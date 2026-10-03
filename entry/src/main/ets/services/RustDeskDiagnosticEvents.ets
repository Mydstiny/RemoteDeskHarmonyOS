import { DiagnosticNetworkFacts, DiagnosticOutcome } from './DiagnosticCapturePolicy';
import { recordDiagnosticEvent } from './DiagnosticCaptureRuntime';
import { ConnectionJournal } from './ConnectionJournal';
import { classifyRustDeskProNativeError, parseRustDeskNativeError,
  RustDeskProNativeErrorKind } from './RustDeskProConnectionPreflightPolicy';

/**
 * RustDesk diagnostic events without text: a failure becomes a closed category plus the stage the Rust core reported
 * (rendezvous, relay, control plane, peer); the first-frame wait becomes a duration and a recovery count.
 */

/** rustdesk_failure count: what kind of failure it was. */
export const RUSTDESK_FAILURE_UNCLASSIFIED: number = 0;
export const RUSTDESK_FAILURE_NETWORK: number = 1;
export const RUSTDESK_FAILURE_PEER_MISSING: number = 2;
export const RUSTDESK_FAILURE_PASSWORD: number = 3;
export const RUSTDESK_FAILURE_APPROVAL_REQUIRED: number = 4;
export const RUSTDESK_FAILURE_APPROVAL_TIMEOUT: number = 5;
export const RUSTDESK_FAILURE_RELAY_AUTH: number = 6;
export const RUSTDESK_FAILURE_CONTROL_PLANE: number = 7;
export const RUSTDESK_FAILURE_TWO_FACTOR: number = 8;
export const RUSTDESK_FAILURE_FIRST_FRAME: number = 9;
export const RUSTDESK_FAILURE_HANDSHAKE: number = 10;
export const RUSTDESK_FAILURE_HELPER: number = 11;
export const RUSTDESK_FAILURE_CANCELLED: number = 12;
export const RUSTDESK_FAILURE_TIMEOUT: number = 13;
export const RUSTDESK_FAILURE_MODE: number = 14;
export const RUSTDESK_FAILURE_CONFIG: number = 15;

function categoryForKind(kind: RustDeskProNativeErrorKind): number {
  switch (kind) {
    case 'network': return RUSTDESK_FAILURE_NETWORK;
    case 'peer_missing': return RUSTDESK_FAILURE_PEER_MISSING;
    case 'device_password': return RUSTDESK_FAILURE_PASSWORD;
    case 'peer_password_required': return RUSTDESK_FAILURE_APPROVAL_REQUIRED;
    case 'approval_timeout': return RUSTDESK_FAILURE_APPROVAL_TIMEOUT;
    case 'relay_auth': return RUSTDESK_FAILURE_RELAY_AUTH;
    case 'pro_session_expired': return RUSTDESK_FAILURE_CONTROL_PLANE;
    case 'control_plane_incompatible': return RUSTDESK_FAILURE_CONTROL_PLANE;
    default: return RUSTDESK_FAILURE_UNCLASSIFIED;
  }
}

/** The stage the Rust core reported: 1 rendezvous (ID server), 2 relay, 3 control plane, 4 peer, 5 other. */
function stageCode(message: string): number {
  const stage: string = parseRustDeskNativeError(message).stage;
  if (stage === '') { return 0; }
  if (stage === 'rendezvous') { return 1; }
  if (stage === 'relay') { return 2; }
  if (stage === 'control_plane') { return 3; }
  if (stage === 'peer') { return 4; }
  return 5;
}

/**
 * The category and stage of a RustDesk failure message (the message is read here and dropped). The app's own error
 * codes are exact and come first; then what the Rust core said; then the shared native-error classification.
 */
export function rustDeskFailureClassification(message: string): number[] {
  const stage: number = stageCode(message);
  const text: string = message.toUpperCase();
  if (text.indexOf('FIRST-FRAME') >= 0) { return [RUSTDESK_FAILURE_FIRST_FRAME, stage]; }
  if (text.indexOf('APPROVAL-TIMEOUT') >= 0) { return [RUSTDESK_FAILURE_APPROVAL_TIMEOUT, stage]; }
  if (text.indexOf('E-RUSTDESK-CANCELLED') >= 0) { return [RUSTDESK_FAILURE_CANCELLED, stage]; }
  if (text.indexOf('DIRECT-APPROVAL') >= 0 || text.indexOf('APPROVAL-UNSUPPORTED') >= 0) {
    return [RUSTDESK_FAILURE_MODE, stage];
  }
  if (text.indexOf('E-RUSTDESK-CONFIG') >= 0 || text.indexOf('E-RUSTDESK-CONTEXT') >= 0 ||
    text.indexOf('E-RUSTDESK-STRATEGY') >= 0) {
    return [RUSTDESK_FAILURE_CONFIG, stage];
  }
  if (text.indexOf('E-CONNECT-2]') >= 0 || text.indexOf('E-CONNECT-3]') >= 0) { return [RUSTDESK_FAILURE_HELPER, stage]; }
  if (text.indexOf('E-RUSTDESK-TIMEOUT') >= 0) { return [RUSTDESK_FAILURE_TIMEOUT, stage]; }
  const parsed = parseRustDeskNativeError(message);
  const detail: string = parsed.detail.toLowerCase();
  // A server that does not answer is a network problem whatever stage reported it.
  const unreachable: boolean = ['timed out', 'timeout', 'unreachable', 'resolve', 'no route', 'connection reset']
    .some((word: string): boolean => detail.indexOf(word) >= 0);
  if (unreachable && parsed.code !== 'relay_credential_rejected' && parsed.code !== 'pro_session_expired') {
    return [RUSTDESK_FAILURE_NETWORK, stage];
  }
  const byKind: number = categoryForKind(classifyRustDeskProNativeError(message));
  if (byKind !== RUSTDESK_FAILURE_UNCLASSIFIED) { return [byKind, stage]; }
  if (text.indexOf('2FA') >= 0 || message.indexOf('二次验证') >= 0) { return [RUSTDESK_FAILURE_TWO_FACTOR, stage]; }
  if (text.indexOf('E-RUSTDESK-STATE-') >= 0 || text.indexOf('E-CONNECT-31') >= 0) {
    return [RUSTDESK_FAILURE_HANDSHAKE, stage];
  }
  return [RUSTDESK_FAILURE_UNCLASSIFIED, stage];
}

/** A RustDesk connection failed (generation 1 while connecting, 2 in the session). */
const RUSTDESK_FAILURE_WORDS: string[] = ['连接失败', '服务器不可达', '对端 ID 不存在或离线', '设备密码错误', '需要对方批准',
  '等待批准超时', '中继鉴权失败', 'Server Pro 登录失败', '二次验证失败', '连上但没有画面', '握手失败或中断', '本机核心未运行', '已取消',
  '握手超时', '连接方式不支持', '连接配置无效'];

export function recordRustDeskFailure(message: string, stage: number, elapsedMs: number): void {
  const classified: number[] = rustDeskFailureClassification(message);
  if (classified[0] !== RUSTDESK_FAILURE_CANCELLED) {
    ConnectionJournal.failed('rustdesk', (stage === 2 ? '会话中断：' : '') + (RUSTDESK_FAILURE_WORDS[classified[0]] ?? '连接失败'));
  }
  recordDiagnosticEvent('connection.rustdesk', 'rustdesk_failure', 'failed', 0, stage, classified[1],
    Math.max(0, Math.round(elapsedMs)), classified[0]);
}

/** Connected → first picture: how long it took and how many decoder recoveries / keyframe requests it needed. */
export function recordRustDeskFirstFrame(outcome: DiagnosticOutcome, elapsedMs: number, recoveries: number): void {
  recordDiagnosticEvent('connection.rustdesk', 'rustdesk_first_frame', outcome, 0, 0, 0,
    Math.max(0, Math.round(elapsedMs)), recoveries);
}

/** rustdesk_quality_result code: closed verdict of a live image-quality change. */
export const RUSTDESK_QUALITY_RESULT_SEND_FAILED: number = 1;
export const RUSTDESK_QUALITY_RESULT_RAISED: number = 2;
export const RUSTDESK_QUALITY_RESULT_LOWERED: number = 3;
export const RUSTDESK_QUALITY_RESULT_UNCHANGED: number = 4;
export const RUSTDESK_QUALITY_RESULT_NOT_REPORTED: number = 5;

export function rustDeskQualityResultCode(verdict: string): number {
  switch (verdict) {
    case 'send_failed': return RUSTDESK_QUALITY_RESULT_SEND_FAILED;
    case 'bitrate_raised': return RUSTDESK_QUALITY_RESULT_RAISED;
    case 'bitrate_lowered': return RUSTDESK_QUALITY_RESULT_LOWERED;
    case 'bitrate_unchanged': return RUSTDESK_QUALITY_RESULT_UNCHANGED;
    case 'not_reported': return RUSTDESK_QUALITY_RESULT_NOT_REPORTED;
    default: return 0;
  }
}

/**
 * A live image-quality request. generation is the requested tier (0..2), code
 * is 1 when the native control lane accepted it and 0 when it was rejected and
 * only the preference was saved for the next connection.
 */
export function recordRustDeskQualityRequest(sessionId: number, quality: number,
  acceptedLive: boolean, baselineBitrateKbps: number): void {
  recordDiagnosticEvent('connection.rustdesk', 'rustdesk_quality_request',
    acceptedLive ? 'started' : 'skipped', Math.max(0, sessionId), quality, acceptedLive ? 1 : 0, 0,
    Math.max(0, Math.round(baselineBitrateKbps)));
}

/**
 * The evidence-based outcome of that request. count carries the remote target
 * bitrate (kbps) after the change; durationMs is the confirmation wait.
 */
export function recordRustDeskQualityResult(sessionId: number, quality: number, verdict: string,
  currentBitrateKbps: number, elapsedMs: number): void {
  const code: number = rustDeskQualityResultCode(verdict);
  const outcome: DiagnosticOutcome = code === RUSTDESK_QUALITY_RESULT_RAISED ||
    code === RUSTDESK_QUALITY_RESULT_LOWERED ? 'succeeded' :
    (code === RUSTDESK_QUALITY_RESULT_SEND_FAILED ? 'failed' : 'state');
  recordDiagnosticEvent('connection.rustdesk', 'rustdesk_quality_result', outcome, Math.max(0, sessionId),
    quality, code, Math.max(0, Math.round(elapsedMs)), Math.max(0, Math.round(currentBitrateKbps)));
}

/**
 * One stage of a RustDesk connection attempt with its route evidence and no
 * address: generation is the endpoint source code (0 relay, 1 manual direct,
 * 2 LAN discovery), code is the RustDeskDirectStage code and count is the
 * RustDeskDirectAddressClass code. Network facts carry only the address family.
 */
export function recordRustDeskDirectStage(outcome: DiagnosticOutcome, sessionId: number,
  sourceCode: number, stageCode: number, addressClassCode: number, elapsedMs: number,
  network: DiagnosticNetworkFacts): void {
  recordDiagnosticEvent('connection.rustdesk', 'rustdesk_direct_stage', outcome,
    sessionId > 0 ? sessionId : 0, Math.max(0, sourceCode), Math.max(0, stageCode),
    Math.max(0, Math.round(elapsedMs)), Math.max(0, addressClassCode), 0, undefined, network);
}
