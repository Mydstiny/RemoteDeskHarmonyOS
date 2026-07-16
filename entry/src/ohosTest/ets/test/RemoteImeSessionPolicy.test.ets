/**
 * RemoteImeSessionPolicy.test.ets - 系统 IME 影子会话策略
 */
import { describe, it, expect } from '@ohos/hypium';
import {
  REMOTE_IME_CENTER,
  REMOTE_IME_MAX_CARET_MOVEMENT,
  REMOTE_IME_PREVIEW_ENABLED,
  RemoteImeSelectionAction,
  createRemoteImeDiagnostic,
  createRemoteImeShadow,
  resolveRemoteImeDelete,
  resolveRemoteImeSelection,
  shouldResetRemoteImeOnPointerDown,
  shouldAcceptRemoteImeTextChange,
  shouldCloseRemoteImeSessionOnEditChange,
  shouldRecenterRemoteImeShadow,
  shouldWaitForRemoteImeInput,
  splitRemoteImeCaretMovement
} from '../../../main/ets/services/RemoteImeSessionPolicy';

export default function remoteImeSessionPolicyTest(): void {
  describe('RemoteImeSessionPolicy', (): void => {
    it('creates_bounded_shadow_around_center', 0, (): void => {
      const shadow = createRemoteImeShadow();
      expect(shadow.caret).assertEqual(REMOTE_IME_CENTER);
      expect(shadow.text.length).assertEqual(REMOTE_IME_CENTER * 2);
    });

    it('disables_preview_text_for_remote_virtual_keyboard', 0, (): void => {
      expect(REMOTE_IME_PREVIEW_ENABLED).assertFalse();
    });

    it('does_not_rebind_shadow_while_preview_text_is_active', 0, (): void => {
      expect(shouldAcceptRemoteImeTextChange(true, 4)).assertFalse();
      expect(shouldAcceptRemoteImeTextChange(true, 0)).assertTrue();
      expect(shouldAcceptRemoteImeTextChange(false, 0)).assertFalse();
    });

    it('keeps_session_open_for_initial_editing_false_transition', 0, (): void => {
      expect(shouldCloseRemoteImeSessionOnEditChange(true, false, false)).assertFalse();
      expect(shouldCloseRemoteImeSessionOnEditChange(true, false, true)).assertTrue();
      expect(shouldCloseRemoteImeSessionOnEditChange(true, false, true, true)).assertFalse();
      expect(shouldCloseRemoteImeSessionOnEditChange(true, true, false)).assertFalse();
      expect(shouldCloseRemoteImeSessionOnEditChange(false, false, true)).assertFalse();
    });

    it('ignores_expected_and_programmatic_selection', 0, (): void => {
      const expected = resolveRemoteImeSelection({
        active: true,
        programmatic: false,
        initialSelectionPending: false,
        expectedStart: 2050,
        expectedEnd: 2050,
        syncedCaret: 2048,
        selectionStart: 2050,
        selectionEnd: 2050
      });
      expect(expected.action).assertEqual(RemoteImeSelectionAction.IGNORE_EXPECTED);
      expect(expected.consumeExpected).assertTrue();

      const programmatic = resolveRemoteImeSelection({
        active: true,
        programmatic: true,
        initialSelectionPending: false,
        expectedStart: -1,
        expectedEnd: -1,
        syncedCaret: 2048,
        selectionStart: 2048,
        selectionEnd: 2048
      });
      expect(programmatic.action).assertEqual(RemoteImeSelectionAction.IGNORE_PROGRAMMATIC);

      const expandedProgrammatic = resolveRemoteImeSelection({
        active: true,
        programmatic: true,
        initialSelectionPending: false,
        expectedStart: -1,
        expectedEnd: -1,
        syncedCaret: 2048,
        selectionStart: 2030,
        selectionEnd: 2048
      });
      expect(expandedProgrammatic.action).assertEqual(RemoteImeSelectionAction.IGNORE_PROGRAMMATIC);
      expect(expandedProgrammatic.count).assertEqual(0);
    });

    it('ignores_initial_shadow_selection_without_remote_movement', 0, (): void => {
      const initial = resolveRemoteImeSelection({
        active: true,
        programmatic: false,
        initialSelectionPending: true,
        expectedStart: 2048,
        expectedEnd: 2048,
        syncedCaret: 2048,
        selectionStart: 4096,
        selectionEnd: 4096
      });
      expect(initial.action).assertEqual(RemoteImeSelectionAction.IGNORE_INITIAL);
      expect(initial.count).assertEqual(0);
      expect(initial.consumeInitial).assertTrue();
    });

    it('converts_collapsed_selection_to_relative_movement', 0, (): void => {
      const left = resolveRemoteImeSelection({
        active: true,
        programmatic: false,
        initialSelectionPending: false,
        expectedStart: -1,
        expectedEnd: -1,
        syncedCaret: 2048,
        selectionStart: 2035,
        selectionEnd: 2035
      });
      expect(left.action).assertEqual(RemoteImeSelectionAction.MOVE_LEFT);
      expect(left.count).assertEqual(13);
      expect(left.nextSyncedCaret).assertEqual(2035);

      const right = resolveRemoteImeSelection({
        active: true,
        programmatic: false,
        initialSelectionPending: false,
        expectedStart: -1,
        expectedEnd: -1,
        syncedCaret: 2035,
        selectionStart: 2042,
        selectionEnd: 2042
      });
      expect(right.action).assertEqual(RemoteImeSelectionAction.MOVE_RIGHT);
      expect(right.count).assertEqual(7);
    });

    it('does_not_flood_remote_control_queue_for_large_selection_jump', 0, (): void => {
      const result = resolveRemoteImeSelection({
        active: true,
        programmatic: false,
        initialSelectionPending: false,
        expectedStart: -1,
        expectedEnd: -1,
        syncedCaret: REMOTE_IME_CENTER,
        selectionStart: 0,
        selectionEnd: 0
      });
      expect(REMOTE_IME_MAX_CARET_MOVEMENT).assertEqual(32);
      expect(result.action).assertEqual(RemoteImeSelectionAction.COLLAPSE_LOCAL);
      expect(result.count).assertEqual(0);
    });

    it('does_not_translate_expanded_selection', 0, (): void => {
      const result = resolveRemoteImeSelection({
        active: true,
        programmatic: false,
        initialSelectionPending: false,
        expectedStart: -1,
        expectedEnd: -1,
        syncedCaret: 2048,
        selectionStart: 2038,
        selectionEnd: 2048
      });
      expect(result.action).assertEqual(RemoteImeSelectionAction.COLLAPSE_LOCAL);
      expect(result.count).assertEqual(0);
      expect(result.nextSyncedCaret).assertEqual(2048);
    });

    it('does_not_move_when_ime_session_is_inactive', 0, (): void => {
      const result = resolveRemoteImeSelection({
        active: false,
        programmatic: false,
        initialSelectionPending: false,
        expectedStart: -1,
        expectedEnd: -1,
        syncedCaret: 2048,
        selectionStart: 2000,
        selectionEnd: 2000
      });
      expect(result.action).assertEqual(RemoteImeSelectionAction.IGNORE_INACTIVE);
      expect(result.count).assertEqual(0);
    });

    it('chunks_large_movement_without_losing_count', 0, (): void => {
      const chunks = splitRemoteImeCaretMovement(700, 256);
      expect(chunks.length).assertEqual(3);
      expect(chunks[0]).assertEqual(256);
      expect(chunks[1]).assertEqual(256);
      expect(chunks[2]).assertEqual(188);
    });

    it('maps_delete_direction_and_recenter_threshold', 0, (): void => {
      expect(resolveRemoteImeDelete(0, 'abc'.length).backwardCount).assertEqual(3);
      expect(resolveRemoteImeDelete(0, 'abc'.length).forwardCount).assertEqual(0);
      expect(resolveRemoteImeDelete(1, 'x'.length).backwardCount).assertEqual(0);
      expect(resolveRemoteImeDelete(1, 'x'.length).forwardCount).assertEqual(1);
      expect(shouldRecenterRemoteImeShadow(255, 4096)).assertTrue();
      expect(shouldRecenterRemoteImeShadow(2048, 4096)).assertFalse();
      expect(shouldRecenterRemoteImeShadow(3841, 4096)).assertTrue();
    });

    it('keeps_remote_ime_commands_until_input_is_ready', 0, (): void => {
      expect(shouldWaitForRemoteImeInput(true, 7, false)).assertTrue();
      expect(shouldWaitForRemoteImeInput(false, 7, false)).assertFalse();
      expect(shouldWaitForRemoteImeInput(true, 0, false)).assertFalse();
      expect(shouldWaitForRemoteImeInput(true, 7, true)).assertFalse();
    });

    it('does_not_reset_active_ime_on_pointer_down', 0, (): void => {
      expect(shouldResetRemoteImeOnPointerDown(true)).assertFalse();
      expect(shouldResetRemoteImeOnPointerDown(false)).assertTrue();
    });

    it('creates_privacy_safe_diagnostics_without_input_text', 0, (): void => {
      const diagnostic = createRemoteImeDiagnostic('selection', 13, 2048, 2035, 'move-left');
      expect(diagnostic.source).assertEqual('selection');
      expect(diagnostic.units).assertEqual(13);
      expect(diagnostic.oldCaret).assertEqual(2048);
      expect(diagnostic.newCaret).assertEqual(2035);
      expect(diagnostic.delta).assertEqual(-13);
      expect(diagnostic.result).assertEqual('move-left');
    });
  });
}
