/**
 * ClipboardBridgeService — 系统剪贴板 ↔ 远程桌面桥接
 *
 * 复用项目中已有的 pasteboard API 模式 (SshTerminal / KeyVaultPage / SshKeyCard)。
 * 轮询检测本地系统剪贴板变化并推送远端；接收远端剪贴板并写入本地系统剪贴板。
 * 防回环: setSystemText 后 1.2s 窗口期内忽略轮询到的相同/相似内容。
 */
import {
  abilityAccessCtrl,
  common,
  PermissionRequestResult,
  Permissions
} from '@kit.AbilityKit';
import { pasteboard, BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  ClipboardReadAccessDecision,
  clipboardReadPermissionErrorCode,
  resolveClipboardReadAccess,
  validateClipboardText
} from './ClipboardSyncPolicy';

const TAG = 'ClipboardBridge';
const READ_PASTEBOARD_PERMISSION: Permissions =
  'ohos.permission.READ_PASTEBOARD' as Permissions;

export async function ensureSystemPasteboardReadAccess(
  context: common.UIAbilityContext): Promise<ClipboardReadAccessDecision> {
  try {
    const manager: abilityAccessCtrl.AtManager = abilityAccessCtrl.createAtManager();
    const status: abilityAccessCtrl.GrantStatus = manager.checkAccessTokenSync(
      context.applicationInfo.accessTokenId, READ_PASTEBOARD_PERMISSION);
    if (status === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED) {
      return resolveClipboardReadAccess(true, null);
    }
    const result: PermissionRequestResult = await manager.requestPermissionsFromUser(
      context, [READ_PASTEBOARD_PERMISSION]);
    const authResult: number | null = result.authResults && result.authResults.length === 1
      ? result.authResults[0] : null;
    return resolveClipboardReadAccess(false, authResult);
  } catch (error) {
    const businessError: BusinessError = error as BusinessError;
    hilog.warn(0x0001, TAG, 'pasteboard read permission unavailable code=' +
      clipboardReadPermissionErrorCode(businessError.code));
    return resolveClipboardReadAccess(false, null, true);
  }
}

export class ClipboardBridgeService {
  private pollingTimer: number = -1;
  private systemPasteboard: pasteboard.SystemPasteboard | null = null;
  private systemUpdateCallback?: () => void;
  private systemReadInFlight: boolean = false;
  private systemReadPending: boolean = false;
  private lastHash: number = 0;
  private remoteSetAt: number = 0;
  private remoteSetHash: number = 0;
  private onLocalTextChanged?: (text: string) => void;
  private enabled: boolean = false;
  private localMonitoringEnabled: boolean = false;
  private permissionManager: abilityAccessCtrl.AtManager | null = null;
  private permissionStateCallback?: (info: abilityAccessCtrl.PermissionStateChangeInfo) => void;
  private readRemoteText?: () => string;
  private lastRemoteHash: number = 0;

  /** 读系统剪贴板纯文本 (异步) */
  getSystemText(): Promise<string> {
    return new Promise<string>((resolve) => {
      try {
        const sysPb: pasteboard.SystemPasteboard = this.systemPasteboard ?? pasteboard.getSystemPasteboard();
        sysPb.getData((err: BusinessError, pd: pasteboard.PasteData) => {
          if (err) {
            hilog.warn(0x0001, TAG, `getData failed: ${err.code} ${err.message}`);
            resolve('');
            return;
          }
          try {
            // Some system versions return an undefined primary value for an
            // empty pasteboard despite the SDK's non-null string signature.
            const text: string | undefined = pd?.getPrimaryText();
            resolve(typeof text === 'string' ? text : '');
          } catch (e) {
            resolve('');
          }
        });
      } catch (e) {
        resolve('');
      }
    });
  }

  /** 写系统剪贴板纯文本 (来自远端) — 同时标记防回环窗口 */
  setSystemText(text: string): void {
    if (!validateClipboardText(text).ok) {
      return;
    }
    try {
      const pd: pasteboard.PasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
      pasteboard.getSystemPasteboard().setData(pd);
      this.remoteSetAt = Date.now();
      this.remoteSetHash = this.hashText(text);
      hilog.info(0x0001, TAG, `setSystemText: ${text.length} chars, antiLoop=true`);
    } catch (err) {
      hilog.warn(0x0001, TAG, `setSystemText failed: ${JSON.stringify(err)}`);
    }
  }

  /** 启动监听 (定时轮询) */
  startMonitoring(callback: (text: string) => void, readRemoteText?: () => string,
    localReadEnabled: boolean = true, localReadAllowed: boolean = true): boolean {
    if (this.enabled) {
      return this.localMonitoringEnabled;
    }
    try {
      this.enabled = true;
      this.onLocalTextChanged = callback;
      this.readRemoteText = readRemoteText;
      this.lastHash = 0;
      this.systemReadInFlight = false;
      this.systemReadPending = false;

      const localMonitoringStarted: boolean = localReadEnabled &&
        this.enableLocalMonitoring();
      if (localReadAllowed && !localMonitoringStarted) {
        this.startPermissionStateMonitoring();
      }

      // RustDesk/RDP/VNC expose remote clipboard snapshots through the native
      // session facade, so retain a lightweight remote-only poll. Local system
      // clipboard reads are event-driven: getData can occupy the ArkUI thread
      // for more than 100ms on an empty pasteboard and must not run every 500ms.
      this.pollingTimer = setInterval(() => {
        this.pollRemoteOnce();
      }, 500);
      hilog.info(0x0001, TAG, localMonitoringStarted
        ? 'monitoring started (local update event + 500ms remote poll)'
        : 'monitoring started (remote poll only; local read unavailable)');
      return localMonitoringStarted;
    } catch (err) {
      this.enabled = false;
      this.onLocalTextChanged = undefined;
      this.detachSystemUpdateListener();
      this.detachPermissionStateListener();
      hilog.warn(0x0001, TAG, `monitoring start failed: ${JSON.stringify(err)}`);
      return false;
    }
  }

  /** 权限在会话建立后获批时，立即补上本地监听并建立基线。 */
  enableLocalMonitoring(): boolean {
    if (!this.enabled || !this.onLocalTextChanged) {
      return false;
    }
    if (this.localMonitoringEnabled) {
      return true;
    }
    try {
      const sysPb: pasteboard.SystemPasteboard = pasteboard.getSystemPasteboard();
      this.systemPasteboard = sysPb;
      this.systemUpdateCallback = (): void => {
        this.readLocalClipboard(false);
      };
      sysPb.on('update', this.systemUpdateCallback);
      this.localMonitoringEnabled = true;
      this.readLocalClipboard(true);
      this.detachPermissionStateListener();
      hilog.info(0x0001, TAG, 'local pasteboard monitoring enabled');
      return true;
    } catch (error) {
      this.detachSystemUpdateListener();
      hilog.warn(0x0001, TAG, 'local pasteboard monitoring unavailable: ' +
        JSON.stringify(error));
      return false;
    }
  }

  /** 停止监听 */
  stopMonitoring(): void {
    if (!this.enabled) {
      return;
    }
    this.enabled = false;
    this.onLocalTextChanged = undefined;
    this.readRemoteText = undefined;
    if (this.pollingTimer >= 0) {
      clearInterval(this.pollingTimer);
      this.pollingTimer = -1;
    }
    this.detachSystemUpdateListener();
    this.detachPermissionStateListener();
    this.localMonitoringEnabled = false;
    this.systemReadInFlight = false;
    this.systemReadPending = false;
    this.remoteSetAt = 0;
    this.remoteSetHash = 0;
    hilog.info(0x0001, TAG, 'monitoring stopped');
  }

  /** 轮询 native 会话内的远程剪贴板，不读系统剪贴板。 */
  private pollRemoteOnce(): void {
    if (!this.enabled || !this.onLocalTextChanged) {
      return;
    }
    if (this.readRemoteText) {
      const remoteText: string = this.readRemoteText();
      const remoteHash: number = this.hashText(remoteText);
      if (remoteHash !== 0 && remoteHash !== this.lastRemoteHash && validateClipboardText(remoteText).ok) {
        this.lastRemoteHash = remoteHash;
        this.setSystemText(remoteText);
      }
    }
  }

  /** 合并系统 update 事件，任何时刻最多一个 getData 在途。 */
  private readLocalClipboard(baselineOnly: boolean): void {
    if (!this.enabled || !this.localMonitoringEnabled || !this.onLocalTextChanged) {
      return;
    }
    if (this.systemReadInFlight) {
      this.systemReadPending = true;
      return;
    }
    this.systemReadInFlight = true;
    this.getSystemText().then((text: string) => {
      if (!this.enabled) {
        return;
      }
      const hash: number = this.hashText(text);
      if (baselineOnly) {
        this.lastHash = hash;
        return;
      }

      // 防回环: 远端写入后 1200ms 内忽略匹配的本地变化
      if (this.remoteSetAt > 0) {
        const elapsed: number = Date.now() - this.remoteSetAt;
        if (elapsed < 1200 && (hash === this.remoteSetHash || hash === 0)) {
          return;
        }
        if (elapsed >= 1200) {
          this.remoteSetAt = 0;
          this.remoteSetHash = 0;
        }
      }

      // 内容变化且非空 → 推送到远端
      if (hash !== this.lastHash && text.length > 0) {
        if (!validateClipboardText(text).ok) { return; }
        this.lastHash = hash;
        try {
          this.onLocalTextChanged!(text);
        } catch (err) {
          hilog.warn(0x0001, TAG, `local clipboard callback failed: ${JSON.stringify(err)}`);
        }
      }
    }).catch((err: Error) => {
      hilog.warn(0x0001, TAG, `clipboard poll failed: ${err.message}`);
    }).finally(() => {
      this.systemReadInFlight = false;
      if (this.enabled && this.systemReadPending) {
        this.systemReadPending = false;
        this.readLocalClipboard(false);
      }
    });
  }

  private detachSystemUpdateListener(): void {
    if (this.systemPasteboard !== null && this.systemUpdateCallback !== undefined) {
      try {
        this.systemPasteboard.off('update', this.systemUpdateCallback);
      } catch (err) {
        hilog.warn(0x0001, TAG, `system update listener removal failed: ${JSON.stringify(err)}`);
      }
    }
    this.systemPasteboard = null;
    this.systemUpdateCallback = undefined;
    this.localMonitoringEnabled = false;
  }

  private startPermissionStateMonitoring(): void {
    if (this.permissionManager !== null || this.permissionStateCallback !== undefined) {
      return;
    }
    try {
      const manager: abilityAccessCtrl.AtManager = abilityAccessCtrl.createAtManager();
      const callback = (info: abilityAccessCtrl.PermissionStateChangeInfo): void => {
        if (!this.enabled || info.permissionName !== READ_PASTEBOARD_PERMISSION ||
          info.change !== abilityAccessCtrl.PermissionStateChangeType.PERMISSION_GRANTED_OPER) {
          return;
        }
        this.enableLocalMonitoring();
      };
      manager.on('selfPermissionStateChange', [READ_PASTEBOARD_PERMISSION], callback);
      this.permissionManager = manager;
      this.permissionStateCallback = callback;
      hilog.info(0x0001, TAG, 'waiting for pasteboard read permission change');
    } catch (error) {
      const businessError: BusinessError = error as BusinessError;
      hilog.warn(0x0001, TAG, 'permission change monitoring unavailable code=' +
        clipboardReadPermissionErrorCode(businessError.code));
      this.permissionManager = null;
      this.permissionStateCallback = undefined;
    }
  }

  private detachPermissionStateListener(): void {
    if (this.permissionManager !== null && this.permissionStateCallback !== undefined) {
      try {
        this.permissionManager.off('selfPermissionStateChange',
          [READ_PASTEBOARD_PERMISSION], this.permissionStateCallback);
      } catch (error) {
        const businessError: BusinessError = error as BusinessError;
        hilog.warn(0x0001, TAG, 'permission change listener removal failed code=' +
          clipboardReadPermissionErrorCode(businessError.code));
      }
    }
    this.permissionManager = null;
    this.permissionStateCallback = undefined;
  }

  /** 纯文本内容哈希 (djb2 — 轻量去重，不要求密码学强度) */
  private hashText(text: string): number {
    if (text.length === 0) {
      return 0;
    }
    let h: number = 5381;
    for (let i: number = 0; i < text.length; i++) {
      h = ((h << 5) + h) + text.charCodeAt(i);
      h = h & 0x7fffffff; // 保持正数
    }
    return h;
  }
}
