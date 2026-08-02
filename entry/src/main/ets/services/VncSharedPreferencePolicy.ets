export interface VncReverseWheelResolution {
  value: boolean;
  source: 'shared' | 'legacy' | 'default';
}

/** Shared personalization is authoritative; VNC payload is migration input only. */
export function resolveVncReverseWheel(sharedPresent: boolean,
  sharedValue: boolean, legacyVncValue: boolean): VncReverseWheelResolution {
  if (sharedPresent) {
    return { value: sharedValue, source: 'shared' };
  }
  if (legacyVncValue) {
    return { value: true, source: 'legacy' };
  }
  return { value: false, source: 'default' };
}

export function shouldMigrateLegacyVncReverseWheel(sharedPresent: boolean): boolean {
  return !sharedPresent;
}
