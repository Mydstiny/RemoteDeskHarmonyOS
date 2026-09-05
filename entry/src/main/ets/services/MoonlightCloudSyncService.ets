import {
  MoonlightRecord,
  moonlightRecordFromCloudRow,
  moonlightRecordToCloudRow
} from '../model/MoonlightRecord';
import {
  AccountSessionLease,
  accountSessionLeaseEquals,
  cloneAccountSessionLease
} from './AccountScopePolicy';
import {
  CloudCiphertextProbe,
  moonlightCloudRowsAreDownloadCompatible,
  moonlightCloudRowsAreUploadSafe
} from './CloudSensitiveTransferPolicy';
import { normalizeMoonlightCloudRowExact } from './CloudTableAdapter';
import {
  MoonlightCloudSyncScope,
  isMoonlightRecordTypeSelected,
  moonlightIdentitySyncAllowed,
  normalizeMoonlightCloudSyncSelection
} from './MoonlightCloudSyncSelectionPolicy';
import {
  MoonlightRepository,
  MoonlightRepositoryPort,
  MoonlightRepositoryReadResult
} from './MoonlightRepository';
import {
  moonlightRecordContainsDevicePrivateEndpoint,
  moonlightValidateRecord
} from './MoonlightRecordPolicy';
import {
  MoonlightConflictDecision,
  MoonlightConflictMergeContext,
  resolveMoonlightRecordConflict
} from './MoonlightRecordConflictPolicy';

export interface MoonlightCloudSyncGateSnapshot {
  cloudSchemaReady: boolean;
  physicalTableSelected: boolean;
  selectedScopes: string[];
  identityCapabilityReady: boolean;
  cryptoConfigured: boolean;
}

export type MoonlightCloudMaterializationCode =
  'ok' | 'partial' | 'disabled' | 'stale_lease' |
  'not_ready' | 'sensitive_blocked' | 'projection_failed';

export interface MoonlightCloudMaterializationResult {
  ok: boolean;
  code: MoonlightCloudMaterializationCode;
  accepted: number;
  skipped: number;
  quarantined: number;
  failed: number;
  promoted: number;
  cloudAttempted: boolean;
}

export interface MoonlightCloudLocalMutation {
  record: MoonlightRecord;
  localOnly: number;
  operation: 'upsert' | 'tombstone';
}

export interface MoonlightCloudQuarantineMutation {
  recordId: string;
  reason: string;
  payloadHashSha256: string;
}

/**
 * The CloudStore adapter performs this as one transaction: upsert
 * only the supplied selected records into moonlightrecordv1, mark the same
 * local overlays localonly=0, journal them, verify readback, then commit. It
 * must preserve every unselected physical row and never issue cloud I/O.
 */
export interface MoonlightCloudSyncServicePort extends MoonlightRepositoryPort {
  /** Apply one cloud-first merge as a single local RDB transaction. */
  commitMoonlightCloudMaterialization(
    lease: AccountSessionLease,
    mutations: MoonlightCloudLocalMutation[],
    quarantines: MoonlightCloudQuarantineMutation[]
  ): boolean;
  /**
   * Manual cloud download only: replace the selected local overlay scopes
   * with one fully validated cloud snapshot. The live adapter performs this
   * atomically and leaves every unselected/device-local scope untouched.
   */
  replaceMoonlightLocalRecordsFromCloud(
    lease: AccountSessionLease,
    records: MoonlightRecord[],
    selectedScopes: MoonlightCloudSyncScope[]
  ): boolean;
  promoteMoonlightLocalRecords(
    lease: AccountSessionLease, records: MoonlightRecord[]
  ): number;
}

function result(ok: boolean, code: MoonlightCloudMaterializationCode,
  accepted: number = 0, skipped: number = 0,
  quarantined: number = 0, failed: number = 0,
  promoted: number = 0): MoonlightCloudMaterializationResult {
  return {
    ok: ok,
    code: code,
    accepted: accepted,
    skipped: skipped,
    quarantined: quarantined,
    failed: failed,
    promoted: promoted,
    // This service prepares/materializes the local physical projection only.
    // Optional registration and the coordinator own the actual cloud transfer.
    cloudAttempted: false
  };
}

function gatesOpen(gates: MoonlightCloudSyncGateSnapshot): boolean {
  return gates.cloudSchemaReady && gates.physicalTableSelected;
}

function safeQuarantineId(
  row: Record<string, string>, index: number
): string {
  const candidate: string = row['id'] || '';
  return candidate.trim() !== '' && candidate.length <= 128 ?
    candidate : 'invalid-cloud-row-' + index.toString();
}

function safePayloadHash(row: Record<string, string>): string {
  const candidate: string = row['payloadhashsha256'] || '';
  return /^[0-9a-f]{64}$/.test(candidate) ? candidate : '';
}

export class MoonlightCloudSyncService {
  private readonly port: MoonlightCloudSyncServicePort;
  private readonly repository: MoonlightRepository;
  private readonly ciphertextProbe: CloudCiphertextProbe;

  constructor(port: MoonlightCloudSyncServicePort,
    ciphertextProbe: CloudCiphertextProbe) {
    this.port = port;
    this.repository = new MoonlightRepository(port);
    this.ciphertextProbe = ciphertextProbe;
  }

  /**
   * Materialize a cloud-first snapshot into the owner local overlay. Logical
   * scopes filter runtime records but never delete hidden rows from the single
   * physical table. Invalid rows are quarantined as id/hash/reason only.
   */
  materializeDownloadedRows(lease: AccountSessionLease,
    rows: Array<Record<string, string>>,
    gates: MoonlightCloudSyncGateSnapshot,
    authoritativeReplace: boolean = false
  ): MoonlightCloudMaterializationResult {
    const captured: AccountSessionLease = cloneAccountSessionLease(lease);
    if (!this.leaseIsCurrent(captured)) {
      return result(false, 'stale_lease');
    }
    if (!gatesOpen(gates)) { return result(false, 'disabled'); }
    const selected: MoonlightCloudSyncScope[] =
      normalizeMoonlightCloudSyncSelection(
        gates.selectedScopes, gates.identityCapabilityReady);
    let accepted: number = 0;
    let skipped: number = 0;
    let quarantined: number = 0;
    let failed: number = 0;
    const authoritativeRecords: MoonlightRecord[] = [];
    const mutations: MoonlightCloudLocalMutation[] = [];
    const quarantines: MoonlightCloudQuarantineMutation[] = [];
    for (let i = 0; i < rows.length; i++) {
      if (!this.leaseIsCurrent(captured)) {
        return result(false, 'stale_lease', accepted, skipped,
          quarantined, failed);
      }
      const exact: Record<string, string> | null =
        normalizeMoonlightCloudRowExact(rows[i]);
      if (exact === null) {
        quarantines.push({
          recordId: safeQuarantineId(rows[i], i),
          reason: 'cloud_row_shape_invalid',
          payloadHashSha256: safePayloadHash(rows[i])
        });
        quarantined++;
        continue;
      }
      const record: MoonlightRecord = moonlightRecordFromCloudRow(exact);
      const validation = moonlightValidateRecord(record);
      if (!validation.valid || record.userId !== captured.ownerScopeId) {
        const reason: string = record.userId !== captured.ownerScopeId ?
          'cloud_row_owner_mismatch' : validation.reason;
        quarantines.push({
          recordId: safeQuarantineId(exact, i),
          reason: reason,
          payloadHashSha256: safePayloadHash(exact)
        });
        quarantined++;
        continue;
      }
      if (moonlightRecordContainsDevicePrivateEndpoint(record)) {
        quarantines.push({
          recordId: record.id,
          reason: 'cloud_device_private_endpoint',
          payloadHashSha256: record.payloadHashSha256
        });
        quarantined++;
        continue;
      }
      if (!isMoonlightRecordTypeSelected(
        record.recordType, selected, gates.identityCapabilityReady)) {
        skipped++;
        continue;
      }
      if (record.recordType === 'secret' && record.deletedAt === 0) {
        if (!moonlightIdentitySyncAllowed(selected,
          gates.identityCapabilityReady, gates.cryptoConfigured)) {
          skipped++;
          continue;
        }
        if (!moonlightCloudRowsAreDownloadCompatible(
          [exact], this.ciphertextProbe)) {
          quarantines.push({
            recordId: record.id,
            reason: 'cloud_identity_ciphertext_invalid',
            payloadHashSha256: record.payloadHashSha256
          });
          quarantined++;
          continue;
        }
      }
      if (authoritativeReplace) {
        authoritativeRecords.push(
          MoonlightRecord.fromJSON(record.toJSON()));
        accepted++;
        continue;
      }
      const current = this.port.readMoonlightLocalRecord(
        captured, record.id);
      if (!current.ok) {
        failed++;
        continue;
      }
      const mergeContext: MoonlightConflictMergeContext | null =
        current.record !== null &&
        (record.recordType === 'settings' || record.recordType === 'profile') ? {
          mutationId: deterministicMergeMutationId(
            current.record.payloadHashSha256, record.payloadHashSha256),
          originId: 'moonlight-cloud-merge-v1',
          updatedAt: Math.max(current.record.updatedAt, record.updatedAt)
        } : null;
      let winner: MoonlightRecord =
        MoonlightRecord.fromJSON(record.toJSON());
      let localOnly: number = 0;
      if (current.record !== null) {
        const decision: MoonlightConflictDecision =
          resolveMoonlightRecordConflict(
            current.record, record, mergeContext);
        if (decision.action === 'quarantine_candidate' ||
            decision.action === 'quarantine_both' ||
            decision.record === null) {
          quarantines.push({
            recordId: record.id,
            reason: decision.reason,
            payloadHashSha256: record.payloadHashSha256
          });
          quarantined++;
          continue;
        }
        winner = MoonlightRecord.fromJSON(decision.record.toJSON());
        // Exact cloud mirrors become localonly=0. Any deterministic local or
        // merged winner is a real pending repair and remains localonly=1.
        localOnly = sameMoonlightRecord(winner, record) ? 0 : 1;
      }
      mutations.push({
        record: winner,
        localOnly: localOnly,
        operation: winner.deletedAt > 0 ? 'tombstone' : 'upsert'
      });
      accepted++;
    }
    if (!this.leaseIsCurrent(captured)) {
      return result(false, 'stale_lease', accepted, skipped,
        quarantined, failed);
    }
    if (authoritativeReplace) {
      // An explicit cloud-authoritative replacement must be all-or-nothing.
      // Deleting local rows from a snapshot containing a malformed or
      // unpersistable selected row would turn validation into data loss. A
      // malformed optional row must not, however, prevent the user from
      // pulling the rest of the cloud database. Degrade that Moonlight leg to
      // the ordinary non-destructive merge: valid rows and redacted
      // quarantine entries commit atomically, while local rows absent from an
      // incomplete snapshot are preserved.
      if (quarantined > 0 || failed > 0) {
        if (failed > 0) {
          return result(false, 'partial', accepted, skipped,
            quarantined, failed);
        }
        const salvaged: MoonlightCloudMaterializationResult =
          this.materializeDownloadedRows(
            captured, rows, gates, false);
        const safePartial: boolean = salvaged.ok ||
          (salvaged.code === 'partial' && salvaged.failed === 0);
        return result(
          safePartial, salvaged.code, salvaged.accepted,
          salvaged.skipped, salvaged.quarantined,
          salvaged.failed, salvaged.promoted);
      }
      if (!this.port.replaceMoonlightLocalRecordsFromCloud(
        captured, authoritativeRecords, selected)) {
        return result(false, 'projection_failed', accepted, skipped,
          quarantined, 1);
      }
      if (!this.leaseIsCurrent(captured)) {
        return result(false, 'stale_lease', accepted, skipped,
          quarantined, failed);
      }
      return result(true, 'ok', accepted, skipped);
    }
    // A read/lease failure invalidates the whole merge. Do not commit the
    // safe prefix and leave an automatic foreground/cloudEvent pull half
    // materialized without a before-image.
    if (failed > 0) {
      return result(false, 'partial', accepted, skipped,
        quarantined, failed);
    }
    if ((mutations.length > 0 || quarantines.length > 0) &&
        !this.port.commitMoonlightCloudMaterialization(
          captured, mutations, quarantines)) {
      return result(false, 'projection_failed', accepted, skipped,
        quarantined, 1);
    }
    if (!this.leaseIsCurrent(captured)) {
      return result(false, 'stale_lease', accepted, skipped,
        quarantined, failed);
    }
    const partial: boolean = quarantined > 0 || failed > 0;
    return result(!partial, partial ? 'partial' : 'ok',
      accepted, skipped, quarantined, failed);
  }

  /**
   * Promote only locally eligible selected rows. Turning a scope off never
   * emits deletions; it simply omits that logical type from this upsert set.
   */
  promoteSelectedLocalRecords(lease: AccountSessionLease,
    gates: MoonlightCloudSyncGateSnapshot
  ): MoonlightCloudMaterializationResult {
    const captured: AccountSessionLease = cloneAccountSessionLease(lease);
    if (!this.leaseIsCurrent(captured)) {
      return result(false, 'stale_lease');
    }
    if (!gatesOpen(gates)) { return result(false, 'disabled'); }
    const selected: MoonlightCloudSyncScope[] =
      normalizeMoonlightCloudSyncSelection(
        gates.selectedScopes, gates.identityCapabilityReady);
    const local: MoonlightRecord[] | null =
      this.repository.loadAll(captured, true);
    if (local === null) { return result(false, 'not_ready'); }
    const candidates: MoonlightRecord[] = [];
    const rows: Array<Record<string, string>> = [];
    let skipped: number = 0;
    for (let i = 0; i < local.length; i++) {
      // Only a local-first row may enter the cloud projection. A row already
      // marked localonly=0 is merely the last materialized cloud mirror; if it
      // disappeared from the current cloud snapshot, promoting it here would
      // resurrect a remote deletion.
      const localState: MoonlightRepositoryReadResult =
        this.port.readMoonlightLocalRecord(captured, local[i].id);
      if (!localState.ok || localState.record === null) {
        return result(false, 'not_ready', 0, skipped);
      }
      if (localState.localOnly === 0) {
        skipped++;
        continue;
      }
      if (localState.localOnly !== 1) {
        return result(false, 'not_ready', 0, skipped);
      }
      const record: MoonlightRecord = localState.record;
      if (!isMoonlightRecordTypeSelected(
        record.recordType, selected, gates.identityCapabilityReady)) {
        skipped++;
        continue;
      }
      if (moonlightRecordContainsDevicePrivateEndpoint(record)) {
        skipped++;
        continue;
      }
      if (record.recordType === 'secret' && record.deletedAt === 0 &&
          !moonlightIdentitySyncAllowed(selected,
            gates.identityCapabilityReady, gates.cryptoConfigured)) {
        skipped++;
        continue;
      }
      candidates.push(MoonlightRecord.fromJSON(record.toJSON()));
      rows.push(moonlightRecordToCloudRow(record));
    }
    if (!moonlightCloudRowsAreUploadSafe(
      rows, gates.cryptoConfigured, this.ciphertextProbe)) {
      return result(false, 'sensitive_blocked', 0, skipped);
    }
    if (candidates.length === 0) {
      return result(true, 'ok', 0, skipped);
    }
    if (!this.leaseIsCurrent(captured)) {
      return result(false, 'stale_lease', 0, skipped);
    }
    const promoted: number = this.port.promoteMoonlightLocalRecords(
      captured, candidates);
    if (promoted < 0) {
      return result(false, 'projection_failed', 0, skipped,
        0, candidates.length);
    }
    if (!this.leaseIsCurrent(captured)) {
      return result(false, 'stale_lease', 0, skipped,
        0, 0, promoted);
    }
    return result(true, 'ok', 0, skipped, 0, 0, promoted);
  }

  private leaseIsCurrent(lease: AccountSessionLease): boolean {
    return accountSessionLeaseEquals(
      this.port.currentAccountLease(), lease) &&
      this.port.isLeaseCurrent(lease);
  }
}

function deterministicMergeMutationId(
  leftHash: string, rightHash: string
): string {
  const ordered: string[] = [leftHash, rightHash].sort();
  return 'moonlight-cloud-merge-v1:' +
    ordered[0].substring(0, 32) + ':' +
    ordered[1].substring(0, 32);
}

function sameMoonlightRecord(
  left: MoonlightRecord, right: MoonlightRecord
): boolean {
  const leftRow: Record<string, string> = moonlightRecordToCloudRow(left);
  const rightRow: Record<string, string> = moonlightRecordToCloudRow(right);
  const keys: string[] = Object.keys(leftRow);
  if (keys.length !== Object.keys(rightRow).length) { return false; }
  for (let i = 0; i < keys.length; i++) {
    if (leftRow[keys[i]] !== rightRow[keys[i]]) { return false; }
  }
  return true;
}
