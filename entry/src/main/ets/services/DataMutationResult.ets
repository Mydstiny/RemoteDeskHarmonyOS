/**
 * One local persistence operation must have one observable outcome.  Boolean
 * callers remain supported by CloudStore, while UI/service code can inspect
 * the exact reason when a write is rejected before it reaches cloud sync.
 */
export type DataMutationCode =
  'ok' | 'not_ready' | 'not_found' | 'unchanged' | 'unlock_required' |
  'local_write_failed' | 'extension_write_failed' | 'metadata_write_failed' | 'journal_write_failed' |
  'readback_not_found' | 'readback_mismatch' |
  'restore_in_progress' | 'sync_deferred' | 'invalid_data' |
  'crypto_lifecycle_blocked';

export type DataMutationStage =
  'idle' | 'validating' | 'waiting_gate' | 'committing' | 'verifying' | 'completed';

export class DataMutationResult {
  ok: boolean = false;
  code: DataMutationCode = 'local_write_failed';
  recordId: string = '';
  message: string = '';
  stage: DataMutationStage = 'committing';
  localCommitted: boolean = false;

  static success(
    recordId: string,
    code: DataMutationCode = 'ok',
    stage: DataMutationStage = 'completed'
  ): DataMutationResult {
    const result = new DataMutationResult();
    result.ok = true;
    result.code = code;
    result.recordId = recordId;
    result.stage = stage;
    result.localCommitted = true;
    return result;
  }

  static failure(
    recordId: string,
    code: DataMutationCode,
    message: string,
    stage: DataMutationStage = 'committing',
    localCommitted: boolean = false
  ): DataMutationResult {
    const result = new DataMutationResult();
    result.ok = false;
    result.code = code;
    result.recordId = recordId;
    result.message = message;
    result.stage = stage;
    result.localCommitted = localCommitted;
    return result;
  }
}
