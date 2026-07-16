import { RustDeskProAddressBook } from '../model/RustDeskProModels';

export interface RustDeskProLoginRequest {
  username: string
  password: string
  id: string
  uuid: string
  type: string
  deviceInfo: RustDeskProDeviceInfo
}

export interface RustDeskProDeviceInfo {
  os: string
  platform: string
  app: string
  version: string
}

export interface RustDeskProLoginResult {
  accessToken: string
  userId: string
  username: string
  displayName: string
  requiresTwoFactor: boolean
}

export interface RustDeskProAddressBookPage {
  total: number
  addressBook: RustDeskProAddressBook
}

export class RustDeskProApiError extends Error {
  code: string;
  status: number;

  constructor(code: string, message: string, status: number = 0) {
    super(message);
    this.code = code;
    this.status = status;
  }
}

export function normalizeRustDeskProServerUrl(value: string): string {
  let url = value.trim();
  while (url.endsWith('/')) { url = url.substring(0, url.length - 1); }
  if (url.endsWith('/api')) { url = url.substring(0, url.length - 4); }
  while (url.endsWith('/')) { url = url.substring(0, url.length - 1); }
  if (url.length === 0) { throw new RustDeskProApiError('invalid_url', 'Pro 服务器地址不能为空'); }
  if (!url.startsWith('http://') && !url.startsWith('https://')) {
    throw new RustDeskProApiError('invalid_url', 'Pro 服务器地址必须以 http:// 或 https:// 开头');
  }
  return url;
}

export function buildRustDeskProLoginRequest(username: string, password: string,
  deviceId: string, deviceUuid: string, appVersion: string): RustDeskProLoginRequest {
  return {
    username: username.trim(),
    password,
    id: deviceId,
    uuid: deviceUuid,
    type: 'account',
    deviceInfo: {
      os: 'HarmonyOS',
      platform: 'HarmonyOS NEXT',
      app: 'RemoteDeskHarmonyOS',
      version: appVersion
    }
  };
}

export function parseRustDeskProLoginResponse(payload: Object, status: number): RustDeskProLoginResult {
  const root = payload as Record<string, Object>;
  const rawError: Object | undefined = root['error'];
  if (status !== 200) {
    const message = typeof rawError === 'string' ? rawError as string : 'Pro 登录失败 (HTTP ' + status.toString() + ')';
    throw new RustDeskProApiError('http_error', message, status);
  }
  if (typeof root['type'] === 'string' && (root['type'] as string) === 'email_check') {
    throw new RustDeskProApiError('two_factor_required', 'Pro 账号需要二次验证', status);
  }
  if (rawError !== undefined && typeof rawError === 'string') {
    throw new RustDeskProApiError('auth_error', rawError as string, status);
  }
  const token: string = typeof root['access_token'] === 'string' ? root['access_token'] as string : '';
  if (token.length === 0) {
    throw new RustDeskProApiError('invalid_response', 'Pro 登录响应缺少 access_token', status);
  }
  const user: Record<string, Object> = root['user'] && typeof root['user'] === 'object'
    ? root['user'] as Record<string, Object> : {};
  const username: string = typeof user['name'] === 'string' ? user['name'] as string : '';
  const displayName: string = typeof user['display_name'] === 'string' ? user['display_name'] as string : username;
  const userId: string = typeof user['id'] === 'string' ? user['id'] as string : username;
  return { accessToken: token, userId, username, displayName, requiresTwoFactor: false };
}

export function parseRustDeskProAddressBookResponse(payload: Object, status: number): RustDeskProAddressBook {
  const root = payload as Record<string, Object>;
  if (status === 401 || status === 403) {
    throw new RustDeskProApiError('token_expired', 'Pro 登录已过期，请重新登录', status);
  }
  if (status !== 200) {
    const rawError: Object | undefined = root['error'];
    const message = typeof rawError === 'string' ? rawError as string : 'Pro 地址簿同步失败 (HTTP ' + status.toString() + ')';
    throw new RustDeskProApiError('http_error', message, status);
  }
  if (typeof root['error'] === 'string') {
    throw new RustDeskProApiError('api_error', root['error'] as string, status);
  }
  return RustDeskProAddressBook.fromResponse(payload);
}

export function parseRustDeskProPersonalAddressBookResponse(payload: Object, status: number): string {
  if (status === 401 || status === 403) {
    throw new RustDeskProApiError('token_expired', 'Pro 登录已过期，请重新登录', status);
  }
  if (status === 404) { return ''; }
  if (status !== 200) {
    const root = payload as Record<string, Object>;
    const rawError: Object | undefined = root['error'];
    const message = typeof rawError === 'string' ? rawError as string :
      'Pro 个人地址簿查询失败 (HTTP ' + status.toString() + ')';
    throw new RustDeskProApiError('http_error', message, status);
  }
  const root = payload as Record<string, Object>;
  if (typeof root['error'] === 'string') {
    throw new RustDeskProApiError('api_error', root['error'] as string, status);
  }
  const guid = typeof root['guid'] === 'string' ? root['guid'] as string : '';
  if (guid.length === 0) {
    throw new RustDeskProApiError('invalid_response', 'Pro 个人地址簿响应缺少 guid', status);
  }
  return guid;
}

export function parseRustDeskProAddressBookPage(payload: Object, status: number): RustDeskProAddressBookPage {
  if (status === 401 || status === 403) {
    throw new RustDeskProApiError('token_expired', 'Pro 登录已过期，请重新登录', status);
  }
  if (status !== 200) {
    const root = payload as Record<string, Object>;
    const rawError: Object | undefined = root['error'];
    const message = typeof rawError === 'string' ? rawError as string :
      'Pro 地址簿分页同步失败 (HTTP ' + status.toString() + ')';
    throw new RustDeskProApiError('http_error', message, status);
  }
  const root = payload as Record<string, Object>;
  if (typeof root['error'] === 'string') {
    throw new RustDeskProApiError('api_error', root['error'] as string, status);
  }
  const rawTotal: Object | undefined = root['total'];
  const total = typeof rawTotal === 'number' ? rawTotal as number : 0;
  const result: RustDeskProAddressBookPage = {
    total,
    addressBook: RustDeskProAddressBook.fromResponse(payload)
  };
  return result;
}

export function parseRustDeskProSharedAddressBookProfiles(payload: Object, status: number): string[] {
  if (status === 401 || status === 403) {
    throw new RustDeskProApiError('token_expired', 'Pro 登录已过期，请重新登录', status);
  }
  // Older compatible servers may not expose shared address books.
  if (status === 404) { return []; }
  if (status !== 200) {
    const root = payload as Record<string, Object>;
    const rawError: Object | undefined = root['error'];
    const message = typeof rawError === 'string' ? rawError as string :
      'Pro 共享地址簿列表查询失败 (HTTP ' + status.toString() + ')';
    throw new RustDeskProApiError('http_error', message, status);
  }
  const root = payload as Record<string, Object>;
  if (typeof root['error'] === 'string') {
    throw new RustDeskProApiError('api_error', root['error'] as string, status);
  }
  const result: string[] = [];
  const data: Object | undefined = root['data'];
  if (Array.isArray(data)) {
    const rows: Object[] = data as Object[];
    for (let i = 0; i < rows.length; i++) {
      if (!rows[i] || typeof rows[i] !== 'object') { continue; }
      const row = rows[i] as Record<string, Object>;
      if (typeof row['guid'] === 'string' && (row['guid'] as string).length > 0) {
        result.push(row['guid'] as string);
      }
    }
  }
  return result;
}
