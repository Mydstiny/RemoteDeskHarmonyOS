import { describe, expect, it } from '@ohos/hypium';
import {
  ActiveRemoteSessionRegistry,
  ActiveRemoteSessionRecord
} from '../main/ets/services/ActiveRemoteSessionRegistry';
import {
  MoonlightCoordinatorEvent,
  MoonlightRuntimePort,
  MoonlightRuntimePollScheduler,
  MoonlightSessionCoordinator,
  MoonlightSessionStartRequest,
  moonlightRuntimeNativeError,
  moonlightRuntimePollDelayMs,
  moonlightRuntimePollShouldLock,
  moonlightRuntimeReadinessEvents
} from '../main/ets/services/MoonlightSessionCoordinator';
import { RemoteProtocol } from '../main/ets/services/RemoteSessionState';
import { MoonlightSessionStateSnapshot } from '../main/ets/services/MoonlightSessionState';
import { defaultMoonlightSettings } from '../main/ets/model/MoonlightModels';
import {
  encodeMoonlightEffectiveSettings,
  resolveMoonlightProductSettings
} from '../main/ets/services/MoonlightSettingsPolicy';
import { MoonlightNativeStreamSnapshot } from '../main/ets/services/MoonlightHostService';
import {
  MoonlightRuntimeOwnerRegistry
} from '../main/ets/services/MoonlightRuntimeOwnerRegistry';

class FakeMoonlightRuntime implements MoonlightRuntimePort {
  startCalls: number = 0;
  cancelCalls: number = 0;
  stopCalls: number = 0;
  suspendSurfaceCalls: number = 0;
  rebindSurfaceCalls: number = 0;
  audioLifecycleCalls: number = 0;
  lastAddress: string = '';
  startResult: boolean = true;
  cancelResult: boolean = true;
  stopResult: boolean = true;
  surfaceLifecycleResult: boolean = true;
  audioLifecycleResult: boolean = true;
  currentSnapshot: MoonlightNativeStreamSnapshot | null = null;
  nativeId: number = 42;
  lastOperationGeneration: number = 0;

  start(request: MoonlightSessionStartRequest, operationGeneration: number): boolean {
    this.startCalls += 1;
    this.lastAddress = request.hostAddress;
    this.lastOperationGeneration = operationGeneration;
    return this.startResult;
  }

  cancel(_operationGeneration: number, _reason: string): boolean {
    this.cancelCalls += 1;
    return this.cancelResult;
  }

  stop(_nativeSessionId: number, _reason: string): boolean {
    this.stopCalls += 1;
    return this.stopResult;
  }

  nativeSessionId(_operationGeneration: number): number { return this.nativeId; }

  snapshot(_operationGeneration: number): MoonlightNativeStreamSnapshot | null {
    return this.currentSnapshot;
  }

  suspendSurface(_operationGeneration: number): boolean {
    this.suspendSurfaceCalls += 1;
    return this.surfaceLifecycleResult;
  }

  rebindSurface(_operationGeneration: number, _rendererHandle: number): boolean {
    this.rebindSurfaceCalls += 1;
    return this.surfaceLifecycleResult;
  }

  setAudioPaused(_operationGeneration: number, _paused: boolean): boolean {
    this.audioLifecycleCalls += 1;
    return this.audioLifecycleResult;
  }
}

class FakeMoonlightRuntimePollScheduler implements MoonlightRuntimePollScheduler {
  private callback: (() => void) | null = null;
  private timerId: number = 0;
  private currentNowMs: number = Date.now();
  scheduleCalls: number = 0;
  lastDelayMs: number = -1;

  nowMs(): number { return this.currentNowMs; }

  schedule(callback: () => void, delayMs: number): number {
    this.timerId += 1;
    this.scheduleCalls += 1;
    this.lastDelayMs = delayMs;
    this.callback = callback;
    return this.timerId;
  }

  cancel(timerId: number): void {
    if (timerId === this.timerId) { this.callback = null; }
  }

  hasPending(): boolean { return this.callback !== null; }

  runNext(nowMs: number): boolean {
    const pending: (() => void) | null = this.callback;
    if (pending === null) { return false; }
    this.callback = null;
    this.currentNowMs = nowMs;
    pending();
    return true;
  }
}

function request(): MoonlightSessionStartRequest {
  return {
    ownerScopeId: 'owner-1', accountGeneration: 1, hostId: 'host-1', appId: 'app-1',
    hostAddress: '192.168.1.20', runtimeAvailable: true,
    hostControlReady: true, streamingTransportReady: true
  };
}

function productRequest(includeSurface: boolean): MoonlightSessionStartRequest {
  const value: MoonlightSessionStartRequest = request();
  value.hostControlAlreadyLaunched = true;
  value.launchKey = { requestId: 9, generation: 7, ownerToken: 11 };
  value.serverUuid = 'server-1';
  value.numericAppId = 42;
  value.effectiveSettingsEncoded = encodeMoonlightEffectiveSettings(
    resolveMoonlightProductSettings(defaultMoonlightSettings()));
  if (includeSurface) {
    value.rendererHandle = 101;
    value.surfaceWidth = 1920;
    value.surfaceHeight = 1080;
    value.surfaceId = 'surface-1';
  }
  return value;
}

function event(type: MoonlightCoordinatorEvent['type'], generation: number,
  sequence: number, nativeSessionId: number = 0, surfaceId: string = ''):
  MoonlightCoordinatorEvent {
  return {
    type: type, generation: generation, sequence: sequence,
    nativeError: '', detailCode: '', nativeSessionId: nativeSessionId, surfaceId: surfaceId
  };
}

function activeMoonlightRecord(registry: ActiveRemoteSessionRegistry): ActiveRemoteSessionRecord | null {
  return registry.getActive();
}

function runtimeSnapshot(): MoonlightNativeStreamSnapshot {
  return {
    matched: true, code: 'first_frame', sessionId: 42, generation: 7, ownerToken: 11,
    transportReady: true, videoReady: true, audioReady: true, inputReady: true,
    controllerReady: true, physicalControllerReady: false,
    inputMayBeStuck: false, presentationFrameReady: true, firstFrameReady: true,
    terminal: false, lastSequence: 9
  };
}

function reachNegotiating(coordinator: MoonlightSessionCoordinator): number {
  const started = coordinator.start(request());
  const state: MoonlightSessionStateSnapshot = started.state as MoonlightSessionStateSnapshot;
  const generation: number = state.generation;
  coordinator.handleRuntimeEvent(event('beginVerification', generation, 2));
  coordinator.handleRuntimeEvent(event('catalogReady', generation, 3));
  coordinator.handleRuntimeEvent(event('launchRequested', generation, 4));
  coordinator.handleRuntimeEvent(event('launchAccepted', generation, 5, 42));
  return generation;
}

export default function moonlightSessionCoordinatorTest(): void {
  describe('MoonlightSessionCoordinator', (): void => {
    it('backs_off_missing_native_receipts_and_eventually_locks_fail_closed', 0,
      (): void => {
        expect(moonlightRuntimePollDelayMs(0)).assertEqual(100);
        expect(moonlightRuntimePollDelayMs(1)).assertEqual(200);
        expect(moonlightRuntimePollDelayMs(5)).assertEqual(3200);
        expect(moonlightRuntimePollDelayMs(6)).assertEqual(5000);
        expect(moonlightRuntimePollDelayMs(63)).assertEqual(5000);
        expect(moonlightRuntimePollShouldLock(63)).assertFalse();
        expect(moonlightRuntimePollShouldLock(64)).assertTrue();
        expect(moonlightRuntimePollShouldLock(-1)).assertTrue();
      });

    it('resets_the_real_poll_state_when_an_exact_snapshot_arrives_after_63_misses', 0,
      (): void => {
        const runtime: FakeMoonlightRuntime = new FakeMoonlightRuntime();
        const registry: ActiveRemoteSessionRegistry = ActiveRemoteSessionRegistry.getInstance();
        registry.resetForTest();
        registry.bindScope('owner-1', 1);
        const scheduler: FakeMoonlightRuntimePollScheduler =
          new FakeMoonlightRuntimePollScheduler();
        const coordinator: MoonlightSessionCoordinator =
          new MoonlightSessionCoordinator(runtime, registry, null, null, scheduler);
        expect(coordinator.start(productRequest(true)).accepted).assertTrue();
        const nowMs: number = Date.now();
        for (let miss: number = 0; miss < 63; miss++) {
          expect(scheduler.runNext(nowMs)).assertTrue();
        }
        runtime.currentSnapshot = runtimeSnapshot();
        expect(scheduler.runNext(nowMs)).assertTrue();
        expect(scheduler.hasPending()).assertTrue();
        expect(scheduler.lastDelayMs).assertEqual(100);
        const state: MoonlightSessionStateSnapshot =
          coordinator.snapshotForRoute('host-1', 'app-1') as
            MoonlightSessionStateSnapshot;
        expect(state.firstFrameSeen).assertTrue();
        expect(state.phase).assertEqual('streaming');
        coordinator.resetForTest();
        registry.resetForTest();
      });

    it('keeps_the_shared_registry_owned_after_the_real_poll_state_locks', 0,
      (): void => {
        const runtime: FakeMoonlightRuntime = new FakeMoonlightRuntime();
        const registry: ActiveRemoteSessionRegistry = ActiveRemoteSessionRegistry.getInstance();
        registry.resetForTest();
        registry.bindScope('owner-1', 1);
        const scheduler: FakeMoonlightRuntimePollScheduler =
          new FakeMoonlightRuntimePollScheduler();
        const coordinator: MoonlightSessionCoordinator =
          new MoonlightSessionCoordinator(runtime, registry, null, null, scheduler);
        expect(coordinator.start(productRequest(true)).accepted).assertTrue();
        const nowMs: number = Date.now();
        for (let miss: number = 0; miss < 64; miss++) {
          expect(scheduler.runNext(nowMs)).assertTrue();
        }
        expect(scheduler.hasPending()).assertFalse();
        expect(scheduler.scheduleCalls).assertEqual(64);
        const active: ActiveRemoteSessionRecord =
          activeMoonlightRecord(registry) as ActiveRemoteSessionRecord;
        expect(active.protocol).assertEqual(RemoteProtocol.moonlight);
        expect(active.sessionId).assertEqual(42);
        runtime.currentSnapshot = runtimeSnapshot();
        expect(scheduler.runNext(nowMs)).assertFalse();
        expect((activeMoonlightRecord(registry) as ActiveRemoteSessionRecord).sessionId)
          .assertEqual(42);
        coordinator.resetForTest();
        registry.resetForTest();
      });

    it('applies_first_frame_timeout_during_a_real_missing_snapshot_poll', 0,
      (): void => {
        const runtime: FakeMoonlightRuntime = new FakeMoonlightRuntime();
        const registry: ActiveRemoteSessionRegistry = ActiveRemoteSessionRegistry.getInstance();
        registry.resetForTest();
        registry.bindScope('owner-1', 1);
        const scheduler: FakeMoonlightRuntimePollScheduler =
          new FakeMoonlightRuntimePollScheduler();
        const coordinator: MoonlightSessionCoordinator =
          new MoonlightSessionCoordinator(runtime, registry, null, null, scheduler);
        expect(coordinator.start(productRequest(true)).accepted).assertTrue();
        expect(scheduler.runNext(Date.now() + 31000)).assertTrue();
        const failed: MoonlightSessionStateSnapshot =
          coordinator.snapshotForRoute('host-1', 'app-1') as MoonlightSessionStateSnapshot;
        expect(failed.phase).assertEqual('failed');
        expect(failed.errorCode).assertEqual('stream_timeout');
        expect(runtime.stopCalls).assertEqual(1);
        expect(activeMoonlightRecord(registry) !== null).assertTrue();

        const terminal: MoonlightNativeStreamSnapshot = runtimeSnapshot();
        terminal.terminal = true;
        terminal.code = 'connection_terminated';
        runtime.currentSnapshot = terminal;
        expect(scheduler.runNext(Date.now() + 32000)).assertTrue();
        expect(activeMoonlightRecord(registry)).assertNull();
        coordinator.resetForTest();
        registry.resetForTest();
      });

    it('enters_reconnect_only_after_an_exact_terminal_following_a_real_poll_miss', 0,
      (): void => {
        const runtime: FakeMoonlightRuntime = new FakeMoonlightRuntime();
        const registry: ActiveRemoteSessionRegistry = ActiveRemoteSessionRegistry.getInstance();
        registry.resetForTest();
        registry.bindScope('owner-1', 1);
        const scheduler: FakeMoonlightRuntimePollScheduler =
          new FakeMoonlightRuntimePollScheduler();
        const coordinator: MoonlightSessionCoordinator =
          new MoonlightSessionCoordinator(runtime, registry, null, null, scheduler);
        expect(coordinator.start(productRequest(true)).accepted).assertTrue();
        runtime.currentSnapshot = runtimeSnapshot();
        expect(scheduler.runNext(Date.now())).assertTrue();
        expect(coordinator.setReconnectEnabledForRoute('host-1', 'app-1', true)).assertTrue();
        runtime.currentSnapshot = null;
        expect(scheduler.runNext(Date.now())).assertTrue();
        expect(scheduler.lastDelayMs).assertEqual(200);

        const terminal: MoonlightNativeStreamSnapshot = runtimeSnapshot();
        terminal.terminal = true;
        terminal.code = 'connection_terminated';
        runtime.currentSnapshot = terminal;
        expect(scheduler.runNext(Date.now())).assertTrue();
        const state: MoonlightSessionStateSnapshot =
          coordinator.snapshotForRoute('host-1', 'app-1') as MoonlightSessionStateSnapshot;
        expect(state.phase).assertEqual('reconnecting');
        const active: ActiveRemoteSessionRecord =
          activeMoonlightRecord(registry) as ActiveRemoteSessionRecord;
        expect(active.protocolConnected).assertFalse();
        expect(active.renderAttached).assertFalse();
        coordinator.resetForTest();
        registry.resetForTest();
      });

    it('rejects_runtime_before_touching_the_shared_registry', 0, (): void => {
      const registry: ActiveRemoteSessionRegistry = ActiveRemoteSessionRegistry.getInstance();
      registry.resetForTest();
      registry.bindScope('owner-1', 1);
      const coordinator: MoonlightSessionCoordinator = new MoonlightSessionCoordinator(null, registry);
      const result = coordinator.start(request());
      expect(result.accepted).assertFalse();
      expect(result.code).assertEqual('runtime_unavailable');
      expect(activeMoonlightRecord(registry)).assertNull();
    });

    it('requires_all_runtime_gates_before_the_port_is_called', 0, (): void => {
      const runtime: FakeMoonlightRuntime = new FakeMoonlightRuntime();
      const registry: ActiveRemoteSessionRegistry = ActiveRemoteSessionRegistry.getInstance();
      registry.resetForTest();
      registry.bindScope('owner-1', 1);
      const coordinator: MoonlightSessionCoordinator = new MoonlightSessionCoordinator(runtime, registry);
      const blocked: MoonlightSessionStartRequest = request();
      blocked.streamingTransportReady = false;
      const result = coordinator.start(blocked);
      expect(result.code).assertEqual('runtime_unavailable');
      expect(runtime.startCalls).assertEqual(0);
      expect(activeMoonlightRecord(registry)).assertNull();
    });

    it('binds_crash_recovery_reset_to_the_exact_stream_reservation', 0, (): void => {
      const runtime: FakeMoonlightRuntime = new FakeMoonlightRuntime();
      const registry: ActiveRemoteSessionRegistry = ActiveRemoteSessionRegistry.getInstance();
      registry.resetForTest();
      registry.bindScope('owner-1', 1);
      const coordinator: MoonlightSessionCoordinator =
        new MoonlightSessionCoordinator(runtime, registry);
      const reserved: MoonlightSessionStartRequest = productRequest(false);
      reserved.resetRemoteInputBeforeAdmission = true;
      expect(coordinator.reserve(reserved).accepted).assertTrue();
      const mismatched: MoonlightSessionStartRequest = productRequest(true);
      mismatched.resetRemoteInputBeforeAdmission = false;
      const result = coordinator.start(mismatched);
      expect(result.code).assertEqual('duplicate_start');
      expect(runtime.startCalls).assertEqual(0);
      coordinator.resetForTest();
      registry.resetForTest();
    });

    it('keeps_session_admission_closed_until_the_exact_account_scope_is_bound', 0,
      (): void => {
        const runtime = new FakeMoonlightRuntime();
        const registry = ActiveRemoteSessionRegistry.getInstance();
        registry.resetForTest();
        registry.bindScope('owner-1', 1);
        const owners = new MoonlightRuntimeOwnerRegistry();
        const coordinator = new MoonlightSessionCoordinator(runtime, registry, owners);
        expect(coordinator.start(request()).code).assertEqual('lifecycle_closed');
        owners.bindScope({
          ownerScopeId: 'owner-1', storeIdentity: 'store-1',
          generation: 1, storeInstanceId: 1
        });
        expect(coordinator.start(request()).accepted).assertTrue();
        coordinator.resetForTest();
        registry.resetForTest();
      });

    it('serializes_against_an_existing_protocol_session', 0, (): void => {
      const runtime: FakeMoonlightRuntime = new FakeMoonlightRuntime();
      const registry: ActiveRemoteSessionRegistry = ActiveRemoteSessionRegistry.getInstance();
      registry.resetForTest();
      registry.bindScope('owner-1', 1);
      registry.setActive({
        ownerScopeId: 'owner-1', accountGeneration: 1, sessionId: 9, hostId: 'rdp-host',
        protocol: RemoteProtocol.rustdesk, hostAddress: '10.0.0.2', protocolConnected: true,
        renderAttached: true, restoreNeeded: false, latestSurfaceId: 'surface',
        createdAtMs: 1, updatedAtMs: 1
      });
      const coordinator: MoonlightSessionCoordinator = new MoonlightSessionCoordinator(runtime, registry);
      const result = coordinator.start(request());
      expect(result.accepted).assertFalse();
      expect(result.code).assertEqual('active_session_busy');
      expect(runtime.startCalls).assertEqual(0);
      registry.resetForTest();
    });

    it('keeps_the_endpoint_transient_and_requires_surface_before_streaming', 0, (): void => {
      const runtime: FakeMoonlightRuntime = new FakeMoonlightRuntime();
      const registry: ActiveRemoteSessionRegistry = ActiveRemoteSessionRegistry.getInstance();
      registry.resetForTest();
      registry.bindScope('owner-1', 1);
      const coordinator: MoonlightSessionCoordinator = new MoonlightSessionCoordinator(runtime, registry);
      const generation: number = reachNegotiating(coordinator);
      expect(runtime.lastAddress).assertEqual('192.168.1.20');
      const activeBeforeFrame: ActiveRemoteSessionRecord | null = activeMoonlightRecord(registry);
      expect(activeBeforeFrame !== null).assertTrue();
      expect((activeBeforeFrame as ActiveRemoteSessionRecord).hostAddress).assertEqual('');
      expect(coordinator.handleRuntimeEvent(event('videoReady', generation, 6, 42)).accepted).assertTrue();
      expect(coordinator.handleRuntimeEvent(event('audioReady', generation, 7, 42)).accepted).assertTrue();
      expect(coordinator.handleRuntimeEvent(event('inputReady', generation, 8, 42)).accepted).assertTrue();
      expect(coordinator.handleRuntimeEvent(event('streamStable', generation, 9, 42)).code)
        .assertEqual('render_not_attached');
      expect(coordinator.handleRuntimeEvent(event('firstFrameRendered', generation, 9, 42, 'surface-1'))
        .accepted).assertTrue();
      const streaming = coordinator.handleRuntimeEvent(event('streamStable', generation, 10, 42));
      expect(streaming.accepted).assertTrue();
      expect((streaming.state as MoonlightSessionStateSnapshot).phase).assertEqual('streaming');
      expect((activeMoonlightRecord(registry) as ActiveRemoteSessionRecord).renderAttached).assertTrue();
      coordinator.resetForTest();
      registry.resetForTest();
    });

    it('enters_stable_streaming_when_input_becomes_ready_after_the_first_frame', 0, (): void => {
      const state: MoonlightSessionStateSnapshot = {
        sessionId: 'moonlight-1', ownerScopeId: 'owner-1', hostId: 'host-1', appId: 'app-1',
        generation: 1, phase: 'firstFrame', lastEventSequence: 8,
        videoReady: true, audioReady: true, inputReady: false, firstFrameSeen: true,
        reconnectAttempt: 0, errorCode: 'none', degradationReasons: []
      };
      const planned = moonlightRuntimeReadinessEvents(state, runtimeSnapshot());
      expect(planned.length).assertEqual(2);
      expect(planned[0]).assertEqual('inputReady');
      expect(planned[1]).assertEqual('streamStable');

      const beforeVideo: MoonlightSessionStateSnapshot = {
        sessionId: 'moonlight-2', ownerScopeId: 'owner-1', hostId: 'host-1', appId: 'app-1',
        generation: 2, phase: 'negotiating', lastEventSequence: 5,
        videoReady: false, audioReady: false, inputReady: false, firstFrameSeen: false,
        reconnectAttempt: 0, errorCode: 'none', degradationReasons: []
      };
      const earlyFrame: MoonlightNativeStreamSnapshot = runtimeSnapshot();
      earlyFrame.videoReady = false;
      earlyFrame.audioReady = false;
      earlyFrame.inputReady = false;
      const frameProvesVideo = moonlightRuntimeReadinessEvents(beforeVideo, earlyFrame);
      expect(frameProvesVideo.length).assertEqual(2);
      expect(frameProvesVideo[0]).assertEqual('videoReady');
      expect(frameProvesVideo[1]).assertEqual('firstFrameRendered');
    });

    it('keeps_one_native_session_across_exact_surface_rebind_and_fresh_frame', 0, (): void => {
      const runtime: FakeMoonlightRuntime = new FakeMoonlightRuntime();
      const registry: ActiveRemoteSessionRegistry = ActiveRemoteSessionRegistry.getInstance();
      registry.resetForTest();
      registry.bindScope('owner-1', 1);
      const coordinator: MoonlightSessionCoordinator = new MoonlightSessionCoordinator(runtime, registry);
      const generation: number = reachNegotiating(coordinator);
      coordinator.handleRuntimeEvent(event('videoReady', generation, 6, 42));
      coordinator.handleRuntimeEvent(event('audioReady', generation, 7, 42));
      coordinator.handleRuntimeEvent(event('inputReady', generation, 8, 42));
      coordinator.handleRuntimeEvent(event('firstFrameRendered', generation, 9, 42, 'surface-1'));
      coordinator.handleRuntimeEvent(event('streamStable', generation, 10, 42));

      expect(coordinator.suspendSurfaceForRoute('host-1', 'app-1').code)
        .assertEqual('surface_detached');
      expect(runtime.suspendSurfaceCalls).assertEqual(1);
      expect((activeMoonlightRecord(registry) as ActiveRemoteSessionRecord).renderAttached).assertFalse();
      expect(coordinator.rebindSurfaceForRoute('host-1', 'app-1', 202, 'surface-2').code)
        .assertEqual('surface_rebound');
      expect(runtime.rebindSurfaceCalls).assertEqual(1);

      runtime.currentSnapshot = runtimeSnapshot();
      // Session readiness is sticky, but a rebound Surface must still prove
      // one fresh presentation before input/render admission reopens.
      (runtime.currentSnapshot as MoonlightNativeStreamSnapshot).firstFrameReady = true;
      (runtime.currentSnapshot as MoonlightNativeStreamSnapshot).presentationFrameReady = false;
      expect(coordinator.confirmSurfaceFrameForRoute('host-1', 'app-1', 'surface-2').code)
        .assertEqual('surface_frame_pending');
      (runtime.currentSnapshot as MoonlightNativeStreamSnapshot).presentationFrameReady = true;
      expect(coordinator.confirmSurfaceFrameForRoute('host-1', 'app-1', 'surface-2').accepted)
        .assertTrue();
      const rebound: ActiveRemoteSessionRecord =
        activeMoonlightRecord(registry) as ActiveRemoteSessionRecord;
      expect(rebound.renderAttached).assertTrue();
      expect(rebound.latestSurfaceId).assertEqual('surface-2');
      expect(runtime.startCalls).assertEqual(1);

      expect(coordinator.setAudioPausedForRoute('host-1', 'app-1', true).code)
        .assertEqual('audio_paused');
      expect(coordinator.setAudioPausedForRoute('host-1', 'app-1', false).code)
        .assertEqual('audio_resumed');
      expect(runtime.audioLifecycleCalls).assertEqual(2);
      coordinator.resetForTest();
      registry.resetForTest();
    });

    it('reconciles_only_an_exact_native_terminal_before_cross_protocol_admission', 0,
      (): void => {
      const runtime: FakeMoonlightRuntime = new FakeMoonlightRuntime();
      const registry: ActiveRemoteSessionRegistry = ActiveRemoteSessionRegistry.getInstance();
      registry.resetForTest();
      registry.bindScope('owner-1', 1);
      const coordinator: MoonlightSessionCoordinator =
        new MoonlightSessionCoordinator(runtime, registry);
      expect(coordinator.start(productRequest(true)).accepted).assertTrue();
      expect(activeMoonlightRecord(registry) !== null).assertTrue();

      const staleTerminal: MoonlightNativeStreamSnapshot = runtimeSnapshot();
      staleTerminal.terminal = true;
      staleTerminal.code = 'cancelled';
      staleTerminal.ownerToken = 99;
      runtime.currentSnapshot = staleTerminal;
      expect(coordinator.reconcileNativeTerminalReceipt()).assertFalse();
      expect(activeMoonlightRecord(registry) !== null).assertTrue();

      const exactTerminal: MoonlightNativeStreamSnapshot = runtimeSnapshot();
      exactTerminal.terminal = true;
      exactTerminal.code = 'cancelled';
      runtime.currentSnapshot = exactTerminal;
      expect(coordinator.reconcileNativeTerminalReceipt()).assertTrue();
      expect(activeMoonlightRecord(registry) === null).assertTrue();
      coordinator.resetForTest();
      registry.resetForTest();
    });

    it('atomically_rotates_a_terminal_stream_into_one_reconnect_reservation', 0, (): void => {
      const runtime: FakeMoonlightRuntime = new FakeMoonlightRuntime();
      const registry: ActiveRemoteSessionRegistry = ActiveRemoteSessionRegistry.getInstance();
      registry.resetForTest();
      registry.bindScope('owner-1', 1);
      const coordinator: MoonlightSessionCoordinator = new MoonlightSessionCoordinator(runtime, registry);
      const started = coordinator.start(productRequest(true));
      const generation: number = (started.state as MoonlightSessionStateSnapshot).generation;
      coordinator.handleRuntimeEvent(event('videoReady', generation, 6, 42));
      coordinator.handleRuntimeEvent(event('audioReady', generation, 7, 42));
      coordinator.handleRuntimeEvent(event('inputReady', generation, 8, 42));
      coordinator.handleRuntimeEvent(event('firstFrameRendered', generation, 9, 42, 'surface-1'));
      coordinator.handleRuntimeEvent(event('streamStable', generation, 10, 42));
      expect(coordinator.setReconnectEnabledForRoute('host-1', 'app-1', true)).assertTrue();

      const premature = coordinator.acceptRecoverableTerminalForRoute(
        'host-1', 'app-1');
      expect(premature.code).assertEqual('terminal_not_observed');
      const staleTerminal: MoonlightNativeStreamSnapshot = runtimeSnapshot();
      staleTerminal.terminal = true;
      staleTerminal.code = 'connection_terminated';
      staleTerminal.ownerToken = 99;
      runtime.currentSnapshot = staleTerminal;
      expect(coordinator.acceptRecoverableTerminalForRoute(
        'host-1', 'app-1').code)
        .assertEqual('terminal_not_observed');
      const exactTerminal: MoonlightNativeStreamSnapshot = runtimeSnapshot();
      exactTerminal.terminal = true;
      exactTerminal.code = 'connection_terminated';
      runtime.currentSnapshot = exactTerminal;
      const reserved = coordinator.acceptRecoverableTerminalForRoute(
        'host-1', 'app-1');
      expect(reserved.code).assertEqual('reconnect_reserved');
      expect((reserved.state as MoonlightSessionStateSnapshot).phase).assertEqual('reconnecting');
      const reconnectGeneration: number =
        (reserved.state as MoonlightSessionStateSnapshot).generation;
      expect(reconnectGeneration > generation).assertTrue();
      const placeholder: ActiveRemoteSessionRecord =
        activeMoonlightRecord(registry) as ActiveRemoteSessionRecord;
      expect(placeholder.protocolConnected).assertFalse();
      expect(placeholder.renderAttached).assertFalse();

      runtime.nativeId = 43;
      const next: MoonlightSessionStartRequest = productRequest(true);
      next.launchKey = { requestId: 19, generation: 2, ownerToken: 21 };
      next.rendererHandle = 202;
      next.surfaceId = 'surface-2';
      const restarted = coordinator.restartAfterTransportLoss(next);
      expect(restarted.accepted).assertTrue();
      expect(restarted.nativeSessionId).assertEqual(43);
      expect(runtime.startCalls).assertEqual(2);
      expect(runtime.lastOperationGeneration).assertEqual(reconnectGeneration);
      expect((activeMoonlightRecord(registry) as ActiveRemoteSessionRecord).sessionId)
        .assertEqual(43);
      expect(coordinator.handleRuntimeEvent(event('videoReady', generation, 12, 42)).code)
        .assertEqual('stale_generation');
      expect(coordinator.handleRuntimeEvent(event('videoReady', reconnectGeneration, 2, 42)).code)
        .assertEqual('native_session_mismatch');
      coordinator.resetForTest();
      registry.resetForTest();
    });

    it('stops_a_session_that_never_renders_its_first_frame', 0,
      async (): Promise<void> => {
      const runtime: FakeMoonlightRuntime = new FakeMoonlightRuntime();
      const registry: ActiveRemoteSessionRegistry = ActiveRemoteSessionRegistry.getInstance();
      registry.resetForTest();
      registry.bindScope('owner-1', 1);
      const coordinator: MoonlightSessionCoordinator = new MoonlightSessionCoordinator(runtime, registry);
      reachNegotiating(coordinator);
      const expired = coordinator.expireFirstFrame(Date.now() + 31000);
      expect(expired.code).assertEqual('first_frame_timeout');
      expect(runtime.stopCalls).assertEqual(1);
      expect((expired.state as MoonlightSessionStateSnapshot).phase).assertEqual('failed');
      expect((expired.state as MoonlightSessionStateSnapshot).errorCode).assertEqual('stream_timeout');
      expect(activeMoonlightRecord(registry) !== null).assertTrue();
      expect(coordinator.start(request()).code).assertEqual('active_session_busy');
      const terminalSnapshot: MoonlightNativeStreamSnapshot = runtimeSnapshot();
      terminalSnapshot.terminal = true;
      terminalSnapshot.code = 'cancelled';
      runtime.currentSnapshot = terminalSnapshot;
      expect(await coordinator.stopForLifecycle('first-frame-timeout', 1000)).assertTrue();
      expect(activeMoonlightRecord(registry)).assertNull();
      expect(moonlightRuntimeNativeError('input_failed')).assertEqual('INPUT_FAILED');
      coordinator.resetForTest();
      registry.resetForTest();
    });

    it('lifecycle_stop_waits_for_a_real_native_terminal_receipt', 0,
      async (): Promise<void> => {
        const runtime = new FakeMoonlightRuntime();
        const registry = ActiveRemoteSessionRegistry.getInstance();
        registry.resetForTest();
        registry.bindScope('owner-1', 1);
        const coordinator = new MoonlightSessionCoordinator(runtime, registry);
        expect(coordinator.start(productRequest(true)).accepted).assertTrue();
        const terminalSnapshot: MoonlightNativeStreamSnapshot = runtimeSnapshot();
        terminalSnapshot.terminal = true;
        terminalSnapshot.code = 'cancelled';
        runtime.currentSnapshot = terminalSnapshot;
        expect(await coordinator.stopForLifecycle('account-switch', 1000)).assertTrue();
        expect(runtime.stopCalls).assertEqual(1);
        expect(activeMoonlightRecord(registry)).assertNull();
        coordinator.resetForTest();
        registry.resetForTest();
      });

    it('fences_late_events_and_clears_only_its_own_registry_marker', 0, (): void => {
      const runtime: FakeMoonlightRuntime = new FakeMoonlightRuntime();
      const registry: ActiveRemoteSessionRegistry = ActiveRemoteSessionRegistry.getInstance();
      registry.resetForTest();
      registry.bindScope('owner-1', 1);
      const coordinator: MoonlightSessionCoordinator = new MoonlightSessionCoordinator(runtime, registry);
      const generation: number = reachNegotiating(coordinator);
      expect(coordinator.handleRuntimeEvent(event('failed', generation - 1, 6)).code)
        .assertEqual('stale_generation');
      const stop = coordinator.requestStop('user-disconnect');
      expect(stop.code).assertEqual('stop_requested');
      expect(runtime.stopCalls).assertEqual(1);
      const stopped = coordinator.handleRuntimeEvent(event('stopped', generation, 6, 42));
      expect(stopped.code).assertEqual('stopped');
      expect(activeMoonlightRecord(registry)).assertNull();
      coordinator.resetForTest();
      registry.resetForTest();
    });

    it('reserves_the_shared_registry_before_runtime_start', 0, (): void => {
      const runtime: FakeMoonlightRuntime = new FakeMoonlightRuntime();
      const registry: ActiveRemoteSessionRegistry = ActiveRemoteSessionRegistry.getInstance();
      registry.resetForTest();
      registry.bindScope('owner-1', 1);
      const coordinator: MoonlightSessionCoordinator = new MoonlightSessionCoordinator(runtime, registry);
      expect(coordinator.start(request()).accepted).assertTrue();
      const competing: boolean = registry.setActive({
        ownerScopeId: 'owner-1', accountGeneration: 1, sessionId: 77, hostId: 'rdp-host',
        protocol: RemoteProtocol.rdp, hostAddress: '10.0.0.3', protocolConnected: true,
        renderAttached: false, restoreNeeded: false, latestSurfaceId: '', createdAtMs: 1, updatedAtMs: 1
      });
      expect(competing).assertFalse();
      coordinator.resetForTest();
      registry.resetForTest();
    });

    it('reserves_before_surface_and_reuses_the_exact_reservation_on_start', 0, (): void => {
      const runtime: FakeMoonlightRuntime = new FakeMoonlightRuntime();
      const registry: ActiveRemoteSessionRegistry = ActiveRemoteSessionRegistry.getInstance();
      registry.resetForTest();
      registry.bindScope('owner-1', 1);
      const coordinator: MoonlightSessionCoordinator = new MoonlightSessionCoordinator(runtime, registry);
      const reserved = coordinator.reserve(productRequest(false));
      expect(reserved.accepted).assertTrue();
      expect(reserved.code).assertEqual('reserved');
      expect(runtime.startCalls).assertEqual(0);
      expect(activeMoonlightRecord(registry) !== null).assertTrue();
      const started = coordinator.start(productRequest(true));
      expect(started.accepted).assertTrue();
      expect(runtime.startCalls).assertEqual(1);
      expect((activeMoonlightRecord(registry) as ActiveRemoteSessionRecord).sessionId).assertEqual(42);
      coordinator.resetForTest();
      registry.resetForTest();
    });

    it('releases_an_unstarted_route_reservation_without_calling_native', 0, (): void => {
      const runtime: FakeMoonlightRuntime = new FakeMoonlightRuntime();
      const registry: ActiveRemoteSessionRegistry = ActiveRemoteSessionRegistry.getInstance();
      registry.resetForTest();
      registry.bindScope('owner-1', 1);
      const coordinator: MoonlightSessionCoordinator = new MoonlightSessionCoordinator(runtime, registry);
      expect(coordinator.reserve(productRequest(false)).accepted).assertTrue();
      expect(coordinator.cancelForRoute('host-1', 'app-1', 'surface-destroyed').code)
        .assertEqual('stopped');
      expect(runtime.cancelCalls).assertEqual(0);
      expect(activeMoonlightRecord(registry)).assertNull();
      coordinator.resetForTest();
      registry.resetForTest();
    });

    it('uses_the_next_sequence_for_staged_runtime_start_failure', 0, (): void => {
      const runtime: FakeMoonlightRuntime = new FakeMoonlightRuntime();
      runtime.startResult = false;
      const registry: ActiveRemoteSessionRegistry = ActiveRemoteSessionRegistry.getInstance();
      registry.resetForTest();
      registry.bindScope('owner-1', 1);
      const coordinator: MoonlightSessionCoordinator = new MoonlightSessionCoordinator(runtime, registry);
      const failed = coordinator.start(productRequest(true));
      expect(failed.code).assertEqual('runtime_start_failed');
      expect((failed.state as MoonlightSessionStateSnapshot).phase).assertEqual('failed');
      expect((failed.state as MoonlightSessionStateSnapshot).lastEventSequence).assertEqual(5);
      expect(activeMoonlightRecord(registry)).assertNull();
      coordinator.resetForTest();
      registry.resetForTest();
    });

    it('cancels_a_prelaunch_reservation_and_fences_native_teardown_failures', 0,
      async (): Promise<void> => {
      const runtime: FakeMoonlightRuntime = new FakeMoonlightRuntime();
      const registry: ActiveRemoteSessionRegistry = ActiveRemoteSessionRegistry.getInstance();
      registry.resetForTest();
      registry.bindScope('owner-1', 1);
      const coordinator: MoonlightSessionCoordinator = new MoonlightSessionCoordinator(runtime, registry);
      const prelaunch = coordinator.start(request());
      expect(prelaunch.accepted).assertTrue();
      expect(coordinator.cancel('user-cancel').accepted).assertTrue();
      expect(runtime.cancelCalls).assertEqual(1);
      expect(activeMoonlightRecord(registry) !== null).assertTrue();
      expect(coordinator.handleRuntimeEvent(event(
        'stopped', (prelaunch.state as MoonlightSessionStateSnapshot).generation, 3)).code)
        .assertEqual('stopped');
      expect(activeMoonlightRecord(registry)).assertNull();

      const second: MoonlightSessionCoordinator = new MoonlightSessionCoordinator(runtime, registry);
      expect(second.start(request()).accepted).assertTrue();
      const generation: number = (second.snapshotForRoute('host-1', 'app-1') as MoonlightSessionStateSnapshot).generation;
      second.handleRuntimeEvent(event('beginVerification', generation, 2));
      second.handleRuntimeEvent(event('catalogReady', generation, 3));
      second.handleRuntimeEvent(event('launchRequested', generation, 4));
      second.handleRuntimeEvent(event('launchAccepted', generation, 5, 43));
      runtime.stopResult = false;
      expect(second.requestStop('stop-failure').code).assertEqual('stop_failed');
      expect(activeMoonlightRecord(registry) !== null).assertTrue();
      expect(second.suspendSurfaceForRoute('host-1', 'app-1').accepted).assertTrue();
      const stopFailureTerminal: MoonlightNativeStreamSnapshot = runtimeSnapshot();
      stopFailureTerminal.terminal = true;
      stopFailureTerminal.code = 'cancelled';
      runtime.currentSnapshot = stopFailureTerminal;
      expect(await second.stopForLifecycle('stop-failure-drain', 1000)).assertTrue();
      expect(activeMoonlightRecord(registry)).assertNull();

      runtime.stopResult = true;
      runtime.currentSnapshot = null;
      const third: MoonlightSessionCoordinator = new MoonlightSessionCoordinator(runtime, registry);
      expect(third.start(request()).accepted).assertTrue();
      const thirdGeneration: number =
        (third.snapshotForRoute('host-1', 'app-1') as MoonlightSessionStateSnapshot).generation;
      third.handleRuntimeEvent(event('beginVerification', thirdGeneration, 2));
      third.handleRuntimeEvent(event('catalogReady', thirdGeneration, 3));
      third.handleRuntimeEvent(event('launchRequested', thirdGeneration, 4));
      third.handleRuntimeEvent(event('launchAccepted', thirdGeneration, 5, 44));
      expect(third.requestStop('stop-timeout').accepted).assertTrue();
      expect(third.expireStop(Date.now() + 6000).code).assertEqual('stop_timeout');
      expect(activeMoonlightRecord(registry) !== null).assertTrue();
      expect(third.start(request()).code).assertEqual('active_session_busy');
      const stopTimeoutTerminal: MoonlightNativeStreamSnapshot = runtimeSnapshot();
      stopTimeoutTerminal.terminal = true;
      stopTimeoutTerminal.code = 'cancelled';
      runtime.currentSnapshot = stopTimeoutTerminal;
      expect(await third.stopForLifecycle('stop-timeout-drain', 1000)).assertTrue();
      expect(activeMoonlightRecord(registry)).assertNull();
      registry.resetForTest();
    });

    it('rejects_callbacks_from_a_different_native_session', 0, (): void => {
      const runtime: FakeMoonlightRuntime = new FakeMoonlightRuntime();
      const registry: ActiveRemoteSessionRegistry = ActiveRemoteSessionRegistry.getInstance();
      registry.resetForTest();
      registry.bindScope('owner-1', 1);
      const coordinator: MoonlightSessionCoordinator = new MoonlightSessionCoordinator(runtime, registry);
      const generation: number = reachNegotiating(coordinator);
      expect(coordinator.handleRuntimeEvent(event('videoReady', generation, 6, 99)).code)
        .assertEqual('native_session_mismatch');
      expect(coordinator.handleRuntimeEvent(event('videoReady', generation, 6, 42)).accepted).assertTrue();
      coordinator.resetForTest();
      registry.resetForTest();
    });

    it('hides_the_old_owner_but_keeps_its_registry_until_native_terminal', 0,
      async (): Promise<void> => {
      const runtime: FakeMoonlightRuntime = new FakeMoonlightRuntime();
      const registry: ActiveRemoteSessionRegistry = ActiveRemoteSessionRegistry.getInstance();
      registry.resetForTest();
      registry.bindScope('owner-1', 1);
      const coordinator: MoonlightSessionCoordinator = new MoonlightSessionCoordinator(runtime, registry);
      const started = coordinator.start(request());
      const oldState: MoonlightSessionStateSnapshot = started.state as MoonlightSessionStateSnapshot;
      coordinator.bindScope('owner-2', 2);
      expect(runtime.cancelCalls).assertEqual(1);
      expect(coordinator.handleRuntimeEvent(
        event('beginVerification', oldState.generation, 2)).accepted).assertFalse();
      expect(activeMoonlightRecord(registry) !== null).assertTrue();
      const terminalSnapshot: MoonlightNativeStreamSnapshot = runtimeSnapshot();
      terminalSnapshot.terminal = true;
      terminalSnapshot.code = 'cancelled';
      runtime.currentSnapshot = terminalSnapshot;
      expect(await coordinator.stopForLifecycle('owner-change-drain', 1000)).assertTrue();
      expect(activeMoonlightRecord(registry)).assertNull();

      runtime.currentSnapshot = null;
      registry.bindScope('owner-2', 2);
      const next: MoonlightSessionStartRequest = request();
      next.ownerScopeId = 'owner-2';
      next.accountGeneration = 2;
      expect(coordinator.start(next).accepted).assertTrue();
      coordinator.resetForTest();
      registry.resetForTest();
    });

    it('publishes_only_scope_and_route_matching_snapshots', 0, (): void => {
      const runtime: FakeMoonlightRuntime = new FakeMoonlightRuntime();
      const registry: ActiveRemoteSessionRegistry = ActiveRemoteSessionRegistry.getInstance();
      registry.resetForTest();
      registry.bindScope('owner-1', 1);
      const coordinator: MoonlightSessionCoordinator = new MoonlightSessionCoordinator(runtime, registry);
      let matching: MoonlightSessionStateSnapshot | null = null;
      let foreignNonNull: boolean = false;
      const unsubscribe = coordinator.subscribeForRoute(
        'owner-1', 1, 'host-1', 'app-1',
        (snapshot: MoonlightSessionStateSnapshot | null): void => { matching = snapshot; });
      const unsubscribeForeign = coordinator.subscribeForRoute(
        'owner-1', 1, 'host-other', 'app-other',
        (snapshot: MoonlightSessionStateSnapshot | null): void => {
          if (snapshot !== null) { foreignNonNull = true; }
        });
      expect(matching).assertNull();
      expect(coordinator.start(request()).accepted).assertTrue();
      expect(matching !== null).assertTrue();
      expect((matching as MoonlightSessionStateSnapshot).phase).assertEqual('discovering');
      coordinator.handleRuntimeEvent(event('capabilityDegraded', 1, 2, 0, ''));
      expect((matching as MoonlightSessionStateSnapshot).degradationReasons.length).assertEqual(0);
      coordinator.handleRuntimeEvent({
        type: 'capabilityDegraded', generation: 1, sequence: 3,
        nativeError: '', detailCode: 'audio_degraded', nativeSessionId: 0, surfaceId: ''
      });
      expect((matching as MoonlightSessionStateSnapshot).degradationReasons.length).assertEqual(1);
      expect(foreignNonNull).assertFalse();
      coordinator.bindScope('owner-2', 2);
      expect(matching).assertNull();
      unsubscribe();
      unsubscribeForeign();
      coordinator.resetForTest();
      registry.resetForTest();
    });
  });
}
