import { picker, fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { CloudStore } from './CloudStore';
import { CloudSyncCoordinator } from './CloudSyncCoordinator';
import { createLocalBackupDocument, LocalBackupDocument, validateLocalBackupDocument } from './LocalBackupPolicy';

export class LocalBackupService {
  private static instance: LocalBackupService;
  private readonly cloud: CloudStore = CloudStore.getInstance();

  static getInstance(): LocalBackupService {
    if (!LocalBackupService.instance) { LocalBackupService.instance = new LocalBackupService(); }
    return LocalBackupService.instance;
  }

  async saveBackup(appVersion: string): Promise<boolean> {
    const now: number = Date.now();
    const document: LocalBackupDocument = createLocalBackupDocument(
      this.cloud.exportAllTableRows(), now, appVersion, this.cloud.exportLocalExtensionRows());
    const options: picker.DocumentSaveOptions = { newFileNames: ['RemoteDesktop-backup-' + now.toString() + '.json'] };
    const uris: string[] = await new picker.DocumentViewPicker().save(options);
    if (uris.length === 0) { return false; }
    const file = fileIo.openSync(uris[0], fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
    try {
      const bytes: Uint8Array = new util.TextEncoder().encode(JSON.stringify(document));
      fileIo.writeSync(file.fd, bytes.buffer as ArrayBuffer);
      return true;
    } finally { fileIo.closeSync(file); }
  }

  async selectAndValidate(): Promise<LocalBackupDocument | null> {
    const uris: string[] = await new picker.DocumentViewPicker().select();
    if (uris.length === 0) { return null; }
    const file = fileIo.openSync(uris[0], fileIo.OpenMode.READ_ONLY);
    try {
      const size: number = fileIo.statSync(file.fd).size;
      const buffer = new ArrayBuffer(size);
      fileIo.readSync(file.fd, buffer);
      return validateLocalBackupDocument(new util.TextDecoder().decodeToString(new Uint8Array(buffer)));
    } finally { fileIo.closeSync(file); }
  }

  async restore(document: LocalBackupDocument): Promise<boolean> {
    return await CloudSyncCoordinator.getInstance().runExclusiveRestore(
      (): Promise<boolean> => this.cloud.replaceAllTableRows(document.tables, document.extensions || [])
    );
  }
}
