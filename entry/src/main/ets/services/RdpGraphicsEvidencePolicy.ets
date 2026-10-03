import { RdpGfxEvidenceStats, RdpRenderStats } from '../types/rdpnapi';

/**
 * RDP graphics evidence keeps four facts apart that older diagnostics merged
 * into one `backend=gdi` label:
 *  - requestedMode: what the client was willing to advertise before connect;
 *  - capsConfirmed*: the one RDPGFX capability set the server confirmed;
 *  - wireCodec: the codec id actually carried by surface commands;
 *  - presentation: how the local renderer consumed the decoded frame.
 * Byte counters are labelled by source: wireBytes are RDPGFX surface payload
 * bytes, copiedBytes are local BGRA presentation copies.
 */
export type RdpRequestedGraphicsMode = 'unknown' | 'gdi' | 'gfx' | 'gfx-h264';
export type RdpGraphicsPresentation = 'unknown' | 'gdi_bgra' | 'gfx_gdi_consumer';
export type RdpGfxWireCodec =
  'none' | 'uncompressed' | 'av1' | 'remotefx' | 'clearcodec' | 'progressive' |
  'planar' | 'avc420' | 'alpha' | 'progressive_v2' | 'avc444' | 'avc444v2' | 'unknown';
export type RdpGfxCapsVersion =
  'unknown' | '8.0' | '8.1' | '10.0' | '10.1' | '10.2' | '10.3' | '10.4' | '10.5' |
  '10.6' | '10.6-err' | '10.7' | '11.1' | '11.2' | '11.3' | 'freerdp-1';
export type RdpGfxFallbackReason =
  'none' | 'gfx-gdi-missing' | 'gfx-gdi-mode' | 'gfx-owner-missing' |
  'gfx-channel-conflict' | 'gfx-init-failed' | 'resize-rejected' | 'resize-failed' | 'unknown';
export type RdpGraphicsEvidenceLevel = 'missing' | 'configured' | 'observed_native';
/** Closed H.264 status: never derived from the requested mode alone. */
export type RdpH264Status =
  'unknown' | 'gated_off' | 'advertised_unconfirmed' | 'server_disabled' |
  'allowed_not_used' | 'in_use';

export interface DiagnosticRdpGraphicsFacts {
  evidenceVersion: number;
  evidenceLevel: RdpGraphicsEvidenceLevel;
  requestedMode: RdpRequestedGraphicsMode;
  presentation: RdpGraphicsPresentation;
  gfxChannelConnected: boolean;
  supportGraphicsPipeline: boolean;
  remoteFxCodec: boolean;
  h264Advertised: boolean;
  h264Compiled: boolean;
  h264PathSafe: boolean;
  fallbackConsumed: boolean;
  fallbackReason: RdpGfxFallbackReason;
  capsAdvertisedCount: number;
  capsAdvertisedMaxVersion: RdpGfxCapsVersion;
  capsConfirmed: boolean;
  capsConfirmedVersion: RdpGfxCapsVersion;
  capsConfirmedAvc: boolean;
  wireCodec: RdpGfxWireCodec;
  wireCodecMask: number;
  surfaceCommands: number;
  avcSurfaceCommands: number;
  wireBytes: number;
  copiedBytes: number;
  h264Status: RdpH264Status;
}

export const RDP_GRAPHICS_EVIDENCE_VERSION: number = 1;

const REQUESTED_MODES: RdpRequestedGraphicsMode[] = ['unknown', 'gdi', 'gfx', 'gfx-h264'];
const PRESENTATIONS: RdpGraphicsPresentation[] = ['unknown', 'gdi_bgra', 'gfx_gdi_consumer'];
const WIRE_CODECS: RdpGfxWireCodec[] = [
  'none', 'uncompressed', 'av1', 'remotefx', 'clearcodec', 'progressive', 'planar',
  'avc420', 'alpha', 'progressive_v2', 'avc444', 'avc444v2', 'unknown'
];
const CAPS_VERSIONS: RdpGfxCapsVersion[] = [
  'unknown', '8.0', '8.1', '10.0', '10.1', '10.2', '10.3', '10.4', '10.5',
  '10.6', '10.6-err', '10.7', '11.1', '11.2', '11.3', 'freerdp-1'
];
const FALLBACK_REASONS: RdpGfxFallbackReason[] = [
  'none', 'gfx-gdi-missing', 'gfx-gdi-mode', 'gfx-owner-missing',
  'gfx-channel-conflict', 'gfx-init-failed', 'resize-rejected', 'resize-failed', 'unknown'
];
const EVIDENCE_LEVELS: RdpGraphicsEvidenceLevel[] = ['missing', 'configured', 'observed_native'];
const H264_STATUSES: RdpH264Status[] = [
  'unknown', 'gated_off', 'advertised_unconfirmed', 'server_disabled',
  'allowed_not_used', 'in_use'
];

function counter(value: number | undefined): number {
  return value !== undefined && Number.isSafeInteger(value) && value >= 0 ? value : 0;
}

function closed<T>(value: string | undefined, allowed: T[], fallback: T): T {
  if (value === undefined) { return fallback; }
  return allowed.indexOf(value as T) >= 0 ? value as T : fallback;
}

export function emptyDiagnosticRdpGraphicsFacts(): DiagnosticRdpGraphicsFacts {
  return {
    evidenceVersion: RDP_GRAPHICS_EVIDENCE_VERSION, evidenceLevel: 'missing',
    requestedMode: 'unknown', presentation: 'unknown', gfxChannelConnected: false,
    supportGraphicsPipeline: false, remoteFxCodec: false, h264Advertised: false,
    h264Compiled: false, h264PathSafe: false, fallbackConsumed: false,
    fallbackReason: 'none', capsAdvertisedCount: 0, capsAdvertisedMaxVersion: 'unknown',
    capsConfirmed: false, capsConfirmedVersion: 'unknown', capsConfirmedAvc: false,
    wireCodec: 'none', wireCodecMask: 0, surfaceCommands: 0, avcSurfaceCommands: 0,
    wireBytes: 0, copiedBytes: 0, h264Status: 'unknown'
  };
}

export function rdpH264Status(facts: DiagnosticRdpGraphicsFacts): RdpH264Status {
  if (facts.evidenceLevel === 'missing') { return 'unknown'; }
  if (facts.avcSurfaceCommands > 0) { return 'in_use'; }
  if (!facts.h264Advertised) { return 'gated_off'; }
  if (!facts.capsConfirmed) { return 'advertised_unconfirmed'; }
  return facts.capsConfirmedAvc ? 'allowed_not_used' : 'server_disabled';
}

/** Maps native render stats into exportable, address-free graphics facts. */
export function rdpGraphicsFactsFromRenderStats(stats: RdpRenderStats): DiagnosticRdpGraphicsFacts {
  const facts: DiagnosticRdpGraphicsFacts = emptyDiagnosticRdpGraphicsFacts();
  const gfx: RdpGfxEvidenceStats | undefined = stats.gfxEvidence;
  facts.requestedMode = closed<RdpRequestedGraphicsMode>(stats.graphicsMode, REQUESTED_MODES, 'unknown');
  facts.gfxChannelConnected = stats.gfxChannelConnected === true;
  facts.copiedBytes = counter(stats.copiedBytes);
  if (gfx !== undefined) {
    facts.supportGraphicsPipeline = gfx.supportGraphicsPipeline === true;
    facts.remoteFxCodec = gfx.remoteFxCodec === true;
    facts.h264Advertised = gfx.h264Advertised === true;
    facts.h264Compiled = gfx.compiledH264 === true;
    facts.h264PathSafe = gfx.h264PathSafe === true;
    facts.fallbackConsumed = gfx.fallbackConsumed === true;
    facts.fallbackReason = facts.fallbackConsumed ?
      closed<RdpGfxFallbackReason>(gfx.fallbackReason, FALLBACK_REASONS, 'unknown') : 'none';
    facts.capsAdvertisedCount = counter(gfx.capsAdvertisedCount);
    facts.capsAdvertisedMaxVersion =
      closed<RdpGfxCapsVersion>(gfx.capsAdvertisedMaxVersion, CAPS_VERSIONS, 'unknown');
    facts.capsConfirmed = gfx.capsConfirmed === true;
    facts.capsConfirmedVersion = facts.capsConfirmed ?
      closed<RdpGfxCapsVersion>(gfx.capsConfirmedVersion, CAPS_VERSIONS, 'unknown') : 'unknown';
    facts.capsConfirmedAvc = facts.capsConfirmed && gfx.capsConfirmedAvc === true;
    facts.surfaceCommands = counter(gfx.surfaceCommands);
    facts.avcSurfaceCommands = Math.min(counter(gfx.avcSurfaceCommands), facts.surfaceCommands);
    facts.wireBytes = counter(gfx.surfaceCommandBytes);
    facts.wireCodecMask = counter(gfx.wireCodecMask) & 0xFFFF;
    // Commands carrying only out-of-catalog codec ids still prove GFX frames
    // arrived; they map to 'unknown', never to 'none'.
    const wireCodec: RdpGfxWireCodec = closed<RdpGfxWireCodec>(gfx.wireCodec, WIRE_CODECS, 'unknown');
    facts.wireCodec = facts.surfaceCommands > 0 ? (wireCodec === 'none' ? 'unknown' : wireCodec) : 'none';
    if (facts.capsConfirmed || facts.surfaceCommands > 0) {
      facts.evidenceLevel = 'observed_native';
    } else if (gfx.requestedApplied === true) {
      facts.evidenceLevel = 'configured';
    }
  }
  if (facts.gfxChannelConnected) {
    facts.presentation = 'gfx_gdi_consumer';
  } else if (facts.evidenceLevel !== 'missing' || facts.requestedMode !== 'unknown') {
    facts.presentation = 'gdi_bgra';
  }
  facts.h264Status = rdpH264Status(facts);
  return facts;
}

export function diagnosticRdpGraphicsFactsAreValid(facts: DiagnosticRdpGraphicsFacts): boolean {
  if (facts.evidenceVersion !== RDP_GRAPHICS_EVIDENCE_VERSION ||
    EVIDENCE_LEVELS.indexOf(facts.evidenceLevel) < 0 ||
    REQUESTED_MODES.indexOf(facts.requestedMode) < 0 ||
    PRESENTATIONS.indexOf(facts.presentation) < 0 ||
    FALLBACK_REASONS.indexOf(facts.fallbackReason) < 0 ||
    CAPS_VERSIONS.indexOf(facts.capsAdvertisedMaxVersion) < 0 ||
    CAPS_VERSIONS.indexOf(facts.capsConfirmedVersion) < 0 ||
    WIRE_CODECS.indexOf(facts.wireCodec) < 0 ||
    H264_STATUSES.indexOf(facts.h264Status) < 0) { return false; }
  const booleans: boolean[] = [facts.gfxChannelConnected, facts.supportGraphicsPipeline,
    facts.remoteFxCodec, facts.h264Advertised, facts.h264Compiled, facts.h264PathSafe,
    facts.fallbackConsumed, facts.capsConfirmed, facts.capsConfirmedAvc];
  for (let index: number = 0; index < booleans.length; index++) {
    if (typeof booleans[index] !== 'boolean') { return false; }
  }
  const numbers: number[] = [facts.capsAdvertisedCount, facts.wireCodecMask,
    facts.surfaceCommands, facts.avcSurfaceCommands, facts.wireBytes, facts.copiedBytes];
  for (let index: number = 0; index < numbers.length; index++) {
    if (!Number.isSafeInteger(numbers[index]) || numbers[index] < 0) { return false; }
  }
  if (facts.wireCodecMask > 0xFFFF || facts.avcSurfaceCommands > facts.surfaceCommands) {
    return false;
  }
  // A codec name is evidence only when surface commands were observed.
  if ((facts.surfaceCommands === 0) !== (facts.wireCodec === 'none')) { return false; }
  if (!facts.capsConfirmed && (facts.capsConfirmedAvc || facts.capsConfirmedVersion !== 'unknown')) {
    return false;
  }
  if (!facts.fallbackConsumed && facts.fallbackReason !== 'none') { return false; }
  if (facts.evidenceLevel !== 'observed_native' &&
    (facts.capsConfirmed || facts.surfaceCommands > 0)) { return false; }
  return facts.h264Status === rdpH264Status(facts);
}

export function copyDiagnosticRdpGraphicsFacts(
  facts: DiagnosticRdpGraphicsFacts): DiagnosticRdpGraphicsFacts {
  return {
    evidenceVersion: facts.evidenceVersion, evidenceLevel: facts.evidenceLevel,
    requestedMode: facts.requestedMode, presentation: facts.presentation,
    gfxChannelConnected: facts.gfxChannelConnected,
    supportGraphicsPipeline: facts.supportGraphicsPipeline,
    remoteFxCodec: facts.remoteFxCodec, h264Advertised: facts.h264Advertised,
    h264Compiled: facts.h264Compiled, h264PathSafe: facts.h264PathSafe,
    fallbackConsumed: facts.fallbackConsumed, fallbackReason: facts.fallbackReason,
    capsAdvertisedCount: facts.capsAdvertisedCount,
    capsAdvertisedMaxVersion: facts.capsAdvertisedMaxVersion,
    capsConfirmed: facts.capsConfirmed, capsConfirmedVersion: facts.capsConfirmedVersion,
    capsConfirmedAvc: facts.capsConfirmedAvc, wireCodec: facts.wireCodec,
    wireCodecMask: facts.wireCodecMask, surfaceCommands: facts.surfaceCommands,
    avcSurfaceCommands: facts.avcSurfaceCommands, wireBytes: facts.wireBytes,
    copiedBytes: facts.copiedBytes, h264Status: facts.h264Status
  };
}

const FACT_KEYS: string[] = [
  'evidenceVersion', 'evidenceLevel', 'requestedMode', 'presentation',
  'gfxChannelConnected', 'supportGraphicsPipeline', 'remoteFxCodec', 'h264Advertised',
  'h264Compiled', 'h264PathSafe', 'fallbackConsumed', 'fallbackReason',
  'capsAdvertisedCount', 'capsAdvertisedMaxVersion', 'capsConfirmed',
  'capsConfirmedVersion', 'capsConfirmedAvc', 'wireCodec', 'wireCodecMask',
  'surfaceCommands', 'avcSurfaceCommands', 'wireBytes', 'copiedBytes', 'h264Status'
];

/** Strict JSONL parser; unknown keys or out-of-catalog values are rejected. */
export function parseDiagnosticRdpGraphicsFacts(value: Object): DiagnosticRdpGraphicsFacts | null {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) { return null; }
  const source: Record<string, Object> = value as Record<string, Object>;
  const keys: string[] = Object.keys(source).sort();
  const expected: string[] = FACT_KEYS.slice().sort();
  if (keys.length !== expected.length) { return null; }
  for (let index: number = 0; index < keys.length; index++) {
    if (keys[index] !== expected[index]) { return null; }
  }
  const facts: DiagnosticRdpGraphicsFacts = {
    evidenceVersion: source['evidenceVersion'] as number,
    evidenceLevel: source['evidenceLevel'] as RdpGraphicsEvidenceLevel,
    requestedMode: source['requestedMode'] as RdpRequestedGraphicsMode,
    presentation: source['presentation'] as RdpGraphicsPresentation,
    gfxChannelConnected: source['gfxChannelConnected'] as boolean,
    supportGraphicsPipeline: source['supportGraphicsPipeline'] as boolean,
    remoteFxCodec: source['remoteFxCodec'] as boolean,
    h264Advertised: source['h264Advertised'] as boolean,
    h264Compiled: source['h264Compiled'] as boolean,
    h264PathSafe: source['h264PathSafe'] as boolean,
    fallbackConsumed: source['fallbackConsumed'] as boolean,
    fallbackReason: source['fallbackReason'] as RdpGfxFallbackReason,
    capsAdvertisedCount: source['capsAdvertisedCount'] as number,
    capsAdvertisedMaxVersion: source['capsAdvertisedMaxVersion'] as RdpGfxCapsVersion,
    capsConfirmed: source['capsConfirmed'] as boolean,
    capsConfirmedVersion: source['capsConfirmedVersion'] as RdpGfxCapsVersion,
    capsConfirmedAvc: source['capsConfirmedAvc'] as boolean,
    wireCodec: source['wireCodec'] as RdpGfxWireCodec,
    wireCodecMask: source['wireCodecMask'] as number,
    surfaceCommands: source['surfaceCommands'] as number,
    avcSurfaceCommands: source['avcSurfaceCommands'] as number,
    wireBytes: source['wireBytes'] as number,
    copiedBytes: source['copiedBytes'] as number,
    h264Status: source['h264Status'] as RdpH264Status
  };
  return diagnosticRdpGraphicsFactsAreValid(facts) ? facts : null;
}

/** Short HUD labels; they never claim H.264 from the requested mode alone. */
export function rdpWireCodecLabel(facts: DiagnosticRdpGraphicsFacts): string {
  switch (facts.wireCodec) {
    case 'none': return facts.gfxChannelConnected ? '等待首个 GFX 帧' : '无 GFX 帧（GDI 位图）';
    case 'remotefx': return 'RemoteFX';
    case 'progressive': return 'RemoteFX Progressive';
    case 'progressive_v2': return 'RemoteFX Progressive v2';
    case 'avc420': return 'H.264 AVC420';
    case 'avc444': return 'H.264 AVC444';
    case 'avc444v2': return 'H.264 AVC444v2';
    case 'planar': return 'Planar';
    case 'clearcodec': return 'ClearCodec';
    case 'uncompressed': return '未压缩';
    case 'alpha': return 'Alpha';
    case 'av1': return 'AV1';
    default: return '未知编码';
  }
}

export function rdpGraphicsPresentationLabel(facts: DiagnosticRdpGraphicsFacts): string {
  if (facts.presentation === 'gfx_gdi_consumer') { return 'GFX 已连接'; }
  if (facts.presentation === 'gdi_bgra') {
    return facts.fallbackConsumed ? 'GFX 未连接（本次回退 GDI）' : 'GFX 未连接（GDI 呈现）';
  }
  return '未上报';
}

export function rdpH264StatusLabel(facts: DiagnosticRdpGraphicsFacts): string {
  switch (facts.h264Status) {
    case 'in_use': return '正在使用';
    case 'gated_off': return '客户端未通告（门禁关闭）';
    case 'advertised_unconfirmed': return '已通告，等待服务端确认';
    case 'server_disabled': return '服务端确认不使用';
    case 'allowed_not_used': return '服务端允许，尚未使用';
    default: return '未上报';
  }
}

export function rdpGfxCapsLabel(facts: DiagnosticRdpGraphicsFacts): string {
  const advertised: string = facts.capsAdvertisedCount > 0 ?
    facts.capsAdvertisedCount.toString() + ' 组/最高 ' + facts.capsAdvertisedMaxVersion : '未通告';
  const confirmed: string = facts.capsConfirmed ? facts.capsConfirmedVersion : '未确认';
  return advertised + ' → ' + confirmed;
}

/**
 * Fields whose change is a negotiation transition worth an event: evidence
 * level, presentation, confirmed caps, wire codec, H.264 status and fallback.
 * Counters are deliberately excluded so steady streaming records nothing.
 */
export function rdpGraphicsTransitionSignature(facts: DiagnosticRdpGraphicsFacts): string {
  return [facts.evidenceLevel, facts.requestedMode, facts.presentation, facts.capsConfirmedVersion,
    facts.wireCodec, facts.wireCodecMask, facts.h264Status, facts.fallbackReason].join('|');
}

/** Event code: 1 configured only, 2 caps confirmed, 3 wire codec observed, 4 H.264 in use. */
export function rdpGraphicsTransitionCode(facts: DiagnosticRdpGraphicsFacts): number {
  if (facts.h264Status === 'in_use') { return 4; }
  if (facts.wireCodec !== 'none') { return 3; }
  if (facts.capsConfirmed) { return 2; }
  return facts.evidenceLevel === 'missing' ? 0 : 1;
}
