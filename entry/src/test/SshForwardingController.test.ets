import { describe, it, expect } from '@ohos/hypium';
import {
  SshForwardingConfig,
  SshForwardingSnapshot,
  SshForwardingSnapshotsResult
} from '../main/ets/types/rdpnapi';
import {
  SshForwardingController,
  SshForwardingNativePort,
  sshForwardingNativeConfig
} from '../main/ets/services/SshForwardingController';
import {
  SshForwardingMode,
  SshForwardingProfile
} from '../main/ets/services/SshForwardingPolicy';
import { SshForwardingRuntimeStore } from '../main/ets/services/SshForwardingRuntimeStore';
import { SshSessionHandle, SshSessionLifecycleState } from '../main/ets/services/SshSessionStore';

class FakeForwardingNative implements SshForwardingNativePort {
  readonly generations: Map<number, number> = new Map<number, number>();
  readonly calls: string[] = [];
  readonly configs: SshForwardingConfig[] = [];
  snapshots: SshForwardingSnapshot[] = [];
  configureCode: number = 0;
  startCode: number = 0;
  stopCode: number = 0;
  completeCode: number = 0;
  removeCode: number = 0;
  acquireCode: number = 0;
  releaseCode: number = 0;
  snapshotCode: number = 0;

  accept(handle: SshSessionHandle): void {
    this.generations.set(handle.sessionId, handle.generation);
  }

  accepts(handle: SshSessionHandle): boolean {
    return this.generations.get(handle.sessionId) === handle.generation;
  }

  forwardingSessionState(handle: SshSessionHandle): SshSessionLifecycleState | '' {
    return this.accepts(handle) ? 'Ready' : '';
  }

  configureSshForwarding(handle: SshSessionHandle, config: SshForwardingConfig): number {
    this.calls.push('configure:' + handle.sessionId.toString() + ':' +
      handle.generation.toString() + ':' + config.id);
    this.configs.push({ ...config });
    return this.configureCode;
  }

  removeSshForwarding(handle: SshSessionHandle, id: string): number {
    this.calls.push('remove:' + handle.sessionId.toString() + ':' + id);
    return this.removeCode;
  }

  startSshForwarding(handle: SshSessionHandle, id: string): number {
    this.calls.push('start:' + handle.sessionId.toString() + ':' + id);
    return this.startCode;
  }

  stopSshForwarding(handle: SshSessionHandle, id: string): number {
    this.calls.push('stop:' + handle.sessionId.toString() + ':' + id);
    return this.stopCode;
  }

  completeSshForwardingStop(handle: SshSessionHandle, id: string): number {
    this.calls.push('complete:' + handle.sessionId.toString() + ':' + id);
    return this.completeCode;
  }

  acquireSshForwardingConnection(handle: SshSessionHandle, id: string): number {
    this.calls.push('acquire:' + handle.sessionId.toString() + ':' + id);
    return this.acquireCode;
  }

  releaseSshForwardingConnection(handle: SshSessionHandle, id: string): number {
    this.calls.push('release:' + handle.sessionId.toString() + ':' + id);
    return this.releaseCode;
  }

  getSshForwardingSnapshots(handle: SshSessionHandle): SshForwardingSnapshotsResult {
    this.calls.push('snapshot:' + handle.sessionId.toString());
    return {
      errorCode: this.snapshotCode,
      sessionId: handle.sessionId,
      sessionGeneration: handle.generation,
      snapshots: this.snapshots
    };
  }
}

function handle(sessionId: number, generation: number = 1): SshSessionHandle {
  return { sessionId, channelId: 'shell', generation };
}

function profile(id: string, mode: SshForwardingMode = 'local'): SshForwardingProfile {
  return {
    id,
    mode,
    bindHost: '127.0.0.1',
    bindPort: mode === 'dynamic' ? 1080 : 8022,
    targetHost: mode === 'dynamic' ? '' : 'target.example',
    targetPort: mode === 'dynamic' ? 0 : 22,
    maxConnections: 4,
    enabled: true,
    startPolicy: 'manual',
    allowPublicBind: false
  };
}

export default function sshForwardingControllerTest(): void {
  describe('SshForwardingController', (): void => {
    it('maps_local_remote_and_dynamic_to_the_existing_native_contract', 0, (): void => {
      expect(sshForwardingNativeConfig(profile('local', 'local')).mode).assertEqual(0);
      expect(sshForwardingNativeConfig(profile('remote', 'remote')).mode).assertEqual(1);
      const dynamic: SshForwardingConfig = sshForwardingNativeConfig(profile('dynamic', 'dynamic'));
      expect(dynamic.mode).assertEqual(2);
      expect(dynamic.targetHost).assertEqual('');
      expect(dynamic.targetPort).assertEqual(0);
      expect(dynamic.schemaVersion).assertEqual(1);
    });

    it('rejects_invalid_profiles_and_stale_handles_before_native', 0, (): void => {
      const native: FakeForwardingNative = new FakeForwardingNative();
      const controller: SshForwardingController = new SshForwardingController(native);
      const current: SshSessionHandle = handle(1);
      native.accept(current);
      const invalid: SshForwardingProfile = profile('bad');
      invalid.bindPort = 0;
      expect(controller.configure(current, invalid).accepted).assertFalse();
      expect(native.calls.length).assertEqual(0);
      const stale: SshSessionHandle = handle(1, 2);
      expect(controller.start(stale, profile('stale')).stale).assertTrue();
      expect(native.calls.length).assertEqual(0);
      expect(controller.snapshot(stale).runtimes.length).assertEqual(0);
      expect(native.calls.length).assertEqual(0);
    });

    it('checks_runtime_capacity_before_configuring_native', 0, (): void => {
      const native: FakeForwardingNative = new FakeForwardingNative();
      const first: SshSessionHandle = handle(11);
      const second: SshSessionHandle = handle(12);
      native.accept(first);
      native.accept(second);
      const controller: SshForwardingController = new SshForwardingController(
        native, new SshForwardingRuntimeStore(1));
      expect(controller.configure(first, profile('first')).accepted).assertTrue();
      native.calls.splice(0, native.calls.length);
      const rejected = controller.configure(second, profile('second'));
      expect(rejected.code).assertEqual(-70);
      expect(rejected.accepted).assertFalse();
      expect(native.calls.length).assertEqual(0);
    });

    it('orders_configure_start_stop_complete_and_remove_cleanup', 0, (): void => {
      const native: FakeForwardingNative = new FakeForwardingNative();
      const current: SshSessionHandle = handle(2);
      native.accept(current);
      const controller: SshForwardingController = new SshForwardingController(native);
      expect(controller.start(current, profile('rule')).accepted).assertTrue();
      expect(native.calls[0]).assertEqual('configure:2:1:rule');
      expect(native.calls[1]).assertEqual('start:2:rule');
      native.calls.splice(0, native.calls.length);
      expect(controller.stop(current, 'rule').accepted).assertTrue();
      expect(native.calls[0]).assertEqual('stop:2:rule');
      expect(native.calls[1]).assertEqual('complete:2:rule');
      expect(controller.start(current, profile('rule')).accepted).assertTrue();
      native.calls.splice(0, native.calls.length);
      expect(controller.remove(current, 'rule').accepted).assertTrue();
      expect(native.calls[0]).assertEqual('stop:2:rule');
      expect(native.calls[1]).assertEqual('complete:2:rule');
      expect(native.calls[2]).assertEqual('remove:2:rule');
    });

    it('does_not_revive_an_old_generation_during_reconcile', 0, (): void => {
      const native: FakeForwardingNative = new FakeForwardingNative();
      const oldHandle: SshSessionHandle = handle(3, 1);
      native.accept(oldHandle);
      const controller: SshForwardingController = new SshForwardingController(native);
      expect(controller.start(oldHandle, profile('auto')).accepted).assertTrue();
      native.calls.splice(0, native.calls.length);
      const nextHandle: SshSessionHandle = handle(3, 2);
      native.accept(nextHandle);
      const automatic: SshForwardingProfile = profile('auto');
      automatic.startPolicy = 'onSessionReady';
      const results = controller.reconcile(nextHandle, [automatic]);
      expect(results.length).assertEqual(1);
      expect(results[0].accepted).assertTrue();
      expect(controller.list(oldHandle).length).assertEqual(0);
      expect(native.calls[0]).assertEqual('configure:3:2:auto');
      expect(native.calls[1]).assertEqual('start:3:auto');
      expect(native.calls.some((call: string): boolean => call.indexOf('3:1') >= 0)).assertFalse();
    });

    it('retires_session_runtime_records_after_stopping_native_listeners', 0, (): void => {
      const native: FakeForwardingNative = new FakeForwardingNative();
      const current: SshSessionHandle = handle(4);
      native.accept(current);
      const controller: SshForwardingController = new SshForwardingController(native);
      expect(controller.start(current, profile('retired')).accepted).assertTrue();
      expect(controller.list(current).length).assertEqual(1);
      expect(controller.releaseSession(current).length).assertEqual(1);
      expect(controller.list(current).length).assertEqual(0);
    });

    it('clears_old_generation_runtime_records_on_session_release', 0, (): void => {
      const native: FakeForwardingNative = new FakeForwardingNative();
      const oldHandle: SshSessionHandle = handle(5, 1);
      const current: SshSessionHandle = handle(5, 2);
      native.accept(oldHandle);
      const controller: SshForwardingController = new SshForwardingController(native);
      expect(controller.start(oldHandle, profile('old-generation')).accepted).assertTrue();
      native.accept(current);
      expect(controller.releaseSession(current).length).assertEqual(0);
      expect(controller.list(oldHandle).length).assertEqual(0);
    });

    it('clears_runtime_records_when_native_handle_is_already_stale', 0, (): void => {
      const native: FakeForwardingNative = new FakeForwardingNative();
      const current: SshSessionHandle = handle(6);
      native.accept(current);
      const controller: SshForwardingController = new SshForwardingController(native);
      expect(controller.start(current, profile('stale-session')).accepted).assertTrue();
      expect(controller.list(current).length).assertEqual(1);
      native.generations.delete(current.sessionId);
      expect(controller.releaseSession(current).length).assertEqual(1);
      expect(controller.list(current).length).assertEqual(0);
    });

    it('isolates_at_least_eight_sessions', 0, (): void => {
      const native: FakeForwardingNative = new FakeForwardingNative();
      const controller: SshForwardingController = new SshForwardingController(native);
      for (let index: number = 1; index <= 8; index++) {
        const current: SshSessionHandle = handle(100 + index);
        native.accept(current);
        expect(controller.start(current, profile('shared')).accepted).assertTrue();
      }
      for (let index: number = 1; index <= 8; index++) {
        const current: SshSessionHandle = handle(100 + index);
        expect(controller.list(current).length).assertEqual(1);
        expect(controller.list(current)[0].sessionId).assertEqual(100 + index);
      }
    });

    it('propagates_native_errors_without_claiming_success', 0, (): void => {
      const native: FakeForwardingNative = new FakeForwardingNative();
      const current: SshSessionHandle = handle(9);
      native.accept(current);
      native.configureCode = -80;
      const controller: SshForwardingController = new SshForwardingController(native);
      const result = controller.start(current, profile('failure'));
      expect(result.code).assertEqual(-80);
      expect(result.accepted).assertFalse();
      expect(result.state).assertEqual('failed');
      expect(native.calls.length).assertEqual(1);
    });

    it('refreshes_connection_and_byte_statistics_from_matching_native_snapshots', 0, (): void => {
      const native: FakeForwardingNative = new FakeForwardingNative();
      const current: SshSessionHandle = handle(10, 3);
      native.accept(current);
      const controller: SshForwardingController = new SshForwardingController(native);
      expect(controller.start(current, profile('stats')).accepted).assertTrue();
      native.snapshots = [{
        schemaVersion: 1,
        id: 'stats',
        mode: 0,
        bindHost: '127.0.0.1',
        bindPort: 8022,
        targetHost: 'target.example',
        targetPort: 22,
        maxConnections: 4,
        enabled: true,
        allowPublicBind: false,
        state: 2,
        sessionGeneration: 3,
        activeConnections: 2,
        lastError: 0,
        minBindPort: 1,
        maxBindPort: 65535,
        maxBytes: 0,
        ownerSessionId: 10,
        ownerChannelId: 'shell',
        ownerGeneration: 3,
        transferredBytes: 4096,
        expiresAtMs: 0
      }];
      const refreshed = controller.snapshot(current);
      expect(refreshed.accepted).assertTrue();
      expect(refreshed.runtimes.length).assertEqual(1);
      expect(refreshed.runtimes[0].activeConnections).assertEqual(2);
      expect(refreshed.runtimes[0].transferredBytes).assertEqual(4096);

      native.snapshots[0] = { ...native.snapshots[0], ownerGeneration: 2,
        activeConnections: 7, transferredBytes: 8192 };
      const staleOwner = controller.snapshot(current);
      expect(staleOwner.accepted).assertTrue();
      expect(staleOwner.runtimes[0].activeConnections).assertEqual(2);
      expect(staleOwner.runtimes[0].transferredBytes).assertEqual(4096);
    });
  });
}
