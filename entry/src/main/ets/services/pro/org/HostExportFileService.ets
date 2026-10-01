import { fileIo, picker } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { BoundedDocumentIo } from '../../BoundedDocumentIo';

const HOST_EXPORT_MAX_BYTES: number = 2 * 1024 * 1024;

export type HostExportFileCode = 'ok' | 'cancelled' | 'failed' | 'too_large';
export interface HostImportFileResult { code: HostExportFileCode; text: string; }

/** Saves and opens host-export JSON documents through the system file picker. */
export class HostExportFileService {
  static async save(fileName: string, text: string): Promise<HostExportFileCode> {
    const bytes: Uint8Array = new util.TextEncoder().encodeInto(text);
    if (bytes.length > HOST_EXPORT_MAX_BYTES) { return 'too_large'; }
    try {
      const options: picker.DocumentSaveOptions = { newFileNames: [fileName] };
      const uris: string[] = await new picker.DocumentViewPicker().save(options);
      if (uris.length === 0) { return 'cancelled'; }
      const file = fileIo.openSync(uris[0], fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
      try {
        const written = BoundedDocumentIo.writeFully(file.fd, bytes);
        if (!written.ok) { return 'failed'; }
        fileIo.fsyncSync(file.fd);
      } finally {
        fileIo.closeSync(file);
      }
      return 'ok';
    } catch (_error) {
      return 'failed';
    }
  }

  static async open(): Promise<HostImportFileResult> {
    try {
      const options: picker.DocumentSelectOptions = { maxSelectNumber: 1, fileSuffixFilters: ['.json'] };
      const uris: string[] = await new picker.DocumentViewPicker().select(options);
      if (uris.length === 0) { return { code: 'cancelled', text: '' }; }
      const file = fileIo.openSync(uris[0], fileIo.OpenMode.READ_ONLY);
      try {
        const size: number = fileIo.statSync(file.fd).size;
        if (size > HOST_EXPORT_MAX_BYTES) { return { code: 'too_large', text: '' }; }
        const read = BoundedDocumentIo.readFully(file.fd, size, HOST_EXPORT_MAX_BYTES);
        if (!read.ok) { return { code: 'failed', text: '' }; }
        return { code: 'ok', text: new util.TextDecoder().decodeToString(read.bytes) };
      } finally {
        fileIo.closeSync(file);
      }
    } catch (_error) {
      return { code: 'failed', text: '' };
    }
  }
}
