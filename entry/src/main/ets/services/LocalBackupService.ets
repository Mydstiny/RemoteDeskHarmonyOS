import { picker, fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
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
  LOCAL_BACKUP_MAX_BYTES,
  localBackupSha256,
  PortableBackupRestorePlan,
  validateLocalBackupDocument
} from './LocalBackupPolicy';
import { BackupRestorePreview } from './BackupManifestV3';
import { BoundedDocumentIo, BoundedDocumentIoCode } from './BoundedDocumentIo';
import {
  portableBackupExportAllowed,
  portableBackupRestoreAllowed
} from './CloudLifecycleSafetyPolicy';

export class LocalBackupService {
  private static instance: LocalBackupService;
  private readonly cloud: CloudStore = CloudStore.getInstance();
  private lastErrorCode: BoundedDocumentIoCode | 'cancelled' | 'invalid_backup' |
    'unsafe_legacy_backup' | 'snapshot_failed' | 'owner_mismatch' |
    'selection_expired' | 'restore_failed' = 'cancelled';
  private selectedPreview: BackupRestorePreview | null = null;
  private selectedDocumentFingerprint: string = '';
  private selectedOwnerScopeId: string = '';
  private selectedGeneration: number = 0;

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
    if (this.lastErrorCode === 'invalid_backup') { return '备份文件格式或完整性校验失败'; }
    if (this.lastErrorCode === 'snapshot_failed') {
      return '无法取得一致的账号数据快照，未生成备份文件';
    }
    if (this.lastErrorCode === 'owner_mismatch') {
      return '备份属于其他华为账号，已拒绝导入当前账号';
    }
    if (this.lastErrorCode === 'selection_expired') {
      return '账号会话或备份内容已变化，请重新选择备份文件';
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
    appVersion: string, stagingDirectory: string
  ): Promise<boolean> {
    if (!portableBackupExportAllowed()) {
      this.lastErrorCode = 'unsafe_legacy_backup';
      return false;
    }
    const now: number = Date.now();
    let snapshot: PortableBackupSnapshot;
    try {
      snapshot = this.cloud.createPortableBackupSnapshot();
    } catch (_e) {
      this.lastErrorCode = 'snapshot_failed';
      return false;
    }
    const document: LocalBackupDocument = createLocalBackupDocument(
      snapshot.tables, now, appVersion, snapshot.extensions,
      snapshot.localTables, snapshot.accountScope,
      snapshot.rdbSchemaVersion, snapshot.sourceCryptoConfigured);
    const bytes: Uint8Array = new util.TextEncoder().encode(JSON.stringify(document));
    if (bytes.length > LOCAL_BACKUP_MAX_BYTES) { this.lastErrorCode = 'too_large'; return false; }
    const baseName: string =
      'RemoteDesktop-backup-' + now.toString() + '.json';
    const temporaryPath: string =
      stagingDirectory + '/.' + baseName + '.tmp';
    const readyPath: string = stagingDirectory + '/' + baseName;
    try {
      if (!this.writePrivateStagingFile(temporaryPath, bytes)) {
        return false;
      }
      fileIo.renameSync(temporaryPath, readyPath);
      if (!this.verifyFile(readyPath, bytes)) { return false; }
      const options: picker.DocumentSaveOptions = {
        newFileNames: [baseName]
      };
      const uris: string[] =
        await new picker.DocumentViewPicker().save(options);
      if (uris.length === 0) {
        this.lastErrorCode = 'cancelled';
        return false;
      }
      const file = fileIo.openSync(
        uris[0], fileIo.OpenMode.CREATE |
        fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
      try {
        const written = BoundedDocumentIo.writeFully(file.fd, bytes);
        this.lastErrorCode = written.code;
        if (!written.ok) { return false; }
        fileIo.fsyncSync(file.fd);
      } finally {
        fileIo.closeSync(file);
      }
      if (!this.verifyFile(uris[0], bytes)) { return false; }
      this.lastErrorCode = 'cancelled';
      return true;
    } catch (_e) {
      if (this.lastErrorCode === 'cancelled') {
        this.lastErrorCode = 'io_error';
      }
      return false;
    } finally {
      LocalBackupService.unlinkIfPresent(temporaryPath);
      LocalBackupService.unlinkIfPresent(readyPath);
    }
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
      const parsed: LocalBackupDocument | null =
        validateLocalBackupDocument(
          new util.TextDecoder().decodeToString(verified.bytes));
      if (parsed === null) {
        this.lastErrorCode = 'invalid_backup';
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
    this.selectedOwnerScopeId = '';
    this.selectedGeneration = 0;
    const selectionScope = this.cloud.currentScope();
    if (selectionScope.kind !== 'huawei_account' ||
      selectionScope.ownerScopeId.trim() === '') {
      this.lastErrorCode = 'owner_mismatch';
      return null;
    }
    const uris: string[] = await new picker.DocumentViewPicker().select();
    if (uris.length === 0) { this.lastErrorCode = 'cancelled'; return null; }
    const file = fileIo.openSync(uris[0], fileIo.OpenMode.READ_ONLY);
    try {
      const size: number = fileIo.statSync(file.fd).size;
      const read = BoundedDocumentIo.readFully(file.fd, size, LOCAL_BACKUP_MAX_BYTES);
      if (!read.ok) { this.lastErrorCode = read.code; return null; }
      const document: LocalBackupDocument | null =
        validateLocalBackupDocument(new util.TextDecoder().decodeToString(read.bytes));
      this.lastErrorCode = document ? 'cancelled' : 'invalid_backup';
      if (document !== null) {
        this.selectedPreview =
          createLocalBackupRestorePreview(document);
        this.selectedDocumentFingerprint =
          localBackupSha256(JSON.stringify(document));
        this.selectedOwnerScopeId = selectionScope.ownerScopeId;
        this.selectedGeneration = selectionScope.generation;
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
    if (currentScope.kind !== 'huawei_account' ||
      currentScope.ownerScopeId !== this.selectedOwnerScopeId ||
      currentScope.generation !== this.selectedGeneration ||
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
    const restored: boolean =
      await CloudSyncCoordinator.getInstance().runExclusiveRestore(
        (): Promise<boolean> =>
          this.cloud.mergePortableBackup(plan));
    this.lastErrorCode = restored ? 'cancelled' : 'restore_failed';
    if (restored) {
      this.selectedPreview = null;
      this.selectedDocumentFingerprint = '';
      this.selectedOwnerScopeId = '';
      this.selectedGeneration = 0;
    }
    return restored;
  }
}
