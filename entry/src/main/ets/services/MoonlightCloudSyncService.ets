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
  MoonlightRepositoryResult
} from './MoonlightRepository';
import { moonlightValidateRecord } from './MoonlightRecordPolicy';

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

/**
 * The future CloudStore adapter must perform this as one transaction: upsert
 * only the supplied selected records into moonlightrecordv1, mark the same
 * local overlays localonly=0, journal them, verify readback, then commit. It
 * must preserve every unselected physical row and never issue cloud I/O.
 */
export interface MoonlightCloudSyncServicePort extends MoonlightRepositoryPort {
  promoteMoonlightLocalRecords(
    lease: AccountSessionLease, records: MoonlightRecord[]
  ): boolean;
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
    // D2-10 prepares/materializes the local physical projection only. D2-07
    // registration and D3 coordinator own future native cloud transfer.
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
    let accepted: number = 0;
    let skipped: number = 0;
    let quarantined: number = 0;
    let failed: number = 0;
    for (let i = 0; i < rows.length; i++) {
      if (!this.leaseIsCurrent(captured)) {
        return result(false, 'stale_lease', accepted, skipped,
          quarantined, failed);
      }
      const exact: Record<string, string> | null =
        normalizeMoonlightCloudRowExact(rows[i]);
      if (exact === null) {
        if (this.port.recordMoonlightQuarantine(
          captured, safeQuarantineId(rows[i], i),
          'cloud_row_shape_invalid', safePayloadHash(rows[i]))) {
          quarantined++;
        } else { failed++; }
        continue;
      }
      const record: MoonlightRecord = moonlightRecordFromCloudRow(exact);
      const validation = moonlightValidateRecord(record);
      if (!validation.valid || record.userId !== captured.ownerScopeId) {
        const reason: string = record.userId !== captured.ownerScopeId ?
          'cloud_row_owner_mismatch' : validation.reason;
        if (this.port.recordMoonlightQuarantine(
          captured, safeQuarantineId(exact, i), reason,
          safePayloadHash(exact))) {
          quarantined++;
        } else { failed++; }
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
          if (this.port.recordMoonlightQuarantine(
            captured, record.id, 'cloud_identity_ciphertext_invalid',
            record.payloadHashSha256)) {
            quarantined++;
          } else { failed++; }
          continue;
        }
      }
      const write: MoonlightRepositoryResult =
        this.repository.upsert(captured, record, 0);
      if (write.ok) { accepted++; }
      else { failed++; }
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
      const record: MoonlightRecord = local[i];
      if (!isMoonlightRecordTypeSelected(
        record.recordType, selected, gates.identityCapabilityReady)) {
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
    if (!this.port.promoteMoonlightLocalRecords(
      captured, candidates)) {
      return result(false, 'projection_failed', 0, skipped,
        0, candidates.length);
    }
    if (!this.leaseIsCurrent(captured)) {
      return result(false, 'stale_lease', 0, skipped,
        0, 0, candidates.length);
    }
    return result(true, 'ok', 0, skipped, 0, 0, candidates.length);
  }

  private leaseIsCurrent(lease: AccountSessionLease): boolean {
    return accountSessionLeaseEquals(
      this.port.currentAccountLease(), lease) &&
      this.port.isLeaseCurrent(lease);
  }
}
