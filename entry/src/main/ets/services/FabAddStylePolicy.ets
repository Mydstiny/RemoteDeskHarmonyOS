/** FAB add-style routing shared by host, key, 2FA, and relay resource entry points. */
export type FabAddStyle = 'modern' | 'classic';

/**
 * All device classes honor the persisted preference. The persisted/cloud key
 * intentionally remains `hostAddMode` for compatibility with released cloud
 * settings records. Desktop-specific layout is handled by the page/sheet,
 * not by silently replacing the selected add flow.
 */
export function resolveFabAddStyle(savedStyle: string, _isDesktopDevice: boolean): FabAddStyle {
  return savedStyle === 'classic' ? 'classic' : 'modern';
}
