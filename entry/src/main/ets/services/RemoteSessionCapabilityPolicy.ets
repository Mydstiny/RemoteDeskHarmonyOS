export interface SessionCapabilityState {
  protocol: 'rdp' | 'rustdesk' | 'ssh' | 'vnc' | 'moonlight' | string;
  connected: boolean;
  rdpDriveMounted: boolean;
  rdpClipboardEnabled: boolean;
  rdpClipboardReady: boolean;
  sftpConnected: boolean;
  rustDeskVerifiedPeer: boolean;
  rustDeskInboundClipboard: boolean;
  rustDeskTransferConfirmed: boolean;
  rustDeskDisplaySupported?: boolean;
  vncClipboardEnabled: boolean;
  vncClipboardReady: boolean;
  vncViewOnly: boolean;
  moonlightRuntimeAvailable?: boolean;
  moonlightHostControlReady?: boolean;
}

export interface CapabilityAvailability {
  enabled: boolean;
  reason: string;
}

export interface RemoteSessionCapabilities {
  connect: CapabilityAvailability;
  clipboardSend: CapabilityAvailability;
  clipboardReceive: CapabilityAvailability;
  fileUpload: CapabilityAvailability;
  fileDownload: CapabilityAvailability;
  multiDisplay: CapabilityAvailability;
}

function available(): CapabilityAvailability {
  return { enabled: true, reason: '' };
}

function unavailable(reason: string): CapabilityAvailability {
  return { enabled: false, reason };
}

function disconnected(): CapabilityAvailability {
  return unavailable('远程会话尚未连接');
}

function unsupported(protocol: string): CapabilityAvailability {
  return unavailable('当前版本尚未提供 ' + protocol.toUpperCase() + ' 会话能力');
}

function moonlightConnectAvailability(state: SessionCapabilityState): CapabilityAvailability {
  if (state.moonlightRuntimeAvailable !== true) {
    return unavailable('Moonlight 串流运行时尚未开放');
  }
  if (state.moonlightHostControlReady !== true) {
    return unavailable('Moonlight Host Control 尚未就绪');
  }
  return available();
}

export function resolveSessionCapabilities(state: SessionCapabilityState): RemoteSessionCapabilities {
  if (state.protocol === 'vnc') {
    const vncSend = !state.connected
      ? disconnected()
      : state.vncViewOnly
        ? unavailable('VNC 当前会话为只读连接')
        : state.vncClipboardEnabled
          ? available() : unavailable('VNC 文本剪贴板未在 VNC 设置中开启');
    const vncReceive = !state.connected
      ? disconnected()
      : !state.vncClipboardEnabled
        ? unavailable('VNC 文本剪贴板未在 VNC 设置中开启')
        : state.vncClipboardReady
          ? available() : unavailable('VNC 尚未收到远端 ServerCutText');
    return {
      connect: available(),
      clipboardSend: vncSend,
      clipboardReceive: vncReceive,
      fileUpload: unavailable('VNC RFB 不提供文件传输能力'),
      fileDownload: unavailable('VNC RFB 不提供文件传输能力'),
      multiDisplay: unavailable('当前 VNC 会话仅支持单帧缓冲区')
    };
  }

  if (state.protocol === 'moonlight') {
    const connect = moonlightConnectAvailability(state);
    const unsupportedMoonlight = unavailable('Moonlight 不提供此通用远程桌面能力');
    return {
      connect: connect,
      clipboardSend: unsupportedMoonlight,
      clipboardReceive: unsupportedMoonlight,
      fileUpload: unsupportedMoonlight,
      fileDownload: unsupportedMoonlight,
      multiDisplay: unavailable('Moonlight 当前只提供单路串流画面')
    };
  }

  const connect = state.protocol === 'rdp' || state.protocol === 'rustdesk' || state.protocol === 'ssh'
    ? available()
    : unsupported(state.protocol);
  if (!state.connected) {
    return {
      connect,
      clipboardSend: disconnected(),
      clipboardReceive: disconnected(),
      fileUpload: disconnected(),
      fileDownload: disconnected(),
      multiDisplay: disconnected()
    };
  }

  if (state.protocol === 'rdp') {
    const drive = state.rdpDriveMounted ? available() : unavailable('RDP 共享盘尚未挂载');
    const clipboardDisabled = unavailable('RDP 文本剪贴板未在 RDP 设置中开启');
    const inbound = !state.rdpClipboardEnabled
      ? clipboardDisabled
      : state.rdpClipboardReady ? available() : unavailable('RDP 剪贴板通道尚未就绪');
    return {
      connect,
      // Sending is not a local-only operation: FreeRDP must have negotiated
      // cliprdr for the current session. Keep the capability truthful when a
      // user enables the preference after connecting with the channel off.
      clipboardSend: !state.rdpClipboardEnabled
        ? clipboardDisabled
        : state.rdpClipboardReady ? available() : unavailable('RDP 剪贴板通道尚未就绪'),
      clipboardReceive: inbound,
      fileUpload: !state.rdpClipboardEnabled
        ? clipboardDisabled
        : state.rdpClipboardReady ? available() : unavailable('RDP 文件剪贴板通道尚未就绪'),
      fileDownload: drive,
      multiDisplay: unavailable('当前 RDP 渲染仅支持单显示器')
    };
  }

  if (state.protocol === 'ssh') {
    const sftp = state.sftpConnected ? available() : unavailable('SFTP 通道尚未连接');
    return {
      connect,
      clipboardSend: unavailable('SSH 会话暂不支持远程剪贴板同步'),
      clipboardReceive: unavailable('SSH 会话暂不支持远程剪贴板同步'),
      fileUpload: sftp,
      fileDownload: sftp,
      multiDisplay: unavailable('SSH 终端不支持多显示器')
    };
  }

  if (state.protocol === 'rustdesk') {
    const peer = state.rustDeskVerifiedPeer ? available() : unavailable('RustDesk 远端尚未完成可信会话验证');
    const inbound = state.rustDeskVerifiedPeer && state.rustDeskInboundClipboard
      ? available()
      : unavailable('RustDesk 入站纯文本剪贴板尚未验证');
    const transfer = state.rustDeskVerifiedPeer && state.rustDeskTransferConfirmed
      ? available()
      : unavailable('RustDesk 文件传输尚未获得远端确认');
    const display = state.rustDeskDisplaySupported === true
      ? available() : unavailable('当前 RustDesk 会话尚未提供显示器能力');
    return {
      connect,
      clipboardSend: peer,
      clipboardReceive: inbound,
      fileUpload: transfer,
      fileDownload: unavailable('当前 RustDesk 会话未验证文件下载能力'),
      multiDisplay: display
    };
  }

  const unknown = unsupported(state.protocol);
  return {
    connect: unknown,
    clipboardSend: unknown,
    clipboardReceive: unknown,
    fileUpload: unknown,
    fileDownload: unknown,
    multiDisplay: unknown
  };
}
