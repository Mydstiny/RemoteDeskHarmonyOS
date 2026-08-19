import { describe, expect, it } from '@ohos/hypium';
import {
  DiagnosticCaptureExportService,
  DiagnosticDocumentPort,
  DiagnosticSaveCode,
  DiagnosticSaveResult,
  DiagnosticSerializationResult,
  diagnosticBytesEqual,
  diagnosticLogFileName,
  serializeDiagnosticCapture,
  validateDiagnosticJsonl,
  validateFrozenDiagnosticCapture
} from '../main/ets/services/DiagnosticCaptureExportService';
import {
  DiagnosticCaptureRuntime,
  DiagnosticClock,
  FrozenDiagnosticCapture
} from '../main/ets/services/DiagnosticCaptureRuntime';

class ExportFakeClock implements DiagnosticClock {
  uptime: number = 100;
  wall: number = 1700000000000;

  uptimeMs(): number { return this.uptime; }
  wallTimeMs(): number { return this.wall; }
}

class FakeDiagnosticDocumentPort implements DiagnosticDocumentPort {
  resultCode: DiagnosticSaveCode = 'ok';
  shouldThrow: boolean = false;
  calls: number = 0;
  savedFileName: string = '';
  savedBytes: number = 0;

  async save(fileName: string, bytes: Uint8Array): Promise<DiagnosticSaveResult> {
    this.calls += 1;
    this.savedFileName = fileName;
    this.savedBytes = bytes.length;
    if (this.shouldThrow) { throw new Error('fake document failure'); }
    return {
      ok: this.resultCode === 'ok',
      code: this.resultCode,
      fileName: fileName,
      bytesWritten: this.resultCode === 'ok' ? bytes.length : 0
    };
  }
}

function frozenCapture(): FrozenDiagnosticCapture {
  const clock: ExportFakeClock = new ExportFakeClock();
  const runtime: DiagnosticCaptureRuntime = new DiagnosticCaptureRuntime(clock);
  runtime.start(10, ['connection.rdp', 'security.ssh_key']);
  runtime.record('connection.rdp', 'rdp_state_changed', 'state', 987654321, 7, 2, 12, 1, 0);
  runtime.record('security.ssh_key', 'ssh_key_import', 'succeeded', 0, 0, 0, 30, 1, 2048);
  clock.uptime += 500;
  clock.wall += 500;
  runtime.stop();
  return runtime.frozenCapture() as FrozenDiagnosticCapture;
}

export default function diagnosticCaptureExportServiceTest(): void {
  describe('DiagnosticCaptureExportService', (): void => {
    it('serializes_manifest_events_and_summary_as_parseable_jsonl', 0, (): void => {
      const capture: FrozenDiagnosticCapture = frozenCapture();
      const result: DiagnosticSerializationResult = serializeDiagnosticCapture(capture);
      expect(result.ok).assertTrue();
      expect(result.code).assertEqual('ok');
      expect(result.fileName.startsWith('RemoteDesktop-log-')).assertTrue();
      expect(result.fileName.endsWith('.jsonl')).assertTrue();
      expect(result.text.endsWith('\n')).assertTrue();
      expect(validateDiagnosticJsonl(result.text)).assertTrue();
      const lines: string[] = result.text.substring(0, result.text.length - 1).split('\n');
      expect(lines.length).assertEqual(capture.events.length + 2);
      const manifest: Record<string, Object> = JSON.parse(lines[0]) as Record<string, Object>;
      const summary: Record<string, Object> =
        JSON.parse(lines[lines.length - 1]) as Record<string, Object>;
      expect(manifest['kind'] as string).assertEqual('manifest');
      expect(summary['kind'] as string).assertEqual('summary');
      expect(summary['eventCount'] as number).assertEqual(capture.events.length);
      expect(summary['serializedBytes'] as number).assertEqual(result.bytes.length);
    });

    it('never_serializes_rejected_free_text_or_raw_correlation_ids', 0, (): void => {
      const clock: ExportFakeClock = new ExportFakeClock();
      const runtime: DiagnosticCaptureRuntime = new DiagnosticCaptureRuntime(clock);
      runtime.start(3, ['connection.ssh_sftp', 'data.local_store']);
      const canaries: string[] = [
        'PASSWORD_CANARY_91', 'TOKEN_CANARY_92', 'private-key-canary',
        'host.example.invalid', '/private/secret/path', 'SELECT * FROM secret',
        'terminal-command-canary', 'clipboard-canary', 'stack-trace-canary'
      ];
      for (let i: number = 0; i < canaries.length; i++) {
        runtime.record('connection.ssh_sftp', canaries[i], 'failed', 987654321);
      }
      runtime.record('connection.ssh_sftp', 'ssh_session_event', 'state', 987654321, 4, 1);
      clock.uptime += 20;
      clock.wall += 20;
      runtime.stop();
      const result: DiagnosticSerializationResult =
        serializeDiagnosticCapture(runtime.frozenCapture());
      expect(result.ok).assertTrue();
      for (let i: number = 0; i < canaries.length; i++) {
        expect(result.text.indexOf(canaries[i])).assertEqual(-1);
      }
      expect(result.text.indexOf('987654321')).assertEqual(-1);
      expect(result.text.indexOf('session-1') >= 0).assertTrue();
    });

    it('rejects_forged_capture_strings_before_any_bytes_are_created', 0, (): void => {
      const capture: FrozenDiagnosticCapture = frozenCapture();
      capture.events[1].eventCode = 'PASSWORD_CANARY_FORGED';
      expect(validateFrozenDiagnosticCapture(capture)).assertFalse();
      const result: DiagnosticSerializationResult = serializeDiagnosticCapture(capture);
      expect(result.ok).assertFalse();
      expect(result.text).assertEqual('');
      expect(result.bytes.length).assertEqual(0);
    });

    it('serializes_after_wall_clock_rollback_using_monotonic_projection', 0, (): void => {
      const clock: ExportFakeClock = new ExportFakeClock();
      const runtime: DiagnosticCaptureRuntime = new DiagnosticCaptureRuntime(clock);
      runtime.start(1, ['connection.vnc']);
      clock.uptime += 1000;
      clock.wall -= 60000;
      runtime.stop();
      const capture: FrozenDiagnosticCapture = runtime.frozenCapture() as FrozenDiagnosticCapture;
      expect(capture.endedWallTimeMs >= capture.startedWallTimeMs).assertTrue();
      expect(serializeDiagnosticCapture(capture).ok).assertTrue();
    });

    it('keeps_frozen_data_after_cancel_and_resets_only_after_confirmed_write', 0,
      async (): Promise<void> => {
        const clock: ExportFakeClock = new ExportFakeClock();
        const runtime: DiagnosticCaptureRuntime = new DiagnosticCaptureRuntime(clock);
        runtime.start(3, ['data.cloud_sync']);
        runtime.stop();
        const service: DiagnosticCaptureExportService = new DiagnosticCaptureExportService();
        const cancelled: FakeDiagnosticDocumentPort = new FakeDiagnosticDocumentPort();
        cancelled.resultCode = 'cancelled';
        const first: DiagnosticSaveResult =
          await service.saveWithPort(runtime, cancelled);
        expect(first.code).assertEqual('cancelled');
        expect(cancelled.calls).assertEqual(1);
        expect(runtime.status().phase).assertEqual('readyToSave');

        const success: FakeDiagnosticDocumentPort = new FakeDiagnosticDocumentPort();
        const second: DiagnosticSaveResult = await service.saveWithPort(runtime, success);
        expect(second.ok).assertTrue();
        expect(success.savedFileName.endsWith('.jsonl')).assertTrue();
        expect(success.savedBytes > 0).assertTrue();
        expect(runtime.status().phase).assertEqual('idle');
      });

    it('restores_ready_state_for_short_write_verify_failure_and_port_exception', 0,
      async (): Promise<void> => {
        const failureCodes: DiagnosticSaveCode[] = ['short_write', 'verify_failed'];
        for (let i: number = 0; i < failureCodes.length; i++) {
          const clock: ExportFakeClock = new ExportFakeClock();
          const runtime: DiagnosticCaptureRuntime = new DiagnosticCaptureRuntime(clock);
          runtime.start(5, ['network.routing']);
          runtime.stop();
          const port: FakeDiagnosticDocumentPort = new FakeDiagnosticDocumentPort();
          port.resultCode = failureCodes[i];
          const result: DiagnosticSaveResult =
            await new DiagnosticCaptureExportService().saveWithPort(runtime, port);
          expect(result.code).assertEqual(failureCodes[i]);
          expect(runtime.status().phase).assertEqual('readyToSave');
        }
        const clock: ExportFakeClock = new ExportFakeClock();
        const runtime: DiagnosticCaptureRuntime = new DiagnosticCaptureRuntime(clock);
        runtime.start(5, ['connection.rdp']);
        runtime.stop();
        const throwing: FakeDiagnosticDocumentPort = new FakeDiagnosticDocumentPort();
        throwing.shouldThrow = true;
        const result: DiagnosticSaveResult =
          await new DiagnosticCaptureExportService().saveWithPort(runtime, throwing);
        expect(result.code).assertEqual('io_error');
        expect(runtime.status().phase).assertEqual('readyToSave');
      });

    it('rejects_malformed_or_incomplete_jsonl', 0, (): void => {
      expect(validateDiagnosticJsonl('')).assertFalse();
      expect(validateDiagnosticJsonl('{}\n')).assertFalse();
      expect(validateDiagnosticJsonl('{"kind":"manifest"}\n{"kind":"event"}\n'))
        .assertFalse();
      const result: DiagnosticSerializationResult = serializeDiagnosticCapture(null);
      expect(result.ok).assertFalse();
      expect(result.code).assertEqual('invalid_capture');
    });

    it('uses_deterministic_file_names_and_byte_comparison', 0, (): void => {
      const name: string = diagnosticLogFileName(1700000000000);
      expect(name.startsWith('RemoteDesktop-log-')).assertTrue();
      expect(name.endsWith('.jsonl')).assertTrue();
      expect(diagnosticBytesEqual(new Uint8Array([1, 2]), new Uint8Array([1, 2]))).assertTrue();
      expect(diagnosticBytesEqual(new Uint8Array([1, 2]), new Uint8Array([1, 3]))).assertFalse();
    });
  });
}
