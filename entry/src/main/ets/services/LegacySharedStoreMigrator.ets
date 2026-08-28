import { common } from '@kit.AbilityKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { preferences, relationalStore } from '@kit.ArkData';
import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { AccountScopeToken, accountStoreIdentity } from './AccountScopePolicy';
import {
  accountScopedLocalOverlayRowDecision,
  AccountScopedLocalOverlayRowDecision,
  accountScopedMigrationReceiptDecision,
  accountScopedMigrationReceiptNeedsUpgrade,
  accountScopedCryptoParamsMayMigrate,
  accountScopedRowOwnershipDecision,
  legacyCryptoParamsMayMigrate,
  legacyRowOwnershipDecision,
  legacyVncRowMigrationDecision,
  LegacyRowOwnershipDecision,
  LegacyVncRowMigrationDecision
} from './LegacySharedStoreMigrationPolicy';
import {
  VNC_LOCAL_TABLE,
  VNC_RECORD_COLUMNS,
  vncRecordFromCloudRow,
  vncRecordIsValid
} from './VncRecordPolicy';
import {
  MOONLIGHT_CLOUD_TABLE,
  MOONLIGHT_LOCAL_RECORD_COLUMNS,
  MOONLIGHT_LOCAL_TABLE,
  MOONLIGHT_RECORD_COLUMNS,
  moonlightRecordFromCloudRow
} from '../model/MoonlightRecord';
import { moonlightValidateRecord } from './MoonlightRecordPolicy';
import { moonlightRecordTypeIsPublicCloudData } from './MoonlightCloudDeletionPolicy';
import { cloudSyncTableNames } from './CloudSyncPolicy';

export const ACCOUNT_SCOPED_SOURCE_CHANGED_ERROR: string =
  'account_scoped_source_changed_after_committed_migration';
export const COMPATIBILITY_MUTATION_PREFERENCES_NAME: string =
  'RemoteDesktopCloudCompatibilityPrefs';
export const COMPATIBILITY_MUTATION_PREFERENCE_PREFIX: string =
  'pending_local_mutations_v1';
export const COMPATIBILITY_MUTATION_METADATA_PREFIX: string =
  'pending_local_mutation_revision_v1:';

export function compatibilityMutationPreferenceKey(
  ownerScopeId: string, storeIdentity: string
): string {
  const owner: string = ownerScopeId.trim();
  const store: string = storeIdentity.trim();
  return owner === '' || store === '' ? '' :
    COMPATIBILITY_MUTATION_PREFERENCE_PREFIX + ':' + owner + ':' + store;
}

const LEGACY_STORE_NAME: string = 'remotedesktop.db';
const ACCOUNT_SCOPED_MIGRATION_ID: string = 'account-scoped-store-v1';
const RECEIPT_TABLE: string = 'migrationreceipts';
const QUARANTINE_TABLE: string = 'migrationquarantine';
const JOURNAL_TABLE: string = 'localmutationjournal';
const LOCAL_METADATA_TABLE: string = 'localmetadata';
const ACCOUNT_SCOPED_RECOVERY_BASELINE_KEY: string =
  'account_scoped_cloud_recovery_journal_baseline_v1';
const MIGRATION_ID: string = 'legacy-shared-store-v1';
const OWNER_CLAIM_MIGRATION_ID: string = 'legacy-owner-claim-v2';
/** Store-scoped metadata that must survive an account-scope migration. */
const CARRYOVER_METADATA_EXCLUDE_KEYS: string[] = [
  'store_owner_scope_id',
  'store_identity',
  'store_schema_revision',
  'store_platform_cloud_identity_fingerprint',
  ACCOUNT_SCOPED_RECOVERY_BASELINE_KEY
];
const OWNER_TABLES: string[] = [
  'remotehosts',
  'rdpcredentials',
  'rustdeskrelays',
  'sshkeys',
  'totpentries',
  'usersettings',
  'vncrecords',
  'vncrecord',
  'vncrecordv2',
  MOONLIGHT_CLOUD_TABLE,
  VNC_LOCAL_TABLE,
  MOONLIGHT_LOCAL_TABLE
];
const EXPLICIT_OWNER_TABLES: string[] = [
  'remotehosts',
  'rustdeskrelays',
  'sshkeys',
  'totpentries',
  'usersettings',
  'vncrecords',
  'vncrecord',
  'vncrecordv2'
];
const VNC_LOCAL_RECORD_COLUMNS: string[] = [
  ...VNC_RECORD_COLUMNS,
  'localonly'
];
const ACCOUNT_SCOPED_LOCAL_TABLES: string[] = [
  VNC_LOCAL_TABLE,
  MOONLIGHT_LOCAL_TABLE
];
const ACCOUNT_SCOPED_DISTRIBUTED_TABLES: string[] =
  cloudSyncTableNames();
/** Tables that carried userid in the pre-ownerScopeId cloud store. */
const LEGACY_OWNER_CLAIM_TABLES: string[] = [
  'remotehosts',
  'rdpcredentials',
  'rustdeskrelays',
  'sshkeys',
  'totpentries',
  'usersettings',
  'vncrecords',
  'vncrecord',
  'vncrecordv2'
];

export interface LegacySharedStoreMigrationResult {
  found: boolean;
  migrated: boolean;
  copiedRows: number;
  quarantinedRows: number;
  skippedRows: number;
}

export type LegacySharedStoreSourceKind = 'legacy' | 'account_scope';

export interface LegacySharedStoreMigrationOptions {
  sourceName?: string;
  migrationId?: string;
  sourceKind?: LegacySharedStoreSourceKind;
  targetStoreName?: string;
}

interface CommittedMigrationReceipt {
  sourceFingerprint: string;
}

export class LegacySharedStoreMigrator {
  private static instance: LegacySharedStoreMigrator;

  static getInstance(): LegacySharedStoreMigrator {
    if (!LegacySharedStoreMigrator.instance) {
      LegacySharedStoreMigrator.instance = new LegacySharedStoreMigrator();
    }
    return LegacySharedStoreMigrator.instance;
  }

  captureAccountScopedRecoveryBaseline(
    source: relationalStore.RdbStore
  ): boolean {
    try {
      const existing: string | null =
        this.localMetadataValue(
          source,
          ACCOUNT_SCOPED_RECOVERY_BASELINE_KEY);
      if (existing !== null) {
        return existing.indexOf('journal-v1:') === 0;
      }
      const fingerprint: string =
        this.sourceMutationFingerprint(source);
      this.insertRow(source, LOCAL_METADATA_TABLE, {
        key: ACCOUNT_SCOPED_RECOVERY_BASELINE_KEY,
        value: fingerprint,
        updatedat: Date.now()
      });
      return this.localMetadataValue(
        source,
        ACCOUNT_SCOPED_RECOVERY_BASELINE_KEY) === fingerprint;
    } catch (_error) {
      return false;
    }
  }

  async migrateIfNeeded(context: common.Context, target: relationalStore.RdbStore,
    scope: AccountScopeToken, verifiedUnionId: string = '',
    options: LegacySharedStoreMigrationOptions = {}):
    Promise<LegacySharedStoreMigrationResult> {
    const empty: LegacySharedStoreMigrationResult = {
      found: false, migrated: false, copiedRows: 0,
      quarantinedRows: 0, skippedRows: 0
    };
    const sourceName: string =
      options.sourceName !== undefined && options.sourceName.length > 0
        ? options.sourceName : LEGACY_STORE_NAME;
    const migrationId: string =
      options.migrationId !== undefined && options.migrationId.length > 0
        ? options.migrationId : MIGRATION_ID;
    const sourceKind: LegacySharedStoreSourceKind =
      options.sourceKind === 'account_scope' ? 'account_scope' : 'legacy';
    const targetStoreName: string =
      options.targetStoreName !== undefined ? options.targetStoreName : '';
    // The canonical cloud store is the migration target for verified account
    // scopes; a legacy source with the same file must never self-migrate.
    if (targetStoreName.length > 0 && sourceName === targetStoreName) {
      return empty;
    }
    // RDB stores live under <databaseDir>/rdb/ on HarmonyOS. context.databaseDir
    // itself is <...>/database/<bundle>/<module>, so the missing "/rdb/" segment
    // made every existence check fail and silently skipped the migration.
    const path: string = context.databaseDir + '/rdb/' + sourceName;
    if (!fileIo.accessSync(path)) { return empty; }
    const receiptId: string = migrationId + ':' + scope.ownerScopeId;
    const committedReceipt: CommittedMigrationReceipt | null =
      this.committedReceipt(target, receiptId);
    if (committedReceipt !== null &&
        sourceKind !== 'account_scope') {
      return {
        found: true, migrated: true, copiedRows: 0,
        quarantinedRows: 0, skippedRows: 0
      };
    }
    const source: relationalStore.RdbStore = await relationalStore.getRdbStore(
      context, {
        name: sourceName,
        securityLevel: relationalStore.SecurityLevel.S1,
        isReadOnly: true
      });
    let result: LegacySharedStoreMigrationResult = empty;
    try {
      if (sourceKind === 'account_scope' &&
          source.version > target.version) {
        throw new Error(
          'account_scoped_source_schema_newer_than_target');
      }
      const compatibilityRevisions: Record<string, number> =
        sourceKind === 'account_scope'
          ? this.compatibilityMutationRevisions(
              context, source, scope.ownerScopeId, sourceName)
          : {};
      if (sourceKind === 'account_scope' &&
          committedReceipt !== null) {
        const currentFingerprint: string =
          this.sourceMutationFingerprint(
            source, compatibilityRevisions);
        const recoveryBaseline: string | null =
          this.localMetadataValue(
            source,
            ACCOUNT_SCOPED_RECOVERY_BASELINE_KEY);
        const decision =
          accountScopedMigrationReceiptDecision(
            committedReceipt.sourceFingerprint,
            currentFingerprint,
            recoveryBaseline);
        if (decision === 'source_changed') {
          throw new Error(
            ACCOUNT_SCOPED_SOURCE_CHANGED_ERROR);
        }
        if (accountScopedMigrationReceiptNeedsUpgrade(
          committedReceipt.sourceFingerprint,
          decision,
          recoveryBaseline)) {
          this.upgradeCommittedReceiptFingerprint(
            target, receiptId, currentFingerprint);
        }
        return {
          found: true, migrated: true, copiedRows: 0,
          quarantinedRows: 0, skippedRows: 0
        };
      }
      result = this.copySource(
        source, target, scope, verifiedUnionId, receiptId, path,
        migrationId, sourceName, sourceKind,
        compatibilityRevisions);
    } finally {
      // The target receipt and copied rows are already one committed
      // transaction. A source-handle close error must not turn that durable
      // success into an apparent migration failure on this launch.
      try { await source.close(); } catch (_closeError) {}
    }
    return result;
  }

  /**
   * Migrates the 1.0.9/1.0.10 account-scoped physical store
   * (`remotedesktop_owner-<sha>.db`) into the canonical cloud store
   * (`remotedesktop.db`) for the same verified account scope. Rows are
   * ownership-checked, tombstoned deletions are applied, crypto is migrated
   * only when the source has exactly one owner, and store-scoped metadata
   * (barriers/checkpoints/restore quarantine) is carried over.
   */
  async migrateAccountScopedStoreIfNeeded(
    context: common.Context,
    target: relationalStore.RdbStore,
    scope: AccountScopeToken,
    verifiedUnionId: string = ''
  ): Promise<LegacySharedStoreMigrationResult> {
    const sourceName: string = accountStoreIdentity(scope.ownerScopeId);
    const empty: LegacySharedStoreMigrationResult = {
      found: false, migrated: false, copiedRows: 0,
      quarantinedRows: 0, skippedRows: 0
    };
    if (sourceName.length === 0) { return empty; }
    return await this.migrateIfNeeded(context, target, scope,
      verifiedUnionId, {
        sourceName,
        migrationId: ACCOUNT_SCOPED_MIGRATION_ID,
        sourceKind: 'account_scope',
        targetStoreName: scope.storeIdentity
      });
  }

  /**
   * Claim rows written by 1.0.7/1.0.8 directly in the canonical physical
   * store. Those releases used a blank userid or the raw UnionID, while the
   * current app reads only owner-<sha256 UnionID>. The claim changes userid
   * only, preserves every primary key and payload column, and is committed
   * with a scoped receipt so a crashed upgrade can safely retry.
   */
  async claimLegacyRowsInPlace(
    target: relationalStore.RdbStore,
    scope: AccountScopeToken,
    verifiedUnionId: string = ''
  ): Promise<LegacySharedStoreMigrationResult> {
    const empty: LegacySharedStoreMigrationResult = {
      found: false, migrated: false, copiedRows: 0,
      quarantinedRows: 0, skippedRows: 0
    };
    if (scope.kind !== 'huawei_account' ||
      verifiedUnionId.trim().length === 0) {
      return empty;
    }
    const receiptId: string = OWNER_CLAIM_MIGRATION_ID + ':' +
      scope.ownerScopeId;
    if (this.receiptCommitted(target, receiptId)) {
      return {
        found: true, migrated: true, copiedRows: 0,
        quarantinedRows: 0, skippedRows: 0
      };
    }
    const selected: Map<string, Set<string>> =
      new Map<string, Set<string>>();
    const startedAt: number = Date.now();
    target.beginTransaction();
    try {
      this.writeReceipt(
        target, receiptId, scope,
        this.sha256Hex(
          'in-place:' + scope.storeIdentity + ':' +
            scope.schemaRevision.toString()),
        'running', '{}', '', startedAt, 0,
        OWNER_CLAIM_MIGRATION_ID,
        scope.storeIdentity);
      const counts: number[] =
        this.claimOwnerRowsWithinTransaction(
          target, scope, verifiedUnionId,
          LEGACY_OWNER_CLAIM_TABLES, selected);
      if (counts[0] > 0) {
        this.writeMigrationJournal(
          target, receiptId, selected,
          OWNER_CLAIM_MIGRATION_ID,
          'legacy_owner_claimed_not_uploaded');
      }
      const countsJson: string = JSON.stringify({
        claimedRows: counts[0],
        skippedRows: counts[1]
      });
      this.writeReceipt(
        target, receiptId, scope,
        this.sha256Hex(
          'in-place:' + scope.storeIdentity + ':' +
            scope.schemaRevision.toString()),
        'committed', countsJson, '', startedAt, Date.now(),
        OWNER_CLAIM_MIGRATION_ID,
        scope.storeIdentity);
      target.commit();
      return {
        found: true, migrated: true, copiedRows: counts[0],
        quarantinedRows: 0, skippedRows: counts[1]
      };
    } catch (err) {
      try { target.rollBack(); } catch (_rollbackError) {}
      throw new Error(
        'legacy owner claim failed: ' + this.errorDetail(err));
    }
  }

  /**
   * Cloud-first can bring a legacy row back after the startup receipt was
   * committed. Re-run the same owner decision for the affected table; the
   * operation is idempotent and writes a table-level journal only when a row
   * actually changes.
   */
  normalizeLegacyRowsInPlace(
    target: relationalStore.RdbStore,
    scope: AccountScopeToken,
    verifiedUnionId: string,
    table: string
  ): number {
    if (scope.kind !== 'huawei_account' ||
      verifiedUnionId.trim().length === 0 ||
      LEGACY_OWNER_CLAIM_TABLES.indexOf(table) < 0) {
      return 0;
    }
    const selected: Map<string, Set<string>> =
      new Map<string, Set<string>>();
    const receiptId: string = OWNER_CLAIM_MIGRATION_ID + ':postpull:' +
      scope.ownerScopeId + ':' + Date.now().toString();
    target.beginTransaction();
    try {
      const counts: number[] =
        this.claimOwnerRowsWithinTransaction(
          target, scope, verifiedUnionId,
          [table], selected);
      if (counts[0] > 0) {
        this.writeMigrationJournal(
          target, receiptId, selected,
          OWNER_CLAIM_MIGRATION_ID,
          'legacy_owner_normalized_not_uploaded');
      }
      target.commit();
      return counts[0];
    } catch (err) {
      try { target.rollBack(); } catch (_rollbackError) {}
      hilog.warn(0x0001, 'CloudSync',
        'legacy owner post-pull normalization failed table=' +
        table + ' err=' + this.errorDetail(err));
      return -1;
    }
  }

  private copySource(source: relationalStore.RdbStore,
    target: relationalStore.RdbStore, scope: AccountScopeToken,
    verifiedUnionId: string, receiptId: string, sourcePath: string,
    migrationId: string, sourceName: string,
    sourceKind: LegacySharedStoreSourceKind,
    compatibilityRevisions: Record<string, number> = {}):
    LegacySharedStoreMigrationResult {
    let copiedRows: number = 0;
    let quarantinedRows: number = 0;
    let skippedRows: number = 0;
    const selected: Map<string, Set<string>> = new Map<string, Set<string>>();
    const distinctOwners: string[] = this.distinctOwners(source);
    const cryptoOwnershipProven: boolean =
      sourceKind === 'account_scope'
        ? accountScopedCryptoParamsMayMigrate(
            distinctOwners, scope.ownerScopeId)
        : legacyCryptoParamsMayMigrate(
            distinctOwners, scope.kind, verifiedUnionId,
            scope.ownerScopeId);
    const legacyVncResetEpoch: number = cryptoOwnershipProven
      ? this.readLegacyVncResetEpoch(source) : 0;
    const sourceFingerprint: string = sourceKind === 'account_scope'
      ? this.sourceMutationFingerprint(
          source, compatibilityRevisions)
      : this.sourceFingerprint(
          sourcePath, source.version, distinctOwners);
    const startedAt: number = Date.now();
    target.beginTransaction();
    try {
      this.writeReceipt(target, receiptId, scope, sourceFingerprint,
        'running', '{}', '', startedAt, 0, migrationId, sourceName);
      if (sourceKind === 'account_scope') {
        this.prepareCompatibilitySnapshotReplacement(
          source, target, scope, verifiedUnionId,
          compatibilityRevisions, cryptoOwnershipProven);
      }
      for (let i = 0; i < EXPLICIT_OWNER_TABLES.length; i++) {
        const sourceTable: string = EXPLICIT_OWNER_TABLES[i];
        if (!this.tableExists(source, sourceTable)) { continue; }
        if (sourceKind === 'account_scope' &&
            sourceTable === 'vncrecordv2') {
          continue;
        }
        const targetTable: string =
          sourceTable === 'vncrecords' || sourceTable === 'vncrecord' ||
            (sourceTable === 'vncrecordv2' &&
              sourceKind !== 'account_scope')
            ? 'vnclocalrecords' : sourceTable;
        const counts: number[] = this.copyOwnedRows(
          source, target, sourceTable, targetTable, scope,
          verifiedUnionId, receiptId, selected,
          legacyVncResetEpoch, migrationId, sourceKind);
        copiedRows += counts[0];
        quarantinedRows += counts[1];
        skippedRows += counts[2];
      }
      if (sourceKind === 'account_scope') {
        if (this.tableExists(source, 'vncrecordv2')) {
          const vncCounts: number[] =
            this.copyAccountScopedVncCloudRows(
              source, target, scope, selected,
              legacyVncResetEpoch);
          copiedRows += vncCounts[0];
          skippedRows += vncCounts[1];
        }
        if (this.tableExists(source, MOONLIGHT_CLOUD_TABLE)) {
          const moonlightCounts: number[] =
            this.copyAccountScopedMoonlightCloudRows(
              source, target, scope, selected);
          copiedRows += moonlightCounts[0];
          skippedRows += moonlightCounts[1];
        }
        for (let i = 0; i < ACCOUNT_SCOPED_LOCAL_TABLES.length; i++) {
          const table: string = ACCOUNT_SCOPED_LOCAL_TABLES[i];
          if (!this.tableExists(source, table)) { continue; }
          const counts: number[] =
            this.copyAccountScopedLocalOverlayRows(
              source, target, table, scope, receiptId,
              migrationId, legacyVncResetEpoch);
          copiedRows += counts[0];
          quarantinedRows += counts[1];
          skippedRows += counts[2];
        }
      }
      if (sourceKind === 'account_scope' &&
          this.tableExists(source, 'rdpcredentials')) {
        const rdpCounts: number[] = this.copyOwnedRows(
          source, target, 'rdpcredentials', 'rdpcredentials', scope,
          verifiedUnionId, receiptId, selected,
          legacyVncResetEpoch, migrationId, sourceKind);
        copiedRows += rdpCounts[0];
        quarantinedRows += rdpCounts[1];
        skippedRows += rdpCounts[2];
      } else if (this.tableExists(source, 'rdpcredentials')) {
        const rdpCounts: number[] = this.copyReferencedRows(
          source, target, 'rdpcredentials',
          selected.get('rdpcredentials') ?? new Set<string>(),
          scope.ownerScopeId, receiptId, migrationId);
        copiedRows += rdpCounts[0];
        quarantinedRows += rdpCounts[1];
        skippedRows += rdpCounts[2];
      }
      if (this.tableExists(source, 'localextensions')) {
        copiedRows += this.copyLocalExtensions(source, target, selected);
      }
      if (this.tableExists(source, 'cryptoparams')) {
        if (cryptoOwnershipProven) {
          copiedRows += this.copyAllRows(
            source, target, 'cryptoparams', 'cryptoparams');
          this.recordSelection(selected, 'cryptoparams', '__table__');
        } else {
          quarantinedRows++;
          this.writeQuarantine(target, receiptId, 'cryptoparams',
            '__table__', 'ambiguous_crypto_owner', '', migrationId);
        }
      }
      if (sourceKind === 'account_scope') {
        copiedRows += this.copyLocalMetadataCarryover(source, target);
        // Legacy 1.0.7/1.0.8 rows still present in the canonical cloud store
        // carry userid == unionID. Normalize them to the target owner scope so
        // the app's userid-filtered reads keep showing them.
        copiedRows += this.normalizeLegacyOwnerRows(
          target, scope, verifiedUnionId, selected);
        // Compatibility markers are table-level because record-level intent
        // was unavailable. Distributed tables publish the exact replaced
        // source snapshot; local overlays were also replaced above but must
        // never enter the cloud mutation journal.
        const compatibilityTables: string[] =
          Object.keys(compatibilityRevisions);
        for (let i = 0; i < compatibilityTables.length; i++) {
          if (ACCOUNT_SCOPED_DISTRIBUTED_TABLES.indexOf(
            compatibilityTables[i]) >= 0) {
            this.recordSelection(
              selected, compatibilityTables[i], '__table__');
          }
        }
      }
      this.writeMigrationJournal(target, receiptId, selected, migrationId,
        sourceKind === 'account_scope'
          ? 'account_scope_migrated_not_uploaded'
          : 'legacy_migrated_not_uploaded');
      const countsJson: string = JSON.stringify({
        copiedRows, quarantinedRows, skippedRows
      });
      this.writeReceipt(target, receiptId, scope, sourceFingerprint,
        'committed', countsJson, '', startedAt, Date.now(),
        migrationId, sourceName);
      target.commit();
      return {
        found: true, migrated: true, copiedRows,
        quarantinedRows, skippedRows
      };
    } catch (err) {
      try { target.rollBack(); } catch (_rollbackError) {}
      throw new Error('legacy shared store migration failed: ' +
        this.errorDetail(err));
    }
  }

  private copyAccountScopedVncCloudRows(
    source: relationalStore.RdbStore,
    target: relationalStore.RdbStore,
    scope: AccountScopeToken,
    selected: Map<string, Set<string>>,
    legacyVncResetEpoch: number
  ): number[] {
    const table: string = 'vncrecordv2';
    if (!this.tableExists(target, table) ||
        !this.tableColumnsAreExact(
          source, table, VNC_RECORD_COLUMNS) ||
        !this.tableColumnsAreExact(
          target, table, VNC_RECORD_COLUMNS)) {
      throw new Error(
        'account-scoped VNC cloud schema mismatch');
    }
    const rows: relationalStore.ResultSet = source.querySync(
      new relationalStore.RdbPredicates(table));
    let copied: number = 0;
    let skipped: number = 0;
    try {
      while (rows.goToNextRow()) {
        const sourceRow: relationalStore.ValuesBucket = rows.getRow();
        const record = vncRecordFromCloudRow(
          this.stringRow(sourceRow, VNC_RECORD_COLUMNS));
        const ownership: LegacyRowOwnershipDecision =
          accountScopedRowOwnershipDecision(
            record.userId, scope.ownerScopeId);
        if (ownership === 'other_owner') {
          skipped++;
          continue;
        }
        const decision: LegacyVncRowMigrationDecision =
          legacyVncRowMigrationDecision(
            record.userId, scope.ownerScopeId,
            record.resetEpoch, legacyVncResetEpoch,
            vncRecordIsValid(record));
        if (ownership !== 'target' || decision !== 'migrate') {
          throw new Error(
            'account-scoped VNC cloud row is not safely migratable');
        }
        const bucket: relationalStore.ValuesBucket =
          this.projectBucket(sourceRow, VNC_RECORD_COLUMNS);
        bucket['userid'] = scope.ownerScopeId;
        this.insertRow(target, table, bucket);
        copied++;
        this.recordSelection(selected, table, record.id);
      }
    } finally {
      rows.close();
    }
    return [copied, skipped];
  }

  private copyAccountScopedMoonlightCloudRows(
    source: relationalStore.RdbStore,
    target: relationalStore.RdbStore,
    scope: AccountScopeToken,
    selected: Map<string, Set<string>>
  ): number[] {
    if (!this.tableExists(target, MOONLIGHT_CLOUD_TABLE) ||
        !this.tableColumnsAreExact(
          source, MOONLIGHT_CLOUD_TABLE,
          MOONLIGHT_RECORD_COLUMNS) ||
        !this.tableColumnsAreExact(
          target, MOONLIGHT_CLOUD_TABLE,
          MOONLIGHT_RECORD_COLUMNS)) {
      throw new Error(
        'account-scoped Moonlight cloud schema mismatch');
    }
    const rows: relationalStore.ResultSet = source.querySync(
      new relationalStore.RdbPredicates(MOONLIGHT_CLOUD_TABLE));
    let copied: number = 0;
    let skipped: number = 0;
    try {
      while (rows.goToNextRow()) {
        const sourceRow: relationalStore.ValuesBucket = rows.getRow();
        const record = moonlightRecordFromCloudRow(
          this.stringRow(sourceRow, MOONLIGHT_RECORD_COLUMNS));
        const ownership: LegacyRowOwnershipDecision =
          accountScopedRowOwnershipDecision(
            record.userId, scope.ownerScopeId);
        if (ownership === 'other_owner') {
          skipped++;
          continue;
        }
        if (ownership !== 'target' ||
            !moonlightValidateRecord(record).valid ||
            !moonlightRecordTypeIsPublicCloudData(record)) {
          throw new Error(
            'account-scoped Moonlight cloud row is not safely migratable');
        }
        const bucket: relationalStore.ValuesBucket =
          this.projectBucket(sourceRow, MOONLIGHT_RECORD_COLUMNS);
        bucket['userid'] = scope.ownerScopeId;
        this.insertRow(
          target, MOONLIGHT_CLOUD_TABLE, bucket);
        copied++;
        this.recordSelection(
          selected, MOONLIGHT_CLOUD_TABLE, record.id);
      }
    } finally {
      rows.close();
    }
    return [copied, skipped];
  }

  /**
   * A compatibility marker has table-level semantics. Replace the proven
   * target-owner snapshot before copying, otherwise a source-side delete or
   * clear could leave stale canonical rows that native-first would revive.
   */
  private prepareCompatibilitySnapshotReplacement(
    source: relationalStore.RdbStore,
    target: relationalStore.RdbStore,
    scope: AccountScopeToken,
    verifiedUnionId: string,
    revisions: Record<string, number>,
    cryptoOwnershipProven: boolean
  ): void {
    const tables: string[] = Object.keys(revisions);
    for (let i = 0; i < tables.length; i++) {
      const table: string = tables[i];
      const distributed: boolean =
        ACCOUNT_SCOPED_DISTRIBUTED_TABLES.indexOf(table) >= 0;
      const localOverlay: boolean =
        ACCOUNT_SCOPED_LOCAL_TABLES.indexOf(table) >= 0;
      if (!distributed && !localOverlay) {
        throw new Error(
          'unsupported compatibility snapshot table=' + table);
      }
      if (!this.tableExists(source, table) ||
          !this.tableExists(target, table)) {
        throw new Error(
          'compatibility snapshot schema unavailable table=' + table);
      }
      if (table === 'cryptoparams') {
        if (!cryptoOwnershipProven) {
          throw new Error(
            'compatibility crypto snapshot owner is ambiguous');
        }
        target.deleteSync(
          new relationalStore.RdbPredicates('cryptoparams'));
        continue;
      }
      this.clearProvenOwnerSnapshot(
        target, table, scope, verifiedUnionId);
    }
  }

  private clearProvenOwnerSnapshot(
    target: relationalStore.RdbStore,
    table: string,
    scope: AccountScopeToken,
    verifiedUnionId: string
  ): void {
    const columns: string[] = this.tableColumns(target, table);
    if (columns.indexOf('id') < 0 || columns.indexOf('userid') < 0) {
      throw new Error(
        'compatibility snapshot ownership columns unavailable table=' +
        table);
    }
    const rows: relationalStore.ResultSet = target.querySync(
      new relationalStore.RdbPredicates(table));
    const targets: string[][] = [];
    try {
      while (rows.goToNextRow()) {
        const row: relationalStore.ValuesBucket = rows.getRow();
        const id: string = this.stringValue(row['id']);
        const owner: string = this.stringValue(row['userid']);
        const decision: LegacyRowOwnershipDecision =
          legacyRowOwnershipDecision(
            owner, scope.kind, verifiedUnionId,
            scope.ownerScopeId);
        if (decision === 'quarantine_missing_owner' || id === '') {
          throw new Error(
            'compatibility target owner is ambiguous table=' + table);
        }
        if (decision === 'target') {
          targets.push([id, owner]);
        }
      }
    } finally {
      rows.close();
    }
    for (let i = 0; i < targets.length; i++) {
      const predicates = new relationalStore.RdbPredicates(table);
      predicates.equalTo('id', targets[i][0]);
      predicates.equalTo('userid', targets[i][1]);
      target.deleteSync(predicates);
    }
  }

  private copyOwnedRows(source: relationalStore.RdbStore,
    target: relationalStore.RdbStore, sourceTable: string, targetTable: string,
    scope: AccountScopeToken, verifiedUnionId: string, receiptId: string,
    selected: Map<string, Set<string>>,
    legacyVncResetEpoch: number, migrationId: string,
    sourceKind: LegacySharedStoreSourceKind): number[] {
    const targetColumns: string[] = this.tableColumns(target, targetTable);
    const rows: relationalStore.ResultSet =
      source.querySync(new relationalStore.RdbPredicates(sourceTable));
    const deletedIndex: number =
      rows.getColumnIndex(relationalStore.Field.DELETED_FLAG_FIELD);
    let copied: number = 0;
    let quarantined: number = 0;
    let skipped: number = 0;
    while (rows.goToNextRow()) {
      const sourceRow: relationalStore.ValuesBucket = rows.getRow();
      const recordId: string = this.stringValue(sourceRow['id']);
      if (deletedIndex >= 0 && rows.getLong(deletedIndex) === 1 &&
        sourceKind === 'account_scope') {
        // Apply tombstone deletions from the account-scoped store so hosts
        // deleted after 1.0.8 cannot be resurrected by stale canonical rows.
        if (recordId.length > 0) {
          const deletePredicates =
            new relationalStore.RdbPredicates(targetTable);
          deletePredicates.equalTo('id', recordId);
          target.deleteSync(deletePredicates);
        }
        copied++;
        continue;
      }
      if (deletedIndex >= 0 && rows.getLong(deletedIndex) === 1) {
        skipped++;
        continue;
      }
      const userId: string = this.stringValue(sourceRow['userid']);
      const decision: LegacyRowOwnershipDecision =
        sourceKind === 'account_scope'
          ? accountScopedRowOwnershipDecision(
              userId, scope.ownerScopeId)
          : legacyRowOwnershipDecision(
              userId, scope.kind, verifiedUnionId,
              scope.ownerScopeId);
      if (decision === 'quarantine_missing_owner') {
        quarantined++;
        this.writeQuarantine(target, receiptId, sourceTable, recordId,
          'missing_owner', '', migrationId);
        continue;
      }
      if (decision !== 'target') {
        skipped++;
        continue;
      }
      const bucket: relationalStore.ValuesBucket =
        this.projectBucket(sourceRow, targetColumns);
      if (targetColumns.indexOf('userid') >= 0) {
        bucket['userid'] = scope.ownerScopeId;
      }
      if (targetTable === 'vnclocalrecords') {
        bucket['localonly'] = 1;
        const row: Record<string, string> =
          this.vncStringRow(bucket);
        const record = vncRecordFromCloudRow(row);
        const vncDecision: LegacyVncRowMigrationDecision =
          legacyVncRowMigrationDecision(
            record.userId,
            scope.ownerScopeId,
            record.resetEpoch,
            legacyVncResetEpoch,
            vncRecordIsValid(record));
        if (vncDecision !== 'migrate') {
          quarantined++;
          this.writeQuarantine(
            target,
            receiptId,
            sourceTable,
            recordId,
            vncDecision,
            this.stringValue(bucket['payload']) + ':' +
              this.stringValue(bucket['ciphertext']),
            migrationId);
          continue;
        }
      }
      this.insertRow(target, targetTable, bucket);
      copied++;
      this.recordSelection(selected,
        sourceTable === 'vncrecords' ? 'vncrecordv2' : sourceTable, recordId);
      if (sourceTable === 'remotehosts') {
        const credentialId: string =
          this.stringValue(sourceRow['rdpcredentialid']);
        if (credentialId.length > 0) {
          this.recordSelection(selected, 'rdpcredentials', credentialId);
        }
      }
    }
    rows.close();
    return [copied, quarantined, skipped];
  }

  /**
   * Copy the local canonical overlays that are intentionally absent from
   * setDistributedTables. These rows remain local overlays in the target;
   * localonly and record tombstones are preserved byte-for-byte after strict
   * schema, owner and protocol validation.
   */
  private copyAccountScopedLocalOverlayRows(
    source: relationalStore.RdbStore,
    target: relationalStore.RdbStore,
    table: string,
    scope: AccountScopeToken,
    receiptId: string,
    migrationId: string,
    vncResetEpoch: number
  ): number[] {
    const expectedColumns: string[] = table === VNC_LOCAL_TABLE
      ? VNC_LOCAL_RECORD_COLUMNS : MOONLIGHT_LOCAL_RECORD_COLUMNS;
    if (!this.tableColumnsAreExact(
      source, table, expectedColumns)) {
      throw new Error(
        'account-scoped local overlay source schema mismatch table=' +
        table);
    }
    const rows: relationalStore.ResultSet =
      source.querySync(
        new relationalStore.RdbPredicates(table));
    let copied: number = 0;
    let quarantined: number = 0;
    let skipped: number = 0;
    let targetSchemaVerified: boolean = false;
    while (rows.goToNextRow()) {
      const sourceRow: relationalStore.ValuesBucket =
        rows.getRow();
      const bucket: relationalStore.ValuesBucket =
        this.projectBucket(sourceRow, expectedColumns);
      const recordId: string =
        this.stringValue(bucket['id']);
      const owner: string =
        this.stringValue(bucket['userid']);
      const localOnly: number = Number(
        this.stringValue(bucket['localonly']));
      let payloadValid: boolean = false;
      if (table === VNC_LOCAL_TABLE) {
        const record = vncRecordFromCloudRow(
          this.stringRow(bucket, VNC_RECORD_COLUMNS));
        payloadValid = legacyVncRowMigrationDecision(
          record.userId, scope.ownerScopeId,
          record.resetEpoch, vncResetEpoch,
          vncRecordIsValid(record)) === 'migrate';
      } else {
        payloadValid = moonlightValidateRecord(
          moonlightRecordFromCloudRow(
            this.stringRow(
              bucket,
              MOONLIGHT_RECORD_COLUMNS))).valid;
      }
      const decision: AccountScopedLocalOverlayRowDecision =
        accountScopedLocalOverlayRowDecision(
          owner, scope.ownerScopeId,
          localOnly, payloadValid);
      if (decision === 'other_owner') {
        skipped++;
        continue;
      }
      if (decision !== 'migrate' || recordId.length === 0) {
        quarantined++;
        this.writeQuarantine(
          target, receiptId, table, recordId,
          recordId.length === 0
            ? 'invalid_local_overlay_id' : decision,
          this.stringValue(bucket['payload']) + ':' +
            this.stringValue(bucket['ciphertext']),
          migrationId);
        continue;
      }
      if (!targetSchemaVerified) {
        if (!this.tableExists(target, table) ||
            !this.tableColumnsAreExact(
              target, table, expectedColumns)) {
          rows.close();
          throw new Error(
            'account-scoped local overlay target schema mismatch table=' +
            table);
        }
        targetSchemaVerified = true;
      }
      this.insertRow(target, table, bucket);
      copied++;
    }
    rows.close();
    return [copied, quarantined, skipped];
  }

  private copyReferencedRows(source: relationalStore.RdbStore,
    target: relationalStore.RdbStore, table: string,
    selectedIds: Set<string>, targetOwner: string,
    receiptId: string, migrationId: string): number[] {
    const targetColumns: string[] = this.tableColumns(target, table);
    const rows: relationalStore.ResultSet =
      source.querySync(new relationalStore.RdbPredicates(table));
    const deletedIndex: number =
      rows.getColumnIndex(relationalStore.Field.DELETED_FLAG_FIELD);
    let copied: number = 0;
    let quarantined: number = 0;
    let skipped: number = 0;
    while (rows.goToNextRow()) {
      if (deletedIndex >= 0 && rows.getLong(deletedIndex) === 1) {
        skipped++;
        continue;
      }
      const sourceRow: relationalStore.ValuesBucket = rows.getRow();
      const id: string = this.stringValue(sourceRow['id']);
      if (!selectedIds.has(id)) {
        quarantined++;
        this.writeQuarantine(target, receiptId, table, id,
          'unreferenced_credential_owner_unknown', '', migrationId);
        continue;
      }
      const bucket: relationalStore.ValuesBucket =
        this.projectBucket(sourceRow, targetColumns);
      if (targetColumns.indexOf('userid') >= 0) {
        bucket['userid'] = targetOwner;
      }
      this.insertRow(target, table, bucket);
      copied++;
    }
    rows.close();
    return [copied, quarantined, skipped];
  }

  private copyLocalExtensions(source: relationalStore.RdbStore,
    target: relationalStore.RdbStore,
    selected: Map<string, Set<string>>): number {
    const targetColumns: string[] = this.tableColumns(target, 'localextensions');
    const rows: relationalStore.ResultSet =
      source.querySync(new relationalStore.RdbPredicates('localextensions'));
    let copied: number = 0;
    while (rows.goToNextRow()) {
      const sourceRow: relationalStore.ValuesBucket = rows.getRow();
      const table: string = this.stringValue(sourceRow['tablename']);
      const recordId: string = this.stringValue(sourceRow['recordid']);
      const ownerTable: string = table === 'rdprestrictedadminsecrets'
        ? 'remotehosts' : table;
      const ids: Set<string> | undefined = selected.get(ownerTable);
      if (ids === undefined || !ids.has(recordId)) { continue; }
      this.insertRow(target, 'localextensions',
        this.projectBucket(sourceRow, targetColumns));
      copied++;
    }
    rows.close();
    return copied;
  }

  /**
   * Carries store-scoped safety metadata (restore quarantine markers,
   * bootstrap/barrier/checkpoint state, crypto lifecycle, migration markers)
   * from the account-scoped store into the canonical cloud store. The four
   * store-identity keys are excluded: they are re-derived and written by
   * CloudStore.verifyStoreIdentity() after migration.
   */
  private copyLocalMetadataCarryover(source: relationalStore.RdbStore,
    target: relationalStore.RdbStore): number {
    if (!this.tableExists(source, LOCAL_METADATA_TABLE) ||
      !this.tableExists(target, LOCAL_METADATA_TABLE)) {
      return 0;
    }
    const targetColumns: string[] =
      this.tableColumns(target, LOCAL_METADATA_TABLE);
    if (targetColumns.indexOf('key') < 0 ||
      targetColumns.indexOf('value') < 0) {
      return 0;
    }
    const rows: relationalStore.ResultSet =
      source.querySync(
        new relationalStore.RdbPredicates(
          LOCAL_METADATA_TABLE));
    let copied: number = 0;
    while (rows.goToNextRow()) {
      const sourceRow: relationalStore.ValuesBucket = rows.getRow();
      const key: string = this.stringValue(sourceRow['key']);
      if (key === '' ||
        CARRYOVER_METADATA_EXCLUDE_KEYS.indexOf(key) >= 0) {
        continue;
      }
      this.insertRow(target, LOCAL_METADATA_TABLE,
        this.projectBucket(sourceRow, targetColumns));
      copied++;
    }
    rows.close();
    return copied;
  }

  private normalizeLegacyOwnerRows(
    target: relationalStore.RdbStore,
    scope: AccountScopeToken,
    legacyUnionId: string,
    selected: Map<string, Set<string>>
  ): number {
    if (legacyUnionId.trim().length === 0) { return 0; }
    const counts: number[] =
      this.claimOwnerRowsWithinTransaction(
        target, scope, legacyUnionId,
        LEGACY_OWNER_CLAIM_TABLES, selected);
    return counts[0];
  }

  /** Returns [claimedRows, skippedRows] and must run inside a transaction. */
  private claimOwnerRowsWithinTransaction(
    target: relationalStore.RdbStore,
    scope: AccountScopeToken,
    verifiedUnionId: string,
    tables: string[],
    selected: Map<string, Set<string>>
  ): number[] {
    let claimed: number = 0;
    let skipped: number = 0;
    for (let i = 0; i < tables.length; i++) {
      const table: string = tables[i];
      if (!this.tableExists(target, table) ||
        this.tableColumns(target, table).indexOf('userid') < 0) {
        continue;
      }
      let rows: relationalStore.ResultSet | null = null;
      const claimIds: string[] = [];
      try {
        rows = target.querySync(
          new relationalStore.RdbPredicates(table));
        while (rows.goToNextRow()) {
          const sourceRow: relationalStore.ValuesBucket = rows.getRow();
          const recordId: string =
            this.stringValue(sourceRow['id']);
          const owner: string =
            this.stringValue(sourceRow['userid']);
          const decision: LegacyRowOwnershipDecision =
            legacyRowOwnershipDecision(
              owner, scope.kind, verifiedUnionId,
              scope.ownerScopeId);
          if (decision !== 'target' ||
            owner.trim() === scope.ownerScopeId.trim()) {
            if (decision === 'other_owner') { skipped++; }
            continue;
          }
          if (recordId.length === 0) {
            skipped++;
            continue;
          }
          claimIds.push(recordId);
        }
      } finally {
        if (rows !== null) { rows.close(); }
      }
      for (let j = 0; j < claimIds.length; j++) {
        const predicates =
          new relationalStore.RdbPredicates(table);
        predicates.equalTo('id', claimIds[j]);
        const changed: number = target.updateSync(
          { userid: scope.ownerScopeId }, predicates);
        if (changed > 0) {
          claimed += changed;
          this.recordSelection(selected, table, claimIds[j]);
        } else {
          skipped++;
        }
      }
    }
    return [claimed, skipped];
  }

  private copyAllRows(source: relationalStore.RdbStore,
    target: relationalStore.RdbStore, sourceTable: string,
    targetTable: string): number {
    const targetColumns: string[] = this.tableColumns(target, targetTable);
    const rows: relationalStore.ResultSet =
      source.querySync(new relationalStore.RdbPredicates(sourceTable));
    let copied: number = 0;
    while (rows.goToNextRow()) {
      this.insertRow(target, targetTable,
        this.projectBucket(rows.getRow(), targetColumns));
      copied++;
    }
    rows.close();
    return copied;
  }

  private distinctOwners(source: relationalStore.RdbStore): string[] {
    const owners: string[] = [];
    for (let i = 0; i < OWNER_TABLES.length; i++) {
      const table: string = OWNER_TABLES[i];
      if (table === 'rdpcredentials' || !this.tableExists(source, table) ||
        this.tableColumns(source, table).indexOf('userid') < 0) {
        continue;
      }
      const rows: relationalStore.ResultSet =
        source.querySync(new relationalStore.RdbPredicates(table), ['userid']);
      while (rows.goToNextRow()) {
        const owner: string =
          rows.getString(rows.getColumnIndex('userid')).trim();
        if (owner.length > 0 && owner !== 'local' &&
          owner !== 'device-local' && owners.indexOf(owner) < 0) {
          owners.push(owner);
        }
      }
      rows.close();
    }
    owners.sort();
    return owners;
  }

  private writeMigrationJournal(target: relationalStore.RdbStore,
    receiptId: string, selected: Map<string, Set<string>>,
    migrationId: string, operation: string): void {
    const tables: string[] = Array.from(selected.keys());
    const now: number = Date.now();
    for (let i = 0; i < tables.length; i++) {
      const table: string = tables[i] === 'vncrecords'
        ? 'vncrecordv2' : tables[i];
      const bucket: relationalStore.ValuesBucket = {
        id: receiptId + ':dirty:' + table,
        tablename: table,
        recordid: '__table__',
        operation,
        revision: now + i,
        createdat: now,
        updatedat: now
      };
      this.insertRow(target, JOURNAL_TABLE, bucket);
    }
  }

  private writeReceipt(target: relationalStore.RdbStore, receiptId: string,
    scope: AccountScopeToken, sourceFingerprint: string, status: string,
    countsJson: string, errorDetail: string, startedAt: number,
    completedAt: number, migrationId: string, sourceName: string): void {
    this.insertRow(target, RECEIPT_TABLE, {
      id: receiptId,
      migrationid: migrationId,
      sourcestore: sourceName,
      sourcefingerprint: sourceFingerprint,
      targetowner: scope.ownerScopeId,
      targetstore: scope.storeIdentity,
      status,
      countsjson: countsJson,
      errordetail: errorDetail,
      startedat: startedAt,
      updatedat: Date.now(),
      completedat: completedAt
    });
  }

  private writeQuarantine(target: relationalStore.RdbStore,
    receiptId: string, table: string, recordId: string, reason: string,
    payloadFingerprint: string = '', migrationId: string = MIGRATION_ID): void {
    const safeId: string = recordId.length > 0 ? recordId : '__missing_id__';
    const id: string = receiptId + ':' + table + ':' + safeId + ':' + reason;
    this.insertRow(target, QUARANTINE_TABLE, {
      id,
      migrationid: migrationId,
      tablename: table,
      recordid: safeId,
      reason,
      payloadhashsha256: this.sha256Hex(
        payloadFingerprint.length > 0
          ? payloadFingerprint
          : table + ':' + safeId + ':' + reason),
      payloadciphertext: '',
      redactedsummary: table + ': record requires migration repair',
      createdat: Date.now()
    });
  }

  private readLegacyVncResetEpoch(
    source: relationalStore.RdbStore
  ): number {
    if (!this.tableExists(source, 'cryptoparams')) { return 0; }
    const columns: string[] =
      this.tableColumns(source, 'cryptoparams');
    if (columns.indexOf('key') < 0 ||
      columns.indexOf('value') < 0) {
      return 0;
    }
    const predicates =
      new relationalStore.RdbPredicates('cryptoparams');
    predicates.equalTo('key', 'vnc_reset_epoch');
    const rows: relationalStore.ResultSet =
      source.querySync(predicates);
    let epoch: number = 0;
    while (rows.goToNextRow()) {
      const candidate: number =
        Number(rows.getString(rows.getColumnIndex('value')));
      if (Number.isFinite(candidate) &&
        Number.isInteger(candidate) &&
        candidate >= epoch) {
        epoch = candidate;
      }
    }
    rows.close();
    return epoch;
  }

  private vncStringRow(
    bucket: relationalStore.ValuesBucket
  ): Record<string, string> {
    const row: Record<string, string> = {};
    for (let i = 0; i < VNC_RECORD_COLUMNS.length; i++) {
      const column: string = VNC_RECORD_COLUMNS[i];
      row[column] = this.stringValue(bucket[column]);
    }
    return row;
  }

  private receiptCommitted(target: relationalStore.RdbStore,
    receiptId: string): boolean {
    return this.committedReceipt(
      target, receiptId) !== null;
  }

  private committedReceipt(
    target: relationalStore.RdbStore,
    receiptId: string
  ): CommittedMigrationReceipt | null {
    const predicates =
      new relationalStore.RdbPredicates(RECEIPT_TABLE);
    predicates.equalTo('id', receiptId);
    const rows: relationalStore.ResultSet = target.querySync(predicates);
    let receipt: CommittedMigrationReceipt | null = null;
    if (rows.goToFirstRow() &&
        rows.getString(rows.getColumnIndex('status')) === 'committed') {
      receipt = {
        sourceFingerprint: rows.getString(
          rows.getColumnIndex('sourcefingerprint'))
      };
    }
    rows.close();
    return receipt;
  }

  private upgradeCommittedReceiptFingerprint(
    target: relationalStore.RdbStore,
    receiptId: string,
    sourceFingerprint: string
  ): void {
    const predicates =
      new relationalStore.RdbPredicates(RECEIPT_TABLE);
    predicates.equalTo('id', receiptId);
    target.beginTransaction();
    try {
      const changed: number = target.updateSync({
        sourcefingerprint: sourceFingerprint,
        updatedat: Date.now()
      }, predicates);
      if (changed !== 1) {
        throw new Error(
          'account-scoped receipt fingerprint upgrade failed');
      }
      target.commit();
    } catch (error) {
      try { target.rollBack(); } catch (_rollbackError) {}
      throw new Error(
        'account-scoped receipt fingerprint upgrade transaction failed: ' +
        this.errorDetail(error));
    }
    // API 23 querySync on this device does not expose the same handle's
    // uncommitted transaction writes. Verify only after the durable commit;
    // a failed read-back must never attempt to roll that commit back.
    const rows: relationalStore.ResultSet =
      target.querySync(predicates);
    const valid: boolean = rows.goToFirstRow() &&
      rows.getString(rows.getColumnIndex('status')) ===
        'committed' &&
      rows.getString(
        rows.getColumnIndex('sourcefingerprint')) ===
        sourceFingerprint;
    rows.close();
    if (!valid) {
      throw new Error(
        'account-scoped receipt fingerprint upgrade verification failed');
    }
  }

  private recordSelection(selected: Map<string, Set<string>>,
    table: string, recordId: string): void {
    if (recordId.length === 0) { return; }
    let ids: Set<string> | undefined = selected.get(table);
    if (ids === undefined) {
      ids = new Set<string>();
      selected.set(table, ids);
    }
    ids.add(recordId);
  }

  private projectBucket(source: relationalStore.ValuesBucket,
    targetColumns: string[]): relationalStore.ValuesBucket {
    const result: relationalStore.ValuesBucket = {};
    const keys: string[] = Object.keys(source);
    for (let i = 0; i < keys.length; i++) {
      if (targetColumns.indexOf(keys[i]) >= 0) {
        result[keys[i]] = source[keys[i]];
      }
    }
    return result;
  }

  private insertRow(target: relationalStore.RdbStore, table: string,
    bucket: relationalStore.ValuesBucket): void {
    const rowId: number = target.insertSync(table, bucket,
      relationalStore.ConflictResolution.ON_CONFLICT_REPLACE);
    if (rowId < 0) {
      throw new Error('migration insert failed table=' + table);
    }
  }

  private tableExists(store: relationalStore.RdbStore, table: string): boolean {
    const rows: relationalStore.ResultSet = store.querySqlSync(
      "SELECT name FROM sqlite_master WHERE type='table' AND name='" + table + "'");
    const exists: boolean = rows.goToFirstRow();
    rows.close();
    return exists;
  }

  private tableColumns(store: relationalStore.RdbStore, table: string): string[] {
    const rows: relationalStore.ResultSet =
      store.querySqlSync('PRAGMA table_info(' + table + ')');
    const columns: string[] = [];
    const nameIndex: number = rows.getColumnIndex('name');
    while (rows.goToNextRow()) { columns.push(rows.getString(nameIndex)); }
    rows.close();
    return columns;
  }

  private tableColumnsAreExact(
    store: relationalStore.RdbStore,
    table: string,
    expected: string[]
  ): boolean {
    const actual: string[] =
      this.tableColumns(store, table);
    if (actual.length !== expected.length) { return false; }
    for (let i = 0; i < expected.length; i++) {
      if (actual.indexOf(expected[i]) < 0) { return false; }
    }
    return true;
  }

  private compatibilityMutationRevisions(
    context: common.Context,
    source: relationalStore.RdbStore,
    ownerScopeId: string,
    storeIdentity: string
  ): Record<string, number> {
    const result: Record<string, number> = {};
    if (this.tableExists(source, LOCAL_METADATA_TABLE)) {
      const rows: relationalStore.ResultSet = source.querySync(
        new relationalStore.RdbPredicates(LOCAL_METADATA_TABLE));
      while (rows.goToNextRow()) {
        const metadataKey: string =
          rows.getString(rows.getColumnIndex('key'));
        if (metadataKey.indexOf(
          COMPATIBILITY_MUTATION_METADATA_PREFIX) !== 0) {
          continue;
        }
        const table: string = metadataKey.slice(
          COMPATIBILITY_MUTATION_METADATA_PREFIX.length);
        const revision: number = Number(
          rows.getString(rows.getColumnIndex('value')));
        if (table !== '' && Number.isFinite(revision) && revision > 0) {
          result[table] = Math.floor(revision);
        }
      }
      rows.close();
    }
    const key: string = compatibilityMutationPreferenceKey(
      ownerScopeId, storeIdentity);
    if (key === '') { return result; }
    const prefs = preferences.getPreferencesSync(
      context, { name: COMPATIBILITY_MUTATION_PREFERENCES_NAME });
    const stored: Object = prefs.getSync(key, '') as Object;
    if (typeof stored !== 'string' || (stored as string) === '') {
      return result;
    }
    const parsed: Record<string, Object> =
      JSON.parse(stored as string) as Record<string, Object>;
    const tables: string[] = Object.keys(parsed);
    for (let i = 0; i < tables.length; i++) {
      const value: Object = parsed[tables[i]];
      if (tables[i] !== '' && typeof value === 'number' &&
          Number.isFinite(value as number) &&
          (value as number) > 0) {
        result[tables[i]] = Math.max(
          result[tables[i]] || 0,
          Math.floor(value as number));
      }
    }
    return result;
  }

  private sourceMutationFingerprint(
    source: relationalStore.RdbStore,
    compatibilityRevisions: Record<string, number> = {}
  ): string {
    const values: string[] = [];
    if (this.tableExists(source, JOURNAL_TABLE)) {
      const rows: relationalStore.ResultSet =
        source.querySync(
          new relationalStore.RdbPredicates(
            JOURNAL_TABLE));
      while (rows.goToNextRow()) {
        values.push([
          rows.getString(rows.getColumnIndex('id')),
          rows.getString(rows.getColumnIndex('tablename')),
          rows.getString(rows.getColumnIndex('recordid')),
          rows.getString(rows.getColumnIndex('operation')),
          rows.getLong(rows.getColumnIndex('revision')).toString(),
          rows.getLong(rows.getColumnIndex('createdat')).toString(),
          rows.getLong(rows.getColumnIndex('updatedat')).toString()
        ].join(':'));
      }
      rows.close();
    }
    if (this.tableExists(source, LOCAL_METADATA_TABLE)) {
      const rows: relationalStore.ResultSet =
        source.querySync(
          new relationalStore.RdbPredicates(
            LOCAL_METADATA_TABLE));
      while (rows.goToNextRow()) {
        const key: string =
          rows.getString(rows.getColumnIndex('key'));
        if (key.indexOf(
          COMPATIBILITY_MUTATION_METADATA_PREFIX) === 0) {
          values.push('metadata:' + key + ':' +
            rows.getString(rows.getColumnIndex('value')));
        }
      }
      rows.close();
    }
    values.sort();
    const compatibilityTables: string[] =
      Object.keys(compatibilityRevisions);
    if (compatibilityTables.length === 0) {
      return 'journal-v1:' +
        this.sha256Hex(values.join('\n'));
    }
    compatibilityTables.sort();
    const compatibilityValues: string[] = [];
    for (let i = 0; i < compatibilityTables.length; i++) {
      const table: string = compatibilityTables[i];
      compatibilityValues.push(
        table + ':' + compatibilityRevisions[table].toString());
    }
    return 'journal-v2:' + this.sha256Hex(
      values.join('\n') + '\ncompatibility\n' +
      compatibilityValues.join('\n'));
  }

  private localMetadataValue(
    store: relationalStore.RdbStore,
    key: string
  ): string | null {
    if (!this.tableExists(store, LOCAL_METADATA_TABLE)) {
      return null;
    }
    const predicates =
      new relationalStore.RdbPredicates(
        LOCAL_METADATA_TABLE);
    predicates.equalTo('key', key);
    const rows: relationalStore.ResultSet =
      store.querySync(predicates);
    const value: string | null = rows.goToFirstRow()
      ? rows.getString(rows.getColumnIndex('value'))
      : null;
    rows.close();
    return value;
  }

  private sourceFingerprint(path: string, version: number,
    owners: string[]): string {
    const stat = fileIo.statSync(path);
    return this.sha256Hex(
      stat.size.toString() + ':' + stat.mtime.toString() + ':' +
      version.toString() + ':' + owners.join(','));
  }

  private sha256Hex(value: string): string {
    const md = cryptoFramework.createMd('SHA256');
    md.updateSync({ data: new util.TextEncoder().encode(value) });
    const bytes: Uint8Array = md.digestSync().data;
    let hex: string = '';
    for (let i = 0; i < bytes.length; i++) {
      hex += bytes[i].toString(16).padStart(2, '0');
    }
    return hex;
  }

  private stringValue(value: relationalStore.ValueType | undefined): string {
    if (typeof value === 'string') { return value; }
    return typeof value === 'number' ? value.toString() : '';
  }

  private stringRow(
    bucket: relationalStore.ValuesBucket,
    columns: string[]
  ): Record<string, string> {
    const row: Record<string, string> = {};
    for (let i = 0; i < columns.length; i++) {
      row[columns[i]] =
        this.stringValue(bucket[columns[i]]);
    }
    return row;
  }

  private errorDetail(err: Object): string {
    if (err instanceof Error) { return err.message; }
    try { return JSON.stringify(err); } catch (_jsonError) { return 'unknown'; }
  }
}
