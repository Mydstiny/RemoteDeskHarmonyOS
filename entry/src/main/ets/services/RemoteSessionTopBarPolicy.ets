import { RemoteSessionCapabilities, resolveSessionCapabilities } from './RemoteSessionCapabilityPolicy';

export type RemoteTopBarDeviceClass = 'pc' | 'pad' | 'phone';

/** Legacy preference retained for migration; connected session bars now stay reachable. */
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

/**
 * Shared collapsed edge-rail geometry and gesture thresholds.
 *
 * The visual handle stays deliberately narrow and translucent, while its
 * parent keeps a larger touch target.  This mirrors HarmonyOS edge affordances
 * without requesting the privileged SYSTEM_FLOAT_WINDOW capability.
 */
export const REMOTE_SESSION_COLLAPSED_RAIL_WIDTH: number = 22;
export const REMOTE_SESSION_COLLAPSED_RAIL_TOUCH_WIDTH: number = 40;
export const REMOTE_SESSION_COLLAPSED_RAIL_HEIGHT: number = 72;
export const REMOTE_SESSION_COLLAPSED_RAIL_BACKGROUND: string =
  'rgba(248,250,252,0.52)';
export const REMOTE_SESSION_COLLAPSED_RAIL_ICON: string =
  'rgba(36,40,48,0.72)';
export const REMOTE_SESSION_COLLAPSED_RAIL_BORDER: string =
  'rgba(255,255,255,0.48)';

export function remoteSessionRailDragOffset(offsetX: number): number {
  if (!Number.isFinite(offsetX) || offsetX <= 0) {
    return 0;
  }
  return Math.min(72, offsetX);
}

export function remoteSessionRailShouldCollapse(offsetX: number,
  velocityX: number): boolean {
  const safeOffset: number = Number.isFinite(offsetX) ? offsetX : 0;
  const safeVelocity: number = Number.isFinite(velocityX) ? velocityX : 0;
  return safeOffset >= 24 || safeVelocity >= 720;
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
  return protocol === 'rustdesk';
}

/** RDP and RustDesk share one persistent session toolbar shell. */
export function shouldShowRemoteSessionTopBar(protocol: string): boolean {
  return protocol === 'rdp' || protocol === 'rustdesk';
}

/** Keep the compatibility entrypoint aligned with the persistent mobile rail. */
export function shouldUseRustDeskEdgeRail(protocol: string, isDesktopDevice: boolean,
  breakpoint: string, rustdeskControlMode: number, isPadDevice: boolean): boolean {
  return protocol === 'rustdesk' && !isDesktopDevice;
}

/** Phone and Pad always use a right rail; PC always uses a top bar. */
export function shouldUseRemoteSessionEdgeRail(protocol: string,
  isDesktopDevice: boolean): boolean {
  return shouldShowRemoteSessionTopBar(protocol) && !isDesktopDevice;
}

export function remoteTopBarLayout(isDesktopDevice: boolean, breakpoint: string,
  isPadDevice: boolean): RemoteTopBarLayout {
  const deviceClass: RemoteTopBarDeviceClass = remoteTopBarDeviceClass(isDesktopDevice, breakpoint, isPadDevice);
  if (deviceClass === 'pc') {
    if (breakpoint !== 'xl') {
      return { deviceClass, iconSize: 36, itemGap: 4, topOffset: 6, maxVisibleButtons: 7, menuWidth: 320 };
    }
    return { deviceClass, iconSize: 44, itemGap: 8, topOffset: 8, maxVisibleButtons: 7, menuWidth: 360 };
  }
  if (deviceClass === 'pad') {
    return { deviceClass, iconSize: 44, itemGap: 8, topOffset: 8, maxVisibleButtons: 7, menuWidth: 340 };
  }
  return { deviceClass, iconSize: 40, itemGap: 6, topOffset: 6, maxVisibleButtons: 7, menuWidth: 300 };
}

export function remoteSessionActionAvailability(actionId: string, protocol: string,
  capabilities: RemoteSessionCapabilities): RemoteTopBarActionAvailability {
  if (protocol === 'rustdesk') {
    return rustDeskActionAvailability(actionId, capabilities);
  }
  if (protocol !== 'rdp') {
    return { enabled: false, reason: '当前协议不支持该会话工具栏操作' };
  }
  if (actionId === 'fileTransfer') { return capabilities.fileUpload; }
  if (actionId === 'toggleClipboard') { return capabilities.clipboardSend; }
  if (actionId === 'disconnect' || actionId === 'refreshFrame' ||
      actionId === 'ctrlAltDel' || actionId === 'toggleKeyboard' ||
      actionId === 'toggleModifiers' || actionId === 'displaySettings' ||
      actionId === 'keyboardMouseSettings') {
    return capabilities.connect;
  }
  return { enabled: false, reason: 'RDP 当前未提供该操作' };
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
    actionId === 'toggleKeyboard' || actionId === 'toggleModifiers' ||
    actionId === 'displaySettings' ||
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
