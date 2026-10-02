import { common } from '@kit.AbilityKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { preferences } from '@kit.ArkData';
import { util } from '@kit.ArkTS';
import { DiagnosticAiProviderProfile, DiagnosticAiSettings, cloneDiagnosticAiProfile, defaultDiagnosticAiSettings } from './DiagnosticAiModels';
import { DiagnosticAiSecretStore } from './DiagnosticAiSecretStore';
import { cloneDiagnosticAiSettings, validDiagnosticAiSettings } from './DiagnosticAiSettingsPolicy';

const STORE_PREFIX: string = 'RemoteDeskDiagnosticAiProfiles-v1-';

function scopeHash(scope: string): string {
  const md = cryptoFramework.createMd('SHA256'); md.updateSync({ data: new util.TextEncoder().encode(scope) });
  const bytes: Uint8Array = md.digestSync().data; let value = '';
  for (let i = 0; i < bytes.length; i++) { value += bytes[i].toString(16).padStart(2, '0'); }
  return value.slice(0, 24);
}

/** Non-secret Provider metadata only. API keys remain in DiagnosticAiSecretStore. */
export class DiagnosticAiProfileStore {
  private static active: DiagnosticAiProfileStore | null = null;
  private context: common.Context | null = null;
  private owner: string = 'device-local';
  private profiles: DiagnosticAiProviderProfile[] = [];
  private settings: DiagnosticAiSettings = defaultDiagnosticAiSettings();
  private loaded: boolean = false;

  init(context: common.Context, owner: string): void {
    DiagnosticAiProfileStore.active = this;
    this.context = context; this.owner = owner.trim() === '' ? 'device-local' : owner.trim(); this.loaded = false; this.load();
    DiagnosticAiSecretStore.getInstance().init(context, this.owner);
  }

  private load(): void {
    if (this.loaded || this.context === null) { return; }
    try {
      const prefs = preferences.getPreferencesSync(this.context, { name: STORE_PREFIX + scopeHash(this.owner) });
      const rows = JSON.parse(prefs.getSync('profiles', '[]') as string) as DiagnosticAiProviderProfile[];
      this.profiles = Array.isArray(rows) ? rows.filter((value: DiagnosticAiProviderProfile): boolean => value.owner === this.owner)
        .map((value: DiagnosticAiProviderProfile): DiagnosticAiProviderProfile => cloneDiagnosticAiProfile(value)) : [];
      const candidate = JSON.parse(prefs.getSync('settings', '{}') as string) as DiagnosticAiSettings;
      this.settings = validDiagnosticAiSettings(candidate) ? cloneDiagnosticAiSettings(candidate) : defaultDiagnosticAiSettings();
    } catch (_error) { this.profiles = []; this.settings = defaultDiagnosticAiSettings(); }
    this.loaded = true;
  }

  private persist(): void {
    if (this.context === null) { return; }
    try {
      const prefs = preferences.getPreferencesSync(this.context, { name: STORE_PREFIX + scopeHash(this.owner) });
      prefs.putSync('profiles', JSON.stringify(this.profiles.map((value: DiagnosticAiProviderProfile): DiagnosticAiProviderProfile => {
        const copy = cloneDiagnosticAiProfile(value); copy.secretRef = ''; copy.secretFingerprint = value.secretFingerprint; return copy;
      })));
      prefs.putSync('settings', JSON.stringify(this.settings)); prefs.flushSync();
    } catch (_error) { /* keep current memory state; next explicit save can retry */ }
  }

  list(): DiagnosticAiProviderProfile[] { this.load(); return this.profiles.map((value: DiagnosticAiProviderProfile): DiagnosticAiProviderProfile => cloneDiagnosticAiProfile(value)); }
  settingsSnapshot(): DiagnosticAiSettings { this.load(); return cloneDiagnosticAiSettings(this.settings); }

  saveProfile(profile: DiagnosticAiProviderProfile, secret: string): boolean {
    this.load(); if (profile.owner !== this.owner || profile.id === '' || profile.providerId === '') { return false; }
    const secretStore = DiagnosticAiSecretStore.getInstance();
    const ref = profile.secretRef === '' ? profile.id : profile.secretRef;
    const meta = secret === '' ? secretStore.metadataFor(ref) : secretStore.put(ref, secret);
    if (secret !== '' && meta === null) { return false; }
    const index = this.profiles.findIndex((value: DiagnosticAiProviderProfile): boolean => value.id === profile.id);
    profile.revision = index >= 0 ? Math.max(this.profiles[index].revision + 1, profile.revision) : Math.max(1, profile.revision);
    profile.secretRef = ref; profile.secretFingerprint = meta?.fingerprint ?? profile.secretFingerprint; profile.updatedAt = Date.now();
    if (index >= 0) { this.profiles[index] = cloneDiagnosticAiProfile(profile); } else { this.profiles.push(cloneDiagnosticAiProfile(profile)); }
    this.persist(); return true;
  }

  removeProfile(id: string): boolean {
    this.load(); const found = this.profiles.find((value: DiagnosticAiProviderProfile): boolean => value.id === id);
    if (found === undefined) { return false; }
    DiagnosticAiSecretStore.getInstance().remove(found.secretRef);
    this.profiles = this.profiles.filter((value: DiagnosticAiProviderProfile): boolean => value.id !== id);
    if (this.settings.selectedProviderId === found.providerId) { this.settings.selectedProviderId = ''; this.settings.selectedModelId = ''; }
    this.persist(); return true;
  }

  saveSettings(settings: DiagnosticAiSettings): boolean {
    if (!validDiagnosticAiSettings(settings)) { return false; }
    this.settings = cloneDiagnosticAiSettings(settings); this.persist(); return true;
  }

  secret(profile: DiagnosticAiProviderProfile): string { return DiagnosticAiSecretStore.getInstance().get(profile.secretRef); }
  clearForScopeTransition(): void {
    this.profiles.forEach((value: DiagnosticAiProviderProfile): void => { DiagnosticAiSecretStore.getInstance().remove(value.secretRef); });
    this.profiles = this.profiles.map((value: DiagnosticAiProviderProfile): DiagnosticAiProviderProfile => {
      const copy = cloneDiagnosticAiProfile(value); copy.secretRef = ''; copy.secretFingerprint = ''; return copy;
    });
    this.settings.showOrbOnHostPage = false;
    this.persist(); this.loaded = true;
  }

  static clearActiveScope(): void {
    DiagnosticAiProfileStore.active?.clearForScopeTransition();
  }
}
