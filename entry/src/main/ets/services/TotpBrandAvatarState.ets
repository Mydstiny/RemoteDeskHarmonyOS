export type TotpBrandAssetVisibility = 'initials' | 'asset';

export interface TotpBrandAvatarToken {
  entryKey: string;
  brandId: string;
  generation: number;
}

export interface TotpBrandAvatarSnapshot {
  entryKey: string;
  brandId: string;
  generation: number;
  ready: boolean;
  failed: boolean;
}

/**
 * Owns the async boundary between an ArkUI Image callback and a card row.
 * A callback from an older entry/brand is ignored, so list reuse cannot paint
 * the previous brand after the row has changed.
 */
export class TotpBrandAvatarState {
  private currentState: TotpBrandAvatarSnapshot = {
    entryKey: '',
    brandId: '',
    generation: 0,
    ready: false,
    failed: false
  };

  begin(entryKey: string, brandId: string): TotpBrandAvatarToken {
    this.currentState = {
      entryKey,
      brandId,
      generation: this.currentState.generation + 1,
      ready: false,
      failed: false
    };
    return {
      entryKey,
      brandId,
      generation: this.currentState.generation
    };
  }

  /** Invalidate callbacks after disappear/background/lock without a new asset. */
  invalidate(): void {
    this.currentState = {
      entryKey: '',
      brandId: '',
      generation: this.currentState.generation + 1,
      ready: false,
      failed: false
    };
  }

  snapshot(): TotpBrandAvatarSnapshot {
    return {
      entryKey: this.currentState.entryKey,
      brandId: this.currentState.brandId,
      generation: this.currentState.generation,
      ready: this.currentState.ready,
      failed: this.currentState.failed
    };
  }

  onComplete(token: TotpBrandAvatarToken): boolean {
    if (!this.matches(token)) { return false; }
    this.currentState.ready = true;
    this.currentState.failed = false;
    return true;
  }

  onError(token: TotpBrandAvatarToken): boolean {
    if (!this.matches(token)) { return false; }
    this.currentState.ready = false;
    this.currentState.failed = true;
    return true;
  }

  private matches(token: TotpBrandAvatarToken): boolean {
    return token.entryKey === this.currentState.entryKey &&
      token.brandId === this.currentState.brandId &&
      token.generation === this.currentState.generation;
  }
}

export function totpBrandAssetVisibility(
  snapshot: TotpBrandAvatarSnapshot,
  hasLocalAsset: boolean
): TotpBrandAssetVisibility {
  return hasLocalAsset && snapshot.ready && !snapshot.failed ? 'asset' : 'initials';
}
