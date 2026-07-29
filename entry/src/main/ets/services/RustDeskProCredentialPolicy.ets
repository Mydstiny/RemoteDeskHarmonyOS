import { RustDeskProAccountState } from '../model/RustDeskProModels';

/**
 * Device-local, non-secret metadata persisted in Preferences.
 *
 * The reusable access token deliberately has no field in this shape. It is
 * stored separately in Asset Store and can therefore never be serialized by
 * this policy.
 */
export interface RustDeskProCredentialMetadata {
  id: string
  relayId: string
  serverUrl: string
  username: string
  displayName: string
  userId: string
  accessTokenFingerprint: string
  tokenGeneration: number
  deviceId: string
  deviceUuid: string
  loginStatus: string
  lastLoginAt: number
  lastSyncAt: number
  lastSyncError: string
}

export function rustDeskProCredentialMetadata(
  account: RustDeskProAccountState
): RustDeskProCredentialMetadata {
  return {
    id: account.id,
    relayId: account.relayId,
    serverUrl: account.serverUrl,
    username: account.username,
    displayName: account.displayName,
    userId: account.userId,
    accessTokenFingerprint: account.accessTokenFingerprint,
    tokenGeneration: account.tokenGeneration,
    deviceId: account.deviceId,
    deviceUuid: account.deviceUuid,
    loginStatus: account.loginStatus,
    lastLoginAt: account.lastLoginAt,
    lastSyncAt: account.lastSyncAt,
    lastSyncError: account.lastSyncError
  };
}
