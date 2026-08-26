import { describe, it, expect } from '@ohos/hypium';
import { VncSessionCredentialHandoff } from '../main/ets/services/VncSessionCredentialHandoff';

export default function vncSessionCredentialHandoffTest(): void {
  describe('VncSessionCredentialHandoff', (): void => {
    it('hands_off_a_password_once_and_keeps_users_isolated', 0, (): void => {
      const handoff = VncSessionCredentialHandoff.getInstance();
      handoff.clear('test-user-a', 'test-host');
      handoff.clear('test-user-b', 'test-host');
      handoff.put('test-user-a', 'test-host', 'one-time-password');
      expect(handoff.take('test-user-b', 'test-host')).assertEqual('');
      expect(handoff.take('test-user-a', 'test-host')).assertEqual('one-time-password');
      expect(handoff.take('test-user-a', 'test-host')).assertEqual('');
    });

    it('preserves_an_explicit_no_password_decision', 0, (): void => {
      const handoff = VncSessionCredentialHandoff.getInstance();
      handoff.clear('test-user', 'empty-host');
      expect(handoff.put('test-user', 'empty-host', '')).assertTrue();
      expect(handoff.has('test-user', 'empty-host')).assertTrue();
      const decision = handoff.takeDecision('test-user', 'empty-host');
      expect(decision === null).assertFalse();
      expect(decision?.password).assertEqual('');
      expect(handoff.has('test-user', 'empty-host')).assertFalse();
    });

    it('binds_a_settings_credential_once_to_endpoint_and_account_scope', 0, (): void => {
      const handoff = VncSessionCredentialHandoff.getInstance();
      const endpointA: string =
        'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
      const endpointB: string =
        'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
      handoff.clear('test-user', 'bound-host');
      expect(handoff.put('test-user', 'bound-host', 'one-shot')).assertTrue();
      expect(handoff.bind('test-user', 'bound-host', endpointA, 'test-user', 7)).assertTrue();
      expect(handoff.takeDecision(
        'test-user', 'bound-host', endpointA, 'test-user', 7)?.password).assertEqual('one-shot');

      expect(handoff.put(
        'test-user', 'bound-host', 'must-not-rebind', endpointA, 'test-user', 7)).assertTrue();
      expect(handoff.bind('test-user', 'bound-host', endpointB, 'test-user', 7)).assertFalse();
      expect(handoff.takeDecision(
        'test-user', 'bound-host', endpointA, 'test-user', 7)).assertNull();
    });
  });
}
