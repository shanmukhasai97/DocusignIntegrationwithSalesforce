/**
* DocuSignAuthService class for handling DocuSign OAuth authentication, connection lifecycle, and configuration management,
* including connect URL generation, account validation, metadata persistence, polling control, and secure API access.
*/
public without sharing class DocuSignAuthService {
    
    private static final String AUTH_PROVIDER_NAME = 'DocuSign_Auth_Provider';
    public class DocuSignAuthException extends Exception {}
    //  CONNECT URL
    @AuraEnabled
    public static String getConnectUrl() {
        return getConnectUrlWithOptions(true);
    }
    @AuraEnabled
    public static String getConnectUrlForced() {
        return getConnectUrlWithOptions(true);
    }
    private static String getConnectUrlWithOptions(Boolean forceLogin) {
        DocuSign_Config__mdt cfg = DocuSignConfigService.getConfig();
        if (cfg.Active__c != true) {
            throw new AuraHandledException('DocuSign integration is currently inactive. Ask your Salesforce admin to activate it first.');
        }
        String returnPath = DocuSignConfigService.getReturnPath();
        System.debug(DocuSignConfigService.getReturnPath());
        String promptValue = forceLogin ? 'login select_account' : 'select_account';
        String connectUrl = URL.getOrgDomainUrl().toExternalForm() + '/services/auth/oauth/' + AUTH_PROVIDER_NAME + '?startURL=' + EncodingUtil.urlEncode(returnPath, 'UTF-8') + '&prompt=' + EncodingUtil.urlEncode(promptValue, 'UTF-8');
        if (forceLogin) {
            connectUrl += '&max_age=0';
        }
        DocuSignConfigService.getConfig();
        return connectUrl;
    }
    //  COMPLETE CONNECTION  (OAuth callback → store account details in CMDT)
    @AuraEnabled
    public static Map<String, String> completeConnection(String environment) {
        /*  Normalise environment */
        if (String.isBlank(environment)) {
            environment = 'Demo';
        }
        if (!environment.equalsIgnoreCase('Demo') && !environment.equalsIgnoreCase('Production')) {
            throw new AuraHandledException('Invalid environment value "' + environment + '". Must be Demo or Production.');
        }
        environment = environment.equalsIgnoreCase('Production') ? 'Production' : 'Demo';
        DocuSign_Config__mdt activeCheckCfg = DocuSignConfigService.getConfig();
        if (activeCheckCfg.Active__c != true) {
            throw new AuraHandledException(
                'DocuSign integration is currently inactive. ' +
                'Ask your Salesforce admin to check "Active" on the DocuSign_Configuration ' +
                'Custom Metadata record before connecting.'
            );
        }
        /* Validate org-level config matches the requested environment */
        try {
            DocuSignConfigService.validateEnvironmentSetup(environment);
        } catch (DocuSignConfigService.DocuSignConfigException cfgEx) {
            throw new AuraHandledException('Environment mismatch in Custom Metadata: ' + cfgEx.getMessage());
        }
        /* Fetch OAuth userinfo via the fresh UI auth token */
        Id userId = UserInfo.getUserId();
        Map<String, Object> userInfo;
        try {
            
            AuthProvider provider = [SELECT Id FROM AuthProvider WHERE DeveloperName = :AUTH_PROVIDER_NAME LIMIT 1];
            
            String rawUiToken;
            if (Test.isRunningTest()) {
                rawUiToken = 'TEST_TOKEN';
            } else {
                rawUiToken = Auth.AuthToken.getAccessToken(provider.Id, 'Open ID Connect');
            }
            if (String.isBlank(rawUiToken)) {
                throw new CalloutException('No access token returned from UI login flow.');
            }
            userInfo = fetchUserInfoWithRawToken(rawUiToken, environment);
        } catch (Exception e) {
            throw new AuraHandledException('DocuSign authentication failed — token not present or expired. ' + 'Please click Connect and log in again. Detail: ' + e.getMessage());
        }
        /* Extract the default (or first) account from userinfo */
        List<Object> accounts = (List<Object>) userInfo.get('accounts');
        if (accounts == null || accounts.isEmpty()) {
            throw new AuraHandledException('No DocuSign accounts were returned for this user. ' + 'Check that the DocuSign user has at least one active account.');
        }
        String oauthAccountId = null;
        String oauthBaseUri = null;
        String oauthAcctName = null;
        for (Object obj : accounts) {
            Map<String, Object> acct = (Map<String, Object>) obj;
            if (acct.get('is_default') == true) {
                oauthAccountId = (String) acct.get('account_id');
                oauthBaseUri = (String) acct.get('base_uri');
                oauthAcctName = (String) acct.get('account_name');
                break;
            }
        }
        if (String.isBlank(oauthAccountId)) {
            Map<String, Object> first = (Map<String, Object>) accounts[0];
            oauthAccountId = (String) first.get('account_id');
            oauthBaseUri = (String) first.get('base_uri');
            oauthAcctName = (String) first.get('account_name');
        }
        if (String.isBlank(oauthAccountId)) {
            throw new AuraHandledException('Unable to determine the DocuSign Account ID from the OAuth response. ' + 'Raw accounts returned: ' + accounts.size());
        }
        /* 5 — Account isolation */
        String allowedAccountId = DocuSignConfigService.getAllowedAccountId();
        if (String.isNotBlank(allowedAccountId)) {
            if (!allowedAccountId.equalsIgnoreCase(oauthAccountId)) {
                System.debug(LoggingLevel.WARN, '[DocuSignAuthService.completeConnection] Rejected account. ' + 'Allowed=' + allowedAccountId + ' Attempted=' + oauthAccountId + ' User=' + userId);
                throw new AuraHandledException('Wrong DocuSign account. ' + 'You signed in as account "' + oauthAccountId + '", ' + 'but this org only permits account "' + allowedAccountId + '". ' + 'Please disconnect and reconnect using the authorised DocuSign account.');
            }
        } else {
            System.debug(LoggingLevel.WARN, '[DocuSignAuthService.completeConnection] ' + 'DocuSign_API_Account_ID__c is blank in Custom Metadata. ' + 'Any DocuSign account will be accepted. ' + 'Set this field to restrict to a specific account.');
        }
        /*  Fetch numeric account ID + account details */
        String apiCredential = DocuSignConfigService.getApiNamedCredential(environment);
        String shortAccountId = null;
        String accountName = oauthAcctName;
        String site = null;
        try {
            Map<String, String> acctDetails = fetchAccountDetails(apiCredential, oauthAccountId);
            shortAccountId = acctDetails.get('accountNumber');
            if (String.isNotBlank(acctDetails.get('accountName'))) {
                accountName = acctDetails.get('accountName');
            }
            site = acctDetails.get('companyName');
            System.debug(LoggingLevel.INFO, '[DocuSignAuthService.completeConnection] Account details — ' + 'shortAccountId=' + shortAccountId + ' accountName=' + accountName + ' site=' + site);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, '[DocuSignAuthService.completeConnection] fetchAccountDetails failed: ' + e.getMessage());
            throw new AuraHandledException('Connected to DocuSign but could not retrieve the numeric Account ID. ' + 'Verify that Named Credential "DocuSign_API_' + environment + '" ' + 'URL is correct and the Per-User Principal is authorised. ' + 'Detail: ' + e.getMessage());
        }
        /*  shortAccountId must be numeric */
        if (String.isBlank(shortAccountId) || shortAccountId.contains('-') || shortAccountId == 'null' || shortAccountId == '0') {
            throw new AuraHandledException('DocuSign returned an invalid numeric Account ID ("' + shortAccountId + '"). ' + 'Check the DocuSign_API_' + environment + ' Named Credential and retry.');
        }
        /*  Resolve site/company label */
        if (String.isBlank(site)) {
            site = environment;
        }
        /*  Persist the connection state into Custom Metadata */
        try {
            persistConnectionMetadata(userId, oauthAccountId, shortAccountId, oauthBaseUri, accountName, environment, site);
        } catch (Exception e) {
            throw new AuraHandledException('DocuSign account validated but failed to save the connection record: ' + e.getMessage());
        }
        
        /*  Restart polling under the connecting user */
        restartPollingForNewConnection();
        System.debug(LoggingLevel.INFO, '[DocuSignAuthService.completeConnection] SUCCESS — ' + 'userId=' + userId + ' accountId=' + oauthAccountId + ' shortAccountId=' + shortAccountId + ' environment=' + environment + ' site=' + site);
        return new Map<String, String>{ 'accountId' => oauthAccountId, 'shortAccountId' => shortAccountId, 'accountName' => accountName, 'companyName' => site, 'environment' => environment, 'baseUri' => oauthBaseUri, 'site' => site };
            }
    //  CONNECTION STATUS  (read from Custom Metadata — no DocuSign_Auth__c)
    @AuraEnabled(cacheable=false)
    public static Boolean isConnected() {
        try {
            List<DocuSign_Config__mdt> rows = [SELECT Active__c, DocuSign_API_Account_ID__c FROM DocuSign_Config__mdt WHERE DeveloperName = :DocuSignConfigService.CONFIG_DEVELOPER_NAME LIMIT 1];
            if (rows.isEmpty())
                return false;
            return rows[0].Active__c == true && String.isNotBlank(rows[0].DocuSign_API_Account_ID__c);
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, '[DocuSignAuthService.isConnected] ' + e.getMessage());
            return false;
        }
    }
    @AuraEnabled(cacheable=false)
    public static Map<String, String> getConnectionInfo() {
        try {
            List<DocuSign_Config__mdt> rows = [SELECT Active__c, DocuSign_API_Account_ID__c, Auth_Base_URL__c FROM DocuSign_Config__mdt WHERE DeveloperName = :DocuSignConfigService.CONFIG_DEVELOPER_NAME LIMIT 1];
            if (rows.isEmpty() || rows[0].Active__c != true || String.isBlank(rows[0].DocuSign_API_Account_ID__c)) {
                return null;
            }
            String fullAccountId = rows[0].DocuSign_API_Account_ID__c;
            String environment = DocuSignConfigService.detectEnvironment();
            String apiNc = DocuSignConfigService.getApiNamedCredential(environment);
            String accountName = 'DocuSign Account';
            String companyName = 'DocuSign Account';
            String shortId = fullAccountId.contains('-') ? '' : fullAccountId;
            String siteLabel = environment.equalsIgnoreCase('Production') ? 'Production' : 'DocuSign Developer Center';
            try {
                Map<String, String> details = fetchAccountDetails(apiNc, fullAccountId);
                if (String.isNotBlank(details.get('accountName'))) {
                    accountName = details.get('accountName');
                }
                if (String.isNotBlank(details.get('companyName'))) {
                    companyName = details.get('companyName');
                }
                if (String.isNotBlank(details.get('accountNumber'))) {
                    shortId = details.get('accountNumber');
                }
                System.debug(LoggingLevel.INFO, '[DocuSignAuthService.getConnectionInfo] Live details fetched — ' + 'accountName=' + accountName + ' companyName=' + companyName + ' shortId=' + shortId);
            } catch (Exception apiEx) {
                // API call failed (e.g. token expired) — fall back to CMDT-only values
                System.debug(LoggingLevel.WARN, '[DocuSignAuthService.getConnectionInfo] fetchAccountDetails failed, ' + 'using fallback values. Reason: ' + apiEx.getMessage());
            }
            return new Map<String, String>{ 'accountId' => fullAccountId, 'accountName' => accountName, 'shortAccountId' => shortId, 'companyName' => environment, 'environment' => environment, 'site' => environment, 'baseUrl' => rows[0].Auth_Base_URL__c };
                } catch (Exception e) {
                    System.debug(LoggingLevel.ERROR, '[DocuSignAuthService.getConnectionInfo] ' + e.getMessage());
                    return null;
                }
    }
    //  DISCONNECT
    @AuraEnabled
    public static void disconnect() {
        try {
            String authNc = DocuSignConfigService.getAuthNamedCredential();
            HttpRequest req = new HttpRequest();
            req.setEndpoint(authNc + '/oauth/revoke');
            req.setMethod('POST');
            req.setHeader('Content-Type', 'application/x-www-form-urlencoded');
            req.setBody('token_type_hint=access_token');
            req.setTimeout(10000);
            HttpResponse res = new Http().send(req);
            System.debug(LoggingLevel.INFO, '[DocuSignAuthService.disconnect] Revoke status=' + res.getStatusCode());
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, '[DocuSignAuthService.disconnect] Revoke failed (ignored): ' + e.getMessage());
        }
    }
    //  ACCOUNT / CONNECTION ACCESSORS  (all read from Custom Metadata)
    public static String getAccountId(Id userId) {
        if (userId == null) {
            throw new DocuSignAuthException('UserId cannot be null.');
        }
        try {
            DocuSign_Config__mdt cfg = DocuSignConfigService.getConfig();
            if (cfg.Active__c != true || String.isBlank(cfg.DocuSign_API_Account_ID__c)) {
                throw new DocuSignAuthException('DocuSign is not connected. Account ID not configured in Custom Metadata.');
            }
            return cfg.DocuSign_API_Account_ID__c;
        } catch (DocuSignAuthException e) {
            throw e;
        } catch (Exception e) {
            throw new DocuSignAuthException('DocuSign is not connected. ' + e.getMessage());
        }
    }
    
    public static String getAccountId(Id userId, String environment) {
        return getAccountId(userId);
    }
    
    public static String getBaseUri(Id userId) {
        try {
            DocuSign_Config__mdt cfg = DocuSignConfigService.getConfig();
            if (cfg.Active__c != true || String.isBlank(cfg.Auth_Base_URL__c)) {
                throw new DocuSignAuthException('Base URI not found. Auth_Base_URL__c is not configured.');
            }
            return cfg.Auth_Base_URL__c;
        } catch (DocuSignAuthException e) {
            throw e;
        } catch (Exception e) {
            throw new DocuSignAuthException('Base URI not found. ' + e.getMessage());
        }
    }
    
    public static String getEnvironment(Id userId) {
        try {
            DocuSign_Config__mdt cfg = DocuSignConfigService.getConfig();
            if (cfg.Active__c != true) {
                throw new DocuSignAuthException('DocuSign is not connected. Custom Metadata is not active.');
            }
            String env = DocuSignConfigService.detectEnvironment();
            if ('Unknown'.equals(env)) {
                throw new DocuSignAuthException('DocuSign is not connected. Environment cannot be determined from Auth_Base_URL__c.');
            }
            return env;
        } catch (DocuSignAuthException e) {
            throw e;
        } catch (Exception e) {
            throw new DocuSignAuthException('DocuSign is not connected. ' + e.getMessage());
        }
    }
    
    //  TEST CONNECTION
    @AuraEnabled
    public static String testConnection() {
        String namedCredential = DocuSignConfigService.getAuthNamedCredential();
        try {
            Map<String, Object> info = fetchUserInfo(namedCredential);
            String name = (String) info.get('name');
            String email = (String) info.get('email');
            return 'OK — Connected as: ' + name + ' (' + email + ')';
        } catch (Exception e) {
            return 'FAILED — ' + e.getMessage() + '. Token not in Per User Principal. ' + 'Connect via LWC button, not via Setup → Allow Access.';
        }
    }
    //  POLLING
    @AuraEnabled
    public static Boolean restartPolling() {
        try {
            DocuSignPollingScheduler.startPolling();
        } catch (Exception e) {
            throw new AuraHandledException('Could not restart polling: ' + e.getMessage());
        }
        if (!DocuSignPollingScheduler.isPollingActive()) {
            throw new AuraHandledException('Scheduling call succeeded but job is not active. ' + 'Check that your Profile has the "Schedule Apex" system permission.');
        }
        return true;
    }
    @AuraEnabled(cacheable=false)
    public static Boolean isPollingActive() {
        return DocuSignPollingScheduler.isPollingActive();
    }
    //  CONFIG VALUES
    @AuraEnabled(cacheable=false)
    public static Map<String, Object> getConfigValues() {
        try {
            if (!Schema.sObjectType.DocuSign_Config__mdt.isAccessible()) {
                throw new AuraHandledException('Insufficient permissions to read DocuSign configuration.');
            }
            List<DocuSign_Config__mdt> rows = [SELECT DocuSign_API_Account_ID__c, Auth_Base_URL__c, Docusign_Secret_Keys__c, API_Version__c, Active__c, Enable_Partial_Signatures__c FROM DocuSign_Config__mdt WHERE DeveloperName = :DocuSignConfigService.CONFIG_DEVELOPER_NAME LIMIT 1];
            if (rows.isEmpty()) {
                return new Map<String, Object>{ 'active' => false };
                    }
            DocuSign_Config__mdt cfg = rows[0];
            Boolean secretConfigured = String.isNotBlank(cfg.Docusign_Secret_Keys__c);
            return new Map<String, Object>{ 'accountId' => cfg.DocuSign_API_Account_ID__c, 'authBaseUrl' => cfg.Auth_Base_URL__c, 'secretConfigured' => secretConfigured, 'apiVersion' => cfg.API_Version__c, 'active' => cfg.Active__c, 'enablePartialSign' => cfg.Enable_Partial_Signatures__c };
                } catch (AuraHandledException e) {
                    throw e;
                } catch (Exception e) {
                    throw new AuraHandledException('Could not load configuration: ' + e.getMessage());
                }
    }
    @AuraEnabled
    public static void saveConfigValues(String accountId, String authBaseUrl, String secretKey, String environment, String apiVersion, Boolean active, Boolean enablePartialSign) {
        if (String.isBlank(accountId) || String.isBlank(authBaseUrl)) {
            throw new AuraHandledException('Account ID and Auth Base URL are required. Enter the DocuSign Auth Base URL that matches your Named Credential configuration (e.g. https://account-d.docusign.com for Demo, https://account.docusign.com for Production).');
        }
        Metadata.CustomMetadata record = new Metadata.CustomMetadata();
        record.fullName = DocuSignConfigService.getQualifiedApiName('DocuSign_Config__mdt') + '.' + DocuSignConfigService.getQualifiedApiName(DocuSignConfigService.CONFIG_DEVELOPER_NAME);
        record.label = 'DocuSign Configuration';
        record.values.add(newMetadataValue(DocuSignConfigService.getQualifiedApiName('DocuSign_API_Account_ID__c'), accountId));
        record.values.add(newMetadataValue(DocuSignConfigService.getQualifiedApiName('Auth_Base_URL__c'), authBaseUrl));
        if (String.isNotBlank(secretKey)) {
            record.values.add(newMetadataValue(DocuSignConfigService.getQualifiedApiName('Docusign_Secret_Keys__c'), secretKey));
        }
        if (String.isNotBlank(apiVersion)) {
            record.values.add(newMetadataValue(DocuSignConfigService.getQualifiedApiName('API_Version__c'), apiVersion));
        }
        record.values.add(newMetadataValue(DocuSignConfigService.getQualifiedApiName('Active__c'), active));
        record.values.add(newMetadataValue(DocuSignConfigService.getQualifiedApiName('Enable_Partial_Signatures__c'), enablePartialSign));
        Metadata.DeployContainer container = new Metadata.DeployContainer();
        container.addMetadata(record);
        Id jobId = Metadata.Operations.enqueueDeployment(container, new MetadataCallback());
        System.debug(LoggingLevel.INFO, '[DocuSignAuthService.saveConfigValues] Deploy enqueued. jobId=' + jobId);
    }
    //  MISC AURA HELPERS
    @AuraEnabled
    public static void clearExternalCredentialState() {
        System.debug(LoggingLevel.INFO, '[DocuSignAuthService] clearExternalCredentialState called.');
    }
    @AuraEnabled
    public static void seedApprovedAccountIfNeeded(String environment) {
        System.debug('[DocuSignAuthService] seedApprovedAccountIfNeeded — no-op.');
    }
    //  METADATA CALLBACK
    public class MetadataCallback implements Metadata.DeployCallback {
        public void handleResult(Metadata.DeployResult result, Metadata.DeployCallbackContext ctx) {
            if (result.status == Metadata.DeployStatus.Succeeded) {
                System.debug(LoggingLevel.INFO, '[DocuSignAuthService.MetadataCallback] Config deploy succeeded.');
            } else {
                System.debug(LoggingLevel.ERROR, '[DocuSignAuthService.MetadataCallback] Config deploy FAILED: ' + result.errorMessage);
            }
        }
    }
    //  PRIVATE HELPERS
    private static Map<String, Object> fetchUserInfo(String namedCredential) {
        HttpRequest req = new HttpRequest();
        req.setEndpoint(namedCredential + '/oauth/userinfo');
        req.setMethod('GET');
        req.setHeader('Cache-Control', 'no-cache');
        req.setTimeout(10000);
        HttpResponse res = new Http().send(req);
        System.debug('[fetchUserInfo] STATUS: ' + res.getStatusCode());
        System.debug('[fetchUserInfo] BODY: ' + res.getBody());
        if (res.getStatusCode() != 200) {
            throw new DocuSignAuthException('Failed to fetch DocuSign user info. ' + 'Status: ' + res.getStatusCode() + ' Body: ' + res.getBody());
        }
        return (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
    }
    private static Map<String, Object> fetchUserInfoWithRawToken(String accessToken, String environment) {
        String authNc = DocuSignConfigService.getAuthNamedCredential();
        HttpRequest req = new HttpRequest();
        req.setEndpoint(authNc + '/oauth/userinfo');
        req.setMethod('GET');
        req.setHeader('Authorization', 'Bearer ' + accessToken);
        req.setTimeout(10000);
        HttpResponse res = new Http().send(req);
        if (res.getStatusCode() != 200) {
            throw new DocuSignAuthException('Failed to fetch DocuSign user info from UI token. ' + 'Status: ' + res.getStatusCode() + ' Body: ' + res.getBody());
        }
        return (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
    }
    private static Map<String, String> fetchAccountDetails(String namedCredential, String accountGuid) {
        String apiVersion = DocuSignConfigService.getApiVersion();
        HttpRequest req = new HttpRequest();
        req.setEndpoint(namedCredential + '/restapi/' + apiVersion + '/accounts/' + accountGuid);
        req.setMethod('GET');
        req.setHeader('Cache-Control', 'no-cache');
        req.setTimeout(15000);
        HttpResponse res = new Http().send(req);
        System.debug(LoggingLevel.INFO, '[fetchAccountDetails] Status=' + res.getStatusCode() + ' | BodyLength=' + res.getBody().length());
        if (res.getStatusCode() != 200) {
            System.debug(LoggingLevel.ERROR, '[fetchAccountDetails] Failed Body: ' + res.getBody());
            throw new CalloutException('Failed to fetch account details. Status=' + res.getStatusCode());
        }
        Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
        // Try multiple field names for the numeric/short account ID
        String shortId = '';
        for (String field : new List<String>{ 'externalAccountId', 'accountId', 'id' }) {
            Object val = body.get(field);
            if (val != null) {
                String strVal = String.valueOf(val).trim();
                if (strVal.contains('.'))
                    strVal = strVal.substringBefore('.');
                if (String.isNotBlank(strVal) && !strVal.equalsIgnoreCase('null') && !strVal.equals('0')) {
                    shortId = strVal;
                    break;
                }
            }
        }
        String accountName = 'DocuSign Account';
        Object nameObj = body.get('accountName');
        if (nameObj != null)
            accountName = String.valueOf(nameObj).trim();
        String companyName = accountName;
        Object companyObj = body.get('companyName');
        if (companyObj != null)
            companyName = String.valueOf(companyObj).trim();
        System.debug(LoggingLevel.INFO, '[fetchAccountDetails] shortId="' + shortId + '" accountName="' + accountName + '" companyName="' + companyName + '"');
        return new Map<String, String>{ 'accountNumber' => shortId, 'accountName' => accountName, 'companyName' => companyName };
            }
    
    private static void persistConnectionMetadata(Id userId, String accountId, String shortAccountId, String baseUri, String accountName, String environment, String site) {
        try {
            DocuSign_Config__mdt cfg = [SELECT Active__c, DocuSign_API_Account_ID__c, Auth_Base_URL__c, Docusign_Secret_Keys__c, API_Version__c, Enable_Partial_Signatures__c FROM DocuSign_Config__mdt WHERE DeveloperName = :DocuSignConfigService.CONFIG_DEVELOPER_NAME LIMIT 1];
            if (cfg.DocuSign_API_Account_ID__c == accountId) {
                System.debug(LoggingLevel.INFO, '[DocuSignAuthService.persistConnectionMetadata] ' + 'Account ID unchanged — skipping CMDT deploy. accountId=' + accountId);
            } else {
                Metadata.CustomMetadata record = new Metadata.CustomMetadata();
      			record.fullName = DocuSignConfigService.getQualifiedApiName('DocuSign_Config__mdt') + '.' + DocuSignConfigService.getQualifiedApiName(DocuSignConfigService.CONFIG_DEVELOPER_NAME);
                record.label = 'DocuSign Configuration';
                record.values.add(newMetadataValue(DocuSignConfigService.getQualifiedApiName('Active__c'), cfg.Active__c));
                record.values.add(newMetadataValue(DocuSignConfigService.getQualifiedApiName('DocuSign_API_Account_ID__c'), accountId));
                record.values.add(newMetadataValue(DocuSignConfigService.getQualifiedApiName('Auth_Base_URL__c'), cfg.Auth_Base_URL__c));
                if (String.isNotBlank(cfg.Docusign_Secret_Keys__c)) {
                    record.values.add(newMetadataValue(DocuSignConfigService.getQualifiedApiName('Docusign_Secret_Keys__c'), cfg.Docusign_Secret_Keys__c));
                }
                if (String.isNotBlank(cfg.API_Version__c)) {
                    record.values.add(newMetadataValue(DocuSignConfigService.getQualifiedApiName('API_Version__c'), cfg.API_Version__c));
                }
                record.values.add(newMetadataValue(DocuSignConfigService.getQualifiedApiName('Enable_Partial_Signatures__c'), cfg.Enable_Partial_Signatures__c));
                Metadata.DeployContainer container = new Metadata.DeployContainer();
                container.addMetadata(record);
                Metadata.Operations.enqueueDeployment(container, new MetadataCallback());
                System.debug(LoggingLevel.INFO, '[DocuSignAuthService.persistConnectionMetadata] ' + 'Deployed CMDT update. accountId=' + accountId + ' Active__c=' + cfg.Active__c);
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, '[DocuSignAuthService.persistConnectionMetadata] ' + e.getMessage());
            throw e;
        }
        migrateOpenEnvelopesAsync(accountId);
    }
    private static void restartPollingForNewConnection() {
        try {
            DocuSignPollingScheduler.startPolling();
            System.debug(LoggingLevel.INFO, '[DocuSignAuthService.restartPollingForNewConnection] ' + 'Polling restarted. User=' + UserInfo.getUserId());
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, '[DocuSignAuthService.restartPollingForNewConnection] ' + 'Could not restart polling: ' + e.getMessage());
        }
        try {
            DocuSignPollingScheduler.startWatchdog();
            System.debug(LoggingLevel.INFO, '[DocuSignAuthService.restartPollingForNewConnection] ' + 'Watchdog restarted. User=' + UserInfo.getUserId());
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, '[DocuSignAuthService.restartPollingForNewConnection] ' + 'Could not restart watchdog: ' + e.getMessage());
        }
    }
    private static Metadata.CustomMetadataValue newMetadataValue(String field, Object value) {
        Metadata.CustomMetadataValue cmv = new Metadata.CustomMetadataValue();
        cmv.field = field;
        cmv.value = value;
        return cmv;
    }
    @future
    private static void migrateOpenEnvelopesAsync(String newAccountId) {
        try {
            List<DocuSign_Status__c> openEnvelopes = [SELECT Id, DocuSign_Account_ID__c FROM DocuSign_Status__c WHERE Is_Terminal__c = FALSE AND DocuSign_Account_ID__c != :newAccountId AND DocuSign_Account_ID__c != NULL];
            if (openEnvelopes.isEmpty())
                return;
            for (DocuSign_Status__c env : openEnvelopes) {
                env.DocuSign_Account_ID__c = newAccountId;
            }
            update openEnvelopes;
            System.debug(LoggingLevel.INFO, '[DocuSignAuthService.migrateOpenEnvelopesAsync] Migrated ' + openEnvelopes.size() + ' envelope(s) to account: ' + newAccountId);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, '[DocuSignAuthService.migrateOpenEnvelopesAsync] ' + e.getMessage());
        }
    }
}