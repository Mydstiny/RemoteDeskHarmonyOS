export type RemotePinchZoomProtocol = 'rdp' | 'rustdesk' | 'ssh' | 'vnc' | 'moonlight';

export const REMOTE_PINCH_ZOOM_PREFERENCE_VERSION: number = 1;
export const REMOTE_PINCH_ZOOM_PREFERENCE_VERSION_KEY: string =
  'remotePinchZoomPreferenceVersion';
export const RDP_PINCH_ZOOM_ENABLED_KEY: string = 'rdpPinchZoomEnabled';
export const RUSTDESK_PINCH_ZOOM_ENABLED_KEY: string = 'rustdeskPinchZoomEnabled';
export const SSH_PINCH_ZOOM_ENABLED_KEY: string = 'sshPinchZoomEnabled';
export const VNC_PINCH_ZOOM_ENABLED_KEY: string = 'vncPinchZoomEnabled';
export const MOONLIGHT_PINCH_ZOOM_ENABLED_KEY: string = 'moonlightPinchZoomEnabled';

export interface RemotePinchZoomPreferences {
  rdp: boolean;
  rustdesk: boolean;
  ssh: boolean;
  vnc: boolean;
  moonlight: boolean;
}

export interface RemotePinchZoomPreferencePresence {
  rdp: boolean;
  rustdesk: boolean;
  ssh: boolean;
  vnc: boolean;
  moonlight: boolean;
}

export interface RemotePinchZoomPreferenceMigration {
  values: RemotePinchZoomPreferences;
  shouldPersist: boolean;
  version: number;
}

export interface RemotePinchZoomPreferenceUpdate {
  values: RemotePinchZoomPreferences;
  touched: RemotePinchZoomPreferencePresence;
}

export function defaultRemotePinchZoomPreferences(
  legacyCanvasEnabled: boolean = false
): RemotePinchZoomPreferences {
  return {
    rdp: legacyCanvasEnabled,
    rustdesk: legacyCanvasEnabled,
    // SSH already supported font-size pinch before the split.
    ssh: true,
    vnc: legacyCanvasEnabled,
    // Moonlight had no local canvas transform before the split.
    moonlight: false
  };
}

export function remotePinchZoomProtocols(): RemotePinchZoomProtocol[] {
  return ['rdp', 'rustdesk', 'ssh', 'vnc', 'moonlight'];
}

export function remotePinchZoomPreferenceKey(
  protocol: RemotePinchZoomProtocol
): string {
  if (protocol === 'rdp') { return RDP_PINCH_ZOOM_ENABLED_KEY; }
  if (protocol === 'rustdesk') { return RUSTDESK_PINCH_ZOOM_ENABLED_KEY; }
  if (protocol === 'ssh') { return SSH_PINCH_ZOOM_ENABLED_KEY; }
  if (protocol === 'vnc') { return VNC_PINCH_ZOOM_ENABLED_KEY; }
  return MOONLIGHT_PINCH_ZOOM_ENABLED_KEY;
}

export function remotePinchZoomPreference(
  values: RemotePinchZoomPreferences,
  protocol: string
): boolean {
  if (protocol === 'rdp') { return values.rdp; }
  if (protocol === 'rustdesk') { return values.rustdesk; }
  if (protocol === 'ssh') { return values.ssh; }
  if (protocol === 'vnc') { return values.vnc; }
  if (protocol === 'moonlight') { return values.moonlight; }
  return false;
}

export function withRemotePinchZoomPreference(
  values: RemotePinchZoomPreferences,
  protocol: RemotePinchZoomProtocol,
  enabled: boolean
): RemotePinchZoomPreferences {
  return {
    rdp: protocol === 'rdp' ? enabled : values.rdp,
    rustdesk: protocol === 'rustdesk' ? enabled : values.rustdesk,
    ssh: protocol === 'ssh' ? enabled : values.ssh,
    vnc: protocol === 'vnc' ? enabled : values.vnc,
    moonlight: protocol === 'moonlight' ? enabled : values.moonlight
  };
}

/** Merge a stale settings-sheet draft without reverting untouched protocols. */
export function applyRemotePinchZoomPreferenceUpdate(
  current: RemotePinchZoomPreferences,
  update: RemotePinchZoomPreferenceUpdate
): RemotePinchZoomPreferences {
  return {
    rdp: update.touched.rdp ? update.values.rdp : current.rdp,
    rustdesk: update.touched.rustdesk ? update.values.rustdesk : current.rustdesk,
    ssh: update.touched.ssh ? update.values.ssh : current.ssh,
    vnc: update.touched.vnc ? update.values.vnc : current.vnc,
    moonlight: update.touched.moonlight ? update.values.moonlight : current.moonlight
  };
}

/**
 * Split the legacy graphical-protocol switch without changing observed
 * behavior. SSH and Moonlight use their own previously released behavior.
 * RustDesk remote-App TouchScale is a different owner and always wins during
 * migration so local canvas scale and protocol-native scale cannot both run.
 */
export function migrateRemotePinchZoomPreferences(
  current: RemotePinchZoomPreferences,
  present: RemotePinchZoomPreferencePresence,
  storedVersion: number,
  legacyCanvasEnabled: boolean,
  rustDeskRemoteAppTouchScaleEnabled: boolean = false
): RemotePinchZoomPreferenceMigration {
  const values: RemotePinchZoomPreferences = {
    rdp: present.rdp ? current.rdp : legacyCanvasEnabled,
    rustdesk: present.rustdesk ? current.rustdesk : legacyCanvasEnabled,
    ssh: present.ssh ? current.ssh : true,
    vnc: present.vnc ? current.vnc : legacyCanvasEnabled,
    moonlight: present.moonlight ? current.moonlight : false
  };
  if (rustDeskRemoteAppTouchScaleEnabled && values.rustdesk) {
    values.rustdesk = false;
  }
  const everyKeyPresent: boolean = present.rdp && present.rustdesk &&
    present.ssh && present.vnc && present.moonlight;
  return {
    values,
    shouldPersist: storedVersion < REMOTE_PINCH_ZOOM_PREFERENCE_VERSION ||
      !everyKeyPresent ||
      (rustDeskRemoteAppTouchScaleEnabled && current.rustdesk),
    version: REMOTE_PINCH_ZOOM_PREFERENCE_VERSION
  };
}

function remotePinchZoomProtocolLabel(protocol: RemotePinchZoomProtocol): string {
  if (protocol === 'rdp') { return 'RDP'; }
  if (protocol === 'rustdesk') { return 'RustDesk'; }
  if (protocol === 'ssh') { return 'SSH'; }
  if (protocol === 'vnc') { return 'VNC'; }
  return 'Moonlight';
}

export function remotePinchZoomSelectionSummary(
  values: RemotePinchZoomPreferences
): string {
  const protocols: RemotePinchZoomProtocol[] = remotePinchZoomProtocols();
  const enabledLabels: string[] = [];
  for (let i: number = 0; i < protocols.length; i++) {
    if (remotePinchZoomPreference(values, protocols[i])) {
      enabledLabels.push(remotePinchZoomProtocolLabel(protocols[i]));
    }
  }
  if (enabledLabels.length === 0) { return '全部协议关闭'; }
  if (enabledLabels.length === protocols.length) { return '全部协议开启'; }
  return '已开启：' + enabledLabels.join('、');
}
