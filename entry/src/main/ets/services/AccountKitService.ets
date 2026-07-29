/**
 * AccountKitService.ets — 华为账号凭据管理服务 (Preferences 持久化)
 *
 * 与现有 AuthService (内存会话) 并行工作, 负责:
 * 1. 持久化存储 unionID / openID / authorizationCode / idToken
 * 2. Token 生命周期管理 (过期判断 / 刷新)
 * 3. 生成服务端 API 调用的 Authorization Header
 *
 * 安全说明: OAuth 令牌通过 Preferences API 存储在应用沙箱内。
 * HarmonyOS 应用沙箱提供文件级隔离保护。如需硬件级保护,
 * 后续版本可使用 HUKS KeyStorage 加密存储。
 *
 * 用法:
 *   const aks = AccountKitService.getInstance();
 *   await aks.init(context);
 *   aks.saveCredential({ unionID, openID, authorizationCode, idToken });
 *   const headers = aks.getAuthHeaders();
 */
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { http } from '@kit.NetworkKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG = 'AccountKit';
const DOMAIN = 0x0013;
const STORE_NAME: string = 'AccountKitCreds';
const KEY_CREDENTIAL: string = 'credential_json';

/** AGC OAuth Token 端点 (用于 Authorization Code 换取 Access Token) */
const AGC_TOKEN_ENDPOINT = 'https://oauth-login.cloud.huawei.com/oauth2/v3/token';

/** 持久化的凭据数据结构 */
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

/** 登录凭据参数 */
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
  private initPromise: Promise<boolean> | null = null;
  private credentialRevision: number = 0;
  private persistenceTail: Promise<void> = Promise.resolve();

  static getInstance(): AccountKitService {
    if (!AccountKitService.instance) {
      AccountKitService.instance = new AccountKitService();
    }
    return AccountKitService.instance;
  }

  /** 初始化持久化存储, 从磁盘恢复 */
  async init(context: common.Context): Promise<boolean> {
    if (this.dataPreferences !== null) { return true; }
    if (this.initPromise !== null) { return await this.initPromise; }
    this.initPromise = this.initializePreferences(context);
    const initialized: boolean = await this.initPromise;
    if (!initialized) { this.initPromise = null; }
    return initialized;
  }

  private async initializePreferences(context: common.Context): Promise<boolean> {
    try {
      this.dataPreferences = preferences.getPreferencesSync(context, { name: STORE_NAME });
      await this.loadFromDisk();
      return true;
    } catch (err) {
      hilog.error(0x0015, 'AccountKit', 'AccountKitService 初始化失败: ' + JSON.stringify(err));
      this.dataPreferences = null;
      return false;
    }
  }

  /** 从 Preferences 加载凭据 */
  private async loadFromDisk(): Promise<void> {
    if (!this.dataPreferences) { return; }
    try {
      const raw: string = this.dataPreferences.getSync(KEY_CREDENTIAL, '') as string;
      if (raw !== '') {
        const parsed: StoredCredential = JSON.parse(raw) as StoredCredential;
        this.credential = parsed && typeof parsed.unionID === 'string' &&
          parsed.unionID.trim().length > 0 ? parsed : null;
      }
      this.credentialRevision++;
    } catch (err) {
      hilog.error(0x0015, 'AccountKit', 'AccountKitService 加载凭据失败: ' + JSON.stringify(err));
      this.credential = null;
    }
  }

  /** 持久化到 Preferences */
  private async saveToDisk(): Promise<boolean> {
    if (!this.dataPreferences) { return false; }
    const snapshot: StoredCredential | null = this.credential === null
      ? null : this.cloneCredential(this.credential);
    let succeeded: boolean = false;
    const previous: Promise<void> = this.persistenceTail;
    const write: Promise<void> = previous.catch((_error: Error): void => {})
      .then(async (): Promise<void> => {
        try {
          if (snapshot !== null) {
            this.dataPreferences?.putSync(
              KEY_CREDENTIAL, JSON.stringify(snapshot));
          } else {
            this.dataPreferences?.deleteSync(KEY_CREDENTIAL);
          }
          await this.dataPreferences?.flush();
          succeeded = true;
        } catch (err) {
          hilog.error(0x0015, 'AccountKit',
            'AccountKitService 保存凭据失败: ' + JSON.stringify(err));
        }
      });
    this.persistenceTail = write.catch((_error: Error): void => {});
    await write;
    return succeeded;
  }

  /**
   * 保存登录凭据 (LoginPage 成功后调用)
   */
  async saveCredential(cred: CredentialParams): Promise<boolean> {
    const unionID: string = cred.unionID.trim();
    if (unionID.length === 0 || this.dataPreferences === null) { return false; }
    const previous: StoredCredential | null = this.credential;
    const previousRevision: number = this.credentialRevision;
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
    if (await this.saveToDisk()) { return true; }
    this.credential = previous;
    this.credentialRevision = previousRevision + 2;
    return false;
  }

  /** 清除凭据 (退出登录) */
  async clearCredential(): Promise<boolean> {
    const previous: StoredCredential | null = this.credential;
    const previousRevision: number = this.credentialRevision;
    this.credential = null;
    this.credentialRevision++;
    if (await this.saveToDisk()) { return true; }
    this.credential = previous;
    this.credentialRevision = previousRevision + 2;
    return false;
  }

  /** 是否有有效凭据 */
  isAuthorized(): boolean {
    return this.credential !== null && this.credential.unionID !== '';
  }

  /** In-memory transaction snapshot used only by AccountSessionCoordinator. */
  credentialSnapshot(): StoredCredential | null {
    return this.credential === null ? null : this.cloneCredential(this.credential);
  }

  /** Restore the exact previous durable credential after a failed scope commit. */
  async restoreCredentialSnapshot(snapshot: StoredCredential | null): Promise<boolean> {
    if (this.dataPreferences === null) { return false; }
    const previous: StoredCredential | null = this.credential;
    const previousRevision: number = this.credentialRevision;
    this.credential = snapshot === null ? null : this.cloneCredential(snapshot);
    this.credentialRevision++;
    if (await this.saveToDisk()) { return true; }
    this.credential = previous;
    this.credentialRevision = previousRevision + 2;
    return false;
  }

  private cloneCredential(source: StoredCredential): StoredCredential {
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

  /** 获取 Authorization Code (5分钟有效, 一次性使用) */
  getAuthorizationCode(): string {
    return this.credential?.authorizationCode || '';
  }

  /** 获取 UnionID */
  getUnionID(): string {
    return this.credential?.unionID || '';
  }

  /** 获取 OpenID */
  getOpenID(): string {
    return this.credential?.openID || '';
  }

  /** 获取 ID Token (JWT) */
  getIdToken(): string {
    return this.credential?.idToken || '';
  }

  /** 获取显示名称 */
  getDisplayName(): string {
    return this.credential?.displayName || '';
  }

  /** 登录时间戳 */
  getLoginTime(): number {
    return this.credential?.loginTime || 0;
  }

  /**
   * 生成服务端 API 请求头
   * 优先使用 Access Token (通过 exchangeAuthCode 换取);
   * 如果尚未换取, 使用 ID Token (JWT) 作为 Bearer Token。
   *
   * ⚠️ Authorization Code 是一次性临时凭证，不能直接作为 Bearer Token
   *    必须通过 OAuth 2.0 Token Endpoint 换取 Access Token 后才可使用
   */
  getAuthHeaders(): Record<string, string> {
    // 优先使用已换取的 Access Token
    const bearer = this.getAccessToken() || this.getIdToken();
    if (!bearer) {
      hilog.warn(DOMAIN, TAG, '[getAuthHeaders] 无可用的 Bearer Token, 请先调用 exchangeAuthCode');
    }
    return {
      'Authorization': "Bearer " + bearer,
      'X-Union-ID': this.getUnionID(),
      'X-Open-ID': this.getOpenID(),
      'Content-Type': 'application/json'
    };
  }

  /** 获取长期 Access Token (通过 exchangeAuthCode 换取) */
  getAccessToken(): string {
    return this.credential?.accessToken || '';
  }

  /**
   * 使用 Authorization Code 换取 Access Token (OAuth 2.0 Token Exchange)
   * 调用华为 AGC OAuth Token Endpoint
   *
   * @param clientId AGC OAuth 2.0 client_id
   * @param clientSecret AGC OAuth 2.0 client_secret
   * @returns Access Token 字符串, 失败时返回 undefined
   */
  async exchangeAuthCode(clientId: string, clientSecret: string): Promise<string | undefined> {
    const authCode = this.getAuthorizationCode();
    const unionId: string = this.getUnionID();
    const operationRevision: number = this.credentialRevision;
    if (!authCode) {
      hilog.error(DOMAIN, TAG, '[exchangeAuthCode] 无可用的 Authorization Code');
      return undefined;
    }

    try {
      const body = "grant_type=authorization_code&code=" + encodeURIComponent(authCode) +
        "&client_id=" + encodeURIComponent(clientId) +
        "&client_secret=" + encodeURIComponent(clientSecret);

      const req = http.createHttp();
      const resp = await req.request(AGC_TOKEN_ENDPOINT, {
        method: http.RequestMethod.POST,
        header: { 'Content-Type': 'application/x-www-form-urlencoded' },
        extraData: body,
        connectTimeout: 10000,
        readTimeout: 10000
      });

      if (resp.responseCode === 200) {
        if (operationRevision !== this.credentialRevision ||
          this.credential === null ||
          this.credential.unionID !== unionId ||
          this.credential.authorizationCode !== authCode) {
          hilog.warn(DOMAIN, TAG,
            '[exchangeAuthCode] 账号已切换，丢弃旧凭据网络结果');
          return undefined;
        }
        const data: Record<string, Object> = JSON.parse(resp.result as string) as Record<string, Object>;
        const accessToken = data['access_token'] as string;
        const refreshToken = data['refresh_token'] as string;
        const expiresIn = data['expires_in'] as number;

        if (this.credential) {
          const previous: StoredCredential =
            this.cloneCredential(this.credential);
          this.credential.accessToken = accessToken;
          this.credential.refreshToken = refreshToken;
          this.credential.tokenExpiresAt = Date.now() + (expiresIn || 3600) * 1000;
          this.credentialRevision++;
          if (!(await this.saveToDisk())) {
            this.credential = previous;
            this.credentialRevision++;
            return undefined;
          }
        }

        hilog.info(DOMAIN, TAG, "[exchangeAuthCode] Access Token 换取成功, expires_in=" + expiresIn.toString());
        return accessToken;
      } else {
        hilog.error(DOMAIN, TAG,
          "[exchangeAuthCode] Token 换取失败 HTTP=" + resp.responseCode.toString() + " body=" + resp.result);
        return undefined;
      }
    } catch (err) {
      hilog.error(DOMAIN, TAG,
        "[exchangeAuthCode] 网络请求失败: " + JSON.stringify(err));
      return undefined;
    }
  }

  /**
   * 判断凭据是否过期
   * Access Token 过期后进行判断; ID Token 通常有效期为 1 小时
   */
  isExpired(): boolean {
    if (!this.credential || this.credential.loginTime === 0) { return true; }
    // 如果有 Access Token, 按 tokenExpiresAt 判断
    if (this.credential.accessToken && this.credential.tokenExpiresAt > 0) {
      return Date.now() > this.credential.tokenExpiresAt;
    }
    // 否则按 ID Token 典型有效期 (1小时) 判断
    const elapsed: number = Date.now() - this.credential.loginTime;
    return elapsed > 60 * 60 * 1000; // 1 hour
  }
}
