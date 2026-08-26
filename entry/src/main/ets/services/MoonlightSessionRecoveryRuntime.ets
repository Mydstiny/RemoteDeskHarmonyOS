/**
 * Process-lifetime owner for the device-local Moonlight recovery marker.
 *
 * A page may disappear before common-c emits its typed terminal receipt, so
 * the marker cannot be owned by a component lifecycle. This singleton keeps
 * only the exact Preferences owner/store binding and non-secret marker DTO;
 * it has no CloudStore, backup, endpoint, identity, RI-key, or media path.
 */
import { common } from '@kit.AbilityKit';
import { AccountSessionLease } from './AccountScopePolicy';
import {
  MoonlightNativeStreamSnapshot
} from './MoonlightHostService';
import {
  MoonlightSessionRecoveryDecodeCode,
  MoonlightSessionRecoveryMarker,
  MoonlightSessionRecoveryStage,
  MoonlightSessionRecoveryTerminalAction
} from './MoonlightSessionRecoveryPolicy';
import { MoonlightSessionRecoveryStore } from './MoonlightSessionRecoveryStore';

export type MoonlightSessionRecoveryRuntimeBindCode =
  'ready' | 'absent' | 'corrupt' | 'too_new' | 'mismatch';

export interface MoonlightSessionRecoveryRuntimePort {
  observeState(ownerScopeId: string, accountGeneration: number,
    hostId: string, appId: string, phase: string, nowMs: number): void;
  observeNativeSnapshot(ownerScopeId: string, accountGeneration: number,
    hostId: string, appId: string, snapshot: MoonlightNativeStreamSnapshot,
    nowMs: number): void;
  acceptNativeTerminal(ownerScopeId: string, accountGeneration: number,
    hostId: string, appId: string, snapshot: MoonlightNativeStreamSnapshot,
    nowMs: number): void;
  acceptNoRuntimeTerminal(ownerScopeId: string, accountGeneration: number,
    hostId: string, appId: string, nowMs: number): void;
}

export interface MoonlightSessionRecoveryHostQuitReceipt {
  code: string;
  preflightTruth: string;
  actionTruth: string;
  postconditionTruth: string;
  idempotent: boolean;
}

const RECOVERY_HEARTBEAT_INTERVAL_MS: number = 5000;

function safeGeneration(value: number): boolean {
  return Number.isSafeInteger(value) && value > 0;
}

function stageForPhase(phase: string): MoonlightSessionRecoveryStage | null {
  if (phase === 'streaming') { return 'streaming'; }
  if (phase === 'reconnecting') { return 'reconnecting'; }
  if (phase === 'stopping') { return 'terminal_pending'; }
  if (phase === 'suspended') { return 'suspended'; }
  if (phase === 'connecting' || phase === 'negotiating' ||
      phase === 'launching' || phase === 'verifying' ||
      phase === 'discovering') { return 'transport_connecting'; }
  if (phase === 'failed' || phase === 'disconnected') {
    return 'terminal_uncertain';
  }
  return null;
}

export class MoonlightSessionRecoveryRuntime implements
  MoonlightSessionRecoveryRuntimePort {
  private static instance: MoonlightSessionRecoveryRuntime | null = null;
  private store: MoonlightSessionRecoveryStore | null = null;
  private marker: MoonlightSessionRecoveryMarker | null = null;
  private ownerScopeId: string = '';
  private accountGeneration: number = 0;
  private hostId: string = '';
  private appId: string = '';

  static getInstance(): MoonlightSessionRecoveryRuntime {
    if (MoonlightSessionRecoveryRuntime.instance === null) {
      MoonlightSessionRecoveryRuntime.instance =
        new MoonlightSessionRecoveryRuntime();
    }
    return MoonlightSessionRecoveryRuntime.instance;
  }

  bind(context: common.Context, lease: AccountSessionLease,
    sessionId: string, hostId: string,
    appId: string): MoonlightSessionRecoveryRuntimeBindCode {
    const store: MoonlightSessionRecoveryStore =
      new MoonlightSessionRecoveryStore();
    const decoded = store.bind(context, lease, hostId);
    if (decoded.code !== 'ready' || decoded.marker === null) {
      this.resetBinding();
      return decoded.code as MoonlightSessionRecoveryDecodeCode;
    }
    const marker: MoonlightSessionRecoveryMarker = decoded.marker;
    if (marker.sessionId !== sessionId.trim().toLowerCase() ||
        marker.hostId !== hostId.trim() || marker.appId !== appId.trim() ||
        lease.ownerScopeId.trim() === '' || !safeGeneration(lease.generation)) {
      this.resetBinding();
      return 'mismatch';
    }
    this.store = store;
    this.marker = marker;
    this.ownerScopeId = lease.ownerScopeId;
    this.accountGeneration = lease.generation;
    this.hostId = hostId.trim();
    this.appId = appId.trim();
    // Once a fresh transport is admitted, an abrupt process death may happen
    // between any native input callback and the next ArkTS poll. Persist the
    // conservative truth before input activation, then clear only after an
    // explicitly requested clean terminal receipt.
    return this.update('transport_connecting', Date.now(), true,
      marker.lastRequestedTerminalAction) ? 'ready' : 'corrupt';
  }

  markerSnapshot(): MoonlightSessionRecoveryMarker | null {
    return this.marker === null ? null : this.clone(this.marker);
  }

  requestTerminal(action: MoonlightSessionRecoveryTerminalAction,
    nowMs: number = Date.now()): boolean {
    if (action === 'none') { return false; }
    return this.update('terminal_pending', nowMs, true, action);
  }

  observeState(ownerScopeId: string, accountGeneration: number,
    hostId: string, appId: string, phase: string, nowMs: number): void {
    if (!this.matches(ownerScopeId, accountGeneration, hostId, appId)) { return; }
    const stage: MoonlightSessionRecoveryStage | null = stageForPhase(phase);
    if (stage === null) { return; }
    const marker: MoonlightSessionRecoveryMarker =
      this.marker as MoonlightSessionRecoveryMarker;
    const due: boolean = nowMs >= marker.lastHeartbeatAt &&
      nowMs - marker.lastHeartbeatAt >= RECOVERY_HEARTBEAT_INTERVAL_MS;
    if (stage !== marker.lastStage || due) {
      this.update(stage, nowMs, true, marker.lastRequestedTerminalAction);
    }
  }

  observeNativeSnapshot(ownerScopeId: string, accountGeneration: number,
    hostId: string, appId: string, snapshot: MoonlightNativeStreamSnapshot,
    nowMs: number): void {
    if (!this.matches(ownerScopeId, accountGeneration, hostId, appId) ||
        !snapshot.matched || snapshot.terminal) { return; }
    const marker: MoonlightSessionRecoveryMarker =
      this.marker as MoonlightSessionRecoveryMarker;
    const stage: MoonlightSessionRecoveryStage = snapshot.firstFrameReady ?
      'streaming' : 'transport_connecting';
    const due: boolean = nowMs >= marker.lastHeartbeatAt &&
      nowMs - marker.lastHeartbeatAt >= RECOVERY_HEARTBEAT_INTERVAL_MS;
    if (stage !== marker.lastStage || due || !marker.inputMayBeStuck) {
      // Keep true for the whole admitted input lifetime. The native snapshot
      // remains diagnostic truth, but cannot close the tiny crash window
      // between a hardware callback and this observer.
      this.update(stage, nowMs, true, marker.lastRequestedTerminalAction);
    }
  }

  acceptNativeTerminal(ownerScopeId: string, accountGeneration: number,
    hostId: string, appId: string, snapshot: MoonlightNativeStreamSnapshot,
    nowMs: number): void {
    if (!this.matches(ownerScopeId, accountGeneration, hostId, appId) ||
        snapshot === undefined || snapshot === null ||
        !snapshot.matched || !snapshot.terminal) { return; }
    const marker: MoonlightSessionRecoveryMarker =
      this.marker as MoonlightSessionRecoveryMarker;
    const inputNeutral: boolean = !snapshot.inputMayBeStuck;
    if (inputNeutral &&
        marker.lastRequestedTerminalAction === 'disconnect') {
      if (this.store !== null && this.store.clear(marker.sessionId)) {
        this.resetBinding();
      }
      return;
    }
    if (inputNeutral &&
        marker.lastRequestedTerminalAction === 'quit') {
      // A clean common-c terminal proves that remote input was neutralized,
      // but it does not prove that Sunshine accepted and verified /cancel.
      // Keep the marker until the independent host-control postcondition is
      // confirmed so an app/process death between the two phases is
      // recoverable without replaying an uncertain mutation.
      this.update('terminal_pending', nowMs, false, 'quit');
      return;
    }
    this.update('terminal_uncertain', nowMs, snapshot.inputMayBeStuck,
      marker.lastRequestedTerminalAction);
  }

  acceptNoRuntimeTerminal(ownerScopeId: string, accountGeneration: number,
    hostId: string, appId: string, nowMs: number): void {
    if (!this.matches(ownerScopeId, accountGeneration, hostId, appId)) { return; }
    const marker: MoonlightSessionRecoveryMarker =
      this.marker as MoonlightSessionRecoveryMarker;
    if (marker.lastRequestedTerminalAction === 'disconnect') {
      if (this.store !== null && this.store.clear(marker.sessionId)) {
        this.resetBinding();
      }
      return;
    }
    if (marker.lastRequestedTerminalAction === 'quit') {
      this.update('terminal_pending', nowMs, false, 'quit');
      return;
    }
    this.update('terminal_uncertain', nowMs, false, 'none');
  }

  acceptHostQuitReceipt(ownerScopeId: string, accountGeneration: number,
    hostId: string, appId: string,
    receipt: MoonlightSessionRecoveryHostQuitReceipt,
    nowMs: number): boolean {
    if (!this.matches(ownerScopeId, accountGeneration, hostId, appId) ||
        receipt === undefined || receipt === null ||
        !Number.isSafeInteger(nowMs) || nowMs <= 0) {
      return false;
    }
    const marker: MoonlightSessionRecoveryMarker =
      this.marker as MoonlightSessionRecoveryMarker;
    // Host quit is phase two. Never let a caller skip the typed native
    // terminal/input-neutrality receipt from phase one.
    if (marker.lastRequestedTerminalAction !== 'quit' ||
        marker.lastStage !== 'terminal_pending' || marker.inputMayBeStuck) {
      return false;
    }
    const confirmedIdle: boolean = receipt.code === 'ok' &&
      receipt.preflightTruth === 'confirmed' &&
      receipt.postconditionTruth === 'confirmed' &&
      (receipt.idempotent || receipt.actionTruth === 'confirmed');
    const expectedAppAlreadyGone: boolean = receipt.code === 'stale' &&
      receipt.preflightTruth === 'confirmed';
    if ((confirmedIdle || expectedAppAlreadyGone) && this.store !== null &&
        this.store.clear(marker.sessionId)) {
      this.resetBinding();
      return true;
    }
    // The stream itself is already neutral, so retain only host-state
    // uncertainty. This marker lets the next process perform a read-only
    // serverinfo preflight without claiming the quit succeeded.
    this.update('terminal_uncertain', nowMs, false, 'quit');
    return false;
  }

  resetForTest(): void { this.resetBinding(); }

  private matches(ownerScopeId: string, accountGeneration: number,
    hostId: string, appId: string): boolean {
    return this.store !== null && this.marker !== null &&
      this.ownerScopeId === ownerScopeId.trim() &&
      this.accountGeneration === accountGeneration &&
      this.hostId === hostId.trim() && this.appId === appId.trim();
  }

  private update(stage: MoonlightSessionRecoveryStage, nowMs: number,
    inputMayBeStuck: boolean,
    terminalAction: MoonlightSessionRecoveryTerminalAction): boolean {
    if (this.store === null || this.marker === null ||
        !Number.isSafeInteger(nowMs) || nowMs <= 0) { return false; }
    const heartbeatAt: number = Math.max(nowMs, this.marker.lastHeartbeatAt);
    const next: MoonlightSessionRecoveryMarker | null = this.store.update(
      this.marker.sessionId, {
        stage: stage,
        heartbeatAt: heartbeatAt,
        hostAppMayStillBeRunning: true,
        inputMayBeStuck: inputMayBeStuck,
        terminalAction: terminalAction
      });
    if (next === null) { return false; }
    this.marker = next;
    return true;
  }

  private resetBinding(): void {
    this.store = null;
    this.marker = null;
    this.ownerScopeId = '';
    this.accountGeneration = 0;
    this.hostId = '';
    this.appId = '';
  }

  private clone(marker: MoonlightSessionRecoveryMarker):
    MoonlightSessionRecoveryMarker {
    return {
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
      lastStage: marker.lastStage,
      lastHeartbeatAt: marker.lastHeartbeatAt,
      hostAppMayStillBeRunning: marker.hostAppMayStillBeRunning,
      inputMayBeStuck: marker.inputMayBeStuck,
      lastRequestedTerminalAction: marker.lastRequestedTerminalAction
    };
  }
}
