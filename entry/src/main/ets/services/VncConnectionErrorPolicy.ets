/**
 * Stable, user-facing diagnosis for the VNC native handshake failures.
 *
 * The native layer keeps the wire error precise but intentionally does not
 * know about macOS setup instructions.  This policy turns the supported
 * failure markers into actionable guidance without exposing credentials or
 * changing the error paths of RDP, RustDesk or SSH.
 */
export interface VncConnectionErrorDiagnosis {
  title: string;
  detail: string;
  code: string;
}

export function diagnoseVncConnectionError(nativeMessage: string): VncConnectionErrorDiagnosis {
  const message: string = nativeMessage.trim();
  if (message.indexOf('SSL routines::wrong version number') >= 0) {
    return {
      title: 'VNC TLS 配置不匹配',
      detail: '目标端口返回的是明文 RFB。Mac 屏幕共享测试请关闭主机 TLS，并选择“可信网络”；只有目标端确实提供 TLS 时才开启 TLS。',
      code: 'E-VNC-TLS-VERSION'
    };
  }
  if (message.indexOf('VNC security authentication failed') >= 0) {
    return {
      title: 'VNC 密码认证失败',
      detail: '服务器已返回 RFB 密码 challenge，但拒绝了当前密码。macOS 请在“系统设置 > 通用 > 共享 > 屏幕共享 > 信息”启用“VNC viewers may control screen with password”，并使用那里设置的独立 VNC 密码，不要使用 Mac 登录密码；传统 VNC 密码通常只取前 8 个 ASCII 字符。',
      code: 'E-VNC-AUTH-PASSWORD'
    };
  }
  if (message.indexOf('VNC password is required') >= 0) {
    return {
      title: 'VNC 未提供可用密码',
      detail: '服务器要求 VNC password。请在主机编辑页输入密码；编辑已有主机时，留空表示保留已保存密码，输入内容才会替换它。',
      code: 'E-VNC-AUTH-MISSING'
    };
  }
  return {
    title: 'VNC 连接失败',
    detail: message === '' ? 'VNC 服务器未返回可用诊断。' : message,
    code: 'E-VNC-CONNECTION'
  };
}
