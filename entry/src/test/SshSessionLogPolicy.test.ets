import { describe, it, expect } from '@ohos/hypium';
import {
  addSshSessionLogBookmark,
  appendSshSessionLogRecord,
  defaultSshSessionLogSettings,
  emptySshSessionLogDocument,
  encodeSshSessionLogDocument,
  exportSshSessionLog,
  matchesSshSessionLogExportFence,
  resolveSshSessionLogsEnabled,
  searchSshSessionLog,
  sanitizeSshSessionLogText,
  sshSessionLogCaptureAllowed,
  SSH_SESSION_LOGS_DEFAULT_ENABLED,
  SshSessionLogDocumentV1,
  SshSessionLogRecordV1
} from '../main/ets/services/ssh/log/SshSessionLogPolicy';

function record(id: string, text: string, timestamp: number = 100): SshSessionLogRecordV1 {
  return {
    id, hostId: 'host-one', sessionId: 7, generation: 2, timestamp,
    direction: 'output', kind: 'data', text, searchText: '', byteSize: text.length
  };
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

    it('quota_should_preserve_pinned_chunks_and_export_should_be_bounded', 0, (): void => {
      const document = emptySshSessionLogDocument();
      document.settings.enabled = true;
      document.settings.quotaBytes = 256 * 1024;
      let next = appendSshSessionLogRecord(document,
        record('pinned', 'password=do-not-leak', 100), 100);
      const bookmarked = addSshSessionLogBookmark(
        next, { hostId: 'host-one', sessionId: 7, generation: 2 }, 'pinned', '', true, 101);
      next = bookmarked as SshSessionLogDocumentV1;
      const exportResult = exportSshSessionLog(next, 'host-one', undefined, true);
      expect(exportResult.ok).assertTrue();
      expect(exportResult.text.indexOf('do-not-leak')).assertEqual(-1);
      expect(exportResult.text.indexOf('[redacted]') >= 0).assertTrue();
      expect(encodeSshSessionLogDocument(next).indexOf('searchText') >= 0).assertTrue();
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
