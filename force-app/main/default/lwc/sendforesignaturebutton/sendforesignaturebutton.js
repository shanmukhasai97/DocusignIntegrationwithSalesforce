import { LightningElement, api } from 'lwc';
import checkForSignedDocuments from '@salesforce/apex/DocuSignAgreementService.checkForSignedDocuments';
import isSignedDownloadComplete from '@salesforce/apex/DocuSignAgreementService.isSignedDownloadComplete';
import AgreementSendForEsignature from 'c/agreementSendForEsignature';
//import AgreementTemplateSelector from 'c/agreementTemplateSelector';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { RefreshEvent } from 'lightning/refresh';
const POLL_INTERVAL_MS = 3000;
const MAX_POLL_ATTEMPTS = 5; // ~30s ceiling

export default class SendForEsignatureButton extends LightningElement {
    @api recordId;
    isChecking = false;
    // Open eSignature Modal
    async handleSendForEsignature() {
        const result = await AgreementSendForEsignature.open({
            size: 'large',
            recordId: this.recordId
        });
    }
    /* Manually fetch signed documents without waiting for the polling schedule.
     Safe to click even while polling is active — downloadSignedPdf's own title 
     check prevents duplicate ContentVersion files being created.*/
     async handleCheckForSignedDocuments() {
        if (this.isChecking) return;
        this.isChecking = true;

        try {
            const result = await checkForSignedDocuments({ agreementId: this.recordId });

            if (result === 'NO_ENVELOPES') {
                this.toast('No Envelopes', 'No DocuSign envelopes were found for this agreement.', 'info');
                this.isChecking = false;
                return;
            }
            if (result === 'NO_COMPLETED_ENVELOPES') {
                this.toast('Not Completed', 'No completed DocuSign envelopes are available yet.', 'info');
                this.isChecking = false;
                return;
            }
            if (result.startsWith('QUEUED_')) {
                const [countPart, envelopeIdsCsv] = result.replace('QUEUED_', '').split('|');
                this.toast('Download Started', `${countPart} completed envelope(s) queued for signed document download.`, 'info');
                // keep spinner going while we wait for the async job
                await this.pollUntilComplete(envelopeIdsCsv);
            }
        } catch (error) {
            this.toast('Error', error?.body?.message || 'Failed to check for signed documents.', 'error');
            this.isChecking = false;
        }
    }

    async pollUntilComplete(envelopeIdsCsv) {
        for (let attempt = 0; attempt < MAX_POLL_ATTEMPTS; attempt++) {
            await this.sleep(POLL_INTERVAL_MS);
            try {
                const done = await isSignedDownloadComplete({
                    agreementId: this.recordId,
                    envelopeIdsCsv
                });
                if (done) {
                    this.toast('Signed Documents Ready', 'Signed document(s) were successfully downloaded.', 'success');
                    this.dispatchEvent(new RefreshEvent()); // refreshes the record page / related lists
                    this.isChecking = false;
                    return;
                }
            } catch (error) {
                // status check failing shouldn't block the user forever
                console.error('Polling error', error);
            }
        }
        // Timed out — job may still be running, don't call it a failure
        this.toast('Still Processing', 'This is taking longer than expected. The file will appear once processing completes.', 'info');
        this.isChecking = false;
    }

    sleep(ms) {
        return new Promise((resolve) => setTimeout(resolve, ms));
    }

    toast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }

    // Open Template Selector Modal
    /*
    async handleDisplayTemplates() {
        const result = await AgreementTemplateSelector.open({
            size: 'large',
            recordId: this.recordId
        });
    }
    */
}