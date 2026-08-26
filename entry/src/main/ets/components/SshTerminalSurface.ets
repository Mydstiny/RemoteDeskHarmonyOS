/**
 * SshTerminalSurface.ets — Alacritty terminal_core 驱动的终端表面
 *
 * 将 ANSI/VT 解析完全交给 Rust terminal_core, ArkTS 只负责 Canvas 绘制 snapshot。
 *
 * 依赖:
 *   TerminalCoreBridge.ets → C++ NAPI → Rust terminal_core (C ABI)
 *
 * 绘制策略 (与 TerminalEmulator.ets 一致):
 *   1. 普通输出: dirtySnapshot() → 只重绘 dirtyRows + 光标
 *   2. 用户滚动/resize: snapshot() → 全量重绘
 *   3. 光标闪烁: 530ms timer → 仅擦旧光标 cell + 画新光标 cell
 *   4. 脏行附加: 强制包含光标所在行 (光标移动后旧行也要重绘)
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  TerminalCoreBridge,
  TerminalCoreMode,
  TerminalCoreSnapshot,
  TerminalCoreCell
} from '../napi/TerminalCoreBridge';
import {
  shouldAutoScrollToBottomAfterViewportChange,
  shouldHonorAutoScrollToBottom,
  terminalGridTop
} from '../services/SshTerminalScrollPolicy';
import {
  terminalCellIndex,
  terminalDimensionsMatchSnapshot,
  terminalGridDimension
} from '../services/TerminalRendererPolicy';
import { TerminalCoreRegistry } from '../services/TerminalCoreRegistry';

/** 默认前景色 (与 Rust DEFAULT_FG = 0xFFE8EAED 一致, 用于 cell.fg 比较) */
const DEFAULT_FG: number = 0xFFE8EAED;
/** 默认背景色 (与 Rust DEFAULT_BG = 0xFF0B0F14 一致, 用于 cell.bg 比较) */
const DEFAULT_BG: number = 0xFF0B0F14;
/** 终端统一背景 CSS 色 — 与 Theme.terminalBg / TerminalEmulator.DEFAULT_BG 一致, 避免 Canvas 与页面底色不匹配 */
const TERMINAL_BG_CSS: string = '#0D0D0D';
/** 选区高亮底色 */
const SELECTION_BG: string = 'rgba(90,140,255,0.40)';
/** 单次 Canvas 更新的最大 SSH 输出量, 避免长输出阻塞 ArkUI 帧循环。 */
const TERMINAL_INPUT_FRAME_BUDGET_BYTES: number = 256 * 1024;

/**
 * SSH 输出字节的稳定传输载体。
 *
 * 不要用 @Prop/@State 直接持有 ArrayBuffer：ArkUI 观察系统会给 ArrayBuffer 包
 * 观察代理，watch 回调中访问 byteLength 时走 Reflect.get(target, key, proxy)，
 * ArrayBuffer 内置 byteLength getter 要求 this 是真实 ArrayBuffer（internal
 * slot），代理对象没有 → 抛 “don't have internal slot” 导致整页闪退。
 * 该载体本身也会作为 GpuTerminalRenderer 的 @Prop 传递，ArkUI 仍可能代理它。
 * 因此队列的 ArrayBuffer 必须完全放在模块级非观察状态中，载体对象只保留一个
 * 字符串 ID；inputSequence 序号仍由 @Prop @Watch 驱动消费。
 */
class TerminalInputBufferState {
  buffers: ArrayBuffer[] = [];
  bytes: number = 0;
}

const terminalInputBufferStates: Map<string, TerminalInputBufferState> =
  new Map<string, TerminalInputBufferState>();
let terminalInputBufferSequence: number = 0;

/** Test receipt for the module-level non-observed state lifecycle. */
export function sshTerminalInputBufferStateCountForTest(): number {
  return terminalInputBufferStates.size;
}

export class TerminalInputBuffer {
  /** ArkUI may proxy this object; keep the only object-owned value primitive. */
  private readonly stateId: string;

  constructor() {
    terminalInputBufferSequence += 1;
    this.stateId = 'ssh-terminal-input-' + terminalInputBufferSequence.toString();
  }

  private state(): TerminalInputBufferState {
    let state: TerminalInputBufferState | undefined =
      terminalInputBufferStates.get(this.stateId);
    if (state === undefined) {
      // A proxied/reused component can outlive an explicit clear. Recreate the
      // state lazily while retaining the same stable primitive identity.
      state = new TerminalInputBufferState();
      terminalInputBufferStates.set(this.stateId, state);
    }
    return state;
  }

  enqueue(buffer: ArrayBuffer): void {
    if (buffer.byteLength === 0) { return; }
    const state: TerminalInputBufferState = this.state();
    state.buffers.push(buffer);
    state.bytes += buffer.byteLength;
  }

  drain(maxBytes: number = -1): ArrayBuffer[] {
    const state: TerminalInputBufferState = this.state();
    if (state.buffers.length === 0) { return []; }
    if (!Number.isFinite(maxBytes) || maxBytes <= 0) {
      const buffers: ArrayBuffer[] = state.buffers;
      state.buffers = [];
      state.bytes = 0;
      return buffers;
    }

    const limit: number = Math.max(1, Math.floor(maxBytes));
    let selectedBytes: number = 0;
    const selected: ArrayBuffer[] = [];
    while (state.buffers.length > 0 && selectedBytes < limit) {
      const next: ArrayBuffer = state.buffers[0];
      const remaining: number = limit - selectedBytes;
      if (next.byteLength <= remaining) {
        selected.push(next);
        state.buffers.shift();
        selectedBytes += next.byteLength;
        continue;
      }
      // A single native callback can exceed the frame budget. Split only
      // that boundary; the terminal parser accepts partial UTF-8/VT input
      // and the remainder stays at the head of the ordered queue.
      const prefix: ArrayBuffer = next.slice(0, remaining);
      state.buffers[0] = next.slice(remaining);
      selected.push(prefix);
      selectedBytes += prefix.byteLength;
      break;
    }
    state.bytes = Math.max(0, state.bytes - selectedBytes);
    return selected;
  }

  clear(): void {
    // The stable wrapper may be reused after a renderer fallback, so state()
    // recreates storage lazily on the next enqueue/read. Removing the entry
    // here also releases module-level ownership when a host tab is closed.
    terminalInputBufferStates.delete(this.stateId);
  }

  size(): number {
    return this.state().buffers.length;
  }

  byteLength(): number {
    return this.state().bytes;
  }
}

@Component
export struct SshTerminalSurface {
  @Prop @Watch('onResize') cols: number = 80;
  @Prop @Watch('onResize') rows: number = 24;
  @Prop @Watch('onViewportSizeChange') viewportWidth: number = 0;
  @Prop @Watch('onViewportHeightChange') viewportHeight: number = 0;
  @Prop @Watch('onViewportHeightChange') visibleViewportHeight: number = 0;
  /** SshTerminal 传入的 cell 尺寸 (vp), 与 Canvas 测量解耦, 保证 cols×cellW 精确填满终端宽度 */
  @Prop @Watch('onCellSizeChange') cellWvp: number = 9;
  @Prop @Watch('onCellSizeChange') cellHvp: number = 20;
  @Prop @Watch('onFontChange') fontSize: number = 18;
  /** Stable SSH tab key; keeps the VT core alive across visible-page swaps. */
  @Prop coreKey: string = '';
  /** 由 SshTerminal 在构造时传入的稳定引用（普通字段，不参与状态观察）。 */
  inputBuffer: TerminalInputBuffer = new TerminalInputBuffer();
  @Prop @Watch('onInputSequenceChange') inputSequence: number = 0;
  @StorageProp('sshTerminalForegroundColor') @Watch('onFgColorChange') terminalFgColor: string = '#33FF33';
  @Prop selectMode: boolean = false;
  @Prop bottomAlignSparseContent: boolean = false;
  @Prop @Watch('onScrollToBottomRequest') scrollToBottomRequest: number = 0;
  @Prop @Watch('onForceScrollToBottomRequest') forceScrollToBottomRequest: number = 0;
  @Prop externalScrollLines: number = 0;
  @Prop @Watch('onExternalScrollRequest') externalScrollRequest: number = 0;
  @Link @Watch('onCopyRequest') copyRequest: number;
  @Link copiedText: string;
  onData?: (data: string) => void;
  onTerminalModeChange?: (mode: TerminalCoreMode) => void;

  /** 终端核心句柄 (Rust heap 分配) */
  private handle: number = 0;
  private bridge: TerminalCoreBridge = new TerminalCoreBridge();
  private coreRegistry: TerminalCoreRegistry = TerminalCoreRegistry.getInstance();
  private ctx: CanvasRenderingContext2D =
    new CanvasRenderingContext2D(new RenderingContextSettings(true));
  @State cellW: number = 9;
  @State cellH: number = 20;

  /** 最新完整快照缓存 — 用于全屏复制 (getContent) 和 drawCellAt */
  private lastSnapshot: TerminalCoreSnapshot | null = null;
  private lastModeSignature: string = '';
  /** 脏行集合 (从 Rust dirtySnapshot 获取) */
  private dirtyRows: Set<number> = new Set();
  /** 光标闪烁 */
  private blinkTimer: number = -1;
  private cursorVisible: boolean = true;
  /** 上一次绘制时光标的位置 — 用于擦除旧光标 */
  private lastCursorX: number = 0;
  private lastCursorY: number = 0;
  /** 上一次 rows (用于检测 resize) */
  private lastRows: number = 24;
  /** 用户/键盘把视图带到底部后, 后续 resize 和输出持续跟随底部, 直到用户主动上滑 */
  private followBottom: boolean = true;
  /** 帧计数器 — 用于稀疏日志采样 */
  private frameCount: number = 0;
  /** 上一次绘制使用的顶部偏移, 偏移变化时需要全量重绘避免残影 */
  private lastGridTop: number = 0;
  private lastCanvasArea: string = '';
  /** 输入可能先于 Canvas onReady 到达；ready 前保留在 inputBuffer 中。 */
  private canvasReady: boolean = false;
  /** 页面复用时 Canvas 可能不再触发 onReady, 记录该组件曾完成过表面初始化。 */
  private surfaceEverReady: boolean = false;
  /** 复用页面预初始化后, 等待新 surface 的 ready/area 回调再确认一次。 */
  private surfaceReadyProbePending: boolean = false;
  private inputDrainTimer: number = -1;
  /** Coalesce cols/rows updates so a transient mixed-size grid is never drawn. */
  private resizeTimer: number = -1;

  aboutToAppear(): void {
    this.resetLifecycleState();
    this.lastRows = this.rows;
    this.calcCellSize();
    this.handle = this.coreRegistry.acquire(this.coreKey, this.cols, this.rows, this.bridge);
    this.applyForegroundColorToCore();
    if (this.surfaceEverReady) {
      this.markCanvasReady();
      this.surfaceReadyProbePending = true;
    }
    // 光标 530ms 闪烁
    this.blinkTimer = setInterval((): void => {
      this.cursorVisible = !this.cursorVisible;
      this.renderCursorOnly();
    }, 530);
  }

  aboutToDisappear(): void {
    if (this.blinkTimer !== -1) {
      clearInterval(this.blinkTimer);
      this.blinkTimer = -1;
    }
    if (this.inputDrainTimer !== -1) {
      clearTimeout(this.inputDrainTimer);
      this.inputDrainTimer = -1;
    }
    if (this.resizeTimer !== -1) {
      clearTimeout(this.resizeTimer);
      this.resizeTimer = -1;
    }
    // The VT core belongs to the SSH tab, not the transient visible page. It
    // is destroyed by SshTerminal only when the user exits all SSH tabs.
    this.handle = 0;
    this.resetLifecycleState();
  }

  /** ArkUI 可能复用组件实例；Rust handle 重建时增量游标也必须同步归零。 */
  private resetLifecycleState(): void {
    this.lastSnapshot = null;
    this.dirtyRows.clear();
    this.cursorVisible = true;
    this.lastCursorX = 0;
    this.lastCursorY = 0;
    this.followBottom = true;
    this.frameCount = 0;
    this.lastGridTop = 0;
    this.lastViewportHeight = 0;
    this.lastCanvasArea = '';
    this.lastModeSignature = '';
    this.canvasReady = false;
    this.surfaceReadyProbePending = false;
  }

  private notifyTerminalMode(snapshot: TerminalCoreSnapshot): void {
    const mode: TerminalCoreMode = {
      bracketedPaste: snapshot.bracketedPaste,
      mouseTracking: snapshot.mouseTracking,
      sgrMouse: snapshot.sgrMouse,
      applicationCursorKeys: snapshot.applicationCursorKeys,
      applicationKeypad: snapshot.applicationKeypad,
      autoWrap: snapshot.autoWrap
    };
    const signature: string = [
      mode.bracketedPaste ? '1' : '0', mode.mouseTracking.toString(),
      mode.sgrMouse ? '1' : '0', mode.applicationCursorKeys ? '1' : '0',
      mode.applicationKeypad ? '1' : '0', mode.autoWrap ? '1' : '0'
    ].join(':');
    if (signature === this.lastModeSignature) { return; }
    this.lastModeSignature = signature;
    if (this.onTerminalModeChange) {
      this.onTerminalModeChange(mode);
    }
  }

  // ============================================================
  // 字号 / 尺寸变化
  // ============================================================

  private onFontChange(): void {
    this.calcCellSize();
    // 字号变化 → 全量快照 + 全量重绘
    if (this.handle > 0) {
      this.lastSnapshot = this.bridge.snapshot(this.handle);
    }
    this.renderFull();
  }

  private onCellSizeChange(): void {
    this.calcCellSize();
    this.renderFull();
  }

  /** 前景色设置变更 → 全量重绘 (光标+文字都需要刷新) */
  private onFgColorChange(): void {
    this.applyForegroundColorToCore();
    this.renderFull();
  }

  /**
   * Keep the persisted SSH appearance in the VT core. The renderer still
   * consumes the same setting for cursor paint and as a compatibility fallback
   * when an older native library is loaded.
   */
  private applyForegroundColorToCore(): void {
    if (this.handle <= 0) { return; }
    const color: string = this.terminalFgColor.trim();
    if (color.length !== 7 || color.charAt(0) !== '#') { return; }
    const red: number = parseInt(color.substring(1, 3), 16);
    const green: number = parseInt(color.substring(3, 5), 16);
    const blue: number = parseInt(color.substring(5, 7), 16);
    if (!Number.isFinite(red) || !Number.isFinite(green) || !Number.isFinite(blue)) { return; }
    const foreground: number = 0xFF000000 + red * 0x10000 + green * 0x100 + blue;
    this.bridge.setDefaultForeground(this.handle, foreground);
    this.lastSnapshot = this.bridge.snapshot(this.handle);
  }

  /** 父页面请求回到底部 — 键盘弹起/终端高度变化后保证最新行可见 */
  private onScrollToBottomRequest(): void {
    if (!shouldHonorAutoScrollToBottom(this.followBottom)) { return; }
    this.scrollToBottomAndRender();
  }

  private onForceScrollToBottomRequest(): void {
    this.followBottom = true;
    this.scrollToBottomAndRender();
    const snap: TerminalCoreSnapshot | null = this.lastSnapshot;
    if (snap) {
      hilog.info(0x0000, 'NativeTerminal',
        `[layoutDiag] force cols=${snap.cols} rows=${snap.rows} ` +
        `viewTop=${snap.viewTop} screenTop=${snap.screenTop} atBottom=${snap.isAtBottom} ` +
        `viewport=${this.viewportWidth}x${this.viewportHeight} visibleH=${this.visibleViewportHeight} ` +
        `gridTop=${this.gridTop()}`);
    }
  }

  private onExternalScrollRequest(): void {
    hilog.info(0x0000, 'NativeTerminal',
      `[touchDiag] external req=${this.externalScrollRequest} lines=${this.externalScrollLines} ` +
      `handle=${this.handle} follow=${this.followBottom}`);
    this.scrollByLines(this.externalScrollLines);
  }

  private onResize(): void {
    if (this.cols <= 0 || this.rows <= 0) { return; }
    this.scheduleResize();
  }

  private scheduleResize(): void {
    if (this.resizeTimer !== -1) { return; }
    this.resizeTimer = setTimeout((): void => {
      this.resizeTimer = -1;
      this.applyResize();
    }, 0);
  }

  private applyResize(): void {
    if (this.cols <= 0 || this.rows <= 0) { return; }
    if (this.handle > 0) {
      const nextCols: number = terminalGridDimension(this.cols);
      const nextRows: number = terminalGridDimension(this.rows);
      this.bridge.resize(this.handle, nextCols, nextRows);
      if (this.followBottom) {
        this.bridge.scrollToBottom(this.handle);
      }
      this.lastSnapshot = this.bridge.snapshot(this.handle);
    }
    this.lastRows = terminalGridDimension(this.rows);
    this.renderFull();
  }

  private onViewportSizeChange(): void {
    this.renderFull();
  }

  private lastViewportHeight: number = 0;

  private onViewportHeightChange(): void {
    const previousViewportHeight: number = this.lastViewportHeight;
    this.lastViewportHeight = this.viewportHeight;
    if (this.handle > 0 &&
      shouldAutoScrollToBottomAfterViewportChange(this.followBottom, previousViewportHeight, this.viewportHeight)) {
      this.bridge.scrollToBottom(this.handle);
      this.lastSnapshot = this.bridge.snapshot(this.handle);
    }
    this.renderFull();
  }

  // ============================================================
  // 数据输入 — SSH 数据推送到 Rust terminal_core
  // ============================================================

  private onInputSequenceChange(): void {
    this.consumeInputQueue();
  }

  private scheduleInputDrain(): void {
    if (this.inputDrainTimer !== -1 || this.terminalInputIsEmpty() ||
      this.handle <= 0 || !this.canvasReady) { return; }
    this.inputDrainTimer = setTimeout((): void => {
      this.inputDrainTimer = -1;
      this.consumeInputQueue();
    }, 0);
  }

  private terminalInputIsEmpty(): boolean {
    return this.inputBuffer.size() === 0;
  }

  /**
   * Consume every output batch admitted before this frame. Keeping the queue
   * in the stable parent-owned object prevents a later @Watch event from
   * replacing an earlier ArrayBuffer while the Canvas is still initializing.
   */
  private consumeInputQueue(): void {
    if (this.handle <= 0 || !this.canvasReady) { return; }
    const buffers: ArrayBuffer[] = this.inputBuffer.drain(TERMINAL_INPUT_FRAME_BUDGET_BYTES);
    if (buffers.length === 0) { return; }
    for (let index = 0; index < buffers.length; index++) {
      const buffer: ArrayBuffer = buffers[index];
      if (buffer.byteLength === 0) { continue; }
      // Each item is an ordered SSH byte chunk. The Rust core owns bounded
      // scrollback and parses UTF-8/VT sequences without a lossy JS conversion.
      this.bridge.writeBytes(this.handle, buffer);
    }
    if (this.followBottom) {
      this.bridge.scrollToBottom(this.handle);
    }
    this.applyDirtySnapshot();
    this.scheduleInputDrain();
  }

  private markCanvasReady(): void {
    if (this.handle <= 0) { return; }
    this.surfaceReadyProbePending = false;
    if (this.canvasReady) {
      // A reused component can receive onReady for a newly allocated surface
      // after aboutToAppear optimistically restored the previous surface.
      // Refresh the backing canvas before consuming any pending output.
      this.calcCellSize();
      this.lastSnapshot = this.bridge.snapshot(this.handle);
      this.notifyTerminalMode(this.lastSnapshot);
      this.renderFull();
      this.consumeInputQueue();
      return;
    }
    this.canvasReady = true;
    this.surfaceEverReady = true;
    this.calcCellSize();
    this.lastSnapshot = this.bridge.snapshot(this.handle);
    this.notifyTerminalMode(this.lastSnapshot);
    this.renderFull();
    this.consumeInputQueue();
  }

  /** 获取脏快照并增量渲染 */
  private applyDirtySnapshot(): void {
    if (this.handle <= 0) { return; }
    this.frameCount++;
    const snap: TerminalCoreSnapshot = this.bridge.dirtySnapshot(this.handle);
    this.lastSnapshot = snap;
    this.notifyTerminalMode(snap);
    // 构建脏行集合
    this.dirtyRows.clear();
    for (let i = 0; i < snap.dirtyRows.length; i++) {
      const viewRow: number = snap.screenTop + snap.dirtyRows[i] - snap.viewTop;
      if (viewRow >= 0 && viewRow < snap.rows) {
        this.dirtyRows.add(viewRow);
      }
    }
    // 强制包含光标行 (光标移动后旧行也需要擦除)
    const cursorViewY: number = this.cursorViewY(snap);
    if (cursorViewY >= 0 && cursorViewY < snap.rows) {
      this.dirtyRows.add(cursorViewY);
    }

    // 稀疏日志: 前 5 帧 + 每 50 帧 + dirtyRows 异常时
    if (this.frameCount <= 5 || this.frameCount % 50 === 0 || snap.dirtyRows.length === snap.rows) {
      hilog.info(0x0000, 'NativeTerminal',
        `snap #${this.frameCount} cursor=(${snap.cursorX},${snap.cursorY}) ` +
        `viewTop=${snap.viewTop} screenTop=${snap.screenTop} ` +
        `dirtyRows=${snap.dirtyRows.length}/${snap.rows} atBottom=${snap.isAtBottom}`);
    }

    // 如全部脏, 走全量
    if (this.dirtyRows.size >= snap.rows) {
      this.renderFull();
    } else {
      this.renderIncremental();
    }
  }

  // ============================================================
  // 复制支持
  // ============================================================

  private onCopyRequest(): void {
    this.copiedText = this.getContent();
  }

  /** 获取当前可见区完整文本 */
  getContent(): string {
    const snap: TerminalCoreSnapshot | null = this.lastSnapshot;
    if (!snap || snap.cells.length === 0) { return ''; }
    const lines: string[] = [];
    for (let r = 0; r < snap.rows; r++) {
      let line: string = '';
      for (let c = 0; c < snap.cols; c++) {
        const idx: number = r * snap.cols + c;
        if (idx < snap.cells.length) {
          line += snap.cells[idx].ch;
        }
      }
      lines.push(line.replace(/\s+$/, ''));
    }
    return lines.join('\n');
  }

  // ============================================================
  // 字体测量
  // ============================================================

  private calcCellSize(): void {
    // 与 SshTerminal 统一使用 vp 尺寸, 避免 Canvas measureText 在不同 DPI 设备上
    // 返回物理像素值导致 cellW 与 SshTerminal.cellWvp 不一致, 造成内容只占部分宽度。
    this.cellW = this.cellWvp;
    this.cellH = this.cellHvp;
    // 使用 vp 单位保证字体尺寸与 cellWvp/cellHvp (vp) 一致, 避免高 DPI 下 px≠vp 导致的字符溢出或过小
    this.ctx.font = `${this.fontSize}vp monospace`;
  }

  private canvasFont(bold: boolean, italic: boolean = false): string {
    return `${italic ? 'italic ' : ''}${bold ? 'bold ' : ''}${this.fontSize}vp monospace`;
  }

  private gridTop(): number {
    if (!this.bottomAlignSparseContent || this.viewportHeight <= 0) { return 0; }
    const snap: TerminalCoreSnapshot | null = this.lastSnapshot;
    if (!snap || snap.cells.length === 0) { return 0; }
    let bottomRow: number = this.cursorViewY(snap);
    for (let r = snap.rows - 1; r >= 0; r--) {
      for (let c = 0; c < snap.cols; c++) {
        const idx: number = r * snap.cols + c;
        if (idx < snap.cells.length) {
          const ch: string = snap.cells[idx].ch;
          if (ch !== ' ' && ch !== '\x00') {
            bottomRow = Math.max(bottomRow, r);
            r = -1;
            break;
          }
        }
      }
    }
    if (bottomRow < 0) { bottomRow = 0; }
    const contentH: number = (bottomRow + 1) * this.cellH;
    const gridRows: number = snap ? snap.rows : terminalGridDimension(this.rows);
    const visibleH: number = this.visibleViewportHeight > 0 ? this.visibleViewportHeight : this.viewportHeight;
    const topInset: number = Math.max(0, this.viewportHeight - visibleH);
    // screenTop > 0 只说明缓冲区存在历史内容，不代表当前可见区正在浏览历史。
    // 横屏输入命令后切回竖屏时，PTY 会扩大 rows，但光标仍可能停在横屏的第 11 行；
    // 此时 viewTop === screenTop，移动端应把当前可见的稀疏内容贴到可视区底部。
    // 只有用户主动上滑、viewTop 落后于 screenTop 时，才保持历史浏览的顶部布局。
    const hasScrollback: boolean = snap.viewTop < snap.screenTop;
    const sparseLimit: number = Math.min(visibleH * 0.35, this.cellH * 8);
    return terminalGridTop(
      this.bottomAlignSparseContent,
      topInset,
      visibleH,
      gridRows * this.cellH,
      contentH,
      sparseLimit,
      hasScrollback
    );
  }

  private clearTopInset(): void {
    const top: number = this.gridTop();
    if (top <= 0) { return; }
    const ctx: CanvasRenderingContext2D = this.ctx;
    ctx.fillStyle = TERMINAL_BG_CSS;
    ctx.fillRect(0, 0, this.canvasWidth(), top);
  }

  private canvasWidth(): number {
    const snap: TerminalCoreSnapshot | null = this.lastSnapshot;
    const gridCols: number = snap ? snap.cols : terminalGridDimension(this.cols);
    return Math.max(gridCols * this.cellW, Math.ceil(this.viewportWidth));
  }

  private canvasHeight(): number {
    const snap: TerminalCoreSnapshot | null = this.lastSnapshot;
    const gridRows: number = snap ? snap.rows : terminalGridDimension(this.rows);
    return Math.max(gridRows * this.cellH, Math.ceil(this.viewportHeight));
  }

  // ============================================================
  // 颜色转换: uint32 RGBA → CSS color string
  // ============================================================

  private static rgbaToCss(abgr: number): string {
    const a: number = (abgr >> 24) & 0xFF;
    const r: number = (abgr >> 16) & 0xFF;
    const g: number = (abgr >> 8) & 0xFF;
    const b: number = abgr & 0xFF;
    if (a === 0xFF) {
      // 不透明 → #RRGGBB
      return '#' + [r, g, b].map((v: number): string => {
        return v.toString(16).padStart(2, '0');
      }).join('');
    }
    return `rgba(${r},${g},${b},${(a / 255).toFixed(2)})`;
  }

  // ============================================================
  // 渲染 — 全量 / 增量 / 光标
  // ============================================================

  private renderFull(): void {
    const snap: TerminalCoreSnapshot | null = this.lastSnapshot;
    if (this.cellW <= 0 || this.cellH <= 0 || this.cols <= 0 || this.rows <= 0 || !snap) {
      return;
    }
    if (!terminalDimensionsMatchSnapshot(this.cols, this.rows, snap.cols, snap.rows)) {
      this.scheduleResize();
      return;
    }
    const top: number = this.gridTop();
    const ctx: CanvasRenderingContext2D = this.ctx;
    ctx.fillStyle = TERMINAL_BG_CSS;
    ctx.fillRect(0, 0, this.canvasWidth(), this.canvasHeight());
    this.clearTopInset();
    for (let r = 0; r < snap.rows; r++) {
      this.drawRow(r);
    }
    this.drawCursor();
    this.dirtyRows.clear();
    this.lastGridTop = top;
  }

  private renderIncremental(): void {
    const snap: TerminalCoreSnapshot | null = this.lastSnapshot;
    if (this.cellW <= 0 || this.cellH <= 0 || !snap) { return; }
    if (!terminalDimensionsMatchSnapshot(this.cols, this.rows, snap.cols, snap.rows)) {
      this.scheduleResize();
      return;
    }
    const top: number = this.gridTop();
    if (top !== this.lastGridTop) {
      this.renderFull();
      return;
    }
    this.eraseOldCursor();
    this.dirtyRows.forEach((absR: number): void => {
      // dirtyRows 是快照中的视口行号 (0..rows-1)
      if (absR >= 0 && absR < snap.rows) {
        this.drawRow(absR);
      }
    });
    this.drawCursor();
    this.dirtyRows.clear();
  }

  private renderCursorOnly(): void {
    const snap: TerminalCoreSnapshot | null = this.lastSnapshot;
    if (this.cellW <= 0 || this.cellH <= 0 || !snap) { return; }
    if (!terminalDimensionsMatchSnapshot(this.cols, this.rows, snap.cols, snap.rows)) {
      this.scheduleResize();
      return;
    }
    this.eraseOldCursor();
    this.drawCursor();
  }

  /** 擦除上一次光标单元格 — 重画该 cell 字符+背景即消除下划线 */
  private eraseOldCursor(): void {
    this.drawCellAt(this.lastCursorY, this.lastCursorX);
  }

  private scrollToBottomAndRender(): void {
    if (this.handle <= 0) { return; }
    this.bridge.scrollToBottom(this.handle);
    this.lastSnapshot = this.bridge.snapshot(this.handle);
    this.cursorVisible = true;
    this.renderFull();
  }

  /** Rust cursorY 是当前真实屏幕内行号, Canvas 需要映射到 viewTop 可见窗口行号 */
  private cursorViewY(snap: TerminalCoreSnapshot): number {
    return snap.screenTop + snap.cursorY - snap.viewTop;
  }

  /** 画一整行 */
  private drawRow(r: number): void {
    const snap: TerminalCoreSnapshot | null = this.lastSnapshot;
    if (!snap || r < 0 || r >= snap.rows) { return; }
    const ctx: CanvasRenderingContext2D = this.ctx;
    const y: number = this.gridTop() + r * this.cellH;
    // 清整行 — 使用统一终端背景色
    ctx.fillStyle = TERMINAL_BG_CSS;
    ctx.fillRect(0, y, this.canvasWidth(), this.cellH);
    for (let c = 0; c < snap.cols; c++) {
      const idx: number = terminalCellIndex(snap.cols, snap.rows, r, c);
      if (idx >= snap.cells.length) { continue; }
      const cell: TerminalCoreCell = snap.cells[idx];
      // The wide head paints both cells. Painting the continuation again can
      // overwrite the glyph or create a one-cell seam on some Canvas backends.
      if (cell.wideContinuation) { continue; }
      const x: number = c * this.cellW;
      const paintWidth: number = cell.wide ? this.cellW * 2 : this.cellW;
      let fg: number = cell.fg;
      let bg: number = cell.bg;
      if (cell.inverse) {
        const swapped: number = fg;
        fg = bg;
        bg = swapped;
      }
      // 背景 (非默认色)
      if (bg !== DEFAULT_BG) {
        ctx.fillStyle = SshTerminalSurface.rgbaToCss(bg);
        ctx.fillRect(x, y, paintWidth, this.cellH);
      }
      // 前景字符
      if (cell.ch === ' ' || cell.ch === '\x00') { continue; }
      // 默认前景色用 SSH 终端设置替代 Rust 硬编码灰色
      ctx.fillStyle = (fg === DEFAULT_FG) ? this.terminalFgColor : SshTerminalSurface.rgbaToCss(fg);
      ctx.font = this.canvasFont(cell.bold, cell.italic);
      ctx.textBaseline = 'middle';
      ctx.fillText(cell.ch, x, y + this.cellH * 0.50);
      if (cell.underline) {
        ctx.strokeStyle = ctx.fillStyle;
        ctx.lineWidth = Math.max(1, this.cellH * 0.06);
        ctx.beginPath();
        ctx.moveTo(x, y + this.cellH - Math.max(1, this.cellH * 0.12));
        ctx.lineTo(x + paintWidth, y + this.cellH - Math.max(1, this.cellH * 0.12));
        ctx.stroke();
      }
    }
  }

  /** 画单个 cell — 用于 eraseOldCursor */
  private drawCellAt(r: number, c: number): void {
    const snap: TerminalCoreSnapshot | null = this.lastSnapshot;
    if (!snap) { return; }
    let cellCol: number = c;
    let idx: number = terminalCellIndex(snap.cols, snap.rows, r, cellCol);
    if (idx < 0 || idx >= snap.cells.length) { return; }
    if (snap.cells[idx].wideContinuation && cellCol > 0) {
      cellCol -= 1;
      idx = terminalCellIndex(snap.cols, snap.rows, r, cellCol);
    }
    if (idx < 0 || idx >= snap.cells.length) { return; }
    const cell: TerminalCoreCell = snap.cells[idx];
    const ctx: CanvasRenderingContext2D = this.ctx;
    const x: number = cellCol * this.cellW;
    const y: number = this.gridTop() + r * this.cellH;
    const paintWidth: number = cell.wide ? this.cellW * 2 : this.cellW;
    // 清该格 — 使用统一终端背景色
    ctx.fillStyle = TERMINAL_BG_CSS;
    ctx.fillRect(x, y, paintWidth, this.cellH);
    let fg: number = cell.fg;
    let bg: number = cell.bg;
    if (cell.inverse) {
      const swapped: number = fg;
      fg = bg;
      bg = swapped;
    }
    if (bg !== DEFAULT_BG) {
      ctx.fillStyle = SshTerminalSurface.rgbaToCss(bg);
      ctx.fillRect(x, y, paintWidth, this.cellH);
    }
    if (cell.ch !== ' ' && cell.ch !== '\x00' && !cell.wideContinuation) {
      ctx.fillStyle = (fg === DEFAULT_FG) ? this.terminalFgColor : SshTerminalSurface.rgbaToCss(fg);
      ctx.font = this.canvasFont(cell.bold, cell.italic);
      ctx.textBaseline = 'middle';
      ctx.fillText(cell.ch, x, y + this.cellH * 0.50);
      if (cell.underline) {
        ctx.strokeStyle = ctx.fillStyle;
        ctx.lineWidth = Math.max(1, this.cellH * 0.06);
        ctx.beginPath();
        ctx.moveTo(x, y + this.cellH - Math.max(1, this.cellH * 0.12));
        ctx.lineTo(x + paintWidth, y + this.cellH - Math.max(1, this.cellH * 0.12));
        ctx.stroke();
      }
    }
  }

  /** 画光标 — 底部细下划线 */
  private drawCursor(): void {
    const snap: TerminalCoreSnapshot | null = this.lastSnapshot;
    if (!snap) { return; }
    const cursorViewY: number = this.cursorViewY(snap);
    const cursorX: number = snap.cursorX;
    if (this.cursorVisible && snap.cursorVisible && cursorViewY >= 0 && cursorViewY < snap.rows &&
      cursorX >= 0 && cursorX < snap.cols) {
      const ctx: CanvasRenderingContext2D = this.ctx;
      const cx: number = cursorX * this.cellW;
      const cy: number = this.gridTop() + cursorViewY * this.cellH;
      const lineH: number = Math.max(3, Math.min(5, Math.round(this.cellH * 0.18)));
      const lineW: number = Math.max(4, this.cellW - 2);
      ctx.fillStyle = this.terminalFgColor;
      ctx.fillRect(cx + 1, cy + this.cellH - lineH - 1, lineW, lineH);
    }
    this.lastCursorX = cursorX;
    this.lastCursorY = cursorViewY;
  }

  // ============================================================
  // 滚动 — 触控 / 鼠标滚轮 / 触摸板
  // ============================================================

  private scrollByLines(deltaLines: number): void {
    if (this.handle <= 0 || deltaLines === 0) { return; }
    const beforeViewTop: number = this.lastSnapshot ? this.lastSnapshot.viewTop : -1;
    const beforeScreenTop: number = this.lastSnapshot ? this.lastSnapshot.screenTop : -1;
    this.bridge.scrollView(this.handle, deltaLines);
    this.lastSnapshot = this.bridge.snapshot(this.handle);
    this.followBottom = this.lastSnapshot.isAtBottom;
    hilog.info(0x0000, 'NativeTerminal',
      `[touchDiag] scrolled delta=${deltaLines} viewTop=${beforeViewTop}->${this.lastSnapshot.viewTop} ` +
      `screenTop=${beforeScreenTop}->${this.lastSnapshot.screenTop} atBottom=${this.lastSnapshot.isAtBottom}`);
    this.renderFull();
  }

  build() {
    Canvas(this.ctx)
      .onReady((): void => {
        this.markCanvasReady();
      })
      .width('100%')
      .height('100%')
      .backgroundColor(TERMINAL_BG_CSS)
      .onAreaChange((_o: Area, n: Area): void => {
        const area: string =
          `size=${n.width}x${n.height} position=${JSON.stringify(n.position) ?? ''} ` +
          `global=${JSON.stringify(n.globalPosition) ?? ''}`;
        if (area !== this.lastCanvasArea) {
          this.lastCanvasArea = area;
          hilog.info(0x0000, 'NativeTerminal', `[areaDiag] canvas ${area}`);
        }
        if (n.width > 0 && n.height > 0 &&
          (!this.canvasReady || this.surfaceReadyProbePending)) {
          // Reused ArkUI surfaces can skip a second onReady callback; a
          // positive laid-out canvas is safe to render and consume into.
          this.markCanvasReady();
        }
      })
      .focusable(false)
  }
}
