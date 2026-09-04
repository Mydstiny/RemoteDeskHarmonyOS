export type HarmonyShortcutDeviceClass = 'phone' | 'pad' | 'pc';
export type HarmonyShortcutProtocol = 'rdp' | 'rustdesk' | 'ssh' | 'vnc' | 'moonlight';

export interface HarmonyShortcutProtocolSelection {
  rdp: boolean;
  rustdesk: boolean;
  ssh: boolean;
  vnc: boolean;
  moonlight: boolean;
}

export interface HarmonyShortcutBlockingPreferences {
  version: number;
  phone: HarmonyShortcutProtocolSelection;
  pad: HarmonyShortcutProtocolSelection;
  pc: HarmonyShortcutProtocolSelection;
}

export interface HarmonyShortcutCaptureEligibility {
  configured: boolean;
  foreground: boolean;
  windowActive: boolean;
  sessionReady: boolean;
  inputAllowed: boolean;
  modalOwnsInput: boolean;
}

export interface HarmonyShortcutPressedKeyIdentity {
  keyCode: number;
  deviceId: number;
}

export interface HarmonyShortcutStorageTransactionPort {
  has(key: string): boolean;
  get(key: string, fallback: string): string;
  put(key: string, value: string): void;
  delete(key: string): void;
  flush(): void;
  publish(key: string, value: string): void;
}

export const HARMONY_SHORTCUT_BLOCKING_VERSION: number = 1;
export const HARMONY_SHORTCUT_BLOCKING_STORAGE_KEY: string =
  'remoteHarmonyShortcutBlockingV1';
export const HARMONY_MEDIA_PLAY_PAUSE_KEY_CODE: number = 10;
export const HARMONY_MEDIA_NEXT_KEY_CODE: number = 12;
export const HARMONY_MEDIA_PREVIOUS_KEY_CODE: number = 13;
export const HARMONY_VOLUME_UP_KEY_CODE: number = 16;
export const HARMONY_VOLUME_DOWN_KEY_CODE: number = 17;

function emptyProtocolSelection(): HarmonyShortcutProtocolSelection {
  return { rdp: false, rustdesk: false, ssh: false, vnc: false, moonlight: false };
}

function desktopDefaultProtocolSelection(): HarmonyShortcutProtocolSelection {
  return { rdp: true, rustdesk: true, ssh: false, vnc: true, moonlight: true };
}

export function disabledHarmonyShortcutBlockingPreferences():
  HarmonyShortcutBlockingPreferences {
  return {
    version: HARMONY_SHORTCUT_BLOCKING_VERSION,
    phone: emptyProtocolSelection(),
    pad: emptyProtocolSelection(),
    pc: emptyProtocolSelection()
  };
}

function normalizeProtocolSelection(
  value: Object | undefined
): HarmonyShortcutProtocolSelection {
  if (value === undefined || value === null || Array.isArray(value) ||
    typeof value !== 'object') { return emptyProtocolSelection(); }
  const record: Record<string, Object> = value as Record<string, Object>;
  return {
    rdp: record['rdp'] === true,
    rustdesk: record['rustdesk'] === true,
    ssh: false,
    vnc: record['vnc'] === true,
    moonlight: record['moonlight'] === true
  };
}

export function defaultHarmonyShortcutBlockingPreferences():
  HarmonyShortcutBlockingPreferences {
  return {
    version: HARMONY_SHORTCUT_BLOCKING_VERSION,
    phone: emptyProtocolSelection(),
    pad: emptyProtocolSelection(),
    pc: desktopDefaultProtocolSelection()
  };
}

export function normalizeHarmonyShortcutBlockingPreferences(
  value: Object | null | undefined
): HarmonyShortcutBlockingPreferences {
  if (value === null || value === undefined || Array.isArray(value) ||
    typeof value !== 'object') {
    return disabledHarmonyShortcutBlockingPreferences();
  }
  const record: Record<string, Object> = value as Record<string, Object>;
  return {
    version: HARMONY_SHORTCUT_BLOCKING_VERSION,
    phone: normalizeProtocolSelection(record['phone']),
    pad: normalizeProtocolSelection(record['pad']),
    pc: normalizeProtocolSelection(record['pc'])
  };
}

export function decodeHarmonyShortcutBlockingPreferences(
  encoded: string
): HarmonyShortcutBlockingPreferences {
  const trimmed: string = encoded.trim();
  if (trimmed.length === 0 || trimmed.length > 4096) {
    return disabledHarmonyShortcutBlockingPreferences();
  }
  try {
    return normalizeHarmonyShortcutBlockingPreferences(
      JSON.parse(trimmed) as Object);
  } catch (_error) {
    return disabledHarmonyShortcutBlockingPreferences();
  }
}

/** Product defaults apply only when the durable key is reliably absent.
 * Existing but unreadable data must never be mistaken for first use. */
export function readHarmonyShortcutBlockingPreferences(
  port: HarmonyShortcutStorageTransactionPort
): HarmonyShortcutBlockingPreferences | null {
  try {
    if (!port.has(HARMONY_SHORTCUT_BLOCKING_STORAGE_KEY)) {
      return defaultHarmonyShortcutBlockingPreferences();
    }
    return decodeHarmonyShortcutBlockingPreferences(
      port.get(HARMONY_SHORTCUT_BLOCKING_STORAGE_KEY, ''));
  } catch (_error) {
    return null;
  }
}

export function encodeHarmonyShortcutBlockingPreferences(
  value: HarmonyShortcutBlockingPreferences
): string {
  return JSON.stringify(normalizeHarmonyShortcutBlockingPreferences(value as Object));
}

export function harmonyShortcutDeviceClass(
  isDesktopDevice: boolean,
  isPadDevice: boolean
): HarmonyShortcutDeviceClass {
  if (isDesktopDevice) { return 'pc'; }
  return isPadDevice ? 'pad' : 'phone';
}

export function harmonyShortcutProtocols(): HarmonyShortcutProtocol[] {
  // SSH terminals have no standard byte sequence for consumer media/volume
  // keys. Do not offer a switch that would suppress HarmonyOS locally while
  // having nothing meaningful to deliver to the remote shell.
  return ['rdp', 'rustdesk', 'vnc', 'moonlight'];
}

export function harmonyShortcutDeviceClasses(): HarmonyShortcutDeviceClass[] {
  return ['phone', 'pad', 'pc'];
}

export function harmonyShortcutProtocolSelection(
  value: HarmonyShortcutBlockingPreferences,
  deviceClass: HarmonyShortcutDeviceClass
): HarmonyShortcutProtocolSelection {
  if (deviceClass === 'phone') { return value.phone; }
  if (deviceClass === 'pad') { return value.pad; }
  return value.pc;
}

export function harmonyShortcutBlockingEnabled(
  value: HarmonyShortcutBlockingPreferences,
  deviceClass: HarmonyShortcutDeviceClass,
  protocol: string
): boolean {
  const selected: HarmonyShortcutProtocolSelection =
    harmonyShortcutProtocolSelection(value, deviceClass);
  if (protocol === 'rdp') { return selected.rdp; }
  if (protocol === 'rustdesk') { return selected.rustdesk; }
  if (protocol === 'ssh') { return selected.ssh; }
  if (protocol === 'vnc') { return selected.vnc; }
  if (protocol === 'moonlight') { return selected.moonlight; }
  return false;
}

function withProtocolSelection(
  value: HarmonyShortcutProtocolSelection,
  protocol: HarmonyShortcutProtocol,
  enabled: boolean
): HarmonyShortcutProtocolSelection {
  return {
    rdp: protocol === 'rdp' ? enabled : value.rdp,
    rustdesk: protocol === 'rustdesk' ? enabled : value.rustdesk,
    ssh: false,
    vnc: protocol === 'vnc' ? enabled : value.vnc,
    moonlight: protocol === 'moonlight' ? enabled : value.moonlight
  };
}

export function withHarmonyShortcutBlockingPreference(
  value: HarmonyShortcutBlockingPreferences,
  deviceClass: HarmonyShortcutDeviceClass,
  protocol: HarmonyShortcutProtocol,
  enabled: boolean
): HarmonyShortcutBlockingPreferences {
  const normalized: HarmonyShortcutBlockingPreferences =
    normalizeHarmonyShortcutBlockingPreferences(value as Object);
  return {
    version: HARMONY_SHORTCUT_BLOCKING_VERSION,
    phone: deviceClass === 'phone' ?
      withProtocolSelection(normalized.phone, protocol, enabled) : normalized.phone,
    pad: deviceClass === 'pad' ?
      withProtocolSelection(normalized.pad, protocol, enabled) : normalized.pad,
    pc: deviceClass === 'pc' ?
      withProtocolSelection(normalized.pc, protocol, enabled) : normalized.pc
  };
}

export function withHarmonyShortcutDeviceSelection(
  value: HarmonyShortcutBlockingPreferences,
  deviceClass: HarmonyShortcutDeviceClass,
  enabled: boolean
): HarmonyShortcutBlockingPreferences {
  const normalized: HarmonyShortcutBlockingPreferences =
    normalizeHarmonyShortcutBlockingPreferences(value as Object);
  const selected: HarmonyShortcutProtocolSelection = {
    rdp: enabled,
    rustdesk: enabled,
    ssh: false,
    vnc: enabled,
    moonlight: enabled
  };
  return {
    version: HARMONY_SHORTCUT_BLOCKING_VERSION,
    phone: deviceClass === 'phone' ? selected : normalized.phone,
    pad: deviceClass === 'pad' ? selected : normalized.pad,
    pc: deviceClass === 'pc' ? selected : normalized.pc
  };
}

export function harmonyShortcutBlockingSelectionCount(
  value: HarmonyShortcutBlockingPreferences
): number {
  const devices: HarmonyShortcutDeviceClass[] = harmonyShortcutDeviceClasses();
  const protocols: HarmonyShortcutProtocol[] = harmonyShortcutProtocols();
  let count: number = 0;
  for (let deviceIndex: number = 0; deviceIndex < devices.length; deviceIndex++) {
    for (let protocolIndex: number = 0; protocolIndex < protocols.length; protocolIndex++) {
      if (harmonyShortcutBlockingEnabled(
        value, devices[deviceIndex], protocols[protocolIndex])) { count++; }
    }
  }
  return count;
}

export function harmonyShortcutBlockingSelectionSummary(
  value: HarmonyShortcutBlockingPreferences
): string {
  const count: number = harmonyShortcutBlockingSelectionCount(value);
  if (count === 0) { return '尚未启用'; }
  if (count === harmonyShortcutDeviceClasses().length * harmonyShortcutProtocols().length) {
    return '全部设备与可用协议';
  }
  return '已启用 ' + count.toString() + ' 项';
}

/** API 23 inputConsumer keys that have a defined mapping for the protocol. */
export function harmonyShortcutCaptureKeyCodes(
  protocol: string,
  _remoteKeyboardLayout: string = 'windows'
): number[] {
  if (protocol === 'ssh' || protocol.trim().length === 0) { return []; }
  if (protocol === 'rustdesk') {
    // RustDesk chooses Map/Legacy from the negotiated peer platform and
    // version, not from the user's local shortcut-layout preference. Volume
    // controls are defined in every transport; the three media controls are
    // not representable for Legacy/Android/Linux peers, so never consume them.
    return [HARMONY_VOLUME_UP_KEY_CODE, HARMONY_VOLUME_DOWN_KEY_CODE];
  }
  if (protocol !== 'rdp' && protocol !== 'rustdesk' &&
    protocol !== 'vnc' && protocol !== 'moonlight') { return []; }
  return [
    HARMONY_MEDIA_PLAY_PAUSE_KEY_CODE,
    HARMONY_MEDIA_NEXT_KEY_CODE,
    HARMONY_MEDIA_PREVIOUS_KEY_CODE,
    HARMONY_VOLUME_UP_KEY_CODE,
    HARMONY_VOLUME_DOWN_KEY_CODE
  ];
}

export function harmonyShortcutCaptureEligible(
  value: HarmonyShortcutCaptureEligibility
): boolean {
  return value.configured && value.foreground && value.windowActive &&
    value.sessionReady && value.inputAllowed && !value.modalOwnsInput;
}

export function harmonyShortcutRememberPressedKey(
  current: HarmonyShortcutPressedKeyIdentity[],
  keyCode: number,
  deviceId: number
): HarmonyShortcutPressedKeyIdentity[] {
  for (let index: number = 0; index < current.length; index++) {
    if (current[index].keyCode === keyCode && current[index].deviceId === deviceId) {
      return current.slice();
    }
  }
  const next: HarmonyShortcutPressedKeyIdentity[] = current.slice();
  next.push({ keyCode, deviceId });
  return next;
}

export function harmonyShortcutForgetPressedKey(
  current: HarmonyShortcutPressedKeyIdentity[],
  keyCode: number,
  deviceId: number
): HarmonyShortcutPressedKeyIdentity[] {
  return current.filter((entry: HarmonyShortcutPressedKeyIdentity): boolean =>
    entry.keyCode !== keyCode || entry.deviceId !== deviceId);
}

export function harmonyShortcutPressedKeysForRelease(
  current: HarmonyShortcutPressedKeyIdentity[]
): HarmonyShortcutPressedKeyIdentity[] {
  return current.map((entry: HarmonyShortcutPressedKeyIdentity): HarmonyShortcutPressedKeyIdentity => ({
    keyCode: entry.keyCode,
    deviceId: entry.deviceId
  }));
}

export function harmonyShortcutMissingSubscriptionKeyCodes(
  requested: number[],
  active: number[]
): number[] {
  return requested.filter((keyCode: number): boolean => active.indexOf(keyCode) < 0);
}

export function harmonyShortcutUnrequestedSubscriptionKeyCodes(
  requested: number[],
  active: number[]
): number[] {
  return active.filter((keyCode: number): boolean => requested.indexOf(keyCode) < 0);
}

/** Durable write with an exact before-image and publish-after-flush ordering. */
export function commitHarmonyShortcutBlockingPreferences(
  port: HarmonyShortcutStorageTransactionPort,
  values: HarmonyShortcutBlockingPreferences
): boolean {
  const encoded: string = encodeHarmonyShortcutBlockingPreferences(values);
  let previousPresent: boolean = false;
  let previousEncoded: string = '';
  let snapshotCaptured: boolean = false;
  try {
    previousPresent = port.has(HARMONY_SHORTCUT_BLOCKING_STORAGE_KEY);
    previousEncoded = port.get(HARMONY_SHORTCUT_BLOCKING_STORAGE_KEY, '');
    snapshotCaptured = true;
    port.put(HARMONY_SHORTCUT_BLOCKING_STORAGE_KEY, encoded);
    port.flush();
    port.publish(HARMONY_SHORTCUT_BLOCKING_STORAGE_KEY, encoded);
    return true;
  } catch (_error) {
    if (!snapshotCaptured) { return false; }
    try {
      if (previousPresent) {
        port.put(HARMONY_SHORTCUT_BLOCKING_STORAGE_KEY, previousEncoded);
      } else {
        port.delete(HARMONY_SHORTCUT_BLOCKING_STORAGE_KEY);
      }
      port.flush();
    } catch (_rollbackError) {
      // Publishing remains forbidden even when the platform cannot flush the
      // before-image. A later mutation reloads Preferences before editing.
    }
    return false;
  }
}

/** Read-modify-write through one Preferences instance. A read failure must
 * never be converted into the UI's safe all-off fallback and persisted over
 * unrelated cells. */
export function mutateHarmonyShortcutBlockingPreferences(
  port: HarmonyShortcutStorageTransactionPort,
  deviceClass: HarmonyShortcutDeviceClass,
  protocol: HarmonyShortcutProtocol | null,
  enabled: boolean
): HarmonyShortcutBlockingPreferences | null {
  let previousPresent: boolean = false;
  let previousEncoded: string = '';
  let snapshotCaptured: boolean = false;
  try {
    previousPresent = port.has(HARMONY_SHORTCUT_BLOCKING_STORAGE_KEY);
    if (previousPresent) {
      previousEncoded = port.get(HARMONY_SHORTCUT_BLOCKING_STORAGE_KEY, '');
    }
    snapshotCaptured = true;
    const current: HarmonyShortcutBlockingPreferences =
      previousPresent ? decodeHarmonyShortcutBlockingPreferences(previousEncoded) :
        defaultHarmonyShortcutBlockingPreferences();
    const next: HarmonyShortcutBlockingPreferences = protocol === null ?
      withHarmonyShortcutDeviceSelection(current, deviceClass, enabled) :
      withHarmonyShortcutBlockingPreference(current, deviceClass, protocol, enabled);
    const encoded: string = encodeHarmonyShortcutBlockingPreferences(next);
    port.put(HARMONY_SHORTCUT_BLOCKING_STORAGE_KEY, encoded);
    port.flush();
    port.publish(HARMONY_SHORTCUT_BLOCKING_STORAGE_KEY, encoded);
    return next;
  } catch (_error) {
    if (!snapshotCaptured) { return null; }
    try {
      if (previousPresent) {
        port.put(HARMONY_SHORTCUT_BLOCKING_STORAGE_KEY, previousEncoded);
      } else {
        port.delete(HARMONY_SHORTCUT_BLOCKING_STORAGE_KEY);
      }
      port.flush();
    } catch (_rollbackError) {
      // The in-memory state is not published after an incomplete durable
      // transaction. The next user action reloads the authoritative store.
    }
    return null;
  }
}
