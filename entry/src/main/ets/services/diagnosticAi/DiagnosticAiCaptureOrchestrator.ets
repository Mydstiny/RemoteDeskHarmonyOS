import { DiagnosticCaptureActionCode } from '../DiagnosticCaptureRuntime';
import { DiagnosticCaptureCoordinator } from '../DiagnosticCaptureCoordinator';
import { DiagnosticAiCapturePlan, diagnosticAiBundleFromCapture, DiagnosticAiBundle, diagnosticAiPlanValid } from './DiagnosticAiBundlePolicy';

export class DiagnosticAiCaptureOrchestrator {
  private static instance: DiagnosticAiCaptureOrchestrator;
  private readonly coordinator: DiagnosticCaptureCoordinator = DiagnosticCaptureCoordinator.getInstance();
  private owner: string = '';
  private generation: number = 0;

  static getInstance(): DiagnosticAiCaptureOrchestrator {
    if (!DiagnosticAiCaptureOrchestrator.instance) { DiagnosticAiCaptureOrchestrator.instance = new DiagnosticAiCaptureOrchestrator(); }
    return DiagnosticAiCaptureOrchestrator.instance;
  }

  start(owner: string, plan: DiagnosticAiCapturePlan): DiagnosticCaptureActionCode {
    if (!diagnosticAiPlanValid(plan) || owner.trim() === '') { return 'invalid_duration'; }
    if (this.owner !== '' && this.owner !== owner) { return 'busy'; }
    this.owner = owner;
    const result = this.coordinator.start(owner, 'ai', plan.durationMinutes, plan.modules, false);
    if (result !== 'ok') { this.owner = ''; } return result;
  }

  stop(owner: string): DiagnosticCaptureActionCode {
    if (owner !== this.owner) { return 'stale_capture'; }
    const result = this.coordinator.stop(owner, 'ai');
    // Keep the owner while the frozen capture is converted to an AI bundle.
    // The caller must release it with discard() after copying the bundle.
    if (result === 'not_active') { this.owner = ''; }
    return result;
  }

  bundle(owner: string): DiagnosticAiBundle | null {
    if (owner !== this.owner) { return null; }
    return diagnosticAiBundleFromCapture(this.coordinator.bundle(owner, 'ai'));
  }

  discard(owner: string, captureId: string = ''): DiagnosticCaptureActionCode {
    if (owner !== this.owner) { return 'stale_capture'; }
    const result = this.coordinator.discard(owner, 'ai', captureId);
    if (result === 'ok' || result === 'not_active') { this.owner = ''; }
    return result;
  }

  /** Stop and discard an AI capture that the user cancelled or a page abandoned. */
  cancel(owner: string): DiagnosticCaptureActionCode {
    if (owner !== this.owner) { return 'stale_capture'; }
    const stopped: DiagnosticCaptureActionCode = this.stop(owner);
    if (stopped !== 'ok' && stopped !== 'not_active') { return stopped; }
    const status = this.coordinator.status();
    return this.discard(owner, status.captureId);
  }

  status() { return this.coordinator.status(); }

  /** Stop capture before an account/logout/refund transition can change scope. */
  invalidateAll(): void {
    this.generation++;
    this.coordinator.invalidateAll();
    this.owner = '';
    AppStorage.setOrCreate('diagnosticAiOrbEnabled', false);
    AppStorage.setOrCreate('aiEntryState', 'idle');
    AppStorage.setOrCreate('aiEntryOpenRequest', 0);
  }

  currentGeneration(): number { return this.generation; }
}
