import { describe, expect, it } from '@ohos/hypium';
import {
  MoonlightCloudStatusInput,
  resolveMoonlightCloudStatus
} from '../main/ets/services/MoonlightCloudStatusPolicy';

function ready(): MoonlightCloudStatusInput {
  return {
    accountOnline: true, platformIdentityVerified: true,
    cloudSchemaReady: true, physicalSelected: true,
    selectedScopes: ['hosts'], identityCapabilityReady: false,
    cryptoConfigured: false, cryptoUnlocked: false,
    bootstrapComplete: true, pendingUploadCount: 0, quarantineCount: 0,
    lastSuccessAt: 100, lastErrorCode: ''
  };
}

export default function moonlightCloudStatusPolicyTest(): void {
  describe('MoonlightCloudStatusPolicy', (): void => {
    it('shows_off_for_an_empty_or_unselected_physical_scope', 0, (): void => {
      const input: MoonlightCloudStatusInput = ready();
      input.selectedScopes = [];
      expect(resolveMoonlightCloudStatus(input).state).assertEqual('off');
      input.selectedScopes = ['hosts'];
      input.physicalSelected = false;
      expect(resolveMoonlightCloudStatus(input).state).assertEqual('off');
    });

    it('separates_platform_and_schema_unavailability_from_off', 0, (): void => {
      const input: MoonlightCloudStatusInput = ready();
      input.platformIdentityVerified = false;
      expect(resolveMoonlightCloudStatus(input).state).assertEqual('unavailable');
      input.platformIdentityVerified = true;
      input.cloudSchemaReady = false;
      expect(resolveMoonlightCloudStatus(input).state).assertEqual('unavailable');
    });

    it('keeps_bootstrap_distinct_from_pending_upload', 0, (): void => {
      const input: MoonlightCloudStatusInput = ready();
      input.bootstrapComplete = false;
      input.pendingUploadCount = 3;
      expect(resolveMoonlightCloudStatus(input).state).assertEqual('bootstrap');
      input.bootstrapComplete = true;
      expect(resolveMoonlightCloudStatus(input).state).assertEqual('pending');
    });

    it('gives_quarantine_and_partial_failure_their_own_states', 0, (): void => {
      const input: MoonlightCloudStatusInput = ready();
      input.quarantineCount = 2;
      input.lastErrorCode = 'partial';
      expect(resolveMoonlightCloudStatus(input).state).assertEqual('quarantined');
      input.quarantineCount = 0;
      expect(resolveMoonlightCloudStatus(input).state).assertEqual('partial_failure');
    });

    it('reports_identity_crypto_lock_without_enabling_upload', 0, (): void => {
      const input: MoonlightCloudStatusInput = ready();
      input.selectedScopes = ['identity'];
      input.identityCapabilityReady = true;
      input.cryptoConfigured = true;
      input.cryptoUnlocked = false;
      const state = resolveMoonlightCloudStatus(input);
      expect(state.state).assertEqual('crypto_locked');
      expect(state.identityScopeLocked).assertTrue();
      expect(state.canUpload).assertFalse();
    });

    it('exposes_ready_and_last_success_without_calling_it_synced', 0,
      (): void => {
        const state = resolveMoonlightCloudStatus(ready());
        expect(state.state).assertEqual('ready');
        expect(state.canUpload).assertTrue();
        expect(state.lastSuccessAt).assertEqual(100);
      });
  });
}
