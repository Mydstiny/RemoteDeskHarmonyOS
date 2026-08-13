import { promptAction, router } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { Palette, buildDark, buildLight } from '../common/Theme';
import { MoonlightConnectStageOverlay } from '../components/moonlight/MoonlightConnectStageOverlay';
import { MoonlightControlCenter, MoonlightControlMode } from '../components/moonlight/MoonlightControlCenter';
import {
  MoonlightControllerOverlay,
  MoonlightControllerSemanticEvent
} from '../components/moonlight/MoonlightControllerOverlay';
import { MoonlightDiagnosticsHud } from '../components/moonlight/MoonlightDiagnosticsHud';
import { MoonlightSessionToolbar } from '../components/moonlight/MoonlightSessionToolbar';
import { RemoteModifierHandle } from '../components/RemoteModifierHandle';
import { RemoteModifierPanel } from '../components/RemoteModifierPanel';
import { AccountScopeToken, AccountSessionLease } from '../services/AccountScopePolicy';
import { AccountSessionCoordinator } from '../services/AccountSessionCoordinator';
import { CloudStore } from '../services/CloudStore';
import {
  MoonlightSessionCoordinator,
  MoonlightSessionStartRequest
} from '../services/MoonlightSessionCoordinator';
import {
  MoonlightSessionErrorCode,
  MoonlightSessionPhase,
  MoonlightSessionStateSnapshot
} from '../services/MoonlightSessionState';
import {
  MoonlightDiagnosticsSnapshot,
  MoonlightRouteIdentity,
  MoonlightToolbarLayout,
  MoonlightToolbarAction,
  moonlightRouteIdentity,
  moonlightToolbarLayout
} from '../services/MoonlightUiPolicy';
import rdpnapi from 'librdpnapi.so';
import {
  MoonlightHostService,
  MoonlightNativeRequestKey
} from '../services/MoonlightHostService';
import {
  moonlightInstallationId,
  moonlightOwnerScopeFingerprint
} from '../services/MoonlightRuntimeSupport';

class MoonlightStreamXComponentController extends XComponentController {
  onSurface: (surfaceId: string) => void = (_surfaceId: string): void => {};
  onSurfaceDetached: (surfaceId: string) => void = (_surfaceId: string): void => {};
  onSurfaceCreated(surfaceId: string): void { this.onSurface(surfaceId); }
  onSurfaceDestroyed(surfaceId: string): void { this.onSurfaceDetached(surfaceId); }
}

type MoonlightSessionSheetMode = 'none' | 'control' | 'stop';
type MoonlightPointerAction = 'relative' | 'absolute' | 'button' | 'scroll';
type MoonlightTouchPhase = 'down' | 'move' | 'up' | 'cancel';
type MoonlightInputLifecycleReason = 'overlay_opened' | 'control_mode_changed' |
  'display_rotated' | 'focus_lost' | 'pip_entered' | 'backgrounded' |
  'surface_detached' | 'reconnect_started';

interface MoonlightPointerInputRequest {
  launchKey: MoonlightNativeRequestKey;
  action: MoonlightPointerAction;
  x?: number;
  y?: number;
  contentLeft?: number;
  contentTop?: number;
  contentWidth?: number;
  contentHeight?: number;
  referenceWidth?: number;
  referenceHeight?: number;
  geometryGeneration?: number;
  button?: number;
  pressed?: boolean;
  horizontal?: boolean;
  scrollAmount?: number;
}

interface MoonlightTouchPoint {
  x: number;
  y: number;
}

const EMPTY_SNAPSHOT: MoonlightDiagnosticsSnapshot = {
  available: false, fps: -1, latencyMs: -1, bitrateKbps: -1,
  packetLossPercent: -1, codec: '', width: 0, height: 0,
  decodeP50Us: -1, decodeP95Us: -1, renderP50Us: -1, renderP95Us: -1,
  audioUnderruns: -1, inputDrops: -1
};

@Entry
@Component
struct MoonlightStreamPage {
  @StorageLink('currentTheme') theme: string = 'light';
  @StorageLink('accentColor') accentColor: string = '#007DFF';
  @StorageProp('currentBreakpoint') breakpoint: string = 'sm';
  @StorageProp('isDesktopDevice') isDesktopDevice: boolean = false;
  @StorageProp('isPadDevice') isPadDevice: boolean = false;
  @StorageProp('liveViewEnabled') liveViewEnabled: boolean = true;
  @StorageProp('liveViewMode') liveViewMode: number = 1;
  @StorageProp('remoteDisplayScaleMode') commonDisplayScaleMode: string = 'fit';
  @State hostId: string = '';
  @State appId: string = '';
  @State phase: MoonlightSessionPhase = 'failed';
  @State errorCode: MoonlightSessionErrorCode = 'internal';
  @State degradationReasons: string[] = [];
  @State elapsedMs: number = 0;
  @State firstFrameSeen: boolean = false;
  @State inputReady: boolean = false;
  @State controllerReady: boolean = false;
  @State audioReady: boolean = false;
  @State showConnectStage: boolean = true;
  @State showSessionSheet: boolean = false;
  @State sheetMode: MoonlightSessionSheetMode = 'none';
  @State pendingSheetMode: MoonlightSessionSheetMode = 'none';
  @State controlMode: MoonlightControlMode = 'touch';
  @State muted: boolean = false;
  @State volume: number = 100;
  @State scaleMode: string = 'fit';
  @State latencyMode: string = 'lowLatency';
  @State sessionChanges: number = 0;
  @State showDiagnostics: boolean = false;
  @State diagnosticsExpanded: boolean = false;
  @State diagnosticsX: number = 18;
  @State diagnosticsY: number = 90;
  @State showController: boolean = false;
  @State controllerEditing: boolean = false;
  @State showModifierPanel: boolean = false;
  @State showShortcutPanel: boolean = false;
  @State ctrlLatch: string = 'off';
  @State altLatch: string = 'off';
  @State shiftLatch: string = 'off';
  @State winLatch: string = 'off';
  @State fnLayer: boolean = false;
  @State showReconnectMask: boolean = false;
  @State showAudioBanner: boolean = false;
  @State showNetworkBanner: boolean = false;
  @State inputFlushCount: number = 0;
  private readonly pipRuntimeAvailable: boolean = false;
  private readonly sessionCoordinator: MoonlightSessionCoordinator =
    MoonlightSessionCoordinator.getInstance();
  private readonly hostService: MoonlightHostService = new MoonlightHostService();
  private accountScopeUnsubscribe: (() => void) | null = null;
  private snapshotUnsubscribe: (() => void) | null = null;
  private pageActive: boolean = false;
  private sessionGeneration: number = 0;
  private sessionStartedAtMs: number = 0;
  private elapsedTimer: number = -1;
  private sheetReopenGeneration: number = 0;
  private sheetReopenTimer: number = -1;
  private readonly xcId: string = 'MoonlightStreamSurface';
  private readonly xComponentController: MoonlightStreamXComponentController =
    new MoonlightStreamXComponentController();
  private launchKey: MoonlightNativeRequestKey = { requestId: 0, generation: 0, ownerToken: 0 };
  private serverUuid: string = '';
  private numericAppId: number = 0;
  private hostAddress: string = '';
  private surfaceId: string = '';
  private surfaceWidthPx: number = 1920;
  private surfaceHeightPx: number = 1080;
  private surfaceWidthVp: number = 1;
  private surfaceHeightVp: number = 1;
  private streamWidth: number = 1920;
  private streamHeight: number = 1080;
  private configuredBitrateKbps: number = 20000;
  private routeOwnerScopeFingerprint: string = '';
  private routeAccountGeneration: number = 0;
  private routeInstallationId: string = '';
  private routeStoreInstanceId: number = 0;
  private routeOwnerValidated: boolean = false;
  private launchOwnerDisposed: boolean = false;
  private geometryGeneration: number = 1;
  private hitMapGeneration: number = 1;
  private activeTouches: Map<number, MoonlightTouchPoint> = new Map<number, MoonlightTouchPoint>();
  private inputSuspended: boolean = false;
  private rendererHandle: number = -1;
  private streamStartAttempted: boolean = false;
  private surfacePollTimer: number = -1;
  private sessionReserved: boolean = false;
  private routeTerminated: boolean = false;
  private nativeSurfaceAttached: boolean = false;
  private reservedOwnerScopeId: string = '';
  private reservedAccountGeneration: number = 0;
  private nativeRuntimeAvailable: boolean = false;
  private nativeHostControlReady: boolean = false;
  private nativeStreamingTransportReady: boolean = false;

  private pal(): Palette {
    return this.theme === 'light' ? buildLight(this.accentColor) : buildDark(this.accentColor);
  }

  private toolbarLayout(): MoonlightToolbarLayout {
    return moonlightToolbarLayout(this.isDesktopDevice, this.breakpoint, this.isPadDevice);
  }

  aboutToAppear(): void {
    this.pageActive = true;
    this.sheetReopenGeneration += 1;
    const params: Record<string, Object> = router.getParams() as Record<string, Object>;
    const route: MoonlightRouteIdentity = moonlightRouteIdentity(params, true);
    this.hostId = route.valid ? route.hostId : '';
    this.appId = route.valid ? route.appId : '';
    this.launchKey = {
      requestId: params['launchRequestId'] as number,
      generation: params['launchGeneration'] as number,
      ownerToken: params['launchOwnerToken'] as number
    };
    this.serverUuid = typeof params['serverUuid'] === 'string' ? params['serverUuid'] as string : '';
    this.numericAppId = typeof params['numericAppId'] === 'number' ? params['numericAppId'] as number : 0;
    this.hostAddress = typeof params['hostAddress'] === 'string' ? params['hostAddress'] as string : '';
    const routeStreamWidth: number = params['streamWidth'] as number;
    const routeStreamHeight: number = params['streamHeight'] as number;
    this.streamWidth = Number.isSafeInteger(routeStreamWidth) && routeStreamWidth >= 2 &&
      routeStreamWidth <= 32767 ? routeStreamWidth : 1920;
    this.streamHeight = Number.isSafeInteger(routeStreamHeight) && routeStreamHeight >= 2 &&
      routeStreamHeight <= 32767 ? routeStreamHeight : 1080;
    const routeBitrateKbps: number = params['streamBitrateKbps'] as number;
    this.configuredBitrateKbps = Number.isSafeInteger(routeBitrateKbps) &&
      routeBitrateKbps >= 1000 && routeBitrateKbps <= 200000 ? routeBitrateKbps : 20000;
    this.routeOwnerScopeFingerprint = typeof params['launchOwnerScopeFingerprint'] === 'string'
      ? params['launchOwnerScopeFingerprint'] as string : '';
    this.routeAccountGeneration = params['launchAccountGeneration'] as number;
    this.routeInstallationId = typeof params['launchInstallationId'] === 'string'
      ? params['launchInstallationId'] as string : '';
    this.routeStoreInstanceId = params['launchStoreInstanceId'] as number;
    this.xComponentController.onSurface = (surfaceId: string): void => {
      this.onMoonlightSurface(surfaceId);
    };
    this.xComponentController.onSurfaceDetached = (surfaceId: string): void => {
      this.onMoonlightSurfaceDestroyed(surfaceId);
    };
    this.scaleMode = this.commonDisplayScaleMode;
    this.phase = 'failed';
    this.errorCode = 'internal';
    this.degradationReasons = [];
    this.elapsedMs = 0;
    this.firstFrameSeen = false;
    this.inputReady = false;
    this.controllerReady = false;
    this.audioReady = false;
    this.inputSuspended = false;
    this.activeTouches.clear();
    this.sessionGeneration = 0;
    this.sessionStartedAtMs = 0;
    this.clearElapsedTimer();
    this.showConnectStage = true;
    this.phase = 'discovering';
    this.streamStartAttempted = false;
    this.sessionReserved = false;
    this.routeTerminated = false;
    this.nativeSurfaceAttached = false;
    this.reservedOwnerScopeId = '';
    this.reservedAccountGeneration = 0;
    const scope: AccountScopeToken = AccountSessionCoordinator.getInstance().currentScope();
    this.routeOwnerValidated = this.routeOwnerMatches(scope);
    if (!this.routeOwnerValidated) {
      this.phase = 'failed';
      this.errorCode = 'internal';
      this.routeTerminated = true;
      this.disposeLaunchOwner();
      return;
    }
    this.sessionCoordinator.bindScope(scope.ownerScopeId, scope.generation);
    this.bindSessionSnapshot(scope);
    this.reserveMoonlightSession(scope);
    this.accountScopeUnsubscribe = AccountSessionCoordinator.getInstance().onChange(
      (next: AccountScopeToken): void => {
        const reservationChanged: boolean = this.sessionReserved &&
          (next.ownerScopeId !== this.reservedOwnerScopeId ||
            next.generation !== this.reservedAccountGeneration);
        const routeOwnerChanged: boolean = !this.routeOwnerMatches(next);
        this.sessionCoordinator.bindScope(next.ownerScopeId, next.generation);
        this.bindSessionSnapshot(next);
        if (reservationChanged || routeOwnerChanged) {
          this.routeOwnerValidated = false;
          this.closeMoonlightRoute('owner-scope-changed');
        }
      });
  }

  aboutToDisappear(): void {
    this.pageActive = false;
    this.sheetReopenGeneration += 1;
    this.cancelSheetReopen();
    this.pendingSheetMode = 'none';
    this.showSessionSheet = false;
    this.closeMoonlightRoute('stream-page-disappear');
    this.clearElapsedTimer();
    if (this.snapshotUnsubscribe !== null) {
      this.snapshotUnsubscribe();
      this.snapshotUnsubscribe = null;
    }
    if (this.accountScopeUnsubscribe !== null) {
      this.accountScopeUnsubscribe();
      this.accountScopeUnsubscribe = null;
    }
  }

  private routeLeaseValid(): boolean {
    return this.routeOwnerValidated && !this.launchOwnerDisposed &&
      Number.isSafeInteger(this.launchKey.requestId) && this.launchKey.requestId > 0 &&
      Number.isSafeInteger(this.launchKey.generation) && this.launchKey.generation > 0 &&
      Number.isSafeInteger(this.launchKey.ownerToken) && this.launchKey.ownerToken > 0 &&
      this.serverUuid.trim() !== '' && Number.isSafeInteger(this.numericAppId) &&
      this.numericAppId > 0 && this.hostAddress.trim() !== '';
  }

  private routeOwnerMatches(scope: AccountScopeToken): boolean {
    if (!/^[0-9a-f]{64}$/.test(this.routeOwnerScopeFingerprint) ||
        !Number.isSafeInteger(this.routeAccountGeneration) || this.routeAccountGeneration <= 0 ||
        this.routeInstallationId.trim() === '' ||
        !Number.isSafeInteger(this.routeStoreInstanceId) || this.routeStoreInstanceId <= 0 ||
        scope.ownerScopeId.trim() === '' ||
        (this.reservedOwnerScopeId !== '' &&
          scope.ownerScopeId !== this.reservedOwnerScopeId)) {
      return false;
    }
    const lease: AccountSessionLease | null = CloudStore.getInstance().currentAccountLease();
    return lease !== null && CloudStore.getInstance().isLeaseCurrent(lease) &&
      lease.ownerScopeId === scope.ownerScopeId && lease.generation === scope.generation &&
      moonlightOwnerScopeFingerprint(lease.ownerScopeId) === this.routeOwnerScopeFingerprint &&
      lease.generation === this.routeAccountGeneration &&
      moonlightInstallationId(lease.storeIdentity) === this.routeInstallationId &&
      lease.storeInstanceId === this.routeStoreInstanceId;
  }

  private disposeLaunchOwner(): void {
    if (this.launchOwnerDisposed || !Number.isSafeInteger(this.launchKey.ownerToken) ||
        this.launchKey.ownerToken <= 0) { return; }
    this.launchOwnerDisposed = true;
    this.hostService.disposeOwner(this.launchKey.ownerToken);
  }

  private onMoonlightXComponentLoad = (): void => {
    if (!this.sessionReserved || this.routeTerminated) { return; }
    try { rdpnapi.registerNativeXComponent(); } catch (_) {}
    this.pollMoonlightSurface(0);
  }

  private pollMoonlightSurface(attempt: number): void {
    this.stopSurfacePoll();
    if (!this.pageActive || !this.sessionReserved || this.routeTerminated ||
        this.streamStartAttempted || attempt >= 80) { return; }
    try {
      const surface: string = this.xComponentController.getXComponentSurfaceId();
      if (surface.trim() !== '') { this.onMoonlightSurface(surface); return; }
    } catch (_) {}
    this.surfacePollTimer = setTimeout((): void => {
      this.surfacePollTimer = -1;
      this.pollMoonlightSurface(attempt + 1);
    }, 50);
  }

  private stopSurfacePoll(): void {
    if (this.surfacePollTimer >= 0) {
      clearTimeout(this.surfacePollTimer);
      this.surfacePollTimer = -1;
    }
  }

  private onMoonlightSurface(surfaceId: string): void {
    if (!this.pageActive || !this.sessionReserved || this.routeTerminated ||
        this.streamStartAttempted || !this.routeLeaseValid() ||
        surfaceId.trim() === '') { return; }
    this.surfaceId = surfaceId;
    try {
      if (!rdpnapi.setXComponentSurfaceId(
          surfaceId, this.surfaceWidthPx, this.surfaceHeightPx)) {
        this.closeMoonlightRoute('surface-bind-failed');
        return;
      }
      this.nativeSurfaceAttached = true;
      this.rendererHandle = rdpnapi.initRenderer(
        this.xcId, this.surfaceWidthPx, this.surfaceHeightPx);
    } catch (_) {
      this.rendererHandle = -1;
    }
    if (this.rendererHandle <= 0) {
      this.phase = 'failed'; this.errorCode = 'decoder_failed';
      this.closeMoonlightRoute('renderer-init-failed');
      return;
    }
    this.streamStartAttempted = true;
    const result = this.sessionCoordinator.start(this.sessionStartRequest(true));
    if (!result.accepted) {
      this.phase = 'failed'; this.errorCode = 'internal';
      if (this.pageActive) {
        promptAction.showToast({ message: '串流启动失败（' + result.code + '）', duration: 2200 });
      }
      this.closeMoonlightRoute('stream-start-failed');
    }
  }

  private reserveMoonlightSession(scope: AccountScopeToken): void {
    if (!this.pageActive || !this.routeLeaseValid() || this.hostId === '' || this.appId === '') {
      this.phase = 'failed';
      this.errorCode = 'internal';
      return;
    }
    try {
      const capabilities = rdpnapi.moonlightGetBridgeCapabilities();
      this.nativeRuntimeAvailable = capabilities.bridgeCompiled;
      this.nativeHostControlReady = capabilities.hostControlReady;
      this.nativeStreamingTransportReady = capabilities.transportReady;
    } catch (_) {
      this.nativeRuntimeAvailable = false;
      this.nativeHostControlReady = false;
      this.nativeStreamingTransportReady = false;
    }
    this.reservedOwnerScopeId = scope.ownerScopeId;
    this.reservedAccountGeneration = scope.generation;
    const result = this.sessionCoordinator.reserve(this.sessionStartRequest(false));
    this.sessionReserved = result.accepted;
    if (!result.accepted) {
      this.phase = 'failed';
      this.errorCode = 'internal';
      this.disposeLaunchOwner();
      this.routeTerminated = true;
    }
  }

  private sessionStartRequest(includeSurface: boolean): MoonlightSessionStartRequest {
    const request: MoonlightSessionStartRequest = {
      ownerScopeId: this.reservedOwnerScopeId,
      accountGeneration: this.reservedAccountGeneration,
      hostId: this.hostId,
      appId: this.appId,
      hostAddress: this.hostAddress,
      runtimeAvailable: this.nativeRuntimeAvailable,
      hostControlReady: this.nativeHostControlReady,
      streamingTransportReady: this.nativeStreamingTransportReady,
      hostControlAlreadyLaunched: true,
      launchKey: this.launchKey,
      serverUuid: this.serverUuid,
      numericAppId: this.numericAppId,
      configuredBitrateKbps: this.configuredBitrateKbps
    };
    if (includeSurface) {
      request.rendererHandle = this.rendererHandle;
      request.surfaceWidth = this.surfaceWidthPx;
      request.surfaceHeight = this.surfaceHeightPx;
      request.surfaceId = this.surfaceId;
    }
    return request;
  }

  private onMoonlightSurfaceDestroyed(surfaceId: string): void {
    if (this.routeTerminated || this.surfaceId !== '' &&
        surfaceId.trim() !== '' && surfaceId !== this.surfaceId) {
      return;
    }
    this.closeMoonlightRoute('surface-destroyed');
  }

  private closeMoonlightRoute(reason: string): void {
    if (this.routeTerminated) { return; }
    this.routeTerminated = true;
    this.stopSurfacePoll();
    this.flushInput(reason);
    if (this.showController) {
      this.setVirtualControllerMode(false, false);
      this.showController = false;
      this.controllerEditing = false;
    }
    this.setNativeInputSuspended(true, 'surface_detached');
    if (this.nativeSurfaceAttached) {
      try { rdpnapi.markXComponentSurfaceDestroyed(); } catch (_) {}
      this.nativeSurfaceAttached = false;
    }
    this.sessionCoordinator.cancelForRoute(this.hostId, this.appId, reason);
    this.disposeLaunchOwner();
    this.destroyMoonlightRenderer();
    this.sessionReserved = false;
    this.streamStartAttempted = true;
    this.surfaceId = '';
    this.inputReady = false;
    this.controllerReady = false;
    this.audioReady = false;
    if (this.pageActive) {
      this.phase = 'failed';
      this.errorCode = reason === 'renderer-init-failed' ? 'decoder_failed' : 'internal';
    }
  }

  private destroyMoonlightRenderer(): void {
    const handle: number = this.rendererHandle;
    this.rendererHandle = -1;
    if (handle > 0) {
      try { rdpnapi.destroyRenderer(handle); } catch (_) {}
    }
  }

  private nativeInputAvailable(): boolean {
    return this.inputReady && this.routeLeaseValid() && !this.inputSuspended;
  }

  private refreshNativeInputReadiness(): void {
    if (!this.routeLeaseValid()) {
      this.inputReady = false;
      this.controllerReady = false;
      return;
    }
    try {
      const source = rdpnapi.moonlightGetStreamSnapshot({
        requestId: this.launchKey.requestId,
        generation: this.launchKey.generation,
        ownerToken: this.launchKey.ownerToken
      });
      this.inputReady = source.matched && source.inputReady && !source.terminal;
      this.controllerReady = this.inputReady && source.controllerReady;
    } catch (_) {
      this.inputReady = false;
      this.controllerReady = false;
    }
  }

  private sendMoonlightKey(keyCode: number, pressed: boolean): boolean {
    if (!this.nativeInputAvailable() || !Number.isSafeInteger(keyCode) || keyCode < 0) { return false; }
    try {
      return rdpnapi.moonlightSendKey({
        launchKey: {
          requestId: this.launchKey.requestId,
          generation: this.launchKey.generation,
          ownerToken: this.launchKey.ownerToken
        },
        keyCode: keyCode,
        pressed: pressed,
        normalizedToUsLayout: true
      });
    } catch (_) { return false; }
  }

  private sendMoonlightPointer(request: MoonlightPointerInputRequest): boolean {
    if (!this.nativeInputAvailable()) { return false; }
    try {
      return rdpnapi.moonlightSendPointer({
        launchKey: {
          requestId: this.launchKey.requestId,
          generation: this.launchKey.generation,
          ownerToken: this.launchKey.ownerToken
        },
        action: request.action,
        x: request.x,
        y: request.y,
        contentLeft: request.contentLeft,
        contentTop: request.contentTop,
        contentWidth: request.contentWidth,
        contentHeight: request.contentHeight,
        referenceWidth: request.referenceWidth,
        referenceHeight: request.referenceHeight,
        geometryGeneration: request.geometryGeneration,
        button: request.button,
        pressed: request.pressed,
        horizontal: request.horizontal,
        scrollAmount: request.scrollAmount
      });
    } catch (_) { return false; }
  }

  private sendAbsolutePointer(x: number, y: number): boolean {
    const request: MoonlightPointerInputRequest = {
      launchKey: this.launchKey, action: 'absolute', x: x, y: y,
      contentLeft: 0, contentTop: 0,
      contentWidth: Math.max(1, this.surfaceWidthVp),
      contentHeight: Math.max(1, this.surfaceHeightVp),
      referenceWidth: this.streamWidth, referenceHeight: this.streamHeight,
      geometryGeneration: this.geometryGeneration
    };
    return this.sendMoonlightPointer(request);
  }

  private sendPointerButton(button: number, pressed: boolean): boolean {
    const request: MoonlightPointerInputRequest = {
      launchKey: this.launchKey, action: 'button', button: button, pressed: pressed
    };
    return this.sendMoonlightPointer(request);
  }

  private sendTouchPoint(contactId: number, phase: MoonlightTouchPhase,
    point: MoonlightTouchPoint): boolean {
    if (!this.nativeInputAvailable()) { return false; }
    try {
      return rdpnapi.moonlightSendTouch({
        launchKey: {
          requestId: this.launchKey.requestId,
          generation: this.launchKey.generation,
          ownerToken: this.launchKey.ownerToken
        },
        contactId: contactId,
        phase: phase,
        pointX: point.x,
        pointY: point.y,
        pressure: phase === 'up' || phase === 'cancel' ? 0 : 1,
        contactAreaMajor: 0,
        contactAreaMinor: 0,
        rotation: 0,
        contentLeft: 0,
        contentTop: 0,
        contentWidth: Math.max(1, this.surfaceWidthVp),
        contentHeight: Math.max(1, this.surfaceHeightVp),
        referenceWidth: this.streamWidth,
        referenceHeight: this.streamHeight,
        geometryGeneration: this.geometryGeneration,
        hitMapGeneration: this.hitMapGeneration
      });
    } catch (_) { return false; }
  }

  private setNativeInputSuspended(suspended: boolean,
    reason: MoonlightInputLifecycleReason): boolean {
    if (this.inputSuspended === suspended) { return true; }
    if (!this.inputReady || !this.routeLeaseValid()) {
      if (suspended) { this.inputSuspended = true; }
      return false;
    }
    try {
      const accepted: boolean = rdpnapi.moonlightSetInputSuspended({
        launchKey: {
          requestId: this.launchKey.requestId,
          generation: this.launchKey.generation,
          ownerToken: this.launchKey.ownerToken
        },
        reason: reason,
        suspended: suspended
      });
      if (accepted || suspended) { this.inputSuspended = suspended; }
      return accepted;
    } catch (_) {
      if (suspended) { this.inputSuspended = true; }
      return false;
    }
  }

  private setNativeTouchMode(mode: MoonlightControlMode): boolean {
    if (!this.inputReady || !this.routeLeaseValid()) { return false; }
    try {
      return rdpnapi.moonlightSetTouchMode({
        launchKey: {
          requestId: this.launchKey.requestId,
          generation: this.launchKey.generation,
          ownerToken: this.launchKey.ownerToken
        },
        direct: mode === 'touch'
      });
    } catch (_) { return false; }
  }

  private setVirtualControllerMode(enabled: boolean, editing: boolean): boolean {
    if (!this.inputReady || !this.controllerReady || !this.routeLeaseValid()) { return false; }
    try {
      return rdpnapi.moonlightSetVirtualControllerMode({
        launchKey: {
          requestId: this.launchKey.requestId,
          generation: this.launchKey.generation,
          ownerToken: this.launchKey.ownerToken
        },
        enabled: enabled,
        editing: editing
      });
    } catch (_) { return false; }
  }

  private sendVirtualController(event: MoonlightControllerSemanticEvent): boolean {
    if (!this.nativeInputAvailable() || !this.controllerReady ||
      !this.showController || this.controllerEditing) { return false; }
    try {
      return rdpnapi.moonlightSendVirtualController({
        launchKey: {
          requestId: this.launchKey.requestId,
          generation: this.launchKey.generation,
          ownerToken: this.launchKey.ownerToken
        },
        element: event.element,
        phase: event.phase,
        pointerId: event.pointerId,
        primary: event.primary,
        secondary: event.secondary
      });
    } catch (_) { return false; }
  }

  private handleVirtualControllerEvent(event: MoonlightControllerSemanticEvent): void {
    if (this.sendVirtualController(event)) { return; }
    if (event.phase !== 'end' && event.phase !== 'cancel') { return; }
    // Never hide a terminal input failure. Force the native controller lane
    // through its neutral/disconnect boundary; if even that cannot be queued,
    // suspend the entire input owner and keep the overlay visible for retry.
    if (this.setVirtualControllerMode(false, false)) {
      this.controllerEditing = false;
      this.showController = false;
      promptAction.showToast({ message: '控制器输入拥塞，已安全复位', duration: 1800 });
      return;
    }
    this.setNativeInputSuspended(true, 'overlay_opened');
    promptAction.showToast({ message: '控制器正在安全释放，请稍后重试', duration: 1800 });
  }

  private closeVirtualController(): void {
    this.flushInput('controller_close');
    if (!this.setVirtualControllerMode(false, false)) {
      this.setNativeInputSuspended(true, 'overlay_opened');
      promptAction.showToast({ message: '控制器正在安全释放，请稍后重试', duration: 1800 });
      return;
    }
    this.controllerEditing = false;
    this.showController = false;
  }

  private moonlightTouchPhase(event: TouchEvent): MoonlightTouchPhase {
    if (event.type === TouchType.Down) { return 'down'; }
    if (event.type === TouchType.Up) { return 'up'; }
    if (event.type === TouchType.Cancel) { return 'cancel'; }
    return 'move';
  }

  private handleMoonlightTouch = (event: TouchEvent): void => {
    if (!this.nativeInputAvailable()) { return; }
    event.stopPropagation();
    const phase: MoonlightTouchPhase = this.moonlightTouchPhase(event);
    if (phase === 'cancel' && event.changedTouches.length === 0) {
      this.activeTouches.forEach((point: MoonlightTouchPoint, id: number): void => {
        this.sendTouchPoint(id, 'cancel', point);
      });
      this.activeTouches.clear();
      return;
    }
    const points = event.changedTouches.length > 0 ? event.changedTouches : event.touches;
    for (let index: number = 0; index < points.length; index++) {
      const id: number = Math.max(1, Math.floor(points[index].id) + 1);
      const point: MoonlightTouchPoint = { x: points[index].x, y: points[index].y };
      this.sendTouchPoint(id, phase, point);
      if (phase === 'up' || phase === 'cancel') { this.activeTouches.delete(id); }
      else { this.activeTouches.set(id, point); }
    }
  }

  private handleMoonlightKey = (event: KeyEvent): boolean => {
    if (!this.nativeInputAvailable()) { return false; }
    const pressed: boolean = event.type === KeyType.Down;
    if (!pressed && event.type !== KeyType.Up) { return false; }
    event.stopPropagation();
    return this.sendMoonlightKey(event.keyCode, pressed);
  }

  private moonlightPointerButton(raw: number): number {
    if (raw === MouseButton.Left || raw === 1) { return 1; }
    if (raw === MouseButton.Middle || raw === 4) { return 2; }
    if (raw === MouseButton.Right || raw === 2) { return 3; }
    return 0;
  }

  private handleMoonlightMouse = (event: MouseEvent): void => {
    if (!this.nativeInputAvailable() ||
      (event.sourceTool !== SourceTool.MOUSE && event.sourceTool !== SourceTool.TOUCHPAD)) { return; }
    event.stopPropagation();
    if (event.action === MouseAction.Move || event.action === MouseAction.Hover) {
      this.sendAbsolutePointer(event.x as number, event.y as number);
      return;
    }
    if (event.action === MouseAction.Press || event.action === MouseAction.Release) {
      const button: number = this.moonlightPointerButton(event.button as number);
      if (button <= 0) { return; }
      this.sendAbsolutePointer(event.x as number, event.y as number);
      this.sendPointerButton(button, event.action === MouseAction.Press);
    }
  }

  private handleMoonlightAxis = (event?: AxisEvent): void => {
    if (!event || !this.nativeInputAvailable()) { return; }
    const vertical: number = event.getVerticalAxisValue();
    const horizontal: number = event.getHorizontalAxisValue();
    const raw: number = Math.abs(vertical) >= Math.abs(horizontal) ? vertical : horizontal;
    if (!Number.isFinite(raw) || raw === 0) { return; }
    const amount: number = Math.max(-32768, Math.min(32767, Math.round(raw * 120)));
    const request: MoonlightPointerInputRequest = {
      launchKey: this.launchKey, action: 'scroll',
      horizontal: Math.abs(horizontal) > Math.abs(vertical), scrollAmount: amount
    };
    this.sendMoonlightPointer(request);
  }

  private bindSessionSnapshot(scope: AccountScopeToken): void {
    if (this.snapshotUnsubscribe !== null) {
      this.snapshotUnsubscribe();
      this.snapshotUnsubscribe = null;
    }
    if (this.hostId === '' || this.appId === '') {
      this.applySessionSnapshot(null);
      return;
    }
    this.snapshotUnsubscribe = this.sessionCoordinator.subscribeForRoute(
      scope.ownerScopeId, scope.generation, this.hostId, this.appId,
      (snapshot: MoonlightSessionStateSnapshot | null): void => {
        this.applySessionSnapshot(snapshot);
      });
  }

  private applySessionSnapshot(snapshot: MoonlightSessionStateSnapshot | null): void {
    if (!this.pageActive) { return; }
    if (snapshot === null) {
      this.phase = 'failed';
      this.errorCode = 'internal';
      this.degradationReasons = [];
      this.elapsedMs = 0;
      this.firstFrameSeen = false;
      this.inputReady = false;
      this.controllerReady = false;
      this.audioReady = false;
      this.inputSuspended = false;
      this.sessionGeneration = 0;
      this.sessionStartedAtMs = 0;
      this.showConnectStage = true;
      this.clearElapsedTimer();
      return;
    }
    if (snapshot.generation !== this.sessionGeneration) {
      this.sessionGeneration = snapshot.generation;
      this.sessionStartedAtMs = Date.now();
      this.elapsedMs = 0;
    }
    this.phase = snapshot.phase;
    this.errorCode = snapshot.errorCode;
    this.degradationReasons = snapshot.degradationReasons.slice();
    this.firstFrameSeen = snapshot.firstFrameSeen;
    this.audioReady = snapshot.audioReady;
    if (snapshot.inputReady) { this.refreshNativeInputReadiness(); }
    else { this.inputReady = false; this.controllerReady = false; }
    this.showConnectStage = !snapshot.firstFrameSeen && snapshot.phase !== 'streaming';
    if (this.sessionStartedAtMs > 0) {
      this.elapsedMs = Math.max(0, Date.now() - this.sessionStartedAtMs);
    }
    if (this.showConnectStage && snapshot.phase !== 'failed' && snapshot.phase !== 'disconnected') {
      this.scheduleElapsedTick();
    } else {
      this.clearElapsedTimer();
    }
  }

  private scheduleElapsedTick(): void {
    if (!this.pageActive || this.elapsedTimer >= 0 || this.sessionStartedAtMs <= 0 ||
      this.firstFrameSeen || this.phase === 'failed' || this.phase === 'disconnected') {
      return;
    }
    this.elapsedTimer = setTimeout((): void => {
      this.elapsedTimer = -1;
      if (!this.pageActive || this.sessionStartedAtMs <= 0) { return; }
      this.elapsedMs = Math.max(0, Date.now() - this.sessionStartedAtMs);
      this.scheduleElapsedTick();
    }, 250);
  }

  private clearElapsedTimer(): void {
    if (this.elapsedTimer >= 0) {
      clearTimeout(this.elapsedTimer);
      this.elapsedTimer = -1;
    }
  }

  private cancelConnection(): void {
    const result = this.sessionCoordinator.cancelForRoute(
      this.hostId, this.appId, 'connect-stage-cancel');
    if (result.code === 'stop_requested') {
      promptAction.showToast({ message: '正在安全取消连接', duration: 1400 });
    }
    this.flushInput('cancel_connect');
    router.back();
  }

  private retryConnection(): void {
    promptAction.showToast({ message: '请返回应用目录重新建立安全启动租约', duration: 2000 });
  }

  private flushInput(reason: string): void {
    const wasSuspended: boolean = this.inputSuspended;
    if (!wasSuspended) { this.setNativeInputSuspended(true, 'overlay_opened'); }
    this.inputFlushCount += 1;
    this.ctrlLatch = 'off'; this.altLatch = 'off'; this.shiftLatch = 'off'; this.winLatch = 'off';
    this.fnLayer = false;
    this.activeTouches.clear();
    if (!wasSuspended) { this.setNativeInputSuspended(false, 'overlay_opened'); }
    hilog.info(0x0014, 'MoonlightStreamUi',
      'input local state cleared reason=' + reason + ' count=' + this.inputFlushCount.toString());
  }

  private pipAvailable(): boolean {
    return this.pipRuntimeAvailable && this.liveViewEnabled && this.liveViewMode === 1;
  }

  private openSheet(mode: MoonlightSessionSheetMode): void {
    this.flushInput('open_l5_' + mode);
    this.setNativeInputSuspended(true, 'overlay_opened');
    if (this.showSessionSheet) {
      this.pendingSheetMode = mode;
      this.showSessionSheet = false;
      return;
    }
    this.sheetMode = mode;
    this.showSessionSheet = true;
  }

  private closeSheet(): void {
    this.pendingSheetMode = 'none';
    this.sheetReopenGeneration += 1;
    this.cancelSheetReopen();
    this.showSessionSheet = false;
  }

  private cancelSheetReopen(): void {
    if (this.sheetReopenTimer >= 0) {
      clearTimeout(this.sheetReopenTimer);
      this.sheetReopenTimer = -1;
    }
  }

  private onSheetDisappear(): void {
    if (this.pendingSheetMode !== 'none') {
      const next: MoonlightSessionSheetMode = this.pendingSheetMode;
      this.pendingSheetMode = 'none';
      this.sheetMode = next;
      const generation: number = this.sheetReopenGeneration;
      this.cancelSheetReopen();
      this.sheetReopenTimer = setTimeout((): void => {
        this.sheetReopenTimer = -1;
        if (this.pageActive && generation === this.sheetReopenGeneration) {
          this.showSessionSheet = true;
        }
      }, 0);
      return;
    }
    this.sheetMode = 'none';
    this.setNativeInputSuspended(false, 'overlay_opened');
  }

  private toolbarAction(action: MoonlightToolbarAction): void {
    if (action === 'more') { this.openSheet('control'); return; }
    if (action === 'disconnect') { this.openSheet('stop'); return; }
    if (action === 'controller') {
      this.flushInput('open_controller');
      if (this.setVirtualControllerMode(true, false)) {
        this.controllerEditing = false;
        this.showController = true;
      } else {
        promptAction.showToast({ message: '手柄输入尚未就绪', duration: 1600 });
      }
      return;
    }
    if (action === 'keyboard') {
      this.flushInput('open_keyboard');
      promptAction.showToast({ message: '虚拟键盘将在真实会话输入 owner 就绪后打开', duration: 1800 });
      return;
    }
    if (action === 'control') {
      const nextMode: MoonlightControlMode = this.controlMode === 'touch' ? 'trackpad' : 'touch';
      if (this.setNativeTouchMode(nextMode)) {
        this.controlMode = nextMode;
        this.sessionChanges += 1;
        promptAction.showToast({ message: '已切换为' + (this.controlMode === 'touch' ? '直接触控' : '触控板'),
          duration: 1400 });
      } else {
        promptAction.showToast({ message: nextMode === 'touch' ? '当前主机不支持直接触控' : '输入尚未就绪',
          duration: 1600 });
      }
      return;
    }
    if (action === 'audio') { this.muted = !this.muted; this.sessionChanges += 1; return; }
    if (action === 'display') {
      promptAction.showToast({ message: '首帧与系统 PIP 能力通过后可用', duration: 1800 });
    }
  }

  private modifierNext(current: string): string {
    if (current === 'off') { return 'once'; }
    if (current === 'once') { return 'locked'; }
    return 'off';
  }

  private toggleModifier(mod: string): void {
    let current: string = 'off';
    let keyCode: number = 0;
    if (mod === 'ctrl') { current = this.ctrlLatch; keyCode = 2072; }
    else if (mod === 'alt') { current = this.altLatch; keyCode = 2045; }
    else if (mod === 'shift') { current = this.shiftLatch; keyCode = 2047; }
    else if (mod === 'win') { current = this.winLatch; keyCode = 2076; }
    if (keyCode === 0) { return; }
    const next: string = this.modifierNext(current);
    if (current === 'off') { this.sendMoonlightKey(keyCode, true); }
    else if (next === 'off') { this.sendMoonlightKey(keyCode, false); }
    if (mod === 'ctrl') { this.ctrlLatch = next; }
    else if (mod === 'alt') { this.altLatch = next; }
    else if (mod === 'shift') { this.shiftLatch = next; }
    else { this.winLatch = next; }
  }

  private releaseOnceModifiers(): void {
    if (this.ctrlLatch === 'once') { this.sendMoonlightKey(2072, false); this.ctrlLatch = 'off'; }
    if (this.altLatch === 'once') { this.sendMoonlightKey(2045, false); this.altLatch = 'off'; }
    if (this.shiftLatch === 'once') { this.sendMoonlightKey(2047, false); this.shiftLatch = 'off'; }
    if (this.winLatch === 'once') { this.sendMoonlightKey(2076, false); this.winLatch = 'off'; }
  }

  @Builder private controlCenterSheet() {
    MoonlightControlCenter({
      hostName: this.hostId || '未绑定主机', appName: this.appId || 'Moonlight UI',
      durationLabel: Math.floor(this.elapsedMs / 1000).toString() + ' 秒',
      negotiatedSummary: this.firstFrameSeen ?
        this.streamWidth.toString() + '×' + this.streamHeight.toString() : '正在协商串流',
      controlMode: this.controlMode, muted: this.muted, volume: this.volume,
      scaleMode: this.scaleMode, latencyMode: this.latencyMode,
      diagnosticsEnabled: this.showDiagnostics, sessionChangeCount: this.sessionChanges,
      pipAvailable: this.pipAvailable(), controllerAvailable: this.controllerReady,
      onClose: (): void => { this.closeSheet(); },
      onOpenKeyboard: (): void => { this.closeSheet(); this.toolbarAction('keyboard'); },
      onOpenModifiers: (): void => {
        this.closeSheet(); this.flushInput('open_modifier_panel'); this.showModifierPanel = true;
      },
      onCopyDiagnostics: (): void => {
        this.closeSheet();
        promptAction.showToast({ message: '暂无真实会话指标，未复制任何敏感信息', duration: 1600 });
      },
      onOpenController: (): void => { this.closeSheet(); this.toolbarAction('controller'); },
      onControlMode: (mode: MoonlightControlMode): void => {
        if (this.setNativeTouchMode(mode)) {
          this.controlMode = mode; this.sessionChanges += 1;
        }
      },
      onToggleMute: (): void => { this.muted = !this.muted; this.sessionChanges += 1; },
      onVolume: (value: number): void => { this.volume = value; this.sessionChanges += 1; },
      onScaleMode: (mode: string): void => { this.scaleMode = mode; this.sessionChanges += 1; },
      onLatencyMode: (mode: string): void => { this.latencyMode = mode; this.sessionChanges += 1; },
      onToggleDiagnostics: (): void => { this.showDiagnostics = !this.showDiagnostics; },
      onReconnect: (): void => { this.closeSheet(); this.flushInput('reconnect'); this.showReconnectMask = true; },
      onDisconnect: (): void => { this.openSheet('stop'); },
      onQuitHostApp: (): void => { this.openSheet('stop'); },
      onSaveProfile: (): void => {
        promptAction.showToast({ message: '真实会话 profile owner 就绪后可保存', duration: 1800 });
      }
    })
  }

  @Builder private stopSheet() {
    Column() {
      Text('结束 Moonlight 串流？').fontSize(20).fontWeight(FontWeight.Bold).fontColor(this.pal().text)
      Text('默认只断开本地串流并保留主机应用。主机退出结果不阻塞本地资源清理。')
        .fontSize(12).fontColor(this.pal().text3).lineHeight(18).margin({ top: 8 })
      Button('仅断开并保留主机应用').height(46).width('100%').borderRadius(13).fontSize(13)
        .backgroundColor(this.accentColor).fontColor(Color.White).margin({ top: 20 })
        .onClick((): void => {
          this.flushInput('disconnect_local'); this.closeSheet(); router.back();
        })
      Button('同时退出主机应用').height(46).width('100%').borderRadius(13).fontSize(13)
        .backgroundColor(this.pal().danger + '16').fontColor(this.pal().danger).margin({ top: 9 })
        .onClick((): void => {
          this.flushInput('quit_host_app'); this.closeSheet(); router.back();
        })
      Button('取消').height(42).width('100%').borderRadius(12).fontSize(13)
        .backgroundColor(this.pal().surface).fontColor(this.pal().text2).margin({ top: 9 })
        .onClick((): void => { this.closeSheet(); })
    }.width('100%').padding(22).backgroundColor(this.pal().sheetBg)
      .borderRadius({ topLeft: 24, topRight: 24, bottomLeft: 0, bottomRight: 0 })
      .border({ width: 0.5, color: this.pal().cardBorder })
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
  }

  @Builder private sessionSheet() {
    if (this.sheetMode === 'control') { this.controlCenterSheet() }
    else if (this.sheetMode === 'stop') { this.stopSheet() }
    else { Column().width('100%').height(1) }
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      XComponent({ id: this.xcId, type: XComponentType.SURFACE,
        libraryname: 'rdpnapi', controller: this.xComponentController })
        .width('100%').height('100%').backgroundColor('#000000')
        .focusable(true).focusOnTouch(true)
        .onLoad(this.onMoonlightXComponentLoad)
        .onTouch(this.handleMoonlightTouch)
        .onKeyEvent(this.handleMoonlightKey)
        .onMouse(this.handleMoonlightMouse)
        .onAxisEvent(this.handleMoonlightAxis)
        .onAreaChange((_oldArea: Area, newArea: Area): void => {
          this.surfaceWidthVp = Math.max(1, newArea.width as number);
          this.surfaceHeightVp = Math.max(1, newArea.height as number);
          const width: number = Math.max(1, Math.round(vp2px(this.surfaceWidthVp)));
          const height: number = Math.max(1, Math.round(vp2px(this.surfaceHeightVp)));
          this.surfaceWidthPx = width; this.surfaceHeightPx = height;
          this.geometryGeneration += 1;
          if (this.rendererHandle > 0) {
            try { rdpnapi.resizeRenderer(this.rendererHandle, width, height); } catch (_) {}
          }
        })

      if (this.showAudioBanner) {
        Row() {
          SymbolGlyph($r('sys.symbol.speaker_slash_fill')).fontSize(16).fontColor(['#FFFFFF'])
          Text('音频已暂停：其他应用正在播放').fontSize(11).fontColor('#FFFFFF').margin({ left: 8 })
          Button('恢复').height(30).fontSize(10).borderRadius(9).margin({ left: 10 })
            .backgroundColor('rgba(255,255,255,0.14)').fontColor('#FFFFFF')
            .onClick((): void => { this.showAudioBanner = false; })
        }.padding({ left: 12, right: 8, top: 7, bottom: 7 })
          .backgroundColor('rgba(14,18,28,0.86)').borderRadius(13).position({ x: 20, y: 22 })
      }

      if (this.showNetworkBanner) {
        Row() {
          Column() {
            Text('网络持续波动').fontSize(12).fontWeight(FontWeight.Medium).fontColor('#FFFFFF')
            Text('可降低码率或打开诊断').fontSize(10).fontColor('rgba(255,255,255,0.62)').margin({ top: 3 })
          }.alignItems(HorizontalAlign.Start)
          Button('降低码率').height(32).fontSize(10).borderRadius(9).margin({ left: 12 })
            .backgroundColor(this.accentColor).fontColor('#FFFFFF')
            .onClick((): void => { this.sessionChanges += 1; this.showNetworkBanner = false; })
        }.padding(10).backgroundColor('rgba(14,18,28,0.88)').borderRadius(13).position({ x: 20, y: 70 })
      }

      MoonlightSessionToolbar({
        audioAvailable: this.audioReady, controllerAvailable: this.controllerReady,
        pipAvailable: this.pipAvailable(),
        menuOpen: this.showSessionSheet,
        qualityColor: this.showReconnectMask ? '#FFCF70' : '#66DD7A',
        qualityLabel: this.showReconnectMask ? '正在重连' : '良好',
        onAction: (action: MoonlightToolbarAction): void => { this.toolbarAction(action); },
        onUnavailable: (reason: string): void => {
          promptAction.showToast({ message: reason, duration: 1800 });
        }
      }).align(this.toolbarLayout().edgeRail ? Alignment.TopEnd : Alignment.Top)
        .margin({ top: this.toolbarLayout().topOffset,
          right: this.toolbarLayout().edgeRail ? 4 : 0 })

      RemoteModifierHandle({
        handleX: 0, handleY: 330, handleSide: 'left', panelVisible: this.showModifierPanel,
        ctrlLocked: this.ctrlLatch === 'locked', altLocked: this.altLatch === 'locked',
        shiftLocked: this.shiftLatch === 'locked', winLocked: this.winLatch === 'locked',
        fnLayer: this.fnLayer,
        onTogglePanel: (): void => { this.flushInput('toggle_modifier'); this.showModifierPanel = !this.showModifierPanel; },
        onLongPress: (): void => { this.flushInput('toggle_shortcuts'); this.showShortcutPanel = !this.showShortcutPanel; }
      })

      RemoteModifierPanel({
        visible: this.showModifierPanel, shortcutVisible: this.showShortcutPanel, attachSide: 'left',
        ctrlLatch: this.ctrlLatch, altLatch: this.altLatch, shiftLatch: this.shiftLatch,
        winLatch: this.winLatch, fnLayer: this.fnLayer, panelX: 60, panelY: 300,
        shortcutX: 60, shortcutY: 180,
        onClose: (): void => { this.flushInput('close_modifier'); this.showModifierPanel = false; },
        onCloseShortcut: (): void => { this.flushInput('close_shortcut'); this.showShortcutPanel = false; },
        onToggleModifier: (mod: string): void => { this.toggleModifier(mod); },
        onLockModifier: (mod: string): void => { this.toggleModifier(mod); this.toggleModifier(mod); },
        onToggleFnLayer: (): void => { this.fnLayer = !this.fnLayer; },
        onKeyTap: (keyCode: number, _label: string): void => {
          this.sendMoonlightKey(keyCode, true);
          this.sendMoonlightKey(keyCode, false);
          this.releaseOnceModifiers();
        },
        onShortcutTap: (keyCodes: number[], _label: string): void => {
          for (let index: number = 0; index < keyCodes.length; index++) {
            this.sendMoonlightKey(keyCodes[index], true);
          }
          for (let index: number = keyCodes.length - 1; index >= 0; index--) {
            this.sendMoonlightKey(keyCodes[index], false);
          }
          this.releaseOnceModifiers();
        }
      })

      if (this.showDiagnostics) {
        MoonlightDiagnosticsHud({
          snapshot: EMPTY_SNAPSHOT, expanded: this.diagnosticsExpanded,
          x: this.diagnosticsX, y: this.diagnosticsY,
          onToggle: (): void => { this.diagnosticsExpanded = !this.diagnosticsExpanded; },
          onPositionChange: (x: number, y: number): void => {
            this.diagnosticsX = Math.max(0, x); this.diagnosticsY = Math.max(0, y);
          },
          onCopySanitized: (): void => {
            promptAction.showToast({ message: '暂无真实会话指标', duration: 1600 });
          }
        })
      }

      if (this.showController) {
        MoonlightControllerOverlay({
          inputCapabilityReady: this.inputReady && this.controllerReady,
          editing: this.controllerEditing,
          physicalControllerName: '', physicalControllerSlot: -1,
          onSemanticEvent: (event: MoonlightControllerSemanticEvent): void => {
            this.handleVirtualControllerEvent(event);
          },
          onEditToggle: (): void => {
            this.flushInput('controller_edit');
            const nextEditing: boolean = !this.controllerEditing;
            if (this.setVirtualControllerMode(true, nextEditing)) {
              this.controllerEditing = nextEditing;
            }
          },
          onClose: (): void => {
            this.closeVirtualController();
          }
        })
      }

      if (this.showReconnectMask) {
        Column() {
          Text('画面已暂停').fontSize(18).fontWeight(FontWeight.Bold).fontColor('#FFFFFF')
          Text('正在停止旧 generation，输入已冻结').fontSize(11)
            .fontColor('rgba(255,255,255,0.68)').margin({ top: 6 })
          Row({ space: 10 }) {
            Button('立即重试').height(40).fontSize(12).borderRadius(11)
              .backgroundColor(this.accentColor).fontColor('#FFFFFF')
              .onClick((): void => { this.showReconnectMask = false; })
            Button('退出').height(40).fontSize(12).borderRadius(11)
              .backgroundColor('rgba(255,255,255,0.12)').fontColor('#FFFFFF')
              .onClick((): void => { this.openSheet('stop'); })
          }.margin({ top: 14 })
        }.width('82%').constraintSize({ maxWidth: 440 }).padding(20)
          .backgroundColor('rgba(14,18,28,0.92)').borderRadius(20)
          .border({ width: 1, color: 'rgba(255,255,255,0.16)' })
      }

      if (this.showConnectStage) {
        MoonlightConnectStageOverlay({
          phase: this.phase, elapsedMs: this.elapsedMs, firstFrameSeen: this.firstFrameSeen,
          errorCode: this.errorCode, degradationReasons: this.degradationReasons,
          onCancel: (): void => { this.cancelConnection(); },
          onRetry: (): void => { this.retryConnection(); },
          onDowngradeRetry: (): void => { this.retryConnection(); },
          onOpenDiagnostics: (): void => { this.showDiagnostics = true; },
          onBackToCatalog: (): void => { this.flushInput('back_to_catalog'); router.back(); }
        })
      }
    }.width('100%').height('100%').backgroundColor('#000000')
      .bindSheet($$this.showSessionSheet, this.sessionSheet(), {
        height: this.sheetMode === 'control' ? '86%' : SheetSize.FIT_CONTENT,
        preferType: this.breakpoint === 'sm' ? SheetType.BOTTOM : SheetType.CENTER,
        dragBar: false, showClose: false,
        onDisappear: (): void => { this.onSheetDisappear(); }
      })
  }
}
