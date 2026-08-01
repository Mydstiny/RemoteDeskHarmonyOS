import {
  RustDeskProAccountState,
  rustDeskProAccessTokenFingerprint,
  rustDeskProTokenGeneration
} from '../model/RustDeskProModels';
import {
  cloneRustDeskControlPlaneCapabilityProof,
  RustDeskControlPlaneCapabilityProof
} from '../model/RustDeskControlPlaneCapabilityModels';

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
  controlPlaneCapabilityProof?: RustDeskControlPlaneCapabilityProof
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
    lastSyncError: account.lastSyncError,
    controlPlaneCapabilityProof:
      cloneRustDeskControlPlaneCapabilityProof(
        account.controlPlaneCapabilityProof)
  };
}

/**
 * Asset revocation removes only the reusable secret. Server/account/device
 * metadata remains available so a failed scope transition can safely reload
 * the outgoing configuration and ask the user to authenticate again.
 */
export function rustDeskProCredentialAfterTokenRevocation(
  account: RustDeskProAccountState
): RustDeskProAccountState {
  return {
    id: account.id,
    relayId: account.relayId,
    serverUrl: account.serverUrl,
    username: account.username,
    displayName: account.displayName,
    userId: account.userId,
    accessToken: '',
    accessTokenFingerprint:
      rustDeskProAccessTokenFingerprint(''),
    tokenGeneration:
      rustDeskProTokenGeneration(account) + 1,
    deviceId: account.deviceId,
    deviceUuid: account.deviceUuid,
    loginStatus: 'requires_login',
    lastLoginAt: account.lastLoginAt,
    lastSyncAt: account.lastSyncAt,
    lastSyncError: 'credential_revoked_on_scope_transition',
    controlPlaneCapabilityProof: undefined
  };
}
