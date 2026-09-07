import { DiagnosticRuntimeFacts } from './DiagnosticCapturePolicy';
import { diagnosticCaptureIdForModule, DiagnosticCaptureRuntime } from './DiagnosticCaptureRuntime';

/** Explicit user observation is separate from the sampled transform; no pixel inference. */
export function recordVideoOrientation(protocol: 'rustdesk' | 'moonlight', sessionId: number,
  facts: DiagnosticRuntimeFacts, controlX: boolean, controlY: boolean,
  source: number, observation: number = 0, visualX: number = -1,
  visualY: number = -1, transformVersion: number = -1): boolean {
  const moduleId = protocol === 'rustdesk' ? 'connection.rustdesk' : 'connection.moonlight';
  if (sessionId <= 0 || diagnosticCaptureIdForModule(moduleId).length === 0 || facts.video === undefined) {
    return false;
  }
  facts.video.requestedVisualFlipX = visualX;
  facts.video.requestedVisualFlipY = visualY;
  facts.video.requestedTransformVersion = transformVersion;
  facts.video.controlFlipX = controlX ? 1 : 0;
  facts.video.controlFlipY = controlY ? 1 : 0;
  facts.video.flipSource = source;
  facts.video.observedOrientation = observation;
  return DiagnosticCaptureRuntime.getInstance().record(moduleId,
    protocol + '_orientation_observation', 'state', sessionId, 0, observation, 0, 0, 0, facts);
}
