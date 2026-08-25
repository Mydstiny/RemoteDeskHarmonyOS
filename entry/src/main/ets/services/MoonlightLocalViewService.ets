import {
  MoonlightAppCacheEntry,
  moonlightAppCacheEntryIsValid
} from '../model/MoonlightAppCache';
import {
  MoonlightAddress,
  MoonlightHost,
  MoonlightInputOverrides,
  MoonlightProfile,
  MoonlightStreamOverrides,
  MoonlightWakeOnLan,
  MOONLIGHT_DEFAULT_HTTPS_PORT,
  moonlightHostIsValid,
  moonlightProfileIsValid
} from '../model/MoonlightModels';
import { MoonlightRecord } from '../model/MoonlightRecord';
import { CloudStore } from './CloudStore';
import { AccountSessionLease, cloneAccountSessionLease } from './AccountScopePolicy';
import { MoonlightAppCacheResult, MoonlightAppCacheService } from './MoonlightAppCacheService';
import { moonlightRecordBusinessPayload } from './MoonlightRecordPolicy';
import { MoonlightRepository } from './MoonlightRepository';
import { MoonlightCatalogItem, moonlightCatalogItems } from './MoonlightUiPolicy';

export interface MoonlightHostLocalView {
  ok: boolean;
  code: string;
  lease: AccountSessionLease | null;
  host: MoonlightHost | null;
  paired: boolean;
  serverCertificateSha256: string;
  profiles: MoonlightProfile[];
  cacheEntries: MoonlightAppCacheEntry[];
  catalogItems: MoonlightCatalogItem[];
  updatedAt: number;
}

export interface MoonlightHostDirectoryView {
  ok: boolean;
  code: string;
  hosts: MoonlightHostLocalView[];
}

function emptyView(code: string,
  lease: AccountSessionLease | null = null): MoonlightHostLocalView {
  return {
    ok: false, code: code, lease: lease, host: null, paired: false,
    serverCertificateSha256: '',
    profiles: [], cacheEntries: [], catalogItems: [], updatedAt: 0
  };
}

export function moonlightHostFromRecord(record: MoonlightRecord): MoonlightHost | null {
  const payload: Record<string, Object> | null =
    moonlightRecordBusinessPayload(record);
  if (payload === null || !Array.isArray(payload['addresses']) ||
      payload['wakeOnLan'] === null || typeof payload['wakeOnLan'] !== 'object') {
    return null;
  }
  const host: MoonlightHost = {
    id: record.id,
    serverUuid: payload['serverUuid'] as string,
    displayName: payload['displayName'] as string,
    addresses: payload['addresses'] as MoonlightAddress[],
    preferredAddressKey: payload['preferredAddressKey'] as string,
    httpsPort: payload['httpsPort'] === undefined ? MOONLIGHT_DEFAULT_HTTPS_PORT :
      payload['httpsPort'] as number,
    hostType: payload['hostType'] as 'sunshine' | 'gamestream',
    wakeOnLan: payload['wakeOnLan'] as MoonlightWakeOnLan,
    locked: payload['locked'] === true,
    userOrder: payload['userOrder'] as number
  };
  return moonlightHostIsValid(host) ? host : null;
}

function profileFromRecord(record: MoonlightRecord): MoonlightProfile | null {
  const payload: Record<string, Object> | null =
    moonlightRecordBusinessPayload(record);
  if (payload === null || payload['streamOverrides'] === null ||
      typeof payload['streamOverrides'] !== 'object' ||
      payload['inputOverrides'] === null || typeof payload['inputOverrides'] !== 'object') {
    return null;
  }
  const profile: MoonlightProfile = {
    id: record.id,
    hostId: payload['hostId'] as string,
    appId: payload['appId'] as string,
    titleSnapshot: payload['titleSnapshot'] as string,
    streamOverrides: payload['streamOverrides'] as MoonlightStreamOverrides,
    inputOverrides: payload['inputOverrides'] as MoonlightInputOverrides,
    favorite: payload['favorite'] as boolean,
    userOrder: payload['userOrder'] as number,
    lastUsedAt: record.updatedAt
  };
  return moonlightProfileIsValid(profile) ? profile : null;
}

function trustFingerprintFromRecord(record: MoonlightRecord,
  hostId: string, serverUuid: string): string {
  if (record.recordType !== 'trust' || record.ownerId !== hostId) { return ''; }
  const payload: Record<string, Object> | null = moonlightRecordBusinessPayload(record);
  if (payload === null || payload['hostId'] !== hostId ||
      payload['serverUuid'] !== serverUuid ||
      typeof payload['serverCertificateSha256'] !== 'string') {
    return '';
  }
  const fingerprint: string = payload['serverCertificateSha256'] as string;
  return /^[0-9a-f]{64}$/.test(fingerprint) ? fingerprint : '';
}

export class MoonlightLocalViewService {
  private readonly port: CloudStore;
  private readonly repository: MoonlightRepository;
  private readonly cache: MoonlightAppCacheService;

  constructor(port: CloudStore) {
    this.port = port;
    this.repository = new MoonlightRepository(port);
    this.cache = new MoonlightAppCacheService(port);
  }

  loadHost(hostId: string, nowMs: number): MoonlightHostLocalView {
    const lease: AccountSessionLease | null = this.port.currentAccountLease();
    if (lease === null || hostId.trim() === '') { return emptyView('not_ready'); }
    const captured: AccountSessionLease = cloneAccountSessionLease(lease);
    const records: MoonlightRecord[] | null = this.repository.loadAll(captured);
    if (records === null) { return emptyView('record_read_failed', captured); }
    let host: MoonlightHost | null = null;
    let updatedAt: number = 0;
    let paired: boolean = false;
    let serverCertificateSha256: string = '';
    const profiles: MoonlightProfile[] = [];
    for (let i = 0; i < records.length; i++) {
      const record: MoonlightRecord = records[i];
      if (record.recordType === 'host' && record.id === hostId) {
        host = moonlightHostFromRecord(record);
        updatedAt = record.updatedAt;
      } else if (record.recordType === 'profile' && record.ownerId === hostId) {
        const profile: MoonlightProfile | null = profileFromRecord(record);
        if (profile !== null) { profiles.push(profile); }
      }
    }
    if (host === null) { return emptyView('host_not_found', captured); }
    for (let i = 0; i < records.length; i++) {
      const fingerprint: string = trustFingerprintFromRecord(
        records[i], hostId, host.serverUuid);
      if (fingerprint !== '') {
        paired = true;
        serverCertificateSha256 = fingerprint;
        break;
      }
    }
    const cacheResult: MoonlightAppCacheResult = this.cache.loadSnapshot(captured, hostId);
    if (!cacheResult.ok) {
      return {
        ok: true, code: 'cache_read_failed', lease: captured, host: host,
        paired: paired, serverCertificateSha256: serverCertificateSha256,
        profiles: profiles, cacheEntries: [], catalogItems: [],
        updatedAt: updatedAt
      };
    }
    return {
      ok: true, code: 'ok', lease: captured, host: host, paired: paired,
      serverCertificateSha256: serverCertificateSha256,
      profiles: profiles, cacheEntries: cacheResult.visibleEntries,
      catalogItems: moonlightCatalogItems(cacheResult.visibleEntries, profiles, nowMs),
      updatedAt: updatedAt
    };
  }

  loadHosts(nowMs: number): MoonlightHostDirectoryView {
    const lease: AccountSessionLease | null = this.port.currentAccountLease();
    if (lease === null) { return { ok: false, code: 'not_ready', hosts: [] }; }
    const captured: AccountSessionLease = cloneAccountSessionLease(lease);
    const records: MoonlightRecord[] | null = this.repository.loadAll(captured);
    if (records === null) { return { ok: false, code: 'record_read_failed', hosts: [] }; }
    const allCache: MoonlightAppCacheEntry[] | null =
      this.port.loadMoonlightAppCacheEntries(captured);
    const cacheValid: boolean = allCache !== null && this.port.isLeaseCurrent(captured);
    const cacheEntries: MoonlightAppCacheEntry[] = cacheValid ? allCache as MoonlightAppCacheEntry[] : [];
    if (cacheValid) {
      for (let i = 0; i < cacheEntries.length; i++) {
        if (!moonlightAppCacheEntryIsValid(cacheEntries[i]) ||
            cacheEntries[i].userId !== captured.ownerScopeId) {
          return { ok: false, code: 'cache_read_failed', hosts: [] };
        }
      }
    }
    const hosts: MoonlightHostLocalView[] = [];
    for (let i = 0; i < records.length; i++) {
      const record: MoonlightRecord = records[i];
      if (record.recordType !== 'host') { continue; }
      const host: MoonlightHost | null = moonlightHostFromRecord(record);
      if (host === null) { continue; }
      const profiles: MoonlightProfile[] = [];
      const hostCache: MoonlightAppCacheEntry[] = [];
      let paired: boolean = false;
      let serverCertificateSha256: string = '';
      for (let j = 0; j < records.length; j++) {
        if (records[j].recordType === 'profile' && records[j].ownerId === host.id) {
          const profile: MoonlightProfile | null = profileFromRecord(records[j]);
          if (profile !== null) { profiles.push(profile); }
        } else if (records[j].recordType === 'trust' && records[j].ownerId === host.id) {
          const fingerprint: string = trustFingerprintFromRecord(
            records[j], host.id, host.serverUuid);
          if (fingerprint !== '') {
            paired = true;
            serverCertificateSha256 = fingerprint;
          }
        }
      }
      for (let j = 0; j < cacheEntries.length; j++) {
        if (cacheEntries[j].hostId === host.id) { hostCache.push(cacheEntries[j]); }
      }
      hosts.push({
        ok: true, code: cacheValid ? 'ok' : 'cache_read_failed', lease: captured,
        host: host, paired: paired, serverCertificateSha256: serverCertificateSha256,
        profiles: profiles, cacheEntries: hostCache,
        catalogItems: moonlightCatalogItems(hostCache, profiles, nowMs), updatedAt: record.updatedAt
      });
    }
    hosts.sort((left: MoonlightHostLocalView, right: MoonlightHostLocalView): number => {
      if (left.host === null || right.host === null) { return 0; }
      if (left.host.userOrder !== right.host.userOrder) {
        return left.host.userOrder - right.host.userOrder;
      }
      return left.host.displayName < right.host.displayName ? -1 :
        (left.host.displayName === right.host.displayName ? 0 : 1);
    });
    return { ok: true, code: cacheValid ? 'ok' : 'cache_read_failed', hosts: hosts };
  }
}
