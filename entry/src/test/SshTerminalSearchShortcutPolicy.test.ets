import { describe, it, expect } from '@ohos/hypium';
import {
  createSshTerminalSearchRequest,
  decodeSshTerminalSearchRequest,
  decodeSshTerminalSearchResult,
  defaultSshTerminalSearchOptions,
  encodeSshTerminalSearchRequest,
  sshTerminalSearchResultLabel,
  SshTerminalSearchOptions,
  validateSshTerminalSearchQuery
} from '../main/ets/services/ssh/search/SshTerminalSearchPolicy';
import {
  findSshShortcutConflict,
  normalizeSshShortcutChord,
  routeSshShortcut,
  SshShortcutBinding,
  SshShortcutChord,
  SshShortcutContext
} from '../main/ets/services/ssh/shortcut/SshShortcutPolicy';

function chord(key: 'F' | 'F6' | 'J' | 'T' | 'W' | 'DIGIT' | 'ENTER' | 'ESCAPE' | 'TAB' | 'OTHER',
  ctrl: boolean = false, shift: boolean = false, alt: boolean = false,
  digit: number = -1): SshShortcutChord {
  return { key, ctrl, meta: false, alt, shift, digit };
}

function context(searchOpen: boolean = false): SshShortcutContext {
  return {
    modalOpen: false,
    searchOpen,
    textEditorFocused: false,
    terminalFocused: !searchOpen,
    terminalSearchEnabled: true
  };
}

export default function sshTerminalSearchShortcutPolicyTest(): void {
  describe('SshTerminalSearchShortcutPolicy', (): void => {
    it('validates_empty_long_and_invalid_regex_queries', 0, (): void => {
      const options: SshTerminalSearchOptions = defaultSshTerminalSearchOptions();
      expect(validateSshTerminalSearchQuery('', options).errorCode).assertEqual('empty_query');
      expect(validateSshTerminalSearchQuery('x'.repeat(513), options).errorCode)
        .assertEqual('query_too_long');
      options.regex = true;
      expect(validateSshTerminalSearchQuery('[', options).errorCode).assertEqual('invalid_regex');
      expect(validateSshTerminalSearchQuery('^ok$', options).valid).assertTrue();
    });

    it('encodes_only_valid_search_requests', 0, (): void => {
      const options: SshTerminalSearchOptions = defaultSshTerminalSearchOptions();
      options.caseSensitive = true;
      const request = createSshTerminalSearchRequest(7, 'Error', 'previous', options);
      expect(request !== null).assertTrue();
      expect(encodeSshTerminalSearchRequest(request!).indexOf('Error') > 0).assertTrue();
      expect(createSshTerminalSearchRequest(0, 'x', 'next', options)).assertNull();
    });

    it('decodes_only_whitelisted_search_bridge_requests', 0, (): void => {
      const decoded = decodeSshTerminalSearchRequest(JSON.stringify({
        requestId: 3,
        query: 'fatal',
        direction: 'next',
        options: { caseSensitive: false, wholeWord: true, regex: false },
        password: 'must-not-cross-bridge'
      }));
      expect(decoded !== null).assertTrue();
      expect(JSON.stringify(decoded).indexOf('password')).assertEqual(-1);
      expect(decodeSshTerminalSearchRequest(JSON.stringify({
        requestId: 3,
        query: 'fatal',
        direction: 'sideways',
        options: { caseSensitive: false, wholeWord: true, regex: false }
      }))).assertNull();
    });

    it('decodes_double_encoded_results_and_rejects_stale_ids', 0, (): void => {
      const raw: string = JSON.stringify(JSON.stringify({
        requestId: 8,
        found: true,
        resultIndex: 1,
        resultCount: 3,
        elapsedMs: 4.24,
        errorCode: ''
      }));
      const result = decodeSshTerminalSearchResult(raw, 8);
      expect(result.found).assertTrue();
      expect(result.resultIndex).assertEqual(1);
      expect(result.elapsedMs).assertEqual(4.2);
      expect(sshTerminalSearchResultLabel(result)).assertEqual('2 / 3');
      expect(decodeSshTerminalSearchResult(raw, 9).errorCode).assertEqual('stale_result');
    });

    it('routes_search_before_terminal_and_never_sends_search_text_remote', 0, (): void => {
      expect(routeSshShortcut(chord('F', true), context()).action)
        .assertEqual('open_terminal_search');
      expect(routeSshShortcut(chord('ENTER'), context(true)).action).assertEqual('search_next');
      expect(routeSshShortcut(chord('ENTER', false, true), context(true)).action)
        .assertEqual('search_previous');
      expect(routeSshShortcut(chord('OTHER'), context(true)).action)
        .assertEqual('let_text_editor_handle');
    });

    it('leaves_terminal_reserved_chords_and_shift_tab_on_existing_paths', 0, (): void => {
      expect(routeSshShortcut(chord('OTHER', true), context()).action)
        .assertEqual('send_to_terminal');
      const escape = routeSshShortcut(chord('TAB', false, true), context());
      expect(escape.action).assertEqual('escape_terminal_focus');
      expect(escape.consume).assertFalse();
    });

    it('keeps_modal_and_text_editor_priority_above_terminal', 0, (): void => {
      const modal: SshShortcutContext = context();
      modal.modalOpen = true;
      expect(routeSshShortcut(chord('F', true), modal).action).assertEqual('let_modal_handle');
      const editor: SshShortcutContext = context();
      editor.textEditorFocused = true;
      expect(routeSshShortcut(chord('F', true), editor).action)
        .assertEqual('let_text_editor_handle');
    });

    it('cycles_workspace_regions_with_f6_without_forwarding_it_to_the_terminal', 0,
      (): void => {
        const workspace: SshShortcutContext = context();
        workspace.workspaceShortcutsEnabled = true;
        workspace.focusCycleEnabled = true;
        workspace.captureGlobalShortcuts = false;
        expect(routeSshShortcut(chord('F6'), workspace).action)
          .assertEqual('focus_next_region');
        expect(routeSshShortcut(chord('F6', false, true), workspace).action)
          .assertEqual('focus_previous_region');

        const modal: SshShortcutContext = context();
        modal.workspaceShortcutsEnabled = true;
        modal.modalOpen = true;
        expect(routeSshShortcut(chord('F6'), modal).action).assertEqual('let_modal_handle');
      });

    it('detects_same_scope_conflicts_but_allows_other_scopes', 0, (): void => {
      const existing: SshShortcutBinding = {
        actionId: 'terminal.search', scope: 'workspace', chord: chord('F', true)
      };
      const conflict: SshShortcutBinding = {
        actionId: 'palette.open', scope: 'workspace', chord: chord('F', true)
      };
      const otherScope: SshShortcutBinding = {
        actionId: 'palette.open', scope: 'editor', chord: chord('F', true)
      };
      expect(normalizeSshShortcutChord(existing.chord)).assertEqual('ctrl+f');
      expect(findSshShortcutConflict([existing], conflict).conflict).assertTrue();
      expect(findSshShortcutConflict([existing], otherScope).conflict).assertFalse();
    });

    it('captures_workspace_shortcuts_only_when_the_profile_allows_terminal_takeover', 0,
      (): void => {
        const safeTerminal: SshShortcutContext = context();
        safeTerminal.workspaceShortcutsEnabled = true;
        safeTerminal.captureGlobalShortcuts = false;
        safeTerminal.tabCount = 3;
        expect(routeSshShortcut(chord('J', true), safeTerminal).action)
          .assertEqual('send_to_terminal');
        expect(routeSshShortcut(chord('W', true), safeTerminal).action)
          .assertEqual('send_to_terminal');

        const captured: SshShortcutContext = context();
        captured.workspaceShortcutsEnabled = true;
        captured.captureGlobalShortcuts = true;
        captured.tabCount = 3;
        expect(routeSshShortcut(chord('J', true), captured).action)
          .assertEqual('open_command_palette');
        expect(routeSshShortcut(chord('T', true), captured).action)
          .assertEqual('open_new_session_picker');
        expect(routeSshShortcut(chord('W', true), captured).action)
          .assertEqual('close_active_tab');
        const third = routeSshShortcut(chord('DIGIT', false, false, true, 3), captured);
        expect(third.action).assertEqual('activate_tab_index');
        expect(third.tabIndex).assertEqual(2);
      });

    it('lets_the_workspace_use_navigation_shortcuts_after_terminal_focus_exits', 0,
      (): void => {
        const workspace: SshShortcutContext = context();
        workspace.terminalFocused = false;
        workspace.workspaceShortcutsEnabled = true;
        workspace.captureGlobalShortcuts = false;
        workspace.tabCount = 2;
        expect(routeSshShortcut(chord('J', true), workspace).action)
          .assertEqual('open_command_palette');
        expect(routeSshShortcut(chord('DIGIT', false, false, true, 2), workspace).tabIndex)
          .assertEqual(1);
        expect(routeSshShortcut(chord('DIGIT', false, false, true, 3), workspace).action)
          .assertEqual('none');
      });
  });
}
