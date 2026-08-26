export enum RdpCertificatePreflightState {
  PROBING = 0,
  TRUST_FIRST_TIME = 1,
  TRUSTED_MATCH = 2,
  CERTIFICATE_CHANGED = 3,
  ERROR = 4
}

export type RdpPreflightStatus = 'completed' | 'inconclusive' | 'unavailable' | 'transportFailed';

export const RDP_PREFLIGHT_COMPLETED: RdpPreflightStatus = 'completed';
export const RDP_PREFLIGHT_INCONCLUSIVE: RdpPreflightStatus = 'inconclusive';
export const RDP_PREFLIGHT_UNAVAILABLE: RdpPreflightStatus = 'unavailable';
export const RDP_PREFLIGHT_TRANSPORT_FAILED: RdpPreflightStatus = 'transportFailed';

export enum RdpCertificatePreflightDecision {
  CONTINUE_ONCE = 0,
  TRUST = 1
}

export const RDP_CERTIFICATE_UNKNOWN_TRUST_MODE: number = 0;
export const RDP_CERTIFICATE_LEGACY_IMPLICIT_TRUST_MODE: number = 1;
export const RDP_CERTIFICATE_EXPLICIT_TRUST_MODE: number = 2;

/**
 * 证书预检使用独立 TLS probe，而真实 FreeRDP 连接有自己的 endpoint/resolver 路径。
 * 预检只报告观察结果。DNS/TCP/明确的连接超时仍然是传输失败；其余证书、TLS
 * 元数据或协议兼容性结果都交给真实连接和用户的明确选择处理。
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
  // DNS failure is a transport failure under the explicit preflight
  // contract. A saved pin must not turn it into an implicit connect decision.
  return false;
}

/**
 * Decide whether a failed certificate probe may still hand control to the
 * real RDP connection. This is a transport classification, not a trust
 * decision: the real certificate callback remains authoritative.
 */
export function rdpCertificatePreflightAllowsRealConnection(
  status: RdpPreflightStatus, errorCode: number
): boolean {
  // Preserve the diagnostic meaning for legacy numeric payloads as well.
  // These values map to negotiation/TLS/certificate observations, so an old
  // transportFailed status must not replace the user's explicit choice.
  switch (errorCode) {
    case -13:
    case -17:
    case -18:
    case -19:
    case -20:
    case -21:
    case -22:
    case -23:
    case -24:
    case -25:
    case -36:
    case -37:
    case -38:
      return true;
    default:
      break;
  }
  if (status === RDP_PREFLIGHT_TRANSPORT_FAILED) {
    return false;
  }
  if (status === RDP_PREFLIGHT_COMPLETED || status === RDP_PREFLIGHT_INCONCLUSIVE) {
    return true;
  }
  switch (errorCode) {
    case -10:
    case -11:
    case -12:
    case -14:
      return false;
    default:
      // Local probe setup and unknown diagnostics must not preempt a
      // FreeRDP attempt.
      return true;
  }
}

/**
 * Route probes report string error codes while the legacy direct probe reports
 * numeric ones. Keep the UI's admission rule explicit: a preflight can only
 * stop before the real connection for a known transport/configuration failure.
 * TLS, certificate, callback, and unknown-gateway observations stay advisory.
 */
export function rdpCertificateRoutePreflightAllowsRealConnection(
  status: RdpPreflightStatus, errorCode: string = '', riskFlags: string[] = []
): boolean {
  const normalizedErrorCode: string = errorCode.trim();
  // These codes describe what the certificate probe could (or could not)
  // observe after it reached the endpoint.  Older native payloads sometimes
  // attach transportFailed to them, so the diagnostic code must take
  // precedence over that stale status.  None of these observations is a
  // decision to trust the live certificate: Continue Once is still required
  // and FreeRDP's callback remains the final verifier.
  switch (normalizedErrorCode) {
    case 'E-RDP-TARGET-TLS':
    case 'E-RDP-GATEWAY-TLS':
    case 'E-RDP-TARGET-CERT':
    case 'E-RDP-GATEWAY-CERT':
    case 'E-RDP-CERT':
    case 'E-RDP-NEGOTIATION':
    case 'E-RDP-PREFLIGHT-NAPI':
    case 'E-RDP-PREFLIGHT-EXCEPTION':
    case 'E-RDP-BASTION-UNSUPPORTED':
    case 'E-RDP-GATEWAY-AWARE-UNAVAILABLE':
    case 'E-RDP-GATEWAY-AUTH-REQUIRED':
      return true;
    default:
      break;
  }
  if (riskFlags.indexOf('TLS_PROBE_RESET') >= 0) {
    return true;
  }
  if (status === RDP_PREFLIGHT_COMPLETED || status === RDP_PREFLIGHT_INCONCLUSIVE) {
    return true;
  }
  if (status === RDP_PREFLIGHT_TRANSPORT_FAILED) {
    return false;
  }
  switch (normalizedErrorCode) {
    case 'E-RDP-TARGET-DNS':
    case 'E-RDP-GATEWAY-DNS':
    case 'E-RDP-TARGET-TCP':
    case 'E-RDP-GATEWAY-TCP':
    case 'E-RDP-TARGET-TIMEOUT':
    case 'E-RDP-GATEWAY-TUNNEL':
    case 'E-RDP-GATEWAY-AUTH':
    case 'E-RDP-ENDPOINT':
    case 'E-RDP-GATEWAY-SNI':
    case 'E-RDP-ADAPTER':
    case 'E-RDP-CERT-ROUTE-STALE':
    case 'E-RDP-FREERDP-NEGOTIATION':
      return false;
    default:
      // Unknown probe diagnostics are advisory by default. The user's
      // Continue Once choice reaches FreeRDP, whose certificate callback
      // still validates the live peer.
      return true;
  }
}

/** Preserve both stage-level and record-level risks across old/new NAPI payloads. */
export function rdpCertificateEffectiveRiskFlags(
  primary: string[] = [], fallback: string[] = []
): string[] {
  const merged: string[] = [];
  primary.concat(fallback).forEach((flag: string): void => {
    if (flag.trim() !== '' && merged.indexOf(flag) < 0) {
      merged.push(flag);
    }
  });
  return merged;
}

export function shouldEnableStandardRdpSecurityOnce(
  userApprovedAdvisory: boolean, riskFlags: string[] = []
): boolean {
  return userApprovedAdvisory && riskFlags.indexOf('STANDARD_RDP_SECURITY') >= 0;
}

/**
 * Keeps the opt-in TLS-without-NLA escape hatch isolated from every existing
 * RDP path. Gateway, blank-password, and Restricted Admin always retain NLA.
 */
export function shouldUseRdpTlsWithoutNla(
  requested: boolean, endpointMode: string, authenticationMode: string
): boolean {
  return requested && endpointMode === 'direct_rdp' && authenticationMode === 'password';
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
  preflightStatus?: RdpPreflightStatus;
  riskFlags?: string[];
  requiresUserDecision?: boolean;
}

export function rdpCertificateRiskLabel(flag: string): string {
  switch (flag) {
    case 'UNTRUSTED_ROOT':
      return '证书链不受信';
    case 'HOSTNAME_MISMATCH':
      return '主机名不匹配';
    case 'CERTIFICATE_CHANGED':
      return '证书已变化';
    case 'CERTIFICATE_TIME_INVALID':
      return '证书时间异常';
    case 'CERTIFICATE_METADATA_UNAVAILABLE':
      return '证书元数据不完整，无法验证证书链和时间';
    case 'STANDARD_RDP_SECURITY':
      return '服务器未提供 TLS 证书，连接安全性较低';
    case 'TLS_PROBE_RESET':
      return '预检无法完成，可能是服务端、网关或协议兼容性问题';
    case 'GATEWAY_CERTIFICATE_RISK':
      return 'Gateway 证书存在风险';
    case 'TARGET_CERTIFICATE_RISK':
      return '目标 RDP 证书存在风险';
    case 'UNKNOWN_GATEWAY_PROTOCOL':
      return '当前预检无法识别该网关协议';
    default:
      return flag;
  }
}

export function rdpCertificateRiskSummary(flags: string[] = []): string {
  const unique: string[] = [];
  flags.forEach((flag: string): void => {
    if (flag.trim() !== '' && unique.indexOf(flag) < 0) {
      unique.push(flag);
    }
  });
  return unique.map((flag: string): string => rdpCertificateRiskLabel(flag)).join('；');
}

export function rdpPreflightStatusLabel(status: RdpPreflightStatus): string {
  switch (status) {
    case RDP_PREFLIGHT_COMPLETED:
      return '预检已完成';
    case RDP_PREFLIGHT_INCONCLUSIVE:
      return '预检结果不确定';
    case RDP_PREFLIGHT_TRANSPORT_FAILED:
      return '连接通道失败';
    case RDP_PREFLIGHT_UNAVAILABLE:
    default:
      return '预检不可用';
  }
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
    case 'E-RDP-GATEWAY-AUTH-REQUIRED':
      return '堡垒机需要认证后才能检查目标证书';
    case 'E-RDP-GATEWAY-AUTH':
      return '堡垒机认证配置无效';
    case 'E-RDP-NEGOTIATION':
      return '目标 RDP 协商失败';
    case 'E-RDP-TARGET-DNS':
      return '目标 RDP 地址解析失败';
    case 'E-RDP-TARGET-TCP':
      return '目标 RDP 连接失败';
    case 'E-RDP-TARGET-TIMEOUT':
      return '目标 RDP 连接超时';
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
      return 'target_tcp';
    case -13:
      return 'negotiation';
    case -14:
      return 'target_tcp';
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
      return 'E-RDP-TARGET-TCP';
    case -13:
      return 'E-RDP-NEGOTIATION';
    case -14:
      return 'E-RDP-TARGET-TIMEOUT';
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
  if ((probe.riskFlags || []).indexOf('CERTIFICATE_CHANGED') >= 0) {
    return RdpCertificatePreflightState.CERTIFICATE_CHANGED;
  }
  if (!probe.ok || probe.fingerprintSha256.length === 0) {
    if (probe.preflightStatus === RDP_PREFLIGHT_INCONCLUSIVE ||
      probe.requiresUserDecision === true || (probe.riskFlags || []).length > 0) {
      // A populated risk list is an observation, even when an older/native
      // probe reports its status as unavailable. Keep it user-decidable so
      // the real FreeRDP callback can evaluate the live endpoint.
      return RdpCertificatePreflightState.TRUST_FIRST_TIME;
    }
    return RdpCertificatePreflightState.ERROR;
  }
  const certificateTimeState: string = rdpCertificateValidityState(
    probe.notBeforeMs ?? 0, probe.notAfterMs ?? 0);
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
    if (certificateTimeState !== 'valid') {
      return RdpCertificatePreflightState.TRUST_FIRST_TIME;
    }
    return RdpCertificatePreflightState.TRUSTED_MATCH;
  }
  return RdpCertificatePreflightState.TRUST_FIRST_TIME;
}

export function rdpCertificateWarningMessage(
  hostLabel: string,
  rootTrusted: boolean,
  hostMismatch: boolean,
  riskFlags: string[] = []
): string {
  let message: string = '你正在连接到 RDP 主机 “' + hostLabel + '”。';
  if (riskFlags.indexOf('CERTIFICATE_METADATA_UNAVAILABLE') >= 0) {
    message += '证书元数据不完整，无法验证证书链和时间。';
  } else if (!rootTrusted) {
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
