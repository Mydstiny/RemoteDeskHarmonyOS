import {
  SshForwardingConfig,
  SshForwardingSnapshot,
  SshForwardingSnapshotsResult
} from '../types/rdpnapi';
import {
  SshForwardingProfile,
  SshForwardingValidationResult,
  validateSshForwardingProfile
} from './SshForwardingPolicy';
import {
  SshForwardingRuntimeRecord,
  SshForwardingRuntimeState,
  SshForwardingRuntimeStore
} from './SshForwardingRuntimeStore';
import { SshNativeFacade } from './SshNativeFacade';
import { SshSessionHandle, SshSessionLifecycleState } from './SshSessionStore';
import { recordDiagnosticEvent } from './DiagnosticCaptureRuntime';

export type SshForwardingOperation = 'configure' | 'start' | 'stop' | 'remove' |
  'acquire' | 'release' | 'reconcile' | 'snapshot';

export interface SshForwardingOperationResult {
  operation: SshForwardingOperation;
  profileId: string;
  code: number;
  accepted: boolean;
  stale: boolean;
  state: SshForwardingRuntimeState;
  message: string;
}

export interface SshForwardingSnapshotResult {
  code: number;
  accepted: boolean;
  stale: boolean;
  runtimes: SshForwardingRuntimeRecord[];
}

export interface SshForwardingNativePort {
  accepts(handle: SshSessionHandle): boolean;
  forwardingSessionState(handle: SshSessionHandle): SshSessionLifecycleState | '';
  configureSshForwarding(handle: SshSessionHandle, config: SshForwardingConfig): number;
  removeSshForwarding(handle: SshSessionHandle, id: string): number;
  startSshForwarding(handle: SshSessionHandle, id: string): number;
  stopSshForwarding(handle: SshSessionHandle, id: string): number;
  completeSshForwardingStop(handle: SshSessionHandle, id: string): number;
  acquireSshForwardingConnection(handle: SshSessionHandle, id: string): number;
  releaseSshForwardingConnection(handle: SshSessionHandle, id: string): number;
  getSshForwardingSnapshots(handle: SshSessionHandle): SshForwardingSnapshotsResult;
}

const SSH_FORWARDING_OK: number = 0;
const SSH_FORWARDING_INVALID_STATE: number = -74;
const SSH_FORWARDING_STALE: number = -75;
const SSH_FORWARDING_PROFILE_LIMIT: number = -70;
const SSH_FORWARDING_NOT_FOUND: number = -72;

function nativeMode(profile: SshForwardingProfile): number {
  if (profile.mode === 'remote') { return 1; }
  if (profile.mode === 'dynamic') { return 2; }
  return 0;
}

export function sshForwardingNativeConfig(profile: SshForwardingProfile): SshForwardingConfig {
  return {
    schemaVersion: 1,
    id: profile.id,
    mode: nativeMode(profile),
    bindHost: profile.bindHost,
    bindPort: profile.bindPort,
    targetHost: profile.targetHost,
    targetPort: profile.targetPort,
    maxConnections: profile.maxConnections,
    enabled: profile.enabled,
    allowPublicBind: profile.allowPublicBind,
    minBindPort: profile.minBindPort === undefined ? 1 : profile.minBindPort,
    maxBindPort: profile.maxBindPort === undefined ? 65535 : profile.maxBindPort,
    maxBytes: profile.maxBytes === undefined ? 0 : profile.maxBytes,
    expiresAtMs: profile.expiresAtMs === undefined ? 0 : profile.expiresAtMs
  };
}

function nativeState(value: number): SshForwardingRuntimeState {
  if (value === 1) { return 'starting'; }
  if (value === 2) { return 'listening'; }
  if (value === 3) { return 'stopping'; }
  if (value === 4) { return 'failed'; }
  return 'stopped';
}

function operationResult(operation: SshForwardingOperation, profileId: string, code: number,
  state: SshForwardingRuntimeState, message: string = ''): SshForwardingOperationResult {
  const stale: boolean = code === SSH_FORWARDING_STALE;
  const result: SshForwardingOperationResult = {
    operation, profileId, code, accepted: code === SSH_FORWARDING_OK,
    stale, state, message };
  const operationCode: number = operation === 'configure' ? 1 :
    (operation === 'start' ? 2 : (operation === 'stop' ? 3 :
      (operation === 'remove' ? 4 : (operation === 'acquire' ? 5 :
        (operation === 'release' ? 6 : (operation === 'reconcile' ? 7 : 8))))));
  recordDiagnosticEvent('network.routing', 'routing_ssh_forwarding',
    result.accepted ? 'succeeded' : (result.stale ? 'skipped' : 'failed'),
    0, 0, code === SSH_FORWARDING_OK ? operationCode : code);
  return result;
}

export class SshForwardingController {
  private static instance: SshForwardingController | null = null;
  private readonly native: SshForwardingNativePort;
  private readonly runtimes: SshForwardingRuntimeStore;

  constructor(native: SshForwardingNativePort = SshNativeFacade.getInstance(),
    runtimes: SshForwardingRuntimeStore = new SshForwardingRuntimeStore()) {
    this.native = native;
    this.runtimes = runtimes;
  }

  static getInstance(): SshForwardingController {
    if (SshForwardingController.instance === null) {
      SshForwardingController.instance = new SshForwardingController();
    }
    return SshForwardingController.instance;
  }

  configure(handle: SshSessionHandle, profile: SshForwardingProfile): SshForwardingOperationResult {
    const validation: SshForwardingValidationResult = validateSshForwardingProfile(profile);
    if (!validation.valid) {
      return operationResult('configure', profile.id, SSH_FORWARDING_INVALID_STATE,
        'failed', validation.code + ': ' + validation.message);
    }
    if (!this.native.accepts(handle)) { return this.rejectStale(handle, 'configure', profile.id); }
    if (!this.runtimes.canUpsert(handle, validation.profile.id)) {
      return operationResult('configure', validation.profile.id, SSH_FORWARDING_PROFILE_LIMIT,
        'failed', 'forwarding runtime limit reached');
    }
    const code: number = this.native.configureSshForwarding(handle,
      sshForwardingNativeConfig(validation.profile));
    const state: SshForwardingRuntimeState = code === SSH_FORWARDING_OK ? 'configured' :
      (code === SSH_FORWARDING_STALE ? 'stale' : 'failed');
    if (this.runtimes.upsert(handle, validation.profile, state, code) === null) {
      return operationResult('configure', profile.id, SSH_FORWARDING_PROFILE_LIMIT,
        'failed', 'forwarding runtime limit reached');
    }
    return operationResult('configure', validation.profile.id, code, state);
  }

  start(handle: SshSessionHandle, profile: SshForwardingProfile): SshForwardingOperationResult {
    if (!this.native.accepts(handle)) { return this.rejectStale(handle, 'start', profile.id); }
    if (this.native.forwardingSessionState(handle) !== 'Ready') {
      return operationResult('start', profile.id, SSH_FORWARDING_INVALID_STATE,
        'failed', 'SSH session is not Ready');
    }
    const configured: SshForwardingOperationResult = this.configure(handle, profile);
    if (!configured.accepted) {
      return operationResult('start', profile.id, configured.code, configured.state, configured.message);
    }
    this.runtimes.upsert(handle, profile, 'starting');
    const code: number = this.native.startSshForwarding(handle, profile.id);
    const state: SshForwardingRuntimeState = code === SSH_FORWARDING_OK ? 'listening' :
      (code === SSH_FORWARDING_STALE ? 'stale' : 'failed');
    this.runtimes.upsert(handle, profile, state, code);
    return operationResult('start', profile.id, code, state);
  }

  stop(handle: SshSessionHandle, profileId: string): SshForwardingOperationResult {
    if (!this.native.accepts(handle)) { return this.rejectStale(handle, 'stop', profileId); }
    const runtime: SshForwardingRuntimeRecord | null = this.runtimes.get(handle, profileId);
    if (runtime !== null && (runtime.state === 'stopped' || runtime.state === 'configured')) {
      this.runtimes.upsert(handle, runtime.profile, 'stopped');
      return operationResult('stop', profileId, SSH_FORWARDING_OK, 'stopped');
    }
    if (runtime !== null) { this.runtimes.upsert(handle, runtime.profile, 'stopping'); }
    const stopCode: number = this.native.stopSshForwarding(handle, profileId);
    if (stopCode !== SSH_FORWARDING_OK && stopCode !== SSH_FORWARDING_NOT_FOUND) {
      if (runtime !== null) { this.runtimes.upsert(handle, runtime.profile,
        stopCode === SSH_FORWARDING_STALE ? 'stale' : 'failed', stopCode); }
      return operationResult('stop', profileId, stopCode,
        stopCode === SSH_FORWARDING_STALE ? 'stale' : 'failed');
    }
    const completeCode: number = stopCode === SSH_FORWARDING_NOT_FOUND ? SSH_FORWARDING_OK :
      this.native.completeSshForwardingStop(handle, profileId);
    const state: SshForwardingRuntimeState = completeCode === SSH_FORWARDING_OK ? 'stopped' :
      (completeCode === SSH_FORWARDING_STALE ? 'stale' : 'failed');
    if (runtime !== null) { this.runtimes.upsert(handle, runtime.profile, state, completeCode); }
    return operationResult('stop', profileId, completeCode, state);
  }

  remove(handle: SshSessionHandle, profileId: string): SshForwardingOperationResult {
    if (!this.native.accepts(handle)) { return this.rejectStale(handle, 'remove', profileId); }
    const runtime: SshForwardingRuntimeRecord | null = this.runtimes.get(handle, profileId);
    if (runtime !== null && (runtime.state === 'starting' || runtime.state === 'listening' ||
      runtime.state === 'stopping')) {
      const stopped: SshForwardingOperationResult = this.stop(handle, profileId);
      if (!stopped.accepted) {
        return operationResult('remove', profileId, stopped.code, stopped.state, stopped.message);
      }
    }
    const code: number = this.native.removeSshForwarding(handle, profileId);
    if (code === SSH_FORWARDING_OK || code === SSH_FORWARDING_NOT_FOUND) {
      this.runtimes.remove(handle, profileId);
      return operationResult('remove', profileId, SSH_FORWARDING_OK, 'stopped');
    }
    return operationResult('remove', profileId, code,
      code === SSH_FORWARDING_STALE ? 'stale' : 'failed');
  }

  acquire(handle: SshSessionHandle, profileId: string): SshForwardingOperationResult {
    return this.connectionOperation(handle, profileId, true);
  }

  release(handle: SshSessionHandle, profileId: string): SshForwardingOperationResult {
    return this.connectionOperation(handle, profileId, false);
  }

  reconcile(handle: SshSessionHandle,
    profiles: SshForwardingProfile[]): SshForwardingOperationResult[] {
    this.runtimes.markOlderGenerations(handle);
    if (!this.native.accepts(handle)) {
      this.runtimes.markHandleStale(handle);
      return [operationResult('reconcile', '', SSH_FORWARDING_STALE, 'stale')];
    }
    const results: SshForwardingOperationResult[] = [];
    for (let index: number = 0; index < profiles.length; index++) {
      const profile: SshForwardingProfile = profiles[index];
      if (!profile.enabled) {
        const runtime: SshForwardingRuntimeRecord | null = this.runtimes.get(handle, profile.id);
        if (runtime !== null) { results.push(this.stop(handle, profile.id)); }
        continue;
      }
      if (profile.startPolicy === 'onSessionReady') {
        results.push(this.start(handle, profile));
      } else {
        results.push(this.configure(handle, profile));
      }
    }
    // A successfully adopted generation owns fresh native listeners. Runtime
    // records from older generations are no longer actionable and must not
    // accumulate in the process-wide controller.
    this.runtimes.clearOlderGenerations(handle);
    return results;
  }

  snapshot(handle: SshSessionHandle): SshForwardingSnapshotResult {
    if (!this.native.accepts(handle)) {
      this.runtimes.markHandleStale(handle);
      return { code: SSH_FORWARDING_STALE, accepted: false, stale: true, runtimes: [] };
    }
    const nativeResult: SshForwardingSnapshotsResult = this.native.getSshForwardingSnapshots(handle);
    if (nativeResult.errorCode !== SSH_FORWARDING_OK ||
      nativeResult.sessionGeneration !== handle.generation) {
      this.runtimes.markHandleStale(handle);
      const code: number = nativeResult.errorCode === SSH_FORWARDING_OK
        ? SSH_FORWARDING_STALE : nativeResult.errorCode;
      return { code, accepted: false, stale: code === SSH_FORWARDING_STALE, runtimes: [] };
    }
    for (let index: number = 0; index < nativeResult.snapshots.length; index++) {
      const snapshot: SshForwardingSnapshot = nativeResult.snapshots[index];
      if (snapshot.ownerSessionId !== handle.sessionId || snapshot.ownerChannelId !== handle.channelId ||
        snapshot.ownerGeneration !== handle.generation || snapshot.sessionGeneration !== handle.generation) {
        continue;
      }
      this.runtimes.updateSnapshot(handle, snapshot.id, nativeState(snapshot.state),
        snapshot.activeConnections, snapshot.transferredBytes, snapshot.lastError,
        snapshot.bindHost, snapshot.bindPort);
    }
    return { code: SSH_FORWARDING_OK, accepted: true, stale: false,
      runtimes: this.runtimes.list(handle) };
  }

  list(handle: SshSessionHandle): SshForwardingRuntimeRecord[] {
    return this.runtimes.list(handle);
  }

  stopAll(handle: SshSessionHandle): SshForwardingOperationResult[] {
    const runtimes: SshForwardingRuntimeRecord[] = this.runtimes.list(handle);
    const results: SshForwardingOperationResult[] = [];
    for (let index: number = 0; index < runtimes.length; index++) {
      results.push(this.stop(handle, runtimes[index].profileId));
    }
    return results;
  }

  releaseSession(handle: SshSessionHandle): SshForwardingOperationResult[] {
    const results: SshForwardingOperationResult[] = this.stopAll(handle);
    // A reconnect can leave an old generation without a successful reconcile
    // boundary. Teardown owns the whole session identity, not just its latest
    // generation, so stale runtime records must not survive into later slots.
    this.runtimes.clearSession(handle);
    return results;
  }

  private connectionOperation(handle: SshSessionHandle, profileId: string,
    acquire: boolean): SshForwardingOperationResult {
    const operation: SshForwardingOperation = acquire ? 'acquire' : 'release';
    if (!this.native.accepts(handle)) { return this.rejectStale(handle, operation, profileId); }
    const runtime: SshForwardingRuntimeRecord | null = this.runtimes.get(handle, profileId);
    if (runtime === null || runtime.state !== 'listening') {
      return operationResult(operation, profileId, SSH_FORWARDING_INVALID_STATE, 'failed');
    }
    const code: number = acquire
      ? this.native.acquireSshForwardingConnection(handle, profileId)
      : this.native.releaseSshForwardingConnection(handle, profileId);
    if (code !== SSH_FORWARDING_OK) {
      this.runtimes.upsert(handle, runtime.profile,
        code === SSH_FORWARDING_STALE ? 'stale' : 'failed', code);
    }
    return operationResult(operation, profileId, code,
      code === SSH_FORWARDING_OK ? 'listening' :
        (code === SSH_FORWARDING_STALE ? 'stale' : 'failed'));
  }

  private rejectStale(handle: SshSessionHandle, operation: SshForwardingOperation,
    profileId: string): SshForwardingOperationResult {
    this.runtimes.markHandleStale(handle);
    return operationResult(operation, profileId, SSH_FORWARDING_STALE, 'stale');
  }
}
