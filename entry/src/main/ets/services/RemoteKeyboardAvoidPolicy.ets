/**
 * RemoteKeyboardAvoidPolicy.ets — 软键盘弹出时的画布让位计算。
 *
 * ArkUI 的页面级键盘避让只会整体上移信箱式画布，它不知道远端输入光标在哪，
 * 光标落在画面下部时照样被键盘挡住。这里按实际遮挡量算让位。
 */

/** 判定"被键盘挡住"时，输入光标下方要保留的余量 (vp)。 */
export const KEYBOARD_CARET_MARGIN_VP: number = 24;

/**
 * 被挡住时，把光标送到可见区高度的这个比例处。
 *
 * 0.5 = 可见区正中，和官方客户端 `_moveToCenterCursor()` 的落点一致。只按最小
 * 遮挡量上移的话，光标会紧贴键盘顶边，输入框在贴近任务栏时仍然看不全。
 */
const CARET_TARGET_RATIO: number = 0.5;

/**
 * 计算画布还需要额外上移多少像素，才能让远端输入光标舒服地露出来。
 *
 * caretLocalYPx / surfaceHeightPx / keyboardHeightPx 都是当前渲染表面的像素。
 * caretLocalYPx 是在**当前已经上移过**的画面里量到的，所以返回的是增量，
 * 调用方累加到既有偏移上；线性关系保证一步收敛，不会来回震荡。
 *
 * 只上移、不下移：光标本来就在可见区里就完全不动，避免键盘一弹画面就乱跳。
 */
export function keyboardCanvasLiftDeltaPx(caretLocalYPx: number, surfaceHeightPx: number,
  keyboardHeightPx: number, marginPx: number): number {
  if (!(surfaceHeightPx > 0) || keyboardHeightPx <= 0) {
    return 0;
  }
  const visibleBottomPx: number = surfaceHeightPx - keyboardHeightPx;
  if (visibleBottomPx <= 0) {
    return 0;
  }
  if (caretLocalYPx + marginPx <= visibleBottomPx) {
    return 0;
  }
  const targetPx: number = visibleBottomPx * CARET_TARGET_RATIO;
  const deltaPx: number = caretLocalYPx - targetPx;
  return deltaPx > 0 ? deltaPx : 0;
}

/** 让位量的上限：把画面最底部的光标送到目标位置所需的量，再多就只是拉出黑边。 */
export function maxKeyboardCanvasLiftPx(surfaceHeightPx: number, keyboardHeightPx: number): number {
  const visibleBottomPx: number = surfaceHeightPx - keyboardHeightPx;
  if (!(surfaceHeightPx > 0) || visibleBottomPx <= 0) {
    return 0;
  }
  return surfaceHeightPx - visibleBottomPx * CARET_TARGET_RATIO;
}
