import { pasteboard } from '@kit.BasicServicesKit';
import { fileIo, fileUri } from '@kit.CoreFileKit';

const MAX_FILES: number = 256;
const READ_TIMEOUT_MS: number = 30000;
const CANCEL_POLL_MS: number = 100;
const ERROR_PREFIX: string = 'system_clipboard_files_';

function failure(reason: string): Error { return new Error(ERROR_PREFIX + reason); }
function diagnostic(error: Error): Error {
  return error !== null && error !== undefined && typeof error.message === 'string' && error.message.startsWith(ERROR_PREFIX) ?
    error : failure('read_failed');
}

/** Reads one system clipboard source; it never creates a destination or copies bytes.
 * API 23/26 getDataWithProgress + ProgressSignal are available since API 15;
 * getChangeCount is available since API 18. The API excludes folders. Its API 26
 * contract recommends omitting destUri for complex copying policies, leaving the
 * actual copy to our scoped artifact store. Progress here is clipboard reading,
 * not staging or network transfer progress.
 */
export class SystemClipboardFileProvider {
  read(isCurrent: () => boolean, onProgress?: (percent: number) => void): Promise<string[]> {
    return new Promise<string[]>((resolve, reject): void => {
      let board: pasteboard.SystemPasteboard;
      let signal: pasteboard.ProgressSignal;
      let changeCount: number;
      try {
        let owned: boolean = false;
        try { owned = isCurrent(); } catch (_error) { /* Fail closed before admission. */ }
        if (!owned) { throw failure('cancelled'); }
        board = pasteboard.getSystemPasteboard();
        changeCount = board.getChangeCount();
        // Zero also means the platform could not read its counter. It cannot
        // establish the identity of a non-empty clipboard file source.
        if (!Number.isSafeInteger(changeCount) || changeCount <= 0) { throw failure('source_unavailable'); }
        signal = new pasteboard.ProgressSignal();
      } catch (error) { reject(diagnostic(error as Error)); return; }

      let finished: boolean = false;
      let reported: number = -1;
      const started: number = Date.now();
      let timeout: number = -1;
      let poll: number = -1;
      const clearTimers = (): void => {
        if (timeout >= 0) { clearTimeout(timeout); timeout = -1; }
        if (poll >= 0) { clearInterval(poll); poll = -1; }
      };
      const stop = (error: Error): void => {
        if (finished) { return; }
        finished = true; clearTimers();
        // Settle independently of an uncooperative platform promise. A cancel
        // callback may run synchronously, so close our callback gate first.
        try { signal.cancel(); } catch (_error) { /* Cancellation remains best effort. */ }
        reject(diagnostic(error));
      };
      const check = (): void => {
        if (finished) { throw failure('cancelled'); }
        let current: boolean = false;
        try { current = isCurrent(); } catch (_error) { /* A lost owner is cancellation. */ }
        if (!current) { throw failure('cancelled'); }
        let observed: number;
        try { observed = board.getChangeCount(); } catch (_error) { throw failure('source_unavailable'); }
        if (!Number.isSafeInteger(observed) || observed <= 0) { throw failure('source_unavailable'); }
        if (observed !== changeCount) { throw failure('source_changed'); }
        if (Date.now() - started >= READ_TIMEOUT_MS) { throw failure('timeout'); }
      };
      const report = (value: number, complete: boolean = false): void => {
        if (finished) { return; }
        check();
        if (!Number.isFinite(value)) { return; }
        const percent: number = Math.max(0, Math.min(complete ? 100 : 99, Math.floor(value)));
        if (percent <= reported) { return; }
        reported = percent;
        if (onProgress !== undefined) { try { onProgress(percent); } catch (_error) { /* Read observers cannot own the operation. */ } }
        check();
      };
      timeout = setTimeout((): void => { stop(failure('timeout')); }, READ_TIMEOUT_MS);
      poll = setInterval((): void => {
        if (finished) { return; }
        try { check(); } catch (error) { stop(error as Error); }
      }, CANCEL_POLL_MS);
      const params: pasteboard.GetDataParams = {
        progressIndicator: pasteboard.ProgressIndicator.NONE,
        progressSignal: signal,
        progressListener: (info: pasteboard.ProgressInfo): void => {
          if (finished) { return; }
          try { report(info.progress); } catch (error) { stop(error as Error); }
        }
      };
      // Both fulfillment and rejection handlers remain installed after timeout,
      // consuming late completion without restarting metadata work or callbacks.
      const operation = async (): Promise<string[]> => {
        check(); report(0);
        const data: pasteboard.PasteData = await board.getDataWithProgress(params);
        check();
        const count: number = data.getRecordCount();
        if (!Number.isSafeInteger(count) || count < 0 || count > MAX_FILES) { throw failure('item_limit'); }
        const uris: string[] = [];
        for (let index: number = 0; index < count; index++) {
          check(); const record: pasteboard.PasteDataRecord = data.getRecord(index);
          if (record.mimeType !== pasteboard.MIMETYPE_TEXT_URI) { continue; }
          const uri: string = record.uri;
          if (typeof uri !== 'string' || !uri.startsWith('file://') || uri.length > 8192 ||
            uri.indexOf('\u0000') >= 0 || uri.indexOf('?') >= 0 || uri.indexOf('#') >= 0) {
            throw failure('unsupported_uri');
          }
          const path: string = new fileUri.FileUri(uri).path;
          if (!path.startsWith('/') || path.length > 4096 || path.indexOf('\u0000') >= 0 || path.indexOf('\\') >= 0 ||
            path.split('/').slice(1).some((part: string): boolean => part.length === 0 || part === '.' || part === '..')) {
            throw failure('unsupported_uri');
          }
          // lstat accepts URI grants since API 22 in both installed SDKs.
          // Keep the original authority here as well as in the returned value.
          check(); const info: fileIo.Stat = await fileIo.lstat(uri); check();
          if (info.isDirectory()) { throw failure('directory_unsupported'); }
          if (info.isSymbolicLink() || !info.isFile()) { throw failure('unsupported_type'); }
          uris.push(uri);
        }
        check();
        if (uris.length === 0) { throw failure('no_files'); }
        if (uris.length > MAX_FILES) { throw failure('item_limit'); }
        return uris;
      };
      operation().then((uris: string[]): void => {
        if (finished) { return; }
        try {
          check(); report(100, true); check();
          finished = true; clearTimers(); resolve(uris);
        } catch (error) { stop(error as Error); }
      }, (error: Error): void => { stop(error); });
    });
  }
}
