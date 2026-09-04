export enum RdpSessionErrorSource {
  SERVER_ERROR_INFO = 'server-error-info',
  LOCAL_RENDER_WATCHDOG = 'local-render-watchdog',
  CONNECT_FAILURE = 'connect-failure',
  TRANSPORT_FAILURE = 'transport-failure'
}

export const RDP_CONNECT_FAILURE_UNCLASSIFIED: string = 'E-RDP-CONNECT-UNCLASSIFIED';
export const RDP_SESSION_END_UNCLASSIFIED: string = 'E-RDP-SESSION-END-UNCLASSIFIED';

export interface RdpSessionErrorDialogModel {
  title: string;
  message: string;
  code: string;
  source: RdpSessionErrorSource;
}

function extractHexCodeAfterMarker(text: string, marker: string): string {
  const markerIndex: number = text.indexOf(marker);
  if (markerIndex < 0) {
    return '';
  }
  const markerTail: string = text.substring(markerIndex + marker.length);
  const relativeHexIndex: number = markerTail.indexOf('0x');
  if (relativeHexIndex < 0) {
    return '';
  }
  const idx: number = markerIndex + marker.length + relativeHexIndex;
  const closeRelative: number = markerTail.indexOf(']');
  if (closeRelative >= 0 && relativeHexIndex > closeRelative) {
    return '';
  }
  const hexMarker: string = '0x';
  let code: string = hexMarker;
  for (let i = idx + hexMarker.length; i < text.length; i++) {
    const ch: string = text.charAt(i);
    const isHex: boolean = (ch >= '0' && ch <= '9') ||
      (ch >= 'a' && ch <= 'f') || (ch >= 'A' && ch <= 'F');
    if (!isHex) {
      break;
    }
    code += ch;
  }
  return code.length > hexMarker.length ? code : '';
}

function validDiagnosticCode(code: string): boolean {
  if (!code.startsWith('E-') || code.length > 96) {
    return false;
  }
  for (let i = 0; i < code.length; i++) {
    const ch: string = code.charAt(i);
    const valid: boolean = (ch >= 'A' && ch <= 'Z') ||
      (ch >= '0' && ch <= '9') || ch === '-';
    if (!valid) {
      return false;
    }
  }
  return true;
}

function extractNativeDiagnosticCode(text: string): string {
  const marker: string = '[E-';
  let remainder: string = text;
  while (remainder.length > 0) {
    const idx: number = remainder.indexOf(marker);
    if (idx < 0) {
      return '';
    }
    const closeRelative: number = remainder.substring(idx + 1).indexOf(']');
    if (closeRelative < 0) {
      return '';
    }
    const closeIndex: number = idx + 1 + closeRelative;
    const code: string = remainder.substring(idx + 1, closeIndex).toUpperCase();
    if (validDiagnosticCode(code) && !code.startsWith('E-RDP-STATE-') &&
      !code.startsWith('E-CONNECT-STATE-') && !code.startsWith('E-RDP-ERRINFO-') &&
      !code.startsWith('E-CONN-0X')) {
      return code;
    }
    remainder = remainder.substring(closeIndex + 1);
  }
  return '';
}

function extractServerErrorInfoCode(text: string): string {
  return extractHexCodeAfterMarker(text, 'E-RDP-ERRINFO-');
}

function extractFreeRdpConnectionCode(text: string): string {
  return extractHexCodeAfterMarker(text, 'E-CONN-');
}

export function normalizeRdpErrorCode(raw: string, fallback: string): string {
  const code: string = raw.length > 0 ? raw : fallback;
  if (code.length <= 2) {
    return fallback;
  }
  const upper: string = code.toUpperCase();
  if (!upper.startsWith('0X')) {
    return fallback;
  }
  let hex: string = upper.substring(2);
  while (hex.length > 1 && hex.charAt(0) === '0') {
    hex = hex.substring(1);
  }
  if (hex.length === 1) {
    hex = '0' + hex;
  }
  return '0x' + hex;
}

function normalizedNativeCode(raw: string, fallback: string): string {
  if (raw.length > 0) {
    return normalizeRdpErrorCode(raw, fallback);
  }
  return fallback;
}

/*
 * Do not scan arbitrary 0x values from the message. Certificate flags, selected
 * protocols and other diagnostics also use hexadecimal notation; treating the
 * first one as ErrorInfo is exactly how an unrelated failure can be mislabeled.
 */
function classifiedCode(message: string, fallback: string): string {
  const serverCode: string = extractServerErrorInfoCode(message);
  if (serverCode.length > 0) {
    return normalizedNativeCode(serverCode, fallback);
  }
  const connectionCode: string = extractFreeRdpConnectionCode(message);
  if (connectionCode.length > 0) {
    return normalizedNativeCode(connectionCode, fallback);
  }
  const diagnosticCode: string = extractNativeDiagnosticCode(message);
  return diagnosticCode.length > 0 ? diagnosticCode : fallback;
}

function hasServerErrorInfo(message: string): boolean {
  return extractServerErrorInfoCode(message).length > 0;
}

function modelForCode(code: string, source: RdpSessionErrorSource): RdpSessionErrorDialogModel {
  if (source === RdpSessionErrorSource.LOCAL_RENDER_WATCHDOG) {
    return {
      title: '画面正在恢复',
      message: '连接仍保持，检测到本地送显暂时受阻，系统正在重试。',
      code: 'RDP-LOCAL-RENDER-STALL',
      source
    };
  }
  switch (code) {
    case 'E-RDP-AUTH-CRYPTO-LOCKED':
      return {
        title: '无法读取本机凭据',
        message: '本机凭据存储已锁定，请先解锁后再连接 Restricted Admin 主机。',
        code,
        source
      };
    case 'E-RDP-AUTH-IDENTITY-MISMATCH':
      return {
        title: '需要重新输入 Hash',
        message: '主机地址、用户名或登录身份模式已改变，请重新输入该主机的 NTLM Hash。',
        code,
        source
      };
    case 'E-RDP-AUTH-SECRET-REQUIRED':
      return {
        title: '缺少 Restricted Admin Hash',
        message: '本机没有保存该主机的 NTLM Hash，请在主机编辑中重新输入。',
        code,
        source
      };
    case 'E-RDP-AUTH-HASH':
      return {
        title: 'Restricted Admin Hash 无效',
        message: 'NTLM Hash 无效或无法配置，请确认输入的是该 Windows 账户的 32 位 NTLM Hash。',
        code,
        source
      };
    case 'E-RDP-AUTH-CONFIG':
      return {
        title: 'RDP 认证配置无效',
        message: 'RDP 认证参数不完整或已过期，请重新选择认证方式后保存。',
        code,
        source
      };
    default:
      break;
  }
  if (source === RdpSessionErrorSource.CONNECT_FAILURE) {
    return {
      title: '你的会话已断开',
      message: '远程会话连接失败；没有收到服务器 ErrorInfo。',
      code,
      source
    };
  }
  if (source === RdpSessionErrorSource.TRANSPORT_FAILURE) {
    return {
      title: '你的会话已断开',
      message: 'RDP 连接在客户端或网络侧异常结束；没有收到服务器 ErrorInfo。',
      code,
      source
    };
  }
  switch (code) {
    case '0x10':
      return {
        title: '你的会话已断开',
        message: '远端 Windows 会话中的桌面窗口管理器（DWM）意外终止。',
        code,
        source
      };
    case '0xF':
    case '0x11':
    case '0x12':
      return {
        title: '你的会话已断开',
        message: '远程会话中的图形显示组件启动失败。',
        code,
        source
      };
    case '0x01':
      return {
        title: '服务器请求断开会话',
        message: '服务器请求结束当前会话（RPC initiated disconnect）；这不是图形管线故障。',
        code,
        source
      };
    case '0x112D':
      return {
        title: '你的会话已断开',
        message: '服务器不支持当前请求的图形模式。',
        code,
        source
      };
    case '0x112E':
      return {
        title: '你的会话已断开',
        message: '远程会话图形子系统重置失败。',
        code,
        source
      };
    case '0x112F':
      return {
        title: '你的会话已断开',
        message: '远程会话图形子系统出现错误，无法继续图形编码。',
        code,
        source
      };
    default:
      return {
        title: '你的会话已断开',
        message: '远程桌面会话被服务器断开。',
        code,
        source
      };
  }
}

export function rdpSessionErrorFromNativeMessage(message: string, fallbackCode: string,
  fallbackSource: RdpSessionErrorSource = RdpSessionErrorSource.CONNECT_FAILURE): RdpSessionErrorDialogModel {
  const code: string = classifiedCode(message, fallbackCode);
  const source: RdpSessionErrorSource = hasServerErrorInfo(message)
    ? RdpSessionErrorSource.SERVER_ERROR_INFO
    : fallbackSource;
  return modelForCode(code, source);
}

export function rdpNoFrameWatchdogError(): RdpSessionErrorDialogModel {
  return modelForCode('0x11', RdpSessionErrorSource.LOCAL_RENDER_WATCHDOG);
}

export function shouldCleanupRdpSessionBeforeErrorDismiss(): boolean {
  return false;
}

export function shouldShowRdpSessionErrorAfterControlPanelDismiss(controlPanelVisible: boolean): boolean {
  return controlPanelVisible;
}

export function rdpSessionErrorSheetPrefersLandscapeCenter(isRdpSession: boolean): boolean {
  return isRdpSession;
}
