import { describe, it, expect } from '@ohos/hypium';
import { VncHostValues } from '../main/ets/services/VncModelPolicy';
import {
  VncSecretEditDecision,
  vncSecretBindingUnchanged,
  vncSecretEditDecision
} from '../main/ets/services/VncSecretEditPolicy';

function host(host: string = 'server-a', port: number = 5900): VncHostValues {
  return {
    label: 'VNC', host, port, username: '', gatewayId: '', transport: 'direct_tcp',
    repeaterMode: 'mode12', rememberPassword: true, viewOnly: false,
    displayOverrideEnabled: false, scalingMode: 'fit', clipboardEnabled: false,
    securityPolicy: 'secure_only', tls: true, locked: false, lockType: 0
  };
}

export default function vncSecretEditPolicyTest() {
  describe('VncSecretEditPolicy', (): void => {
    it('keeps_an_unchanged_secret_only_on_the_same_endpoint', 0, (): void => {
      const previous: VncHostValues = host();
      const same: VncSecretEditDecision = vncSecretEditDecision(
        'old-password', '', false, true, false, previous, host());
      expect(same.storageMutation).assertEqual('keep');

      const changed: VncSecretEditDecision = vncSecretEditDecision(
        'old-password', '', false, true, false, previous, host('server-b'));
      expect(changed.storageMutation).assertEqual('clear');
      expect(changed.submissionValue).assertEqual('');
    });

    it('does_not_handoff_an_old_secret_to_a_changed_endpoint', 0, (): void => {
      const previous: VncHostValues = host();
      const same: VncSecretEditDecision = vncSecretEditDecision(
        'old-password', '', false, false, true, previous, host());
      expect(same.storageMutation).assertEqual('clear');
      expect(same.submissionValue).assertEqual('old-password');

      const changed: VncSecretEditDecision = vncSecretEditDecision(
        'old-password', '', false, false, true, previous, host('server-b'));
      expect(changed.submissionValue).assertEqual('');
    });

    it('treats_visible_manual_clear_as_an_explicit_delete', 0, (): void => {
      const decision: VncSecretEditDecision = vncSecretEditDecision(
        'old-password', '', true, true, false, host(), host());
      expect(decision.storageMutation).assertEqual('clear');
    });

    it('binds_passwords_to_gateway_target_and_security_mode', 0, (): void => {
      const previous: VncHostValues = host('target-a', 5901);
      previous.transport = 'ultravnc_repeater';
      previous.gatewayId = 'gateway-a';
      const next: VncHostValues = host('target-a', 5901);
      next.transport = 'ultravnc_repeater';
      next.gatewayId = 'gateway-a';
      expect(vncSecretBindingUnchanged(previous, next)).assertTrue();
      next.host = 'target-b';
      expect(vncSecretBindingUnchanged(previous, next)).assertFalse();
      next.host = 'target-a';
      next.tls = false;
      next.securityPolicy = 'allow_plaintext';
      expect(vncSecretBindingUnchanged(previous, next)).assertFalse();
    });
  });
}
