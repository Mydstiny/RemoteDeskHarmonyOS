import { describe, expect, it } from '@ohos/hypium';
import {
  classifyCryptoEnvelope,
  cryptoEnvelopeCanMigrateToV3,
  cryptoEnvelopeIsProtected
} from '../main/ets/services/CryptoEnvelopePolicy';

export default function cryptoEnvelopePolicyTest(): void {
  describe('CryptoEnvelopePolicy', (): void => {
    it('recognizes_legacy_vnc_and_scoped_envelopes', 0, (): void => {
      expect(classifyCryptoEnvelope('1:a:b')).assertEqual('legacy_v1');
      expect(classifyCryptoEnvelope('2:a:b:c')).assertEqual('vnc_v2');
      expect(classifyCryptoEnvelope('3:a:b:c')).assertEqual('scoped_v3');
    });

    it('never_treats_a_damaged_or_future_envelope_as_plaintext', 0, (): void => {
      expect(classifyCryptoEnvelope('1:broken')).assertEqual('malformed_v1');
      expect(classifyCryptoEnvelope('3:a::c')).assertEqual('malformed_v3');
      expect(classifyCryptoEnvelope('9:a:b:c')).assertEqual('unknown_versioned');
      expect(cryptoEnvelopeIsProtected('9:a:b:c')).assertTrue();
      expect(cryptoEnvelopeCanMigrateToV3('9:a:b:c')).assertFalse();
    });

    it('keeps_ordinary_colon_text_as_plaintext', 0, (): void => {
      expect(classifyCryptoEnvelope('https://example.com')).assertEqual('plaintext');
      expect(classifyCryptoEnvelope('user:password')).assertEqual('plaintext');
      expect(cryptoEnvelopeIsProtected('user:password')).assertFalse();
      expect(cryptoEnvelopeCanMigrateToV3('user:password')).assertTrue();
    });
  });
}
