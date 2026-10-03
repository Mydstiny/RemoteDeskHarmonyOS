import { recordDiagnosticEvent } from './DiagnosticCaptureRuntime';
import { ConnectionJournal } from './ConnectionJournal';

/** vnc_failure count: what kind of failure it was (from the app's E-VNC-* code; the message itself is dropped). */
export const VNC_FAILURE_UNCLASSIFIED: number = 0;
export const VNC_FAILURE_CONNECTION: number = 1;
export const VNC_FAILURE_PASSWORD: number = 2;
export const VNC_FAILURE_PASSWORD_MISSING: number = 3;
export const VNC_FAILURE_TLS: number = 4;
export const VNC_FAILURE_CERTIFICATE: number = 5;
export const VNC_FAILURE_GATEWAY: number = 6;
export const VNC_FAILURE_CONFIG: number = 7;
export const VNC_FAILURE_RESTORE: number = 8;
export const VNC_FAILURE_TIMEOUT: number = 9;

export function vncFailureCategory(message: string): number {
  const text: string = message.toUpperCase();
  if (text.indexOf('E-VNC-AUTH-PASSWORD') >= 0) { return VNC_FAILURE_PASSWORD; }
  if (text.indexOf('E-VNC-AUTH-MISSING') >= 0) { return VNC_FAILURE_PASSWORD_MISSING; }
  if (text.indexOf('E-VNC-TLS') >= 0) { return VNC_FAILURE_TLS; }
  if (text.indexOf('E-VNC-CERT') >= 0) { return VNC_FAILURE_CERTIFICATE; }
  if (text.indexOf('E-VNC-GATEWAY') >= 0 || text.indexOf('E-VNC-WS') >= 0) { return VNC_FAILURE_GATEWAY; }
  if (text.indexOf('E-VNC-PAIRING') >= 0 || text.indexOf('E-VNC-ENDPOINT') >= 0 || text.indexOf('E-VNC-HOST') >= 0 ||
    text.indexOf('E-VNC-PROBE') >= 0 || text.indexOf('E-VNC-SCOPE') >= 0) {
    return VNC_FAILURE_CONFIG;
  }
  if (text.indexOf('E-VNC-RESTORE') >= 0) { return VNC_FAILURE_RESTORE; }
  if (text.indexOf('TIMEOUT') >= 0 || message.indexOf('超时') >= 0) { return VNC_FAILURE_TIMEOUT; }
  if (text.indexOf('E-VNC-CONNECTION') >= 0 || text.indexOf('E-CONNECT') >= 0) { return VNC_FAILURE_CONNECTION; }
  return VNC_FAILURE_UNCLASSIFIED;
}

/** A VNC connection failed (generation 1 while connecting). */
const VNC_FAILURE_WORDS: string[] = ['连接失败', '地址或端口不通', 'VNC 密码错误', '缺少密码', 'TLS 配置不匹配', '证书问题',
  '网关配置问题', '主机配置无效', '恢复画面失败', '连接超时'];

export function recordVncFailure(message: string, elapsedMs: number): void {
  const category: number = vncFailureCategory(message);
  ConnectionJournal.failed('vnc', VNC_FAILURE_WORDS[category] ?? '连接失败');
  recordDiagnosticEvent('connection.vnc', 'vnc_failure', 'failed', 0, 1, 0, Math.max(0, Math.round(elapsedMs)),
    category);
}
