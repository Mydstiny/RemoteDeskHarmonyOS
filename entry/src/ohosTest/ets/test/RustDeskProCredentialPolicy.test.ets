import { describe, it, expect } from '@ohos/hypium';
import { RustDeskProAccountState } from '../../../main/ets/model/RustDeskProModels';
import {
  rustDeskProCredentialMetadata
} from '../../../main/ets/services/RustDeskProCredentialPolicy';

export default function rustDeskProCredentialPolicyTest(): void {
  describe('RustDeskProCredentialPolicy', (): void => {
    it('preferences_metadata_must_never_serialize_access_token',
      0, (): void => {
        const secret: string = 'asset-store-only-token';
        const account: RustDeskProAccountState = {
          id: 'pro-1',
          relayId: 'relay-1',
          serverUrl: 'https://pro.example.com',
          username: 'alice',
          displayName: 'Alice',
          userId: '42',
          accessToken: secret,
          accessTokenFingerprint: 'fingerprint',
          tokenGeneration: 2,
          deviceId: 'device',
          deviceUuid: 'uuid',
          loginStatus: 'logged_in',
          lastLoginAt: 100,
          lastSyncAt: 200,
          lastSyncError: ''
        };

        const serialized: string = JSON.stringify(
          rustDeskProCredentialMetadata(account));
        expect(serialized.indexOf(secret)).assertEqual(-1);
        expect(serialized.indexOf('"accessToken"')).assertEqual(-1);
        expect(serialized.indexOf('"accessTokenFingerprint"'))
          .assertLarger(0);
      });
  });
}
