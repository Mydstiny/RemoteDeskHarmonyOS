import { describe, expect, it } from '@ohos/hypium';
import { maskHost, maskSecret, maskUser, safeError } from '../../../main/ets/utils/SafeLogger';

export default function safeLoggerTest(): void {
  describe('SafeLogger', (): void => {
    it('maskHost_should_keep_diagnostic_shape_without_full_host', 0, (): void => {
      expect(maskHost('192.168.31.177')).assertEqual('192.168.*.177');
      expect(maskHost('rdp.office.example.com')).assertEqual('rdp...com');
      expect(maskHost('pc')).assertEqual('p*');
    });

    it('maskUser_should_hide_email_and_domain_user_identity', 0, (): void => {
      expect(maskUser('alice@example.com')).assertEqual('a***e@e***e.com');
      expect(maskUser('DOMAIN\\administrator')).assertEqual('D***N\\a***r');
      expect(maskUser('li')).assertEqual('l*');
    });

    it('maskSecret_should_never_return_original_secret', 0, (): void => {
      expect(maskSecret('')).assertEqual('<empty>');
      expect(maskSecret('abc')).assertEqual('<secret:3>');
      expect(maskSecret('super-long-password')).assertEqual('<secret:19>');
    });

    it('safeError_should_keep_message_without_serializing_objects', 0, (): void => {
      const err: Error = new Error('connection failed for password=abc123');
      const text: string = safeError(err);
      expect(text.indexOf('connection failed')).assertLarger(-1);
      expect(text.indexOf('abc123')).assertEqual(-1);
    });
  });
}
