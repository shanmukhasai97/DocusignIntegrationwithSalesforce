import { api, track, wire } from 'lwc';
import LightningModal from 'lightning/modal';
import { subscribe, unsubscribe, onError } from 'lightning/empApi';
import getAgreementFiles from '@salesforce/apex/DocuSignAgreementService.getAgreementFiles';
import sendForSignature from '@salesforce/apex/DocuSignAgreementService.sendForSignature';
import createSenderView from '@salesforce/apex/DocuSignAgreementService.createSenderView';
import searchRecipients from '@salesforce/apex/DocuSignAgreementService.searchRecipients';
import isPollingActive from '@salesforce/apex/DocuSignAgreementService.isPollingActive';
import { getRecord, getFieldValue, getRecordNotifyChange } from 'lightning/uiRecordApi';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';

const AGREEMENT_FIELDS = [
    'Agreement__c.Name',
    'Agreement__c.Status__c',
    'Agreement__c.Status_Group__c'
];
const DOCUSIGN_EVENT_CHANNEL = '/event/DocuSign_Event__e';

const columns = [
    {
        label: 'Select',
        type: 'button-icon',
        initialWidth: 70,
        typeAttributes: {
            iconName: { fieldName: 'selectIcon' },
            variant: 'border-filled',
            name: 'select_row',
            class: { fieldName: 'selectClass' }
        }
    },
    {
        label: 'File Name',
        fieldName: 'title',
        type: 'text',
        sortable: true
    },
    {
        label: 'Size',
        fieldName: 'formattedSize',
        initialWidth: 100
    },
    {
        label: 'Last Modified Date',
        fieldName: 'formattedDate',
        initialWidth: 250
    }
];

export default class AgreementSendForEsignature extends LightningModal {
    // ── API ──
    @api recordId;

    // ── TRACKED STATE ──
    @track files = [];
    @track recipients = [];
    @track searchResults = [];
    @track selectedUsersForPreview = [];
    @track showModal = false;
    @track showEditModal = false;
    @track showSuccessScreen = false;
    @track isPreparing = false;
    @track isSearching = false;

    // ── UI STATE ──
    currentStep = '1';
    columns = columns;
    modalMode = 'sf';
    agreementName;
    docusignStatus;
    searchKey = '';
    emailSubject = 'Agreement Signature Request';
    emailMessage = '';
    reminderType = 'every1';
    reminderDays = 3;
    expireDays = 30;
    expireDate;
    signingOrderEnabled = true;
    draggedIndex = null;
    isSending = false;
    sendStartTime = null;
    subscription = null;

    // ── MODAL FIELDS ──
    modalName = '';
    modalEmail = '';
    modalRole = 'signer';
    editRecipientKey = null;

    // ── OPTIONS ──
    roleOptions = [
        { label: 'Needs to Sign',    value: 'signer' },
        { label: 'Receives a Copy',  value: 'copy'   },
        { label: 'Needs to View',    value: 'viewer' }
    ];

    // ─────────────────────────────────────────────
    // WIRES
    // ─────────────────────────────────────────────
    @wire(getAgreementFiles, { agreementId: '$recordId' })
    wiredFiles({ data, error }) {
        if (data) {
            this.files = data.map(file => ({
                ...file,
                isSelected: false,
                selectIcon: 'utility:add',
                selectClass: 'custom-add-button',
                formattedDate: this.formatDate(file.LastModifiedDate),
                formattedSize: this.formatFileSize(file.ContentSize)
            }));
        } else if (error) {
            this.toast('Error', error?.body?.message || 'Failed to load files', 'error');
        }
    }

    @wire(getRecord, { recordId: '$recordId', fields: AGREEMENT_FIELDS })
    wiredAgreement({ data, error }) {
        if (data) {
            this.agreementName  = getFieldValue(data, 'Agreement__c.Name');
            this.docusignStatus = getFieldValue(data, 'Agreement__c.Status__c');
        } else if (error) {
            console.error('[eSignature] wiredAgreement error:', error);
        }
    }

   connectedCallback() {
    this.subscribeToPlatformEvents();
    
    Promise.resolve().then(() => {
        try {
            const modalContainer = this.template?.host?.closest('.slds-modal__container');
            if (modalContainer) {
                modalContainer.style.height = '100vh';
                modalContainer.style.maxHeight = '100vh';
            }
        } catch (e) {
            console.log('[eSignature] modal height:', e);
        }
    });
}
 
disconnectedCallback() {
    this.unsubscribeFromPlatformEvents();
}

    // ─────────────────────────────────────────────
    // PLATFORM EVENTS
    // ─────────────────────────────────────────────
    subscribeToPlatformEvents() {
        subscribe(DOCUSIGN_EVENT_CHANNEL, -1, this.handlePlatformEvent.bind(this))
            .then(response => { this.subscription = response; })
            .catch(error => { console.error('[eSignature] Subscription Error', error); });

        onError(error => { console.error('[eSignature] EMP API Error', error); });
    }

    unsubscribeFromPlatformEvents() {
        if (!this.subscription) return;
        unsubscribe(this.subscription)
            .then(() => { this.subscription = null; })
            .catch(error => { console.error('[eSignature] Unsubscribe Error', error); });
    }

    handlePlatformEvent(event) {
        const payload = event?.data?.payload;
        if (!payload) return;

        if (payload.Agreement_Id__c !== this.recordId) return;

        const newStatus  = payload.New_Status__c;
        const isTerminal = payload.Is_Terminal__c;

        getRecordNotifyChange([{ recordId: this.recordId }]);

        if (isTerminal && newStatus === 'Completed') {
            this.toast('Signed!', 'Document fully signed. PDF will appear shortly.', 'success');
            setTimeout(() => getRecordNotifyChange([{ recordId: this.recordId }]), 5000);

        } else if (isTerminal && newStatus === 'Declined') {
            this.toast('Declined', 'A recipient declined to sign.', 'warning');

        } else if (isTerminal && newStatus === 'Voided') {
            this.toast('Voided', 'The envelope has been voided.', 'warning');

        } else if (!isTerminal && newStatus === 'Completed') {
            this.toast('Partially Signed', 'A recipient has signed. Waiting for remaining recipients.', 'info');
            setTimeout(() => getRecordNotifyChange([{ recordId: this.recordId }]), 5000);
        }
    }

    // ─────────────────────────────────────────────
    // GETTERS
    // ─────────────────────────────────────────────
    get isStep1() { return this.currentStep === '1'; }
    get isStep2() { return this.currentStep === '2'; }
    get isStep3() { return this.currentStep === '3'; }
    get isFirstStep() { return this.currentStep === '1'; }
    get isSuccessScreen() { return this.showSuccessScreen; }
    get hasFiles() { return this.files?.length > 0; }
    get selectedFiles() { return this.files.filter(f => f.isSelected); }
    get hasRecipients() { return this.recipients?.length > 0; }

    get validRecipientsCount() {
        return this.recipients.filter(r => r.name && r.email).length;
    }

    get showProgressBar() {
        return !this.isSuccessScreen && !this.isPreparing && !this.isSending;
    }

    get nextLabel() {
        return this.currentStep === '2' ? 'Prepare & Send' : 'Next';
    }

    get isNextDisabled() {
        if (this.currentStep === '1') return this.selectedFiles.length === 0;
        if (this.currentStep === '2') return this.validRecipientsCount === 0 || this.isSending;
        return false;
    }

    get isSalesforce() { return this.modalMode === 'sf'; }
    get isManual()     { return this.modalMode === 'manual'; }
    get hasSearchResults() { return this.searchResults?.length > 0; }
    get isSelectDisabled() { return this.selectedUsersForPreview.length === 0; }
    get isAddDisabled()    { return !this.modalName || !this.modalEmail; }
    get showCustomReminder() { return this.reminderType === 'custom'; }
    get signingOrderVariant() { return this.signingOrderEnabled ? 'brand' : 'neutral'; }
    get sfTabClass()     { return this.modalMode === 'sf'     ? 'active-tab' : ''; }
    get manualTabClass() { return this.modalMode === 'manual' ? 'active-tab' : ''; }

    get contentAreaClass() {
    return this.isStep1
        ? 'content-area step1-content'
        : 'content-area step2-content';
}
get mainCardClass() {
        return this.isStep1
            ? 'slds-card main-card slds-grid slds-grid_vertical step1-fixed'
            : 'slds-card main-card slds-grid slds-grid_vertical step2-organic';
    }

    get reminderOptions() {
        return [
            { label: 'Do Not Remind', value: 'none'   },
            { label: 'Every day',     value: 'every1' },
            { label: 'Every 2 days',  value: 'every2' },
            { label: 'Every 3 days',  value: 'every3' },
            { label: 'Every 4 days',  value: 'every4' },
            { label: 'Every 5 days',  value: 'every5' },
            { label: 'Every 6 days',  value: 'every6' },
            { label: 'Every 7 days',  value: 'every7' },
            { label: 'Custom',        value: 'custom' }
        ];
    }

    get validRecipientsForDisplay() {
        return this.recipients.map(r => ({
            ...r,
            roleLabel: this.getRoleLabel(r.role)
        }));
    }

    // ─────────────────────────────────────────────
    // FILES
    // ─────────────────────────────────────────────
    handleRowAction(event) {
        const { action, row } = event.detail;
        if (action.name === 'select_row') {
            this.toggleSelect(row.contentDocumentId);
        }
    }

    toggleSelect(fileId) {
        this.files = this.files.map(file => {
            if (file.contentDocumentId !== fileId) return file;
            const isSelected = !file.isSelected;
            return {
                ...file,
                isSelected,
                selectIcon:  isSelected ? 'utility:check' : 'utility:add',
                selectClass: isSelected ? 'custom-check-button' : 'custom-add-button'
            };
        });
    }

    // ─────────────────────────────────────────────
    // SEARCH
    // ─────────────────────────────────────────────
    handleSearch(event) {
        this.searchKey = event.target.value;

        if (!this.searchKey || this.searchKey.trim().length < 2) {
            this.searchResults = [];
            return;
        }

        this.isSearching = true;

        searchRecipients({ searchKey: this.searchKey })
            .then(results => {
                this.searchResults = results.map(r => ({
                    ...r,
                    key: r.recordId,
                    isSelected: this.isUserSelected(r.recordId)
                }));
            })
            .catch(error => {
                this.toast('Error', error?.body?.message || 'Search failed', 'error');
                this.searchResults = [];
            })
            .finally(() => { this.isSearching = false; });
    }

    isUserSelected(recordId) {
        return this.selectedUsersForPreview.some(u => u.recordId === recordId);
    }

    handleUserCheckbox(event) {
        const recordId = event.target.dataset.id;
        const isChecked = event.target.checked;

        if (isChecked) {
            const user = this.searchResults.find(r => r.recordId === recordId);
            if (user && !this.isUserSelected(recordId)) {
                this.selectedUsersForPreview = [...this.selectedUsersForPreview, { ...user }];
            }
        } else {
            this.selectedUsersForPreview = this.selectedUsersForPreview.filter(
                u => u.recordId !== recordId
            );
        }

        // FIX: update isSelected for ALL results, not only the toggled one
        this.searchResults = this.searchResults.map(r => ({
            ...r,
            isSelected: r.recordId === recordId ? isChecked : r.isSelected
        }));
    }

    // ─────────────────────────────────────────────
    // RECIPIENT MODALS — open/close
    // ─────────────────────────────────────────────
    openModal() {
        this.resetModalFields();
        this.modalMode = 'sf';
        this.showModal = true;
    }

    closeModal() {
        this.showModal = false;
        this.resetModalFields();
    }

    openEditModal(event) {
        // Support both button-icon value and data-key
        const key = event.target.value || event.currentTarget.dataset.key;
        const recipient = this.recipients.find(r => String(r.key) === String(key));
        if (!recipient) return;

        this.editRecipientKey = recipient.key;
        this.modalName  = recipient.name;
        this.modalEmail = recipient.email;
        this.modalRole  = recipient.role || 'signer';
        this.showEditModal = true;
    }

    closeEditModal() {
        this.showEditModal = false;
        this.editRecipientKey = null;
        this.modalName  = '';
        this.modalEmail = '';
        this.modalRole  = 'signer';
    }

    saveEditedRecipient() {
        if (!this.modalName || !this.modalEmail) {
            this.toast('Error', 'Name and Email are required', 'error');
            return;
        }

        this.recipients = this.recipients.map(r => {
            if (String(r.key) === String(this.editRecipientKey)) {
                return { ...r, name: this.modalName, email: this.modalEmail, role: this.modalRole };
            }
            return r;
        });

        this.toast('Success', 'Recipient updated', 'success');
        this.closeEditModal();
    }

    resetModalFields() {
        this.selectedUsersForPreview = [];
        this.searchKey    = '';
        this.searchResults = [];
        this.modalName    = '';
        this.modalEmail   = '';
        this.modalRole    = 'signer';
    }

    // ─────────────────────────────────────────────
    // MODAL FIELD HANDLERS
    // ─────────────────────────────────────────────
    handleLeftNavClick(event) { this.modalMode = event.currentTarget.dataset.mode; }
    handleModalName(event)    { this.modalName  = event.target.value; }
    handleModalEmail(event)   { this.modalEmail = event.target.value; }
    handleModalRoleChange(event) { this.modalRole = event.detail.value; }

    // ─────────────────────────────────────────────
    // RECIPIENTS — add / remove
    // ─────────────────────────────────────────────
    addManualRecipient() {
        if (!this.modalName || !this.modalEmail) {
            this.toast('Error', 'Name and Email are required', 'error');
            return;
        }

        const recipient = {
            key:   `${Date.now()}_${Math.random()}`,
            name:  this.modalName,
            email: this.modalEmail,
            role:  this.modalRole || 'signer'
        };

        this.recipients = [...this.recipients, recipient];
        this.normalizeRoutingOrders();
        this.closeModal();
        this.toast('Success', 'Recipient added', 'success');
    }

    addRecipientsFromSalesforce() {
        if (this.selectedUsersForPreview.length === 0) {
            this.toast('Error', 'Please select at least one user', 'error');
            return;
        }

        const newRecipients = [];

        for (const user of this.selectedUsersForPreview) {
            const alreadyExists = this.recipients.some(r => r.email === user.email);
            if (alreadyExists) {
                this.toast('Warning', `Recipient already added: ${user.email}`, 'warning');
                continue;
            }
            newRecipients.push({
                key:      `${Date.now()}_${Math.random()}`,
                name:     user.name,
                email:    user.email,
                recordId: user.recordId,
                type:     user.type,
                role:     this.modalRole || 'signer'
            });
        }

        if (newRecipients.length === 0) return;

        this.recipients = [...this.recipients, ...newRecipients];
        this.normalizeRoutingOrders();
        this.closeModal();
        this.toast('Success', `${newRecipients.length} recipient(s) added`, 'success');
    }

    removeRecipient(event) {
        const key = event.target.value || event.currentTarget.dataset.key;
        this.recipients = this.recipients.filter(r => String(r.key) !== String(key));
        this.normalizeRoutingOrders();
    }

    // ─────────────────────────────────────────────
    // DRAG & DROP
    // ─────────────────────────────────────────────
    handleDragStart(event) {
        if (!this.signingOrderEnabled) return;
        const key = event.currentTarget.dataset.key;
        this.draggedIndex = this.recipients.findIndex(r => String(r.key) === String(key));
        event.currentTarget.classList.add('dragging');
    }

    handleDragOver(event) {
        event.preventDefault();
    }

    handleDrop(event) {
        event.preventDefault();
        if (!this.signingOrderEnabled) return;

        const key = event.currentTarget.dataset.key;
        const dropIndex = this.recipients.findIndex(r => String(r.key) === String(key));

        if (this.draggedIndex === null || dropIndex === -1 || this.draggedIndex === dropIndex) return;

        const updated = [...this.recipients];
        const [draggedItem] = updated.splice(this.draggedIndex, 1);
        updated.splice(dropIndex, 0, draggedItem);

        this.recipients = updated;
        this.normalizeRoutingOrders();
    }

    handleDragEnd(event) {
        event.currentTarget.classList.remove('dragging');
        this.draggedIndex = null;
    }

    normalizeRoutingOrders() {
        this.recipients = this.recipients.map((r, i) => ({
            ...r,
            routingOrder: this.signingOrderEnabled ? i + 1 : 1
        }));
    }

    toggleSigningOrder() {
        this.signingOrderEnabled = !this.signingOrderEnabled;
        this.normalizeRoutingOrders();
    }

    previewRouting() {
        const order = this.recipients
            .map(r => `${r.routingOrder} → ${r.name}`)
            .join('\n');
        this.toast('Routing Order', order || 'No recipients added', 'info');
    }

    // ─────────────────────────────────────────────
    // EMAIL / REMINDERS / EXPIRY
    // ─────────────────────────────────────────────
    handleSubject(event) { this.emailSubject = event.target.value; }
    handleMessage(event) { this.emailMessage = event.target.value; }

    handleReminderTypeChange(event) {
        this.reminderType = event.detail.value;
        if (this.reminderType === 'none') {
            this.reminderDays = 0;
            return;
        }
        if (this.reminderType.startsWith('every')) {
            this.reminderDays = Number(this.reminderType.replace('every', ''));
        }
    }

    handleReminderDaysChange(event) {
        this.reminderDays = Number(event.target.value);
    }

    handleExpireDateChange(event) {
        this.expireDate = event.target.value;
        if (!this.expireDate) return;

        const today        = new Date();
        const selectedDate = new Date(this.expireDate);
        const diffDays     = Math.ceil((selectedDate - today) / (1000 * 60 * 60 * 24));
        this.expireDays    = diffDays > 0 ? diffDays : 0;
    }

    handleExpireDaysChange(event) {
        this.expireDays = Number(event.target.value);
        if (!this.expireDays || this.expireDays <= 0) {
            this.expireDate = null;
            return;
        }
        const futureDate = new Date();
        futureDate.setDate(futureDate.getDate() + this.expireDays);
        this.expireDate = futureDate.toISOString().split('T')[0];
    }

    // ─────────────────────────────────────────────
    // NAVIGATION
    // ─────────────────────────────────────────────
    handleBack() {
        this.currentStep = String(Number(this.currentStep) - 1);
    }

    handleNext() {
        if (this.currentStep === '1') {
            this.validatePollingAndContinue();
            return;
        }
        if (this.currentStep === '2') {
            this.isPreparing = true;
            this.send();
            return;
        }
        // Generic advance (future steps)
        this.currentStep = String(Number(this.currentStep) + 1);
    }

    validatePollingAndContinue() {
        isPollingActive()
            .then(active => {
                if (!active) {
                    this.toast(
                        'Polling Not Active',
                        'DocuSign background polling is not running. Please contact your administrator.',
                        'error'
                    );
                    return;
                }
                this.currentStep = '2';
            })
            .catch(() => {
                this.toast('Error', 'Could not verify polling status.', 'error');
            });
    }

    handleCancel() {
        this.close('cancelled');
    }

    // ─────────────────────────────────────────────
    // SEND
    // ─────────────────────────────────────────────
    send() {
        if (this.isSending) return;

        this.isSending    = true;
        this.sendStartTime = Date.now();

        sendForSignature({
            agreementId:     this.recordId,
            filesJson:       JSON.stringify(this.selectedFiles),
            recipientsJson:  JSON.stringify(this.recipients),
            reminderDays:    this.reminderDays,
            reminderEnabled: this.reminderDays > 0,
            expireDays:      this.expireDays,
            expireDate:      this.expireDate,
            emailSubject:    this.emailSubject,
            emailMessage:    this.emailMessage
        })
        .then(() => {
            this.toast('Envelope Queued', 'Opening DocuSign...', 'success');
            this.pollForSenderView(0);
        })
        .catch(error => {
            this.isSending   = false;
            this.isPreparing = false;
            this.toast('Error', error?.body?.message || 'DocuSign error', 'error');
        });
    }

    pollForSenderView(elapsed) {
        const TIMEOUT_MS  = 120000;
        const INTERVAL_MS = 3000;

        if (elapsed >= TIMEOUT_MS) {
            this.isSending   = false;
            this.isPreparing = false;
            this.toast('Error', 'Timed out waiting for envelope.', 'error');
            return;
        }

        window.setTimeout(() => {
            createSenderView({ agreementId: this.recordId, sentAtMillis: this.sendStartTime })
                .then(url => {
                    this.isSending   = false;
                    this.isPreparing = false;
                    window.location.href = url;
                })
                .catch(error => {
                    const message = error?.body?.message || '';
                    if (message.includes('not created yet')) {
                        this.pollForSenderView(elapsed + INTERVAL_MS);
                        return;
                    }
                    this.isSending   = false;
                    this.isPreparing = false;
                    this.toast('DocuSign Error', message || 'Failed to open DocuSign.', 'error');
                });
        }, INTERVAL_MS);
    }

    // ─────────────────────────────────────────────
    // UTILITIES
    // ─────────────────────────────────────────────
    getRoleLabel(role) {
        switch (role) {
            case 'signer': return 'Needs to Sign';
            case 'copy':   return 'Receives a Copy';
            case 'viewer': return 'Needs to View';
            default:       return 'Needs to Sign';
        }
    }

    formatDate(dateValue) {
        if (!dateValue) return '';
        try {
            return new Intl.DateTimeFormat('en-US', {
                year:   'numeric',
                month:  'short',
                day:    'numeric',
                hour:   '2-digit',
                minute: '2-digit'
            }).format(new Date(dateValue));
        } catch (e) {
            return dateValue;
        }
    }

    formatFileSize(bytes) {
        if (!bytes || bytes === 0) return '0 KB';
        const k     = 1024;
        const sizes = ['Bytes', 'KB', 'MB', 'GB'];
        const index = Math.floor(Math.log(bytes) / Math.log(k));
        return (Math.round((bytes / Math.pow(k, index)) * 100) / 100) + ' ' + sizes[index];
    }

    toast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
}