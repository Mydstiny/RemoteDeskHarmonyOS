import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';

const PRO_CONTINUATION_PREFERENCES_KEY: string = 'proContinuationV1';

/** How the target obtains a secret its own host record does not store. */
export type ProContinuationCredentialMode = 'manual' | 'transfer';
export interface ProContinuationSettings { auto: boolean; credentialMode: ProContinuationCredentialMode; }

/** Device-local continuation choices; defaults keep continuation on and secrets on the source device. */
export class ProContinuationPreferences {
  private static instance: ProContinuationPreferences | null = null;
  private value: ProContinuationSettings = { auto: true, credentialMode: 'manual' };
  private loaded: boolean = false;
  private listeners: Array<() => void> = [];

  static getInstance(): ProContinuationPreferences {
    if (ProContinuationPreferences.instance === null) { ProContinuationPreferences.instance = new ProContinuationPreferences(); }
    return ProContinuationPreferences.instance;
  }

  load(context: common.Context): void {
    if (this.loaded) { return; }
    try {
      const raw = preferences.getPreferencesSync(context, { name: 'RemoteDesktopAppPrefs' })
        .getSync(PRO_CONTINUATION_PREFERENCES_KEY, '{}') as string;
      const parsed = JSON.parse(raw) as Record<string, Object>;
      if (typeof parsed['auto'] === 'boolean') { this.value.auto = parsed['auto'] as boolean; }
      if (parsed['credentialMode'] === 'transfer') { this.value.credentialMode = 'transfer'; }
    } catch (_error) { /* malformed data keeps the safe defaults */ }
    this.loaded = true;
    this.publish();
  }

  settings(): ProContinuationSettings { return { auto: this.value.auto, credentialMode: this.value.credentialMode }; }

  update(context: common.Context, next: ProContinuationSettings): boolean {
    this.load(context);
    const previous = this.settings();
    this.value = { auto: next.auto, credentialMode: next.credentialMode === 'transfer' ? 'transfer' : 'manual' };
    try {
      const prefs = preferences.getPreferencesSync(context, { name: 'RemoteDesktopAppPrefs' });
      prefs.putSync(PRO_CONTINUATION_PREFERENCES_KEY, JSON.stringify(this.value));
      prefs.flushSync();
    } catch (_error) { this.value = previous; return false; }
    this.publish();
    return true;
  }

  subscribe(listener: () => void): () => void {
    this.listeners.push(listener);
    listener();
    return (): void => { this.listeners = this.listeners.filter((item: () => void): boolean => item !== listener); };
  }

  private publish(): void {
    this.listeners.slice().forEach((listener: () => void): void => {
      try { listener(); } catch (_error) { /* isolate subscribers */ }
    });
  }
}
