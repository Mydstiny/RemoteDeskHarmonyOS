/**
 * Huawei Account credential lifecycle.
 *
 * Stable account metadata remains in app-private Preferences. Reusable bearer
 * and refresh tokens are stored as THIS_DEVICE Asset Store records and must
 * fit Asset Store's documented 1 KiB short-secret limit. Authorization codes
 * and ID tokens are deliberately memory-only.
 */
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { asset } from '@kit.AssetStoreKit';
import { util } from '@kit.ArkTS';
import { http } from '@kit.NetworkKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  AccountCredentialMetadataV2,
  accountCredentialMetadata,
  accountCredentialSecretFitsAssetStore,
  parseAccountCredentialRecord,
  serializeAccountCredentialMetadata
} from './AccountCredentialStoragePolicy';
import { ownerScopeIdForUnionId } from './AccountScopePolicy';
import { safeError } from '../utils/SafeLogger';

const TAG: string = 'AccountKit';
const DOMAIN: number = 0x0013;
const STORE_NAME: string = 'AccountKitCreds';
const KEY_CREDENTIAL: string = 'credential_json';
const KEY_PENDING_ASSET_CLEANUP: string =
  'pending_asset_cleanup_json';
const TOKEN_ALIAS_DOMAIN: string =
  'RemoteDeskHarmonyOS:account-kit-token:v2:';
const ASSET_NOT_FOUND_CODE: number = 24000002;

/** AGC OAuth Token endpoint. */
const AGC_TOKEN_ENDPOINT: string =
  'https://oauth-login.cloud.huawei.com/oauth2/v3/token';

type AccountTokenKind = 'access' | 'refresh';

/** In-memory credential. Secret fields are never serialized as JSON. */
export interface StoredCredential {
  unionID: string;
  openID: string;
  authorizationCode: string;
  idToken: string;
  accessToken: string;
  refreshToken: string;
  tokenExpiresAt: number;
  displayName: string;
  loginTime: number;
}

export interface CredentialParams {
  unionID: string;
  openID: string;
  authorizationCode: string;
  idToken: string;
  displayName: string;
}

export class AccountKitService {
  private static instance: AccountKitService;
  private dataPreferences: preferences.Preferences | null = null;
  private credential: StoredCredential | null = null;
  private persistedMetadata: AccountCredentialMetadataV2 | null = null;
  private pendingCleanupUnionIDs: string[] = [];
  private initPromise: Promise<boolean> | null = null;
  private credentialRevision: number = 0;
  private persistenceTail: Promise<void> = Promise.resolve();

  static getInstance(): AccountKitService {
    if (!AccountKitService.instance) {
      AccountKitService.instance = new AccountKitService();
    }
    return AccountKitService.instance;
  }

  async init(context: common.Context): Promise<boolean> {
    if (this.dataPreferences !== null) { return true; }
    if (this.initPromise !== null) { return await this.initPromise; }
    this.initPromise = this.initializePreferences(context);
    const initialized: boolean = await this.initPromise;
    if (!initialized) { this.initPromise = null; }
    return initialized;
  }

  private async initializePreferences(
    context: common.Context
  ): Promise<boolean> {
    try {
      this.dataPreferences = preferences.getPreferencesSync(
        context, { name: STORE_NAME });
      if (!(await this.loadFromDisk())) {
        this.dataPreferences = null;
        return false;
      }
      return true;
    } catch (err) {
      hilog.error(DOMAIN, TAG,
        'AccountKitService 初始化失败: ' + safeError(err));
      this.dataPreferences = null;
      return false;
    }
  }

  private assetErrorCode(error: Object): number {
    if (!error || typeof error !== 'object') { return 0; }
    const record: Record<string, Object> =
      error as Record<string, Object>;
    return typeof record['code'] === 'number'
      ? record['code'] as number : 0;
  }

  private tokenAlias(
    unionID: string,
    kind: AccountTokenKind
  ): Uint8Array {
    const ownerScopeId: string =
      ownerScopeIdForUnionId(unionID);
    return new util.TextEncoder().encode(
      TOKEN_ALIAS_DOMAIN + ownerScopeId + ':' + kind);
  }

  private readToken(
    unionID: string,
    kind: AccountTokenKind
  ): string | null {
    if (unionID.trim().length === 0) { return null; }
    try {
      const query: asset.AssetMap = new Map();
      query.set(asset.Tag.ALIAS,
        this.tokenAlias(unionID, kind));
      query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ALL);
      const rows: Array<asset.AssetMap> =
        asset.querySync(query);
      if (rows.length !== 1) { return null; }
      const secret: Uint8Array =
        rows[0].get(asset.Tag.SECRET) as Uint8Array;
      if (!secret || secret.length === 0 ||
        secret.length > 1024) {
        return null;
      }
      return new util.TextDecoder().decodeToString(secret);
    } catch (_err) {
      return null;
    }
  }

  private writeToken(
    unionID: string,
    kind: AccountTokenKind,
    token: string
  ): boolean {
    if (unionID.trim().length === 0 ||
      !accountCredentialSecretFitsAssetStore(token) ||
      token.length === 0) {
      return false;
    }
    try {
      const attributes: asset.AssetMap = new Map();
      attributes.set(asset.Tag.ALIAS,
        this.tokenAlias(unionID, kind));
      attributes.set(asset.Tag.SECRET,
        new util.TextEncoder().encode(token));
      attributes.set(asset.Tag.ACCESSIBILITY,
        asset.Accessibility.DEVICE_FIRST_UNLOCKED);
      attributes.set(asset.Tag.SYNC_TYPE,
        asset.SyncType.THIS_DEVICE);
      attributes.set(asset.Tag.CONFLICT_RESOLUTION,
        asset.ConflictResolution.OVERWRITE);
      asset.addSync(attributes);
      return true;
    } catch (_err) {
      return false;
    }
  }

  private removeToken(
    unionID: string,
    kind: AccountTokenKind
  ): boolean {
    if (unionID.trim().length === 0) { return true; }
    try {
      const query: asset.AssetMap = new Map();
      query.set(asset.Tag.ALIAS,
        this.tokenAlias(unionID, kind));
      asset.removeSync(query);
      return true;
    } catch (err) {
      return this.assetErrorCode(err as Object) ===
        ASSET_NOT_FOUND_CODE;
    }
  }

  private removeAccountTokens(unionID: string): boolean {
    const accessRemoved: boolean =
      this.removeToken(unionID, 'access');
    const refreshRemoved: boolean =
      this.removeToken(unionID, 'refresh');
    return accessRemoved && refreshRemoved;
  }

  private pendingCleanupFromDisk(): string[] {
    if (this.dataPreferences === null) { return []; }
    try {
      const raw: string = this.dataPreferences.getSync(
        KEY_PENDING_ASSET_CLEANUP, '') as string;
      if (raw.length === 0) { return []; }
      const parsed: Object = JSON.parse(raw) as Object;
      if (!Array.isArray(parsed)) { return []; }
      const values: Object[] = parsed as Object[];
      const result: string[] = [];
      for (let i = 0; i < values.length; i++) {
        if (typeof values[i] !== 'string') { continue; }
        const unionID: string = (values[i] as string).trim();
        if (unionID.length > 0 &&
          result.indexOf(unionID) < 0) {
          result.push(unionID);
        }
      }
      return result;
    } catch (_err) {
      return [];
    }
  }

  private addPendingCleanup(
    values: string[],
    unionID: string
  ): void {
    const normalized: string = unionID.trim();
    if (normalized.length > 0 &&
      values.indexOf(normalized) < 0) {
      values.push(normalized);
    }
  }

  private withoutUnionID(
    values: string[],
    unionID: string
  ): string[] {
    const normalized: string = unionID.trim();
    return values.filter((value: string): boolean =>
      value !== normalized);
  }

  private async writePreferenceState(
    metadata: AccountCredentialMetadataV2 | null,
    pendingCleanup: string[]
  ): Promise<boolean> {
    if (this.dataPreferences === null) { return false; }
    try {
      if (metadata === null) {
        this.dataPreferences.deleteSync(KEY_CREDENTIAL);
      } else {
        this.dataPreferences.putSync(
          KEY_CREDENTIAL,
          serializeAccountCredentialMetadata(metadata));
      }
      if (pendingCleanup.length === 0) {
        this.dataPreferences.deleteSync(
          KEY_PENDING_ASSET_CLEANUP);
      } else {
        this.dataPreferences.putSync(
          KEY_PENDING_ASSET_CLEANUP,
          JSON.stringify(pendingCleanup));
      }
      await this.dataPreferences.flush();
      return true;
    } catch (err) {
      hilog.error(DOMAIN, TAG,
        '账号元数据保存失败: ' + safeError(err));
      return false;
    }
  }

  /**
   * Remove protected stale tokens only after the metadata/cleanup receipt is
   * durable. A failed removal remains in the receipt for the next launch.
   */
  private async drainPendingCleanup(
    activeUnionID: string
  ): Promise<boolean> {
    const remaining: string[] = [];
    let succeeded: boolean = true;
    for (let i = 0; i < this.pendingCleanupUnionIDs.length; i++) {
      const unionID: string =
        this.pendingCleanupUnionIDs[i];
      if (unionID === activeUnionID) { continue; }
      if (!this.removeAccountTokens(unionID)) {
        remaining.push(unionID);
        succeeded = false;
      }
    }
    const changed: boolean =
      remaining.length !== this.pendingCleanupUnionIDs.length;
    this.pendingCleanupUnionIDs = remaining;
    if (changed && !(await this.writePreferenceState(
      this.persistedMetadata, remaining))) {
      return false;
    }
    return succeeded;
  }

  private credentialFromMetadata(
    metadata: AccountCredentialMetadataV2,
    accessToken: string,
    refreshToken: string
  ): StoredCredential {
    return {
      unionID: metadata.unionID,
      openID: metadata.openID,
      authorizationCode: '',
      idToken: '',
      accessToken,
      refreshToken,
      tokenExpiresAt: metadata.tokenExpiresAt,
      displayName: metadata.displayName,
      loginTime: metadata.loginTime
    };
  }

  private async migrateLegacyCredential(
    metadata: AccountCredentialMetadataV2,
    accessToken: string,
    refreshToken: string
  ): Promise<boolean> {
    let migratedAccess: string = '';
    let migratedRefresh: string = '';
    if (accessToken.length > 0 &&
      accountCredentialSecretFitsAssetStore(accessToken) &&
      this.writeToken(metadata.unionID, 'access', accessToken)) {
      migratedAccess = accessToken;
    } else {
      this.removeToken(metadata.unionID, 'access');
    }
    if (refreshToken.length > 0 &&
      accountCredentialSecretFitsAssetStore(refreshToken) &&
      this.writeToken(metadata.unionID, 'refresh', refreshToken)) {
      migratedRefresh = refreshToken;
    } else {
      this.removeToken(metadata.unionID, 'refresh');
    }
    const migratedMetadata: AccountCredentialMetadataV2 | null =
      accountCredentialMetadata(
        metadata.unionID, metadata.openID,
        metadata.tokenExpiresAt, metadata.displayName,
        metadata.loginTime, migratedAccess.length > 0,
        migratedRefresh.length > 0);
    if (migratedMetadata === null) { return false; }
    this.pendingCleanupUnionIDs =
      this.withoutUnionID(
        this.pendingCleanupUnionIDs, metadata.unionID);
    if (!(await this.writePreferenceState(
      migratedMetadata, this.pendingCleanupUnionIDs))) {
      this.removeAccountTokens(metadata.unionID);
      return false;
    }
    this.persistedMetadata = migratedMetadata;
    this.credential = this.credentialFromMetadata(
      migratedMetadata, migratedAccess, migratedRefresh);
    return true;
  }

  private async loadFromDisk(): Promise<boolean> {
    if (this.dataPreferences === null) { return false; }
    this.pendingCleanupUnionIDs =
      this.pendingCleanupFromDisk();
    const raw: string = this.dataPreferences.getSync(
      KEY_CREDENTIAL, '') as string;
    const parsed = parseAccountCredentialRecord(raw);
    if (parsed.metadata === null) {
      this.credential = null;
      this.persistedMetadata = null;
      if (raw.length > 0 && !(await this.writePreferenceState(
        null, this.pendingCleanupUnionIDs))) {
        return false;
      }
      this.credentialRevision++;
      await this.drainPendingCleanup('');
      return true;
    }
    if (parsed.requiresRewrite) {
      const migrated: boolean =
        await this.migrateLegacyCredential(
          parsed.metadata,
          parsed.legacySecrets.accessToken,
          parsed.legacySecrets.refreshToken);
      if (!migrated) {
        // Never keep the legacy plaintext as a fallback. If the sanitized
        // rewrite itself cannot become durable, account initialization fails.
        return false;
      }
    } else {
      this.persistedMetadata = parsed.metadata;
      const accessToken: string =
        parsed.metadata.accessTokenStored
          ? this.readToken(parsed.metadata.unionID, 'access') ?? ''
          : '';
      const refreshToken: string =
        parsed.metadata.refreshTokenStored
          ? this.readToken(parsed.metadata.unionID, 'refresh') ?? ''
          : '';
      this.credential = this.credentialFromMetadata(
        parsed.metadata, accessToken, refreshToken);
    }
    this.credentialRevision++;
    await this.drainPendingCleanup(
      this.credential?.unionID ?? '');
    return true;
  }

  private metadataForCredential(
    credential: StoredCredential
  ): AccountCredentialMetadataV2 | null {
    return accountCredentialMetadata(
      credential.unionID, credential.openID,
      credential.tokenExpiresAt, credential.displayName,
      credential.loginTime,
      credential.accessToken.length > 0,
      credential.refreshToken.length > 0);
  }

  private restoreTargetTokens(
    targetUnionID: string,
    previousCredential: StoredCredential | null,
    previousMetadata: AccountCredentialMetadataV2 | null
  ): void {
    if (previousCredential !== null &&
      previousMetadata !== null &&
      previousMetadata.unionID === targetUnionID &&
      previousCredential.unionID === targetUnionID) {
      if (previousMetadata.accessTokenStored &&
        previousCredential.accessToken.length > 0) {
        this.writeToken(
          targetUnionID, 'access',
          previousCredential.accessToken);
      } else {
        this.removeToken(targetUnionID, 'access');
      }
      if (previousMetadata.refreshTokenStored &&
        previousCredential.refreshToken.length > 0) {
        this.writeToken(
          targetUnionID, 'refresh',
          previousCredential.refreshToken);
      } else {
        this.removeToken(targetUnionID, 'refresh');
      }
      return;
    }
    this.removeAccountTokens(targetUnionID);
  }

  private applyTargetTokens(
    credential: StoredCredential,
    previousCredential: StoredCredential | null,
    previousMetadata: AccountCredentialMetadataV2 | null
  ): boolean {
    const sameDurableOwner: boolean =
      previousMetadata !== null &&
      previousMetadata.unionID === credential.unionID;
    let accessSucceeded: boolean = true;
    if (credential.accessToken.length > 0) {
      accessSucceeded = this.writeToken(
        credential.unionID, 'access',
        credential.accessToken);
    } else if (sameDurableOwner &&
      previousMetadata?.accessTokenStored) {
      accessSucceeded = this.removeToken(
        credential.unionID, 'access');
    }
    let refreshSucceeded: boolean = true;
    if (credential.refreshToken.length > 0) {
      refreshSucceeded = this.writeToken(
        credential.unionID, 'refresh',
        credential.refreshToken);
    } else if (sameDurableOwner &&
      previousMetadata?.refreshTokenStored) {
      refreshSucceeded = this.removeToken(
        credential.unionID, 'refresh');
    }
    if (accessSucceeded && refreshSucceeded) { return true; }
    this.restoreTargetTokens(
      credential.unionID, previousCredential,
      previousMetadata);
    return false;
  }

  private async persistSnapshot(
    snapshot: StoredCredential | null,
    previousCredential: StoredCredential | null
  ): Promise<boolean> {
    const previousMetadata: AccountCredentialMetadataV2 | null =
      this.persistedMetadata;
    const nextMetadata: AccountCredentialMetadataV2 | null =
      snapshot === null
        ? null : this.metadataForCredential(snapshot);
    if (snapshot !== null && nextMetadata === null) {
      return false;
    }
    if (snapshot !== null &&
      !this.applyTargetTokens(
        snapshot, previousCredential,
        previousMetadata)) {
      return false;
    }
    let pending: string[] =
      this.pendingCleanupUnionIDs.slice();
    if (previousMetadata !== null &&
      (nextMetadata === null ||
        previousMetadata.unionID !==
          nextMetadata.unionID)) {
      this.addPendingCleanup(
        pending, previousMetadata.unionID);
    }
    if (nextMetadata !== null) {
      pending = this.withoutUnionID(
        pending, nextMetadata.unionID);
    }
    if (!(await this.writePreferenceState(
      nextMetadata, pending))) {
      if (snapshot !== null) {
        this.restoreTargetTokens(
          snapshot.unionID, previousCredential,
          previousMetadata);
      }
      return false;
    }
    this.persistedMetadata = nextMetadata;
    this.pendingCleanupUnionIDs = pending;
    return await this.drainPendingCleanup(
      nextMetadata?.unionID ?? '');
  }

  private async saveToDisk(
    previousCredential: StoredCredential | null
  ): Promise<boolean> {
    const snapshot: StoredCredential | null =
      this.credential === null
        ? null : this.cloneCredential(this.credential);
    let succeeded: boolean = false;
    const previous: Promise<void> =
      this.persistenceTail;
    const write: Promise<void> =
      previous.catch((_error: Error): void => {})
        .then(async (): Promise<void> => {
          succeeded = await this.persistSnapshot(
            snapshot, previousCredential);
        });
    this.persistenceTail =
      write.catch((_error: Error): void => {});
    await write;
    return succeeded;
  }

  async saveCredential(
    cred: CredentialParams
  ): Promise<boolean> {
    const unionID: string = cred.unionID.trim();
    if (unionID.length === 0 ||
      this.dataPreferences === null) {
      return false;
    }
    const previous: StoredCredential | null =
      this.credential === null
        ? null : this.cloneCredential(this.credential);
    const previousRevision: number =
      this.credentialRevision;
    this.credential = {
      unionID,
      openID: cred.openID,
      authorizationCode: cred.authorizationCode,
      idToken: cred.idToken,
      accessToken: '',
      refreshToken: '',
      tokenExpiresAt: 0,
      displayName: cred.displayName || '',
      loginTime: Date.now()
    };
    this.credentialRevision++;
    if (await this.saveToDisk(previous)) { return true; }
    this.credential = previous;
    this.credentialRevision =
      previousRevision + 2;
    return false;
  }

  async clearCredential(): Promise<boolean> {
    const previous: StoredCredential | null =
      this.credential === null
        ? null : this.cloneCredential(this.credential);
    const previousRevision: number =
      this.credentialRevision;
    this.credential = null;
    this.credentialRevision++;
    if (await this.saveToDisk(previous)) { return true; }
    this.credential = previous;
    this.credentialRevision =
      previousRevision + 2;
    return false;
  }

  isAuthorized(): boolean {
    return this.credential !== null &&
      this.credential.unionID !== '';
  }

  credentialSnapshot(): StoredCredential | null {
    return this.credential === null
      ? null : this.cloneCredential(this.credential);
  }

  async restoreCredentialSnapshot(
    snapshot: StoredCredential | null
  ): Promise<boolean> {
    if (this.dataPreferences === null) { return false; }
    const previous: StoredCredential | null =
      this.credential === null
        ? null : this.cloneCredential(this.credential);
    const previousRevision: number =
      this.credentialRevision;
    this.credential = snapshot === null
      ? null : this.cloneCredential(snapshot);
    this.credentialRevision++;
    if (await this.saveToDisk(previous)) { return true; }
    this.credential = previous;
    this.credentialRevision =
      previousRevision + 2;
    return false;
  }

  private cloneCredential(
    source: StoredCredential
  ): StoredCredential {
    return {
      unionID: source.unionID,
      openID: source.openID,
      authorizationCode: source.authorizationCode,
      idToken: source.idToken,
      accessToken: source.accessToken,
      refreshToken: source.refreshToken,
      tokenExpiresAt: source.tokenExpiresAt,
      displayName: source.displayName,
      loginTime: source.loginTime
    };
  }

  getAuthorizationCode(): string {
    return this.credential?.authorizationCode || '';
  }

  getUnionID(): string {
    return this.credential?.unionID || '';
  }

  getOpenID(): string {
    return this.credential?.openID || '';
  }

  getIdToken(): string {
    return this.credential?.idToken || '';
  }

  getDisplayName(): string {
    return this.credential?.displayName || '';
  }

  getLoginTime(): number {
    return this.credential?.loginTime || 0;
  }

  getAuthHeaders(): Record<string, string> {
    const bearer: string =
      this.getAccessToken() || this.getIdToken();
    const headers: Record<string, string> = {
      'X-Union-ID': this.getUnionID(),
      'X-Open-ID': this.getOpenID(),
      'Content-Type': 'application/json'
    };
    if (bearer.length > 0) {
      headers['Authorization'] = 'Bearer ' + bearer;
    } else {
      hilog.warn(DOMAIN, TAG,
        '[getAuthHeaders] 无可用 Bearer Token');
    }
    return headers;
  }

  getAccessToken(): string {
    return this.credential?.accessToken || '';
  }

  /**
   * This legacy exchange entry remains for compatibility. Client secrets must
   * be provisioned by a trusted backend; no token or response body is logged.
   */
  async exchangeAuthCode(
    clientId: string,
    clientSecret: string
  ): Promise<string | undefined> {
    const authCode: string =
      this.getAuthorizationCode();
    const unionID: string = this.getUnionID();
    const operationRevision: number =
      this.credentialRevision;
    if (!authCode) {
      hilog.error(DOMAIN, TAG,
        '[exchangeAuthCode] 无可用 Authorization Code');
      return undefined;
    }
    try {
      const body: string =
        'grant_type=authorization_code&code=' +
        encodeURIComponent(authCode) +
        '&client_id=' + encodeURIComponent(clientId) +
        '&client_secret=' +
        encodeURIComponent(clientSecret);
      const req = http.createHttp();
      const resp = await req.request(
        AGC_TOKEN_ENDPOINT, {
          method: http.RequestMethod.POST,
          header: {
            'Content-Type':
              'application/x-www-form-urlencoded'
          },
          extraData: body,
          connectTimeout: 10000,
          readTimeout: 10000
        });
      if (resp.responseCode !== 200) {
        hilog.error(DOMAIN, TAG,
          '[exchangeAuthCode] Token 换取失败 HTTP=' +
          resp.responseCode.toString());
        return undefined;
      }
      if (operationRevision !== this.credentialRevision ||
        this.credential === null ||
        this.credential.unionID !== unionID ||
        this.credential.authorizationCode !== authCode) {
        hilog.warn(DOMAIN, TAG,
          '[exchangeAuthCode] 账号已切换，丢弃旧网络结果');
        return undefined;
      }
      const data: Record<string, Object> =
        JSON.parse(resp.result as string) as
        Record<string, Object>;
      const accessToken: string =
        typeof data['access_token'] === 'string'
          ? data['access_token'] as string : '';
      const refreshToken: string =
        typeof data['refresh_token'] === 'string'
          ? data['refresh_token'] as string : '';
      const expiresIn: number =
        typeof data['expires_in'] === 'number' &&
        Number.isFinite(data['expires_in'] as number)
          ? data['expires_in'] as number : 3600;
      if (accessToken.length === 0 ||
        !accountCredentialSecretFitsAssetStore(accessToken) ||
        !accountCredentialSecretFitsAssetStore(refreshToken)) {
        hilog.error(DOMAIN, TAG,
          '[exchangeAuthCode] Token 超出安全存储边界');
        return undefined;
      }
      const previous: StoredCredential =
        this.cloneCredential(this.credential);
      previous.authorizationCode = '';
      this.credential.authorizationCode = '';
      this.credential.accessToken = accessToken;
      this.credential.refreshToken = refreshToken;
      this.credential.tokenExpiresAt =
        Date.now() + Math.max(1, expiresIn) * 1000;
      this.credentialRevision++;
      if (!(await this.saveToDisk(previous))) {
        this.credential = previous;
        this.credentialRevision++;
        return undefined;
      }
      hilog.info(DOMAIN, TAG,
        '[exchangeAuthCode] Access Token 换取成功');
      return accessToken;
    } catch (err) {
      hilog.error(DOMAIN, TAG,
        '[exchangeAuthCode] 请求失败: ' +
        safeError(err));
      return undefined;
    }
  }

  isExpired(): boolean {
    if (!this.credential ||
      this.credential.loginTime === 0) {
      return true;
    }
    if (this.credential.accessToken &&
      this.credential.tokenExpiresAt > 0) {
      return Date.now() >
        this.credential.tokenExpiresAt;
    }
    return Date.now() -
      this.credential.loginTime >
      60 * 60 * 1000;
  }
}
