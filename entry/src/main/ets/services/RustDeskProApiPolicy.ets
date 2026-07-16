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
