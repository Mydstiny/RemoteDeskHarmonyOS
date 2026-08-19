/**
 * Process-local ownership boundary for independent remote-session windows.
 *
 * Secrets and one-shot trust handoffs stay in memory. The system Want only
 * receives the opaque window id, preventing credentials from entering mission
 * metadata, logs, or system persistence.
 */
import { util } from '@kit.ArkTS';
import { ExtensionLoader } from './ExtensionLoader';
import {
  ActiveRemoteSessionRecord,
  ActiveRemoteSessionRegistry,
  ActiveRemoteSessionRestoreAdoption,
  ActiveRemoteSessionTermination
} from './ActiveRemoteSessionRegistry';
import { SshTerminalTabStore } from './SshTerminalTabStore';
import { SshTerminalTranscriptStore } from './SshTerminalTranscriptStore';
import { TerminalCoreRegistry } from './TerminalCoreRegistry';
import { SshTerminalRendererRegistry } from './SshTerminalRendererRegistry';
import { SshSessionStore } from './SshSessionStore';
import {
  SshSessionHandle,
  SshSessionLifecycleState
} from './SshSessionStore';
import { SshNativeFacade } from './SshNativeFacade';
import {
  SshForwardingController,
  SshForwardingNativePort
} from './SshForwardingController';
import {
  SshForwardingConfig,
  SshForwardingSnapshotsResult
} from '../types/rdpnapi';
import { RemoteProtocol } from './RemoteSessionState';
import {
  RemoteSessionWindowRequest,
  remoteSessionWindowPage,
  remoteSessionWindowRequestIsValid
} from './RemoteSessionWindowPolicy';
import { RemoteSessionWindowFrameController } from './RemoteSessionWindowFrameController';
import { RemoteSessionWindowReadinessBarrier } from './RemoteSessionWindowReadiness';

export type RemoteSessionWindowState =
  'pending' | 'active' | 'page_ready' | 'content_ready' | 'closing';

/** Structural contract shared by the legacy singleton and a window-local registry. */
export interface RemoteSessionRecordRegistry {
  bindScope(ownerScopeId: string, accountGeneration: number): void;
  setActive(record: ActiveRemoteSessionRecord,
    adoption?: ActiveRemoteSessionRestoreAdoption | null): boolean;
  reserveActive(record: ActiveRemoteSessionRecord): boolean;
  promoteReserved(ownerScopeId: string, accountGeneration: number, reservationSessionId: number,
    next: ActiveRemoteSessionRecord): boolean;
  rotateMoonlightToReconnectReservation(ownerScopeId: string, accountGeneration: number,
    currentSessionId: number, reservationSessionId: number, hostId: string): boolean;
  getActive(): ActiveRemoteSessionRecord | null;
  hasRestorePending(ownerScopeId: string, accountGeneration: number,
    hostId: string, sessionId: number): boolean;
  beginRestoreAdoption(record: ActiveRemoteSessionRecord):
    ActiveRemoteSessionRestoreAdoption | null;
  isRestoreAdoptionCurrent(adoption: ActiveRemoteSessionRestoreAdoption | null): boolean;
  isRestoreOwnerCurrent(adoption: ActiveRemoteSessionRestoreAdoption | null): boolean;
  completeRestoreAdoption(adoption: ActiveRemoteSessionRestoreAdoption | null): boolean;
  beginTermination(record: ActiveRemoteSessionRecord,
    adoption: ActiveRemoteSessionRestoreAdoption | null):
    ActiveRemoteSessionTermination | null;
  isTerminationCurrent(termination: ActiveRemoteSessionTermination | null): boolean;
  completeTermination(termination: ActiveRemoteSessionTermination | null): boolean;
  markRenderDetached(adoption?: ActiveRemoteSessionRestoreAdoption | null): boolean;
  markRenderAttached(surfaceId: string,
    adoption?: ActiveRemoteSessionRestoreAdoption | null): boolean;
  markRestoreNeeded(value: boolean,
    adoption?: ActiveRemoteSessionRestoreAdoption | null): boolean;
  clear(reason: string): void;
  clearIfMatches(ownerScopeId: string, accountGeneration: number, sessionId: number,
    protocol: RemoteProtocol,
    adoption?: ActiveRemoteSessionRestoreAdoption | null): boolean;
}

class WindowRemoteSessionRecordRegistry implements RemoteSessionRecordRegistry {
  private ownerScopeId: string = '';
  private accountGeneration: number = 0;
  private active: ActiveRemoteSessionRecord | null = null;
  private restoreAdoptionEpoch: number = 0;
  private restoreAdoption: ActiveRemoteSessionRestoreAdoption | null = null;
  private terminationEpoch: number = 0;
  private termination: ActiveRemoteSessionTermination | null = null;

  bindScope(ownerScopeId: string, accountGeneration: number): void {
    const nextOwner: string = ownerScopeId.trim();
    const nextGeneration: number = Math.max(0, Math.floor(accountGeneration));
    if (this.ownerScopeId !== nextOwner || this.accountGeneration !== nextGeneration) {
      this.active = null;
      this.restoreAdoption = null;
      this.termination = null;
    }
    this.ownerScopeId = nextOwner;
    this.accountGeneration = nextGeneration;
  }

  setActive(record: ActiveRemoteSessionRecord,
    adoption: ActiveRemoteSessionRestoreAdoption | null = null): boolean {
    if (this.termination !== null || !this.restoreOwnerAllows(adoption)) { return false; }
    if (record.ownerScopeId.trim() === '' || record.accountGeneration <= 0 || record.sessionId <= 0 ||
      record.ownerScopeId !== this.ownerScopeId || record.accountGeneration !== this.accountGeneration) {
      return false;
    }
    if (this.active !== null && (this.active.sessionId !== record.sessionId ||
      this.active.protocol !== record.protocol)) {
      return false;
    }
    const now: number = Date.now();
    this.active = this.cloneRecord(record, now);
    return true;
  }

  reserveActive(record: ActiveRemoteSessionRecord): boolean {
    return this.active === null && this.setActive(record);
  }

  promoteReserved(ownerScopeId: string, accountGeneration: number, reservationSessionId: number,
    next: ActiveRemoteSessionRecord): boolean {
    if (this.termination !== null || !this.restoreOwnerAllows(null)) { return false; }
    if (this.active === null || this.active.ownerScopeId !== ownerScopeId ||
      this.active.accountGeneration !== accountGeneration ||
      this.active.sessionId !== reservationSessionId) {
      return false;
    }
    this.active = this.cloneRecord(next, Date.now());
    return true;
  }

  rotateMoonlightToReconnectReservation(ownerScopeId: string, accountGeneration: number,
    currentSessionId: number, reservationSessionId: number, hostId: string): boolean {
    if (this.termination !== null || !this.restoreOwnerAllows(null)) { return false; }
    if (this.active === null || this.active.ownerScopeId !== ownerScopeId ||
      this.active.accountGeneration !== accountGeneration || this.active.sessionId !== currentSessionId ||
      reservationSessionId <= 0 || this.active.hostId !== hostId) {
      return false;
    }
    this.active.sessionId = reservationSessionId;
    this.active.protocolConnected = false;
    this.active.renderAttached = false;
    this.active.restoreNeeded = true;
    this.active.latestSurfaceId = '';
    this.active.updatedAtMs = Date.now();
    return true;
  }

  getActive(): ActiveRemoteSessionRecord | null {
    return this.active === null ? null : this.cloneRecord(this.active, this.active.updatedAtMs);
  }

  hasRestorePending(ownerScopeId: string, accountGeneration: number,
    hostId: string, sessionId: number): boolean {
    const active: ActiveRemoteSessionRecord | null = this.active;
    return active !== null && active.ownerScopeId === ownerScopeId &&
      active.accountGeneration === accountGeneration && active.hostId === hostId &&
      active.sessionId === sessionId && active.protocolConnected && active.restoreNeeded;
  }

  beginRestoreAdoption(
    record: ActiveRemoteSessionRecord
  ): ActiveRemoteSessionRestoreAdoption | null {
    const active: ActiveRemoteSessionRecord | null = this.active;
    if (this.termination !== null || active === null ||
        !active.protocolConnected || !active.restoreNeeded ||
        active.ownerScopeId !== record.ownerScopeId ||
        active.accountGeneration !== record.accountGeneration ||
        active.sessionId !== record.sessionId || active.hostId !== record.hostId ||
        active.protocol !== record.protocol ||
        this.restoreAdoptionEpoch >= Number.MAX_SAFE_INTEGER) {
      return null;
    }
    this.restoreAdoptionEpoch += 1;
    const adoption: ActiveRemoteSessionRestoreAdoption = {
      ownerScopeId: active.ownerScopeId,
      accountGeneration: active.accountGeneration,
      sessionId: active.sessionId,
      hostId: active.hostId,
      protocol: active.protocol,
      epoch: this.restoreAdoptionEpoch
    };
    this.restoreAdoption = this.cloneAdoption(adoption);
    return this.cloneAdoption(adoption);
  }

  isRestoreAdoptionCurrent(
    adoption: ActiveRemoteSessionRestoreAdoption | null
  ): boolean {
    const active: ActiveRemoteSessionRecord | null = this.active;
    const current: ActiveRemoteSessionRestoreAdoption | null = this.restoreAdoption;
    return adoption !== null && current !== null && active !== null &&
      active.protocolConnected &&
      current.ownerScopeId === adoption.ownerScopeId &&
      current.accountGeneration === adoption.accountGeneration &&
      current.sessionId === adoption.sessionId && current.hostId === adoption.hostId &&
      current.protocol === adoption.protocol && current.epoch === adoption.epoch &&
      active.ownerScopeId === adoption.ownerScopeId &&
      active.accountGeneration === adoption.accountGeneration &&
      active.sessionId === adoption.sessionId && active.hostId === adoption.hostId &&
      active.protocol === adoption.protocol;
  }

  isRestoreOwnerCurrent(
    adoption: ActiveRemoteSessionRestoreAdoption | null
  ): boolean {
    return this.termination === null && this.active !== null &&
      this.active.protocolConnected && this.restoreOwnerAllows(adoption);
  }

  completeRestoreAdoption(
    adoption: ActiveRemoteSessionRestoreAdoption | null
  ): boolean {
    const current: ActiveRemoteSessionRestoreAdoption | null = this.restoreAdoption;
    const active: ActiveRemoteSessionRecord | null = this.active;
    if (adoption === null || current === null || active === null ||
        current.epoch !== adoption.epoch ||
        current.ownerScopeId !== adoption.ownerScopeId ||
        current.accountGeneration !== adoption.accountGeneration ||
        current.sessionId !== adoption.sessionId || current.hostId !== adoption.hostId ||
        current.protocol !== adoption.protocol ||
        active.ownerScopeId !== adoption.ownerScopeId ||
        active.accountGeneration !== adoption.accountGeneration ||
        active.sessionId !== adoption.sessionId || active.hostId !== adoption.hostId ||
        active.protocol !== adoption.protocol) {
      return false;
    }
    // Keep the successful adopter as the process-local session owner until an
    // exact termination or a newer page reconstruction supersedes it.
    return true;
  }

  beginTermination(record: ActiveRemoteSessionRecord,
    adoption: ActiveRemoteSessionRestoreAdoption | null):
    ActiveRemoteSessionTermination | null {
    const active: ActiveRemoteSessionRecord | null = this.active;
    if (this.termination !== null || active === null ||
        active.ownerScopeId !== record.ownerScopeId ||
        active.accountGeneration !== record.accountGeneration ||
        active.sessionId !== record.sessionId || active.hostId !== record.hostId ||
        active.protocol !== record.protocol ||
        this.terminationEpoch >= Number.MAX_SAFE_INTEGER) {
      return null;
    }
    if (this.restoreAdoption === null) {
      if (adoption !== null) { return null; }
    } else if (!this.adoptionEquals(this.restoreAdoption, adoption)) {
      return null;
    }
    this.terminationEpoch += 1;
    const termination: ActiveRemoteSessionTermination = {
      ownerScopeId: active.ownerScopeId,
      accountGeneration: active.accountGeneration,
      sessionId: active.sessionId,
      hostId: active.hostId,
      protocol: active.protocol,
      epoch: this.terminationEpoch
    };
    this.termination = this.cloneTermination(termination);
    this.restoreAdoption = null;
    return this.cloneTermination(termination);
  }

  isTerminationCurrent(
    termination: ActiveRemoteSessionTermination | null
  ): boolean {
    const active: ActiveRemoteSessionRecord | null = this.active;
    const current: ActiveRemoteSessionTermination | null = this.termination;
    return termination !== null && current !== null && active !== null &&
      current.ownerScopeId === termination.ownerScopeId &&
      current.accountGeneration === termination.accountGeneration &&
      current.sessionId === termination.sessionId && current.hostId === termination.hostId &&
      current.protocol === termination.protocol && current.epoch === termination.epoch &&
      active.ownerScopeId === termination.ownerScopeId &&
      active.accountGeneration === termination.accountGeneration &&
      active.sessionId === termination.sessionId && active.hostId === termination.hostId &&
      active.protocol === termination.protocol;
  }

  completeTermination(
    termination: ActiveRemoteSessionTermination | null
  ): boolean {
    if (!this.isTerminationCurrent(termination)) { return false; }
    this.clear('terminated-session-clear');
    return true;
  }

  markRenderDetached(
    adoption: ActiveRemoteSessionRestoreAdoption | null = null
  ): boolean {
    if (this.termination !== null || !this.restoreOwnerAllows(adoption)) { return false; }
    if (this.active === null) { return false; }
    this.active.renderAttached = false;
    this.active.restoreNeeded = true;
    this.active.updatedAtMs = Date.now();
    return true;
  }

  markRenderAttached(surfaceId: string,
    adoption: ActiveRemoteSessionRestoreAdoption | null = null): boolean {
    if (this.termination !== null || !this.restoreOwnerAllows(adoption)) { return false; }
    if (this.active === null) { return false; }
    this.active.renderAttached = true;
    this.active.restoreNeeded = false;
    this.active.latestSurfaceId = surfaceId;
    this.active.updatedAtMs = Date.now();
    return true;
  }

  markRestoreNeeded(value: boolean,
    adoption: ActiveRemoteSessionRestoreAdoption | null = null): boolean {
    if (this.termination !== null || !this.restoreOwnerAllows(adoption)) { return false; }
    if (this.active === null) { return false; }
    this.active.restoreNeeded = value;
    this.active.updatedAtMs = Date.now();
    return true;
  }

  clear(_reason: string): void {
    this.active = null;
    this.restoreAdoption = null;
    this.termination = null;
  }

  clearIfMatches(ownerScopeId: string, accountGeneration: number, sessionId: number,
    protocol: RemoteProtocol,
    adoption: ActiveRemoteSessionRestoreAdoption | null = null): boolean {
    if (this.termination !== null || !this.restoreOwnerAllows(adoption)) { return false; }
    if (this.active === null || this.active.ownerScopeId !== ownerScopeId ||
      this.active.accountGeneration !== accountGeneration || this.active.sessionId !== sessionId ||
      this.active.protocol !== protocol) {
      return false;
    }
    this.active = null;
    this.restoreAdoption = null;
    this.termination = null;
    return true;
  }

  private cloneAdoption(
    adoption: ActiveRemoteSessionRestoreAdoption
  ): ActiveRemoteSessionRestoreAdoption {
    return {
      ownerScopeId: adoption.ownerScopeId,
      accountGeneration: adoption.accountGeneration,
      sessionId: adoption.sessionId,
      hostId: adoption.hostId,
      protocol: adoption.protocol,
      epoch: adoption.epoch
    };
  }

  private adoptionEquals(left: ActiveRemoteSessionRestoreAdoption,
    right: ActiveRemoteSessionRestoreAdoption | null): boolean {
    return right !== null && left.ownerScopeId === right.ownerScopeId &&
      left.accountGeneration === right.accountGeneration &&
      left.sessionId === right.sessionId && left.hostId === right.hostId &&
      left.protocol === right.protocol && left.epoch === right.epoch;
  }

  private restoreOwnerAllows(
    adoption: ActiveRemoteSessionRestoreAdoption | null
  ): boolean {
    if (this.restoreAdoption === null) { return adoption === null; }
    return this.adoptionEquals(this.restoreAdoption, adoption);
  }

  private cloneTermination(
    termination: ActiveRemoteSessionTermination
  ): ActiveRemoteSessionTermination {
    return {
      ownerScopeId: termination.ownerScopeId,
      accountGeneration: termination.accountGeneration,
      sessionId: termination.sessionId,
      hostId: termination.hostId,
      protocol: termination.protocol,
      epoch: termination.epoch
    };
  }

  private cloneRecord(record: ActiveRemoteSessionRecord, updatedAtMs: number): ActiveRemoteSessionRecord {
    return {
      ownerScopeId: record.ownerScopeId,
      accountGeneration: record.accountGeneration,
      sessionId: record.sessionId,
      hostId: record.hostId,
      protocol: record.protocol,
      hostAddress: record.hostAddress,
      protocolConnected: record.protocolConnected,
      renderAttached: record.renderAttached,
      restoreNeeded: record.restoreNeeded,
      latestSurfaceId: record.latestSurfaceId,
      createdAtMs: record.createdAtMs,
      updatedAtMs
    };
  }
}

class WindowSshForwardingNativePort implements SshForwardingNativePort {
  private readonly facade: SshNativeFacade;

  constructor(facade: SshNativeFacade) { this.facade = facade; }

  accepts(handle: SshSessionHandle): boolean { return this.facade.accepts(handle); }

  forwardingSessionState(handle: SshSessionHandle): SshSessionLifecycleState | '' {
    return this.facade.forwardingSessionState(handle);
  }

  configureSshForwarding(handle: SshSessionHandle, config: SshForwardingConfig): number {
    return this.facade.configureSshForwarding(handle, config);
  }

  removeSshForwarding(handle: SshSessionHandle, id: string): number {
    return this.facade.removeSshForwarding(handle, id);
  }

  startSshForwarding(handle: SshSessionHandle, id: string): number {
    return this.facade.startSshForwarding(handle, id);
  }

  stopSshForwarding(handle: SshSessionHandle, id: string): number {
    return this.facade.stopSshForwarding(handle, id);
  }

  completeSshForwardingStop(handle: SshSessionHandle, id: string): number {
    return this.facade.completeSshForwardingStop(handle, id);
  }

  acquireSshForwardingConnection(handle: SshSessionHandle, id: string): number {
    return this.facade.acquireSshForwardingConnection(handle, id);
  }

  releaseSshForwardingConnection(handle: SshSessionHandle, id: string): number {
    return this.facade.releaseSshForwardingConnection(handle, id);
  }

  getSshForwardingSnapshots(handle: SshSessionHandle): SshForwardingSnapshotsResult {
    return this.facade.getSshForwardingSnapshots(handle);
  }
}

export class RemoteSessionWindowRuntime {
  readonly loader: ExtensionLoader = new ExtensionLoader();
  readonly activeSessionRegistry: RemoteSessionRecordRegistry =
    new WindowRemoteSessionRecordRegistry();
  readonly sshTabStore: SshTerminalTabStore = new SshTerminalTabStore();
  readonly sshTranscriptStore: SshTerminalTranscriptStore = new SshTerminalTranscriptStore();
  readonly terminalCoreRegistry: TerminalCoreRegistry = new TerminalCoreRegistry();
  readonly sshTerminalRendererRegistry: SshTerminalRendererRegistry =
    new SshTerminalRendererRegistry();
  readonly sshSessionStore: SshSessionStore = new SshSessionStore();
  readonly sshNativeFacade: SshNativeFacade;
  readonly sshForwardingController: SshForwardingController;

  constructor() {
    this.sshNativeFacade = new SshNativeFacade(this.loader, this.sshSessionStore);
    this.sshForwardingController = new SshForwardingController(
      new WindowSshForwardingNativePort(this.sshNativeFacade));
  }

  closeNativeSessions(): void {
    const sshSessionIds: number[] = this.sshTabStore.closeAll();
    for (let index: number = 0; index < sshSessionIds.length; index++) {
      this.loader.disconnectSshSession(sshSessionIds[index]);
    }
    this.loader.disconnect();
    this.activeSessionRegistry.clear('session-window-closed');
  }
}

/** Live-session ownership supplied only after an existing auth flow commits. */
export class RemoteSessionWindowNativeHandoff {
  sourceLoader: ExtensionLoader;
  sourceRegistry: ActiveRemoteSessionRegistry;
  activeRecord: ActiveRemoteSessionRecord;

  constructor(sourceLoader: ExtensionLoader, sourceRegistry: ActiveRemoteSessionRegistry,
    activeRecord: ActiveRemoteSessionRecord) {
    this.sourceLoader = sourceLoader;
    this.sourceRegistry = sourceRegistry;
    this.activeRecord = activeRecord;
  }
}

export class AppliedRemoteSessionWindowNativeHandoff extends RemoteSessionWindowNativeHandoff {
  transferred: boolean;

  constructor(sourceLoader: ExtensionLoader, sourceRegistry: ActiveRemoteSessionRegistry,
    activeRecord: ActiveRemoteSessionRecord, transferred: boolean) {
    super(sourceLoader, sourceRegistry, activeRecord);
    this.transferred = transferred;
  }
}

export interface RemoteSessionWindowRecord {
  id: string;
  page: string;
  state: RemoteSessionWindowState;
  createdAtMs: number;
  request: RemoteSessionWindowRequest;
  runtime: RemoteSessionWindowRuntime;
  frameController: RemoteSessionWindowFrameController;
  nativeHandoff: AppliedRemoteSessionWindowNativeHandoff | null;
  readinessBarrier: RemoteSessionWindowReadinessBarrier;
  closeTarget: (() => void) | null;
}

export class RemoteSessionWindowCoordinator {
  private static instance: RemoteSessionWindowCoordinator | null = null;
  private records: Map<string, RemoteSessionWindowRecord> =
    new Map<string, RemoteSessionWindowRecord>();
  private launchSequence: number = 0;

  static getInstance(): RemoteSessionWindowCoordinator {
    if (RemoteSessionWindowCoordinator.instance === null) {
      RemoteSessionWindowCoordinator.instance = new RemoteSessionWindowCoordinator();
    }
    return RemoteSessionWindowCoordinator.instance;
  }

  reserve(request: RemoteSessionWindowRequest,
    nativeHandoff: RemoteSessionWindowNativeHandoff | null = null): RemoteSessionWindowRecord | null {
    if (!remoteSessionWindowRequestIsValid(request)) { return null; }
    let id: string = util.generateRandomUUID(true);
    while (this.records.has(id)) { id = util.generateRandomUUID(true); }
    const routeParams: Record<string, Object> = {};
    Object.keys(request.routeParams).forEach((key: string): void => {
      routeParams[key] = request.routeParams[key];
    });
    const storedRequest: RemoteSessionWindowRequest = {
      target: request.target,
      protocol: request.protocol,
      hostId: request.hostId.trim(),
      title: request.title.trim(),
      authorizationToken: request.authorizationToken.trim(),
      routeParams
    };
    const record: RemoteSessionWindowRecord = {
      id,
      page: remoteSessionWindowPage(request.target),
      state: 'pending',
      createdAtMs: Date.now(),
      request: storedRequest,
      runtime: new RemoteSessionWindowRuntime(),
      frameController: new RemoteSessionWindowFrameController(),
      nativeHandoff: null,
      readinessBarrier: new RemoteSessionWindowReadinessBarrier(),
      closeTarget: null
    };
    if (nativeHandoff !== null && !this.applyNativeHandoff(record, nativeHandoff)) {
      return null;
    }
    this.records.set(id, record);
    this.launchSequence += 1;
    return record;
  }

  activate(id: string): RemoteSessionWindowRecord | null {
    const record: RemoteSessionWindowRecord | undefined = this.records.get(id.trim());
    if (record === undefined || record.state === 'closing') { return null; }
    if (record.state === 'pending') { record.state = 'active'; }
    return record;
  }

  registerTargetCloser(id: string, closeTarget: () => void): boolean {
    const record: RemoteSessionWindowRecord | undefined = this.records.get(id.trim());
    if (record === undefined || record.state === 'closing') { return false; }
    record.closeTarget = closeTarget;
    return true;
  }

  markPageReady(id: string): boolean {
    const record: RemoteSessionWindowRecord | undefined = this.records.get(id.trim());
    if (record === undefined || record.state === 'closing') { return false; }
    if (record.state === 'content_ready') { return true; }
    record.state = 'page_ready';
    // Non-live targets do not transfer an authenticated native session and do
    // not need the source-side two-phase ownership barrier.
    return record.nativeHandoff === null ? this.markContentReady(id) : true;
  }

  markContentReady(id: string): boolean {
    const record: RemoteSessionWindowRecord | undefined = this.records.get(id.trim());
    if (record === undefined || record.state === 'closing') { return false; }
    if (record.state === 'content_ready') { return true; }
    record.state = 'content_ready';
    // The target page is now the only owner. Drop rollback references to the
    // originating page/runtime so later window closure can only disconnect
    // the target session and can never resurrect the source owner.
    record.nativeHandoff = null;
    record.readinessBarrier.markReady();
    void record.frameController.promoteInteractive();
    return true;
  }

  async waitUntilContentReady(id: string, timeoutMs: number): Promise<boolean> {
    const record: RemoteSessionWindowRecord | undefined = this.records.get(id.trim());
    if (record === undefined || record.state === 'closing') { return false; }
    if (record.state === 'content_ready') { return true; }
    return await record.readinessBarrier.wait(timeoutMs);
  }

  isContentReady(id: string): boolean {
    return this.records.get(id.trim())?.state === 'content_ready';
  }

  resolve(id: string): RemoteSessionWindowRecord | null {
    return this.records.get(id.trim()) ?? null;
  }

  rollbackReservation(id: string): boolean {
    const normalized: string = id.trim();
    const record: RemoteSessionWindowRecord | undefined = this.records.get(normalized);
    if (record === undefined) { return false; }
    return this.rollbackBeforeReady(normalized, record, true, 'window-launch-rollback');
  }

  failBeforeReady(id: string, reason: string): boolean {
    const normalized: string = id.trim();
    const record: RemoteSessionWindowRecord | undefined = this.records.get(normalized);
    if (record === undefined) { return false; }
    return this.rollbackBeforeReady(normalized, record, true, reason);
  }

  release(id: string): boolean {
    const normalized: string = id.trim();
    const record: RemoteSessionWindowRecord | undefined = this.records.get(normalized);
    if (record === undefined) { return false; }
    if (record.state !== 'content_ready') {
      return this.rollbackBeforeReady(
        normalized, record, false, 'target-released-before-ready');
    }
    record.state = 'closing';
    record.readinessBarrier.fail();
    record.frameController.detach();
    record.runtime.closeNativeSessions();
    this.records.delete(normalized);
    return true;
  }

  hasOpenOrPendingWindows(): boolean { return this.records.size > 0; }

  /**
   * Main-window lifecycle must not tear down a background task owned by an
   * independent session Ability.  Keep the query protocol-scoped so bringing
   * the host list foreground does not accidentally preserve an unrelated SSH
   * task merely because an RDP/VNC/RustDesk window is still open.
   */
  hasOpenOrPendingWindowForProtocol(protocol: string): boolean {
    const normalized: string = protocol.trim();
    if (normalized.length === 0) { return false; }
    let found: boolean = false;
    this.records.forEach((record: RemoteSessionWindowRecord): void => {
      if (record.request.protocol === normalized) { found = true; }
    });
    return found;
  }

  activeWindowCount(): number { return this.records.size; }

  nextPlacementSequence(): number { return this.launchSequence; }

  async toggleFullscreen(id: string): Promise<boolean> {
    const record: RemoteSessionWindowRecord | undefined = this.records.get(id.trim());
    if (record === undefined || record.state === 'closing') { return false; }
    return await record.frameController.toggle();
  }

  async promoteTargetWindow(id: string): Promise<boolean> {
    const record: RemoteSessionWindowRecord | undefined = this.records.get(id.trim());
    if (record === undefined || record.state !== 'content_ready') { return false; }
    return await record.frameController.promoteInteractive();
  }

  resetForTest(): void {
    const ids: string[] = Array.from(this.records.keys());
    for (let index: number = 0; index < ids.length; index++) { this.release(ids[index]); }
    this.launchSequence = 0;
  }

  private applyNativeHandoff(record: RemoteSessionWindowRecord,
    handoff: RemoteSessionWindowNativeHandoff): boolean {
    const active: ActiveRemoteSessionRecord = handoff.activeRecord;
    const sourceActive: ActiveRemoteSessionRecord | null = handoff.sourceRegistry.getActive();
    if (active.sessionId <= 0 || active.hostId !== record.request.hostId ||
      (active.protocol as string) !== record.request.protocol || sourceActive === null ||
      sourceActive.sessionId !== active.sessionId || sourceActive.hostId !== active.hostId ||
      sourceActive.ownerScopeId !== active.ownerScopeId ||
      sourceActive.accountGeneration !== active.accountGeneration) {
      return false;
    }
    record.runtime.activeSessionRegistry.bindScope(
      active.ownerScopeId, active.accountGeneration);
    if (!record.runtime.activeSessionRegistry.setActive(active)) { return false; }
    if (!handoff.sourceLoader.transferActiveSessionTo(
      record.runtime.loader, active.sessionId)) {
      record.runtime.activeSessionRegistry.clear('window-handoff-loader-rejected');
      return false;
    }
    if (!handoff.sourceRegistry.clearIfMatches(
      active.ownerScopeId, active.accountGeneration, active.sessionId, active.protocol)) {
      record.runtime.loader.transferActiveSessionTo(handoff.sourceLoader, active.sessionId);
      record.runtime.activeSessionRegistry.clear('window-handoff-registry-rejected');
      return false;
    }
    record.nativeHandoff = new AppliedRemoteSessionWindowNativeHandoff(
      handoff.sourceLoader, handoff.sourceRegistry, active, true);
    return true;
  }

  private rollbackBeforeReady(id: string, record: RemoteSessionWindowRecord,
    terminateTarget: boolean, reason: string): boolean {
    if (record.state === 'content_ready' || record.state === 'closing') { return false; }
    record.state = 'closing';
    const closeTarget: (() => void) | null = record.closeTarget;
    const handoff: AppliedRemoteSessionWindowNativeHandoff | null = record.nativeHandoff;
    if (handoff !== null && handoff.transferred) {
      this.restoreNativeHandoff(record, handoff, reason);
    } else {
      record.runtime.closeNativeSessions();
    }
    record.nativeHandoff = null;
    record.readinessBarrier.fail();
    record.frameController.detach();
    this.records.delete(id);
    if (terminateTarget && closeTarget !== null) {
      try { closeTarget(); } catch (_err) {}
    }
    return true;
  }

  private restoreNativeHandoff(record: RemoteSessionWindowRecord,
    handoff: AppliedRemoteSessionWindowNativeHandoff, reason: string): boolean {
    const active: ActiveRemoteSessionRecord = handoff.activeRecord;
    const transferred: boolean = record.runtime.loader.transferActiveSessionTo(
      handoff.sourceLoader, active.sessionId);
    let registryRestored: boolean = false;
    if (transferred) {
      handoff.sourceRegistry.bindScope(active.ownerScopeId, active.accountGeneration);
      registryRestored = handoff.sourceRegistry.setActive(active);
    }
    record.runtime.activeSessionRegistry.clear(reason);
    handoff.transferred = false;
    if (transferred && registryRestored) { return true; }
    if (transferred) {
      // A registry refusal leaves the session with no safe source owner. Move
      // it back to the target runtime and close it there rather than leaking or
      // attaching it to an unrelated source-page generation.
      handoff.sourceLoader.transferActiveSessionTo(record.runtime.loader, active.sessionId);
    }
    record.runtime.closeNativeSessions();
    return false;
  }
}
