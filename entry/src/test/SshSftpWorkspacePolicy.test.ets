import { describe, it, expect } from '@ohos/hypium';
import {
  activateSshSftpSurface,
  activateSshTerminalSurface,
  closeSshSftpWorkspaceTab,
  createSshSftpWorkspaceTabState,
  openSshSftpWorkspaceTab,
  planSshSftpExternalDrop,
  resolveSshSftpPresentation,
  resolveSshSftpPaneLayout,
  sshSftpDropRecordCountAllowed,
  SshSftpDropItem,
  SshSftpWorkspaceTabState
} from '../main/ets/services/ssh/sftp/SshSftpWorkspacePolicy';

function file(name: string, size: number): SshSftpDropItem {
  return {
    uri: 'file:///sandbox/' + name,
    name,
    size,
    isDirectory: false,
    isSymbolicLink: false,
    isSpecialFile: false,
    readable: true
  };
}

export default function sshSftpWorkspacePolicyTest(): void {
  describe('SshSftpWorkspacePolicy', (): void => {
    it('opens_switches_and_closes_one_sftp_surface_without_session_identity', 0, (): void => {
      const empty: SshSftpWorkspaceTabState = createSshSftpWorkspaceTabState();
      const opened: SshSftpWorkspaceTabState = openSshSftpWorkspaceTab(empty, 'host-a');
      expect(opened.open).assertTrue();
      expect(opened.activeSurface).assertEqual('sftp');
      expect(opened.tabId.startsWith('sftp:')).assertTrue();
      const terminal: SshSftpWorkspaceTabState = activateSshTerminalSurface(opened);
      expect(terminal.activeSurface).assertEqual('terminal');
      expect(activateSshSftpSurface(terminal, 'host-b')).assertEqual(terminal);
      expect(activateSshSftpSurface(terminal, 'host-a').activeSurface).assertEqual('sftp');
      expect(closeSshSftpWorkspaceTab(opened).open).assertFalse();
    });

    it('degrades_a_360vp_pc_to_single_pane_without_changing_phone_semantics', 0, (): void => {
      expect(resolveSshSftpPaneLayout(360, 'pc').mode).assertEqual('single');
      expect(resolveSshSftpPaneLayout(900, 'pc').mode).assertEqual('dual');
      expect(resolveSshSftpPaneLayout(900, 'pad').mode).assertEqual('dual');
      expect(resolveSshSftpPaneLayout(1200, 'phone').mode).assertEqual('single');
    });

    it('keeps_pc_sftp_in_a_centered_sheet_with_workbench_enabled', 0, (): void => {
      expect(resolveSshSftpPresentation(true, true)).assertEqual('sheet');
      expect(resolveSshSftpPresentation(false, true)).assertEqual('sheet');
      expect(resolveSshSftpPresentation(true, false)).assertEqual('workspace');
      expect(resolveSshSftpPresentation(false, false)).assertEqual('sheet');
    });

    it('accepts_bounded_multi_file_drop_and_requires_explicit_conflict_confirmation', 0,
      (): void => {
        const plan = planSshSftpExternalDrop([file('a.txt', 10), file('b.txt', 20)],
          'ssh', true, true, { maxItems: 10, maxSingleFileBytes: 100, maxTotalBytes: 1000 });
        expect(plan.accepted).assertTrue();
        expect(plan.itemCount).assertEqual(2);
        expect(plan.totalBytes).assertEqual(30);
        expect(plan.requiresConflictConfirmation).assertTrue();
        expect(plan.actionLabel).assertEqual('上传到远端目录');
      });

    it('fails_closed_for_permissions_links_special_files_and_size_limits', 0, (): void => {
      const denied: SshSftpDropItem = file('denied', 1);
      denied.readable = false;
      expect(planSshSftpExternalDrop([denied], 'ssh', true, false,
        { maxItems: 1, maxSingleFileBytes: 10, maxTotalBytes: 10 }).reason)
        .assertEqual('permission-denied');
      const link: SshSftpDropItem = file('link', 1);
      link.isSymbolicLink = true;
      expect(planSshSftpExternalDrop([link], 'ssh', true, false,
        { maxItems: 1, maxSingleFileBytes: 10, maxTotalBytes: 10 }).reason)
        .assertEqual('unsupported-file-type');
      expect(planSshSftpExternalDrop([file('large', 11)], 'ssh', true, false,
        { maxItems: 1, maxSingleFileBytes: 10, maxTotalBytes: 20 }).reason)
        .assertEqual('single-file-limit');
      expect(planSshSftpExternalDrop([file('a', 6), file('b', 6)], 'ssh', true, false,
        { maxItems: 2, maxSingleFileBytes: 10, maxTotalBytes: 10 }).reason)
        .assertEqual('total-size-limit');
    });

    it('rejects_oversized_record_sets_before_external_uri_work', 0, (): void => {
      expect(sshSftpDropRecordCountAllowed(64, 64)).assertTrue();
      expect(sshSftpDropRecordCountAllowed(65, 64)).assertFalse();
      expect(sshSftpDropRecordCountAllowed(2, Number.NaN)).assertFalse();
    });
  });
}
