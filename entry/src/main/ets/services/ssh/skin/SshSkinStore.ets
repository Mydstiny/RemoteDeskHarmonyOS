import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { ProEntries } from '../../pro/ProEntries';
import { PRO_PERSONALIZATION_FEATURE } from '../../pro/ProFeatureCatalog';
import {
  decodeSshSkinSettings,
  emptySshSkinSettings,
  encodeSshSkinSettings,
  resolveSshSkin,
  sanitizeSshCustomSkin,
  SSH_SKIN_CUSTOM_MAX,
  SshSkin,
  SshSkinSettings
} from './SshSkinPolicy';

const SSH_SKIN_PREFS_KEY: string = 'sshSkinV1';
/** Bumped on every change so terminal pages and settings re-render. */
export const SSH_SKIN_REVISION_KEY: string = 'sshSkinRevision';

function withoutHosts(source: Record<string, string>, drop: (hostId: string, skinId: string) => boolean):
  Record<string, string> {
  const result: Record<string, string> = {};
  Object.keys(source).forEach((hostId: string): void => {
    if (!drop(hostId, source[hostId])) { result[hostId] = source[hostId]; }
  });
  return result;
}

/** Device-local SSH skin choices (Pro 个性化方案). */
export class SshSkinStore {
  private static instance: SshSkinStore | null = null;
  private settings: SshSkinSettings = emptySshSkinSettings();
  private loaded: boolean = false;

  static getInstance(): SshSkinStore {
    if (SshSkinStore.instance === null) { SshSkinStore.instance = new SshSkinStore(); }
    return SshSkinStore.instance;
  }

  load(context: common.Context): void {
    if (this.loaded) { return; }
    this.loaded = true;
    try {
      const raw = preferences.getPreferencesSync(context, { name: 'RemoteDesktopAppPrefs' })
        .getSync(SSH_SKIN_PREFS_KEY, '') as string;
      this.settings = decodeSshSkinSettings(typeof raw === 'string' ? raw : '');
    } catch (_error) {
      this.settings = emptySshSkinSettings();
    }
    this.bump();
  }

  snapshot(): SshSkinSettings {
    return decodeSshSkinSettings(encodeSshSkinSettings(this.settings));
  }

  /** The skin a terminal for this host uses now, or null for the free appearance. */
  resolve(hostId: string): SshSkin | null {
    return resolveSshSkin(this.settings, hostId, ProEntries.visible(PRO_PERSONALIZATION_FEATURE));
  }

  setGlobalSkin(context: common.Context, skinId: string): boolean {
    const next: SshSkinSettings = this.snapshot();
    next.globalSkinId = skinId;
    return this.save(context, next);
  }

  setFont(context: common.Context, fontId: string): boolean {
    const next: SshSkinSettings = this.snapshot();
    next.fontId = fontId;
    return this.save(context, next);
  }

  setHostSkin(context: common.Context, hostId: string, skinId: string): boolean {
    const next: SshSkinSettings = this.snapshot();
    next.hostSkins = withoutHosts(next.hostSkins, (id: string, _skin: string): boolean => id === hostId);
    if (skinId.length > 0) { next.hostSkins[hostId] = skinId; }
    return this.save(context, next);
  }

  saveCustom(context: common.Context, skin: SshSkin): boolean {
    const clean: SshSkin | null = sanitizeSshCustomSkin(skin);
    if (clean === null) { return false; }
    const next: SshSkinSettings = this.snapshot();
    const index: number = next.custom.findIndex((item: SshSkin): boolean => item.id === clean.id);
    if (index >= 0) {
      next.custom[index] = clean;
    } else {
      if (next.custom.length >= SSH_SKIN_CUSTOM_MAX) { return false; }
      next.custom.push(clean);
    }
    return this.save(context, next);
  }

  deleteCustom(context: common.Context, skinId: string): boolean {
    const next: SshSkinSettings = this.snapshot();
    next.custom = next.custom.filter((item: SshSkin): boolean => item.id !== skinId);
    if (next.globalSkinId === skinId) { next.globalSkinId = ''; }
    next.hostSkins = withoutHosts(next.hostSkins, (_id: string, skin: string): boolean => skin === skinId);
    return this.save(context, next);
  }

  private save(context: common.Context, next: SshSkinSettings): boolean {
    try {
      const prefs = preferences.getPreferencesSync(context, { name: 'RemoteDesktopAppPrefs' });
      prefs.putSync(SSH_SKIN_PREFS_KEY, encodeSshSkinSettings(next));
      prefs.flushSync();
    } catch (_error) {
      return false;
    }
    this.settings = next;
    this.bump();
    return true;
  }

  private bump(): void {
    AppStorage.setOrCreate(SSH_SKIN_REVISION_KEY, (AppStorage.get<number>(SSH_SKIN_REVISION_KEY) ?? 0) + 1);
  }
}
