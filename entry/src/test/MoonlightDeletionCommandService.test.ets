import { describe, expect, it } from '@ohos/hypium';
import {
  defaultMoonlightSettings
} from '../main/ets/model/MoonlightModels';
import {
  MoonlightRecord,
  MoonlightRecordType
} from '../main/ets/model/MoonlightRecord';
import {
  MoonlightAppCacheEntry,
  cloneMoonlightAppCacheEntry,
  moonlightAppCacheIdentity
} from '../main/ets/model/MoonlightAppCache';
import {
  AccountSessionLease,
  accountSessionLeaseEquals,
  cloneAccountSessionLease
} from '../main/ets/services/AccountScopePolicy';
import {
  MoonlightRecordMeta,
  moonlightPayloadWithMeta,
  moonlightRecordPayloadHashSha256
} from '../main/ets/services/MoonlightRecordPolicy';
import {
  MoonlightDeletionCommandPort,
  MoonlightDeletionCommandService,
  MoonlightDeletionMutationRequest,
  MoonlightDeletionMutationResult,
  MoonlightDeletionSelectionPort,
  MoonlightDeletionSelectionSnapshot,
  MoonlightHostUnpairPort,
  MoonlightIdentityDeletionPort
} from '../main/ets/services/MoonlightDeletionCommandService';

function lease(owner: string = 'owner-a', generation: number = 1,
  storeInstanceId: number = 1): AccountSessionLease {
  return {
    ownerScopeId: owner,
    storeIdentity: 'store-' + owner,
    generation,
    storeInstanceId
  };
}

function recordBusiness(type: MoonlightRecordType,
  hostId: string = ''): Record<string, Object> {
  if (type === 'settings') {
    return defaultMoonlightSettings() as Object as Record<string, Object>;
  }
  if (type === 'host') {
    return {
      schemaVersion: 1,
      serverUuid: 'server-' + hostId,
      displayName: 'PC ' + hostId,
      addresses: [{ host: '192.0.2.20', family: 'ipv4', port: 47989 }],
      preferredAddressKey: 'ipv4|192.0.2.20|47989',
      hostType: 'sunshine',
      wakeOnLan: { enabled: false, mac: '', broadcast: '' },
      userOrder: 0
    };
  }
  if (type === 'profile') {
    return {
      schemaVersion: 1,
      hostId,
      appId: 'app-' + hostId,
      titleSnapshot: 'Desktop',
      streamOverrides: {
        codecPreference: 'h264', fps: 60, bitrateKbps: 20000
      },
      inputOverrides: { touchMode: 'touch', controllerSlot: -1 },
      favorite: false,
      userOrder: 0
    };
  }
  if (type === 'trust') {
    return {
      schemaVersion: 1,
      hostId,
      serverUuid: 'server-' + hostId,
      serverCertificateSha256: 'a'.repeat(64),
      pairingGeneration: 1,
      candidateObservedAt: 200
    };
  }
  return {
    schemaVersion: 1,
    identityVersion: 1,
    certificateSha256: 'b'.repeat(64),
    storageMode: 'cloudEncryptedPending'
  };
}

function record(type: MoonlightRecordType, id: string,
  owner: string = 'owner-a', hostId: string = ''): MoonlightRecord {
  const value = new MoonlightRecord();
  value.id = id;
  value.userId = owner;
  value.recordType = type;
  value.ownerId = type === 'profile' || type === 'trust' ? hostId : owner;
  value.ownerType = type === 'profile' || type === 'trust'
    ? 'host' : 'account';
  value.secretKind = type === 'secret' ? 'client_identity' : '';
  const meta: MoonlightRecordMeta = {
    mutationId: 'mutation-' + id,
    originId: 'origin-' + owner,
    baseSyncVersion: 0,
    fieldVersions: type === 'host' ? { 'displayName': 1 } : {}
  };
  value.payload = moonlightPayloadWithMeta(
    recordBusiness(type, type === 'host' ? id : hostId), meta, type).canonical;
  value.syncVersion = 1;
  value.createdAt = 100;
  value.updatedAt = 101;
  if (type === 'secret') {
    value.ciphertext = 'AQID';
    value.envelopeVersion = 1;
    value.cryptoVersion = 1;
    value.keyVersion = 1;
    value.aadVersion = 1;
  }
  value.payloadHashSha256 = moonlightRecordPayloadHashSha256(value);
  return value;
}

function cacheEntry(hostId: string, appId: string): MoonlightAppCacheEntry {
  const value = new MoonlightAppCacheEntry();
  value.id = moonlightAppCacheIdentity('owner-a', hostId, appId);
  value.userId = 'owner-a';
  value.hostId = hostId;
  value.appId = appId;
  value.title = 'Desktop';
  value.artworkLocalPath = '/sandbox/' + hostId + '-' + appId + '.png';
  value.available = true;
  value.lastCatalogAt = 100;
  value.expiresAt = 1000;
  value.lastAccessedAt = 100;
  value.sizeBytes = 10;
  return value;
}

function okMutation(localCommitted: boolean): MoonlightDeletionMutationResult {
  return {
    ok: true,
    code: 'ok',
    localCommitted,
    cloudAttempted: false,
    cloudTerminal: false
  };
}

class MemoryDeletionPort implements MoonlightDeletionCommandPort {
  activeLease: AccountSessionLease | null = lease();
  rows: Map<string, MoonlightRecord> = new Map<string, MoonlightRecord>();
  cache: Map<string, MoonlightAppCacheEntry> =
    new Map<string, MoonlightAppCacheEntry>();
  cloudReady: boolean = false;
  writeFailure: boolean = false;
  switchAfterCommit: boolean = false;
  runtimeStateCount: number = 0;
  commitCount: number = 0;

  currentAccountLease(): AccountSessionLease | null {
    return this.activeLease === null ? null :
      cloneAccountSessionLease(this.activeLease);
  }

  isLeaseCurrent(candidate: AccountSessionLease): boolean {
    return accountSessionLeaseEquals(this.activeLease, candidate);
  }

  loadMoonlightLocalRecords(candidate: AccountSessionLease,
    _includeDeleted: boolean = false): MoonlightRecord[] | null {
    if (!this.isLeaseCurrent(candidate)) { return null; }
    const result: MoonlightRecord[] = [];
    this.rows.forEach((value: MoonlightRecord): void => {
      if (value.userId === candidate.ownerScopeId) {
        result.push(MoonlightRecord.fromJSON(value.toJSON()));
      }
    });
    return result;
  }

  loadMoonlightAppCacheEntries(candidate: AccountSessionLease,
    _hostId: string = ''): MoonlightAppCacheEntry[] | null {
    if (!this.isLeaseCurrent(candidate)) { return null; }
    const result: MoonlightAppCacheEntry[] = [];
    this.cache.forEach((value: MoonlightAppCacheEntry): void => {
      if (value.userId === candidate.ownerScopeId) {
        result.push(cloneMoonlightAppCacheEntry(value));
      }
    });
    return result;
  }

  moonlightCloudDeletionReady(candidate: AccountSessionLease): boolean {
    return this.cloudReady && this.isLeaseCurrent(candidate);
  }

  moonlightOwnerRuntimeStateCount(
    candidate: AccountSessionLease,
    _recordIds: string[],
    _includeOwnerMarker: boolean
  ): number {
    return this.isLeaseCurrent(candidate) ? this.runtimeStateCount : -1;
  }

  commitMoonlightDeletion(candidate: AccountSessionLease,
    request: MoonlightDeletionMutationRequest
  ): MoonlightDeletionMutationResult {
    if (!this.isLeaseCurrent(candidate)) {
      return {
        ok: false, code: 'stale_lease', localCommitted: false,
        cloudAttempted: false, cloudTerminal: false
      };
    }
    if (this.writeFailure) {
      return {
        ok: false, code: 'write_failed', localCommitted: false,
        cloudAttempted: false, cloudTerminal: false
      };
    }
    if (request.writeCloudTombstones && !this.cloudReady) {
      return {
        ok: false, code: 'cloud_unavailable', localCommitted: false,
        cloudAttempted: false, cloudTerminal: false
      };
    }
    if (request.expectedRuntimeStateCount !== this.runtimeStateCount) {
      return {
        ok: false, code: 'write_failed', localCommitted: false,
        cloudAttempted: false, cloudTerminal: false
      };
    }
    for (let i = 0; i < request.recordIds.length; i++) {
      this.rows.delete(request.recordIds[i]);
    }
    for (let i = 0; i < request.cacheIds.length; i++) {
      this.cache.delete(request.cacheIds[i]);
    }
    if (request.clearOwnerRuntimeState) { this.runtimeStateCount = 0; }
    this.commitCount++;
    if (this.switchAfterCommit) {
      this.activeLease = lease('owner-b', 2, 2);
    }
    return okMutation(request.recordIds.length > 0 ||
      request.cacheIds.length > 0 || request.clearOwnerRuntimeState);
  }
}

class MemorySelectionPort implements MoonlightDeletionSelectionPort {
  snapshotValue: MoonlightDeletionSelectionSnapshot = {
    physicalSelected: false,
    selectedScopes: []
  };
  cancelFailure: boolean = false;
  cancelCount: number = 0;

  selectionSnapshot(
    _candidate: AccountSessionLease
  ): MoonlightDeletionSelectionSnapshot | null {
    return {
      physicalSelected: this.snapshotValue.physicalSelected,
      selectedScopes: this.snapshotValue.selectedScopes.slice()
    };
  }

  cancelAllMoonlightSync(_candidate: AccountSessionLease): boolean {
    if (this.cancelFailure) { return false; }
    this.snapshotValue = { physicalSelected: false, selectedScopes: [] };
    this.cancelCount++;
    return true;
  }
}

class MemoryHostPort implements MoonlightHostUnpairPort {
  ready: boolean = true;
  succeed: boolean = true;
  calls: number = 0;

  isHostUnpairReady(
    _candidate: AccountSessionLease, _hostId: string
  ): boolean {
    return this.ready;
  }

  async requestHostUnpair(
    _candidate: AccountSessionLease, _hostId: string
  ): Promise<boolean> {
    this.calls++;
    return this.succeed;
  }
}

class MemoryIdentityPort implements MoonlightIdentityDeletionPort {
  ready: boolean = true;
  succeed: boolean = true;
  calls: number = 0;
  identityCount: number = 1;

  localIdentityCount(_candidate: AccountSessionLease): number {
    return this.identityCount;
  }

  isIdentityDeletionReady(
    _candidate: AccountSessionLease, _identityRecordIds: string[]
  ): boolean {
    return this.ready;
  }

  async deleteLocalIdentities(
    _candidate: AccountSessionLease, _identityRecordIds: string[],
    _clearAllForOwner: boolean
  ): Promise<boolean> {
    this.calls++;
    if (this.succeed) { this.identityCount = 0; }
    return this.succeed;
  }
}

function seededPort(): MemoryDeletionPort {
  const port = new MemoryDeletionPort();
  const records: MoonlightRecord[] = [
    record('settings', 'settings-1'),
    record('host', 'host-1'),
    record('host', 'host-2'),
    record('profile', 'profile-1', 'owner-a', 'host-1'),
    record('profile', 'profile-2', 'owner-a', 'host-2'),
    record('trust', 'trust-1', 'owner-a', 'host-1'),
    record('trust', 'trust-2', 'owner-a', 'host-2'),
    record('secret', 'identity-1')
  ];
  for (let i = 0; i < records.length; i++) {
    port.rows.set(records[i].id, records[i]);
  }
  const cache: MoonlightAppCacheEntry[] = [
    cacheEntry('host-1', 'app-1'),
    cacheEntry('host-2', 'app-2')
  ];
  for (let i = 0; i < cache.length; i++) {
    port.cache.set(cache[i].id, cache[i]);
  }
  return port;
}

export default function moonlightDeletionCommandServiceTest(): void {
  describe('MoonlightDeletionCommandService', (): void => {
    it('derives_complete_delete_all_counts_from_owner_rows_and_cache', 0,
      (): void => {
        const service = new MoonlightDeletionCommandService(seededPort());
        const preview = service.preview(lease(), 'delete_local_data');
        expect(preview.code).assertEqual('ok');
        expect(preview.context.settingsRecordCount).assertEqual(1);
        expect(preview.context.hostRecordCount).assertEqual(2);
        expect(preview.context.profileRecordCount).assertEqual(2);
        expect(preview.context.trustRecordCount).assertEqual(2);
        expect(preview.context.identityRecordCount).assertEqual(1);
        expect(preview.impact.localRowsRemoved).assertEqual(8);
        expect(preview.impact.cacheRowsRemoved).assertEqual(2);
      });

    it('executes_an_exact_local_delete_without_cloud_or_identity_leak', 0,
      async (): Promise<void> => {
        const port = seededPort();
        const identity = new MemoryIdentityPort();
        const service = new MoonlightDeletionCommandService(
          port, null, null, identity);
        const preview = service.preview(lease(), 'delete_local_data');
        const result = await service.execute(lease(), preview, 300);
        expect(result.ok).assertTrue();
        expect(result.localCommitted).assertTrue();
        expect(result.cloudAttempted).assertFalse();
        expect(result.identitySucceeded).assertTrue();
        expect(identity.calls).assertEqual(1);
        expect(result.artworkPathsToDelete.length).assertEqual(2);
        expect(port.rows.size).assertEqual(0);
        expect(port.cache.size).assertEqual(0);
      });

    it('blocks_delete_all_when_secure_identity_cleanup_is_unavailable', 0,
      async (): Promise<void> => {
        const port = seededPort();
        const service = new MoonlightDeletionCommandService(port);
        const preview = service.preview(lease(), 'delete_local_data');
        const result = await service.execute(lease(), preview, 300);
        expect(result.code).assertEqual('identity_unavailable');
        expect(result.localCommitted).assertFalse();
        expect(port.rows.has('identity-1')).assertTrue();
        expect(port.commitCount).assertEqual(0);
      });

    it('reports_secure_identity_cleanup_when_the_following_rdb_commit_fails', 0,
      async (): Promise<void> => {
        const port = seededPort();
        port.writeFailure = true;
        const identity = new MemoryIdentityPort();
        const service = new MoonlightDeletionCommandService(
          port, null, null, identity);
        const preview = service.preview(lease(), 'delete_local_data');
        const result = await service.execute(lease(), preview, 300);
        expect(result.code).assertEqual('local_write_failed');
        expect(result.identityAttempted).assertTrue();
        expect(result.identitySucceeded).assertTrue();
        expect(result.localCommitted).assertFalse();
        expect(port.rows.has('identity-1')).assertTrue();
      });

    it('clears_orphaned_owner_runtime_state_even_without_business_rows', 0,
      async (): Promise<void> => {
        const port = new MemoryDeletionPort();
        port.runtimeStateCount = 2;
        const service = new MoonlightDeletionCommandService(port);
        const preview = service.preview(lease(), 'delete_local_data');
        expect(preview.code).assertEqual('ok');
        expect(preview.impact.localRuntimeStatesRemoved).assertEqual(2);
        const result = await service.execute(lease(), preview, 300);
        expect(result.ok).assertTrue();
        expect(result.localCommitted).assertTrue();
        expect(port.runtimeStateCount).assertEqual(0);
      });

    it('clears_owner_secure_identity_even_when_its_metadata_row_is_missing', 0,
      async (): Promise<void> => {
        const port = new MemoryDeletionPort();
        const identity = new MemoryIdentityPort();
        const service = new MoonlightDeletionCommandService(
          port, null, null, identity);
        const preview = service.preview(lease(), 'delete_local_data');
        expect(preview.impact.secureIdentitiesRemoved).assertEqual(1);
        const result = await service.execute(lease(), preview, 300);
        expect(result.ok).assertTrue();
        expect(result.identitySucceeded).assertTrue();
        expect(identity.identityCount).assertEqual(0);
      });

    it('forgets_only_the_target_host_graph_and_preserves_shared_identity', 0,
      async (): Promise<void> => {
        const port = seededPort();
        const service = new MoonlightDeletionCommandService(port);
        const preview = service.preview(
          lease(), 'forget_host', 'host-1');
        expect(preview.recordIds.join(','))
          .assertEqual('host-1,profile-1,trust-1');
        const result = await service.execute(lease(), preview, 300);
        expect(result.ok).assertTrue();
        expect(port.rows.has('identity-1')).assertTrue();
        expect(port.rows.has('settings-1')).assertTrue();
        expect(port.rows.has('host-2')).assertTrue();
        expect(port.rows.has('host-1')).assertFalse();
        expect(port.cache.size).assertEqual(1);
      });

    it('rejects_a_stale_preview_before_any_mutation', 0,
      async (): Promise<void> => {
        const port = seededPort();
        const service = new MoonlightDeletionCommandService(port);
        const preview = service.preview(
          lease(), 'forget_host', 'host-1');
        port.rows.set('profile-new',
          record('profile', 'profile-new', 'owner-a', 'host-1'));
        const result = await service.execute(lease(), preview, 300);
        expect(result.code).assertEqual('stale_preview');
        expect(port.commitCount).assertEqual(0);
        expect(port.rows.has('host-1')).assertTrue();
      });

    it('rejects_a_stale_account_generation_without_reads_or_writes', 0,
      async (): Promise<void> => {
        const port = seededPort();
        const service = new MoonlightDeletionCommandService(port);
        const preview = service.preview(lease(), 'delete_local_data');
        port.activeLease = lease('owner-b', 2, 2);
        const result = await service.execute(lease(), preview, 300);
        expect(result.code).assertEqual('stale_lease');
        expect(port.commitCount).assertEqual(0);
      });

    it('blocks_cloud_deletion_before_the_terminal_cloud_port_exists', 0,
      async (): Promise<void> => {
        const port = seededPort();
        const service = new MoonlightDeletionCommandService(port);
        const preview = service.preview(lease(), 'delete_cloud_data');
        expect(preview.code).assertEqual('cloud_unavailable');
        const result = await service.execute(lease(), preview, 300);
        expect(result.code).assertEqual('cloud_unavailable');
        expect(result.cloudAttempted).assertFalse();
        expect(port.commitCount).assertEqual(0);
      });

    it('blocks_unpair_when_no_real_host_control_port_is_ready', 0,
      async (): Promise<void> => {
        const port = seededPort();
        const service = new MoonlightDeletionCommandService(port);
        const preview = service.preview(
          lease(), 'unpair_host', 'host-1');
        const result = await service.execute(lease(), preview, 300);
        expect(result.code).assertEqual('host_unavailable');
        expect(port.rows.has('trust-1')).assertTrue();
        expect(port.commitCount).assertEqual(0);
      });

    it('keeps_local_unpair_committed_when_the_best_effort_host_call_fails', 0,
      async (): Promise<void> => {
        const port = seededPort();
        const host = new MemoryHostPort();
        host.succeed = false;
        const service = new MoonlightDeletionCommandService(
          port, null, host);
        const preview = service.preview(
          lease(), 'unpair_host', 'host-1');
        const result = await service.execute(lease(), preview, 300);
        expect(result.ok).assertTrue();
        expect(result.code).assertEqual('ok_with_remote_warning');
        expect(result.hostAttempted).assertTrue();
        expect(result.hostSucceeded).assertFalse();
        expect(port.rows.has('trust-1')).assertFalse();
        expect(port.rows.has('identity-1')).assertTrue();
      });

    it('does_not_claim_commit_when_the_atomic_local_write_fails', 0,
      async (): Promise<void> => {
        const port = seededPort();
        port.writeFailure = true;
        const service = new MoonlightDeletionCommandService(port);
        const preview = service.preview(
          lease(), 'delete_profile', 'host-1', 'profile-1');
        const result = await service.execute(lease(), preview, 300);
        expect(result.code).assertEqual('local_write_failed');
        expect(result.localCommitted).assertFalse();
        expect(port.rows.has('profile-1')).assertTrue();
      });

    it('returns_unchanged_when_cancel_sync_has_no_selected_scope', 0,
      async (): Promise<void> => {
        const port = seededPort();
        const selection = new MemorySelectionPort();
        const service = new MoonlightDeletionCommandService(
          port, selection);
        const preview = service.preview(lease(), 'cancel_sync');
        expect(preview.code).assertEqual('unchanged');
        const result = await service.execute(lease(), preview, 300);
        expect(result.code).assertEqual('unchanged');
        expect(selection.cancelCount).assertEqual(0);
      });

    it('cancels_physical_and_logical_selection_without_deleting_rows', 0,
      async (): Promise<void> => {
        const port = seededPort();
        const selection = new MemorySelectionPort();
        selection.snapshotValue = {
          physicalSelected: true,
          selectedScopes: ['hosts', 'profiles']
        };
        const service = new MoonlightDeletionCommandService(
          port, selection);
        const preview = service.preview(lease(), 'cancel_sync');
        expect(preview.impact.selectionChanged).assertTrue();
        const result = await service.execute(lease(), preview, 300);
        expect(result.ok).assertTrue();
        expect(result.selectionChanged).assertTrue();
        expect(port.rows.size).assertEqual(8);
        expect(port.commitCount).assertEqual(0);
        expect(selection.cancelCount).assertEqual(1);
      });
  });
}
