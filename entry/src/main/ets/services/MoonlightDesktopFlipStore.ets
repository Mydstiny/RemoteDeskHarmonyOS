import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import {
  MoonlightDesktopFlipMode,
  normalizeMoonlightDesktopFlipMode
} from './MoonlightDesktopFlipPolicy';
import { moonlightLocalHostSettingFingerprint } from './MoonlightRuntimeSupport';

export const MOONLIGHT_DESKTOP_FLIP_PREFERENCES_NAME: string =
  'RemoteDesktopMoonlightDesktopFlipPrefsV1';

export interface MoonlightDesktopFlipPreferenceRead {
  ok: boolean;
  value: string;
}

export interface MoonlightDesktopFlipPreferenceAdapter {
  read(context: common.Context, storeName: string,
    key: string): MoonlightDesktopFlipPreferenceRead;
  write(context: common.Context, storeName: string,
    key: string, value: string): boolean;
}

class HarmonyMoonlightDesktopFlipPreferenceAdapter implements
  MoonlightDesktopFlipPreferenceAdapter {
  read(context: common.Context, storeName: string,
    key: string): MoonlightDesktopFlipPreferenceRead {
    try {
      const prefs = preferences.getPreferencesSync(context, { name: storeName });
      const value: Object = prefs.getSync(key, 'reset') as Object;
      return typeof value === 'string' ?
        { ok: true, value: value as string } : { ok: false, value: '' };
    } catch (_error) { return { ok: false, value: '' }; }
  }

  write(context: common.Context, storeName: string,
    key: string, value: string): boolean {
    try {
      const prefs = preferences.getPreferencesSync(context, { name: storeName });
      prefs.putSync(key, value);
      prefs.flushSync();
      return true;
    } catch (_error) { return false; }
  }
}

let flipPreferenceAdapter: MoonlightDesktopFlipPreferenceAdapter =
  new HarmonyMoonlightDesktopFlipPreferenceAdapter();

export function setMoonlightDesktopFlipPreferenceAdapterForTest(
  adapter: MoonlightDesktopFlipPreferenceAdapter | null
): void {
  flipPreferenceAdapter = adapter === null ?
    new HarmonyMoonlightDesktopFlipPreferenceAdapter() : adapter;
}

export function moonlightDesktopFlipPreferenceKey(
  ownerScopeFingerprint: string, hostId: string
): string {
  const owner: string = ownerScopeFingerprint.trim().toLowerCase();
  const host: string = moonlightLocalHostSettingFingerprint(hostId);
  if (!/^[0-9a-f]{64}$/.test(owner) || host.length !== 64) { return ''; }
  return 'moonlight.desktop.flip.v1:' + owner.slice(0, 24) + ':' + host.slice(0, 32);
}

export class MoonlightDesktopFlipStore {
  load(context: common.Context, ownerScopeFingerprint: string,
    hostId: string): MoonlightDesktopFlipMode {
    const key: string = moonlightDesktopFlipPreferenceKey(
      ownerScopeFingerprint, hostId);
    if (key === '') { return 'reset'; }
    try {
      const result: MoonlightDesktopFlipPreferenceRead = flipPreferenceAdapter.read(
        context, MOONLIGHT_DESKTOP_FLIP_PREFERENCES_NAME, key);
      return result.ok ? normalizeMoonlightDesktopFlipMode(result.value) : 'reset';
    } catch (_error) { return 'reset'; }
  }

  save(context: common.Context, ownerScopeFingerprint: string,
    hostId: string, mode: MoonlightDesktopFlipMode): boolean {
    const key: string = moonlightDesktopFlipPreferenceKey(
      ownerScopeFingerprint, hostId);
    if (key === '') { return false; }
    try {
      return flipPreferenceAdapter.write(context,
        MOONLIGHT_DESKTOP_FLIP_PREFERENCES_NAME, key,
        normalizeMoonlightDesktopFlipMode(mode));
    } catch (_error) { return false; }
  }
}
