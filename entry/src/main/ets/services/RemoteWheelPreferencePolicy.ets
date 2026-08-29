export type RemoteWheelProtocol = 'rdp' | 'rustdesk' | 'ssh' | 'vnc' | 'moonlight';

export const REMOTE_WHEEL_PREFERENCE_VERSION: number = 2;
export const REMOTE_WHEEL_PREFERENCE_VERSION_KEY: string =
  'remoteWheelPreferenceVersion';
export const RDP_REVERSE_WHEEL_KEY: string = 'rdpReverseWheel';
export const RUSTDESK_REVERSE_WHEEL_KEY: string = 'rustdeskReverseWheel';
export const SSH_REVERSE_WHEEL_KEY: string = 'sshReverseWheel';
export const VNC_REVERSE_WHEEL_KEY: string = 'vncReverseWheel';
export const MOONLIGHT_REVERSE_WHEEL_KEY: string = 'moonlightReverseWheel';

export interface RemoteWheelPreferences {
  rdp: boolean;
  rustdesk: boolean;
  ssh: boolean;
  vnc: boolean;
  moonlight: boolean;
}

export interface RemoteWheelPreferencePresence {
  rdp: boolean;
  rustdesk: boolean;
  ssh: boolean;
  vnc: boolean;
  moonlight: boolean;
}

export interface RemoteWheelPreferenceMigration {
  values: RemoteWheelPreferences;
  shouldPersist: boolean;
  version: number;
}

export interface RemoteWheelPreferenceUpdate {
  values: RemoteWheelPreferences;
  touched: RemoteWheelPreferencePresence;
}

export function defaultRemoteWheelPreferences(): RemoteWheelPreferences {
  return { rdp: false, rustdesk: false, ssh: false, vnc: false, moonlight: false };
}

export function remoteWheelProtocols(): RemoteWheelProtocol[] {
  return ['rdp', 'rustdesk', 'ssh', 'vnc', 'moonlight'];
}

export function remoteWheelPreferenceKey(protocol: RemoteWheelProtocol): string {
  if (protocol === 'rdp') { return RDP_REVERSE_WHEEL_KEY; }
  if (protocol === 'rustdesk') { return RUSTDESK_REVERSE_WHEEL_KEY; }
  if (protocol === 'ssh') { return SSH_REVERSE_WHEEL_KEY; }
  if (protocol === 'vnc') { return VNC_REVERSE_WHEEL_KEY; }
  return MOONLIGHT_REVERSE_WHEEL_KEY;
}

export function remoteWheelPreference(
  values: RemoteWheelPreferences,
  protocol: string
): boolean {
  if (protocol === 'rdp') { return values.rdp; }
  if (protocol === 'rustdesk') { return values.rustdesk; }
  if (protocol === 'ssh') { return values.ssh; }
  if (protocol === 'vnc') { return values.vnc; }
  if (protocol === 'moonlight') { return values.moonlight; }
  return false;
}

export function withRemoteWheelPreference(
  values: RemoteWheelPreferences,
  protocol: RemoteWheelProtocol,
  reversed: boolean
): RemoteWheelPreferences {
  return {
    rdp: protocol === 'rdp' ? reversed : values.rdp,
    rustdesk: protocol === 'rustdesk' ? reversed : values.rustdesk,
    ssh: protocol === 'ssh' ? reversed : values.ssh,
    vnc: protocol === 'vnc' ? reversed : values.vnc,
    moonlight: protocol === 'moonlight' ? reversed : values.moonlight
  };
}

/** Merge a possibly stale editor draft without reverting untouched protocols. */
export function applyRemoteWheelPreferenceUpdate(
  current: RemoteWheelPreferences,
  update: RemoteWheelPreferenceUpdate
): RemoteWheelPreferences {
  return {
    rdp: update.touched.rdp ? update.values.rdp : current.rdp,
    rustdesk: update.touched.rustdesk ? update.values.rustdesk : current.rustdesk,
    ssh: update.touched.ssh ? update.values.ssh : current.ssh,
    vnc: update.touched.vnc ? update.values.vnc : current.vnc,
    moonlight: update.touched.moonlight ? update.values.moonlight : current.moonlight
  };
}

/**
 * Split the legacy RDP/RustDesk/VNC switch without changing an upgraded
 * installation's observed direction. The VNC logical setting is only a
 * fallback when the shared legacy key was never stored.
 */
export function migrateRemoteWheelPreferences(
  current: RemoteWheelPreferences,
  present: RemoteWheelPreferencePresence,
  storedVersion: number,
  legacyVncReverseWheel: boolean
): RemoteWheelPreferenceMigration {
  const legacySharedPresent: boolean = present.rustdesk;
  const legacySharedValue: boolean = current.rustdesk;
  const values: RemoteWheelPreferences = {
    rdp: present.rdp ? current.rdp :
      (legacySharedPresent ? legacySharedValue : false),
    rustdesk: legacySharedPresent ? current.rustdesk : false,
    ssh: present.ssh ? current.ssh : false,
    vnc: present.vnc ? current.vnc :
      (legacySharedPresent ? legacySharedValue : legacyVncReverseWheel),
    moonlight: present.moonlight ? current.moonlight : false
  };
  const everyKeyPresent: boolean = present.rdp && present.rustdesk && present.ssh &&
    present.vnc && present.moonlight;
  return {
    values,
    shouldPersist: storedVersion < REMOTE_WHEEL_PREFERENCE_VERSION || !everyKeyPresent,
    version: REMOTE_WHEEL_PREFERENCE_VERSION
  };
}

function remoteWheelProtocolLabel(protocol: RemoteWheelProtocol): string {
  if (protocol === 'rdp') { return 'RDP'; }
  if (protocol === 'rustdesk') { return 'RustDesk'; }
  if (protocol === 'ssh') { return 'SSH'; }
  if (protocol === 'vnc') { return 'VNC'; }
  return 'Moonlight';
}

export function remoteWheelSelectionSummary(values: RemoteWheelPreferences): string {
  const protocols: RemoteWheelProtocol[] = remoteWheelProtocols();
  const reversedLabels: string[] = [];
  for (let i: number = 0; i < protocols.length; i++) {
    if (remoteWheelPreference(values, protocols[i])) {
      reversedLabels.push(remoteWheelProtocolLabel(protocols[i]));
    }
  }
  if (reversedLabels.length === 0) { return '全部协议正常'; }
  if (reversedLabels.length === protocols.length) { return '全部协议反转'; }
  return '已反转：' + reversedLabels.join('、');
}
