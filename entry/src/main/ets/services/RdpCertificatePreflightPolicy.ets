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
 * 只有明确 pin 且 pin 绑定当前完整路由的主机，在 probe 仅因 resolver 失败时才可以
 * 继续交给真实连接，由 native 的指纹校验作为第二道闸门；首次信任或旧路由信任
 * 不能在无法读证书时绕过预检。
 */
export function rdpCertificateRouteIsCurrent(
  savedRouteIdentity: string,
  currentRouteIdentity: string
): boolean {
  const saved: string = savedRouteIdentity.trim();
  const current: string = currentRouteIdentity.trim();
  return saved.length > 0 && current.length > 0 && saved === current;
}

export function shouldFallbackToNativeRdpConnectionAfterResolverFailure(errorCode: number,
  trustMode: number, savedFingerprintSha256: string,
  savedRouteIdentity: string, currentRouteIdentity: string): boolean {
  return errorCode === -11 && trustMode === RDP_CERTIFICATE_EXPLICIT_TRUST_MODE &&
    savedFingerprintSha256.trim().length > 0 &&
    rdpCertificateRouteIsCurrent(savedRouteIdentity, currentRouteIdentity);
}

export interface RdpCertificateProbeView {
  ok: boolean;
  fingerprintSha256: string;
  commonName: string;
  subject: string;
  issuer: string;
  notBeforeMs?: number;
  notAfterMs?: number;
  flags: number;
  rootTrusted: boolean;
  hostMismatch: boolean;
  errorMessage: string;
}

export function rdpCertificateValidityState(
  notBeforeMs: number = 0,
  notAfterMs: number = 0,
  nowMs: number = Date.now()
): string {
  if (notBeforeMs <= 0 && notAfterMs <= 0) {
    return 'unknown';
  }
  if (notBeforeMs <= 0 || notAfterMs <= notBeforeMs) {
    return 'invalid';
  }
  if (nowMs < notBeforeMs) {
    return 'not_yet_valid';
  }
  if (nowMs > notAfterMs) {
    return 'expired';
  }
  return 'valid';
}

export function rdpCertificateErrorTitle(stage: string, errorCode: string): string {
  switch (errorCode) {
    case 'E-RDP-GATEWAY-DNS':
      return '堡垒机地址解析失败';
    case 'E-RDP-GATEWAY-TCP':
      return '堡垒机连接失败';
    case 'E-RDP-GATEWAY-TLS':
      return '堡垒机 TLS 检查失败';
    case 'E-RDP-GATEWAY-CERT':
      return '堡垒机证书检查失败';
    case 'E-RDP-GATEWAY-TUNNEL':
      return '堡垒机隧道协商失败';
    case 'E-RDP-GATEWAY-AUTH':
      return '堡垒机认证失败';
    case 'E-RDP-NEGOTIATION':
      return '目标 RDP 协商失败';
    case 'E-RDP-TARGET-DNS':
      return '目标 RDP 地址解析失败';
    case 'E-RDP-TARGET-TCP':
      return '目标 RDP 连接失败';
    case 'E-RDP-TARGET-TLS':
      return '目标 RDP TLS 检查失败';
    case 'E-RDP-TARGET-CERT':
      return '目标 RDP 证书检查失败';
    case 'E-RDP-BASTION-UNSUPPORTED':
      return '堡垒机类型暂不支持';
    case 'E-RDP-GATEWAY-AWARE-UNAVAILABLE':
      return 'Gateway 证书预检不可用';
    case 'E-RDP-ENDPOINT':
      return 'RDP 连接端点配置无效';
    case 'E-RDP-CERT-ROUTE-STALE':
      return 'RDP 路由已变化，需要重新检查证书';
    case 'E-RDP-CERT-PERSIST':
      return 'RDP 证书信任保存失败';
    case 'E-RDP-PREFLIGHT-NAPI':
    case 'E-RDP-PREFLIGHT-EXCEPTION':
      return 'RDP 证书预检失败';
    default:
      if (stage === 'endpoint') {
        return 'RDP 预检端点失败';
      }
      if (stage === 'gateway') {
        return '堡垒机 TLS 检查失败';
      }
      if (stage === 'tunnel') {
        return '堡垒机隧道协商失败';
      }
      if (stage === 'negotiation') {
        return '目标 RDP 协商失败';
      }
      return '目标 RDP 证书检查失败';
  }
}

/** Keep the requested Gateway policy separate from observed wire evidence. */
export function rdpGatewayTransportSummary(
  requested: string,
  negotiated: string
): string {
  const requestedValue: string = requested.trim() !== '' ? requested.trim() : 'auto';
  const observed: string = negotiated === 'http' || negotiated === 'rpc' ||
    negotiated === 'websocket' ? negotiated : 'unknown';
  const observedLabel: string = observed === 'unknown' ? '未观测' : observed;
  return 'Gateway 传输策略: 请求 ' + requestedValue + ' · 实际 ' + observedLabel;
}

export function rdpCertificateLegacyProbeStage(errorCode: number): string {
  switch (errorCode) {
    case -10:
    case -11:
      return 'endpoint';
    case -12:
    case -13:
      return 'target_tcp';
    case -14:
    case -18:
    case -19:
    case -20:
    case -21:
      return 'negotiation';
    case -17:
    case -25:
      return 'target_cert';
    default:
      return 'target';
  }
}

export function rdpCertificateLegacyProbeErrorCode(errorCode: number): string {
  switch (errorCode) {
    case -10:
      return 'E-RDP-ENDPOINT';
    case -11:
      return 'E-RDP-TARGET-DNS';
    case -12:
    case -13:
      return 'E-RDP-TARGET-TCP';
    case -14:
    case -18:
    case -19:
    case -20:
    case -21:
      return 'E-RDP-NEGOTIATION';
    case -17:
    case -25:
      return 'E-RDP-TARGET-CERT';
    default:
      return 'E-RDP-TARGET-TLS';
  }
}

export interface RdpCertificateTrustView {
  trustMode: number;
  savedFingerprintSha256: string;
  routeBound?: boolean;
  savedAllowUntrustedRoot?: boolean;
  savedAllowHostMismatch?: boolean;
}

export function classifyRdpCertificateProbe(
  probe: RdpCertificateProbeView,
  trust: RdpCertificateTrustView
): RdpCertificatePreflightState {
  if (!probe.ok || probe.fingerprintSha256.length === 0) {
    return RdpCertificatePreflightState.ERROR;
  }
  if (rdpCertificateValidityState(probe.notBeforeMs ?? 0, probe.notAfterMs ?? 0) !== 'valid') {
    return RdpCertificatePreflightState.ERROR;
  }
  if (trust.trustMode === RDP_CERTIFICATE_EXPLICIT_TRUST_MODE && trust.savedFingerprintSha256.length > 0) {
    if (trust.routeBound !== true) {
      return RdpCertificatePreflightState.TRUST_FIRST_TIME;
    }
    if (trust.savedFingerprintSha256 !== probe.fingerprintSha256) {
      return RdpCertificatePreflightState.CERTIFICATE_CHANGED;
    }
    if (probe.hostMismatch && trust.savedAllowHostMismatch !== true) {
      return RdpCertificatePreflightState.TRUST_FIRST_TIME;
    }
    if (!probe.rootTrusted && trust.savedAllowUntrustedRoot !== true) {
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
  savedFingerprintSha256: string,
  routeBound: boolean = false
): boolean {
  return trustMode !== RDP_CERTIFICATE_EXPLICIT_TRUST_MODE ||
    savedFingerprintSha256.length === 0 || !routeBound;
}
