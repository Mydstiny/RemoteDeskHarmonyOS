/**
 * Local-only VNC Gateway health stages.
 *
 * A TCP connect is deliberately not treated as a working Repeater path. The
 * state can only advance to protocol readiness when the native deep check has
 * observed the expected banner, pairing and RFB handoff.
 */
export type VncGatewayHealthStage =
  'UNTESTED' |
  'TCP_REACHABLE' |
  'TLS_CERT_CONFIRMATION_REQUIRED' |
  'TLS_PIN_MATCHED' |
  'REPEATER_BANNER_OK' |
  'TARGET_PAIRED' |
  'RFB_BANNER_READY' |
  'FAILED';

export type VncGatewayHealthCheck = 'tcp' | 'deep';

export interface VncGatewayTcpHealthInput {
  transport: string;
  enabled: boolean;
  repeaterMode: string;
  tcpReachable: boolean;
  errorCode: string;
}

export interface VncGatewayHealthInput {
  transport: string;
  enabled: boolean;
  repeaterMode: string;
  target: string;
  tcpReachable: boolean;
  tlsRequired: boolean;
  certificateConfirmed: boolean;
  pinMatched: boolean;
  repeaterBannerOk: boolean;
  targetPaired: boolean;
  rfbBannerReady: boolean;
  /** True only when the bounded native banner/pairing probe actually ran. */
  deepCheckAttempted: boolean;
  errorCode: string;
}

export interface VncGatewayHealthResult {
  stage: VncGatewayHealthStage;
  code: string;
  message: string;
  protocolReady: boolean;
}

function failed(code: string, message: string): VncGatewayHealthResult {
  return { stage: 'FAILED', code, message, protocolReady: false };
}

/**
 * The cheap port check is intentionally a separate contract. It never
 * produces a protocol-ready state and its success text remains explicit
 * about that limitation.
 */
export function classifyVncGatewayTcpHealth(input: VncGatewayTcpHealthInput): VncGatewayHealthResult {
  if (!input.enabled) {
    return failed('E-VNC-GATEWAY-DISABLED', 'Gateway 已停用');
  }
  if (input.transport !== 'ultravnc_repeater') {
    return failed('E-VNC-GATEWAY-TRANSPORT', '当前仅支持 UltraVNC Repeater mode12');
  }
  if (input.repeaterMode !== 'mode12') {
    return failed('E-VNC-REPEATER-MODE2-ROLE', 'mode2 是服务端监听角色，不能作为 Viewer 深度测试');
  }
  if (!input.tcpReachable) {
    return failed(input.errorCode.trim() === '' ? 'E-VNC-GATEWAY-TCP' : input.errorCode.trim(),
      'Gateway 端口不可达');
  }
  return {
    stage: 'TCP_REACHABLE', code: '',
    message: 'Gateway 端口可达，但不代表 Repeater、TLS 或 VNC 协议可用', protocolReady: false
  };
}

/** The native fixed field leaves three bytes for the ID: prefix. */
export function isSafeVncRepeaterTarget(value: string): boolean {
  const target: string = value.trim();
  if (target === '' || target.length > 247) { return false; }
  for (let i = 0; i < target.length; i++) {
    const code: number = target.charCodeAt(i);
    if (code < 0x21 || code > 0x7e) { return false; }
  }
  return true;
}

/** Classify one bounded check result; no result is persisted or cloud-synced. */
export function classifyVncGatewayHealth(input: VncGatewayHealthInput): VncGatewayHealthResult {
  if (!input.enabled) {
    return failed('E-VNC-GATEWAY-DISABLED', 'Gateway 已停用');
  }
  if (input.transport !== 'ultravnc_repeater') {
    return failed('E-VNC-GATEWAY-TRANSPORT', '当前仅支持 UltraVNC Repeater mode12');
  }
  if (input.repeaterMode !== 'mode12') {
    return failed('E-VNC-REPEATER-MODE2-ROLE', 'mode2 是服务端监听角色，不能作为 Viewer 深度测试');
  }
  if (!input.tcpReachable) {
    return failed(input.errorCode.trim() === '' ? 'E-VNC-GATEWAY-TCP' : input.errorCode,
      'Gateway 端口不可达');
  }
  if (!input.deepCheckAttempted) {
    return {
      stage: 'TCP_REACHABLE', code: 'E-VNC-GATEWAY-DEEP-CHECK-NOT-RUN',
      message: 'TCP 端口可达，尚未验证 Repeater/VNC 协议链路', protocolReady: false
    };
  }
  if (!isSafeVncRepeaterTarget(input.target)) {
    return failed('E-VNC-REPEATER-TARGET', 'target ID 不能为空、不能含控制字符且最多 247 个 ASCII 字符');
  }
  if (input.tlsRequired && !input.certificateConfirmed) {
    return {
      stage: 'TLS_CERT_CONFIRMATION_REQUIRED', code: 'E-VNC-CERT-TRUST-REQUIRED',
      message: 'TLS Gateway 需要先完成证书确认', protocolReady: false
    };
  }
  if (input.tlsRequired && !input.pinMatched) {
    return failed('E-VNC-CERT-CHANGED', 'TLS Gateway 证书与已确认指纹不匹配');
  }
  if (input.tlsRequired && !input.repeaterBannerOk) {
    return { stage: 'TLS_PIN_MATCHED', code: '', message: 'TLS 指纹匹配，等待 Repeater banner', protocolReady: false };
  }
  if (!input.repeaterBannerOk) {
    return failed('E-VNC-REPEATER-BANNER', 'Repeater banner 无效或读取不完整');
  }
  if (!input.targetPaired) {
    return { stage: 'REPEATER_BANNER_OK', code: '', message: 'Repeater banner 正确，等待 target pairing', protocolReady: false };
  }
  if (!input.rfbBannerReady) {
    return { stage: 'TARGET_PAIRED', code: '', message: 'target 已配对，等待 RFB banner', protocolReady: false };
  }
  return { stage: 'RFB_BANNER_READY', code: '', message: 'VNC 协议链路已验证', protocolReady: true };
}

export function untestedVncGatewayHealth(): VncGatewayHealthResult {
  return { stage: 'UNTESTED', code: '', message: '尚未执行 Gateway 检查', protocolReady: false };
}
