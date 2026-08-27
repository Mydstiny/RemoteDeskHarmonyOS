export const REMOTE_SURFACE_RESIZE_FRAME_MS: number = 16;
export const REMOTE_SURFACE_RESIZE_SETTLE_MS: number = 120;

export interface RemoteSurfaceResizeGeometry {
  revision: number;
  widthVp: number;
  heightVp: number;
  widthPx: number;
  heightPx: number;
}

export interface RemoteSurfaceResizeObservation {
  accepted: boolean;
  geometry: RemoteSurfaceResizeGeometry | null;
}

function validDimension(value: number): boolean {
  return Number.isFinite(value) && value > 0;
}

function sameGeometry(left: RemoteSurfaceResizeGeometry | null,
  widthVp: number, heightVp: number, widthPx: number, heightPx: number): boolean {
  return left !== null && Math.abs(left.widthVp - widthVp) < 1 &&
    Math.abs(left.heightVp - heightVp) < 1 &&
    Math.abs(left.widthPx - widthPx) < 1 &&
    Math.abs(left.heightPx - heightPx) < 1;
}

function copyGeometry(value: RemoteSurfaceResizeGeometry): RemoteSurfaceResizeGeometry {
  return {
    revision: value.revision,
    widthVp: value.widthVp,
    heightVp: value.heightVp,
    widthPx: value.widthPx,
    heightPx: value.heightPx
  };
}

/**
 * Keeps ArkUI's latest XComponent geometry while allowing the page to drain
 * it once per display interval. WindowManager may emit several intermediate
 * sizes during snap/maximize; intermediate observations replace pending work
 * instead of running synchronous native and overlay layout for every callback.
 */
export class RemoteSurfaceResizeCoordinator {
  private revision: number = 0;
  private latest: RemoteSurfaceResizeGeometry | null = null;
  private appliedRevision: number = 0;

  observe(widthVp: number, heightVp: number,
    widthPx: number, heightPx: number): RemoteSurfaceResizeObservation {
    if (!validDimension(widthVp) || !validDimension(heightVp) ||
      !validDimension(widthPx) || !validDimension(heightPx)) {
      return { accepted: false, geometry: null };
    }
    if (sameGeometry(this.latest, widthVp, heightVp, widthPx, heightPx)) {
      return { accepted: false, geometry: null };
    }
    this.revision += 1;
    this.latest = {
      revision: this.revision,
      widthVp,
      heightVp,
      widthPx,
      heightPx
    };
    return { accepted: true, geometry: copyGeometry(this.latest) };
  }

  takeLatestForFrame(): RemoteSurfaceResizeGeometry | null {
    if (this.latest === null || this.latest.revision === this.appliedRevision) {
      return null;
    }
    this.appliedRevision = this.latest.revision;
    return copyGeometry(this.latest);
  }

  isLatest(revision: number): boolean {
    return this.latest !== null && revision > 0 && this.latest.revision === revision;
  }

  reset(): void {
    this.revision = 0;
    this.latest = null;
    this.appliedRevision = 0;
  }
}
