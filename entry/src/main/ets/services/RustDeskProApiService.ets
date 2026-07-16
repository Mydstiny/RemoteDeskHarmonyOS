import { http } from '@kit.NetworkKit';
import { RustDeskProAccountState, RustDeskProAddressBook } from '../model/RustDeskProModels';
import {
  buildRustDeskProLoginRequest,
  normalizeRustDeskProServerUrl,
  parseRustDeskProAddressBookResponse,
  parseRustDeskProLoginResponse,
  RustDeskProApiError,
  RustDeskProLoginResult
} from './RustDeskProApiPolicy';

const HTTP_TIMEOUT_MS: number = 15000;
const APP_VERSION: string = '1.0.7';

interface RustDeskProHttpResponse {
  status: number
  payload: Object
}

interface RustDeskProLogoutRequest {
  id: string
  uuid: string
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
      const headers: Record<string, string> = { 'Content-Type': 'application/json', 'Accept': 'application/json' };
      if (account.accessToken.length > 0) { headers['Authorization'] = 'Bearer ' + account.accessToken; }
      const options: http.HttpRequestOptions = {
        method,
        header: headers,
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: HTTP_TIMEOUT_MS,
        readTimeout: HTTP_TIMEOUT_MS
      };
      if (body !== null) { options.extraData = JSON.stringify(body); }
      const response = await client.request(normalizeRustDeskProServerUrl(account.serverUrl) + path, options);
      let payload: Object = JSON.parse('{}') as Object;
      if (typeof response.result === 'string' && (response.result as string).length > 0) {
        try { payload = JSON.parse(response.result as string) as Object; } catch (_err) {
          throw new RustDeskProApiError('invalid_response', 'Pro 服务器返回了无效 JSON', response.responseCode as number);
        }
      }
      return { status: response.responseCode as number, payload };
    } finally {
      client.destroy();
    }
  }

  async login(account: RustDeskProAccountState, username: string, password: string): Promise<RustDeskProLoginResult> {
    const body = buildRustDeskProLoginRequest(username, password, account.deviceId, account.deviceUuid, APP_VERSION);
    const response = await this.request(account, '/api/login', http.RequestMethod.POST, body as Object);
    return parseRustDeskProLoginResponse(response.payload, response.status);
  }

  async getAddressBook(account: RustDeskProAccountState): Promise<RustDeskProAddressBook> {
    if (account.accessToken.length === 0) {
      throw new RustDeskProApiError('not_logged_in', 'Pro 账号尚未登录');
    }
    const response = await this.request(account, '/api/ab/get', http.RequestMethod.POST, JSON.parse('{}') as Object);
    return parseRustDeskProAddressBookResponse(response.payload, response.status);
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
