import { describe, it, expect } from '@ohos/hypium';
import { TotpAlgorithm, TotpCode, TotpEntry } from '../main/ets/model/TotpEntry';
import {
  isRustDeskPeerTwoFactorAutoSubmitCompatible,
  isRustDeskPeerTwoFactorManualCode,
  rustDeskPeerTwoFactorAutoSubmitError,
  RUSTDESK_PEER_2FA_MIN_REMAINING_SECONDS
} from '../main/ets/services/RustDeskPeerTwoFactorPolicy';

export default function rustDeskPeerTwoFactorPolicyTest(): void {
  describe('RustDeskPeerTwoFactorPolicy', (): void => {
    it('accepts_only_the_supported_manual_code_lengths', 0, (): void => {
      expect(isRustDeskPeerTwoFactorManualCode('123456')).assertTrue();
      expect(isRustDeskPeerTwoFactorManualCode('12345678')).assertTrue();
      expect(isRustDeskPeerTwoFactorManualCode('12345')).assertFalse();
      expect(isRustDeskPeerTwoFactorManualCode('1234567')).assertFalse();
      expect(isRustDeskPeerTwoFactorManualCode('12345x')).assertFalse();
    });

    it('limits_automatic_submission_to_the_official_rustdesk_totp_shape', 0, (): void => {
      const entry = new TotpEntry();
      entry.algorithm = TotpAlgorithm.SHA1;
      entry.digits = 6;
      entry.period = 30;
      expect(isRustDeskPeerTwoFactorAutoSubmitCompatible(entry)).assertTrue();
      entry.digits = 8;
      expect(isRustDeskPeerTwoFactorAutoSubmitCompatible(entry)).assertFalse();
      entry.digits = 6;
      entry.algorithm = TotpAlgorithm.SHA256;
      expect(isRustDeskPeerTwoFactorAutoSubmitCompatible(entry)).assertFalse();
    });

    it('falls_back_to_manual_input_at_the_totp_period_boundary', 0, (): void => {
      const entry = new TotpEntry();
      const safe: TotpCode = {
        code: '123456', remaining: RUSTDESK_PEER_2FA_MIN_REMAINING_SECONDS,
        total: 30, progress: 0.5
      };
      expect(rustDeskPeerTwoFactorAutoSubmitError(entry, safe)).assertEqual('');
      const expiring: TotpCode = {
        code: '123456', remaining: RUSTDESK_PEER_2FA_MIN_REMAINING_SECONDS - 1,
        total: 30, progress: 0.9
      };
      expect(rustDeskPeerTwoFactorAutoSubmitError(entry, expiring).indexOf('即将更新') >= 0)
        .assertTrue();
    });
  });
}
