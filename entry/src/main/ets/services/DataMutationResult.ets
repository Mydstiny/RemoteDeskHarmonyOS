/**
 * One local persistence operation must have one observable outcome.  Boolean
 * callers remain supported by CloudStore, while UI/service code can inspect
 * the exact reason when a write is rejected before it reaches cloud sync.
 */
export type DataMutationCode =
  'ok' | 'not_ready' | 'not_found' | 'unchanged' | 'unlock_required' |
  'local_write_failed' | 'extension_write_failed' | 'journal_write_failed' |
  'restore_in_progress' | 'sync_deferred';

export class DataMutationResult {
  ok: boolean = false;
  code: DataMutationCode = 'local_write_failed';
  recordId: string = '';
  message: string = '';

  static success(recordId: string, code: DataMutationCode = 'ok'): DataMutationResult {
    const result = new DataMutationResult();
    result.ok = true;
    result.code = code;
    result.recordId = recordId;
    return result;
  }

  static failure(recordId: string, code: DataMutationCode, message: string): DataMutationResult {
    const result = new DataMutationResult();
    result.ok = false;
    result.code = code;
    result.recordId = recordId;
    result.message = message;
    return result;
  }
}
