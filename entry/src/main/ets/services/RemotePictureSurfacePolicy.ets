/**
 * 多个画面会话同时存在（平板分屏、PC 多窗口）时的画面归属。
 *
 * 原生层有一份进程级的 XComponent 画面（setXComponentSurfaceId / markXComponentSurfaceDestroyed）。同一时间只能属于一个
 * 会话页面：另一个页面再绑定或标记它，会让前一个页面的渲染器整体失效。所以第一个画面页面照旧使用进程级画面；在它之后、
 * 它仍在时打开的页面改为直接画到自己 XComponent 的 SurfaceId 上，并且从不碰进程级画面。
 */
export type RemotePictureSurfaceMode = 'unset' | 'process' | 'own';

/** The mode a page gets when it first needs its surface, given the page currently holding the process surface. */
export function pictureSurfaceModeForClaim(holderPageSeq: number, pageSeq: number): RemotePictureSurfaceMode {
  return holderPageSeq <= 0 || holderPageSeq === pageSeq ? 'process' : 'own';
}

/** A renderer on the page's own surface needs that SurfaceId before it starts, as the VNC renderer always did. */
export function rendererNeedsOwnSurfaceId(isVnc: boolean, mode: RemotePictureSurfaceMode): boolean {
  return isVnc || mode === 'own';
}

/** Process-wide: every session window lives in this process, so one holder is shared by all of them. */
export class RemotePictureSurfaceClaims {
  private static holderPageSeq: number = 0;

  static claim(pageSeq: number): RemotePictureSurfaceMode {
    const mode: RemotePictureSurfaceMode =
      pictureSurfaceModeForClaim(RemotePictureSurfaceClaims.holderPageSeq, pageSeq);
    if (mode === 'process') {
      RemotePictureSurfaceClaims.holderPageSeq = pageSeq;
    }
    return mode;
  }

  /** The holder's page went away; the next page to open uses the process surface again. */
  static release(pageSeq: number): void {
    if (RemotePictureSurfaceClaims.holderPageSeq === pageSeq) {
      RemotePictureSurfaceClaims.holderPageSeq = 0;
    }
  }
}
