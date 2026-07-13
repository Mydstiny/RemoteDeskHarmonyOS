/**
 * SshTerminalInputPolicy.test.ets - SSH 终端输入字节编码策略。
 */

import { describe, it, expect } from '@ohos/hypium';
import { KeyCode } from '@kit.InputKit';
import {
  TerminalModifierState,
  encodePhysicalKey,
  encodeSoftDelete,
  encodeSpecialKey,
  encodeTextInput
} from '../main/ets/services/SshTerminalInputPolicy';

const NONE: TerminalModifierState = { ctrl: false, alt: false, shift: false };
const CTRL: TerminalModifierState = { ctrl: true, alt: false, shift: false };
const ALT: TerminalModifierState = { ctrl: false, alt: true, shift: false };
const SHIFT: TerminalModifierState = { ctrl: false, alt: false, shift: true };
const ALT_SHIFT: TerminalModifierState = { ctrl: false, alt: true, shift: true };
const CTRL_SHIFT: TerminalModifierState = { ctrl: true, alt: false, shift: true };

export default function sshTerminalInputPolicyTest(): void {
  describe('SshTerminalInputPolicy', (): void => {
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

    it('should_request_refocus_after_tab_sequences', 0, (): void => {
      const tab = encodePhysicalKey({ keyCode: KeyCode.KEYCODE_TAB, unicode: undefined, ctrl: false, alt: false, shift: false });
      expect(tab.sequence).assertEqual('\t');
      expect(tab.refocusAfterTab).assertTrue();

      const shiftTab = encodePhysicalKey({ keyCode: KeyCode.KEYCODE_TAB, unicode: undefined, ctrl: false, alt: false, shift: true });
      expect(shiftTab.sequence).assertEqual('\u001b[Z');
      expect(shiftTab.refocusAfterTab).assertTrue();
    });
  });
}
