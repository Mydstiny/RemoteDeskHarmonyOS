import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import {
  SSH_WORKBENCH_V2_DEFAULT_ENABLED,
  SSH_WORKBENCH_V2_FLAG_KEY
} from './SshWorkspaceCapabilityPolicy';

export const SSH_WORKBENCH_PREFERENCES_NAME: string = 'RemoteDesktopAppPrefs';

export interface SshWorkspaceCapabilityPreferenceRead {
  ok: boolean;
  exists: boolean;
  value: Object;
}

export interface SshWorkspaceCapabilityPreferenceAdapter {
  read(context: common.Context): SshWorkspaceCapabilityPreferenceRead;
  write(context: common.Context, enabled: boolean): boolean;
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
}

let capabilityPreferenceAdapter: SshWorkspaceCapabilityPreferenceAdapter =
  new HarmonySshWorkspaceCapabilityPreferenceAdapter();

export function setSshWorkspaceCapabilityPreferenceAdapterForTest(
  adapter: SshWorkspaceCapabilityPreferenceAdapter | null
): void {
  capabilityPreferenceAdapter = adapter === null ?
    new HarmonySshWorkspaceCapabilityPreferenceAdapter() : adapter;
}

export class SshWorkspaceCapabilityStore {
  load(context: common.Context): boolean {
    const read: SshWorkspaceCapabilityPreferenceRead =
      capabilityPreferenceAdapter.read(context);
    const enabled: boolean = read.ok && typeof read.value === 'boolean' ?
      read.value as boolean : SSH_WORKBENCH_V2_DEFAULT_ENABLED;
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
