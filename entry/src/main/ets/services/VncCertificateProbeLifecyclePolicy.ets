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
    isCanonicalEndpointBindingFingerprint(left.endpointBindingFingerprint) &&
    isCanonicalEndpointBindingFingerprint(right.endpointBindingFingerprint) &&
    left.endpointBindingFingerprint === right.endpointBindingFingerprint &&
    left.storeGeneration === right.storeGeneration;
}

function isPositiveGeneration(value: number): boolean {
  return Number.isSafeInteger(value) && value > 0;
}

function isCanonicalEndpointBindingFingerprint(value: string): boolean {
  return value.length === 64 && /^[0-9a-f]{64}$/.test(value);
}

export function nextVncCertificateProbeGeneration(current: number): number {
  return !isPositiveGeneration(current) || current >= Number.MAX_SAFE_INTEGER ? 1 : current + 1;
}

export function nextVncConnectionAttemptGeneration(current: number): number {
  return !isPositiveGeneration(current) || current >= Number.MAX_SAFE_INTEGER ? 1 : current + 1;
}

export function shouldApplyVncCertificateProbeResult(
  activeProbeGeneration: number,
  resultProbeGeneration: number,
  activeConnectionAttemptGeneration: number,
  resultConnectionAttemptGeneration: number,
  activeIdentity: VncCertificateProbeIdentity,
  resultIdentity: VncCertificateProbeIdentity
): boolean {
  return isPositiveGeneration(activeProbeGeneration) &&
    isPositiveGeneration(resultProbeGeneration) &&
    isPositiveGeneration(activeConnectionAttemptGeneration) &&
    isPositiveGeneration(resultConnectionAttemptGeneration) &&
    activeProbeGeneration === resultProbeGeneration &&
    activeConnectionAttemptGeneration === resultConnectionAttemptGeneration &&
    sameProbeIdentity(activeIdentity, resultIdentity);
}

export function shouldRouteVncAfterCertificateSheetDisappear(
  sheetVisible: boolean,
  closing: boolean
): boolean {
  return !sheetVisible && !closing;
}
