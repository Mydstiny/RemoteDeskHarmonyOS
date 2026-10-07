/**
 * Call right before starting an endless animation (animateTo or keyframeAnimateTo with iterations: -1).
 *
 * animateTo first flushes every state change still waiting for a frame, and animates those with its own parameters.
 * An endless decoration (a breathing glow, a turning glyph) started from a timer could thereby capture changes made
 * elsewhere a moment earlier and loop them for ever: on the tablet a session's 正在连接 cover and side handle kept fading
 * in and out together, in step with such a loop, after the session had connected. A zero-length animateTo applies those
 * pending changes at once, so the loop that follows carries only its own change.
 */
export function settleBeforeLoop(ui: UIContext): void {
  ui.animateTo({ duration: 0 }, (): void => {});
}
