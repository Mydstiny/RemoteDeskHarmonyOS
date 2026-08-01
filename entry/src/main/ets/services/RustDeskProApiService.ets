import { http } from '@kit.NetworkKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { RustDeskProAccountState, RustDeskProAddressBook } from '../model/RustDeskProModels';
import { CURRENT_RELEASE_VERSION } from './ReleaseNotesRegistry';
import { rustDeskRelayIdFingerprint } from './RustDeskRelaySavePolicy';
import {
  buildRustDeskProLoginRequest,
  buildRustDeskProMinimalLoginRequest,
  normalizeRustDeskProServerUrl,
  parseRustDeskProAddressBookPage,
  parseRustDeskProAddressBookResponse,
  parseRustDeskProLoginResponse,
  parseRustDeskProPersonalAddressBookResponse,
  parseRustDeskProSharedAddressBookProfiles,
  rustDeskProApiRouteId,
  RustDeskProApiError,
  RustDeskProLoginResult
} from './RustDeskProApiPolicy';

const HTTP_TIMEOUT_MS: number = 15000;
const APP_VERSION: string = CURRENT_RELEASE_VERSION;
const LOG_DOMAIN: number = 0x0001;
const LOG_TAG: string = 'RustDeskProApi';

interface RustDeskProHttpResponse {
  status: number
  payload: Object
}

interface RustDeskProLogoutRequest {
  id: string
  uuid: string
}

interface RustDeskProErrorPayload {
  error: string
}

/**
 * 从服务器拒绝响应中提取可诊断的 error/message 文本（脱敏、截断）。
 * 只保留错误说明，不记录 URL、query、GUID、token、账号或完整响应体。
 */
function extractServerRejectionReason(raw: string): string {
  let value = raw.replace(/\s+/g, ' ').trim();
  try {
    const obj = JSON.parse(raw) as Record<string, Object>;
    const keys: string[] = ['error', 'message', 'detail', 'reason', 'msg'];
    for (let i = 0; i < keys.length; i++) {
      const v: Object | undefined = obj[keys[i]];
      if (typeof v === 'string' && (v as string).length > 0) {
        value = v as string;
        break;
      }
    }
  } catch (_err) {
    // 非 JSON：保留纯文本开头。
  }
  value = value
    .replace(/("(?:access_token|token|password|secret|authorization)"\s*:\s*")[^"]+(")/gi, '$1<redacted>$2')
    .replace(/(token|password|secret|authorization)\s*[=:]\s*[\w.\-]+/gi, '$1=<redacted>');
  if (value.length > 200) { value = value.substring(0, 200) + '…'; }
  return value;
}

export class RustDeskProApiService {
  private static instance: RustDeskProApiService;

  static getInstance(): RustDeskProApiService {
    if (!RustDeskProApiService.instance) {
      RustDeskProApiService.instance = new RustDeskProApiService();
    }
    return RustDeskProApiService.instance;
  }

  private async request(account: RustDeskProAccountState, path: string, method: http.RequestMethod,
    body: Object | null): Promise<RustDeskProHttpResponse> {
    const client: http.HttpRequest = http.createHttp();
    try {
      const url = normalizeRustDeskProServerUrl(account.serverUrl) + path;
      const headers: Record<string, string> = { 'Content-Type': 'application/json', 'Accept': 'application/json' };
      if (account.accessToken.length > 0) { headers['Authorization'] = 'Bearer ' + account.accessToken; }
      const options: http.HttpRequestOptions = {
        method,
        header: headers,
        expectDataType: http.HttpDataType.STRING,
        usingCache: false,
        connectTimeout: HTTP_TIMEOUT_MS,
        readTimeout: HTTP_TIMEOUT_MS
      };
      if (body !== null) {
        options.extraData = JSON.stringify(body);
      } else {
        // Match the official RustDesk client for empty POST requests.
        headers['Content-Length'] = '0';
      }
      const endpointId: string =
        rustDeskRelayIdFingerprint(
          normalizeRustDeskProServerUrl(
            account.serverUrl));
      const routeId: string = rustDeskProApiRouteId(path);
      hilog.info(LOG_DOMAIN, LOG_TAG,
        'request method=' + method.toString() +
        ' route=' + routeId + ' endpointId=' +
        endpointId + ' token=' +
        (account.accessToken.length > 0
          ? 'present' : 'absent'));
      let response: http.HttpResponse;
      try {
        response = await client.request(url, options);
      } catch (_err) {
        throw new RustDeskProApiError(
          'network_error',
          'Pro API 网络请求失败（请求 ' + routeId +
          '，端点编号 ' + endpointId + '）');
      }
      const rawResult: Object = response.result as Object;
      let responseBytes: number = 0;
      if (typeof rawResult === 'string') {
        responseBytes = (rawResult as string).length;
      } else {
        try {
          const serialized: string =
            JSON.stringify(rawResult);
          responseBytes = serialized.length;
        } catch (_err) {
          responseBytes = 0;
        }
      }
      hilog.info(LOG_DOMAIN, LOG_TAG, 'response status=' + response.responseCode.toString() +
        ' resultType=' + response.resultType.toString() +
        ' bytes=' + responseBytes.toString() +
        ' route=' + routeId +
        ' endpointId=' + endpointId);
      if (response.responseCode >= 400 &&
        typeof rawResult === 'string' &&
        (rawResult as string).length > 0) {
        hilog.warn(LOG_DOMAIN, LOG_TAG,
          'server rejected route=' + routeId +
          ' status=' + response.responseCode.toString() +
          ' reason=' + extractServerRejectionReason(rawResult as string));
      }
      let payload: Object = JSON.parse('{}') as Object;
      if (typeof response.result === 'string' && (response.result as string).length > 0) {
        try { payload = JSON.parse(response.result as string) as Object; } catch (_err) {
          // Some compatible servers return a plain-text body for 404/405. Keep
          // the status so the caller can select a legacy endpoint or report the
          // actual HTTP failure; successful responses must remain strict JSON.
          if (response.responseCode >= 200 && response.responseCode < 300) {
            throw new RustDeskProApiError('invalid_response',
              'Pro 服务器返回了无效 JSON（HTTP ' +
              response.responseCode.toString() + '，请求 ' +
              routeId + '）',
              response.responseCode as number);
          }
          const errorPayload: RustDeskProErrorPayload = {
            error: 'remote_rejected'
          };
          payload = errorPayload as Object;
        }
      } else if (response.result && typeof response.result === 'object') {
        payload = response.result as Object;
      }
      if (response.responseCode < 200 ||
        response.responseCode >= 300) {
        const reason: string =
          typeof rawResult === 'string' && (rawResult as string).length > 0
            ? extractServerRejectionReason(rawResult as string)
            : 'remote_rejected';
        const errorPayload: RustDeskProErrorPayload = {
          error: reason
        };
        payload = errorPayload as Object;
      }
      return { status: response.responseCode as number, payload };
    } finally {
      client.destroy();
    }
  }

  async login(account: RustDeskProAccountState, username: string, password: string): Promise<RustDeskProLoginResult> {
    const body = buildRustDeskProLoginRequest(username, password, account.deviceId, account.deviceUuid, APP_VERSION);
    const attempt = async (payload: Object): Promise<RustDeskProLoginResult> => {
      const response: RustDeskProHttpResponse =
        await this.request(account, '/api/login', http.RequestMethod.POST, payload);
      return parseRustDeskProLoginResponse(response.payload, response.status);
    };
    try {
      return await attempt(body as Object);
    } catch (err) {
      // Deterministic compatibility fallback: only when the server actively
      // rejects the extended device-registration payload with HTTP 400.
      // Retry once with the official minimal username/password login body.
      // Any other failure propagates unchanged.
      const apiError: RustDeskProApiError =
        err instanceof RustDeskProApiError ? err : new RustDeskProApiError('login_failed', 'Pro 登录失败');
      if (apiError.code !== 'http_error' || apiError.status !== 400) {
        throw apiError;
      }
      const minimalBody = buildRustDeskProMinimalLoginRequest(username, password);
      return await attempt(minimalBody);
    }
  }

  async getAddressBook(account: RustDeskProAccountState): Promise<RustDeskProAddressBook> {
    if (account.accessToken.length === 0) {
      throw new RustDeskProApiError('not_logged_in', 'Pro 账号尚未登录');
    }
    // Current RustDesk servers expose the personal address book and peers as
    // separate paginated endpoints. Older deployments use the legacy /api/ab/get
    // payload. Some hosted panels reject the modern endpoint shape with 400/405
    // instead of 404; treat those the same as "not supported" and fall back to
    // the legacy payload. 401/403 and transport failures stay authoritative.
    const personal: RustDeskProHttpResponse =
      await this.request(account, '/api/ab/personal', http.RequestMethod.POST, null);
    const personalGuid: string =
      personal.status === 400 || personal.status === 404 || personal.status === 405
        ? '' : parseRustDeskProPersonalAddressBookResponse(personal.payload, personal.status);
    if (personalGuid.length === 0) {
      const legacy = await this.request(account, '/api/ab/get', http.RequestMethod.POST,
        JSON.parse('{}') as Object);
      return parseRustDeskProAddressBookResponse(legacy.payload, legacy.status);
    }

    const result = new RustDeskProAddressBook();
    const addressBookGuids: string[] = [personalGuid];
    let sharedPage = 1;
    const sharedPageSize = 100;
    let sharedTotal = 0;
    do {
      const profilesPath = '/api/ab/shared/profiles?current=' + sharedPage.toString() +
        '&pageSize=' + sharedPageSize.toString();
      const profilesResponse = await this.request(account, profilesPath, http.RequestMethod.POST, null);
      const profiles = parseRustDeskProSharedAddressBookProfiles(profilesResponse.payload, profilesResponse.status);
      for (const guid of profiles) {
        if (addressBookGuids.indexOf(guid) < 0) { addressBookGuids.push(guid); }
      }
      const profilesRoot = profilesResponse.payload as Record<string, Object>;
      const rawTotal: Object | undefined = profilesRoot['total'];
      sharedTotal = typeof rawTotal === 'number' ? rawTotal as number : 0;
      sharedPage += 1;
    } while (sharedTotal > 0 && (sharedPage - 1) * sharedPageSize < sharedTotal);

    const pageSize = 100;
    for (const addressBookGuid of addressBookGuids) {
      let page = 1;
      let total = 0;
      do {
        const path = '/api/ab/peers?current=' + page.toString() + '&pageSize=' + pageSize.toString() +
          '&ab=' + encodeURIComponent(addressBookGuid);
        const response = await this.request(account, path, http.RequestMethod.POST, null);
        const parsed = parseRustDeskProAddressBookPage(response.payload, response.status);
        total = parsed.total;
        for (const peer of parsed.addressBook.peers) {
          if (result.peers.every((existing) => existing.id !== peer.id)) { result.peers.push(peer); }
        }
        for (const tag of parsed.addressBook.tags) {
          if (result.tags.indexOf(tag) < 0) { result.tags.push(tag); }
        }
        page += 1;
      } while (total > 0 && (page - 1) * pageSize < total);
    }
    // Some compatible servers expose an older cached address book alongside
    // the modern personal/shared APIs. Use it only when the modern result is
    // empty; this also covers migrations where desktop clients still show the
    // legacy list.
    if (result.peers.length === 0) {
      const legacyResponse = await this.request(account, '/api/ab', http.RequestMethod.GET, null);
      if (legacyResponse.status === 200) {
        const legacy = parseRustDeskProAddressBookResponse(legacyResponse.payload, legacyResponse.status);
        for (const peer of legacy.peers) {
          if (result.peers.every((existing) => existing.id !== peer.id)) { result.peers.push(peer); }
        }
        for (const tag of legacy.tags) {
          if (result.tags.indexOf(tag) < 0) { result.tags.push(tag); }
        }
      }
    }
    result.updatedAt = Date.now();
    return result;
  }

  async logout(account: RustDeskProAccountState): Promise<void> {
    if (account.accessToken.length === 0) { return; }
    try {
      const body: RustDeskProLogoutRequest = {
        id: account.deviceId,
        uuid: account.deviceUuid
      };
      await this.request(account, '/api/logout', http.RequestMethod.POST, body);
    } catch (_err) {
      // Logout is best effort; local token is cleared by the caller regardless.
    }
  }
}
