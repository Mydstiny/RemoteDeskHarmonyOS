/** @deprecated Use FabAddStylePolicy. Kept for source compatibility. */
import { FabAddStyle, resolveFabAddStyle } from './FabAddStylePolicy';

export type HostAddMode = FabAddStyle;

export function resolveHostAddMode(savedMode: string, isDesktopDevice: boolean): HostAddMode {
  return resolveFabAddStyle(savedMode, isDesktopDevice);
}
