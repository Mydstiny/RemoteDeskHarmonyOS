export function shouldOpenVncFloatingPanelAfterSheetDisappear(pending: boolean,
  connected: boolean, pendingSessionId: number, currentSessionId: number): boolean {
  return pending && connected && pendingSessionId > 0 && pendingSessionId === currentSessionId;
}
