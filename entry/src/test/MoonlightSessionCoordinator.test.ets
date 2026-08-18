import { describe, expect, it } from '@ohos/hypium';
import {
  ActiveRemoteSessionRegistry,
  ActiveRemoteSessionRecord
} from '../main/ets/services/ActiveRemoteSessionRegistry';
import {
  MoonlightCoordinatorEvent,
  MoonlightRuntimePort,
  MoonlightSessionCoordinator,
  MoonlightSessionStartRequest,
  moonlightRuntimeNativeError,
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

class FakeMoonlightRuntime implements MoonlightRuntimePort {
  startCalls: number = 0;
  cancelCalls: number = 0;
  stopCalls: number = 0;
  lastAddress: string = '';
  startResult: boolean = true;
  cancelResult: boolean = true;
  stopResult: boolean = true;

  start(request: MoonlightSessionStartRequest, _operationGeneration: number): boolean {
    this.startCalls += 1;
    this.lastAddress = request.hostAddress;
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

  nativeSessionId(_operationGeneration: number): number { return 42; }
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
    controllerReady: true, physicalControllerReady: false, firstFrameReady: true,
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
      expect(moonlightRuntimeReadinessEvents(beforeVideo, earlyFrame).length).assertEqual(0);
    });

    it('stops_a_session_that_never_renders_its_first_frame', 0, (): void => {
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
      expect(activeMoonlightRecord(registry)).assertNull();
      expect(moonlightRuntimeNativeError('input_failed')).assertEqual('INPUT_FAILED');
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

    it('cancels_a_prelaunch_reservation_and_local_terminates_on_stop_failure', 0, (): void => {
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
      expect(activeMoonlightRecord(registry)).assertNull();

      runtime.stopResult = true;
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

    it('invalidates_the_old_owner_before_a_late_native_event_can_write', 0, (): void => {
      const runtime: FakeMoonlightRuntime = new FakeMoonlightRuntime();
      const registry: ActiveRemoteSessionRegistry = ActiveRemoteSessionRegistry.getInstance();
      registry.resetForTest();
      registry.bindScope('owner-1', 1);
      const coordinator: MoonlightSessionCoordinator = new MoonlightSessionCoordinator(runtime, registry);
      const started = coordinator.start(request());
      const oldState: MoonlightSessionStateSnapshot = started.state as MoonlightSessionStateSnapshot;
      coordinator.bindScope('owner-2', 2);
      expect(coordinator.handleRuntimeEvent(event('beginVerification', oldState.generation, 2)).code)
        .assertEqual('not_active');
      expect(activeMoonlightRecord(registry)).assertNull();
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
