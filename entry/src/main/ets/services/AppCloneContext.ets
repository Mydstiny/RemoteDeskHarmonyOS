import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0029;
const TAG: string = 'AppClone';

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

/** Process-local owner of the platform clone index and its security policy. */
export class AppCloneContext {
  private static instance: AppCloneContext;
  private initialized: boolean = false;
  private policy: AppClonePolicySnapshot = appClonePolicyForIndex(-1);

  static getInstance(): AppCloneContext {
    if (!AppCloneContext.instance) {
      AppCloneContext.instance = new AppCloneContext();
    }
    return AppCloneContext.instance;
  }

  init(context: common.Context): void {
    if (this.initialized) { return; }
    let index: number = -1;
    try {
      index = context.getApplicationContext().getCurrentAppCloneIndex();
    } catch (_error) {
      index = -1;
    }
    this.policy = appClonePolicyForIndex(index);
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

  cloudSyncAllowed(): boolean { return this.policy.cloudSyncAllowed; }

  accountKitAllowed(): boolean { return this.policy.accountKitAllowed; }
}
