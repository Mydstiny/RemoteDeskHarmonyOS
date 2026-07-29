import { describe, it, expect } from '@ohos/hypium';
import {
  CloudAccountBinding,
  cloudAccountBindingIsValid,
  cloudDistributedRegistrationAllowed,
  cloudTransferAllowed,
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
        generation: 1
      };
      expect(cloudAccountBindingIsValid(incomplete)).assertFalse();
      expect(cloudDistributedRegistrationAllowed(incomplete, true)).assertFalse();
    });

    it('requires_both_rollout_and_a_complete_binding', 0, (): void => {
      const bound: CloudAccountBinding = {
        state: 'bound',
        ownerScopeId: 'owner-a',
        storeIdentity: 'account-owner-a.db',
        generation: 1
      };
      expect(cloudAccountBindingIsValid(bound)).assertTrue();
      expect(cloudDistributedRegistrationAllowed(bound, false)).assertFalse();
      expect(cloudTransferAllowed(bound, false)).assertFalse();
      expect(cloudDistributedRegistrationAllowed(bound, true)).assertTrue();
      expect(cloudTransferAllowed(bound, true)).assertTrue();
    });

    it('enables_redacted_backup_while_destructive_legacy_paths_stay_disabled', 0, (): void => {
      expect(remoteCryptoLifecycleMutationAllowed()).assertFalse();
      expect(portableBackupExportAllowed()).assertTrue();
      expect(portableBackupRestoreAllowed()).assertTrue();
      expect(legacyCloudRestTransferAllowed()).assertFalse();
    });
  });
}
