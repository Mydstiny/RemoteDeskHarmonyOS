import { describe, it, expect } from '@ohos/hypium';
import {
  CloudAccountBinding,
  cloudAccountBindingIsValid,
  cloudDistributedRegistrationAllowed,
  cloudRegistrationRetryAllowed,
  cloudRegistrationRetrySucceeded,
  cloudRuntimeRegistrationAdmissionAllowed,
  moonlightCloudSchemaProvisioned,
  optionalCloudTableRegistrationAllowed,
  cloudTransferAllowed,
  legacyRelayMigrationCloudAdmissionAllowed,
  localMutationCommitAllowed,
  legacyCloudRestTransferAllowed,
  portableBackupExportAllowed,
  portableBackupRestoreAllowed,
  remoteCryptoLifecycleMutationAllowed,
  unboundCloudAccountBinding
} from '../main/ets/services/CloudLifecycleSafetyPolicy';

export default function cloudLifecycleSafetyPolicyTest(): void {
  describe('CloudLifecycleSafetyPolicy', (): void => {
    it('blocks_unbound_or_incomplete_cloud_bindings', 0, (): void => {
      const unbound: CloudAccountBinding = unboundCloudAccountBinding();
      expect(cloudAccountBindingIsValid(unbound)).assertFalse();
      expect(cloudDistributedRegistrationAllowed(unbound, true)).assertFalse();
      expect(cloudTransferAllowed(unbound, true)).assertFalse();

      const incomplete: CloudAccountBinding = {
        state: 'bound',
        ownerScopeId: 'owner-a',
        storeIdentity: '',
        generation: 1,
        platformIdentityFingerprint: ''
      };
      expect(cloudAccountBindingIsValid(incomplete)).assertFalse();
      expect(cloudDistributedRegistrationAllowed(incomplete, true)).assertFalse();
    });

    it('requires_both_rollout_and_a_complete_binding', 0, (): void => {
      const bound: CloudAccountBinding = {
        state: 'bound',
        ownerScopeId: 'owner-a',
        storeIdentity: 'account-owner-a.db',
        generation: 1,
        platformIdentityFingerprint:
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' +
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
      };
      expect(cloudAccountBindingIsValid(bound)).assertTrue();
      expect(cloudDistributedRegistrationAllowed(bound, false)).assertFalse();
      expect(cloudTransferAllowed(bound, false)).assertFalse();
      expect(cloudDistributedRegistrationAllowed(bound, true)).assertTrue();
      expect(cloudTransferAllowed(bound, true)).assertTrue();
      expect(cloudDistributedRegistrationAllowed(bound)).assertTrue();
      expect(cloudTransferAllowed(bound)).assertTrue();
    });

    it('enables_redacted_backup_while_destructive_legacy_paths_stay_disabled', 0, (): void => {
      expect(remoteCryptoLifecycleMutationAllowed()).assertFalse();
      expect(portableBackupExportAllowed()).assertTrue();
      expect(portableBackupRestoreAllowed()).assertTrue();
      expect(legacyCloudRestTransferAllowed()).assertFalse();
    });

    it('retries_only_a_bound_unavailable_store_after_the_cooldown', 0, (): void => {
      const bound: CloudAccountBinding = {
        state: 'bound',
        ownerScopeId: 'owner-a',
        storeIdentity: 'remotedesktop.db',
        generation: 2,
        platformIdentityFingerprint:
          'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' +
          'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
      };
      expect(cloudRegistrationRetryAllowed(
        true, true, true, bound, false, false,
        1000, 0, 15000)).assertTrue();
      expect(cloudRegistrationRetryAllowed(
        true, true, true, bound, false, false,
        10000, 1000, 15000)).assertFalse();
      expect(cloudRegistrationRetryAllowed(
        true, true, true, bound, false, false,
        16000, 1000, 15000)).assertTrue();
      expect(cloudRegistrationRetryAllowed(
        true, true, true, bound, true, false,
        16000, 1000, 15000)).assertFalse();
      expect(cloudRegistrationRetryAllowed(
        true, true, true, bound, false, true,
        16000, 1000, 15000)).assertFalse();
      expect(cloudRegistrationRetryAllowed(
        true, true, true, unboundCloudAccountBinding(), false, false,
        16000, 0, 15000)).assertFalse();
    });

    it('never_masks_a_failed_core_rebind_with_optional_table_work', 0,
      (): void => {
        expect(cloudRegistrationRetrySucceeded(true, true, true))
          .assertTrue();
        expect(cloudRegistrationRetrySucceeded(true, true, false))
          .assertFalse();
        expect(cloudRegistrationRetrySucceeded(true, false, true))
          .assertFalse();
        expect(cloudRegistrationRetrySucceeded(false, true, true))
          .assertFalse();
      });

    it('uses_the_same_durability_gate_for_startup_and_foreground_retry',
      0, (): void => {
        expect(cloudRuntimeRegistrationAdmissionAllowed(
          true, false, true, false)).assertTrue();
        expect(cloudRuntimeRegistrationAdmissionAllowed(
          false, false, true, false)).assertFalse();
        expect(cloudRuntimeRegistrationAdmissionAllowed(
          true, true, true, false)).assertFalse();
        expect(cloudRuntimeRegistrationAdmissionAllowed(
          true, false, false, false)).assertFalse();
        expect(cloudRuntimeRegistrationAdmissionAllowed(
          true, false, true, true)).assertFalse();
      });

    it('never_commits_local_rows_without_same_transaction_dirty_proof',
      0, (): void => {
        expect(localMutationCommitAllowed(true, false)).assertTrue();
        expect(localMutationCommitAllowed(false, true)).assertTrue();
        expect(localMutationCommitAllowed(false, false)).assertFalse();
      });

    it('pauses_cloud_for_every_failed_legacy_secret_migration',
      0, (): void => {
        // Both malformed payload and transactional migration failures report
        // a negative result and must follow the same fail-local-only path.
        expect(legacyRelayMigrationCloudAdmissionAllowed(-1)).assertFalse();
        expect(legacyRelayMigrationCloudAdmissionAllowed(0)).assertTrue();
        expect(legacyRelayMigrationCloudAdmissionAllowed(2)).assertTrue();
      });

    it('requires_every_isolation_proof_before_optional_table_registration', 0,
      (): void => {
        expect(optionalCloudTableRegistrationAllowed(
          true, true, true, true, true, true)).assertTrue();
        expect(optionalCloudTableRegistrationAllowed(
          false, true, true, true, true, true)).assertFalse();
        expect(optionalCloudTableRegistrationAllowed(
          true, false, true, true, true, true)).assertFalse();
        expect(optionalCloudTableRegistrationAllowed(
          true, true, false, true, true, true)).assertFalse();
        expect(optionalCloudTableRegistrationAllowed(
          true, true, true, false, true, true)).assertFalse();
        expect(optionalCloudTableRegistrationAllowed(
          true, true, true, true, false, true)).assertFalse();
        expect(optionalCloudTableRegistrationAllowed(
          true, true, true, true, true, false)).assertFalse();
      });

    it('requires_an_explicit_remote_schema_deployment_receipt', 0,
      (): void => {
        expect(moonlightCloudSchemaProvisioned()).assertTrue();
        expect(moonlightCloudSchemaProvisioned(0)).assertFalse();
        expect(moonlightCloudSchemaProvisioned(1)).assertTrue();
        expect(moonlightCloudSchemaProvisioned(2)).assertTrue();
      });
  });
}
