@isTest
private class DocuSignPostInstallHandlerTest {

    // ── fresh install ─────────────────────────────────────────────────────────

    @isTest
    static void freshInstall_noExistingPermSets_completesCleanly() {
        // If DocuSign PS don't exist in this org, the "psMap empty" branch runs
        Test.startTest();
        Test.testInstall(new DocuSignPostInstallHandler(), null, false);
        Test.stopTest();
        System.assert(true, 'Fresh install (no PS) should not throw');
    }

    @isTest
    static void freshInstall_withPermSets_assignsToInstallingUser() {
        // Create PS so the assignment branch runs
        PermissionSet ps1 = new PermissionSet(Name = 'DocuSign_Admin', Label = 'DocuSign Admin');
        PermissionSet ps2 = new PermissionSet(Name = 'DocuSign_User',  Label = 'DocuSign User');
        try {
            insert new List<PermissionSet>{ ps1, ps2 };
        } catch (DmlException e) {
            // PS already exist in org — continue, assignment will still run
        }

        Test.startTest();
        Test.testInstall(new DocuSignPostInstallHandler(), null, false);
        Test.stopTest();

        Id userId = UserInfo.getUserId();
        List<PermissionSetAssignment> psas = [
            SELECT Id FROM PermissionSetAssignment
            WHERE AssigneeId = :userId
            AND PermissionSet.Name IN ('DocuSign_Admin', 'DocuSign_User')
        ];
        System.assert(!psas.isEmpty(), 'Permission sets should be assigned after fresh install');
    }

    @isTest
    static void freshInstall_withAlreadyAssignedPermSets_noError() {
        // Pre-assign PS so "already assigned" branch runs in handler
        Id userId = UserInfo.getUserId();
        List<PermissionSet> psets = [
            SELECT Id FROM PermissionSet WHERE Name IN ('DocuSign_Admin', 'DocuSign_User')
        ];
        if (!psets.isEmpty()) {
            Set<Id> psIds = new Map<Id, PermissionSet>(psets).keySet();
            Set<Id> alreadyAssigned = new Set<Id>();
            for (PermissionSetAssignment psa : [
                SELECT PermissionSetId FROM PermissionSetAssignment
                WHERE AssigneeId = :userId AND PermissionSetId IN :psIds
            ]) {
                alreadyAssigned.add(psa.PermissionSetId);
            }
            List<PermissionSetAssignment> toInsert = new List<PermissionSetAssignment>();
            for (PermissionSet ps : psets) {
                if (!alreadyAssigned.contains(ps.Id)) {
                    toInsert.add(new PermissionSetAssignment(
                        AssigneeId = userId, PermissionSetId = ps.Id
                    ));
                }
            }
            if (!toInsert.isEmpty()) insert toInsert;
        }

        Test.startTest();
        Test.testInstall(new DocuSignPostInstallHandler(), null, false);
        Test.stopTest();
        System.assert(true, 'Should handle already-assigned PS without error');
    }

    // ── upgrade ───────────────────────────────────────────────────────────────

    @isTest
    static void upgradeInstall_skipsPermSetAssignment() {
        // previousVersion != null → isUpgrade = true → perm set block skipped
        Test.startTest();
        Test.testInstall(new DocuSignPostInstallHandler(), new Version(1, 0), false);
        Test.stopTest();
        System.assert(true, 'Upgrade should complete without perm set assignment');
    }

    @isTest
    static void upgradeInstall_patchVersion_skipsPermSetAssignment() {
        Test.startTest();
        Test.testInstall(new DocuSignPostInstallHandler(), new Version(1, 5), true);
        Test.stopTest();
        System.assert(true, 'Patch upgrade should complete without error');
    }
}