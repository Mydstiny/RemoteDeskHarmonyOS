/**
 * SshXtermSurface — mature xterm.js terminal frontend for SSH.
 *
 * The visible terminal is an ArkWeb page backed by xterm.js + CanvasAddon.
 * ArkUI only owns the lifecycle/bridge shell; it does not parse VT bytes or
 * draw terminal cells. Output is kept in a small ordinary FIFO so a Web page
 * navigation cannot reorder or silently discard SSH output.
 */
import { webview } from '@kit.ArkWeb';
import { hilog } from '@kit.PerformanceAnalysisKit';

const XTERM_DOMAIN: number = 0x0000;
const XTERM_TAG: string = 'SshXtermSurface';

/** Decoded SSH output waiting for the visible xterm page to consume it. */
export class XtermOutputBuffer {
  private pending: Array<string> = [];

  enqueue(value: string): void {
    if (value.length > 0) { this.pending.push(value); }
  }

  drain(): Array<string> {
    const values: Array<string> = this.pending;
    this.pending = [];
    return values;
  }

  clear(): void {
    this.pending = [];
  }

  size(): number {
    return this.pending.length;
  }
}

class SshXtermBridgeProxy {
  onReadyCallback: (cols: number, rows: number) => void = (_cols: number, _rows: number): void => {};
  onInputCallback: (data: string) => void = (_data: string): void => {};
  onResizeCallback: (cols: number, rows: number) => void = (_cols: number, _rows: number): void => {};
  onSelectionCallback: (text: string) => void = (_text: string): void => {};
  onFocusCallback: (focused: boolean) => void = (_focused: boolean): void => {};

  onReady(cols: number, rows: number): void {
    this.onReadyCallback(cols, rows);
  }

  onInput(data: string): void {
    this.onInputCallback(data);
  }

  onResize(cols: number, rows: number): void {
    this.onResizeCallback(cols, rows);
  }

  onSelection(text: string): void {
    this.onSelectionCallback(text);
  }

  onFocus(focused: boolean): void {
    this.onFocusCallback(focused);
  }
}

@Component
export struct SshXtermSurface {
  @Prop @Watch('onCoreKeyChange') coreKey: string = '';
  @Prop @Watch('onViewportChange') viewportWidth: number = 0;
  @Prop @Watch('onViewportChange') viewportHeight: number = 0;
  @Prop cols: number = 80;
  @Prop rows: number = 24;
  @Prop @Watch('onFontChange') fontSize: number = 18;
  @Prop @Watch('onLineSpacingChange') lineSpacing: number = 1.12;
  @Prop @Watch('onAppearanceChange') bottomAlignSparseContent: boolean = false;
  @StorageProp('sshTerminalForegroundColor') @Watch('onAppearanceChange') terminalFgColor: string = '#33FF33';
  @Prop @Watch('onOutputSequenceChange') outputSequence: number = 0;
  @Prop @Watch('onFocusRequest') focusRequest: number = 0;
  @Prop @Watch('onCopyRequest') copyRequest: number = 0;
  @Prop @Watch('onScrollToBottomRequest') scrollToBottomRequest: number = 0;
  @Prop @Watch('onForceScrollToBottomRequest') forceScrollToBottomRequest: number = 0;
  @Prop @Watch('onExternalScrollRequest') externalScrollRequest: number = 0;
  @Prop externalScrollLines: number = 0;
  /** Ordinary reference: it is deliberately outside ArkUI observation. */
  outputBuffer: XtermOutputBuffer = new XtermOutputBuffer();
  @Link copiedText: string;
  onData?: (data: string, surfaceKey: string) => void;
  onResize?: (cols: number, rows: number, surfaceKey: string) => void;
  onReady?: (surfaceKey: string) => void;

  private controller: webview.WebviewController = new webview.WebviewController();
  private bridge: SshXtermBridgeProxy = new SshXtermBridgeProxy();
  private bridgeRegistered: boolean = false;
  private bridgeRetryTimer: number = -1;
  private bridgeRetryCount: number = 0;
  private bridgeCleanupTimer: number = -1;
  private pageFinished: boolean = false;
  private pageReady: boolean = false;
  private readyReported: boolean = false;
  private pendingCoreReset: boolean = false;
  /** A host switch must finish a new document boot before consuming output. */
  private documentReloadPending: boolean = false;
  private outputPumpRunning: boolean = false;
  private outputPumpRetryTimer: number = -1;
  private fitTimer: number = -1;
  private pendingWrites: Array<string> = [];
  private disposed: boolean = false;
  private lifecycleToken: number = 0;

  aboutToAppear(): void {
    const lifecycleToken: number = ++this.lifecycleToken;
    this.disposed = false;
    if (this.bridgeCleanupTimer !== -1) {
      clearTimeout(this.bridgeCleanupTimer);
      this.bridgeCleanupTimer = -1;
    }
    // A reused WebView may have navigated to a new document while the old
    // proxy registration was still present. Rebind it for this page.
    this.bridgeRegistered = false;
    this.clearBridgeRetry();
    this.bridgeRetryCount = 0;
    this.pageFinished = false;
    this.pageReady = false;
    this.readyReported = false;
    this.pendingCoreReset = false;
    this.documentReloadPending = false;
    this.installBridgeCallbacks(lifecycleToken);
    // The first attempt may run before Web is bound; onPageBegin retries after
    // the controller is attached to the component.
    this.registerBridge();
  }

  aboutToDisappear(): void {
    const lifecycleToken: number = ++this.lifecycleToken;
    this.disposed = true;
    this.clearBridgeRetry();
    this.bridgeRetryCount = 0;
    this.pageFinished = false;
    this.pageReady = false;
    this.pendingCoreReset = false;
    this.documentReloadPending = false;
    this.pendingWrites = [];
    this.outputPumpRunning = false;
    if (this.outputPumpRetryTimer !== -1) {
      clearTimeout(this.outputPumpRetryTimer);
      this.outputPumpRetryTimer = -1;
    }
    if (this.fitTimer !== -1) {
      clearTimeout(this.fitTimer);
      this.fitTimer = -1;
    }
    // Route replacement can overlap the old and new Web components. Delay
    // deletion so an old page cannot remove a bridge just registered by the
    // replacement component/controller, and skip cleanup if this component is
    // immediately reused for the next host.
    if (this.bridgeRegistered) {
      this.bridgeCleanupTimer = setTimeout((): void => {
        this.bridgeCleanupTimer = -1;
        if (lifecycleToken !== this.lifecycleToken || !this.disposed || !this.bridgeRegistered) {
          return;
        }
        try { this.controller.deleteJavaScriptRegister('sshTerminalBridge'); } catch (_err) {
          // The Web page may already have been destroyed.
        }
        this.bridgeRegistered = false;
      }, 250);
    }
  }

  private installBridgeCallbacks(lifecycleToken: number): void {
    this.bridge.onReadyCallback = (cols: number, rows: number): void => {
      if (lifecycleToken !== this.lifecycleToken) { return; }
      this.handlePageReady(cols, rows);
    };
    this.bridge.onInputCallback = (data: string): void => {
      if (lifecycleToken === this.lifecycleToken && this.onData && data.length > 0 && !this.disposed) {
        this.onData(data, this.coreKey);
      }
    };
    this.bridge.onResizeCallback = (cols: number, rows: number): void => {
      if (lifecycleToken === this.lifecycleToken && this.onResize && !this.disposed) {
        this.onResize(cols, rows, this.coreKey);
      }
    };
    this.bridge.onSelectionCallback = (_text: string): void => {};
    this.bridge.onFocusCallback = (_focused: boolean): void => {};
  }

  private clearBridgeRetry(): void {
    if (this.bridgeRetryTimer !== -1) {
      clearTimeout(this.bridgeRetryTimer);
      this.bridgeRetryTimer = -1;
    }
  }

  private scheduleBridgeRetry(lifecycleToken: number): void {
    if (this.bridgeRetryTimer !== -1 || this.disposed || lifecycleToken !== this.lifecycleToken) {
      return;
    }
    // ArkWeb can bind the WebviewController after onPageBegin during route
    // replacement. Keep retrying for a bounded window tied to this page.
    if (this.bridgeRetryCount >= 180) {
      hilog.warn(XTERM_DOMAIN, XTERM_TAG, 'register bridge retry limit reached');
      return;
    }
    this.bridgeRetryCount++;
    this.bridgeRetryTimer = setTimeout((): void => {
      this.bridgeRetryTimer = -1;
      if (lifecycleToken === this.lifecycleToken) {
        this.registerBridge(lifecycleToken);
      }
    }, 32);
  }

  private registerBridge(lifecycleToken: number = this.lifecycleToken): void {
    if (lifecycleToken !== this.lifecycleToken || this.bridgeRegistered || this.disposed) { return; }
    try {
      this.controller.registerJavaScriptProxy(
        this.bridge,
        'sshTerminalBridge',
        ['onReady', 'onInput', 'onResize', 'onSelection', 'onFocus']
      );
      this.bridgeRegistered = true;
      this.bridgeRetryCount = 0;
      this.clearBridgeRetry();
    } catch (err) {
      this.scheduleBridgeRetry(lifecycleToken);
      hilog.debug(XTERM_DOMAIN, XTERM_TAG,
        'register bridge deferred: ' + JSON.stringify(err));
    }
  }

  private pageConfigScript(): string {
    const requestedFontSize: number = Number(this.fontSize);
    const normalizedFontSize: number = Number.isFinite(requestedFontSize)
      ? Math.max(12, Math.min(32, requestedFontSize)) : 18;
    const requestedLineSpacing: number = Number(this.lineSpacing);
    const normalizedLineSpacing: number = Number.isFinite(requestedLineSpacing)
      ? Math.max(1, Math.min(1.6, requestedLineSpacing)) : 1.12;
    const config: string = JSON.stringify({
      cols: Math.max(20, Math.floor(this.cols)),
      rows: Math.max(3, Math.floor(this.rows)),
      fontSize: normalizedFontSize,
      lineHeight: normalizedLineSpacing,
      fontFamily: 'monospace',
      foreground: this.terminalFgColor,
      background: '#0D0D0D',
      bottomAlignSparseContent: this.bottomAlignSparseContent
    });
    return 'window.__sshXtermConfigure(' + config + ');';
  }

  private runPageScript(script: string, onFailure?: () => void): void {
    if (this.disposed || !this.pageFinished) { return; }
    try {
      this.controller.runJavaScript(script).then((): void => {}).catch((_err: Error): void => {
        if (onFailure) { onFailure(); }
      });
    } catch (_err) {
      if (onFailure) { onFailure(); }
    }
  }

  private handlePageReady(cols: number, rows: number): void {
    if (this.disposed) { return; }
    this.pageReady = true;
    this.documentReloadPending = false;
    this.reportReadyOnce();
    this.runPageScript(this.pageConfigScript());
    this.flushOutputBuffer();
    // onPageEnd can queue output before xterm has called onReady. Starting
    // the pump again here releases that first prompt and preserves ordering.
    this.pumpOutput();
    if (this.onResize && cols > 0 && rows > 0) {
      this.onResize(cols, rows, this.coreKey);
    }
  }

  private reportReadyOnce(): void {
    if (this.readyReported) { return; }
    this.readyReported = true;
    if (this.onReady) { this.onReady(this.coreKey); }
  }

  private handlePageEnd(): void {
    this.pageFinished = true;
    this.registerBridge();
    if (this.pendingCoreReset) {
      this.pendingCoreReset = false;
      this.runPageScript('window.__sshXtermReset();');
    }
    // Page end only means that the document loaded. The xterm callback is the
    // readiness gate; otherwise output can be sent into a page whose terminal
    // renderer failed to boot and the native side would show only a caret.
    this.runPageScript(this.pageConfigScript());
    this.flushOutputBuffer();
  }

  /**
   * Recreate the ArkWeb document for a same-page SSH tab switch.
   *
   * A reset is insufficient here: ArkWeb can retain the old xterm DOM while
   * ArkUI batches the host/state update. Loading the rawfile gives the new
   * host a new JS heap, bridge registration and xterm buffer. Output remains
   * in the parent-owned XtermOutputBuffer until the new document reports ready.
   */
  private reloadDocumentForCoreKey(): void {
    if (this.disposed) { return; }
    const lifecycleToken: number = ++this.lifecycleToken;
    this.clearBridgeRetry();
    if (this.outputPumpRetryTimer !== -1) {
      clearTimeout(this.outputPumpRetryTimer);
      this.outputPumpRetryTimer = -1;
    }
    if (this.fitTimer !== -1) {
      clearTimeout(this.fitTimer);
      this.fitTimer = -1;
    }
    this.pendingWrites = [];
    this.outputPumpRunning = false;
    this.bridgeRegistered = false;
    this.pageFinished = false;
    this.pageReady = false;
    this.readyReported = false;
    this.pendingCoreReset = false;
    this.documentReloadPending = true;
    this.installBridgeCallbacks(lifecycleToken);
    try { this.controller.deleteJavaScriptRegister('sshTerminalBridge'); } catch (_err) {
      // The old document may already have been detached.
    }
    try {
      this.controller.loadUrl($rawfile('ssh-terminal/index.html'));
    } catch (err) {
      hilog.warn(XTERM_DOMAIN, XTERM_TAG,
        'reload xterm document failed: ' + JSON.stringify(err));
      this.documentReloadPending = false;
      this.pageFinished = true;
      this.registerBridge(lifecycleToken);
    }
  }

  private enqueueOutput(): void {
    const values: Array<string> = this.outputBuffer.drain();
    if (values.length === 0) { return; }
    for (let index = 0; index < values.length; index++) {
      this.pendingWrites.push(values[index]);
    }
    this.pumpOutput();
  }

  private flushOutputBuffer(): void {
    this.enqueueOutput();
  }

  private pumpOutput(): void {
    if (this.outputPumpRunning || !this.pageReady || !this.pageFinished || this.disposed) { return; }
    if (this.pendingWrites.length === 0) { return; }
    const lifecycleToken: number = this.lifecycleToken;
    this.outputPumpRunning = true;
    const batch: Array<string> = [];
    let batchLength: number = 0;
    while (this.pendingWrites.length > 0 && batch.length < 8) {
      const next: string = this.pendingWrites[0];
      // Keep a bridge call below one frame-sized payload while allowing a
      // single oversized SSH chunk to pass through without being truncated.
      if (batch.length > 0 && batchLength + next.length > 65536) { break; }
      batch.push(this.pendingWrites.shift() as string);
      batchLength += next.length;
    }
    const script: string = 'window.__sshXtermWriteBatch(' + JSON.stringify(batch) + ');';
    try {
      this.controller.runJavaScript(script).then((): void => {
        if (lifecycleToken !== this.lifecycleToken) { return; }
        this.outputPumpRunning = false;
        this.pumpOutput();
      }).catch((_err: Error): void => {
        if (lifecycleToken !== this.lifecycleToken) { return; }
        // Keep the whole batch for a page re-entry instead of silently losing
        // an ordered portion of the terminal transcript.
        for (let index: number = batch.length - 1; index >= 0; index--) {
          this.pendingWrites.unshift(batch[index]);
        }
        this.outputPumpRunning = false;
        this.scheduleOutputPumpRetry(lifecycleToken);
      });
    } catch (_err) {
      if (lifecycleToken !== this.lifecycleToken) { return; }
      for (let index: number = batch.length - 1; index >= 0; index--) {
        this.pendingWrites.unshift(batch[index]);
      }
      this.outputPumpRunning = false;
      this.scheduleOutputPumpRetry(lifecycleToken);
    }
  }

  private scheduleOutputPumpRetry(lifecycleToken: number): void {
    if (this.outputPumpRetryTimer !== -1 || this.disposed) { return; }
    this.outputPumpRetryTimer = setTimeout((): void => {
      this.outputPumpRetryTimer = -1;
      if (lifecycleToken === this.lifecycleToken) { this.pumpOutput(); }
    }, 48);
  }

  private onCoreKeyChange(): void {
    if (this.disposed) { return; }
    this.reloadDocumentForCoreKey();
  }

  private onViewportChange(): void {
    this.scheduleFit();
  }

  private scheduleFit(): void {
    if (this.disposed || this.fitTimer !== -1) { return; }
    this.fitTimer = setTimeout((): void => {
      this.fitTimer = -1;
      if (!this.disposed) { this.runPageScript('window.__sshXtermFit();'); }
    }, 64);
  }

  private onFontChange(): void {
    this.runPageScript(this.pageConfigScript());
  }

  private onLineSpacingChange(): void {
    this.runPageScript(this.pageConfigScript());
  }

  private onAppearanceChange(): void {
    this.runPageScript(this.pageConfigScript());
  }

  private onOutputSequenceChange(): void {
    if (this.documentReloadPending) { return; }
    this.flushOutputBuffer();
  }

  private onFocusRequest(): void {
    this.runPageScript('window.__sshXtermFocus();');
  }

  private onCopyRequest(): void {
    if (!this.pageReady || this.disposed) { return; }
    try {
      this.controller.runJavaScript('window.__sshXtermGetSelection();').then((result: string): void => {
        if (this.disposed) { return; }
        let selection: string = result ?? '';
        try {
          const decoded: Object = JSON.parse(selection) as Object;
          if (typeof decoded === 'string') { selection = decoded; }
        } catch (_err) {
          // ArkWeb versions differ: some return the raw string, others return
          // a JSON string literal. Both are accepted here.
        }
        this.copiedText = selection;
      }).catch((_err: Error): void => {});
    } catch (_err) { /* page is leaving */ }
  }

  private onScrollToBottomRequest(): void {
    this.runPageScript('window.__sshXtermScrollToBottom();');
  }

  private onForceScrollToBottomRequest(): void {
    this.runPageScript('window.__sshXtermScrollToBottom();');
  }

  private onExternalScrollRequest(): void {
    if (this.externalScrollLines === 0) { return; }
    this.runPageScript('window.__sshXtermScrollLines(' + this.externalScrollLines.toString() + ');');
  }

  build() {
    Web({
      src: $rawfile('ssh-terminal/index.html'),
      controller: this.controller
    })
      // Give ArkUI a distinct native view identity for every SSH binding. The
      // explicit reload below handles a reused component; this id handles the
      // coalesced true -> false -> true update during a fast tab switch.
      .id('ssh-xterm-' + this.coreKey)
      .javaScriptAccess(true)
      // The page and its vendored xterm assets are bundled rawfiles. ArkWeb
      // needs local file access enabled to resolve the relative vendor URLs.
      .fileAccess(true)
      .domStorageAccess(false)
      .onPageBegin((): void => { this.registerBridge(); })
      .onPageEnd((): void => { this.handlePageEnd(); })
      .onAreaChange((_oldArea: Area, _newArea: Area): void => {
        this.scheduleFit();
      })
      .width('100%')
      .height('100%')
      .backgroundColor('#0D0D0D');
  }
}
