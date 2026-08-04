import { VncTlsEndpointOwnerType } from './VncTlsEndpointPolicy';

export enum VncCertificatePreflightState {
  IDLE = 'IDLE',
  PROBING = 'PROBING',
  PLAINTEXT_WARNING = 'PLAINTEXT_WARNING',
  TRUST_FIRST_TIME = 'TRUST_FIRST_TIME',
  TRUSTED_MATCH = 'TRUSTED_MATCH',
  CERTIFICATE_CHANGED = 'CERTIFICATE_CHANGED',
  ERROR = 'ERROR',
  CLOSING = 'CLOSING'
}

export enum VncCertificatePreflightDecision {
  CANCEL = 'CANCEL',
  CONTINUE_PLAINTEXT = 'CONTINUE_PLAINTEXT',
  CONTINUE_ONCE = 'CONTINUE_ONCE',
  TRUST = 'TRUST',
  UPDATE_TRUST = 'UPDATE_TRUST'
}

export interface VncCertificateProbeView {
  ok: boolean;
  fingerprintSha256: string;
  commonName: string;
  subject: string;
  issuer: string;
  notBeforeMs: number;
  notAfterMs: number;
  rootTrusted: boolean;
  hostMismatch: boolean;
  errorCode: string;
  errorMessage: string;
}

export interface VncCertificateTrustView {
  ownerType: VncTlsEndpointOwnerType;
  ownerId: string;
  userId: string;
  storeIdentityFingerprint: string;
  endpointBindingFingerprint: string;
  fingerprintSha256: string;
  confirmed: boolean;
  confirmedAt: number;
  cloudCandidate: boolean;
}

function normalizedFingerprint(value: string): string {
  return value.trim().toLowerCase();
}

function hasLocalConfirmation(trust: VncCertificateTrustView): boolean {
  return trust.confirmed && !trust.cloudCandidate &&
    Number.isSafeInteger(trust.confirmedAt) && trust.confirmedAt > 0;
}

export function isVncSha256Fingerprint(value: string): boolean {
  return /^[0-9a-f]{64}$/.test(normalizedFingerprint(value));
}

export function classifyVncCertificateProbe(probe: VncCertificateProbeView,
  trust: VncCertificateTrustView | null): VncCertificatePreflightState {
  const fingerprint: string = normalizedFingerprint(probe.fingerprintSha256);
  if (!probe.ok || !isVncSha256Fingerprint(fingerprint)) {
    return VncCertificatePreflightState.ERROR;
  }
  if (trust === null || trust.ownerId.trim() === '' ||
    !isVncSha256Fingerprint(trust.endpointBindingFingerprint) ||
    !isVncSha256Fingerprint(trust.storeIdentityFingerprint) ||
    trust.userId.trim() === '') {
    return VncCertificatePreflightState.TRUST_FIRST_TIME;
  }
  if (!isVncSha256Fingerprint(trust.fingerprintSha256)) {
    return VncCertificatePreflightState.TRUST_FIRST_TIME;
  }
  if (normalizedFingerprint(trust.fingerprintSha256) !== fingerprint) {
    return VncCertificatePreflightState.CERTIFICATE_CHANGED;
  }
  if (!hasLocalConfirmation(trust)) {
    return VncCertificatePreflightState.TRUST_FIRST_TIME;
  }
  return VncCertificatePreflightState.TRUSTED_MATCH;
}

/** Owner and endpoint binding must match before a saved pin is eligible. */
export function classifyVncCertificateProbeForOwner(
  probe: VncCertificateProbeView,
  trust: VncCertificateTrustView | null,
  ownerType: VncTlsEndpointOwnerType,
  ownerId: string,
  userId: string,
  storeIdentityFingerprint: string,
  endpointBindingFingerprint: string
): VncCertificatePreflightState {
  if (ownerId.trim() === '' || userId.trim() === '' ||
    !isVncSha256Fingerprint(storeIdentityFingerprint) ||
    !isVncSha256Fingerprint(endpointBindingFingerprint)) {
    return classifyVncCertificateProbe(probe, null);
  }
  if (trust !== null && (trust.ownerType !== ownerType || trust.ownerId.trim() !== ownerId.trim() ||
    trust.userId.trim() !== userId.trim() ||
    normalizedFingerprint(trust.storeIdentityFingerprint) !== normalizedFingerprint(storeIdentityFingerprint) ||
    normalizedFingerprint(trust.endpointBindingFingerprint) !== normalizedFingerprint(endpointBindingFingerprint))) {
    return classifyVncCertificateProbe(probe, null);
  }
  return classifyVncCertificateProbe(probe, trust);
}

export function shouldRequireVncCertificateConfirmation(
  state: VncCertificatePreflightState
): boolean {
  return state === VncCertificatePreflightState.TRUST_FIRST_TIME ||
    state === VncCertificatePreflightState.CERTIFICATE_CHANGED;
}

export function shouldPersistVncCertificateTrust(
  decision: VncCertificatePreflightDecision
): boolean {
  return decision === VncCertificatePreflightDecision.TRUST ||
    decision === VncCertificatePreflightDecision.UPDATE_TRUST;
}

export function shouldUseVncCertificateOnce(
  decision: VncCertificatePreflightDecision
): boolean {
  return decision === VncCertificatePreflightDecision.CONTINUE_ONCE;
}

export function vncCertificateDecisionAllowed(
  state: VncCertificatePreflightState,
  decision: VncCertificatePreflightDecision
): boolean {
  if (decision === VncCertificatePreflightDecision.CANCEL) { return true; }
  if (state === VncCertificatePreflightState.PLAINTEXT_WARNING) {
    return decision === VncCertificatePreflightDecision.CONTINUE_PLAINTEXT;
  }
  if (state === VncCertificatePreflightState.TRUST_FIRST_TIME) {
    return decision === VncCertificatePreflightDecision.CONTINUE_ONCE ||
      decision === VncCertificatePreflightDecision.TRUST;
  }
  if (state === VncCertificatePreflightState.CERTIFICATE_CHANGED) {
    return decision === VncCertificatePreflightDecision.CONTINUE_ONCE ||
      decision === VncCertificatePreflightDecision.UPDATE_TRUST;
  }
  return false;
}
