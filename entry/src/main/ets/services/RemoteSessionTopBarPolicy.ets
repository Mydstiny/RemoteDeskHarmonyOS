import { RemoteSessionCapabilities, resolveSessionCapabilities } from './RemoteSessionCapabilityPolicy';

export type RemoteTopBarDeviceClass = 'pc' | 'pad' | 'phone';

/** Device-local preference shared by the RustDesk and VNC PC session bars. */
export const PC_SESSION_TOP_BAR_HIDDEN_KEY: string = 'pcSessionTopBarHidden';

export type RemoteTopBarMenuId = 'control' | 'display' | 'keyboardMouse' | 'chat' | 'voice' | 'record';

export interface RemoteTopBarContext {
  protocol: string;
  isDesktopDevice: boolean;
  isPadDevice: boolean;
  breakpoint: string;
  rustdeskControlMode: number;
  physicalKeyboardMouseConnected: boolean;
}

export interface RemoteTopBarLayout {
  deviceClass: RemoteTopBarDeviceClass;
  iconSize: number;
  itemGap: number;
  topOffset: number;
  maxVisibleButtons: number;
  menuWidth: number;
}

export interface RemoteTopBarActionAvailability {
  enabled: boolean;
  reason: string;
}

const RUSTDESK_DISABLED_REASONS: Record<string, string> = {
  'screenshot': '截屏需要本地截图保存和权限链路接入后启用',
  'textChat': '文字聊天需要 RustDesk 会话消息通道接入后启用',
  'voiceCall': '语音通话需要 RustDesk 音频输入和通话信令接入后启用',
  'recordSession': '录制需要本地录屏/编码保存链路接入后启用',
  'resolutionSettings': '远端显示器能力尚未同步完成',
  'virtualDisplay': '虚拟显示器需要 RustDesk 虚拟显示控制协议接入后启用',
  'remoteCamera': '查看摄像头需要 RustDesk 摄像头流接入后启用',
  'terminal': '终端需要 RustDesk 远程 shell 能力接入后启用',
  'tcpTunnel': 'TCP 隧道需要 RustDesk tunnel 控制通道接入后启用',
  'lockRemote': '锁定远程电脑需要确认远端系统键码后启用',
  'reverseAccess': '反转访问方向需要 RustDesk 反向会话协议接入后启用',
  'blockRemoteInput': '阻止用户输入需要远端权限控制协议接入后启用',
  'restartRemote': '重启远程电脑需要远端系统命令协议接入后启用'
};

export function remoteTopBarDeviceClass(isDesktopDevice: boolean, _breakpoint: string,
  isPadDevice: boolean): RemoteTopBarDeviceClass {
  if (isDesktopDevice) {
    return 'pc';
  }
  if (isPadDevice) {
    return 'pad';
  }
  return 'phone';
}

export function shouldShowRustDeskTopBar(
  protocol: string,
  isDesktopDevice: boolean,
  breakpoint: string,
  rustdeskControlMode: number,
  physicalKeyboardMouseConnected: boolean,
  isPadDevice: boolean,
  pcSessionTopBarHidden: boolean = false
): boolean {
  if (protocol !== 'rustdesk') {
    return false;
  }
  if (isDesktopDevice) {
    return !pcSessionTopBarHidden;
  }
  const deviceClass: RemoteTopBarDeviceClass = remoteTopBarDeviceClass(isDesktopDevice, breakpoint, isPadDevice);
  if (deviceClass === 'pad') {
    return true;
  }
  // On a phone the rail is only useful when the session is in keyboard/mouse
  // mode and a real external input device is present. Touch and virtual
  // touchpad sessions must leave the remote canvas unobstructed.
  return rustdeskControlMode === 2 && physicalKeyboardMouseConnected;
}

/**
 * Keep Pad pointing modes on the same right-side rail so switching between
 * virtual touchpad and physical keyboard/mouse does not move session controls
 * across the remote canvas. Phones retain the compact rail only for physical
 * keyboard/mouse mode, where the top system-bar edge is most constrained.
 */
export function shouldUseRustDeskEdgeRail(protocol: string, isDesktopDevice: boolean,
  breakpoint: string, rustdeskControlMode: number, isPadDevice: boolean): boolean {
  if (protocol !== 'rustdesk' || isDesktopDevice) {
    return false;
  }
  const deviceClass: RemoteTopBarDeviceClass = remoteTopBarDeviceClass(isDesktopDevice, breakpoint, isPadDevice);
  if (deviceClass === 'pad') {
    return rustdeskControlMode === 0 || rustdeskControlMode === 2;
  }
  return deviceClass === 'phone' && rustdeskControlMode === 2;
}

export function remoteTopBarLayout(isDesktopDevice: boolean, breakpoint: string,
  isPadDevice: boolean): RemoteTopBarLayout {
  const deviceClass: RemoteTopBarDeviceClass = remoteTopBarDeviceClass(isDesktopDevice, breakpoint, isPadDevice);
  if (deviceClass === 'pc') {
    return { deviceClass, iconSize: 44, itemGap: 8, topOffset: 8, maxVisibleButtons: 8, menuWidth: 360 };
  }
  if (deviceClass === 'pad') {
    return { deviceClass, iconSize: 44, itemGap: 8, topOffset: 8, maxVisibleButtons: 6, menuWidth: 340 };
  }
  return { deviceClass, iconSize: 40, itemGap: 6, topOffset: 6, maxVisibleButtons: 5, menuWidth: 300 };
}

function knownRustDeskCapabilities(): RemoteSessionCapabilities {
  return resolveSessionCapabilities({
    protocol: 'rustdesk', connected: true, rdpDriveMounted: false, rdpClipboardEnabled: true,
    rdpClipboardReady: false, sftpConnected: false,
    rustDeskVerifiedPeer: true, rustDeskInboundClipboard: true, rustDeskTransferConfirmed: true,
    vncClipboardEnabled: false, vncClipboardReady: false, vncViewOnly: true
  });
}

export function rustDeskActionAvailability(actionId: string,
  capabilities: RemoteSessionCapabilities = knownRustDeskCapabilities()): RemoteTopBarActionAvailability {
  if (actionId === 'fileTransfer' || actionId === 'toggleFilePaste') {
    return capabilities.fileUpload;
  }
  if (actionId === 'toggleClipboard') {
    return capabilities.clipboardSend;
  }
  if (actionId === 'disconnect' || actionId === 'refreshFrame' || actionId === 'ctrlAltDel' ||
    actionId === 'toggleKeyboard' || actionId === 'displaySettings' ||
    actionId === 'rotateDisplay' ||
    actionId === 'keyboardMouseSettings' || actionId === 'browseMode' ||
    actionId === 'togglePrivacyMode' || actionId === 'toggleAudio') {
    return capabilities.connect;
  }
  if (actionId === 'resolutionSettings') {
    return capabilities.multiDisplay;
  }
  const reason: string = RUSTDESK_DISABLED_REASONS[actionId] ?? '当前版本尚未接入该 RustDesk 官方能力';
  return { enabled: false, reason };
}

export function rustDeskTopBarAutoCollapseDelayMs(pinned: boolean, menuOpen: boolean): number {
  if (pinned || menuOpen) {
    return 0;
  }
  return 5000;
}

export function protocolPreferenceOwner(key: string): string {
  if (key.startsWith('rustdesk')) {
    return 'rustdesk';
  }
  if (key.startsWith('rdp')) {
    return 'rdp';
  }
  return 'shared';
}
