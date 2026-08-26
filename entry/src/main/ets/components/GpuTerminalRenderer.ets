/**
 * GpuTerminalRenderer.ets — 原生 GPU 终端渲染组件 (XComponent + OH_Drawing)。
 *
 * 与 NativeTerminalRenderer (Canvas) 接口对齐，但 VT 解析和绘制都发生在
 * native 侧 (SshTerminalRenderer): ArkTS 只负责 surface 生命周期、输入字节
 * 转发和滚动/复制/外观请求。native 符号缺失或创建失败时 isAvailable 为
 * false，页面保留 Canvas 回退路径。
 *
 * 滚动/触摸仍由 SshTerminal 页面统一驱动 (externalScroll* / scrollToBottom*)，
 * 组件本身不挂手势，保持与 Canvas 渲染器一致的事件模型。
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { SshTerminalRendererBridge, SshTerminalRendererConfig } from '../napi/SshTerminalRendererBridge';
import { TerminalCoreMode } from '../napi/TerminalCoreBridge';
import { SshTerminalRendererRegistry } from '../services/SshTerminalRendererRegistry';
import { makeSshTerminalSurfaceOwnerId } from '../services/SshTerminalSurfaceBindingPolicy';
import { sshDiagnosticErrorCode } from '../services/ssh/observability/SshDiagnosticPolicy';
import { TerminalInputBuffer } from './SshTerminalSurface';

/** 与 NativeTerminalRenderer 一致的单帧输入预算。 */
const GPU_INPUT_FRAME_BUDGET_BYTES: number = 256 * 1024;
const TERMINAL_BG_ARGB: number = 0xFF0D0D0D;
const DEFAULT_FG_ARGB: number = 0xFFE8EAED;
/** API 23 may omit XComponentController.onSurfaceCreated during a remount. */
const GPU_SURFACE_POLL_INTERVAL_MS: number = 100;
const GPU_SURFACE_POLL_MAX_ATTEMPTS: number = 60;
// API 23 can expose a numeric surface ID a few turns before its BufferQueue
// is attached. Do not create OH_Drawing_SurfaceOnScreen during that window;
// the old eager poll produced 41207000 before onSurfaceCreated was delivered.
const GPU_SURFACE_STABILIZATION_ATTEMPTS: number = 3;

class GpuTerminalSurfaceController extends XComponentController {
  onSurfaceReady: ((surfaceId: string) => void) | null = null;
  onSurfaceGone: ((surfaceId: string) => void) | null = null;

  onSurfaceCreated(surfaceId: string): void {
    if (this.onSurfaceReady !== null) {
      this.onSurfaceReady(surfaceId);
    }
  }

  onSurfaceDestroyed(surfaceId: string): void {
    hilog.info(0x0000, 'GpuTerminal', 'surface destroyed');
    if (this.onSurfaceGone !== null) { this.onSurfaceGone(surfaceId); }
  }
}

@Component
export struct GpuTerminalRenderer {
  @Prop @Watch('onGeometryChange') cols: number = 80;
  @Prop @Watch('onGeometryChange') rows: number = 24;
  @Prop @Watch('onGeometryChange') cellWvp: number = 9;
  @Prop @Watch('onGeometryChange') cellHvp: number = 20;
  @Prop @Watch('onGeometryChange') fontSize: number = 18;
  @Prop @Watch('onViewportChange') viewportHeight: number = 0;
  @Prop @Watch('onViewportChange') visibleViewportHeight: number = 0;
  /** Stable SSH tab key; keeps the native renderer alive across tab swaps. */
  @Prop @Watch('onCoreKeyChange') coreKey: string = '';
  /** Visible surface identity; changes whenever the page binds a new terminal view. */
  @Prop @Watch('onSurfaceIdentityChange') surfaceIdentity: string = '';
  /** Explicit page-owned revision; handles an ArkUI child reused with the same key. */
  @Prop @Watch('onRenderRevisionChange') renderRevision: number = 0;
  /** Parent-owned repaint fence; a host can need repaint without new SSH bytes. */
  @Prop @Watch('onSurfaceRefreshRequestChange') surfaceRefreshRequest: number = 0;
  /** The XComponent stays mounted; only an active binding may own a renderer. */
  // The component is created only after the page commits a visible binding.
  // A true default also covers ArkUI's initial prop-injection turn: the
  // surface callback/poll must not be lost before @Watch can observe active.
  @Prop @Watch('onActiveChange') active: boolean = true;
  @Prop bottomAlignSparseContent: boolean = false;
  /** Parent-owned per-host queue; it must follow a reused component instance. */
  @Prop @Watch('onInputBufferChange') inputBuffer: TerminalInputBuffer = new TerminalInputBuffer();
  @Prop @Watch('onInputSequenceChange') inputSequence: number = 0;
  @StorageProp('sshTerminalForegroundColor') @Watch('onAppearanceChange') terminalFgColor: string = '#33FF33';
  @Prop @Watch('onScrollToBottomRequest') scrollToBottomRequest: number = 0;
  @Prop @Watch('onForceScrollToBottomRequest') forceScrollToBottomRequest: number = 0;
  @Prop externalScrollLines: number = 0;
  @Prop @Watch('onExternalScrollRequest') externalScrollRequest: number = 0;
  @Link @Watch('onCopyRequest') copyRequest: number;
  @Link copiedText: string;
  onTerminalModeChange?: (mode: TerminalCoreMode) => void;
  onRendererReady?: (hostId: string, surfaceIdentity: string) => void;
  onRendererUnavailable?: (hostId: string, surfaceIdentity: string) => void;

  private bridge: SshTerminalRendererBridge = new SshTerminalRendererBridge();
  private registry: SshTerminalRendererRegistry = SshTerminalRendererRegistry.getInstance();
  private xcController: GpuTerminalSurfaceController = new GpuTerminalSurfaceController();
  private handle: number = 0;
  private surfaceReady: boolean = false;
  private surfaceWidthPx: number = 0;
  private surfaceHeightPx: number = 0;
  /** Dimensions used by the last native surface allocation. */
  private boundSurfaceWidthPx: number = 0;
  private boundSurfaceHeightPx: number = 0;
  /** The XComponent can survive an ArkUI prop update without a new create callback. */
  private currentSurfaceId: string = '';
  /** Keep the last surface identity for a destroy/recreate race. */
  private lastKnownSurfaceId: string = '';
  /** True only after the platform create callback or bounded stabilization. */
  private surfaceLifecycleReady: boolean = false;
  private followBottom: boolean = true;
  private lastModeSignature: string = '';
  private inputDrainTimer: number = -1;
  /** Coalesce core/surface prop watches into one binding transaction. */
  private surfaceRebindTimer: number = -1;
  private surfaceRebindToken: number = 0;
  private surfaceAttachRetryTimer: number = -1;
  private surfaceAttachRetryCount: number = 0;
  private surfacePollTimer: number = -1;
  private surfacePollToken: number = 0;
  private attachedCoreKey: string = '';
  private attachedOwnerId: string = '';
  private disposed: boolean = false;
  private unavailableReported: boolean = false;
  private lifecycleToken: number = 0;
  /** A new visible binding must receive one acknowledged full repaint. */
  private fullRefreshPending: boolean = true;

  /** Identifies the visible host/revision pair that may own this surface. */
  private surfaceBindingLease(): string {
    return this.coreKey.trim() + '|' + this.surfaceIdentity.trim() + '|r' +
      Math.floor(Number.isFinite(this.renderRevision) ? this.renderRevision : 0).toString();
  }

  private hasUsableBinding(): boolean {
    return this.active && this.coreKey.trim().length > 0 && this.surfaceIdentity.trim().length > 0;
  }

  /** The registry uses this identity to reject stale component callbacks. */
  private rendererOwnerId(): string {
    const identity: string = this.surfaceIdentity.trim();
    const owner: string = makeSshTerminalSurfaceOwnerId(identity, this.renderRevision);
    return owner.length > 0 ? owner : this.coreKey.trim();
  }

  private attachedRendererOwnerId(): string {
    return this.attachedOwnerId.length > 0 ? this.attachedOwnerId : this.rendererOwnerId();
  }

  aboutToAppear(): void {
    const lifecycleToken: number = ++this.lifecycleToken;
    this.disposed = false;
    this.unavailableReported = false;
    this.fullRefreshPending = true;
    this.surfaceAttachRetryCount = 0;
    this.surfaceLifecycleReady = false;
    this.xcController.onSurfaceReady = (surfaceId: string): void => {
      if (this.disposed || lifecycleToken !== this.lifecycleToken) { return; }
      if (!this.active) { return; }
      const changed: boolean = this.currentSurfaceId !== surfaceId;
      // onSurfaceCreated only confirms that ArkUI allocated an ID. On API 23
      // the BufferQueue can still reject its first producer flush for a few
      // frames, so let pollSurfaceId() perform the same bounded stabilization
      // for callback-driven and polling-driven surface discovery.
      this.surfaceLifecycleReady = false;
      if (this.surfaceRebindTimer !== -1) {
        clearTimeout(this.surfaceRebindTimer);
        this.surfaceRebindTimer = -1;
      }
      // Invalidate a rebind callback that may already be queued behind the
      // platform surface callback; it must not bypass stabilization.
      this.surfaceRebindToken += 1;
      this.currentSurfaceId = surfaceId;
      this.lastKnownSurfaceId = surfaceId;
      if (changed) {
        this.surfaceReady = false;
        this.fullRefreshPending = true;
        this.boundSurfaceWidthPx = 0;
        this.boundSurfaceHeightPx = 0;
      }
      if (this.surfaceAttachRetryTimer !== -1) {
        clearTimeout(this.surfaceAttachRetryTimer);
        this.surfaceAttachRetryTimer = -1;
      }
      this.surfaceAttachRetryCount = 0;
      if (this.hasUsableBinding()) { this.startSurfaceIdPolling(); }
    };
    this.xcController.onSurfaceGone = (surfaceId: string): void => {
      // Ignore a destroy callback for a different, newer surface. A callback
      // for the current/last surface must detach and enter the rebind retry.
      if (lifecycleToken !== this.lifecycleToken || surfaceId.length === 0 ||
        (this.currentSurfaceId.length > 0 && this.currentSurfaceId !== surfaceId)) { return; }
      // An inactive binding has already detached its registry entry. Ignore a
      // late destroy callback here so it cannot detach the next host's handle.
      if (!this.active) { return; }
      this.lastKnownSurfaceId = surfaceId;
      this.currentSurfaceId = '';
      this.surfaceLifecycleReady = false;
      this.surfaceReady = false;
      this.fullRefreshPending = true;
      this.boundSurfaceWidthPx = 0;
      this.boundSurfaceHeightPx = 0;
      const key: string = this.attachedCoreKey.length > 0 ? this.attachedCoreKey : this.coreKey;
      this.registry.detach(key, this.bridge, this.attachedRendererOwnerId());
      // ArkUI may destroy the old surface before it emits a replacement
      // callback. Keep the identity and let the bounded rebind retry recover
      // the retained VT core instead of leaving a connected tab blank.
      if (this.active) {
        this.scheduleSurfaceRebind();
        this.startSurfaceIdPolling();
      }
    };
    // 同一标签切回时 registry 里可能已有句柄；等 surface ready 后 rebind。
    // Do not cache a retained handle before the current surface is known. The
    // registry remains the source of truth and attachSurface() will rebind the
    // retained per-host core with the current owner lease.
    this.handle = 0;
    // Keep the callback fast path, but do not make rendering depend on it.
    // API 23 can create the surface without dispatching onSurfaceCreated.
    this.startSurfaceIdPolling();
  }

  aboutToDisappear(): void {
    this.lifecycleToken++;
    this.disposed = true;
    this.surfaceRebindToken++;
    if (this.surfaceRebindTimer !== -1) {
      clearTimeout(this.surfaceRebindTimer);
      this.surfaceRebindTimer = -1;
    }
    if (this.surfaceAttachRetryTimer !== -1) {
      clearTimeout(this.surfaceAttachRetryTimer);
      this.surfaceAttachRetryTimer = -1;
    }
    this.stopSurfaceIdPolling();
    if (this.inputDrainTimer !== -1) {
      clearTimeout(this.inputDrainTimer);
      this.inputDrainTimer = -1;
    }
    if (this.handle > 0) {
      const key: string = this.attachedCoreKey.length > 0 ? this.attachedCoreKey : this.coreKey;
      this.registry.detach(key, this.bridge, this.attachedRendererOwnerId());
    }
    this.surfaceReady = false;
    this.currentSurfaceId = '';
    this.lastKnownSurfaceId = '';
    this.surfaceLifecycleReady = false;
    this.boundSurfaceWidthPx = 0;
    this.boundSurfaceHeightPx = 0;
    // 句柄归 SSH 标签所有，由页面在关闭标签/退出全部连接时经 registry 销毁。
    this.handle = 0;
    this.attachedCoreKey = '';
    this.attachedOwnerId = '';
    this.unavailableReported = false;
    this.xcController.onSurfaceReady = null;
    this.xcController.onSurfaceGone = null;
  }

  private onCoreKeyChange(): void {
    this.fullRefreshPending = true;
    // Detach synchronously before ArkUI delivers the remaining prop watches;
    // otherwise the old host can keep painting through the reused XComponent
    // for one frame while the new host binding is being assembled.
    this.deactivateRenderer();
    if (this.active) {
      this.scheduleSurfaceRebind();
      this.startSurfaceIdPolling();
    }
  }

  private onSurfaceIdentityChange(): void {
    this.fullRefreshPending = true;
    this.deactivateRenderer();
    if (this.active) {
      this.scheduleSurfaceRebind();
      this.startSurfaceIdPolling();
    }
  }

  private onRenderRevisionChange(): void {
    this.fullRefreshPending = true;
    this.deactivateRenderer();
    if (!this.active) {
      this.stopSurfaceIdPolling();
      return;
    }
    // The parent increments this even when host/session identity is reused.
    // Reconcile the native surface explicitly so a reused XComponent cannot
    // keep drawing the previous retained core without a new callback.
    this.unavailableReported = false;
    this.startSurfaceIdPolling();
    this.scheduleSurfaceRebind();
  }

  private onActiveChange(): void {
    if (!this.active) {
      this.deactivateRenderer();
      this.stopSurfaceIdPolling();
      return;
    }
    this.fullRefreshPending = true;
    this.invalidateSurfaceObservation();
    this.unavailableReported = false;
    this.startSurfaceIdPolling();
    this.scheduleSurfaceRebind();
  }

  private onInputBufferChange(): void {
    if (this.active) { this.consumeInputQueue(); }
  }

  /** Repaint or rebind the retained core after the page commits a new host view. */
  private onSurfaceRefreshRequestChange(): void {
    if (!this.hasUsableBinding()) { return; }
    this.fullRefreshPending = true;
    // The page increments this fence together with the target host's input
    // sequence. Drain the host-local FIFO here as well because ArkUI can
    // coalesce the ordinary input-sequence watch during keyed surface creation.
    if (this.attachedCoreKey === this.coreKey &&
      this.attachedOwnerId === this.rendererOwnerId()) {
      this.consumeInputQueue();
    }
    this.refreshVisibleSurface();
  }

  /** Detach only the visible surface; the per-host VT core stays in the registry. */
  private deactivateRenderer(): void {
    const key: string = this.attachedCoreKey.length > 0 ? this.attachedCoreKey : this.coreKey;
    if (key.trim().length > 0 && this.handle > 0) {
      this.registry.detach(key, this.bridge, this.attachedRendererOwnerId());
    }
    this.handle = 0;
    this.attachedCoreKey = '';
    this.attachedOwnerId = '';
    this.surfaceReady = false;
    this.lastModeSignature = '';
    this.unavailableReported = false;
    this.fullRefreshPending = true;
    this.invalidateSurfaceObservation();
  }

  /** Drop all platform surface observations before a new visible binding. */
  private invalidateSurfaceObservation(): void {
    this.surfaceRebindToken++;
    if (this.surfaceRebindTimer !== -1) {
      clearTimeout(this.surfaceRebindTimer);
      this.surfaceRebindTimer = -1;
    }
    if (this.surfaceAttachRetryTimer !== -1) {
      clearTimeout(this.surfaceAttachRetryTimer);
      this.surfaceAttachRetryTimer = -1;
    }
    this.stopSurfaceIdPolling();
    this.currentSurfaceId = '';
    this.lastKnownSurfaceId = '';
    this.surfaceLifecycleReady = false;
    this.surfaceReady = false;
    this.boundSurfaceWidthPx = 0;
    this.boundSurfaceHeightPx = 0;
  }

  private stopSurfaceIdPolling(): void {
    this.surfacePollToken++;
    if (this.surfacePollTimer !== -1) {
      clearTimeout(this.surfacePollTimer);
      this.surfacePollTimer = -1;
    }
  }

  private startSurfaceIdPolling(): void {
    if (this.disposed) { return; }
    this.stopSurfaceIdPolling();
    const token: number = this.surfacePollToken;
    this.pollSurfaceId(token, 0);
  }

  /** Reconcile the surface even when the platform skips lifecycle callbacks. */
  private pollSurfaceId(token: number, attempt: number): void {
    if (this.disposed || token !== this.surfacePollToken) { return; }
    let surfaceId: string = '';
    try {
      surfaceId = this.xcController.getXComponentSurfaceId();
    } catch (_err) {
      surfaceId = '';
    }
    if (surfaceId.length > 0) {
      // ArkUI can expose the surface before it applies the first @Prop set.
      // Keep polling while inactive so that the later active transition does
      // not depend on a second onSurfaceCreated callback.
      if (!this.active) {
        if (attempt >= GPU_SURFACE_POLL_MAX_ATTEMPTS) {
          hilog.warn(0x0000, 'GpuTerminal', 'inactive surface poll timed out');
          return;
        }
        this.surfacePollTimer = setTimeout((): void => {
          this.surfacePollTimer = -1;
          this.pollSurfaceId(token, attempt + 1);
        }, GPU_SURFACE_POLL_INTERVAL_MS);
        return;
      }
      const changed: boolean = this.currentSurfaceId !== surfaceId;
      this.currentSurfaceId = surfaceId;
      this.lastKnownSurfaceId = surfaceId;
      if (!this.surfaceLifecycleReady && attempt < GPU_SURFACE_STABILIZATION_ATTEMPTS) {
        this.surfacePollTimer = setTimeout((): void => {
          this.surfacePollTimer = -1;
          this.pollSurfaceId(token, attempt + 1);
        }, GPU_SURFACE_POLL_INTERVAL_MS);
        return;
      }
      this.surfaceLifecycleReady = true;
      if (changed || !this.surfaceReady) {
        this.scheduleSurfaceRebind();
      }
      // The attach/rebind retry owns the remainder of this transaction. A
      // second polling loop would only keep invalidating its pending turn.
      return;
    }
    this.surfaceLifecycleReady = false;
    if (attempt >= GPU_SURFACE_POLL_MAX_ATTEMPTS) {
      hilog.warn(0x0000, 'GpuTerminal', 'surface id poll timed out');
      return;
    }
    this.surfacePollTimer = setTimeout((): void => {
      this.surfacePollTimer = -1;
      this.pollSurfaceId(token, attempt + 1);
    }, GPU_SURFACE_POLL_INTERVAL_MS);
  }

  /**
   * ArkUI can deliver coreKey and surfaceIdentity watches in either order.
   * Wait one event-loop turn so the native binding always observes the pair
   * from the same visible page revision.
   */
  private scheduleSurfaceRebind(): void {
    if (this.disposed) { return; }
    if (!this.hasUsableBinding()) {
      this.deactivateRenderer();
      return;
    }
    if (!this.surfaceLifecycleReady) {
      this.startSurfaceIdPolling();
      return;
    }
    if (this.surfaceRebindTimer !== -1) {
      clearTimeout(this.surfaceRebindTimer);
      this.surfaceRebindTimer = -1;
    }
    this.surfaceReady = false;
    this.lastModeSignature = '';
    this.unavailableReported = false;
    this.fullRefreshPending = true;
    const token: number = ++this.surfaceRebindToken;
    const bindingLease: string = this.surfaceBindingLease();
    this.surfaceRebindTimer = setTimeout((): void => {
      this.surfaceRebindTimer = -1;
      if (this.disposed || !this.hasUsableBinding() || !this.surfaceLifecycleReady ||
        token !== this.surfaceRebindToken || bindingLease !== this.surfaceBindingLease()) { return; }
      const previousKey: string = this.attachedCoreKey;
      if (previousKey.length > 0) {
        this.registry.detach(previousKey, this.bridge, this.attachedRendererOwnerId());
      }
      this.attachedCoreKey = '';
      this.attachedOwnerId = '';
      this.handle = this.registry.handleFor(this.coreKey);
      const surfaceId: string = this.currentSurfaceId.length > 0
        ? this.currentSurfaceId : this.lastKnownSurfaceId;
      if (surfaceId.length > 0) {
        this.attachSurface(surfaceId);
      }
    }, 0);
  }

  private reportUnavailable(): void {
    if (this.unavailableReported || this.disposed) { return; }
    this.unavailableReported = true;
    if (this.onRendererUnavailable) {
      this.onRendererUnavailable(this.coreKey, this.surfaceIdentity);
    }
  }

  private fgArgb(): number {
    const color: string = this.terminalFgColor.trim();
    if (color.length !== 7 || color.charAt(0) !== '#') { return DEFAULT_FG_ARGB; }
    const red: number = parseInt(color.substring(1, 3), 16);
    const green: number = parseInt(color.substring(3, 5), 16);
    const blue: number = parseInt(color.substring(5, 7), 16);
    if (!Number.isFinite(red) || !Number.isFinite(green) || !Number.isFinite(blue)) {
      return DEFAULT_FG_ARGB;
    }
    return 0xFF000000 + red * 0x10000 + green * 0x100 + blue;
  }

  private attachSurface(surfaceId: string): void {
    if (this.disposed || !this.hasUsableBinding() || surfaceId.length === 0) { return; }
    if (!this.bridge.isAvailable()) {
      this.reportUnavailable();
      return;
    }
    const config: SshTerminalRendererConfig = {
      surfaceId: surfaceId,
      widthPx: this.surfaceWidthPx > 0 ? this.surfaceWidthPx : vp2px(this.cols * this.cellWvp),
      heightPx: this.surfaceHeightPx > 0 ? this.surfaceHeightPx : vp2px(this.rows * this.cellHvp),
      cols: Math.max(1, this.cols),
      rows: Math.max(1, this.rows),
      cellWidthPx: Math.max(2, vp2px(this.cellWvp)),
      cellHeightPx: Math.max(2, vp2px(this.cellHvp)),
      fontSizePx: Math.max(2, vp2px(this.fontSize)),
      foreground: this.fgArgb(),
      background: TERMINAL_BG_ARGB,
      viewportHeightPx: Math.max(0, vp2px(this.viewportHeight)),
      visibleHeightPx: Math.max(0, vp2px(this.visibleViewportHeight)),
      bottomAlign: this.bottomAlignSparseContent
    };
    let handle: number = 0;
    try {
      handle = this.registry.attach(this.coreKey, config, this.bridge, this.rendererOwnerId());
    } catch (err) {
      hilog.warn(0x0000, 'GpuTerminal',
        'attach exception code=' + sshDiagnosticErrorCode(err));
      this.reportUnavailable();
      return;
    }
    if (handle <= 0) {
      if (handle < 0) {
        // A negative handle is the native renderer's latched GPU-flush
        // failure. Retrying would call OH_Drawing_SurfaceFlush again on the
        // same lost backend and can abort the entire application.
        this.reportUnavailable();
        return;
      }
      hilog.warn(0x0000, 'GpuTerminal', 'attach failed');
      this.scheduleSurfaceAttachRetry();
      return;
    }
    this.surfaceAttachRetryCount = 0;
    if (this.surfaceAttachRetryTimer !== -1) {
      clearTimeout(this.surfaceAttachRetryTimer);
      this.surfaceAttachRetryTimer = -1;
    }
    this.unavailableReported = false;
    this.handle = handle;
    this.attachedCoreKey = this.coreKey;
    this.attachedOwnerId = this.rendererOwnerId();
    this.currentSurfaceId = surfaceId;
    this.lastKnownSurfaceId = surfaceId;
    this.boundSurfaceWidthPx = config.widthPx;
    this.boundSurfaceHeightPx = config.heightPx;
    this.surfaceReady = true;
    this.fullRefreshPending = true;
    this.applyGeometry();
    this.applyViewport();
    this.applyAppearance();
    this.consumeInputQueue();
    this.refreshVisibleSurface();
  }

  /**
   * A visible binding is not ready until its retained VT snapshot has been
   * acknowledged by native drawing. Failed flushes release only the surface
   * and reuse the bounded rebind/poll recovery path. A latched native GPU
   * flush failure is terminal for this renderer and switches to xterm.
   */
  private refreshVisibleSurface(): boolean {
    if (!this.hasUsableBinding()) { return false; }
    // Geometry, viewport and appearance changes already repaint synchronously;
    // this helper owns the explicit page repaint fence.
    if (!this.fullRefreshPending) { return this.surfaceReady && this.handle > 0; }
    // ArkUI may deliver the refresh fence before the new core/surface props.
    // Never report the previous host as ready for this binding.
    if (this.attachedCoreKey !== this.coreKey ||
      this.attachedOwnerId !== this.rendererOwnerId()) {
      this.deactivateRenderer();
      this.scheduleSurfaceRebind();
      this.startSurfaceIdPolling();
      return false;
    }
    if (this.handle <= 0 || !this.surfaceReady) {
      this.startSurfaceIdPolling();
      this.scheduleSurfaceRebind();
      return false;
    }
    let refreshed: boolean = false;
    try {
      refreshed = this.bridge.refresh(this.handle);
    } catch (err) {
      hilog.warn(0x0000, 'GpuTerminal',
        'surface refresh exception code=' + sshDiagnosticErrorCode(err));
    }
    if (refreshed) {
      this.fullRefreshPending = false;
      this.notifyMode();
      if (this.onRendererReady) {
        this.onRendererReady(this.coreKey, this.surfaceIdentity);
      }
      return true;
    }
    this.fullRefreshPending = true;
    this.surfaceReady = false;
    const attachedKey: string = this.attachedCoreKey.length > 0
      ? this.attachedCoreKey : this.coreKey;
    this.registry.detach(attachedKey, this.bridge, this.attachedRendererOwnerId());
    if (this.bridge.hasSurfaceFlushFailure(this.handle)) {
      // The native renderer has already latched the failure and will reject
      // every later bind. Switch to the retained transcript immediately.
      this.reportUnavailable();
      return false;
    }
    this.scheduleSurfaceAttachRetry();
    this.startSurfaceIdPolling();
    return false;
  }

  /** A surface can be between destruction and recreation during a tab swap. */
  private scheduleSurfaceAttachRetry(): void {
    if (this.disposed || this.surfaceAttachRetryTimer !== -1 ||
      (this.currentSurfaceId.length === 0 && this.lastKnownSurfaceId.length === 0)) {
      return;
    }
    if (this.surfaceAttachRetryCount >= 5) {
      this.reportUnavailable();
      return;
    }
    this.surfaceAttachRetryCount++;
    const bindingLease: string = this.surfaceBindingLease();
    this.surfaceAttachRetryTimer = setTimeout((): void => {
      this.surfaceAttachRetryTimer = -1;
      if (!this.disposed && bindingLease === this.surfaceBindingLease() &&
        (this.currentSurfaceId.length > 0 || this.lastKnownSurfaceId.length > 0)) {
        this.scheduleSurfaceRebind();
      }
    }, 32);
  }

  private applyGeometry(): void {
    if (!this.surfaceReady || this.handle <= 0) { return; }
    this.bridge.resize(this.handle, Math.max(1, this.cols), Math.max(1, this.rows),
      Math.max(2, vp2px(this.cellWvp)), Math.max(2, vp2px(this.cellHvp)),
      Math.max(2, vp2px(this.fontSize)));
  }

  private applyViewport(): void {
    if (!this.surfaceReady || this.handle <= 0) { return; }
    this.bridge.setViewport(this.handle, Math.max(0, vp2px(this.viewportHeight)),
      Math.max(0, vp2px(this.visibleViewportHeight)), this.bottomAlignSparseContent);
  }

  private applyAppearance(): void {
    if (!this.surfaceReady || this.handle <= 0) { return; }
    this.bridge.setAppearance(this.handle, Math.max(2, vp2px(this.fontSize)),
      this.fgArgb(), TERMINAL_BG_ARGB);
  }

  private onGeometryChange(): void {
    this.applyGeometry();
  }

  private onViewportChange(): void {
    this.applyViewport();
  }

  private onAppearanceChange(): void {
    this.applyAppearance();
  }

  private onInputSequenceChange(): void {
    this.consumeInputQueue();
  }

  private scheduleInputDrain(): void {
    if (this.inputDrainTimer !== -1 || this.inputBuffer.size() === 0 ||
      this.handle <= 0 || !this.surfaceReady) { return; }
    this.inputDrainTimer = setTimeout((): void => {
      this.inputDrainTimer = -1;
      this.consumeInputQueue();
    }, 0);
  }

  private consumeInputQueue(): void {
    if (!this.active || this.handle <= 0 || !this.surfaceReady) { return; }
    const buffers: ArrayBuffer[] = this.inputBuffer.drain(GPU_INPUT_FRAME_BUDGET_BYTES);
    if (buffers.length === 0) { return; }
    // One native write owns one VT parse and one dirty-frame render. Merge the
    // bounded batch first so a burst split across callback chunks cannot cause
    // dozens of synchronous SurfaceFlush calls in one ArkUI turn.
    let totalBytes: number = 0;
    for (let index = 0; index < buffers.length; index++) {
      totalBytes += buffers[index].byteLength;
    }
    if (totalBytes > 0) {
      const merged: Uint8Array = new Uint8Array(totalBytes);
      let offset: number = 0;
      for (let index = 0; index < buffers.length; index++) {
        const source: Uint8Array = new Uint8Array(buffers[index]);
        merged.set(source, offset);
        offset += source.length;
      }
      const mergedBuffer: ArrayBuffer = merged.buffer as ArrayBuffer;
      this.bridge.writeBytes(this.handle, mergedBuffer);
    }
    if (this.followBottom) {
      this.bridge.scrollToBottom(this.handle);
    }
    this.notifyMode();
    this.scheduleInputDrain();
  }

  private notifyMode(): void {
    if (this.handle <= 0 || this.onTerminalModeChange === undefined) { return; }
    const mode: TerminalCoreMode = this.bridge.mode(this.handle);
    const signature: string = `${mode.bracketedPaste}:${mode.mouseTracking}:${mode.sgrMouse}:` +
      `${mode.applicationCursorKeys}:${mode.applicationKeypad}:${mode.autoWrap}`;
    if (signature !== this.lastModeSignature) {
      this.lastModeSignature = signature;
      this.onTerminalModeChange(mode);
    }
  }

  private onScrollToBottomRequest(): void {
    if (!this.followBottom || this.handle <= 0) { return; }
    this.bridge.scrollToBottom(this.handle);
  }

  private onForceScrollToBottomRequest(): void {
    this.followBottom = true;
    if (this.handle > 0) {
      this.bridge.scrollToBottom(this.handle);
    }
  }

  private onExternalScrollRequest(): void {
    if (this.handle <= 0) { return; }
    this.bridge.scrollView(this.handle, this.externalScrollLines);
    // 用户主动上滑后停止跟随底部；滑回底部 (非正 delta) 恢复跟随。
    this.followBottom = this.externalScrollLines <= 0;
  }

  private onCopyRequest(): void {
    this.copiedText = this.handle > 0 ? this.bridge.content(this.handle) : '';
  }

  build() {
    XComponent({
      // The retained VT core is stable per host, but every visible binding
      // needs a distinct native surface identity so ArkUI cannot reuse the
      // previous host's drawing buffer during a keyed remount.
      id: 'gpu-terminal-' +
        (this.surfaceIdentity.length > 0 ? this.surfaceIdentity : this.coreKey) +
        '-render-' + this.renderRevision.toString(),
      type: XComponentType.SURFACE,
      controller: this.xcController })
      .width('100%')
      .height('100%')
      .backgroundColor('#0D0D0D')
      .onLoad((): void => {
        if (!this.hasUsableBinding()) { return; }
        this.startSurfaceIdPolling();
      })
      .onAreaChange((_o: Area, n: Area): void => {
        const nextWidthPx: number = vp2px(n.width as number);
        const nextHeightPx: number = vp2px(n.height as number);
        const sizeChanged: boolean = Math.abs(nextWidthPx - this.surfaceWidthPx) >= 1 ||
          Math.abs(nextHeightPx - this.surfaceHeightPx) >= 1;
        this.surfaceWidthPx = nextWidthPx;
        this.surfaceHeightPx = nextHeightPx;
        // The first surface callback can race the first area callback and use
        // a cols*cell fallback size. Recreate the native drawing surface once
        // the real pixel dimensions are known so the new host is not clipped
        // into the old surface's buffer geometry.
        if (this.active && sizeChanged && this.surfaceReady && this.currentSurfaceId.length > 0 &&
          this.boundSurfaceWidthPx > 0 && this.boundSurfaceHeightPx > 0 &&
          (Math.abs(this.boundSurfaceWidthPx - nextWidthPx) >= 1 ||
           Math.abs(this.boundSurfaceHeightPx - nextHeightPx) >= 1)) {
          this.scheduleSurfaceRebind();
        }
      })
      .focusable(false)
  }
}
