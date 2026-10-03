import { VideoDiagnosticEvidence, copyVideoDiagnosticEvidence, parseVideoDiagnosticEvidence } from './VideoDiagnosticEvidence';
import {
  EndpointAddressResult,
  parseEndpointAuthority,
  parseEndpointFields
} from './EndpointAddressPolicy';

export type DiagnosticModuleId =
  'core.app' |
  'connection.rdp' |
  'connection.rustdesk' |
  'connection.ssh_sftp' |
  'connection.vnc' |
  'connection.moonlight' |
  'data.cloud_sync' |
  'data.local_store' |
  'network.routing' |
  'security.ssh_key' |
  'core.account' |
  'core.ai';

export type DiagnosticEventLevel = 'info' | 'warn' | 'error';

export type DiagnosticOutcome =
  'started' |
  'succeeded' |
  'failed' |
  'cancelled' |
  'timeout' |
  'skipped' |
  'retry' |
  'state';

export type DiagnosticStopReason = 'manual' | 'deadline';

export type DiagnosticRuntimeState =
  'unknown' | 'connecting' | 'connected' | 'recovering' |
  'stopping' | 'disconnected' | 'failed';

export type DiagnosticRuntimeBackend =
  'unknown' | 'hardware' | 'software' | 'gdi' | 'raw' | 'zrle' |
  'copyrect' | 'native' | 'terminal';

export type DiagnosticRuntimeCodec =
  'unknown' | 'h264' | 'h265' | 'vp8' | 'vp9' | 'av1' | 'raw';

export type DiagnosticRuntimePath =
  'unknown' | 'direct' | 'relay' | 'gateway' | 'proxy';

export type DiagnosticPeerPlatform =
  'unknown' | 'windows' | 'macos' | 'linux' | 'android' | 'ios' | 'other';

export type DiagnosticPresentation =
  'unknown' | 'identity' | 'producer' | 'validated_producer' |
  'vertical_flip_producer' | 'top_left_producer';

export type DiagnosticProducerTransform =
  'unknown' | 'not_sampled' | 'identity' | 'flip_x' | 'flip_y' |
  'rotate_90' | 'rotate_180' | 'rotate_270' | 'transpose' | 'transverse' |
  'other' | 'read_failed';

/** Redacted window orientation values used by the app-level request trace. */
export type DiagnosticWindowOrientation =
  'unknown' | 'unspecified' | 'landscape' | 'portrait' |
  'portrait_inverted' | 'landscape_inverted' | 'auto_rotation' |
  'auto_rotation_portrait' | 'auto_rotation_landscape' |
  'auto_rotation_restricted' | 'auto_rotation_portrait_restricted' |
  'auto_rotation_landscape_restricted' | 'locked' | 'auto_rotation_unspecified' |
  'user_rotation_portrait' | 'user_rotation_landscape' |
  'user_rotation_portrait_inverted' | 'user_rotation_landscape_inverted' |
  'follow_desktop';

export type DiagnosticWindowRequestPhase =
  'idle' | 'queued' | 'started' | 'succeeded' | 'failed' | 'superseded';

export type DiagnosticAppLifecycle =
  'unknown' | 'foreground' | 'background' | 'pip' | 'split';

/**
 * Window facts are deliberately separate from video transform facts. A
 * renderer rotation cannot prove which preferred orientation was requested
 * from the OS window manager, so both are captured independently.
 */
export interface DiagnosticWindowFacts {
  requestedOrientation: DiagnosticWindowOrientation;
  /** The orientation value accepted by the WMS request; API 26 has no readback. */
  appliedOrientation: DiagnosticWindowOrientation;
  requestPhase: DiagnosticWindowRequestPhase;
  appLifecycle: DiagnosticAppLifecycle;
  requestGeneration: number;
  windowGeneration: number;
  width: number;
  height: number;
  displayRotation: number;
  isLandscape: boolean;
  orientationApplied: boolean;
  rotationSwitchControlled: boolean;
}

/**
 * Protocol counters are kept in one closed, numeric shape so a runtime
 * snapshot cannot silently lose a native counter at the export boundary.
 */
export interface DiagnosticProtocolFacts {
  supported: boolean;
  sessionActive: boolean;
  snapshotAvailable: boolean;
  videoSeen: boolean;
  inputPermissionKnown: boolean;
  inputAllowed: boolean;
  clipboardPermissionKnown: boolean;
  clipboardAllowed: boolean;
  filePermissionKnown: boolean;
  fileAllowed: boolean;
  targetBitrateKbps: number;
  requestedQuality: number;
  effectiveQuality: number;
  sentQuality: number;
  qualityProfile: number;
  qualityFps: number;
  qualityRequestedGeneration: number;
  qualityAppliedGeneration: number;
  qualityUpdateStatus: number;
  messages: number;
  receivedFrames: number;
  keyframes: number;
  receivedBytes: number;
  audioFrames: number;
  cadenceGaps: number;
  maxCadenceGapMs: number;
  testDelayCount: number;
  receivedFps: number;
  displayFps: number;
  decodeFps: number;
  bitrateKbps: number;
  lastFrameAgeMs: number;
  lastPresentedFrameAgeMs: number;
  decodeOk: number;
  decodeErrors: number;
  decodeP50Us: number;
  decodeP95Us: number;
  decodeMaxUs: number;
  presentedFrames: number;
  presentationRejected: number;
  lastDirtyX: number;
  lastDirtyY: number;
  lastDirtyWidth: number;
  lastDirtyHeight: number;
  requestedColorDepthCode: number;
  effectiveColorDepth: number;
  inputEventsSent: number;
  inputEventsDropped: number;
  presentationWindowSamples: number;
  presentationWindowMs: number;
  renderP50Us: number;
  renderP95Us: number;
  renderMaxUs: number;
  queueMax: number;
  droppedFrames: number;
  inputBytes: number;
  writeBytes: number;
  readBytes: number;
  callbackBytes: number;
  inputQueueBytes: number;
  inputQueueMaxBytes: number;
  inputReorder: number;
  ownerStallEvents: number;
  coverageMask: number;
  coverageComplete: boolean;
  lastInputSequence: number;
  maxInputToWriteAttemptNs: number;
  maxInputToWriteCompleteNs: number;
}

export interface DiagnosticResourceFacts {
  supported: boolean;
  cpuAvailable: boolean;
  cpuPercent: number;
  memoryAvailable: boolean;
  memoryBytes: number;
  gpuAvailable: boolean;
  gpuPercent: number;
  sampledAtMs: number;
}

export type DiagnosticAddressFamily =
  'unknown' | 'hostname' | 'ipv4' | 'ipv6' | 'mixed';

/** Closed, address-free network metadata safe for exported diagnostics. */
export interface DiagnosticNetworkFacts {
  configuredEndpointFamily: DiagnosticAddressFamily;
  configuredRouteFamily: DiagnosticAddressFamily;
  hostnameCandidate: boolean;
  ipv4Candidate: boolean;
  ipv6Candidate: boolean;
  scopedIpv6: boolean;
}

export interface DiagnosticRuntimeFacts {
  video?: VideoDiagnosticEvidence;
  state: DiagnosticRuntimeState;
  backend: DiagnosticRuntimeBackend;
  codec: DiagnosticRuntimeCodec;
  path: DiagnosticRuntimePath;
  peerPlatform: DiagnosticPeerPlatform;
  presentation: DiagnosticPresentation;
  producerTransform: DiagnosticProducerTransform;
  appliedTransform: DiagnosticProducerTransform;
  desktopSurfaceCompatibility: boolean;
  producerTransformSampled: boolean;
  producerTransformReadResult: number;
  producerTransformSamples: number;
  producerTransformChanges: number;
  producerTransformReadFailures: number;
  producerTransformClassMask: number;
  producerTransformMatrix: number[];
  appliedTextureTransform: number[];
  rendererTransformValid: boolean;
  rendererTransformVersion: number;
  rendererRotationQuarterTurns: number;
  rendererFlipX: boolean;
  rendererFlipY: boolean;
  decoderGeneration: number;
  rendererGeneration: number;
  width: number;
  height: number;
  frames: number;
  dropped: number;
  errors: number;
  queueDepth: number;
  latencyMs: number;
  protocol: DiagnosticProtocolFacts;
  resources: DiagnosticResourceFacts;
}

export interface DiagnosticModuleSpec {
  id: DiagnosticModuleId;
  label: string;
  alwaysEnabled: boolean;
}

export interface DiagnosticEventSpec {
  moduleId: DiagnosticModuleId;
  eventCode: string;
}

/** A capture profile is part of the exported contract, not a UI-only flag. */
export type DiagnosticCaptureProfile = 'selected' | 'full';

export const DIAGNOSTIC_CAPTURE_SCHEMA_VERSION: number = 8;
export const DIAGNOSTIC_EVENT_CATALOG_VERSION: number = 2;
export const DIAGNOSTIC_REDACTION_POLICY_VERSION: number = 3;
export const DIAGNOSTIC_DEFAULT_DURATION_MINUTES: number = 10;
export const DIAGNOSTIC_MAX_EVENTS: number = 10000;
export const DIAGNOSTIC_MAX_EVENT_BYTES: number = 8192;
export const DIAGNOSTIC_MAX_CAPTURE_BYTES: number = 8 * 1024 * 1024;
export const DIAGNOSTIC_MAX_EXPORT_BYTES: number = 12 * 1024 * 1024;
export const DIAGNOSTIC_MAX_SESSION_REFS: number = 512;

const DIAGNOSTIC_DURATIONS: number[] = [1, 3, 5, 10, 15, 30];

const DIAGNOSTIC_MODULES: DiagnosticModuleSpec[] = [
  { id: 'core.app', label: '应用状态', alwaysEnabled: true },
  { id: 'connection.rdp', label: 'RDP 连接', alwaysEnabled: false },
  { id: 'connection.rustdesk', label: 'RustDesk 连接', alwaysEnabled: false },
  { id: 'connection.ssh_sftp', label: 'SSH / SFTP', alwaysEnabled: false },
  { id: 'connection.vnc', label: 'VNC 连接', alwaysEnabled: false },
  { id: 'connection.moonlight', label: 'Moonlight 串流', alwaysEnabled: false },
  { id: 'data.cloud_sync', label: '云同步', alwaysEnabled: false },
  { id: 'data.local_store', label: '本地数据库', alwaysEnabled: false },
  { id: 'network.routing', label: '中继与网关', alwaysEnabled: false },
  { id: 'security.ssh_key', label: 'SSH 密钥对', alwaysEnabled: false },
  { id: 'core.account', label: '账号与登录', alwaysEnabled: false },
  { id: 'core.ai', label: 'AI 助手', alwaysEnabled: false }
];

const DIAGNOSTIC_OUTCOMES: DiagnosticOutcome[] = [
  'started', 'succeeded', 'failed', 'cancelled',
  'timeout', 'skipped', 'retry', 'state'
];

const DIAGNOSTIC_EVENTS: DiagnosticEventSpec[] = [
  { moduleId: 'core.app', eventCode: 'capture_started' },
  { moduleId: 'core.app', eventCode: 'capture_stopped' },
  { moduleId: 'core.app', eventCode: 'capture_expired' },
  { moduleId: 'core.app', eventCode: 'app_lifecycle' },
  { moduleId: 'core.app', eventCode: 'window_orientation_request' },
  { moduleId: 'core.app', eventCode: 'window_orientation_state' },
  { moduleId: 'core.app', eventCode: 'app_fault_history' },
  { moduleId: 'core.app', eventCode: 'app_exception' },

  { moduleId: 'connection.rdp', eventCode: 'rdp_connection_request' },
  { moduleId: 'connection.rdp', eventCode: 'rdp_preflight' },
  { moduleId: 'connection.rdp', eventCode: 'rdp_state_changed' },
  { moduleId: 'connection.rdp', eventCode: 'rdp_runtime_snapshot' },
  { moduleId: 'connection.rdp', eventCode: 'rdp_display_layout' },
  { moduleId: 'connection.rdp', eventCode: 'rdp_disconnect' },
  { moduleId: 'connection.rdp', eventCode: 'rdp_failure' },
  { moduleId: 'connection.rdp', eventCode: 'rdp_certificate' },
  { moduleId: 'connection.rdp', eventCode: 'rdp_clipboard' },
  { moduleId: 'connection.rdp', eventCode: 'rdp_drive' },
  { moduleId: 'connection.rdp', eventCode: 'rdp_audio' },

  { moduleId: 'connection.rustdesk', eventCode: 'rustdesk_presence' },
  { moduleId: 'connection.rustdesk', eventCode: 'rustdesk_preflight' },
  { moduleId: 'connection.rustdesk', eventCode: 'rustdesk_connection_request' },
  { moduleId: 'connection.rustdesk', eventCode: 'rustdesk_state_changed' },
  { moduleId: 'connection.rustdesk', eventCode: 'rustdesk_two_factor' },
  { moduleId: 'connection.rustdesk', eventCode: 'rustdesk_runtime_snapshot' },
  { moduleId: 'connection.rustdesk', eventCode: 'rustdesk_display_switch' },
  { moduleId: 'connection.rustdesk', eventCode: 'rustdesk_orientation_observation' },
  { moduleId: 'connection.rustdesk', eventCode: 'rustdesk_disconnect' },
  { moduleId: 'connection.rustdesk', eventCode: 'rustdesk_clipboard' },
  { moduleId: 'connection.rustdesk', eventCode: 'rustdesk_failure' },
  { moduleId: 'connection.rustdesk', eventCode: 'rustdesk_first_frame' },

  { moduleId: 'connection.ssh_sftp', eventCode: 'ssh_session_event' },
  { moduleId: 'connection.ssh_sftp', eventCode: 'ssh_preflight' },
  { moduleId: 'connection.ssh_sftp', eventCode: 'ssh_disconnect' },
  { moduleId: 'connection.ssh_sftp', eventCode: 'ssh_runtime_snapshot' },
  { moduleId: 'connection.ssh_sftp', eventCode: 'sftp_task_started' },
  { moduleId: 'connection.ssh_sftp', eventCode: 'sftp_task_completed' },
  { moduleId: 'connection.ssh_sftp', eventCode: 'ssh_failure' },
  { moduleId: 'connection.ssh_sftp', eventCode: 'sftp_failure' },

  { moduleId: 'connection.vnc', eventCode: 'vnc_connection_request' },
  { moduleId: 'connection.vnc', eventCode: 'vnc_preflight' },
  { moduleId: 'connection.vnc', eventCode: 'vnc_state_changed' },
  { moduleId: 'connection.vnc', eventCode: 'vnc_update_rejected' },
  { moduleId: 'connection.vnc', eventCode: 'vnc_update_progress' },
  { moduleId: 'connection.vnc', eventCode: 'vnc_runtime_snapshot' },
  { moduleId: 'connection.vnc', eventCode: 'vnc_disconnect' },
  { moduleId: 'connection.vnc', eventCode: 'vnc_failure' },

  { moduleId: 'connection.moonlight', eventCode: 'moonlight_pair' },
  { moduleId: 'connection.moonlight', eventCode: 'moonlight_catalog' },
  { moduleId: 'connection.moonlight', eventCode: 'moonlight_launch' },
  { moduleId: 'connection.moonlight', eventCode: 'moonlight_state_changed' },
  { moduleId: 'connection.moonlight', eventCode: 'moonlight_runtime_snapshot' },
  { moduleId: 'connection.moonlight', eventCode: 'moonlight_orientation_observation' },

  { moduleId: 'data.cloud_sync', eventCode: 'cloud_sync_requested' },
  { moduleId: 'data.cloud_sync', eventCode: 'cloud_sync_started' },
  { moduleId: 'data.cloud_sync', eventCode: 'cloud_sync_completed' },
  { moduleId: 'data.cloud_sync', eventCode: 'cloud_sync_retry' },
  { moduleId: 'data.cloud_sync', eventCode: 'cloud_sync_skipped' },

  { moduleId: 'data.local_store', eventCode: 'local_store_init' },
  { moduleId: 'data.local_store', eventCode: 'local_store_rebind' },
  { moduleId: 'data.local_store', eventCode: 'local_store_schema' },
  { moduleId: 'data.local_store', eventCode: 'local_store_mutation' },
  { moduleId: 'data.local_store', eventCode: 'local_backup_export' },
  { moduleId: 'data.local_store', eventCode: 'local_backup_restore' },

  { moduleId: 'network.routing', eventCode: 'routing_rdp_gateway' },
  { moduleId: 'network.routing', eventCode: 'routing_rustdesk_relay' },
  { moduleId: 'network.routing', eventCode: 'routing_rustdesk_pro' },
  { moduleId: 'network.routing', eventCode: 'routing_vnc_gateway' },
  { moduleId: 'network.routing', eventCode: 'routing_ssh_proxy' },
  { moduleId: 'network.routing', eventCode: 'routing_ssh_forwarding' },

  { moduleId: 'security.ssh_key', eventCode: 'ssh_key_generate' },
  { moduleId: 'security.ssh_key', eventCode: 'ssh_key_import' },
  { moduleId: 'security.ssh_key', eventCode: 'ssh_key_inspect' },
  { moduleId: 'security.ssh_key', eventCode: 'ssh_key_passphrase' },
  { moduleId: 'security.ssh_key', eventCode: 'ssh_key_store' },
  { moduleId: 'security.ssh_key', eventCode: 'ssh_key_delete' },
  { moduleId: 'security.ssh_key', eventCode: 'ssh_key_install' },
  { moduleId: 'security.ssh_key', eventCode: 'ssh_key_auth_test' },

  { moduleId: 'core.account', eventCode: 'account_login' },

  { moduleId: 'core.ai', eventCode: 'ai_request' },
  { moduleId: 'core.ai', eventCode: 'ai_config' },
  { moduleId: 'core.ai', eventCode: 'ai_setting' }
];

export function diagnosticDurationOptions(): number[] {
  return DIAGNOSTIC_DURATIONS.slice();
}

export function diagnosticDurationIsAllowed(minutes: number): boolean {
  return Number.isSafeInteger(minutes) && DIAGNOSTIC_DURATIONS.indexOf(minutes) >= 0;
}

export function diagnosticModuleSpecs(): DiagnosticModuleSpec[] {
  return DIAGNOSTIC_MODULES.map((spec: DiagnosticModuleSpec): DiagnosticModuleSpec => {
    return { id: spec.id, label: spec.label, alwaysEnabled: spec.alwaysEnabled };
  });
}

export function diagnosticModuleIsKnown(moduleId: string): boolean {
  for (let i: number = 0; i < DIAGNOSTIC_MODULES.length; i++) {
    if (DIAGNOSTIC_MODULES[i].id === moduleId) { return true; }
  }
  return false;
}

export function normalizeDiagnosticModules(moduleIds: string[]): DiagnosticModuleId[] {
  const normalized: DiagnosticModuleId[] = [];
  for (let i: number = 0; i < DIAGNOSTIC_MODULES.length; i++) {
    const spec: DiagnosticModuleSpec = DIAGNOSTIC_MODULES[i];
    if (spec.alwaysEnabled || moduleIds.indexOf(spec.id) >= 0) {
      normalized.push(spec.id);
    }
  }
  return normalized;
}

export function diagnosticAllModules(): DiagnosticModuleId[] {
  return normalizeDiagnosticModules(DIAGNOSTIC_MODULES.map(
    (spec: DiagnosticModuleSpec): string => spec.id));
}

export function diagnosticEventCatalogSize(): number {
  return DIAGNOSTIC_EVENTS.length;
}

export function diagnosticEventIsAllowed(moduleId: DiagnosticModuleId, eventCode: string): boolean {
  for (let i: number = 0; i < DIAGNOSTIC_EVENTS.length; i++) {
    const spec: DiagnosticEventSpec = DIAGNOSTIC_EVENTS[i];
    if (spec.moduleId === moduleId && spec.eventCode === eventCode) { return true; }
  }
  return false;
}

export function diagnosticOutcomeIsAllowed(outcome: string): boolean {
  return DIAGNOSTIC_OUTCOMES.indexOf(outcome as DiagnosticOutcome) >= 0;
}

export function diagnosticLevelForOutcome(outcome: DiagnosticOutcome): DiagnosticEventLevel {
  if (outcome === 'failed' || outcome === 'timeout') { return 'error'; }
  if (outcome === 'retry' || outcome === 'skipped' || outcome === 'cancelled') { return 'warn'; }
  return 'info';
}

export function diagnosticSafeInteger(value: number): number | null {
  if (!Number.isFinite(value) || !Number.isSafeInteger(value)) { return null; }
  const limit: number = Number.MAX_SAFE_INTEGER;
  return Math.max(-limit, Math.min(limit, value));
}

const DIAGNOSTIC_RUNTIME_STATES: DiagnosticRuntimeState[] = [
  'unknown', 'connecting', 'connected', 'recovering',
  'stopping', 'disconnected', 'failed'
];
const DIAGNOSTIC_RUNTIME_BACKENDS: DiagnosticRuntimeBackend[] = [
  'unknown', 'hardware', 'software', 'gdi', 'raw', 'zrle',
  'copyrect', 'native', 'terminal'
];
const DIAGNOSTIC_RUNTIME_CODECS: DiagnosticRuntimeCodec[] = [
  'unknown', 'h264', 'h265', 'vp8', 'vp9', 'av1', 'raw'
];
const DIAGNOSTIC_RUNTIME_PATHS: DiagnosticRuntimePath[] = [
  'unknown', 'direct', 'relay', 'gateway', 'proxy'
];
const DIAGNOSTIC_PEER_PLATFORMS: DiagnosticPeerPlatform[] = [
  'unknown', 'windows', 'macos', 'linux', 'android', 'ios', 'other'
];
const DIAGNOSTIC_PRESENTATIONS: DiagnosticPresentation[] = [
  'unknown', 'identity', 'producer', 'validated_producer',
  'vertical_flip_producer', 'top_left_producer'
];
const DIAGNOSTIC_PRODUCER_TRANSFORMS: DiagnosticProducerTransform[] = [
  'unknown', 'not_sampled', 'identity', 'flip_x', 'flip_y',
  'rotate_90', 'rotate_180', 'rotate_270', 'transpose', 'transverse',
  'other', 'read_failed'
];

const DIAGNOSTIC_WINDOW_ORIENTATIONS: DiagnosticWindowOrientation[] = [
  'unknown', 'unspecified', 'landscape', 'portrait', 'portrait_inverted',
  'landscape_inverted', 'auto_rotation', 'auto_rotation_portrait',
  'auto_rotation_landscape', 'auto_rotation_restricted',
  'auto_rotation_portrait_restricted', 'auto_rotation_landscape_restricted',
  'locked', 'auto_rotation_unspecified', 'user_rotation_portrait',
  'user_rotation_landscape', 'user_rotation_portrait_inverted',
  'user_rotation_landscape_inverted', 'follow_desktop'
];

const DIAGNOSTIC_WINDOW_REQUEST_PHASES: DiagnosticWindowRequestPhase[] = [
  'idle', 'queued', 'started', 'succeeded', 'failed', 'superseded'
];

const DIAGNOSTIC_APP_LIFECYCLES: DiagnosticAppLifecycle[] = [
  'unknown', 'foreground', 'background', 'pip', 'split'
];

export function emptyDiagnosticWindowFacts(): DiagnosticWindowFacts {
  return {
    requestedOrientation: 'unknown', appliedOrientation: 'unknown',
    requestPhase: 'idle', appLifecycle: 'unknown', requestGeneration: 0,
    windowGeneration: 0, width: 0, height: 0, displayRotation: 0,
    isLandscape: false, orientationApplied: false, rotationSwitchControlled: false
  };
}

export function diagnosticWindowFactsAreValid(facts: DiagnosticWindowFacts): boolean {
  if (DIAGNOSTIC_WINDOW_ORIENTATIONS.indexOf(facts.requestedOrientation) < 0 ||
    DIAGNOSTIC_WINDOW_ORIENTATIONS.indexOf(facts.appliedOrientation) < 0 ||
    DIAGNOSTIC_WINDOW_REQUEST_PHASES.indexOf(facts.requestPhase) < 0 ||
    DIAGNOSTIC_APP_LIFECYCLES.indexOf(facts.appLifecycle) < 0 ||
    typeof facts.isLandscape !== 'boolean' ||
    typeof facts.orientationApplied !== 'boolean' ||
    typeof facts.rotationSwitchControlled !== 'boolean') {
    return false;
  }
  const numbers: number[] = [facts.requestGeneration, facts.windowGeneration,
    facts.width, facts.height, facts.displayRotation];
  for (let index: number = 0; index < numbers.length; index++) {
    if (diagnosticSafeInteger(numbers[index]) === null || numbers[index] < 0) {
      return false;
    }
  }
  if (facts.displayRotation < 0 || facts.displayRotation > 3) { return false; }
  // A successful WMS request is useful evidence even when the window
  // properties API is temporarily unavailable during teardown. Only the
  // derived landscape bit requires a non-zero rectangle.
  if (facts.width === 0 || facts.height === 0) {
    if (facts.isLandscape) { return false; }
  }
  if (facts.width > 0 && facts.height > 0 && facts.isLandscape !== (facts.width >= facts.height)) {
    return false;
  }
  if (facts.requestPhase === 'idle' && facts.requestGeneration !== 0) { return false; }
  return true;
}

export function copyDiagnosticWindowFacts(
  facts: DiagnosticWindowFacts): DiagnosticWindowFacts {
  return {
    requestedOrientation: facts.requestedOrientation,
    appliedOrientation: facts.appliedOrientation,
    requestPhase: facts.requestPhase,
    appLifecycle: facts.appLifecycle,
    requestGeneration: facts.requestGeneration,
    windowGeneration: facts.windowGeneration,
    width: facts.width, height: facts.height, displayRotation: facts.displayRotation,
    isLandscape: facts.isLandscape,
    orientationApplied: facts.orientationApplied,
    rotationSwitchControlled: facts.rotationSwitchControlled
  };
}

function protocolCounterFields(facts: DiagnosticProtocolFacts): number[] {
  return [facts.targetBitrateKbps, facts.requestedQuality, facts.effectiveQuality,
    facts.sentQuality, facts.qualityProfile, facts.qualityFps,
    facts.qualityRequestedGeneration, facts.qualityAppliedGeneration,
    facts.qualityUpdateStatus, facts.messages, facts.receivedFrames, facts.keyframes,
    facts.receivedBytes, facts.audioFrames, facts.cadenceGaps, facts.maxCadenceGapMs,
    facts.testDelayCount, facts.receivedFps, facts.displayFps, facts.decodeFps,
    facts.bitrateKbps, facts.lastFrameAgeMs, facts.lastPresentedFrameAgeMs,
    facts.decodeOk, facts.decodeErrors, facts.decodeP50Us, facts.decodeP95Us,
    facts.decodeMaxUs, facts.presentedFrames, facts.presentationRejected,
    facts.lastDirtyX, facts.lastDirtyY, facts.lastDirtyWidth, facts.lastDirtyHeight,
    facts.requestedColorDepthCode, facts.effectiveColorDepth, facts.inputEventsSent,
    facts.inputEventsDropped, facts.presentationWindowSamples,
    facts.presentationWindowMs, facts.renderP50Us, facts.renderP95Us,
    facts.renderMaxUs, facts.queueMax, facts.droppedFrames, facts.inputBytes,
    facts.writeBytes, facts.readBytes, facts.callbackBytes, facts.inputQueueBytes,
    facts.inputQueueMaxBytes, facts.inputReorder, facts.ownerStallEvents,
    facts.coverageMask, facts.lastInputSequence, facts.maxInputToWriteAttemptNs,
    facts.maxInputToWriteCompleteNs];
}

export function emptyDiagnosticProtocolFacts(): DiagnosticProtocolFacts {
  return {
    supported: false, sessionActive: false, snapshotAvailable: false, videoSeen: false,
    inputPermissionKnown: false, inputAllowed: false,
    clipboardPermissionKnown: false, clipboardAllowed: false,
    filePermissionKnown: false, fileAllowed: false,
    targetBitrateKbps: 0, requestedQuality: 0, effectiveQuality: 0, sentQuality: 0,
    qualityProfile: 0, qualityFps: 0, qualityRequestedGeneration: 0,
    qualityAppliedGeneration: 0, qualityUpdateStatus: 0, messages: 0,
    receivedFrames: 0, keyframes: 0, receivedBytes: 0, audioFrames: 0,
    cadenceGaps: 0, maxCadenceGapMs: 0, testDelayCount: 0, receivedFps: 0,
    displayFps: 0, decodeFps: 0, bitrateKbps: 0, lastFrameAgeMs: 0,
    lastPresentedFrameAgeMs: 0, decodeOk: 0, decodeErrors: 0, decodeP50Us: 0,
    decodeP95Us: 0, decodeMaxUs: 0, presentedFrames: 0, presentationRejected: 0,
    lastDirtyX: 0, lastDirtyY: 0, lastDirtyWidth: 0, lastDirtyHeight: 0,
    requestedColorDepthCode: 0, effectiveColorDepth: 0, inputEventsSent: 0,
    inputEventsDropped: 0, presentationWindowSamples: 0, presentationWindowMs: 0,
    renderP50Us: 0, renderP95Us: 0, renderMaxUs: 0, queueMax: 0,
    droppedFrames: 0, inputBytes: 0, writeBytes: 0, readBytes: 0,
    callbackBytes: 0, inputQueueBytes: 0, inputQueueMaxBytes: 0,
    inputReorder: 0, ownerStallEvents: 0, coverageMask: 0, coverageComplete: false,
    lastInputSequence: 0, maxInputToWriteAttemptNs: 0, maxInputToWriteCompleteNs: 0
  };
}

export function emptyDiagnosticResourceFacts(): DiagnosticResourceFacts {
  return {
    supported: false, cpuAvailable: false, cpuPercent: 0,
    memoryAvailable: false, memoryBytes: 0, gpuAvailable: false, gpuPercent: 0,
    sampledAtMs: 0
  };
}

export function diagnosticProtocolFactsAreValid(facts: DiagnosticProtocolFacts): boolean {
  if (typeof facts.supported !== 'boolean' || typeof facts.sessionActive !== 'boolean' ||
    typeof facts.snapshotAvailable !== 'boolean' || typeof facts.videoSeen !== 'boolean' ||
    typeof facts.inputPermissionKnown !== 'boolean' || typeof facts.inputAllowed !== 'boolean' ||
    typeof facts.clipboardPermissionKnown !== 'boolean' || typeof facts.clipboardAllowed !== 'boolean' ||
    typeof facts.filePermissionKnown !== 'boolean' || typeof facts.fileAllowed !== 'boolean' ||
    typeof facts.coverageComplete !== 'boolean') { return false; }
  const numbers: number[] = protocolCounterFields(facts);
  for (let index: number = 0; index < numbers.length; index++) {
    if (diagnosticSafeInteger(numbers[index]) === null || numbers[index] < 0) { return false; }
  }
  return true;
}

export function diagnosticResourceFactsAreValid(facts: DiagnosticResourceFacts): boolean {
  if (typeof facts.supported !== 'boolean' || typeof facts.cpuAvailable !== 'boolean' ||
    typeof facts.memoryAvailable !== 'boolean' || typeof facts.gpuAvailable !== 'boolean') {
    return false;
  }
  const numbers: number[] = [facts.cpuPercent, facts.memoryBytes, facts.gpuPercent,
    facts.sampledAtMs];
  for (let index: number = 0; index < numbers.length; index++) {
    if (!Number.isFinite(numbers[index]) || numbers[index] < 0) { return false; }
  }
  if (facts.cpuPercent > 100 || facts.gpuPercent > 100) { return false; }
  return true;
}

export function copyDiagnosticProtocolFacts(
  facts: DiagnosticProtocolFacts): DiagnosticProtocolFacts {
  return {
    supported: facts.supported, sessionActive: facts.sessionActive,
    snapshotAvailable: facts.snapshotAvailable, videoSeen: facts.videoSeen,
    inputPermissionKnown: facts.inputPermissionKnown, inputAllowed: facts.inputAllowed,
    clipboardPermissionKnown: facts.clipboardPermissionKnown,
    clipboardAllowed: facts.clipboardAllowed,
    filePermissionKnown: facts.filePermissionKnown, fileAllowed: facts.fileAllowed,
    targetBitrateKbps: facts.targetBitrateKbps, requestedQuality: facts.requestedQuality,
    effectiveQuality: facts.effectiveQuality, sentQuality: facts.sentQuality,
    qualityProfile: facts.qualityProfile, qualityFps: facts.qualityFps,
    qualityRequestedGeneration: facts.qualityRequestedGeneration,
    qualityAppliedGeneration: facts.qualityAppliedGeneration,
    qualityUpdateStatus: facts.qualityUpdateStatus, messages: facts.messages,
    receivedFrames: facts.receivedFrames, keyframes: facts.keyframes,
    receivedBytes: facts.receivedBytes, audioFrames: facts.audioFrames,
    cadenceGaps: facts.cadenceGaps, maxCadenceGapMs: facts.maxCadenceGapMs,
    testDelayCount: facts.testDelayCount, receivedFps: facts.receivedFps,
    displayFps: facts.displayFps, decodeFps: facts.decodeFps,
    bitrateKbps: facts.bitrateKbps, lastFrameAgeMs: facts.lastFrameAgeMs,
    lastPresentedFrameAgeMs: facts.lastPresentedFrameAgeMs, decodeOk: facts.decodeOk,
    decodeErrors: facts.decodeErrors, decodeP50Us: facts.decodeP50Us,
    decodeP95Us: facts.decodeP95Us, decodeMaxUs: facts.decodeMaxUs,
    presentedFrames: facts.presentedFrames, presentationRejected: facts.presentationRejected,
    lastDirtyX: facts.lastDirtyX, lastDirtyY: facts.lastDirtyY,
    lastDirtyWidth: facts.lastDirtyWidth, lastDirtyHeight: facts.lastDirtyHeight,
    requestedColorDepthCode: facts.requestedColorDepthCode,
    effectiveColorDepth: facts.effectiveColorDepth,
    inputEventsSent: facts.inputEventsSent, inputEventsDropped: facts.inputEventsDropped,
    presentationWindowSamples: facts.presentationWindowSamples,
    presentationWindowMs: facts.presentationWindowMs, renderP50Us: facts.renderP50Us,
    renderP95Us: facts.renderP95Us, renderMaxUs: facts.renderMaxUs,
    queueMax: facts.queueMax, droppedFrames: facts.droppedFrames,
    inputBytes: facts.inputBytes, writeBytes: facts.writeBytes,
    readBytes: facts.readBytes, callbackBytes: facts.callbackBytes,
    inputQueueBytes: facts.inputQueueBytes, inputQueueMaxBytes: facts.inputQueueMaxBytes,
    inputReorder: facts.inputReorder, ownerStallEvents: facts.ownerStallEvents,
    coverageMask: facts.coverageMask, coverageComplete: facts.coverageComplete,
    lastInputSequence: facts.lastInputSequence,
    maxInputToWriteAttemptNs: facts.maxInputToWriteAttemptNs,
    maxInputToWriteCompleteNs: facts.maxInputToWriteCompleteNs
  };
}

export function copyDiagnosticResourceFacts(
  facts: DiagnosticResourceFacts): DiagnosticResourceFacts {
  return {
    supported: facts.supported, cpuAvailable: facts.cpuAvailable,
    cpuPercent: facts.cpuPercent, memoryAvailable: facts.memoryAvailable,
    memoryBytes: facts.memoryBytes, gpuAvailable: facts.gpuAvailable,
    gpuPercent: facts.gpuPercent, sampledAtMs: facts.sampledAtMs
  };
}

export function emptyDiagnosticRuntimeFacts(): DiagnosticRuntimeFacts {
  return {
    state: 'unknown', backend: 'unknown', codec: 'unknown', path: 'unknown',
    peerPlatform: 'unknown', presentation: 'unknown', producerTransform: 'unknown',
    appliedTransform: 'unknown', desktopSurfaceCompatibility: false,
    producerTransformSampled: false, producerTransformReadResult: 0,
    producerTransformSamples: 0, producerTransformChanges: 0,
    producerTransformReadFailures: 0, producerTransformClassMask: 0,
    producerTransformMatrix: [], appliedTextureTransform: [],
    rendererTransformValid: false, rendererTransformVersion: 0,
    rendererRotationQuarterTurns: 0, rendererFlipX: false, rendererFlipY: false,
    decoderGeneration: 0, rendererGeneration: 0,
    width: 0, height: 0, frames: 0, dropped: 0, errors: 0,
    queueDepth: 0, latencyMs: 0,
    protocol: emptyDiagnosticProtocolFacts(), resources: emptyDiagnosticResourceFacts()
  };
}

export function diagnosticRuntimeFactsAreValid(facts: DiagnosticRuntimeFacts): boolean {
  if (facts.video !== undefined && parseVideoDiagnosticEvidence(facts.video) === null) { return false; }
  if (!diagnosticProtocolFactsAreValid(facts.protocol) ||
    !diagnosticResourceFactsAreValid(facts.resources)) { return false; }
  if (DIAGNOSTIC_RUNTIME_STATES.indexOf(facts.state) < 0 ||
    DIAGNOSTIC_RUNTIME_BACKENDS.indexOf(facts.backend) < 0 ||
    DIAGNOSTIC_RUNTIME_CODECS.indexOf(facts.codec) < 0 ||
    DIAGNOSTIC_RUNTIME_PATHS.indexOf(facts.path) < 0 ||
    DIAGNOSTIC_PEER_PLATFORMS.indexOf(facts.peerPlatform) < 0 ||
    DIAGNOSTIC_PRESENTATIONS.indexOf(facts.presentation) < 0 ||
    DIAGNOSTIC_PRODUCER_TRANSFORMS.indexOf(facts.producerTransform) < 0 ||
    DIAGNOSTIC_PRODUCER_TRANSFORMS.indexOf(facts.appliedTransform) < 0 ||
    typeof facts.desktopSurfaceCompatibility !== 'boolean' ||
    typeof facts.producerTransformSampled !== 'boolean' ||
    typeof facts.rendererTransformValid !== 'boolean' ||
    typeof facts.rendererFlipX !== 'boolean' ||
    typeof facts.rendererFlipY !== 'boolean') {
    return false;
  }
  const numbers: number[] = [
    facts.width, facts.height, facts.frames, facts.dropped, facts.errors,
    facts.queueDepth, facts.latencyMs, facts.producerTransformSamples,
    facts.producerTransformChanges, facts.producerTransformReadFailures,
    facts.producerTransformClassMask, facts.rendererTransformVersion,
    facts.decoderGeneration, facts.rendererGeneration
  ];
  for (let index: number = 0; index < numbers.length; index++) {
    if (diagnosticSafeInteger(numbers[index]) === null || numbers[index] < 0) {
      return false;
    }
  }
  if (diagnosticSafeInteger(facts.producerTransformReadResult) === null ||
    diagnosticSafeInteger(facts.rendererRotationQuarterTurns) === null ||
    facts.rendererRotationQuarterTurns < 0 || facts.rendererRotationQuarterTurns > 3 ||
    (facts.producerTransformMatrix.length !== 0 &&
      facts.producerTransformMatrix.length !== 16) ||
    (facts.appliedTextureTransform.length !== 0 &&
      facts.appliedTextureTransform.length !== 16)) { return false; }
  const matrices: number[][] = [
    facts.producerTransformMatrix, facts.appliedTextureTransform
  ];
  for (let matrixIndex: number = 0; matrixIndex < matrices.length; matrixIndex++) {
    for (let valueIndex: number = 0; valueIndex < matrices[matrixIndex].length; valueIndex++) {
      const value: number = matrices[matrixIndex][valueIndex];
      if (!Number.isFinite(value) || Math.abs(value) > 16) { return false; }
    }
  }
  return true;
}

export function copyDiagnosticRuntimeFacts(
  facts: DiagnosticRuntimeFacts): DiagnosticRuntimeFacts {
  return {
    video: facts.video === undefined ? undefined : copyVideoDiagnosticEvidence(facts.video),
    state: facts.state, backend: facts.backend, codec: facts.codec, path: facts.path,
    peerPlatform: facts.peerPlatform, presentation: facts.presentation,
    producerTransform: facts.producerTransform,
    appliedTransform: facts.appliedTransform,
    desktopSurfaceCompatibility: facts.desktopSurfaceCompatibility,
    producerTransformSampled: facts.producerTransformSampled,
    producerTransformReadResult: facts.producerTransformReadResult,
    producerTransformSamples: facts.producerTransformSamples,
    producerTransformChanges: facts.producerTransformChanges,
    producerTransformReadFailures: facts.producerTransformReadFailures,
    producerTransformClassMask: facts.producerTransformClassMask,
    producerTransformMatrix: facts.producerTransformMatrix.slice(),
    appliedTextureTransform: facts.appliedTextureTransform.slice(),
    rendererTransformValid: facts.rendererTransformValid,
    rendererTransformVersion: facts.rendererTransformVersion,
    rendererRotationQuarterTurns: facts.rendererRotationQuarterTurns,
    rendererFlipX: facts.rendererFlipX, rendererFlipY: facts.rendererFlipY,
    decoderGeneration: facts.decoderGeneration,
    rendererGeneration: facts.rendererGeneration, width: facts.width,
    height: facts.height, frames: facts.frames, dropped: facts.dropped,
    errors: facts.errors, queueDepth: facts.queueDepth, latencyMs: facts.latencyMs,
    protocol: copyDiagnosticProtocolFacts(facts.protocol),
    resources: copyDiagnosticResourceFacts(facts.resources)
  };
}

const DIAGNOSTIC_ADDRESS_FAMILIES: DiagnosticAddressFamily[] = [
  'unknown', 'hostname', 'ipv4', 'ipv6', 'mixed'
];

export function emptyDiagnosticNetworkFacts(): DiagnosticNetworkFacts {
  return {
    configuredEndpointFamily: 'unknown',
    configuredRouteFamily: 'unknown',
    hostnameCandidate: false,
    ipv4Candidate: false,
    ipv6Candidate: false,
    scopedIpv6: false
  };
}

export function diagnosticNetworkFactsAreValid(facts: DiagnosticNetworkFacts): boolean {
  if (DIAGNOSTIC_ADDRESS_FAMILIES.indexOf(facts.configuredEndpointFamily) < 0 ||
    DIAGNOSTIC_ADDRESS_FAMILIES.indexOf(facts.configuredRouteFamily) < 0 ||
    typeof facts.hostnameCandidate !== 'boolean' ||
    typeof facts.ipv4Candidate !== 'boolean' ||
    typeof facts.ipv6Candidate !== 'boolean' ||
    typeof facts.scopedIpv6 !== 'boolean') {
    return false;
  }
  if (facts.scopedIpv6 && !facts.ipv6Candidate) { return false; }
  if (facts.configuredEndpointFamily === 'hostname' && !facts.hostnameCandidate) {
    return false;
  }
  if (facts.configuredEndpointFamily === 'ipv4' && !facts.ipv4Candidate) {
    return false;
  }
  if (facts.configuredEndpointFamily === 'ipv6' && !facts.ipv6Candidate) {
    return false;
  }
  if (facts.configuredRouteFamily === 'hostname' && !facts.hostnameCandidate) {
    return false;
  }
  if (facts.configuredRouteFamily === 'ipv4' && !facts.ipv4Candidate) {
    return false;
  }
  if (facts.configuredRouteFamily === 'ipv6' && !facts.ipv6Candidate) {
    return false;
  }
  return true;
}

export function copyDiagnosticNetworkFacts(
  facts: DiagnosticNetworkFacts): DiagnosticNetworkFacts {
  return {
    configuredEndpointFamily: facts.configuredEndpointFamily,
    configuredRouteFamily: facts.configuredRouteFamily,
    hostnameCandidate: facts.hostnameCandidate,
    ipv4Candidate: facts.ipv4Candidate,
    ipv6Candidate: facts.ipv6Candidate,
    scopedIpv6: facts.scopedIpv6
  };
}

export function diagnosticNetworkFactsForEndpoints(endpointHost: string,
  endpointPort: number, routeHost: string = '', routePort: number = 0): DiagnosticNetworkFacts {
  try {
    const endpoint: EndpointAddressResult = parseEndpointFields(
      endpointHost, endpointPort > 0 ? endpointPort : 1, 'runtime');
    const endpointFamily: DiagnosticAddressFamily = endpoint.ok ?
      endpoint.endpoint.family : 'unknown';
    let routeFamily: DiagnosticAddressFamily = 'unknown';
    let routeScopedIpv6: boolean = false;
    if (routeHost.trim().length > 0) {
      const route: EndpointAddressResult = parseEndpointFields(
        routeHost, routePort > 0 ? routePort : 1, 'runtime');
      routeFamily = route.ok ? route.endpoint.family : 'unknown';
      routeScopedIpv6 = route.ok && route.endpoint.family === 'ipv6' &&
        route.endpoint.scope.length > 0;
    }
    return {
      configuredEndpointFamily: endpointFamily,
      configuredRouteFamily: routeFamily,
      hostnameCandidate: endpointFamily === 'hostname' || routeFamily === 'hostname',
      ipv4Candidate: endpointFamily === 'ipv4' || routeFamily === 'ipv4',
      ipv6Candidate: endpointFamily === 'ipv6' || routeFamily === 'ipv6',
      scopedIpv6: routeScopedIpv6 || (endpoint.ok &&
        endpoint.endpoint.family === 'ipv6' && endpoint.endpoint.scope.length > 0)
    };
  } catch (_err) {
    return emptyDiagnosticNetworkFacts();
  }
}

export function diagnosticNetworkFactsForAuthority(authority: string,
  defaultPort: number = 1): DiagnosticNetworkFacts {
  try {
    const parsed: EndpointAddressResult = parseEndpointAuthority(
      authority, defaultPort > 0 ? defaultPort : 1, 'runtime');
    if (!parsed.ok) { return emptyDiagnosticNetworkFacts(); }
    return {
      configuredEndpointFamily: parsed.endpoint.family,
      configuredRouteFamily: 'unknown',
      hostnameCandidate: parsed.endpoint.family === 'hostname',
      ipv4Candidate: parsed.endpoint.family === 'ipv4',
      ipv6Candidate: parsed.endpoint.family === 'ipv6',
      scopedIpv6: parsed.endpoint.family === 'ipv6' && parsed.endpoint.scope.length > 0
    };
  } catch (_err) {
    return emptyDiagnosticNetworkFacts();
  }
}

/** Build facts for ordered Moonlight-style candidate lists without retaining addresses. */
export function diagnosticNetworkFactsForCandidates(families: string[],
  scopedIpv6: boolean = false): DiagnosticNetworkFacts {
  try {
    let hostnameCandidate: boolean = false;
    let ipv4Candidate: boolean = false;
    let ipv6Candidate: boolean = false;
    for (let index: number = 0; index < families.length; index++) {
      const family: string = families[index].trim().toLowerCase();
      if (family === 'ipv4') { ipv4Candidate = true; }
      else if (family === 'ipv6') { ipv6Candidate = true; }
      else if (family === 'hostname' || family === 'unspecified') {
        hostnameCandidate = true;
      }
    }
    const familyCount: number = (hostnameCandidate ? 1 : 0) +
      (ipv4Candidate ? 1 : 0) + (ipv6Candidate ? 1 : 0);
    const configuredEndpointFamily: DiagnosticAddressFamily = familyCount === 0 ? 'unknown' :
      (familyCount > 1 ? 'mixed' :
        (ipv6Candidate ? 'ipv6' : (ipv4Candidate ? 'ipv4' : 'hostname')));
    return {
      configuredEndpointFamily: configuredEndpointFamily,
      configuredRouteFamily: 'unknown',
      hostnameCandidate: hostnameCandidate,
      ipv4Candidate: ipv4Candidate,
      ipv6Candidate: ipv6Candidate,
      scopedIpv6: scopedIpv6 && ipv6Candidate
    };
  } catch (_err) {
    return emptyDiagnosticNetworkFacts();
  }
}
