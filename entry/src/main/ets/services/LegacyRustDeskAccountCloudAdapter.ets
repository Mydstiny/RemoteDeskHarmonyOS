import { RustDeskAccount } from '../model/RustDeskAccount';
import { RustDeskProAccountState } from '../model/RustDeskProModels';

/** Marker stored in the released accountsjson.loginStatus field. */
const PRO_METADATA_STATUS: string = 'pro_metadata';

/**
 * Maps Server Pro account metadata onto the released RustDeskAccount JSON
 * shape. Passwords and API tokens are deliberately never mapped.
 */
export class LegacyRustDeskAccountCloudAdapter {
  static isProMetadata(account: RustDeskAccount): boolean {
    return account.loginStatus === PRO_METADATA_STATUS;
  }

  static fromLegacy(account: RustDeskAccount, serverUrl: string): RustDeskProAccountState {
    return {
      id: account.id,
      relayId: account.relayId,
      serverUrl: serverUrl,
      username: account.username,
      displayName: account.username,
      userId: '',
      accessToken: '',
      deviceId: '',
      deviceUuid: '',
      loginStatus: 'requires_login',
      lastLoginAt: account.lastLoginAt,
      lastSyncAt: 0,
      lastSyncError: ''
    };
  }

  static toLegacy(account: RustDeskProAccountState): RustDeskAccount {
    const legacy = new RustDeskAccount();
    legacy.id = account.id;
    legacy.relayId = account.relayId;
    legacy.username = account.username;
    legacy.password = '';
    legacy.loginStatus = PRO_METADATA_STATUS;
    legacy.lastLoginAt = account.lastLoginAt;
    legacy.createdAt = account.lastLoginAt > 0 ? account.lastLoginAt : Date.now();
    return legacy;
  }
}
