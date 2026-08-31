export const HOST_PROTOCOL_COMING_SOON_LABEL: string = '即将支持';
export type MoonlightPickerIconMode = 'brand' | 'system-fallback';

export interface HostProtocolPickerOptionState {
  protocol: string;
  enabled: boolean;
  routeEnabled: boolean;
  runtimeAvailable: boolean;
  shellOnly: boolean;
  statusLabel: string;
  opacity: number;
}

/** Keeps the option-card contract shared with RustDesk while separating the
 * add-flow entry from native pairing and streaming readiness.
 */
export function resolveHostProtocolPickerOption(
  protocol: string,
  moonlightProtocolAvailable: boolean,
  moonlightFabEntryAvailable: boolean = false
): HostProtocolPickerOptionState {
  const runtimeAvailable: boolean = protocol !== 'moonlight' || moonlightProtocolAvailable;
  const routeEnabled: boolean = runtimeAvailable ||
    (protocol === 'moonlight' && moonlightFabEntryAvailable);
  // Shell admission only opens the add flow. Pairing and streaming continue
  // to use their independent native capability checks.
  const shellOnly: boolean = protocol === 'moonlight' && routeEnabled && !runtimeAvailable;
  return {
    protocol: protocol,
    enabled: routeEnabled,
    routeEnabled: routeEnabled,
    runtimeAvailable: runtimeAvailable,
    shellOnly: shellOnly,
    statusLabel: shellOnly ? '仅添加' : (routeEnabled ? '' : HOST_PROTOCOL_COMING_SOON_LABEL),
    opacity: routeEnabled ? 1 : 0.58
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
