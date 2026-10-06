export type RemoteWheelProtocol = 'rdp' | 'rustdesk' | 'ssh' | 'vnc' | 'moonlight';

export const REMOTE_WHEEL_PREFERENCE_VERSION: number = 2;
export const REMOTE_WHEEL_PREFERENCE_VERSION_KEY: string =
  'remoteWheelPreferenceVersion';
export const RDP_REVERSE_WHEEL_KEY: string = 'rdpReverseWheel';
export const RUSTDESK_REVERSE_WHEEL_KEY: string = 'rustdeskReverseWheel';
export const SSH_REVERSE_WHEEL_KEY: string = 'sshReverseWheel';
export const VNC_REVERSE_WHEEL_KEY: string = 'vncReverseWheel';
export const MOONLIGHT_REVERSE_WHEEL_KEY: string = 'moonlightReverseWheel';
export const RUSTDESK_WHEEL_DIRECTION_FOLLOWS_KEYBOARD_KEY: string =
  'rustdeskWheelDirectionFollowsKeyboard';

export function defaultRustDeskWheelDirectionFollowsKeyboard(
  followsKeyboardPreferencePresent: boolean,
  storedFollowsKeyboard: boolean,
  legacyReverseWheel: boolean
): boolean {
  if (followsKeyboardPreferencePresent) { return storedFollowsKeyboard; }
  // Preserve an old reversed choice as manual. Legacy false was also the
  // default, so it adopts the new keyboard-following behavior.
  return !legacyReverseWheel;
}

export function rustDeskWheelReversedForKeyboardLayout(layout: string): boolean {
  return layout.trim().toLowerCase() === 'macos';
}

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

// ---------------------------------------------------------------- speed

/**
 * 设置 › 显示与交互 › 远程滚轮: each protocol's wheel speed, a percentage of its tuned default (100). One wheel
 * notch, one touchpad stroke or one two-finger swipe moves the remote this much more or less.
 */
export const REMOTE_WHEEL_SPEED_DEFAULT: number = 100;
export const REMOTE_WHEEL_SPEED_MIN: number = 25;
export const REMOTE_WHEEL_SPEED_MAX: number = 400;
export const REMOTE_WHEEL_SPEED_STEP: number = 25;
export const RDP_WHEEL_SPEED_KEY: string = 'rdpWheelSpeed';
export const RUSTDESK_WHEEL_SPEED_KEY: string = 'rustdeskWheelSpeed';
export const SSH_WHEEL_SPEED_KEY: string = 'sshWheelSpeed';
export const VNC_WHEEL_SPEED_KEY: string = 'vncWheelSpeed';
export const MOONLIGHT_WHEEL_SPEED_KEY: string = 'moonlightWheelSpeed';

export interface RemoteWheelSpeeds {
  rdp: number;
  rustdesk: number;
  ssh: number;
  vnc: number;
  moonlight: number;
}

export function defaultRemoteWheelSpeeds(): RemoteWheelSpeeds {
  return { rdp: 100, rustdesk: 100, ssh: 100, vnc: 100, moonlight: 100 };
}

export function remoteWheelSpeedKey(protocol: RemoteWheelProtocol): string {
  if (protocol === 'rdp') { return RDP_WHEEL_SPEED_KEY; }
  if (protocol === 'rustdesk') { return RUSTDESK_WHEEL_SPEED_KEY; }
  if (protocol === 'ssh') { return SSH_WHEEL_SPEED_KEY; }
  if (protocol === 'vnc') { return VNC_WHEEL_SPEED_KEY; }
  return MOONLIGHT_WHEEL_SPEED_KEY;
}

/** A stored or typed speed on the 25% grid between 25% and 400%; anything unreadable is the default. */
export function normalizeRemoteWheelSpeed(value: number): number {
  if (!Number.isFinite(value) || value <= 0) { return REMOTE_WHEEL_SPEED_DEFAULT; }
  const snapped: number = Math.round(value / REMOTE_WHEEL_SPEED_STEP) * REMOTE_WHEEL_SPEED_STEP;
  return Math.max(REMOTE_WHEEL_SPEED_MIN, Math.min(REMOTE_WHEEL_SPEED_MAX, snapped));
}

/** Every speed the settings offer (also the AI's choices). */
export function remoteWheelSpeedChoices(): number[] {
  const out: number[] = [];
  for (let v = REMOTE_WHEEL_SPEED_MIN; v <= REMOTE_WHEEL_SPEED_MAX; v += REMOTE_WHEEL_SPEED_STEP) { out.push(v); }
  return out;
}

export function remoteWheelSpeedLabel(value: number): string {
  const v: number = normalizeRemoteWheelSpeed(value);
  return v === REMOTE_WHEEL_SPEED_DEFAULT ? '100%（默认）' : v.toString() + '%';
}

export function remoteWheelSpeed(values: RemoteWheelSpeeds, protocol: string): number {
  if (protocol === 'rdp') { return values.rdp; }
  if (protocol === 'rustdesk') { return values.rustdesk; }
  if (protocol === 'ssh') { return values.ssh; }
  if (protocol === 'vnc') { return values.vnc; }
  if (protocol === 'moonlight') { return values.moonlight; }
  return REMOTE_WHEEL_SPEED_DEFAULT;
}

export function withRemoteWheelSpeed(values: RemoteWheelSpeeds, protocol: RemoteWheelProtocol,
  speed: number): RemoteWheelSpeeds {
  const v: number = normalizeRemoteWheelSpeed(speed);
  return {
    rdp: protocol === 'rdp' ? v : values.rdp,
    rustdesk: protocol === 'rustdesk' ? v : values.rustdesk,
    ssh: protocol === 'ssh' ? v : values.ssh,
    vnc: protocol === 'vnc' ? v : values.vnc,
    moonlight: protocol === 'moonlight' ? v : values.moonlight
  };
}

const WHEEL_PROTOCOL_NAMES: string[][] = [['rdp', 'RDP'], ['rustdesk', 'RustDesk'], ['ssh', 'SSH'], ['vnc', 'VNC'],
  ['moonlight', 'Moonlight']];

/** One protocol's row in 远程滚轮: 「方向正常 · 速度 100%（默认）」. */
export function remoteWheelProtocolSummary(reversed: boolean, speed: number): string {
  return (reversed ? '方向反转' : '方向正常') + ' · 速度 ' + remoteWheelSpeedLabel(speed);
}

/** The 显示与交互 row: what differs from the defaults, or 「全部默认」. */
export function remoteWheelSettingsSummary(directions: RemoteWheelPreferences, speeds: RemoteWheelSpeeds): string {
  const parts: string[] = [];
  WHEEL_PROTOCOL_NAMES.forEach((pair: string[]): void => {
    const reversed: boolean = remoteWheelPreference(directions, pair[0]);
    const speed: number = normalizeRemoteWheelSpeed(remoteWheelSpeed(speeds, pair[0]));
    if (!reversed && speed === REMOTE_WHEEL_SPEED_DEFAULT) { return; }
    const bits: string[] = [];
    if (reversed) { bits.push('反转'); }
    if (speed !== REMOTE_WHEEL_SPEED_DEFAULT) { bits.push(speed.toString() + '%'); }
    parts.push(pair[1] + ' ' + bits.join(' '));
  });
  return parts.length === 0 ? '方向与速度均为默认' : parts.join(' · ');
}
