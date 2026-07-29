import { common } from '@kit.AbilityKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { relationalStore } from '@kit.ArkData';
import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { AccountScopeToken } from './AccountScopePolicy';
import {
  legacyCryptoParamsMayMigrate,
  legacyRowOwnershipDecision,
  LegacyRowOwnershipDecision
} from './LegacySharedStoreMigrationPolicy';

const LEGACY_STORE_NAME: string = 'remotedesktop.db';
const RECEIPT_TABLE: string = 'migrationreceipts';
const QUARANTINE_TABLE: string = 'migrationquarantine';
const JOURNAL_TABLE: string = 'localmutationjournal';
const MIGRATION_ID: string = 'legacy-shared-store-v1';
const OWNER_TABLES: string[] = [
  'remotehosts',
  'rdpcredentials',
  'rustdeskrelays',
  'sshkeys',
  'totpentries',
  'usersettings',
  'vncrecords',
  'vncrecord'
];
const EXPLICIT_OWNER_TABLES: string[] = [
  'remotehosts',
  'rustdeskrelays',
  'sshkeys',
  'totpentries',
  'usersettings',
  'vncrecords',
  'vncrecord'
];

export interface LegacySharedStoreMigrationResult {
  found: boolean;
  migrated: boolean;
  copiedRows: number;
  quarantinedRows: number;
  skippedRows: number;
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
    scope: AccountScopeToken, verifiedUnionId: string = ''):
    Promise<LegacySharedStoreMigrationResult> {
    const empty: LegacySharedStoreMigrationResult = {
      found: false, migrated: false, copiedRows: 0,
      quarantinedRows: 0, skippedRows: 0
    };
    const path: string = context.databaseDir + '/' + LEGACY_STORE_NAME;
    if (!fileIo.accessSync(path)) { return empty; }
    const receiptId: string = MIGRATION_ID + ':' + scope.ownerScopeId;
    if (this.receiptCommitted(target, receiptId)) {
      return {
        found: true, migrated: true, copiedRows: 0,
        quarantinedRows: 0, skippedRows: 0
      };
    }
    const source: relationalStore.RdbStore = await relationalStore.getRdbStore(
      context, {
        name: LEGACY_STORE_NAME,
        securityLevel: relationalStore.SecurityLevel.S1,
        isReadOnly: true
      });
    let result: LegacySharedStoreMigrationResult = empty;
    try {
      result = this.copySource(
        source, target, scope, verifiedUnionId, receiptId, path);
    } finally {
      // The target receipt and copied rows are already one committed
      // transaction. A source-handle close error must not turn that durable
      // success into an apparent migration failure on this launch.
      try { await source.close(); } catch (_closeError) {}
    }
    return result;
  }

  private copySource(source: relationalStore.RdbStore,
    target: relationalStore.RdbStore, scope: AccountScopeToken,
    verifiedUnionId: string, receiptId: string, sourcePath: string):
    LegacySharedStoreMigrationResult {
    let copiedRows: number = 0;
    let quarantinedRows: number = 0;
    let skippedRows: number = 0;
    const selected: Map<string, Set<string>> = new Map<string, Set<string>>();
    const distinctOwners: string[] = this.distinctOwners(source);
    const sourceFingerprint: string = this.sourceFingerprint(
      sourcePath, source.version, distinctOwners);
    const startedAt: number = Date.now();
    target.beginTransaction();
    try {
      this.writeReceipt(target, receiptId, scope, sourceFingerprint,
        'running', '{}', '', startedAt, 0);
      for (let i = 0; i < EXPLICIT_OWNER_TABLES.length; i++) {
        const sourceTable: string = EXPLICIT_OWNER_TABLES[i];
        if (!this.tableExists(source, sourceTable)) { continue; }
        const targetTable: string =
          sourceTable === 'vncrecords' || sourceTable === 'vncrecord'
            ? 'vnclocalrecords' : sourceTable;
        const counts: number[] = this.copyOwnedRows(
          source, target, sourceTable, targetTable, scope,
          verifiedUnionId, receiptId, selected);
        copiedRows += counts[0];
        quarantinedRows += counts[1];
        skippedRows += counts[2];
      }
      if (this.tableExists(source, 'rdpcredentials')) {
        const rdpCounts: number[] = this.copyReferencedRows(
          source, target, 'rdpcredentials',
          selected.get('rdpcredentials') ?? new Set<string>(),
          scope.ownerScopeId, receiptId);
        copiedRows += rdpCounts[0];
        quarantinedRows += rdpCounts[1];
        skippedRows += rdpCounts[2];
      }
      if (this.tableExists(source, 'localextensions')) {
        copiedRows += this.copyLocalExtensions(source, target, selected);
      }
      if (this.tableExists(source, 'cryptoparams')) {
        if (legacyCryptoParamsMayMigrate(
          distinctOwners, scope.kind, verifiedUnionId)) {
          copiedRows += this.copyAllRows(
            source, target, 'cryptoparams', 'cryptoparams');
          this.recordSelection(selected, 'cryptoparams', '__table__');
        } else {
          quarantinedRows++;
          this.writeQuarantine(target, receiptId, 'cryptoparams',
            '__table__', 'ambiguous_crypto_owner');
        }
      }
      this.writeMigrationJournal(target, receiptId, selected);
      const countsJson: string = JSON.stringify({
        copiedRows, quarantinedRows, skippedRows
      });
      this.writeReceipt(target, receiptId, scope, sourceFingerprint,
        'committed', countsJson, '', startedAt, Date.now());
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
    selected: Map<string, Set<string>>): number[] {
    const targetColumns: string[] = this.tableColumns(target, targetTable);
    const rows: relationalStore.ResultSet =
      source.querySync(new relationalStore.RdbPredicates(sourceTable));
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
      const recordId: string = this.stringValue(sourceRow['id']);
      const userId: string = this.stringValue(sourceRow['userid']);
      const decision: LegacyRowOwnershipDecision =
        legacyRowOwnershipDecision(userId, scope.kind, verifiedUnionId);
      if (decision === 'quarantine_missing_owner') {
        quarantined++;
        this.writeQuarantine(target, receiptId, sourceTable, recordId,
          'missing_owner');
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
      if (targetTable === 'vnclocalrecords') { bucket['localonly'] = 1; }
      this.insertRow(target, targetTable, bucket);
      copied++;
      this.recordSelection(selected,
        sourceTable === 'vncrecords' ? 'vncrecord' : sourceTable, recordId);
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
    receiptId: string): number[] {
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
          'unreferenced_credential_owner_unknown');
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
    receiptId: string, selected: Map<string, Set<string>>): void {
    const tables: string[] = Array.from(selected.keys());
    const now: number = Date.now();
    for (let i = 0; i < tables.length; i++) {
      const table: string = tables[i] === 'vncrecords'
        ? 'vncrecord' : tables[i];
      const bucket: relationalStore.ValuesBucket = {
        id: receiptId + ':dirty:' + table,
        tablename: table,
        recordid: '__table__',
        operation: 'legacy_migrated_not_uploaded',
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
    completedAt: number): void {
    this.insertRow(target, RECEIPT_TABLE, {
      id: receiptId,
      migrationid: MIGRATION_ID,
      sourcestore: LEGACY_STORE_NAME,
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
    receiptId: string, table: string, recordId: string, reason: string): void {
    const safeId: string = recordId.length > 0 ? recordId : '__missing_id__';
    const id: string = receiptId + ':' + table + ':' + safeId + ':' + reason;
    this.insertRow(target, QUARANTINE_TABLE, {
      id,
      migrationid: MIGRATION_ID,
      tablename: table,
      recordid: safeId,
      reason,
      payloadhashsha256: this.sha256Hex(table + ':' + safeId + ':' + reason),
      payloadciphertext: '',
      redactedsummary: table + ': record requires ownership confirmation',
      createdat: Date.now()
    });
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
    return typeof value === 'string' ? value : '';
  }

  private errorDetail(err: Object): string {
    if (err instanceof Error) { return err.message; }
    try { return JSON.stringify(err); } catch (_jsonError) { return 'unknown'; }
  }
}
