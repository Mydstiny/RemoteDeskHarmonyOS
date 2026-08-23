import { VncDisplayScaleMode } from './VncModelPolicy';

export type VncToolbarDeviceClass = 'pc' | 'pad' | 'phone';
export type VncToolbarOrientation = 'portrait' | 'landscape';
export type VncToolbarSide = 'left' | 'right';

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
  viewOnly: boolean, collapsed: boolean): number {
  if (deviceClass === 'pc') { return 0; }
  if (collapsed) { return 72; }
  const actionCount: number = 6;
  const actionHeight: number = actionCount * 44;
  const actionGaps: number = Math.max(0, actionCount - 1) * 5;
  const collapseHandleHeight: number = 44;
  const collapseHandleGap: number = 5;
  const viewOnlyHeader: number = viewOnly ? 24 + 5 : 0;
  return 12 + collapseHandleHeight + collapseHandleGap + actionHeight + actionGaps + viewOnlyHeader;
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
