import { DiagnosticModuleId, DiagnosticOutcome } from './DiagnosticCapturePolicy';
import { recordDiagnosticEvent } from './DiagnosticCaptureRuntime';
import { ConnectionJournal } from './ConnectionJournal';

/**
 * Remote-session diagnostic events that carry no text: an RDP failure is reduced to a closed category and the
 * native numeric code (FreeRDP connect error or server ErrorInfo), never the message itself.
 */

/** rdp_failure count: what kind of failure it was. */
export const RDP_FAILURE_UNCLASSIFIED: number = 0;
export const RDP_FAILURE_TRANSPORT: number = 1;
export const RDP_FAILURE_DNS: number = 2;
export const RDP_FAILURE_TLS: number = 3;
export const RDP_FAILURE_CREDENTIALS: number = 4;
export const RDP_FAILURE_ACCOUNT: number = 5;
export const RDP_FAILURE_CERTIFICATE: number = 6;
export const RDP_FAILURE_GATEWAY: number = 7;
export const RDP_FAILURE_SERVER_DISCONNECT: number = 8;
export const RDP_FAILURE_TIMEOUT: number = 9;
export const RDP_FAILURE_CANCELLED: number = 10;
export const RDP_FAILURE_NEGOTIATION: number = 11;
export const RDP_FAILURE_PERMISSION: number = 12;
export const RDP_FAILURE_PASSWORD_EXPIRED: number = 13;

/** rdp_failure generation: where it happened. */
export const RDP_FAILURE_WHILE_CONNECTING: number = 1;
export const RDP_FAILURE_IN_SESSION: number = 2;

function bracketedHex(message: string, marker: string): number {
  const match: RegExpMatchArray | null = message.match(new RegExp('\\[' + marker + '0x([0-9a-fA-F]{1,8})\\]'));
  if (match === null || match.length < 2) { return 0; }
  const value: number = parseInt(match[1], 16);
  return Number.isSafeInteger(value) ? value : 0;
}

/** FreeRDP connect error (ERRCONNECT_*) → category. */
function categoryForConnectCode(code: number): number {
  switch (code) {
    case 0x20004: case 0x20005: return RDP_FAILURE_DNS;
    case 0x20002: case 0x20006: case 0x20007: case 0x2000D: return RDP_FAILURE_TRANSPORT;
    case 0x20008: return RDP_FAILURE_TLS;
    case 0x20009: case 0x20011: case 0x20014: case 0x20015: case 0x2001B: return RDP_FAILURE_CREDENTIALS;
    case 0x2000A: case 0x20016: case 0x2001A: return RDP_FAILURE_PERMISSION;
    case 0x2000E: case 0x2000F: case 0x20013: return RDP_FAILURE_PASSWORD_EXPIRED;
    case 0x20010: case 0x20012: case 0x20017: case 0x20018: case 0x20019: return RDP_FAILURE_ACCOUNT;
    case 0x2000B: return RDP_FAILURE_CANCELLED;
    case 0x2000C: return RDP_FAILURE_NEGOTIATION;
    default: return RDP_FAILURE_UNCLASSIFIED;
  }
}

/** The category and numeric code of an RDP failure message (the message is read here and dropped). */
export function rdpFailureClassification(message: string): number[] {
  const connectCode: number = bracketedHex(message, 'E-CONN-');
  if (connectCode > 0) {
    const category: number = categoryForConnectCode(connectCode);
    return [category === RDP_FAILURE_UNCLASSIFIED ? RDP_FAILURE_TRANSPORT : category, connectCode];
  }
  const errorInfo: number = bracketedHex(message, 'E-RDP-ERRINFO-');
  if (errorInfo > 0) { return [RDP_FAILURE_SERVER_DISCONNECT, errorInfo]; }
  const text: string = message.toUpperCase();
  if (text.indexOf('E-RDP-TIMEOUT') >= 0 || message.indexOf('超时') >= 0) { return [RDP_FAILURE_TIMEOUT, 0]; }
  if (text.indexOf('CERT') >= 0 || message.indexOf('证书') >= 0) { return [RDP_FAILURE_CERTIFICATE, 0]; }
  if (text.indexOf('GATEWAY') >= 0 || message.indexOf('网关') >= 0) { return [RDP_FAILURE_GATEWAY, 0]; }
  if (text.indexOf('E-RDP-AUTH') >= 0 || text.indexOf('CREDENTIAL') >= 0 || message.indexOf('凭据') >= 0) {
    return [RDP_FAILURE_CREDENTIALS, 0];
  }
  if (message.indexOf('取消') >= 0) { return [RDP_FAILURE_CANCELLED, 0]; }
  if (text.indexOf('E-CONNECT-2]') >= 0 || message.indexOf('拒绝') >= 0) { return [RDP_FAILURE_TRANSPORT, 0]; }
  return [RDP_FAILURE_UNCLASSIFIED, 0];
}

/** An RDP connection failed (while connecting) or ended with an error (in the session). */
/** rdp_failure categories in words, for 连接记录. */
const RDP_FAILURE_WORDS: string[] = ['连接失败', '网络或端口不通', '域名解析失败', 'TLS 握手失败', '用户名或密码错误', '账号被禁用或受限',
  '证书问题', '网关失败', '服务器断开', '连接超时', '已取消', '安全协商失败', '没有远程登录权限', '密码已过期'];

export function recordRdpFailure(message: string, stage: number, elapsedMs: number): void {
  const classified: number[] = rdpFailureClassification(message);
  if (classified[0] !== RDP_FAILURE_CANCELLED) {
    ConnectionJournal.failed('rdp', (stage === RDP_FAILURE_IN_SESSION ? '会话中断：' : '') +
      (RDP_FAILURE_WORDS[classified[0]] ?? '连接失败'));
  }
  recordDiagnosticEvent('connection.rdp', 'rdp_failure', 'failed', 0, stage, classified[1],
    Math.max(0, Math.round(elapsedMs)), classified[0]);
  recordRdpSecurityLayerEvidence(message);
}

/** rdp_security_layer generation bits. */
export const RDP_SECURITY_LAYER_ALLOWED: number = 1;
export const RDP_SECURITY_LAYER_REACHED: number = 2;
export const RDP_SECURITY_LAYER_CHECK: number = 8;

/**
 * The native security-layer evidence of a failed connection,
 * "[RDP-SEC proto=0x0 allowed=1 layer=1 level=4 method=0x10]", as numbers:
 * code the selected protocol, generation 1 Standard RDP Security allowed +
 * 2 reached, count the server encryption level, bytes the encryption method.
 * Null when the message carries no such evidence.
 */
export function rdpSecurityLayerEvidence(message: string): number[] | null {
  const match: RegExpMatchArray | null = message.match(new RegExp(
    '\\[RDP-SEC proto=0x([0-9a-fA-F]{1,8}) allowed=([01]) layer=([01]) level=([0-9]{1,10}) method=0x([0-9a-fA-F]{1,8})\\]'));
  if (match === null || match.length < 6) { return null; }
  const values: number[] = [parseInt(match[1], 16), parseInt(match[4], 10), parseInt(match[5], 16)];
  if (values.some((value: number): boolean => !Number.isSafeInteger(value))) { return null; }
  const flags: number = (match[2] === '1' ? RDP_SECURITY_LAYER_ALLOWED : 0) +
    (match[3] === '1' ? RDP_SECURITY_LAYER_REACHED : 0);
  return [values[0], flags, values[1], values[2]];
}

/** The failure message without its security-layer evidence, for showing to the user. */
export function withoutRdpSecurityLayerEvidence(message: string): string {
  return message.replace(new RegExp('\\s*\\[RDP-SEC [^\\]]*\\]', 'g'), '');
}

function recordRdpSecurityLayerEvidence(message: string): void {
  const evidence: number[] | null = rdpSecurityLayerEvidence(message);
  if (evidence === null) { return; }
  recordDiagnosticEvent('connection.rdp', 'rdp_security_layer', 'failed', 0, evidence[1], evidence[0], 0,
    evidence[2], evidence[3]);
}

/**
 * After a normal connection failed, the credential-free check of the host's
 * security layer: succeeded when it only speaks Standard RDP Security (the
 * downgrade choice is then offered), skipped when it does not.
 */
export function recordRdpStandardSecurityCheck(required: boolean): void {
  recordDiagnosticEvent('connection.rdp', 'rdp_security_layer', required ? 'succeeded' : 'skipped', 0,
    RDP_SECURITY_LAYER_CHECK, required ? -18 : 0);
}

/** rdp_certificate code: what the user did with the certificate sheet. */
export const RDP_CERTIFICATE_CONTINUE_ONCE: number = 1;
export const RDP_CERTIFICATE_TRUST: number = 2;
export const RDP_CERTIFICATE_CANCEL: number = 3;
export const RDP_CERTIFICATE_BYPASS: number = 4;

export function recordRdpCertificateDecision(decision: number): void {
  const outcome: DiagnosticOutcome = decision === RDP_CERTIFICATE_CANCEL ? 'cancelled' :
    decision === RDP_CERTIFICATE_BYPASS ? 'skipped' : 'succeeded';
  recordDiagnosticEvent('connection.rdp', 'rdp_certificate', outcome, 0, 0, decision);
}

/** *_clipboard code: how the session clipboard bridge came up. */
export const CLIPBOARD_STARTED: number = 0;
export const CLIPBOARD_AUTHORITY_BUSY: number = 1;
export const CLIPBOARD_READ_PERMISSION_MISSING: number = 2;
export const CLIPBOARD_CHANNEL_NOT_NEGOTIATED: number = 3;
export const CLIPBOARD_START_ERROR: number = 4;
export const CLIPBOARD_NATIVE_REJECTED: number = 5;

/** The session clipboard for RDP or RustDesk (count 1 when local reading is allowed). */
export function recordSessionClipboard(protocol: string, outcome: DiagnosticOutcome, code: number,
  localRead: boolean = false): void {
  const moduleId: DiagnosticModuleId | null = protocol === 'rdp' ? 'connection.rdp' :
    protocol === 'rustdesk' ? 'connection.rustdesk' : null;
  if (moduleId === null) { return; }
  recordDiagnosticEvent(moduleId, protocol + '_clipboard', outcome, 0, 0, code, 0, localRead ? 1 : 0);
}

/** rdp_drive code: 0 mounted, 1 unavailable on the server side, 2 not mounted in time. */
export function recordRdpDrive(outcome: DiagnosticOutcome, code: number): void {
  recordDiagnosticEvent('connection.rdp', 'rdp_drive', outcome, 0, 0, code);
}

/** rdp_audio: the local player for remote audio (code: the native handle, ≤ 0 is a failure). */
export function recordRdpAudio(outcome: DiagnosticOutcome, code: number): void {
  recordDiagnosticEvent('connection.rdp', 'rdp_audio', outcome, 0, 0, code);
}
