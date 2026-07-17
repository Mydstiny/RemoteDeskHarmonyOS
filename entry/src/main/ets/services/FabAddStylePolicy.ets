/** FAB add-style routing shared by host, key, 2FA, and relay resource entry points. */
export type FabAddStyle = 'modern' | 'classic';

/**
 * PC keeps its desktop-optimized forms. Phone and Pad honor the persisted
 * preference. The persisted/cloud key intentionally remains `hostAddMode`
 * for compatibility with released cloud settings records.
 */
export function resolveFabAddStyle(savedStyle: string, isDesktopDevice: boolean): FabAddStyle {
  if (isDesktopDevice) { return 'classic'; }
  return savedStyle === 'classic' ? 'classic' : 'modern';
}
