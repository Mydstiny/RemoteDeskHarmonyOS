/**
 * TwoFingerScrollPolicy.ets — 触控模式下的双指滚轮判定。
 *
 * 触控模式的画布上同时挂着 PinchGesture({ fingers: 2 })，同一组双指手势既
 * 可能是捏合缩放，也可能是滚动翻页。ArkUI 一旦判成捏合就会通过
 * canvasPinchInputConsumed 吞掉整条 touch 流，onTouch 再也收不到 Move，
 * 所以滚动必须在自己的 onTouch 里先一步认出来。
 *
 * 认出来之后还要认得住：手指在滑动过程中间距不可能纹丝不动，若每帧重新
 * 判定，一次抖动就会把手势让回给缩放，表现为滚一半突然开始缩放。因此
 * nextTwoFingerScrollLatch 只升不降，由调用方在手指全部抬起时复位。
 */

/** 重心每帧至少移动这么多 vp 才考虑滚动，避免双指静止时的抖动误判。 */
export const TWO_FINGER_SCROLL_MIN_STEP_VP: number = 0.6;

/**
 * 纵向位移要达到横向的这个倍数才算滚动。
 *
 * 双指横向滑动在很多远端应用里是"左右翻页/后退前进"，留给后续手势，
 * 这里只认纵向为主的滑动。
 */
export const TWO_FINGER_SCROLL_AXIS_RATIO: number = 1.4;

/** 两指间距每帧变化超过这么多 vp 就判定为捏合，不是滚动。 */
export const TWO_FINGER_SCROLL_MAX_SPREAD_STEP_VP: number = 3.0;

/** 两个触点之间的距离 (vp)。间距的逐帧变化量用来区分捏合与平移。 */
export function twoFingerSpreadVp(x0: number, y0: number,
  x1: number, y1: number): number {
  const dx: number = x1 - x0;
  const dy: number = y1 - y0;
  return Math.sqrt(dx * dx + dy * dy);
}

/**
 * 本帧的双指位移是否应该开始按滚轮处理。
 *
 * stepDx/stepDy 是两指重心相对上一帧的位移，spreadStepVp 是两指间距相对
 * 上一帧的变化量，单位都是 vp。
 */
export function shouldStartTwoFingerScroll(stepDx: number, stepDy: number,
  spreadStepVp: number): boolean {
  if (!Number.isFinite(stepDx) || !Number.isFinite(stepDy) ||
    !Number.isFinite(spreadStepVp)) {
    return false;
  }
  if (Math.abs(stepDy) < TWO_FINGER_SCROLL_MIN_STEP_VP) {
    return false;
  }
  // 间距在变 = 用户在捏合，这一帧不属于滚动。
  if (Math.abs(spreadStepVp) > TWO_FINGER_SCROLL_MAX_SPREAD_STEP_VP) {
    return false;
  }
  return Math.abs(stepDy) >= Math.abs(stepDx) * TWO_FINGER_SCROLL_AXIS_RATIO;
}

/**
 * 滚动锁存：认过一次就保持到手势结束。
 *
 * 调用方负责在所有手指抬起时把 active 复位成 false。
 */
export function nextTwoFingerScrollLatch(active: boolean, stepDx: number,
  stepDy: number, spreadStepVp: number): boolean {
  if (active) {
    return true;
  }
  return shouldStartTwoFingerScroll(stepDx, stepDy, spreadStepVp);
}
