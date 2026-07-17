import { describe, it, expect } from '@ohos/hypium';
import { RustDeskProAccountState } from '../../../main/ets/model/RustDeskProModels';
import { LegacyRustDeskAccountCloudAdapter } from '../../../main/ets/services/LegacyRustDeskAccountCloudAdapter';

export default function legacyRustDeskAccountCloudAdapterTest(): void {
  describe('LegacyRustDeskAccountCloudAdapter', (): void => {
    it('must_not_put_pro_secrets_in_legacy_cloud_record', 0, (): void => {
      const account: RustDeskProAccountState = {
        id: 'pro-1', relayId: 'relay-1', serverUrl: 'https://pro.example.com', username: 'alice',
        displayName: 'Alice', userId: '42', accessToken: 'secret-token', deviceId: 'device',
        deviceUuid: 'uuid', loginStatus: 'logged_in', lastLoginAt: 100, lastSyncAt: 200, lastSyncError: ''
      };
      const legacy = LegacyRustDeskAccountCloudAdapter.toLegacy(account);
      expect(legacy.password).assertEqual('');
      expect(legacy.loginStatus).assertEqual('pro_metadata');
      expect(legacy.username).assertEqual('alice');
    });

    it('cloud_metadata_requires_login_on_a_new_device', 0, (): void => {
      const account: RustDeskProAccountState = {
        id: 'pro-1', relayId: 'relay-1', serverUrl: 'https://pro.example.com', username: 'alice',
        displayName: 'Alice', userId: '', accessToken: '', deviceId: '', deviceUuid: '',
        loginStatus: 'logged_in', lastLoginAt: 100, lastSyncAt: 0, lastSyncError: ''
      };
      const restored = LegacyRustDeskAccountCloudAdapter.fromLegacy(
        LegacyRustDeskAccountCloudAdapter.toLegacy(account), account.serverUrl);
      expect(restored.accessToken).assertEqual('');
      expect(restored.loginStatus).assertEqual('requires_login');
    });
  });
}
