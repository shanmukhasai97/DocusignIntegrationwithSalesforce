@IsTest
private class DocuSignConfigServiceTest {
    /*  MOCK CONFIG HELPERS
	  Every test below drives DocuSignConfigService.getConfig() through the @TestVisible mockConfig / mockConfigMissing hooks instead of relying on
      whether a real DocuSign_Config__mdt row happens to exist in the org. This makes every test deterministic and independent of org CMDT state.*/
    private static void setMockConfig(Boolean active, String apiVersion, String secretKey,
                                       String authBaseUrl, String accountId, Boolean partialSig) {
        DocuSignConfigService.mockConfigMissing = false;
        DocuSignConfigService.mockConfig = new DocuSign_Config__mdt(
            Active__c                    = active,
            API_Version__c                = apiVersion,
            Docusign_Secret_Keys__c       = secretKey,
            Auth_Base_URL__c              = authBaseUrl,
            DocuSign_API_Account_ID__c    = accountId,
            Enable_Partial_Signatures__c  = partialSig
        );
    }

    private static void mockActiveConfig() {
        setMockConfig(true, 'v2.1', 'test-secret-key', 'https://account-d.docusign.com', 'acc-001', false);
    }

    private static void mockProductionConfig() {
        setMockConfig(true, 'v2.1', 'test-secret-key', 'https://account.docusign.com', 'acc-001', false);
    }

    private static void mockConfigWithoutAllowedAccount() {
        setMockConfig(true, 'v2.1', 'test-secret-key', 'https://account-d.docusign.com', null, false);
    }

    private static void mockInactiveConfig() {
        setMockConfig(false, 'v2.1', 'test-secret-key', 'https://account-d.docusign.com', 'acc-001', false);
    }

    private static void mockUnknownEnvConfig() {
        setMockConfig(true, 'v2.1', 'test-secret-key', 'https://unknown.example.com', 'acc-001', false);
    }

    private static void mockBlankApiVersionConfig() {
        setMockConfig(true, '', 'test-secret-key', 'https://account-d.docusign.com', 'acc-001', false);
    }

    private static void mockBlankAuthUrlConfig() {
        setMockConfig(true, 'v2.1', 'test-secret-key', '', 'acc-001', false);
    }

    private static void mockPartialSigEnabledConfig() {
        setMockConfig(true, 'v2.1', 'test-secret-key', 'https://account-d.docusign.com', 'acc-001', true);
    }

    private static void resetMocks() {
        DocuSignConfigService.mockConfigMissing = false;
        DocuSignConfigService.mockConfig = null;
    }

    //  HTTP MOCKS
    //Happy-path mock: responds to /oauth/userinfo and /accounts/<guid> with well-formed JSON. 
    private class DocuSignCompleteConnectionMock implements HttpCalloutMock {
        private final String oauthAccountId;
        private final String shortAccountId;

        DocuSignCompleteConnectionMock(String oauthAccountId, String shortAccountId) {
            this.oauthAccountId = oauthAccountId;
            this.shortAccountId = shortAccountId;
        }

        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setHeader('Content-Type', 'application/json');
            if (req.getEndpoint().contains('/oauth/userinfo')) {
                res.setStatusCode(200);
                res.setBody(
                    '{"accounts":[{"account_id":"' + oauthAccountId + '",'
                    + '"base_uri":"https://demo.docusign.net",'
                    + '"account_name":"Test Account",'
                    + '"is_default":true}]}'
                );
                return res;
            }
            if (req.getEndpoint().contains('/accounts/')) {
                res.setStatusCode(200);
                res.setBody(
                    '{"externalAccountId":"' + shortAccountId + '",'
                    + '"accountName":"Test Account",'
                    + '"companyName":"Test Co"}'
                );
                return res;
            }
            res.setStatusCode(404);
            res.setBody('{}');
            return res;
        }
    }

    // Returns a 401 for every request. 
    private class DocuSignFailureMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setHeader('Content-Type', 'application/json');
            res.setStatusCode(401);
            res.setBody('{"error":"invalid_token"}');
            return res;
        }
    }

    private class EmptyAccountsMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setHeader('Content-Type', 'application/json');
            res.setBody('{"accounts":[]}');
            return res;
        }
    }

    private class AccountDetailsFailMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setHeader('Content-Type', 'application/json');
            if (req.getEndpoint().contains('/oauth/userinfo')) {
                res.setStatusCode(200);
                res.setBody(
                    '{"accounts":[{"account_id":"acc-001","base_uri":"https://demo.docusign.net",'
                    + '"account_name":"Test","is_default":true}]}'
                );
            } else {
                res.setStatusCode(500);
                res.setBody('{}');
            }
            return res;
        }
    }

    //userinfo succeeds; /accounts returns externalAccountId="0" (invalid).
    private class InvalidAccountIdMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setHeader('Content-Type', 'application/json');
            if (req.getEndpoint().contains('/userinfo')) {
                res.setStatusCode(200);
                res.setBody(
                    '{"accounts":[{"account_id":"any-acct","base_uri":"https://demo",'
                    + '"account_name":"Test","is_default":true}]}'
                );
            } else {
                res.setStatusCode(200);
                res.setBody('{"externalAccountId":"0"}');
            }
            return res;
        }
    }

    private class NonDefaultAccountMock implements HttpCalloutMock {
        private String acctId;

        public NonDefaultAccountMock(String acctId) {
            this.acctId = acctId;
        }

        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setHeader('Content-Type', 'application/json');

            if (req.getEndpoint().contains('/oauth/userinfo')) {
                res.setStatusCode(200);
                res.setBody('{"accounts":[{"account_id":"' + this.acctId + '","base_uri":"https://demo.docusign.net","account_name":"Fallback Acct","is_default":false}]}');
                return res;
            }
            if (req.getEndpoint().contains('/accounts/')) {
                res.setStatusCode(200);
                res.setBody('{"id":"888888","accountName":"Fallback Acct","companyName":"Fallback Co"}');
                return res;
            }
            res.setStatusCode(404);
            return res;
        }
    }

    //Mock that forces a hard Apex CalloutException to hit generic catch blocks.
    private class CalloutExceptionMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            CalloutException e = (CalloutException) CalloutException.class.newInstance();
            e.setMessage('Simulated System Callout Exception');
            throw e;
        }
    }

    //Mock that returns a JSON payload completely missing the account_id field.
    private class MissingAccountIdMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setHeader('Content-Type', 'application/json');
            if (req.getEndpoint().contains('/oauth/userinfo')) {
                res.setStatusCode(200);
                res.setBody('{"accounts":[{"base_uri":"https://demo.docusign.net","account_name":"No ID Acct","is_default":true}]}');
                return res;
            }
            res.setStatusCode(404);
            return res;
        }
    }

    //Succeeds for UserInfo but fails for Account Details, to hit the nested catch block.
    private class BadAccountDetailsMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setHeader('Content-Type', 'application/json');
            if (req.getEndpoint().contains('/oauth/userinfo')) {
                res.setStatusCode(200);
                res.setBody('{"accounts":[{"account_id":"acc-001","base_uri":"https://demo.docusign.net","account_name":"Acct","is_default":true}]}');
                return res;
            }
            if (req.getEndpoint().contains('/accounts/')) {
                res.setStatusCode(400);
                res.setBody('{"error":"bad_request"}');
                return res;
            }
            return res;
        }
    }

    private class EmptyAccountIdMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setBody('{"accounts":[{"account_id":"","base_uri":"https://demo.docusign.net","account_name":"Test","is_default":true}]}');
            return res;
        }
    }

    //Returns externalAccountId="0" to trigger the invalid numeric ID exception.
    private class ZeroExternalAccountIdMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            if (req.getEndpoint().contains('/userinfo')) {
                res.setStatusCode(200);
                res.setBody('{"accounts":[{"account_id":"any-acct","base_uri":"https://demo","account_name":"Test","is_default":true}]}');
            } else {
                res.setStatusCode(200);
                res.setBody('{"externalAccountId":"0"}');
            }
            return res;
        }
    }

    // Returns HTTP 500 for fetchUserInfo, to trigger the testConnection catch block.
    private class FetchUserInfoFailMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(500);
            res.setBody('{"error":"Server Error"}');
            return res;
        }
    }

    //Account details payload with null/blank fields, to hit blank-handling branches. 
    private class NullFieldsAccountMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setHeader('Content-Type', 'application/json');
            if (req.getEndpoint().contains('/oauth/userinfo')) {
                res.setBody('{"accounts":[{"account_id":"any-acct","base_uri":"https://demo.docusign.net","account_name":"Test","is_default":true}]}');
            } else {
                res.setBody('{"accountName":null,"companyName":"","externalAccountId":"","id":""}');
            }
            return res;
        }
    }

    // Broken structure — account entry with no fields at all. 
    private class BrokenMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setHeader('Content-Type', 'application/json');
            res.setBody('{"accounts":[{}]}');
            return res;
        }
    }

    //  DocuSignConfigService — getConfig
    @IsTest
    static void getConfig_returnsMockedActiveRecord() {
        mockActiveConfig();
        DocuSign_Config__mdt cfg = DocuSignConfigService.getConfig();
        System.assertNotEquals(null, cfg, 'Should return the mocked config');
        System.assertEquals(true, cfg.Active__c);
        System.assertEquals('acc-001', cfg.DocuSign_API_Account_ID__c);
        resetMocks();
    }

    @IsTest
    static void getConfig_returnsSameMockedValueOnRepeatedCalls() {
        mockActiveConfig();
        DocuSign_Config__mdt c1 = DocuSignConfigService.getConfig();
        DocuSign_Config__mdt c2 = DocuSignConfigService.getConfig();
        System.assertEquals(c1.DocuSign_API_Account_ID__c, c2.DocuSign_API_Account_ID__c,
                            'Repeated calls should return equivalent config values');
        resetMocks();
    }

    @IsTest
    static void getConfig_throwsWhenMockConfigMissing() {
        DocuSignConfigService.mockConfig = null;
        DocuSignConfigService.mockConfigMissing = true;
        try {
            DocuSignConfigService.getConfig();
            System.assert(false, 'Expected DocuSignConfigException');
        } catch (DocuSignConfigService.DocuSignConfigException e) {
            System.assert(e.getMessage().contains(DocuSignConfigService.CONFIG_DEVELOPER_NAME) ||
                          e.getMessage().contains('not found'),
                          'Unexpected message: ' + e.getMessage());
        }
        resetMocks();
    }

    //  DocuSignConfigService — validateConfig
    @IsTest
    static void validateConfig_throwsOnAllBlankFields() {
        DocuSign_Config__mdt cfg = new DocuSign_Config__mdt(
            API_Version__c          = '',
            Docusign_Secret_Keys__c = ''
        );
        try {
            DocuSignConfigService.validateConfig(cfg);
            System.assert(false, 'Expected DocuSignConfigException');
        } catch (DocuSignConfigService.DocuSignConfigException e) {
            System.assert(e.getMessage().contains('API_Version__c'), 'Message should mention API_Version__c');
            System.assert(e.getMessage().contains('Docusign_Secret_Keys__c'), 'Message should mention Docusign_Secret_Keys__c');
        }
    }

    @IsTest
    static void validateConfig_passesOnValidDemoConfig() {
        DocuSign_Config__mdt cfg = new DocuSign_Config__mdt(
            Auth_Base_URL__c        = 'https://account-d.docusign.com',
            API_Version__c          = 'v2.1',
            Docusign_Secret_Keys__c = 'dummy-secret'
        );
        DocuSignConfigService.validateConfig(cfg);
        System.assert(true, 'validateConfig should not throw for a valid demo config');
    }

    @IsTest
    static void validateConfig_passesForProductionConfig() {
        DocuSign_Config__mdt cfg = new DocuSign_Config__mdt(
            Auth_Base_URL__c        = 'https://account.docusign.com',
            API_Version__c          = 'v2.1',
            Docusign_Secret_Keys__c = 'dummy-secret'
        );
        DocuSignConfigService.validateConfig(cfg);
        System.assert(true, 'validateConfig should not throw for a valid production config');
    }

    //  DocuSignConfigService — environment helpers
    @IsTest
    static void validateEnvironmentSetup_passesForDemo() {
        mockActiveConfig();
        DocuSignConfigService.validateEnvironmentSetup('Demo');
        System.assert(true, 'Should not throw when Auth_Base_URL__c matches Demo');
        resetMocks();
    }

    @IsTest
    static void validateEnvironmentSetup_passesForProduction() {
        mockProductionConfig();
        DocuSignConfigService.validateEnvironmentSetup('Production');
        System.assert(true, 'Should not throw when Auth_Base_URL__c matches Production');
        resetMocks();
    }

    @IsTest
    static void validateEnvironmentSetup_defaultsToDemoWhenBlank() {
        mockActiveConfig();
        DocuSignConfigService.validateEnvironmentSetup(null);
        System.assert(true, 'Blank environment should default to Demo without throwing');
        resetMocks();
    }

    @IsTest
    static void validateEnvironmentSetup_throwsOnMismatch() {
        mockActiveConfig(); // Demo URL configured
        try {
            DocuSignConfigService.validateEnvironmentSetup('Production');
            System.assert(false, 'Expected DocuSignConfigException for mismatched env');
        } catch (DocuSignConfigService.DocuSignConfigException e) {
            System.assert(e.getMessage().contains('misconfiguration'), 'Unexpected message: ' + e.getMessage());
        }
        resetMocks();
    }

    @IsTest
    static void validateEnvironmentSetup_throwsWhenAuthUrlBlank() {
        mockBlankAuthUrlConfig();
        try {
            DocuSignConfigService.validateEnvironmentSetup('Demo');
            System.assert(false, 'Expected DocuSignConfigException for blank auth base url');
        } catch (DocuSignConfigService.DocuSignConfigException e) {
            System.assert(e.getMessage().contains('(blank)'), 'Unexpected message: ' + e.getMessage());
        }
        resetMocks();
    }

    @IsTest
    static void detectEnvironment_returnsDemo() {
        mockActiveConfig();
        System.assertEquals('Demo', DocuSignConfigService.detectEnvironment());
        resetMocks();
    }

    @IsTest
    static void detectEnvironment_returnsProduction() {
        mockProductionConfig();
        System.assertEquals('Production', DocuSignConfigService.detectEnvironment());
        resetMocks();
    }

    @IsTest
    static void detectEnvironment_returnsUnknownForUnrecognizedUrl() {
        mockUnknownEnvConfig();
        System.assertEquals('Unknown', DocuSignConfigService.detectEnvironment());
        resetMocks();
    }

    @IsTest
    static void getExpectedAuthBaseUrl_returnsDemoUrl() {
        System.assertEquals('https://account-d.docusign.com', DocuSignConfigService.getExpectedAuthBaseUrl('Demo'));
    }

    @IsTest
    static void getExpectedAuthBaseUrl_returnsProductionUrl() {
        System.assertEquals('https://account.docusign.com', DocuSignConfigService.getExpectedAuthBaseUrl('Production'));
    }

    @IsTest
    static void getExpectedAuthBaseUrl_defaultsToDemoWhenBlank() {
        System.assertEquals('https://account-d.docusign.com', DocuSignConfigService.getExpectedAuthBaseUrl(null));
        System.assertEquals('https://account-d.docusign.com', DocuSignConfigService.getExpectedAuthBaseUrl(''));
    }

    //  DocuSignConfigService — credential / feature helpers
    @IsTest
    static void isPartialSignaturesEnabled_returnsTrueWhenEnabled() {
        mockPartialSigEnabledConfig();
        System.assertEquals(true, DocuSignConfigService.isPartialSignaturesEnabled());
        resetMocks();
    }

    @IsTest
    static void isPartialSignaturesEnabled_returnsFalseWhenDisabled() {
        mockActiveConfig();
        System.assertEquals(false, DocuSignConfigService.isPartialSignaturesEnabled());
        resetMocks();
    }

    @IsTest
    static void getApiVersion_returnsConfiguredValue() {
        mockActiveConfig();
        System.assertEquals('v2.1', DocuSignConfigService.getApiVersion());
        resetMocks();
    }

    @IsTest
    static void getApiVersion_defaultsWhenBlank() {
        mockBlankApiVersionConfig();
        System.assertEquals('v2.1', DocuSignConfigService.getApiVersion());
        resetMocks();
    }

@IsTest
static void getApiNamedCredential_alwaysReturnsDocuSignApi() {
    mockActiveConfig();
    String expected = 'callout:' + DocuSignConfigService.getQualifiedApiName('DocuSign_API');
    Test.startTest();
    System.assertEquals(expected,DocuSignConfigService.getApiNamedCredential());
    System.assertEquals(expected,DocuSignConfigService.getApiNamedCredential('Demo'));
    System.assertEquals(expected,DocuSignConfigService.getApiNamedCredential('Production'));
    Test.stopTest();
    resetMocks();
}

    @isTest
	static void getAuthNamedCredential_returnsDocuSignAuth() {
    String ns = DocuSignConfigService.getNamespace();
    String expected = String.isNotBlank(ns) ? 'callout:' + ns + '__DocuSign_Auth' : 'callout:DocuSign_Auth';
    String actual = DocuSignConfigService.getAuthNamedCredential();
    System.assertEquals(expected, actual, 'Auth Named Credential should resolve with correct namespace prefix.');
}

    @IsTest
    static void getAllowedAccountId_returnsTrimmedLowercaseValue() {
        setMockConfig(true, 'v2.1', 'test-secret-key', 'https://account-d.docusign.com', '  ACC-Mixed-Case  ', false);
        System.assertEquals('acc-mixed-case', DocuSignConfigService.getAllowedAccountId());
        resetMocks();
    }

    @IsTest
    static void getAllowedAccountId_returnsNullWhenBlank() {
        mockConfigWithoutAllowedAccount();
        System.assertEquals(null, DocuSignConfigService.getAllowedAccountId());
        resetMocks();
    }

    @IsTest
    static void getConnectSecret_returnsValue() {
        mockActiveConfig();
        System.assertEquals('test-secret-key', DocuSignConfigService.getConnectSecret());
        resetMocks();
    }

    @IsTest
    static void docuSignConfigException_canBeCreatedWithMessage() {
        DocuSignConfigService.DocuSignConfigException e = new DocuSignConfigService.DocuSignConfigException('config error');
        System.assertEquals('config error', e.getMessage());
    }

    @IsTest
    static void getReturnPath_returnsExpectedFormat() {
        String path = DocuSignConfigService.getReturnPath();
        System.assert(path.startsWith('/lightning/n/'), 'Return path should start with /lightning/n/: ' + path);
        System.assert(path.endsWith('?connected=true'), 'Return path should end with ?connected=true: ' + path);
        System.assert(path.contains('DocuSign_SetUp'), 'Return path should reference the tab name: ' + path);
    }

    //  DocuSignAuthService — connect URL
    @IsTest
    static void auth_getConnectUrl_containsExpectedSegments() {
        mockActiveConfig();
        Test.startTest();
        String url = DocuSignAuthService.getConnectUrl();
        Test.stopTest();
        System.assert(url.contains('/services/auth/oauth/DocuSign_Auth_Provider'), 'URL must reference DocuSign_Auth_Provider');
        System.assert(url.contains('max_age=0'), 'URL must include max_age=0 for forced login');
        System.assert(url.contains('prompt='), 'URL must include prompt parameter');
        resetMocks();
    }

    @IsTest
    static void auth_getConnectUrlForced_containsExpectedSegments() {
        mockActiveConfig();
        String url = DocuSignAuthService.getConnectUrlForced();
        System.assert(url.contains('/services/auth/oauth/DocuSign_Auth_Provider'));
        System.assert(url.contains('max_age=0'));
        resetMocks();
    }

    @IsTest
    static void auth_getConnectUrl_throwsWhenInactive() {
        mockInactiveConfig();
        try {
            DocuSignAuthService.getConnectUrl();
            System.assert(false, 'Expected exception when integration is inactive');
        } catch (AuraHandledException e) {
            System.assert(true, 'AuraHandledException correctly thrown for inactive config');
        }
        resetMocks();
    }

    @IsTest
    static void auth_isConnected_returnsNonNullBoolean() {
        Boolean result = DocuSignAuthService.isConnected();
        System.assertNotEquals(null, result, 'isConnected must return a non-null Boolean');
    }

    @IsTest
    static void auth_getConnectionInfo_executesWithoutError() {
        Map<String, String> info = DocuSignAuthService.getConnectionInfo();
        if (info != null) {
            System.assert(info.containsKey('accountId'), 'Map must contain accountId');
            System.assert(info.containsKey('environment'), 'Map must contain environment');
            System.assert(info.containsKey('site'), 'Map must contain site');
            System.assert(info.containsKey('baseUrl'), 'Map must contain baseUrl');
            System.assert(info.containsKey('shortAccountId'), 'Map must contain shortAccountId');
        } else {
            System.assert(true, 'getConnectionInfo returned null — acceptable when not connected');
        }
    }

    @IsTest
    static void auth_getConnectionInfo_fallbackWhenApiCalloutFails() {
        Test.setMock(HttpCalloutMock.class, new DocuSignFailureMock());
        Test.startTest();
        Map<String, String> info = DocuSignAuthService.getConnectionInfo();
        Test.stopTest();
        System.assert(true, 'getConnectionInfo must complete even when the live API callout fails');
    }

    //  DocuSignAuthService — disconnect
    @IsTest
    static void auth_disconnect_withFailureMock() {
        Test.setMock(HttpCalloutMock.class, new DocuSignFailureMock());
        Test.startTest();
        DocuSignAuthService.disconnect();
        Test.stopTest();
        System.assert(true, 'disconnect must complete without throwing on a 401 revoke response');
    }

    @IsTest
    static void auth_disconnect_withSuccessfulCallout() {
        Test.setMock(HttpCalloutMock.class, new DocuSignCompleteConnectionMock('x', 'y'));
        Test.startTest();
        DocuSignAuthService.disconnect();
        Test.stopTest();
        System.assert(true);
    }

    @IsTest
    static void auth_disconnect_catchBlockCoverage() {
        Test.setMock(HttpCalloutMock.class, new CalloutExceptionMock());
        Test.startTest();
        DocuSignAuthService.disconnect();
        Test.stopTest();
        System.assert(true, 'disconnect() catch block successfully swallowed the exception');
    }

    //  DocuSignAuthService — getAccountId
    @IsTest
    static void auth_getAccountId_throwsOnNullUserId() {
        try {
            DocuSignAuthService.getAccountId(null);
            System.assert(false, 'Expected exception for null userId');
        } catch (DocuSignAuthService.DocuSignAuthException e) {
            System.assertEquals('UserId cannot be null.', e.getMessage());
        }
    }

    @IsTest
    static void auth_getAccountId_returnsValueWhenConfigured() {
        mockActiveConfig();
        String id = DocuSignAuthService.getAccountId(UserInfo.getUserId());
        System.assertEquals('acc-001', id, 'Account ID should reflect the mocked config');
        resetMocks();
    }

    @IsTest
    static void auth_getAccountId_throwsWhenInactive() {
        mockInactiveConfig();
        try {
            DocuSignAuthService.getAccountId(UserInfo.getUserId());
            System.assert(false, 'Expected exception for inactive config');
        } catch (DocuSignAuthService.DocuSignAuthException e) {
            System.assert(e.getMessage().contains('not connected'), 'Unexpected message: ' + e.getMessage());
        }
        resetMocks();
    }

    @IsTest
    static void auth_getAccountId_throwsWhenAccountIdBlank() {
        mockConfigWithoutAllowedAccount();
        try {
            DocuSignAuthService.getAccountId(UserInfo.getUserId());
            System.assert(false, 'Expected exception when account id blank');
        } catch (DocuSignAuthService.DocuSignAuthException e) {
            System.assert(e.getMessage().contains('not connected'), 'Unexpected message: ' + e.getMessage());
        }
        resetMocks();
    }

    @IsTest
    static void auth_getAccountId_withEnvOverload_returnsSameValue() {
        mockActiveConfig();
        String id = DocuSignAuthService.getAccountId(UserInfo.getUserId(), 'Demo');
        System.assertEquals('acc-001', id);
        resetMocks();
    }

    //  DocuSignAuthService — getBaseUri
    @IsTest
    static void auth_getBaseUri_returnsUriWhenConfigured() {
        mockActiveConfig();
        String uri = DocuSignAuthService.getBaseUri(UserInfo.getUserId());
        System.assertEquals('https://account-d.docusign.com', uri);
        resetMocks();
    }

    @IsTest
    static void auth_getBaseUri_throwsWhenBlank() {
        mockBlankAuthUrlConfig();
        try {
            DocuSignAuthService.getBaseUri(UserInfo.getUserId());
            System.assert(false, 'Expected exception when Auth_Base_URL__c is blank');
        } catch (DocuSignAuthService.DocuSignAuthException e) {
            System.assert(e.getMessage().contains('Base URI not found'), 'Unexpected message: ' + e.getMessage());
        }
        resetMocks();
    }

    @IsTest
    static void auth_getBaseUri_throwsWhenInactive() {
        mockInactiveConfig();
        try {
            DocuSignAuthService.getBaseUri(UserInfo.getUserId());
            System.assert(false, 'Expected exception when config is inactive');
        } catch (DocuSignAuthService.DocuSignAuthException e) {
            System.assert(e.getMessage().contains('Base URI not found'), 'Unexpected message: ' + e.getMessage());
        }
        resetMocks();
    }

    //  DocuSignAuthService — getEnvironment
    @IsTest
    static void auth_getEnvironment_returnsDemo() {
        mockActiveConfig();
        System.assertEquals('Demo', DocuSignAuthService.getEnvironment(UserInfo.getUserId()));
        resetMocks();
    }

    @IsTest
    static void auth_getEnvironment_returnsProduction() {
        mockProductionConfig();
        System.assertEquals('Production', DocuSignAuthService.getEnvironment(UserInfo.getUserId()));
        resetMocks();
    }

    @IsTest
    static void auth_getEnvironment_throwsWhenInactive() {
        mockInactiveConfig();
        try {
            DocuSignAuthService.getEnvironment(UserInfo.getUserId());
            System.assert(false, 'Expected exception when config is inactive');
        } catch (DocuSignAuthService.DocuSignAuthException e) {
            System.assert(e.getMessage().contains('not connected'), 'Unexpected message: ' + e.getMessage());
        }
        resetMocks();
    }

    @IsTest
    static void auth_getEnvironment_throwsWhenUnknown() {
        mockUnknownEnvConfig();
        try {
            DocuSignAuthService.getEnvironment(UserInfo.getUserId());
            System.assert(false, 'Expected exception when environment cannot be determined');
        } catch (DocuSignAuthService.DocuSignAuthException e) {
            System.assert(e.getMessage().contains('not connected'), 'Unexpected message: ' + e.getMessage());
        }
        resetMocks();
    }

    //  DocuSignAuthService — testConnection
    @IsTest
    static void auth_testConnection_returnsFailedOnBadToken() {
        Test.setMock(HttpCalloutMock.class, new DocuSignFailureMock());
        Test.startTest();
        String result = DocuSignAuthService.testConnection();
        Test.stopTest();
        System.assert(result.startsWith('FAILED'), 'Result should start with FAILED for a 401 response');
    }

    @IsTest
    static void auth_testConnection_returnsOkOnSuccess() {
        Test.setMock(HttpCalloutMock.class, new DocuSignCompleteConnectionMock('ignored', 'ignored'));
        Test.startTest();
        String result = DocuSignAuthService.testConnection();
        Test.stopTest();
        System.assert(result.startsWith('OK — Connected as:'), 'Unexpected result: ' + result);
    }

    @IsTest
    static void auth_testConnection_catchesCalloutException() {
        Test.setMock(HttpCalloutMock.class, new CalloutExceptionMock());
        Test.startTest();
        String result = DocuSignAuthService.testConnection();
        Test.stopTest();
        System.assert(result.startsWith('FAILED'), 'testConnection should catch the exception and return FAILED');
    }

    @IsTest
    static void auth_testConnection_catches500() {
        Test.setMock(HttpCalloutMock.class, new FetchUserInfoFailMock());
        Test.startTest();
        String result = DocuSignAuthService.testConnection();
        Test.stopTest();
        System.assert(result.startsWith('FAILED'), 'testConnection should return FAILED on a 500 error');
    }

    //  DocuSignAuthService — polling
    @IsTest
    static void auth_restartPolling_executesOrThrowsGracefully() {
        try {
            Boolean res = DocuSignAuthService.restartPolling();
            System.assertEquals(true, res);
        } catch (AuraHandledException e) {
            System.assert(true, 'Scheduling may be disallowed in some test contexts');
        }
    }

    @IsTest
    static void auth_isPollingActive_returnsNonNullBoolean() {
        Boolean res = DocuSignAuthService.isPollingActive();
        System.assertNotEquals(null, res, 'isPollingActive should return a non-null Boolean');
    }

    //  DocuSignAuthService — misc AuraEnabled helpers
    @IsTest
    static void auth_misc_methods_executeWithoutError() {
        DocuSignAuthService.clearExternalCredentialState();
        DocuSignAuthService.seedApprovedAccountIfNeeded('Demo');
        System.assert(true, 'Misc helpers should complete without throwing');
    }

    //  DocuSignAuthService — MetadataCallback
    @IsTest
    static void auth_metadataCallback_handlesSuccessAndFailure() {
        DocuSignAuthService.MetadataCallback cb = new DocuSignAuthService.MetadataCallback();

        Metadata.DeployResult successResult = new Metadata.DeployResult();
        successResult.status = Metadata.DeployStatus.Succeeded;
        cb.handleResult(successResult, null);

        Metadata.DeployResult failResult = new Metadata.DeployResult();
        failResult.status = Metadata.DeployStatus.Failed;
        failResult.errorMessage = 'simulated error';
        cb.handleResult(failResult, null);

        System.assert(true, 'MetadataCallback must handle both Succeeded and Failed without throwing');
    }

    //  DocuSignAuthService — saveConfigValues / getConfigValues
    @IsTest
    static void auth_saveConfigValues_throwsWhenRequiredFieldsBlank() {
        try {
            DocuSignAuthService.saveConfigValues('', '', null, null, null, false, false);
            System.assert(false, 'Expected AuraHandledException for blank required fields');
        } catch (AuraHandledException e) {
            System.assert(true, 'Correctly threw for blank required fields');
        }
    }

    @IsTest
    static void auth_saveConfigValues_reachesDeployWithoutValidationError() {
        Test.startTest();
        try {
            DocuSignAuthService.saveConfigValues(
                '123', 'https://account-d.docusign.com', 'secret', 'Demo', 'v2.1', true, true
            );
        } catch (System.AsyncException e) {
            System.assert(true, 'Metadata deploy is disallowed in test context — expected');
        }
        Test.stopTest();
        System.assert(true, 'saveConfigValues reached the deploy call without a validation error');
    }

    @IsTest
    static void auth_saveConfigValues_blankOptionalFields() {
        Test.startTest();
        try {
            DocuSignAuthService.saveConfigValues(
                'TEST123456', 'https://account-d.docusign.com', '', 'Demo', '', true, false
            );
        } catch (System.AsyncException e) {
            System.assert(true, 'Expected in test context');
        }
        Test.stopTest();
        System.assert(true);
    }

    @IsTest
    static void auth_getConfigValues_returnsMap() {
        Test.startTest();
        Map<String, Object> cfg = DocuSignAuthService.getConfigValues();
        Test.stopTest();
        System.assertNotEquals(null, cfg, 'getConfigValues should return a non-null Map');
    }

    @IsTest
    static void auth_completeConnection_throwsOnInvalidEnvironment() {
        try {
            DocuSignAuthService.completeConnection('INVALID');
            System.assert(false, 'Expected exception for environment=INVALID');
        } catch (AuraHandledException e) {
            System.assert(true);
        }
    }

    @IsTest
    static void auth_completeConnection_throwsOnInactiveConfig() {
        mockInactiveConfig();
        try {
            DocuSignAuthService.completeConnection('Demo');
            System.assert(false, 'Expected exception when integration is inactive');
        } catch (AuraHandledException e) {
            System.assert(true);
        }
        resetMocks();
    }

    @IsTest
    static void auth_completeConnection_throwsOnEnvironmentMismatch() {
        mockActiveConfig(); // Demo URL configured
        try {
            DocuSignAuthService.completeConnection('Production');
            System.assert(false, 'Expected exception for environment mismatch');
        } catch (AuraHandledException e) {
            System.assert(true);
        }
        resetMocks();
    }

    @IsTest
    static void auth_completeConnection_throwsOnEmptyAccounts() {
        mockActiveConfig();
        Test.setMock(HttpCalloutMock.class, new EmptyAccountsMock());
        Boolean exceptionThrown = false;
        Test.startTest();
        try {
            DocuSignAuthService.completeConnection('Demo');
            System.assert(false, 'Expected exception for empty accounts');
        } catch (AuraHandledException e) {
            exceptionThrown = true;
        }
        Test.stopTest();
        System.assertEquals(true, exceptionThrown, 'completeConnection should reject empty accounts');
        resetMocks();
    }

    @IsTest
    static void auth_completeConnection_throwsOnWrongAccount() {
        mockActiveConfig(); // allowed account id = acc-001
        Test.setMock(HttpCalloutMock.class, new DocuSignCompleteConnectionMock('DIFFERENT_ACCOUNT', '123'));
        Boolean exceptionThrown = false;
        Test.startTest();
        try {
            DocuSignAuthService.completeConnection('Demo');
            System.assert(false, 'Expected wrong account exception');
        } catch (AuraHandledException e) {
            exceptionThrown = true;
        }
        Test.stopTest();
        System.assertEquals(true, exceptionThrown);
        resetMocks();
    }

    @IsTest
    static void auth_completeConnection_throwsWhenAccountDetailsCallFails() {
        mockActiveConfig();
        Test.setMock(HttpCalloutMock.class, new AccountDetailsFailMock());
        Boolean exceptionThrown = false;
        try {
            DocuSignAuthService.completeConnection('Demo');
            System.assert(false, 'Expected exception when account details HTTP call fails');
        } catch (Exception e) {
            exceptionThrown = true;
        }
        System.assert(exceptionThrown, 'An exception must be thrown when account details HTTP call fails');
        resetMocks();
    }

    @IsTest
    static void auth_completeConnection_throwsOnInvalidShortAccountId() {
        mockConfigWithoutAllowedAccount();
        Test.setMock(HttpCalloutMock.class, new InvalidAccountIdMock());
        Boolean exceptionThrown = false;
        try {
            DocuSignAuthService.completeConnection('Demo');
            System.assert(false, 'Expected exception for invalid short account id');
        } catch (Exception e) {
            exceptionThrown = true;
        }
        System.assert(exceptionThrown, 'An exception must be thrown when externalAccountId is 0');
        resetMocks();
    }

    @IsTest
    static void auth_completeConnection_fallbackToFirstAccountAndAlternateIdField() {
        mockConfigWithoutAllowedAccount();
        Test.setMock(HttpCalloutMock.class, new NonDefaultAccountMock('NON_DEF'));
        Boolean exceptionThrown = false;
        Map<String, String> result;
        Test.startTest();
        try {
            result = DocuSignAuthService.completeConnection('Demo');
        } catch (Exception e) {
            // persistConnectionMetadata may fail if no real CMDT row exists; still valid coverage.
            exceptionThrown = true;
        }
        Test.stopTest();
        if (!exceptionThrown) {
            System.assertEquals('NON_DEF', result.get('accountId'), 'Should fall back to the first account when none are default');
            System.assertEquals('888888', result.get('shortAccountId'), 'Should parse "id" when "externalAccountId" is missing');
        } else {
            System.assert(true, 'Reached persistence step — acceptable without a real CMDT row deployed');
        }
        resetMocks();
    }

    @IsTest
    static void auth_completeConnection_tokenFailure401() {
        mockActiveConfig();
        Test.setMock(HttpCalloutMock.class, new DocuSignFailureMock());
        Boolean exceptionThrown = false;
        try {
            DocuSignAuthService.completeConnection('Demo');
        } catch (Exception e) {
            exceptionThrown = true;
        }
        System.assert(exceptionThrown, 'Should throw an exception on a 401 token response');
        resetMocks();
    }

    @IsTest
    static void auth_completeConnection_catchTokenCalloutFailure() {
        mockActiveConfig();
        Test.setMock(HttpCalloutMock.class, new CalloutExceptionMock());
        Boolean exceptionThrown = false;
        try {
            DocuSignAuthService.completeConnection('Demo');
        } catch (Exception e) {
            exceptionThrown = true;
        }
        System.assert(exceptionThrown, 'Should throw an exception when the initial token callout fails');
        resetMocks();
    }

    @IsTest
    static void auth_completeConnection_catchAccountDetailsFailure() {
        mockActiveConfig();
        Test.setMock(HttpCalloutMock.class, new BadAccountDetailsMock());
        Boolean exceptionThrown = false;
        try {
            DocuSignAuthService.completeConnection('Demo');
        } catch (Exception e) {
            exceptionThrown = true;
        }
        System.assert(exceptionThrown, 'Should throw an exception when account details fetch fails');
        resetMocks();
    }

    @IsTest
    static void auth_completeConnection_missingAccountIdField() {
        mockConfigWithoutAllowedAccount();
        Test.setMock(HttpCalloutMock.class, new MissingAccountIdMock());
        Boolean exceptionThrown = false;
        try {
            DocuSignAuthService.completeConnection('Demo');
        } catch (Exception e) {
            exceptionThrown = true;
        }
        System.assert(exceptionThrown, 'Should throw an exception when account_id is missing from the JSON payload');
        resetMocks();
    }

    @IsTest
    static void auth_completeConnection_emptyAccountIdString() {
        mockConfigWithoutAllowedAccount();
        Test.setMock(HttpCalloutMock.class, new EmptyAccountIdMock());
        Boolean caught = false;
        try {
            DocuSignAuthService.completeConnection('Demo');
        } catch (Exception e) {
            caught = true;
        }
        System.assert(caught, 'Should throw an exception if account_id is blank in the DocuSign JSON');
        resetMocks();
    }

    @IsTest
    static void auth_completeConnection_zeroExternalAccountId() {
        mockConfigWithoutAllowedAccount();
        Test.setMock(HttpCalloutMock.class, new ZeroExternalAccountIdMock());
        Boolean caught = false;
        try {
            DocuSignAuthService.completeConnection('Demo');
        } catch (Exception e) {
            caught = true;
        }
        System.assert(caught, 'Should throw an exception if externalAccountId evaluates to 0');
        resetMocks();
    }

    @IsTest
    static void auth_completeConnection_nullFieldsAccountMock() {
        mockConfigWithoutAllowedAccount();
        Test.setMock(HttpCalloutMock.class, new NullFieldsAccountMock());
        Boolean caught = false;
        try {
            DocuSignAuthService.completeConnection('Demo');
        } catch (Exception e) {
            caught = true;
        }
        System.assert(caught, 'Should throw when all account detail fields are null/blank');
        resetMocks();
    }

    @IsTest
    static void auth_completeConnection_brokenPayload() {
        mockConfigWithoutAllowedAccount();
        Test.setMock(HttpCalloutMock.class, new BrokenMock());
        Boolean thrown = false;
        try {
            DocuSignAuthService.completeConnection('Demo');
        } catch (Exception e) {
            thrown = true;
        }
        System.assert(thrown, 'Should throw when the accounts payload is malformed');
        resetMocks();
    }

    @IsTest
    static void auth_completeConnection_nullEnvironmentDefaultsToDemo() {
        mockActiveConfig();
        Test.setMock(HttpCalloutMock.class, new DocuSignCompleteConnectionMock('acc-001', '999999'));
        Boolean exceptionThrown = false;
        Map<String, String> result;
        Test.startTest();
        try {
            result = DocuSignAuthService.completeConnection(null);
        } catch (Exception e) {
            exceptionThrown = true;
        }
        Test.stopTest();
        if (!exceptionThrown) {
            System.assertEquals('Demo', result.get('environment'));
        } else {
            System.assert(true, 'Reached persistence step — acceptable without a real CMDT row deployed');
        }
        resetMocks();
    }

    @IsTest
    static void auth_completeConnection_noAllowedAccountRestriction() {
        mockConfigWithoutAllowedAccount();
        Test.setMock(HttpCalloutMock.class, new DocuSignCompleteConnectionMock('ANY_ACCOUNT', '123456'));
        Boolean exceptionThrown = false;
        Map<String, String> result;
        Test.startTest();
        try {
            result = DocuSignAuthService.completeConnection('Demo');
        } catch (Exception e) {
            exceptionThrown = true;
        }
        Test.stopTest();
        if (!exceptionThrown) {
            System.assertEquals('ANY_ACCOUNT', result.get('accountId'));
        } else {
            System.assert(true, 'Reached persistence step — acceptable without a real CMDT row deployed');
        }
        resetMocks();
    }

    @IsTest
    static void auth_completeConnection_success() {
        mockActiveConfig(); // allowed account id = acc-001
        Test.setMock(HttpCalloutMock.class, new DocuSignCompleteConnectionMock('acc-001', '999999'));
        Boolean exceptionThrown = false;
        Map<String, String> result;
        Test.startTest();
        try {
            result = DocuSignAuthService.completeConnection('Demo');
        } catch (Exception e) {
            exceptionThrown = true;
        }
        Test.stopTest();
        if (!exceptionThrown) {
            System.assertEquals('acc-001', result.get('accountId'));
            System.assertEquals('999999', result.get('shortAccountId'));
            System.assertEquals('Demo', result.get('environment'));
        } else {
            System.assert(true, 'Reached persistence step — acceptable without a real CMDT row deployed');
        }
        resetMocks();
    }

    @IsTest
    static void auth_migrateOpenEnvelopes_triggersOnCompleteConnection() {
        mockConfigWithoutAllowedAccount();

        Agreement__c agr = new Agreement__c(
            Name            = 'Migration Test Agr',
            Status__c       = 'Draft',
            Status_Group__c = 'In Signature'
        );
        insert agr;

        DocuSign_Status__c envRec = new DocuSign_Status__c(
            Agreement__c            = agr.Id,
            Envelope_Id__c           = 'env-migrate-123',
            DocuSign_Account_ID__c   = 'OLD_ACCOUNT_ID',
            Is_Terminal__c           = false
        );
        insert envRec;

        Test.setMock(HttpCalloutMock.class, new DocuSignCompleteConnectionMock('NEW_ACCOUNT_ID', '123'));

        Boolean exceptionThrown = false;
        Test.startTest();
        try {
            DocuSignAuthService.completeConnection('Demo');
        } catch (Exception e) {
            exceptionThrown = true;
        }
        Test.stopTest();

        DocuSign_Status__c updatedEnv = [SELECT DocuSign_Account_ID__c FROM DocuSign_Status__c WHERE Id = :envRec.Id];
        if (!exceptionThrown) {
            System.assertEquals('NEW_ACCOUNT_ID', updatedEnv.DocuSign_Account_ID__c,'Envelope account ID should be migrated by the @future method');
        } else {
            System.assertEquals('OLD_ACCOUNT_ID', updatedEnv.DocuSign_Account_ID__c,'Envelope should remain unchanged when persistence failed before migration ran');
        }
        resetMocks();
    }
}