export interface VncCertificateProbeIdentity {
  userId: string;
  hostId: string;
  gatewayId: string;
  endpointBindingFingerprint: string;
  storeGeneration: number;
}

function sameProbeIdentity(left: VncCertificateProbeIdentity,
  right: VncCertificateProbeIdentity): boolean {
  return left.userId.trim() !== '' && left.userId.trim() === right.userId.trim() &&
    left.hostId.trim() !== '' && left.hostId.trim() === right.hostId.trim() &&
    left.gatewayId.trim() === right.gatewayId.trim() &&
    left.endpointBindingFingerprint.trim() !== '' &&
    left.endpointBindingFingerprint.trim() === right.endpointBindingFingerprint.trim() &&
    left.storeGeneration === right.storeGeneration;
}

export function nextVncCertificateProbeGeneration(current: number): number {
  return current >= Number.MAX_SAFE_INTEGER ? 1 : current + 1;
}

export function nextVncConnectionAttemptGeneration(current: number): number {
  return current >= Number.MAX_SAFE_INTEGER ? 1 : current + 1;
}

export function shouldApplyVncCertificateProbeResult(
  activeGeneration: number,
  resultGeneration: number,
  activeIdentity: VncCertificateProbeIdentity,
  resultIdentity: VncCertificateProbeIdentity
): boolean {
  return activeGeneration === resultGeneration && sameProbeIdentity(activeIdentity, resultIdentity);
}

export function shouldRouteVncAfterCertificateSheetDisappear(
  sheetVisible: boolean,
  closing: boolean
): boolean {
  return !sheetVisible && !closing;
}
