import { expect } from '@ohos/hypium';
import { auditedDescribe as describe, auditedIt as it } from '../main/ets/services/FocusedTestRegistrationAudit';
import {
  RemoteShortcutContext,
  remoteShortcutActionsForContext,
  resolveShortcutAction,
  resolveRustDeskKeyboardLayout,
  migrateVncKeyboardLayout,
  remoteShortcutKeyCodes,
  vncShortcutHostStorageKey,
  vncShortcutSessionStorageKey,
  vncShortcutMigrationStorageKey,
  vncShortcutLegacyHostStorageKey,
  vncShortcutLegacyMigrationAllowed
} from '../main/ets/services/RemoteShortcutPolicy';

function context(protocol: 'rdp' | 'rustdesk' | 'vnc' | 'ssh'): RemoteShortcutContext {
  return {
    protocol,
    sessionId: 11,
    generation: 4,
    connected: true,
    viewOnly: false,
    canSendKeys: true,
    canSendText: true,
    clipboardEnabled: true,
    remotePlatform: 'windows',
    sessionLayout: 'unknown',
    isPreconnect: false,
    bracketedPaste: false,
    pasteTextBytes: 0
  };
}

export default function remoteShortcutPolicyTest(): void {
  describe('RemoteShortcutCatalog_protocol_matrix', (): void => {
    it('rdp_exposes_copy_cut_paste_with_fixed_windows_ctrl', 0, (): void => {
      const actions = remoteShortcutActionsForContext(context('rdp'));
      expect(actions[0].id).assertEqual('copy');
      expect(actions[1].id).assertEqual('cut');
      expect(actions[2].id).assertEqual('pasteShortcut');
      expect(actions[0].subtitle).assertEqual('Ctrl+C');
      expect(remoteShortcutKeyCodes(actions[0])[0]).assertEqual(2072);
      expect(remoteShortcutKeyCodes(actions[0])[1]).assertEqual(2019);
      expect(resolveShortcutAction('pasteShortcut', context('rdp')).enabled).assertTrue();
    });

    it('keeps_utility_sequences_in_catalog_not_surface_literals', 0, (): void => {
      const actions = remoteShortcutActionsForContext(context('rdp'));
      let found: boolean = false;
      for (let index = 0; index < actions.length; index++) {
        if (actions[index].id === 'ctrlShiftEsc') {
          found = true;
          expect(actions[index].subtitle).assertEqual('Ctrl+Shift+Esc');
          expect(remoteShortcutKeyCodes(actions[index]).length).assertEqual(3);
        }
      }
      expect(found).assertTrue();
    });

    it('rustdesk_peer_info_wins_and_pro_hint_is_preconnect_only', 0, (): void => {
      expect(resolveRustDeskKeyboardLayout('macos', 'windows', 'windows', true)).assertEqual('command');
      expect(resolveRustDeskKeyboardLayout('', 'macos', 'windows', true)).assertEqual('command');
      expect(resolveRustDeskKeyboardLayout('', 'macos', 'windows', false)).assertEqual('ctrl');
      expect(resolveRustDeskKeyboardLayout('', '', 'macos', false)).assertEqual('command');
      expect(resolveRustDeskKeyboardLayout('', '', '', false)).assertEqual('unknown');
    });

    it('rustdesk_does_not_promote_local_layout_to_peer_platform', 0, (): void => {
      const rustdesk = context('rustdesk');
      rustdesk.remotePlatform = 'macos';
      rustdesk.peerInfoPlatform = '';
      rustdesk.sessionChoice = 'unknown';
      const action = resolveShortcutAction('copy', rustdesk);
      expect(action.layout).assertEqual('unknown');
      expect(action.accessibilityText).assertEqual('复制，Ctrl+C');
    });

    it('rustdesk_unknown_peer_requires_explicit_remote_choice_not_local_keyboard_state', 0, (): void => {
      const rustdesk = context('rustdesk');
      rustdesk.remotePlatform = 'unknown';
      rustdesk.peerInfoPlatform = '';
      rustdesk.sessionChoice = 'unknown';
      expect(resolveRustDeskKeyboardLayout('', '', 'unknown', false)).assertEqual('unknown');
      expect(resolveShortcutAction('copy', rustdesk).accessibilityText).assertEqual('复制，Ctrl+C');
    });

    it('vnc_unknown_layout_is_explicitly_presented_as_ctrl', 0, (): void => {
      expect(migrateVncKeyboardLayout(undefined)).assertEqual('ctrl');
      expect(migrateVncKeyboardLayout('legacy-unknown')).assertEqual('ctrl');
      const vnc = context('vnc');
      vnc.remotePlatform = 'macos';
      vnc.sessionLayout = 'command';
      expect(resolveShortcutAction('copy', vnc).subtitle).assertEqual('Command+C');
      vnc.sessionLayout = 'unknown';
      vnc.remotePlatform = 'unknown';
      expect(resolveShortcutAction('copy', vnc).subtitle).assertEqual('Ctrl+C');
    });

    it('ssh_exposes_control_bytes_and_separates_local_copy_paste', 0, (): void => {
      const actions = remoteShortcutActionsForContext(context('ssh'));
      expect(actions[0].id).assertEqual('terminalCtrlC');
      expect(actions[1].id).assertEqual('terminalCtrlV');
      expect(actions[2].id).assertEqual('terminalCtrlX');
      expect(resolveShortcutAction('terminalCtrlC', context('ssh')).terminalByte).assertEqual(0x03);
      expect(resolveShortcutAction('terminalCtrlV', context('ssh')).terminalByte).assertEqual(0x16);
      expect(resolveShortcutAction('terminalCtrlX', context('ssh')).terminalByte).assertEqual(0x18);
      expect(resolveShortcutAction('terminalCopySelection', context('ssh')).kind).assertEqual('local');
      expect(resolveShortcutAction('pasteLocalText', context('ssh')).kind).assertEqual('local-text');
    });

    it('view_only_disables_remote_input_but_keeps_local_copy', 0, (): void => {
      const vnc = context('vnc');
      vnc.viewOnly = true;
      expect(resolveShortcutAction('copy', vnc).enabled).assertFalse();
      const ssh = context('ssh');
      ssh.viewOnly = true;
      expect(resolveShortcutAction('terminalCopySelection', ssh).enabled).assertTrue();
      expect(resolveShortcutAction('terminalCtrlC', ssh).enabled).assertFalse();
      expect(resolveShortcutAction('pasteLocalText', ssh).enabled).assertFalse();
    });

    it('clipboard_sync_off_only_blocks_local_text_paste', 0, (): void => {
      const rdp = context('rdp');
      rdp.clipboardEnabled = false;
      expect(resolveShortcutAction('copy', rdp).enabled).assertTrue();
      expect(resolveShortcutAction('cut', rdp).enabled).assertTrue();
      expect(resolveShortcutAction('pasteShortcut', rdp).enabled).assertTrue();
      expect(resolveShortcutAction('pasteLocalText', rdp).enabled).assertFalse();
    });

    it('vnc_storage_keys_are_host_and_generation_scoped', 0, (): void => {
      const hostA = vncShortcutHostStorageKey('host-a', 'account-a');
      const hostB = vncShortcutHostStorageKey('host-b', 'account-a');
      expect(hostA.indexOf('vncShortcutLayout:v3:') === 0).assertTrue();
      expect(hostA.indexOf('account-a') < 0).assertTrue();
      expect(hostA === hostB).assertFalse();
      expect(vncShortcutSessionStorageKey('host-a', 7, 'account-a').indexOf(
        'vncShortcutSessionLayout:v3:') === 0).assertTrue();
      expect(vncShortcutSessionStorageKey('host-a', 8, 'account-a') ===
        vncShortcutSessionStorageKey('host-a', 7, 'account-a')).assertFalse();
      expect(vncShortcutSessionStorageKey('host-b', 7, 'account-a') ===
        vncShortcutSessionStorageKey('host-a', 7, 'account-a')).assertFalse();
      expect(vncShortcutSessionStorageKey('host-a', 7, 'account-b') ===
        vncShortcutSessionStorageKey('host-a', 7, 'account-a')).assertFalse();
      expect(vncShortcutMigrationStorageKey('host-a', 'account-a').indexOf(
        'vncShortcutLayoutMigrated:v3:') === 0).assertTrue();

      // v2 replacement tokens collided (`a/b` and `a_b`).  v3 encodes every
      // UTF-16 code unit and keeps account and host boundaries distinct.
      expect(vncShortcutHostStorageKey('a/b', 'account-a') ===
        vncShortcutHostStorageKey('a_b', 'account-a')).assertFalse();
      expect(vncShortcutHostStorageKey('主机', '账户') ===
        vncShortcutHostStorageKey('主机_', '账户')).assertFalse();
      expect(vncShortcutHostStorageKey('host-a', 'account-a') ===
        vncShortcutHostStorageKey('host-a', 'account-b')).assertFalse();
      expect(vncShortcutLegacyHostStorageKey('host-a', 'account-a'))
        .assertEqual('vncShortcutLayout:v2:account-a:host-a');
    });

    it('never_migrates_unowned_global_or_cross_owner_legacy_layout', 0, (): void => {
      expect(vncShortcutLegacyMigrationAllowed('host-a', 'account-a', '', '')).assertFalse();
      expect(vncShortcutLegacyMigrationAllowed('host-a', 'account-a', 'host-a', '')).assertFalse();
      expect(vncShortcutLegacyMigrationAllowed('host-a', 'account-a', 'host-b', 'account-a')).assertFalse();
      expect(vncShortcutLegacyMigrationAllowed('host-a', 'account-a', 'host-a', 'account-a')).assertTrue();
      expect(vncShortcutLegacyMigrationAllowed('a/b', 'account-a', 'a/b', 'account-a')).assertFalse();
      expect(vncShortcutLegacyMigrationAllowed('主机', '账户', '主机', '账户')).assertFalse();
    });

    it('disconnect_and_stale_generation_do_not_resolve', 0, (): void => {
      const disconnected = context('rdp');
      disconnected.connected = false;
      expect(resolveShortcutAction('copy', disconnected).enabled).assertFalse();
      const stale = context('rdp');
      stale.generation = 0;
      expect(resolveShortcutAction('copy', stale).enabled).assertFalse();
    });
  });
}
