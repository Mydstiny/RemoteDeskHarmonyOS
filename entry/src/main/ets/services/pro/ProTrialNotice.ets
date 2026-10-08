import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';

/**
 * Whether the user has tapped 立即试用. The 1.2.0 free trial is on for everyone whatever this says
 * (ProComplimentaryPolicy); this only records that they were told, so the Pro page and 设置 → 教程 read
 * 「Pro 试用中」 / 「继续使用 Pro」 afterwards.
 */
const PRO_TRIAL_STARTED_KEY: string = 'proTrialStartedV1';

function prefs(context: common.Context): preferences.Preferences | null {
  try { return preferences.getPreferencesSync(context, { name: 'RemoteDesktopAppPrefs' }); } catch (_error) { return null; }
}

export function proTrialStarted(context: common.Context): boolean {
  const store: preferences.Preferences | null = prefs(context);
  if (store === null) { return false; }
  try { return store.getSync(PRO_TRIAL_STARTED_KEY, false) === true; } catch (_error) { return false; }
}

export function markProTrialStarted(context: common.Context): void {
  const store: preferences.Preferences | null = prefs(context);
  if (store === null) { return; }
  try { store.putSync(PRO_TRIAL_STARTED_KEY, true); store.flushSync(); } catch (_error) { /* kept for this run only */ }
}
