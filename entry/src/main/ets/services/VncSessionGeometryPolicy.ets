export interface VncFrameGeometry {
  width: number;
  height: number;
}

const VNC_FRAME_MIN_EDGE: number = 16;
const VNC_FRAME_MAX_EDGE: number = 32768;

/**
 * The RFB server's first accepted framebuffer update is authoritative.
 * Saved host display values are local presentation preferences and must not
 * be used as the VNC PointerEvent coordinate space.
 */
export function observedVncFrameGeometry(
  sessionActive: boolean, receivedFrames: number,
  observedWidth: number, observedHeight: number): VncFrameGeometry | null {
  if (!sessionActive || receivedFrames <= 0 ||
    !Number.isFinite(observedWidth) || !Number.isFinite(observedHeight)) {
    return null;
  }
  const width: number = Math.floor(observedWidth);
  const height: number = Math.floor(observedHeight);
  if (width < VNC_FRAME_MIN_EDGE || height < VNC_FRAME_MIN_EDGE ||
    width > VNC_FRAME_MAX_EDGE || height > VNC_FRAME_MAX_EDGE) {
    return null;
  }
  return { width, height };
}

export function shouldAdoptVncFrameGeometry(currentWidth: number, currentHeight: number,
  sessionActive: boolean, receivedFrames: number,
  observedWidth: number, observedHeight: number): boolean {
  const geometry: VncFrameGeometry | null = observedVncFrameGeometry(
    sessionActive, receivedFrames, observedWidth, observedHeight);
  return geometry !== null &&
    (geometry.width !== currentWidth || geometry.height !== currentHeight);
}
