import { expect } from '@ohos/hypium';
import {
  auditedDescribe as describe,
  auditedIt as it
} from '../main/ets/services/FocusedTestRegistrationAudit';
import { MoonlightRecord } from '../main/ets/model/MoonlightRecord';
import { MoonlightAppCacheEntry } from '../main/ets/model/MoonlightAppCache';
import { AccountSessionLease, accountSessionLeaseEquals, cloneAccountSessionLease } from
  '../main/ets/services/AccountScopePolicy';
import {
  MoonlightHostAddOperationKey,
  MoonlightHostAddState,
  MoonlightHostAddVerification
} from '../main/ets/services/MoonlightHostAddFlowPolicy';
import {
  MoonlightRepositoryCommit,
  MoonlightRepositoryPort,
  MoonlightRepositoryReadResult
} from '../main/ets/services/MoonlightRepository';
import {
  MoonlightLocalHostService
} from '../main/ets/services/MoonlightLocalHostService';
import { MoonlightAppCachePort } from '../main/ets/services/MoonlightAppCacheService';
import {
  MoonlightHost,
  defaultMoonlightSettings
} from '../main/ets/model/MoonlightModels';
import { MoonlightHostContext } from '../main/ets/services/MoonlightHostService';
import { moonlightHostFromRecord } from '../main/ets/services/MoonlightLocalViewService';
import { moonlightRuntimeContext } from
  '../main/ets/services/MoonlightRuntimeContextFactory';
import { moonlightRecordPayloadHashSha256 } from
  '../main/ets/services/MoonlightRecordPolicy';

function testLease(): AccountSessionLease {
  return {
    ownerScopeId: 'owner-a',
    storeIdentity: 'moonlight-test-store',
    generation: 1,
    storeInstanceId: 1
  };
}

class MemoryMoonlightHostPort implements MoonlightRepositoryPort, MoonlightAppCachePort {
  active: AccountSessionLease = testLease();
  rows: Map<string, MoonlightRecord> = new Map<string, MoonlightRecord>();
  localOnly: Map<string, number> = new Map<string, number>();
  failTrustWrite: boolean = false;
  failCompensationWrite: boolean = false;
  trustWriteAttempted: boolean = false;
  failReadbackRecordType: string = '';
  failReadbackOnce: boolean = false;
  switchAfterLoad: boolean = false;

  currentAccountLease(): AccountSessionLease | null {
    return cloneAccountSessionLease(this.active);
  }

  isLeaseCurrent(candidate: AccountSessionLease): boolean {
    return accountSessionLeaseEquals(this.active, candidate);
  }

  readMoonlightLocalRecord(candidate: AccountSessionLease,
    id: string): MoonlightRepositoryReadResult {
    if (!this.isLeaseCurrent(candidate)) { return { ok: false, record: null, localOnly: 1 }; }
    const key: string = candidate.ownerScopeId + ':' + id;
    const stored: MoonlightRecord | undefined = this.rows.get(key);
    if (stored === undefined) { return { ok: true, record: null, localOnly: 1 }; }
    if (this.failReadbackOnce && stored.recordType === this.failReadbackRecordType) {
      this.failReadbackOnce = false;
      return { ok: false, record: null, localOnly: 1 };
    }
    const only: number | undefined = this.localOnly.get(key);
    return {
      ok: true,
      record: MoonlightRecord.fromJSON(stored.toJSON()),
      localOnly: only === undefined ? 1 : only
    };
  }

  loadMoonlightLocalRecords(candidate: AccountSessionLease,
    includeDeleted: boolean = false): MoonlightRecord[] | null {
    if (!this.isLeaseCurrent(candidate)) { return null; }
    const result: MoonlightRecord[] = [];
    this.rows.forEach((value: MoonlightRecord): void => {
      if (value.userId === candidate.ownerScopeId &&
          (includeDeleted || value.deletedAt === 0)) {
        result.push(MoonlightRecord.fromJSON(value.toJSON()));
      }
    });
    if (this.switchAfterLoad) {
      this.active = {
        ownerScopeId: 'owner-b',
        storeIdentity: 'moonlight-test-store-b',
        generation: 2,
        storeInstanceId: 2
      };
    }
    return result;
  }

  commitMoonlightLocalRecord(candidate: AccountSessionLease,
    record: MoonlightRecord, only: number, _operation: string): boolean {
    if (record.recordType === 'trust' && record.deletedAt === 0 && this.failTrustWrite) {
      this.trustWriteAttempted = true;
      return false;
    }
    if (!this.isLeaseCurrent(candidate) ||
        (this.failCompensationWrite && this.trustWriteAttempted &&
          record.recordType === 'host')) {
      return false;
    }
    const key: string = candidate.ownerScopeId + ':' + record.id;
    this.rows.set(key, MoonlightRecord.fromJSON(record.toJSON()));
    this.localOnly.set(key, only);
    return true;
  }

  commitMoonlightLocalRecords(candidate: AccountSessionLease,
    commits: MoonlightRepositoryCommit[]): boolean {
    if (!this.isLeaseCurrent(candidate)) { return false; }
    for (let i = 0; i < commits.length; i++) {
      if (commits[i].record.recordType === 'trust' &&
          commits[i].record.deletedAt === 0 && this.failTrustWrite) {
        this.trustWriteAttempted = true;
        return false;
      }
    }
    for (let i = 0; i < commits.length; i++) {
      const key: string = candidate.ownerScopeId + ':' + commits[i].record.id;
      this.rows.set(key, MoonlightRecord.fromJSON(commits[i].record.toJSON()));
      this.localOnly.set(key, commits[i].localOnly);
    }
    return true;
  }

  recordMoonlightQuarantine(candidate: AccountSessionLease,
    _recordId: string, _reason: string, _hash: string): boolean {
    return this.isLeaseCurrent(candidate);
  }

  loadMoonlightAppCacheEntries(candidate: AccountSessionLease,
    _hostId?: string): MoonlightAppCacheEntry[] | null {
    return this.isLeaseCurrent(candidate) ? [] : null;
  }

  commitMoonlightAppCacheRefresh(candidate: AccountSessionLease,
    _hostId: string, _rows: MoonlightAppCacheEntry[], _evictedIds: string[]): boolean {
    return this.isLeaseCurrent(candidate);
  }
}

function readyAddState(): MoonlightHostAddState {
  const state: MoonlightHostAddState = new MoonlightHostAddState();
  state.ownerToken = 7;
  state.generation = 4;
  state.step = 4;
  state.displayName = '办公室主机';
  state.paired = true;
  state.trustState = 'trusted';
  state.verification = {
    serverUuid: 'server-uuid-1',
    serverName: '办公室主机',
    hostType: 'sunshine',
    version: '1.0',
    address: { host: '192.0.2.20', family: 'ipv4', port: 47989 },
    httpsPort: 48084,
    paired: false,
    fingerprintSha256: 'a'.repeat(64),
    certificateChanged: false,
    udpVerified: true,
    duplicateHostId: ''
  };
  state.selectedAddress = state.verification.address;
  return state;
}

function saveKey(state: MoonlightHostAddState): MoonlightHostAddOperationKey {
  const key: MoonlightHostAddOperationKey = new MoonlightHostAddOperationKey();
  key.ownerToken = 7;
  key.generation = state.generation;
  key.operation = 'save';
  return key;
}

export default function moonlightLocalHostServiceTest(): void {
  describe('MoonlightLocalHostService', (): void => {
    it('writes_host_and_trust_as_local_only_records', 0, (): void => {
      const port = new MemoryMoonlightHostPort();
      const state: MoonlightHostAddState = readyAddState();
      state.activeOperation = 'save';
      const result = new MoonlightLocalHostService(port).save(
        state, saveKey(state), 1000);
      expect(result.ok).assertTrue();
      expect(result.localCommitted).assertTrue();
      expect(result.hostId.length > 0).assertTrue();
      expect(result.trustRecordId.length > 0).assertTrue();
      expect(port.rows.size).assertEqual(2);
      port.localOnly.forEach((value: number): void => { expect(value).assertEqual(1); });
      let hostRecord: MoonlightRecord | null = null;
      port.rows.forEach((value: MoonlightRecord): void => {
        if (value.recordType === 'host') { hostRecord = value; }
      });
      expect(hostRecord !== null).assertTrue();
      const payload: Record<string, Object> = JSON.parse(
        (hostRecord as MoonlightRecord).payload) as Record<string, Object>;
      expect(payload['httpsPort']).assertEqual(48084);
    });

    it('persists_dual_stack_candidates_and_keeps_interface_scope_local', 0,
      (): void => {
        const port = new MemoryMoonlightHostPort();
        const state: MoonlightHostAddState = readyAddState();
        (state.verification as MoonlightHostAddVerification).candidateAddresses = [
          { host: '192.0.2.20', family: 'ipv4', port: 47989 },
          { host: 'fe80::20', family: 'ipv6', port: 47989, scope: 'wlan0' }
        ];
        state.activeOperation = 'save';
        const result = new MoonlightLocalHostService(port).save(
          state, saveKey(state), 1000);
        expect(result.ok).assertTrue();
        let hostRecord: MoonlightRecord | null = null;
        port.rows.forEach((value: MoonlightRecord): void => {
          if (value.recordType === 'host') { hostRecord = value; }
        });
        const host: MoonlightHost | null = moonlightHostFromRecord(
          hostRecord as MoonlightRecord);
        expect(host !== null).assertTrue();
        expect((host as MoonlightHost).addresses.length).assertEqual(2);
        expect((host as MoonlightHost).addresses[1].family).assertEqual('ipv6');
        expect((host as MoonlightHost).addresses[1].scope).assertEqual('wlan0');
        expect(port.localOnly.get('owner-a:' + result.hostId) as number).assertEqual(1);
      });

    it('persists_the_same_local_host_graph_without_an_account_login', 0,
      (): void => {
        const port = new MemoryMoonlightHostPort();
        port.active = {
          ownerScopeId: 'device-local',
          storeIdentity: 'remotedesktop_device_local.db',
          generation: 1,
          storeInstanceId: 1
        };
        const state: MoonlightHostAddState = readyAddState();
        state.activeOperation = 'save';
        const result = new MoonlightLocalHostService(port).save(
          state, saveKey(state), 1000);
        expect(result.ok).assertTrue();
        expect(result.localCommitted).assertTrue();
        expect(port.rows.size).assertEqual(2);
        port.rows.forEach((value: MoonlightRecord): void => {
          expect(value.userId).assertEqual('device-local');
        });
        port.localOnly.forEach((value: number): void => {
          expect(value).assertEqual(1);
        });
      });

    it('reloads_a_custom_sunshine_https_port_into_the_runtime_endpoint', 0, (): void => {
      const port = new MemoryMoonlightHostPort();
      const state: MoonlightHostAddState = readyAddState();
      state.activeOperation = 'save';
      const saved = new MoonlightLocalHostService(port).save(
        state, saveKey(state), 1000);
      expect(saved.ok).assertTrue();
      const rows: MoonlightRecord[] = port.loadMoonlightLocalRecords(
        port.active) as MoonlightRecord[];
      let storedHost: MoonlightRecord | null = null;
      for (let index: number = 0; index < rows.length; index++) {
        if (rows[index].recordType === 'host') { storedHost = rows[index]; }
      }
      expect(storedHost !== null).assertTrue();
      const reloaded: MoonlightHost | null =
        moonlightHostFromRecord(storedHost as MoonlightRecord);
      expect(reloaded !== null).assertTrue();
      const runtime = moonlightRuntimeContext(
        reloaded as MoonlightHost, port.active, 101, 7,
        'a'.repeat(64), defaultMoonlightSettings(), 5000);
      expect(runtime !== null).assertTrue();
      expect((runtime as MoonlightHostContext).endpoint.httpsPort).assertEqual(48084);
    });

    it('does_not_commit_either_graph_row_when_trust_write_fails', 0, (): void => {
      const port = new MemoryMoonlightHostPort();
      port.failTrustWrite = true;
      const state: MoonlightHostAddState = readyAddState();
      state.activeOperation = 'save';
      const result = new MoonlightLocalHostService(port).save(
        state, saveKey(state), 1000);
      expect(result.ok).assertFalse();
      expect(result.localCommitted).assertFalse();
      const liveRows: MoonlightRecord[] = port.loadMoonlightLocalRecords(
        port.active) as MoonlightRecord[];
      expect(liveRows.length).assertEqual(0);
      const allRows: MoonlightRecord[] = port.loadMoonlightLocalRecords(
        port.active, true) as MoonlightRecord[];
      expect(allRows.length).assertEqual(0);
    });

    it('rejects_an_untrusted_or_stale_add_without_writing', 0, (): void => {
      const port = new MemoryMoonlightHostPort();
      const state: MoonlightHostAddState = readyAddState();
      state.trustState = 'pending';
      const invalid = new MoonlightLocalHostService(port).save(
        state, saveKey(state), 1000);
      expect(invalid.code).assertEqual('invalid_state');
      port.switchAfterLoad = true;
      const staleState: MoonlightHostAddState = readyAddState();
      staleState.activeOperation = 'save';
      const stale = new MoonlightLocalHostService(port).save(
        staleState, saveKey(staleState), 1000);
      expect(stale.code).assertEqual('stale_lease');
      expect(port.rows.size).assertEqual(0);
    });

    it('rejects_a_replayed_operation_generation_before_writing', 0, (): void => {
      const port = new MemoryMoonlightHostPort();
      const state: MoonlightHostAddState = readyAddState();
      state.activeOperation = 'save';
      const staleKey: MoonlightHostAddOperationKey = saveKey(state);
      staleKey.generation += 1;
      const result = new MoonlightLocalHostService(port).save(state, staleKey, 1000);
      expect(result.code).assertEqual('invalid_state');
      expect(port.rows.size).assertEqual(0);
    });

    it('revives_a_compensation_tombstone_on_a_later_save', 0, (): void => {
      const port = new MemoryMoonlightHostPort();
      const firstState: MoonlightHostAddState = readyAddState();
      firstState.activeOperation = 'save';
      port.failTrustWrite = true;
      const failed = new MoonlightLocalHostService(port).save(
        firstState, saveKey(firstState), 1000);
      expect(failed.ok).assertFalse();
      expect(failed.commitState).assertEqual('not_committed');
      port.failTrustWrite = false;
      const retryState: MoonlightHostAddState = readyAddState();
      retryState.activeOperation = 'save';
      const retried = new MoonlightLocalHostService(port).save(
        retryState, saveKey(retryState), 2000);
      expect(retried.ok).assertTrue();
      expect(port.rows.size).assertEqual(2);
      const live: MoonlightRecord[] = port.loadMoonlightLocalRecords(
        port.active) as MoonlightRecord[];
      expect(live.length).assertEqual(2);
      for (let index = 0; index < live.length; index++) {
        expect(live[index].deletedAt).assertEqual(0);
      }
    });

    it('restores_an_existing_host_when_the_companion_trust_write_fails', 0, (): void => {
      const port = new MemoryMoonlightHostPort();
      const initialState: MoonlightHostAddState = readyAddState();
      initialState.activeOperation = 'save';
      const initial = new MoonlightLocalHostService(port).save(
        initialState, saveKey(initialState), 1000);
      expect(initial.ok).assertTrue();
      port.failTrustWrite = true;
      const updateState: MoonlightHostAddState = readyAddState();
      updateState.displayName = '更新后的名称';
      updateState.activeOperation = 'save';
      const failed = new MoonlightLocalHostService(port).save(
        updateState, saveKey(updateState), 2000);
      expect(failed.ok).assertFalse();
      expect(failed.commitState).assertEqual('not_committed');
      const live: MoonlightRecord[] = port.loadMoonlightLocalRecords(
        port.active) as MoonlightRecord[];
      expect(live.length).assertEqual(2);
      let restoredHost: MoonlightRecord | null = null;
      for (let index = 0; index < live.length; index++) {
        if (live[index].recordType === 'host') { restoredHost = live[index]; }
      }
      expect(restoredHost !== null).assertTrue();
      const payload: Object = JSON.parse((restoredHost as MoonlightRecord).payload) as Object;
      expect((payload as Record<string, Object>)['displayName']).assertEqual('办公室主机');
    });

    it('keeps_atomic_graph_commit_truth_when_post_commit_readback_fails', 0, (): void => {
      const port = new MemoryMoonlightHostPort();
      const state: MoonlightHostAddState = readyAddState();
      state.activeOperation = 'save';
      port.failReadbackRecordType = 'host';
      port.failReadbackOnce = true;
      const result = new MoonlightLocalHostService(port).save(
        state, saveKey(state), 1000);
      expect(result.ok).assertTrue();
      expect(result.code).assertEqual('readback_failed');
      expect(result.localCommitted).assertTrue();
      expect(result.commitState).assertEqual('committed');
      const live: MoonlightRecord[] = port.loadMoonlightLocalRecords(
        port.active) as MoonlightRecord[];
      expect(live.length).assertEqual(2);
    });

    it('does_not_need_compensation_when_the_atomic_graph_commit_is_rejected', 0, (): void => {
      const port = new MemoryMoonlightHostPort();
      port.failTrustWrite = true;
      port.failCompensationWrite = true;
      const state: MoonlightHostAddState = readyAddState();
      state.activeOperation = 'save';
      const result = new MoonlightLocalHostService(port).save(
        state, saveKey(state), 1000);
      expect(result.ok).assertFalse();
      expect(result.commitState).assertEqual('not_committed');
      const allRows: MoonlightRecord[] = port.loadMoonlightLocalRecords(
        port.active, true) as MoonlightRecord[];
      expect(allRows.length).assertEqual(0);
    });

    it('renames_an_existing_host_inside_the_current_local_lease', 0, (): void => {
      const port = new MemoryMoonlightHostPort();
      const state: MoonlightHostAddState = readyAddState();
      state.activeOperation = 'save';
      const service = new MoonlightLocalHostService(port, port);
      const saved = service.save(state, saveKey(state), 1000);
      expect(saved.ok).assertTrue();
      const renamed = service.updateDisplayName(saved.hostId, '客厅游戏主机', 2000);
      expect(renamed.ok).assertTrue();
      const stored = port.readMoonlightLocalRecord(port.active, saved.hostId).record as MoonlightRecord;
      const payload: Record<string, Object> = JSON.parse(stored.payload) as Record<string, Object>;
      expect(payload['displayName']).assertEqual('客厅游戏主机');
    });

    it('persists_the_unified_host_card_lock_and_preserves_it_across_rename', 0, (): void => {
      const port = new MemoryMoonlightHostPort();
      const state: MoonlightHostAddState = readyAddState();
      state.activeOperation = 'save';
      const service = new MoonlightLocalHostService(port, port);
      const saved = service.save(state, saveKey(state), 1000);
      expect(saved.ok).assertTrue();
      expect(service.updateLocked(saved.hostId, true, 2000).ok).assertTrue();
      expect(service.updateDisplayName(saved.hostId, '已锁定主机', 3000).ok).assertTrue();
      const stored = port.readMoonlightLocalRecord(port.active, saved.hostId).record as MoonlightRecord;
      const payload: Record<string, Object> = JSON.parse(stored.payload) as Record<string, Object>;
      expect(payload['locked']).assertTrue();
      const reloaded: MoonlightHost | null = moonlightHostFromRecord(stored);
      expect(reloaded !== null).assertTrue();
      expect((reloaded as MoonlightHost).locked === true).assertTrue();
    });

    it('updates_the_complete_editable_host_configuration_without_replacing_identity', 0, (): void => {
      const port = new MemoryMoonlightHostPort();
      const state: MoonlightHostAddState = readyAddState();
      state.activeOperation = 'save';
      const service = new MoonlightLocalHostService(port, port);
      const saved = service.save(state, saveKey(state), 1000);
      expect(saved.ok).assertTrue();
      const stored = port.readMoonlightLocalRecord(
        port.active, saved.hostId).record as MoonlightRecord;
      const current = moonlightHostFromRecord(stored) as MoonlightHost;
      const edited: MoonlightHost = {
        id: current.id,
        serverUuid: current.serverUuid,
        displayName: '游戏工作站',
        addresses: [{
          host: '2001:0DB8:0000:0000:0000:0000:0000:0020', family: 'ipv6', port: 47989
        }],
        preferredAddressKey:
          'ipv6|2001:0db8:0000:0000:0000:0000:0000:0020|47989',
        httpsPort: 47984,
        hostType: 'sunshine',
        wakeOnLan: { enabled: true, mac: 'AA:BB:CC:DD:EE:FF', broadcast: '192.0.2.255' },
        locked: current.locked,
        userOrder: current.userOrder
      };
      const updated = service.updateHost(edited, 2000);
      expect(updated.ok).assertTrue();
      const nextRecord = port.readMoonlightLocalRecord(
        port.active, saved.hostId).record as MoonlightRecord;
      const next = moonlightHostFromRecord(nextRecord) as MoonlightHost;
      expect(next.displayName).assertEqual('游戏工作站');
      expect(next.addresses[0].host).assertEqual('2001:db8::20');
      expect(next.preferredAddressKey).assertEqual('ipv6|2001:db8::20|47989');
      expect(next.httpsPort as number).assertEqual(47984);
      expect(next.wakeOnLan.enabled).assertTrue();
      expect(next.serverUuid).assertEqual(current.serverUuid);
    });

    it('persists_moonlight_order_and_rejects_editor_identity_replacement', 0, (): void => {
      const port = new MemoryMoonlightHostPort();
      const state: MoonlightHostAddState = readyAddState();
      state.activeOperation = 'save';
      const service = new MoonlightLocalHostService(port, port);
      const saved = service.save(state, saveKey(state), 1000);
      expect(saved.ok).assertTrue();
      expect(service.updateUserOrder(saved.hostId, 7, 2000).ok).assertTrue();
      const stored = port.readMoonlightLocalRecord(
        port.active, saved.hostId).record as MoonlightRecord;
      const reordered = moonlightHostFromRecord(stored) as MoonlightHost;
      expect(reordered.userOrder).assertEqual(7);
      reordered.serverUuid = 'different-server';
      const rejected = service.updateHost(reordered, 3000);
      expect(rejected.code).assertEqual('invalid_request');
    });

    it('treats_committed_host_readback_failure_as_pending_verification', 0,
      (): void => {
        const port = new MemoryMoonlightHostPort();
        const state: MoonlightHostAddState = readyAddState();
        state.activeOperation = 'save';
        const service = new MoonlightLocalHostService(port, port);
        const saved = service.save(state, saveKey(state), 1000);
        expect(saved.ok).assertTrue();
        port.failReadbackRecordType = 'host';
        port.failReadbackOnce = true;
        const renamed = service.updateDisplayName(
          saved.hostId, '已提交名称', 2000);
        expect(renamed.ok).assertTrue();
        expect(renamed.code).assertEqual('pending_local_verification');
        expect(renamed.localCommitted).assertTrue();
      });

    it('reports_an_unchanged_order_without_claiming_a_new_commit', 0, (): void => {
      const port = new MemoryMoonlightHostPort();
      const state: MoonlightHostAddState = readyAddState();
      state.activeOperation = 'save';
      const service = new MoonlightLocalHostService(port, port);
      const saved = service.save(state, saveKey(state), 1000);
      expect(saved.ok).assertTrue();
      const unchanged = service.updateUserOrder(saved.hostId, 0, 2000);
      expect(unchanged.ok).assertTrue();
      expect(unchanged.code).assertEqual('unchanged');
      expect(unchanged.localCommitted).assertFalse();
    });

    it('preserves_the_unified_host_card_lock_when_an_existing_host_is_saved_again', 0, (): void => {
      const port = new MemoryMoonlightHostPort();
      const initialState: MoonlightHostAddState = readyAddState();
      initialState.activeOperation = 'save';
      const service = new MoonlightLocalHostService(port, port);
      const initial = service.save(initialState, saveKey(initialState), 1000);
      expect(initial.ok).assertTrue();
      expect(service.updateLocked(initial.hostId, true, 2000).ok).assertTrue();

      const repairedState: MoonlightHostAddState = readyAddState();
      repairedState.displayName = '重新验证后的名称';
      repairedState.activeOperation = 'save';
      const repaired = service.save(repairedState, saveKey(repairedState), 3000);
      expect(repaired.ok).assertTrue();
      const stored = port.readMoonlightLocalRecord(
        port.active, repaired.hostId).record as MoonlightRecord;
      const payload: Record<string, Object> = JSON.parse(stored.payload) as Record<string, Object>;
      expect(payload['displayName']).assertEqual('重新验证后的名称');
      expect(payload['locked']).assertTrue();
      const reloaded: MoonlightHost | null = moonlightHostFromRecord(stored);
      expect(reloaded !== null).assertTrue();
      expect((reloaded as MoonlightHost).locked === true).assertTrue();
    });

    it('reuses_a_valid_legacy_host_id_for_the_same_sunshine_uuid', 0,
      (): void => {
        const port = new MemoryMoonlightHostPort();
        const state: MoonlightHostAddState = readyAddState();
        state.activeOperation = 'save';
        const service = new MoonlightLocalHostService(port, port);
        const initial = service.save(state, saveKey(state), 1000);
        expect(initial.ok).assertTrue();
        const canonicalKey: string =
          port.active.ownerScopeId + ':' + initial.hostId;
        const legacy: MoonlightRecord = MoonlightRecord.fromJSON(
          (port.rows.get(canonicalKey) as MoonlightRecord).toJSON());
        legacy.id = 'moonlight-host|legacy-v0-id';
        legacy.payloadHashSha256 = moonlightRecordPayloadHashSha256(legacy);
        port.rows.clear();
        port.localOnly.clear();
        port.rows.set(port.active.ownerScopeId + ':' + legacy.id, legacy);
        port.localOnly.set(port.active.ownerScopeId + ':' + legacy.id, 1);
        const repairedState: MoonlightHostAddState = readyAddState();
        repairedState.activeOperation = 'save';
        const repaired = service.save(
          repairedState, saveKey(repairedState), 2000);
        expect(repaired.ok).assertTrue();
        expect(repaired.hostId).assertEqual(legacy.id);
        expect(port.rows.has(
          port.active.ownerScopeId + ':' + initial.hostId)).assertFalse();
      });

    it('keeps_the_canonical_host_and_tombstones_a_live_legacy_alias', 0,
      (): void => {
        const port = new MemoryMoonlightHostPort();
        const state: MoonlightHostAddState = readyAddState();
        state.activeOperation = 'save';
        const service = new MoonlightLocalHostService(port, port);
        const initial = service.save(state, saveKey(state), 1000);
        expect(initial.ok).assertTrue();
        const canonicalKey: string =
          port.active.ownerScopeId + ':' + initial.hostId;
        const alias: MoonlightRecord = MoonlightRecord.fromJSON(
          (port.rows.get(canonicalKey) as MoonlightRecord).toJSON());
        alias.id = 'moonlight-host|legacy-live-alias';
        alias.payloadHashSha256 = moonlightRecordPayloadHashSha256(alias);
        port.rows.set(port.active.ownerScopeId + ':' + alias.id, alias);
        port.localOnly.set(port.active.ownerScopeId + ':' + alias.id, 1);

        const repairedState: MoonlightHostAddState = readyAddState();
        repairedState.activeOperation = 'save';
        const repaired = service.save(
          repairedState, saveKey(repairedState), 2000);
        expect(repaired.ok).assertTrue();
        expect(repaired.hostId).assertEqual(initial.hostId);
        const retiredAlias: MoonlightRecord = port.rows.get(
          port.active.ownerScopeId + ':' + alias.id) as MoonlightRecord;
        expect(retiredAlias.deletedAt > 0).assertTrue();
      });

    it('keeps_one_canonical_trust_and_tombstones_live_trust_aliases', 0,
      (): void => {
        const port = new MemoryMoonlightHostPort();
        const state: MoonlightHostAddState = readyAddState();
        state.activeOperation = 'save';
        const service = new MoonlightLocalHostService(port, port);
        const initial = service.save(state, saveKey(state), 1000);
        expect(initial.ok).assertTrue();
        const canonicalKey: string = port.active.ownerScopeId + ':' +
          initial.trustRecordId;
        const alias: MoonlightRecord = MoonlightRecord.fromJSON(
          (port.rows.get(canonicalKey) as MoonlightRecord).toJSON());
        alias.id = 'moonlight-trust|legacy-live-alias';
        alias.payloadHashSha256 = moonlightRecordPayloadHashSha256(alias);
        port.rows.set(port.active.ownerScopeId + ':' + alias.id, alias);
        port.localOnly.set(port.active.ownerScopeId + ':' + alias.id, 1);

        const repairedState: MoonlightHostAddState = readyAddState();
        repairedState.activeOperation = 'save';
        const repaired = service.save(
          repairedState, saveKey(repairedState), 2000);
        expect(repaired.ok).assertTrue();
        const canonical: MoonlightRecord = port.rows.get(canonicalKey) as MoonlightRecord;
        const retiredAlias: MoonlightRecord = port.rows.get(
          port.active.ownerScopeId + ':' + alias.id) as MoonlightRecord;
        expect(canonical.deletedAt).assertEqual(0);
        expect(retiredAlias.deletedAt > 0).assertTrue();
      });

    it('tombstones_host_and_owned_records_when_deleting_locally', 0, (): void => {
      const port = new MemoryMoonlightHostPort();
      const state: MoonlightHostAddState = readyAddState();
      state.activeOperation = 'save';
      const service = new MoonlightLocalHostService(port, port);
      const saved = service.save(state, saveKey(state), 1000);
      expect(saved.ok).assertTrue();
      const removed = service.deleteHost(saved.hostId, 2000);
      expect(removed.ok).assertTrue();
      const live = port.loadMoonlightLocalRecords(port.active) as MoonlightRecord[];
      const all = port.loadMoonlightLocalRecords(port.active, true) as MoonlightRecord[];
      expect(live.length).assertEqual(0);
      expect(all.length).assertEqual(2);
      expect(all[0].deletedAt > 0).assertTrue();
      expect(all[1].deletedAt > 0).assertTrue();
    });
  });
}
