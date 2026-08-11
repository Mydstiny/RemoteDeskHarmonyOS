export const HOST_PROTOCOL_COMING_SOON_LABEL: string = '即将支持';
export type MoonlightPickerIconMode = 'brand' | 'system-fallback';

export interface HostProtocolPickerOptionState {
  protocol: string;
  enabled: boolean;
  statusLabel: string;
  opacity: number;
}

/**
 * Keeps Moonlight fail-closed while preserving the same option-card contract
 * used by the enabled RustDesk entry.
 */
export function resolveHostProtocolPickerOption(
  protocol: string,
  moonlightProtocolAvailable: boolean
): HostProtocolPickerOptionState {
  const enabled: boolean = protocol !== 'moonlight' || moonlightProtocolAvailable;
  return {
    protocol: protocol,
    enabled: enabled,
    statusLabel: enabled ? '' : HOST_PROTOCOL_COMING_SOON_LABEL,
    opacity: enabled ? 1 : 0.58
  };
}

/** Returns an empty route for disabled cards so taps have no side effect. */
export function selectedHostProtocolRoute(state: HostProtocolPickerOptionState): string {
  return state.enabled ? state.protocol : '';
}

/** Centralizes callback dispatch so a disabled card cannot call the Sheet owner. */
export function dispatchSelectedHostProtocol(
  state: HostProtocolPickerOptionState,
  onSelect: (protocol: string) => void
): void {
  const route: string = selectedHostProtocolRoute(state);
  if (route !== '') {
    onSelect(route);
  }
}

export function resolveMoonlightPickerIconMode(loadFailed: boolean): MoonlightPickerIconMode {
  return loadFailed ? 'system-fallback' : 'brand';
}

export function resolveHostProtocolPickerIconTint(
  enabled: boolean,
  accentColor: string,
  disabledColor: string
): string {
  return enabled ? accentColor : disabledColor;
}
