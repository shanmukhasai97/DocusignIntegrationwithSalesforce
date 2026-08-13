import { LightningElement, api } from 'lwc';

import AgreementSendForEsignature from 'c/agreementSendForEsignature';
//import AgreementTemplateSelector from 'c/agreementTemplateSelector';

export default class SendForEsignatureButton extends LightningElement {
    @api recordId;

    // Open eSignature Modal
    async handleSendForEsignature() {
        const result = await AgreementSendForEsignature.open({
            size: 'large',
            recordId: this.recordId
        });

        if (result === 'success') {
            // Optional refresh / toast
        }
    }

    // Open Template Selector Modal
    /*
    async handleDisplayTemplates() {
        const result = await AgreementTemplateSelector.open({
            size: 'large',
            recordId: this.recordId
        });

        if (result === 'success') {
            // Optional refresh / toast
        }
    }
    */
}