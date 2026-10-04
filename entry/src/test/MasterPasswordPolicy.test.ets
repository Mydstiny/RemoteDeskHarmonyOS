import { describe, expect, it } from '@ohos/hypium';
import {
  masterPasswordSetupError,
  masterPasswordValueAcceptable
} from '../main/ets/services/MasterPasswordPolicy';

export default function masterPasswordPolicyTest(): void {
  describe('MasterPasswordPolicy', (): void => {
    it('accepts_any_non_empty_password_without_length_or_complexity_rules', 0, (): void => {
      expect(masterPasswordValueAcceptable('a')).assertTrue();
      expect(masterPasswordValueAcceptable('1234')).assertTrue();
      expect(masterPasswordValueAcceptable('lowercase only')).assertTrue();
      expect(masterPasswordValueAcceptable(' ')).assertTrue();
      expect(masterPasswordValueAcceptable('x'.repeat(200))).assertTrue();
      expect(masterPasswordValueAcceptable('')).assertFalse();
    });

    it('requires_only_a_value_and_matching_confirmation', 0, (): void => {
      expect(masterPasswordSetupError('a', 'a')).assertEqual('');
      expect(masterPasswordSetupError('', '')).assertEqual('请输入主密码');
      expect(masterPasswordSetupError('abc', 'abd')).assertEqual('两次输入的密码不一致');
      // Used exactly as typed: surrounding spaces are part of the password.
      expect(masterPasswordSetupError(' abc', 'abc')).assertEqual('两次输入的密码不一致');
    });
  });
}
