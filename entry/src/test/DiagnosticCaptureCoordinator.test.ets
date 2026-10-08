import { describe, expect, it } from '@ohos/hypium';
import { DiagnosticClock, DiagnosticCaptureRuntime } from '../main/ets/services/DiagnosticCaptureRuntime';
import { DiagnosticCaptureCoordinator } from '../main/ets/services/DiagnosticCaptureCoordinator';

class CoordinatorClock implements DiagnosticClock {
  uptime: number = 1000;
  wall: number = 1700000000000;

  uptimeMs(): number { return this.uptime; }
  wallTimeMs(): number { return this.wall; }
}

export default function diagnosticCaptureCoordinatorTest(): void {
  describe('DiagnosticCaptureCoordinator', (): void => {
    it('keeps_manual_and_ai_capture_owners_mutually_exclusive', 0, (): void => {
      const runtime: DiagnosticCaptureRuntime = new DiagnosticCaptureRuntime(new CoordinatorClock());
      const coordinator: DiagnosticCaptureCoordinator = new DiagnosticCaptureCoordinator(runtime);
      expect(coordinator.start('manual-sheet', 'manual', 1, ['core.app'])).assertEqual('ok');
      expect(coordinator.start('ai-panel', 'ai', 1, ['core.app'])).assertEqual('busy');
      expect(coordinator.stop('ai-panel', 'ai')).assertEqual('busy');
      expect(coordinator.status().ownerKind).assertEqual('manual');
      expect(coordinator.stop('manual-sheet', 'manual')).assertEqual('ok');
      expect(coordinator.bundle('ai-panel', 'ai')).assertEqual(null);
      expect(coordinator.bundle('manual-sheet', 'manual') === null).assertFalse();
      expect(coordinator.discard('manual-sheet', 'manual', 'capture-1')).assertEqual('ok');
      expect(coordinator.status().ownerKind).assertEqual('');
    });

    it('blocks_manual_actions_while_ai_owns_the_capture', 0, (): void => {
      const runtime: DiagnosticCaptureRuntime = new DiagnosticCaptureRuntime(new CoordinatorClock());
      const coordinator: DiagnosticCaptureCoordinator = new DiagnosticCaptureCoordinator(runtime);
      expect(coordinator.start('ai-panel', 'ai', 1, ['core.app'])).assertEqual('ok');
      expect(coordinator.start('manual-sheet', 'manual', 1, ['core.app'])).assertEqual('busy');
      expect(coordinator.discard('manual-sheet', 'manual', 'capture-1')).assertEqual('busy');
      coordinator.invalidateAll();
      expect(coordinator.status().phase).assertEqual('idle');
      expect(coordinator.status().ownerKind).assertEqual('');
    });

    it('does_not_leave_an_owner_after_invalid_start', 0, (): void => {
      const runtime: DiagnosticCaptureRuntime = new DiagnosticCaptureRuntime(new CoordinatorClock());
      const coordinator: DiagnosticCaptureCoordinator = new DiagnosticCaptureCoordinator(runtime);
      expect(coordinator.start('manual-sheet', 'manual', 2, ['core.app'])).assertEqual('invalid_duration');
      expect(coordinator.status().phase).assertEqual('idle');
      expect(coordinator.status().ownerId).assertEqual('');
      expect(coordinator.start('ai-panel', 'ai', 1, ['core.app'])).assertEqual('ok');
    });

    it('invalidates_a_ready_capture_and_releases_the_runtime', 0, (): void => {
      const runtime: DiagnosticCaptureRuntime = new DiagnosticCaptureRuntime(new CoordinatorClock());
      const coordinator: DiagnosticCaptureCoordinator = new DiagnosticCaptureCoordinator(runtime);
      expect(coordinator.start('ai-panel', 'ai', 1, ['core.app'])).assertEqual('ok');
      expect(coordinator.stop('ai-panel', 'ai')).assertEqual('ok');
      expect(coordinator.status().phase).assertEqual('readyToSave');
      coordinator.invalidateAll();
      expect(coordinator.status().phase).assertEqual('idle');
      expect(coordinator.start('manual-sheet', 'manual', 1, ['core.app'])).assertEqual('ok');
    });
  });
}
