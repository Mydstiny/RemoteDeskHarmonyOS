/** HostAddModePolicy — resolve the FAB add-host experience per device class. */
export type HostAddMode = 'modern' | 'classic';

export function resolveHostAddMode(savedMode: string, isDesktopDevice: boolean): HostAddMode {
  if (isDesktopDevice) { return 'classic'; }
  return savedMode === 'classic' ? 'classic' : 'modern';
}
