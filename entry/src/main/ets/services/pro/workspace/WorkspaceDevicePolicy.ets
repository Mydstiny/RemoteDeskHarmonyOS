import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { MAX_WORKSPACE_ENTRIES } from './WorkspacePolicy';

export type WorkspaceDeviceKind = 'phone' | 'tablet' | 'pc';

/** Pad runs a workspace as a two-session pair; phones and PCs keep the full limit. */
export const TABLET_WORKSPACE_ENTRIES: number = 2;
/** AppStorage mirror of the phone opt-in so pages re-render when it changes. */
export const WORKSPACE_PHONE_ENABLED_KEY: string = 'proWorkspacesPhoneEnabled';
const WORKSPACE_PHONE_PREFS_KEY: string = 'proWorkspacesPhoneEnabled';

export function workspaceDeviceKind(isDesktopDevice: boolean, isPadDevice: boolean): WorkspaceDeviceKind {
  if (isDesktopDevice) { return 'pc'; }
  return isPadDevice ? 'tablet' : 'phone';
}

export function workspaceEntryLimit(kind: WorkspaceDeviceKind): number {
  return kind === 'tablet' ? TABLET_WORKSPACE_ENTRIES : MAX_WORKSPACE_ENTRIES;
}

/** Phones show workspaces only after the user opts in. */
export function workspaceUsableOnDevice(kind: WorkspaceDeviceKind, phoneEnabled: boolean): boolean {
  return kind !== 'phone' || phoneEnabled;
}

export function currentWorkspaceDeviceKind(): WorkspaceDeviceKind {
  return workspaceDeviceKind(AppStorage.get<boolean>('isDesktopDevice') ?? false,
    AppStorage.get<boolean>('isPadDevice') ?? false);
}

/** Device-local opt-in for workspaces on phones (off by default; never synced). */
export class WorkspacePhonePreference {
  static load(context: common.Context): boolean {
    let enabled: boolean = false;
    try {
      enabled = preferences.getPreferencesSync(context, { name: 'RemoteDesktopAppPrefs' })
        .getSync(WORKSPACE_PHONE_PREFS_KEY, false) as boolean === true;
    } catch (_error) {
      enabled = false;
    }
    AppStorage.setOrCreate<boolean>(WORKSPACE_PHONE_ENABLED_KEY, enabled);
    return enabled;
  }

  static set(context: common.Context, enabled: boolean): boolean {
    try {
      const prefs = preferences.getPreferencesSync(context, { name: 'RemoteDesktopAppPrefs' });
      prefs.putSync(WORKSPACE_PHONE_PREFS_KEY, enabled);
      prefs.flushSync();
    } catch (_error) {
      return false;
    }
    AppStorage.setOrCreate<boolean>(WORKSPACE_PHONE_ENABLED_KEY, enabled);
    return true;
  }
}
