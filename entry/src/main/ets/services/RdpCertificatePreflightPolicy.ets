export enum RdpCertificatePreflightState {
  PROBING = 0,
  TRUST_FIRST_TIME = 1,
  TRUSTED_MATCH = 2,
  CERTIFICATE_CHANGED = 3,
  ERROR = 4
}

export enum RdpCertificatePreflightDecision {
  CONTINUE_ONCE = 0,
  TRUST = 1
}

export const RDP_CERTIFICATE_UNKNOWN_TRUST_MODE: number = 0;
export const RDP_CERTIFICATE_LEGACY_IMPLICIT_TRUST_MODE: number = 1;
export const RDP_CERTIFICATE_EXPLICIT_TRUST_MODE: number = 2;

/**
 * 证书预检使用独立 TLS probe，而真实 FreeRDP 连接有自己的 endpoint/resolver 路径。
 * 已明确 pin 过指纹的主机在 probe 仅因 resolver 失败时可以继续交给真实连接，
 * 由 native 的指纹校验作为第二道闸门；首次信任不能在无法读证书时绕过预检。
 */
export function shouldFallbackToNativeRdpConnectionAfterResolverFailure(errorCode: number,
  trustMode: number, savedFingerprintSha256: string): boolean {
  return errorCode === -11 && trustMode === RDP_CERTIFICATE_EXPLICIT_TRUST_MODE &&
    savedFingerprintSha256.trim().length > 0;
}

export interface RdpCertificateProbeView {
  ok: boolean;
  fingerprintSha256: string;
  commonName: string;
  subject: string;
  issuer: string;
  flags: number;
  rootTrusted: boolean;
  hostMismatch: boolean;
  errorMessage: string;
}

export interface RdpCertificateTrustView {
  trustMode: number;
  savedFingerprintSha256: string;
  savedAllowHostMismatch?: boolean;
}

export function classifyRdpCertificateProbe(
  probe: RdpCertificateProbeView,
  trust: RdpCertificateTrustView
): RdpCertificatePreflightState {
  if (!probe.ok || probe.fingerprintSha256.length === 0) {
    return RdpCertificatePreflightState.ERROR;
  }
  if (trust.trustMode === RDP_CERTIFICATE_EXPLICIT_TRUST_MODE && trust.savedFingerprintSha256.length > 0) {
    if (trust.savedFingerprintSha256 !== probe.fingerprintSha256) {
      return RdpCertificatePreflightState.CERTIFICATE_CHANGED;
    }
    if (probe.hostMismatch && trust.savedAllowHostMismatch !== true) {
      return RdpCertificatePreflightState.TRUST_FIRST_TIME;
    }
    return RdpCertificatePreflightState.TRUSTED_MATCH;
  }
  return RdpCertificatePreflightState.TRUST_FIRST_TIME;
}

export function rdpCertificateWarningMessage(
  hostLabel: string,
  rootTrusted: boolean,
  hostMismatch: boolean
): string {
  let message: string = '你正在连接到 RDP 主机 “' + hostLabel + '”。';
  if (!rootTrusted) {
    message += '无法将证书反向验证到根证书。你的连接可能不安全。是否要继续？';
  } else {
    message += '此证书已通过根证书验证。是否继续连接？';
  }
  if (hostMismatch) {
    message += ' 证书名称与当前主机不匹配。';
  }
  return message;
}

export function shouldRequireRdpCertificateConfirmation(
  state: RdpCertificatePreflightState
): boolean {
  return state === RdpCertificatePreflightState.TRUST_FIRST_TIME ||
    state === RdpCertificatePreflightState.CERTIFICATE_CHANGED;
}

export function shouldPersistRdpCertificateTrust(
  decision: RdpCertificatePreflightDecision
): boolean {
  return decision === RdpCertificatePreflightDecision.TRUST;
}

export function rdpCertificateRouteDelayMsAfterSheetClose(): number {
  return 0;
}

export function shouldRouteRdpCertificateAfterSheetDisappear(sheetVisible: boolean): boolean {
  return sheetVisible;
}

export function shouldShowRdpCertificateProbeSheetBeforeProbe(
  trustMode: number,
  savedFingerprintSha256: string
): boolean {
  return trustMode !== RDP_CERTIFICATE_EXPLICIT_TRUST_MODE || savedFingerprintSha256.length === 0;
}
