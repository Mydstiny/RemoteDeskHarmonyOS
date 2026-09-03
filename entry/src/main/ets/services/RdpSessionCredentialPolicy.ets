import {
  RemoteHost,
  normalizeRdpAuthMode,
  normalizeRdpCredentialStorageMode,
  rdpRouteIdentity
} from '../model/RemoteHost';
import {
  decodeRemoteHostDisplayPayload,
  encodeRemoteHostDisplayPayload,
  RemoteHostDisplayPayload
} from './CloudTableAdapter';

export interface RdpConnectTimeRowSanitization {
  row: Record<string, string>;
  changed: boolean;
  connectTime: boolean;
}

export function connectTimeRdpHostIdsFromRows(
  rows: Array<Record<string, string>>
): string[] {
  const result: string[] = [];
  for (let index: number = 0; index < rows.length; index++) {
    if (!remoteHostRowUsesConnectTimeRdpCredentials(rows[index])) { continue; }
    const id: string = (rows[index]['id'] || '').trim();
    if (id !== '' && result.indexOf(id) < 0) { result.push(id); }
  }
  return result;
}

function copyStringRecord(source: Record<string, string>): Record<string, string> {
  const result: Record<string, string> = {};
  const keys: string[] = Object.keys(source);
  for (let i: number = 0; i < keys.length; i++) {
    result[keys[i]] = source[keys[i]];
  }
  return result;
}

export function remoteHostRowUsesConnectTimeRdpCredentials(
  row: Record<string, string>
): boolean {
  if ((row['protocol'] || '').trim().toLowerCase() !== 'rdp') { return false; }
  const payload: RemoteHostDisplayPayload =
    decodeRemoteHostDisplayPayload(row['displayconfig'] || '{}');
  return normalizeRdpCredentialStorageMode(
    payload.extension['rdpcredentialstoragemode'] || 'saved') === 'connect_time';
}

/** Resolve policy from the effective row while preserving partial-merge semantics. */
export function remoteHostMergeUsesConnectTimeRdpCredentials(
  existing: Record<string, string>,
  incoming: Record<string, string>
): boolean {
  const effective: Record<string, string> = copyStringRecord(existing);
  const keys: string[] = Object.keys(incoming);
  for (let index: number = 0; index < keys.length; index++) {
    effective[keys[index]] = incoming[keys[index]];
  }
  return remoteHostRowUsesConnectTimeRdpCredentials(effective);
}

/** Scrub malformed imported/cloud rows before any password decrypt or durable write. */
export function sanitizeRemoteHostRowForRdpCredentialPolicy(
  source: Record<string, string>
): RdpConnectTimeRowSanitization {
  const row: Record<string, string> = copyStringRecord(source);
  const connectTime: boolean = remoteHostRowUsesConnectTimeRdpCredentials(row);
  if (!connectTime) { return { row, changed: false, connectTime: false }; }
  let changed: boolean = false;
  const clearIfPresent = (key: string): void => {
    if (row[key] === undefined) { return; }
    if (row[key] !== '') { changed = true; }
    row[key] = '';
  };
  clearIfPresent('username');
  clearIfPresent('password');
  clearIfPresent('passward');
  clearIfPresent('rdpcredentialid');
  const payload: RemoteHostDisplayPayload =
    decodeRemoteHostDisplayPayload(row['displayconfig'] || '{}');
  if ((payload.extension['rdpcredentialid'] || '') !== '') {
    const extension: Record<string, string> = copyStringRecord(payload.extension);
    extension['rdpcredentialid'] = '';
    row['displayconfig'] = encodeRemoteHostDisplayPayload(
      payload.displayConfigJson, extension);
    changed = true;
  }
  return { row, changed, connectTime: true };
}

/** Apply the same fail-closed rule to portable local-extension payload rows. */
export function sanitizeRemoteHostExtensionForRdpCredentialPolicy(
  source: Record<string, string>,
  connectTimeHostIds: string[] = []
): RdpConnectTimeRowSanitization {
  const row: Record<string, string> = copyStringRecord(source);
  if ((row['tablename'] || '') !== 'remotehosts') {
    return { row, changed: false, connectTime: false };
  }
  const recordId: string = (row['recordid'] || '').trim();
  const knownConnectTime: boolean = connectTimeHostIds.indexOf(recordId) >= 0;
  try {
    const payload: Record<string, string> =
      JSON.parse(row['payload'] || '{}') as Record<string, string>;
    const connectTime: boolean = knownConnectTime ||
      normalizeRdpCredentialStorageMode(
        payload['rdpcredentialstoragemode'] || 'saved') === 'connect_time';
    if (!connectTime) {
      return { row, changed: false, connectTime };
    }
    const safePayload: Record<string, string> = copyStringRecord(payload);
    let changed: boolean = false;
    const clearIfPresent = (key: string): void => {
      if (safePayload[key] === undefined) { return; }
      if (safePayload[key] !== '') { changed = true; }
      safePayload[key] = '';
    };
    clearIfPresent('username');
    clearIfPresent('password');
    clearIfPresent('passward');
    clearIfPresent('rdpcredentialid');
    if (!changed) {
      return { row, changed: false, connectTime: true };
    }
    row['payload'] = JSON.stringify(safePayload);
    return { row, changed: true, connectTime: true };
  } catch (_error) {
    if (!knownConnectTime) {
      return { row, changed: false, connectTime: false };
    }
    const changed: boolean = row['payload'] !== '{}';
    row['payload'] = '{}';
    return { row, changed, connectTime: true };
  }
}

export function rdpSessionCredentialRequiredForNewConnection(
  host: RemoteHost,
  restoringEstablishedSession: boolean
): boolean {
  return !restoringEstablishedSession && host.protocol === 'rdp' &&
    normalizeRdpAuthMode(host.rdpAuthMode) === 'password' &&
    normalizeRdpCredentialStorageMode(host.rdpCredentialStorageMode) ===
      'connect_time';
}

/**
 * A connection-time credential is no longer allowed to survive after the
 * owning RemoteDesktop window goes to the background before native connect.
 * Only a confirmed protocol connection or registry restore is established.
 * A positive native session id that is still connecting remains cancellable.
 */
export function shouldInvalidatePendingRdpSessionCredentialOnBackground(
  host: RemoteHost | null,
  isBackground: boolean,
  protocolConnected: boolean,
  restoringEstablishedSession: boolean
): boolean {
  return shouldInvalidatePendingRdpSessionCredentialRouteOnBackground(
    host !== null && rdpSessionCredentialRequiredForNewConnection(host, false),
    isBackground, protocolConnected, restoringEstablishedSession);
}

/** Same lifecycle rule when the route binding is staged before its first await. */
export function shouldInvalidatePendingRdpSessionCredentialRouteOnBackground(
  credentialRoutePending: boolean,
  isBackground: boolean,
  protocolConnected: boolean,
  restoringEstablishedSession: boolean
): boolean {
  return credentialRoutePending && isBackground && !protocolConnected &&
    !restoringEstablishedSession;
}

/** Final page-lifecycle fence immediately before the synchronous NAPI call. */
export function rdpSessionCredentialNativeAdmissionIsCurrent(
  attemptId: number,
  currentAttemptId: number,
  isBackground: boolean,
  cleanupStarted: boolean
): boolean {
  return Number.isSafeInteger(attemptId) && attemptId > 0 &&
    attemptId === currentAttemptId && !isBackground && !cleanupStarted;
}

/**
 * Final, synchronous admission check immediately before a one-shot credential
 * is moved into the native connection configuration.
 */
export function rdpSessionCredentialBindingIsCurrent(
  pendingHost: RemoteHost,
  liveHost: RemoteHost | undefined,
  capturedOwnerScopeId: string,
  capturedGeneration: number,
  currentOwnerScopeId: string,
  currentGeneration: number
): boolean {
  if (!rdpSessionCredentialRequiredForNewConnection(pendingHost, false) ||
    liveHost === undefined ||
    !rdpSessionCredentialRequiredForNewConnection(liveHost, false)) {
    return false;
  }
  const owner: string = currentOwnerScopeId.trim();
  return owner !== '' && Number.isSafeInteger(currentGeneration) &&
    currentGeneration > 0 &&
    capturedOwnerScopeId.trim() === owner &&
    capturedGeneration === currentGeneration &&
    pendingHost.userId.trim() === owner && liveHost.userId.trim() === owner &&
    pendingHost.id.trim() !== '' && pendingHost.id === liveHost.id &&
    rdpRouteIdentity(pendingHost) === rdpRouteIdentity(liveHost);
}
