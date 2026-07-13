/**
 * CloudSyncService.ets — 华为云 REST API 同步服务
 *
 * 通过 @kit.NetworkKit HTTP 将主机/SSH密钥/TOTP条目同步到自定义服务端。
 * 依赖 AccountKitService 获取 Authorization Header 进行身份验证。
 *
 * 同步策略: 应用启动时拉取 (restore), 本地变更后推送 (sync).
 */
import { http } from '@kit.NetworkKit';
import { AccountKitService } from './AccountKitService';
import { RemoteHost } from '../model/RemoteHost';
import { SshKey } from '../model/SshKey';
import { TotpEntry } from '../model/TotpEntry';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG = 'CloudSyncService';
const DOMAIN = 0x0014;
const DEFAULT_BASE_URL = 'https://api.remotedesktop.app/v1';
const HTTP_TIMEOUT_MS: number = 15000;

export class CloudSyncService {
  private static instance: CloudSyncService;
  private unionID: string = '';
  private serverBaseUrl: string = '';
  private httpClient: http.HttpRequest | null = null;

  static getInstance(): CloudSyncService {
    if (!CloudSyncService.instance) {
      CloudSyncService.instance = new CloudSyncService();
    }
    return CloudSyncService.instance;
  }

  private getClient(): http.HttpRequest {
    if (!this.httpClient) {
      this.httpClient = http.createHttp();
    }
    return this.httpClient;
  }

  setUnionID(id: string): void {
    this.unionID = id;
  }

  setServerUrl(url: string): void {
    this.serverBaseUrl = url;
  }

  private getServerUrl(): string {
    return this.serverBaseUrl !== '' ? this.serverBaseUrl : DEFAULT_BASE_URL;
  }

  private getHeaders(): Record<string, string> {
    const headers: Record<string, string> = {
      'Content-Type': 'application/json'
    };
    const akHeaders = AccountKitService.getInstance().getAuthHeaders();
    const keys: string[] = Object.keys(akHeaders);
    for (let i = 0; i < keys.length; i++) {
      headers[keys[i]] = akHeaders[keys[i]];
    }
    return headers;
  }

  private async post(path: string, body: Object): Promise<Object | null> {
    try {
      const client = this.getClient();
      const url = this.getServerUrl() + path;
      const response = await client.request(url, {
        method: http.RequestMethod.POST,
        header: this.getHeaders(),
        extraData: JSON.stringify(body),
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: HTTP_TIMEOUT_MS,
        readTimeout: HTTP_TIMEOUT_MS
      });
      if (response.responseCode === 200 || response.responseCode === 201) {
        return JSON.parse(response.result as string) as Object;
      }
      hilog.warn(DOMAIN, TAG, "POST " + path + " HTTP " + response.responseCode.toString());
      return null;
    } catch (err) {
      hilog.error(DOMAIN, TAG, "POST " + path + " 失败: " + JSON.stringify(err));
      return null;
    }
  }

  private async get(path: string): Promise<Object | null> {
    try {
      const client = this.getClient();
      const url = this.getServerUrl() + path;
      const response = await client.request(url, {
        method: http.RequestMethod.GET,
        header: this.getHeaders(),
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: HTTP_TIMEOUT_MS,
        readTimeout: HTTP_TIMEOUT_MS
      });
      if (response.responseCode === 200) {
        return JSON.parse(response.result as string) as Object;
      }
      hilog.warn(DOMAIN, TAG, "GET " + path + " HTTP " + response.responseCode.toString());
      return null;
    } catch (err) {
      hilog.error(DOMAIN, TAG, "GET " + path + " 失败: " + JSON.stringify(err));
      return null;
    }
  }

  private isReady(): boolean {
    return this.unionID !== '';
  }

  // ==================== 主机同步 ====================

  async syncHosts(hosts: RemoteHost[]): Promise<void> {
    if (!this.isReady()) { return; }
    const body = { unionID: this.unionID, hosts: hosts.map((h: RemoteHost) => h.toJSON()) };
    const result = await this.post('/hosts', body);
    if (result) {
      hilog.info(DOMAIN, TAG, "同步 " + hosts.length.toString() + " 个主机到云端");
    }
  }

  async restoreHosts(): Promise<RemoteHost[]> {
    if (!this.isReady()) { return []; }
    const result = await this.get('/hosts?unionID=' + encodeURIComponent(this.unionID));
    if (!result) { return []; }
    try {
      const data = result as Record<string, Object>;
      const hostArray = data['hosts'] as Record<string, Object>[];
      if (!hostArray) { return []; }
      return hostArray.map((h: Record<string, Object>) => RemoteHost.fromJSON(h));
    } catch (err) {
      hilog.error(DOMAIN, TAG, "restoreHosts 解析失败: " + JSON.stringify(err));
      return [];
    }
  }

  // ==================== 密钥同步 ====================

  async syncKeys(keys: SshKey[]): Promise<void> {
    if (!this.isReady()) { return; }
    const body = { unionID: this.unionID, keys: keys.map((k: SshKey) => k.toJSON()) };
    const result = await this.post('/keys', body);
    if (result) {
      hilog.info(DOMAIN, TAG, "同步 " + keys.length.toString() + " 个密钥到云端");
    }
  }

  async restoreKeys(): Promise<SshKey[]> {
    if (!this.isReady()) { return []; }
    const result = await this.get('/keys?unionID=' + encodeURIComponent(this.unionID));
    if (!result) { return []; }
    try {
      const data = result as Record<string, Object>;
      const keyArray = data['keys'] as Record<string, Object>[];
      if (!keyArray) { return []; }
      return keyArray.map((k: Record<string, Object>) => SshKey.fromJSON(k));
    } catch (err) {
      hilog.error(DOMAIN, TAG, "restoreKeys 解析失败: " + JSON.stringify(err));
      return [];
    }
  }

  // ==================== TOTP 同步 ====================

  async syncTotpEntries(entries: TotpEntry[]): Promise<void> {
    if (!this.isReady()) { return; }
    const body = { unionID: this.unionID, entries: entries.map((e: TotpEntry) => e.toJSON()) };
    const result = await this.post('/totp', body);
    if (result) {
      hilog.info(DOMAIN, TAG, "同步 " + entries.length.toString() + " 个 TOTP 条目到云端");
    }
  }

  async restoreTotpEntries(): Promise<TotpEntry[]> {
    if (!this.isReady()) { return []; }
    const result = await this.get('/totp?unionID=' + encodeURIComponent(this.unionID));
    if (!result) { return []; }
    try {
      const data = result as Record<string, Object>;
      const entryArray = data['entries'] as Record<string, Object>[];
      if (!entryArray) { return []; }
      return entryArray.map((e: Record<string, Object>) => TotpEntry.fromJSON(e));
    } catch (err) {
      hilog.error(DOMAIN, TAG, "restoreTotpEntries 解析失败: " + JSON.stringify(err));
      return [];
    }
  }
}
