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
import { RemoteHost, DisplayConfig, DisplayConfigJSON } from '../model/RemoteHost';
import { RustDeskRelayConfig, RustDeskRelayJSON } from '../model/RustDeskRelayConfig';
import { RustDeskAccount, RustDeskAccountJSON } from '../model/RustDeskAccount';
import { RdpCredential } from '../model/RdpCredential';
import { SshKey, SshKeyType } from '../model/SshKey';
import { TotpEntry, TotpAlgorithm } from '../model/TotpEntry';
import { DataCrypto, CryptoCloudStore } from './DataCrypto';
import { hashForLog, safeError } from '../utils/SafeLogger';
import { cloudSyncTableNames, CloudSyncDirection } from './CloudSyncPolicy';
import { CloudSyncCoordinator, CloudSyncCoordinatorHooks, CloudSyncOperationResult } from './CloudSyncCoordinator';
import { cloudDistributedTableAutoSync, cloudLocalMutationAllowed } from './CloudSyncCoordinatorPolicy';
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

const DB_NAME: string = 'remotedesktop';
const TABLES: string[] = cloudSyncTableNames();

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
  private localRestoreActive: boolean = false;
  private localRestorePending: boolean = false;
  private readonly syncSelection: CloudSyncSelectionStore = CloudSyncSelectionStore.getInstance();
  // 加密状态追踪
  private lastKnownCryptoStatus: string = '';

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
        autoCleanDirtyData: true
      };
      this.store = await relationalStore.getRdbStore(context, config);
      hilog.info(0x0001, 'CloudSync',
        "[DEBUG] 系统版本: " + deviceInfo.osFullName + ", RDB已创建");

      await this.createTables();
      // 本地库必须独立可用；云服务未开通或网络策略设置失败时仍要恢复缓存数据。
      this.initialized = true;
      this.syncSelection.init(context);
      DataCrypto.getInstance().init(this);
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
            "云端数据变更: " + accounts.length.toString() + " 个账号, 触发拉取同步");
          CloudSyncCoordinator.getInstance().requestCloudEventPull();
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
          this.store.commit();
          return true;
        } catch (_e) {
          try { this.store.rollBack(); } catch (_ignored) {}
          this.manualDownloadSnapshot = null;
          return false;
        }
      },
      rollbackManualDownload: async (): Promise<boolean> => {
        const snapshot = this.manualDownloadSnapshot;
        this.manualDownloadSnapshot = null;
        return snapshot !== null && await this.replaceAllTableRows(snapshot);
      },
      completeManualDownload: (): void => { this.manualDownloadSnapshot = null; },
      setRestorePending: (pending: boolean): void => { this.localRestorePending = pending; }
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
      const columns: string[] = rows.getColumnNames();
      while (rows.goToNextRow()) {
        const row: Record<string, string> = {};
        for (let c = 0; c < columns.length; c++) { row[columns[c]] = rows.getString(c); }
        snapshot[table].push(row);
      }
      rows.close();
      snapshot[table].sort((a: Record<string, string>, b: Record<string, string>): number =>
        (a['id'] || '').localeCompare(b['id'] || ''));
    }
    return snapshot;
  }

  /** 本地恢复专用：调用者已完成文件完整性校验；失败时整批回滚，且绝不自动推云。 */
  async replaceAllTableRows(snapshot: Record<string, Array<Record<string, string>>>): Promise<boolean> {
    if (!this.store) { return false; }
    for (let i = 0; i < TABLES.length; i++) {
      if (!snapshot[TABLES[i]]) { return false; }
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
          for (let k = 0; k < keys.length; k++) { bucket[keys[k]] = rows[r][keys[k]]; }
          if (!rdbInsertSucceeded(this.store.insertSync(table, bucket, relationalStore.ConflictResolution.ON_CONFLICT_REPLACE))) {
            throw new Error('restore insert failed table=' + table);
          }
        }
      }
      this.store.commit();
      // A restored cryptoparams row may belong to a different master password.
      // Never keep the previous DEK alive across a whole-database replacement.
      this.localRestoreActive = false;
      DataCrypto.getInstance().lock();
      this.lastKnownCryptoStatus = '';
      this.checkCryptoStatusChange();
      for (let i = 0; i < this.onChangeCallbacks.length; i++) { this.onChangeCallbacks[i](); }
      return true;
    } catch (_e) {
      try { this.store.rollBack(); } catch (_ignored) {}
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
    this.checkCryptoStatusChange();
    if (tables.indexOf('usersettings') >= 0) { this.applyCloudUserSettingsToRuntime(); }
    for (let i = 0; i < this.onChangeCallbacks.length; i++) {
      this.onChangeCallbacks[i]();
    }
  }

  private applyCloudUserSettingsToRuntime(): void {
    if (!this.appContext) { return; }
    const settings: Record<string, CloudUserSettingValue> = this.loadUserSettings();
    const keys: string[] = Object.keys(settings);
    if (keys.length === 0) { return; }
    try {
      const prefs = preferences.getPreferencesSync(this.appContext, { name: 'RemoteDesktopAppPrefs' });
      for (let i = 0; i < keys.length; i++) {
        const key: string = keys[i];
        if (!cloudUserSettingIsSyncable(key)) { continue; }
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
      this.store.cloudSync(mode, [table],
        (progress: Object): void => {
          const detail = progress as Record<string, Object>;
          hilog.info(0x0001, 'CloudSync', label + ' progress table=' + table + ' status=' + detail['status']);
        },
        (err: BusinessError | undefined): void => {
          this.lastSyncTime = Date.now();
          if (err) {
            this.syncFailCount++;
            this.cloudServiceGuidanceNeeded = this.cloudServiceGuidanceNeeded || this.errorRequiresCloudServiceGuidance(err);
            this.lastError = label + ' ' + table + ': code=' + err.code.toString() + ' msg=' + err.message;
            if (this.tableStatus[table]) { this.tableStatus[table].fail++; }
            hilog.error(0x0001, 'CloudSync', this.lastError);
            resolve(false);
            return;
          }
          this.syncSuccessCount++;
          this.cloudServiceGuidanceNeeded = false;
          if (this.tableStatus[table]) {
            this.tableStatus[table].ok++;
            this.tableStatus[table].last = Date.now();
          }
          hilog.info(0x0001, 'CloudSync', label + ' complete table=' + table);
          resolve(true);
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
        updatedat INTEGER
      )
    `);
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

  /** 写入一项允许跨设备使用的个性化设置，并在本地写成功后立即推送独立云表。 */
  upsertUserSetting(key: string, value: CloudUserSettingValue): boolean {
    if (!this.localMutationAllowed() || !cloudUserSettingIsSyncable(key) || !this.store) { return false; }
    try {
      const bucket: relationalStore.ValuesBucket = {};
      bucket['id'] = 'setting:' + key;
      bucket['userid'] = '';
      bucket['key'] = key;
      bucket['value'] = JSON.stringify(value);
      bucket['updatedat'] = Date.now();
      if (!rdbInsertSucceeded(this.store.insertSync('usersettings', bucket, relationalStore.ConflictResolution.ON_CONFLICT_REPLACE))) {
        return false;
      }
      this.pushTable('usersettings');
      return true;
    } catch (err) {
      hilog.error(0x0001, 'CloudSync', '[CloudStore] upsertUserSetting 失败: ' + safeError(err));
      return false;
    }
  }

  /** 获取已由云端同步到本地 RDB 的可信个性化设置。 */
  loadUserSettings(): Record<string, CloudUserSettingValue> {
    const result: Record<string, CloudUserSettingValue> = {};
    if (!this.store) { return result; }
    try {
      const rows = this.store.querySync(new relationalStore.RdbPredicates('usersettings'));
      while (rows.goToNextRow()) {
        const key: string = rows.getString(rows.getColumnIndex('key'));
        if (!cloudUserSettingIsSyncable(key)) { continue; }
        const parsed: CloudUserSettingValue = JSON.parse(rows.getString(rows.getColumnIndex('value'))) as CloudUserSettingValue;
        if (typeof parsed === 'string' || typeof parsed === 'number' || typeof parsed === 'boolean') {
          result[key] = parsed;
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
      if (!rdbInsertSucceeded(this.store.insertSync('cryptoparams', vb, relationalStore.ConflictResolution.ON_CONFLICT_REPLACE))) {
        return false;
      }
      this.lastKnownCryptoStatus = status;
      hilog.info(0x0001, 'CloudSync', "[setCryptoStatus] " + status);
      return true;
    } catch (e) {
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
      for (let i = 0; i < tables.length; i++) {
        await this.store.executeSql("DELETE FROM " + tables[i]);
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
      // 1. remotehosts: 解密 password, sshkeydata
      const hostPredicates = new relationalStore.RdbPredicates('remotehosts');
      const hostRs = this.store.querySync(hostPredicates);
      while (hostRs.goToNextRow()) {
        const id: string = hostRs.getString(hostRs.getColumnIndex('id'));
        const pwd: string = hostRs.getString(hostRs.getColumnIndex('password'));
        const sshData: string = hostRs.getString(hostRs.getColumnIndex('sshkeydata'));
        let changed: boolean = false;
        const vb: relationalStore.ValuesBucket = {};
        if (crypto.isEncrypted(pwd)) {
          vb['password'] = crypto.decrypt(pwd);
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
            count++;
            relaysChanged = true;
          } else {
            throw new Error('decrypt rustdeskrelays update failed id=' + id);
          }
        }
      }
      relayRs.close();

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

  /** 检测加密状态变更并执行对应的本地联动操作 (跨设备同步) */
  checkCryptoStatusChange(): void {
    const newStatus: string = this.getCryptoStatus();
    if (newStatus === '' || newStatus === this.lastKnownCryptoStatus) {
      return;
    }
    hilog.info(0x0001, 'CloudSync',
      "[checkCryptoStatusChange] " + this.lastKnownCryptoStatus + " → " + newStatus);
    this.lastKnownCryptoStatus = newStatus;

    if (newStatus === 'reset') {
      // await clearAllTables 完成后再触发回调, 避免回调读到旧数据
      this.clearAllTables().then((cleared: boolean): void => {
        DataCrypto.getInstance().lock();
        for (let i = 0; i < this.onCryptoResetCallbacks.length; i++) {
          this.onCryptoResetCallbacks[i]();
        }
        if (cleared) {
          hilog.info(0x0001, 'CloudSync', '[checkCryptoStatusChange] reset: 本地数据已清空');
        } else {
          hilog.error(0x0001, 'CloudSync', '[checkCryptoStatusChange] reset: 本地清理失败，已锁定密钥');
        }
      }).catch((e: Error): void => {
        hilog.error(0x0001, 'CloudSync',
          '[checkCryptoStatusChange] reset clearAllTables 异常: ' + e.message);
        // 即使清表失败也锁定 DEK, 防止残留明文密钥
        DataCrypto.getInstance().lock();
        for (let i = 0; i < this.onCryptoResetCallbacks.length; i++) {
          this.onCryptoResetCallbacks[i]();
        }
      });
    } else if (newStatus === 'disabled') {
      // 接收端必须先解密本地数据再锁 DEK (云同步过来的数据仍是密文)
      const crypto = DataCrypto.getInstance();
      if (crypto.isReady()) {
        const decrypted = this.decryptAllData(crypto);
        if (decrypted < 0) {
          // Keep the DEK for a later retry. Treating this status as handled would
          // otherwise leave encrypted rows unreadable after a transient RDB failure.
          this.lastKnownCryptoStatus = '';
          hilog.error(0x0001, 'CloudSync', '[checkCryptoStatusChange] disabled: 本地解密失败，等待后续同步重试');
          return;
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
      // 通知服务层重载 (无论 DEK 状态, UI 都需要刷新)
      for (let j = 0; j < this.onChangeCallbacks.length; j++) {
        this.onChangeCallbacks[j]();
      }
      hilog.info(0x0001, 'CloudSync', '[checkCryptoStatusChange] disabled: 已通知服务层重载');
    }
  }

  /** 清除密码学参数 */
  async clearCryptoParams(): Promise<boolean> {
    if (!this.localMutationAllowed() || !this.store) { return false; }
    try {
      this.store.beginTransaction();
      await this.store.executeSql("DELETE FROM cryptoparams WHERE key IN ('crypto_salt', 'crypto_verifier')");
      this.store.commit();
      return true;
    } catch (e) {
      try { this.store.rollBack(); } catch (_ignored) {}
      hilog.error(0x0001, 'CloudSync', '[clearCryptoParams] 失败: ' + DataCrypto.errDetail(e));
      return false;
    }
  }

  // ==================== Raw CRUD (不解密, 供迁移使用) ====================

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
    if (!this.localMutationAllowed()) { return false; }
    return this.updateHostInternal(host, false);
  }

  updateRdpCredentialRaw(credential: RdpCredential): boolean {
    if (!this.localMutationAllowed()) { return false; }
    return this.updateRdpCredentialInternal(credential, false);
  }

  upsertRelayLocalRaw(relay: RustDeskRelayConfig): boolean {
    if (!this.localMutationAllowed()) { return false; }
    return this.upsertRelayLocalInternal(relay, false);
  }

  updateSshKeyRaw(key: SshKey): boolean {
    if (!this.localMutationAllowed()) { return false; }
    return this.updateSshKeyInternal(key, false);
  }

  updateTotpEntryRaw(entry: TotpEntry): boolean {
    if (!this.localMutationAllowed()) { return false; }
    return this.updateTotpEntryInternal(entry, false);
  }

  // ==================== RemoteHost CRUD ====================

  loadAllHosts(): RemoteHost[] {
    return this.loadAllHostsInternal(true);
  }

  insertHost(host: RemoteHost): boolean {
    if (!this.localMutationAllowed() || !this.store) { return false; }
    try {
      const vb = this.hostToBucket(host);
      vb['createdat'] = Date.now();
      vb['updatedat'] = Date.now();
      if (!rdbInsertSucceeded(this.store.insertSync('remotehosts', vb))) { return false; }
      hilog.info(0x0001, 'CloudSync', "insertHost: " + host.label + " (" + host.id + ")");
      return true;
    } catch (err) {
      hilog.error(0x0001, 'CloudSync', '[CloudStore] insertHost 失败: ' + JSON.stringify(err));
      return false;
    }
  }

  updateHost(host: RemoteHost): boolean {
    if (!this.localMutationAllowed() || !this.store) { return false; }
    try {
      const vb = this.hostToBucket(host);
      vb['updatedat'] = Date.now();
      const predicates = new relationalStore.RdbPredicates('remotehosts');
      predicates.equalTo('id', host.id);
      if (!rdbSingleRowAffected(this.store.updateSync(vb, predicates))) { return false; }
      hilog.info(0x0001, 'CloudSync', "updateHost: " + host.label + " (" + host.id + ")");
      return true;
    } catch (err) {
      hilog.error(0x0001, 'CloudSync', '[CloudStore] updateHost 失败: ' + JSON.stringify(err));
      return false;
    }
  }

  deleteHost(id: string): boolean {
    if (!this.localMutationAllowed() || !this.store) { return false; }
    try {
      const predicates = new relationalStore.RdbPredicates('remotehosts');
      predicates.equalTo('id', id);
      if (!rdbSingleRowAffected(this.store.deleteSync(predicates))) { return false; }
      hilog.info(0x0001, 'CloudSync', "deleteHost: " + id);
      return true;
    } catch (err) {
      hilog.error(0x0001, 'CloudSync', '[CloudStore] deleteHost 失败: ' + JSON.stringify(err));
      return false;
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
        result.push(decrypt ? this.rowToRdpCredential(rs) : this.rowToRdpCredentialRaw(rs));
      }
      rs.close();
    } catch (err) {
      hilog.error(0x0001, 'CloudSync', '[CloudStore] loadAllRdpCredentials 失败: ' + JSON.stringify(err));
    }
    return result;
  }

  insertRdpCredential(credential: RdpCredential): boolean {
    if (!this.localMutationAllowed() || !this.store) { return false; }
    try {
      const vb = this.rdpCredentialToBucket(credential);
      vb['updatedat'] = Date.now();
      if (!rdbInsertSucceeded(this.store.insertSync('rdpcredentials', vb, relationalStore.ConflictResolution.ON_CONFLICT_REPLACE))) {
        return false;
      }
      hilog.info(0x0001, 'CloudSync', 'insertRdpCredential: idHash=' + hashForLog(credential.id));
      return true;
    } catch (err) {
      hilog.error(0x0001, 'CloudSync', '[CloudStore] insertRdpCredential 失败: ' + safeError(err));
      return false;
    }
  }

  updateRdpCredential(credential: RdpCredential): boolean {
    if (!this.localMutationAllowed()) { return false; }
    return this.updateRdpCredentialInternal(credential, true);
  }

  private updateRdpCredentialInternal(credential: RdpCredential, encrypt: boolean): boolean {
    if (!this.store) { return false; }
    try {
      const vb = encrypt ? this.rdpCredentialToBucket(credential) : this.rdpCredentialToBucketRaw(credential);
      vb['updatedat'] = Date.now();
      const predicates = new relationalStore.RdbPredicates('rdpcredentials');
      predicates.equalTo('id', credential.id);
      return rdbSingleRowAffected(this.store.updateSync(vb, predicates));
    } catch (err) {
      hilog.error(0x0001, 'CloudSync', '[CloudStore] updateRdpCredential 失败: ' + safeError(err));
      return false;
    }
  }

  deleteRdpCredential(id: string): boolean {
    if (!this.localMutationAllowed() || !this.store) { return false; }
    try {
      const predicates = new relationalStore.RdbPredicates('rdpcredentials');
      predicates.equalTo('id', id);
      return rdbSingleRowAffected(this.store.deleteSync(predicates));
    } catch (err) {
      hilog.error(0x0001, 'CloudSync', '[CloudStore] deleteRdpCredential 失败: ' + safeError(err));
      return false;
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
    return vb;
  }

  upsertRelay(relay: RustDeskRelayConfig): boolean {
    if (!this.localMutationAllowed()) { return false; }
    const ok = this.upsertRelayLocal(relay);
    if (ok) { this.syncRelaysToCloud(); }
    return ok;
  }

  deleteRelay(id: string): boolean {
    if (!this.localMutationAllowed()) { return false; }
    const ok = this.deleteRelayLocal(id);
    if (ok) { this.syncRelaysToCloud(); }
    return ok;
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
      const vb = encrypt ? this.relayToBucket(relay) : this.relayToBucketRaw(relay);
      vb['updatedat'] = Date.now();
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
    const crypto = DataCrypto.getInstance();
    const encrypt = (v: string) => crypto.isReady() ? crypto.encrypt(v) : v;
    const vb: relationalStore.ValuesBucket = {};
    vb['id'] = h.id;
    vb['userid'] = h.userId;
    vb['label'] = h.label;
    vb['protocol'] = h.protocol;
    vb['host'] = h.host;
    vb['port'] = h.port;
    vb['username'] = h.username;
    vb['password'] = h.password ? encrypt(h.password) : h.password;
    vb['customhostname'] = h.customHostname;
    vb['sshusekey'] = h.sshUseKey ? 1 : 0;
    vb['sshkeypath'] = h.sshKeyPath;
    vb['sshkeydata'] = h.sshKeyData ? encrypt(h.sshKeyData) : h.sshKeyData;
    vb['sshkeypassphrase'] = h.sshKeyPassphrase ? encrypt(h.sshKeyPassphrase) : h.sshKeyPassphrase;
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
    vb['displayconfig'] = JSON.stringify(h.displayConfig.toJSON());
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
    return vb;
  }

  private rowToHost(rs: relationalStore.ResultSet): RemoteHost {
    const crypto = DataCrypto.getInstance();
    const decrypt = (v: string) => crypto.isReady() ? crypto.decrypt(v) : v;
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
    h.password = decrypt(getStr('password'));
    h.customHostname = getStr('customhostname');
    h.sshUseKey = rs.getLong(rs.getColumnIndex('sshusekey')) !== 0;
    h.sshKeyPath = getStr('sshkeypath');
    h.sshKeyData = decrypt(getStr('sshkeydata'));
    h.sshKeyPassphrase = decrypt(getStr('sshkeypassphrase'));
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
    if (dcJson) {
      try { h.displayConfig = DisplayConfig.fromJSON(JSON.parse(dcJson) as DisplayConfigJSON); }
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
    h.rustdeskDirectPort = rdDirectPortIdx >= 0 ? rs.getLong(rdDirectPortIdx) : 21116;
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
    return h;
  }

  private rdpCredentialToBucket(credential: RdpCredential): relationalStore.ValuesBucket {
    const crypto = DataCrypto.getInstance();
    const encrypt = (v: string) => crypto.isReady() ? crypto.encrypt(v) : v;
    const vb: relationalStore.ValuesBucket = {};
    vb['id'] = credential.id;
    vb['label'] = credential.label;
    vb['username'] = credential.username;
    vb['password'] = credential.password ? encrypt(credential.password) : credential.password;
    vb['createdat'] = credential.createdAt;
    return vb;
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
      createdAt: json.createdAt
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
    return crypto.isReady() ? crypto.encrypt(value) : value;
  }

  private decryptIfReady(crypto: DataCrypto, value: string): string {
    if (value === '') { return value; }
    return crypto.isReady() ? crypto.decrypt(value) : value;
  }

  private rdpCredentialToBucketRaw(credential: RdpCredential): relationalStore.ValuesBucket {
    const vb: relationalStore.ValuesBucket = {};
    vb['id'] = credential.id;
    vb['label'] = credential.label;
    vb['username'] = credential.username;
    vb['password'] = credential.password;
    vb['createdat'] = credential.createdAt;
    return vb;
  }

  private rowToRdpCredential(rs: relationalStore.ResultSet): RdpCredential {
    const crypto = DataCrypto.getInstance();
    const decrypt = (v: string) => crypto.isReady() ? crypto.decrypt(v) : v;
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
    credential.password = decrypt(getStr('password'));
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
        result.push(this.rowToSshKey(rs));
      }
      rs.close();
      return result;
    } catch (err) {
      hilog.error(0x0001, 'CloudSync', '[CloudStore] loadAllSshKeys 失败: ' + JSON.stringify(err));
      return [];
    }
  }

  insertSshKey(key: SshKey): boolean {
    if (!this.localMutationAllowed() || !this.store) { return false; }
    try {
      const vb = this.sshKeyToBucket(key);
      vb['createdat'] = Date.now();
      vb['updatedat'] = Date.now();
      if (!rdbInsertSucceeded(this.store.insertSync('sshkeys', vb))) { return false; }
      hilog.info(0x0001, 'CloudSync', "insertSshKey: " + key.label + " (" + key.id + ")");
      return true;
    } catch (err) {
      hilog.error(0x0001, 'CloudSync', '[CloudStore] insertSshKey 失败: ' + JSON.stringify(err));
      return false;
    }
  }

  updateSshKey(key: SshKey): boolean {
    if (!this.localMutationAllowed() || !this.store) { return false; }
    try {
      const vb = this.sshKeyToBucket(key);
      vb['updatedat'] = Date.now();
      const predicates = new relationalStore.RdbPredicates('sshkeys');
      predicates.equalTo('id', key.id);
      if (!rdbSingleRowAffected(this.store.updateSync(vb, predicates))) { return false; }
      hilog.info(0x0001, 'CloudSync', "updateSshKey: " + key.label + " (" + key.id + ")");
      return true;
    } catch (err) {
      hilog.error(0x0001, 'CloudSync', '[CloudStore] updateSshKey 失败: ' + JSON.stringify(err));
      return false;
    }
  }

  deleteSshKey(id: string): boolean {
    if (!this.localMutationAllowed() || !this.store) { return false; }
    try {
      const predicates = new relationalStore.RdbPredicates('sshkeys');
      predicates.equalTo('id', id);
      if (!rdbSingleRowAffected(this.store.deleteSync(predicates))) { return false; }
      hilog.info(0x0001, 'CloudSync', "deleteSshKey: " + id);
      return true;
    } catch (err) {
      hilog.error(0x0001, 'CloudSync', '[CloudStore] deleteSshKey 失败: ' + JSON.stringify(err));
      return false;
    }
  }

  /** @deprecated Compatibility entry point; still uses the sole coordinator. */
  syncSshKeys(_userId: string): void {
    CloudSyncCoordinator.getInstance().requestAutomaticPush('sshkeys');
  }

  private sshKeyToBucket(k: SshKey): relationalStore.ValuesBucket {
    const crypto = DataCrypto.getInstance();
    const encrypt = (v: string) => crypto.isReady() ? crypto.encrypt(v) : v;
    const vb: relationalStore.ValuesBucket = {};
    vb['id'] = k.id;
    vb['userid'] = k.userId;
    vb['label'] = k.label;
    vb['keytype'] = k.keyType;
    vb['publickey'] = k.publicKey;
    vb['privatekey'] = k.privateKey ? encrypt(k.privateKey) : k.privateKey;
    vb['fingerprint'] = k.fingerprint;
    vb['comment'] = k.comment;
    vb['locked'] = k.locked ? 1 : 0;
    vb['locktype'] = k.lockType;
    vb['syncversion'] = k.syncVersion;
    vb['createdat'] = k.createdAt;
    vb['formatversion'] = k.formatVersion;
    vb['privatekeyencrypted'] = k.privateKeyEncrypted ? 1 : 0;
    return vb;
  }

  private rowToSshKey(rs: relationalStore.ResultSet): SshKey {
    const crypto = DataCrypto.getInstance();
    const decrypt = (v: string) => crypto.isReady() ? crypto.decrypt(v) : v;
    const getStr = (col: string): string => rs.getString(rs.getColumnIndex(col));
    const k = new SshKey();
    k.id = getStr('id');
    k.userId = getStr('userid');
    k.label = getStr('label');
    k.keyType = rs.getLong(rs.getColumnIndex('keytype'));
    k.publicKey = getStr('publickey');
    k.privateKey = decrypt(getStr('privatekey'));
    k.fingerprint = getStr('fingerprint');
    k.comment = getStr('comment');
    k.locked = rs.getLong(rs.getColumnIndex('locked')) !== 0;
    k.lockType = rs.getLong(rs.getColumnIndex('locktype'));
    k.syncVersion = rs.getLong(rs.getColumnIndex('syncversion'));
    k.createdAt = rs.getLong(rs.getColumnIndex('createdat'));
    k.formatVersion = rs.getLong(rs.getColumnIndex('formatversion'));
    k.privateKeyEncrypted = rs.getLong(rs.getColumnIndex('privatekeyencrypted')) !== 0;
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
          result.push(decrypt ? this.rowToHost(rs) : this.rowToHostRaw(rs));
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
    h.password = rs.getString(rs.getColumnIndex('password')); // raw
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
    if (dcJson) {
      try { h.displayConfig = DisplayConfig.fromJSON(JSON.parse(dcJson) as DisplayConfigJSON); }
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
    h.rustdeskDirectPort = rdDirectPortIdx2 >= 0 ? rs.getLong(rdDirectPortIdx2) : 21116;
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
        result.push(decrypt ? this.rowToSshKey(rs) : this.rowToSshKeyRaw(rs));
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
    k.formatVersion = rs.getLong(rs.getColumnIndex('formatversion'));
    k.privateKeyEncrypted = rs.getLong(rs.getColumnIndex('privatekeyencrypted')) !== 0;
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
      return rdbSingleRowAffected(this.store.updateSync(vb, predicates));
    } catch (err) {
      hilog.error(0x0006, 'CloudStore', "updateHost 失败: " + JSON.stringify(err));
      return false;
    }
  }

  private hostToBucketRaw(h: RemoteHost): relationalStore.ValuesBucket {
    const vb: relationalStore.ValuesBucket = {};
    vb['id'] = h.id; vb['userid'] = h.userId; vb['label'] = h.label;
    vb['protocol'] = h.protocol; vb['host'] = h.host; vb['port'] = h.port;
    vb['username'] = h.username; vb['password'] = h.password;
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
    vb['displayconfig'] = JSON.stringify(h.displayConfig.toJSON());
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
    return vb;
  }

  private updateSshKeyInternal(key: SshKey, encrypt: boolean): boolean {
    if (!this.store) { return false; }
    try {
      const vb = encrypt ? this.sshKeyToBucket(key) : this.sshKeyToBucketRaw(key);
      vb['updatedat'] = Date.now();
      const predicates = new relationalStore.RdbPredicates('sshkeys');
      predicates.equalTo('id', key.id);
      return rdbSingleRowAffected(this.store.updateSync(vb, predicates));
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
    return vb;
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
    if (!this.localMutationAllowed() || !this.store) { return false; }
    try {
      const vb = this.totpToBucket(entry);
      vb['createdat'] = Date.now();
      vb['updatedat'] = Date.now();
      if (!rdbInsertSucceeded(this.store.insertSync('totpentries', vb))) { return false; }
      hilog.info(0x0001, 'CloudSync', "insertTotpEntry: " + entry.issuer + " (" + entry.id + ")");
      return true;
    } catch (err) {
      hilog.error(0x0001, 'CloudSync', '[CloudStore] insertTotpEntry 失败: ' + JSON.stringify(err));
      return false;
    }
  }

  updateTotpEntry(entry: TotpEntry): boolean {
    if (!this.localMutationAllowed() || !this.store) { return false; }
    try {
      const vb = this.totpToBucket(entry);
      vb['updatedat'] = Date.now();
      const predicates = new relationalStore.RdbPredicates('totpentries');
      predicates.equalTo('id', entry.id);
      if (!rdbSingleRowAffected(this.store.updateSync(vb, predicates))) { return false; }
      hilog.info(0x0001, 'CloudSync', "updateTotpEntry: " + entry.issuer + " (" + entry.id + ")");
      return true;
    } catch (err) {
      hilog.error(0x0001, 'CloudSync', '[CloudStore] updateTotpEntry 失败: ' + JSON.stringify(err));
      return false;
    }
  }

  deleteTotpEntry(id: string): boolean {
    if (!this.localMutationAllowed() || !this.store) { return false; }
    try {
      const predicates = new relationalStore.RdbPredicates('totpentries');
      predicates.equalTo('id', id);
      if (!rdbSingleRowAffected(this.store.deleteSync(predicates))) { return false; }
      hilog.info(0x0001, 'CloudSync', "deleteTotpEntry: " + id);
      return true;
    } catch (err) {
      hilog.error(0x0001, 'CloudSync', '[CloudStore] deleteTotpEntry 失败: ' + JSON.stringify(err));
      return false;
    }
  }

  /** @deprecated Compatibility entry point; still uses the sole coordinator. */
  syncTotpEntries(_userId: string): void {
    CloudSyncCoordinator.getInstance().requestAutomaticPush('totpentries');
  }

  private totpToBucket(e: TotpEntry): relationalStore.ValuesBucket {
    const crypto = DataCrypto.getInstance();
    const encrypt = (v: string) => crypto.isReady() ? crypto.encrypt(v) : v;
    const vb: relationalStore.ValuesBucket = {};
    vb['id'] = e.id;
    vb['userid'] = e.userId;
    vb['issuer'] = e.issuer;
    vb['account'] = e.account;
    vb['secret'] = e.secret ? encrypt(e.secret) : e.secret;
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
    const decrypt = (v: string) => crypto.isReady() ? crypto.decrypt(v) : v;
    const getStr = (col: string): string => rs.getString(rs.getColumnIndex(col));
    const e = new TotpEntry();
    e.id = getStr('id');
    e.userId = getStr('userid');
    e.issuer = getStr('issuer');
    e.account = getStr('account');
    e.secret = decrypt(getStr('secret'));
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
