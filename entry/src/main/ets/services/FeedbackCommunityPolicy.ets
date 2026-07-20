/**
 * FeedbackCommunityPolicy.ets — 云端反馈/畅联群聊清单校验。
 *
 * 云端只需要维护一个 HTTPS JSON 文件，客户端不信任未经校验的链接。
 */

export const FEEDBACK_COMMUNITY_MANIFEST_URL: string =
  'https://lijiong.online/feedback/chanlian.json';
export const FEEDBACK_COMMUNITY_ASSET_PREFIX: string =
  'https://lijiong.online/feedback/';
export const FEEDBACK_COMMUNITY_QR_MAX_AGE_MS: number = 7 * 24 * 60 * 60 * 1000;
export const FEEDBACK_COMMUNITY_QR_MAX_BYTES: number = 10 * 1024 * 1024;
export const FEEDBACK_COMMUNITY_CLOCK_SKEW_MS: number = 5 * 60 * 1000;

export interface FeedbackCommunityManifest {
  version: string;
  issuedAt: number;
  expiresAt: number;
  qrImageUrl: string;
  joinUrl: string;
  title: string;
  notice: string;
}

export interface FeedbackCommunityValidation {
  ok: boolean;
  message: string;
  manifest: FeedbackCommunityManifest | null;
}

function stringValue(value: Object | undefined): string {
  return typeof value === 'string' ? value as string : '';
}

function numberValue(value: Object | undefined): number {
  return typeof value === 'number' ? value as number : 0;
}

function isHttpsUrl(value: string): boolean {
  return value.indexOf('https://') === 0;
}

export function isFeedbackCommunityQrImageUrl(value: string): boolean {
  return value.indexOf(FEEDBACK_COMMUNITY_ASSET_PREFIX) === 0;
}

export function validateFeedbackCommunityManifest(
  payload: Object,
  now: number
): FeedbackCommunityValidation {
  const raw: Record<string, Object> = payload as Record<string, Object>;
  const issuedAt: number = numberValue(raw['issuedAt']);
  const expiresAt: number = numberValue(raw['expiresAt']);
  const version: string = stringValue(raw['version']);
  const qrImageUrl: string = stringValue(raw['qrImageUrl']);
  const joinUrl: string = stringValue(raw['joinUrl']);
  if (issuedAt <= 0 || expiresAt <= 0 || expiresAt <= issuedAt) {
    return { ok: false, message: '云端二维码时间戳无效', manifest: null };
  }
  if (expiresAt - issuedAt > FEEDBACK_COMMUNITY_QR_MAX_AGE_MS) {
    return { ok: false, message: '云端二维码有效期超过 7 天', manifest: null };
  }
  if (issuedAt > now + FEEDBACK_COMMUNITY_CLOCK_SKEW_MS) {
    return { ok: false, message: '云端二维码发布时间异常', manifest: null };
  }
  if (expiresAt <= now) {
    return { ok: false, message: '二维码已过期，请刷新后重试', manifest: null };
  }
  if (!isFeedbackCommunityQrImageUrl(qrImageUrl)) {
    return { ok: false, message: '二维码地址必须来自 lijiong.online', manifest: null };
  }
  if (joinUrl !== '' && !isHttpsUrl(joinUrl)) {
    return { ok: false, message: '畅联跳转地址必须使用 HTTPS', manifest: null };
  }
  const manifest: FeedbackCommunityManifest = {
    // 兼容旧服务器清单：没有 version 时使用 expiresAt 作为缓存版本。
    version: version || expiresAt.toString(),
    issuedAt: issuedAt,
    expiresAt: expiresAt,
    qrImageUrl: qrImageUrl,
    joinUrl: joinUrl,
    title: stringValue(raw['title']) || '加入 RemoteDesktop 畅联群聊',
    notice: stringValue(raw['notice']) || '二维码每 7 天更新一次，请保存后使用另一台设备扫描。'
  };
  return { ok: true, message: '', manifest: manifest };
}

export function feedbackCommunityImageUrl(manifest: FeedbackCommunityManifest): string {
  const separator: string = manifest.qrImageUrl.indexOf('?') >= 0 ? '&' : '?';
  return manifest.qrImageUrl + separator + 'v=' + encodeURIComponent(manifest.version);
}

export function feedbackCommunityRemainingText(expiresAt: number, now: number): string {
  const remainingMs: number = expiresAt - now;
  if (remainingMs <= 0) { return '已过期'; }
  const remainingHours: number = Math.ceil(remainingMs / (60 * 60 * 1000));
  if (remainingHours < 24) { return '将在约 ' + remainingHours.toString() + ' 小时后更新'; }
  const remainingDays: number = Math.ceil(remainingHours / 24);
  return '将在约 ' + remainingDays.toString() + ' 天后更新';
}
