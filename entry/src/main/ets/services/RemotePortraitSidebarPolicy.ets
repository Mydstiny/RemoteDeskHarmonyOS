import {
  remotePortraitDisplayActionLabel,
  remotePortraitDisplayActionVisible,
  remotePortraitDisplayActive,
  RemotePortraitDisplayPreferences,
  RemotePortraitProtocol
} from './RemotePortraitDisplayPreferencePolicy';

export type RemotePortraitSidebarSide = 'right';
export type RemotePortraitSidebarHeightMode = 'auto' | 'compact' | 'standard' | 'tall';

export const REMOTE_PORTRAIT_SIDEBAR_HEIGHT_MODE_KEY: string =
  'remotePortraitSidebarHeightMode';

const REMOTE_PORTRAIT_SIDEBAR_MIN_HEIGHT: number = 68;

export function normalizeRemotePortraitSidebarHeightMode(
  value: string
): RemotePortraitSidebarHeightMode {
  if (value === 'compact' || value === 'standard' || value === 'tall') {
    return value;
  }
  return 'auto';
}

export function remotePortraitSidebarHeightModes(): Array<RemotePortraitSidebarHeightMode> {
  return ['auto', 'compact', 'standard', 'tall'];
}

export function remotePortraitSidebarHeightLabel(
  mode: RemotePortraitSidebarHeightMode
): string {
  if (mode === 'compact') { return '紧凑'; }
  if (mode === 'standard') { return '标准'; }
  if (mode === 'tall') { return '高'; }
  return '自动';
}

/**
 * Resolve one bounded rail height. `naturalHeight` is used by Auto so the
 * existing protocol rail keeps its content-sized behavior. The other modes
 * give the user a predictable share of the currently available safe-area
 * height; this is a visual viewport choice and never changes remote pixels.
 */
export function remotePortraitSidebarHeightPx(
  mode: RemotePortraitSidebarHeightMode,
  availableHeight: number,
  naturalHeight: number
): number {
  const available: number = Math.max(0, Number.isFinite(availableHeight) ? availableHeight : 0);
  if (available <= 0) { return 0; }
  const natural: number = Math.max(0,
    Number.isFinite(naturalHeight) ? Math.min(naturalHeight, available) : available);
  if (mode === 'auto') {
    return Math.max(Math.min(REMOTE_PORTRAIT_SIDEBAR_MIN_HEIGHT, available), natural);
  }
  const ratio: number = mode === 'compact' ? 0.45 : mode === 'tall' ? 0.85 : 0.65;
  return Math.max(Math.min(REMOTE_PORTRAIT_SIDEBAR_MIN_HEIGHT, available),
    Math.min(available, available * ratio));
}

export interface RemotePortraitSidebarPlacement {
  visible: boolean;
  active: boolean;
  side: RemotePortraitSidebarSide;
  safeAreaAware: boolean;
  actionId: string;
  actionLabel: string;
  layoutKey: string;
}

/**
 * The portrait action is part of the protocol-owned mobile rail. Desktop and
 * Pad keep their existing toolbar contracts; phone rails consume the same
 * right-edge safe-area placement so the action does not cover remote input.
 */
export function remotePortraitSidebarPlacement(
  values: RemotePortraitDisplayPreferences,
  protocol: string,
  isDesktopDevice: boolean,
  isPadDevice: boolean
): RemotePortraitSidebarPlacement {
  const visible: boolean = remotePortraitDisplayActionVisible(
    values, protocol, isDesktopDevice, isPadDevice);
  const active: boolean = remotePortraitDisplayActive(
    values, protocol, isDesktopDevice, isPadDevice);
  const normalized: string = visible &&
    (protocol === 'rdp' || protocol === 'rustdesk' || protocol === 'vnc' || protocol === 'moonlight') ?
    protocol : 'none';
  return {
    visible,
    active,
    side: 'right',
    safeAreaAware: true,
    actionId: visible ? 'remote-portrait-display' : '',
    actionLabel: visible ? remotePortraitDisplayActionLabel(active) : '',
    layoutKey: 'remote-portrait-sidebar:' + normalized + ':' + (active ? 'portrait' : 'default')
  };
}

export function remotePortraitSidebarProtocol(value: string): RemotePortraitProtocol | null {
  if (value === 'rdp' || value === 'rustdesk' || value === 'vnc' || value === 'moonlight') {
    return value;
  }
  return null;
}
