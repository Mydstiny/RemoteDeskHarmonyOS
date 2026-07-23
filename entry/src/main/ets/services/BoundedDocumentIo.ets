import { fileIo } from '@kit.CoreFileKit';

/**
 * CoreFileKit readSync/writeSync may complete a short transfer. Backup code
 * must therefore consume/produce the complete document before reporting it
 * as valid or saved.
 */
export type BoundedDocumentIoCode =
  'ok' | 'empty' | 'too_large' | 'short_read' | 'short_write' | 'io_error';

export class BoundedDocumentReadResult {
  ok: boolean = false;
  code: BoundedDocumentIoCode = 'io_error';
  bytes: Uint8Array = new Uint8Array(0);
}

export class BoundedDocumentWriteResult {
  ok: boolean = false;
  code: BoundedDocumentIoCode = 'io_error';
  bytesWritten: number = 0;
}

export const DOCUMENT_IO_CHUNK_BYTES: number = 64 * 1024;

export function validateBoundedDocumentSize(size: number, maxBytes: number): BoundedDocumentIoCode {
  if (!Number.isFinite(size) || size <= 0) { return 'empty'; }
  if (!Number.isFinite(maxBytes) || maxBytes <= 0 || size > maxBytes) { return 'too_large'; }
  return 'ok';
}

export function documentTransferIsComplete(expectedBytes: number, transferredBytes: number): boolean {
  return expectedBytes >= 0 && transferredBytes === expectedBytes;
}

export class BoundedDocumentIo {
  static readFully(fd: number, size: number, maxBytes: number): BoundedDocumentReadResult {
    const result = new BoundedDocumentReadResult();
    const sizeCode: BoundedDocumentIoCode = validateBoundedDocumentSize(size, maxBytes);
    if (sizeCode !== 'ok') {
      result.code = sizeCode;
      return result;
    }
    try {
      const all: Uint8Array = new Uint8Array(size);
      let offset: number = 0;
      while (offset < size) {
        const request: number = Math.min(DOCUMENT_IO_CHUNK_BYTES, size - offset);
        const block: ArrayBuffer = new ArrayBuffer(request);
        const read: number = fileIo.readSync(fd, block);
        if (read <= 0 || read > request) {
          result.code = 'short_read';
          return result;
        }
        all.set(new Uint8Array(block).subarray(0, read), offset);
        offset += read;
      }
      if (!documentTransferIsComplete(size, offset)) {
        result.code = 'short_read';
        return result;
      }
      result.ok = true;
      result.code = 'ok';
      result.bytes = all;
      return result;
    } catch (_err) {
      result.code = 'io_error';
      return result;
    }
  }

  static writeFully(fd: number, bytes: Uint8Array): BoundedDocumentWriteResult {
    const result = new BoundedDocumentWriteResult();
    if (bytes.length === 0) {
      result.code = 'empty';
      return result;
    }
    try {
      let offset: number = 0;
      while (offset < bytes.length) {
        const request: number = Math.min(DOCUMENT_IO_CHUNK_BYTES, bytes.length - offset);
        const block: Uint8Array = new Uint8Array(request);
        block.set(bytes.subarray(offset, offset + request));
        const written: number = fileIo.writeSync(fd, block.buffer as ArrayBuffer);
        if (written <= 0 || written > request) {
          result.code = 'short_write';
          result.bytesWritten = offset;
          return result;
        }
        offset += written;
      }
      result.ok = documentTransferIsComplete(bytes.length, offset);
      result.code = result.ok ? 'ok' : 'short_write';
      result.bytesWritten = offset;
      return result;
    } catch (_err) {
      result.code = 'io_error';
      return result;
    }
  }
}
