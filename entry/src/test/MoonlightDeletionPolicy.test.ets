import { expect } from '@ohos/hypium';
import {
  auditedDescribe as describe,
  auditedIt as it
} from '../main/ets/services/FocusedTestRegistrationAudit';
import {
  MoonlightDeletionCommandType,
  MoonlightDeletionContext,
  resolveMoonlightDeletionImpact
} from '../main/ets/services/MoonlightDeletionPolicy';

function context(): MoonlightDeletionContext {
  return {
    ownerScopeId: 'owner-a', hostId: 'host-a', profileId: 'profile-a',
    physicalCloudSelected: true,
    selectedLogicalScopeCount: 3, settingsRecordCount: 1,
    hostRecordCount: 1, profileRecordCount: 2, trustRecordCount: 1,
    identityRecordCount: 1, appCacheCount: 10,
    localRuntimeStateCount: 2, secureIdentityCount: 1
  };
}

export default function moonlightDeletionPolicyTest(): void {
  describe('MoonlightDeletionPolicy', (): void => {
    it('cancel_sync_changes_only_selection_and_never_writes_tombstones', 0,
      (): void => {
        const impact = resolveMoonlightDeletionImpact('cancel_sync', context());
        expect(impact.selectionChanged).assertTrue();
        expect(impact.cloudTombstonesRequired).assertEqual(0);
        expect(impact.localDataPreserved).assertTrue();
      });

    it('delete_cloud_waits_for_terminal_tombstones_but_keeps_local_rows', 0,
      (): void => {
        const impact = resolveMoonlightDeletionImpact(
          'delete_cloud_data', context());
        expect(impact.cloudTombstonesRequired).assertEqual(4);
        expect(impact.waitForCloudTerminal).assertTrue();
        expect(impact.localDataPreserved).assertTrue();
        expect(impact.confirmationLevel).assertEqual('danger');
      });

    it('delete_local_removes_overlay_and_cache_without_cloud_deletes', 0,
      (): void => {
        const impact = resolveMoonlightDeletionImpact(
          'delete_local_data', context());
        expect(impact.localRowsRemoved).assertEqual(6);
        expect(impact.cacheRowsRemoved).assertEqual(10);
        expect(impact.localRuntimeStatesRemoved).assertEqual(2);
        expect(impact.secureIdentitiesRemoved).assertEqual(1);
        expect(impact.cloudTombstonesRequired).assertEqual(0);
        expect(impact.identityPreserved).assertFalse();
        expect(impact.selectionChanged).assertTrue();
      });

    it('treats_fixed_logical_scopes_as_inactive_without_the_physical_table',
      0, (): void => {
        const value: MoonlightDeletionContext = context();
        value.physicalCloudSelected = false;
        value.selectedLogicalScopeCount = 3;
        expect(resolveMoonlightDeletionImpact(
          'cancel_sync', value).selectionChanged).assertFalse();
      });

    it('forget_host_removes_host_profiles_trust_and_cache_but_preserves_identity',
      0, (): void => {
        const impact = resolveMoonlightDeletionImpact('forget_host', context());
        expect(impact.localRowsRemoved).assertEqual(4);
        expect(impact.cloudTombstonesRequired).assertEqual(3);
        expect(impact.identityPreserved).assertTrue();
        expect(impact.cacheRowsRemoved).assertEqual(10);
      });

    it('unpair_is_best_effort_and_never_deletes_the_shared_client_identity', 0,
      (): void => {
        const impact = resolveMoonlightDeletionImpact('unpair_host', context());
        expect(impact.hostRequestBestEffort).assertTrue();
        expect(impact.localRowsRemoved).assertEqual(1);
        expect(impact.cloudTombstonesRequired).assertEqual(0);
        expect(impact.identityPreserved).assertTrue();
      });

    it('never_counts_device_bound_trust_or_identity_as_cloud_rows', 0,
      (): void => {
        const value: MoonlightDeletionContext = context();
        value.settingsRecordCount = 0;
        value.hostRecordCount = 0;
        value.profileRecordCount = 0;
        value.trustRecordCount = 8;
        value.identityRecordCount = 3;
        const impact = resolveMoonlightDeletionImpact(
          'delete_cloud_data', value);
        expect(impact.cloudTombstonesRequired).assertEqual(0);
        expect(impact.waitForCloudTerminal).assertFalse();
        expect(impact.cloudDataPreserved).assertTrue();
        expect(impact.selectionChanged).assertTrue();
      });

    it('delete_profile_is_scoped_and_rejects_a_missing_profile_identity', 0,
      (): void => {
        const valid = resolveMoonlightDeletionImpact('delete_profile', context());
        expect(valid.localRowsRemoved).assertEqual(2);
        const invalidContext: MoonlightDeletionContext = context();
        invalidContext.profileId = '';
        expect(resolveMoonlightDeletionImpact(
          'delete_profile', invalidContext).valid).assertFalse();
        expect(resolveMoonlightDeletionImpact(
          'unknown' as MoonlightDeletionCommandType,
          context()).valid).assertFalse();
      });
  });
}
