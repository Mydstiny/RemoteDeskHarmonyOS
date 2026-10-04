/**
 * One classification of every remote-host field this version knows, shared
 * by cloud sync, local extensions and portable backups.
 *
 * Fields that are unknown to this version were written by a newer one. They
 * are kept verbatim when this version rewrites a host's synced displayconfig
 * (forward fields), so an account used with mixed app versions does not lose
 * them on every save. Fields this version knows are never forwarded: it
 * either writes them itself or keeps them out on purpose (secrets, device
 * trust, device-local 2FA bindings, local-only personalization). Device-local
 * extensions are not forwarded: they never sync, and a full backup rejects
 * keys it does not know.
 */
import { remoteHostCloudExtensionColumns } from './CloudTableAdapter';
import { remoteHostDeviceTrustKeys } from './RemoteHostDeviceTrustPolicy';

/** Key that nests the cloud extension inside displayconfig. */
export const REMOTE_HOST_CLOUD_EXTENSION_KEY: string = '_remoteDeskExtensionV1';

/** Secrets; never part of displayconfig and never forwarded. */
const REMOTE_HOST_SECRET_KEYS: string[] = [
  'password', 'passward', 'sshkeydata', 'sshkeypassphrase', 'sshproxypassword',
  'sshproxykeypassphrase'
];

/** Device-local bindings and choices; never forwarded across devices. */
const REMOTE_HOST_DEVICE_LOCAL_KEYS: string[] = [
  'rustdesktotpentryid', 'rustdesktotpautosubmit', 'rustdesktotpdeviceid',
  'localrustdeskphonechoice'
];

/** Fields that ride in displayconfig/extensions but are not cloud columns. */
const REMOTE_HOST_LOCAL_ONLY_KEYS: string[] = [
  'rustdeskproaccountid', 'rustdeskpropeerid', 'rustdeskproplatform', 'rustdeskpromanaged',
  'rustdeskprolastseenat', 'rustdeskprosyncerror', 'localpersonalizationversion',
  'localdisplayconfig', 'locallastconnected', 'locallasthealth', 'locallastlatency',
  'localrustdeskadaptiveorientation', 'localrustdeskdesktopflipmode',
  'localrustdeskprolastseenat', 'localrustdeskprosyncerror'
];

/** The six display settings every displayconfig save writes. */
const REMOTE_HOST_DISPLAY_KEYS: string[] = [
  'width', 'height', 'multiMonitor', 'monitorCount', 'dynamicResolution', 'colorDepth'
];

/** Upper bounds for forwarded data, so a corrupt row cannot grow without limit. */
const FORWARD_MAX_KEYS: number = 32;
const FORWARD_MAX_VALUE_LENGTH: number = 4096;

function lowerList(keys: string[]): string[] {
  return keys.map((key: string): string => key.toLowerCase());
}

let knownFieldKeysCache: string[] | null = null;

/** Every remote-host field key this version knows, lower-cased. */
export function remoteHostKnownFieldKeys(): string[] {
  if (knownFieldKeysCache !== null) { return knownFieldKeysCache.slice(); }
  const known: string[] = [];
  const groups: string[][] = [
    remoteHostCloudExtensionColumns(), remoteHostDeviceTrustKeys(), REMOTE_HOST_SECRET_KEYS,
    REMOTE_HOST_DEVICE_LOCAL_KEYS, REMOTE_HOST_LOCAL_ONLY_KEYS, REMOTE_HOST_DISPLAY_KEYS
  ];
  for (let g = 0; g < groups.length; g++) {
    const keys: string[] = lowerList(groups[g]);
    for (let k = 0; k < keys.length; k++) {
      if (known.indexOf(keys[k]) < 0) { known.push(keys[k]); }
    }
  }
  knownFieldKeysCache = known;
  return known.slice();
}

export function remoteHostFieldIsKnown(key: string, extraKnown: string[] = []): boolean {
  const lower: string = key.toLowerCase();
  return remoteHostKnownFieldKeys().indexOf(lower) >= 0 ||
    lowerList(extraKnown).indexOf(lower) >= 0;
}

function forwardValueAllowed(value: Object | undefined): boolean {
  if (typeof value === 'string') { return (value as string).length <= FORWARD_MAX_VALUE_LENGTH; }
  return typeof value === 'number' || typeof value === 'boolean';
}

/**
 * Copies into `next` the keys of `existing` that this version does not know
 * and `next` does not set. `extraKnown` lists further keys owned by the
 * caller (for example every display setting this version writes).
 */
export function withForwardRemoteHostFields(
  existing: Record<string, Object>,
  next: Record<string, Object>,
  extraKnown: string[]
): Record<string, Object> {
  const result: Record<string, Object> = {};
  const nextKeys: string[] = Object.keys(next);
  for (let i = 0; i < nextKeys.length; i++) { result[nextKeys[i]] = next[nextKeys[i]]; }
  const lowerNext: string[] = lowerList(nextKeys);
  const keys: string[] = Object.keys(existing);
  let forwarded: number = 0;
  for (let i = 0; i < keys.length && forwarded < FORWARD_MAX_KEYS; i++) {
    const key: string = keys[i];
    if (key === REMOTE_HOST_CLOUD_EXTENSION_KEY || lowerNext.indexOf(key.toLowerCase()) >= 0 ||
      remoteHostFieldIsKnown(key, extraKnown) || !forwardValueAllowed(existing[key])) {
      continue;
    }
    result[key] = existing[key];
    forwarded++;
  }
  return result;
}

function parseObject(raw: string): Record<string, Object> | null {
  try {
    const parsed: Object = JSON.parse(raw || '{}') as Object;
    if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) { return null; }
    return parsed as Record<string, Object>;
  } catch (_e) {
    return null;
  }
}

/**
 * displayconfig a save writes, with forward fields of the stored value kept
 * at the top level and inside the cloud extension. Anything unreadable falls
 * back to what this version would write anyway.
 */
export function remoteHostDisplayConfigWithForwardFields(
  storedRaw: string,
  nextRaw: string
): string {
  const stored: Record<string, Object> | null = parseObject(storedRaw);
  const next: Record<string, Object> | null = parseObject(nextRaw);
  if (stored === null || next === null) { return nextRaw; }
  const merged: Record<string, Object> = withForwardRemoteHostFields(stored, next, Object.keys(next));
  const storedExtension: Object | undefined = stored[REMOTE_HOST_CLOUD_EXTENSION_KEY];
  const nextExtension: Object | undefined = next[REMOTE_HOST_CLOUD_EXTENSION_KEY];
  if (storedExtension !== undefined && storedExtension !== null && typeof storedExtension === 'object' &&
    !Array.isArray(storedExtension)) {
    const base: Record<string, Object> = nextExtension !== undefined && nextExtension !== null &&
      typeof nextExtension === 'object' && !Array.isArray(nextExtension) ?
      nextExtension as Record<string, Object> : {};
    const extension: Record<string, Object> = withForwardRemoteHostFields(
      storedExtension as Record<string, Object>, base, []);
    if (Object.keys(extension).length > 0) {
      merged[REMOTE_HOST_CLOUD_EXTENSION_KEY] = extension as Object;
    }
  }
  return JSON.stringify(merged);
}
