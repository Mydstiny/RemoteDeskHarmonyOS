export type RemotePortraitProtocol = 'rdp' | 'rustdesk' | 'vnc' | 'moonlight';
export type RemotePortraitDisplayMode = 'default' | 'portrait';

export const REMOTE_PORTRAIT_DISPLAY_PREFERENCE_VERSION: number = 1;
export const REMOTE_PORTRAIT_DISPLAY_PREFERENCE_VERSION_KEY: string =
  'remotePortraitDisplayPreferenceVersion';
export const REMOTE_PORTRAIT_DISPLAY_REVISION_KEY: string =
  'remotePortraitDisplayRevision';
export const REMOTE_PORTRAIT_DISPLAY_ENCODED_KEY: string = 'remotePortraitDisplayEncoded';

export const RDP_PORTRAIT_DISPLAY_ENABLED_KEY: string = 'rdpPortraitDisplayEnabled';
export const RDP_PORTRAIT_DISPLAY_MODE_KEY: string = 'rdpPortraitDisplayMode';
export const RUSTDESK_PORTRAIT_DISPLAY_ENABLED_KEY: string =
  'rustdeskPortraitDisplayEnabled';
export const RUSTDESK_PORTRAIT_DISPLAY_MODE_KEY: string =
  'rustdeskPortraitDisplayMode';
export const VNC_PORTRAIT_DISPLAY_ENABLED_KEY: string = 'vncPortraitDisplayEnabled';
export const VNC_PORTRAIT_DISPLAY_MODE_KEY: string = 'vncPortraitDisplayMode';
export const MOONLIGHT_PORTRAIT_DISPLAY_ENABLED_KEY: string =
  'moonlightPortraitDisplayEnabled';
export const MOONLIGHT_PORTRAIT_DISPLAY_MODE_KEY: string =
  'moonlightPortraitDisplayMode';

export interface RemotePortraitProtocolPreference {
  enabled: boolean;
  mode: RemotePortraitDisplayMode;
}

export interface RemotePortraitDisplayPreferences {
  rdp: RemotePortraitProtocolPreference;
  rustdesk: RemotePortraitProtocolPreference;
  vnc: RemotePortraitProtocolPreference;
  moonlight: RemotePortraitProtocolPreference;
}

export interface RemotePortraitDisplayPreferencePresence {
  rdpEnabled: boolean;
  rdpMode: boolean;
  rustdeskEnabled: boolean;
  rustdeskMode: boolean;
  vncEnabled: boolean;
  vncMode: boolean;
  moonlightEnabled: boolean;
  moonlightMode: boolean;
}

export interface RemotePortraitDisplayPreferenceUpdate {
  values: RemotePortraitDisplayPreferences;
  touched: RemotePortraitDisplayPreferencePresence;
}

const REMOTE_PORTRAIT_PROTOCOLS: RemotePortraitProtocol[] = [
  'rdp', 'rustdesk', 'vnc', 'moonlight'
];

function emptyPreference(): RemotePortraitProtocolPreference {
  return { enabled: false, mode: 'default' };
}

function clonePreference(value: RemotePortraitProtocolPreference): RemotePortraitProtocolPreference {
  return { enabled: value.enabled === true, mode: normalizeRemotePortraitDisplayMode(value.mode) };
}

export function normalizeRemotePortraitDisplayMode(value: string): RemotePortraitDisplayMode {
  return value === 'portrait' ? 'portrait' : 'default';
}

export function defaultRemotePortraitDisplayPreferences(): RemotePortraitDisplayPreferences {
  return {
    rdp: emptyPreference(),
    rustdesk: emptyPreference(),
    vnc: emptyPreference(),
    moonlight: emptyPreference()
  };
}

export function remotePortraitDisplayProtocols(): RemotePortraitProtocol[] {
  return REMOTE_PORTRAIT_PROTOCOLS.slice();
}

export function remotePortraitDisplayPreferenceKey(
  protocol: RemotePortraitProtocol, field: 'enabled' | 'mode'
): string {
  if (protocol === 'rdp') {
    return field === 'enabled' ? RDP_PORTRAIT_DISPLAY_ENABLED_KEY : RDP_PORTRAIT_DISPLAY_MODE_KEY;
  }
  if (protocol === 'rustdesk') {
    return field === 'enabled' ? RUSTDESK_PORTRAIT_DISPLAY_ENABLED_KEY : RUSTDESK_PORTRAIT_DISPLAY_MODE_KEY;
  }
  if (protocol === 'vnc') {
    return field === 'enabled' ? VNC_PORTRAIT_DISPLAY_ENABLED_KEY : VNC_PORTRAIT_DISPLAY_MODE_KEY;
  }
  return field === 'enabled' ? MOONLIGHT_PORTRAIT_DISPLAY_ENABLED_KEY : MOONLIGHT_PORTRAIT_DISPLAY_MODE_KEY;
}

function preferenceForProtocol(values: RemotePortraitDisplayPreferences,
  protocol: RemotePortraitProtocol): RemotePortraitProtocolPreference {
  if (protocol === 'rdp') { return values.rdp; }
  if (protocol === 'rustdesk') { return values.rustdesk; }
  if (protocol === 'vnc') { return values.vnc; }
  return values.moonlight;
}

export function remotePortraitDisplayPreference(
  values: RemotePortraitDisplayPreferences, protocol: string
): RemotePortraitProtocolPreference {
  if (protocol === 'rdp' || protocol === 'rustdesk' || protocol === 'vnc' || protocol === 'moonlight') {
    return clonePreference(preferenceForProtocol(values, protocol));
  }
  return emptyPreference();
}

export function remotePortraitDisplayEnabled(
  values: RemotePortraitDisplayPreferences, protocol: string
): boolean {
  return remotePortraitDisplayPreference(values, protocol).enabled;
}

export function remotePortraitDisplayMode(
  values: RemotePortraitDisplayPreferences, protocol: string
): RemotePortraitDisplayMode {
  return remotePortraitDisplayPreference(values, protocol).mode;
}

export function remotePortraitDisplayModeLabel(mode: RemotePortraitDisplayMode): string {
  return mode === 'portrait' ? '竖屏' : '默认方向';
}

export function withRemotePortraitDisplayPreference(
  values: RemotePortraitDisplayPreferences,
  protocol: RemotePortraitProtocol,
  next: RemotePortraitProtocolPreference
): RemotePortraitDisplayPreferences {
  const normalized: RemotePortraitProtocolPreference = clonePreference(next);
  return {
    rdp: protocol === 'rdp' ? normalized : clonePreference(values.rdp),
    rustdesk: protocol === 'rustdesk' ? normalized : clonePreference(values.rustdesk),
    vnc: protocol === 'vnc' ? normalized : clonePreference(values.vnc),
    moonlight: protocol === 'moonlight' ? normalized : clonePreference(values.moonlight)
  };
}

export function applyRemotePortraitDisplayPreferenceUpdate(
  current: RemotePortraitDisplayPreferences,
  update: RemotePortraitDisplayPreferenceUpdate
): RemotePortraitDisplayPreferences {
  const merged: RemotePortraitDisplayPreferences = {
    rdp: update.touched.rdpEnabled || update.touched.rdpMode ? {
      enabled: update.touched.rdpEnabled ? update.values.rdp.enabled : current.rdp.enabled,
      mode: update.touched.rdpMode ? update.values.rdp.mode : current.rdp.mode
    } : clonePreference(current.rdp),
    rustdesk: update.touched.rustdeskEnabled || update.touched.rustdeskMode ? {
      enabled: update.touched.rustdeskEnabled ? update.values.rustdesk.enabled : current.rustdesk.enabled,
      mode: update.touched.rustdeskMode ? update.values.rustdesk.mode : current.rustdesk.mode
    } : clonePreference(current.rustdesk),
    vnc: update.touched.vncEnabled || update.touched.vncMode ? {
      enabled: update.touched.vncEnabled ? update.values.vnc.enabled : current.vnc.enabled,
      mode: update.touched.vncMode ? update.values.vnc.mode : current.vnc.mode
    } : clonePreference(current.vnc),
    moonlight: update.touched.moonlightEnabled || update.touched.moonlightMode ? {
      enabled: update.touched.moonlightEnabled ? update.values.moonlight.enabled : current.moonlight.enabled,
      mode: update.touched.moonlightMode ? update.values.moonlight.mode : current.moonlight.mode
    } : clonePreference(current.moonlight)
  };
  // Disabling always restores the protocol's default direction. A first
  // enable stays at default unless the same editor explicitly chose portrait.
  const protocols: RemotePortraitProtocol[] = remotePortraitDisplayProtocols();
  for (let i: number = 0; i < protocols.length; i++) {
    const value: RemotePortraitProtocolPreference = preferenceForProtocol(merged, protocols[i]);
    value.enabled = value.enabled === true;
    value.mode = value.enabled ? normalizeRemotePortraitDisplayMode(value.mode) : 'default';
  }
  return merged;
}

export function migrateRemotePortraitDisplayPreferences(
  current: RemotePortraitDisplayPreferences,
  present: RemotePortraitDisplayPreferencePresence,
  storedVersion: number
): RemotePortraitDisplayPreferences {
  const defaults: RemotePortraitDisplayPreferences = defaultRemotePortraitDisplayPreferences();
  const values: RemotePortraitDisplayPreferences = {
    rdp: {
      enabled: present.rdpEnabled ? current.rdp.enabled : defaults.rdp.enabled,
      mode: present.rdpMode ? current.rdp.mode : defaults.rdp.mode
    },
    rustdesk: {
      enabled: present.rustdeskEnabled ? current.rustdesk.enabled : defaults.rustdesk.enabled,
      mode: present.rustdeskMode ? current.rustdesk.mode : defaults.rustdesk.mode
    },
    vnc: {
      enabled: present.vncEnabled ? current.vnc.enabled : defaults.vnc.enabled,
      mode: present.vncMode ? current.vnc.mode : defaults.vnc.mode
    },
    moonlight: {
      enabled: present.moonlightEnabled ? current.moonlight.enabled : defaults.moonlight.enabled,
      mode: present.moonlightMode ? current.moonlight.mode : defaults.moonlight.mode
    }
  };
  // A disabled preference never silently locks a window after migration.
  if (!values.rdp.enabled) { values.rdp.mode = 'default'; }
  if (!values.rustdesk.enabled) { values.rustdesk.mode = 'default'; }
  if (!values.vnc.enabled) { values.vnc.mode = 'default'; }
  if (!values.moonlight.enabled) { values.moonlight.mode = 'default'; }
  return values;
}

export function remotePortraitDisplaySelectionSummary(
  values: RemotePortraitDisplayPreferences
): string {
  const labels: string[] = [];
  if (values.rdp.enabled) { labels.push('RDP'); }
  if (values.rustdesk.enabled) { labels.push('RustDesk'); }
  if (values.vnc.enabled) { labels.push('VNC'); }
  if (values.moonlight.enabled) { labels.push('Moonlight'); }
  return labels.length === 0 ? '未选择协议' : '已开启：' + labels.join('、');
}

export function remotePortraitDisplayPreferenceObject(
  enabled: boolean, mode: string
): RemotePortraitProtocolPreference {
  return { enabled: enabled === true, mode: normalizeRemotePortraitDisplayMode(mode) };
}

function parsedPreference(value: Object): RemotePortraitProtocolPreference {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) {
    return emptyPreference();
  }
  const row: Record<string, Object> = value as Record<string, Object>;
  const enabled: boolean = row['enabled'] === true;
  return {
    enabled,
    mode: enabled && row['mode'] === 'portrait' ? 'portrait' : 'default'
  };
}

export function decodeRemotePortraitDisplayPreferences(encoded: string): RemotePortraitDisplayPreferences {
  if (encoded.length === 0 || encoded.length > 32768) {
    return defaultRemotePortraitDisplayPreferences();
  }
  try {
    const row: Record<string, Object> = JSON.parse(encoded) as Record<string, Object>;
    if (row === null || typeof row !== 'object' || Array.isArray(row)) {
      return defaultRemotePortraitDisplayPreferences();
    }
    return {
      rdp: parsedPreference(row['rdp']), rustdesk: parsedPreference(row['rustdesk']),
      vnc: parsedPreference(row['vnc']), moonlight: parsedPreference(row['moonlight'])
    };
  } catch (_error) {
    return defaultRemotePortraitDisplayPreferences();
  }
}

export function remotePortraitDisplayActive(values: RemotePortraitDisplayPreferences,
  protocol: string, isDesktopDevice: boolean, isPadDevice: boolean): boolean {
  const preference: RemotePortraitProtocolPreference = remotePortraitDisplayPreference(values, protocol);
  return !isDesktopDevice && !isPadDevice && preference.enabled && preference.mode === 'portrait';
}

export function remotePortraitDisplayActionVisible(values: RemotePortraitDisplayPreferences,
  protocol: string, isDesktopDevice: boolean, isPadDevice: boolean): boolean {
  return !isDesktopDevice && !isPadDevice && remotePortraitDisplayEnabled(values, protocol);
}

export function remotePortraitDisplayActionLabel(active: boolean): string {
  return active ? '翻转：恢复横屏' : '翻转：竖屏显示';
}
