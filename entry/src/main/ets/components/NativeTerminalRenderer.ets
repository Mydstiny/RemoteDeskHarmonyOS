/**
 * NativeTerminalRenderer.ets — Rust terminal_core 驱动的 Canvas 渲染器
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
import { TerminalCoreBridge, TerminalCoreSnapshot, TerminalCoreCell } from '../napi/TerminalCoreBridge';
import {
  shouldAutoScrollToBottomAfterViewportChange,
  shouldHonorAutoScrollToBottom,
  terminalGridTop
} from '../services/SshTerminalScrollPolicy';

/** 默认前景色 (与 Rust DEFAULT_FG = 0xFFE8EAED 一致, 用于 cell.fg 比较) */
const DEFAULT_FG: number = 0xFFE8EAED;
/** 默认背景色 (与 Rust DEFAULT_BG = 0xFF0B0F14 一致, 用于 cell.bg 比较) */
const DEFAULT_BG: number = 0xFF0B0F14;
/** 终端统一背景 CSS 色 — 与 Theme.terminalBg / TerminalEmulator.DEFAULT_BG 一致, 避免 Canvas 与页面底色不匹配 */
const TERMINAL_BG_CSS: string = '#0D0D0D';
/** 选区高亮底色 */
const SELECTION_BG: string = 'rgba(90,140,255,0.40)';

@Component
export struct NativeTerminalRenderer {
  @Prop @Watch('onResize') cols: number = 80;
  @Prop @Watch('onResize') rows: number = 24;
  @Prop @Watch('onViewportHeightChange') viewportHeight: number = 0;
  @Prop @Watch('onViewportHeightChange') visibleViewportHeight: number = 0;
  /** SshTerminal 传入的 cell 尺寸 (vp), 与 Canvas 测量解耦, 保证 cols×cellW 精确填满终端宽度 */
  @Prop @Watch('onCellSizeChange') cellWvp: number = 9;
  @Prop @Watch('onCellSizeChange') cellHvp: number = 20;
  @Prop @Watch('onFontChange') fontSize: number = 18;
  @Prop @Watch('onInputChange') inputData: string = '';
  @StorageProp('terminalFgColor') @Watch('onFgColorChange') terminalFgColor: string = '#33FF33';
  @Prop selectMode: boolean = false;
  @Prop bottomAlignSparseContent: boolean = false;
  @Prop @Watch('onScrollToBottomRequest') scrollToBottomRequest: number = 0;
  @Prop externalScrollLines: number = 0;
  @Prop @Watch('onExternalScrollRequest') externalScrollRequest: number = 0;
  @Link @Watch('onCopyRequest') copyRequest: number;
  @Link copiedText: string;
  onData?: (data: string) => void;

  /** 终端核心句柄 (Rust heap 分配) */
  private handle: number = 0;
  private bridge: TerminalCoreBridge = new TerminalCoreBridge();
  private ctx: CanvasRenderingContext2D =
    new CanvasRenderingContext2D(new RenderingContextSettings(true));
  @State cellW: number = 9;
  @State cellH: number = 20;

  /** 最新完整快照缓存 — 用于全屏复制 (getContent) 和 drawCellAt */
  private lastSnapshot: TerminalCoreSnapshot | null = null;
  /** 脏行集合 (从 Rust dirtySnapshot 获取) */
  private dirtyRows: Set<number> = new Set();
  /** 光标闪烁 */
  private blinkTimer: number = -1;
  private cursorVisible: boolean = true;
  /** 上一次绘制时光标的位置 — 用于擦除旧光标 */
  private lastCursorX: number = 0;
  private lastCursorY: number = 0;
  /** 输入增量追踪 */
  private lastInputLen: number = 0;
  /** 上一次 rows (用于检测 resize) */
  private lastRows: number = 24;
  /** 用户/键盘把视图带到底部后, 后续 resize 和输出持续跟随底部, 直到用户主动上滑 */
  private followBottom: boolean = true;
  /** 帧计数器 — 用于稀疏日志采样 */
  private frameCount: number = 0;
  /** 上一次绘制使用的顶部偏移, 偏移变化时需要全量重绘避免残影 */
  private lastGridTop: number = 0;

  aboutToAppear(): void {
    this.resetLifecycleState();
    this.lastRows = this.rows;
    this.calcCellSize();
    this.handle = this.bridge.create(this.cols, this.rows);
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
    if (this.handle > 0) {
      this.bridge.destroy(this.handle);
      this.handle = 0;
    }
    this.resetLifecycleState();
  }

  /** ArkUI 可能复用组件实例；Rust handle 重建时增量游标也必须同步归零。 */
  private resetLifecycleState(): void {
    this.lastSnapshot = null;
    this.dirtyRows.clear();
    this.cursorVisible = true;
    this.lastCursorX = 0;
    this.lastCursorY = 0;
    this.lastInputLen = 0;
    this.followBottom = true;
    this.frameCount = 0;
    this.lastGridTop = 0;
    this.lastViewportHeight = 0;
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
    this.renderFull();
  }

  /** 父页面请求回到底部 — 键盘弹起/终端高度变化后保证最新行可见 */
  private onScrollToBottomRequest(): void {
    if (!shouldHonorAutoScrollToBottom(this.followBottom)) { return; }
    this.scrollToBottomAndRender();
  }

  private onExternalScrollRequest(): void {
    hilog.info(0x0000, 'NativeTerminal',
      `[touchDiag] external req=${this.externalScrollRequest} lines=${this.externalScrollLines} ` +
      `handle=${this.handle} follow=${this.followBottom}`);
    this.scrollByLines(this.externalScrollLines);
  }

  private onResize(): void {
    if (this.cols <= 0 || this.rows <= 0) { return; }
    if (this.handle > 0) {
      this.bridge.resize(this.handle, this.cols, this.rows);
      if (this.followBottom) {
        this.bridge.scrollToBottom(this.handle);
      }
      this.lastSnapshot = this.bridge.snapshot(this.handle);
    }
    this.lastRows = this.rows;
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

  private onInputChange(): void {
    if (this.handle <= 0) { return; }
    const curLen: number = this.inputData.length;
    if (curLen > this.lastInputLen) {
      // 增量数据
      const added: string = this.inputData.substring(this.lastInputLen);
      this.bridge.write(this.handle, added);
      if (this.followBottom) {
        this.bridge.scrollToBottom(this.handle);
      }
      this.applyDirtySnapshot();
    } else if (curLen < this.lastInputLen) {
      // 截断 (父级限制 50KB): 重建终端, 全量重放
      this.bridge.destroy(this.handle);
      this.handle = this.bridge.create(this.cols, this.rows);
      if (this.inputData.length > 0) {
        this.bridge.write(this.handle, this.inputData);
      }
      if (this.followBottom) {
        this.bridge.scrollToBottom(this.handle);
      }
      this.lastSnapshot = this.bridge.snapshot(this.handle);
      this.renderFull();
    }
    this.lastInputLen = curLen;
  }

  /** 获取脏快照并增量渲染 */
  private applyDirtySnapshot(): void {
    if (this.handle <= 0) { return; }
    this.frameCount++;
    const snap: TerminalCoreSnapshot = this.bridge.dirtySnapshot(this.handle);
    this.lastSnapshot = snap;
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

  private canvasFont(bold: boolean): string {
    return `${bold ? 'bold ' : ''}${this.fontSize}vp monospace`;
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
    const visibleH: number = this.visibleViewportHeight > 0 ? this.visibleViewportHeight : this.viewportHeight;
    const topInset: number = Math.max(0, this.viewportHeight - visibleH);
    const hasScrollback: boolean = snap.screenTop > 0 || snap.viewTop > 0;
    const sparseLimit: number = Math.min(visibleH * 0.35, this.cellH * 8);
    return terminalGridTop(
      this.bottomAlignSparseContent,
      topInset,
      visibleH,
      this.rows * this.cellH,
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
    ctx.fillRect(0, 0, this.cols * this.cellW, top);
  }

  private canvasHeight(): number {
    return Math.max(this.rows * this.cellH, Math.ceil(this.viewportHeight));
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
    if (this.cellW <= 0 || this.cellH <= 0 || this.cols <= 0 || this.rows <= 0) { return; }
    const top: number = this.gridTop();
    const ctx: CanvasRenderingContext2D = this.ctx;
    ctx.fillStyle = TERMINAL_BG_CSS;
    ctx.fillRect(0, 0, this.cols * this.cellW, this.canvasHeight());
    this.clearTopInset();
    for (let r = 0; r < this.rows; r++) {
      this.drawRow(r);
    }
    this.drawCursor();
    this.dirtyRows.clear();
    this.lastGridTop = top;
  }

  private renderIncremental(): void {
    if (this.cellW <= 0 || this.cellH <= 0) { return; }
    const top: number = this.gridTop();
    if (top !== this.lastGridTop) {
      this.renderFull();
      return;
    }
    this.eraseOldCursor();
    this.dirtyRows.forEach((absR: number): void => {
      // dirtyRows 是快照中的视口行号 (0..rows-1)
      if (absR >= 0 && absR < this.rows) {
        this.drawRow(absR);
      }
    });
    this.drawCursor();
    this.dirtyRows.clear();
  }

  private renderCursorOnly(): void {
    if (this.cellW <= 0 || this.cellH <= 0) { return; }
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
    if (r < 0 || r >= this.rows) { return; }
    const snap: TerminalCoreSnapshot | null = this.lastSnapshot;
    if (!snap) { return; }
    const ctx: CanvasRenderingContext2D = this.ctx;
    const y: number = this.gridTop() + r * this.cellH;
    // 清整行 — 使用统一终端背景色
    ctx.fillStyle = TERMINAL_BG_CSS;
    ctx.fillRect(0, y, this.cols * this.cellW, this.cellH);
    for (let c = 0; c < this.cols; c++) {
      const idx: number = r * snap.cols + c;
      if (idx >= snap.cells.length) { continue; }
      const cell: TerminalCoreCell = snap.cells[idx];
      const x: number = c * this.cellW;
      // 背景 (非默认色)
      if (cell.bg !== DEFAULT_BG && cell.ch !== ' ') {
        ctx.fillStyle = NativeTerminalRenderer.rgbaToCss(cell.bg);
        ctx.fillRect(x, y, this.cellW, this.cellH);
      }
      // 前景字符
      if (cell.ch === ' ' || cell.ch === '\x00') { continue; }
      // 默认前景色用用户设置的 terminalFgColor 替代 Rust 硬编码灰色
      ctx.fillStyle = (cell.fg === DEFAULT_FG) ? this.terminalFgColor : NativeTerminalRenderer.rgbaToCss(cell.fg);
      ctx.font = this.canvasFont(cell.bold);
      ctx.textBaseline = 'middle';
      ctx.fillText(cell.ch, x, y + this.cellH * 0.50);
    }
  }

  /** 画单个 cell — 用于 eraseOldCursor */
  private drawCellAt(r: number, c: number): void {
    if (r < 0 || r >= this.rows || c < 0 || c >= this.cols) { return; }
    const snap: TerminalCoreSnapshot | null = this.lastSnapshot;
    const ctx: CanvasRenderingContext2D = this.ctx;
    const x: number = c * this.cellW;
    const y: number = this.gridTop() + r * this.cellH;
    // 清该格 — 使用统一终端背景色
    ctx.fillStyle = TERMINAL_BG_CSS;
    ctx.fillRect(x, y, this.cellW, this.cellH);
    if (!snap) { return; }
    const idx: number = r * snap.cols + c;
    if (idx < snap.cells.length) {
      const cell: TerminalCoreCell = snap.cells[idx];
      if (cell.ch !== ' ' && cell.ch !== '\x00') {
        if (cell.bg !== DEFAULT_BG) {
          ctx.fillStyle = NativeTerminalRenderer.rgbaToCss(cell.bg);
          ctx.fillRect(x, y, this.cellW, this.cellH);
        }
        ctx.fillStyle = (cell.fg === DEFAULT_FG) ? this.terminalFgColor : NativeTerminalRenderer.rgbaToCss(cell.fg);
        ctx.font = this.canvasFont(cell.bold);
        ctx.textBaseline = 'middle';
        ctx.fillText(cell.ch, x, y + this.cellH * 0.50);
      }
    }
  }

  /** 画光标 — 底部细下划线 */
  private drawCursor(): void {
    const snap: TerminalCoreSnapshot | null = this.lastSnapshot;
    if (!snap) { return; }
    const cursorViewY: number = this.cursorViewY(snap);
    const cursorX: number = snap.cursorX;
    if (this.cursorVisible && cursorViewY >= 0 && cursorViewY < this.rows &&
      cursorX >= 0 && cursorX < this.cols) {
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
        this.calcCellSize();
        if (this.handle > 0) {
          this.lastSnapshot = this.bridge.snapshot(this.handle);
        }
        this.renderFull();
      })
      .width('100%')
      .height('100%')
      .backgroundColor(TERMINAL_BG_CSS)
      .focusable(false)
  }
}
