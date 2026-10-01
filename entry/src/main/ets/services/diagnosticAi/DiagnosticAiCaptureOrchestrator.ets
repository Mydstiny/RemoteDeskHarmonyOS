import { DiagnosticCaptureRuntime, DiagnosticCaptureActionCode } from '../DiagnosticCaptureRuntime';
import { DiagnosticAiCapturePlan, diagnosticAiBundleFromCapture, DiagnosticAiBundle, diagnosticAiPlanValid } from './DiagnosticAiBundlePolicy';

export class DiagnosticAiCaptureOrchestrator {
  private static instance: DiagnosticAiCaptureOrchestrator;
  private readonly runtime: DiagnosticCaptureRuntime = DiagnosticCaptureRuntime.getInstance();
  private owner: string = '';
  private generation: number = 0;

  static getInstance(): DiagnosticAiCaptureOrchestrator {
    if (!DiagnosticAiCaptureOrchestrator.instance) { DiagnosticAiCaptureOrchestrator.instance = new DiagnosticAiCaptureOrchestrator(); }
    return DiagnosticAiCaptureOrchestrator.instance;
  }

  start(owner: string, plan: DiagnosticAiCapturePlan): DiagnosticCaptureActionCode {
    if (!diagnosticAiPlanValid(plan) || owner.trim() === '') { return 'invalid_duration'; }
    if (this.owner !== '' && this.owner !== owner) { return 'busy'; }
    this.owner = owner; const result = this.runtime.start(plan.durationMinutes, plan.modules, false);
    if (result !== 'ok') { this.owner = ''; } return result;
  }

  stop(owner: string): DiagnosticCaptureActionCode {
    if (owner !== this.owner) { return 'stale_capture'; }
    const result = this.runtime.stop(); if (result === 'ok' || result === 'not_active') { this.owner = ''; } return result;
  }

  bundle(owner: string): DiagnosticAiBundle | null {
    if (owner !== this.owner && this.runtime.status().phase !== 'readyToSave') { return null; }
    return diagnosticAiBundleFromCapture(this.runtime.frozenCapture());
  }

  status() { return this.runtime.status(); }

  /** Stop capture before an account/logout/refund transition can change scope. */
  invalidateAll(): void {
    this.generation++;
    if (this.owner !== '') {
      this.runtime.stop();
      this.owner = '';
    }
    AppStorage.setOrCreate('diagnosticAiOrbEnabled', false);
  }

  currentGeneration(): number { return this.generation; }
}
