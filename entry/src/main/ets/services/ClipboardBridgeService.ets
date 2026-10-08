/**
 * ClipboardBridgeService — 系统剪贴板 ↔ 远程桌面桥接
 *
 * 复用项目中已有的 pasteboard API 模式 (SshTerminal / KeyVaultPage / SshKeyCard)。
 * 轮询检测本地系统剪贴板变化并推送远端；接收远端剪贴板并写入本地系统剪贴板。
 * 唯一显式授权连接拥有同步权；系统来源 tag 与 native 事件序号防止跨会话回环。
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

import { ClipboardCoordinator, ClipboardLease, ClipboardAuthorization, ClipboardSourceState, LocalClipboardSnapshot,
  RemoteClipboardSnapshot } from './ClipboardCoordinator';

export interface ClipboardBridgeOptions {
  withAuthority?: (operation: () => boolean) => boolean;
  lease?: ClipboardLease;
  authorization?: ClipboardAuthorization;
  /** Required external process-wide authorization, separate from presentation/focus. */
  isAuthorized?: () => boolean;
  isCurrent?: () => boolean;
  readRemoteSnapshot?: () => RemoteClipboardSnapshot | null;
  onLocalContent?: (isCurrent: () => boolean, data: pasteboard.PasteData) => Promise<boolean | null | 'unavailable'>;
  onRemoteContent?: (snapshot: RemoteClipboardSnapshot, isCurrent: () => boolean, remoteTag: string) => Promise<boolean>;
}

interface ClipboardSystemSnapshot extends LocalClipboardSnapshot { data?: pasteboard.PasteData; }
interface RemoteContentFence {
  generation: number;
  epoch: number;
  remoteRevision: number;
  localRevision: number;
  sequence: number;
  kind: 'files' | 'rich';
  changeCount: number;
  tag: string;
  writeObserved: boolean;
}

const TAG = 'ClipboardBridge';
const SYSTEM_READ_TIMEOUT_MS: number = 30000;
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
  private onLocalTextChanged?: (text: string) => boolean | void | Promise<boolean>;
  private enabled: boolean = false;
  private localMonitoringEnabled: boolean = false;
  private localReadGranted: boolean = false;
  private localReadAllowed: boolean = false;
  private nextReadId: number = 0;
  private pendingReads: Map<number, () => void> = new Map<number, () => void>();
  private permissionManager: abilityAccessCtrl.AtManager | null = null;
  private permissionStateCallback?: (info: abilityAccessCtrl.PermissionStateChangeInfo) => void;
  private readRemoteText?: () => string;
  private lastRemoteHash: number = 0;
  private lastRemoteText: string | null = null;
  private onRemoteTextDelivered?: (hash: number) => void;
  private coordinator: ClipboardCoordinator = ClipboardCoordinator.getInstance();
  private ownerId: number = this.coordinator.allocate();
  private generation: number = 0;
  private remoteRevision: number = 0;
  private localRevision: number = 0;
  private sourceState: ClipboardSourceState = new ClipboardSourceState();
  private options: ClipboardBridgeOptions = {};
  private pendingLocalRetry: boolean = false;
  private remoteContentInFlight: boolean = false;
  private remoteContentFence: RemoteContentFence | null = null;

  private authorized(): boolean {
    try {
      return this.coordinator.isAuthorized(this.options.authorization, this.options.lease) &&
        this.options.isAuthorized !== undefined && this.options.isAuthorized() &&
        (this.options.isCurrent === undefined || this.options.isCurrent());
    } catch (_error) { return false; }
  }

  private active(): boolean {
    return this.enabled && this.coordinator.owns(this.ownerId) && this.authorized();
  }

  /** Explicitly detach/reattach this bridge; focus changes must not call this. */
  setActive(active: boolean): void {
    const authorization: ClipboardAuthorization | undefined = this.options.authorization;
    if (active && this.enabled && this.authorized() && authorization !== undefined) {
      this.coordinator.attachBridge(authorization, this.ownerId);
    } else {
      this.coordinator.detachBridge(authorization, this.ownerId);
      this.cancelSystemReads();
    }
  }

  private cancelSystemReads(): void {
    const pending: Array<() => void> = Array.from(this.pendingReads.values());
    for (const cancel of pending) { cancel(); }
  }

  /** A lightweight counter also recovers notifications missed while suspended. */
  private observeMissedSystemUpdate(): void {
    if (!this.active() || !this.localMonitoringEnabled) { return; }
    const count: number = this.systemChangeCount();
    if (count >= 0 && count !== this.sourceState.notifiedChangeCount) { this.handleSystemUpdate(); }
  }

  private handleSystemUpdate(): void {
    if (!this.active() || !this.localMonitoringEnabled) { return; }
    this.sourceState.notifiedChangeCount = this.systemChangeCount();
    if (this.remoteContentFence !== null && this.recordOwnRemoteWrite(this.remoteContentFence)) { return; }
    this.observeSystemUpdateBoundary();
    this.sourceState.pendingLocal = true;
    this.localRevision++;
    this.readLocalClipboard(false);
  }

  hasRemoteClipboardSource(): boolean {
    if (this.active() && this.options.readRemoteSnapshot) {
      try {
        const snapshot: RemoteClipboardSnapshot | null = this.options.readRemoteSnapshot();
        if (snapshot !== null) { this.observeRemoteSnapshot(snapshot); }
      } catch (error) { /* Poll will retry; retain the last known provenance. */ }
    }
    if (this.active() && this.localMonitoringEnabled) {
      try {
        const board: pasteboard.SystemPasteboard = pasteboard.getSystemPasteboard();
        const count: number = board.getChangeCount();
        if (count !== this.sourceState.systemChangeCount) {
          // The update callback's async read may not have completed before Ctrl+V.
          // Only inspect data on a changed count, and retain remote provenance for
          // another runtime's tagged write. A read failure stays conservative.
          const data: pasteboard.PasteData | null = board.hasDataSync() ? board.getDataSync() : null;
          const tag: string = data === null ? '' : data.getTag();
          const remote: boolean = this.coordinator.isRemoteTag(tag);
          if (board.getChangeCount() === count) {
            this.sourceState.remoteSource = remote;
            this.sourceState.systemChangeCount = count;
          }
        }
      } catch (error) { /* Existing asynchronous listener can resolve provenance later. */ }
    }
    return this.sourceState.remoteSource;
  }

  private systemChangeCount(): number {
    try { return pasteboard.getSystemPasteboard().getChangeCount(); }
    catch (error) { return -1; }
  }

  private observeRemoteSnapshot(snapshot: RemoteClipboardSnapshot): void {
    if (snapshot.sequence <= 0 || snapshot.sequence === this.sourceState.observedSequence) { return; }
    this.sourceState.observedSequence = snapshot.sequence;
    this.remoteRevision++;
    this.sourceState.remoteSource = true;
    this.sourceState.systemChangeCount = this.systemChangeCount();
    this.pendingLocalRetry = false;
    this.sourceState.pendingLocal = false;
  }

  /** Record native events already present when a newer system update is delivered. */
  private observeSystemUpdateBoundary(): void {
    if (!this.active()) { return; }
    try {
      const remote: RemoteClipboardSnapshot | null = this.options.readRemoteSnapshot?.() ?? null;
      if (remote !== null) { this.observeRemoteSnapshot(remote); }
    } catch (_error) { /* A later successful observation still fences the read. */ }
    // A pending async local read must not let the next poll deliver an older
    // native event. Tagged remote writes keep their provenance immediately.
    this.sourceState.remoteSource = false;
    try {
      const board: pasteboard.SystemPasteboard = this.systemPasteboard ?? pasteboard.getSystemPasteboard();
      const count: number = board.getChangeCount();
      const data: pasteboard.PasteData | null = board.hasDataSync() ? board.getDataSync() : null;
      if (board.getChangeCount() === count) {
        this.sourceState.remoteSource = data !== null && this.coordinator.isRemoteTag(data.getTag());
        this.sourceState.systemChangeCount = count;
      }
    } catch (_error) { /* Async read retries classification; do not restore the older remote event. */ }
  }

  /** Compatibility helper; internal reads retain failure/type/provenance. */
  async getSystemText(): Promise<string> {
    const snapshot: LocalClipboardSnapshot = await this.getSystemSnapshot();
    return snapshot.ok && snapshot.hasText ? snapshot.text : '';
  }

  private getSystemSnapshot(): Promise<ClipboardSystemSnapshot> {
    return new Promise<ClipboardSystemSnapshot>((resolve): void => {
      const failed: ClipboardSystemSnapshot = { ok: false, hasText: false, text: '', tag: '', changeCount: 0 };
      if (!this.active() || !this.localReadGranted) { resolve(failed); return; }
      const generation: number = this.generation;
      const epoch: number = this.coordinator.currentEpoch();
      const revision: number = this.localRevision;
      const id: number = ++this.nextReadId;
      const started: number = Date.now();
      let finished: boolean = false;
      let timeout: number = -1;
      const finish = (snapshot: ClipboardSystemSnapshot): void => {
        if (finished) { return; }
        finished = true;
        if (timeout >= 0) { clearTimeout(timeout); }
        this.pendingReads.delete(id); resolve(snapshot);
      };
      const current = (): boolean => !finished && this.active() && this.localReadGranted &&
        this.generation === generation && this.localRevision === revision &&
        this.coordinator.isCurrent(this.ownerId, epoch) && Date.now() - started < SYSTEM_READ_TIMEOUT_MS;
      this.pendingReads.set(id, (): void => { finish(failed); });
      timeout = setTimeout((): void => { finish(failed); }, SYSTEM_READ_TIMEOUT_MS);
      try {
        const sysPb: pasteboard.SystemPasteboard = this.systemPasteboard ?? pasteboard.getSystemPasteboard();
        const before: number = sysPb.getChangeCount();
        if (!sysPb.hasDataSync()) {
          finish(current() ? { ok: true, hasText: true, text: '', tag: '', changeCount: before } : failed);
          return;
        }
        sysPb.getData((err: BusinessError, pd: pasteboard.PasteData): void => {
          // A late callback cannot inspect data, change a replacement read or publish.
          if (finished) { return; }
          if (err || !current()) { finish(failed); return; }
          try {
            const after: number = sysPb.getChangeCount();
            if (before !== after) { finish(failed); return; }
            const text: string | undefined = pd?.getPrimaryText();
            finish({ ok: true, hasText: pd.hasType(pasteboard.MIMETYPE_TEXT_PLAIN),
              text: typeof text === 'string' ? text : '', tag: pd.getTag(), changeCount: after, data: pd });
          } catch (_error) { finish(failed); }
        });
      } catch (_error) { finish(failed); }
    });
  }

  /** A tagged empty text record explicitly clears text without losing provenance. */
  setSystemText(text: string): boolean {
    if (!this.active() || !validateClipboardText(text, true).ok) { return false; }
    try {
      const pd: pasteboard.PasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
      const property: pasteboard.PasteDataProperty = pd.getProperty();
      property.tag = this.coordinator.remoteTag(this.ownerId);
      pd.setProperty(property);
      const write = (): boolean => {
        if (!this.active()) { return false; }
        pasteboard.getSystemPasteboard().setDataSync(pd);
        this.sourceState.systemChangeCount = this.systemChangeCount();
        return true;
      };
      return this.options.withAuthority !== undefined ? this.options.withAuthority(write) : write();
    } catch (error) {
      hilog.warn(0x0001, TAG, 'system clipboard delivery failed');
      return false;
    }
  }

  /** Explicit paste always reads current content, even when startup only took a baseline. */
  async readAndSendCurrentText(): Promise<boolean> {
    if (!this.active() || !this.localMonitoringEnabled) { return false; }
    const generation: number = this.generation;
    const epoch: number = this.coordinator.currentEpoch();
    const revision: number = this.remoteRevision;
    const localRevision: number = this.localRevision;
    const snapshot: ClipboardSystemSnapshot = await this.getSystemSnapshot();
    if (!this.currentRead(generation, epoch, revision, localRevision, snapshot.changeCount) || !snapshot.ok) { return false; }
    const guard: () => boolean = (): boolean => this.currentRead(generation, epoch, revision, localRevision, snapshot.changeCount);
    return (await this.sendLocalSnapshot(snapshot, guard)) === true && guard();
  }

  private currentRead(generation: number, epoch: number, revision: number,
    localRevision: number, expectedChangeCount: number = -1): boolean {
    this.hasRemoteClipboardSource();
    return this.active() && this.localReadGranted && this.generation === generation && this.remoteRevision === revision &&
      this.localRevision === localRevision && (expectedChangeCount < 0 ||
      this.systemChangeCount() === expectedChangeCount) && this.coordinator.isCurrent(this.ownerId, epoch);
  }

  private async sendLocalSnapshot(snapshot: ClipboardSystemSnapshot, isCurrent: () => boolean): Promise<boolean | null | 'unavailable'> {
    if (!isCurrent()) { return false; }
    if (this.options.onLocalContent && snapshot.data !== undefined) {
      const accepted: boolean | null | 'unavailable' = await this.options.onLocalContent(isCurrent, snapshot.data);
      if (!isCurrent()) { return false; }
      if (accepted !== null) { return accepted; }
    }
    if (!snapshot.hasText || !validateClipboardText(snapshot.text, true).ok) { return null; }
    const accepted: boolean = await this.sendLocalText(snapshot.text);
    return accepted && isCurrent();
  }

  private async sendLocalText(text: string): Promise<boolean> {
    if (!this.active() || !this.onLocalTextChanged || !validateClipboardText(text, true).ok) { return false; }
    try {
      // Legacy void callbacks mean accepted. New callers return explicit admission.
      const generation: number = this.generation;
      const epoch: number = this.coordinator.currentEpoch();
      const revision: number = this.remoteRevision;
      const localRevision: number = this.localRevision;
      const changeCount: number = this.systemChangeCount();
      const accepted: boolean | void = await Promise.resolve(this.onLocalTextChanged(text));
      return accepted !== false && this.currentRead(generation, epoch, revision, localRevision, changeCount);
    } catch (error) {
      hilog.warn(0x0001, TAG, 'local clipboard callback failed');
      return false;
    }
  }

  /** 启动监听 (定时轮询) */
  startMonitoring(callback: (text: string) => boolean | void | Promise<boolean>, readRemoteText?: () => string,
    localReadEnabled: boolean = true, localReadAllowed: boolean = true,
    initialRemoteHash: number = 0, onRemoteTextDelivered?: (hash: number) => void,
    options: ClipboardBridgeOptions = {}): boolean {
    if (this.enabled) {
      return this.localMonitoringEnabled;
    }
    try {
      this.options = options;
      const authorization: ClipboardAuthorization | undefined = options.authorization;
      if (authorization === undefined || !this.authorized() || !this.coordinator.attachBridge(authorization, this.ownerId)) {
        return false;
      }
      this.enabled = true;
      this.generation++;
      this.localReadGranted = localReadEnabled;
      this.localReadAllowed = localReadAllowed;
      this.sourceState = this.coordinator.sourceState(options.lease ?? authorization.lease, this.ownerId);
      this.onLocalTextChanged = callback;
      this.readRemoteText = readRemoteText;
      this.onRemoteTextDelivered = onRemoteTextDelivered;
      this.lastRemoteText = null;
      this.pendingLocalRetry = false;
      this.lastRemoteHash = initialRemoteHash;
      this.systemReadInFlight = false;
      this.systemReadPending = false;
      this.remoteContentInFlight = false;
      this.remoteContentFence = null;

      const localMonitoringStarted: boolean = localReadEnabled &&
        this.enableLocalMonitoring();
      if (localReadAllowed) {
        this.startPermissionStateMonitoring();
      }

      // RustDesk/RDP/VNC expose remote clipboard snapshots through the native
      // session facade, so retain a lightweight remote-only poll. Local system
      // clipboard reads are event-driven: getData can occupy the ArkUI thread
      // for more than 100ms on an empty pasteboard and must not run every 500ms.
      this.pollingTimer = setInterval(() => {
        if (!this.active()) { this.cancelSystemReads(); return; }
        this.observeMissedSystemUpdate();
        this.pollRemoteOnce();
        if (this.pendingLocalRetry) { this.readLocalClipboard(false); }
      }, 500);
      hilog.info(0x0001, TAG, localMonitoringStarted
        ? 'monitoring started (local update event + 500ms remote poll)'
        : 'monitoring started (remote poll only; local read unavailable)');
      return localMonitoringStarted;
    } catch (err) {
      this.enabled = false;
      this.coordinator.detachBridge(this.options.authorization, this.ownerId);
      this.generation++;
      this.cancelSystemReads();
      this.localReadGranted = false;
      if (this.pollingTimer >= 0) { clearInterval(this.pollingTimer); this.pollingTimer = -1; }
      this.onLocalTextChanged = undefined;
      this.readRemoteText = undefined;
      this.onRemoteTextDelivered = undefined;
      this.detachSystemUpdateListener();
      this.detachPermissionStateListener();
      hilog.warn(0x0001, TAG, `monitoring start failed: ${JSON.stringify(err)}`);
      return false;
    }
  }

  /** The page may call this after an explicit permission check; never requests permission. */
  setLocalReadAccess(granted: boolean): boolean {
    if (!this.enabled || !this.localReadAllowed) { return false; }
    this.localReadGranted = granted;
    if (granted) { return this.enableLocalMonitoring(); }
    this.localRevision++;
    this.pendingLocalRetry = false;
    this.cancelSystemReads();
    this.detachSystemUpdateListener();
    return false;
  }

  /** 权限在会话建立后获批时，立即补上本地监听并建立基线。 */
  enableLocalMonitoring(): boolean {
    if (!this.active() || !this.localReadGranted || !this.onLocalTextChanged) {
      return false;
    }
    if (this.localMonitoringEnabled) {
      return true;
    }
    try {
      const sysPb: pasteboard.SystemPasteboard = pasteboard.getSystemPasteboard();
      this.systemPasteboard = sysPb;
      const generation: number = this.generation;
      this.systemUpdateCallback = (): void => {
        if (this.generation !== generation) { return; }
        this.handleSystemUpdate();
      };
      sysPb.on('update', this.systemUpdateCallback);
      this.localMonitoringEnabled = true;
      const count: number = this.systemChangeCount();
      const firstBaseline: boolean = this.sourceState.notifiedChangeCount < 0;
      if (firstBaseline) {
        this.sourceState.notifiedChangeCount = count;
        this.readLocalClipboard(true);
      } else if (count !== this.sourceState.notifiedChangeCount) {
        this.handleSystemUpdate();
      } else if (this.sourceState.pendingLocal) {
        this.readLocalClipboard(false);
      }
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
    this.generation++;
    this.cancelSystemReads();
    this.localReadGranted = false;
    this.localReadAllowed = false;
    this.coordinator.detachBridge(this.options.authorization, this.ownerId);
    this.onLocalTextChanged = undefined;
    this.readRemoteText = undefined;
    this.onRemoteTextDelivered = undefined;
    if (this.pollingTimer >= 0) {
      clearInterval(this.pollingTimer);
      this.pollingTimer = -1;
    }
    this.detachSystemUpdateListener();
    this.detachPermissionStateListener();
    this.localMonitoringEnabled = false;
    this.systemReadInFlight = false;
    this.systemReadPending = false;
    this.pendingLocalRetry = false;
    this.remoteContentInFlight = false;
    this.remoteContentFence = null;
    this.lastRemoteHash = 0;
    hilog.info(0x0001, TAG, 'monitoring stopped');
  }

  /** Remote event identity advances independently from successful delivery. */
  private pollRemoteOnce(): void {
    if (!this.active()) { return; }
    try {
      if (this.options.readRemoteSnapshot) {
        const snapshot: RemoteClipboardSnapshot | null = this.options.readRemoteSnapshot();
        if (snapshot === null || snapshot.sequence <= 0) { return; }
        this.observeRemoteSnapshot(snapshot);
        if (!this.sourceState.remoteSource || !snapshot.ready || snapshot.sequence === this.sourceState.deliveredSequence) { return; }
        if (snapshot.kind === 'rich' || snapshot.kind === 'files') {
          if (this.options.onRemoteContent && !this.remoteContentInFlight) { this.deliverRemoteContent(snapshot); }
          return;
        }
        if (snapshot.kind !== 'text' && snapshot.kind !== 'none') { return; }
        const text: string = snapshot.kind === 'none' ? '' : snapshot.text;
        if (this.setSystemText(text)) {
          this.sourceState.deliveredSequence = snapshot.sequence;
          this.lastRemoteHash = this.hashText(text);
          if (this.onRemoteTextDelivered) { this.onRemoteTextDelivered(this.lastRemoteHash); }
        }
        return;
      }
      // Old adapters have no sequence: exact text comparison avoids hash collision,
      // but only the snapshot API can represent identical new remote events.
      if (!this.readRemoteText) { return; }
      const text: string = this.readRemoteText();
      const hash: number = this.hashText(text);
      if (this.lastRemoteText === text || (this.lastRemoteText === null &&
        (text.length === 0 || hash === this.lastRemoteHash))) { return; }
      if (this.setSystemText(text)) {
        this.lastRemoteText = text;
        this.lastRemoteHash = hash;
        this.sourceState.remoteSource = true;
        this.remoteRevision++;
        if (this.onRemoteTextDelivered) { this.onRemoteTextDelivered(hash); }
      }
    } catch (error) {
      hilog.warn(0x0001, TAG, 'remote clipboard snapshot unavailable');
    }
  }

  private recordOwnRemoteWrite(fence: RemoteContentFence): boolean {
    if (this.remoteContentFence !== fence || this.generation !== fence.generation) { return false; }
    try {
      const board: pasteboard.SystemPasteboard = pasteboard.getSystemPasteboard();
      const count: number = board.getChangeCount();
      if (!board.hasDataSync()) { return false; }
      const data: pasteboard.PasteData = board.getDataSync();
      if (data.getTag() !== fence.tag || board.getChangeCount() !== count) { return false; }
      if (fence.writeObserved && count !== fence.changeCount) { return false; }
      if (!fence.writeObserved && count === fence.changeCount) { return false; }
      fence.writeObserved = true;
      fence.changeCount = count;
      this.sourceState.systemChangeCount = count;
      this.sourceState.remoteSource = true;
      this.pendingLocalRetry = false;
      return true;
    } catch (_error) { return false; }
  }

  private currentRemoteContent(fence: RemoteContentFence): boolean {
    if (this.remoteContentFence !== fence || !this.active() || this.generation !== fence.generation ||
      !this.coordinator.isCurrent(this.ownerId, fence.epoch)) { return false; }
    try {
      const current: RemoteClipboardSnapshot | null = this.options.readRemoteSnapshot?.() ?? null;
      if (current === null) { return false; }
      this.observeRemoteSnapshot(current);
      if (current.sequence !== fence.sequence || current.kind !== fence.kind || !current.ready) { return false; }
    } catch (_error) { return false; }
    if (this.remoteRevision !== fence.remoteRevision || this.localRevision !== fence.localRevision ||
      !this.sourceState.remoteSource) { return false; }
    if (this.systemChangeCount() !== fence.changeCount && !this.recordOwnRemoteWrite(fence)) { return false; }
    return this.systemChangeCount() === fence.changeCount;
  }

  private async deliverRemoteContent(snapshot: RemoteClipboardSnapshot): Promise<void> {
    const callback: ((snapshot: RemoteClipboardSnapshot, isCurrent: () => boolean, remoteTag: string) => Promise<boolean>) | undefined = this.options.onRemoteContent;
    if (!callback || this.remoteContentInFlight || (snapshot.kind !== 'rich' && snapshot.kind !== 'files')) { return; }
    const fence: RemoteContentFence = { generation: this.generation, epoch: this.coordinator.currentEpoch(),
      remoteRevision: this.remoteRevision, localRevision: this.localRevision, sequence: snapshot.sequence, kind: snapshot.kind,
      changeCount: this.systemChangeCount(), tag: this.coordinator.remoteTag(this.ownerId), writeObserved: false };
    this.remoteContentInFlight = true;
    this.remoteContentFence = fence;
    try {
      const guard: () => boolean = (): boolean => this.currentRemoteContent(fence);
      if (!guard()) { return; }
      const delivered: boolean = await callback(snapshot, guard, fence.tag);
      if (delivered && guard() && fence.writeObserved) {
        this.sourceState.deliveredSequence = snapshot.sequence;
        this.sourceState.remoteSource = true;
        this.sourceState.systemChangeCount = fence.changeCount;
      }
    } catch (_error) {
      hilog.warn(0x0001, TAG, 'rich clipboard delivery unavailable');
    } finally {
      if (this.generation === fence.generation && this.remoteContentFence === fence) {
        this.remoteContentInFlight = false;
        this.remoteContentFence = null;
      }
    }
  }

  /** Merge notifications; no content hash suppresses genuine repeated copies. */
  private readLocalClipboard(baselineOnly: boolean): void {
    if (!this.active() || !this.localMonitoringEnabled || !this.onLocalTextChanged) { return; }
    if (this.systemReadInFlight) { this.systemReadPending = true; return; }
    this.systemReadInFlight = true;
    const generation: number = this.generation;
    const epoch: number = this.coordinator.currentEpoch();
    const revision: number = this.remoteRevision;
    const localRevision: number = this.localRevision;
    this.getSystemSnapshot().then(async (snapshot: ClipboardSystemSnapshot): Promise<void> => {
      if (!this.currentRead(generation, epoch, revision, localRevision)) { return; }
      if (!snapshot.ok) { this.pendingLocalRetry = !baselineOnly; return; }
      if (baselineOnly) {
        if (!this.coordinator.isRemoteOrigin(snapshot) &&
          snapshot.changeCount !== this.sourceState.systemChangeCount) {
          this.sourceState.remoteSource = false;
        }
        this.sourceState.systemChangeCount = snapshot.changeCount;
        return;
      }
      if (this.coordinator.isRemoteOrigin(snapshot)) {
        this.sourceState.remoteSource = true;
        this.sourceState.systemChangeCount = snapshot.changeCount;
        this.pendingLocalRetry = false;
        this.sourceState.pendingLocal = false;
        return;
      }
      this.sourceState.remoteSource = false;
      this.sourceState.systemChangeCount = snapshot.changeCount;
      const guard: () => boolean = (): boolean => this.currentRead(generation, epoch, revision, localRevision, snapshot.changeCount);
      const accepted: boolean | null | 'unavailable' = await this.sendLocalSnapshot(snapshot, guard);
      if (guard()) {
        this.pendingLocalRetry = accepted === false;
        this.sourceState.pendingLocal = accepted === false;
      }
    }).catch(() => {
      if (this.currentRead(generation, epoch, revision, localRevision)) { this.pendingLocalRetry = !baselineOnly; }
    }).finally(() => {
      // An old completion must not clear a new generation's in-flight flag.
      if (this.generation !== generation) { return; }
      this.systemReadInFlight = false;
      if (this.active() && this.systemReadPending) {
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
      const generation: number = this.generation;
      const callback = (info: abilityAccessCtrl.PermissionStateChangeInfo): void => {
        if (this.generation !== generation || !this.enabled || !this.localReadAllowed ||
          info.permissionName !== READ_PASTEBOARD_PERMISSION) { return; }
        if (info.change === abilityAccessCtrl.PermissionStateChangeType.PERMISSION_GRANTED_OPER) {
          this.setLocalReadAccess(true);
        } else if (info.change === abilityAccessCtrl.PermissionStateChangeType.PERMISSION_REVOKED_OPER) {
          this.setLocalReadAccess(false);
        }
      };
      manager.on('selfPermissionStateChange', [READ_PASTEBOARD_PERMISSION], callback);
      this.permissionManager = manager;
      this.permissionStateCallback = callback;
      hilog.info(0x0001, TAG, 'monitoring pasteboard read permission changes');
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
