import { display, promptAction, router, window } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { connection } from '@kit.NetworkKit';
import { KeyCode, pointer } from '@kit.InputKit';
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
import { MoonlightPhysicalControllerSheet } from '../components/moonlight/MoonlightPhysicalControllerSheet';
import { RemoteSessionFullscreenButton } from '../components/RemoteSessionFullscreenButton';
import { RemoteCursorOverlay, RemoteCursorOverlayState } from '../components/RemoteCursorOverlay';
import { normalizeRemoteCursorStyle } from '../services/RemoteCursorStylePolicy';
import { RemoteModifierPanel } from '../components/RemoteModifierPanel';
import {
  RemoteCustomShortcut,
  RemoteCustomShortcutUpdate,
  removeRemoteCustomShortcut,
  upsertRemoteCustomShortcut
} from '../services/RemoteCustomShortcutPolicy';
import { RemoteKeyboardSettingsService } from '../services/RemoteKeyboardSettingsService';
import { RemoteShortcutPlatform } from '../services/RemoteKeyboardSettingsPolicy';
import {
  MoonlightEffectiveSettings,
  MoonlightInputControlMode,
  MoonlightKeyboardTarget,
  MoonlightSettings,
  defaultMoonlightSettings,
  moonlightInputControlMode
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
  MoonlightAdaptiveInputSource,
  MoonlightDiagnosticsSnapshot,
  MoonlightResolvedControlMode,
  MOONLIGHT_DISAPPEAR_BACKGROUND_SIGNAL_WAIT_MS,
  MOONLIGHT_PRESENTATION_STALL_MS,
  moonlightConnectSheetMountReady,
  moonlightAdaptiveControlModeForSource,
  moonlightInitialAdaptiveControlMode,
  moonlightPhysicalKeyboardCaptureEnabled,
  moonlightResolvedControlMode,
  moonlightRouteIdentity,
  moonlightSystemKeyReserved,
  moonlightToolbarLayout,
  moonlightUsesEntryAbilityImmersiveBars,
  shouldDeferMoonlightDisappear
} from '../services/MoonlightUiPolicy';
import { REMOTE_SESSION_COLLAPSED_RAIL_TOUCH_WIDTH } from
  '../services/RemoteSessionTopBarPolicy';
import {
  clampTouchpadEffectiveGain,
  resetTouchpadPointerCurveState,
  TouchpadPointerCurveState,
  touchpadPointerCurve
} from '../services/TouchpadPointerCurvePolicy';
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
  RemoteSessionPipRestoreTarget,
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
import {
  MoonlightImeKeyStroke,
  moonlightImeAsciiKeyStroke
} from '../services/MoonlightImeTextInputPolicy';
import {
  moonlightDecoderCapability,
  probeMoonlightHardwareDecoderCapabilities
} from '../services/MoonlightVideoCapabilityService';
import { normalizeRendererViewportToSurface } from
  '../services/RemoteSurfaceTransformPolicy';
import {
  mapPhysicalKeyForRemoteLayout,
  RemoteKeyboardLayout,
  remoteKeyboardLayoutDescription,
  shouldChoosePhysicalKeyboardLayout
} from '../services/RemotePhysicalKeyboardPolicy';
import {
  shouldHideSystemPointerForEmbeddedRemoteCursor
} from '../services/RemotePointerModePolicy';

const MOONLIGHT_KEYCODE_DPAD_LEFT = 2014;
const MOONLIGHT_KEYCODE_DPAD_RIGHT = 2015;
const MOONLIGHT_KEYCODE_ENTER = 2054;
const MOONLIGHT_KEYCODE_DEL = 2055;
const MOONLIGHT_KEYCODE_FORWARD_DEL = 2071;
const MOONLIGHT_KEYCODE_SHIFT_LEFT = 2047;
const MOONLIGHT_IME_SELECTION_ACK_TIMEOUT_MS = 600;
const MOONLIGHT_IME_COMMAND_RETRY_MS = 50;
const MOONLIGHT_DIAGNOSTICS_POLL_MS = 250;
const MOONLIGHT_DIAGNOSTICS_NEW_SAMPLE_WEIGHT = 0.65;
// Keep virtual-trackpad travel stable across phone and Pad sizes. The scale is
// derived from the whole reference-plane area below, so X/Y always retain the
// same gain instead of feeling different when the viewport aspect ratio does.
const MOONLIGHT_TRACKPAD_REFERENCE_WIDTH = 1280;
const MOONLIGHT_TRACKPAD_REFERENCE_HEIGHT = 720;
const MOONLIGHT_TRACKPAD_MAX_LOCAL_STEP_RATIO = 0.75;
const MOONLIGHT_TRACKPAD_MAX_LOCAL_STEP_VP = 420;
// ArkUI can report touch motion faster than the streamed desktop can present
// it. Dispatch at most once per 60 Hz presentation interval and preserve the
// complete accumulated delta. This avoids starving decoder presentation with
// synchronous NAPI calls while keeping pointer/button ordering deterministic.
const MOONLIGHT_TRACKPAD_WIRE_INTERVAL_MS = 16;
const MOONLIGHT_RENDERER_VIEWPORT_CACHE_MS = 250;

const EMPTY_MOONLIGHT_DIAGNOSTICS: MoonlightDiagnosticsSnapshot = {
  available: false, transportReady: false, videoReady: false, audioReady: false,
  inputReady: false, fps: -1, latencyMs: -1, bitrateKbps: -1,
  configuredBitrateKbps: -1, packetLossPercent: -1, codec: '', width: 0, height: 0,
  targetFps: -1, acceptedVideoFrames: 0, droppedVideoFrames: 0,
  decoderQueueDepth: -1,
  decodeP50Us: -1, decodeP95Us: -1, renderP50Us: -1, renderP95Us: -1,
  codecLatencyMs: -1, codecLatencyMaxMs: -1, surfaceUpdateFailures: 0,
  surfaceCoalescedNotifications: 0, acceptedAudioPackets: 0,
  rejectedAudioPackets: 0, audioBytes: 0, audioUnderruns: -1,
  inputAccepted: 0, inputDrops: -1, presentedFrames: 0, videoBytes: 0,
  ingressAgeMs: -1, presentationAgeMs: -1, stalled: false
};

class MoonlightStreamXComponentController extends XComponentController {
  onSurface: (surfaceId: string) => void = (_surfaceId: string): void => {};
  onSurfaceDetached: (surfaceId: string) => void = (_surfaceId: string): void => {};
  onSurfaceCreated(surfaceId: string): void { this.onSurface(surfaceId); }
  onSurfaceDestroyed(surfaceId: string): void { this.onSurfaceDetached(surfaceId); }
}

type MoonlightSessionSheetMode = 'none' | 'connect' | 'control' | 'controller' | 'stop';
type MoonlightPointerAction = 'relative' | 'absolute' | 'absoluteButton' | 'button' | 'scroll';
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

interface MoonlightPhysicalPointerGeometry {
  contentLeft: number;
  contentTop: number;
  contentWidth: number;
  contentHeight: number;
  referenceWidth: number;
  referenceHeight: number;
  signature: string;
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
  @StorageLink('virtualMouseStyle') @Watch('onVirtualMouseStyleChanged')
  virtualMouseStyle: string = 'arrow';
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
  @State pendingConnectStageSheet: boolean = false;
  @State showSessionSheet: boolean = false;
  @State sheetMode: MoonlightSessionSheetMode = 'none';
  @State pendingSheetMode: MoonlightSessionSheetMode = 'none';
  @State controlMode: MoonlightControlMode = 'adaptive';
  @State adaptiveControlMode: MoonlightResolvedControlMode = 'trackpad';
  @State sessionChanges: number = 0;
  @State showController: boolean = false;
  @State controllerEditing: boolean = false;
  @State showModifierPanel: boolean = false;
  @State showShortcutPanel: boolean = false;
  @State modifierPanelX: number = 8;
  @State modifierPanelY: number = 62;
  @State shortcutPanelX: number = 8;
  @State shortcutPanelY: number = 62;
  @State modifierPanelWidth: number = 320;
  @State modifierPanelHeight: number = 430;
  @State shortcutPanelWidth: number = 320;
  @State shortcutPanelHeight: number = 430;
  @State remoteCustomShortcuts: Array<RemoteCustomShortcut> = [];
  @State keyboardOpen: boolean = false;
  @State keyboardText: string = '';
  @State diagnosticsVisible: boolean = false;
  @State diagnosticsExpanded: boolean = false;
  @State diagnosticsX: number = 18;
  @State diagnosticsY: number = 18;
  @State diagnosticsSnapshot: MoonlightDiagnosticsSnapshot = EMPTY_MOONLIGHT_DIAGNOSTICS;
  // ArkUI reliably observes this primitive even on platform revisions where
  // an interface-typed @Prop object can retain its first rendered value.
  // Advancing it with every native sample keeps every HUD metric live without
  // requiring a collapse/expand reconstruction.
  @State diagnosticsSampleEpoch: number = 0;
  @State ctrlLatch: string = 'off';
  @State altLatch: string = 'off';
  @State shiftLatch: string = 'off';
  @State winLatch: string = 'off';
  @State fnLayer: boolean = false;
  @State inputFlushCount: number = 0;
  @State surfaceRecovering: boolean = false;
  @State pipPrepared: boolean = false;
  @State terminationBusy: boolean = false;
  @State trackpadCursorOverlayState: RemoteCursorOverlayState =
    new RemoteCursorOverlayState();
  private readonly sessionCoordinator: MoonlightSessionCoordinator =
    MoonlightSessionCoordinator.getInstance();
  // getUniqueId() returns -1 until the component node exists. Capture the
  // @Entry page ID from lifecycle/runtime code instead of a field initializer
  // so PiP can restore this exact stream route.
  private pipRestorePageId: number = -1;
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
  private virtualKeyboardFocusTimer: number = -1;
  private physicalKeyboardFocusTimer: number = -1;
  private physicalKeyboardProxyFocused: boolean = false;
  private customShortcutSequence: number = 0;
  private diagnosticsTimer: number = -1;
  private diagnosticsPreviousSampleMs: number = 0;
  private diagnosticsPreviousPresentedFrames: number = 0;
  private diagnosticsPreviousVideoBytes: number = 0;
  private diagnosticsLastPresentedProgressSampleMs: number = 0;
  private diagnosticsLastIngressProgressSampleMs: number = 0;
  private diagnosticsSmoothedFps: number = -1;
  private diagnosticsSmoothedBitrateKbps: number = -1;
  private diagnosticsLatestSnapshot: MoonlightDiagnosticsSnapshot =
    EMPTY_MOONLIGHT_DIAGNOSTICS;
  private pendingDisappearDecisionTimer: number = -1;
  private disappearDecisionGeneration: number = 0;
  private routeExitAfterSheetDisappear: boolean = false;
  private launchKey: MoonlightNativeRequestKey = { requestId: 0, generation: 0, ownerToken: 0 };
  private serverUuid: string = '';
  private numericAppId: number = 0;
  private hostAddress: string = '';
  private surfaceId: string = '';
  private pageSurfaceId: string = '';
  private pipSurfaceId: string = '';
  private surfaceWidthPx: number = 1920;
  private surfaceHeightPx: number = 1080;
  @State private surfaceWidthVp: number = 1;
  @State private surfaceHeightVp: number = 1;
  @State orientationApplied: boolean = false;
  private orientationRequestGeneration: number = 0;
  private moonlightSystemBarRequestId: number = 0;
  private moonlightSystemBarsHidden: boolean = false;
  private moonlightSystemBarUpdate: Promise<void> = Promise.resolve();
  private moonlightSystemPointerVisible: boolean | null = null;
  private moonlightRemoteSurfaceHovered: boolean = false;
  @State private physicalKeyboardLayout: RemoteKeyboardLayout = RemoteKeyboardLayout.WINDOWS;
  @State private physicalKeyboardLayoutConfirmed: boolean = false;
  private physicalKeyboardLayoutPromptVisible: boolean = false;
  private surfaceLayoutReady: boolean = false;
  private rendererSurfaceWidthPx: number = 0;
  private rendererSurfaceHeightPx: number = 0;
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
  private physicalPointerGeometryCache: MoonlightPhysicalPointerGeometry | null = null;
  private physicalPointerGeometryHandle: number = -1;
  private physicalPointerGeometryReadAtMs: number = 0;
  private physicalPointerGeometrySignature: string = '';
  private physicalMouseObservedEvents: number = 0;
  private hitMapGeneration: number = 1;
  private trackpadVisualTouches: Map<number, MoonlightTouchPoint> =
    new Map<number, MoonlightTouchPoint>();
  private trackpadCursorX: number = 0;
  private trackpadCursorY: number = 0;
  private trackpadCursorInitialized: boolean = false;
  private trackpadCursorRevision: number = 0;
  private trackpadGestureStartedAtMs: number = 0;
  private trackpadGestureMaximumTravel: number = 0;
  private trackpadPeakContactCount: number = 0;
  private trackpadGestureMoved: boolean = false;
  private trackpadDragActive: boolean = false;
  private trackpadScrollCentroidX: number = 0;
  private trackpadScrollCentroidY: number = 0;
  private trackpadScrollCentroidValid: boolean = false;
  private trackpadCurveState: TouchpadPointerCurveState =
    resetTouchpadPointerCurveState();
  private trackpadLocalAcceptedEvents: number = 0;
  private trackpadLocalRejectedEvents: number = 0;
  private trackpadPendingDeltaX: number = 0;
  private trackpadPendingDeltaY: number = 0;
  private trackpadPointerFlushTimer: number = -1;
  private trackpadLastPointerDispatchMs: number = 0;
  private inputSuspended: boolean = false;
  private inputSuspensionAppliedOwnerToken: number = 0;
  private rendererHandle: number = -1;
  private streamStartAttempted: boolean = false;
  private surfacePollTimer: number = -1;
  private surfaceRecoveryTimer: number = -1;
  private surfaceRecoveryGeneration: number = 0;
  private sessionReserved: boolean = false;
  private routeTerminated: boolean = false;
  private modifierPanelUserPositioned: boolean = false;
  private shortcutPanelUserPositioned: boolean = false;
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
  private reconnectWindow: MoonlightReconnectWindow | null = null;
  private reconnectTimer: number = -1;
  private reconnectGeneration: number = 0;
  private reconnectInFlight: boolean = false;
  private reconnectRuntimeLaunched: boolean = false;
  private requestedTerminalAction: MoonlightSessionRecoveryTerminalAction = 'none';
  private terminalRouteExitTimer: number = -1;
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
    // Rotation and PIP foreground restore are presentation handoffs, not new
    // connection attempts. Reusing the connection Sheet during those handoffs
    // leaves its dark mask above a healthy renderer and can flash stale errors.
    // Once route teardown begins, every terminal native snapshot is expected.
    // Never remount the connection/failure Sheet above an intentional exit.
    const gateNeeded: boolean = this.showConnectStage && !this.routeTerminated;
    if (!gateNeeded) {
      this.pendingConnectStageSheet = false;
      if (this.sheetMode === 'connect') {
        this.sheetReopenGeneration += 1;
        this.cancelSheetReopen();
        this.showSessionSheet = false;
      }
      return;
    }
    if (!moonlightConnectSheetMountReady(gateNeeded, this.surfaceLayoutReady)) {
      this.pendingConnectStageSheet = true;
      return;
    }
    // Connection progress and session controls deliberately share one native
    // Sheet host. Two BindSheet hosts on the rotating stream page can leave
    // an invisible SheetPage above the XComponent after first frame.
    if (this.showSessionSheet && this.sheetMode !== 'connect') {
      this.pendingConnectStageSheet = true;
      this.pendingSheetMode = 'none';
      this.sheetReopenGeneration += 1;
      this.cancelSheetReopen();
      this.showSessionSheet = false;
      return;
    }
    this.pendingConnectStageSheet = false;
    this.pendingSheetMode = 'none';
    this.sheetMode = 'connect';
    this.showSessionSheet = true;
  }

  private connectStageGateActive(): boolean {
    return this.pageActive && this.showConnectStage;
  }

  private setConnectStageVisible(visible: boolean): void {
    this.showConnectStage = visible;
    this.syncConnectStageSheet();
  }

  private setSurfaceRecovering(recovering: boolean): void {
    this.surfaceRecovering = recovering;
    this.publishTrackpadCursor();
  }

  private clearMoonlightContextualGuideRetry(): void {
    if (this.contextualGuideRetryTimer >= 0) {
      clearTimeout(this.contextualGuideRetryTimer);
      this.contextualGuideRetryTimer = -1;
    }
  }

  private moonlightContextualGuideSessionIdentity(): string {
    if (this.hostId.trim().length === 0 || this.appId.trim().length === 0 ||
      !Number.isSafeInteger(this.launchKey.requestId) || this.launchKey.requestId <= 0 ||
      !Number.isSafeInteger(this.launchKey.generation) || this.launchKey.generation <= 0 ||
      !Number.isSafeInteger(this.launchKey.ownerToken) || this.launchKey.ownerToken <= 0) {
      return '';
    }
    return 'moonlight|' + this.hostId.trim() + '|' + this.appId.trim() + '|' +
      this.launchKey.requestId.toString() + '|' + this.launchKey.generation.toString() + '|' +
      this.launchKey.ownerToken.toString();
  }

  private scheduleMoonlightContextualGuide(delayMs: number = 240): void {
    if (this.contextualGuideRetryTimer >= 0 || !this.pageActive || this.routeTerminated) { return; }
    this.contextualGuideRetryTimer = setTimeout((): void => {
      this.contextualGuideRetryTimer = -1;
      this.maybeShowMoonlightContextualGuide();
      const guide: SessionContextualGuide = sessionContextualGuide('moonlight',
        guideDeviceFor(this.isDesktopDevice, this.isPadDevice, this.breakpoint));
      const guideVisibility: GuideVisibilityService = GuideVisibilityService.getInstance();
      const alreadyShown: boolean = guideVisibility.wasShown(
        getContext(this) as common.Context, guide.storageKey);
      const shownInRuntimeSession: boolean = guideVisibility.wasShownInRuntimeSession(
        guide.storageKey, this.moonlightContextualGuideSessionIdentity());
      const ready: boolean = this.pageActive && !this.routeTerminated &&
        this.phase === 'streaming' && this.firstFrameSeen;
      if (shouldRetrySessionContextualGuide(
        ready, alreadyShown, this.guideAlwaysVisible,
        shownInRuntimeSession) && !this.appInBackground) {
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
    const guideVisibility: GuideVisibilityService = GuideVisibilityService.getInstance();
    const sessionIdentity: string = this.moonlightContextualGuideSessionIdentity();
    const alreadyShown: boolean = guideVisibility.wasShown(
      getContext(this) as common.Context, guide.storageKey);
    const shownInRuntimeSession: boolean = guideVisibility.wasShownInRuntimeSession(
      guide.storageKey, sessionIdentity);
    const blockingOverlayVisible: boolean = this.showSessionSheet || this.showModifierPanel ||
      this.showShortcutPanel || this.showController || this.keyboardOpen || this.surfaceRecovering;
    if (!shouldShowSessionContextualGuide(
      this.pageActive && !this.appInBackground && !this.routeTerminated &&
        this.phase === 'streaming' && this.firstFrameSeen, alreadyShown,
      blockingOverlayVisible, this.guideAlwaysVisible,
      shownInRuntimeSession)) {
      return;
    }
    try {
      this.getUIContext().getPromptAction().showToast({
        message: guide.message,
        duration: guide.durationMs
      });
      guideVisibility.markShownInRuntimeSession(guide.storageKey, sessionIdentity);
      guideVisibility.markShown(getContext(this) as common.Context, guide.storageKey);
    } catch (_) {}
  }

  private toolbarLayout(): MoonlightToolbarLayout {
    return moonlightToolbarLayout(this.isDesktopDevice, this.breakpoint, this.isPadDevice);
  }

  private trackpadInputSurfaceWidth(): number {
    const viewportWidth: number = Number.isFinite(this.surfaceWidthVp) ?
      Math.max(1, this.surfaceWidthVp) : 1;
    const layout: MoonlightToolbarLayout = this.toolbarLayout();
    if (!layout.edgeRail) { return viewportWidth; }
    // The remote input surface must never overlap the right rail. Reserve the
    // complete expanded rail width, not only the translucent collapsed handle,
    // so every rail button remains independently clickable in either state.
    const railWidth: number = Math.max(
      REMOTE_SESSION_COLLAPSED_RAIL_TOUCH_WIDTH, layout.iconSize + 32);
    return Math.max(1, viewportWidth - railWidth);
  }

  private toolbarControlModeLabel(): string {
    if (this.controlMode === 'keyboardMouse') {
      return '键鼠·' + this.physicalKeyboardLayoutLabel();
    }
    if (this.controlMode === 'trackpad') { return '触控板'; }
    return this.adaptiveControlMode === 'keyboardMouse' ?
      '自适应·键鼠·' + this.physicalKeyboardLayoutLabel() : '自适应·触控板';
  }

  private physicalKeyboardLayoutLabel(): string {
    if (!this.physicalKeyboardLayoutConfirmed) { return '待选'; }
    return this.physicalKeyboardLayout === RemoteKeyboardLayout.MACOS ? 'macOS' : 'Windows';
  }

  private applyConfiguredKeyboardTarget(target: MoonlightKeyboardTarget | undefined): void {
    this.physicalKeyboardLayout = target === 'macos' ?
      RemoteKeyboardLayout.MACOS : RemoteKeyboardLayout.WINDOWS;
    this.physicalKeyboardLayoutConfirmed = target === 'windows' || target === 'macos';
    this.physicalKeyboardLayoutPromptVisible = false;
  }

  private moonlightPointerInteractionBlocked(): boolean {
    return this.appInBackground || this.routeTerminated || this.inputSuspended ||
      this.showSessionSheet || this.keyboardOpen || this.showModifierPanel ||
      this.showShortcutPanel || this.showController;
  }

  private shouldHideMoonlightSystemPointer(): boolean {
    return shouldHideSystemPointerForEmbeddedRemoteCursor(
      this.firstFrameSeen && this.inputReady,
      this.resolvedMoonlightControlMode() === 'keyboardMouse',
      this.moonlightRemoteSurfaceHovered,
      this.moonlightPointerInteractionBlocked());
  }

  private setMoonlightSystemPointerVisible(visible: boolean, reason: string,
    force: boolean = false): void {
    if (!force && this.moonlightSystemPointerVisible === visible) { return; }
    try {
      pointer.setPointerVisibleSync(visible);
      this.moonlightSystemPointerVisible = visible;
      hilog.info(0x0014, 'MoonlightStreamUi',
        'system pointer visible=' + (visible ? '1' : '0') + ' reason=' + reason);
    } catch (error) {
      hilog.warn(0x0014, 'MoonlightStreamUi',
        'system pointer visibility failed reason=' + reason +
        ' error=' + JSON.stringify(error));
    }
  }

  private syncMoonlightSystemPointer(reason: string, force: boolean = false): void {
    this.setMoonlightSystemPointerVisible(
      !this.shouldHideMoonlightSystemPointer(), reason, force);
  }

  private restoreMoonlightSystemPointer(reason: string): void {
    this.setMoonlightSystemPointerVisible(true, reason, true);
  }

  private handleMoonlightRemoteSurfaceHover = (hovered: boolean): void => {
    const changed: boolean = this.moonlightRemoteSurfaceHovered !== hovered;
    this.moonlightRemoteSurfaceHovered = hovered;
    this.syncMoonlightSystemPointer('surface-hover', changed);
  };

  private resolvedMoonlightControlMode(): MoonlightResolvedControlMode {
    return moonlightResolvedControlMode(this.controlMode, this.adaptiveControlMode);
  }

  private observeMoonlightAdaptiveInput(source: MoonlightAdaptiveInputSource): void {
    if (this.controlMode !== 'adaptive') { return; }
    const next: MoonlightResolvedControlMode = moonlightAdaptiveControlModeForSource(
      this.controlMode, this.adaptiveControlMode, source);
    if (next === this.adaptiveControlMode) { return; }
    this.cancelActiveMoonlightTouches();
    this.adaptiveControlMode = next;
    this.setNativeTouchMode(next);
    this.publishTrackpadCursor();
    this.syncMoonlightSystemPointer('adaptive-input-' + source);
    if (next === 'keyboardMouse') {
      this.scheduleMoonlightPhysicalKeyboardFocus('adaptive-' + source);
    }
  }

  private commitMoonlightControlMode(mode: MoonlightInputControlMode,
    countAsSessionChange: boolean = true): void {
    if (mode === this.controlMode) {
      this.syncMoonlightSystemPointer('control-mode-unchanged');
      return;
    }
    this.cancelActiveMoonlightTouches();
    this.controlMode = mode;
    if (mode === 'adaptive') {
      this.adaptiveControlMode = moonlightInitialAdaptiveControlMode(
        this.isPadDevice, this.isDesktopDevice, this.sessionWindowId);
    }
    this.setNativeTouchMode(this.resolvedMoonlightControlMode());
    this.clampAndPublishTrackpadCursor();
    if (countAsSessionChange) { this.sessionChanges += 1; }
    this.physicalKeyboardProxyFocused = false;
    this.scheduleMoonlightPhysicalKeyboardFocus('control-mode-change');
    this.syncMoonlightSystemPointer('control-mode-change', true);
  }

  private applyMoonlightControlMode(mode: MoonlightInputControlMode,
    countAsSessionChange: boolean = true): void {
    if (mode === 'keyboardMouse') {
      this.promptPhysicalKeyboardLayout((layout: RemoteKeyboardLayout): void => {
        this.physicalKeyboardLayout = layout;
        this.physicalKeyboardLayoutConfirmed = true;
        this.commitMoonlightControlMode(mode, countAsSessionChange);
      });
      return;
    }
    this.commitMoonlightControlMode(mode, countAsSessionChange);
  }

  private nextMoonlightControlMode(): MoonlightInputControlMode {
    if (this.controlMode === 'adaptive') { return 'keyboardMouse'; }
    if (this.controlMode === 'keyboardMouse') { return 'trackpad'; }
    return 'adaptive';
  }

  private clampMoonlightPanelX(x: number, width: number): number {
    const maximum: number = Math.max(8, this.surfaceWidthVp - Math.max(1, width) - 8);
    return Math.min(maximum, Math.max(8, x));
  }

  private clampMoonlightPanelY(y: number, height: number): number {
    const maximum: number = Math.max(8, this.surfaceHeightVp - Math.max(1, height) - 8);
    return Math.min(maximum, Math.max(8, y));
  }

  private placeMoonlightModifierPanel(shortcut: boolean): void {
    if (shortcut) {
      if (!this.shortcutPanelUserPositioned) {
        this.shortcutPanelX = this.clampMoonlightPanelX(
          this.surfaceWidthVp - this.shortcutPanelWidth - 8, this.shortcutPanelWidth);
        this.shortcutPanelY = this.clampMoonlightPanelY(62, this.shortcutPanelHeight);
      }
      return;
    }
    if (!this.modifierPanelUserPositioned) {
      this.modifierPanelX = this.clampMoonlightPanelX(
        this.surfaceWidthVp - this.modifierPanelWidth - 8, this.modifierPanelWidth);
      this.modifierPanelY = this.clampMoonlightPanelY(62, this.modifierPanelHeight);
    }
  }

  private reflowMoonlightModifierPanels(): void {
    if (this.modifierPanelUserPositioned) {
      this.modifierPanelX = this.clampMoonlightPanelX(
        this.modifierPanelX, this.modifierPanelWidth);
      this.modifierPanelY = this.clampMoonlightPanelY(
        this.modifierPanelY, this.modifierPanelHeight);
    } else {
      this.placeMoonlightModifierPanel(false);
    }
    if (this.shortcutPanelUserPositioned) {
      this.shortcutPanelX = this.clampMoonlightPanelX(
        this.shortcutPanelX, this.shortcutPanelWidth);
      this.shortcutPanelY = this.clampMoonlightPanelY(
        this.shortcutPanelY, this.shortcutPanelHeight);
    } else {
      this.placeMoonlightModifierPanel(true);
    }
  }

  private moveMoonlightModifierPanel(x: number, y: number, shortcut: boolean): void {
    if (shortcut) {
      this.shortcutPanelX = this.clampMoonlightPanelX(x, this.shortcutPanelWidth);
      this.shortcutPanelY = this.clampMoonlightPanelY(y, this.shortcutPanelHeight);
      this.shortcutPanelUserPositioned = true;
      return;
    }
    this.modifierPanelX = this.clampMoonlightPanelX(x, this.modifierPanelWidth);
    this.modifierPanelY = this.clampMoonlightPanelY(y, this.modifierPanelHeight);
    this.modifierPanelUserPositioned = true;
  }

  private updateMoonlightModifierPanelSize(width: number, height: number,
    shortcut: boolean): void {
    if (shortcut) {
      this.shortcutPanelWidth = width;
      this.shortcutPanelHeight = height;
    } else {
      this.modifierPanelWidth = width;
      this.modifierPanelHeight = height;
    }
    this.reflowMoonlightModifierPanels();
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
    this.cancelPendingMoonlightDisappearDecision();
    this.refreshMoonlightPipRestorePageId('about-to-appear');
    if (this.pageActive && !this.routeTerminated && this.nativeSessionId > 0) {
      const background: boolean = this.currentMoonlightAbilityBackgroundState();
      hilog.info(0x0014, 'MoonlightStreamUi',
        'aboutToAppear preserved-session nativeSessionId=' + this.nativeSessionId.toString() +
        ' background=' + background.toString());
      if (!background) {
        void this.setMoonlightSystemBarsHidden(true, 'preserved-page-appear');
        this.applyMoonlightAbilityBackground(false);
        this.scheduleMoonlightPhysicalKeyboardFocus('preserved-page-appear');
        this.syncMoonlightSystemPointer('preserved-page-appear', true);
      }
      return;
    }
    hilog.info(0x0014, 'MoonlightStreamUi', 'aboutToAppear begin');
    this.pageActive = true;
    this.remoteCustomShortcuts = RemoteKeyboardSettingsService.getInstance()
      .loadCustomShortcuts(getContext(this) as common.Context);
    hilog.info(0x0014, 'MoonlightStreamUi', 'aboutToAppear keyboard-settings-ready');
    this.sheetReopenGeneration += 1;
    const params: Record<string, Object> = router.getParams() as Record<string, Object>;
    this.sessionWindowId = typeof params['sessionWindowId'] === 'string'
      ? (params['sessionWindowId'] as string).trim() : '';
    void this.setMoonlightSystemBarsHidden(true, 'page-appear');
    this.appInBackground = this.sessionWindowId.length > 0 ?
      this.sessionWindowBackground : this.appBackgroundSignal;
    const route: MoonlightRouteIdentity = moonlightRouteIdentity(params, true);
    this.hostId = route.valid ? route.hostId : '';
    this.appId = route.valid ? route.appId : '';
    hilog.info(0x0014, 'MoonlightStreamUi',
      'aboutToAppear route-valid=' + (route.valid ? '1' : '0'));
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
      this.controlMode = moonlightInputControlMode(
        settingsSnapshot.effective.input.controlMode,
        settingsSnapshot.effective.input.touchMode);
    } else {
      this.effectiveSettingsEncoded = '';
      this.effectiveSettings = defaultMoonlightSettings();
      this.controlMode = moonlightInputControlMode(
        this.effectiveSettings.input.controlMode, this.effectiveSettings.input.touchMode);
    }
    this.applyConfiguredKeyboardTarget(this.effectiveSettings.input.keyboardTarget);
    this.adaptiveControlMode = moonlightInitialAdaptiveControlMode(
      this.isPadDevice, this.isDesktopDevice, this.sessionWindowId);
    this.diagnosticsVisible = this.effectiveSettings.diagnostics.showPerformanceHud;
    this.diagnosticsExpanded = false;
    this.diagnosticsSnapshot = EMPTY_MOONLIGHT_DIAGNOSTICS;
    this.diagnosticsSampleEpoch = 0;
    this.diagnosticsLatestSnapshot = EMPTY_MOONLIGHT_DIAGNOSTICS;
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
    this.discardPendingTrackpadPointer();
    this.resetTrackpadGesture(false);
    this.trackpadLocalAcceptedEvents = 0;
    this.trackpadLocalRejectedEvents = 0;
    this.physicalMouseObservedEvents = 0;
    this.moonlightRemoteSurfaceHovered = false;
    this.restoreMoonlightSystemPointer('page-appear');
    this.trackpadCursorInitialized = false;
    this.publishTrackpadCursor();
    this.sessionGeneration = 0;
    this.sessionStartedAtMs = 0;
    this.clearElapsedTimer();
    this.keyboardOpen = false;
    this.showModifierPanel = false;
    this.showShortcutPanel = false;
    this.resetMoonlightImeSession('page-appear');
    this.phase = 'discovering';
    this.streamStartAttempted = false;
    this.sessionReserved = false;
    this.routeTerminated = false;
    this.routeExitAfterSheetDisappear = false;
    this.orientationApplied = this.isDesktopDevice || this.sessionWindowId.length > 0;
    this.surfaceLayoutReady = false;
    this.rendererSurfaceWidthPx = 0;
    this.rendererSurfaceHeightPx = 0;
    this.nativeSurfaceAttached = false;
    this.surfaceSuspended = false;
    this.setSurfaceRecovering(false);
    this.setConnectStageVisible(true);
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
    this.clearTerminalRouteExitTimer();
    this.reservedOwnerScopeId = '';
    this.reservedAccountGeneration = 0;
    const scope: AccountScopeToken = AccountSessionCoordinator.getInstance().currentScope();
    this.routeOwnerValidated = this.routeOwnerMatches(scope);
    hilog.info(0x0014, 'MoonlightStreamUi',
      'aboutToAppear owner-valid=' + (this.routeOwnerValidated ? '1' : '0'));
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
    hilog.info(0x0014, 'MoonlightStreamUi', 'aboutToAppear recovery-ready');
    this.recoveryBound = true;
    if (!this.isDesktopDevice && this.sessionWindowId.length === 0) {
      void this.setMoonlightPreferredOrientation(
        window.Orientation.LANDSCAPE, 'MOONLIGHT-LANDSCAPE');
    }
    this.sessionCoordinator.bindScope(scope.ownerScopeId, scope.generation);
    hilog.info(0x0014, 'MoonlightStreamUi', 'aboutToAppear reserving-session');
    // Reserve the new operation generation before subscribing. A cleanly
    // disconnected session for the same host/app remains as typed terminal
    // history until reserve() rotates it. Subscribing first synchronously
    // delivered that old terminal snapshot to the new page, which scheduled a
    // route exit and released the renderer even though reserve() immediately
    // succeeded for the next generation.
    this.reserveMoonlightSession(scope);
    hilog.info(0x0014, 'MoonlightStreamUi',
      'aboutToAppear session-reserved=' + (this.sessionReserved ? '1' : '0'));
    if (this.sessionReserved) {
      this.bindSessionSnapshot(scope);
    }
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
    hilog.info(0x0014, 'MoonlightStreamUi', 'aboutToAppear complete');
  }

  aboutToDisappear(): void {
    const background: boolean = this.currentMoonlightAbilityBackgroundState();
    const sessionActive: boolean = !this.routeTerminated && this.nativeSessionId > 0;
    if (background && sessionActive) {
      this.cancelPendingMoonlightDisappearDecision();
      hilog.info(0x0014, 'MoonlightStreamUi',
        'aboutToDisappear background preserve nativeSessionId=' + this.nativeSessionId.toString());
      this.applyMoonlightAbilityBackground(true);
      return;
    }
    if (shouldDeferMoonlightDisappear(background, sessionActive, this.routeTerminated)) {
      this.deferMoonlightDisappearDecision();
      return;
    }
    this.finalizeMoonlightPageDisappear();
  }

  private finalizeMoonlightPageDisappear(): void {
    this.cancelPendingMoonlightDisappearDecision();
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
    this.clearTerminalRouteExitTimer();
    this.unregisterMoonlightNetworkMonitor();
    this.sheetReopenGeneration += 1;
    this.cancelSheetReopen();
    this.pendingSheetMode = 'none';
    this.showSessionSheet = false;
    this.pendingConnectStageSheet = false;
    this.routeExitAfterSheetDisappear = false;
    this.showModifierPanel = false;
    this.showShortcutPanel = false;
    this.clearMoonlightVirtualKeyboardFocusSchedule();
    this.clearMoonlightPhysicalKeyboardFocusSchedule();
    this.physicalKeyboardProxyFocused = false;
    this.physicalKeyboardLayoutPromptVisible = false;
    this.moonlightRemoteSurfaceHovered = false;
    this.restoreMoonlightSystemPointer('page-disappear');
    void this.setMoonlightSystemBarsHidden(false, 'page-disappear');
    this.closeMoonlightRoute('stream-page-disappear');
    if (!this.isDesktopDevice && this.sessionWindowId.length === 0) {
      void this.setMoonlightPreferredOrientation(
        window.Orientation.UNSPECIFIED, 'MOONLIGHT-UNSPECIFIED');
    }
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

  private async setMoonlightPreferredOrientation(
    orientation: window.Orientation, label: string
  ): Promise<void> {
    const requestGeneration: number = ++this.orientationRequestGeneration;
    try {
      const context = this.getUIContext().getHostContext();
      if (!context) {
        if (requestGeneration === this.orientationRequestGeneration &&
            orientation !== window.Orientation.UNSPECIFIED) {
          this.orientationApplied = true;
          this.syncConnectStageSheet();
        }
        hilog.warn(0x0014, 'MoonlightStreamUi',
          'setPreferredOrientation skipped label=' + label + ' reason=no-context');
        return;
      }
      const win: window.Window = await window.getLastWindow(context);
      await win.setPreferredOrientation(orientation);
      if (requestGeneration !== this.orientationRequestGeneration) { return; }
      this.orientationApplied = orientation !== window.Orientation.UNSPECIFIED;
      this.syncConnectStageSheet();
      if (orientation !== window.Orientation.UNSPECIFIED) {
        void this.setMoonlightSystemBarsHidden(true, 'orientation-' + label);
      }
      hilog.info(0x0014, 'MoonlightStreamUi',
        'setPreferredOrientation label=' + label + ' ok');
    } catch (error) {
      if (requestGeneration === this.orientationRequestGeneration &&
          orientation !== window.Orientation.UNSPECIFIED) {
        // Orientation control is best effort. Do not permanently withhold the
        // surface on a platform/window that declines the preference request.
        this.orientationApplied = true;
        this.syncConnectStageSheet();
      }
      hilog.warn(0x0014, 'MoonlightStreamUi',
        'setPreferredOrientation label=' + label + ' failed=' + JSON.stringify(error));
    }
  }

  /**
   * Phone and Pad Moonlight sessions share the same immersive window contract
   * as RDP, RustDesk and VNC. PC sessions are owned by RemoteSessionAbility's
   * frame controller instead and must not mutate EntryAbility system bars.
   */
  private async setMoonlightSystemBarsHidden(hidden: boolean, reason: string): Promise<void> {
    if (!moonlightUsesEntryAbilityImmersiveBars(
        this.isDesktopDevice, this.sessionWindowId)) { return; }
    const requestId: number = ++this.moonlightSystemBarRequestId;
    const forceApply: boolean = reason === 'foreground-restore' ||
      reason.indexOf('orientation-') === 0;
    const update: Promise<void> = this.moonlightSystemBarUpdate
      .catch((_error: Error): void => {})
      .then(async (): Promise<void> => {
        if (requestId !== this.moonlightSystemBarRequestId ||
            (!forceApply && this.moonlightSystemBarsHidden === hidden)) { return; }
        try {
          const context = this.getUIContext().getHostContext();
          if (!context) { return; }
          const win: window.Window = await window.getLastWindow(context);
          // Keep the ArkUI root behind system insets. Once the bars are hidden
          // the XComponent can use the complete physical display geometry.
          try { await win.setWindowLayoutFullScreen(true); } catch (_layoutError) {}
          let statusApplied: boolean = true;
          let navigationApplied: boolean = true;
          try {
            await win.setSpecificSystemBarEnabled('status', !hidden, false);
          } catch (error) {
            statusApplied = false;
            hilog.warn(0x0014, 'MoonlightStreamUi',
              'system status bar update failed reason=' + reason +
              ' error=' + JSON.stringify(error));
          }
          try {
            await win.setSpecificSystemBarEnabled('navigation', !hidden, false);
          } catch (error) {
            navigationApplied = false;
            hilog.warn(0x0014, 'MoonlightStreamUi',
              'system navigation bar update failed reason=' + reason +
              ' error=' + JSON.stringify(error));
          }
          try {
            await win.setSpecificSystemBarEnabled('navigationIndicator', !hidden, false);
          } catch (_indicatorError) {
            // Some API-23 device families expose only the navigation bar name.
          }
          if (requestId === this.moonlightSystemBarRequestId &&
              statusApplied && navigationApplied) {
            this.moonlightSystemBarsHidden = hidden;
          }
          hilog.info(0x0014, 'MoonlightStreamUi',
            'system bars=' + (hidden ? 'hidden' : 'restored') + ' reason=' + reason);
        } catch (error) {
          hilog.warn(0x0014, 'MoonlightStreamUi',
            'system bar transaction failed reason=' + reason +
            ' error=' + JSON.stringify(error));
        }
      });
    this.moonlightSystemBarUpdate = update;
    await update;
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
      this.resetDiagnosticsSampling();
      this.setSurfaceRecovering(false);
      this.setConnectStageVisible(false);
      this.firstFrameSeen = true;
      this.clampAndPublishTrackpadCursor();
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
    // The first phone surface is often published with the old portrait size.
    // Starting common-c before the landscape onAreaChange then immediately
    // resizing the renderer invalidates the media binding generation. Admit
    // the stream only after the final landscape geometry is observable.
    if (!this.surfaceLayoutReady) { return; }
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
    this.rendererSurfaceWidthPx = this.surfaceWidthPx;
    this.rendererSurfaceHeightPx = this.surfaceHeightPx;
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

  private resizeActiveMoonlightRenderer(width: number, height: number): void {
    if (this.rendererHandle <= 0 ||
        (this.rendererSurfaceWidthPx === width &&
          this.rendererSurfaceHeightPx === height)) {
      return;
    }
    if (this.streamStartAttempted && this.nativeSessionId <= 0) {
      // Never mutate the renderer generation while common-c admission is in
      // flight. The landscape readiness barrier prevents this on first mount;
      // retaining the current binding is safer than creating a stale decoder.
      return;
    }
    if (this.streamStartAttempted && !this.surfaceSuspended) {
      const suspended = this.sessionCoordinator.suspendSurfaceForRoute(
        this.hostId, this.appId);
      if (!suspended.accepted) {
        this.closeMoonlightRoute('surface-resize-suspend-failed');
        return;
      }
      this.surfaceSuspended = true;
      this.setSurfaceRecovering(true);
    }
    try {
      rdpnapi.resizeRenderer(this.rendererHandle, width, height);
      this.rendererSurfaceWidthPx = width;
      this.rendererSurfaceHeightPx = height;
    } catch (_) {
      this.closeMoonlightRoute('surface-resize-failed');
      return;
    }
    if (this.streamStartAttempted) {
      const rebound = this.sessionCoordinator.rebindSurfaceForRoute(
        this.hostId, this.appId, this.rendererHandle, this.surfaceId);
      if (!rebound.accepted) {
        this.closeMoonlightRoute('surface-resize-rebind-failed');
        return;
      }
      this.surfaceSuspended = false;
      this.beginSurfaceFrameRecovery(this.surfaceId);
    }
  }

  private onMoonlightSurfaceAreaChange(newArea: Area): void {
    this.surfaceWidthVp = Math.max(1, newArea.width as number);
    this.surfaceHeightVp = Math.max(1, newArea.height as number);
    this.clampAndPublishTrackpadCursor();
    this.reflowMoonlightModifierPanels();
    const width: number = Math.max(1, Math.round(vp2px(this.surfaceWidthVp)));
    const height: number = Math.max(1, Math.round(vp2px(this.surfaceHeightVp)));
    this.surfaceWidthPx = width;
    this.surfaceHeightPx = height;
    this.geometryGeneration += 1;
    this.invalidatePhysicalPointerGeometry();
    const layoutReady: boolean = width > 1 && height > 1 &&
      (this.isDesktopDevice || this.sessionWindowId.length > 0 ||
        this.surfaceWidthVp > this.surfaceHeightVp);
    const becameReady: boolean = layoutReady && !this.surfaceLayoutReady;
    this.surfaceLayoutReady = layoutReady;
    this.syncConnectStageSheet();
    if (!layoutReady) { return; }
    this.resizeActiveMoonlightRenderer(width, height);
    if (becameReady && !this.streamStartAttempted) {
      if (this.pageSurfaceId.trim() !== '') {
        this.onMoonlightSurface(this.pageSurfaceId);
      } else {
        this.pollMoonlightSurface(0);
      }
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
    hilog.info(0x0014, 'MoonlightStreamUi',
      'reserve result=' + result.code +
      ' generation=' + (result.state === null ? 'none' : result.state.generation.toString()));
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
    if (this.surfaceId !== '' &&
        surfaceId.trim() !== '' && surfaceId !== this.surfaceId) {
      return;
    }
    // This callback is the authoritative ArkUI window-detach boundary. A
    // terminal route must not skip it: closeMoonlightRoute() deliberately
    // releases the renderer asynchronously after PIP teardown, and that work
    // must never treat an already detached page window as live.
    if (this.routeTerminated) {
      this.destroyDetachedMoonlightSurface();
      return;
    }
    if (this.reconnectWindow !== null && this.nativeSessionId <= 0) {
      this.flushInput('surface-destroyed-during-reconnect');
      this.setNativeInputSuspended(true, 'surface_detached');
      this.surfaceRecoveryGeneration += 1;
      this.clearSurfaceRecoveryTimer();
      this.setSurfaceRecovering(true);
      this.surfaceSuspended = true;
      this.destroyDetachedMoonlightSurface();
      if (!this.appInBackground) { this.pollMoonlightSurface(0); }
      return;
    }
    if (!this.streamStartAttempted || this.nativeSessionId <= 0) {
      this.destroyDetachedMoonlightSurface();
      this.closeMoonlightRoute('surface-destroyed-before-stream');
      return;
    }
    this.flushInput('surface-destroyed');
    this.setNativeInputSuspended(true, 'surface_detached');
    const suspended = this.sessionCoordinator.suspendSurfaceForRoute(this.hostId, this.appId);
    if (!suspended.accepted) {
      this.destroyDetachedMoonlightSurface();
      this.closeMoonlightRoute('surface-suspend-failed');
      return;
    }
    this.surfaceRecoveryGeneration += 1;
    this.clearSurfaceRecoveryTimer();
    this.setSurfaceRecovering(true);
    this.surfaceSuspended = true;
    this.destroyDetachedMoonlightSurface();
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
    this.physicalKeyboardLayoutPromptVisible = false;
    this.restoreMoonlightSystemPointer('route-close-' + reason);
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
    this.showModifierPanel = false;
    this.showShortcutPanel = false;
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
    this.pipPrepared = false;
    this.pipPrepareInFlight = false;
    // Keep the presentation ownership flags until the asynchronous PIP
    // teardown completes. They distinguish a late page-XComponent destroy
    // callback from destruction of the process-global PIP surface.
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
    if (action === 'disconnect') {
      this.disconnectMoonlightImmediately('user-disconnect');
      return;
    }
    if (this.terminationBusy) { return; }
    this.terminationBusy = true;
    if (this.routeTerminated) {
      const settled: boolean = await this.sessionCoordinator.stopForLifecycle(
        'terminal-route-exit', 6500);
      this.terminationBusy = false;
      if (settled) {
        const sheetWasVisible: boolean = this.showSessionSheet;
        this.closeSheet();
        this.requestSessionSurfaceClose(sheetWasVisible);
      } else if (this.pageActive) {
        this.setConnectStageVisible(true);
        promptAction.showToast({
          message: '本地串流仍在安全收尾，请稍后再返回', duration: 2400
        });
      }
      return;
    }
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
    let hostQuitConfirmed: boolean = false;
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
      if (!stopped) {
        // Keep the route visible and occupied until the exact native terminal
        // receipt arrives. Leaving now would make the host list actionable
        // while the process-wide media owner is still legitimately draining.
        this.setConnectStageVisible(true);
        this.terminationBusy = false;
        return;
      }
      try {
        const sheetWasVisible: boolean = this.showSessionSheet;
        this.closeMoonlightRoute(action === 'quit' ?
          (hostQuitConfirmed ? 'host-app-quit' : 'host-app-quit-uncertain') :
          'user-disconnect');
        this.closeSheet();
        this.requestSessionSurfaceClose(sheetWasVisible);
      } finally {
        this.terminationBusy = false;
      }
    }
  }

  /**
   * Navigation must respond in the same frame as the toolbar/back gesture.
   * closeMoonlightRoute() requests the typed native terminal transition and
   * keeps the shared protocol registry occupied until its receipt arrives, so
   * the page never needs to remain visible while common-c drains.
   */
  private disconnectMoonlightImmediately(reason: string): void {
    if (this.terminationBusy) { return; }
    this.terminationBusy = true;
    const sheetWasVisible: boolean = this.showSessionSheet;
    try {
      if (!this.routeTerminated) {
        this.requestedTerminalAction = 'disconnect';
        this.recoveryRuntime.requestTerminal('disconnect', Date.now());
        this.sessionCoordinator.setReconnectEnabledForRoute(
          this.hostId, this.appId, false);
        this.closeMoonlightRoute(reason);
      }
      this.closeSheet();
    } finally {
      this.terminationBusy = false;
      this.requestSessionSurfaceClose(sheetWasVisible);
    }
  }

  private destroyMoonlightRenderer(): void {
    const handle: number = this.rendererHandle;
    this.rendererHandle = -1;
    this.rendererSurfaceWidthPx = 0;
    this.rendererSurfaceHeightPx = 0;
    if (handle > 0) {
      try { rdpnapi.destroyRenderer(handle); } catch (_) {}
    }
  }

  private destroyDetachedMoonlightSurface(): void {
    if (this.nativeSurfaceAttached) {
      try { rdpnapi.markXComponentSurfaceDestroyed(); } catch (_) {}
    }
    this.nativeSurfaceAttached = false;
    this.destroyMoonlightRenderer();
    this.surfaceId = '';
  }

  private detachSurfaceAndDestroyMoonlightRenderer(): void {
    // This path releases or transfers a renderer while its ArkUI/FreeNode
    // Surface may still be alive. Do not publish the XComponent-destroyed
    // fence here: GL must be allowed to destroy its EGLSurface/window
    // reference before that same native window can be rebound.
    this.destroyMoonlightRenderer();
    this.nativeSurfaceAttached = false;
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
        this.pipSurfaceId = '';
        this.pipTransferInProgress = false;
        this.renderPreservedInPip = false;
        this.foregroundRestoreInProgress = false;
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
    const background: boolean = this.currentMoonlightAbilityBackgroundState();
    if (background) { this.cancelPendingMoonlightDisappearDecision(); }
    this.applyMoonlightAbilityBackground(background);
  }

  private onSessionWindowBackgroundChange(): void {
    if (this.sessionWindowId.length === 0) { return; }
    const background: boolean = this.currentMoonlightAbilityBackgroundState();
    if (background) { this.cancelPendingMoonlightDisappearDecision(); }
    this.applyMoonlightAbilityBackground(background);
  }

  private currentMoonlightAbilityBackgroundState(): boolean {
    return this.sessionWindowId.length > 0 ? this.sessionWindowBackground :
      (AppStorage.get<boolean>('remoteDesktopBgFlag') ?? this.appBackgroundSignal);
  }

  private cancelPendingMoonlightDisappearDecision(): void {
    if (this.pendingDisappearDecisionTimer >= 0) {
      clearTimeout(this.pendingDisappearDecisionTimer);
      this.pendingDisappearDecisionTimer = -1;
    }
    this.disappearDecisionGeneration += 1;
  }

  private deferMoonlightDisappearDecision(): void {
    this.cancelPendingMoonlightDisappearDecision();
    const generation: number = this.disappearDecisionGeneration;
    this.pendingDisappearDecisionTimer = setTimeout((): void => {
      this.pendingDisappearDecisionTimer = -1;
      if (generation !== this.disappearDecisionGeneration) { return; }
      const background: boolean = this.currentMoonlightAbilityBackgroundState();
      if (background && !this.routeTerminated && this.nativeSessionId > 0) {
        hilog.info(0x0014, 'MoonlightStreamUi',
          'deferred disappear classified as background; preserving nativeSessionId=' +
          this.nativeSessionId.toString());
        this.applyMoonlightAbilityBackground(true);
        return;
      }
      hilog.info(0x0014, 'MoonlightStreamUi',
        'deferred disappear classified as explicit navigation');
      this.finalizeMoonlightPageDisappear();
    }, MOONLIGHT_DISAPPEAR_BACKGROUND_SIGNAL_WAIT_MS);
    hilog.info(0x0014, 'MoonlightStreamUi',
      'page disappear waiting for ability background classification');
  }

  private applyMoonlightAbilityBackground(isBackground: boolean): void {
    const changed: boolean = this.appInBackground !== isBackground;
    this.appInBackground = isBackground;
    if (isBackground) {
      this.restoreMoonlightSystemPointer('ability-background');
    } else {
      this.syncMoonlightSystemPointer('ability-foreground', true);
    }
    if (!isBackground && this.pageActive && !this.routeTerminated) {
      void this.setMoonlightSystemBarsHidden(true, 'foreground-restore');
      this.scheduleMoonlightPhysicalKeyboardFocus('foreground-restore');
    }
    if (!changed || !this.pageActive || this.routeTerminated) { return; }
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
    this.destroyMoonlightRenderer();
    this.nativeSurfaceAttached = false;
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
    this.destroyMoonlightRenderer();
    this.nativeSurfaceAttached = false;

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
    void this.setMoonlightSystemBarsHidden(true, 'foreground-presentation');
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
      const restoreTarget: RemoteSessionPipRestoreTarget | null =
        this.moonlightPipRestoreTarget();
      if (this.sessionWindowId.length === 0 && restoreTarget === null) {
        this.pipPrepared = false;
        hilog.warn(0x0014, 'MoonlightStreamUi',
          'PIP prepare deferred because stream-page restore handle is unavailable');
        return;
      }
      const prepared: boolean = await pipService.prepare(
        context, uiContext, size.width, size.height, presentationLease,
        (reason: string): void => {
          this.handleMoonlightPipStopped(reason, presentationLease);
        },
        (surface: RemoteSessionPipSurface): void => {
          this.handleMoonlightPipSurfaceChanged(surface, presentationLease);
        }, restoreTarget);
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
    if (!this.pipPrepared && this.pipAvailable() &&
        !this.appInBackground && !this.routeTerminated) {
      await this.prepareMoonlightPipForForeground();
    }
    if (!this.pipAvailable() || !this.pipPrepared ||
        this.appInBackground || this.routeTerminated) {
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

    let launchConfiguration: MoonlightNativeLaunchConfiguration;
    const decoderCapabilities = probeMoonlightHardwareDecoderCapabilities();
    const decoderCapability = moonlightDecoderCapability(decoderCapabilities,
      this.effectiveSettings.video.codecPreference);
    try {
      const current: display.Display = display.getDefaultDisplaySync();
      launchConfiguration = moonlightLaunchConfiguration(
        this.effectiveSettings, current.width, current.height,
        decoderCapability.maxWidth, decoderCapability.maxHeight);
    } catch (_error) {
      launchConfiguration = moonlightLaunchConfiguration(this.effectiveSettings, 0, 0,
        decoderCapability.maxWidth, decoderCapability.maxHeight);
    }
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
        this.scheduleMoonlightPhysicalKeyboardFocus('input-ready');
      }
      this.syncMoonlightSystemPointer('input-readiness');
    } catch (_) {
      this.inputReady = false;
      this.controllerReady = false;
      this.physicalControllerPathReady = false;
      this.syncMoonlightSystemPointer('input-readiness-error');
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
    this.clearMoonlightPhysicalKeyboardFocusSchedule();
    this.keyboardOpen = true;
    this.restoreMoonlightSystemPointer('virtual-keyboard-open');
    this.startMoonlightImeSession();
    this.scheduleMoonlightVirtualKeyboardFocus('keyboard-open');
  }

  private dismissMoonlightKeyboard(): void {
    if (!this.keyboardOpen && !this.keyboardImeActive) { return; }
    this.clearMoonlightVirtualKeyboardFocusSchedule();
    this.keyboardOpen = false;
    this.flushInput('close-keyboard');
    this.resetMoonlightImeSession('dismiss');
    this.physicalKeyboardProxyFocused = false;
    this.syncMoonlightSystemPointer('virtual-keyboard-dismissed', true);
    this.scheduleMoonlightPhysicalKeyboardFocus('virtual-keyboard-dismissed');
  }

  private clearMoonlightVirtualKeyboardFocusSchedule(): void {
    if (this.virtualKeyboardFocusTimer < 0) { return; }
    clearTimeout(this.virtualKeyboardFocusTimer);
    this.virtualKeyboardFocusTimer = -1;
  }

  private scheduleMoonlightVirtualKeyboardFocus(reason: string): void {
    this.clearMoonlightVirtualKeyboardFocusSchedule();
    const generation: number = this.keyboardImeGeneration;
    this.virtualKeyboardFocusTimer = setTimeout((): void => {
      this.virtualKeyboardFocusTimer = -1;
      if (!this.pageActive || this.appInBackground || this.routeTerminated ||
          !this.inputReady || !this.keyboardOpen || !this.keyboardImeActive ||
          generation !== this.keyboardImeGeneration) { return; }
      try {
        const focused: boolean = focusControl.requestFocus('MoonlightKeyboardProxy');
        hilog.info(0x0014, 'MoonlightStreamUi',
          'virtual keyboard proxy focus=' + (focused ? '1' : '0') +
          ' reason=' + reason);
      } catch (error) {
        hilog.warn(0x0014, 'MoonlightStreamUi',
          'virtual keyboard proxy focus failed reason=' + reason +
          ' error=' + JSON.stringify(error));
      }
    }, 0);
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
    this.clearMoonlightVirtualKeyboardFocusSchedule();
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
    this.keyboardImeEditingObserved = true;
    this.keyboardExpectedStart = info.insertOffset + info.insertValue.length;
    this.keyboardExpectedEnd = this.keyboardExpectedStart;
    return this.keyboardImeActive;
  }

  private handleMoonlightImeDidInsert(info: InsertValue): void {
    if (!this.keyboardImeActive || info.insertValue.length === 0) { return; }
    this.keyboardSyncedCaret = info.insertOffset + info.insertValue.length;
    this.keyboardCommandQueue.enqueueText(
      info.insertValue, this.keyboardImeGeneration, 'didInsert');
    hilog.debug(0x0014, 'MoonlightStreamUi',
      'ime enqueue kind=text units=' + info.insertValue.length.toString() +
      ' queue=' + this.keyboardCommandQueue.size().toString());
    this.scheduleMoonlightImeCommandPump();
  }

  private handleMoonlightImeWillDelete(info: DeleteValue): boolean {
    this.keyboardImeEditingObserved = true;
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
      accepted = this.sendMoonlightCommittedText(command.text);
      hilog.debug(0x0014, 'MoonlightStreamUi',
        'ime dispatch kind=text units=' + command.text.length.toString() +
        ' accepted=' + accepted.toString() +
        ' queue=' + this.keyboardCommandQueue.size().toString());
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

  private sendMoonlightImeKeyStroke(stroke: MoonlightImeKeyStroke): boolean {
    let accepted: boolean = true;
    if (stroke.shift) {
      accepted = this.sendMoonlightKey(MOONLIGHT_KEYCODE_SHIFT_LEFT, true) && accepted;
    }
    accepted = this.sendMoonlightKey(stroke.keyCode, true) && accepted;
    accepted = this.sendMoonlightKey(stroke.keyCode, false) && accepted;
    if (stroke.shift) {
      // Always attempt the release even if a preceding dispatch failed. The
      // native keyboard mapper then remains neutral for the recovery flush.
      accepted = this.sendMoonlightKey(MOONLIGHT_KEYCODE_SHIFT_LEFT, false) && accepted;
    }
    return accepted;
  }

  private sendMoonlightCommittedText(text: string): boolean {
    let utf8Fallback: string = '';
    let asciiStrokes: number = 0;
    let utf8Units: number = 0;
    for (let index: number = 0; index < text.length; index++) {
      const character: string = text.charAt(index);
      const stroke: MoonlightImeKeyStroke | null =
        moonlightImeAsciiKeyStroke(character);
      if (stroke === null) {
        utf8Fallback += character;
        utf8Units += 1;
        continue;
      }
      if (utf8Fallback.length > 0) {
        if (!this.sendMoonlightText(utf8Fallback)) { return false; }
        utf8Fallback = '';
      }
      if (!this.sendMoonlightImeKeyStroke(stroke)) { return false; }
      asciiStrokes += 1;
    }
    const accepted: boolean = utf8Fallback.length === 0 ||
      this.sendMoonlightText(utf8Fallback);
    hilog.debug(0x0014, 'MoonlightStreamUi',
      'ime route asciiStrokes=' + asciiStrokes.toString() +
      ' utf8Units=' + utf8Units.toString() +
      ' accepted=' + accepted.toString());
    return accepted;
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

  private commitPhysicalPointerGeometry(
    geometry: MoonlightPhysicalPointerGeometry): MoonlightPhysicalPointerGeometry {
    if (this.physicalPointerGeometrySignature !== '' &&
        this.physicalPointerGeometrySignature !== geometry.signature) {
      this.geometryGeneration = Math.min(Number.MAX_SAFE_INTEGER,
        this.geometryGeneration + 1);
    }
    this.physicalPointerGeometrySignature = geometry.signature;
    return geometry;
  }

  private invalidatePhysicalPointerGeometry(): void {
    this.physicalPointerGeometryCache = null;
    this.physicalPointerGeometryHandle = this.rendererHandle;
    this.physicalPointerGeometryReadAtMs = 0;
  }

  private fallbackPhysicalPointerGeometry(): MoonlightPhysicalPointerGeometry {
    const width: number = Math.max(1, this.surfaceWidthVp);
    const height: number = Math.max(1, this.surfaceHeightVp);
    const referenceWidth: number = Math.max(2, Math.min(32767,
      Math.floor(this.streamWidth)));
    const referenceHeight: number = Math.max(2, Math.min(32767,
      Math.floor(this.streamHeight)));
    return this.commitPhysicalPointerGeometry({
      contentLeft: 0,
      contentTop: 0,
      contentWidth: width,
      contentHeight: height,
      referenceWidth: referenceWidth,
      referenceHeight: referenceHeight,
      signature: 'fallback|' + this.rendererHandle.toString() + '|' +
        width.toFixed(3) + '|' + height.toFixed(3) + '|' +
        referenceWidth.toString() + '|' + referenceHeight.toString()
    });
  }

  private readPhysicalPointerGeometry(): MoonlightPhysicalPointerGeometry | null {
    if (this.rendererHandle <= 0) { return null; }
    const now: number = Date.now();
    if (this.physicalPointerGeometryHandle !== this.rendererHandle) {
      this.invalidatePhysicalPointerGeometry();
    }
    if (now - this.physicalPointerGeometryReadAtMs <
        MOONLIGHT_RENDERER_VIEWPORT_CACHE_MS) {
      return this.physicalPointerGeometryCache;
    }
    this.physicalPointerGeometryReadAtMs = now;
    try {
      const raw = rdpnapi.getRendererViewport(this.rendererHandle);
      if (raw === null || !Number.isFinite(raw.sourceWidth) ||
          !Number.isFinite(raw.sourceHeight) || raw.sourceWidth < 2 ||
          raw.sourceWidth > 32767 || raw.sourceHeight < 2 ||
          raw.sourceHeight > 32767) {
        return this.physicalPointerGeometryCache;
      }
      const viewport = normalizeRendererViewportToSurface(
        raw.viewportX, raw.viewportY, raw.viewportW, raw.viewportH,
        raw.surfaceWidth, raw.surfaceHeight,
        Math.max(1, this.surfaceWidthVp), Math.max(1, this.surfaceHeightVp));
      if (viewport === null) { return this.physicalPointerGeometryCache; }
      const referenceWidth: number = Math.floor(raw.sourceWidth);
      const referenceHeight: number = Math.floor(raw.sourceHeight);
      const geometry: MoonlightPhysicalPointerGeometry = {
        contentLeft: viewport.viewportX,
        contentTop: viewport.viewportY,
        contentWidth: viewport.viewportW,
        contentHeight: viewport.viewportH,
        referenceWidth: referenceWidth,
        referenceHeight: referenceHeight,
        signature: 'renderer|' + this.rendererHandle.toString() + '|' +
          viewport.viewportX.toFixed(3) + '|' + viewport.viewportY.toFixed(3) + '|' +
          viewport.viewportW.toFixed(3) + '|' + viewport.viewportH.toFixed(3) + '|' +
          referenceWidth.toString() + '|' + referenceHeight.toString()
      };
      this.physicalPointerGeometryCache = this.commitPhysicalPointerGeometry(geometry);
    } catch (_) {
      // The renderer can be between surfaces during PIP/foreground handoff.
    }
    return this.physicalPointerGeometryCache;
  }

  private absolutePointerRequest(action: 'absolute' | 'absoluteButton',
    x: number, y: number, button?: number, pressed?: boolean): MoonlightPointerInputRequest {
    const geometry: MoonlightPhysicalPointerGeometry =
      this.readPhysicalPointerGeometry() ?? this.fallbackPhysicalPointerGeometry();
    const request: MoonlightPointerInputRequest = {
      launchKey: this.launchKey, action: action, x: x, y: y,
      contentLeft: geometry.contentLeft, contentTop: geometry.contentTop,
      contentWidth: geometry.contentWidth,
      contentHeight: geometry.contentHeight,
      referenceWidth: geometry.referenceWidth,
      referenceHeight: geometry.referenceHeight,
      geometryGeneration: this.geometryGeneration,
      button: button,
      pressed: pressed
    };
    return request;
  }

  private sendAbsolutePointer(x: number, y: number): boolean {
    return this.sendMoonlightPointer(this.absolutePointerRequest('absolute', x, y));
  }

  private sendAbsolutePointerButton(x: number, y: number,
    button: number, pressed: boolean): boolean {
    const request: MoonlightPointerInputRequest = this.absolutePointerRequest(
      'absoluteButton', x, y, button, pressed);
    return this.sendMoonlightPointer(request);
  }

  private recordTrackpadDispatch(accepted: boolean): boolean {
    if (accepted) {
      this.trackpadLocalAcceptedEvents = Math.min(Number.MAX_SAFE_INTEGER,
        this.trackpadLocalAcceptedEvents + 1);
    } else {
      this.trackpadLocalRejectedEvents = Math.min(Number.MAX_SAFE_INTEGER,
        this.trackpadLocalRejectedEvents + 1);
    }
    return accepted;
  }

  private sendRelativePointer(deltaX: number, deltaY: number): boolean {
    if (!Number.isFinite(deltaX) || !Number.isFinite(deltaY)) { return false; }
    return this.recordTrackpadDispatch(this.sendMoonlightPointer({
      launchKey: this.launchKey,
      action: 'relative',
      x: deltaX,
      y: deltaY
    }));
  }

  private clearTrackpadPointerFlushTimer(): void {
    if (this.trackpadPointerFlushTimer >= 0) {
      clearTimeout(this.trackpadPointerFlushTimer);
      this.trackpadPointerFlushTimer = -1;
    }
  }

  private discardPendingTrackpadPointer(): void {
    this.clearTrackpadPointerFlushTimer();
    this.trackpadPendingDeltaX = 0;
    this.trackpadPendingDeltaY = 0;
    this.trackpadLastPointerDispatchMs = 0;
  }

  private flushPendingTrackpadPointer(): boolean {
    this.clearTrackpadPointerFlushTimer();
    const deltaX: number = this.trackpadPendingDeltaX;
    const deltaY: number = this.trackpadPendingDeltaY;
    this.trackpadPendingDeltaX = 0;
    this.trackpadPendingDeltaY = 0;
    if (!Number.isFinite(deltaX) || !Number.isFinite(deltaY)) {
      this.trackpadLastPointerDispatchMs = 0;
      return false;
    }
    if (Math.abs(deltaX) < 0.001 && Math.abs(deltaY) < 0.001) { return true; }
    this.trackpadLastPointerDispatchMs = Date.now();
    return this.sendRelativePointer(deltaX, deltaY);
  }

  private queueTrackpadPointer(deltaX: number, deltaY: number): void {
    if (!Number.isFinite(deltaX) || !Number.isFinite(deltaY)) { return; }
    this.trackpadPendingDeltaX += deltaX;
    this.trackpadPendingDeltaY += deltaY;
    if (this.trackpadPointerFlushTimer >= 0) { return; }
    const elapsedMs: number = this.trackpadLastPointerDispatchMs > 0 ?
      Date.now() - this.trackpadLastPointerDispatchMs : MOONLIGHT_TRACKPAD_WIRE_INTERVAL_MS;
    if (elapsedMs >= MOONLIGHT_TRACKPAD_WIRE_INTERVAL_MS) {
      this.flushPendingTrackpadPointer();
      return;
    }
    const delayMs: number = Math.max(1, MOONLIGHT_TRACKPAD_WIRE_INTERVAL_MS - elapsedMs);
    this.trackpadPointerFlushTimer = setTimeout((): void => {
      this.trackpadPointerFlushTimer = -1;
      if (!this.nativeInputAvailable() || this.inputSuspended || this.routeTerminated) {
        this.trackpadPendingDeltaX = 0;
        this.trackpadPendingDeltaY = 0;
        return;
      }
      this.flushPendingTrackpadPointer();
      // Default real-cursor mode is rendered by Sunshine. The circle mode is
      // the only local overlay that needs a presentation-aligned update.
      if (normalizeRemoteCursorStyle(this.virtualMouseStyle) === 'circle') {
        this.publishTrackpadCursor();
      }
    }, delayMs);
  }

  private sendTrackpadScroll(deltaX: number, deltaY: number): boolean {
    this.flushPendingTrackpadPointer();
    const horizontal: boolean = Math.abs(deltaX) > Math.abs(deltaY);
    const raw: number = horizontal ? deltaX : deltaY;
    if (!Number.isFinite(raw) || Math.abs(raw) < 0.35) { return true; }
    const amount: number = Math.max(-32768, Math.min(32767,
      Math.round(-raw * 4)));
    return this.recordTrackpadDispatch(this.sendMoonlightPointer({
      launchKey: this.launchKey,
      action: 'scroll',
      horizontal: horizontal,
      scrollAmount: amount
    }));
  }

  private sendTrackpadButton(button: number, pressed: boolean): boolean {
    this.flushPendingTrackpadPointer();
    return this.recordTrackpadDispatch(this.sendPointerButton(button, pressed));
  }

  private clickTrackpadButton(button: number): boolean {
    const down: boolean = this.sendTrackpadButton(button, true);
    const up: boolean = this.sendTrackpadButton(button, false);
    return down && up;
  }

  private sendPointerButton(button: number, pressed: boolean): boolean {
    const request: MoonlightPointerInputRequest = {
      launchKey: this.launchKey, action: 'button', button: button, pressed: pressed
    };
    return this.sendMoonlightPointer(request);
  }

  private setNativeInputSuspended(suspended: boolean,
    reason: MoonlightInputLifecycleReason): boolean {
    if (this.inputSuspended === suspended &&
        this.inputSuspensionAppliedOwnerToken === this.launchKey.ownerToken) {
      return true;
    }
    if (!this.inputReady || !this.routeLeaseValid()) {
      this.inputSuspended = suspended;
      this.syncMoonlightSystemPointer('input-suspended-' + reason);
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
      this.syncMoonlightSystemPointer('input-suspended-' + reason);
      return accepted;
    } catch (_) {
      if (suspended) { this.inputSuspended = true; }
      this.syncMoonlightSystemPointer('input-suspended-error-' + reason);
      return false;
    }
  }

  private setNativeTouchMode(_mode: MoonlightResolvedControlMode): boolean {
    if (!this.inputReady || !this.routeLeaseValid()) { return false; }
    try {
      return rdpnapi.moonlightSetTouchMode({
        launchKey: {
          requestId: this.launchKey.requestId,
          generation: this.launchKey.generation,
          ownerToken: this.launchKey.ownerToken
        },
        // Product input modes share the pointer lane. Direct-touch remains a
        // low-level compatibility field only, so it cannot bypass the unified
        // keyboard/mouse and virtual-trackpad behavior.
        direct: false
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
    this.syncMoonlightSystemPointer('virtual-controller-close', true);
  }

  private moonlightTouchPhase(event: TouchEvent): MoonlightTouchPhase {
    if (event.type === TouchType.Down) { return 'down'; }
    if (event.type === TouchType.Up) { return 'up'; }
    if (event.type === TouchType.Cancel) { return 'cancel'; }
    return 'move';
  }

  private trackpadCursorVisible(): boolean {
    return this.resolvedMoonlightControlMode() === 'trackpad' && this.pageActive &&
      !this.routeTerminated && !this.surfaceSuspended &&
      !this.surfaceRecovering && this.firstFrameSeen;
  }

  private clampAndPublishTrackpadCursor(): void {
    const width: number = Math.max(1, this.surfaceWidthVp);
    const height: number = Math.max(1, this.surfaceHeightVp);
    if (!this.trackpadCursorInitialized) {
      this.trackpadCursorX = width / 2;
      this.trackpadCursorY = height / 2;
      this.trackpadCursorInitialized = true;
    }
    this.trackpadCursorX = Math.max(0, Math.min(Math.max(0, width - 26),
      this.trackpadCursorX));
    this.trackpadCursorY = Math.max(0, Math.min(Math.max(0, height - 26),
      this.trackpadCursorY));
    this.publishTrackpadCursor();
  }

  private publishTrackpadCursor(): void {
    const cursor: RemoteCursorOverlayState = this.trackpadCursorOverlayState;
    const visible: boolean = this.trackpadCursorVisible();
    const circleVisible: boolean = visible &&
      normalizeRemoteCursorStyle(this.virtualMouseStyle) === 'circle';
    // In the default real-mouse style, Sunshine's streamed host cursor is the
    // source of truth. Do not invalidate even the isolated ArkUI overlay on
    // every touch sample when there is nothing local to draw.
    if (!circleVisible && cursor.renderMode === 'none' && !cursor.showCircle &&
        !cursor.showArrow) { return; }
    // Sunshine includes the host cursor in Moonlight's video stream. In the
    // default real-mouse mode that streamed cursor is the single source of
    // truth for both appearance and position; a second locally accumulated
    // arrow can never stay aligned with the host OS acceleration and latency.
    // Only the explicitly selected circle style draws a local touch indicator.
    cursor.showCircle = circleVisible;
    cursor.circleX = this.trackpadCursorX;
    cursor.circleY = this.trackpadCursorY;
    cursor.circleOuterSize = 28;
    cursor.circleRingSize = 18;
    cursor.circleDotSize = 3;
    cursor.circleColor = this.trackpadDragActive ? '#FF3B30' : '#00D1FF';
    cursor.circleDrag = this.trackpadDragActive;
    cursor.showArrow = false;
    cursor.arrowInside = false;
    cursor.arrowUsesLocalSymbol = false;
    cursor.arrowPixelMap = null;
    cursor.arrowWidth = 0;
    cursor.arrowHeight = 0;
    cursor.arrowX = 0;
    cursor.arrowY = 0;
    this.trackpadCursorRevision += 1;
    cursor.viewRevision = this.trackpadCursorRevision;
    cursor.renderMode = circleVisible ? 'circle' : 'none';
  }

  private onVirtualMouseStyleChanged(): void {
    this.publishTrackpadCursor();
  }

  private resetTrackpadGesture(releaseDrag: boolean): void {
    if (releaseDrag && this.trackpadDragActive) {
      this.sendTrackpadButton(1, false);
    }
    this.trackpadVisualTouches.clear();
    this.trackpadGestureStartedAtMs = 0;
    this.trackpadGestureMaximumTravel = 0;
    this.trackpadPeakContactCount = 0;
    this.trackpadGestureMoved = false;
    this.trackpadDragActive = false;
    this.trackpadScrollCentroidX = 0;
    this.trackpadScrollCentroidY = 0;
    this.trackpadScrollCentroidValid = false;
    this.trackpadCurveState = resetTouchpadPointerCurveState();
  }

  private trackpadReferenceScale(): number {
    const touchWidth: number = Math.max(1, this.trackpadInputSurfaceWidth());
    const touchHeight: number = Math.max(1, this.surfaceHeightVp);
    const referenceArea: number = MOONLIGHT_TRACKPAD_REFERENCE_WIDTH *
      MOONLIGHT_TRACKPAD_REFERENCE_HEIGHT;
    const touchArea: number = touchWidth * touchHeight;
    return Math.max(0.75, Math.min(2.5, Math.sqrt(referenceArea / touchArea)));
  }

  private trackpadStepIsDiscontinuous(deltaX: number, deltaY: number): boolean {
    const distance: number = Math.hypot(deltaX, deltaY);
    const smallestEdge: number = Math.min(
      Math.max(1, this.trackpadInputSurfaceWidth()),
      Math.max(1, this.surfaceHeightVp));
    const maximum: number = Math.min(MOONLIGHT_TRACKPAD_MAX_LOCAL_STEP_VP,
      Math.max(160, smallestEdge * MOONLIGHT_TRACKPAD_MAX_LOCAL_STEP_RATIO));
    return !Number.isFinite(distance) || distance > maximum;
  }

  private trackpadCentroid(): MoonlightTouchPoint | null {
    if (this.trackpadVisualTouches.size < 2) { return null; }
    let x: number = 0;
    let y: number = 0;
    let count: number = 0;
    this.trackpadVisualTouches.forEach((point: MoonlightTouchPoint): void => {
      x += point.x;
      y += point.y;
      count += 1;
    });
    return count > 0 ? { x: x / count, y: y / count } : null;
  }

  /**
   * Phone/Pad virtual trackpad uses the ordinary Moonlight pointer lane.
   * This matches RDP/VNC's proven input route and avoids coupling cursor motion
   * to Sunshine's optional direct-touch negotiation. Direct touch continues
   * to use moonlightSendTouch in `handleMoonlightTouch` below.
   */
  private handleMoonlightTrackpad(event: TouchEvent,
    phase: MoonlightTouchPhase): void {
    const points = event.changedTouches.length > 0 ? event.changedTouches : event.touches;
    if (phase === 'cancel') {
      this.discardPendingTrackpadPointer();
      this.resetTrackpadGesture(true);
      this.clampAndPublishTrackpadCursor();
      return;
    }

    if (phase === 'down') {
      if (this.trackpadVisualTouches.size === 0) {
        this.resetTrackpadGesture(false);
        this.trackpadGestureStartedAtMs = Date.now();
      }
      for (let index: number = 0; index < points.length; index++) {
        const id: number = Math.max(1, Math.floor(points[index].id) + 1);
        this.trackpadVisualTouches.set(id,
          { x: points[index].x, y: points[index].y });
      }
      this.trackpadPeakContactCount = Math.max(
        this.trackpadPeakContactCount, this.trackpadVisualTouches.size);
      const centroid: MoonlightTouchPoint | null = this.trackpadCentroid();
      if (centroid !== null) {
        this.trackpadScrollCentroidX = centroid.x;
        this.trackpadScrollCentroidY = centroid.y;
        this.trackpadScrollCentroidValid = true;
      }
      this.clampAndPublishTrackpadCursor();
      return;
    }

    if (phase === 'move') {
      let relativeX: number = 0;
      let relativeY: number = 0;
      const previouslySingle: boolean = this.trackpadVisualTouches.size <= 1;
      for (let index: number = 0; index < points.length; index++) {
        const id: number = Math.max(1, Math.floor(points[index].id) + 1);
        const next: MoonlightTouchPoint = { x: points[index].x, y: points[index].y };
        const previous: MoonlightTouchPoint | undefined = this.trackpadVisualTouches.get(id);
        if (previous !== undefined) {
          const dx: number = next.x - previous.x;
          const dy: number = next.y - previous.y;
          this.trackpadGestureMaximumTravel += Math.hypot(dx, dy);
          if (previouslySingle) {
            relativeX += dx;
            relativeY += dy;
          }
        }
        this.trackpadVisualTouches.set(id, next);
      }
      this.trackpadPeakContactCount = Math.max(
        this.trackpadPeakContactCount, this.trackpadVisualTouches.size);
      if (this.trackpadVisualTouches.size <= 1 && this.trackpadPeakContactCount <= 1) {
        const distance: number = Math.hypot(relativeX, relativeY);
        if (!this.trackpadDragActive &&
            Date.now() - this.trackpadGestureStartedAtMs >= 480 &&
            this.trackpadGestureMaximumTravel <= 12) {
          this.trackpadDragActive = this.sendTrackpadButton(1, true);
        }
        if (distance >= 0.1) {
          this.trackpadGestureMoved = this.trackpadGestureMoved ||
            this.trackpadGestureMaximumTravel > 6;
          if (this.trackpadStepIsDiscontinuous(relativeX, relativeY)) {
            // A surface reparent/orientation change can switch the local
            // coordinate origin between two events. Re-anchor this event so a
            // PIP or foreground transition cannot teleport the host pointer.
            this.trackpadCurveState = resetTouchpadPointerCurveState();
            this.clampAndPublishTrackpadCursor();
            return;
          }
          // Reuse the same bounded, immediate velocity curve as the RDP/VNC/
          // RustDesk virtual trackpad. Moonlight remains relative on the wire;
          // the UI lane coalesces deltas to presentation cadence and the
          // native mapper preserves fractional remainder until an integral
          // host movement is available.
          const curve = touchpadPointerCurve(
            relativeX, relativeY, Date.now(), this.trackpadCurveState);
          this.trackpadCurveState = curve.state;
          const gain: number = this.trackpadReferenceScale() *
            clampTouchpadEffectiveGain(curve.gain, 1);
          const adjustedX: number = relativeX * gain;
          const adjustedY: number = relativeY * gain;
          this.trackpadCursorX += adjustedX;
          this.trackpadCursorY += adjustedY;
          this.queueTrackpadPointer(adjustedX, adjustedY);
        }
        this.trackpadScrollCentroidValid = false;
      } else {
        const centroid: MoonlightTouchPoint | null = this.trackpadCentroid();
        if (centroid !== null && this.trackpadScrollCentroidValid) {
          const dx: number = centroid.x - this.trackpadScrollCentroidX;
          const dy: number = centroid.y - this.trackpadScrollCentroidY;
          if (Math.hypot(dx, dy) >= 0.35) {
            this.trackpadGestureMoved = this.trackpadGestureMoved ||
              this.trackpadGestureMaximumTravel > 6;
            this.sendTrackpadScroll(dx, dy);
          }
        }
        if (centroid !== null) {
          this.trackpadScrollCentroidX = centroid.x;
          this.trackpadScrollCentroidY = centroid.y;
          this.trackpadScrollCentroidValid = true;
        }
      }
      this.clampAndPublishTrackpadCursor();
      return;
    }

    if (points.length === 0) {
      this.flushPendingTrackpadPointer();
      this.resetTrackpadGesture(true);
      this.clampAndPublishTrackpadCursor();
      return;
    }
    for (let index: number = 0; index < points.length; index++) {
      const id: number = Math.max(1, Math.floor(points[index].id) + 1);
      this.trackpadVisualTouches.delete(id);
    }
    if (this.trackpadVisualTouches.size > 0) {
      const centroid: MoonlightTouchPoint | null = this.trackpadCentroid();
      if (centroid !== null) {
        this.trackpadScrollCentroidX = centroid.x;
        this.trackpadScrollCentroidY = centroid.y;
        this.trackpadScrollCentroidValid = true;
      }
      this.clampAndPublishTrackpadCursor();
      return;
    }
    const durationMs: number = this.trackpadGestureStartedAtMs > 0 ?
      Date.now() - this.trackpadGestureStartedAtMs : Number.MAX_SAFE_INTEGER;
    const tap: boolean = !this.trackpadGestureMoved &&
      this.trackpadGestureMaximumTravel <= 12 && durationMs <= 380;
    this.flushPendingTrackpadPointer();
    if (this.trackpadDragActive) {
      this.sendTrackpadButton(1, false);
    } else if (tap && this.trackpadPeakContactCount === 1) {
      this.clickTrackpadButton(1);
    } else if (tap && this.trackpadPeakContactCount === 2) {
      this.clickTrackpadButton(3);
    }
    this.resetTrackpadGesture(false);
    this.clampAndPublishTrackpadCursor();
  }

  private handleMoonlightTouch = (event: TouchEvent): void => {
    event.stopPropagation();
    this.observeMoonlightAdaptiveInput('touch');
    const phase: MoonlightTouchPhase = this.moonlightTouchPhase(event);
    if (this.resolvedMoonlightControlMode() === 'trackpad') {
      this.handleMoonlightTrackpad(event, phase);
    }
  }

  private handleMoonlightSurfaceTouch = (event: TouchEvent): void => {
    if (this.controlMode === 'keyboardMouse') { return; }
    this.observeMoonlightAdaptiveInput('touch');
    if (this.resolvedMoonlightControlMode() === 'trackpad') {
      this.handleMoonlightTouch(event);
    }
  }

  private cancelActiveMoonlightTouches(): void {
    this.discardPendingTrackpadPointer();
    this.resetTrackpadGesture(true);
    this.publishTrackpadCursor();
  }

  private moonlightPhysicalKeyboardCaptureEnabled(): boolean {
    // Pad and PC are explicit physical keyboard/mouse product modes. Preserve
    // the opt-in switch for a phone with an occasionally attached keyboard,
    // but do not leave the primary Pad/PC input path disabled by the old phone
    // default stored in a compatible settings record.
    return moonlightPhysicalKeyboardCaptureEnabled(
      this.effectiveSettings.input.captureKeyboard, this.isPadDevice,
      this.isDesktopDevice, this.sessionWindowId, this.controlMode);
  }

  private moonlightModifierKeyPressed(event: KeyEvent, key: string): boolean {
    try {
      return event.getModifierKeyState !== undefined &&
        event.getModifierKeyState([key]);
    } catch (_) { return false; }
  }

  private moonlightShouldReserveSystemKey(event: KeyEvent): boolean {
    return moonlightSystemKeyReserved(event.keyCode,
      this.moonlightModifierKeyPressed(event, 'Alt'),
      this.moonlightModifierKeyPressed(event, 'Ctrl'), event.metaKey === 1,
      this.effectiveSettings.input.forwardSystemShortcuts);
  }

  private clearMoonlightPhysicalKeyboardFocusSchedule(): void {
    if (this.physicalKeyboardFocusTimer < 0) { return; }
    clearTimeout(this.physicalKeyboardFocusTimer);
    this.physicalKeyboardFocusTimer = -1;
  }

  private scheduleMoonlightPhysicalKeyboardFocus(reason: string): void {
    if (this.physicalKeyboardFocusTimer >= 0 || this.physicalKeyboardProxyFocused ||
        !this.pageActive || this.appInBackground || this.routeTerminated ||
        !this.inputReady || this.inputSuspended || this.keyboardOpen ||
        this.showSessionSheet || !this.moonlightPhysicalKeyboardCaptureEnabled()) { return; }
    this.physicalKeyboardFocusTimer = setTimeout((): void => {
      this.physicalKeyboardFocusTimer = -1;
      if (!this.pageActive || this.appInBackground || this.routeTerminated ||
          !this.inputReady || this.inputSuspended || this.keyboardOpen ||
          this.showSessionSheet || !this.moonlightPhysicalKeyboardCaptureEnabled()) { return; }
      try {
        const focused: boolean = focusControl.requestFocus('MoonlightKeyboardProxy');
        hilog.info(0x0014, 'MoonlightStreamUi',
          'physical keyboard proxy focus=' + (focused ? '1' : '0') +
          ' reason=' + reason);
      } catch (error) {
        hilog.warn(0x0014, 'MoonlightStreamUi',
          'physical keyboard proxy focus failed reason=' + reason +
          ' error=' + JSON.stringify(error));
      }
    }, 40);
  }

  private shouldRequirePhysicalKeyboardLayout(): boolean {
    return !this.physicalKeyboardLayoutConfirmed &&
      this.resolvedMoonlightControlMode() === 'keyboardMouse' &&
      shouldChoosePhysicalKeyboardLayout('moonlight', this.isDesktopDevice, this.breakpoint);
  }

  private promptPhysicalKeyboardLayout(
    onSelected?: (layout: RemoteKeyboardLayout) => void
  ): void {
    if (this.physicalKeyboardLayoutPromptVisible || !this.pageActive ||
        this.routeTerminated) { return; }
    this.physicalKeyboardLayoutPromptVisible = true;
    this.clearMoonlightPhysicalKeyboardFocusSchedule();
    this.physicalKeyboardProxyFocused = false;
    this.flushInput('keyboard-layout-prompt');
    this.restoreMoonlightSystemPointer('keyboard-layout-prompt');
    promptAction.showDialog({
      title: '选择远端键盘类型',
      message: '此选择用于当前 Moonlight 连接。\n\nWindows：' +
        remoteKeyboardLayoutDescription(RemoteKeyboardLayout.WINDOWS) + '\n\nmacOS：' +
        remoteKeyboardLayoutDescription(RemoteKeyboardLayout.MACOS),
      isModal: true,
      buttons: [
        { text: 'Windows', color: this.accentColor },
        { text: 'macOS', color: this.accentColor }
      ]
    }).then((result: Object): void => {
      this.physicalKeyboardLayoutPromptVisible = false;
      if (!this.pageActive || this.routeTerminated) {
        this.restoreMoonlightSystemPointer('keyboard-layout-stale');
        return;
      }
      const response: Record<string, number> = result as Record<string, number>;
      const layout: RemoteKeyboardLayout = response['index'] === 1 ?
        RemoteKeyboardLayout.MACOS : RemoteKeyboardLayout.WINDOWS;
      this.physicalKeyboardLayout = layout;
      this.physicalKeyboardLayoutConfirmed = true;
      if (onSelected !== undefined) { onSelected(layout); }
      hilog.info(0x0014, 'MoonlightStreamUi',
        'physical keyboard layout selected=' + layout);
      this.syncMoonlightSystemPointer('keyboard-layout-selected', true);
      this.scheduleMoonlightPhysicalKeyboardFocus('keyboard-layout-selected');
    }).catch((error: Error): void => {
      this.physicalKeyboardLayoutPromptVisible = false;
      this.syncMoonlightSystemPointer('keyboard-layout-dismissed', true);
      this.scheduleMoonlightPhysicalKeyboardFocus('keyboard-layout-dismissed');
      hilog.warn(0x0014, 'MoonlightStreamUi',
        'physical keyboard layout dismissed error=' + JSON.stringify(error));
    });
  }

  private mapMoonlightPhysicalKeyCode(keyCode: number): number {
    return mapPhysicalKeyForRemoteLayout(this.physicalKeyboardLayout, keyCode);
  }

  private handleMoonlightPhysicalKeyPreIme = (event: KeyEvent): boolean => {
    if (this.keyboardOpen || !this.moonlightPhysicalKeyboardCaptureEnabled()) { return false; }
    if (this.moonlightShouldReserveSystemKey(event)) {
      return false;
    }
    this.observeMoonlightAdaptiveInput('keyboard');
    const accepted: boolean = this.handleMoonlightKey(event);
    hilog.debug(0x0014, 'MoonlightStreamUi',
      'physical key type=' + event.type.toString() +
      ' code=' + event.keyCode.toString() +
      ' accepted=' + accepted.toString());
    // The physical proxy exists specifically to keep the system IME from
    // consuming ordinary hardware keys before Moonlight sees key-down/up.
    return accepted;
  };

  private handleMoonlightKey = (event: KeyEvent): boolean => {
    if (this.sessionWindowId.length > 0 && event.keyCode === KeyCode.KEYCODE_F11) {
      try { event.stopPropagation(); } catch (_err) {}
      if (event.type === KeyType.Down) { this.toggleIndependentWindowFullscreen(); }
      return true;
    }
    if (this.moonlightShouldReserveSystemKey(event)) {
      return false;
    }
    this.observeMoonlightAdaptiveInput('keyboard');
    if (!this.nativeInputAvailable() || !this.moonlightPhysicalKeyboardCaptureEnabled()) {
      return false;
    }
    if (this.shouldRequirePhysicalKeyboardLayout()) {
      try { event.stopPropagation(); } catch (_error) {}
      this.promptPhysicalKeyboardLayout();
      return true;
    }
    const pressed: boolean = event.type === KeyType.Down;
    if (!pressed && event.type !== KeyType.Up) { return false; }
    event.stopPropagation();
    const remoteKeyCode: number = this.mapMoonlightPhysicalKeyCode(event.keyCode);
    const accepted: boolean = this.sendMoonlightKey(remoteKeyCode, pressed);
    hilog.debug(0x0014, 'MoonlightStreamUi',
      'physical key mapped local=' + event.keyCode.toString() +
      ' remote=' + remoteKeyCode.toString() +
      ' layout=' + this.physicalKeyboardLayout +
      ' down=' + (pressed ? '1' : '0') +
      ' accepted=' + (accepted ? '1' : '0'));
    return accepted;
  }

  private moonlightPointerButton(raw: number): number {
    if (raw === MouseButton.Left || raw === 1) { return 1; }
    if (raw === MouseButton.Middle || raw === 4) { return 2; }
    if (raw === MouseButton.Right || raw === 2) { return 3; }
    return 0;
  }

  private handleMoonlightMouse = (event: MouseEvent): void => {
    // Match the proven RDP/VNC path: an event delivered through ArkUI's
    // onMouse boundary is forwardable even when a vendor HID reports an
    // unknown sourceTool. The old allow-list silently discarded both Pad mice
    // observed on the real device before coordinates reached native input.
    this.moonlightRemoteSurfaceHovered = true;
    this.observeMoonlightAdaptiveInput(
      event.sourceTool === SourceTool.TOUCHPAD ? 'touchpad' : 'mouse');
    this.syncMoonlightSystemPointer('physical-mouse-event');
    event.stopPropagation();
    this.physicalMouseObservedEvents = Math.min(Number.MAX_SAFE_INTEGER,
      this.physicalMouseObservedEvents + 1);
    const eventIndex: number = this.physicalMouseObservedEvents;
    const inputAvailable: boolean = this.nativeInputAvailable();
    if (!inputAvailable) {
      if (eventIndex <= 12 || eventIndex % 120 === 0) {
        hilog.warn(0x0014, 'MoonlightStreamUi',
          'physical mouse blocked event=' + eventIndex.toString() +
          ' action=' + (event.action as number).toString() +
          ' sourceTool=' + event.sourceTool.toString() +
          ' inputReady=' + (this.inputReady ? '1' : '0') +
          ' lease=' + (this.routeLeaseValid() ? '1' : '0') +
          ' suspended=' + (this.inputSuspended ? '1' : '0'));
      }
      return;
    }
    let accepted: boolean = false;
    if (event.action === MouseAction.Move || event.action === MouseAction.Hover) {
      accepted = this.sendAbsolutePointer(event.x as number, event.y as number);
      if (eventIndex <= 12 || eventIndex % 120 === 0) {
        hilog.info(0x0014, 'MoonlightStreamUi',
          'physical mouse event=' + eventIndex.toString() +
          ' action=' + (event.action as number).toString() +
          ' sourceTool=' + event.sourceTool.toString() +
          ' local=' + (event.x as number).toString() + ',' +
            (event.y as number).toString() +
          ' accepted=' + (accepted ? '1' : '0'));
      }
      return;
    }
    if (event.action === MouseAction.Press || event.action === MouseAction.Release) {
      const button: number = this.moonlightPointerButton(event.button as number);
      if (button <= 0) { return; }
      accepted = this.sendAbsolutePointerButton(event.x as number, event.y as number,
        button, event.action === MouseAction.Press);
      hilog.info(0x0014, 'MoonlightStreamUi',
        'physical mouse button event=' + eventIndex.toString() +
        ' action=' + (event.action as number).toString() +
        ' raw=' + (event.button as number).toString() +
        ' mapped=' + button.toString() +
        ' sourceTool=' + event.sourceTool.toString() +
        ' accepted=' + (accepted ? '1' : '0'));
      if (event.action === MouseAction.Release) {
        this.physicalKeyboardProxyFocused = false;
        this.scheduleMoonlightPhysicalKeyboardFocus('physical-mouse-release');
      }
    }
  }

  private handleMoonlightAxis = (event?: AxisEvent): void => {
    if (!event || !this.nativeInputAvailable()) { return; }
    if (event.sourceTool === SourceTool.MOUSE || event.sourceTool === SourceTool.TOUCHPAD) {
      this.moonlightRemoteSurfaceHovered = true;
      this.observeMoonlightAdaptiveInput(
        event.sourceTool === SourceTool.TOUCHPAD ? 'touchpad' : 'mouse');
      this.syncMoonlightSystemPointer('physical-axis-event');
    }
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
      // subscribeForRoute emits one synchronous null snapshot while the
      // reserved route is still being materialized. This is an initialization
      // barrier, not a terminal receipt. Keep the authentication/connection
      // gate visible and wait for the typed coordinator snapshot.
      if (this.routeTerminated) { return; }
      this.phase = 'negotiating';
      this.errorCode = 'none';
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
      this.clearElapsedTimer();
      this.setConnectStageVisible(true);
      this.clearMoonlightPhysicalKeyboardFocusSchedule();
      this.physicalKeyboardProxyFocused = false;
      this.publishTrackpadCursor();
      return;
    }
    if (snapshot.generation !== this.sessionGeneration) {
      this.sessionGeneration = snapshot.generation;
      this.sessionStartedAtMs = Date.now();
      this.elapsedMs = 0;
    }
    const terminal: boolean = snapshot.phase === 'failed' ||
      snapshot.phase === 'disconnected';
    // Dismiss first, then publish the terminal state. ArkUI state updates are
    // observable between assignments on some devices, which was enough to
    // render the former failure controls for a single frame on exit.
    if (terminal) { this.setConnectStageVisible(false); }
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
          this.setNativeTouchMode(this.resolvedMoonlightControlMode())) {
        this.appliedTouchModeSessionGeneration = this.sessionGeneration;
      }
    }
    else {
      this.inputReady = false;
      this.controllerReady = false;
      this.physicalControllerPathReady = false;
      this.clearMoonlightPhysicalKeyboardFocusSchedule();
      this.physicalKeyboardProxyFocused = false;
    }
    if (terminal) {
      hilog.warn(0x0014, 'MoonlightStreamUi',
        'terminal snapshot phase=' + snapshot.phase +
        ' code=' + (snapshot.errorCode || 'none') +
        ' generation=' + snapshot.generation.toString() +
        ' elapsedMs=' + this.elapsedMs.toString());
    }
    // The waiting/authentication Sheet exists only while a connection is in
    // progress. A terminal snapshot returns directly to the catalog; mounting
    // the same Sheet in its failure state caused the visible failure flash on
    // user exit, system Back and PIP restoration.
    if (!terminal) { this.setConnectStageVisible(!snapshot.firstFrameSeen); }
    if (terminal && !this.routeTerminated) {
      this.scheduleTerminalRouteExit(snapshot.errorCode, snapshot.firstFrameSeen);
    }
    if (terminal) {
      this.restoreMoonlightSystemPointer('terminal-snapshot');
    } else {
      this.syncMoonlightSystemPointer('session-snapshot');
    }
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
    // Keep the inexpensive local snapshot sampler alive for the full session.
    // Opening the HUD must reveal a current sample immediately instead of
    // racing the first visibility-triggered timer.
    if (this.diagnosticsSessionActive()) {
      this.startDiagnosticsPolling();
    } else if (snapshot.phase === 'failed' || snapshot.phase === 'disconnected') {
      this.stopDiagnosticsPolling();
    }
    this.publishTrackpadCursor();
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

  private clearTerminalRouteExitTimer(): void {
    if (this.terminalRouteExitTimer >= 0) {
      clearTimeout(this.terminalRouteExitTimer);
      this.terminalRouteExitTimer = -1;
    }
  }

  private scheduleTerminalRouteExit(errorCode: MoonlightSessionErrorCode,
    hadFirstFrame: boolean): void {
    if (this.terminalRouteExitTimer >= 0 || this.routeTerminated || !this.pageActive) { return; }
    promptAction.showToast({
      message: hadFirstFrame ? 'Moonlight 连接已结束，正在返回应用目录' :
        'Moonlight 连接失败（' + errorCode + '），已返回应用目录',
      duration: 1800
    });
    this.terminalRouteExitTimer = setTimeout((): void => {
      this.terminalRouteExitTimer = -1;
      if (!this.pageActive || this.routeTerminated) { return; }
      this.disconnectMoonlightImmediately(hadFirstFrame ?
        'remote-session-terminal' : 'initial-connection-terminal');
    }, 0);
  }

  private resetDiagnosticsSampling(): void {
    this.diagnosticsPreviousSampleMs = 0;
    this.diagnosticsPreviousPresentedFrames = 0;
    this.diagnosticsPreviousVideoBytes = 0;
    this.diagnosticsLastPresentedProgressSampleMs = 0;
    this.diagnosticsLastIngressProgressSampleMs = 0;
    this.diagnosticsSmoothedFps = -1;
    this.diagnosticsSmoothedBitrateKbps = -1;
  }

  private smoothDiagnosticsRate(previous: number, current: number,
    decimalPlaces: number): number {
    if (!Number.isFinite(current) || current < 0) { return -1; }
    const blended: number = previous < 0 ? current :
      previous * (1 - MOONLIGHT_DIAGNOSTICS_NEW_SAMPLE_WEIGHT) +
        current * MOONLIGHT_DIAGNOSTICS_NEW_SAMPLE_WEIGHT;
    const scale: number = Math.pow(10, decimalPlaces);
    return Math.round(blended * scale) / scale;
  }

  private diagnosticsSessionActive(): boolean {
    return this.pageActive && !this.routeTerminated && this.routeLeaseValid() &&
      this.phase !== 'failed' && this.phase !== 'disconnected' &&
      this.phase !== 'stopping';
  }

  private startDiagnosticsPolling(): void {
    if (!this.diagnosticsSessionActive() || this.diagnosticsTimer >= 0) { return; }
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
    if (!this.diagnosticsSessionActive() || this.diagnosticsTimer >= 0) { return; }
    this.diagnosticsTimer = setTimeout((): void => {
      this.diagnosticsTimer = -1;
      this.refreshDiagnosticsSnapshot();
    }, MOONLIGHT_DIAGNOSTICS_POLL_MS);
  }

  private publishDiagnosticsSnapshot(
    snapshot: MoonlightDiagnosticsSnapshot): void {
    this.diagnosticsLatestSnapshot = snapshot;
    if (!this.diagnosticsVisible) { return; }
    this.diagnosticsSnapshot = snapshot;
    this.diagnosticsSampleEpoch = Math.min(Number.MAX_SAFE_INTEGER,
      this.diagnosticsSampleEpoch + 1);
  }

  private refreshDiagnosticsSnapshot(): void {
    if (!this.diagnosticsSessionActive()) { return; }
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
      const hadPreviousSample: boolean = this.diagnosticsPreviousSampleMs > 0;
      const presentationAdvanced: boolean = hadPreviousSample &&
        presentedFrames > this.diagnosticsPreviousPresentedFrames;
      const ingressAdvanced: boolean = hadPreviousSample &&
        videoBytes > this.diagnosticsPreviousVideoBytes;
      if (this.diagnosticsLastPresentedProgressSampleMs <= 0 || presentationAdvanced) {
        this.diagnosticsLastPresentedProgressSampleMs = sampledAtMs;
      }
      if (this.diagnosticsLastIngressProgressSampleMs <= 0 || ingressAdvanced) {
        this.diagnosticsLastIngressProgressSampleMs = sampledAtMs;
      }
      if (hadPreviousSample && elapsedMs > 0 &&
          presentedFrames >= this.diagnosticsPreviousPresentedFrames &&
          videoBytes >= this.diagnosticsPreviousVideoBytes) {
        const sampledFps: number = (presentedFrames - this.diagnosticsPreviousPresentedFrames) *
          1000 / elapsedMs;
        const sampledBitrateKbps: number = (videoBytes - this.diagnosticsPreviousVideoBytes) *
          8 / elapsedMs;
        this.diagnosticsSmoothedFps = this.smoothDiagnosticsRate(
          this.diagnosticsSmoothedFps, sampledFps, 1);
        this.diagnosticsSmoothedBitrateKbps = this.smoothDiagnosticsRate(
          this.diagnosticsSmoothedBitrateKbps, sampledBitrateKbps, 0);
        fps = this.diagnosticsSmoothedFps;
        bitrateKbps = this.diagnosticsSmoothedBitrateKbps;
      }
      const ingressRecentlyActive: boolean = hadPreviousSample &&
        this.diagnosticsLastIngressProgressSampleMs > 0 &&
        sampledAtMs - this.diagnosticsLastIngressProgressSampleMs <= 1500;
      const presentationStalled: boolean = ingressRecentlyActive &&
        presentedFrames === this.diagnosticsPreviousPresentedFrames &&
        sampledAtMs - this.diagnosticsLastPresentedProgressSampleMs >=
          MOONLIGHT_PRESENTATION_STALL_MS;
      const acceptedVideoFrames: number = source.acceptedVideoFrames ?? 0;
      const droppedVideoFrames: number = source.droppedVideoFrames ?? 0;
      const videoFrameTotal: number = acceptedVideoFrames + droppedVideoFrames;
      const packetLossPercent: number = videoFrameTotal > 0 ?
        Math.round(droppedVideoFrames * 10000 / videoFrameTotal) / 100 : -1;
      const presentationAgeMs: number = this.diagnosticsLastPresentedProgressSampleMs > 0 ?
        Math.max(0, sampledAtMs - this.diagnosticsLastPresentedProgressSampleMs) : -1;
      const ingressAgeMs: number = this.diagnosticsLastIngressProgressSampleMs > 0 ?
        Math.max(0, sampledAtMs - this.diagnosticsLastIngressProgressSampleMs) : -1;
      const nextSnapshot: MoonlightDiagnosticsSnapshot = {
        available: source.matched && !source.terminal,
        transportReady: source.transportReady,
        videoReady: source.videoReady,
        audioReady: source.audioReady,
        inputReady: source.inputReady,
        fps: fps,
        latencyMs: source.decoderCodecLatencyMs ?? -1,
        bitrateKbps: bitrateKbps,
        configuredBitrateKbps: source.configuredBitrateKbps ?? this.configuredBitrateKbps,
        packetLossPercent: packetLossPercent,
        codec: source.matched ? this.diagnosticsCodecLabel(source.codec) : '',
        width: source.streamWidth ?? this.streamWidth,
        height: source.streamHeight ?? this.streamHeight,
        targetFps: source.targetFps ?? -1,
        acceptedVideoFrames: acceptedVideoFrames,
        droppedVideoFrames: droppedVideoFrames,
        decoderQueueDepth: source.decoderQueueDepth ?? -1,
        decodeP50Us: -1,
        decodeP95Us: -1,
        renderP50Us: -1,
        renderP95Us: -1,
        codecLatencyMs: source.decoderCodecLatencyMs ?? -1,
        codecLatencyMaxMs: source.decoderCodecLatencyMaxMs ?? -1,
        surfaceUpdateFailures: source.decoderSurfaceUpdateFailures ?? 0,
        surfaceCoalescedNotifications:
          source.decoderSurfaceCoalescedNotifications ?? 0,
        acceptedAudioPackets: source.acceptedAudioPackets ?? 0,
        rejectedAudioPackets: source.rejectedAudioPackets ?? 0,
        audioBytes: source.acceptedAudioBytes ?? 0,
        audioUnderruns: -1,
        inputAccepted: source.acceptedInputEvents ?? this.trackpadLocalAcceptedEvents,
        inputDrops: source.rejectedInputEvents ?? this.trackpadLocalRejectedEvents,
        presentedFrames: presentedFrames,
        videoBytes: videoBytes,
        ingressAgeMs: ingressAgeMs,
        presentationAgeMs: presentationAgeMs,
        stalled: presentationStalled
      };
      this.publishDiagnosticsSnapshot(nextSnapshot);
      this.diagnosticsPreviousSampleMs = sampledAtMs;
      this.diagnosticsPreviousPresentedFrames = presentedFrames;
      this.diagnosticsPreviousVideoBytes = videoBytes;
    } catch (_) {
      this.publishDiagnosticsSnapshot(EMPTY_MOONLIGHT_DIAGNOSTICS);
      this.resetDiagnosticsSampling();
    }
    this.scheduleDiagnosticsPoll();
  }

  private diagnosticsCodecLabel(codec: string | undefined): string {
    if (codec === 'hevc') { return 'H.265 / HEVC · 8-bit 4:2:0'; }
    if (codec === 'av1') { return 'AV1 · 8-bit 4:2:0'; }
    if (codec === 'h264') { return 'H.264 · 8-bit 4:2:0'; }
    return '未知';
  }

  private toggleDiagnosticsHud(): void {
    const opening: boolean = !this.diagnosticsVisible;
    this.diagnosticsVisible = opening;
    this.diagnosticsExpanded = opening;
    if (opening) {
      this.publishDiagnosticsSnapshot(this.diagnosticsLatestSnapshot);
      this.startDiagnosticsPolling();
    }
  }

  private copySanitizedDiagnostics(): void {
    const snapshot: MoonlightDiagnosticsSnapshot = this.diagnosticsSnapshot;
    const text: string = 'Moonlight diagnostics\n' +
      'available=' + snapshot.available.toString() + '\n' +
      'codec=' + (snapshot.codec || 'unavailable') + '\n' +
      'size=' + snapshot.width.toString() + 'x' + snapshot.height.toString() + '\n' +
      'fps=' + snapshot.fps.toString() + '\n' +
      'bitrateKbps=' + snapshot.bitrateKbps.toString() + '\n' +
      'targetBitrateKbps=' + snapshot.configuredBitrateKbps.toString() + '\n' +
      'acceptedVideoFrames=' + snapshot.acceptedVideoFrames.toString() + '\n' +
      'droppedVideoFrames=' + snapshot.droppedVideoFrames.toString() + '\n' +
      'decoderQueueDepth=' + snapshot.decoderQueueDepth.toString() + '\n' +
      'codecLatencyMs=' + snapshot.codecLatencyMs.toString() + '\n' +
      'codecLatencyMaxMs=' + snapshot.codecLatencyMaxMs.toString() + '\n' +
      'surfaceUpdateFailures=' + snapshot.surfaceUpdateFailures.toString() + '\n' +
      'surfaceCoalesced=' + snapshot.surfaceCoalescedNotifications.toString() + '\n' +
      'inputAccepted=' + snapshot.inputAccepted.toString() + '\n' +
      'inputDrops=' + snapshot.inputDrops.toString() + '\n' +
      'presentedFrames=' + snapshot.presentedFrames.toString() + '\n' +
      'videoBytes=' + snapshot.videoBytes.toString() + '\n' +
      'presentationAgeMs=' + snapshot.presentationAgeMs.toString() + '\n' +
      'ingressAgeMs=' + snapshot.ingressAgeMs.toString() + '\n' +
      'stalled=' + snapshot.stalled.toString();
    try {
      const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
      pasteboard.getSystemPasteboard().setDataSync(data);
      promptAction.showToast({ message: '已复制脱敏诊断', duration: 1400 });
    } catch (_) {
      promptAction.showToast({ message: '复制诊断失败', duration: 1400 });
    }
  }

  private cancelConnection(): void {
    if (this.terminationBusy) { return; }
    this.disconnectMoonlightImmediately('connection-cancelled');
  }

  onBackPress(): boolean {
    if (this.terminationBusy) { return true; }
    this.disconnectMoonlightImmediately('system-back');
    return true;
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

  /**
   * ArkUI routes Back to the native Sheet while it is dismissing. Calling
   * router.back() in that same callback therefore consumes the navigation and
   * leaves a terminal stream page visible. A page without a Sheet still exits
   * in the current event frame; a Sheet-hosted exit continues from its exact
   * onDisappear receipt.
   */
  private requestSessionSurfaceClose(waitForSheetDisappear: boolean): void {
    if (waitForSheetDisappear && this.sessionWindowId.length === 0) {
      this.routeExitAfterSheetDisappear = true;
      return;
    }
    this.routeExitAfterSheetDisappear = false;
    this.closeSessionSurface();
  }

  private retryConnection(): void {
    promptAction.showToast({ message: '正在返回应用目录，请重新选择应用连接', duration: 1600 });
    this.leaveTerminalConnectSheet('retry-from-catalog');
  }

  private leaveTerminalConnectSheet(reason: string): void {
    const sheetWasVisible: boolean = this.showSessionSheet;
    if (!this.routeTerminated) { this.closeMoonlightRoute(reason); }
    this.closeSheet();
    this.requestSessionSurfaceClose(sheetWasVisible);
  }

  private flushInput(reason: string): void {
    this.discardPendingTrackpadPointer();
    const wasSuspended: boolean = this.inputSuspended;
    if (!wasSuspended) { this.setNativeInputSuspended(true, 'overlay_opened'); }
    this.inputFlushCount += 1;
    this.ctrlLatch = 'off'; this.altLatch = 'off'; this.shiftLatch = 'off'; this.winLatch = 'off';
    this.fnLayer = false;
    // Native suspension already performs the remote-neutral release. Only
    // discard the ArkTS gesture ledger here so a Sheet cannot inherit a drag.
    this.resetTrackpadGesture(false);
    this.publishTrackpadCursor();
    if (!wasSuspended) { this.setNativeInputSuspended(false, 'overlay_opened'); }
    hilog.info(0x0014, 'MoonlightStreamUi',
      'input local state cleared reason=' + reason + ' count=' + this.inputFlushCount.toString());
  }

  private pipAvailable(): boolean {
    return this.liveViewEnabled &&
      this.liveViewMode === LiveViewMode.AVSESSION && this.firstFrameSeen &&
      !this.routeTerminated;
  }

  private refreshMoonlightPipRestorePageId(reason: string): number {
    const candidate: number = this.getUniqueId();
    if (Number.isSafeInteger(candidate) && candidate > 0) {
      if (this.pipRestorePageId !== candidate) {
        this.pipRestorePageId = candidate;
        hilog.info(0x0014, 'MoonlightStreamUi',
          'PIP restore handle captured id=' + candidate.toString() +
          ' reason=' + reason);
      }
    }
    return this.pipRestorePageId;
  }

  private moonlightPipRestoreTarget(): RemoteSessionPipRestoreTarget | null {
    if (this.sessionWindowId.length > 0) { return null; }
    const handleId: number = this.refreshMoonlightPipRestorePageId('prepare');
    if (!Number.isSafeInteger(handleId) || handleId <= 0) { return null; }
    return { handleId: handleId };
  }

  private openSheet(mode: MoonlightSessionSheetMode): void {
    if (this.showConnectStage || this.surfaceRecovering || this.pendingConnectStageSheet) {
      return;
    }
    this.flushInput('open_l5_' + mode);
    this.setNativeInputSuspended(true, 'overlay_opened');
    this.restoreMoonlightSystemPointer('open-sheet-' + mode);
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
    if (this.routeExitAfterSheetDisappear) {
      this.routeExitAfterSheetDisappear = false;
      this.pendingConnectStageSheet = false;
      this.pendingSheetMode = 'none';
      this.closeSessionSurface();
      return;
    }
    if (this.pendingConnectStageSheet || this.showConnectStage) {
      this.pendingSheetMode = 'none';
      this.cancelSheetReopen();
      this.pendingConnectStageSheet = false;
      this.sheetMode = 'connect';
      this.setNativeInputSuspended(true, 'overlay_opened');
      const generation: number = this.sheetReopenGeneration;
      this.sheetReopenTimer = setTimeout((): void => {
        this.sheetReopenTimer = -1;
        if (this.pageActive && generation === this.sheetReopenGeneration &&
            this.connectStageGateActive() && this.surfaceLayoutReady) {
          this.showSessionSheet = true;
        }
      }, 0);
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
    this.syncMoonlightSystemPointer('sheet-disappear', true);
    if (this.keyboardOpen && this.keyboardImeActive) {
      // A native Sheet owns focus until its onDisappear receipt. Re-request
      // the virtual keyboard here so opening it from Control Center cannot
      // leave keyboardOpen=true without an actual IME.
      this.scheduleMoonlightVirtualKeyboardFocus('sheet-disappear');
    } else {
      this.scheduleMoonlightPhysicalKeyboardFocus('sheet-disappear');
    }
  }

  private toolbarAction(action: MoonlightToolbarAction): void {
    if (action === 'more') { this.openSheet('control'); return; }
    if (action === 'disconnect') {
      if (this.terminationBusy) {
        promptAction.showToast({ message: '正在安全退出并释放连接', duration: 1400 });
        return;
      }
      this.disconnectMoonlightImmediately('toolbar-disconnect');
      return;
    }
    if (action === 'diagnostics') {
      this.toggleDiagnosticsHud();
      promptAction.showToast({
        message: this.diagnosticsVisible ? '性能监控已开启' : '性能监控已关闭',
        duration: 1200
      });
      return;
    }
    if (action === 'controller') {
      this.openSheet('controller');
      return;
    }
    if (action === 'keyboard') {
      if (this.keyboardOpen) { this.dismissMoonlightKeyboard(); }
      else { this.openMoonlightKeyboard(); }
      return;
    }
    if (action === 'modifiers') {
      this.flushInput('toggle_modifier_from_toolbar');
      this.showShortcutPanel = false;
      this.placeMoonlightModifierPanel(false);
      this.showModifierPanel = !this.showModifierPanel;
      this.syncMoonlightSystemPointer('modifier-panel-toggle', true);
      return;
    }
    if (action === 'control') {
      const next: MoonlightInputControlMode = this.nextMoonlightControlMode();
      this.applyMoonlightControlMode(next);
      if (next !== 'keyboardMouse') {
        promptAction.showToast({
          message: next === 'adaptive' ? '自适应模式已启用' : '虚拟触控板已启用',
          duration: 1200
        });
      }
      return;
    }
    if (action === 'display') {
      void this.moveMoonlightToPip();
    }
  }

  private saveRemoteCustomShortcut(id: string, keyCodes: Array<number>): boolean {
    this.customShortcutSequence++;
    const effectiveId: string = id.trim().length > 0 ? id :
      'moonlight-shortcut-' + Date.now().toString() + '-' +
        this.customShortcutSequence.toString();
    const update: RemoteCustomShortcutUpdate = upsertRemoteCustomShortcut(
      this.remoteCustomShortcuts, effectiveId, keyCodes);
    if (!update.accepted) {
      promptAction.showToast({ message: update.reason, duration: 1800 });
      return false;
    }
    if (!RemoteKeyboardSettingsService.getInstance().saveCustomShortcuts(
      update.shortcuts, getContext(this) as common.Context)) {
      promptAction.showToast({ message: '组合键保存失败', duration: 2000 });
      return false;
    }
    this.remoteCustomShortcuts = update.shortcuts;
    return true;
  }

  private deleteRemoteCustomShortcut(id: string): void {
    const next: Array<RemoteCustomShortcut> = removeRemoteCustomShortcut(
      this.remoteCustomShortcuts, id);
    if (RemoteKeyboardSettingsService.getInstance().saveCustomShortcuts(
      next, getContext(this) as common.Context)) {
      this.remoteCustomShortcuts = next;
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
        this.closeSheet();
        this.flushInput('open_modifier_panel');
        this.placeMoonlightModifierPanel(false);
        this.showModifierPanel = true;
      },
      onOpenController: (): void => { this.openSheet('controller'); },
      onEnterPip: (): void => { this.closeSheet(); void this.moveMoonlightToPip(); },
      onToggleDiagnostics: (): void => { this.toggleDiagnosticsHud(); },
      onControlMode: (mode: MoonlightControlMode): void => {
        this.applyMoonlightControlMode(mode);
      },
      onDisconnect: (): void => { this.openSheet('stop'); }
    })
  }

  private openMoonlightVirtualController(): void {
    this.closeSheet();
    this.flushInput('open_virtual_controller');
    if (this.setVirtualControllerMode(true, false)) {
      this.controllerEditing = false;
      this.showController = true;
      this.restoreMoonlightSystemPointer('virtual-controller-open');
      return;
    }
    promptAction.showToast({ message: '虚拟手柄输入尚未就绪', duration: 1600 });
  }

  @Builder private physicalControllerSheet() {
    MoonlightPhysicalControllerSheet({
      inputReady: this.inputReady,
      controllerReady: this.controllerReady,
      physicalListenerReady: this.physicalControllerPathReady,
      rumbleEnabled: this.effectiveSettings.input.enableRumble,
      onRefresh: (): void => {
        this.refreshNativeInputReadiness();
        promptAction.showToast({
          message: this.physicalControllerPathReady ?
            '实体手柄监听已就绪' : '暂未检测到可用的系统手柄监听',
          duration: 1600
        });
      },
      onOpenVirtualController: (): void => { this.openMoonlightVirtualController(); },
      onClose: (): void => { this.closeSheet(); }
    })
  }

  @Builder private stopSheet() {
    Column() {
      Text('结束 Moonlight 串流？').fontSize(20).fontWeight(FontWeight.Bold).fontColor(this.pal().text)
      Text('可仅断开本地串流，也可在本地输入完全释放后结束主机端应用。')
        .fontSize(12).fontColor(this.pal().text3).lineHeight(18).margin({ top: 8 })
      Button('仅断开并保留主机应用').height(46).width('100%').borderRadius(13).fontSize(13)
        .backgroundColor(this.pal().surface).fontColor(this.pal().text).margin({ top: 20 })
        .border({ width: 1, color: this.pal().cardBorder })
        .onClick((): void => {
          void this.terminateMoonlightSession('disconnect');
        })
        .enabled(!this.terminationBusy).opacity(this.terminationBusy ? 0.55 : 1)
      Button(this.terminationBusy ? '正在安全结束…' : '结束主机应用并断开')
        .height(46).width('100%').borderRadius(13).fontSize(13)
        .backgroundColor('#D94B4B').fontColor(Color.White).margin({ top: 9 })
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
    if (this.sheetMode === 'connect') { this.connectStageSheet() }
    else if (this.sheetMode === 'control') { this.controlCenterSheet() }
    else if (this.sheetMode === 'controller') { this.physicalControllerSheet() }
    else if (this.sheetMode === 'stop') { this.stopSheet() }
    else { Column().width('100%').height(1) }
  }

  @Builder private connectStageSheet() {
    MoonlightConnectStageOverlay({
      inSheet: true,
      phase: this.surfaceRecovering ? 'reconnecting' : this.phase,
      elapsedMs: this.elapsedMs,
      firstFrameSeen: this.surfaceRecovering ? false : this.firstFrameSeen,
      errorCode: this.errorCode,
      degradationReasons: this.degradationReasons,
      onCancel: (): void => {
        if (this.pageActive && this.showConnectStage) { this.cancelConnection(); }
      },
      onRetry: (): void => {
        if (this.pageActive && this.showConnectStage) { this.retryConnection(); }
      },
      onDowngradeRetry: (): void => {
        if (this.pageActive && this.showConnectStage) { this.retryConnection(); }
      },
      onOpenDiagnostics: (): void => {
        if (!this.connectStageGateActive()) { return; }
        this.diagnosticsVisible = true;
        this.diagnosticsExpanded = true;
        this.publishDiagnosticsSnapshot(this.diagnosticsLatestSnapshot);
        this.startDiagnosticsPolling();
      },
      onBackToCatalog: (): void => {
        if (this.pageActive && this.showConnectStage) {
          this.leaveTerminalConnectSheet('connect-sheet-back');
        }
      }
    })
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      if (this.isDesktopDevice || this.sessionWindowId.length > 0 ||
          this.orientationApplied) {
        Stack() {
          XComponent({ id: this.xcId, type: XComponentType.SURFACE,
            libraryname: 'rdpnapi', controller: this.xComponentController })
            .width('100%').height('100%').backgroundColor('#000000')
            // Keep the hidden TextArea as the sole keyboard focus owner, just
            // like RDP/VNC. Pointer events remain attached to the Surface.
            .focusable(false).focusOnTouch(false)
            .onLoad(this.onMoonlightXComponentLoad)
            .onTouch(this.handleMoonlightSurfaceTouch)
            .onKeyEvent(this.handleMoonlightKey)
            .onMouse(this.handleMoonlightMouse)
            .onAxisEvent(this.handleMoonlightAxis)
            .onAreaChange((_oldArea: Area, newArea: Area): void => {
              this.onMoonlightSurfaceAreaChange(newArea);
            })

          // A real ArkUI hit surface is required above XComponent for every
          // input mode. Real Pad mice were visible in the system's XComponent
          // hit path but XComponent.onMouse was not invoked. RDP/VNC already
          // solve this by owning pointer hit testing on an independent layer.
          Stack() {
            Text(' ')
              .width('100%').height('100%').fontSize(1)
              .fontColor('rgba(0,0,0,0.001)')
          }
          .id('MoonlightRemoteInputSurface')
          .width(this.trackpadInputSurfaceWidth()).height('100%')
          .position({ x: 0, y: 0 })
          .backgroundColor('rgba(0,0,0,0.001)')
          .hitTestBehavior(HitTestMode.Block)
          .focusable(false).focusOnTouch(false).defaultFocus(false)
          .onTouch(this.handleMoonlightSurfaceTouch)
          .onKeyEvent(this.handleMoonlightKey)
          .onMouse(this.handleMoonlightMouse)
          .onAxisEvent(this.handleMoonlightAxis)
          .onHover(this.handleMoonlightRemoteSurfaceHover)
          .zIndex(40)
        }.width('100%').height('100%').zIndex(0)
      } else {
        Column().width('100%').height('100%').backgroundColor('#000000')
      }

      RemoteCursorOverlay({ cursor: this.trackpadCursorOverlayState })
        .zIndex(120)
        .hitTestBehavior(HitTestMode.None)

      if (this.toolbarLayout().edgeRail) {
        Stack({ alignContent: Alignment.End }) {
          MoonlightSessionToolbar({
            audioAvailable: this.effectiveSettings.audio.enabled && this.audioReady,
            controllerAvailable: this.controllerReady,
            pipAvailable: this.pipAvailable(),
            keyboardAvailable: this.inputReady,
            controlModeLabel: this.toolbarControlModeLabel(),
            diagnosticsVisible: this.diagnosticsVisible,
            terminationBusy: this.terminationBusy,
            menuOpen: this.showSessionSheet,
            qualityColor: this.firstFrameSeen ? '#66DD7A' : '#FFCF70',
            qualityLabel: this.firstFrameSeen ? '串流中' : '连接中',
            availableHeight: this.surfaceHeightVp,
            onAction: (action: MoonlightToolbarAction): void => {
              this.toolbarAction(action);
            },
            onUnavailable: (reason: string): void => {
              promptAction.showToast({ message: reason, duration: 1800 });
            }
          })
        }
        // Anchor to the actual ArkUI session viewport. Surface geometry can
        // temporarily exclude a fold/safe-area inset during rotation, which
        // previously left a visible gap between the rail and the right edge.
        .width('100%').height('100%')
        .hitTestBehavior(HitTestMode.Transparent)
        .zIndex(220)
      } else {
        Stack({ alignContent: Alignment.Top }) {
          MoonlightSessionToolbar({
            audioAvailable: this.effectiveSettings.audio.enabled && this.audioReady,
            controllerAvailable: this.controllerReady,
            pipAvailable: this.pipAvailable(),
            keyboardAvailable: this.inputReady,
            controlModeLabel: this.toolbarControlModeLabel(),
            diagnosticsVisible: this.diagnosticsVisible,
            terminationBusy: this.terminationBusy,
            menuOpen: this.showSessionSheet,
            qualityColor: this.firstFrameSeen ? '#66DD7A' : '#FFCF70',
            qualityLabel: this.firstFrameSeen ? '串流中' : '连接中',
            availableHeight: this.surfaceHeightVp,
            onAction: (action: MoonlightToolbarAction): void => {
              this.toolbarAction(action);
            },
            onUnavailable: (reason: string): void => {
              promptAction.showToast({ message: reason, duration: 1800 });
            }
          })
        }
        .width('100%').height(80)
        .position({ x: 0, y: this.toolbarLayout().topOffset })
        .hitTestBehavior(HitTestMode.Transparent)
        .zIndex(220)
      }

      if (this.sessionWindowId.length > 0) {
        RemoteSessionFullscreenButton({
          fullscreen: this.sessionWindowFullscreen,
          onToggle: (): void => { this.toggleIndependentWindowFullscreen(); }
        })
          .align(Alignment.BottomEnd)
          .margin({ right: 16, bottom: 16 })
          .zIndex(220)
      }

      if (this.showModifierPanel || this.showShortcutPanel) {
        RemoteModifierPanel({
          visible: this.showModifierPanel, shortcutVisible: this.showShortcutPanel, attachSide: 'right',
          ctrlLatch: this.ctrlLatch, altLatch: this.altLatch, shiftLatch: this.shiftLatch,
          winLatch: this.winLatch, fnLayer: this.fnLayer,
          panelX: this.modifierPanelX, panelY: this.modifierPanelY,
          shortcutX: this.shortcutPanelX, shortcutY: this.shortcutPanelY,
          emphasisColor: '#5B8FF9',
          shortcutPlatformOverride: this.physicalKeyboardLayout ===
            RemoteKeyboardLayout.MACOS ? 'macos' : 'windows',
          customizationEnabled: true,
          customShortcuts: this.remoteCustomShortcuts,
          onClose: (): void => {
            this.flushInput('close_modifier');
            this.showModifierPanel = false;
            this.syncMoonlightSystemPointer('modifier-panel-close', true);
          },
          onCloseShortcut: (): void => {
            this.flushInput('close_shortcut');
            this.showShortcutPanel = false;
            this.syncMoonlightSystemPointer('shortcut-panel-close', true);
          },
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
          },
          onSaveCustomShortcut: (id: string, keyCodes: Array<number>): boolean =>
            this.saveRemoteCustomShortcut(id, keyCodes),
          onDeleteCustomShortcut: (id: string): void => { this.deleteRemoteCustomShortcut(id); },
          onShortcutPlatformChange: (platform: RemoteShortcutPlatform): void => {
            this.flushInput('shortcut-platform-change');
            this.physicalKeyboardLayout = platform === 'macos' ?
              RemoteKeyboardLayout.MACOS : RemoteKeyboardLayout.WINDOWS;
            this.physicalKeyboardLayoutConfirmed = true;
            this.syncMoonlightSystemPointer('shortcut-platform-change', true);
          },
          onPanelPositionChange: (x: number, y: number): void => {
            this.moveMoonlightModifierPanel(x, y, false);
          },
          onShortcutPositionChange: (x: number, y: number): void => {
            this.moveMoonlightModifierPanel(x, y, true);
          },
          onPanelSizeChange: (width: number, height: number): void => {
            this.updateMoonlightModifierPanelSize(width, height, false);
          },
          onShortcutSizeChange: (width: number, height: number): void => {
            this.updateMoonlightModifierPanelSize(width, height, true);
          }
        }).zIndex(240).hitTestBehavior(HitTestMode.Transparent)
      }

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
        }).zIndex(240).hitTestBehavior(HitTestMode.Transparent)
      }

      if (this.diagnosticsVisible && !this.routeTerminated) {
        MoonlightDiagnosticsHud({
          snapshot: this.diagnosticsSnapshot,
          sampleEpoch: this.diagnosticsSampleEpoch,
          expanded: this.diagnosticsExpanded,
          x: this.diagnosticsX,
          y: this.diagnosticsY,
          viewportWidth: this.surfaceWidthVp,
          viewportHeight: this.surfaceHeightVp,
          onToggle: (): void => {
            this.diagnosticsExpanded = !this.diagnosticsExpanded;
            this.startDiagnosticsPolling();
          },
          onPositionChange: (x: number, y: number): void => {
            this.diagnosticsX = x;
            this.diagnosticsY = y;
          },
          onCopySanitized: (): void => { this.copySanitizedDiagnostics(); }
        }).zIndex(260).hitTestBehavior(HitTestMode.Transparent)
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
        .onKeyPreIme(this.handleMoonlightPhysicalKeyPreIme)
        .onFocus((): void => {
          this.physicalKeyboardProxyFocused = !this.keyboardOpen;
        })
        .onBlur((): void => {
          this.physicalKeyboardProxyFocused = false;
          this.scheduleMoonlightPhysicalKeyboardFocus('proxy-blur');
        })
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
    }.id('MoonlightStreamPageRoot')
      .width('100%').height('100%').backgroundColor('#000000')
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
      .bindSheet($$this.showSessionSheet, this.sessionSheet(), {
        height: this.sheetMode === 'control' ? '86%' : SheetSize.FIT_CONTENT,
        preferType: this.breakpoint === 'sm' ? SheetType.BOTTOM : SheetType.CENTER,
        dragBar: false, showClose: false,
        backgroundColor: this.sheetMode === 'connect' ? '#0E121C' : this.pal().sheetBg,
        blurStyle: BlurStyle.NONE,
        maskColor: this.sheetMode === 'connect' ? 'rgba(0,0,0,0.62)' : 'rgba(0,0,0,0.36)',
        onWillDismiss: (action: DismissSheetAction): void => {
          if (this.sheetMode === 'connect') {
            this.disconnectMoonlightImmediately('system-sheet-back');
          }
          action.dismiss();
        },
        onDisappear: (): void => { this.onSheetDisappear(); }
      })
  }
}
