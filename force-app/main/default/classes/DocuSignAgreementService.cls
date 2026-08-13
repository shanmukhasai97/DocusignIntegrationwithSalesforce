/**
* DocuSignAgreementService class for managing DocuSign agreement lifecycle in Salesforce, including document retrieval,
* recipient search, envelope creation, sender view generation, signed PDF download, and activity tracking,
* with asynchronous processing and proper ownership handling.
*/
public with sharing class DocuSignAgreementService {
    /*DTOs*/
    public class AgreementFileDTO {
        @AuraEnabled public Id contentDocumentId;
        @AuraEnabled public Id contentVersionId;
        @AuraEnabled public DateTime LastModifiedDate;
        @AuraEnabled public Integer ContentSize;
        @AuraEnabled public String title;
    }
    public class RecipientDTO {
        @AuraEnabled public String name;
        @AuraEnabled public String email;
        @AuraEnabled public Integer routingOrder;
        @AuraEnabled public String type;
        @AuraEnabled public Id recordId;
        @AuraEnabled public String role;
    }
    public class DocuSignServiceException extends Exception {
    }
    /** PUBLIC AURA METHODS **/
    @AuraEnabled(cacheable=true)
    public static List<AgreementFileDTO> getAgreementFiles(Id agreementId) {
        List<AgreementFileDTO> results = new List<AgreementFileDTO>();
        if (agreementId == null) return results;
        List<ContentDocumentLink> links = Security.stripInaccessible(
            AccessType.READABLE,
            [   SELECT ContentDocumentId, ContentDocument.Title, ContentDocument.LatestPublishedVersionId, ContentDocument.LastModifiedDate, ContentDocument.ContentSize
             FROM ContentDocumentLink
             WHERE LinkedEntityId = :agreementId AND (NOT ContentDocument.Title LIKE '%_FullySigned%') AND (NOT ContentDocument.Title LIKE '%_PartiallySigned%') AND (NOT ContentDocument.Title LIKE '%_partiallySigned%') AND (NOT ContentDocument.Title LIKE 'Signed - %')
             ORDER BY ContentDocument.Title
            ]).getRecords();
        for (ContentDocumentLink cdl : links) {
            AgreementFileDTO dto = new AgreementFileDTO();
            dto.contentDocumentId = cdl.ContentDocumentId;
            dto.contentVersionId = cdl.ContentDocument.LatestPublishedVersionId;
            dto.title = cdl.ContentDocument.Title;
            dto.LastModifiedDate = cdl.ContentDocument.LastModifiedDate;
            dto.ContentSize = cdl.ContentDocument.ContentSize;
            results.add(dto);
        }
        return results;
    }
    
    @AuraEnabled(cacheable=true)
    public static List<RecipientDTO> searchRecipients(String searchKey) {
        List<RecipientDTO> results = new List<RecipientDTO>();
        if (String.isBlank(searchKey))
            return results;
        String key = '%' + searchKey.trim() + '%';
        List<User> users = Security.stripInaccessible(AccessType.READABLE, [SELECT Id, Name, Email FROM User WHERE IsActive = TRUE AND Email != NULL AND (Name LIKE :key OR Email LIKE :key) LIMIT 10]).getRecords();
        for (User u : users) {
            RecipientDTO dto = new RecipientDTO();
            dto.recordId = u.Id;
            dto.name = u.Name;
            dto.email = u.Email;
            dto.type = 'User';
            results.add(dto);
        }
        List<Contact> contacts = Security.stripInaccessible(AccessType.READABLE, [SELECT Id, Name, Email FROM Contact WHERE Email != NULL AND (Name LIKE :key OR Email LIKE :key) LIMIT 10]).getRecords();
        for (Contact c : contacts) {
            RecipientDTO dto = new RecipientDTO();
            dto.recordId = c.Id;
            dto.name = c.Name;
            dto.email = c.Email;
            dto.type = 'Contact';
            results.add(dto);
        }
        return results;
    }
    @AuraEnabled
    public static String sendForSignature(Id agreementId, String filesJson, String recipientsJson, Integer reminderDays, Integer expireDays, String emailSubject, String emailMessage) {
        List<AgreementFileDTO> files = (List<AgreementFileDTO>) JSON.deserialize(filesJson, List<AgreementFileDTO>.class);
        List<RecipientDTO> recipients = (List<RecipientDTO>) JSON.deserialize(recipientsJson, List<RecipientDTO>.class);
        if (files == null || files.isEmpty() || recipients == null || recipients.isEmpty()) {
            throw new AuraHandledException('Documents and Recipients are required.');
        }
        DocuSign_Config__mdt cfg = DocuSignConfigService.getConfig();
        if (!cfg.Active__c || String.isBlank(cfg.DocuSign_API_Account_ID__c)) {
            throw new AuraHandledException('No DocuSign account is connected. Please authenticate via the DocuSign Setup tab.');
        }
        Id currentUserId = UserInfo.getUserId();
        System.enqueueJob(new EnvelopeQueueable(agreementId, currentUserId, files, recipients, reminderDays, expireDays, emailSubject, emailMessage));
        return 'QUEUED';
    }
    @AuraEnabled
    public static String createSenderView(Id agreementId, Long sentAtMillis) {
        if (agreementId == null) {
            throw new AuraHandledException('Agreement ID is required.');
        }
        Datetime cutoff = (sentAtMillis != null) ? Datetime.newInstance(sentAtMillis - 15000) : Datetime.now().addMinutes(-10);
        List<DocuSign_Status__c> envelopes = [SELECT Envelope_Id__c FROM DocuSign_Status__c WHERE Agreement__c = :agreementId AND CreatedDate >= :cutoff ORDER BY CreatedDate DESC LIMIT 1];
        if (envelopes.isEmpty()) {
            throw new AuraHandledException('Envelope not created yet. Please wait a moment and try again.');
        }
        String envelopeId = envelopes[0].Envelope_Id__c;
        String accountId = getConfiguredAccountId();
        String environment = getConfiguredEnvironment();
        String apiNc = DocuSignConfigService.getApiNamedCredential(environment);
        String apiVersion = DocuSignConfigService.getApiVersion();
        String returnUrl = URL.getOrgDomainUrl().toExternalForm() + '/lightning/r/Agreement__c/' + agreementId + '/view';
        String path = '/restapi/' + apiVersion + '/accounts/' + accountId + '/envelopes/' + envelopeId + '/views/sender';
        HttpResponse res = doCallout(apiNc, 'POST', path, JSON.serialize(new Map<String, Object>{ 'returnUrl' => returnUrl }));
        if (res.getStatusCode() != 200 && res.getStatusCode() != 201) {
            System.debug(LoggingLevel.ERROR, 'Sender View failed: ' + res.getBody());
            throw new AuraHandledException('Failed to create sender view: ' + res.getBody());
        }
        Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
        return (String) body.get('url');
    }
    @AuraEnabled
    public static void downloadSignedPdf(String envelopeId, Id agreementId) {
        if (String.isBlank(envelopeId) || agreementId == null) {
            throw new AuraHandledException('Envelope ID and Agreement ID are required.');
        }
        
        // 1. Resolve the actual initiator from the status record
        Id actualOwnerId = UserInfo.getUserId(); // Default
        List<DocuSign_Status__c> statusRecs = [
            SELECT Initiated_By__c FROM DocuSign_Status__c 
            WHERE Envelope_Id__c = :envelopeId LIMIT 1
        ];
        if (!statusRecs.isEmpty() && statusRecs[0].Initiated_By__c != null) {
            actualOwnerId = statusRecs[0].Initiated_By__c;
        }
        
        String accountId = getConfiguredAccountId();
        String environment = getConfiguredEnvironment();
        String apiNc = DocuSignConfigService.getApiNamedCredential(environment);
        String apiVersion = DocuSignConfigService.getApiVersion();
        
        List<Agreement__c> agreements = Security.stripInaccessible(AccessType.READABLE, [SELECT Name FROM Agreement__c WHERE Id = :agreementId LIMIT 1]).getRecords();
        String agreementName = agreements.isEmpty() ? 'Agreement' : ((Agreement__c) agreements[0]).Name;
        
        // Retrieve Document List
        HttpRequest listReq = new HttpRequest();
        listReq.setEndpoint(apiNc + '/restapi/' + apiVersion + '/accounts/' + accountId + '/envelopes/' + envelopeId + '/documents');
        listReq.setMethod('GET');
        listReq.setTimeout(30000);
        HttpResponse listRes = new Http().send(listReq);
        
        if (listRes.getStatusCode() != 200) {
            throw new AuraHandledException('Failed to retrieve document list. Status: ' + listRes.getStatusCode());
        }
        
        Map<String, Object> listResp = (Map<String, Object>) JSON.deserializeUntyped(listRes.getBody());
        List<Object> docs = (List<Object>) listResp.get('envelopeDocuments');
        
        if (docs == null || docs.isEmpty()) return;
        
        Set<String> existingTitles = new Set<String>();
        for (ContentDocumentLink cdl : [SELECT ContentDocument.Title FROM ContentDocumentLink WHERE LinkedEntityId = :agreementId]) {
            existingTitles.add(cdl.ContentDocument.Title);
        }
        
        Set<String> seenBaseNames = new Set<String>();
        List<ContentVersion> toInsert = new List<ContentVersion>();
        
        for (Object d : docs) {
            Map<String, Object> doc = (Map<String, Object>) d;
            String docId = (String) doc.get('documentId');
            if (docId == 'certificate') continue;
            
            String pdfTitle = buildPdfTitle(agreementName, (String) doc.get('name'), docId, 'FullySigned', seenBaseNames, envelopeId);
            if (existingTitles.contains(pdfTitle)) continue;
            
            // Download Document Blob
            HttpRequest req = new HttpRequest();
            req.setEndpoint(apiNc + '/restapi/' + apiVersion + '/accounts/' + accountId + '/envelopes/' + envelopeId + '/documents/' + docId);
            req.setMethod('GET');
            req.setTimeout(30000);
            HttpResponse res = new Http().send(req);
            
            if (res.getStatusCode() == 200) {
                ContentVersion cv = new ContentVersion();
                cv.Title = pdfTitle;
                cv.PathOnClient = pdfTitle + '.pdf';
                cv.VersionData = res.getBodyAsBlob();
                cv.FirstPublishLocationId = agreementId;
                // SET THE OWNER EXPLICITLY TO THE INITIATOR
                cv.OwnerId = actualOwnerId; 
                toInsert.add(cv);
            }
        }
        
        if (!toInsert.isEmpty()) {
            new ContentVersionInsertHelper().insertAll(toInsert);
            createActivity(agreementId, actualOwnerId, envelopeId, 'Signed Document Received', 'Downloaded ' + toInsert.size() + ' signed PDF(s).');
        }
    }
    /** ENVELOPE QUEUEABLE **/
    public class EnvelopeQueueable implements Queueable, Database.AllowsCallouts {
        private Id agreementId;
        private Id initiatedByUserId;
        private List<AgreementFileDTO> files;
        private List<RecipientDTO> recipients;
        private Integer reminderDays;
        private Integer expireDays;
        private String emailSubject;
        private String emailMessage;
        public EnvelopeQueueable(Id agreementId, Id initiatedByUserId, List<AgreementFileDTO> files, List<RecipientDTO> recipients, Integer reminderDays, Integer expireDays, String emailSubject, String emailMessage) {
            this.agreementId = agreementId;
            this.initiatedByUserId = initiatedByUserId;
            this.files = files;
            this.recipients = recipients;
            this.reminderDays = reminderDays;
            this.expireDays = expireDays;
            this.emailSubject = emailSubject;
            this.emailMessage = emailMessage;
        }
        public void execute(QueueableContext ctx) {
            System.debug('[EnvelopeQueueable] Start | agreementId=' + agreementId + ' | userId=' + initiatedByUserId);
            try {
                String accountId = getConfiguredAccountId();
                String environment = getConfiguredEnvironment();
                String apiNc = DocuSignConfigService.getApiNamedCredential(environment);
                String apiVersion = DocuSignConfigService.getApiVersion();
                Map<String, Object> payload = new Map<String, Object>{
                    'emailSubject' => String.isNotBlank(this.emailSubject) ? this.emailSubject : 'Agreement Signature Request',
                        'emailBlurb' => String.isNotBlank(this.emailMessage) ? this.emailMessage : 'Please review and sign the attached documents.',
                            'status' => 'created','documents' => buildDocuments(this.files),
                            'recipients' => buildRecipients(this.recipients),
                            'notification' => buildNotification(this.reminderDays, this.expireDays)
                            };
                                HttpResponse res = doCallout(apiNc, 'POST', '/restapi/' + apiVersion + '/accounts/' + accountId + '/envelopes', JSON.serialize(payload));
                if (res.getStatusCode() != 201 && res.getStatusCode() != 200) {
                    throw new CalloutException('DocuSign create envelope failed: ' + res.getBody());
                }
                Map<String, Object> resp = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
                String envelopeId = (String) resp.get('envelopeId');
                DocuSign_Status__c env = new DocuSign_Status__c();
                env.Agreement__c = agreementId;
                env.Envelope_Id__c = envelopeId;
                env.Status__c = 'Sent';
                env.Sent_DateTime__c = System.now();
                env.Subject__c = this.emailSubject;
                env.Email_Message__c = this.emailMessage;
                env.Recipients_JSON__c = JSON.serialize(this.recipients);
                env.Initiated_By__c = this.initiatedByUserId;
                env.Reminder_Days__c = this.reminderDays;
                env.Expire_After_Days__c = this.expireDays;
                env.DocuSign_Account_ID__c = accountId;
                env.Is_Terminal__c = false;
                env.Last_Polled__c = null;
                env.PDF_Downloaded__c = false;
                if (this.expireDays != null) {
                    env.Expiration_Date__c = System.now().addDays(this.expireDays);
                }
                List<String> docNames = new List<String>();
                for (AgreementFileDTO f : this.files) {
                    if (f != null && f.title != null)
                        docNames.add(f.title);
                }
                env.Document_Names__c = String.join(docNames, ', ');
                insert env;
                Agreement__c agr = new Agreement__c(Id = agreementId, Status__c = 'Sent', Status_Group__c = 'In Signature');
                update agr;
                createActivity(agreementId, this.initiatedByUserId, envelopeId, 'Envelope Created', 'DocuSign envelope created with ID: ' + envelopeId);
            } catch (Exception e) {
                System.debug(LoggingLevel.ERROR, '[EnvelopeQueueable] ' + e.getMessage() + ' | ' + e.getStackTraceString());
                throw e;
            }
        }
    }
    /** SIGNED PDF QUEUEABLE  (single envelope) **/
    public class SignedPdfQueueable implements Queueable, Database.AllowsCallouts {
        private String envelopeId;
        private Id     agreementId;
        private String statusSuffix;
        
        public SignedPdfQueueable(String envelopeId, Id agreementId) {
            this.envelopeId   = envelopeId;
            this.agreementId  = agreementId;
            this.statusSuffix = 'FullySigned';
        }
        public SignedPdfQueueable(String envelopeId, Id agreementId, String statusSuffix) {
            this.envelopeId   = envelopeId;
            this.agreementId  = agreementId;
            this.statusSuffix = normalizeStatusSuffix(statusSuffix);
        }
        public SignedPdfQueueable(Id agreementId, Id initiatedByUserId, String envelopeId, String fileNameSuffix) {
            this.envelopeId   = envelopeId;
            this.agreementId  = agreementId;
            this.statusSuffix = 'FullySigned';
        }
        
        public void execute(QueueableContext ctx) {
            System.debug(LoggingLevel.INFO, '[SignedPdfQueueable] Start | envelopeId=' + envelopeId
                         + ' | agreementId=' + agreementId + ' | statusSuffix=' + statusSuffix);
            
            Boolean isFullySigned = statusSuffix != null && statusSuffix.contains('FullySigned');
            
            //   DUPLICATE GUARD  
            if (isFullySigned) {
                List<DocuSign_Status__c> statusCheck = [
                    SELECT PDF_Downloaded__c FROM DocuSign_Status__c
                    WHERE Envelope_Id__c = :envelopeId LIMIT 1
                ];
                if (!statusCheck.isEmpty() && statusCheck[0].PDF_Downloaded__c == true) {
                    System.debug(LoggingLevel.INFO, '[SignedPdfQueueable] FullySigned PDF already downloaded — skipping');
                    return;
                }
            }
            
            String accountId   = getConfiguredAccountId();
            String environment = getConfiguredEnvironment();
            String apiNc       = DocuSignConfigService.getApiNamedCredential(environment);
            String apiVersion  = DocuSignConfigService.getApiVersion();
            
            List<Agreement__c> agrs = Security.stripInaccessible(
                AccessType.READABLE,
                [SELECT Name FROM Agreement__c WHERE Id = :agreementId LIMIT 1]
            ).getRecords();
            String agreementName = agrs.isEmpty() ? 'Agreement' : ((Agreement__c) agrs[0]).Name;
            
            // ── LIST DOCUMENTS ────────────────────────────────────────────────────────
            HttpRequest listReq = new HttpRequest();
            listReq.setEndpoint(apiNc + '/restapi/' + apiVersion + '/accounts/' + accountId
                                + '/envelopes/' + envelopeId + '/documents');
            listReq.setMethod('GET');
            listReq.setTimeout(30000);
            
            HttpResponse listRes;
            try {
                listRes = new Http().send(listReq);
            } catch (Exception e) {
                System.debug(LoggingLevel.ERROR, '[SignedPdfQueueable] Doc list callout failed: ' + e.getMessage());
                return;
            }
            if (listRes.getStatusCode() != 200) {
                System.debug(LoggingLevel.ERROR, '[SignedPdfQueueable] Doc list failed | status='
                             + listRes.getStatusCode() + ' | body=' + listRes.getBody());
                return;
            }
            
            Map<String, Object> listResp = (Map<String, Object>) JSON.deserializeUntyped(listRes.getBody());
            List<Object> docs = (List<Object>) listResp.get('envelopeDocuments');
            if (docs == null || docs.isEmpty()) {
                System.debug(LoggingLevel.WARN, '[SignedPdfQueueable] No documents in envelope');
                return;
            }
            
            //  BUILD TITLES 
            Set<String>         seenBaseNames = new Set<String>();
            Map<String, String> docIdToTitle  = new Map<String, String>();
            for (Object d : docs) {
                Map<String, Object> doc   = (Map<String, Object>) d;
                String              docId = (String) doc.get('documentId');
                if (docId == 'certificate' || docId == 'combined') continue;
                docIdToTitle.put(docId, buildPdfTitle(
                    agreementName, (String) doc.get('name'), docId, statusSuffix, seenBaseNames, envelopeId));
            }
            
            System.debug(LoggingLevel.INFO, '[SignedPdfQueueable] DocuSign returned '
                         + docs.size() + ' document(s) for envelope ' + envelopeId);
            for (Object d : docs) {
                Map<String, Object> doc = (Map<String, Object>) d;
                System.debug(LoggingLevel.INFO, '[SignedPdfQueueable]   → docId=' + doc.get('documentId')
                             + ' | name=' + doc.get('name')
                             + ' | resolvedTitle=' + docIdToTitle.get((String) doc.get('documentId')));
            }
            
            //  DOWNLOAD ALL BLOBS (no DML yet) 
            List<ContentVersionDraft> drafts = new List<ContentVersionDraft>();
            for (Object d : docs) {
                Map<String, Object> doc   = (Map<String, Object>) d;
                String              docId = (String) doc.get('documentId');
                if (docId == 'certificate' || docId == 'combined') continue;
                String finalTitle = docIdToTitle.get(docId);
                if (finalTitle == null) {
                    System.debug(LoggingLevel.WARN, '[SignedPdfQueueable] No title resolved for docId=' + docId + ' — skipping');
                    continue;
                }
                try {
                    HttpRequest req = new HttpRequest();
                    req.setEndpoint(apiNc + '/restapi/' + apiVersion + '/accounts/' + accountId
                                    + '/envelopes/' + envelopeId + '/documents/' + docId);
                    req.setMethod('GET');
                    req.setTimeout(30000);
                    HttpResponse res = new Http().send(req);
                    if (res.getStatusCode() != 200) {
                        System.debug(LoggingLevel.ERROR, '[SignedPdfQueueable] Download failed | docId=' + docId
                                     + ' | status=' + res.getStatusCode() + ' | body=' + res.getBody());
                        continue;
                    }
                    drafts.add(new ContentVersionDraft(finalTitle, res.getBodyAsBlob()));
                    System.debug(LoggingLevel.INFO, '[SignedPdfQueueable] Downloaded blob: '
                                 + finalTitle + ' (' + res.getBodyAsBlob().size() + ' bytes)');
                } catch (Exception e) {
                    System.debug(LoggingLevel.ERROR, '[SignedPdfQueueable] Callout exception | docId='
                                 + docId + ' | ' + e.getMessage());
                }
            }
            Id initiatedBy = null;
            try {
                List<DocuSign_Status__c> statusRecs = [
                    SELECT Initiated_By__c FROM DocuSign_Status__c
                    WHERE Envelope_Id__c = :envelopeId LIMIT 1
                ];
                if (!statusRecs.isEmpty() && statusRecs[0].Initiated_By__c != null) {
                    initiatedBy = statusRecs[0].Initiated_By__c;
                }
            } catch (Exception e) {
                System.debug(LoggingLevel.WARN, '[SignedPdfQueueable] Could not load initiator: ' + e.getMessage());
            }
            if (initiatedBy == null) {
                System.debug(LoggingLevel.WARN, '[SignedPdfQueueable] Initiated_By__c is null for envelope '
                             + envelopeId + ' — OwnerId will not be set explicitly.');
            }
            
            //  BUILD + INSERT FILES (single bulk DML via without-sharing helper) 
            List<ContentVersion> toInsert = new List<ContentVersion>();
            for (ContentVersionDraft draft : drafts) {
                ContentVersion cv         = new ContentVersion();
                cv.Title                  = draft.title;
                cv.PathOnClient           = draft.title + '.pdf';
                cv.VersionData            = draft.bodyBlob;
                cv.FirstPublishLocationId = agreementId;
                if (initiatedBy != null) {
                    cv.OwnerId = initiatedBy;
                }
                toInsert.add(cv);
            }
            
            Integer savedCount  = 0;
            Integer failedCount = 0;
            if (!toInsert.isEmpty()) {
                try {
                    // without sharing helper preserves OwnerId in async/scheduler context
                    new ContentVersionInsertHelper().insertAll(toInsert);
                    savedCount = toInsert.size();
                    System.debug(LoggingLevel.INFO, '[SignedPdfQueueable] Saved ' + savedCount
                                 + ' file(s) | owner=' + initiatedBy);
                } catch (Exception e) {
                    failedCount = toInsert.size();
                    System.debug(LoggingLevel.ERROR, '[SignedPdfQueueable] Bulk insert failed: ' + e.getMessage());
                }
            }
            
            System.debug(LoggingLevel.INFO, '[SignedPdfQueueable] Done | saved=' + savedCount
                         + ' | failed=' + failedCount
                         + ' | skipped=' + (docs.size() - drafts.size()));
            
            if (isFullySigned && savedCount > 0 && failedCount == 0) {
                try {
                    List<DocuSign_Status__c> sr = [
                        SELECT Id FROM DocuSign_Status__c
                        WHERE Envelope_Id__c = :envelopeId LIMIT 1
                    ];
                    if (!sr.isEmpty()) {
                        sr[0].PDF_Downloaded__c = true;
                        update sr[0];
                        System.debug(LoggingLevel.INFO, '[SignedPdfQueueable] PDF_Downloaded__c set true for ' + envelopeId);
                    }
                } catch (Exception ex) {
                    System.debug(LoggingLevel.WARN, '[SignedPdfQueueable] Could not update PDF_Downloaded__c: ' + ex.getMessage());
                }
            } else if (isFullySigned && failedCount > 0) {
                System.debug(LoggingLevel.WARN, '[SignedPdfQueueable] ' + failedCount
                             + ' doc(s) failed — PDF_Downloaded__c NOT set, watchdog will retry.');
            }
        }
    }
    
    /** BULK SIGNED PDF QUEUEABLE  (chains through a list of envelopes) **/
    public class BulkSignedPdfQueueable implements Queueable, Database.AllowsCallouts {
        private List<String> envelopeIds;
        private List<Id>     agreementIds;
        private List<String> statusSuffixes;
        private Integer      index;
        
        public BulkSignedPdfQueueable(List<String> envelopeIds, List<Id> agreementIds, List<String> statusSuffixes) {
            this.envelopeIds    = envelopeIds;
            this.agreementIds   = agreementIds;
            this.statusSuffixes = statusSuffixes;
            this.index          = 0;
        }
        private BulkSignedPdfQueueable(List<String> envelopeIds, List<Id> agreementIds, List<String> statusSuffixes, Integer index) {
            this.envelopeIds    = envelopeIds;
            this.agreementIds   = agreementIds;
            this.statusSuffixes = statusSuffixes;
            this.index          = index;
        }
        
        public void execute(QueueableContext ctx) {
            if (index >= envelopeIds.size()) return;
            
            String  envelopeId   = envelopeIds[index];
            Id      agreementId  = agreementIds[index];
            String  statusSuffix = (statusSuffixes != null
                                    && index < statusSuffixes.size()
                                    && String.isNotBlank(statusSuffixes[index]))
                ? normalizeStatusSuffix(statusSuffixes[index])
                : 'FullySigned';
            Boolean isFullySigned = statusSuffix != null && statusSuffix.contains('FullySigned');
            
            System.debug(LoggingLevel.INFO, '[BulkSignedPdfQueueable] Processing ' + (index + 1)
                         + ' of ' + envelopeIds.size()
                         + ' | envelopeId=' + envelopeId
                         + ' | statusSuffix=' + statusSuffix);
            Id initiatedBy = resolveInitiatedBy(envelopeId);
            System.debug(LoggingLevel.INFO, '[BulkSignedPdfQueueable] Resolved initiatedBy=' + initiatedBy
                         + ' for envelope=' + envelopeId);
            
            //  DUPLICATE GUARD 
            if (isFullySigned) {
                List<DocuSign_Status__c> statusCheck = [
                    SELECT PDF_Downloaded__c FROM DocuSign_Status__c
                    WHERE Envelope_Id__c = :envelopeId LIMIT 1
                ];
                if (!statusCheck.isEmpty() && statusCheck[0].PDF_Downloaded__c == true) {
                    System.debug(LoggingLevel.INFO, '[BulkSignedPdfQueueable] Already downloaded — skipping envelope ' + envelopeId);
                    chainNext();
                    return;
                }
            }
            
            try {
                String accountId   = getConfiguredAccountId();
                String environment = getConfiguredEnvironment();
                String apiNc       = DocuSignConfigService.getApiNamedCredential(environment);
                String apiVersion  = DocuSignConfigService.getApiVersion();
                
                List<Agreement__c> agrs = Security.stripInaccessible(
                    AccessType.READABLE,
                    [SELECT Name FROM Agreement__c WHERE Id = :agreementId LIMIT 1]
                ).getRecords();
                String agreementName = agrs.isEmpty() ? 'Agreement' : ((Agreement__c) agrs[0]).Name;
                
                //  LIST DOCUMENTS 
                HttpRequest listReq = new HttpRequest();
                listReq.setEndpoint(apiNc + '/restapi/' + apiVersion + '/accounts/' + accountId
                                    + '/envelopes/' + envelopeId + '/documents');
                listReq.setMethod('GET');
                listReq.setTimeout(30000);
                HttpResponse listRes = new Http().send(listReq);
                if (listRes.getStatusCode() != 200) {
                    System.debug(LoggingLevel.ERROR, '[BulkSignedPdfQueueable] Doc list failed | status='
                                 + listRes.getStatusCode() + ' | body=' + listRes.getBody()
                                 + ' | envelope=' + envelopeId);
                    chainNext();
                    return;
                }
                
                Map<String, Object> listResp = (Map<String, Object>) JSON.deserializeUntyped(listRes.getBody());
                List<Object> docs = (List<Object>) listResp.get('envelopeDocuments');
                if (docs == null || docs.isEmpty()) {
                    System.debug(LoggingLevel.WARN, '[BulkSignedPdfQueueable] No documents found for envelope ' + envelopeId);
                    chainNext();
                    return;
                }
                
                //  BUILD TITLES 
                Set<String>         seenBaseNames = new Set<String>();
                Map<String, String> docIdToTitle  = new Map<String, String>();
                for (Object d : docs) {
                    Map<String, Object> doc   = (Map<String, Object>) d;
                    String              docId = (String) doc.get('documentId');
                    if (docId == 'certificate' || docId == 'combined') continue;
                    docIdToTitle.put(docId, buildPdfTitle(
                        agreementName, (String) doc.get('name'), docId, statusSuffix, seenBaseNames, envelopeId));
                }
                
                System.debug(LoggingLevel.INFO, '[BulkSignedPdfQueueable] DocuSign returned '
                             + docs.size() + ' document(s) for envelope ' + envelopeId);
                for (Object d : docs) {
                    Map<String, Object> doc = (Map<String, Object>) d;
                    System.debug(LoggingLevel.INFO, '[BulkSignedPdfQueueable]   → docId=' + doc.get('documentId')
                                 + ' | name=' + doc.get('name')
                                 + ' | resolvedTitle=' + docIdToTitle.get((String) doc.get('documentId')));
                }
                
                //  DOWNLOAD ALL BLOBS (no DML yet) 
                List<ContentVersionDraft> drafts = new List<ContentVersionDraft>();
                for (Object d : docs) {
                    Map<String, Object> doc   = (Map<String, Object>) d;
                    String              docId = (String) doc.get('documentId');
                    if (docId == 'certificate' || docId == 'combined') continue;
                    String finalTitle = docIdToTitle.get(docId);
                    if (finalTitle == null) {
                        System.debug(LoggingLevel.WARN, '[BulkSignedPdfQueueable] No title for docId=' + docId + ' — skipping');
                        continue;
                    }
                    try {
                        HttpRequest req = new HttpRequest();
                        req.setEndpoint(apiNc + '/restapi/' + apiVersion + '/accounts/' + accountId
                                        + '/envelopes/' + envelopeId + '/documents/' + docId);
                        req.setMethod('GET');
                        req.setTimeout(30000);
                        HttpResponse res = new Http().send(req);
                        if (res.getStatusCode() != 200) {
                            System.debug(LoggingLevel.ERROR, '[BulkSignedPdfQueueable] Download failed | docId=' + docId
                                         + ' | status=' + res.getStatusCode() + ' | body=' + res.getBody()
                                         + ' | envelope=' + envelopeId);
                            continue;
                        }
                        drafts.add(new ContentVersionDraft(finalTitle, res.getBodyAsBlob()));
                        System.debug(LoggingLevel.INFO, '[BulkSignedPdfQueueable] Downloaded blob: '
                                     + finalTitle + ' (' + res.getBodyAsBlob().size() + ' bytes)');
                    } catch (Exception e) {
                        System.debug(LoggingLevel.ERROR, '[BulkSignedPdfQueueable] Callout exception | docId='
                                     + docId + ' | ' + e.getMessage());
                    }
                }
                
                //  BUILD ContentVersion LIST 
                List<ContentVersion> toInsert = new List<ContentVersion>();
                for (ContentVersionDraft draft : drafts) {
                    ContentVersion cv         = new ContentVersion();
                    cv.Title                  = draft.title;
                    cv.PathOnClient           = draft.title + '.pdf';
                    cv.VersionData            = draft.bodyBlob;
                    cv.FirstPublishLocationId = agreementId;
                    // OwnerId: always use Initiated_By__c — never fall back to running user
                    if (initiatedBy != null) {
                        cv.OwnerId = initiatedBy;
                    }
                    toInsert.add(cv);
                }
                
                Integer savedCount  = 0;
                Integer failedCount = 0;
                if (!toInsert.isEmpty()) {
                    try {
                        new ContentVersionInsertHelper().insertWithOwner(toInsert, initiatedBy);
                        savedCount = toInsert.size();
                        System.debug(LoggingLevel.INFO, '[BulkSignedPdfQueueable] Saved ' + savedCount
                                     + ' file(s) | envelope=' + envelopeId + ' | owner=' + initiatedBy);
                    } catch (Exception e) {
                        failedCount = toInsert.size();
                        System.debug(LoggingLevel.ERROR, '[BulkSignedPdfQueueable] Bulk insert failed | envelope='
                                     + envelopeId + ' | ' + e.getMessage());
                    }
                }
                
                System.debug(LoggingLevel.INFO, '[BulkSignedPdfQueueable] Done | envelope=' + envelopeId
                             + ' | saved=' + savedCount + ' | failed=' + failedCount);
                //  FLAG PDF_Downloaded__c 
                if (isFullySigned && savedCount > 0 && failedCount == 0) {
                    try {
                        List<DocuSign_Status__c> sr = [
                            SELECT Id FROM DocuSign_Status__c
                            WHERE Envelope_Id__c = :envelopeId LIMIT 1
                        ];
                        if (!sr.isEmpty()) {
                            sr[0].PDF_Downloaded__c = true;
                            update sr[0];
                            System.debug(LoggingLevel.INFO, '[BulkSignedPdfQueueable] PDF_Downloaded__c set true for ' + envelopeId);
                        }
                    } catch (Exception ex) {
                        System.debug(LoggingLevel.WARN, '[BulkSignedPdfQueueable] Could not update PDF_Downloaded__c: ' + ex.getMessage());
                    }
                } else if (isFullySigned && failedCount > 0) {
                    System.debug(LoggingLevel.WARN, '[BulkSignedPdfQueueable] ' + failedCount
                                 + ' doc(s) failed — PDF_Downloaded__c NOT set, watchdog will retry.');
                }
                
            } catch (Exception e) {
                System.debug(LoggingLevel.ERROR, '[BulkSignedPdfQueueable] Outer error | envelope=' + envelopeId
                             + ' | ' + e.getMessage() + '\n' + e.getStackTraceString());
            }
            
            chainNext();
        }
        private Id resolveInitiatedBy(String envelopeId) {
            try {
                List<DocuSign_Status__c> statusRecs = [
                    SELECT Initiated_By__c FROM DocuSign_Status__c
                    WHERE Envelope_Id__c = :envelopeId LIMIT 1
                ];
                if (!statusRecs.isEmpty() && statusRecs[0].Initiated_By__c != null) {
                    return statusRecs[0].Initiated_By__c;
                }
            } catch (Exception e) {
                System.debug(LoggingLevel.WARN, '[BulkSignedPdfQueueable] resolveInitiatedBy failed: ' + e.getMessage());
            }
            System.debug(LoggingLevel.WARN, '[BulkSignedPdfQueueable] Initiated_By__c is null for envelope '
                         + envelopeId + ' — OwnerId will not be set explicitly.');
            return null;
        }
        private void chainNext() {
            Integer nextIndex = index + 1;
            if (nextIndex < envelopeIds.size()) {
                try {
                    System.enqueueJob(new BulkSignedPdfQueueable(envelopeIds, agreementIds, statusSuffixes, nextIndex));
                } catch (AsyncException e) {
                    System.debug(LoggingLevel.WARN, '[BulkSignedPdfQueueable] Cannot chain: ' + e.getMessage());
                }
            }
        }
    }
    /** STATUS EVENT HANDLERS**/
    public static void handleRecipientCompleted(Agreement__c agreement, String envelopeId) {
        if (agreement == null) return;
        agreement.Status__c = 'In Signature';
        agreement.Status_Group__c = 'In Signature';
        SObjectAccessDecision dec = Security.stripInaccessible(AccessType.UPDATABLE, new List<Agreement__c>{ agreement });
        if (!dec.getRecords().isEmpty())
            update dec.getRecords();
    }
    
    public static void handleEnvelopeCompleted(Agreement__c agreement, String envelopeId) {
        if (agreement == null) return;
        agreement.Status__c = 'Fully Signed';
        agreement.Status_Group__c = 'In Signature';
        SObjectAccessDecision dec = Security.stripInaccessible(AccessType.UPDATABLE, new List<Agreement__c>{ agreement });
        if (!dec.getRecords().isEmpty())
            update dec.getRecords();
        System.enqueueJob(new SignedPdfQueueable(envelopeId, agreement.Id, 'FullySigned'));
    }
    
    /** ACTIVITY HELPERS**/
    public static void createActivity(Id agreementId, String subject, String description) {
        createActivity(agreementId, UserInfo.getUserId(), null, subject, description);
    }
    public static void createActivity(Id agreementId, Id userId, String envelopeId, String subject) {
        String descs = String.isNotBlank(envelopeId) ? 'DocuSign envelope ID: ' + envelopeId : subject;
        createActivity(agreementId, userId, envelopeId, subject, descs);
    }
    public static void createActivity(Id agreementId, Id userId, String envelopeId, String subject, String description) {
        if (agreementId == null || String.isBlank(subject)) return;
        String finalSubject = subject;
        if (subject.contains('Viewed') || subject.contains('Partially Signed') || subject.contains('Recipient Signed') || subject.contains('Recipient Declined') || subject.contains('Document Viewed') || subject.contains('Copy Sent')) {
            if (String.isNotBlank(description)) {
                String token = description.length() > 40 ? description.left(40).trim() : description.trim();
                finalSubject = subject + ' — ' + token;
            }
        }
        if (finalSubject.length() > 255)
            finalSubject = finalSubject.left(255);
        List<Task> existing;
        if (String.isNotBlank(envelopeId)) {
            existing = [SELECT Id FROM Task WHERE WhatId = :agreementId AND Subject = :finalSubject AND ActivityDate = TODAY AND CallObject = :envelopeId LIMIT 1];
        } else {
            existing = [SELECT Id FROM Task WHERE WhatId = :agreementId AND Subject = :finalSubject AND ActivityDate = TODAY LIMIT 1];
        }
        if (!existing.isEmpty()) {
            System.debug(LoggingLevel.DEBUG, '[DocuSignAgreementService.createActivity] Duplicate skipped: ' + finalSubject);
            return;
        }
        Task t = new Task(WhatId = agreementId, OwnerId = userId != null ? userId : UserInfo.getUserId(), Subject = finalSubject, Description = description, CallObject = envelopeId, Status = 'Completed', ActivityDate = Date.today(), Priority = 'Normal');
        SObjectAccessDecision decision = Security.stripInaccessible(AccessType.CREATABLE, new List<Task>{ t });
        insert decision.getRecords();
        System.debug(LoggingLevel.DEBUG, '[DocuSignAgreementService.createActivity] Created: ' + finalSubject);
    }
    
    public static void createActivitiesBulk(List<List<Object>> queue) {
        if (queue == null || queue.isEmpty()) return;
        List<Map<String, Object>> entries = new List<Map<String, Object>>();
        Set<Id> agrIds = new Set<Id>();
        for (List<Object> params : queue) {
            Id agrId = (Id) params[0];
            Id userId = (Id) params[1];
            String envelopeId = (String) params[2];
            String subject = (String) params[3];
            String description = (String) params[4];
            if (agrId == null || String.isBlank(subject)) continue;
            String finalSubject = subject;
            if (subject.contains('Viewed') || subject.contains('Partially Signed') || subject.contains('Recipient Signed') 
                || subject.contains('Recipient Declined') || subject.contains('Recipient Sent') || 
                subject.contains('Recipient Delivered') || subject.contains('Recipient Auth') || subject.contains('Recipient Auto')
                || subject.contains('Viewer Sent') || subject.contains('Document Viewed') || subject.contains('Copy Sent') || 
                subject.contains('Resent')) {
                    if (String.isNotBlank(description)) {
                        String token = description.length() > 40 ? description.left(40).trim() : description.trim();
                        finalSubject = subject + ' — ' + token;
                    }
                }
            if (finalSubject.length() > 255)
                finalSubject = finalSubject.left(255);
            agrIds.add(agrId);
            entries.add(new Map<String, Object>{ 'agrId' => agrId, 'userId' => userId, 'envelopeId' => envelopeId, 'subject' => finalSubject, 'description' => description });
        }
        if (entries.isEmpty())
            return;
        Set<String> existingKeys = new Set<String>();
        for (Task t : [SELECT WhatId, Subject, CallObject FROM Task WHERE WhatId IN :agrIds AND ActivityDate = TODAY]) {
            existingKeys.add((String) t.WhatId + '|' + t.Subject + '|' + (String.isNotBlank(t.CallObject) ? t.CallObject : ''));
        }
        List<Task> toInsert = new List<Task>();
        for (Map<String, Object> e : entries) {
            Id agrId = (Id) e.get('agrId');
            String envelopeId = (String) e.get('envelopeId');
            String subject = (String) e.get('subject');
            String dedupeEnv = String.isNotBlank(envelopeId) ? envelopeId : '';
            String key = (String) agrId + '|' + subject + '|' + dedupeEnv;
            if (existingKeys.contains(key)) {
                System.debug(LoggingLevel.DEBUG, '[DocuSignAgreementService.createActivitiesBulk] Duplicate skipped: ' + subject);
                continue;
            }
            existingKeys.add(key);
            Id ownerId = e.get('userId') != null ? (Id) e.get('userId') : UserInfo.getUserId();
            toInsert.add(new Task(WhatId = agrId, OwnerId = ownerId, Subject = subject, Description = (String) e.get('description'), CallObject = String.isNotBlank(envelopeId) ? envelopeId : null, Status = 'Completed', ActivityDate = Date.today(), Priority = 'Normal'));
        }
        if (!toInsert.isEmpty()) {
            SObjectAccessDecision dec = Security.stripInaccessible(AccessType.CREATABLE, toInsert);
            insert dec.getRecords();
            System.debug(LoggingLevel.DEBUG, '[DocuSignAgreementService.createActivitiesBulk] Inserted ' + dec.getRecords().size() + ' task(s).');
        }
    }
    /** PRIVATE CALLOUT HELPER **/
    private static HttpResponse doCallout(String namedCredential, String method, String path, String body) {
        HttpRequest req = new HttpRequest();
        req.setEndpoint(namedCredential + path);
        req.setMethod(method);
        req.setHeader('Content-Type', 'application/json');
        req.setTimeout(30000);
        if (String.isNotBlank(body))
            req.setBody(body);
        HttpResponse res = new Http().send(req);
        System.debug(LoggingLevel.INFO, '[AgreementDocuSignService.doCallout] ' + method + ' ' + path + ' → ' + res.getStatusCode());
        return res;
    }
    /*** PAYLOAD BUILDERS**/
    private static List<Object> buildDocuments(List<AgreementFileDTO> files) {
        List<Object> docs = new List<Object>();
        if (files == null || files.isEmpty())
            return docs;
        Set<Id> cvIds = new Set<Id>();
        for (AgreementFileDTO f : files) {
            if (f != null && f.contentVersionId != null)
                cvIds.add(f.contentVersionId);
        }
        List<ContentVersion> cvList = [SELECT Id, VersionData, Title, FileExtension FROM ContentVersion WHERE Id IN :cvIds];    Map<Id, ContentVersion> cvMap = new Map<Id, ContentVersion>();
        for (ContentVersion cv : cvList) cvMap.put(cv.Id, cv);
        Integer i = 1;
        for (AgreementFileDTO f : files) {
            if (f == null) continue;
            ContentVersion cv = cvMap.get(f.contentVersionId);
            if (cv == null) continue;
            docs.add(new Map<String, Object>{ 'documentBase64' => EncodingUtil.base64Encode(cv.VersionData), 'name' => cv.Title, 'fileExtension' => cv.FileExtension, 'documentId' => String.valueOf(i++) });
        }
        return docs;
    }
    private static Map<String, Object> buildRecipients(List<RecipientDTO> recs) {
        List<Object> signers = new List<Object>();
        List<Object> copies = new List<Object>();
        List<Object> viewers = new List<Object>();
        Integer counter = 1;
        for (RecipientDTO r : recs) {
            if (r == null || String.isBlank(r.email) || String.isBlank(r.name)) continue;
            Map<String, Object> rec = new Map<String, Object>{ 'name' => r.name, 'email' => r.email, 'routingOrder' => String.valueOf(r.routingOrder == null ? 1 : r.routingOrder), 'recipientId' => String.valueOf(counter++) };
                String role = String.isBlank(r.role) ? 'signer' : r.role.toLowerCase();
            if (role == 'copy') copies.add(rec);
            else if (role == 'viewer') viewers.add(rec);
            else signers.add(rec);
        }
        return new Map<String, Object>{ 'signers' => signers, 'carbonCopies' => copies, 'certifiedDeliveries' => viewers };
            }
    
    private static Map<String, Object> buildNotification(Integer rem, Integer exp) {
        Integer r = rem == null ? 3 : rem;
        Integer e = exp == null ? 30 : exp;
        return new Map<String, Object>{ 'reminders' => new Map<String, Object>{ 'reminderEnabled' => true, 'reminderDelay' => r, 'reminderFrequency' => r }, 'expirations' => new Map<String, Object>{ 'expireEnabled' => true, 'expireAfter' => e } };
            }
    
    /** STATUS + UTILITY HELPERS**/
    private static String mapStatus(String dsStatus) {
        if (String.isBlank(dsStatus))
            return 'Draft';
        switch on dsStatus.toLowerCase() {
            when 'sent' {return 'Sent';}
            when 'delivered' {return 'Delivered';}
            when 'completed' {return 'Completed';}
            when 'declined' {return 'Declined';}
            when 'voided' {return 'Voided';}
            when else {return 'Draft';}
        }
    }
    
    private static Boolean hasMultipleSigners(String envelopeId) {
        List<DocuSign_Status__c> recs = [SELECT Recipients_JSON__c FROM DocuSign_Status__c WHERE Envelope_Id__c = :envelopeId LIMIT 1];
        if (recs.isEmpty() || String.isBlank(recs[0].Recipients_JSON__c))
            return false;
        List<Object> recipients = (List<Object>) JSON.deserializeUntyped(recs[0].Recipients_JSON__c);
        Integer signerCount = 0;
        for (Object r : recipients) {
            Map<String, Object> rec = (Map<String, Object>) r;
            String role = (String) rec.get('role');
            if (role == null || role.toLowerCase() == 'signer')
                signerCount++;
        }
        return signerCount > 1;
    }
    
    private static String normalizeStatusSuffix(String s) {
        if (s == 'FullySigned' || s == 'PartiallySigned')
            return s;
        if (s != null && s.startsWith('partiallySigned_'))
            return s;
        return String.isNotBlank(s) ? s : 'FullySigned';
    }
    // Lightweight struct to hold a downloaded blob before DML
    private class ContentVersionDraft {
        String title;
        Blob bodyBlob;
        ContentVersionDraft(String t, Blob b) {
            this.title = t;
            this.bodyBlob = b;
        }
    }
    /** buildPdfTitle*/
    @TestVisible
    private static String buildPdfTitle(String agreementName, String rawDocName, String docId, String statusSuffix, Set<String> seenBaseNames, String envelopeId) {
        String cleanName = String.isBlank(rawDocName) ? 'Document' : rawDocName.trim();
        if (cleanName.equalsIgnoreCase('Adobe PDF'))
            cleanName = 'Document';
        // Strip signed-status artifacts from the doc name
        cleanName = cleanName.replace('Signed - ', '');
        cleanName = cleanName.replace('_FullySigned', '');
        cleanName = cleanName.replace('_PartiallySigned', '');
        cleanName = cleanName.replace('_partiallySigned', '');
        cleanName = cleanName.replaceAll('_?\\d+of\\d+', '');
        if (String.isNotBlank(agreementName)) {
            String prefixWithUnderscore = agreementName + '_';
            if (cleanName.startsWith(prefixWithUnderscore)) {
                cleanName = cleanName.substring(prefixWithUnderscore.length());
            } else if (cleanName.equals(agreementName)) {
                // exact match with no suffix → use a generic label
                cleanName = 'Document';
            }
        }
        cleanName = cleanName.replaceAll('_{2,}', '_').removeStart('_').removeEnd('_').trim();
        if (String.isBlank(cleanName))
            cleanName = 'Document';
        // Normalise status suffix
        String finalSuffix;
        if (statusSuffix == 'FullySigned') {
            finalSuffix = 'FullySigned';
        } else if (statusSuffix != null && statusSuffix.startsWith('partiallySigned_')) {
            finalSuffix = statusSuffix;
        } else if (statusSuffix == 'PartiallySigned') {
            finalSuffix = 'partiallySigned';
        } else {
            finalSuffix = String.isNotBlank(statusSuffix) ? statusSuffix : 'Signed';
        }
        String baseTitle = agreementName + '_' + cleanName + '_' + finalSuffix;
        String finalTitle = baseTitle;
        if (seenBaseNames != null && seenBaseNames.contains(finalTitle)) {
            finalTitle = baseTitle + '_doc' + docId;
        }
        if (seenBaseNames != null)
            seenBaseNames.add(finalTitle);
        return finalTitle;
    }
    @AuraEnabled(cacheable=true)
    public static Boolean isPollingActive() {
        return DocuSignPollingScheduler.isPollingActive();
    }
    private static String getConfiguredAccountId() {
        DocuSign_Config__mdt cfg = DocuSignConfigService.getConfig();
        if (!cfg.Active__c || String.isBlank(cfg.DocuSign_API_Account_ID__c)) {
            throw new DocuSignServiceException('No DocuSign account configured in Custom Metadata.');
        }
        return cfg.DocuSign_API_Account_ID__c;
    }
    private static String getConfiguredEnvironment() {
        return DocuSignConfigService.detectEnvironment();
    }
    public without sharing class ContentVersionInsertHelper {
        public void insertWithOwner(List<ContentVersion> records, Id ownerIdFallback) {
            if (records == null || records.isEmpty()) return;
            if (ownerIdFallback != null) {
                for (ContentVersion cv : records) {
                    cv.OwnerId = ownerIdFallback;
                }
            }
            insert records;
        }
        public void insertAll(List<ContentVersion> records) {
            if (records == null || records.isEmpty()) return;
            insert records;
        }
    }
}