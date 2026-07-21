import { picker, fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { CloudStore } from './CloudStore';
import { CloudSyncCoordinator } from './CloudSyncCoordinator';
import {
  createLocalBackupDocument,
  LocalBackupDocument,
  LOCAL_BACKUP_MAX_BYTES,
  validateLocalBackupDocument
} from './LocalBackupPolicy';
import { BoundedDocumentIo, BoundedDocumentIoCode } from './BoundedDocumentIo';

export class LocalBackupService {
  private static instance: LocalBackupService;
  private readonly cloud: CloudStore = CloudStore.getInstance();
  private lastErrorCode: BoundedDocumentIoCode | 'cancelled' | 'invalid_backup' = 'cancelled';

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
    return '备份文件读写失败，请重试';
  }

  async saveBackup(appVersion: string): Promise<boolean> {
    const now: number = Date.now();
    const document: LocalBackupDocument = createLocalBackupDocument(
      this.cloud.exportAllTableRows(), now, appVersion, this.cloud.exportLocalExtensionRows());
    const options: picker.DocumentSaveOptions = { newFileNames: ['RemoteDesktop-backup-' + now.toString() + '.json'] };
    const uris: string[] = await new picker.DocumentViewPicker().save(options);
    if (uris.length === 0) { this.lastErrorCode = 'cancelled'; return false; }
    const bytes: Uint8Array = new util.TextEncoder().encode(JSON.stringify(document));
    if (bytes.length > LOCAL_BACKUP_MAX_BYTES) { this.lastErrorCode = 'too_large'; return false; }
    const file = fileIo.openSync(uris[0], fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
    try {
      const written = BoundedDocumentIo.writeFully(file.fd, bytes);
      this.lastErrorCode = written.code;
      if (!written.ok) { return false; }
    } finally { fileIo.closeSync(file); }

    // A successful write call is not sufficient evidence that a document provider
    // persisted the complete backup. Reopen the selected URI and verify both the
    // exact bytes and the signed backup structure before reporting success.
    const verifyFile = fileIo.openSync(uris[0], fileIo.OpenMode.READ_ONLY);
    try {
      const size: number = fileIo.statSync(verifyFile.fd).size;
      const verified = BoundedDocumentIo.readFully(verifyFile.fd, size, LOCAL_BACKUP_MAX_BYTES);
      if (!verified.ok) { this.lastErrorCode = verified.code; return false; }
      if (!LocalBackupService.bytesEqual(bytes, verified.bytes)) {
        this.lastErrorCode = 'short_write';
        return false;
      }
      const parsed: LocalBackupDocument | null =
        validateLocalBackupDocument(new util.TextDecoder().decodeToString(verified.bytes));
      if (!parsed) { this.lastErrorCode = 'invalid_backup'; return false; }
      this.lastErrorCode = 'cancelled';
      return true;
    } finally { fileIo.closeSync(verifyFile); }
  }

  private static bytesEqual(left: Uint8Array, right: Uint8Array): boolean {
    if (left.length !== right.length) { return false; }
    for (let i = 0; i < left.length; i++) {
      if (left[i] !== right[i]) { return false; }
    }
    return true;
  }

  async selectAndValidate(): Promise<LocalBackupDocument | null> {
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
      return document;
    } finally { fileIo.closeSync(file); }
  }

  async restore(document: LocalBackupDocument): Promise<boolean> {
    return await CloudSyncCoordinator.getInstance().runExclusiveRestore(
      (): Promise<boolean> => this.cloud.replaceAllTableRows(document.tables, document.extensions || [])
    );
  }
}
