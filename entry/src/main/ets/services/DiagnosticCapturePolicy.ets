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
  'security.ssh_key';

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
  'unknown' | 'identity' | 'producer' | 'validated_producer';

export type DiagnosticProducerTransform =
  'unknown' | 'not_sampled' | 'identity' | 'flip_x' | 'flip_y' |
  'rotate_90' | 'rotate_180' | 'rotate_270' | 'transpose' | 'transverse' |
  'other' | 'read_failed';

export interface DiagnosticRuntimeFacts {
  state: DiagnosticRuntimeState;
  backend: DiagnosticRuntimeBackend;
  codec: DiagnosticRuntimeCodec;
  path: DiagnosticRuntimePath;
  peerPlatform: DiagnosticPeerPlatform;
  presentation: DiagnosticPresentation;
  producerTransform: DiagnosticProducerTransform;
  width: number;
  height: number;
  frames: number;
  dropped: number;
  errors: number;
  queueDepth: number;
  latencyMs: number;
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

export const DIAGNOSTIC_CAPTURE_SCHEMA_VERSION: number = 2;
export const DIAGNOSTIC_REDACTION_POLICY_VERSION: number = 2;
export const DIAGNOSTIC_DEFAULT_DURATION_MINUTES: number = 10;
export const DIAGNOSTIC_MAX_EVENTS: number = 10000;
export const DIAGNOSTIC_MAX_EVENT_BYTES: number = 1024;
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
  { id: 'security.ssh_key', label: 'SSH 密钥对', alwaysEnabled: false }
];

const DIAGNOSTIC_OUTCOMES: DiagnosticOutcome[] = [
  'started', 'succeeded', 'failed', 'cancelled',
  'timeout', 'skipped', 'retry', 'state'
];

const DIAGNOSTIC_EVENTS: DiagnosticEventSpec[] = [
  { moduleId: 'core.app', eventCode: 'capture_started' },
  { moduleId: 'core.app', eventCode: 'capture_stopped' },
  { moduleId: 'core.app', eventCode: 'capture_expired' },

  { moduleId: 'connection.rdp', eventCode: 'rdp_connection_request' },
  { moduleId: 'connection.rdp', eventCode: 'rdp_preflight' },
  { moduleId: 'connection.rdp', eventCode: 'rdp_state_changed' },
  { moduleId: 'connection.rdp', eventCode: 'rdp_runtime_snapshot' },
  { moduleId: 'connection.rdp', eventCode: 'rdp_disconnect' },

  { moduleId: 'connection.rustdesk', eventCode: 'rustdesk_presence' },
  { moduleId: 'connection.rustdesk', eventCode: 'rustdesk_connection_request' },
  { moduleId: 'connection.rustdesk', eventCode: 'rustdesk_state_changed' },
  { moduleId: 'connection.rustdesk', eventCode: 'rustdesk_two_factor' },
  { moduleId: 'connection.rustdesk', eventCode: 'rustdesk_runtime_snapshot' },
  { moduleId: 'connection.rustdesk', eventCode: 'rustdesk_disconnect' },

  { moduleId: 'connection.ssh_sftp', eventCode: 'ssh_session_event' },
  { moduleId: 'connection.ssh_sftp', eventCode: 'ssh_preflight' },
  { moduleId: 'connection.ssh_sftp', eventCode: 'ssh_disconnect' },
  { moduleId: 'connection.ssh_sftp', eventCode: 'ssh_runtime_snapshot' },
  { moduleId: 'connection.ssh_sftp', eventCode: 'sftp_task_started' },
  { moduleId: 'connection.ssh_sftp', eventCode: 'sftp_task_completed' },

  { moduleId: 'connection.vnc', eventCode: 'vnc_connection_request' },
  { moduleId: 'connection.vnc', eventCode: 'vnc_preflight' },
  { moduleId: 'connection.vnc', eventCode: 'vnc_state_changed' },
  { moduleId: 'connection.vnc', eventCode: 'vnc_runtime_snapshot' },
  { moduleId: 'connection.vnc', eventCode: 'vnc_disconnect' },

  { moduleId: 'connection.moonlight', eventCode: 'moonlight_pair' },
  { moduleId: 'connection.moonlight', eventCode: 'moonlight_catalog' },
  { moduleId: 'connection.moonlight', eventCode: 'moonlight_launch' },
  { moduleId: 'connection.moonlight', eventCode: 'moonlight_state_changed' },
  { moduleId: 'connection.moonlight', eventCode: 'moonlight_runtime_snapshot' },

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
  { moduleId: 'security.ssh_key', eventCode: 'ssh_key_auth_test' }
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
  'unknown', 'identity', 'producer', 'validated_producer'
];
const DIAGNOSTIC_PRODUCER_TRANSFORMS: DiagnosticProducerTransform[] = [
  'unknown', 'not_sampled', 'identity', 'flip_x', 'flip_y',
  'rotate_90', 'rotate_180', 'rotate_270', 'transpose', 'transverse',
  'other', 'read_failed'
];

export function emptyDiagnosticRuntimeFacts(): DiagnosticRuntimeFacts {
  return {
    state: 'unknown', backend: 'unknown', codec: 'unknown', path: 'unknown',
    peerPlatform: 'unknown', presentation: 'unknown', producerTransform: 'unknown',
    width: 0, height: 0, frames: 0, dropped: 0, errors: 0,
    queueDepth: 0, latencyMs: 0
  };
}

export function diagnosticRuntimeFactsAreValid(facts: DiagnosticRuntimeFacts): boolean {
  if (DIAGNOSTIC_RUNTIME_STATES.indexOf(facts.state) < 0 ||
    DIAGNOSTIC_RUNTIME_BACKENDS.indexOf(facts.backend) < 0 ||
    DIAGNOSTIC_RUNTIME_CODECS.indexOf(facts.codec) < 0 ||
    DIAGNOSTIC_RUNTIME_PATHS.indexOf(facts.path) < 0 ||
    DIAGNOSTIC_PEER_PLATFORMS.indexOf(facts.peerPlatform) < 0 ||
    DIAGNOSTIC_PRESENTATIONS.indexOf(facts.presentation) < 0 ||
    DIAGNOSTIC_PRODUCER_TRANSFORMS.indexOf(facts.producerTransform) < 0) {
    return false;
  }
  const numbers: number[] = [
    facts.width, facts.height, facts.frames, facts.dropped, facts.errors,
    facts.queueDepth, facts.latencyMs
  ];
  for (let index: number = 0; index < numbers.length; index++) {
    if (diagnosticSafeInteger(numbers[index]) === null || numbers[index] < 0) {
      return false;
    }
  }
  return true;
}

export function copyDiagnosticRuntimeFacts(
  facts: DiagnosticRuntimeFacts): DiagnosticRuntimeFacts {
  return {
    state: facts.state, backend: facts.backend, codec: facts.codec, path: facts.path,
    peerPlatform: facts.peerPlatform, presentation: facts.presentation,
    producerTransform: facts.producerTransform, width: facts.width,
    height: facts.height, frames: facts.frames, dropped: facts.dropped,
    errors: facts.errors, queueDepth: facts.queueDepth, latencyMs: facts.latencyMs
  };
}
