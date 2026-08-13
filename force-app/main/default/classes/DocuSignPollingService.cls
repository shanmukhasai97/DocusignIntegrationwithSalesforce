/**
 * Batch polling service for DocuSign envelopes.
 * Periodically fetches envelope status updates via API, synchronizes DocuSign_Status__c records,
 * updates related Agreement__c records, triggers platform events, creates activity logs,
 * and queues signed PDF downloads. Includes retry handling, recipient-level tracking,
 * and watchdog-based resilience.
 */
public inherited sharing class DocuSignPollingService implements Database.Batchable<SObject>, Database.AllowsCallouts, Database.Stateful {
    public class PollingException extends Exception {
    }
    private Integer publishErrors = 0;
    private Integer recordsProcessed = 0;
    private static final Set<String> TERMINAL_STATUSES = new Set<String>{ 'completed', 'declined', 'voided' };
        private static final Integer MAX_IDS_PER_CALLOUT = 50;
    private static final Map<String, Object> ENVELOPES_NOT_FOUND = new Map<String, Object>{ '__notFound__' => true };
        /* START */
        public Database.QueryLocator start(Database.BatchableContext ctx) {
            return Database.getQueryLocator(
                [SELECT Id, Envelope_Id__c, Status__c, Agreement__c, DocuSign_Account_ID__c, Is_Terminal__c, Last_Polled__c, Initiated_By__c, PDF_Downloaded__c, Completed_DateTime__c, Declined_DateTime__c, Voided_DateTime__c, Completed_Signers__c, Recipient_Statuses__c
                 FROM DocuSign_Status__c WHERE (Is_Terminal__c = FALSE OR (Is_Terminal__c = TRUE AND Status__c = 'Completed' AND PDF_Downloaded__c = FALSE)) AND DocuSign_Account_ID__c != NULL AND Envelope_Id__c != NULL
                 ORDER BY CreatedDate ASC]);
        }
    /* EXECUTE */
    public void execute(Database.BatchableContext ctx, List<DocuSign_Status__c> scope) {
        if (scope == null || scope.isEmpty()) return;
        System.debug(LoggingLevel.INFO, '[DocuSignPollingService] Batch execute. Records: ' + scope.size());
        Map<String, List<DocuSign_Status__c>> groups = groupByAccount(scope);
        for (String groupKey : groups.keySet()) {
            try {
                processGroup(groupKey, groups.get(groupKey));
            } catch (Exception e) {
                System.debug(LoggingLevel.ERROR, '[DocuSignPollingService] Group failed: ' + groupKey + ' | ' + e.getMessage() + ' | ' + e.getStackTraceString());
            }
        }
        recordsProcessed += scope.size();
    }
    /* FINISH */
    public void finish(Database.BatchableContext ctx) {
        System.debug(LoggingLevel.INFO, '[DocuSignPollingService] Batch complete. Processed=' + recordsProcessed + ' PublishErrors=' + publishErrors);
        try {
            if (!DocuSignPollingScheduler.isPollingActive()) {
                System.debug(LoggingLevel.WARN, '[DocuSignPollingService] Scheduler not active — restarting.');
                DocuSignPollingScheduler.startPolling();
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, '[DocuSignPollingService] Could not restart scheduler: ' + e.getMessage());
        }
        try {
            if (!DocuSignPollingScheduler.isWatchdogActive()) {
                System.debug(LoggingLevel.WARN, '[DocuSignPollingService] Watchdog not active — restarting.');
                DocuSignPollingScheduler.startWatchdog();
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, '[DocuSignPollingService] Could not restart watchdog: ' + e.getMessage());
        }
    }
    private void processGroup(String groupKey, List<DocuSign_Status__c> records) {
        List<String> parts = groupKey.split('\\|');
        String accountId = parts[0];
        String environment = parts[1];
        String apiNc = DocuSignConfigService.getApiNamedCredential(environment);
        String apiVersion = DocuSignConfigService.getApiVersion();
        Map<String, DocuSign_Status__c> statusByEnvelopeId = new Map<String, DocuSign_Status__c>();
        List<String> allEnvelopeIds = new List<String>();
        for (DocuSign_Status__c rec : records) {
            if (String.isBlank(rec.Envelope_Id__c)) continue;
            allEnvelopeIds.add(rec.Envelope_Id__c);
            statusByEnvelopeId.put(rec.Envelope_Id__c.toLowerCase(), rec);
        }
        Integer total = allEnvelopeIds.size();
        Integer i = 0;
        while (i < total) {
            Integer ends = Math.min(i + MAX_IDS_PER_CALLOUT, total);
            List<String> chunk = new List<String>();
            for (Integer j = i; j < ends; j++) {
                chunk.add(allEnvelopeIds[j]);
            }
            // Call DocuSign
            Map<String, Object> apiResponse = callListStatusChanges(apiNc, apiVersion, accountId, chunk);
            if (apiResponse == null) {
                i = ends;
                continue;
            }
            if (apiResponse == ENVELOPES_NOT_FOUND) {
                List<DocuSign_Status__c> chunkRecords = new List<DocuSign_Status__c>();
                for (String eid : chunk) {
                    DocuSign_Status__c rec = statusByEnvelopeId.get(eid.toLowerCase());
                    if (rec != null) {
                        chunkRecords.add(rec);
                    }
                }
                if (!chunkRecords.isEmpty()) {
                    markChunkTerminalNotFound(chunkRecords);
                }
                i = ends;
                continue;
            }
            // Normal success case
            List<Object> envelopeList = (List<Object>) apiResponse.get('envelopes');
            if (envelopeList == null || envelopeList.isEmpty()) {
                System.debug(LoggingLevel.WARN, '[DocuSignPollingService] No envelopes returned for accountId=' + accountId);
                i = ends;
                continue;
            }
            // Build map of envelope data
            Map<String, Object> envelopeDataByIdMap = new Map<String, Object>();
            for (Object envObj : envelopeList) {
                Map<String, Object> envData = (Map<String, Object>) envObj;
                String eid = ((String) envData.get('envelopeId'))?.toLowerCase();
                if (String.isNotBlank(eid)) {
                    envelopeDataByIdMap.put(eid, envData);
                }
            }
            // Get matching records for this chunk
            List<DocuSign_Status__c> chunkRecords = new List<DocuSign_Status__c>();
            for (String eid : chunk) {
                DocuSign_Status__c rec = statusByEnvelopeId.get(eid.toLowerCase());
                if (rec != null) {
                    chunkRecords.add(rec);
                }
            }
            if (!chunkRecords.isEmpty() && !envelopeDataByIdMap.isEmpty()) {
                applyStatusUpdates(chunkRecords, envelopeDataByIdMap, environment);
            }
            i = ends;
        }
    }
    private Map<String, Object> callListStatusChanges(String apiNc, String apiVersion, String accountId, List<String> envelopeIds) {
        if (envelopeIds == null || envelopeIds.isEmpty()) {
            return null;
        }
        String idList = String.join(envelopeIds, ',');
        String path = '/restapi/' + apiVersion + '/accounts/' + accountId + '/envelopes?envelope_ids=' + EncodingUtil.urlEncode(idList, 'UTF-8') + '&include=recipients' + '&status=created,sent,delivered,completed,declined,voided';
        HttpRequest req = new HttpRequest();
        req.setEndpoint(apiNc + path);
        req.setMethod('GET');
        req.setTimeout(30000);
        HttpResponse res = new Http().send(req);
        System.debug(LoggingLevel.INFO, '[DocuSignPollingService.callListStatusChanges] AccountId=' + accountId + ' Envelopes=' + envelopeIds.size() + ' Status=' + res.getStatusCode());
        if (res.getStatusCode() == 200) {
            return (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
        }
        if (res.getStatusCode() == 401) {
            System.debug(LoggingLevel.WARN, '[DocuSignPollingService] 401 — Token invalid/expired for account ' + accountId);
            return null;
        }
        if (res.getStatusCode() == 404) {
            System.debug(LoggingLevel.WARN, '[DocuSignPollingService] 404 — Some envelopes not found. Account=' + accountId + ' Body: ' + res.getBody().left(500));
            return ENVELOPES_NOT_FOUND;
        }
        System.debug(LoggingLevel.ERROR, '[DocuSignPollingService] API error ' + res.getStatusCode() + ': ' + res.getBody());
        return null;
    }
    private void applyStatusUpdates(List<DocuSign_Status__c> records, Map<String, Object> envelopeMap, String environment) {
        Set<Id> agrIds = new Set<Id>();
        for (DocuSign_Status__c r : records) {
            if (r.Agreement__c != null)
                agrIds.add(r.Agreement__c);
        }
        Map<Id, String> agrNameById = new Map<Id, String>();
        if (!agrIds.isEmpty()) {
            for (Agreement__c a : [SELECT Id, Name FROM Agreement__c WHERE Id IN :agrIds]) {
                agrNameById.put(a.Id, a.Name);
            }
        }
        List<DocuSign_Status__c> toUpdate = new List<DocuSign_Status__c>();
        List<DocuSign_Event__e> events = new List<DocuSign_Event__e>();
        Map<Id, Agreement__c> agrUpdates = new Map<Id, Agreement__c>();
        List<String> pdfEnvelopeIds = new List<String>();
        List<Id> pdfAgreementIds = new List<Id>();
        List<String> pdfStatusSuffixes = new List<String>();
        // Track envelope IDs already queued for PDF in this batch run
        Set<String> pdfQueued = new Set<String>();
        List<List<Object>> recipientActQueue = new List<List<Object>>();
        List<List<Object>> envelopeActQueue = new List<List<Object>>();
        Set<String> terminalStatuses = new Set<String>{ 'completed', 'declined', 'voided' };
            for (DocuSign_Status__c rec : records) {
                Map<String, Object> envData = (Map<String, Object>) envelopeMap.get(rec.Envelope_Id__c?.toLowerCase());
                if (envData == null)
                    continue;
                String rawStatus = ((String) envData.get('status'))?.toLowerCase();
                if (String.isBlank(rawStatus))
                    continue;
                Boolean isTerminal = terminalStatuses.contains(rawStatus);
                String displayStatus = rawStatus.substring(0, 1).toUpperCase() + rawStatus.substring(1);
                String mappedStatus = (rawStatus == 'created') ? 'Draft' : displayStatus;
                Boolean statusChanged = rec.Status__c != mappedStatus;
                //   Update DocuSign Status envelope level fields
                rec.Status__c = mappedStatus;
                rec.Last_Polled__c = System.now();
                rec.Is_Terminal__c = isTerminal;
                if (isTerminal) {
                    if (rawStatus == 'completed' && rec.Completed_DateTime__c == null)
                        rec.Completed_DateTime__c = System.now();
                    else if (rawStatus == 'declined' && rec.Declined_DateTime__c == null)
                        rec.Declined_DateTime__c = System.now();
                    else if (rawStatus == 'voided' && rec.Voided_DateTime__c == null)
                        rec.Voided_DateTime__c = System.now();
                }
                toUpdate.add(rec);
                //   Platform event for LWC refresh
                events.add(new DocuSign_Event__e(Envelope_Id__c = rec.Envelope_Id__c, New_Status__c = displayStatus, Agreement_Id__c = rec.Agreement__c, Is_Terminal__c = isTerminal, Event_Time__c = System.now()));
                if (rawStatus == 'completed' && rec.Agreement__c != null && !rec.PDF_Downloaded__c && !pdfQueued.contains(rec.Envelope_Id__c)) {
                    pdfEnvelopeIds.add(rec.Envelope_Id__c);
                    pdfAgreementIds.add(rec.Agreement__c);
                    pdfStatusSuffixes.add('FullySigned');
                    pdfQueued.add(rec.Envelope_Id__c);
                }
                if (rec.Agreement__c == null) continue;
                Map<String, String> prevRecipientStatuses = new Map<String, String>();
                if (String.isNotBlank(rec.Recipient_Statuses__c)) {
                    try {
                        prevRecipientStatuses = (Map<String, String>) JSON.deserialize(rec.Recipient_Statuses__c, Map<String, String>.class);
                    } catch (Exception e) {
                        System.debug(LoggingLevel.WARN, '[DocuSignPollingService] Could not parse Recipient_Statuses__c ' + 'for envelope ' + rec.Envelope_Id__c + ': ' + e.getMessage());
                    }
                }
                Map<String, String> currentRecipientStatuses = new Map<String, String>();
                Integer totalSigners = 0;
                Integer completedSigners = 0;
                List<String> completedSignerNames = new List<String>();
                List<String> declinedSignerNames = new List<String>();
                try {
                    Map<String, Object> recipients = (Map<String, Object>) envData.get('recipients');
                    if (recipients != null) {
                        //   SIGNERS
                        List<Object> signersList = (List<Object>) recipients.get('signers');
                        if (signersList != null) {
                            for (Object s : signersList) {
                                Map<String, Object> signer = (Map<String, Object>) s;
                                String recipId = (String) signer.get('recipientId');
                                String recipStatus = ((String) signer.get('status'))?.toLowerCase();
                                String recipName = (String) signer.get('name');
                                String recipEmail = (String) signer.get('email');
                                String label = String.isNotBlank(recipName) ? recipName : (String.isNotBlank(recipEmail) ? recipEmail : 'A signer');
                                    totalSigners++;
                                String stateKey = 'signer_' + recipId;
                                String prevStatus = prevRecipientStatuses.get(stateKey);
                                currentRecipientStatuses.put(stateKey, recipStatus);
                                if (recipStatus == 'completed') {
                                    completedSigners++;
                                    completedSignerNames.add(label);
                                } else if (recipStatus == 'declined') {
                                    declinedSignerNames.add(label);
                                }
                                if (prevStatus == recipStatus)
                                    continue;
                                // Detect resend (went backwards)
                                if (recipStatus == 'sent' && (prevStatus == 'delivered' || prevStatus == 'completed')) {
                                    recipientActQueue.add(new List<Object>{ rec.Agreement__c, rec.Initiated_By__c, rec.Envelope_Id__c, 'Envelope Resent to ' + label, 'Envelope was resent to ' + label + '. Previous status: ' + prevStatus + '. Envelope ID: ' + rec.Envelope_Id__c });
                                    continue;
                                }
                                if (recipStatus == 'sent') {
                                    recipientActQueue.add(new List<Object>{ rec.Agreement__c, rec.Initiated_By__c, rec.Envelope_Id__c, 'Recipient Sent — ' + label, 'DocuSign email sent to ' + label + '. Awaiting action.' + ' Envelope ID: ' + rec.Envelope_Id__c });
                                } else if (recipStatus == 'delivered') {
                                    recipientActQueue.add(new List<Object>{ rec.Agreement__c, rec.Initiated_By__c, rec.Envelope_Id__c, 'Recipient Delivered — ' + label, label + ' has opened and viewed the document.' + ' Envelope ID: ' + rec.Envelope_Id__c });
                                } else if (recipStatus == 'completed') {
                                    recipientActQueue.add(new List<Object>{ rec.Agreement__c, rec.Initiated_By__c, rec.Envelope_Id__c, 'Recipient Signed — ' + label, label + ' has completed signing.' + ' Envelope ID: ' + rec.Envelope_Id__c });
                                } else if (recipStatus == 'declined') {
                                    recipientActQueue.add(new List<Object>{ rec.Agreement__c, rec.Initiated_By__c, rec.Envelope_Id__c, 'Recipient Declined — ' + label, label + ' declined to sign the document.' + ' Envelope ID: ' + rec.Envelope_Id__c });
                                } else if (recipStatus == 'autoresponded') {
                                    recipientActQueue.add(new List<Object>{ rec.Agreement__c, rec.Initiated_By__c, rec.Envelope_Id__c, 'Recipient Auto-Responded — ' + label, label + ' auto-responded (out of office or blocked email).' + ' Envelope ID: ' + rec.Envelope_Id__c });
                                } else if (recipStatus == 'authenticationfailed') {
                                    recipientActQueue.add(new List<Object>{ rec.Agreement__c, rec.Initiated_By__c, rec.Envelope_Id__c, 'Recipient Auth Failed — ' + label, label + ' failed identity authentication.' + ' Manual follow-up required.' + ' Envelope ID: ' + rec.Envelope_Id__c });
                                }
                            }
                        }
                        //  CERTIFIED DELIVERIES (viewers) 
                        List<Object> viewersList = (List<Object>) recipients.get('certifiedDeliveries');
                        if (viewersList != null) {
                            for (Object v : viewersList) {
                                Map<String, Object> viewer = (Map<String, Object>) v;
                                String recipId = (String) viewer.get('recipientId');
                                String recipStatus = ((String) viewer.get('status'))?.toLowerCase();
                                String recipName = (String) viewer.get('name');
                                String label = String.isNotBlank(recipName) ? recipName : 'A viewer';
                                String stateKey = 'viewer_' + recipId;
                                String prevStatus = prevRecipientStatuses.get(stateKey);
                                currentRecipientStatuses.put(stateKey, recipStatus);
                                if (prevStatus == recipStatus)
                                    continue;
                                if (recipStatus == 'sent') {
                                    recipientActQueue.add(new List<Object>{ rec.Agreement__c, rec.Initiated_By__c, rec.Envelope_Id__c, 'Viewer Sent — ' + label, 'DocuSign email sent to viewer ' + label + '.' + ' Envelope ID: ' + rec.Envelope_Id__c });
                                } else if (recipStatus == 'delivered' || recipStatus == 'completed') {
                                    recipientActQueue.add(new List<Object>{ rec.Agreement__c, rec.Initiated_By__c, rec.Envelope_Id__c, 'Document Viewed — ' + label, label + ' has viewed and acknowledged the document.' + ' Envelope ID: ' + rec.Envelope_Id__c });
                                }
                            }
                        }
                        //  CARBON COPIES
                        List<Object> ccList = (List<Object>) recipients.get('carbonCopies');
                        if (ccList != null) {
                            for (Object c : ccList) {
                                Map<String, Object> cc = (Map<String, Object>) c;
                                String recipId = (String) cc.get('recipientId');
                                String recipStatus = ((String) cc.get('status'))?.toLowerCase();
                                String recipName = (String) cc.get('name');
                                String label = String.isNotBlank(recipName) ? recipName : 'A recipient';
                                String stateKey = 'cc_' + recipId;
                                String prevStatus = prevRecipientStatuses.get(stateKey);
                                currentRecipientStatuses.put(stateKey, recipStatus);
                                if (prevStatus == recipStatus)
                                    continue;
                                if (recipStatus == 'sent' || recipStatus == 'delivered') {
                                    recipientActQueue.add(new List<Object>{ rec.Agreement__c, rec.Initiated_By__c, rec.Envelope_Id__c, 'Copy Sent to ' + label, label + ' received a copy of the document.' + ' Envelope ID: ' + rec.Envelope_Id__c });
                                }
                            }
                        }
                    }
                } catch (Exception e) {
                    System.debug(LoggingLevel.WARN, '[DocuSignPollingService] Recipients parse error for envelope ' + rec.Envelope_Id__c + ': ' + e.getMessage());
                }
                rec.Recipient_Statuses__c = JSON.serialize(currentRecipientStatuses);
                Integer prevCompleted = rec.Completed_Signers__c != null ? (Integer) rec.Completed_Signers__c : 0;
                rec.Completed_Signers__c = completedSigners;
                if (completedSigners > prevCompleted && totalSigners > 0) {
                    for (Integer idx = prevCompleted + 1; idx <= completedSigners; idx++) {
                        Boolean isIntermediateSigner = (idx < totalSigners) && rawStatus != 'completed' && rawStatus != 'declined' && rawStatus != 'voided';
                        if (isIntermediateSigner && !pdfQueued.contains(rec.Envelope_Id__c + '_partial_' + idx)) {
                            String partialStatus = 'partiallySigned_' + idx + 'of' + totalSigners;
                            pdfEnvelopeIds.add(rec.Envelope_Id__c);
                            pdfAgreementIds.add(rec.Agreement__c);
                            pdfStatusSuffixes.add(partialStatus);
                            pdfQueued.add(rec.Envelope_Id__c + '_partial_' + idx);
                        }
                        // Activity task for partial signing
                        if (idx < totalSigners) {
                            String signerLabel = (completedSignerNames.size() >= idx) ? completedSignerNames[idx - 1] : 'Signer ' + idx;
                            recipientActQueue.add(new List<Object>{ rec.Agreement__c, rec.Initiated_By__c, rec.Envelope_Id__c, 'Partially Signed (' + idx + ' of ' + totalSigners + ')', signerLabel + ' has signed (' + idx + ' of ' + totalSigners + ' recipients). Envelope ID: ' + rec.Envelope_Id__c });
                        }
                    }
                }
                if (rec.Agreement__c != null && completedSigners > prevCompleted && completedSigners < totalSigners && rawStatus != 'completed' && rawStatus != 'declined' && rawStatus != 'voided') {
                    agrUpdates.put(rec.Agreement__c, new Agreement__c(Id = rec.Agreement__c, Status__c = 'In Signature', Status_Group__c = 'In Signature'));
                }
                if (!statusChanged)
                    continue;
                //  Agreement status mapping 
                String agreementStatus;
                String agreementStatusGroup;
                if (rawStatus == 'completed') {
                    agreementStatus = 'Fully Signed';
                    agreementStatusGroup = 'In Signature';
                } else if (rawStatus == 'declined') {
                    agreementStatus = 'Declined';
                    agreementStatusGroup = 'Closed';
                } else if (rawStatus == 'voided') {
                    agreementStatus = 'Voided';
                    agreementStatusGroup = 'Closed';
                } else if (completedSigners > 0 && completedSigners < totalSigners) {
                    agreementStatus = 'In Signature';
                    agreementStatusGroup = 'In Signature';
                } else if (rawStatus == 'sent' || rawStatus == 'delivered') {
                    agreementStatus = 'Sent';
                    agreementStatusGroup = 'In Signature';
                } else if (rawStatus == 'created') {
                    agreementStatus = 'Sent';
                    agreementStatusGroup = 'In Signature';
                } else {
                    agreementStatus = 'In Signature';
                    agreementStatusGroup = 'In Signature';
                }
                // Terminal/sent always overwrites any partial-signing entry for same agreement
                agrUpdates.put(rec.Agreement__c, new Agreement__c(Id = rec.Agreement__c, Status__c = agreementStatus, Status_Group__c = agreementStatusGroup));
                // Envelope-level activity task (always newest in timeline) 
                String taskSubject;
                String taskDesc;
                if (rawStatus == 'sent') {
                    taskSubject = 'Envelope Sent';
                    taskDesc = 'DocuSign envelope sent to all recipients.' + ' Envelope ID: ' + rec.Envelope_Id__c;
                } else if (rawStatus == 'delivered') {
                    taskSubject = 'Envelope Delivered';
                    taskDesc = 'At least one recipient has viewed the document.' + ' Envelope ID: ' + rec.Envelope_Id__c;
                } else if (rawStatus == 'completed') {
                    String signerSummary = completedSignerNames.isEmpty() ? (completedSigners + ' recipient(s)') : String.join(completedSignerNames, ', ');
                    taskSubject = 'Envelope Fully Signed';
                    taskDesc = 'All recipients have signed. Signed by: ' + signerSummary + '. Envelope ID: ' + rec.Envelope_Id__c;
                } else if (rawStatus == 'declined') {
                    String declinerSummary = declinedSignerNames.isEmpty() ? 'A recipient' : String.join(declinedSignerNames, ', ');
                    taskSubject = 'Envelope Declined';
                    taskDesc = declinerSummary + ' declined to sign.' + ' Envelope ID: ' + rec.Envelope_Id__c;
                } else if (rawStatus == 'voided') {
                    taskSubject = 'Envelope Voided';
                    taskDesc = 'The DocuSign envelope was voided.' + ' Envelope ID: ' + rec.Envelope_Id__c;
                } else {
                    taskSubject = 'Envelope ' + displayStatus;
                    taskDesc = 'Status updated to ' + displayStatus + '. Envelope ID: ' + rec.Envelope_Id__c;
                }
                envelopeActQueue.add(new List<Object>{ rec.Agreement__c, rec.Initiated_By__c, rec.Envelope_Id__c, taskSubject, taskDesc });
            }
        //  BULK DML DocuSign Status
        if (!toUpdate.isEmpty()) {
            update Security.stripInaccessible(AccessType.UPDATABLE, toUpdate).getRecords();
        }
        // BULK DML  Agreement
        if (!agrUpdates.isEmpty()) {
            try {
                List<SObject> safeAgrs = Security.stripInaccessible(AccessType.UPDATABLE, agrUpdates.values()).getRecords();
                List<Database.SaveResult> results = Database.update(safeAgrs, false);
                for (Integer i = 0; i < results.size(); i++) {
                    if (!results[i].isSuccess()) {
                        Database.Error err = results[i].getErrors()[0];
                        System.debug(LoggingLevel.ERROR, '[DocuSignPollingService] Agreement update FAILED | Id=' + safeAgrs[i].Id + ' | ' + err.getMessage());
                    }
                }
            } catch (Exception e) {
                System.debug(LoggingLevel.ERROR, '[DocuSignPollingService] Agreement update EXCEPTION: ' + e.getMessage() + '\n' + e.getStackTraceString());
            }
        }
        // PLATFORM EVENTS 
        if (!events.isEmpty()) {
            EventBus.publish(events);
        }
        // Recipient tasks first → envelope tasks second (timeline ordering)
        try {
            if (!recipientActQueue.isEmpty()) {
                DocuSignAgreementService.createActivitiesBulk(recipientActQueue);
            }
            if (!envelopeActQueue.isEmpty()) {
                DocuSignAgreementService.createActivitiesBulk(envelopeActQueue);
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, '[DocuSignPollingService] createActivitiesBulk failed: ' + e.getMessage() + '\n' + e.getStackTraceString());
        }
        // PDF QUEUEABLE 
        if (!pdfEnvelopeIds.isEmpty()) {
            try {
                System.enqueueJob(new DocuSignAgreementService.BulkSignedPdfQueueable(pdfEnvelopeIds, pdfAgreementIds, pdfStatusSuffixes));
            } catch (AsyncException e) {
                System.debug(LoggingLevel.WARN, '[DocuSignPollingService] PDF queueable enqueue failed: ' + e.getMessage());
            }
        }
    }
    /* PRIVATE HELPERS */
    private Map<String, List<DocuSign_Status__c>> groupByAccount(List<DocuSign_Status__c> records) {
        DocuSign_Config__mdt cfg = DocuSignConfigService.getConfig();   // let it throw if missing
        if (!cfg.Active__c || String.isBlank(cfg.DocuSign_API_Account_ID__c)) {
            System.debug(LoggingLevel.ERROR, '[DocuSignPollingService.groupByAccount] DocuSign not active in CMDT.');
            return new Map<String, List<DocuSign_Status__c>>();
        }
        String activeAccountId = cfg.DocuSign_API_Account_ID__c;
        String activeEnvironment = DocuSignConfigService.detectEnvironment();
        String groupKey = activeAccountId + '|' + activeEnvironment;
        List<DocuSign_Status__c> validRecords = new List<DocuSign_Status__c>();
        for (DocuSign_Status__c rec : records) {
            if (String.isNotBlank(rec.Envelope_Id__c)) {
                validRecords.add(rec);
            }
        }
        System.debug(LoggingLevel.INFO, '[DocuSignPollingService.groupByAccount] Org-wide polling → Account: ' + activeAccountId + ' | Env: ' + activeEnvironment + ' | Envelopes to check: ' + validRecords.size());
        return new Map<String, List<DocuSign_Status__c>>{ groupKey => validRecords };
            }
    private static String mapDocuSignStatus(String raw) {
        if (String.isBlank(raw))
            return 'Draft';
        switch on raw.toLowerCase() {
            when 'sent' {return 'Sent';}
            when 'delivered' { return 'Delivered';}
            when 'completed' {return 'Completed';}
            when 'declined' {return 'Declined';}
            when 'voided' {return 'Voided';}
            when 'created' {return 'Draft';}
            when else {return raw;}
        }
    }
    private static void updateAgreementStatus(Agreement__c agr, String mappedStatus) {
        if (mappedStatus == 'Completed') {
            agr.Status__c = 'Fully Signed';
            agr.Status_Group__c = 'In Signature';
        } else if (mappedStatus == 'Sent') {
            agr.Status__c = 'Sent';
            agr.Status_Group__c = 'In Signature';
        } else if (mappedStatus == 'Delivered') {
            agr.Status__c = 'In Signature';
            agr.Status_Group__c = 'In Signature';
        } else if (mappedStatus == 'Declined') {
            agr.Status__c = 'Declined';
            agr.Status_Group__c = 'Closed';
        } else if (mappedStatus == 'Voided') {
            agr.Status__c = 'Voided';
            agr.Status_Group__c = 'Closed';
        }
    }
    /*   RETRY FAILED PDF DOWNLOADS (called by watchdog)*/
    public static void retryFailedPdfDownloads() {
        List<DocuSign_Status__c> pending = [ SELECT Id, Envelope_Id__c, Agreement__c, Agreement__r.Name FROM DocuSign_Status__c
                                            WHERE Is_Terminal__c = TRUE AND Status__c = 'Completed' AND PDF_Downloaded__c = FALSE AND Envelope_Id__c != NULL AND Agreement__c != NULL
                                            LIMIT 50 ];
        if (pending.isEmpty()) return;
        List<String> envIds = new List<String>();
        List<Id> agrIds = new List<Id>();
        List<String> suffixes = new List<String>();
        for (DocuSign_Status__c rec : pending) {
            envIds.add(rec.Envelope_Id__c);
            agrIds.add(rec.Agreement__c);
            suffixes.add('FullySigned');
        }
        System.enqueueJob(new DocuSignAgreementService.BulkSignedPdfQueueable(envIds, agrIds, suffixes));
        System.debug(LoggingLevel.INFO, '[DocuSignPollingService] Watchdog retrying PDF for ' + pending.size() + ' envelope(s).');
    }
    private void markChunkTerminalNotFound(List<DocuSign_Status__c> recs) {
        if (recs == null || recs.isEmpty()) return;
        List<DocuSign_Status__c> toUpdate = new List<DocuSign_Status__c>();
        for (DocuSign_Status__c rec : recs) {
            rec.Is_Terminal__c = true;
            rec.Status__c = 'Voided';  
            rec.Last_Polled__c = System.now();
            toUpdate.add(rec);
            System.debug(LoggingLevel.WARN, '[DocuSignPollingService.markChunkTerminalNotFound] ' + 'Marking terminal (404): envelopeId=' + rec.Envelope_Id__c);
        }
        try {
            update Security.stripInaccessible(AccessType.UPDATABLE, toUpdate).getRecords();
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, '[DocuSignPollingService.markChunkTerminalNotFound] DML failed: ' + e.getMessage());
        }
    }
}