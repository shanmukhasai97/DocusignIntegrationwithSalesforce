/**
 * REST webhook handler for processing DocuSign Connect events, including HMAC signature validation,
 * payload normalization, caching, and bulk-safe asynchronous processing to update Agreements,
 * envelope statuses, and related activities with retry and deduplication logic.
 */
@RestResource(urlMapping='/docusign/webhook')
global without sharing class DocuSignWebhookHandler {
    // Configuration constants
    private static final Integer MAX_RETRIES = 3;
    private static final Integer INITIAL_BACKOFF_MS = 1000;
    // The partition name you should create under Setup -> Platform Cache
    private static final String CACHE_PARTITION = 'DocuSignCache';
    private static final Integer CACHE_TTL_SECONDS = 3600;
    private static final Boolean REQUIRE_SIGNATURE_IF_HEADER_PRESENT = true;
    // In-memory fallback cache (per-transaction) when Platform Cache partition is missing.
    private static Map<String, Object> fallbackCache = new Map<String, Object>();
    @HttpPost
    global static void handleEvent() {
        // Always return 200 to DocuSign quickly 
        RestContext.response.statusCode = 200;
        String rawBody = RestContext.request.requestBody.toString();
        logDebug('DOCUSIGN RAW PAYLOAD => ' + rawBody);
        try {
            String payload = RestContext.request?.requestBody?.toString();
            if (String.isBlank(payload)) {
                logDebug('Empty payload received');
                return;
            }
            // Validate HMAC signature
            if (!isValidSignature(payload)) {
                logWarning('Invalid or missing HMAC signature - aborting processing');
                return;
            }
            // Parse and bulkify processing
            System.enqueueJob(new WebhookProcessorQueueable(payload));
        } catch (Exception e) {
            logError('Webhook processing failed: ' + e.getMessage() + '\n' + e.getStackTraceString());
        }
    }
    private static void processWebhookPayload(String payload) {
        try {
            Object parsed = JSON.deserializeUntyped(payload);
            List<Map<String, Object>> notifications = normalizePayload(parsed);
            if (notifications.isEmpty()) {
                logDebug('No valid notifications to process');
                return;
            }
            
            Set<String> envelopeIds = new Set<String>();
            for (Map<String, Object> notification : notifications) {
                Map<String, Object> envelopeStatus = getEnvelopeStatus(notification);
                if (envelopeStatus == null) continue;
                String envelopeId = (String) envelopeStatus.get('envelopeId');
                String eventType  = (String) notification.get('event');
                if (String.isNotBlank(envelopeId) && isValidEventType(eventType)) {
                    envelopeIds.add(envelopeId);
                }
            }
            if (envelopeIds.isEmpty()) {
                logDebug('No valid envelope IDs found');
                return;
            }
            
            Map<String, Agreement__c> agreementsByEnvelopeId = getAgreementsByEnvelopeIds(envelopeIds);
            if (agreementsByEnvelopeId.isEmpty()) {
                logDebug('No matching Agreements found for envelope IDs: ' + envelopeIds);
                return;
            }
            
            Map<String, DocuSign_Status__c> envelopeMap = new Map<String, DocuSign_Status__c>();
            for (DocuSign_Status__c env : [SELECT Id, Envelope_Id__c, Agreement__c, Status__c, Completed_DateTime__c, Declined_DateTime__c, Voided_DateTime__c FROM DocuSign_Status__c WHERE Envelope_Id__c IN :envelopeIds]) {
                envelopeMap.put(env.Envelope_Id__c, env);
            }
            
            List<List<Object>>       activityQueue       = new List<List<Object>>();
            List<Agreement__c>       agreementsToUpdate  = new List<Agreement__c>();
            List<DocuSign_Status__c> envelopesToUpdate   = new List<DocuSign_Status__c>();
            
            for (Map<String, Object> notification : notifications) {
                String eventType = (String) notification.get('event');
                Map<String, Object> envelopeStatus = getEnvelopeStatus(notification);
                if (envelopeStatus == null) continue;
                String envelopeId = (String) envelopeStatus.get('envelopeId');
                if (String.isBlank(envelopeId)) continue;
                
                Agreement__c       agreement = agreementsByEnvelopeId.get(envelopeId);
                DocuSign_Status__c env       = envelopeMap.get(envelopeId);
                
                String status = (String) envelopeStatus.get('status');
                if (String.isBlank(status)) {
                    status = (eventType == null) ? null : eventType.replace('envelope-', '').replace('recipient-', '');
                }
                if (String.isBlank(status)) continue;
                
                logDebug('Event received | type=' + eventType + ' | envelopeId=' + envelopeId + ' | status=' + status);
                if (env != null) {
                    String mappedStatus = mapDocuSignStatus(status);
                    env.Status__c = mappedStatus;
                    if (mappedStatus == 'Completed' && env.Completed_DateTime__c == null) {
                        env.Completed_DateTime__c = System.now();
                    } else if (mappedStatus == 'Declined' && env.Declined_DateTime__c == null) {
                        env.Declined_DateTime__c = System.now();
                    } else if (mappedStatus == 'Voided' && env.Voided_DateTime__c == null) {
                        env.Voided_DateTime__c = System.now();
                    }
                    envelopesToUpdate.add(env);
                }
                
                if (agreement == null) continue;
                
                updateAgreementStatusFromWebhook(agreement, status, eventType, envelopeId);
                
                String evtLower = eventType == null ? '' : eventType.toLowerCase();
                
                if (evtLower.contains('envelope-completed')) {
                    DocuSignAgreementService.handleEnvelopeCompleted(agreement, envelopeId);
                    
                } else if (evtLower.contains('recipient-completed')) {

                    DocuSignAgreementService.handleRecipientCompleted(agreement, envelopeId);
                    
                } else if (evtLower.contains('recipient-delivered')) {
                    agreement.Status__c       = 'In Signature';
                    agreement.Status_Group__c = 'In Signature';
                    String viewerInfo  = getRecipientInfo(notification);
                    String viewerLabel = String.isNotBlank(viewerInfo) ? viewerInfo : 'A recipient';
                    activityQueue.add(new List<Object>{
                        agreement.Id, UserInfo.getUserId(), envelopeId,
                            'Recipient Delivered — ' + viewerLabel,
                            viewerLabel + ' has opened and viewed the document.' + ' Envelope ID: ' + envelopeId });
                    
                } else if (evtLower.contains('envelope-declined')) {
                    agreement.Status__c       = 'Declined';
                    agreement.Status_Group__c = 'Closed';
                    // Subject matches polling ("Envelope Declined") — dedup-safe.
                    activityQueue.add(new List<Object>{
                        agreement.Id, UserInfo.getUserId(), envelopeId,
                            'Envelope Declined',
                            'A recipient declined to sign. Envelope ID: ' + envelopeId });
                    
                } else if (evtLower.contains('recipient-declined')) {
                    String signerInfo  = getRecipientInfo(notification);
                    String signerLabel = String.isNotBlank(signerInfo) ? signerInfo : 'A recipient';
                    // Subject matches polling ("Recipient Declined — <Name>") — dedup-safe.
                    activityQueue.add(new List<Object>{
                        agreement.Id, UserInfo.getUserId(), envelopeId,
                            'Recipient Declined — ' + signerLabel,
                            signerLabel + ' declined to sign the document.' + ' Envelope ID: ' + envelopeId });
                    
                } else if (evtLower.contains('envelope-voided')) {
                    agreement.Status__c       = 'Voided';
                    agreement.Status_Group__c = 'Closed';
                    // Subject matches polling ("Envelope Voided") — dedup-safe.
                    activityQueue.add(new List<Object>{
                        agreement.Id, UserInfo.getUserId(), envelopeId,
                            'Envelope Voided',
                            'The DocuSign envelope was voided. Envelope ID: ' + envelopeId });
                    
                } else if (evtLower.contains('envelope-sent')) {
                    agreement.Status__c       = 'Sent';
                    agreement.Status_Group__c = 'In Signature';
                    // Subject matches polling ("Envelope Sent") — dedup-safe.
                    activityQueue.add(new List<Object>{
                        agreement.Id, UserInfo.getUserId(), envelopeId,
                            'Envelope Sent',
                            'DocuSign envelope sent to recipients. Envelope ID: ' + envelopeId });
                    
                } else {
                    if (String.isNotBlank(eventType)) {
                        activityQueue.add(new List<Object>{
                            agreement.Id, UserInfo.getUserId(), envelopeId,
                                'DocuSign Event: ' + eventType,
                                'DocuSign event received. Type: ' + eventType + '. Status: ' + status + '. Envelope ID: ' + envelopeId });
                    }
                }
                
                agreementsToUpdate.add(agreement);
            }
            
            if (!agreementsToUpdate.isEmpty()) {
                updateAgreementsWithRetry(agreementsToUpdate);
            }
            if (!envelopesToUpdate.isEmpty()) {
                update Security.stripInaccessible(AccessType.UPDATABLE, envelopesToUpdate).getRecords();
            }
            if (!activityQueue.isEmpty()) {
                DocuSignAgreementService.createActivitiesBulk(activityQueue);
            }
            
            logDebug('Processed ' + notifications.size() + ' notification(s). '
                     + 'Agreements updated: ' + agreementsToUpdate.size() + '. '
                     + 'Envelopes updated: '  + envelopesToUpdate.size() + '. '
                     + 'Activities queued: '  + activityQueue.size() + '.');
            
        } catch (Exception e) {
            logError('processWebhookPayload error: ' + e.getMessage() + '\n' + e.getStackTraceString());
            throw e;
        }
    }
    // PAYLOAD NORMALIZATION
    private static List<Map<String, Object>> normalizePayload(Object parsed) {
        List<Map<String, Object>> notifications = new List<Map<String, Object>>();
        if (parsed instanceof List<Object>) {
            for (Object item : (List<Object>) parsed) {
                if (item instanceof Map<String, Object>) {
                    notifications.add((Map<String, Object>) item);
                }
            }
        } else if (parsed instanceof Map<String, Object>) {
            Map<String, Object> payloadMap = (Map<String, Object>) parsed;
            if (payloadMap.containsKey('envelopeEvents') && payloadMap.get('envelopeEvents') instanceof List<Object>) {
                for (Object eventItem : (List<Object>) payloadMap.get('envelopeEvents')) {
                    if (eventItem instanceof Map<String, Object>)
                        notifications.add((Map<String, Object>) eventItem);
                }
            } else {
                notifications.add(payloadMap);
            }
        }
        return notifications;
    }
    private static Map<String, Object> getEnvelopeStatus(Map<String, Object> notification) {
        if (notification.containsKey('envelopeStatus')) {
            return (Map<String, Object>) notification.get('envelopeStatus');
        } else if (notification.containsKey('data')) {
            Map<String, Object> data = (Map<String, Object>) notification.get('data');
            if (data != null) {
                if (data.containsKey('envelopeSummary')) {
                    return (Map<String, Object>) data.get('envelopeSummary');
                }
                if (data.containsKey('envelopeId')) {
                    return data;
                }
            }
        }
        return notification;
    }
    // CACHING LAYER
    private static Map<String, Agreement__c> getAgreementsByEnvelopeIds(Set<String> envelopeIds) {
        Map<String, Agreement__c> results = new Map<String, Agreement__c>();
        Set<String> uncachedIds = new Set<String>();
        for (String envelopeId : envelopeIds) {
            String cacheKey = 'agreement_' + envelopeId;
            Agreement__c cached = (Agreement__c) getCachedValue(cacheKey);
            if (cached != null) {
                results.put(envelopeId, cached);
            } else {
                uncachedIds.add(envelopeId);
            }
        }
        if (!uncachedIds.isEmpty()) {
            Map<String, Agreement__c> queried = queryAgreementsByEnvelopeIds(uncachedIds);
            for (String envelopeId : queried.keySet()) {
                Agreement__c agreement = queried.get(envelopeId);
                results.put(envelopeId, agreement);
                setCachedValue('agreement_' + envelopeId, agreement);
            }
        }
        return results;
    }
    private static Map<String, Agreement__c> queryAgreementsByEnvelopeIds(Set<String> envelopeIds) {
        Map<String, Agreement__c> result = new Map<String, Agreement__c>();
        for (DocuSign_Status__c env : [SELECT Envelope_Id__c, Agreement__r.Name, Agreement__r.Id, Agreement__r.Status__c, Agreement__r.Status_Group__c FROM DocuSign_Status__c WHERE Envelope_Id__c IN :envelopeIds]) {
            if (env.Agreement__r != null) {
                result.put(env.Envelope_Id__c, env.Agreement__r);
            }
        }
        return result;
    }
    private static void updateAgreementStatusFromWebhook(Agreement__c agreement, String status, String eventType, String envelopeId) {
        if (agreement == null || String.isBlank(status)) return;
        String mappedStatus = mapDocuSignStatus(status);
        // Envelope completed
        if (mappedStatus == 'Completed') {
            agreement.Status__c = 'Fully Signed';
            agreement.Status_Group__c = 'In Signature';
        }
        // Recipient signed (partial)
        else if (eventType != null && eventType.toLowerCase().contains('recipient-completed')) {
            agreement.Status__c = 'In Signature';
            agreement.Status_Group__c = 'In Signature';
        }
        // Sent
        else if (mappedStatus == 'Sent') {
            agreement.Status__c = 'Sent';
            agreement.Status_Group__c = 'In Signature';
        }
        // Declined
        else if (mappedStatus == 'Declined') {
            agreement.Status__c = 'Declined';
            agreement.Status_Group__c = 'Closed';
        }
        // Voided
        else if (mappedStatus == 'Voided') {
            agreement.Status__c = 'Voided';
            agreement.Status_Group__c = 'Closed';
        }
    }
    private static String mapDocuSignStatus(String docusignStatus) {
        String normalized = (docusignStatus == null) ? '' : docusignStatus.toLowerCase();
        if (normalized == 'sent')
            return 'Sent';
        if (normalized == 'completed')
            return 'Completed';
        if (normalized == 'delivered')
            return 'Delivered';
        if (normalized == 'declined')
            return 'Declined';
        if (normalized == 'voided')
            return 'Voided';
        if (normalized == 'created' || normalized == 'draft')
            return 'Draft';
        return docusignStatus;
    }
    private static void updateAgreementsWithRetry(List<Agreement__c> agreements) {
        Integer   retryCount    = 0;
        Boolean   success       = false;
        Exception lastException = null;
        List<Agreement__c> safeRecords = (List<Agreement__c>) Security.stripInaccessible(AccessType.UPDATABLE, agreements).getRecords();
        while (retryCount < MAX_RETRIES && !success) {
            try {
                update safeRecords;
                success = true;
                logDebug('Successfully updated ' + safeRecords.size() + ' agreement(s)');
            } catch (DmlException e) {
                lastException = e;
                retryCount++;
                if (retryCount < MAX_RETRIES) {
                    Integer backoffMs = INITIAL_BACKOFF_MS * (Integer) Math.pow(2, retryCount - 1);
                    logWarning('Update failed, retrying. Attempt=' + retryCount + ' backoff=' + backoffMs + 'ms' + ' reason=' + e.getMessage());
                }
            }
        }
        if (!success) {
            logError('Update failed after ' + MAX_RETRIES + ' retries: ' + (lastException != null ? lastException.getMessage() : 'unknown'));
        }
    }
    // SIGNATURE VALIDATION
    private static Boolean isValidSignature(String payload) {
        try {
            String signature = RestContext.request.headers.get('X-DocuSign-Signature-1');
            if (String.isBlank(signature)) {
                logDebug('No X-DocuSign-Signature-1 header present; skipping signature validation by configuration.');
                return true;
            }
            String hmacKey = getHmacKey();
            if (String.isBlank(hmacKey)) {
                logError('HMAC key not configured but DocuSign sent signature header. Rejecting.');
                return false;
            }
            Blob hmacData = Crypto.generateMac('HmacSHA256', Blob.valueOf(payload), Blob.valueOf(hmacKey));
            String computedSignature = EncodingUtil.base64Encode(hmacData);
            Boolean ok = (signature == computedSignature);
            if (!ok) {
                logWarning('Signature mismatch. received=' + signature + ' computed=' + computedSignature);
            }
            return ok;
        } catch (Exception e) {
            logError('Signature validation error: ' + e.getMessage());
            return false;
        }
    }
    private static String getHmacKey() {
        try {
            String secret = DocuSignConfigService.getConnectSecret();
            if (String.isBlank(secret)) {
                logError('Connect Secret not configured in DocuSign Config CMDT.');
                return null;
            }
            return secret;
        } catch (Exception e) {
            logError('Error loading HMAC key: ' + e.getMessage());
            return null;
        }
    }
    // EVENT TYPE VALIDATION
    private static Boolean isValidEventType(String eventType) {
        if (String.isBlank(eventType))
            return false;
        Set<String> validEvents = new Set<String>{ 'envelope-sent', 'envelope-delivered', 'envelope-completed', 'envelope-declined', 'envelope-voided', 'recipient-sent', 'recipient-delivered', 'recipient-completed', 'recipient-declined', 'sent', 'delivered', 'completed', 'declined', 'voided', 'recipient_signed', 'envelope-completed:server', 'recipient-completed:server' };
            return validEvents.contains(eventType.toLowerCase());
    }
    // CACHE UTILITIES
    private static Object getCachedValue(String key) {
        try {
            Cache.OrgPartition partition = Cache.Org.getPartition(CACHE_PARTITION);
            if (partition != null) {
                return partition.get(key);
            } else {
                // fallback to in-memory map
                logWarning('Cache partition "' + CACHE_PARTITION + '" not found. Using fallback in-memory cache.');
                return fallbackCache.containsKey(key) ? fallbackCache.get(key) : null;
            }
        } catch (Exception e) {
            logDebug('Cache get failed: ' + e.getMessage());
            return null;
        }
    }
    private static void setCachedValue(String key, Object value) {
        try {
            Cache.OrgPartition partition = Cache.Org.getPartition(CACHE_PARTITION);
            if (partition != null) {
                partition.put(key, value, CACHE_TTL_SECONDS);
            } else {
                fallbackCache.put(key, value);
            }
        } catch (Exception e) {
            logDebug('Cache set failed: ' + e.getMessage());
        }
    }
    public class WebhookProcessorQueueable implements Queueable {
        private String payload;
        public WebhookProcessorQueueable(String payload) {
            this.payload = payload;
        }
        public void execute(QueueableContext ctx) {
            processWebhookPayload(payload);
        }
    }
    // Extracts the name + email of the recipient who triggered this event
    private static String getRecipientInfo(Map<String, Object> notification) {
        try {
            Map<String, Object> data = (Map<String, Object>) notification.get('data');
            if (data == null) return null;
            Map<String, Object> summary = data.containsKey('envelopeSummary') ? (Map<String, Object>) data.get('envelopeSummary') : null;
            if (summary == null) return null;
            Map<String, Object> recipients = (Map<String, Object>) summary.get('recipients');
            if (recipients == null) return null;
            // Check all recipient types for the one that triggered this event
            for (String recipType : new List<String>{ 'signers', 'certifiedDeliveries', 'carbonCopies' }) {
                List<Object> recipList = (List<Object>) recipients.get(recipType);
                if (recipList == null) continue;
                for (Object r : recipList) {
                    Map<String, Object> recip = (Map<String, Object>) r;
                    String recipStatus = ((String) recip.get('status'))?.toLowerCase();
                    // delivered = viewed, completed = signed
                    if (recipStatus == 'delivered' || recipStatus == 'completed') {
                        String name  = (String) recip.get('name');
                        String email = (String) recip.get('email');
                        if (String.isNotBlank(name)) {
                            return name + (String.isNotBlank(email) ? ' (' + email + ')' : '');
                        }
                    }
                }
            }
        } catch (Exception e) {
            logDebug('getRecipientInfo error: ' + e.getMessage());
        }
        return null;
    }
    // LOGGING
    private static void logDebug(String message) {
        System.debug(LoggingLevel.DEBUG, '[DocuSignWebhook] ' + message);
    }
    private static void logWarning(String message) {
        System.debug(LoggingLevel.WARN, '[DocuSignWebhook] ' + message);
    }
    private static void logError(String message) {
        System.debug(LoggingLevel.ERROR, '[DocuSignWebhook] ' + message);
    }
}