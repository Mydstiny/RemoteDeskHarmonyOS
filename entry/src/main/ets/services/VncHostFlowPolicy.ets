import { VncTransport } from './VncModelPolicy';

export const VNC_HOST_ADD_STEP_COUNT: number = 2;
export const VNC_GATEWAY_ADD_STEP_COUNT: number = 2;

export function clampVncFlowStep(step: number, stepCount: number): number {
  const safeCount: number = Math.max(1, Math.floor(stepCount));
  const safeStep: number = Number.isFinite(step) ? Math.floor(step) : 0;
  return Math.max(0, Math.min(safeStep, safeCount - 1));
}

export function nextVncFlowStep(step: number, stepCount: number): number {
  return clampVncFlowStep(clampVncFlowStep(step, stepCount) + 1, stepCount);
}

export function previousVncFlowStep(step: number, stepCount: number): number {
  return clampVncFlowStep(clampVncFlowStep(step, stepCount) - 1, stepCount);
}

export function isVncGatewayTransportSelectable(transport: VncTransport): boolean {
  return transport === 'ultravnc_repeater';
}
