import { DiagnosticAiCaptureState, DiagnosticAiOrbState } from './DiagnosticAiModels';

export interface DiagnosticAiOrbTransition {
  state: DiagnosticAiOrbState;
  capture: DiagnosticAiCaptureState;
  generation: number;
}

export function diagnosticAiOrbVisible(proVisible: boolean, configured: boolean, preference: boolean,
  pageActive: boolean): boolean {
  return proVisible && configured && preference && pageActive;
}

export function diagnosticAiOrbTransition(current: DiagnosticAiOrbTransition, action: string): DiagnosticAiOrbTransition {
  const next: DiagnosticAiOrbTransition = { state: current.state, capture: current.capture, generation: current.generation + 1 };
  if (action === 'open' && (current.state === 'idle' || current.state === 'error')) { next.state = 'opening'; }
  else if (action === 'opened') { next.state = 'open'; }
  else if (action === 'thinking') { next.state = 'thinking'; }
  else if (action === 'prepareCapture') { next.state = 'capturePreparing'; next.capture = 'arming'; }
  else if (action === 'captureStarted') { next.state = 'capturing'; next.capture = 'capturing'; }
  else if (action === 'captureReady') { next.state = 'result'; next.capture = 'ready'; }
  else if (action === 'error') { next.state = 'error'; next.capture = 'error'; }
  else if (action === 'dismiss') { next.state = 'idle'; next.capture = 'idle'; }
  return next;
}
