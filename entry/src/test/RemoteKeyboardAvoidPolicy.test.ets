import { describe, it, expect } from '@ohos/hypium';
import {
  keyboardCanvasLiftDeltaPx,
  maxKeyboardCanvasLiftPx
} from '../main/ets/services/RemoteKeyboardAvoidPolicy';

export default function remoteKeyboardAvoidPolicyTest() {
  describe('RemoteKeyboardAvoidPolicy', () => {
    it('lifts_only_when_the_caret_is_behind_the_keyboard', 0, () => {
      // 光标在可见区内，不需要让位。
      expect(keyboardCanvasLiftDeltaPx(200, 1000, 400, 20)).assertEqual(0);
      // 正好卡在余量边界上，不再动。
      expect(keyboardCanvasLiftDeltaPx(580, 1000, 400, 20)).assertEqual(0);
      // 被挡住时送到可见区中部 (600/2=300)：700 - 300 = 400。
      expect(keyboardCanvasLiftDeltaPx(700, 1000, 400, 20)).assertEqual(400);
    });

    it('lifts_enough_for_a_caret_sitting_on_the_taskbar', 0, () => {
      // 输入框贴着任务栏：光标几乎在画面最底部，最小上移只能让它紧贴键盘顶边，
      // 看不全输入区；送到可见区中部才够用。
      const lift: number = keyboardCanvasLiftDeltaPx(990, 1000, 400, 20);
      expect(lift).assertEqual(690);
      // 上移后光标落在 300，正好是可见区 600 的中部。
      expect(990 - lift).assertEqual(300);
    });

    it('never_lifts_without_a_keyboard_or_a_surface', 0, () => {
      expect(keyboardCanvasLiftDeltaPx(700, 1000, 0, 20)).assertEqual(0);
      expect(keyboardCanvasLiftDeltaPx(700, 0, 400, 20)).assertEqual(0);
      // 键盘比画面还高时不做无意义的位移。
      expect(keyboardCanvasLiftDeltaPx(700, 400, 400, 20)).assertEqual(0);
    });

    it('converges_in_one_step_because_the_delta_is_measured_on_the_shifted_frame', 0, () => {
      // 第一次量到 caret 在 700，上移之后再量应该已经在可见区里 → 增量归零，
      // 不会来回震荡。
      const first: number = keyboardCanvasLiftDeltaPx(700, 1000, 400, 20);
      expect(keyboardCanvasLiftDeltaPx(700 - first, 1000, 400, 20)).assertEqual(0);
    });

    it('caps_the_lift_at_what_a_bottom_edge_caret_needs', 0, () => {
      // 可见区 600，目标落点 300 → 最底部的光标最多需要 1000-300=700。
      expect(maxKeyboardCanvasLiftPx(1000, 400)).assertEqual(700);
      expect(maxKeyboardCanvasLiftPx(1000, 0)).assertEqual(1000);
      expect(maxKeyboardCanvasLiftPx(400, 400)).assertEqual(0);
      expect(maxKeyboardCanvasLiftPx(0, 400)).assertEqual(0);
    });
  });
}
