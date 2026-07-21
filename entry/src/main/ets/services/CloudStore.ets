/**
 * CloudStore.ets — 端云分布式数据库封装
 *
 * 基于 @kit.ArkData relationalStore + setDistributedTables,
 * 登录同一华为账号的设备数据自动同步, 无需自建服务器。
 *
 * 表结构 (名称不含下划线, AGC 限制):
 *   remotehosts  — 远程主机 (RDP/RustDesk/SSH)
 *   sshkeys      — SSH 密钥
 *   totpentries  — 2FA TOTP 条目
 */
import { relationalStore, preferences } from '@kit.ArkData';
import { cloudData } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { BusinessError, deviceInfo } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  RemoteHost,
  DisplayConfig,
  DisplayConfigJSON,
  normalizeRdpAuthMode,
  normalizeRdpNtlmHash,
  normalizeRdpRestrictedAdminSecretSource,
  RdpAuthMode,
  RdpRestrictedAdminSecretSource
} from '../model/RemoteHost';
import { RustDeskRelayConfig, RustDeskRelayJSON } from '../model/RustDeskRelayConfig';
import { RustDeskAccount, RustDeskAccountJSON } from '../model/RustDeskAccount';
import { RdpCredential } from '../model/RdpCredential';
import { SshKey, SshKeyType } from '../model/SshKey';
import { TotpEntry, TotpAlgorithm } from '../model/TotpEntry';
import { DataCrypto, CryptoCloudStore } from './DataCrypto';
import { hashForLog, safeError } from '../utils/SafeLogger';
import { cloudSyncTableNames, CloudSyncDirection } from './CloudSyncPolicy';
import { CloudSyncCoordinator, CloudSyncCoordinatorHooks, CloudSyncOperationResult } from './CloudSyncCoordinator';
import {
  cloudDistributedTableAutoSync,
  cloudLocalMutationAllowed,
  cloudSyncProgressFinished,
  cloudSyncProgressSucceeded
} from './CloudSyncCoordinatorPolicy';
import { CloudSyncSelectionStore } from './CloudSyncSelectionStore';
import {
  cloudServiceGuidanceRequiredForMessage,
  rdbInsertSucceeded,
  rdbSingleRowAffected
} from './CloudStoreMutationPolicy';
import {
  cloudUserSettingIsSyncable,
  CloudUserSettingValue
} from './CloudSyncSettingsPolicy';
import {
  localBackupColumnsForTable,
  localBackupLocalExtensionColumns,
  validateLocalBackupSnapshot
} from './LocalBackupPolicy';
import { DataMutationResult } from './DataMutationResult';
import { canonicalHostPassword } from './SensitiveDataMigrationPolicy';
import {
  sensitiveWriteRequiresUnlock,
  shouldRedactLockedCiphertext
} from './SensitiveDataStatePolicy';
import {
  VIRTUAL_MOUSE_STYLE_RESTORE_VERSION_KEY,
  shouldApplyCloudVirtualMouseStyle
} from './RemoteCursorStylePolicy';
import {
  cloudTableColumns,
  encodeUserSettingsPayload,
  decodeUserSettingsPayload,
  projectRemoteHostCloudExtension,
  encodeRemoteHostDisplayPayload,
  decodeRemoteHostDisplayPayload,
  RemoteHostDisplayPayload
} from './CloudTableAdapter';

const DB_NAME: string = 'remotedesktop';
const TABLES: string[] = cloudSyncTableNames();
const RDP_RESTRICTED_ADMIN_SECRET_TABLE: string = 'rdprestrictedadminsecrets';
const LOCAL_METADATA_TABLE: string = 'localmetadata';
const LOCAL_MUTATION_JOURNAL_TABLE: string = 'localmutationjournal';
const CANONICAL_SECRET_STORAGE_VERSION_KEY: string = 'canonical_secret_storage_version';
const CANONICAL_SECRET_STORAGE_VERSION: string = '2';
const RESTORED_NOT_UPLOADED_KEY: string = 'restored_not_uploaded';
const TABLE_MUTATION_RECORD_ID: string = '__table__';
const LOCAL_METADATA_COLUMNS: string[] = ['key', 'value', 'updatedat'];
const LOCAL_MUTATION_JOURNAL_COLUMNS: string[] = [
  'id', 'tablename', 'recordid', 'operation', 'revision', 'createdat', 'updatedat'
];

export class RdpRestrictedAdminSecretResult {
  status: string = 'missing';
  hash: string = '';
}

/** 单表同步状态 */
export class TableSyncStatus {
  ok: number = 0;
  fail: number = 0;
  last: number = 0;
}

/** 同步状态快照 */
export interface SyncStatus {
  lastSyncTime: number;
  syncSuccessCount: number;
  syncFailCount: number;
  lastError: string;
  tableStatus: Record<string, TableSyncStatus>;
}

export class CloudStore implements CryptoCloudStore {
  private static instance: CloudStore;
  private store: relationalStore.RdbStore | null = null;
  private appContext: common.Context | null = null;
  private initialized: boolean = false;
  private cloudAvailable: boolean = false;
  private cloudServiceGuidanceNeeded: boolean = false;
  private onChangeCallbacks: Array<() => void> = [];
  private onCryptoResetCallbacks: Array<() => void> = [];
  // 同步状态追踪
  private lastSyncTime: number = 0;
  private syncSuccessCount: number = 0;
  private syncFailCount: number = 0;
  private lastError: string = '';
  private tableStatus: Record<string, TableSyncStatus> = {}
  private automaticPushSuppressed: boolean = false;
  private manualDownloadSnapshot: Record<string, Array<Record<string, string>>> | null = null;
  private manualDownloadExtensions: Array<Record<string, string>> | null = null;
  private manualDownloadMetadata: Array<Record<string, string>> | null = null;
  private manualDownloadMutationJournal: Array<Record<string, string>> | null = null;
  private localRestoreActive: boolean = false;
  private localRestorePending: boolean = false;
  private lastMutationResult: DataMutationResult = DataMutationResult.success('');
  private lastMutationRevision: number = 0;
  private readonly syncSelection: CloudSyncSelectionStore = CloudSyncSelectionStore.getInstance();
  // 加密状态追踪
  private lastKnownCryptoStatus: string = '';
  // A cloud-first apply may synchronously lock/unlock DataCrypto.  Hold its
  // state callback until the completed cloud snapshot is published once.
  private suppressCryptoStateSnapshot: boolean = false;

  /** 获取同步状态快照 (用于诊断) */
  getSyncStatus(): SyncStatus {
    return {
      lastSyncTime: this.lastSyncTime,
      syncSuccessCount: this.syncSuccessCount,
      syncFailCount: this.syncFailCount,
      lastError: this.lastError,
      tableStatus: this.tableStatus
    };
  }

  /** 调试: 打印本地数据库行数 + 同步状态 */
  debugDump(): string {
    const parts: string[] = [];
    parts.push("isReady=" + this.initialized.toString());
    if (this.store && this.initialized) {
      for (let i = 0; i < TABLES.length; i++) {
        try {
          const predicates = new relationalStore.RdbPredicates(TABLES[i]);
          const rs = this.store.querySync(predicates);
          parts.push(TABLES[i] + "=" + rs.rowCount.toString() + "rows");
          rs.close();
        } catch (e) {
          parts.push(TABLES[i] + "=err");
        }
      }
    }
    const st = this.getSyncStatus();
    parts.push("syncOK=" + st.syncSuccessCount.toString() + " syncFAIL=" + st.syncFailCount.toString());
    const result = parts.join(' | ');
    hilog.info(0x0001, 'CloudSync', "[DEBUG] " + result);
    return result;
  }

  static getInstance(): CloudStore {
    if (!CloudStore.instance) {
      CloudStore.instance = new CloudStore();
    }
    return CloudStore.instance;
  }

  /** 初始化数据库 + 开启云同步 */
  async init(context: common.Context): Promise<void> {
    this.appContext = context;
    if (this.initialized) { return; }
    // 初始化表级同步状态
    for (let i = 0; i < TABLES.length; i++) {
      this.tableStatus[TABLES[i]] = new TableSyncStatus();
    }
    try {
      const config: relationalStore.StoreConfig = {
        name: DB_NAME + '.db',
        securityLevel: relationalStore.SecurityLevel.S1,
        // 系统自动同步关闭；显式 cloud-first 同步仍需将云端删除清理到当前已选表。
        autoCleanDirtyData: false
      };
      this.store = await relationalStore.getRdbStore(context, config);
      hilog.info(0x0001, 'CloudSync',
        "[DEBUG] 系统版本: " + deviceInfo.osFullName + ", RDB已创建");

      await this.createTables();
      await this.migrateLocalExtensions();
      // 本地库必须独立可用；云服务未开通或网络策略设置失败时仍要恢复缓存数据。
      this.initialized = true;
      this.syncSelection.init(context);
      const crypto: DataCrypto = DataCrypto.getInstance();
      crypto.init(this);
      crypto.onStateChange((_ready: boolean, _configured: boolean): void => {
        if (!this.initialized) { return; }
        // Models may currently contain either decrypted values or locked-state
        // redactions. Reload them once from RDB for the new DEK state.
        this.lastKnownCryptoStatus = this.getCryptoStatus();
        if (!this.suppressCryptoStateSnapshot) {
          this.notifyDataSnapshotChanged();
        }
      });
      CloudSyncCoordinator.getInstance().init(
        context,
        (table: string, direction: CloudSyncDirection, label: string): Promise<boolean> =>
          this.executeSyncTable(table, direction, label),
        (tables: string[]): void => { this.notifyCloudDataApplied(tables); },
        this.coordinatorHooks()
      );
      // setDistributedTables — 同步关键入口, 必须捕获错误码
      try {
        await this.store.setDistributedTables(
          TABLES,
          relationalStore.DistributedType.DISTRIBUTED_CLOUD,
          { autoSync: cloudDistributedTableAutoSync() }
        );
        hilog.info(0x0001, 'CloudSync',
          'setDistributedTables 成功 — 云同步已生效');
        this.cloudAvailable = true;
      } catch (e) {
        const be: BusinessError = e as BusinessError;
        hilog.error(0x0001, 'CloudSync',
          "setDistributedTables 失败! code=" + be.code.toString() + " msg=" + be.message);
        this.cloudAvailable = false;
        this.cloudServiceGuidanceNeeded = this.errorRequiresCloudServiceGuidance(be);
        this.lastError = 'setDistributedTables: code=' + be.code.toString() + ' msg=' + be.message;
      }
      // 仅 WiFi 下同步；策略设置失败不能让本地数据库也不可用。
      try {
        await cloudData.setCloudStrategy(
          cloudData.StrategyType.NETWORK,
          [cloudData.NetWorkStrategy.WIFI]
        );
      } catch (e) {
        const be: BusinessError = e as BusinessError;
        this.lastError = 'setCloudStrategy: code=' + be.code.toString() + ' msg=' + be.message;
        hilog.error(0x0001, 'CloudSync', this.lastError);
      }
      hilog.info(0x0001, 'CloudSync', 'CloudStore 初始化完成');
      hilog.info(0x0001, 'CloudSync', "分布式表: " + TABLES.join(',') + ", autoSync=false (应用显式协调)");
      hilog.info(0x0001, 'CloudSync', "云策略: WIFI only");
      // dump 本地行数
      this.debugDump();
      // 订阅云端数据变更 (事件驱动, 替代定时轮询)
      if (this.cloudAvailable) {
        this.subscribeCloudChanges();
      }
      // 初始化加密状态追踪
      this.lastKnownCryptoStatus = this.getCryptoStatus();
      hilog.info(0x0001, 'CloudSync',
        '云空间同步已就绪 — 请确认两台设备"设置→华为账号"为同一账号');
    } catch (err) {
      hilog.error(0x0001, 'CloudSync', "初始化失败: " + DataCrypto.errDetail(err));
    }
  }

  /** 注册云端数据变更回调 (供 Service 层使用) */
  onCloudChange(callback: () => void): void {
    this.onChangeCallbacks.push(callback);
  }

  /** 注册加密重置回调 (供 Service 层使用, 重置时清空内存数据) */
  onCryptoReset(callback: () => void): void {
    this.onCryptoResetCallbacks.push(callback);
  }

  private notifyDataSnapshotChanged(): void {
    const callbacks: Array<() => void> = this.onChangeCallbacks.slice();
    for (let i = 0; i < callbacks.length; i++) {
      try { callbacks[i](); } catch (err) {
        hilog.warn(0x0001, 'CloudSync', '[CloudStore] data listener failed: ' + safeError(err));
      }
    }
  }

  /** 订阅云空间数据变更事件 (系统级推送, 替代轮询) */
  private subscribeCloudChanges(): void {
    if (!this.store) { return; }
    try {
      this.store.on('dataChange',
        relationalStore.SubscribeType.SUBSCRIBE_TYPE_CLOUD,
        (accounts: Array<string>) => {
          this.lastSyncTime = Date.now();
          this.syncSuccessCount++;
          hilog.info(0x0001, 'CloudSync',
            '云端数据变更: ' + accounts.length.toString() + ' 个账号, 延迟到下次启动或手动下载');
        }
      );
      hilog.info(0x0001, 'CloudSync', '已订阅云空间数据变更事件');
    } catch (err) {
      hilog.error(0x0001, 'CloudSync',
        "订阅云空间变更失败: " + JSON.stringify(err));
    }
  }

  /** 取消订阅云空间数据变更 */
  unsubscribeCloudChanges(): void {
    if (!this.store) { return; }
    try {
      this.store.off('dataChange',
        relationalStore.SubscribeType.SUBSCRIBE_TYPE_CLOUD
      );
      hilog.info(0x0001, 'CloudSync', '已取消订阅云空间数据变更');
    } catch (err) {
      hilog.error(0x0001, 'CloudSync',
        "取消订阅失败: " + JSON.stringify(err));
    }
  }

  /** 成功本地写入后的自动推送统一进入协调器。 */
  pushTable(table: string): void {
    if (!this.localMutationAllowed() || this.automaticPushSuppressed || this.syncableTables().indexOf(table) < 0) {
      return;
    }
    if (!this.isCloudAvailable()) {
      hilog.warn(0x0001, 'CloudSync', 'pushTable 跳过: 云同步不可用 table=' + table);
      return;
    }
    CloudSyncCoordinator.getInstance().requestAutomaticPush(table);
  }

  /** 兼容服务层调用；所有启动/恢复拉取都由协调器合并。 */
  pullNowAsync(): Promise<boolean> {
    return CloudSyncCoordinator.getInstance().requestStartupPull()
      .then((result): boolean => result.ok);
  }

  /** 手动触发拉取 (fire-and-forget, 内部用) */
  pullNow(): void {
    this.pullNowAsync(); // fire Promise, 不 await
  }

  /** 用户确认后覆盖云端：强制本地优先，并等待每个表完成。 */
  async uploadAllToCloud(): Promise<boolean> {
    if (!this.hasAnyBusinessRows()) {
      hilog.warn(0x0001, 'CloudSync', 'manual upload blocked: local business tables are empty');
      return false;
    }
    const result = await CloudSyncCoordinator.getInstance().requestManualUpload();
    return result.ok;
  }

  /** 启动恢复或用户确认下载：强制云端优先，避免空白本地库覆盖云端。 */
  async downloadAllFromCloud(): Promise<boolean> {
    const result = await this.downloadAllFromCloudResult();
    return result.ok;
  }

  async downloadAllFromCloudResult(): Promise<CloudSyncOperationResult> {
    return await CloudSyncCoordinator.getInstance().requestManualDownload();
  }

  syncableTables(): string[] {
    return this.syncSelection.effectiveTables();
  }

  setAutomaticPushSuppressed(suppressed: boolean): void {
    this.automaticPushSuppressed = suppressed;
  }

  private localMutationAllowed(): boolean {
    return cloudLocalMutationAllowed(
      this.manualDownloadSnapshot !== null,
      this.localRestoreActive || this.localRestorePending
    );
  }

  private coordinatorHooks(): CloudSyncCoordinatorHooks {
    return {
      beginManualDownload: (): boolean => {
        if (!this.store) { return false; }
        try {
          // A read transaction plus the mutation guard makes rollback snapshot-consistent.
          this.store.beginTransaction();
          this.manualDownloadSnapshot = this.exportAllTableRows();
          this.manualDownloadExtensions = this.exportLocalExtensionRows();
          this.manualDownloadMetadata = this.exportLocalMetadataRows();
          this.manualDownloadMutationJournal = this.exportMutationJournalRows();
          this.store.commit();
          return true;
        } catch (_e) {
          try { this.store.rollBack(); } catch (_ignored) {}
          this.manualDownloadSnapshot = null;
          this.manualDownloadExtensions = null;
          this.manualDownloadMetadata = null;
          this.manualDownloadMutationJournal = null;
          return false;
        }
      },
      rollbackManualDownload: async (): Promise<boolean> => {
        const snapshot = this.manualDownloadSnapshot;
        const extensions = this.manualDownloadExtensions;
        const metadata = this.manualDownloadMetadata;
        const journal = this.manualDownloadMutationJournal;
        const restored: boolean = snapshot !== null && (await this.restoreManualDownloadSnapshot(
          snapshot, extensions || [], metadata || [], journal || []));
        this.manualDownloadSnapshot = null;
        this.manualDownloadExtensions = null;
        this.manualDownloadMetadata = null;
        this.manualDownloadMutationJournal = null;
        return restored;
      },
      completeManualDownload: (tables: string[]): boolean => {
        // The local intent must be discarded before exposing a cloud-first
        // success; otherwise a later automatic retry could overwrite it.
        if (!this.discardMutationJournalForTables(tables) || !this.clearRestoredNotUploaded()) {
          return false;
        }
        this.manualDownloadSnapshot = null;
        this.manualDownloadExtensions = null;
        this.manualDownloadMetadata = null;
        this.manualDownloadMutationJournal = null;
        return true;
      },
      setRestorePending: (pending: boolean): void => { this.localRestorePending = pending; },
      pendingMutationTableRevisions: (): Record<string, number> => this.pendingMutationTableRevisions(),
      acknowledgeMutationJournal: (table: string, revision: number): boolean =>
        this.acknowledgeMutationJournal(table, revision),
      hasRestoredNotUploaded: (): boolean => this.hasRestoredNotUploaded(),
      clearRestoredNotUploaded: (): boolean => this.clearRestoredNotUploaded()
    };
  }

  pendingSyncTableCount(): number {
    return CloudSyncCoordinator.getInstance().pendingTableCount();
  }

  /** 本地备份专用：以稳定列顺序导出七张表，不触发云同步。 */
  exportAllTableRows(): Record<string, Array<Record<string, string>>> {
    const snapshot: Record<string, Array<Record<string, string>>> = {};
    for (let i = 0; i < TABLES.length; i++) {
      const table: string = TABLES[i];
      snapshot[table] = [];
      if (!this.store) { continue; }
      const rows = this.store.querySync(new relationalStore.RdbPredicates(table));
      const columns: string[] = localBackupColumnsForTable(table);
      while (rows.goToNextRow()) {
        const row: Record<string, string> = {};
        for (let c = 0; c < columns.length; c++) {
          const index: number = rows.getColumnIndex(columns[c]);
          if (index >= 0) { row[columns[c]] = rows.getString(index); }
        }
        snapshot[table].push(row);
      }
      rows.close();
      snapshot[table].sort((a: Record<string, string>, b: Record<string, string>): number =>
        (a['id'] || '').localeCompare(b['id'] || ''));
    }
    return snapshot;
  }

  private hasAnyBusinessRows(): boolean {
    if (!this.store) { return false; }
    const tables: string[] = ['remotehosts', 'rdpcredentials', 'rustdeskrelays', 'sshkeys', 'totpentries'];
    for (let i = 0; i < tables.length; i++) {
      try {
        const rows = this.store.querySync(new relationalStore.RdbPredicates(tables[i]));
        const hasRows: boolean = rows.rowCount > 0;
        rows.close();
        if (hasRows) { return true; }
      } catch (_e) {}
    }
    return false;
  }

  exportLocalExtensionRows(): Array<Record<string, string>> {
    const result: Array<Record<string, string>> = [];
    if (!this.store) { return result; }
    try {
      const rows = this.store.querySync(new relationalStore.RdbPredicates('localextensions'));
      const columns: string[] = localBackupLocalExtensionColumns();
      while (rows.goToNextRow()) {
        const row: Record<string, string> = {};
        for (let i = 0; i < columns.length; i++) {
          const index: number = rows.getColumnIndex(columns[i]);
          if (index >= 0) { row[columns[i]] = rows.getString(index); }
        }
        result.push(row);
      }
      rows.close();
      result.sort((a: Record<string, string>, b: Record<string, string>): number =>
        (a['id'] || '').localeCompare(b['id'] || ''));
    } catch (err) {
      hilog.warn(0x0001, 'CloudSync', '[CloudStore] export local extensions failed: ' + safeError(err));
    }
    return result;
  }

  /**
   * Local backup restore.  A successful restore is intentionally quarantined:
   * it cannot pull or upload automatically until the user explicitly chooses a
   * cloud direction, so a valid backup can never be overwritten on startup.
   */
  async replaceAllTableRows(snapshot: Record<string, Array<Record<string, string>>>,
    extensions: Array<Record<string, string>> = []): Promise<boolean> {
    return await this.replaceAllTableRowsInternal(snapshot, extensions, null, null, true, true);
  }

  /** Manual cloud-download rollback restores every local state owner exactly. */
  private async restoreManualDownloadSnapshot(snapshot: Record<string, Array<Record<string, string>>>,
    extensions: Array<Record<string, string>>, metadata: Array<Record<string, string>>,
    journal: Array<Record<string, string>>): Promise<boolean> {
    return await this.replaceAllTableRowsInternal(snapshot, extensions, metadata, journal, false, false);
  }

  private async replaceAllTableRowsInternal(snapshot: Record<string, Array<Record<string, string>>>,
    extensions: Array<Record<string, string>>, metadata: Array<Record<string, string>> | null,
    journal: Array<Record<string, string>> | null, markRestoredNotUploaded: boolean,
    publishReload: boolean): Promise<boolean> {
    if (!this.store || !validateLocalBackupSnapshot(snapshot, extensions)) { return false; }
    if (metadata !== null && !this.deviceLocalRowsValid(metadata, LOCAL_METADATA_COLUMNS, 'key')) { return false; }
    if (journal !== null && !this.deviceLocalRowsValid(journal, LOCAL_MUTATION_JOURNAL_COLUMNS, 'id')) {
      return false;
    }
    this.setAutomaticPushSuppressed(true);
    this.localRestoreActive = true;
    try {
      this.store.beginTransaction();
      for (let i = 0; i < TABLES.length; i++) {
        const table: string = TABLES[i];
        await this.store.executeSql('DELETE FROM ' + table);
        const rows: Array<Record<string, string>> = snapshot[table];
        for (let r = 0; r < rows.length; r++) {
          const bucket: relationalStore.ValuesBucket = {};
          const keys: string[] = Object.keys(rows[r]);
          const allowed: string[] = localBackupColumnsForTable(table);
          for (let k = 0; k < keys.length; k++) {
            if (allowed.indexOf(keys[k]) < 0) { throw new Error('restore unknown column table=' + table); }
            bucket[keys[k]] = rows[r][keys[k]];
          }
          if (!rdbInsertSucceeded(this.store.insertSync(table, bucket,
            relationalStore.ConflictResolution.ON_CONFLICT_REPLACE))) {
            throw new Error('restore insert failed table=' + table);
          }
        }
      }
      if (!(await this.restoreDeviceLocalRows('localextensions', localBackupLocalExtensionColumns(), extensions))) {
        throw new Error('restore local extensions failed');
      }
      if (metadata !== null && !(await this.restoreDeviceLocalRows(
        LOCAL_METADATA_TABLE, LOCAL_METADATA_COLUMNS, metadata))) {
        throw new Error('restore local metadata failed');
      }
      if (journal !== null) {
        if (!(await this.restoreDeviceLocalRows(
          LOCAL_MUTATION_JOURNAL_TABLE, LOCAL_MUTATION_JOURNAL_COLUMNS, journal))) {
          throw new Error('restore mutation journal failed');
        }
      } else if (!this.clearMutationJournal()) {
        throw new Error('clear mutation journal failed');
      }
      if (markRestoredNotUploaded && !this.writeLocalMetadata(RESTORED_NOT_UPLOADED_KEY, '1')) {
        throw new Error('set restored upload marker failed');
      }
      this.store.commit();
      this.localRestoreActive = false;
      if (publishReload) {
        // A restored crypto parameter set can belong to another password. Do
        // not retain any previous decrypted cache, and publish one snapshot.
        this.lastKnownCryptoStatus = this.getCryptoStatus();
        const changedCryptoState: boolean = DataCrypto.getInstance().lock();
        if (!changedCryptoState) { this.notifyDataSnapshotChanged(); }
      }
      return true;
    } catch (err) {
      try { this.store.rollBack(); } catch (_ignored) {}
      hilog.error(0x0001, 'CloudSync', '[CloudStore] atomic restore failed: ' + safeError(err));
      return false;
    } finally {
      this.localRestoreActive = false;
      this.setAutomaticPushSuppressed(false);
    }
  }

  /** Coordinator-only adapter for the Huawei one-table cloudSync API. */
  private executeSyncTable(table: string, direction: CloudSyncDirection, label: string): Promise<boolean> {
    return this.syncTableAsync(table, direction, label);
  }

  private notifyCloudDataApplied(tables: string[]): void {
    this.suppressCryptoStateSnapshot = true;
    let resetClearPending: boolean = false;
    try {
      resetClearPending = this.checkCryptoStatusChange(tables.indexOf('cryptoparams') >= 0);
      if (!resetClearPending && tables.indexOf('usersettings') >= 0) {
        this.applyCloudUserSettingsToRuntime();
      }
    } finally {
      this.suppressCryptoStateSnapshot = false;
    }
    // A reset clears data asynchronously. Its completion publishes the first
    // valid empty snapshot; publishing here would expose stale rows first.
    if (!resetClearPending) { this.notifyDataSnapshotChanged(); }
  }

  private applyCloudUserSettingsToRuntime(): void {
    if (!this.appContext) { return; }
    const settings: Record<string, CloudUserSettingValue> = this.loadUserSettings();
    const keys: string[] = Object.keys(settings);
    if (keys.length === 0) { return; }
    let applyVirtualMouseStyle: boolean = false;
    try {
      const prefs = preferences.getPreferencesSync(this.appContext, { name: 'RemoteDesktopAppPrefs' });
      const restoreVersion: number = prefs.getSync(VIRTUAL_MOUSE_STYLE_RESTORE_VERSION_KEY, 0) as number;
      applyVirtualMouseStyle = shouldApplyCloudVirtualMouseStyle(restoreVersion);
      for (let i = 0; i < keys.length; i++) {
        const key: string = keys[i];
        if (!cloudUserSettingIsSyncable(key)) { continue; }
        if (key === 'virtualMouseStyle' && !applyVirtualMouseStyle) { continue; }
        prefs.putSync(key, settings[key]);
        AppStorage.setOrCreate(key, settings[key]);
      }
      prefs.flushSync();
    } catch (err) {
      hilog.warn(0x0001, 'CloudSync', '[CloudStore] apply cloud settings failed: ' + safeError(err));
    }
  }

  private syncTableAsync(table: string, direction: CloudSyncDirection, label: string): Promise<boolean> {
    return new Promise<boolean>((resolve) => {
      if (!this.store || !this.cloudAvailable) { resolve(false); return; }
      const mode: relationalStore.SyncMode = direction === 'cloudFirst'
        ? relationalStore.SyncMode.SYNC_MODE_CLOUD_FIRST
        : relationalStore.SyncMode.SYNC_MODE_NATIVE_FIRST;
      let settled: boolean = false;
      const recordFailure = (message: string): void => {
        if (settled) { return; }
        settled = true;
        this.lastSyncTime = Date.now();
        this.syncFailCount++;
        this.lastError = label + ' ' + table + ': ' + message;
        if (this.tableStatus[table]) { this.tableStatus[table].fail++; }
        hilog.error(0x0001, 'CloudSync', this.lastError);
        resolve(false);
      };
      const recordSuccess = (): void => {
        if (settled) { return; }
        settled = true;
        this.lastSyncTime = Date.now();
        this.syncSuccessCount++;
        this.cloudServiceGuidanceNeeded = false;
        if (this.tableStatus[table]) {
          this.tableStatus[table].ok++;
          this.tableStatus[table].last = Date.now();
        }
        hilog.info(0x0001, 'CloudSync', label + ' transfer complete table=' + table);
        resolve(true);
      };
      this.store.cloudSync(mode, [table],
        (progress: relationalStore.ProgressDetails): void => {
          const schedule: number = progress.schedule as number;
          const code: number = progress.code as number;
          hilog.info(0x0001, 'CloudSync', label + ' progress table=' + table +
            ' schedule=' + schedule.toString() + ' code=' + code.toString());
          if (!cloudSyncProgressFinished(schedule)) { return; }
          if (cloudSyncProgressSucceeded(schedule, code)) {
            recordSuccess();
          } else {
            recordFailure('progressCode=' + code.toString());
          }
        },
        (err: BusinessError | undefined): void => {
          if (err) {
            this.cloudServiceGuidanceNeeded = this.cloudServiceGuidanceNeeded || this.errorRequiresCloudServiceGuidance(err);
            recordFailure('code=' + err.code.toString() + ' msg=' + err.message);
            return;
          }
          // On this device the completion callback confirms that the task was
          // accepted, while Progress.SYNC_FINISH arrives after the real transfer.
          hilog.info(0x0001, 'CloudSync', label + ' accepted table=' + table);
        }
      );
    });
  }

  /** 建表 (列名无下划线, 符合 AGC 限制) */
  private async createTables(): Promise<void> {
    if (!this.store) { return; }
    await this.store.executeSql(`
      CREATE TABLE IF NOT EXISTS remotehosts (
        id TEXT PRIMARY KEY,
        userid TEXT,
        label TEXT,
        protocol TEXT,
        host TEXT,
        port INTEGER,
        username TEXT,
        password TEXT,
        passward TEXT,
        customhostname TEXT,
        sshusekey INTEGER,
        sshkeypath TEXT,
        sshkeydata TEXT,
        sshkeypassphrase TEXT,
        sshkeyid TEXT,
        sshhostkeyalgorithm TEXT,
        sshhostkeyfingerprintsha256 TEXT,
        sshhostkeyrawbase64 TEXT,
        sshhostkeytrustedat INTEGER,
        sshhostkeytrustmode INTEGER,
        rdpcertificatefingerprintsha256 TEXT,
        rdpcertificatesubject TEXT,
        rdpcertificateissuer TEXT,
        rdpcertificatecommonname TEXT,
        rdpcertificatetrustedat INTEGER,
        rdpcertificatetrustmode INTEGER,
        rdpcertificateallowuntrustedroot INTEGER,
        rdpcertificateallowhostmismatch INTEGER,
        proxyhost TEXT,
        proxyport INTEGER,
        proxyusername TEXT,
        gatewayhost TEXT,
        gatewayport INTEGER,
        displayconfig TEXT,
        locked INTEGER,
        locktype INTEGER,
        isfavorite INTEGER,
        groupid TEXT,
        sortorder INTEGER,
        icon TEXT,
        lastconnected INTEGER,
        lasthealth INTEGER,
        lastlatency INTEGER,
        syncversion INTEGER,
        rustdeskrelayid TEXT,
        rustdeskaccountid TEXT,
        rustdeskpasswordmode INTEGER,
        rustdeskauthmode TEXT,
        rustdeskdirectenabled INTEGER,
        rustdeskdirecthost TEXT,
        rustdeskdirectport INTEGER,
        rdpcredentialid TEXT,
        sourcetype TEXT,
        rustdeskproaccountid TEXT,
        rustdeskpropeerid TEXT,
        rustdeskproplatform TEXT,
        rustdeskpromanaged INTEGER,
        rustdeskprolastseenat INTEGER,
        rustdeskprosyncerror TEXT,
        createdat INTEGER,
        updatedat INTEGER
      )
    `);
    // 迁移: 为已存在的 remotehosts 表添加 sshkeypassphrase 列 (2026-06-23)
    try {
      await this.store.executeSql(
        `ALTER TABLE remotehosts ADD COLUMN sshkeypassphrase TEXT`
      );
    } catch (e) {
      // 列已存在则忽略
    }
    try {
      await this.store.executeSql(
        `ALTER TABLE remotehosts ADD COLUMN sshkeyid TEXT`
      );
    } catch (e) {
      // 列已存在则忽略
    }
    // 迁移: T-210 SSH host key trust 字段 (2026-06-23)
    const hostKeyCols: string[] = [
      'sshhostkeyalgorithm TEXT',
      'sshhostkeyfingerprintsha256 TEXT',
      'sshhostkeyrawbase64 TEXT',
      'sshhostkeytrustedat INTEGER',
      'sshhostkeytrustmode INTEGER',
      'rdpcertificatefingerprintsha256 TEXT',
      'rdpcertificatesubject TEXT',
      'rdpcertificateissuer TEXT',
      'rdpcertificatecommonname TEXT',
      'rdpcertificatetrustedat INTEGER',
      'rdpcertificatetrustmode INTEGER',
      'rdpcertificateallowuntrustedroot INTEGER',
      'rdpcertificateallowhostmismatch INTEGER'
    ];
    for (const colDef of hostKeyCols) {
      try {
        await this.store.executeSql(`ALTER TABLE remotehosts ADD COLUMN ${colDef}`);
      } catch (_e) {
        // 列已存在则忽略
      }
    }
    await this.store.executeSql(`
      CREATE TABLE IF NOT EXISTS rdpcredentials (
        id TEXT PRIMARY KEY,
        label TEXT,
        username TEXT,
        password TEXT,
        createdat INTEGER,
        updatedat INTEGER
      )
    `);
    await this.store.executeSql(`
      CREATE TABLE IF NOT EXISTS sshkeys (
        id TEXT PRIMARY KEY,
        userid TEXT,
        label TEXT,
        keytype INTEGER,
        publickey TEXT,
        privatekey TEXT,
        fingerprint TEXT,
        comment TEXT,
        locked INTEGER,
        locktype INTEGER,
        syncversion INTEGER,
        createdat INTEGER,
        updatedat INTEGER,
        formatversion INTEGER,
        privatekeyencrypted INTEGER
      )
    `);
    // 迁移: 旧安装缺少 formatversion / privatekeyencrypted 列
    try { await this.store.executeSql(`ALTER TABLE sshkeys ADD COLUMN formatversion INTEGER`); } catch (e) {}
    try { await this.store.executeSql(`ALTER TABLE sshkeys ADD COLUMN privatekeyencrypted INTEGER`); } catch (e) {}
    await this.store.executeSql(`
      CREATE TABLE IF NOT EXISTS totpentries (
        id TEXT PRIMARY KEY,
        userid TEXT,
        issuer TEXT,
        account TEXT,
        secret TEXT,
        algorithm INTEGER,
        digits INTEGER,
        period INTEGER,
        iconurl TEXT,
        locked INTEGER,
        locktype INTEGER,
        syncversion INTEGER,
        createdat INTEGER,
        updatedat INTEGER
      )
    `);
    // 密码学参数表 (盐值+验证器, 云同步以实现跨设备解密)
    await this.store.executeSql(`
      CREATE TABLE IF NOT EXISTS cryptoparams (
        id TEXT PRIMARY KEY,
        key TEXT,
        value TEXT
      )
    `);
    await this.store.executeSql(`
      CREATE TABLE IF NOT EXISTS usersettings (
        id TEXT PRIMARY KEY,
        userid TEXT,
        key TEXT,
        value TEXT,
        payload TEXT,
        schemaversion INTEGER,
        updatedat INTEGER
      )
    `);
    try { await this.store.executeSql('ALTER TABLE remotehosts ADD COLUMN passward TEXT'); } catch (_e) {}
    try { await this.store.executeSql('ALTER TABLE usersettings ADD COLUMN payload TEXT'); } catch (_e) {}
    try { await this.store.executeSql('ALTER TABLE usersettings ADD COLUMN schemaversion INTEGER'); } catch (_e) {}
    // RustDesk 中继服务器配置表 (本地缓存, 云同步通过 cryptoparams)
    await this.store.executeSql(`
      CREATE TABLE IF NOT EXISTS rustdeskrelays (
        id TEXT PRIMARY KEY,
        userid TEXT,
        idserver TEXT,
        idserverport INTEGER,
        relayserver TEXT,
        relayport INTEGER,
        apiserver TEXT,
        apiusername TEXT,
        apipassword TEXT,
        key TEXT,
        healthstatus TEXT,
        healthlatency INTEGER,
        healthcheckedat INTEGER,
        apiloginstatus TEXT,
        accountsjson TEXT,
        syncversion INTEGER,
        createdat INTEGER,
        updatedat INTEGER
      )
    `);
    try {
      await this.store.executeSql('ALTER TABLE rustdeskrelays ADD COLUMN accountsjson TEXT');
    } catch (_e) {
      // 旧库已迁移时会报重复列名, 忽略即可。
    }
    try {
      await this.store.executeSql('ALTER TABLE rustdeskrelays ADD COLUMN updatedat INTEGER');
    } catch (_e) {
      // 旧库已迁移时会报重复列名, 忽略即可。
    }
    try {
      await this.store.executeSql('ALTER TABLE remotehosts ADD COLUMN rustdeskrelayid TEXT');
    } catch (_e) {
      // 旧库已迁移时会报重复列名, 忽略即可。
    }
    try {
      await this.store.executeSql('ALTER TABLE remotehosts ADD COLUMN rustdeskaccountid TEXT');
    } catch (_e) {
      // 旧库已迁移时会报重复列名, 忽略即可。
    }
    try {
      await this.store.executeSql('ALTER TABLE remotehosts ADD COLUMN rustdeskpasswordmode INTEGER');
    } catch (_e) {
      // 旧库已迁移时会报重复列名, 忽略即可。
    }
    // 迁移: RustDesk 直连字段 (2026-06-23 引入, 旧库/新库都必须与 hostToBucket 对齐)
    const rustDeskDirectCols: string[] = [
      'rustdeskdirectenabled INTEGER',
      'rustdeskdirecthost TEXT',
      'rustdeskdirectport INTEGER'
    ];
    for (const colDef of rustDeskDirectCols) {
      try {
        await this.store.executeSql(`ALTER TABLE remotehosts ADD COLUMN ${colDef}`);
      } catch (_e) {
        // 列已存在则忽略
      }
    }
    try {
      await this.store.executeSql('ALTER TABLE remotehosts ADD COLUMN rdpcredentialid TEXT');
    } catch (_e) {
      // 旧库已迁移时会报重复列名, 忽略即可。
    }
    try {
      await this.store.executeSql('ALTER TABLE remotehosts ADD COLUMN rustdeskauthmode TEXT');
    } catch (_e) {
      // 旧库已迁移时会报重复列名, 忽略即可。
    }
    const rustDeskProCols: string[] = [
      'sourcetype TEXT',
      'rustdeskproaccountid TEXT',
      'rustdeskpropeerid TEXT',
      'rustdeskproplatform TEXT',
      'rustdeskpromanaged INTEGER',
      'rustdeskprolastseenat INTEGER',
      'rustdeskprosyncerror TEXT'
    ];
    for (const colDef of rustDeskProCols) {
      try {
        await this.store.executeSql(`ALTER TABLE remotehosts ADD COLUMN ${colDef}`);
      } catch (_e) {
        // 列已存在则忽略
      }
    }
    // 本地扩展表不参与 setDistributedTables；它保存云表没有的字段。
    await this.store.executeSql(`
      CREATE TABLE IF NOT EXISTS localextensions (
        id TEXT PRIMARY KEY,
        tablename TEXT,
        recordid TEXT,
        payload TEXT,
        updatedat INTEGER
      )
    `);
    // Device-local recovery state. These tables are never registered as cloud
    // tables, so the existing Huawei schema remains unchanged.
    await this.store.executeSql(`
      CREATE TABLE IF NOT EXISTS localmetadata (
        key TEXT PRIMARY KEY,
        value TEXT,
        updatedat INTEGER
      )
    `);
    await this.store.executeSql(`
      CREATE TABLE IF NOT EXISTS localmutationjournal (
        id TEXT PRIMARY KEY,
        tablename TEXT,
        recordid TEXT,
        operation TEXT,
        revision INTEGER,
        createdat INTEGER,
        updatedat INTEGER
      )
    `);
  }

  getRdbStore(): relationalStore.RdbStore | null {
    return this.store;
  }

  isReady(): boolean {
    return this.initialized && this.store !== null;
  }

  async syncAllToCloud(): Promise<boolean> {
    return await this.uploadAllToCloud();
  }

  isCloudAvailable(): boolean {
    return this.initialized && this.store !== null && this.cloudAvailable;
  }

  /** Show the Huawei Cloud Space guidance after registration or explicit sync reports an unavailable service. */
  requiresCloudServiceGuidance(): boolean {
    return this.cloudServiceGuidanceNeeded;
  }

  private errorRequiresCloudServiceGuidance(error: BusinessError): boolean {
    return cloudServiceGuidanceRequiredForMessage(error.message);
  }

  private localExtensionId(table: string, recordId: string): string {
    return table + ':' + recordId;
  }

  private setLastMutation(result: DataMutationResult): boolean {
    this.lastMutationResult = result;
    return result.ok;
  }

  private nextMutationRevision(): number {
    const now: number = Date.now();
    this.lastMutationRevision = now > this.lastMutationRevision ? now : this.lastMutationRevision + 1;
    return this.lastMutationRevision;
  }

  private sensitiveWriteAllowed(recordId: string): boolean {
    const crypto: DataCrypto = DataCrypto.getInstance();
    if (!sensitiveWriteRequiresUnlock(crypto.isSetupComplete(), crypto.isReady())) { return true; }
    return this.setLastMutation(DataMutationResult.failure(recordId, 'unlock_required',
      '加密数据已锁定，请先解锁后再保存'));
  }

  private readLocalMetadata(key: string): string {
    if (!this.store || key === '') { return ''; }
    try {
      const predicates = new relationalStore.RdbPredicates(LOCAL_METADATA_TABLE);
      predicates.equalTo('key', key);
      const rows = this.store.querySync(predicates);
      const value: string = rows.goToFirstRow() ? rows.getString(rows.getColumnIndex('value')) : '';
      rows.close();
      return value;
    } catch (_e) { return ''; }
  }

  private writeLocalMetadata(key: string, value: string): boolean {
    if (!this.store || key === '') { return false; }
    try {
      const bucket: relationalStore.ValuesBucket = { key, value, updatedat: Date.now() };
      return rdbInsertSucceeded(this.store.insertSync(LOCAL_METADATA_TABLE, bucket,
        relationalStore.ConflictResolution.ON_CONFLICT_REPLACE));
    } catch (_e) { return false; }
  }

  private deleteLocalMetadata(key: string): boolean {
    if (!this.store || key === '') { return false; }
    try {
      const predicates = new relationalStore.RdbPredicates(LOCAL_METADATA_TABLE);
      predicates.equalTo('key', key);
      this.store.deleteSync(predicates);
      return true;
    } catch (_e) { return false; }
  }

  private recordLocalMutation(table: string, recordId: string, operation: string): boolean {
    if (!this.store || table === '' || recordId === '') { return false; }
    try {
      const now: number = Date.now();
      const bucket: relationalStore.ValuesBucket = {
        id: this.localExtensionId(table, recordId),
        tablename: table,
        recordid: recordId,
        operation,
        revision: this.nextMutationRevision(),
        createdat: now,
        updatedat: now
      };
      return rdbInsertSucceeded(this.store.insertSync(LOCAL_MUTATION_JOURNAL_TABLE, bucket,
        relationalStore.ConflictResolution.ON_CONFLICT_REPLACE));
    } catch (_e) { return false; }
  }

  /** A bulk transition still needs a durable table-level upload intention. */
  private recordTableMutation(table: string, operation: string): boolean {
    return this.recordLocalMutation(table, TABLE_MUTATION_RECORD_ID, operation);
  }

  /** Durable restart recovery input for CloudSyncCoordinator. */
  pendingMutationTableRevisions(): Record<string, number> {
    const result: Record<string, number> = {};
    if (!this.store) { return result; }
    try {
      const rows = this.store.querySync(new relationalStore.RdbPredicates(LOCAL_MUTATION_JOURNAL_TABLE));
      while (rows.goToNextRow()) {
        const table: string = rows.getString(rows.getColumnIndex('tablename'));
        const revision: number = rows.getLong(rows.getColumnIndex('revision'));
        if (table !== '' && revision > (result[table] || 0)) { result[table] = revision; }
      }
      rows.close();
    } catch (_e) { /* leave empty; legacy Preferences dirty state still recovers uploads */ }
    return result;
  }

  private exportDeviceLocalRows(table: string, columns: string[]): Array<Record<string, string>> {
    const result: Array<Record<string, string>> = [];
    if (!this.store) { return result; }
    try {
      const rows = this.store.querySync(new relationalStore.RdbPredicates(table));
      while (rows.goToNextRow()) {
        const row: Record<string, string> = {};
        for (let i = 0; i < columns.length; i++) {
          const index: number = rows.getColumnIndex(columns[i]);
          if (index >= 0) { row[columns[i]] = rows.getString(index); }
        }
        result.push(row);
      }
      rows.close();
      result.sort((left: Record<string, string>, right: Record<string, string>): number =>
        (left['id'] || left['key'] || '').localeCompare(right['id'] || right['key'] || ''));
    } catch (err) {
      hilog.warn(0x0001, 'CloudSync', '[CloudStore] export local state failed table=' + table +
        ' err=' + safeError(err));
    }
    return result;
  }

  private exportLocalMetadataRows(): Array<Record<string, string>> {
    return this.exportDeviceLocalRows(LOCAL_METADATA_TABLE, LOCAL_METADATA_COLUMNS);
  }

  private exportMutationJournalRows(): Array<Record<string, string>> {
    return this.exportDeviceLocalRows(LOCAL_MUTATION_JOURNAL_TABLE, LOCAL_MUTATION_JOURNAL_COLUMNS);
  }

  private deviceLocalRowsValid(rows: Array<Record<string, string>>, columns: string[], idColumn: string): boolean {
    const ids: Set<string> = new Set<string>();
    for (let i = 0; i < rows.length; i++) {
      const row: Record<string, string> = rows[i];
      const id: string = row[idColumn] || '';
      if (id === '' || ids.has(id)) { return false; }
      const keys: string[] = Object.keys(row);
      for (let k = 0; k < keys.length; k++) {
        if (columns.indexOf(keys[k]) < 0 || typeof row[keys[k]] !== 'string') { return false; }
      }
      ids.add(id);
    }
    return true;
  }

  private async restoreDeviceLocalRows(table: string, columns: string[],
    rows: Array<Record<string, string>>): Promise<boolean> {
    if (!this.store) { return false; }
    try {
      await this.store.executeSql('DELETE FROM ' + table);
      for (let i = 0; i < rows.length; i++) {
        const bucket: relationalStore.ValuesBucket = {};
        const keys: string[] = Object.keys(rows[i]);
        for (let k = 0; k < keys.length; k++) {
          if (columns.indexOf(keys[k]) < 0) { return false; }
          bucket[keys[k]] = rows[i][keys[k]];
        }
        if (!rdbInsertSucceeded(this.store.insertSync(table, bucket,
          relationalStore.ConflictResolution.ON_CONFLICT_REPLACE))) { return false; }
      }
      return true;
    } catch (_e) { return false; }
  }

  /** Remove only entries known to be covered by a terminal successful upload. */
  acknowledgeMutationJournal(table: string, coveredRevision: number): boolean {
    if (!this.store || table === '' || coveredRevision <= 0) { return false; }
    try {
      const candidates: string[] = [];
      const predicates = new relationalStore.RdbPredicates(LOCAL_MUTATION_JOURNAL_TABLE);
      predicates.equalTo('tablename', table);
      const rows = this.store.querySync(predicates);
      while (rows.goToNextRow()) {
        const revision: number = rows.getLong(rows.getColumnIndex('revision'));
        if (revision <= coveredRevision) { candidates.push(rows.getString(rows.getColumnIndex('id'))); }
      }
      rows.close();
      if (candidates.length === 0) { return true; }
      this.store.beginTransaction();
      for (let i = 0; i < candidates.length; i++) {
        const one = new relationalStore.RdbPredicates(LOCAL_MUTATION_JOURNAL_TABLE);
        one.equalTo('id', candidates[i]);
        this.store.deleteSync(one);
      }
      this.store.commit();
      return true;
    } catch (_e) {
      try { this.store.rollBack(); } catch (_ignored) {}
      return false;
    }
  }

  /** An explicit cloud-first download intentionally discards local dirty intent. */
  discardMutationJournalForTables(tables: string[]): boolean {
    if (!this.store) { return false; }
    const distinctTables: string[] = [];
    for (let i = 0; i < tables.length; i++) {
      if (tables[i] !== '' && distinctTables.indexOf(tables[i]) < 0) { distinctTables.push(tables[i]); }
    }
    if (distinctTables.length === 0) { return true; }
    try {
      this.store.beginTransaction();
      for (let i = 0; i < distinctTables.length; i++) {
        const predicates = new relationalStore.RdbPredicates(LOCAL_MUTATION_JOURNAL_TABLE);
        predicates.equalTo('tablename', distinctTables[i]);
        this.store.deleteSync(predicates);
      }
      this.store.commit();
      return true;
    } catch (_e) {
      try { this.store.rollBack(); } catch (_ignored) {}
      return false;
    }
  }

  private clearMutationJournal(): boolean {
    if (!this.store) { return false; }
    try {
      this.store.deleteSync(new relationalStore.RdbPredicates(LOCAL_MUTATION_JOURNAL_TABLE));
      return true;
    } catch (_e) { return false; }
  }

  hasRestoredNotUploaded(): boolean {
    return this.readLocalMetadata(RESTORED_NOT_UPLOADED_KEY) === '1';
  }

  clearRestoredNotUploaded(): boolean {
    return this.deleteLocalMetadata(RESTORED_NOT_UPLOADED_KEY);
  }

  private cloudBucket(table: string, source: relationalStore.ValuesBucket): relationalStore.ValuesBucket {
    const result: relationalStore.ValuesBucket = {};
    const columns: string[] = cloudTableColumns(table);
    for (let i = 0; i < columns.length; i++) {
      const column: string = columns[i];
      if (source[column] !== undefined) { result[column] = source[column]; }
    }
    return result;
  }

  /** Most recent local persistence result, intentionally never contains secret material. */
  getLastMutationResult(): DataMutationResult {
    const result = new DataMutationResult();
    result.ok = this.lastMutationResult.ok;
    result.code = this.lastMutationResult.code;
    result.recordId = this.lastMutationResult.recordId;
    result.message = this.lastMutationResult.message;
    return result;
  }

  private rdpRestrictedAdminSecretBinding(host: RemoteHost): string {
    return [
      'rdp',
      host.host.trim().toLowerCase(),
      host.port.toString(),
      host.username.trim().toLowerCase(),
      normalizeRdpRestrictedAdminSecretSource(host.rdpRestrictedAdminSecretSource)
    ].join('|');
  }

  /** Stores a user-provided NTLM hash on this device only. */
  saveRdpRestrictedAdminHash(host: RemoteHost, rawHash: string): boolean {
    const mode: RdpAuthMode = normalizeRdpAuthMode(host.rdpAuthMode);
    const source: RdpRestrictedAdminSecretSource = normalizeRdpRestrictedAdminSecretSource(
      host.rdpRestrictedAdminSecretSource);
    const hash: string = normalizeRdpNtlmHash(rawHash);
    if (host.id === '' || host.protocol !== 'rdp' || mode !== 'restricted_admin' ||
      source !== 'ntlm_hash' || hash === '') {
      return false;
    }
    const crypto: DataCrypto = DataCrypto.getInstance();
    if (!crypto.isReady()) { return false; }
    try {
      return this.saveLocalExtension(RDP_RESTRICTED_ADMIN_SECRET_TABLE, host.id, {
        'hash': crypto.encrypt(hash),
        'binding': crypto.encrypt(this.rdpRestrictedAdminSecretBinding(host))
      });
    } catch (err) {
      hilog.warn(0x0001, 'CloudSync', '[CloudStore] save RDP restricted admin secret failed: ' + safeError(err));
      return false;
    }
  }

  clearRdpRestrictedAdminHash(hostId: string): boolean {
    return this.deleteLocalExtension(RDP_RESTRICTED_ADMIN_SECRET_TABLE, hostId);
  }

  /** Loads a locally encrypted NTLM hash and rejects stale, plaintext, or locked secrets. */
  loadRdpRestrictedAdminHash(host: RemoteHost): RdpRestrictedAdminSecretResult {
    const result = new RdpRestrictedAdminSecretResult();
    const mode: RdpAuthMode = normalizeRdpAuthMode(host.rdpAuthMode);
    const source: RdpRestrictedAdminSecretSource = normalizeRdpRestrictedAdminSecretSource(
      host.rdpRestrictedAdminSecretSource);
    if (host.protocol !== 'rdp' || mode !== 'restricted_admin') {
      result.status = 'not_applicable';
      return result;
    }
    if (source === 'empty_password_hash') {
      result.status = 'not_required';
      return result;
    }
    const crypto: DataCrypto = DataCrypto.getInstance();
    if (!crypto.isReady()) {
      result.status = 'crypto_locked';
      return result;
    }
    const values: Record<string, string> = this.loadLocalExtension(RDP_RESTRICTED_ADMIN_SECRET_TABLE, host.id);
    const encryptedHash: string = values['hash'] || '';
    const encryptedBinding: string = values['binding'] || '';
    if (encryptedHash === '' || encryptedBinding === '') { return result; }
    if (!crypto.isEncrypted(encryptedHash) || !crypto.isEncrypted(encryptedBinding)) {
      this.clearRdpRestrictedAdminHash(host.id);
      result.status = 'invalid';
      return result;
    }
    try {
      const binding: string = crypto.decrypt(encryptedBinding);
      const hash: string = normalizeRdpNtlmHash(crypto.decrypt(encryptedHash));
      if (binding !== this.rdpRestrictedAdminSecretBinding(host)) {
        this.clearRdpRestrictedAdminHash(host.id);
        result.status = 'binding_mismatch';
        return result;
      }
      if (hash === '') {
        this.clearRdpRestrictedAdminHash(host.id);
        result.status = 'invalid';
        return result;
      }
      result.status = 'ready';
      result.hash = hash;
      return result;
    } catch (err) {
      hilog.warn(0x0001, 'CloudSync', '[CloudStore] load RDP restricted admin secret failed: ' + safeError(err));
      result.status = 'invalid';
      return result;
    }
  }

  private saveLocalExtension(table: string, recordId: string, values: Record<string, string>): boolean {
    if (!this.store || recordId === '') { return false; }
    try {
      const bucket: relationalStore.ValuesBucket = {
        id: this.localExtensionId(table, recordId),
        tablename: table,
        recordid: recordId,
        payload: JSON.stringify(values),
        updatedat: Date.now()
      };
      return rdbInsertSucceeded(this.store.insertSync('localextensions', bucket,
        relationalStore.ConflictResolution.ON_CONFLICT_REPLACE));
    } catch (err) {
      hilog.error(0x0001, 'CloudSync', '[CloudStore] save local extension failed: ' + safeError(err));
      return false;
    }
  }

  private loadLocalExtension(table: string, recordId: string): Record<string, string> {
    const result: Record<string, string> = {};
    if (!this.store || recordId === '') { return result; }
    try {
      const predicates = new relationalStore.RdbPredicates('localextensions');
      predicates.equalTo('id', this.localExtensionId(table, recordId));
      const rows = this.store.querySync(predicates);
      if (rows.goToNextRow()) {
        const payload: string = rows.getString(rows.getColumnIndex('payload'));
        const parsed = JSON.parse(payload) as Record<string, string>;
        const keys: string[] = Object.keys(parsed);
        for (let i = 0; i < keys.length; i++) { result[keys[i]] = parsed[keys[i]]; }
      }
      rows.close();
    } catch (err) {
      hilog.warn(0x0001, 'CloudSync', '[CloudStore] load local extension failed: ' + safeError(err));
    }
    return result;
  }

  private deleteLocalExtension(table: string, recordId: string): boolean {
    if (!this.store || recordId === '') { return false; }
    try {
      const predicates = new relationalStore.RdbPredicates('localextensions');
      predicates.equalTo('id', this.localExtensionId(table, recordId));
      this.store.deleteSync(predicates);
      return true;
    } catch (err) {
      hilog.warn(0x0001, 'CloudSync', '[CloudStore] delete local extension failed: ' + safeError(err));
      return false;
    }
  }

  private hostExtensionFromResult(rs: relationalStore.ResultSet): Record<string, string> {
    const result: Record<string, string> = {};
    const columns: string[] = [
      'sshkeypassphrase', 'sshkeyid', 'sshhostkeyalgorithm',
      'sshhostkeyfingerprintsha256', 'sshhostkeyrawbase64', 'sshhostkeytrustedat',
      'sshhostkeytrustmode', 'rdpcertificatefingerprintsha256', 'rdpcertificatesubject',
      'rdpcertificateissuer', 'rdpcertificatecommonname', 'rdpcertificatetrustedat',
      'rdpcertificatetrustmode', 'rdpcertificateallowuntrustedroot',
      'rdpcertificateallowhostmismatch', 'rustdeskrelayid', 'rustdeskaccountid',
      'rustdeskpasswordmode', 'rustdeskauthmode', 'rustdeskdirectenabled',
      'rustdeskdirecthost', 'rustdeskdirectport', 'rdpcredentialid', 'rdpauthmode',
      'rdprestrictedadminsecretsource', 'sourcetype',
      'rustdeskproaccountid', 'rustdeskpropeerid', 'rustdeskproplatform',
      'rustdeskpromanaged', 'rustdeskprolastseenat', 'rustdeskprosyncerror'
    ];
    for (let i = 0; i < columns.length; i++) {
      const index: number = rs.getColumnIndex(columns[i]);
      if (index >= 0) { result[columns[i]] = rs.getString(index); }
    }
    return result;
  }

  private mergeHostExtension(host: RemoteHost): RemoteHost {
    const values: Record<string, string> = this.loadLocalExtension('remotehosts', host.id);
    const get = (key: string, fallback: string): string => values[key] !== undefined ? values[key] : fallback;
    const crypto: DataCrypto = DataCrypto.getInstance();
    host.sshKeyPassphrase = this.decryptIfReady(crypto, get('sshkeypassphrase', host.sshKeyPassphrase));
    return host;
  }

  /** Apply only the portable extension decoded from the cloud row. Never persist from a decoder. */
  private applyCloudHostExtension(host: RemoteHost, values: Record<string, string>): RemoteHost {
    const get = (key: string, fallback: string): string => values[key] !== undefined ? values[key] : fallback;
    host.sshKeyId = get('sshkeyid', host.sshKeyId);
    host.sshHostKeyAlgorithm = get('sshhostkeyalgorithm', host.sshHostKeyAlgorithm);
    host.sshHostKeyFingerprintSha256 = get('sshhostkeyfingerprintsha256', host.sshHostKeyFingerprintSha256);
    host.sshHostKeyRawBase64 = get('sshhostkeyrawbase64', host.sshHostKeyRawBase64);
    host.rdpCertificateFingerprintSha256 = get('rdpcertificatefingerprintsha256', host.rdpCertificateFingerprintSha256);
    host.rdpCertificateSubject = get('rdpcertificatesubject', host.rdpCertificateSubject);
    host.rdpCertificateIssuer = get('rdpcertificateissuer', host.rdpCertificateIssuer);
    host.rdpCertificateCommonName = get('rdpcertificatecommonname', host.rdpCertificateCommonName);
    host.rustdeskRelayId = get('rustdeskrelayid', host.rustdeskRelayId);
    host.rustdeskAccountId = get('rustdeskaccountid', host.rustdeskAccountId);
    host.rustdeskDirectHost = get('rustdeskdirecthost', host.rustdeskDirectHost);
    host.rdpCredentialId = get('rdpcredentialid', host.rdpCredentialId);
    host.rdpAuthMode = normalizeRdpAuthMode(get('rdpauthmode', host.rdpAuthMode));
    host.rdpRestrictedAdminSecretSource = normalizeRdpRestrictedAdminSecretSource(
      get('rdprestrictedadminsecretsource', host.rdpRestrictedAdminSecretSource));
    host.sshHostKeyTrustedAt = Number(get('sshhostkeytrustedat', host.sshHostKeyTrustedAt.toString()));
    host.sshHostKeyTrustMode = Number(get('sshhostkeytrustmode', host.sshHostKeyTrustMode.toString()));
    host.rdpCertificateTrustedAt = Number(get('rdpcertificatetrustedat', host.rdpCertificateTrustedAt.toString()));
    host.rdpCertificateTrustMode = Number(get('rdpcertificatetrustmode', host.rdpCertificateTrustMode.toString()));
    host.rdpCertificateAllowUntrustedRoot = get('rdpcertificateallowuntrustedroot', host.rdpCertificateAllowUntrustedRoot ? '1' : '0') === '1';
    host.rdpCertificateAllowHostMismatch = get('rdpcertificateallowhostmismatch', host.rdpCertificateAllowHostMismatch ? '1' : '0') === '1';
    host.rustdeskPasswordMode = Number(get('rustdeskpasswordmode', host.rustdeskPasswordMode.toString()));
    host.rustdeskAuthMode = get('rustdeskauthmode', host.rustdeskAuthMode) === 'request_approval' ? 'request_approval' : 'password';
    host.rustdeskDirectEnabled = get('rustdeskdirectenabled', host.rustdeskDirectEnabled ? '1' : '0') === '1';
    host.rustdeskDirectPort = Number(get('rustdeskdirectport', host.rustdeskDirectPort.toString()));
    host.sourceType = get('sourcetype', host.sourceType);
    host.rustdeskProAccountId = get('rustdeskproaccountid', host.rustdeskProAccountId);
    host.rustdeskProPeerId = get('rustdeskpropeerid', host.rustdeskProPeerId);
    host.rustdeskProPlatform = get('rustdeskproplatform', host.rustdeskProPlatform);
    host.rustdeskProManaged = get('rustdeskpromanaged', host.rustdeskProManaged ? '1' : '0') === '1';
    host.rustdeskProLastSeenAt = Number(get('rustdeskprolastseenat', host.rustdeskProLastSeenAt.toString()));
    host.rustdeskProSyncError = get('rustdeskprosyncerror', host.rustdeskProSyncError);
    host.normalizeRdpAuthentication();
    return host;
  }

  private hostExtensionValues(host: RemoteHost): Record<string, string> {
    const crypto: DataCrypto = DataCrypto.getInstance();
    const values: Record<string, string> = {};
    host.normalizeRdpAuthentication();
    values['sshkeypassphrase'] = this.encryptIfReady(crypto, host.sshKeyPassphrase);
    return values;
  }

  /** Values that travel in displayconfig's backward-compatible cloud extension. */
  private hostCloudExtensionValues(host: RemoteHost): Record<string, string> {
    const values: Record<string, string> = {};
    host.normalizeRdpAuthentication();
    values['sshkeyid'] = host.sshKeyId;
    values['sshhostkeyalgorithm'] = host.sshHostKeyAlgorithm;
    values['sshhostkeyfingerprintsha256'] = host.sshHostKeyFingerprintSha256;
    values['sshhostkeyrawbase64'] = host.sshHostKeyRawBase64;
    values['sshhostkeytrustedat'] = host.sshHostKeyTrustedAt.toString();
    values['sshhostkeytrustmode'] = host.sshHostKeyTrustMode.toString();
    values['rdpcertificatefingerprintsha256'] = host.rdpCertificateFingerprintSha256;
    values['rdpcertificatesubject'] = host.rdpCertificateSubject;
    values['rdpcertificateissuer'] = host.rdpCertificateIssuer;
    values['rdpcertificatecommonname'] = host.rdpCertificateCommonName;
    values['rdpcertificatetrustedat'] = host.rdpCertificateTrustedAt.toString();
    values['rdpcertificatetrustmode'] = host.rdpCertificateTrustMode.toString();
    values['rdpcertificateallowuntrustedroot'] = host.rdpCertificateAllowUntrustedRoot ? '1' : '0';
    values['rdpcertificateallowhostmismatch'] = host.rdpCertificateAllowHostMismatch ? '1' : '0';
    values['rustdeskrelayid'] = host.rustdeskRelayId;
    values['rustdeskaccountid'] = host.rustdeskAccountId;
    values['rustdeskpasswordmode'] = host.rustdeskPasswordMode.toString();
    values['rustdeskauthmode'] = host.rustdeskAuthMode;
    values['rustdeskdirectenabled'] = host.rustdeskDirectEnabled ? '1' : '0';
    values['rustdeskdirecthost'] = host.rustdeskDirectHost;
    values['rustdeskdirectport'] = host.rustdeskDirectPort.toString();
    values['rdpcredentialid'] = host.rdpCredentialId;
    values['rdpauthmode'] = host.rdpAuthMode;
    values['rdprestrictedadminsecretsource'] = host.rdpRestrictedAdminSecretSource;
    values['sourcetype'] = host.sourceType;
    values['rustdeskproaccountid'] = host.rustdeskProAccountId;
    values['rustdeskpropeerid'] = host.rustdeskProPeerId;
    values['rustdeskproplatform'] = host.rustdeskProPlatform;
    values['rustdeskpromanaged'] = host.rustdeskProManaged ? '1' : '0';
    values['rustdeskprolastseenat'] = host.rustdeskProLastSeenAt.toString();
    values['rustdeskprosyncerror'] = host.rustdeskProSyncError;
    return values;
  }

  private saveHostExtension(host: RemoteHost): boolean {
    if (host.protocol !== 'rdp' || normalizeRdpAuthMode(host.rdpAuthMode) !== 'restricted_admin' ||
      normalizeRdpRestrictedAdminSecretSource(host.rdpRestrictedAdminSecretSource) !== 'ntlm_hash') {
      if (!this.clearRdpRestrictedAdminHash(host.id)) { return false; }
    }
    return this.saveLocalExtension('remotehosts', host.id, this.hostExtensionValues(host));
  }

  private saveSshKeyExtension(key: SshKey): boolean {
    const values: Record<string, string> = {};
    values['formatversion'] = key.formatVersion.toString();
    values['privatekeyencrypted'] = key.privateKeyEncrypted ? '1' : '0';
    return this.saveLocalExtension('sshkeys', key.id, values);
  }

  private mergeSshKeyExtension(key: SshKey): SshKey {
    const values: Record<string, string> = this.loadLocalExtension('sshkeys', key.id);
    if (values['formatversion'] !== undefined) { key.formatVersion = Number(values['formatversion']); }
    if (values['privatekeyencrypted'] !== undefined) { key.privateKeyEncrypted = values['privatekeyencrypted'] === '1'; }
    key.normalizeFormatMetadata();
    return key;
  }

  private async migrateLocalExtensions(): Promise<void> {
    if (!this.store) { return; }
    if (this.readLocalMetadata(CANONICAL_SECRET_STORAGE_VERSION_KEY) === CANONICAL_SECRET_STORAGE_VERSION) { return; }
    try {
      this.store.beginTransaction();
      const rows = this.store.querySync(new relationalStore.RdbPredicates('remotehosts'));
      const idIndex: number = rows.getColumnIndex('id');
      const passwardIndex: number = rows.getColumnIndex('passward');
      const passwordIndex: number = rows.getColumnIndex('password');
      const sshKeyPassphraseIndex: number = rows.getColumnIndex('sshkeypassphrase');
      const displayConfigIndex: number = rows.getColumnIndex('displayconfig');
      while (rows.goToNextRow()) {
        if (idIndex < 0) { continue; }
        const id: string = rows.getString(idIndex);
        if (id === '') { continue; }
        const localValues: Record<string, string> = this.loadLocalExtension('remotehosts', id);
        const legacyValues: Record<string, string> = this.hostExtensionFromResult(rows);
        const legacyKeys: string[] = Object.keys(legacyValues);
        for (let i = 0; i < legacyKeys.length; i++) {
          const key: string = legacyKeys[i];
          if (localValues[key] === undefined && legacyValues[key] !== '') {
            localValues[key] = legacyValues[key];
          }
        }
        const canonical: string = passwardIndex >= 0 ? rows.getString(passwardIndex) : '';
        const legacyMain: string = passwordIndex >= 0 ? rows.getString(passwordIndex) : '';
        const decision = canonicalHostPassword(canonical, legacyMain, localValues['password'] || '');
        const bucket: relationalStore.ValuesBucket = {};
        if (decision.writeCanonical || decision.clearLegacyMain) {
          if (decision.writeCanonical) { bucket['passward'] = decision.value; }
          if (decision.clearLegacyMain) { bucket['password'] = ''; }
        }
        // ArkTS deliberately does not support `delete`. Build the migrated
        // extension explicitly so an old local password shadow can never be
        // re-persisted (or projected into the cloud extension).
        const migratedValues: Record<string, string> = {};
        const localKeys: string[] = Object.keys(localValues);
        for (let i = 0; i < localKeys.length; i++) {
          const key: string = localKeys[i];
          if (key !== 'password') { migratedValues[key] = localValues[key]; }
        }
        const cloudExtension: Record<string, string> = projectRemoteHostCloudExtension(migratedValues);
        if (Object.keys(cloudExtension).length > 0) {
          const displayConfig: string = displayConfigIndex >= 0 ? rows.getString(displayConfigIndex) : '{}';
          bucket['displayconfig'] = encodeRemoteHostDisplayPayload(displayConfig, cloudExtension);
        }
        // The historical column was never part of the cloud contract. Once
        // its value has been copied into the transactional local extension,
        // clear it so it can no longer become a second secret source.
        if (sshKeyPassphraseIndex >= 0 && rows.getString(sshKeyPassphraseIndex) !== '') {
          bucket['sshkeypassphrase'] = '';
        }
        if (Object.keys(bucket).length > 0) {
          const predicates = new relationalStore.RdbPredicates('remotehosts');
          predicates.equalTo('id', id);
          if (!rdbSingleRowAffected(this.store.updateSync(bucket, predicates))) {
            throw new Error('canonical host migration failed id=' + id);
          }
        }
        const deviceLocal: Record<string, string> = {};
        if (migratedValues['sshkeypassphrase'] !== undefined) {
          deviceLocal['sshkeypassphrase'] = migratedValues['sshkeypassphrase'];
        }
        if (Object.keys(deviceLocal).length > 0) {
          if (!this.saveLocalExtension('remotehosts', id, deviceLocal)) {
            throw new Error('local extension migration failed id=' + id);
          }
        } else if (!this.deleteLocalExtension('remotehosts', id)) {
          throw new Error('local extension cleanup failed id=' + id);
        }
      }
      rows.close();
      if (!this.writeLocalMetadata(CANONICAL_SECRET_STORAGE_VERSION_KEY, CANONICAL_SECRET_STORAGE_VERSION)) {
        throw new Error('canonical password migration marker failed');
      }
      this.store.commit();
    } catch (err) {
      try { this.store.rollBack(); } catch (_ignored) {}
      hilog.warn(0x0001, 'CloudSync', '[CloudStore] local extension migration skipped: ' + safeError(err));
    }
  }

  /** 写入一项允许跨设备使用的个性化设置，并在本地写成功后立即推送独立云表。 */
  upsertUserSetting(key: string, value: CloudUserSettingValue): boolean {
    if (!this.store) { return this.setLastMutation(DataMutationResult.failure(key, 'not_ready', '本地数据库未就绪')); }
    if (!this.localMutationAllowed()) {
      return this.setLastMutation(DataMutationResult.failure(key, 'restore_in_progress', '恢复进行中，暂不能保存'));
    }
    if (!cloudUserSettingIsSyncable(key)) {
      return this.setLastMutation(DataMutationResult.failure(key, 'unchanged', '该设置不参与云同步'));
    }
    let code = 'local_write_failed';
    try {
      this.store.beginTransaction();
      const bucket: relationalStore.ValuesBucket = {};
      bucket['id'] = 'setting:' + key;
      bucket['userid'] = '';
      bucket['key'] = key;
      bucket['value'] = JSON.stringify(value);
      const settingRow: Record<string, string> = {};
      settingRow['id'] = 'setting:' + key;
      settingRow['key'] = key;
      settingRow['value'] = JSON.stringify(value);
      settingRow['updatedat'] = Date.now().toString();
      bucket['payload'] = encodeUserSettingsPayload([settingRow]);
      bucket['schemaversion'] = 1;
      bucket['updatedat'] = Date.now();
      if (!rdbInsertSucceeded(this.store.insertSync('usersettings', this.cloudBucket('usersettings', bucket),
        relationalStore.ConflictResolution.ON_CONFLICT_REPLACE))) {
        code = 'local_write_failed'; throw new Error('usersettings upsert failed');
      }
      if (!this.recordLocalMutation('usersettings', key, 'upsert')) {
        code = 'journal_write_failed'; throw new Error('usersettings journal failed');
      }
      this.store.commit();
      this.setLastMutation(DataMutationResult.success(key));
      this.pushTable('usersettings');
      return true;
    } catch (err) {
      try { this.store.rollBack(); } catch (_ignored) {}
      hilog.error(0x0001, 'CloudSync', '[CloudStore] upsertUserSetting 失败: ' + safeError(err));
      return this.setLastMutation(DataMutationResult.failure(key, code as 'local_write_failed' |
        'journal_write_failed', '设置保存未完成'));
    }
  }

  /** 获取已由云端同步到本地 RDB 的可信个性化设置。 */
  loadUserSettings(): Record<string, CloudUserSettingValue> {
    const result: Record<string, CloudUserSettingValue> = {};
    if (!this.store) { return result; }
    try {
      const rows = this.store.querySync(new relationalStore.RdbPredicates('usersettings'));
      while (rows.goToNextRow()) {
        const keyIndex: number = rows.getColumnIndex('key');
        const valueIndex: number = rows.getColumnIndex('value');
        const key: string = keyIndex >= 0 ? rows.getString(keyIndex) : '';
        if (key !== '' && cloudUserSettingIsSyncable(key) && valueIndex >= 0) {
          const parsed: CloudUserSettingValue = JSON.parse(rows.getString(valueIndex)) as CloudUserSettingValue;
          if (typeof parsed === 'string' || typeof parsed === 'number' || typeof parsed === 'boolean') {
            result[key] = parsed;
          }
          continue;
        }
        const payloadIndex: number = rows.getColumnIndex('payload');
        if (payloadIndex < 0) { continue; }
        const cloudSettingRow: Record<string, string> = {};
        cloudSettingRow['id'] = rows.getString(rows.getColumnIndex('id'));
        cloudSettingRow['userid'] = rows.getString(rows.getColumnIndex('userid'));
        cloudSettingRow['payload'] = rows.getString(payloadIndex);
        cloudSettingRow['updatedat'] = rows.getString(rows.getColumnIndex('updatedat'));
        const cloudRows = decodeUserSettingsPayload(cloudSettingRow);
        for (let i = 0; i < cloudRows.length; i++) {
          const payloadKey: string = cloudRows[i]['key'];
          if (!cloudUserSettingIsSyncable(payloadKey)) { continue; }
          const payloadValue: CloudUserSettingValue = JSON.parse(cloudRows[i]['value']) as CloudUserSettingValue;
          if (typeof payloadValue === 'string' || typeof payloadValue === 'number' || typeof payloadValue === 'boolean') {
            result[payloadKey] = payloadValue;
          }
        }
      }
      rows.close();
    } catch (err) {
      hilog.error(0x0001, 'CloudSync', '[CloudStore] loadUserSettings 失败: ' + safeError(err));
    }
    return result;
  }

  /** 暴露 RDB 实例 (供 DataCrypto 使用) */
  getStore(): relationalStore.RdbStore | null {
    return this.store;
  }

  // ==================== Crypto Params (加密参数存储) ====================

  /** 获取密码学参数 (盐值 + 验证器) */
  getCryptoParams(): Record<string, string> | null {
    return DataCrypto.getInstance().getCryptoParams();
  }

  /** 存储密码学参数 (使用 insertSync 以触发云同步) */
  setCryptoParams(salt: string, verifier: string): boolean {
    if (!this.localMutationAllowed() || !this.store) { return false; }
    try {
      const vb1: relationalStore.ValuesBucket = { 'id': 'salt', 'key': 'crypto_salt', 'value': salt };
      const vb2: relationalStore.ValuesBucket = { 'id': 'verif', 'key': 'crypto_verifier', 'value': verifier };
      const vb3: relationalStore.ValuesBucket = { 'id': 'status', 'key': 'crypto_status', 'value': 'active' };
      this.store.beginTransaction();
      if (!rdbInsertSucceeded(this.store.insertSync('cryptoparams', vb1, relationalStore.ConflictResolution.ON_CONFLICT_REPLACE)) ||
        !rdbInsertSucceeded(this.store.insertSync('cryptoparams', vb2, relationalStore.ConflictResolution.ON_CONFLICT_REPLACE)) ||
        !rdbInsertSucceeded(this.store.insertSync('cryptoparams', vb3, relationalStore.ConflictResolution.ON_CONFLICT_REPLACE))) {
        throw new Error('cryptoparams insert failed');
      }
      if (!this.recordTableMutation('cryptoparams', 'configure')) {
        throw new Error('cryptoparams journal failed');
      }
      this.store.commit();
      this.lastKnownCryptoStatus = 'active';
      // 立即推送到云端, 其他设备无需等待 autoSync 即可获知加密已启用
      this.pushTable('cryptoparams');
      return true;
    } catch (e) {
      try { this.store.rollBack(); } catch (_ignored) {}
      hilog.error(0x0001, 'CloudSync', "[setCryptoParams] 写入失败: " + DataCrypto.errDetail(e));
      return false;
    }
  }

  /** 设置加密状态 (跨设备信令) */
  setCryptoStatus(status: string): boolean {
    if (!this.localMutationAllowed() || !this.store) { return false; }
    try {
      const vb: relationalStore.ValuesBucket = { 'id': 'status', 'key': 'crypto_status', 'value': status };
      this.store.beginTransaction();
      if (!rdbInsertSucceeded(this.store.insertSync('cryptoparams', vb, relationalStore.ConflictResolution.ON_CONFLICT_REPLACE))) {
        throw new Error('cryptoparams status insert failed');
      }
      if (!this.recordTableMutation('cryptoparams', 'status:' + status)) {
        throw new Error('cryptoparams status journal failed');
      }
      this.store.commit();
      this.lastKnownCryptoStatus = status;
      hilog.info(0x0001, 'CloudSync', "[setCryptoStatus] " + status);
      return true;
    } catch (e) {
      try { this.store.rollBack(); } catch (_ignored) {}
      hilog.error(0x0001, 'CloudSync', "[setCryptoStatus] 失败: " + DataCrypto.errDetail(e));
      return false;
    }
  }

  /** 读取当前加密状态 */
  getCryptoStatus(): string {
    if (!this.store) { return ''; }
    try {
      const rs = this.store.querySqlSync("SELECT value FROM cryptoparams WHERE key = 'crypto_status'");
      let result: string = '';
      if (rs.goToFirstRow()) {
        result = rs.getString(0);
      }
      rs.close();
      // 兼容旧数据: 有 salt 但无 crypto_status → 视为 active
      if (result === '') {
        const saltRs = this.store.querySqlSync("SELECT value FROM cryptoparams WHERE key = 'crypto_salt'");
        if (saltRs.goToFirstRow()) {
          result = 'active';
        }
        saltRs.close();
      }
      return result;
    } catch (_e) {
      return '';
    }
  }

  /** 清空全部敏感业务表；接收云端 reset 时需要推送本地删除，手动重置则统一在最后推送。 */
  async clearAllTables(pushChanges: boolean = true): Promise<boolean> {
    if (!this.localMutationAllowed() || !this.store) { return false; }
    try {
      const tables: string[] = ['remotehosts', 'rdpcredentials', 'sshkeys', 'totpentries', 'rustdeskrelays'];
      this.store.beginTransaction();
      // Every local-only payload belongs to one of the cleared rows. Clear
      // stale cached secrets/metadata before recording fresh delete intents.
      await this.store.executeSql('DELETE FROM localextensions');
      await this.store.executeSql('DELETE FROM ' + LOCAL_METADATA_TABLE);
      await this.store.executeSql('DELETE FROM ' + LOCAL_MUTATION_JOURNAL_TABLE);
      for (let i = 0; i < tables.length; i++) {
        await this.store.executeSql("DELETE FROM " + tables[i]);
        if (!this.recordTableMutation(tables[i], 'clear')) {
          throw new Error('clear journal failed table=' + tables[i]);
        }
        hilog.info(0x0001, 'CloudSync', "[clearAllTables] " + tables[i] + " 已清空");
      }
      this.store.commit();
      // 系统 autoSync 已关闭，显式推送每一个已清空的业务表。
      if (pushChanges) {
        for (let i = 0; i < tables.length; i++) { this.pushTable(tables[i]); }
      }
      return true;
    } catch (e) {
      try { this.store.rollBack(); } catch (_ignored) {}
      hilog.error(0x0001, 'CloudSync', "[clearAllTables] 失败: " + DataCrypto.errDetail(e));
      return false;
    }
  }

  /**
   * 批量解密敏感业务表；返回 -1 表示任何本地写入失败且本次事务已回滚。
   * 调用方绝不能在 -1 后删除密码学参数或发布 disabled 信令。
   */
  decryptAllData(crypto: DataCrypto, pushChanges: boolean = true): number {
    if (!this.localMutationAllowed() || !this.store) { return -1; }
    let count: number = 0;
    let hostsChanged: boolean = false;
    let rdpCredentialsChanged: boolean = false;
    let relaysChanged: boolean = false;
    let sshKeysChanged: boolean = false;
    let totpEntriesChanged: boolean = false;
    try {
      this.store.beginTransaction();
      // 1. remotehosts: the canonical password lives in `passward`.
      const hostPredicates = new relationalStore.RdbPredicates('remotehosts');
      const hostRs = this.store.querySync(hostPredicates);
      while (hostRs.goToNextRow()) {
        const id: string = hostRs.getString(hostRs.getColumnIndex('id'));
        const passwardIndex: number = hostRs.getColumnIndex('passward');
        const legacyPasswordIndex: number = hostRs.getColumnIndex('password');
        const canonicalPassword: string = passwardIndex >= 0 ? hostRs.getString(passwardIndex) : '';
        const legacyPassword: string = legacyPasswordIndex >= 0 ? hostRs.getString(legacyPasswordIndex) : '';
        const pwd: string = canonicalPassword !== '' ? canonicalPassword : legacyPassword;
        const sshData: string = hostRs.getString(hostRs.getColumnIndex('sshkeydata'));
        let changed: boolean = false;
        const vb: relationalStore.ValuesBucket = {};
        if (crypto.isEncrypted(pwd)) {
          vb['passward'] = crypto.decrypt(pwd);
          // Never recreate the retired local password shadow while disabling
          // encryption. If it was the only recoverable legacy value, it has
          // now been promoted into the canonical column above.
          if (legacyPasswordIndex >= 0) { vb['password'] = ''; }
          changed = true;
        } else if (legacyPassword !== '') {
          // A plaintext legacy shadow cannot override canonical passward.
          vb['password'] = '';
          changed = true;
        }
        if (crypto.isEncrypted(sshData)) {
          vb['sshkeydata'] = crypto.decrypt(sshData);
          changed = true;
        }
        if (changed) {
          const predicates = new relationalStore.RdbPredicates('remotehosts');
          predicates.equalTo('id', id);
          if (rdbSingleRowAffected(this.store.updateSync(vb, predicates))) {
            if (!this.recordLocalMutation('remotehosts', id, 'crypto_decrypt')) {
              throw new Error('decrypt remotehosts journal failed id=' + id);
            }
            count++;
            hostsChanged = true;
          } else {
            throw new Error('decrypt remotehosts update failed id=' + id);
          }
        }
      }
      hostRs.close();

      // 2. rdpcredentials: 解密 password
      const rdpPredicates = new relationalStore.RdbPredicates('rdpcredentials');
      const rdpRs = this.store.querySync(rdpPredicates);
      while (rdpRs.goToNextRow()) {
        const id: string = rdpRs.getString(rdpRs.getColumnIndex('id'));
        const pwd: string = rdpRs.getString(rdpRs.getColumnIndex('password'));
        const vb: relationalStore.ValuesBucket = {};
        if (crypto.isEncrypted(pwd)) {
          vb['password'] = crypto.decrypt(pwd);
          const predicates = new relationalStore.RdbPredicates('rdpcredentials');
          predicates.equalTo('id', id);
          if (rdbSingleRowAffected(this.store.updateSync(vb, predicates))) {
            if (!this.recordLocalMutation('rdpcredentials', id, 'crypto_decrypt')) {
              throw new Error('decrypt rdpcredentials journal failed id=' + id);
            }
            count++;
            rdpCredentialsChanged = true;
          } else {
            throw new Error('decrypt rdpcredentials update failed id=' + id);
          }
        }
      }
      rdpRs.close();

      // 3. sshkeys: 解密 privatekey
      const keyPredicates = new relationalStore.RdbPredicates('sshkeys');
      const keyRs = this.store.querySync(keyPredicates);
      while (keyRs.goToNextRow()) {
        const id: string = keyRs.getString(keyRs.getColumnIndex('id'));
        const pk: string = keyRs.getString(keyRs.getColumnIndex('privatekey'));
        if (crypto.isEncrypted(pk)) {
          const vb: relationalStore.ValuesBucket = {};
          vb['privatekey'] = crypto.decrypt(pk);
          const predicates = new relationalStore.RdbPredicates('sshkeys');
          predicates.equalTo('id', id);
          if (rdbSingleRowAffected(this.store.updateSync(vb, predicates))) {
            if (!this.recordLocalMutation('sshkeys', id, 'crypto_decrypt')) {
              throw new Error('decrypt sshkeys journal failed id=' + id);
            }
            count++;
            sshKeysChanged = true;
          } else {
            throw new Error('decrypt sshkeys update failed id=' + id);
          }
        }
      }
      keyRs.close();

      // 4. totpentries: 解密 secret
      const totpPredicates = new relationalStore.RdbPredicates('totpentries');
      const totpRs = this.store.querySync(totpPredicates);
      while (totpRs.goToNextRow()) {
        const id: string = totpRs.getString(totpRs.getColumnIndex('id'));
        const sec: string = totpRs.getString(totpRs.getColumnIndex('secret'));
        if (crypto.isEncrypted(sec)) {
          const vb: relationalStore.ValuesBucket = {};
          vb['secret'] = crypto.decrypt(sec);
          const predicates = new relationalStore.RdbPredicates('totpentries');
          predicates.equalTo('id', id);
          if (rdbSingleRowAffected(this.store.updateSync(vb, predicates))) {
            if (!this.recordLocalMutation('totpentries', id, 'crypto_decrypt')) {
              throw new Error('decrypt totpentries journal failed id=' + id);
            }
            count++;
            totpEntriesChanged = true;
          } else {
            throw new Error('decrypt totpentries update failed id=' + id);
          }
        }
      }
      totpRs.close();

      // 5. rustdeskrelays: 解密 API 密码、server key 和 accountsjson 内的账户密码
      const relayPredicates = new relationalStore.RdbPredicates('rustdeskrelays');
      const relayRs = this.store.querySync(relayPredicates);
      while (relayRs.goToNextRow()) {
        const id: string = relayRs.getString(relayRs.getColumnIndex('id'));
        let changed: boolean = false;
        const vb: relationalStore.ValuesBucket = {};
        const apiPassword: string = relayRs.getString(relayRs.getColumnIndex('apipassword'));
        const key: string = relayRs.getString(relayRs.getColumnIndex('key'));
        if (crypto.isEncrypted(apiPassword)) {
          vb['apipassword'] = crypto.decrypt(apiPassword);
          changed = true;
        }
        if (crypto.isEncrypted(key)) {
          vb['key'] = crypto.decrypt(key);
          changed = true;
        }
        const accountsIdx: number = relayRs.getColumnIndex('accountsjson');
        if (accountsIdx >= 0) {
          const accountsJson: string = relayRs.getString(accountsIdx);
          if (accountsJson !== '') {
            try {
              const accounts: RustDeskAccountJSON[] = JSON.parse(accountsJson) as RustDeskAccountJSON[];
              for (let i = 0; i < accounts.length; i++) {
                if (crypto.isEncrypted(accounts[i].password)) {
                  accounts[i].password = crypto.decrypt(accounts[i].password);
                  changed = true;
                }
              }
              if (changed) {
                vb['accountsjson'] = JSON.stringify(accounts);
              }
            } catch (err) {
              throw new Error('[decryptAllData] rustdesk accounts 解密失败: ' + DataCrypto.errDetail(err));
            }
          }
        }
        if (changed) {
          const predicates = new relationalStore.RdbPredicates('rustdeskrelays');
          predicates.equalTo('id', id);
          if (rdbSingleRowAffected(this.store.updateSync(vb, predicates))) {
            if (!this.recordLocalMutation('rustdeskrelays', id, 'crypto_decrypt')) {
              throw new Error('decrypt rustdeskrelays journal failed id=' + id);
            }
            count++;
            relaysChanged = true;
          } else {
            throw new Error('decrypt rustdeskrelays update failed id=' + id);
          }
        }
      }
      relayRs.close();

      // Device-local extension secrets are not represented by a cloud column.
      // When encryption is disabled, convert the SSH passphrase in place and
      // wipe restricted-admin material instead of leaving inaccessible cipher
      // text (or a plaintext NTLM hash) behind.
      count += this.decryptSensitiveLocalExtensions(crypto);

      this.store.commit();
      if (pushChanges) {
        if (hostsChanged) { this.pushTable('remotehosts'); }
        if (rdpCredentialsChanged) { this.pushTable('rdpcredentials'); }
        if (relaysChanged) { this.pushTable('rustdeskrelays'); }
        if (sshKeysChanged) { this.pushTable('sshkeys'); }
        if (totpEntriesChanged) { this.pushTable('totpentries'); }
      }

      hilog.info(0x0001, 'CloudSync', "[decryptAllData] 已解密 " + count.toString() + " 条记录");
    } catch (e) {
      try { this.store.rollBack(); } catch (_ignored) {}
      hilog.error(0x0001, 'CloudSync', "[decryptAllData] 失败: " + DataCrypto.errDetail(e));
      return -1;
    }
    return count;
  }

  /** Runs inside decryptAllData's active RDB transaction. */
  private decryptSensitiveLocalExtensions(crypto: DataCrypto): number {
    if (!this.store) { throw new Error('local extension store unavailable'); }
    let changedCount: number = 0;
    const rows = this.store.querySync(new relationalStore.RdbPredicates('localextensions'));
    try {
      while (rows.goToNextRow()) {
        const id: string = rows.getString(rows.getColumnIndex('id'));
        const table: string = rows.getString(rows.getColumnIndex('tablename'));
        const recordId: string = rows.getString(rows.getColumnIndex('recordid'));
        if (id === '' || recordId === '') { throw new Error('invalid local extension identity'); }
        const predicates = new relationalStore.RdbPredicates('localextensions');
        predicates.equalTo('id', id);
        if (table === RDP_RESTRICTED_ADMIN_SECRET_TABLE) {
          if (!rdbSingleRowAffected(this.store.deleteSync(predicates))) {
            throw new Error('restricted admin extension wipe failed id=' + id);
          }
          changedCount++;
          continue;
        }
        if (table !== 'remotehosts') { continue; }
        const payload: string = rows.getString(rows.getColumnIndex('payload'));
        const parsed: Object = JSON.parse(payload) as Object;
        if (!parsed || Array.isArray(parsed)) { throw new Error('invalid host extension payload id=' + id); }
        const source: Record<string, string> = parsed as Record<string, string>;
        const next: Record<string, string> = {};
        const keys: string[] = Object.keys(source);
        let changed: boolean = false;
        for (let i = 0; i < keys.length; i++) {
          const key: string = keys[i];
          const value: string = source[key];
          // This retired shadow must never survive an encryption transition.
          if (key === 'password') { changed = true; continue; }
          if (key === 'sshkeypassphrase' && crypto.isEncrypted(value)) {
            next[key] = crypto.decrypt(value);
            changed = true;
          } else {
            next[key] = value;
          }
        }
        if (!changed) { continue; }
        if (Object.keys(next).length === 0) {
          if (!rdbSingleRowAffected(this.store.deleteSync(predicates))) {
            throw new Error('empty host extension cleanup failed id=' + id);
          }
        } else {
          const bucket: relationalStore.ValuesBucket = {
            payload: JSON.stringify(next), updatedat: Date.now()
          };
          if (!rdbSingleRowAffected(this.store.updateSync(bucket, predicates))) {
            throw new Error('host extension decrypt failed id=' + id);
          }
        }
        changedCount++;
      }
    } finally {
      rows.close();
    }
    return changedCount;
  }

  /** 检测加密状态变更并执行对应的本地联动操作 (跨设备同步) */
  checkCryptoStatusChange(allowRemoteReset: boolean = false): boolean {
    const newStatus: string = this.getCryptoStatus();
    if (newStatus === '' || newStatus === this.lastKnownCryptoStatus) {
      return false;
    }
    hilog.info(0x0001, 'CloudSync',
      "[checkCryptoStatusChange] " + this.lastKnownCryptoStatus + " → " + newStatus);
    if (newStatus === 'reset') {
      if (!allowRemoteReset) {
        hilog.warn(0x0001, 'CloudSync',
          '[checkCryptoStatusChange] reset not confirmed by cloud-first; preserving local data');
        DataCrypto.getInstance().lock();
        return false;
      }
      this.lastKnownCryptoStatus = newStatus;
      // await clearAllTables 完成后再触发回调, 避免回调读到旧数据
      this.clearAllTables().then((cleared: boolean): void => {
        const cryptoStateChanged: boolean = DataCrypto.getInstance().lock();
        for (let i = 0; i < this.onCryptoResetCallbacks.length; i++) {
          this.onCryptoResetCallbacks[i]();
        }
        if (cleared) {
          hilog.info(0x0001, 'CloudSync', '[checkCryptoStatusChange] reset: 本地数据已清空');
        } else {
          hilog.error(0x0001, 'CloudSync', '[checkCryptoStatusChange] reset: 本地清理失败，已锁定密钥');
        }
        if (!cryptoStateChanged) { this.notifyDataSnapshotChanged(); }
      }).catch((e: Error): void => {
        hilog.error(0x0001, 'CloudSync',
          '[checkCryptoStatusChange] reset clearAllTables 异常: ' + e.message);
        // 即使清表失败也锁定 DEK, 防止残留明文密钥
        const cryptoStateChanged: boolean = DataCrypto.getInstance().lock();
        for (let i = 0; i < this.onCryptoResetCallbacks.length; i++) {
          this.onCryptoResetCallbacks[i]();
        }
        if (!cryptoStateChanged) { this.notifyDataSnapshotChanged(); }
      });
      return true;
    } else {
      this.lastKnownCryptoStatus = newStatus;
    }

    if (newStatus === 'disabled') {
      // 接收端必须先解密本地数据再锁 DEK (云同步过来的数据仍是密文)
      const crypto = DataCrypto.getInstance();
      if (crypto.isReady()) {
        const decrypted = this.decryptAllData(crypto);
        if (decrypted < 0) {
          // Keep the DEK for a later retry. Treating this status as handled would
          // otherwise leave encrypted rows unreadable after a transient RDB failure.
          this.lastKnownCryptoStatus = '';
          hilog.error(0x0001, 'CloudSync', '[checkCryptoStatusChange] disabled: 本地解密失败，等待后续同步重试');
          return false;
        }
        hilog.info(0x0001, 'CloudSync',
          '[checkCryptoStatusChange] disabled: 接收端已解密 ' + decrypted.toString() + ' 条数据');
        crypto.lock();
      } else {
        // DEK 未解锁 — 发送端已解密并推送明文数据到云端, 本地会通过后续 sync 事件拉取明文。
        // 不需要本地解密, 仅记录日志。下次 onCloudChange 触发时数据已是明文。
        hilog.warn(0x0001, 'CloudSync',
          '[checkCryptoStatusChange] disabled: DEK未就绪, 等待云端明文数据同步到达');
      }
      hilog.info(0x0001, 'CloudSync', '[checkCryptoStatusChange] disabled: 等待完成快照发布');
    }
    return false;
  }

  /** 清除密码学参数 */
  async clearCryptoParams(): Promise<boolean> {
    if (!this.localMutationAllowed() || !this.store) { return false; }
    try {
      this.store.beginTransaction();
      await this.store.executeSql("DELETE FROM cryptoparams WHERE key IN ('crypto_salt', 'crypto_verifier')");
      if (!this.recordTableMutation('cryptoparams', 'clear_params')) {
        throw new Error('cryptoparams clear journal failed');
      }
      this.store.commit();
      return true;
    } catch (e) {
      try { this.store.rollBack(); } catch (_ignored) {}
      hilog.error(0x0001, 'CloudSync', '[clearCryptoParams] 失败: ' + DataCrypto.errDetail(e));
      return false;
    }
  }

  // ==================== Raw CRUD (不解密, 供迁移使用) ====================

  /**
   * Encryption migration changes business rows outside ordinary CRUD. Treat
   * each successful raw write as a normal durable mutation so a process death
   * between the local transformation and cloud upload cannot lose it.
   */
  private runRawMigrationMutation(table: string, recordId: string, operation: string,
    write: () => boolean): boolean {
    if (!this.store || !this.localMutationAllowed()) { return false; }
    try {
      this.store.beginTransaction();
      if (!write()) { throw new Error('raw migration write failed'); }
      if (!this.recordLocalMutation(table, recordId, operation)) {
        throw new Error('raw migration journal failed');
      }
      this.store.commit();
      return true;
    } catch (err) {
      try { this.store.rollBack(); } catch (_ignored) {}
      hilog.warn(0x0001, 'CloudSync', '[CloudStore] raw migration mutation failed table=' +
        table + ' err=' + safeError(err));
      return false;
    }
  }

  loadAllHostsRaw(): RemoteHost[] {
    return this.loadAllHostsInternal(false);
  }

  loadAllRdpCredentialsRaw(): RdpCredential[] {
    return this.loadAllRdpCredentialsInternal(false);
  }

  loadAllRelaysRaw(): RustDeskRelayConfig[] {
    return this.loadAllRelaysLocalInternal(false);
  }

  loadAllSshKeysRaw(): SshKey[] {
    return this.loadAllSshKeysInternal(false);
  }

  loadAllTotpEntriesRaw(): TotpEntry[] {
    return this.loadAllTotpEntriesInternal(false);
  }

  updateHostRaw(host: RemoteHost): boolean {
    return this.runRawMigrationMutation('remotehosts', host.id, 'crypto_encrypt',
      (): boolean => this.updateHostInternal(host, false));
  }

  updateRdpCredentialRaw(credential: RdpCredential): boolean {
    return this.runRawMigrationMutation('rdpcredentials', credential.id, 'crypto_encrypt',
      (): boolean => this.updateRdpCredentialInternal(credential, false));
  }

  upsertRelayLocalRaw(relay: RustDeskRelayConfig): boolean {
    return this.runRawMigrationMutation('rustdeskrelays', relay.id, 'crypto_encrypt',
      (): boolean => this.upsertRelayLocalInternal(relay, false));
  }

  updateSshKeyRaw(key: SshKey): boolean {
    return this.runRawMigrationMutation('sshkeys', key.id, 'crypto_encrypt',
      (): boolean => this.updateSshKeyInternal(key, false));
  }

  updateTotpEntryRaw(entry: TotpEntry): boolean {
    return this.runRawMigrationMutation('totpentries', entry.id, 'crypto_encrypt',
      (): boolean => this.updateTotpEntryInternal(entry, false));
  }

  // ==================== RemoteHost CRUD ====================

  loadAllHosts(): RemoteHost[] {
    return this.loadAllHostsInternal(true);
  }

  insertHost(host: RemoteHost): boolean {
    if (!this.store) { return this.setLastMutation(DataMutationResult.failure(host.id, 'not_ready', '本地数据库未就绪')); }
    if (!this.localMutationAllowed()) {
      return this.setLastMutation(DataMutationResult.failure(host.id, 'restore_in_progress', '恢复进行中，暂不能保存'));
    }
    if (!this.sensitiveWriteAllowed(host.id)) { return false; }
    let code = 'local_write_failed';
    try {
      this.store.beginTransaction();
      const vb = this.hostToBucket(host);
      vb['createdat'] = Date.now();
      vb['updatedat'] = Date.now();
      if (!rdbInsertSucceeded(this.store.insertSync('remotehosts', vb))) { code = 'local_write_failed'; throw new Error('host insert failed'); }
      if (!this.saveHostExtension(host)) { code = 'extension_write_failed'; throw new Error('host extension insert failed'); }
      if (!this.recordLocalMutation('remotehosts', host.id, 'add')) { code = 'journal_write_failed'; throw new Error('host journal insert failed'); }
      this.store.commit();
      hilog.info(0x0001, 'CloudSync', "insertHost: " + host.label + " (" + host.id + ")");
      return this.setLastMutation(DataMutationResult.success(host.id));
    } catch (err) {
      try { this.store.rollBack(); } catch (_ignored) {}
      hilog.error(0x0001, 'CloudSync', '[CloudStore] insertHost 失败: ' + JSON.stringify(err));
      return this.setLastMutation(DataMutationResult.failure(host.id, code as 'local_write_failed' |
        'extension_write_failed' | 'journal_write_failed', '主机保存未完成'));
    }
  }

  updateHost(host: RemoteHost): boolean {
    if (!this.store) { return this.setLastMutation(DataMutationResult.failure(host.id, 'not_ready', '本地数据库未就绪')); }
    if (!this.localMutationAllowed()) {
      return this.setLastMutation(DataMutationResult.failure(host.id, 'restore_in_progress', '恢复进行中，暂不能保存'));
    }
    if (!this.sensitiveWriteAllowed(host.id)) { return false; }
    let code = 'local_write_failed';
    try {
      this.store.beginTransaction();
      const vb = this.hostToBucket(host);
      vb['updatedat'] = Date.now();
      const predicates = new relationalStore.RdbPredicates('remotehosts');
      predicates.equalTo('id', host.id);
      if (!rdbSingleRowAffected(this.store.updateSync(vb, predicates))) { code = 'not_found'; throw new Error('host update failed'); }
      if (!this.saveHostExtension(host)) { code = 'extension_write_failed'; throw new Error('host extension update failed'); }
      if (!this.recordLocalMutation('remotehosts', host.id, 'update')) { code = 'journal_write_failed'; throw new Error('host journal update failed'); }
      this.store.commit();
      hilog.info(0x0001, 'CloudSync', "updateHost: " + host.label + " (" + host.id + ")");
      return this.setLastMutation(DataMutationResult.success(host.id));
    } catch (err) {
      try { this.store.rollBack(); } catch (_ignored) {}
      hilog.error(0x0001, 'CloudSync', '[CloudStore] updateHost 失败: ' + JSON.stringify(err));
      return this.setLastMutation(DataMutationResult.failure(host.id, code as 'local_write_failed' |
        'not_found' | 'extension_write_failed' | 'journal_write_failed', '主机更新未完成'));
    }
  }

  deleteHost(id: string): boolean {
    if (!this.store) { return this.setLastMutation(DataMutationResult.failure(id, 'not_ready', '本地数据库未就绪')); }
    if (!this.localMutationAllowed()) {
      return this.setLastMutation(DataMutationResult.failure(id, 'restore_in_progress', '恢复进行中，暂不能删除'));
    }
    if (!this.sensitiveWriteAllowed(id)) { return false; }
    let code = 'local_write_failed';
    try {
      this.store.beginTransaction();
      const predicates = new relationalStore.RdbPredicates('remotehosts');
      predicates.equalTo('id', id);
      if (!rdbSingleRowAffected(this.store.deleteSync(predicates))) { code = 'not_found'; throw new Error('host delete failed'); }
      if (!this.deleteLocalExtension('remotehosts', id) || !this.clearRdpRestrictedAdminHash(id)) {
        code = 'extension_write_failed'; throw new Error('host extension delete failed');
      }
      if (!this.recordLocalMutation('remotehosts', id, 'delete')) { code = 'journal_write_failed'; throw new Error('host journal delete failed'); }
      this.store.commit();
      hilog.info(0x0001, 'CloudSync', "deleteHost: " + id);
      return this.setLastMutation(DataMutationResult.success(id));
    } catch (err) {
      try { this.store.rollBack(); } catch (_ignored) {}
      hilog.error(0x0001, 'CloudSync', '[CloudStore] deleteHost 失败: ' + JSON.stringify(err));
      return this.setLastMutation(DataMutationResult.failure(id, code as 'local_write_failed' |
        'not_found' | 'extension_write_failed' | 'journal_write_failed', '主机删除未完成'));
    }
  }

  // ==================== RDP Credential CRUD ====================

  loadAllRdpCredentials(): RdpCredential[] {
    return this.loadAllRdpCredentialsInternal(true);
  }

  private loadAllRdpCredentialsInternal(decrypt: boolean): RdpCredential[] {
    const result: RdpCredential[] = [];
    if (!this.store) { return result; }
    try {
      const predicates = new relationalStore.RdbPredicates('rdpcredentials');
      const rs = this.store.querySync(predicates);
      while (rs.goToNextRow()) {
        const credential: RdpCredential = decrypt ? this.rowToRdpCredential(rs) : this.rowToRdpCredentialRaw(rs);
        const extension: Record<string, string> = this.loadLocalExtension('rdpcredentials', credential.id);
        if (extension['username'] !== undefined) { credential.username = extension['username']; }
        result.push(credential);
      }
      rs.close();
    } catch (err) {
      hilog.error(0x0001, 'CloudSync', '[CloudStore] loadAllRdpCredentials 失败: ' + JSON.stringify(err));
    }
    return result;
  }

  insertRdpCredential(credential: RdpCredential): boolean {
    if (!this.store) { return this.setLastMutation(DataMutationResult.failure(credential.id, 'not_ready', '本地数据库未就绪')); }
    if (!this.localMutationAllowed()) {
      return this.setLastMutation(DataMutationResult.failure(credential.id, 'restore_in_progress', '恢复进行中，暂不能保存'));
    }
    if (!this.sensitiveWriteAllowed(credential.id)) { return false; }
    let code = 'local_write_failed';
    try {
      this.store.beginTransaction();
      const vb = this.rdpCredentialToBucket(credential);
      vb['updatedat'] = Date.now();
      if (!rdbInsertSucceeded(this.store.insertSync('rdpcredentials', vb, relationalStore.ConflictResolution.ON_CONFLICT_REPLACE))) {
        code = 'local_write_failed'; throw new Error('rdp credential insert failed');
      }
      if (!this.saveLocalExtension('rdpcredentials', credential.id, { 'username': credential.username })) {
        code = 'extension_write_failed'; throw new Error('rdp credential extension insert failed');
      }
      if (!this.recordLocalMutation('rdpcredentials', credential.id, 'add')) {
        code = 'journal_write_failed'; throw new Error('rdp credential journal insert failed');
      }
      this.store.commit();
      hilog.info(0x0001, 'CloudSync', 'insertRdpCredential: idHash=' + hashForLog(credential.id));
      return this.setLastMutation(DataMutationResult.success(credential.id));
    } catch (err) {
      try { this.store.rollBack(); } catch (_ignored) {}
      hilog.error(0x0001, 'CloudSync', '[CloudStore] insertRdpCredential 失败: ' + safeError(err));
      return this.setLastMutation(DataMutationResult.failure(credential.id, code as 'local_write_failed' |
        'extension_write_failed' | 'journal_write_failed', 'Windows 凭据保存未完成'));
    }
  }

  updateRdpCredential(credential: RdpCredential): boolean {
    if (!this.store) { return this.setLastMutation(DataMutationResult.failure(credential.id, 'not_ready', '本地数据库未就绪')); }
    if (!this.localMutationAllowed()) {
      return this.setLastMutation(DataMutationResult.failure(credential.id, 'restore_in_progress', '恢复进行中，暂不能保存'));
    }
    if (!this.sensitiveWriteAllowed(credential.id)) { return false; }
    let code = 'local_write_failed';
    try {
      this.store.beginTransaction();
      const vb = this.rdpCredentialToBucket(credential);
      vb['updatedat'] = Date.now();
      const predicates = new relationalStore.RdbPredicates('rdpcredentials');
      predicates.equalTo('id', credential.id);
      if (!rdbSingleRowAffected(this.store.updateSync(vb, predicates))) { code = 'not_found'; throw new Error('rdp credential update failed'); }
      if (!this.saveLocalExtension('rdpcredentials', credential.id, { 'username': credential.username })) {
        code = 'extension_write_failed'; throw new Error('rdp credential extension update failed');
      }
      if (!this.recordLocalMutation('rdpcredentials', credential.id, 'update')) {
        code = 'journal_write_failed'; throw new Error('rdp credential journal update failed');
      }
      this.store.commit();
      return this.setLastMutation(DataMutationResult.success(credential.id));
    } catch (err) {
      try { this.store.rollBack(); } catch (_ignored) {}
      hilog.error(0x0001, 'CloudSync', '[CloudStore] updateRdpCredential 失败: ' + safeError(err));
      return this.setLastMutation(DataMutationResult.failure(credential.id, code as 'local_write_failed' |
        'not_found' | 'extension_write_failed' | 'journal_write_failed', 'Windows 凭据更新未完成'));
    }
  }

  private updateRdpCredentialInternal(credential: RdpCredential, encrypt: boolean): boolean {
    if (!this.store) { return false; }
    try {
      const vb = encrypt ? this.rdpCredentialToBucket(credential) : this.rdpCredentialToBucketRaw(credential);
      vb['updatedat'] = Date.now();
      const predicates = new relationalStore.RdbPredicates('rdpcredentials');
      predicates.equalTo('id', credential.id);
      const updated: boolean = rdbSingleRowAffected(this.store.updateSync(vb, predicates));
      if (!updated) { return false; }
      return this.saveLocalExtension('rdpcredentials', credential.id, { 'username': credential.username });
    } catch (err) {
      hilog.error(0x0001, 'CloudSync', '[CloudStore] updateRdpCredential 失败: ' + safeError(err));
      return false;
    }
  }

  deleteRdpCredential(id: string): boolean {
    if (!this.store) { return this.setLastMutation(DataMutationResult.failure(id, 'not_ready', '本地数据库未就绪')); }
    if (!this.localMutationAllowed()) {
      return this.setLastMutation(DataMutationResult.failure(id, 'restore_in_progress', '恢复进行中，暂不能删除'));
    }
    if (!this.sensitiveWriteAllowed(id)) { return false; }
    let code = 'local_write_failed';
    try {
      this.store.beginTransaction();
      const predicates = new relationalStore.RdbPredicates('rdpcredentials');
      predicates.equalTo('id', id);
      const deleted: boolean = rdbSingleRowAffected(this.store.deleteSync(predicates));
      if (!deleted) { code = 'not_found'; throw new Error('rdp credential delete failed'); }
      if (!this.deleteLocalExtension('rdpcredentials', id)) { code = 'extension_write_failed'; throw new Error('rdp credential extension delete failed'); }
      if (!this.recordLocalMutation('rdpcredentials', id, 'delete')) { code = 'journal_write_failed'; throw new Error('rdp credential journal delete failed'); }
      this.store.commit();
      return this.setLastMutation(DataMutationResult.success(id));
    } catch (err) {
      try { this.store.rollBack(); } catch (_ignored) {}
      hilog.error(0x0001, 'CloudSync', '[CloudStore] deleteRdpCredential 失败: ' + safeError(err));
      return this.setLastMutation(DataMutationResult.failure(id, code as 'local_write_failed' |
        'not_found' | 'extension_write_failed' | 'journal_write_failed', 'Windows 凭据删除未完成'));
    }
  }

  // ==================== RustDesk Relay 云同步 ====================

  /** 中继使用独立的 rustdeskrelays 云表；不再把整表 JSON 塞入 cryptoparams。 */
  syncRelaysToCloud(): void {
    this.pushTable('rustdeskrelays');
  }

  /** 从 cryptoparams 读取 relay JSON → 合并到本地 rustdeskrelays 表 */
  syncRelaysFromCloud(): RustDeskRelayConfig[] {
    const result: RustDeskRelayConfig[] = [];
    if (!this.store) { return result; }
    try {
      const predicates = new relationalStore.RdbPredicates('cryptoparams');
      predicates.equalTo('key', 'rustdesk_relays');
      const rs = this.store.querySync(predicates);
      if (rs.goToNextRow()) {
        const json: string = rs.getString(rs.getColumnIndex('value'));
        const cfgs: RustDeskRelayJSON[] = JSON.parse(json) as RustDeskRelayJSON[];
        // 合并到本地表: 云端有而本地没有的 → insert; 本地有而云端没有的 → 保留本地
        const localIds: Set<string> = new Set();
        const localRelays = this.loadAllRelaysLocal();
        for (let i = 0; i < localRelays.length; i++) { localIds.add(localRelays[i].id); }
        for (let i = 0; i < cfgs.length; i++) {
          const relay = this.relayFromCloudJson(cfgs[i]);
          if (!localIds.has(relay.id)) {
            this.upsertRelayLocal(relay);
          }
          result.push(relay);
        }
        // 如果云端为空而本地有数据, 推本地到云端
        for (let i = 0; i < localRelays.length; i++) {
          const found = cfgs.some((c: RustDeskRelayJSON) => c.id === localRelays[i].id);
          if (!found) { result.push(localRelays[i]); }
        }
        hilog.info(0x0001, 'CloudSync', '[syncRelaysFromCloud] 从云端合并 ' + cfgs.length.toString() + ' 组中继');
      }
      rs.close();
    } catch (err) {
      hilog.error(0x0001, 'CloudSync', '[syncRelaysFromCloud] 失败: ' + JSON.stringify(err));
    }
    return result;
  }

  // ==================== RustDesk Relay CRUD (本地) ====================

  private relayAccountsToJson(relay: RustDeskRelayConfig): string {
    const crypto = DataCrypto.getInstance();
    const items: RustDeskAccountJSON[] = [];
    for (let i = 0; i < relay.accounts.length; i++) {
      const item: RustDeskAccountJSON = relay.accounts[i].toJSON();
      if (item.password !== '') { item.password = this.encryptIfReady(crypto, item.password); }
      items.push(item);
    }
    return JSON.stringify(items);
  }

  private relayAccountsFromJson(json: string): RustDeskAccount[] {
    const accounts: RustDeskAccount[] = [];
    if (json === '') { return accounts; }
    try {
      const crypto = DataCrypto.getInstance();
      const parsed: RustDeskAccountJSON[] = JSON.parse(json) as RustDeskAccountJSON[];
      for (let i = 0; i < parsed.length; i++) {
        const account: RustDeskAccount = RustDeskAccount.fromJSON(parsed[i]);
        if (account.password !== '') { account.password = this.decryptIfReady(crypto, account.password); }
        accounts.push(account);
      }
    } catch (err) {
      hilog.error(0x0001, 'CloudSync', '[CloudStore] relay accounts JSON 解析失败: ' + JSON.stringify(err));
    }
    return accounts;
  }

  private relayAccountsFromJsonRaw(json: string): RustDeskAccount[] {
    const accounts: RustDeskAccount[] = [];
    if (json === '') { return accounts; }
    try {
      const parsed: RustDeskAccountJSON[] = JSON.parse(json) as RustDeskAccountJSON[];
      for (let i = 0; i < parsed.length; i++) {
        accounts.push(RustDeskAccount.fromJSON(parsed[i]));
      }
    } catch (err) {
      hilog.error(0x0001, 'CloudSync', '[CloudStore] relay raw accounts JSON 解析失败: ' + JSON.stringify(err));
    }
    return accounts;
  }

  private relayToBucket(relay: RustDeskRelayConfig): relationalStore.ValuesBucket {
    const crypto = DataCrypto.getInstance();
    const vb: relationalStore.ValuesBucket = {} as relationalStore.ValuesBucket;
    vb['id'] = relay.id;
    vb['userid'] = relay.userId;
    vb['idserver'] = relay.idServer;
    vb['idserverport'] = relay.idServerPort;
    vb['relayserver'] = relay.relayServer;
    vb['relayport'] = relay.relayPort;
    vb['apiserver'] = relay.apiServer;
    vb['apiusername'] = relay.apiUsername;
    vb['apipassword'] = this.encryptIfReady(crypto, relay.apiPassword);
    vb['key'] = this.encryptIfReady(crypto, relay.key);
    vb['healthstatus'] = relay.healthStatus;
    vb['healthlatency'] = relay.healthLatency;
    vb['healthcheckedat'] = relay.healthCheckedAt;
    vb['apiloginstatus'] = relay.apiLoginStatus;
    vb['accountsjson'] = this.relayAccountsToJson(relay);
    vb['syncversion'] = relay.syncVersion;
    vb['updatedat'] = relay.updatedAt;
    return vb;
  }

  private relayToBucketRaw(relay: RustDeskRelayConfig): relationalStore.ValuesBucket {
    const items: RustDeskAccountJSON[] = [];
    for (let i = 0; i < relay.accounts.length; i++) {
      items.push(relay.accounts[i].toJSON());
    }
    const vb: relationalStore.ValuesBucket = {} as relationalStore.ValuesBucket;
    vb['id'] = relay.id;
    vb['userid'] = relay.userId;
    vb['idserver'] = relay.idServer;
    vb['idserverport'] = relay.idServerPort;
    vb['relayserver'] = relay.relayServer;
    vb['relayport'] = relay.relayPort;
    vb['apiserver'] = relay.apiServer;
    vb['apiusername'] = relay.apiUsername;
    vb['apipassword'] = relay.apiPassword;
    vb['key'] = relay.key;
    vb['healthstatus'] = relay.healthStatus;
    vb['healthlatency'] = relay.healthLatency;
    vb['healthcheckedat'] = relay.healthCheckedAt;
    vb['apiloginstatus'] = relay.apiLoginStatus;
    vb['accountsjson'] = JSON.stringify(items);
    vb['syncversion'] = relay.syncVersion;
    vb['updatedat'] = relay.updatedAt;
    return vb;
  }

  upsertRelay(relay: RustDeskRelayConfig): boolean {
    if (!this.store) { return this.setLastMutation(DataMutationResult.failure(relay.id, 'not_ready', '本地数据库未就绪')); }
    if (!this.localMutationAllowed()) {
      return this.setLastMutation(DataMutationResult.failure(relay.id, 'restore_in_progress', '恢复进行中，暂不能保存'));
    }
    if (!this.sensitiveWriteAllowed(relay.id)) { return false; }
    let code = 'local_write_failed';
    try {
      this.store.beginTransaction();
      if (!this.upsertRelayLocalInternal(relay, true)) { code = 'local_write_failed'; throw new Error('relay upsert failed'); }
      if (!this.recordLocalMutation('rustdeskrelays', relay.id, 'upsert')) {
        code = 'journal_write_failed'; throw new Error('relay journal failed');
      }
      this.store.commit();
      this.setLastMutation(DataMutationResult.success(relay.id));
      this.syncRelaysToCloud();
      return true;
    } catch (err) {
      try { this.store.rollBack(); } catch (_ignored) {}
      hilog.error(0x0001, 'CloudSync', '[CloudStore] upsertRelay transaction failed: ' + safeError(err));
      return this.setLastMutation(DataMutationResult.failure(relay.id, code as 'local_write_failed' |
        'journal_write_failed', 'RustDesk 中继保存未完成'));
    }
  }

  deleteRelay(id: string): boolean {
    if (!this.store) { return this.setLastMutation(DataMutationResult.failure(id, 'not_ready', '本地数据库未就绪')); }
    if (!this.localMutationAllowed()) {
      return this.setLastMutation(DataMutationResult.failure(id, 'restore_in_progress', '恢复进行中，暂不能删除'));
    }
    if (!this.sensitiveWriteAllowed(id)) { return false; }
    let code = 'local_write_failed';
    try {
      this.store.beginTransaction();
      const predicates = new relationalStore.RdbPredicates('rustdeskrelays');
      predicates.equalTo('id', id);
      if (!rdbSingleRowAffected(this.store.deleteSync(predicates))) { code = 'not_found'; throw new Error('relay delete failed'); }
      if (!this.recordLocalMutation('rustdeskrelays', id, 'delete')) {
        code = 'journal_write_failed'; throw new Error('relay journal failed');
      }
      this.store.commit();
      this.setLastMutation(DataMutationResult.success(id));
      this.syncRelaysToCloud();
      return true;
    } catch (err) {
      try { this.store.rollBack(); } catch (_ignored) {}
      hilog.error(0x0001, 'CloudSync', '[CloudStore] deleteRelay transaction failed: ' + safeError(err));
      return this.setLastMutation(DataMutationResult.failure(id, code as 'local_write_failed' |
        'not_found' | 'journal_write_failed', 'RustDesk 中继删除未完成'));
    }
  }

  loadAllRelays(): RustDeskRelayConfig[] {
    // 分布式表已完成端云合并；读取时绝不再把旧 JSON 反向写回云端。
    return this.loadAllRelaysLocal();
  }

  // ---- 本地 CRUD (不触发云同步, 供内部和 sync 方法使用) ----

  upsertRelayLocal(relay: RustDeskRelayConfig): boolean {
    if (!this.localMutationAllowed()) { return false; }
    return this.upsertRelayLocalInternal(relay, true);
  }

  private upsertRelayLocalInternal(relay: RustDeskRelayConfig, encrypt: boolean): boolean {
    if (!this.store) { return false; }
    try {
      const updatedAt: number = Date.now();
      relay.updatedAt = updatedAt;
      const vb = encrypt ? this.relayToBucket(relay) : this.relayToBucketRaw(relay);
      vb['updatedat'] = updatedAt;
      const predicates = new relationalStore.RdbPredicates('rustdeskrelays');
      predicates.equalTo('id', relay.id);
      const rs = this.store.querySync(predicates);
      const exists: boolean = rs.rowCount > 0;
      rs.close();
      if (exists) {
        return rdbSingleRowAffected(this.store.updateSync(vb, predicates));
      } else {
        vb['createdat'] = Date.now();
        return rdbInsertSucceeded(this.store.insertSync('rustdeskrelays', vb));
      }
    } catch (err) {
      hilog.error(0x0001, 'CloudSync', '[CloudStore] upsertRelay 失败: ' + JSON.stringify(err));
      return false;
    }
  }

  deleteRelayLocal(id: string): boolean {
    if (!this.localMutationAllowed() || !this.store) { return false; }
    try {
      const predicates = new relationalStore.RdbPredicates('rustdeskrelays');
      predicates.equalTo('id', id);
      return rdbSingleRowAffected(this.store.deleteSync(predicates));
    } catch (err) {
      hilog.error(0x0001, 'CloudSync', '[CloudStore] deleteRelay 失败: ' + JSON.stringify(err));
      return false;
    }
  }

  loadAllRelaysLocal(): RustDeskRelayConfig[] {
    return this.loadAllRelaysLocalInternal(true);
  }

  private loadAllRelaysLocalInternal(decrypt: boolean): RustDeskRelayConfig[] {
    const result: RustDeskRelayConfig[] = [];
    if (!this.store) { return result; }
    try {
      const predicates = new relationalStore.RdbPredicates('rustdeskrelays');
      const rs = this.store.querySync(predicates);
      while (rs.goToNextRow()) {
        const crypto = DataCrypto.getInstance();
        const relay = new RustDeskRelayConfig();
        relay.id = rs.getString(rs.getColumnIndex('id'));
        relay.userId = rs.getString(rs.getColumnIndex('userid'));
        relay.idServer = rs.getString(rs.getColumnIndex('idserver'));
        relay.idServerPort = rs.getLong(rs.getColumnIndex('idserverport'));
        relay.relayServer = rs.getString(rs.getColumnIndex('relayserver'));
        relay.relayPort = rs.getLong(rs.getColumnIndex('relayport'));
        relay.apiServer = rs.getString(rs.getColumnIndex('apiserver'));
        relay.apiUsername = rs.getString(rs.getColumnIndex('apiusername'));
        const apiPassword: string = rs.getString(rs.getColumnIndex('apipassword'));
        const key: string = rs.getString(rs.getColumnIndex('key'));
        relay.apiPassword = decrypt ? this.decryptIfReady(crypto, apiPassword) : apiPassword;
        relay.key = decrypt ? this.decryptIfReady(crypto, key) : key;
        relay.healthStatus = rs.getString(rs.getColumnIndex('healthstatus'));
        relay.healthLatency = rs.getLong(rs.getColumnIndex('healthlatency'));
        relay.healthCheckedAt = rs.getLong(rs.getColumnIndex('healthcheckedat'));
        relay.apiLoginStatus = rs.getString(rs.getColumnIndex('apiloginstatus'));
        const accountsColumn: number = rs.getColumnIndex('accountsjson');
        if (accountsColumn >= 0) {
        relay.accounts = decrypt ? this.relayAccountsFromJson(rs.getString(accountsColumn)) : this.relayAccountsFromJsonRaw(rs.getString(accountsColumn));
        }
        relay.syncVersion = rs.getLong(rs.getColumnIndex('syncversion'));
        relay.createdAt = rs.getLong(rs.getColumnIndex('createdat'));
        const updatedAtColumn: number = rs.getColumnIndex('updatedat');
        relay.updatedAt = updatedAtColumn >= 0 ? rs.getLong(updatedAtColumn) : 0;
        result.push(relay);
      }
      rs.close();
    } catch (err) {
      hilog.error(0x0001, 'CloudSync', '[CloudStore] loadAllRelays 失败: ' + JSON.stringify(err));
    }
    return result;
  }

  /** @deprecated Compatibility entry point; still uses the sole coordinator. */
  syncHosts(_userId: string, callback?: () => void): void {
    CloudSyncCoordinator.getInstance().requestAutomaticPush('remotehosts')
      .then((result): void => { if (result.ok && callback) { callback(); } });
  }

  private hostToBucket(h: RemoteHost): relationalStore.ValuesBucket {
    h.normalizeRdpAuthentication();
    const crypto = DataCrypto.getInstance();
    const vb: relationalStore.ValuesBucket = {};
    vb['id'] = h.id;
    vb['userid'] = h.userId;
    vb['label'] = h.label;
    vb['protocol'] = h.protocol;
    vb['host'] = h.host;
    vb['port'] = h.port;
    vb['username'] = h.username;
    // `passward` is the immutable existing cloud contract. `password` is a
    // retired local shadow and must never be populated again.
    vb['passward'] = this.encryptIfReady(crypto, h.password);
    vb['customhostname'] = h.customHostname;
    vb['sshusekey'] = h.sshUseKey ? 1 : 0;
    vb['sshkeypath'] = h.sshKeyPath;
    vb['sshkeydata'] = this.encryptIfReady(crypto, h.sshKeyData);
    vb['sshkeypassphrase'] = this.encryptIfReady(crypto, h.sshKeyPassphrase);
    vb['sshkeyid'] = h.sshKeyId;
    vb['sshhostkeyalgorithm'] = h.sshHostKeyAlgorithm;
    vb['sshhostkeyfingerprintsha256'] = h.sshHostKeyFingerprintSha256;
    vb['sshhostkeyrawbase64'] = h.sshHostKeyRawBase64;
    vb['sshhostkeytrustedat'] = h.sshHostKeyTrustedAt;
    vb['sshhostkeytrustmode'] = h.sshHostKeyTrustMode;
    vb['rdpcertificatefingerprintsha256'] = h.rdpCertificateFingerprintSha256;
    vb['rdpcertificatesubject'] = h.rdpCertificateSubject;
    vb['rdpcertificateissuer'] = h.rdpCertificateIssuer;
    vb['rdpcertificatecommonname'] = h.rdpCertificateCommonName;
    vb['rdpcertificatetrustedat'] = h.rdpCertificateTrustedAt;
    vb['rdpcertificatetrustmode'] = h.rdpCertificateTrustMode;
    vb['rdpcertificateallowuntrustedroot'] = h.rdpCertificateAllowUntrustedRoot ? 1 : 0;
    vb['rdpcertificateallowhostmismatch'] = h.rdpCertificateAllowHostMismatch ? 1 : 0;
    vb['proxyhost'] = h.proxyHost;
    vb['proxyport'] = h.proxyPort;
    vb['proxyusername'] = h.proxyUsername;
    vb['gatewayhost'] = h.gatewayHost;
    vb['gatewayport'] = h.gatewayPort;
    vb['displayconfig'] = encodeRemoteHostDisplayPayload(
      JSON.stringify(h.displayConfig.toJSON()),
      projectRemoteHostCloudExtension(this.hostCloudExtensionValues(h))
    );
    vb['locked'] = h.locked ? 1 : 0;
    vb['locktype'] = h.lockType;
    vb['groupid'] = h.groupId;
    vb['sortorder'] = h.sortOrder;
    vb['icon'] = h.icon;
    vb['lastconnected'] = h.lastConnected;
    vb['lasthealth'] = h.lastHealth;
    vb['lastlatency'] = h.lastLatency;
    vb['rustdeskrelayid'] = h.rustdeskRelayId;
    vb['rustdeskaccountid'] = h.rustdeskAccountId;
    vb['rustdeskpasswordmode'] = h.rustdeskPasswordMode;
    vb['rustdeskauthmode'] = h.rustdeskAuthMode;
    vb['rustdeskdirectenabled'] = h.rustdeskDirectEnabled ? 1 : 0;
    vb['rustdeskdirecthost'] = h.rustdeskDirectHost;
    vb['rustdeskdirectport'] = h.rustdeskDirectPort;
    vb['rdpcredentialid'] = h.rdpCredentialId;
    vb['sourcetype'] = h.sourceType;
    vb['rustdeskproaccountid'] = h.rustdeskProAccountId;
    vb['rustdeskpropeerid'] = h.rustdeskProPeerId;
    vb['rustdeskproplatform'] = h.rustdeskProPlatform;
    vb['rustdeskpromanaged'] = h.rustdeskProManaged ? 1 : 0;
    vb['rustdeskprolastseenat'] = h.rustdeskProLastSeenAt;
    vb['rustdeskprosyncerror'] = h.rustdeskProSyncError;
    vb['syncversion'] = h.syncVersion;
    vb['createdat'] = h.createdAt;
    return this.cloudBucket('remotehosts', vb);
  }

  private rowToHost(rs: relationalStore.ResultSet): RemoteHost {
    const crypto = DataCrypto.getInstance();
    // 安全读取: 列不存在时返回空字符串, 不抛异常
    const getStr = (col: string): string => {
      const idx: number = rs.getColumnIndex(col);
      return idx >= 0 ? rs.getString(idx) : '';
    };
    const h = new RemoteHost();
    h.id = getStr('id');
    h.userId = getStr('userid');
    h.label = getStr('label');
    h.protocol = getStr('protocol');
    h.host = getStr('host');
    h.port = rs.getLong(rs.getColumnIndex('port'));
    h.username = getStr('username');
    h.password = this.decryptIfReady(crypto, getStr('passward') || getStr('password'));
    h.customHostname = getStr('customhostname');
    h.sshUseKey = rs.getLong(rs.getColumnIndex('sshusekey')) !== 0;
    h.sshKeyPath = getStr('sshkeypath');
    h.sshKeyData = this.decryptIfReady(crypto, getStr('sshkeydata'));
    h.sshKeyPassphrase = this.decryptIfReady(crypto, getStr('sshkeypassphrase'));
    h.sshKeyId = getStr('sshkeyid');
    h.sshHostKeyAlgorithm = getStr('sshhostkeyalgorithm');
    h.sshHostKeyFingerprintSha256 = getStr('sshhostkeyfingerprintsha256');
    h.sshHostKeyRawBase64 = getStr('sshhostkeyrawbase64');
    h.sshHostKeyTrustedAt = rs.getLong(rs.getColumnIndex('sshhostkeytrustedat'));
    const hkTrustIdx: number = rs.getColumnIndex('sshhostkeytrustmode');
    h.sshHostKeyTrustMode = hkTrustIdx >= 0 ? rs.getLong(hkTrustIdx) : 0;
    h.rdpCertificateFingerprintSha256 = getStr('rdpcertificatefingerprintsha256');
    h.rdpCertificateSubject = getStr('rdpcertificatesubject');
    h.rdpCertificateIssuer = getStr('rdpcertificateissuer');
    h.rdpCertificateCommonName = getStr('rdpcertificatecommonname');
    const rdpCertTrustedAtIdx: number = rs.getColumnIndex('rdpcertificatetrustedat');
    h.rdpCertificateTrustedAt = rdpCertTrustedAtIdx >= 0 ? rs.getLong(rdpCertTrustedAtIdx) : 0;
    const rdpCertTrustModeIdx: number = rs.getColumnIndex('rdpcertificatetrustmode');
    h.rdpCertificateTrustMode = rdpCertTrustModeIdx >= 0 ? rs.getLong(rdpCertTrustModeIdx) : 0;
    const allowRootIdx: number = rs.getColumnIndex('rdpcertificateallowuntrustedroot');
    h.rdpCertificateAllowUntrustedRoot = allowRootIdx >= 0 && rs.getLong(allowRootIdx) === 1;
    const allowMismatchIdx: number = rs.getColumnIndex('rdpcertificateallowhostmismatch');
    h.rdpCertificateAllowHostMismatch = allowMismatchIdx >= 0 && rs.getLong(allowMismatchIdx) === 1;
    h.proxyHost = rs.getString(rs.getColumnIndex('proxyhost'));
    h.proxyPort = rs.getLong(rs.getColumnIndex('proxyport'));
    h.proxyUsername = rs.getString(rs.getColumnIndex('proxyusername'));
    h.gatewayHost = rs.getString(rs.getColumnIndex('gatewayhost'));
    h.gatewayPort = rs.getLong(rs.getColumnIndex('gatewayport'));
    const dcJson: string = rs.getString(rs.getColumnIndex('displayconfig'));
    const displayPayload: RemoteHostDisplayPayload = decodeRemoteHostDisplayPayload(dcJson);
    if (displayPayload.displayConfigJson) {
      try {
        h.displayConfig = DisplayConfig.fromJSON(
          JSON.parse(displayPayload.displayConfigJson) as DisplayConfigJSON);
      }
      catch (_err) { /* keep default */ }
    }
    h.locked = rs.getLong(rs.getColumnIndex('locked')) !== 0;
    h.lockType = rs.getLong(rs.getColumnIndex('locktype'));
    h.groupId = rs.getString(rs.getColumnIndex('groupid'));
    h.sortOrder = rs.getLong(rs.getColumnIndex('sortorder'));
    h.icon = rs.getString(rs.getColumnIndex('icon'));
    h.lastConnected = rs.getLong(rs.getColumnIndex('lastconnected'));
    h.lastHealth = rs.getLong(rs.getColumnIndex('lasthealth'));
    h.lastLatency = rs.getLong(rs.getColumnIndex('lastlatency'));
    h.rustdeskRelayId = getStr('rustdeskrelayid');
    h.rustdeskAccountId = getStr('rustdeskaccountid');
    const rdPwdModeIdx: number = rs.getColumnIndex('rustdeskpasswordmode');
    h.rustdeskPasswordMode = rdPwdModeIdx >= 0 && rs.getLong(rdPwdModeIdx) === 1 ? 1 : 0;
    const rdAuthModeIdx: number = rs.getColumnIndex('rustdeskauthmode');
    h.rustdeskAuthMode = rdAuthModeIdx >= 0 && rs.getString(rdAuthModeIdx) === 'request_approval' ?
      'request_approval' : 'password';
    const rdDirectEnabledIdx: number = rs.getColumnIndex('rustdeskdirectenabled');
    h.rustdeskDirectEnabled = rdDirectEnabledIdx >= 0 && rs.getLong(rdDirectEnabledIdx) === 1;
    h.rustdeskDirectHost = getStr('rustdeskdirecthost');
    const rdDirectPortIdx: number = rs.getColumnIndex('rustdeskdirectport');
    h.rustdeskDirectPort = rdDirectPortIdx >= 0 ? rs.getLong(rdDirectPortIdx) : 21118;
    h.rdpCredentialId = getStr('rdpcredentialid');
    h.sourceType = getStr('sourcetype') || 'manual';
    h.rustdeskProAccountId = getStr('rustdeskproaccountid');
    h.rustdeskProPeerId = getStr('rustdeskpropeerid');
    h.rustdeskProPlatform = getStr('rustdeskproplatform');
    const rdProManagedIdx: number = rs.getColumnIndex('rustdeskpromanaged');
    h.rustdeskProManaged = rdProManagedIdx >= 0 && rs.getLong(rdProManagedIdx) === 1;
    const rdProLastSeenIdx: number = rs.getColumnIndex('rustdeskprolastseenat');
    h.rustdeskProLastSeenAt = rdProLastSeenIdx >= 0 ? rs.getLong(rdProLastSeenIdx) : 0;
    h.rustdeskProSyncError = getStr('rustdeskprosyncerror');
    h.syncVersion = rs.getLong(rs.getColumnIndex('syncversion'));
    h.createdAt = rs.getLong(rs.getColumnIndex('createdat'));
    this.applyCloudHostExtension(h, displayPayload.extension);
    return h;
  }

  private rdpCredentialToBucket(credential: RdpCredential): relationalStore.ValuesBucket {
    const crypto = DataCrypto.getInstance();
    const vb: relationalStore.ValuesBucket = {};
    vb['id'] = credential.id;
    vb['label'] = credential.label;
    vb['username'] = credential.username;
    vb['password'] = this.encryptIfReady(crypto, credential.password);
    vb['createdat'] = credential.createdAt;
    return this.cloudBucket('rdpcredentials', vb);
  }

  private relayToCloudJson(relay: RustDeskRelayConfig): RustDeskRelayJSON {
    const crypto = DataCrypto.getInstance();
    const json: RustDeskRelayJSON = relay.toJSON();
    json.apiPassword = this.encryptIfReady(crypto, json.apiPassword);
    json.key = this.encryptIfReady(crypto, json.key);
    for (let i = 0; i < json.accounts.length; i++) {
      json.accounts[i].password = this.encryptIfReady(crypto, json.accounts[i].password);
    }
    return json;
  }

  private relayFromCloudJson(json: RustDeskRelayJSON): RustDeskRelayConfig {
    const crypto = DataCrypto.getInstance();
    const copied: RustDeskRelayJSON = {
      id: json.id,
      userId: json.userId,
      idServer: json.idServer,
      idServerPort: json.idServerPort,
      relayServer: json.relayServer,
      relayPort: json.relayPort,
      apiServer: json.apiServer,
      apiUsername: json.apiUsername,
      apiPassword: this.decryptIfReady(crypto, json.apiPassword),
      key: this.decryptIfReady(crypto, json.key),
      healthStatus: json.healthStatus,
      healthLatency: json.healthLatency,
      healthCheckedAt: json.healthCheckedAt,
      apiLoginStatus: json.apiLoginStatus,
      accounts: [],
      syncVersion: json.syncVersion,
      createdAt: json.createdAt,
      updatedAt: json.updatedAt ?? 0
    };
    if (json.accounts) {
      for (let i = 0; i < json.accounts.length; i++) {
        const account: RustDeskAccountJSON = {
          id: json.accounts[i].id,
          relayId: json.accounts[i].relayId,
          username: json.accounts[i].username,
          password: this.decryptIfReady(crypto, json.accounts[i].password),
          loginStatus: json.accounts[i].loginStatus,
          lastLoginAt: json.accounts[i].lastLoginAt,
          createdAt: json.accounts[i].createdAt
        };
        copied.accounts.push(account);
      }
    }
    return RustDeskRelayConfig.fromJSON(copied);
  }

  private encryptIfReady(crypto: DataCrypto, value: string): string {
    if (value === '') { return value; }
    if (crypto.isEncrypted(value)) { return value; }
    if (sensitiveWriteRequiresUnlock(crypto.isSetupComplete(), crypto.isReady())) {
      throw new Error('unlock_required');
    }
    return crypto.isReady() ? crypto.encrypt(value) : value;
  }

  private decryptIfReady(crypto: DataCrypto, value: string): string {
    if (value === '') { return value; }
    // A locked configured store must never expose ciphertext as though it were
    // usable plaintext. Redact both envelopes and legacy clear values until
    // the user supplies the master password.
    if (shouldRedactLockedCiphertext(crypto.isSetupComplete(), crypto.isReady(), crypto.isEncrypted(value)) ||
      (crypto.isSetupComplete() && !crypto.isReady())) {
      return '';
    }
    return crypto.isReady() ? crypto.decrypt(value) : value;
  }

  private rdpCredentialToBucketRaw(credential: RdpCredential): relationalStore.ValuesBucket {
    const vb: relationalStore.ValuesBucket = {};
    vb['id'] = credential.id;
    vb['label'] = credential.label;
    vb['username'] = credential.username;
    vb['password'] = credential.password;
    vb['createdat'] = credential.createdAt;
    return this.cloudBucket('rdpcredentials', vb);
  }

  private rowToRdpCredential(rs: relationalStore.ResultSet): RdpCredential {
    const crypto = DataCrypto.getInstance();
    const getStr = (col: string): string => {
      const idx: number = rs.getColumnIndex(col);
      return idx >= 0 ? rs.getString(idx) : '';
    };
    const getLong = (col: string): number => {
      const idx: number = rs.getColumnIndex(col);
      return idx >= 0 ? rs.getLong(idx) : 0;
    };
    const credential = new RdpCredential();
    credential.id = getStr('id');
    credential.label = getStr('label');
    credential.username = getStr('username');
    credential.password = this.decryptIfReady(crypto, getStr('password'));
    credential.createdAt = getLong('createdat');
    return credential;
  }

  private rowToRdpCredentialRaw(rs: relationalStore.ResultSet): RdpCredential {
    const getStr = (col: string): string => {
      const idx: number = rs.getColumnIndex(col);
      return idx >= 0 ? rs.getString(idx) : '';
    };
    const getLong = (col: string): number => {
      const idx: number = rs.getColumnIndex(col);
      return idx >= 0 ? rs.getLong(idx) : 0;
    };
    const credential = new RdpCredential();
    credential.id = getStr('id');
    credential.label = getStr('label');
    credential.username = getStr('username');
    credential.password = getStr('password');
    credential.createdAt = getLong('createdat');
    return credential;
  }

  // ==================== SshKey CRUD ====================

  loadAllSshKeys(): SshKey[] {
    if (!this.store) { return []; }
    try {
      const predicates = new relationalStore.RdbPredicates('sshkeys');
      predicates.orderByDesc('createdat');
      const rs = this.store.querySync(predicates);
      const result: SshKey[] = [];
      while (rs.goToNextRow()) {
        const dfIdx: number = rs.getColumnIndex(relationalStore.Field.DELETED_FLAG_FIELD);
        if (dfIdx >= 0 && rs.getLong(dfIdx) === 1) { continue; }
        result.push(this.mergeSshKeyExtension(this.rowToSshKey(rs)));
      }
      rs.close();
      return result;
    } catch (err) {
      hilog.error(0x0001, 'CloudSync', '[CloudStore] loadAllSshKeys 失败: ' + JSON.stringify(err));
      return [];
    }
  }

  insertSshKey(key: SshKey): boolean {
    if (!this.store) { return this.setLastMutation(DataMutationResult.failure(key.id, 'not_ready', '本地数据库未就绪')); }
    if (!this.localMutationAllowed()) {
      return this.setLastMutation(DataMutationResult.failure(key.id, 'restore_in_progress', '恢复进行中，暂不能保存'));
    }
    if (!this.sensitiveWriteAllowed(key.id)) { return false; }
    let code = 'local_write_failed';
    try {
      this.store.beginTransaction();
      const vb = this.sshKeyToBucket(key);
      vb['createdat'] = Date.now();
      vb['updatedat'] = Date.now();
      if (!rdbInsertSucceeded(this.store.insertSync('sshkeys', vb))) { code = 'local_write_failed'; throw new Error('ssh key insert failed'); }
      if (!this.saveSshKeyExtension(key)) { code = 'extension_write_failed'; throw new Error('ssh key extension insert failed'); }
      if (!this.recordLocalMutation('sshkeys', key.id, 'add')) { code = 'journal_write_failed'; throw new Error('ssh key journal failed'); }
      this.store.commit();
      hilog.info(0x0001, 'CloudSync', "insertSshKey: " + key.label + " (" + key.id + ")");
      return this.setLastMutation(DataMutationResult.success(key.id));
    } catch (err) {
      try { this.store.rollBack(); } catch (_ignored) {}
      hilog.error(0x0001, 'CloudSync', '[CloudStore] insertSshKey 失败: ' + JSON.stringify(err));
      return this.setLastMutation(DataMutationResult.failure(key.id, code as 'local_write_failed' |
        'extension_write_failed' | 'journal_write_failed', 'SSH 密钥保存未完成'));
    }
  }

  updateSshKey(key: SshKey): boolean {
    if (!this.store) { return this.setLastMutation(DataMutationResult.failure(key.id, 'not_ready', '本地数据库未就绪')); }
    if (!this.localMutationAllowed()) {
      return this.setLastMutation(DataMutationResult.failure(key.id, 'restore_in_progress', '恢复进行中，暂不能保存'));
    }
    if (!this.sensitiveWriteAllowed(key.id)) { return false; }
    let code = 'local_write_failed';
    try {
      this.store.beginTransaction();
      const vb = this.sshKeyToBucket(key);
      vb['updatedat'] = Date.now();
      const predicates = new relationalStore.RdbPredicates('sshkeys');
      predicates.equalTo('id', key.id);
      if (!rdbSingleRowAffected(this.store.updateSync(vb, predicates))) { code = 'not_found'; throw new Error('ssh key update failed'); }
      if (!this.saveSshKeyExtension(key)) { code = 'extension_write_failed'; throw new Error('ssh key extension update failed'); }
      if (!this.recordLocalMutation('sshkeys', key.id, 'update')) { code = 'journal_write_failed'; throw new Error('ssh key journal failed'); }
      this.store.commit();
      hilog.info(0x0001, 'CloudSync', "updateSshKey: " + key.label + " (" + key.id + ")");
      return this.setLastMutation(DataMutationResult.success(key.id));
    } catch (err) {
      try { this.store.rollBack(); } catch (_ignored) {}
      hilog.error(0x0001, 'CloudSync', '[CloudStore] updateSshKey 失败: ' + JSON.stringify(err));
      return this.setLastMutation(DataMutationResult.failure(key.id, code as 'local_write_failed' |
        'not_found' | 'extension_write_failed' | 'journal_write_failed', 'SSH 密钥更新未完成'));
    }
  }

  deleteSshKey(id: string): boolean {
    if (!this.store) { return this.setLastMutation(DataMutationResult.failure(id, 'not_ready', '本地数据库未就绪')); }
    if (!this.localMutationAllowed()) {
      return this.setLastMutation(DataMutationResult.failure(id, 'restore_in_progress', '恢复进行中，暂不能删除'));
    }
    if (!this.sensitiveWriteAllowed(id)) { return false; }
    let code = 'local_write_failed';
    try {
      this.store.beginTransaction();
      const predicates = new relationalStore.RdbPredicates('sshkeys');
      predicates.equalTo('id', id);
      if (!rdbSingleRowAffected(this.store.deleteSync(predicates))) { code = 'not_found'; throw new Error('ssh key delete failed'); }
      if (!this.deleteLocalExtension('sshkeys', id)) { code = 'extension_write_failed'; throw new Error('ssh key extension delete failed'); }
      if (!this.recordLocalMutation('sshkeys', id, 'delete')) { code = 'journal_write_failed'; throw new Error('ssh key journal failed'); }
      this.store.commit();
      hilog.info(0x0001, 'CloudSync', "deleteSshKey: " + id);
      return this.setLastMutation(DataMutationResult.success(id));
    } catch (err) {
      try { this.store.rollBack(); } catch (_ignored) {}
      hilog.error(0x0001, 'CloudSync', '[CloudStore] deleteSshKey 失败: ' + JSON.stringify(err));
      return this.setLastMutation(DataMutationResult.failure(id, code as 'local_write_failed' |
        'not_found' | 'extension_write_failed' | 'journal_write_failed', 'SSH 密钥删除未完成'));
    }
  }

  /** @deprecated Compatibility entry point; still uses the sole coordinator. */
  syncSshKeys(_userId: string): void {
    CloudSyncCoordinator.getInstance().requestAutomaticPush('sshkeys');
  }

  private sshKeyToBucket(k: SshKey): relationalStore.ValuesBucket {
    const crypto = DataCrypto.getInstance();
    const vb: relationalStore.ValuesBucket = {};
    vb['id'] = k.id;
    vb['userid'] = k.userId;
    vb['label'] = k.label;
    vb['keytype'] = k.keyType;
    vb['publickey'] = k.publicKey;
    vb['privatekey'] = this.encryptIfReady(crypto, k.privateKey);
    vb['fingerprint'] = k.fingerprint;
    vb['comment'] = k.comment;
    vb['locked'] = k.locked ? 1 : 0;
    vb['locktype'] = k.lockType;
    vb['syncversion'] = k.syncVersion;
    vb['createdat'] = k.createdAt;
    vb['formatversion'] = k.formatVersion;
    vb['privatekeyencrypted'] = k.privateKeyEncrypted ? 1 : 0;
    return this.cloudBucket('sshkeys', vb);
  }

  private rowToSshKey(rs: relationalStore.ResultSet): SshKey {
    const crypto = DataCrypto.getInstance();
    const getStr = (col: string): string => rs.getString(rs.getColumnIndex(col));
    const k = new SshKey();
    k.id = getStr('id');
    k.userId = getStr('userid');
    k.label = getStr('label');
    k.keyType = rs.getLong(rs.getColumnIndex('keytype'));
    k.publicKey = getStr('publickey');
    k.privateKey = this.decryptIfReady(crypto, getStr('privatekey'));
    k.fingerprint = getStr('fingerprint');
    k.comment = getStr('comment');
    k.locked = rs.getLong(rs.getColumnIndex('locked')) !== 0;
    k.lockType = rs.getLong(rs.getColumnIndex('locktype'));
    k.syncVersion = rs.getLong(rs.getColumnIndex('syncversion'));
    k.createdAt = rs.getLong(rs.getColumnIndex('createdat'));
    const formatIndex: number = rs.getColumnIndex('formatversion');
    const encryptedIndex: number = rs.getColumnIndex('privatekeyencrypted');
    k.formatVersion = formatIndex >= 0 ? rs.getLong(formatIndex) : 0;
    k.privateKeyEncrypted = encryptedIndex >= 0 && rs.getLong(encryptedIndex) !== 0;
    k.normalizeFormatMetadata();
    return k;
  }

  // ==================== Internal CRUD (for raw access) ====================

  private loadAllHostsInternal(decrypt: boolean): RemoteHost[] {
    if (!this.store) { return []; }
    try {
      const predicates = new relationalStore.RdbPredicates('remotehosts');
      predicates.orderByDesc('sortorder');
      const rs: relationalStore.ResultSet = this.store.querySync(predicates);
      const rowCount: number = rs.rowCount;
      const result: RemoteHost[] = [];
      const dfIdx: number = rs.getColumnIndex(relationalStore.Field.DELETED_FLAG_FIELD);
      hilog.info(0x0001, 'CloudSync',
        "loadAllHostsInternal: rowCount=" + rowCount.toString() + " dfIdx=" + dfIdx.toString());
      let skipped: number = 0;
      let loaded: number = 0;
      while (rs.goToNextRow()) {
        if (dfIdx >= 0) {
          const deleted: number = rs.getLong(dfIdx);
          if (deleted === 1) {
            skipped++;
            continue;
          }
        }
        try {
          const host: RemoteHost = decrypt ? this.rowToHost(rs) : this.rowToHostRaw(rs);
          result.push(this.mergeHostExtension(host));
          loaded++;
        } catch (rowErr) {
          const id: string = rs.getString(rs.getColumnIndex('id'));
          hilog.error(0x0001, 'CloudSync',
            "loadAllHostsInternal: rowToHost 失败 id=" + id + " err=" + DataCrypto.errDetail(rowErr));
        }
      }
      rs.close();
      hilog.info(0x0001, 'CloudSync',
        "loadAllHostsInternal: result=" + result.length.toString() + " loaded=" + loaded.toString() + " skipped=" + skipped.toString());
      return result;
    } catch (err) {
      hilog.error(0x0001, 'CloudSync', "loadAllHosts 失败: " + DataCrypto.errDetail(err));
      return [];
    }
  }

  private rowToHostRaw(rs: relationalStore.ResultSet): RemoteHost {
    const h = new RemoteHost();
    h.id = rs.getString(rs.getColumnIndex('id'));
    h.userId = rs.getString(rs.getColumnIndex('userid'));
    h.label = rs.getString(rs.getColumnIndex('label'));
    h.protocol = rs.getString(rs.getColumnIndex('protocol'));
    h.host = rs.getString(rs.getColumnIndex('host'));
    h.port = rs.getLong(rs.getColumnIndex('port'));
    h.username = rs.getString(rs.getColumnIndex('username'));
    const passwardIndex: number = rs.getColumnIndex('passward');
    const passwordIndex: number = rs.getColumnIndex('password');
    const canonicalPassword: string = passwardIndex >= 0 ? rs.getString(passwardIndex) : '';
    h.password = canonicalPassword !== '' ? canonicalPassword :
      (passwordIndex >= 0 ? rs.getString(passwordIndex) : ''); // raw
    h.customHostname = rs.getString(rs.getColumnIndex('customhostname'));
    h.sshUseKey = rs.getLong(rs.getColumnIndex('sshusekey')) !== 0;
    h.sshKeyPath = rs.getString(rs.getColumnIndex('sshkeypath'));
    h.sshKeyData = rs.getString(rs.getColumnIndex('sshkeydata')); // raw
    h.sshKeyPassphrase = rs.getString(rs.getColumnIndex('sshkeypassphrase')); // raw
    h.sshKeyId = rs.getString(rs.getColumnIndex('sshkeyid')); // raw
    h.proxyHost = rs.getString(rs.getColumnIndex('proxyhost'));
    h.proxyPort = rs.getLong(rs.getColumnIndex('proxyport'));
    h.proxyUsername = rs.getString(rs.getColumnIndex('proxyusername'));
    h.gatewayHost = rs.getString(rs.getColumnIndex('gatewayhost'));
    h.gatewayPort = rs.getLong(rs.getColumnIndex('gatewayport'));
    const dcJson = rs.getString(rs.getColumnIndex('displayconfig'));
    const displayPayload: RemoteHostDisplayPayload = decodeRemoteHostDisplayPayload(dcJson);
    if (displayPayload.displayConfigJson) {
      try {
        h.displayConfig = DisplayConfig.fromJSON(
          JSON.parse(displayPayload.displayConfigJson) as DisplayConfigJSON);
      }
      catch (_err) { /* keep default */ }
    }
    h.locked = rs.getLong(rs.getColumnIndex('locked')) !== 0;
    h.lockType = rs.getLong(rs.getColumnIndex('locktype'));
    h.groupId = rs.getString(rs.getColumnIndex('groupid'));
    h.sortOrder = rs.getLong(rs.getColumnIndex('sortorder'));
    h.icon = rs.getString(rs.getColumnIndex('icon'));
    h.lastConnected = rs.getLong(rs.getColumnIndex('lastconnected'));
    h.lastHealth = rs.getLong(rs.getColumnIndex('lasthealth'));
    h.lastLatency = rs.getLong(rs.getColumnIndex('lastlatency'));
    // RustDesk 字段 (列可能不存在 — 安全读取)
    const rdRelayIdx: number = rs.getColumnIndex('rustdeskrelayid');
    const rdAcctIdx: number = rs.getColumnIndex('rustdeskaccountid');
    const rdPwdModeIdx: number = rs.getColumnIndex('rustdeskpasswordmode');
    const rdpCredIdx: number = rs.getColumnIndex('rdpcredentialid');
    const rdDirectEnabledIdx2: number = rs.getColumnIndex('rustdeskdirectenabled');
    const rdDirectHostIdx2: number = rs.getColumnIndex('rustdeskdirecthost');
    const rdDirectPortIdx2: number = rs.getColumnIndex('rustdeskdirectport');
    h.rustdeskRelayId = rdRelayIdx >= 0 ? rs.getString(rdRelayIdx) : '';
    h.rustdeskAccountId = rdAcctIdx >= 0 ? rs.getString(rdAcctIdx) : '';
    h.rustdeskPasswordMode = rdPwdModeIdx >= 0 && rs.getLong(rdPwdModeIdx) === 1 ? 1 : 0;
    const rdAuthModeIdx: number = rs.getColumnIndex('rustdeskauthmode');
    h.rustdeskAuthMode = rdAuthModeIdx >= 0 && rs.getString(rdAuthModeIdx) === 'request_approval' ?
      'request_approval' : 'password';
    h.rustdeskDirectEnabled = rdDirectEnabledIdx2 >= 0 && rs.getLong(rdDirectEnabledIdx2) === 1;
    h.rustdeskDirectHost = rdDirectHostIdx2 >= 0 ? rs.getString(rdDirectHostIdx2) : '';
    h.rustdeskDirectPort = rdDirectPortIdx2 >= 0 ? rs.getLong(rdDirectPortIdx2) : 21118;
    h.rdpCredentialId = rdpCredIdx >= 0 ? rs.getString(rdpCredIdx) : '';
    const rdSourceTypeIdx: number = rs.getColumnIndex('sourcetype');
    const rdProAccountIdx: number = rs.getColumnIndex('rustdeskproaccountid');
    const rdProPeerIdx: number = rs.getColumnIndex('rustdeskpropeerid');
    const rdProPlatformIdx: number = rs.getColumnIndex('rustdeskproplatform');
    const rdProManagedIdx2: number = rs.getColumnIndex('rustdeskpromanaged');
    const rdProLastSeenIdx2: number = rs.getColumnIndex('rustdeskprolastseenat');
    const rdProSyncErrorIdx: number = rs.getColumnIndex('rustdeskprosyncerror');
    h.sourceType = rdSourceTypeIdx >= 0 ? rs.getString(rdSourceTypeIdx) || 'manual' : 'manual';
    h.rustdeskProAccountId = rdProAccountIdx >= 0 ? rs.getString(rdProAccountIdx) : '';
    h.rustdeskProPeerId = rdProPeerIdx >= 0 ? rs.getString(rdProPeerIdx) : '';
    h.rustdeskProPlatform = rdProPlatformIdx >= 0 ? rs.getString(rdProPlatformIdx) : '';
    h.rustdeskProManaged = rdProManagedIdx2 >= 0 && rs.getLong(rdProManagedIdx2) === 1;
    h.rustdeskProLastSeenAt = rdProLastSeenIdx2 >= 0 ? rs.getLong(rdProLastSeenIdx2) : 0;
    h.rustdeskProSyncError = rdProSyncErrorIdx >= 0 ? rs.getString(rdProSyncErrorIdx) : '';
    h.syncVersion = rs.getLong(rs.getColumnIndex('syncversion'));
    h.createdAt = rs.getLong(rs.getColumnIndex('createdat'));
    this.applyCloudHostExtension(h, displayPayload.extension);
    return h;
  }

  private loadAllSshKeysInternal(decrypt: boolean): SshKey[] {
    if (!this.store) { return []; }
    try {
      const predicates = new relationalStore.RdbPredicates('sshkeys');
      predicates.orderByDesc('createdat');
      const rs = this.store.querySync(predicates);
      const result: SshKey[] = [];
      const dfIdx: number = rs.getColumnIndex(relationalStore.Field.DELETED_FLAG_FIELD);
      while (rs.goToNextRow()) {
        if (dfIdx >= 0 && rs.getLong(dfIdx) === 1) { continue; }
        const key: SshKey = decrypt ? this.rowToSshKey(rs) : this.rowToSshKeyRaw(rs);
        result.push(this.mergeSshKeyExtension(key));
      }
      rs.close();
      return result;
    } catch (err) {
      hilog.error(0x0006, 'CloudStore', "loadAllSshKeys 失败: " + JSON.stringify(err));
      return [];
    }
  }

  private rowToSshKeyRaw(rs: relationalStore.ResultSet): SshKey {
    const k = new SshKey();
    k.id = rs.getString(rs.getColumnIndex('id'));
    k.userId = rs.getString(rs.getColumnIndex('userid'));
    k.label = rs.getString(rs.getColumnIndex('label'));
    k.keyType = rs.getLong(rs.getColumnIndex('keytype'));
    k.publicKey = rs.getString(rs.getColumnIndex('publickey'));
    k.privateKey = rs.getString(rs.getColumnIndex('privatekey')); // raw
    k.fingerprint = rs.getString(rs.getColumnIndex('fingerprint'));
    k.comment = rs.getString(rs.getColumnIndex('comment'));
    k.locked = rs.getLong(rs.getColumnIndex('locked')) !== 0;
    k.lockType = rs.getLong(rs.getColumnIndex('locktype'));
    k.syncVersion = rs.getLong(rs.getColumnIndex('syncversion'));
    k.createdAt = rs.getLong(rs.getColumnIndex('createdat'));
    const formatIndex: number = rs.getColumnIndex('formatversion');
    const encryptedIndex: number = rs.getColumnIndex('privatekeyencrypted');
    k.formatVersion = formatIndex >= 0 ? rs.getLong(formatIndex) : 0;
    k.privateKeyEncrypted = encryptedIndex >= 0 && rs.getLong(encryptedIndex) !== 0;
    k.normalizeFormatMetadata();
    return k;
  }

  private loadAllTotpEntriesInternal(decrypt: boolean): TotpEntry[] {
    if (!this.store) { return []; }
    try {
      const predicates = new relationalStore.RdbPredicates('totpentries');
      predicates.orderByDesc('createdat');
      const rs = this.store.querySync(predicates);
      const result: TotpEntry[] = [];
      const dfIdx: number = rs.getColumnIndex(relationalStore.Field.DELETED_FLAG_FIELD);
      while (rs.goToNextRow()) {
        if (dfIdx >= 0 && rs.getLong(dfIdx) === 1) { continue; }
        result.push(decrypt ? this.rowToTotpEntry(rs) : this.rowToTotpEntryRaw(rs));
      }
      rs.close();
      return result;
    } catch (err) {
      hilog.error(0x0006, 'CloudStore', "loadAllTotpEntries 失败: " + JSON.stringify(err));
      return [];
    }
  }

  private rowToTotpEntryRaw(rs: relationalStore.ResultSet): TotpEntry {
    const e = new TotpEntry();
    e.id = rs.getString(rs.getColumnIndex('id'));
    e.userId = rs.getString(rs.getColumnIndex('userid'));
    e.issuer = rs.getString(rs.getColumnIndex('issuer'));
    e.account = rs.getString(rs.getColumnIndex('account'));
    e.secret = rs.getString(rs.getColumnIndex('secret')); // raw
    e.algorithm = rs.getLong(rs.getColumnIndex('algorithm'));
    e.digits = rs.getLong(rs.getColumnIndex('digits'));
    e.period = rs.getLong(rs.getColumnIndex('period'));
    e.iconUrl = rs.getString(rs.getColumnIndex('iconurl'));
    e.locked = rs.getLong(rs.getColumnIndex('locked')) !== 0;
    e.lockType = rs.getLong(rs.getColumnIndex('locktype'));
    e.syncVersion = rs.getLong(rs.getColumnIndex('syncversion'));
    e.createdAt = rs.getLong(rs.getColumnIndex('createdat'));
    return e;
  }

  private updateHostInternal(host: RemoteHost, encrypt: boolean): boolean {
    if (!this.store) { return false; }
    try {
      let vb: relationalStore.ValuesBucket;
      if (encrypt) {
        vb = this.hostToBucket(host);
      } else {
        vb = this.hostToBucketRaw(host);
      }
      vb['updatedat'] = Date.now();
      const predicates = new relationalStore.RdbPredicates('remotehosts');
      predicates.equalTo('id', host.id);
      const updated: boolean = rdbSingleRowAffected(this.store.updateSync(vb, predicates));
      if (!updated) { return false; }
      return this.saveHostExtension(host);
    } catch (err) {
      hilog.error(0x0006, 'CloudStore', "updateHost 失败: " + JSON.stringify(err));
      return false;
    }
  }

  private hostToBucketRaw(h: RemoteHost): relationalStore.ValuesBucket {
    h.normalizeRdpAuthentication();
    const vb: relationalStore.ValuesBucket = {};
    vb['id'] = h.id; vb['userid'] = h.userId; vb['label'] = h.label;
    vb['protocol'] = h.protocol; vb['host'] = h.host; vb['port'] = h.port;
    vb['username'] = h.username; vb['passward'] = h.password;
    vb['customhostname'] = h.customHostname;
    vb['sshusekey'] = h.sshUseKey ? 1 : 0;
    vb['sshkeypath'] = h.sshKeyPath; vb['sshkeydata'] = h.sshKeyData;
    vb['sshkeypassphrase'] = h.sshKeyPassphrase;
    vb['sshkeyid'] = h.sshKeyId;
    vb['sshhostkeyalgorithm'] = h.sshHostKeyAlgorithm;
    vb['sshhostkeyfingerprintsha256'] = h.sshHostKeyFingerprintSha256;
    vb['sshhostkeyrawbase64'] = h.sshHostKeyRawBase64;
    vb['sshhostkeytrustedat'] = h.sshHostKeyTrustedAt;
    vb['sshhostkeytrustmode'] = h.sshHostKeyTrustMode;
    vb['rdpcertificatefingerprintsha256'] = h.rdpCertificateFingerprintSha256;
    vb['rdpcertificatesubject'] = h.rdpCertificateSubject;
    vb['rdpcertificateissuer'] = h.rdpCertificateIssuer;
    vb['rdpcertificatecommonname'] = h.rdpCertificateCommonName;
    vb['rdpcertificatetrustedat'] = h.rdpCertificateTrustedAt;
    vb['rdpcertificatetrustmode'] = h.rdpCertificateTrustMode;
    vb['rdpcertificateallowuntrustedroot'] = h.rdpCertificateAllowUntrustedRoot ? 1 : 0;
    vb['rdpcertificateallowhostmismatch'] = h.rdpCertificateAllowHostMismatch ? 1 : 0;
    vb['proxyhost'] = h.proxyHost; vb['proxyport'] = h.proxyPort;
    vb['proxyusername'] = h.proxyUsername;
    vb['gatewayhost'] = h.gatewayHost; vb['gatewayport'] = h.gatewayPort;
    vb['displayconfig'] = encodeRemoteHostDisplayPayload(
      JSON.stringify(h.displayConfig.toJSON()),
      projectRemoteHostCloudExtension(this.hostCloudExtensionValues(h))
    );
    vb['locked'] = h.locked ? 1 : 0; vb['locktype'] = h.lockType;
    vb['groupid'] = h.groupId;
    vb['sortorder'] = h.sortOrder; vb['icon'] = h.icon;
    vb['lastconnected'] = h.lastConnected; vb['lasthealth'] = h.lastHealth;
    vb['lastlatency'] = h.lastLatency;
    vb['rustdeskrelayid'] = h.rustdeskRelayId;
    vb['rustdeskaccountid'] = h.rustdeskAccountId;
    vb['rustdeskpasswordmode'] = h.rustdeskPasswordMode;
    vb['rustdeskauthmode'] = h.rustdeskAuthMode;
    vb['rustdeskdirectenabled'] = h.rustdeskDirectEnabled ? 1 : 0;
    vb['rustdeskdirecthost'] = h.rustdeskDirectHost;
    vb['rustdeskdirectport'] = h.rustdeskDirectPort;
    vb['rdpcredentialid'] = h.rdpCredentialId;
    vb['sourcetype'] = h.sourceType;
    vb['rustdeskproaccountid'] = h.rustdeskProAccountId;
    vb['rustdeskpropeerid'] = h.rustdeskProPeerId;
    vb['rustdeskproplatform'] = h.rustdeskProPlatform;
    vb['rustdeskpromanaged'] = h.rustdeskProManaged ? 1 : 0;
    vb['rustdeskprolastseenat'] = h.rustdeskProLastSeenAt;
    vb['rustdeskprosyncerror'] = h.rustdeskProSyncError;
    vb['syncversion'] = h.syncVersion;
    vb['createdat'] = h.createdAt;
    return this.cloudBucket('remotehosts', vb);
  }

  private updateSshKeyInternal(key: SshKey, encrypt: boolean): boolean {
    if (!this.store) { return false; }
    try {
      const vb = encrypt ? this.sshKeyToBucket(key) : this.sshKeyToBucketRaw(key);
      vb['updatedat'] = Date.now();
      const predicates = new relationalStore.RdbPredicates('sshkeys');
      predicates.equalTo('id', key.id);
      const updated: boolean = rdbSingleRowAffected(this.store.updateSync(vb, predicates));
      if (!updated) { return false; }
      return this.saveSshKeyExtension(key);
    } catch (err) {
      hilog.error(0x0006, 'CloudStore', "updateSshKey 失败: " + JSON.stringify(err));
      return false;
    }
  }

  private sshKeyToBucketRaw(k: SshKey): relationalStore.ValuesBucket {
    const vb: relationalStore.ValuesBucket = {};
    vb['id'] = k.id; vb['userid'] = k.userId; vb['label'] = k.label;
    vb['keytype'] = k.keyType; vb['publickey'] = k.publicKey;
    vb['privatekey'] = k.privateKey; vb['fingerprint'] = k.fingerprint;
    vb['comment'] = k.comment; vb['locked'] = k.locked ? 1 : 0;
    vb['locktype'] = k.lockType; vb['syncversion'] = k.syncVersion;
    vb['createdat'] = k.createdAt;
    vb['formatversion'] = k.formatVersion;
    vb['privatekeyencrypted'] = k.privateKeyEncrypted ? 1 : 0;
    return this.cloudBucket('sshkeys', vb);
  }

  private updateTotpEntryInternal(entry: TotpEntry, encrypt: boolean): boolean {
    if (!this.store) { return false; }
    try {
      const vb = encrypt ? this.totpToBucket(entry) : this.totpToBucketRaw(entry);
      vb['updatedat'] = Date.now();
      const predicates = new relationalStore.RdbPredicates('totpentries');
      predicates.equalTo('id', entry.id);
      return rdbSingleRowAffected(this.store.updateSync(vb, predicates));
    } catch (err) {
      hilog.error(0x0006, 'CloudStore', "updateTotpEntry 失败: " + JSON.stringify(err));
      return false;
    }
  }

  private totpToBucketRaw(e: TotpEntry): relationalStore.ValuesBucket {
    const vb: relationalStore.ValuesBucket = {};
    vb['id'] = e.id; vb['userid'] = e.userId; vb['issuer'] = e.issuer;
    vb['account'] = e.account; vb['secret'] = e.secret;
    vb['algorithm'] = e.algorithm; vb['digits'] = e.digits; vb['period'] = e.period;
    vb['iconurl'] = e.iconUrl; vb['locked'] = e.locked ? 1 : 0;
    vb['locktype'] = e.lockType; vb['syncversion'] = e.syncVersion;
    vb['createdat'] = e.createdAt;
    return vb;
  }

  // ==================== TotpEntry CRUD ====================

  loadAllTotpEntries(): TotpEntry[] {
    if (!this.store) { return []; }
    try {
      const predicates = new relationalStore.RdbPredicates('totpentries');
      predicates.orderByDesc('createdat');
      const rs = this.store.querySync(predicates);
      const result: TotpEntry[] = [];
      while (rs.goToNextRow()) {
        const dfIdx: number = rs.getColumnIndex(relationalStore.Field.DELETED_FLAG_FIELD);
        if (dfIdx >= 0 && rs.getLong(dfIdx) === 1) { continue; }
        result.push(this.rowToTotpEntry(rs));
      }
      rs.close();
      return result;
    } catch (err) {
      hilog.error(0x0001, 'CloudSync', '[CloudStore] loadAllTotpEntries 失败: ' + JSON.stringify(err));
      return [];
    }
  }

  insertTotpEntry(entry: TotpEntry): boolean {
    if (!this.store) { return this.setLastMutation(DataMutationResult.failure(entry.id, 'not_ready', '本地数据库未就绪')); }
    if (!this.localMutationAllowed()) {
      return this.setLastMutation(DataMutationResult.failure(entry.id, 'restore_in_progress', '恢复进行中，暂不能保存'));
    }
    if (!this.sensitiveWriteAllowed(entry.id)) { return false; }
    let code = 'local_write_failed';
    try {
      this.store.beginTransaction();
      const vb = this.totpToBucket(entry);
      vb['createdat'] = Date.now();
      vb['updatedat'] = Date.now();
      if (!rdbInsertSucceeded(this.store.insertSync('totpentries', vb))) { code = 'local_write_failed'; throw new Error('totp insert failed'); }
      if (!this.recordLocalMutation('totpentries', entry.id, 'add')) { code = 'journal_write_failed'; throw new Error('totp journal failed'); }
      this.store.commit();
      hilog.info(0x0001, 'CloudSync', "insertTotpEntry: " + entry.issuer + " (" + entry.id + ")");
      return this.setLastMutation(DataMutationResult.success(entry.id));
    } catch (err) {
      try { this.store.rollBack(); } catch (_ignored) {}
      hilog.error(0x0001, 'CloudSync', '[CloudStore] insertTotpEntry 失败: ' + JSON.stringify(err));
      return this.setLastMutation(DataMutationResult.failure(entry.id, code as 'local_write_failed' |
        'journal_write_failed', '动态口令保存未完成'));
    }
  }

  updateTotpEntry(entry: TotpEntry): boolean {
    if (!this.store) { return this.setLastMutation(DataMutationResult.failure(entry.id, 'not_ready', '本地数据库未就绪')); }
    if (!this.localMutationAllowed()) {
      return this.setLastMutation(DataMutationResult.failure(entry.id, 'restore_in_progress', '恢复进行中，暂不能保存'));
    }
    if (!this.sensitiveWriteAllowed(entry.id)) { return false; }
    let code = 'local_write_failed';
    try {
      this.store.beginTransaction();
      const vb = this.totpToBucket(entry);
      vb['updatedat'] = Date.now();
      const predicates = new relationalStore.RdbPredicates('totpentries');
      predicates.equalTo('id', entry.id);
      if (!rdbSingleRowAffected(this.store.updateSync(vb, predicates))) { code = 'not_found'; throw new Error('totp update failed'); }
      if (!this.recordLocalMutation('totpentries', entry.id, 'update')) { code = 'journal_write_failed'; throw new Error('totp journal failed'); }
      this.store.commit();
      hilog.info(0x0001, 'CloudSync', "updateTotpEntry: " + entry.issuer + " (" + entry.id + ")");
      return this.setLastMutation(DataMutationResult.success(entry.id));
    } catch (err) {
      try { this.store.rollBack(); } catch (_ignored) {}
      hilog.error(0x0001, 'CloudSync', '[CloudStore] updateTotpEntry 失败: ' + JSON.stringify(err));
      return this.setLastMutation(DataMutationResult.failure(entry.id, code as 'local_write_failed' |
        'not_found' | 'journal_write_failed', '动态口令更新未完成'));
    }
  }

  deleteTotpEntry(id: string): boolean {
    if (!this.store) { return this.setLastMutation(DataMutationResult.failure(id, 'not_ready', '本地数据库未就绪')); }
    if (!this.localMutationAllowed()) {
      return this.setLastMutation(DataMutationResult.failure(id, 'restore_in_progress', '恢复进行中，暂不能删除'));
    }
    if (!this.sensitiveWriteAllowed(id)) { return false; }
    let code = 'local_write_failed';
    try {
      this.store.beginTransaction();
      const predicates = new relationalStore.RdbPredicates('totpentries');
      predicates.equalTo('id', id);
      if (!rdbSingleRowAffected(this.store.deleteSync(predicates))) { code = 'not_found'; throw new Error('totp delete failed'); }
      if (!this.recordLocalMutation('totpentries', id, 'delete')) { code = 'journal_write_failed'; throw new Error('totp journal failed'); }
      this.store.commit();
      hilog.info(0x0001, 'CloudSync', "deleteTotpEntry: " + id);
      return this.setLastMutation(DataMutationResult.success(id));
    } catch (err) {
      try { this.store.rollBack(); } catch (_ignored) {}
      hilog.error(0x0001, 'CloudSync', '[CloudStore] deleteTotpEntry 失败: ' + JSON.stringify(err));
      return this.setLastMutation(DataMutationResult.failure(id, code as 'local_write_failed' |
        'not_found' | 'journal_write_failed', '动态口令删除未完成'));
    }
  }

  /** @deprecated Compatibility entry point; still uses the sole coordinator. */
  syncTotpEntries(_userId: string): void {
    CloudSyncCoordinator.getInstance().requestAutomaticPush('totpentries');
  }

  private totpToBucket(e: TotpEntry): relationalStore.ValuesBucket {
    const crypto = DataCrypto.getInstance();
    const vb: relationalStore.ValuesBucket = {};
    vb['id'] = e.id;
    vb['userid'] = e.userId;
    vb['issuer'] = e.issuer;
    vb['account'] = e.account;
    vb['secret'] = this.encryptIfReady(crypto, e.secret);
    vb['algorithm'] = e.algorithm;
    vb['digits'] = e.digits;
    vb['period'] = e.period;
    vb['iconurl'] = e.iconUrl;
    vb['locked'] = e.locked ? 1 : 0;
    vb['locktype'] = e.lockType;
    vb['syncversion'] = e.syncVersion;
    vb['createdat'] = e.createdAt;
    return vb;
  }

  private rowToTotpEntry(rs: relationalStore.ResultSet): TotpEntry {
    const crypto = DataCrypto.getInstance();
    const getStr = (col: string): string => rs.getString(rs.getColumnIndex(col));
    const e = new TotpEntry();
    e.id = getStr('id');
    e.userId = getStr('userid');
    e.issuer = getStr('issuer');
    e.account = getStr('account');
    e.secret = this.decryptIfReady(crypto, getStr('secret'));
    e.algorithm = rs.getLong(rs.getColumnIndex('algorithm'));
    e.digits = rs.getLong(rs.getColumnIndex('digits'));
    e.period = rs.getLong(rs.getColumnIndex('period'));
    e.iconUrl = getStr('iconurl');
    e.locked = rs.getLong(rs.getColumnIndex('locked')) !== 0;
    e.lockType = rs.getLong(rs.getColumnIndex('locktype'));
    e.syncVersion = rs.getLong(rs.getColumnIndex('syncversion'));
    e.createdAt = rs.getLong(rs.getColumnIndex('createdat'));
    return e;
  }
}
