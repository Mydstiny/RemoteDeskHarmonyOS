import { expect } from '@ohos/hypium';
import {
  auditedDescribe as describe,
  auditedIt as it
} from '../main/ets/services/FocusedTestRegistrationAudit';
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
    it('upgrades_empty_legacy_scopes_and_uses_only_the_physical_state', 0, (): void => {
      const input: MoonlightCloudStatusInput = ready();
      input.selectedScopes = [];
      expect(resolveMoonlightCloudStatus(input).state).assertEqual('ready');
      expect(resolveMoonlightCloudStatus(input).scopes.join(','))
        .assertEqual('settings,hosts,profiles');
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

    it('ignores_legacy_identity_scope_because_private_identity_is_local_only', 0, (): void => {
      const input: MoonlightCloudStatusInput = ready();
      input.selectedScopes = ['identity'];
      input.identityCapabilityReady = true;
      input.cryptoConfigured = true;
      input.cryptoUnlocked = false;
      const state = resolveMoonlightCloudStatus(input);
      expect(state.state).assertEqual('ready');
      expect(state.identityScopeLocked).assertFalse();
      expect(state.canUpload).assertTrue();
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
