/**
 * 多个画面会话同时存在（平板分屏、PC 多窗口）时的画面归属。
 *
 * 原生层有一份进程级的 XComponent 画面（setXComponentSurfaceId / markXComponentSurfaceDestroyed）。同一时间只能属于一个
 * 会话页面：另一个页面再绑定或标记它，会让前一个页面的渲染器整体失效。所以第一个画面页面照旧使用进程级画面；在它之后、
 * 它仍在时打开的页面改为直接画到自己 XComponent 的 SurfaceId 上，并且从不碰进程级画面。
 */
export type RemotePictureSurfaceMode = 'unset' | 'process' | 'own';

/** The mode a page gets when it first needs its surface, given the page currently holding the process surface
 * (the native claim applies the same rule process-wide). */
export function pictureSurfaceModeForClaim(holderPageSeq: number, pageSeq: number): RemotePictureSurfaceMode {
  return holderPageSeq <= 0 || holderPageSeq === pageSeq ? 'process' : 'own';
}

/** A renderer on the page's own surface needs that SurfaceId before it starts, as the VNC renderer always did. */
export function rendererNeedsOwnSurfaceId(isVnc: boolean, mode: RemotePictureSurfaceMode): boolean {
  return isVnc || mode === 'own';
}

/**
 * A page's claim token: unique across every window of the process (each session window has its own ArkTS module
 * instances, so page numbers repeat; the holder itself lives in native code, see claimProcessSurface).
 */
export function pictureSurfaceClaimToken(nowMs: number, random: number): number {
  return Math.floor(nowMs) * 1000 + Math.floor(Math.max(0, Math.min(random, 0.999)) * 1000) + 1;
}
