export const KNOCK_MAX_FILES: number = 16;
export const KNOCK_MAX_BYTES: number = 512 * 1024 * 1024;
export const KNOCK_SPACE_RESERVE: number = 32 * 1024 * 1024;
export interface KnockPoint { x: number; y: number; }
export interface KnockBounds { left: number; top: number; width: number; height: number; }
export type KnockPointMatch = 'inside' | 'outside' | 'unknown';
// Share Kit and WindowProperties.windowRect both use screen pixels. Never turn
// a desktop coordinate into a file-system path: the user confirms that separately.
export function matchKnockWindow(point: KnockPoint | null, bounds: KnockBounds): KnockPointMatch {
  if (point === null || !Number.isInteger(point.x) || !Number.isInteger(point.y) ||
    point.x < 0 || point.y < 0 || !Number.isFinite(bounds.left) ||
    !Number.isFinite(bounds.top) || !Number.isFinite(bounds.width) ||
    !Number.isFinite(bounds.height) || bounds.width <= 0 || bounds.height <= 0) { return 'unknown'; }
  return point.x >= bounds.left && point.y >= bounds.top &&
    point.x < bounds.left + bounds.width && point.y < bounds.top + bounds.height ? 'inside' : 'outside';
}
export function knockRelativePath(root: string, path: string): string | null {
  if (!root.startsWith('/') || !path.startsWith(root + '/') || path.length > 4096 ||
    /[\x00-\x1f\\]/.test(path)) { return null; }
  const relative: string = path.substring(root.length + 1);
  const parts: string[] = relative.split('/');
  if (parts.length > 16 || parts.some((part: string): boolean =>
    part.length === 0 || part === '.' || part === '..' || part.length > 255)) { return null; }
  return relative;
}
export function knockFileSizeAllowed(size: number, accumulated: number): boolean {
  return Number.isSafeInteger(size) && size >= 0 && size <= KNOCK_MAX_BYTES &&
    Number.isSafeInteger(accumulated) && accumulated >= 0 && accumulated <= KNOCK_MAX_BYTES - size;
}
