/**
 * SshTerminalInputPolicy.test.ets - SSH 终端输入字节编码策略。
 */

import { describe, it, expect } from '@ohos/hypium';
import { KeyCode } from '@kit.InputKit';
import {
  TerminalModifierState,
  encodePhysicalKey,
  normalizeSshKeyCode,
  encodeSoftDelete,
  encodeSpecialKey,
  encodeTextInput,
  createSshImeCallbackState,
  recordSshImeWillInsert,
  consumeSshImeDidInsert,
  recordSshImeWillDelete,
  consumeSshImeDidDelete,
  inspectSshImeChange,
  resetSshImeShadow,
  sshTerminalInputByteLength,
  splitSshTerminalInputText
} from '../main/ets/services/SshTerminalInputPolicy';

const NONE: TerminalModifierState = { ctrl: false, alt: false, shift: false };
const CTRL: TerminalModifierState = { ctrl: true, alt: false, shift: false };
const ALT: TerminalModifierState = { ctrl: false, alt: true, shift: false };
const SHIFT: TerminalModifierState = { ctrl: false, alt: false, shift: true };
const ALT_SHIFT: TerminalModifierState = { ctrl: false, alt: true, shift: true };
const CTRL_SHIFT: TerminalModifierState = { ctrl: true, alt: false, shift: true };

export default function sshTerminalInputPolicyTest(): void {
  describe('SshTerminalInputPolicy', (): void => {
    it('should_measure_pending_input_as_native_utf8_bytes', 0, (): void => {
      expect(sshTerminalInputByteLength('ascii')).assertEqual(5);
      expect(sshTerminalInputByteLength('密码')).assertEqual(6);
      expect(sshTerminalInputByteLength('🙂')).assertEqual(4);
      expect(sshTerminalInputByteLength('\uD800')).assertEqual(3);
    });

    it('should_split_paste_without_separating_surrogate_pairs', 0, (): void => {
      const source: string = 'a'.repeat(4095) + '🙂b';
      const chunks: Array<string> = splitSshTerminalInputText(source, 4096);
      expect(chunks.length).assertEqual(2);
      expect(chunks[0].length).assertEqual(4095);
      expect(chunks[1]).assertEqual('🙂b');
      expect(chunks.join('')).assertEqual(source);

      const oneUnitChunks: Array<string> = splitSshTerminalInputText('🙂a', 1);
      expect(oneUnitChunks.length).assertEqual(2);
      expect(oneUnitChunks[0]).assertEqual('🙂');
      expect(oneUnitChunks[1]).assertEqual('a');
    });

    it('should_pass_soft_keyboard_committed_text_through', 0, (): void => {
      expect(encodeTextInput('ls -la', NONE)).assertEqual('ls -la');
      expect(encodeTextInput('中文😀', NONE)).assertEqual('中文😀');
    });

    it('should_apply_virtual_modifiers_only_to_single_printable_ascii_text', 0, (): void => {
      expect(encodeTextInput('a', SHIFT)).assertEqual('A');
      expect(encodeTextInput('1', ALT_SHIFT)).assertEqual('\u001b!');
      expect(encodeTextInput('a', CTRL_SHIFT)).assertEqual('\u0001');
      expect(encodeTextInput('x', CTRL)).assertEqual('\u0018');
      expect(encodeTextInput('[', CTRL)).assertEqual('\u001b');
      expect(encodeTextInput('x', ALT)).assertEqual('\u001bx');
      expect(encodeTextInput('中文', CTRL)).assertEqual('中文');
    });

    it('should_encode_soft_delete_by_deleted_character_count', 0, (): void => {
      expect(encodeSoftDelete('')).assertEqual('\u007f');
      expect(encodeSoftDelete('ab')).assertEqual('\u007f\u007f');
      expect(encodeSoftDelete('😀')).assertEqual('\u007f');
    });

    it('should_encode_navigation_and_editing_special_keys', 0, (): void => {
      expect(encodeSpecialKey(KeyCode.KEYCODE_DPAD_UP, NONE)).assertEqual('\u001b[A');
      expect(encodeSpecialKey(KeyCode.KEYCODE_DPAD_DOWN, NONE)).assertEqual('\u001b[B');
      expect(encodeSpecialKey(KeyCode.KEYCODE_DPAD_LEFT, NONE)).assertEqual('\u001b[D');
      expect(encodeSpecialKey(KeyCode.KEYCODE_DPAD_RIGHT, NONE)).assertEqual('\u001b[C');
      expect(encodeSpecialKey(KeyCode.KEYCODE_MOVE_HOME, NONE)).assertEqual('\u001b[H');
      expect(encodeSpecialKey(KeyCode.KEYCODE_MOVE_END, NONE)).assertEqual('\u001b[F');
      expect(encodeSpecialKey(KeyCode.KEYCODE_INSERT, NONE)).assertEqual('\u001b[2~');
      expect(encodeSpecialKey(KeyCode.KEYCODE_FORWARD_DEL, NONE)).assertEqual('\u001b[3~');
      expect(encodeSpecialKey(KeyCode.KEYCODE_PAGE_UP, NONE)).assertEqual('\u001b[5~');
      expect(encodeSpecialKey(KeyCode.KEYCODE_PAGE_DOWN, NONE)).assertEqual('\u001b[6~');
    });

    it('should_encode_modified_terminal_special_keys', 0, (): void => {
      expect(encodeSpecialKey(KeyCode.KEYCODE_TAB, SHIFT)).assertEqual('\u001b[Z');
      expect(encodeSpecialKey(KeyCode.KEYCODE_DPAD_LEFT, CTRL)).assertEqual('\u001b[1;5D');
      expect(encodeSpecialKey(KeyCode.KEYCODE_DPAD_RIGHT, ALT)).assertEqual('\u001b[1;3C');
      expect(encodeSpecialKey(KeyCode.KEYCODE_MOVE_HOME, CTRL_SHIFT)).assertEqual('\u001b[1;6H');
    });

    it('should_encode_application_cursor_and_keypad_modes', 0, (): void => {
      expect(encodeSpecialKey(KeyCode.KEYCODE_DPAD_UP, NONE, true, false)).assertEqual('\u001bOA');
      expect(encodeSpecialKey(KeyCode.KEYCODE_NUMPAD_7, NONE, false, true)).assertEqual('\u001bOw');
      expect(encodeSpecialKey(KeyCode.KEYCODE_NUMPAD_ENTER, NONE, false, true)).assertEqual('\u001bOM');
    });

    it('should_encode_function_keys_and_numpad_keys', 0, (): void => {
      expect(encodeSpecialKey(KeyCode.KEYCODE_F1, NONE)).assertEqual('\u001bOP');
      expect(encodeSpecialKey(KeyCode.KEYCODE_F4, NONE)).assertEqual('\u001bOS');
      expect(encodeSpecialKey(KeyCode.KEYCODE_F5, NONE)).assertEqual('\u001b[15~');
      expect(encodeSpecialKey(KeyCode.KEYCODE_F12, NONE)).assertEqual('\u001b[24~');
      expect(encodeSpecialKey(KeyCode.KEYCODE_F5, CTRL)).assertEqual('\u001b[15;5~');
      expect(encodeSpecialKey(KeyCode.KEYCODE_NUMPAD_ENTER, NONE)).assertEqual('\r');
      expect(encodeSpecialKey(KeyCode.KEYCODE_NUMPAD_ADD, NONE)).assertEqual('+');
      expect(encodeSpecialKey(KeyCode.KEYCODE_NUMPAD_LEFT_PAREN, NONE)).assertEqual('(');
    });

    it('should_encode_physical_backspace_on_all_device_modes', 0, (): void => {
      expect(encodePhysicalKey({ keyCode: KeyCode.KEYCODE_DEL, unicode: undefined, ctrl: false, alt: false, shift: false }).sequence)
        .assertEqual('\u007f');
    });

    it('should_encode_physical_printable_ctrl_alt_and_space', 0, (): void => {
      expect(encodePhysicalKey({ keyCode: KeyCode.KEYCODE_A, unicode: 97, ctrl: true, alt: false, shift: false }).sequence)
        .assertEqual('\u0001');
      expect(encodePhysicalKey({ keyCode: KeyCode.KEYCODE_1, unicode: 49, ctrl: false, alt: true, shift: true }).sequence)
        .assertEqual('\u001b!');
      expect(encodePhysicalKey({ keyCode: KeyCode.KEYCODE_SPACE, unicode: undefined, ctrl: true, alt: false, shift: false }).sequence)
        .assertEqual('\u0000');
      expect(encodePhysicalKey({ keyCode: KeyCode.KEYCODE_X, unicode: 120, ctrl: false, alt: true, shift: false }).sequence)
        .assertEqual('\u001bx');
    });

    it('should_consume_unicode_physical_text_without_ime', 0, (): void => {
      const cjk = encodePhysicalKey({
        keyCode: KeyCode.KEYCODE_A, unicode: 0x4E2D, ctrl: false, alt: false, shift: false
      });
      expect(cjk.consume).assertTrue();
      expect(cjk.sequence).assertEqual('中');
      const emoji = encodePhysicalKey({
        keyCode: KeyCode.KEYCODE_A, unicode: 0x1F600, ctrl: false, alt: false, shift: false
      });
      expect(emoji.sequence).assertEqual('😀');
    });

    it('should_use_keycode_fallback_when_physical_unicode_is_missing', 0, (): void => {
      const plain = encodePhysicalKey({
        keyCode: KeyCode.KEYCODE_A, unicode: undefined, ctrl: false, alt: false, shift: false,
        allowKeyCodeFallback: true
      });
      expect(plain.consume).assertTrue();
      expect(plain.sequence).assertEqual('a');
      const caps = encodePhysicalKey({
        keyCode: KeyCode.KEYCODE_A, unicode: undefined, ctrl: false, alt: false, shift: false,
        capsLock: true, allowKeyCodeFallback: true
      });
      expect(caps.sequence).assertEqual('A');
    });

    it('should_normalize_android_compatible_external_keycodes', 0, (): void => {
      expect(normalizeSshKeyCode(29)).assertEqual(KeyCode.KEYCODE_A);
      expect(normalizeSshKeyCode(66)).assertEqual(KeyCode.KEYCODE_ENTER);
      expect(normalizeSshKeyCode(67)).assertEqual(KeyCode.KEYCODE_DEL);
      expect(normalizeSshKeyCode(19)).assertEqual(KeyCode.KEYCODE_DPAD_UP);
      expect(encodePhysicalKey({
        keyCode: 29, unicode: undefined, ctrl: false, alt: false, shift: false,
        allowKeyCodeFallback: true
      }).sequence).assertEqual('a');
      expect(encodePhysicalKey({
        keyCode: 66, unicode: undefined, ctrl: false, alt: false, shift: false,
        allowKeyCodeFallback: true
      }).sequence).assertEqual('\r');
    });

    it('should_keep_altgr_composed_unicode_as_text', 0, (): void => {
      expect(encodePhysicalKey({
        keyCode: KeyCode.KEYCODE_2, unicode: 0x40, ctrl: true, alt: true, shift: false,
        altGraph: true
      }).sequence).assertEqual('@');
    });

    it('should_request_refocus_after_tab_sequences', 0, (): void => {
      const tab = encodePhysicalKey({ keyCode: KeyCode.KEYCODE_TAB, unicode: undefined, ctrl: false, alt: false, shift: false });
      expect(tab.sequence).assertEqual('\t');
      expect(tab.refocusAfterTab).assertTrue();

      const shiftTab = encodePhysicalKey({ keyCode: KeyCode.KEYCODE_TAB, unicode: undefined, ctrl: false, alt: false, shift: true });
      expect(shiftTab.sequence).assertEqual('\u001b[Z');
      expect(shiftTab.refocusAfterTab).assertTrue();
    });

    it('should_commit_ime_insert_once_after_will_and_did_callbacks', 0, (): void => {
      const state = createSshImeCallbackState();
      expect(recordSshImeWillInsert(state, 'ni')).assertTrue();
      const preview = inspectSshImeChange(state, 'ni', 2);
      expect(preview.updateShadow).assertTrue();
      expect(preview.sendRemote).assertFalse();
      expect(preview.resetLocal).assertFalse();
      expect(consumeSshImeDidInsert(state, '你')).assertEqual('你');
      expect(consumeSshImeDidInsert(state, '你')).assertEqual('');
      const duplicateChange = inspectSshImeChange(state, '你', 0);
      expect(duplicateChange.sendRemote).assertFalse();
      expect(duplicateChange.resetLocal).assertTrue();
    });

    it('should_drop_cumulative_change_after_did_insert_and_clear_editor', 0, (): void => {
      const state = createSshImeCallbackState();
      expect(recordSshImeWillInsert(state, 'p')).assertTrue();
      expect(consumeSshImeDidInsert(state, 'p')).assertEqual('p');
      // API 23 may expose the stale previous editor value together with this
      // commit. "p" was already sent by onDidInsert, so "np" is local state.
      const cumulative = inspectSshImeChange(state, 'np', 0);
      expect(cumulative.sendRemote).assertFalse();
      expect(cumulative.remoteInsert).assertEqual('');
      expect(cumulative.resetLocal).assertTrue();
      resetSshImeShadow(state, 'np');
      const emptyReset = inspectSshImeChange(state, '', 0);
      expect(emptyReset.sendRemote).assertFalse();
    });

    it('should_strip_line_breaks_from_ime_commit', 0, (): void => {
      const state = createSshImeCallbackState();
      expect(recordSshImeWillInsert(state, '候选')).assertTrue();
      expect(consumeSshImeDidInsert(state, '第一行\r\n第二行')).assertEqual('第一行第二行');
    });

    it('should_commit_ime_delete_once_and_keep_change_local', 0, (): void => {
      const state = createSshImeCallbackState();
      expect(recordSshImeWillDelete(state, '字')).assertTrue();
      expect(consumeSshImeDidDelete(state, '字')).assertEqual('字');
      expect(consumeSshImeDidDelete(state, '字')).assertEqual(null);
      const change = inspectSshImeChange(state, '', 0);
      expect(change.updateShadow).assertTrue();
      expect(change.sendRemote).assertFalse();
      expect(change.resetLocal).assertFalse();
    });

    it('should_not_reset_or_send_while_ime_preview_is_active', 0, (): void => {
      const state = createSshImeCallbackState();
      expect(recordSshImeWillInsert(state, '拼音')).assertTrue();
      const decision = inspectSshImeChange(state, '拼音', 2);
      expect(decision.sendRemote).assertFalse();
      expect(decision.resetLocal).assertFalse();
    });

    it('should_fallback_commit_non_system_ime_change_once', 0, (): void => {
      const state = createSshImeCallbackState();
      const committed = inspectSshImeChange(state, '你😀', 0);
      expect(committed.sendRemote).assertTrue();
      expect(committed.remoteInsert).assertEqual('你😀');
      expect(committed.remoteDelete).assertEqual('');
      const duplicate = inspectSshImeChange(state, '你😀', 0);
      expect(duplicate.sendRemote).assertFalse();
    });

    it('should_strip_line_breaks_from_ime_diff_and_keep_paste_text', 0, (): void => {
      const state = createSshImeCallbackState();
      const committed = inspectSshImeChange(state, '第一行\r\n第二行', 0);
      expect(committed.sendRemote).assertTrue();
      expect(committed.remoteInsert).assertEqual('第一行第二行');
      const duplicate = inspectSshImeChange(state, '第一行\r\n第二行', 0);
      expect(duplicate.sendRemote).assertFalse();
      expect(encodeTextInput('第一行\r\n第二行', NONE)).assertEqual('第一行\r\n第二行');
    });

    it('should_allow_the_same_character_after_editor_reset', 0, (): void => {
      const state = createSshImeCallbackState();
      resetSshImeShadow(state, 'x');
      const resetChange = inspectSshImeChange(state, '', 0);
      expect(resetChange.sendRemote).assertFalse();
      const repeated = inspectSshImeChange(state, 'x', 0);
      expect(repeated.sendRemote).assertTrue();
      expect(repeated.remoteInsert).assertEqual('x');
    });

    it('should_ignore_preview_then_send_only_committed_candidate', 0, (): void => {
      const state = createSshImeCallbackState();
      // Third-party IMEs may omit onWill/onDid while still reporting preview
      // metadata through onChange.
      const preview = inspectSshImeChange(state, 'ni', 2);
      expect(preview.sendRemote).assertFalse();
      const committed = inspectSshImeChange(state, '你', 0);
      expect(committed.sendRemote).assertTrue();
      expect(committed.remoteInsert).assertEqual('你');
    });

    it('should_fallback_when_on_change_precedes_missing_did_insert', 0, (): void => {
      const state = createSshImeCallbackState();
      expect(recordSshImeWillInsert(state, 'a')).assertTrue();
      const committed = inspectSshImeChange(state, 'a', 0);
      expect(committed.sendRemote).assertTrue();
      expect(committed.remoteInsert).assertEqual('a');
      // A late onDidInsert must not duplicate the fallback commit.
      expect(consumeSshImeDidInsert(state, 'a')).assertEqual('');
    });

    it('should_replace_local_preview_with_committed_candidate', 0, (): void => {
      const state = createSshImeCallbackState();
      expect(recordSshImeWillInsert(state, 'ni')).assertTrue();
      const preview = inspectSshImeChange(state, 'ni', 2);
      expect(preview.sendRemote).assertFalse();
      const committed = inspectSshImeChange(state, '你', 0);
      expect(committed.sendRemote).assertTrue();
      expect(committed.remoteInsert).assertEqual('你');
      expect(committed.remoteDelete).assertEqual('');
    });
  });
}
