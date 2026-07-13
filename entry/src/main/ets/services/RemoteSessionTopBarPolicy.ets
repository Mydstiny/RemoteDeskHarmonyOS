import { RemoteSessionCapabilities, resolveSessionCapabilities } from './RemoteSessionCapabilityPolicy';

export type RemoteTopBarDeviceClass = 'pc' | 'pad' | 'phone';

export type RemoteTopBarMenuId = 'control' | 'display' | 'keyboardMouse' | 'chat' | 'voice' | 'record';

export interface RemoteTopBarContext {
  protocol: string;
  isDesktopDevice: boolean;
  breakpoint: string;
  rustdeskControlMode: number;
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
  'resolutionSettings': '分辨率切换需要 RustDesk 显示枚举和 resize 协议接入后启用',
  'virtualDisplay': '虚拟显示器需要 RustDesk 虚拟显示控制协议接入后启用',
  'remoteCamera': '查看摄像头需要 RustDesk 摄像头流接入后启用',
  'terminal': '终端需要 RustDesk 远程 shell 能力接入后启用',
  'tcpTunnel': 'TCP 隧道需要 RustDesk tunnel 控制通道接入后启用',
  'lockRemote': '锁定远程电脑需要确认远端系统键码后启用',
  'reverseAccess': '反转访问方向需要 RustDesk 反向会话协议接入后启用',
  'blockRemoteInput': '阻止用户输入需要远端权限控制协议接入后启用',
  'restartRemote': '重启远程电脑需要远端系统命令协议接入后启用'
};

export function remoteTopBarDeviceClass(isDesktopDevice: boolean, breakpoint: string): RemoteTopBarDeviceClass {
  if (isDesktopDevice) {
    return 'pc';
  }
  if (breakpoint === 'md' || breakpoint === 'lg' || breakpoint === 'xl') {
    return 'pad';
  }
  return 'phone';
}

export function shouldShowRustDeskTopBar(
  protocol: string,
  isDesktopDevice: boolean,
  _breakpoint: string,
  rustdeskControlMode: number
): boolean {
  if (protocol !== 'rustdesk') {
    return false;
  }
  if (isDesktopDevice) {
    return true;
  }
  return rustdeskControlMode === 2;
}

export function remoteTopBarLayout(isDesktopDevice: boolean, breakpoint: string): RemoteTopBarLayout {
  const deviceClass: RemoteTopBarDeviceClass = remoteTopBarDeviceClass(isDesktopDevice, breakpoint);
  if (deviceClass === 'pc') {
    return { deviceClass, iconSize: 44, itemGap: 8, topOffset: 8, maxVisibleButtons: 7, menuWidth: 360 };
  }
  if (deviceClass === 'pad') {
    return { deviceClass, iconSize: 44, itemGap: 8, topOffset: 8, maxVisibleButtons: 6, menuWidth: 340 };
  }
  return { deviceClass, iconSize: 40, itemGap: 6, topOffset: 6, maxVisibleButtons: 5, menuWidth: 300 };
}

function knownRustDeskCapabilities(): RemoteSessionCapabilities {
  return resolveSessionCapabilities({
    protocol: 'rustdesk', connected: true, rdpDriveMounted: false, rdpClipboardReady: false, sftpConnected: false,
    rustDeskVerifiedPeer: true, rustDeskInboundClipboard: true, rustDeskTransferConfirmed: true
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
    actionId === 'keyboardMouseSettings' || actionId === 'browseMode' ||
    actionId === 'togglePrivacyMode' || actionId === 'toggleAudio') {
    return capabilities.connect;
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
