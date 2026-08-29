import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';
import {
  MoonlightAddress,
  MoonlightHost,
  MoonlightHostType,
  MoonlightWakeOnLan,
  MOONLIGHT_DEFAULT_HTTPS_PORT,
  canonicalMoonlightAddress,
  moonlightAddressKey,
  moonlightHostIsValid
} from '../model/MoonlightModels';
import { MoonlightRecord } from '../model/MoonlightRecord';
import { MoonlightAppCacheEntry } from '../model/MoonlightAppCache';
import { MoonlightAppCachePort } from './MoonlightAppCacheService';
import { AccountSessionLease, cloneAccountSessionLease } from './AccountScopePolicy';
import {
  MoonlightHostAddOperationKey,
  MoonlightHostAddState
} from './MoonlightHostAddFlowPolicy';
import {
  MoonlightRecordMeta,
  moonlightMutableFieldPaths,
  moonlightPayloadWithMeta,
  moonlightRecordBusinessPayload,
  moonlightRecordPayloadHashSha256
} from './MoonlightRecordPolicy';
import {
  MoonlightRepository,
  MoonlightRepositoryBatchResult,
  MoonlightRepositoryBatchMutation,
  MoonlightRepositoryPort,
  MoonlightRepositoryResult
} from './MoonlightRepository';

export type MoonlightLocalHostSaveCode =
  'ok' | 'invalid_state' | 'not_ready' | 'stale_lease' | 'duplicate' |
  'local_write_failed' | 'readback_failed' | 'trust_write_failed' | 'rollback_failed';

export interface MoonlightLocalHostSaveResult {
  ok: boolean;
  code: MoonlightLocalHostSaveCode;
  localCommitted: boolean;
  commitState: 'committed' | 'not_committed' | 'partial' | 'uncertain';
  hostId: string;
  trustRecordId: string;
  errorText: string;
}

export type MoonlightLocalHostMutationCode =
  'ok' | 'invalid_request' | 'not_ready' | 'stale_lease' | 'not_found' |
  'local_write_failed' | 'cache_cleanup_failed' | 'rollback_failed' |
  'pending_local_verification' | 'unchanged';

export interface MoonlightLocalHostMutationResult {
  ok: boolean;
  code: MoonlightLocalHostMutationCode;
  hostId: string;
  localCommitted: boolean;
  errorText: string;
}

function mutationResult(ok: boolean, code: MoonlightLocalHostMutationCode,
  hostId: string, localCommitted: boolean, errorText: string = ''):
  MoonlightLocalHostMutationResult {
  return {
    ok: ok, code: code, hostId: hostId,
    localCommitted: localCommitted, errorText: errorText
  };
}

function mutationFromRepository(written: MoonlightRepositoryResult,
  hostId: string, errorText: string): MoonlightLocalHostMutationResult {
  if (written.ok) {
    return mutationResult(true, written.code === 'unchanged' ?
      'unchanged' : 'ok', hostId, written.localCommitted);
  }
  if (written.localCommitted && written.code === 'readback_failed') {
    return mutationResult(true, 'pending_local_verification', hostId, true,
      '本地修改已保存，正在后台核验');
  }
  return mutationResult(false, written.code === 'stale_lease' ?
    'stale_lease' : 'local_write_failed', hostId,
    written.localCommitted, errorText);
}

function saveResult(
  ok: boolean,
  code: MoonlightLocalHostSaveCode,
  localCommitted: boolean,
  hostId: string = '',
  trustRecordId: string = '',
  errorText: string = '',
  commitState: 'committed' | 'not_committed' | 'partial' | 'uncertain' =
    localCommitted ? 'committed' : 'not_committed'
): MoonlightLocalHostSaveResult {
  return {
    ok: ok,
    code: code,
    localCommitted: localCommitted,
    commitState: commitState,
    hostId: hostId,
    trustRecordId: trustRecordId,
    errorText: errorText
  };
}

function sha256Hex(value: string): string {
  const md = cryptoFramework.createMd('SHA256');
  md.updateSync({ data: new util.TextEncoder().encode(value) });
  const bytes: Uint8Array = md.digestSync().data;
  let result: string = '';
  for (let index = 0; index < bytes.length; index++) {
    result += bytes[index].toString(16).padStart(2, '0');
  }
  return result;
}

function stableId(prefix: string, value: string): string {
  return prefix + sha256Hex(value);
}

function validNow(nowMs: number): boolean {
  return Number.isSafeInteger(nowMs) && nowMs > 0;
}

function copyAddress(value: MoonlightAddress): MoonlightAddress {
  return canonicalMoonlightAddress(value);
}

function legacyAddressKey(value: MoonlightAddress): string {
  return value.family + '|' + value.host.trim().toLowerCase() + '|' + value.port.toString();
}

function canonicalPreferredAddressKey(
  addresses: MoonlightAddress[], preferredAddressKey: string
): string {
  if (preferredAddressKey === '') { return ''; }
  for (let index = 0; index < addresses.length; index++) {
    if (moonlightAddressKey(addresses[index]) === preferredAddressKey ||
        legacyAddressKey(addresses[index]) === preferredAddressKey) {
      return moonlightAddressKey(copyAddress(addresses[index]));
    }
  }
  return preferredAddressKey;
}

function recordWithId(records: MoonlightRecord[], id: string): MoonlightRecord | null {
  for (let index = 0; index < records.length; index++) {
    if (records[index].id === id) { return records[index]; }
  }
  return null;
}

function serverUuidFromHostRecord(record: MoonlightRecord): string {
  if (record.recordType !== 'host') { return ''; }
  const payload: Record<string, Object> | null = moonlightRecordBusinessPayload(record);
  return payload === null || typeof payload['serverUuid'] !== 'string'
    ? '' : payload['serverUuid'] as string;
}

function hostFromRecord(record: MoonlightRecord): MoonlightHost | null {
  if (record.recordType !== 'host' || record.deletedAt > 0) { return null; }
  const payload: Record<string, Object> | null = moonlightRecordBusinessPayload(record);
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
    httpsPort: typeof payload['httpsPort'] === 'number'
      ? payload['httpsPort'] as number : MOONLIGHT_DEFAULT_HTTPS_PORT,
    hostType: payload['hostType'] as MoonlightHostType,
    wakeOnLan: payload['wakeOnLan'] as MoonlightWakeOnLan,
    locked: payload['locked'] === true,
    userOrder: payload['userOrder'] as number
  };
  return moonlightHostIsValid(host) ? host : null;
}

function businessForHost(host: MoonlightHost): Record<string, Object> {
  const business: Record<string, Object> = {};
  business['schemaVersion'] = 1;
  business['serverUuid'] = host.serverUuid;
  business['displayName'] = host.displayName;
  business['addresses'] = host.addresses;
  business['preferredAddressKey'] = host.preferredAddressKey;
  business['httpsPort'] = host.httpsPort === undefined
    ? MOONLIGHT_DEFAULT_HTTPS_PORT : host.httpsPort;
  business['hostType'] = host.hostType;
  business['wakeOnLan'] = host.wakeOnLan;
  business['locked'] = host.locked === true;
  business['userOrder'] = host.userOrder;
  return business;
}

function nextUserOrder(records: MoonlightRecord[]): number {
  let maximum: number = -1;
  for (let index = 0; index < records.length; index++) {
    if (records[index].recordType !== 'host') { continue; }
    const payload: Record<string, Object> | null = moonlightRecordBusinessPayload(records[index]);
    if (payload === null || typeof payload['userOrder'] !== 'number') { continue; }
    const order: number = payload['userOrder'] as number;
    if (Number.isSafeInteger(order) && order >= 0) { maximum = Math.max(maximum, order); }
  }
  return Math.min(maximum + 1, 1000000);
}

function fieldVersions(recordType: 'host' | 'trust', version: number): Record<string, number> {
  const result: Record<string, number> = {};
  const paths: string[] = moonlightMutableFieldPaths(recordType);
  for (let index = 0; index < paths.length; index++) { result[paths[index]] = version; }
  return result;
}

function buildMeta(
  recordType: 'host' | 'trust',
  captured: AccountSessionLease,
  nowMs: number,
  version: number,
  current: MoonlightRecord | null
): MoonlightRecordMeta {
  return {
    mutationId: 'moonlight-' + recordType + '-' + nowMs.toString() + '-' + version.toString(),
    originId: ('moonlight-host-add|' + captured.storeIdentity).substring(0, 128),
    baseSyncVersion: current === null ? 0 : current.syncVersion,
    fieldVersions: fieldVersions(recordType, version)
  };
}

function buildRecord(
  recordType: 'host' | 'trust',
  id: string,
  ownerId: string,
  captured: AccountSessionLease,
  nowMs: number,
  current: MoonlightRecord | null,
  business: Record<string, Object>
): MoonlightRecord | null {
  const nextVersion: number = current === null ? 1 : current.syncVersion + 1;
  if (!Number.isSafeInteger(nextVersion) || nextVersion < 1) { return null; }
  const payload = moonlightPayloadWithMeta(
    business,
    buildMeta(recordType, captured, nowMs, nextVersion, current),
    recordType
  );
  if (!payload.ok) { return null; }
  const record: MoonlightRecord = new MoonlightRecord();
  record.id = id;
  record.userId = captured.ownerScopeId;
  record.recordType = recordType;
  record.ownerId = ownerId;
  record.ownerType = recordType === 'trust' ? 'host' : 'account';
  record.payload = payload.canonical;
  record.resetEpoch = current !== null && current.deletedAt > 0
    ? current.resetEpoch + 1 : current === null ? 0 : current.resetEpoch;
  if (!Number.isSafeInteger(record.resetEpoch)) { return null; }
  record.syncVersion = nextVersion;
  record.createdAt = current === null ? nowMs : current.createdAt;
  record.updatedAt = Math.max(nowMs, record.createdAt,
    current === null ? 0 : current.updatedAt);
  record.payloadHashSha256 = moonlightRecordPayloadHashSha256(record);
  return record;
}

function tombstoneCandidate(
  current: MoonlightRecord, nowMs: number
): MoonlightRecord {
  const tombstone: MoonlightRecord = MoonlightRecord.fromJSON(current.toJSON());
  tombstone.payload = '{}';
  tombstone.ciphertext = '';
  tombstone.envelopeVersion = 0;
  tombstone.cryptoVersion = 0;
  tombstone.keyVersion = 0;
  tombstone.aadVersion = 0;
  tombstone.syncVersion = current.syncVersion + 1;
  tombstone.updatedAt = Math.max(nowMs, current.updatedAt, current.createdAt);
  tombstone.deletedAt = tombstone.updatedAt;
  tombstone.payloadHashSha256 = moonlightRecordPayloadHashSha256(tombstone);
  return tombstone;
}

/**
 * Owner-scoped local host and catalog-data adapter. It never enters Moonlight
 * cloud selection or transfer. Related host/trust mutations share one local
 * transaction, while rebuildable app-cache cleanup is best effort.
 */
export class MoonlightLocalHostService {
  private readonly port: MoonlightRepositoryPort;
  private readonly repository: MoonlightRepository;
  private readonly cachePort: MoonlightAppCachePort | null;

  constructor(port: MoonlightRepositoryPort,
    cachePort: MoonlightAppCachePort | null = null) {
    this.port = port;
    this.repository = new MoonlightRepository(port);
    this.cachePort = cachePort;
  }

  updateHost(host: MoonlightHost, nowMs: number): MoonlightLocalHostMutationResult {
    const normalizedId: string = host.id.trim();
    const normalizedAddresses: MoonlightAddress[] = host.addresses.map(
      (address: MoonlightAddress): MoonlightAddress => copyAddress(address));
    const normalizedHost: MoonlightHost = {
      id: normalizedId,
      serverUuid: host.serverUuid.trim(),
      displayName: host.displayName.trim(),
      addresses: normalizedAddresses,
      preferredAddressKey: canonicalPreferredAddressKey(
        host.addresses, host.preferredAddressKey),
      httpsPort: host.httpsPort === undefined ? MOONLIGHT_DEFAULT_HTTPS_PORT : host.httpsPort,
      hostType: host.hostType,
      wakeOnLan: {
        enabled: host.wakeOnLan.enabled,
        mac: host.wakeOnLan.mac.trim(),
        broadcast: host.wakeOnLan.broadcast.trim()
      },
      locked: host.locked === true,
      userOrder: host.userOrder
    };
    if (!validNow(nowMs) || !moonlightHostIsValid(normalizedHost)) {
      return mutationResult(false, 'invalid_request', normalizedId, false, '主机配置无效');
    }
    const lease: AccountSessionLease | null = this.port.currentAccountLease();
    if (lease === null) {
      return mutationResult(false, 'not_ready', normalizedId, false, '当前本地数据域不可用');
    }
    const captured: AccountSessionLease = cloneAccountSessionLease(lease);
    const records: MoonlightRecord[] | null = this.repository.loadAll(captured);
    if (records === null) {
      return mutationResult(false, 'stale_lease', normalizedId, false, '本地数据域已变化');
    }
    const current: MoonlightRecord | null = recordWithId(records, normalizedId);
    const currentHost: MoonlightHost | null = current === null ? null : hostFromRecord(current);
    if (current === null || currentHost === null) {
      return mutationResult(false, 'not_found', normalizedId, false, '主机不存在或记录损坏');
    }
    // Pairing identity, lock state and list order have dedicated mutation
    // paths. The editor may change the complete connection configuration but
    // cannot silently replace those independently protected fields.
    if (normalizedHost.serverUuid !== currentHost.serverUuid ||
        normalizedHost.locked !== currentHost.locked ||
        normalizedHost.userOrder !== currentHost.userOrder) {
      return mutationResult(false, 'invalid_request', normalizedId, false, '主机身份或受保护状态已变化');
    }
    const candidate: MoonlightRecord | null = buildRecord(
      'host', normalizedId, captured.ownerScopeId, captured, nowMs, current,
      businessForHost(normalizedHost));
    if (candidate === null) {
      return mutationResult(false, 'local_write_failed', normalizedId, false, '无法生成主机记录');
    }
    const written: MoonlightRepositoryResult = this.repository.upsert(captured, candidate, 1);
    return mutationFromRepository(written, normalizedId, '主机配置保存失败');
  }

  updateUserOrder(hostId: string, userOrder: number,
    nowMs: number): MoonlightLocalHostMutationResult {
    const normalizedId: string = hostId.trim();
    if (!validNow(nowMs) || normalizedId === '' || !Number.isSafeInteger(userOrder) ||
        userOrder < 0 || userOrder > 1000000) {
      return mutationResult(false, 'invalid_request', normalizedId, false, '主机排序无效');
    }
    const lease: AccountSessionLease | null = this.port.currentAccountLease();
    if (lease === null) {
      return mutationResult(false, 'not_ready', normalizedId, false, '当前本地数据域不可用');
    }
    const captured: AccountSessionLease = cloneAccountSessionLease(lease);
    const records: MoonlightRecord[] | null = this.repository.loadAll(captured);
    if (records === null) {
      return mutationResult(false, 'stale_lease', normalizedId, false, '本地数据域已变化');
    }
    const current: MoonlightRecord | null = recordWithId(records, normalizedId);
    const currentHost: MoonlightHost | null = current === null ? null : hostFromRecord(current);
    if (current === null || currentHost === null) {
      return mutationResult(false, 'not_found', normalizedId, false, '主机不存在或记录损坏');
    }
    if (currentHost.userOrder === userOrder) {
      return mutationResult(true, 'unchanged', normalizedId, false);
    }
    currentHost.userOrder = userOrder;
    const candidate: MoonlightRecord | null = buildRecord(
      'host', normalizedId, captured.ownerScopeId, captured, nowMs, current,
      businessForHost(currentHost));
    if (candidate === null) {
      return mutationResult(false, 'local_write_failed', normalizedId, false, '无法生成主机排序记录');
    }
    const written: MoonlightRepositoryResult = this.repository.upsert(captured, candidate, 1);
    return mutationFromRepository(written, normalizedId, '主机排序保存失败');
  }

  updateDisplayName(hostId: string, displayName: string,
    nowMs: number): MoonlightLocalHostMutationResult {
    const normalizedId: string = hostId.trim();
    const normalizedName: string = displayName.trim();
    if (!validNow(nowMs) || normalizedId === '' || normalizedName === '' ||
        normalizedName.length > 128) {
      return mutationResult(false, 'invalid_request', normalizedId, false, '主机名称无效');
    }
    const lease: AccountSessionLease | null = this.port.currentAccountLease();
    if (lease === null) {
      return mutationResult(false, 'not_ready', normalizedId, false, '当前本地数据域不可用');
    }
    const captured: AccountSessionLease = cloneAccountSessionLease(lease);
    const records: MoonlightRecord[] | null = this.repository.loadAll(captured);
    if (records === null) {
      return mutationResult(false, 'stale_lease', normalizedId, false, '本地数据域已变化');
    }
    const current: MoonlightRecord | null = recordWithId(records, normalizedId);
    if (current === null || current.recordType !== 'host') {
      return mutationResult(false, 'not_found', normalizedId, false, '主机不存在');
    }
    const business: Record<string, Object> | null = moonlightRecordBusinessPayload(current);
    if (business === null) {
      return mutationResult(false, 'local_write_failed', normalizedId, false, '主机记录损坏');
    }
    const nextBusiness: Record<string, Object> = {};
    nextBusiness['schemaVersion'] = business['schemaVersion'];
    nextBusiness['serverUuid'] = business['serverUuid'];
    nextBusiness['displayName'] = normalizedName;
    nextBusiness['addresses'] = business['addresses'];
    nextBusiness['preferredAddressKey'] = business['preferredAddressKey'];
    nextBusiness['httpsPort'] = typeof business['httpsPort'] === 'number'
      ? business['httpsPort'] : MOONLIGHT_DEFAULT_HTTPS_PORT;
    nextBusiness['hostType'] = business['hostType'];
    nextBusiness['wakeOnLan'] = business['wakeOnLan'];
    nextBusiness['locked'] = business['locked'] === true;
    nextBusiness['userOrder'] = business['userOrder'];
    const candidate: MoonlightRecord | null = buildRecord(
      'host', normalizedId, captured.ownerScopeId, captured, nowMs, current, nextBusiness);
    if (candidate === null) {
      return mutationResult(false, 'local_write_failed', normalizedId, false, '无法生成主机记录');
    }
    const written: MoonlightRepositoryResult = this.repository.upsert(captured, candidate, 1);
    return mutationFromRepository(written, normalizedId, '主机名称保存失败');
  }

  updateLocked(hostId: string, locked: boolean,
    nowMs: number): MoonlightLocalHostMutationResult {
    const normalizedId: string = hostId.trim();
    if (!validNow(nowMs) || normalizedId === '' || typeof locked !== 'boolean') {
      return mutationResult(false, 'invalid_request', normalizedId, false, '主机锁定状态无效');
    }
    const lease: AccountSessionLease | null = this.port.currentAccountLease();
    if (lease === null) {
      return mutationResult(false, 'not_ready', normalizedId, false, '当前本地数据域不可用');
    }
    const captured: AccountSessionLease = cloneAccountSessionLease(lease);
    const records: MoonlightRecord[] | null = this.repository.loadAll(captured);
    if (records === null) {
      return mutationResult(false, 'stale_lease', normalizedId, false, '本地数据域已变化');
    }
    const current: MoonlightRecord | null = recordWithId(records, normalizedId);
    if (current === null || current.recordType !== 'host') {
      return mutationResult(false, 'not_found', normalizedId, false, '主机不存在');
    }
    const business: Record<string, Object> | null = moonlightRecordBusinessPayload(current);
    if (business === null) {
      return mutationResult(false, 'local_write_failed', normalizedId, false, '主机记录损坏');
    }
    const nextBusiness: Record<string, Object> = {};
    nextBusiness['schemaVersion'] = business['schemaVersion'];
    nextBusiness['serverUuid'] = business['serverUuid'];
    nextBusiness['displayName'] = business['displayName'];
    nextBusiness['addresses'] = business['addresses'];
    nextBusiness['preferredAddressKey'] = business['preferredAddressKey'];
    nextBusiness['httpsPort'] = typeof business['httpsPort'] === 'number'
      ? business['httpsPort'] : MOONLIGHT_DEFAULT_HTTPS_PORT;
    nextBusiness['hostType'] = business['hostType'];
    nextBusiness['wakeOnLan'] = business['wakeOnLan'];
    nextBusiness['locked'] = locked;
    nextBusiness['userOrder'] = business['userOrder'];
    const candidate: MoonlightRecord | null = buildRecord(
      'host', normalizedId, captured.ownerScopeId, captured, nowMs, current, nextBusiness);
    if (candidate === null) {
      return mutationResult(false, 'local_write_failed', normalizedId, false, '无法生成主机记录');
    }
    const written: MoonlightRepositoryResult = this.repository.upsert(captured, candidate, 1);
    return mutationFromRepository(written, normalizedId, '主机锁定状态保存失败');
  }

  deleteHost(hostId: string, nowMs: number): MoonlightLocalHostMutationResult {
    const normalizedId: string = hostId.trim();
    if (!validNow(nowMs) || normalizedId === '') {
      return mutationResult(false, 'invalid_request', normalizedId, false, '主机标识无效');
    }
    const lease: AccountSessionLease | null = this.port.currentAccountLease();
    if (lease === null) {
      return mutationResult(false, 'not_ready', normalizedId, false, '当前本地数据域不可用');
    }
    const captured: AccountSessionLease = cloneAccountSessionLease(lease);
    const records: MoonlightRecord[] | null = this.repository.loadAll(captured);
    if (records === null) {
      return mutationResult(false, 'stale_lease', normalizedId, false, '本地数据域已变化');
    }
    const owned: MoonlightRecord[] = [];
    let hostFound: boolean = false;
    for (let index: number = 0; index < records.length; index++) {
      const record: MoonlightRecord = records[index];
      if (record.id === normalizedId && record.recordType === 'host' ||
          record.ownerId === normalizedId) {
        owned.push(MoonlightRecord.fromJSON(record.toJSON()));
        if (record.id === normalizedId && record.recordType === 'host') { hostFound = true; }
      }
    }
    if (!hostFound) {
      return mutationResult(false, 'not_found', normalizedId, false, '主机不存在');
    }
    const mutations: MoonlightRepositoryBatchMutation[] = [];
    for (let index: number = 0; index < owned.length; index++) {
      const deleteAt: number = Math.max(nowMs + index, owned[index].updatedAt,
        owned[index].createdAt);
      mutations.push({
        record: tombstoneCandidate(owned[index], deleteAt),
        localOnly: 1
      });
    }
    const removed: MoonlightRepositoryBatchResult =
      this.repository.upsertBatch(captured, mutations);
    if (!removed.ok) {
      if (removed.localCommitted && removed.code === 'readback_failed') {
        this.clearHostCache(captured, normalizedId);
        return mutationResult(true, 'pending_local_verification',
          normalizedId, true, '主机已删除，正在后台核验');
      }
      return mutationResult(false,
        removed.code === 'stale_lease' ? 'stale_lease' : 'local_write_failed',
        normalizedId, removed.localCommitted, '删除本地记录失败');
    }
    // Cache is non-authoritative and can be rebuilt. A cleanup failure must not
    // resurrect the host or make the user repeat an already committed delete.
    this.clearHostCache(captured, normalizedId);
    return mutationResult(true, removed.code === 'unchanged' ?
      'unchanged' : 'ok', normalizedId, removed.localCommitted);
  }

  private clearHostCache(lease: AccountSessionLease, hostId: string): boolean {
    if (this.cachePort === null) { return true; }
    const rows: MoonlightAppCacheEntry[] | null =
      this.cachePort.loadMoonlightAppCacheEntries(lease, hostId);
    if (rows === null || !this.port.isLeaseCurrent(lease)) { return false; }
    const ids: string[] = [];
    for (let index: number = 0; index < rows.length; index++) {
      if (rows[index].userId !== lease.ownerScopeId || rows[index].hostId !== hostId) {
        return false;
      }
      ids.push(rows[index].id);
    }
    return this.cachePort.commitMoonlightAppCacheRefresh(lease, hostId, [], ids) &&
      this.port.isLeaseCurrent(lease);
  }

  save(
    state: MoonlightHostAddState,
    key: MoonlightHostAddOperationKey,
    nowMs: number
  ): MoonlightLocalHostSaveResult {
    if (!validNow(nowMs) || key.operation !== 'save' ||
        key.ownerToken <= 0 || key.ownerToken !== state.ownerToken ||
        key.generation <= 0 || key.generation !== state.generation ||
        state.activeOperation !== 'save' ||
        state.step !== 4 || !state.paired || state.trustState !== 'trusted' ||
        state.verification === null || state.verification.certificateChanged ||
        !/^[0-9a-fA-F]{64}$/.test(state.verification.fingerprintSha256)) {
      return saveResult(false, 'invalid_state', false, '', '', '主机尚未完成验证与信任');
    }
    const lease: AccountSessionLease | null = this.port.currentAccountLease();
    if (lease === null) { return saveResult(false, 'not_ready', false, '', '', '当前本地数据域不可用'); }
    const captured: AccountSessionLease = cloneAccountSessionLease(lease);
    const records: MoonlightRecord[] | null = this.repository.loadAll(captured, true);
    if (records === null) { return saveResult(false, 'stale_lease', false, '', '', '本地数据域已变化，请重试'); }

    const verification = state.verification;
    const serverUuid: string = verification.serverUuid.trim();
    const displayName: string = (state.displayName.trim() || verification.serverName.trim());
    const address: MoonlightAddress = copyAddress(verification.address);
    if (serverUuid === '' || displayName === '' || !moonlightHostIsValid({
      id: 'moonlight-host|' + sha256Hex(serverUuid),
      serverUuid: serverUuid,
      displayName: displayName,
      addresses: [address],
      preferredAddressKey: moonlightAddressKey(address),
      httpsPort: verification.httpsPort === undefined ? MOONLIGHT_DEFAULT_HTTPS_PORT :
        verification.httpsPort,
      hostType: verification.hostType,
      wakeOnLan: { enabled: false, mac: '', broadcast: '' },
      locked: false,
      userOrder: 0
    })) {
      return saveResult(false, 'invalid_state', false, '', '', '主机信息不完整');
    }

    const canonicalHostId: string = stableId(
      'moonlight-host|',
      'RemoteDeskHarmonyOS:moonlight-host:v1:' + captured.ownerScopeId + ':' + serverUuid
    );
    let compatibleHost: MoonlightRecord | null = null;
    const duplicateHostIds: string[] = [];
    for (let index = 0; index < records.length; index++) {
      const existingUuid: string = serverUuidFromHostRecord(records[index]);
      if (records[index].recordType !== 'host' || existingUuid !== serverUuid ||
          records[index].deletedAt > 0) {
        continue;
      }
      duplicateHostIds.push(records[index].id);
      if (records[index].id === canonicalHostId) {
        compatibleHost = records[index];
        continue;
      }
      if ((compatibleHost === null || compatibleHost.id !== canonicalHostId) &&
          (compatibleHost === null ||
          records[index].resetEpoch > compatibleHost.resetEpoch ||
          (records[index].resetEpoch === compatibleHost.resetEpoch &&
           records[index].syncVersion > compatibleHost.syncVersion) ||
          (records[index].resetEpoch === compatibleHost.resetEpoch &&
           records[index].syncVersion === compatibleHost.syncVersion &&
           records[index].updatedAt > compatibleHost.updatedAt))) {
        compatibleHost = records[index];
      }
    }
    // Pre-release builds used a different host-id derivation. Reuse the valid
    // live identity instead of permanently rejecting the same Sunshine UUID.
    const hostId: string = compatibleHost === null ?
      canonicalHostId : compatibleHost.id;
    const currentHost: MoonlightRecord | null = recordWithId(records, hostId);
    const currentHostBusiness: Record<string, Object> | null = currentHost === null ? null :
      moonlightRecordBusinessPayload(currentHost);
    const userOrder: number = currentHostBusiness !== null &&
      typeof currentHostBusiness['userOrder'] === 'number' ?
      currentHostBusiness['userOrder'] as number : nextUserOrder(records);
    // Re-verifying or repairing an existing Sunshine record updates its
    // endpoint/trust material, but must never silently unlock the unified host
    // card. Legacy records without this field remain intentionally unlocked.
    const locked: boolean = currentHostBusiness !== null &&
      currentHostBusiness['locked'] === true;
    const hostType: MoonlightHostType = verification.hostType;
    const host: MoonlightHost = {
      id: hostId,
      serverUuid: serverUuid,
      displayName: displayName,
      addresses: [address],
      preferredAddressKey: moonlightAddressKey(address),
      httpsPort: verification.httpsPort === undefined ? MOONLIGHT_DEFAULT_HTTPS_PORT :
        verification.httpsPort,
      hostType: hostType,
      wakeOnLan: { enabled: false, mac: '', broadcast: '' },
      locked: locked,
      userOrder: userOrder
    };
    if (!moonlightHostIsValid(host)) {
      return saveResult(false, 'invalid_state', false, '', '', '主机信息校验失败');
    }
    const hostBusiness: Record<string, Object> = {};
    hostBusiness['schemaVersion'] = 1;
    hostBusiness['serverUuid'] = host.serverUuid;
    hostBusiness['displayName'] = host.displayName;
    hostBusiness['addresses'] = host.addresses;
    hostBusiness['preferredAddressKey'] = host.preferredAddressKey;
    hostBusiness['httpsPort'] = host.httpsPort as number;
    hostBusiness['hostType'] = host.hostType;
    hostBusiness['wakeOnLan'] = host.wakeOnLan;
    hostBusiness['locked'] = host.locked === true;
    hostBusiness['userOrder'] = host.userOrder;
    const hostRecord: MoonlightRecord | null = buildRecord(
      'host', hostId, captured.ownerScopeId, captured, nowMs, currentHost, hostBusiness);
    if (hostRecord === null) {
      return saveResult(false, 'invalid_state', false, '', '', '无法生成主机本地记录');
    }
    const trustRecordId: string = stableId('moonlight-trust|', 'v1:' + hostId);
    const currentTrust: MoonlightRecord | null = recordWithId(records, trustRecordId);
    const previousGeneration: number = currentTrust === null ? 0 : (() => {
      const payload: Record<string, Object> | null = moonlightRecordBusinessPayload(currentTrust);
      return payload !== null && typeof payload['pairingGeneration'] === 'number'
        ? payload['pairingGeneration'] as number : 0;
    })();
    const trustBusiness: Record<string, Object> = {};
    trustBusiness['schemaVersion'] = 1;
    trustBusiness['hostId'] = hostId;
    trustBusiness['serverUuid'] = serverUuid;
    trustBusiness['serverCertificateSha256'] = verification.fingerprintSha256.toLowerCase();
    trustBusiness['pairingGeneration'] =
      Math.min(previousGeneration + 1, Number.MAX_SAFE_INTEGER);
    trustBusiness['candidateObservedAt'] = nowMs;
    const trustRecord: MoonlightRecord | null = buildRecord(
      'trust', trustRecordId, hostId, captured, nowMs, currentTrust, trustBusiness);
    if (trustRecord === null) {
      return saveResult(false, 'trust_write_failed', false, hostId, trustRecordId,
        '信任记录生成失败，未开始本地主机写入');
    }

    try {
      const graphMutations: MoonlightRepositoryBatchMutation[] = [
        { record: hostRecord, localOnly: 1 },
        { record: trustRecord, localOnly: 1 }
      ];
      let aliasOffset: number = 1;
      for (let i = 0; i < records.length; i++) {
        const duplicateHostOrOwned: boolean =
          (duplicateHostIds.indexOf(records[i].id) >= 0 &&
            records[i].id !== hostId) ||
          (duplicateHostIds.indexOf(records[i].ownerId) >= 0 &&
            records[i].ownerId !== hostId);
        const trustAlias: boolean = records[i].recordType === 'trust' &&
          records[i].ownerId === hostId && records[i].id !== trustRecordId;
        if (records[i].deletedAt > 0 ||
            (!duplicateHostOrOwned && !trustAlias)) {
          continue;
        }
        graphMutations.push({
          record: tombstoneCandidate(records[i], nowMs + aliasOffset),
          localOnly: 1
        });
        aliasOffset++;
      }
      const graph: MoonlightRepositoryBatchResult =
        this.repository.upsertBatch(captured, graphMutations);
      if (graph.ok) {
        return saveResult(true, 'ok', graph.localCommitted,
          hostId, trustRecordId, '', graph.localCommitted ?
            'committed' : 'not_committed');
      }
      if (graph.localCommitted && graph.code === 'readback_failed') {
        return saveResult(true, 'readback_failed', true,
          hostId, trustRecordId,
          '本地主机与信任已保存，正在后台核验', 'committed');
      }
      return saveResult(false,
        graph.code === 'stale_lease' ? 'stale_lease' :
        graph.code === 'readback_failed' ? 'readback_failed' :
          'trust_write_failed', graph.localCommitted,
        hostId, trustRecordId,
        graph.localCommitted ? '本地主机保存发生在先前数据域，请刷新确认' :
          '本地主机与信任未写入，请重试',
        graph.localCommitted ? 'uncertain' : 'not_committed');
    } catch (_error) {
      return saveResult(false, 'trust_write_failed', false,
        hostId, trustRecordId, '本地主机与信任未写入，请重试',
        'not_committed');
    }
  }
}
