import { expect } from '@ohos/hypium';
import {
  auditedDescribe as describe,
  auditedIt as it
} from '../main/ets/services/FocusedTestRegistrationAudit';
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
  moonlightCloudDeletionTombstone,
  moonlightPreservedLocalAfterCloudDelete,
  moonlightRecordTypeIsPublicCloudData
} from '../main/ets/services/MoonlightCloudDeletionPolicy';
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

class MemoryDeletionPort implements MoonlightDeletionCommandPort {
  activeLease: AccountSessionLease | null = lease();
  rows: Map<string, MoonlightRecord> = new Map<string, MoonlightRecord>();
  physicalCloudRows: Map<string, MoonlightRecord> =
    new Map<string, MoonlightRecord>();
  cache: Map<string, MoonlightAppCacheEntry> =
    new Map<string, MoonlightAppCacheEntry>();
  cacheReadFailure: boolean = false;
  cloudReady: boolean = false;
  writeFailure: boolean = false;
  postCommitVerificationPending: boolean = false;
  switchAfterCommit: boolean = false;
  runtimeStateCount: number = 0;
  commitCount: number = 0;
  prepareAddsHost: boolean = false;
  prepareCount: number = 0;
  cloudTerminal: boolean = false;
  lastRequest: MoonlightDeletionMutationRequest | null = null;

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
    if (!this.isLeaseCurrent(candidate) || this.cacheReadFailure) {
      return null;
    }
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

  async prepareMoonlightCloudDeletion(
    candidate: AccountSessionLease
  ): Promise<boolean> {
    this.prepareCount++;
    if (this.prepareAddsHost && this.isLeaseCurrent(candidate)) {
      this.prepareAddsHost = false;
      const discovered: MoonlightRecord = record(
        'host', 'host-cloud-new', candidate.ownerScopeId);
      this.rows.set(discovered.id, discovered);
    }
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
    if (request.command === 'delete_cloud_data' &&
        request.persistCloudDeletionIntent && !this.cloudReady) {
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
    this.lastRequest = {
      command: request.command,
      recordIds: request.recordIds.slice(),
      cacheIds: request.cacheIds.slice(),
      persistCloudDeletionIntent: request.persistCloudDeletionIntent,
      clearOwnerRuntimeState: request.clearOwnerRuntimeState,
      expectedRuntimeStateCount: request.expectedRuntimeStateCount,
      nowMs: request.nowMs
    };
    // Model the production contract: explicit cloud-wide deletion mutates the
    // physical projection, while ordinary selected deletion stages durable
    // local tombstones without depending on current cloud availability.
    if (request.command === 'delete_cloud_data') {
      const cloudIds: string[] = [];
      this.physicalCloudRows.forEach((value: MoonlightRecord): void => {
        if (value.userId === candidate.ownerScopeId) {
          cloudIds.push(value.id);
        }
      });
      for (let i = 0; i < cloudIds.length; i++) {
        const id: string = cloudIds[i];
        const cloud: MoonlightRecord =
          this.physicalCloudRows.get(id) as MoonlightRecord;
        const local: MoonlightRecord | undefined = this.rows.get(id);
        const deleted: MoonlightRecord | null =
          moonlightRecordTypeIsPublicCloudData(cloud) ?
            moonlightCloudDeletionTombstone(
              local === undefined ? null : local,
              cloud, request.nowMs) : null;
        if (deleted === null) { this.physicalCloudRows.delete(id); }
        else { this.physicalCloudRows.set(id, deleted); }
      }
      const localIds: string[] = [];
      this.rows.forEach((value: MoonlightRecord): void => {
        if (value.userId === candidate.ownerScopeId &&
            value.deletedAt === 0 &&
            moonlightRecordTypeIsPublicCloudData(value)) {
          localIds.push(value.id);
        }
      });
      for (let i = 0; i < localIds.length; i++) {
        const id: string = localIds[i];
        const current: MoonlightRecord = this.rows.get(id) as MoonlightRecord;
        const boundary: MoonlightRecord | undefined =
          this.physicalCloudRows.get(id);
        const preserved: MoonlightRecord | null =
          moonlightPreservedLocalAfterCloudDelete(
            current, boundary === undefined ? null : boundary,
            candidate, request.nowMs, i);
        if (preserved !== null) { this.rows.set(id, preserved); }
      }
    } else {
      for (let i = 0; i < request.recordIds.length; i++) {
        const id: string = request.recordIds[i];
        const current: MoonlightRecord | undefined = this.rows.get(id);
        if (request.persistCloudDeletionIntent && current !== undefined &&
            moonlightRecordTypeIsPublicCloudData(current)) {
          const deleted: MoonlightRecord | null =
            moonlightCloudDeletionTombstone(
              current, current, request.nowMs);
          if (deleted !== null) { this.rows.set(id, deleted); }
        } else {
          this.rows.delete(id);
        }
      }
      for (let i = 0; i < request.cacheIds.length; i++) {
        this.cache.delete(request.cacheIds[i]);
      }
    }
    if (request.clearOwnerRuntimeState) { this.runtimeStateCount = 0; }
    this.commitCount++;
    if (this.switchAfterCommit) {
      this.activeLease = lease('owner-b', 2, 2);
    }
    return {
      ok: true,
      code: this.postCommitVerificationPending ?
        'local_verification_pending' : 'ok',
      localCommitted: request.command === 'delete_cloud_data' ||
        request.recordIds.length > 0 || request.cacheIds.length > 0 ||
        request.clearOwnerRuntimeState,
      cloudAttempted: request.command === 'delete_cloud_data' &&
        request.persistCloudDeletionIntent,
      cloudTerminal: request.command === 'delete_cloud_data' &&
        request.persistCloudDeletionIntent && this.cloudTerminal
    };
  }
}

class MemorySelectionPort implements MoonlightDeletionSelectionPort {
  snapshotValue: MoonlightDeletionSelectionSnapshot = {
    physicalSelected: false,
    selectedScopes: ['settings', 'hosts', 'profiles']
  };
  cancelFailure: boolean = false;
  snapshotReadable: boolean = true;
  cancelCount: number = 0;

  selectionSnapshot(
    _candidate: AccountSessionLease
  ): MoonlightDeletionSelectionSnapshot | null {
    if (!this.snapshotReadable) { return null; }
    return {
      physicalSelected: this.snapshotValue.physicalSelected,
      selectedScopes: this.snapshotValue.selectedScopes.slice()
    };
  }

  cancelAllMoonlightSync(_candidate: AccountSessionLease): boolean {
    if (this.cancelFailure) { return false; }
    this.snapshotValue = {
      physicalSelected: false,
      selectedScopes: ['settings', 'hosts', 'profiles']
    };
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
    port.physicalCloudRows.set(
      records[i].id, MoonlightRecord.fromJSON(records[i].toJSON()));
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

    it('stops_selected_moonlight_sync_before_a_local_only_wipe', 0,
      async (): Promise<void> => {
        const port = seededPort();
        const selection = new MemorySelectionPort();
        selection.snapshotValue = {
          physicalSelected: true,
          selectedScopes: ['settings', 'hosts', 'profiles']
        };
        const identity = new MemoryIdentityPort();
        const service = new MoonlightDeletionCommandService(
          port, selection, null, identity);
        const preview = service.preview(lease(), 'delete_local_data');
        expect(preview.impact.selectionChanged).assertTrue();
        const result = await service.execute(lease(), preview, 300);
        expect(result.ok).assertTrue();
        expect(result.selectionChanged).assertTrue();
        expect(result.cloudAttempted).assertFalse();
        expect(selection.cancelCount).assertEqual(1);
        expect(port.rows.size).assertEqual(0);
      });

    it('keeps_the_fixed_logical_projection_from_blocking_local_cleanup',
      0, async (): Promise<void> => {
        const port = seededPort();
        const selection = new MemorySelectionPort();
        // The fixed logical projection is not an active cloud relationship
        // while the physical Moonlight table is stopped.
        selection.snapshotValue = {
          physicalSelected: false,
          selectedScopes: ['settings', 'hosts', 'profiles']
        };
        const identity = new MemoryIdentityPort();
        const service = new MoonlightDeletionCommandService(
          port, selection, null, identity);
        const preview = service.preview(lease(), 'delete_local_data');
        expect(preview.code).assertEqual('ok');
        expect(preview.impact.cloudTombstonesRequired).assertEqual(0);
        expect(preview.impact.selectionChanged).assertFalse();
        const result = await service.execute(lease(), preview, 300);
        expect(result.ok).assertTrue();
        expect(result.cloudAttempted).assertFalse();
        expect(selection.cancelCount).assertEqual(0);
        expect(port.rows.size).assertEqual(0);
      });

    it('leaves_local_rows_and_identity_intact_when_sync_cannot_be_stopped', 0,
      async (): Promise<void> => {
        const port = seededPort();
        const selection = new MemorySelectionPort();
        selection.snapshotValue = {
          physicalSelected: true,
          selectedScopes: ['settings', 'hosts']
        };
        selection.cancelFailure = true;
        const identity = new MemoryIdentityPort();
        const service = new MoonlightDeletionCommandService(
          port, selection, null, identity);
        const preview = service.preview(lease(), 'delete_local_data');
        const result = await service.execute(lease(), preview, 300);
        expect(result.code).assertEqual('selection_failed');
        expect(result.localCommitted).assertFalse();
        expect(port.commitCount).assertEqual(0);
        expect(identity.calls).assertEqual(0);
        expect(port.rows.size).assertEqual(8);
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
        expect(result.identityAttempted).assertFalse();
        expect(result.identitySucceeded).assertFalse();
        expect(result.localCommitted).assertFalse();
        expect(identity.calls).assertEqual(0);
        expect(identity.identityCount).assertEqual(1);
        expect(port.rows.has('identity-1')).assertTrue();
      });

    it('keeps_committed_local_delete_retryable_when_identity_cleanup_fails', 0,
      async (): Promise<void> => {
        const port = seededPort();
        const identity = new MemoryIdentityPort();
        identity.succeed = false;
        const service = new MoonlightDeletionCommandService(
          port, null, null, identity);
        const preview = service.preview(lease(), 'delete_local_data');
        const result = await service.execute(lease(), preview, 300);
        expect(result.code).assertEqual('identity_delete_failed');
        expect(result.localCommitted).assertTrue();
        expect(result.identityAttempted).assertTrue();
        expect(result.identitySucceeded).assertFalse();
        expect(port.rows.size).assertEqual(0);
        expect(identity.identityCount).assertEqual(1);
        const retryPreview = service.preview(lease(), 'delete_local_data');
        expect(retryPreview.code).assertEqual('ok');
        identity.succeed = true;
        const retry = await service.execute(lease(), retryPreview, 301);
        expect(retry.ok).assertTrue();
        expect(identity.identityCount).assertEqual(0);
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

    it('always_sweeps_native_owner_identity_after_an_interrupted_pairing', 0,
      async (): Promise<void> => {
        const port = new MemoryDeletionPort();
        const identity = new MemoryIdentityPort();
        // Zero is only the last verified native result. A pairing that was
        // interrupted before metadata commit may have created a new orphan
        // since then, so the explicit local wipe must remain actionable.
        identity.identityCount = 0;
        const service = new MoonlightDeletionCommandService(
          port, null, null, identity);
        const preview = service.preview(lease(), 'delete_local_data');
        expect(preview.code).assertEqual('ok');
        expect(preview.impact.localRowsRemoved).assertEqual(0);
        expect(preview.impact.secureIdentitiesRemoved).assertEqual(0);
        const result = await service.execute(lease(), preview, 300);
        expect(result.ok).assertTrue();
        expect(result.identityAttempted).assertTrue();
        expect(result.identitySucceeded).assertTrue();
        expect(identity.calls).assertEqual(1);
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
        expect((port.rows.get('host-1') as MoonlightRecord).deletedAt)
          .assertEqual(300);
        expect((port.rows.get('profile-1') as MoonlightRecord).deletedAt)
          .assertEqual(300);
        expect(port.rows.has('trust-1')).assertFalse();
        expect(port.cache.size).assertEqual(1);
      });

    it('does_not_require_a_non_deployed_cloud_table_to_forget_a_local_host',
      0, async (): Promise<void> => {
        const port = seededPort();
        const selection = new MemorySelectionPort();
        selection.snapshotValue = {
          physicalSelected: false,
          selectedScopes: ['hosts', 'profiles']
        };
        const service = new MoonlightDeletionCommandService(
          port, selection);
        const preview = service.preview(
          lease(), 'forget_host', 'host-1');
        expect(preview.code).assertEqual('ok');
        expect(preview.impact.cloudTombstonesRequired).assertEqual(0);
        const result = await service.execute(lease(), preview, 300);
        expect(result.ok).assertTrue();
        expect(result.cloudAttempted).assertFalse();
        expect(port.prepareCount).assertEqual(0);
        expect((port.rows.get('host-1') as MoonlightRecord).deletedAt)
          .assertEqual(300);
        expect((port.rows.get('profile-1') as MoonlightRecord).deletedAt)
          .assertEqual(300);
        expect(port.rows.has('trust-1')).assertFalse();
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

    it('keeps_all_local_rows_while_cloud_wide_deletion_waits_for_upload',
      0, async (): Promise<void> => {
        const port = seededPort();
        port.cloudReady = true;
        const selection = new MemorySelectionPort();
        selection.snapshotValue = {
          physicalSelected: true,
          selectedScopes: ['settings', 'hosts', 'profiles']
        };
        const service = new MoonlightDeletionCommandService(
          port, selection);
        const preview = service.preview(
          lease(), 'delete_cloud_data');
        expect(preview.code).assertEqual('ok');
        const result = await service.execute(
          lease(), preview, 300);
        expect(result.ok).assertTrue();
        expect(result.code).assertEqual('pending_cloud');
        expect(result.cloudAttempted).assertTrue();
        expect(result.cloudTerminal).assertFalse();
        expect(port.rows.size).assertEqual(8);
        expect(port.rows.has('trust-1')).assertTrue();
        expect(port.rows.has('identity-1')).assertTrue();
        expect(port.physicalCloudRows.size).assertEqual(5);
        expect((port.physicalCloudRows.get('host-1') as
          MoonlightRecord).deletedAt > 0).assertTrue();
        expect((port.physicalCloudRows.get('profile-1') as
          MoonlightRecord).deletedAt > 0).assertTrue();
        expect(port.physicalCloudRows.has('trust-1')).assertFalse();
        expect(port.physicalCloudRows.has('identity-1')).assertFalse();
        expect((port.rows.get('host-1') as MoonlightRecord).resetEpoch)
          .assertEqual(1);
        expect(port.prepareCount).assertEqual(1);
        expect(port.lastRequest?.command)
          .assertEqual('delete_cloud_data');
        expect(port.lastRequest?.clearOwnerRuntimeState)
          .assertFalse();
        expect(selection.cancelCount).assertEqual(0);
      });

    it('stages_targeted_tombstones_locally_without_touching_cloud_first', 0,
      async (): Promise<void> => {
        const port = seededPort();
        port.cloudReady = true;
        const selection = new MemorySelectionPort();
        selection.snapshotValue = {
          physicalSelected: true,
          selectedScopes: ['hosts', 'profiles']
        };
        const service = new MoonlightDeletionCommandService(
          port, selection);
        const preview = service.preview(
          lease(), 'forget_host', 'host-1');
        const result = await service.execute(
          lease(), preview, 300);
        expect(result.code).assertEqual('pending_cloud');
        expect(result.ok).assertTrue();
        expect(result.localCommitted).assertTrue();
        expect(result.cloudAttempted).assertFalse();
        expect(port.prepareCount).assertEqual(0);
        expect((port.physicalCloudRows.get('host-1') as
          MoonlightRecord).deletedAt).assertEqual(0);
        expect((port.physicalCloudRows.get('profile-1') as
          MoonlightRecord).deletedAt).assertEqual(0);
        expect((port.rows.get('host-1') as
          MoonlightRecord).deletedAt).assertEqual(300);
        expect((port.rows.get('profile-1') as
          MoonlightRecord).deletedAt).assertEqual(300);
        expect(port.rows.has('trust-1')).assertFalse();
      });

    it('never_blocks_selected_host_delete_when_cloud_space_is_unavailable',
      0, async (): Promise<void> => {
        const port = seededPort();
        port.cloudReady = false;
        const selection = new MemorySelectionPort();
        selection.snapshotValue = {
          physicalSelected: true,
          selectedScopes: ['settings', 'hosts', 'profiles']
        };
        const service = new MoonlightDeletionCommandService(
          port, selection);
        const preview = service.preview(
          lease(), 'forget_host', 'host-1');
        expect(preview.code).assertEqual('ok');
        expect(preview.impact.cloudTombstonesRequired).assertEqual(2);
        const result = await service.execute(
          lease(), preview, 300);
        expect(result.ok).assertTrue();
        expect(result.code).assertEqual('pending_cloud');
        expect(result.localCommitted).assertTrue();
        expect(result.cloudAttempted).assertFalse();
        expect(port.prepareCount).assertEqual(0);
        expect((port.rows.get('host-1') as
          MoonlightRecord).deletedAt).assertEqual(300);
        expect((port.rows.get('profile-1') as
          MoonlightRecord).deletedAt).assertEqual(300);
        expect(port.rows.has('trust-1')).assertFalse();
        expect(port.cache.size).assertEqual(1);
      });

    it('keeps_ordinary_local_delete_available_when_selection_state_is_unreadable',
      0, async (): Promise<void> => {
        const port = seededPort();
        const selection = new MemorySelectionPort();
        selection.snapshotReadable = false;
        const service = new MoonlightDeletionCommandService(
          port, selection);
        const preview = service.preview(
          lease(), 'forget_host', 'host-1');
        expect(preview.code).assertEqual('ok');
        const result = await service.execute(
          lease(), preview, 300);
        expect(result.ok).assertTrue();
        expect(result.code).assertEqual('ok');
        expect((port.rows.get('host-1') as
          MoonlightRecord).deletedAt).assertEqual(300);
        expect(port.rows.has('trust-1')).assertFalse();
      });

    it('ignores_unrelated_malformed_rows_and_rebuildable_cache_during_delete',
      0, async (): Promise<void> => {
        const port = seededPort();
        const malformed: MoonlightRecord = record(
          'profile', 'profile-corrupt', 'owner-a', 'host-2');
        malformed.payloadHashSha256 = '0'.repeat(64);
        port.rows.set(malformed.id, malformed);
        const brokenCache: MoonlightAppCacheEntry =
          cacheEntry('host-2', 'broken-app');
        brokenCache.title = '';
        port.cache.set(brokenCache.id, brokenCache);
        const service = new MoonlightDeletionCommandService(port);
        const preview = service.preview(
          lease(), 'forget_host', 'host-1');
        expect(preview.code).assertEqual('ok');
        const result = await service.execute(lease(), preview, 300);
        expect(result.ok).assertTrue();
        expect(port.rows.has('host-1')).assertFalse();
        expect(port.rows.has('host-2')).assertTrue();
      });

    it('requires_reconfirmation_when_the_authoritative_pull_finds_more_data',
      0, async (): Promise<void> => {
        const port = seededPort();
        port.cloudReady = true;
        port.prepareAddsHost = true;
        const selection = new MemorySelectionPort();
        selection.snapshotValue = {
          physicalSelected: true,
          selectedScopes: ['settings', 'hosts', 'profiles']
        };
        const service = new MoonlightDeletionCommandService(
          port, selection);
        const preview = service.preview(
          lease(), 'delete_cloud_data');
        const result = await service.execute(
          lease(), preview, 300);
        expect(result.code).assertEqual('stale_preview');
        expect(port.commitCount).assertEqual(0);
        expect(port.rows.has('host-cloud-new')).assertTrue();
      });

    it('revokes_local_trust_when_no_remote_host_control_port_is_ready', 0,
      async (): Promise<void> => {
        const port = seededPort();
        const service = new MoonlightDeletionCommandService(port);
        const preview = service.preview(
          lease(), 'unpair_host', 'host-1');
        const result = await service.execute(lease(), preview, 300);
        expect(result.ok).assertTrue();
        expect(result.code).assertEqual('ok_with_remote_warning');
        expect(result.hostAttempted).assertTrue();
        expect(result.hostSucceeded).assertFalse();
        expect(port.rows.has('trust-1')).assertFalse();
        expect(port.commitCount).assertEqual(1);
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

    it('never_requests_a_cloud_delete_when_unpairing_a_selected_host',
      0, async (): Promise<void> => {
        const port = seededPort();
        const selection = new MemorySelectionPort();
        selection.snapshotValue = {
          physicalSelected: true,
          selectedScopes: ['hosts', 'profiles']
        };
        const host = new MemoryHostPort();
        const service = new MoonlightDeletionCommandService(
          port, selection, host);
        const preview = service.preview(
          lease(), 'unpair_host', 'host-1');
        const result = await service.execute(
          lease(), preview, 300);
        expect(result.ok).assertTrue();
        expect(result.cloudAttempted).assertFalse();
        expect(port.lastRequest?.persistCloudDeletionIntent)
          .assertFalse();
        expect(port.rows.has('trust-1')).assertFalse();
        expect(port.rows.has('host-1')).assertTrue();
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

    it('does_not_make_the_user_repeat_an_already_committed_local_delete', 0,
      async (): Promise<void> => {
        const port = seededPort();
        port.postCommitVerificationPending = true;
        const service = new MoonlightDeletionCommandService(port);
        const preview = service.preview(
          lease(), 'forget_host', 'host-1');
        const result = await service.execute(lease(), preview, 300);
        expect(result.ok).assertTrue();
        expect(result.code).assertEqual('pending_local_verification');
        expect(result.localCommitted).assertTrue();
        expect((port.rows.get('host-1') as MoonlightRecord).deletedAt)
          .assertEqual(300);
        expect(port.commitCount).assertEqual(1);
      });

    it('deletes_an_authoritative_host_when_the_rebuildable_cache_cannot_be_read',
      0, async (): Promise<void> => {
        const port = seededPort();
        port.cacheReadFailure = true;
        const service = new MoonlightDeletionCommandService(port);
        const preview = service.preview(
          lease(), 'forget_host', 'host-1');
        expect(preview.code).assertEqual('ok');
        expect(preview.context.appCacheCount).assertEqual(0);
        const result = await service.execute(lease(), preview, 300);
        expect(result.ok).assertTrue();
        expect(result.localCommitted).assertTrue();
        expect((port.rows.get('host-1') as MoonlightRecord).deletedAt)
          .assertEqual(300);
      });

    it('returns_unchanged_when_the_physical_moonlight_table_is_stopped', 0,
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

    it('cancels_only_the_physical_table_and_keeps_the_fixed_projection', 0,
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
        expect(selection.snapshotValue.selectedScopes.join(','))
          .assertEqual('settings,hosts,profiles');
      });
  });
}
