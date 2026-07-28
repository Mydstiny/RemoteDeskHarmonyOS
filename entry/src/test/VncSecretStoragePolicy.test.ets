import { describe, it, expect } from '@ohos/hypium';
import {
  decodePlainVncSecret,
  decideVncSecretStorage,
  encodePlainVncSecret,
  isPlainVncSecretEnvelope
} from '../main/ets/services/VncSecretStoragePolicy';

export default function vncSecretStoragePolicyTest(): void {
  describe('VncSecretStoragePolicy', (): void => {
    it('does_not_require_crypto_when_password_is_not_remembered', 0, (): void => {
      const decision = decideVncSecretStorage(false, false, false, false);
      expect(decision.allowed).assertTrue();
      expect(decision.mode).assertEqual('');
    });

    it('requires_explicit_confirmation_for_plain_remembered_passwords', 0, (): void => {
      const decision = decideVncSecretStorage(true, false, false, false);
      expect(decision.allowed).assertFalse();
      expect(decision.code).assertEqual('plain_confirmation_required');
      const confirmed = decideVncSecretStorage(true, false, false, true);
      expect(confirmed.allowed).assertTrue();
      expect(confirmed.mode).assertEqual('plain_explicit_v1');
    });

    it('requires_unlock_for_encrypted_remembered_passwords', 0, (): void => {
      const decision = decideVncSecretStorage(true, true, false, true);
      expect(decision.allowed).assertFalse();
      expect(decision.code).assertEqual('unlock_required');
      const ready = decideVncSecretStorage(true, true, true, false);
      expect(ready.allowed).assertTrue();
      expect(ready.mode).assertEqual('encrypted_v2');
    });

    it('round_trips_plain_v1_secret_envelopes', 0, (): void => {
      const envelope: string = encodePlainVncSecret('测试 VNC 密码!');
      expect(isPlainVncSecretEnvelope(envelope)).assertTrue();
      expect(decodePlainVncSecret(envelope)).assertEqual('测试 VNC 密码!');
      expect(isPlainVncSecretEnvelope('plain-v1:not-valid-base64')).assertFalse();
      expect(decodePlainVncSecret('plain-v1:not-valid-base64')).assertEqual(null);
    });
  });
}
