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
const XTERM_DOCUMENT_RELOAD_TIMEOUT_MS: number = 3000;

/** Decoded SSH output waiting for the visible xterm page to consume it. */
export class XtermOutputBuffer {
  private pending: Array<string> = [];

  enqueue(value: string): void {
    if (value.length > 0) { this.pending.push(value); }
  }

  prepend(values: Array<string>): void {
    if (values.length > 0) { this.pending = values.concat(this.pending); }
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
  onFrameCallback: (batchSequence: number) => void = (_batchSequence: number): void => {};
  onFrameErrorCallback: (batchSequence: number, consumedCount: number) => void =
    (_batchSequence: number, _consumedCount: number): void => {};
  onInputCallback: (data: string) => void = (_data: string): void => {};
  onResizeCallback: (cols: number, rows: number) => void = (_cols: number, _rows: number): void => {};
  onSelectionCallback: (text: string) => void = (_text: string): void => {};
  onFocusCallback: (focused: boolean) => void = (_focused: boolean): void => {};

  onReady(cols: number, rows: number): void {
    this.onReadyCallback(cols, rows);
  }

  onFrame(batchSequence: number): void {
    this.onFrameCallback(batchSequence);
  }

  onFrameError(batchSequence: number, consumedCount: number): void {
    this.onFrameErrorCallback(batchSequence, consumedCount);
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
  /** Explicit page-owned revision; survives a reused Web component instance. */
  @Prop @Watch('onRenderRevisionChange') renderRevision: number = 0;
  /** Parent-owned repaint fence for a quiet retained host session. */
  @Prop @Watch('onSurfaceRefreshRequestChange') surfaceRefreshRequest: number = 0;
  /** The WebView remains mounted while SSH rebinding; inactive pages keep output queued. */
  @Prop @Watch('onActiveChange') active: boolean = true;
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
  private pendingCoreKeyReload: boolean = false;
  /** Prevent two prop watchers from loading the same document revision twice. */
  private reloadRequestedDocumentKey: string = '';
  /** A host switch must finish a new document boot before consuming output. */
  private documentReloadPending: boolean = false;
  private outputPumpRunning: boolean = false;
  private outputPumpRetryTimer: number = -1;
  private outputBatchAckTimer: number = -1;
  private fitTimer: number = -1;
  private readyReportTimer: number = -1;
  private pageConfigRetryTimer: number = -1;
  private pageConfigRetryCount: number = 0;
  private documentReloadRetryTimer: number = -1;
  private documentReloadRetryCount: number = 0;
  private documentReloadWatchdogTimer: number = -1;
  private outputBatchSequence: number = 0;
  private awaitingOutputBatch: number = 0;
  private pendingWrites: Array<string> = [];
  private inFlightWrites: Array<string> = [];
  private inFlightOutputBuffer: XtermOutputBuffer | null = null;
  private pendingOutputBuffer: XtermOutputBuffer | null = null;
  private disposed: boolean = false;
  private lifecycleToken: number = 0;

  aboutToAppear(): void {
    this.restoreQueuedWrites();
    const lifecycleToken: number = ++this.lifecycleToken;
    this.disposed = false;
    if (this.readyReportTimer !== -1) {
      clearTimeout(this.readyReportTimer);
      this.readyReportTimer = -1;
    }
    this.clearPageConfigRetry();
    this.pageConfigRetryCount = 0;
    this.clearDocumentReloadRetry();
    this.documentReloadRetryCount = 0;
    // ArkUI can reuse this component instance for the next SSH tab before the
    // delayed disappear cleanup runs. Remove the previous proxy first; leaving
    // it registered makes every new document miss onReady and show only its
    // initial cursor/input anchor.
    if (this.bridgeCleanupTimer !== -1) {
      clearTimeout(this.bridgeCleanupTimer);
      this.bridgeCleanupTimer = -1;
    }
    if (this.bridgeRegistered) {
      try { this.controller.deleteJavaScriptRegister('sshTerminalBridge'); } catch (_err) {
        // The previous document may already have been destroyed.
      }
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
    this.pendingCoreKeyReload = false;
    this.reloadRequestedDocumentKey = '';
    this.documentReloadPending = false;
    this.awaitingOutputBatch = 0;
    // Give every document its own proxy. A late callback from the previous
    // document must not satisfy the readiness gate of the new host.
    this.bridge = new SshXtermBridgeProxy();
    this.installBridgeCallbacks(lifecycleToken);
    // The first attempt may run before Web is bound; onPageBegin retries after
    // the controller is attached to the component.
    this.registerBridge();
  }

  aboutToDisappear(): void {
    this.restoreQueuedWrites();
    const lifecycleToken: number = ++this.lifecycleToken;
    this.disposed = true;
    this.clearBridgeRetry();
    this.bridgeRetryCount = 0;
    this.pageFinished = false;
    this.pageReady = false;
    this.pendingCoreReset = false;
    this.pendingCoreKeyReload = false;
    this.reloadRequestedDocumentKey = '';
    this.documentReloadPending = false;
    this.pendingWrites = [];
    this.outputPumpRunning = false;
    this.awaitingOutputBatch = 0;
    if (this.outputPumpRetryTimer !== -1) {
      clearTimeout(this.outputPumpRetryTimer);
      this.outputPumpRetryTimer = -1;
    }
    if (this.fitTimer !== -1) {
      clearTimeout(this.fitTimer);
      this.fitTimer = -1;
    }
    if (this.readyReportTimer !== -1) {
      clearTimeout(this.readyReportTimer);
      this.readyReportTimer = -1;
    }
    this.clearPageConfigRetry();
    this.pageConfigRetryCount = 0;
    this.clearDocumentReloadRetry();
    this.documentReloadRetryCount = 0;
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
    this.bridge.onFrameCallback = (batchSequence: number): void => {
      if (lifecycleToken !== this.lifecycleToken || this.disposed) { return; }
      this.handleOutputFrame(batchSequence);
    };
    this.bridge.onFrameErrorCallback = (batchSequence: number, consumedCount: number): void => {
      if (lifecycleToken !== this.lifecycleToken || this.disposed) { return; }
      this.handleOutputFrameError(batchSequence, consumedCount);
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
    const retryDelay: number = this.bridgeRetryCount < 180 ? 32 : 250;
    this.bridgeRetryCount++;
    this.bridgeRetryTimer = setTimeout((): void => {
      this.bridgeRetryTimer = -1;
      if (lifecycleToken === this.lifecycleToken) {
        this.registerBridge(lifecycleToken);
      }
    }, retryDelay);
  }

  private registerBridge(lifecycleToken: number = this.lifecycleToken): void {
    if (lifecycleToken !== this.lifecycleToken || this.bridgeRegistered || this.disposed) { return; }
    try {
      this.controller.registerJavaScriptProxy(
        this.bridge,
        'sshTerminalBridge',
        ['onReady', 'onFrame', 'onFrameError', 'onInput', 'onResize', 'onSelection', 'onFocus']
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

  private runPageScript(script: string, onSuccess?: () => void, onFailure?: () => void): void {
    if (this.disposed || !this.pageFinished) { return; }
    try {
      this.controller.runJavaScript(script).then((): void => {
        if (onSuccess) { onSuccess(); }
      }).catch((_err: Error): void => {
        if (onFailure) { onFailure(); }
      });
    } catch (_err) {
      if (onFailure) { onFailure(); }
    }
  }

  private clearPageConfigRetry(): void {
    if (this.pageConfigRetryTimer !== -1) {
      clearTimeout(this.pageConfigRetryTimer);
      this.pageConfigRetryTimer = -1;
    }
  }

  private clearDocumentReloadRetry(): void {
    if (this.documentReloadRetryTimer !== -1) {
      clearTimeout(this.documentReloadRetryTimer);
      this.documentReloadRetryTimer = -1;
    }
    if (this.documentReloadWatchdogTimer !== -1) {
      clearTimeout(this.documentReloadWatchdogTimer);
      this.documentReloadWatchdogTimer = -1;
    }
  }

  private scheduleDocumentReloadWatchdog(lifecycleToken: number,
    requestedDocumentKey: string): void {
    if (this.documentReloadWatchdogTimer !== -1) {
      clearTimeout(this.documentReloadWatchdogTimer);
    }
    this.documentReloadWatchdogTimer = setTimeout((): void => {
      this.documentReloadWatchdogTimer = -1;
      if (lifecycleToken !== this.lifecycleToken || this.disposed ||
        !this.active || !this.documentReloadPending ||
        this.reloadRequestedDocumentKey !== requestedDocumentKey) {
        return;
      }
      hilog.warn(XTERM_DOMAIN, XTERM_TAG,
        'xterm document reload produced no ready callback, retrying');
      this.scheduleDocumentReloadRetry(lifecycleToken, requestedDocumentKey);
    }, XTERM_DOCUMENT_RELOAD_TIMEOUT_MS);
  }

  /** Start a fresh bridge for every reload attempt so an old document cannot
   * satisfy the new document's ready gate after a watchdog retry. */
  private restartDocumentReloadAttempt(requestedDocumentKey: string): void {
    if (this.disposed || !this.documentReloadPending ||
      !this.active || this.reloadRequestedDocumentKey !== requestedDocumentKey) {
      return;
    }
    const lifecycleToken: number = ++this.lifecycleToken;
    this.clearBridgeRetry();
    if (this.readyReportTimer !== -1) {
      clearTimeout(this.readyReportTimer);
      this.readyReportTimer = -1;
    }
    this.clearPageConfigRetry();
    this.pageConfigRetryCount = 0;
    this.clearDocumentReloadRetry();
    this.bridgeRegistered = false;
    this.pageFinished = false;
    this.pageReady = false;
    this.readyReported = false;
    try { this.controller.deleteJavaScriptRegister('sshTerminalBridge'); } catch (_err) {
      // The previous document may already have been detached.
    }
    this.bridge = new SshXtermBridgeProxy();
    this.installBridgeCallbacks(lifecycleToken);
    this.attemptDocumentReload(lifecycleToken, requestedDocumentKey);
  }

  private attemptDocumentReload(lifecycleToken: number, requestedDocumentKey: string): void {
    if (lifecycleToken !== this.lifecycleToken || this.disposed || !this.active ||
      !this.documentReloadPending || this.reloadRequestedDocumentKey !== requestedDocumentKey) {
      return;
    }
    try {
      this.controller.loadUrl($rawfile('ssh-terminal/index.html'));
      this.documentReloadRetryCount = 0;
      this.scheduleDocumentReloadWatchdog(lifecycleToken, requestedDocumentKey);
    } catch (err) {
      hilog.warn(XTERM_DOMAIN, XTERM_TAG,
        'reload xterm document failed: ' + JSON.stringify(err));
      // Keep the old document fenced off. Replaying the timeout batch into it
      // can duplicate output that was rendered before the ACK was lost.
      this.scheduleDocumentReloadRetry(lifecycleToken, requestedDocumentKey);
    }
  }

  private scheduleDocumentReloadRetry(lifecycleToken: number,
    requestedDocumentKey: string): void {
    if (this.documentReloadRetryTimer !== -1 || this.disposed ||
      lifecycleToken !== this.lifecycleToken || !this.active ||
      !this.documentReloadPending ||
      this.reloadRequestedDocumentKey !== requestedDocumentKey) {
      return;
    }
    const retryDelay: number = this.documentReloadRetryCount < 180 ? 64 : 250;
    this.documentReloadRetryCount++;
    this.documentReloadRetryTimer = setTimeout((): void => {
      this.documentReloadRetryTimer = -1;
      if (lifecycleToken !== this.lifecycleToken || this.disposed ||
        !this.active || !this.documentReloadPending ||
        this.reloadRequestedDocumentKey !== requestedDocumentKey) {
        return;
      }
      this.restartDocumentReloadAttempt(requestedDocumentKey);
    }, retryDelay);
  }

  private schedulePageConfigRetry(lifecycleToken: number): void {
    if (this.pageConfigRetryTimer !== -1 || this.disposed ||
      lifecycleToken !== this.lifecycleToken || !this.pageFinished) {
      return;
    }
    const retryDelay: number = this.pageConfigRetryCount < 180 ? 32 : 250;
    this.pageConfigRetryCount++;
    this.pageConfigRetryTimer = setTimeout((): void => {
      this.pageConfigRetryTimer = -1;
      if (lifecycleToken === this.lifecycleToken) {
        this.applyPageConfigAfterLoad(lifecycleToken);
      }
    }, retryDelay);
  }

  private applyPageConfigAfterLoad(lifecycleToken: number = this.lifecycleToken): void {
    if (this.disposed || lifecycleToken !== this.lifecycleToken || !this.pageFinished) {
      return;
    }
    this.runPageScript(this.pageConfigScript(), (): void => {
      if (lifecycleToken !== this.lifecycleToken || this.disposed) { return; }
      this.clearPageConfigRetry();
      this.pageConfigRetryCount = 0;
      this.flushOutputBuffer();
      this.maybeReportReady();
    }, (): void => {
      this.schedulePageConfigRetry(lifecycleToken);
    });
  }

  private handlePageReady(cols: number, rows: number): void {
    if (this.disposed) { return; }
    this.pageReady = true;
    this.documentReloadPending = false;
    this.reloadRequestedDocumentKey = '';
    this.clearDocumentReloadRetry();
    this.documentReloadRetryCount = 0;
    if (!this.active) { return; }
    if (this.pageFinished) {
      this.applyPageConfigAfterLoad();
    } else {
      // onPageEnd will apply the config and start the output pump after the
      // document is fully loaded. Keep the first frame masked until then.
      this.flushOutputBuffer();
    }
    if (this.onResize && cols > 0 && rows > 0) {
      this.onResize(cols, rows, this.coreKey);
    }
  }

  /**
   * Report visibility only after the first document has drained its retained
   * transcript. The extra UI turn lets xterm complete its asynchronous write
   * callback before the ArkUI loading mask is removed.
   */
  private maybeReportReady(): void {
    if (this.readyReported || this.disposed || !this.active || !this.pageReady ||
      !this.pageFinished) {
      return;
    }
    if (this.outputPumpRunning) { return; }
    if (this.pendingWrites.length > 0 || this.outputBuffer.size() > 0) {
      this.flushOutputBuffer();
      return;
    }
    if (this.readyReportTimer !== -1) { return; }
    const lifecycleToken: number = this.lifecycleToken;
    this.readyReportTimer = setTimeout((): void => {
      this.readyReportTimer = -1;
      if (lifecycleToken !== this.lifecycleToken || this.disposed || !this.active) {
        return;
      }
      if (this.outputPumpRunning || this.pendingWrites.length > 0 || this.outputBuffer.size() > 0) {
        this.flushOutputBuffer();
        return;
      }
      this.reportReadyOnce();
    }, 32);
  }

  private handleOutputFrame(batchSequence: number): void {
    const normalizedSequence: number = Math.floor(Number(batchSequence));
    if (!this.outputPumpRunning || normalizedSequence <= 0 ||
      normalizedSequence !== this.awaitingOutputBatch) {
      return;
    }
    this.clearOutputBatchAckTimer();
    this.inFlightWrites = [];
    this.inFlightOutputBuffer = null;
    this.awaitingOutputBatch = 0;
    this.outputPumpRunning = false;
    this.flushOutputBuffer();
    this.maybeReportReady();
  }

  /** Rebuild the document after a page-side xterm write error. */
  private handleOutputFrameError(batchSequence: number, consumedCount: number): void {
    const normalizedSequence: number = Math.floor(Number(batchSequence));
    if (!this.outputPumpRunning || normalizedSequence <= 0 ||
      normalizedSequence !== this.awaitingOutputBatch) {
      return;
    }
    const requestedConsumed: number = Number(consumedCount);
    const consumed: number = Number.isFinite(requestedConsumed)
      ? Math.max(0, Math.min(this.inFlightWrites.length, Math.floor(requestedConsumed))) : 0;
    // The error path rebuilds the document. Its new xterm buffer is empty, so
    // it must receive the complete in-flight batch, including the prefix that
    // already rendered in the failed document. Replaying only the suffix would
    // make the prefix disappear after reload.
    const replayBatch: Array<string> = this.inFlightWrites.slice();
    const inFlightTarget: XtermOutputBuffer = this.inFlightOutputBuffer ??
      this.pendingOutputBuffer ?? this.outputBuffer;
    const pendingTarget: XtermOutputBuffer = this.pendingOutputBuffer ??
      this.inFlightOutputBuffer ?? this.outputBuffer;
    if (inFlightTarget === pendingTarget) {
      inFlightTarget.prepend(replayBatch.concat(this.pendingWrites));
    } else {
      if (replayBatch.length > 0) { inFlightTarget.prepend(replayBatch); }
      if (this.pendingWrites.length > 0) { pendingTarget.prepend(this.pendingWrites); }
    }
    this.clearOutputBatchAckTimer();
    this.inFlightWrites = [];
    this.inFlightOutputBuffer = null;
    this.pendingWrites = [];
    this.pendingOutputBuffer = null;
    this.awaitingOutputBatch = 0;
    this.outputPumpRunning = false;
    hilog.warn(XTERM_DOMAIN, XTERM_TAG,
      'xterm output write failed, replaying batch=' + replayBatch.length.toString() +
      ' after consumed=' + consumed.toString());
    this.reloadDocumentForCoreKey();
  }

  private reportReadyOnce(): void {
    if (this.readyReported) { return; }
    this.readyReported = true;
    if (this.onReady) { this.onReady(this.coreKey); }
  }

  private handlePageEnd(): void {
    if (this.disposed) { return; }
    this.pageFinished = true;
    this.registerBridge();
    if (!this.active) { return; }
    if (this.pendingCoreReset) {
      this.pendingCoreReset = false;
      this.runPageScript('window.__sshXtermReset();');
    }
    // Page end only means that the document loaded. The xterm callback is the
    // readiness gate; otherwise output can be sent into a page whose terminal
    // renderer failed to boot and the native side would show only a caret.
    this.applyPageConfigAfterLoad();
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
    const requestedDocumentKey: string = this.coreKey + ':render:' +
      this.renderRevision.toString();
    if (this.documentReloadPending && this.reloadRequestedDocumentKey === requestedDocumentKey) {
      return;
    }
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
    if (this.readyReportTimer !== -1) {
      clearTimeout(this.readyReportTimer);
      this.readyReportTimer = -1;
    }
    this.clearPageConfigRetry();
    this.pageConfigRetryCount = 0;
    this.clearDocumentReloadRetry();
    this.documentReloadRetryCount = 0;
    this.restoreQueuedWrites();
    this.pendingWrites = [];
    this.outputPumpRunning = false;
    this.awaitingOutputBatch = 0;
    this.bridgeRegistered = false;
    this.pageFinished = false;
    this.pageReady = false;
    this.readyReported = false;
    this.pendingCoreReset = false;
    this.documentReloadPending = true;
    this.reloadRequestedDocumentKey = requestedDocumentKey;
    try { this.controller.deleteJavaScriptRegister('sshTerminalBridge'); } catch (_err) {
      // The old document may already have been detached.
    }
    // Do not reuse the proxy registered by the old document. ArkWeb can finish
    // dispatching one of its callbacks after loadUrl() has started.
    this.bridge = new SshXtermBridgeProxy();
    this.installBridgeCallbacks(lifecycleToken);
    this.attemptDocumentReload(lifecycleToken, requestedDocumentKey);
  }

  private clearOutputBatchAckTimer(): void {
    if (this.outputBatchAckTimer !== -1) {
      clearTimeout(this.outputBatchAckTimer);
      this.outputBatchAckTimer = -1;
    }
  }

  /** Return local queues before a document/lifecycle handoff can invalidate them. */
  private restoreQueuedWrites(): void {
    this.clearOutputBatchAckTimer();
    const inFlightTarget: XtermOutputBuffer = this.inFlightOutputBuffer ??
      this.pendingOutputBuffer ?? this.outputBuffer;
    const pendingTarget: XtermOutputBuffer = this.pendingOutputBuffer ??
      this.inFlightOutputBuffer ?? this.outputBuffer;
    if (this.inFlightWrites.length > 0 && this.pendingWrites.length > 0 &&
      inFlightTarget === pendingTarget) {
      inFlightTarget.prepend(this.inFlightWrites.concat(this.pendingWrites));
    } else {
      if (this.inFlightWrites.length > 0) { inFlightTarget.prepend(this.inFlightWrites); }
      if (this.pendingWrites.length > 0) { pendingTarget.prepend(this.pendingWrites); }
    }
    this.inFlightWrites = [];
    this.inFlightOutputBuffer = null;
    this.pendingWrites = [];
    this.pendingOutputBuffer = null;
    this.outputPumpRunning = false;
    this.awaitingOutputBatch = 0;
  }

  private scheduleOutputBatchAckTimeout(lifecycleToken: number, batchSequence: number): void {
    this.clearOutputBatchAckTimer();
    this.outputBatchAckTimer = setTimeout((): void => {
      this.outputBatchAckTimer = -1;
      if (lifecycleToken !== this.lifecycleToken || this.disposed ||
        this.awaitingOutputBatch !== batchSequence) {
        return;
      }
      hilog.warn(XTERM_DOMAIN, XTERM_TAG,
        'xterm output frame ack timeout, reloading document');
      this.restoreQueuedWrites();
      this.reloadDocumentForCoreKey();
    }, 640);
  }

  private enqueueOutput(): void {
    if (!this.active || this.disposed) { return; }
    const values: Array<string> = this.outputBuffer.drain();
    if (values.length === 0) { return; }
    if (this.pendingOutputBuffer === null) { this.pendingOutputBuffer = this.outputBuffer; }
    for (let index = 0; index < values.length; index++) {
      this.pendingWrites.push(values[index]);
    }
  }

  private flushOutputBuffer(): void {
    if (!this.active || this.disposed) { return; }
    this.enqueueOutput();
    this.pumpOutput();
  }

  private pumpOutput(): void {
    if (!this.active || this.outputPumpRunning || !this.pageReady || !this.pageFinished || this.disposed) { return; }
    if (this.pendingWrites.length === 0) {
      this.maybeReportReady();
      return;
    }
    const lifecycleToken: number = this.lifecycleToken;
    const batchSequence: number = ++this.outputBatchSequence;
    this.awaitingOutputBatch = batchSequence;
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
    this.inFlightWrites = batch;
    this.inFlightOutputBuffer = this.pendingOutputBuffer ?? this.outputBuffer;
    const script: string = 'window.__sshXtermWriteBatch(' + JSON.stringify(batch) + ', ' +
      batchSequence.toString() + ');';
    try {
      this.scheduleOutputBatchAckTimeout(lifecycleToken, batchSequence);
      this.controller.runJavaScript(script).then((): void => {
        // The JS evaluation only queues terminal.write. Keep the pump locked
        // until the page reports this batch's completed render frame.
        if (lifecycleToken !== this.lifecycleToken ||
          this.awaitingOutputBatch !== batchSequence) { return; }
      }).catch((_err: Error): void => {
        if (lifecycleToken !== this.lifecycleToken) { return; }
        if (this.awaitingOutputBatch !== batchSequence) { return; }
        this.clearOutputBatchAckTimer();
        this.inFlightWrites = [];
        this.inFlightOutputBuffer = null;
        this.awaitingOutputBatch = 0;
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
      if (this.awaitingOutputBatch !== batchSequence) { return; }
      this.clearOutputBatchAckTimer();
      this.inFlightWrites = [];
      this.inFlightOutputBuffer = null;
      this.awaitingOutputBatch = 0;
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
    if (!this.active) {
      this.pendingCoreKeyReload = true;
      return;
    }
    this.reloadDocumentForCoreKey();
  }

  private onRenderRevisionChange(): void {
    if (this.disposed) { return; }
    if (!this.active) {
      this.pendingCoreKeyReload = true;
      return;
    }
    // A host/session key can be reused after a surface recovery. Reload the
    // document explicitly so the visible xterm state cannot remain stale even
    // if ArkUI reuses the Web component instead of rebuilding its subtree.
    this.reloadDocumentForCoreKey();
  }

  private onActiveChange(): void {
    if (this.disposed) { return; }
    if (!this.active) {
      // Keep the document and xterm scrollback alive while this tab is hidden.
      // Only an actual core/revision change sets pendingCoreKeyReload; a normal
      // tab switch must not turn into a document reload.
      this.clearDocumentReloadRetry();
      this.documentReloadRetryCount = 0;
      this.restoreQueuedWrites();
      return;
    }
    if (this.pendingCoreKeyReload || this.documentReloadPending) {
      this.pendingCoreKeyReload = false;
      // A reload interrupted while inactive left its old document fenced. Let
      // the active turn create a fresh bridge instead of returning early on
      // the old document key.
      if (this.documentReloadPending) {
        this.documentReloadPending = false;
        this.reloadRequestedDocumentKey = '';
      }
      this.reloadDocumentForCoreKey();
      return;
    }
    this.runPageScript(this.pageConfigScript());
    this.flushOutputBuffer();
    this.pumpOutput();
    this.scheduleFit();
  }

  private onSurfaceRefreshRequestChange(): void {
    if (!this.active || this.disposed) { return; }
    if (this.documentReloadPending) { return; }
    this.runPageScript(this.pageConfigScript());
    this.flushOutputBuffer();
    this.pumpOutput();
    this.scheduleFit();
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
    if (!this.active || this.documentReloadPending || this.disposed) { return; }
    this.flushOutputBuffer();
  }

  private onFocusRequest(): void {
    if (!this.active) { return; }
    this.runPageScript('window.__sshXtermFocus();');
  }

  private onCopyRequest(): void {
    if (!this.active || !this.pageReady || this.disposed) { return; }
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
    if (!this.active) { return; }
    this.runPageScript('window.__sshXtermScrollToBottom();');
  }

  private onForceScrollToBottomRequest(): void {
    if (!this.active) { return; }
    this.runPageScript('window.__sshXtermScrollToBottom();');
  }

  private onExternalScrollRequest(): void {
    if (!this.active || this.externalScrollLines === 0) { return; }
    this.runPageScript('window.__sshXtermScrollLines(' + this.externalScrollLines.toString() + ');');
  }

  build() {
    Web({
      src: $rawfile('ssh-terminal/index.html'),
      controller: this.controller
    })
      // The binding key is also the native WebView identity. This keeps a
      // retained SSH session separate from the previous host's DOM/document
      // when ArkUI performs the keyed surface remount.
      .id('ssh-xterm-' + this.coreKey + '-render-' + this.renderRevision.toString())
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
