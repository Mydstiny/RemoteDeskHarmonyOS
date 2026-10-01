import {
  remotePortraitDisplayActionLabel,
  remotePortraitDisplayActionVisible,
  remotePortraitDisplayActive,
  RemotePortraitDisplayPreferences,
  RemotePortraitProtocol
} from './RemotePortraitDisplayPreferencePolicy';

export type RemotePortraitSidebarSide = 'right';

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
