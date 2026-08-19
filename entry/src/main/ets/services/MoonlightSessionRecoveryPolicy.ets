/**
 * Device-local Moonlight crash/session-recovery contract.
 *
 * This payload deliberately contains no endpoint, PIN, client identity,
 * launch key, RI key, media content, input value, or cloud field. It is never
 * projected into CloudStore or portable backup data.
 */

export const MOONLIGHT_SESSION_RECOVERY_MARKER_VERSION: number = 1;
export const MOONLIGHT_SESSION_RECOVERY_PROTOCOL_COMPAT: string =
  'remotedesk-moonlight-product-v1+common-c-e41355ea';

export type MoonlightSessionRecoveryStage =
  'launch_requested' | 'host_launch_confirmed' | 'transport_connecting' |
  'streaming' | 'suspended' | 'reconnecting' | 'terminal_pending' |
  'terminal_uncertain';

export type MoonlightSessionRecoveryTerminalAction =
  'none' | 'disconnect' | 'quit';

export type MoonlightSessionRecoveryDecodeCode =
  'absent' | 'ready' | 'corrupt' | 'too_new';

export type MoonlightSessionRecoveryHostState =
  'matching_app_running' | 'host_stopped' | 'different_app_running' |
  'host_unreachable';

export interface MoonlightSessionRecoveryBinding {
  ownerScopeShortId: string;
  storeIdentityHash: string;
  storeGeneration: number;
}

export interface MoonlightSessionRecoverySeed {
  sessionId: string;
  hostId: string;
  profileId: string;
  appId: string;
}

export interface MoonlightSessionRecoveryMarker {
  markerVersion: number;
  ownerScopeShortId: string;
  storeIdentityHash: string;
  storeGenerationAtLaunch: number;
  sessionId: string;
  hostId: string;
  profileId: string;
  appId: string;
  protocolCompatUniqueId: string;
  launchedAt: number;
  lastStage: MoonlightSessionRecoveryStage;
  lastHeartbeatAt: number;
  hostAppMayStillBeRunning: boolean;
  inputMayBeStuck: boolean;
  lastRequestedTerminalAction: MoonlightSessionRecoveryTerminalAction;
}

export interface MoonlightSessionRecoveryDecodeResult {
  code: MoonlightSessionRecoveryDecodeCode;
  marker: MoonlightSessionRecoveryMarker | null;
}

export interface MoonlightSessionRecoveryUpdate {
  stage: MoonlightSessionRecoveryStage;
  heartbeatAt: number;
  hostAppMayStillBeRunning: boolean;
  inputMayBeStuck: boolean;
  terminalAction: MoonlightSessionRecoveryTerminalAction;
}

const MARKER_KEYS: string[] = [
  'markerVersion', 'ownerScopeShortId', 'storeIdentityHash',
  'storeGenerationAtLaunch', 'sessionId', 'hostId', 'profileId', 'appId',
  'protocolCompatUniqueId', 'launchedAt', 'lastStage', 'lastHeartbeatAt',
  'hostAppMayStillBeRunning', 'inputMayBeStuck',
  'lastRequestedTerminalAction'
];

const STAGES: MoonlightSessionRecoveryStage[] = [
  'launch_requested', 'host_launch_confirmed', 'transport_connecting',
  'streaming', 'suspended', 'reconnecting', 'terminal_pending',
  'terminal_uncertain'
];

const TERMINAL_ACTIONS: MoonlightSessionRecoveryTerminalAction[] = [
  'none', 'disconnect', 'quit'
];

function safePositive(value: number): boolean {
  return Number.isSafeInteger(value) && value > 0;
}

function bounded(value: string, maximum: number, emptyAllowed: boolean = false): boolean {
  return typeof value === 'string' && value.length <= maximum &&
    (emptyAllowed || value.trim().length > 0);
}

function exactKeys(value: Record<string, Object>): boolean {
  const actual: string[] = Object.keys(value).sort();
  return actual.join(',') === MARKER_KEYS.slice().sort().join(',');
}

export function moonlightSessionRecoveryBindingIsValid(
  binding: MoonlightSessionRecoveryBinding
): boolean {
  return binding !== undefined && binding !== null &&
    /^[0-9a-f]{16}$/.test(binding.ownerScopeShortId) &&
    /^[0-9a-f]{64}$/.test(binding.storeIdentityHash) &&
    safePositive(binding.storeGeneration);
}

export function moonlightSessionRecoveryMarkerIsValid(
  marker: MoonlightSessionRecoveryMarker
): boolean {
  return marker !== undefined && marker !== null &&
    marker.markerVersion === MOONLIGHT_SESSION_RECOVERY_MARKER_VERSION &&
    /^[0-9a-f]{16}$/.test(marker.ownerScopeShortId) &&
    /^[0-9a-f]{64}$/.test(marker.storeIdentityHash) &&
    safePositive(marker.storeGenerationAtLaunch) &&
    /^[0-9a-f]{32}$/.test(marker.sessionId) &&
    bounded(marker.hostId, 128) && bounded(marker.profileId, 128, true) &&
    bounded(marker.appId, 128) &&
    marker.protocolCompatUniqueId === MOONLIGHT_SESSION_RECOVERY_PROTOCOL_COMPAT &&
    safePositive(marker.launchedAt) && safePositive(marker.lastHeartbeatAt) &&
    marker.lastHeartbeatAt >= marker.launchedAt &&
    STAGES.indexOf(marker.lastStage) >= 0 &&
    typeof marker.hostAppMayStillBeRunning === 'boolean' &&
    typeof marker.inputMayBeStuck === 'boolean' &&
    TERMINAL_ACTIONS.indexOf(marker.lastRequestedTerminalAction) >= 0;
}

export function createMoonlightSessionRecoveryMarker(
  binding: MoonlightSessionRecoveryBinding,
  seed: MoonlightSessionRecoverySeed,
  nowMs: number
): MoonlightSessionRecoveryMarker | null {
  const marker: MoonlightSessionRecoveryMarker = {
    markerVersion: MOONLIGHT_SESSION_RECOVERY_MARKER_VERSION,
    ownerScopeShortId: binding.ownerScopeShortId,
    storeIdentityHash: binding.storeIdentityHash,
    storeGenerationAtLaunch: binding.storeGeneration,
    sessionId: seed.sessionId.trim().toLowerCase(),
    hostId: seed.hostId.trim(),
    profileId: seed.profileId.trim(),
    appId: seed.appId.trim(),
    protocolCompatUniqueId: MOONLIGHT_SESSION_RECOVERY_PROTOCOL_COMPAT,
    launchedAt: nowMs,
    lastStage: 'launch_requested',
    lastHeartbeatAt: nowMs,
    // A process may die after the Host Control mutation is sent but before
    // its ArkTS completion runs. Keep the pre-launch marker conservative.
    hostAppMayStillBeRunning: true,
    inputMayBeStuck: false,
    lastRequestedTerminalAction: 'none'
  };
  return moonlightSessionRecoveryBindingIsValid(binding) &&
    moonlightSessionRecoveryMarkerIsValid(marker) ? marker : null;
}

export function moonlightSessionRecoveryMarkerMatchesBinding(
  marker: MoonlightSessionRecoveryMarker,
  binding: MoonlightSessionRecoveryBinding
): boolean {
  return moonlightSessionRecoveryMarkerIsValid(marker) &&
    moonlightSessionRecoveryBindingIsValid(binding) &&
    marker.ownerScopeShortId === binding.ownerScopeShortId &&
    marker.storeIdentityHash === binding.storeIdentityHash;
}

export function updateMoonlightSessionRecoveryMarker(
  marker: MoonlightSessionRecoveryMarker,
  update: MoonlightSessionRecoveryUpdate
): MoonlightSessionRecoveryMarker | null {
  if (!moonlightSessionRecoveryMarkerIsValid(marker) ||
      !safePositive(update.heartbeatAt) ||
      update.heartbeatAt < marker.lastHeartbeatAt ||
      STAGES.indexOf(update.stage) < 0 ||
      TERMINAL_ACTIONS.indexOf(update.terminalAction) < 0) {
    return null;
  }
  const next: MoonlightSessionRecoveryMarker = {
    markerVersion: marker.markerVersion,
    ownerScopeShortId: marker.ownerScopeShortId,
    storeIdentityHash: marker.storeIdentityHash,
    storeGenerationAtLaunch: marker.storeGenerationAtLaunch,
    sessionId: marker.sessionId,
    hostId: marker.hostId,
    profileId: marker.profileId,
    appId: marker.appId,
    protocolCompatUniqueId: marker.protocolCompatUniqueId,
    launchedAt: marker.launchedAt,
    lastStage: update.stage,
    lastHeartbeatAt: update.heartbeatAt,
    hostAppMayStillBeRunning: update.hostAppMayStillBeRunning,
    inputMayBeStuck: update.inputMayBeStuck,
    lastRequestedTerminalAction: update.terminalAction
  };
  return moonlightSessionRecoveryMarkerIsValid(next) ? next : null;
}

export function encodeMoonlightSessionRecoveryMarker(
  marker: MoonlightSessionRecoveryMarker
): string {
  return moonlightSessionRecoveryMarkerIsValid(marker) ? JSON.stringify(marker) : '';
}

export function decodeMoonlightSessionRecoveryMarker(
  raw: string
): MoonlightSessionRecoveryDecodeResult {
  if (raw.length === 0) { return { code: 'absent', marker: null }; }
  if (raw.length > 8192) { return { code: 'corrupt', marker: null }; }
  try {
    const source: Record<string, Object> =
      JSON.parse(raw) as Record<string, Object>;
    if (source === null || Array.isArray(source) || typeof source !== 'object') {
      return { code: 'corrupt', marker: null };
    }
    const version: Object = source['markerVersion'];
    if (typeof version === 'number' && Number.isSafeInteger(version as number) &&
        (version as number) > MOONLIGHT_SESSION_RECOVERY_MARKER_VERSION) {
      return { code: 'too_new', marker: null };
    }
    if (!exactKeys(source)) { return { code: 'corrupt', marker: null }; }
    const marker: MoonlightSessionRecoveryMarker = {
      markerVersion: source['markerVersion'] as number,
      ownerScopeShortId: source['ownerScopeShortId'] as string,
      storeIdentityHash: source['storeIdentityHash'] as string,
      storeGenerationAtLaunch: source['storeGenerationAtLaunch'] as number,
      sessionId: source['sessionId'] as string,
      hostId: source['hostId'] as string,
      profileId: source['profileId'] as string,
      appId: source['appId'] as string,
      protocolCompatUniqueId: source['protocolCompatUniqueId'] as string,
      launchedAt: source['launchedAt'] as number,
      lastStage: source['lastStage'] as MoonlightSessionRecoveryStage,
      lastHeartbeatAt: source['lastHeartbeatAt'] as number,
      hostAppMayStillBeRunning: source['hostAppMayStillBeRunning'] as boolean,
      inputMayBeStuck: source['inputMayBeStuck'] as boolean,
      lastRequestedTerminalAction:
        source['lastRequestedTerminalAction'] as MoonlightSessionRecoveryTerminalAction
    };
    return moonlightSessionRecoveryMarkerIsValid(marker) ?
      { code: 'ready', marker: marker } : { code: 'corrupt', marker: null };
  } catch (_error) {
    return { code: 'corrupt', marker: null };
  }
}

/** Maps the existing read-only quit preflight result to recovery host truth. */
export function moonlightSessionRecoveryHostState(
  nativeCode: string, idempotent: boolean
): MoonlightSessionRecoveryHostState {
  if (nativeCode === 'confirmation_required') { return 'matching_app_running'; }
  if (nativeCode === 'ok' && idempotent) { return 'host_stopped'; }
  if (nativeCode === 'stale') { return 'different_app_running'; }
  return 'host_unreachable';
}

export function moonlightSessionRecoveryRequiresRemoteReset(
  marker: MoonlightSessionRecoveryMarker
): boolean {
  return moonlightSessionRecoveryMarkerIsValid(marker) && marker.inputMayBeStuck;
}
