import { LightningElement, track, wire } from 'lwc';
import { NavigationMixin, CurrentPageReference } from 'lightning/navigation';
import { ShowToastEvent }  from 'lightning/platformShowToastEvent';
import checkIsConnected    from '@salesforce/apex/DocuSignAuthService.isConnected';
import getConnectUrl from '@salesforce/apex/DocuSignAuthService.getConnectUrl';
import getConnectUrlForced from '@salesforce/apex/DocuSignAuthService.getConnectUrlForced';
import completeConnection  from '@salesforce/apex/DocuSignAuthService.completeConnection';
import disconnectApex      from '@salesforce/apex/DocuSignAuthService.disconnect';
import getConnectionInfo   from '@salesforce/apex/DocuSignAuthService.getConnectionInfo';
import restartPolling      from '@salesforce/apex/DocuSignAuthService.restartPolling';
import isPollingActive     from '@salesforce/apex/DocuSignAuthService.isPollingActive';
import seedApprovedAccountIfNeeded from '@salesforce/apex/DocuSignAuthService.seedApprovedAccountIfNeeded';
import getConfigValues    from '@salesforce/apex/DocuSignAuthService.getConfigValues';
import saveConfigValues   from '@salesforce/apex/DocuSignAuthService.saveConfigValues';
const FORCE_REAUTH_KEY   = 'docusign_force_reauth';
const PENDING_CONNECT_KEY = 'docusign_pending_connect'; 

export default class DocuSignSetup extends NavigationMixin(LightningElement) {

    @track isConnected      = false;
    @track isLoading        = false;
    @track isCompleting     = false;
    @track errorMessage     = '';
    @track connectionInfo   = {};
    @track environment      = 'Demo';
    @track isPollingRunning = false;
    @track configAccountId   = '';
    @track configAuthBaseUrl = '';
    @track configSecretKey   = '';
    @track configSaveSuccess = false;
    @track configSaveError   = '';
    @track isSavingConfig    = false;
    @track configApiVersion = '';
    @track configActive = true;
    @track configEnablePartialSign = false;
    // Added to support the new UI's Account Name mapping 
    get displayCompanyName() {
    return this.connectionInfo?.companyName || this.connectionInfo?.accountName || '';
}
    get displayAccountName() {
    return this.connectionInfo?.accountName || 'DocuSign Account';
}
get displaySite() {
    return this.connectionInfo?.site || '';
}
    get environmentLabel() {
        const env = (this.connectionInfo && this.connectionInfo.environment) || this.environment || '';
        return env.toLowerCase() === 'production' ? 'Production' : 'Developer';
    }

   get displayAccountId() {
    const shortId = this.connectionInfo?.shortAccountId;
    if (!shortId || shortId.includes('-')) return '';
    return 'Account: ' + shortId;
}

    environmentOptions = [
        { label: 'Demo (Sandbox)', value: 'Demo'       },
        { label: 'Production',     value: 'Production' }
    ];

    _oauthHandled = false;
    _statusLoaded = false;

    @wire(CurrentPageReference)
    handlePageRef(pageRef) {
        if (!pageRef) return;

        const state = pageRef.state || {};
        console.log('[DocuSignSetup] CurrentPageReference fired. state=', JSON.stringify(state));

        const isOAuthReturnFromUrl =
            state.connected    === 'true' ||
            state.c__connected === 'true';

        const pendingEnv             = sessionStorage.getItem(PENDING_CONNECT_KEY);
        const isOAuthReturnFromStore = pendingEnv !== null;

        const isOAuthReturn = isOAuthReturnFromUrl || isOAuthReturnFromStore;
        const envParam = state.env || state.c__env || pendingEnv || 'Demo';

        console.log('[DocuSignSetup] isOAuthReturn=' + isOAuthReturn
            + ' source=' + (isOAuthReturnFromUrl ? 'URL' : isOAuthReturnFromStore ? 'sessionStorage' : 'none')
            + ' env=' + envParam);

        if (isOAuthReturn && !this._oauthHandled) {
            this._oauthHandled = true;
            this._statusLoaded = true;
            this.environment   = envParam;

            sessionStorage.removeItem(PENDING_CONNECT_KEY);
            this.handleOAuthCompletion();

        } else if (!isOAuthReturn && !this._statusLoaded) {
            this._statusLoaded = true;
            this.loadStatus();
        }
    }

    handleOAuthCompletion() {
        if (this.isCompleting) return;
        this.isCompleting = true;
        this.isLoading    = true;

        console.log('[DocuSignSetup] Calling completeConnection. env=' + this.environment);

        completeConnection({ environment: this.environment })
            .then(result => {
                console.log('[DocuSignSetup] completeConnection SUCCESS:', JSON.stringify(result));
                this.isConnected      = true;
                this.connectionInfo   = result;
                this.isPollingRunning = true;
                sessionStorage.removeItem(FORCE_REAUTH_KEY);
                this.dispatchEvent(new ShowToastEvent({
                    title:   'Connected!',
                    message: 'DocuSign connected — ' + (result.accountName || result.accountId),
                    variant: 'success'
                }));
            })
        .catch(error => {
            console.error('[DocuSignSetup] completeConnection FAILED:', error);
            const msg = error.body?.message || 'Connection failed. Please try again.';
            
            // 1. This updates the inline red box at the bottom (KEEP THIS)
            this.errorMessage = msg;

            /* 2. REMOVE OR COMMENT OUT THIS TOAST EVENT 
               This was causing the duplicate red banner at the top of the screen.
               
            this.dispatchEvent(new ShowToastEvent({
                title:   'Connection Failed',
                message: msg,
                variant: 'error',
                mode:    'sticky'          
            }));
            */

            // On account mismatch, force DocuSign login prompt on next Connect attempt
            if (msg && msg.includes('Wrong DocuSign account')) {
                sessionStorage.setItem(FORCE_REAUTH_KEY, 'true');
            }
        })
            .finally(() => {
                this.isCompleting = false;
                this.isLoading    = false;
                this.clearUrlParams();
            });
    }

loadStatus() {
    this.isLoading = true;

    checkIsConnected()
        .then(connected => {
            this.isConnected = connected;
            if (connected) {
                return getConnectionInfo();
            }
            // Not connected — load current config values into the form
            return getConfigValues()
                .then(cfg => {
                    if (cfg) {
                        this.configAccountId   = cfg.accountId   || '';
                        this.configAuthBaseUrl = cfg.authBaseUrl || '';
                        this.configSecretKey   = cfg.secretKey   || '';
                        this.configApiVersion        = cfg.apiVersion || '';
                        this.configActive            = cfg.active || false;
                        this.configEnablePartialSign = cfg.enablePartialSign || false;
                    }
                })
                .then(() => {
                    seedApprovedAccountIfNeeded({ environment: this.environment })
                        .catch(err => {
                            console.warn('[DocuSignSetup] seedApprovedAccountIfNeeded failed:', err);
                        });
                    return null;
                });
        })
        .then(info => {
            if (info) {
                this.connectionInfo = info;
                if (info.environment) this.environment = info.environment;
                return isPollingActive();
            }
            return false;
        })
        .then(active => { this.isPollingRunning = active; })
        .catch(err   => { this.errorMessage = err.body?.message || 'Error checking status.'; })
        .finally(()  => { this.isLoading = false; });
}

    handleEnvironmentChange(event) {
        this.environment  = event.detail.value;
        this.errorMessage = '';
    }

handleConnect() {
    this.isLoading    = true;
    this.errorMessage = '';

    sessionStorage.setItem(PENDING_CONNECT_KEY, this.environment);
    console.log('[DocuSignSetup] Stored pending connect env=' + this.environment);

    const needsForceLogin = sessionStorage.getItem(FORCE_REAUTH_KEY) === 'true';
    const getUrl = needsForceLogin ? getConnectUrlForced : getConnectUrl;

    getUrl()                              // ← was getUrl({ environment: this.environment })
        .then(url => {
            console.log('[DocuSignSetup] Redirecting to OAuth URL:', url);
            window.location.href = url;
        })
        .catch(err => {
            sessionStorage.removeItem(PENDING_CONNECT_KEY);
            this.isLoading    = false;
            this.errorMessage = err.body?.message || 'Failed to get connect URL.';
        });
}

    handleDisconnect() {
    this.isLoading = true;

    disconnectApex()
        .then(() => {
            this.isConnected      = false;
            this.connectionInfo   = {};
            this.isPollingRunning = false;
            this._statusLoaded    = false;
            sessionStorage.setItem(FORCE_REAUTH_KEY, 'true');
            return getConfigValues();
        })
        .then(cfg => {
            if (cfg) {
                this.configAccountId         = cfg.accountId        || '';
                this.configAuthBaseUrl       = cfg.authBaseUrl       || '';
                this.configSecretKey         = cfg.secretKey         || '';
                this.configApiVersion        = cfg.apiVersion        || '';
                this.configActive            = cfg.active            || false;
                this.configEnablePartialSign = cfg.enablePartialSign || false;
            }
            this.dispatchEvent(new ShowToastEvent({
                title:   'Disconnected',
                message: 'DocuSign account disconnected. Sign in again to reconnect.',
                variant: 'warning'
            }));
        })
        .catch(err => { this.errorMessage = err.body?.message || 'Failed to disconnect.'; })
        .finally(() => { this.isLoading = false; });
}

    handleRestartPolling() {
        restartPolling()
            .then(() => {
                this.isPollingRunning = true;
                this.dispatchEvent(new ShowToastEvent({
                    title:   'Polling Started',
                    message: 'DocuSign background polling is now running.',
                    variant: 'success'
                }));
            })
            .catch(err => { this.errorMessage = err.body?.message || 'Could not start polling.'; });
    }
    handleConfigAccountIdChange(event) {
    this.configAccountId   = event.target.value;
    this.configSaveSuccess = false;
    this.configSaveError   = '';
}

handleConfigAuthBaseUrlChange(event) {
    this.configAuthBaseUrl = event.target.value;
    this.configSaveSuccess = false;
    this.configSaveError   = '';
}

handleConfigSecretKeyChange(event) {
    this.configSecretKey   = event.target.value;
    this.configSaveSuccess = false;
    this.configSaveError   = '';
}
handleConfigApiVersionChange(event) {
    this.configApiVersion = event.target.value;
    this.configSaveSuccess = false;
    this.configSaveError = '';
}

handleConfigActiveChange(event) {
    this.configActive = event.target.checked;
    this.configSaveSuccess = false;
    this.configSaveError = '';
}

handleConfigEnablePartialSignChange(event) {
    this.configEnablePartialSign = event.target.checked;
    this.configSaveSuccess = false;
    this.configSaveError = '';
}

handleSaveConfig() {
    if (!this.configAccountId || !this.configAuthBaseUrl) {
        this.configSaveError = 'Account ID and Auth Base URL are required.';
        return;
    }
    this.isSavingConfig    = true;
    this.configSaveSuccess = false;
    this.configSaveError   = '';

    saveConfigValues({
    accountId          : this.configAccountId,
    authBaseUrl        : this.configAuthBaseUrl,
    secretKey          : this.configSecretKey,
    environment        : this.environment,
    apiVersion         : this.configApiVersion,
    active             : this.configActive,
    enablePartialSign  : this.configEnablePartialSign
})
        .then(() => {
            this.configSaveSuccess = true;
        })
        .catch(err => {
            this.configSaveError = err.body?.message || 'Failed to save configuration.';
        })
        .finally(() => {
            this.isSavingConfig = false;
        });
}

    clearUrlParams() {
        try {
            const url = new URL(window.location.href);
            if (url.search) {
                url.search = '';
                window.history.replaceState(null, '', url.toString());
            }
        } catch (e) {
            console.error('[DocuSignSetup] clearUrlParams error:', e);
        }
    }
}