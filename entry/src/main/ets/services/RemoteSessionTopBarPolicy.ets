import { RemoteSessionCapabilities, resolveSessionCapabilities } from './RemoteSessionCapabilityPolicy';

export type RemoteTopBarDeviceClass = 'pc' | 'pad' | 'phone';

/** Legacy PC-only preference retained for compatibility; new code uses protocol keys below. */
export const PC_SESSION_TOP_BAR_HIDDEN_KEY: string = 'pcSessionTopBarHidden';

export const REMOTE_SESSION_CONTROL_BAR_HIDDEN_RDP_KEY: string =
  'remoteSessionControlBarHiddenRdp';
export const REMOTE_SESSION_CONTROL_BAR_HIDDEN_RUSTDESK_KEY: string =
  'remoteSessionControlBarHiddenRustDesk';
export const REMOTE_SESSION_CONTROL_BAR_HIDDEN_VNC_KEY: string =
  'remoteSessionControlBarHiddenVnc';
export const REMOTE_SESSION_CONTROL_BAR_HIDDEN_MOONLIGHT_KEY: string =
  'remoteSessionControlBarHiddenMoonlight';

export interface RemoteSessionControlBarVisibility {
  rdpHidden: boolean;
  rustDeskHidden: boolean;
  vncHidden: boolean;
  moonlightHidden: boolean;
}

export interface RemoteSessionControlBarPreferencePresence {
  rustDeskPresent: boolean;
  vncPresent: boolean;
}

export type RemoteTopBarMenuId = 'control' | 'display' | 'keyboardMouse' | 'chat' | 'voice' | 'record';

export type RemoteSessionPrimaryActionId = 'pin' | 'control' | 'display' |
  'keyboardMouse' | 'keyboard' | 'fileTransfer' | 'diagnostics' | 'disconnect';

export type RemoteKeyboardSidebarAction = 'choose' | 'close';

const RUSTDESK_PRIMARY_ACTION_IDS: RemoteSessionPrimaryActionId[] = [
  'pin', 'control', 'display', 'keyboardMouse', 'keyboard',
  'fileTransfer', 'diagnostics', 'disconnect'
];

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
/** PC equivalent of the right-edge affordance, rotated onto the top edge. */
export const REMOTE_SESSION_COLLAPSED_TOP_WIDTH: number = 72;
export const REMOTE_SESSION_COLLAPSED_TOP_TOUCH_HEIGHT: number = 40;
export const REMOTE_SESSION_COLLAPSED_TOP_HEIGHT: number = 22;

export function remoteSessionControlBarHidden(protocol: string,
  visibility: RemoteSessionControlBarVisibility): boolean {
  if (protocol === 'rdp') { return visibility.rdpHidden; }
  if (protocol === 'rustdesk') { return visibility.rustDeskHidden; }
  if (protocol === 'vnc') { return visibility.vncHidden; }
  if (protocol === 'moonlight') { return visibility.moonlightHidden; }
  return false;
}

export function shouldDismissRemoteSessionControlSheet(
  controlBarHidden: boolean,
  sheetVisible: boolean,
  sheetMode: string
): boolean {
  return controlBarHidden && sheetVisible && sheetMode === 'control';
}

export function remoteSessionControlBarSelectionSummary(
  visibility: RemoteSessionControlBarVisibility): string {
  const hiddenLabels: string[] = [];
  if (visibility.rdpHidden) { hiddenLabels.push('RDP'); }
  if (visibility.rustDeskHidden) { hiddenLabels.push('RustDesk'); }
  if (visibility.vncHidden) { hiddenLabels.push('VNC'); }
  if (visibility.moonlightHidden) { hiddenLabels.push('Moonlight'); }
  return hiddenLabels.length === 0 ? '全部显示' : '已隐藏：' + hiddenLabels.join('、');
}

export function resolveRemoteSessionControlBarVisibility(
  stored: RemoteSessionControlBarVisibility,
  presence: RemoteSessionControlBarPreferencePresence,
  legacyPcHidden: boolean): RemoteSessionControlBarVisibility {
  return {
    rdpHidden: stored.rdpHidden,
    rustDeskHidden: presence.rustDeskPresent ? stored.rustDeskHidden : legacyPcHidden,
    vncHidden: presence.vncPresent ? stored.vncHidden : legacyPcHidden,
    moonlightHidden: stored.moonlightHidden
  };
}

export function remoteSessionRailDragOffset(offsetX: number): number {
  if (!Number.isFinite(offsetX) || offsetX <= 0) {
    return 0;
  }
  // Keep enough of every edge rail visible while previewing the collapse
  // gesture.  The previous 72vp cap could translate a phone rail completely
  // outside its parent before the gesture ended.
  return Math.min(28, offsetX);
}

export function remoteSessionRailShouldCollapse(offsetX: number,
  velocityX: number): boolean {
  const safeOffset: number = Number.isFinite(offsetX) ? offsetX : 0;
  const safeVelocity: number = Number.isFinite(velocityX) ? velocityX : 0;
  return safeOffset >= 24 || safeVelocity >= 720;
}

/**
 * The system IME and the unified shortcut panel are one user-facing keyboard
 * surface.  Protocol pages still keep separate ArkUI state for those owners,
 * so the toolbar must fold every legacy flag before deciding whether its
 * keyboard affordance opens the chooser or closes the active surface.
 */
export function remoteKeyboardSurfaceOpen(
  virtualKeyboardOpen: boolean,
  modifierPanelOpen: boolean,
  shortcutPanelOpen: boolean = false
): boolean {
  return virtualKeyboardOpen || modifierPanelOpen || shortcutPanelOpen;
}

export function remoteKeyboardSidebarAction(
  virtualKeyboardOpen: boolean,
  modifierPanelOpen: boolean,
  shortcutPanelOpen: boolean = false
): RemoteKeyboardSidebarAction {
  return remoteKeyboardSurfaceOpen(
    virtualKeyboardOpen, modifierPanelOpen, shortcutPanelOpen) ? 'close' : 'choose';
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

/** RustDesk retains its protocol-owned persistent toolbar shell. */
export function shouldShowRemoteSessionTopBar(protocol: string): boolean {
  return protocol === 'rustdesk';
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

/** PC top bar and Phone/Pad edge rail consume this exact ordered action set. */
export function remoteSessionPrimaryActionIds(protocol: string): RemoteSessionPrimaryActionId[] {
  return protocol === 'rustdesk' ? RUSTDESK_PRIMARY_ACTION_IDS.slice() : [];
}

export function remoteTopBarLayout(isDesktopDevice: boolean, breakpoint: string,
  isPadDevice: boolean): RemoteTopBarLayout {
  const deviceClass: RemoteTopBarDeviceClass = remoteTopBarDeviceClass(isDesktopDevice, breakpoint, isPadDevice);
  if (deviceClass === 'pc') {
    if (breakpoint !== 'xl') {
      return { deviceClass, iconSize: 36, itemGap: 4, topOffset: 0, maxVisibleButtons: 8, menuWidth: 320 };
    }
    return { deviceClass, iconSize: 44, itemGap: 8, topOffset: 0, maxVisibleButtons: 8, menuWidth: 360 };
  }
  if (deviceClass === 'pad') {
    return { deviceClass, iconSize: 44, itemGap: 8, topOffset: 8, maxVisibleButtons: 8, menuWidth: 340 };
  }
  return { deviceClass, iconSize: 40, itemGap: 6, topOffset: 6, maxVisibleButtons: 8, menuWidth: 300 };
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
  if (actionId === 'diagnostics') {
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
