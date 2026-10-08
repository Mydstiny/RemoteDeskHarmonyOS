/**
 * RustDesk image quality is a bitrate preference sent to the controlled
 * peer. The protocol has no acknowledgement, so "sent" must never be shown as
 * "applied". The only remote evidence is the encoder target bitrate the peer
 * reports in its periodic TestDelay messages. This policy turns those samples
 * into a closed three-way verdict: changed, unchanged, or not reported.
 */

export type RustDeskQualityVerdict =
  'pending' | 'send_failed' | 'bitrate_raised' | 'bitrate_lowered' |
  'bitrate_unchanged' | 'not_reported';

/** The subset of RustDeskDiagnosticsSnapshot used for confirmation. */
export interface RustDeskQualitySample {
  sessionActive: boolean;
  targetBitrateKbps: number;
  testDelayCount: number;
  sentImageQuality: number;
  qualityRequestedGeneration: number;
  qualityAppliedGeneration: number;
  qualityUpdateStatus: number;
}

export interface RustDeskQualityConfirmation {
  quality: number;
  startedAtMs: number;
  baselineBitrateKbps: number;
  baselineTestDelayCount: number;
  /** testDelayCount observed when the native send completed; -1 until sent. */
  sentTestDelayCount: number;
  requestGeneration: number;
  /** Consecutive samples reporting no active session. */
  inactiveSamples: number;
}

export interface RustDeskQualityEvaluation {
  verdict: RustDeskQualityVerdict;
  baselineBitrateKbps: number;
  currentBitrateKbps: number;
}

/** A send that has not completed after this long is reported as failed. */
export const RUSTDESK_QUALITY_SEND_TIMEOUT_MS: number = 5000;
/** Remote TestDelay messages arrive every few seconds on a healthy link. */
export const RUSTDESK_QUALITY_CONFIRM_WINDOW_MS: number = 12000;
/** Samples after the send required before "unchanged" is a fair verdict. */
export const RUSTDESK_QUALITY_REQUIRED_REPORTS: number = 2;
/** Relative bitrate change treated as a real encoder adjustment. */
export const RUSTDESK_QUALITY_CHANGE_PERMILLE: number = 50;
export const RUSTDESK_QUALITY_POLL_INTERVAL_MS: number = 1000;
/** Consecutive inactive samples before a pending change is reported as failed. */
export const RUSTDESK_QUALITY_INACTIVE_SAMPLES: number = 2;

function safe(value: number): number {
  return Number.isSafeInteger(value) && value >= 0 ? value : 0;
}

export function beginRustDeskQualityConfirmation(quality: number, nowMs: number,
  baseline: RustDeskQualitySample): RustDeskQualityConfirmation {
  return {
    quality: quality,
    startedAtMs: nowMs,
    baselineBitrateKbps: safe(baseline.targetBitrateKbps),
    baselineTestDelayCount: safe(baseline.testDelayCount),
    sentTestDelayCount: -1,
    // The native request increments the generation; the request in flight
    // is the first generation strictly newer than the baseline.
    requestGeneration: safe(baseline.qualityRequestedGeneration) + 1,
    inactiveSamples: 0
  };
}

/**
 * Evaluates one sample. `state.sentTestDelayCount` is updated in place the
 * first time the native layer reports the request as sent, so only TestDelay
 * reports that arrived after the change count as evidence.
 */
export function evaluateRustDeskQualityConfirmation(state: RustDeskQualityConfirmation,
  sample: RustDeskQualitySample, nowMs: number): RustDeskQualityEvaluation {
  const current: number = safe(sample.targetBitrateKbps);
  const result: RustDeskQualityEvaluation = {
    verdict: 'pending', baselineBitrateKbps: state.baselineBitrateKbps, currentBitrateKbps: current
  };
  const elapsed: number = Math.max(0, nowMs - state.startedAtMs);
  if (!sample.sessionActive) {
    // A single failed diagnostics read returns an inactive placeholder; only
    // a repeated observation means the session is really gone.
    state.inactiveSamples++;
    if (state.inactiveSamples >= RUSTDESK_QUALITY_INACTIVE_SAMPLES) {
      result.verdict = 'send_failed';
    }
    return result;
  }
  state.inactiveSamples = 0;
  const generation: number = safe(sample.qualityRequestedGeneration);
  const superseded: boolean = generation > state.requestGeneration;
  const sent: boolean = safe(sample.qualityAppliedGeneration) >= state.requestGeneration &&
    sample.sentImageQuality === state.quality;
  if (!sent) {
    if (!superseded && sample.qualityUpdateStatus === 3) {
      result.verdict = 'send_failed';
    } else if (elapsed >= RUSTDESK_QUALITY_SEND_TIMEOUT_MS) {
      result.verdict = 'send_failed';
    }
    return result;
  }
  if (state.sentTestDelayCount < 0) {
    state.sentTestDelayCount = safe(sample.testDelayCount);
  }
  const reportsAfterSend: number = safe(sample.testDelayCount) - state.sentTestDelayCount;
  if (state.baselineBitrateKbps > 0 && current > 0) {
    const delta: number = current - state.baselineBitrateKbps;
    const threshold: number = Math.max(1,
      Math.floor(state.baselineBitrateKbps * RUSTDESK_QUALITY_CHANGE_PERMILLE / 1000));
    if (reportsAfterSend >= 1 && Math.abs(delta) >= threshold) {
      result.verdict = delta > 0 ? 'bitrate_raised' : 'bitrate_lowered';
      return result;
    }
    if (reportsAfterSend >= RUSTDESK_QUALITY_REQUIRED_REPORTS) {
      result.verdict = 'bitrate_unchanged';
      return result;
    }
  } else if (state.baselineBitrateKbps === 0 && current > 0 && reportsAfterSend >= 1) {
    // No baseline sample: a first report proves delivery but not a change.
    result.verdict = 'bitrate_unchanged';
    return result;
  }
  if (elapsed >= RUSTDESK_QUALITY_CONFIRM_WINDOW_MS) {
    result.verdict = current > 0 && reportsAfterSend >= 1 ? 'bitrate_unchanged' : 'not_reported';
  }
  return result;
}

export function rustDeskQualityName(quality: number): string {
  if (quality === 0) { return '速度优先'; }
  if (quality === 2) { return '画质优先'; }
  return '平衡';
}

function formatKbps(value: number): string {
  if (value >= 1000) {
    return (Math.round(value / 100) / 10).toString() + ' Mbps';
  }
  return value.toString() + ' kbps';
}

/** User-facing text; it never says "applied" without a bitrate change. */
export function rustDeskQualityVerdictMessage(quality: number,
  evaluation: RustDeskQualityEvaluation): string {
  const name: string = rustDeskQualityName(quality);
  switch (evaluation.verdict) {
    case 'bitrate_raised':
    case 'bitrate_lowered':
      return name + '：远端码率 ' + formatKbps(evaluation.baselineBitrateKbps) + ' → ' +
        formatKbps(evaluation.currentBitrateKbps);
    case 'bitrate_unchanged':
      return name + '已送达，远端码率未变化（可能受网络自适应或远端编码器限制）';
    case 'not_reported':
      return name + '已发送，远端未报告码率，无法确认是否生效';
    case 'send_failed':
      return name + '发送失败，下次连接时生效';
    default:
      return name + '：等待远端码率报告';
  }
}

export function rustDeskQualityVerdictIsFinal(verdict: RustDeskQualityVerdict): boolean {
  return verdict !== 'pending';
}
