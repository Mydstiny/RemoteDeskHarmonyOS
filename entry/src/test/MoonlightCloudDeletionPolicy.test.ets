import { expect } from '@ohos/hypium';
import {
  auditedDescribe as describe,
  auditedIt as it
} from '../main/ets/services/FocusedTestRegistrationAudit';
import { MoonlightRecord } from '../main/ets/model/MoonlightRecord';
import { AccountSessionLease } from '../main/ets/services/AccountScopePolicy';
import {
  encodeMoonlightCloudDeletionCheckpoint,
  moonlightCloudDeletionTombstone,
  moonlightCloudDeletionCheckpointForLease,
  moonlightCloudDeletionCheckpointUploaded,
  moonlightCloudPromotionBlocked,
  moonlightLocalDeletionTombstone,
  moonlightPreservedLocalAfterCloudDelete,
  moonlightCloudSelectionMutationAllowed,
  newMoonlightCloudDeletionCheckpoint,
  parseMoonlightCloudDeletionCheckpoint,
  recoverMoonlightCloudDeletionCheckpoint
} from '../main/ets/services/MoonlightCloudDeletionPolicy';
import {
  resolveMoonlightRecordConflict
} from '../main/ets/services/MoonlightRecordConflictPolicy';
import {
  MoonlightRecordMeta,
  moonlightPayloadWithMeta,
  moonlightRecordBusinessPayload,
  moonlightRecordMeta,
  moonlightRecordPayloadHashSha256,
  moonlightValidateRecord
} from '../main/ets/services/MoonlightRecordPolicy';

function lease(owner: string = 'owner-a'): AccountSessionLease {
  return {
    ownerScopeId: owner,
    storeIdentity: 'remotedesktop.db',
    generation: 4,
    storeInstanceId: 7
  };
}

function leaseForStore(
  owner: string, storeIdentity: string
): AccountSessionLease {
  return {
    ownerScopeId: owner,
    storeIdentity,
    generation: 9,
    storeInstanceId: 11
  };
}

function hostRecord(
  id: string = 'host-a', syncVersion: number = 1,
  resetEpoch: number = 0, updatedAt: number = 101
): MoonlightRecord {
  const value = new MoonlightRecord();
  value.id = id;
  value.userId = 'owner-a';
  value.recordType = 'host';
  value.ownerId = 'owner-a';
  value.ownerType = 'account';
  const meta: MoonlightRecordMeta = {
    mutationId: 'mutation-' + id + '-' + syncVersion.toString(),
    originId: 'origin-owner-a',
    baseSyncVersion: Math.max(0, syncVersion - 1),
    fieldVersions: { 'displayName': syncVersion }
  };
  value.payload = moonlightPayloadWithMeta({
    schemaVersion: 1,
    serverUuid: 'server-' + id,
    displayName: 'Gaming PC',
    addresses: [{ host: '192.0.2.30', family: 'ipv4', port: 47989 }],
    preferredAddressKey: 'ipv4|192.0.2.30|47989',
    hostType: 'sunshine',
    wakeOnLan: { enabled: false, mac: '', broadcast: '' },
    userOrder: 0
  }, meta, 'host').canonical;
  value.syncVersion = syncVersion;
  value.resetEpoch = resetEpoch;
  value.createdAt = 100;
  value.updatedAt = updatedAt;
  value.payloadHashSha256 = moonlightRecordPayloadHashSha256(value);
  return value;
}

function trustRecord(): MoonlightRecord {
  const value = new MoonlightRecord();
  value.id = 'trust-a';
  value.userId = 'owner-a';
  value.recordType = 'trust';
  value.ownerId = 'host-a';
  value.ownerType = 'host';
  value.payload = moonlightPayloadWithMeta({
    schemaVersion: 1,
    hostId: 'host-a',
    serverUuid: 'server-host-a',
    serverCertificateSha256: 'a'.repeat(64),
    pairingGeneration: 1,
    candidateObservedAt: 101
  }, {
    mutationId: 'mutation-trust-a',
    originId: 'origin-owner-a',
    baseSyncVersion: 0,
    fieldVersions: {}
  }, 'trust').canonical;
  value.syncVersion = 1;
  value.createdAt = 100;
  value.updatedAt = 101;
  value.payloadHashSha256 = moonlightRecordPayloadHashSha256(value);
  return value;
}

export default function moonlightCloudDeletionPolicyTest(): void {
  describe('MoonlightCloudDeletionPolicy', (): void => {
    it('builds_a_payload_free_tombstone_above_both_local_and_cloud', 0,
      (): void => {
        const local: MoonlightRecord = hostRecord('host-a', 4, 2, 240);
        const cloud: MoonlightRecord = hostRecord('host-a', 6, 3, 260);
        const deleted: MoonlightRecord | null =
          moonlightCloudDeletionTombstone(local, cloud, 300);
        expect(deleted === null).assertFalse();
        expect(moonlightValidateRecord(deleted!).valid).assertTrue();
        expect(deleted?.payload).assertEqual('{}');
        expect(deleted?.ciphertext).assertEqual('');
        expect(deleted?.syncVersion).assertEqual(7);
        expect(deleted?.resetEpoch).assertEqual(3);
        expect(deleted?.deletedAt).assertEqual(300);
      });

    it('rejects_scope_mismatch_and_device_private_cloud_rows', 0,
      (): void => {
        const local: MoonlightRecord = hostRecord('host-a');
        const foreign: MoonlightRecord = hostRecord('host-b');
        expect(moonlightCloudDeletionTombstone(
          local, foreign, 300) === null).assertTrue();
        expect(moonlightValidateRecord(trustRecord()).valid).assertTrue();
        expect(moonlightCloudDeletionTombstone(
          null, trustRecord(), 300) === null).assertTrue();
      });

    it('builds_an_offline_local_tombstone_that_beats_a_stale_cloud_row', 0,
      (): void => {
        const local: MoonlightRecord = hostRecord('host-a', 4, 2, 240);
        const deleted: MoonlightRecord | null =
          moonlightLocalDeletionTombstone(local, 300);
        expect(deleted === null).assertFalse();
        expect(moonlightValidateRecord(deleted!).valid).assertTrue();
        expect(deleted?.payload).assertEqual('{}');
        expect(deleted?.syncVersion).assertEqual(5);
        expect(deleted?.resetEpoch).assertEqual(2);
        const newerCloudEnvelope: MoonlightRecord =
          hostRecord('host-a', 99, 2, 999);
        const decision = resolveMoonlightRecordConflict(
          newerCloudEnvelope, deleted!);
        expect(decision.action).assertEqual('accept_candidate');
        expect(decision.reason).assertEqual('tombstone_wins');
      });

    it('builds_a_device_local_trust_tombstone_for_unpair_restore_fencing', 0,
      (): void => {
        const deleted: MoonlightRecord | null =
          moonlightLocalDeletionTombstone(trustRecord(), 300);
        expect(deleted === null).assertFalse();
        expect(deleted?.recordType).assertEqual('trust');
        expect(deleted?.payload).assertEqual('{}');
        expect(deleted?.syncVersion).assertEqual(2);
        expect(deleted?.deletedAt).assertEqual(300);
        expect(moonlightValidateRecord(deleted!).valid).assertTrue();
      });

    it('preserves_local_business_data_above_the_uploaded_delete_epoch', 0,
      (): void => {
        const local: MoonlightRecord = hostRecord('host-a', 4, 2, 240);
        const cloud: MoonlightRecord = hostRecord('host-a', 6, 3, 260);
        const deleted: MoonlightRecord =
          moonlightCloudDeletionTombstone(local, cloud, 300)!;
        const preserved: MoonlightRecord | null =
          moonlightPreservedLocalAfterCloudDelete(
            local, deleted, lease(), 301, 0);
        expect(preserved === null).assertFalse();
        expect(moonlightValidateRecord(preserved!).valid).assertTrue();
        expect(preserved?.resetEpoch).assertEqual(4);
        expect(preserved?.syncVersion).assertEqual(8);
        expect(preserved?.deletedAt).assertEqual(0);
        expect(JSON.stringify(moonlightRecordBusinessPayload(preserved!)))
          .assertEqual(JSON.stringify(moonlightRecordBusinessPayload(local)));
        expect(moonlightRecordMeta(preserved!)?.mutationId ===
          moonlightRecordMeta(local)?.mutationId).assertFalse();
        const decision = resolveMoonlightRecordConflict(
          deleted, preserved!);
        expect(decision.action).assertEqual('accept_candidate');
        expect(decision.reason).assertEqual('explicit_revival');
      });

    it('persists_a_restart_safe_pending_upload_without_session_ids', 0,
      (): void => {
        const checkpoint = newMoonlightCloudDeletionCheckpoint(
          lease(), 'forget_host', 2, 100);
        expect(checkpoint === null).assertFalse();
        const encoded: string = encodeMoonlightCloudDeletionCheckpoint(
          checkpoint!);
        expect(encoded.indexOf('storeInstanceId')).assertEqual(-1);
        expect(encoded.indexOf('generation')).assertEqual(-1);
        const restored = parseMoonlightCloudDeletionCheckpoint(encoded);
        expect(restored === null).assertFalse();
        expect(restored?.phase).assertEqual('pending_upload');
        expect(moonlightCloudDeletionCheckpointForLease(
          restored!, lease())).assertTrue();
      });

    it('marks_zero_row_cloud_cleanup_uploaded_but_still_requires_sync_disable',
      0, (): void => {
        const checkpoint = newMoonlightCloudDeletionCheckpoint(
          lease(), 'delete_cloud_data', 0, 100);
        expect(checkpoint === null).assertFalse();
        expect(checkpoint?.phase).assertEqual('uploaded');
        expect(checkpoint?.disableSyncAfterUpload).assertTrue();
      });

    it('advances_only_a_valid_checkpoint_to_terminal_upload', 0,
      (): void => {
        const checkpoint = newMoonlightCloudDeletionCheckpoint(
          lease(), 'delete_profile', 1, 100);
        const uploaded = moonlightCloudDeletionCheckpointUploaded(
          checkpoint!, 101);
        expect(uploaded?.phase).assertEqual('uploaded');
        expect(uploaded?.disableSyncAfterUpload).assertFalse();
        expect(moonlightCloudDeletionCheckpointUploaded(
          checkpoint!, 99) === null).assertTrue();
      });

    it('rejects_foreign_owner_and_device_only_commands_but_accepts_future_fields', 0,
      (): void => {
        const checkpoint = newMoonlightCloudDeletionCheckpoint(
          lease(), 'unpair_host', 1, 100);
        expect(checkpoint === null).assertTrue();
        const valid = newMoonlightCloudDeletionCheckpoint(
          lease(), 'forget_host', 1, 100)!;
        expect(moonlightCloudDeletionCheckpointForLease(
          valid, lease('owner-b'))).assertFalse();
        expect(moonlightCloudDeletionCheckpointForLease(
          valid, leaseForStore('owner-a', 'owner-a-fallback.db')))
          .assertFalse();
        const parsed: Record<string, Object> = JSON.parse(
          encodeMoonlightCloudDeletionCheckpoint(valid)) as
            Record<string, Object>;
        parsed['future'] = true;
        expect(parseMoonlightCloudDeletionCheckpoint(
          JSON.stringify(parsed)) === null).assertFalse();
      });

    it('keeps_the_owner_and_store_fence_after_restart_and_terminal_upload',
      0, (): void => {
        const original = newMoonlightCloudDeletionCheckpoint(
          lease(), 'delete_cloud_data', 3, 100)!;
        const afterRestart = parseMoonlightCloudDeletionCheckpoint(
          encodeMoonlightCloudDeletionCheckpoint(original))!;
        const uploaded = moonlightCloudDeletionCheckpointUploaded(
          afterRestart, 200)!;
        const afterSecondRestart = parseMoonlightCloudDeletionCheckpoint(
          encodeMoonlightCloudDeletionCheckpoint(uploaded))!;
        expect(afterSecondRestart.phase).assertEqual('uploaded');
        expect(afterSecondRestart.disableSyncAfterUpload).assertTrue();
        expect(moonlightCloudDeletionCheckpointForLease(
          afterSecondRestart, lease())).assertTrue();
        expect(moonlightCloudDeletionCheckpointForLease(
          afterSecondRestart, lease('owner-b'))).assertFalse();
        expect(moonlightCloudDeletionCheckpointForLease(
          afterSecondRestart,
          leaseForStore('owner-a', 'other-store.db'))).assertFalse();
      });

    it('freezes_cloud_selection_until_the_deletion_checkpoint_is_gone',
      0, (): void => {
        const pending = newMoonlightCloudDeletionCheckpoint(
          lease(), 'forget_host', 1, 100);
        const uploaded = moonlightCloudDeletionCheckpointUploaded(
          pending!, 101);
        expect(moonlightCloudSelectionMutationAllowed(
          true, null)).assertTrue();
        expect(moonlightCloudSelectionMutationAllowed(
          true, pending)).assertFalse();
        expect(moonlightCloudSelectionMutationAllowed(
          true, uploaded)).assertFalse();
        expect(moonlightCloudSelectionMutationAllowed(
          false, null)).assertFalse();
      });

    it('blocks_promotion_for_unreadable_current_and_foreign_checkpoints',
      0, (): void => {
        const pending = newMoonlightCloudDeletionCheckpoint(
          lease(), 'forget_host', 1, 100)!;
        expect(moonlightCloudPromotionBlocked(
          true, null, lease())).assertFalse();
        expect(moonlightCloudPromotionBlocked(
          false, null, lease())).assertTrue();
        expect(moonlightCloudPromotionBlocked(
          true, pending, lease())).assertTrue();
        // A stale owner/store checkpoint is an account-boundary fault, never
        // permission to republish local rows under the new account.
        expect(moonlightCloudPromotionBlocked(
          true, pending, lease('owner-b'))).assertTrue();
        expect(moonlightCloudPromotionBlocked(
          true, pending,
          leaseForStore('owner-a', 'other-store.db'))).assertTrue();
      });

    it('repairs_a_malformed_checkpoint_into_a_resumable_promotion_fence', 0,
      (): void => {
        const targeted = recoverMoonlightCloudDeletionCheckpoint(
          '{"command":"forget_host","deletedPhysicalRowCount":3,' +
          '"createdAt":50}', lease(), 100)!;
        expect(targeted.command).assertEqual('forget_host');
        expect(targeted.phase).assertEqual('pending_upload');
        expect(targeted.deletedPhysicalRowCount).assertEqual(3);
        expect(targeted.disableSyncAfterUpload).assertFalse();
        expect(moonlightCloudPromotionBlocked(
          true, targeted, lease())).assertTrue();

        const conservative = recoverMoonlightCloudDeletionCheckpoint(
          '{truncated', lease(), 100)!;
        expect(conservative.command).assertEqual('delete_cloud_data');
        expect(conservative.disableSyncAfterUpload).assertTrue();
        expect(conservative.deletedPhysicalRowCount).assertEqual(1);
        expect(moonlightCloudPromotionBlocked(
          true, conservative, lease())).assertTrue();
      });
  });
}
