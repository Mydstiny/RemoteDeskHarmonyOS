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
import { TerminalInputBuffer } from './SshTerminalSurface';

/** 与 NativeTerminalRenderer 一致的单帧输入预算。 */
const GPU_INPUT_FRAME_BUDGET_BYTES: number = 256 * 1024;
const TERMINAL_BG_ARGB: number = 0xFF0D0D0D;
const DEFAULT_FG_ARGB: number = 0xFFE8EAED;

class GpuTerminalSurfaceController extends XComponentController {
  onSurfaceReady: ((surfaceId: string) => void) | null = null;
  onSurfaceGone: ((surfaceId: string) => void) | null = null;

  onSurfaceCreated(surfaceId: string): void {
    if (this.onSurfaceReady !== null) {
      this.onSurfaceReady(surfaceId);
    }
  }

  onSurfaceDestroyed(surfaceId: string): void {
    hilog.info(0x0000, 'GpuTerminal', 'surface destroyed: %{public}s', surfaceId);
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
  @Prop bottomAlignSparseContent: boolean = false;
  inputBuffer: TerminalInputBuffer = new TerminalInputBuffer();
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
  /** The XComponent can survive an ArkUI prop update without a new create callback. */
  private currentSurfaceId: string = '';
  private followBottom: boolean = true;
  private lastModeSignature: string = '';
  private inputDrainTimer: number = -1;
  /** Coalesce core/surface prop watches into one binding transaction. */
  private surfaceRebindTimer: number = -1;
  private surfaceRebindToken: number = 0;
  private surfaceAttachRetryTimer: number = -1;
  private surfaceAttachRetryCount: number = 0;
  private attachedCoreKey: string = '';
  private disposed: boolean = false;
  private unavailableReported: boolean = false;
  private lifecycleToken: number = 0;

  aboutToAppear(): void {
    const lifecycleToken: number = ++this.lifecycleToken;
    this.disposed = false;
    this.unavailableReported = false;
    this.surfaceAttachRetryCount = 0;
    this.xcController.onSurfaceReady = (surfaceId: string): void => {
      if (this.disposed || lifecycleToken !== this.lifecycleToken) { return; }
      this.currentSurfaceId = surfaceId;
      if (this.surfaceAttachRetryTimer !== -1) {
        clearTimeout(this.surfaceAttachRetryTimer);
        this.surfaceAttachRetryTimer = -1;
      }
      this.surfaceAttachRetryCount = 0;
      this.scheduleSurfaceRebind();
    };
    this.xcController.onSurfaceGone = (surfaceId: string): void => {
      // An old surface may report destruction after a replacement surface is
      // already attached. Do not detach the replacement from the registry.
      if (lifecycleToken !== this.lifecycleToken || this.currentSurfaceId.length === 0 ||
        this.currentSurfaceId !== surfaceId) { return; }
      this.currentSurfaceId = '';
      this.surfaceReady = false;
      const key: string = this.attachedCoreKey.length > 0 ? this.attachedCoreKey : this.coreKey;
      this.registry.detach(key, this.bridge);
    };
    // 同一标签切回时 registry 里可能已有句柄；等 surface ready 后 rebind。
    this.handle = this.registry.handleFor(this.coreKey);
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
    if (this.inputDrainTimer !== -1) {
      clearTimeout(this.inputDrainTimer);
      this.inputDrainTimer = -1;
    }
    if (this.handle > 0) {
      const key: string = this.attachedCoreKey.length > 0 ? this.attachedCoreKey : this.coreKey;
      this.registry.detach(key, this.bridge);
    }
    this.surfaceReady = false;
    this.currentSurfaceId = '';
    // 句柄归 SSH 标签所有，由页面在关闭标签/退出全部连接时经 registry 销毁。
    this.handle = 0;
    this.attachedCoreKey = '';
    this.unavailableReported = false;
    this.xcController.onSurfaceReady = null;
    this.xcController.onSurfaceGone = null;
  }

  private onCoreKeyChange(): void {
    this.scheduleSurfaceRebind();
  }

  private onSurfaceIdentityChange(): void {
    this.scheduleSurfaceRebind();
  }

  /**
   * ArkUI can deliver coreKey and surfaceIdentity watches in either order.
   * Wait one event-loop turn so the native binding always observes the pair
   * from the same visible page revision.
   */
  private scheduleSurfaceRebind(): void {
    if (this.disposed) { return; }
    if (this.surfaceRebindTimer !== -1) {
      clearTimeout(this.surfaceRebindTimer);
      this.surfaceRebindTimer = -1;
    }
    this.surfaceReady = false;
    this.lastModeSignature = '';
    this.unavailableReported = false;
    const token: number = ++this.surfaceRebindToken;
    this.surfaceRebindTimer = setTimeout((): void => {
      this.surfaceRebindTimer = -1;
      if (this.disposed || token !== this.surfaceRebindToken) { return; }
      const previousKey: string = this.attachedCoreKey;
      if (previousKey.length > 0) {
        this.registry.detach(previousKey, this.bridge);
      }
      this.attachedCoreKey = '';
      this.handle = this.registry.handleFor(this.coreKey);
      if (this.currentSurfaceId.length > 0) {
        this.attachSurface(this.currentSurfaceId);
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
    if (this.disposed || surfaceId.length === 0) { return; }
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
      handle = this.registry.attach(this.coreKey, config, this.bridge);
    } catch (err) {
      hilog.warn(0x0000, 'GpuTerminal', 'attach exception: %{public}s', JSON.stringify(err));
      this.reportUnavailable();
      return;
    }
    if (handle <= 0) {
      hilog.warn(0x0000, 'GpuTerminal', 'attach failed for key %{public}s', this.coreKey);
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
    this.surfaceReady = true;
    this.applyGeometry();
    this.applyViewport();
    this.applyAppearance();
    this.consumeInputQueue();
    this.notifyMode();
    if (this.onRendererReady) {
      this.onRendererReady(this.coreKey, this.surfaceIdentity);
    }
  }

  /** A surface can be between destruction and recreation during a tab swap. */
  private scheduleSurfaceAttachRetry(): void {
    if (this.disposed || this.surfaceAttachRetryTimer !== -1 || this.currentSurfaceId.length === 0) {
      return;
    }
    if (this.surfaceAttachRetryCount >= 5) {
      this.reportUnavailable();
      return;
    }
    this.surfaceAttachRetryCount++;
    this.surfaceAttachRetryTimer = setTimeout((): void => {
      this.surfaceAttachRetryTimer = -1;
      if (!this.disposed && this.currentSurfaceId.length > 0) {
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
    if (this.handle <= 0 || !this.surfaceReady) { return; }
    const buffers: ArrayBuffer[] = this.inputBuffer.drain(GPU_INPUT_FRAME_BUDGET_BYTES);
    if (buffers.length === 0) { return; }
    for (let index = 0; index < buffers.length; index++) {
      const buffer: ArrayBuffer = buffers[index];
      if (buffer.byteLength === 0) { continue; }
      this.bridge.writeBytes(this.handle, buffer);
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
      id: `gpu-terminal-${this.surfaceIdentity.length > 0 ? this.surfaceIdentity : this.coreKey}`,
      type: XComponentType.SURFACE,
      controller: this.xcController })
      .width('100%')
      .height('100%')
      .backgroundColor('#0D0D0D')
      .onAreaChange((_o: Area, n: Area): void => {
        this.surfaceWidthPx = vp2px(n.width as number);
        this.surfaceHeightPx = vp2px(n.height as number);
      })
      .focusable(false)
  }
}
