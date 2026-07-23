export enum RdpSessionErrorSource {
  SERVER_ERROR_INFO = 'server-error-info',
  LOCAL_RENDER_WATCHDOG = 'local-render-watchdog',
  CONNECT_FAILURE = 'connect-failure'
}

export interface RdpSessionErrorDialogModel {
  title: string;
  message: string;
  code: string;
  source: RdpSessionErrorSource;
}

function extractFirstHexCode(text: string): string {
  const marker: string = '0x';
  const idx: number = text.indexOf(marker);
  if (idx < 0) {
    return '';
  }
  let code: string = marker;
  for (let i = idx + 2; i < text.length; i++) {
    const ch: string = text.charAt(i);
    const isHex: boolean = (ch >= '0' && ch <= '9') ||
      (ch >= 'a' && ch <= 'f') || (ch >= 'A' && ch <= 'F');
    if (!isHex) {
      break;
    }
    code += ch;
  }
  return code.length > 2 ? code : '';
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
  return '0x' + hex;
}

function modelForCode(code: string, source: RdpSessionErrorSource): RdpSessionErrorDialogModel {
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
      message: '远程会话连接失败。',
      code,
      source
    };
  }
  switch (code) {
    case '0xF':
    case '0x10':
    case '0x11':
    case '0x12':
      return {
        title: '你的会话已断开',
        message: '远程会话中的图形显示组件启动失败。',
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

function extractRdpAuthErrorCode(text: string): string {
  const codes: string[] = [
    'E-RDP-AUTH-CRYPTO-LOCKED',
    'E-RDP-AUTH-IDENTITY-MISMATCH',
    'E-RDP-AUTH-SECRET-REQUIRED',
    'E-RDP-AUTH-HASH',
    'E-RDP-AUTH-CONFIG'
  ];
  for (let i = 0; i < codes.length; i++) {
    if (text.indexOf(codes[i]) >= 0) {
      return codes[i];
    }
  }
  return '';
}

export function rdpSessionErrorFromNativeMessage(message: string, fallbackCode: string): RdpSessionErrorDialogModel {
  const authCode: string = extractRdpAuthErrorCode(message);
  const code: string = authCode !== '' ? authCode : normalizeRdpErrorCode(extractFirstHexCode(message), fallbackCode);
  const source: RdpSessionErrorSource = message.indexOf('E-RDP-ERRINFO-0x') >= 0
    ? RdpSessionErrorSource.SERVER_ERROR_INFO
    : RdpSessionErrorSource.CONNECT_FAILURE;
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
