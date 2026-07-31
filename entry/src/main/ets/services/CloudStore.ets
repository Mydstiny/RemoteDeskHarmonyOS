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
  normalizeRdpCredentialParts,
  normalizeRdpNtlmHash,
  normalizeRdpRestrictedAdminSecretSource,
  RdpAuthMode,
  RdpRestrictedAdminSecretSource
} from '../model/RemoteHost';
import {
  RustDeskRelayConfig,
  RustDeskRelayCloudJSON,
  RustDeskRelayJSON
} from '../model/RustDeskRelayConfig';
import { RustDeskAccount, RustDeskAccountJSON } from '../model/RustDeskAccount';
import { RdpCredential } from '../model/RdpCredential';
import { SshKey, SshKeyType } from '../model/SshKey';
import { TotpEntry, TotpAlgorithm } from '../model/TotpEntry';
import { VncRecord } from '../model/VncRecord';
import { DataCrypto, CryptoCloudStore } from './DataCrypto';
import { hashForLog, safeError } from '../utils/SafeLogger';
import { cloudSyncTableNames, CloudSyncDirection } from './CloudSyncPolicy';
import { CloudSyncCoordinator, CloudSyncCoordinatorHooks, CloudSyncOperationResult } from './CloudSyncCoordinator';
import {
  CLOUD_SYNC_ACCEPT_TIMEOUT_MS,
  CLOUD_SYNC_IDLE_TIMEOUT_MS,
  CLOUD_SYNC_OVERALL_TIMEOUT_MS,
  CloudSyncCallbackIdentity,
  CloudSyncWatchdogState,
  CloudSyncWatchdogTimeoutKind,
  cloudDistributedTableAutoSync,
  cloudLocalMutationAllowed,
  cloudSyncFailureMessage,
  cloudSyncCallbackIdentityMatches,
  CloudSyncFailureKind,
  classifyCloudSyncFailure,
  cloudSyncProgressFinished,
  cloudSyncProgressSucceeded,
  cloudSyncTargetTableCompleted,
  cloudSyncWatchdogNextDelayMs,
  cloudSyncWatchdogTimeoutKind,
  cloudSyncBlockedByLocalRestore,
  classifyCloudSyncProgressCode,
  shouldRejectAutomaticEmptyCloudSnapshot
} from './CloudSyncCoordinatorPolicy';
import { CloudSyncSelectionStore } from './CloudSyncSelectionStore';
import {
  cloudSelectionAfterLocalCryptoTransition,
  cloudTableRowsAreDownloadCompatible,
  cloudTableRowsAreUploadSafe,
  vncSelectionAfterLocalCryptoTransition
} from './CloudSensitiveTransferPolicy';
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
  localBackupLocalTableColumns,
  localBackupLocalTableNames,
  PortableBackupRestorePlan,
  validateLocalBackupSnapshot
} from './LocalBackupPolicy';
import {
  DataMutationResult,
  DataMutationStage
} from './DataMutationResult';
import { canonicalHostPassword } from './SensitiveDataMigrationPolicy';
import { rustDeskRelayKeyForStorage, rustDeskRelayKeyFromStorage } from './RustDeskRelayKeyPolicy';
import {
  RustDeskRelayCloudSyncOutcome,
  RustDeskRelayCloudSyncState,
  rustDeskRelayIdFingerprint,
} from './RustDeskRelaySavePolicy';
import {
  commitRustDeskRelayPersistence,
  RustDeskRelayPersistenceGate,
  RustDeskRelayPersistencePort,
  rustDeskRelayPersistenceGateResult,
  verifyRustDeskRelayPersistence
} from './RustDeskRelayPersistencePolicy';
import {
  normalizeRustDeskControlPlaneProfile,
  rustDeskControlPlaneProfileMetadataKey,
  RUSTDESK_CONTROL_PLANE_PROFILE_METADATA_PREFIX
} from './RustDeskControlPlanePolicy';
import {
  sensitiveWriteRequiresUnlock,
  shouldRedactLockedCiphertext
} from './SensitiveDataStatePolicy';
import {
  VIRTUAL_MOUSE_STYLE_RESTORE_VERSION_KEY,
  shouldApplyCloudVirtualMouseStyle
} from './RemoteCursorStylePolicy';
import {
  SSH_LEGACY_FONT_SIZE_KEY,
  SSH_LEGACY_FOREGROUND_COLOR_KEY,
  SSH_SETTINGS_SCHEMA_VERSION,
  SSH_SETTINGS_SCHEMA_VERSION_KEY,
  SSH_TERMINAL_FONT_SIZE_KEY,
  SSH_TERMINAL_FOREGROUND_COLOR_KEY,
  SshTerminalAppearance,
  hasSshTerminalAppearanceCloudSettings,
  isSshTerminalAppearanceKey,
  resolveSshTerminalAppearance,
  resolveSshTerminalAppearanceFromCloudSettings
} from './SshSettingsPolicy';
import {
  cloudTableColumns,
  encodeUserSettingsPayload,
  decodeUserSettingsPayload,
  projectRemoteHostCloudExtension,
  encodeRemoteHostDisplayPayload,
  decodeRemoteHostDisplayPayload,
  RemoteHostDisplayPayload
} from './CloudTableAdapter';
import {
  extractLegacyRemoteHostDeviceTrust,
  mergeRemoteHostDeviceTrust,
  projectRemoteHostDeviceTrust,
  remoteHostDeviceTrustIsMeaningful
} from './RemoteHostDeviceTrustPolicy';
import {
  VNC_CLOUD_TABLE,
  VNC_LOCAL_TABLE,
  VNC_RECORD_COLUMNS,
  vncRecordFromCloudRow,
  vncRecordIdentity,
  vncRecordIsValid,
  vncRecordIsScopeTombstone,
  vncRecordToCloudRow,
  vncRecordWins,
  vncPayloadHashSha256,
  vncCanonicalJson,
  vncPayloadObject,
  VNC_AAD_VERSION,
  VNC_CRYPTO_VERSION,
  VNC_KEY_VERSION,
  VNC_LEGACY_AAD_VERSION,
  VNC_LEGACY_CRYPTO_VERSION,
  VNC_LEGACY_KEY_VERSION,
  VNC_LEGACY_SECRET_ENVELOPE_VERSION,
  VNC_SECRET_ENVELOPE_VERSION,
  VNC_PLAIN_SECRET_ENVELOPE_VERSION,
  vncRecordHasActiveEncryptedCiphertext
} from './VncRecordPolicy';
import { VncCloudSyncSelectionStore } from './VncCloudSyncSelectionStore';
import { VncCloudSyncService } from './VncCloudSyncService';
import { decodePlainVncSecret, encodePlainVncSecret, vncSecretStorageModeFromPayload } from './VncSecretStoragePolicy';
import {
  CloudAccountBinding,
  CLOUD_LIFECYCLE_BLOCKED_REASON,
  cloudAccountBindingIsValid,
  cloudDistributedRegistrationAllowed,
  cloudTransferAllowed,
  remoteCryptoLifecycleMutationAllowed,
  unboundCloudAccountBinding
} from './CloudLifecycleSafetyPolicy';
import {
  AccountSessionLease,
  AccountScopeToken,
  ACCOUNT_CLOUD_STORE_IDENTITY,
  accountSessionLease,
  accountSessionLeaseEquals,
  accountStoreIdentity,
  cloudAccountBindingForScope,
  cloneAccountSessionLease,
  deviceLocalScopeToken,
  ownerRecordWriteAllowed,
  verifyAccountScopeCloudBinding
} from './AccountScopePolicy';
import {
  PlatformCloudIdentityProof,
  unavailablePlatformCloudIdentityProof
} from './PlatformCloudIdentityPolicy';
import {
  CloudDownloadTransactionEnvelope,
  CloudDownloadTransactionOperation,
  cloudDownloadTransactionEnvelope,
  parseCloudDownloadTransactionEnvelope
} from './CloudDownloadTransactionPolicy';
import {
  CLOUD_DOWNLOAD_TRANSACTION_KEY,
  CLOUD_SELECTION_REENABLE_BARRIERS_KEY,
  VNC_SELECTION_REENABLE_TRANSACTION_KEY,
  CloudDownloadTransactionPayload,
  CloudStoreVncAuthoritativeCompletionPort,
  CloudStoreVncSelectionFinalizationPort,
  VncAuthoritativeCompletionWiringResult,
  VncSelectionCheckpointIdentity,
  VncSelectionFinalizationWiringResult,
  VncSelectionReenableCheckpoint,
  VncSelectionReenableCheckpointRead,
  VncSelectionReenableTransactionPayload,
  completeVncAuthoritativeCloudFirst as
    completeVncAuthoritativeCloudFirstWiring,
  finalizeVncSelectionReenable,
  readVncSelectionReenableCheckpointState
} from './CloudStoreVncLifecycleWiring';
import {
  CloudStoreStartupRecoveryIo,
  CloudStoreStartupRecoveryRunner
} from './CloudStoreStartupRecoveryRunner';
import {
  CloudMetadataReadResult,
  cloudMetadataAbsentProven,
  cloudMetadataBoundaryReadable,
  cloudMetadataCheckpointBlocks,
  readCloudMetadataState
} from './CloudMetadataSafetyPolicy';
import {
  CloudSelectionReenablePhase,
  cloudSelectionBarrierAfterRollback,
  cloudSelectionAfterAuthoritativePull,
  cloudSelectionAfterLocalPromotion,
  cloudSelectionLocalPromotionAllowed,
  cloudSelectionNativeFirstAllowed,
  normalizeCloudSelectionReenablePhase,
  vncSelectionRecoveryBarrier,
  vncSettingsRollbackJournal,
  vncSettingsRollbackRows
} from './CloudSelectionReenablePolicy';
import {
  CloudBootstrapRecordReconcileAction,
  cloudBootstrapRecordReconcileAction
} from './CloudBootstrapReconcilePolicy';
import {
  CloudSyncDurableState,
  cloudSyncExternalRecoveryRequired,
  cloudSyncExternalRecoverySettled,
  corruptedCloudSyncDurableState,
  recoverCloudSyncDurableState
} from './CloudSyncLifecyclePolicy';
import {
  CryptoCommittedState,
  CryptoLifecycleDurableState,
  cryptoLifecycleCanConfigure,
  cryptoLifecycleCanDisable,
  cryptoLifecycleCanMigrate,
  cryptoLifecycleCanReset,
  cryptoLifecycleMemoryStateChanged,
  cryptoLifecycleOperationCommitted,
  cryptoLifecycleOperationFailed,
  cryptoLifecycleOperationStarted,
  cryptoLifecycleSensitiveWriteAllowed,
  newCryptoLifecycleDurableState,
  recoverCryptoLifecycleDurableState
} from './CryptoLifecyclePolicy';
import { LegacySharedStoreMigrator } from './LegacySharedStoreMigrator';
import { parseLegacyRelayJson } from './LegacyRelayMigrationPolicy';
import {
  LegacyVncRowMigrationDecision,
  legacyVncRowMigrationDecision
} from './LegacySharedStoreMigrationPolicy';

const TABLES: string[] = cloudSyncTableNames();
const RDP_RESTRICTED_ADMIN_SECRET_TABLE: string = 'rdprestrictedadminsecrets';
const LOCAL_METADATA_TABLE: string = 'localmetadata';
const LOCAL_MUTATION_JOURNAL_TABLE: string = 'localmutationjournal';
const MIGRATION_RECEIPT_TABLE: string = 'migrationreceipts';
const MIGRATION_QUARANTINE_TABLE: string = 'migrationquarantine';
const ACCOUNT_STORE_SCHEMA_VERSION: number = 3;
const CANONICAL_SECRET_STORAGE_VERSION_KEY: string = 'canonical_secret_storage_version';
const CANONICAL_SECRET_STORAGE_VERSION: string = '3';
const DEVICE_LOCAL_HOST_TRUST_MIGRATION_KEY: string =
  'device_local_host_trust_migrated_v1';
const LEGACY_RELAY_JSON_MIGRATION_KEY: string =
  'legacy_relay_json_migrated_v1';
const LEGACY_RELAY_JSON_MIGRATION_ID: string =
  'legacy-relay-cryptoparams-v1';
const LEGACY_VNC_MIGRATION_ID: string =
  'legacy-vnc-table-v1';
const RESTORED_NOT_UPLOADED_KEY: string = 'restored_not_uploaded';
const RESTORED_NOT_UPLOADED_TABLE_PREFIX: string =
  'restored_not_uploaded|';
const CLOUD_BOOTSTRAP_COMPLETED_KEY: string = 'cloud_bootstrap_completed_v1';
const CLOUD_SYNC_DURABLE_STATE_KEY: string = 'cloud_sync_durable_state_v1';
const CRYPTO_LIFECYCLE_DURABLE_STATE_KEY: string =
  'crypto_lifecycle_durable_state_v1';
const STORE_OWNER_SCOPE_KEY: string = 'store_owner_scope_id';
const STORE_IDENTITY_KEY: string = 'store_identity';
const STORE_SCHEMA_REVISION_KEY: string = 'store_schema_revision';
const STORE_PLATFORM_IDENTITY_KEY: string =
  'store_platform_cloud_identity_fingerprint';
// Compatibility only: this table is never registered again. Existing rows are
// copied into the device-local VNC overlay before the new `vncrecord` table is
// registered, so a table-name correction cannot erase an installed user's data
// or silently publish it to the replacement cloud table.
const LEGACY_VNC_CLOUD_TABLE: string = 'vncrecords';
const VNC_LEGACY_MIGRATION_KEY: string = 'vnc_legacy_vncrecords_migrated_v1';
const TABLE_MUTATION_RECORD_ID: string = '__table__';
const VNC_RESET_EPOCH_KEY: string = 'vnc_reset_epoch';

interface LegacyVncQuarantineItem {
  recordId: string;
  reason: LegacyVncRowMigrationDecision;
  payloadHashSha256: string;
}
const CRYPTO_SECRET_PARAM_KEYS: string[] = [
  'crypto_salt',
  'crypto_verifier',
  'crypto_kdf_version',
  'crypto_kdf_iterations',
  'crypto_key_version',
  'crypto_verifier_version',
  'crypto_envelope_version'
];
const LOCAL_METADATA_COLUMNS: string[] = ['key', 'value', 'updatedat'];
const LOCAL_MUTATION_JOURNAL_COLUMNS: string[] = [
  'id', 'tablename', 'recordid', 'operation', 'revision', 'createdat', 'updatedat'
];

interface CryptoCloudSelectionSnapshot {
  ordinary: string[];
  vnc: string[];
}

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

interface IndeterminateCloudSyncOperation {
  operationId: number;
  storeInstanceId: number;
  table: string;
  direction: CloudSyncDirection;
  label: string;
  lease: AccountSessionLease;
  terminalObserved: boolean;
  terminalSucceeded: boolean;
}

export interface PortableBackupSnapshot {
  accountScope: string;
  rdbSchemaVersion: number;
  sourceCryptoConfigured: boolean;
  tables: Record<string, Array<Record<string, string>>>;
  extensions: Array<Record<string, string>>;
  localTables: Record<string, Array<Record<string, string>>>;
}

interface SelectionReenableBarrierSnapshot {
  readable: boolean;
  barriers: Record<string, string>;
}

/**
 * Narrow metadata I/O boundary used by every safety-sensitive metadata read.
 * The live adapter performs the actual RdbStore.querySync call.
 */
export interface CloudStoreMetadataQueryPort {
  queryValue(key: string): string | null;
}

export interface CloudStoreWiringPorts {
  metadataQuery?: CloudStoreMetadataQueryPort;
}

export class CloudStore implements CryptoCloudStore {
  private static instance: CloudStore;
  private store: relationalStore.RdbStore | null = null;
  private appContext: common.Context | null = null;
  private initialized: boolean = false;
  private initPromise: Promise<void> | null = null;
  private cloudAvailable: boolean = false;
  private cloudServiceGuidanceNeeded: boolean = false;
  private onChangeCallbacks: Array<() => void> = [];
  private onCryptoResetCallbacks: Array<() => void> = [];
  // 同步状态追踪
  private lastSyncTime: number = 0;
  private syncSuccessCount: number = 0;
  private syncFailCount: number = 0;
  private lastError: string = '';
  // 诊断: 记录 createTables 当前执行的 DDL 步骤, 失败时精确定位语句
  private schemaStep: string = '';
  private lastSyncFailureKind: CloudSyncFailureKind = 'none';
  private tableStatus: Record<string, TableSyncStatus> = {}
  private automaticPushSuppressed: boolean = false;
  private manualDownloadSnapshot: Record<string, Array<Record<string, string>>> | null = null;
  private manualDownloadExtensions: Array<Record<string, string>> | null = null;
  private manualDownloadMetadata: Array<Record<string, string>> | null = null;
  private manualDownloadMutationJournal: Array<Record<string, string>> | null = null;
  private manualDownloadLocalTables: Record<string, Array<Record<string, string>>> | null = null;
  private cloudDownloadCheckpointOperation:
    CloudDownloadTransactionOperation | null = null;
  private localRestoreActive: boolean = false;
  private localRestorePending: boolean = false;
  // Device-local starts unbound. AccountSessionCoordinator supplies identity
  // from the current Account Kit authorization; this store verifies that it
  // derives the exact owner and physical database before enabling cloud I/O.
  private currentScopeToken: AccountScopeToken = deviceLocalScopeToken(1);
  private currentLease: AccountSessionLease | null = null;
  private storeInstanceSequence: number = 0;
  private cloudSyncOperationSequence: number = 0;
  private indeterminateCloudSyncOperation: IndeterminateCloudSyncOperation | null = null;
  private cloudDownloadActive: boolean = false;
  private mutationGateOpen: boolean = false;
  private exclusiveCryptoLease: AccountSessionLease | null = null;
  private exclusiveCryptoReady: boolean = false;
  private cloudChangeObserver: ((accounts: Array<string>) => void) | null = null;
  private cloudAccountBinding: CloudAccountBinding = unboundCloudAccountBinding();
  private cryptoStateListenerBound: boolean = false;
  // The first process-wide cloud operation is a pull barrier. It is enabled
  // before service migrations run so startup defaults cannot become an upload.
  private startupSyncPending: boolean = true;
  private cloudBootstrapCompleted: boolean = false;
  private lastMutationResult: DataMutationResult = DataMutationResult.success('');
  private lastMutationRevision: number = 0;
  private readonly syncSelection: CloudSyncSelectionStore = CloudSyncSelectionStore.getInstance();
  private readonly vncSyncSelection: VncCloudSyncSelectionStore =
    VncCloudSyncSelectionStore.getInstance();
  // 加密状态追踪
  private lastKnownCryptoStatus: string = '';
  private cryptoLifecycleState: CryptoLifecycleDurableState | null = null;
  // A cloud-first apply may synchronously lock/unlock DataCrypto.  Hold its
  // state callback until the completed cloud snapshot is published once.
  private suppressCryptoStateSnapshot: boolean = false;
  private readonly wiringPorts:
    CloudStoreWiringPorts | null;
  // Set only on a detached instance created by the startup verification
  // factory. It never exposes or replaces the singleton's private RDB handle.
  private startupRecoveryVerificationIo:
    CloudStoreStartupRecoveryIo | null = null;

  constructor(
    wiringPorts: CloudStoreWiringPorts | null = null
  ) {
    this.wiringPorts = wiringPorts;
  }

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

  /**
   * Build a detached, RDB-free initialization target for executable startup
   * wiring verification. The returned instance can only exercise the
   * startup-recovery I/O supplied by the caller; it cannot mutate the
   * production singleton or obtain a relationalStore handle.
   */
  static createStartupRecoveryVerificationStore(
    io: CloudStoreStartupRecoveryIo
  ): CloudStore {
    const detached: CloudStore =
      new CloudStore();
    detached.startupRecoveryVerificationIo =
      io;
    return detached;
  }

  /** 初始化数据库 + 开启云同步 */
  async init(
    context: common.Context | null
  ): Promise<void> {
    if (this.initialized) { return; }
    if (this.initPromise !== null) {
      await this.initPromise;
      return;
    }
    this.initPromise = this.openScopeStore(context, this.currentScopeToken);
    try {
      await this.initPromise;
    } finally {
      this.initPromise = null;
    }
  }

  /**
   * Switch the singleton facade to a physically separate scope store. The
   * caller must drain sessions and clear service caches before invoking this.
   */
  async rebindScope(context: common.Context, token: AccountScopeToken,
    verifiedUnionId: string = '',
    platformProof: PlatformCloudIdentityProof =
      unavailablePlatformCloudIdentityProof()): Promise<boolean> {
    if (this.initialized &&
      this.currentScopeToken.storeIdentity === token.storeIdentity &&
      this.currentScopeToken.generation === token.generation) {
      return true;
    }
    if (this.initPromise !== null) { await this.initPromise; }
    if (this.initialized && this.mutationGateOpen) {
      hilog.error(0x0001, 'CloudSync',
        '拒绝切换物理数据域：mutation gate 尚未关闭');
      return false;
    }
    if (!(await this.closeCurrentStore())) { return false; }
    this.initPromise = this.openScopeStore(
      context, token, verifiedUnionId, platformProof);
    try {
      await this.initPromise;
    } finally {
      this.initPromise = null;
    }
    return this.initialized && this.store !== null &&
      this.currentScopeToken.storeIdentity === token.storeIdentity &&
      this.currentScopeToken.generation === token.generation;
  }

  currentScope(): AccountScopeToken {
    return {
      kind: this.currentScopeToken.kind,
      ownerScopeId: this.currentScopeToken.ownerScopeId,
      generation: this.currentScopeToken.generation,
      sessionState: this.currentScopeToken.sessionState,
      cloudBindingState: this.currentScopeToken.cloudBindingState,
      storeIdentity: this.currentScopeToken.storeIdentity,
      schemaRevision: this.currentScopeToken.schemaRevision,
      selectionRevision: this.currentScopeToken.selectionRevision,
      platformIdentityFingerprint:
        this.currentScopeToken.platformIdentityFingerprint
    };
  }

  currentAccountLease(): AccountSessionLease | null {
    return this.currentLease === null ? null : cloneAccountSessionLease(this.currentLease);
  }

  private currentOwnerScopeId(): string {
    return this.currentScopeToken.ownerScopeId.trim();
  }

  /**
   * Blank owners are new local drafts and may be claimed by the active scope.
   * A non-blank different owner is a stale/cross-account object and must never
   * be silently rebound into the current account.
   */
  private recordOwnerWriteAllowed(candidateOwner: string): boolean {
    return ownerRecordWriteAllowed(this.currentOwnerScopeId(), candidateOwner);
  }

  private addCurrentOwnerPredicate(
    predicates: relationalStore.RdbPredicates
  ): void {
    predicates.equalTo('userid', this.currentOwnerScopeId());
  }

  isLeaseCurrent(lease: AccountSessionLease): boolean {
    return this.store !== null && this.initialized &&
      accountSessionLeaseEquals(this.currentLease, lease);
  }

  closeMutationGate(): boolean {
    const lease: AccountSessionLease | null = this.currentAccountLease();
    if (lease === null) {
      this.mutationGateOpen = false;
      return true;
    }
    const closed: boolean =
      CloudSyncCoordinator.getInstance().closeMutationGate(lease);
    if (closed) { this.mutationGateOpen = false; }
    return closed;
  }

  async quiesceCurrentScope(timeoutMs: number = 15000): Promise<boolean> {
    this.mutationGateOpen = false;
    const lease: AccountSessionLease | null = this.currentAccountLease();
    if (lease === null) { return true; }
    if (this.indeterminateCloudSyncOperation !== null) {
      hilog.error(0x0001, 'CloudSync',
        '底层云同步仍处于不确定状态；拒绝切换账号或关闭物理库');
      return false;
    }
    return await CloudSyncCoordinator.getInstance().quiesce(lease, timeoutMs);
  }

  activateScope(token: AccountScopeToken): boolean {
    if (!this.updateScopeState(token)) { return false; }
    if (this.indeterminateCloudSyncOperation !== null) { return false; }
    if (token.sessionState !== 'offline' && token.sessionState !== 'ready' &&
      token.sessionState !== 'bound') {
      return false;
    }
    const lease: AccountSessionLease | null = this.currentAccountLease();
    if (lease === null ||
      !CloudSyncCoordinator.getInstance().reopenMutationGate(lease)) {
      return false;
    }
    this.mutationGateOpen = true;
    return true;
  }

  updateScopeState(token: AccountScopeToken): boolean {
    if (!this.initialized ||
      token.generation !== this.currentScopeToken.generation ||
      token.storeIdentity !== this.currentScopeToken.storeIdentity ||
      token.ownerScopeId !== this.currentScopeToken.ownerScopeId) {
      return false;
    }
    this.currentScopeToken = {
      kind: token.kind,
      ownerScopeId: token.ownerScopeId,
      generation: token.generation,
      sessionState: token.sessionState,
      cloudBindingState: token.cloudBindingState,
      storeIdentity: token.storeIdentity,
      schemaRevision: this.store === null ? token.schemaRevision : this.store.version,
      selectionRevision: token.selectionRevision,
      platformIdentityFingerprint:
        token.platformIdentityFingerprint
    };
    this.cloudAccountBinding = cloudAccountBindingForScope(this.currentScopeToken);
    return true;
  }

  private async closeCurrentStore(): Promise<boolean> {
    const closing: relationalStore.RdbStore | null = this.store;
    const closingLease: AccountSessionLease | null = this.currentAccountLease();
    this.mutationGateOpen = false;
    this.exclusiveCryptoLease = null;
    this.exclusiveCryptoReady = false;
    if (this.indeterminateCloudSyncOperation !== null) {
      hilog.error(0x0001, 'CloudSync',
        '底层云同步尚无终态；拒绝关闭或复用当前物理数据库');
      return false;
    }
    const coordinator: CloudSyncCoordinator = CloudSyncCoordinator.getInstance();
    const coordinatorLease: AccountSessionLease | null =
      coordinator.currentAccountLease();
    if (closingLease !== null && coordinatorLease !== null &&
      !(await coordinator.dispose(closingLease))) {
      hilog.error(0x0001, 'CloudSync',
        '旧账号同步队列未达到终态；拒绝关闭或复用物理数据库');
      return false;
    }
    if (closing !== null) {
      this.unsubscribeCloudChanges();
    }
    this.initialized = false;
    this.cloudAvailable = false;
    this.cloudServiceGuidanceNeeded = false;
    this.startupSyncPending = true;
    this.cloudBootstrapCompleted = false;
    if (closing !== null) {
      try {
        await closing.close();
      } catch (err) {
        hilog.error(0x0001, 'CloudSync',
          '关闭旧账号物理库失败；保留旧 handle 并阻止打开新库: ' + safeError(err));
        return false;
      }
    }
    this.store = null;
    this.currentLease = null;
    this.cryptoLifecycleState = null;
    this.cloudDownloadActive = false;
    this.indeterminateCloudSyncOperation = null;
    this.clearManualDownloadSnapshot();
    return true;
  }

  private async openScopeStore(
    context: common.Context | null,
    token: AccountScopeToken,
    verifiedUnionId: string = '',
    platformProof: PlatformCloudIdentityProof =
      unavailablePlatformCloudIdentityProof()): Promise<void> {
    this.appContext = context;
    this.currentScopeToken = {
      kind: token.kind,
      ownerScopeId: token.ownerScopeId,
      generation: token.generation,
      sessionState: token.sessionState,
      cloudBindingState: token.cloudBindingState,
      storeIdentity: token.storeIdentity,
      schemaRevision: token.schemaRevision,
      selectionRevision: token.selectionRevision,
      platformIdentityFingerprint:
        token.platformIdentityFingerprint
    };
    this.cloudAccountBinding = cloudAccountBindingForScope(this.currentScopeToken);
    this.startupSyncPending = true;
    this.cloudDownloadActive = false;
    this.indeterminateCloudSyncOperation = null;
    this.exclusiveCryptoLease = null;
    this.exclusiveCryptoReady = false;
    // 初始化表级同步状态
    for (let i = 0; i < TABLES.length; i++) {
      this.tableStatus[TABLES[i]] = new TableSyncStatus();
    }
    const startupRecoveryVerification:
      boolean =
      this.startupRecoveryVerificationIo !==
        null;
    try {
      if (!startupRecoveryVerification) {
        if (context === null) {
          throw new Error(
            'CloudStore production initialization requires a context');
        }
      const config: relationalStore.StoreConfig = {
        name: this.currentScopeToken.storeIdentity,
        securityLevel: relationalStore.SecurityLevel.S1,
        // 系统自动同步关闭；显式 cloud-first 同步仍需将云端删除清理到当前已选表。
        autoCleanDirtyData: false
      };
      this.store = await relationalStore.getRdbStore(context, config);
      this.storeInstanceSequence++;
      this.currentLease = accountSessionLease(
        this.currentScopeToken, this.storeInstanceSequence);
      hilog.info(0x0001, 'CloudSync',
        "[DEBUG] 系统版本: " + deviceInfo.osFullName + ", RDB已创建");

      await this.createTables();
      this.currentScopeToken.schemaRevision = this.store.version;
      // Canonical cloud store admission control. The AGC cloud schema binds
      // only to the store id `remotedesktop`; a per-account hashed store can
      // never register distributed cloud tables (14800000). When the canonical
      // store is already owned by a different account on this OS user, fall
      // back to the local-only hashed store and keep cloud fail-closed.
      if (this.currentScopeToken.kind === 'huawei_account' &&
        this.currentScopeToken.storeIdentity === ACCOUNT_CLOUD_STORE_IDENTITY &&
        this.store !== null) {
        const storedOwner: string =
          this.readLocalMetadataStrict(STORE_OWNER_SCOPE_KEY);
        if (storedOwner !== '' &&
          storedOwner !== this.currentScopeToken.ownerScopeId) {
          const fallbackIdentity: string =
            accountStoreIdentity(this.currentScopeToken.ownerScopeId);
          if (fallbackIdentity.length === 0) {
            throw new Error('account-scoped local store identity unavailable');
          }
          const foreignStore: relationalStore.RdbStore = this.store;
          this.store = null;
          this.currentLease = null;
          try { await foreignStore.close(); } catch (_closeError) {}
          this.currentScopeToken.storeIdentity = fallbackIdentity;
          this.currentScopeToken.cloudBindingState = 'blocked';
          this.cloudAccountBinding =
            cloudAccountBindingForScope(this.currentScopeToken);
          const fallbackConfig: relationalStore.StoreConfig = {
            name: fallbackIdentity,
            securityLevel: relationalStore.SecurityLevel.S1,
            autoCleanDirtyData: false
          };
          this.store = await relationalStore.getRdbStore(context, fallbackConfig);
          this.storeInstanceSequence++;
          this.currentLease = accountSessionLease(
            this.currentScopeToken, this.storeInstanceSequence);
          await this.createTables();
          this.currentScopeToken.schemaRevision = this.store.version;
          hilog.warn(0x0001, 'CloudSync',
            '规范云库属于其他账号，已回退到本地哈希作用域（云同步 fail-closed）');
        }
      }
      this.currentScopeToken = verifyAccountScopeCloudBinding(
        this.currentScopeToken, verifiedUnionId, platformProof);
      this.cloudAccountBinding =
        cloudAccountBindingForScope(this.currentScopeToken);
      if (this.currentScopeToken.kind === 'huawei_account' &&
        this.currentScopeToken.cloudBindingState === 'blocked') {
        throw new Error(
          'Account Kit scope or independent platform cloud identity does not match target binding');
      }
      this.verifyStoreIdentity();
      const migrator: LegacySharedStoreMigrator =
        LegacySharedStoreMigrator.getInstance();
      if (this.currentScopeToken.kind === 'huawei_account' &&
        this.currentScopeToken.storeIdentity === ACCOUNT_CLOUD_STORE_IDENTITY) {
        // remotedesktop.db == the canonical cloud target, so the legacy
        // self-migration is skipped; instead migrate the 1.0.9/1.0.10
        // account-scoped store into the canonical cloud store first, then
        // recover any pending download transaction carried over with it.
        await migrator.migrateAccountScopedStoreIfNeeded(
          context, this.store, this.currentScopeToken, verifiedUnionId);
      } else {
        await migrator.migrateIfNeeded(
          context, this.store, this.currentScopeToken, verifiedUnionId,
          { targetStoreName: this.currentScopeToken.storeIdentity });
      }
      if (!(await this.recoverPendingCloudDownloadTransaction())) {
        throw new Error(
          'pending cloud download transaction recovery failed');
      }
      this.migrateCryptoParamIdentity();
      this.migrateLegacyRelayJson();
      await this.migrateLocalExtensions();
      await this.migrateDeviceLocalHostTrust();
      await this.migrateLegacyVncRecords();
      const bootstrapMetadata:
        CloudMetadataReadResult =
        this.readLocalMetadataState(
          CLOUD_BOOTSTRAP_COMPLETED_KEY);
      if (!cloudMetadataBoundaryReadable(
        bootstrapMetadata)) {
        throw new Error(
          'cloud bootstrap metadata query failed');
      }
      this.cloudBootstrapCompleted =
        bootstrapMetadata.state === 'present' &&
        bootstrapMetadata.value === '1';
      // 本地库必须独立可用；云服务未开通或网络策略设置失败时仍要恢复缓存数据。
      this.initialized = true;
      this.syncSelection.init(context, this.currentScopeToken.ownerScopeId);
      this.vncSyncSelection.init(context, this.currentScopeToken.ownerScopeId);
      } else {
        // The detached verification store has no RDB and cannot proceed beyond
        // the production startup-recovery gate.
        this.initialized = true;
      }
      if (!(await this
        .recoverPendingVncSelectionReenableTransaction())) {
        throw new Error(
          'pending VNC selection transaction recovery failed');
      }
      if (startupRecoveryVerification) {
        return;
      }
      if (this.store === null ||
        this.currentLease === null) {
        throw new Error(
          'CloudStore startup state unavailable after VNC recovery');
      }
      const lease: AccountSessionLease =
        cloneAccountSessionLease(this.currentLease);
      this.cryptoLifecycleState =
        this.recoverCryptoLifecycleState(lease);
      if (!this.persistCryptoLifecycleState(this.cryptoLifecycleState)) {
        throw new Error('crypto lifecycle recovery state persistence failed');
      }
      const crypto: DataCrypto = DataCrypto.getInstance();
      crypto.init(this, lease);
      if (!this.cryptoStateListenerBound) {
        this.cryptoStateListenerBound = true;
        crypto.onStateChange((_ready: boolean, _configured: boolean): void => {
          if (!this.initialized) { return; }
          // Models may currently contain either decrypted values or locked-state
          // redactions. Reload them once from RDB for the new DEK state.
          this.lastKnownCryptoStatus = this.getCryptoStatus();
          if (!this.suppressCryptoStateSnapshot) {
            this.notifyDataSnapshotChanged();
          }
        });
      }
      const coordinatorBound: boolean = CloudSyncCoordinator.getInstance().bind(
        lease,
        this.cloudAccountBinding,
        (table: string, direction: CloudSyncDirection, label: string): Promise<boolean> =>
          this.executeSyncTable(table, direction, label),
        (tables: string[]): void => { this.notifyCloudDataApplied(tables); },
        this.coordinatorHooks()
      );
      if (!coordinatorBound) {
        throw new Error('CloudSyncCoordinator refused account lease');
      }
      // A physical distributed table is the platform sync boundary. Never
      // register a shared/unbound store: SQL row filters cannot constrain what
      // setDistributedTables/cloudSync publishes for another account.
      if (cloudDistributedRegistrationAllowed(this.cloudAccountBinding)) {
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
      } else {
        this.cloudAvailable = false;
        this.cloudServiceGuidanceNeeded = false;
        this.lastError = CLOUD_LIFECYCLE_BLOCKED_REASON;
        hilog.warn(0x0001, 'CloudSync',
          '云同步已按安全策略暂停：账号作用域与独立物理库尚未完成验证');
      }
      hilog.info(0x0001, 'CloudSync', 'CloudStore 初始化完成');
      hilog.info(0x0001, 'CloudSync',
        '物理数据域=' + this.currentScopeToken.storeIdentity +
        ' generation=' + this.currentScopeToken.generation.toString());
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
      if (this.cloudAvailable) {
        hilog.info(0x0001, 'CloudSync',
          '云空间同步已就绪 — 请确认两台设备"设置→华为账号"为同一账号');
      }
    } catch (err) {
      this.initialized = false;
      this.cloudAvailable = false;
      this.mutationGateOpen = false;
      this.exclusiveCryptoLease = null;
      this.exclusiveCryptoReady = false;
      const failedStore: relationalStore.RdbStore | null = this.store;
      const failedLease: AccountSessionLease | null = this.currentAccountLease();
      const coordinator: CloudSyncCoordinator = CloudSyncCoordinator.getInstance();
      if (failedLease !== null &&
        accountSessionLeaseEquals(coordinator.currentAccountLease(), failedLease)) {
        await coordinator.dispose(failedLease);
      }
      this.store = null;
      this.currentLease = null;
      if (failedStore !== null) {
        try { await failedStore.close(); } catch (_closeError) {}
      }
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

  /** Notify local VNC owners after the initiating device completes a reset. */
  notifyCryptoReset(): void {
    const callbacks: Array<() => void> = this.onCryptoResetCallbacks.slice();
    for (let i = 0; i < callbacks.length; i++) {
      try { callbacks[i](); } catch (err) {
        hilog.warn(0x0001, 'CloudSync', '[CloudStore] crypto reset listener failed: ' + safeError(err));
      }
    }
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
    if (!this.store || this.currentLease === null) { return; }
    const callbackStore: relationalStore.RdbStore = this.store;
    const callbackLease: AccountSessionLease =
      cloneAccountSessionLease(this.currentLease);
    try {
      const observer = (accounts: Array<string>): void => {
        if (this.store !== callbackStore || !this.isLeaseCurrent(callbackLease)) {
          hilog.warn(0x0001, 'CloudSync',
            '忽略旧账号物理库的迟到 dataChange 回调 generation=' +
            callbackLease.generation.toString());
          return;
        }
        this.lastSyncTime = Date.now();
        hilog.info(0x0001, 'CloudSync',
          '云端数据变更: ' + accounts.length.toString() + ' 个账号, 进入串行 cloud-first 拉取');
        CloudSyncCoordinator.getInstance().requestCloudEventPull()
          .then((result: CloudSyncOperationResult): void => {
            if (!this.isLeaseCurrent(callbackLease)) { return; }
            if (!result.ok) {
              hilog.warn(0x0001, 'CloudSync',
                '云端变更拉取未完成 failure=' + result.failureKind);
            }
          });
      };
      this.cloudChangeObserver = observer;
      callbackStore.on('dataChange',
        relationalStore.SubscribeType.SUBSCRIBE_TYPE_CLOUD,
        observer
      );
      hilog.info(0x0001, 'CloudSync', '已订阅云空间数据变更事件');
    } catch (err) {
      hilog.error(0x0001, 'CloudSync',
        "订阅云空间变更失败: " + JSON.stringify(err));
    }
  }

  /** 取消订阅云空间数据变更 */
  unsubscribeCloudChanges(): void {
    if (!this.store || this.cloudChangeObserver === null) { return; }
    try {
      this.store.off('dataChange',
        relationalStore.SubscribeType.SUBSCRIBE_TYPE_CLOUD,
        this.cloudChangeObserver
      );
      this.cloudChangeObserver = null;
      hilog.info(0x0001, 'CloudSync', '已取消订阅云空间数据变更');
    } catch (err) {
      hilog.error(0x0001, 'CloudSync',
        "取消订阅失败: " + JSON.stringify(err));
    }
  }

  /** 成功本地写入后的自动推送统一进入协调器。 */
  pushTable(table: string): void {
    if (table === VNC_CLOUD_TABLE) {
      if (!this.localMutationAllowed() || this.automaticPushSuppressed || !this.isCloudAvailable()) {
        return;
      }
      CloudSyncCoordinator.getInstance().requestVncTableAutomaticPush();
      return;
    }
    if (!this.localMutationAllowed() || this.automaticPushSuppressed || this.syncableTables().indexOf(table) < 0) {
      return;
    }
    if (!this.isCloudAvailable()) {
      hilog.warn(0x0001, 'CloudSync', 'pushTable 跳过: 云同步不可用 table=' + table);
      return;
    }
    CloudSyncCoordinator.getInstance().requestAutomaticPush(table);
  }

  /** Explicit crypto-reset path; intentionally bypasses VNC scope filtering. */
  pushVncResetTable(): void {
    if (!this.localMutationAllowed() || this.automaticPushSuppressed || !this.isCloudAvailable()) {
      return;
    }
    CloudSyncCoordinator.getInstance().requestVncTableAutomaticPush(true);
  }

  /** 兼容服务层调用；所有启动/恢复拉取都由协调器合并。 */
  pullNowAsync(): Promise<boolean> {
    if (!this.isCloudAvailable()) { return Promise.resolve(false); }
    return CloudSyncCoordinator.getInstance().requestStartupPull()
      .then((result): boolean => result.ok);
  }

  /** 手动触发拉取 (fire-and-forget, 内部用) */
  pullNow(): void {
    this.pullNowAsync(); // fire Promise, 不 await
  }

  /** 用户确认后覆盖云端：强制本地优先，并等待每个表完成。 */
  async uploadAllToCloud(): Promise<boolean> {
    if (!this.isCloudAvailable()) {
      hilog.warn(0x0001, 'CloudSync', 'manual upload blocked: account-scoped cloud store unavailable');
      return false;
    }
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
    if (!this.isCloudAvailable()) {
      return {
        ok: false,
        source: 'manualDownload',
        tables: this.syncableTables(),
        failedTables: this.syncableTables(),
        rollbackFailed: false,
        failureKind: 'cloud_service'
      };
    }
    return await CloudSyncCoordinator.getInstance().requestManualDownload();
  }

  syncableTables(): string[] {
    return this.syncSelection.effectiveTables();
  }

  selectionReenableBarrierPhase(
    table: string
  ): CloudSelectionReenablePhase | null {
    if (TABLES.indexOf(table) < 0) { return null; }
    const snapshot:
      SelectionReenableBarrierSnapshot =
      this.selectionReenableBarrierSnapshot();
    if (!snapshot.readable) {
      return 'pending_pull';
    }
    return normalizeCloudSelectionReenablePhase(
      snapshot.barriers[table]);
  }

  beginSelectionReenableBarrier(table: string): boolean {
    if (TABLES.indexOf(table) < 0) { return false; }
    const snapshot:
      SelectionReenableBarrierSnapshot =
      this.selectionReenableBarrierSnapshot();
    if (!snapshot.readable) { return false; }
    snapshot.barriers[table] = 'pending_pull';
    return this.persistSelectionReenableBarriers(
      snapshot.barriers);
  }

  abortSelectionReenableBarrier(table: string): boolean {
    if (TABLES.indexOf(table) < 0) { return false; }
    const snapshot:
      SelectionReenableBarrierSnapshot =
      this.selectionReenableBarrierSnapshot();
    if (!snapshot.readable) { return false; }
    return this.persistSelectionReenableBarriers(
      this.selectionReenableBarriersWithout(
        snapshot.barriers, [table]));
  }

  restoreSelectionReenableBarrier(
    table: string,
    previousPhase: CloudSelectionReenablePhase | null
  ): boolean {
    if (TABLES.indexOf(table) < 0) { return false; }
    const snapshot:
      SelectionReenableBarrierSnapshot =
      this.selectionReenableBarrierSnapshot();
    if (!snapshot.readable) { return false; }
    const restored: CloudSelectionReenablePhase | null =
      cloudSelectionBarrierAfterRollback(
        previousPhase);
    if (restored === null) {
      return this.persistSelectionReenableBarriers(
        this.selectionReenableBarriersWithout(
          snapshot.barriers, [table]));
    }
    snapshot.barriers[table] = restored;
    return this.persistSelectionReenableBarriers(
      snapshot.barriers);
  }

  /**
   * Establish the fail-closed VNC settings transaction before either the
   * logical selector or deterministic settings row is changed. The same RDB
   * commit writes the checkpoint and pending barrier, so a process death can
   * never expose an enabled secret scope without a recovery record.
   */
  beginVncSelectionReenableTransaction(
    previousScopes: string[],
    previousBarrier:
      CloudSelectionReenablePhase | null,
    settingsId: string,
    lease: AccountSessionLease
  ): boolean {
    if (!this.store ||
      !this.vncSelectionExclusiveLeaseCurrent(
        lease) ||
      settingsId.trim() === '') {
      return false;
    }
    try {
      this.store.beginTransaction();
      const checkpointRead:
        CloudMetadataReadResult =
        this.readLocalMetadataState(
          VNC_SELECTION_REENABLE_TRANSACTION_KEY);
      const barrierSnapshot:
        SelectionReenableBarrierSnapshot =
        this.selectionReenableBarrierSnapshot();
      if (!cloudMetadataAbsentProven(
        checkpointRead) ||
        !barrierSnapshot.readable) {
        throw new Error(
          'VNC selection safety metadata unavailable');
      }
      const base: CloudDownloadTransactionPayload =
        this.captureCloudDownloadPayload();
      const payload:
        VncSelectionReenableTransactionPayload = {
        snapshot: base.snapshot,
        extensions: base.extensions,
        metadata: base.metadata,
        mutationJournal: base.mutationJournal,
        localTables: base.localTables,
        stage: 'prepared',
        previousScopes: previousScopes.slice(),
        previousBarrier:
          previousBarrier === null
            ? '' : previousBarrier,
        settingsId
      };
      const envelope:
        CloudDownloadTransactionEnvelope | null =
        cloudDownloadTransactionEnvelope(
          'vnc_scope_reenable',
          this.currentScopeToken.ownerScopeId,
          this.currentScopeToken.storeIdentity,
          this.currentScopeToken.generation,
          JSON.stringify(payload));
      const encodedEnvelope: string =
        envelope === null
          ? '' : JSON.stringify(envelope);
      if (envelope === null ||
        !this.writeLocalMetadata(
          VNC_SELECTION_REENABLE_TRANSACTION_KEY,
          encodedEnvelope) ||
        !this.localMetadataValueMatches(
          VNC_SELECTION_REENABLE_TRANSACTION_KEY,
          encodedEnvelope)) {
        throw new Error(
          'VNC selection checkpoint persistence failed');
      }
      barrierSnapshot.barriers[
        VNC_CLOUD_TABLE] = 'pending_pull';
      if (!this.persistSelectionReenableBarriers(
        barrierSnapshot.barriers)) {
        throw new Error(
          'VNC pending barrier persistence failed');
      }
      this.store.commit();
      return true;
    } catch (err) {
      try { this.store.rollBack(); } catch (_ignored) {}
      hilog.error(0x0001, 'CloudSync',
        'VNC scope checkpoint 建立失败: ' +
        safeError(err));
      return false;
    }
  }

  async requestSelectionReenableCloudFirst(
    table: string
  ): Promise<CloudSyncOperationResult> {
    if (table === VNC_CLOUD_TABLE &&
      cloudMetadataCheckpointBlocks(
        this.readLocalMetadataState(
          VNC_SELECTION_REENABLE_TRANSACTION_KEY))) {
      return {
        ok: false,
        source: 'selectionReenable',
        tables: [table],
        failedTables: [table],
        rollbackFailed: true,
        failureKind: 'unknown'
      };
    }
    const result: CloudSyncOperationResult =
      await CloudSyncCoordinator.getInstance()
        .requestSelectionReenableCloudFirst(table);
    if (!result.ok) { return result; }
    if (!this.markSelectionReenablePulled(
      result.tables.length > 0 ? result.tables : [table]) ||
      !this.prepareSelectionReenablePromotions() ||
      !this.releaseSelectionReenableBarriers()) {
      return {
        ok: false,
        source: result.source,
        tables: result.tables.slice(),
        failedTables: [table],
        rollbackFailed: false,
        failureKind: 'unknown'
      };
    }
    return result;
  }

  async completeExclusiveVncSelectionCloudFirst(
    result: CloudSyncOperationResult,
    lease: AccountSessionLease
  ): Promise<CloudSyncOperationResult> {
    if (!this.vncSelectionExclusiveLeaseCurrent(
      lease)) {
      return {
        ok: false,
        source: result.source,
        tables: result.tables.slice(),
        failedTables: [VNC_CLOUD_TABLE],
        rollbackFailed: true,
        failureKind: 'unknown'
      };
    }
    const finalized: boolean = result.ok &&
      this.finalizeVncSelectionReenableTransaction();
    if (result.ok && finalized) {
      return result;
    }
    const restored: boolean =
      await this
        .rollbackVncSelectionReenableTransactionInternal();
    return {
      ok: false,
      source: result.source,
      tables: result.tables.slice(),
      failedTables: result.failedTables.length > 0
        ? result.failedTables.slice()
        : [VNC_CLOUD_TABLE],
      rollbackFailed:
        result.rollbackFailed || !restored,
      failureKind: result.failureKind === 'none'
        ? 'unknown' : result.failureKind
    };
  }

  markStartupSelectionReenablePulled(): boolean {
    const snapshot:
      SelectionReenableBarrierSnapshot =
      this.selectionReenableBarrierSnapshot();
    if (!snapshot.readable) { return false; }
    const tables: string[] =
      Object.keys(snapshot.barriers);
    return this.markSelectionReenablePulled(tables);
  }

  prepareSelectionReenablePromotions(): boolean {
    const snapshot:
      SelectionReenableBarrierSnapshot =
      this.selectionReenableBarrierSnapshot();
    if (!snapshot.readable) { return false; }
    const tables: string[] =
      Object.keys(snapshot.barriers)
      .filter((table: string): boolean =>
        snapshot.barriers[table] ===
          'pull_complete');
    if (tables.length === 0) { return true; }
    if (tables.indexOf(VNC_CLOUD_TABLE) >= 0 &&
      !this.reconcileVncSyncSelection(true)) {
      return false;
    }
    for (let i = 0; i < tables.length; i++) {
      snapshot.barriers[tables[i]] =
        cloudSelectionAfterLocalPromotion(
          'pull_complete');
    }
    return this.persistSelectionReenableBarriers(
      snapshot.barriers);
  }

  releaseSelectionReenableBarriers(): boolean {
    const snapshot:
      SelectionReenableBarrierSnapshot =
      this.selectionReenableBarrierSnapshot();
    if (!snapshot.readable) { return false; }
    const tables: string[] =
      Object.keys(snapshot.barriers)
      .filter((table: string): boolean =>
        snapshot.barriers[table] ===
          'promotion_complete');
    if (tables.length === 0) { return true; }
    if (!this.persistSelectionReenableBarriers(
      this.selectionReenableBarriersWithout(
        snapshot.barriers, tables))) {
      return false;
    }
    for (let i = 0; i < tables.length; i++) {
      if (tables[i] === VNC_CLOUD_TABLE) {
        void CloudSyncCoordinator.getInstance()
          .requestVncTableAutomaticPush();
      } else {
        void CloudSyncCoordinator.getInstance()
          .requestAutomaticPush(tables[i]);
      }
    }
    return true;
  }

  setAutomaticPushSuppressed(suppressed: boolean): void {
    this.automaticPushSuppressed = suppressed;
  }

  /** True after this device has completed one authoritative cloud-first pull. */
  hasCloudBootstrapCompleted(): boolean {
    return this.cloudBootstrapCompleted;
  }

  /**
   * Startup attempts may fail because Cloud Space is unavailable. Release the
   * local write gate after the attempt, but keep the coordinator's automatic
   * upload gate closed until a later authoritative operation succeeds.
   */
  setStartupSyncPending(pending: boolean): void {
    this.startupSyncPending = pending;
  }

  markCloudBootstrapCompleted(): boolean {
    if (!this.store ||
      !this.writeLocalMetadata(
        CLOUD_BOOTSTRAP_COMPLETED_KEY, '1') ||
      !this.localMetadataValueMatches(
        CLOUD_BOOTSTRAP_COMPLETED_KEY, '1')) {
      return false;
    }
    this.cloudBootstrapCompleted = true;
    return true;
  }

  private loadCloudSyncDurableState(): CloudSyncDurableState | null {
    const metadata: CloudMetadataReadResult =
      this.readLocalMetadataState(
        CLOUD_SYNC_DURABLE_STATE_KEY);
    if (metadata.state === 'error') {
      hilog.error(0x0001, 'CloudSync',
        '云同步持久状态查询失败，已阻止传输并等待恢复');
      return corruptedCloudSyncDurableState(
        this.cloudAccountBinding,
        this.cloudBootstrapCompleted);
    }
    if (metadata.state === 'absent') {
      return null;
    }
    try {
      return JSON.parse(metadata.value) as
        CloudSyncDurableState;
    } catch (err) {
      hilog.error(0x0001, 'CloudSync',
        '云同步持久状态损坏，已阻止传输并等待恢复: ' + safeError(err));
      return corruptedCloudSyncDurableState(
        this.cloudAccountBinding, this.cloudBootstrapCompleted);
    }
  }

  private persistCloudSyncDurableState(
    state: CloudSyncDurableState
  ): boolean {
    if (!this.store || this.currentLease === null ||
      state.ownerScopeId !== this.currentScopeToken.ownerScopeId ||
      state.storeIdentity !== this.currentScopeToken.storeIdentity ||
      state.generation !== this.currentScopeToken.generation) {
      return false;
    }
    try {
      const encoded: string =
        JSON.stringify(state);
      return this.writeLocalMetadata(
        CLOUD_SYNC_DURABLE_STATE_KEY,
        encoded) &&
        this.localMetadataValueMatches(
          CLOUD_SYNC_DURABLE_STATE_KEY,
          encoded);
    } catch (err) {
      hilog.error(0x0001, 'CloudSync',
        '云同步持久状态写入失败: ' + safeError(err));
      return false;
    }
  }

  private localMutationAllowed(): boolean {
    return this.mutationGateOpen &&
      this.localMutationEnvironmentAllowed();
  }

  private localMutationEnvironmentAllowed(): boolean {
    return cloudLocalMutationAllowed(
      this.manualDownloadSnapshot !== null,
      this.localRestoreActive || this.localRestorePending,
      this.startupSyncPending,
      this.cloudBootstrapCompleted,
      this.cloudDownloadActive,
      this.indeterminateCloudSyncOperation !== null
    );
  }

  private cryptoLifecycleMutationAllowed(
    lease: AccountSessionLease | null
  ): boolean {
    return this.exclusiveCryptoReady &&
      accountSessionLeaseEquals(this.exclusiveCryptoLease, lease) &&
      this.cryptoLeaseIsCurrent(lease) &&
      this.localMutationEnvironmentAllowed();
  }

  private coordinatorHooks(): CloudSyncCoordinatorHooks {
    return {
      beginManualDownload: (): boolean => {
        return this.beginCloudDownloadTransaction(
          'manual_download');
      },
      rollbackManualDownload: async (): Promise<boolean> => {
        return await this.rollbackCloudDownloadTransaction();
      },
      completeManualDownload: (tables: string[]): boolean => {
        // The local intent must be discarded before exposing a cloud-first
        // success; otherwise a later automatic retry could overwrite it.
        // Delete only rows covered by the before-image. Sanitizers and schema
        // adapters may create a newer journal entry while the download is
        // being applied, and that repair must survive this completion hook.
        if (!this.acknowledgeMutationJournalSnapshot(
          tables, this.manualDownloadMutationJournal || []) ||
          !this.clearRestoredNotUploaded()) {
          return false;
        }
        return this.completeCloudDownloadTransaction();
      },
      completeManualDownloadPartial: (tables: string[]): boolean => {
        // A VNC request may finish its independent vncrecord transfer while
        // cryptoparams is unavailable. Discard only the successful table's
        // journal and release the temporary snapshot; keep the global restore
        // quarantine intact until every required table has completed.
        if (!this.acknowledgeMutationJournalSnapshot(
          tables, this.manualDownloadMutationJournal || [])) {
          return false;
        }
        return this.completeCloudDownloadTransaction();
      },
      beginSelectionReenableDownload: (): boolean =>
        this.beginCloudDownloadTransaction(
          'selection_reenable'),
      rollbackSelectionReenableDownload: ():
        Promise<boolean> =>
        this.rollbackCloudDownloadTransaction(),
      completeSelectionReenableDownload: (
        tables: string[]): boolean => {
        if (tables.indexOf(
          VNC_CLOUD_TABLE) >= 0) {
          const checkpointRead:
            CloudMetadataReadResult =
            this.readLocalMetadataState(
              VNC_SELECTION_REENABLE_TRANSACTION_KEY);
          if (!cloudMetadataBoundaryReadable(
            checkpointRead)) {
            return false;
          }
          if (checkpointRead.state ===
            'present') {
            return this
              .completeVncAuthoritativeCloudFirst(
                tables);
          }
        }
        if (!this.reconcileStartupMutationSnapshot(
          tables)) {
          return false;
        }
        return this.completeCloudDownloadTransaction();
      },
      beginStartupDownload: (): boolean =>
        this.beginCloudDownloadTransaction(
          'startup_bootstrap'),
      rollbackStartupDownload: (): Promise<boolean> =>
        this.rollbackCloudDownloadTransaction(),
      completeStartupDownload: (
        tables: string[]): boolean => {
        if (!this.reconcileStartupMutationSnapshot(tables)) {
          return false;
        }
        return this.completeCloudDownloadTransaction();
      },
      setRestorePending: (pending: boolean): void => { this.localRestorePending = pending; },
      setCloudDownloadPending: (pending: boolean): void => {
        // A watchdog timeout releases the coordinator queue but cannot cancel
        // the native RDB transfer. Keep local writes frozen until the exact
        // late terminal callback clears the indeterminate fence.
        if (!pending && this.indeterminateCloudSyncOperation !== null) { return; }
        this.cloudDownloadActive = pending;
      },
      settlePendingIndeterminate: (): void => {
        this.trySettlePendingIndeterminate();
      },
      setStartupSyncPending: (pending: boolean): void => { this.setStartupSyncPending(pending); },
      hasCloudBootstrapCompleted: (): boolean => this.hasCloudBootstrapCompleted(),
      markCloudBootstrapCompleted: (): boolean => this.markCloudBootstrapCompleted(),
      discardMutationJournalForTables: (tables: string[]): boolean =>
        this.discardMutationJournalForTables(tables),
      pendingMutationTableRevisions: (): Record<string, number> => this.pendingMutationTableRevisions(),
      acknowledgeMutationJournal: (table: string, revision: number): boolean =>
        this.acknowledgeMutationJournal(table, revision),
      failureKindForTable: (_table: string): CloudSyncFailureKind => this.lastSyncFailureKind,
      hasRestoredNotUploaded: (): boolean => this.hasRestoredNotUploaded(),
      clearRestoredNotUploaded: (): boolean => this.clearRestoredNotUploaded(),
      loadDurableState: (): CloudSyncDurableState | null =>
        this.loadCloudSyncDurableState(),
      persistDurableState: (state: CloudSyncDurableState): boolean =>
        this.persistCloudSyncDurableState(state),
      selectionReenableBlocked: (table: string): boolean =>
        this.selectionReenableBlocked(table)
    };
  }

  private clearManualDownloadSnapshot(): void {
    this.manualDownloadSnapshot = null;
    this.manualDownloadExtensions = null;
    this.manualDownloadMetadata = null;
    this.manualDownloadMutationJournal = null;
    this.manualDownloadLocalTables = null;
    this.cloudDownloadCheckpointOperation = null;
  }

  private failClosedSelectionReenableBarriers():
    Record<string, string> {
    const result: Record<string, string> = {};
    for (let i = 0; i < TABLES.length; i++) {
      result[TABLES[i]] = 'pending_pull';
    }
    return result;
  }

  private selectionReenableBarrierSnapshot():
    SelectionReenableBarrierSnapshot {
    const result: Record<string, string> = {};
    const metadata: CloudMetadataReadResult =
      this.readLocalMetadataState(
      CLOUD_SELECTION_REENABLE_BARRIERS_KEY);
    if (!cloudMetadataBoundaryReadable(
      metadata)) {
      return {
        readable: false,
        barriers:
          this.failClosedSelectionReenableBarriers()
      };
    }
    if (metadata.state === 'absent') {
      return { readable: true, barriers: result };
    }
    try {
      const parsed: Record<string, Object> =
        JSON.parse(metadata.value) as
          Record<string, Object>;
      const keys: string[] = Object.keys(parsed);
      for (let i = 0; i < keys.length; i++) {
        const phase: CloudSelectionReenablePhase | null =
          normalizeCloudSelectionReenablePhase(
            parsed[keys[i]]);
        if (TABLES.indexOf(keys[i]) >= 0 &&
          phase !== null) {
          result[keys[i]] = phase;
        }
      }
    } catch (_error) {
      return {
        readable: false,
        barriers:
          this.failClosedSelectionReenableBarriers()
      };
    }
    return { readable: true, barriers: result };
  }

  private persistSelectionReenableBarriers(
    barriers: Record<string, string>
  ): boolean {
    const keys: string[] = Object.keys(barriers);
    if (keys.length === 0) {
      return this.deleteLocalMetadata(
        CLOUD_SELECTION_REENABLE_BARRIERS_KEY) &&
        cloudMetadataAbsentProven(
          this.readLocalMetadataState(
            CLOUD_SELECTION_REENABLE_BARRIERS_KEY));
    }
    const encoded: string =
      JSON.stringify(barriers);
    return this.writeLocalMetadata(
      CLOUD_SELECTION_REENABLE_BARRIERS_KEY,
      encoded) &&
      this.localMetadataValueMatches(
        CLOUD_SELECTION_REENABLE_BARRIERS_KEY,
        encoded);
  }

  private selectionReenableBarriersWithout(
    barriers: Record<string, string>,
    removedTables: string[]
  ): Record<string, string> {
    const next: Record<string, string> = {};
    const keys: string[] = Object.keys(barriers);
    for (let i = 0; i < keys.length; i++) {
      if (removedTables.indexOf(keys[i]) < 0) {
        next[keys[i]] = barriers[keys[i]];
      }
    }
    return next;
  }

  selectionReenableBlocked(
    table: string
  ): boolean {
    const snapshot:
      SelectionReenableBarrierSnapshot =
      this.selectionReenableBarrierSnapshot();
    if (!snapshot.readable) { return true; }
    const phase: CloudSelectionReenablePhase | null =
      normalizeCloudSelectionReenablePhase(
        snapshot.barriers[table]);
    return !cloudSelectionNativeFirstAllowed(phase);
  }

  private markSelectionReenablePulled(
    tables: string[]
  ): boolean {
    const snapshot:
      SelectionReenableBarrierSnapshot =
      this.selectionReenableBarrierSnapshot();
    if (!snapshot.readable) { return false; }
    for (let i = 0; i < tables.length; i++) {
      if (snapshot.barriers[tables[i]] ===
        'pending_pull') {
        snapshot.barriers[tables[i]] =
          cloudSelectionAfterAuthoritativePull(
            'pending_pull');
      }
    }
    return this.persistSelectionReenableBarriers(
      snapshot.barriers);
  }

  private captureCloudDownloadPayload():
    CloudDownloadTransactionPayload {
    return {
      snapshot: this.exportAllTableRows(),
      extensions: this.exportLocalExtensionRows(),
      metadata: this.exportLocalMetadataRows(),
      mutationJournal:
        this.exportMutationJournalRows(),
      localTables: this.exportAllLocalTableRows()
    };
  }

  private vncSelectionCheckpointIdentity():
    VncSelectionCheckpointIdentity {
    return {
      ownerScopeId:
        this.currentScopeToken.ownerScopeId,
      storeIdentity:
        this.currentScopeToken.storeIdentity,
      generation:
        this.currentScopeToken.generation
    };
  }

  private readVncSelectionReenableCheckpointState():
    VncSelectionReenableCheckpointRead {
    return readVncSelectionReenableCheckpointState(
      (key: string): CloudMetadataReadResult =>
        this.readLocalMetadataState(key),
      this.vncSelectionCheckpointIdentity());
  }

  private readVncSelectionReenableCheckpoint():
    VncSelectionReenableCheckpoint | null {
    return this
      .readVncSelectionReenableCheckpointState()
      .checkpoint;
  }

  private cloneMetadataRow(
    row: Record<string, string>
  ): Record<string, string> {
    const result: Record<string, string> = {};
    const keys: string[] = Object.keys(row);
    for (let i = 0; i < keys.length; i++) {
      result[keys[i]] = row[keys[i]];
    }
    return result;
  }

  private metadataRow(
    rows: Array<Record<string, string>>,
    key: string
  ): Record<string, string> | null {
    for (let i = 0; i < rows.length; i++) {
      if (rows[i]['key'] === key) {
        return this.cloneMetadataRow(rows[i]);
      }
    }
    return null;
  }

  private metadataWithoutKeys(
    rows: Array<Record<string, string>>,
    keys: string[]
  ): Array<Record<string, string>> {
    const result: Array<Record<string, string>> = [];
    for (let i = 0; i < rows.length; i++) {
      if (keys.indexOf(rows[i]['key'] || '') < 0) {
        result.push(
          this.cloneMetadataRow(rows[i]));
      }
    }
    return result;
  }

  private metadataWithVncBarrier(
    rows: Array<Record<string, string>>,
    phase: CloudSelectionReenablePhase | null
  ): Array<Record<string, string>> {
    const result: Array<Record<string, string>> =
      this.metadataWithoutKeys(
        rows,
        [CLOUD_SELECTION_REENABLE_BARRIERS_KEY]);
    const current: Record<string, string> | null =
      this.metadataRow(
        rows,
        CLOUD_SELECTION_REENABLE_BARRIERS_KEY);
    let barriers: Record<string, string> = {};
    if (current !== null) {
      try {
        barriers = JSON.parse(
          current['value'] || '{}') as
            Record<string, string>;
      } catch (_error) {
        barriers = {};
      }
    }
    if (phase === null) {
      barriers =
        this.selectionReenableBarriersWithout(
          barriers, [VNC_CLOUD_TABLE]);
    } else {
      barriers[VNC_CLOUD_TABLE] = phase;
    }
    if (Object.keys(barriers).length > 0) {
      const row: Record<string, string> = {};
      row['key'] =
        CLOUD_SELECTION_REENABLE_BARRIERS_KEY;
      row['value'] = JSON.stringify(barriers);
      row['updatedat'] = Date.now().toString();
      result.push(row);
    }
    return result;
  }

  /**
   * Once cloud-first has committed, replace the prepared checkpoint with a
   * rollback image that preserves the authoritative cloud mirror. The
   * pre-save local settings row, selector barrier and its journal entries are
   * spliced back into that image so finalization failure undoes only the
   * user's uncommitted scope change.
   */
  private stageAuthoritativeVncSelectionBeforeImageWithinTransaction():
    boolean {
    if (!this.store) { return false; }
    const checkpoint:
      VncSelectionReenableCheckpoint | null =
      this.readVncSelectionReenableCheckpoint();
    if (checkpoint === null ||
      checkpoint.payload.stage !== 'prepared') {
      return false;
    }
    const current: CloudDownloadTransactionPayload =
      this.captureCloudDownloadPayload();
    const rollbackRows = vncSettingsRollbackRows(
      current.snapshot[VNC_CLOUD_TABLE] || [],
      current.localTables[VNC_LOCAL_TABLE] || [],
      checkpoint.payload.localTables[
        VNC_LOCAL_TABLE] || [],
      checkpoint.payload.settingsId);
    current.snapshot[VNC_CLOUD_TABLE] =
      rollbackRows.cloudRows;
    current.localTables[VNC_LOCAL_TABLE] =
      rollbackRows.localRows;
    current.mutationJournal =
      vncSettingsRollbackJournal(
        current.mutationJournal,
        checkpoint.payload.mutationJournal,
        checkpoint.payload.settingsId,
        VNC_CLOUD_TABLE, VNC_LOCAL_TABLE);
    const previousBarrier:
      CloudSelectionReenablePhase | null =
      checkpoint.payload.previousBarrier === ''
        ? null
        : normalizeCloudSelectionReenablePhase(
          checkpoint.payload.previousBarrier);
    current.metadata =
      this.metadataWithVncBarrier(
        this.metadataWithoutKeys(
          current.metadata,
          [
            VNC_SELECTION_REENABLE_TRANSACTION_KEY,
            CLOUD_DOWNLOAD_TRANSACTION_KEY
          ]),
        previousBarrier);
    const next:
      VncSelectionReenableTransactionPayload = {
      snapshot: current.snapshot,
      extensions: current.extensions,
      metadata: current.metadata,
      mutationJournal:
        current.mutationJournal,
      localTables: current.localTables,
      stage: 'authoritative',
      previousScopes:
        checkpoint.payload.previousScopes.slice(),
      previousBarrier:
        checkpoint.payload.previousBarrier,
      settingsId:
        checkpoint.payload.settingsId
    };
    const envelope:
      CloudDownloadTransactionEnvelope | null =
      cloudDownloadTransactionEnvelope(
        'vnc_scope_reenable',
        this.currentScopeToken.ownerScopeId,
        this.currentScopeToken.storeIdentity,
        this.currentScopeToken.generation,
        JSON.stringify(next));
    const encodedEnvelope: string =
      envelope === null
        ? '' : JSON.stringify(envelope);
    if (envelope === null ||
      !this.writeLocalMetadata(
        VNC_SELECTION_REENABLE_TRANSACTION_KEY,
        encodedEnvelope) ||
      !this.localMetadataValueMatches(
        VNC_SELECTION_REENABLE_TRANSACTION_KEY,
        encodedEnvelope)) {
      return false;
    }
    return true;
  }

  private persistVncSelectionBarrierPhase(
    expected: CloudSelectionReenablePhase,
    next: CloudSelectionReenablePhase
  ): boolean {
    const snapshot:
      SelectionReenableBarrierSnapshot =
      this.selectionReenableBarrierSnapshot();
    if (!snapshot.readable ||
      snapshot.barriers[VNC_CLOUD_TABLE] !==
        expected) {
      return false;
    }
    snapshot.barriers[VNC_CLOUD_TABLE] = next;
    return this.persistSelectionReenableBarriers(
      snapshot.barriers);
  }

  private promoteVncSelectionWithinTransaction(
    records: VncRecord[]
  ): boolean {
    const physicalTableSelected: boolean =
      this.syncSelection.selectedBusinessTables()
        .indexOf(VNC_CLOUD_TABLE) >= 0;
    if (!physicalTableSelected) { return false; }
    for (let i = 0; i < records.length; i++) {
      const record: VncRecord = records[i];
      const selected: boolean =
        this.vncSyncSelection.isRecordTypeSelected(
          record.recordType);
      const secretAllowed: boolean =
        record.recordType !== 'secret' ||
        this.vncSyncSelection.secretsAllowed();
      if (selected && secretAllowed) {
        if (!this.upsertVncRecordInternal(
          record, false) ||
          !this.upsertVncRecordInternal(
            record, true) ||
          !this.recordLocalMutation(
            VNC_CLOUD_TABLE, record.id,
            'scope_promote')) {
          return false;
        }
      } else if (!this.upsertVncRecordInternal(
        record, true)) {
        return false;
      }
    }
    return true;
  }

  /**
   * Promotion, phase changes, release and checkpoint deletion form one RDB
   * commit. Automatic upload is scheduled only after that commit.
   */
  private finalizeVncSelectionReenableTransaction():
    boolean {
    const port:
      CloudStoreVncSelectionFinalizationPort | null =
      this.vncSelectionFinalizationPort();
    if (port === null) { return false; }
    const result:
      VncSelectionFinalizationWiringResult =
      finalizeVncSelectionReenable(port);
    if (!result.ok &&
      !result.transaction.ok) {
      hilog.error(0x0001, 'CloudSync',
        'VNC scope finalization failed step=' +
        result.transaction.failedStep);
    }
    return result.ok;
  }

  private vncSelectionFinalizationPort():
    CloudStoreVncSelectionFinalizationPort | null {
    if (!this.store) { return null; }
    const store: relationalStore.RdbStore =
      this.store;
    let records: VncRecord[] = [];
    const port:
      CloudStoreVncSelectionFinalizationPort = {
      checkpointIdentity:
        (): VncSelectionCheckpointIdentity =>
          this.vncSelectionCheckpointIdentity(),
      readMetadataState:
        (key: string):
          CloudMetadataReadResult =>
          this.readLocalMetadataState(key),
      preparePromotion: (): boolean => {
        records = this.mergeVncRecords(
          true,
          this.currentOwnerScopeId(),
          false);
        return true;
      },
      beginTransaction: (): boolean => {
        store.beginTransaction();
        return true;
      },
      persistPullComplete: (): boolean =>
        this.persistVncSelectionBarrierPhase(
          'pending_pull', 'pull_complete'),
      promote: (): boolean =>
        this.promoteVncSelectionWithinTransaction(
          records),
      persistPromotionComplete: (): boolean =>
        this.persistVncSelectionBarrierPhase(
          'pull_complete',
          'promotion_complete'),
      releaseBarrier: (): boolean => {
        const snapshot:
          SelectionReenableBarrierSnapshot =
          this.selectionReenableBarrierSnapshot();
        if (!snapshot.readable ||
          snapshot.barriers[
            VNC_CLOUD_TABLE] !==
          'promotion_complete') {
          return false;
        }
        return this.persistSelectionReenableBarriers(
          this.selectionReenableBarriersWithout(
            snapshot.barriers,
            [VNC_CLOUD_TABLE]));
      },
      deleteCheckpoint: (): boolean =>
        this.deleteLocalMetadata(
          VNC_SELECTION_REENABLE_TRANSACTION_KEY),
      commit: (): boolean => {
        store.commit();
        return true;
      },
      rollback: (): void => {
        store.rollBack();
      },
      requestAutomaticUpload: (): void => {
        void CloudSyncCoordinator.getInstance()
          .requestVncTableAutomaticPush();
      }
    };
    return port;
  }

  private cloudDownloadPayloadFromMemory():
    CloudDownloadTransactionPayload | null {
    if (this.manualDownloadSnapshot === null ||
      this.manualDownloadExtensions === null ||
      this.manualDownloadMetadata === null ||
      this.manualDownloadMutationJournal === null ||
      this.manualDownloadLocalTables === null) {
      return null;
    }
    return {
      snapshot: this.manualDownloadSnapshot,
      extensions: this.manualDownloadExtensions,
      metadata: this.manualDownloadMetadata,
      mutationJournal:
        this.manualDownloadMutationJournal,
      localTables: this.manualDownloadLocalTables
    };
  }

  /**
   * Persist the before-image in the account's non-distributed metadata table
   * before the platform is allowed to mutate any cloud table. A process death
   * therefore leaves a recoverable transaction instead of an in-memory-only
   * rollback promise.
   */
  private beginCloudDownloadTransaction(
    operation: CloudDownloadTransactionOperation
  ): boolean {
    if (!this.store ||
      !cloudMetadataAbsentProven(
        this.readLocalMetadataState(
          CLOUD_DOWNLOAD_TRANSACTION_KEY))) {
      return false;
    }
    try {
      this.store.beginTransaction();
      this.manualDownloadSnapshot =
        this.exportAllTableRows();
      this.manualDownloadExtensions =
        this.exportLocalExtensionRows();
      this.manualDownloadMetadata =
        this.exportLocalMetadataRows();
      this.manualDownloadMutationJournal =
        this.exportMutationJournalRows();
      this.manualDownloadLocalTables =
        this.exportAllLocalTableRows();
      const payload: CloudDownloadTransactionPayload | null =
        this.cloudDownloadPayloadFromMemory();
      if (payload === null) {
        throw new Error(
          'cloud download before-image unavailable');
      }
      const payloadJson: string = JSON.stringify(payload);
      const envelope: CloudDownloadTransactionEnvelope | null =
        cloudDownloadTransactionEnvelope(
          operation,
          this.currentScopeToken.ownerScopeId,
          this.currentScopeToken.storeIdentity,
          this.currentScopeToken.generation,
          payloadJson);
      const encodedEnvelope: string =
        envelope === null
          ? '' : JSON.stringify(envelope);
      if (envelope === null) {
        throw new Error(
          'cloud download before-image envelope unavailable');
      }
      if (!this.writeLocalMetadata(
        CLOUD_DOWNLOAD_TRANSACTION_KEY,
        encodedEnvelope)) {
        throw new Error(
          'cloud download transaction metadata write failed');
      }
      this.store.commit();
      // Real-device OpenHarmony RDB does not expose uncommitted writes to a
      // subsequent querySync on the same store, so the read-back verification
      // must run after commit. A verification failure removes the row and
      // fails the transaction (the in-memory snapshots are discarded).
      if (!this.localMetadataValueMatches(
        CLOUD_DOWNLOAD_TRANSACTION_KEY,
        encodedEnvelope)) {
        this.deleteLocalMetadata(
          CLOUD_DOWNLOAD_TRANSACTION_KEY);
        throw new Error(
          'cloud download transaction persistence verification failed');
      }
      this.cloudDownloadCheckpointOperation = operation;
      return true;
    } catch (err) {
      try { this.store.rollBack(); } catch (_ignored) {}
      this.clearManualDownloadSnapshot();
      hilog.error(0x0001, 'CloudSync',
        '云下载 before-image 建立失败: ' +
        safeError(err));
      return false;
    }
  }

  private completeCloudDownloadTransaction(): boolean {
    if (this.cloudDownloadCheckpointOperation === null ||
      !this.deleteLocalMetadata(
        CLOUD_DOWNLOAD_TRANSACTION_KEY) ||
      !cloudMetadataAbsentProven(
        this.readLocalMetadataState(
          CLOUD_DOWNLOAD_TRANSACTION_KEY))) {
      return false;
    }
    this.clearManualDownloadSnapshot();
    return true;
  }

  /**
   * Coordinator completion boundary. Persistence I/O is injectable, while
   * admission, ordering, read-back validation and publication stay in this
   * production method.
   */
  private completeVncAuthoritativeCloudFirst(
    tables: string[]
  ): boolean {
    const port:
      CloudStoreVncAuthoritativeCompletionPort | null =
      this.vncAuthoritativeCompletionPort();
    if (port === null) { return false; }
    const result:
      VncAuthoritativeCompletionWiringResult =
      completeVncAuthoritativeCloudFirstWiring(
        tables, port);
    if (!result.transaction.ok) {
      hilog.error(0x0001, 'CloudSync',
        'VNC cloud-first 权威 checkpoint 原子提交失败 step=' +
        result.transaction.failedStep);
    } else if (!result.ok) {
      hilog.error(0x0001, 'CloudSync',
        'VNC cloud-first 权威 checkpoint 提交后校验失败');
    }
    return result.ok;
  }

  private vncAuthoritativeCompletionPort():
    CloudStoreVncAuthoritativeCompletionPort | null {
    if (!this.store) { return null; }
    const store: relationalStore.RdbStore =
      this.store;
    const port:
      CloudStoreVncAuthoritativeCompletionPort = {
      activeOperation:
        (): CloudDownloadTransactionOperation | null =>
          this.cloudDownloadCheckpointOperation,
      checkpointIdentity:
        (): VncSelectionCheckpointIdentity =>
          this.vncSelectionCheckpointIdentity(),
      readMetadataState:
        (key: string):
          CloudMetadataReadResult =>
          this.readLocalMetadataState(key),
      beginTransaction: (): boolean => {
        store.beginTransaction();
        return true;
      },
      rebaseAuthoritativeCheckpoint:
        (): boolean =>
          this
            .stageAuthoritativeVncSelectionBeforeImageWithinTransaction(),
      reconcileJournal:
        (tables: string[]): boolean =>
          this
            .reconcileStartupMutationSnapshotWithinTransaction(
              tables),
      deleteDownloadCheckpoint: (): boolean =>
        this.deleteLocalMetadata(
          CLOUD_DOWNLOAD_TRANSACTION_KEY),
      commit: (): boolean => {
        store.commit();
        return true;
      },
      rollback: (): void => {
        store.rollBack();
      },
      clearInMemorySnapshot: (): void => {
        this.clearManualDownloadSnapshot();
      }
    };
    return port;
  }

  private async rollbackCloudDownloadTransaction():
    Promise<boolean> {
    const payload: CloudDownloadTransactionPayload | null =
      this.cloudDownloadPayloadFromMemory();
    const restored: boolean = payload !== null &&
      (await this.restoreManualDownloadSnapshot(
        payload.snapshot,
        payload.extensions,
        payload.metadata,
        payload.mutationJournal,
        payload.localTables));
    const checkpointCleared: boolean =
      restored &&
      this.deleteLocalMetadata(
        CLOUD_DOWNLOAD_TRANSACTION_KEY) &&
      cloudMetadataAbsentProven(
        this.readLocalMetadataState(
          CLOUD_DOWNLOAD_TRANSACTION_KEY));
    this.clearManualDownloadSnapshot();
    return restored && checkpointCleared;
  }

  private async recoverPendingCloudDownloadTransaction():
    Promise<boolean> {
    const metadata: CloudMetadataReadResult =
      this.readLocalMetadataState(
      CLOUD_DOWNLOAD_TRANSACTION_KEY);
    if (metadata.state === 'absent') {
      return true;
    }
    if (metadata.state === 'error') {
      return false;
    }
    const envelope: CloudDownloadTransactionEnvelope | null =
      parseCloudDownloadTransactionEnvelope(
        metadata.value,
        this.currentScopeToken.ownerScopeId,
        this.currentScopeToken.storeIdentity,
        this.currentScopeToken.generation);
    if (envelope === null) { return false; }
    try {
      const payload: CloudDownloadTransactionPayload =
        JSON.parse(envelope.payloadJson) as
          CloudDownloadTransactionPayload;
      const restored: boolean =
        await this.restoreManualDownloadSnapshot(
          payload.snapshot,
          payload.extensions,
          payload.metadata,
          payload.mutationJournal,
          payload.localTables);
      if (!restored) { return false; }
      if (!this.deleteLocalMetadata(
        CLOUD_DOWNLOAD_TRANSACTION_KEY) ||
        !cloudMetadataAbsentProven(
          this.readLocalMetadataState(
            CLOUD_DOWNLOAD_TRANSACTION_KEY))) {
        return false;
      }
      hilog.warn(0x0001, 'CloudSync',
        '已回滚上次未终结的云下载事务 operation=' +
        envelope.operation);
      return true;
    } catch (_error) {
      return false;
    }
  }

  private vncRecoveryMetadata(
    checkpoint: VncSelectionReenableCheckpoint
  ): Array<Record<string, string>> {
    let metadata: Array<Record<string, string>> =
      this.metadataWithoutKeys(
        checkpoint.payload.metadata,
        [
          VNC_SELECTION_REENABLE_TRANSACTION_KEY,
          CLOUD_DOWNLOAD_TRANSACTION_KEY,
          CLOUD_SELECTION_REENABLE_BARRIERS_KEY,
          CLOUD_SYNC_DURABLE_STATE_KEY
        ]);
    // Keep the coordinator's latest post-pull/failure lifecycle and retry
    // state aligned with its in-memory state during an in-process rollback.
    const currentMetadata: Array<Record<string, string>> =
      this.exportLocalMetadataRows();
    const durable: Record<string, string> | null =
      this.metadataRow(
        currentMetadata,
        CLOUD_SYNC_DURABLE_STATE_KEY);
    if (durable !== null) {
      metadata.push(durable);
    }
    const previousBarrier:
      CloudSelectionReenablePhase | null =
      checkpoint.payload.previousBarrier === ''
        ? null
        : normalizeCloudSelectionReenablePhase(
          checkpoint.payload.previousBarrier);
    const originalBarrierRow:
      Record<string, string> | null =
      this.metadataRow(
        checkpoint.payload.metadata,
        CLOUD_SELECTION_REENABLE_BARRIERS_KEY);
    let barriers: Record<string, string> = {};
    if (originalBarrierRow !== null) {
      try {
        barriers = JSON.parse(
          originalBarrierRow['value'] || '{}') as
            Record<string, string>;
      } catch (_error) {
        barriers = {};
      }
    }
    const recoveryPhase:
      CloudSelectionReenablePhase | null =
      vncSelectionRecoveryBarrier(
        true, previousBarrier);
    if (recoveryPhase !== null) {
      barriers[VNC_CLOUD_TABLE] =
        recoveryPhase;
    }
    const barrierMetadata:
      Record<string, string> = {};
    barrierMetadata['key'] =
      CLOUD_SELECTION_REENABLE_BARRIERS_KEY;
    barrierMetadata['value'] =
      JSON.stringify(barriers);
    barrierMetadata['updatedat'] =
      Date.now().toString();
    metadata.push(barrierMetadata);
    // The checkpoint survives the data restore and is removed only after the
    // previous selector has also been durably restored.
    const checkpointMetadata:
      Record<string, string> = {};
    checkpointMetadata['key'] =
      VNC_SELECTION_REENABLE_TRANSACTION_KEY;
    checkpointMetadata['value'] =
      checkpoint.raw;
    checkpointMetadata['updatedat'] =
      Date.now().toString();
    metadata.push(checkpointMetadata);
    return metadata;
  }

  private markVncSelectionRecoveryRequired():
    boolean {
    const coordinator: CloudSyncCoordinator =
      CloudSyncCoordinator.getInstance();
    if (this.currentLease !== null &&
      accountSessionLeaseEquals(
        coordinator.currentAccountLease(),
        this.currentLease) &&
      coordinator.requireExternalRecovery(
        [VNC_CLOUD_TABLE])) {
      return true;
    }
    const recovered: CloudSyncDurableState =
      recoverCloudSyncDurableState(
        this.loadCloudSyncDurableState(),
        this.cloudAccountBinding,
        cloudTransferAllowed(
          this.cloudAccountBinding),
        this.cloudBootstrapCompleted);
    const required: CloudSyncDurableState =
      cloudSyncExternalRecoveryRequired(
        recovered, [VNC_CLOUD_TABLE]);
    return this.persistCloudSyncDurableState(
      required);
  }

  private vncSelectionExclusiveLeaseCurrent(
    lease: AccountSessionLease | null
  ): boolean {
    return lease !== null &&
      this.currentLease !== null &&
      accountSessionLeaseEquals(
        this.currentLease, lease) &&
      CloudSyncCoordinator.getInstance()
        .isExclusiveVncSelectionLease(lease);
  }

  async rollbackVncSelectionReenableTransaction(
    lease: AccountSessionLease
  ): Promise<boolean> {
    if (!this.vncSelectionExclusiveLeaseCurrent(
      lease)) {
      this.markVncSelectionRecoveryRequired();
      return false;
    }
    return await this
      .rollbackVncSelectionReenableTransactionInternal();
  }

  private async rollbackVncSelectionReenableTransactionInternal():
    Promise<boolean> {
    return await this
      .rollbackVncSelectionCheckpointInternal(
        null);
  }

  private async rollbackVncSelectionCheckpointInternal(
    checkpointOverride:
      VncSelectionReenableCheckpoint | null
  ): Promise<boolean> {
    const runner:
      CloudStoreStartupRecoveryRunner | null =
      this.vncSelectionStartupRecoveryRunner();
    if (runner === null) {
      this.markVncSelectionRecoveryRequired();
      return false;
    }
    const checkpoint:
      VncSelectionReenableCheckpoint | null =
      checkpointOverride === null
        ? this.readVncSelectionReenableCheckpoint()
        : checkpointOverride;
    if (checkpoint === null) {
      this.markVncSelectionRecoveryRequired();
      return false;
    }
    const restored: boolean =
      await runner.rollbackCheckpoint(
        checkpoint);
    if (!restored) {
      hilog.error(0x0001, 'CloudSync',
        'VNC scope rollback finalization failed');
    }
    return restored;
  }

  private vncSelectionStartupRecoveryRunner():
    CloudStoreStartupRecoveryRunner | null {
    const io:
      CloudStoreStartupRecoveryIo | null =
      this.vncSelectionStartupRecoveryIo();
    if (io === null) {
      return null;
    }
    return new CloudStoreStartupRecoveryRunner(
      io);
  }

  /**
   * Construct the live startup adapter once for both production and the
   * detached initialization contract. The verification branch substitutes
   * only bottom-level I/O; checkpoint projection, table/key routing and the
   * startup state machine remain production code.
   */
  private vncSelectionStartupRecoveryIo():
    CloudStoreStartupRecoveryIo | null {
    const verification:
      CloudStoreStartupRecoveryIo | null =
      this.startupRecoveryVerificationIo;
    const store:
      relationalStore.RdbStore | null =
      this.store;
    const context:
      common.Context | null =
      this.appContext;
    if (verification === null &&
      (store === null || context === null)) {
      return null;
    }
    return {
      checkpointIdentity:
        (): VncSelectionCheckpointIdentity =>
          verification !== null
            ? verification
              .checkpointIdentity()
            : this
              .vncSelectionCheckpointIdentity(),
      readMetadataState:
        (key: string):
          CloudMetadataReadResult =>
          verification !== null
            ? verification
              .readMetadataState(key)
            : this
              .readLocalMetadataState(key),
      recoveryMetadata: (
        checkpoint:
          VncSelectionReenableCheckpoint
      ): Array<Record<string, string>> =>
        verification !== null
          ? verification
            .recoveryMetadata(checkpoint)
          : this.vncRecoveryMetadata(
            checkpoint),
      restoreManualDownloadSnapshot:
        async (
          snapshot:
            Record<string,
              Array<Record<string, string>>>,
          extensions:
            Array<Record<string, string>>,
          metadata:
            Array<Record<string, string>>,
          mutationJournal:
            Array<Record<string, string>>,
          localTables:
            Record<string,
              Array<Record<string, string>>>
        ): Promise<boolean> => {
          if (verification !== null) {
            return await verification
              .restoreManualDownloadSnapshot(
                snapshot,
                extensions,
                metadata,
                mutationJournal,
                localTables);
          }
          return await this
            .restoreManualDownloadSnapshot(
              snapshot,
              extensions,
              metadata,
              mutationJournal,
              localTables);
        },
      stageSelectedScopes:
        (scopes: string[]): void => {
          if (verification !== null) {
            verification
              .stageSelectedScopes(scopes);
            return;
          }
          this.vncSyncSelection
            .stageSelectedScopes(scopes);
        },
      persistSelectedScopes:
        (): boolean => {
          if (verification !== null) {
            return verification
              .persistSelectedScopes();
          }
          if (context === null) {
            return false;
          }
          return this.vncSyncSelection
            .persistSelectedScopes(context);
        },
      beginTransaction: (): boolean => {
        if (verification !== null) {
          return verification
            .beginTransaction();
        }
        if (store === null) {
          return false;
        }
        store.beginTransaction();
        return true;
      },
      settleRecoveryLifecycle: (): boolean => {
        if (verification !== null) {
          return verification
            .settleRecoveryLifecycle();
        }
        const durable:
          CloudSyncDurableState | null =
          this.loadCloudSyncDurableState();
        if (durable === null ||
          durable.phase !==
            'recovery_required' ||
          durable.lastFailureKind !==
            'unknown' ||
          durable.failedTables.indexOf(
            VNC_CLOUD_TABLE) < 0) {
          return true;
        }
        const coordinator:
          CloudSyncCoordinator =
          CloudSyncCoordinator.getInstance();
        if (this.currentLease !== null &&
          accountSessionLeaseEquals(
            coordinator.currentAccountLease(),
            this.currentLease)) {
          return false;
        }
        const settled:
          CloudSyncDurableState =
          cloudSyncExternalRecoverySettled(
            durable,
            this.cloudAccountBinding,
            cloudTransferAllowed(
              this.cloudAccountBinding),
            [VNC_CLOUD_TABLE]);
        return settled.phase !==
          'recovery_required' &&
          this.persistCloudSyncDurableState(
            settled);
      },
      restoreSelectionReenableBarrier: (
        table: string,
        previousPhase:
          CloudSelectionReenablePhase | null
      ): boolean => {
        if (table !== VNC_CLOUD_TABLE) {
          return false;
        }
        if (verification !== null) {
          return verification
            .restoreSelectionReenableBarrier(
              table,
              previousPhase);
        }
        return this
          .restoreSelectionReenableBarrier(
            table,
            previousPhase);
      },
      deleteLocalMetadata:
        (key: string): boolean =>
          verification !== null
            ? verification
              .deleteLocalMetadata(key)
            : this
              .deleteLocalMetadata(key),
      commit: (): boolean => {
        if (verification !== null) {
          return verification.commit();
        }
        if (store === null) {
          return false;
        }
        store.commit();
        return true;
      },
      rollback: (): void => {
        if (verification !== null) {
          verification.rollback();
        } else if (store !== null) {
          store.rollBack();
        }
      },
      publishSnapshot: (): void => {
        if (verification !== null) {
          verification.publishSnapshot();
        } else {
          this.notifyDataSnapshotChanged();
        }
      },
      markRecoveryRequired: (): void => {
        if (verification !== null) {
          verification
            .markRecoveryRequired();
        } else {
          this
            .markVncSelectionRecoveryRequired();
        }
      },
      onRecovered: (): void => {
        if (verification !== null) {
          verification.onRecovered();
        } else {
          hilog.warn(0x0001, 'CloudSync',
            '已回滚上次未终结的 VNC scope 事务');
        }
      }
    };
  }

  private async recoverPendingVncSelectionReenableTransaction():
    Promise<boolean> {
    const runner:
      CloudStoreStartupRecoveryRunner | null =
      this.vncSelectionStartupRecoveryRunner();
    if (runner === null) {
      this.markVncSelectionRecoveryRequired();
      return false;
    }
    return await runner.recoverPending();
  }

  /**
   * Re-apply only records named by the pre-bootstrap journal. Cloud rows for
   * unrelated records remain authoritative, while genuine offline/user
   * mutations keep both their value and upload intent.
   */
  private reconcileStartupMutationSnapshot(
    tables: string[]
  ): boolean {
    if (!this.store) { return false; }
    try {
      this.store.beginTransaction();
      if (!this
        .reconcileStartupMutationSnapshotWithinTransaction(
          tables)) {
        throw new Error(
          'record-level journal reconcile failed');
      }
      this.store.commit();
      return true;
    } catch (err) {
      try { this.store.rollBack(); } catch (_ignored) {}
      hilog.error(0x0001, 'CloudSync',
        '启动 journal 记录级 reconcile 失败: ' +
        safeError(err));
      return false;
    }
  }

  private reconcileStartupMutationSnapshotWithinTransaction(
    tables: string[]
  ): boolean {
    if (!this.store) { return false; }
    const payload: CloudDownloadTransactionPayload | null =
      this.cloudDownloadPayloadFromMemory();
    if (payload === null) { return false; }
    try {
      for (let i = 0; i < tables.length; i++) {
        const table: string = tables[i];
        if (TABLES.indexOf(table) < 0) { continue; }
        const journalRows: Array<Record<string, string>> =
          payload.mutationJournal.filter(
            (row: Record<string, string>): boolean =>
              row['tablename'] === table);
        if (journalRows.length === 0) { continue; }
        const restoreWholeTable: boolean =
          journalRows.some(
            (row: Record<string, string>): boolean =>
              row['recordid'] ===
                TABLE_MUTATION_RECORD_ID);
        if (restoreWholeTable) {
          this.store.deleteSync(
            new relationalStore.RdbPredicates(table));
          const allRows: Array<Record<string, string>> =
            payload.snapshot[table] || [];
          for (let r = 0; r < allRows.length; r++) {
            if (!rdbInsertSucceeded(
              this.store.insertSync(
                table, allRows[r],
                relationalStore.ConflictResolution
                  .ON_CONFLICT_REPLACE))) {
              throw new Error(
                'startup table reconcile insert failed');
            }
          }
          continue;
        }
        const beforeRows: Array<Record<string, string>> =
          payload.snapshot[table] || [];
        for (let j = 0; j < journalRows.length; j++) {
          let recordId: string =
            journalRows[j]['recordid'] || '';
          if (table === 'usersettings' &&
            recordId.indexOf('setting:') !== 0) {
            recordId = 'setting:' + recordId;
          }
          if (recordId === '') { throw new Error(
            'startup journal record identity missing'); }
          const predicates =
            new relationalStore.RdbPredicates(table);
          predicates.equalTo('id', recordId);
          const before = beforeRows.find(
            (row: Record<string, string>): boolean =>
              row['id'] === recordId);
          const action:
            CloudBootstrapRecordReconcileAction =
            cloudBootstrapRecordReconcileAction(
              false,
              journalRows[j]['operation'] || '',
              before !== undefined);
          if (action === 'invalid') {
            throw new Error(
              'startup journal before-image missing');
          }
          this.store.deleteSync(predicates);
          if (before !== undefined &&
            !rdbInsertSucceeded(this.store.insertSync(
              table, before,
              relationalStore.ConflictResolution
                .ON_CONFLICT_REPLACE))) {
            throw new Error(
              'startup record reconcile insert failed');
          }
        }
      }
      return true;
    } catch (err) {
      hilog.error(0x0001, 'CloudSync',
        '事务内 journal 记录级 reconcile 失败: ' +
        safeError(err));
      return false;
    }
  }

  getLastSyncFailureKind(): CloudSyncFailureKind {
    return this.lastSyncFailureKind;
  }

  getLastSyncErrorMessage(): string {
    if (this.lastSyncFailureKind === 'none') { return ''; }
    return cloudSyncFailureMessage(this.lastSyncFailureKind);
  }

  pendingSyncTableCount(): number {
    return CloudSyncCoordinator.getInstance().pendingTableCount();
  }

  /** 本地备份专用：以稳定列顺序导出云表，不触发云同步。 */
  exportAllTableRows(): Record<string, Array<Record<string, string>>> {
    if (!this.store) {
      throw new Error('portable backup store unavailable');
    }
    const snapshot: Record<string, Array<Record<string, string>>> = {};
    for (let i = 0; i < TABLES.length; i++) {
      snapshot[TABLES[i]] = this.exportTableRows(TABLES[i]);
    }
    return snapshot;
  }

  private exportTableRows(table: string): Array<Record<string, string>> {
    const result: Array<Record<string, string>> = [];
    if (!this.store) {
      throw new Error('portable backup store unavailable');
    }
    let rows: relationalStore.ResultSet | null = null;
    try {
      const predicates = new relationalStore.RdbPredicates(table);
      if (table !== 'cryptoparams') {
        this.addCurrentOwnerPredicate(predicates);
      }
      rows = this.store.querySync(predicates);
      const columns: string[] = localBackupColumnsForTable(table);
      while (rows.goToNextRow()) {
        const deletedIndex: number =
          rows.getColumnIndex(relationalStore.Field.DELETED_FLAG_FIELD);
        // Cloud deleted rows have no portable application-level tombstone
        // contract. Exclude them instead of stripping the system flag and
        // accidentally restoring them as live records.
        if (deletedIndex >= 0 && rows.getLong(deletedIndex) !== 0) {
          continue;
        }
        const row: Record<string, string> = {};
        for (let c = 0; c < columns.length; c++) {
          const index: number = rows.getColumnIndex(columns[c]);
          // Keep nullable migration columns absent instead of converting NULL
          // into an invalid typed value during a safety restore.
          if (index >= 0 && !rows.isColumnNull(index)) { row[columns[c]] = rows.getString(index); }
        }
        result.push(row);
      }
      result.sort((a: Record<string, string>, b: Record<string, string>): number =>
        (a['id'] || '').localeCompare(b['id'] || ''));
    } catch (err) {
      throw new Error(
        'portable backup table export failed table=' + table +
        ' — ' + safeError(err));
    } finally {
      if (rows !== null) { rows.close(); }
    }
    return result;
  }

  private countVisibleTableRows(table: string): number {
    if (!this.store) { return 0; }
    let count: number = 0;
    try {
      const rows = this.store.querySync(new relationalStore.RdbPredicates(table));
      const deletedIndex: number = rows.getColumnIndex(relationalStore.Field.DELETED_FLAG_FIELD);
      while (rows.goToNextRow()) {
        if (deletedIndex < 0 || rows.getLong(deletedIndex) === 0) { count++; }
      }
      rows.close();
    } catch (err) {
      hilog.warn(0x0001, 'CloudSync', '[CloudStore] count visible rows failed table=' + table +
        ' err=' + safeError(err));
    }
    return count;
  }

  private countCloudDeletedRows(table: string): number {
    if (!this.store) { return 0; }
    let count: number = 0;
    try {
      const rows = this.store.querySync(new relationalStore.RdbPredicates(table));
      const deletedIndex: number = rows.getColumnIndex(relationalStore.Field.DELETED_FLAG_FIELD);
      while (rows.goToNextRow()) {
        if (deletedIndex >= 0 && rows.getLong(deletedIndex) !== 0) { count++; }
      }
      rows.close();
    } catch (_e) { return 0; }
    return count;
  }

  private async restoreProtectedTableRows(table: string,
    rows: Array<Record<string, string>>): Promise<boolean> {
    if (!this.store) { return false; }
    this.setAutomaticPushSuppressed(true);
    this.localRestoreActive = true;
    try {
      const columns: string[] = localBackupColumnsForTable(table);
      this.store.beginTransaction();
      await this.store.executeSql('DELETE FROM ' + table);
      for (let i = 0; i < rows.length; i++) {
        const bucket: relationalStore.ValuesBucket = {};
        const keys: string[] = Object.keys(rows[i]);
        for (let k = 0; k < keys.length; k++) {
          if (columns.indexOf(keys[k]) < 0) { throw new Error('restore unknown column'); }
          bucket[keys[k]] = rows[i][keys[k]];
        }
        if (!rdbInsertSucceeded(this.store.insertSync(table, bucket,
          relationalStore.ConflictResolution.ON_CONFLICT_REPLACE))) {
          throw new Error('restore insert failed');
        }
      }
      this.store.commit();
      return true;
    } catch (err) {
      try { this.store.rollBack(); } catch (_ignored) {}
      hilog.error(0x0001, 'CloudSync', '[CloudStore] protected snapshot restore failed table=' +
        table + ' err=' + safeError(err));
      return false;
    } finally {
      this.localRestoreActive = false;
      this.setAutomaticPushSuppressed(false);
    }
  }

  private async cleanCloudDeletedRows(table: string): Promise<boolean> {
    if (!this.store) { return false; }
    try {
      await this.store.cleanDirtyData(table);
      hilog.info(0x0001, 'CloudSync', '[CloudStore] cleaned cloud-deleted rows table=' + table);
      return true;
    } catch (err) {
      hilog.warn(0x0001, 'CloudSync', '[CloudStore] clean dirty data failed table=' + table +
        ' err=' + safeError(err));
      return false;
    }
  }

  private hasAnyBusinessRows(): boolean {
    if (!this.store) { return false; }
    const tables: string[] = ['usersettings', 'remotehosts', 'rdpcredentials', 'rustdeskrelays',
      'sshkeys', 'totpentries', VNC_CLOUD_TABLE];
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

  /**
   * Return true only for active VNC secrets that are still encrypted with the
   * context-bound v2 envelope. Explicitly confirmed plain-v1 secrets are
   * already compatible with the global disabled state and must not block it.
   * Scan every owner table without applying the VNC selection projection so a
   * deselected or locked device cannot strand a secret owned by another device.
   */
  hasEncryptedVncSecrets(): boolean {
    if (!this.store) { return false; }
    const tables: string[] = [VNC_LOCAL_TABLE, VNC_CLOUD_TABLE, LEGACY_VNC_CLOUD_TABLE];
    for (let i = 0; i < tables.length; i++) {
      const compatibilityTable: boolean = tables[i] === LEGACY_VNC_CLOUD_TABLE;
      try {
        const rows = this.store.querySync(new relationalStore.RdbPredicates(tables[i]));
        const deletedFlagIndex: number = rows.getColumnIndex(relationalStore.Field.DELETED_FLAG_FIELD);
        while (rows.goToNextRow()) {
          if (deletedFlagIndex >= 0 && rows.getLong(deletedFlagIndex) === 1) { continue; }
          const record: VncRecord = this.vncRecordFromResult(rows);
          if (vncRecordHasActiveEncryptedCiphertext(record)) {
            rows.close();
            return true;
          }
        }
        rows.close();
      } catch (err) {
        if (!compatibilityTable) {
          hilog.error(0x0001, 'CloudSync', '[CloudStore] VNC crypto guard read failed table=' + tables[i] +
            ' err=' + safeError(err));
          return true;
        }
        // The renamed legacy table is optional. It is not registered as a
        // distributed table and is absent on clean installations.
      }
    }
    return false;
  }

  exportLocalExtensionRows(): Array<Record<string, string>> {
    const result: Array<Record<string, string>> = [];
    if (!this.store) {
      throw new Error('portable backup store unavailable');
    }
    let rows: relationalStore.ResultSet | null = null;
    try {
      rows = this.store.querySync(
        new relationalStore.RdbPredicates('localextensions'));
      const columns: string[] = localBackupLocalExtensionColumns();
      while (rows.goToNextRow()) {
        const row: Record<string, string> = {};
        for (let i = 0; i < columns.length; i++) {
          const index: number = rows.getColumnIndex(columns[i]);
          if (index >= 0 && !rows.isColumnNull(index)) { row[columns[i]] = rows.getString(index); }
        }
        result.push(row);
      }
      result.sort((a: Record<string, string>, b: Record<string, string>): number =>
        (a['id'] || '').localeCompare(b['id'] || ''));
    } catch (err) {
      throw new Error(
        'portable backup local extension export failed — ' +
        safeError(err));
    } finally {
      if (rows !== null) { rows.close(); }
    }
    return result;
  }

  exportAllLocalTableRows(): Record<string, Array<Record<string, string>>> {
    const snapshot: Record<string, Array<Record<string, string>>> = {};
    const names: string[] = localBackupLocalTableNames();
    for (let i = 0; i < names.length; i++) {
      snapshot[names[i]] = this.exportDeviceLocalRows(names[i], localBackupLocalTableColumns(names[i]));
    }
    return snapshot;
  }

  /**
   * Capture one account-scoped, transaction-consistent portable snapshot.
   * Any section failure aborts the artifact; an empty fallback is forbidden.
   */
  createPortableBackupSnapshot(): PortableBackupSnapshot {
    if (!this.store || this.currentLease === null ||
      this.currentScopeToken.kind !== 'huawei_account' ||
      this.currentOwnerScopeId() === '') {
      throw new Error('portable backup requires a bound account store');
    }
    try {
      this.store.beginTransaction();
      const snapshot: PortableBackupSnapshot = {
        accountScope: this.currentOwnerScopeId(),
        rdbSchemaVersion: this.store.version,
        sourceCryptoConfigured: this.getCryptoStatus() === 'active',
        tables: this.exportAllTableRows(),
        extensions: this.exportLocalExtensionRows(),
        localTables: this.exportAllLocalTableRows()
      };
      this.store.commit();
      return snapshot;
    } catch (err) {
      try { this.store.rollBack(); } catch (_rollbackError) {}
      throw new Error(
        'portable backup snapshot failed — ' + safeError(err));
    }
  }

  private portableOwnerTable(table: string): boolean {
    return [
      'usersettings', 'remotehosts', 'rdpcredentials',
      'rustdeskrelays', 'sshkeys', 'totpentries',
      VNC_CLOUD_TABLE, VNC_LOCAL_TABLE
    ].indexOf(table) >= 0;
  }

  private portableRowExists(
    table: string, id: string
  ): boolean {
    if (!this.store) { return false; }
    const predicates = new relationalStore.RdbPredicates(table);
    predicates.equalTo('id', id);
    if (this.portableOwnerTable(table)) {
      this.addCurrentOwnerPredicate(predicates);
    }
    const rows: relationalStore.ResultSet =
      this.store.querySync(predicates);
    try {
      return rows.goToFirstRow();
    } finally {
      rows.close();
    }
  }

  private mergePortableRows(
    table: string, rows: Array<Record<string, string>>
  ): number {
    if (!this.store) {
      throw new Error('portable restore store unavailable');
    }
    const allowed: string[] = table === VNC_LOCAL_TABLE
      ? localBackupLocalTableColumns(table)
      : localBackupColumnsForTable(table);
    let changed: number = 0;
    for (let i = 0; i < rows.length; i++) {
      const source: Record<string, string> = rows[i];
      const id: string = source['id'] || '';
      if (id === '') {
        throw new Error('portable restore row identity missing: ' + table);
      }
      if (this.portableOwnerTable(table) &&
        source['userid'] !== this.currentOwnerScopeId()) {
        throw new Error('portable restore owner mismatch: ' + table);
      }
      const bucket: relationalStore.ValuesBucket = {};
      const keys: string[] = Object.keys(source);
      for (let k = 0; k < keys.length; k++) {
        if (allowed.indexOf(keys[k]) < 0) {
          throw new Error(
            'portable restore unknown column: ' + table + '/' +
            keys[k]);
        }
        bucket[keys[k]] = source[keys[k]];
      }
      if (table === VNC_CLOUD_TABLE || table === VNC_LOCAL_TABLE) {
        bucket['resetepoch'] = this.readVncResetEpoch();
        const validationRow: Record<string, string> = {};
        for (let k = 0; k < keys.length; k++) {
          validationRow[keys[k]] = source[keys[k]];
        }
        validationRow['resetepoch'] =
          this.readVncResetEpoch().toString();
        if (!vncRecordIsValid(vncRecordFromCloudRow(validationRow))) {
          throw new Error('portable restore invalid VNC row: ' + id);
        }
      }
      const exists: boolean = this.portableRowExists(table, id);
      if (exists) {
        const predicates = new relationalStore.RdbPredicates(table);
        predicates.equalTo('id', id);
        if (this.portableOwnerTable(table)) {
          this.addCurrentOwnerPredicate(predicates);
        }
        if (!rdbSingleRowAffected(
          this.store.updateSync(bucket, predicates))) {
          throw new Error(
            'portable restore update failed: ' + table + '/' + id);
        }
      } else if (!rdbInsertSucceeded(
        this.store.insertSync(
          table, bucket,
          relationalStore.ConflictResolution.ON_CONFLICT_ABORT))) {
        throw new Error(
          'portable restore insert failed: ' + table + '/' + id);
      }
      changed++;
    }
    return changed;
  }

  private portableExtensionOwnerExists(
    table: string, recordId: string
  ): boolean {
    if (!this.store) { return false; }
    const ownerTable: string =
      table === RDP_RESTRICTED_ADMIN_SECRET_TABLE
        ? 'remotehosts' : table;
    if ([
      'remotehosts', 'rdpcredentials', 'sshkeys'
    ].indexOf(ownerTable) < 0) {
      return false;
    }
    const predicates =
      new relationalStore.RdbPredicates(ownerTable);
    predicates.equalTo('id', recordId);
    this.addCurrentOwnerPredicate(predicates);
    const rows: relationalStore.ResultSet =
      this.store.querySync(predicates);
    try {
      return rows.goToFirstRow();
    } finally {
      rows.close();
    }
  }

  private mergePortableExtensions(
    rows: Array<Record<string, string>>
  ): number {
    if (!this.store) {
      throw new Error('portable extension restore store unavailable');
    }
    const allowed: string[] = localBackupLocalExtensionColumns();
    let changed: number = 0;
    for (let i = 0; i < rows.length; i++) {
      const source: Record<string, string> = rows[i];
      const id: string = source['id'] || '';
      const table: string = source['tablename'] || '';
      const recordId: string = source['recordid'] || '';
      if (id !== table + ':' + recordId ||
        table === RDP_RESTRICTED_ADMIN_SECRET_TABLE ||
        !this.portableExtensionOwnerExists(table, recordId)) {
        throw new Error(
          'portable extension owner invalid: ' + id);
      }
      const incoming: Record<string, string> =
        JSON.parse(source['payload'] || '{}') as
          Record<string, string>;
      const predicates =
        new relationalStore.RdbPredicates('localextensions');
      predicates.equalTo('id', id);
      const existingRows: relationalStore.ResultSet =
        this.store.querySync(predicates);
      let exists: boolean = false;
      let merged: Record<string, string> = {};
      try {
        exists = existingRows.goToFirstRow();
        if (exists) {
          merged = JSON.parse(existingRows.getString(
            existingRows.getColumnIndex('payload'))) as
            Record<string, string>;
        }
      } finally {
        existingRows.close();
      }
      const incomingKeys: string[] = Object.keys(incoming);
      for (let k = 0; k < incomingKeys.length; k++) {
        merged[incomingKeys[k]] = incoming[incomingKeys[k]];
      }
      const bucket: relationalStore.ValuesBucket = {};
      const keys: string[] = Object.keys(source);
      for (let k = 0; k < keys.length; k++) {
        if (allowed.indexOf(keys[k]) < 0) {
          throw new Error(
            'portable extension unknown column: ' + keys[k]);
        }
        bucket[keys[k]] = source[keys[k]];
      }
      bucket['payload'] = JSON.stringify(merged);
      if (exists) {
        if (!rdbSingleRowAffected(
          this.store.updateSync(bucket, predicates))) {
          throw new Error(
            'portable extension update failed: ' + id);
        }
      } else if (!rdbInsertSucceeded(
        this.store.insertSync(
          'localextensions', bucket,
          relationalStore.ConflictResolution.ON_CONFLICT_ABORT))) {
        throw new Error(
          'portable extension insert failed: ' + id);
      }
      changed++;
    }
    return changed;
  }

  /**
   * Apply a validated portable plan as a field-level merge. Missing sections
   * and missing columns are no-ops, so an old/redacted backup cannot clear a
   * newer table or overwrite an existing password with NULL.
   */
  async mergePortableBackup(
    plan: PortableBackupRestorePlan
  ): Promise<boolean> {
    if (!this.store ||
      plan.restoreMode !== 'merge' ||
      plan.targetAccountScope !== this.currentOwnerScopeId() ||
      plan.presentTables.indexOf('cryptoparams') >= 0) {
      return false;
    }
    this.setAutomaticPushSuppressed(true);
    this.localRestoreActive = true;
    try {
      this.store.beginTransaction();
      let changed: number = 0;
      for (let i = 0; i < plan.presentTables.length; i++) {
        const table: string = plan.presentTables[i];
        if (TABLES.indexOf(table) < 0 ||
          table === 'cryptoparams') {
          throw new Error(
            'portable restore table is not mergeable: ' + table);
        }
        const rows: Array<Record<string, string>> =
          plan.tables[table] || [];
        if (rows.length === 0) { continue; }
        changed += this.mergePortableRows(table, rows);
        if (!this.recordTableMutation(
          table, 'portable_restore_merge')) {
          throw new Error(
            'portable restore journal failed: ' + table);
        }
        if (!this.writeLocalMetadata(
          RESTORED_NOT_UPLOADED_TABLE_PREFIX + table, '1')) {
          throw new Error(
            'portable restore table quarantine failed: ' + table);
        }
      }
      if (plan.extensionsPresent) {
        const extensionChanged: number =
          this.mergePortableExtensions(plan.extensions);
        changed += extensionChanged;
        if (extensionChanged > 0) {
          const extensionTables: string[] = [];
          for (let i = 0; i < plan.extensions.length; i++) {
            const table: string =
              plan.extensions[i]['tablename'] || '';
            if (TABLES.indexOf(table) >= 0 &&
              extensionTables.indexOf(table) < 0) {
              extensionTables.push(table);
            }
          }
          for (let i = 0; i < extensionTables.length; i++) {
            if (!this.recordTableMutation(
              extensionTables[i],
              'portable_restore_extension_merge') ||
              !this.writeLocalMetadata(
                RESTORED_NOT_UPLOADED_TABLE_PREFIX +
                extensionTables[i], '1')) {
              throw new Error(
                'portable extension quarantine failed: ' +
                extensionTables[i]);
            }
          }
        }
      }
      for (let i = 0;
        i < plan.presentLocalTables.length; i++) {
        const table: string = plan.presentLocalTables[i];
        if (localBackupLocalTableNames().indexOf(table) < 0) {
          throw new Error(
            'portable local table is not mergeable: ' + table);
        }
        const localChanged: number = this.mergePortableRows(
          table, plan.localTables[table] || []);
        changed += localChanged;
        if (localChanged > 0 && table === VNC_LOCAL_TABLE) {
          if (!this.recordTableMutation(
            VNC_CLOUD_TABLE,
            'portable_restore_local_vnc_merge') ||
            !this.writeLocalMetadata(
              RESTORED_NOT_UPLOADED_TABLE_PREFIX +
              VNC_CLOUD_TABLE, '1')) {
            throw new Error(
              'portable local VNC quarantine failed');
          }
        }
      }
      if (changed > 0 && !this.writeLocalMetadata(
        RESTORED_NOT_UPLOADED_KEY, '1')) {
        throw new Error(
          'portable restore quarantine marker failed');
      }
      this.store.commit();
      this.notifyDataSnapshotChanged();
      hilog.info(0x0001, 'CloudSync',
        'portable backup merged rows=' + changed.toString() +
        ' quarantined=' + plan.quarantinedRows.toString());
      return true;
    } catch (err) {
      let rollbackFailed: boolean = false;
      try {
        this.store.rollBack();
      } catch (_rollbackError) {
        rollbackFailed = true;
      }
      hilog.error(0x0001, 'CloudSync',
        'portable backup merge failed rollbackFailed=' +
        rollbackFailed.toString() + ' err=' + safeError(err));
      if (rollbackFailed) {
        // The RDB state is indeterminate. Throwing preserves the
        // coordinator's already-persisted restore quarantine; returning false
        // would incorrectly release it as if rollback had completed.
        throw new Error(
          'portable backup rollback failed; restore quarantine retained');
      }
      return false;
    } finally {
      this.localRestoreActive = false;
      this.setAutomaticPushSuppressed(false);
    }
  }

  /**
   * Local backup restore.  A successful restore is intentionally quarantined:
   * it cannot pull or upload automatically until the user explicitly chooses a
   * cloud direction, so a valid backup can never be overwritten on startup.
   */
  async replaceAllTableRows(snapshot: Record<string, Array<Record<string, string>>>,
    extensions: Array<Record<string, string>> = [],
    localTables?: Record<string, Array<Record<string, string>>>): Promise<boolean> {
    return await this.replaceAllTableRowsInternal(snapshot, extensions, null, null,
      localTables, true, true);
  }

  /** Manual cloud-download rollback restores every local state owner exactly. */
  private async restoreManualDownloadSnapshot(snapshot: Record<string, Array<Record<string, string>>>,
    extensions: Array<Record<string, string>>, metadata: Array<Record<string, string>>,
    journal: Array<Record<string, string>>,
    localTables: Record<string, Array<Record<string, string>>>): Promise<boolean> {
    return await this.replaceAllTableRowsInternal(snapshot, extensions, metadata, journal,
      localTables, false, false);
  }

  private async replaceAllTableRowsInternal(snapshot: Record<string, Array<Record<string, string>>>,
    extensions: Array<Record<string, string>>, metadata: Array<Record<string, string>> | null,
    journal: Array<Record<string, string>> | null,
    localTables: Record<string, Array<Record<string, string>>> | undefined,
    markRestoredNotUploaded: boolean,
    publishReload: boolean): Promise<boolean> {
    if (!this.store || !validateLocalBackupSnapshot(snapshot, extensions, localTables)) { return false; }
    if (metadata !== null && !this.deviceLocalRowsValid(metadata, LOCAL_METADATA_COLUMNS, 'key')) { return false; }
    if (journal !== null && !this.deviceLocalRowsValid(journal, LOCAL_MUTATION_JOURNAL_COLUMNS, 'id')) {
      return false;
    }
    // A local backup may predate a crypto reset. Preserve the current VNC
    // generation across restore so an old backup cannot make stale VNC rows
    // readable again.
    const protectedVncResetEpoch: number = this.readVncResetEpoch();
    this.setAutomaticPushSuppressed(true);
    this.localRestoreActive = true;
    try {
      this.store.beginTransaction();
      // A portable backup intentionally does not grant token handoff on this
      // device. Manual cloud-download rollback passes its metadata snapshot.
      if (metadata === null && !this.clearRustDeskRelayControlPlaneProfiles()) {
        throw new Error('clear device-local relay control-plane profiles failed');
      }
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
      const localTableNames: string[] = localBackupLocalTableNames();
      for (let i = 0; i < localTableNames.length; i++) {
        const localTable: string = localTableNames[i];
        const localRows: Array<Record<string, string>> = localTables === undefined
          ? [] : (localTables[localTable] || []);
        if (!(await this.restoreDeviceLocalRows(localTable, localBackupLocalTableColumns(localTable), localRows))) {
          throw new Error('restore local table failed table=' + localTable);
        }
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
      if (!this.ensureVncResetEpochAtLeast(protectedVncResetEpoch)) {
        throw new Error('preserve VNC reset epoch failed');
      }
      if (markRestoredNotUploaded && !this.writeLocalMetadata(RESTORED_NOT_UPLOADED_KEY, '1')) {
        throw new Error('set restored upload marker failed');
      }
      const bootstrapMetadata:
        CloudMetadataReadResult =
        this.readLocalMetadataState(
          CLOUD_BOOTSTRAP_COMPLETED_KEY);
      if (!cloudMetadataBoundaryReadable(
        bootstrapMetadata)) {
        throw new Error(
          'restored bootstrap metadata query failed');
      }
      const restoredBootstrapCompleted:
        boolean =
        bootstrapMetadata.state === 'present' &&
        bootstrapMetadata.value === '1';
      this.store.commit();
      this.cloudBootstrapCompleted =
        restoredBootstrapCompleted;
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

  private markCloudSyncIndeterminate(
    operationId: number,
    capturedStore: relationalStore.RdbStore,
    capturedLease: AccountSessionLease,
    table: string,
    direction: CloudSyncDirection,
    label: string
  ): boolean {
    if (this.store !== capturedStore || !this.isLeaseCurrent(capturedLease)) {
      return false;
    }
    if (this.indeterminateCloudSyncOperation !== null) {
      return this.indeterminateCloudSyncOperation.operationId === operationId &&
        this.indeterminateCloudSyncOperation.storeInstanceId ===
          capturedLease.storeInstanceId &&
        accountSessionLeaseEquals(
          this.indeterminateCloudSyncOperation.lease, capturedLease);
    }
    this.indeterminateCloudSyncOperation = {
      operationId,
      storeInstanceId: capturedLease.storeInstanceId,
      table,
      direction,
      label,
      lease: cloneAccountSessionLease(capturedLease),
      terminalObserved: false,
      terminalSucceeded: false
    };
    this.cloudDownloadActive = this.cloudDownloadActive ||
      direction === 'cloudFirst';
    return true;
  }

  private indeterminateCloudSyncMatches(
    operationId: number,
    capturedStore: relationalStore.RdbStore,
    capturedLease: AccountSessionLease
  ): boolean {
    const pending: IndeterminateCloudSyncOperation | null =
      this.indeterminateCloudSyncOperation;
    if (pending === null) { return false; }
    const expected: CloudSyncCallbackIdentity = {
      operationId: pending.operationId,
      storeInstanceId: pending.storeInstanceId,
      generation: pending.lease.generation
    };
    const candidate: CloudSyncCallbackIdentity = {
      operationId,
      storeInstanceId: capturedLease.storeInstanceId,
      generation: capturedLease.generation
    };
    return cloudSyncCallbackIdentityMatches(expected, candidate) &&
      this.store === capturedStore &&
      this.isLeaseCurrent(capturedLease) &&
      accountSessionLeaseEquals(pending.lease, capturedLease);
  }

  private settleLateCloudSyncTerminal(
    operationId: number,
    capturedStore: relationalStore.RdbStore,
    capturedLease: AccountSessionLease,
    terminalSucceeded: boolean
  ): void {
    if (!this.indeterminateCloudSyncMatches(
      operationId, capturedStore, capturedLease)) {
      return;
    }
    const pending: IndeterminateCloudSyncOperation | null =
      this.indeterminateCloudSyncOperation;
    if (pending === null) { return; }
    pending.terminalObserved = true;
    pending.terminalSucceeded = terminalSucceeded;
    setTimeout((): void => {
      this.trySettlePendingIndeterminate();
    }, 0);
  }

  private trySettlePendingIndeterminate(): void {
    const pending: IndeterminateCloudSyncOperation | null =
      this.indeterminateCloudSyncOperation;
    if (pending === null || !pending.terminalObserved ||
      !this.isLeaseCurrent(pending.lease)) {
      return;
    }
    const coordinator: CloudSyncCoordinator =
      CloudSyncCoordinator.getInstance();
    if (!coordinator.recoverIndeterminateTransfer(pending.lease)) {
      return;
    }
    this.indeterminateCloudSyncOperation = null;
    this.cloudDownloadActive = false;
    hilog.warn(0x0001, 'CloudSync',
      '已接收匹配的迟到终态并解除物理库隔离 operation=' +
      pending.operationId.toString() + ' table=' + pending.table +
      ' terminalSuccess=' + pending.terminalSucceeded.toString());
    if (pending.direction === 'cloudFirst' || pending.terminalSucceeded) {
      setTimeout((): void => {
        if (!this.isLeaseCurrent(pending.lease)) { return; }
        coordinator.requestCloudEventPull()
          .then((result: CloudSyncOperationResult): void => {
            if (!this.isLeaseCurrent(pending.lease)) { return; }
            if (!result.ok) {
              hilog.warn(0x0001, 'CloudSync',
                '迟到终态后的权威重核对未完成 failure=' +
                result.failureKind);
            }
          }, (): void => {
            hilog.warn(0x0001, 'CloudSync',
              '迟到终态后的权威重核对 Promise 被拒绝');
          });
      }, 0);
    }
  }

  private notifyCloudDataApplied(tables: string[]): void {
    this.suppressCryptoStateSnapshot = true;
    let resetClearPending: boolean = false;
    try {
      if (tables.indexOf('cryptoparams') >= 0) {
        const migratedRelays: number = this.migrateLegacyRelayJson();
        if (migratedRelays < 0) {
          this.lastError =
            'legacy relay JSON failed validation and was quarantined';
        }
      }
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
      const storedSshColor: Object = prefs.getSync(SSH_TERMINAL_FOREGROUND_COLOR_KEY, '') as Object;
      const storedLegacySshColor: Object = prefs.getSync(SSH_LEGACY_FOREGROUND_COLOR_KEY, '') as Object;
      const storedSshFontSize: Object = prefs.getSync(SSH_TERMINAL_FONT_SIZE_KEY, 0) as Object;
      const storedLegacySshFontSize: Object = prefs.getSync(SSH_LEGACY_FONT_SIZE_KEY, 0) as Object;
      const currentSshAppearance: SshTerminalAppearance = resolveSshTerminalAppearance(
        typeof storedSshColor === 'string' ? storedSshColor as string : '',
        typeof storedLegacySshColor === 'string' ? storedLegacySshColor as string : '',
        typeof storedSshFontSize === 'number' ? storedSshFontSize as number : 0,
        typeof storedLegacySshFontSize === 'number' ? storedLegacySshFontSize as number : 0
      );
      const hasSshSettings: boolean = hasSshTerminalAppearanceCloudSettings(settings);
      const nextSshAppearance: SshTerminalAppearance = hasSshSettings
        ? resolveSshTerminalAppearanceFromCloudSettings(settings, currentSshAppearance)
        : currentSshAppearance;
      for (let i = 0; i < keys.length; i++) {
        const key: string = keys[i];
        if (!cloudUserSettingIsSyncable(key)) { continue; }
        if (isSshTerminalAppearanceKey(key)) { continue; }
        if (key === 'virtualMouseStyle' && !applyVirtualMouseStyle) { continue; }
        prefs.putSync(key, settings[key]);
        AppStorage.setOrCreate(key, settings[key]);
      }
      if (hasSshSettings) {
        prefs.putSync(SSH_TERMINAL_FOREGROUND_COLOR_KEY, nextSshAppearance.foregroundColor);
        prefs.putSync(SSH_TERMINAL_FONT_SIZE_KEY, nextSshAppearance.fontSize);
        prefs.putSync(SSH_LEGACY_FOREGROUND_COLOR_KEY, nextSshAppearance.foregroundColor);
        prefs.putSync(SSH_LEGACY_FONT_SIZE_KEY, nextSshAppearance.fontSize);
        prefs.putSync(SSH_SETTINGS_SCHEMA_VERSION_KEY, SSH_SETTINGS_SCHEMA_VERSION);
        AppStorage.setOrCreate(SSH_TERMINAL_FOREGROUND_COLOR_KEY, nextSshAppearance.foregroundColor);
        AppStorage.setOrCreate(SSH_TERMINAL_FONT_SIZE_KEY, nextSshAppearance.fontSize);
        AppStorage.setOrCreate(SSH_LEGACY_FOREGROUND_COLOR_KEY, nextSshAppearance.foregroundColor);
        AppStorage.setOrCreate(SSH_LEGACY_FONT_SIZE_KEY, nextSshAppearance.fontSize);
      }
      prefs.flushSync();
    } catch (err) {
      hilog.warn(0x0001, 'CloudSync', '[CloudStore] apply cloud settings failed: ' + safeError(err));
    }
  }

  private vncCloudRowsAreUploadSafe(): boolean {
    if (!this.store) { return false; }
    try {
      const predicates =
        new relationalStore.RdbPredicates(VNC_CLOUD_TABLE);
      this.addCurrentOwnerPredicate(predicates);
      const rows: relationalStore.ResultSet =
        this.store.querySync(predicates);
      const deletedIndex: number = rows.getColumnIndex(
        relationalStore.Field.DELETED_FLAG_FIELD);
      const currentEpoch: number = this.readVncResetEpoch();
      while (rows.goToNextRow()) {
        if (deletedIndex >= 0 && rows.getLong(deletedIndex) === 1) {
          continue;
        }
        const record: VncRecord = this.vncRecordFromResult(rows);
        if (!vncRecordIsValid(record) ||
          record.resetEpoch !== currentEpoch ||
          (record.recordType === 'secret' &&
            record.deletedAt <= 0 &&
            !vncRecordHasActiveEncryptedCiphertext(record))) {
          rows.close();
          return false;
        }
      }
      rows.close();
      return true;
    } catch (err) {
      hilog.error(0x0001, 'CloudSync',
        'VNC native-first safety scan failed: ' + safeError(err));
      return false;
    }
  }

  private nativeFirstTableIsSafe(table: string): boolean {
    if (!this.store) { return false; }
    if (table === VNC_CLOUD_TABLE) {
      return this.vncCloudRowsAreUploadSafe();
    }
    try {
      const crypto: DataCrypto = DataCrypto.getInstance();
      return cloudTableRowsAreUploadSafe(
        table,
        this.exportTableRows(table),
        crypto.isSetupComplete(),
        (value: string): boolean => crypto.isEncrypted(value));
    } catch (err) {
      hilog.error(0x0001, 'CloudSync',
        'native-first safety scan failed table=' + table +
        ' err=' + safeError(err));
      return false;
    }
  }

  private downloadedTableIsCompatible(table: string): boolean {
    if (table === VNC_CLOUD_TABLE) {
      // VNC owns its record/envelope validator. A cloud physical row must not
      // bypass that validator merely because its logical scope is hidden.
      return this.vncCloudRowsAreUploadSafe();
    }
    try {
      const crypto: DataCrypto = DataCrypto.getInstance();
      return cloudTableRowsAreDownloadCompatible(
        table,
        this.exportTableRows(table),
        crypto.isSetupComplete(),
        (value: string): boolean => crypto.isEncrypted(value));
    } catch (err) {
      hilog.error(0x0001, 'CloudSync',
        'cloud-first safety scan failed table=' + table +
        ' err=' + safeError(err));
      return false;
    }
  }

  private syncTableAsync(table: string, direction: CloudSyncDirection, label: string): Promise<boolean> {
    return new Promise<boolean>((resolve) => {
      if (!this.store || !this.cloudAvailable || this.currentLease === null) {
        this.lastSyncFailureKind = 'cloud_service';
        resolve(false);
        return;
      }
      if (cloudSyncBlockedByLocalRestore(
        this.localRestoreActive,
        this.localRestorePending)) {
        this.lastSyncFailureKind = 'restore_pending';
        this.lastError = label + ' ' + table +
          ': blocked by exclusive local restore';
        resolve(false);
        return;
      }
      if (direction === 'nativeFirst' &&
        !this.nativeFirstTableIsSafe(table)) {
        this.lastSyncFailureKind = 'unsafe_payload';
        this.lastError = label + ' ' + table +
          ': UNSAFE_CLOUD_PAYLOAD native-first blocked';
        if (this.tableStatus[table]) {
          this.tableStatus[table].fail++;
        }
        hilog.error(0x0001, 'CloudSync', this.lastError);
        resolve(false);
        return;
      }
      if (this.indeterminateCloudSyncOperation !== null) {
        this.lastSyncFailureKind = 'indeterminate';
        this.lastError = label + ' ' + table +
          ': blocked by indeterminate operation=' +
          this.indeterminateCloudSyncOperation.operationId.toString();
        resolve(false);
        return;
      }
      const capturedStore: relationalStore.RdbStore = this.store;
      const capturedLease: AccountSessionLease =
        cloneAccountSessionLease(this.currentLease);
      const operationId: number = ++this.cloudSyncOperationSequence;
      const operationIsCurrent = (): boolean =>
        this.store === capturedStore && this.isLeaseCurrent(capturedLease);
      const mode: relationalStore.SyncMode = direction === 'cloudFirst'
        ? relationalStore.SyncMode.SYNC_MODE_CLOUD_FIRST
        : relationalStore.SyncMode.SYNC_MODE_NATIVE_FIRST;
      this.lastSyncFailureKind = 'none';
      // Every automatic cloud-first read is an authoritative snapshot. A new
      // device must not publish its startup defaults merely because the first
      // cloud callback happens to report an empty table. Explicit manual
      // download is the only operation allowed to intentionally replace local
      // rows with an empty cloud snapshot.
      const protectsEmptySnapshot: boolean = direction === 'cloudFirst' &&
        (label === 'startup' || label === 'foreground' || label === 'cloudEvent');
      const beforeVisibleRows: number = protectsEmptySnapshot ? this.countVisibleTableRows(table) : 0;
      const protectedRows: Array<Record<string, string>> = protectsEmptySnapshot
        ? this.exportTableRows(table) : [];
      if (protectsEmptySnapshot && beforeVisibleRows > 0 && protectedRows.length === 0) {
        this.lastSyncFailureKind = 'empty_snapshot';
        this.lastError = label + ' ' + table + ': EMPTY_CLOUD_SNAPSHOT safety snapshot unavailable';
        resolve(false);
        return;
      }
      let settled: boolean = false;
      let conflictRecoveryStarted: boolean = false;
      let watchdogTimer: number = -1;
      const watchdogStartedAt: number = Date.now();
      const watchdogState: CloudSyncWatchdogState = {
        startedAt: watchdogStartedAt,
        lastSignalAt: watchdogStartedAt,
        signalObserved: false,
        settled: false
      };
      const clearWatchdog = (): void => {
        if (watchdogTimer >= 0) {
          clearTimeout(watchdogTimer);
          watchdogTimer = -1;
        }
      };
      const finishFailure = (message: string, kind: CloudSyncFailureKind): void => {
        if (settled) { return; }
        settled = true;
        watchdogState.settled = true;
        clearWatchdog();
        if (!operationIsCurrent()) {
          resolve(false);
          return;
        }
        this.lastSyncTime = Date.now();
        this.syncFailCount++;
        this.lastSyncFailureKind = kind;
        this.lastError = label + ' ' + table + ': ' + message;
        if (this.tableStatus[table]) { this.tableStatus[table].fail++; }
        hilog.error(0x0001, 'CloudSync', this.lastError);
        resolve(false);
      };
      const recordFailure = (message: string, forcedKind?: CloudSyncFailureKind): void => {
        if (settled) { return; }
        const kind: CloudSyncFailureKind = forcedKind || classifyCloudSyncFailure(message);
        if (kind === 'version_conflict' && !conflictRecoveryStarted) {
          conflictRecoveryStarted = true;
          this.cleanCloudDeletedRows(table).then((cleaned: boolean): void => {
            finishFailure(message + ' tombstoneCleanup=' + cleaned.toString(), kind);
          }, (): void => {
            finishFailure(message + ' tombstoneCleanup=false', kind);
          });
          return;
        }
        finishFailure(message, kind);
      };
      const recordSuccess = (): void => {
        if (settled) { return; }
        settled = true;
        watchdogState.settled = true;
        clearWatchdog();
        if (!operationIsCurrent()) {
          resolve(false);
          return;
        }
        this.lastSyncTime = Date.now();
        this.syncSuccessCount++;
        this.lastSyncFailureKind = 'none';
        this.cloudServiceGuidanceNeeded = false;
        if (this.tableStatus[table]) {
          this.tableStatus[table].ok++;
          this.tableStatus[table].last = Date.now();
        }
        hilog.info(0x0001, 'CloudSync', label + ' transfer complete table=' + table);
        resolve(true);
      };
      const armWatchdog = (): void => {
        clearWatchdog();
        if (settled) { return; }
        const delay: number =
          cloudSyncWatchdogNextDelayMs(watchdogState, Date.now());
        if (delay < 0) { return; }
        watchdogTimer = setTimeout((): void => {
          watchdogTimer = -1;
          if (settled) { return; }
          const timeoutKind: CloudSyncWatchdogTimeoutKind =
            cloudSyncWatchdogTimeoutKind(watchdogState, Date.now());
          if (timeoutKind === 'none') {
            armWatchdog();
            return;
          }
          if (!this.markCloudSyncIndeterminate(
            operationId, capturedStore, capturedLease,
            table, direction, label)) {
            finishFailure('WATCHDOG_' + timeoutKind.toUpperCase() +
              ' stale operation', 'unknown');
            return;
          }
          finishFailure(
            'WATCHDOG_' + timeoutKind.toUpperCase() +
            ' acceptMs=' + CLOUD_SYNC_ACCEPT_TIMEOUT_MS.toString() +
            ' idleMs=' + CLOUD_SYNC_IDLE_TIMEOUT_MS.toString() +
            ' overallMs=' + CLOUD_SYNC_OVERALL_TIMEOUT_MS.toString(),
            'indeterminate');
        }, delay) as number;
      };
      const signalWatchdog = (): void => {
        if (settled) { return; }
        watchdogState.signalObserved = true;
        watchdogState.lastSignalAt = Date.now();
        armWatchdog();
      };
      const finishCloudFirstSuccess = (): void => {
        if (!operationIsCurrent()) {
          finishFailure('stale account lease', 'unknown');
          return;
        }
        const afterVisibleRows: number = this.countVisibleTableRows(table);
        // API 23 gives no separate "empty snapshot" token. The strongest
        // available proof is the conjunction of an independently verified
        // platform account binding, successful distributed-table
        // registration (permission/schema), a current lease, and the exact
        // target table's terminal successful progress record. This callback
        // is reached only after those terminal progress checks passed.
        const authoritativeEmptyProof: boolean =
          this.cloudAvailable &&
          cloudAccountBindingIsValid(
            this.cloudAccountBinding) &&
          operationIsCurrent();
        if (shouldRejectAutomaticEmptyCloudSnapshot(label, direction,
          beforeVisibleRows, afterVisibleRows,
          authoritativeEmptyProof)) {
          this.restoreProtectedTableRows(table, protectedRows).then((restored: boolean): void => {
            recordFailure('EMPTY_CLOUD_SNAPSHOT before=' + beforeVisibleRows.toString() +
              ' after=' + afterVisibleRows.toString() + ' restored=' + restored.toString(), 'empty_snapshot');
          }, (): void => {
            recordFailure('EMPTY_CLOUD_SNAPSHOT before=' + beforeVisibleRows.toString() +
              ' after=' + afterVisibleRows.toString() + ' restored=false', 'empty_snapshot');
          });
          return;
        }
        if (table === 'cryptoparams') {
          try {
            const migrated: number =
              this.migrateCryptoParamIdentity();
            if (migrated > 0) {
              CloudSyncCoordinator.getInstance()
                .requestAutomaticPush('cryptoparams')
                .then((_result: CloudSyncOperationResult): void => {},
                  (): void => {});
            }
          } catch (err) {
            const message: string =
              'UNSAFE_CLOUD_PAYLOAD cryptoparams identity=' +
              safeError(err);
            if (!protectsEmptySnapshot) {
              recordFailure(message, 'unsafe_payload');
              return;
            }
            this.restoreProtectedTableRows(
              table, protectedRows).then((restored: boolean): void => {
                recordFailure(
                  message + ' restored=' + restored.toString(),
                  'unsafe_payload');
              }, (): void => {
                recordFailure(
                  message + ' restored=false',
                  'unsafe_payload');
              });
            return;
          }
        }
        if (!this.downloadedTableIsCompatible(table)) {
          const message: string =
            'UNSAFE_CLOUD_PAYLOAD incompatible table=' + table;
          if (!protectsEmptySnapshot) {
            recordFailure(message, 'unsafe_payload');
            return;
          }
          this.restoreProtectedTableRows(
            table, protectedRows).then((restored: boolean): void => {
              recordFailure(
                message + ' restored=' + restored.toString(),
                'unsafe_payload');
            }, (): void => {
              recordFailure(
                message + ' restored=false',
                'unsafe_payload');
            });
          return;
        }
        if (table === 'remotehosts') {
          const trustCleanup: number =
            this.stripRemoteHostDeviceTrustAfterCloudPull();
          if (trustCleanup < 0) {
            recordFailure(
              'DEVICE_TRUST_SANITIZE failed',
              'unknown');
            return;
          }
          if (trustCleanup > 0) {
            // The cloud-first row may have been written by an old client.
            // Queue one native-first scrub after this serialized pull; never
            // adopt its trust decision into the current device overlay.
            CloudSyncCoordinator.getInstance()
              .requestAutomaticPush('remotehosts')
              .then((_result: CloudSyncOperationResult): void => {},
                (): void => {});
          }
        }
        const dirtyRows: number = this.countCloudDeletedRows(table);
        if (dirtyRows > 0) {
          this.cleanCloudDeletedRows(table).then((cleaned: boolean): void => {
            if (!cleaned) {
              recordFailure('TOMBSTONE_CLEANUP dirtyRows=' + dirtyRows.toString(), 'tombstone_cleanup');
              return;
            }
            recordSuccess();
          }, (): void => {
            recordFailure('TOMBSTONE_CLEANUP dirtyRows=' + dirtyRows.toString(), 'tombstone_cleanup');
          });
          return;
        }
        recordSuccess();
      };
      armWatchdog();
      try {
        capturedStore.cloudSync(mode, [table],
          (progress: relationalStore.ProgressDetails): void => {
            if (settled) {
              if (progress) {
                const lateSchedule: number = progress.schedule as number;
                const lateCode: number = progress.code as number;
                if (cloudSyncProgressFinished(lateSchedule)) {
                  const lateSucceeded: boolean =
                    cloudSyncProgressSucceeded(lateSchedule, lateCode) &&
                    cloudSyncTargetTableCompleted(progress.details, table);
                  this.settleLateCloudSyncTerminal(
                    operationId, capturedStore, capturedLease, lateSucceeded);
                }
              }
              return;
            }
            if (!operationIsCurrent()) {
              finishFailure('stale account lease', 'unknown');
              return;
            }
            if (!progress) {
              this.markCloudSyncIndeterminate(
                operationId, capturedStore, capturedLease,
                table, direction, label);
              finishFailure('progress details missing', 'indeterminate');
              return;
            }
            const schedule: number = progress.schedule as number;
            const code: number = progress.code as number;
            signalWatchdog();
            hilog.info(0x0001, 'CloudSync', label + ' progress table=' + table +
              ' schedule=' + schedule.toString() + ' code=' + code.toString());
            if (!cloudSyncProgressFinished(schedule)) { return; }
            clearWatchdog();
            if (cloudSyncProgressSucceeded(schedule, code)) {
              if (!cloudSyncTargetTableCompleted(progress.details, table)) {
                recordFailure('target table progress statistics incomplete', 'unknown');
                return;
              }
              if (direction === 'cloudFirst') { finishCloudFirstSuccess(); }
              else { recordSuccess(); }
            } else {
              recordFailure('progressCode=' + code.toString(),
                classifyCloudSyncProgressCode(code));
            }
          },
          (err: BusinessError | undefined): void => {
            if (settled) {
              if (err) {
                this.settleLateCloudSyncTerminal(
                  operationId, capturedStore, capturedLease, false);
              }
              return;
            }
            if (!operationIsCurrent()) {
              finishFailure('stale account lease', 'unknown');
              return;
            }
            if (err) {
              clearWatchdog();
              this.cloudServiceGuidanceNeeded = this.cloudServiceGuidanceNeeded || this.errorRequiresCloudServiceGuidance(err);
              recordFailure('code=' + err.code.toString() + ' msg=' + err.message);
              return;
            }
            // On this device the completion callback confirms that the task was
            // accepted, while Progress.SYNC_FINISH arrives after the real transfer.
            signalWatchdog();
            hilog.info(0x0001, 'CloudSync', label + ' accepted table=' + table);
          }
        );
      } catch (err) {
        clearWatchdog();
        recordFailure('exception=' + safeError(err));
      }
    });
  }

  private tableColumns(table: string): string[] {
    if (!this.store) { throw new Error('RDB store unavailable'); }
    const rows: relationalStore.ResultSet =
      this.store.querySqlSync('PRAGMA table_info(' + table + ')');
    const result: string[] = [];
    const nameIndex: number = rows.getColumnIndex('name');
    while (rows.goToNextRow()) {
      result.push(rows.getString(nameIndex));
    }
    rows.close();
    return result;
  }

  private tableExists(table: string): boolean {
    if (!this.store) { throw new Error('RDB store unavailable'); }
    const rows: relationalStore.ResultSet = this.store.querySqlSync(
      "SELECT name FROM sqlite_master WHERE type='table' AND name='" + table + "'");
    const exists: boolean = rows.goToFirstRow();
    rows.close();
    return exists;
  }

  private async ensureColumn(table: string, columnDefinition: string): Promise<void> {
    if (!this.store) { throw new Error('RDB store unavailable'); }
    const separator: number = columnDefinition.indexOf(' ');
    const column: string = separator < 0
      ? columnDefinition : columnDefinition.substring(0, separator);
    if (column.length === 0) { throw new Error('empty schema column'); }
    this.schemaStep = 'ensureColumn:PRAGMA:' + table;
    const columns: string[] = this.tableColumns(table);
    if (columns.indexOf(column) >= 0) { return; }
    this.schemaStep = 'ensureColumn:ALTER:' + table + '.' + column;
    await this.store.executeSql(
      'ALTER TABLE ' + table + ' ADD COLUMN ' + columnDefinition);
  }

  /** Atomic schema migration. RdbStore.version is the only schema truth. */
  private async createTables(): Promise<void> {
    if (!this.store) { return; }
    const currentVersion: number = this.store.version;
    if (currentVersion > ACCOUNT_STORE_SCHEMA_VERSION) {
      throw new Error('database schema is newer than this app: ' +
        currentVersion.toString());
    }
    // 平台约束（已真机验证）: OpenHarmony RDB 服务在 beginTransaction() 内执行
    // DDL (CREATE/ALTER) 不会物化表, 后续 ALTER 报 14800021 "no such table"。
    // 因此 schema 迁移不包手动事务; 所有 DDL 均幂等 (IF NOT EXISTS + 列检测),
    // 中途失败重跑可自愈, 不再依赖事务回滚保证原子性。
    try {
    this.schemaStep = 'create:remotehosts';
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
    await this.ensureColumn('remotehosts', 'sshkeypassphrase TEXT');
    await this.ensureColumn('remotehosts', 'sshkeyid TEXT');
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
      await this.ensureColumn('remotehosts', colDef);
    }
    this.schemaStep = 'create:rdpcredentials';
    await this.store.executeSql(`
      CREATE TABLE IF NOT EXISTS rdpcredentials (
        id TEXT PRIMARY KEY,
        userid TEXT,
        label TEXT,
        username TEXT,
        password TEXT,
        createdat INTEGER,
        updatedat INTEGER
      )
    `);
    await this.ensureColumn('rdpcredentials', 'userid TEXT');
    this.schemaStep = 'create:sshkeys';
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
    await this.ensureColumn('sshkeys', 'formatversion INTEGER');
    await this.ensureColumn('sshkeys', 'privatekeyencrypted INTEGER');
    this.schemaStep = 'create:totpentries';
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
    this.schemaStep = 'create:cryptoparams';
    await this.store.executeSql(`
      CREATE TABLE IF NOT EXISTS cryptoparams (
        id TEXT PRIMARY KEY,
        key TEXT,
        value TEXT
      )
    `);
    this.schemaStep = 'create:usersettings';
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
    await this.ensureColumn('remotehosts', 'passward TEXT');
    await this.ensureColumn('usersettings', 'payload TEXT');
    await this.ensureColumn('usersettings', 'schemaversion INTEGER');
    // RustDesk 中继服务器配置表 (本地缓存, 云同步通过 cryptoparams)
    this.schemaStep = 'create:rustdeskrelays';
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
    // VNC owns exactly one cloud table. Logical settings, hosts, gateways,
    // secrets and trust rows are separated by recordtype; no existing protocol
    // table is extended with VNC-specific fields.
    this.schemaStep = 'create:vncrecord';
    await this.store.executeSql(`
      CREATE TABLE IF NOT EXISTS vncrecord (
        id TEXT PRIMARY KEY,
        userid TEXT,
        recordtype TEXT,
        ownerid TEXT,
        ownertype TEXT,
        secretkind TEXT,
        payload TEXT,
        ciphertext TEXT,
        envelopeversion INTEGER,
        cryptoversion INTEGER,
        keyversion INTEGER,
        aadversion INTEGER,
        payloadhashsha256 TEXT,
        syncversion INTEGER,
        schemaversion INTEGER,
        resetepoch INTEGER,
        createdat INTEGER,
        updatedat INTEGER,
        deletedat INTEGER
      )
    `);
    await this.ensureColumn('rustdeskrelays', 'accountsjson TEXT');
    await this.ensureColumn('rustdeskrelays', 'updatedat INTEGER');
    await this.ensureColumn('remotehosts', 'rustdeskrelayid TEXT');
    await this.ensureColumn('remotehosts', 'rustdeskaccountid TEXT');
    await this.ensureColumn('remotehosts', 'rustdeskpasswordmode INTEGER');
    // 迁移: RustDesk 直连字段 (2026-06-23 引入, 旧库/新库都必须与 hostToBucket 对齐)
    const rustDeskDirectCols: string[] = [
      'rustdeskdirectenabled INTEGER',
      'rustdeskdirecthost TEXT',
      'rustdeskdirectport INTEGER'
    ];
    for (const colDef of rustDeskDirectCols) {
      await this.ensureColumn('remotehosts', colDef);
    }
    await this.ensureColumn('remotehosts', 'rdpcredentialid TEXT');
    await this.ensureColumn('remotehosts', 'rustdeskauthmode TEXT');
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
      await this.ensureColumn('remotehosts', colDef);
    }
    // 本地扩展表不参与 setDistributedTables；它保存云表没有的字段。
    this.schemaStep = 'create:localextensions';
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
    this.schemaStep = 'create:localmetadata';
    await this.store.executeSql(`
      CREATE TABLE IF NOT EXISTS localmetadata (
        key TEXT PRIMARY KEY,
        value TEXT,
        updatedat INTEGER
      )
    `);
    this.schemaStep = 'create:localmutationjournal';
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
    this.schemaStep = 'create:migrationreceipts';
    await this.store.executeSql(`
      CREATE TABLE IF NOT EXISTS migrationreceipts (
        id TEXT PRIMARY KEY,
        migrationid TEXT,
        sourcestore TEXT,
        sourcefingerprint TEXT,
        targetowner TEXT,
        targetstore TEXT,
        status TEXT,
        countsjson TEXT,
        errordetail TEXT,
        startedat INTEGER,
        updatedat INTEGER,
        completedat INTEGER
      )
    `);
    this.schemaStep = 'create:migrationquarantine';
    await this.store.executeSql(`
      CREATE TABLE IF NOT EXISTS migrationquarantine (
        id TEXT PRIMARY KEY,
        migrationid TEXT,
        tablename TEXT,
        recordid TEXT,
        reason TEXT,
        payloadhashsha256 TEXT,
        payloadciphertext TEXT,
        redactedsummary TEXT,
        createdat INTEGER
      )
    `);
    // Device-local VNC rows never enter setDistributedTables. They are used
    // for non-syncable caches and local key/trust mirrors only.
    this.schemaStep = 'create:vnclocalrecords';
    await this.store.executeSql(`
      CREATE TABLE IF NOT EXISTS vnclocalrecords (
        id TEXT PRIMARY KEY,
        userid TEXT,
        recordtype TEXT,
        ownerid TEXT,
        ownertype TEXT,
        secretkind TEXT,
        payload TEXT,
        ciphertext TEXT,
        envelopeversion INTEGER,
        cryptoversion INTEGER,
        keyversion INTEGER,
        aadversion INTEGER,
        payloadhashsha256 TEXT,
        syncversion INTEGER,
        schemaversion INTEGER,
        resetepoch INTEGER,
        createdat INTEGER,
        updatedat INTEGER,
        deletedat INTEGER,
        localonly INTEGER
      )
    `);
    this.schemaStep = 'setVersion';
    this.store.version = ACCOUNT_STORE_SCHEMA_VERSION;
    } catch (err) {
      const detail: string = DataCrypto.errDetail(err);
      hilog.error(0x0001, 'CloudSync',
        'createTables failed at step[' + this.schemaStep + ']: ' + detail);
      throw new Error('schema migration failed at step[' + this.schemaStep + ']: ' + detail);
    }
  }

  /**
   * Preserve data from the pre-rename local RDB table without treating the old
   * name as a cloud contract. The replacement `vncrecord` table is deliberately
   * left untouched until the user explicitly edits or uploads the migrated
   * records; this prevents a fresh device from native-first publishing stale
   * legacy rows during bootstrap.
   */
  private async migrateLegacyVncRecords(): Promise<void> {
    if (!this.store || this.readLocalMetadataStrict(VNC_LEGACY_MIGRATION_KEY) === '1') { return; }
    if (!this.tableExists(LEGACY_VNC_CLOUD_TABLE)) {
      if (!this.writeLocalMetadata(VNC_LEGACY_MIGRATION_KEY, '1')) {
        throw new Error('legacy VNC absent-table marker write failed');
      }
      return;
    }
    let legacyRows: relationalStore.ResultSet | null = null;
    try {
      legacyRows = this.store.querySync(
        new relationalStore.RdbPredicates(LEGACY_VNC_CLOUD_TABLE));
      const localRows: VncRecord[] = this.loadVncRecordsFromTable(VNC_LOCAL_TABLE, true);
      const localByIdentity: Map<string, VncRecord> = new Map<string, VncRecord>();
      for (let i = 0; i < localRows.length; i++) {
        localByIdentity.set(vncRecordIdentity(localRows[i].userId, localRows[i].id), localRows[i]);
      }
      const candidates: VncRecord[] = [];
      const quarantined: LegacyVncQuarantineItem[] = [];
      const deletedFlagIndex: number = legacyRows.getColumnIndex(relationalStore.Field.DELETED_FLAG_FIELD);
      const currentResetEpoch: number = this.readVncResetEpoch();
      while (legacyRows.goToNextRow()) {
        if (deletedFlagIndex >= 0 && legacyRows.getLong(deletedFlagIndex) === 1) { continue; }
        const record: VncRecord = this.vncRecordFromResult(legacyRows);
        const decision: LegacyVncRowMigrationDecision =
          legacyVncRowMigrationDecision(
            record.userId,
            this.currentOwnerScopeId(),
            record.resetEpoch,
            currentResetEpoch,
            vncRecordIsValid(record));
        if (decision !== 'migrate') {
          quarantined.push({
            recordId: record.id,
            reason: decision,
            payloadHashSha256: vncPayloadHashSha256(record.payload)
          });
          continue;
        }
        const identity: string = vncRecordIdentity(record.userId, record.id);
        const local: VncRecord | undefined = localByIdentity.get(identity);
        if (local === undefined || vncRecordWins(record, local)) { candidates.push(record); }
      }
      legacyRows.close();
      legacyRows = null;
      this.store.beginTransaction();
      if (candidates.length > 0) {
        for (let i = 0; i < candidates.length; i++) {
          if (!this.upsertVncRecordInternal(candidates[i], true)) {
            throw new Error('legacy VNC local overlay insert failed id=' + candidates[i].id);
          }
        }
      }
      for (let i = 0; i < quarantined.length; i++) {
        if (!this.writeLegacyVncQuarantine(quarantined[i])) {
          throw new Error(
            'legacy VNC quarantine write failed id=' +
            quarantined[i].recordId);
        }
      }
      if (!this.writeLocalMetadata(VNC_LEGACY_MIGRATION_KEY, '1')) {
        throw new Error('legacy VNC migration marker write failed');
      }
      this.store.commit();
      hilog.info(0x0001, 'CloudSync',
        '[CloudStore] legacy VNC migration preserved=' +
        candidates.length.toString() + ' quarantined=' +
        quarantined.length.toString());
    } catch (err) {
      if (legacyRows !== null) {
        try { legacyRows.close(); } catch (_ignored) {}
      }
      try { this.store.rollBack(); } catch (_ignored) {}
      throw new Error('legacy VNC migration failed: ' + safeError(err));
    }
  }

  private writeLegacyVncQuarantine(
    item: LegacyVncQuarantineItem
  ): boolean {
    if (!this.store || item.reason === 'migrate') { return false; }
    const recordId: string =
      item.recordId.trim() === '' ? '__missing_id__' : item.recordId.trim();
    const bucket: relationalStore.ValuesBucket = {
      id: LEGACY_VNC_MIGRATION_ID + ':' +
        this.currentOwnerScopeId() + ':' + recordId + ':' + item.reason,
      migrationid: LEGACY_VNC_MIGRATION_ID,
      tablename: LEGACY_VNC_CLOUD_TABLE,
      recordid: recordId,
      reason: item.reason,
      payloadhashsha256: item.payloadHashSha256,
      payloadciphertext: '',
      redactedsummary:
        'Legacy VNC row remains in the source table and requires repair',
      createdat: Date.now()
    };
    return rdbInsertSucceeded(this.store.insertSync(
      MIGRATION_QUARANTINE_TABLE,
      bucket,
      relationalStore.ConflictResolution.ON_CONFLICT_REPLACE));
  }

  getRdbStore(): relationalStore.RdbStore | null {
    return this.store;
  }

  isReady(): boolean {
    return this.initialized &&
      (this.store !== null ||
        this.startupRecoveryVerificationIo !==
          null);
  }

  async syncAllToCloud(): Promise<boolean> {
    return await this.uploadAllToCloud();
  }

  isCloudAvailable(): boolean {
    return this.initialized && this.store !== null && this.cloudAvailable &&
      cloudTransferAllowed(this.cloudAccountBinding);
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
    if (this.cryptoLifecycleState === null ||
      !cryptoLifecycleSensitiveWriteAllowed(
        this.cryptoLifecycleState,
        crypto.isSetupComplete(),
        crypto.isReady())) {
      return this.setLastMutation(DataMutationResult.failure(
        recordId, 'crypto_lifecycle_blocked',
        '加密数据生命周期尚未就绪，请先解锁或完成恢复'));
    }
    if (!sensitiveWriteRequiresUnlock(crypto.isSetupComplete(), crypto.isReady())) { return true; }
    return this.setLastMutation(DataMutationResult.failure(recordId, 'unlock_required',
      '加密数据已锁定，请先解锁后再保存'));
  }

  readLocalMetadataState(
    key: string
  ): CloudMetadataReadResult {
    if (key === '') {
      return { state: 'error', value: '' };
    }
    const injected:
      CloudStoreMetadataQueryPort | null =
      this.wiringPorts !== null &&
      this.wiringPorts.metadataQuery !==
        undefined
        ? this.wiringPorts.metadataQuery
        : null;
    if (injected !== null) {
      return readCloudMetadataState(
        (): string | null =>
          injected.queryValue(key));
    }
    if (!this.store) {
      return { state: 'error', value: '' };
    }
    const store: relationalStore.RdbStore =
      this.store;
    return readCloudMetadataState(
      (): string | null => {
        let rows:
          relationalStore.ResultSet | null = null;
        try {
          const predicates =
            new relationalStore.RdbPredicates(
              LOCAL_METADATA_TABLE);
          predicates.equalTo('key', key);
          rows = store.querySync(predicates);
          if (!rows.goToFirstRow()) {
            return null;
          }
          return rows.getString(
            rows.getColumnIndex('value'));
        } finally {
          if (rows !== null) {
            rows.close();
          }
        }
      });
  }

  private readLocalMetadata(key: string): string {
    const result: CloudMetadataReadResult =
      this.readLocalMetadataState(key);
    return result.state === 'present'
      ? result.value : '';
  }

  private readLocalMetadataStrict(key: string): string {
    const result: CloudMetadataReadResult =
      this.readLocalMetadataState(key);
    if (!cloudMetadataBoundaryReadable(result)) {
      throw new Error(
        'metadata query failed key=' + key);
    }
    return result.state === 'present'
      ? result.value : '';
  }

  private localMetadataValueMatches(
    key: string,
    expected: string
  ): boolean {
    const result: CloudMetadataReadResult =
      this.readLocalMetadataState(key);
    return result.state === 'present' &&
      result.value === expected;
  }

  private verifyStoreIdentity(): void {
    if (!this.store || this.currentLease === null) {
      throw new Error('store identity verification unavailable');
    }
    const expectedOwner: string = this.currentLease.ownerScopeId;
    const expectedStore: string = this.currentLease.storeIdentity;
    const expectedPlatformIdentity: string =
      this.currentScopeToken.platformIdentityFingerprint;
    const storedOwner: string = this.readLocalMetadataStrict(STORE_OWNER_SCOPE_KEY);
    const storedStore: string = this.readLocalMetadataStrict(STORE_IDENTITY_KEY);
    const storedPlatformIdentity: string =
      this.readLocalMetadataStrict(STORE_PLATFORM_IDENTITY_KEY);
    // 平台分布式身份仅在“可独立证明”时参与校验 (指纹为 64 位十六进制)。
    // 若当前设备/系统无法提供可信证明 (validating), 账号本地作用域仍可打开,
    // 云端传输保持 fail-closed (cloudDistributedRegistrationAllowed=false),
    // 与 verifyAccountScopeCloudBinding 的 validating 语义一致。
    const platformIdentityCheckable: boolean =
      expectedPlatformIdentity.length === 64;
    if ((storedOwner !== '' && storedOwner !== expectedOwner) ||
      (storedStore !== '' && storedStore !== expectedStore) ||
      (this.currentScopeToken.kind === 'huawei_account' &&
        platformIdentityCheckable &&
        storedPlatformIdentity !== '' &&
        storedPlatformIdentity !== expectedPlatformIdentity)) {
      throw new Error('physical database owner identity mismatch');
    }
    this.store.beginTransaction();
    try {
      if (!this.writeLocalMetadata(STORE_OWNER_SCOPE_KEY, expectedOwner) ||
        !this.writeLocalMetadata(STORE_IDENTITY_KEY, expectedStore) ||
        !this.writeLocalMetadata(STORE_SCHEMA_REVISION_KEY,
          this.store.version.toString()) ||
        (this.currentScopeToken.kind === 'huawei_account' &&
          !this.writeLocalMetadata(
            STORE_PLATFORM_IDENTITY_KEY,
            expectedPlatformIdentity))) {
        throw new Error('store identity metadata write failed');
      }
      this.store.commit();
    } catch (err) {
      try { this.store.rollBack(); } catch (_rollbackError) {}
      throw new Error('store identity verification failed: ' + safeError(err));
    }
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

  /**
   * cryptoparams is an existing three-column cloud contract. Account identity
   * is therefore encoded into its primary key instead of relying on an
   * unavailable userid column. The logical key remains stable for old clients,
   * while every read in this build requires the scoped primary key as well.
   */
  private cryptoParamId(key: string): string {
    const owner: string = this.currentOwnerScopeId();
    if (owner === '' || key.trim() === '') { return ''; }
    return 'crypto-param|' + owner + '|' + key.trim();
  }

  private cryptoParamBucket(
    key: string, value: string
  ): relationalStore.ValuesBucket {
    const id: string = this.cryptoParamId(key);
    if (id === '') { throw new Error('crypto parameter identity unavailable'); }
    return { id, key: key.trim(), value };
  }

  /**
   * Re-key legacy rows only after the physical store owner has been verified.
   * Conflicting or foreign scoped rows block the store instead of guessing
   * which account owns portable encryption material.
   */
  private migrateCryptoParamIdentity(): number {
    if (!this.store) { throw new Error('crypto parameter store unavailable'); }
    const rows: relationalStore.ResultSet = this.store.querySync(
      new relationalStore.RdbPredicates('cryptoparams'));
    const ids: string[] = [];
    const keys: string[] = [];
    const values: string[] = [];
    try {
      while (rows.goToNextRow()) {
        ids.push(rows.getString(rows.getColumnIndex('id')));
        keys.push(rows.getString(rows.getColumnIndex('key')));
        values.push(rows.getString(rows.getColumnIndex('value')));
      }
    } finally {
      rows.close();
    }
    let changed: number = 0;
    this.store.beginTransaction();
    try {
      for (let i = 0; i < ids.length; i++) {
        const expectedId: string = this.cryptoParamId(keys[i]);
        if (expectedId === '' || ids[i] === '') {
          throw new Error('malformed cryptoparams identity');
        }
        if (ids[i] === expectedId) { continue; }
        if (ids[i].indexOf('crypto-param|') === 0) {
          throw new Error('foreign cryptoparams owner identity');
        }
        const existingPredicates =
          new relationalStore.RdbPredicates('cryptoparams');
        existingPredicates.equalTo('id', expectedId);
        const existing: relationalStore.ResultSet =
          this.store.querySync(existingPredicates);
        const found: boolean = existing.goToFirstRow();
        const existingValue: string = found
          ? existing.getString(existing.getColumnIndex('value')) : '';
        const existingKey: string = found
          ? existing.getString(existing.getColumnIndex('key')) : '';
        existing.close();
        if (found &&
          (existingKey !== keys[i] || existingValue !== values[i])) {
          throw new Error('conflicting legacy cryptoparams row: ' + keys[i]);
        }
        if (!found && !rdbInsertSucceeded(this.store.insertSync(
          'cryptoparams',
          this.cryptoParamBucket(keys[i], values[i]),
          relationalStore.ConflictResolution.ON_CONFLICT_ABORT))) {
          throw new Error('legacy cryptoparams re-key failed: ' + keys[i]);
        }
        const oldPredicates =
          new relationalStore.RdbPredicates('cryptoparams');
        oldPredicates.equalTo('id', ids[i]);
        if (!rdbSingleRowAffected(
          this.store.deleteSync(oldPredicates))) {
          throw new Error('legacy cryptoparams cleanup failed: ' + ids[i]);
        }
        changed++;
      }
      if (changed > 0 &&
        !this.recordTableMutation(
          'cryptoparams', 'scope_identity_migrate')) {
        throw new Error('cryptoparams identity journal failed');
      }
      this.store.commit();
    } catch (err) {
      try { this.store.rollBack(); } catch (_rollbackError) {}
      throw new Error(
        'cryptoparams account migration failed: ' + safeError(err));
    }
    return changed;
  }

  private readRustDeskRelayControlPlaneProfile(relayId: string) {
    const key: string = rustDeskControlPlaneProfileMetadataKey(relayId);
    return normalizeRustDeskControlPlaneProfile(key === '' ? undefined : this.readLocalMetadata(key));
  }

  private writeRustDeskRelayControlPlaneProfile(relay: RustDeskRelayConfig): boolean {
    const key: string = rustDeskControlPlaneProfileMetadataKey(relay.id);
    return key !== '' && this.writeLocalMetadata(key,
      normalizeRustDeskControlPlaneProfile(relay.controlPlaneProfile));
  }

  private deleteRustDeskRelayControlPlaneProfile(relayId: string): boolean {
    const key: string = rustDeskControlPlaneProfileMetadataKey(relayId);
    return key === '' || this.deleteLocalMetadata(key);
  }

  private clearRustDeskRelayControlPlaneProfiles(): boolean {
    if (!this.store) { return false; }
    try {
      const rows = this.store.querySync(new relationalStore.RdbPredicates(LOCAL_METADATA_TABLE));
      const keys: string[] = [];
      const keyColumn: number = rows.getColumnIndex('key');
      while (rows.goToNextRow()) {
        const key: string = rows.getString(keyColumn);
        if (key.indexOf(RUSTDESK_CONTROL_PLANE_PROFILE_METADATA_PREFIX) === 0) { keys.push(key); }
      }
      rows.close();
      for (let i = 0; i < keys.length; i++) {
        const predicates = new relationalStore.RdbPredicates(LOCAL_METADATA_TABLE);
        predicates.equalTo('key', keys[i]);
        this.store.deleteSync(predicates);
      }
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
    if (!this.store) {
      throw new Error('local state export store unavailable');
    }
    let rows: relationalStore.ResultSet | null = null;
    try {
      rows = this.store.querySync(
        new relationalStore.RdbPredicates(table));
      while (rows.goToNextRow()) {
        const row: Record<string, string> = {};
        for (let i = 0; i < columns.length; i++) {
          const index: number = rows.getColumnIndex(columns[i]);
          if (index >= 0) { row[columns[i]] = rows.getString(index); }
        }
        result.push(row);
      }
      result.sort((left: Record<string, string>, right: Record<string, string>): number =>
        (left['id'] || left['key'] || '').localeCompare(right['id'] || right['key'] || ''));
    } catch (err) {
      throw new Error(
        'local state export failed table=' + table +
        ' — ' + safeError(err));
    } finally {
      if (rows !== null) { rows.close(); }
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

  private mutationJournalRevisionsFromRows(
    rows: Array<Record<string, string>>
  ): Record<string, number> {
    const result: Record<string, number> = {};
    for (let i = 0; i < rows.length; i++) {
      const table: string = rows[i]['tablename'] || '';
      const revision: number = Number(rows[i]['revision'] || '0');
      if (table !== '' && Number.isFinite(revision) &&
        revision > (result[table] || 0)) {
        result[table] = Math.floor(revision);
      }
    }
    return result;
  }

  private acknowledgeMutationJournalSnapshot(
    tables: string[],
    beforeRows: Array<Record<string, string>>
  ): boolean {
    const covered: Record<string, number> =
      this.mutationJournalRevisionsFromRows(beforeRows);
    for (let i = 0; i < tables.length; i++) {
      const revision: number = covered[tables[i]] || 0;
      if (revision > 0 &&
        !this.acknowledgeMutationJournal(
          tables[i], revision)) {
        return false;
      }
    }
    return true;
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
    const metadata: CloudMetadataReadResult =
      this.readLocalMetadataState(
        RESTORED_NOT_UPLOADED_KEY);
    return metadata.state === 'error' ||
      (metadata.state === 'present' &&
        metadata.value === '1');
  }

  clearRestoredNotUploaded(): boolean {
    if (!this.deleteLocalMetadata(RESTORED_NOT_UPLOADED_KEY)) {
      return false;
    }
    for (let i = 0; i < TABLES.length; i++) {
      if (!this.deleteLocalMetadata(
        RESTORED_NOT_UPLOADED_TABLE_PREFIX + TABLES[i])) {
        return false;
      }
    }
    return true;
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
    result.stage = this.lastMutationResult.stage;
    result.localCommitted = this.lastMutationResult.localCommitted;
    return result;
  }

  private rdpRestrictedAdminSecretBinding(host: RemoteHost): string {
    const authIdentityMode: number = AppStorage.get<number>('rdpAuthIdentityMode') ?? 1;
    const identity = normalizeRdpCredentialParts(host.username, authIdentityMode);
    return [
      'rdp-binding-v2',
      host.host.trim().toLowerCase(),
      host.port.toString(),
      host.customHostname.trim().toLowerCase(),
      identity.username.trim().toLowerCase(),
      identity.domain.trim().toLowerCase(),
      authIdentityMode.toString(),
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
        'hash': crypto.encryptScoped(
          this.currentOwnerScopeId(), RDP_RESTRICTED_ADMIN_SECRET_TABLE,
          host.id, 'hash', hash, this.readVncResetEpoch()),
        'binding': crypto.encryptScoped(
          this.currentOwnerScopeId(), RDP_RESTRICTED_ADMIN_SECRET_TABLE,
          host.id, 'binding',
          this.rdpRestrictedAdminSecretBinding(host),
          this.readVncResetEpoch())
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
    const crypto: DataCrypto = DataCrypto.getInstance();
    if (!crypto.isReady()) {
      result.status = 'crypto_locked';
      return result;
    }
    const values: Record<string, string> = this.loadLocalExtension(RDP_RESTRICTED_ADMIN_SECRET_TABLE, host.id);
    const encryptedHash: string = values['hash'] || '';
    const encryptedBinding: string = values['binding'] || '';
    if (encryptedHash === '' || encryptedBinding === '') {
      // A partially written local extension must not remain around and be
      // retried on every connection attempt.  Treat it as invalid and fail
      // closed; the next explicit edit can write a complete secret again.
      this.clearRdpRestrictedAdminHash(host.id);
      result.status = 'invalid';
      return result;
    }
    if (!crypto.isEncrypted(encryptedHash) || !crypto.isEncrypted(encryptedBinding)) {
      this.clearRdpRestrictedAdminHash(host.id);
      result.status = 'invalid';
      return result;
    }
    try {
      const binding: string = crypto.decryptScopedOrLegacy(
        this.currentOwnerScopeId(), RDP_RESTRICTED_ADMIN_SECRET_TABLE,
        host.id, 'binding', encryptedBinding,
        this.readVncResetEpoch());
      const hash: string = normalizeRdpNtlmHash(
        crypto.decryptScopedOrLegacy(
          this.currentOwnerScopeId(), RDP_RESTRICTED_ADMIN_SECRET_TABLE,
          host.id, 'hash', encryptedHash,
          this.readVncResetEpoch()));
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
      this.clearRdpRestrictedAdminHash(host.id);
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
      'rustdeskpromanaged', 'rustdeskprolastseenat', 'rustdeskprosyncerror',
      'rustdesktargetdevice', 'rustdeskadaptiveorientation'
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
    host.sshKeyPassphrase = this.decryptIfReady(
      crypto, 'localextensions/remotehosts', host.id,
      'sshkeypassphrase', get('sshkeypassphrase', host.sshKeyPassphrase));
    host.sshHostKeyAlgorithm =
      get('sshhostkeyalgorithm', host.sshHostKeyAlgorithm);
    host.sshHostKeyFingerprintSha256 =
      get('sshhostkeyfingerprintsha256',
        host.sshHostKeyFingerprintSha256);
    host.sshHostKeyRawBase64 =
      get('sshhostkeyrawbase64', host.sshHostKeyRawBase64);
    host.sshHostKeyTrustedAt = Number(
      get('sshhostkeytrustedat',
        host.sshHostKeyTrustedAt.toString()));
    host.sshHostKeyTrustMode = Number(
      get('sshhostkeytrustmode',
        host.sshHostKeyTrustMode.toString()));
    host.rdpCertificateFingerprintSha256 =
      get('rdpcertificatefingerprintsha256',
        host.rdpCertificateFingerprintSha256);
    host.rdpCertificateSubject =
      get('rdpcertificatesubject',
        host.rdpCertificateSubject);
    host.rdpCertificateIssuer =
      get('rdpcertificateissuer',
        host.rdpCertificateIssuer);
    host.rdpCertificateCommonName =
      get('rdpcertificatecommonname',
        host.rdpCertificateCommonName);
    host.rdpCertificateTrustedAt = Number(
      get('rdpcertificatetrustedat',
        host.rdpCertificateTrustedAt.toString()));
    host.rdpCertificateTrustMode = Number(
      get('rdpcertificatetrustmode',
        host.rdpCertificateTrustMode.toString()));
    host.rdpCertificateAllowUntrustedRoot =
      get('rdpcertificateallowuntrustedroot',
        host.rdpCertificateAllowUntrustedRoot ? '1' : '0') === '1';
    host.rdpCertificateAllowHostMismatch =
      get('rdpcertificateallowhostmismatch',
        host.rdpCertificateAllowHostMismatch ? '1' : '0') === '1';
    return host;
  }

  /** Apply only the portable extension decoded from the cloud row. Never persist from a decoder. */
  private applyCloudHostExtension(host: RemoteHost, values: Record<string, string>): RemoteHost {
    const get = (key: string, fallback: string): string => values[key] !== undefined ? values[key] : fallback;
    host.sshKeyId = get('sshkeyid', host.sshKeyId);
    const sshProxyType: string = get('sshproxytype', host.sshProxyType);
    if (sshProxyType === 'http_connect' || sshProxyType === 'socks5' ||
      sshProxyType === 'legacy_gateway' || sshProxyType === 'direct') {
      host.sshProxyType = sshProxyType;
    }
    host.rustdeskRelayId = get('rustdeskrelayid', host.rustdeskRelayId);
    host.rustdeskAccountId = get('rustdeskaccountid', host.rustdeskAccountId);
    host.rustdeskDirectHost = get('rustdeskdirecthost', host.rustdeskDirectHost);
    host.rustdeskTargetDevice = get('rustdesktargetdevice', host.rustdeskTargetDevice) === 'phone' ?
      'phone' : 'computer';
    host.rustdeskAdaptiveOrientation = get('rustdeskadaptiveorientation',
      host.rustdeskAdaptiveOrientation ? '1' : '0') === '1';
    host.rdpCredentialId = get('rdpcredentialid', host.rdpCredentialId);
    host.rdpAuthMode = normalizeRdpAuthMode(get('rdpauthmode', host.rdpAuthMode));
    host.rdpRestrictedAdminSecretSource = normalizeRdpRestrictedAdminSecretSource(
      get('rdprestrictedadminsecretsource', host.rdpRestrictedAdminSecretSource));
    host.rustdeskPasswordMode = Number(get('rustdeskpasswordmode', host.rustdeskPasswordMode.toString()));
    host.rustdeskAuthMode = get('rustdeskauthmode', host.rustdeskAuthMode) === 'request_approval' ? 'request_approval' : 'password';
    host.rustdeskDirectEnabled = get('rustdeskdirectenabled', host.rustdeskDirectEnabled ? '1' : '0') === '1';
    host.rustdeskDirectPort = Number(get('rustdeskdirectport', host.rustdeskDirectPort.toString()));
    host.rustdeskTotpEntryId = get('rustdesktotpentryid', host.rustdeskTotpEntryId);
    host.rustdeskTotpAutoSubmit = get('rustdesktotpautosubmit', host.rustdeskTotpAutoSubmit ? '1' : '0') === '1';
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
    values['sshkeypassphrase'] = this.encryptIfReady(
      crypto, 'localextensions/remotehosts', host.id,
      'sshkeypassphrase', host.sshKeyPassphrase);
    values['sshhostkeyalgorithm'] =
      host.sshHostKeyAlgorithm;
    values['sshhostkeyfingerprintsha256'] =
      host.sshHostKeyFingerprintSha256;
    values['sshhostkeyrawbase64'] =
      host.sshHostKeyRawBase64;
    values['sshhostkeytrustedat'] =
      host.sshHostKeyTrustedAt.toString();
    values['sshhostkeytrustmode'] =
      host.sshHostKeyTrustMode.toString();
    values['rdpcertificatefingerprintsha256'] =
      host.rdpCertificateFingerprintSha256;
    values['rdpcertificatesubject'] =
      host.rdpCertificateSubject;
    values['rdpcertificateissuer'] =
      host.rdpCertificateIssuer;
    values['rdpcertificatecommonname'] =
      host.rdpCertificateCommonName;
    values['rdpcertificatetrustedat'] =
      host.rdpCertificateTrustedAt.toString();
    values['rdpcertificatetrustmode'] =
      host.rdpCertificateTrustMode.toString();
    values['rdpcertificateallowuntrustedroot'] =
      host.rdpCertificateAllowUntrustedRoot ? '1' : '0';
    values['rdpcertificateallowhostmismatch'] =
      host.rdpCertificateAllowHostMismatch ? '1' : '0';
    return values;
  }

  /** Values that travel in displayconfig's backward-compatible cloud extension. */
  private hostCloudExtensionValues(host: RemoteHost): Record<string, string> {
    const values: Record<string, string> = {};
    host.normalizeRdpAuthentication();
    values['sshkeyid'] = host.sshKeyId;
    values['sshproxytype'] = host.sshProxyType;
    values['rustdeskrelayid'] = host.rustdeskRelayId;
    values['rustdeskaccountid'] = host.rustdeskAccountId;
    values['rustdeskpasswordmode'] = host.rustdeskPasswordMode.toString();
    values['rustdeskauthmode'] = host.rustdeskAuthMode;
    values['rustdeskdirectenabled'] = host.rustdeskDirectEnabled ? '1' : '0';
    values['rustdeskdirecthost'] = host.rustdeskDirectHost;
    values['rustdeskdirectport'] = host.rustdeskDirectPort.toString();
    values['rustdesktargetdevice'] = host.rustdeskTargetDevice;
    values['rustdeskadaptiveorientation'] = host.rustdeskAdaptiveOrientation ? '1' : '0';
    values['rustdesktotpentryid'] = host.rustdeskTotpEntryId;
    values['rustdesktotpautosubmit'] = host.rustdeskTotpAutoSubmit ? '1' : '0';
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
    if (this.readLocalMetadataStrict(CANONICAL_SECRET_STORAGE_VERSION_KEY) ===
      CANONICAL_SECRET_STORAGE_VERSION) { return; }
    try {
      this.store.beginTransaction();
      const hostPredicates = new relationalStore.RdbPredicates('remotehosts');
      this.addCurrentOwnerPredicate(hostPredicates);
      const rows = this.store.querySync(hostPredicates);
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
          this.addCurrentOwnerPredicate(predicates);
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
      // RDP username is now part of the authoritative cloud contract. Migrate
      // the historical local extension exactly once, then remove the shadow so
      // a stale local value can never override a newer cloud row.
      const rdpPredicates = new relationalStore.RdbPredicates('rdpcredentials');
      this.addCurrentOwnerPredicate(rdpPredicates);
      const rdpRows: relationalStore.ResultSet = this.store.querySync(rdpPredicates);
      const rdpIdIndex: number = rdpRows.getColumnIndex('id');
      const rdpUsernameIndex: number = rdpRows.getColumnIndex('username');
      while (rdpRows.goToNextRow()) {
        const id: string = rdpIdIndex >= 0 ? rdpRows.getString(rdpIdIndex) : '';
        if (id.length === 0) { continue; }
        const extension: Record<string, string> =
          this.loadLocalExtension('rdpcredentials', id);
        const currentUsername: string = rdpUsernameIndex >= 0
          ? rdpRows.getString(rdpUsernameIndex) : '';
        const legacyUsername: string = extension['username'] || '';
        if (currentUsername.length === 0 && legacyUsername.length > 0) {
          const usernameBucket: relationalStore.ValuesBucket = {
            username: legacyUsername,
            updatedat: Date.now()
          };
          const updatePredicates =
            new relationalStore.RdbPredicates('rdpcredentials');
          updatePredicates.equalTo('id', id);
          this.addCurrentOwnerPredicate(updatePredicates);
          if (!rdbSingleRowAffected(
            this.store.updateSync(usernameBucket, updatePredicates))) {
            throw new Error('canonical RDP username migration failed id=' + id);
          }
        }
        if (!this.deleteLocalExtension('rdpcredentials', id)) {
          throw new Error('RDP username extension cleanup failed id=' + id);
        }
      }
      rdpRows.close();
      if (!this.writeLocalMetadata(CANONICAL_SECRET_STORAGE_VERSION_KEY, CANONICAL_SECRET_STORAGE_VERSION)) {
        throw new Error('canonical password migration marker failed');
      }
      this.store.commit();
    } catch (err) {
      try { this.store.rollBack(); } catch (_ignored) {}
      throw new Error('local extension migration failed: ' + safeError(err));
    }
  }

  /**
   * One-time upgrade bridge. Existing installs previously stored SSH host-key
   * and RDP certificate trust inside the distributed host row. Capture the
   * current device's last local decision, then remove every cloud-visible and
   * duplicate physical-column copy in one transaction.
   */
  private async migrateDeviceLocalHostTrust(): Promise<void> {
    if (!this.store) { return; }
    if (this.readLocalMetadataStrict(
      DEVICE_LOCAL_HOST_TRUST_MIGRATION_KEY) === '1') {
      return;
    }
    try {
      this.store.beginTransaction();
      const predicates =
        new relationalStore.RdbPredicates('remotehosts');
      this.addCurrentOwnerPredicate(predicates);
      const rows: relationalStore.ResultSet =
        this.store.querySync(predicates);
      const idIndex: number = rows.getColumnIndex('id');
      const displayIndex: number =
        rows.getColumnIndex('displayconfig');
      const deletedIndex: number = rows.getColumnIndex(
        relationalStore.Field.DELETED_FLAG_FIELD);
      let changedRows: number = 0;
      while (rows.goToNextRow()) {
        if (deletedIndex >= 0 &&
          rows.getLong(deletedIndex) === 1) {
          continue;
        }
        const id: string = idIndex >= 0
          ? rows.getString(idIndex) : '';
        if (id === '') { continue; }
        const rawDisplay: string = displayIndex >= 0
          ? rows.getString(displayIndex) : '{}';
        const local: Record<string, string> =
          this.loadLocalExtension('remotehosts', id);
        const physical: Record<string, string> =
          projectRemoteHostDeviceTrust(
            this.hostExtensionFromResult(rows));
        const historical: Record<string, string> =
          extractLegacyRemoteHostDeviceTrust(rawDisplay);
        const trust: Record<string, string> =
          mergeRemoteHostDeviceTrust(
            physical, historical, local);
        const nextLocal: Record<string, string> = {};
        if (local['sshkeypassphrase'] !== undefined) {
          nextLocal['sshkeypassphrase'] =
            local['sshkeypassphrase'];
        }
        if (remoteHostDeviceTrustIsMeaningful(trust)) {
          const trustKeys: string[] = Object.keys(trust);
          for (let i = 0; i < trustKeys.length; i++) {
            nextLocal[trustKeys[i]] =
              trust[trustKeys[i]];
          }
        }
        const localSaved: boolean =
          Object.keys(nextLocal).length > 0
            ? this.saveLocalExtension(
              'remotehosts', id, nextLocal)
            : this.deleteLocalExtension(
              'remotehosts', id);
        if (!localSaved) {
          throw new Error(
            'device trust overlay migration failed id=' + id);
        }

        const displayPayload: RemoteHostDisplayPayload =
          decodeRemoteHostDisplayPayload(rawDisplay);
        const sanitizedDisplay: string =
          encodeRemoteHostDisplayPayload(
            displayPayload.displayConfigJson,
            displayPayload.extension);
        const needsDisplayCleanup: boolean =
          Object.keys(historical).length > 0 &&
          sanitizedDisplay !== rawDisplay;
        const needsPhysicalCleanup: boolean =
          remoteHostDeviceTrustIsMeaningful(physical);
        if (!needsDisplayCleanup &&
          !needsPhysicalCleanup) {
          continue;
        }
        const bucket: relationalStore.ValuesBucket =
          this.clearedRemoteHostDeviceTrustBucket();
        if (needsDisplayCleanup) {
          bucket['displayconfig'] = sanitizedDisplay;
          bucket['updatedat'] = Date.now();
        }
        const updatePredicates =
          new relationalStore.RdbPredicates('remotehosts');
        updatePredicates.equalTo('id', id);
        this.addCurrentOwnerPredicate(updatePredicates);
        if (!rdbSingleRowAffected(
          this.store.updateSync(bucket, updatePredicates))) {
          throw new Error(
            'device trust row cleanup failed id=' + id);
        }
        changedRows++;
      }
      rows.close();
      if (changedRows > 0 &&
        !this.recordTableMutation(
          'remotehosts', 'device_trust_migration')) {
        throw new Error(
          'device trust scrub journal failed');
      }
      if (!this.writeLocalMetadata(
        DEVICE_LOCAL_HOST_TRUST_MIGRATION_KEY, '1')) {
        throw new Error(
          'device trust migration marker failed');
      }
      this.store.commit();
    } catch (err) {
      try { this.store.rollBack(); } catch (_ignored) {}
      throw new Error(
        'device-local host trust migration failed: ' +
        safeError(err));
    }
  }

  private clearedRemoteHostDeviceTrustBucket():
    relationalStore.ValuesBucket {
    return {
      sshhostkeyalgorithm: '',
      sshhostkeyfingerprintsha256: '',
      sshhostkeyrawbase64: '',
      sshhostkeytrustedat: 0,
      sshhostkeytrustmode: 0,
      rdpcertificatefingerprintsha256: '',
      rdpcertificatesubject: '',
      rdpcertificateissuer: '',
      rdpcertificatecommonname: '',
      rdpcertificatetrustedat: 0,
      rdpcertificatetrustmode: 0,
      rdpcertificateallowuntrustedroot: 0,
      rdpcertificateallowhostmismatch: 0
    };
  }

  /**
   * Old clients can reintroduce trust fields after the one-time migration.
   * Strip those fields after every remote-host pull, but never copy them into
   * localextensions on a new device.
   *
   * @returns -1 on rollback, 0 when unchanged, or the changed row count.
   */
  private stripRemoteHostDeviceTrustAfterCloudPull(): number {
    if (!this.store) { return -1; }
    try {
      this.store.beginTransaction();
      const predicates =
        new relationalStore.RdbPredicates('remotehosts');
      this.addCurrentOwnerPredicate(predicates);
      const rows: relationalStore.ResultSet =
        this.store.querySync(predicates);
      const idIndex: number = rows.getColumnIndex('id');
      const displayIndex: number =
        rows.getColumnIndex('displayconfig');
      const deletedIndex: number = rows.getColumnIndex(
        relationalStore.Field.DELETED_FLAG_FIELD);
      let changedRows: number = 0;
      while (rows.goToNextRow()) {
        if (deletedIndex >= 0 &&
          rows.getLong(deletedIndex) === 1) {
          continue;
        }
        const id: string = idIndex >= 0
          ? rows.getString(idIndex) : '';
        if (id === '') { continue; }
        const rawDisplay: string = displayIndex >= 0
          ? rows.getString(displayIndex) : '{}';
        const historical: Record<string, string> =
          extractLegacyRemoteHostDeviceTrust(rawDisplay);
        const physical: Record<string, string> =
          projectRemoteHostDeviceTrust(
            this.hostExtensionFromResult(rows));
        const displayPayload: RemoteHostDisplayPayload =
          decodeRemoteHostDisplayPayload(rawDisplay);
        const sanitizedDisplay: string =
          encodeRemoteHostDisplayPayload(
            displayPayload.displayConfigJson,
            displayPayload.extension);
        const needsDisplayCleanup: boolean =
          Object.keys(historical).length > 0 &&
          sanitizedDisplay !== rawDisplay;
        const needsPhysicalCleanup: boolean =
          remoteHostDeviceTrustIsMeaningful(physical);
        if (!needsDisplayCleanup && !needsPhysicalCleanup) {
          continue;
        }
        const bucket: relationalStore.ValuesBucket =
          this.clearedRemoteHostDeviceTrustBucket();
        if (needsDisplayCleanup) {
          bucket['displayconfig'] = sanitizedDisplay;
        }
        bucket['updatedat'] = Date.now();
        const updatePredicates =
          new relationalStore.RdbPredicates('remotehosts');
        updatePredicates.equalTo('id', id);
        this.addCurrentOwnerPredicate(updatePredicates);
        if (!rdbSingleRowAffected(
          this.store.updateSync(bucket, updatePredicates))) {
          throw new Error(
            'pulled device trust cleanup failed id=' + id);
        }
        changedRows++;
      }
      rows.close();
      if (changedRows > 0 &&
        !this.recordTableMutation(
          'remotehosts', 'strip_remote_device_trust')) {
        throw new Error(
          'pulled device trust cleanup journal failed');
      }
      this.store.commit();
      return changedRows;
    } catch (err) {
      try { this.store.rollBack(); } catch (_ignored) {}
      hilog.error(0x0001, 'CloudSync',
        '[CloudStore] pulled device trust cleanup failed: ' +
        safeError(err));
      return -1;
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
      bucket['userid'] = this.currentOwnerScopeId();
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
      const predicates = new relationalStore.RdbPredicates('usersettings');
      this.addCurrentOwnerPredicate(predicates);
      const rows = this.store.querySync(predicates);
      while (rows.goToNextRow()) {
        const keyIndex: number = rows.getColumnIndex('key');
        const valueIndex: number = rows.getColumnIndex('value');
        const key: string = keyIndex >= 0 && !rows.isColumnNull(keyIndex) ? rows.getString(keyIndex) : '';
        let legacyValueAccepted: boolean = false;
        if (key !== '' && cloudUserSettingIsSyncable(key) && valueIndex >= 0) {
          try {
            if (!rows.isColumnNull(valueIndex)) {
              const parsed: CloudUserSettingValue = JSON.parse(rows.getString(valueIndex)) as CloudUserSettingValue;
              if (typeof parsed === 'string' || typeof parsed === 'number' || typeof parsed === 'boolean') {
                result[key] = parsed;
                legacyValueAccepted = true;
              }
            }
          } catch (rowError) {
            hilog.warn(0x0001, 'CloudSync', '[CloudStore] ignored malformed legacy setting row key=' + key);
          }
        }
        if (legacyValueAccepted) { continue; }
        const payloadIndex: number = rows.getColumnIndex('payload');
        if (payloadIndex < 0) { continue; }
        const cloudSettingRow: Record<string, string> = {};
        const idIndex: number = rows.getColumnIndex('id');
        const userIdIndex: number = rows.getColumnIndex('userid');
        const updatedAtIndex: number = rows.getColumnIndex('updatedat');
        cloudSettingRow['id'] = idIndex >= 0 && !rows.isColumnNull(idIndex) ? rows.getString(idIndex) : '';
        cloudSettingRow['userid'] = userIdIndex >= 0 && !rows.isColumnNull(userIdIndex) ? rows.getString(userIdIndex) : '';
        cloudSettingRow['payload'] = rows.isColumnNull(payloadIndex) ? '' : rows.getString(payloadIndex);
        cloudSettingRow['updatedat'] = updatedAtIndex >= 0 && !rows.isColumnNull(updatedAtIndex)
          ? rows.getString(updatedAtIndex) : '0';
        let cloudRows: Array<Record<string, string>> = [];
        try {
          cloudRows = decodeUserSettingsPayload(cloudSettingRow);
        } catch (rowError) {
          hilog.warn(0x0001, 'CloudSync', '[CloudStore] ignored malformed settings payload id=' + cloudSettingRow['id']);
          continue;
        }
        for (let i = 0; i < cloudRows.length; i++) {
          const payloadKey: string = cloudRows[i]['key'] || '';
          if (!cloudUserSettingIsSyncable(payloadKey)) { continue; }
          try {
            const payloadValue: CloudUserSettingValue = JSON.parse(cloudRows[i]['value']) as CloudUserSettingValue;
            if (typeof payloadValue === 'string' || typeof payloadValue === 'number' || typeof payloadValue === 'boolean') {
              result[payloadKey] = payloadValue;
            }
          } catch (rowError) {
            hilog.warn(0x0001, 'CloudSync', '[CloudStore] ignored malformed settings payload key=' + payloadKey);
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

  private readCryptoParamForCurrentStore(key: string): string {
    if (!this.store) { return ''; }
    const id: string = this.cryptoParamId(key);
    if (id === '') { return ''; }
    try {
      const predicates = new relationalStore.RdbPredicates('cryptoparams');
      predicates.equalTo('id', id);
      predicates.equalTo('key', key);
      const rows: relationalStore.ResultSet =
        this.store.querySync(predicates);
      const value: string = rows.goToFirstRow()
        ? rows.getString(rows.getColumnIndex('value')) : '';
      rows.close();
      return value;
    } catch (_e) { return ''; }
  }

  readCryptoParam(
    key: string, lease: AccountSessionLease | null
  ): string {
    if (lease === null || !this.isLeaseCurrent(lease)) { return ''; }
    return this.readCryptoParamForCurrentStore(key);
  }

  private committedCryptoState(): CryptoCommittedState {
    const status: string = this.readCryptoParamForCurrentStore(
      'crypto_status');
    const salt: string = this.readCryptoParamForCurrentStore('crypto_salt');
    const verifier: string =
      this.readCryptoParamForCurrentStore('crypto_verifier');
    const configured: boolean = salt !== '' && verifier !== '';
    const readVersion = (key: string): number => {
      const value: number =
        Number(this.readCryptoParamForCurrentStore(key));
      return Number.isFinite(value) && value >= 0
        ? Math.floor(value) : 0;
    };
    return {
      status: status === '' && configured ? 'active' : status,
      configured,
      kdfVersion: readVersion('crypto_kdf_version'),
      kdfIterations: readVersion('crypto_kdf_iterations'),
      keyVersion: readVersion('crypto_key_version'),
      verifierVersion: readVersion('crypto_verifier_version'),
      envelopeVersion: readVersion('crypto_envelope_version')
    };
  }

  private recoverCryptoLifecycleState(
    lease: AccountSessionLease
  ): CryptoLifecycleDurableState {
    const committed: CryptoCommittedState = this.committedCryptoState();
    const raw: string =
      this.readLocalMetadataStrict(CRYPTO_LIFECYCLE_DURABLE_STATE_KEY);
    let candidate: CryptoLifecycleDurableState | null = null;
    if (raw !== '') {
      try {
        candidate = JSON.parse(raw) as CryptoLifecycleDurableState;
      } catch (err) {
        candidate = newCryptoLifecycleDurableState(
          lease, committed);
        candidate.phase = 'blocked';
        candidate.lastFailure =
          'crypto_lifecycle_json_corrupted:' + safeError(err);
      }
    }
    return recoverCryptoLifecycleDurableState(
      candidate, lease, committed);
  }

  private persistCryptoLifecycleState(
    state: CryptoLifecycleDurableState
  ): boolean {
    if (!this.store || this.currentLease === null ||
      state.ownerScopeId !== this.currentLease.ownerScopeId ||
      state.storeIdentity !== this.currentLease.storeIdentity ||
      state.generation !== this.currentLease.generation) {
      return false;
    }
    return this.writeLocalMetadata(
      CRYPTO_LIFECYCLE_DURABLE_STATE_KEY,
      JSON.stringify(state));
  }

  private cryptoLeaseIsCurrent(
    lease: AccountSessionLease | null
  ): boolean {
    return lease !== null && this.isLeaseCurrent(lease);
  }

  private nextCryptoTransactionId(label: string): string {
    if (this.cryptoLifecycleState === null) { return ''; }
    return label + '|' + this.currentOwnerScopeId() + '|' +
      (this.cryptoLifecycleState.revision + 1).toString() + '|' +
      Date.now().toString();
  }

  /**
   * Crypto lifecycle transitions own the physical account store exclusively.
   * API 23 has no cloud-sync cancellation primitive, so the only safe entry is
   * to stop accepting work and wait for the current queue to reach a terminal
   * state before permitting the matching lease to mutate encrypted rows.
   */
  async beginExclusiveCryptoLifecycle(
    lease: AccountSessionLease | null
  ): Promise<boolean> {
    if (!this.localMutationAllowed() ||
      !this.cryptoLeaseIsCurrent(lease) ||
      this.exclusiveCryptoLease !== null) {
      return false;
    }
    this.exclusiveCryptoLease =
      cloneAccountSessionLease(lease as AccountSessionLease);
    this.exclusiveCryptoReady = false;
    if (!(await this.quiesceCurrentScope()) ||
      !this.cryptoLeaseIsCurrent(lease)) {
      this.exclusiveCryptoLease = null;
      this.exclusiveCryptoReady = false;
      return false;
    }
    this.exclusiveCryptoReady = true;
    return true;
  }

  endExclusiveCryptoLifecycle(
    lease: AccountSessionLease | null
  ): boolean {
    if (!accountSessionLeaseEquals(this.exclusiveCryptoLease, lease)) {
      return false;
    }
    this.exclusiveCryptoReady = false;
    this.exclusiveCryptoLease = null;
    if (!this.cryptoLeaseIsCurrent(lease) ||
      lease === null ||
      !CloudSyncCoordinator.getInstance().reopenMutationGate(lease)) {
      return false;
    }
    this.mutationGateOpen = true;
    const pending: string[] =
      Object.keys(this.pendingMutationTableRevisions());
    for (let i = 0; i < pending.length; i++) {
      this.pushTable(pending[i]);
    }
    return true;
  }

  beginCryptoConfiguration(
    lease: AccountSessionLease | null
  ): string {
    if (!this.cryptoLifecycleMutationAllowed(lease) ||
      !this.cryptoLeaseIsCurrent(lease) ||
      this.cryptoLifecycleState === null ||
      !cryptoLifecycleCanConfigure(this.cryptoLifecycleState)) {
      return '';
    }
    const transactionId: string =
      this.nextCryptoTransactionId('configure');
    const next: CryptoLifecycleDurableState =
      cryptoLifecycleOperationStarted(
        this.cryptoLifecycleState, 'configuring', transactionId);
    if (!this.persistCryptoLifecycleState(next)) { return ''; }
    this.cryptoLifecycleState = next;
    return transactionId;
  }

  abortCryptoLifecycle(
    transactionId: string,
    lease: AccountSessionLease | null,
    failure: string
  ): void {
    if (!this.cryptoLeaseIsCurrent(lease) ||
      this.cryptoLifecycleState === null) {
      return;
    }
    const next: CryptoLifecycleDurableState =
      cryptoLifecycleOperationFailed(
        this.cryptoLifecycleState, transactionId, failure);
    if (next === this.cryptoLifecycleState) { return; }
    let durable: CryptoLifecycleDurableState = next;
    const committed: CryptoCommittedState =
      this.committedCryptoState();
    if (!committed.configured &&
      (committed.status === '' ||
        committed.status === 'disabled')) {
      durable = recoverCryptoLifecycleDurableState(
        next, lease as AccountSessionLease, committed);
    }
    if (this.persistCryptoLifecycleState(durable)) {
      this.cryptoLifecycleState = durable;
    }
  }

  markCryptoUnlocked(lease: AccountSessionLease | null): boolean {
    if (!this.cryptoLeaseIsCurrent(lease) ||
      this.cryptoLifecycleState === null ||
      this.committedCryptoState().configured === false) {
      return false;
    }
    const next: CryptoLifecycleDurableState =
      cryptoLifecycleMemoryStateChanged(
        this.cryptoLifecycleState, true);
    if (next === this.cryptoLifecycleState) {
      return this.cryptoLifecycleState.phase === 'active_unlocked';
    }
    if (!this.persistCryptoLifecycleState(next)) { return false; }
    this.cryptoLifecycleState = next;
    return true;
  }

  markCryptoLocked(lease: AccountSessionLease | null): boolean {
    if (!this.cryptoLeaseIsCurrent(lease) ||
      this.cryptoLifecycleState === null) {
      return false;
    }
    const next: CryptoLifecycleDurableState =
      cryptoLifecycleMemoryStateChanged(
        this.cryptoLifecycleState, false);
    if (next === this.cryptoLifecycleState) { return true; }
    if (!this.persistCryptoLifecycleState(next)) { return false; }
    this.cryptoLifecycleState = next;
    return true;
  }

  /** Current VNC generation. Missing legacy markers intentionally mean epoch 0. */
  getVncResetEpoch(): number {
    return this.readVncResetEpoch();
  }

  private readVncResetEpoch(): number {
    const epoch: number = Number(
      this.readCryptoParamForCurrentStore(VNC_RESET_EPOCH_KEY));
    return Number.isFinite(epoch) && epoch >= 0
      ? Math.floor(epoch) : 0;
  }

  private ensureVncResetEpochAtLeast(minimum: number): boolean {
    if (!this.store) { return false; }
    const current: number = this.readVncResetEpoch();
    if (current >= minimum) { return true; }
    const bucket: relationalStore.ValuesBucket =
      this.cryptoParamBucket(VNC_RESET_EPOCH_KEY, minimum.toString());
    if (!rdbInsertSucceeded(this.store.insertSync('cryptoparams', bucket,
      relationalStore.ConflictResolution.ON_CONFLICT_REPLACE))) {
      return false;
    }
    return this.recordTableMutation('cryptoparams', 'preserve_vnc_reset_epoch');
  }

  /** 读取当前加密状态 */
  getCryptoStatus(): string {
    return this.committedCryptoState().status;
  }

  /**
   * Upgrades every account-owned sensitive value in one RDB transaction.
   * Unknown/damaged envelopes, context mismatches and journal failures abort
   * the entire migration; no partially encrypted account is committed.
   */
  migrateAllDataToScopedV3(
    crypto: DataCrypto,
    lease: AccountSessionLease | null
  ): number {
    if (!this.cryptoLifecycleMutationAllowed(lease) || !this.store ||
      !crypto.isReady() ||
      !this.cryptoLeaseIsCurrent(lease) ||
      this.cryptoLifecycleState === null ||
      !cryptoLifecycleCanMigrate(this.cryptoLifecycleState)) {
      return -1;
    }
    let count: number = 0;
    const changedTables: string[] = [];
    const transactionId: string =
      this.nextCryptoTransactionId('migrate');
    const migratingState: CryptoLifecycleDurableState =
      cryptoLifecycleOperationStarted(
        this.cryptoLifecycleState, 'migrating', transactionId);
    if (!this.persistCryptoLifecycleState(migratingState)) {
      return -1;
    }
    this.cryptoLifecycleState = migratingState;
    try {
      this.store.beginTransaction();
      count = this.migrateAllDataToScopedV3InTransaction(
        crypto, changedTables);
      const committed: CryptoCommittedState =
        this.committedCryptoState();
      const activeState: CryptoLifecycleDurableState =
        cryptoLifecycleOperationCommitted(
          migratingState, 'active_unlocked', committed);
      if (!this.persistCryptoLifecycleState(activeState)) {
        throw new Error('crypto migration lifecycle commit failed');
      }
      this.store.commit();
      this.cryptoLifecycleState = activeState;
    } catch (err) {
      try { this.store.rollBack(); } catch (_rollbackError) {}
      this.abortCryptoLifecycle(
        transactionId, lease, safeError(err));
      hilog.error(0x0001, 'CloudSync',
        '[migrateAllDataToScopedV3] 全量回滚: ' + safeError(err));
      return -1;
    }
    if (remoteCryptoLifecycleMutationAllowed()) {
      for (let i = 0; i < changedTables.length; i++) {
        this.pushTable(changedTables[i]);
      }
    }
    return count;
  }

  /**
   * Commits KDF metadata and every encrypted business row together. The
   * candidate DEK exists only in DataCrypto memory and is discarded if this
   * transaction rolls back.
   */
  configureCryptoV3(
    salt: string,
    verifier: string,
    kdfVersion: number,
    kdfIterations: number,
    keyVersion: number,
    verifierVersion: number,
    crypto: DataCrypto,
    transactionId: string,
    lease: AccountSessionLease | null
  ): number {
    if (!this.cryptoLifecycleMutationAllowed(lease) || !this.store ||
      !crypto.isReady() || salt === '' || verifier === '' ||
      kdfVersion < 1 || kdfIterations < 100000 ||
      keyVersion < 1 || verifierVersion < 1 ||
      !this.cryptoLeaseIsCurrent(lease) ||
      this.cryptoLifecycleState === null ||
      this.cryptoLifecycleState.phase !== 'configuring' ||
      this.cryptoLifecycleState.transactionId !== transactionId) {
      return -1;
    }
    const changedTables: string[] = [];
    let count: number = 0;
    try {
      this.store.beginTransaction();
      const configuring: relationalStore.ValuesBucket =
        this.cryptoParamBucket('crypto_status', 'configuring');
      const saltBucket: relationalStore.ValuesBucket =
        this.cryptoParamBucket('crypto_salt', salt);
      const verifierBucket: relationalStore.ValuesBucket =
        this.cryptoParamBucket('crypto_verifier', verifier);
      const kdfVersionBucket: relationalStore.ValuesBucket =
        this.cryptoParamBucket(
          'crypto_kdf_version', kdfVersion.toString());
      const iterationsBucket: relationalStore.ValuesBucket =
        this.cryptoParamBucket(
          'crypto_kdf_iterations', kdfIterations.toString());
      const keyVersionBucket: relationalStore.ValuesBucket =
        this.cryptoParamBucket(
          'crypto_key_version', keyVersion.toString());
      const verifierVersionBucket: relationalStore.ValuesBucket =
        this.cryptoParamBucket(
          'crypto_verifier_version', verifierVersion.toString());
      const envelopeVersionBucket: relationalStore.ValuesBucket =
        this.cryptoParamBucket(
          'crypto_envelope_version',
          crypto.SCOPED_ENVELOPE_VERSION.toString());
      if (!rdbInsertSucceeded(this.store.insertSync(
        'cryptoparams', configuring,
        relationalStore.ConflictResolution.ON_CONFLICT_REPLACE)) ||
        !rdbInsertSucceeded(this.store.insertSync(
          'cryptoparams', saltBucket,
          relationalStore.ConflictResolution.ON_CONFLICT_REPLACE)) ||
        !rdbInsertSucceeded(this.store.insertSync(
          'cryptoparams', verifierBucket,
          relationalStore.ConflictResolution.ON_CONFLICT_REPLACE)) ||
        !rdbInsertSucceeded(this.store.insertSync(
          'cryptoparams', kdfVersionBucket,
          relationalStore.ConflictResolution.ON_CONFLICT_REPLACE)) ||
        !rdbInsertSucceeded(this.store.insertSync(
          'cryptoparams', iterationsBucket,
          relationalStore.ConflictResolution.ON_CONFLICT_REPLACE)) ||
        !rdbInsertSucceeded(this.store.insertSync(
          'cryptoparams', keyVersionBucket,
          relationalStore.ConflictResolution.ON_CONFLICT_REPLACE)) ||
        !rdbInsertSucceeded(this.store.insertSync(
          'cryptoparams', verifierVersionBucket,
          relationalStore.ConflictResolution.ON_CONFLICT_REPLACE)) ||
        !rdbInsertSucceeded(this.store.insertSync(
          'cryptoparams', envelopeVersionBucket,
          relationalStore.ConflictResolution.ON_CONFLICT_REPLACE))) {
        throw new Error('crypto v3 parameter staging failed');
      }
      count = this.migrateAllDataToScopedV3InTransaction(
        crypto, changedTables);
      const active: relationalStore.ValuesBucket =
        this.cryptoParamBucket('crypto_status', 'active');
      if (!rdbInsertSucceeded(this.store.insertSync(
        'cryptoparams', active,
        relationalStore.ConflictResolution.ON_CONFLICT_REPLACE))) {
        throw new Error('crypto v3 activation failed');
      }
      if (!this.recordTableMutation('cryptoparams', 'configure_v3')) {
        throw new Error('crypto v3 parameter journal failed');
      }
      const committed: CryptoCommittedState = {
        status: 'active',
        configured: true,
        kdfVersion,
        kdfIterations,
        keyVersion,
        verifierVersion,
        envelopeVersion: crypto.SCOPED_ENVELOPE_VERSION
      };
      const activeState: CryptoLifecycleDurableState =
        cryptoLifecycleOperationCommitted(
          this.cryptoLifecycleState, 'active_unlocked', committed);
      if (!this.persistCryptoLifecycleState(activeState)) {
        throw new Error('crypto lifecycle activation failed');
      }
      this.store.commit();
      this.cryptoLifecycleState = activeState;
    } catch (err) {
      try { this.store.rollBack(); } catch (_rollbackError) {}
      hilog.error(0x0001, 'CloudSync',
        '[configureCryptoV3] 全量回滚: ' + safeError(err));
      return -1;
    }
    this.lastKnownCryptoStatus = 'active';
    if (remoteCryptoLifecycleMutationAllowed()) {
      this.pushTable('cryptoparams');
      for (let i = 0; i < changedTables.length; i++) {
        this.pushTable(changedTables[i]);
      }
    }
    return count;
  }

  /** Caller owns the active RDB transaction. */
  private migrateAllDataToScopedV3InTransaction(
    crypto: DataCrypto, changedTables: string[]
  ): number {
    let count: number = 0;
    count += this.migrateLegacyHostPasswordToScopedV3(
      crypto, changedTables);
    count += this.migrateScalarTableToScopedV3(
      crypto, 'remotehosts',
      ['passward', 'sshkeydata', 'sshkeypassphrase'],
      changedTables);
    count += this.migrateScalarTableToScopedV3(
      crypto, 'rdpcredentials', ['password'], changedTables);
    count += this.migrateScalarTableToScopedV3(
      crypto, 'sshkeys', ['privatekey'], changedTables);
    count += this.migrateScalarTableToScopedV3(
      crypto, 'totpentries', ['secret'], changedTables);
    count += this.migrateScalarTableToScopedV3(
      crypto, 'rustdeskrelays', ['apipassword', 'key'], changedTables);
    count += this.migrateRelayAccountsToScopedV3(crypto, changedTables);
    count += this.migrateLocalExtensionSecretsToScopedV3(crypto);
    count += this.migrateVncSecretsToV3(crypto, changedTables);
    return count;
  }

  /** Runs only inside migrateAllDataToScopedV3's active transaction. */
  private migrateLegacyHostPasswordToScopedV3(
    crypto: DataCrypto, changedTables: string[]
  ): number {
    if (!this.store) { throw new Error('host migration store unavailable'); }
    const predicates = new relationalStore.RdbPredicates('remotehosts');
    this.addCurrentOwnerPredicate(predicates);
    const rows: relationalStore.ResultSet = this.store.querySync(predicates);
    let count: number = 0;
    try {
      while (rows.goToNextRow()) {
        const id: string = rows.getString(rows.getColumnIndex('id'));
        const canonicalIndex: number = rows.getColumnIndex('passward');
        const legacyIndex: number = rows.getColumnIndex('password');
        if (id === '' || legacyIndex < 0 || rows.isColumnNull(legacyIndex)) {
          continue;
        }
        const legacy: string = rows.getString(legacyIndex);
        if (legacy === '') { continue; }
        const canonical: string = canonicalIndex >= 0 &&
          !rows.isColumnNull(canonicalIndex)
          ? rows.getString(canonicalIndex) : '';
        const bucket: relationalStore.ValuesBucket = { password: '' };
        if (canonical === '') {
          bucket['passward'] = crypto.migrateValueToScopedV3(
            this.currentOwnerScopeId(), 'remotehosts', id,
            'passward', legacy, this.readVncResetEpoch());
        }
        const updatePredicates =
          new relationalStore.RdbPredicates('remotehosts');
        updatePredicates.equalTo('id', id);
        this.addCurrentOwnerPredicate(updatePredicates);
        if (!rdbSingleRowAffected(
          this.store.updateSync(bucket, updatePredicates))) {
          throw new Error('legacy host password migration failed: ' + id);
        }
        if (!this.recordLocalMutation(
          'remotehosts', id, 'crypto_migrate_v3')) {
          throw new Error(
            'legacy host password migration journal failed: ' + id);
        }
        this.rememberChangedTable(changedTables, 'remotehosts');
        count++;
      }
    } finally {
      rows.close();
    }
    return count;
  }

  private rememberChangedTable(tables: string[], table: string): void {
    if (tables.indexOf(table) < 0) { tables.push(table); }
  }

  /** Runs only inside migrateAllDataToScopedV3's active transaction. */
  private migrateScalarTableToScopedV3(crypto: DataCrypto, table: string,
    fields: string[], changedTables: string[]): number {
    if (!this.store) { throw new Error('crypto migration store unavailable'); }
    const predicates = new relationalStore.RdbPredicates(table);
    this.addCurrentOwnerPredicate(predicates);
    const rows: relationalStore.ResultSet = this.store.querySync(predicates);
    let count: number = 0;
    try {
      while (rows.goToNextRow()) {
        const id: string = rows.getString(rows.getColumnIndex('id'));
        if (id === '') { throw new Error('missing record identity: ' + table); }
        const bucket: relationalStore.ValuesBucket = {};
        let changed: boolean = false;
        for (let i = 0; i < fields.length; i++) {
          const field: string = fields[i];
          const index: number = rows.getColumnIndex(field);
          if (index < 0 || rows.isColumnNull(index)) { continue; }
          const value: string = rows.getString(index);
          if (value === '') { continue; }
          const next: string = crypto.migrateValueToScopedV3(
            this.currentOwnerScopeId(), table, id, field, value,
            this.readVncResetEpoch());
          if (next !== value) {
            bucket[field] = next;
            changed = true;
          }
        }
        if (!changed) { continue; }
        const updatePredicates = new relationalStore.RdbPredicates(table);
        updatePredicates.equalTo('id', id);
        this.addCurrentOwnerPredicate(updatePredicates);
        if (!rdbSingleRowAffected(
          this.store.updateSync(bucket, updatePredicates))) {
          throw new Error('crypto migration update failed: ' + table + '/' + id);
        }
        if (!this.recordLocalMutation(table, id, 'crypto_migrate_v3')) {
          throw new Error('crypto migration journal failed: ' + table + '/' + id);
        }
        this.rememberChangedTable(changedTables, table);
        count++;
      }
    } finally {
      rows.close();
    }
    return count;
  }

  /** Runs only inside migrateAllDataToScopedV3's active transaction. */
  private migrateRelayAccountsToScopedV3(
    crypto: DataCrypto, changedTables: string[]): number {
    if (!this.store) { throw new Error('relay migration store unavailable'); }
    const predicates = new relationalStore.RdbPredicates('rustdeskrelays');
    this.addCurrentOwnerPredicate(predicates);
    const rows: relationalStore.ResultSet = this.store.querySync(predicates);
    let count: number = 0;
    try {
      while (rows.goToNextRow()) {
        const id: string = rows.getString(rows.getColumnIndex('id'));
        const index: number = rows.getColumnIndex('accountsjson');
        if (id === '' || index < 0 || rows.isColumnNull(index)) { continue; }
        const value: string = rows.getString(index);
        if (value === '') { continue; }
        const accounts: RustDeskAccountJSON[] =
          JSON.parse(value) as RustDeskAccountJSON[];
        let changed: boolean = false;
        for (let i = 0; i < accounts.length; i++) {
          if (accounts[i].id === '') {
            throw new Error('relay account identity missing: ' + id);
          }
          if (accounts[i].password === '') { continue; }
          const next: string = crypto.migrateValueToScopedV3(
            this.currentOwnerScopeId(), 'rustdeskrelays', id,
            'accounts/' + accounts[i].id + '/password',
            accounts[i].password, this.readVncResetEpoch());
          if (next !== accounts[i].password) {
            accounts[i].password = next;
            changed = true;
          }
        }
        if (!changed) { continue; }
        const bucket: relationalStore.ValuesBucket = {
          accountsjson: JSON.stringify(accounts),
          updatedat: Date.now()
        };
        const updatePredicates =
          new relationalStore.RdbPredicates('rustdeskrelays');
        updatePredicates.equalTo('id', id);
        this.addCurrentOwnerPredicate(updatePredicates);
        if (!rdbSingleRowAffected(
          this.store.updateSync(bucket, updatePredicates))) {
          throw new Error('relay accounts migration update failed: ' + id);
        }
        if (!this.recordLocalMutation(
          'rustdeskrelays', id, 'crypto_migrate_v3')) {
          throw new Error('relay accounts migration journal failed: ' + id);
        }
        this.rememberChangedTable(changedTables, 'rustdeskrelays');
        count++;
      }
    } finally {
      rows.close();
    }
    return count;
  }

  /** Runs only inside migrateAllDataToScopedV3's active transaction. */
  private migrateLocalExtensionSecretsToScopedV3(
    crypto: DataCrypto
  ): number {
    if (!this.store) {
      throw new Error('local extension migration store unavailable');
    }
    const rows: relationalStore.ResultSet = this.store.querySync(
      new relationalStore.RdbPredicates('localextensions'));
    let count: number = 0;
    try {
      while (rows.goToNextRow()) {
        const id: string = rows.getString(rows.getColumnIndex('id'));
        const table: string =
          rows.getString(rows.getColumnIndex('tablename'));
        const recordId: string =
          rows.getString(rows.getColumnIndex('recordid'));
        const payload: string =
          rows.getString(rows.getColumnIndex('payload'));
        if (id === '' || recordId === '' || payload === '') { continue; }
        if (table !== 'remotehosts' &&
          table !== RDP_RESTRICTED_ADMIN_SECRET_TABLE) {
          continue;
        }
        const source: Record<string, string> =
          JSON.parse(payload) as Record<string, string>;
        const next: Record<string, string> = {};
        const keys: string[] = Object.keys(source);
        let changed: boolean = false;
        for (let i = 0; i < keys.length; i++) {
          const key: string = keys[i];
          const value: string = source[key];
          if (table === 'remotehosts' && key === 'password') {
            changed = true;
            continue;
          }
          const sensitive: boolean =
            (table === 'remotehosts' && key === 'sshkeypassphrase') ||
            (table === RDP_RESTRICTED_ADMIN_SECRET_TABLE &&
              (key === 'hash' || key === 'binding'));
          if (!sensitive || value === '') {
            next[key] = value;
            continue;
          }
          const aadTable: string = table === 'remotehosts'
            ? 'localextensions/remotehosts'
            : RDP_RESTRICTED_ADMIN_SECRET_TABLE;
          next[key] = crypto.migrateValueToScopedV3(
            this.currentOwnerScopeId(), aadTable, recordId, key, value,
            this.readVncResetEpoch());
          changed = changed || next[key] !== value;
        }
        if (!changed) { continue; }
        const bucket: relationalStore.ValuesBucket = {
          payload: JSON.stringify(next),
          updatedat: Date.now()
        };
        const updatePredicates =
          new relationalStore.RdbPredicates('localextensions');
        updatePredicates.equalTo('id', id);
        if (!rdbSingleRowAffected(
          this.store.updateSync(bucket, updatePredicates))) {
          throw new Error('local extension migration failed: ' + id);
        }
        count++;
      }
    } finally {
      rows.close();
    }
    return count;
  }

  /** Runs only inside migrateAllDataToScopedV3's active transaction. */
  private migrateVncSecretsToV3(
    crypto: DataCrypto, changedTables: string[]
  ): number {
    if (!this.store) { throw new Error('VNC migration store unavailable'); }
    const tables: string[] =
      [VNC_LOCAL_TABLE, VNC_CLOUD_TABLE, LEGACY_VNC_CLOUD_TABLE];
    let count: number = 0;
    for (let tableIndex = 0; tableIndex < tables.length; tableIndex++) {
      const table: string = tables[tableIndex];
      let rows: relationalStore.ResultSet | null = null;
      try {
        const predicates = new relationalStore.RdbPredicates(table);
        this.addCurrentOwnerPredicate(predicates);
        rows = this.store.querySync(predicates);
      } catch (err) {
        if (table === LEGACY_VNC_CLOUD_TABLE) { continue; }
        throw new Error('VNC migration table unavailable: ' +
          table + ' — ' + safeError(err));
      }
      try {
        while (rows.goToNextRow()) {
          const deletedIndex: number =
            rows.getColumnIndex(relationalStore.Field.DELETED_FLAG_FIELD);
          if (deletedIndex >= 0 && rows.getLong(deletedIndex) === 1) {
            continue;
          }
          const record: VncRecord = this.vncRecordFromResult(rows);
          if (record.recordType !== 'secret' ||
            record.ciphertext === '') { continue; }
          const storageMode: string =
            vncSecretStorageModeFromPayload(record.payload);
          if (storageMode === 'encrypted_v3') {
            crypto.decryptVncFieldV3(
              record.userId, VNC_CLOUD_TABLE, record.id, 'ciphertext',
              record.ciphertext, record.resetEpoch);
            continue;
          }
          let plaintext: string = '';
          if (storageMode === 'encrypted_v2') {
            plaintext = crypto.decryptLegacyVncFieldV2(
              'remotedesktop|vnc', VNC_CLOUD_TABLE, record.id,
              'ciphertext', record.ciphertext);
          } else if (storageMode === 'plain_explicit_v1') {
            plaintext = decodePlainVncSecret(record.ciphertext) || '';
          } else {
            plaintext = crypto.decrypt(record.ciphertext);
          }
          if (plaintext === '') {
            throw new Error('VNC secret plaintext invalid: ' + record.id);
          }
          const metadata = vncPayloadObject(record.payload);
          if (metadata === null) {
            throw new Error('VNC secret metadata invalid: ' + record.id);
          }
          metadata['storageMode'] = 'encrypted_v3';
          record.payload = vncCanonicalJson(metadata);
          record.ciphertext = crypto.encryptVncFieldV3(
            record.userId, VNC_CLOUD_TABLE, record.id,
            'ciphertext', plaintext, record.resetEpoch,
            record.schemaVersion > 0 ? record.schemaVersion : 1);
          record.envelopeVersion = VNC_SECRET_ENVELOPE_VERSION;
          record.cryptoVersion = VNC_CRYPTO_VERSION;
          record.keyVersion = VNC_KEY_VERSION;
          record.aadVersion = VNC_AAD_VERSION;
          record.syncVersion = Math.max(0, record.syncVersion) + 1;
          record.updatedAt = Date.now();
          record.payloadHashSha256 =
            vncPayloadHashSha256(record.payload);
          const bucket: relationalStore.ValuesBucket =
            this.vncRecordToBucket(record, table !== VNC_CLOUD_TABLE);
          const updatePredicates =
            new relationalStore.RdbPredicates(table);
          updatePredicates.equalTo('id', record.id);
          updatePredicates.equalTo('userid', this.currentOwnerScopeId());
          if (!rdbSingleRowAffected(
            this.store.updateSync(bucket, updatePredicates))) {
            throw new Error(
              'VNC crypto migration failed: ' + table + '/' + record.id);
          }
          if (table === VNC_CLOUD_TABLE) {
            if (!this.recordLocalMutation(
              VNC_CLOUD_TABLE, record.id, 'crypto_migrate_v3')) {
              throw new Error(
                'VNC crypto migration journal failed: ' + record.id);
            }
            this.rememberChangedTable(
              changedTables, VNC_CLOUD_TABLE);
          }
          count++;
        }
      } finally {
        rows.close();
      }
    }
    return count;
  }

  private sensitiveBusinessTables(): string[] {
    return [
      'remotehosts', 'rdpcredentials', 'sshkeys', 'totpentries',
      'rustdeskrelays', VNC_CLOUD_TABLE
    ];
  }

  /** Caller owns the active transaction and the account physical store. */
  private clearAllTablesInActiveTransaction(tables: string[]): void {
    if (!this.store) {
      throw new Error('sensitive data store unavailable');
    }
    // These local-only tables contain data for exactly one physical account
    // store. They must be cleared before fresh delete intents are recorded.
    this.store.deleteSync(
      new relationalStore.RdbPredicates('localextensions'));
    this.store.deleteSync(
      new relationalStore.RdbPredicates(LOCAL_MUTATION_JOURNAL_TABLE));
    const localVncPredicates =
      new relationalStore.RdbPredicates(VNC_LOCAL_TABLE);
    this.addCurrentOwnerPredicate(localVncPredicates);
    this.store.deleteSync(localVncPredicates);
    if (!this.clearRustDeskRelayControlPlaneProfiles()) {
      throw new Error('relay profile metadata clear failed');
    }
    for (let i = 0; i < tables.length; i++) {
      const predicates =
        new relationalStore.RdbPredicates(tables[i]);
      this.addCurrentOwnerPredicate(predicates);
      this.store.deleteSync(predicates);
      if (!this.recordTableMutation(tables[i], 'clear')) {
        throw new Error('clear journal failed table=' + tables[i]);
      }
      hilog.info(0x0001, 'CloudSync',
        '[clearAllTables] ' + tables[i] + ' 已清空');
    }
  }

  /**
   * 批量解密敏感业务表；返回 -1 表示任何本地写入失败且本次事务已回滚。
   * 调用方绝不能在 -1 后删除密码学参数或发布 disabled 信令。
   */
  decryptAllData(
    crypto: DataCrypto,
    pushChanges: boolean = true,
    manageTransaction: boolean = true,
    lease: AccountSessionLease | null = null
  ): number {
    const mutationAllowed: boolean = lease === null
      ? this.localMutationAllowed()
      : this.cryptoLifecycleMutationAllowed(lease);
    if (!mutationAllowed || !this.store) { return -1; }
    let count: number = 0;
    let hostsChanged: boolean = false;
    let rdpCredentialsChanged: boolean = false;
    let relaysChanged: boolean = false;
    let sshKeysChanged: boolean = false;
    let totpEntriesChanged: boolean = false;
    let vncRecordsChanged: boolean = false;
    try {
      if (manageTransaction) { this.store.beginTransaction(); }
      // 1. remotehosts: the canonical password lives in `passward`.
      const hostPredicates = new relationalStore.RdbPredicates('remotehosts');
      this.addCurrentOwnerPredicate(hostPredicates);
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
          vb['passward'] = crypto.decryptScopedOrLegacy(
            this.currentOwnerScopeId(), 'remotehosts', id, 'passward',
            pwd, this.readVncResetEpoch());
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
          vb['sshkeydata'] = crypto.decryptScopedOrLegacy(
            this.currentOwnerScopeId(), 'remotehosts', id,
            'sshkeydata', sshData, this.readVncResetEpoch());
          changed = true;
        }
        if (changed) {
          const predicates = new relationalStore.RdbPredicates('remotehosts');
          predicates.equalTo('id', id);
          this.addCurrentOwnerPredicate(predicates);
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
      this.addCurrentOwnerPredicate(rdpPredicates);
      const rdpRs = this.store.querySync(rdpPredicates);
      while (rdpRs.goToNextRow()) {
        const id: string = rdpRs.getString(rdpRs.getColumnIndex('id'));
        const pwd: string = rdpRs.getString(rdpRs.getColumnIndex('password'));
        const vb: relationalStore.ValuesBucket = {};
        if (crypto.isEncrypted(pwd)) {
          vb['password'] = crypto.decryptScopedOrLegacy(
            this.currentOwnerScopeId(), 'rdpcredentials', id,
            'password', pwd, this.readVncResetEpoch());
          const predicates = new relationalStore.RdbPredicates('rdpcredentials');
          predicates.equalTo('id', id);
          this.addCurrentOwnerPredicate(predicates);
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
      this.addCurrentOwnerPredicate(keyPredicates);
      const keyRs = this.store.querySync(keyPredicates);
      while (keyRs.goToNextRow()) {
        const id: string = keyRs.getString(keyRs.getColumnIndex('id'));
        const pk: string = keyRs.getString(keyRs.getColumnIndex('privatekey'));
        if (crypto.isEncrypted(pk)) {
          const vb: relationalStore.ValuesBucket = {};
          vb['privatekey'] = crypto.decryptScopedOrLegacy(
            this.currentOwnerScopeId(), 'sshkeys', id,
            'privatekey', pk, this.readVncResetEpoch());
          const predicates = new relationalStore.RdbPredicates('sshkeys');
          predicates.equalTo('id', id);
          this.addCurrentOwnerPredicate(predicates);
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
      this.addCurrentOwnerPredicate(totpPredicates);
      const totpRs = this.store.querySync(totpPredicates);
      while (totpRs.goToNextRow()) {
        const id: string = totpRs.getString(totpRs.getColumnIndex('id'));
        const sec: string = totpRs.getString(totpRs.getColumnIndex('secret'));
        if (crypto.isEncrypted(sec)) {
          const vb: relationalStore.ValuesBucket = {};
          vb['secret'] = crypto.decryptScopedOrLegacy(
            this.currentOwnerScopeId(), 'totpentries', id,
            'secret', sec, this.readVncResetEpoch());
          const predicates = new relationalStore.RdbPredicates('totpentries');
          predicates.equalTo('id', id);
          this.addCurrentOwnerPredicate(predicates);
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
      this.addCurrentOwnerPredicate(relayPredicates);
      const relayRs = this.store.querySync(relayPredicates);
      while (relayRs.goToNextRow()) {
        const id: string = relayRs.getString(relayRs.getColumnIndex('id'));
        let changed: boolean = false;
        const vb: relationalStore.ValuesBucket = {};
        const apiPassword: string = relayRs.getString(relayRs.getColumnIndex('apipassword'));
        const key: string = relayRs.getString(relayRs.getColumnIndex('key'));
        if (crypto.isEncrypted(apiPassword)) {
          vb['apipassword'] = crypto.decryptScopedOrLegacy(
            this.currentOwnerScopeId(), 'rustdeskrelays', id,
            'apipassword', apiPassword, this.readVncResetEpoch());
          changed = true;
        }
        if (crypto.isEncrypted(key)) {
          vb['key'] = crypto.decryptScopedOrLegacy(
            this.currentOwnerScopeId(), 'rustdeskrelays', id, 'key',
            key, this.readVncResetEpoch());
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
                  accounts[i].password = crypto.decryptScopedOrLegacy(
                    this.currentOwnerScopeId(), 'rustdeskrelays', id,
                    'accounts/' + accounts[i].id + '/password',
                    accounts[i].password, this.readVncResetEpoch());
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
          this.addCurrentOwnerPredicate(predicates);
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

      // 6. VNC secret owner: convert encrypted_v2/v3 to the explicitly
      // confirmed plain-v1 envelope before the global DEK is removed. This is a
      // transactional migration; a single undecryptable row aborts the whole
      // status transition instead of leaving an unreadable half-migrated set.
      const vncDecrypted: number = this.decryptVncSecretsForDisable(crypto);
      count += vncDecrypted;
      vncRecordsChanged = vncDecrypted > 0;

      // Device-local extension secrets are not represented by a cloud column.
      // When encryption is disabled, convert the SSH passphrase in place and
      // wipe restricted-admin material instead of leaving inaccessible cipher
      // text (or a plaintext NTLM hash) behind.
      count += this.decryptSensitiveLocalExtensions(crypto);

      if (manageTransaction) { this.store.commit(); }
      if (pushChanges && manageTransaction) {
        if (hostsChanged) { this.pushTable('remotehosts'); }
        if (rdpCredentialsChanged) { this.pushTable('rdpcredentials'); }
        if (relaysChanged) { this.pushTable('rustdeskrelays'); }
        if (sshKeysChanged) { this.pushTable('sshkeys'); }
        if (totpEntriesChanged) { this.pushTable('totpentries'); }
        if (vncRecordsChanged) { this.pushTable(VNC_CLOUD_TABLE); }
      }

      hilog.info(0x0001, 'CloudSync', "[decryptAllData] 已解密 " + count.toString() + " 条记录");
    } catch (e) {
      if (!manageTransaction) {
        throw new Error(
          '[decryptAllData] active transaction failed: ' +
          DataCrypto.errDetail(e));
      }
      try { this.store.rollBack(); } catch (_ignored) {}
      hilog.error(0x0001, 'CloudSync', "[decryptAllData] 失败: " + DataCrypto.errDetail(e));
      return -1;
    }
    return count;
  }

  /**
   * Convert active VNC encrypted_v2/v3 rows only in device-local mirrors.
   * The distributed cloud mirror must remain encrypted: disabling local
   * encryption is not consent to publish plain-v1 or rewrite another device.
   */
  private decryptVncSecretsForDisable(crypto: DataCrypto): number {
    if (!this.store) { throw new Error('VNC store unavailable'); }
    const tables: string[] = [
      VNC_LOCAL_TABLE, LEGACY_VNC_CLOUD_TABLE
    ];
    let changedCount: number = 0;
    for (let tableIndex = 0; tableIndex < tables.length; tableIndex++) {
      const table: string = tables[tableIndex];
      let rows: relationalStore.ResultSet | null = null;
      try {
        const predicates = new relationalStore.RdbPredicates(table);
        this.addCurrentOwnerPredicate(predicates);
        rows = this.store.querySync(predicates);
      } catch (_e) {
        if (table === LEGACY_VNC_CLOUD_TABLE) { continue; }
        throw new Error('VNC table read failed: ' + table);
      }
      try {
        while (rows.goToNextRow()) {
          const deletedFlagIndex: number = rows.getColumnIndex(relationalStore.Field.DELETED_FLAG_FIELD);
          if (deletedFlagIndex >= 0 && rows.getLong(deletedFlagIndex) === 1) { continue; }
          const record: VncRecord = this.vncRecordFromResult(rows);
          if (!vncRecordHasActiveEncryptedCiphertext(record)) { continue; }
          if (!vncRecordIsValid(record)) { throw new Error('invalid VNC secret row: ' + record.id); }
          const metadata = vncPayloadObject(record.payload);
          if (metadata === null) { throw new Error('invalid VNC secret metadata: ' + record.id); }
          const storageMode: string =
            vncSecretStorageModeFromPayload(record.payload);
          let plaintext: string = '';
          if (storageMode === 'encrypted_v3') {
            plaintext = crypto.decryptVncFieldV3(
              record.userId, VNC_CLOUD_TABLE, record.id, 'ciphertext',
              record.ciphertext, record.resetEpoch);
          } else if (storageMode === 'encrypted_v2') {
            plaintext = crypto.decryptLegacyVncFieldV2(
              'remotedesktop|vnc', VNC_CLOUD_TABLE, record.id,
              'ciphertext', record.ciphertext);
          } else {
            throw new Error(
              'unsupported encrypted VNC storage mode: ' + record.id);
          }
          const encoded: string = encodePlainVncSecret(plaintext);
          if (encoded === '') { throw new Error('VNC secret cannot be represented as plain-v1: ' + record.id); }
          metadata['storageMode'] = 'plain_explicit_v1';
          record.payload = vncCanonicalJson(metadata);
          record.ciphertext = encoded;
          record.envelopeVersion = VNC_PLAIN_SECRET_ENVELOPE_VERSION;
          record.cryptoVersion = 0;
          record.keyVersion = 0;
          record.aadVersion = 0;
          record.syncVersion = Math.max(0, record.syncVersion) + 1;
          record.updatedAt = Date.now();
          record.payloadHashSha256 = vncPayloadHashSha256(record.payload);
          const source: Record<string, string> = vncRecordToCloudRow(record);
          const bucket: relationalStore.ValuesBucket = {};
          for (let i = 0; i < VNC_RECORD_COLUMNS.length; i++) {
            const column: string = VNC_RECORD_COLUMNS[i];
            const value: string = source[column];
            if (['envelopeversion', 'cryptoversion', 'keyversion', 'aadversion', 'syncversion',
              'schemaversion', 'resetepoch', 'createdat', 'updatedat', 'deletedat'].indexOf(column) >= 0) {
              bucket[column] = Number(value);
            } else {
              bucket[column] = value;
            }
          }
          bucket['localonly'] = 1;
          const predicates = new relationalStore.RdbPredicates(table);
          predicates.equalTo('id', record.id);
          predicates.equalTo('userid', record.userId);
          if (!rdbSingleRowAffected(this.store.updateSync(bucket, predicates))) {
            throw new Error('VNC secret update failed: ' + table + '/' + record.id);
          }
          if (!this.recordLocalMutation(table, record.id, 'crypto_decrypt')) {
            throw new Error('VNC secret journal failed: ' + table + '/' + record.id);
          }
          changedCount++;
        }
      } finally {
        rows.close();
      }
    }
    return changedCount;
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
        if (table === RDP_RESTRICTED_ADMIN_SECRET_TABLE || table === 'remotehosts') {
          const ownerPredicates = new relationalStore.RdbPredicates('remotehosts');
          ownerPredicates.equalTo('id', recordId);
          this.addCurrentOwnerPredicate(ownerPredicates);
          const ownerRows: relationalStore.ResultSet = this.store.querySync(ownerPredicates);
          const owned: boolean = ownerRows.goToFirstRow();
          ownerRows.close();
          if (!owned) { continue; }
        }
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
            next[key] = crypto.decryptScopedOrLegacy(
              this.currentOwnerScopeId(), 'localextensions/remotehosts',
              recordId, 'sshkeypassphrase', value,
              this.readVncResetEpoch());
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

  /** Caller owns the active transaction. The reset epoch and status survive. */
  private clearCryptoSecretsInActiveTransaction(): void {
    if (!this.store) {
      throw new Error('crypto parameter store unavailable');
    }
    for (let i = 0; i < CRYPTO_SECRET_PARAM_KEYS.length; i++) {
      const predicates =
        new relationalStore.RdbPredicates('cryptoparams');
      predicates.equalTo(
        'id', this.cryptoParamId(CRYPTO_SECRET_PARAM_KEYS[i]));
      predicates.equalTo('key', CRYPTO_SECRET_PARAM_KEYS[i]);
      this.store.deleteSync(predicates);
    }
  }

  private pauseCloudSelectionForLocalCryptoTransition(
    reset: boolean
  ): CryptoCloudSelectionSnapshot | null {
    if (this.appContext === null) { return null; }
    const snapshot: CryptoCloudSelectionSnapshot = {
      ordinary: this.syncSelection.selectedBusinessTables(),
      vnc: this.vncSyncSelection.selectedScopes()
    };
    const nextOrdinary: string[] =
      cloudSelectionAfterLocalCryptoTransition(
        snapshot.ordinary, reset);
    const nextVnc: string[] =
      vncSelectionAfterLocalCryptoTransition(
        snapshot.vnc, reset);
    if (!this.syncSelection.replaceSelectedBusinessTables(
      this.appContext, nextOrdinary)) {
      return null;
    }
    if (!this.vncSyncSelection.replaceSelectedScopes(
      this.appContext, nextVnc)) {
      this.syncSelection.replaceSelectedBusinessTables(
        this.appContext, snapshot.ordinary);
      return null;
    }
    return snapshot;
  }

  private restoreCloudSelectionAfterFailedCryptoTransition(
    snapshot: CryptoCloudSelectionSnapshot
  ): void {
    if (this.appContext === null) { return; }
    this.syncSelection.replaceSelectedBusinessTables(
      this.appContext, snapshot.ordinary);
    this.vncSyncSelection.replaceSelectedScopes(
      this.appContext, snapshot.vnc);
  }

  private pushCryptoTransitionTables(
    includeVncReset: boolean = false
  ): void {
    if (!remoteCryptoLifecycleMutationAllowed()) {
      hilog.warn(0x0001, 'CloudSync',
        '远端加密生命周期协议未启用；本机原子变更不会发布为跨设备破坏性操作');
      return;
    }
    this.pushTable('cryptoparams');
    this.pushTable('remotehosts');
    this.pushTable('rdpcredentials');
    this.pushTable('rustdeskrelays');
    this.pushTable('sshkeys');
    this.pushTable('totpentries');
    if (includeVncReset) { this.pushVncResetTable(); }
    else { this.pushTable(VNC_CLOUD_TABLE); }
  }

  /**
   * Decrypts every sensitive row, clears KDF material and commits the disabled
   * status in one transaction. A caller may clear the in-memory DEK only after
   * this method returns a non-negative count.
   */
  async disableCryptoV3(
    crypto: DataCrypto,
    lease: AccountSessionLease | null
  ): Promise<number> {
    if (!(await this.beginExclusiveCryptoLifecycle(lease))) {
      return -1;
    }
    try {
      return this.disableCryptoV3Exclusive(crypto, lease);
    } finally {
      if (!this.endExclusiveCryptoLifecycle(lease)) {
        hilog.error(0x0001, 'CloudSync',
          '[disableCryptoV3] 同步门闩恢复失败并保持关闭');
      }
    }
  }

  private disableCryptoV3Exclusive(
    crypto: DataCrypto,
    lease: AccountSessionLease | null
  ): number {
    if (!this.cryptoLifecycleMutationAllowed(lease) || !this.store ||
      !crypto.isReady() ||
      !this.cryptoLeaseIsCurrent(lease) ||
      this.cryptoLifecycleState === null ||
      !cryptoLifecycleCanDisable(this.cryptoLifecycleState)) {
      return -1;
    }
    const selectionSnapshot: CryptoCloudSelectionSnapshot | null =
      this.pauseCloudSelectionForLocalCryptoTransition(false);
    if (selectionSnapshot === null) { return -1; }
    const transactionId: string =
      this.nextCryptoTransactionId('disable');
    const disablingState: CryptoLifecycleDurableState =
      cryptoLifecycleOperationStarted(
        this.cryptoLifecycleState, 'disabling', transactionId);
    if (!this.persistCryptoLifecycleState(disablingState)) {
      this.restoreCloudSelectionAfterFailedCryptoTransition(
        selectionSnapshot);
      return -1;
    }
    this.cryptoLifecycleState = disablingState;
    let count: number = -1;
    try {
      this.store.beginTransaction();
      count = this.decryptAllData(crypto, false, false, lease);
      this.clearCryptoSecretsInActiveTransaction();
      if (!rdbInsertSucceeded(this.store.insertSync(
        'cryptoparams',
        this.cryptoParamBucket('crypto_status', 'disabled'),
        relationalStore.ConflictResolution.ON_CONFLICT_REPLACE))) {
        throw new Error('crypto disabled status write failed');
      }
      if (!this.recordTableMutation(
        'cryptoparams', 'disable_v3')) {
        throw new Error('crypto disable journal failed');
      }
      const committed: CryptoCommittedState = {
        status: 'disabled',
        configured: false,
        kdfVersion: 0,
        kdfIterations: 0,
        keyVersion: 0,
        verifierVersion: 0,
        envelopeVersion: 0
      };
      const disabledState: CryptoLifecycleDurableState =
        cryptoLifecycleOperationCommitted(
          disablingState, 'disabled', committed);
      if (!this.persistCryptoLifecycleState(disabledState)) {
        throw new Error('crypto disable lifecycle commit failed');
      }
      this.store.commit();
      this.cryptoLifecycleState = disabledState;
      this.lastKnownCryptoStatus = 'disabled';
    } catch (err) {
      try { this.store.rollBack(); } catch (_rollbackError) {}
      this.abortCryptoLifecycle(
        transactionId, lease, safeError(err));
      hilog.error(0x0001, 'CloudSync',
        '[disableCryptoV3] 全量回滚: ' + safeError(err));
      this.restoreCloudSelectionAfterFailedCryptoTransition(
        selectionSnapshot);
      return -1;
    }
    this.pushCryptoTransitionTables(false);
    return count;
  }

  /**
   * Local forgotten-password reset. Account rows, local-only extensions,
   * deletion intents, reset epoch and KDF material commit together. It is
   * deliberately not a remote wipe protocol.
   */
  async resetCryptoV3(
    lease: AccountSessionLease | null
  ): Promise<boolean> {
    if (!(await this.beginExclusiveCryptoLifecycle(lease))) {
      return false;
    }
    try {
      return this.resetCryptoV3Exclusive(lease);
    } finally {
      if (!this.endExclusiveCryptoLifecycle(lease)) {
        hilog.error(0x0001, 'CloudSync',
          '[resetCryptoV3] 同步门闩恢复失败并保持关闭');
      }
    }
  }

  private resetCryptoV3Exclusive(
    lease: AccountSessionLease | null
  ): boolean {
    if (!this.cryptoLifecycleMutationAllowed(lease) || !this.store ||
      !this.cryptoLeaseIsCurrent(lease) ||
      this.cryptoLifecycleState === null ||
      !cryptoLifecycleCanReset(this.cryptoLifecycleState)) {
      return false;
    }
    const selectionSnapshot: CryptoCloudSelectionSnapshot | null =
      this.pauseCloudSelectionForLocalCryptoTransition(true);
    if (selectionSnapshot === null) { return false; }
    const transactionId: string =
      this.nextCryptoTransactionId('reset');
    const resetPending: CryptoLifecycleDurableState =
      cryptoLifecycleOperationStarted(
        this.cryptoLifecycleState, 'reset_pending', transactionId);
    if (!this.persistCryptoLifecycleState(resetPending)) {
      this.restoreCloudSelectionAfterFailedCryptoTransition(
        selectionSnapshot);
      return false;
    }
    this.cryptoLifecycleState = resetPending;
    try {
      const nextEpoch: number = this.readVncResetEpoch() + 1;
      const tables: string[] = this.sensitiveBusinessTables();
      this.store.beginTransaction();
      this.clearAllTablesInActiveTransaction(tables);
      this.clearCryptoSecretsInActiveTransaction();
      if (!rdbInsertSucceeded(this.store.insertSync(
        'cryptoparams',
        this.cryptoParamBucket(
          VNC_RESET_EPOCH_KEY, nextEpoch.toString()),
        relationalStore.ConflictResolution.ON_CONFLICT_REPLACE)) ||
        !rdbInsertSucceeded(this.store.insertSync(
          'cryptoparams',
          this.cryptoParamBucket('crypto_status', 'disabled'),
          relationalStore.ConflictResolution.ON_CONFLICT_REPLACE))) {
        throw new Error('crypto reset marker write failed');
      }
      if (!this.recordTableMutation(
        'cryptoparams', 'reset_local_v3')) {
        throw new Error('crypto reset journal failed');
      }
      const committed: CryptoCommittedState = {
        status: 'disabled',
        configured: false,
        kdfVersion: 0,
        kdfIterations: 0,
        keyVersion: 0,
        verifierVersion: 0,
        envelopeVersion: 0
      };
      const resetState: CryptoLifecycleDurableState =
        cryptoLifecycleOperationCommitted(
          resetPending, 'reset_committed', committed);
      if (!this.persistCryptoLifecycleState(resetState)) {
        throw new Error('crypto reset lifecycle commit failed');
      }
      this.store.commit();
      this.cryptoLifecycleState = resetState;
      this.lastKnownCryptoStatus = 'disabled';
    } catch (err) {
      try { this.store.rollBack(); } catch (_rollbackError) {}
      this.abortCryptoLifecycle(
        transactionId, lease, safeError(err));
      hilog.error(0x0001, 'CloudSync',
        '[resetCryptoV3] 全量回滚: ' + safeError(err));
      this.restoreCloudSelectionAfterFailedCryptoTransition(
        selectionSnapshot);
      return false;
    }
    DataCrypto.getInstance().lock();
    this.notifyCryptoReset();
    this.notifyDataSnapshotChanged();
    this.pushCryptoTransitionTables(true);
    return true;
  }

  /** 检测加密状态变更并执行对应的本地联动操作 (跨设备同步) */
  checkCryptoStatusChange(_allowRemoteReset: boolean = false): boolean {
    const newStatus: string = this.getCryptoStatus();
    if (newStatus === '' || newStatus === this.lastKnownCryptoStatus) {
      return false;
    }
    hilog.info(0x0001, 'CloudSync',
      "[checkCryptoStatusChange] " + this.lastKnownCryptoStatus + " → " + newStatus);
    this.lastKnownCryptoStatus = newStatus;
    if (this.currentLease !== null &&
      this.cryptoLifecycleState !== null) {
      const recovered: CryptoLifecycleDurableState =
        recoverCryptoLifecycleDurableState(
          this.cryptoLifecycleState,
          this.currentLease,
          this.committedCryptoState());
      if (this.persistCryptoLifecycleState(recovered)) {
        this.cryptoLifecycleState = recovered;
      }
    }
    if (newStatus === 'reset' ||
      newStatus === 'disabled' ||
      newStatus === 'configuring') {
      DataCrypto.getInstance().lock();
      hilog.warn(0x0001, 'CloudSync',
        '[checkCryptoStatusChange] 未验证的远端加密生命周期信令已隔离；本地数据保持不变');
      return false;
    }
    return false;
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
    if (!this.recordOwnerWriteAllowed(host.userId)) { return false; }
    host.userId = this.currentOwnerScopeId();
    return this.runRawMigrationMutation('remotehosts', host.id, 'crypto_encrypt',
      (): boolean => this.updateHostInternal(host, false));
  }

  updateRdpCredentialRaw(credential: RdpCredential): boolean {
    if (!this.recordOwnerWriteAllowed(credential.userId)) { return false; }
    credential.userId = this.currentOwnerScopeId();
    return this.runRawMigrationMutation('rdpcredentials', credential.id, 'crypto_encrypt',
      (): boolean => this.updateRdpCredentialInternal(credential, false));
  }

  upsertRelayLocalRaw(relay: RustDeskRelayConfig): boolean {
    if (!this.recordOwnerWriteAllowed(relay.userId)) { return false; }
    relay.userId = this.currentOwnerScopeId();
    return this.runRawMigrationMutation('rustdeskrelays', relay.id, 'crypto_encrypt',
      (): boolean => this.upsertRelayLocalInternal(relay, false));
  }

  updateSshKeyRaw(key: SshKey): boolean {
    if (!this.recordOwnerWriteAllowed(key.userId)) { return false; }
    key.userId = this.currentOwnerScopeId();
    return this.runRawMigrationMutation('sshkeys', key.id, 'crypto_encrypt',
      (): boolean => this.updateSshKeyInternal(key, false));
  }

  updateTotpEntryRaw(entry: TotpEntry): boolean {
    if (!this.recordOwnerWriteAllowed(entry.userId)) { return false; }
    entry.userId = this.currentOwnerScopeId();
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
    if (!this.recordOwnerWriteAllowed(host.userId)) {
      return this.setLastMutation(DataMutationResult.failure(
        host.id, 'invalid_data', '主机属于其他账号，已拒绝保存'));
    }
    host.userId = this.currentOwnerScopeId();
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
    if (!this.recordOwnerWriteAllowed(host.userId)) {
      return this.setLastMutation(DataMutationResult.failure(
        host.id, 'invalid_data', '主机属于其他账号，已拒绝更新'));
    }
    host.userId = this.currentOwnerScopeId();
    if (!this.sensitiveWriteAllowed(host.id)) { return false; }
    let code = 'local_write_failed';
    try {
      this.store.beginTransaction();
      const vb = this.hostToBucket(host);
      vb['updatedat'] = Date.now();
      const predicates = new relationalStore.RdbPredicates('remotehosts');
      predicates.equalTo('id', host.id);
      this.addCurrentOwnerPredicate(predicates);
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
      this.addCurrentOwnerPredicate(predicates);
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
      predicates.equalTo('userid', this.currentScopeToken.ownerScopeId);
      const rs = this.store.querySync(predicates);
      while (rs.goToNextRow()) {
        const credential: RdpCredential = decrypt ? this.rowToRdpCredential(rs) : this.rowToRdpCredentialRaw(rs);
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
    if (!this.recordOwnerWriteAllowed(credential.userId)) {
      return this.setLastMutation(DataMutationResult.failure(
        credential.id, 'invalid_data', 'Windows 凭据属于其他账号，已拒绝保存'));
    }
    credential.userId = this.currentOwnerScopeId();
    if (!this.sensitiveWriteAllowed(credential.id)) { return false; }
    let code = 'local_write_failed';
    try {
      this.store.beginTransaction();
      const vb = this.rdpCredentialToBucket(credential);
      vb['updatedat'] = Date.now();
      if (!rdbInsertSucceeded(this.store.insertSync('rdpcredentials', vb, relationalStore.ConflictResolution.ON_CONFLICT_REPLACE))) {
        code = 'local_write_failed'; throw new Error('rdp credential insert failed');
      }
      if (!this.deleteLocalExtension('rdpcredentials', credential.id)) {
        code = 'extension_write_failed'; throw new Error('rdp credential extension cleanup failed');
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
    if (!this.recordOwnerWriteAllowed(credential.userId)) {
      return this.setLastMutation(DataMutationResult.failure(
        credential.id, 'invalid_data', 'Windows 凭据属于其他账号，已拒绝更新'));
    }
    credential.userId = this.currentOwnerScopeId();
    if (!this.sensitiveWriteAllowed(credential.id)) { return false; }
    let code = 'local_write_failed';
    try {
      this.store.beginTransaction();
      const vb = this.rdpCredentialToBucket(credential);
      vb['updatedat'] = Date.now();
      const predicates = new relationalStore.RdbPredicates('rdpcredentials');
      predicates.equalTo('id', credential.id);
      this.addCurrentOwnerPredicate(predicates);
      if (!rdbSingleRowAffected(this.store.updateSync(vb, predicates))) { code = 'not_found'; throw new Error('rdp credential update failed'); }
      if (!this.deleteLocalExtension('rdpcredentials', credential.id)) {
        code = 'extension_write_failed'; throw new Error('rdp credential extension cleanup failed');
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
      this.addCurrentOwnerPredicate(predicates);
      const updated: boolean = rdbSingleRowAffected(this.store.updateSync(vb, predicates));
      if (!updated) { return false; }
      return this.deleteLocalExtension('rdpcredentials', credential.id);
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
      this.addCurrentOwnerPredicate(predicates);
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
  rustDeskRelayCloudSyncInitialState(): RustDeskRelayCloudSyncState {
    return this.isCloudAvailable() &&
      this.syncableTables().indexOf('rustdeskrelays') >= 0
      ? 'pending' : 'not_configured';
  }

  async syncRelaysToCloudAsync(): Promise<RustDeskRelayCloudSyncOutcome> {
    const outcome = new RustDeskRelayCloudSyncOutcome();
    outcome.state = this.rustDeskRelayCloudSyncInitialState();
    if (outcome.state === 'not_configured') { return outcome; }
    try {
      const result: CloudSyncOperationResult =
        await CloudSyncCoordinator.getInstance()
          .requestAutomaticPush('rustdeskrelays');
      if (!result.ok) {
        outcome.state = 'failed';
        outcome.failureKind = result.failureKind;
      } else if (result.tables.indexOf('rustdeskrelays') >= 0) {
        outcome.state = 'completed';
      } else {
        // Deferred/coalesced work remains represented by the durable local
        // mutation journal and must not be called completed.
        outcome.state = 'pending';
      }
    } catch (_err) {
      outcome.state = 'failed';
      outcome.failureKind = 'unknown';
    }
    return outcome;
  }

  syncRelaysToCloud(): void {
    void this.syncRelaysToCloudAsync();
  }

  /**
   * Compatibility read. Production migration is executed only during account
   * store initialization or after a complete cloud-first apply.
   */
  syncRelaysFromCloud(): RustDeskRelayConfig[] {
    return this.loadAllRelaysLocal();
  }

  // ==================== RustDesk Relay CRUD (本地) ====================

  /**
   * Converts the retired whole-table JSON container without overwriting rows
   * already owned by the current independent relay table. The source value is
   * retained; malformed data receives only a hash and redacted quarantine
   * record so secrets are not duplicated into diagnostics.
   */
  private migrateLegacyRelayJson(): number {
    if (!this.store ||
      this.readLocalMetadataStrict(
        LEGACY_RELAY_JSON_MIGRATION_KEY) === '1') {
      return 0;
    }
    const predicates =
      new relationalStore.RdbPredicates('cryptoparams');
    predicates.equalTo(
      'id', this.cryptoParamId('rustdesk_relays'));
    predicates.equalTo('key', 'rustdesk_relays');
    const rows: relationalStore.ResultSet =
      this.store.querySync(predicates);
    const found: boolean = rows.goToFirstRow();
    const raw: string = found
      ? rows.getString(rows.getColumnIndex('value')) : '';
    rows.close();
    // Do not mark an absent source as complete. A new device can receive the
    // legacy row only after its first cloud-first cryptoparams transfer.
    if (!found) { return 0; }
    const legacyRows: RustDeskRelayJSON[] | null =
      parseLegacyRelayJson(raw);
    if (legacyRows === null) {
      this.quarantineLegacyRelayJson(raw);
      return -1;
    }
    let migrated: number = 0;
    try {
      this.store.beginTransaction();
      for (let i = 0; i < legacyRows.length; i++) {
        const legacy: RustDeskRelayConfig =
          RustDeskRelayConfig.fromJSON(legacyRows[i]);
        legacy.userId = this.currentOwnerScopeId();
        const existingPredicates =
          new relationalStore.RdbPredicates('rustdeskrelays');
        existingPredicates.equalTo('id', legacy.id);
        this.addCurrentOwnerPredicate(existingPredicates);
        const existing: relationalStore.ResultSet =
          this.store.querySync(existingPredicates);
        const exists: boolean = existing.goToFirstRow();
        existing.close();
        if (exists) { continue; }
        const bucket: relationalStore.ValuesBucket =
          this.relayToBucketRaw(legacy);
        bucket['createdat'] =
          legacy.createdAt > 0 ? legacy.createdAt : Date.now();
        bucket['updatedat'] =
          legacy.updatedAt > 0 ? legacy.updatedAt : Date.now();
        if (!rdbInsertSucceeded(
          this.store.insertSync('rustdeskrelays', bucket))) {
          throw new Error('legacy relay insert failed');
        }
        migrated++;
      }
      if (migrated > 0 &&
        !this.recordTableMutation(
          'rustdeskrelays', 'legacy_json_migration')) {
        throw new Error('legacy relay journal failed');
      }
      if (!this.writeLocalMetadata(
        LEGACY_RELAY_JSON_MIGRATION_KEY, '1')) {
        throw new Error('legacy relay marker failed');
      }
      this.store.commit();
      return migrated;
    } catch (err) {
      try { this.store.rollBack(); } catch (_rollbackError) {}
      this.quarantineLegacyRelayJson(raw);
      hilog.error(0x0001, 'CloudSync',
        '[migrateLegacyRelayJson] 已回滚并隔离: ' + safeError(err));
      return -1;
    }
  }

  private quarantineLegacyRelayJson(raw: string): void {
    if (!this.store) { return; }
    try {
      const bucket: relationalStore.ValuesBucket = {
        id: LEGACY_RELAY_JSON_MIGRATION_ID + ':' +
          this.currentOwnerScopeId(),
        migrationid: LEGACY_RELAY_JSON_MIGRATION_ID,
        tablename: 'cryptoparams',
        recordid: 'rustdesk_relays',
        reason: 'invalid_legacy_relay_json',
        payloadhashsha256: vncPayloadHashSha256(raw),
        payloadciphertext: '',
        redactedsummary:
          'Legacy relay data remains in cryptoparams and requires repair',
        createdat: Date.now()
      };
      this.store.insertSync(
        MIGRATION_QUARANTINE_TABLE, bucket,
        relationalStore.ConflictResolution.ON_CONFLICT_REPLACE);
    } catch (_e) {
      hilog.error(0x0001, 'CloudSync',
        '[migrateLegacyRelayJson] 隔离记录写入失败');
    }
  }

  private relayAccountsToJson(relay: RustDeskRelayConfig): string {
    const crypto = DataCrypto.getInstance();
    const items: RustDeskAccountJSON[] = [];
    for (let i = 0; i < relay.accounts.length; i++) {
      const item: RustDeskAccountJSON = relay.accounts[i].toJSON();
      if (item.password !== '') {
        item.password = this.encryptIfReady(
          crypto, 'rustdeskrelays', relay.id,
          'accounts/' + item.id + '/password', item.password);
      }
      items.push(item);
    }
    return JSON.stringify(items);
  }

  private relayAccountsFromJson(json: string, relayId: string): RustDeskAccount[] {
    const accounts: RustDeskAccount[] = [];
    if (json === '') { return accounts; }
    try {
      const crypto = DataCrypto.getInstance();
      const parsed: RustDeskAccountJSON[] = JSON.parse(json) as RustDeskAccountJSON[];
      for (let i = 0; i < parsed.length; i++) {
        const account: RustDeskAccount = RustDeskAccount.fromJSON(parsed[i]);
        if (account.password !== '') {
          account.password = this.decryptIfReady(
            crypto, 'rustdeskrelays', relayId,
            'accounts/' + account.id + '/password', account.password);
        }
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
    vb['userid'] = this.currentOwnerScopeId();
    vb['idserver'] = relay.idServer;
    vb['idserverport'] = relay.idServerPort;
    vb['relayserver'] = relay.relayServer;
    vb['relayport'] = relay.relayPort;
    vb['apiserver'] = relay.apiServer;
    vb['apiusername'] = relay.apiUsername;
    vb['apipassword'] = this.encryptIfReady(
      crypto, 'rustdeskrelays', relay.id, 'apipassword', relay.apiPassword);
    vb['key'] = this.encryptIfReady(
      crypto, 'rustdeskrelays', relay.id, 'key',
      rustDeskRelayKeyForStorage(relay.key, relay.keyMode));
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
    vb['userid'] = this.currentOwnerScopeId();
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

  private rustDeskRelayPersistencePort(
    relay: RustDeskRelayConfig
  ): RustDeskRelayPersistencePort {
    return {
      beginTransaction: (): void => {
        if (!this.store) { throw new Error('relay store unavailable'); }
        this.store.beginTransaction();
      },
      upsertRelay: (): boolean =>
        this.upsertRelayLocalInternal(relay, true),
      writeControlPlaneProfile: (): boolean =>
        this.writeRustDeskRelayControlPlaneProfile(relay),
      recordMutationJournal: (): boolean =>
        this.recordLocalMutation(
          'rustdeskrelays', relay.id, 'upsert'),
      commit: (): void => {
        if (!this.store) { throw new Error('relay store unavailable'); }
        this.store.commit();
      },
      rollback: (): void => {
        if (!this.store) { throw new Error('relay store unavailable'); }
        this.store.rollBack();
      },
      readback: (): RustDeskRelayConfig | null =>
        this.loadRelayById(relay.id)
    };
  }

  private commitRelayPersistenceResult(
    relay: RustDeskRelayConfig,
    attemptId: string
  ): DataMutationResult {
    const relayFingerprint: string = rustDeskRelayIdFingerprint(relay.id);
    hilog.info(0x0001, 'RustDeskSave', 'attempt=' + attemptId + ' relay=' +
      relayFingerprint + ' stage=waiting_gate');
    const storeReady: boolean = this.store !== null;
    const mutationAllowed: boolean =
      storeReady && this.localMutationAllowed();
    const ownerAllowed: boolean = mutationAllowed &&
      this.recordOwnerWriteAllowed(relay.userId);
    const sensitiveAllowed: boolean = ownerAllowed &&
      this.sensitiveWriteAllowed(relay.id);
    const gate: RustDeskRelayPersistenceGate = {
      storeReady,
      localMutationAllowed: mutationAllowed,
      ownerAllowed,
      sensitiveWriteAllowed: sensitiveAllowed,
      sensitiveFailure: sensitiveAllowed
        ? null : this.getLastMutationResult()
    };
    const blocked: DataMutationResult | null =
      rustDeskRelayPersistenceGateResult(relay.id, gate);
    if (blocked !== null) {
      this.setLastMutation(blocked);
      return this.getLastMutationResult();
    }
    relay.userId = this.currentOwnerScopeId();
    hilog.info(0x0001, 'RustDeskSave', 'attempt=' + attemptId +
      ' relay=' + relayFingerprint + ' stage=committing');
    const result: DataMutationResult =
      commitRustDeskRelayPersistence(
        relay, this.rustDeskRelayPersistencePort(relay));
    if (!result.ok) {
      hilog.error(0x0001, 'RustDeskSave', 'attempt=' + attemptId + ' relay=' +
        relayFingerprint + ' stage=committing code=' +
        result.code + ' committed=false rolled_back=true');
      this.setLastMutation(result);
      return this.getLastMutationResult();
    }
    this.setLastMutation(result);
    return this.getLastMutationResult();
  }

  private verifyRelayPersistenceResult(
    relay: RustDeskRelayConfig,
    attemptId: string
  ): DataMutationResult {
    const relayFingerprint: string =
      rustDeskRelayIdFingerprint(relay.id);
    hilog.info(0x0001, 'RustDeskSave', 'attempt=' + attemptId + ' relay=' +
      relayFingerprint + ' stage=verifying');
    const result: DataMutationResult =
      verifyRustDeskRelayPersistence(
        relay, this.rustDeskRelayPersistencePort(relay));
    this.setLastMutation(result);
    if (!result.ok) {
      hilog.error(0x0001, 'RustDeskSave', 'attempt=' + attemptId + ' relay=' +
        relayFingerprint + ' stage=verifying code=' +
        result.code + ' committed=true');
      return this.getLastMutationResult();
    }
    hilog.info(0x0001, 'RustDeskSave', 'attempt=' + attemptId + ' relay=' +
      relayFingerprint + ' stage=completed code=ok committed=true');
    return this.getLastMutationResult();
  }

  upsertRelayResult(
    relay: RustDeskRelayConfig,
    attemptId: string = ''
  ): DataMutationResult {
    const committed: DataMutationResult =
      this.commitRelayPersistenceResult(relay, attemptId);
    return committed.ok
      ? this.verifyRelayPersistenceResult(relay, attemptId)
      : committed;
  }

  async upsertRelayResultAsync(
    relay: RustDeskRelayConfig,
    attemptId: string = '',
    onStage: ((stage: DataMutationStage) => void) | null = null
  ): Promise<DataMutationResult> {
    if (onStage !== null) { onStage('waiting_gate'); }
    await new Promise<void>((resolve: () => void): void => {
      setTimeout(resolve, 0);
    });
    if (onStage !== null) { onStage('committing'); }
    await new Promise<void>((resolve: () => void): void => {
      setTimeout(resolve, 0);
    });
    const committed: DataMutationResult =
      this.commitRelayPersistenceResult(relay, attemptId);
    if (!committed.ok) { return committed; }
    if (onStage !== null) { onStage('verifying'); }
    await new Promise<void>((resolve: () => void): void => {
      setTimeout(resolve, 0);
    });
    return this.verifyRelayPersistenceResult(relay, attemptId);
  }

  upsertRelay(relay: RustDeskRelayConfig): boolean {
    const result: DataMutationResult =
      this.upsertRelayResult(relay);
    if (result.ok) { this.syncRelaysToCloud(); }
    return result.ok;
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
      this.addCurrentOwnerPredicate(predicates);
      if (!rdbSingleRowAffected(this.store.deleteSync(predicates))) { code = 'not_found'; throw new Error('relay delete failed'); }
      if (!this.deleteRustDeskRelayControlPlaneProfile(id)) {
        code = 'metadata_write_failed'; throw new Error('relay profile metadata delete failed');
      }
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
        'not_found' | 'metadata_write_failed' | 'journal_write_failed', 'RustDesk 中继删除未完成'));
    }
  }

  loadAllRelays(): RustDeskRelayConfig[] {
    // 分布式表已完成端云合并；读取时绝不再把旧 JSON 反向写回云端。
    return this.loadAllRelaysLocal();
  }

  private relayFromCurrentRow(
    rows: relationalStore.ResultSet,
    decrypt: boolean
  ): RustDeskRelayConfig {
    const crypto = DataCrypto.getInstance();
    const relay = new RustDeskRelayConfig();
    relay.id = rows.getString(rows.getColumnIndex('id'));
    relay.userId = rows.getString(
      rows.getColumnIndex('userid'));
    relay.idServer = rows.getString(
      rows.getColumnIndex('idserver'));
    relay.idServerPort = rows.getLong(
      rows.getColumnIndex('idserverport'));
    relay.relayServer = rows.getString(
      rows.getColumnIndex('relayserver'));
    relay.relayPort = rows.getLong(
      rows.getColumnIndex('relayport'));
    relay.apiServer = rows.getString(
      rows.getColumnIndex('apiserver'));
    relay.apiUsername = rows.getString(
      rows.getColumnIndex('apiusername'));
    const apiPassword: string = rows.getString(
      rows.getColumnIndex('apipassword'));
    const key: string = rows.getString(
      rows.getColumnIndex('key'));
    relay.apiPassword = decrypt ? this.decryptIfReady(
      crypto, 'rustdeskrelays', relay.id,
      'apipassword', apiPassword) : apiPassword;
    if (decrypt) {
      const storedKey = rustDeskRelayKeyFromStorage(
        this.decryptIfReady(
          crypto, 'rustdeskrelays', relay.id, 'key', key));
      relay.key = storedKey.key;
      relay.keyMode = storedKey.mode;
    } else {
      relay.key = key;
    }
    relay.healthStatus = rows.getString(
      rows.getColumnIndex('healthstatus'));
    relay.healthLatency = rows.getLong(
      rows.getColumnIndex('healthlatency'));
    relay.healthCheckedAt = rows.getLong(
      rows.getColumnIndex('healthcheckedat'));
    relay.apiLoginStatus = rows.getString(
      rows.getColumnIndex('apiloginstatus'));
    const accountsColumn: number =
      rows.getColumnIndex('accountsjson');
    if (accountsColumn >= 0) {
      relay.accounts = decrypt
        ? this.relayAccountsFromJson(
          rows.getString(accountsColumn), relay.id)
        : this.relayAccountsFromJsonRaw(
          rows.getString(accountsColumn));
    }
    relay.controlPlaneProfile =
      this.readRustDeskRelayControlPlaneProfile(relay.id);
    relay.syncVersion = rows.getLong(
      rows.getColumnIndex('syncversion'));
    relay.createdAt = rows.getLong(
      rows.getColumnIndex('createdat'));
    const updatedAtColumn: number =
      rows.getColumnIndex('updatedat');
    relay.updatedAt = updatedAtColumn >= 0
      ? rows.getLong(updatedAtColumn) : 0;
    return relay;
  }

  loadRelayById(id: string): RustDeskRelayConfig | null {
    const normalized: string = id.trim();
    if (!this.store || normalized === '') { return null; }
    let rows: relationalStore.ResultSet | null = null;
    try {
      const predicates =
        new relationalStore.RdbPredicates('rustdeskrelays');
      predicates.equalTo('id', normalized);
      this.addCurrentOwnerPredicate(predicates);
      rows = this.store.querySync(predicates);
      if (!rows.goToFirstRow()) { return null; }
      return this.relayFromCurrentRow(rows, true);
    } catch (err) {
      hilog.error(0x0001, 'RustDeskSave',
        'stable-id readback failed relay=' +
        rustDeskRelayIdFingerprint(normalized) +
        ' error=' + safeError(err));
      return null;
    } finally {
      if (rows !== null) { rows.close(); }
    }
  }

  // ---- 本地 CRUD (不触发云同步, 供内部和 sync 方法使用) ----

  upsertRelayLocal(relay: RustDeskRelayConfig): boolean {
    if (!this.localMutationAllowed()) { return false; }
    if (!this.recordOwnerWriteAllowed(relay.userId)) { return false; }
    relay.userId = this.currentOwnerScopeId();
    return this.upsertRelayLocalInternal(relay, true);
  }

  private upsertRelayLocalInternal(relay: RustDeskRelayConfig, encrypt: boolean): boolean {
    if (!this.store) { return false; }
    if (!this.recordOwnerWriteAllowed(relay.userId)) { return false; }
    relay.userId = this.currentOwnerScopeId();
    try {
      const updatedAt: number = Date.now();
      relay.updatedAt = updatedAt;
      const vb = encrypt ? this.relayToBucket(relay) : this.relayToBucketRaw(relay);
      vb['updatedat'] = updatedAt;
      const predicates = new relationalStore.RdbPredicates('rustdeskrelays');
      predicates.equalTo('id', relay.id);
      this.addCurrentOwnerPredicate(predicates);
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
      this.addCurrentOwnerPredicate(predicates);
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
    let rows: relationalStore.ResultSet | null = null;
    try {
      const predicates = new relationalStore.RdbPredicates('rustdeskrelays');
      this.addCurrentOwnerPredicate(predicates);
      rows = this.store.querySync(predicates);
      while (rows.goToNextRow()) {
        result.push(
          this.relayFromCurrentRow(rows, decrypt));
      }
    } catch (err) {
      hilog.error(0x0001, 'CloudSync', '[CloudStore] loadAllRelays 失败: ' + JSON.stringify(err));
    } finally {
      if (rows !== null) { rows.close(); }
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
    vb['userid'] = this.currentOwnerScopeId();
    vb['label'] = h.label;
    vb['protocol'] = h.protocol;
    vb['host'] = h.host;
    vb['port'] = h.port;
    vb['username'] = h.username;
    // `passward` is the immutable existing cloud contract. `password` is a
    // retired local shadow and must never be populated again.
    vb['passward'] = this.encryptIfReady(
      crypto, 'remotehosts', h.id, 'passward', h.password);
    vb['customhostname'] = h.customHostname;
    vb['sshusekey'] = h.sshUseKey ? 1 : 0;
    vb['sshkeypath'] = h.sshKeyPath;
    vb['sshkeydata'] = this.encryptIfReady(
      crypto, 'remotehosts', h.id, 'sshkeydata', h.sshKeyData);
    vb['sshkeypassphrase'] = this.encryptIfReady(
      crypto, 'remotehosts', h.id, 'sshkeypassphrase', h.sshKeyPassphrase);
    vb['sshkeyid'] = h.sshKeyId;
    const clearedTrust: relationalStore.ValuesBucket =
      this.clearedRemoteHostDeviceTrustBucket();
    const clearedTrustKeys: string[] = Object.keys(clearedTrust);
    for (let i = 0; i < clearedTrustKeys.length; i++) {
      vb[clearedTrustKeys[i]] = clearedTrust[clearedTrustKeys[i]];
    }
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
    h.password = this.decryptIfReady(
      crypto, 'remotehosts', h.id, 'passward',
      getStr('passward') || getStr('password'));
    h.customHostname = getStr('customhostname');
    h.sshUseKey = rs.getLong(rs.getColumnIndex('sshusekey')) !== 0;
    h.sshKeyPath = getStr('sshkeypath');
    h.sshKeyData = this.decryptIfReady(
      crypto, 'remotehosts', h.id, 'sshkeydata', getStr('sshkeydata'));
    h.sshKeyPassphrase = this.decryptIfReady(
      crypto, 'remotehosts', h.id, 'sshkeypassphrase',
      getStr('sshkeypassphrase'));
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
    vb['userid'] = this.currentOwnerScopeId();
    vb['label'] = credential.label;
    vb['username'] = credential.username;
    vb['password'] = this.encryptIfReady(
      crypto, 'rdpcredentials', credential.id, 'password',
      credential.password);
    vb['createdat'] = credential.createdAt;
    return this.cloudBucket('rdpcredentials', vb);
  }

  private relayToCloudJson(relay: RustDeskRelayConfig): RustDeskRelayCloudJSON {
    const crypto = DataCrypto.getInstance();
    const json: RustDeskRelayCloudJSON = relay.toCloudJSON();
    json.apiPassword = this.encryptIfReady(
      crypto, 'rustdeskrelays', json.id, 'apipassword', json.apiPassword);
    json.key = this.encryptIfReady(
      crypto, 'rustdeskrelays', json.id, 'key',
      rustDeskRelayKeyForStorage(json.key, relay.keyMode));
    for (let i = 0; i < json.accounts.length; i++) {
      json.accounts[i].password = this.encryptIfReady(
        crypto, 'rustdeskrelays', json.id,
        'accounts/' + json.accounts[i].id + '/password',
        json.accounts[i].password);
    }
    return json;
  }

  private relayFromCloudJson(json: RustDeskRelayCloudJSON): RustDeskRelayConfig {
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
      apiPassword: this.decryptIfReady(
        crypto, 'rustdeskrelays', json.id, 'apipassword', json.apiPassword),
      key: this.decryptIfReady(
        crypto, 'rustdeskrelays', json.id, 'key', json.key),
      keyMode: json.keyMode,
      healthStatus: json.healthStatus,
      healthLatency: json.healthLatency,
      healthCheckedAt: json.healthCheckedAt,
      apiLoginStatus: json.apiLoginStatus,
      accounts: [],
      controlPlaneProfile: this.readRustDeskRelayControlPlaneProfile(json.id),
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
          password: this.decryptIfReady(
            crypto, 'rustdeskrelays', json.id,
            'accounts/' + json.accounts[i].id + '/password',
            json.accounts[i].password),
          loginStatus: json.accounts[i].loginStatus,
          lastLoginAt: json.accounts[i].lastLoginAt,
          createdAt: json.accounts[i].createdAt
        };
        copied.accounts.push(account);
      }
    }
    return RustDeskRelayConfig.fromJSON(copied);
  }

  private encryptIfReady(crypto: DataCrypto, table: string,
    recordId: string, fieldName: string, value: string): string {
    if (value === '') { return value; }
    if (sensitiveWriteRequiresUnlock(crypto.isSetupComplete(), crypto.isReady())) {
      throw new Error('unlock_required');
    }
    return crypto.isReady()
      ? crypto.migrateValueToScopedV3(
        this.currentOwnerScopeId(), table, recordId, fieldName, value,
        this.readVncResetEpoch())
      : value;
  }

  private decryptIfReady(crypto: DataCrypto, table: string,
    recordId: string, fieldName: string, value: string): string {
    if (value === '') { return value; }
    // A locked configured store must never expose ciphertext as though it were
    // usable plaintext. Redact both envelopes and legacy clear values until
    // the user supplies the master password.
    if (shouldRedactLockedCiphertext(crypto.isSetupComplete(), crypto.isReady(), crypto.isEncrypted(value)) ||
      (crypto.isSetupComplete() && !crypto.isReady())) {
      return '';
    }
    return crypto.isReady()
      ? crypto.decryptScopedOrLegacy(
        this.currentOwnerScopeId(), table, recordId, fieldName, value,
        this.readVncResetEpoch())
      : value;
  }

  private rdpCredentialToBucketRaw(credential: RdpCredential): relationalStore.ValuesBucket {
    const vb: relationalStore.ValuesBucket = {};
    vb['id'] = credential.id;
    vb['userid'] = this.currentScopeToken.ownerScopeId;
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
    credential.userId = getStr('userid');
    credential.label = getStr('label');
    credential.username = getStr('username');
    credential.password = this.decryptIfReady(
      crypto, 'rdpcredentials', credential.id, 'password',
      getStr('password'));
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
    credential.userId = getStr('userid');
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
      this.addCurrentOwnerPredicate(predicates);
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
    if (!this.recordOwnerWriteAllowed(key.userId)) {
      return this.setLastMutation(DataMutationResult.failure(
        key.id, 'invalid_data', 'SSH 密钥属于其他账号，已拒绝保存'));
    }
    key.userId = this.currentOwnerScopeId();
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
    if (!this.recordOwnerWriteAllowed(key.userId)) {
      return this.setLastMutation(DataMutationResult.failure(
        key.id, 'invalid_data', 'SSH 密钥属于其他账号，已拒绝更新'));
    }
    key.userId = this.currentOwnerScopeId();
    if (!this.sensitiveWriteAllowed(key.id)) { return false; }
    let code = 'local_write_failed';
    try {
      this.store.beginTransaction();
      const vb = this.sshKeyToBucket(key);
      vb['updatedat'] = Date.now();
      const predicates = new relationalStore.RdbPredicates('sshkeys');
      predicates.equalTo('id', key.id);
      this.addCurrentOwnerPredicate(predicates);
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
      this.addCurrentOwnerPredicate(predicates);
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
    vb['userid'] = this.currentOwnerScopeId();
    vb['label'] = k.label;
    vb['keytype'] = k.keyType;
    vb['publickey'] = k.publicKey;
    vb['privatekey'] = this.encryptIfReady(
      crypto, 'sshkeys', k.id, 'privatekey', k.privateKey);
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
    k.privateKey = this.decryptIfReady(
      crypto, 'sshkeys', k.id, 'privatekey', getStr('privatekey'));
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
      this.addCurrentOwnerPredicate(predicates);
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
      this.addCurrentOwnerPredicate(predicates);
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
      this.addCurrentOwnerPredicate(predicates);
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
    if (!this.recordOwnerWriteAllowed(host.userId)) { return false; }
    host.userId = this.currentOwnerScopeId();
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
      this.addCurrentOwnerPredicate(predicates);
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
    vb['id'] = h.id; vb['userid'] = this.currentOwnerScopeId(); vb['label'] = h.label;
    vb['protocol'] = h.protocol; vb['host'] = h.host; vb['port'] = h.port;
    vb['username'] = h.username; vb['passward'] = h.password;
    vb['customhostname'] = h.customHostname;
    vb['sshusekey'] = h.sshUseKey ? 1 : 0;
    vb['sshkeypath'] = h.sshKeyPath; vb['sshkeydata'] = h.sshKeyData;
    vb['sshkeypassphrase'] = h.sshKeyPassphrase;
    vb['sshkeyid'] = h.sshKeyId;
    const clearedTrust: relationalStore.ValuesBucket =
      this.clearedRemoteHostDeviceTrustBucket();
    const clearedTrustKeys: string[] = Object.keys(clearedTrust);
    for (let i = 0; i < clearedTrustKeys.length; i++) {
      vb[clearedTrustKeys[i]] = clearedTrust[clearedTrustKeys[i]];
    }
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
    if (!this.recordOwnerWriteAllowed(key.userId)) { return false; }
    key.userId = this.currentOwnerScopeId();
    try {
      const vb = encrypt ? this.sshKeyToBucket(key) : this.sshKeyToBucketRaw(key);
      vb['updatedat'] = Date.now();
      const predicates = new relationalStore.RdbPredicates('sshkeys');
      predicates.equalTo('id', key.id);
      this.addCurrentOwnerPredicate(predicates);
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
    vb['id'] = k.id; vb['userid'] = this.currentOwnerScopeId(); vb['label'] = k.label;
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
    if (!this.recordOwnerWriteAllowed(entry.userId)) { return false; }
    entry.userId = this.currentOwnerScopeId();
    try {
      const vb = encrypt ? this.totpToBucket(entry) : this.totpToBucketRaw(entry);
      vb['updatedat'] = Date.now();
      const predicates = new relationalStore.RdbPredicates('totpentries');
      predicates.equalTo('id', entry.id);
      this.addCurrentOwnerPredicate(predicates);
      return rdbSingleRowAffected(this.store.updateSync(vb, predicates));
    } catch (err) {
      hilog.error(0x0006, 'CloudStore', "updateTotpEntry 失败: " + JSON.stringify(err));
      return false;
    }
  }

  private totpToBucketRaw(e: TotpEntry): relationalStore.ValuesBucket {
    const vb: relationalStore.ValuesBucket = {};
    vb['id'] = e.id; vb['userid'] = this.currentOwnerScopeId(); vb['issuer'] = e.issuer;
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
      this.addCurrentOwnerPredicate(predicates);
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
    if (!this.recordOwnerWriteAllowed(entry.userId)) {
      return this.setLastMutation(DataMutationResult.failure(
        entry.id, 'invalid_data', '动态口令属于其他账号，已拒绝保存'));
    }
    entry.userId = this.currentOwnerScopeId();
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
    if (!this.recordOwnerWriteAllowed(entry.userId)) {
      return this.setLastMutation(DataMutationResult.failure(
        entry.id, 'invalid_data', '动态口令属于其他账号，已拒绝更新'));
    }
    entry.userId = this.currentOwnerScopeId();
    if (!this.sensitiveWriteAllowed(entry.id)) { return false; }
    let code = 'local_write_failed';
    try {
      this.store.beginTransaction();
      const vb = this.totpToBucket(entry);
      vb['updatedat'] = Date.now();
      const predicates = new relationalStore.RdbPredicates('totpentries');
      predicates.equalTo('id', entry.id);
      this.addCurrentOwnerPredicate(predicates);
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
      this.addCurrentOwnerPredicate(predicates);
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
    vb['userid'] = this.currentOwnerScopeId();
    vb['issuer'] = e.issuer;
    vb['account'] = e.account;
    vb['secret'] = this.encryptIfReady(
      crypto, 'totpentries', e.id, 'secret', e.secret);
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
    e.secret = this.decryptIfReady(
      crypto, 'totpentries', e.id, 'secret', getStr('secret'));
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

  // ==================== Isolated VNC record domain ====================

  loadAllVncRecordsRaw(includeDeleted: boolean = false): VncRecord[] {
    // DataCrypto migration must inspect both selected and deselected logical
    // scopes. This is a raw owner read, not a runtime projection.
    return this.mergeVncRecords(includeDeleted, this.currentOwnerScopeId(), false);
  }

  loadAllVncLocalRecordsRaw(includeDeleted: boolean = false): VncRecord[] {
    return this.loadVncRecordsFromTable(
      VNC_LOCAL_TABLE, includeDeleted, this.currentOwnerScopeId(), false);
  }

  loadVncRecords(userId: string, includeDeleted: boolean = false): VncRecord[] {
    const normalizedUserId: string = userId.trim();
    if (normalizedUserId !== this.currentOwnerScopeId()) { return []; }
    return this.mergeVncRecords(includeDeleted, normalizedUserId);
  }

  loadVncLocalRecords(userId: string, includeDeleted: boolean = false): VncRecord[] {
    const normalizedUserId: string = userId.trim();
    if (normalizedUserId !== this.currentOwnerScopeId()) { return []; }
    return this.loadVncRecordsFromTable(VNC_LOCAL_TABLE, includeDeleted, normalizedUserId);
  }

  upsertVncRecord(record: VncRecord, localOnly: boolean = false, forceCloud: boolean = false): boolean {
    if (!this.store) { return this.setLastMutation(DataMutationResult.failure(record.id, 'not_ready', '本地数据库未就绪')); }
    if (!this.localMutationAllowed()) {
      return this.setLastMutation(DataMutationResult.failure(record.id, 'restore_in_progress', '恢复进行中，暂不能保存'));
    }
    if (!this.recordOwnerWriteAllowed(record.userId)) {
      return this.setLastMutation(DataMutationResult.failure(
        record.id, 'invalid_data', 'VNC 数据属于其他账号，已拒绝保存'));
    }
    record.userId = this.currentOwnerScopeId();
    if (!this.prepareVncRecordEpoch(record)) {
      return this.setLastMutation(DataMutationResult.failure(record.id, 'invalid_data',
        'VNC 数据属于旧的加密重置 epoch，已拒绝写入'));
    }
    if (!vncRecordIsValid(record)) {
      return this.setLastMutation(DataMutationResult.failure(record.id, 'invalid_data', 'VNC 数据格式无效'));
    }
    if (record.recordType === 'secret' && record.deletedAt <= 0 &&
      !this.sensitiveWriteAllowed(record.id)) { return false; }
    // A VNC row may enter the single cloud table only when its independent
    // logical scope is selected. Crypto readiness controls whether a secret
    // can be materialized or replaced, not whether an opaque row can be
    // mirrored or preserved.
    const physicalTableSelected: boolean =
      this.syncSelection.selectedBusinessTables().indexOf(VNC_CLOUD_TABLE) >= 0;
    const scopeSelected: boolean = this.vncSyncSelection.isRecordTypeSelected(record.recordType);
    const secretAllowed: boolean = record.recordType !== 'secret' ||
      this.vncSyncSelection.secretsAllowed();
    const plainSecret: boolean = record.recordType === 'secret' &&
      record.deletedAt <= 0 &&
      vncSecretStorageModeFromPayload(record.payload) ===
        'plain_explicit_v1';
    // Explicit plaintext consent is device-local. It never authorizes a
    // portable/cloud copy, even when the VNC secret scope is selected.
    const effectiveLocalOnly: boolean = localOnly || plainSecret ||
      this.selectionReenableBlocked(VNC_CLOUD_TABLE) ||
      (!forceCloud &&
      (!physicalTableSelected || !scopeSelected || !secretAllowed));
    let code = 'local_write_failed';
    try {
      this.store.beginTransaction();
      // The device-local row is the canonical VNC overlay. It exists even for
      // records whose cloud mirror is selected, so a locked device or a
      // temporarily disabled scope never loses its local connection data.
      if (!this.upsertVncRecordInternal(record, true)) {
        throw new Error('VNC local record upsert failed');
      }
      if (effectiveLocalOnly) {
        // A disabled scope is a local projection decision, not permission to
        // mutate the shared cloud row. In particular, a device with locked
        // crypto must never turn another device's secret into a cloud
        // tombstone merely because this device cannot project it.
        if (!this.recordLocalMutation(VNC_LOCAL_TABLE, record.id, 'upsert')) {
          code = 'journal_write_failed';
          throw new Error('VNC local record journal failed');
        }
      } else {
        if (!this.upsertVncRecordInternal(record, false)) {
          throw new Error('VNC cloud record upsert failed');
        }
        if (!this.recordLocalMutation(VNC_CLOUD_TABLE, record.id, 'upsert')) {
          code = 'journal_write_failed';
          throw new Error('VNC cloud record journal failed');
        }
      }
      this.store.commit();
      this.setLastMutation(DataMutationResult.success(record.id));
      if (!effectiveLocalOnly) {
        VncCloudSyncService.getInstance().requestAutomaticPush(record.recordType);
      }
      return true;
    } catch (err) {
      try { this.store.rollBack(); } catch (_ignored) {}
      hilog.error(0x0001, 'CloudSync', '[CloudStore] upsertVncRecord failed: ' + safeError(err));
      return this.setLastMutation(DataMutationResult.failure(record.id, code as 'local_write_failed' |
        'journal_write_failed', 'VNC 数据保存未完成'));
    }
  }

  deleteVncRecord(userId: string, id: string, localOnly: boolean = false): boolean {
    if (!this.store) { return this.setLastMutation(DataMutationResult.failure(id, 'not_ready', '本地数据库未就绪')); }
    if (!this.localMutationAllowed()) {
      return this.setLastMutation(DataMutationResult.failure(id, 'restore_in_progress', '恢复进行中，暂不能删除'));
    }
    const owner: string = userId.trim();
    if (owner !== this.currentOwnerScopeId()) {
      return this.setLastMutation(DataMutationResult.failure(
        id, 'invalid_data', 'VNC 数据属于其他账号，已拒绝删除'));
    }
    let merged: VncRecord[] = this.loadVncRecords(owner, true);
    // Explicit secret deletion is an owner operation, not a scope projection.
    // If the current scope hides the row, recover it from the raw VNC owner
    // view so a user can still forget a locked or deselected credential.
    if (merged.every((record: VncRecord): boolean => record.id !== id)) {
      merged = this.mergeVncRecords(true, owner, false);
    }
    let current: VncRecord | null = null;
    for (let i = 0; i < merged.length; i++) {
      if (merged[i].id === id) { current = merged[i]; break; }
    }
    if (current === null) {
      return this.setLastMutation(DataMutationResult.failure(id, 'not_found', 'VNC 数据不存在'));
    }
    // Deletion only writes a metadata tombstone and clears the opaque
    // envelope; it never needs to decrypt the secret, so crypto lock must not
    // make an existing VNC credential impossible to forget.
    const now: number = Date.now();
    current.deletedAt = now;
    current.updatedAt = now;
    current.syncVersion = current.syncVersion + 1;
    if (current.recordType === 'secret') {
      current.ciphertext = '';
      // A tombstone has no secret material. Keep the v2 wire marker so an old
      // client can still observe the deletion after newer clients write v3
      // live envelopes.
      current.envelopeVersion = VNC_LEGACY_SECRET_ENVELOPE_VERSION;
      current.cryptoVersion = VNC_LEGACY_CRYPTO_VERSION;
      current.keyVersion = VNC_LEGACY_KEY_VERSION;
      current.aadVersion = VNC_LEGACY_AAD_VERSION;
      current.payload = '{}';
      current.payloadHashSha256 = vncPayloadHashSha256(current.payload);
    }
    const physicalTableSelected: boolean =
      this.syncSelection.selectedBusinessTables().indexOf(VNC_CLOUD_TABLE) >= 0;
    const cloudSecretExists: boolean = current.recordType === 'secret' && physicalTableSelected &&
      this.findVncRecord(VNC_CLOUD_TABLE, owner, id) !== null;
    return this.upsertVncRecord(current, localOnly, cloudSecretExists);
  }

  /**
   * Roll back a newly-created VNC owner row without manufacturing a user
   * deletion tombstone. This is used only when the host/gateway payload was
   * written first and its companion secret could not be stored. Existing
   * records always use the normal restore path and are never physically
   * removed here.
   */
  discardVncRecordAfterFailedCreate(userId: string, id: string): boolean {
    const owner: string = userId.trim();
    if (!this.store || owner !== this.currentOwnerScopeId() ||
      id.trim() === '') { return false; }
    let cloudDeleted: boolean = false;
    try {
      this.store.beginTransaction();
      const tables: string[] = [VNC_LOCAL_TABLE, VNC_CLOUD_TABLE];
      for (let i = 0; i < tables.length; i++) {
        const table: string = tables[i];
        const predicates = new relationalStore.RdbPredicates(table);
        predicates.equalTo('id', id);
        predicates.equalTo('userid', owner);
        const affected: number = this.store.deleteSync(predicates);
        if (table === VNC_CLOUD_TABLE && affected > 0) { cloudDeleted = true; }
        const journal = new relationalStore.RdbPredicates(LOCAL_MUTATION_JOURNAL_TABLE);
        journal.equalTo('id', this.localExtensionId(table, id));
        this.store.deleteSync(journal);
      }
      if (cloudDeleted && !this.recordLocalMutation(VNC_CLOUD_TABLE, id, 'rollback_delete')) {
        throw new Error('VNC rollback journal failed');
      }
      this.store.commit();
      if (cloudDeleted) { CloudSyncCoordinator.getInstance().requestVncTableAutomaticPush(); }
      return true;
    } catch (err) {
      try { this.store.rollBack(); } catch (_ignored) {}
      hilog.warn(0x0001, 'CloudSync', '[CloudStore] discard VNC create failed: ' + safeError(err));
      return false;
    }
  }

  /** Raw migration entry point used only by DataCrypto; it never decrypts a row. */
  updateVncRecordRaw(record: VncRecord): boolean {
    if (!this.recordOwnerWriteAllowed(record.userId)) { return false; }
    record.userId = this.currentOwnerScopeId();
    const physicalTableSelected: boolean =
      this.syncSelection.selectedBusinessTables().indexOf(VNC_CLOUD_TABLE) >= 0;
    const selected: boolean = this.vncSyncSelection.isRecordTypeSelected(record.recordType);
    const secretAllowed: boolean = record.recordType !== 'secret' ||
      this.vncSyncSelection.secretsAllowed();
    const localOnly: boolean = !physicalTableSelected || !selected || !secretAllowed;
    return this.runRawMigrationMutation(localOnly ? VNC_LOCAL_TABLE : VNC_CLOUD_TABLE, record.id,
      'crypto_encrypt', (): boolean => {
        if (!this.upsertVncRecordInternal(record, true)) { return false; }
        // A migration pass must not turn a hidden cloud-only row into a
        // reverse cloud tombstone. The physical cloud row remains intact and
        // can be projected when this scope is explicitly enabled later.
        if (localOnly) { return true; }
        return this.upsertVncRecordInternal(record, false);
      });
  }

  syncVncRecords(_userId: string): void {
    CloudSyncCoordinator.getInstance().requestAutomaticPush(VNC_CLOUD_TABLE);
  }

  /**
   * Reconcile the single cloud mirror after a VNC logical scope changes.
   * Turning a scope off never deletes the local owner or mutates the shared
   * cloud row. Turning it on promotes the local winner to the same physical
   * `vncrecord` table.
   */
  reconcileVncSyncSelection(
    allowBarrierPromotion: boolean = false
  ): boolean {
    if (!this.store ||
      !cloudSelectionLocalPromotionAllowed(
        allowBarrierPromotion,
        this.localMutationAllowed())) {
      return false;
    }
    const physicalTableSelected: boolean =
      this.syncSelection.selectedBusinessTables().indexOf(VNC_CLOUD_TABLE) >= 0;
    const records: VncRecord[] =
      this.mergeVncRecords(true, this.currentOwnerScopeId(), false);
    let cloudChanged: boolean = false;
    try {
      this.store.beginTransaction();
      for (let i = 0; i < records.length; i++) {
        const record: VncRecord = records[i];
        const selected: boolean = this.vncSyncSelection.isRecordTypeSelected(record.recordType);
        const secretAllowed: boolean = record.recordType !== 'secret' ||
          this.vncSyncSelection.secretsAllowed();
        if (physicalTableSelected && selected &&
          secretAllowed &&
          (allowBarrierPromotion ||
            !this.selectionReenableBlocked(
              VNC_CLOUD_TABLE))) {
          if (!this.upsertVncRecordInternal(record, false)) { throw new Error('VNC promote failed'); }
          if (!this.upsertVncRecordInternal(record, true)) { throw new Error('VNC local mirror failed'); }
          if (!this.recordLocalMutation(VNC_CLOUD_TABLE, record.id, 'scope_promote')) {
            throw new Error('VNC promote journal failed');
          }
          cloudChanged = true;
        } else {
          if (!this.upsertVncRecordInternal(record, true)) { throw new Error('VNC local preserve failed'); }
          // Selection changes only alter this device's projection. Leave the
          // single shared cloud row untouched; a different device may still
          // have the same scope enabled, and an encrypted secret must never
          // be retracted from the cloud by a locked/unselected device.
        }
      }
      this.store.commit();
      if (cloudChanged) { VncCloudSyncService.getInstance().requestAutomaticPush('settings'); }
      return true;
    } catch (err) {
      try { this.store.rollBack(); } catch (_ignored) {}
      hilog.error(0x0001, 'CloudSync', '[CloudStore] reconcile VNC selection failed: ' + safeError(err));
      return false;
    }
  }

  private loadVncRecordsFromTable(table: string, includeDeleted: boolean,
    userId: string = '', applySelection: boolean = true): VncRecord[] {
    const result: VncRecord[] = [];
    if (!this.store) { return result; }
    const currentResetEpoch: number = this.readVncResetEpoch();
    try {
      const predicates = new relationalStore.RdbPredicates(table);
      const normalizedUserId: string =
        userId.trim().length > 0 ? userId.trim() : this.currentOwnerScopeId();
      if (normalizedUserId !== this.currentOwnerScopeId()) { return result; }
      predicates.equalTo('userid', normalizedUserId);
      predicates.orderByDesc('updatedat');
      const rows = this.store.querySync(predicates);
      const deletedFlagIndex: number = rows.getColumnIndex(relationalStore.Field.DELETED_FLAG_FIELD);
      while (rows.goToNextRow()) {
        if (deletedFlagIndex >= 0 && rows.getLong(deletedFlagIndex) === 1) { continue; }
        const record: VncRecord = this.vncRecordFromResult(rows);
        // Do not expose rows from before the latest crypto reset. This is the
        // read-side half of the fail-closed VNC generation boundary.
        if (record.resetEpoch !== currentResetEpoch) { continue; }
        // Validate every cloud row before applying selection projection. This
        // prevents malformed type/owner/scope rows from becoming runtime VNC
        // records even when they happen to use a valid physical-table shape.
        if (!vncRecordIsValid(record)) { continue; }
        if (record.id === '' || (!includeDeleted && record.deletedAt > 0)) { continue; }
        if (table === VNC_CLOUD_TABLE && applySelection) {
          const physicalTableSelected: boolean =
            this.syncSelection.selectedBusinessTables().indexOf(VNC_CLOUD_TABLE) >= 0;
          if (!physicalTableSelected) { continue; }
          const selected: boolean = this.vncSyncSelection.isRecordTypeSelected(record.recordType);
          const secretAllowed: boolean = record.recordType !== 'secret' ||
            this.vncSyncSelection.secretsAllowed();
          if (!selected || !secretAllowed) { continue; }
        }
        result.push(record);
      }
      rows.close();
    } catch (err) {
      hilog.error(0x0001, 'CloudSync', '[CloudStore] load VNC records failed: ' + safeError(err));
    }
    return result;
  }

  /** Merge cloud mirrors with the device-local VNC overlay without exposing
   * a second distributed table. Local-only scopes intentionally win over a
   * stale cloud mirror; selected scopes use the durable version ordering. */
  private mergeVncRecords(includeDeleted: boolean, userId: string = '', applySelection: boolean = true): VncRecord[] {
    const cloudRows: VncRecord[] = this.loadVncRecordsFromTable(VNC_CLOUD_TABLE, true, userId, applySelection);
    const localRows: VncRecord[] = this.loadVncRecordsFromTable(VNC_LOCAL_TABLE, true, userId, applySelection);
    const merged: Map<string, VncRecord> = new Map<string, VncRecord>();
    for (let i = 0; i < cloudRows.length; i++) {
      merged.set(vncRecordIdentity(cloudRows[i].userId, cloudRows[i].id), cloudRows[i]);
    }
    for (let i = 0; i < localRows.length; i++) {
      const local: VncRecord = localRows[i];
      const identity: string = vncRecordIdentity(local.userId, local.id);
      const cloud: VncRecord | undefined = merged.get(identity);
      if (cloud === undefined) {
        merged.set(identity, local);
        continue;
      }
      // A row with the same physical id but a different VNC owner contract
      // is not a merge candidate. Keep the local owner and never let a cloud
      // row rewrite its logical type/owner relationship.
      if (cloud.recordType !== local.recordType || cloud.ownerId !== local.ownerId ||
        cloud.ownerType !== local.ownerType || cloud.secretKind !== local.secretKind) {
        merged.set(identity, local);
        continue;
      }
      // Legacy scope tombstones are distinguished from user deletion. If the
      // local owner is still active, reopening that scope restores the local
      // record instead of treating the legacy marker as a user deletion from
      // another device. New selection transitions leave the cloud row alone.
      if (vncRecordIsScopeTombstone(cloud) && local.deletedAt <= 0) {
        merged.set(identity, local);
        continue;
      }
      const localOnlyScope: boolean = applySelection &&
        !this.vncSyncSelection.isRecordTypeSelected(local.recordType);
      if (localOnlyScope || vncRecordWins(local, cloud)) { merged.set(identity, local); }
    }
    const result: VncRecord[] = [];
    merged.forEach((record: VncRecord): void => {
      if (record.id !== '' && (includeDeleted || record.deletedAt <= 0)) { result.push(record); }
    });
    result.sort((left: VncRecord, right: VncRecord): number => right.updatedAt - left.updatedAt);
    return result;
  }

  private findVncRecord(table: string, userId: string, id: string): VncRecord | null {
    if (!this.store || userId.trim() !== this.currentOwnerScopeId() ||
      id === '') { return null; }
    try {
      const predicates = new relationalStore.RdbPredicates(table);
      predicates.equalTo('id', id);
      predicates.equalTo('userid', userId);
      const rows = this.store.querySync(predicates);
      const candidate: VncRecord | null = rows.goToFirstRow() ? this.vncRecordFromResult(rows) : null;
      rows.close();
      return candidate !== null && candidate.resetEpoch === this.readVncResetEpoch() &&
        vncRecordIsValid(candidate) ? candidate : null;
    } catch (_e) { return null; }
  }

  /** Bind new rows to the current generation and reject stale row rewrites. */
  private prepareVncRecordEpoch(record: VncRecord): boolean {
    const current: number = this.readVncResetEpoch();
    if (record.resetEpoch === current) { return true; }
    if (record.resetEpoch < 0 || record.resetEpoch > current) { return false; }
    // New VNC model instances default to epoch 0. Bind those only when their
    // identity does not already exist as an old local/cloud row; otherwise a
    // stale record could be resurrected under the new generation.
    if (record.resetEpoch === 0 && current > 0 &&
      !this.hasVncRecordAnyEpoch(record.userId, record.id)) {
      record.resetEpoch = current;
      return true;
    }
    return false;
  }

  private hasVncRecordAnyEpoch(userId: string, id: string): boolean {
    if (!this.store || userId.trim() !== this.currentOwnerScopeId() ||
      id.trim() === '') { return false; }
    const tables: string[] = [VNC_LOCAL_TABLE, VNC_CLOUD_TABLE];
    for (let i = 0; i < tables.length; i++) {
      try {
        const predicates = new relationalStore.RdbPredicates(tables[i]);
        predicates.equalTo('id', id);
        predicates.equalTo('userid', userId);
        const rows = this.store.querySync(predicates);
        const found: boolean = rows.goToFirstRow();
        rows.close();
        if (found) { return true; }
      } catch (_e) {
        // A missing/temporarily unavailable mirror must not prevent checking
        // the other VNC owner table; the actual write will report its error.
      }
    }
    return false;
  }

  private upsertVncRecordInternal(record: VncRecord, localOnly: boolean): boolean {
    if (!this.store) { return false; }
    const table: string = localOnly ? VNC_LOCAL_TABLE : VNC_CLOUD_TABLE;
    const bucket: relationalStore.ValuesBucket = this.vncRecordToBucket(record, localOnly);
    return rdbInsertSucceeded(this.store.insertSync(table, bucket,
      relationalStore.ConflictResolution.ON_CONFLICT_REPLACE));
  }

  private vncRecordToBucket(record: VncRecord, localOnly: boolean): relationalStore.ValuesBucket {
    const source: Record<string, string> = vncRecordToCloudRow(record);
    const bucket: relationalStore.ValuesBucket = {};
    for (let i = 0; i < VNC_RECORD_COLUMNS.length; i++) {
      const column: string = VNC_RECORD_COLUMNS[i];
      const value: string = source[column];
      if (['envelopeversion', 'cryptoversion', 'keyversion', 'aadversion', 'syncversion',
        'schemaversion', 'resetepoch', 'createdat', 'updatedat', 'deletedat'].indexOf(column) >= 0) {
        bucket[column] = Number(value);
      } else {
        bucket[column] = value;
      }
    }
    if (localOnly) { bucket['localonly'] = 1; }
    return localOnly ? bucket : this.cloudBucket(VNC_CLOUD_TABLE, bucket);
  }

  private vncRecordFromResult(rows: relationalStore.ResultSet): VncRecord {
    const source: Record<string, string> = {};
    for (let i = 0; i < VNC_RECORD_COLUMNS.length; i++) {
      const column: string = VNC_RECORD_COLUMNS[i];
      const index: number = rows.getColumnIndex(column);
      if (index >= 0 && !rows.isColumnNull(index)) { source[column] = rows.getString(index); }
    }
    return vncRecordFromCloudRow(source);
  }
}
