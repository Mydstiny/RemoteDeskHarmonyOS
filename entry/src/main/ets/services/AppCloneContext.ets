import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0029;
const TAG: string = 'AppClone';
const APP_PREFS_NAME: string = 'RemoteDesktopAppPrefs';
/** Each clone has its own sandbox, so this opt-in is local to one clone. */
export const APP_CLONE_CLIPBOARD_OPT_IN_KEY: string = 'appCloneClipboardBridgeOptIn';

export interface AppClonePolicySnapshot {
  cloneIndex: number;
  detected: boolean;
  isClone: boolean;
  localOnly: boolean;
  cloudSyncAllowed: boolean;
  accountKitAllowed: boolean;
  statusText: string;
}

/** Invalid platform results stay fail-closed until a valid index is observed. */
export function normalizeAppCloneIndex(value: number): number {
  if (!Number.isFinite(value) || value < 0 || Math.floor(value) !== value) {
    return -1;
  }
  return value;
}

export function appClonePolicyForIndex(value: number): AppClonePolicySnapshot {
  const cloneIndex: number = normalizeAppCloneIndex(value);
  const detected: boolean = cloneIndex >= 0;
  const isClone: boolean = cloneIndex > 0;
  const localOnly: boolean = !detected || isClone;
  return {
    cloneIndex,
    detected,
    isClone,
    localOnly,
    cloudSyncAllowed: detected && !isClone,
    accountKitAllowed: detected && !isClone,
    statusText: !detected
      ? '实例状态未确认 · 云同步已暂停'
      : (isClone
        ? '应用分身 #' + cloneIndex.toString() + ' · 数据仅保存在本机'
        : '主应用 · 云同步策略保持不变')
  };
}

/** Runtime probe seam: platform failures must never reopen account, cloud or clipboard sharing. */
export function appClonePolicyFromIndexReader(
  readIndex: () => number
): AppClonePolicySnapshot {
  try {
    return appClonePolicyForIndex(readIndex());
  } catch (_error) {
    return appClonePolicyForIndex(-1);
  }
}

export function appCloneAccountTransitionAllowed(
  policy: AppClonePolicySnapshot
): boolean {
  return policy.accountKitAllowed;
}

export function appCloneCloudOperationAllowed(
  policy: AppClonePolicySnapshot
): boolean {
  return policy.cloudSyncAllowed;
}

/**
 * SystemPasteboard is device-wide, so a clone shares it with the main app.
 * A clone keeps both bridge directions off unless the user opted in on that
 * clone (user decision 2026-10-04); an unconfirmed instance never bridges.
 */
export function appCloneClipboardBridgeAllowed(
  policy: AppClonePolicySnapshot,
  cloneOptIn: boolean = false
): boolean {
  if (!policy.localOnly) { return true; }
  return policy.detected && policy.isClone && cloneOptIn;
}

export function appCloneLocalDataSheetReturnCloses(
  policy: AppClonePolicySnapshot
): boolean {
  return policy.localOnly;
}

/** Process-local owner of the platform clone index and its security policy. */
export class AppCloneContext {
  private static instance: AppCloneContext;
  private initialized: boolean = false;
  private policy: AppClonePolicySnapshot = appClonePolicyForIndex(-1);
  private clipboardOptIn: boolean = false;

  static getInstance(): AppCloneContext {
    if (!AppCloneContext.instance) {
      AppCloneContext.instance = new AppCloneContext();
    }
    return AppCloneContext.instance;
  }

  init(context: common.Context): void {
    if (this.initialized) { return; }
    this.policy = appClonePolicyFromIndexReader((): number =>
      context.getApplicationContext().getCurrentAppCloneIndex());
    this.clipboardOptIn = this.policy.isClone && AppCloneContext.readClipboardOptIn(context);
    this.initialized = true;
    hilog.info(DOMAIN, TAG,
      'instance policy detected=%{public}s clone=%{public}s index=%{public}d localOnly=%{public}s',
      this.policy.detected.toString(), this.policy.isClone.toString(),
      this.policy.cloneIndex, this.policy.localOnly.toString());
  }

  snapshot(): AppClonePolicySnapshot {
    return {
      cloneIndex: this.policy.cloneIndex,
      detected: this.policy.detected,
      isClone: this.policy.isClone,
      localOnly: this.policy.localOnly,
      cloudSyncAllowed: this.policy.cloudSyncAllowed,
      accountKitAllowed: this.policy.accountKitAllowed,
      statusText: this.policy.statusText
    };
  }

  isClone(): boolean { return this.policy.isClone; }

  isLocalOnly(): boolean { return this.policy.localOnly; }

  cloudSyncAllowed(): boolean {
    return appCloneCloudOperationAllowed(this.policy);
  }

  accountKitAllowed(): boolean {
    return appCloneAccountTransitionAllowed(this.policy);
  }

  clipboardBridgeAllowed(): boolean {
    return appCloneClipboardBridgeAllowed(this.policy, this.clipboardOptIn);
  }

  cloneClipboardOptIn(): boolean { return this.policy.isClone && this.clipboardOptIn; }

  /**
   * Persists this clone's opt-in. Turning it off takes effect in memory first
   * and stays off even if the write fails (fail closed); turning it on needs
   * a successful write. Every bridge operation re-checks
   * clipboardBridgeAllowed, so a change applies to the next operation.
   */
  setCloneClipboardOptIn(context: common.Context, enabled: boolean): boolean {
    if (!this.policy.isClone) { return false; }
    if (!enabled) { this.clipboardOptIn = false; }
    try {
      const prefs = preferences.getPreferencesSync(context, { name: APP_PREFS_NAME });
      prefs.putSync(APP_CLONE_CLIPBOARD_OPT_IN_KEY, enabled);
      prefs.flushSync();
    } catch (_error) {
      hilog.error(DOMAIN, TAG, 'clipboard opt-in write failed');
      return false;
    }
    this.clipboardOptIn = enabled;
    hilog.info(DOMAIN, TAG, 'clone clipboard opt-in=%{public}s', enabled.toString());
    return true;
  }

  private static readClipboardOptIn(context: common.Context): boolean {
    try {
      const prefs = preferences.getPreferencesSync(context, { name: APP_PREFS_NAME });
      return prefs.getSync(APP_CLONE_CLIPBOARD_OPT_IN_KEY, false) === true;
    } catch (_error) {
      return false;
    }
  }

  localDataSheetReturnCloses(): boolean {
    return appCloneLocalDataSheetReturnCloses(this.policy);
  }
}
