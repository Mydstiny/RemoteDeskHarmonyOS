import {
  MoonlightRecord,
  MoonlightRecordType
} from '../model/MoonlightRecord';
import {
  MoonlightAppCacheEntry,
  moonlightAppCacheEntryIsValid
} from '../model/MoonlightAppCache';
import {
  AccountSessionLease,
  accountSessionLeaseEquals,
  cloneAccountSessionLease
} from './AccountScopePolicy';
import {
  MoonlightCloudSyncScope,
  normalizeMoonlightCloudSyncSelection
} from './MoonlightCloudSyncSelectionPolicy';
import {
  MoonlightDeletionCommandType,
  MoonlightDeletionContext,
  MoonlightDeletionImpact,
  moonlightDeletionCommandTypeIsKnown,
  resolveMoonlightDeletionImpact
} from './MoonlightDeletionPolicy';
import {
  moonlightRecordBusinessPayload,
  moonlightValidateRecord
} from './MoonlightRecordPolicy';
import { moonlightCanonicalHostRecordId } from './MoonlightBackupPolicy';

export type MoonlightDeletionPreviewCode =
  'ok' | 'unchanged' | 'invalid_request' | 'stale_lease' |
  'read_failed' | 'invalid_data' | 'not_found' | 'cloud_unavailable';

export type MoonlightDeletionCommandCode =
  'ok' | 'unchanged' | 'invalid_request' | 'stale_lease' |
  'stale_preview' | 'read_failed' | 'invalid_data' | 'not_found' |
  'selection_unavailable' | 'selection_failed' | 'cloud_unavailable' |
  'host_unavailable' | 'identity_unavailable' |
  'identity_delete_failed' | 'local_write_failed' | 'pending_cloud' |
  'pending_local_verification' | 'ok_with_remote_warning';

export type MoonlightDeletionMutationCode =
  'ok' | 'stale_lease' | 'invalid_request' |
  'cloud_unavailable' | 'write_failed' | 'local_verification_pending';

export interface MoonlightDeletionSelectionSnapshot {
  physicalSelected: boolean;
  selectedScopes: MoonlightCloudSyncScope[];
}

export interface MoonlightDeletionMutationRequest {
  command: MoonlightDeletionCommandType;
  recordIds: string[];
  cacheIds: string[];
  /** Preserve a durable cloud deletion intent; ordinary deletes stage it in
   * the local overlay, while delete_cloud_data owns the strict cloud commit. */
  persistCloudDeletionIntent: boolean;
  clearOwnerRuntimeState: boolean;
  expectedRuntimeStateCount: number;
  nowMs: number;
}

export interface MoonlightDeletionMutationResult {
  ok: boolean;
  code: MoonlightDeletionMutationCode;
  localCommitted: boolean;
  cloudAttempted: boolean;
  cloudTerminal: boolean;
}

export interface MoonlightDeletionPreview {
  code: MoonlightDeletionPreviewCode;
  command: MoonlightDeletionCommandType;
  ownerScopeId: string;
  hostId: string;
  profileId: string;
  recordIds: string[];
  identityRecordIds: string[];
  cacheIds: string[];
  artworkPaths: string[];
  context: MoonlightDeletionContext;
  impact: MoonlightDeletionImpact;
}

export interface MoonlightDeletionCommandResult {
  ok: boolean;
  code: MoonlightDeletionCommandCode;
  impact: MoonlightDeletionImpact;
  localCommitted: boolean;
  cloudAttempted: boolean;
  cloudTerminal: boolean;
  selectionChanged: boolean;
  hostAttempted: boolean;
  hostSucceeded: boolean;
  identityAttempted: boolean;
  identitySucceeded: boolean;
  artworkPathsToDelete: string[];
}

export interface MoonlightDeletionCommandPort {
  currentAccountLease(): AccountSessionLease | null;
  isLeaseCurrent(lease: AccountSessionLease): boolean;
  loadMoonlightLocalRecords(
    lease: AccountSessionLease, includeDeleted?: boolean
  ): MoonlightRecord[] | null;
  loadMoonlightAppCacheEntries(
    lease: AccountSessionLease, hostId?: string
  ): MoonlightAppCacheEntry[] | null;
  moonlightOwnerRuntimeStateCount(
    lease: AccountSessionLease,
    recordIds: string[],
    includeOwnerMarker: boolean
  ): number;
  moonlightCloudDeletionReady(lease: AccountSessionLease): boolean;
  prepareMoonlightCloudDeletion(
    lease: AccountSessionLease
  ): Promise<boolean>;
  commitMoonlightDeletion(
    lease: AccountSessionLease,
    request: MoonlightDeletionMutationRequest
  ): MoonlightDeletionMutationResult;
}

export interface MoonlightDeletionSelectionPort {
  selectionSnapshot(
    lease: AccountSessionLease
  ): MoonlightDeletionSelectionSnapshot | null;
  cancelAllMoonlightSync(lease: AccountSessionLease): boolean;
}

export interface MoonlightHostUnpairPort {
  isHostUnpairReady(
    lease: AccountSessionLease, hostId: string
  ): boolean;
  requestHostUnpair(
    lease: AccountSessionLease, hostId: string
  ): Promise<boolean>;
}

export interface MoonlightIdentityDeletionPort {
  localIdentityCount(lease: AccountSessionLease): number;
  isIdentityDeletionReady(
    lease: AccountSessionLease, identityRecordIds: string[]
  ): boolean;
  deleteLocalIdentities(
    lease: AccountSessionLease, identityRecordIds: string[],
    clearAllForOwner: boolean
  ): Promise<boolean>;
}

function deletionContext(ownerScopeId: string,
  hostId: string, profileId: string): MoonlightDeletionContext {
  return {
    ownerScopeId,
    hostId,
    profileId,
    physicalCloudSelected: false,
    selectedLogicalScopeCount: 0,
    settingsRecordCount: 0,
    hostRecordCount: 0,
    profileRecordCount: 0,
    trustRecordCount: 0,
    identityRecordCount: 0,
    appCacheCount: 0,
    localRuntimeStateCount: 0,
    secureIdentityCount: 0
  };
}

function previewValue(code: MoonlightDeletionPreviewCode,
  command: MoonlightDeletionCommandType,
  context: MoonlightDeletionContext,
  recordIds: string[] = [], identityRecordIds: string[] = [],
  cacheIds: string[] = [],
  artworkPaths: string[] = []): MoonlightDeletionPreview {
  return {
    code,
    command,
    ownerScopeId: context.ownerScopeId,
    hostId: context.hostId,
    profileId: context.profileId,
    recordIds: recordIds.slice(),
    identityRecordIds: identityRecordIds.slice(),
    cacheIds: cacheIds.slice(),
    artworkPaths: artworkPaths.slice(),
    context,
    impact: resolveMoonlightDeletionImpact(command, context)
  };
}

function commandResult(ok: boolean, code: MoonlightDeletionCommandCode,
  impact: MoonlightDeletionImpact,
  localCommitted: boolean = false,
  cloudAttempted: boolean = false,
  cloudTerminal: boolean = false,
  selectionChanged: boolean = false,
  hostAttempted: boolean = false,
  hostSucceeded: boolean = false,
  identityAttempted: boolean = false,
  identitySucceeded: boolean = false,
  artworkPaths: string[] = []): MoonlightDeletionCommandResult {
  return {
    ok,
    code,
    impact,
    localCommitted,
    cloudAttempted,
    cloudTerminal,
    selectionChanged,
    hostAttempted,
    hostSucceeded,
    identityAttempted,
    identitySucceeded,
    artworkPathsToDelete: artworkPaths.slice()
  };
}

function idsEqual(left: string[], right: string[]): boolean {
  if (left.length !== right.length) { return false; }
  for (let i = 0; i < left.length; i++) {
    if (left[i] !== right[i]) { return false; }
  }
  return true;
}

function contextEquals(
  left: MoonlightDeletionContext,
  right: MoonlightDeletionContext
): boolean {
  return left.ownerScopeId === right.ownerScopeId &&
    left.hostId === right.hostId && left.profileId === right.profileId &&
    left.physicalCloudSelected === right.physicalCloudSelected &&
    left.selectedLogicalScopeCount === right.selectedLogicalScopeCount &&
    left.settingsRecordCount === right.settingsRecordCount &&
    left.hostRecordCount === right.hostRecordCount &&
    left.profileRecordCount === right.profileRecordCount &&
    left.trustRecordCount === right.trustRecordCount &&
    left.identityRecordCount === right.identityRecordCount &&
    left.appCacheCount === right.appCacheCount &&
    left.localRuntimeStateCount === right.localRuntimeStateCount &&
    left.secureIdentityCount === right.secureIdentityCount;
}

function previewsEqual(
  left: MoonlightDeletionPreview,
  right: MoonlightDeletionPreview
): boolean {
  return left.code === right.code && left.command === right.command &&
    contextEquals(left.context, right.context) &&
    idsEqual(left.recordIds, right.recordIds) &&
    idsEqual(left.identityRecordIds, right.identityRecordIds) &&
    idsEqual(left.cacheIds, right.cacheIds) &&
    idsEqual(left.artworkPaths, right.artworkPaths);
}

function recordIsTarget(
  command: MoonlightDeletionCommandType,
  record: MoonlightRecord,
  hostIds: string[],
  profileId: string
): boolean {
  if (command === 'delete_cloud_data' ||
      command === 'delete_local_data') { return true; }
  if (command === 'forget_host') {
    return (record.recordType === 'host' &&
      hostIds.indexOf(record.id) >= 0) ||
      ((record.recordType === 'profile' ||
        record.recordType === 'trust') &&
        hostIds.indexOf(record.ownerId) >= 0);
  }
  if (command === 'unpair_host') {
    return record.recordType === 'trust' &&
      hostIds.indexOf(record.ownerId) >= 0;
  }
  if (command === 'delete_profile') {
    return record.recordType === 'profile' && record.id === profileId &&
      (hostIds.length === 0 || hostIds.indexOf(record.ownerId) >= 0);
  }
  return false;
}

function countRecord(
  context: MoonlightDeletionContext,
  type: MoonlightRecordType
): void {
  if (type === 'settings') { context.settingsRecordCount++; }
  else if (type === 'host') { context.hostRecordCount++; }
  else if (type === 'profile') { context.profileRecordCount++; }
  else if (type === 'trust') { context.trustRecordCount++; }
  else { context.identityRecordCount++; }
}

function idIsBounded(value: string): boolean {
  const trimmed: string = value.trim();
  return value === trimmed && trimmed.length > 0 && trimmed.length <= 128;
}

export class MoonlightDeletionCommandService {
  private readonly port: MoonlightDeletionCommandPort;
  private readonly selectionPort: MoonlightDeletionSelectionPort | null;
  private readonly hostPort: MoonlightHostUnpairPort | null;
  private readonly identityPort: MoonlightIdentityDeletionPort | null;

  constructor(port: MoonlightDeletionCommandPort,
    selectionPort: MoonlightDeletionSelectionPort | null = null,
    hostPort: MoonlightHostUnpairPort | null = null,
    identityPort: MoonlightIdentityDeletionPort | null = null) {
    this.port = port;
    this.selectionPort = selectionPort;
    this.hostPort = hostPort;
    this.identityPort = identityPort;
  }

  preview(lease: AccountSessionLease,
    command: MoonlightDeletionCommandType,
    hostId: string = '', profileId: string = ''): MoonlightDeletionPreview {
    const captured: AccountSessionLease = cloneAccountSessionLease(lease);
    const host: string = hostId.trim();
    const profile: string = profileId.trim();
    const context: MoonlightDeletionContext = deletionContext(
      captured.ownerScopeId, host, profile);
    if (!moonlightDeletionCommandTypeIsKnown(command)) {
      return previewValue('invalid_request', command, context);
    }
    if (!this.leaseIsCurrent(captured) ||
        captured.ownerScopeId.trim() === '') {
      return previewValue('stale_lease', command, context);
    }
    if ((host !== '' && !idIsBounded(host)) ||
        (profile !== '' && !idIsBounded(profile)) ||
        ((command === 'forget_host' || command === 'unpair_host') &&
          host === '') ||
        (command === 'delete_profile' && profile === '')) {
      return previewValue('invalid_request', command, context);
    }
    if (this.selectionPort !== null) {
      const selection: MoonlightDeletionSelectionSnapshot | null =
        this.selectionPort.selectionSnapshot(captured);
      if (selection === null ||
          typeof selection.physicalSelected !== 'boolean') {
        // A corrupt/unreadable cloud preference must never make an ordinary
        // local host/profile delete impossible. The command will persist a
        // local tombstone independently of this best-effort status snapshot.
        if (command !== 'forget_host' && command !== 'delete_profile' &&
            command !== 'unpair_host') {
          return previewValue('read_failed', command, context);
        }
      } else {
        const normalized: MoonlightCloudSyncScope[] =
          normalizeMoonlightCloudSyncSelection(
            selection.selectedScopes, true);
        if (!idsEqual(normalized, selection.selectedScopes)) {
          if (command !== 'forget_host' && command !== 'delete_profile' &&
              command !== 'unpair_host') {
            return previewValue('invalid_data', command, context);
          }
        } else {
          context.physicalCloudSelected = selection.physicalSelected;
          context.selectedLogicalScopeCount = normalized.length;
        }
      }
    }
    if (command === 'cancel_sync') {
      const impact: MoonlightDeletionImpact =
        resolveMoonlightDeletionImpact(command, context);
      return previewValue(impact.selectionChanged ? 'ok' : 'unchanged',
        command, context);
    }
    if (command === 'delete_cloud_data' &&
        !this.port.moonlightCloudDeletionReady(captured)) {
      return previewValue('cloud_unavailable', command, context);
    }
    const records: MoonlightRecord[] | null =
      this.port.loadMoonlightLocalRecords(captured, true);
    const loadedCache: MoonlightAppCacheEntry[] | null =
      this.port.loadMoonlightAppCacheEntries(captured);
    if (records === null || !this.leaseIsCurrent(captured)) {
      return previewValue(this.leaseIsCurrent(captured) ?
        'read_failed' : 'stale_lease', command, context);
    }
    // Catalog rows are a rebuildable presentation cache. A cache read failure
    // must not prevent authoritative host/profile/trust tombstones or an
    // owner-wide local wipe; the CloudStore mutation still performs its own
    // fenced transaction and owner-wide cleanup where applicable.
    const cache: MoonlightAppCacheEntry[] =
      loadedCache === null ? [] : loadedCache;
    // Pre-release builds used more than one host-id derivation. Resolve every
    // live alias of the selected Sunshine UUID before calculating the graph,
    // so forget/unpair cannot remove a canonical root while leaving its
    // profiles, trust, cache or runtime state behind.
    const logicalHostIds: string[] = host === '' ? [] : [host];
    let targetServerUuid: string = '';
    if (command === 'forget_host' || command === 'unpair_host') {
      for (let i = 0; i < records.length; i++) {
        if (records[i].id !== host || records[i].recordType !== 'host' ||
            records[i].deletedAt > 0 ||
            !moonlightValidateRecord(records[i]).valid) {
          continue;
        }
        const payload: Record<string, Object> | null =
          moonlightRecordBusinessPayload(records[i]);
        if (payload !== null && typeof payload['serverUuid'] === 'string') {
          targetServerUuid = payload['serverUuid'] as string;
        }
        break;
      }
      if (targetServerUuid !== '') {
        const canonicalHostId: string = moonlightCanonicalHostRecordId(
          captured.ownerScopeId, targetServerUuid);
        if (canonicalHostId !== '' &&
            logicalHostIds.indexOf(canonicalHostId) < 0) {
          logicalHostIds.push(canonicalHostId);
        }
        for (let i = 0; i < records.length; i++) {
          if (records[i].deletedAt > 0 ||
              !moonlightValidateRecord(records[i]).valid ||
              (records[i].recordType !== 'host' &&
               records[i].recordType !== 'trust')) {
            continue;
          }
          const payload: Record<string, Object> | null =
            moonlightRecordBusinessPayload(records[i]);
          if (payload === null ||
              payload['serverUuid'] !== targetServerUuid) {
            continue;
          }
          const aliasHostId: string = records[i].recordType === 'host' ?
            records[i].id : records[i].ownerId;
          if (logicalHostIds.indexOf(aliasHostId) < 0) {
            logicalHostIds.push(aliasHostId);
          }
        }
      }
    }
    const recordIds: string[] = [];
    const identityRecordIds: string[] = [];
    const cacheIds: string[] = [];
    const artworkPaths: string[] = [];
    let hostExists: boolean = false;
    let profileExists: boolean = false;
    const allRecordIds: string[] = [];
    for (let i = 0; i < records.length; i++) {
      const record: MoonlightRecord = records[i];
      if (record.userId !== captured.ownerScopeId ||
          !moonlightValidateRecord(record).valid) {
        const targetsCorruptRow: boolean = record.id === host ||
          record.id === profile;
        if (targetsCorruptRow) {
          return previewValue('invalid_data', command, context);
        }
        continue;
      }
      if (allRecordIds.indexOf(record.id) >= 0) {
        return previewValue('invalid_data', command, context);
      }
      allRecordIds.push(record.id);
      if (record.deletedAt === 0 &&
          record.recordType === 'host' && record.id === host) {
        hostExists = true;
      }
      if (record.deletedAt === 0 &&
          record.recordType === 'profile' && record.id === profile &&
          (host === '' || record.ownerId === host)) {
        profileExists = true;
      }
      const physicalWipeIncludesTombstones: boolean =
        command === 'delete_cloud_data' || command === 'delete_local_data';
      if ((record.deletedAt === 0 || physicalWipeIncludesTombstones) &&
          recordIsTarget(command, record, logicalHostIds, profile)) {
        recordIds.push(record.id);
        if (record.recordType === 'secret') {
          identityRecordIds.push(record.id);
        }
        countRecord(context, record.recordType);
      }
    }
    const allCacheIds: string[] = [];
    for (let i = 0; i < cache.length; i++) {
      const entry: MoonlightAppCacheEntry = cache[i];
      if (entry.userId !== captured.ownerScopeId ||
          !moonlightAppCacheEntryIsValid(entry)) {
        continue;
      }
      if (allCacheIds.indexOf(entry.id) >= 0) {
        return previewValue('invalid_data', command, context);
      }
      allCacheIds.push(entry.id);
      const targeted: boolean = command === 'delete_local_data' ||
        (command === 'forget_host' &&
          logicalHostIds.indexOf(entry.hostId) >= 0);
      if (targeted) {
        cacheIds.push(entry.id);
        if (entry.artworkLocalPath !== '' &&
            artworkPaths.indexOf(entry.artworkLocalPath) < 0) {
          artworkPaths.push(entry.artworkLocalPath);
        }
      }
    }
    context.appCacheCount = cacheIds.length;
    recordIds.sort();
    identityRecordIds.sort();
    cacheIds.sort();
    artworkPaths.sort();
    if ((command === 'forget_host' || command === 'unpair_host') &&
        !hostExists) {
      return previewValue('not_found', command, context,
        recordIds, identityRecordIds, cacheIds, artworkPaths);
    }
    if (command === 'delete_profile' && !profileExists) {
      return previewValue('not_found', command, context,
        recordIds, identityRecordIds, cacheIds, artworkPaths);
    }
    if (command === 'delete_local_data' || command === 'forget_host' ||
        command === 'unpair_host' || command === 'delete_profile') {
      const runtimeStateCount: number =
        this.port.moonlightOwnerRuntimeStateCount(
          captured, recordIds, command === 'delete_local_data');
      if (!Number.isSafeInteger(runtimeStateCount) ||
          runtimeStateCount < 0 || !this.leaseIsCurrent(captured)) {
        return previewValue(this.leaseIsCurrent(captured) ?
          'read_failed' : 'stale_lease', command, context,
          recordIds, identityRecordIds, cacheIds, artworkPaths);
      }
      context.localRuntimeStateCount = runtimeStateCount;
    }
    if (command === 'delete_local_data') {
      if (this.identityPort === null) {
        context.secureIdentityCount = identityRecordIds.length;
      } else {
        const secureIdentityCount: number =
          this.identityPort.localIdentityCount(captured);
        if (!Number.isSafeInteger(secureIdentityCount) ||
            secureIdentityCount < 0 || !this.leaseIsCurrent(captured)) {
          return previewValue(this.leaseIsCurrent(captured) ?
            'read_failed' : 'stale_lease', command, context,
            recordIds, identityRecordIds, cacheIds, artworkPaths);
        }
        context.secureIdentityCount = secureIdentityCount;
      }
    }
    const impact: MoonlightDeletionImpact =
      resolveMoonlightDeletionImpact(command, context);
    if (!impact.valid) {
      return previewValue('invalid_request', command, context,
        recordIds, identityRecordIds, cacheIds, artworkPaths);
    }
    // The native identity store is intentionally not enumerable from ArkTS.
    // Even when its last verified count is zero, a later interrupted pairing
    // can leave an owner-scoped identity without a matching RDB metadata row.
    // Keep the explicit owner-wide local wipe actionable whenever the native
    // cleanup capability is present; execute() will perform the real inventory
    // and deletion behind the lifecycle gate.
    const nativeIdentitySweepRequired: boolean =
      command === 'delete_local_data' && this.identityPort !== null;
    const unchanged: boolean = !nativeIdentitySweepRequired &&
      !impact.selectionChanged &&
      impact.localRowsRemoved === 0 && impact.cacheRowsRemoved === 0 &&
      impact.localRuntimeStatesRemoved === 0 &&
      impact.secureIdentitiesRemoved === 0 &&
      impact.cloudTombstonesRequired === 0 &&
      !impact.hostRequestBestEffort;
    return previewValue(unchanged ? 'unchanged' : 'ok', command,
      context, recordIds, identityRecordIds, cacheIds, artworkPaths);
  }

  async execute(lease: AccountSessionLease,
    preview: MoonlightDeletionPreview,
    nowMs: number): Promise<MoonlightDeletionCommandResult> {
    const captured: AccountSessionLease = cloneAccountSessionLease(lease);
    if (!this.leaseIsCurrent(captured) ||
        preview.ownerScopeId !== captured.ownerScopeId ||
        !Number.isSafeInteger(nowMs) || nowMs <= 0) {
      return commandResult(false, this.leaseIsCurrent(captured) ?
        'invalid_request' : 'stale_lease', preview.impact);
    }
    let current: MoonlightDeletionPreview = this.preview(
      captured, preview.command, preview.hostId, preview.profileId);
    if (current.code === 'unchanged' && previewsEqual(current, preview)) {
      return commandResult(true, 'unchanged', current.impact);
    }
    if (current.code !== 'ok') {
      const code: MoonlightDeletionCommandCode =
        current.code === 'stale_lease' ? 'stale_lease' :
        current.code === 'read_failed' ? 'read_failed' :
        current.code === 'invalid_data' ? 'invalid_data' :
        current.code === 'not_found' ? 'not_found' : 'invalid_request';
      if (current.code === 'cloud_unavailable') {
        return commandResult(false, 'cloud_unavailable', current.impact);
      }
      return commandResult(false, code, current.impact);
    }
    if (!previewsEqual(current, preview)) {
      return commandResult(false, 'stale_preview', current.impact);
    }
    if (current.command === 'cancel_sync') {
      if (this.selectionPort === null) {
        return commandResult(false, 'selection_unavailable', current.impact);
      }
      const changed: boolean =
        this.selectionPort.cancelAllMoonlightSync(captured);
      if (!changed || !this.leaseIsCurrent(captured)) {
        return commandResult(false, this.leaseIsCurrent(captured) ?
          'selection_failed' : 'stale_lease', current.impact,
          false, false, false, changed);
      }
      return commandResult(true, 'ok', current.impact,
        false, false, false, true);
    }
    const persistCloudDeletionIntent: boolean =
      current.command === 'delete_cloud_data' ||
      current.command === 'forget_host' ||
      current.command === 'delete_profile';
    const cloudSynchronizationPending: boolean =
      current.command === 'delete_cloud_data' ||
      current.impact.cloudTombstonesRequired > 0;
    const cloudWideDeletion: boolean =
      current.command === 'delete_cloud_data';
    if (cloudWideDeletion) {
      // Explicit whole-cloud deletion is the only command that needs an
      // online authoritative boundary before it mutates the physical table.
      // Ordinary host/profile deletion is local-first and persists a
      // tombstone for later conflict-safe promotion.
      let prepared: boolean = false;
      try {
        prepared = await this.port.prepareMoonlightCloudDeletion(captured);
      } catch (_error) {
        prepared = false;
      }
      if (!prepared || !this.leaseIsCurrent(captured)) {
        return commandResult(false, this.leaseIsCurrent(captured) ?
          'cloud_unavailable' : 'stale_lease', current.impact);
      }
      current = this.preview(
        captured, preview.command, preview.hostId, preview.profileId);
      if (current.code !== 'ok') {
        return commandResult(false,
          current.code === 'stale_lease' ? 'stale_lease' :
          current.code === 'cloud_unavailable' ? 'cloud_unavailable' :
          current.code === 'read_failed' ? 'read_failed' :
          current.code === 'invalid_data' ? 'invalid_data' :
          current.code === 'not_found' ? 'not_found' : 'invalid_request',
          current.impact);
      }
      if (!previewsEqual(current, preview)) {
        return commandResult(false, 'stale_preview', current.impact);
      }
    }
    if (cloudWideDeletion &&
        !this.port.moonlightCloudDeletionReady(captured)) {
      return commandResult(false, 'cloud_unavailable', current.impact);
    }
    let hostPrepared: boolean = false;
    if (current.command === 'unpair_host' && this.hostPort !== null) {
      try {
        hostPrepared = this.hostPort.isHostUnpairReady(
          captured, current.hostId);
      } catch (_error) {
        hostPrepared = false;
      }
    }
    const identitiesRequireDeletion: boolean =
      current.command === 'delete_local_data' &&
      (this.identityPort !== null ||
       current.identityRecordIds.length > 0 ||
       current.context.secureIdentityCount > 0);
    if (identitiesRequireDeletion &&
        (this.identityPort === null ||
         !this.identityPort.isIdentityDeletionReady(
           captured, current.identityRecordIds))) {
      return commandResult(false, 'identity_unavailable', current.impact);
    }
    let selectionChanged: boolean = false;
    if (current.command === 'delete_local_data' &&
        current.impact.selectionChanged) {
      // Stop future upload/download before removing local rows. This prevents
      // an active physical cloud projection from immediately rehydrating a
      // local-only wipe. The fixed logical set remains canonical and is not a
      // second on/off boundary.
      if (this.selectionPort === null) {
        return commandResult(false, 'selection_unavailable', current.impact);
      }
      const cancelled: boolean =
        this.selectionPort.cancelAllMoonlightSync(captured);
      if (!cancelled || !this.leaseIsCurrent(captured)) {
        return commandResult(false, this.leaseIsCurrent(captured) ?
          'selection_failed' : 'stale_lease', current.impact,
          false, false, false, cancelled);
      }
      selectionChanged = true;
    }
    let identityAttempted: boolean = false;
    let identitySucceeded: boolean = false;
    // Commit the owner-scoped RDB/cache mutation first. If that atomic write
    // fails, no secure identity is removed. A later identity failure is
    // retryable even when every metadata row has already gone because the
    // production identity port always performs a native owner inventory.
    const mutation: MoonlightDeletionMutationResult =
      this.port.commitMoonlightDeletion(captured, {
        command: current.command,
        recordIds: current.recordIds.slice(),
        cacheIds: current.cacheIds.slice(),
        persistCloudDeletionIntent,
        clearOwnerRuntimeState:
          current.command === 'delete_local_data',
        expectedRuntimeStateCount:
          current.context.localRuntimeStateCount,
        nowMs
      });
    if (!mutation.ok || !this.leaseIsCurrent(captured)) {
      const code: MoonlightDeletionCommandCode =
        !this.leaseIsCurrent(captured) || mutation.code === 'stale_lease'
          ? 'stale_lease' :
        mutation.code === 'cloud_unavailable'
          ? 'cloud_unavailable' :
        mutation.code === 'invalid_request'
          ? 'invalid_request' : 'local_write_failed';
      return commandResult(false, code, current.impact,
        mutation.localCommitted, mutation.cloudAttempted,
        mutation.cloudTerminal, selectionChanged, false, false,
        identityAttempted, identitySucceeded,
        mutation.localCommitted ? current.artworkPaths : []);
    }
    if (identitiesRequireDeletion && this.identityPort !== null) {
      identityAttempted = true;
      try {
        identitySucceeded = await this.identityPort.deleteLocalIdentities(
          captured, current.identityRecordIds.slice(), true);
      } catch (_error) {
        identitySucceeded = false;
      }
      if (!identitySucceeded || !this.leaseIsCurrent(captured)) {
        return commandResult(false,
          this.leaseIsCurrent(captured) ?
            'identity_delete_failed' : 'stale_lease',
          current.impact, mutation.localCommitted,
          mutation.cloudAttempted, mutation.cloudTerminal,
          selectionChanged, false, false, true, identitySucceeded,
          mutation.localCommitted ? current.artworkPaths : []);
      }
    }
    let hostAttempted: boolean = current.command === 'unpair_host';
    let hostSucceeded: boolean = false;
    if (current.command === 'unpair_host' && this.hostPort !== null &&
        hostPrepared) {
      try {
        hostSucceeded = await this.hostPort.requestHostUnpair(
          captured, current.hostId);
      } catch (_error) {
        hostSucceeded = false;
      }
    }
    if (mutation.code === 'local_verification_pending') {
      // The atomic local transaction is already durable. A transient
      // post-commit readback failure must not turn a successful user delete
      // into a retry loop or duplicate mutation; the store has scheduled a
      // fenced background notification and cloud-first reconciliation.
      return commandResult(true, 'pending_local_verification', current.impact,
        true, mutation.cloudAttempted, false, false,
        hostAttempted, hostSucceeded,
        identityAttempted, identitySucceeded,
        current.artworkPaths);
    }
    if (cloudSynchronizationPending && !mutation.cloudTerminal) {
      return commandResult(true, 'pending_cloud', current.impact,
        mutation.localCommitted, mutation.cloudAttempted, false,
        false, hostAttempted, hostSucceeded,
        identityAttempted, identitySucceeded,
        current.artworkPaths);
    }
    if (hostAttempted && !hostSucceeded) {
      return commandResult(true, 'ok_with_remote_warning', current.impact,
        mutation.localCommitted, mutation.cloudAttempted,
        mutation.cloudTerminal, false, true, false,
        identityAttempted, identitySucceeded,
        current.artworkPaths);
    }
    return commandResult(true, 'ok', current.impact,
      mutation.localCommitted, mutation.cloudAttempted,
      mutation.cloudTerminal,
      selectionChanged ||
        (current.command === 'delete_cloud_data' &&
          mutation.cloudTerminal),
      hostAttempted, hostSucceeded,
      identityAttempted, identitySucceeded,
      current.artworkPaths);
  }

  private leaseIsCurrent(lease: AccountSessionLease): boolean {
    return accountSessionLeaseEquals(
      this.port.currentAccountLease(), lease) &&
      this.port.isLeaseCurrent(lease);
  }
}
