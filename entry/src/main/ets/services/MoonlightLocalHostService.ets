import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';
import {
  MoonlightAddress,
  MoonlightHost,
  MoonlightHostType,
  MOONLIGHT_DEFAULT_HTTPS_PORT,
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
  'local_write_failed' | 'cache_cleanup_failed' | 'rollback_failed';

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
  return { host: value.host.trim(), family: value.family, port: value.port };
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

function restoreCandidate(
  previous: MoonlightRecord, current: MoonlightRecord, nowMs: number
): MoonlightRecord {
  const restored: MoonlightRecord = MoonlightRecord.fromJSON(previous.toJSON());
  restored.resetEpoch = previous.deletedAt > 0
    ? current.resetEpoch + 1 : current.resetEpoch;
  restored.syncVersion = current.syncVersion + 1;
  restored.updatedAt = Math.max(nowMs, current.updatedAt, restored.createdAt);
  restored.deletedAt = previous.deletedAt > 0 ? restored.updatedAt : 0;
  if (restored.deletedAt > 0) {
    restored.payload = '{}';
    restored.ciphertext = '';
    restored.envelopeVersion = 0;
    restored.cryptoVersion = 0;
    restored.keyVersion = 0;
    restored.aadVersion = 0;
  }
  restored.payloadHashSha256 = moonlightRecordPayloadHashSha256(restored);
  return restored;
}

/**
 * Compensates with a forward version. Restoring an older envelope directly
 * would be rejected by conflict resolution; a new-host rollback uses a
 * tombstone that can later be explicitly revived by buildRecord().
 */
function rollbackRecord(
  repository: MoonlightRepository,
  lease: AccountSessionLease,
  id: string,
  previous: MoonlightRecord | null,
  current: MoonlightRecord | null,
  nowMs: number
): boolean {
  if (current === null) { return previous === null; }
  const candidate: MoonlightRecord = previous === null
    ? tombstoneCandidate(current, nowMs)
    : restoreCandidate(previous, current, nowMs);
  const restored: MoonlightRepositoryResult = repository.upsert(lease, candidate, 1);
  return restored.ok || restored.code === 'not_found' || restored.code === 'unchanged';
}

function safeRollbackRecord(
  repository: MoonlightRepository,
  lease: AccountSessionLease,
  id: string,
  previous: MoonlightRecord | null,
  current: MoonlightRecord | null,
  nowMs: number
): boolean {
  try {
    return rollbackRecord(repository, lease, id, previous, current, nowMs);
  } catch (_error) {
    return false;
  }
}

/**
 * Owner-scoped local host and catalog-data adapter. It never enters Moonlight
 * cloud selection or transfer. Host/trust mutations are compensated on a
 * partial failure, and deleting a host also clears its local app cache when a
 * cache port is supplied.
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
    return written.ok
      ? mutationResult(true, 'ok', normalizedId, true)
      : mutationResult(false, written.code === 'stale_lease' ? 'stale_lease' :
        'local_write_failed', normalizedId, written.localCommitted, '主机名称保存失败');
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
    return written.ok
      ? mutationResult(true, 'ok', normalizedId, true)
      : mutationResult(false, written.code === 'stale_lease' ? 'stale_lease' :
        'local_write_failed', normalizedId, written.localCommitted, '主机锁定状态保存失败');
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
    const tombstones: MoonlightRecord[] = [];
    for (let index: number = 0; index < owned.length; index++) {
      const deleteAt: number = Math.max(nowMs + index, owned[index].updatedAt,
        owned[index].createdAt);
      const removed: MoonlightRepositoryResult =
        this.repository.tombstone(captured, owned[index].id, deleteAt, 1);
      if (!removed.ok || removed.record === null) {
        const recovered: boolean = this.rollbackDeletedRecords(
          captured, owned, tombstones, nowMs + owned.length + 1);
        return mutationResult(false, recovered ? 'local_write_failed' : 'rollback_failed',
          normalizedId, tombstones.length > 0, recovered ? '删除本地记录失败' : '删除回滚失败');
      }
      tombstones.push(removed.record);
    }
    if (!this.clearHostCache(captured, normalizedId)) {
      const recovered: boolean = this.rollbackDeletedRecords(
        captured, owned, tombstones, nowMs + owned.length + 1);
      return mutationResult(false, recovered ? 'cache_cleanup_failed' : 'rollback_failed',
        normalizedId, true, recovered ? '应用缓存清理失败' : '缓存失败且记录回滚失败');
    }
    return mutationResult(true, 'ok', normalizedId, true);
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

  private rollbackDeletedRecords(lease: AccountSessionLease,
    previous: MoonlightRecord[], current: MoonlightRecord[], nowMs: number): boolean {
    let recovered: boolean = true;
    for (let index: number = current.length - 1; index >= 0; index--) {
      recovered = safeRollbackRecord(this.repository, lease, current[index].id,
        previous[index], current[index], nowMs + current.length - index) && recovered;
    }
    return recovered;
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

    const hostId: string = stableId(
      'moonlight-host|',
      'RemoteDeskHarmonyOS:moonlight-host:v1:' + captured.ownerScopeId + ':' + serverUuid
    );
    for (let index = 0; index < records.length; index++) {
      const existingUuid: string = serverUuidFromHostRecord(records[index]);
      if (records[index].recordType === 'host' && existingUuid === serverUuid &&
          records[index].id !== hostId) {
        return saveResult(false, 'duplicate', false, records[index].id, '', '该主机已存在');
      }
    }
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

    // Nothing below this boundary may escape as an exception. The first local
    // row can already be durable when the second row or its readback fails.
    let hostSaved: MoonlightRepositoryResult | null = null;
    let trustSaved: MoonlightRepositoryResult | null = null;
    try {
      hostSaved = this.repository.upsert(captured, hostRecord, 1);
      if (!hostSaved.ok) {
        const code: MoonlightLocalHostSaveCode = hostSaved.code === 'readback_failed'
          ? 'readback_failed' : 'local_write_failed';
        if (!hostSaved.localCommitted) {
          return saveResult(false, code, false, hostId, '', '主机本地记录保存失败');
        }
        const recovered: boolean = safeRollbackRecord(this.repository, captured, hostId,
          currentHost, hostSaved.record === null ? hostRecord : hostSaved.record, nowMs);
        return saveResult(false, recovered ? code : 'rollback_failed', false, hostId, '',
          recovered ? '主机本地记录保存未确认，已回滚；请重试' :
            '主机本地记录保存状态不确定，请刷新主机列表确认',
          recovered ? 'not_committed' : 'uncertain');
      }
      trustSaved = this.repository.upsert(captured, trustRecord, 1);
      if (!trustSaved.ok) {
        const hostRolledBack: boolean = safeRollbackRecord(this.repository, captured, hostId,
          currentHost, hostSaved.record === null ? hostRecord : hostSaved.record, nowMs);
        const trustRolledBack: boolean = !trustSaved.localCommitted || safeRollbackRecord(
          this.repository, captured, trustRecordId, currentTrust,
          trustSaved.record === null ? trustRecord : trustSaved.record, nowMs);
        const recovered: boolean = hostRolledBack && trustRolledBack;
        return saveResult(false,
          recovered ? 'trust_write_failed' : 'rollback_failed', false, hostId, trustRecordId,
          recovered ? '信任记录保存失败，已回滚本地变更' :
            '信任记录保存状态不确定，请刷新主机列表确认',
          recovered ? 'not_committed' : 'partial');
      }
      return saveResult(true, 'ok', true, hostId, trustRecordId, '', 'committed');
    } catch (_error) {
      const hostRolledBack: boolean = safeRollbackRecord(this.repository, captured, hostId,
        currentHost, hostSaved === null || hostSaved.record === null ? hostRecord : hostSaved.record,
        nowMs);
      const trustRolledBack: boolean = safeRollbackRecord(this.repository, captured, trustRecordId,
        currentTrust, trustSaved === null || trustSaved.record === null ? trustRecord : trustSaved.record,
        nowMs);
      const recovered: boolean = hostRolledBack && trustRolledBack;
      return saveResult(false, recovered ? 'trust_write_failed' : 'rollback_failed', false,
        hostId, trustRecordId,
        recovered ? '本地主机保存异常，已回滚本地变更，请重试' :
          '本地主机保存状态不确定，请刷新主机列表确认',
        recovered ? 'not_committed' : 'uncertain');
    }
  }
}
