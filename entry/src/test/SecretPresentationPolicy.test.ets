import { describe, it, expect } from '@ohos/hypium';
import {
  allHiddenSecretPresentationPolicy,
  defaultSecretPresentationPolicy,
  editableSecretKinds,
  parseSecretPresentationPolicy,
  secretPresentationHidden,
  secretPresentationSummary,
  serializeSecretPresentationPolicy,
  withSecretPresentationHidden
} from '../main/ets/services/SecretPresentationPolicy';

export default function secretPresentationPolicyTest() {
  describe('SecretPresentationPolicy', (): void => {
    it('preserves_the_existing_vnc_write_only_default', 0, (): void => {
      const policy = defaultSecretPresentationPolicy();
      expect(secretPresentationHidden(policy, 'vnc_host_password')).assertTrue();
      expect(secretPresentationHidden(policy, 'rdp_host_password')).assertFalse();
      expect(policy.hiddenKinds.length).assertEqual(1);
    });

    it('parses_only_versioned_allowlisted_unique_kinds', 0, (): void => {
      const parsed = parseSecretPresentationPolicy(JSON.stringify({
        version: 1,
        hiddenKinds: ['rdp_host_password', 'rdp_host_password', 'not-a-secret', 1]
      }));
      expect(parsed.hiddenKinds.length).assertEqual(1);
      expect(parsed.hiddenKinds[0]).assertEqual('rdp_host_password');
      expect(parseSecretPresentationPolicy('{broken').hiddenKinds[0])
        .assertEqual('vnc_host_password');
      expect(parseSecretPresentationPolicy(JSON.stringify({ version: 2, hiddenKinds: [] }))
        .hiddenKinds[0]).assertEqual('vnc_host_password');
    });

    it('toggles_without_mutating_the_input_and_roundtrips', 0, (): void => {
      const initial = defaultSecretPresentationPolicy();
      const next = withSecretPresentationHidden(initial, 'ssh_host_password', true);
      expect(initial.hiddenKinds.length).assertEqual(1);
      expect(secretPresentationHidden(next, 'ssh_host_password')).assertTrue();
      const restored = parseSecretPresentationPolicy(serializeSecretPresentationPolicy(next));
      expect(secretPresentationHidden(restored, 'ssh_host_password')).assertTrue();
    });

    it('supports_all_hidden_and_security_overrides', 0, (): void => {
      const all = allHiddenSecretPresentationPolicy();
      expect(all.hiddenKinds.length).assertEqual(editableSecretKinds().length);
      expect(secretPresentationSummary(all).indexOf('全部') >= 0).assertTrue();
      expect(secretPresentationHidden(defaultSecretPresentationPolicy(),
        'rdp_saved_credential', true)).assertTrue();
    });
  });
}
