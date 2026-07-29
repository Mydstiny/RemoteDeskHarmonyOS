import { util } from '@kit.ArkTS';

export const ACCOUNT_CREDENTIAL_STORAGE_VERSION: number = 2;
export const ACCOUNT_CREDENTIAL_ASSET_MAX_BYTES: number = 1024;

export interface AccountCredentialMetadataV2 {
  storageVersion: number;
  unionID: string;
  openID: string;
  tokenExpiresAt: number;
  displayName: string;
  loginTime: number;
  accessTokenStored: boolean;
  refreshTokenStored: boolean;
}

export interface AccountCredentialLegacySecrets {
  accessToken: string;
  refreshToken: string;
}

export interface ParsedAccountCredentialRecord {
  metadata: AccountCredentialMetadataV2 | null;
  legacySecrets: AccountCredentialLegacySecrets;
  requiresRewrite: boolean;
  plaintextSecretsFound: boolean;
}

function stringValue(value: Object | undefined): string {
  return typeof value === 'string' ? value as string : '';
}

function finiteNumber(value: Object | undefined): number {
  if (typeof value !== 'number' || !Number.isFinite(value as number)) {
    return 0;
  }
  return value as number;
}

function booleanValue(value: Object | undefined): boolean {
  return typeof value === 'boolean' && value as boolean;
}

export function accountCredentialSecretFitsAssetStore(
  secret: string
): boolean {
  if (secret.length === 0) { return true; }
  const bytes: Uint8Array = new util.TextEncoder().encode(secret);
  return bytes.length > 0 &&
    bytes.length <= ACCOUNT_CREDENTIAL_ASSET_MAX_BYTES;
}

export function accountCredentialMetadata(
  unionID: string,
  openID: string,
  tokenExpiresAt: number,
  displayName: string,
  loginTime: number,
  accessTokenStored: boolean,
  refreshTokenStored: boolean
): AccountCredentialMetadataV2 | null {
  const normalizedUnionID: string = unionID.trim();
  if (normalizedUnionID.length === 0) { return null; }
  return {
    storageVersion: ACCOUNT_CREDENTIAL_STORAGE_VERSION,
    unionID: normalizedUnionID,
    openID,
    tokenExpiresAt: Number.isFinite(tokenExpiresAt)
      ? Math.max(0, Math.floor(tokenExpiresAt)) : 0,
    displayName,
    loginTime: Number.isFinite(loginTime)
      ? Math.max(0, Math.floor(loginTime)) : 0,
    accessTokenStored,
    refreshTokenStored
  };
}

export function serializeAccountCredentialMetadata(
  metadata: AccountCredentialMetadataV2
): string {
  return JSON.stringify({
    storageVersion: ACCOUNT_CREDENTIAL_STORAGE_VERSION,
    unionID: metadata.unionID,
    openID: metadata.openID,
    tokenExpiresAt: metadata.tokenExpiresAt,
    displayName: metadata.displayName,
    loginTime: metadata.loginTime,
    accessTokenStored: metadata.accessTokenStored,
    refreshTokenStored: metadata.refreshTokenStored
  });
}

export function parseAccountCredentialRecord(
  raw: string
): ParsedAccountCredentialRecord {
  const empty: ParsedAccountCredentialRecord = {
    metadata: null,
    legacySecrets: { accessToken: '', refreshToken: '' },
    requiresRewrite: raw.length > 0,
    plaintextSecretsFound: false
  };
  if (raw.length === 0) { return empty; }
  try {
    const parsed: Object = JSON.parse(raw) as Object;
    if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) {
      return empty;
    }
    const record: Record<string, Object> =
      parsed as Record<string, Object>;
    const unionID: string = stringValue(record['unionID']).trim();
    if (unionID.length === 0) { return empty; }
    const version: number = finiteNumber(record['storageVersion']);
    if (version === ACCOUNT_CREDENTIAL_STORAGE_VERSION) {
      return {
        metadata: accountCredentialMetadata(
          unionID,
          stringValue(record['openID']),
          finiteNumber(record['tokenExpiresAt']),
          stringValue(record['displayName']),
          finiteNumber(record['loginTime']),
          booleanValue(record['accessTokenStored']),
          booleanValue(record['refreshTokenStored'])
        ),
        legacySecrets: { accessToken: '', refreshToken: '' },
        requiresRewrite: false,
        plaintextSecretsFound: false
      };
    }
    const authorizationCode: string =
      stringValue(record['authorizationCode']);
    const idToken: string = stringValue(record['idToken']);
    const accessToken: string = stringValue(record['accessToken']);
    const refreshToken: string = stringValue(record['refreshToken']);
    return {
      metadata: accountCredentialMetadata(
        unionID,
        stringValue(record['openID']),
        finiteNumber(record['tokenExpiresAt']),
        stringValue(record['displayName']),
        finiteNumber(record['loginTime']),
        false,
        false
      ),
      legacySecrets: { accessToken, refreshToken },
      requiresRewrite: true,
      plaintextSecretsFound: authorizationCode.length > 0 ||
        idToken.length > 0 || accessToken.length > 0 ||
        refreshToken.length > 0
    };
  } catch (_err) {
    return empty;
  }
}
