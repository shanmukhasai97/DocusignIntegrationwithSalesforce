/**
* DocuSignConfigService class for managing and validating DocuSign configuration via Custom Metadata,
* including environment detection, API settings, named credential resolution, and
* runtime access to secure configuration values.
*/
public without sharing class DocuSignConfigService {
    private static DocuSign_Config__mdt cachedConfig;
    /* CONSTANTS — single source of truth, referenced everywhere instead of re-typing literals */
    public static final String CONFIG_DEVELOPER_NAME = 'DocuSign_Configuration';
    private static final String API_NAMED_CREDENTIAL  = 'callout:DocuSign_API';
    private static final String AUTH_NAMED_CREDENTIAL = 'callout:DocuSign_Auth';
    
    private static final Map<String, String> ENV_BASE_URLS = new Map<String, String>{'Production' => 'https://account.docusign.com', 'Demo'       => 'https://account-d.docusign.com'};
        @TestVisible private static Boolean mockConfigMissing = false;
    @TestVisible private static DocuSign_Config__mdt mockConfig;
    
    /*  CONFIG LOAD  */
    public static DocuSign_Config__mdt getConfig() {
        if (Test.isRunningTest()) {
            if (mockConfigMissing) {
                throw new DocuSignConfigException('DocuSign_Config__mdt record "' + CONFIG_DEVELOPER_NAME + '" not found. ...');
            }
            if (mockConfig != null) {
                return mockConfig;
            }
        }
        if (cachedConfig == null) {
            List<DocuSign_Config__mdt> rows = [SELECT Active__c, API_Version__c, Auth_Base_URL__c, Enable_Partial_Signatures__c,Docusign_Secret_Keys__c, DocuSign_API_Account_ID__c FROM DocuSign_Config__mdt WHERE DeveloperName = :CONFIG_DEVELOPER_NAME LIMIT 1];
            if (rows.isEmpty()) {
                throw new DocuSignConfigException('DocuSign_Config__mdt record "' + CONFIG_DEVELOPER_NAME + '" not found. ' + 'Go to Setup → Custom Metadata Types → DocuSign Config and create it.');
            }
            cachedConfig = rows[0];
            if (cachedConfig.Active__c == true) {
                validateConfig(cachedConfig);
            }
        }
        return cachedConfig;
    }
    /*  BASIC VALIDATION  */
    @TestVisible
    private static void validateConfig(DocuSign_Config__mdt cfg) {
        List<String> errors = new List<String>();
        if (String.isBlank(cfg.API_Version__c)) {
            errors.add('API_Version__c is empty. Use v2.1');
        }
        if (String.isBlank(cfg.Docusign_Secret_Keys__c)) {
            errors.add('Docusign_Secret_Keys__c is empty.');
        }
        if (!errors.isEmpty()) {
            throw new DocuSignConfigException('DocuSign configuration errors:\n• ' + String.join(errors, '\n• '));
        }
    }
    /*  HELPERS  */
    public static String getApiVersion() {
        String v = getConfig().API_Version__c;
        return String.isNotBlank(v) ? v : 'v2.1';
    }
    public static Boolean isPartialSignaturesEnabled() {
        return getConfig().Enable_Partial_Signatures__c == true;
    }
    public static String getConnectSecret() {
        return getConfig().Docusign_Secret_Keys__c;
    }
    public static String getApiNamedCredential() {
        return getApiNamedCredential(detectEnvironment());
    }
    public static String getApiNamedCredential(String environment) {
        return 'callout:' + getQualifiedApiName('DocuSign_API');
    }    
    public static String getAuthNamedCredential() {
        return 'callout:' + getQualifiedApiName('DocuSign_Auth');
    }
    public class DocuSignConfigException extends Exception {}
    /*  URL NORMALIZATION  */
    private static String normalizeUrl(String url) {
        if (String.isBlank(url)) return '';
        String cleaned = url.trim().toLowerCase();
        if (cleaned.endsWith('/')) {
            cleaned = cleaned.substring(0, cleaned.length() - 1);
        }
        return cleaned;
    }
    
    public static void validateEnvironmentSetup(String environment) {
        if (String.isBlank(environment)) {
            environment = 'Demo';
        }
        String envKey = environment.equalsIgnoreCase('Production') ? 'Production' : 'Demo';
        String expectedAuth = normalizeUrl(ENV_BASE_URLS.get(envKey));
        String authBase = normalizeUrl(getConfig().Auth_Base_URL__c);
        if (String.isBlank(authBase) || authBase != expectedAuth) {
            throw new DocuSignConfigException(
                'DocuSign environment misconfiguration (' + environment + '):\n\n• ' + 'Custom Metadata Auth_Base_URL__c incorrect.\n' +
                'Expected: ' + expectedAuth + '\n' + 'Actual: '   + (String.isBlank(authBase) ? '(blank)' : authBase) + '\n\n' +
                'Go to Setup → Custom Metadata → DocuSign Config and update Auth Base URL to: ' + expectedAuth );
        }
    }
    
    /** Returns the expected Auth Base URL for a given environment, from the single shared map. */
    public static String getExpectedAuthBaseUrl(String environment) {
        String envKey = (String.isNotBlank(environment) && environment.equalsIgnoreCase('Production'))
            ? 'Production' : 'Demo';
        return ENV_BASE_URLS.get(envKey);
    }
    
    public static String detectEnvironment() {
        String authBase = normalizeUrl(getConfig().Auth_Base_URL__c);
        if (authBase.contains('account.docusign.com')) {
            return 'Production';
        }
        if (authBase.contains('account-d.docusign.com')) {
            return 'Demo';
        }
        return 'Unknown';
    }
    public static String getAllowedAccountId() {
        String id = getConfig().DocuSign_API_Account_ID__c;
        return String.isNotBlank(id) ? id.trim().toLowerCase() : null;
    }
    private static final String RETURN_TAB_NAME = 'DocuSign_SetUp';
    private static String cachedNamespace;
    
    public static String getNamespace() {
        if (cachedNamespace == null) {
            List<ApexClass> rows = [SELECT NamespacePrefix FROM ApexClass WHERE Name = 'DocuSignConfigService' LIMIT 1];
            cachedNamespace = (!rows.isEmpty() && String.isNotBlank(rows[0].NamespacePrefix)) ? rows[0].NamespacePrefix : '';
        }
        return cachedNamespace;
    }
    
    public static String getQualifiedApiName(String unqualifiedName) {
        String ns = getNamespace();
        return String.isNotBlank(ns) ? ns + '__' + unqualifiedName : unqualifiedName;
    }
    
    public static String getReturnPath() {
        String ns = getNamespace();
        String tabApiName = String.isNotBlank(ns) ? ns + '__' + RETURN_TAB_NAME : RETURN_TAB_NAME;
        return '/lightning/n/' + tabApiName + '?connected=true';
    }
}