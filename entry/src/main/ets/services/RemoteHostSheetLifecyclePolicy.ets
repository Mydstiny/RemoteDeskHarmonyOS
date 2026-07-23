/**
 * RemoteHostSheetLifecyclePolicy.ets - one-driver Sheet dismissal rules.
 *
 * Interactive dismissal is confirmed by DismissSheetAction.dismiss().
 * Programmatic dismissal is driven by the bound visibility state instead.
 */

export type RemoteHostSheetCloseSource = 'interactive' | 'programmatic';

export interface RemoteHostSheetDismissState {
  busy: boolean;
  closing: boolean;
  pendingRoute: boolean;
}

export function shouldAcceptRemoteHostSheetDismiss(state: RemoteHostSheetDismissState): boolean {
  return !state.busy && !state.closing && !state.pendingRoute;
}

export function shouldCallRemoteHostSheetDismissAction(source: RemoteHostSheetCloseSource): boolean {
  return source === 'interactive';
}

export function shouldSetRemoteHostSheetVisibility(source: RemoteHostSheetCloseSource): boolean {
  return source === 'programmatic';
}

export function nextRemoteHostSheetGeneration(current: number): number {
  return current >= Number.MAX_SAFE_INTEGER ? 1 : current + 1;
}

export function shouldApplyRemoteHostSheetResult(activeGeneration: number,
  resultGeneration: number, activeHostId: string, resultHostId: string): boolean {
  return activeGeneration === resultGeneration && activeHostId.length > 0 &&
    activeHostId === resultHostId;
}
