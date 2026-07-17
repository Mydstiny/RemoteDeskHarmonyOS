/**
 * SshTerminal.ets v5 — 推送式 SSH 终端页 (Phase 4 统一输入模型)
 *
 * ## 输入模型 (单向: 输入→SSH, 显示←SSH echo)
 *
 *   软键盘 (手机/平板):
 *     onWillInsert/onWillDelete/onSubmit → SshTerminalInputPolicy → sendData
 *
 *   物理/系统键盘:
 *     onKeyPreIme → SshTerminalInputPolicy → sendData；未识别的 IME 组合态放行给 onWillInsert
 *
 *   通用 (fallback):
 *     onChange → handleChangeGuard；PC 粘贴 → handlePaste
 *
 * ## 防重复设计
 *   - onWillInsert 返回 false → 文本不插入 TextInput → onChange 不触发
 *   - 移动端 onPaste 返回后直接忽略, 避免和软键盘输入路径重复
 *   - PC 端 Ctrl+V 是唯一粘贴路径 (onPaste 保留)
 *
 * ## 数据流
 *   输入 → sendData(SSH) → 远端 shell → echo → readerLoop → termOutput → 终端渲染
 *   终端显示完全来自 SSH echo, 本地输入不参与显示
 */
import { KeyboardAvoidMode, promptAction, router, window } from '@kit.ArkUI';
import { pasteboard, BusinessError } from '@kit.BasicServicesKit';
import { picker, fileIo } from '@kit.CoreFileKit';
import { KeyCode } from '@kit.InputKit';
import { socket } from '@kit.NetworkKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { HostSyncService } from '../services/HostSyncService';
import { ExtensionLoader } from '../services/ExtensionLoader';
import { KeyVaultService } from '../services/KeyVaultService';
import { RemoteHost } from '../model/RemoteHost';
import { Palette, buildDark, buildLight } from '../common/Theme';
import { showLockGate, lockGateErrorMessage } from '../components/LockGate';
import { TerminalEmulator } from '../components/TerminalEmulator';
import { NativeTerminalRenderer } from '../components/NativeTerminalRenderer';
import { SessionConfig, SftpFileEntry, SshPrivateKeyInfo } from '../types/rdpnapi';
import { SshPreflightService } from '../services/SshPreflightService';
import {
  terminalLogicalViewportHeight,
  terminalRowsBottomOffset,
  terminalTouchDragScrollLines,
  terminalVisualBottomOffset,
  terminalTouchSurfaceOffsetY
} from '../services/SshTerminalScrollPolicy';
import {
  SshEncodedKey,
  TerminalModifierState,
  encodePhysicalKey,
  encodeSoftDelete,
  encodeTextInput
} from '../services/SshTerminalInputPolicy';
import {
  defaultSshTerminalOrientation,
  SshTerminalOrientation,
  toggleSshTerminalOrientation
} from '../services/SshTerminalOrientationPolicy';
import { VirtualKeyBar } from '../components/VirtualKeyBar';
import {
  TransferSession,
  TransferStage,
  cancelTransfer,
  downloadResumeOffset,
  recordConfirmedUploadWrite,
  shouldShowTransferCancelAction,
  transferProgressPanelHeight,
  uploadResumeOffset
} from '../services/TransferSessionPolicy';
// Passphrase uses bindSheet (SshTerminal is @Entry, no bindSheet limit)

const SFTP_MAX_TRANSFER_BYTES: number = 512 * 1024 * 1024;
const SFTP_UPLOAD_CHUNK_BYTES: number = 64 * 1024;
const SFTP_DOWNLOAD_CHUNK_BYTES: number = 64 * 1024;

@Entry
@Component
struct SshTerminal {
  @StorageLink('currentTheme') theme: string = 'light';
  @StorageProp('accentColor') accentColor: string = '#007DFF';
  @State connected: boolean = false;
  @State connecting: boolean = true;
  @State connectionError: string = '';
  @State hostLabel: string = '';
  @State userAtHost: string = '';
  @State termOutput: string = '';
  @StorageLink('currentBreakpoint') @Watch('onFontSizeChange') breakpoint: string = 'sm';
  @StorageProp('isDesktopDevice') isDesktopDevice: boolean = false;
  @StorageLink('terminalFontSize') @Watch('onFontSizeChange') fontSize: number = 18;
  @State termRows: number = 24;
  @State termCols: number = 80;
  @State kbInput: string = '';
  @State backHover: boolean = false;
  /** 软键盘高度 (vp) — 手动驱动移动端虚拟键栏悬浮到键盘上边缘 */
  @State @Watch('onKeyboardInsetChange') kbHeight: number = 0;
  /** 系统导航栏/手势条底部避让高度 (vp), 用于键盘未弹起时托起虚拟键栏 */
  @State navHeight: number = 0;
  /** 状态栏/挖孔顶部避让高度 (vp), 顶栏内容从安全区下方开始 */
  @State topSafeHeight: number = 0;
  /** SSH 内容层实际尺寸 (vp), 用于计算浮动底栏和终端可视高度 */
  @State shellAreaH: number = 0;
  @State shellAreaW: number = 0;
  /** 终端区实际尺寸 (vp), onAreaChange 写入 */
  @State termAreaH: number = 0;
  @State termAreaW: number = 0;
  /** 修饰键 sticky 状态 — 与 VirtualKeyBar 双向绑定; 物理键盘也借用此状态 */
  @State ctrlActive: boolean = false;
  @State altActive: boolean = false;
  @State shiftActive: boolean = false;
  /** 选区模式 — 长按菜单"选择"开启, 传给 TerminalEmulator 改变 touch 行为 */
  @State selectMode: boolean = false;
  /** 复制请求计数器 — ++ 触发 TerminalEmulator 把文本写入 copiedText */
  @State copyRequest: number = 0;
  /** TerminalEmulator 回传的待复制文本 — @Watch 触发写系统剪贴板 */
  @State @Watch('onCopiedTextChange') copiedText: string = '';
  /** 移动端键盘/视口变化时递增, 通知终端渲染器回到底部 */
  @State scrollToBottomRequest: number = 0;
  @State forceScrollToBottomRequest: number = 0;
  @State terminalExternalScrollLines: number = 0;
  @State terminalExternalScrollRequest: number = 0;
  /** SSH 协议级 keepalive 延迟 */
  @State latencyMs: number = -1;
  /** SFTP 文件传输面板 */
  @State showSftpPanel: boolean = false;
  @State sftpPath: string = '.';
  @State sftpEntries: SftpFileEntry[] = [];
  @State sftpSelectedPath: string = '';
  @State sftpSelectedName: string = '';
  @State sftpSelectedIsDir: boolean = false;
  @State sftpSelectedSize: number = 0;
  @State sftpPathInput: string = '.';
  @State sftpNameInput: string = '';
  @State sftpBusy: boolean = false;
  @State sftpStatus: string = '打开后会加载远端当前目录。';
  @State sftpProgress: number = -1;
  @State sftpProgressLabel: string = '处理中';
  @State sftpTransferSession: TransferSession | null = null;
  @State isLandscape: boolean = false;
  // Kept only in-memory to retry the current picker grant; never logged or placed in diagnostics.
  private sftpTransferUri: string = '';
  private sftpTransferRemotePath: string = '';
  /** 功能开关: true=使用 Rust terminal_core 渲染 (NativeTerminalRenderer), false=旧 TerminalEmulator */
  @StorageProp('useNativeTerminalCore') useNativeTerminalCore: boolean = true;

  // cellH/cellW 由字号推算, 与 Canvas 字体单位保持一致
  @State cellHvp: number = 20;
  @State cellWvp: number = 9;
  @State renderFontVp: number = 18;
  private kbCtrl: TextInputController = new TextInputController();
  private srv: HostSyncService = HostSyncService.getInstance();
  private loader: ExtensionLoader = ExtensionLoader.getInstance();
  private hostId: string = '';
  private sessionId: number = -1;
  private win: window.Window | null = null;
  private orientationApplied: boolean = false;
  private orientationTransitioning: boolean = false;
  private orientationSettleTimer: number = -1;
  private orientationFinalTimer: number = -1;
  private restoreKeyboardAfterOrientation: boolean = false;
  private lastTermAreaPosition: string = '';
  private lastShellAreaPosition: string = '';
  private avoidCb: ((data: window.AvoidAreaOptions) => void) | null = null;
  private resizePtyTimer: number = -1;
  private latencyTimer: number = -1;
  private sftpRefreshTimer: number = -1;
  private sftpPanelOpenedAt: number = 0;
  private latencyProbeRunning: boolean = false;
  private terminalClosing: boolean = false;
  private terminalPanStartOffsetY: number = 0;
  private terminalPanLastLines: number = 0;
  private oldKeyboardAvoidMode: KeyboardAvoidMode = KeyboardAvoidMode.OFFSET;
  private keyboardAvoidModeChanged: boolean = false;
  private sshHost: string = '';
  private sshPort: number = 22;
  /** 进入 SSH 终端前的系统状态栏文字颜色, 用于离开时恢复 */
  private savedStatusBarColor: string = '#E6E6E6';

  private updateCellSize(): void {
    const normalized: number = Math.max(12, Math.min(32, this.fontSize));
    this.renderFontVp = normalized;
    const rowRatio: number = normalized <= 16 ? 1.18 : normalized <= 24 ? 1.13 : normalized <= 32 ? 1.09 : 1.06;
    const widthRatio: number =
      this.breakpoint === 'sm' ? 0.54 :
        this.breakpoint === 'md' ? 0.56 :
          this.breakpoint === 'lg' ? 0.58 : 0.60;
    this.cellHvp = Math.max(15, Math.ceil(normalized * rowRatio));
    this.cellWvp = Math.max(6, Math.round(normalized * widthRatio));
  }

  private onFontSizeChange(): void {
    this.updateCellSize();
    this.recalcGrid();
  }

  /** 根据 termAreaW/H + 字号反推 cols/rows, 同步到 PTY */
  private recalcGrid(): void {
    if (this.cellHvp <= 0 || this.cellWvp <= 0) { return; }
    let changed: boolean = false;
    const usableH: number = this.terminalRowsViewportHeight();
    if (usableH > 0) {
      // 最小 3 行: 大键盘小屏幕时允许终端缩小, 避免 Canvas 溢出容器被裁剪
      const r: number = Math.max(3, Math.min(80, Math.floor(usableH / this.cellHvp)));
      if (r !== this.termRows) { this.termRows = r; changed = true; }
    }
    if (this.termAreaW > 0) {
      const c: number = Math.max(20, Math.min(300, Math.floor(this.termAreaW / this.cellWvp)));
      if (c !== this.termCols) { this.termCols = c; changed = true; }
    }
    if (changed) {
      this.schedulePtyResize();
    }
  }

  private schedulePtyResize(): void {
    if (this.sessionId <= 0) { return; }
    if (this.resizePtyTimer !== -1) {
      clearTimeout(this.resizePtyTimer);
      this.resizePtyTimer = -1;
    }
    this.resizePtyTimer = setTimeout((): void => {
      this.resizePtyTimer = -1;
      if (this.sessionId <= 0) { return; }
      this.loader.resizePty(this.sessionId, this.termCols, this.termRows);
      hilog.info(0x0000, 'SshTerminal',
        `PTY resize cols=${this.termCols} rows=${this.termRows} ` +
        `termArea=${this.termAreaW}x${this.termAreaH} logicalH=${this.terminalRowsViewportHeight()} ` +
        `cell=${this.cellWvp}x${this.cellHvp} font=${this.renderFontVp}vp`);
      if (!this.isDesktopDevice) {
        this.requestTerminalScrollToBottomSettled();
      }
    }, this.isDesktopDevice ? 32 : 140);
  }

  private calcRowsFallback(): number {
    switch (this.breakpoint) { case 'xl': return 40; case 'lg': return 36; case 'md': return 30; default: return 24; }
  }
  private calcColsFallback(): number {
    switch (this.breakpoint) { case 'xl': return 120; case 'lg': return 100; case 'md': return 80; default: return 60; }
  }

  private barBottomOffset(): number {
    return terminalVisualBottomOffset(this.isDesktopDevice, this.kbHeight, this.navHeight);
  }

  private rowsBottomOffset(): number {
    return terminalRowsBottomOffset(this.isDesktopDevice, this.kbHeight, this.navHeight);
  }

  private topChromeOffset(): number {
    if (this.isDesktopDevice) { return 0; }
    return Math.max(8, this.topSafeHeight);
  }

  private headerHeight(): number {
    return 56 + this.topChromeOffset();
  }

  private barTop(): number {
    return Math.max(0, this.shellAreaH - this.barBottomOffset() - VirtualKeyBar.TOTAL_H);
  }

  private terminalPaneHeight(): number {
    if (this.shellAreaH <= 0) { return this.calcRowsFallback() * this.cellHvp; }
    return Math.max(this.cellHvp * 3, this.shellAreaH);
  }

  private terminalRowsViewportHeight(): number {
    const shellHeight: number = this.shellAreaH > 0 ? this.shellAreaH : this.termAreaH;
    if (shellHeight <= 0) { return this.calcRowsFallback() * this.cellHvp; }
    return terminalLogicalViewportHeight(
      this.isDesktopDevice,
      shellHeight,
      this.cellHvp,
      this.rowsBottomOffset(),
      VirtualKeyBar.TOTAL_H
    );
  }

  private terminalCanvasOffsetY(): number {
    return terminalTouchSurfaceOffsetY(this.isDesktopDevice, this.barBottomOffset(), VirtualKeyBar.TOTAL_H);
  }

  private requestTerminalScrollToBottom(): void {
    this.scrollToBottomRequest = this.scrollToBottomRequest + 1;
  }

  private requestTerminalExternalScroll(lines: number): void {
    if (lines === 0) { return; }
    this.terminalExternalScrollLines = lines;
    this.terminalExternalScrollRequest = this.terminalExternalScrollRequest + 1;
    hilog.info(0x0000, 'SshTerminal',
      `[touchDiag] forward req=${this.terminalExternalScrollRequest} lines=${lines} ` +
      `termArea=${this.termAreaW}x${this.termAreaH} shell=${this.shellAreaW}x${this.shellAreaH} ` +
      `pane=${this.terminalPaneHeight()} logicalH=${this.terminalRowsViewportHeight()} ` +
      `offset=${this.terminalCanvasOffsetY()} ` +
      `kb=${this.kbHeight} nav=${this.navHeight} rowsOffset=${this.rowsBottomOffset()} rows=${this.termRows}`);
  }

  private handleTerminalPanStart(event: GestureEvent): void {
    if (this.selectMode) { return; }
    const axisY: number = event.axisVertical === undefined ? 0 : event.axisVertical;
    if (axisY !== 0) { return; }
    this.terminalPanStartOffsetY = event.offsetY === undefined ? 0 : event.offsetY;
    this.terminalPanLastLines = 0;
  }

  private handleTerminalPanUpdate(event: GestureEvent): void {
    if (this.selectMode) { return; }
    const axisY: number = event.axisVertical === undefined ? 0 : event.axisVertical;
    if (axisY !== 0) {
      const isTouchPad: boolean = event.sourceTool === SourceTool.TOUCHPAD;
      let lines: number = isTouchPad ? Math.round(axisY / Math.max(1, this.cellHvp)) : (axisY > 0 ? 3 : -3);
      if (lines === 0) { lines = axisY > 0 ? 1 : -1; }
      this.requestTerminalExternalScroll(lines);
      return;
    }

    const offsetY: number = event.offsetY === undefined ? 0 : event.offsetY;
    const totalLines: number = terminalTouchDragScrollLines(this.terminalPanStartOffsetY, offsetY, this.cellHvp);
    const deltaLines: number = totalLines - this.terminalPanLastLines;
    if (deltaLines !== 0) {
      this.terminalPanLastLines = totalLines;
      hilog.info(0x0000, 'SshTerminal',
        `[touchDiag] panMove start=${this.terminalPanStartOffsetY} offset=${offsetY} ` +
        `total=${totalLines} delta=${deltaLines}`);
      this.requestTerminalExternalScroll(deltaLines);
    }
  }

  private handleTerminalPanEnd(): void {
    this.terminalPanLastLines = 0;
  }

  private requestTerminalScrollToBottomSettled(): void {
    this.requestTerminalScrollToBottom();
    setTimeout((): void => { this.requestTerminalScrollToBottom(); }, 48);
    setTimeout((): void => { this.requestTerminalScrollToBottom(); }, 140);
    setTimeout((): void => { this.requestTerminalScrollToBottom(); }, 260);
  }

  private onKeyboardInsetChange(): void {
    if (this.isDesktopDevice || !this.connected) { return; }
    this.recalcGrid();
    // 键盘收起 (kbHeight → 0) 时, terminalPaneHeight 会先增大再触发 onAreaChange→recalcGrid→PTY resize (140ms)。
    // 标准 Settled (0/48/140/260ms) 的 0ms 可能跑在 resize 之前被 followBottom=false 覆盖。
    // 扩展延迟确保键盘收起后有足够时间让 PTY resize + 布局稳定, 最末一次 scrollToBottom 做最后兜底。
    if (this.kbHeight <= 0) {
      // 键盘已收起 — 先立即滚动, 再等 resize 做完后滚动
      this.requestTerminalScrollToBottom();
      setTimeout((): void => { this.requestTerminalScrollToBottom(); }, 200);
      setTimeout((): void => { this.requestTerminalScrollToBottom(); }, 450);
      setTimeout((): void => { this.requestTerminalScrollToBottom(); }, 700);
    } else {
      this.requestTerminalScrollToBottomSettled();
    }
  }

  async aboutToAppear(): Promise<void> {
    this.terminalClosing = false;
    this.lastTermAreaPosition = '';
    this.lastShellAreaPosition = '';
    this.orientationApplied = false;
    // ArkUI 可能复用页面实例；每次进入都必须从全新的会话输出开始。
    this.termOutput = '';
    this.connected = false;
    this.connecting = true;
    this.connectionError = '';
    this.sessionId = -1;
    this.updateCellSize();
    this.termRows = this.calcRowsFallback();
    this.termCols = this.calcColsFallback();

    // 手机/平板 SSH 默认竖屏；桌面/2in1 由系统窗口管理当前方向。
    const defaultOrientation: SshTerminalOrientation = defaultSshTerminalOrientation(this.isDesktopDevice);
    this.isLandscape = defaultOrientation === 'landscape';
    if (!this.isDesktopDevice) {
      await this.setPreferredOrientation(window.Orientation.PORTRAIT, 'SSH-PORTRAIT');
    }

    // SSH 终端始终深色模式 — 强制系统状态栏/导航栏亮色图标
    this.forceStatusBarDark();

    this.setupKeyboardAvoidMode();
    // 注册键盘/系统栏高度监听 — 用于手动定位移动端虚拟键栏
    this.registerAvoidAreaListener();

    const params: Object = router.getParams();
    if (params) {
      const p: Record<string, Object> = params as Record<string, Object>;
      const id: string = p['hostId'] as string;
      if (id) {
        this.hostId = id;

        // T-210: 消费 preflight token (获取 passphrase + expected host key)
        const preflightTokenId: string = (p['sshPreflightToken'] as string) || '';
        if (preflightTokenId !== '') {
          const tokenSvc = SshPreflightService.getInstance();
          const tokenData = tokenSvc.consume(preflightTokenId);
          if (tokenData) {
            this.preflightPassphrase = tokenData.privateKeyPassphrase;
            this.preflightExpectedHostKeyRaw = tokenData.expectedHostKeyRawBase64;
            this.preflightExpectedHostKeyFp = tokenData.expectedHostKeyFingerprintSha256;
            hilog.info(0x0001, 'SshTerminal', 'preflight token consumed ok');
          } else {
            hilog.warn(0x0001, 'SshTerminal', 'preflight token expired or missing');
            this.connecting = false;
            this.connectionError = 'SSH 连接缺少安全预检, 请从主机列表重新连接';
            return;
          }
        }

        const host: RemoteHost | undefined = this.srv.getHost(this.hostId);
        if (host) {
          this.hostLabel = host.label;
          this.userAtHost = host.username + '@' + host.host + ':' + host.port;
          const authenticated: boolean = (p['authenticated'] as boolean) === true;
          if (host.locked && !authenticated) {
            const r = await showLockGate(host.label, 'biometric');
            if (!r.ok) { this.connecting = false; this.connectionError = lockGateErrorMessage(r) || '验证未通过'; return; }
          }
          await this.connect(host);
        }
      }
    }
  }

  aboutToDisappear(): void {
    this.terminalClosing = true;
    if (this.resizePtyTimer !== -1) {
      clearTimeout(this.resizePtyTimer);
      this.resizePtyTimer = -1;
    }
    if (this.orientationSettleTimer !== -1) {
      clearTimeout(this.orientationSettleTimer);
      this.orientationSettleTimer = -1;
    }
    if (this.orientationFinalTimer !== -1) {
      clearTimeout(this.orientationFinalTimer);
      this.orientationFinalTimer = -1;
    }
    this.orientationTransitioning = false;
    this.restoreKeyboardAfterOrientation = false;
    this.clearSftpRefreshTimer();
    this.sftpBusy = false;
    this.sftpProgress = -1;
    this.stopLatencyProbe();
    this.restoreKeyboardAvoidMode();
    this.unregisterAvoidAreaListener();
    // 恢复系统状态栏颜色到进入前的值
    this.restoreStatusBar();
    if (this.sessionId > 0) {
      try { this.loader.setOnDataCallback(this.sessionId, null); } catch (_e) { /* ignore */ }
    }
    this.loader.disconnect();
    this.sessionId = -1;
    this.connected = false;
    this.termOutput = '';
    if (this.orientationApplied) {
      setTimeout((): void => {
        this.setPreferredOrientation(window.Orientation.UNSPECIFIED, 'SSH-UNSPECIFIED');
      }, 250);
    }
  }

  private async setPreferredOrientation(orientation: window.Orientation, label: string): Promise<void> {
    try {
      const ctx = this.getUIContext().getHostContext();
      if (!ctx) { return; }
      const win: window.Window = await window.getLastWindow(ctx);
      await win.setPreferredOrientation(orientation);
      this.orientationApplied = orientation !== window.Orientation.UNSPECIFIED;
      if (orientation === window.Orientation.LANDSCAPE) {
        this.isLandscape = true;
      } else if (orientation === window.Orientation.PORTRAIT) {
        this.isLandscape = false;
      }
      hilog.info(0x0000, 'SshTerminal', 'setPreferredOrientation(' + label + ') OK');
    } catch (err) {
      hilog.warn(0x0001, 'SshTerminal', 'setPreferredOrientation(' + label + ') failed: ' + JSON.stringify(err));
    }
  }

  private async toggleSshOrientation(): Promise<void> {
    if (this.isDesktopDevice || this.orientationTransitioning) { return; }
    this.orientationTransitioning = true;
    this.restoreKeyboardAfterOrientation = this.kbHeight > this.navHeight + 1;
    if (this.orientationSettleTimer !== -1) {
      clearTimeout(this.orientationSettleTimer);
      this.orientationSettleTimer = -1;
    }
    if (this.orientationFinalTimer !== -1) {
      clearTimeout(this.orientationFinalTimer);
      this.orientationFinalTimer = -1;
    }
    // 旋转前解除隐藏输入框焦点，防止 IME 继续使用旧窗口坐标定位输入光标。
    try { this.getUIContext().getFocusController().clearFocus(); } catch (_e) { /* ignore */ }
    this.resetKeyboardBuffer();
    const current: SshTerminalOrientation = this.isLandscape ? 'landscape' : 'portrait';
    const next: SshTerminalOrientation = toggleSshTerminalOrientation(current);
    this.isLandscape = next === 'landscape';
    await this.setPreferredOrientation(
      this.isLandscape ? window.Orientation.LANDSCAPE : window.Orientation.PORTRAIT,
      this.isLandscape ? 'SSH-LANDSCAPE-MANUAL' : 'SSH-PORTRAIT-MANUAL'
    );
    this.scheduleOrientationSettle();
  }

  private scheduleOrientationSettle(): void {
    if (this.orientationSettleTimer !== -1) { clearTimeout(this.orientationSettleTimer); }
    if (this.orientationFinalTimer !== -1) { clearTimeout(this.orientationFinalTimer); }
    this.orientationSettleTimer = setTimeout((): void => {
      this.orientationSettleTimer = -1;
      if (this.terminalClosing) { return; }
      this.recalcGrid();
      this.forceScrollToBottomRequest = this.forceScrollToBottomRequest + 1;
      this.requestTerminalScrollToBottom();
      // 第一阶段只确认尺寸已停止变化；PTY resize 和 Canvas 属性更新可能还在同一帧之后提交。
      // 保持 transitioning，避免最后一组 onAreaChange 被当作普通布局变化处理。
      this.orientationFinalTimer = setTimeout((): void => {
        this.orientationFinalTimer = -1;
        if (this.terminalClosing) { return; }
        this.recalcGrid();
        this.forceScrollToBottomRequest = this.forceScrollToBottomRequest + 1;
        this.requestTerminalScrollToBottom();
        this.orientationTransitioning = false;
        this.resetKeyboardBuffer();
        if (this.restoreKeyboardAfterOrientation) {
          this.focusKeyboard();
        }
        this.restoreKeyboardAfterOrientation = false;
        hilog.info(0x0000, 'SshTerminal',
          `[orientation] settled landscape=${this.isLandscape} shell=${this.shellAreaW}x${this.shellAreaH} ` +
          `term=${this.termAreaW}x${this.termAreaH} grid=${this.termCols}x${this.termRows}`);
      }, 220);
    }, 260);
  }
  private setupKeyboardAvoidMode(): void {
    try {
      const ui = this.getUIContext();
      this.oldKeyboardAvoidMode = ui.getKeyboardAvoidMode();
      ui.setKeyboardAvoidMode(KeyboardAvoidMode.NONE);
      this.keyboardAvoidModeChanged = true;
    } catch (err) {
      hilog.warn(0x0001, 'SshTerminal', '[keyboardAvoid] 设置失败: ' + JSON.stringify(err));
    }
  }

  private restoreKeyboardAvoidMode(): void {
    if (!this.keyboardAvoidModeChanged) { return; }
    try {
      this.getUIContext().setKeyboardAvoidMode(this.oldKeyboardAvoidMode);
    } catch (_e) { /* ignore */ }
    this.keyboardAvoidModeChanged = false;
  }

  private syncAvoidHeights(w: window.Window): void {
    const oldKbHeight: number = this.kbHeight;
    const oldNavHeight: number = this.navHeight;
    try {
      const keyboardArea: window.AvoidArea = w.getWindowAvoidArea(window.AvoidAreaType.TYPE_KEYBOARD);
      this.kbHeight = px2vp(keyboardArea.bottomRect.height);
    } catch (_e) { /* ignore */ }
    let topInset: number = 0;
    try {
      const systemArea: window.AvoidArea = w.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
      this.navHeight = px2vp(systemArea.bottomRect.height);
      topInset = Math.max(topInset, px2vp(systemArea.topRect.height));
    } catch (_e) { /* ignore */ }
    try {
      const cutoutArea: window.AvoidArea = w.getWindowAvoidArea(window.AvoidAreaType.TYPE_CUTOUT);
      topInset = Math.max(topInset, px2vp(cutoutArea.topRect.height));
    } catch (_e) { /* ignore */ }
    try {
      const indicatorArea: window.AvoidArea =
        w.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
      this.navHeight = Math.max(this.navHeight, px2vp(indicatorArea.bottomRect.height));
    } catch (_e) { /* ignore */ }
    this.topSafeHeight = topInset;
    if (!this.isDesktopDevice && this.connected &&
      (Math.abs(oldKbHeight - this.kbHeight) >= 1 || Math.abs(oldNavHeight - this.navHeight) >= 1)) {
      this.recalcGrid();
      if (this.orientationTransitioning) {
        this.scheduleOrientationSettle();
      } else {
        this.requestTerminalScrollToBottomSettled();
      }
    }
  }

  /**
   * SSH 终端始终深色模式 — 强制系统状态栏/导航栏亮色图标。
   * 保存进入前的颜色, 离开时由 restoreStatusBar() 恢复。
   */
  private async forceStatusBarDark(): Promise<void> {
    try {
      const ctx = this.getUIContext().getHostContext();
      if (!ctx) { return; }
      const win: window.Window = await window.getLastWindow(ctx);
      if (!win) { return; }
      // 保存当前状态栏颜色 (从全局主题推导)
      const isDark: boolean = (AppStorage.get<string>('currentTheme') ?? 'light') === 'dark';
      this.savedStatusBarColor = isDark ? '#E6E6E6' : '#1C1C1C';
      // 强制深色模式: 亮色图标 + 透明背景
      await win.setWindowSystemBarProperties({
        statusBarColor: '#0A0D12',
        navigationBarColor: '#0A0D12',
        statusBarContentColor: '#E6E6E6',
        navigationBarContentColor: '#E6E6E6'
      });
      hilog.info(0x0000, 'SshTerminal', '[statusBar] 强制深色模式, saved=' + this.savedStatusBarColor);
    } catch (err) {
      hilog.warn(0x0001, 'SshTerminal', '[statusBar] forceStatusBarDark 失败: ' + JSON.stringify(err));
    }
  }

  /** 恢复系统状态栏颜色到进入 SSH 终端前的值 */
  private async restoreStatusBar(): Promise<void> {
    try {
      const ctx = this.getUIContext().getHostContext();
      if (!ctx) { return; }
      const win: window.Window = await window.getLastWindow(ctx);
      if (!win) { return; }
      const isDark: boolean = (AppStorage.get<string>('currentTheme') ?? 'light') === 'dark';
      const contentColor: string = isDark ? '#E6E6E6' : '#1C1C1C';
      await win.setWindowSystemBarProperties({
        statusBarColor: '#00000000',
        navigationBarColor: '#00000000',
        statusBarContentColor: contentColor,
        navigationBarContentColor: contentColor
      });
      hilog.info(0x0000, 'SshTerminal', '[statusBar] 恢复: ' + contentColor);
    } catch (err) {
      hilog.warn(0x0001, 'SshTerminal', '[statusBar] restoreStatusBar 失败: ' + JSON.stringify(err));
    }
  }

  /** 监听软键盘高度变化 (window.AvoidAreaType.TYPE_KEYBOARD) */
  private registerAvoidAreaListener(): void {
    try {
      const ctx = this.getUIContext().getHostContext();
      if (!ctx) { return; }
      window.getLastWindow(ctx).then((w: window.Window): void => {
        this.win = w;
        // 初始读取一次 (页面进入时键盘或导航栏可能已存在)
        this.syncAvoidHeights(w);
        this.avoidCb = (data: window.AvoidAreaOptions): void => {
          if (data.type === window.AvoidAreaType.TYPE_KEYBOARD) {
            this.kbHeight = px2vp(data.area.bottomRect.height);
          } else if (data.type === window.AvoidAreaType.TYPE_SYSTEM ||
            data.type === window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR ||
            data.type === window.AvoidAreaType.TYPE_CUTOUT) {
            this.syncAvoidHeights(w);
          }
        };
        w.on('avoidAreaChange', this.avoidCb);
      }).catch((err: Error): void => {
        hilog.warn(0x0001, 'SshTerminal', '[avoidArea] getLastWindow 失败: ' + err.message);
      });
    } catch (err) {
      hilog.warn(0x0001, 'SshTerminal', '[avoidArea] 注册失败: ' + JSON.stringify(err));
    }
  }

  private unregisterAvoidAreaListener(): void {
    try {
      if (this.win && this.avoidCb) {
        this.win.off('avoidAreaChange', this.avoidCb);
      }
    } catch (_e) { /* ignore */ }
    this.win = null;
    this.avoidCb = null;
  }

  private pal(): Palette {
    return this.theme === 'light' ? buildLight(this.accentColor) : buildDark(this.accentColor);
  }

  private sshPal(): Palette {
    return buildDark(this.accentColor);
  }

  // SSH 终端始终深色模式 — 顶栏和底栏不跟随系统主题, 固定深色背景+亮色文字
  private chromeBg(): string {
    return '#11151C';
  }

  private chromeChipBg(): string {
    return 'rgba(255,255,255,0.08)';
  }

  private connectionDotColor(): string {
    if (this.connected) { return '#34C759'; }
    if (this.connecting) { return this.accentColor; }
    return this.pal().danger;
  }

  private connectionLabel(): string {
    if (this.connected) {
      return this.latencyMs >= 0 ? `已连接 ${this.latencyMs}ms` : '已连接 --ms';
    }
    if (this.connecting) { return '连接中'; }
    return '断开';
  }

  private probeLatencyOnce(): void {
    if (!this.connected || this.sessionId <= 0 || this.latencyProbeRunning) { return; }
    this.latencyProbeRunning = true;
    this.tcpLatencyTest(this.sshHost, this.sshPort).then((latency: number): void => {
      this.latencyMs = latency;
      this.latencyProbeRunning = false;
      this.srv.updateConnectionHealth(this.hostId, latency, false);
    }).catch((err: BusinessError): void => {
      this.latencyMs = -1;
      this.latencyProbeRunning = false;
      this.srv.updateConnectionHealth(this.hostId, -1, false);
      hilog.warn(0x0001, 'SshTerminal', '[latency] TCP 检测失败: ' + err.message);
    });
  }

  private async tcpLatencyTest(host: string, port: number): Promise<number> {
    if (host.trim().length === 0 || port <= 0) { return -1; }
    const start: number = Date.now();
    let tcp: socket.TCPSocket | null = null;
    try {
      tcp = socket.constructTCPSocketInstance();
      const addr: socket.NetAddress = { address: host, port: port, family: 1 };
      await tcp.connect({ address: addr, timeout: 5000 });
      return Math.max(1, Date.now() - start);
    } catch (_e) {
      return -1;
    } finally {
      try { tcp?.close(); } catch (_e2) { /* ignore */ }
    }
  }

  private startLatencyProbe(): void {
    this.stopLatencyProbe();
    this.probeLatencyOnce();
    this.latencyTimer = setInterval((): void => {
      this.probeLatencyOnce();
    }, 5000);
  }

  private stopLatencyProbe(): void {
    if (this.latencyTimer !== -1) {
      clearInterval(this.latencyTimer);
      this.latencyTimer = -1;
    }
    this.latencyProbeRunning = false;
  }

  @State showPassphraseSheet: boolean = false;
  private passphraseResolve: ((v: string) => void) | null = null;
  @State passphraseInput: string = '';
  @State passphraseShowPw: boolean = false;
  // T-210: preflight token 数据 (从 HostList 传递)
  private preflightPassphrase: string = '';
  private preflightExpectedHostKeyRaw: string = '';
  private preflightExpectedHostKeyFp: string = '';

  private promptPassphrase(): Promise<string> {
    return new Promise<string>((resolve: (v: string) => void) => {
      this.passphraseResolve = resolve;
      this.passphraseInput = '';
      this.showPassphraseSheet = true;
    });
  }

  @Builder passphraseSheet() {
    Column() {
      Text('私钥密码').fontSize(18).fontWeight(FontWeight.Bold)
        .fontColor(this.pal().text).margin({ bottom: 8 })
      Text('此私钥已加密, 请输入密码').fontSize(14)
        .fontColor(this.pal().text2).margin({ bottom: 16 })
      Row() {
        TextInput({ placeholder: '输入密码', text: this.passphraseInput })
          .type(this.passphraseShowPw ? InputType.Normal : InputType.Password)
          .height(40).backgroundColor(this.pal().surface).borderRadius(8)
          .fontColor(this.pal().text).placeholderColor(this.pal().text3)
          .layoutWeight(1).padding({ left: 12, right: 12 })
          .onChange((v: string) => { this.passphraseInput = v; })
        SymbolGlyph(this.passphraseShowPw ? $r('sys.symbol.eye_slash') : $r('sys.symbol.eye'))
          .fontSize(18).fontColor([this.pal().text3]).margin({ left: 8 })
          .onClick(() => { this.passphraseShowPw = !this.passphraseShowPw; })
      }.width('100%').margin({ bottom: 20 })
      Row() {
        Button('取消').fontSize(14).height(38).layoutWeight(1)
          .backgroundColor(this.pal().surface).fontColor(this.pal().text2).borderRadius(8)
          .onClick(() => {
            this.showPassphraseSheet = false;
            if (this.passphraseResolve) {
              this.passphraseResolve('');
              this.passphraseResolve = null;
            }
          })
        Button('确定').fontSize(14).height(38).layoutWeight(1)
          .backgroundColor(this.accentColor).fontColor('#FFFFFF').borderRadius(8).margin({ left: 12 })
          .onClick(() => {
            this.showPassphraseSheet = false;
            if (this.passphraseResolve) {
              this.passphraseResolve(this.passphraseInput);
              this.passphraseResolve = null;
            }
          })
      }.width('100%')
    }.padding(20)
  }

  private async connect(host: RemoteHost): Promise<void> {
    try {
      if (!(await this.loader.waitForPendingTeardown())) {
        throw new Error('上一会话资源清理未完成 [E-TEARDOWN-PENDING]');
      }
      this.sshHost = host.host;
      this.sshPort = host.port;
      // 密钥解析: sshKeyId 优先 (引用 KeyVault), 回退 sshKeyData (旧副本)
      let keyData: string = host.sshKeyData;
      let keyEncryptedHint: boolean = false;
      if (host.sshKeyId !== '') {
        const kvs = KeyVaultService.getInstance();
        const ref = kvs.getSshKey(host.sshKeyId);
        if (ref) {
          keyData = ref.privateKey;
          keyEncryptedHint = ref.privateKeyEncrypted;
        }
      }
      const useKey: boolean = host.sshUseKey && keyData.length > 0;
      // T-210: 优先使用 preflight token 中的 passphrase; 否则用 host 保存的; 最后才弹窗
      let keyPassphrase: string = this.preflightPassphrase || host.sshKeyPassphrase || '';
      if (useKey) {
        const keyInfo: SshPrivateKeyInfo = this.loader.inspectSshPrivateKey(keyData, keyPassphrase);
        if (keyInfo.ok && !keyInfo.encrypted) {
          keyPassphrase = '';
        } else if (keyPassphrase === '' && (keyEncryptedHint || keyInfo.encrypted)) {
          // fallback: 无 preflight token 时弹窗 (兼容直接路由进入的旧路径)
          keyPassphrase = await this.promptPassphrase();
        }
      }

      const cfg: SessionConfig = {
        protocol: 'ssh',
        host: host.host,
        port: host.port,
        username: host.username,
        password: host.password,
        width: this.termCols,
        height: this.termRows,
        customHostname: host.customHostname,
        gatewayHost: host.proxyHost,
        gatewayPort: host.proxyPort,
        domain: '',
        codec: '',
        multiMonitor: false,
        monitorCount: 1,
        colorDepth: 32,
        authMethod: useKey ? 'publickey' : 'password',
        privateKeyPem: useKey ? keyData : '',
        privateKeyPassphrase: keyPassphrase,
        expectedHostKeyRawBase64: this.preflightExpectedHostKeyRaw || host.sshHostKeyRawBase64,
        expectedHostKeyFingerprintSha256: this.preflightExpectedHostKeyFp || host.sshHostKeyFingerprintSha256
      };
      this.sessionId = this.loader.connect(cfg);
      hilog.info(0x0001, 'SshTerminal',
        '[connect] sessionId=' + this.sessionId.toString() + ' auth=' + cfg.authMethod);
      if (this.sessionId <= 0) {
        throw new Error('连接失败 (code=' + this.sessionId.toString() + ')');
      }
      this.connected = true;
      this.connecting = false;
      await this.srv.updateLastConnected(this.hostId);
      this.startLatencyProbe();

      // 推送式数据接收: C++ reader 线程读到数据 → TSFN → 这里
      let dataChunkCount: number = 0;
      this.loader.setOnDataCallback(this.sessionId, (data: string): void => {
        if (!data || data.length === 0) { return; }
        dataChunkCount++;
        // 稀疏日志: 前 5 次 + 每 100 次
        if (dataChunkCount <= 5 || dataChunkCount % 100 === 0) {
          hilog.info(0x0000, 'SshTerminal',
            `SSH data #${dataChunkCount} len=${data.length} totalOut=${this.termOutput.length}`);
        }
        // 拼接 + 限制 50KB 防止内存膨胀
        let next: string = this.termOutput + data;
        if (next.length > 50000) { next = next.substring(next.length - 50000); }
        this.termOutput = next;
      });

      // PC/2in1 默认获焦
      if (this.isDesktopDevice) {
        setTimeout((): void => { this.focusKeyboard(); }, 100);
      }
    } catch (err) {
      this.connecting = false;
      const msg: string = (err as Error).message || 'SSH 连接失败';
      await this.srv.updateConnectionHealth(this.hostId, -1, false);
      hilog.error(0x0001, 'SshTerminal', '[connect] 异常: ' + msg);
      this.connectionError = msg;
    }
  }

  private virtualModifiers(): TerminalModifierState {
    return { ctrl: this.ctrlActive, alt: this.altActive, shift: this.shiftActive };
  }

  private sendTerminalBytes(data: string): void {
    if (this.sessionId <= 0 || data.length === 0) { return; }
    this.loader.sendData(this.sessionId, data);
  }

  /** 发送文本到 SSH 服务端; 修饰键 active 时由统一策略编码组合。 */
  private onTerminalData(data: string): void {
    this.sendTerminalBytes(encodeTextInput(data, this.virtualModifiers()));
  }

  private setVirtualModifier(modifier: string, active: boolean): void {
    if (modifier === 'ctrl') { this.ctrlActive = active; }
    else if (modifier === 'alt') { this.altActive = active; }
    else if (modifier === 'shift') { this.shiftActive = active; }
  }

  private focusKeyboard(): void {
    try {
      this.getUIContext().getFocusController().requestFocus('sshKbInput');
    } catch (_e) {
      try { focusControl.requestFocus('sshKbInput'); } catch (_e2) { /* ignore */ }
    }
  }

  /** TerminalEmulator 回传文本后写入系统剪贴板 (写入无需权限) */
  private onCopiedTextChange(): void {
    const text: string = this.copiedText;
    if (text.length === 0) { return; }
    try {
      const pd: pasteboard.PasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
      pasteboard.getSystemPasteboard().setData(pd);
    } catch (err) {
      hilog.warn(0x0001, 'SshTerminal', '[onCopiedTextChange] code=C001 ' + JSON.stringify(err));
    }
  }

  /** 进入选区模式 (长按菜单"选择") */
  private enterSelectMode(): void {
    this.selectMode = true;
  }

  private normalizeRemoteDir(path: string): string {
    const trimmed: string = path.trim();
    if (trimmed === '') { return '.'; }
    let p: string = trimmed.replace(/\/+/g, '/');
    if (p.length > 1 && p.endsWith('/')) { p = p.substring(0, p.length - 1); }
    return p;
  }

  private remoteBaseName(path: string): string {
    const p: string = this.normalizeRemoteDir(path);
    const idx: number = p.lastIndexOf('/');
    if (idx >= 0 && idx < p.length - 1) { return p.substring(idx + 1); }
    if (p === '/' || p === '.') { return 'download.bin'; }
    return p;
  }

  private joinRemotePath(dir: string, name: string): string {
    const cleanName: string = name.replace(/\\/g, '/').split('/').pop() || 'file';
    const d: string = this.normalizeRemoteDir(dir);
    if (d === '/' || d === '') { return '/' + cleanName; }
    if (d === '.') { return cleanName; }
    return d + '/' + cleanName;
  }

  private parentRemotePath(path: string): string {
    const p: string = this.normalizeRemoteDir(path);
    if (p === '/' || p === '.' || p === '') { return '.'; }
    const idx: number = p.lastIndexOf('/');
    if (idx <= 0) { return p.startsWith('/') ? '/' : '.'; }
    return p.substring(0, idx);
  }

  private formatFileSize(size: number): string {
    if (size < 1024) { return size.toString() + ' B'; }
    if (size < 1024 * 1024) { return (size / 1024).toFixed(1) + ' KB'; }
    if (size < 1024 * 1024 * 1024) { return (size / 1024 / 1024).toFixed(1) + ' MB'; }
    return (size / 1024 / 1024 / 1024).toFixed(1) + ' GB';
  }

  private sortSftpEntries(entries: SftpFileEntry[]): SftpFileEntry[] {
    return entries.sort((a: SftpFileEntry, b: SftpFileEntry): number => {
      if (a.isDirectory !== b.isDirectory) { return a.isDirectory ? -1 : 1; }
      return a.name.localeCompare(b.name);
    });
  }

  private refreshSftp(path?: string): void {
    if (this.terminalClosing || this.sessionId <= 0 || this.sftpBusy) { return; }
    this.clearSftpRefreshTimer();
    const target: string = this.normalizeRemoteDir(path || this.sftpPath);
    this.sftpBusy = true;
    this.sftpStatus = '正在读取远端目录...';
    try {
      const entries: SftpFileEntry[] = this.loader.listRemoteDir(this.sessionId, target);
      this.sftpEntries = this.sortSftpEntries(entries);
      this.sftpPath = target;
      this.sftpPathInput = target;
      this.sftpSelectedPath = '';
      this.sftpSelectedName = '';
      this.sftpSelectedIsDir = false;
      this.sftpSelectedSize = 0;
      this.sftpNameInput = '';
      this.sftpStatus = '已加载 ' + entries.length.toString() + ' 项';
    } catch (err) {
      this.sftpStatus = '[SFTP-LIST] 读取目录失败: ' + JSON.stringify(err);
    }
    this.sftpBusy = false;
  }

  private openSftpPanel(): void {
    this.sftpPanelOpenedAt = Date.now();
    this.showSftpPanel = true;
    if (this.sftpEntries.length === 0) {
      // 先让半模态完成挂载和高度测量, 避免打开瞬间刷新目录触发重建后被系统反向 dismiss。
      this.scheduleSftpRefresh(this.sftpPath, 260);
    }
  }

  private sftpSheetHeight(): SheetSize | number {
    return SheetSize.FIT_CONTENT;
  }

  private sftpListHeight(): number {
    if (this.isDesktopDevice) { return 280; }
    return this.breakpoint === 'sm' ? 190 : 220;
  }

  private handleSftpSheetDismiss(action: DismissSheetAction): void {
    const elapsed: number = Date.now() - this.sftpPanelOpenedAt;
    if (elapsed < 500 || this.sftpBusy) {
      return;
    }
    this.showSftpPanel = false;
    action.dismiss();
  }

  private enterSftpEntry(entry: SftpFileEntry): void {
    this.sftpSelectedPath = entry.path;
    this.sftpSelectedName = entry.name;
    this.sftpSelectedIsDir = entry.isDirectory;
    this.sftpSelectedSize = entry.size;
    this.sftpNameInput = entry.name;
    this.sftpStatus = entry.isDirectory ? '已选择目录 ' + entry.name : '已选择 ' + entry.name + ' (' + this.formatFileSize(entry.size) + ')';
  }

  private openSftpSelectedDir(): void {
    if (!this.sftpSelectedIsDir || this.sftpSelectedPath.length === 0) { return; }
    this.refreshSftp(this.sftpSelectedPath);
  }

  private isValidRemoteName(name: string): boolean {
    const trimmed: string = name.trim();
    return trimmed.length > 0 && trimmed.indexOf('/') < 0 && trimmed.indexOf('\\') < 0;
  }

  private gotoSftpPath(): void {
    if (this.sftpBusy) { return; }
    this.refreshSftp(this.sftpPathInput);
  }

  private clearSftpRefreshTimer(): void {
    if (this.sftpRefreshTimer !== -1) {
      clearTimeout(this.sftpRefreshTimer);
      this.sftpRefreshTimer = -1;
    }
  }

  private scheduleSftpRefresh(path: string, delayMs: number): void {
    this.clearSftpRefreshTimer();
    this.sftpRefreshTimer = setTimeout((): void => {
      this.sftpRefreshTimer = -1;
      if (this.terminalClosing || this.sessionId <= 0) { return; }
      this.refreshSftp(path);
    }, delayMs);
  }

  private resetSftpTransferState(): void {
    this.sftpBusy = false;
    this.sftpProgress = -1;
    this.sftpProgressLabel = '处理中';
  }

  private beginSftpTransfer(direction: 'upload' | 'download', fileName: string, totalBytes: number,
    offset: number = 0): TransferSession {
    const session: TransferSession = {
      id: 'ssh-' + direction + '-' + Date.now().toString(), protocol: 'ssh', direction, fileName,
      totalBytes, transferredBytes: offset, stage: 'transferring', canCancel: true, diagnosticCode: ''
    };
    this.sftpTransferSession = session;
    this.sftpBusy = true;
    this.sftpProgress = totalBytes > 0 ? offset / totalBytes : 0;
    return session;
  }

  private shouldStopSftpTransfer(session: TransferSession): boolean {
    return this.terminalClosing || this.sessionId <= 0 || this.sftpTransferSession === null ||
      this.sftpTransferSession.id !== session.id || this.sftpTransferSession.stage === 'cancelled';
  }

  private isSftpTransferCancelled(session: TransferSession): boolean {
    return this.sftpTransferSession !== null && this.sftpTransferSession.id === session.id &&
      this.sftpTransferSession.stage === 'cancelled';
  }

  private updateSftpTransfer(session: TransferSession, transferredBytes: number): void {
    if (this.sftpTransferSession === null || this.sftpTransferSession.id !== session.id) { return; }
    const current: TransferSession = this.sftpTransferSession;
    this.sftpTransferSession = {
      id: session.id, protocol: session.protocol, direction: session.direction, fileName: session.fileName,
      totalBytes: session.totalBytes, transferredBytes, stage: current.stage,
      canCancel: current.canCancel, diagnosticCode: current.diagnosticCode
    };
    this.sftpProgress = Math.min(1, transferredBytes / session.totalBytes);
  }

  private finishSftpTransfer(session: TransferSession, stage: TransferStage, diagnosticCode: string = ''): void {
    if (this.sftpTransferSession === null || this.sftpTransferSession.id !== session.id) { return; }
    const current: TransferSession = this.sftpTransferSession;
    this.sftpTransferSession = {
      id: current.id, protocol: current.protocol, direction: current.direction, fileName: current.fileName,
      totalBytes: current.totalBytes, transferredBytes: current.transferredBytes, stage,
      canCancel: false, diagnosticCode
    };
    this.resetSftpTransferState();
  }

  private stopSftpTransfer(session: TransferSession, failureCode: string): void {
    if (this.isSftpTransferCancelled(session)) {
      const diagnosticCode: string = this.sftpTransferSession === null ? 'cancelled-by-user' :
        this.sftpTransferSession.diagnosticCode;
      this.finishSftpTransfer(session, 'cancelled', diagnosticCode);
      return;
    }
    this.finishSftpTransfer(session, 'failed', failureCode);
  }

  private cancelSftpTransfer(): void {
    if (this.sftpTransferSession === null) { return; }
    this.sftpTransferSession = cancelTransfer(this.sftpTransferSession);
    if (this.sftpTransferSession.stage === 'cancelled') {
      this.sftpStatus = '已取消 ' + this.sftpTransferSession.fileName;
    }
  }

  private async yieldUi(ms: number = 0): Promise<void> {
    await new Promise<void>((resolve: () => void): void => {
      setTimeout(resolve, ms);
    });
  }

  private async uploadSftpFile(): Promise<void> {
    if (this.sessionId <= 0 || this.sftpBusy) { return; }
    try {
      const docPicker = new picker.DocumentViewPicker();
      const uris: string[] = await docPicker.select();
      if (!uris || uris.length === 0) { return; }
      const uri: string = uris[0];
      let fileName: string = uri.substring(Math.max(uri.lastIndexOf('/'), uri.lastIndexOf('\\')) + 1);
      try { fileName = decodeURIComponent(fileName); } catch (_e) { /* ignore */ }
      const remotePath: string = this.joinRemotePath(this.sftpPath, fileName);
      await this.uploadSftpToRemote(uri, fileName, remotePath, 0);
    } catch (_err) {
      this.sftpStatus = '[SFTP-UPLOAD] 选择文件失败';
    }
  }

  private async uploadSftpToRemote(uri: string, fileName: string, remotePath: string,
    recordedOffset: number): Promise<void> {
    let file: fileIo.File | null = null;
    let session: TransferSession | null = null;
    try {
      // Check the selected URI before opening its descriptor so the 512 MiB guard is never bypassed.
      const fileSize: number = fileIo.statSync(uri).size;
      if (fileSize <= 0 || fileSize > SFTP_MAX_TRANSFER_BYTES) {
        this.sftpStatus = '[SFTP-UPLOAD] 文件为空或超过 512MB';
        return;
      }
      const resumeOffset: number = uploadResumeOffset(recordedOffset, fileSize);
      if (resumeOffset < 0) {
        this.sftpStatus = '[SFTP-UPLOAD] 源文件大小已变化，无法继续传输';
        return;
      }
      session = this.beginSftpTransfer('upload', fileName, fileSize, resumeOffset);
      this.sftpTransferUri = uri;
      this.sftpTransferRemotePath = remotePath;
      this.sftpProgressLabel = '上传中';
      this.sftpStatus = '正在上传 ' + fileName + ' ' + Math.floor(this.sftpProgress * 100).toString() + '%';
      await this.yieldUi(16);
      if (this.shouldStopSftpTransfer(session)) {
        this.stopSftpTransfer(session, 'upload-connection-unavailable');
        return;
      }
      file = fileIo.openSync(uri, fileIo.OpenMode.READ_ONLY);
      let uploaded: number = session.transferredBytes;
      if (fileIo.lseek(file.fd, uploaded) !== uploaded) {
        fileIo.closeSync(file);
        file = null;
        this.stopSftpTransfer(session, 'upload-local-seek-failed');
        return;
      }
      while (uploaded < fileSize) {
        if (this.shouldStopSftpTransfer(session)) {
          fileIo.closeSync(file); file = null;
          this.stopSftpTransfer(session, 'upload-connection-unavailable');
          return;
        }
        const chunkSize: number = Math.min(SFTP_UPLOAD_CHUNK_BYTES, fileSize - uploaded);
        const chunk = new ArrayBuffer(chunkSize);
        const readLen: number = fileIo.readSync(file.fd, chunk);
        if (readLen <= 0) {
          this.sftpStatus = '[SFTP-UPLOAD] 文件读取中断';
          fileIo.closeSync(file);
          file = null;
          this.stopSftpTransfer(session, 'upload-local-read-failed');
          return;
        }
        const payload: ArrayBuffer = readLen === chunkSize ? chunk : chunk.slice(0, readLen);
        if (this.shouldStopSftpTransfer(session)) {
          fileIo.closeSync(file); file = null;
          this.stopSftpTransfer(session, 'upload-connection-unavailable');
          return;
        }
        const ret: number = this.loader.writeRemoteFileChunk(
          this.sessionId,
          remotePath,
          payload,
          uploaded,
          uploaded === 0);
        const confirmedOffset: number = recordConfirmedUploadWrite(uploaded, ret, payload.byteLength);
        if (confirmedOffset !== uploaded) {
          uploaded = confirmedOffset;
          this.updateSftpTransfer(session, uploaded);
        }
        if (ret !== payload.byteLength) {
          this.sftpStatus = '[SFTP-UPLOAD] 上传中断，可从已确认进度重试';
          fileIo.closeSync(file);
          file = null;
          this.stopSftpTransfer(session, 'upload-remote-write-unconfirmed');
          return;
        }
        this.sftpStatus = '正在上传 ' + fileName + ' ' + Math.floor(this.sftpProgress * 100).toString() + '%';
        await this.yieldUi(16);
        if (this.shouldStopSftpTransfer(session)) {
          fileIo.closeSync(file);
          file = null;
          this.stopSftpTransfer(session, 'upload-connection-unavailable');
          return;
        }
      }
      fileIo.closeSync(file);
      file = null;
      this.finishSftpTransfer(session, 'completed');
      this.sftpStatus = '已上传 ' + fileName;
      promptAction.showToast({ message: 'SFTP 上传完成', duration: 1500 });
      this.scheduleSftpRefresh(this.sftpPath, 180);
    } catch (err) {
      if (file !== null) {
        try { fileIo.closeSync(file); } catch (_e2) { /* ignore */ }
      }
      if (session !== null) { this.stopSftpTransfer(session, 'upload-exception'); }
      this.sftpStatus = '[SFTP-UPLOAD] 上传失败';
    }
  }

  private async downloadSftpSelected(): Promise<void> {
    if (this.sessionId <= 0 || this.sftpBusy || this.sftpSelectedPath.length === 0) { return; }
    try {
      const totalSize: number = this.sftpSelectedSize;
      if (totalSize <= 0 || totalSize > SFTP_MAX_TRANSFER_BYTES) {
        this.sftpStatus = '[SFTP-DOWNLOAD] 文件为空或超过 512MB';
        return;
      }
      const options = new picker.DocumentSaveOptions();
      options.newFileNames = [this.remoteBaseName(this.sftpSelectedPath)];
      const docPicker = new picker.DocumentViewPicker();
      const uris: string[] = await docPicker.save(options);
      if (!uris || uris.length === 0) {
        this.sftpStatus = '已取消保存';
        return;
      }
      await this.downloadSftpToLocal(uris[0], this.sftpSelectedName, this.sftpSelectedPath, totalSize, 0);
    } catch (_err) {
      this.sftpStatus = '[SFTP-DOWNLOAD] 选择保存位置失败';
    }
  }

  private async downloadSftpToLocal(uri: string, fileName: string, remotePath: string,
    totalSize: number, recordedOffset: number): Promise<void> {
    let outFile: fileIo.File | null = null;
    let session: TransferSession | null = null;
    try {
      outFile = fileIo.openSync(uri, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE);
      const localBytes: number = fileIo.statSync(outFile.fd).size;
      const resumeOffset: number = downloadResumeOffset(recordedOffset, localBytes, totalSize);
      if (resumeOffset < 0) {
        fileIo.closeSync(outFile);
        outFile = null;
        this.sftpStatus = '[SFTP-DOWNLOAD] 本地文件长度无效，无法继续传输';
        return;
      }
      session = this.beginSftpTransfer('download', fileName, totalSize, resumeOffset);
      this.sftpTransferUri = uri;
      this.sftpTransferRemotePath = remotePath;
      this.sftpProgressLabel = '下载中';
      this.sftpStatus = '正在下载 ' + fileName + ' ' + Math.floor(this.sftpProgress * 100).toString() + '%';
      await this.yieldUi(16);
      if (this.shouldStopSftpTransfer(session)) {
        fileIo.closeSync(outFile);
        outFile = null;
        this.stopSftpTransfer(session, 'download-connection-unavailable');
        return;
      }
      const targetFile: fileIo.File = outFile;
      let downloaded: number = session.transferredBytes;
      if (fileIo.lseek(targetFile.fd, downloaded) !== downloaded) {
        fileIo.closeSync(targetFile);
        outFile = null;
        this.stopSftpTransfer(session, 'download-local-seek-failed');
        return;
      }
      while (downloaded < totalSize) {
        if (this.shouldStopSftpTransfer(session)) {
          fileIo.closeSync(targetFile); outFile = null;
          this.stopSftpTransfer(session, 'download-connection-unavailable');
          return;
        }
        const chunkSize: number = Math.min(SFTP_DOWNLOAD_CHUNK_BYTES, totalSize - downloaded);
        const data: ArrayBuffer = this.loader.readRemoteFileChunk(
          this.sessionId,
          remotePath,
          downloaded,
          chunkSize);
        if (data.byteLength <= 0) {
          fileIo.closeSync(targetFile);
          outFile = null;
          this.sftpStatus = '[SFTP-DOWNLOAD] 远端读取中断';
          this.stopSftpTransfer(session, 'download-remote-read-failed');
          return;
        }
        if (this.shouldStopSftpTransfer(session)) {
          fileIo.closeSync(targetFile); outFile = null;
          this.stopSftpTransfer(session, 'download-connection-unavailable');
          return;
        }
        const written: number = fileIo.writeSync(targetFile.fd, data);
        if (written !== data.byteLength) {
          fileIo.closeSync(targetFile);
          outFile = null;
          this.sftpStatus = '[SFTP-DOWNLOAD] 本地写入不完整';
          this.stopSftpTransfer(session, 'download-local-write-failed');
          return;
        }
        downloaded += data.byteLength;
        this.updateSftpTransfer(session, downloaded);
        this.sftpStatus = '正在下载 ' + fileName + ' ' +
          Math.floor(this.sftpProgress * 100).toString() + '%';
        await this.yieldUi(16);
        if (this.shouldStopSftpTransfer(session)) {
          fileIo.closeSync(targetFile);
          outFile = null;
          this.stopSftpTransfer(session, 'download-connection-unavailable');
          return;
        }
      }
      fileIo.closeSync(targetFile);
      outFile = null;
      this.finishSftpTransfer(session, 'completed');
      this.sftpStatus = '已保存 ' + downloaded.toString() + ' 字节';
      promptAction.showToast({ message: 'SFTP 下载完成', duration: 1500 });
    } catch (err) {
      if (outFile !== null) {
        try { fileIo.closeSync(outFile); } catch (_e2) { /* ignore */ }
      }
      if (session !== null) { this.stopSftpTransfer(session, 'download-exception'); }
      this.sftpStatus = '[SFTP-DOWNLOAD] 下载失败';
    }
  }

  private async retrySftpTransfer(): Promise<void> {
    const previous: TransferSession | null = this.sftpTransferSession;
    if (this.sftpBusy || previous === null ||
      (previous.stage !== 'failed' && previous.stage !== 'cancelled') ||
      this.sftpTransferUri.length === 0 || this.sftpTransferRemotePath.length === 0) { return; }
    if (previous.direction === 'upload') {
      await this.uploadSftpToRemote(this.sftpTransferUri, previous.fileName, this.sftpTransferRemotePath,
        previous.transferredBytes);
    } else {
      await this.downloadSftpToLocal(this.sftpTransferUri, previous.fileName, this.sftpTransferRemotePath,
        previous.totalBytes, previous.transferredBytes);
    }
  }

  private deleteSftpSelected(): void {
    if (this.sessionId <= 0 || this.sftpBusy || this.sftpSelectedPath.length === 0) { return; }
    const targetIsDir: boolean = this.sftpSelectedIsDir;
    promptAction.showDialog({
      title: targetIsDir ? '删除远端目录' : '删除远端文件',
      message: '确定删除 ' + this.sftpSelectedName + ' 吗？' + (targetIsDir ? ' 目录必须为空。' : ''),
      buttons: [
        { text: '取消', color: this.pal().text2 },
        { text: '删除', color: this.pal().danger }
      ]
    }).then((res): void => {
      if (res.index !== 1) { return; }
      this.sftpBusy = true;
      const ret: number = targetIsDir ?
        this.loader.removeRemoteDir(this.sessionId, this.sftpSelectedPath) :
        this.loader.removeRemoteFile(this.sessionId, this.sftpSelectedPath);
      this.sftpBusy = false;
      if (ret === 0) {
        this.sftpStatus = '已删除 ' + this.sftpSelectedName;
        this.refreshSftp(this.sftpPath);
      } else {
        this.sftpStatus = '[SFTP-DELETE] 删除失败 ret=' + ret.toString();
      }
    }).catch((err: BusinessError): void => {
      this.sftpStatus = '[SFTP-DELETE] 对话框失败: ' + err.message;
    });
  }

  private makeSftpDir(): void {
    if (this.sessionId <= 0 || this.sftpBusy) { return; }
    const candidate: string = this.sftpNameInput.trim();
    if (candidate.length > 0 && !this.isValidRemoteName(candidate)) {
      this.sftpStatus = '[SFTP-MKDIR] 目录名无效';
      return;
    }
    const dirName: string = candidate.length > 0 ? candidate : 'NewFolder-' + Date.now().toString();
    const remotePath: string = this.joinRemotePath(this.sftpPath, dirName);
    this.sftpBusy = true;
    const ret: number = this.loader.makeRemoteDir(this.sessionId, remotePath);
    this.sftpBusy = false;
    if (ret === 0) {
      this.sftpStatus = '已创建目录 ' + dirName;
      this.refreshSftp(this.sftpPath);
    } else {
      this.sftpStatus = '[SFTP-MKDIR] 创建失败 ret=' + ret.toString();
    }
  }

  private renameSftpSelected(): void {
    if (this.sessionId <= 0 || this.sftpBusy || this.sftpSelectedPath.length === 0) { return; }
    const trimmed: string = this.sftpNameInput.trim();
    if (!this.isValidRemoteName(trimmed)) {
      this.sftpStatus = '[SFTP-RENAME] 新名称无效';
      return;
    }
    const newPath: string = this.joinRemotePath(this.parentRemotePath(this.sftpSelectedPath), trimmed);
    this.sftpBusy = true;
    const ret: number = this.loader.renameRemotePath(this.sessionId, this.sftpSelectedPath, newPath);
    this.sftpBusy = false;
    if (ret === 0) {
      this.sftpStatus = '已重命名为 ' + trimmed;
      this.refreshSftp(this.sftpPath);
    } else {
      this.sftpStatus = '[SFTP-RENAME] 重命名失败 ret=' + ret.toString();
    }
  }

  /** 执行复制: 触发 TerminalEmulator 回传选区/整屏文本, 然后退出选区模式 */
  private doCopy(): void {
    this.copyRequest = this.copyRequest + 1;
    this.selectMode = false;
  }

  /** 全选并复制: 清空选区 → copyRequest 触发 getSelection 回退整屏 */
  private doCopyAll(): void {
    this.selectMode = false;
    this.copyRequest = this.copyRequest + 1;
  }

  /** PC 端 Ctrl+V 粘贴 — 仅桌面设备处理。 */
  private handlePaste(content: string): void {
    if (!this.isDesktopDevice) { return; }
    if (content.length > 0) { this.onTerminalData(content); }
    this.resetKeyboardBuffer();
  }

  /** 清空隐藏输入框缓存。onWillInsert/onWillDelete/onSubmit 每次都调用。 */
  private resetKeyboardBuffer(): void {
    this.kbInput = '';
    try { this.kbCtrl.caretPosition(0); } catch (_e) { /* ignore */ }
  }

  private handleSoftInsert(info: InsertValue): boolean {
    const text: string = info.insertValue;
    if (text.length > 0) { this.onTerminalData(text); }
    this.resetKeyboardBuffer();
    return false;
  }

  private handleSoftDelete(info: DeleteValue): boolean {
    this.sendTerminalBytes(encodeSoftDelete(info.deleteValue));
    this.resetKeyboardBuffer();
    return false;
  }

  /**
   * 兜底守卫 — 仅当 IME 绕过 onWillInsert 直接修改 TextInput 时触发。
   * 正常情况下 onWillInsert 返回 false 阻止插入, TextInput 始终为空, 本方法不会 send。
   */
  private handleChangeGuard(v: string): void {
    if (v.length > 0) {
      hilog.warn(0x0001, 'SshTerminal',
        '[input] onChange 兜底触发 (IME 可能未遵守 onWillInsert), len=' + v.length.toString());
      this.onTerminalData(v);
      this.resetKeyboardBuffer();
    }
  }

  /** 终端长按上下文菜单: 选择 / 复制 / 全选并复制 */
  @Builder
  TermMenu() {
    Menu() {
      MenuItem({ content: this.selectMode ? '复制选区' : '选择' })
        .onClick((): void => {
          if (this.selectMode) { this.doCopy(); }
          else { this.enterSelectMode(); }
        })
      MenuItem({ content: '全选并复制' })
        .onClick((): void => { this.doCopyAll(); })
    }
  }

  @Builder
  SftpTransferSheet() {
    Column() {
      Row() {
        Column() {
          Text('SFTP 文件传输').fontSize(18).fontWeight(FontWeight.Medium).fontColor(this.sshPal().text)
          Text(this.userAtHost).fontSize(12).fontColor(this.sshPal().text2).margin({ top: 4 })
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        Text('×').fontSize(22).fontColor(this.sshPal().text2)
          .width(36).height(36).textAlign(TextAlign.Center)
          .borderRadius(18).backgroundColor(this.sshPal().surface)
          .onClick((): void => { this.showSftpPanel = false; })
      }.width('100%').margin({ bottom: 18 })

      Row() {
        Button('上级').height(36).fontSize(12)
          .enabled(!this.sftpBusy)
          .onClick((): void => { this.refreshSftp(this.parentRemotePath(this.sftpPath)); })
        Button('刷新').height(36).fontSize(12).margin({ left: 8 })
          .enabled(!this.sftpBusy)
          .onClick((): void => { this.refreshSftp(this.sftpPath); })
        Button('根目录').height(36).fontSize(12).margin({ left: 8 })
          .enabled(!this.sftpBusy)
          .onClick((): void => { this.refreshSftp('/'); })
        Button('新建目录').height(36).fontSize(12).margin({ left: 8 })
          .enabled(!this.sftpBusy)
          .onClick((): void => { this.makeSftpDir(); })
      }.width('100%').margin({ bottom: 10 })

      Row() {
        TextInput({ text: this.sftpPathInput })
          .fontSize(12).fontColor(this.sshPal().text).fontFamily('monospace')
          .backgroundColor(this.sshPal().surface)
          .height(38).borderRadius(8).layoutWeight(1)
          .onChange((value: string): void => { this.sftpPathInput = value; })
          .onSubmit((): void => { this.gotoSftpPath(); })
        Button('跳转').height(38).fontSize(12).margin({ left: 8 })
          .enabled(!this.sftpBusy)
          .onClick((): void => { this.gotoSftpPath(); })
      }.width('100%').margin({ bottom: 10 })

      Row() {
        TextInput({ text: this.sftpNameInput, placeholder: '输入目录名或重命名后的名称' })
          .fontSize(12).fontColor(this.sshPal().text).placeholderColor(this.sshPal().text3)
          .backgroundColor(this.sshPal().surface)
          .height(38).borderRadius(8).layoutWeight(1)
          .onChange((value: string): void => { this.sftpNameInput = value; })
        Button('重命名').height(38).fontSize(12).margin({ left: 8 })
          .enabled(!this.sftpBusy && this.sftpSelectedPath.length > 0 && this.sftpNameInput.trim().length > 0)
          .onClick((): void => { this.renameSftpSelected(); })
      }.width('100%').margin({ bottom: 10 })

      Column() {
        if (this.sftpBusy) {
          Column() {
            Row() {
              LoadingProgress().width(22).height(22).color(this.accentColor)
              Text(this.sftpProgress >= 0 ?
                (this.sftpProgressLabel + ' ' + Math.floor(this.sftpProgress * 100).toString() + '%') : '处理中...')
                .fontSize(12).fontColor(this.sshPal().text2).margin({ left: 8 })
            }.height(34).justifyContent(FlexAlign.Center)
            if (this.sftpProgress >= 0) {
              Progress({ value: Math.floor(this.sftpProgress * 100), total: 100, type: ProgressType.Linear })
                .width('86%').height(4).color(this.accentColor).backgroundColor(this.sshPal().divider)
                .margin({ top: 4 })
            }
          }.height(transferProgressPanelHeight(this.sftpTransferSession)).justifyContent(FlexAlign.Center)
        } else if (this.sftpEntries.length === 0) {
          Column() {
            Text('远端目录为空').fontSize(13).fontColor(this.sshPal().text2)
            Text('可点击上传文件或刷新目录').fontSize(11).fontColor(this.sshPal().text3).margin({ top: 4 })
          }.height(120).justifyContent(FlexAlign.Center)
        } else {
          List() {
            ForEach(this.sftpEntries, (entry: SftpFileEntry) => {
              ListItem() {
                Row() {
                  SymbolGlyph(entry.isDirectory ? $r('sys.symbol.folder') : $r('sys.symbol.doc'))
                    .fontSize(18)
                    .fontColor([entry.isDirectory ? this.accentColor : this.sshPal().text3])
                    .width(28)
                  Column() {
                    Text(entry.name)
                      .fontSize(13).fontColor(this.sshPal().text)
                      .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                    Text(entry.isDirectory ? '目录' : this.formatFileSize(entry.size))
                      .fontSize(10).fontColor(this.sshPal().text3).margin({ top: 2 })
                  }.alignItems(HorizontalAlign.Start).layoutWeight(1)
                  if (this.sftpSelectedPath === entry.path) {
                    SymbolGlyph($r('sys.symbol.checkmark'))
                      .fontSize(17).fontColor([this.accentColor])
                  }
                }
                .width('100%').height(48).padding({ left: 10, right: 10 })
                .borderRadius(8)
                .backgroundColor(this.sftpSelectedPath === entry.path ? this.sshPal().card : Color.Transparent)
                .onClick((): void => { this.enterSftpEntry(entry); })
              }
            }, (entry: SftpFileEntry) => entry.path)
          }
          .height(this.sftpListHeight())
          .width('100%')
        }
      }
      .width('100%')
      .padding({ top: 6, bottom: 6 })
      .backgroundColor(this.sshPal().surface)
      .borderRadius(10)
      .border({ width: 0.5, color: this.sshPal().divider })

      if (shouldShowTransferCancelAction(this.sftpTransferSession)) {
        Button('取消传输')
          .height(40).fontSize(13).width('100%').margin({ top: 10 })
          .backgroundColor(this.sshPal().danger).fontColor('#FFFFFF').borderRadius(8)
          .onClick((): void => { this.cancelSftpTransfer(); })
      }

      Text(this.sftpStatus)
        .fontSize(11).fontColor(this.sshPal().text2).width('100%')
        .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
        .margin({ top: 10 })

      if (!this.sftpBusy && this.sftpTransferSession !== null &&
        (this.sftpTransferSession.stage === 'failed' || this.sftpTransferSession.stage === 'cancelled')) {
        Button('重试传输')
          .height(34).fontSize(12).width('100%').margin({ top: 10 })
          .onClick((): void => { this.retrySftpTransfer(); })
      }

      Row() {
        Button('上传到当前目录')
          .height(40).layoutWeight(1).enabled(!this.sftpBusy)
          .fontSize(12)
          .onClick((): void => { this.uploadSftpFile(); })
        Button('下载选中文件')
          .height(40).layoutWeight(1)
          .enabled(!this.sftpBusy && this.sftpSelectedPath.length > 0 && !this.sftpSelectedIsDir)
          .fontSize(12)
          .margin({ left: 10 })
          .onClick((): void => { this.downloadSftpSelected(); })
      }.width('100%').margin({ top: 14 })

      Row() {
        Button('进入目录')
          .height(38).layoutWeight(1)
          .enabled(!this.sftpBusy && this.sftpSelectedPath.length > 0 && this.sftpSelectedIsDir)
          .fontSize(12)
          .onClick((): void => { this.openSftpSelectedDir(); })
        Button('删除选中项')
          .height(38).layoutWeight(1)
          .enabled(!this.sftpBusy && this.sftpSelectedPath.length > 0)
          .fontSize(12).backgroundColor(this.sshPal().danger).fontColor('#FFFFFF')
          .margin({ left: 10 })
          .onClick((): void => { this.deleteSftpSelected(); })
      }.width('100%').margin({ top: 16 })
    }
    .width('100%')
    .constraintSize({ maxWidth: 620 })
    .padding({ left: 22, right: 22, top: 20, bottom: 22 })
    .borderRadius(18)
    .backgroundColor(this.sshPal().bg)
  }

  build() {
    Column() {
      // 顶栏 — SSH 终端始终深色模式, 固定深色背景+亮色文字, 不跟随系统主题
      Row() {
        if (this.isDesktopDevice) {
          Row() {
            Text('←').fontSize(18).fontColor('#E6E6E6').margin({ right: 6 })
            Text('返回').fontSize(14).fontColor('#E6E6E6')
          }
          .height(36).padding({ left: 12, right: 14 })
          .borderRadius(18)
          .backgroundColor(this.backHover ? 'rgba(255,255,255,0.14)' : 'rgba(255,255,255,0.05)')
          .onHover((isHover: boolean): void => { this.backHover = isHover; })
          .onClick(() => { router.back(); })
        } else {
          Text('<').fontSize(20).fontColor('#E6E6E6')
            .width(40).height(40).textAlign(TextAlign.Center)
            .borderRadius(20)
            .backgroundColor('rgba(255,255,255,0.06)')
            .onClick(() => { router.back(); })
        }
        Column() {
          Text(this.hostLabel).fontSize(15).fontWeight(FontWeight.Medium).fontColor('#F2F4F7')
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.userAtHost).fontSize(11).fontColor('rgba(242,244,247,0.58)')
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        }.alignItems(HorizontalAlign.Start).layoutWeight(1).margin({ left: 10 })
        if (this.isDesktopDevice) {
          Text('Ctrl+Shift+Q 退出')
            .fontSize(11).fontColor('rgba(242,244,247,0.54)')
            .margin({ right: 12 })
        }
        if (this.connected) {
          if (!this.isDesktopDevice) {
            Row() {
              Text('↻').fontSize(19).fontColor('rgba(242,244,247,0.86)')
            }
            .width(34)
            .height(34)
            .justifyContent(FlexAlign.Center)
            .borderRadius(17)
            .backgroundColor(this.chromeChipBg())
            .margin({ right: 8 })
            .onClick((): void => { this.toggleSshOrientation(); })
          }
          Row() {
            SymbolGlyph($r('sys.symbol.doc'))
              .fontSize(18)
              .fontColor(['rgba(242,244,247,0.86)'])
          }
          .width(34)
          .height(34)
          .justifyContent(FlexAlign.Center)
          .borderRadius(17)
          .backgroundColor(this.chromeChipBg())
          .margin({ right: 8 })
          .onClick((): void => { this.openSftpPanel(); })

        }
        Row() {
          Column().width(8).height(8).borderRadius(4)
            .backgroundColor(this.connectionDotColor())
            .shadow({ radius: 8, color: this.connectionDotColor() + '66', offsetY: 0 })
          Text(this.connectionLabel())
            .fontSize(11).fontColor('rgba(242,244,247,0.70)').margin({ left: 6 })
        }
        .height(34)
        .padding({ left: 10, right: 12 })
        .borderRadius(17)
        .backgroundColor(this.chromeChipBg())
      }
      .width('100%')
      .height(this.headerHeight())
      .padding({ left: 10, right: 16, top: 6 + this.topChromeOffset(), bottom: 6 })
      .backgroundColor(this.chromeBg())
      .backgroundBlurStyle(BlurStyle.NONE)
      .linearGradient({
        direction: GradientDirection.Bottom,
        colors: [['rgba(255,255,255,0.09)', 0], ['rgba(255,255,255,0.00)', 1]]
      })

      // 加载/错误态
      if (!this.connected) {
        Column() {
          if (this.connecting) {
            LoadingProgress().width(32).height(32).color(this.accentColor)
            Text('Connecting...').fontSize(13).fontColor('#888').margin({ top: 10 })
          } else {
            Text(this.connectionError).fontSize(14).fontColor('#FF6B6B')
            Button('返回').margin({ top: 16 }).backgroundColor(this.accentColor).fontColor('#FFFFFF').borderRadius(8)
              .onClick(() => { router.back(); })
          }
        }.width('100%').layoutWeight(1).justifyContent(FlexAlign.Center).backgroundColor('#0D0D0D')
      } else {
        Stack({ alignContent: Alignment.TopStart }) {
          // 终端内容顶部对齐, 虚拟键栏通过 position 绝对定位在底部
          Stack({ alignContent: Alignment.TopStart }) {
            if (this.useNativeTerminalCore) {
              NativeTerminalRenderer({
                cols: this.termCols,
                rows: this.termRows,
                viewportWidth: this.termAreaW,
                cellWvp: this.cellWvp,
                cellHvp: this.cellHvp,
                fontSize: this.renderFontVp,
                viewportHeight: this.terminalPaneHeight(),
                visibleViewportHeight: this.terminalRowsViewportHeight(),
                inputData: this.termOutput,
                selectMode: this.selectMode,
                bottomAlignSparseContent: !this.isDesktopDevice,
                copyRequest: this.copyRequest,
                copiedText: this.copiedText,
                scrollToBottomRequest: this.scrollToBottomRequest,
                forceScrollToBottomRequest: this.forceScrollToBottomRequest,
                externalScrollLines: this.terminalExternalScrollLines,
                externalScrollRequest: this.terminalExternalScrollRequest,
                onData: (data: string): void => { this.onTerminalData(data); }
              })
            } else {
              TerminalEmulator({
                cols: this.termCols,
                rows: this.termRows,
                viewportWidth: this.termAreaW,
                cellWvp: this.cellWvp,
                cellHvp: this.cellHvp,
                fontSize: this.renderFontVp,
                viewportHeight: this.terminalPaneHeight(),
                visibleViewportHeight: this.terminalRowsViewportHeight(),
                inputData: this.termOutput,
                selectMode: this.selectMode,
                bottomAlignSparseContent: !this.isDesktopDevice,
                copyRequest: this.copyRequest,
                copiedText: this.copiedText,
                scrollToBottomRequest: this.scrollToBottomRequest,
                forceScrollToBottomRequest: this.forceScrollToBottomRequest,
                externalScrollLines: this.terminalExternalScrollLines,
                externalScrollRequest: this.terminalExternalScrollRequest,
                onData: (data: string): void => { this.onTerminalData(data); }
              })
            }

            // 隐藏 TextInput — 1×1 可点击, 软键盘锚点
            TextInput({ text: this.kbInput, controller: this.kbCtrl })
              .id('sshKbInput')
              // Treat terminal input like a username: IMEs normally start in
              // lowercase, while explicit Shift/Caps Lock remains available.
              // Never lowercase command text in the app because shells are
              // case-sensitive.
              .type(InputType.USER_NAME)
              .enableAutoFill(false)
              .fontSize(this.renderFontVp)
              .fontColor('#00000000').fontFamily('monospace')
              .backgroundColor('#00000000')
              .caretColor('#00000000')
              .border({ width: 0 })
              .width(1).height(1)
              .hitTestBehavior(HitTestMode.Transparent)  // 透明命中, 不拦截父 onClick
              .defaultFocus(this.isDesktopDevice)
              .focusOnTouch(true)
              .enableKeyboardOnFocus(true)
              .autoCapitalizationMode(AutoCapitalizationMode.NONE)
              .enterKeyType(EnterKeyType.Send)
              .copyOption(CopyOptions.None)
              .selectionMenuHidden(true)
              .onWillInsert((info: InsertValue): boolean => {
                return this.handleSoftInsert(info);
              })
              .onWillDelete((info: DeleteValue): boolean => {
                return this.handleSoftDelete(info);
              })
              .onChange((v: string): void => {
                this.handleChangeGuard(v);
              })
              .onSubmit((_enterKey: EnterKeyType, event: SubmitEvent): void => {
                this.onTerminalData('\r');
                this.resetKeyboardBuffer();
                // HarmonyOS 非 TV 设备默认会在提交后失焦并收起软键盘。
                // SSH 终端需要连续输入命令, 保持隐藏输入框的编辑态。
                event.keepEditableState();
                setTimeout((): void => { this.focusKeyboard(); }, 30);
              })
              .onPaste((content: string): void => {
                this.handlePaste(content);
              })
              .onKeyPreIme((event: KeyEvent): boolean => {
                // 仅 KeyType.Down (=0); ArkUI KeyType 枚举: Down=0 Up=1 LongPress=2
                if (event.type !== KeyType.Down) { return false; }
                const code: number = event.keyCode;
                const ctrl: boolean = event.getModifierKeyState ? event.getModifierKeyState(['Ctrl']) : false;
                const alt: boolean = event.getModifierKeyState ? event.getModifierKeyState(['Alt']) : false;
                const shift: boolean = event.getModifierKeyState ? event.getModifierKeyState(['Shift']) : false;
                // PC 退出快捷键: Ctrl+Shift+Q
                if (this.isDesktopDevice && code === KeyCode.KEYCODE_Q && ctrl && shift) {
                  router.back();
                  return true;
                }
                const encoded: SshEncodedKey = encodePhysicalKey({
                  keyCode: code,
                  unicode: event.unicode,
                  ctrl: ctrl || this.ctrlActive,
                  alt: alt || this.altActive,
                  shift: shift || this.shiftActive
                });
                if (encoded.consume) {
                  this.sendTerminalBytes(encoded.sequence);
                  if (encoded.refocusAfterTab && this.isDesktopDevice) {
                    setTimeout((): void => { this.focusKeyboard(); }, 16);
                  }
                  return true;
                }
                return false;  // 普通字符放行 → IME → onChange
              })
          }
          .width('100%')
          .height(this.terminalPaneHeight())
          .position({ x: 0, y: this.terminalCanvasOffsetY() })
          .onClick(() => {
            // 手机/平板: 点终端区呼出软键盘
            if (!this.isDesktopDevice) {
              this.focusKeyboard();
            }
          })
          .onAreaChange((_o: Area, n: Area): void => {
            const h: number = n.height as number;
            const w: number = n.width as number;
            const position: string = JSON.stringify(n.position) ?? '';
            const globalPosition: string = JSON.stringify(n.globalPosition) ?? '';
            const sizeChanged: boolean = Math.abs(h - this.termAreaH) >= 1 || Math.abs(w - this.termAreaW) >= 1;
            const positionChanged: boolean = position !== this.lastTermAreaPosition;
            if (!sizeChanged && !positionChanged) { return; }
            this.lastTermAreaPosition = position;
            this.termAreaH = h;
            this.termAreaW = w;
            hilog.info(0x0000, 'SshTerminal',
              `[areaDiag] term size=${w}x${h} position=${position} global=${globalPosition} ` +
              `offset=${this.terminalCanvasOffsetY()} transition=${this.orientationTransitioning}`);
            this.recalcGrid();
            if (positionChanged) {
              this.forceScrollToBottomRequest = this.forceScrollToBottomRequest + 1;
            }
            if (this.orientationTransitioning) {
              this.scheduleOrientationSettle();
            } else if (!this.isDesktopDevice && this.connected) {
              this.requestTerminalScrollToBottomSettled();
            }
          })
          .bindContextMenu(this.TermMenu(), ResponseType.LongPress)

          if (!this.selectMode) {
            Stack() {
              Text(' ')
                .width('100%')
                .height('100%')
                .fontSize(1)
                .fontColor('rgba(0,0,0,0.01)')
            }
            .width('100%')
            .height(this.terminalPaneHeight())
            .position({ x: 0, y: this.terminalCanvasOffsetY() })
            .backgroundColor('rgba(0,0,0,0.01)')
            .zIndex(10)
            .hitTestBehavior(HitTestMode.Block)
            .gesture(
              GestureGroup(GestureMode.Exclusive,
                TapGesture({ count: 1 })
                  .onAction((): void => {
                    if (!this.isDesktopDevice) {
                      this.focusKeyboard();
                    }
                  }),
                PanGesture({ direction: PanDirection.Vertical, distance: 2 })
                  .onActionStart((event: GestureEvent): void => {
                    this.handleTerminalPanStart(event);
                  })
                  .onActionUpdate((event: GestureEvent): void => {
                    this.handleTerminalPanUpdate(event);
                  })
                  .onActionEnd((): void => {
                    this.handleTerminalPanEnd();
                  })
                  .onActionCancel((): void => {
                    this.handleTerminalPanEnd();
                  })
              )
            )
            .bindContextMenu(this.TermMenu(), ResponseType.LongPress)
          }

          // 虚拟键盘栏 — 仅手机/平板, 悬浮到系统键盘或导航栏上边缘。
          if (!this.isDesktopDevice) {
            Column() {
              VirtualKeyBar({
                ctrlActive: $ctrlActive,
                altActive: $altActive,
                shiftActive: $shiftActive,
                onKey: (seq: string): void => { this.onTerminalData(seq); },
                onModifierLock: (modifier: string): void => { this.setVirtualModifier(modifier, true); },
                onModifierUnlock: (modifier: string): void => { this.setVirtualModifier(modifier, false); },
                onModifierTap: (): void => {
                  setTimeout((): void => { this.focusKeyboard(); }, 30);
                }
              })
            }
            .width('100%')
            .height(VirtualKeyBar.TOTAL_H)
            .position({ x: 0, y: this.barTop() })
            .zIndex(20)
            .hitTestBehavior(HitTestMode.Default)
          }
        }
        .layoutWeight(1)
        .width('100%')
        .clip(true)
        .onAreaChange((_o: Area, n: Area): void => {
          const h: number = n.height as number;
          const w: number = n.width as number;
          const position: string = JSON.stringify(n.position) ?? '';
          const globalPosition: string = JSON.stringify(n.globalPosition) ?? '';
          const sizeChanged: boolean = Math.abs(h - this.shellAreaH) >= 1 || Math.abs(w - this.shellAreaW) >= 1;
          const positionChanged: boolean = position !== this.lastShellAreaPosition;
          if (!sizeChanged && !positionChanged) { return; }
          this.lastShellAreaPosition = position;
          this.shellAreaH = h;
          this.shellAreaW = w;
          hilog.info(0x0000, 'SshTerminal',
            `[areaDiag] shell size=${w}x${h} position=${position} global=${globalPosition} ` +
            `transition=${this.orientationTransitioning}`);
          this.recalcGrid();
          if (positionChanged) {
            this.forceScrollToBottomRequest = this.forceScrollToBottomRequest + 1;
          }
          if (this.orientationTransitioning) {
            this.scheduleOrientationSettle();
          } else if (!this.isDesktopDevice && this.connected) {
            this.requestTerminalScrollToBottomSettled();
          }
        })
      }
    }
    .width('100%').height('100%').backgroundColor('#0D0D0D')
    .bindSheet($$this.showPassphraseSheet, this.passphraseSheet(), {
      height: SheetSize.FIT_CONTENT,
      preferType: this.isDesktopDevice ? SheetType.CENTER : SheetType.BOTTOM,
      dragBar: !this.isDesktopDevice,
      backgroundColor: Color.Transparent,
      blurStyle: BlurStyle.NONE,
      showClose: false,
      maskColor: 'rgba(0,0,0,0.4)',
      onDisappear: (): void => {
        if (this.passphraseResolve) {
          this.passphraseResolve('');
          this.passphraseResolve = null;
        }
      }
    })
    .bindSheet($$this.showSftpPanel, this.SftpTransferSheet(), {
      height: this.sftpSheetHeight(),
      preferType: this.isDesktopDevice ? SheetType.CENTER : SheetType.BOTTOM,
      dragBar: !this.isDesktopDevice,
      backgroundColor: Color.Transparent,
      blurStyle: BlurStyle.NONE,
      showClose: false,
      onWillDismiss: (action: DismissSheetAction): void => { this.handleSftpSheetDismiss(action); }
    })
  }
}
