import { describe, expect, it } from '@ohos/hypium';
import {
  DiagnosticCaptureRuntime,
  DiagnosticClock,
  FrozenDiagnosticCapture
} from '../main/ets/services/DiagnosticCaptureRuntime';
import { DIAGNOSTIC_MAX_EVENTS } from '../main/ets/services/DiagnosticCapturePolicy';
import {
  DiagnosticNetworkFacts,
  DiagnosticRuntimeFacts,
  diagnosticNetworkFactsForEndpoints
} from '../main/ets/services/DiagnosticCapturePolicy';

class FakeDiagnosticClock implements DiagnosticClock {
  uptime: number = 1000;
  wall: number = 1700000000000;
  uptimeReads: number = 0;
  wallReads: number = 0;

  uptimeMs(): number {
    this.uptimeReads += 1;
    return this.uptime;
  }

  wallTimeMs(): number {
    this.wallReads += 1;
    return this.wall;
  }

  advance(milliseconds: number): void {
    this.uptime += milliseconds;
    this.wall += milliseconds;
  }
}

export default function diagnosticCaptureRuntimeTest(): void {
  describe('DiagnosticCaptureRuntime', (): void => {
    it('keeps_the_inactive_fast_path_clock_and_allocation_free', 0, (): void => {
      const clock: FakeDiagnosticClock = new FakeDiagnosticClock();
      const runtime: DiagnosticCaptureRuntime = new DiagnosticCaptureRuntime(clock);
      expect(runtime.record('connection.rdp', 'rdp_state_changed', 'state')).assertFalse();
      expect(clock.uptimeReads).assertEqual(0);
      expect(clock.wallReads).assertEqual(0);
      expect(runtime.status().phase).assertEqual('idle');
    });

    it('starts_one_capture_with_an_immutable_normalized_module_set', 0, (): void => {
      const clock: FakeDiagnosticClock = new FakeDiagnosticClock();
      const runtime: DiagnosticCaptureRuntime = new DiagnosticCaptureRuntime(clock);
      expect(runtime.start(10, ['connection.vnc', 'connection.rdp'])).assertEqual('ok');
      expect(runtime.start(10, ['connection.ssh_sftp'])).assertEqual('already_active');
      const status = runtime.status();
      expect(status.phase).assertEqual('capturing');
      expect(status.selectedModules.join(','))
        .assertEqual('core.app,connection.rdp,connection.vnc');
      expect(status.eventCount).assertEqual(1);
      expect(runtime.record('connection.ssh_sftp', 'ssh_session_event', 'state')).assertFalse();
      expect(runtime.record('connection.rdp', 'rdp_state_changed', 'state', 77, 3, 2))
        .assertTrue();
      expect(runtime.status().eventCount).assertEqual(2);
    });

    it('defaults_to_core_only_and_exposes_identity_only_to_selected_modules', 0, (): void => {
      const clock: FakeDiagnosticClock = new FakeDiagnosticClock();
      const runtime: DiagnosticCaptureRuntime = new DiagnosticCaptureRuntime(clock);
      expect(runtime.start(10)).assertEqual('ok');
      expect(runtime.status().selectedModules.join(',')).assertEqual('core.app');
      expect(runtime.captureIdForModule('core.app')).assertEqual('capture-1');
      expect(runtime.captureIdForModule('connection.rdp')).assertEqual('');
      expect(runtime.stop()).assertEqual('ok');
      expect(runtime.captureIdForModule('core.app')).assertEqual('');
    });

    it('maps_numeric_session_ids_to_capture_local_references', 0, (): void => {
      const clock: FakeDiagnosticClock = new FakeDiagnosticClock();
      const runtime: DiagnosticCaptureRuntime = new DiagnosticCaptureRuntime(clock);
      runtime.start(1, ['connection.rdp']);
      runtime.record('connection.rdp', 'rdp_state_changed', 'state', 987654321, 1, 2);
      runtime.record('connection.rdp', 'rdp_disconnect', 'succeeded', 987654321, 1, 0);
      runtime.record('connection.rdp', 'rdp_state_changed', 'state', 123456789, 2, 3);
      runtime.stop();
      const frozen: FrozenDiagnosticCapture = runtime.frozenCapture() as FrozenDiagnosticCapture;
      expect(frozen.events[1].sessionRef).assertEqual('session-1');
      expect(frozen.events[2].sessionRef).assertEqual('session-1');
      expect(frozen.events[3].sessionRef).assertEqual('session-2');
      expect(JSON.stringify(frozen).indexOf('987654321')).assertEqual(-1);
      expect(JSON.stringify(frozen).indexOf('123456789')).assertEqual(-1);
    });

    it('freezes_at_the_monotonic_deadline_even_when_wall_time_moves_back', 0, (): void => {
      const clock: FakeDiagnosticClock = new FakeDiagnosticClock();
      const runtime: DiagnosticCaptureRuntime = new DiagnosticCaptureRuntime(clock);
      runtime.start(1, ['connection.vnc']);
      clock.uptime += 60000;
      clock.wall -= 5000;
      expect(runtime.record('connection.vnc', 'vnc_state_changed', 'state')).assertFalse();
      const status = runtime.status();
      expect(status.phase).assertEqual('readyToSave');
      expect(status.stopReason).assertEqual('deadline');
      expect(status.remainingSeconds).assertEqual(0);
      const frozen: FrozenDiagnosticCapture = runtime.frozenCapture() as FrozenDiagnosticCapture;
      expect(frozen.events[frozen.events.length - 1].eventCode).assertEqual('capture_expired');
    });

    it('rejects_unknown_events_and_invalid_numbers_without_throwing', 0, (): void => {
      const clock: FakeDiagnosticClock = new FakeDiagnosticClock();
      const runtime: DiagnosticCaptureRuntime = new DiagnosticCaptureRuntime(clock);
      runtime.start(3, ['connection.ssh_sftp']);
      expect(runtime.record('connection.ssh_sftp', 'password=secret', 'failed')).assertFalse();
      expect(runtime.record('connection.ssh_sftp', 'ssh_session_event', 'state',
        0, 0, 0, Number.NaN)).assertFalse();
      expect(runtime.status().droppedEventCount).assertEqual(2);
      expect(runtime.status().eventCount).assertEqual(1);
    });

    it('copies_valid_runtime_facts_and_rejects_forged_categories', 0, (): void => {
      const clock: FakeDiagnosticClock = new FakeDiagnosticClock();
      const runtime: DiagnosticCaptureRuntime = new DiagnosticCaptureRuntime(clock);
      runtime.start(3, ['connection.rustdesk']);
      const facts: DiagnosticRuntimeFacts = {
        state: 'connected', backend: 'hardware', codec: 'h264', path: 'relay',
        peerPlatform: 'windows', presentation: 'identity',
        producerTransform: 'rotate_180', width: 1920, height: 1080,
        frames: 30, dropped: 0, errors: 0, queueDepth: 1, latencyMs: 20
      };
      const network: DiagnosticNetworkFacts = diagnosticNetworkFactsForEndpoints(
        '2001:db8::8', 21115, 'relay.example.invalid', 21116);
      expect(runtime.record('connection.rustdesk', 'rustdesk_runtime_snapshot',
        'state', 8, 1, 0, 20, 30, 4096, facts, network)).assertTrue();
      facts.peerPlatform = 'peer-id-canary' as 'windows';
      expect(runtime.record('connection.rustdesk', 'rustdesk_runtime_snapshot',
        'state', 8, 1, 0, 20, 30, 4096, facts)).assertFalse();
      network.configuredEndpointFamily = 'raw-address-canary' as 'ipv6';
      expect(runtime.record('connection.rustdesk', 'rustdesk_runtime_snapshot',
        'state', 8, 1, 0, 20, 30, 4096, {
          state: 'connected', backend: 'hardware', codec: 'h264', path: 'relay',
          peerPlatform: 'windows', presentation: 'identity',
          producerTransform: 'rotate_180', width: 1920, height: 1080,
          frames: 30, dropped: 0, errors: 0, queueDepth: 1, latencyMs: 20
        }, network)).assertFalse();
      runtime.stop();
      const frozen: FrozenDiagnosticCapture = runtime.frozenCapture() as FrozenDiagnosticCapture;
      expect(frozen.events[1].runtime.presentation).assertEqual('identity');
      expect(frozen.events[1].runtime.producerTransform).assertEqual('rotate_180');
      expect(frozen.events[1].network.configuredEndpointFamily).assertEqual('ipv6');
      expect(frozen.events[1].network.configuredRouteFamily).assertEqual('hostname');
      expect(JSON.stringify(frozen).indexOf('peer-id-canary')).assertEqual(-1);
      expect(JSON.stringify(frozen).indexOf('raw-address-canary')).assertEqual(-1);
    });

    it('caps_high_frequency_events_without_interrupting_the_capture', 0, (): void => {
      const clock: FakeDiagnosticClock = new FakeDiagnosticClock();
      const runtime: DiagnosticCaptureRuntime = new DiagnosticCaptureRuntime(clock);
      runtime.start(30, ['connection.rdp']);
      for (let index = 0; index < DIAGNOSTIC_MAX_EVENTS + 5; index += 1) {
        runtime.record('connection.rdp', 'rdp_state_changed', 'state', 7, 1, index);
      }
      let status = runtime.status();
      expect(status.phase).assertEqual('capturing');
      expect(status.eventCount).assertEqual(DIAGNOSTIC_MAX_EVENTS - 1);
      expect(status.droppedEventCount).assertEqual(7);
      expect(runtime.stop()).assertEqual('ok');
      status = runtime.status();
      expect(status.eventCount).assertEqual(DIAGNOSTIC_MAX_EVENTS);
      const frozen: FrozenDiagnosticCapture = runtime.frozenCapture() as FrozenDiagnosticCapture;
      expect(frozen.events[frozen.events.length - 1].eventCode).assertEqual('capture_stopped');
    });

    it('keeps_frozen_data_for_cancelled_saves_and_resets_only_after_success', 0, (): void => {
      const clock: FakeDiagnosticClock = new FakeDiagnosticClock();
      const runtime: DiagnosticCaptureRuntime = new DiagnosticCaptureRuntime(clock);
      runtime.start(5, ['data.cloud_sync']);
      runtime.record('data.cloud_sync', 'cloud_sync_completed', 'succeeded', 0, 0, 0, 20, 3, 0);
      expect(runtime.stop()).assertEqual('ok');
      expect(runtime.beginSaving()).assertEqual('ok');
      expect(runtime.status().phase).assertEqual('saving');
      runtime.finishSaving(false);
      expect(runtime.status().phase).assertEqual('readyToSave');
      expect((runtime.frozenCapture() as FrozenDiagnosticCapture).events.length).assertEqual(3);
      expect(runtime.beginSaving()).assertEqual('ok');
      runtime.finishSaving(true);
      expect(runtime.status().phase).assertEqual('idle');
      expect(runtime.frozenCapture()).assertNull();
    });

    it('binds_explicit_discard_to_the_observed_capture_identity', 0, (): void => {
      const clock: FakeDiagnosticClock = new FakeDiagnosticClock();
      const runtime: DiagnosticCaptureRuntime = new DiagnosticCaptureRuntime(clock);
      runtime.start(30, ['network.routing']);
      const firstCaptureId: string = runtime.status().captureId;
      expect(runtime.discard(firstCaptureId)).assertEqual('ok');
      expect(runtime.status().phase).assertEqual('idle');
      expect(runtime.discard()).assertEqual('not_active');
      runtime.start(30, ['connection.rdp']);
      const secondCaptureId: string = runtime.status().captureId;
      expect(runtime.discard(firstCaptureId)).assertEqual('stale_capture');
      expect(runtime.status().phase).assertEqual('capturing');
      expect(runtime.status().captureId).assertEqual(secondCaptureId);
      expect(runtime.discard(secondCaptureId)).assertEqual('ok');
    });
  });
}
