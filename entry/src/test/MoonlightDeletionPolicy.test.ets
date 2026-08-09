import { describe, expect, it } from '@ohos/hypium';
import {
  MoonlightDeletionContext,
  resolveMoonlightDeletionImpact
} from '../main/ets/services/MoonlightDeletionPolicy';

function context(): MoonlightDeletionContext {
  return {
    ownerScopeId: 'owner-a', hostId: 'host-a', profileId: 'profile-a',
    physicalCloudSelected: true,
    hostRecordCount: 1, profileRecordCount: 2, trustRecordCount: 1,
    identityRecordCount: 1, appCacheCount: 10
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
        expect(impact.cloudTombstonesRequired).assertEqual(5);
        expect(impact.waitForCloudTerminal).assertTrue();
        expect(impact.localDataPreserved).assertTrue();
        expect(impact.confirmationLevel).assertEqual('danger');
      });

    it('delete_local_removes_overlay_and_cache_without_cloud_deletes', 0,
      (): void => {
        const impact = resolveMoonlightDeletionImpact(
          'delete_local_data', context());
        expect(impact.localRowsRemoved).assertEqual(5);
        expect(impact.cacheRowsRemoved).assertEqual(10);
        expect(impact.cloudTombstonesRequired).assertEqual(0);
      });

    it('forget_host_removes_host_profiles_trust_and_cache_but_preserves_identity',
      0, (): void => {
        const impact = resolveMoonlightDeletionImpact('forget_host', context());
        expect(impact.localRowsRemoved).assertEqual(4);
        expect(impact.cloudTombstonesRequired).assertEqual(4);
        expect(impact.identityPreserved).assertTrue();
        expect(impact.cacheRowsRemoved).assertEqual(10);
      });

    it('unpair_is_best_effort_and_never_deletes_the_shared_client_identity', 0,
      (): void => {
        const impact = resolveMoonlightDeletionImpact('unpair_host', context());
        expect(impact.hostRequestBestEffort).assertTrue();
        expect(impact.localRowsRemoved).assertEqual(1);
        expect(impact.cloudTombstonesRequired).assertEqual(1);
        expect(impact.identityPreserved).assertTrue();
      });

    it('delete_profile_is_scoped_and_rejects_a_missing_profile_identity', 0,
      (): void => {
        const valid = resolveMoonlightDeletionImpact('delete_profile', context());
        expect(valid.localRowsRemoved).assertEqual(2);
        const invalidContext: MoonlightDeletionContext = context();
        invalidContext.profileId = '';
        expect(resolveMoonlightDeletionImpact(
          'delete_profile', invalidContext).valid).assertFalse();
      });
  });
}
