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

export function rdpSessionErrorFromNativeMessage(message: string, fallbackCode: string): RdpSessionErrorDialogModel {
  const code: string = normalizeRdpErrorCode(extractFirstHexCode(message), fallbackCode);
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
