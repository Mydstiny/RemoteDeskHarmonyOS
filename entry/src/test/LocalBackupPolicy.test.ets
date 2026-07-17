import { describe, it, expect } from '@ohos/hypium';
import { CLOUD_SYNC_TABLES } from '../main/ets/services/CloudSyncPolicy';
import {
  LocalBackupDocument,
  createLocalBackupDocument,
  localBackupCanonicalPayload,
  localBackupSha256,
  validateLocalBackupDocument
} from '../main/ets/services/LocalBackupPolicy';

function emptyTables(): Record<string, Array<Record<string, string>>> {
  const tables: Record<string, Array<Record<string, string>>> = {};
  for (let i = 0; i < CLOUD_SYNC_TABLES.length; i++) { tables[CLOUD_SYNC_TABLES[i]] = []; }
  return tables;
}

function signedText(document: LocalBackupDocument): string {
  document.sha256 = localBackupSha256(localBackupCanonicalPayload(
    document.createdAt, document.appVersion, document.tables));
  return JSON.stringify(document);
}

export default function localBackupPolicyTest(): void {
  describe('LocalBackupPolicy', (): void => {
    it('accepts_an_exact_empty_seven_table_backup', 0, (): void => {
      const document = createLocalBackupDocument(emptyTables(), 100, '1.0.5');
      expect(validateLocalBackupDocument(JSON.stringify(document)) !== null).assertTrue();
    });

    it('rejects_unknown_columns_inside_a_row', 0, (): void => {
      const document = createLocalBackupDocument(emptyTables(), 100, '1.0.5');
      document.tables['sshkeys'].push({ id: 'key-1', unexpected: 'no' });
      expect(validateLocalBackupDocument(signedText(document)) === null).assertTrue();
    });

    it('rejects_non_integer_text_for_integer_columns', 0, (): void => {
      const document = createLocalBackupDocument(emptyTables(), 100, '1.0.5');
      document.tables['remotehosts'].push({ id: 'host-1', port: 'invalid' });
      expect(validateLocalBackupDocument(signedText(document)) === null).assertTrue();
    });

    it('accepts_rows_missing_columns_added_by_later_versions', 0, (): void => {
      const document = createLocalBackupDocument(emptyTables(), 100, '1.0.5');
      document.tables['rdpcredentials'].push({ id: 'credential-1' });
      expect(validateLocalBackupDocument(signedText(document)) !== null).assertTrue();
    });
  });
}
