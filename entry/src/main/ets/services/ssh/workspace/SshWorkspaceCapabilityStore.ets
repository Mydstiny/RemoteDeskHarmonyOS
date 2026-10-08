import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { deviceInfo } from '@kit.BasicServicesKit';
import {
  SSH_WORKBENCH_V2_DEFAULT_ENABLED,
  SSH_WORKBENCH_V2_FLAG_KEY
} from './SshWorkspaceCapabilityPolicy';

export const SSH_WORKBENCH_PREFERENCES_NAME: string = 'RemoteDesktopAppPrefs';
/** Set once the PC default (工作台 on) was applied; a PC user who later turns it off keeps it off. */
export const SSH_WORKBENCH_PC_DEFAULT_KEY: string = 'sshWorkbenchV2PcDefaultOn';

export interface SshWorkspaceCapabilityPreferenceRead {
  ok: boolean;
  exists: boolean;
  value: Object;
}

export interface SshWorkspaceCapabilityPreferenceAdapter {
  read(context: common.Context): SshWorkspaceCapabilityPreferenceRead;
  write(context: common.Context, enabled: boolean): boolean;
  /** Whether the one-time PC default was applied (true when it cannot be read, so it is never forced twice). */
  pcDefaultApplied(context: common.Context): boolean;
  markPcDefaultApplied(context: common.Context): void;
}

class HarmonySshWorkspaceCapabilityPreferenceAdapter
  implements SshWorkspaceCapabilityPreferenceAdapter {
  read(context: common.Context): SshWorkspaceCapabilityPreferenceRead {
    try {
      const prefs = preferences.getPreferencesSync(
        context, { name: SSH_WORKBENCH_PREFERENCES_NAME });
      const exists: boolean = prefs.hasSync(SSH_WORKBENCH_V2_FLAG_KEY);
      return {
        ok: true,
        exists,
        value: prefs.getSync(
          SSH_WORKBENCH_V2_FLAG_KEY, SSH_WORKBENCH_V2_DEFAULT_ENABLED) as Object
      };
    } catch (_err) {
      return { ok: false, exists: false, value: SSH_WORKBENCH_V2_DEFAULT_ENABLED };
    }
  }

  write(context: common.Context, enabled: boolean): boolean {
    try {
      const prefs = preferences.getPreferencesSync(
        context, { name: SSH_WORKBENCH_PREFERENCES_NAME });
      prefs.putSync(SSH_WORKBENCH_V2_FLAG_KEY, enabled);
      prefs.flushSync();
      return true;
    } catch (_err) {
      return false;
    }
  }

  pcDefaultApplied(context: common.Context): boolean {
    try {
      const prefs = preferences.getPreferencesSync(
        context, { name: SSH_WORKBENCH_PREFERENCES_NAME });
      return prefs.getSync(SSH_WORKBENCH_PC_DEFAULT_KEY, false) === true;
    } catch (_err) {
      return true;
    }
  }

  markPcDefaultApplied(context: common.Context): void {
    try {
      const prefs = preferences.getPreferencesSync(
        context, { name: SSH_WORKBENCH_PREFERENCES_NAME });
      prefs.putSync(SSH_WORKBENCH_PC_DEFAULT_KEY, true);
      prefs.flushSync();
    } catch (_err) {
      // Not applied again on failure: the reader treats an unreadable marker as applied.
    }
  }
}

let capabilityPreferenceAdapter: SshWorkspaceCapabilityPreferenceAdapter =
  new HarmonySshWorkspaceCapabilityPreferenceAdapter();

export function setSshWorkspaceCapabilityPreferenceAdapterForTest(
  adapter: SshWorkspaceCapabilityPreferenceAdapter | null
): void {
  capabilityPreferenceAdapter = adapter === null ?
    new HarmonySshWorkspaceCapabilityPreferenceAdapter() : adapter;
}

/** A HarmonyOS PC: the app's flag, or the device type itself when a page loads before that flag is published. */
export function sshWorkbenchHostIsPc(isDesktopDevice: boolean): boolean {
  if (isDesktopDevice) { return true; }
  try {
    return deviceInfo.deviceType === '2in1';
  } catch (_err) {
    return false;
  }
}

export class SshWorkspaceCapabilityStore {
  /**
   * The SSH 工作台 switch. On PC it is on by default (2026-10-09): applied once, also over the 「off」 an earlier
   * version stored on its own; after that the user's choice stands.
   */
  load(context: common.Context, desktop: boolean = false): boolean {
    const read: SshWorkspaceCapabilityPreferenceRead =
      capabilityPreferenceAdapter.read(context);
    let enabled: boolean = read.ok && typeof read.value === 'boolean' ?
      read.value as boolean : SSH_WORKBENCH_V2_DEFAULT_ENABLED;
    if (desktop && read.ok && !capabilityPreferenceAdapter.pcDefaultApplied(context)) {
      capabilityPreferenceAdapter.markPcDefaultApplied(context);
      if (capabilityPreferenceAdapter.write(context, true)) {
        enabled = true;
        AppStorage.setOrCreate(SSH_WORKBENCH_V2_FLAG_KEY, enabled);
        return enabled;
      }
    }
    AppStorage.setOrCreate(SSH_WORKBENCH_V2_FLAG_KEY, enabled);
    if (read.ok && !read.exists) {
      capabilityPreferenceAdapter.write(context, SSH_WORKBENCH_V2_DEFAULT_ENABLED);
    }
    return enabled;
  }

  save(context: common.Context, enabled: boolean): boolean {
    const normalized: boolean = enabled === true;
    AppStorage.setOrCreate(SSH_WORKBENCH_V2_FLAG_KEY, normalized);
    return capabilityPreferenceAdapter.write(context, normalized);
  }
}
