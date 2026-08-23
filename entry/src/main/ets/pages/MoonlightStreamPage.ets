import { promptAction, router } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { connection } from '@kit.NetworkKit';
import { KeyCode } from '@kit.InputKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { Palette, buildDark, buildLight } from '../common/Theme';
import { guideDeviceFor, GuideDevice } from '../services/GuideContentRegistry';
import {
  SessionContextualGuide,
  sessionContextualGuide,
  shouldRetrySessionContextualGuide,
  shouldShowSessionContextualGuide
} from '../services/SessionContextualGuidePolicy';
import { GUIDE_ALWAYS_VISIBLE_STORAGE_KEY } from '../services/GuideVisibilityPolicy';
import { GuideVisibilityService } from '../services/GuideVisibilityService';
import { MoonlightConnectStageOverlay } from '../components/moonlight/MoonlightConnectStageOverlay';
import { MoonlightDiagnosticsHud } from '../components/moonlight/MoonlightDiagnosticsHud';
import { MoonlightControlCenter, MoonlightControlMode } from '../components/moonlight/MoonlightControlCenter';
import {
  MoonlightControllerOverlay,
  MoonlightControllerSemanticEvent
} from '../components/moonlight/MoonlightControllerOverlay';
import { MoonlightSessionToolbar } from '../components/moonlight/MoonlightSessionToolbar';
import { RemoteSessionFullscreenButton } from '../components/RemoteSessionFullscreenButton';
import { RemoteModifierHandle } from '../components/RemoteModifierHandle';
import { RemoteModifierPanel } from '../components/RemoteModifierPanel';
import {
  MoonlightEffectiveSettings,
  MoonlightSettings,
  defaultMoonlightSettings
} from '../model/MoonlightModels';
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
  MoonlightRouteIdentity,
  MoonlightToolbarLayout,
  MoonlightToolbarAction,
  MoonlightDiagnosticsSnapshot,
  moonlightRouteIdentity,
  moonlightToolbarLayout
} from '../services/MoonlightUiPolicy';
import rdpnapi from 'librdpnapi.so';
import {
  MoonlightHostService,
  MoonlightHostContext,
  MoonlightHostServiceResult,
  MoonlightNativeLaunchConfiguration,
  MoonlightNativeRequestKey
} from '../services/MoonlightHostService';
import {
  moonlightInstallationId,
  moonlightOwnerScopeFingerprint
} from '../services/MoonlightRuntimeSupport';
import { decodeMoonlightEffectiveSettings } from '../services/MoonlightSettingsPolicy';
import {
  RemoteSessionBackgroundTaskService,
  RemoteSessionBgInfo
} from '../services/RemoteSessionBackgroundTaskService';
import {
  RemoteSessionLiveViewService,
  LiveViewConnectionInfo
} from '../services/RemoteSessionLiveViewService';
import { LiveViewMode } from '../services/LiveViewTypes';
import {
  RemoteSessionPipService,
  RemoteSessionPipSurface
} from '../services/RemoteSessionPipService';
import {
  RemoteSessionPipContentSize,
  resolveRemoteSessionPipContentSize,
  shouldPrepareRemoteSessionPip
} from '../services/RemoteSessionPipLifecyclePolicy';
import {
  RemoteSessionServiceLease,
  cloneRemoteSessionServiceLease,
  remoteSessionServiceLeaseEquals
} from '../services/RemoteSessionServiceLeasePolicy';
import {
  MoonlightNetworkBinding,
  moonlightNetIdIsValid,
  moonlightNetworkCallbackSessionId,
  moonlightNetworkAvailableMatchesDefault,
  moonlightNetworkLostMatches,
  shouldResumeMoonlightInputAfterNetworkAvailable
} from '../services/MoonlightNetworkHandlePolicy';
import {
  MoonlightHostLocalView,
  MoonlightLocalViewService
} from '../services/MoonlightLocalViewService';
import {
  MoonlightReconnectDecision,
  MoonlightReconnectWindow,
  createMoonlightReconnectWindow,
  moonlightReconnectAfterFailure,
  moonlightReconnectAttemptTimeoutMs,
  moonlightReconnectDecision,
  moonlightReconnectWindowIsCurrent
} from '../services/MoonlightReconnectPolicy';
import {
  MoonlightRuntimeOwnerTokenAllocator,
  moonlightLaunchConfiguration,
  moonlightRuntimeContext,
  moonlightSelectedHostAddress
} from '../services/MoonlightRuntimeContextFactory';
import { RemoteSessionWindowCoordinator } from '../services/RemoteSessionWindowCoordinator';
import {
  MoonlightSessionRecoveryRuntime
} from '../services/MoonlightSessionRecoveryRuntime';
import {
  MoonlightSessionRecoveryTerminalAction
} from '../services/MoonlightSessionRecoveryPolicy';
import {
  REMOTE_IME_PREVIEW_ENABLED,
  RemoteImeSelectionAction,
  createRemoteImeShadow,
  resolveRemoteImeDelete,
  resolveRemoteImeSelection,
  shouldAcceptRemoteImeTextChange,
  shouldRecenterRemoteImeShadow
} from '../services/RemoteImeSessionPolicy';
import {
  RemoteImeCommand,
  RemoteImeCommandKind,
  RemoteImeCommandQueue
} from '../services/RemoteImeCommandQueue';

const MOONLIGHT_KEYCODE_DPAD_LEFT = 2014;
const MOONLIGHT_KEYCODE_DPAD_RIGHT = 2015;
const MOONLIGHT_KEYCODE_TAB = 2049;
const MOONLIGHT_KEYCODE_ENTER = 2054;
const MOONLIGHT_KEYCODE_DEL = 2055;
const MOONLIGHT_KEYCODE_ESCAPE = 2070;
const MOONLIGHT_KEYCODE_FORWARD_DEL = 2071;
const MOONLIGHT_IME_SELECTION_ACK_TIMEOUT_MS = 600;
const MOONLIGHT_IME_COMMAND_RETRY_MS = 50;

const EMPTY_MOONLIGHT_DIAGNOSTICS: MoonlightDiagnosticsSnapshot = {
  available: false, fps: -1, latencyMs: -1, bitrateKbps: -1,
  packetLossPercent: -1, codec: '', width: 0, height: 0,
  decodeP50Us: -1, decodeP95Us: -1, renderP50Us: -1, renderP95Us: -1,
  audioUnderruns: -1, inputDrops: -1
};

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

@Entry
@Component
struct MoonlightStreamPage {
  @StorageLink('currentTheme') theme: string = 'light';
  @StorageLink('accentColor') accentColor: string = '#007DFF';
  @StorageProp('currentBreakpoint') breakpoint: string = 'sm';
  @StorageProp('isDesktopDevice') isDesktopDevice: boolean = false;
  @StorageProp('isPadDevice') isPadDevice: boolean = false;
  @StorageProp(GUIDE_ALWAYS_VISIBLE_STORAGE_KEY) guideAlwaysVisible: boolean = false;
  @StorageProp('liveViewEnabled') liveViewEnabled: boolean = true;
  @StorageProp('liveViewMode') liveViewMode: number = 1;
  @StorageLink('remoteDesktopBgFlag') @Watch('onRemoteDesktopBgFlagChange')
  appBackgroundSignal: boolean = false;
  @LocalStorageLink('sessionWindowBackground') @Watch('onSessionWindowBackgroundChange')
  sessionWindowBackground: boolean = false;
  @LocalStorageLink('sessionWindowFullscreen') sessionWindowFullscreen: boolean = false;
  @State appInBackground: boolean = false;
  @State hostId: string = '';
  @State appId: string = '';
  @State phase: MoonlightSessionPhase = 'failed';
  @State errorCode: MoonlightSessionErrorCode = 'internal';
  @State degradationReasons: string[] = [];
  @State elapsedMs: number = 0;
  @State firstFrameSeen: boolean = false;
  @State inputReady: boolean = false;
  @State controllerReady: boolean = false;
  @State physicalControllerPathReady: boolean = false;
  @State audioReady: boolean = false;
  @State showConnectStage: boolean = true;
  @State showConnectStageSheet: boolean = false;
  @State pendingConnectStageSheet: boolean = false;
  @State showSessionSheet: boolean = false;
  @State sheetMode: MoonlightSessionSheetMode = 'none';
  @State pendingSheetMode: MoonlightSessionSheetMode = 'none';
  @State controlMode: MoonlightControlMode = 'touch';
  @State sessionChanges: number = 0;
  @State showController: boolean = false;
  @State controllerEditing: boolean = false;
  @State showModifierPanel: boolean = false;
  @State showShortcutPanel: boolean = false;
  @State keyboardOpen: boolean = false;
  @State keyboardText: string = '';
  @State diagnosticsVisible: boolean = false;
  @State diagnosticsExpanded: boolean = false;
  @State diagnosticsX: number = 18;
  @State diagnosticsY: number = 90;
  @State diagnosticsSnapshot: MoonlightDiagnosticsSnapshot = EMPTY_MOONLIGHT_DIAGNOSTICS;
  @State ctrlLatch: string = 'off';
  @State altLatch: string = 'off';
  @State shiftLatch: string = 'off';
  @State winLatch: string = 'off';
  @State fnLayer: boolean = false;
  @State inputFlushCount: number = 0;
  @State surfaceRecovering: boolean = false;
  @State pipPrepared: boolean = false;
  @State terminationBusy: boolean = false;
  private readonly sessionCoordinator: MoonlightSessionCoordinator =
    MoonlightSessionCoordinator.getInstance();
  private readonly hostService: MoonlightHostService = new MoonlightHostService();
  private readonly localViewService: MoonlightLocalViewService =
    new MoonlightLocalViewService(CloudStore.getInstance());
  private readonly recoveryRuntime: MoonlightSessionRecoveryRuntime =
    MoonlightSessionRecoveryRuntime.getInstance();
  private accountScopeUnsubscribe: (() => void) | null = null;
  private snapshotUnsubscribe: (() => void) | null = null;
  private pageActive: boolean = false;
  private sessionGeneration: number = 0;
  private appliedTouchModeSessionGeneration: number = 0;
  private sessionStartedAtMs: number = 0;
  private elapsedTimer: number = -1;
  private sheetReopenGeneration: number = 0;
  private sheetReopenTimer: number = -1;
  private readonly xcId: string = 'MoonlightStreamSurface';
  private readonly xComponentController: MoonlightStreamXComponentController =
    new MoonlightStreamXComponentController();
  private readonly keyboardController: TextAreaController = new TextAreaController();
  private readonly keyboardCommandQueue: RemoteImeCommandQueue = new RemoteImeCommandQueue();
  private keyboardImeGeneration: number = 0;
  private keyboardImeActive: boolean = false;
  private keyboardImeEditingObserved: boolean = false;
  private keyboardSyncedCaret: number = 0;
  private keyboardExpectedStart: number = -1;
  private keyboardExpectedEnd: number = -1;
  private keyboardProgrammaticSelection: boolean = false;
  private keyboardInitialSelectionPending: boolean = false;
  private keyboardSelectionAckTimer: number = -1;
  private keyboardCommandPumpTimer: number = -1;
  private diagnosticsTimer: number = -1;
  private diagnosticsPreviousSampleMs: number = 0;
  private diagnosticsPreviousPresentedFrames: number = 0;
  private diagnosticsPreviousVideoBytes: number = 0;
  private launchKey: MoonlightNativeRequestKey = { requestId: 0, generation: 0, ownerToken: 0 };
  private serverUuid: string = '';
  private numericAppId: number = 0;
  private hostAddress: string = '';
  private surfaceId: string = '';
  private pageSurfaceId: string = '';
  private pipSurfaceId: string = '';
  private surfaceWidthPx: number = 1920;
  private surfaceHeightPx: number = 1080;
  private surfaceWidthVp: number = 1;
  private surfaceHeightVp: number = 1;
  private streamWidth: number = 1920;
  private streamHeight: number = 1080;
  private configuredBitrateKbps: number = 20000;
  private effectiveSettingsEncoded: string = '';
  private effectiveSettings: MoonlightSettings = defaultMoonlightSettings();
  private routeOwnerScopeFingerprint: string = '';
  private routeAccountGeneration: number = 0;
  private routeInstallationId: string = '';
  private routeStoreInstanceId: number = 0;
  private recoverySessionId: string = '';
  private resetRemoteInputBeforeAdmission: boolean = false;
  private recoveryBound: boolean = false;
  private routeOwnerValidated: boolean = false;
  private launchOwnerDisposed: boolean = false;
  private geometryGeneration: number = 1;
  private hitMapGeneration: number = 1;
  private activeTouches: Map<number, MoonlightTouchPoint> = new Map<number, MoonlightTouchPoint>();
  private inputSuspended: boolean = false;
  private inputSuspensionAppliedOwnerToken: number = 0;
  private rendererHandle: number = -1;
  private streamStartAttempted: boolean = false;
  private surfacePollTimer: number = -1;
  private surfaceRecoveryTimer: number = -1;
  private surfaceRecoveryGeneration: number = 0;
  private sessionReserved: boolean = false;
  private routeTerminated: boolean = false;
  private nativeSurfaceAttached: boolean = false;
  private reservedOwnerScopeId: string = '';
  private reservedAccountGeneration: number = 0;
  private nativeRuntimeAvailable: boolean = false;
  private nativeHostControlReady: boolean = false;
  private nativeStreamingTransportReady: boolean = false;
  private surfaceSuspended: boolean = false;
  private nativeSessionId: number = -1;
  private sessionWindowId: string = '';
  private audioPausedForBackground: boolean = false;
  private backgroundTaskStarted: boolean = false;
  private backgroundTaskGeneration: number = 0;
  private liveViewStarted: boolean = false;
  private pipPrepareInFlight: boolean = false;
  private pipTransferInProgress: boolean = false;
  private renderPreservedInPip: boolean = false;
  private pipLifecycleGeneration: number = 0;
  private foregroundRestoreInProgress: boolean = false;
  private pipRestoreTimer: number = -1;
  private pipRestoreAttempt: number = 0;
  private networkConnection: connection.NetConnection | null = null;
  private networkMonitorRegistered: boolean = false;
  private networkAvailable: boolean = true;
  private networkBinding: MoonlightNetworkBinding = {
    ownerToken: 0, nativeSessionId: -1, activeNetId: 0, unavailable: false
  };
  private presentationLease: RemoteSessionServiceLease | null = null;
  private presentationTeardown: Promise<boolean> = Promise.resolve(true);
  private presentationReleaseGeneration: number = 0;
  private presentationReleaseRetryTimer: number = -1;
  private presentationReleaseActive: boolean = false;
  private contextualGuideRetryTimer: number = -1;
  private contextualGuideShownThisSession: boolean = false;
  private reconnectWindow: MoonlightReconnectWindow | null = null;
  private reconnectTimer: number = -1;
  private reconnectGeneration: number = 0;
  private reconnectInFlight: boolean = false;
  private reconnectRuntimeLaunched: boolean = false;
  private requestedTerminalAction: MoonlightSessionRecoveryTerminalAction = 'none';
  private readonly networkAvailableCallback: Callback<connection.NetHandle> =
    (handle: connection.NetHandle): void => { this.onMoonlightNetworkAvailable(handle); };
  private readonly networkLostCallback: Callback<connection.NetHandle> =
    (handle: connection.NetHandle): void => { this.onMoonlightNetworkLost(handle); };
  private readonly networkUnavailableCallback: Callback<void> =
    (): void => { this.onMoonlightNetworkUnavailable(); };

  private pal(): Palette {
    return this.theme === 'light' ? buildLight(this.accentColor) : buildDark(this.accentColor);
  }

  /**
   * The connection gate belongs to the stream route, but it must render as a
   * native Sheet rather than as a centered child over the video surface.
   * Keep the Sheet binding derived from both the initial handshake state and
   * transient surface recovery so neither path can expose a false "connected"
   * session underneath it.
   */
  private syncConnectStageSheet(): void {
    const gateNeeded: boolean = this.showConnectStage || this.surfaceRecovering;
    if (!gateNeeded) {
      this.pendingConnectStageSheet = false;
      this.showConnectStageSheet = false;
      return;
    }
    // The stream route has one native Sheet host for session controls and one
    // for the connection gate. Never leave both requested at once: closing a
    // control Sheet is asynchronous, so queue the gate and let
    // onSheetDisappear() open it after the native Sheet has actually gone.
    if (this.showSessionSheet || this.sheetMode !== 'none' ||
        this.pendingSheetMode !== 'none' || this.sheetReopenTimer >= 0) {
      this.pendingConnectStageSheet = true;
      this.showConnectStageSheet = false;
      this.pendingSheetMode = 'none';
      this.sheetReopenGeneration += 1;
      this.cancelSheetReopen();
      if (this.showSessionSheet) { this.showSessionSheet = false; }
      return;
    }
    this.pendingConnectStageSheet = false;
    this.showConnectStageSheet = true;
  }

  private setConnectStageVisible(visible: boolean): void {
    this.showConnectStage = visible;
    this.syncConnectStageSheet();
  }

  private setSurfaceRecovering(recovering: boolean): void {
    this.surfaceRecovering = recovering;
    this.syncConnectStageSheet();
  }

  private clearMoonlightContextualGuideRetry(): void {
    if (this.contextualGuideRetryTimer >= 0) {
      clearTimeout(this.contextualGuideRetryTimer);
      this.contextualGuideRetryTimer = -1;
    }
  }

  private scheduleMoonlightContextualGuide(delayMs: number = 240): void {
    if (this.contextualGuideRetryTimer >= 0 || !this.pageActive || this.routeTerminated) { return; }
    this.contextualGuideRetryTimer = setTimeout((): void => {
      this.contextualGuideRetryTimer = -1;
      this.maybeShowMoonlightContextualGuide();
      const guide: SessionContextualGuide = sessionContextualGuide('moonlight',
        guideDeviceFor(this.isDesktopDevice, this.isPadDevice, this.breakpoint));
      const alreadyShown: boolean = GuideVisibilityService.getInstance().wasShown(
        getContext(this) as common.Context, guide.storageKey);
      const ready: boolean = this.pageActive && !this.routeTerminated &&
        this.phase === 'streaming' && this.firstFrameSeen;
      if (shouldRetrySessionContextualGuide(
        ready, alreadyShown, this.guideAlwaysVisible,
        this.contextualGuideShownThisSession) && !this.appInBackground) {
        // Keep only one retry alive while a transient Sheet, keyboard or
        // recovery overlay owns the visible session.
        this.scheduleMoonlightContextualGuide(800);
      }
    }, delayMs);
  }

  private maybeShowMoonlightContextualGuide(): void {
    const device: GuideDevice = guideDeviceFor(
      this.isDesktopDevice, this.isPadDevice, this.breakpoint);
    const guide: SessionContextualGuide = sessionContextualGuide('moonlight', device);
    const alreadyShown: boolean = GuideVisibilityService.getInstance().wasShown(
      getContext(this) as common.Context, guide.storageKey);
    const blockingOverlayVisible: boolean = this.showSessionSheet || this.showModifierPanel ||
      this.showShortcutPanel || this.showController || this.keyboardOpen || this.surfaceRecovering;
    if (!shouldShowSessionContextualGuide(
      this.pageActive && !this.appInBackground && !this.routeTerminated &&
        this.phase === 'streaming' && this.firstFrameSeen, alreadyShown,
      blockingOverlayVisible, this.guideAlwaysVisible,
      this.contextualGuideShownThisSession)) {
      return;
    }
    try {
      this.getUIContext().getPromptAction().showToast({
        message: guide.message,
        duration: guide.durationMs
      });
      this.contextualGuideShownThisSession = true;
      GuideVisibilityService.getInstance().markShown(
        getContext(this) as common.Context, guide.storageKey);
    } catch (_) {}
  }

  private toolbarLayout(): MoonlightToolbarLayout {
    return moonlightToolbarLayout(this.isDesktopDevice, this.breakpoint, this.isPadDevice);
  }

  private toggleIndependentWindowFullscreen(): void {
    if (this.sessionWindowId.length === 0) { return; }
    void RemoteSessionWindowCoordinator.getInstance().toggleFullscreen(
      this.sessionWindowId).then((changed: boolean): void => {
      if (!changed) {
        promptAction.showToast({ message: '窗口全屏切换暂不可用', duration: 1800 });
      }
    }).catch((_err: Error): void => {
      promptAction.showToast({ message: '窗口全屏切换失败', duration: 1800 });
    });
  }

  aboutToAppear(): void {
    this.pageActive = true;
    this.sheetReopenGeneration += 1;
    const params: Record<string, Object> = router.getParams() as Record<string, Object>;
    this.sessionWindowId = typeof params['sessionWindowId'] === 'string'
      ? (params['sessionWindowId'] as string).trim() : '';
    this.appInBackground = this.sessionWindowId.length > 0 ?
      this.sessionWindowBackground : this.appBackgroundSignal;
    const route: MoonlightRouteIdentity = moonlightRouteIdentity(params, true);
    this.hostId = route.valid ? route.hostId : '';
    this.appId = route.valid ? route.appId : '';
    this.launchKey = {
      requestId: params['launchRequestId'] as number,
      generation: params['launchGeneration'] as number,
      ownerToken: params['launchOwnerToken'] as number
    };
    this.launchOwnerDisposed = false;
    this.serverUuid = typeof params['serverUuid'] === 'string' ? params['serverUuid'] as string : '';
    this.numericAppId = typeof params['numericAppId'] === 'number' ? params['numericAppId'] as number : 0;
    this.hostAddress = typeof params['hostAddress'] === 'string' ? params['hostAddress'] as string : '';
    this.effectiveSettingsEncoded = typeof params['moonlightEffectiveSettings'] === 'string' ?
      params['moonlightEffectiveSettings'] as string : '';
    const settingsSnapshot: MoonlightEffectiveSettings | null =
      decodeMoonlightEffectiveSettings(this.effectiveSettingsEncoded);
    if (settingsSnapshot !== null) {
      this.effectiveSettings = settingsSnapshot.effective;
      this.controlMode = settingsSnapshot.effective.input.touchMode;
    } else {
      this.effectiveSettingsEncoded = '';
      this.effectiveSettings = defaultMoonlightSettings();
    }
    this.diagnosticsVisible = this.effectiveSettings.diagnostics.showPerformanceHud;
    this.diagnosticsExpanded = false;
    this.diagnosticsSnapshot = EMPTY_MOONLIGHT_DIAGNOSTICS;
    this.resetDiagnosticsSampling();
    const routeStreamWidth: number = params['streamWidth'] as number;
    const routeStreamHeight: number = params['streamHeight'] as number;
    this.streamWidth = Number.isSafeInteger(routeStreamWidth) && routeStreamWidth >= 2 &&
      routeStreamWidth <= 32767 ? routeStreamWidth : 1920;
    this.streamHeight = Number.isSafeInteger(routeStreamHeight) && routeStreamHeight >= 2 &&
      routeStreamHeight <= 32767 ? routeStreamHeight : 1080;
    this.configuredBitrateKbps = this.effectiveSettings.video.bitrateKbps;
    this.routeOwnerScopeFingerprint = typeof params['launchOwnerScopeFingerprint'] === 'string'
      ? params['launchOwnerScopeFingerprint'] as string : '';
    this.routeAccountGeneration = params['launchAccountGeneration'] as number;
    this.routeInstallationId = typeof params['launchInstallationId'] === 'string'
      ? params['launchInstallationId'] as string : '';
    this.routeStoreInstanceId = params['launchStoreInstanceId'] as number;
    this.recoverySessionId = typeof params['moonlightRecoverySessionId'] === 'string' ?
      (params['moonlightRecoverySessionId'] as string).trim().toLowerCase() : '';
    this.resetRemoteInputBeforeAdmission =
      params['resetRemoteInputBeforeAdmission'] === true;
    this.recoveryBound = false;
    this.xComponentController.onSurface = (surfaceId: string): void => {
      this.onMoonlightSurface(surfaceId);
    };
    this.xComponentController.onSurfaceDetached = (surfaceId: string): void => {
      this.onMoonlightSurfaceDestroyed(surfaceId);
    };
    this.phase = 'failed';
    this.errorCode = 'internal';
    this.degradationReasons = [];
    this.elapsedMs = 0;
    this.firstFrameSeen = false;
    this.inputReady = false;
    this.controllerReady = false;
    this.physicalControllerPathReady = false;
    this.audioReady = false;
    this.appliedTouchModeSessionGeneration = 0;
    this.inputSuspended = false;
    this.inputSuspensionAppliedOwnerToken = 0;
    this.activeTouches.clear();
    this.sessionGeneration = 0;
    this.sessionStartedAtMs = 0;
    this.clearElapsedTimer();
    this.setConnectStageVisible(true);
    this.keyboardOpen = false;
    this.resetMoonlightImeSession('page-appear');
    this.phase = 'discovering';
    this.streamStartAttempted = false;
    this.sessionReserved = false;
    this.routeTerminated = false;
    this.nativeSurfaceAttached = false;
    this.surfaceSuspended = false;
    this.setSurfaceRecovering(false);
    this.pageSurfaceId = '';
    this.pipSurfaceId = '';
    this.surfaceRecoveryGeneration += 1;
    this.clearSurfaceRecoveryTimer();
    this.nativeSessionId = -1;
    this.presentationLease = null;
    this.presentationTeardown = Promise.resolve(true);
    this.presentationReleaseGeneration += 1;
    this.clearPresentationReleaseRetry();
    this.presentationReleaseActive = false;
    this.networkBinding = {
      ownerToken: 0, nativeSessionId: -1, activeNetId: 0, unavailable: false
    };
    this.audioPausedForBackground = false;
    this.backgroundTaskStarted = false;
    this.liveViewStarted = false;
    this.pipPrepared = false;
    this.pipPrepareInFlight = false;
    this.pipTransferInProgress = false;
    this.renderPreservedInPip = false;
    this.foregroundRestoreInProgress = false;
    this.pipRestoreAttempt = 0;
    this.clearPipRestoreTimer();
    this.pipLifecycleGeneration += 1;
    this.reconnectGeneration += 1;
    this.reconnectWindow = null;
    this.reconnectInFlight = false;
    this.reconnectRuntimeLaunched = false;
    this.clearReconnectTimer();
    this.terminationBusy = false;
    this.requestedTerminalAction = 'none';
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
    const recoveryLease: AccountSessionLease | null =
      CloudStore.getInstance().currentAccountLease();
    let recoveryContext: common.UIAbilityContext | null = null;
    try {
      recoveryContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
    } catch (_error) {}
    if (recoveryLease === null || recoveryContext === null ||
        this.recoveryRuntime.bind(recoveryContext, recoveryLease,
          this.recoverySessionId, this.hostId, this.appId) !== 'ready') {
      this.phase = 'failed';
      this.errorCode = 'internal';
      this.routeTerminated = true;
      this.disposeLaunchOwner();
      return;
    }
    this.recoveryBound = true;
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
    this.registerMoonlightNetworkMonitor();
  }

  aboutToDisappear(): void {
    this.pageActive = false;
    this.clearMoonlightContextualGuideRetry();
    this.pipLifecycleGeneration += 1;
    this.pipPrepareInFlight = false;
    this.pipTransferInProgress = false;
    this.foregroundRestoreInProgress = false;
    this.clearPipRestoreTimer();
    this.reconnectGeneration += 1;
    this.reconnectWindow = null;
    this.reconnectInFlight = false;
    this.reconnectRuntimeLaunched = false;
    this.clearReconnectTimer();
    this.unregisterMoonlightNetworkMonitor();
    this.sheetReopenGeneration += 1;
    this.cancelSheetReopen();
    this.pendingSheetMode = 'none';
    this.showSessionSheet = false;
    this.pendingConnectStageSheet = false;
    this.showConnectStageSheet = false;
    this.closeMoonlightRoute('stream-page-disappear');
    void this.stopMoonlightBackgroundTask();
    this.stopDiagnosticsPolling();
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
      /^[0-9a-f]{32}$/.test(this.recoverySessionId) && this.recoveryBound &&
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
    const waitingForSurface: boolean = !this.streamStartAttempted || this.surfaceSuspended;
    if (!this.pageActive || !this.sessionReserved || this.routeTerminated ||
        !waitingForSurface || this.appInBackground || attempt >= 80) { return; }
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

  private beginSurfaceFrameRecovery(surfaceId: string): void {
    this.surfaceRecoveryGeneration += 1;
    const generation: number = this.surfaceRecoveryGeneration;
    this.clearSurfaceRecoveryTimer();
    this.confirmSurfaceFrame(generation, surfaceId, 0);
  }

  private confirmSurfaceFrame(generation: number, surfaceId: string, attempt: number): void {
    if (!this.pageActive || this.routeTerminated || this.surfaceSuspended ||
        !this.surfaceRecovering || generation !== this.surfaceRecoveryGeneration ||
        surfaceId !== this.surfaceId) {
      return;
    }
    const confirmed = this.sessionCoordinator.confirmSurfaceFrameForRoute(
      this.hostId, this.appId, surfaceId);
    if (confirmed.accepted) {
      this.setSurfaceRecovering(false);
      this.setConnectStageVisible(false);
      this.firstFrameSeen = true;
      if (!this.appInBackground) {
        this.setNativeInputSuspended(false, 'surface_detached');
        void this.prepareMoonlightPipForForeground();
      }
      return;
    }
    if (confirmed.code !== 'surface_frame_pending' || attempt >= 79) {
      this.phase = 'failed';
      this.errorCode = 'decoder_failed';
      this.closeMoonlightRoute(attempt >= 79 ?
        'surface-first-frame-timeout' : 'surface-frame-confirm-failed');
      return;
    }
    this.surfaceRecoveryTimer = setTimeout((): void => {
      this.surfaceRecoveryTimer = -1;
      this.confirmSurfaceFrame(generation, surfaceId, attempt + 1);
    }, 100);
  }

  private clearSurfaceRecoveryTimer(): void {
    if (this.surfaceRecoveryTimer >= 0) {
      clearTimeout(this.surfaceRecoveryTimer);
      this.surfaceRecoveryTimer = -1;
    }
  }

  private onMoonlightSurface(surfaceId: string): void {
    if (surfaceId.trim() !== '') {
      this.pageSurfaceId = surfaceId;
    }
    if (this.renderPreservedInPip || this.pipTransferInProgress ||
        this.foregroundRestoreInProgress) {
      // The page XComponent can be recreated while the independent PIP
      // free-node owns the native renderer. Keep the page ID for restore but
      // never redirect the process-global native surface away from PIP.
      return;
    }
    if (this.pageActive && !this.routeTerminated && this.reconnectWindow !== null &&
        this.nativeSessionId <= 0 && surfaceId.trim() !== '') {
      this.surfaceId = surfaceId;
      this.surfaceSuspended = false;
      this.setSurfaceRecovering(true);
      this.scheduleReconnectDecision(this.reconnectWindow.generation, 0);
      return;
    }
    const rebinding: boolean = this.streamStartAttempted && this.surfaceSuspended;
    if (!this.pageActive || !this.sessionReserved || this.routeTerminated ||
        (this.streamStartAttempted && !rebinding) || !this.routeLeaseValid() ||
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
    if (rebinding) {
      const rebound = this.sessionCoordinator.rebindSurfaceForRoute(
        this.hostId, this.appId, this.rendererHandle, surfaceId);
      if (!rebound.accepted) {
        this.phase = 'failed'; this.errorCode = 'decoder_failed';
        this.closeMoonlightRoute('surface-rebind-failed');
        return;
      }
      this.surfaceSuspended = false;
      this.setSurfaceRecovering(true);
      this.beginSurfaceFrameRecovery(surfaceId);
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
      return;
    }
    this.nativeSessionId = result.nativeSessionId;
    this.refreshMoonlightPresentationLease();
    this.bindMoonlightNetworkToCurrentSession();
    this.sessionCoordinator.setReconnectEnabledForRoute(
      this.hostId, this.appId, this.effectiveSettings.network.autoReconnect &&
      this.effectiveSettings.network.reconnectBudgetMs > 0);
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
      configuredBitrateKbps: this.configuredBitrateKbps,
      effectiveSettingsEncoded: this.effectiveSettingsEncoded,
      resetRemoteInputBeforeAdmission: this.resetRemoteInputBeforeAdmission
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
    if (surfaceId.trim() !== '' && surfaceId === this.pageSurfaceId) {
      this.pageSurfaceId = '';
    }
    if (this.renderPreservedInPip || this.pipTransferInProgress ||
        this.foregroundRestoreInProgress) {
      // The destroyed callback belongs to the page XComponent. PIP owns a
      // different free-node surface and remains the only native renderer.
      return;
    }
    if (this.routeTerminated || this.surfaceId !== '' &&
        surfaceId.trim() !== '' && surfaceId !== this.surfaceId) {
      return;
    }
    if (this.reconnectWindow !== null && this.nativeSessionId <= 0) {
      this.flushInput('surface-destroyed-during-reconnect');
      this.setNativeInputSuspended(true, 'surface_detached');
      this.surfaceRecoveryGeneration += 1;
      this.clearSurfaceRecoveryTimer();
      this.setSurfaceRecovering(true);
      this.surfaceSuspended = true;
      if (this.nativeSurfaceAttached) {
        try { rdpnapi.markXComponentSurfaceDestroyed(); } catch (_) {}
        this.nativeSurfaceAttached = false;
      }
      this.destroyMoonlightRenderer();
      this.surfaceId = '';
      if (!this.appInBackground) { this.pollMoonlightSurface(0); }
      return;
    }
    if (!this.streamStartAttempted || this.nativeSessionId <= 0) {
      this.closeMoonlightRoute('surface-destroyed-before-stream');
      return;
    }
    this.flushInput('surface-destroyed');
    this.setNativeInputSuspended(true, 'surface_detached');
    const suspended = this.sessionCoordinator.suspendSurfaceForRoute(this.hostId, this.appId);
    if (!suspended.accepted) {
      this.closeMoonlightRoute('surface-suspend-failed');
      return;
    }
    this.surfaceRecoveryGeneration += 1;
    this.clearSurfaceRecoveryTimer();
    this.setSurfaceRecovering(true);
    this.surfaceSuspended = true;
    if (this.nativeSurfaceAttached) {
      try { rdpnapi.markXComponentSurfaceDestroyed(); } catch (_) {}
      this.nativeSurfaceAttached = false;
    }
    this.destroyMoonlightRenderer();
    this.surfaceId = '';
    if (!this.appInBackground) { this.pollMoonlightSurface(0); }
  }

  private closeMoonlightRoute(reason: string): void {
    if (this.routeTerminated) { return; }
    if (this.recoveryBound) {
      const action: MoonlightSessionRecoveryTerminalAction =
        this.requestedTerminalAction === 'none' ?
          'disconnect' : this.requestedTerminalAction;
      this.recoveryRuntime.requestTerminal(action, Date.now());
    }
    this.sessionCoordinator.setReconnectEnabledForRoute(this.hostId, this.appId, false);
    this.routeTerminated = true;
    this.reconnectGeneration += 1;
    this.reconnectWindow = null;
    this.reconnectInFlight = false;
    this.reconnectRuntimeLaunched = false;
    this.clearReconnectTimer();
    this.unregisterMoonlightNetworkMonitor();
    this.stopSurfacePoll();
    this.surfaceRecoveryGeneration += 1;
    this.clearSurfaceRecoveryTimer();
    this.setSurfaceRecovering(false);
    this.surfaceSuspended = false;
    this.flushInput(reason);
    this.keyboardOpen = false;
    this.resetMoonlightImeSession('route-close');
    if (this.showController) {
      this.setVirtualControllerMode(false, false);
      this.showController = false;
      this.controllerEditing = false;
    }
    this.setNativeInputSuspended(true, 'surface_detached');
    if (this.nativeSessionId > 0 && !this.surfaceSuspended) {
      const detached = this.sessionCoordinator.suspendSurfaceForRoute(
        this.hostId, this.appId);
      this.surfaceSuspended = detached.accepted;
    }
    this.sessionCoordinator.cancelForRoute(this.hostId, this.appId, reason);
    this.disposeLaunchOwner();
    void this.stopMoonlightBackgroundTask();
    this.releaseRendererAfterPresentationTeardown(reason);
    this.stopDiagnosticsPolling();
    this.sessionReserved = false;
    this.streamStartAttempted = true;
    this.surfaceId = '';
    this.pageSurfaceId = '';
    this.pipSurfaceId = '';
    this.pipPrepared = false;
    this.pipPrepareInFlight = false;
    this.pipTransferInProgress = false;
    this.renderPreservedInPip = false;
    this.foregroundRestoreInProgress = false;
    this.pipLifecycleGeneration += 1;
    this.clearPipRestoreTimer();
    this.nativeSessionId = -1;
    this.inputReady = false;
    this.controllerReady = false;
    this.physicalControllerPathReady = false;
    this.audioReady = false;
    this.inputSuspensionAppliedOwnerToken = 0;
    if (this.pageActive) {
      this.phase = 'failed';
      this.errorCode = reason === 'renderer-init-failed' ? 'decoder_failed' : 'internal';
    }
  }

  private async terminateMoonlightSession(
    action: 'disconnect' | 'quit'
  ): Promise<void> {
    if (this.terminationBusy || this.routeTerminated) { return; }
    this.terminationBusy = true;
    this.flushInput(action === 'quit' ? 'quit_host_app' : 'disconnect_local');
    this.setNativeInputSuspended(true, 'surface_detached');

    let presentationStopped: boolean = false;
    try {
      presentationStopped = await this.stopMoonlightBackgroundPresentation();
    } catch (_error) {
      presentationStopped = false;
    }
    if (!presentationStopped) {
      this.terminationBusy = false;
      if (this.pageActive) {
        promptAction.showToast({
          message: '系统画中画仍在安全收尾，请稍后重试', duration: 2200
        });
      }
      return;
    }
    this.requestedTerminalAction = action;
    this.recoveryRuntime.requestTerminal(action, Date.now());
    this.sessionCoordinator.setReconnectEnabledForRoute(this.hostId, this.appId, false);

    let stopped: boolean = false;
    let hostQuitConfirmed: boolean = action === 'disconnect';
    let hostQuitCode: string = '';
    let hostQuitReceiptRecorded: boolean = false;
    try {
      stopped = await this.sessionCoordinator.stopForLifecycle(
        action === 'quit' ? 'user-quit-host-app' : 'user-disconnect', 6500);
      if (action === 'quit' && stopped) {
        const view: MoonlightHostLocalView =
          this.localViewService.loadHost(this.hostId, Date.now());
        const lease: AccountSessionLease | null = view.lease;
        const ownerToken: number =
          MoonlightRuntimeOwnerTokenAllocator.getInstance().next();
        const context: MoonlightHostContext | null = view.ok && view.host !== null &&
          view.paired && lease !== null && CloudStore.getInstance().isLeaseCurrent(lease) &&
          lease.ownerScopeId === this.reservedOwnerScopeId &&
          lease.generation === this.reservedAccountGeneration &&
          view.host.serverUuid === this.serverUuid && ownerToken > 0 ?
          moonlightRuntimeContext(view.host, lease, ownerToken, ownerToken,
            view.serverCertificateSha256, this.effectiveSettings, 8000) : null;
        if (context !== null) {
          let result: MoonlightHostServiceResult | null = null;
          try {
            result = await this.hostService.quit(
              context, this.numericAppId, true);
          } finally {
            this.hostService.disposeOwner(ownerToken);
          }
          if (result !== null) {
            hostQuitCode = result.code;
            const native = result.nativeResult;
            hostQuitReceiptRecorded = true;
            const markerCleared: boolean =
              this.recoveryRuntime.acceptHostQuitReceipt(
                this.reservedOwnerScopeId, this.reservedAccountGeneration,
                this.hostId, this.appId, {
                  code: result.code,
                  preflightTruth: native === null ?
                    'not_attempted' : native.preflightTruth,
                  actionTruth: native === null ?
                    'not_attempted' : native.actionTruth,
                  postconditionTruth: native === null ?
                    'not_attempted' : native.postconditionTruth,
                  idempotent: native !== null && native.idempotent
                }, Date.now());
            hostQuitConfirmed = markerCleared ||
              (result.ok && native !== null &&
                native.postconditionTruth === 'confirmed');
          }
        }
      }
    } catch (_error) {
      hostQuitCode = action === 'quit' ? 'native_exception' : '';
    } finally {
      if (action === 'quit' && stopped && !hostQuitReceiptRecorded) {
        // Stream teardown is already input-neutral, but the host mutation was
        // never observed. Move the durable marker to explicit uncertainty so
        // the next process performs a read-only serverinfo preflight.
        this.recoveryRuntime.acceptHostQuitReceipt(
          this.reservedOwnerScopeId, this.reservedAccountGeneration,
          this.hostId, this.appId, {
            code: hostQuitCode === '' ? 'outcome_unknown' : hostQuitCode,
            preflightTruth: 'not_attempted', actionTruth: 'not_attempted',
            postconditionTruth: 'unknown', idempotent: false
          }, Date.now());
      }
      if (this.pageActive) {
        if (!stopped) {
          promptAction.showToast({
            message: '本地串流仍在安全收尾，已保留恢复记录', duration: 2400
          });
        } else if (action === 'quit' && !hostQuitConfirmed) {
          promptAction.showToast({
            message: '主机应用退出结果未确认' +
              (hostQuitCode === '' ? '' : '（' + hostQuitCode + '）') +
              '，已保留恢复记录', duration: 2800
          });
        } else if (action === 'quit') {
          promptAction.showToast({ message: '主机应用已安全结束', duration: 1600 });
        }
      }
      try {
        this.closeMoonlightRoute(action === 'quit' ?
          (hostQuitConfirmed ? 'host-app-quit' : 'host-app-quit-uncertain') :
          (stopped ? 'user-disconnect' : 'user-disconnect-timeout'));
        this.closeSheet();
      } finally {
        this.terminationBusy = false;
        this.closeSessionSurface();
      }
    }
  }

  private destroyMoonlightRenderer(): void {
    const handle: number = this.rendererHandle;
    this.rendererHandle = -1;
    if (handle > 0) {
      try { rdpnapi.destroyRenderer(handle); } catch (_) {}
    }
  }

  private detachSurfaceAndDestroyMoonlightRenderer(): void {
    if (this.nativeSurfaceAttached) {
      try { rdpnapi.markXComponentSurfaceDestroyed(); } catch (_) {}
      this.nativeSurfaceAttached = false;
    }
    this.destroyMoonlightRenderer();
  }

  private clearPresentationReleaseRetry(): void {
    if (this.presentationReleaseRetryTimer >= 0) {
      clearTimeout(this.presentationReleaseRetryTimer);
      this.presentationReleaseRetryTimer = -1;
    }
  }

  /**
   * PiPWindow may still own the free-node surface after the route has already
   * been closed. Keep exactly one retry chain and release the native surface /
   * renderer only after WMS reports a terminal controller state.
   */
  private releaseRendererAfterPresentationTeardown(reason: string): void {
    if (this.presentationReleaseActive) { return; }
    this.presentationReleaseActive = true;
    const generation: number = ++this.presentationReleaseGeneration;
    this.clearPresentationReleaseRetry();
    const attempt = (): void => {
      if (generation !== this.presentationReleaseGeneration) { return; }
      const pending: Promise<boolean> = this.stopMoonlightBackgroundPresentation()
        .catch((_error: Error): boolean => false);
      this.presentationTeardown = pending;
      pending.then((stopped: boolean): void => {
        if (generation !== this.presentationReleaseGeneration) { return; }
        if (!stopped) {
          this.presentationReleaseRetryTimer = setTimeout((): void => {
            this.presentationReleaseRetryTimer = -1;
            attempt();
          }, 250);
          return;
        }
        this.clearPresentationReleaseRetry();
        this.detachSurfaceAndDestroyMoonlightRenderer();
        this.presentationLease = null;
        this.presentationReleaseActive = false;
        hilog.info(0x0014, 'MoonlightStreamUi',
          'presentation renderer released after terminal PIP reason=' + reason);
      }).catch((_error: Error): void => {
        if (generation !== this.presentationReleaseGeneration) { return; }
        this.presentationReleaseRetryTimer = setTimeout((): void => {
          this.presentationReleaseRetryTimer = -1;
          attempt();
        }, 250);
      });
    };
    attempt();
  }

  private onRemoteDesktopBgFlagChange(): void {
    if (this.sessionWindowId.length > 0) { return; }
    this.applyMoonlightAbilityBackground(this.appBackgroundSignal);
  }

  private onSessionWindowBackgroundChange(): void {
    if (this.sessionWindowId.length === 0) { return; }
    this.applyMoonlightAbilityBackground(this.sessionWindowBackground);
  }

  private applyMoonlightAbilityBackground(isBackground: boolean): void {
    this.appInBackground = isBackground;
    if (!this.pageActive || this.routeTerminated) { return; }
    if (isBackground) {
      void this.enterMoonlightBackground();
      return;
    }
    this.scheduleMoonlightContextualGuide();
    void this.restoreMoonlightForeground();
  }

  private moonlightPipSize(): RemoteSessionPipContentSize {
    return resolveRemoteSessionPipContentSize(
      this.streamWidth, this.streamHeight, this.surfaceWidthPx, this.surfaceHeightPx);
  }

  private refreshMoonlightPresentationLease(): RemoteSessionServiceLease | null {
    if (!this.routeLeaseValid() || this.nativeSessionId <= 0 || this.hostId.trim() === '') {
      return null;
    }
    const lease: RemoteSessionServiceLease = {
      protocol: 'moonlight',
      hostId: this.hostId,
      sessionId: this.nativeSessionId,
      generation: this.launchKey.generation,
      ownerToken: this.launchKey.ownerToken
    };
    this.presentationLease = cloneRemoteSessionServiceLease(lease);
    return cloneRemoteSessionServiceLease(lease);
  }

  private currentMoonlightPresentationLease(): RemoteSessionServiceLease | null {
    return this.presentationLease === null ? null :
      cloneRemoteSessionServiceLease(this.presentationLease);
  }

  private presentationLeaseCurrent(lease: RemoteSessionServiceLease): boolean {
    return remoteSessionServiceLeaseEquals(this.presentationLease, lease) &&
      this.routeLeaseValid() && !this.routeTerminated;
  }

  private moonlightBackgroundInfo(hasVideo: boolean): RemoteSessionBgInfo {
    const keepAudio: boolean = this.effectiveSettings.audio.enabled && this.audioReady &&
      this.effectiveSettings.background.allowAudioInBackground;
    return {
      hostId: this.hostId,
      sessionId: this.nativeSessionId,
      resumeRemoteSession: true,
      protocolLabel: 'Moonlight',
      // Keep host addresses out of system notifications and media metadata.
      hostAddress: this.hostId,
      hasAudio: keepAudio,
      hasVideo: hasVideo
    };
  }

  private async enterMoonlightBackground(): Promise<void> {
    if (!this.pageActive || !this.appInBackground || this.routeTerminated ||
        this.nativeSessionId <= 0) { return; }
    const presentationLease: RemoteSessionServiceLease | null =
      this.currentMoonlightPresentationLease();
    if (presentationLease === null) {
      this.closeMoonlightRoute('background-presentation-lease-missing');
      return;
    }
    const lifecycleGeneration: number = ++this.pipLifecycleGeneration;
    this.clearPipRestoreTimer();
    this.pipRestoreAttempt = 0;
    this.foregroundRestoreInProgress = false;
    this.flushInput('ability-background');
    this.keyboardOpen = false;
    this.resetMoonlightImeSession('background');
    this.setNativeInputSuspended(true, 'backgrounded');
    if (!this.effectiveSettings.background.allowAudioInBackground && this.audioReady) {
      const paused = this.sessionCoordinator.setAudioPausedForRoute(
        this.hostId, this.appId, true);
      this.audioPausedForBackground = paused.accepted;
    }

    let pipPreserved: boolean = false;
    const pipService: RemoteSessionPipService = RemoteSessionPipService.getInstance();
    const pipEnabled: boolean = this.liveViewEnabled && this.liveViewMode === LiveViewMode.AVSESSION;
    if (pipEnabled && this.firstFrameSeen &&
        pipService.isPreparedOrPreparing(presentationLease)) {
      this.pipTransferInProgress = true;
      try {
        const uiContext = this.getUIContext();
        const context: common.UIAbilityContext =
          uiContext.getHostContext() as common.UIAbilityContext;
        const size: RemoteSessionPipContentSize = this.moonlightPipSize();
        pipPreserved = await pipService.start(
          context, uiContext, size.width, size.height, presentationLease,
          (surface: RemoteSessionPipSurface, operationGeneration: number): Promise<boolean> =>
            this.attachMoonlightRendererToPipSurface(
              surface, operationGeneration, lifecycleGeneration, presentationLease),
          (reason: string): void => {
            this.handleMoonlightPipStopped(reason, presentationLease);
          },
          (surface: RemoteSessionPipSurface): void => {
            this.handleMoonlightPipSurfaceChanged(surface, presentationLease);
          });
      } catch (err) {
        hilog.warn(0x0014, 'MoonlightStreamUi',
          'PIP auto-start failed: ' + JSON.stringify(err));
        pipPreserved = false;
      }
    }
    if (lifecycleGeneration !== this.pipLifecycleGeneration || !this.appInBackground ||
        this.routeTerminated || !this.presentationLeaseCurrent(presentationLease)) {
      if (remoteSessionServiceLeaseEquals(this.presentationLease, presentationLease)) {
        this.pipTransferInProgress = false;
      }
      await pipService.stop(presentationLease);
      return;
    }
    this.pipTransferInProgress = false;
    this.renderPreservedInPip = pipPreserved;
    if (!pipPreserved) {
      await pipService.stop(presentationLease);
      if (!this.suspendMoonlightRendererForBackground('pip-unavailable')) {
        this.closeMoonlightRoute('background-surface-suspend-failed');
        return;
      }
    }
    const hasBackgroundVideo: boolean = pipPreserved && this.rendererHandle > 0;
    await this.startMoonlightBackgroundTask(hasBackgroundVideo);
    await this.startMoonlightLiveView(hasBackgroundVideo);
  }

  private suspendMoonlightRendererForBackground(reason: string): boolean {
    if (this.routeTerminated || this.nativeSessionId <= 0) { return false; }
    if (!this.surfaceSuspended) {
      const suspended = this.sessionCoordinator.suspendSurfaceForRoute(this.hostId, this.appId);
      if (!suspended.accepted) {
        hilog.warn(0x0014, 'MoonlightStreamUi',
          'surface suspend rejected reason=' + reason + ' code=' + suspended.code);
        return false;
      }
    }
    this.surfaceRecoveryGeneration += 1;
    this.clearSurfaceRecoveryTimer();
    this.surfaceSuspended = true;
    this.setSurfaceRecovering(true);
    if (this.nativeSurfaceAttached) {
      try { rdpnapi.markXComponentSurfaceDestroyed(); } catch (_) {}
      this.nativeSurfaceAttached = false;
    }
    this.destroyMoonlightRenderer();
    this.surfaceId = '';
    this.pipSurfaceId = '';
    this.renderPreservedInPip = false;
    hilog.info(0x0014, 'MoonlightStreamUi',
      'renderer suspended without disconnect reason=' + reason);
    return true;
  }

  private async attachMoonlightRendererToPipSurface(surface: RemoteSessionPipSurface,
    operationGeneration: number, lifecycleGeneration: number,
    presentationLease: RemoteSessionServiceLease): Promise<boolean> {
    const pipService: RemoteSessionPipService = RemoteSessionPipService.getInstance();
    if (!this.pageActive || !this.appInBackground || this.routeTerminated ||
        lifecycleGeneration !== this.pipLifecycleGeneration ||
        !this.presentationLeaseCurrent(presentationLease) ||
        !pipService.isOperationCurrent(operationGeneration, presentationLease) ||
        this.nativeSessionId <= 0 || this.rendererHandle <= 0 || !this.firstFrameSeen ||
        surface.surfaceId.trim() === '' || surface.surfaceWidth <= 0 || surface.surfaceHeight <= 0) {
      return false;
    }
    this.flushInput('pip-surface-transfer');
    this.setNativeInputSuspended(true, 'pip_entered');
    const suspended = this.sessionCoordinator.suspendSurfaceForRoute(this.hostId, this.appId);
    if (!suspended.accepted) { return false; }
    this.surfaceRecoveryGeneration += 1;
    this.clearSurfaceRecoveryTimer();
    this.surfaceSuspended = true;
    this.setSurfaceRecovering(true);
    if (this.nativeSurfaceAttached) {
      try { rdpnapi.markXComponentSurfaceDestroyed(); } catch (_) {}
      this.nativeSurfaceAttached = false;
    }
    this.destroyMoonlightRenderer();

    try {
      if (!rdpnapi.setXComponentSurfaceId(
          surface.surfaceId, surface.surfaceWidth, surface.surfaceHeight)) {
        return false;
      }
      this.nativeSurfaceAttached = true;
      this.rendererHandle = rdpnapi.initRenderer(
        this.xcId, surface.surfaceWidth, surface.surfaceHeight);
    } catch (_) {
      this.rendererHandle = -1;
    }
    if (this.rendererHandle <= 0 || lifecycleGeneration !== this.pipLifecycleGeneration ||
        !this.presentationLeaseCurrent(presentationLease) ||
        !pipService.isOperationCurrent(operationGeneration, presentationLease)) {
      this.suspendMoonlightRendererForBackground('pip-renderer-init-failed');
      return false;
    }
    this.surfaceId = surface.surfaceId;
    this.pipSurfaceId = surface.surfaceId;
    const rebound = this.sessionCoordinator.rebindSurfaceForRoute(
      this.hostId, this.appId, this.rendererHandle, surface.surfaceId);
    if (!rebound.accepted) {
      this.suspendMoonlightRendererForBackground('pip-surface-rebind-failed');
      return false;
    }
    this.surfaceSuspended = false;
    const frameReady: boolean = await this.waitForMoonlightPipFrame(
      surface.surfaceId, operationGeneration, lifecycleGeneration, presentationLease);
    if (!frameReady) {
      this.suspendMoonlightRendererForBackground('pip-first-frame-timeout');
      return false;
    }
    this.setSurfaceRecovering(false);
    this.firstFrameSeen = true;
    this.renderPreservedInPip = true;
    return true;
  }

  private async waitForMoonlightPipFrame(surfaceId: string,
    operationGeneration: number, lifecycleGeneration: number,
    presentationLease: RemoteSessionServiceLease): Promise<boolean> {
    const pipService: RemoteSessionPipService = RemoteSessionPipService.getInstance();
    for (let attempt: number = 0; attempt < 80; attempt++) {
      if (this.routeTerminated || !this.appInBackground ||
          lifecycleGeneration !== this.pipLifecycleGeneration ||
          !this.presentationLeaseCurrent(presentationLease) ||
          !pipService.isOperationCurrent(operationGeneration, presentationLease) ||
          this.surfaceSuspended || this.surfaceId !== surfaceId) {
        return false;
      }
      const confirmed = this.sessionCoordinator.confirmSurfaceFrameForRoute(
        this.hostId, this.appId, surfaceId);
      if (confirmed.accepted) { return true; }
      if (confirmed.code !== 'surface_frame_pending') { return false; }
      await new Promise<void>((resolve: () => void): void => {
        setTimeout(resolve, 100);
      });
    }
    return false;
  }

  private handleMoonlightPipSurfaceChanged(surface: RemoteSessionPipSurface,
    presentationLease: RemoteSessionServiceLease): void {
    if (!this.presentationLeaseCurrent(presentationLease) ||
        !this.renderPreservedInPip || this.foregroundRestoreInProgress ||
        this.rendererHandle <= 0 || surface.surfaceId !== this.pipSurfaceId ||
        surface.surfaceWidth <= 0 || surface.surfaceHeight <= 0) { return; }
    try {
      if (!rdpnapi.setXComponentSurfaceId(
          surface.surfaceId, surface.surfaceWidth, surface.surfaceHeight)) { return; }
      rdpnapi.resizeRenderer(this.rendererHandle, surface.surfaceWidth, surface.surfaceHeight);
    } catch (err) {
      hilog.warn(0x0014, 'MoonlightStreamUi',
        'PIP surface resize failed: ' + JSON.stringify(err));
    }
  }

  private handleMoonlightPipStopped(reason: string,
    presentationLease: RemoteSessionServiceLease): void {
    if (!this.presentationLeaseCurrent(presentationLease)) { return; }
    this.pipPrepared = false;
    if (this.foregroundRestoreInProgress || this.routeTerminated) { return; }
    if (this.renderPreservedInPip || this.pipSurfaceId !== '') {
      this.suspendMoonlightRendererForBackground('pip-stopped-' + reason);
    }
  }

  private async restoreMoonlightForeground(): Promise<void> {
    if (!this.pageActive || this.appInBackground || this.routeTerminated ||
        this.foregroundRestoreInProgress) { return; }
    const lifecycleGeneration: number = ++this.pipLifecycleGeneration;
    this.foregroundRestoreInProgress = true;
    this.pipTransferInProgress = false;
    await this.stopMoonlightBackgroundTask();
    const pipStopped: boolean = await this.stopMoonlightBackgroundPresentation();
    if (lifecycleGeneration !== this.pipLifecycleGeneration || this.routeTerminated ||
        this.appInBackground) {
      this.foregroundRestoreInProgress = false;
      return;
    }
    if (!pipStopped) {
      this.foregroundRestoreInProgress = false;
      this.scheduleMoonlightPipRestoreRetry();
      return;
    }
    this.clearPipRestoreTimer();
    this.pipRestoreAttempt = 0;
    if (this.renderPreservedInPip || this.pipSurfaceId !== '') {
      if (!this.suspendMoonlightRendererForBackground('foreground-pip-release')) {
        this.foregroundRestoreInProgress = false;
        this.closeMoonlightRoute('foreground-surface-suspend-failed');
        return;
      }
    }
    this.renderPreservedInPip = false;
    this.pipSurfaceId = '';
    this.foregroundRestoreInProgress = false;
    if (this.audioPausedForBackground) {
      const resumed = this.sessionCoordinator.setAudioPausedForRoute(
        this.hostId, this.appId, false);
      this.audioPausedForBackground = !resumed.accepted;
      if (!resumed.accepted) {
        this.closeMoonlightRoute('background-audio-resume-failed');
        return;
      }
    }
    let candidateSurfaceId: string = this.pageSurfaceId;
    if (candidateSurfaceId.trim() === '') {
      try { candidateSurfaceId = this.xComponentController.getXComponentSurfaceId(); } catch (_) {}
    }
    if (candidateSurfaceId.trim() !== '') {
      this.onMoonlightSurface(candidateSurfaceId);
    } else {
      this.pollMoonlightSurface(0);
    }
    if (!this.surfaceSuspended && !this.surfaceRecovering) {
      this.setNativeInputSuspended(false, 'backgrounded');
      void this.prepareMoonlightPipForForeground();
    }
  }

  private scheduleMoonlightPipRestoreRetry(): void {
    if (this.pipRestoreTimer >= 0 || this.routeTerminated || this.appInBackground) { return; }
    this.pipRestoreAttempt += 1;
    if (this.pipRestoreAttempt > 6) {
      this.closeMoonlightRoute('pip-terminal-state-timeout');
      return;
    }
    this.pipRestoreTimer = setTimeout((): void => {
      this.pipRestoreTimer = -1;
      void this.restoreMoonlightForeground();
    }, 250);
  }

  private clearPipRestoreTimer(): void {
    if (this.pipRestoreTimer >= 0) {
      clearTimeout(this.pipRestoreTimer);
      this.pipRestoreTimer = -1;
    }
  }

  private async startMoonlightBackgroundTask(hasVideo: boolean = false): Promise<void> {
    if (!this.pageActive || !this.appInBackground || this.routeTerminated ||
        this.nativeSessionId <= 0) {
      return;
    }
    const generation: number = ++this.backgroundTaskGeneration;
    let context: common.UIAbilityContext;
    try {
      context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    } catch (_) { return; }
    const info: RemoteSessionBgInfo = this.moonlightBackgroundInfo(hasVideo);
    const service: RemoteSessionBackgroundTaskService =
      RemoteSessionBackgroundTaskService.getInstance();
    const started: boolean = this.backgroundTaskStarted ? true :
      await service.startSessionTask(context, info);
    if (started && (info.hasAudio || info.hasVideo)) {
      await service.updateAudioPlaybackMode(context, info);
    }
    if (generation !== this.backgroundTaskGeneration || !this.pageActive ||
        !this.appInBackground || this.routeTerminated) {
      if (started) {
        await RemoteSessionBackgroundTaskService.getInstance().stopSessionTask(context);
      }
      return;
    }
    this.backgroundTaskStarted = started;
  }

  private async startMoonlightLiveView(hasVideo: boolean): Promise<void> {
    if (!this.pageActive || !this.appInBackground || this.routeTerminated ||
        this.nativeSessionId <= 0) { return; }
    const presentationLease: RemoteSessionServiceLease | null =
      this.currentMoonlightPresentationLease();
    if (presentationLease === null) { return; }
    let context: common.UIAbilityContext;
    try {
      context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    } catch (_) { return; }
    const info: RemoteSessionBgInfo = this.moonlightBackgroundInfo(hasVideo);
    const liveInfo: LiveViewConnectionInfo = {
      hostId: info.hostId,
      sessionId: info.sessionId,
      protocolLabel: info.protocolLabel,
      hostAddress: info.hostAddress,
      hasAudio: info.hasAudio,
      hasVideo: info.hasVideo,
      connectedAtMs: this.sessionStartedAtMs > 0 ? this.sessionStartedAtMs : Date.now()
    };
    const service: RemoteSessionLiveViewService = RemoteSessionLiveViewService.getInstance();
    const started: boolean = await service.reconcile(context, liveInfo, presentationLease);
    if (!this.presentationLeaseCurrent(presentationLease)) {
      if (started) { await service.stop(context, presentationLease); }
      return;
    }
    this.liveViewStarted = started;
    if (started && info.hasAudio) {
      service.setMuteCommandCallback((mute: boolean): void => {
        if (!this.presentationLeaseCurrent(presentationLease)) { return; }
        const result = this.sessionCoordinator.setAudioPausedForRoute(
          this.hostId, this.appId, mute);
        if (result.accepted) { this.audioPausedForBackground = mute; }
      }, presentationLease);
    }
  }

  private async stopMoonlightBackgroundPresentation(): Promise<boolean> {
    const presentationLease: RemoteSessionServiceLease | null =
      this.currentMoonlightPresentationLease();
    if (presentationLease === null) { return true; }
    let context: common.UIAbilityContext | null = null;
    try {
      context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    } catch (_) {}
    const liveViewService: RemoteSessionLiveViewService =
      RemoteSessionLiveViewService.getInstance();
    if (this.liveViewStarted || liveViewService.isActive(presentationLease)) {
      if (context !== null) {
        await liveViewService.stop(context, presentationLease);
      } else {
        await liveViewService.stopOwned(presentationLease);
      }
    }
    const stopped: boolean = await RemoteSessionPipService.getInstance().stop(presentationLease);
    if (remoteSessionServiceLeaseEquals(this.presentationLease, presentationLease)) {
      this.liveViewStarted = false;
      if (stopped) { this.pipPrepared = false; }
    }
    return stopped;
  }

  private async stopMoonlightBackgroundTask(): Promise<void> {
    this.backgroundTaskGeneration += 1;
    if (!this.backgroundTaskStarted) { return; }
    let context: common.UIAbilityContext;
    try {
      context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    } catch (_) {
      this.backgroundTaskStarted = false;
      return;
    }
    await RemoteSessionBackgroundTaskService.getInstance().stopSessionTask(context);
    this.backgroundTaskStarted = false;
  }

  private async prepareMoonlightPipForForeground(): Promise<void> {
    if (this.pipPrepareInFlight || this.appInBackground || this.routeTerminated) { return; }
    const presentationLease: RemoteSessionServiceLease | null =
      this.currentMoonlightPresentationLease();
    if (presentationLease === null) { return; }
    const pipService: RemoteSessionPipService = RemoteSessionPipService.getInstance();
    if (this.pipPrepared && pipService.isPrepared(presentationLease)) {
      const preparedSize: RemoteSessionPipContentSize = this.moonlightPipSize();
      pipService.updateContentSize(
        preparedSize.width, preparedSize.height, presentationLease);
      return;
    }
    const sessionActive: boolean = this.pageActive && this.nativeSessionId > 0 &&
      this.phase === 'streaming' && this.firstFrameSeen;
    const canPrepare: boolean = shouldPrepareRemoteSessionPip(
      this.liveViewEnabled, this.liveViewMode, sessionActive,
      this.rendererHandle > 0, this.surfaceId.trim() !== '' && !this.surfaceSuspended);
    if (!canPrepare) {
      this.pipPrepared = false;
      if (!sessionActive || !this.liveViewEnabled || this.liveViewMode !== LiveViewMode.AVSESSION) {
        await pipService.stop(presentationLease);
      }
      return;
    }
    const lifecycleGeneration: number = this.pipLifecycleGeneration;
    this.pipPrepareInFlight = true;
    try {
      const uiContext = this.getUIContext();
      const context: common.UIAbilityContext =
        uiContext.getHostContext() as common.UIAbilityContext;
      const size: RemoteSessionPipContentSize = this.moonlightPipSize();
      const prepared: boolean = await pipService.prepare(
        context, uiContext, size.width, size.height, presentationLease,
        (reason: string): void => {
          this.handleMoonlightPipStopped(reason, presentationLease);
        },
        (surface: RemoteSessionPipSurface): void => {
          this.handleMoonlightPipSurfaceChanged(surface, presentationLease);
        });
      if (lifecycleGeneration === this.pipLifecycleGeneration && !this.appInBackground &&
          !this.routeTerminated && this.presentationLeaseCurrent(presentationLease)) {
        this.pipPrepared = prepared;
      } else if (prepared) {
        await pipService.stop(presentationLease);
      }
    } catch (err) {
      if (remoteSessionServiceLeaseEquals(this.presentationLease, presentationLease)) {
        this.pipPrepared = false;
      }
      hilog.warn(0x0014, 'MoonlightStreamUi',
        'PIP foreground prepare failed: ' + JSON.stringify(err));
    } finally {
      this.pipPrepareInFlight = false;
    }
  }

  private async moveMoonlightToPip(): Promise<void> {
    if (!this.pipAvailable() || this.appInBackground || this.routeTerminated) {
      await this.prepareMoonlightPipForForeground();
    }
    if (!this.pipAvailable() || this.appInBackground || this.routeTerminated) {
      promptAction.showToast({ message: '当前设备未能准备画中画', duration: 1800 });
      return;
    }
    try {
      const context: common.UIAbilityContext =
        this.getUIContext().getHostContext() as common.UIAbilityContext;
      await context.moveAbilityToBackground();
    } catch (err) {
      promptAction.showToast({ message: '进入画中画失败', duration: 1800 });
      hilog.warn(0x0014, 'MoonlightStreamUi',
        'moveAbilityToBackground failed: ' + JSON.stringify(err));
    }
  }

  private registerMoonlightNetworkMonitor(): void {
    if (this.networkMonitorRegistered || this.routeTerminated) { return; }
    this.bindMoonlightNetworkToCurrentSession();
    try {
      const monitor: connection.NetConnection = connection.createNetConnection(undefined, 5000);
      monitor.on('netAvailable', this.networkAvailableCallback);
      monitor.on('netLost', this.networkLostCallback);
      monitor.on('netUnavailable', this.networkUnavailableCallback);
      monitor.register((_error): void => {});
      this.networkConnection = monitor;
      this.networkMonitorRegistered = true;
    } catch (_) {
      this.networkConnection = null;
      this.networkMonitorRegistered = false;
    }
  }

  private unregisterMoonlightNetworkMonitor(): void {
    const monitor: connection.NetConnection | null = this.networkConnection;
    this.networkConnection = null;
    this.networkMonitorRegistered = false;
    this.networkBinding = {
      ownerToken: 0, nativeSessionId: -1, activeNetId: 0, unavailable: false
    };
    if (monitor === null) { return; }
    try { monitor.unregister((_error): void => {}); } catch (_) {}
  }

  private bindMoonlightNetworkToCurrentSession(): void {
    let activeNetId: number = 0;
    try {
      const current: connection.NetHandle = connection.getDefaultNetSync();
      activeNetId = moonlightNetIdIsValid(current.netId) ? current.netId : 0;
      this.networkAvailable = activeNetId > 0;
    } catch (_) {
      // Unknown is not treated as a confirmed outage. Native transport truth
      // still gates reconnect admission.
      this.networkAvailable = true;
    }
    this.networkBinding = {
      ownerToken: this.routeLeaseValid() ? this.launchKey.ownerToken : 0,
      nativeSessionId: this.nativeSessionId,
      activeNetId: activeNetId,
      unavailable: false
    };
  }

  private onMoonlightNetworkAvailable(handle: connection.NetHandle): void {
    if (!this.pageActive || this.routeTerminated) { return; }
    let defaultNetId: number = 0;
    try { defaultNetId = connection.getDefaultNetSync().netId; } catch (_) { return; }
    const callbackSessionId: number = moonlightNetworkCallbackSessionId(
      this.networkBinding, this.nativeSessionId, this.reconnectWindow !== null);
    if (!moonlightNetworkAvailableMatchesDefault(
        handle.netId, defaultNetId,
        this.launchKey.ownerToken, this.networkBinding.ownerToken,
        callbackSessionId, this.networkBinding.nativeSessionId)) { return; }
    const wasUnavailable: boolean = this.networkBinding.unavailable || !this.networkAvailable;
    this.networkBinding = {
      ownerToken: this.launchKey.ownerToken,
      nativeSessionId: callbackSessionId,
      activeNetId: handle.netId,
      unavailable: false
    };
    this.networkAvailable = true;
    if (this.reconnectWindow !== null && !this.reconnectInFlight &&
        !this.reconnectRuntimeLaunched) {
      this.scheduleReconnectDecision(this.reconnectWindow.generation, 0);
      return;
    }
    if (shouldResumeMoonlightInputAfterNetworkAvailable(
        wasUnavailable, this.reconnectWindow !== null,
        this.reconnectRuntimeLaunched, this.inputReady,
        this.routeLeaseValid() && !this.appInBackground &&
          !this.surfaceSuspended && !this.surfaceRecovering)) {
      this.setNativeInputSuspended(false, 'reconnect_started');
    }
  }

  private onMoonlightNetworkLost(handle: connection.NetHandle): void {
    const callbackSessionId: number = moonlightNetworkCallbackSessionId(
      this.networkBinding, this.nativeSessionId, this.reconnectWindow !== null);
    if (!moonlightNetworkLostMatches(
        this.networkBinding, handle.netId,
        this.launchKey.ownerToken, callbackSessionId)) { return; }
    this.applyMoonlightNetworkUnavailable(callbackSessionId);
  }

  private onMoonlightNetworkUnavailable(): void {
    try {
      const current: connection.NetHandle = connection.getDefaultNetSync();
      if (moonlightNetIdIsValid(current.netId)) {
        this.onMoonlightNetworkAvailable(current);
        return;
      }
    } catch (_) {
      // The callback itself is confirmed outage evidence when no default
      // network can be queried.
    }
    const callbackSessionId: number = moonlightNetworkCallbackSessionId(
      this.networkBinding, this.nativeSessionId, this.reconnectWindow !== null);
    if (this.networkBinding.ownerToken !== this.launchKey.ownerToken ||
        this.networkBinding.nativeSessionId !== callbackSessionId ||
        callbackSessionId <= 0) { return; }
    this.applyMoonlightNetworkUnavailable(callbackSessionId);
  }

  private applyMoonlightNetworkUnavailable(callbackSessionId: number): void {
    this.networkBinding = {
      ownerToken: this.launchKey.ownerToken,
      nativeSessionId: callbackSessionId,
      activeNetId: 0,
      unavailable: true
    };
    this.networkAvailable = false;
    if (!this.pageActive || this.routeTerminated) { return; }
    this.flushInput('network-lost');
    this.setNativeInputSuspended(true, 'reconnect_started');
  }

  private beginReconnectFromSnapshot(): void {
    if (!this.pageActive || this.routeTerminated) { return; }
    if (this.reconnectWindow !== null && !this.reconnectRuntimeLaunched &&
        (this.reconnectInFlight || this.reconnectTimer >= 0)) {
      return;
    }
    this.flushInput('transport-lost');
    this.setNativeInputSuspended(true, 'reconnect_started');
    this.presentationTeardown = this.stopMoonlightBackgroundPresentation()
      .catch((_error: Error): boolean => false);
    this.nativeSessionId = -1;
    this.surfaceRecoveryGeneration += 1;
    this.clearSurfaceRecoveryTimer();
    this.setSurfaceRecovering(false);
    this.surfaceSuspended = false;
    this.disposeLaunchOwner();

    if (this.reconnectWindow !== null) {
      if (this.reconnectRuntimeLaunched) {
        this.reconnectWindow = moonlightReconnectAfterFailure(
          this.reconnectWindow, Date.now());
      }
      this.reconnectRuntimeLaunched = false;
      this.reconnectInFlight = false;
      this.scheduleReconnectDecision(this.reconnectWindow.generation, 0);
      return;
    }

    this.reconnectGeneration += 1;
    const window: MoonlightReconnectWindow = createMoonlightReconnectWindow(
      this.effectiveSettings.network.autoReconnect,
      this.effectiveSettings.network.reconnectBudgetMs,
      Date.now(), this.reconnectGeneration);
    this.reconnectWindow = window;
    this.reconnectRuntimeLaunched = false;
    this.reconnectInFlight = false;
    this.scheduleReconnectDecision(window.generation, 0);
  }

  private scheduleReconnectDecision(generation: number, delayMs: number): void {
    this.clearReconnectTimer();
    if (!moonlightReconnectWindowIsCurrent(this.reconnectWindow, generation) ||
        this.routeTerminated) { return; }
    this.reconnectTimer = setTimeout((): void => {
      this.reconnectTimer = -1;
      this.driveReconnect(generation);
    }, Math.max(0, Math.min(120000, delayMs)));
  }

  private scheduleReconnectDeadline(generation: number, delayMs: number): void {
    this.clearReconnectTimer();
    if (!moonlightReconnectWindowIsCurrent(this.reconnectWindow, generation) ||
        this.routeTerminated) { return; }
    this.reconnectTimer = setTimeout((): void => {
      this.reconnectTimer = -1;
      if (moonlightReconnectWindowIsCurrent(this.reconnectWindow, generation)) {
        this.giveUpReconnect(generation, 'reconnect-budget-exhausted');
      }
    }, Math.max(1, Math.min(120000, delayMs)));
  }

  private clearReconnectTimer(): void {
    if (this.reconnectTimer >= 0) {
      clearTimeout(this.reconnectTimer);
      this.reconnectTimer = -1;
    }
  }

  private driveReconnect(generation: number): void {
    const window: MoonlightReconnectWindow | null = this.reconnectWindow;
    if (!this.pageActive || this.routeTerminated || this.reconnectInFlight ||
        this.reconnectRuntimeLaunched ||
        !moonlightReconnectWindowIsCurrent(window, generation)) {
      return;
    }
    const decision: MoonlightReconnectDecision = moonlightReconnectDecision(
      window as MoonlightReconnectWindow, Date.now(), this.networkAvailable);
    if (decision.action === 'give_up') {
      this.giveUpReconnect(generation, 'reconnect-budget-exhausted');
      return;
    }
    if (decision.action !== 'attempt') {
      this.scheduleReconnectDecision(generation, Math.max(1, decision.delayMs));
      return;
    }
    void this.performReconnectAttempt(generation, decision);
  }

  private async performReconnectAttempt(generation: number,
    decision: MoonlightReconnectDecision): Promise<void> {
    if (!moonlightReconnectWindowIsCurrent(this.reconnectWindow, generation) ||
        this.reconnectInFlight || this.routeTerminated) { return; }
    let candidateSurfaceId: string = this.surfaceId;
    if (candidateSurfaceId.trim() === '') {
      try { candidateSurfaceId = this.xComponentController.getXComponentSurfaceId(); } catch (_) {}
    }
    if (candidateSurfaceId.trim() === '' || this.appInBackground) {
      this.scheduleReconnectDecision(generation, 200);
      return;
    }
    this.reconnectInFlight = true;
    const presentationStopped: boolean = await this.presentationTeardown;
    if (!moonlightReconnectWindowIsCurrent(this.reconnectWindow, generation) ||
        this.routeTerminated) {
      this.reconnectInFlight = false;
      return;
    }
    if (!presentationStopped) {
      this.presentationTeardown = this.stopMoonlightBackgroundPresentation()
        .catch((_error: Error): boolean => false);
      this.recordReconnectFailure(generation);
      return;
    }
    const surfaceEpoch: number = this.surfaceRecoveryGeneration;

    const scope: AccountScopeToken = AccountSessionCoordinator.getInstance().currentScope();
    const view: MoonlightHostLocalView = this.localViewService.loadHost(this.hostId, Date.now());
    const lease: AccountSessionLease | null = view.lease;
    if (!this.routeOwnerMatches(scope) || !view.ok || view.host === null || !view.paired ||
        lease === null || !CloudStore.getInstance().isLeaseCurrent(lease) ||
        view.host.serverUuid !== this.serverUuid ||
        lease.ownerScopeId !== this.reservedOwnerScopeId ||
        lease.generation !== this.reservedAccountGeneration) {
      this.giveUpReconnect(generation, 'reconnect-owner-or-trust-changed');
      return;
    }

    const ownerToken: number = MoonlightRuntimeOwnerTokenAllocator.getInstance().next();
    const attemptTimeout: number = moonlightReconnectAttemptTimeoutMs(decision);
    const perOperationTimeout: number = Math.max(100, Math.min(2500,
      Math.floor(attemptTimeout / 2)));
    const context: MoonlightHostContext | null = moonlightRuntimeContext(
      view.host, lease, ownerToken, decision.attemptNumber,
      view.serverCertificateSha256, this.effectiveSettings, perOperationTimeout);
    const nextHostAddress: string = moonlightSelectedHostAddress(
      view.host, this.effectiveSettings);
    if (ownerToken <= 0 || context === null || nextHostAddress === '') {
      this.recordReconnectFailure(generation);
      return;
    }

    this.surfaceId = candidateSurfaceId;
    this.surfaceSuspended = false;
    this.detachSurfaceAndDestroyMoonlightRenderer();
    try {
      if (!rdpnapi.setXComponentSurfaceId(
          candidateSurfaceId, this.surfaceWidthPx, this.surfaceHeightPx)) {
        this.reconnectInFlight = false;
        this.hostService.disposeOwner(ownerToken);
        this.recordReconnectFailure(generation);
        return;
      }
      this.nativeSurfaceAttached = true;
      this.rendererHandle = rdpnapi.initRenderer(
        this.xcId, this.surfaceWidthPx, this.surfaceHeightPx);
    } catch (_) {
      this.rendererHandle = -1;
    }
    if (this.rendererHandle <= 0) {
      this.reconnectInFlight = false;
      this.hostService.disposeOwner(ownerToken);
      this.detachSurfaceAndDestroyMoonlightRenderer();
      this.recordReconnectFailure(generation);
      return;
    }

    const launchConfiguration: MoonlightNativeLaunchConfiguration =
      moonlightLaunchConfiguration(this.effectiveSettings);
    const result: MoonlightHostServiceResult = await this.hostService.resume(
      context, this.numericAppId, launchConfiguration);
    if (!this.pageActive || this.routeTerminated ||
        !moonlightReconnectWindowIsCurrent(this.reconnectWindow, generation) ||
        !CloudStore.getInstance().isLeaseCurrent(lease) ||
        surfaceEpoch !== this.surfaceRecoveryGeneration ||
        candidateSurfaceId !== this.surfaceId || this.surfaceSuspended) {
      this.hostService.disposeOwner(ownerToken);
      this.reconnectInFlight = false;
      this.detachSurfaceAndDestroyMoonlightRenderer();
      return;
    }
    if (!result.ok || result.nativeResult === null) {
      this.hostService.disposeOwner(ownerToken);
      this.reconnectInFlight = false;
      this.detachSurfaceAndDestroyMoonlightRenderer();
      this.recordReconnectFailure(generation);
      return;
    }

    this.launchKey = result.key;
    this.launchOwnerDisposed = false;
    this.inputSuspensionAppliedOwnerToken = 0;
    this.hostAddress = nextHostAddress;
    const restarted = this.sessionCoordinator.restartAfterTransportLoss(
      this.sessionStartRequest(true));
    if (!restarted.accepted) {
      this.disposeLaunchOwner();
      this.reconnectInFlight = false;
      this.detachSurfaceAndDestroyMoonlightRenderer();
      this.recordReconnectFailure(generation);
      return;
    }
    this.nativeSessionId = restarted.nativeSessionId;
    this.refreshMoonlightPresentationLease();
    this.bindMoonlightNetworkToCurrentSession();
    this.reconnectInFlight = false;
    this.reconnectRuntimeLaunched = true;
    this.sessionCoordinator.setReconnectEnabledForRoute(
      this.hostId, this.appId, true);
    const activeWindow: MoonlightReconnectWindow | null = this.reconnectWindow;
    if (moonlightReconnectWindowIsCurrent(activeWindow, generation)) {
      const remainingMs: number = Math.max(1,
        (activeWindow as MoonlightReconnectWindow).deadlineAtMs - Date.now());
      this.scheduleReconnectDeadline(generation, remainingMs);
    }
  }

  private recordReconnectFailure(generation: number): void {
    if (!moonlightReconnectWindowIsCurrent(this.reconnectWindow, generation)) { return; }
    this.reconnectWindow = moonlightReconnectAfterFailure(
      this.reconnectWindow as MoonlightReconnectWindow, Date.now());
    this.reconnectInFlight = false;
    this.reconnectRuntimeLaunched = false;
    this.scheduleReconnectDecision(generation, 0);
  }

  private finishReconnect(): void {
    this.reconnectGeneration += 1;
    this.reconnectWindow = null;
    this.reconnectInFlight = false;
    this.reconnectRuntimeLaunched = false;
    this.clearReconnectTimer();
    if (!this.appInBackground && !this.surfaceRecovering && !this.surfaceSuspended) {
      this.setNativeInputSuspended(false, 'reconnect_started');
    }
  }

  private giveUpReconnect(generation: number, reason: string): void {
    if (!moonlightReconnectWindowIsCurrent(this.reconnectWindow, generation)) { return; }
    this.closeMoonlightRoute(reason);
    this.phase = 'failed';
    this.errorCode = 'network_unreachable';
    this.setConnectStageVisible(true);
    if (this.pageActive) {
      promptAction.showToast({ message: '网络恢复超时，请返回应用目录后重试', duration: 2200 });
    }
  }

  private nativeInputAvailable(): boolean {
    return this.inputReady && this.routeLeaseValid() && !this.inputSuspended;
  }

  private refreshNativeInputReadiness(): void {
    if (!this.routeLeaseValid()) {
      this.inputReady = false;
      this.controllerReady = false;
      this.physicalControllerPathReady = false;
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
      this.physicalControllerPathReady = this.inputReady &&
        source.physicalControllerReady;
      if (this.inputReady) {
        // A crash-recovery reset is a one-shot admission boundary. A later
        // same-process network reconnect gets a fresh common-c session but
        // does not replay the expensive sweep after the first reset receipt.
        this.resetRemoteInputBeforeAdmission = false;
      }
    } catch (_) {
      this.inputReady = false;
      this.controllerReady = false;
      this.physicalControllerPathReady = false;
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

  private sendMoonlightText(text: string): boolean {
    if (!this.nativeInputAvailable() || text.length === 0) { return false; }
    try {
      return rdpnapi.moonlightSendText({
        launchKey: {
          requestId: this.launchKey.requestId,
          generation: this.launchKey.generation,
          ownerToken: this.launchKey.ownerToken
        },
        text: text
      });
    } catch (_) { return false; }
  }

  private sendMoonlightKeyTap(keyCode: number): boolean {
    const pressed: boolean = this.sendMoonlightKey(keyCode, true);
    const released: boolean = this.sendMoonlightKey(keyCode, false);
    return pressed && released;
  }

  private openMoonlightKeyboard(): void {
    if (this.keyboardOpen) { return; }
    if (!this.inputReady || this.routeTerminated) {
      promptAction.showToast({ message: '键盘输入尚未就绪', duration: 1600 });
      return;
    }
    this.flushInput('open-keyboard');
    this.keyboardOpen = true;
    this.startMoonlightImeSession();
    setTimeout((): void => {
      if (!this.keyboardOpen || !this.keyboardImeActive) { return; }
      try { focusControl.requestFocus('MoonlightKeyboardProxy'); } catch (_) {}
    }, 0);
  }

  private dismissMoonlightKeyboard(): void {
    if (!this.keyboardOpen && !this.keyboardImeActive) { return; }
    this.keyboardOpen = false;
    this.flushInput('close-keyboard');
    this.resetMoonlightImeSession('dismiss');
    try { focusControl.requestFocus(this.xcId); } catch (_) {}
  }

  private startMoonlightImeSession(): void {
    const shadow = createRemoteImeShadow();
    this.keyboardImeGeneration += 1;
    this.keyboardCommandQueue.clear();
    this.keyboardText = shadow.text;
    this.keyboardImeActive = true;
    this.keyboardImeEditingObserved = false;
    this.keyboardSyncedCaret = shadow.caret;
    this.keyboardExpectedStart = shadow.caret;
    this.keyboardExpectedEnd = shadow.caret;
    this.keyboardProgrammaticSelection = true;
    this.keyboardInitialSelectionPending = true;
    const generation: number = this.keyboardImeGeneration;
    setTimeout((): void => {
      if (this.keyboardImeActive && generation === this.keyboardImeGeneration) {
        this.setMoonlightImeSelection(shadow.caret);
      }
    }, 0);
  }

  private resetMoonlightImeSession(_reason: string): void {
    if (this.keyboardCommandPumpTimer >= 0) {
      clearTimeout(this.keyboardCommandPumpTimer);
      this.keyboardCommandPumpTimer = -1;
    }
    if (this.keyboardSelectionAckTimer >= 0) {
      clearTimeout(this.keyboardSelectionAckTimer);
      this.keyboardSelectionAckTimer = -1;
    }
    this.keyboardImeGeneration += 1;
    this.keyboardImeActive = false;
    this.keyboardImeEditingObserved = false;
    this.keyboardCommandQueue.clear();
    this.keyboardText = '';
    this.keyboardSyncedCaret = 0;
    this.keyboardExpectedStart = -1;
    this.keyboardExpectedEnd = -1;
    this.keyboardProgrammaticSelection = false;
    this.keyboardInitialSelectionPending = false;
  }

  private setMoonlightImeSelection(caret: number): void {
    const safeCaret: number = Math.max(0, Math.min(caret, this.keyboardText.length));
    this.keyboardExpectedStart = safeCaret;
    this.keyboardExpectedEnd = safeCaret;
    this.keyboardProgrammaticSelection = true;
    if (this.keyboardSelectionAckTimer >= 0) {
      clearTimeout(this.keyboardSelectionAckTimer);
    }
    const generation: number = this.keyboardImeGeneration;
    const initialSelection: boolean = this.keyboardInitialSelectionPending;
    this.keyboardSelectionAckTimer = setTimeout((): void => {
      this.keyboardSelectionAckTimer = -1;
      if (this.keyboardImeActive && generation === this.keyboardImeGeneration) {
        this.keyboardProgrammaticSelection = false;
        if (initialSelection) { this.keyboardInitialSelectionPending = false; }
      }
    }, MOONLIGHT_IME_SELECTION_ACK_TIMEOUT_MS);
    try {
      this.keyboardController.setTextSelection(
        safeCaret, safeCaret, { menuPolicy: MenuPolicy.HIDE });
    } catch (_) {}
  }

  private handleMoonlightImeWillInsert(info: InsertValue): boolean {
    this.keyboardExpectedStart = info.insertOffset + info.insertValue.length;
    this.keyboardExpectedEnd = this.keyboardExpectedStart;
    return this.keyboardImeActive;
  }

  private handleMoonlightImeDidInsert(info: InsertValue): void {
    if (!this.keyboardImeActive || info.insertValue.length === 0) { return; }
    this.keyboardSyncedCaret = info.insertOffset + info.insertValue.length;
    this.keyboardCommandQueue.enqueueText(
      info.insertValue, this.keyboardImeGeneration, 'didInsert');
    this.scheduleMoonlightImeCommandPump();
  }

  private handleMoonlightImeWillDelete(info: DeleteValue): boolean {
    this.keyboardExpectedStart = info.deleteOffset;
    this.keyboardExpectedEnd = info.deleteOffset;
    return this.keyboardImeActive;
  }

  private handleMoonlightImeDidDelete(info: DeleteValue): void {
    if (!this.keyboardImeActive) { return; }
    const deletion = resolveRemoteImeDelete(info.direction as number, info.deleteValue.length);
    this.keyboardSyncedCaret = info.deleteOffset;
    if (deletion.backwardCount > 0) {
      this.keyboardCommandQueue.enqueueKeyTaps(
        MOONLIGHT_KEYCODE_DEL, deletion.backwardCount,
        this.keyboardImeGeneration, 'didDelete-backward');
    }
    if (deletion.forwardCount > 0) {
      this.keyboardCommandQueue.enqueueKeyTaps(
        MOONLIGHT_KEYCODE_FORWARD_DEL, deletion.forwardCount,
        this.keyboardImeGeneration, 'didDelete-forward');
    }
    this.scheduleMoonlightImeCommandPump();
  }

  private handleMoonlightImeSelectionChange(start: number, end: number): void {
    const result = resolveRemoteImeSelection({
      active: this.keyboardImeActive,
      programmatic: this.keyboardProgrammaticSelection,
      initialSelectionPending: this.keyboardInitialSelectionPending,
      expectedStart: this.keyboardExpectedStart,
      expectedEnd: this.keyboardExpectedEnd,
      syncedCaret: this.keyboardSyncedCaret,
      selectionStart: start,
      selectionEnd: end
    });
    if (result.consumeInitial) {
      this.keyboardInitialSelectionPending = false;
      this.keyboardProgrammaticSelection = false;
      this.keyboardExpectedStart = -1;
      this.keyboardExpectedEnd = -1;
      if (start !== this.keyboardSyncedCaret || end !== this.keyboardSyncedCaret) {
        this.setMoonlightImeSelection(this.keyboardSyncedCaret);
      }
      return;
    }
    if (result.consumeExpected) {
      this.keyboardExpectedStart = -1;
      this.keyboardExpectedEnd = -1;
    }
    if (result.action === RemoteImeSelectionAction.IGNORE_PROGRAMMATIC) {
      this.keyboardExpectedStart = -1;
      this.keyboardExpectedEnd = -1;
      return;
    }
    if (result.action === RemoteImeSelectionAction.MOVE_LEFT ||
        result.action === RemoteImeSelectionAction.MOVE_RIGHT) {
      const keyCode: number = result.action === RemoteImeSelectionAction.MOVE_LEFT ?
        MOONLIGHT_KEYCODE_DPAD_LEFT : MOONLIGHT_KEYCODE_DPAD_RIGHT;
      this.keyboardSyncedCaret = result.nextSyncedCaret;
      this.keyboardCommandQueue.enqueueKeyTaps(
        keyCode, result.count, this.keyboardImeGeneration, 'selection');
      this.scheduleMoonlightImeCommandPump();
    } else if (result.action === RemoteImeSelectionAction.COLLAPSE_LOCAL) {
      this.setMoonlightImeSelection(this.keyboardSyncedCaret);
    }
  }

  private scheduleMoonlightImeCommandPump(delayMs: number = 0): void {
    if (this.keyboardCommandPumpTimer >= 0 || this.keyboardCommandQueue.size() === 0) { return; }
    this.keyboardCommandPumpTimer = setTimeout((): void => {
      this.keyboardCommandPumpTimer = -1;
      this.pumpMoonlightImeCommands();
    }, delayMs);
  }

  private pumpMoonlightImeCommands(): void {
    const command: RemoteImeCommand | null = this.keyboardCommandQueue.shift();
    if (command === null) {
      this.recenterMoonlightImeShadow();
      return;
    }
    if (!this.keyboardImeActive || command.generation !== this.keyboardImeGeneration ||
        this.routeTerminated) {
      this.resetMoonlightImeSession('stale-command');
      return;
    }
    if (!this.nativeInputAvailable()) {
      this.keyboardCommandQueue.pushFront(command);
      this.scheduleMoonlightImeCommandPump(MOONLIGHT_IME_COMMAND_RETRY_MS);
      return;
    }
    let accepted: boolean = true;
    if (command.kind === RemoteImeCommandKind.TEXT) {
      accepted = this.sendMoonlightText(command.text);
    } else {
      const sendCount: number = Math.min(32, command.tapCount);
      for (let index: number = 0; index < sendCount; index++) {
        accepted = this.sendMoonlightKeyTap(command.keyCode) && accepted;
      }
      command.tapCount -= sendCount;
      if (command.tapCount > 0) { this.keyboardCommandQueue.pushFront(command); }
    }
    if (!accepted) {
      this.resetMoonlightImeSession('dispatch-failed');
      this.keyboardOpen = false;
      return;
    }
    if (this.keyboardCommandQueue.size() > 0) {
      this.scheduleMoonlightImeCommandPump();
    } else {
      this.recenterMoonlightImeShadow();
    }
  }

  private recenterMoonlightImeShadow(): void {
    if (!this.keyboardImeActive || this.keyboardCommandQueue.size() > 0 ||
        !shouldRecenterRemoteImeShadow(this.keyboardSyncedCaret, this.keyboardText.length)) { return; }
    const shadow = createRemoteImeShadow();
    this.keyboardText = shadow.text;
    this.keyboardSyncedCaret = shadow.caret;
    this.setMoonlightImeSelection(shadow.caret);
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
    if (this.inputSuspended === suspended &&
        this.inputSuspensionAppliedOwnerToken === this.launchKey.ownerToken) {
      return true;
    }
    if (!this.inputReady || !this.routeLeaseValid()) {
      this.inputSuspended = suspended;
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
      if (accepted) {
        this.inputSuspended = suspended;
        this.inputSuspensionAppliedOwnerToken = this.launchKey.ownerToken;
      } else if (suspended) {
        this.inputSuspended = true;
      }
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
    if (this.sessionWindowId.length > 0 && event.keyCode === KeyCode.KEYCODE_F11) {
      try { event.stopPropagation(); } catch (_err) {}
      if (event.type === KeyType.Down) { this.toggleIndependentWindowFullscreen(); }
      return true;
    }
    if (!this.nativeInputAvailable() || !this.effectiveSettings.input.captureKeyboard) { return false; }
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
      this.physicalControllerPathReady = false;
      this.audioReady = false;
      this.inputSuspended = false;
      this.sessionGeneration = 0;
      this.appliedTouchModeSessionGeneration = 0;
      this.sessionStartedAtMs = 0;
      this.setConnectStageVisible(true);
      this.clearElapsedTimer();
      void this.stopMoonlightBackgroundTask();
      this.releaseRendererAfterPresentationTeardown('missing-session-snapshot');
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
    if (snapshot.inputReady) {
      this.refreshNativeInputReadiness();
      if (this.inputReady && this.inputSuspended) {
        this.setNativeInputSuspended(true,
          snapshot.phase === 'reconnecting' ? 'reconnect_started' :
            (this.appInBackground ? 'backgrounded' : 'overlay_opened'));
      }
      if (this.inputReady && this.sessionGeneration > 0 &&
          this.appliedTouchModeSessionGeneration !== this.sessionGeneration &&
          this.setNativeTouchMode(this.effectiveSettings.input.touchMode)) {
        this.appliedTouchModeSessionGeneration = this.sessionGeneration;
      }
    }
    else {
      this.inputReady = false;
      this.controllerReady = false;
      this.physicalControllerPathReady = false;
    }
    this.setConnectStageVisible(!snapshot.firstFrameSeen);
    this.scheduleMoonlightContextualGuide();
    if (this.sessionStartedAtMs > 0) {
      this.elapsedMs = Math.max(0, Date.now() - this.sessionStartedAtMs);
    }
    if (this.showConnectStage && snapshot.phase !== 'failed' && snapshot.phase !== 'disconnected') {
      this.scheduleElapsedTick();
    } else {
      this.clearElapsedTimer();
    }
    if (this.appInBackground && snapshot.phase === 'streaming') {
      if (!this.effectiveSettings.background.allowAudioInBackground &&
          this.audioReady && !this.audioPausedForBackground) {
        const paused = this.sessionCoordinator.setAudioPausedForRoute(
          this.hostId, this.appId, true);
        this.audioPausedForBackground = paused.accepted;
      }
      void this.startMoonlightBackgroundTask(this.renderPreservedInPip);
      void this.startMoonlightLiveView(this.renderPreservedInPip);
    } else if (snapshot.phase === 'failed' || snapshot.phase === 'disconnected') {
      void this.stopMoonlightBackgroundTask();
    }
    if (snapshot.phase === 'reconnecting') {
      this.beginReconnectFromSnapshot();
    } else if (snapshot.phase === 'streaming' && this.reconnectWindow !== null) {
      this.finishReconnect();
    } else if ((snapshot.phase === 'failed' || snapshot.phase === 'disconnected') &&
        this.reconnectWindow !== null) {
      this.reconnectGeneration += 1;
      this.reconnectWindow = null;
      this.reconnectInFlight = false;
      this.reconnectRuntimeLaunched = false;
      this.clearReconnectTimer();
      this.disposeLaunchOwner();
    }
    if (snapshot.phase === 'failed' || snapshot.phase === 'disconnected') {
      this.releaseRendererAfterPresentationTeardown('terminal-session-snapshot');
    }
    if (!this.appInBackground && snapshot.phase === 'streaming' && snapshot.firstFrameSeen &&
        !this.surfaceSuspended && !this.surfaceRecovering) {
      void this.prepareMoonlightPipForForeground();
    }
    if (snapshot.phase === 'streaming' && this.diagnosticsVisible) {
      this.startDiagnosticsPolling();
    } else if (snapshot.phase === 'failed' || snapshot.phase === 'disconnected') {
      this.stopDiagnosticsPolling();
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

  private resetDiagnosticsSampling(): void {
    this.diagnosticsPreviousSampleMs = 0;
    this.diagnosticsPreviousPresentedFrames = 0;
    this.diagnosticsPreviousVideoBytes = 0;
  }

  private startDiagnosticsPolling(): void {
    if (!this.diagnosticsVisible || !this.pageActive || this.routeTerminated ||
        this.diagnosticsTimer >= 0) { return; }
    this.refreshDiagnosticsSnapshot();
  }

  private stopDiagnosticsPolling(): void {
    if (this.diagnosticsTimer >= 0) {
      clearTimeout(this.diagnosticsTimer);
      this.diagnosticsTimer = -1;
    }
    this.resetDiagnosticsSampling();
  }

  private scheduleDiagnosticsPoll(): void {
    if (!this.diagnosticsVisible || !this.pageActive || this.routeTerminated ||
        this.diagnosticsTimer >= 0) { return; }
    this.diagnosticsTimer = setTimeout((): void => {
      this.diagnosticsTimer = -1;
      this.refreshDiagnosticsSnapshot();
    }, 1000);
  }

  private refreshDiagnosticsSnapshot(): void {
    if (!this.diagnosticsVisible || !this.pageActive || this.routeTerminated ||
        !this.routeLeaseValid()) { return; }
    try {
      const source = rdpnapi.moonlightGetStreamSnapshot({
        requestId: this.launchKey.requestId,
        generation: this.launchKey.generation,
        ownerToken: this.launchKey.ownerToken
      });
      const sampledAtMs: number = source.sampledAtMonotonicMs ?? 0;
      const presentedFrames: number = source.rendererPresentedFrames ?? 0;
      const videoBytes: number = source.acceptedVideoBytes ?? 0;
      let fps: number = -1;
      let bitrateKbps: number = -1;
      const elapsedMs: number = sampledAtMs - this.diagnosticsPreviousSampleMs;
      if (this.diagnosticsPreviousSampleMs > 0 && elapsedMs > 0 &&
          presentedFrames >= this.diagnosticsPreviousPresentedFrames &&
          videoBytes >= this.diagnosticsPreviousVideoBytes) {
        fps = Math.round((presentedFrames - this.diagnosticsPreviousPresentedFrames) *
          10000 / elapsedMs) / 10;
        bitrateKbps = Math.round((videoBytes - this.diagnosticsPreviousVideoBytes) *
          8 / elapsedMs);
      }
      this.diagnosticsPreviousSampleMs = sampledAtMs;
      this.diagnosticsPreviousPresentedFrames = presentedFrames;
      this.diagnosticsPreviousVideoBytes = videoBytes;
      this.diagnosticsSnapshot = {
        available: source.matched && !source.terminal,
        fps: fps,
        latencyMs: -1,
        bitrateKbps: bitrateKbps,
        packetLossPercent: -1,
        codec: source.matched ? 'H.264 · 8-bit 4:2:0' : '',
        width: source.streamWidth ?? this.streamWidth,
        height: source.streamHeight ?? this.streamHeight,
        decodeP50Us: -1,
        decodeP95Us: -1,
        renderP50Us: -1,
        renderP95Us: -1,
        audioUnderruns: -1,
        inputDrops: source.rejectedInputEvents ?? -1
      };
    } catch (_) {
      this.diagnosticsSnapshot = EMPTY_MOONLIGHT_DIAGNOSTICS;
      this.resetDiagnosticsSampling();
    }
    this.scheduleDiagnosticsPoll();
  }

  private toggleDiagnosticsHud(): void {
    this.diagnosticsVisible = !this.diagnosticsVisible;
    this.diagnosticsExpanded = this.diagnosticsVisible && this.diagnosticsExpanded;
    if (this.diagnosticsVisible) { this.startDiagnosticsPolling(); }
    else { this.stopDiagnosticsPolling(); }
  }

  private copySanitizedDiagnostics(): void {
    const snapshot: MoonlightDiagnosticsSnapshot = this.diagnosticsSnapshot;
    const text: string = 'Moonlight diagnostics\n' +
      'available=' + snapshot.available.toString() + '\n' +
      'codec=' + (snapshot.codec || 'unavailable') + '\n' +
      'size=' + snapshot.width.toString() + 'x' + snapshot.height.toString() + '\n' +
      'fps=' + snapshot.fps.toString() + '\n' +
      'bitrateKbps=' + snapshot.bitrateKbps.toString() + '\n' +
      'inputDrops=' + snapshot.inputDrops.toString();
    try {
      const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
      pasteboard.getSystemPasteboard().setDataSync(data);
      promptAction.showToast({ message: '已复制脱敏诊断', duration: 1400 });
    } catch (_) {
      promptAction.showToast({ message: '复制诊断失败', duration: 1400 });
    }
  }

  private cancelConnection(): void {
    const result = this.sessionCoordinator.cancelForRoute(
      this.hostId, this.appId, 'connect-stage-cancel');
    if (result.code === 'stop_requested') {
      promptAction.showToast({ message: '正在安全取消连接', duration: 1400 });
    }
    this.flushInput('cancel_connect');
    this.closeSessionSurface();
  }

  private closeSessionSurface(): void {
    if (this.sessionWindowId.length > 0) {
      try {
        const context: common.UIAbilityContext =
          this.getUIContext().getHostContext() as common.UIAbilityContext;
        void context.terminateSelf();
      } catch (_err) {
        router.back();
      }
      return;
    }
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
    return this.pipPrepared && this.liveViewEnabled &&
      this.liveViewMode === LiveViewMode.AVSESSION && this.firstFrameSeen &&
      !this.routeTerminated;
  }

  private openSheet(mode: MoonlightSessionSheetMode): void {
    if (this.showConnectStage || this.surfaceRecovering || this.pendingConnectStageSheet) {
      return;
    }
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
    if (this.pendingConnectStageSheet || this.showConnectStage || this.surfaceRecovering) {
      this.pendingSheetMode = 'none';
      this.sheetMode = 'none';
      this.cancelSheetReopen();
      this.pendingConnectStageSheet = false;
      this.showConnectStageSheet = true;
      this.setNativeInputSuspended(true, 'overlay_opened');
      return;
    }
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
      if (this.keyboardOpen) { this.dismissMoonlightKeyboard(); }
      else { this.openMoonlightKeyboard(); }
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
    if (action === 'display') {
      void this.moveMoonlightToPip();
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
      controlMode: this.controlMode, sessionChangeCount: this.sessionChanges,
      audioAvailable: this.effectiveSettings.audio.enabled && this.audioReady,
      pipAvailable: this.pipAvailable(),
      controllerAvailable: this.controllerReady,
      physicalControllerPathReady: this.physicalControllerPathReady,
      keyboardAvailable: this.inputReady,
      diagnosticsVisible: this.diagnosticsVisible,
      onClose: (): void => { this.closeSheet(); },
      onOpenKeyboard: (): void => { this.closeSheet(); this.toolbarAction('keyboard'); },
      onOpenModifiers: (): void => {
        this.closeSheet(); this.flushInput('open_modifier_panel'); this.showModifierPanel = true;
      },
      onOpenController: (): void => { this.closeSheet(); this.toolbarAction('controller'); },
      onEnterPip: (): void => { this.closeSheet(); void this.moveMoonlightToPip(); },
      onToggleDiagnostics: (): void => { this.toggleDiagnosticsHud(); },
      onControlMode: (mode: MoonlightControlMode): void => {
        if (this.setNativeTouchMode(mode)) {
          this.controlMode = mode; this.sessionChanges += 1;
        }
      },
      onDisconnect: (): void => { this.openSheet('stop'); }
    })
  }

  @Builder private stopSheet() {
    Column() {
      Text('结束 Moonlight 串流？').fontSize(20).fontWeight(FontWeight.Bold).fontColor(this.pal().text)
      Text('可仅断开本地串流，也可在本地输入完全释放后结束主机端应用。')
        .fontSize(12).fontColor(this.pal().text3).lineHeight(18).margin({ top: 8 })
      Button('仅断开并保留主机应用').height(46).width('100%').borderRadius(13).fontSize(13)
        .backgroundColor(this.accentColor).fontColor(Color.White).margin({ top: 20 })
        .onClick((): void => {
          void this.terminateMoonlightSession('disconnect');
        })
        .enabled(!this.terminationBusy).opacity(this.terminationBusy ? 0.55 : 1)
      Button(this.terminationBusy ? '正在安全结束…' : '结束主机应用并断开')
        .height(46).width('100%').borderRadius(13).fontSize(13)
        .backgroundColor('#C43B3B').fontColor(Color.White).margin({ top: 9 })
        .onClick((): void => { void this.terminateMoonlightSession('quit'); })
        .enabled(!this.terminationBusy).opacity(this.terminationBusy ? 0.55 : 1)
      Button('取消').height(42).width('100%').borderRadius(12).fontSize(13)
        .backgroundColor(this.pal().surface).fontColor(this.pal().text2).margin({ top: 9 })
        .onClick((): void => { this.closeSheet(); })
        .enabled(!this.terminationBusy).opacity(this.terminationBusy ? 0.55 : 1)
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

  @Builder private moonlightKeyboardKey(label: string, keyCode: number,
    emphasized: boolean = false) {
    Button(label).height(38).constraintSize({ minWidth: 54 }).fontSize(12)
      .padding({ left: 13, right: 13 })
      .backgroundColor(emphasized ? this.accentColor : 'rgba(20,20,24,0.90)')
      .fontColor(Color.White).borderRadius(11)
      .onClick((): void => { this.sendMoonlightKeyTap(keyCode); })
  }

  @Builder private moonlightKeyboardAccessory() {
    Row() {
      Scroll() {
        Row({ space: 8 }) {
          this.moonlightKeyboardKey('Esc', MOONLIGHT_KEYCODE_ESCAPE)
          this.moonlightKeyboardKey('Tab', MOONLIGHT_KEYCODE_TAB)
          this.moonlightKeyboardKey('←', MOONLIGHT_KEYCODE_DPAD_LEFT)
          this.moonlightKeyboardKey('→', MOONLIGHT_KEYCODE_DPAD_RIGHT)
          this.moonlightKeyboardKey('退格', MOONLIGHT_KEYCODE_DEL)
          this.moonlightKeyboardKey('删除', MOONLIGHT_KEYCODE_FORWARD_DEL)
          this.moonlightKeyboardKey('Enter', MOONLIGHT_KEYCODE_ENTER, true)
        }.padding({ left: 8, right: 8 })
      }.scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off).layoutWeight(1)
      Button() {
        SymbolGlyph($r('sys.symbol.chevron_down'))
          .fontSize(18).fontColor([Color.White])
      }.width(42).height(38).borderRadius(11).margin({ left: 8, right: 8 })
        .backgroundColor('rgba(20,20,24,0.90)')
        .onClick((): void => { this.dismissMoonlightKeyboard(); })
        .accessibilityText('关闭虚拟键盘')
    }.width(this.breakpoint === 'sm' ? '96%' : '72%').height(50)
      .padding({ top: 6, bottom: 6 })
      .backgroundColor('rgba(0,0,0,0.34)').borderRadius(15)
      .border({ width: 0.5, color: 'rgba(255,255,255,0.18)' })
  }

  @Builder private connectStageSheet() {
    MoonlightConnectStageOverlay({
      inSheet: true,
      phase: this.surfaceRecovering ? 'reconnecting' : this.phase,
      elapsedMs: this.elapsedMs,
      firstFrameSeen: this.surfaceRecovering ? false : this.firstFrameSeen,
      errorCode: this.errorCode,
      degradationReasons: this.degradationReasons,
      onCancel: (): void => { this.cancelConnection(); },
      onRetry: (): void => { this.retryConnection(); },
      onDowngradeRetry: (): void => { this.retryConnection(); },
      onOpenDiagnostics: (): void => {
        this.diagnosticsVisible = true;
        this.diagnosticsExpanded = true;
        this.startDiagnosticsPolling();
      },
      onBackToCatalog: (): void => {
        this.flushInput('back_to_catalog');
        this.closeSessionSurface();
      }
    })
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
          if (this.pipPrepared) {
            const size: RemoteSessionPipContentSize = this.moonlightPipSize();
            const presentationLease: RemoteSessionServiceLease | null =
              this.currentMoonlightPresentationLease();
            if (presentationLease !== null) {
              RemoteSessionPipService.getInstance().updateContentSize(
                size.width, size.height, presentationLease);
            }
          }
        })

      MoonlightSessionToolbar({
        audioAvailable: this.effectiveSettings.audio.enabled && this.audioReady,
        controllerAvailable: this.controllerReady,
        pipAvailable: this.pipAvailable(),
        keyboardAvailable: this.inputReady,
        menuOpen: this.showSessionSheet,
        qualityColor: this.firstFrameSeen ? '#66DD7A' : '#FFCF70',
        qualityLabel: this.firstFrameSeen ? '串流中' : '连接中',
        onAction: (action: MoonlightToolbarAction): void => { this.toolbarAction(action); },
        onUnavailable: (reason: string): void => {
          promptAction.showToast({ message: reason, duration: 1800 });
        }
      }).align(this.toolbarLayout().edgeRail ? Alignment.TopEnd : Alignment.Top)
        .margin({ top: this.toolbarLayout().topOffset,
          right: this.toolbarLayout().edgeRail ? 4 : 0 })

      if (this.sessionWindowId.length > 0) {
        RemoteSessionFullscreenButton({
          fullscreen: this.sessionWindowFullscreen,
          onToggle: (): void => { this.toggleIndependentWindowFullscreen(); }
        })
          .align(Alignment.BottomEnd)
          .margin({ right: 16, bottom: 16 })
          .zIndex(220)
      }

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

      if (this.showController) {
        MoonlightControllerOverlay({
          inputCapabilityReady: this.inputReady && this.controllerReady,
          editing: this.controllerEditing,
          physicalControllerPathReady: this.physicalControllerPathReady,
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

      if (this.keyboardOpen) {
        Row() {
          this.moonlightKeyboardAccessory()
        }.width('100%').justifyContent(FlexAlign.Center)
          .align(Alignment.Bottom).margin({ bottom: 12 })
      }

      if (this.diagnosticsVisible && this.firstFrameSeen) {
        MoonlightDiagnosticsHud({
          snapshot: this.diagnosticsSnapshot,
          expanded: this.diagnosticsExpanded,
          x: this.diagnosticsX,
          y: this.diagnosticsY,
          onToggle: (): void => { this.diagnosticsExpanded = !this.diagnosticsExpanded; },
          onPositionChange: (x: number, y: number): void => {
            this.diagnosticsX = Math.max(0, x);
            this.diagnosticsY = Math.max(0, y);
          },
          onCopySanitized: (): void => { this.copySanitizedDiagnostics(); }
        })
      }

      TextArea({ text: this.keyboardText, controller: this.keyboardController })
        .id('MoonlightKeyboardProxy')
        .width(1).height(1).opacity(0.01)
        .fontColor('#00000000').backgroundColor('#00000000').caretColor('#00000000')
        .border({ width: 0 }).position({ x: '50%', y: '50%' })
        .hitTestBehavior(HitTestMode.Transparent)
        .focusable(true).defaultFocus(false).focusOnTouch(false)
        .enableKeyboardOnFocus(this.keyboardOpen)
        .enablePreviewText(REMOTE_IME_PREVIEW_ENABLED)
        .selectionMenuHidden(true).enterKeyType(EnterKeyType.Send)
        .onWillInsert((info: InsertValue): boolean => this.handleMoonlightImeWillInsert(info))
        .onDidInsert((info: InsertValue): void => { this.handleMoonlightImeDidInsert(info); })
        .onWillDelete((info: DeleteValue): boolean => this.handleMoonlightImeWillDelete(info))
        .onDidDelete((info: DeleteValue): void => { this.handleMoonlightImeDidDelete(info); })
        .onTextSelectionChange((start: number, end: number): void => {
          this.handleMoonlightImeSelectionChange(start, end);
        })
        .onEditChange((editing: boolean): void => {
          if (editing) { this.keyboardImeEditingObserved = true; return; }
          if (this.keyboardOpen && this.keyboardImeEditingObserved &&
              !this.keyboardProgrammaticSelection) {
            this.keyboardOpen = false;
            this.flushInput('ime-dismissed');
            this.resetMoonlightImeSession('ime-dismissed');
          }
        })
        .onChange((value: string, previewText?: PreviewText): void => {
          const previewUnits: number = previewText ? previewText.value.length : 0;
          if (shouldAcceptRemoteImeTextChange(this.keyboardImeActive, previewUnits)) {
            this.keyboardText = value;
          }
        })
        .onSubmit((_enterKey: EnterKeyType, event: SubmitEvent): void => {
          event.keepEditableState();
          this.keyboardCommandQueue.enqueueKeyTaps(
            MOONLIGHT_KEYCODE_ENTER, 1, this.keyboardImeGeneration, 'submit');
          this.scheduleMoonlightImeCommandPump();
        })

      // The connection gate is mounted through a native BindSheet below.
      // Keeping it out of this Stack prevents a centered overlay from being
      // mistaken for a connected stream while the first frame is pending.
      Column().width('100%').height('100%')
        .hitTestBehavior(this.showConnectStageSheet ? HitTestMode.Default : HitTestMode.None)
        .bindSheet($$this.showConnectStageSheet, this.connectStageSheet(), {
          height: SheetSize.FIT_CONTENT,
          preferType: this.breakpoint === 'sm' ? SheetType.BOTTOM : SheetType.CENTER,
          dragBar: false,
          backgroundColor: '#0E121C',
          blurStyle: BlurStyle.NONE,
          showClose: false,
          maskColor: 'rgba(0,0,0,0.62)',
          onWillDismiss: (action: DismissSheetAction): void => {
            if (this.showConnectStageSheet) { this.cancelConnection(); }
            action.dismiss();
          }
        })
    }.width('100%').height('100%').backgroundColor('#000000')
      .bindSheet($$this.showSessionSheet, this.sessionSheet(), {
        height: this.sheetMode === 'control' ? '86%' : SheetSize.FIT_CONTENT,
        preferType: this.breakpoint === 'sm' ? SheetType.BOTTOM : SheetType.CENTER,
        dragBar: false, showClose: false,
        onDisappear: (): void => { this.onSheetDisappear(); }
      })
  }
}
