import { CanvasTransform, CanvasViewport, clampCanvasTransform,
  RDP_CANVAS_FREE_PAN_INSET_RATIO } from '../RemoteCanvasTransformPolicy';
import { RdpRenderStats, RendererViewport } from '../../types/rdpnapi';
import { ProConnectionView } from './ProConnectionEnvelope';

function positiveSize(value: number): boolean {
  return Number.isFinite(value) && value > 0 && value <= 32768;
}

export function proRdpInputMode(value: number): string {
  return value === 0 ? 'touchpad' : value === 1 ? 'direct' : value === 2 ? 'keyboardMouse' : '';
}
export function proRdpInputModeValue(value: string): number {
  return value === 'touchpad' ? 0 : value === 'direct' ? 1 : value === 'keyboardMouse' ? 2 : -1;
}

export function describeProRdpView(transform: CanvasTransform, inputMode: number): ProConnectionView | null {
  const mode = proRdpInputMode(inputMode);
  if (mode === '' || !Number.isFinite(transform.scale) || transform.scale < 0.1 || transform.scale > 12 ||
      !Number.isFinite(transform.panX) || Math.abs(transform.panX) > 100000 ||
      !Number.isFinite(transform.panY) || Math.abs(transform.panY) > 100000 ||
      (transform.rotation !== undefined && transform.rotation !== 0)) { return null; }
  // Current RDP adapter negotiates exactly one display. Never claim that a
  // reserved monitor index or a RustDesk-only canvas rotation was restored.
  return { sshPane: 'terminal', sshDirectory: '', monitor: 0, scale: transform.scale,
    panX: transform.panX, panY: transform.panY, inputMode: mode,
    strictBounds: transform.strictContentBounds === true };
}

export function restoreProRdpView(view: ProConnectionView, viewport: CanvasViewport): CanvasTransform | null {
  if (view.monitor !== 0 || typeof view.strictBounds !== 'boolean' ||
      proRdpInputModeValue(view.inputMode) < 0 ||
      !positiveSize(viewport.sourceWidth) || !positiveSize(viewport.sourceHeight) ||
      !positiveSize(viewport.surfaceWidth) || !positiveSize(viewport.surfaceHeight)) { return null; }
  const transform: CanvasTransform = { scale: view.scale, panX: view.panX, panY: view.panY,
    rotation: 0, strictContentBounds: view.strictBounds };
  if (describeProRdpView(transform, proRdpInputModeValue(view.inputMode)) === null) { return null; }
  const target: CanvasViewport = { sourceWidth: viewport.sourceWidth, sourceHeight: viewport.sourceHeight,
    surfaceWidth: viewport.surfaceWidth, surfaceHeight: viewport.surfaceHeight,
    freePanInsetRatio: RDP_CANVAS_FREE_PAN_INSET_RATIO };
  return clampCanvasTransform(transform, target);
}

export function proRdpPresentedViewReady(stats: RdpRenderStats, viewport: RendererViewport | null,
  requiredVersion: number): boolean {
  return viewport !== null && Number.isSafeInteger(requiredVersion) && requiredVersion > 0 &&
    Number.isSafeInteger(viewport.transformVersion) && viewport.transformVersion === requiredVersion &&
    viewport.presentedTransformVersion === viewport.transformVersion &&
    positiveSize(viewport.sourceWidth) && positiveSize(viewport.sourceHeight) &&
    positiveSize(viewport.surfaceWidth) && positiveSize(viewport.surfaceHeight) &&
    stats.desktopWidth === viewport.sourceWidth && stats.desktopHeight === viewport.sourceHeight &&
    Number.isFinite(stats.renderedPaintCount) && stats.renderedPaintCount > 0 &&
    stats.inputGeometryReady && !stats.desktopResizeInProgress &&
    !stats.displayLayoutPending && !stats.displayLayoutInFlight;
}
