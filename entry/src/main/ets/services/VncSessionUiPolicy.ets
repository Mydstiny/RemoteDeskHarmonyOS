import { VncDisplayScaleMode } from './VncModelPolicy';

export function shouldShowVncSessionToolbar(protocol: string, connected: boolean,
  sessionId: number): boolean {
  return protocol === 'vnc' && connected && sessionId > 0;
}

export function vncToolbarAutoCollapseDelayMs(connected: boolean,
  collapsed: boolean): number {
  return connected && !collapsed ? 20000 : 0;
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
