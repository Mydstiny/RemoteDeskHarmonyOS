import { describe, expect, it } from '@ohos/hypium';
import {
  ActiveRemoteSessionRegistry,
  ActiveRemoteSessionRecord
} from '../main/ets/services/ActiveRemoteSessionRegistry';
import {
  MoonlightCoordinatorEvent,
  MoonlightRuntimePort,
  MoonlightSessionCoordinator,
  MoonlightSessionStartRequest
} from '../main/ets/services/MoonlightSessionCoordinator';
import { RemoteProtocol } from '../main/ets/services/RemoteSessionState';
import { MoonlightSessionStateSnapshot } from '../main/ets/services/MoonlightSessionState';

class FakeMoonlightRuntime implements MoonlightRuntimePort {
  startCalls: number = 0;
  stopCalls: number = 0;
  lastAddress: string = '';
  startResult: boolean = true;

  start(request: MoonlightSessionStartRequest, _operationGeneration: number): boolean {
    this.startCalls += 1;
    this.lastAddress = request.hostAddress;
    return this.startResult;
  }

  stop(_nativeSessionId: number, _reason: string): boolean {
    this.stopCalls += 1;
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
      expect(coordinator.handleRuntimeEvent(event('videoReady', generation, 6)).accepted).assertTrue();
      expect(coordinator.handleRuntimeEvent(event('audioReady', generation, 7)).accepted).assertTrue();
      expect(coordinator.handleRuntimeEvent(event('inputReady', generation, 8)).accepted).assertTrue();
      expect(coordinator.handleRuntimeEvent(event('streamStable', generation, 9)).code)
        .assertEqual('render_not_attached');
      expect(coordinator.handleRuntimeEvent(event('firstFrameRendered', generation, 9, 42, 'surface-1'))
        .accepted).assertTrue();
      const streaming = coordinator.handleRuntimeEvent(event('streamStable', generation, 10));
      expect(streaming.accepted).assertTrue();
      expect((streaming.state as MoonlightSessionStateSnapshot).phase).assertEqual('streaming');
      expect((activeMoonlightRecord(registry) as ActiveRemoteSessionRecord).renderAttached).assertTrue();
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
  });
}
