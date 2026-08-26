import { VncDisplayScaleMode, VncLocalCursorMode } from './VncModelPolicy';

export type VncToolbarDeviceClass = 'pc' | 'pad' | 'phone';
export type VncToolbarOrientation = 'portrait' | 'landscape';
export type VncToolbarSide = 'left' | 'right';
export type VncToolbarPrimaryActionId = 'keyboard' | 'controlMode' | 'shortcuts' |
  'displayScale' | 'diagnostics' | 'disconnect';

const VNC_TOOLBAR_PRIMARY_ACTION_IDS: VncToolbarPrimaryActionId[] = [
  'keyboard', 'controlMode', 'shortcuts', 'displayScale', 'diagnostics', 'disconnect'
];

/** PC 顶栏和 Phone/Pad 侧栏必须消费完全相同、顺序一致的动作集合。 */
export function vncToolbarPrimaryActionIds(): VncToolbarPrimaryActionId[] {
  return VNC_TOOLBAR_PRIMARY_ACTION_IDS.slice();
}

/**
 * VNC 服务器若不下发 Cursor pseudo-encoding，光标通常已合成在帧缓冲中。
 * auto 模式此时隐藏本地系统光标，避免 UltraVNC 出现两层鼠标；一旦独立
 * 光标形状就绪，立即恢复并采用协议光标。显式 arrow/circle 始终保留本地光标。
 */
export function shouldHideVncSystemPointer(protocol: string, connected: boolean,
  keyboardMouseMode: boolean, surfaceHovered: boolean,
  localCursorMode: VncLocalCursorMode, nativeCursorReady: boolean): boolean {
  if (protocol !== 'vnc' || !connected || !keyboardMouseMode || !surfaceHovered) {
    return false;
  }
  if (localCursorMode === 'hidden') {
    return true;
  }
  return localCursorMode === 'auto' && !nativeCursorReady;
}

export function shouldShowVncSessionToolbar(protocol: string, connected: boolean,
  sessionId: number, isDesktopDevice: boolean = false,
  pcSessionTopBarHidden: boolean = false): boolean {
  return protocol === 'vnc' && connected && sessionId > 0;
}

export function vncToolbarAutoCollapseDelayMs(connected: boolean,
  collapsed: boolean): number {
  return connected && !collapsed ? 20000 : 0;
}

/** Mobile VNC uses a persistent right rail; PC uses the persistent top bar. */
export function vncToolbarRailWidth(deviceClass: VncToolbarDeviceClass,
  collapsed: boolean): number {
  if (deviceClass === 'pc') { return 0; }
  return collapsed ? 44 : 68;
}

export function vncToolbarRailHeight(deviceClass: VncToolbarDeviceClass,
  viewOnly: boolean, collapsed: boolean,
  availableHeight: number = Number.MAX_SAFE_INTEGER): number {
  if (deviceClass === 'pc') { return 0; }
  const normalizedAvailable: number = Number.isFinite(availableHeight) && availableHeight > 0 ?
    availableHeight : Number.MAX_SAFE_INTEGER;
  if (collapsed) { return Math.max(44, Math.min(72, normalizedAvailable)); }
  const actionCount: number = vncToolbarPrimaryActionIds().length;
  const actionHeight: number = actionCount * 44;
  const actionGaps: number = Math.max(0, actionCount - 1) * 5;
  const collapseHandleHeight: number = 44;
  const collapseHandleGap: number = 5;
  const viewOnlyHeader: number = viewOnly ? 24 + 5 : 0;
  const naturalHeight: number = 12 + collapseHandleHeight + collapseHandleGap +
    actionHeight + actionGaps + viewOnlyHeader;
  return Math.max(44, Math.min(naturalHeight, normalizedAvailable));
}

export function vncToolbarDefaultSide(_deviceClass: VncToolbarDeviceClass): VncToolbarSide {
  return 'right';
}

export function vncToolbarPositionPreferenceKey(deviceClass: VncToolbarDeviceClass,
  orientation: VncToolbarOrientation, field: 'side' | 'yRatio'): string {
  return 'vncSessionToolbar:' + deviceClass + ':' + orientation + ':' + field;
}

export function nextVncControlMode(current: number, viewOnly: boolean): number {
  if (viewOnly) {
    return Math.max(0, Math.min(2, Math.floor(current)));
  }
  const normalized: number = Math.max(0, Math.min(2, Math.floor(current)));
  return normalized >= 2 ? 0 : normalized + 1;
}

export function nextVncDisplayScaleMode(current: VncDisplayScaleMode): VncDisplayScaleMode {
  if (current === 'fit') { return '100'; }
  if (current === '100') { return 'integer'; }
  return 'fit';
}
