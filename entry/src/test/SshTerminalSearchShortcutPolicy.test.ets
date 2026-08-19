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

function chord(key: 'F' | 'ENTER' | 'ESCAPE' | 'TAB' | 'OTHER',
  ctrl: boolean = false, shift: boolean = false): SshShortcutChord {
  return { key, ctrl, meta: false, alt: false, shift };
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
  });
}
