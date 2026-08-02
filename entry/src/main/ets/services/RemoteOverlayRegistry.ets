import { OverlayPlacement, OverlayRect } from './RemoteOverlayViewportPolicy';

interface OverlayRegistryEntry {
  ownerId: string;
  generation: number;
  /** Instance/measurement fence inside one session generation. */
  measurementToken: string;
  placement: OverlayPlacement | null;
  rects: Array<OverlayRect>;
}

/**
 * Session-scoped overlay ownership and generation fence.
 * A late onAreaChange/avoid-area callback cannot publish after its owner has
 * been replaced or disconnected.
 */
export class RemoteOverlayRegistry {
  private entries: Array<OverlayRegistryEntry> = [];

  private findEntry(ownerId: string): OverlayRegistryEntry | null {
    for (let index = 0; index < this.entries.length; index++) {
      if (this.entries[index].ownerId === ownerId) { return this.entries[index]; }
    }
    return null;
  }

  /**
   * Start (or restart) one concrete renderer/overlay instance.  A token is
   * deliberately separate from the session generation: an old UI instance
   * can receive a late onAreaChange after a same-generation relayout.
   */
  begin(ownerId: string, generation: number, measurementToken: string = ''): boolean {
    if (ownerId.trim().length === 0 || generation < 0 || measurementToken.trim().length === 0) {
      return false;
    }
    const existing: OverlayRegistryEntry | null = this.findEntry(ownerId);
    if (existing === null) {
      this.entries.push({ ownerId, generation, measurementToken, placement: null, rects: [] });
      return true;
    }
    if (generation < existing.generation) {
      return false;
    }
    if (generation === existing.generation && existing.measurementToken.length > 0 &&
      measurementToken.length > 0 && measurementToken === existing.measurementToken) {
      // Same instance may publish a fresh measurement; its token remains the
      // owner fence while its previous geometry is replaced.
      existing.placement = null;
      existing.rects = [];
      return true;
    }
    existing.generation = generation;
    existing.measurementToken = measurementToken;
    existing.placement = null;
    existing.rects = [];
    return true;
  }

  acceptPlacement(ownerId: string, generation: number, placement: OverlayPlacement,
    measurementToken: string = ''): boolean {
    const existing: OverlayRegistryEntry | null = this.findEntry(ownerId);
    if (existing === null || existing.generation !== generation ||
      placement.generation !== generation ||
      measurementToken.trim().length === 0 ||
      (existing.measurementToken.length > 0 && existing.measurementToken !== measurementToken)) {
      return false;
    }
    existing.placement = placement;
    existing.rects = [placement.railRect];
    if (placement.menuRect.width > 0 && placement.menuRect.height > 0) {
      existing.rects.push(placement.menuRect);
    }
    return true;
  }

  /** Register a measured auxiliary overlay without inventing a placement. */
  acceptRects(ownerId: string, generation: number, rects: Array<OverlayRect>,
    measurementToken: string = ''): boolean {
    const existing: OverlayRegistryEntry | null = this.findEntry(ownerId);
    if (existing === null || existing.generation !== generation ||
      measurementToken.trim().length === 0 ||
      (existing.measurementToken.length > 0 && existing.measurementToken !== measurementToken)) {
      return false;
    }
    existing.placement = null;
    existing.rects = rects.slice(0);
    return true;
  }

  /** Update a renderer's measured rail bounds without discarding its menu placement. */
  acceptMeasuredRect(ownerId: string, generation: number, measurementToken: string,
    rect: OverlayRect): boolean {
    const existing: OverlayRegistryEntry | null = this.findEntry(ownerId);
    if (existing === null || existing.generation !== generation ||
      measurementToken.trim().length === 0 ||
      (existing.measurementToken.length > 0 && existing.measurementToken !== measurementToken)) {
      return false;
    }
    if (existing.placement !== null) {
      if (existing.rects.length === 0) {
        existing.rects.push(rect);
      } else {
        existing.rects[0] = rect;
      }
    } else {
      existing.rects = [rect];
    }
    return true;
  }

  currentGeneration(ownerId: string): number {
    const existing: OverlayRegistryEntry | null = this.findEntry(ownerId);
    return existing === null ? -1 : existing.generation;
  }

  currentMeasurementToken(ownerId: string): string {
    const existing: OverlayRegistryEntry | null = this.findEntry(ownerId);
    return existing === null ? '' : existing.measurementToken;
  }

  clearOwner(ownerId: string): void {
    for (let index = this.entries.length - 1; index >= 0; index--) {
      if (this.entries[index].ownerId === ownerId) { this.entries.splice(index, 1); }
    }
  }

  clear(ownerId: string, generation?: number, measurementToken?: string): boolean {
    const existing: OverlayRegistryEntry | null = this.findEntry(ownerId);
    if (existing === null || (generation !== undefined && existing.generation !== generation) ||
      (measurementToken !== undefined && existing.measurementToken !== measurementToken)) {
      return false;
    }
    existing.placement = null;
    existing.rects = [];
    return true;
  }

  occupiedRects(excludeOwnerId: string = ''): Array<OverlayRect> {
    const result: Array<OverlayRect> = [];
    for (let index = 0; index < this.entries.length; index++) {
      const item: OverlayRegistryEntry = this.entries[index];
      if (item.ownerId === excludeOwnerId) { continue; }
      for (let rectIndex = 0; rectIndex < item.rects.length; rectIndex++) {
        const rect: OverlayRect = item.rects[rectIndex];
        if (rect.width > 0 && rect.height > 0) { result.push(rect); }
      }
    }
    return result;
  }
}
