import { common } from '@kit.AbilityKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { relationalStore } from '@kit.ArkData';
import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { AccountScopeToken, accountStoreIdentity } from './AccountScopePolicy';
import {
  accountScopedCryptoParamsMayMigrate,
  accountScopedRowOwnershipDecision,
  legacyCryptoParamsMayMigrate,
  legacyRowOwnershipDecision,
  legacyVncRowMigrationDecision,
  LegacyRowOwnershipDecision,
  LegacyVncRowMigrationDecision
} from './LegacySharedStoreMigrationPolicy';
import {
  VNC_RECORD_COLUMNS,
  vncRecordFromCloudRow,
  vncRecordIsValid
} from './VncRecordPolicy';

const LEGACY_STORE_NAME: string = 'remotedesktop.db';
const ACCOUNT_SCOPED_MIGRATION_ID: string = 'account-scoped-store-v1';
const RECEIPT_TABLE: string = 'migrationreceipts';
const QUARANTINE_TABLE: string = 'migrationquarantine';
const JOURNAL_TABLE: string = 'localmutationjournal';
const MIGRATION_ID: string = 'legacy-shared-store-v1';
const OWNER_CLAIM_MIGRATION_ID: string = 'legacy-owner-claim-v2';
/** Store-scoped metadata that must survive an account-scope migration. */
const CARRYOVER_METADATA_EXCLUDE_KEYS: string[] = [
  'store_owner_scope_id',
  'store_identity',
  'store_schema_revision',
  'store_platform_cloud_identity_fingerprint'
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
  'vncrecordv2'
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

export class LegacySharedStoreMigrator {
  private static instance: LegacySharedStoreMigrator;

  static getInstance(): LegacySharedStoreMigrator {
    if (!LegacySharedStoreMigrator.instance) {
      LegacySharedStoreMigrator.instance = new LegacySharedStoreMigrator();
    }
    return LegacySharedStoreMigrator.instance;
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
    if (this.receiptCommitted(target, receiptId)) {
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
      result = this.copySource(
        source, target, scope, verifiedUnionId, receiptId, path,
        migrationId, sourceName, sourceKind);
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
    sourceKind: LegacySharedStoreSourceKind):
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
    const sourceFingerprint: string = this.sourceFingerprint(
      sourcePath, source.version, distinctOwners);
    const startedAt: number = Date.now();
    target.beginTransaction();
    try {
      this.writeReceipt(target, receiptId, scope, sourceFingerprint,
        'running', '{}', '', startedAt, 0, migrationId, sourceName);
      for (let i = 0; i < EXPLICIT_OWNER_TABLES.length; i++) {
        const sourceTable: string = EXPLICIT_OWNER_TABLES[i];
        if (!this.tableExists(source, sourceTable)) { continue; }
        const targetTable: string =
          sourceTable === 'vncrecords' || sourceTable === 'vncrecord' ||
            sourceTable === 'vncrecordv2'
            ? 'vnclocalrecords' : sourceTable;
        const counts: number[] = this.copyOwnedRows(
          source, target, sourceTable, targetTable, scope,
          verifiedUnionId, receiptId, selected,
          legacyVncResetEpoch, migrationId, sourceKind);
        copiedRows += counts[0];
        quarantinedRows += counts[1];
        skippedRows += counts[2];
      }
      if (this.tableExists(source, 'rdpcredentials')) {
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
    if (!this.tableExists(source, 'localmetadata') ||
      !this.tableExists(target, 'localmetadata')) {
      return 0;
    }
    const targetColumns: string[] =
      this.tableColumns(target, 'localmetadata');
    if (targetColumns.indexOf('key') < 0 ||
      targetColumns.indexOf('value') < 0) {
      return 0;
    }
    const rows: relationalStore.ResultSet =
      source.querySync(new relationalStore.RdbPredicates('localmetadata'));
    let copied: number = 0;
    while (rows.goToNextRow()) {
      const sourceRow: relationalStore.ValuesBucket = rows.getRow();
      const key: string = this.stringValue(sourceRow['key']);
      if (key === '' ||
        CARRYOVER_METADATA_EXCLUDE_KEYS.indexOf(key) >= 0) {
        continue;
      }
      this.insertRow(target, 'localmetadata',
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
    const predicates =
      new relationalStore.RdbPredicates(RECEIPT_TABLE);
    predicates.equalTo('id', receiptId);
    const rows: relationalStore.ResultSet = target.querySync(predicates);
    const committed: boolean = rows.goToFirstRow() &&
      rows.getString(rows.getColumnIndex('status')) === 'committed';
    rows.close();
    return committed;
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

  private errorDetail(err: Object): string {
    if (err instanceof Error) { return err.message; }
    try { return JSON.stringify(err); } catch (_jsonError) { return 'unknown'; }
  }
}
