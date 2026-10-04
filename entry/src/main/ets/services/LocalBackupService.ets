import { AiLifecycle } from './ai/AiLifecycle';
import { AiTransport } from './ai/AiTransport';
import { picker, fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  CloudStore,
  PortableBackupSnapshot
} from './CloudStore';
import { CloudSyncCoordinator } from './CloudSyncCoordinator';
import {
  adaptLocalBackupDocumentForRestore,
  createLocalBackupDocument,
  createLocalBackupRestorePreview,
  LocalBackupDocument,
  LocalBackupValidation,
  localBackupValidationStageCode,
  LOCAL_BACKUP_MAX_BYTES,
  localBackupSha256,
  portableBackupScopeLeaseAllowed,
  PortableBackupRestorePlan,
  validateLocalBackupDocumentDetailed
} from './LocalBackupPolicy';
import {
  BackupRestorePreview,
  BackupSensitivityMode
} from './BackupManifestV3';
import { BoundedDocumentIo, BoundedDocumentIoCode } from './BoundedDocumentIo';
import {
  portableBackupExportAllowed,
  portableBackupRestoreAllowed
} from './CloudLifecycleSafetyPolicy';
import {
  AccountSessionLease,
  accountSessionLeaseEquals
} from './AccountScopePolicy';
import { recordDiagnosticEvent } from './DiagnosticCaptureRuntime';

export class LocalBackupService {
  private static instance: LocalBackupService;
  private readonly cloud: CloudStore = CloudStore.getInstance();
  private lastErrorCode: BoundedDocumentIoCode | 'cancelled' | 'invalid_backup' |
    'unsafe_legacy_backup' | 'snapshot_failed' | 'owner_mismatch' |
    'local_scope_required' | 'export_self_check_failed' | 'backup_newer_version' |
    'selection_expired' | 'restore_failed' = 'cancelled';
  /** Failed validation stage of the last export self-check or selected file. */
  private lastErrorStage: string = '';
  /** Format version declared by the last rejected file, 0 when unknown. */
  private lastErrorVersion: number = 0;
  private selectedPreview: BackupRestorePreview | null = null;
  private selectedDocumentFingerprint: string = '';
  private selectedLease: AccountSessionLease | null = null;

  static getInstance(): LocalBackupService {
    if (!LocalBackupService.instance) { LocalBackupService.instance = new LocalBackupService(); }
    return LocalBackupService.instance;
  }

  getLastErrorMessage(): string {
    if (this.lastErrorCode === 'cancelled') { return '未选择备份文件'; }
    if (this.lastErrorCode === 'empty') { return '备份文件为空'; }
    if (this.lastErrorCode === 'too_large') { return '备份文件过大'; }
    if (this.lastErrorCode === 'short_read') { return '备份文件读取不完整，请重新选择'; }
    if (this.lastErrorCode === 'short_write') { return '备份文件写入不完整，请更换保存位置后重试'; }
    if (this.lastErrorCode === 'invalid_backup') {
      if (this.lastErrorStage === 'json' || this.lastErrorStage === 'shape') {
        return '所选文件不是有效的 RemoteDesktop 备份文件';
      }
      if (this.lastErrorVersion === 1 || this.lastErrorVersion === 2) {
        // Old formats are canonicalized by today's code, so a mismatch is
        // more likely an unsupported early build than a damaged file.
        return '该备份来自早期版本（v' + this.lastErrorVersion.toString() +
          '），包含当前版本无法识别的内容（阶段 ' + this.lastErrorStage + '），未写入任何数据';
      }
      if (this.lastErrorStage === 'hash') { return '备份文件内容已被修改或损坏，完整性校验失败'; }
      return '备份文件未通过校验（阶段 ' + this.lastErrorStage + '），未写入任何数据';
    }
    if (this.lastErrorCode === 'backup_newer_version') {
      return '该备份由更新版本的应用生成，请先升级应用后再恢复';
    }
    if (this.lastErrorCode === 'export_self_check_failed') {
      // The document was produced by this app from local data, so a failure
      // here is an app defect, not a problem with the chosen location.
      return '备份生成后自检未通过（阶段 ' + this.lastErrorStage +
        '），未保存任何文件。这是应用自身的问题，请导出诊断日志反馈';
    }
    if (this.lastErrorCode === 'snapshot_failed') {
      return '无法取得一致的本地数据快照，未生成备份文件';
    }
    if (this.lastErrorCode === 'owner_mismatch') {
      return '备份属于其他账号或本机数据作用域，已拒绝跨作用域导入';
    }
    if (this.lastErrorCode === 'local_scope_required') {
      return '当前本地数据作用域尚未就绪，请重新进入应用后重试';
    }
    if (this.lastErrorCode === 'selection_expired') {
      return '本地数据作用域、数据库会话或备份内容已变化，请重新选择备份文件';
    }
    if (this.lastErrorCode === 'restore_failed') {
      return '恢复未完成；数据仍处于恢复隔离状态，请重试或检查诊断信息';
    }
    if (this.lastErrorCode === 'unsafe_legacy_backup') {
      return '旧版备份未按账号隔离敏感数据，安全备份升级完成前已暂停导出和覆盖恢复';
    }
    return '备份文件读写失败，请重试';
  }

  getSelectedPreview(): BackupRestorePreview | null {
    return this.selectedPreview;
  }

  async saveBackup(
    appVersion: string, stagingDirectory: string,
    sensitivityMode: BackupSensitivityMode = 'redacted'
  ): Promise<boolean> {
    hilog.info(0x0001, 'LocalBackupService',
      'backup export start mode=' + sensitivityMode);
    if (!portableBackupExportAllowed()) {
      this.lastErrorCode = 'unsafe_legacy_backup';
      hilog.error(0x0001, 'LocalBackupService',
        'backup export blocked code=' + this.lastErrorCode);
      return false;
    }
    const exportScope = this.cloud.currentScope();
    const exportLease: AccountSessionLease | null =
      this.cloud.currentAccountLease();
    if (!portableBackupScopeLeaseAllowed(exportScope, exportLease)) {
      this.lastErrorCode = 'local_scope_required';
      hilog.error(0x0001, 'LocalBackupService',
        'backup export blocked code=' + this.lastErrorCode);
      return false;
    }
    const now: number = Date.now();
    this.lastErrorStage = '';
    let snapshot: PortableBackupSnapshot;
    try {
      snapshot = this.cloud.createPortableBackupSnapshot();
    } catch (_e) {
      this.lastErrorCode = 'snapshot_failed';
      hilog.error(0x0001, 'LocalBackupService',
        'backup export snapshot failed');
      return false;
    }
    let document: LocalBackupDocument | null = null;
    try {
      document = createLocalBackupDocument(
        snapshot.tables, now, appVersion, snapshot.extensions,
        snapshot.localTables, snapshot.accountScope,
        snapshot.rdbSchemaVersion, snapshot.sourceCryptoConfigured,
        sensitivityMode);
    } catch (_e) {
      document = null;
    }
    if (document === null) {
      return this.failExportSelfCheck('create');
    }
    const text: string = JSON.stringify(document);
    const bytes: Uint8Array = new util.TextEncoder().encode(text);
    hilog.info(0x0001, 'LocalBackupService',
      'backup document created bytes=' + bytes.length.toString() +
      ' extensions=' + snapshot.extensions.length.toString());
    if (bytes.length > LOCAL_BACKUP_MAX_BYTES) {
      this.lastErrorCode = 'too_large';
      hilog.error(0x0001, 'LocalBackupService',
        'backup export too large bytes=' + bytes.length.toString());
      return false;
    }
    // Self-check before anything touches storage: a document this app cannot
    // read back must never be offered as a backup. The written files are then
    // compared byte for byte with this validated text.
    const selfCheck: LocalBackupValidation = validateLocalBackupDocumentDetailed(text);
    if (selfCheck.document === null) {
      return this.failExportSelfCheck(selfCheck.stage);
    }
    const baseName: string =
      'RemoteDesktop-backup-' + now.toString() + '.json';
    const temporaryPath: string =
      stagingDirectory + '/.' + baseName + '.tmp';
    const readyPath: string = stagingDirectory + '/' + baseName;
    try {
      if (!this.writePrivateStagingFile(temporaryPath, bytes)) {
        hilog.error(0x0001, 'LocalBackupService',
          'backup staging write failed code=' + this.lastErrorCode);
        return false;
      }
      fileIo.renameSync(temporaryPath, readyPath);
      if (!this.verifyFile(readyPath, bytes)) {
        hilog.error(0x0001, 'LocalBackupService',
          'backup staging verify failed code=' + this.lastErrorCode);
        return false;
      }
      hilog.info(0x0001, 'LocalBackupService',
        'backup staging verified');
      const options: picker.DocumentSaveOptions = {
        newFileNames: [baseName]
      };
      const uris: string[] =
        await new picker.DocumentViewPicker().save(options);
      if (uris.length === 0) {
        this.lastErrorCode = 'cancelled';
        hilog.warn(0x0001, 'LocalBackupService',
          'backup document picker cancelled');
        return false;
      }
      const file = fileIo.openSync(
        uris[0], fileIo.OpenMode.CREATE |
        fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
      try {
        const written = BoundedDocumentIo.writeFully(file.fd, bytes);
        this.lastErrorCode = written.code;
        if (!written.ok) {
          hilog.error(0x0001, 'LocalBackupService',
            'backup destination write failed code=' + this.lastErrorCode);
          return false;
        }
        fileIo.fsyncSync(file.fd);
      } finally {
        fileIo.closeSync(file);
      }
      if (!this.verifyFile(uris[0], bytes)) {
        hilog.error(0x0001, 'LocalBackupService',
          'backup destination verify failed code=' + this.lastErrorCode);
        return false;
      }
      this.lastErrorCode = 'cancelled';
      hilog.info(0x0001, 'LocalBackupService',
        'backup export complete');
      return true;
    } catch (_e) {
      if (this.lastErrorCode === 'cancelled') {
        this.lastErrorCode = 'io_error';
      }
      hilog.error(0x0001, 'LocalBackupService',
        'backup export exception code=' + this.lastErrorCode);
      return false;
    } finally {
      LocalBackupService.unlinkIfPresent(temporaryPath);
      LocalBackupService.unlinkIfPresent(readyPath);
    }
  }

  private failExportSelfCheck(stage: string): boolean {
    this.lastErrorCode = 'export_self_check_failed';
    this.lastErrorStage = stage;
    hilog.error(0x0001, 'LocalBackupService',
      'backup export self-check failed stage=' + stage);
    // Code -3: the app could not read back its own document; count = stage.
    recordDiagnosticEvent('data.local_store', 'local_backup_export', 'failed',
      0, this.cloud.currentScope().generation, -3, 0,
      localBackupValidationStageCode(stage));
    return false;
  }

  private writePrivateStagingFile(
    path: string, bytes: Uint8Array
  ): boolean {
    const file = fileIo.openSync(
      path, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY |
      fileIo.OpenMode.TRUNC);
    try {
      const written = BoundedDocumentIo.writeFully(file.fd, bytes);
      this.lastErrorCode = written.code;
      if (!written.ok) { return false; }
      fileIo.fsyncSync(file.fd);
      return true;
    } finally {
      fileIo.closeSync(file);
    }
  }

  /** Reads an exported file back; its bytes must equal the validated document. */
  private verifyFile(path: string, expected: Uint8Array): boolean {
    const file = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
    try {
      const size: number = fileIo.statSync(file.fd).size;
      const verified = BoundedDocumentIo.readFully(
        file.fd, size, LOCAL_BACKUP_MAX_BYTES);
      if (!verified.ok) {
        this.lastErrorCode = verified.code;
        return false;
      }
      if (!LocalBackupService.bytesEqual(expected, verified.bytes)) {
        this.lastErrorCode = 'short_write';
        return false;
      }
      return true;
    } finally {
      fileIo.closeSync(file);
    }
  }

  private static unlinkIfPresent(path: string): void {
    try { fileIo.unlinkSync(path); } catch (_e) {}
  }

  private static bytesEqual(left: Uint8Array, right: Uint8Array): boolean {
    if (left.length !== right.length) { return false; }
    for (let i = 0; i < left.length; i++) {
      if (left[i] !== right[i]) { return false; }
    }
    return true;
  }

  async selectAndValidate(): Promise<LocalBackupDocument | null> {
    this.selectedPreview = null;
    this.selectedDocumentFingerprint = '';
    this.selectedLease = null;
    this.lastErrorStage = '';
    this.lastErrorVersion = 0;
    const selectionScope = this.cloud.currentScope();
    const selectionLease: AccountSessionLease | null =
      this.cloud.currentAccountLease();
    if (!portableBackupScopeLeaseAllowed(
      selectionScope, selectionLease)) {
      this.lastErrorCode = 'local_scope_required';
      return null;
    }
    const uris: string[] = await new picker.DocumentViewPicker().select();
    if (uris.length === 0) { this.lastErrorCode = 'cancelled'; return null; }
    const file = fileIo.openSync(uris[0], fileIo.OpenMode.READ_ONLY);
    try {
      const size: number = fileIo.statSync(file.fd).size;
      const read = BoundedDocumentIo.readFully(file.fd, size, LOCAL_BACKUP_MAX_BYTES);
      if (!read.ok) { this.lastErrorCode = read.code; return null; }
      const validation: LocalBackupValidation =
        validateLocalBackupDocumentDetailed(new util.TextDecoder().decodeToString(read.bytes));
      const document: LocalBackupDocument | null = validation.document;
      this.lastErrorStage = validation.stage;
      this.lastErrorVersion = validation.version;
      this.lastErrorCode = document !== null ? 'cancelled' :
        validation.stage === 'unsupported_version' ? 'backup_newer_version' : 'invalid_backup';
      if (document === null) {
        hilog.error(0x0001, 'LocalBackupService',
          'backup selection rejected stage=' + validation.stage +
          ' version=' + validation.version.toString());
        // Code -3: the selected file was rejected before any write; count = stage.
        recordDiagnosticEvent('data.local_store', 'local_backup_restore', 'failed',
          0, selectionScope.generation, -3, 0,
          localBackupValidationStageCode(validation.stage));
      }
      if (document !== null) {
        this.selectedPreview =
          createLocalBackupRestorePreview(document);
        this.selectedDocumentFingerprint =
          localBackupSha256(JSON.stringify(document));
        this.selectedLease = selectionLease;
      }
      return document;
    } finally { fileIo.closeSync(file); }
  }

  async restore(
    document: LocalBackupDocument,
    allowLegacyOwnerAdoption: boolean = false
  ): Promise<boolean> {
    if (!portableBackupRestoreAllowed()) {
      this.lastErrorCode = 'unsafe_legacy_backup';
      return false;
    }
    const currentScope = this.cloud.currentScope();
    const currentLease: AccountSessionLease | null =
      this.cloud.currentAccountLease();
    if (!portableBackupScopeLeaseAllowed(currentScope, currentLease) ||
      !accountSessionLeaseEquals(currentLease, this.selectedLease) ||
      this.selectedDocumentFingerprint === '' ||
      localBackupSha256(JSON.stringify(document)) !==
        this.selectedDocumentFingerprint) {
      this.lastErrorCode = 'selection_expired';
      return false;
    }
    const plan: PortableBackupRestorePlan | null =
      adaptLocalBackupDocumentForRestore(
        document, currentScope.ownerScopeId,
        allowLegacyOwnerAdoption);
    if (plan === null) {
      this.lastErrorCode = 'owner_mismatch';
      return false;
    }
    const finishAiRestore = AiLifecycle.beginRestore();
    let restored = false;
    try {
      AiTransport.cancelAll();
      if (!(await AiTransport.drain())) { this.lastErrorCode = 'restore_failed'; return false; }
      restored = await CloudSyncCoordinator.getInstance().runExclusiveRestore(
        (): Promise<boolean> => this.cloud.mergePortableBackup(plan));
    } finally { finishAiRestore(); }
    this.lastErrorCode = restored ? 'cancelled' : 'restore_failed';
    if (restored) {
      this.selectedPreview = null;
      this.selectedDocumentFingerprint = '';
      this.selectedLease = null;
    }
    return restored;
  }
}
