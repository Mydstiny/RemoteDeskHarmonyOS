export interface SessionCapabilityState {
  protocol: 'rdp' | 'rustdesk' | 'ssh' | 'vnc' | string;
  connected: boolean;
  rdpDriveMounted: boolean;
  rdpClipboardReady: boolean;
  sftpConnected: boolean;
  rustDeskVerifiedPeer: boolean;
  rustDeskInboundClipboard: boolean;
  rustDeskTransferConfirmed: boolean;
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

export function resolveSessionCapabilities(state: SessionCapabilityState): RemoteSessionCapabilities {
  if (state.protocol === 'vnc') {
    const vncUnavailable = unavailable('当前版本尚未提供 VNC 连接支持');
    return {
      connect: vncUnavailable,
      clipboardSend: vncUnavailable,
      clipboardReceive: vncUnavailable,
      fileUpload: vncUnavailable,
      fileDownload: vncUnavailable,
      multiDisplay: vncUnavailable
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
    const inbound = state.rdpClipboardReady ? available() : unavailable('RDP 剪贴板通道尚未就绪');
    return {
      connect,
      clipboardSend: available(),
      clipboardReceive: inbound,
      fileUpload: drive,
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
    return {
      connect,
      clipboardSend: peer,
      clipboardReceive: inbound,
      fileUpload: transfer,
      fileDownload: unavailable('当前 RustDesk 会话未验证文件下载能力'),
      multiDisplay: unavailable('当前 RustDesk 会话未验证多显示器控制能力')
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
