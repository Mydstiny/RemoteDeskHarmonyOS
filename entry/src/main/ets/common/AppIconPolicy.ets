export const APP_ICON_MIN_API: number = 26;
export interface AppIconState { name: string; enabled: boolean; }
export interface AppIconProvider {
  supported(): boolean;
  query(): Promise<AppIconState[]>;
  apply(name: string): Promise<void>;
}
export function knownAppIcon(name: string): boolean {
  return name === '' || name === 'rd_white' || name === 'rd_transparent';
}
