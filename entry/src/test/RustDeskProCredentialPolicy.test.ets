import { describe, expect, it } from '@ohos/hypium';
import {
  RustDeskProAccountState
} from '../main/ets/model/RustDeskProModels';
import {
  rustDeskProCredentialAfterTokenRevocation,
  rustDeskProCredentialMetadata
} from '../main/ets/services/RustDeskProCredentialPolicy';

function accountWithToken(): RustDeskProAccountState {
  return {
    id: 'account-a',
    relayId: 'relay-a',
    serverUrl: 'https://pro.example.test',
    username: 'alice',
    displayName: 'Alice',
    userId: 'user-a',
    accessToken: 'secret-token',
    accessTokenFingerprint: 'old-fingerprint',
    tokenGeneration: 7,
    deviceId: 'device-a',
    deviceUuid: 'uuid-a',
    loginStatus: 'logged_in',
    lastLoginAt: 100,
    lastSyncAt: 200,
    lastSyncError: ''
  };
}

export default function rustDeskProCredentialPolicyTest():
  void {
  describe('RustDeskProCredentialPolicy', (): void => {
    it('revokes_only_the_token_and_preserves_non_secret_account_metadata',
      0, (): void => {
        const revoked: RustDeskProAccountState =
          rustDeskProCredentialAfterTokenRevocation(
            accountWithToken());
        expect(revoked.accessToken).assertEqual('');
        expect(revoked.accessTokenFingerprint ===
          'old-fingerprint').assertFalse();
        expect(revoked.tokenGeneration)
          .assertEqual(8);
        expect(revoked.loginStatus)
          .assertEqual('requires_login');
        expect(revoked.serverUrl)
          .assertEqual('https://pro.example.test');
        expect(revoked.username).assertEqual('alice');
        expect(revoked.deviceId)
          .assertEqual('device-a');
        expect(revoked.deviceUuid)
          .assertEqual('uuid-a');
        const metadata =
          rustDeskProCredentialMetadata(revoked);
        const raw: string =
          JSON.stringify(metadata);
        expect(raw.indexOf('secret-token'))
          .assertEqual(-1);
        expect(metadata.id)
          .assertEqual('account-a');
        expect(metadata.loginStatus)
          .assertEqual('requires_login');
      });
  });
}
