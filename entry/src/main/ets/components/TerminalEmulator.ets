/**
 * TerminalEmulator.ets — Canvas 终端模拟器 (v4 增量渲染版)
 *
 * 改进 (相对 v3):
 *   1. dirtyRows 脏行集合 + renderIncremental: 每帧只重画修改过的行 + 光标 cell
 *   2. blinkTimer 530ms 仅画光标 cell, 不再触发整屏重画 (CPU 从 cols×rows 降到 1)
 *   3. cursorX/Y 在所有 CSI 路径统一夹紧到 [0, rows-1] / [0, cols-1]
 *   4. Canvas 尺寸 100% 自适应, 由父容器 onAreaChange 提供 termAreaW/H
 *   5. 字号变化 / 列数变化 / scroll 触发 renderFull, 其他全部走 renderIncremental
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  shouldAutoScrollToBottomAfterViewportChange,
  shouldHonorAutoScrollToBottom,
  terminalGridTop
} from '../services/SshTerminalScrollPolicy';

/** 终端字符单元格 */
interface TerminalCell {
  ch: string;
  fg: string;
  bg: string;
  bold: boolean;
  inverse: boolean;
}

const DEFAULT_BG = '#0D0D0D';
/** 选区高亮底色 (半透明蓝) */
const SELECTION_BG = 'rgba(90,140,255,0.40)';

// ANSI 8色表
const ANSI_COLORS: string[] = [
  '#1C1C1C','#CD0000','#00CD00','#CDCD00',
  '#0000EE','#CD00CD','#00CDCD','#E5E5E5'
];
const ANSI_BRIGHT: string[] = [
  '#555753','#FF0000','#00FF00','#FFFF00',
  '#5C5CFF','#FF00FF','#00FFFF','#FFFFFF'
];

/** 256 色调色板 */
function make256Colors(): string[] {
  const c: string[] = [];
  c.push('#1C1C1C','#CD0000','#00CD00','#CDCD00','#0000EE','#CD00CD','#00CDCD','#E5E5E5');
  c.push('#555753','#FF0000','#00FF00','#FFFF00','#5C5CFF','#FF00FF','#00FFFF','#FFFFFF');
  for (let r = 0; r < 6; r++) {
    for (let g = 0; g < 6; g++) {
      for (let b = 0; b < 6; b++) {
        const rr = r > 0 ? (r * 40 + 55).toString(16).padStart(2, '0') : '00';
        const gg = g > 0 ? (g * 40 + 55).toString(16).padStart(2, '0') : '00';
        const bb = b > 0 ? (b * 40 + 55).toString(16).padStart(2, '0') : '00';
        c.push(`#${rr}${gg}${bb}`);
      }
    }
  }
  for (let i = 0; i < 24; i++) {
    const v = (i * 10 + 8).toString(16).padStart(2, '0');
    c.push(`#${v}${v}${v}`);
  }
  return c;
}
const COL256: string[] = make256Colors();

@Component
export struct TerminalEmulator {
  @Prop @Watch('onResize') cols: number = 80;
  @Prop @Watch('onResize') rows: number = 24;
  /** 父组件 SshTerminal 传入的 cell 尺寸 (vp), 与 Canvas 解耦以保证 cols×cellW 精确填满终端宽度 */
  @Prop @Watch('onCellSizeChange') cellWvp: number = 9;
  @Prop @Watch('onCellSizeChange') cellHvp: number = 20;
  @Prop @Watch('onViewportSizeChange') viewportWidth: number = 0;
  @Prop @Watch('onViewportHeightChange') viewportHeight: number = 0;
  @Prop @Watch('onViewportHeightChange') visibleViewportHeight: number = 0;
  @Prop @Watch('onFontChange') fontSize: number = 18;
  @Prop @Watch('onInputChange') inputData: string = '';
  @StorageProp('terminalFgColor') @Watch('onFgColorChange') terminalFgColor: string = '#33FF33';
  /** 选区模式 — 由父级长按菜单"选择"开启; 开启时 touch 拖选而非滚动 */
  @Prop @Watch('onSelectModeChange') selectMode: boolean = false;
  @Prop bottomAlignSparseContent: boolean = false;
  /** 父页面请求回到底部 — 键盘弹起/终端高度变化后保证最新行可见 */
  @Prop @Watch('onScrollToBottomRequest') scrollToBottomRequest: number = 0;
  @Prop @Watch('onForceScrollToBottomRequest') forceScrollToBottomRequest: number = 0;
  @Prop externalScrollLines: number = 0;
  @Prop @Watch('onExternalScrollRequest') externalScrollRequest: number = 0;
  /** 复制请求计数器 — 父级 ++ 触发本组件把选区/整屏文本写入 copiedText */
  @Link @Watch('onCopyRequest') copyRequest: number;
  /** 复制结果回传给父级 (父级再写系统剪贴板) */
  @Link copiedText: string;
  onData?: (data: string) => void;
  private lastInputLen: number = 0;

  /** 选区锚点/终点 (绝对行号 + 列), -1 表示无选区 */
  private selStartAbsR: number = -1;
  private selStartC: number = -1;
  private selEndAbsR: number = -1;
  private selEndC: number = -1;

  /** inputData 增量处理 */
  private onInputChange(): void {
    const curLen: number = this.inputData.length;
    if (curLen > this.lastInputLen) {
      const added: string = this.inputData.substring(this.lastInputLen);
      this.write(added);
    } else if (curLen < this.lastInputLen) {
      // 截断 → 清空旧 buffer 后全量重写, 避免把裁剪后的内容重复追加到屏幕上
      this.resetTerminalState();
      this.write(this.inputData);
    }
    this.lastInputLen = curLen;
  }

  /** 字号变化 → 重测 cellW/cellH + 全量重绘 */
  private onFontChange(): void {
    this.calcCellSize();
    this.markAllDirty();
    this.renderFull();
  }

  private onCellSizeChange(): void {
    this.calcCellSize();
    this.markAllDirty();
    this.renderFull();
  }

  /** 前景色设置变更 → 更新默认 fgColor + 全量重绘 */
  private onFgColorChange(): void {
    this.fgColor = this.terminalFgColor;
    // 重置默认前景色 (ANSI SGR 0 会用到)
    this.markAllDirty();
    this.renderFull();
  }

  /** 选区模式开关变化 — 关闭时清空选区并重绘 */
  private onSelectModeChange(): void {
    if (!this.selectMode) {
      this.clearSelection();
      this.markAllDirty();
      this.renderFull();
    }
  }

  private onScrollToBottomRequest(): void {
    if (!shouldHonorAutoScrollToBottom(this.followBottom)) { return; }
    this.viewOffset = this.screenTop;
    this.cursorVisible = true;
    this.markAllDirty();
    this.renderFull();
  }

  private onForceScrollToBottomRequest(): void {
    this.followBottom = true;
    this.viewOffset = this.screenTop;
    this.cursorVisible = true;
    this.markAllDirty();
    this.renderFull();
  }

  private onExternalScrollRequest(): void {
    hilog.info(0x0000, 'TerminalEmu',
      `[touchDiag] external req=${this.externalScrollRequest} lines=${this.externalScrollLines} ` +
      `viewOffset=${this.viewOffset} screenTop=${this.screenTop} follow=${this.followBottom}`);
    this.scrollByLines(this.externalScrollLines);
  }

  private onViewportHeightChange(): void {
    const previousViewportHeight: number = this.lastViewportHeight;
    this.lastViewportHeight = this.viewportHeight;
    if (shouldAutoScrollToBottomAfterViewportChange(this.followBottom, previousViewportHeight, this.viewportHeight)) {
      this.viewOffset = this.screenTop;
    }
    this.markAllDirty();
    this.renderFull();
  }

  private onViewportSizeChange(): void {
    this.renderFull();
  }

  /** 父级请求复制 — 把当前选区 (无选区则整屏) 文本写入 copiedText 回传 */
  private onCopyRequest(): void {
    this.copiedText = this.getSelection();
  }

  /** 清空选区坐标 */
  private clearSelection(): void {
    this.selStartAbsR = -1;
    this.selStartC = -1;
    this.selEndAbsR = -1;
    this.selEndC = -1;
  }

  /** 选区是否有效 */
  private hasSelection(): boolean {
    return this.selStartAbsR >= 0 && this.selEndAbsR >= 0;
  }

  /**
   * 把 (start, end) 规范化为行优先顺序的 [上界, 下界]。
   * 返回 [r0, c0, r1, c1], 保证 (r0,c0) <= (r1,c1)。
   */
  private normSelection(): number[] {
    let r0: number = this.selStartAbsR;
    let c0: number = this.selStartC;
    let r1: number = this.selEndAbsR;
    let c1: number = this.selEndC;
    if (r1 < r0 || (r1 === r0 && c1 < c0)) {
      const tr: number = r0; r0 = r1; r1 = tr;
      const tc: number = c0; c0 = c1; c1 = tc;
    }
    return [r0, c0, r1, c1];
  }

  /** 绝对单元 (absR, c) 是否落在选区内 */
  private isCellSelected(absR: number, c: number): boolean {
    if (!this.hasSelection()) { return false; }
    const n: number[] = this.normSelection();
    const r0: number = n[0]; const c0: number = n[1]; const r1: number = n[2]; const c1: number = n[3];
    if (absR < r0 || absR > r1) { return false; }
    if (absR === r0 && absR === r1) { return c >= c0 && c <= c1; }
    if (absR === r0) { return c >= c0; }
    if (absR === r1) { return c <= c1; }
    return true;  // 中间整行
  }

  private ctx: CanvasRenderingContext2D = new CanvasRenderingContext2D(new RenderingContextSettings(true));
  private buffer: TerminalCell[][] = [];
  private wrappedRows: boolean[] = [];
  private screenTop: number = 0;
  private viewOffset: number = 0;
  private readonly MAX_SCROLLBACK: number = 3000;
  private cursorX: number = 0;
  private cursorY: number = 0;  // 视口内行号 [0, rows-1]
  private fgColor: string = '#33FF33';
  private bgColor: string = DEFAULT_BG;
  private boldFlag: boolean = false;
  private inverseFlag: boolean = false;
  private cursorVisible: boolean = true;
  private scrollTop: number = 0;
  private scrollBottom: number = 24;
  private escState: number = 0;
  private escParams: number[] = [];
  private escParam: string = '';
  private csiPrivate: boolean = false;

  // cellW/cellH 必须 @State — Canvas 字号自适应需引用
  @State cellW: number = 8;
  @State cellH: number = 18;

  /** 脏行集合 (绝对行号) — 仅 viewOffset..viewOffset+rows 范围内重画 */
  private dirtyRows: Set<number> = new Set();
  /** 上次画光标的位置 (用于擦除旧光标) */
  private lastCursorX: number = 0;
  private lastCursorAbsR: number = 0;

  private blinkTimer: number = -1;
  private lastRows: number = 24;
  /** 用户/键盘把视图带到底部后, 后续 resize 和输出持续跟随底部, 直到用户主动上滑 */
  private followBottom: boolean = true;
  /** 上一次绘制使用的顶部偏移, 偏移变化时需要全量重绘避免残影 */
  private lastGridTop: number = 0;
  private lastViewportHeight: number = 0;

  aboutToAppear(): void {
    this.resetLifecycleState();
    this.scrollBottom = this.rows - 1;
    this.lastRows = this.rows;
    this.fgColor = this.terminalFgColor;
    this.calcCellSize();
    this.initBuffer();
    // 光标 530ms 闪烁 — 仅画光标 cell, 不全屏重画
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
    this.resetLifecycleState();
  }

  /** ArkUI 复用组件时清除上一 SSH 会话的增量、滚动和选择状态。 */
  private resetLifecycleState(): void {
    this.lastInputLen = 0;
    this.followBottom = true;
    this.lastGridTop = 0;
    this.lastViewportHeight = 0;
    this.cursorVisible = true;
    this.lastCursorX = 0;
    this.lastCursorAbsR = 0;
    this.clearSelection();
    this.resetTerminalState();
  }

  /** 容器尺寸 / cols / rows 变化 */
  private onResize(): void {
    if (this.cols <= 0 || this.rows <= 0) { return; }
    const oldRows: number = this.lastRows > 0 ? this.lastRows : this.rows;
    const oldMaxOffset: number = Math.max(0, this.buffer.length - oldRows);
    const wasAtBottom: boolean = this.followBottom || this.viewOffset >= oldMaxOffset;
    this.calcCellSize();
    // 1. 调整每行列数
    for (let r = 0; r < this.buffer.length; r++) {
      while (this.buffer[r].length < this.cols) {
        this.buffer[r].push({ ch: ' ', fg: this.terminalFgColor, bg: DEFAULT_BG, bold: false, inverse: false });
      }
      if (this.buffer[r].length > this.cols) {
        this.buffer[r] = this.buffer[r].slice(0, this.cols);
      }
    }
    while (this.wrappedRows.length < this.buffer.length) {
      this.wrappedRows.push(false);
    }
    for (let r = 0; r < this.wrappedRows.length; r++) {
      this.wrappedRows[r] = false;
    }
    // 2. 确保 buffer 至少覆盖真实屏幕和当前可视窗口
    const requiredRows: number = Math.max(this.screenTop, this.viewOffset) + this.rows;
    while (this.buffer.length < requiredRows) {
      this.buffer.push(this.makeEmptyRow());
      this.wrappedRows.push(false);
    }
    while (this.buffer.length > this.MAX_SCROLLBACK) {
      this.buffer.shift();
      this.wrappedRows.shift();
      if (this.screenTop > 0) { this.screenTop--; }
      if (this.viewOffset > 0) { this.viewOffset--; }
    }
    // 3. 视口 / 光标夹紧
    this.clampCursor();
    const newMaxOffset: number = Math.max(0, this.buffer.length - this.rows);
    this.screenTop = wasAtBottom ? newMaxOffset : Math.max(0, Math.min(this.screenTop, newMaxOffset));
    this.viewOffset = wasAtBottom ? newMaxOffset : Math.max(0, Math.min(this.viewOffset, newMaxOffset));
    this.scrollBottom = this.rows - 1;
    this.lastRows = this.rows;
    this.markAllDirty();
    this.renderFull();
  }

  private makeEmptyRow(): TerminalCell[] {
    const row: TerminalCell[] = [];
    for (let c = 0; c < this.cols; c++) {
      row.push({ ch: ' ', fg: this.terminalFgColor, bg: DEFAULT_BG, bold: false, inverse: false });
    }
    return row;
  }

  /** 计算 cellW/cellH — 使用父组件传入的 vp 尺寸, 避免 Canvas measureText DPI 偏差 */
  private calcCellSize(): void {
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
    let bottomRow: number = this.cursorY;
    const maxRow: number = Math.min(this.rows - 1, this.buffer.length - this.viewOffset - 1);
    for (let r = maxRow; r >= 0; r--) {
      const absR: number = this.viewOffset + r;
      const row: TerminalCell[] = this.buffer[absR];
      for (let c = 0; c < this.cols && c < row.length; c++) {
        if (row[c].ch !== ' ' && row[c].ch !== '\x00') {
          bottomRow = Math.max(bottomRow, r);
          r = -1;
          break;
        }
      }
    }
    if (bottomRow < 0) { bottomRow = 0; }
    const contentH: number = (bottomRow + 1) * this.cellH;
    const visibleH: number = this.visibleViewportHeight > 0 ? this.visibleViewportHeight : this.viewportHeight;
    const topInset: number = Math.max(0, this.viewportHeight - visibleH);
    // 存在历史缓冲不等于当前正在浏览历史。回到底部后，横屏扩大为竖屏时
    // 当前内容可能只占前几行，移动端需要继续执行稀疏内容的底对齐。
    const hasScrollback: boolean = this.viewOffset < this.screenTop;
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
    ctx.fillStyle = DEFAULT_BG;
    ctx.fillRect(0, 0, this.canvasWidth(), top);
  }

  private canvasWidth(): number {
    return Math.max(this.cols * this.cellW, Math.ceil(this.viewportWidth));
  }

  private canvasHeight(): number {
    return Math.max(this.rows * this.cellH, Math.ceil(this.viewportHeight));
  }

  private initBuffer(): void {
    this.buffer = [];
    this.wrappedRows = [];
    for (let r = 0; r < this.rows; r++) {
      this.buffer.push(this.makeEmptyRow());
      this.wrappedRows.push(false);
    }
    this.screenTop = 0;
    this.viewOffset = 0;
    this.cursorX = 0;
    this.cursorY = 0;
    this.markAllDirty();
  }

  /** 重置终端解析和显示状态, 用于父级输出截断后的全量重放。 */
  private resetTerminalState(): void {
    this.initBuffer();
    this.fgColor = this.terminalFgColor;
    this.bgColor = DEFAULT_BG;
    this.boldFlag = false;
    this.inverseFlag = false;
    this.scrollTop = 0;
    this.scrollBottom = this.rows - 1;
    this.escState = 0;
    this.escParams = [];
    this.escParam = '';
    this.csiPrivate = false;
  }

  /** 标记所有可见行为脏 */
  private markAllDirty(): void {
    this.dirtyRows.clear();
    for (let r = 0; r < this.rows; r++) {
      this.dirtyRows.add(this.viewOffset + r);
    }
  }

  /** 把绝对行 absR 标为脏 (仅当在可视范围内才有意义) */
  private markRowDirty(absR: number): void {
    this.dirtyRows.add(absR);
  }

  private clearCell(cell: TerminalCell): void {
    cell.ch = ' ';
    cell.fg = this.terminalFgColor;
    cell.bg = DEFAULT_BG;
    cell.bold = false;
    cell.inverse = false;
  }

  private copyCell(dst: TerminalCell, src: TerminalCell): void {
    dst.ch = src.ch;
    dst.fg = src.fg;
    dst.bg = src.bg;
    dst.bold = src.bold;
    dst.inverse = src.inverse;
  }

  private markCurrentRowWrapped(): void {
    const absR: number = this.screenTop + this.cursorY;
    while (absR >= this.wrappedRows.length) {
      this.wrappedRows.push(false);
    }
    this.wrappedRows[absR] = true;
  }

  private clearCurrentWrapMarker(): void {
    const absR: number = this.screenTop + this.cursorY;
    while (absR >= this.wrappedRows.length) {
      this.wrappedRows.push(false);
    }
    this.wrappedRows[absR] = false;
  }

  private canReverseWrapCursor(): boolean {
    if (this.cursorY <= 0) { return false; }
    if (this.scrollTop !== 0 || this.scrollBottom !== this.rows - 1) { return false; }
    const prevAbs: number = this.screenTop + this.cursorY - 1;
    return prevAbs >= 0 && prevAbs < this.wrappedRows.length && this.wrappedRows[prevAbs];
  }

  private canForwardWrapCursor(): boolean {
    if (this.cursorY >= this.rows - 1) { return false; }
    if (this.scrollTop !== 0 || this.scrollBottom !== this.rows - 1) { return false; }
    const absR: number = this.screenTop + this.cursorY;
    return absR >= 0 && absR < this.wrappedRows.length && this.wrappedRows[absR];
  }

  private moveCursorHorizontal(delta: number): void {
    if (delta < 0) {
      for (let i = 0; i < -delta; i++) {
        if (this.cursorX > 0) {
          this.cursorX--;
        } else if (this.canReverseWrapCursor()) {
          this.cursorY--;
          this.cursorX = this.cols - 1;
        } else {
          break;
        }
      }
      return;
    }

    for (let i = 0; i < delta; i++) {
      if (this.cursorX < this.cols - 1) {
        this.cursorX++;
      } else if (this.canForwardWrapCursor()) {
        this.cursorY++;
        this.cursorX = 0;
      } else {
        break;
      }
    }
  }

  /** 光标位置夹紧 — 所有 CSI/写入路径调用前后用 */
  private clampCursor(): void {
    if (this.cursorY < 0) { this.cursorY = 0; }
    if (this.cursorY > this.rows - 1) { this.cursorY = this.rows - 1; }
    if (this.cursorX < 0) { this.cursorX = 0; }
    if (this.cursorX > this.cols - 1) { this.cursorX = this.cols - 1; }
  }

  // ============================================================
  // 渲染 — Full / Incremental / CursorOnly
  // ============================================================

  /** 全量重绘 — 仅在 resize/font/scroll/initBuffer 时使用 */
  private renderFull(): void {
    if (this.cellW <= 0 || this.cellH <= 0 || this.cols <= 0 || this.rows <= 0) { return; }
    const gridTop: number = this.gridTop();
    const ctx: CanvasRenderingContext2D = this.ctx;
    ctx.fillStyle = DEFAULT_BG;
    ctx.fillRect(0, 0, this.canvasWidth(), this.canvasHeight());
    this.clearTopInset();
    for (let r = 0; r < this.rows; r++) {
      this.drawRow(r);
    }
    this.drawCursor();
    this.dirtyRows.clear();
    this.lastGridTop = gridTop;
  }

  /** 统一滚动回滚区, 供触摸拖动、鼠标滚轮和触控板共用 */
  private scrollByLines(lines: number): void {
    const wholeLines: number = lines > 0 ? Math.ceil(lines) : Math.floor(lines);
    if (wholeLines === 0) { return; }
    const maxOffset: number = Math.max(0, this.screenTop);
    const beforeOffset: number = this.viewOffset;
    const clamped: number = Math.max(0, Math.min(maxOffset, this.viewOffset + wholeLines));
    if (clamped !== this.viewOffset) {
      this.viewOffset = clamped;
      this.followBottom = this.viewOffset >= this.screenTop;
      this.markAllDirty();
      this.renderFull();
    }
    hilog.info(0x0000, 'TerminalEmu',
      `[touchDiag] scrolled delta=${wholeLines} viewOffset=${beforeOffset}->${this.viewOffset} ` +
      `screenTop=${this.screenTop} maxOffset=${maxOffset} follow=${this.followBottom}`);
  }

  /** 增量渲染 — 仅画 dirtyRows ∩ 可视范围 + 光标 */
  private renderIncremental(): void {
    if (this.cellW <= 0 || this.cellH <= 0) { return; }
    const gridTop: number = this.gridTop();
    if (gridTop !== this.lastGridTop) {
      this.renderFull();
      return;
    }
    this.eraseOldCursor();
    const top: number = this.viewOffset;
    const bot: number = this.viewOffset + this.rows;
    this.dirtyRows.forEach((absR: number): void => {
      if (absR >= top && absR < bot) {
        this.drawRow(absR - top);
      }
    });
    this.drawCursor();
    this.dirtyRows.clear();
  }

  /** 仅重画光标 cell — blinkTimer 调用 */
  private renderCursorOnly(): void {
    if (this.cellW <= 0 || this.cellH <= 0) { return; }
    // 擦除旧光标位置 (重画该 cell 的字符), 再画新光标 (如可见)
    this.eraseOldCursor();
    this.drawCursor();
  }

  /**
   * 擦除上一次光标所在格 — 重画该格字符即抹掉下划线。
   * 关键: 不依赖 cursorVisible。方向键纯移动光标 (无字符写入, dirtyRows 为空) +
   * blinkTimer 翻转可见性时, 旧光标格必须被无条件擦净, 否则下划线会在多个字母下残留。
   */
  private eraseOldCursor(): void {
    const viewR: number = this.lastCursorAbsR - this.viewOffset;
    this.drawCellAt(viewR, this.lastCursorX);
  }

  /** 画一整行 (视口行号 r) — 只清+画该行高度区域 */
  private drawRow(r: number): void {
    if (r < 0 || r >= this.rows) { return; }
    const ctx: CanvasRenderingContext2D = this.ctx;
    const absR: number = this.viewOffset + r;
    const y: number = this.gridTop() + r * this.cellH;
    // 清整行
    ctx.fillStyle = DEFAULT_BG;
    ctx.fillRect(0, y, this.canvasWidth(), this.cellH);
    if (absR >= this.buffer.length) { return; }
    const row: TerminalCell[] = this.buffer[absR];
    const selOnRow: boolean = this.hasSelection();
    for (let c = 0; c < this.cols && c < row.length; c++) {
      const cell: TerminalCell = row[c];
      const x: number = c * this.cellW;
      // 选区高亮底色 (在字符之下绘制)
      if (selOnRow && this.isCellSelected(absR, c)) {
        ctx.fillStyle = SELECTION_BG;
        ctx.fillRect(x, y, this.cellW, this.cellH);
      } else if (cell.bg !== DEFAULT_BG && cell.ch !== ' ' && cell.ch !== '\x00') {
        ctx.fillStyle = cell.bg;
        ctx.fillRect(x, y, this.cellW, this.cellH);
      }
      if (cell.ch === ' ' || cell.ch === '\x00') { continue; }
      // 前景文字
      ctx.fillStyle = cell.fg;
      ctx.font = this.canvasFont(cell.bold);
      ctx.textBaseline = 'middle';
      ctx.fillText(cell.ch, x, y + this.cellH * 0.50);
    }
  }

  /** 画单个 cell (视口行号 r, 列 c) — 用于擦除旧光标 */
  private drawCellAt(r: number, c: number): void {
    if (r < 0 || r >= this.rows || c < 0 || c >= this.cols) { return; }
    const ctx: CanvasRenderingContext2D = this.ctx;
    const absR: number = this.viewOffset + r;
    const x: number = c * this.cellW;
    const y: number = this.gridTop() + r * this.cellH;
    // 清单格
    ctx.fillStyle = DEFAULT_BG;
    ctx.fillRect(x, y, this.cellW, this.cellH);
    // 选区高亮 (擦除/重画单格时也要保留)
    if (this.hasSelection() && this.isCellSelected(absR, c)) {
      ctx.fillStyle = SELECTION_BG;
      ctx.fillRect(x, y, this.cellW, this.cellH);
    }
    if (absR >= 0 && absR < this.buffer.length) {
      const row: TerminalCell[] = this.buffer[absR];
      if (c < row.length) {
        const cell: TerminalCell = row[c];
        if (cell.ch !== ' ' && cell.ch !== '\x00') {
          if (cell.bg !== DEFAULT_BG && !this.isCellSelected(absR, c)) {
            ctx.fillStyle = cell.bg;
            ctx.fillRect(x, y, this.cellW, this.cellH);
          }
          ctx.fillStyle = cell.fg;
          ctx.font = this.canvasFont(cell.bold);
          ctx.textBaseline = 'middle';
          ctx.fillText(cell.ch, x, y + this.cellH * 0.50);
        }
      }
    }
  }

  /**
   * 画光标 (底部细下划线)。
   * 职责单一: 仅在可见时绘制下划线; 无论可见与否, 末尾都把 lastCursor 推进到当前位置。
   * 旧光标的擦除由 eraseOldCursor() 在调用本方法之前完成 — 二者解耦, 杜绝残留。
   */
  private drawCursor(): void {
    const cursorAbsR: number = this.screenTop + this.cursorY;
    const viewR: number = cursorAbsR - this.viewOffset;
    if (this.cursorVisible && viewR >= 0 && viewR < this.rows && this.cursorX >= 0 && this.cursorX < this.cols) {
      const ctx: CanvasRenderingContext2D = this.ctx;
      const cx: number = this.cursorX * this.cellW;
      const cy: number = this.gridTop() + viewR * this.cellH;
      const lineH: number = Math.max(3, Math.min(5, Math.round(this.cellH * 0.18)));
      const lineW: number = Math.max(4, this.cellW - 2);
      ctx.fillStyle = this.terminalFgColor;
      ctx.fillRect(cx + 1, cy + this.cellH - lineH - 1, lineW, lineH);
    }
    this.lastCursorX = this.cursorX;
    this.lastCursorAbsR = cursorAbsR;
  }

  /** 写入字符串到终端 */
  write(data: string): void {
    const wasAtBottom: boolean = this.followBottom || this.viewOffset >= this.screenTop;
    for (let i = 0; i < data.length; i++) {
      this.processChar(data.charCodeAt(i));
    }
    this.cursorVisible = true;
    if (wasAtBottom) {
      if (this.screenTop !== this.viewOffset) {
        this.viewOffset = this.screenTop;
        this.markAllDirty();
      }
      this.followBottom = true;
    } else {
      this.followBottom = false;
    }
    this.clampCursor();
    this.renderIncremental();
  }

  /** 单字符处理 */
  private processChar(code: number): void {
    if (this.escState === 1) {
      if (code === 0x5B) { this.escState = 2; this.escParams = []; this.escParam = ''; this.csiPrivate = false; return; }
      this.escState = 0;
      return;
    }
    if (this.escState === 2) {
      if (code === 0x3F) { this.csiPrivate = true; return; }
      if (code >= 0x30 && code <= 0x39) { this.escParam += String.fromCharCode(code); return; }
      if (code === 0x3B) {
        const v: number = parseInt(this.escParam) || 0;
        this.escParams.push(v);
        this.escParam = '';
        return;
      }
      const v2: number = parseInt(this.escParam) || 0;
      this.escParams.push(v2);
      this.execCsi(code, this.escParams);
      this.escState = 0;
      this.escParams = [];
      this.escParam = '';
      return;
    }
    if (code === 0x1B) { this.escState = 1; return; }
    this.putChar(code);
  }

  /** CSI 执行 (所有 cursor 写入后立即夹紧) */
  private execCsi(cmd: number, p: number[]): void {
    if (this.csiPrivate) {
      if (cmd === 0x68 && p[0] === 25) { this.cursorVisible = true; }
      else if (cmd === 0x6C && p[0] === 25) { this.cursorVisible = false; }
      return;
    }
    switch (cmd) {
      case 0x41: this.cursorY -= (p[0] || 1); break;                                      // CUU
      case 0x42: this.cursorY += (p[0] || 1); break;                                      // CUD
      case 0x43: this.moveCursorHorizontal(p[0] || 1); break;                             // CUF
      case 0x44: this.moveCursorHorizontal(-(p[0] || 1)); break;                          // CUB
      case 0x48: this.cursorX = (p[1] || 1) - 1; this.cursorY = (p[0] || 1) - 1; break;   // CUP
      case 0x40: this.insertChars(p[0] || 1); break;                                        // ICH
      case 0x4A:  // ED
        if (p[0] === 2 || p[0] === 3) {
          this.initBuffer();
          this.cursorX = 0; this.cursorY = 0; this.screenTop = 0; this.viewOffset = 0;
        } else if (p[0] === 1) {
          this.eraseAbove();
        } else {
          this.eraseBelow();
        }
        break;
      case 0x4B:  // EL
        if (p[0] === 2) {
          for (let c = 0; c < this.cols; c++) { this.setCell(this.cursorY, c, ' '); }
        } else if (p[0] === 1) {
          for (let c = 0; c <= this.cursorX; c++) { this.setCell(this.cursorY, c, ' '); }
        } else {
          for (let c = this.cursorX; c < this.cols; c++) { this.setCell(this.cursorY, c, ' '); }
        }
        this.clearCurrentWrapMarker();
        break;
      case 0x50: this.deleteChars(p[0] || 1); break;                                        // DCH
      case 0x58: this.eraseChars(p[0] || 1); break;                                         // ECH
      case 0x6D: this.sgr(p); break;
    }
    this.clampCursor();
  }

  /** SGR */
  private sgr(p: number[]): void {
    for (let i = 0; i < p.length; i++) {
      const v: number = p[i];
      if (v === 0) { this.fgColor = this.terminalFgColor; this.bgColor = DEFAULT_BG; this.boldFlag = false; this.inverseFlag = false; }
      else if (v === 1) { this.boldFlag = true; }
      else if (v === 7) { this.inverseFlag = true; }
      else if (v === 27) { this.inverseFlag = false; }
      else if (v === 38 && i + 2 < p.length && p[i + 1] === 5) {
        const idx: number = p[i + 2];
        if (idx >= 0 && idx < 256) { this.fgColor = COL256[idx]; }
        i += 2;
      } else if (v === 48 && i + 2 < p.length && p[i + 1] === 5) {
        const idx: number = p[i + 2];
        if (idx >= 0 && idx < 256) { this.bgColor = COL256[idx]; }
        i += 2;
      } else if (v >= 30 && v <= 37) { this.fgColor = ANSI_COLORS[v - 30]; }
      else if (v >= 40 && v <= 47) { this.bgColor = ANSI_COLORS[v - 40]; }
      else if (v >= 90 && v <= 97) { this.fgColor = ANSI_BRIGHT[v - 90]; }
    }
  }

  /** 写入字符 (过滤控制字符) */
  private putChar(code: number): void {
    switch (code) {
      case 0x0A: this.lineFeed(); return;
      case 0x0D: this.cursorX = 0; return;
      case 0x08: if (this.cursorX > 0) { this.cursorX--; } return;
      case 0x09: this.cursorX = Math.min(this.cols - 1, ((Math.floor(this.cursorX / 8) + 1) * 8)); return;
      case 0x07: return;
    }
    if (code < 0x20 || code === 0x7F || (code >= 0x80 && code <= 0x9F)) { return; }
    const ch: string = String.fromCharCode(code);
    this.setCell(this.cursorY, this.cursorX, ch);
    this.cursorX++;
    if (this.cursorX >= this.cols) {
      this.markCurrentRowWrapped();
      this.cursorX = 0;
      this.lineFeed();
    }
  }

  private setCell(r: number, c: number, ch: string): void {
    if (r < 0 || r >= this.rows || c < 0 || c >= this.cols) { return; }
    const absR: number = this.screenTop + r;
    while (absR >= this.buffer.length) {
      this.buffer.push(this.makeEmptyRow());
      this.wrappedRows.push(false);
    }
    const cell: TerminalCell = this.buffer[absR][c];
    cell.ch = ch;
    cell.fg = this.inverseFlag ? this.bgColor : this.fgColor;
    cell.bg = this.inverseFlag ? this.fgColor : this.bgColor;
    cell.bold = this.boldFlag;
    cell.inverse = this.inverseFlag;
    this.markRowDirty(absR);
  }

  private insertChars(count: number): void {
    const n: number = Math.max(1, Math.min(count, this.cols - this.cursorX));
    const absR: number = this.screenTop + this.cursorY;
    while (absR >= this.buffer.length) {
      this.buffer.push(this.makeEmptyRow());
      this.wrappedRows.push(false);
    }
    const row: TerminalCell[] = this.buffer[absR];
    for (let c = this.cols - 1; c >= this.cursorX; c--) {
      const src: number = c - n;
      if (src >= this.cursorX) {
        this.copyCell(row[c], row[src]);
      } else {
        this.clearCell(row[c]);
      }
    }
    this.wrappedRows[absR] = false;
    this.markRowDirty(absR);
  }

  private deleteChars(count: number): void {
    const n: number = Math.max(1, Math.min(count, this.cols - this.cursorX));
    const absR: number = this.screenTop + this.cursorY;
    while (absR >= this.buffer.length) {
      this.buffer.push(this.makeEmptyRow());
      this.wrappedRows.push(false);
    }
    const row: TerminalCell[] = this.buffer[absR];
    for (let c = this.cursorX; c < this.cols; c++) {
      const src: number = c + n;
      if (src < this.cols) {
        this.copyCell(row[c], row[src]);
      } else {
        this.clearCell(row[c]);
      }
    }
    this.wrappedRows[absR] = false;
    this.markRowDirty(absR);
  }

  private eraseChars(count: number): void {
    const n: number = Math.max(1, Math.min(count, this.cols - this.cursorX));
    const absR: number = this.screenTop + this.cursorY;
    while (absR >= this.buffer.length) {
      this.buffer.push(this.makeEmptyRow());
      this.wrappedRows.push(false);
    }
    const row: TerminalCell[] = this.buffer[absR];
    for (let c = this.cursorX; c < this.cursorX + n; c++) {
      this.clearCell(row[c]);
    }
    this.wrappedRows[absR] = false;
    this.markRowDirty(absR);
  }

  private lineFeed(): void {
    if (this.cursorY >= this.scrollBottom) { this.scroll(); }
    else { this.cursorY++; }
  }

  private scroll(): void {
    const wasAtBottom: boolean = this.viewOffset >= this.screenTop;
    this.screenTop++;
    if (wasAtBottom) { this.viewOffset = this.screenTop; }
    while (this.buffer.length < this.screenTop + this.rows) {
      this.buffer.push(this.makeEmptyRow());
      this.wrappedRows.push(false);
    }
    while (this.buffer.length > this.MAX_SCROLLBACK) {
      this.buffer.shift();
      this.wrappedRows.shift();
      this.screenTop--;
      this.viewOffset--;
    }
    if (this.screenTop < 0) { this.screenTop = 0; }
    if (this.viewOffset < 0) { this.viewOffset = 0; }
    // 滚动 → 全部可视行变化, 由 write() 结束时统一渲染, 避免一批输出多次全屏绘制。
    this.markAllDirty();
  }

  private eraseBelow(): void {
    for (let r = this.cursorY; r < this.rows; r++) {
      const startCol: number = r === this.cursorY ? this.cursorX : 0;
      for (let c = startCol; c < this.cols; c++) { this.setCell(r, c, ' '); }
      const absR: number = this.screenTop + r;
      while (absR >= this.wrappedRows.length) {
        this.wrappedRows.push(false);
      }
      this.wrappedRows[absR] = false;
    }
  }

  private eraseAbove(): void {
    for (let r = 0; r <= this.cursorY; r++) {
      const endCol: number = r === this.cursorY ? this.cursorX : this.cols - 1;
      for (let c = 0; c <= endCol; c++) { this.setCell(r, c, ' '); }
      const absR: number = this.screenTop + r;
      while (absR >= this.wrappedRows.length) {
        this.wrappedRows.push(false);
      }
      this.wrappedRows[absR] = false;
    }
  }

  /** 获取当前可见区内容 */
  getContent(): string {
    const lines: string[] = [];
    for (let r = 0; r < this.rows; r++) {
      const absR: number = this.viewOffset + r;
      if (absR >= this.buffer.length) { break; }
      let line: string = '';
      for (let c = 0; c < this.cols; c++) { line += this.buffer[absR][c].ch; }
      lines.push(line.replace(/\s+$/, ''));
    }
    return lines.join('\n');
  }

  /**
   * 获取选区文本 — 按规范化后的选区从 buffer 拼接。
   * 单行: 裁 [c0, c1]; 跨行: 首行 [c0,末], 中间整行, 末行 [0,c1]。
   * 行尾空白 trim, 行间用 \n。无有效选区时回退整屏 getContent()。
   */
  getSelection(): string {
    if (!this.hasSelection()) { return this.getContent(); }
    const n: number[] = this.normSelection();
    const r0: number = n[0]; const c0: number = n[1]; const r1: number = n[2]; const c1: number = n[3];
    const lines: string[] = [];
    for (let absR = r0; absR <= r1; absR++) {
      if (absR < 0 || absR >= this.buffer.length) { continue; }
      const row: TerminalCell[] = this.buffer[absR];
      const startC: number = (absR === r0) ? c0 : 0;
      const endC: number = (absR === r1) ? c1 : this.cols - 1;
      let line: string = '';
      for (let c = startC; c <= endC && c < row.length; c++) {
        line += row[c].ch;
      }
      lines.push(line.replace(/\s+$/, ''));
    }
    return lines.join('\n');
  }

  build() {
    Canvas(this.ctx)
      .onReady(() => {
        this.calcCellSize();
        this.markAllDirty();
        this.renderFull();
      })
      .width('100%')
      .height('100%')
      .backgroundColor(DEFAULT_BG)
      .focusable(false)
      .onTouch((event: TouchEvent): void => {
        if (this.selectMode) {
          this.handleSelectTouch(event);
        }
      })
  }

  /** 选区模式下的触摸: Down 设锚点, Move 更新终点, 实时高亮重绘 */
  private handleSelectTouch(event: TouchEvent): void {
    if (this.cellW <= 0 || this.cellH <= 0) { return; }
    if (event.type === TouchType.Down) {
      const t = event.touches[0];
      const c: number = Math.max(0, Math.min(this.cols - 1, Math.floor(t.x / this.cellW)));
      const localY: number = t.y - this.gridTop();
      const r: number = Math.max(0, Math.min(this.rows - 1, Math.floor(localY / this.cellH)));
      this.selStartAbsR = this.viewOffset + r;
      this.selStartC = c;
      this.selEndAbsR = this.selStartAbsR;
      this.selEndC = c;
      this.markAllDirty();
      this.renderFull();
    } else if (event.type === TouchType.Move && this.selStartAbsR >= 0) {
      const t = event.touches[0];
      const c: number = Math.max(0, Math.min(this.cols - 1, Math.floor(t.x / this.cellW)));
      const localY: number = t.y - this.gridTop();
      const r: number = Math.max(0, Math.min(this.rows - 1, Math.floor(localY / this.cellH)));
      const newEndR: number = this.viewOffset + r;
      if (newEndR !== this.selEndAbsR || c !== this.selEndC) {
        this.selEndAbsR = newEndR;
        this.selEndC = c;
        this.markAllDirty();
        this.renderFull();
      }
    }
  }
}
