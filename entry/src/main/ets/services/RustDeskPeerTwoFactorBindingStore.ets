import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { RemoteHost } from '../model/RemoteHost';

export const RUSTDESK_PEER_2FA_BINDING_VERSION: number = 1;
export const RUSTDESK_PEER_2FA_LEGACY_MIGRATION_VERSION: number = 1;
export const RUSTDESK_PEER_2FA_PREFERENCES_NAME: string =
  'RemoteDesktopRustDeskPeerTwoFactorBindingsV1';

const DEVICE_IDENTITY_KEY: string = 'deviceIdentity';
const OWNER_BINDING_KEY_PREFIX: string = 'ownerBindings:';

export interface RustDeskPeerTwoFactorBinding {
  version: number
  ownerScopeId: string
  hostId: string
  endpointIdentity: string
  entryId: string
  autoSubmit: boolean
  deviceIdentity: string
  source: string
  migrationVersion: number
  updatedAt: number
}

interface RustDeskPeerTwoFactorBindingEnvelope {
  version: number
  ownerScopeId: string
  bindings: RustDeskPeerTwoFactorBinding[]
  migrationMarkers: Record<string, number>
}

export interface RustDeskPeerTwoFactorPreferenceRead {
  ok: boolean
  value: string
}

export interface RustDeskPeerTwoFactorPreferenceAdapter {
  read(context: common.Context, storeName: string, key: string): RustDeskPeerTwoFactorPreferenceRead
  write(context: common.Context, storeName: string, key: string, value: string): boolean
}

class HarmonyRustDeskPeerTwoFactorPreferenceAdapter implements
  RustDeskPeerTwoFactorPreferenceAdapter {
  read(context: common.Context, storeName: string,
    key: string): RustDeskPeerTwoFactorPreferenceRead {
    try {
      const prefs: preferences.Preferences = preferences.getPreferencesSync(
        context, { name: storeName });
      const value: Object = prefs.getSync(key, '') as Object;
      return typeof value === 'string' ?
        { ok: true, value: value as string } : { ok: false, value: '' };
    } catch (_error) {
      return { ok: false, value: '' };
    }
  }

  write(context: common.Context, storeName: string,
    key: string, value: string): boolean {
    try {
      const prefs: preferences.Preferences = preferences.getPreferencesSync(
        context, { name: storeName });
      prefs.putSync(key, value);
      prefs.flushSync();
      return true;
    } catch (_error) {
      return false;
    }
  }
}

let peerTwoFactorPreferenceAdapter: RustDeskPeerTwoFactorPreferenceAdapter =
  new HarmonyRustDeskPeerTwoFactorPreferenceAdapter();

export function setRustDeskPeerTwoFactorPreferenceAdapterForTest(
  adapter: RustDeskPeerTwoFactorPreferenceAdapter | null
): void {
  peerTwoFactorPreferenceAdapter = adapter === null ?
    new HarmonyRustDeskPeerTwoFactorPreferenceAdapter() : adapter;
}

function normalized(value: string): string {
  return value.trim();
}

function bindingKey(hostId: string, endpointIdentity: string): string {
  return normalized(hostId) + '\u001f' + normalized(endpointIdentity);
}

function migrationMarkerKey(hostId: string, endpointIdentity: string,
  source: string): string {
  return bindingKey(hostId, endpointIdentity) + '\u001f' + normalized(source);
}

function cloneBinding(binding: RustDeskPeerTwoFactorBinding): RustDeskPeerTwoFactorBinding {
  return {
    version: binding.version,
    ownerScopeId: binding.ownerScopeId,
    hostId: binding.hostId,
    endpointIdentity: binding.endpointIdentity,
    entryId: binding.entryId,
    autoSubmit: binding.autoSubmit,
    deviceIdentity: binding.deviceIdentity,
    source: binding.source,
    migrationVersion: binding.migrationVersion,
    updatedAt: binding.updatedAt
  };
}

function validBinding(binding: RustDeskPeerTwoFactorBinding): boolean {
  return binding.version === RUSTDESK_PEER_2FA_BINDING_VERSION &&
    normalized(binding.ownerScopeId) !== '' && normalized(binding.hostId) !== '' &&
    normalized(binding.endpointIdentity) !== '' && normalized(binding.entryId) !== '' &&
    normalized(binding.deviceIdentity) !== '' &&
    Number.isFinite(binding.migrationVersion) && binding.migrationVersion >= 0 &&
    Number.isFinite(binding.updatedAt) && binding.updatedAt >= 0;
}

function stringValue(row: Record<string, Object>, key: string): string {
  return typeof row[key] === 'string' ? row[key] as string : '';
}

function numberValue(row: Record<string, Object>, key: string, fallback: number): number {
  return typeof row[key] === 'number' && Number.isFinite(row[key] as number) ?
    row[key] as number : fallback;
}

function bindingFromObject(value: Object): RustDeskPeerTwoFactorBinding | null {
  if (!value || typeof value !== 'object' || Array.isArray(value)) { return null; }
  const row: Record<string, Object> = value as Record<string, Object>;
  const binding: RustDeskPeerTwoFactorBinding = {
    version: numberValue(row, 'version', 0),
    ownerScopeId: stringValue(row, 'ownerScopeId'),
    hostId: stringValue(row, 'hostId'),
    endpointIdentity: stringValue(row, 'endpointIdentity'),
    entryId: stringValue(row, 'entryId'),
    autoSubmit: row['autoSubmit'] === true,
    deviceIdentity: stringValue(row, 'deviceIdentity'),
    source: stringValue(row, 'source'),
    migrationVersion: numberValue(row, 'migrationVersion', 0),
    updatedAt: numberValue(row, 'updatedAt', 0)
  };
  return validBinding(binding) ? binding : null;
}

function generateDeviceIdentity(): string {
  return 'rdh-device-' + RemoteHost.generateId();
}

export function rustDeskPeerTwoFactorEndpointIdentity(host: RemoteHost): string {
  if (host.protocol !== 'rustdesk' || normalized(host.id) === '') { return ''; }
  const peerIdentity: string = normalized(host.rustdeskProPeerId) !== '' ?
    normalized(host.rustdeskProPeerId) :
    (normalized(host.lanDiscoveryIdentity) !== '' ?
      normalized(host.lanDiscoveryIdentity) : normalized(host.host));
  if (peerIdentity === '') { return ''; }
  return 'peer=' + peerIdentity + '\u001frelay=' + normalized(host.rustdeskRelayId) +
    '\u001faccount=' + normalized(host.rustdeskAccountId) +
    '\u001fproAccount=' + normalized(host.rustdeskProAccountId) +
    '\u001fmanaged=' + (host.rustdeskProManaged ? '1' : '0');
}

export function scrubRustDeskPeerTwoFactorRuntime(host: RemoteHost): void {
  host.rustdeskTotpEntryId = '';
  host.rustdeskTotpAutoSubmit = false;
  host.rustdeskTotpLegacyDeviceId = '';
  host.rustdeskTotpLegacySource = '';
}

export function copyRustDeskPeerTwoFactorRuntime(
  source: RemoteHost, target: RemoteHost
): void {
  target.rustdeskTotpEntryId = source.rustdeskTotpEntryId;
  target.rustdeskTotpAutoSubmit = source.rustdeskTotpAutoSubmit;
  target.rustdeskTotpLegacyDeviceId = source.rustdeskTotpLegacyDeviceId;
  target.rustdeskTotpLegacySource = source.rustdeskTotpLegacySource;
}

export function rustDeskPeerTwoFactorBindingFromHost(
  ownerScopeId: string, host: RemoteHost
): RustDeskPeerTwoFactorBinding | null {
  const owner: string = normalized(ownerScopeId);
  const endpoint: string = rustDeskPeerTwoFactorEndpointIdentity(host);
  const entryId: string = normalized(host.rustdeskTotpEntryId);
  if (owner === '' || endpoint === '' || entryId === '') { return null; }
  return {
    version: RUSTDESK_PEER_2FA_BINDING_VERSION,
    ownerScopeId: owner,
    hostId: normalized(host.id),
    endpointIdentity: endpoint,
    entryId,
    autoSubmit: host.rustdeskTotpAutoSubmit,
    deviceIdentity: normalized(host.rustdeskTotpLegacyDeviceId),
    source: normalized(host.rustdeskTotpLegacySource) === '' ?
      'manual' : 'legacy:' + normalized(host.rustdeskTotpLegacySource),
    migrationVersion: normalized(host.rustdeskTotpLegacySource) === '' ?
      0 : RUSTDESK_PEER_2FA_LEGACY_MIGRATION_VERSION,
    updatedAt: Date.now()
  };
}

export function hydrateRustDeskPeerTwoFactorHost(
  host: RemoteHost, binding: RustDeskPeerTwoFactorBinding | null,
  entryExists: (entryId: string) => boolean,
  currentDeviceIdentity: string
): boolean {
  scrubRustDeskPeerTwoFactorRuntime(host);
  if (binding === null || !validBinding(binding) || host.protocol !== 'rustdesk' ||
    normalized(binding.hostId) !== normalized(host.id) ||
    normalized(binding.endpointIdentity) !== rustDeskPeerTwoFactorEndpointIdentity(host) ||
    normalized(binding.deviceIdentity) !== normalized(currentDeviceIdentity) ||
    !entryExists(binding.entryId)) {
    return false;
  }
  host.rustdeskTotpEntryId = binding.entryId;
  host.rustdeskTotpAutoSubmit = binding.autoSubmit;
  return true;
}

/**
 * A missing TOTP entry is destructive evidence only after KeyVault has loaded
 * the current account-scoped snapshot. During startup/scope transitions an
 * empty in-memory map is merely "not loaded yet" and must preserve the binding.
 */
export function shouldRemoveDanglingRustDeskPeerTwoFactorBinding(
  removeDangling: boolean, totpSnapshotReady: boolean, entryExists: boolean
): boolean {
  return removeDangling && totpSnapshotReady && !entryExists;
}

export class RustDeskPeerTwoFactorBindingMemory {
  protected ownerScopeId: string = '';
  protected deviceIdentityValue: string = '';
  protected bindings: Map<string, RustDeskPeerTwoFactorBinding> = new Map();
  protected migrationMarkers: Map<string, number> = new Map();
  protected loaded: boolean = false;

  bind(ownerScopeId: string, deviceIdentity: string = 'test-device'): boolean {
    const owner: string = normalized(ownerScopeId);
    const device: string = normalized(deviceIdentity);
    if (owner === '' || device === '') { return false; }
    this.ownerScopeId = owner;
    this.deviceIdentityValue = device;
    this.bindings.clear();
    this.migrationMarkers.clear();
    this.loaded = true;
    return true;
  }

  isLoaded(): boolean { return this.loaded; }

  clearMemoryForScopeTransition(): void {
    this.ownerScopeId = '';
    this.deviceIdentityValue = '';
    this.bindings.clear();
    this.migrationMarkers.clear();
    this.loaded = false;
  }

  currentOwnerScopeId(): string { return this.ownerScopeId; }

  deviceIdentity(): string { return this.deviceIdentityValue; }

  save(binding: RustDeskPeerTwoFactorBinding): boolean {
    const next: RustDeskPeerTwoFactorBinding = cloneBinding(binding);
    next.ownerScopeId = normalized(next.ownerScopeId);
    next.hostId = normalized(next.hostId);
    next.endpointIdentity = normalized(next.endpointIdentity);
    next.entryId = normalized(next.entryId);
    next.deviceIdentity = normalized(next.deviceIdentity);
    next.source = normalized(next.source) === '' ? 'manual' : normalized(next.source);
    next.version = RUSTDESK_PEER_2FA_BINDING_VERSION;
    next.updatedAt = Number.isFinite(next.updatedAt) && next.updatedAt > 0 ?
      Math.floor(next.updatedAt) : Date.now();
    if (!this.loaded || next.ownerScopeId !== this.ownerScopeId ||
      next.deviceIdentity !== this.deviceIdentityValue || !validBinding(next)) {
      return false;
    }
    this.bindings.set(bindingKey(next.hostId, next.endpointIdentity), next);
    if (next.migrationVersion > 0) {
      this.migrationMarkers.set(migrationMarkerKey(
        next.hostId, next.endpointIdentity,
        next.source.startsWith('legacy:') ? next.source.substring('legacy:'.length) : next.source),
      next.migrationVersion);
    }
    return true;
  }

  get(hostId: string, endpointIdentity: string): RustDeskPeerTwoFactorBinding | null {
    if (!this.loaded) { return null; }
    const found: RustDeskPeerTwoFactorBinding | undefined =
      this.bindings.get(bindingKey(hostId, endpointIdentity));
    return found === undefined ? null : cloneBinding(found);
  }

  list(): RustDeskPeerTwoFactorBinding[] {
    if (!this.loaded) { return []; }
    const result: RustDeskPeerTwoFactorBinding[] = [];
    this.bindings.forEach((binding: RustDeskPeerTwoFactorBinding): void => {
      result.push(cloneBinding(binding));
    });
    return result;
  }

  remove(hostId: string, endpointIdentity: string): boolean {
    if (!this.loaded) { return false; }
    this.bindings.delete(bindingKey(hostId, endpointIdentity));
    return true;
  }

  removeHost(hostId: string): boolean {
    if (!this.loaded) { return false; }
    const prefix: string = normalized(hostId) + '\u001f';
    const keys: string[] = [];
    this.bindings.forEach((_binding: RustDeskPeerTwoFactorBinding, key: string): void => {
      if (key.indexOf(prefix) === 0) { keys.push(key); }
    });
    for (let i = 0; i < keys.length; i++) { this.bindings.delete(keys[i]); }
    return true;
  }

  removeEntry(entryId: string): boolean {
    if (!this.loaded) { return false; }
    const normalizedEntry: string = normalized(entryId);
    const keys: string[] = [];
    this.bindings.forEach((binding: RustDeskPeerTwoFactorBinding, key: string): void => {
      if (binding.entryId === normalizedEntry) { keys.push(key); }
    });
    for (let i = 0; i < keys.length; i++) { this.bindings.delete(keys[i]); }
    return true;
  }

  legacyMigrationVersion(hostId: string, endpointIdentity: string,
    source: string): number {
    if (!this.loaded) { return 0; }
    return this.migrationMarkers.get(migrationMarkerKey(
      hostId, endpointIdentity, source)) ?? 0;
  }

  setLegacyMigrationMarkerForTest(hostId: string, endpointIdentity: string,
    source: string, version: number): void {
    this.migrationMarkers.set(migrationMarkerKey(hostId, endpointIdentity, source), version);
  }
}

export class RustDeskPeerTwoFactorBindingStore extends
  RustDeskPeerTwoFactorBindingMemory {
  private static instance: RustDeskPeerTwoFactorBindingStore;
  private context: common.Context | null = null;
  private persistenceFailure: string = '';
  private testMode: boolean = false;

  static getInstance(): RustDeskPeerTwoFactorBindingStore {
    if (!RustDeskPeerTwoFactorBindingStore.instance) {
      RustDeskPeerTwoFactorBindingStore.instance =
        new RustDeskPeerTwoFactorBindingStore();
    }
    return RustDeskPeerTwoFactorBindingStore.instance;
  }

  bindContext(context: common.Context, ownerScopeId: string): boolean {
    const owner: string = normalized(ownerScopeId);
    if (owner === '') { return false; }
    this.context = context;
    this.testMode = false;
    this.ownerScopeId = owner;
    this.bindings.clear();
    this.migrationMarkers.clear();
    this.loaded = false;
    const deviceRead: RustDeskPeerTwoFactorPreferenceRead =
      peerTwoFactorPreferenceAdapter.read(
        context, RUSTDESK_PEER_2FA_PREFERENCES_NAME, DEVICE_IDENTITY_KEY);
    if (!deviceRead.ok) { return false; }
    let device: string = normalized(deviceRead.value);
    if (device === '') {
      device = generateDeviceIdentity();
      if (!peerTwoFactorPreferenceAdapter.write(
        context, RUSTDESK_PEER_2FA_PREFERENCES_NAME, DEVICE_IDENTITY_KEY, device)) {
        return false;
      }
    }
    this.deviceIdentityValue = device;
    const read: RustDeskPeerTwoFactorPreferenceRead =
      peerTwoFactorPreferenceAdapter.read(
        context, RUSTDESK_PEER_2FA_PREFERENCES_NAME, this.ownerPreferenceKey());
    if (!read.ok) { return false; }
    if (read.value === '') {
      this.loaded = true;
      return true;
    }
    return this.decode(read.value);
  }

  bindForTest(ownerScopeId: string): void {
    this.context = null;
    this.testMode = true;
    this.persistenceFailure = '';
    super.bind(ownerScopeId, 'test-device');
  }

  setPersistenceFailureForTest(stage: string): void {
    this.persistenceFailure = stage;
  }

  save(binding: RustDeskPeerTwoFactorBinding): boolean {
    const previousBindings: RustDeskPeerTwoFactorBinding[] = this.list();
    const previousMarkers: Record<string, number> = this.markerSnapshot();
    if (!super.save(binding)) { return false; }
    if (this.persist()) { return true; }
    this.restoreSnapshots(previousBindings, previousMarkers);
    this.loaded = false;
    return false;
  }

  remove(hostId: string, endpointIdentity: string): boolean {
    return this.mutateAndPersist((): boolean => super.remove(hostId, endpointIdentity));
  }

  removeHost(hostId: string): boolean {
    return this.mutateAndPersist((): boolean => super.removeHost(hostId));
  }

  removeEntry(entryId: string): boolean {
    return this.mutateAndPersist((): boolean => super.removeEntry(entryId));
  }

  private mutateAndPersist(mutation: () => boolean): boolean {
    const previousBindings: RustDeskPeerTwoFactorBinding[] = this.list();
    const previousMarkers: Record<string, number> = this.markerSnapshot();
    if (!mutation()) { return false; }
    if (this.persist()) { return true; }
    this.restoreSnapshots(previousBindings, previousMarkers);
    this.loaded = false;
    return false;
  }

  private ownerPreferenceKey(): string {
    return OWNER_BINDING_KEY_PREFIX + encodeURIComponent(this.ownerScopeId);
  }

  private persist(): boolean {
    if (!this.loaded || this.persistenceFailure === 'persist') { return false; }
    if (this.testMode) { return true; }
    if (this.context === null) { return false; }
    const envelope: RustDeskPeerTwoFactorBindingEnvelope = {
      version: RUSTDESK_PEER_2FA_BINDING_VERSION,
      ownerScopeId: this.ownerScopeId,
      bindings: this.list(),
      migrationMarkers: this.markerSnapshot()
    };
    return peerTwoFactorPreferenceAdapter.write(
      this.context, RUSTDESK_PEER_2FA_PREFERENCES_NAME,
      this.ownerPreferenceKey(), JSON.stringify(envelope));
  }

  private decode(raw: string): boolean {
    try {
      const parsed: Object = JSON.parse(raw) as Object;
      if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) { return false; }
      const row: Record<string, Object> = parsed as Record<string, Object>;
      if (numberValue(row, 'version', 0) !== RUSTDESK_PEER_2FA_BINDING_VERSION ||
        stringValue(row, 'ownerScopeId') !== this.ownerScopeId ||
        !Array.isArray(row['bindings'])) {
        return false;
      }
      const bindingRows: Object[] = row['bindings'] as Object[];
      const next: Map<string, RustDeskPeerTwoFactorBinding> = new Map();
      for (let i = 0; i < bindingRows.length; i++) {
        const binding: RustDeskPeerTwoFactorBinding | null =
          bindingFromObject(bindingRows[i]);
        if (binding === null || binding.ownerScopeId !== this.ownerScopeId ||
          binding.deviceIdentity !== this.deviceIdentityValue) {
          return false;
        }
        next.set(bindingKey(binding.hostId, binding.endpointIdentity), binding);
      }
      const nextMarkers: Map<string, number> = new Map();
      const markersValue: Object = row['migrationMarkers'];
      if (markersValue && typeof markersValue === 'object' && !Array.isArray(markersValue)) {
        const markers: Record<string, Object> = markersValue as Record<string, Object>;
        const keys: string[] = Object.keys(markers);
        for (let i = 0; i < keys.length; i++) {
          const marker: Object = markers[keys[i]];
          if (typeof marker !== 'number' || !Number.isFinite(marker as number) ||
            (marker as number) < 0) { return false; }
          nextMarkers.set(keys[i], Math.floor(marker as number));
        }
      }
      this.bindings = next;
      this.migrationMarkers = nextMarkers;
      this.loaded = true;
      return true;
    } catch (_error) {
      return false;
    }
  }

  private markerSnapshot(): Record<string, number> {
    const result: Record<string, number> = {};
    this.migrationMarkers.forEach((version: number, key: string): void => {
      result[key] = version;
    });
    return result;
  }

  private restoreSnapshots(bindings: RustDeskPeerTwoFactorBinding[],
    markers: Record<string, number>): void {
    this.bindings.clear();
    for (let i = 0; i < bindings.length; i++) {
      const binding: RustDeskPeerTwoFactorBinding = bindings[i];
      this.bindings.set(bindingKey(binding.hostId, binding.endpointIdentity),
        cloneBinding(binding));
    }
    this.migrationMarkers.clear();
    const keys: string[] = Object.keys(markers);
    for (let i = 0; i < keys.length; i++) {
      this.migrationMarkers.set(keys[i], markers[keys[i]]);
    }
  }
}
