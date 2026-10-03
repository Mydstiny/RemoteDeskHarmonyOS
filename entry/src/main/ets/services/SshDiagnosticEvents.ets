import { recordDiagnosticEvent } from './DiagnosticCaptureRuntime';

/**
 * SSH/SFTP diagnostic events without text: a connection failure becomes a closed category plus the native code, an
 * SFTP failure a category plus the engine's own reason (by its position in a fixed list).
 */

/** ssh_failure count. */
export const SSH_FAILURE_UNCLASSIFIED: number = 0;
export const SSH_FAILURE_CONNECT: number = 1;
export const SSH_FAILURE_AUTH: number = 2;
export const SSH_FAILURE_HOST_KEY: number = 3;
export const SSH_FAILURE_KEY: number = 4;
export const SSH_FAILURE_JUMP: number = 5;
export const SSH_FAILURE_PROXY: number = 6;
export const SSH_FAILURE_ROUTE: number = 7;
export const SSH_FAILURE_BINDING: number = 8;

function nativeCode(message: string, code: number): number {
  if (code !== 0) { return code; }
  const match: RegExpMatchArray | null = message.match(/code=(-?\d{1,6})/);
  return match !== null && match.length > 1 ? parseInt(match[1], 10) : 0;
}

/** The category and native code of an SSH connection failure (the message is read here and dropped). */
export function sshFailureClassification(message: string, code: number): number[] {
  const text: string = message.toUpperCase();
  const native: number = nativeCode(message, code);
  if (text.indexOf('E-SSH-JUMP') >= 0) { return [SSH_FAILURE_JUMP, native]; }
  if (text.indexOf('E-SSH-PROXY') >= 0) { return [SSH_FAILURE_PROXY, native]; }
  if (text.indexOf('HOSTKEY') >= 0 || message.indexOf('指纹') >= 0 || message.indexOf('主机密钥') >= 0) {
    return [SSH_FAILURE_HOST_KEY, native];
  }
  if (text.indexOf('PASSPHRASE') >= 0 || text.indexOf('KEY-MISSING') >= 0 || message.indexOf('私钥') >= 0) {
    return [SSH_FAILURE_KEY, native];
  }
  if (text.indexOf('AUTH') >= 0 || message.indexOf('认证') >= 0 || message.indexOf('鉴权') >= 0 ||
    message.indexOf('密码') >= 0) {
    return [SSH_FAILURE_AUTH, native];
  }
  if (text.indexOf('ROUTE') >= 0 || text.indexOf('PREFLIGHT') >= 0) { return [SSH_FAILURE_ROUTE, native]; }
  if (message.indexOf('绑定') >= 0) { return [SSH_FAILURE_BINDING, native]; }
  if (message.indexOf('连接失败') >= 0 || native < 0) { return [SSH_FAILURE_CONNECT, native]; }
  return [SSH_FAILURE_UNCLASSIFIED, native];
}

export function recordSshFailure(message: string, code: number, elapsedMs: number): void {
  const classified: number[] = sshFailureClassification(message, code);
  recordDiagnosticEvent('connection.ssh_sftp', 'ssh_failure', 'failed', 0, 1, classified[1],
    Math.max(0, Math.round(elapsedMs)), classified[0]);
}

/** The SFTP engine's failure reasons; an event carries the position (1-based) of its reason. */
const SFTP_REASONS: string[] = [
  'local-source-missing', 'local-source-identity-changed', 'local-directory-prepare-failed', 'directory-prepare-failed',
  'directory-complete-rejected', 'upload-offset-invalid', 'upload-partial-identity-mismatch', 'upload-local-seek-failed',
  'upload-empty-partial-unverified', 'upload-local-read-failed', 'upload-partial-unverified', 'upload-source-changed',
  'upload-partial-size-mismatch', 'upload-exception', 'download-remote-identity-changed', 'download-local-target-invalid',
  'download-partial-path-invalid', 'download-offset-invalid', 'download-partial-identity-mismatch',
  'download-local-seek-failed', 'download-local-write-failed', 'download-partial-unverified',
  'download-final-identity-mismatch', 'download-atomic-export-failed', 'download-exception', 'remote-conflict-list-failed',
  'remote-copy-path-invalid', 'remote-copy-directory-complete-rejected', 'remote-copy-offset-invalid'
];

/** sftp_failure count. */
export const SFTP_FAILURE_OTHER: number = 0;
export const SFTP_FAILURE_LOCAL_FILE: number = 1;
export const SFTP_FAILURE_VERIFY: number = 2;
export const SFTP_FAILURE_CHANGED: number = 3;
export const SFTP_FAILURE_PATH: number = 4;
export const SFTP_FAILURE_EXCEPTION: number = 5;
export const SFTP_FAILURE_DIRECTORY: number = 6;
export const SFTP_FAILURE_CONNECTION_LOST: number = 7;

export function sftpFailureCategory(reason: string): number {
  if (reason.indexOf('changed') >= 0) { return SFTP_FAILURE_CHANGED; }
  if (reason.indexOf('local') >= 0) { return SFTP_FAILURE_LOCAL_FILE; }
  if (reason.indexOf('unverified') >= 0 || reason.indexOf('mismatch') >= 0 || reason.indexOf('durability') >= 0) {
    return SFTP_FAILURE_VERIFY;
  }
  if (reason.indexOf('exception') >= 0) { return SFTP_FAILURE_EXCEPTION; }
  if (reason.indexOf('prepare') >= 0) { return SFTP_FAILURE_DIRECTORY; }
  if (reason.indexOf('path') >= 0 || reason.indexOf('offset') >= 0 || reason.indexOf('conflict') >= 0 ||
    reason.indexOf('rejected') >= 0) {
    return SFTP_FAILURE_PATH;
  }
  return SFTP_FAILURE_OTHER;
}

/** An SFTP task failed (direction 1 upload, 2 download, 3 remote copy) or its connection dropped mid-transfer. */
export function recordSftpFailure(reason: string, direction: number, connectionLost: boolean = false): void {
  const category: number = connectionLost ? SFTP_FAILURE_CONNECTION_LOST : sftpFailureCategory(reason);
  recordDiagnosticEvent('connection.ssh_sftp', 'sftp_failure', connectionLost ? 'retry' : 'failed', 0, direction,
    SFTP_REASONS.indexOf(reason) + 1, 0, category);
}
