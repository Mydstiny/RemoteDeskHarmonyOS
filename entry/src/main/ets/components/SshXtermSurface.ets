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
import { sshDiagnosticErrorCode } from
  '../services/ssh/observability/SshDiagnosticPolicy';
import {
  decodeSshTerminalSearchRequest,
  decodeSshTerminalSearchResult,
  encodeSshTerminalSearchRequest,
  invalidSshTerminalSearchResult,
  SshTerminalSearchRequest,
  SshTerminalSearchResult
} from '../services/ssh/search/SshTerminalSearchPolicy';
import {
  SshWebMessagePortChannel,
  SshWebMessagePortLike
} from '../services/ssh/web/SshWebMessagePortChannel';
import { SshWebMessageEnvelopeV1 } from '../services/ssh/web/SshWebMessagePortPolicy';

const XTERM_DOMAIN: number = 0x0000;
const XTERM_TAG: string = 'SshXtermSurface';
const XTERM_DOCUMENT_RELOAD_TIMEOUT_MS: number = 3000;

/** Decoded SSH output waiting for the visible xterm page to consume it. */
export class XtermOutputBuffer {
  private pending: Array<string> = [];
  private listeners: Array<() => void> = [];

  enqueue(value: string): void {
    if (value.length === 0) { return; }
    this.pending.push(value);
    this.notifyReadable();
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

  /** Wake the renderer without routing terminal payload through ArkUI state. */
  subscribe(listener: () => void): () => void {
    this.listeners.push(listener);
    return (): void => {
      const index: number = this.listeners.indexOf(listener);
      if (index >= 0) { this.listeners.splice(index, 1); }
    };
  }

  private notifyReadable(): void {
    const listeners: Array<() => void> = this.listeners.slice();
    for (let index: number = 0; index < listeners.length; index++) {
      try { listeners[index](); } catch (_err) {
        // A stale renderer must not break the SSH reader or later listeners.
      }
    }
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
  onModeCallback: (mouseTracking: boolean, applicationCursorKeys: boolean,
    applicationKeypad: boolean, alternateBuffer: boolean) => void =
    (_mouseTracking: boolean, _applicationCursorKeys: boolean,
      _applicationKeypad: boolean, _alternateBuffer: boolean): void => {};

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

  onMode(mouseTracking: boolean, applicationCursorKeys: boolean,
    applicationKeypad: boolean, alternateBuffer: boolean): void {
    this.onModeCallback(mouseTracking, applicationCursorKeys,
      applicationKeypad, alternateBuffer);
  }
}

/** Explicit ArkWeb adapter; ArkTS does not permit structural assignment. */
class SshArkWebMessagePortAdapter implements SshWebMessagePortLike {
  private readonly delegate: webview.WebMessagePort;

  constructor(delegate: webview.WebMessagePort) {
    this.delegate = delegate;
  }

  postMessageEvent(message: string | ArrayBuffer): void {
    this.delegate.postMessageEvent(message);
  }

  onMessageEvent(callback: (message: string | ArrayBuffer) => void): void {
    this.delegate.onMessageEvent(callback);
  }

  close(): void {
    this.delegate.close();
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
  /** Parent-side fence used to recover a ready callback lost during tab handoff. */
  @Prop @Watch('onReadyProbeRequestChange') readyProbeRequest: number = 0;
  @Prop cols: number = 80;
  @Prop rows: number = 24;
  @Prop @Watch('onFontChange') fontSize: number = 18;
  @Prop @Watch('onLineSpacingChange') lineSpacing: number = 1.12;
  @Prop @Watch('onAppearanceChange') bottomAlignSparseContent: boolean = false;
  @Prop @Watch('onAppearanceChange') bottomAlignSafeRows: number = 0;
  @Prop @Watch('onAppearanceChange') bottomInsetPx: number = 10;
  @Prop @Watch('onAppearanceChange') profileEnabled: boolean = false;
  @Prop @Watch('onAppearanceChange') profileForegroundColor: string = '#33FF33';
  @Prop @Watch('onAppearanceChange') profileBackgroundColor: string = '#0D0D0D';
  @Prop @Watch('onAppearanceChange') profilePalette: string[] = [];
  @Prop @Watch('onAppearanceChange') profileFontFamily: string = 'monospace';
  @Prop @Watch('onAppearanceChange') profileFontWeight: string = 'normal';
  @Prop @Watch('onAppearanceChange') profileCursorStyle: string = 'bar';
  @Prop @Watch('onAppearanceChange') profileCursorBlink: boolean = true;
  @Prop @Watch('onAppearanceChange') profileScrollback: number = 10000;
  @Prop @Watch('onAppearanceChange') profileBellStyle: string = 'none';
  @Prop profileCopyOnSelect: boolean = false;
  @StorageProp('sshTerminalForegroundColor') @Watch('onAppearanceChange') terminalFgColor: string = '#33FF33';
  /** Low-frequency lifecycle wake; live output is delivered by outputBuffer. */
  @Prop @Watch('onOutputSequenceChange') outputSequence: number = 0;
  /**
   * API 23+ WebMessagePort transport. It is deliberately capability-gated
   * and defaults off so existing xterm proxy traffic remains the safe path
   * until the device/runtime acceptance matrix enables it.
   */
  @Prop @Watch('onWebMessageBridgeEnabledChange') webMessageBridgeEnabled: boolean = false;
  /** Replace the current document with one host transcript after a revision handoff. */
  @Prop transcriptResetIdentity: string = '';
  @Prop @Watch('onTranscriptResetRequestChange') transcriptResetRequest: number = 0;
  @Prop @Watch('onFocusRequest') focusRequest: number = 0;
  @Prop @Watch('onCopyRequest') copyRequest: number = 0;
  @Prop @Watch('onScrollToBottomRequest') scrollToBottomRequest: number = 0;
  @Prop @Watch('onForceScrollToBottomRequest') forceScrollToBottomRequest: number = 0;
  @Prop @Watch('onExternalScrollRequest') externalScrollRequest: number = 0;
  @Prop externalScrollLines: number = 0;
  /** JSON-whitelisted request; only the active host receives a non-empty value. */
  @Prop @Watch('onSearchRequestChange') searchRequest: string = '';
  /** Monotonic clear fence, replayed when a previously hidden tab becomes active. */
  @Prop @Watch('onSearchClearRequestChange') searchClearRequest: number = 0;
  /** Ordinary reference: it is deliberately outside ArkUI observation. */
  outputBuffer: XtermOutputBuffer = new XtermOutputBuffer();
  @Link copiedText: string;
  onData?: (data: string, surfaceKey: string) => void;
  onResize?: (cols: number, rows: number, surfaceKey: string) => void;
  onReady?: (surfaceKey: string) => void;
  onTerminalFocus?: (focused: boolean, surfaceKey: string) => void;
  onTerminalMode?: (mouseTracking: boolean, applicationCursorKeys: boolean,
    applicationKeypad: boolean, alternateBuffer: boolean, surfaceKey: string) => void;
  onSearchResult?: (result: SshTerminalSearchResult, surfaceKey: string) => void;

  private controller: webview.WebviewController = new webview.WebviewController();
  private bridge: SshXtermBridgeProxy = new SshXtermBridgeProxy();
  private webMessageChannel: SshWebMessagePortChannel = new SshWebMessagePortChannel();
  private webMessagePortConnected: boolean = false;
  private webMessagePortReady: boolean = false;
  private webMessagePortInstallAttempted: boolean = false;
  private webMessagePortToken: number = 0;
  private bridgeRegistered: boolean = false;
  private bridgeRetryTimer: number = -1;
  private bridgeRetryCount: number = 0;
  private bridgeCleanupTimer: number = -1;
  /** True after the current Web document has started loading. */
  private pageStarted: boolean = false;
  /** A proxy registered during a load becomes visible only after another load. */
  private bridgeActivationReloadPending: boolean = false;
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
  private outputBufferWakeTimer: number = -1;
  private outputBufferUnsubscribe: (() => void) | null = null;
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
  private lastSearchExecutionKey: string = '';
  private appliedSearchClearRequest: number = -1;

  private logLifecycle(message: string): void {
    hilog.info(XTERM_DOMAIN, XTERM_TAG, message);
  }

  private surfaceIdentity(): string {
    const key: string = this.coreKey.trim();
    if (key.length === 0) { return ''; }
    const revision: number = Number.isFinite(this.renderRevision)
      ? Math.max(0, Math.floor(this.renderRevision)) : 0;
    return key + ':render:' + revision.toString();
  }

  private webMessageGeneration(): number {
    const requested: number = Number(this.renderRevision);
    if (!Number.isFinite(requested)) { return 0; }
    return Math.max(1, Math.floor(requested));
  }

  private webMessagePortEligible(): boolean {
    return this.webMessageBridgeEnabled && !this.disposed && this.pageFinished &&
      this.coreKey.trim().length > 0 && this.webMessageGeneration() > 0;
  }

  private detachWebMessagePort(resetAttempted: boolean = true): void {
    this.webMessagePortToken++;
    this.webMessagePortConnected = false;
    this.webMessagePortReady = false;
    if (resetAttempted) { this.webMessagePortInstallAttempted = false; }
    if (this.outputPumpRunning) { this.restoreQueuedWrites(); }
    this.webMessageChannel.detach();
  }

  private disableWebMessagePort(code: string): void {
    this.webMessagePortConnected = false;
    this.webMessagePortReady = false;
    hilog.warn(XTERM_DOMAIN, XTERM_TAG, 'web message port disabled code=' + code);
    this.webMessageChannel.detach();
    if (this.outputPumpRunning) {
      this.restoreQueuedWrites();
    }
    if (!this.disposed && this.active && this.pageReady) {
      this.scheduleOutputPumpRetry(this.lifecycleToken);
    }
  }

  private handleWebMessageEnvelope(envelope: SshWebMessageEnvelopeV1,
    lifecycleToken: number): void {
    if (lifecycleToken !== this.lifecycleToken || this.disposed ||
      !this.webMessagePortConnected || envelope.sessionKey !== this.surfaceIdentity() ||
      envelope.generation !== this.webMessageGeneration()) {
      return;
    }
    if (envelope.kind === 'ack') {
      try {
        const source: Record<string, Object> = JSON.parse(envelope.payload) as Record<string, Object>;
        if (source['ready'] === true) {
          this.webMessagePortReady = true;
          this.flushOutputBuffer();
          return;
        }
        const batchSequence: number = Number(source['batchSequence']);
        if (Number.isFinite(batchSequence) && Math.floor(batchSequence) > 0) {
          this.handleOutputFrame(Math.floor(batchSequence));
        }
      } catch (_err) {
        // Transport ACKs without an application batch are valid; ignore them.
      }
      return;
    }
    if (envelope.kind === 'error') {
      this.disableWebMessagePort('page_error');
      return;
    }
    if (envelope.kind === 'input') {
      if (this.onData && envelope.payload.length > 0 && this.active) {
        this.onData(envelope.payload, this.surfaceIdentity());
      }
      return;
    }
    if (envelope.kind === 'resize') {
      try {
        const source: Record<string, Object> = JSON.parse(envelope.payload) as Record<string, Object>;
        const cols: number = Number(source['cols']);
        const rows: number = Number(source['rows']);
        if (this.onResize && Number.isFinite(cols) && Number.isFinite(rows) &&
          cols > 0 && rows > 0 && this.active) {
          this.onResize(Math.floor(cols), Math.floor(rows), this.surfaceIdentity());
        }
      } catch (_err) {
        // Invalid resize payloads are rejected at the owner boundary.
      }
    }
  }

  private installWebMessagePort(lifecycleToken: number = this.lifecycleToken): void {
    if (!this.webMessagePortEligible() || lifecycleToken !== this.lifecycleToken ||
      this.webMessagePortInstallAttempted) {
      return;
    }
    this.webMessagePortInstallAttempted = true;
    const sessionKey: string = this.surfaceIdentity();
    const generation: number = this.webMessageGeneration();
    const portToken: number = ++this.webMessagePortToken;
    try {
      const ports: Array<webview.WebMessagePort> = this.controller.createWebMessagePorts(false);
      if (ports.length < 2) {
        this.disableWebMessagePort('ports_unavailable');
        return;
      }
      const nativePort: SshWebMessagePortLike = new SshArkWebMessagePortAdapter(ports[0]);
      const pagePort: webview.WebMessagePort = ports[1];
      const attached: boolean = this.webMessageChannel.attach(nativePort, sessionKey, generation, {
        onReady: (): void => {
          if (portToken !== this.webMessagePortToken || lifecycleToken !== this.lifecycleToken ||
            this.disposed) { return; }
          this.webMessagePortConnected = true;
          this.logLifecycle('web message port ready');
        },
        onEnvelope: (envelope: SshWebMessageEnvelopeV1): void => {
          this.handleWebMessageEnvelope(envelope, lifecycleToken);
        },
        onError: (code: string): void => {
          if (portToken !== this.webMessagePortToken || lifecycleToken !== this.lifecycleToken) {
            return;
          }
          this.disableWebMessagePort(code);
        }
      });
      if (!attached) {
        this.disableWebMessagePort('attach_rejected');
        return;
      }
      // The page receives the transferred endpoint through the standard
      // message event. Prefer ArkWeb's current rawfile URI; the wildcard is
      // only a compatibility fallback for runtimes that report it as empty.
      let targetUri: string = '*';
      try {
        const currentUri: string = this.controller.getUrl();
        if (currentUri.trim().length > 0) { targetUri = currentUri; }
      } catch (_err) {
        // The controller can briefly report no URL during a keyed load.
      }
      this.controller.postMessage('sshTerminalWebMessagePort', [pagePort], targetUri);
    } catch (err) {
      hilog.debug(XTERM_DOMAIN, XTERM_TAG,
        'web message port unavailable code=' + sshDiagnosticErrorCode(err));
      this.disableWebMessagePort('install_failed');
    }
  }

  private onWebMessageBridgeEnabledChange(): void {
    if (!this.webMessageBridgeEnabled) {
      this.detachWebMessagePort();
      return;
    }
    if (this.webMessagePortEligible()) {
      this.installWebMessagePort();
    }
  }

  aboutToAppear(): void {
    this.restoreQueuedWrites();
    this.detachWebMessagePort();
    const lifecycleToken: number = ++this.lifecycleToken;
    this.disposed = false;
    if (this.outputBufferWakeTimer !== -1) {
      clearTimeout(this.outputBufferWakeTimer);
      this.outputBufferWakeTimer = -1;
    }
    if (this.outputBufferUnsubscribe !== null) {
      this.outputBufferUnsubscribe();
      this.outputBufferUnsubscribe = null;
    }
    this.outputBufferUnsubscribe = this.outputBuffer.subscribe((): void => {
      this.scheduleOutputBufferWake(lifecycleToken);
    });
    this.scheduleOutputBufferWake(lifecycleToken);
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
    this.pageStarted = false;
    this.bridgeActivationReloadPending = false;
    this.pageFinished = false;
    this.pageReady = false;
    this.readyReported = false;
    this.pendingCoreReset = false;
    this.pendingCoreKeyReload = false;
    this.reloadRequestedDocumentKey = '';
    this.documentReloadPending = false;
    this.awaitingOutputBatch = 0;
    this.lastSearchExecutionKey = '';
    this.appliedSearchClearRequest = this.normalizedSearchClearRequest();
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
    this.detachWebMessagePort();
    const lifecycleToken: number = ++this.lifecycleToken;
    this.disposed = true;
    if (this.outputBufferUnsubscribe !== null) {
      this.outputBufferUnsubscribe();
      this.outputBufferUnsubscribe = null;
    }
    if (this.outputBufferWakeTimer !== -1) {
      clearTimeout(this.outputBufferWakeTimer);
      this.outputBufferWakeTimer = -1;
    }
    this.clearBridgeRetry();
    this.bridgeRetryCount = 0;
    this.pageStarted = false;
    this.bridgeActivationReloadPending = false;
    this.pageFinished = false;
    this.pageReady = false;
    this.pendingCoreReset = false;
    this.pendingCoreKeyReload = false;
    this.reloadRequestedDocumentKey = '';
    this.documentReloadPending = false;
    this.pendingWrites = [];
    this.outputPumpRunning = false;
    this.awaitingOutputBatch = 0;
    this.lastSearchExecutionKey = '';
    this.appliedSearchClearRequest = this.normalizedSearchClearRequest();
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
        this.onData(data, this.surfaceIdentity());
      }
    };
    this.bridge.onResizeCallback = (cols: number, rows: number): void => {
      if (lifecycleToken === this.lifecycleToken && this.onResize && !this.disposed) {
        this.onResize(cols, rows, this.surfaceIdentity());
      }
    };
    this.bridge.onSelectionCallback = (text: string): void => {
      if (lifecycleToken === this.lifecycleToken && !this.disposed &&
        this.active && this.profileEnabled && this.profileCopyOnSelect && text.length > 0) {
        this.copiedText = text;
      }
    };
    this.bridge.onFocusCallback = (focused: boolean): void => {
      if (lifecycleToken === this.lifecycleToken && this.onTerminalFocus && !this.disposed) {
        this.onTerminalFocus(focused, this.surfaceIdentity());
      }
    };
    this.bridge.onModeCallback = (mouseTracking: boolean, applicationCursorKeys: boolean,
      applicationKeypad: boolean, alternateBuffer: boolean): void => {
      if (lifecycleToken === this.lifecycleToken && this.onTerminalMode && !this.disposed) {
        this.onTerminalMode(mouseTracking === true, applicationCursorKeys === true,
          applicationKeypad === true, alternateBuffer === true, this.surfaceIdentity());
      }
    };
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
        ['onReady', 'onFrame', 'onFrameError', 'onInput', 'onResize', 'onSelection', 'onFocus',
          'onMode']
      );
      this.bridgeRegistered = true;
      this.bridgeRetryCount = 0;
      this.clearBridgeRetry();
      this.logLifecycle('bridge registered');
      if (this.pageStarted) {
        // ArkWeb exposes a newly registered proxy only after the next page
        // load. The initial Web component load may already be in progress.
        this.bridgeActivationReloadPending = true;
      } else if (this.documentReloadPending && this.active) {
        // Reload attempts must register before loadUrl; otherwise the new
        // document repeats the same invisible-proxy failure.
        const requestedDocumentKey: string = this.reloadRequestedDocumentKey;
        if (requestedDocumentKey.length > 0) {
          this.attemptDocumentReload(lifecycleToken, requestedDocumentKey);
        }
      }
    } catch (err) {
      this.scheduleBridgeRetry(lifecycleToken);
      hilog.debug(XTERM_DOMAIN, XTERM_TAG,
        'register bridge deferred code=' + sshDiagnosticErrorCode(err));
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
      fontFamily: this.profileEnabled && this.profileFontFamily !== 'monospace' ?
        this.profileFontFamily + ', monospace' : 'monospace',
      fontWeight: this.profileEnabled ? this.profileFontWeight : 'normal',
      foreground: this.profileEnabled ? this.profileForegroundColor : this.terminalFgColor,
      background: this.profileEnabled ? this.profileBackgroundColor : '#0D0D0D',
      palette: this.profileEnabled ? this.profilePalette : [],
      cursorStyle: this.profileEnabled ? this.profileCursorStyle : 'bar',
      cursorBlink: this.profileEnabled ? this.profileCursorBlink : true,
      scrollback: this.profileEnabled ? this.profileScrollback : 10000,
      bellStyle: this.profileEnabled ? this.profileBellStyle : 'none',
      bottomAlignSparseContent: this.bottomAlignSparseContent,
      bottomAlignSafeRows: Math.max(0, Math.min(6, Math.floor(this.bottomAlignSafeRows))),
      bottomInsetPx: Math.max(0, Math.min(20, Math.floor(this.bottomInsetPx)))
    });
    // ArkWeb can dispatch onPageEnd while the rawfile's inline bootstrap is
    // still installing its window functions. Keep configuration idempotent
    // and retry inside the page so this race cannot strand xterm at its
    // default cursor with no ready callback.
    return '(function(config){' +
      'var attempts=0;' +
      'function apply(){' +
      'if(typeof window.__sshXtermConfigure==="function"){' +
      'window.__sshXtermConfigure(config);return;}' +
      'if(attempts++<120){window.setTimeout(apply,16);}' +
      '}' +
      'apply();' +
      '})(' + config + ');';
  }

  private runPageScript(script: string, onSuccess?: () => void, onFailure?: () => void): void {
    // ArkWeb can deliver the xterm ready callback before onPageEnd. The page
    // has already booted its JS surface at that point, so pageReady is enough
    // evidence for configuration and output calls.
    if (this.disposed || (!this.pageFinished && !this.pageReady)) { return; }
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

  private normalizedSearchClearRequest(): number {
    const requested: number = Number(this.searchClearRequest);
    return Number.isFinite(requested) ? Math.max(0, Math.floor(requested)) : 0;
  }

  private searchExecutionCurrent(lifecycleToken: number, surfaceIdentity: string,
    payload: string): boolean {
    return lifecycleToken === this.lifecycleToken && !this.disposed && this.active &&
      this.pageReady && surfaceIdentity === this.surfaceIdentity() &&
      payload === this.searchRequest.trim();
  }

  private reportSearchResult(result: SshTerminalSearchResult, lifecycleToken: number,
    surfaceIdentity: string, payload: string): void {
    if (!this.searchExecutionCurrent(lifecycleToken, surfaceIdentity, payload)) { return; }
    if (this.onSearchResult) { this.onSearchResult(result, surfaceIdentity); }
  }

  private executeSearchRequest(): void {
    if (!this.active || !this.pageReady || this.documentReloadPending || this.disposed) { return; }
    const requestedPayload: string = this.searchRequest.trim();
    if (requestedPayload.length === 0) { return; }
    const request: SshTerminalSearchRequest | null =
      decodeSshTerminalSearchRequest(requestedPayload);
    if (request === null) { return; }
    const payload: string = encodeSshTerminalSearchRequest(request);
    if (payload.length === 0) { return; }
    const lifecycleToken: number = this.lifecycleToken;
    const surfaceIdentity: string = this.surfaceIdentity();
    const executionKey: string = lifecycleToken.toString() + ':' + surfaceIdentity + ':' + payload;
    if (executionKey === this.lastSearchExecutionKey) { return; }
    this.lastSearchExecutionKey = executionKey;
    const script: string = '(function(request){' +
      'if(typeof window.__sshXtermSearch!=="function"){' +
      'return JSON.stringify({requestId:request.requestId,found:false,resultIndex:-1,' +
      'resultCount:0,elapsedMs:0,errorCode:"search_unavailable"});}' +
      'return window.__sshXtermSearch(request);' +
      '})(' + payload + ');';
    try {
      this.controller.runJavaScript(script).then((rawResult: string): void => {
        if (!this.searchExecutionCurrent(lifecycleToken, surfaceIdentity, payload)) { return; }
        const result: SshTerminalSearchResult =
          decodeSshTerminalSearchResult(rawResult ?? '', request.requestId);
        this.reportSearchResult(result, lifecycleToken, surfaceIdentity, payload);
      }).catch((_err: Error): void => {
        if (!this.searchExecutionCurrent(lifecycleToken, surfaceIdentity, payload)) { return; }
        this.lastSearchExecutionKey = '';
        this.reportSearchResult(
          invalidSshTerminalSearchResult(request.requestId, 'execution_failed'),
          lifecycleToken, surfaceIdentity, payload);
      });
    } catch (_err) {
      if (!this.searchExecutionCurrent(lifecycleToken, surfaceIdentity, payload)) { return; }
      this.lastSearchExecutionKey = '';
      this.reportSearchResult(
        invalidSshTerminalSearchResult(request.requestId, 'execution_failed'),
        lifecycleToken, surfaceIdentity, payload);
    }
  }

  private executeSearchClear(): void {
    if (!this.active || !this.pageReady || this.documentReloadPending || this.disposed) { return; }
    const request: number = this.normalizedSearchClearRequest();
    if (request === this.appliedSearchClearRequest) { return; }
    this.appliedSearchClearRequest = request;
    this.lastSearchExecutionKey = '';
    this.runPageScript(
      'if(typeof window.__sshXtermClearSearch==="function"){window.__sshXtermClearSearch();}');
  }

  private reconcileSearchState(): void {
    if (this.searchRequest.trim().length > 0) {
      this.executeSearchRequest();
    } else {
      this.executeSearchClear();
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
    this.detachWebMessagePort();
    this.clearBridgeRetry();
    if (this.readyReportTimer !== -1) {
      clearTimeout(this.readyReportTimer);
      this.readyReportTimer = -1;
    }
    this.clearPageConfigRetry();
    this.pageConfigRetryCount = 0;
    this.clearDocumentReloadRetry();
    this.bridgeRegistered = false;
    this.pageStarted = false;
    this.bridgeActivationReloadPending = false;
    this.pageFinished = false;
    this.pageReady = false;
    this.readyReported = false;
    try { this.controller.deleteJavaScriptRegister('sshTerminalBridge'); } catch (_err) {
      // The previous document may already have been detached.
    }
    this.bridge = new SshXtermBridgeProxy();
    this.installBridgeCallbacks(lifecycleToken);
    this.registerBridge(lifecycleToken);
  }

  private attemptDocumentReload(lifecycleToken: number, requestedDocumentKey: string): void {
    if (lifecycleToken !== this.lifecycleToken || this.disposed || !this.active ||
      !this.documentReloadPending || this.reloadRequestedDocumentKey !== requestedDocumentKey) {
      return;
    }
    if (!this.bridgeRegistered) {
      this.registerBridge(lifecycleToken);
      return;
    }
    try {
      this.controller.loadUrl($rawfile('ssh-terminal/index.html'));
      this.documentReloadRetryCount = 0;
      this.scheduleDocumentReloadWatchdog(lifecycleToken, requestedDocumentKey);
    } catch (err) {
      hilog.warn(XTERM_DOMAIN, XTERM_TAG,
        'reload xterm document failed code=' + sshDiagnosticErrorCode(err));
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
    if (this.disposed || lifecycleToken !== this.lifecycleToken ||
      (!this.pageFinished && !this.pageReady)) {
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

  /**
   * The page can boot before ArkWeb finishes installing the JavaScript proxy.
   * Ask the already-loaded document to publish readiness again after the
   * bridge is registered instead of waiting for the one-shot boot callback.
   */
  private nudgePageReady(lifecycleToken: number = this.lifecycleToken): void {
    if (this.disposed || lifecycleToken !== this.lifecycleToken || !this.pageFinished ||
      this.pageReady) {
      return;
    }
    try {
      this.controller.runJavaScript(
        'if (window.__sshXtermNotifyReady) { window.__sshXtermNotifyReady(); }'
      ).then((): void => {
        if (lifecycleToken !== this.lifecycleToken || this.disposed || this.pageReady) { return; }
        // A page-side boot retry can still be pending. Keep the probe bounded
        // by the existing page-config retry window and lifecycle token.
        this.schedulePageReadyProbe(lifecycleToken);
      }).catch((_err: Error): void => {
        this.schedulePageReadyProbe(lifecycleToken);
      });
    } catch (_err) {
      this.schedulePageReadyProbe(lifecycleToken);
    }
  }

  private schedulePageReadyProbe(lifecycleToken: number): void {
    if (this.disposed || lifecycleToken !== this.lifecycleToken || this.pageReady ||
      !this.pageFinished || this.pageConfigRetryTimer !== -1) {
      return;
    }
    this.pageConfigRetryTimer = setTimeout((): void => {
      this.pageConfigRetryTimer = -1;
      this.nudgePageReady(lifecycleToken);
    }, 64);
  }

  private handlePageReady(cols: number, rows: number): void {
    if (this.disposed) { return; }
    this.pageReady = true;
    this.logLifecycle('page ready cols=' + cols.toString() + ' rows=' + rows.toString() +
      ' finished=' + (this.pageFinished ? '1' : '0'));
    this.documentReloadPending = false;
    this.reloadRequestedDocumentKey = '';
    this.clearDocumentReloadRetry();
    this.documentReloadRetryCount = 0;
    if (!this.active) { return; }
    this.applyPageConfigAfterLoad();
    this.flushOutputBuffer();
    this.reconcileSearchState();
    if (this.onResize && cols > 0 && rows > 0) {
      this.onResize(cols, rows, this.surfaceIdentity());
    }
  }

  /**
   * Report visibility only after the first document has drained its retained
   * transcript. The extra UI turn lets xterm complete its asynchronous write
   * callback before the ArkUI loading mask is removed.
   */
  private maybeReportReady(): void {
    if (this.readyReported || this.disposed || !this.active || !this.pageReady) {
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
    this.logLifecycle('report ready');
    if (this.onReady) { this.onReady(this.surfaceIdentity()); }
  }

  private handlePageEnd(): void {
    if (this.disposed) { return; }
    this.pageFinished = true;
    this.logLifecycle('page end ready=' + (this.pageReady ? '1' : '0'));
    this.registerBridge();
    this.installWebMessagePort();
    // A late registration normally needs one reload to expose the proxy to
    // the document. If the document already delivered pageReady, the proxy
    // is active and reloading would only add cold-start latency.
    if (this.bridgeActivationReloadPending && !this.pageReady) {
      this.bridgeActivationReloadPending = false;
      this.reloadDocumentForCoreKey();
      return;
    }
    this.bridgeActivationReloadPending = false;
    this.nudgePageReady();
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
    this.detachWebMessagePort();
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
    this.pageStarted = false;
    this.bridgeActivationReloadPending = false;
    this.pageFinished = false;
    this.pageReady = false;
    this.readyReported = false;
    this.pendingCoreReset = false;
    this.lastSearchExecutionKey = '';
    this.appliedSearchClearRequest = this.normalizedSearchClearRequest();
    this.documentReloadPending = true;
    this.reloadRequestedDocumentKey = requestedDocumentKey;
    try { this.controller.deleteJavaScriptRegister('sshTerminalBridge'); } catch (_err) {
      // The old document may already have been detached.
    }
    // Do not reuse the proxy registered by the old document. ArkWeb can finish
    // dispatching one of its callbacks after loadUrl() has started.
    this.bridge = new SshXtermBridgeProxy();
    this.installBridgeCallbacks(lifecycleToken);
    this.registerBridge(lifecycleToken);
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

  private scheduleOutputBufferWake(lifecycleToken: number): void {
    if (this.disposed || this.outputBufferWakeTimer !== -1) { return; }
    this.outputBufferWakeTimer = setTimeout((): void => {
      this.outputBufferWakeTimer = -1;
      if (this.disposed || lifecycleToken !== this.lifecycleToken ||
        !this.active || this.documentReloadPending) {
        return;
      }
      this.flushOutputBuffer();
    }, 0);
  }

  private flushOutputBuffer(): void {
    if (!this.active || this.disposed) { return; }
    this.enqueueOutput();
    this.pumpOutput();
  }

  private pumpOutput(): void {
    if (!this.active || this.outputPumpRunning || !this.pageReady || this.disposed) { return; }
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
    if (this.webMessagePortReady && this.webMessageChannel.isReady()) {
      const payload: string = JSON.stringify({ batchSequence: batchSequence, values: batch });
      this.scheduleOutputBatchAckTimeout(lifecycleToken, batchSequence);
      const accepted: boolean = this.webMessageChannel.send('output', payload);
      if (accepted) { return; }
      // A bounded transport queue may reject a burst. Preserve the same
      // xterm FIFO and let the mature proxy path retry without dropping the
      // frame or changing the session identity.
      if (!this.outputPumpRunning || this.awaitingOutputBatch !== batchSequence) { return; }
      this.clearOutputBatchAckTimer();
      this.inFlightWrites = [];
      this.inFlightOutputBuffer = null;
      this.awaitingOutputBatch = 0;
      for (let index: number = batch.length - 1; index >= 0; index--) {
        this.pendingWrites.unshift(batch[index]);
      }
      this.outputPumpRunning = false;
      this.scheduleOutputPumpRetry(lifecycleToken);
      return;
    }
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
    if (this.webMessagePortConnected || this.webMessagePortInstallAttempted) {
      this.detachWebMessagePort();
    }
    if (!this.active) {
      this.pendingCoreKeyReload = true;
      return;
    }
    // The initial Web document may still be waiting for ArkWeb to dispatch
    // onPageBegin. A connection/session revision change during that window
    // only changes the binding identity; reloading here creates a second
    // bridge registration before the first document has even started.
    if (!this.pageStarted && !this.pageFinished && !this.pageReady &&
      !this.documentReloadPending) {
      return;
    }
    this.reloadDocumentForCoreKey();
  }

  private onRenderRevisionChange(): void {
    if (this.disposed) { return; }
    if (this.webMessagePortConnected || this.webMessagePortInstallAttempted) {
      this.detachWebMessagePort();
    }
    if (!this.active) {
      this.pendingCoreKeyReload = true;
      return;
    }
    // The initial xterm document is intentionally warmed before SSH attaches.
    // A session-generation update during that cold boot changes callback
    // identity but does not change the host-owned transcript or the DOM. Wait
    // for the first ready boundary instead of throwing away the page and
    // paying the full WebView load cost a second time.
    if (!this.pageReady && !this.documentReloadPending) {
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
    // A surface that was booted while hidden can finish its document load
    // before the active tab switch. Nudge the page-side ready callback at the
    // activation boundary so a missed bridge callback cannot leave the host
    // with only the WebView's input caret.
    if (!this.pageReady && this.pageFinished) {
      this.nudgePageReady();
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
    // A hidden tab may have finished loading while active=false. In that
    // state handlePageReady intentionally defers the parent ready callback;
    // activation must therefore use the full post-load path so the target
    // tab cannot remain behind the page's Preparing-terminal mask.
    this.applyPageConfigAfterLoad();
    this.flushOutputBuffer();
    this.pumpOutput();
    this.scheduleFit();
    this.reconcileSearchState();
  }

  private onSurfaceRefreshRequestChange(): void {
    if (!this.active || this.disposed) { return; }
    if (this.documentReloadPending) { return; }
    // Keep refreshes idempotent and preserve the same ready-report retry path
    // used by activation after a hidden document boot.
    this.applyPageConfigAfterLoad();
    this.flushOutputBuffer();
    this.pumpOutput();
    this.scheduleFit();
    this.reconcileSearchState();
  }

  private onReadyProbeRequestChange(): void {
    if (!this.active || this.disposed || this.documentReloadPending) { return; }
    if (!this.pageReady) {
      if (this.pageFinished) { this.nudgePageReady(); }
      return;
    }
    // A retained tab can finish rendering while ArkUI coalesces the parent
    // callback. Re-arm the one-shot report so the parent can accept the exact
    // host/revision identity and remove its loading mask.
    this.readyReported = false;
    this.applyPageConfigAfterLoad();
    this.flushOutputBuffer();
    this.maybeReportReady();
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
    this.logLifecycle('appearance font=' + this.fontSize.toString() +
      ' lineSpacing=' + this.lineSpacing.toString());
    this.runPageScript(this.pageConfigScript());
  }

  private onLineSpacingChange(): void {
    this.logLifecycle('appearance font=' + this.fontSize.toString() +
      ' lineSpacing=' + this.lineSpacing.toString());
    this.runPageScript(this.pageConfigScript());
  }

  private onAppearanceChange(): void {
    this.runPageScript(this.pageConfigScript());
  }

  private onOutputSequenceChange(): void {
    if (!this.active || this.documentReloadPending || this.disposed) { return; }
    this.flushOutputBuffer();
  }

  private onTranscriptResetRequestChange(): void {
    if (!this.active || !this.pageReady || this.documentReloadPending || this.disposed ||
      this.transcriptResetIdentity.trim() !== this.surfaceIdentity()) {
      return;
    }
    const lifecycleToken: number = this.lifecycleToken;
    this.logLifecycle('reset document transcript');
    this.runPageScript('window.__sshXtermReset();', (): void => {
      if (lifecycleToken !== this.lifecycleToken || this.disposed || !this.active ||
        this.transcriptResetIdentity.trim() !== this.surfaceIdentity()) {
        return;
      }
      // The parent replaced the host queue with its bounded transcript before
      // advancing this request. Drain it only after xterm.reset() completes so
      // a retained DOM cannot show both its old rows and the restored rows.
      this.flushOutputBuffer();
      this.scheduleFit();
      this.lastSearchExecutionKey = '';
      this.executeSearchRequest();
    });
  }

  private onSearchRequestChange(): void {
    if (this.searchRequest.trim().length === 0) {
      this.lastSearchExecutionKey = '';
      this.executeSearchClear();
      return;
    }
    this.executeSearchRequest();
  }

  private onSearchClearRequestChange(): void {
    if (this.searchRequest.trim().length === 0) { this.executeSearchClear(); }
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
      // The page converts two-finger pinch into terminal font size so xterm,
      // its measured grid and the remote PTY resize as one unit.
      .zoomAccess(false)
      // API 23 exposes the controller before navigation begins. Registering
      // here lets the first rawfile document see the proxy and avoids the old
      // mandatory activation reload after onPageBegin.
      .onControllerAttached((): void => {
        this.logLifecycle('controller attached');
        this.registerBridge();
      })
      .onPageBegin((): void => {
        this.pageStarted = true;
        this.logLifecycle('page begin');
        this.registerBridge();
      })
      .onPageEnd((): void => { this.handlePageEnd(); })
      .onAreaChange((_oldArea: Area, _newArea: Area): void => {
        this.scheduleFit();
      })
      .width('100%')
      .height('100%')
      .backgroundColor('#0D0D0D');
  }
}

/**
 * Keep ArkWeb and the bundled xterm frontend warm while the host list is open.
 * This surface deliberately has no SSH bridge beyond the page-ready callback;
 * it exists only to pay the WebView/vendor-script cold-start cost before the
 * user opens a real terminal.
 */
class SshXtermPrewarmBridge {
  private startedAtMs: number = Date.now();

  onReady(cols: number, rows: number): void {
    hilog.info(XTERM_DOMAIN, XTERM_TAG,
      'prewarm ready cols=' + cols.toString() + ' rows=' + rows.toString() +
        ' elapsedMs=' + Math.max(0, Date.now() - this.startedAtMs).toString());
  }
}

@Component
export struct SshXtermPrewarmSurface {
  @Prop prewarmEnabled: boolean = false;

  private controller: webview.WebviewController = new webview.WebviewController();
  private bridge: SshXtermPrewarmBridge = new SshXtermPrewarmBridge();
  private bridgeRegistered: boolean = false;
  private appearedAtMs: number = 0;
  private bridgeRegisteredAtPageBegin: boolean = false;
  private activationReloaded: boolean = false;

  private elapsedMs(): number {
    if (this.appearedAtMs <= 0) { return 0; }
    return Math.max(0, Date.now() - this.appearedAtMs);
  }

  aboutToAppear(): void {
    this.appearedAtMs = Date.now();
    this.bridgeRegisteredAtPageBegin = false;
    this.activationReloaded = false;
    hilog.info(XTERM_DOMAIN, XTERM_TAG,
      'prewarm appear enabled=' + (this.prewarmEnabled ? '1' : '0'));
    this.registerBridge();
  }

  aboutToDisappear(): void {
    hilog.info(XTERM_DOMAIN, XTERM_TAG,
      'prewarm disappear elapsedMs=' + this.elapsedMs().toString() +
        ' bridge=' + (this.bridgeRegistered ? '1' : '0'));
    if (this.bridgeRegistered) {
      try { this.controller.deleteJavaScriptRegister('sshTerminalBridge'); } catch (_err) {
        // The Web page may already have been detached.
      }
      this.bridgeRegistered = false;
    }
  }

  private registerBridge(): void {
    if (this.bridgeRegistered) { return; }
    try {
      this.controller.registerJavaScriptProxy(
        this.bridge,
        'sshTerminalBridge',
        ['onReady']
      );
      this.bridgeRegistered = true;
      hilog.info(XTERM_DOMAIN, XTERM_TAG,
        'prewarm bridge registered elapsedMs=' + this.elapsedMs().toString());
    } catch (_err) {
      hilog.debug(XTERM_DOMAIN, XTERM_TAG,
        'prewarm bridge register deferred elapsedMs=' + this.elapsedMs().toString());
      // onPageBegin retries after ArkWeb has attached the controller.
    }
  }

  build() {
    Stack() {
      if (this.prewarmEnabled) {
        Web({
          src: $rawfile('ssh-terminal/index.html'),
          controller: this.controller
        })
          .id('ssh-xterm-prewarm')
          .javaScriptAccess(true)
          .fileAccess(true)
          .domStorageAccess(false)
          .onControllerAttached((): void => {
            hilog.info(XTERM_DOMAIN, XTERM_TAG,
              'prewarm controller attached elapsedMs=' + this.elapsedMs().toString());
            this.registerBridge();
          })
          .onPageBegin((): void => {
            this.bridgeRegisteredAtPageBegin = this.bridgeRegistered;
            hilog.info(XTERM_DOMAIN, XTERM_TAG,
              'prewarm page begin elapsedMs=' + this.elapsedMs().toString() +
                ' bridge=' + (this.bridgeRegisteredAtPageBegin ? '1' : '0'));
            this.registerBridge();
          })
          .onPageEnd((): void => {
            hilog.info(XTERM_DOMAIN, XTERM_TAG,
              'prewarm page end elapsedMs=' + this.elapsedMs().toString() +
                ' bridge=' + (this.bridgeRegistered ? '1' : '0'));
            this.registerBridge();
            if (!this.bridgeRegisteredAtPageBegin && this.bridgeRegistered &&
              !this.activationReloaded) {
              // A proxy registered during a document load is visible to the
              // next document on API 23. Reload exactly once so the warm page
              // can deliver its ready callback instead of remaining a silent
              // hidden WebView.
              this.activationReloaded = true;
              hilog.info(XTERM_DOMAIN, XTERM_TAG,
                'prewarm activation reload elapsedMs=' + this.elapsedMs().toString());
              try {
                this.controller.loadUrl($rawfile('ssh-terminal/index.html'));
              } catch (_err) {
                hilog.warn(XTERM_DOMAIN, XTERM_TAG,
                  'prewarm activation reload failed elapsedMs=' + this.elapsedMs().toString());
              }
            }
          })
          .width(1)
          .height(1)
          .opacity(0)
          .hitTestBehavior(HitTestMode.None);
      }
    }
      .width(1)
      .height(1)
      .hitTestBehavior(HitTestMode.None);
  }
}
