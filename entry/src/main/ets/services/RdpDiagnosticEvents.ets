import { DiagnosticModuleId, DiagnosticOutcome } from './DiagnosticCapturePolicy';
import { recordDiagnosticEvent } from './DiagnosticCaptureRuntime';

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
export function recordRdpFailure(message: string, stage: number, elapsedMs: number): void {
  const classified: number[] = rdpFailureClassification(message);
  recordDiagnosticEvent('connection.rdp', 'rdp_failure', 'failed', 0, stage, classified[1],
    Math.max(0, Math.round(elapsedMs)), classified[0]);
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
