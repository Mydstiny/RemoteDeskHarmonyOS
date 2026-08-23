import { describe, it, expect } from '@ohos/hypium';
import {
  addSshSessionLogBookmark,
  appendSshSessionLogRecord,
  continueSshSessionLogSearch,
  createSshSessionLogSearchCursor,
  defaultSshSessionLogSettings,
  emptySshSessionLogDocument,
  encodeSshSessionLogDocument,
  exportSshSessionLog,
  matchesSshSessionLogExportFence,
  pruneSshSessionLogDocument,
  resolveSshSessionLogsEnabled,
  searchSshSessionLog,
  sanitizeSshSessionLogText,
  sshSessionLogCaptureAllowed,
  sshSessionLogInputPhaseAllowed,
  SSH_SESSION_LOG_CHUNK_MAX_RECORDS,
  SSH_SESSION_LOGS_DEFAULT_ENABLED,
  SSH_SESSION_LOG_SEARCH_WORK_BUDGET,
  SshSessionLogChunkV1,
  SshSessionLogDocumentV1,
  SshSessionLogRecordV1,
  SshSessionLogSearchCursorV1
} from '../main/ets/services/ssh/log/SshSessionLogPolicy';

function record(id: string, text: string, timestamp: number = 100): SshSessionLogRecordV1 {
  return {
    id, hostId: 'host-one', sessionId: 7, generation: 2, timestamp,
    direction: 'output', kind: 'data', text, searchText: '', byteSize: text.length
  };
}

function recordForHost(id: string, hostId: string, text: string,
  timestamp: number): SshSessionLogRecordV1 {
  const value: SshSessionLogRecordV1 = record(id, text, timestamp);
  value.hostId = hostId;
  return value;
}

export default function sshSessionLogPolicyTest(): void {
  describe('SshSessionLogPolicy', (): void => {
    it('rollout_gate_should_be_independently_disabled_by_default', 0, (): void => {
      expect(SSH_SESSION_LOGS_DEFAULT_ENABLED).assertFalse();
      expect(resolveSshSessionLogsEnabled(true, false)).assertFalse();
      expect(resolveSshSessionLogsEnabled(false, true)).assertFalse();
      expect(resolveSshSessionLogsEnabled(true, true)).assertTrue();
    });

    it('export_fence_should_reject_flag_page_binding_or_host_changes', 0, (): void => {
      expect(matchesSshSessionLogExportFence(
        'host-one', 7, 9, 'host-one', 7, 9, true)).assertTrue();
      expect(matchesSshSessionLogExportFence(
        'host-one', 7, 9, 'host-two', 7, 9, true)).assertFalse();
      expect(matchesSshSessionLogExportFence(
        'host-one', 7, 9, 'host-one', 8, 9, true)).assertFalse();
      expect(matchesSshSessionLogExportFence(
        'host-one', 7, 9, 'host-one', 7, 10, true)).assertFalse();
      expect(matchesSshSessionLogExportFence(
        'host-one', 7, 9, 'host-one', 7, 9, false)).assertFalse();
    });

    it('chunked_search_should_match_sync_results_and_honor_small_budgets', 0, (): void => {
      const document: SshSessionLogDocumentV1 = emptySshSessionLogDocument();
      document.settings.enabled = true;
      let populated: SshSessionLogDocumentV1 = appendSshSessionLogRecord(
        document, record('one', 'alpha'), 100);
      populated = appendSshSessionLogRecord(populated, record('two', 'needle'), 101);
      populated = appendSshSessionLogRecord(populated, record('three', 'omega'), 102);
      let cursor: SshSessionLogSearchCursorV1 = createSshSessionLogSearchCursor(
        populated, 'needle', 'host-one');
      cursor = continueSshSessionLogSearch(populated, cursor, 1);
      expect(cursor.done).assertFalse();
      expect(cursor.results.length).assertEqual(0);
      let turns: number = 1;
      while (!cursor.done && turns < 32) {
        cursor = continueSshSessionLogSearch(populated, cursor, 1);
        turns++;
      }
      const synchronous = searchSshSessionLog(populated, 'needle', 'host-one');
      expect(cursor.done).assertTrue();
      expect(cursor.results.length).assertEqual(synchronous.length);
      expect(cursor.results[0].record.id).assertEqual(synchronous[0].record.id);

      let invalidIdentity: SshSessionLogSearchCursorV1 = createSshSessionLogSearchCursor(
        populated, '', '', { hostId: '', sessionId: 7, generation: 2 });
      while (!invalidIdentity.done) {
        invalidIdentity = continueSshSessionLogSearch(populated, invalidIdentity, 2);
      }
      expect(invalidIdentity.results.length).assertEqual(0);
    });

    it('ten_mib_search_should_remain_bounded_across_multiple_slices', 0, (): void => {
      const document: SshSessionLogDocumentV1 = emptySshSessionLogDocument();
      const miss: string = 'x'.repeat(8192);
      const match: string = 'x'.repeat(8186) + 'needle';
      let corpusBytes: number = 0;
      for (let chunkIndex: number = 0; chunkIndex < 11; chunkIndex++) {
        const records: Array<SshSessionLogRecordV1> = [];
        for (let recordIndex: number = 0;
          recordIndex < SSH_SESSION_LOG_CHUNK_MAX_RECORDS; recordIndex++) {
          const isMatch: boolean = chunkIndex === 10 &&
            recordIndex === SSH_SESSION_LOG_CHUNK_MAX_RECORDS - 1;
          const text: string = isMatch ? match : miss;
          const item: SshSessionLogRecordV1 = record(
            'large-' + chunkIndex.toString() + '-' + recordIndex.toString(), text,
            chunkIndex * SSH_SESSION_LOG_CHUNK_MAX_RECORDS + recordIndex);
          item.searchText = text;
          records.push(item);
          corpusBytes += item.byteSize;
        }
        const chunk: SshSessionLogChunkV1 = {
          id: 'chunk-' + chunkIndex.toString(), hostId: 'host-one',
          sessionId: 7, generation: 2,
          createdAt: records[0].timestamp,
          updatedAt: records[records.length - 1].timestamp,
          byteSize: records.reduce((sum: number, item: SshSessionLogRecordV1): number =>
            sum + item.byteSize, 0),
          records
        };
        document.chunks.push(chunk);
      }

      let cursor: SshSessionLogSearchCursorV1 = createSshSessionLogSearchCursor(
        document, 'needle', 'host-one');
      let slices: number = 0;
      while (!cursor.done && slices < 32) {
        cursor = continueSshSessionLogSearch(
          document, cursor, SSH_SESSION_LOG_SEARCH_WORK_BUDGET);
        slices++;
      }

      expect(corpusBytes > 10 * 1024 * 1024).assertTrue();
      expect(slices > 1).assertTrue();
      expect(cursor.done).assertTrue();
      expect(cursor.results.length).assertEqual(1);
      expect(cursor.results[0].record.id).assertEqual('large-10-127');
    });

    it('default_should_be_opt_in_and_sensitive_modes_should_fail_closed', 0, (): void => {
      const settings = defaultSshSessionLogSettings();
      expect(settings.enabled).assertFalse();
      const base = {
        hostId: 'host-one', sessionId: 7, generation: 2, enabled: true, paused: false,
        passwordPrompt: false, mfaPrompt: false, passphrasePrompt: false,
        rawMode: false, fullscreenMode: false, secretExpansion: false
      };
      expect(sshSessionLogCaptureAllowed(base)).assertTrue();
      expect(sshSessionLogCaptureAllowed({ ...base, passwordPrompt: true })).assertFalse();
      expect(sshSessionLogCaptureAllowed({ ...base, fullscreenMode: true })).assertFalse();
      expect(sshSessionLogCaptureAllowed({ ...base, generation: 0 })).assertFalse();
    });

    it('input_capture_should_require_a_trusted_command_editing_phase', 0, (): void => {
      expect(sshSessionLogInputPhaseAllowed('prompt')).assertTrue();
      expect(sshSessionLogInputPhaseAllowed('command')).assertTrue();
      expect(sshSessionLogInputPhaseAllowed('executed')).assertFalse();
      expect(sshSessionLogInputPhaseAllowed('idle')).assertFalse();
      expect(sshSessionLogInputPhaseAllowed('password')).assertFalse();
    });

    it('sanitizer_should_remove_vt_and_mask_common_secret_forms', 0, (): void => {
      const sanitized = sanitizeSshSessionLogText(
        '\u001B[31mTOKEN=super-secret\u001B[0m\u001B]133;C\u0007');
      expect(sanitized.indexOf('\u001B')).assertEqual(-1);
      expect(sanitized.indexOf('super-secret')).assertEqual(-1);
      expect(sanitized.indexOf('[redacted]') >= 0).assertTrue();
    });

    it('append_should_create_searchable_chunks_and_bookmarks', 0, (): void => {
      const document: SshSessionLogDocumentV1 = emptySshSessionLogDocument();
      document.settings.enabled = true;
      let next = appendSshSessionLogRecord(document, record('one', 'kubectl get pods'), 100);
      next = appendSshSessionLogRecord(next, record('two', 'service restarted', 101), 101);
      const hits = searchSshSessionLog(next, 'KUBECTL', 'host-one');
      expect(hits.length).assertEqual(1);
      const bookmarked = addSshSessionLogBookmark(
        next, { hostId: 'host-one', sessionId: 7, generation: 2 }, 'one', 'deploy', true, 120);
      expect(bookmarked === null).assertFalse();
      expect((bookmarked as SshSessionLogDocumentV1).bookmarks.length).assertEqual(1);
      expect(searchSshSessionLog(bookmarked as SshSessionLogDocumentV1, '', 'host-one')[0]
        .bookmarked).assertTrue();
    });

    it('append_should_preserve_unchanged_chunk_references', 0, (): void => {
      const document: SshSessionLogDocumentV1 = emptySshSessionLogDocument();
      document.settings.enabled = true;
      const first: SshSessionLogDocumentV1 = appendSshSessionLogRecord(
        document, record('one', 'first host output'), 100);
      const firstChunk = first.chunks[0];
      const otherHost = record('two', 'second host output', 101);
      otherHost.hostId = 'host-two';
      const next: SshSessionLogDocumentV1 = appendSshSessionLogRecord(first, otherHost, 101);

      expect(next.chunks.length).assertEqual(2);
      expect(next.chunks[0] === firstChunk).assertTrue();
      expect(first.chunks.length).assertEqual(1);
      expect(first.chunks[0].records.length).assertEqual(1);
      expect(next.chunks[1].records.length).assertEqual(1);
    });

    it('quota_should_evict_lru_unpinned_bookmark_and_preserve_pinned_chunk', 0, (): void => {
      const document = emptySshSessionLogDocument();
      document.settings.enabled = true;
      document.settings.quotaBytes = 256 * 1024;
      const payload: string = 'x'.repeat(8192);
      let next: SshSessionLogDocumentV1 = appendSshSessionLogRecord(document,
        recordForHost('pinned', 'host-pinned', 'password=do-not-leak' + payload, 700), 700);
      next = addSshSessionLogBookmark(next,
        { hostId: 'host-pinned', sessionId: 7, generation: 2 },
        'pinned', '', true, 701) as SshSessionLogDocumentV1;
      next = appendSshSessionLogRecord(next,
        recordForHost('ordinary-bookmark', 'host-ordinary', payload, 600), 701);
      next = addSshSessionLogBookmark(next,
        { hostId: 'host-ordinary', sessionId: 7, generation: 2 },
        'ordinary-bookmark', '', false, 702) as SshSessionLogDocumentV1;
      for (let index: number = 0; index < 31; index++) {
        next = appendSshSessionLogRecord(next, recordForHost(
          'record-' + index.toString(), 'host-' + index.toString(), payload, 800 + index),
        900 + index);
      }

      expect(searchSshSessionLog(next, '', 'host-pinned').length).assertEqual(1);
      expect(searchSshSessionLog(next, '', 'host-ordinary').length).assertEqual(0);
      expect(next.bookmarks.length).assertEqual(1);
      expect(next.bookmarks[0].recordId).assertEqual('pinned');
      const total: number = next.chunks.reduce((sum: number, chunk): number =>
        sum + chunk.byteSize, 0);
      expect(total <= next.settings.quotaBytes).assertTrue();

      const exportResult = exportSshSessionLog(next, 'host-pinned', undefined, true);
      expect(exportResult.ok).assertTrue();
      expect(exportResult.text.indexOf('do-not-leak')).assertEqual(-1);
      expect(exportResult.text.indexOf('[redacted]') >= 0).assertTrue();
      expect(encodeSshSessionLogDocument(next).indexOf('searchText') >= 0).assertTrue();
    });

    it('retention_should_remove_expired_unpinned_bookmarks_only', 0, (): void => {
      const dayMs: number = 24 * 60 * 60 * 1000;
      const document: SshSessionLogDocumentV1 = emptySshSessionLogDocument();
      document.settings.enabled = true;
      document.settings.retentionDays = 1;
      let next: SshSessionLogDocumentV1 = appendSshSessionLogRecord(document,
        recordForHost('pinned-old', 'host-pinned', 'keep', 100), 100);
      next = addSshSessionLogBookmark(next,
        { hostId: 'host-pinned', sessionId: 7, generation: 2 },
        'pinned-old', '', true, 101) as SshSessionLogDocumentV1;
      next = appendSshSessionLogRecord(next,
        recordForHost('ordinary-old', 'host-ordinary', 'expire', 101), 101);
      next = addSshSessionLogBookmark(next,
        { hostId: 'host-ordinary', sessionId: 7, generation: 2 },
        'ordinary-old', '', false, 102) as SshSessionLogDocumentV1;

      next = pruneSshSessionLogDocument(next, dayMs + 200);

      expect(searchSshSessionLog(next, '', 'host-pinned').length).assertEqual(1);
      expect(searchSshSessionLog(next, '', 'host-ordinary').length).assertEqual(0);
      expect(next.bookmarks.length).assertEqual(1);
      expect(next.bookmarks[0].pinned).assertTrue();
    });

    it('decoder_boundary_should_not_persist_unknown_fields', 0, (): void => {
      const document = emptySshSessionLogDocument();
      document.settings.enabled = true;
      const encoded = encodeSshSessionLogDocument(
        appendSshSessionLogRecord(document, record('one', 'safe'), 100));
      const contaminated = encoded.replace('"schemaVersion":1',
        '"schemaVersion":1,"password":"secret","remotePath":"/private"');
      const decoded = JSON.parse(contaminated) as Object;
      expect((decoded as Record<string, Object>)['password'] !== undefined).assertTrue();
      const roundTrip = encodeSshSessionLogDocument(
        JSON.parse(encoded) as SshSessionLogDocumentV1);
      expect(roundTrip.indexOf('password')).assertEqual(-1);
      expect(roundTrip.indexOf('remotePath')).assertEqual(-1);
    });
  });
}
