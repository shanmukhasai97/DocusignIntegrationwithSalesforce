global with sharing class DocuSignPostInstallHandler implements InstallHandler {
    global void onInstall(InstallContext ctx) {
        Boolean isUpgrade = ctx.previousVersion() != null;
        System.debug(LoggingLevel.INFO, '[DocuSignPostInstallHandler] ' + (isUpgrade ? 'Upgrade' : 'Fresh install') + ' | InstallingUserId=' + ctx.installerId() + ' | OrgId=' + ctx.organizationId());
        /* Step 1: Start polling scheduler  */
        try {
            DocuSign_Config__mdt cfg = DocuSignConfigService.getConfig();
            if (cfg.Active__c == true) {
                DocuSignPollingScheduler.startWatchdog();
            }
            System.debug(LoggingLevel.INFO, '[DocuSignPostInstallHandler] Watchdog started.');
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR,'[DocuSignPostInstallHandler] Failed to start watchdog: ' + e.getMessage());
        }
        /*  Step 2: Assign permission sets to installing user. Skip on upgrade — permissions already assigned */
        if (!isUpgrade && ctx.installerId() != null) {
            try {
                assignPermissionSets(ctx.installerId());
            } catch (Exception e) {
                System.debug(LoggingLevel.ERROR, '[DocuSignPostInstallHandler] ' + 'Failed to assign permission sets: ' + e.getMessage());
            }
        }
    }
    /* PRIVATE HELPERS */
    private void assignPermissionSets(Id userId) {
        // Find the permission set IDs by name
        Map<String, Id> psMap = new Map<String, Id>();
        for (PermissionSet ps : [ SELECT Id, Name FROM PermissionSet WHERE Name IN ('DocuSign_Admin', 'DocuSign_User')]) {
            psMap.put(ps.Name, ps.Id);
        }
        if (psMap.isEmpty()) {
            System.debug(LoggingLevel.WARN, '[DocuSignPostInstallHandler] ' + 'Permission sets not found. Skipping assignment.');
            return;
        }
        /*  Find which permission sets are already assigned */
        Set<Id> alreadyAssigned = new Set<Id>();
        for (PermissionSetAssignment psa : [ SELECT PermissionSetId FROM PermissionSetAssignment WHERE AssigneeId = :userId AND PermissionSetId IN :psMap.values() ]) {
            alreadyAssigned.add(psa.PermissionSetId);
        }
        /*  Insert only missing assignments */
        List<PermissionSetAssignment> toInsert = new List<PermissionSetAssignment>();
        for (String psName : psMap.keySet()) {
            Id psId = psMap.get(psName);
            if (!alreadyAssigned.contains(psId)) {
                toInsert.add(new PermissionSetAssignment(AssigneeId = userId, PermissionSetId = psId));
            }
        }
        if (!toInsert.isEmpty()) {
            insert toInsert;
            System.debug(LoggingLevel.INFO, '[DocuSignPostInstallHandler] Assigned ' + toInsert.size() + ' permission set(s) to ' + userId);
        } else {
            System.debug(LoggingLevel.INFO, '[DocuSignPostInstallHandler] ' + 'All permission sets already assigned.');
        }
    }
}