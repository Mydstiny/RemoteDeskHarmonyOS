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

    it('does_not_store_empty_credentials', 0, (): void => {
      const handoff = VncSessionCredentialHandoff.getInstance();
      handoff.clear('test-user', 'empty-host');
      handoff.put('test-user', 'empty-host', '');
      expect(handoff.take('test-user', 'empty-host')).assertEqual('');
    });
  });
}
