/**
 * RemoteDesktop.ets v4 — 全屏远程桌面 + XComponent 生命周期 + 输入转发 + 错误诊断
 */
import { display, promptAction, router, window } from '@kit.ArkUI';
import { inputDevice, pointer } from '@kit.InputKit';
import { abilityAccessCtrl, common } from '@kit.AbilityKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { image } from '@kit.ImageKit';
import { HostSyncService } from '../services/HostSyncService';
import { CloudStore } from '../services/CloudStore';
import { DataCrypto } from '../services/DataCrypto';
import { ExtensionLoader } from '../services/ExtensionLoader';
import { RustDeskProSyncService } from '../services/RustDeskProSyncService';
import { KeyVaultService } from '../services/KeyVaultService';
import {
  RemoteHost,
  LockType,
  normalizeRdpCredentialParts,
  normalizeRdpAuthMode,
  normalizeRdpRestrictedAdminSecretSource,
  RdpAuthMode,
  RdpRestrictedAdminSecretSource
} from '../model/RemoteHost';
import { TotpEntry } from '../model/TotpEntry';
import { VncHostService, VncHostView } from '../services/VncHostService';
import { VncSecretLoadState } from '../services/VncSecretService';
import { VncGatewayService, VncGatewayView } from '../services/VncGatewayService';
import { VncSettingsService } from '../services/VncSettingsService';
import { VncTrustService } from '../services/VncTrustService';
import { VncSessionCredentialHandoff } from '../services/VncSessionCredentialHandoff';
import { VncSettingsValues } from '../services/VncModelPolicy';
import { vncGatewayAvailability } from '../services/VncGatewayProtocolPolicy';
import { shouldTreatVncConnectionStateAsTerminal } from '../services/VncConnectionStatePolicy';
import { diagnoseVncConnectionError } from '../services/VncConnectionErrorPolicy';
import { RustDeskRelayConfig } from '../model/RustDeskRelayConfig';
import { rustDeskRelayKeyModeForFfi } from '../services/RustDeskRelayKeyPolicy';
import { RdpCredential } from '../model/RdpCredential';
import { RustDeskProAccountState } from '../model/RustDeskProModels';
import {
  classifyRustDeskProNativeError,
  rustDeskProAccountIdForConnection,
  rustDeskProNativeErrorMessage,
  canInvalidateRustDeskProSession,
  rustDeskNativeErrorDetail,
  RustDeskProNativeErrorKind
} from '../services/RustDeskProConnectionPreflightPolicy';
import {
  RustDeskControlPlaneProfile,
  RUSTDESK_CONTROL_PLANE_DEFAULT,
  rustDeskControlPlaneRequiresAccount,
  rustDeskControlPlaneTokenForConnection
} from '../services/RustDeskControlPlanePolicy';
import { AppConfig, Palette, buildDark, buildLight } from '../common/Theme';
import { showLockGate, lockGateErrorMessage } from '../components/LockGate';
import { TotpEngine } from '../services/TotpEngine';
import {
  isRustDeskPeerTwoFactorManualCode,
  rustDeskPeerTwoFactorAutoSubmitError
} from '../services/RustDeskPeerTwoFactorPolicy';
import { RemoteModifierHandle } from '../components/RemoteModifierHandle';
import { RemoteModifierPanel } from '../components/RemoteModifierPanel';
import { RemoteCursorOverlay, RemoteCursorOverlayState } from '../components/RemoteCursorOverlay';
import { RemoteSessionTopBar, RemoteSessionTopBarActions } from '../components/RemoteSessionTopBar';
import { RustDeskDiagnosticsHud } from '../components/RustDeskDiagnosticsHud';
import {
  shouldEnableRustDeskPro,
  shouldShowSessionDiagnostics
} from '../services/RustDeskDiagnosticsPolicy';
// PassphraseDialog replaced with inline bindSheet (RemoteDesktop is @Entry, no bindSheet limit)
import { RemoteKeyDispatcher } from '../services/RemoteKeyDispatcher';
import { ClipboardBridgeService } from '../services/ClipboardBridgeService';
import { clipboardSyncEnabledForProtocol } from '../services/ClipboardSyncPolicy';
import { FileTransferLiveTaskService } from '../services/FileTransferLiveTaskService';
import { RemoteSessionBackgroundTaskService, RemoteSessionBgInfo } from '../services/RemoteSessionBackgroundTaskService';
import { RemoteSessionLiveViewService, LiveViewConnectionInfo } from '../services/RemoteSessionLiveViewService';
import { LiveViewMode } from '../services/LiveViewTypes';
import {
  RemoteSessionPipService,
  RemoteSessionPipSurface
} from '../services/RemoteSessionPipService';
import {
  RemoteSessionPipLifecycleAction,
  RemoteSessionPipContentSize,
  hasRemoteSessionPipVideo,
  hasRdpRemoteSessionPipFrame,
  shouldPrepareRemoteSessionPip,
  shouldCreatePreauthenticatedRustDeskPipeline,
  resolveRemoteSessionPipContentSize,
  resolveRemoteSessionPipLifecycle
} from '../services/RemoteSessionPipLifecyclePolicy';
import { ActiveRemoteSessionRegistry, ActiveRemoteSessionRecord } from '../services/ActiveRemoteSessionRegistry';
import { NativeSessionHandles, ProductionNativeHandleAdapter } from '../services/NativeSessionHandles';
import {
  decideRemoteDesktopBackgroundAction,
  RemoteDesktopBackgroundAction,
  shouldDeferRemoteDesktopDisappear
} from '../services/RemoteDesktopBackgroundLifecyclePolicy';
import {
  getRestoreFrameRefreshDelaysMs,
  RestoreRefreshAction,
  restoreRefreshActionForDelay,
  shouldRebindSurfaceForRestore,
  shouldRestoreRenderImmediately
} from '../services/RemoteRestoreFrameRefreshPolicy';
import {
  shouldInvalidateSurfaceAfterBackgroundDetach,
  shouldPollSurfaceAfterForegroundRestore
} from '../services/RemoteForegroundRestorePolicy';
import {
  shouldHideRemoteNavigation,
  shouldReapplyRemoteNavigation,
  shouldRestoreRemoteNavigation
} from '../services/RemoteImmersivePolicy';
import {
  shouldHideSystemPointerForVirtualTouchpad,
  shouldRenderTouchPointerIndicator,
  shouldUseSystemMousePointer
} from '../services/RemotePointerModePolicy';
import {
  normalizeRemoteCursorStyle,
  remoteCursorSnapshotChanged,
  RemoteCursorStyle,
  resolveRemoteCursorRenderMode,
  resolveRemoteCursorVisualScale,
  shouldRenderRemoteCursorArrow,
  shouldRenderRemoteCursorFallbackIndicator,
  shouldRenderCircleCursor,
  shouldRefreshRemoteCursorBitmap
} from '../services/RemoteCursorStylePolicy';
import {
  advanceRemoteCursorMotion,
  applyLocalCursorTarget,
  beginLocalCursorGesture,
  createRemoteCursorMotionState,
  endLocalCursorGesture,
  observeRemoteCursorPosition,
  RemoteCursorMotionState
} from '../services/RemoteCursorMotionPolicy';
import {
  clampTouchpadEffectiveGain,
  resetTouchpadPointerCurveState,
  TouchpadPointerCurveState,
  touchpadPointerCurve
} from '../services/TouchpadPointerCurvePolicy';
import {
  RemoteSurfaceDelta,
  RemoteSurfaceTransform,
  normalizeRendererViewportToSurface,
  remotePointToSurface,
  surfaceDeltaToRemote,
  surfacePointToRemote
} from '../services/RemoteSurfaceTransformPolicy';
import { shouldAcceptRendererViewportSnapshot } from '../services/RemoteRendererViewportPolicy';
import {
  advanceCanvasTwoFingerMove,
  beginCanvasTwoFingerCandidate,
  CANVAS_TWO_FINGER_HOLD_MS,
  CanvasTwoFingerState,
  claimCanvasTwoFingerPan,
  claimCanvasTwoFingerPinch,
  endCanvasPanOwnership,
  endCanvasPinchOwnership,
  expireCanvasTwoFingerHold,
  finishCanvasTwoFingerCandidate,
  idleCanvasTwoFingerState,
  shouldApplyCanvasTwoFingerPan,
  shouldPreserveCanvasTwoFingerRightClick,
  shouldSendCanvasTwoFingerScroll,
  shouldReleaseCanvasGestureOwnership
} from '../services/RemoteCanvasGesturePolicy';
import {
  CanvasTouchPointEvent,
  resolveCanvasActiveTouchCount
} from '../services/RemoteCanvasTouchPointPolicy';
import {
  baseCanvasTransform,
  canvasTransformCanPan,
  CanvasTransform,
  CanvasViewport,
  CANVAS_TRANSFORM_MAX_SCALE,
  clampCanvasTransform,
  LocalViewScaleMode,
  normalizeLocalViewScaleMode,
  panCanvasTransform,
  pinchCanvasTransform,
  REMOTE_DISPLAY_SCALE_PREFERENCE_VERSION,
  REMOTE_DISPLAY_SCALE_PREFERENCE_VERSION_KEY,
  resolveInitialRemoteDisplayScaleMode
} from '../services/RemoteCanvasTransformPolicy';
import {
  normalizeRdpResolutionId,
  rdpResolutionPresetForId
} from '../services/RemoteResolutionPresetPolicy';
import {
  remoteInputBlockedReason,
  shouldBlockRemoteInputForBrowseMode
} from '../services/RemoteInputGuardPolicy';
import {
  advanceCanvasPinchTouchState,
  CanvasPinchInputPhase,
  CanvasPinchTouchEvent,
  claimCanvasPinchTouchState,
  drainCanvasPinchTouchState,
  rustDeskTouchScaleDelta,
  shouldConsumeCanvasPinchTouch,
  shouldDrainCanvasPinchTouchSequence,
  shouldStartNewCanvasPinchTouchSequence
} from '../services/RemoteCanvasPinchInputPolicy';
import { RemoteProtocol } from '../services/RemoteSessionState';
import {
  canUseRustDeskAdaptiveOrientation,
  rustDeskOrientationPolicy
} from '../services/RemoteOrientationPolicy';
import { createTransferSnapshot, TransferProtocol, TransferState } from '../services/FileTransferProgressModel';
import { isRemoteCompletionConfirmed } from '../services/TransferSessionPolicy';
import {
  remoteTopBarLayout,
  shouldShowRustDeskTopBar
} from '../services/RemoteSessionTopBarPolicy';
import { RemoteSessionCapabilities, resolveSessionCapabilities } from '../services/RemoteSessionCapabilityPolicy';
import {
  RemoteSessionMediaSnapshot,
  resolveRemoteSessionMediaKind
} from '../services/RemoteSessionMediaStatePolicy';
import {
  BackgroundVideoPrewarmMode,
  backgroundVideoPrewarmIntervalMs,
  resolveBackgroundVideoPrewarmMode
} from '../services/BackgroundVideoPrewarmPolicy';
import {
  rdpSessionErrorSheetPrefersLandscapeCenter,
  rdpNoFrameWatchdogError,
  rdpSessionErrorFromNativeMessage,
  RdpSessionErrorDialogModel,
  shouldCleanupRdpSessionBeforeErrorDismiss,
  shouldShowRdpSessionErrorAfterControlPanelDismiss
} from '../services/RdpSessionErrorPolicy';
import {
  REMOTE_IME_CENTER,
  REMOTE_IME_PREVIEW_ENABLED,
  RemoteImeSelectionAction,
  createRemoteImeDiagnostic,
  createRemoteImeShadow,
  resolveRemoteImeDelete,
  resolveRemoteImeSelection,
  shouldAcceptRemoteImeTextChange,
  shouldCloseRemoteImeSessionOnEditChange,
  shouldRecenterRemoteImeShadow,
  shouldResetRemoteImeOnPointerDown,
  shouldWaitForRemoteImeInput
} from '../services/RemoteImeSessionPolicy';
import {
  RemoteImeCommand,
  RemoteImeCommandKind,
  RemoteImeCommandQueue
} from '../services/RemoteImeCommandQueue';
import { hashForLog, maskHost, maskUser, safeError } from '../utils/SafeLogger';
import {
  LocalResourceStats,
  RdpRenderStats,
  RemoteCursorSnapshot,
  RustDeskDisplayCapabilities,
  RustDeskDisplayInfo,
  RustDeskDisplayResolution,
  RustDeskDiagnosticsSnapshot,
  SessionConfig,
  SessionTransferStatus
} from '../types/rdpnapi';
import {
  normalizeRustDeskPort,
  rustDeskRelayFallbackPort,
  RUSTDESK_PEER_TCP_PORT,
  rustDeskAuthModeForConnection,
  rustDeskConnectionError
} from '../services/RustDeskHostConfigPolicy';
import {
  mapPhysicalKeyForRemoteLayout,
  isMacCapsLockLongPress,
  MACOS_CAPS_LOCK_LONG_PRESS_MS,
  RemoteKeyboardLayout,
  remoteKeyboardLayoutDescription,
  shouldChoosePhysicalKeyboardLayout,
  physicalKeyboardLayoutForProtocol,
  shouldConsumeRemoteBack
} from '../services/RemotePhysicalKeyboardPolicy';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { fileIo, fileUri, picker } from '@kit.CoreFileKit';
import { preferences, unifiedDataChannel, uniformDataStruct, uniformTypeDescriptor } from '@kit.ArkData';
import rdpnapi from 'librdpnapi.so';
import { util } from '@kit.ArkTS';

const RD_DOMAIN = 0x0014;
const RD_TAG = 'RemoteDesktop';
const TOUCH_CLICK_SLOP_PX = 18;
const TOUCH_DRAG_HOLD_MS = 1000;
const TOUCH_INDICATOR_HIDE_MS = 900;
const TOUCH_INDICATOR_ACTION_HIDE_MS = 1300;
const TOUCHPAD_POINTER_GAIN = 1.0;
const TOUCHPAD_SCROLL_GAIN = 0.08;
const TOUCHPAD_SCROLL_FLUSH_MS = 24;
const TOUCHPAD_SCROLL_MAX_DELTA = 2;
const TOUCH_DIRECT_RIGHT_CLICK_MS = 650;
const REMOTE_IME_SELECTION_ACK_TIMEOUT_MS = 600;
const REMOTE_IME_COMMAND_RETRY_MS = 50;
const INPUT_LOG_SAMPLE_MS = 1000;
const MOUSE_MOVE_FLUSH_MS = 16;
const MOUSE_MOVE_IN_FLIGHT_DIAGNOSTIC_TIMEOUT_MS = 250;
const RENDERER_VIEWPORT_CACHE_MS = 250;
const REMOTE_CURSOR_POLL_MS = 33;
const REMOTE_CURSOR_RENDER_FRAME_MS = 16;
const REMOTE_CURSOR_BITMAP_RETRY_MS = 1000;
const REMOTE_CURSOR_LOG_SAMPLE_MS = 5000;
const REMOTE_CURSOR_ASYNC_WATCHDOG_MS = 2000;
const REMOTE_CURSOR_MAX_ASYNC_OUTSTANDING = 2;
const REMOTE_CURSOR_PIXELMAP_RETIRE_GRACE_MS = REMOTE_CURSOR_RENDER_FRAME_MS * 2;
const REMOTE_CURSOR_PIXELMAP_RETIRE_RETRY_MS = REMOTE_CURSOR_RENDER_FRAME_MS;
const REMOTE_CURSOR_MAX_RETIRED_PIXELMAPS = 8;
const REMOTE_GEOMETRY_SYNC_MS = 500;
const REMOTE_DESKTOP_DISAPPEAR_BACKGROUND_SIGNAL_WAIT_MS = 500;
const TOUCHPAD_MAX_LOCAL_STEP_RATIO = 0.75;
const TOUCHPAD_MAX_LOCAL_STEP_VP = 420;
const TOUCH_INDICATOR_BUTTON_RIGHT = 2;
const TOUCH_INDICATOR_BUTTON_DRAG = 3;
const RUSTDESK_ADAPTIVE_MAX_EDGE_PX = 1600;
const REMOTE_FILE_CHUNK_BYTES = 256 * 1024;
const RUSTDESK_FILE_MAX_BYTES = 100 * 1024 * 1024;
const RDP_FILE_MAX_BYTES = 2 * 1024 * 1024 * 1024;
const RDP_TRANSFER_DIR_NAME = 'rdp_transfer';
const RDP_TRANSFER_DRIVE_NAME = 'RemoteDesktop';
const RDP_DRIVE_REDIRECTION_ENABLED = true;
const RUSTDESK_TRANSFER_DIR = 'C:\\Users\\Public\\Documents\\RemoteDesktop';
const FILE_TRANSFER_DIAG_RDP_DIR = 'E-RDP-FILE-DIR';
const FILE_TRANSFER_DIAG_FILE_NAME = 'E-FILE-NAME';
const FILE_TRANSFER_DIAG_LIVE_CONTEXT = 'E-FILE-LIVE-CONTEXT';
const FILE_TRANSFER_DIAG_RDP_COPY = 'E-RDP-FILE-COPY';
const FILE_TRANSFER_DIAG_RUSTDESK_SEND = 'E-RUSTDESK-FILE-SEND';
const FILE_TRANSFER_DIAG_PICK = 'E-FILE-PICK';
const FILE_TRANSFER_DIAG_DROP_URI = 'E-FILE-DROP-URI';
const FILE_TRANSFER_DIAG_DROP_META = 'E-FILE-DROP-META';
const FILE_TRANSFER_DIAG_DROP = 'E-FILE-DROP';
const KEYCODE_DPAD_UP = 2012;
const KEYCODE_DPAD_DOWN = 2013;
const KEYCODE_DPAD_LEFT = 2014;
const KEYCODE_DPAD_RIGHT = 2015;
const KEYCODE_ALT_LEFT = 2045;
const KEYCODE_ALT_RIGHT = 2046;
const KEYCODE_SHIFT_LEFT = 2047;
const KEYCODE_SHIFT_RIGHT = 2048;
const KEYCODE_TAB = 2049;
const KEYCODE_SPACE = 2050;
const KEYCODE_ENTER = 2054;
const KEYCODE_DEL = 2055;
const KEYCODE_PAGE_UP = 2068;
const KEYCODE_PAGE_DOWN = 2069;
const KEYCODE_ESCAPE = 2070;
const KEYCODE_FORWARD_DEL = 2071;
const KEYCODE_CTRL_LEFT = 2072;
const KEYCODE_CTRL_RIGHT = 2073;
const KEYCODE_CAPS_LOCK = 2074;
// RustDesk FFI 私有键码：明确要求按 macOS 原始虚拟键码 0x39 发送 Caps Lock。
// 用户已经在当前会话选择 macOS 时使用，避免 FFI 再依赖 PeerInfo.platform 猜测。
const RUSTDESK_MACOS_CAPS_LOCK_RAW = 0x10039;
const KEYCODE_SCROLL_LOCK = 2075;
const KEYCODE_META_LEFT = 2076;
const KEYCODE_META_RIGHT = 2077;
const KEYCODE_MENU = 2067;
const KEYCODE_MOVE_HOME = 2081;
const KEYCODE_MOVE_END = 2082;
const KEYCODE_INSERT = 2083;
// T-172 P0-3: Harmony keyCode namespace (统一虚拟面板+实体键盘)
const KEYCODE_0 = 2000;
const KEYCODE_9 = 2009;
const KEY_A = 2017;
const KEY_C = 2019;
const KEY_D = 2020;
const KEY_E = 2021;
const KEY_R = 2034;
const KEY_V = 2038;
const KEY_W = 2039;
const KEY_X = 2040;
const KEY_Z = 2042;
const KEYCODE_COMMA = 2043;
const KEYCODE_PERIOD = 2044;
const KEYCODE_GRAVE = 2056;
const KEYCODE_MINUS = 2057;
const KEYCODE_EQUALS = 2058;
const KEYCODE_LEFT_BRACKET = 2059;
const KEYCODE_RIGHT_BRACKET = 2060;
const KEYCODE_BACKSLASH = 2061;
const KEYCODE_SEMICOLON = 2062;
const KEYCODE_APOSTROPHE = 2063;
const KEYCODE_SLASH = 2064;
const KEYCODE_AT = 2065;
const KEYCODE_PLUS = 2066;
const KEY_F1 = 2090;
const KEY_F4 = 2093;
const KEY_F12 = 2101;
const KEYCODE_NUM_LOCK = 2102;
const KEY_F13 = 2816;
const KEY_F24 = 2827;

interface RemoteDesktopSurfaceListener {
  onSurfaceCreated(surfaceId: string): void;
  onSurfaceDestroyed(surfaceId: string): void;
}

interface RdpCredentialParts {
  username: string;
  domain: string;
}

/**
 * VNC uses this transient projection only because the existing desktop page
 * owns renderer/input lifecycle. It is never serialized or passed to
 * HostSyncService; all connection values are reassembled from VNC owners.
 */
interface VncSessionOwner {
  host: VncHostView;
  settings: VncSettingsValues;
  gateway: VncGatewayView | null;
}

interface DesktopSize {
  width: number;
  height: number;
  colorDepth: number;
  multiMonitor: boolean;
  monitorCount: number;
}

interface MappedPoint {
  x: number;
  y: number;
  inside: boolean;
}

interface LocalPoint {
  x: number;
  y: number;
  inside: boolean;
}

interface RendererViewportSnapshot {
  transformVersion: number;
  sourceWidth: number;
  sourceHeight: number;
  surfaceWidth: number;
  surfaceHeight: number;
  viewportX: number;
  viewportY: number;
  viewportW: number;
  viewportH: number;
}

interface RetiredRemoteCursorPixelMap {
  pixelMap: image.PixelMap;
  notBeforeMs: number;
  requiredViewRevision: number;
}

type ModifierLatch = 'off' | 'once' | 'locked';
type RustDeskAuthChoice = 'password' | 'request_approval';
type RustDeskAuthDismissReason = 'none' | 'confirm' | 'cancel';
type VncPasswordDismissReason = 'none' | 'confirm' | 'cancel';

const EMPTY_RUSTDESK_DIAGNOSTICS: RustDeskDiagnosticsSnapshot = {
  supported: false, sessionActive: false, protocolSnapshotAvailable: false,
  videoSeen: false, receivedRateAvailable: false, presentedRateAvailable: false,
  decodeRateAvailable: false, sessionId: -1, latencyMs: -1, targetBitrateKbps: 0,
  videoMessages: 0, receivedFrames: 0, keyframes: 0, receivedBytes: 0,
  audioFrames: 0, cadenceGaps: 0, maxCadenceGapMs: 0, testDelayCount: 0,
  receivedFps: 0, displayFps: 0, decodeFps: 0, bitrateKbps: 0, codec: -1, width: 0, height: 0,
  connectionPath: 'unknown', lastFrameAtMs: 0, lastFrameAgeMs: -1, decodeOk: 0, decodeErrors: 0,
  decodeP50Us: 0, decodeP95Us: 0, decodeMaxUs: 0, presentedFrames: 0,
  presentationRejected: 0,
  presentationWindowSamples: 0, presentationWindowMs: 0,
  renderP50Us: 0, renderP95Us: 0, renderMaxUs: 0,
  queueDepth: 0, queueMax: 0,
  droppedFrames: 0, decoderBackend: 'unknown'
};

const EMPTY_RUSTDESK_DISPLAY_CAPABILITIES: RustDeskDisplayCapabilities = {
  supported: false,
  currentDisplay: 0,
  width: 0,
  height: 0,
  originalWidth: 0,
  originalHeight: 0,
  scaleMilli: 1000,
  geometryEpoch: 0,
  resolutions: [],
  displays: []
};

const EMPTY_LOCAL_RESOURCE_STATS: LocalResourceStats = {
  supported: false, cpuAvailable: false, cpuPercent: -1, memoryBytes: 0,
  memoryAvailable: false, gpuAvailable: false, gpuPercent: -1, sampledAtMs: 0
};

class RemoteDesktopXComponentController extends XComponentController {
  private listener: RemoteDesktopSurfaceListener | null = null;

  setListener(listener: RemoteDesktopSurfaceListener): void {
    this.listener = listener;
    hilog.info(0x0014, 'XCController', 'setListener: listener=' + (listener ? 'OK' : 'NULL'));
  }

  onSurfaceCreated(surfaceId: string): void {
    // 直接打 hilog — 诊断框架是否调用此方法
    hilog.info(0x0014, 'XCController', 'onSurfaceCreated 被调用! surfaceId=' + surfaceId);
    if (this.listener) {
      this.listener.onSurfaceCreated(surfaceId);
    } else {
      hilog.warn(0x0014, 'XCController', 'onSurfaceCreated: listener=NULL! surfaceId 丢失!');
    }
  }

  onSurfaceDestroyed(surfaceId: string): void {
    hilog.info(0x0014, 'XCController', 'onSurfaceDestroyed: surfaceId=' + surfaceId);
    if (this.listener) {
      this.listener.onSurfaceDestroyed(surfaceId);
    }
  }
}

@Entry
@Component
struct RemoteDesktop {
  @StorageLink('currentTheme') theme: string = 'light';
  @StorageProp('accentColor') accentColor: string = '#007DFF';
  @StorageProp('currentBreakpoint') breakpoint: string = 'sm';
  @StorageProp('isDesktopDevice') isDesktopDevice: boolean = false;
  @StorageLink('rustdeskControlMode') @Watch('onRemoteControlModeChange')
  rustdeskControlMode: number = 0; // 0=touchpad, 1=direct touch, 2=keyboard/mouse
  @StorageLink('rustdeskImageQuality') rustdeskImageQuality: number = 1;
  @StorageLink('rustdeskCodec') rustdeskCodec: number = 0;
  @StorageLink('rustdeskPrivacyMode') rustdeskPrivacyMode: boolean = false;
  @StorageLink('rustdeskAudioEnabled') rustdeskAudioEnabled: boolean = true;
  @StorageLink('rustdeskShowDiagnostics') @Watch('onRustDeskDiagnosticsSettingChange')
  rustdeskShowDiagnostics: boolean = false;
  @StorageLink('rustdeskShowProDiagnostics') @Watch('onRustDeskDiagnosticsSettingChange')
  rustdeskShowProDiagnostics: boolean = false;
  @StorageLink('rustdeskClipboardEnabled') rustdeskClipboardEnabled: boolean = true;
  @StorageLink('rustdeskFilePasteEnabled') rustdeskFilePasteEnabled: boolean = true;
  @StorageLink('rustdeskRemoteAppTouchScaleEnabled') @Watch('onRemoteAppTouchScaleSettingChange')
  rustdeskRemoteAppTouchScaleEnabled: boolean = false;
  @StorageLink('rustdeskViewScaleMode') rustdeskViewScaleMode: string = 'fit';
  @StorageLink('remoteDisplayScaleMode') remoteDisplayScaleMode: string = 'fit';
  @StorageLink('remoteDisplayCustomScalePercent') remoteDisplayCustomScalePercent: number = 100;
  @StorageLink('canvasGestureZoomEnabled') @Watch('onCanvasGestureZoomSettingChange')
  canvasGestureZoomEnabled: boolean = false;
  @StorageLink('rustdeskShowLocalCursor') rustdeskShowLocalCursor: boolean = true;
  @StorageLink('rustdeskBrowseMode') rustdeskBrowseMode: boolean = false;
  @StorageLink('rustdeskRelativeMouseMode') rustdeskRelativeMouseMode: boolean = false;
  @StorageLink('rustdeskReverseWheel') rustdeskReverseWheel: boolean = false;
  @StorageLink('rustdeskSwapMouseButtons') rustdeskSwapMouseButtons: boolean = false;
  @StorageLink('rustdeskTouchpadSpeed') rustdeskTouchpadSpeed: number = 1.0;
  @StorageLink('virtualMouseStyle') virtualMouseStyle: string = 'circle';
  @StorageLink('rdpControlMode') @Watch('onRemoteControlModeChange')
  rdpControlMode: number = 0; // 0=touchpad, 1=direct touch, 2=keyboard/mouse
  @State vncControlMode: number = 0; // VNC-only: 0=touchpad, 1=direct touch, 2=keyboard/mouse
  @State @Watch('onRustDeskDiagnosticsSettingChange') vncShowDiagnostics: boolean = false;
  @StorageLink('rdpDriveEnabled') rdpDriveEnabled: boolean = true;
  @StorageLink('rdpDriveName') rdpDriveName: string = 'RemoteDesktop';
  @StorageLink('remoteDesktopBgFlag') @Watch('onRemoteDesktopBgFlagChange') remoteDesktopBgFlag: boolean = false;
  @State @Watch('onRemoteConnectionStateChange') connected: boolean = false;
  @State connecting: boolean = true;
  @State connectionError: string = '';
  @State connectionErrorDetail: string = '';
  @State showRdpSessionErrorSheet: boolean = false;
  @State rdpSessionErrorTitle: string = '你的会话已断开';
  @State rdpSessionErrorMessage: string = '';
  @State rdpSessionErrorCode: string = '';
  @State showRustDeskAuthSheet: boolean = false;
  @State showRustDeskTwoFactorSheet: boolean = false;
  @State showVncPasswordSheet: boolean = false;
  @State rustDeskDiagnostics: RustDeskDiagnosticsSnapshot = EMPTY_RUSTDESK_DIAGNOSTICS;
  @State rustDeskDisplayCapabilities: RustDeskDisplayCapabilities = EMPTY_RUSTDESK_DISPLAY_CAPABILITIES;
  @State showRustDeskDisplayResolutionMenu: boolean = false;
  @State localResourceStats: LocalResourceStats = EMPTY_LOCAL_RESOURCE_STATS;
  @State rustDeskAuthChoice: RustDeskAuthChoice = 'password';
  @State rustDeskAuthPasswordInput: string = '';
  @State rustDeskAuthPasswordMode: number = 0;
  @State rustDeskAuthPasswordShow: boolean = false;
  @State rustDeskAuthRememberPassword: boolean = true;
  @State rustDeskAuthError: string = '';
  @State rustDeskTwoFactorInput: string = '';
  @State rustDeskTwoFactorError: string = '';
  @State rustDeskTwoFactorSubmitting: boolean = false;
  @State vncPasswordInput: string = '';
  @State vncRememberPassword: boolean = false;
  @State vncPasswordError: string = '';
  @State vncPasswordStatus: VncSecretLoadState = 'missing';
  private rdpSessionErrorBackPending: boolean = false;
  private rdpSessionErrorPendingCleanupReason: string = '';
  private rdpSessionErrorPendingAfterControlPanel: boolean = false;
  @State hostLabel: string = '';
  @State touchIndicatorVisible: boolean = false;
  @State touchIndicatorX: number = 0;
  @State touchIndicatorY: number = 0;
  @State touchIndicatorButton: number = -1;
  @State isLandscape: boolean = true;  // 横竖屏切换状态
  private srv: HostSyncService = HostSyncService.getInstance();
  private loader: ExtensionLoader = ExtensionLoader.getInstance();
  private keyVault: KeyVaultService = KeyVaultService.getInstance();
  private readonly proSync: RustDeskProSyncService = RustDeskProSyncService.getInstance();
  private readonly vncSettings: VncSettingsService = VncSettingsService.getInstance();
  private readonly vncHosts: VncHostService = VncHostService.getInstance();
  private readonly vncGateways: VncGatewayService = VncGatewayService.getInstance();
  private readonly vncTrust: VncTrustService = VncTrustService.getInstance();
  private nativeHandles: NativeSessionHandles =
    new NativeSessionHandles(new ProductionNativeHandleAdapter((): ExtensionLoader => this.loader));
  private clipboardBridge: ClipboardBridgeService | null = null;
  private keyDispatcher: RemoteKeyDispatcher = new RemoteKeyDispatcher();
  private hostId: string = '';
  private xcId: string = 'rdpSurface';
  // R0: session/renderer/decoder handle 追踪
  private sessionId: number = -1;
  private rustDeskTwoFactorSessionId: number = -1;
  private rustDeskTwoFactorAutoAttemptSessionId: number = -1;
  private rendererHandle: number = -1;
  private decoderHandle: number = -1;
  private surfaceReady: boolean = false;
  private inputForwardReady: boolean = false;
  private connectStarted: boolean = false;
  private cleanupStarted: boolean = false;
  private bgRestorePending: boolean = false; // T-252: 后台保活恢复待处理 (替代 AppStorage 时序问题)
  private activeSessionRegistry: ActiveRemoteSessionRegistry = ActiveRemoteSessionRegistry.getInstance();
  private latestSurfaceId: string = '';
  private keepScreenOnActive: boolean = false;
  private orientationApplied: boolean = false;
  private connectAttemptId: number = 0;
  private pendingHost: RemoteHost | null = null;
  private pendingVncHost: VncHostView | null = null;
  // Set only by the RustDesk Pro preflight handoff. It is consumed after the
  // first renderer/decoder pair is installed and is never inferred from a
  // renderer handle, because normal PIP restore intentionally releases that
  // handle before reattaching the same decoder.
  private preAuthenticatedSessionPending: boolean = false;
  private rustDeskAuthDismissReason: RustDeskAuthDismissReason = 'none';
  private rustDeskAuthBackPending: boolean = false;
  private rustDeskAuthPendingStart: boolean = false;
  private rustDeskAuthSheetClosing: boolean = false;
  private rustDeskAuthQueuedMessage: string | null = null;
  private vncPasswordDismissReason: VncPasswordDismissReason = 'none';
  private vncPasswordBackPending: boolean = false;
  private vncPasswordPendingStart: boolean = false;
  private vncPasswordSheetClosing: boolean = false;
  private vncTransientPassword: string = '';
  private vncAuthResolved: boolean = false;
  private rustDeskSessionAuthChoice: RustDeskAuthChoice = 'password';
  private rustDeskSessionPassword: string = '';
  private rustDeskSessionRememberPassword: boolean = false;
  private rustDeskSessionPasswordMode: number = 0;
  private remoteNavigationHidden: boolean = false;
  private backgroundAudioPollTimer: number = -1;
  private pendingDisappearDecisionTimer: number = -1;
  private disappearDecisionGeneration: number = 0;
  private rustDeskDiagnosticsTimer: number = -1;
  private rustDeskDiagnosticsDockInitialized: boolean = false;
  private backgroundSessionInfo: RemoteSessionBgInfo | null = null;
  private backgroundHasAudio: boolean = false;
  private backgroundHasVideo: boolean = false;
  private renderPreservedInPip: boolean = false;
  // The current renderer handle can change during a failed/stale transfer.
  // Keep the PIP owner separately so foreground recovery can release exactly
  // the free-node renderer before installing the page renderer.
  private pipRendererHandle: number = -1;
  private pipSurfaceTransferInProgress: boolean = false;
  private restoreFrameRefreshTimers: number[] = [];
  // Foreground restore is a teardown barrier: no surface callback or connect
  // retry may rebuild a renderer until PIP and the decoder render thread are
  // fully stopped.
  private restoreInProgress: boolean = false;
  private restoreOperationId: number = 0;
  private pipRestoreRetryTimer: number = -1;
  private nativeDisconnectPending: boolean = false;
  private nativeDisconnectRetryTimer: number = -1;
  private pipContentSizeRefreshTimers: number[] = [];
  private pipLastContentWidth: number = 0;
  private pipLastContentHeight: number = 0;
  private xComponentController: RemoteDesktopXComponentController = new RemoteDesktopXComponentController();
  private surfaceWidth: number = 0;
  private surfaceHeight: number = 0;
  private renderWidthPx: number = 0;
  private renderHeightPx: number = 0;
  private rendererSourceWidth: number = 0;
  private rendererSourceHeight: number = 0;
  private rendererViewportCache: RendererViewportSnapshot | null = null;
  private rendererViewportCacheHandle: number = -1;
  private rendererViewportReadAtMs: number = 0;
  // Native viewport snapshots are published by the renderer thread. Keep the
  // newest transform generation submitted by ArkTS so an older frame cannot
  // overwrite the gesture-time geometry cache.
  private rendererCanvasTransformPendingVersion: number = 0;
  // Pinch math uses a local geometry snapshot. Native viewport reads are kept
  // on low-frequency resize/stream-geometry paths instead of the gesture loop.
  private canvasViewportSnapshot: CanvasViewport | null = null;
  private canvasViewportSnapshotHandle: number = -1;
  private remoteWidth: number = 1920;
  private remoteHeight: number = 1080;
  private rustDeskGeometryEpoch: number = 0;
  private remoteCursorX: number = 960;
  private remoteCursorY: number = 540;
  private remoteCursorPreciseX: number = 960;
  private remoteCursorPreciseY: number = 540;
  private remoteCursorMotion: RemoteCursorMotionState = createRemoteCursorMotionState(960, 540);
  private remoteCursorReady: boolean = false;
  @State remoteCursorOverlayState: RemoteCursorOverlayState = new RemoteCursorOverlayState();
  private remoteCursorViewRevision: number = 0;
  private remoteCursorPixelMap: image.PixelMap | null = null;
  private remoteCursorGeneration: number = -1;
  private remoteCursorShapeRevision: number = -1;
  private remoteCursorPixelMapShapeRevision: number = -1;
  private remoteCursorPositionRevision: number = -1;
  private remoteCursorVisibilityRevision: number = -1;
  private remoteCursorNativeVisible: boolean = false;
  private remoteCursorFallbackShape: boolean = false;
  private remoteCursorShapeWidth: number = 0;
  private remoteCursorShapeHeight: number = 0;
  private remoteCursorHotX: number = 0;
  private remoteCursorHotY: number = 0;
  private remoteCursorShapeRetryAtMs: number = 0;
  private remoteCursorLastLogMs: number = 0;
  private remoteCursorViewCommitTimer: number = -1;
  private remoteCursorViewCommitPending: boolean = false;
  private remoteCursorShapeLoadToken: number = 0;
  private remoteCursorShapeLoading: boolean = false;
  private remoteCursorShapeLoadingSessionId: number = -1;
  private remoteCursorShapeLoadingGeneration: number = -1;
  private remoteCursorShapeLoadingRevision: number = -1;
  private remoteCursorShapeLoadWatchdogTimer: number = -1;
  private remoteCursorShapeLoadOutstandingTokens: Array<number> = [];
  private remoteCursorPixelFetchToken: number = 0;
  private remoteCursorPixelFetchInFlight: boolean = false;
  private remoteCursorPixelFetchSessionId: number = -1;
  private remoteCursorPixelFetchGeneration: number = -1;
  private remoteCursorPixelFetchRevision: number = -1;
  private remoteCursorPixelFetchStartedAtMs: number = 0;
  private remoteCursorPixelFetchWatchdogTimer: number = -1;
  private remoteCursorPixelFetchOutstandingTokens: Array<number> = [];
  private retiredRemoteCursorPixelMaps: Array<RetiredRemoteCursorPixelMap> = [];
  private deferredRemoteCursorPixelMap: RetiredRemoteCursorPixelMap | null = null;
  // Defensive teardown/replacement handoff. Normal shape adoption stops
  // before the bounded retired queue is full, so this slot cannot grow with
  // cursor transitions.
  private overflowRemoteCursorPixelMap: RetiredRemoteCursorPixelMap | null = null;
  private remoteCursorPixelMapReleaseTimer: number = -1;
  private remoteSystemPointerVisible: boolean | null = null;
  private remoteSurfaceUsesSystemPointer: boolean | null = null;
  private remoteSurfaceHovered: boolean | null = null;
  private touchpadCurveState: TouchpadPointerCurveState = resetTouchpadPointerCurveState();
  private touchpadAnchorValid: boolean = false;
  private lastTouchpadCurveLogMs: number = 0;
  private touchpadPointerDown: boolean = false;
  // 触控板手势状态机
  private touchFingerCount: number = 0;   // 当前屏幕上的手指数
  private touchDragActive: boolean = false; // 单指长按拖拽进行中 (左键已按下)
  private touchDragPending: boolean = false; // 双指轻点待确认 (无移动抬起时发送右键)
  private touchMoved: boolean = false;    // 本次手势是否有过移动
  private touchStartLocalX: number = 0;  // 第一根手指的起始 X
  private touchStartLocalY: number = 0;  // 第一根手指的起始 Y
  private touchLastLocalX: number = 0;   // 上一帧手指 X
  private touchLastLocalY: number = 0;   // 上一帧手指 Y
  private touchDragCursorX: number = 0;  // 双指开始时的光标 X (用于防漂移)
  private touchDragCursorY: number = 0;  // 双指开始时的光标 Y
  private touchWheelRemainder: number = 0;
  private lastTouchWheelMs: number = 0;
  private touchLeftDown: boolean = false; // 直接模式用: 左键是否按下
  private touchGestureDone: boolean = false; // 双指手势已完成, 抑制剩余手指的多余点击
  private touchMaxFingers: number = 0;       // 本次手势最高手指数 (用于三指检测)
  private activeTouchPoints: Map<number, LocalPoint> = new Map<number, LocalPoint>();
  private canvasTransform: CanvasTransform = { scale: 1, panX: 0, panY: 0 };
  private canvasTransformInitialized: boolean = false;
  // A default display scale must be recalculated when the surface or stream
  // geometry changes.  Only a real local canvas pinch owns a persistent
  // transform across those geometry changes.
  private canvasTransformGestureModified: boolean = false;
  private canvasPinchActive: boolean = false;
  private canvasPanActive: boolean = false;
  private canvasTwoFingerState: CanvasTwoFingerState = idleCanvasTwoFingerState();
  private canvasTwoFingerSequence: number = 0;
  private canvasTwoFingerHoldTimer: number = -1;
  private canvasPanInputSource: 'none' | 'touch' | 'gesture' = 'none';
  private canvasPanLastOffsetX: number = 0;
  private canvasPanLastOffsetY: number = 0;
  // Gesture coordinates arrive in vp while the renderer transform is in px.
  // Capture density once at gesture start instead of synchronously reading
  // display state for every pinch/pan update.
  private canvasGesturePxPerVp: number = 1;
  private canvasPinchInputPhase: CanvasPinchInputPhase = 'idle';
  private canvasPinchTouchCount: number = 0;
  private canvasPinchLastScale: number = 1;
  private canvasPinchLastCenterX: number = 0;
  private canvasPinchLastCenterY: number = 0;
  // A gesture owns one geometry snapshot for its whole lifetime. Surface and
  // stream changes release the gesture before a new snapshot can be captured.
  private canvasPinchViewportSnapshot: CanvasViewport | null = null;
  private rustDeskTouchPinchActive: boolean = false;
  private rustDeskTouchPinchLastScale: number = 1;
  private rustDeskTouchPinchLastRemoteX: number = 0;
  private rustDeskTouchPinchLastRemoteY: number = 0;
  private rustDeskTouchPanOnly: boolean = false;
  private rustDeskTouchPinchTransformSnapshot: RemoteSurfaceTransform | null = null;
  private keepKeyboardAfterSheetClose: boolean = false;
  // 三指控制面板
  @State showControlPanel: boolean = false;
  @State keyboardOpen: boolean = false;
  @State fileTransferBusy: boolean = false;
  @State fileTransferProgress: number = -1;
  @State fileTransferStatus: string = '';
  @State rdpDriveMounted: boolean = false;
  @State dropHoverActive: boolean = false;
  // 悬浮胶囊与修饰键面板 (T-171 Phase 1)
  @State handleVisible: boolean = false;
  @State handleX: number = 0;
  @State handleY: number = 300;
  @State handleSide: string = 'right';
  @State rustDeskDiagnosticsDockExpanded: boolean = false;
  @State rustDeskDiagnosticsDockSide: string = 'left';
  @State rustDeskDiagnosticsDockY: number = 360;
  @State modifierPanelMounted: boolean = false;
  @State modifierPanelVisible: boolean = false;
  @State shortcutPanelVisible: boolean = false;
  @State modifierPanelX: number = 8;
  @State modifierPanelY: number = 70;
  @State shortcutPanelX: number = 8;
  @State shortcutPanelY: number = 200;
  @State kbHeight: number = 0;
  private modifierPanelPositionReady: boolean = false;
  // 修饰键虚拟状态 (Phase 2: once/locked 状态机)
  @State ctrlLatch: ModifierLatch = 'off';
  @State altLatch: ModifierLatch = 'off';
  @State shiftLatch: ModifierLatch = 'off';
  @State winLatch: ModifierLatch = 'off';
  @State fnLayer: boolean = false;
  // T-172 P0-2: 追踪远端是否已按下修饰键 (解锁时需发送 key up)
  private remoteCtrlDown: boolean = false;
  private remoteAltDown: boolean = false;
  private remoteShiftDown: boolean = false;
  private remoteWinDown: boolean = false;
  // 虚拟键盘
  @State keyboardText: string = '';
  private keyboardSubmitRefocusPending: boolean = false;
  private keyboardController: TextAreaController = new TextAreaController();
  private keyboardImeActive: boolean = false;
  private keyboardImeGeneration: number = 0;
  private keyboardImeEditingObserved: boolean = false;
  private keyboardInitialSelectionPending: boolean = false;
  private keyboardSyncedCaret: number = REMOTE_IME_CENTER;
  private keyboardExpectedStart: number = -1;
  private keyboardExpectedEnd: number = -1;
  private keyboardProgrammaticSelection: boolean = false;
  private keyboardSelectionAckTimer: number = -1;
  private keyboardCommandQueue: RemoteImeCommandQueue = new RemoteImeCommandQueue();
  private keyboardCommandPumpTimer: number = -1;
  private touchIndicatorTimer: number = -1;
  private kbWin: window.Window | null = null;
  private kbAvoidCb: ((data: window.AvoidAreaOptions) => void) | null = null;
  private touchHoldDragTimer: number = -1;
  private touchDirectRightClickTimer: number = -1;
  private lastTouchMs: number = 0;
  private inputLogCount: number = 0;
  private lastInputLogMs: number = 0;
  private remoteInputFocusTimer: number = -1;
  @State private hardwareKeyboardProxyActive: boolean = false;
  private physicalKeyboardLayout: RemoteKeyboardLayout = RemoteKeyboardLayout.WINDOWS;
  private physicalKeyboardLayoutConfirmed: boolean = false;
  private physicalKeyboardLayoutPromptVisible: boolean = false;
  private physicalKeyboardConnected: boolean = false;
  private inputDeviceRefreshEpoch: number = 0;
  private lastMacInputSourceShortcutMs: number = 0;
  private macCapsLockDownAtMs: number = 0;
  private macCapsLockHoldTimer: number = -1;
  private macCapsLockRawDown: boolean = false;
  private pendingMouseMoveX: number = 0;
  private pendingMouseMoveY: number = 0;
  private pendingMouseMoveValid: boolean = false;
  private pendingMouseMoveSequence: number = 0;
  private pendingMouseMoveGeneration: number = 0;
  private mouseMoveSequenceCounter: number = 0;
  private localMouseMoveSequence: number = 0;
  private localMouseMoveInFlight: boolean = false;
  private localMouseMoveSentX: number = 0;
  private localMouseMoveSentY: number = 0;
  private localMouseMoveSentAtMs: number = 0;
  private localMouseMoveGeneration: number = 0;
  private mouseMoveTimer: number = -1;
  private physicalMouseDownButton: number = -1;
  private physicalWheelRemainder: number = 0;
  private inputDeviceListenerRegistered: boolean = false;
  private inputDevicePromptVisible: boolean = false;
  private externalInputPromptedThisSession: boolean = false;
  private inputDeviceBaselineIds: Array<number> = [];
  private fileTransferHideTimer: number = -1;
  private rdpClipboardBatchSequence: number = 0;
  private rdpRenderWatchdogTimer: number = -1;
  private rdpNativeStateMonitorTimer: number = -1;
  private remoteCursorPollTimer: number = -1;
  private rustDeskGeometrySyncTimer: number = -1;
  private rustDeskDisplaySwitchPending: number = -1;
  private rustDeskDisplaySwitchStartedAtMs: number = 0;
  private lastBrowseModeBlockedToastMs: number = 0;
  private lastVncViewOnlyBlockedToastMs: number = 0;

  private inputDeviceListener: Callback<inputDevice.DeviceListener> =
    (data: inputDevice.DeviceListener): void => {
      this.refreshPhysicalKeyboardPresence('device-' + data.type);
      if (data.type === 'add') {
        this.handleInputDeviceAdded(data.deviceId);
      }
    };

  private pal(): Palette {
    return this.theme === 'light' ? buildLight(this.accentColor) : buildDark(this.accentColor);
  }

  private applyDesktopKeyboardMouseMode(): void {
    if (!this.isDesktopDevice || this.breakpoint !== 'xl') { return; }
    const host: RemoteHost | null = this.pendingHost;
    if (!host) { return; }
    if (host.protocol === 'rdp') {
      hilog.info(RD_DOMAIN, RD_TAG,
        'PC large-screen detected, RDP control mode respects user setting=' + this.rdpControlMode.toString());
      return;
    }
    if (host.protocol === 'rustdesk') {
      hilog.info(RD_DOMAIN, RD_TAG,
        'PC large-screen detected, RustDesk control mode respects user setting=' +
          this.rustdeskControlMode.toString());
      return;
    }
    if (host.protocol === 'vnc') {
      hilog.info(RD_DOMAIN, RD_TAG,
        'PC large-screen detected, VNC control mode respects VNC setting=' +
          this.vncControlMode.toString());
    }
  }

  private registerInputDeviceWatcher(): void {
    if (this.inputDeviceListenerRegistered) { return; }
    try {
      inputDevice.getDeviceList().then((ids: Array<number>): void => {
        this.inputDeviceBaselineIds = ids;
        hilog.info(RD_DOMAIN, RD_TAG, 'inputDevice baseline count=' + ids.length.toString());
      }).catch((err: Error): void => {
        hilog.warn(RD_DOMAIN, RD_TAG, 'inputDevice baseline unavailable: ' + JSON.stringify(err));
      });
      inputDevice.on('change', this.inputDeviceListener);
      this.inputDeviceListenerRegistered = true;
      this.refreshPhysicalKeyboardPresence('watcher-registered');
    } catch (err) {
      hilog.warn(RD_DOMAIN, RD_TAG, 'inputDevice watcher unavailable: ' + JSON.stringify(err));
    }
  }

  private isBaselineInputDevice(deviceId: number): boolean {
    return this.inputDeviceBaselineIds.indexOf(deviceId) >= 0;
  }

  private isKeyboardMouseDevice(device: inputDevice.InputDeviceData): boolean {
    const sources: Array<inputDevice.SourceType> = device.sources ?? [];
    return sources.indexOf('keyboard') >= 0 || sources.indexOf('mouse') >= 0 || sources.indexOf('touchpad') >= 0;
  }

  private async handleInputDeviceAdded(deviceId: number): Promise<void> {
    try {
      if (this.isBaselineInputDevice(deviceId)) {
        hilog.info(RD_DOMAIN, RD_TAG, 'ignore baseline inputDevice add id=' + deviceId.toString());
        return;
      }
      const device: inputDevice.InputDeviceData = await inputDevice.getDeviceInfo(deviceId);
      if (this.isKeyboardMouseDevice(device)) {
        this.promptSwitchToKeyboardMouseMode(device.name);
      }
    } catch (err) {
      hilog.warn(RD_DOMAIN, RD_TAG, 'inputDevice add ignored: ' + JSON.stringify(err));
    }
  }

  private promptSwitchToKeyboardMouseMode(deviceName: string): void {
    if (this.inputDevicePromptVisible || this.externalInputPromptedThisSession) {
      return;
    }
    const host: RemoteHost | null = this.pendingHost;
    if (!host) { return; }
    if (host.protocol === 'rdp' && this.rdpControlMode === 2) { return; }
    if (host.protocol === 'rustdesk' && this.rustdeskControlMode === 2) { return; }
    if (host.protocol === 'vnc' && this.vncControlMode === 2) { return; }
    if (host.protocol !== 'rdp' && host.protocol !== 'rustdesk' && host.protocol !== 'vnc') { return; }
    this.externalInputPromptedThisSession = true;
    this.inputDevicePromptVisible = true;
    const name: string = deviceName && deviceName.length > 0 ? deviceName : '键盘/鼠标';
    const protocolLabel: string = host.protocol === 'rdp' ? 'Windows RDP' :
      (host.protocol === 'rustdesk' ? 'RustDesk' : 'VNC');
    promptAction.showDialog({
      title: '检测到外接键鼠',
      message: '已检测到 ' + name + '，是否切换为 ' + protocolLabel + ' 键鼠模式？',
      buttons: [
        { text: '稍后', color: 'rgba(255,255,255,0.7)' },
        { text: '切换', color: this.accentColor }
      ]
    }).then((result: Object): void => {
      this.inputDevicePromptVisible = false;
      const r: Record<string, number> = result as Record<string, number>;
      if (r['index'] === 1) {
        if (host.protocol === 'rdp') {
          this.rdpControlMode = 2;
          AppStorage.setOrCreate('rdpControlMode', 2);
        } else if (host.protocol === 'rustdesk') {
          this.rustdeskControlMode = 2;
          AppStorage.setOrCreate('rustdeskControlMode', 2);
        } else {
          const values: VncSettingsValues = this.vncSettings.get();
          values.controlMode = 2;
          const saved = this.vncSettings.save(values);
          this.vncControlMode = 2;
          if (!saved.ok) {
            hilog.warn(RD_DOMAIN, RD_TAG, 'VNC control mode persistence failed: ' + saved.message);
          }
        }
        this.hideTouchIndicator();
        promptAction.showToast({ message: '已切换为键鼠模式', duration: 1500 });
        this.scheduleRemoteInputFocus('control-mode-switch');
      }
    }).catch((_err: Error): void => {
      this.inputDevicePromptVisible = false;
    });
  }

  private isKeyboardMouseControlMode(): boolean {
    const host: RemoteHost | null = this.pendingHost;
    if (!host) { return false; }
    if (host.protocol === 'rdp') { return this.rdpControlMode === 2; }
    if (host.protocol === 'rustdesk') { return this.rustdeskControlMode === 2; }
    if (host.protocol === 'vnc') {
      return this.vncControlMode === 2 && this.pendingVncHost !== null && !this.pendingVncHost.viewOnly;
    }
    return false;
  }

  private currentControlMode(): number {
    const host: RemoteHost | null = this.pendingHost;
    if (host === null) { return 0; }
    if (host.protocol === 'rdp') { return this.rdpControlMode; }
    if (host.protocol === 'rustdesk') { return this.rustdeskControlMode; }
    if (host.protocol === 'vnc') {
      return Math.max(0, Math.min(2, Math.floor(this.vncControlMode)));
    }
    return 0;
  }

  private isVncViewOnlySession(): boolean {
    return this.isVncSession() && this.pendingVncHost !== null && this.pendingVncHost.viewOnly;
  }

  private shouldShowRustDeskSessionTopBar(): boolean {
    const host: RemoteHost | null = this.pendingHost;
    if (!host) { return false; }
    return shouldShowRustDeskTopBar(host.protocol, this.isDesktopDevice, this.breakpoint, this.rustdeskControlMode);
  }

  private isRustDeskSession(): boolean {
    const host: RemoteHost | null = this.pendingHost;
    return host !== null && host.protocol === 'rustdesk';
  }

  private async refreshPhysicalKeyboardPresence(reason: string): Promise<void> {
    const epoch: number = ++this.inputDeviceRefreshEpoch;
    let keyboardConnected: boolean = false;
    try {
      const ids: Array<number> = await inputDevice.getDeviceList();
      for (let index: number = 0; index < ids.length; index++) {
        try {
          const device: inputDevice.InputDeviceData = await inputDevice.getDeviceInfo(ids[index]);
          const sources: Array<inputDevice.SourceType> = device.sources ?? [];
          if (sources.indexOf('keyboard') >= 0) {
            keyboardConnected = true;
            break;
          }
        } catch (deviceErr) {
          hilog.warn(RD_DOMAIN, RD_TAG, 'inputDevice inspect failed id=' + ids[index].toString() +
            ' err=' + JSON.stringify(deviceErr));
        }
      }
    } catch (err) {
      hilog.warn(RD_DOMAIN, RD_TAG, 'physical keyboard refresh failed reason=' + reason +
        ' err=' + JSON.stringify(err));
      return;
    }
    if (epoch !== this.inputDeviceRefreshEpoch) {
      return;
    }
    const changed: boolean = this.physicalKeyboardConnected !== keyboardConnected;
    this.physicalKeyboardConnected = keyboardConnected;
    hilog.info(RD_DOMAIN, RD_TAG, 'physical-keyboard-presence connected=' +
      (keyboardConnected ? '1' : '0') + ' changed=' + (changed ? '1' : '0') + ' reason=' + reason);
    if (!changed) {
      return;
    }
    if (!keyboardConnected) {
      this.hardwareKeyboardProxyActive = false;
      this.releaseAllHeldKeys();
      return;
    }
    if (this.connected && !this.keyboardOpen) {
      this.scheduleRemoteInputFocus('physical-keyboard-connected');
    }
  }

  private isTouchpadControlMode(): boolean {
    const host: RemoteHost | null = this.pendingHost;
    if (!host || !this.connected) { return false; }
    if (host.protocol === 'rdp') { return this.rdpControlMode === 0; }
    if (host.protocol === 'rustdesk') { return this.rustdeskControlMode === 0; }
    if (host.protocol === 'vnc') { return this.vncControlMode === 0; }
    return false;
  }

  private remoteCursorDisplayStyle(): RemoteCursorStyle {
    return normalizeRemoteCursorStyle(this.virtualMouseStyle);
  }

  private isProRustDeskHost(host: RemoteHost | null): boolean {
    return host !== null && host.protocol === 'rustdesk' &&
      host.sourceType === 'rustdesk_pro' && host.rustdeskProManaged;
  }

  /**
   * Pro 地址簿主机每次新建会话都显式选择认证方式；后台恢复不经过这里，
   * 因为恢复的是已有 RustDesk 会话而不是重新认证。
   */
  private openRustDeskAuthSheet(message: string = ''): void {
    if (this.rustDeskAuthSheetClosing) {
      this.rustDeskAuthQueuedMessage = message;
      return;
    }
    const host: RemoteHost | null = this.pendingHost;
    if (host === null || host.protocol !== 'rustdesk' || host.sourceType !== 'rustdesk_pro' ||
      !host.rustdeskProManaged) {
      this.tryStartConnect();
      return;
    }
    this.rustDeskAuthChoice = host.rustdeskDirectEnabled ? 'password' :
      (host.rustdeskAuthMode === 'request_approval' ? 'request_approval' : 'password');
    this.rustDeskAuthPasswordInput = host.password;
    this.rustDeskAuthPasswordMode = host.rustdeskPasswordMode === 1 ? 1 : 0;
    this.rustDeskAuthPasswordShow = false;
    this.rustDeskAuthRememberPassword = true;
    this.rustDeskAuthError = message;
    this.rustDeskAuthDismissReason = 'none';
    this.rustDeskAuthBackPending = false;
    this.rustDeskAuthPendingStart = false;
    this.showRustDeskAuthSheet = true;
    setTimeout((): void => { this.focusRustDeskAuthPassword(); }, 120);
  }

  private requestRustDeskAuthCancellation(): void {
    this.rustDeskAuthDismissReason = 'cancel';
    this.rustDeskAuthBackPending = true;
    this.rustDeskAuthPendingStart = false;
    this.rustDeskAuthError = '';
    this.connectStarted = false;
    this.connecting = false;
    this.connectionError = '连接已取消';
    this.connectionErrorDetail = '未建立 RustDesk 会话';
  }

  private cancelRustDeskAuthChoice(): void {
    this.rustDeskAuthSheetClosing = true;
    this.requestRustDeskAuthCancellation();
    this.showRustDeskAuthSheet = false;
  }

  private confirmRustDeskAuthChoice(): void {
    const host: RemoteHost | null = this.pendingHost;
    if (host === null || host.protocol !== 'rustdesk' || host.sourceType !== 'rustdesk_pro' ||
      !host.rustdeskProManaged) {
      this.rustDeskAuthDismissReason = 'confirm';
      this.rustDeskAuthPendingStart = true;
      this.rustDeskAuthSheetClosing = true;
      this.showRustDeskAuthSheet = false;
      return;
    }
    if (this.rustDeskAuthChoice === 'request_approval' && host.rustdeskDirectEnabled) {
      this.rustDeskAuthError = '当前主机使用直连模式，不能请求远端批准，请改用设备密码。';
      return;
    }

    const selected = RemoteHost.fromJSON(host.toJSON());
    selected.rustdeskPasswordMode = this.rustDeskAuthPasswordMode === 1 ? 1 : 0;
    if (this.rustDeskAuthChoice === 'password') {
      if (this.rustDeskAuthPasswordInput.trim().length === 0) {
        this.rustDeskAuthError = '请输入远程 RustDesk 设备密码。';
        return;
      }
      selected.password = this.rustDeskAuthPasswordInput;
      selected.rustdeskAuthMode = 'password';
      this.rustDeskSessionPassword = this.rustDeskAuthPasswordInput;
      this.rustDeskSessionRememberPassword = this.rustDeskAuthRememberPassword;
    } else {
      // 保留已保存密码作为回退材料，但本次 FFI 连接明确走批准模式。
      selected.rustdeskAuthMode = 'request_approval';
      this.rustDeskSessionPassword = '';
      this.rustDeskSessionRememberPassword = false;
    }
    this.rustDeskSessionPasswordMode = this.rustDeskAuthPasswordMode === 1 ? 1 : 0;
    this.rustDeskSessionAuthChoice = this.rustDeskAuthChoice;
    this.pendingHost = selected;
    this.rustDeskAuthDismissReason = 'confirm';
    this.rustDeskAuthPendingStart = true;
    this.rustDeskAuthSheetClosing = true;
    this.showRustDeskAuthSheet = false;
    this.rustDeskAuthError = '';
    this.connectionError = '';
    this.connectionErrorDetail = '';
    this.connectStarted = false;
    this.connecting = true;
  }

  private focusRustDeskAuthPassword(): void {
    if (!this.showRustDeskAuthSheet || this.rustDeskAuthChoice !== 'password') {
      return;
    }
    try {
      this.getUIContext().getFocusController().requestFocus('RustDeskAuthPassword');
    } catch (err) {
      hilog.warn(RD_DOMAIN, RD_TAG, 'RustDesk auth password focus failed: ' + JSON.stringify(err));
    }
  }

  private handleRustDeskAuthSheetDismiss(action: DismissSheetAction): void {
    if (this.rustDeskAuthDismissReason === 'confirm' || this.rustDeskAuthDismissReason === 'cancel') {
      action.dismiss();
      return;
    }
    this.rustDeskAuthSheetClosing = true;
    this.requestRustDeskAuthCancellation();
    action.dismiss();
  }

  private handleRustDeskAuthSheetDisappear(): void {
    const reason: RustDeskAuthDismissReason = this.rustDeskAuthDismissReason;
    const shouldStart: boolean = reason === 'confirm' && this.rustDeskAuthPendingStart;
    const queuedMessage: string | null = this.rustDeskAuthQueuedMessage;
    this.rustDeskAuthDismissReason = 'none';
    this.rustDeskAuthPendingStart = false;
    this.rustDeskAuthSheetClosing = false;
    this.rustDeskAuthQueuedMessage = null;
    // 系统下滑/返回键关闭时必须视为取消，不能让连接绕过授权选择。
    if (reason === 'none') {
      this.requestRustDeskAuthCancellation();
    } else if (reason === 'cancel') {
      this.requestRustDeskAuthCancellation();
    }
    if (this.rustDeskAuthBackPending) {
      this.rustDeskAuthBackPending = false;
      // 等 bindSheet 的 native 退出回调完成后再销毁页面，避免下一个
      // RemoteDesktop 页面复用到仍在退出的授权 Sheet 宿主。
      setTimeout((): void => { this.goBack(); }, 0);
      return;
    }
    if (shouldStart) {
      setTimeout((): void => { this.tryStartConnect(); }, 0);
      return;
    }
    if (queuedMessage !== null) {
      setTimeout((): void => { this.openRustDeskAuthSheet(queuedMessage); }, 0);
    }
  }

  /**
   * RustDesk Peer 2FA is a second step of the existing encrypted login.  Keep
   * the native session alive while the user enters the code; opening a new
   * connection here would lose the challenge and can create a second relay.
   */
  private openRustDeskTwoFactorPrompt(sessionId: number, message: string = ''): void {
    if (this.rustDeskTwoFactorSessionId !== sessionId) {
      this.rustDeskTwoFactorInput = '';
      this.rustDeskTwoFactorError = '';
      this.rustDeskTwoFactorSubmitting = false;
    }
    this.rustDeskTwoFactorSessionId = sessionId;
    if (message.indexOf('Wrong 2FA Code') >= 0) {
      this.rustDeskTwoFactorError = '验证码错误，请输入远端设备当前显示的 2FA 验证码。';
      this.rustDeskTwoFactorSubmitting = false;
    } else if (message.length > 0 && message !== '2FA Required' &&
      message !== '2FA code submitted') {
      this.rustDeskTwoFactorError = message;
    }
    this.showRustDeskTwoFactorSheet = true;
  }

  private async tryAutoSubmitRustDeskTwoFactor(sessionId: number, host: RemoteHost): Promise<void> {
    if (!host.rustdeskTotpAutoSubmit || host.rustdeskTotpEntryId === '' ||
      this.rustDeskTwoFactorAutoAttemptSessionId === sessionId) {
      return;
    }
    this.rustDeskTwoFactorAutoAttemptSessionId = sessionId;
    // The secret is released only after the system authentication gate.  The
    // native side receives the short-lived code only; it never receives the
    // TOTP secret or the vault entry.
    const gate = await showLockGate('RustDesk 2FA 自动填写', 'biometric');
    if (this.sessionId !== sessionId || this.connectAttemptId <= 0) {
      return;
    }
    if (!gate.ok) {
      this.openRustDeskTwoFactorPrompt(sessionId, lockGateErrorMessage(gate) ||
        '未通过系统身份认证，请手动输入验证码。');
      return;
    }
    const entry: TotpEntry | undefined = this.keyVault.getTotpEntry(host.rustdeskTotpEntryId);
    if (entry === undefined || entry.secret.length === 0) {
      this.openRustDeskTwoFactorPrompt(sessionId, '已绑定的 2FA 条目不可用，请手动输入验证码。');
      return;
    }
    const generated = TotpEngine.generateCode(entry);
    const autoSubmitError: string = rustDeskPeerTwoFactorAutoSubmitError(entry, generated);
    if (autoSubmitError !== '') {
      this.openRustDeskTwoFactorPrompt(sessionId, autoSubmitError);
      return;
    }
    if (!this.loader.submitRustDesk2FA(sessionId, generated.code)) {
      this.openRustDeskTwoFactorPrompt(sessionId, this.loader.getRustDeskLastError() ||
        '自动提交验证码失败，请手动输入。');
      return;
    }
    this.rustDeskTwoFactorSubmitting = true;
    this.openRustDeskTwoFactorPrompt(sessionId, '2FA code submitted');
    this.rustDeskTwoFactorSubmitting = true;
  }

  private cancelRustDeskTwoFactor(): void {
    this.loader.disconnect();
    this.connectAttemptId += 1;
    this.showRustDeskTwoFactorSheet = false;
    this.rustDeskTwoFactorSessionId = -1;
    this.rustDeskTwoFactorAutoAttemptSessionId = -1;
    this.rustDeskTwoFactorInput = '';
    this.rustDeskTwoFactorSubmitting = false;
    this.connectStarted = false;
    this.connecting = false;
    this.connectionError = '连接已取消';
    this.connectionErrorDetail = '未建立 RustDesk 会话';
    this.sessionId = -1;
  }

  private submitRustDeskTwoFactor(): void {
    const code: string = this.rustDeskTwoFactorInput.trim();
    if (!isRustDeskPeerTwoFactorManualCode(code)) {
      this.rustDeskTwoFactorError = '请输入 6 或 8 位数字验证码。';
      return;
    }
    if (this.rustDeskTwoFactorSessionId <= 0) {
      this.rustDeskTwoFactorError = '2FA 会话已失效，请重新连接。';
      return;
    }
    if (!this.loader.submitRustDesk2FA(this.rustDeskTwoFactorSessionId, code)) {
      this.rustDeskTwoFactorError = this.loader.getRustDeskLastError() ||
        '验证码提交失败，请重新连接。';
      this.rustDeskTwoFactorSubmitting = false;
      return;
    }
    this.rustDeskTwoFactorError = '';
    this.rustDeskTwoFactorSubmitting = true;
    this.rustDeskTwoFactorInput = '';
  }

  private handleRustDeskTwoFactorSheetDismiss(action: DismissSheetAction): void {
    action.dismiss();
    if (this.showRustDeskTwoFactorSheet) {
      this.cancelRustDeskTwoFactor();
    }
  }

  @Builder rustDeskTwoFactorSheetBuilder() {
    Column({ space: 12 }) {
      Row() {
        Column({ space: 4 }) {
          Text('需要 2FA 验证').fontSize(19).fontWeight(FontWeight.Bold)
            .fontColor(this.pal().text)
          Text('远端 RustDesk 设备要求输入动态验证码，当前连接会保持等待。')
            .fontSize(12).fontColor(this.pal().text2)
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        Text('取消').fontSize(13).fontColor(this.pal().text2)
          .onClick((): void => { this.cancelRustDeskTwoFactor(); })
      }.width('100%')

      TextInput({ placeholder: '输入 2FA 验证码', text: this.rustDeskTwoFactorInput })
        .type(InputType.Normal)
        .height(46).width('100%').backgroundColor(this.pal().surface).borderRadius(10)
        .fontColor(this.pal().text).placeholderColor(this.pal().text3)
        .fontSize(16).maxLength(8)
        .onChange((value: string): void => {
          this.rustDeskTwoFactorInput = value.replace(/[^0-9]/g, '');
          this.rustDeskTwoFactorError = '';
          this.rustDeskTwoFactorSubmitting = false;
        })

      Text(this.rustDeskTwoFactorSubmitting ? '验证码已提交，等待远端确认…' :
        '验证码不会保存，也不会发送到应用外部。')
        .fontSize(11).fontColor(this.pal().text3).width('100%')
      if (this.rustDeskTwoFactorError.length > 0) {
        Text(this.rustDeskTwoFactorError).fontSize(12).fontColor(this.pal().danger).width('100%')
      }
      Row({ space: 10 }) {
        Button('取消').layoutWeight(1).height(42).fontSize(13)
          .backgroundColor(this.pal().surface).fontColor(this.pal().text2).borderRadius(10)
          .onClick((): void => { this.cancelRustDeskTwoFactor(); })
        Button(this.rustDeskTwoFactorSubmitting ? '等待中' : '验证')
          .layoutWeight(1).height(42).fontSize(13).fontWeight(FontWeight.Medium)
          .backgroundColor(this.accentColor).fontColor(Color.White).borderRadius(10)
          .enabled(!this.rustDeskTwoFactorSubmitting)
          .onClick((): void => { this.submitRustDeskTwoFactor(); })
      }.width('100%')
    }
    .width('100%').padding({ left: 24, right: 24, top: 22, bottom: 28 })
    .backgroundColor(this.pal().sheetBg)
  }

  private prepareVncAuthentication(): void {
    const host: VncHostView | null = this.pendingVncHost;
    if (host === null) { return; }
    const loaded = this.vncHosts.passwordStateFor(host.id);
    this.vncPasswordStatus = loaded.state;
    if (loaded.state === 'available') {
      this.vncAuthResolved = true;
      this.vncTransientPassword = '';
      this.tryStartConnect();
      return;
    }
    this.vncAuthResolved = false;
    let message: string = '';
    if (loaded.state === 'locked') {
      message = '已保存的 VNC 密码仍是加密密文；解锁应用加密后可使用，也可以输入一次性密码连接。';
    } else if (loaded.state === 'consent_required') {
      message = '这台设备有已同步的未加密密码。使用前请在本设备再次确认，不会自动信任新设备。';
    } else if (loaded.state === 'invalid') {
      message = '已保存的 VNC 密码记录无效，请重新输入；本次连接仍可使用一次性密码。';
    }
    this.openVncPasswordSheet(message);
  }

  private openVncPasswordSheet(message: string = ''): void {
    if (this.vncPasswordSheetClosing || this.showVncPasswordSheet) { return; }
    if (this.pendingVncHost === null) { return; }
    this.vncPasswordInput = '';
    this.vncRememberPassword = false;
    this.vncPasswordError = message;
    this.vncPasswordDismissReason = 'none';
    this.vncPasswordBackPending = false;
    this.vncPasswordPendingStart = false;
    this.showVncPasswordSheet = true;
    setTimeout((): void => { this.focusVncPassword(); }, 120);
  }

  private focusVncPassword(): void {
    if (!this.showVncPasswordSheet) { return; }
    try {
      this.getUIContext().getFocusController().requestFocus('VncPasswordInput');
    } catch (err) {
      hilog.warn(RD_DOMAIN, RD_TAG, 'VNC password focus failed: ' + JSON.stringify(err));
    }
  }

  private finishVncAuthentication(password: string, remember: boolean,
    plainStorageConfirmed: boolean): void {
    const host: VncHostView | null = this.pendingVncHost;
    if (host === null) { return; }
    if (remember) {
      const saveResult = this.vncHosts.savePassword(host.id, password, true, plainStorageConfirmed);
      if (!saveResult.ok) {
        // A credential persistence failure must not turn a valid one-time test
        // connection into a hard feature block. The result is intentionally
        // reported without logging the password, then the native call receives
        // this in-memory value only.
        promptAction.showToast({ message: saveResult.message + '；本次将使用临时密码连接', duration: 2200 });
      }
    }
    this.vncTransientPassword = password;
    // The sheet input is no longer needed after confirmation. Keep only the
    // short-lived value used by the pending connection path.
    this.vncPasswordInput = '';
    this.vncAuthResolved = true;
    this.vncPasswordDismissReason = 'confirm';
    this.vncPasswordPendingStart = true;
    this.vncPasswordSheetClosing = true;
    this.showVncPasswordSheet = false;
    this.vncPasswordError = '';
    this.connectionError = '';
    this.connectionErrorDetail = '';
    this.connectStarted = false;
    this.connecting = true;
  }

  private confirmVncPasswordChoice(): void {
    if (this.pendingVncHost === null) { return; }
    if (this.vncPasswordInput.length === 0) {
      this.vncPasswordError = '请输入 VNC 密码，或选择“无密码连接”。';
      return;
    }
    const crypto: DataCrypto = DataCrypto.getInstance();
    if (this.vncRememberPassword && crypto.isSetupComplete() && !crypto.isReady()) {
      this.vncPasswordError = '应用加密已锁定；请先解锁，或关闭“记住密码”后连接。';
      return;
    }
    if (this.vncRememberPassword && !crypto.isSetupComplete()) {
      promptAction.showDialog({
        title: '确认保存未加密密码',
        message: '应用加密未启用。记住此密码会以未加密形式保存到 VNC 数据中；也可以关闭后仅本次使用。',
        buttons: [{ text: '取消', color: this.pal().text2 }, { text: '确认保存', color: this.pal().danger }]
      }).then((dialog: Object): void => {
        const values: Record<string, number> = dialog as Record<string, number>;
        if (values['index'] === 1) {
          this.finishVncAuthentication(this.vncPasswordInput, true, true);
        }
      });
      return;
    }
    this.finishVncAuthentication(this.vncPasswordInput, this.vncRememberPassword, false);
  }

  private useSavedVncPassword(): void {
    const host: VncHostView | null = this.pendingVncHost;
    if (host === null || this.vncPasswordStatus !== 'consent_required') { return; }
    if (!this.vncHosts.grantPlaintextPasswordConsent(host.id)) {
      this.vncPasswordError = '本地确认失败，请重新输入一次性密码。';
      return;
    }
    const loaded = this.vncHosts.passwordStateFor(host.id);
    if (loaded.state !== 'available') {
      this.vncPasswordError = '已保存密码不可用，请重新输入一次性密码。';
      return;
    }
    this.vncPasswordStatus = 'available';
    this.vncTransientPassword = '';
    this.vncAuthResolved = true;
    this.vncPasswordDismissReason = 'confirm';
    this.vncPasswordPendingStart = true;
    this.vncPasswordSheetClosing = true;
    this.showVncPasswordSheet = false;
    this.connectStarted = false;
    this.connecting = true;
  }

  private connectVncWithoutPassword(): void {
    this.finishVncAuthentication('', false, false);
  }

  private cancelVncPasswordChoice(): void {
    this.vncPasswordDismissReason = 'cancel';
    this.vncPasswordBackPending = true;
    this.vncPasswordPendingStart = false;
    this.vncPasswordSheetClosing = true;
    this.connectStarted = false;
    this.connecting = false;
    this.connectionError = '连接已取消';
    this.connectionErrorDetail = '未建立 VNC 会话';
    this.showVncPasswordSheet = false;
  }

  private handleVncPasswordSheetDismiss(action: DismissSheetAction): void {
    if (this.vncPasswordDismissReason === 'confirm' || this.vncPasswordDismissReason === 'cancel') {
      action.dismiss();
      return;
    }
    this.vncPasswordSheetClosing = true;
    this.cancelVncPasswordChoice();
    action.dismiss();
  }

  private handleVncPasswordSheetDisappear(): void {
    const reason: VncPasswordDismissReason = this.vncPasswordDismissReason;
    const shouldStart: boolean = reason === 'confirm' && this.vncPasswordPendingStart;
    this.vncPasswordDismissReason = 'none';
    this.vncPasswordPendingStart = false;
    this.vncPasswordSheetClosing = false;
    if (reason === 'none' || reason === 'cancel') { this.cancelVncPasswordChoice(); }
    if (this.vncPasswordBackPending) {
      this.vncPasswordBackPending = false;
      setTimeout((): void => { this.goBack(); }, 0);
      return;
    }
    if (shouldStart) { setTimeout((): void => { this.tryStartConnect(); }, 0); }
  }

  private persistRustDeskSessionAuth(host: RemoteHost): void {
    if (!this.isProRustDeskHost(host)) {
      return;
    }
    const existing = this.srv.getHost(host.id);
    if (!existing) {
      return;
    }
    const next = RemoteHost.fromJSON(existing.toJSON());
    next.rustdeskAuthMode = this.rustDeskSessionAuthChoice;
    next.rustdeskPasswordMode = this.rustDeskSessionPasswordMode;
    if (this.rustDeskSessionAuthChoice === 'password' &&
      this.rustDeskSessionRememberPassword && this.rustDeskSessionPassword.length > 0) {
      next.password = this.rustDeskSessionPassword;
    }
    if (this.srv.updateHost(next)) {
      hilog.info(RD_DOMAIN, RD_TAG, 'RustDesk Pro auth choice persisted host=' +
        host.id + ' mode=' + this.rustDeskSessionAuthChoice +
        ' passwordSaved=' + (this.rustDeskSessionAuthChoice === 'password' &&
          this.rustDeskSessionRememberPassword ? 'true' : 'false'));
    } else {
      hilog.warn(RD_DOMAIN, RD_TAG, 'RustDesk Pro auth choice persistence failed host=' + host.id);
    }
  }

  private shouldOfferRustDeskAuthRetry(detail: string): boolean {
    const value: string = detail.toLowerCase();
    const kind: RustDeskProNativeErrorKind = classifyRustDeskProNativeError(detail);
    return kind === 'device_password' || kind === 'approval_timeout' ||
      value.indexOf('wrong password') >= 0 ||
      value.indexOf('empty password') >= 0 ||
      value.indexOf('no password access') >= 0 ||
      value.indexOf('remote approval timed out') >= 0 ||
      value.indexOf('approval') >= 0;
  }

  private currentProtocolName(): string {
    const host: RemoteHost | null = this.pendingHost;
    return host === null ? '' : host.protocol;
  }

  private isVncSession(): boolean {
    return this.pendingHost !== null && this.pendingHost.protocol === 'vnc' &&
      this.pendingVncHost !== null;
  }

  private shouldShowActiveDiagnostics(): boolean {
    const protocol: string = this.currentProtocolName();
    const showDiagnostics: boolean = protocol === 'vnc' ? this.vncShowDiagnostics :
      this.rustdeskShowDiagnostics;
    return shouldShowSessionDiagnostics(showDiagnostics, this.connected, protocol, this.sessionId);
  }

  private shouldShowAdvancedDiagnostics(): boolean {
    return this.isRustDeskSession() && shouldEnableRustDeskPro(
      this.rustdeskShowDiagnostics, this.rustdeskShowProDiagnostics);
  }

  private transientRemoteHostForVnc(host: VncHostView): RemoteHost {
    const transient: RemoteHost = new RemoteHost();
    transient.id = 'vnc:' + host.id;
    transient.userId = host.userId;
    transient.label = host.label;
    transient.protocol = 'vnc';
    transient.host = host.host;
    transient.port = host.port;
    transient.username = host.username;
    transient.password = '';
    transient.sourceType = 'vnc';
    transient.locked = host.locked;
    transient.lockType = host.lockType;
    return transient;
  }

  private vncOwnerForConnection(host: VncHostView): VncSessionOwner {
    let gateway: VncGatewayView | null = null;
    if (host.gatewayId.trim() !== '') {
      gateway = this.vncGateways.find(host.gatewayId);
    }
    return { host, settings: this.vncSettings.get(), gateway };
  }

  /**
   * VNC clipboard policy is resolved only from the VNC owner.  Keeping this
   * branch separate is important: the shared RemoteDesktop component still
   * owns the bridge lifecycle, but VNC must never read the RDP/RustDesk
   * AppStorage preferences as a fallback.
   */
  private clipboardBridgeEnabledForSession(): boolean {
    const protocol: string = this.currentProtocolName();
    if (protocol === 'vnc') {
      return this.isVncSession() && this.pendingVncHost !== null && this.pendingVncHost.clipboardEnabled;
    }
    return clipboardSyncEnabledForProtocol(protocol,
      AppStorage.get<boolean>('rdpClipboardEnabled') ?? true,
      AppStorage.get<boolean>('rustdeskClipboardEnabled') ?? this.rustdeskClipboardEnabled);
  }

  private handleVncTrustRequired(host: VncHostView, detail: string): void {
    const marker: string = 'VNC_TRUST_REQUIRED:';
    const markerIndex: number = detail.indexOf(marker);
    if (markerIndex < 0) { return; }
    const fingerprint: string = detail.substring(markerIndex + marker.length).trim().toLowerCase();
    if (fingerprint.length < 32 || fingerprint.length > 128) { return; }
    promptAction.showDialog({
      title: '确认 VNC TLS 指纹',
      message: host.label + '\n\nSHA-256:\n' + fingerprint +
        '\n\n仅保存到 VNC trust；确认后将重新连接。',
      buttons: [
        { text: '取消', color: this.pal().text2 },
        { text: '确认并重连', color: this.accentColor }
      ]
    }).then((result: Object): void => {
      const values: Record<string, number> = result as Record<string, number>;
      if (values['index'] !== 1) {
        this.connectionError = 'VNC TLS trust 未确认';
        this.connectionErrorDetail = '未保存服务器证书指纹';
        return;
      }
      const saved = this.vncTrust.save(host.id, fingerprint);
      if (!saved.ok) {
        this.connectionError = 'VNC TLS trust 保存失败';
        this.connectionErrorDetail = saved.message;
        return;
      }
      this.connectionError = '';
      this.connectionErrorDetail = '';
      this.connectStarted = false;
      this.connecting = true;
      this.tryStartConnect();
    }).catch((_err: Error): void => {
      this.connectionError = 'VNC TLS trust 未确认';
      this.connectionErrorDetail = '证书指纹确认对话框未完成';
    });
  }

  private currentSessionCapabilities(): RemoteSessionCapabilities {
    const clipboardReady: boolean = this.sessionId > 0 && this.connected &&
      this.loader.isSessionClipboardReady(this.sessionId);
    return resolveSessionCapabilities({
      protocol: this.currentProtocolName(),
      connected: this.connected,
      rdpDriveMounted: this.rdpDriveMounted,
      rdpClipboardReady: clipboardReady,
      sftpConnected: false,
      rustDeskVerifiedPeer: this.connected && this.currentProtocolName() === 'rustdesk',
      rustDeskInboundClipboard: clipboardReady && this.currentProtocolName() === 'rustdesk',
      rustDeskTransferConfirmed: this.connected && this.currentProtocolName() === 'rustdesk',
      vncClipboardEnabled: this.isVncSession() &&
        this.pendingVncHost !== null && this.pendingVncHost.clipboardEnabled,
      vncClipboardReady: this.isVncSession() && clipboardReady,
      vncViewOnly: this.pendingVncHost === null || this.pendingVncHost.viewOnly
    });
  }

  private shouldShowTouchIndicator(): boolean {
    const cursorViewRevision: number = this.remoteCursorViewRevision;
    const style: RemoteCursorStyle = this.remoteCursorDisplayStyle();
    const configuredCircle: boolean = shouldRenderCircleCursor(style, this.remoteCursorReady,
      this.connected, this.isTouchpadControlMode());
    const fallbackCircle: boolean = shouldRenderRemoteCursorFallbackIndicator(
      this.remoteCursorFallbackShape, this.connected, this.isTouchpadControlMode(),
      this.remoteCursorReady);
    return (configuredCircle || fallbackCircle) && shouldRenderTouchPointerIndicator(true,
      shouldUseSystemMousePointer(this.isKeyboardMouseControlMode())) && cursorViewRevision >= 0;
  }

  private shouldShowArrowCursor(): boolean {
    const cursorViewRevision: number = this.remoteCursorViewRevision;
    return shouldRenderRemoteCursorArrow(this.remoteCursorDisplayStyle(), this.connected,
      this.isTouchpadControlMode(), this.remoteCursorReady, this.remoteCursorNativeVisible,
      this.remoteCursorPixelMap !== null, this.remoteCursorFallbackShape) && cursorViewRevision >= 0;
  }

  private arrowCursorPoint(): LocalPoint {
    return this.remoteToLocalPoint(this.remoteCursorX, this.remoteCursorY);
  }

  private arrowCursorInside(): boolean { return this.arrowCursorPoint().inside; }
  private arrowCursorLocalX(): number { return this.arrowCursorPoint().x; }
  private arrowCursorLocalY(): number { return this.arrowCursorPoint().y; }
  private remoteCursorLocalScale(): number {
    if (this.remoteCursorShapeWidth <= 0 || this.remoteCursorShapeHeight <= 0) { return 1; }
    if (this.remoteCursorFallbackShape) {
      return resolveRemoteCursorVisualScale(this.remoteCursorShapeWidth,
        this.remoteCursorShapeHeight, 1, true);
    }
    const transform: RemoteSurfaceTransform = this.currentRemoteSurfaceTransform();
    const origin = remotePointToSurface(transform, this.remoteCursorX, this.remoteCursorY);
    const edgeX = remotePointToSurface(transform,
      this.remoteCursorX + this.remoteCursorShapeWidth, this.remoteCursorY);
    const edgeY = remotePointToSurface(transform,
      this.remoteCursorX, this.remoteCursorY + this.remoteCursorShapeHeight);
    const scaleX: number = Math.abs(edgeX.x - origin.x) / this.remoteCursorShapeWidth;
    const scaleY: number = Math.abs(edgeY.y - origin.y) / this.remoteCursorShapeHeight;
    // A cursor bitmap is one image, so X/Y must share one scale.  Choosing
    // the smaller projection keeps the hotspot aligned without stretching.
    return resolveRemoteCursorVisualScale(this.remoteCursorShapeWidth,
      this.remoteCursorShapeHeight, Math.min(scaleX, scaleY), false);
  }
  private remoteCursorLocalScaleX(): number { return this.remoteCursorLocalScale(); }
  private remoteCursorLocalScaleY(): number { return this.remoteCursorLocalScale(); }
  private remoteCursorLocalWidth(): number {
    return this.remoteCursorShapeWidth * this.remoteCursorLocalScaleX();
  }
  private remoteCursorLocalHeight(): number {
    return this.remoteCursorShapeHeight * this.remoteCursorLocalScaleY();
  }
  private remoteCursorImageX(): number {
    return this.arrowCursorLocalX() - this.remoteCursorHotX * this.remoteCursorLocalScaleX();
  }
  private remoteCursorImageY(): number {
    return this.arrowCursorLocalY() - this.remoteCursorHotY * this.remoteCursorLocalScaleY();
  }
  private circleCursorLocalX(): number {
    return this.touchIndicatorVisible ? this.touchIndicatorX : this.arrowCursorLocalX();
  }
  private circleCursorLocalY(): number {
    return this.touchIndicatorVisible ? this.touchIndicatorY : this.arrowCursorLocalY();
  }

  /** Publish cursor-only state to the isolated overlay component. */
  private publishRemoteCursorOverlay(): void {
    const cursor: RemoteCursorOverlayState = this.remoteCursorOverlayState;
    const showCircle: boolean = this.shouldShowTouchIndicator();
    const showArrow: boolean = this.shouldShowArrowCursor();
    cursor.showCircle = showCircle;
    cursor.circleX = this.circleCursorLocalX();
    cursor.circleY = this.circleCursorLocalY();
    cursor.circleOuterSize = this.getTouchIndicatorOuterSize();
    cursor.circleRingSize = this.getTouchIndicatorRingSize();
    cursor.circleDotSize = this.getTouchIndicatorDotSize();
    cursor.circleColor = this.getTouchIndicatorColor();
    cursor.circleDrag = this.touchIndicatorButton === TOUCH_INDICATOR_BUTTON_DRAG;
    cursor.showArrow = showArrow;
    cursor.arrowInside = showArrow ? this.arrowCursorInside() : false;
    cursor.arrowPixelMap = showArrow ? this.remoteCursorPixelMap : null;
    cursor.arrowWidth = showArrow ? this.remoteCursorLocalWidth() : 0;
    cursor.arrowHeight = showArrow ? this.remoteCursorLocalHeight() : 0;
    cursor.arrowX = showArrow ? this.remoteCursorImageX() : 0;
    cursor.arrowY = showArrow ? this.remoteCursorImageY() : 0;
    cursor.viewRevision = this.remoteCursorViewRevision;
    // Publish the branch selector last. All geometry and PixelMap fields are
    // ready before the overlay is allowed to switch away from its old branch.
    cursor.renderMode = resolveRemoteCursorRenderMode(showCircle, showArrow);
  }

  private setRemoteSurfacePointerStyle(useSystemPointer: boolean, force: boolean = false): void {
    if (!force && this.remoteSurfaceUsesSystemPointer === useSystemPointer) {
      return;
    }
    try {
      const cursorController = this.getUIContext().getCursorController();
      if (useSystemPointer) {
        cursorController.setCursor(pointer.PointerStyle.DEFAULT);
      } else {
        cursorController.restoreDefault();
      }
      this.remoteSurfaceUsesSystemPointer = useSystemPointer;
    } catch (err) {
      hilog.warn(RD_DOMAIN, RD_TAG, 'remote pointer style update failed: ' + JSON.stringify(err));
    }
  }

  private setRemoteSystemPointerVisible(visible: boolean, reason: string,
    force: boolean = false): void {
    if (!force && this.remoteSystemPointerVisible === visible) {
      return;
    }
    try {
      pointer.setPointerVisibleSync(visible);
      this.remoteSystemPointerVisible = visible;
      hilog.info(RD_DOMAIN, RD_TAG, 'system pointer visible=' + (visible ? '1' : '0') +
        ' reason=' + reason);
    } catch (err) {
      hilog.warn(RD_DOMAIN, RD_TAG, 'system pointer visibility update failed reason=' + reason +
        ' err=' + JSON.stringify(err));
    }
  }

  private shouldHideSystemPointerForVirtualTouchpad(): boolean {
    return shouldHideSystemPointerForVirtualTouchpad(this.connected,
      this.isTouchpadControlMode(), this.isDesktopDevice);
  }

  private syncRemoteSystemPointer(reason: string, hovered: boolean = true,
    force: boolean = false): void {
    const hideSystemPointer: boolean = this.shouldHideSystemPointerForVirtualTouchpad();
    this.setRemoteSystemPointerVisible(!hideSystemPointer, reason, force);
    this.setRemoteSurfacePointerStyle(!hideSystemPointer && hovered &&
      shouldUseSystemMousePointer(this.isKeyboardMouseControlMode()), force);
  }

  private restoreRemoteSystemPointer(reason: string): void {
    // HarmonyOS may restore both visibility and the window cursor after a
    // page/window handoff. Force the restore so cached local state cannot
    // suppress the required native call.
    this.setRemoteSystemPointerVisible(true, reason, true);
    this.setRemoteSurfacePointerStyle(false, true);
  }

  private onRemoteConnectionStateChange(): void {
    if (this.connected) {
      this.syncRemoteSystemPointer('connection-state');
      this.startRustDeskDiagnosticsPolling();
    } else {
      this.restoreRemoteSystemPointer('connection-state');
      this.stopRustDeskDiagnosticsPolling(true);
    }
    this.publishRemoteCursorOverlay();
  }

  private onRemoteControlModeChange(): void {
    this.releaseCanvasPinchInput('control-mode-change');
    this.syncRemoteSystemPointer('control-mode');
    this.requestRemoteCursorViewRefresh(true);
  }

  private onRemoteAppTouchScaleSettingChange(): void {
    this.releaseCanvasPinchInput('remote-app-touch-scale-setting-change');
  }

  private handleRemoteSurfaceHover = (hovered: boolean): void => {
    const changed: boolean = this.remoteSurfaceHovered !== hovered;
    this.remoteSurfaceHovered = hovered;
    this.syncRemoteSystemPointer('surface-hover', hovered, changed);
  }

  private toastUnsupportedRustDeskAction(_actionId: string, reason: string): void {
    promptAction.showToast({ message: reason, duration: 2200 });
  }

  private persistSessionPref(key: string, value: string | number | boolean): void {
    AppStorage.setOrCreate(key, value);
    try {
      const prefs = preferences.getPreferencesSync(getContext(this), { name: 'RemoteDesktopAppPrefs' });
      prefs.putSync(key, value);
      prefs.flushSync();
    } catch (err) {
      hilog.warn(RD_DOMAIN, RD_TAG, 'persistSessionPref failed key=' + key + ': ' + JSON.stringify(err));
    }
  }

  /** Keep direct-to-session navigation on the same safe Fit migration as the settings page. */
  private restoreRemoteDisplayScalePreference(): void {
    try {
      const prefs = preferences.getPreferencesSync(getContext(this), { name: 'RemoteDesktopAppPrefs' });
      const storedMode: string = prefs.getSync('remoteDisplayScaleMode', '') as string;
      const storedVersion: number =
        prefs.getSync(REMOTE_DISPLAY_SCALE_PREFERENCE_VERSION_KEY, 0) as number;
      this.remoteDisplayScaleMode = resolveInitialRemoteDisplayScaleMode(storedMode, storedVersion);
      AppStorage.setOrCreate('remoteDisplayScaleMode', this.remoteDisplayScaleMode);
      if (!Number.isFinite(storedVersion) || storedVersion < REMOTE_DISPLAY_SCALE_PREFERENCE_VERSION) {
        prefs.putSync('remoteDisplayScaleMode', this.remoteDisplayScaleMode);
        prefs.putSync(REMOTE_DISPLAY_SCALE_PREFERENCE_VERSION_KEY,
          REMOTE_DISPLAY_SCALE_PREFERENCE_VERSION);
        prefs.flushSync();
      }
    } catch (err) {
      this.remoteDisplayScaleMode = 'fit';
      AppStorage.setOrCreate('remoteDisplayScaleMode', this.remoteDisplayScaleMode);
      hilog.warn(RD_DOMAIN, RD_TAG,
        'restoreRemoteDisplayScalePreference fallback to fit: ' + JSON.stringify(err));
    }
  }

  private setRustDeskPrivacyMode(on: boolean): void {
    this.rustdeskPrivacyMode = on;
    this.persistSessionPref('rustdeskPrivacyMode', on);
    promptAction.showToast({
      message: on ? '隐私模式将在下次连接时请求启用' : '隐私模式将在下次连接时关闭',
      duration: 1800
    });
  }

  private setRustDeskAudioEnabled(on: boolean): void {
    this.rustdeskAudioEnabled = on;
    this.persistSessionPref('rustdeskAudioEnabled', on);
    promptAction.showToast({
      message: on ? '远端音频已启用' : '远端音频将在下次连接时静音',
      duration: 1800
    });
  }

  private setRustDeskClipboardEnabled(on: boolean): void {
    this.rustdeskClipboardEnabled = on;
    this.persistSessionPref('rustdeskClipboardEnabled', on);
    promptAction.showToast({ message: on ? 'RustDesk 剪贴板已允许' : 'RustDesk 剪贴板已禁用', duration: 1600 });
  }

  private setRustDeskFilePasteEnabled(on: boolean): void {
    this.rustdeskFilePasteEnabled = on;
    this.persistSessionPref('rustdeskFilePasteEnabled', on);
    promptAction.showToast({ message: on ? 'RustDesk 文件粘贴已允许' : 'RustDesk 文件粘贴已禁用', duration: 1600 });
  }

  private setRemoteDisplayScaleMode(mode: string): void {
    const next: LocalViewScaleMode = normalizeLocalViewScaleMode(mode);
    this.remoteDisplayScaleMode = next;
    this.persistSessionPref('remoteDisplayScaleMode', next);
    this.persistSessionPref(REMOTE_DISPLAY_SCALE_PREFERENCE_VERSION_KEY,
      REMOTE_DISPLAY_SCALE_PREFERENCE_VERSION);
    this.rustdeskViewScaleMode = next === '100' ? 'original' : next === 'custom' ? 'custom' : 'fit';
    this.persistSessionPref('rustdeskViewScaleMode', this.rustdeskViewScaleMode);
    this.resetCanvasToDisplayDefault();
    promptAction.showToast({ message: '显示缩放已切换为 ' +
      (next === 'fit' ? '适应窗口' : (next === 'custom' ? '自定义' : next + '%')), duration: 1400 });
  }

  private resetCanvasTransformFromMenu(): void {
    this.resetCanvasToDisplayDefault();
    promptAction.showToast({ message: '画面已重新居中', duration: 1200 });
  }

  private openRustDeskDisplayResolutionMenu(): void {
    if (!this.isRustDeskSession() || this.sessionId <= 0) {
      return;
    }
    const capabilities: RustDeskDisplayCapabilities =
      this.loader.getRustDeskDisplayCapabilities(this.sessionId);
    if (!capabilities.supported) {
      promptAction.showToast({ message: '远端尚未提供显示分辨率能力', duration: 1800 });
      return;
    }
    if (capabilities.resolutions.length === 0 && capabilities.displays.length === 0) {
      promptAction.showToast({ message: '远端尚未提供显示器能力', duration: 1800 });
      return;
    }
    this.rustDeskDisplayCapabilities = capabilities;
    this.showRustDeskDisplayResolutionMenu = true;
  }

  private changeRustDeskDisplayResolution(width: number, height: number): void {
    const capabilities: RustDeskDisplayCapabilities = this.rustDeskDisplayCapabilities;
    if (!this.loader.changeRustDeskDisplayResolution(this.sessionId, capabilities.currentDisplay,
      width, height)) {
      promptAction.showToast({ message: '分辨率请求未被远端会话接受', duration: 1800 });
      return;
    }
    this.showRustDeskDisplayResolutionMenu = false;
    promptAction.showToast({ message: '已请求远端切换为 ' + width.toString() + ' × ' + height.toString(), duration: 1800 });
  }

  private rustDeskDisplayLabel(display: RustDeskDisplayInfo): string {
    return display.name.trim().length > 0 ? display.name : '显示器 ' + (display.display + 1).toString();
  }

  private rustDeskDisplayById(displayId: number,
    displays: RustDeskDisplayInfo[] = this.rustDeskDisplayCapabilities.displays): RustDeskDisplayInfo | null {
    for (const display of displays) {
      if (display.display === displayId) {
        return display;
      }
    }
    return null;
  }

  private resetRustDeskInputAfterGeometryChange(reason: string): void {
    this.releaseCanvasPinchInput(reason);
    this.touchpadAnchorValid = false;
    this.resetTouchpadPointerCurve();
    this.invalidateRendererViewportCache();
  }

  private applyRustDeskDisplayGeometry(display: RustDeskDisplayInfo): void {
    const width: number = display.width > 0 ? display.width : display.originalWidth;
    const height: number = display.height > 0 ? display.height : display.originalHeight;
    if (width <= 0 || height <= 0) {
      return;
    }
    this.updateRemoteSize({
      width,
      height,
      colorDepth: 32,
      multiMonitor: false,
      monitorCount: 1
    });
    RemoteSessionPipService.getInstance().updateContentSize(width, height);
    if (!this.canvasTransformGestureModified) {
      this.resetCanvasToDisplayDefault(true);
    }
    this.requestRemoteCursorViewRefresh(true);
  }

  private selectRustDeskDisplay(display: RustDeskDisplayInfo): void {
    if (!this.isRustDeskSession() || this.sessionId <= 0 || !display.online) {
      return;
    }
    if (display.display === this.rustDeskDisplayCapabilities.currentDisplay) {
      return;
    }
    this.resetRustDeskInputAfterGeometryChange('rustdesk-display-switch');
    if (!this.loader.switchRustDeskDisplay(this.sessionId, display.display)) {
      promptAction.showToast({ message: '远端显示器切换请求未被接受', duration: 1800 });
      return;
    }

    const capabilities: RustDeskDisplayCapabilities = this.rustDeskDisplayCapabilities;
    this.rustDeskDisplaySwitchPending = display.display;
    this.rustDeskDisplaySwitchStartedAtMs = Date.now();
    this.rustDeskDisplayCapabilities = {
      supported: capabilities.supported,
      currentDisplay: display.display,
      width: display.width,
      height: display.height,
      originalWidth: display.originalWidth,
      originalHeight: display.originalHeight,
      scaleMilli: display.scaleMilli,
      geometryEpoch: capabilities.geometryEpoch,
      resolutions: display.resolutions,
      displays: capabilities.displays
    };
    this.applyRustDeskDisplayGeometry(display);
    promptAction.showToast({
      message: '已切换到 ' + this.rustDeskDisplayLabel(display),
      duration: 1400
    });
  }

  private syncRustDeskDisplayCatalog(): void {
    if (!this.isRustDeskSession() || this.sessionId <= 0) {
      return;
    }
    const capabilities: RustDeskDisplayCapabilities =
      this.loader.getRustDeskDisplayCapabilities(this.sessionId);
    if (!capabilities.supported || capabilities.displays.length === 0) {
      return;
    }
    if (this.rustDeskDisplaySwitchPending >= 0 &&
      capabilities.currentDisplay !== this.rustDeskDisplaySwitchPending) {
      if (Date.now() - this.rustDeskDisplaySwitchStartedAtMs < 5000) {
        return;
      }
      this.rustDeskDisplaySwitchPending = -1;
    }
    if (capabilities.currentDisplay === this.rustDeskDisplaySwitchPending) {
      this.rustDeskDisplaySwitchPending = -1;
    }
    const previous: RustDeskDisplayCapabilities = this.rustDeskDisplayCapabilities;
    const epochChanged: boolean = this.rustDeskGeometryEpoch > 0 && capabilities.geometryEpoch > 0 &&
      this.rustDeskGeometryEpoch !== capabilities.geometryEpoch;
    const currentChanged: boolean = previous.currentDisplay !== capabilities.currentDisplay ||
      previous.width !== capabilities.width || previous.height !== capabilities.height ||
      previous.geometryEpoch !== capabilities.geometryEpoch || epochChanged;
    if (currentChanged && previous.width > 0 && previous.height > 0) {
      this.resetRustDeskInputAfterGeometryChange('rustdesk-geometry-epoch');
    }
    this.rustDeskDisplayCapabilities = capabilities;
    this.rustDeskGeometryEpoch = capabilities.geometryEpoch;
    if (currentChanged) {
      const current = this.rustDeskDisplayById(capabilities.currentDisplay, capabilities.displays);
      if (current !== null) {
        this.applyRustDeskDisplayGeometry(current);
      }
    }
  }

  private isRustDeskDisplayResolutionSelected(resolution: RustDeskDisplayResolution): boolean {
    return resolution.width === this.rustDeskDisplayCapabilities.width &&
      resolution.height === this.rustDeskDisplayCapabilities.height;
  }

  private refreshCanvasViewportSnapshot(forceRendererRead: boolean = false): CanvasViewport {
    let sourceWidth: number = this.rendererSourceWidth > 0 ? this.rendererSourceWidth : this.remoteWidth;
    let sourceHeight: number = this.rendererSourceHeight > 0 ? this.rendererSourceHeight : this.remoteHeight;
    if (forceRendererRead) {
      const viewport: RendererViewportSnapshot | null = this.readRendererViewport(true);
      if (viewport !== null && viewport.sourceWidth > 0 && viewport.sourceHeight > 0) {
        sourceWidth = viewport.sourceWidth;
        sourceHeight = viewport.sourceHeight;
      }
    }
    const snapshot: CanvasViewport = {
      surfaceWidth: this.renderWidthPx > 0 ? this.renderWidthPx : this.vpToPx(this.surfaceWidth),
      surfaceHeight: this.renderHeightPx > 0 ? this.renderHeightPx : this.vpToPx(this.surfaceHeight),
      sourceWidth: Math.max(1, sourceWidth),
      sourceHeight: Math.max(1, sourceHeight)
    };
    this.canvasViewportSnapshot = snapshot;
    this.canvasViewportSnapshotHandle = this.rendererHandle;
    return snapshot;
  }

  private currentCanvasViewport(forceRendererRead: boolean = false): CanvasViewport {
    if (!forceRendererRead && this.canvasViewportSnapshot !== null &&
      this.canvasViewportSnapshotHandle === this.rendererHandle) {
      return this.canvasViewportSnapshot;
    }
    return this.refreshCanvasViewportSnapshot(forceRendererRead);
  }

  private resetCanvasToDisplayDefault(forceRendererRead: boolean = false): void {
    const mode: LocalViewScaleMode = normalizeLocalViewScaleMode(this.remoteDisplayScaleMode);
    this.canvasTransform = baseCanvasTransform(mode, this.remoteDisplayCustomScalePercent,
      this.currentCanvasViewport(forceRendererRead));
    this.canvasTransformInitialized = true;
    this.canvasTransformGestureModified = false;
    this.applyCanvasTransform();
  }

  private applyCanvasTransform(): void {
    if (this.rendererHandle <= 0) {
      return;
    }
    const viewport: CanvasViewport = this.currentCanvasViewport();
    this.canvasTransform = clampCanvasTransform(this.canvasTransform, viewport);
    const submittedVersion: number = this.loader.setRendererCanvasTransform(this.rendererHandle,
      this.canvasTransform.scale,
      this.canvasTransform.panX, this.canvasTransform.panY);
    if (Number.isFinite(submittedVersion) && submittedVersion > 0) {
      this.rendererCanvasTransformPendingVersion = submittedVersion;
    }
    // Keep coordinate mapping responsive while native redraw catches up. The
    // calculation mirrors GLRenderer::CalculateViewport and avoids a NAPI
    // read on every pinch update.
    this.updateRendererViewportCacheForCanvasTransform(viewport);
  }

  private shouldUseRustDeskRemoteAppTouchScale(): boolean {
    return this.rustdeskRemoteAppTouchScaleEnabled && this.isRustDeskSession() &&
      this.connected && this.sessionId > 0;
  }

  private gestureCenterPoint(event: GestureEvent): LocalPoint | null {
    if (event.fingerList.length <= 0) {
      return null;
    }
    let sumX: number = 0;
    let sumY: number = 0;
    for (let index = 0; index < event.fingerList.length; index++) {
      sumX += event.fingerList[index].localX;
      sumY += event.fingerList[index].localY;
    }
    return {
      x: sumX / event.fingerList.length,
      y: sumY / event.fingerList.length,
      inside: true
    };
  }

  private startRustDeskRemoteAppTouchScale(event: GestureEvent): boolean {
    if (!this.shouldUseRustDeskRemoteAppTouchScale() || !this.canForwardInput('rustdesk-touch-scale')) {
      return false;
    }
    if (this.rustDeskTouchPinchActive) {
      // A parallel two-finger Pan may be recognized before Pinch. Reuse its
      // remote TouchPan stream instead of enqueueing a second start message.
      const transform: RemoteSurfaceTransform | null = this.rustDeskTouchPinchTransformSnapshot;
      const center: LocalPoint | null = this.gestureCenterPoint(event);
      if (transform === null || center === null) {
        return false;
      }
      const mapped: MappedPoint = this.mapInputPointWithTransform(center.x, center.y, transform);
      this.rustDeskTouchPanOnly = false;
      this.rustDeskTouchPinchLastScale = 1;
      this.rustDeskTouchPinchLastRemoteX = mapped.x;
      this.rustDeskTouchPinchLastRemoteY = mapped.y;
      return true;
    }
    const transform: RemoteSurfaceTransform = this.currentRemoteSurfaceTransform();
    const mapped: MappedPoint = this.mapInputPointWithTransform(
      event.pinchCenterX, event.pinchCenterY, transform);
    if (!this.loader.sendRustDeskTouchPan(this.sessionId, 0, mapped.x, mapped.y)) {
      hilog.warn(RD_DOMAIN, RD_TAG, 'rustdesk-touch-scale start rejected by native bridge');
      return false;
    }
    this.rustDeskTouchPinchActive = true;
    this.rustDeskTouchPinchLastScale = 1;
    this.rustDeskTouchPinchLastRemoteX = mapped.x;
    this.rustDeskTouchPinchLastRemoteY = mapped.y;
    this.rustDeskTouchPanOnly = false;
    this.rustDeskTouchPinchTransformSnapshot = transform;
    return true;
  }

  private startRustDeskRemoteAppTouchPan(event: GestureEvent): boolean {
    if (!this.shouldUseRustDeskRemoteAppTouchScale() || !this.canForwardInput('rustdesk-touch-pan')) {
      return false;
    }
    if (this.rustDeskTouchPinchActive) {
      return true;
    }
    const center: LocalPoint | null = this.gestureCenterPoint(event);
    if (center === null) {
      return false;
    }
    const transform: RemoteSurfaceTransform = this.currentRemoteSurfaceTransform();
    const mapped: MappedPoint = this.mapInputPointWithTransform(center.x, center.y, transform);
    if (!this.loader.sendRustDeskTouchPan(this.sessionId, 0, mapped.x, mapped.y)) {
      hilog.warn(RD_DOMAIN, RD_TAG, 'rustdesk-touch-pan start rejected by native bridge');
      return false;
    }
    this.rustDeskTouchPinchActive = true;
    this.rustDeskTouchPanOnly = true;
    this.rustDeskTouchPinchLastScale = 1;
    this.rustDeskTouchPinchLastRemoteX = mapped.x;
    this.rustDeskTouchPinchLastRemoteY = mapped.y;
    this.rustDeskTouchPinchTransformSnapshot = transform;
    return true;
  }

  private updateRustDeskRemoteAppTouchScale(event: GestureEvent): void {
    if (!this.rustDeskTouchPinchActive || !this.shouldUseRustDeskRemoteAppTouchScale()) {
      return;
    }
    const nextScale: number = Number.isFinite(event.scale) && event.scale > 0 ?
      event.scale : this.rustDeskTouchPinchLastScale;
    const transform: RemoteSurfaceTransform | null = this.rustDeskTouchPinchTransformSnapshot;
    if (transform === null) {
      this.releaseCanvasPinchInput('rustdesk-touch-scale-missing-transform');
      return;
    }
    const scaleDelta: number = rustDeskTouchScaleDelta(
      this.rustDeskTouchPinchLastScale, nextScale);
    if (scaleDelta !== 0 &&
      !this.loader.sendRustDeskTouchScale(this.sessionId, scaleDelta)) {
      this.releaseCanvasPinchInput('rustdesk-touch-scale-rejected');
      return;
    }
    const mapped: MappedPoint = this.mapInputPointWithTransform(
      event.pinchCenterX, event.pinchCenterY, transform);
    const deltaX: number = mapped.x - this.rustDeskTouchPinchLastRemoteX;
    const deltaY: number = mapped.y - this.rustDeskTouchPinchLastRemoteY;
    if (deltaX !== 0 || deltaY !== 0) {
      if (!this.loader.sendRustDeskTouchPan(this.sessionId, 1, deltaX, deltaY)) {
        this.releaseCanvasPinchInput('rustdesk-touch-pan-rejected');
        return;
      }
      this.rustDeskTouchPinchLastRemoteX = mapped.x;
      this.rustDeskTouchPinchLastRemoteY = mapped.y;
    }
    this.rustDeskTouchPinchLastScale = nextScale;
  }

  private updateRustDeskRemoteAppTouchPan(event: GestureEvent): void {
    if (!this.rustDeskTouchPinchActive || !this.rustDeskTouchPanOnly ||
      !this.shouldUseRustDeskRemoteAppTouchScale()) {
      return;
    }
    const transform: RemoteSurfaceTransform | null = this.rustDeskTouchPinchTransformSnapshot;
    const center: LocalPoint | null = this.gestureCenterPoint(event);
    if (transform === null || center === null) {
      this.releaseCanvasPinchInput('rustdesk-touch-pan-missing-transform');
      return;
    }
    const mapped: MappedPoint = this.mapInputPointWithTransform(center.x, center.y, transform);
    const deltaX: number = mapped.x - this.rustDeskTouchPinchLastRemoteX;
    const deltaY: number = mapped.y - this.rustDeskTouchPinchLastRemoteY;
    if (deltaX !== 0 || deltaY !== 0) {
      if (!this.loader.sendRustDeskTouchPan(this.sessionId, 1, deltaX, deltaY)) {
        this.releaseCanvasPinchInput('rustdesk-touch-pan-rejected');
        return;
      }
      this.rustDeskTouchPinchLastRemoteX = mapped.x;
      this.rustDeskTouchPinchLastRemoteY = mapped.y;
    }
  }

  private finishRustDeskRemoteAppTouchScale(): void {
    if (!this.rustDeskTouchPinchActive) {
      return;
    }
    if (this.sessionId > 0 && this.isRustDeskSession()) {
      if (!this.rustDeskTouchPanOnly) {
        this.loader.sendRustDeskTouchScale(this.sessionId, 0);
      }
      this.loader.sendRustDeskTouchPan(this.sessionId, 2,
        this.rustDeskTouchPinchLastRemoteX, this.rustDeskTouchPinchLastRemoteY);
    }
    this.rustDeskTouchPinchActive = false;
    this.rustDeskTouchPanOnly = false;
    this.rustDeskTouchPinchLastScale = 1;
    this.rustDeskTouchPinchTransformSnapshot = null;
  }

  private clearCanvasTwoFingerHoldTimer(): void {
    if (this.canvasTwoFingerHoldTimer >= 0) {
      clearTimeout(this.canvasTwoFingerHoldTimer);
      this.canvasTwoFingerHoldTimer = -1;
    }
  }

  private resetCanvasTwoFingerGesture(): void {
    this.clearCanvasTwoFingerHoldTimer();
    this.canvasTwoFingerState = idleCanvasTwoFingerState();
  }

  private canUseCanvasTwoFingerGesture(): boolean {
    return !this.isKeyboardMouseControlMode() &&
      (this.canvasGestureZoomEnabled || this.shouldUseRustDeskRemoteAppTouchScale());
  }

  private canPanCanvasForTwoFingerGesture(): boolean {
    if (!this.canUseCanvasTwoFingerGesture()) {
      return false;
    }
    if (this.shouldUseRustDeskRemoteAppTouchScale()) {
      // Remote-app touch pan is consumed by RustDesk, so it does not depend
      // on the local renderer's overflow state.
      return true;
    }
    if (!this.canvasGestureZoomEnabled) {
      return false;
    }
    if (!this.canvasTransformInitialized) {
      this.resetCanvasToDisplayDefault();
    }
    return canvasTransformCanPan(this.canvasTransform, this.currentCanvasViewport());
  }

  private beginCanvasTwoFingerCandidateAt(point: LocalPoint, holdAlreadySatisfied: boolean = false): void {
    this.clearCanvasTwoFingerHoldTimer();
    this.canvasTwoFingerSequence++;
    const sequenceId: number = this.canvasTwoFingerSequence;
    const remoteAppTarget: boolean = this.shouldUseRustDeskRemoteAppTouchScale();
    const zoomEnabled: boolean = this.canvasGestureZoomEnabled || remoteAppTarget;
    const nowMs: number = Date.now();
    this.canvasTwoFingerState = beginCanvasTwoFingerCandidate(sequenceId, point.x, point.y,
      holdAlreadySatisfied ? nowMs - CANVAS_TWO_FINGER_HOLD_MS : nowMs,
      zoomEnabled, this.canPanCanvasForTwoFingerGesture());
    if (holdAlreadySatisfied) {
      this.canvasTwoFingerState = expireCanvasTwoFingerHold(this.canvasTwoFingerState, nowMs);
      return;
    }
    if (!this.canvasTwoFingerState.holdTimerPending) {
      return;
    }
    this.canvasTwoFingerHoldTimer = setTimeout((): void => {
      this.canvasTwoFingerHoldTimer = -1;
      if (this.canvasTwoFingerState.sequenceId !== sequenceId ||
        this.canvasTwoFingerState.owner !== 'candidate') {
        return;
      }
      this.canvasTwoFingerState = expireCanvasTwoFingerHold(this.canvasTwoFingerState, Date.now());
    }, CANVAS_TWO_FINGER_HOLD_MS);
  }

  /**
   * API 23 can route an XComponent stream directly to native code. Keep a
   * real two-finger LongPress recognizer on the transparent ArkUI owner so a
   * held canvas pan still works when the raw TouchEvent timer is unavailable.
   */
  private armCanvasTwoFingerPanFromLongPress(event: GestureEvent): void {
    if (!this.canUseCanvasTwoFingerGesture() || !this.canPanCanvasForTwoFingerGesture()) {
      return;
    }
    if (this.canvasTwoFingerState.owner === 'idle') {
      const point: LocalPoint | null = this.gestureCenterPoint(event);
      if (point === null) {
        return;
      }
      this.beginCanvasTwoFingerCandidateAt(point, true);
      return;
    }
    if (this.canvasTwoFingerState.owner === 'candidate') {
      this.canvasTwoFingerState = expireCanvasTwoFingerHold(this.canvasTwoFingerState, Date.now());
      if (!this.canvasTwoFingerState.holdTimerPending) {
        this.clearCanvasTwoFingerHoldTimer();
      }
    }
  }

  /**
   * Observe the raw XComponent stream before the per-mode input handler. The
   * same owner is then visible to the ArkUI recognizers and to touchpad/RDP
   * forwarding, which prevents a vertical two-finger scroll from becoming a
   * local canvas pan halfway through one sequence.
   */
  private observeCanvasTwoFingerTouch(event: TouchEvent): void {
    if (event.sourceTool !== SourceTool.Finger) {
      return;
    }
    const activeCount: number = this.trackedCanvasTouchCount(event);
    if (event.type === TouchType.Down && activeCount >= 2 && this.touchFingerCount < 2) {
      const point: LocalPoint | null = this.averageTouchPoint(event) || this.primaryTouchPoint(event);
      if (point !== null) {
        this.beginCanvasTwoFingerCandidateAt(point);
      }
      return;
    }
    if (event.type === TouchType.Move && activeCount >= 2) {
      if (this.canvasTwoFingerState.owner === 'idle') {
        const point: LocalPoint | null = this.averageTouchPoint(event) || this.primaryTouchPoint(event);
        if (point !== null) {
          this.beginCanvasTwoFingerCandidateAt(point);
        }
      }
      const point: LocalPoint | null = this.averageTouchPoint(event) || this.primaryTouchPoint(event);
      if (point === null || this.canvasTwoFingerState.owner === 'idle') {
        return;
      }
      const nowMs: number = Date.now();
      const heldState: CanvasTwoFingerState = expireCanvasTwoFingerHold(
        this.canvasTwoFingerState, nowMs);
      const result = advanceCanvasTwoFingerMove(heldState, point.x, point.y, nowMs);
      this.canvasTwoFingerState = result.state;
      if (!this.canvasTwoFingerState.holdTimerPending) {
        this.clearCanvasTwoFingerHoldTimer();
      }
      return;
    }
    if (event.type === TouchType.Cancel) {
      this.resetCanvasTwoFingerGesture();
    }
  }

  private finishCanvasTwoFingerCandidateForRelease(wasMoved: boolean): void {
    if (this.canvasTwoFingerState.owner !== 'candidate' &&
      this.canvasTwoFingerState.owner !== 'canvas-pan-armed') {
      return;
    }
    this.canvasTwoFingerState = finishCanvasTwoFingerCandidate(
      this.canvasTwoFingerState, wasMoved);
    this.clearCanvasTwoFingerHoldTimer();
  }

  private startCanvasPanFromPoint(point: LocalPoint): boolean {
    if (this.canvasTwoFingerState.owner !== 'canvas-pan' ||
      this.shouldUseRustDeskRemoteAppTouchScale() || !this.canvasGestureZoomEnabled) {
      return false;
    }
    if (!this.canvasTransformInitialized) {
      this.resetCanvasToDisplayDefault();
    }
    const viewport: CanvasViewport = this.currentCanvasViewport();
    if (!canvasTransformCanPan(this.canvasTransform, viewport)) {
      return false;
    }
    this.captureCanvasGestureDensity(viewport);
    this.canvasPanActive = true;
    this.canvasPanInputSource = 'touch';
    this.canvasPanLastOffsetX = point.x;
    this.canvasPanLastOffsetY = point.y;
    if (!this.canvasPinchActive) {
      this.canvasPinchViewportSnapshot = viewport;
    }
    this.claimCanvasPinchInput();
    return true;
  }

  private updateCanvasPanFromPoint(x: number, y: number): void {
    if (!this.canvasPanActive || this.canvasPanInputSource !== 'touch' || this.rustDeskTouchPinchActive ||
      this.canvasTwoFingerState.owner !== 'canvas-pan') {
      return;
    }
    const viewport: CanvasViewport | null = this.canvasPinchViewportSnapshot;
    if (viewport === null) {
      this.releaseCanvasPinchInput('canvas-pan-missing-viewport');
      return;
    }
    const deltaX: number = this.canvasGestureVpToPx(x - this.canvasPanLastOffsetX);
    const deltaY: number = this.canvasGestureVpToPx(y - this.canvasPanLastOffsetY);
    this.canvasPanLastOffsetX = x;
    this.canvasPanLastOffsetY = y;
    if (deltaX === 0 && deltaY === 0) {
      return;
    }
    this.canvasTransform = panCanvasTransform(this.canvasTransform, viewport, deltaX, deltaY);
    this.canvasTransformGestureModified = true;
    this.applyCanvasTransform();
  }

  private startCanvasPinch(event: GestureEvent): void {
    if (!this.canUseCanvasTwoFingerGesture()) {
      return;
    }
    if (this.canvasTwoFingerState.owner === 'idle') {
      const center: LocalPoint | null = this.gestureCenterPoint(event);
      if (center !== null) {
        this.beginCanvasTwoFingerCandidateAt(center);
      }
    }
    const remoteAppTarget: boolean = this.shouldUseRustDeskRemoteAppTouchScale();
    const claimed = claimCanvasTwoFingerPinch(this.canvasTwoFingerState, remoteAppTarget);
    if (claimed.owner === this.canvasTwoFingerState.owner &&
      (claimed.owner === 'touchpad-scroll' || claimed.owner === 'touchpad-right-click' ||
        claimed.owner === 'canvas-pan-armed' || claimed.owner === 'canvas-pan' ||
        claimed.owner === 'remote-touch-pan' ||
        claimed.owner === 'canvas-pinch' || claimed.owner === 'remote-touch-scale')) {
      return;
    }
    this.canvasTwoFingerState = claimed;
    this.clearCanvasTwoFingerHoldTimer();
    if (remoteAppTarget) {
      if (this.startRustDeskRemoteAppTouchScale(event)) {
        this.claimCanvasPinchInput();
      } else {
        this.resetCanvasTwoFingerGesture();
      }
      return;
    }
    if (!this.canvasGestureZoomEnabled || this.canvasTwoFingerState.owner !== 'canvas-pinch') {
      return;
    }
    if (!this.canvasTransformInitialized) {
      this.resetCanvasToDisplayDefault();
    }
    const viewport: CanvasViewport = this.currentCanvasViewport();
    this.canvasPinchViewportSnapshot = viewport;
    this.captureCanvasGestureDensity(viewport);
    this.canvasPinchActive = true;
    this.canvasPinchLastScale = 1;
    this.canvasPinchLastCenterX = this.canvasGestureVpToPx(event.pinchCenterX);
    this.canvasPinchLastCenterY = this.canvasGestureVpToPx(event.pinchCenterY);
    this.claimCanvasPinchInput();
  }

  /** Two-finger pure translation is a local canvas gesture when content overflows. */
  private startCanvasPan(event: GestureEvent): void {
    if (!this.canUseCanvasTwoFingerGesture() ||
      this.canvasPanActive ||
      this.canvasTwoFingerState.owner === 'candidate' ||
      this.canvasTwoFingerState.owner === 'touchpad-scroll' ||
      this.canvasTwoFingerState.owner === 'touchpad-right-click') {
      return;
    }
    if (this.canvasTwoFingerState.owner === 'canvas-pan-armed') {
      const remoteAppTarget: boolean = this.shouldUseRustDeskRemoteAppTouchScale();
      this.canvasTwoFingerState = claimCanvasTwoFingerPan(this.canvasTwoFingerState, remoteAppTarget);
      this.clearCanvasTwoFingerHoldTimer();
    }
    if (this.shouldUseRustDeskRemoteAppTouchScale()) {
      if (this.canvasTwoFingerState.owner !== 'remote-touch-pan') {
        return;
      }
      if (this.startRustDeskRemoteAppTouchPan(event)) {
        this.canvasPanActive = true;
        this.canvasPanInputSource = 'gesture';
        this.claimCanvasPinchInput();
      } else {
        this.resetCanvasTwoFingerGesture();
      }
      return;
    }
    if (this.canvasTwoFingerState.owner !== 'canvas-pan') {
      return;
    }
    if (!this.canvasTransformInitialized) {
      this.resetCanvasToDisplayDefault();
    }
    const viewport: CanvasViewport = this.currentCanvasViewport();
    if (!canvasTransformCanPan(this.canvasTransform, viewport)) {
      return;
    }
    this.captureCanvasGestureDensity(viewport);
    this.canvasPanActive = true;
    this.canvasPanInputSource = 'gesture';
    this.canvasPanLastOffsetX = Number.isFinite(event.offsetX) ? event.offsetX : 0;
    this.canvasPanLastOffsetY = Number.isFinite(event.offsetY) ? event.offsetY : 0;
    if (!this.canvasPinchActive) {
      this.canvasPinchViewportSnapshot = viewport;
    }
    this.claimCanvasPinchInput();
  }

  private updateCanvasPan(event: GestureEvent): void {
    // PanGesture may recognize before the 400 ms hold and will not call
    // onActionStart again. Re-evaluate the shared owner on every update so
    // the first post-hold update can activate the canvas pan path.
    if (!this.canvasPanActive &&
      (this.canvasTwoFingerState.owner === 'canvas-pan-armed' ||
        this.canvasTwoFingerState.owner === 'canvas-pan' ||
        this.canvasTwoFingerState.owner === 'remote-touch-pan')) {
      this.startCanvasPan(event);
    }
    if (!this.canvasPanActive || this.canvasPanInputSource !== 'gesture' ||
      !shouldApplyCanvasTwoFingerPan(this.canvasTwoFingerState)) {
      return;
    }
    if (this.rustDeskTouchPinchActive) {
      this.updateRustDeskRemoteAppTouchPan(event);
      return;
    }
    if (this.canvasPinchActive || !this.canvasGestureZoomEnabled) {
      return;
    }
    const offsetX: number = Number.isFinite(event.offsetX) ? event.offsetX : this.canvasPanLastOffsetX;
    const offsetY: number = Number.isFinite(event.offsetY) ? event.offsetY : this.canvasPanLastOffsetY;
    this.updateCanvasPanFromPoint(offsetX, offsetY);
  }

  private finishCanvasPan(): void {
    this.canvasPanActive = false;
    this.canvasPanInputSource = 'none';
    this.canvasPanLastOffsetX = 0;
    this.canvasPanLastOffsetY = 0;
    if (!this.canvasPinchActive) {
      this.canvasGesturePxPerVp = 1;
    }
  }

  private endCanvasPinchGesture(reason: string): void {
    if (!this.canvasPinchActive) {
      return;
    }
    // With a parallel two-finger recognizer, one recognizer can finish before
    // the other. Keep the shared ownership and viewport until both are done.
    const next = endCanvasPinchOwnership({
      pinchActive: this.canvasPinchActive,
      panActive: this.canvasPanActive
    });
    this.canvasPinchActive = next.pinchActive;
    this.canvasPinchLastScale = 1;
    if (shouldReleaseCanvasGestureOwnership(next)) {
      this.releaseCanvasPinchInput(reason);
    }
  }

  private endCanvasPanGesture(reason: string): void {
    if (!this.canvasPanActive || this.canvasPanInputSource !== 'gesture') {
      return;
    }
    const next = endCanvasPanOwnership({
      pinchActive: this.canvasPinchActive,
      panActive: this.canvasPanActive
    });
    this.finishCanvasPan();
    if (shouldReleaseCanvasGestureOwnership(next)) {
      this.releaseCanvasPinchInput(reason);
    }
  }

  /** Claim input only after ArkUI has recognized a real pinch, never on second-finger down. */
  private claimCanvasPinchInput(): void {
    if (this.canvasPinchInputPhase !== 'idle') {
      return;
    }
    const observedTouchCount: number = this.activeTouchPoints.size > 0 ?
      this.activeTouchPoints.size : this.touchFingerCount;
    const state = claimCanvasPinchTouchState(observedTouchCount);
    this.canvasPinchInputPhase = state.phase;
    this.canvasPinchTouchCount = state.fingerCount;
    this.clearTouchRightClickTimer();
    this.clearTouchDirectRightClickTimer();
    if (this.touchLeftDown) {
      this.sendMouseNow(this.remoteCursorX, this.remoteCursorY, 0, false);
      this.touchLeftDown = false;
    }
    this.touchDragActive = false;
    this.touchDragPending = false;
    this.touchGestureDone = true;
  }

  private updateCanvasPinch(event: GestureEvent): void {
    if (this.rustDeskTouchPinchActive) {
      this.updateRustDeskRemoteAppTouchScale(event);
      return;
    }
    if (!this.canvasPinchActive || !this.canvasGestureZoomEnabled) {
      return;
    }
    const viewport: CanvasViewport | null = this.canvasPinchViewportSnapshot;
    if (viewport === null) {
      this.releaseCanvasPinchInput('canvas-pinch-missing-viewport');
      return;
    }
    const nextScale: number = Number.isFinite(event.scale) && event.scale > 0 ? event.scale : this.canvasPinchLastScale;
    const centerX: number = this.canvasGestureVpToPx(event.pinchCenterX);
    const centerY: number = this.canvasGestureVpToPx(event.pinchCenterY);
    this.canvasTransform = pinchCanvasTransform(this.canvasTransform, viewport,
      centerX, centerY, nextScale / this.canvasPinchLastScale,
      centerX - this.canvasPinchLastCenterX, centerY - this.canvasPinchLastCenterY);
    this.canvasPinchLastScale = nextScale;
    this.canvasPinchLastCenterX = centerX;
    this.canvasPinchLastCenterY = centerY;
    this.canvasTransformGestureModified = true;
    this.applyCanvasTransform();
  }

  private finishCanvasPinch(): void {
    if (this.rustDeskTouchPinchActive) {
      this.finishRustDeskRemoteAppTouchScale();
    }
    this.canvasPinchActive = false;
    this.canvasPinchLastScale = 1;
    this.canvasPinchViewportSnapshot = null;
    this.rustDeskTouchPinchTransformSnapshot = null;
    if (!this.canvasPanActive) {
      this.canvasGesturePxPerVp = 1;
    }
  }

  /** Release gesture ownership from every terminal path; safe to call repeatedly. */
  private releaseCanvasPinchInput(reason: string): void {
    const wasActive: boolean = this.canvasPinchActive || this.rustDeskTouchPinchActive;
    const wasConsumed: boolean = this.canvasPinchInputPhase !== 'idle';
    this.finishCanvasPan();
    this.finishCanvasPinch();
    if (wasConsumed) {
      this.resetTouchGesture();
      if (shouldDrainCanvasPinchTouchSequence(reason)) {
        const state = drainCanvasPinchTouchState({
          phase: this.canvasPinchInputPhase,
          fingerCount: this.canvasPinchTouchCount
        });
        this.canvasPinchInputPhase = state.phase;
        this.canvasPinchTouchCount = state.fingerCount;
      } else {
        this.canvasPinchInputPhase = 'idle';
        this.canvasPinchTouchCount = 0;
      }
    }
    if (wasActive || wasConsumed) {
      hilog.info(RD_DOMAIN, RD_TAG, 'canvas-pinch-release reason=' + reason);
    }
    this.resetCanvasTwoFingerGesture();
  }

  private consumeCanvasPinchTouch(event: TouchEvent): boolean {
    // A raw-touch pan claims the same drain phase as a pinch to stop the
    // remote pointer path, but its local movement still has to be consumed by
    // the canvas transform before the event is swallowed.
    if (this.canvasPanActive && this.canvasPanInputSource === 'touch' &&
      event.sourceTool === SourceTool.Finger && event.type === TouchType.Move) {
      const point: LocalPoint | null = this.averageTouchPoint(event);
      if (point !== null) {
        this.updateCanvasPanFromPoint(point.x, point.y);
      }
      event.stopPropagation();
      return true;
    }
    if (!shouldConsumeCanvasPinchTouch(this.canvasPinchInputPhase !== 'idle',
      event.sourceTool === SourceTool.Finger)) {
      return false;
    }

    const eventType: CanvasPinchTouchEvent = event.type === TouchType.Down ? 'down' :
      event.type === TouchType.Up ? 'up' :
        event.type === TouchType.Cancel ? 'cancel' : 'move';
    const activeTouchCount: number = this.trackedCanvasTouchCount(event);
    if (shouldStartNewCanvasPinchTouchSequence(this.canvasPinchInputPhase, eventType,
      activeTouchCount, event.changedTouches.length)) {
      this.finishCanvasPinch();
      this.canvasPinchInputPhase = 'idle';
      this.canvasPinchTouchCount = 0;
      this.resetTouchGesture();
      return false;
    }

    const next = advanceCanvasPinchTouchState({
      phase: this.canvasPinchInputPhase,
      fingerCount: this.canvasPinchTouchCount
    }, eventType, activeTouchCount, event.changedTouches.length);
    this.canvasPinchInputPhase = next.phase;
    this.canvasPinchTouchCount = next.fingerCount;
    if (next.phase === 'idle') {
      this.finishCanvasPan();
      this.finishCanvasPinch();
      this.resetTouchGesture();
    }
    event.stopPropagation();
    return true;
  }

  private rustDeskViewScaleLabel(mode: string): string {
    if (mode === 'original') { return '原始尺寸'; }
    if (mode === 'custom') { return '自定义缩放'; }
    return '适应窗口';
  }

  private setRustDeskImageQualityPref(quality: number): void {
    const next: number = quality >= 0 && quality <= 2 ? quality : 1;
    this.rustdeskImageQuality = next;
    this.persistSessionPref('rustdeskImageQuality', next);
    promptAction.showToast({ message: '画质偏好已保存，重连后完全生效', duration: 2000 });
  }

  private setRustDeskCodecPref(codec: number): void {
    const next: number = codec >= 0 && codec <= 5 ? codec : 0;
    this.rustdeskCodec = next;
    this.persistSessionPref('rustdeskCodec', next);
    promptAction.showToast({ message: '编解码偏好已保存，重连后完全生效', duration: 2000 });
  }

  private setRustDeskShowLocalCursor(on: boolean): void {
    this.rustdeskShowLocalCursor = on;
    this.persistSessionPref('rustdeskShowLocalCursor', on);
  }

  private setRustDeskBrowseMode(on: boolean): void {
    this.rustdeskBrowseMode = on;
    this.persistSessionPref('rustdeskBrowseMode', on);
    promptAction.showToast({
      message: on ? '已开启浏览模式，仅查看远端画面' : '已关闭浏览模式，可继续控制远端',
      duration: 1400
    });
  }

  private setRustDeskRelativeMouseMode(on: boolean): void {
    this.rustdeskRelativeMouseMode = on;
    this.persistSessionPref('rustdeskRelativeMouseMode', on);
  }

  /** Retains the legacy key while applying wheel direction to every remote protocol. */
  private setRemoteReverseWheel(on: boolean): void {
    this.rustdeskReverseWheel = on;
    this.persistSessionPref('rustdeskReverseWheel', on);
  }

  private setRustDeskSwapMouseButtons(on: boolean): void {
    this.rustdeskSwapMouseButtons = on;
    this.persistSessionPref('rustdeskSwapMouseButtons', on);
  }

  private setRustDeskTouchpadSpeed(speed: number): void {
    const next: number = Math.max(0.4, Math.min(2.2, speed));
    this.rustdeskTouchpadSpeed = next;
    this.persistSessionPref('rustdeskTouchpadSpeed', next);
    promptAction.showToast({ message: '触控板速度 ' + next.toFixed(1) + 'x', duration: 1200 });
  }

  private rustDeskTopBarActions(): RemoteSessionTopBarActions {
    return {
      onDisconnect: (): void => {
        this.disconnectAndCleanup('rustdesk-topbar-close');
        this.goBack();
      },
      onRefreshFrame: (): void => {
        this.loader.requestFrameRefresh();
        promptAction.showToast({ message: '已请求刷新远端画面', duration: 1200 });
      },
      onOpenKeyboard: (): void => {
        if (this.keyboardOpen) {
          this.keepKeyboardAfterSheetClose = false;
          this.dismissKeyboard();
        } else {
          this.openKeyboard();
        }
      },
      onOpenFileTransfer: (): void => {
        this.pickAndSendFile();
      },
      onCtrlAltDel: (): void => {
        this.sendCtrlAltDel();
      },
      onLockRemote: (): void => {},
      onTogglePrivacy: (on: boolean): void => {
        this.setRustDeskPrivacyMode(on);
      },
      onToggleAudio: (on: boolean): void => {
        this.setRustDeskAudioEnabled(on);
      },
      onToggleClipboard: (on: boolean): void => {
        this.setRustDeskClipboardEnabled(on);
      },
      onToggleFilePaste: (on: boolean): void => {
        this.setRustDeskFilePasteEnabled(on);
      },
      onSetViewScaleMode: (mode: string): void => {
        this.setRemoteDisplayScaleMode(mode);
      },
      onResetCanvasTransform: (): void => {
        this.resetCanvasTransformFromMenu();
      },
      onOpenRustDeskResolution: (): void => {
        this.openRustDeskDisplayResolutionMenu();
      },
      onSetRustDeskImageQuality: (quality: number): void => {
        this.setRustDeskImageQualityPref(quality);
      },
      onSetRustDeskCodec: (codec: number): void => {
        this.setRustDeskCodecPref(codec);
      },
      onToggleShowLocalCursor: (on: boolean): void => {
        this.setRustDeskShowLocalCursor(on);
      },
      onToggleBrowseMode: (on: boolean): void => {
        this.setRustDeskBrowseMode(on);
      },
      onToggleRelativeMouse: (on: boolean): void => {
        this.setRustDeskRelativeMouseMode(on);
      },
      onToggleReverseWheel: (on: boolean): void => {
        this.setRemoteReverseWheel(on);
      },
      onToggleSwapMouseButtons: (on: boolean): void => {
        this.setRustDeskSwapMouseButtons(on);
      },
      onSetTouchpadSpeed: (speed: number): void => {
        this.setRustDeskTouchpadSpeed(speed);
      },
      onUnsupported: (actionId: string, reason: string): void => {
        this.toastUnsupportedRustDeskAction(actionId, reason);
      }
    };
  }

  private hideTouchIndicator(): void {
    this.clearTouchIndicatorTimer();
    this.touchIndicatorVisible = false;
    this.publishRemoteCursorOverlay();
  }

  // ============================================================
  // T-171: 悬浮胶囊吸边 + 键盘避让
  // ============================================================

  private snapHandleToEdge(x: number, y: number): void {
    const screenW: number = this.surfaceWidth > 0 ? this.surfaceWidth : 360;
    const screenH: number = this.surfaceHeight > 0 ? this.surfaceHeight : 640;
    const capsuleHalfW: number = this.modifierHandleWidth() / 2;
    const midX: number = screenW / 2;
    const newSide: string = x + capsuleHalfW < midX ? 'left' : 'right';
    const snapX: number = newSide === 'left' ? this.modifierHiddenLeftX() : this.modifierHiddenRightX(screenW);
    const topMargin: number = 48;
    const bottomMargin: number = this.kbHeight > 0 ? this.kbHeight + 8 : 48;
    const clampedY: number = Math.max(topMargin, Math.min(y, screenH - bottomMargin - 42));
    this.handleX = x;
    this.handleY = clampedY;
    animateTo({ duration: 180, curve: Curve.EaseOut }, (): void => {
      this.handleX = snapX;
      this.handleY = clampedY;
      this.handleSide = newSide;
    });
    // T-171-PH6: 持久化位置
    AppStorage.setOrCreate('remoteModifierHandleSide', newSide);
    AppStorage.setOrCreate('remoteModifierHandleYRatio', clampedY / screenH);
  }

  private initHandlePosition(): void {
    const screenW: number = this.surfaceWidth > 0 ? this.surfaceWidth : 360;
    const screenH: number = this.surfaceHeight > 0 ? this.surfaceHeight : 640;
    // T-171-PH6: 从 AppStorage 恢复上次位置
    const savedSide: string = AppStorage.get<string>('remoteModifierHandleSide') ?? '';
    const savedYR: number = AppStorage.get<number>('remoteModifierHandleYRatio') ?? -1;
    const side: string = (savedSide === 'left' || savedSide === 'right') ? savedSide : 'right';
    const yRatio: number = (savedYR > 0 && savedYR < 1) ? savedYR : 0.35;
    this.handleSide = side;
    this.handleX = side === 'left' ? this.modifierHiddenLeftX() : this.modifierHiddenRightX(screenW);
    this.handleY = Math.round(screenH * yRatio);
    this.ensureModifierPanelPositions();
  }

  private modifierHandleWidth(): number {
    return 58;
  }

  private modifierHandleVisibleWidth(): number {
    return 24;
  }

  private modifierHiddenLeftX(): number {
    return -(this.modifierHandleWidth() - this.modifierHandleVisibleWidth());
  }

  private modifierHiddenRightX(screenW: number): number {
    return Math.max(8, screenW - this.modifierHandleVisibleWidth());
  }

  // RustDesk diagnostics is a separate dock, but uses the same local side and
  // vertical-ratio persistence model as the modifier-key capsule.
  private rustDeskDiagnosticsDockWidth(): number {
    return 270;
  }

  private rustDeskDiagnosticsDockHeight(): number {
    return this.shouldShowAdvancedDiagnostics() ?
      380 : 205;
  }

  private rustDeskDiagnosticsDockHandleWidth(): number {
    return 76;
  }

  private rustDeskDiagnosticsDockVisibleWidth(): number {
    return 28;
  }

  private rustDeskDiagnosticsDockPanelX(): number {
    const screenW: number = this.surfaceWidth > 0 ? this.surfaceWidth : 360;
    return this.rustDeskDiagnosticsDockSide === 'left' ? 8 :
      Math.max(8, screenW - this.rustDeskDiagnosticsDockWidth() - 8);
  }

  private rustDeskDiagnosticsDockHandleX(): number {
    const screenW: number = this.surfaceWidth > 0 ? this.surfaceWidth : 360;
    if (this.rustDeskDiagnosticsDockSide === 'left') {
      return -(this.rustDeskDiagnosticsDockHandleWidth() - this.rustDeskDiagnosticsDockVisibleWidth());
    }
    return Math.max(8, screenW - this.rustDeskDiagnosticsDockVisibleWidth());
  }

  private clampRustDeskDiagnosticsDockY(y: number): number {
    const screenH: number = this.surfaceHeight > 0 ? this.surfaceHeight : 640;
    const topMargin: number = this.dropHoverActive ? 116 : 58;
    const bottomMargin: number = this.kbHeight > 0 ? this.kbHeight + 8 : 24;
    const maxY: number = Math.max(topMargin, screenH - bottomMargin - this.rustDeskDiagnosticsDockHeight());
    return Math.max(topMargin, Math.min(y, maxY));
  }

  private updateRustDeskDiagnosticsDockForKeyboard(): void {
    if (!this.rustDeskDiagnosticsDockExpanded) {
      return;
    }
    const screenH: number = this.surfaceHeight > 0 ? this.surfaceHeight : 640;
    const topMargin: number = this.dropHoverActive ? 116 : 58;
    const bottomMargin: number = this.kbHeight > 0 ? this.kbHeight + 8 : 24;
    if (screenH - topMargin - bottomMargin < this.rustDeskDiagnosticsDockHeight()) {
      this.rustDeskDiagnosticsDockExpanded = false;
      return;
    }
    this.rustDeskDiagnosticsDockY = this.avoidRustDeskDiagnosticsDockCollision(
      this.rustDeskDiagnosticsDockSide, this.rustDeskDiagnosticsDockY);
  }

  private avoidRustDeskDiagnosticsDockCollision(side: string, y: number): number {
    let resolvedY: number = this.clampRustDeskDiagnosticsDockY(y);
    if (side !== this.handleSide || !this.handleVisible) {
      return resolvedY;
    }
    const modifierY: number = this.modifierPanelVisible ? this.modifierPanelY : this.handleY;
    const modifierHeight: number = this.modifierPanelVisible ? (this.fnLayer ? 300 : 136) : 42;
    const dockBottom: number = resolvedY + this.rustDeskDiagnosticsDockHeight();
    const modifierBottom: number = modifierY + modifierHeight;
    if (dockBottom + 12 <= modifierY || resolvedY >= modifierBottom + 12) {
      return resolvedY;
    }
    const above: number = this.clampRustDeskDiagnosticsDockY(modifierY - this.rustDeskDiagnosticsDockHeight() - 12);
    const below: number = this.clampRustDeskDiagnosticsDockY(modifierBottom + 12);
    resolvedY = Math.abs(above - y) <= Math.abs(below - y) ? above : below;
    return resolvedY;
  }

  private initRustDeskDiagnosticsDock(): void {
    const screenH: number = this.surfaceHeight > 0 ? this.surfaceHeight : 640;
    const savedSide: string = AppStorage.get<string>('rustdeskDiagnosticsDockSide') ?? '';
    const savedYRatio: number = AppStorage.get<number>('rustdeskDiagnosticsDockYRatio') ?? -1;
    const defaultSide: string = this.handleSide === 'left' ? 'right' : 'left';
    const side: string = savedSide === 'left' || savedSide === 'right' ? savedSide : defaultSide;
    const initialY: number = savedYRatio > 0 && savedYRatio < 1 ? Math.round(screenH * savedYRatio) :
      Math.round(screenH * 0.56);
    this.rustDeskDiagnosticsDockSide = side;
    this.rustDeskDiagnosticsDockY = this.avoidRustDeskDiagnosticsDockCollision(side, initialY);
    this.rustDeskDiagnosticsDockExpanded = false;
    this.rustDeskDiagnosticsDockInitialized = true;
  }

  private snapRustDeskDiagnosticsDockToEdge(x: number, y: number, fromPanel: boolean): void {
    const screenW: number = this.surfaceWidth > 0 ? this.surfaceWidth : 360;
    const referenceX: number = x + (fromPanel ? this.rustDeskDiagnosticsDockWidth() / 2 :
      this.rustDeskDiagnosticsDockHandleWidth() / 2);
    const side: string = referenceX < screenW / 2 ? 'left' : 'right';
    const clampedY: number = this.avoidRustDeskDiagnosticsDockCollision(side, y);
    animateTo({ duration: 180, curve: Curve.EaseOut }, (): void => {
      this.rustDeskDiagnosticsDockSide = side;
      this.rustDeskDiagnosticsDockY = clampedY;
    });
    AppStorage.setOrCreate('rustdeskDiagnosticsDockSide', side);
    const screenH: number = this.surfaceHeight > 0 ? this.surfaceHeight : 640;
    AppStorage.setOrCreate('rustdeskDiagnosticsDockYRatio', clampedY / screenH);
  }

  private toggleRustDeskDiagnosticsDock(): void {
    this.rustDeskDiagnosticsDockExpanded = !this.rustDeskDiagnosticsDockExpanded;
    if (this.rustDeskDiagnosticsDockExpanded) {
      this.rustDeskDiagnosticsDockY = this.avoidRustDeskDiagnosticsDockCollision(
        this.rustDeskDiagnosticsDockSide, this.rustDeskDiagnosticsDockY);
    }
  }

  private modifierPanelWidth(): number {
    if (this.breakpoint === 'xl') {
      return 320;
    }
    if (this.breakpoint === 'lg') {
      return 300;
    }
    if (this.breakpoint === 'md') {
      return 280;
    }
    return 260;
  }

  private clampModifierPanelX(x: number): number {
    const screenW: number = this.surfaceWidth > 0 ? this.surfaceWidth : 360;
    const maxX: number = Math.max(8, screenW - this.modifierPanelWidth() - 8);
    return Math.max(8, Math.min(x, maxX));
  }

  private clampModifierPanelY(y: number, estimatedHeight: number): number {
    const screenH: number = this.surfaceHeight > 0 ? this.surfaceHeight : 640;
    const bottomMargin: number = this.kbHeight > 0 ? this.kbHeight + 8 : 24;
    const maxY: number = Math.max(48, screenH - bottomMargin - estimatedHeight);
    return Math.max(48, Math.min(y, maxY));
  }

  private isValidModifierPanelRatio(value: number): boolean {
    return Number.isFinite(value) && value >= 0 && value < 1;
  }

  private restoreModifierPanelPositions(previousWidth: number = 0,
    previousHeight: number = 0): void {
    const hasSurfaceSize: boolean = this.surfaceWidth > 0 && this.surfaceHeight > 0;
    const screenW: number = hasSurfaceSize ? this.surfaceWidth : 360;
    const screenH: number = hasSurfaceSize ? this.surfaceHeight : 640;
    const panelW: number = this.modifierPanelWidth();
    const defaultX: number = this.handleSide === 'right' ? Math.max(8, screenW - panelW - 8) : 8;
    const defaultY: number = this.clampModifierPanelY(this.handleY - 20, this.fnLayer ? 300 : 136);
    const savedModifierXRatio: number = AppStorage.get<number>('remoteModifierPanelXRatio') ?? -1;
    const savedModifierYRatio: number = AppStorage.get<number>('remoteModifierPanelYRatio') ?? -1;
    const savedShortcutXRatio: number = AppStorage.get<number>('remoteShortcutPanelXRatio') ?? -1;
    const savedShortcutYRatio: number = AppStorage.get<number>('remoteShortcutPanelYRatio') ?? -1;
    const priorW: number = previousWidth > 0 ? previousWidth : screenW;
    const priorH: number = previousHeight > 0 ? previousHeight : screenH;
    const priorModifierXRatio: number = previousWidth > 0 ? this.modifierPanelX / priorW : -1;
    const priorModifierYRatio: number = previousHeight > 0 ? this.modifierPanelY / priorH : -1;
    const priorShortcutXRatio: number = previousWidth > 0 ? this.shortcutPanelX / priorW : -1;
    const priorShortcutYRatio: number = previousHeight > 0 ? this.shortcutPanelY / priorH : -1;
    const modifierXRatio: number = this.isValidModifierPanelRatio(savedModifierXRatio) ?
      savedModifierXRatio : priorModifierXRatio;
    const modifierYRatio: number = this.isValidModifierPanelRatio(savedModifierYRatio) ?
      savedModifierYRatio : priorModifierYRatio;
    const shortcutXRatio: number = this.isValidModifierPanelRatio(savedShortcutXRatio) ?
      savedShortcutXRatio : priorShortcutXRatio;
    const shortcutYRatio: number = this.isValidModifierPanelRatio(savedShortcutYRatio) ?
      savedShortcutYRatio : priorShortcutYRatio;
    this.modifierPanelX = this.clampModifierPanelX(this.isValidModifierPanelRatio(modifierXRatio) ?
      screenW * modifierXRatio : defaultX);
    this.modifierPanelY = this.clampModifierPanelY(this.isValidModifierPanelRatio(modifierYRatio) ?
      screenH * modifierYRatio : defaultY, this.fnLayer ? 300 : 136);
    this.shortcutPanelX = this.clampModifierPanelX(this.isValidModifierPanelRatio(shortcutXRatio) ?
      screenW * shortcutXRatio : this.modifierPanelX);
    this.shortcutPanelY = this.clampModifierPanelY(this.isValidModifierPanelRatio(shortcutYRatio) ?
      screenH * shortcutYRatio : this.modifierPanelY + 150, 238);
    this.modifierPanelPositionReady = hasSurfaceSize;
  }

  private ensureModifierPanelPositions(): void {
    if (this.modifierPanelPositionReady) {
      this.clampModifierPanelsIntoView();
      return;
    }
    this.restoreModifierPanelPositions();
  }

  private clampModifierPanelsIntoView(): void {
    this.modifierPanelX = this.clampModifierPanelX(this.modifierPanelX);
    this.modifierPanelY = this.clampModifierPanelY(this.modifierPanelY, this.fnLayer ? 300 : 136);
    this.shortcutPanelX = this.clampModifierPanelX(this.shortcutPanelX);
    this.shortcutPanelY = this.clampModifierPanelY(this.shortcutPanelY, 238);
  }

  private persistModifierPanelPositions(): void {
    if (this.surfaceWidth <= 0 || this.surfaceHeight <= 0) {
      return;
    }
    const screenW: number = this.surfaceWidth;
    const screenH: number = this.surfaceHeight;
    AppStorage.setOrCreate('remoteModifierPanelXRatio', this.modifierPanelX / screenW);
    AppStorage.setOrCreate('remoteModifierPanelYRatio', this.modifierPanelY / screenH);
    AppStorage.setOrCreate('remoteShortcutPanelXRatio', this.shortcutPanelX / screenW);
    AppStorage.setOrCreate('remoteShortcutPanelYRatio', this.shortcutPanelY / screenH);
  }

  private moveModifierPanel(x: number, y: number): void {
    this.modifierPanelX = this.clampModifierPanelX(x);
    this.modifierPanelY = this.clampModifierPanelY(y, this.fnLayer ? 300 : 136);
    this.persistModifierPanelPositions();
  }

  private moveShortcutPanel(x: number, y: number): void {
    this.shortcutPanelX = this.clampModifierPanelX(x);
    this.shortcutPanelY = this.clampModifierPanelY(y, 238);
    this.persistModifierPanelPositions();
  }

  private openModifierPanel(): void {
    this.ensureModifierPanelPositions();
    this.modifierPanelMounted = true;
    this.modifierPanelVisible = true;
  }

  private closeModifierPanel(): void {
    this.modifierPanelVisible = false;
    this.shortcutPanelVisible = false;
    setTimeout((): void => {
      if (!this.modifierPanelVisible && !this.shortcutPanelVisible) {
        this.modifierPanelMounted = false;
      }
    }, 190);
  }

  private toggleModifierPanel(): void {
    if (this.modifierPanelVisible) {
      this.closeModifierPanel();
    } else {
      this.openModifierPanel();
    }
  }

  private closeShortcutPanel(): void {
    this.shortcutPanelVisible = false;
  }

  private toggleShortcutPanel(): void {
    this.ensureModifierPanelPositions();
    this.modifierPanelMounted = true;
    this.modifierPanelVisible = true;
    this.shortcutPanelVisible = !this.shortcutPanelVisible;
  }

  // ============================================================
  // T-171-PH2: 修饰键 once/locked 状态机
  // ============================================================

  private getLatch(mod: string): ModifierLatch {
    if (mod === 'ctrl') {
      return this.ctrlLatch;
    }
    if (mod === 'alt') {
      return this.altLatch;
    }
    if (mod === 'shift') {
      return this.shiftLatch;
    }
    return this.winLatch;
  }

  private setLatch(mod: string, val: ModifierLatch): void {
    const old: ModifierLatch = this.getLatch(mod);
    // 更新 UI 状态
    if (mod === 'ctrl') {
      this.ctrlLatch = val;
    } else if (mod === 'alt') {
      this.altLatch = val;
    } else if (mod === 'shift') {
      this.shiftLatch = val;
    } else if (mod === 'win') {
      this.winLatch = val;
    }
    // P0-2: locked 立即发送 key down; locked→off 发送 key up
    const keyCode: number = this.modifierKeyCode(mod);
    if (val === 'locked' && old !== 'locked' && !this.isRemoteModDown(mod) &&
      this.sessionId > 0 && this.connected) {
      if (!this.canForwardInput('modifier')) {
        hilog.info(RD_DOMAIN, RD_TAG, 'modifier remote down blocked: ' + mod);
        return;
      }
      this.loader.sendKey(this.sessionId, keyCode, true);
      this.setRemoteModDown(mod, true);
      hilog.info(RD_DOMAIN, RD_TAG, 'modifier remote down: ' + mod);
    } else if (val === 'off' && old === 'locked' && this.isRemoteModDown(mod) &&
      this.sessionId > 0 && this.connected) {
      if (!this.canForwardInput('modifier')) {
        hilog.info(RD_DOMAIN, RD_TAG, 'modifier remote up blocked: ' + mod);
        return;
      }
      this.loader.sendKey(this.sessionId, keyCode, false);
      this.setRemoteModDown(mod, false);
      hilog.info(RD_DOMAIN, RD_TAG, 'modifier remote up: ' + mod);
    }
    hilog.info(RD_DOMAIN, RD_TAG, 'modifier latch: ' + mod + '=' + val);
  }

  private modifierKeyCode(mod: string): number {
    if (mod === 'ctrl') {
      return KEYCODE_CTRL_LEFT;
    }
    if (mod === 'alt') {
      return KEYCODE_ALT_LEFT;
    }
    if (mod === 'shift') {
      return KEYCODE_SHIFT_LEFT;
    }
    return KEYCODE_META_LEFT;
  }

  private isRemoteModDown(mod: string): boolean {
    if (mod === 'ctrl') {
      return this.remoteCtrlDown;
    }
    if (mod === 'alt') {
      return this.remoteAltDown;
    }
    if (mod === 'shift') {
      return this.remoteShiftDown;
    }
    return this.remoteWinDown;
  }

  private setRemoteModDown(mod: string, down: boolean): void {
    if (mod === 'ctrl') {
      this.remoteCtrlDown = down;
    } else if (mod === 'alt') {
      this.remoteAltDown = down;
    } else if (mod === 'shift') {
      this.remoteShiftDown = down;
    } else if (mod === 'win') {
      this.remoteWinDown = down;
    }
  }

  private resetRemoteModDown(): void {
    this.remoteCtrlDown = false;
    this.remoteAltDown = false;
    this.remoteShiftDown = false;
    this.remoteWinDown = false;
  }

  private toggleModifierLatch(mod: string): void {
    const current: ModifierLatch = this.getLatch(mod);
    if (mod === 'win') {
      if (current === 'locked') {
        this.setLatch(mod, 'off');
      } else if (current === 'off') {
        this.sendVirtualKeyTap(KEYCODE_META_LEFT, 'Win');
      } else {
        this.setLatch(mod, 'off');
      }
      return;
    }
    // off→once, once→off, locked→off
    const next: ModifierLatch = current === 'off' ? 'once' : 'off';
    this.setLatch(mod, next);
  }

  private lockModifierLatch(mod: string): void {
    // off/once→locked
    this.setLatch(mod, 'locked');
  }

  private isModifierLatched(mod: string): boolean {
    return this.getLatch(mod) !== 'off';
  }

  private resetAllLatches(): void {
    this.ctrlLatch = 'off';
    this.altLatch = 'off';
    this.shiftLatch = 'off';
    this.winLatch = 'off';
  }

  // ============================================================
  // T-171-PH3: 虚拟组合键 sendKey() down/up 发送
  // ============================================================

  /** 发送单键 down+up → RemoteKeyDispatcher */
  private sendVirtualKeyTap(keyCode: number, label: string): void {
    if (this.sessionId <= 0 || !this.connected || !this.canForwardInput('virtual-key')) {
      return;
    }
    this.keyDispatcher.sendVirtualKeyTap(this.loader, this.sessionId, keyCode, label);
  }

  /** 发送带修饰键的按键序列 → RemoteKeyDispatcher */
  private sendModifiedKey(keyCode: number, label: string): void {
    if (this.sessionId <= 0 || !this.connected || !this.canForwardInput('virtual-modified-key')) {
      return;
    }
    this.keyDispatcher.sendModifiedKey(this.loader, this.sessionId,
      keyCode, label,
      (mod: string): string => this.getLatch(mod),
      (mod: string, val: string): void => { this.setLatch(mod, val as ModifierLatch); },
      (mod: string): boolean => this.isRemoteModDown(mod));
  }

  /** 发送快捷键序列 → RemoteKeyDispatcher */
  private sendShortcutSequence(keyCodes: number[], label: string): void {
    if (this.sessionId <= 0 || !this.connected || !this.canForwardInput('virtual-shortcut')) {
      return;
    }
    this.keyDispatcher.sendShortcutSequence(this.loader, this.sessionId, keyCodes, label,
      (mod: string): string => this.getLatch(mod),
      (mod: string): boolean => this.isRemoteModDown(mod),
      (mod: string, down: boolean): void => { this.setRemoteModDown(mod, down); });
  }

  /** Ctrl+Alt+Del → RemoteKeyDispatcher */
  private sendCtrlAltDel(): void {
    if (this.sessionId <= 0 || !this.connected || !this.canForwardInput('virtual-ctrl-alt-del')) {
      return;
    }
    this.keyDispatcher.sendCtrlAltDel(this.loader, this.sessionId, this.accentColor,
      (mod: string): string => this.getLatch(mod),
      (mod: string): boolean => this.isRemoteModDown(mod),
      (mod: string, down: boolean): void => { this.setRemoteModDown(mod, down); });
  }

  /** Release remote keys and, for lifecycle teardown, any held mouse buttons. */
  private releaseAllHeldKeys(releaseMouseButtons: boolean = true): void {
    this.releasePendingMacCapsLock();
    if (this.sessionId <= 0) {
      this.physicalRemoteKeyCodesDown = [];
      this.resetPhysicalModifiers();
      return;
    }
    // RemoteKeyDispatcher 只知道虚拟修饰键；组合键中的普通实体键由本页
    // 直接发送，因此断开前也要补发它们的 Up，避免下一次连接继承脏状态。
    const physicalKeys: Array<number> = this.physicalRemoteKeyCodesDown.slice();
    for (let index = physicalKeys.length - 1; index >= 0; index--) {
      try {
        this.loader.sendKey(this.sessionId, physicalKeys[index], false);
      } catch (err) {
        hilog.warn(RD_DOMAIN, RD_TAG, 'release physical key failed code=' +
          physicalKeys[index].toString() + ' error=' + JSON.stringify(err));
      }
    }
    this.physicalRemoteKeyCodesDown = [];
    this.keyDispatcher.releaseAllHeldKeys(this.loader, this.sessionId,
      (x: number, y: number): Record<string, number> => this.toSourceSpace(x, y),
      this.remoteCursorX, this.remoteCursorY, releaseMouseButtons);
    if (releaseMouseButtons) {
      this.physicalMouseDownButton = -1;
    }
    this.resetPhysicalModifiers();
  }

  private registerKeyboardAvoidListener(): void {
    try {
      const ctx: common.Context | undefined = this.getUIContext().getHostContext();
      if (!ctx) {
        return;
      }
      window.getLastWindow(ctx).then((w: window.Window): void => {
        this.kbWin = w;
        try {
          const keyboardArea: window.AvoidArea =
            w.getWindowAvoidArea(window.AvoidAreaType.TYPE_KEYBOARD);
          this.kbHeight = px2vp(keyboardArea.bottomRect.height);
          this.updateRustDeskDiagnosticsDockForKeyboard();
        } catch (_e) {
          // 初始读取失败, 后续 avoidAreaChange 会更新
        }
        this.kbAvoidCb = (data: window.AvoidAreaOptions): void => {
          if (data.type === window.AvoidAreaType.TYPE_KEYBOARD) {
            this.kbHeight = px2vp(data.area.bottomRect.height);
            this.updateRustDeskDiagnosticsDockForKeyboard();
            hilog.info(RD_DOMAIN, RD_TAG,
              'kbHeight changed: ' + Math.round(this.kbHeight).toString() + 'vp');
          }
        };
        w.on('avoidAreaChange', this.kbAvoidCb);
      }).catch((err: Error): void => {
        hilog.warn(RD_DOMAIN, RD_TAG,
          'registerKeyboardAvoid: getLastWindow failed: ' + err.message);
      });
    } catch (err) {
      hilog.warn(RD_DOMAIN, RD_TAG,
        'registerKeyboardAvoid failed: ' + JSON.stringify(err));
    }
  }

  private unregisterKeyboardAvoidListener(): void {
    try {
      if (this.kbWin && this.kbAvoidCb) {
        this.kbWin.off('avoidAreaChange', this.kbAvoidCb);
      }
    } catch (_e) {
      // 忽略卸载异常
    }
    this.kbWin = null;
    this.kbAvoidCb = null;
    this.kbHeight = 0;
  }

  private cancelPendingDisappearDecision(): void {
    if (this.pendingDisappearDecisionTimer >= 0) {
      clearTimeout(this.pendingDisappearDecisionTimer);
      this.pendingDisappearDecisionTimer = -1;
    }
    this.disappearDecisionGeneration += 1;
  }

  private deferDisappearDecision(): void {
    this.cancelPendingDisappearDecision();
    const generation: number = this.disappearDecisionGeneration;
    this.pendingDisappearDecisionTimer = setTimeout((): void => {
      this.pendingDisappearDecisionTimer = -1;
      if (generation !== this.disappearDecisionGeneration) {
        return;
      }

      const isBg: boolean = AppStorage.get<boolean>('remoteDesktopBgFlag') ?? false;
      if (isBg) {
        hilog.info(RD_DOMAIN, RD_TAG,
          'deferred page disappear: background signal arrived, preserving session');
        this.onRemoteDesktopBgFlagChange();
        return;
      }

      hilog.info(RD_DOMAIN, RD_TAG,
        'deferred page disappear: no background signal, disconnecting explicit exit');
      this.disconnectAndCleanup('explicit-exit');
    }, REMOTE_DESKTOP_DISAPPEAR_BACKGROUND_SIGNAL_WAIT_MS);
    hilog.info(RD_DOMAIN, RD_TAG,
      'page disappear: waiting for background lifecycle signal before disconnect');
  }

  private onRemoteDesktopBgFlagChange(): void {
    const isBackground: boolean = AppStorage.get<boolean>('remoteDesktopBgFlag') ??
      this.remoteDesktopBgFlag;
    if (isBackground) {
      this.cancelPendingDisappearDecision();
    }
    const action: RemoteDesktopBackgroundAction = decideRemoteDesktopBackgroundAction(
      isBackground,
      this.connected,
      this.sessionId,
      this.bgRestorePending,
      this.cleanupStarted
    );
    if (action === RemoteDesktopBackgroundAction.detach) {
      hilog.info(RD_DOMAIN, RD_TAG, 'bgFlagChange: background preserve');
      this.detachForBackground().catch((err: Error): void => {
        hilog.warn(RD_DOMAIN, RD_TAG, 'bgFlagChange: background preserve failed: ' +
          (err.message ? err.message : JSON.stringify(err)));
      });
      return;
    }
    if (action === RemoteDesktopBackgroundAction.restore) {
      hilog.info(RD_DOMAIN, RD_TAG, 'bgFlagChange: foreground restore');
      this.restoreFromBackground();
      return;
    }
    if (action === RemoteDesktopBackgroundAction.alreadyPreserved) {
      hilog.info(RD_DOMAIN, RD_TAG, 'bgFlagChange: session already preserved');
    }
  }

  private vpToPx(value: number): number {
    try {
      const d: display.Display = display.getDefaultDisplaySync();
      return value * d.densityPixels;
    } catch (_e) {
      return value;
    }
  }

  private evenPx(value: number): number {
    const rounded: number = Math.max(2, Math.round(value));
    return rounded % 2 === 0 ? rounded : rounded - 1;
  }

  private adaptiveSurfaceSize(maxEdgePx: number = RUSTDESK_ADAPTIVE_MAX_EDGE_PX,
    keepComputerLandscape: boolean = true): DesktopSize | null {
    let widthPx: number = this.renderWidthPx;
    let heightPx: number = this.renderHeightPx;
    if (widthPx <= 0 || heightPx <= 0) {
      try {
        const d: display.Display = display.getDefaultDisplaySync();
        widthPx = d.width;
        heightPx = d.height;
      } catch (_e) {
        return null;
      }
    }
    if (widthPx <= 0 || heightPx <= 0) {
      return null;
    }
    // RDP keeps its historical computer-screen request. RustDesk mobile must
    // preserve a portrait peer ratio so the first frame can represent an
    // Android display without an implicit 90-degree rotation.
    if (keepComputerLandscape && widthPx < heightPx) {
      const portraitWidth: number = widthPx;
      widthPx = heightPx;
      heightPx = portraitWidth;
    }
    const longEdge: number = Math.max(widthPx, heightPx);
    const scale: number = longEdge > maxEdgePx ? maxEdgePx / longEdge : 1;
    return {
      width: this.evenPx(widthPx * scale),
      height: this.evenPx(heightPx * scale),
      colorDepth: 32,
      multiMonitor: false,
      monitorCount: 1
    };
  }

  /**
   * Return the page XComponent's physical surface size. This is intentionally
   * separate from desktopSize(), which describes the remote video stream.
   */
  private currentPageSurfaceSize(fallbackWidth: number, fallbackHeight: number): RemoteSessionPipContentSize {
    let width: number = this.renderWidthPx;
    let height: number = this.renderHeightPx;
    if (width <= 0 || height <= 0) {
      try {
        const d: display.Display = display.getDefaultDisplaySync();
        width = d.width;
        height = d.height;
      } catch (_e) {
        width = fallbackWidth;
        height = fallbackHeight;
      }
    }
    return {
      width: Math.max(1, Math.round(width > 0 ? width : fallbackWidth)),
      height: Math.max(1, Math.round(height > 0 ? height : fallbackHeight))
    };
  }

  /** PIP content ratio follows the remote frame, never the local page surface. */
  private currentPipContentSize(): RemoteSessionPipContentSize {
    let sourceWidth: number = 0;
    let sourceHeight: number = 0;
    const isRustDesk: boolean = this.pendingHost?.protocol === 'rustdesk';

    // The first RustDesk request can be an adaptive display size (for example
    // 742x1600) while the peer's first real frame is 2560x1600. Prefer the
    // observed media dimensions so PIP does not lock onto the request ratio.
    if (isRustDesk && this.sessionId > 0) {
      try {
        const diagnostics: RustDeskDiagnosticsSnapshot = this.loader.getRustDeskDiagnostics(this.sessionId);
        if (diagnostics.videoSeen && diagnostics.width > 0 && diagnostics.height > 0) {
          sourceWidth = diagnostics.width;
          sourceHeight = diagnostics.height;
        }
      } catch (_e) {
        // The stream may be between sessions while PIP is being prepared.
      }
    } else if (this.pendingHost?.protocol === 'rdp' && this.sessionId > 0) {
      try {
        const stats: RdpRenderStats = this.loader.getRdpRenderStats(this.sessionId);
        if (stats.desktopWidth > 0 && stats.desktopHeight > 0) {
          sourceWidth = stats.desktopWidth;
          sourceHeight = stats.desktopHeight;
        }
      } catch (_e) {
        // Renderer statistics are unavailable during early connection setup.
      }
    }

    // RDP's GDI path can have an owned frame before graphics lifecycle
    // dimensions are published. Prefer the requested remote ratio to the
    // local (possibly portrait) page surface during that interval.
    if ((sourceWidth <= 0 || sourceHeight <= 0) && this.pendingHost?.protocol === 'rdp') {
      sourceWidth = this.remoteWidth;
      sourceHeight = this.remoteHeight;
    }
    // Before the first RustDesk frame, the renderer's source is initialized
    // from the local XComponent surface. That surface may still be portrait
    // during cold start, so never use it as the PIP media ratio. The logical
    // adaptive request below is the safe pre-frame fallback.
    if ((sourceWidth <= 0 || sourceHeight <= 0) && !isRustDesk && this.rendererHandle > 0) {
      const viewport: RendererViewportSnapshot | null = this.readRendererViewport(true);
      if (viewport !== null && viewport.sourceWidth > 0 && viewport.sourceHeight > 0) {
        sourceWidth = viewport.sourceWidth;
        sourceHeight = viewport.sourceHeight;
      }
    }
    if ((sourceWidth <= 0 || sourceHeight <= 0) && !isRustDesk) {
      sourceWidth = this.rendererSourceWidth;
      sourceHeight = this.rendererSourceHeight;
    }
    return resolveRemoteSessionPipContentSize(
      sourceWidth, sourceHeight,
      this.remoteWidth, this.remoteHeight);
  }

  private clearPipContentSizeRefresh(): void {
    for (const timer of this.pipContentSizeRefreshTimers) {
      clearTimeout(timer);
    }
    this.pipContentSizeRefreshTimers = [];
    this.pipLastContentWidth = 0;
    this.pipLastContentHeight = 0;
  }

  private refreshActivePipContentSize(): void {
    if (!this.renderPreservedInPip || this.restoreInProgress) {
      return;
    }
    const size: RemoteSessionPipContentSize = this.currentPipContentSize();
    if (size.width === this.pipLastContentWidth && size.height === this.pipLastContentHeight) {
      return;
    }
    this.pipLastContentWidth = size.width;
    this.pipLastContentHeight = size.height;
    RemoteSessionPipService.getInstance().updateContentSize(size.width, size.height);
    hilog.info(RD_DOMAIN, RD_TAG, 'refreshActivePipContentSize: remote=' +
      size.width.toString() + 'x' + size.height.toString());
  }

  private schedulePipContentSizeRefresh(): void {
    this.clearPipContentSizeRefresh();
    // PIP preparation can precede the first decoded frame. Re-read native
    // diagnostics after attachment so the controller ratio follows the first
    // actual peer frame instead of the adaptive request dimensions.
    const delays: number[] = [0, 120, 300, 700, 1400, 2600];
    for (const delayMs of delays) {
      const timer: number = setTimeout((): void => {
        this.refreshActivePipContentSize();
      }, delayMs);
      this.pipContentSizeRefreshTimers.push(timer);
    }
  }

  async aboutToAppear(): Promise<void> {
    this.cancelPendingDisappearDecision();
    this.restoreRemoteSystemPointer('page-appear');
    this.proSync.init(getContext(this) as common.Context);
    this.physicalKeyboardLayout = RemoteKeyboardLayout.WINDOWS;
    this.physicalKeyboardLayoutConfirmed = false;
    this.physicalKeyboardLayoutPromptVisible = false;
    this.xComponentController.setListener(this);
    this.restoreRemoteDisplayScalePreference();
    this.registerInputDeviceWatcher();
    this.registerKeyboardAvoidListener();
    const params: Object = router.getParams();
    if (params) {
      const p: Record<string, Object> = params as Record<string, Object>;
      const vncHostId: string = (p['vncHostId'] as string) || '';
      if (vncHostId !== '') {
        const context: common.Context = getContext(this) as common.Context;
        this.vncSettings.init(context);
        this.vncHosts.init(context);
        this.vncGateways.init(context);
        this.vncTrust.init(context);
        const vncSettings: VncSettingsValues = this.vncSettings.get();
        this.vncControlMode = vncSettings.controlMode;
        this.vncShowDiagnostics = vncSettings.showDiagnostics;
        const vncHost: VncHostView | null = this.vncHosts.find(vncHostId);
        if (vncHost === null) {
          this.connecting = false;
          this.connectionError = 'VNC 主机不存在 [E-VNC-HOST-404]';
          return;
        }
        this.hostId = 'vnc:' + vncHost.id;
        this.pendingVncHost = vncHost;
        this.pendingHost = this.transientRemoteHostForVnc(vncHost);
        this.vncAuthResolved = false;
        this.vncTransientPassword = '';
        this.hostLabel = vncHost.label;
        this.preAuthenticatedSessionPending = false;
        this.applyDesktopKeyboardMouseMode();
        const handoffPassword: string = VncSessionCredentialHandoff.getInstance().take(
          vncHost.userId, vncHost.id);
        if (handoffPassword !== '') {
          this.vncPasswordStatus = 'available';
          this.vncTransientPassword = handoffPassword;
          this.vncAuthResolved = true;
          this.tryStartConnect();
        } else {
          this.prepareVncAuthentication();
        }
        return;
      }
      const id: string = p['hostId'] as string;
      if (id) {
        this.hostId = id;
        this.preAuthenticatedSessionPending = (p['rustdeskPreauthenticated'] as boolean) === true;
        const host: RemoteHost | undefined = this.srv.getHost(this.hostId);
        if (host) {
          this.hostLabel = host.label;

          // 主机锁验证 (若已在列表页验证过则跳过)
          const authenticated: boolean = (p['authenticated'] as boolean) === true;
          if (host.locked && !authenticated) {
            const r = await showLockGate(host.label, 'biometric');
            if (!r.ok) {
              this.connecting = false;
              const msg: string = lockGateErrorMessage(r);
              this.connectionError = msg || '身份验证未通过，已取消连接';
              return;
            }
          }

          // 保存 host 配置, 等 XComponent SurfaceId 绑定后再连接
          const resolvedHost: RemoteHost = this.hostWithResolvedCredential(host);
          this.pendingHost = this.hostWithRdpOneTimeCertificate(resolvedHost, p);
          if (this.pendingHost.protocol === 'rustdesk') {
            // Apply the mobile default before the auth sheet and Surface
            // startup. Otherwise a portrait window can remain visible until
            // the native connection reaches its success callback.
            await this.applyRustDeskOrientationPolicy('page-appear', true);
          }
          this.applyDesktopKeyboardMouseMode();
          const restoring: boolean = this.prepareRegistryRestore(host);
          if (restoring) {
            this.restoreFromBackground();
          } else if (this.isProRustDeskHost(this.pendingHost)) {
            this.openRustDeskAuthSheet();
          } else {
            this.tryStartConnect();
          }
        } else {
          this.connecting = false;
          this.connectionError = '主机不存在 [E-REMOTE-HOST-404]';
        }
      }
    }

    // 后台保活恢复: 使用实例变量 bgRestorePending 避免 AppStorage 时序竞争
    if (this.bgRestorePending && this.sessionId > 0) {
      hilog.info(RD_DOMAIN, RD_TAG, 'aboutToAppear: restoring from background preserve sessionId=' +
        this.sessionId.toString());
      this.restoreFromBackground();
    }
  }

  private onRustDeskDiagnosticsSettingChange(): void {
    if (this.shouldShowActiveDiagnostics()) {
      if (!this.rustDeskDiagnosticsDockInitialized) {
        this.initRustDeskDiagnosticsDock();
      }
      if (!this.shouldShowAdvancedDiagnostics()) {
        this.localResourceStats = EMPTY_LOCAL_RESOURCE_STATS;
      }
      this.startRustDeskDiagnosticsPolling();
    } else {
      this.rustDeskDiagnosticsDockExpanded = false;
      this.stopRustDeskDiagnosticsPolling(true);
    }
  }

  /**
   * 页面从后台恢复后 aboutToDisappear 已清空了诊断状态；恢复渲染器后
   * 必须重新建立本次 session 的轮询，否则基础面板和 Pro 本机采样都会停在空值。
   */
  private resumeRustDeskDiagnosticsAfterForeground(): void {
    if (!this.shouldShowActiveDiagnostics()) {
      return;
    }
    if (!this.rustDeskDiagnosticsDockInitialized) {
      this.initRustDeskDiagnosticsDock();
    }
    this.startRustDeskDiagnosticsPolling();
    hilog.info(RD_DOMAIN, RD_TAG, 'resumeRustDeskDiagnosticsAfterForeground: polling resumed sessionId=' +
      this.sessionId.toString() + ' attemptId=' + this.connectAttemptId.toString() +
      ' pro=' + (this.rustdeskShowProDiagnostics ? 'true' : 'false'));
  }

  private refreshRustDeskDiagnostics(sessionId: number, attemptId: number): void {
    if (!this.shouldShowActiveDiagnostics() ||
      this.sessionId !== sessionId || this.connectAttemptId !== attemptId) {
      return;
    }
    const snapshot: RustDeskDiagnosticsSnapshot = this.loader.getSessionDiagnostics(sessionId);
    // A synchronous native query must still be rejected if a reconnect
    // replaced the session between the poll guard and the assignment.
    if (this.sessionId !== sessionId || this.connectAttemptId !== attemptId ||
      snapshot.sessionId !== sessionId) {
      return;
    }
    this.rustDeskDiagnostics = snapshot;
    if (this.shouldShowAdvancedDiagnostics()) {
      this.localResourceStats = this.loader.getLocalResourceStats(true);
    } else {
      this.localResourceStats = EMPTY_LOCAL_RESOURCE_STATS;
    }
  }

  private startRustDeskDiagnosticsPolling(): void {
    if (this.rustDeskDiagnosticsTimer >= 0 ||
      !this.shouldShowActiveDiagnostics()) {
      return;
    }
    const observedSessionId: number = this.sessionId;
    const observedAttemptId: number = this.connectAttemptId;
    this.refreshRustDeskDiagnostics(observedSessionId, observedAttemptId);
    this.rustDeskDiagnosticsTimer = setInterval((): void => {
      if (!this.shouldShowActiveDiagnostics() ||
        this.sessionId !== observedSessionId || this.connectAttemptId !== observedAttemptId) {
        this.stopRustDeskDiagnosticsPolling(false);
        return;
      }
      this.refreshRustDeskDiagnostics(observedSessionId, observedAttemptId);
    }, 1000);
  }

  private stopRustDeskDiagnosticsPolling(reset: boolean): void {
    if (this.rustDeskDiagnosticsTimer >= 0) {
      clearInterval(this.rustDeskDiagnosticsTimer);
      this.rustDeskDiagnosticsTimer = -1;
    }
    if (reset) {
      this.rustDeskDiagnostics = EMPTY_RUSTDESK_DIAGNOSTICS;
      this.localResourceStats = EMPTY_LOCAL_RESOURCE_STATS;
      this.rustDeskDiagnosticsDockExpanded = false;
    }
  }

  aboutToDisappear(): void {
    this.releaseCanvasPinchInput('page-disappear');
    this.restoreRemoteSystemPointer('page-disappear');
    this.stopRustDeskDiagnosticsPolling(true);
    try {
      if (this.inputDeviceListenerRegistered) {
        inputDevice.off('change', this.inputDeviceListener);
        this.inputDeviceListenerRegistered = false;
      }
    } catch (_err) { /* ignore */ }

    // 路由感知策略 (T-252):
    // - 后台标志=true (EntryAbility.onWillBackground/onBackground 已触发) → 保活
    // - 页面先消失时，等待 Ability 生命周期信号再决定，避免误判成显式退出
    // - 确认不是后台切换后 → 完全断连
    const isBg: boolean = AppStorage.get<boolean>('remoteDesktopBgFlag') ?? false;
    if (isBg) {
      const action: RemoteDesktopBackgroundAction = decideRemoteDesktopBackgroundAction(
        true,
        this.connected,
        this.sessionId,
        this.bgRestorePending,
        this.cleanupStarted
      );
      if (action === RemoteDesktopBackgroundAction.detach) {
        // Home 手势 / 系统回桌面 → 后台保活
        hilog.info(RD_DOMAIN, RD_TAG, 'aboutToDisappear: background preserve (home gesture)');
        this.detachForBackground().catch((err: Error): void => {
          hilog.warn(RD_DOMAIN, RD_TAG, 'aboutToDisappear: background preserve failed: ' +
            (err.message ? err.message : JSON.stringify(err)));
        });
      } else {
        hilog.info(RD_DOMAIN, RD_TAG, 'aboutToDisappear: background skip action=' + action.toString());
      }
      this.cancelPendingDisappearDecision();
      return;
    }

    if (shouldDeferRemoteDesktopDisappear(
      isBg,
      this.connected,
      this.sessionId,
      this.bgRestorePending,
      this.cleanupStarted
    )) {
      this.deferDisappearDecision();
      return;
    }

    // 显式 back / 左右滑退出 / 断开按钮 → 完全断连
    this.cancelPendingDisappearDecision();
    hilog.info(RD_DOMAIN, RD_TAG, 'aboutToDisappear: full disconnect reason=explicit-exit');
    this.disconnectAndCleanup('explicit-exit');
  }

  private tryStartConnect(): void {
    if (this.restoreInProgress) {
      hilog.info(RD_DOMAIN, RD_TAG, 'tryStartConnect: waiting for foreground restore teardown');
      return;
    }
    // 后台恢复路径: 协议连接仍存在, 只需重建渲染
    // 使用 bgRestorePending 实例变量, 不受 AppStorage/onForeground 时序影响
    if (this.bgRestorePending && this.sessionId > 0 && this.surfaceReady && !this.cleanupStarted) {
      hilog.info(RD_DOMAIN, RD_TAG, 'tryStartConnect: background restore — reattaching renderer only');
      this.doBackgroundRestoreRender();
      return;
    }

    if (this.connectStarted || !this.pendingHost || this.connected || !this.connecting ||
      this.showRustDeskAuthSheet || this.showVncPasswordSheet ||
      (this.isVncSession() && !this.vncAuthResolved)) {
      return;
    }
    this.resetRemoteImeSession('session-connect');
    if (!this.surfaceReady) {
      hilog.info(RD_DOMAIN, RD_TAG, 'tryStartConnect: surfaceReady=false, 等待 SurfaceId 回调');
      return;
    }
    this.connectStarted = true;
    hilog.info(RD_DOMAIN, RD_TAG, 'XComponent surface ready, starting connect: proto=' +
      this.pendingHost.protocol + ' host=' + maskHost(this.pendingHost.host));
    this.doConnect(this.pendingHost);
  }

  private desktopSize(host: RemoteHost | null): DesktopSize {
    if (!host) {
      return { width: 1920, height: 1080, colorDepth: 32, multiMonitor: false, monitorCount: 1 };
    }
    const display = host.displayConfig;
    if (host.protocol === 'rustdesk') {
      const adaptive: DesktopSize | null = this.adaptiveSurfaceSize(
        RUSTDESK_ADAPTIVE_MAX_EDGE_PX, false);
      if (adaptive) {
        adaptive.colorDepth = display.colorDepth > 0 ? display.colorDepth : 32;
        hilog.info(RD_DOMAIN, RD_TAG, 'RustDesk adaptive size=' + adaptive.width.toString() + 'x' +
          adaptive.height.toString() + ' surfacePx=' + this.renderWidthPx.toString() + 'x' +
          this.renderHeightPx.toString());
        return adaptive;
      }
    }
    if (host.protocol === 'rdp') {
      const legacyPreset: number = AppStorage.get<number>('rdpDesktopPreset') ?? 1;
      const resolutionId: string = normalizeRdpResolutionId(
        AppStorage.get<string>('rdpDesktopResolutionId') ?? '', legacyPreset);
      const colorDepthPref: number = AppStorage.get<number>('rdpColorDepth') ?? 32;
      const colorDepth: number = colorDepthPref === 16 || colorDepthPref === 24 ? colorDepthPref : 32;
      if (resolutionId === 'auto') {
        const adaptiveRdp: DesktopSize | null = this.adaptiveSurfaceSize(3840);
        if (adaptiveRdp) {
          adaptiveRdp.colorDepth = colorDepth;
          hilog.info(RD_DOMAIN, RD_TAG, 'RDP adaptive size=' + adaptiveRdp.width.toString() + 'x' +
            adaptiveRdp.height.toString() + ' colorDepth=' + colorDepth.toString());
          return adaptiveRdp;
        }
      }
      const preset = rdpResolutionPresetForId(resolutionId);
      const width: number = preset !== null ? preset.width : 1920;
      const height: number = preset !== null ? preset.height : 1080;
      hilog.info(RD_DOMAIN, RD_TAG, 'RDP preset size=' + width.toString() + 'x' +
        height.toString() + ' colorDepth=' + colorDepth.toString());
      if (display.multiMonitor) {
        hilog.warn(RD_DOMAIN, RD_TAG,
          'RDP multimon disabled for stable video path; saved display.multiMonitor=true monitorCount=' +
            display.monitorCount.toString());
      }
      return {
        width: width,
        height: height,
        colorDepth: colorDepth,
        multiMonitor: false,
        monitorCount: 1
      };
    }
    return {
      width: display.width > 0 ? display.width : 1920,
      height: display.height > 0 ? display.height : 1080,
      colorDepth: display.colorDepth > 0 ? display.colorDepth : 32,
      multiMonitor: display.multiMonitor,
      monitorCount: display.monitorCount > 0 ? display.monitorCount : 1
    };
  }

  private remoteProtocolOf(host: RemoteHost): RemoteProtocol {
    if (host.protocol === 'rustdesk') {
      return RemoteProtocol.rustdesk;
    }
    if (host.protocol === 'ssh') {
      return RemoteProtocol.ssh;
    }
    if (host.protocol === 'vnc') {
      return RemoteProtocol.vnc;
    }
    return RemoteProtocol.rdp;
  }

  private recordActiveSession(host: RemoteHost, sessionId: number, renderAttached: boolean): void {
    if (host.protocol === 'vnc') {
      // VNC deliberately does not enter the shared PIP/background registry;
      // its raw framebuffer has no decoder-safe background migration path.
      return;
    }
    const now: number = Date.now();
    const record: ActiveRemoteSessionRecord = {
      sessionId: sessionId,
      hostId: host.id,
      protocol: this.remoteProtocolOf(host),
      hostAddress: host.host,
      protocolConnected: true,
      renderAttached: renderAttached,
      restoreNeeded: !renderAttached,
      latestSurfaceId: this.latestSurfaceId,
      createdAtMs: now,
      updatedAtMs: now
    };
    this.activeSessionRegistry.setActive(record);
  }

  /**
   * Register PIP while the foreground page is still visible. The background
   * lifecycle only waits for HarmonyOS to auto-start the prepared controller.
   */
  private async prepareRemoteSessionPipForForeground(host: RemoteHost,
    sessionId: number): Promise<void> {
    if (host.protocol === 'vnc') {
      return;
    }
    const liveViewEnabled: boolean = AppStorage.get<boolean>('liveViewEnabled') ?? true;
    const liveViewMode: number = AppStorage.get<number>('liveViewMode') ?? 1;
    const activeSession: ActiveRemoteSessionRecord | null = this.activeSessionRegistry.getActive();
    const sessionActive: boolean = this.connected && this.sessionId === sessionId &&
      activeSession !== null && activeSession.sessionId === sessionId &&
      activeSession.hostId === host.id && activeSession.protocolConnected;
    const canPrepare: boolean = shouldPrepareRemoteSessionPip(
      liveViewEnabled, liveViewMode, sessionActive,
      this.rendererHandle > 0, this.surfaceReady);
    if (!canPrepare) {
      // A transient frame gap during connection must not revoke a controller
      // that the next background transition still needs.
      if (!sessionActive || !liveViewEnabled || liveViewMode !== LiveViewMode.AVSESSION) {
        await RemoteSessionPipService.getInstance().stop();
      }
      return;
    }
    try {
      const uiContext = this.getUIContext();
      const context: common.UIAbilityContext = uiContext.getHostContext() as common.UIAbilityContext;
      const pipSize: RemoteSessionPipContentSize = this.currentPipContentSize();
      const prepared: boolean = await RemoteSessionPipService.getInstance().prepare(
        context, uiContext, pipSize.width, pipSize.height,
        (reason: string): void => this.handleRemoteSessionPipStopped(reason),
        (surface: RemoteSessionPipSurface): void => this.handlePipSurfaceChanged(surface));
      hilog.info(RD_DOMAIN, RD_TAG, 'prepareRemoteSessionPipForForeground: prepared=' +
        prepared.toString() + ' sessionId=' + sessionId.toString());
    } catch (err) {
      hilog.warn(RD_DOMAIN, RD_TAG, 'prepareRemoteSessionPipForForeground: failed ' +
        JSON.stringify(err));
    }
  }

  private async startRemoteSessionBackgroundTask(ctx: common.UIAbilityContext,
    info: RemoteSessionBgInfo): Promise<boolean> {
    const started: boolean = await RemoteSessionBackgroundTaskService.getInstance().startSessionTask(ctx, info);
    if (!started) {
      return false;
    }
    if (info.hasAudio || info.hasVideo) {
      await RemoteSessionBackgroundTaskService.getInstance().startAudioPlaybackTask(ctx, info);
    }
    return true;
  }

  /**
   * 启动后台媒体身份 (仅在退后台时调用)。
   * 有真实音频或视频活动时优先使用 AVSession；系统拒绝时由服务
   * 降级到普通后台通知。实际视频帧由 PIP free-node surface 承载。
   */
  private async startSessionLiveView(ctx: common.UIAbilityContext,
    info: RemoteSessionBgInfo): Promise<void> {
    try {
      const liveViewInfo: LiveViewConnectionInfo = {
        hostId: info.hostId,
        sessionId: info.sessionId,
        protocolLabel: info.protocolLabel,
        hostAddress: info.hostAddress,
        hasAudio: info.hasAudio,
        hasVideo: info.hasVideo,
        mediaKind: resolveRemoteSessionMediaKind({
          hasAudio: info.hasAudio,
          hasVideo: info.hasVideo
        }),
        connectedAtMs: Date.now()
      };

      const service: RemoteSessionLiveViewService = RemoteSessionLiveViewService.getInstance();
      const started: boolean = await service.reconcile(ctx, liveViewInfo);
      if (!started || !service.isActive()) {
        hilog.warn(RD_DOMAIN, RD_TAG, 'startSessionLiveView: strategy did not start; suppress success log' +
          ' protocol=' + info.protocolLabel);
        return;
      }

      // 如果有音频, AVSession 策略启动后注入静音回调
      if (info.hasAudio) {
        service.setMuteCommandCallback((mute: boolean): void => {
          this.setRemoteAudioMute(mute);
        });
      }

      hilog.info(RD_DOMAIN, RD_TAG, 'startSessionLiveView: background media active protocol=' +
        info.protocolLabel + ' hasAudio=' + (info.hasAudio ? 'true' : 'false') +
        ' hasVideo=' + (info.hasVideo ? 'true' : 'false'));
    } catch (err) {
      hilog.warn(RD_DOMAIN, RD_TAG, 'startSessionLiveView: failed: ' + JSON.stringify(err));
    }
  }

  /**
   * 设置远端音频静音状态。
   * 由 AVSession 播控中心 play/pause 命令触发。
   */
  private setRemoteAudioMute(mute: boolean): void {
    try {
      const audioHandle: number = this.loader.getAudioPlayerHandle();
      if (audioHandle > 0) {
        this.loader.setAudioMute(audioHandle, mute);
        hilog.info(RD_DOMAIN, RD_TAG, 'setRemoteAudioMute: mute=' + (mute ? 'true' : 'false') +
          ' handle=' + audioHandle.toString());
      } else {
        hilog.warn(RD_DOMAIN, RD_TAG, 'setRemoteAudioMute: audio handle invalid, skip');
      }
    } catch (err) {
      hilog.warn(RD_DOMAIN, RD_TAG, 'setRemoteAudioMute: failed: ' + JSON.stringify(err));
    }
  }

  /**
   * 停止后台媒体身份和 PIP (前台恢复或断连时调用)。
   */
  private async stopSessionLiveView(ctx: common.UIAbilityContext): Promise<void> {
    try {
      await RemoteSessionLiveViewService.getInstance().stop(ctx);
      hilog.info(RD_DOMAIN, RD_TAG, 'stopSessionLiveView: background media stopped');
    } catch (err) {
      hilog.warn(RD_DOMAIN, RD_TAG, 'stopSessionLiveView: failed: ' + JSON.stringify(err));
    }
    // Keep PIP teardown independent from AVSession cleanup. A failed media
    // identity stop must not leave an auto-start controller armed.
    try {
      const stopped: boolean = await RemoteSessionPipService.getInstance().stop();
      if (!stopped) {
        throw new Error('PIP controller did not reach terminal state');
      }
    } catch (err) {
      hilog.warn(RD_DOMAIN, RD_TAG, 'stopSessionLiveView: PIP stop failed: ' + JSON.stringify(err));
      throw new Error('PIP controller stop failed [E-PIP-STOP]');
    }
  }

  private startBackgroundAudioPolling(ctx: common.UIAbilityContext, info: RemoteSessionBgInfo): void {
    this.stopBackgroundAudioPolling();
    this.backgroundSessionInfo = info;
    this.backgroundHasAudio = info.hasAudio;
    this.backgroundHasVideo = info.hasVideo;
    this.backgroundAudioPollTimer = setInterval((): void => {
      this.refreshBackgroundAudioState(ctx);
    }, 1500);
  }

  private stopBackgroundAudioPolling(): void {
    if (this.backgroundAudioPollTimer >= 0) {
      clearInterval(this.backgroundAudioPollTimer);
      this.backgroundAudioPollTimer = -1;
    }
    this.backgroundSessionInfo = null;
    this.backgroundHasAudio = false;
    this.backgroundHasVideo = false;
  }

  private isRdpRemoteSession(): boolean {
    return this.pendingHost !== null && this.pendingHost.protocol === 'rdp';
  }

  /**
   * RDP has no decoder handle. A staged GDI frame is the source of truth for
   * whether its frame pump can populate a newly attached PIP surface.
   */
  private isRdpVideoFrameReady(): boolean {
    if (!this.isRdpRemoteSession() || this.sessionId <= 0) {
      return false;
    }
    try {
      const stats: RdpRenderStats = this.loader.getRdpRenderStats(this.sessionId);
      // Legacy GDI sessions can present valid frames before the graphics
      // lifecycle has published desktop dimensions. The owned frame counters
      // are the readiness signal; requiring graphics metadata here blocks RDP
      // PIP while the frame pump is already usable.
      return hasRdpRemoteSessionPipFrame(stats.paintCount, stats.lastRenderBytes);
    } catch (_e) {
      return false;
    }
  }

  private isCurrentVideoReadyForPip(): boolean {
    const protocol: string = this.pendingHost !== null ? this.pendingHost.protocol : '';
    if (protocol === 'vnc') {
      return false;
    }
    return hasRemoteSessionPipVideo(
      protocol,
      this.rendererHandle > 0,
      this.surfaceReady,
      this.decoderHandle > 0,
      this.isRdpVideoFrameReady());
  }

  /** A PIP transfer must not detach the foreground renderer before a real
   * remote frame has reached the protocol-specific frame store. */
  private isPipFrameReady(): boolean {
    if (this.isRdpRemoteSession()) {
      return this.isRdpVideoFrameReady();
    }
    if (this.pendingHost === null || this.pendingHost.protocol !== 'rustdesk' || this.sessionId <= 0) {
      return false;
    }
    try {
      const diagnostics: RustDeskDiagnosticsSnapshot = this.loader.getRustDeskDiagnostics(this.sessionId);
      return diagnostics.videoSeen && diagnostics.receivedFrames > 0 &&
        diagnostics.width > 0 && diagnostics.height > 0;
    } catch (_e) {
      return false;
    }
  }

  private async waitForPipFrameReady(operationGeneration: number,
    timeoutMs: number = 5000): Promise<boolean> {
    const startedAtMs: number = Date.now();
    const pipService: RemoteSessionPipService = RemoteSessionPipService.getInstance();
    while (Date.now() - startedAtMs < timeoutMs) {
      if (this.restoreInProgress || !this.cleanupStarted ||
        !pipService.isOperationCurrent(operationGeneration)) {
        return false;
      }
      if (this.isPipFrameReady()) {
        return true;
      }
      await new Promise<void>((resolve: () => void): void => {
        setTimeout(resolve, 50);
      });
    }
    return !this.restoreInProgress && this.cleanupStarted &&
      pipService.isOperationCurrent(operationGeneration) && this.isPipFrameReady();
  }

  private currentRemoteMediaSnapshot(): RemoteSessionMediaSnapshot {
    return {
      hasAudio: this.loader.isAudioActive(),
      hasVideo: this.isRdpRemoteSession() ? this.isRdpVideoFrameReady() : this.loader.isVideoActive()
    };
  }

  private resolveCurrentBackgroundVideoPrewarmMode(media: RemoteSessionMediaSnapshot):
    BackgroundVideoPrewarmMode {
    const liveViewEnabled: boolean = AppStorage.get<boolean>('liveViewEnabled') ?? true;
    const liveViewMode: number = AppStorage.get<number>('liveViewMode') ?? 1;
    return resolveBackgroundVideoPrewarmMode({
      liveViewEnabled: liveViewEnabled,
      liveViewMode: liveViewMode,
      appBackgrounded: true,
      protocolConnected: this.sessionId > 0 && (this.connected || this.connectStarted || this.bgRestorePending),
      protocol: this.pendingHost !== null ? this.pendingHost.protocol : '',
      hasAudio: media.hasAudio,
      hasVideo: media.hasVideo
    });
  }

  private applyBackgroundVideoPrewarm(media: RemoteSessionMediaSnapshot, reason: string): BackgroundVideoPrewarmMode {
    const mode: BackgroundVideoPrewarmMode = this.resolveCurrentBackgroundVideoPrewarmMode(media);
    const intervalMs: number = backgroundVideoPrewarmIntervalMs(mode);
    const protocol: string = this.pendingHost !== null ? this.pendingHost.protocol : '';
    if (protocol === 'rdp' && this.sessionId > 0) {
      const enabled: boolean = mode === BackgroundVideoPrewarmMode.LOW_FPS_PREWARM;
      const ok: boolean = this.loader.setRdpBackgroundVideoPrewarm(this.sessionId, enabled, intervalMs);
      hilog.info(RD_DOMAIN, RD_TAG, 'background prewarm rdp reason=' + reason +
        ' mode=' + mode.toString() + ' enabled=' + enabled.toString() +
        ' ok=' + ok.toString());
    } else {
      hilog.info(RD_DOMAIN, RD_TAG, 'background prewarm decision reason=' + reason +
        ' protocol=' + protocol + ' mode=' + mode.toString());
    }
    return mode;
  }

  private disableRdpBackgroundVideoPrewarm(reason: string): void {
    if (this.pendingHost !== null && this.pendingHost.protocol === 'rdp' && this.sessionId > 0) {
      const ok: boolean = this.loader.setRdpBackgroundVideoPrewarm(this.sessionId, false, 0);
      hilog.info(RD_DOMAIN, RD_TAG, 'background prewarm rdp disabled reason=' + reason +
        ' ok=' + ok.toString());
    }
  }

  private clearRestoreFrameRefreshPump(): void {
    for (let i = 0; i < this.restoreFrameRefreshTimers.length; i++) {
      clearTimeout(this.restoreFrameRefreshTimers[i]);
    }
    this.restoreFrameRefreshTimers = [];
  }

  private scheduleRestoreFrameRefreshPump(): void {
    this.clearRestoreFrameRefreshPump();
    const delays: number[] = getRestoreFrameRefreshDelaysMs();
    for (let i = 0; i < delays.length; i++) {
      const delayMs: number = delays[i];
      const timer: number = setTimeout((): void => {
        this.runRestoreFrameRefresh(delayMs);
      }, delayMs);
      this.restoreFrameRefreshTimers.push(timer);
    }
    hilog.info(RD_DOMAIN, RD_TAG, 'scheduleRestoreFrameRefreshPump: attempts=' +
      delays.length.toString());
  }

  private runRestoreFrameRefresh(delayMs: number): void {
    if (this.cleanupStarted || !this.connected) {
      hilog.info(RD_DOMAIN, RD_TAG, 'runRestoreFrameRefresh: skip delay=' +
        delayMs.toString() + ' connected=' + (this.connected ? 'true' : 'false') +
        ' renderer=' + this.rendererHandle.toString());
      return;
    }
    const action: RestoreRefreshAction = restoreRefreshActionForDelay(delayMs);
    if (shouldRebindSurfaceForRestore(action, this.rendererHandle)) {
      const desktop: DesktopSize = this.desktopSize(this.pendingHost);
      const pageSurface: RemoteSessionPipContentSize = this.currentPageSurfaceSize(desktop.width, desktop.height);
      const surfaceId: string = this.latestSurfaceId.length > 0 ? this.latestSurfaceId : this.xcId;
      const result = this.loader.reattachRenderForForeground(surfaceId, pageSurface.width, pageSurface.height);
      if (result.ok && result.value !== undefined && result.value > 0) {
        this.rendererHandle = result.value;
        this.nativeHandles.markSurfaceAttached(this.rendererHandle);
        if (this.decoderHandle > 0) {
          this.loader.bindVideoPipeline(this.decoderHandle, this.rendererHandle);
          const recoveryArmed: boolean = this.loader.requestDecoderRecovery();
          hilog.info(RD_DOMAIN, RD_TAG, 'runRestoreFrameRefresh: decoder recovery armed=' +
            (recoveryArmed ? 'true' : 'false') + ' delay=' + delayMs.toString());
        }
        this.activeSessionRegistry.markRenderAttached(surfaceId);
        hilog.info(RD_DOMAIN, RD_TAG, 'runRestoreFrameRefresh: surface rebound delay=' +
          delayMs.toString() + ' renderer=' + this.rendererHandle.toString());
      } else {
        hilog.warn(RD_DOMAIN, RD_TAG, 'runRestoreFrameRefresh: surface rebind failed delay=' +
          delayMs.toString() + ' code=' + result.code + ' msg=' + result.message);
      }
    } else if (action === RestoreRefreshAction.REBIND_SURFACE && this.rendererHandle > 0) {
      if (this.decoderHandle > 0) {
        this.loader.bindVideoPipeline(this.decoderHandle, this.rendererHandle);
        const recoveryArmed: boolean = this.loader.requestDecoderRecovery();
        hilog.info(RD_DOMAIN, RD_TAG, 'runRestoreFrameRefresh: decoder recovery armed=' +
          (recoveryArmed ? 'true' : 'false') + ' delay=' + delayMs.toString());
      }
      hilog.info(RD_DOMAIN, RD_TAG, 'runRestoreFrameRefresh: renderer already attached delay=' +
        delayMs.toString() + ' renderer=' + this.rendererHandle.toString());
    }
    if (action === RestoreRefreshAction.REPORT_STALLED) {
      hilog.warn(RD_DOMAIN, RD_TAG, 'runRestoreFrameRefresh: restore still stalled after ' +
        delayMs.toString() + 'ms');
    }
    const refresh = this.loader.requestFrameRefresh();
    if (!refresh.ok) {
      hilog.warn(RD_DOMAIN, RD_TAG, 'runRestoreFrameRefresh: failed delay=' +
        delayMs.toString() + ' code=' + refresh.code + ' msg=' + refresh.message);
      return;
    }
    hilog.info(RD_DOMAIN, RD_TAG, 'runRestoreFrameRefresh: requested delay=' +
      delayMs.toString());
  }

  private refreshBackgroundAudioState(ctx: common.UIAbilityContext): void {
    if (!this.bgRestorePending || this.backgroundSessionInfo === null) {
      this.stopBackgroundAudioPolling();
      return;
    }
    const media: RemoteSessionMediaSnapshot = this.currentRemoteMediaSnapshot();
    if (media.hasAudio === this.backgroundHasAudio && media.hasVideo === this.backgroundHasVideo) {
      return;
    }
    this.backgroundHasAudio = media.hasAudio;
    this.backgroundHasVideo = media.hasVideo;
    this.applyBackgroundVideoPrewarm(media, 'background-media-update');
    const nextInfo: RemoteSessionBgInfo = {
      hostId: this.backgroundSessionInfo.hostId,
      sessionId: this.backgroundSessionInfo.sessionId,
      resumeRemoteSession: this.backgroundSessionInfo.resumeRemoteSession,
      protocolLabel: this.backgroundSessionInfo.protocolLabel,
      hostAddress: this.backgroundSessionInfo.hostAddress,
      hasAudio: media.hasAudio,
      hasVideo: media.hasVideo
    };
    this.backgroundSessionInfo = nextInfo;
    RemoteSessionBackgroundTaskService.getInstance().updateAudioPlaybackMode(ctx, nextInfo)
      .catch((err: Error): void => {
        hilog.warn(RD_DOMAIN, RD_TAG, 'refreshBackgroundAudioState: background mode update failed: ' +
          (err.message ? err.message : JSON.stringify(err)));
      });
    this.startSessionLiveView(ctx, nextInfo).catch((err: Error): void => {
      hilog.warn(RD_DOMAIN, RD_TAG, 'refreshBackgroundAudioState: live view update failed: ' +
        (err.message ? err.message : JSON.stringify(err)));
    });
    hilog.info(RD_DOMAIN, RD_TAG, 'refreshBackgroundAudioState: hasAudio=' +
      (media.hasAudio ? 'true' : 'false') + ' hasVideo=' +
      (media.hasVideo ? 'true' : 'false'));
  }

  private prepareRegistryRestore(host: RemoteHost): boolean {
    const active: ActiveRemoteSessionRecord | null = this.activeSessionRegistry.getActive();
    if (active === null || active.hostId !== host.id || !active.protocolConnected || !active.restoreNeeded) {
      return false;
    }
    this.sessionId = active.sessionId;
    this.bgRestorePending = true;
    this.cleanupStarted = false;
    this.connectStarted = false;
    this.connected = false;
    this.latestSurfaceId = active.latestSurfaceId;
    hilog.info(RD_DOMAIN, RD_TAG, 'prepareRegistryRestore: sessionId=' +
      active.sessionId.toString() + ' hostId=' + active.hostId);
    return true;
  }

  private updateRemoteSize(desktop: DesktopSize): void {
    this.remoteWidth = Math.max(1, desktop.width);
    this.remoteHeight = Math.max(1, desktop.height);
    if (!this.remoteCursorReady) {
      const centerX: number = Math.round(this.remoteWidth / 2);
      const centerY: number = Math.round(this.remoteHeight / 2);
      this.applyRemoteCursorMotionState(createRemoteCursorMotionState(centerX, centerY));
    } else {
      this.applyRemoteCursorMotionState(this.remoteCursorMotion);
    }
  }

  /** Disabling local canvas zoom must not leave its last enlarged transform on screen. */
  private onCanvasGestureZoomSettingChange(): void {
    this.releaseCanvasPinchInput('zoom-setting-change');
    if (!this.canvasGestureZoomEnabled && this.canvasTransformGestureModified) {
      this.resetCanvasToDisplayDefault();
    }
  }

  onBackPress(): boolean {
    if (this.sessionId <= 0 || !shouldConsumeRemoteBack(this.connected, this.isDesktopDevice,
      this.breakpoint, this.isKeyboardMouseControlMode(), this.physicalKeyboardConnected,
      this.hardwareKeyboardProxyActive)) {
      return false;
    }
    // PC 键盘的 Ctrl+Back/Meta+Back 可能被系统解释为页面返回。远控期间
    // 页面退出只允许走明确的断开按钮，避免系统快捷键销毁协议会话。
    this.releaseAllHeldKeys();
    this.scheduleRemoteInputFocus('back-consumed');
    hilog.info(RD_DOMAIN, RD_TAG, 'remote-back-consumed connected=1');
    promptAction.showToast({ message: '远程连接中，请使用断开按钮退出', duration: 1200 });
    return true;
  }

  private clampRemotePreciseX(x: number): number {
    const maxX: number = Math.max(0, (this.remoteWidth > 0 ? this.remoteWidth : 1280) - 1);
    return Math.max(0, Math.min(maxX, Number.isFinite(x) ? x : 0));
  }

  private clampRemotePreciseY(y: number): number {
    const maxY: number = Math.max(0, (this.remoteHeight > 0 ? this.remoteHeight : 720) - 1);
    return Math.max(0, Math.min(maxY, Number.isFinite(y) ? y : 0));
  }

  private clampRemoteX(x: number): number {
    const maxX: number = Math.max(0, (this.remoteWidth > 0 ? this.remoteWidth : 1280) - 1);
    return Math.max(0, Math.min(maxX, Math.round(x)));
  }

  private clampRemoteY(y: number): number {
    const maxY: number = Math.max(0, (this.remoteHeight > 0 ? this.remoteHeight : 720) - 1);
    return Math.max(0, Math.min(maxY, Math.round(y)));
  }

  private setDisplayedRemoteCursor(x: number, y: number): void {
    const previousX: number = this.remoteCursorX;
    const previousY: number = this.remoteCursorY;
    const previousReady: boolean = this.remoteCursorReady;
    this.remoteCursorPreciseX = this.clampRemotePreciseX(x);
    this.remoteCursorPreciseY = this.clampRemotePreciseY(y);
    this.remoteCursorX = this.clampRemoteX(this.remoteCursorPreciseX);
    this.remoteCursorY = this.clampRemoteY(this.remoteCursorPreciseY);
    this.remoteCursorReady = true;
    this.invalidateRemoteCursorViewIfChanged(previousX, previousY, previousReady);
  }

  private clampRemoteCursorMotionState(state: RemoteCursorMotionState): RemoteCursorMotionState {
    return {
      displayX: this.clampRemotePreciseX(state.displayX),
      displayY: this.clampRemotePreciseY(state.displayY),
      localTargetX: this.clampRemotePreciseX(state.localTargetX),
      localTargetY: this.clampRemotePreciseY(state.localTargetY),
      remoteObservedX: this.clampRemotePreciseX(state.remoteObservedX),
      remoteObservedY: this.clampRemotePreciseY(state.remoteObservedY),
      remoteReady: state.remoteReady,
      owner: state.owner,
      localGestureActive: state.localGestureActive,
      localLastInputAtMs: state.localLastInputAtMs,
      localSettlingUntilMs: state.localSettlingUntilMs,
      remoteObservedAtMs: state.remoteObservedAtMs
    };
  }

  private applyRemoteCursorMotionState(state: RemoteCursorMotionState): void {
    this.remoteCursorMotion = this.clampRemoteCursorMotionState(state);
    this.setDisplayedRemoteCursor(this.remoteCursorMotion.displayX, this.remoteCursorMotion.displayY);
  }

  /** Update the local display without claiming a peer acknowledgement. */
  private rememberRemoteCursor(x: number, y: number): void {
    this.applyRemoteCursorMotionState(applyLocalCursorTarget(this.remoteCursorMotion,
      this.clampRemotePreciseX(x), this.clampRemotePreciseY(y), Date.now()));
  }

  private setRemoteCursorPrediction(x: number, y: number): void {
    this.rememberRemoteCursor(x, y);
  }

  /**
   * Record a protocol-native position independently from local touchpad
   * output. The policy deliberately rejects the former unsequenced ACK
   * heuristic: a delayed coordinate must not pull an active pointer backward.
   */
  private applyAuthoritativeRemoteCursor(x: number, y: number): void {
    this.applyRemoteCursorMotionState(observeRemoteCursorPosition(this.remoteCursorMotion,
      this.clampRemotePreciseX(x), this.clampRemotePreciseY(y), Date.now()));
  }

  private invalidateRemoteCursorViewIfChanged(previousX: number, previousY: number,
    previousReady: boolean): void {
    if (remoteCursorSnapshotChanged(previousX, previousY, previousReady, this.remoteCursorX,
      this.remoteCursorY, this.remoteCursorReady)) {
      this.requestRemoteCursorViewRefresh();
    }
  }

  /**
   * Touch events can arrive faster than ArkUI can present. Keep the latest
   * cursor coordinates in plain fields and commit one visual revision per
   * frame, so pointer updates cannot turn into a high-frequency page rebuild
   * competing with the remote video XComponent.
   */
  private requestRemoteCursorViewRefresh(immediate: boolean = false): void {
    if (immediate) {
      this.clearRemoteCursorViewCommit();
      this.remoteCursorViewRevision += 1;
      this.publishRemoteCursorOverlay();
      return;
    }
    if (this.remoteCursorViewCommitPending) {
      return;
    }
    this.remoteCursorViewCommitPending = true;
    this.remoteCursorViewCommitTimer = setTimeout((): void => {
      this.remoteCursorViewCommitTimer = -1;
      this.remoteCursorViewCommitPending = false;
      this.remoteCursorViewRevision += 1;
      this.publishRemoteCursorOverlay();
    }, REMOTE_CURSOR_RENDER_FRAME_MS);
  }

  private clearRemoteCursorViewCommit(): void {
    if (this.remoteCursorViewCommitTimer >= 0) {
      clearTimeout(this.remoteCursorViewCommitTimer);
      this.remoteCursorViewCommitTimer = -1;
    }
    this.remoteCursorViewCommitPending = false;
  }

  private resetTouchpadPointerCurve(): void {
    this.touchpadCurveState = resetTouchpadPointerCurveState();
  }

  /**
   * A single TouchEvent must not be able to teleport the virtual pointer.
   * Large deltas usually mean that the surface was resized/reparented or that
   * the event stream resumed with a new local coordinate origin.  Normal fast
   * swipes stay well below this guard; the next event is re-anchored instead of
   * sending the discontinuity to the remote host.
   */
  private touchpadStepLimit(): number {
    const width: number = this.surfaceWidth > 0 ? this.surfaceWidth : 0;
    const height: number = this.surfaceHeight > 0 ? this.surfaceHeight : 0;
    const smallestEdge: number = Math.min(width, height);
    if (!Number.isFinite(smallestEdge) || smallestEdge <= 0) {
      return TOUCHPAD_MAX_LOCAL_STEP_VP;
    }
    return Math.min(TOUCHPAD_MAX_LOCAL_STEP_VP,
      Math.max(160, smallestEdge * TOUCHPAD_MAX_LOCAL_STEP_RATIO));
  }

  private isTouchpadStepDiscontinuity(stepDx: number, stepDy: number): boolean {
    const distance: number = Math.sqrt(stepDx * stepDx + stepDy * stepDy);
    return !Number.isFinite(distance) || distance > this.touchpadStepLimit();
  }

  private logTouchpadCurve(stepDx: number, stepDy: number, dtMs: number,
    curveGain: number, effectiveGain: number, remoteDx: number, remoteDy: number,
    nextX: number, nextY: number, discontinuity: boolean = false): void {
    const now: number = Date.now();
    if (!discontinuity && this.lastTouchpadCurveLogMs > 0 &&
      now - this.lastTouchpadCurveLogMs < INPUT_LOG_SAMPLE_MS) {
      return;
    }
    this.lastTouchpadCurveLogMs = now;
    hilog.info(RD_DOMAIN, RD_TAG, 'touchpad-curve dx=' + stepDx.toFixed(2) +
      ' dy=' + stepDy.toFixed(2) + ' dt=' + dtMs.toString() +
      ' gain=' + curveGain.toFixed(3) + ' effective=' + effectiveGain.toFixed(3) +
      ' remoteDelta=' + remoteDx.toFixed(2) + ',' + remoteDy.toFixed(2) +
      ' prediction=' + nextX.toFixed(2) + ',' + nextY.toFixed(2) +
      ' pending=' + (this.pendingMouseMoveValid ? '1' : '0') +
      ' inFlight=' + (this.localMouseMoveInFlight ? '1' : '0') +
      ' remoteObserved=' + this.remoteCursorMotion.remoteObservedX.toFixed(2) + ',' +
      this.remoteCursorMotion.remoteObservedY.toFixed(2) +
      ' owner=' + this.remoteCursorMotion.owner + ' remote=' + this.remoteWidth.toString() +
      'x' + this.remoteHeight.toString() + ' surface=' +
      Math.round(this.surfaceWidth).toString() + 'x' + Math.round(this.surfaceHeight).toString() +
      ' discontinuity=' + (discontinuity ? '1' : '0'));
  }

  private updateRendererViewportCacheForCanvasTransform(viewport: CanvasViewport): void {
    const sourceWidth: number = Math.max(1, viewport.sourceWidth);
    const sourceHeight: number = Math.max(1, viewport.sourceHeight);
    const surfaceWidth: number = Math.max(1, viewport.surfaceWidth);
    const surfaceHeight: number = Math.max(1, viewport.surfaceHeight);
    const contain: number = Math.min(surfaceWidth / sourceWidth, surfaceHeight / sourceHeight);
    const physicalScale: number = contain * Math.max(0.01,
      Math.min(CANVAS_TRANSFORM_MAX_SCALE, this.canvasTransform.scale));
    const viewportW: number = Math.max(1, Math.round(sourceWidth * physicalScale));
    const viewportH: number = Math.max(1, Math.round(sourceHeight * physicalScale));
    this.rendererViewportCache = {
      transformVersion: this.rendererCanvasTransformPendingVersion,
      sourceWidth,
      sourceHeight,
      surfaceWidth,
      surfaceHeight,
      viewportX: Math.round((surfaceWidth - viewportW) / 2 + this.canvasTransform.panX),
      viewportY: Math.round((surfaceHeight - viewportH) / 2 + this.canvasTransform.panY),
      viewportW,
      viewportH
    };
    this.rendererViewportCacheHandle = this.rendererHandle;
    this.rendererViewportReadAtMs = Date.now();
  }

  private invalidateRendererViewportCache(): void {
    this.rendererViewportCache = null;
    this.rendererViewportCacheHandle = this.rendererHandle;
    this.rendererViewportReadAtMs = 0;
    this.rendererCanvasTransformPendingVersion = 0;
    this.canvasViewportSnapshot = null;
    this.canvasViewportSnapshotHandle = this.rendererHandle;
  }

  private readRendererViewport(forceRefresh: boolean = false): RendererViewportSnapshot | null {
    const now: number = Date.now();
    if (this.rendererViewportCacheHandle !== this.rendererHandle) {
      this.rendererViewportCache = null;
      this.rendererViewportCacheHandle = this.rendererHandle;
      this.rendererViewportReadAtMs = 0;
      this.rendererCanvasTransformPendingVersion = 0;
    }
    if (!forceRefresh && this.rendererViewportCache !== null &&
      now - this.rendererViewportReadAtMs < RENDERER_VIEWPORT_CACHE_MS) {
      return this.rendererViewportCache;
    }
    // Throttle failed reads as well. A detached/rebuilding surface must not
    // turn every touch Move and every cursor Builder evaluation into NAPI work.
    if (!forceRefresh && this.rendererViewportReadAtMs > 0 &&
      now - this.rendererViewportReadAtMs < RENDERER_VIEWPORT_CACHE_MS) {
      return this.rendererViewportCache;
    }
    this.rendererViewportReadAtMs = now;
    try {
      const raw = this.loader.getRendererViewport(this.rendererHandle);
      if (raw && raw.sourceWidth > 0 && raw.sourceHeight > 0) {
        const nativeTransformVersion: number = Number.isFinite(raw.transformVersion) ?
          raw.transformVersion : 0;
        if (!shouldAcceptRendererViewportSnapshot(this.rendererCanvasTransformPendingVersion,
          nativeTransformVersion)) {
          // The render owner has not applied the newest transform yet. Keep
          // the locally mirrored viewport; accepting this snapshot would make
          // cursor/input mapping jump back during pinch or canvas pan.
          return this.rendererViewportCache;
        }
        // The renderer owns viewport values in its own surface-pixel space.
        // A resize/rotation can publish that snapshot one frame before ArkUI
        // receives the new surface size. Normalize it before combining it with
        // this page's current vp/px conversion; otherwise a 16px fallback
        // arrow can be magnified to a screen-sized triangle.
        const targetSurfaceWidth: number = this.renderWidthPx > 0 ? this.renderWidthPx :
          raw.surfaceWidth;
        const targetSurfaceHeight: number = this.renderHeightPx > 0 ? this.renderHeightPx :
          raw.surfaceHeight;
        const viewport = normalizeRendererViewportToSurface(raw.viewportX, raw.viewportY,
          raw.viewportW, raw.viewportH, raw.surfaceWidth, raw.surfaceHeight,
          targetSurfaceWidth, targetSurfaceHeight);
        if (viewport !== null) {
          const snapshot: RendererViewportSnapshot = {
            transformVersion: nativeTransformVersion,
            sourceWidth: raw.sourceWidth,
            sourceHeight: raw.sourceHeight,
            surfaceWidth: targetSurfaceWidth,
            surfaceHeight: targetSurfaceHeight,
            viewportX: viewport.viewportX,
            viewportY: viewport.viewportY,
            viewportW: viewport.viewportW,
            viewportH: viewport.viewportH
          };
          this.rendererSourceWidth = snapshot.sourceWidth;
          this.rendererSourceHeight = snapshot.sourceHeight;
          this.rendererViewportCache = snapshot;
          this.rendererCanvasTransformPendingVersion = nativeTransformVersion;
          this.canvasViewportSnapshot = {
            surfaceWidth: snapshot.surfaceWidth,
            surfaceHeight: snapshot.surfaceHeight,
            sourceWidth: snapshot.sourceWidth,
            sourceHeight: snapshot.sourceHeight
          };
          this.canvasViewportSnapshotHandle = this.rendererHandle;
          return this.rendererViewportCache;
        }
      }
    } catch (_e) {
      // Renderer may be unavailable while a surface is being rebuilt.
    }
    return this.rendererViewportCache;
  }

  /** RustDesk frame dimensions are the peer display dimensions in this FFI. */
  private syncRustDeskLogicalSizeFromRenderer(): void {
    if (!this.isRustDeskSession() || this.rendererHandle <= 0) {
      return;
    }
    const viewport: RendererViewportSnapshot | null = this.readRendererViewport();
    if (viewport === null ||
      (viewport.sourceWidth === this.remoteWidth && viewport.sourceHeight === this.remoteHeight)) {
      return;
    }
    // The native renderer can still expose the previous texture for a short
    // interval after RustDesk acknowledges a display switch. Keep the
    // protocol-advertised geometry until the first target-display frame lands.
    const expectedWidth: number = this.rustDeskDisplayCapabilities.width;
    const expectedHeight: number = this.rustDeskDisplayCapabilities.height;
    if (expectedWidth > 0 && expectedHeight > 0 &&
      (viewport.sourceWidth !== expectedWidth || viewport.sourceHeight !== expectedHeight)) {
      return;
    }
    const previousWidth: number = this.remoteWidth;
    const previousHeight: number = this.remoteHeight;
    this.resetRustDeskInputAfterGeometryChange('rustdesk-renderer-geometry');
    RemoteSessionPipService.getInstance().updateContentSize(
      viewport.sourceWidth, viewport.sourceHeight);
    this.updateRemoteSize({
      width: viewport.sourceWidth,
      height: viewport.sourceHeight,
      colorDepth: 32,
      multiMonitor: false,
      monitorCount: 1
    });
    if (!this.canvasTransformGestureModified) {
      this.resetCanvasToDisplayDefault();
    }
    // The cursor overlay owns its own render scope. Geometry changes do not
    // necessarily move the logical pointer, so explicitly publish the new
    // projection even when remoteCursorX/Y stayed unchanged.
    this.requestRemoteCursorViewRefresh(true);
    hilog.info(RD_DOMAIN, RD_TAG, 'RustDesk remote logical size synchronized from peer frame: ' +
      previousWidth.toString() + 'x' + previousHeight.toString() + ' -> ' +
      viewport.sourceWidth.toString() + 'x' + viewport.sourceHeight.toString());
  }

  /**
   * Renderer geometry is a low-frequency stream property, not cursor data.
   * Keep it on its own bounded timer so cursor polling never performs a
   * viewport/NAPI read on the hot path.
   */
  private stopRustDeskGeometrySync(): void {
    if (this.rustDeskGeometrySyncTimer >= 0) {
      clearInterval(this.rustDeskGeometrySyncTimer);
      this.rustDeskGeometrySyncTimer = -1;
    }
  }

  private startRustDeskGeometrySync(sessionId: number): void {
    this.stopRustDeskGeometrySync();
    if (!this.isRustDeskSession() || sessionId <= 0) {
      return;
    }
    const sync: () => void = (): void => {
      if (!this.connected || this.sessionId !== sessionId || !this.isRustDeskSession()) {
        this.stopRustDeskGeometrySync();
        return;
      }
      this.syncRustDeskDisplayCatalog();
      this.syncRustDeskLogicalSizeFromRenderer();
    };
    sync();
    this.rustDeskGeometrySyncTimer = setInterval(sync, REMOTE_GEOMETRY_SYNC_MS);
  }

  private currentRemoteSurfaceTransform(): RemoteSurfaceTransform {
    const remoteW: number = this.remoteWidth > 0 ? this.remoteWidth : 1280;
    const remoteH: number = this.remoteHeight > 0 ? this.remoteHeight : 720;
    const surfaceWidthVp: number = this.surfaceWidth > 0 ? this.surfaceWidth : remoteW;
    const surfaceHeightVp: number = this.surfaceHeight > 0 ? this.surfaceHeight : remoteH;
    const surfaceWidthPx: number = this.renderWidthPx > 0 ? this.renderWidthPx :
      this.vpToPx(surfaceWidthVp);
    const surfaceHeightPx: number = this.renderHeightPx > 0 ? this.renderHeightPx :
      this.vpToPx(surfaceHeightVp);
    const viewport: RendererViewportSnapshot | null = this.readRendererViewport();
    if (viewport !== null) {
      return {
        remoteWidth: remoteW,
        remoteHeight: remoteH,
        viewportX: viewport.viewportX,
        viewportY: viewport.viewportY,
        viewportW: viewport.viewportW,
        viewportH: viewport.viewportH,
        surfaceWidthPx,
        surfaceHeightPx,
        surfaceWidthVp,
        surfaceHeightVp
      };
    }

    const sourceW: number = this.rendererSourceWidth > 0 ? this.rendererSourceWidth : remoteW;
    const sourceH: number = this.rendererSourceHeight > 0 ? this.rendererSourceHeight : remoteH;
    const scaleW: number = surfaceWidthPx / sourceW;
    const scaleH: number = surfaceHeightPx / sourceH;
    const scale: number = Math.min(scaleW, scaleH);
    const viewportW: number = Math.max(1, sourceW * scale);
    const viewportH: number = Math.max(1, sourceH * scale);
    return {
      remoteWidth: remoteW,
      remoteHeight: remoteH,
      viewportX: (surfaceWidthPx - viewportW) / 2,
      viewportY: (surfaceHeightPx - viewportH) / 2,
      viewportW,
      viewportH,
      surfaceWidthPx,
      surfaceHeightPx,
      surfaceWidthVp,
      surfaceHeightVp
    };
  }

  private remoteDeltaFromLocal(delta: number, axis: 'x' | 'y'): number {
    const transform: RemoteSurfaceTransform = this.currentRemoteSurfaceTransform();
    const deltaResult = axis === 'x' ?
      surfaceDeltaToRemote(transform, delta, 0) : surfaceDeltaToRemote(transform, 0, delta);
    return (axis === 'x' ? deltaResult.x : deltaResult.y) * TOUCHPAD_POINTER_GAIN;
  }

  /** Convert both axes against one transform snapshot for one touch event. */
  private remoteDeltaFromLocalPair(deltaX: number, deltaY: number): RemoteSurfaceDelta {
    const delta: RemoteSurfaceDelta = surfaceDeltaToRemote(
      this.currentRemoteSurfaceTransform(), deltaX, deltaY);
    return {
      x: delta.x * TOUCHPAD_POINTER_GAIN,
      y: delta.y * TOUCHPAD_POINTER_GAIN
    };
  }

  /**
   * 将桌面空间坐标转换为 Host 端鼠标空间 (SwitchDisplay 分辨率)
   *
   * 客户端光标在 desktop 空间 (remoteWidth×remoteHeight) 中追踪,
   * 但 RustDesk Host 接收鼠标事件的坐标空间是 SwitchDisplay 分辨率
   * (即视频帧 sourceWidth×sourceHeight)。两者可能不同 (横竖屏/缩放)。
   * 此处按比例映射, 确保 Host 端光标覆盖全桌面。
   */
  /** Protocol input uses remote logical/display coordinates, not renderer pixels. */
  private toSourceSpace(desktopX: number, desktopY: number): Record<string, number> {
    const r: Record<string, number> = {
      'x': this.clampRemoteX(desktopX),
      'y': this.clampRemoteY(desktopY)
    };
    return r;
  }

  private remoteToLocalPoint(remoteX: number, remoteY: number): LocalPoint {
    const transform: RemoteSurfaceTransform = this.currentRemoteSurfaceTransform();
    const point = remotePointToSurface(transform, remoteX, remoteY);
    return { x: point.x, y: point.y, inside: point.inside };
  }

  private mapInputPointWithTransform(localX: number, localY: number,
    transform: RemoteSurfaceTransform): MappedPoint {
    // HarmonyOS TouchEvent/MouseEvent/GestureEvent coordinates are local vp.
    // Keep the unit conversion in the geometry policy; guessing from the
    // numeric range turns out-of-bounds vp coordinates into valid points on
    // high-density surfaces and makes the virtual pointer drift.
    const point = surfacePointToRemote(transform, localX, localY);
    return {
      x: Math.round(point.x),
      y: Math.round(point.y),
      inside: point.inside
    };
  }

  private mapInputPoint(localX: number, localY: number): MappedPoint {
    return this.mapInputPointWithTransform(localX, localY, this.currentRemoteSurfaceTransform());
  }

  private logMappedInput(source: string, localX: number, localY: number, mapped: MappedPoint): void {
    const now: number = Date.now();
    this.inputLogCount++;
    if (mapped.inside && this.inputLogCount > 12 && now - this.lastInputLogMs < INPUT_LOG_SAMPLE_MS) {
      return;
    }
    this.lastInputLogMs = now;
    hilog.info(RD_DOMAIN, RD_TAG, 'mapInput ' + source +
      ' local=' + Math.round(localX).toString() + ',' + Math.round(localY).toString() +
      ' remote=' + mapped.x.toString() + ',' + mapped.y.toString() +
      ' view=' + Math.round(this.surfaceWidth).toString() + 'x' + Math.round(this.surfaceHeight).toString() +
      ' desktop=' + this.remoteWidth.toString() + 'x' + this.remoteHeight.toString() +
      ' inside=' + (mapped.inside ? 'true' : 'false'));
  }

  private canForwardInput(source: string): boolean {
    const protocol: string = this.currentProtocolName();
    if (this.isVncViewOnlySession()) {
      const now: number = Date.now();
      if (source !== 'mouseMove' && now - this.lastVncViewOnlyBlockedToastMs > 2200) {
        this.lastVncViewOnlyBlockedToastMs = now;
        promptAction.showToast({
          message: 'VNC 当前为只读连接，已阻止键盘、鼠标和剪贴板发送',
          duration: 1600
        });
      }
      hilog.info(RD_DOMAIN, RD_TAG, 'dropInput ' + source + ' vncViewOnly=1');
      return false;
    }
    if (shouldBlockRemoteInputForBrowseMode(protocol, this.rustdeskBrowseMode)) {
      const now: number = Date.now();
      if (source !== 'mouseMove' && now - this.lastBrowseModeBlockedToastMs > 2200) {
        this.lastBrowseModeBlockedToastMs = now;
        promptAction.showToast({
          message: remoteInputBlockedReason(protocol, this.rustdeskBrowseMode),
          duration: 1400
        });
      }
      hilog.info(RD_DOMAIN, RD_TAG, 'dropInput ' + source + ' browseMode=1 protocol=' + protocol);
      return false;
    }
    if (this.connected && this.sessionId > 0 && this.inputForwardReady) {
      return true;
    }
    hilog.warn(RD_DOMAIN, RD_TAG, 'dropInput ' + source +
      ' connected=' + (this.connected ? 'true' : 'false') +
      ' sessionId=' + this.sessionId.toString() +
      ' inputReady=' + (this.inputForwardReady ? 'true' : 'false'));
    return false;
  }

  private shouldUseHardwareKeyboardProxy(): boolean {
    const host: RemoteHost | null = this.pendingHost;
    return this.connected && this.sessionId > 0 && this.isKeyboardMouseControlMode() &&
      this.physicalKeyboardConnected && host !== null &&
      (host.protocol === 'rdp' || host.protocol === 'rustdesk' || host.protocol === 'vnc');
  }

  private shouldRequirePhysicalKeyboardLayout(): boolean {
    const host: RemoteHost | null = this.pendingHost;
    return this.isKeyboardMouseControlMode() && this.physicalKeyboardConnected && host !== null &&
      shouldChoosePhysicalKeyboardLayout(host.protocol, this.isDesktopDevice, this.breakpoint);
  }

  /** Each RustDesk session confirms its cross-platform remote keyboard type. */
  private promptPhysicalKeyboardLayout(): void {
    if (!this.shouldRequirePhysicalKeyboardLayout() || this.physicalKeyboardLayoutConfirmed ||
      this.physicalKeyboardLayoutPromptVisible || !this.connected) {
      return;
    }
    this.physicalKeyboardLayoutPromptVisible = true;
    this.hardwareKeyboardProxyActive = false;
    this.releaseAllHeldKeys();
    promptAction.showDialog({
      title: '选择远端键盘类型',
      message: '此选择只对本次连接生效。\n\nWindows：' +
        remoteKeyboardLayoutDescription(RemoteKeyboardLayout.WINDOWS) + '\n\nmacOS：' +
        remoteKeyboardLayoutDescription(RemoteKeyboardLayout.MACOS),
      isModal: true,
      buttons: [
        { text: 'Windows', color: this.accentColor },
        { text: 'macOS', color: this.accentColor }
      ]
    }).then((result: Object): void => {
      const response: Record<string, number> = result as Record<string, number>;
      this.physicalKeyboardLayout = response['index'] === 1 ?
        RemoteKeyboardLayout.MACOS : RemoteKeyboardLayout.WINDOWS;
      this.physicalKeyboardLayoutConfirmed = true;
      this.physicalKeyboardLayoutPromptVisible = false;
      hilog.info(RD_DOMAIN, RD_TAG, 'physical-keyboard-layout selected=' +
        this.physicalKeyboardLayout);
      this.scheduleRemoteInputFocus('keyboard-layout-selected');
    }).catch((err: Error): void => {
      this.physicalKeyboardLayoutPromptVisible = false;
      hilog.warn(RD_DOMAIN, RD_TAG, 'physical-keyboard-layout dismissed error=' +
        JSON.stringify(err));
    });
  }

  private mapPhysicalKeyCode(keyCode: number): number {
    const protocol: string = this.pendingHost === null ? '' : this.pendingHost.protocol;
    return mapPhysicalKeyForRemoteLayout(
      physicalKeyboardLayoutForProtocol(protocol, this.physicalKeyboardLayout), keyCode);
  }

  private clearRemoteInputFocusSchedule(): void {
    if (this.remoteInputFocusTimer >= 0) {
      clearTimeout(this.remoteInputFocusTimer);
      this.remoteInputFocusTimer = -1;
    }
  }

  /**
   * 将系统键盘焦点交给连接后的远程输入层。
   *
   * PC/2in1 的实体键盘不会稳定地产生 XComponent onKeyEvent：当远端
   * 画布是 SURFACE 时，ArkUI 会把按键交给系统输入法编辑器。因此桌面端
   * 使用一个不主动拉起软键盘的隐藏 TextArea 作为硬件输入代理，并在
   * onKeyPreIme 阶段直接转发实体键；只有用户明确打开虚拟键盘时，普通
   * 字符才进入 IME 组词链路。移动端仍优先使用 remoteInputSurface/XComponent。
   */
  private scheduleRemoteInputFocus(reason: string): void {
    if (this.connected && this.shouldRequirePhysicalKeyboardLayout() &&
      !this.physicalKeyboardLayoutConfirmed && !this.physicalKeyboardLayoutPromptVisible) {
      this.promptPhysicalKeyboardLayout();
      return;
    }
    if (!this.connected || this.sessionId <= 0 || this.keyboardOpen ||
      this.physicalKeyboardLayoutPromptVisible ||
      (this.shouldRequirePhysicalKeyboardLayout() && !this.physicalKeyboardLayoutConfirmed)) {
      return;
    }
    this.clearRemoteInputFocusSchedule();
    this.remoteInputFocusTimer = setTimeout((): void => {
      this.remoteInputFocusTimer = -1;
      if (!this.connected || this.sessionId <= 0 || this.keyboardOpen ||
        this.physicalKeyboardLayoutPromptVisible ||
        (this.shouldRequirePhysicalKeyboardLayout() && !this.physicalKeyboardLayoutConfirmed)) {
        return;
      }
      const useHardwareProxy: boolean = this.shouldUseHardwareKeyboardProxy();
      let proxyFocused: boolean = false;
      let overlayFocused: boolean = false;
      let xComponentFocused: boolean = false;
      try {
        if (useHardwareProxy) {
          this.hardwareKeyboardProxyActive = true;
          // 自动桌面硬件键盘模式不需要编辑会话；若用户刚关闭虚拟键盘，
          // 这里同时结束残留 IME 编辑状态，避免控制端输入法再次弹出。
          if (this.keyboardImeActive) {
            this.resetRemoteImeSession('desktop-proxy-direct');
          }
          try {
            this.keyboardController.stopEditing();
          } catch (_err) {
            // TextArea 尚未挂载或已经退出编辑态时，停止编辑可能无效。
          }
          proxyFocused = focusControl.requestFocus('RemoteDesktopKeyboard');
          if (!proxyFocused) {
            overlayFocused = focusControl.requestFocus('remoteInputSurface');
            if (!overlayFocused) {
              xComponentFocused = focusControl.requestFocus(this.xcId);
            }
          }
        } else {
          this.hardwareKeyboardProxyActive = false;
          if (this.keyboardImeActive) {
            this.resetRemoteImeSession('desktop-proxy-unavailable');
          }
          overlayFocused = focusControl.requestFocus('remoteInputSurface');
          if (!overlayFocused) {
            xComponentFocused = focusControl.requestFocus(this.xcId);
          }
        }
        hilog.info(RD_DOMAIN, RD_TAG, 'remote-input-focus reason=' + reason +
          ' proxy=' + (proxyFocused ? '1' : '0') +
          ' proxyExpected=' + (useHardwareProxy ? '1' : '0') +
          ' overlay=' + (overlayFocused ? '1' : '0') +
          ' xcomponent=' + (xComponentFocused ? '1' : '0') +
          ' desktop=' + (this.isDesktopDevice ? '1' : '0') +
          ' breakpoint=' + this.breakpoint +
          ' keyboardMouseMode=' + (this.isKeyboardMouseControlMode() ? '1' : '0') +
          ' physicalKeyboard=' + (this.physicalKeyboardConnected ? '1' : '0') +
          ' protocol=' + this.currentProtocolName());
      } catch (err) {
        hilog.warn(RD_DOMAIN, RD_TAG, 'remote-input-focus failed reason=' + reason +
          ' proxyExpected=' + (useHardwareProxy ? '1' : '0') +
          ' error=' + JSON.stringify(err));
      }
    }, 60);
  }

  private clearMouseMoveTimer(): void {
    if (this.mouseMoveTimer >= 0) {
      clearTimeout(this.mouseMoveTimer);
      this.mouseMoveTimer = -1;
    }
  }

  private discardPendingMouseMove(): void {
    this.clearMouseMoveTimer();
    this.pendingMouseMoveValid = false;
    this.pendingMouseMoveSequence = 0;
    this.pendingMouseMoveGeneration = this.connectAttemptId;
    this.localMouseMoveInFlight = false;
    this.localMouseMoveSentAtMs = 0;
  }

  private expireMouseMoveAcknowledgement(now: number = Date.now()): void {
    if (!this.localMouseMoveInFlight || this.pendingMouseMoveValid ||
      this.localMouseMoveSentAtMs <= 0 ||
      now - this.localMouseMoveSentAtMs < MOUSE_MOVE_IN_FLIGHT_DIAGNOSTIC_TIMEOUT_MS) {
      return;
    }
    this.localMouseMoveInFlight = false;
    hilog.debug(RD_DOMAIN, RD_TAG, 'mouse move remote echo not observed sequence=' +
      this.localMouseMoveSequence.toString() + ' sent=' +
      this.localMouseMoveSentX.toFixed(2) + ',' + this.localMouseMoveSentY.toFixed(2));
  }

  private flushMouseMove(): void {
    this.clearMouseMoveTimer();
    if (!this.pendingMouseMoveValid) {
      return;
    }
    if (this.pendingMouseMoveGeneration !== this.connectAttemptId) {
      this.pendingMouseMoveValid = false;
      return;
    }
    if (this.canForwardInput('mouseMove')) {
      const src = this.toSourceSpace(this.pendingMouseMoveX, this.pendingMouseMoveY);
      this.loader.sendMouse(this.sessionId, src['x'], src['y'], -1, false);
      this.localMouseMoveInFlight = true;
      this.localMouseMoveSentX = this.pendingMouseMoveX;
      this.localMouseMoveSentY = this.pendingMouseMoveY;
      this.localMouseMoveSentAtMs = Date.now();
      this.localMouseMoveSequence = this.pendingMouseMoveSequence;
      this.localMouseMoveGeneration = this.pendingMouseMoveGeneration;
    }
    this.pendingMouseMoveValid = false;
  }

  private queueMouseMove(x: number, y: number, updateDisplayed: boolean = true): void {
    if (updateDisplayed) {
      this.rememberRemoteCursor(x, y);
    }
    this.pendingMouseMoveX = x;
    this.pendingMouseMoveY = y;
    this.pendingMouseMoveValid = true;
    this.pendingMouseMoveSequence = ++this.mouseMoveSequenceCounter;
    this.pendingMouseMoveGeneration = this.connectAttemptId;
    if (this.mouseMoveTimer < 0) {
      this.mouseMoveTimer = setTimeout(() => {
        this.flushMouseMove();
      }, MOUSE_MOVE_FLUSH_MS);
    }
  }

  private sendMouseNow(x: number, y: number, button: number, pressed: boolean): void {
    if (button < 0) {
      this.queueMouseMove(x, y, true);
      return;
    }
    // Keep a fractional touchpad prediction intact when the button event is
    // emitted at the already displayed cursor location.
    if (x !== this.remoteCursorX || y !== this.remoteCursorY) {
      this.rememberRemoteCursor(x, y);
    }
    this.flushMouseMove();
    if (!this.canForwardInput('mouseButton')) {
      return;
    }
    const src = this.toSourceSpace(x, y);
    let sendButton: number = button;
    if (this.isRustDeskSession() && this.rustdeskSwapMouseButtons) {
      if (sendButton === 0) {
        sendButton = 2;
      } else if (sendButton === 2) {
        sendButton = 0;
      }
    }
    this.loader.sendMouse(this.sessionId, src['x'], src['y'], sendButton, pressed);
  }

  private rdpCredentialParts(host: RemoteHost): RdpCredentialParts {
    if (host.protocol !== 'rdp') {
      return { username: host.username, domain: '' };
    }
    return normalizeRdpCredentialParts(
      host.username,
      AppStorage.get<number>('rdpAuthIdentityMode') ?? 1);
  }

  private hostWithResolvedCredential(host: RemoteHost): RemoteHost {
    if (host.protocol !== 'rdp' || normalizeRdpAuthMode(host.rdpAuthMode) !== 'password' ||
      host.rdpCredentialId === '') {
      return host;
    }
    const credential: RdpCredential | undefined = this.srv.getRdpCredential(host.rdpCredentialId);
    if (!credential) {
      hilog.warn(RD_DOMAIN, RD_TAG, 'RDP credential not found: ' + host.rdpCredentialId);
      return host;
    }
    const resolved: RemoteHost = RemoteHost.fromJSON(host.toJSON());
    resolved.username = credential.username;
    resolved.password = credential.password;
    hilog.info(RD_DOMAIN, RD_TAG, 'RDP credential resolved: idHash=' + hashForLog(credential.id) +
      ' username=' + maskUser(credential.username) +
      ' encrypted=' + (credential.password.startsWith('1:') ? 'true' : 'false'));
    return resolved;
  }

  private hostWithRdpOneTimeCertificate(host: RemoteHost, params: Record<string, Object>): RemoteHost {
    if (host.protocol !== 'rdp') {
      return host;
    }
    const fingerprint: string = (params['rdpCertificateOneTimeFingerprintSha256'] as string) || '';
    if (fingerprint.length === 0) {
      return host;
    }
    const resolved: RemoteHost = RemoteHost.fromJSON(host.toJSON());
    resolved.rdpCertificateFingerprintSha256 = fingerprint;
    resolved.rdpCertificateTrustMode = 0;
    resolved.rdpCertificateTrustedAt = 0;
    resolved.rdpCertificateAllowUntrustedRoot =
      (params['rdpCertificateOneTimeAllowUntrustedRoot'] as boolean) === true;
    resolved.rdpCertificateAllowHostMismatch =
      (params['rdpCertificateOneTimeAllowHostMismatch'] as boolean) === true;
    hilog.info(RD_DOMAIN, RD_TAG, 'RDP one-time certificate override applied: host=' + maskHost(host.host));
    return resolved;
  }

  private async waitForNativeConnected(
    sessionId: number,
    timeoutMs: number,
    attemptId: number,
    protocol: string,
    host: RemoteHost | null = null
  ): Promise<boolean> {
    const startedAt: number = Date.now();
    let lastState: number = -1;
    let lastLogMs: number = 0;
    let observedConnecting: boolean = false;
    while (Date.now() - startedAt < timeoutMs) {
      if (attemptId !== this.connectAttemptId || this.sessionId !== sessionId) {
        hilog.info(RD_DOMAIN, RD_TAG, 'Native connection wait canceled');
        return false;
      }
      const state: number = this.loader.getConnectionState(sessionId);
      const transferStatus: SessionTransferStatus = this.loader.getSessionTransferStatus(sessionId);
      this.rdpDriveMounted = transferStatus.rdpDriveMounted;
      if (state === 1) { observedConnecting = true; }
      if (state === 2) {
        if (protocol === 'rustdesk' && this.showRustDeskTwoFactorSheet) {
          this.showRustDeskTwoFactorSheet = false;
          this.rustDeskTwoFactorSessionId = -1;
          this.rustDeskTwoFactorInput = '';
          this.rustDeskTwoFactorError = '';
          this.rustDeskTwoFactorSubmitting = false;
          this.rustDeskTwoFactorAutoAttemptSessionId = -1;
        }
        return true;
      }
      if (protocol === 'rustdesk' && state === 5) {
        const authMessage: string = this.loader.getConnectionLastMessage(sessionId);
        if (host !== null) {
          await this.tryAutoSubmitRustDeskTwoFactor(sessionId, host);
        }
        this.openRustDeskTwoFactorPrompt(sessionId, authMessage);
      }
      const terminal: boolean = protocol === 'vnc' ?
        shouldTreatVncConnectionStateAsTerminal(state, observedConnecting, Date.now() - startedAt) :
        state === 4 || state === 0;
      if (terminal) {
        if (attemptId !== this.connectAttemptId || this.sessionId !== sessionId) {
          hilog.info(RD_DOMAIN, RD_TAG, 'Native connection state ignored after cancel: ' + state.toString());
          return false;
        }
        const nativeMessage: string = this.loader.getConnectionLastMessage(sessionId);
        if (protocol === 'rustdesk') {
          const ffiError: string = this.loader.getRustDeskLastError();
          const detail: string = ffiError.length > 0 ? '：' + ffiError :
            (nativeMessage.length > 0 ? '：' + nativeMessage : '');
          if (ffiError.indexOf('remote approval timed out') >= 0) {
            throw new Error('等待被控端批准超时，请确认对方已启用点击批准' + detail +
              ' [E-RUSTDESK-APPROVAL-TIMEOUT]');
          }
          if (ffiError.indexOf('connection cancelled') >= 0) {
            throw new Error('连接请求已取消' + detail + ' [E-RUSTDESK-CANCELLED]');
          }
          throw new Error('RustDesk 握手失败或连接已断开' + detail +
            ' [E-RUSTDESK-STATE-' + state.toString() + ']');
        }
        if (protocol === 'rdp') {
          const detail: string = nativeMessage.length > 0 ? '：' + nativeMessage : '';
          throw new Error('RDP 连接失败或被服务器拒绝' + detail +
            ' [E-RDP-STATE-' + state.toString() + ']');
        }
        if (protocol === 'vnc') {
          const diagnosis = diagnoseVncConnectionError(nativeMessage);
          throw new Error(diagnosis.title + '：' + diagnosis.detail + ' [' + diagnosis.code + ']');
        }
        const detail: string = nativeMessage.length > 0 ? '：' + nativeMessage : '';
        throw new Error('远程连接失败或已断开' + detail +
          ' [E-CONNECT-STATE-' + state.toString() + ']');
      }
      const elapsedMs: number = Date.now() - startedAt;
      if (state !== lastState) {
        hilog.info(RD_DOMAIN, RD_TAG, 'Native connection state=' + state.toString());
        lastState = state;
        lastLogMs = elapsedMs;
      } else if (elapsedMs - lastLogMs >= 2000) {
        hilog.info(RD_DOMAIN, RD_TAG, 'Native connection still waiting state=' +
          state.toString() + ' elapsed=' + elapsedMs.toString() + 'ms');
        lastLogMs = elapsedMs;
      }
      await new Promise<void>((resolve: () => void): void => {
        setTimeout(resolve, 250);
      });
    }
    if (attemptId !== this.connectAttemptId || this.sessionId !== sessionId) {
      hilog.info(RD_DOMAIN, RD_TAG, 'Native connection timeout ignored after cancel');
      return false;
    }
    if (protocol === 'rustdesk') {
      throw new Error('RustDesk 握手或 2FA 验证超时 [E-RUSTDESK-TIMEOUT]');
    }
    if (protocol === 'rdp') {
      throw new Error('RDP 连接超时，请确认 Windows 远程桌面服务和账号权限 [E-RDP-TIMEOUT]');
    }
    throw new Error('远程连接超时 [E-CONNECT-TIMEOUT]');
  }

  private rdpErrorCodeFromDetail(detail: string, fallback: string): string {
    const marker: string = '0x';
    const idx: number = detail.indexOf(marker);
    if (idx >= 0 && detail.length >= idx + 4) {
      let code: string = marker;
      for (let i = idx + 2; i < detail.length; i++) {
        const ch: string = detail.charAt(i);
        const isHex: boolean = (ch >= '0' && ch <= '9') ||
          (ch >= 'a' && ch <= 'f') || (ch >= 'A' && ch <= 'F');
        if (!isHex) { break; }
        code += ch;
      }
      if (code.length > 2) { return code; }
    }
    return fallback;
  }

  private showRdpSessionError(message: string, code: string, cleanupReason: string): void {
    this.rdpSessionErrorTitle = '你的会话已断开';
    this.rdpSessionErrorMessage = message;
    this.rdpSessionErrorCode = code;
    this.rdpSessionErrorBackPending = false;
    this.rdpSessionErrorPendingCleanupReason = cleanupReason;
    this.setPreferredOrientation(window.Orientation.LANDSCAPE, 'LANDSCAPE-RDP-ERROR');
    if (shouldShowRdpSessionErrorAfterControlPanelDismiss(this.showControlPanel)) {
      this.rdpSessionErrorPendingAfterControlPanel = true;
      this.showControlPanel = false;
      return;
    }
    this.showRdpSessionErrorSheet = true;
  }

  private showRdpSessionErrorModel(model: RdpSessionErrorDialogModel, cleanupReason: string): void {
    this.showRdpSessionError(model.message, model.code, cleanupReason);
  }

  private closeRdpSessionErrorSheet(): void {
    this.rdpSessionErrorBackPending = true;
    this.showRdpSessionErrorSheet = false;
  }

  private handleRdpSessionErrorSheetDisappear(): void {
    if (!this.rdpSessionErrorBackPending) {
      return;
    }
    this.rdpSessionErrorBackPending = false;
    const cleanupReason: string = this.rdpSessionErrorPendingCleanupReason.length > 0 ?
      this.rdpSessionErrorPendingCleanupReason : 'rdp-session-error-dismiss';
    this.rdpSessionErrorPendingCleanupReason = '';
    this.disconnectAndCleanup(cleanupReason);
    this.goBack();
  }

  private handleControlPanelDisappear(): void {
    if (this.keepKeyboardAfterSheetClose && !this.rdpSessionErrorPendingAfterControlPanel) {
      this.keepKeyboardAfterSheetClose = false;
      setTimeout(() => {
        this.openKeyboard();
      }, 60);
    } else if (this.rdpSessionErrorPendingAfterControlPanel) {
      this.keepKeyboardAfterSheetClose = false;
    }
    if (this.rdpSessionErrorPendingAfterControlPanel) {
      this.rdpSessionErrorPendingAfterControlPanel = false;
      setTimeout((): void => {
        this.setPreferredOrientation(window.Orientation.LANDSCAPE, 'LANDSCAPE-RDP-ERROR');
        this.showRdpSessionErrorSheet = true;
      }, 60);
    }
  }

  private clearRdpRenderWatchdog(): void {
    if (this.rdpRenderWatchdogTimer !== -1) {
      clearTimeout(this.rdpRenderWatchdogTimer);
      this.rdpRenderWatchdogTimer = -1;
    }
  }

  private clearRdpNativeStateMonitor(): void {
    if (this.rdpNativeStateMonitorTimer !== -1) {
      clearTimeout(this.rdpNativeStateMonitorTimer);
      this.rdpNativeStateMonitorTimer = -1;
    }
  }

  private startRdpNativeStateMonitor(sessionId: number, attemptId: number): void {
    this.clearRdpNativeStateMonitor();
    const poll = (): void => {
      if (attemptId !== this.connectAttemptId || this.sessionId !== sessionId ||
        !this.connected || !this.pendingHost || this.pendingHost.protocol !== 'rdp') {
        this.rdpNativeStateMonitorTimer = -1;
        return;
      }
      const state: number = this.loader.getConnectionState(sessionId);
      try {
        const vp = this.loader.getRendererViewport(this.rendererHandle);
        if (vp !== null) {
          const sourceWidth: number = vp.sourceWidth;
          const sourceHeight: number = vp.sourceHeight;
          if (sourceWidth > 0 && sourceHeight > 0 &&
            (sourceWidth !== this.rendererSourceWidth || sourceHeight !== this.rendererSourceHeight)) {
            this.rendererSourceWidth = sourceWidth;
            this.rendererSourceHeight = sourceHeight;
            // This monitor reads the native snapshot directly, so invalidate
            // the local geometry cache before preserving a user transform.
            // Otherwise a resize while zoomed keeps the old source dimensions
            // in the next pinch calculation and input projection.
            this.invalidateRendererViewportCache();
            if (!this.canvasTransformGestureModified) {
              this.resetCanvasToDisplayDefault(true);
            }
            hilog.info(RD_DOMAIN, RD_TAG, 'RDP desktop size synchronized from renderer: ' +
              sourceWidth.toString() + 'x' + sourceHeight.toString() +
              ' (renderer source only; remote logical size preserved=' +
              this.remoteWidth.toString() + 'x' + this.remoteHeight.toString() + ')');
          }
        }
      } catch (_e) {
        // Renderer may be temporarily unavailable while a resize transaction is rebuilding GDI.
      }
      if (state === 4 || state === 0) {
        const nativeMessage: string = this.loader.getConnectionLastMessage(sessionId);
        hilog.error(RD_DOMAIN, RD_TAG, 'RDP native post-connect state=' + state.toString() +
          ' message=' + safeError(nativeMessage));
        if (nativeMessage.indexOf('E-RDP-ERRINFO-0x') >= 0 || state === 4) {
          const model: RdpSessionErrorDialogModel =
            rdpSessionErrorFromNativeMessage(nativeMessage, state === 4 ? '0x10' : '0x11');
          this.connectionError = model.title;
          this.connectionErrorDetail = model.message + '错误代码: ' + model.code;
          this.showRdpSessionErrorModel(model, 'rdp-native-errorinfo');
          if (shouldCleanupRdpSessionBeforeErrorDismiss()) {
            this.disconnectAndCleanup('rdp-native-errorinfo');
          }
        }
        this.rdpNativeStateMonitorTimer = -1;
        return;
      }
      this.rdpNativeStateMonitorTimer = setTimeout(poll, 500);
    };
    this.rdpNativeStateMonitorTimer = setTimeout(poll, 500);
  }

  private startRdpRenderWatchdog(sessionId: number, attemptId: number): void {
    this.clearRdpRenderWatchdog();
    this.rdpRenderWatchdogTimer = setTimeout((): void => {
      this.rdpRenderWatchdogTimer = -1;
      if (attemptId !== this.connectAttemptId || this.sessionId !== sessionId ||
        !this.connected || !this.pendingHost || this.pendingHost.protocol !== 'rdp') {
        return;
      }
      const stats: RdpRenderStats = this.loader.getRdpRenderStats(sessionId);
      hilog.info(RD_DOMAIN, RD_TAG, 'RDP render watchdog stats paints=' +
        stats.paintCount.toString() + ' rendered=' + stats.renderedPaintCount.toString() +
        ' first=' + stats.firstPaintMs.toString() + ' last=' + stats.lastPaintMs.toString() +
        ' ret=' + stats.lastRenderResult.toString() +
        ' skipped=' + stats.skippedPaintCount.toString() +
        ' pump=' + stats.pumpRendered.toString() + '/' + stats.pumpSubmitted.toString() +
        ' replaced=' + stats.pumpReplaced.toString() +
        ' rejected=' + stats.presentationRejected.toString() +
        ' detached=' + stats.surfaceDetachedRejections.toString() +
        ' generation=' + stats.generationRejections.toString() +
        ' renderCostUs=' + stats.lastRenderCostUs.toString() +
        ' bytes=' + stats.lastRenderBytes.toString() +
        ' copied=' + stats.copiedBytes.toString() +
        ' callbackP95=' + stats.callbackP95Us.toString() +
        ' copyP95=' + stats.copyP95Us.toString() +
        ' queueP95=' + stats.queueP95Us.toString() +
        ' uploadP95=' + stats.uploadP95Us.toString() +
        ' swapP95=' + stats.swapP95Us.toString() +
        ' workerP95=' + stats.workerP95Us.toString() +
        ' uploadGate=' + stats.glUploadGateDecision.toString() +
        ' uploadSwapP95=' + stats.glUploadSwapP95Us.toString() +
        ' uploadShare=' + stats.glUploadSharePermille.toString() +
        ' gateSamples=' + stats.glUploadEvaluatedSamples.toString() +
        ' desktop=' + stats.desktopWidth.toString() + 'x' + stats.desktopHeight.toString() +
        ' gfxEpoch=' + stats.graphicsEpoch.toString() +
        ' resize=' + stats.desktopResizeCount.toString() + '/' +
          stats.desktopResizeFailures.toString() +
        ' gfxChannel=' + (stats.gfxChannelConnected ? 'connected' : 'disconnected') +
        ' inputQ=' + stats.inputQueueDepth.toString() + '/' + stats.inputQueueMax.toString() +
        ' inputTextUnits=' + stats.inputTextUnits.toString() +
        ' inputMouseDrops=' + stats.inputDroppedMouseMoves.toString() +
        ' inputPriorityOverflow=' + stats.inputNonDisposableOverflow.toString() +
        ' gfx=' + stats.graphicsMode);
      if (stats.renderedPaintCount <= 0 || stats.lastRenderResult < 0) {
        const model: RdpSessionErrorDialogModel = rdpNoFrameWatchdogError();
        this.connectionError = model.title;
        this.connectionErrorDetail = model.message + '错误代码: ' + model.code;
        this.showRdpSessionErrorModel(model, 'rdp-render-watchdog');
        if (shouldCleanupRdpSessionBeforeErrorDismiss()) {
          this.disconnectAndCleanup('rdp-render-watchdog');
        }
      }
    }, 12000);
  }

  @State showPassphraseSheet: boolean = false;
  private rdpPassphraseResolve: ((v: string) => void) | null = null;
  @State rdpPassphraseInput: string = '';
  @State rdpPassphraseShowPw: boolean = false;

  private promptSshPassphrase(): Promise<string> {
    return new Promise<string>((resolve: (v: string) => void) => {
      this.rdpPassphraseResolve = resolve;
      this.rdpPassphraseInput = '';
      this.showPassphraseSheet = true;
    });
  }

  @Builder rdPassphraseBuilder() {
    Column() {
      Text('私钥密码').fontSize(18).fontWeight(FontWeight.Bold)
        .fontColor(this.pal().text).margin({ bottom: 8 })
      Text('此私钥已加密, 请输入密码').fontSize(14)
        .fontColor(this.pal().text2).margin({ bottom: 16 })
      Row() {
        TextInput({ placeholder: '输入密码', text: this.rdpPassphraseInput })
          .type(this.rdpPassphraseShowPw ? InputType.Normal : InputType.Password)
          .height(40).backgroundColor(this.pal().surface).borderRadius(8)
          .fontColor(this.pal().text).placeholderColor(this.pal().text3)
          .layoutWeight(1).padding({ left: 12, right: 12 })
          .onChange((v: string) => { this.rdpPassphraseInput = v; })
        SymbolGlyph(this.rdpPassphraseShowPw ? $r('sys.symbol.eye_slash') : $r('sys.symbol.eye'))
          .fontSize(18).fontColor([this.pal().text3]).margin({ left: 8 })
          .onClick(() => { this.rdpPassphraseShowPw = !this.rdpPassphraseShowPw; })
      }.width('100%').margin({ bottom: 20 })
      Row() {
        Button('取消').fontSize(14).height(38).layoutWeight(1)
          .backgroundColor(this.pal().surface).fontColor(this.pal().text2).borderRadius(8)
          .onClick(() => {
            this.showPassphraseSheet = false;
            if (this.rdpPassphraseResolve) { this.rdpPassphraseResolve(''); }
          })
        Button('确定').fontSize(14).height(38).layoutWeight(1)
          .backgroundColor(this.accentColor).fontColor('#FFFFFF').borderRadius(8).margin({ left: 12 })
          .onClick(() => {
            this.showPassphraseSheet = false;
            if (this.rdpPassphraseResolve) { this.rdpPassphraseResolve(this.rdpPassphraseInput); }
          })
      }.width('100%')
    }.padding(20)
  }

  private releasePixelMap(pixelMap: image.PixelMap): void {
    try {
      pixelMap.release();
    } catch (_e) {
      // PixelMap may already have been released by the image pipeline. Do not
      // put it back into state or expose the exception to the UI promise.
      hilog.warn(RD_DOMAIN, RD_TAG, 'remote-cursor PixelMap release failed');
    }
  }

  private retiredRemoteCursorPixelMapCount(): number {
    return this.retiredRemoteCursorPixelMaps.length +
      (this.deferredRemoteCursorPixelMap !== null ? 1 : 0) +
      (this.overflowRemoteCursorPixelMap !== null ? 1 : 0);
  }

  private releaseRetiredRemoteCursorPixelMaps(): void {
    if (this.retiredRemoteCursorPixelMaps.length === 0 &&
      this.deferredRemoteCursorPixelMap === null && this.overflowRemoteCursorPixelMap === null) {
      return;
    }
    const nowMs: number = Date.now();
    const overlayPixelMap: image.PixelMap | null = this.remoteCursorOverlayState.arrowPixelMap;
    if (this.deferredRemoteCursorPixelMap !== null &&
      this.retiredRemoteCursorPixelMaps.length < REMOTE_CURSOR_MAX_RETIRED_PIXELMAPS) {
      this.retiredRemoteCursorPixelMaps.push(this.deferredRemoteCursorPixelMap);
      this.deferredRemoteCursorPixelMap = null;
    }
    if (this.overflowRemoteCursorPixelMap !== null &&
      this.retiredRemoteCursorPixelMaps.length < REMOTE_CURSOR_MAX_RETIRED_PIXELMAPS) {
      this.retiredRemoteCursorPixelMaps.push(this.overflowRemoteCursorPixelMap);
      this.overflowRemoteCursorPixelMap = null;
    }
    const pending: Array<RetiredRemoteCursorPixelMap> = [];
    let releasedCount: number = 0;
    for (let index: number = 0; index < this.retiredRemoteCursorPixelMaps.length; index++) {
      const retired: RetiredRemoteCursorPixelMap = this.retiredRemoteCursorPixelMaps[index];
      const safeToRelease: boolean = nowMs >= retired.notBeforeMs &&
        this.remoteCursorOverlayState.viewRevision >= retired.requiredViewRevision &&
        retired.pixelMap !== this.remoteCursorPixelMap && retired.pixelMap !== overlayPixelMap;
      if (safeToRelease) {
        this.releasePixelMap(retired.pixelMap);
        releasedCount += 1;
      } else {
        pending.push(retired);
      }
    }
    this.retiredRemoteCursorPixelMaps = pending;
    if (this.deferredRemoteCursorPixelMap !== null &&
      nowMs >= this.deferredRemoteCursorPixelMap.notBeforeMs &&
      this.remoteCursorOverlayState.viewRevision >= this.deferredRemoteCursorPixelMap.requiredViewRevision &&
      this.deferredRemoteCursorPixelMap.pixelMap !== this.remoteCursorPixelMap &&
      this.deferredRemoteCursorPixelMap.pixelMap !== overlayPixelMap) {
      this.releasePixelMap(this.deferredRemoteCursorPixelMap.pixelMap);
      this.deferredRemoteCursorPixelMap = null;
      releasedCount += 1;
    }
    if (this.overflowRemoteCursorPixelMap !== null &&
      nowMs >= this.overflowRemoteCursorPixelMap.notBeforeMs &&
      this.remoteCursorOverlayState.viewRevision >= this.overflowRemoteCursorPixelMap.requiredViewRevision &&
      this.overflowRemoteCursorPixelMap.pixelMap !== this.remoteCursorPixelMap &&
      this.overflowRemoteCursorPixelMap.pixelMap !== overlayPixelMap) {
      this.releasePixelMap(this.overflowRemoteCursorPixelMap.pixelMap);
      this.overflowRemoteCursorPixelMap = null;
      releasedCount += 1;
    }
    const pendingCount: number = this.retiredRemoteCursorPixelMapCount();
    if (pendingCount >= REMOTE_CURSOR_MAX_RETIRED_PIXELMAPS) {
      hilog.warn(RD_DOMAIN, RD_TAG, 'remote-cursor retired PixelMap queue high-water=' +
        pendingCount.toString());
    }
    if (releasedCount > 0) {
      hilog.debug(RD_DOMAIN, RD_TAG, 'remote-cursor retired PixelMap released=' +
        releasedCount.toString() + ' pending=' + pendingCount.toString());
    }
    if (pendingCount > 0) {
      this.scheduleRetiredRemoteCursorPixelMapRelease();
    }
  }

  private scheduleRetiredRemoteCursorPixelMapRelease(): void {
    if (this.remoteCursorPixelMapReleaseTimer >= 0 ||
      this.retiredRemoteCursorPixelMaps.length === 0 &&
      this.deferredRemoteCursorPixelMap === null && this.overflowRemoteCursorPixelMap === null) {
      return;
    }
    const nowMs: number = Date.now();
    let nextDueMs: number = nowMs + REMOTE_CURSOR_PIXELMAP_RETIRE_RETRY_MS;
    for (let index: number = 0; index < this.retiredRemoteCursorPixelMaps.length; index++) {
      nextDueMs = Math.min(nextDueMs, this.retiredRemoteCursorPixelMaps[index].notBeforeMs);
    }
    if (this.deferredRemoteCursorPixelMap !== null) {
      nextDueMs = Math.min(nextDueMs, this.deferredRemoteCursorPixelMap.notBeforeMs);
    }
    if (this.overflowRemoteCursorPixelMap !== null) {
      nextDueMs = Math.min(nextDueMs, this.overflowRemoteCursorPixelMap.notBeforeMs);
    }
    const delayMs: number = Math.max(REMOTE_CURSOR_PIXELMAP_RETIRE_RETRY_MS, nextDueMs - nowMs);
    this.remoteCursorPixelMapReleaseTimer = setTimeout((): void => {
      this.remoteCursorPixelMapReleaseTimer = -1;
      this.releaseRetiredRemoteCursorPixelMaps();
    }, delayMs);
  }

  private retireRemoteCursorPixelMap(pixelMap: image.PixelMap,
    requiredViewRevision: number = this.remoteCursorViewRevision + 1,
    forceRetire: boolean = false): void {
    if (!forceRetire && (pixelMap === this.remoteCursorPixelMap ||
      pixelMap === this.remoteCursorOverlayState.arrowPixelMap)) {
      return;
    }
    for (let index: number = 0; index < this.retiredRemoteCursorPixelMaps.length; index++) {
      if (this.retiredRemoteCursorPixelMaps[index].pixelMap === pixelMap) {
        return;
      }
    }
    if (this.deferredRemoteCursorPixelMap !== null &&
      this.deferredRemoteCursorPixelMap.pixelMap === pixelMap) {
      return;
    }
    if (this.overflowRemoteCursorPixelMap !== null &&
      this.overflowRemoteCursorPixelMap.pixelMap === pixelMap) {
      return;
    }
    const retired: RetiredRemoteCursorPixelMap = {
      pixelMap,
      notBeforeMs: Date.now() + REMOTE_CURSOR_PIXELMAP_RETIRE_GRACE_MS,
      requiredViewRevision
    };
    this.releaseRetiredRemoteCursorPixelMaps();
    if (this.retiredRemoteCursorPixelMaps.length >= REMOTE_CURSOR_MAX_RETIRED_PIXELMAPS) {
      if (this.deferredRemoteCursorPixelMap === null) {
        this.deferredRemoteCursorPixelMap = retired;
      } else if (this.overflowRemoteCursorPixelMap === null) {
        this.overflowRemoteCursorPixelMap = retired;
      } else {
        // The normal adoption guard accounts for all bounded stores, so this
        // means teardown callbacks raced each other. Never push past the
        // queue cap or release a possibly UI-owned map in this branch.
        hilog.error(RD_DOMAIN, RD_TAG,
          'remote-cursor retired PixelMap capacity invariant violated');
        return;
      }
    } else {
      this.retiredRemoteCursorPixelMaps.push(retired);
    }
    this.scheduleRetiredRemoteCursorPixelMapRelease();
  }

  private releaseRemoteCursorPixelMap(): void {
    const previous: image.PixelMap | null = this.remoteCursorPixelMap;
    this.remoteCursorPixelMap = null;
    this.remoteCursorPixelMapShapeRevision = -1;
    if (previous !== null) {
      // The Overlay still points at the old map until the following publish.
      // Force admission instead of dropping it on the reference guard; the
      // view-revision fence delays its release until that publish is visible.
      this.retireRemoteCursorPixelMap(previous, this.remoteCursorViewRevision + 1, true);
    }
  }

  private clearRemoteCursorPixelFetchWatchdog(): void {
    if (this.remoteCursorPixelFetchWatchdogTimer >= 0) {
      clearTimeout(this.remoteCursorPixelFetchWatchdogTimer);
      this.remoteCursorPixelFetchWatchdogTimer = -1;
    }
  }

  private clearRemoteCursorShapeLoadWatchdog(): void {
    if (this.remoteCursorShapeLoadWatchdogTimer >= 0) {
      clearTimeout(this.remoteCursorShapeLoadWatchdogTimer);
      this.remoteCursorShapeLoadWatchdogTimer = -1;
    }
  }

  private removeRemoteCursorAsyncToken(tokens: Array<number>, token: number): void {
    const index: number = tokens.indexOf(token);
    if (index >= 0) {
      tokens.splice(index, 1);
    }
  }

  /**
   * A reconnect can reuse the protocol adapter while an earlier worker or
   * FreeRDP callback is still unwinding. Treat the native generation as a
   * cursor-session boundary and retire the old bitmap before accepting new
   * pixels for the same numeric session id.
   */
  private adoptRemoteCursorGeneration(generation: number): void {
    if (generation <= 0 || generation === this.remoteCursorGeneration) {
      return;
    }
    const hadGeneration: boolean = this.remoteCursorGeneration > 0;
    this.remoteCursorGeneration = generation;
    if (!hadGeneration) {
      return;
    }

    this.remoteCursorShapeLoadToken += 1;
    this.clearRemoteCursorShapeLoadWatchdog();
    this.remoteCursorShapeLoading = false;
    this.remoteCursorShapeLoadingSessionId = -1;
    this.remoteCursorShapeLoadingGeneration = -1;
    this.remoteCursorShapeLoadingRevision = -1;
    this.remoteCursorShapeLoadOutstandingTokens = [];
    this.remoteCursorPixelFetchToken += 1;
    this.clearRemoteCursorPixelFetchWatchdog();
    this.remoteCursorPixelFetchInFlight = false;
    this.remoteCursorPixelFetchSessionId = -1;
    this.remoteCursorPixelFetchGeneration = -1;
    this.remoteCursorPixelFetchRevision = -1;
    this.remoteCursorPixelFetchStartedAtMs = 0;
    this.remoteCursorPixelFetchOutstandingTokens = [];
    this.remoteCursorShapeRevision = -1;
    this.remoteCursorPixelMapShapeRevision = -1;
    this.remoteCursorPositionRevision = -1;
    this.remoteCursorVisibilityRevision = -1;
    this.remoteCursorNativeVisible = false;
    this.remoteCursorFallbackShape = false;
    this.remoteCursorShapeWidth = 0;
    this.remoteCursorShapeHeight = 0;
    this.remoteCursorHotX = 0;
    this.remoteCursorHotY = 0;
    this.remoteCursorShapeRetryAtMs = 0;
    this.releaseRemoteCursorPixelMap();
    this.requestRemoteCursorViewRefresh(true);
    hilog.info(RD_DOMAIN, RD_TAG, 'remote-cursor generation adopted generation=' +
      generation.toString() + ' old_async_invalidated=1');
  }

  private clearRemoteCursorPolling(releaseVisual: boolean = true,
    reason: string = 'session-stop'): void {
    this.clearRemoteCursorViewCommit();
    this.stopRustDeskGeometrySync();
    this.rustDeskGeometryEpoch = 0;
    this.remoteCursorShapeLoadToken += 1;
    this.clearRemoteCursorShapeLoadWatchdog();
    this.remoteCursorShapeLoading = false;
    this.remoteCursorShapeLoadingSessionId = -1;
    this.remoteCursorShapeLoadingGeneration = -1;
    this.remoteCursorShapeLoadingRevision = -1;
    this.remoteCursorShapeLoadOutstandingTokens = [];
    this.remoteCursorPixelFetchToken += 1;
    this.clearRemoteCursorPixelFetchWatchdog();
    this.remoteCursorPixelFetchInFlight = false;
    this.remoteCursorPixelFetchSessionId = -1;
    this.remoteCursorPixelFetchGeneration = -1;
    this.remoteCursorPixelFetchRevision = -1;
    this.remoteCursorPixelFetchStartedAtMs = 0;
    this.remoteCursorPixelFetchOutstandingTokens = [];
    if (this.remoteCursorPollTimer !== -1) {
      clearInterval(this.remoteCursorPollTimer);
      this.remoteCursorPollTimer = -1;
    }
    if (!releaseVisual) {
      hilog.info(RD_DOMAIN, RD_TAG, 'remote-cursor polling stopped preserve=1 reason=' + reason);
      return;
    }
    this.remoteCursorNativeVisible = false;
    this.remoteCursorGeneration = -1;
    this.remoteCursorShapeRevision = -1;
    this.remoteCursorPixelMapShapeRevision = -1;
    this.remoteCursorPositionRevision = -1;
    this.remoteCursorVisibilityRevision = -1;
    this.remoteCursorFallbackShape = false;
    this.remoteCursorShapeWidth = 0;
    this.remoteCursorShapeHeight = 0;
    this.remoteCursorHotX = 0;
    this.remoteCursorHotY = 0;
    this.remoteCursorShapeRetryAtMs = 0;
    this.remoteCursorLastLogMs = 0;
    this.releaseRemoteCursorPixelMap();
    this.requestRemoteCursorViewRefresh(true);
    hilog.info(RD_DOMAIN, RD_TAG, 'remote-cursor polling stopped preserve=0 reason=' + reason);
  }

  /**
   * Read only the current shape bitmap through the N-API worker pool. Cursor
   * metadata stays on the cheap synchronous poll path; a shape transition
   * must never synchronously copy RGBA bytes on the ArkUI thread.
   */
  private requestRemoteCursorShapePixels(sessionId: number, shapeRevision: number,
    generation: number): void {
    if (generation !== this.remoteCursorGeneration) {
      return;
    }
    if (this.remoteCursorPixelFetchInFlight && this.remoteCursorPixelFetchSessionId === sessionId &&
      this.remoteCursorPixelFetchGeneration === generation &&
      this.remoteCursorPixelFetchRevision === shapeRevision) {
      return;
    }
    if (this.remoteCursorPixelFetchOutstandingTokens.length >= REMOTE_CURSOR_MAX_ASYNC_OUTSTANDING) {
      hilog.warn(RD_DOMAIN, RD_TAG, 'remote-cursor shape pixel fetch bounded outstanding=' +
        this.remoteCursorPixelFetchOutstandingTokens.length.toString() +
        ' revision=' + shapeRevision.toString());
      return;
    }
    const fetchToken: number = ++this.remoteCursorPixelFetchToken;
    const startedAtMs: number = Date.now();
    this.remoteCursorPixelFetchInFlight = true;
    this.remoteCursorPixelFetchSessionId = sessionId;
    this.remoteCursorPixelFetchGeneration = generation;
    this.remoteCursorPixelFetchRevision = shapeRevision;
    this.remoteCursorPixelFetchStartedAtMs = startedAtMs;
    this.remoteCursorPixelFetchOutstandingTokens.push(fetchToken);
    this.clearRemoteCursorPixelFetchWatchdog();
    this.remoteCursorPixelFetchWatchdogTimer = setTimeout((): void => {
      this.remoteCursorPixelFetchWatchdogTimer = -1;
      if (fetchToken !== this.remoteCursorPixelFetchToken ||
        !this.remoteCursorPixelFetchInFlight ||
        this.remoteCursorPixelFetchSessionId !== sessionId ||
        this.remoteCursorPixelFetchGeneration !== generation ||
        this.remoteCursorPixelFetchRevision !== shapeRevision) {
        return;
      }
      // Invalidate the hung request but retain its token in the bounded list
      // until its Promise eventually settles. This permits one recovery retry
      // without creating an unbounded number of native async workers.
      this.remoteCursorPixelFetchToken += 1;
      this.remoteCursorPixelFetchInFlight = false;
      this.remoteCursorPixelFetchSessionId = -1;
      this.remoteCursorPixelFetchGeneration = -1;
      this.remoteCursorPixelFetchRevision = -1;
      this.remoteCursorPixelFetchStartedAtMs = 0;
      this.remoteCursorShapeRetryAtMs = Date.now();
      hilog.warn(RD_DOMAIN, RD_TAG, 'remote-cursor shape pixel fetch watchdog timeout session=' +
        sessionId.toString() + ' generation=' + generation.toString() +
        ' revision=' + shapeRevision.toString());
    }, REMOTE_CURSOR_ASYNC_WATCHDOG_MS);
    this.loader.getRemoteCursorSnapshotPixelsAsync(sessionId).then(
      (pixels: RemoteCursorSnapshot | null): void => {
        this.removeRemoteCursorAsyncToken(this.remoteCursorPixelFetchOutstandingTokens, fetchToken);
        const valid: boolean = fetchToken === this.remoteCursorPixelFetchToken &&
          this.connected && this.sessionId === sessionId && pixels !== null &&
          pixels.sessionId === sessionId && pixels.generation === generation &&
          this.remoteCursorGeneration === generation && pixels.shapeRevision === shapeRevision;
        if (valid && pixels !== null) {
          this.applyRemoteCursorShape(pixels);
          hilog.info(RD_DOMAIN, RD_TAG, 'remote-cursor shape pixels ready revision=' +
            shapeRevision.toString() + ' bytes=' + pixels.rgba.byteLength.toString() +
            ' elapsedMs=' + (Date.now() - startedAtMs).toString());
        } else {
          hilog.info(RD_DOMAIN, RD_TAG, 'remote-cursor shape pixels discarded revision=' +
            shapeRevision.toString() + ' elapsedMs=' + (Date.now() - startedAtMs).toString());
        }
        if (fetchToken === this.remoteCursorPixelFetchToken) {
          this.clearRemoteCursorPixelFetchWatchdog();
          this.remoteCursorPixelFetchInFlight = false;
          this.remoteCursorPixelFetchSessionId = -1;
          this.remoteCursorPixelFetchGeneration = -1;
          this.remoteCursorPixelFetchRevision = -1;
          this.remoteCursorPixelFetchStartedAtMs = 0;
        }
      }).catch((err: Object): void => {
        this.removeRemoteCursorAsyncToken(this.remoteCursorPixelFetchOutstandingTokens, fetchToken);
        if (fetchToken === this.remoteCursorPixelFetchToken) {
          this.clearRemoteCursorPixelFetchWatchdog();
          this.remoteCursorPixelFetchInFlight = false;
          this.remoteCursorPixelFetchSessionId = -1;
          this.remoteCursorPixelFetchGeneration = -1;
          this.remoteCursorPixelFetchRevision = -1;
          this.remoteCursorPixelFetchStartedAtMs = 0;
        }
        hilog.warn(RD_DOMAIN, RD_TAG, 'remote-cursor shape pixels failed revision=' +
          shapeRevision.toString() + ' elapsedMs=' + (Date.now() - startedAtMs).toString() +
          ' err=' + JSON.stringify(err));
      });
  }

  private applyRemoteCursorShape(snapshot: RemoteCursorSnapshot): void {
    if (snapshot.width <= 0 || snapshot.height <= 0 ||
      snapshot.rgba.byteLength !== snapshot.width * snapshot.height * 4 ||
      snapshot.generation !== this.remoteCursorGeneration) {
      return;
    }
    if (this.remoteCursorShapeLoading && this.remoteCursorShapeLoadingSessionId === snapshot.sessionId &&
      this.remoteCursorShapeLoadingGeneration === snapshot.generation &&
      this.remoteCursorShapeLoadingRevision === snapshot.shapeRevision) {
      return;
    }
    if (this.remoteCursorShapeLoadOutstandingTokens.length >= REMOTE_CURSOR_MAX_ASYNC_OUTSTANDING) {
      hilog.warn(RD_DOMAIN, RD_TAG, 'remote-cursor PixelMap creation bounded outstanding=' +
        this.remoteCursorShapeLoadOutstandingTokens.length.toString() +
        ' revision=' + snapshot.shapeRevision.toString());
      return;
    }
    const loadToken: number = ++this.remoteCursorShapeLoadToken;
    this.remoteCursorShapeLoading = true;
    this.remoteCursorShapeLoadingSessionId = snapshot.sessionId;
    this.remoteCursorShapeLoadingGeneration = snapshot.generation;
    this.remoteCursorShapeLoadingRevision = snapshot.shapeRevision;
    this.remoteCursorShapeLoadOutstandingTokens.push(loadToken);
    this.clearRemoteCursorShapeLoadWatchdog();
    this.remoteCursorShapeLoadWatchdogTimer = setTimeout((): void => {
      this.remoteCursorShapeLoadWatchdogTimer = -1;
      if (loadToken !== this.remoteCursorShapeLoadToken || !this.remoteCursorShapeLoading ||
        this.remoteCursorShapeLoadingSessionId !== snapshot.sessionId ||
        this.remoteCursorShapeLoadingGeneration !== snapshot.generation ||
        this.remoteCursorShapeLoadingRevision !== snapshot.shapeRevision) {
        return;
      }
      this.remoteCursorShapeLoadToken += 1;
      this.remoteCursorShapeLoading = false;
      this.remoteCursorShapeLoadingSessionId = -1;
      this.remoteCursorShapeLoadingGeneration = -1;
      this.remoteCursorShapeLoadingRevision = -1;
      this.remoteCursorShapeRetryAtMs = Date.now();
      hilog.warn(RD_DOMAIN, RD_TAG, 'remote-cursor PixelMap watchdog timeout session=' +
        snapshot.sessionId.toString() + ' generation=' + snapshot.generation.toString() +
        ' revision=' + snapshot.shapeRevision.toString());
    }, REMOTE_CURSOR_ASYNC_WATCHDOG_MS);
    const options: image.InitializationOptions = {
        editable: false,
        srcPixelFormat: image.PixelMapFormat.RGBA_8888,
        pixelFormat: image.PixelMapFormat.RGBA_8888,
        alphaType: image.AlphaType.UNPREMUL,
        size: { width: snapshot.width, height: snapshot.height }
    };
    // API 23 provides the Promise form of createPixelMap. Keep the old image
    // visible until the new bitmap is ready; a shape transition must never
    // blank the cursor or block the ArkUI/UI thread.
    image.createPixelMap(snapshot.rgba, options).then((next: image.PixelMap): void => {
      this.removeRemoteCursorAsyncToken(this.remoteCursorShapeLoadOutstandingTokens, loadToken);
      const valid: boolean = loadToken === this.remoteCursorShapeLoadToken &&
        this.connected && this.sessionId === snapshot.sessionId &&
        this.remoteCursorGeneration === snapshot.generation &&
        this.remoteCursorShapeRevision === snapshot.shapeRevision;
      if (!valid) {
        this.releasePixelMap(next);
        return;
      }
      // Do not let a rapid sequence of shape transitions grow the retired
      // list. The new map has not entered the UI tree yet, so it is safe to
      // release this candidate and keep the last committed map while the
      // retired queue drains.
      this.releaseRetiredRemoteCursorPixelMaps();
      if (this.retiredRemoteCursorPixelMapCount() >= REMOTE_CURSOR_MAX_RETIRED_PIXELMAPS) {
        this.clearRemoteCursorShapeLoadWatchdog();
        this.remoteCursorShapeLoading = false;
        this.remoteCursorShapeLoadingSessionId = -1;
        this.remoteCursorShapeLoadingGeneration = -1;
        this.remoteCursorShapeLoadingRevision = -1;
        this.remoteCursorShapeRetryAtMs = Date.now();
        this.releasePixelMap(next);
        this.scheduleRetiredRemoteCursorPixelMapRelease();
        hilog.warn(RD_DOMAIN, RD_TAG, 'remote-cursor PixelMap adoption deferred retired_queue=' +
          this.retiredRemoteCursorPixelMapCount().toString() + ' revision=' +
          snapshot.shapeRevision.toString());
        return;
      }
      this.clearRemoteCursorShapeLoadWatchdog();
      this.remoteCursorShapeLoading = false;
      this.remoteCursorShapeLoadingSessionId = -1;
      this.remoteCursorShapeLoadingGeneration = -1;
      this.remoteCursorShapeLoadingRevision = -1;
      const previous: image.PixelMap | null = this.remoteCursorPixelMap;
      this.remoteCursorPixelMap = next;
      this.remoteCursorPixelMapShapeRevision = snapshot.shapeRevision;
      this.remoteCursorShapeWidth = snapshot.width;
      this.remoteCursorShapeHeight = snapshot.height;
      this.remoteCursorHotX = snapshot.hotX;
      this.remoteCursorHotY = snapshot.hotY;
      this.remoteCursorFallbackShape = snapshot.fallbackShape;
      this.remoteCursorShapeRetryAtMs = Date.now();
      this.requestRemoteCursorViewRefresh(true);
      if (previous !== null) {
        this.retireRemoteCursorPixelMap(previous, this.remoteCursorOverlayState.viewRevision);
      }
    }).catch((err: Object): void => {
      this.removeRemoteCursorAsyncToken(this.remoteCursorShapeLoadOutstandingTokens, loadToken);
      if (loadToken === this.remoteCursorShapeLoadToken) {
        this.clearRemoteCursorShapeLoadWatchdog();
        this.remoteCursorShapeLoading = false;
        this.remoteCursorShapeLoadingSessionId = -1;
        this.remoteCursorShapeLoadingGeneration = -1;
        this.remoteCursorShapeLoadingRevision = -1;
      }
      hilog.warn(RD_DOMAIN, RD_TAG, 'remote cursor PixelMap rejected: ' + JSON.stringify(err));
    });
  }

  private pollRemoteCursor(sessionId: number): void {
    if (!this.connected || this.sessionId !== sessionId || sessionId <= 0) {
      return;
    }
    const now: number = Date.now();
    this.expireMouseMoveAcknowledgement(now);
    this.applyRemoteCursorMotionState(advanceRemoteCursorMotion(this.remoteCursorMotion, now));
    const snapshot: RemoteCursorSnapshot | null =
      this.loader.getRemoteCursorSnapshot(sessionId, false);
    if (snapshot === null || snapshot.sessionId !== sessionId || snapshot.generation <= 0) {
      return;
    }
    this.adoptRemoteCursorGeneration(snapshot.generation);
    const shapeChanged: boolean = snapshot.shapeRevision !== this.remoteCursorShapeRevision;
    const hasCurrentPixelMap: boolean = this.remoteCursorPixelMap !== null &&
      this.remoteCursorPixelMapShapeRevision === snapshot.shapeRevision;
    const shapeRetryDue: boolean = shouldRefreshRemoteCursorBitmap(snapshot.shapeRevision,
      hasCurrentPixelMap, snapshot.visible, this.remoteCursorShapeRetryAtMs,
      now, REMOTE_CURSOR_BITMAP_RETRY_MS);
    const shapeLoadInFlight: boolean = this.remoteCursorShapeLoading &&
      this.remoteCursorShapeLoadingSessionId === sessionId &&
      this.remoteCursorShapeLoadingGeneration === snapshot.generation &&
      this.remoteCursorShapeLoadingRevision === snapshot.shapeRevision;
    const shapePixelsInFlight: boolean = this.remoteCursorPixelFetchInFlight &&
      this.remoteCursorPixelFetchSessionId === sessionId &&
      this.remoteCursorPixelFetchGeneration === snapshot.generation &&
      this.remoteCursorPixelFetchRevision === snapshot.shapeRevision;
    if ((shapeChanged || shapeRetryDue) && !shapeLoadInFlight && !shapePixelsInFlight) {
      this.remoteCursorShapeRevision = snapshot.shapeRevision;
      if (snapshot.shapeRevision > 0) {
        // Record the attempt before crossing NAPI so a rejected/missing bitmap
        // retries at a bounded cadence. Existing PixelMaps are never rebuilt
        // on a timer; only a shape revision or a failed shape load requests it.
        this.remoteCursorShapeRetryAtMs = now;
        this.requestRemoteCursorShapePixels(sessionId, snapshot.shapeRevision,
          snapshot.generation);
      }
    }
    const positionChanged: boolean = snapshot.positionRevision !== this.remoteCursorPositionRevision;
    const visibilityChanged: boolean = snapshot.visibilityRevision !== this.remoteCursorVisibilityRevision;
    if (positionChanged) {
      this.remoteCursorPositionRevision = snapshot.positionRevision;
      // Coordinates and visibility are independent protocol dimensions. A
      // hidden remote cursor can still report a position, which is only an
      // observation for the ownership policy and must never hide or snap a
      // controller-owned touchpad pointer.
      if (snapshot.positionAvailable) {
        this.applyAuthoritativeRemoteCursor(snapshot.x, snapshot.y);
      }
    }
    if (visibilityChanged) {
      this.remoteCursorVisibilityRevision = snapshot.visibilityRevision;
      // RustDesk can temporarily report hidden while its cursor callback path
      // is recovering even though the ArkTS session still accepts local input.
      // Preserve the controller-side arrow until a real disconnect; RDP keeps
      // honoring protocol visibility.
      this.remoteCursorNativeVisible = snapshot.visible || this.isRustDeskSession();
      this.requestRemoteCursorViewRefresh(true);
    }
    if (shapeChanged || positionChanged || visibilityChanged ||
      this.remoteCursorLastLogMs === 0 || now - this.remoteCursorLastLogMs >= REMOTE_CURSOR_LOG_SAMPLE_MS) {
      this.remoteCursorLastLogMs = now;
      hilog.info(RD_DOMAIN, RD_TAG, 'remote-cursor state session=' + sessionId.toString() +
        ' generation=' + snapshot.generation.toString() +
        ' shapeRevision=' + snapshot.shapeRevision.toString() +
        ' positionRevision=' + snapshot.positionRevision.toString() +
        ' visibilityRevision=' + snapshot.visibilityRevision.toString() +
        ' visible=' + (snapshot.visible ? '1' : '0') +
        ' pixelMap=' + (this.remoteCursorPixelMap !== null ? '1' : '0') +
        ' fallback=' + (snapshot.fallbackShape ? '1' : '0') +
        ' positionTransport=' + (this.isRustDeskSession() ? 'rustdesk-ffi' : 'freerdp') +
        ' positionAvailable=' + (snapshot.positionAvailable ? '1' : '0') +
        ' position=' + snapshot.x.toString() + ',' + snapshot.y.toString() +
        ' shapeSource=' + snapshot.shapeSource +
        ' owner=' + this.remoteCursorMotion.owner +
        ' local=' + this.remoteCursorMotion.localTargetX.toFixed(1) + ',' +
        this.remoteCursorMotion.localTargetY.toFixed(1) +
        ' observed=' + this.remoteCursorMotion.remoteObservedX.toFixed(1) + ',' +
        this.remoteCursorMotion.remoteObservedY.toFixed(1));
    }
  }

  private startRemoteCursorPolling(sessionId: number): void {
    // Restarting a timer (connect handoff / foreground restore) must not erase
    // the last valid cursor. The native snapshot may not repeat an unchanged
    // shape, so clearing here can otherwise make the arrow disappear forever.
    this.clearRemoteCursorPolling(false, 'poll-restart');
    this.startRustDeskGeometrySync(sessionId);
    this.pollRemoteCursor(sessionId);
    this.remoteCursorPollTimer = setInterval((): void => {
      this.pollRemoteCursor(sessionId);
    }, REMOTE_CURSOR_POLL_MS);
  }

  @Builder rustDeskAuthChoiceBuilder() {
    Column() {
      Text('选择连接授权').fontSize(20).fontWeight(FontWeight.Bold)
        .fontColor(this.pal().text).margin({ bottom: 6 })
      Text(this.pendingHost ? this.pendingHost.label : 'RustDesk 主机').fontSize(13)
        .fontColor(this.pal().text2).margin({ bottom: 4 })
      if (this.pendingHost && this.pendingHost.rustdeskProPlatform.length > 0) {
        Text('平台：' + this.pendingHost.rustdeskProPlatform).fontSize(11)
          .fontColor(this.pal().text3).margin({ bottom: 14 })
      } else {
        Text('Pro 地址簿主机').fontSize(11)
          .fontColor(this.pal().text3).margin({ bottom: 14 })
      }

      Row() {
        Button('使用设备密码').fontSize(13).height(40).layoutWeight(1)
          .backgroundColor(this.rustDeskAuthChoice === 'password' ? this.accentColor : this.pal().surface)
          .fontColor(this.rustDeskAuthChoice === 'password' ? '#FFFFFF' : this.pal().text2)
          .borderRadius(10)
          .onClick(() => {
            this.rustDeskAuthChoice = 'password';
            this.rustDeskAuthError = '';
            setTimeout((): void => { this.focusRustDeskAuthPassword(); }, 30);
          })
        Button('请求远端同意').fontSize(13).height(40).layoutWeight(1)
          .margin({ left: 10 })
          .backgroundColor(this.rustDeskAuthChoice === 'request_approval' ? this.accentColor : this.pal().surface)
          .fontColor(this.rustDeskAuthChoice === 'request_approval' ? '#FFFFFF' : this.pal().text2)
          .borderRadius(10)
          .enabled(!(this.pendingHost && this.pendingHost.rustdeskDirectEnabled))
          .onClick(() => {
            this.rustDeskAuthChoice = 'request_approval';
            this.rustDeskAuthError = '';
          })
      }.width('100%').margin({ bottom: 14 })

      if (this.rustDeskAuthChoice === 'password') {
        Text('远程 RustDesk 设备密码').fontSize(12).fontColor(this.pal().text2)
          .margin({ bottom: 5 })
        Row() {
          TextInput({ placeholder: '输入设备密码', text: this.rustDeskAuthPasswordInput })
            .id('RustDeskAuthPassword')
            .type(this.rustDeskAuthPasswordShow ? InputType.Normal : InputType.Password)
            .height(42).backgroundColor(this.pal().surface).borderRadius(9)
            .fontColor(this.pal().text).placeholderColor(this.pal().text3)
            .layoutWeight(1).padding({ left: 12, right: 12 })
            .focusOnTouch(true)
            .enableKeyboardOnFocus(true)
            .defaultFocus(this.rustDeskAuthChoice === 'password')
            .onChange((v: string) => { this.rustDeskAuthPasswordInput = v; })
            .onSubmit((_enterKey: EnterKeyType, event: SubmitEvent): void => {
              event.keepEditableState();
              this.confirmRustDeskAuthChoice();
            })
          SymbolGlyph(this.rustDeskAuthPasswordShow ? $r('sys.symbol.eye_slash') : $r('sys.symbol.eye'))
            .fontSize(18).fontColor([this.pal().text3]).margin({ left: 8 })
            .onClick(() => { this.rustDeskAuthPasswordShow = !this.rustDeskAuthPasswordShow; })
        }.width('100%').margin({ bottom: 8 })
        Row() {
          Text('记住此设备密码').fontSize(12).fontColor(this.pal().text2).layoutWeight(1)
          Toggle({ type: ToggleType.Switch, isOn: this.rustDeskAuthRememberPassword })
            .selectedColor(this.accentColor).scale({ x: 0.8, y: 0.8 })
            .onChange((on: boolean) => { this.rustDeskAuthRememberPassword = on; })
        }.width('100%').margin({ bottom: 8 })
        Text('密码类型').fontSize(12).fontColor(this.pal().text2).margin({ bottom: 5 })
        Row({ space: 8 }) {
          Button('一次性密码').layoutWeight(1).height(36).fontSize(12)
            .backgroundColor(this.rustDeskAuthPasswordMode === 0 ? this.accentColor : this.pal().surface)
            .fontColor(this.rustDeskAuthPasswordMode === 0 ? Color.White : this.pal().text2)
            .onClick((): void => { this.rustDeskAuthPasswordMode = 0; })
          Button('永久密码').layoutWeight(1).height(36).fontSize(12)
            .backgroundColor(this.rustDeskAuthPasswordMode === 1 ? this.accentColor : this.pal().surface)
            .fontColor(this.rustDeskAuthPasswordMode === 1 ? Color.White : this.pal().text2)
            .onClick((): void => { this.rustDeskAuthPasswordMode = 1; })
        }.width('100%').margin({ bottom: 6 })
        Text(this.rustDeskAuthPasswordMode === 0 ?
          '一次性密码过期后，下次连接需要重新输入。' :
          '永久密码由被控端 RustDesk 设置决定。')
          .fontSize(11).fontColor(this.pal().text3).lineHeight(16).margin({ bottom: 8 })
        Text('Pro 账户密码不能代替远程设备密码；一次性密码过期后需要重新输入。')
          .fontSize(11).fontColor(this.pal().text3).lineHeight(16).margin({ bottom: 8 })
      } else {
        Text('应用会保持 RustDesk 加密连接，等待被控端点击允许。')
          .fontSize(12).fontColor(this.pal().text2).lineHeight(18).margin({ bottom: 8 })
        Text('对方需要启用“点击批准”；直连模式不支持此方式。')
          .fontSize(11).fontColor(this.pal().text3).lineHeight(16).margin({ bottom: 8 })
      }

      if (this.rustDeskAuthError.length > 0) {
        Text(this.rustDeskAuthError).fontSize(12).fontColor(this.pal().danger)
          .lineHeight(17).margin({ bottom: 10 })
      }
      Row() {
        Button('取消').fontSize(14).height(40).layoutWeight(1)
          .backgroundColor(this.pal().surface).fontColor(this.pal().text2).borderRadius(10)
          .onClick(() => { this.cancelRustDeskAuthChoice(); })
        Button('开始连接').fontSize(14).height(40).layoutWeight(1)
          .margin({ left: 10 }).backgroundColor(this.accentColor).fontColor('#FFFFFF')
          .borderRadius(10)
          .onClick(() => { this.confirmRustDeskAuthChoice(); })
      }.width('100%')
    }
    .width('100%').constraintSize({ maxWidth: 520 })
    .padding({ left: 22, right: 22, top: 20, bottom: 22 })
    .backgroundColor(this.pal().bg).borderRadius(20)
    .border({ width: 0.5, color: this.pal().cardBorder, style: BorderStyle.Solid })
    .shadow({ radius: 24, color: 'rgba(0,0,0,0.24)', offsetY: 8 })
  }

  @Builder vncPasswordSheetBuilder() {
    Column() {
      Text('连接 VNC').fontSize(20).fontWeight(FontWeight.Bold)
        .fontColor(this.pal().text).margin({ bottom: 6 })
      Text(this.pendingVncHost ? this.pendingVncHost.label : 'VNC 主机').fontSize(13)
        .fontColor(this.pal().text2).margin({ bottom: 10 })
      if (this.vncPasswordStatus === 'locked') {
        Text('已保存密码需要解锁应用加密；本次仍可输入一次性密码连接。')
          .fontSize(11).fontColor(this.pal().text3).lineHeight(17).margin({ bottom: 10 })
      } else if (this.vncPasswordStatus === 'consent_required') {
        Text('发现本设备尚未确认的云端密码。确认只保存在本设备，不会自动信任新设备。')
          .fontSize(11).fontColor(this.pal().text3).lineHeight(17).margin({ bottom: 8 })
        Button('使用已保存密码').width('100%').height(38).fontSize(13).borderRadius(9)
          .backgroundColor(this.pal().surface).fontColor(this.accentColor)
          .onClick((): void => { this.useSavedVncPassword(); }).margin({ bottom: 10 })
      }
      Text('VNC 密码（可选）').fontSize(12).fontColor(this.pal().text2).margin({ bottom: 5 })
      TextInput({ placeholder: '留空请使用无密码连接', text: this.vncPasswordInput })
        .id('VncPasswordInput').type(InputType.Password).height(42).width('100%')
        .backgroundColor(this.pal().surface).borderRadius(9).fontColor(this.pal().text)
        .placeholderColor(this.pal().text3).padding({ left: 12, right: 12 })
        .focusOnTouch(true).enableKeyboardOnFocus(true).defaultFocus(true)
        .onChange((value: string): void => { this.vncPasswordInput = value; })
        .onSubmit((_enterKey: EnterKeyType, event: SubmitEvent): void => {
          event.keepEditableState();
          this.confirmVncPasswordChoice();
        })
      Row() {
        Column() {
          Text('记住此设备密码').fontSize(13).fontColor(this.pal().text)
          Text(DataCrypto.getInstance().isReady() ? '使用 AES-GCM 保存' :
            (DataCrypto.getInstance().isSetupComplete() ? '应用加密锁定，当前不可保存密文' :
              '应用加密未启用，保存前会确认未加密风险'))
            .fontSize(11).fontColor(this.pal().text3).margin({ top: 3 })
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.vncRememberPassword })
          .selectedColor(this.accentColor)
          .enabled(!DataCrypto.getInstance().isSetupComplete() || DataCrypto.getInstance().isReady())
          .onChange((value: boolean): void => { this.vncRememberPassword = value; })
      }.width('100%').padding({ top: 10, bottom: 10 })
      if (this.vncPasswordError !== '') {
        Text(this.vncPasswordError).fontSize(12).fontColor(this.pal().danger)
          .lineHeight(17).margin({ bottom: 10 })
      }
      Row() {
        Button('取消').fontSize(13).height(40).layoutWeight(1).borderRadius(10)
          .backgroundColor(this.pal().surface).fontColor(this.pal().text2)
          .onClick((): void => { this.cancelVncPasswordChoice(); })
        Button('无密码连接').fontSize(13).height(40).layoutWeight(1).margin({ left: 8 }).borderRadius(10)
          .backgroundColor(this.pal().surface).fontColor(this.pal().text2)
          .onClick((): void => { this.connectVncWithoutPassword(); })
        Button('开始连接').fontSize(13).height(40).layoutWeight(1).margin({ left: 8 }).borderRadius(10)
          .backgroundColor(this.accentColor).fontColor(Color.White)
          .onClick((): void => { this.confirmVncPasswordChoice(); })
      }.width('100%')
    }.width('100%').constraintSize({ maxWidth: 520 })
      .padding({ left: 22, right: 22, top: 20, bottom: 22 })
      .backgroundColor(this.pal().bg).borderRadius(20)
      .border({ width: 0.5, color: this.pal().cardBorder, style: BorderStyle.Solid })
      .shadow({ radius: 24, color: 'rgba(0,0,0,0.24)', offsetY: 8 })
  }

  // XComponent 就绪后初始化渲染管线并连接
  private async doConnect(host: RemoteHost): Promise<void> {
    const attemptId: number = ++this.connectAttemptId;
    const vncHost: VncHostView | null = this.pendingVncHost;
    const isVnc: boolean = host.protocol === 'vnc' && vncHost !== null;
    let rdpRestrictedAdminHash: string = '';
    let rdAccessTokenFingerprint: string = '';
    let rdAccessTokenGeneration: number = 0;
    let rustDeskRelay: RustDeskRelayConfig | undefined;
    try {
      if (!(await this.loader.waitForPendingTeardown())) {
        throw new Error('上一会话资源清理未完成 [E-TEARDOWN-PENDING]');
      }
      this.rendererSourceWidth = 0;
      this.rendererSourceHeight = 0;
      this.rustDeskDisplaySwitchPending = -1;
      this.rustDeskDisplaySwitchStartedAtMs = 0;
      this.invalidateRendererViewportCache();
      const rdpAuthMode: RdpAuthMode = normalizeRdpAuthMode(host.rdpAuthMode);
      const rdpRestrictedAdminSecretSource: RdpRestrictedAdminSecretSource =
        normalizeRdpRestrictedAdminSecretSource(host.rdpRestrictedAdminSecretSource);
      if (host.protocol === 'rdp' && rdpAuthMode === 'restricted_admin' &&
        rdpRestrictedAdminSecretSource === 'ntlm_hash') {
        const secret = CloudStore.getInstance().loadRdpRestrictedAdminHash(host);
        if (secret.status !== 'ready') {
          if (secret.status === 'crypto_locked') {
            throw new Error('请先解锁本地凭据存储后再连接 Restricted Admin 主机 [E-RDP-AUTH-CRYPTO-LOCKED]');
          }
          if (secret.status === 'binding_mismatch') {
            throw new Error('主机地址或用户名已改变，请重新输入 NTLM Hash [E-RDP-AUTH-IDENTITY-MISMATCH]');
          }
          throw new Error('此设备未保存该 Restricted Admin 主机的 NTLM Hash，请重新输入 [E-RDP-AUTH-SECRET-REQUIRED]');
        }
        rdpRestrictedAdminHash = secret.hash;
      }
      const desktop: DesktopSize = this.desktopSize(host);
      this.updateRemoteSize(desktop);
      const credentials: RdpCredentialParts = isVnc && vncHost !== null
        ? { username: vncHost.username, domain: '' }
        : this.rdpCredentialParts(host);
      const w: number = desktop.width;
      const h: number = desktop.height;
      const pageSurface: RemoteSessionPipContentSize = this.currentPageSurfaceSize(w, h);

      // 初始化渲染器 (XComponent surface 已就绪)
      console.info('[RD-DIAG] initRenderer: xcId=' + this.xcId + ' w=' + pageSurface.width +
        ' h=' + pageSurface.height + ' remote=' + w + 'x' + h);
      const rHandle: number = this.loader.initRenderer(this.xcId, pageSurface.width, pageSurface.height);
      console.info('[RD-DIAG] initRenderer returned: ' + rHandle);
      if (rHandle <= 0) {
        throw new Error('渲染器初始化失败 [E-RENDERER-INIT] rc=' + rHandle);
      }
      this.rendererHandle = rHandle;
      this.nativeHandles.markSurfaceAttached(this.rendererHandle);
      this.resetCanvasToDisplayDefault();

      // VNC delivers raw BGRA frames directly to the generation-safe renderer;
      // it must never create or bind the shared encoded-video decoder.
      const rdCodecVal: number = isVnc ? 0 : (AppStorage.get<number>('rustdeskCodec') ?? 0);
      let decoderCodec: number = host.protocol === 'rustdesk' ? 3 : 0;
      if (!isVnc) {
        if (rdCodecVal === 1) {
          decoderCodec = 2;
        } else if (rdCodecVal === 2) {
          decoderCodec = 3;
        } else if (rdCodecVal === 3) {
          decoderCodec = 4;
        } else if (rdCodecVal === 4) {
          decoderCodec = 0;
        } else if (rdCodecVal === 5) {
          decoderCodec = 1;
        }
        const dHandle: number = this.loader.initDecoder(w, h, decoderCodec);
        hilog.info(RD_DOMAIN, RD_TAG, 'initDecoder returned: ' + dHandle);
        if (dHandle > 0) {
          this.decoderHandle = dHandle;
          const bindOk: boolean = this.loader.bindVideoPipeline(this.decoderHandle, this.rendererHandle);
          hilog.info(RD_DOMAIN, RD_TAG, 'bindVideoPipeline returned: ' + bindOk);
        } else {
          hilog.warn(RD_DOMAIN, RD_TAG, '解码器未就绪 (rc=' + dHandle + '), 连接将继续, 待后续初始化');
        }
      } else {
        this.decoderHandle = -1;
        hilog.info(RD_DOMAIN, RD_TAG, 'VNC raw framebuffer path: decoder/audio shared handles skipped');
      }

      if (isVnc) {
        hilog.info(RD_DOMAIN, RD_TAG, 'VNC audio path disabled; VNC owns only raw framebuffer input');
      } else if (host.protocol === 'rustdesk') {
        hilog.info(RD_DOMAIN, RD_TAG, 'RustDesk audio player lazy init enabled; native starts on first PCM frame');
      } else if (host.protocol === 'rdp' && !(AppStorage.get<boolean>('rdpAudioEnabled') ?? true)) {
        hilog.info(RD_DOMAIN, RD_TAG, 'RDP audio disabled by user preference');
      } else {
        const audioHandle: number = this.loader.initAudioPlayer(48000, 2);
        hilog.info(RD_DOMAIN, RD_TAG, 'initAudioPlayer returned: ' + audioHandle.toString());
        if (audioHandle > 0) {
          this.nativeHandles.markAudioStarted();
        }
      }

      // SSH key material is not part of a VNC owner. Keep this branch wholly
      // outside VNC so an in-memory transient RemoteHost cannot accidentally
      // become an SSH credential source.
      let keyData: string = '';
      let keyPassphrase: string = '';
      let useKey: boolean = false;
      if (!isVnc) {
        // 密钥解析: sshKeyId 优先 (引用 KeyVault), 回退 sshKeyData (旧副本)
        keyData = host.sshKeyData;
        if (host.sshKeyId !== '') {
          const kvs = KeyVaultService.getInstance();
          const ref = kvs.getSshKey(host.sshKeyId);
          if (ref) { keyData = ref.privateKey; }
        }
        useKey = host.sshUseKey && keyData.length > 0;
        // 检测私钥是否需要密码
        keyPassphrase = host.sshKeyPassphrase || '';
        if (useKey) {
          const keyInfo = this.loader.inspectSshPrivateKey(keyData, keyPassphrase);
          if (keyInfo['encrypted'] && keyPassphrase === '') {
            keyPassphrase = await this.promptSshPassphrase();
          }
        }
      }
      const rdpDriveName: string = this.sanitizedRdpDriveName();
      if (host.protocol === 'rdp' && this.rdpDriveEnabled && !RDP_DRIVE_REDIRECTION_ENABLED) {
        hilog.warn(RD_DOMAIN, RD_TAG, 'RDP drive redirection disabled for stable connect path');
      }
      const rdpDrivePath: string = host.protocol === 'rdp' && this.rdpDriveEnabled && RDP_DRIVE_REDIRECTION_ENABLED ?
        this.ensureRdpTransferDir() : '';
      let rdServerKey: string = '';
      let rdServerKeyMode: number = 1;
      let rdAccountId: string = host.rustdeskAccountId;
      let rdAccessToken: string = '';
      if (host.protocol === 'rustdesk' && host.rustdeskRelayId.length > 0) {
        rustDeskRelay = this.srv.getAllRelays()
          .find((r: RustDeskRelayConfig): boolean => r.id === host.rustdeskRelayId);
        if (rustDeskRelay) {
          rdServerKey = rustDeskRelay.key;
          rdServerKeyMode = rustDeskRelayKeyModeForFfi(rustDeskRelay.key, rustDeskRelay.keyMode);
        }
      }
      if (host.protocol === 'rustdesk') {
        rdAccountId = rustDeskProAccountIdForConnection(
          host.rustdeskProAccountId, host.rustdeskAccountId);
        if (host.rustdeskProManaged && host.sourceType === 'rustdesk_pro' && !host.rustdeskDirectEnabled) {
          const account: RustDeskProAccountState | undefined = this.proSync.getAccount(rdAccountId);
          const profile: RustDeskControlPlaneProfile = rustDeskRelay === undefined
            ? RUSTDESK_CONTROL_PLANE_DEFAULT : rustDeskRelay.controlPlaneProfile;
          if (account !== undefined) {
            rdAccessToken = rustDeskControlPlaneTokenForConnection(profile, false, account.accessToken);
            rdAccessTokenFingerprint = account.accessTokenFingerprint;
            rdAccessTokenGeneration = account.tokenGeneration;
          }
        }
      }
      let vncOwner: VncSessionOwner | null = null;
      let vncPassword: string = '';
      let vncGatewayHost: string = '';
      let vncGatewayPort: number = 0;
      let vncGatewayPath: string = '/vnc';
      let vncRepeaterMode: string = 'mode12';
      let vncRepeaterTarget: string = '';
      let vncTls: boolean = false;
      let vncExpectedFingerprint: string = '';
      if (isVnc && vncHost !== null) {
        vncOwner = this.vncOwnerForConnection(vncHost);
        if (vncHost.gatewayId.trim() !== '' && vncOwner.gateway === null) {
          throw new Error('VNC 网关不存在或已被删除 [E-VNC-GATEWAY-404]');
        }
        if (vncOwner.gateway !== null && !vncOwner.gateway.enabled) {
          throw new Error('VNC 网关已停用 [E-VNC-GATEWAY-DISABLED]');
        }
        if (vncHost.transport === 'ultravnc_repeater' && vncOwner.gateway === null) {
          throw new Error('VNC Repeater 未绑定网关 [E-VNC-PAIRING-CONFIG]');
        }
        if (vncHost.transport === 'websocket_gateway' && vncOwner.gateway === null) {
          throw new Error('VNC WebSocket 未绑定网关 [E-VNC-WS-CONFIG]');
        }
        vncPassword = this.vncTransientPassword !== '' ? this.vncTransientPassword :
          this.vncHosts.passwordFor(vncHost.id);
        vncGatewayHost = vncOwner.gateway === null ? '' : vncOwner.gateway.host;
        vncGatewayPort = vncOwner.gateway === null ? 0 : vncOwner.gateway.port;
        vncGatewayPath = vncOwner.gateway === null ? '/vnc' : vncOwner.gateway.path;
        vncRepeaterMode = vncOwner.gateway === null ? vncHost.repeaterMode : vncOwner.gateway.repeaterMode;
        // mode12 pairs the viewer with the target VNC server.  A host record
        // owns that target ID; the gateway target is only a legacy fallback
        // for records created by the pre-v2 relay form.
        vncRepeaterTarget = vncHost.host.trim() !== '' ? vncHost.host.trim() :
          (vncOwner.gateway === null ? '' : vncOwner.gateway.targetId);
        vncTls = vncHost.tls || (vncOwner.gateway !== null && vncOwner.gateway.tls);
        vncExpectedFingerprint = vncTls ? this.vncTrust.trustedFingerprint(vncHost.id) : '';
        const gatewayAvailability = vncGatewayAvailability(vncHost.transport, vncTls,
          vncOwner.gateway !== null && vncOwner.gateway.tokenConfigured, vncRepeaterMode);
        if (!gatewayAvailability.enabled) {
          throw new Error(gatewayAvailability.message + ' [' + gatewayAvailability.code + ']');
        }
        if (vncHost.securityPolicy === 'secure_only' && !vncTls) {
          throw new Error('VNC 当前安全策略要求 TLS，请在 VNC 主机或网关中开启 TLS [E-VNC-TLS-REQUIRED]');
        }
        if (vncHost.transport === 'ultravnc_repeater' && vncRepeaterTarget.trim() === '') {
          throw new Error('VNC Repeater 目标 ID 为空 [E-VNC-PAIRING-TARGET]');
        }
      }
      const rustDeskDirect: boolean = host.protocol === 'rustdesk' && host.rustdeskDirectEnabled;
      const directHost: string = host.rustdeskDirectHost.trim();
      if (rustDeskDirect && directHost.length === 0) {
        throw new Error('RustDesk 直连地址为空，请在主机编辑中填写局域网地址 [E-RUSTDESK-DIRECT-HOST]');
      }
      let sessionHost: string = rustDeskDirect ? directHost : host.host;
      let sessionPort: number = rustDeskDirect ?
        normalizeRustDeskPort(host.rustdeskDirectPort, RUSTDESK_PEER_TCP_PORT) : host.port;
      if (host.protocol === 'rustdesk' && !rustDeskDirect) {
        const rustDeskError: string = rustDeskConnectionError({
          directEnabled: false,
          directHost: '',
          directPort: host.rustdeskDirectPort,
          relayId: host.rustdeskRelayId,
          relayExists: rustDeskRelay !== undefined,
          relayHost: rustDeskRelay ? rustDeskRelay.idServer : '',
          relayPort: rustDeskRelay ? rustDeskRelay.idServerPort : 0,
          relayKey: rustDeskRelay ? rustDeskRelay.key : '',
          relayKeyMode: rustDeskRelay ? rustDeskRelay.keyMode : 'auto',
          proManaged: host.rustdeskProManaged && host.sourceType === 'rustdesk_pro' &&
            rustDeskRelay !== undefined && rustDeskControlPlaneRequiresAccount(rustDeskRelay.controlPlaneProfile)
        });
        if (rustDeskError !== '') { throw new Error(rustDeskError + ' [E-RUSTDESK-CONFIG]'); }
        sessionHost = rustDeskRelay?.idServer.trim() ?? '';
        sessionPort = normalizeRustDeskPort(rustDeskRelay?.idServerPort ?? 0);
      }
      const cfg: SessionConfig = {
        protocol: host.protocol,
        host: sessionHost,
        port: sessionPort,
        username: credentials.username,
        password: isVnc ? vncPassword :
          (host.protocol === 'rdp' && rdpAuthMode !== 'password' ? '' : host.password),
        width: w,
        height: h,
        customHostname: host.customHostname,
        gatewayHost: host.gatewayHost,
        gatewayPort: host.gatewayPort,
        domain: credentials.domain,
        codec: '',
        multiMonitor: desktop.multiMonitor,
        monitorCount: desktop.monitorCount,
        colorDepth: desktop.colorDepth,
        rdpAuthIdentityMode: host.protocol === 'rdp' ? (AppStorage.get<number>('rdpAuthIdentityMode') ?? 1) : 0,
        rdpAuthMode: rdpAuthMode,
        rdpRestrictedAdminSecretSource: rdpRestrictedAdminSecretSource,
        rdpRestrictedAdminHash: rdpRestrictedAdminHash,
        authMethod: isVnc ? 'password' : (useKey ? 'publickey' : 'password'),
        privateKeyPem: useKey ? keyData : '',
        privateKeyPassphrase: keyPassphrase,
        // RustDesk fields are deliberately neutral for VNC.  VNC settings do
        // not read or inherit RustDesk/RDP preferences.
        rdImageQuality: host.protocol === 'rustdesk' ? (AppStorage.get<number>('rustdeskImageQuality') ?? 1) : 1,
        rdDirectIp: rustDeskDirect,
        rdDirectPort: sessionPort,
        rdLanDiscovery: host.protocol === 'rustdesk' ? (AppStorage.get<boolean>('rustdeskLanDiscovery') ?? true) : false,
        rdPrivacyMode: host.protocol === 'rustdesk' ? (AppStorage.get<boolean>('rustdeskPrivacyMode') ?? false) : false,
        rdAudioEnabled: host.protocol === 'rdp' ?
          (AppStorage.get<boolean>('rdpAudioEnabled') ?? true) :
          (host.protocol === 'rustdesk' ? (AppStorage.get<boolean>('rustdeskAudioEnabled') ?? true) : false),
        rdClipboardEnabled: host.protocol === 'rustdesk' ?
          (AppStorage.get<boolean>('rustdeskClipboardEnabled') ?? true) :
          (host.protocol === 'rdp' ? (AppStorage.get<boolean>('rdpClipboardEnabled') ?? true) : false),
        rdDriveName: host.protocol === 'rdp' ? rdpDriveName : '',
        rdDrivePath: rdpDrivePath,
        expectedRdpCertificateFingerprintSha256: host.rdpCertificateFingerprintSha256,
        rdpAllowUntrustedRoot: host.rdpCertificateAllowUntrustedRoot,
        rdpAllowHostMismatch: host.rdpCertificateAllowHostMismatch,
        rdPasswordMode: host.rustdeskPasswordMode,
        rdAuthMode: rustDeskAuthModeForConnection(rustDeskDirect, host.rustdeskAuthMode) ===
          'request_approval' ? 1 : 0,
        rdRelayId: host.rustdeskRelayId,
        rdAccountId: rdAccountId,
        rdServerKey: rdServerKey,
        rdServerKeyMode: rdServerKeyMode,
        rdRelayPort: rustDeskRelayFallbackPort(rustDeskRelay ?? null),
        rdAccessToken: rdAccessToken,
        vncTransport: isVnc && vncOwner !== null ? vncOwner.host.transport : 'direct_tcp',
        vncGatewayHost: isVnc ? vncGatewayHost : '',
        vncGatewayPort: isVnc ? vncGatewayPort : 0,
        vncGatewayPath: isVnc ? vncGatewayPath : '/vnc',
        vncRepeaterMode: isVnc ? vncRepeaterMode : 'mode12',
        vncRepeaterTarget: isVnc ? vncRepeaterTarget : '',
        vncTls: isVnc && vncOwner !== null ? vncTls : false,
        vncViewOnly: isVnc && vncOwner !== null ? vncOwner.host.viewOnly : true,
        vncClipboardEnabled: isVnc && vncOwner !== null ? vncOwner.host.clipboardEnabled : false,
        vncSecurityPolicy: isVnc && vncOwner !== null ? vncOwner.host.securityPolicy : 'secure_only',
        vncConnectTimeoutMs: isVnc && vncOwner !== null ? vncOwner.settings.connectTimeoutMs : 10000,
        vncAuthTimeoutMs: isVnc && vncOwner !== null ? vncOwner.settings.authTimeoutMs : 15000,
        vncFirstFrameTimeoutMs: isVnc && vncOwner !== null ? vncOwner.settings.firstFrameTimeoutMs : 15000,
        vncExpectedCertificateFingerprintSha256: isVnc ? vncExpectedFingerprint : ''
      };
      // 编码偏好单独处理 (0=auto → 不强制)
      if (rdCodecVal > 0) {
        const codecMap: Record<number, string> = { 1: 'VP8', 2: 'VP9', 3: 'AV1', 4: 'H264', 5: 'H265' };
        cfg['codec'] = codecMap[rdCodecVal] || '';
      }

      hilog.info(RD_DOMAIN, RD_TAG, 'Protocol codec effective: proto=' + host.protocol +
        ' pref=' + rdCodecVal.toString() +
        ' decoderCodec=' + decoderCodec.toString() + ' cfgCodec=' + (cfg['codec'] || 'auto'));
      hilog.info(RD_DOMAIN, RD_TAG, 'NAPI connect: proto=' + cfg['protocol'] +
        ' host=' + maskHost(String(cfg['host'] ?? '')) + ':' + cfg['port'] +
        ' audio=' + (cfg.rdAudioEnabled ? 'on' : 'off') +
        ' clipboard=' + (cfg.rdClipboardEnabled ? 'on' : 'off') +
        ' driveName=' + rdpDriveName +
        ' drive=' + (cfg.rdDrivePath && cfg.rdDrivePath.length > 0 ? cfg.rdDrivePath : 'off'));
      let sid: number = 0;
      try {
        sid = this.loader.connect(cfg);
      } finally {
        // The native adapter owns its own asynchronous copy after connect;
        // never keep the local session-config reference alive on this side.
        cfg.rdpRestrictedAdminHash = '';
        rdpRestrictedAdminHash = '';
      }
      hilog.info(RD_DOMAIN, RD_TAG, 'NAPI connect returned: ' + sid);
      if (sid <= 0) {
        let errMsg: string = '连接失败 [E-CONNECT-' + Math.abs(sid) + ']';
        if (sid === -1) { errMsg = '协议 "' + host.protocol + '" 未找到 [E-CONNECT-1]'; }
        else if (sid === -2 && host.protocol === 'rustdesk') { errMsg = 'RustDesk helper 未运行 [E-CONNECT-2]'; }
        else if (sid === -2) { errMsg = '连接被拒绝 (' + host.host + ':' + host.port + ') [E-CONNECT-2]'; }
        else if (sid === -3) { errMsg = 'RustDesk helper 未运行 [E-CONNECT-3]'; }
        else if (sid === -40 && host.protocol === 'rustdesk') {
          errMsg = '当前 RustDesk helper 不支持请求被控端批准，请切换到真实 FFI 核心或填写设备密码 [E-RUSTDESK-APPROVAL-UNSUPPORTED]';
        }
        else if (sid === -41 && host.protocol === 'rustdesk') {
          errMsg = '请求被控端批准不能用于直连模式，请关闭直连或改用设备密码 [E-RUSTDESK-DIRECT-APPROVAL]';
        }
        else if (sid === -50 && host.protocol === 'rdp' && rdpAuthMode === 'restricted_admin') {
          errMsg = 'Restricted Admin NTLM Hash 无效或无法配置，请在主机编辑中重新输入 [E-RDP-AUTH-HASH]';
        }
        else if (sid === -50 && host.protocol === 'rdp') {
          errMsg = 'RDP 认证参数无效，请重新选择认证方式并保存 [E-RDP-AUTH-CONFIG]';
        }
        else if (sid === -31 && host.protocol === 'rustdesk') { errMsg = 'RustDesk 握手失败，请查看 FFI 日志 [E-CONNECT-31]'; }
        throw new Error(errMsg);
      }
      this.sessionId = sid;
      this.inputForwardReady = false;
      const rustDeskApprovalWait: boolean = host.protocol === 'rustdesk' &&
        rustDeskAuthModeForConnection(host.rustdeskDirectEnabled, host.rustdeskAuthMode) ===
        'request_approval';
      const nativeReady: boolean = await this.waitForNativeConnected(
        sid, host.protocol === 'rustdesk' ? (rustDeskApprovalWait ? 120000 : 120000) : 45000,
        attemptId, host.protocol, host);
      if (!nativeReady) {
        return;
      }

      this.nativeHandles.attachConnectedSession(sid, this.remoteProtocolOf(host));
      this.connected = true;
      this.connecting = false;
      if (host.protocol === 'rustdesk' && this.rustdeskShowDiagnostics) {
        this.startRustDeskDiagnosticsPolling();
      }
      this.startRemoteCursorPolling(sid);
      this.recordActiveSession(host, sid, true);
      await this.prepareRemoteSessionPipForForeground(host, sid);
      this.persistRustDeskSessionAuth(host);
      // T-171: 连接成功后显示悬浮胶囊
      this.initHandlePosition();
      this.handleVisible = true;
      if (host.protocol === 'rustdesk' && this.rustdeskShowDiagnostics) {
        this.initRustDeskDiagnosticsDock();
      }
      this.promptPhysicalKeyboardLayout();
      if (host.protocol === 'rdp') {
        this.startRdpRenderWatchdog(sid, attemptId);
        this.startRdpNativeStateMonitor(sid, attemptId);
        setTimeout((): void => {
          if (this.sessionId === sid && this.connected && this.connectAttemptId === attemptId) {
            this.inputForwardReady = true;
            hilog.info(RD_DOMAIN, RD_TAG, 'RDP input forwarding enabled after video-stability gate');
            this.scheduleRemoteInputFocus('rdp-input-ready');
          }
        }, 2000);
      } else {
        this.inputForwardReady = true;
        this.scheduleRemoteInputFocus('connect-success');
      }
      if (host.protocol === 'rustdesk') {
        await this.applyRustDeskOrientationPolicy('connect-success');
      } else {
        await this.setPreferredOrientation(window.Orientation.LANDSCAPE, 'LANDSCAPE');
      }
      await this.setRemoteKeepScreenOn(true);
      await this.setRemoteNavigationHidden(true, 'connect-success');
      // VNC 使用独立的 vncrecord owner，不得把 transient `vnc:<id>` 投影
      // 回混合 remotehosts；RDP/RustDesk 保持原有最近连接时间行为。
      if (host.protocol !== 'vnc') {
        await this.srv.updateLastConnected(host.id);
      }
      this.startClipboardBridgeBestEffort(sid, attemptId,
        this.clipboardBridgeEnabledForSession());
    } catch (err) {
      rdpRestrictedAdminHash = '';
      this.clearRdpRenderWatchdog();
      this.clearRdpNativeStateMonitor();
      this.clearRemoteCursorPolling(true, 'connect-error');
      // 停止剪贴板桥
      if (this.clipboardBridge !== null) {
        this.clipboardBridge.stopMonitoring();
        this.clipboardBridge = null;
      }
      this.setRemoteKeepScreenOn(false);
      this.setRemoteNavigationHidden(false, 'connect-failed');
      if (this.sessionId > 0) {
        this.loader.disconnect();
        this.sessionId = -1;
        this.rustDeskDisplaySwitchPending = -1;
        this.rustDeskDisplaySwitchStartedAtMs = 0;
      }
      this.showRustDeskTwoFactorSheet = false;
      this.rustDeskTwoFactorSessionId = -1;
      this.rustDeskTwoFactorAutoAttemptSessionId = -1;
      this.rustDeskTwoFactorInput = '';
      this.rustDeskTwoFactorError = '';
      this.rustDeskTwoFactorSubmitting = false;
      this.nativeHandles.markProtocolDisconnected();
      this.activeSessionRegistry.clear('connect-failed');
      this.clearRemoteInputFocusSchedule();
      this.hardwareKeyboardProxyActive = false;
      this.inputForwardReady = false;
      this.connectStarted = false;
      this.connecting = false;
      const errObj: Error = err as Error;
      this.connectionError = '无法建立远程连接';
      const rawConnectionDetail: string = errObj.message ? errObj.message : '未知连接错误 [E-CONNECT-UNKNOWN]';
      let rustDeskErrorKind: RustDeskProNativeErrorKind = classifyRustDeskProNativeError(rawConnectionDetail);
      if (rustDeskErrorKind === 'unknown' && host.protocol === 'rustdesk' &&
        host.rustdeskAuthMode === 'request_approval' && rawConnectionDetail.indexOf('等待远端批准超时') >= 0) {
        rustDeskErrorKind = 'approval_timeout';
      }
      this.connectionErrorDetail = rustDeskNativeErrorDetail(rawConnectionDetail);
      if (this.isProRustDeskHost(host) && rustDeskErrorKind !== 'unknown') {
        const controlPlaneProfile: RustDeskControlPlaneProfile = rustDeskRelay === undefined
          ? RUSTDESK_CONTROL_PLANE_DEFAULT : rustDeskRelay.controlPlaneProfile;
        if (rustDeskErrorKind === 'pro_session_expired' &&
          canInvalidateRustDeskProSession(rawConnectionDetail, controlPlaneProfile)) {
          const accountId: string = rustDeskProAccountIdForConnection(
            host.rustdeskProAccountId, host.rustdeskAccountId);
          this.proSync.markConnectionSessionExpired(accountId, 'connection_token_expired',
            rdAccessTokenFingerprint, rdAccessTokenGeneration);
        }
        this.connectionErrorDetail = rustDeskProNativeErrorMessage(
          rustDeskErrorKind, host.rustdeskAuthMode);
      }
      // VNC 没有 remotehosts 健康字段；它的 TLS 首次信任必须在 native
      // 清理完成后进入独立 trust 确认流程，确认后由该 owner 重新连接。
      if (host.protocol === 'vnc' && vncHost !== null) {
        this.handleVncTrustRequired(vncHost, this.connectionErrorDetail);
      } else {
        // 连接失败也要立即刷新普通主机的本机健康状态；云写入由服务按
        // 节流策略处理，页面监听器仍会立刻收到 UNKNOWN。
        await this.srv.updateConnectionHealth(host.id, -1, false);
      }
      if (this.isProRustDeskHost(host) && this.shouldOfferRustDeskAuthRetry(this.connectionErrorDetail)) {
        const fresh: RemoteHost | undefined = this.srv.getHost(host.id);
        if (fresh) { this.pendingHost = RemoteHost.fromJSON(fresh.toJSON()); }
        this.connectionError = '';
        this.connectionErrorDetail = '';
        this.connecting = true;
        this.openRustDeskAuthSheet('上次认证未完成，请重新选择设备密码或请求远端批准。');
      }
      if (host.protocol === 'rdp') {
        const model: RdpSessionErrorDialogModel =
          rdpSessionErrorFromNativeMessage(this.connectionErrorDetail, '0x10');
        this.showRdpSessionErrorModel(model, 'rdp-connect-failure');
      }
      console.error('[RD-DIAG] Connection failed: ' + safeError(this.connectionErrorDetail));
    }
  }

  private async setRemoteKeepScreenOn(enabled: boolean): Promise<void> {
    if (this.keepScreenOnActive === enabled) {
      return;
    }
    try {
      const ctx = this.getUIContext().getHostContext();
      if (!ctx) {
        hilog.warn(RD_DOMAIN, RD_TAG, 'setWindowKeepScreenOn skipped: host context is null');
        return;
      }
      const win: window.Window = await window.getLastWindow(ctx);
      await win.setWindowKeepScreenOn(enabled);
      this.keepScreenOnActive = enabled;
      hilog.info(RD_DOMAIN, RD_TAG, 'setWindowKeepScreenOn(' + (enabled ? 'true' : 'false') + ') OK');
    } catch (err) {
      const errObj: Error = err as Error;
      hilog.warn(RD_DOMAIN, RD_TAG, 'setWindowKeepScreenOn(' + (enabled ? 'true' : 'false') +
        ') failed: ' + (errObj.message ? errObj.message : JSON.stringify(err)));
    }
  }

  private async applyRustDeskOrientationPolicy(reason: string, sessionPending: boolean = false): Promise<void> {
    const host: RemoteHost | null = this.pendingHost;
    const protocol: string = host === null ? '' : host.protocol;
    const adaptiveOrientationEnabled: boolean = host !== null &&
      canUseRustDeskAdaptiveOrientation(protocol, host.rustdeskTargetDevice,
        host.rustdeskAdaptiveOrientation, host.sourceType, host.rustdeskProManaged,
        host.rustdeskProPlatform);
    const policy = rustDeskOrientationPolicy(protocol, this.isDesktopDevice,
      this.connected, this.renderPreservedInPip, adaptiveOrientationEnabled, sessionPending);
    if (policy === 'auto-rotate') {
      await this.setPreferredOrientation(window.Orientation.AUTO_ROTATION,
        'RUSTDESK-AUTO-ROTATION-' + reason);
    } else if (policy === 'landscape') {
      await this.setPreferredOrientation(window.Orientation.LANDSCAPE,
        'RUSTDESK-LANDSCAPE-' + reason);
    }
  }

  private async setPreferredOrientation(orientation: window.Orientation, label: string): Promise<void> {
    try {
      const ctx = this.getUIContext().getHostContext();
      if (!ctx) {
        hilog.warn(RD_DOMAIN, RD_TAG, 'setPreferredOrientation skipped: host context is null');
        return;
      }
      const win: window.Window = await window.getLastWindow(ctx);
      await win.setPreferredOrientation(orientation);
      this.orientationApplied = orientation !== window.Orientation.UNSPECIFIED;
      this.isLandscape = orientation === window.Orientation.LANDSCAPE ||
        orientation === window.Orientation.AUTO_ROTATION_LANDSCAPE ||
        orientation === window.Orientation.USER_ROTATION_LANDSCAPE;
      hilog.info(RD_DOMAIN, RD_TAG, 'setPreferredOrientation(' + label + ') OK');
    } catch (err) {
      const errObj: Error = err as Error;
      hilog.warn(RD_DOMAIN, RD_TAG, 'setPreferredOrientation(' + label + ') failed: ' +
        (errObj.message ? errObj.message : JSON.stringify(err)));
    }
  }

  // 底部边缘上滑的“唤起导航/返回主页”由系统仲裁；远程 XComponent 不注册自定义上滑，避免吞掉远程触控。
  private async setRemoteNavigationHidden(hidden: boolean, reason: string): Promise<void> {
    const protocol: string = this.currentProtocolName();
    const targetHidden: boolean = hidden && shouldHideRemoteNavigation(protocol, this.connected);
    const forceApply: boolean = reason === 'foreground-restore';
    if (!forceApply && this.remoteNavigationHidden === targetHidden) {
      return;
    }
    try {
      const ctx = this.getUIContext().getHostContext();
      if (!ctx) {
        hilog.warn(RD_DOMAIN, RD_TAG,
          (targetHidden ? 'E-IMMERSIVE-NAV-HIDE' : 'E-IMMERSIVE-NAV-RESTORE') +
            ': host context is null reason=' + reason);
        return;
      }
      const win: window.Window = await window.getLastWindow(ctx);
      await win.setSpecificSystemBarEnabled('navigation', !targetHidden, false);
      try {
        // API 23 documents this name, but some device families do not support it.
        await win.setSpecificSystemBarEnabled('navigationIndicator', !targetHidden, false);
      } catch (indicatorErr) {
        hilog.warn(RD_DOMAIN, RD_TAG,
          'E-IMMERSIVE-NAV-INDICATOR: unsupported or failed reason=' + reason +
            ' err=' + JSON.stringify(indicatorErr));
      }
      this.remoteNavigationHidden = targetHidden;
      hilog.info(RD_DOMAIN, RD_TAG,
        'remote navigation ' + (targetHidden ? 'hidden' : 'restored') +
          ' protocol=' + protocol + ' reason=' + reason);
    } catch (err) {
      hilog.warn(RD_DOMAIN, RD_TAG,
        (targetHidden ? 'E-IMMERSIVE-NAV-HIDE' : 'E-IMMERSIVE-NAV-RESTORE') +
          ': failed reason=' + reason + ' err=' + JSON.stringify(err));
    }
  }

  private disconnectAndCleanup(reason: string): void {
    // VNC passwords are connection-scoped memory only. The native session has
    // already received its copy; never retain the transient value across a
    // page/session teardown.
    this.vncTransientPassword = '';
    this.vncAuthResolved = false;
    this.releaseCanvasPinchInput('disconnect-' + reason);
    this.restoreRemoteSystemPointer('disconnect-' + reason);
    // Cancel a pending restore continuation before starting explicit teardown.
    // Otherwise a late PIP stop promise could recreate a page renderer after
    // the user has already disconnected or left the app.
    this.restoreInProgress = false;
    this.clearPipRestoreRetry();
    this.restoreOperationId += 1;
    this.clearPipContentSizeRefresh();
    if (this.cleanupStarted && !this.renderPreservedInPip && !this.bgRestorePending) {
      return;
    }
    this.stopRustDeskDiagnosticsPolling(true);
    this.cleanupStarted = true;
    this.renderPreservedInPip = false;
    this.pipSurfaceTransferInProgress = false;
    const cleanupStartedAtMs: number = Date.now();
    if (shouldRestoreRemoteNavigation(reason, false)) {
      this.setRemoteNavigationHidden(false, reason);
    }
    this.clearRemoteInputFocusSchedule();
    this.hardwareKeyboardProxyActive = false;
    this.resetRemoteImeSession('disconnect-' + reason);
    this.resetTouchpadPointerCurve();
    this.discardPendingMouseMove();
    const previousCursorX: number = this.remoteCursorX;
    const previousCursorY: number = this.remoteCursorY;
    const previousCursorReady: boolean = this.remoteCursorReady;
    this.remoteCursorReady = false;
    this.remoteCursorPreciseX = 960;
    this.remoteCursorPreciseY = 540;
    this.remoteCursorX = 960;
    this.remoteCursorY = 540;
    this.remoteCursorMotion = createRemoteCursorMotionState(960, 540);
    this.touchpadPointerDown = false;
    this.invalidateRemoteCursorViewIfChanged(previousCursorX, previousCursorY,
      previousCursorReady);
    this.bgRestorePending = false; // 清除任何待恢复状态
    this.activeSessionRegistry.clear(reason);
    this.preAuthenticatedSessionPending = false;
    this.clearRdpRenderWatchdog();
    this.clearRdpNativeStateMonitor();
    this.clearRemoteCursorPolling(true, reason);
    hilog.info(RD_DOMAIN, RD_TAG, '[RDP-SHUTDOWN] phase=arkts-entry reason=' + reason +
      ' sessionId=' + this.sessionId.toString());
    // T-171: 断开时隐藏胶囊和面板 + 释放所有修饰键
    this.handleVisible = false;
    this.rustDeskDiagnosticsDockExpanded = false;
    this.modifierPanelMounted = false;
    this.modifierPanelVisible = false;
    this.shortcutPanelVisible = false;
    this.releaseAllHeldKeys();
    this.resetAllLatches();
    this.resetRemoteModDown();
    this.resetPhysicalModifiers();
    this.fnLayer = false;
    // 停止剪贴板桥
    if (this.clipboardBridge !== null) {
      this.clipboardBridge.stopMonitoring();
      this.clipboardBridge = null;
    }
    this.unregisterKeyboardAvoidListener();
    try {
      this.connectAttemptId++;
      this.inputForwardReady = false;
      const shouldRestoreOrientation: boolean = this.orientationApplied;
      this.scheduleNativeDisconnectAfterPip(reason, shouldRestoreOrientation, cleanupStartedAtMs);
    } catch (err) {
      hilog.error(RD_DOMAIN, RD_TAG, '[RDP-SHUTDOWN] phase=arkts-error elapsedMs=' +
        (Date.now() - cleanupStartedAtMs).toString() + ' err=' + JSON.stringify(err));
    }
  }

  /**
   * PIP owns a native renderer and a free-node surface. Do not hand the
   * decoder/renderer to asynchronous protocol teardown until WMS has reported
   * STOPPED or ERROR; otherwise a late PIP callback can render into freed GL
   * state or surface an exit animation after an explicit disconnect.
   */
  private scheduleNativeDisconnectAfterPip(reason: string,
    shouldRestoreOrientation: boolean, cleanupStartedAtMs: number): void {
    if (this.nativeDisconnectPending) {
      return;
    }
    this.nativeDisconnectPending = true;
    const attempt: () => void = (): void => {
      if (!this.cleanupStarted) {
        this.nativeDisconnectPending = false;
        return;
      }
      RemoteSessionPipService.getInstance().stop().then((stopped: boolean): void => {
        if (!stopped) {
          hilog.warn(RD_DOMAIN, RD_TAG,
            'disconnectAndCleanup: PIP terminal barrier pending, native teardown deferred');
          this.nativeDisconnectRetryTimer = setTimeout((): void => {
            this.nativeDisconnectRetryTimer = -1;
            attempt();
          }, 250);
          return;
        }
        this.nativeDisconnectPending = false;
        this.finishNativeDisconnect(reason, shouldRestoreOrientation, cleanupStartedAtMs);
      }).catch((err: Error): void => {
        hilog.warn(RD_DOMAIN, RD_TAG, 'disconnectAndCleanup: PIP stop retry: ' +
          (err.message ? err.message : JSON.stringify(err)));
        this.nativeDisconnectRetryTimer = setTimeout((): void => {
          this.nativeDisconnectRetryTimer = -1;
          attempt();
        }, 250);
      });
    };
    attempt();
  }

  private finishNativeDisconnect(reason: string,
    shouldRestoreOrientation: boolean, cleanupStartedAtMs: number): void {
    try {
      if (this.sessionId > 0 || this.rendererHandle > 0 || this.decoderHandle > 0) {
        if (this.sessionId > 0) {
          this.disableRdpBackgroundVideoPrewarm('disconnect-cleanup');
        }
        this.discardPendingMouseMove();
        if (this.decoderHandle > 0) {
          const detached: boolean = this.loader.detachVideoPipelineForBackground();
          hilog.info(RD_DOMAIN, RD_TAG, 'disconnectAndCleanup: decoder pipeline detached=' +
            (detached ? 'true' : 'false'));
        }
        if (this.rendererHandle > 0) {
          this.markXComponentSurfaceDetached('disconnectAndCleanup');
        }
        const nativeDisconnectStartedAtMs: number = Date.now();
        hilog.info(RD_DOMAIN, RD_TAG, '[RDP-SHUTDOWN] phase=native-disconnect-begin sessionId=' +
          this.sessionId.toString());
        const disconnectRequestId: number = this.loader.disconnect();
        hilog.info(RD_DOMAIN, RD_TAG, '[RDP-SHUTDOWN] phase=native-disconnect-return requestId=' +
          disconnectRequestId.toString() + ' elapsedMs=' +
          (Date.now() - nativeDisconnectStartedAtMs).toString());
        this.sessionId = -1;
        this.rustDeskDisplaySwitchPending = -1;
        this.rustDeskDisplaySwitchStartedAtMs = 0;
        this.rendererHandle = -1;
        this.decoderHandle = -1;
        this.pipRendererHandle = -1;
        this.nativeHandles.markAsyncTeardownTransferred();
      }
      this.clearFileTransferAutoHide();
      this.fileTransferBusy = false;
      this.fileTransferProgress = -1;
      this.fileTransferStatus = '';
      this.clearMouseMoveTimer();
      this.clearTouchIndicatorTimer();
      this.clearTouchRightClickTimer();
      this.stopBackgroundAudioPolling();
      this.clearRestoreFrameRefreshPump();
      this.setRemoteKeepScreenOn(false);
      try {
        const ctx: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
        if (ctx) {
          this.stopSessionLiveView(ctx).catch((_e: Error): void => {
            // Media cleanup is best effort after the PIP barrier is complete.
          });
        }
      } catch (_e) { /* ignore */ }
      try {
        const ctx: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
        if (ctx) {
          RemoteSessionBackgroundTaskService.getInstance().stopSessionTask(ctx);
        }
      } catch (_e) { /* ignore */ }
      if (shouldRestoreOrientation) {
        setTimeout((): void => {
          this.setPreferredOrientation(window.Orientation.UNSPECIFIED, 'UNSPECIFIED');
        }, 250);
      }
      this.connected = false;
      this.connectStarted = false;
      hilog.info(RD_DOMAIN, RD_TAG, '[RDP-SHUTDOWN] phase=arkts-return elapsedMs=' +
        (Date.now() - cleanupStartedAtMs).toString() + ' reason=' + reason);
    } catch (err) {
      hilog.error(RD_DOMAIN, RD_TAG, '[RDP-SHUTDOWN] phase=arkts-error elapsedMs=' +
        (Date.now() - cleanupStartedAtMs).toString() + ' err=' + JSON.stringify(err));
    }
  }

  /**
   * 后台保活: 仅脱附渲染, 保留协议连接和音频管线。
   * 系统通过 home gesture / onBackground 触发。
   */
  private releasePipRenderer(reason: string): void {
    this.releaseCanvasPinchInput('pip-renderer-release-' + reason);
    const ownedHandle: number = this.pipRendererHandle > 0
      ? this.pipRendererHandle : this.rendererHandle;
    const currentHandle: number = this.rendererHandle;
    if (!this.isRdpRemoteSession() && this.decoderHandle > 0 &&
      (this.renderPreservedInPip || ownedHandle === currentHandle)) {
      const detached: boolean = this.loader.detachVideoPipelineForBackground();
      hilog.info(RD_DOMAIN, RD_TAG, 'releasePipRenderer: decoder detached=' +
        detached.toString() + ' reason=' + reason);
    }
    if (ownedHandle > 0) {
      if (ownedHandle === currentHandle && this.nativeHandles.isRenderAttached()) {
        this.nativeHandles.detachRenderForBackground();
      } else {
        this.loader.destroyRendererHandle(ownedHandle);
      }
    }
    if (this.rendererHandle === ownedHandle) {
      this.rendererHandle = -1;
    }
    this.pipRendererHandle = -1;
    this.renderPreservedInPip = false;
    hilog.info(RD_DOMAIN, RD_TAG, 'releasePipRenderer: handle=' +
      ownedHandle.toString() + ' reason=' + reason);
  }

  private async attachRendererToPipSurface(surface: RemoteSessionPipSurface,
    operationGeneration: number): Promise<boolean> {
    this.releaseCanvasPinchInput('pip-surface-transfer');
    const activeSession: ActiveRemoteSessionRecord | null = this.activeSessionRegistry.getActive();
    const isRdp: boolean = this.isRdpRemoteSession();
    const pipService: RemoteSessionPipService = RemoteSessionPipService.getInstance();
    if (!this.cleanupStarted || !this.connected || this.sessionId <= 0 || this.pendingHost === null ||
      this.restoreInProgress || !pipService.isOperationCurrent(operationGeneration) ||
      this.rendererHandle <= 0 || (!isRdp && this.decoderHandle <= 0) ||
      activeSession === null ||
      activeSession.sessionId !== this.sessionId || activeSession.hostId !== this.pendingHost.id ||
      !activeSession.protocolConnected || surface.surfaceId.length === 0 ||
      surface.surfaceWidth <= 0 || surface.surfaceHeight <= 0) {
      hilog.warn(RD_DOMAIN, RD_TAG, 'attachRendererToPipSurface: session is no longer attachable');
      return false;
    }

    try {
      if (!(await this.waitForPipFrameReady(operationGeneration))) {
        hilog.warn(RD_DOMAIN, RD_TAG, 'attachRendererToPipSurface: no real remote frame before timeout');
        return false;
      }
      const currentSession: ActiveRemoteSessionRecord | null = this.activeSessionRegistry.getActive();
      if (this.restoreInProgress || !this.cleanupStarted ||
        !pipService.isOperationCurrent(operationGeneration) || !this.connected ||
        this.sessionId <= 0 || currentSession === null ||
        currentSession.sessionId !== this.sessionId || currentSession.hostId !== this.pendingHost.id ||
        !currentSession.protocolConnected) {
        hilog.warn(RD_DOMAIN, RD_TAG,
          'attachRendererToPipSurface: operation/session changed while waiting for frame');
        return false;
      }
      // Capture the remote media ratio while the page renderer is still alive.
      // After destroyRenderer() the native viewport is intentionally no longer
      // readable, and falling back to the rotated page surface would crop PIP.
      const pipSize: RemoteSessionPipContentSize = this.currentPipContentSize();
      // The page renderer is bound to the page XComponent.  Move the native
      // renderer to the free-node surface before the PIP controller reports
      // success; otherwise the PIP window only retains the last page frame.
      if (!isRdp && this.decoderHandle > 0) {
        const detached: boolean = this.loader.detachVideoPipelineForBackground();
        hilog.info(RD_DOMAIN, RD_TAG, 'attachRendererToPipSurface: decoder pipeline detached=' +
          (detached ? 'true' : 'false'));
      }
      if (this.nativeHandles.isRenderAttached()) {
        this.nativeHandles.detachRenderForBackground();
      } else {
        this.loader.destroyRenderer();
      }
      this.rendererHandle = -1;

      const result = this.loader.reattachRenderForForeground(
        surface.surfaceId, surface.surfaceWidth, surface.surfaceHeight);
      if (!result.ok || result.value === undefined || result.value <= 0) {
        hilog.warn(RD_DOMAIN, RD_TAG, 'attachRendererToPipSurface: renderer init failed code=' +
          result.code + ' msg=' + result.message);
        return false;
      }

      this.rendererHandle = result.value;
      this.pipRendererHandle = result.value;
      this.nativeHandles.markSurfaceAttached(this.rendererHandle);
      if (isRdp) {
        const cachedPresented: boolean = this.loader.presentRdpCachedFrame(this.sessionId);
        const refresh = this.loader.requestFrameRefresh();
        hilog.info(RD_DOMAIN, RD_TAG, 'attachRendererToPipSurface: RDP cached=' +
          cachedPresented.toString() + ' refresh=' + refresh.ok.toString());
        if (!cachedPresented && !refresh.ok) {
          this.releasePipRenderer('rdp-pip-present-failed');
          return false;
        }
      } else {
        if (!this.loader.bindVideoPipeline(this.decoderHandle, this.rendererHandle)) {
          hilog.warn(RD_DOMAIN, RD_TAG, 'attachRendererToPipSurface: decoder pipeline bind failed');
          this.releasePipRenderer('rustdesk-pip-bind-failed');
          return false;
        }
        this.loader.requestDecoderRecovery();
        this.loader.requestFrameRefresh();
      }
      if (this.restoreInProgress || !this.cleanupStarted ||
        !pipService.isOperationCurrent(operationGeneration)) {
        this.releasePipRenderer('pip-attach-operation-cancelled');
        return false;
      }
      this.activeSessionRegistry.markRenderDetached();
      hilog.info(RD_DOMAIN, RD_TAG, 'attachRendererToPipSurface: renderer=' +
        this.rendererHandle.toString() + ' media=' + pipSize.width.toString() + 'x' +
        pipSize.height.toString() + ' surface=' + surface.surfaceId + ' ' +
        surface.surfaceWidth.toString() + 'x' + surface.surfaceHeight.toString());
      return true;
    } catch (err) {
      hilog.warn(RD_DOMAIN, RD_TAG, 'attachRendererToPipSurface: failed ' + JSON.stringify(err));
      if (this.pipRendererHandle > 0 || this.rendererHandle > 0) {
        this.releasePipRenderer('attach-exception');
      }
      return false;
    }
  }

  private handlePipSurfaceChanged(surface: RemoteSessionPipSurface): void {
    if ((!this.renderPreservedInPip && this.pipRendererHandle <= 0) ||
      this.restoreInProgress || this.rendererHandle <= 0 ||
      surface.surfaceId.length === 0 || surface.surfaceWidth <= 0 || surface.surfaceHeight <= 0) {
      return;
    }
    try {
      this.releaseCanvasPinchInput('pip-surface-changed');
      const rebound: boolean = rdpnapi.setXComponentSurfaceId(
        surface.surfaceId, surface.surfaceWidth, surface.surfaceHeight) as boolean;
      if (!rebound) {
        hilog.warn(RD_DOMAIN, RD_TAG, 'handlePipSurfaceChanged: native surface update failed id=' +
          surface.surfaceId);
        return;
      }
      const renderer: number = this.pipRendererHandle > 0
        ? this.pipRendererHandle : this.rendererHandle;
      this.loader.resizeRenderer(renderer, surface.surfaceWidth, surface.surfaceHeight);
      this.invalidateRendererViewportCache();
      hilog.info(RD_DOMAIN, RD_TAG, 'handlePipSurfaceChanged: renderer=' +
        this.rendererHandle.toString() + ' surface=' + surface.surfaceWidth.toString() + 'x' +
        surface.surfaceHeight.toString());
    } catch (err) {
      hilog.warn(RD_DOMAIN, RD_TAG, 'handlePipSurfaceChanged failed: ' + JSON.stringify(err));
    }
  }

  private async detachForBackground(): Promise<void> {
    this.releaseCanvasPinchInput('background-detach');
    if (this.isVncSession()) {
      // VNC has no audio/decoder/PIP migration contract. Disconnecting on
      // background keeps the raw renderer and RFB worker out of RustDesk's
      // shared lifecycle path; the user can reconnect from the VNC owner page.
      this.disconnectAndCleanup('vnc-background-no-pip');
      return;
    }
    if (this.cleanupStarted) {
      return;
    }
    const activeSession: ActiveRemoteSessionRecord | null = this.activeSessionRegistry.getActive();
    if (!this.connected || this.sessionId <= 0 || this.pendingHost === null || activeSession === null ||
      activeSession.sessionId !== this.sessionId || activeSession.hostId !== this.pendingHost.id ||
      !activeSession.protocolConnected) {
      hilog.info(RD_DOMAIN, RD_TAG, 'detachForBackground: skip without active connected session connected=' +
        (this.connected ? 'true' : 'false') + ' sessionId=' + this.sessionId.toString());
      return;
    }
    this.restoreRemoteSystemPointer('background-detach');
    this.stopRustDeskDiagnosticsPolling(true);
    this.cleanupStarted = true;
    this.resetRemoteImeSession('background');
    this.clearRemoteInputFocusSchedule();
    this.hardwareKeyboardProxyActive = false;
    hilog.info(RD_DOMAIN, RD_TAG, 'detachForBackground: preserving protocol + audio');
    this.clearRestoreFrameRefreshPump();
    this.clearRdpRenderWatchdog();
    this.clearRdpNativeStateMonitor();
    this.clearRemoteCursorPolling(false, 'background-detach');

    // 隐藏 UI 元素
    this.handleVisible = false;
    this.rustDeskDiagnosticsDockExpanded = false;
    this.modifierPanelMounted = false;
    this.modifierPanelVisible = false;
    this.shortcutPanelVisible = false;
    this.releaseAllHeldKeys();
    this.resetAllLatches();
    this.resetRemoteModDown();
    this.resetPhysicalModifiers();
    this.fnLayer = false;

    // 停止剪贴板桥 (后台不接收新剪贴板)
    if (this.clipboardBridge !== null) {
      this.clipboardBridge.stopMonitoring();
      this.clipboardBridge = null;
    }

    this.clearMouseMoveTimer();
    this.clearTouchIndicatorTimer();
    this.clearTouchRightClickTimer();
    this.setRemoteKeepScreenOn(false);

    // 暂停输入转发
    this.inputForwardReady = false;

    const backgroundMedia: RemoteSessionMediaSnapshot = this.currentRemoteMediaSnapshot();

    // A VIDEO_PLAY PIP owns a free-node XComponent surface. The native
    // renderer is moved there before PIP reports success. Only fall back to
    // the old detach path if PIP is disabled, unsupported, or failed.
    let pipPreserved: boolean = false;
    let pipContext: common.UIAbilityContext | null = null;
    const pipService: RemoteSessionPipService = RemoteSessionPipService.getInstance();
    this.pipSurfaceTransferInProgress = true;
    try {
      pipContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const liveViewEnabled: boolean = AppStorage.get<boolean>('liveViewEnabled') ?? true;
      const liveViewMode: number = AppStorage.get<number>('liveViewMode') ?? 1;
      const pipLifecycleAction: RemoteSessionPipLifecycleAction = resolveRemoteSessionPipLifecycle(
        liveViewEnabled, liveViewMode, true,
        this.connected && this.sessionId > 0, true, false);
      if (pipContext !== null && this.pendingHost !== null &&
        pipService.isPrepared() &&
        pipLifecycleAction === RemoteSessionPipLifecycleAction.WAIT_FOR_AUTO_START) {
        const pipSize: RemoteSessionPipContentSize = this.currentPipContentSize();
        pipPreserved = await pipService.start(
          pipContext, this.getUIContext(), pipSize.width, pipSize.height,
          (surface: RemoteSessionPipSurface, operationGeneration: number): Promise<boolean> =>
            this.attachRendererToPipSurface(surface, operationGeneration),
          (reason: string): void => this.handleRemoteSessionPipStopped(reason),
          (surface: RemoteSessionPipSurface): void => this.handlePipSurfaceChanged(surface));
      } else {
        // A disabled/notification-only/unprepared session must revoke any
        // foreground controller before the app leaves the window.
        const stopped: boolean = await pipService.stop();
        if (!stopped) {
          throw new Error('PIP controller did not reach terminal state before background fallback');
        }
      }
    } catch (err) {
      hilog.warn(RD_DOMAIN, RD_TAG, 'detachForBackground: PIP start failed, falling back to detached renderer: ' +
        JSON.stringify(err));
      pipPreserved = false;
    }
    if (!pipPreserved) {
      // start() may have failed while WMS was still in ABOUT_TO_START or
      // ABOUT_TO_STOP. Never fall back to a detached native renderer until
      // that controller has reached a terminal state, otherwise the pending
      // PIP callback can still target the old renderer/surface.
      const stopped: boolean = await pipService.stop();
      if (!stopped) {
        this.pipSurfaceTransferInProgress = false;
        throw new Error('PIP controller did not reach terminal state before renderer fallback');
      }
    }
    this.renderPreservedInPip = pipPreserved;
    this.pipSurfaceTransferInProgress = false;
    if (pipPreserved) {
      this.schedulePipContentSizeRefresh();
      this.disableRdpBackgroundVideoPrewarm('pip-active');
      hilog.info(RD_DOMAIN, RD_TAG, 'detachForBackground: PIP owns free-node surface, renderer preserved');
    } else {
      this.clearPipContentSizeRefresh();
      this.applyBackgroundVideoPrewarm(backgroundMedia, 'detach');
    }

    // 仅脱附渲染, 不触碰协议连接、解码器和音频.
    // 注意: 不销毁解码器 — destroyDecoder 会级联断开协议连接.
    if (!pipPreserved) {
      if (this.decoderHandle > 0 && !this.isRdpRemoteSession()) {
        this.loader.detachVideoPipelineForBackground();
      }
      const rendererHandleBeforeDetach: number = this.rendererHandle;
      if (this.rendererHandle > 0) {
        this.nativeHandles.detachRenderForBackground();
        this.rendererHandle = -1;
      }
      this.pipRendererHandle = -1;
      if (shouldInvalidateSurfaceAfterBackgroundDetach(rendererHandleBeforeDetach, this.sessionId)) {
        this.surfaceReady = false;
        hilog.info(RD_DOMAIN, RD_TAG, 'detachForBackground: surface invalidated after render detach');
      }
      if (this.pendingHost !== null && this.sessionId > 0) {
        this.recordActiveSession(this.pendingHost, this.sessionId, false);
        this.activeSessionRegistry.markRenderDetached();
      }
    }

    // 启动后台保活任务
    try {
      const ctx: common.UIAbilityContext = pipContext ??
        (this.getUIContext().getHostContext() as common.UIAbilityContext);
      if (ctx && this.pendingHost !== null) {
        const info: RemoteSessionBgInfo = {
          hostId: this.pendingHost.id,
          sessionId: this.sessionId,
          resumeRemoteSession: true,
          protocolLabel: this.pendingHost.protocol === 'rdp' ? 'RDP' : 'RustDesk',
          hostAddress: this.pendingHost.host,
          hasAudio: backgroundMedia.hasAudio,
          hasVideo: backgroundMedia.hasVideo
        };
        this.startRemoteSessionBackgroundTask(ctx, info).then((started: boolean): void => {
          if (started) {
            hilog.info(RD_DOMAIN, RD_TAG, 'detachForBackground: background task active protocol=' +
              info.protocolLabel);
          } else {
            hilog.warn(RD_DOMAIN, RD_TAG, 'detachForBackground: background task was rejected protocol=' +
              info.protocolLabel);
          }
        }).catch((err: Error): void => {
          hilog.warn(RD_DOMAIN, RD_TAG, 'detachForBackground: background task async failed: ' +
            (err.message ? err.message : JSON.stringify(err)));
        });

        // 注册后台媒体身份；实际视频帧由上面的 PIP XComponent 承载。
        this.startSessionLiveView(ctx, info).catch((err: Error): void => {
          hilog.warn(RD_DOMAIN, RD_TAG, 'detachForBackground: background media async failed: ' +
            (err.message ? err.message : JSON.stringify(err)));
        });
        this.startBackgroundAudioPolling(ctx, info);
      }
    } catch (err) {
      hilog.warn(RD_DOMAIN, RD_TAG, 'detachForBackground: startSessionTask failed: ' +
        JSON.stringify(err));
    }

    // PIP 使用独立 free-node surface。保持 connected=true，避免 ArkUI
    // 重建页面 XComponent 后把远端会话误判成已断开。
    // 只有旧的 detached fallback 才把页面标为未连接；PIP 停止后再执行同样的脱附。
    if (!pipPreserved) {
      this.connected = false;
      this.connectStarted = false;
    } else {
      hilog.info(RD_DOMAIN, RD_TAG, 'detachForBackground: keep connected UI state for PIP free-node source');
    }
    this.bgRestorePending = true;
    hilog.info(RD_DOMAIN, RD_TAG, 'detachForBackground: bgRestorePending=true, awaiting foreground');
  }

  private handleRemoteSessionPipStopped(reason: string): void {
    const ownsPipRenderer: boolean = this.renderPreservedInPip || this.pipRendererHandle > 0;
    if (!ownsPipRenderer) {
      return;
    }
    // Foreground restore owns the renderer teardown. A terminal PIP callback
    // may arrive before stop() resumes the restore continuation; consuming
    // the ownership flag here would make that continuation skip the release.
    if (this.restoreInProgress && this.bgRestorePending) {
      hilog.info(RD_DOMAIN, RD_TAG, 'PIP stopped during foreground restore; keeping renderer ownership reason=' +
        reason);
      return;
    }
    if (this.bgRestorePending) {
      // The system may finish a PIP close before the page lifecycle callback
      // reaches aboutToAppear. Keep the decoder and PIP renderer ownership
      // until restoreFromBackground consumes them in one ordered operation.
      hilog.info(RD_DOMAIN, RD_TAG, 'PIP stopped before foreground restore; deferring renderer release reason=' +
        reason);
      return;
    }
    hilog.warn(RD_DOMAIN, RD_TAG, 'PIP stopped while remote session was backgrounded reason=' + reason);
    if (!this.cleanupStarted) {
      this.releasePipRenderer('pip-stopped-' + reason);
      return;
    }
    const rendererHandleBeforeDetach: number = this.pipRendererHandle > 0
      ? this.pipRendererHandle : this.rendererHandle;
    this.releasePipRenderer('pip-stopped-background');
    if (shouldInvalidateSurfaceAfterBackgroundDetach(rendererHandleBeforeDetach, this.sessionId)) {
      this.surfaceReady = false;
    }
    if (this.pendingHost !== null && this.sessionId > 0) {
      this.recordActiveSession(this.pendingHost, this.sessionId, false);
      this.activeSessionRegistry.markRenderDetached();
    }
    this.connected = false;
    this.connectStarted = false;
  }

  /**
   * 从后台恢复: 清除保活标志, 停止后台任务, 等待 XComponent 重建渲染。
   */
  private clearPipRestoreRetry(): void {
    if (this.pipRestoreRetryTimer >= 0) {
      clearTimeout(this.pipRestoreRetryTimer);
      this.pipRestoreRetryTimer = -1;
    }
  }

  private schedulePipRestoreRetry(operationId: number): void {
    if (this.pipRestoreRetryTimer >= 0) {
      return;
    }
    this.pipRestoreRetryTimer = setTimeout((): void => {
      this.pipRestoreRetryTimer = -1;
      if (operationId !== this.restoreOperationId || this.cleanupStarted ||
        !this.bgRestorePending || this.sessionId <= 0) {
        return;
      }
      this.restoreInProgress = false;
      this.restoreFromBackground();
    }, 250);
  }

  private restoreFromBackground(): void {
    this.releaseCanvasPinchInput('background-restore');
    if (this.restoreInProgress) {
      hilog.info(RD_DOMAIN, RD_TAG, 'restoreFromBackground: restore already in progress');
      return;
    }
    this.clearPipRestoreRetry();
    this.restoreInProgress = true;
    const operationId: number = ++this.restoreOperationId;
    this.cleanupStarted = false; // 允许重新 attach
    // The free-node PIP surface replaced the page surface while the app was
    // backgrounded. Always reacquire the current page SurfaceId after the
    // terminal PIP state; reusing the old ID can leave RDP's frame pump alive
    // against a surface that is no longer displayed.
    this.surfaceReady = false;
    this.latestSurfaceId = '';
    // bgFlag 保留到清理完成后 → doBackgroundRestoreRender 使用
    this.stopBackgroundAudioPolling();
    this.clearRestoreFrameRefreshPump();
    this.clearPipContentSizeRefresh();
    const continueRestore = (): void => {
      if (operationId !== this.restoreOperationId || !this.restoreInProgress ||
        this.cleanupStarted || !this.bgRestorePending || this.sessionId <= 0) {
        hilog.info(RD_DOMAIN, RD_TAG, 'restoreFromBackground: continuation cancelled id=' +
          operationId.toString());
        return;
      }
      // The PIP renderer is attached to the free-node surface, not the page
      // surface. Release that renderer before the normal foreground reattach
      // path; otherwise the page could resume with a stale PIP surface or two
      // native renderer handles.
      if (this.renderPreservedInPip || this.pipRendererHandle > 0) {
        this.releasePipRenderer('foreground-restore');
        hilog.info(RD_DOMAIN, RD_TAG, 'restoreFromBackground: released PIP renderer, reattaching page surface');
      }
      this.renderPreservedInPip = false;
      // PIP stop has completed and detachVideoPipelineForBackground has
      // joined the decoder thread. Only now may foreground rendering resume.
      this.restoreInProgress = false;
      if (shouldRestoreRenderImmediately(this.bgRestorePending, this.sessionId, this.surfaceReady, this.cleanupStarted)) {
        hilog.info(RD_DOMAIN, RD_TAG, 'restoreFromBackground: surface ready, reattach now');
        this.doBackgroundRestoreRender();
        return;
      }
      if (shouldPollSurfaceAfterForegroundRestore(this.bgRestorePending, this.sessionId, this.surfaceReady,
        this.cleanupStarted)) {
        hilog.info(RD_DOMAIN, RD_TAG, 'restoreFromBackground: surface not ready, polling surface id');
        this.pollSurfaceId(0);
        return;
      }
      // 渲染重建由 onSurfaceCreated → tryStartConnect → doBackgroundRestoreRender 触发
      hilog.info(RD_DOMAIN, RD_TAG, 'restoreFromBackground: waiting for surface');
    };
    try {
      const ctx: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
      if (ctx) {
        // 移除实况窗
        this.stopSessionLiveView(ctx).then((): void => {
          continueRestore();
        }).catch((err: Error): void => {
          hilog.error(RD_DOMAIN, RD_TAG, 'restoreFromBackground: PIP terminal barrier pending; retrying: ' +
            (err.message ? err.message : JSON.stringify(err)));
          this.restoreInProgress = false;
          this.schedulePipRestoreRetry(operationId);
        });
        RemoteSessionBackgroundTaskService.getInstance().stopSessionTask(ctx);
        return;
      }
    } catch (_e) { /* ignore */ }
    continueRestore();
  }

  /**
   * 后台恢复 — 仅重建渲染器, 不新建协议连接。
   */
  private doBackgroundRestoreRender(): void {
    if (this.restoreInProgress) {
      hilog.warn(RD_DOMAIN, RD_TAG, 'doBackgroundRestoreRender: restore teardown is still in progress');
      return;
    }
    // cleanupStarted 已在 restoreFromBackground 中重置为 false
    if (this.cleanupStarted) {
      hilog.warn(RD_DOMAIN, RD_TAG, 'doBackgroundRestoreRender: cleanupStarted=true, aborting');
      return;
    }
    this.bgRestorePending = false; // 防止重入
    this.connectStarted = true;
    try {
      const desktop: DesktopSize = this.desktopSize(this.pendingHost);
      const pageSurface: RemoteSessionPipContentSize = this.currentPageSurfaceSize(desktop.width, desktop.height);
      const surfaceId: string = this.latestSurfaceId.length > 0 ? this.latestSurfaceId : this.xcId;
      // Pro 主机从列表页完成真实鉴权后交接的是“无画布会话”。此时不能走
      // reattach 路径，必须在远程页首次创建 renderer/decoder，再绑定到同一 session。
      const nativeDecoderReady: boolean = this.decoderHandle > 0 || this.loader.getDecoderHandle() > 0;
      const nativeRendererReady: boolean = this.rendererHandle > 0 || this.loader.getRendererHandle() > 0;
      const preAuthenticatedAttach: boolean = shouldCreatePreauthenticatedRustDeskPipeline(
        this.preAuthenticatedSessionPending,
        this.pendingHost === null ? '' : this.pendingHost.protocol,
        nativeDecoderReady,
        nativeRendererReady);
      if (this.preAuthenticatedSessionPending && !preAuthenticatedAttach) {
        hilog.info(RD_DOMAIN, RD_TAG, 'doBackgroundRestoreRender: preauthenticated marker consumed by existing native pipeline' +
          ' decoder=' + (nativeDecoderReady ? '1' : '0') + ' renderer=' + (nativeRendererReady ? '1' : '0'));
        this.preAuthenticatedSessionPending = false;
      }
      if (preAuthenticatedAttach) {
        const renderer: number = this.loader.initRenderer(surfaceId, pageSurface.width, pageSurface.height);
        if (renderer <= 0) {
          throw new Error('预鉴权会话画布初始化失败 [E-RUSTDESK-PREFLIGHT-RENDERER]');
        }
        this.rendererHandle = renderer;
        this.nativeHandles.markSurfaceAttached(renderer);
        this.resetCanvasToDisplayDefault();
        const codecPref: number = AppStorage.get<number>('rustdeskCodec') ?? 0;
        let decoderCodec: number = 3;
        if (codecPref === 1) { decoderCodec = 2; }
        else if (codecPref === 2) { decoderCodec = 3; }
        else if (codecPref === 3) { decoderCodec = 4; }
        else if (codecPref === 4) { decoderCodec = 0; }
        else if (codecPref === 5) { decoderCodec = 1; }
        const decoder: number = this.loader.initDecoder(desktop.width, desktop.height, decoderCodec);
        if (decoder > 0) {
          this.decoderHandle = decoder;
          this.loader.bindVideoPipeline(decoder, renderer);
          this.loader.requestDecoderRecovery();
        }
        this.nativeHandles.attachConnectedSession(this.sessionId, RemoteProtocol.rustdesk);
        this.connected = true;
        this.connecting = false;
        this.applyRustDeskOrientationPolicy('background-preauthenticated').catch((err: Error): void => {
          hilog.warn(RD_DOMAIN, RD_TAG, 'background-preauthenticated orientation failed: ' +
            (err.message ? err.message : JSON.stringify(err)));
        });
        this.resumeRustDeskDiagnosticsAfterForeground();
        this.startRemoteCursorPolling(this.sessionId);
        this.inputForwardReady = true;
        this.scheduleRemoteInputFocus('background-preauthenticated');
        this.activeSessionRegistry.markRenderAttached(surfaceId);
        this.setRemoteKeepScreenOn(true);
        this.setRemoteNavigationHidden(true, 'preauthenticated-session-handoff');
        this.loader.requestFrameRefresh();
        if (this.pendingHost !== null) {
          this.prepareRemoteSessionPipForForeground(this.pendingHost, this.sessionId).catch((err: Error): void => {
            hilog.warn(RD_DOMAIN, RD_TAG, 'doBackgroundRestoreRender: PIP prepare failed ' +
              (err.message ? err.message : JSON.stringify(err)));
          });
        }
        this.preAuthenticatedSessionPending = false;
        // This is a first renderer attachment for an already-authenticated stream,
        // not a foreground restore. The decoder recovery armed above waits for the
        // first keyframe; scheduling the restore watchdog here would recreate a
        // healthy decoder at 7 seconds and cause a visible video stall.
        this.clearRestoreFrameRefreshPump();
        AppStorage.setOrCreate<boolean>('remoteDesktopBgFlag', false);
        hilog.info(RD_DOMAIN, RD_TAG, 'doBackgroundRestoreRender: preauthenticated session attached');
        return;
      }
      const result = this.loader.reattachRenderForForeground(
        surfaceId, pageSurface.width, pageSurface.height);
      if (result.ok && result.value !== undefined && result.value > 0) {
        this.rendererHandle = result.value;
        this.nativeHandles.markSurfaceAttached(this.rendererHandle);
        this.applyCanvasTransform();
        hilog.info(RD_DOMAIN, RD_TAG, 'doBackgroundRestoreRender: renderer reattached handle=' +
          this.rendererHandle.toString());

        if (this.pendingHost !== null && this.pendingHost.protocol === 'rdp' && this.sessionId > 0) {
          const presented: boolean = this.loader.presentRdpCachedFrame(this.sessionId);
          hilog.info(RD_DOMAIN, RD_TAG, 'doBackgroundRestoreRender: rdp cached frame presented=' +
            presented.toString());
          this.disableRdpBackgroundVideoPrewarm('foreground-restore');
        }

        // 重新绑定 decoder pipeline (如果 decoder 仍活跃)
        if (this.decoderHandle > 0 && this.rendererHandle > 0) {
          this.loader.bindVideoPipeline(this.decoderHandle, this.rendererHandle);
          const recoveryArmed: boolean = this.loader.requestDecoderRecovery();
          hilog.info(RD_DOMAIN, RD_TAG, 'doBackgroundRestoreRender: decoder recovery armed=' +
            (recoveryArmed ? 'true' : 'false'));
        }

        // 恢复状态
        this.connected = true;
        this.applyRustDeskOrientationPolicy('background-restore').catch((err: Error): void => {
          hilog.warn(RD_DOMAIN, RD_TAG, 'background-restore orientation failed: ' +
            (err.message ? err.message : JSON.stringify(err)));
        });
        this.resumeRustDeskDiagnosticsAfterForeground();
        this.inputForwardReady = true;
        this.startRemoteCursorPolling(this.sessionId);
        this.scheduleRemoteInputFocus('background-restore');
        this.activeSessionRegistry.markRenderAttached(surfaceId);
        this.setRemoteKeepScreenOn(true);
        if (shouldReapplyRemoteNavigation(this.currentProtocolName(), this.connected, true)) {
          this.setRemoteNavigationHidden(true, 'foreground-restore');
        }
        if (this.clipboardBridge === null) {
          const clipboardEnabled: boolean = this.clipboardBridgeEnabledForSession();
          this.startClipboardBridgeBestEffort(this.sessionId, this.connectAttemptId, clipboardEnabled);
        }
        this.scheduleRestoreFrameRefreshPump();
        if (this.pendingHost !== null) {
          this.prepareRemoteSessionPipForForeground(this.pendingHost, this.sessionId).catch((err: Error): void => {
            hilog.warn(RD_DOMAIN, RD_TAG, 'doBackgroundRestoreRender: PIP prepare failed ' +
              (err.message ? err.message : JSON.stringify(err)));
          });
        }
        hilog.info(RD_DOMAIN, RD_TAG, 'doBackgroundRestoreRender: complete, session resumed');
      } else {
        hilog.error(RD_DOMAIN, RD_TAG, 'doBackgroundRestoreRender: reattachRenderForForeground failed code=' +
          result.code + ' msg=' + result.message);
        // 重新初始化渲染器失败 — 回退到完全断连
        this.disconnectAndCleanup('bg-restore-render-failed');
      }
    } catch (err) {
      hilog.error(RD_DOMAIN, RD_TAG, 'doBackgroundRestoreRender: exception ' + JSON.stringify(err));
      this.disconnectAndCleanup('bg-restore-exception');
    }
    // 清除后台标志
    AppStorage.setOrCreate<boolean>('remoteDesktopBgFlag', false);
  }

  private startClipboardBridgeBestEffort(sessionId: number, attemptId: number, enabled: boolean): void {
    if (!enabled) {
      return;
    }
    const capability = this.currentSessionCapabilities().clipboardSend;
    if (!capability.enabled) {
      hilog.info(RD_DOMAIN, RD_TAG, 'clipboard bridge not started: ' + capability.reason);
      return;
    }
    setTimeout((): void => {
      if (this.sessionId !== sessionId || this.connectAttemptId !== attemptId || !this.connected) {
        return;
      }
      try {
        if (this.clipboardBridge !== null) {
          this.clipboardBridge.stopMonitoring();
        }
        const bridge: ClipboardBridgeService = new ClipboardBridgeService();
        this.clipboardBridge = bridge;
        bridge.startMonitoring((text: string): void => {
          try {
            if (this.sessionId !== sessionId || this.connectAttemptId !== attemptId || !this.connected) {
              return;
            }
            const encoder = new util.TextEncoder();
            const data: Uint8Array = encoder.encode(text);
            this.loader.sendClipboard(sessionId, data.buffer as ArrayBuffer);
          } catch (err) {
            hilog.warn(RD_DOMAIN, RD_TAG, 'clipboard bridge push skipped: ' + JSON.stringify(err));
          }
        }, (): string => this.loader.getSessionClipboardText(sessionId));
        hilog.info(RD_DOMAIN, RD_TAG, 'clipboard bridge started');
      } catch (err) {
        this.clipboardBridge = null;
        hilog.warn(RD_DOMAIN, RD_TAG, 'clipboard bridge start skipped: ' + JSON.stringify(err));
      }
    }, 1500);
  }

  private goBack(): void {
    router.back();
  }

  // ---- XComponent 生命周期回调 ----

  onSurfaceCreated(surfaceId: string): void {
    try {
      hilog.info(RD_DOMAIN, RD_TAG, 'XComponentController.onSurfaceCreated: surfaceId=' + surfaceId);
      this.latestSurfaceId = surfaceId;
      if (this.restoreInProgress) {
        // Keep the page surface ID for the post-teardown reattach, but do not
        // touch the global native surface while the PIP renderer is stopping.
        this.surfaceReady = true;
        hilog.info(RD_DOMAIN, RD_TAG,
          'onSurfaceCreated: foreground restore teardown active, defer native bind');
        return;
      }
      if (this.renderPreservedInPip || this.pipSurfaceTransferInProgress) {
        // A page surface can be recreated while the PIP free node owns the
        // native window. Do not switch the global native surface away from
        // PIP; keep the page id for the foreground reattach path instead.
        this.surfaceReady = true;
        hilog.info(RD_DOMAIN, RD_TAG,
          'onSurfaceCreated: PIP owns native surface, defer page surface bind');
        return;
      }
      const desktop: DesktopSize = this.desktopSize(this.pendingHost);
      this.updateRemoteSize(desktop);
      const pageSurface: RemoteSessionPipContentSize = this.currentPageSurfaceSize(desktop.width, desktop.height);
      const ok: boolean = rdpnapi.setXComponentSurfaceId(
        surfaceId, pageSurface.width, pageSurface.height) as boolean;
      hilog.info(RD_DOMAIN, RD_TAG, 'setXComponentSurfaceId: surfaceId=' + surfaceId +
        ' page=' + pageSurface.width + 'x' + pageSurface.height +
        ' remote=' + desktop.width + 'x' + desktop.height +
        ' ok=' + (ok ? 'true' : 'false'));
      this.surfaceReady = ok;
      this.tryStartConnect();
    } catch (_e) {
      this.surfaceReady = false;
      hilog.error(RD_DOMAIN, RD_TAG, 'setXComponentSurfaceId threw: ' + JSON.stringify(_e));
    }
  }

  onSurfaceDestroyed(_surfaceId: string): void {
    this.releaseCanvasPinchInput('surface-destroyed');
    hilog.info(RD_DOMAIN, RD_TAG, 'XComponentController.onSurfaceDestroyed');
    this.restoreRemoteSystemPointer('surface-destroyed');
    this.surfaceReady = false;
    if (_surfaceId === this.latestSurfaceId) {
      this.latestSurfaceId = '';
    }
    if (this.restoreInProgress || this.renderPreservedInPip || this.pipSurfaceTransferInProgress) {
      hilog.info(RD_DOMAIN, RD_TAG,
        'onSurfaceDestroyed: PIP owns native surface, skip global detach source=' + _surfaceId);
    } else {
      this.markXComponentSurfaceDetached('surfaceDestroyed');
    }
  }

  private onXComponentLoad = (): void => {
    try {
      const regOk: boolean = rdpnapi.registerNativeXComponent() as boolean;
      hilog.info(RD_DOMAIN, RD_TAG, 'XComponent.onLoad: registerNativeXComponent=' + (regOk ? 'OK' : 'Pbuffer'));
    } catch (_e) {
      hilog.error(RD_DOMAIN, RD_TAG, 'registerNativeXComponent threw: ' + JSON.stringify(_e));
    }
    // 主动轮询 surfaceId — API 23 设备上 XComponentController.onSurfaceCreated 不触发
    this.pollSurfaceId(0);
  }

  // 轮询获取 surfaceId (onSurfaceCreated 回调在 API 23 不可用)
  private pollSurfaceId(attempt: number): void {
    if (this.surfaceReady || (this.connectStarted && !this.bgRestorePending)) {
      return;
    }
    try {
      const surfaceId: string = this.xComponentController.getXComponentSurfaceId();
      hilog.info(RD_DOMAIN, RD_TAG, 'pollSurfaceId attempt=' + attempt + ' surfaceId=' +
        (surfaceId ? surfaceId : '(empty)'));
      if (surfaceId && surfaceId.length > 0) {
        this.onSurfaceCreated(surfaceId);
        return;
      }
    } catch (_e) {
      hilog.error(RD_DOMAIN, RD_TAG, 'getXComponentSurfaceId threw: ' + JSON.stringify(_e));
    }
    // 最多重试 20 次, 每次 250ms (共 5 秒)
    if (attempt < 20) {
      setTimeout(() => { this.pollSurfaceId(attempt + 1); }, 250);
    } else {
      hilog.warn(RD_DOMAIN, RD_TAG, 'pollSurfaceId 超时, surface 未创建');
    }
  }

  private onXComponentDestroy = (): void => {
    this.releaseCanvasPinchInput('xcomponent-destroy');
    this.restoreRemoteSystemPointer('xcomponent-destroy');
    if (this.renderPreservedInPip || this.pipSurfaceTransferInProgress) {
      hilog.info(RD_DOMAIN, RD_TAG, 'onXComponentDestroy: PIP owns native surface, skip global detach');
    } else {
      this.markXComponentSurfaceDetached('xcomponentDestroy');
    }
    this.surfaceReady = false;
  }

  private markXComponentSurfaceDetached(source: string): void {
    try {
      rdpnapi.markXComponentSurfaceDestroyed();
    } catch (_e) {
      hilog.warn(RD_DOMAIN, RD_TAG, 'markXComponentSurfaceDestroyed failed from ' + source + ': ' + JSON.stringify(_e));
    }
  }

  // ---- 输入事件转发 (命名避开组件内置 onKeyEvent/onMouse 属性) ----

  // Gesture API 回调 (TapGesture — 单击 = 鼠标左键点击)
  private handleGestureTap(event: GestureEvent): void {
    if (!this.canForwardInput('gesture-tap')) { return; }
    try {
      const localX: number = event.fingerList.length > 0 ? event.fingerList[0].localX : 0;
      const localY: number = event.fingerList.length > 0 ? event.fingerList[0].localY : 0;
      const mapped: MappedPoint = this.mapInputPoint(localX, localY);
      this.logMappedInput('gesture-tap', localX, localY, mapped);
      if (mapped.inside) {
        this.sendMouseNow(mapped.x, mapped.y, 0, true);
        this.sendMouseNow(mapped.x, mapped.y, 0, false);
      }
    } catch (err) {
      hilog.error(RD_DOMAIN, RD_TAG, 'gesture-tap forward failed: ' + JSON.stringify(err));
    }
  }

  private gesturePanActive: boolean = false;

  // PanGesture 回调
  private handleGesturePanStart(event: GestureEvent): void {
    if (!this.canForwardInput('gesture-pan-start')) { return; }
    try {
      const localX: number = event.fingerList.length > 0 ? event.fingerList[0].localX : 0;
      const localY: number = event.fingerList.length > 0 ? event.fingerList[0].localY : 0;
      const mapped: MappedPoint = this.mapInputPoint(localX, localY);
      this.logMappedInput('gesture-pan-start', localX, localY, mapped);
      if (mapped.inside) {
        this.gesturePanActive = true;
        this.sendMouseNow(mapped.x, mapped.y, 0, true);
      }
    } catch (err) {
      hilog.error(RD_DOMAIN, RD_TAG, 'gesture-pan-start forward failed: ' + JSON.stringify(err));
    }
  }

  private handleGesturePanUpdate(event: GestureEvent): void {
    if (!this.gesturePanActive || !this.canForwardInput('gesture-pan-move')) { return; }
    try {
      const localX: number = event.fingerList.length > 0 ? event.fingerList[0].localX : 0;
      const localY: number = event.fingerList.length > 0 ? event.fingerList[0].localY : 0;
      const mapped: MappedPoint = this.mapInputPoint(localX, localY);
      if (mapped.inside) {
        this.queueMouseMove(mapped.x, mapped.y);
      }
    } catch (err) {
      hilog.error(RD_DOMAIN, RD_TAG, 'gesture-pan-move forward failed: ' + JSON.stringify(err));
    }
  }

  private handleGesturePanEnd(event: GestureEvent): void {
    if (!this.gesturePanActive) { return; }
    this.gesturePanActive = false;
    if (!this.canForwardInput('gesture-pan-end')) { return; }
    try {
      const localX: number = event.fingerList.length > 0 ? event.fingerList[0].localX : 0;
      const localY: number = event.fingerList.length > 0 ? event.fingerList[0].localY : 0;
      const mapped: MappedPoint = this.mapInputPoint(localX, localY);
      this.logMappedInput('gesture-pan-end', localX, localY, mapped);
      this.sendMouseNow(mapped.x, mapped.y, 0, false);
    } catch (err) {
      hilog.error(RD_DOMAIN, RD_TAG, 'gesture-pan-end forward failed: ' + JSON.stringify(err));
    }
  }

  // 单指长按 1 秒进入左键拖拽；保留旧函数名以复用清理调用点。
  private clearTouchRightClickTimer(): void {
    if (this.touchHoldDragTimer >= 0) {
      clearTimeout(this.touchHoldDragTimer);
      this.touchHoldDragTimer = -1;
    }
  }

  private clearTouchDirectRightClickTimer(): void {
    if (this.touchDirectRightClickTimer >= 0) {
      clearTimeout(this.touchDirectRightClickTimer);
      this.touchDirectRightClickTimer = -1;
    }
  }

  private startTouchHoldDragTimer(): void {
    this.clearTouchRightClickTimer();
    this.touchHoldDragTimer = setTimeout((): void => {
      this.touchHoldDragTimer = -1;
      if (this.touchFingerCount !== 1 || this.touchMoved || this.touchDragActive || !this.connected) {
        return;
      }
      this.touchDragActive = true;
      this.touchGestureDone = true;
      this.sendMouseNow(this.remoteCursorX, this.remoteCursorY, 0, true);
      this.showRemoteCursorIndicator(TOUCH_INDICATOR_BUTTON_DRAG, false);
      hilog.info(RD_DOMAIN, RD_TAG, 'one-finger hold drag start remote=' +
      this.remoteCursorX.toString() + ',' + this.remoteCursorY.toString());
    }, TOUCH_DRAG_HOLD_MS);
  }

  private startDirectTouchRightClickTimer(): void {
    this.clearTouchDirectRightClickTimer();
    this.touchDirectRightClickTimer = setTimeout((): void => {
      this.touchDirectRightClickTimer = -1;
      if (this.touchFingerCount !== 1 || this.touchMoved || !this.touchLeftDown || !this.connected) {
        return;
      }
      this.sendMouseNow(this.remoteCursorX, this.remoteCursorY, 0, false);
      this.touchLeftDown = false;
      this.sendMouseNow(this.remoteCursorX, this.remoteCursorY, 2, true);
      this.sendMouseNow(this.remoteCursorX, this.remoteCursorY, 2, false);
      this.touchGestureDone = true;
      this.showRemoteCursorIndicator(2, true);
      hilog.info(RD_DOMAIN, RD_TAG, 'direct-touch long-press right-click remote=' +
        this.remoteCursorX.toString() + ',' + this.remoteCursorY.toString());
    }, TOUCH_DIRECT_RIGHT_CLICK_MS);
  }

  private ensureRdpTransferDir(): string {
    try {
      const ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
      const dir: string = ctx.filesDir + '/' + RDP_TRANSFER_DIR_NAME + '_' + this.sanitizedRdpDriveName();
      try {
        fileIo.mkdirSync(dir);
      } catch (_err) {
        // 目录已存在时会抛错；后续打开目标文件会验证路径是否真实可用。
      }
      return dir;
    } catch (_err) {
      hilog.error(RD_DOMAIN, RD_TAG, 'file transfer diagnostic=' + FILE_TRANSFER_DIAG_RDP_DIR);
      return '';
    }
  }

  private createRdpClipboardBatchDir(): string {
    const root: string = this.ensureRdpTransferDir();
    if (root.length === 0) {
      return '';
    }
    this.rdpClipboardBatchSequence = (this.rdpClipboardBatchSequence + 1) % 1000000;
    const dir: string = root + '/clip_' + Date.now().toString() + '_' +
      this.rdpClipboardBatchSequence.toString();
    try {
      fileIo.mkdirSync(dir);
      return dir;
    } catch (_err) {
      hilog.error(RD_DOMAIN, RD_TAG, 'failed to create isolated RDP clipboard batch');
      return '';
    }
  }

  private sanitizedRdpDriveName(): string {
    let out: string = '';
    const source: string = this.rdpDriveName.length > 0 ? this.rdpDriveName : RDP_TRANSFER_DRIVE_NAME;
    for (let i = 0; i < source.length && out.length < 20; i++) {
      const ch: string = source.charAt(i);
      const code: number = ch.charCodeAt(0);
      const alnum: boolean = (code >= 48 && code <= 57) || (code >= 65 && code <= 90) ||
        (code >= 97 && code <= 122);
      if (alnum || ch === '_' || ch === '-') {
        out += ch;
      } else if (ch === ' ' || ch === '.' || ch === '/' || ch === '\\') {
        out += '_';
      }
    }
    return out.length > 0 ? out : RDP_TRANSFER_DRIVE_NAME;
  }

  private async yieldUi(ms: number = 0): Promise<void> {
    await new Promise<void>((resolve: () => void): void => {
      setTimeout(resolve, ms);
    });
  }

  private fileBaseName(uri: string): string {
    let fileName: string = 'file';
    const lastSlash: number = Math.max(uri.lastIndexOf('/'), uri.lastIndexOf('\\'));
    if (lastSlash >= 0 && lastSlash + 1 < uri.length) {
      fileName = uri.substring(lastSlash + 1);
    }
    try {
      fileName = decodeURIComponent(fileName);
    } catch (_err) {
      hilog.warn(RD_DOMAIN, RD_TAG, 'file transfer diagnostic=' + FILE_TRANSFER_DIAG_FILE_NAME);
    }
    return this.sanitizeTransferFileName(fileName);
  }

  private sanitizeTransferFileName(name: string): string {
    const trimmed: string = name.trim();
    const source: string = trimmed.length > 0 ? trimmed : 'file';
    const illegal: string = '\\/:*?"<>|';
    let out: string = '';
    for (let i = 0; i < source.length; i++) {
      const ch: string = source.charAt(i);
      out += illegal.indexOf(ch) >= 0 ? '_' : ch;
    }
    return out.length > 0 ? out : 'file';
  }

  private formatTransferSize(size: number): string {
    if (size >= 1024 * 1024 * 1024) {
      return (size / (1024 * 1024 * 1024)).toFixed(2) + 'GB';
    }
    if (size >= 1024 * 1024) {
      return (size / (1024 * 1024)).toFixed(1) + 'MB';
    }
    if (size >= 1024) {
      return (size / 1024).toFixed(1) + 'KB';
    }
    return size.toString() + 'B';
  }

  private setFileTransferStatus(status: string, progress: number, busy: boolean): void {
    this.clearFileTransferAutoHide();
    this.fileTransferStatus = status;
    this.fileTransferProgress = progress;
    this.fileTransferBusy = busy;
    if (!busy) {
      this.fileTransferHideTimer = setTimeout((): void => {
        this.fileTransferHideTimer = -1;
        this.fileTransferStatus = '';
        this.fileTransferProgress = -1;
      }, 4200);
    }
  }

  private clearFileTransferAutoHide(): void {
    if (this.fileTransferHideTimer >= 0) {
      clearTimeout(this.fileTransferHideTimer);
      this.fileTransferHideTimer = -1;
    }
  }

  private getFileTransferContext(): common.UIAbilityContext | null {
    try {
      return getContext(this) as common.UIAbilityContext;
    } catch (_err) {
      hilog.warn(RD_DOMAIN, RD_TAG, 'file transfer diagnostic=' + FILE_TRANSFER_DIAG_LIVE_CONTEXT);
      return null;
    }
  }

  private createFileTransferTaskId(protocol: TransferProtocol, fileName: string): string {
    return protocol + '-' + Date.now().toString() + '-' + fileName.length.toString();
  }

  private async beginLiveFileTransfer(protocol: TransferProtocol, fileName: string, total: number,
    statusText: string): Promise<string> {
    const ctx: common.UIAbilityContext | null = this.getFileTransferContext();
    if (ctx === null) {
      return '';
    }
    const taskId: string = this.createFileTransferTaskId(protocol, fileName);
    await FileTransferLiveTaskService.getInstance().begin(ctx,
      createTransferSnapshot(taskId, protocol, fileName, 0, total, 'preparing', statusText));
    return taskId;
  }

  private async updateLiveFileTransfer(taskId: string, protocol: TransferProtocol, fileName: string,
    transferred: number, total: number, state: TransferState, statusText: string): Promise<void> {
    if (taskId.length === 0) {
      return;
    }
    await FileTransferLiveTaskService.getInstance().update(
      createTransferSnapshot(taskId, protocol, fileName, transferred, total, state, statusText));
  }

  private async finishLiveFileTransfer(taskId: string, protocol: TransferProtocol, fileName: string,
    transferred: number, total: number, failed: boolean, statusText: string): Promise<void> {
    if (taskId.length === 0) {
      return;
    }
    const ctx: common.UIAbilityContext | null = this.getFileTransferContext();
    if (ctx === null) {
      return;
    }
    if (failed) {
      await FileTransferLiveTaskService.getInstance().fail(ctx,
        createTransferSnapshot(taskId, protocol, fileName, transferred, total, 'failed', statusText));
      return;
    }
    await FileTransferLiveTaskService.getInstance().complete(ctx,
      createTransferSnapshot(taskId, protocol, fileName, total, total, 'completed', statusText));
  }

  private async stageFileForRdpClipboard(uri: string, fileName: string, fileSize: number,
    batchDir: string = ''): Promise<string> {
    const dir: string = batchDir.length > 0 ? batchDir : this.createRdpClipboardBatchDir();
    if (dir.length === 0) {
      this.setFileTransferStatus('[RDP-FILE] RDP 文件传输准备失败', -1, false);
      return '';
    }
    if (fileSize <= 0 || fileSize > RDP_FILE_MAX_BYTES) {
      this.setFileTransferStatus('[RDP-FILE] 文件为空或超过 2GB', -1, false);
      return '';
    }
    let src: fileIo.File | null = null;
    let dst: fileIo.File | null = null;
    let liveTaskId: string = '';
    let copied: number = 0;
    let lastLiveProgress: number = -1;
    try {
      const targetPath: string = dir + '/' + fileName;
      src = fileIo.openSync(uri, fileIo.OpenMode.READ_ONLY);
      dst = fileIo.openSync(targetPath,
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);

      this.setFileTransferStatus('RDP 文件传输进行中 0%', 0, true);
      liveTaskId = await this.beginLiveFileTransfer('rdp', '文件', fileSize,
        'RDP 文件传输进行中');
      while (copied < fileSize) {
        const chunkSize: number = Math.min(REMOTE_FILE_CHUNK_BYTES, fileSize - copied);
        const chunk = new ArrayBuffer(chunkSize);
        const readLen: number = fileIo.readSync(src.fd, chunk);
        if (readLen <= 0) {
          this.setFileTransferStatus('[RDP-FILE] 文件读取中断', -1, false);
          await this.finishLiveFileTransfer(liveTaskId, 'rdp', '文件', copied, fileSize, true,
            '[RDP-FILE] 文件读取中断');
          return '';
        }
        const payload: ArrayBuffer = readLen === chunkSize ? chunk : chunk.slice(0, readLen);
        const written: number = fileIo.writeSync(dst.fd, payload);
        if (written !== readLen) {
          this.setFileTransferStatus('[RDP-FILE] RDP 文件传输写入不完整', -1, false);
          await this.finishLiveFileTransfer(liveTaskId, 'rdp', '文件', copied, fileSize, true,
            '[RDP-FILE] RDP 文件传输写入不完整');
          return '';
        }
        copied += readLen;
        const progress: number = Math.min(1, copied / fileSize);
        const progressPercent: number = Math.floor(progress * 100);
        this.setFileTransferStatus('RDP 文件传输进行中 ' + progressPercent.toString() + '%', progress, true);
        if (progressPercent !== lastLiveProgress) {
          lastLiveProgress = progressPercent;
          await this.updateLiveFileTransfer(liveTaskId, 'rdp', '文件', copied, fileSize, 'transferring',
            'RDP 文件传输进行中 ' + progressPercent.toString() + '%');
        }
        await this.yieldUi(0);
      }
      const readyStatus: string = 'RDP 文件已暂存，正在发布到远端剪贴板';
      await this.finishLiveFileTransfer(liveTaskId, 'rdp', '文件', fileSize, fileSize, false, readyStatus);
      hilog.info(RD_DOMAIN, RD_TAG, 'rdp clipboard file staged size=' + fileSize.toString());
      return targetPath;
    } catch (_err) {
      this.setFileTransferStatus('[RDP-FILE] 文件传输失败 [' + FILE_TRANSFER_DIAG_RDP_COPY + ']', -1, false);
      await this.finishLiveFileTransfer(liveTaskId, 'rdp', '文件', copied, fileSize, true,
        '[RDP-FILE] 文件传输失败 [' + FILE_TRANSFER_DIAG_RDP_COPY + ']');
      hilog.error(RD_DOMAIN, RD_TAG, 'file transfer diagnostic=' + FILE_TRANSFER_DIAG_RDP_COPY);
      return '';
    } finally {
      if (src !== null) {
        try { fileIo.closeSync(src); } catch (_err2) { /* ignore */ }
      }
      if (dst !== null) {
        try { fileIo.closeSync(dst); } catch (_err3) { /* ignore */ }
      }
    }
  }

  private async submitFileToRustDesk(uri: string, fileName: string, fileSize: number): Promise<TransferState> {
    if (fileSize <= 0 || fileSize > RUSTDESK_FILE_MAX_BYTES) {
      this.setFileTransferStatus('[RustDesk-FILE] 文件为空或超过 100MB', -1, false);
      return 'failed';
    }
    let file: fileIo.File | null = null;
    let liveTaskId: string = '';
    let readLen: number = 0;
    try {
      this.setFileTransferStatus('正在读取 ' + fileName + ' 0%', 0, true);
      liveTaskId = await this.beginLiveFileTransfer('rustdesk', fileName, fileSize,
        '正在读取 ' + fileName);
      file = fileIo.openSync(uri, fileIo.OpenMode.READ_ONLY);
      const buf = new ArrayBuffer(fileSize);
      readLen = fileIo.readSync(file.fd, buf);
      if (readLen !== fileSize) {
        this.setFileTransferStatus('[RustDesk-FILE] 文件读取不完整', -1, false);
        await this.finishLiveFileTransfer(liveTaskId, 'rustdesk', fileName, readLen, fileSize, true,
          '[RustDesk-FILE] 文件读取不完整');
        return 'failed';
      }
      this.setFileTransferStatus('正在提交到 RustDesk core ' + fileName, 0.9, true);
      await this.updateLiveFileTransfer(liveTaskId, 'rustdesk', fileName, Math.floor(fileSize * 0.9),
        fileSize, 'transferring', '正在提交到 RustDesk core ' + fileName);
      await this.yieldUi(0);
      const remotePath: string = RUSTDESK_TRANSFER_DIR + '\\' + fileName;
      const ret: number = this.loader.sendFile(this.sessionId, remotePath, buf);
      if (ret < 0) {
        this.setFileTransferStatus('[RustDesk-FILE] 文件传输失败 [' + FILE_TRANSFER_DIAG_RUSTDESK_SEND + ']', -1, false);
        await this.finishLiveFileTransfer(liveTaskId, 'rustdesk', fileName, readLen, fileSize, true,
          '[RustDesk-FILE] 文件传输失败 [' + FILE_TRANSFER_DIAG_RUSTDESK_SEND + ']');
        return 'failed';
      }
      this.setFileTransferStatus('正在等待 RustDesk 文件传输确认 ' + fileName, 0.95, true);
      await this.updateLiveFileTransfer(liveTaskId, 'rustdesk', fileName, Math.floor(fileSize * 0.95),
        fileSize, 'waitingRemote', '正在等待 RustDesk 文件传输确认 ' + fileName);
      const deadline: number = Date.now() + 30000;
      while (Date.now() < deadline) {
        await this.yieldUi(500);
        const status: SessionTransferStatus = this.loader.getSessionTransferStatus(this.sessionId);
        if (status.transferId !== ret) { continue; }
        if (status.rustdeskTransferState === 3) {
          this.setFileTransferStatus('RustDesk 文件传输已确认', 1, false);
          await this.updateLiveFileTransfer(liveTaskId, 'rustdesk', fileName, fileSize,
            fileSize, 'completed', 'RustDesk 文件传输已确认');
          return 'completed';
        }
        if (status.rustdeskTransferState === 4) {
          this.setFileTransferStatus('[RustDesk-FILE] 远端未确认文件传输', -1, false);
          await this.finishLiveFileTransfer(liveTaskId, 'rustdesk', fileName,
            status.transferredBytes, fileSize, true, '[RustDesk-FILE] 远端未确认文件传输');
          return 'failed';
        }
      }
      this.setFileTransferStatus('RustDesk 文件传输仍在等待远端确认', 0.95, false);
      return 'waitingRemote';
    } catch (_err) {
      this.setFileTransferStatus('[RustDesk-FILE] 文件传输失败 [' + FILE_TRANSFER_DIAG_RUSTDESK_SEND + ']', -1, false);
      await this.finishLiveFileTransfer(liveTaskId, 'rustdesk', fileName, readLen, fileSize, true,
        '[RustDesk-FILE] 文件传输失败 [' + FILE_TRANSFER_DIAG_RUSTDESK_SEND + ']');
      hilog.error(RD_DOMAIN, RD_TAG, 'file transfer diagnostic=' + FILE_TRANSFER_DIAG_RUSTDESK_SEND);
      return 'failed';
    } finally {
      if (file !== null) {
        try { fileIo.closeSync(file); } catch (_err2) { /* ignore */ }
      }
    }
  }

  private async pickAndSendFile(): Promise<void> {
    if (this.fileTransferBusy || this.sessionId <= 0 || !this.connected || !this.pendingHost) {
      return;
    }
    const capability = this.currentSessionCapabilities().fileUpload;
    if (!capability.enabled) {
      promptAction.showToast({ message: capability.reason, duration: 2200 });
      return;
    }
    if (this.pendingHost.protocol === 'rustdesk' && !this.rustdeskFilePasteEnabled) {
      promptAction.showToast({ message: 'RustDesk 文件粘贴已禁用', duration: 1600 });
      return;
    }
    let metaFile: fileIo.File | null = null;
    try {
      const docPicker = new picker.DocumentViewPicker();
      const uris: string[] = await docPicker.select();
      if (!uris || uris.length === 0) {
        return;
      }
      const uri: string = uris[0];
      const fileName: string = this.fileBaseName(uri);
      hilog.info(RD_DOMAIN, RD_TAG, 'file transfer picker selected protocol=' + this.pendingHost.protocol);
      metaFile = fileIo.openSync(uri, fileIo.OpenMode.READ_ONLY);
      const stat = fileIo.statSync(metaFile.fd);
      const fileSize: number = stat.size;
      fileIo.closeSync(metaFile);
      metaFile = null;

      if (this.pendingHost.protocol === 'rdp') {
        const stagedPath: string = await this.stageFileForRdpClipboard(uri, fileName, fileSize);
        if (stagedPath.length === 0 ||
          !this.loader.setSessionClipboardFiles(this.sessionId, [stagedPath])) {
          this.setFileTransferStatus('[RDP-FILE] 远端文件剪贴板发布失败', -1, false);
          return;
        }
        this.keyDispatcher.sendShortcutSequence(this.loader, this.sessionId,
          [KEYCODE_CTRL_LEFT, KEY_V], 'RDP file paste');
        this.setFileTransferStatus('已发送到远端当前位置，Windows 正在读取文件', 1, false);
        promptAction.showToast({ message: '已发送到远端当前位置', duration: 2200 });
      } else if (this.pendingHost.protocol === 'rustdesk') {
        await this.submitFileToRustDesk(uri, fileName, fileSize);
      } else {
        this.setFileTransferStatus('当前协议暂不支持远程桌面文件传输', -1, false);
      }
    } catch (_err) {
      this.setFileTransferStatus('[FILE] 文件选择或传输失败 [' + FILE_TRANSFER_DIAG_PICK + ']', -1, false);
      hilog.error(RD_DOMAIN, RD_TAG, 'file transfer diagnostic=' + FILE_TRANSFER_DIAG_PICK);
    } finally {
      if (metaFile !== null) {
        try { fileIo.closeSync(metaFile); } catch (_err2) { /* ignore */ }
      }
    }
  }

  private systemPasteboardHasFileUri(): boolean {
    try {
      return pasteboard.getSystemPasteboard().hasDataType(pasteboard.MIMETYPE_TEXT_URI);
    } catch (_err) {
      return false;
    }
  }

  private async ensurePasteboardReadPermission(): Promise<boolean> {
    try {
      const ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
      const manager: abilityAccessCtrl.AtManager = abilityAccessCtrl.createAtManager();
      const status: abilityAccessCtrl.GrantStatus = manager.checkAccessTokenSync(
        ctx.applicationInfo.accessTokenId, 'ohos.permission.READ_PASTEBOARD');
      if (status === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED) {
        return true;
      }
      const result = await manager.requestPermissionsFromUser(ctx,
        ['ohos.permission.READ_PASTEBOARD']);
      return result.authResults.length > 0 && result.authResults[0] === 0;
    } catch (_err) {
      hilog.warn(RD_DOMAIN, RD_TAG, 'RDP file clipboard read permission unavailable');
      return false;
    }
  }

  private async handleRdpSystemFilePaste(): Promise<void> {
    if (this.fileTransferBusy || !this.connected || this.sessionId <= 0 ||
      !this.pendingHost || this.pendingHost.protocol !== 'rdp') {
      return;
    }
    if (!await this.ensurePasteboardReadPermission()) {
      promptAction.showToast({ message: '需要剪贴板权限才能粘贴本机文件', duration: 2600 });
      return;
    }
    try {
      const data: unifiedDataChannel.UnifiedData =
        await pasteboard.getSystemPasteboard().getUnifiedData();
      const records: Array<unifiedDataChannel.UnifiedRecord> = data.getRecords();
      if (records.length === 0 || records.length > 15) {
        this.setFileTransferStatus(records.length > 15 ?
          '[RDP-FILE] 单次最多粘贴 15 个文件' : '[RDP-FILE] 剪贴板中没有可传输文件', -1, false);
        return;
      }
      const batchDir: string = this.createRdpClipboardBatchDir();
      if (batchDir.length === 0) {
        return;
      }
      const stagedPaths: string[] = [];
      for (const record of records) {
        const fileUriEntry: uniformDataStruct.FileUri =
          record.getEntry(uniformTypeDescriptor.UniformDataType.FILE_URI) as uniformDataStruct.FileUri;
        const uri: string = fileUriEntry && fileUriEntry.oriUri ? fileUriEntry.oriUri : '';
        if (uri.length === 0) {
          continue;
        }
        let metaFile: fileIo.File | null = null;
        try {
          metaFile = fileIo.openSync(uri, fileIo.OpenMode.READ_ONLY);
          const fileSize: number = fileIo.statSync(metaFile.fd).size;
          fileIo.closeSync(metaFile);
          metaFile = null;
          const stagedPath: string = await this.stageFileForRdpClipboard(
            uri, this.fileBaseName(uri), fileSize, batchDir);
          if (stagedPath.length > 0) {
            stagedPaths.push(stagedPath);
          }
        } catch (_err) {
          hilog.warn(RD_DOMAIN, RD_TAG, 'RDP clipboard file metadata unavailable');
        } finally {
          if (metaFile !== null) {
            try { fileIo.closeSync(metaFile); } catch (_err2) { /* ignore */ }
          }
        }
      }
      if (stagedPaths.length === 0 ||
        !this.loader.setSessionClipboardFiles(this.sessionId, stagedPaths)) {
        this.setFileTransferStatus('[RDP-FILE] 远端文件剪贴板发布失败', -1, false);
        return;
      }
      this.keyDispatcher.sendShortcutSequence(this.loader, this.sessionId,
        [KEYCODE_CTRL_LEFT, KEY_V], 'RDP system file paste');
      this.setFileTransferStatus('Windows 正在从本机读取 ' + stagedPaths.length.toString() + ' 个文件', 1, false);
    } catch (_err) {
      this.setFileTransferStatus('[RDP-FILE] 无法读取系统文件剪贴板', -1, false);
    }
  }

  private async publishDeferredRdpDrop(data: unifiedDataChannel.UnifiedData): Promise<void> {
    try {
      const records: Array<unifiedDataChannel.UnifiedRecord> = data.getRecords();
      if (records.length === 0 || records.length > 15) {
        this.setFileTransferStatus(records.length > 15 ?
          '[RDP-FILE] 单次最多拖入 15 个文件' : '[RDP-FILE] 文件中转站未返回文件', -1, false);
        return;
      }
      const stableDir: string = this.ensureRdpTransferDir();
      const stablePrefix: string = stableDir + '/';
      const paths: string[] = [];
      for (const record of records) {
        const entry: uniformDataStruct.FileUri =
          record.getEntry(uniformTypeDescriptor.UniformDataType.FILE_URI) as uniformDataStruct.FileUri;
        const uri: string = entry && entry.oriUri ? entry.oriUri : '';
        if (uri.length === 0) {
          continue;
        }
        const path: string = new fileUri.FileUri(uri).path;
        if (!path.startsWith(stablePrefix)) {
          hilog.warn(RD_DOMAIN, RD_TAG, 'deferred RDP drop returned path outside staging directory');
          continue;
        }
        const stat = fileIo.statSync(path);
        if (stat.size > 0 && stat.size <= RDP_FILE_MAX_BYTES) {
          paths.push(path);
        }
      }
      if (paths.length === 0 || !this.loader.setSessionClipboardFiles(this.sessionId, paths)) {
        this.setFileTransferStatus('[RDP-FILE] 文件中转站内容发布失败', -1, false);
        return;
      }
      this.keyDispatcher.sendShortcutSequence(this.loader, this.sessionId,
        [KEYCODE_CTRL_LEFT, KEY_V], 'RDP SuperHub file paste');
      this.setFileTransferStatus('Windows 正在读取文件中转站的 ' + paths.length.toString() + ' 个文件', 1, false);
    } catch (_err) {
      this.setFileTransferStatus('[RDP-FILE] 文件中转站数据处理失败', -1, false);
    }
  }

  private startDeferredRdpFileDrop(event: DragEvent): void {
    if (!this.pendingHost || this.pendingHost.protocol !== 'rdp') {
      this.setFileTransferStatus('移动端文件中转站当前仅支持 RDP', -1, false);
      event.setResult(DragResult.DRAG_FAILED);
      return;
    }
    const destPath: string = this.createRdpClipboardBatchDir();
    if (destPath.length === 0) {
      event.setResult(DragResult.DRAG_FAILED);
      return;
    }
    const listener: unifiedDataChannel.DataProgressListener =
      (progress: unifiedDataChannel.ProgressInfo,
        data: unifiedDataChannel.UnifiedData | null): void => {
        if (progress.progress >= 0 && progress.progress < 100) {
          this.setFileTransferStatus('正在从文件中转站获取文件 ' +
            progress.progress.toString() + '%', progress.progress / 100, true);
        }
        if (progress.progress === 100 && data !== null) {
          this.publishDeferredRdpDrop(data);
        } else if (progress.progress < 0) {
          this.setFileTransferStatus('[RDP-FILE] 文件中转站数据获取失败', -1, false);
        }
      };
    const options: DataSyncOptions = {
      destUri: fileUri.getUriFromPath(destPath),
      fileConflictOptions: unifiedDataChannel.FileConflictOptions.OVERWRITE,
      progressIndicator: unifiedDataChannel.ProgressIndicator.DEFAULT,
      dataProgressListener: listener
    };
    try {
      event.startDataLoading(options);
      event.setResult(DragResult.DRAG_SUCCESSFUL);
      this.setFileTransferStatus('正在从文件中转站获取文件', 0, true);
    } catch (_err) {
      event.setResult(DragResult.DRAG_FAILED);
      this.setFileTransferStatus('[RDP-FILE] 无法启动文件中转站数据加载', -1, false);
    }
  }

  // PC 模式: 拖拽文件到远程桌面 → 自动传输
  private async handleFileDrop(event: DragEvent): Promise<void> {
    if (this.fileTransferBusy || !this.connected || !this.pendingHost || this.sessionId <= 0) {
      return;
    }
    const capability = this.currentSessionCapabilities().fileUpload;
    if (!capability.enabled) {
      promptAction.showToast({ message: capability.reason, duration: 2200 });
      return;
    }
    if (this.pendingHost.protocol === 'rustdesk' && !this.rustdeskFilePasteEnabled) {
      promptAction.showToast({ message: 'RustDesk 文件粘贴已禁用', duration: 1600 });
      return;
    }
    if (!this.isDesktopDevice || this.breakpoint !== 'xl') {
      this.startDeferredRdpFileDrop(event);
      return;
    }
    try {
      const data: unifiedDataChannel.UnifiedData = event.getData();
      const records: Array<unifiedDataChannel.UnifiedRecord> = data.getRecords();
      const totalCount: number = records.length;
      if (totalCount <= 0) {
        return;
      }
      if (this.pendingHost.protocol === 'rdp' && totalCount > 15) {
        this.setFileTransferStatus('[RDP-FILE] 单次最多拖入 15 个文件', -1, false);
        promptAction.showToast({ message: '单次最多拖入 15 个文件', duration: 2200 });
        return;
      }
      hilog.info(RD_DOMAIN, RD_TAG, 'drop-files count=' + totalCount.toString() +
        ' protocol=' + this.pendingHost.protocol);
      let completedCount: number = 0;
      let pendingRemoteCount: number = 0;
      const rdpBatchDir: string = this.pendingHost.protocol === 'rdp' ?
        this.createRdpClipboardBatchDir() : '';
      if (this.pendingHost.protocol === 'rdp' && rdpBatchDir.length === 0) {
        return;
      }
      const rdpStagedPaths: string[] = [];
      for (const record of records) {
        // UDMF: 文件数据存储在 FILE_URI 条目中
        const fileUriEntry: uniformDataStruct.FileUri =
          record.getEntry(uniformTypeDescriptor.UniformDataType.FILE_URI) as uniformDataStruct.FileUri;
        let uri: string = fileUriEntry && fileUriEntry.oriUri ?
          fileUriEntry.oriUri : '';
        if (uri.length === 0) {
          hilog.warn(RD_DOMAIN, RD_TAG, 'file transfer diagnostic=' + FILE_TRANSFER_DIAG_DROP_URI);
          continue;
        }
        const fileName: string = this.fileBaseName(uri);
        let metaFile: fileIo.File | null = null;
        let fileSize: number = 0;
        try {
          metaFile = fileIo.openSync(uri, fileIo.OpenMode.READ_ONLY);
          const stat = fileIo.statSync(metaFile.fd);
          fileSize = stat.size;
        } catch (_err) {
          hilog.error(RD_DOMAIN, RD_TAG, 'file transfer diagnostic=' + FILE_TRANSFER_DIAG_DROP_META);
          continue;
        } finally {
          if (metaFile !== null) {
            try { fileIo.closeSync(metaFile); } catch (_err2) { /* ignore */ }
          }
        }
        if (totalCount > 1) {
          if (this.pendingHost.protocol === 'rdp') {
            this.setFileTransferStatus(
              '[' + (completedCount + 1).toString() + '/' + totalCount.toString() + '] 正在暂存 ' +
              fileName + ' (' + this.formatTransferSize(fileSize) + ')',
              completedCount / totalCount, true);
          } else {
            this.setFileTransferStatus(
              '[' + (completedCount + 1).toString() + '/' + totalCount.toString() + '] 正在传输 ' +
              fileName + ' (' + this.formatTransferSize(fileSize) + ')',
              completedCount / totalCount, true);
          }
        }
        let transferState: TransferState = 'failed';
        if (this.pendingHost.protocol === 'rdp') {
          const stagedPath: string = await this.stageFileForRdpClipboard(
            uri, fileName, fileSize, rdpBatchDir);
          if (stagedPath.length > 0) {
            rdpStagedPaths.push(stagedPath);
            transferState = 'completed';
          }
        } else if (this.pendingHost.protocol === 'rustdesk') {
          transferState = await this.submitFileToRustDesk(uri, fileName, fileSize);
        } else {
          this.setFileTransferStatus('当前协议暂不支持远程桌面文件传输', -1, false);
          break;
        }
        if (isRemoteCompletionConfirmed(transferState)) {
          completedCount++;
        } else if (transferState === 'waitingRemote') {
          pendingRemoteCount++;
        }
      }
      if (this.pendingHost.protocol === 'rdp' && rdpStagedPaths.length > 0) {
        if (!this.loader.setSessionClipboardFiles(this.sessionId, rdpStagedPaths)) {
          this.setFileTransferStatus('[RDP-FILE] 远端文件剪贴板发布失败', -1, false);
          return;
        }
        this.keyDispatcher.sendShortcutSequence(this.loader, this.sessionId,
          [KEYCODE_CTRL_LEFT, KEY_V], 'RDP drop file paste');
        this.setFileTransferStatus('已发送到远端当前位置，Windows 正在读取 ' +
          rdpStagedPaths.length.toString() + ' 个文件', 1, false);
      }
      if (completedCount > 0) {
        event.setResult(DragResult.DRAG_SUCCESSFUL);
        if (totalCount > 1) {
          this.setFileTransferStatus(
            '已完成 ' + completedCount.toString() + '/' + totalCount.toString() + ' 个文件传输', 1, false);
        }
      }
      if (pendingRemoteCount > 0) {
        this.setFileTransferStatus(
          '已提交 ' + pendingRemoteCount.toString() + '/' + totalCount.toString() +
            ' 个文件，正在等待 RustDesk 远端确认', 0.95, true);
      }
    } catch (_err) {
      hilog.error(RD_DOMAIN, RD_TAG, 'file transfer diagnostic=' + FILE_TRANSFER_DIAG_DROP);
      this.setFileTransferStatus('[DROP] 拖拽传输失败 [' + FILE_TRANSFER_DIAG_DROP + ']', -1, false);
    }
  }

  private openKeyboard(): void {
    if (this.keyboardOpen) {
      return;
    }
    this.hardwareKeyboardProxyActive = false;
    this.keyboardOpen = true;
    this.startRemoteImeSession();
    hilog.info(RD_DOMAIN, RD_TAG, 'kbd-open');
    try {
      const focused: boolean = focusControl.requestFocus('RemoteDesktopKeyboard');
      hilog.info(RD_DOMAIN, RD_TAG, 'kbd-open-focus editor=' + (focused ? '1' : '0'));
    } catch (err) {
      hilog.error(RD_DOMAIN, RD_TAG,
        'openKeyboard focus failed: ' + JSON.stringify(err));
    }
  }

  private markKeyboardClosed(source: string): void {
    this.keyboardOpen = false;
    this.hardwareKeyboardProxyActive = false;
    this.resetRemoteImeSession('closed-' + source);
    this.keyboardSubmitRefocusPending = false;
    hilog.info(RD_DOMAIN, RD_TAG, 'kbd-close source=' + source);
    if (!this.keepKeyboardAfterSheetClose) {
      this.scheduleRemoteInputFocus('keyboard-close-' + source);
    }
  }

  private dismissKeyboard(): void {
    if (!this.keyboardOpen) {
      return;
    }
    this.markKeyboardClosed('control-panel');
    // 将焦点移到 XComponent 以收起键盘
    this.scheduleRemoteInputFocus('keyboard-dismiss');
  }

  private startRemoteImeSession(): void {
    const shadow = createRemoteImeShadow();
    this.keyboardImeGeneration++;
    this.keyboardCommandQueue.clear();
    this.keyboardText = shadow.text;
    this.keyboardImeActive = true;
    this.keyboardImeEditingObserved = false;
    this.keyboardInitialSelectionPending = true;
    this.keyboardSyncedCaret = shadow.caret;
    this.keyboardExpectedStart = shadow.caret;
    this.keyboardExpectedEnd = shadow.caret;
    this.keyboardProgrammaticSelection = true;
    const generation = this.keyboardImeGeneration;
    setTimeout((): void => {
      if (!this.keyboardImeActive || generation !== this.keyboardImeGeneration) {
        return;
      }
      this.setRemoteImeSelection(shadow.caret, 'start');
    }, 0);
  }

  private resetRemoteImeSession(source: string): void {
    if (this.keyboardCommandPumpTimer >= 0) {
      clearTimeout(this.keyboardCommandPumpTimer);
      this.keyboardCommandPumpTimer = -1;
    }
    this.keyboardImeGeneration++;
    this.keyboardImeActive = false;
    this.keyboardImeEditingObserved = false;
    this.keyboardInitialSelectionPending = false;
    this.keyboardCommandQueue.clear();
    this.keyboardText = '';
    this.keyboardSyncedCaret = REMOTE_IME_CENTER;
    this.keyboardExpectedStart = -1;
    this.keyboardExpectedEnd = -1;
    this.keyboardProgrammaticSelection = false;
    if (this.keyboardSelectionAckTimer >= 0) {
      clearTimeout(this.keyboardSelectionAckTimer);
      this.keyboardSelectionAckTimer = -1;
    }
    hilog.info(RD_DOMAIN, RD_TAG, 'kbd-ime-reset source=' + source);
  }

  private clearRemoteImeSelectionAcknowledgement(): void {
    if (this.keyboardSelectionAckTimer >= 0) {
      clearTimeout(this.keyboardSelectionAckTimer);
      this.keyboardSelectionAckTimer = -1;
    }
    this.keyboardProgrammaticSelection = false;
  }

  private setRemoteImeSelection(caret: number, source: string): void {
    const safeCaret: number = Math.max(0, Math.min(caret, this.keyboardText.length));
    this.keyboardExpectedStart = safeCaret;
    this.keyboardExpectedEnd = safeCaret;
    this.keyboardProgrammaticSelection = true;
    if (this.keyboardSelectionAckTimer >= 0) {
      clearTimeout(this.keyboardSelectionAckTimer);
    }
    const generation = this.keyboardImeGeneration;
    const initialSelection = this.keyboardInitialSelectionPending;
    this.keyboardSelectionAckTimer = setTimeout((): void => {
      this.keyboardSelectionAckTimer = -1;
      if (this.keyboardImeActive && generation === this.keyboardImeGeneration) {
        this.keyboardProgrammaticSelection = false;
        if (initialSelection) {
          this.keyboardInitialSelectionPending = false;
        }
      }
    }, REMOTE_IME_SELECTION_ACK_TIMEOUT_MS);
    try {
      this.keyboardController.setTextSelection(safeCaret, safeCaret, { menuPolicy: MenuPolicy.HIDE });
    } catch (_err) {
      // Controller calls may fail before the hidden editor has mounted.  The
      // expected selection remains so the next component callback is ignored.
    }
    hilog.debug(RD_DOMAIN, RD_TAG,
      'kbd-ime-selection source=' + source + ' caret=' + safeCaret.toString());
  }

  private handleKeyboardWillInsert(info: InsertValue): boolean {
    this.keyboardImeEditingObserved = true;
    this.keyboardExpectedStart = info.insertOffset + info.insertValue.length;
    this.keyboardExpectedEnd = this.keyboardExpectedStart;
    return this.keyboardImeActive;
  }

  private handleKeyboardDidInsert(info: InsertValue): void {
    if (!this.keyboardImeActive || info.insertValue.length === 0) {
      return;
    }
    this.keyboardSyncedCaret = info.insertOffset + info.insertValue.length;
    this.keyboardCommandQueue.enqueueText(info.insertValue, this.keyboardImeGeneration, 'didInsert');
    this.scheduleRemoteImeCommandPump();
  }

  private handleKeyboardWillDelete(info: DeleteValue): boolean {
    this.keyboardImeEditingObserved = true;
    this.keyboardExpectedStart = info.deleteOffset;
    this.keyboardExpectedEnd = info.deleteOffset;
    return this.keyboardImeActive;
  }

  private handleKeyboardDidDelete(info: DeleteValue): void {
    if (!this.keyboardImeActive) {
      return;
    }
    const deletion = resolveRemoteImeDelete(info.direction as number, info.deleteValue.length);
    this.keyboardSyncedCaret = info.deleteOffset;
    this.enqueueRemoteImeDelete(deletion.backwardCount, deletion.forwardCount);
  }

  private handleKeyboardTextChange(value: string, previewText?: PreviewText): void {
    const previewUnits: number = previewText ? previewText.value.length : 0;
    if (!shouldAcceptRemoteImeTextChange(this.keyboardImeActive, previewUnits)) {
      if (previewUnits > 0) {
        hilog.debug(RD_DOMAIN, RD_TAG,
          'kbd-ime-change ignored previewUnits=' + previewUnits.toString());
      }
      return;
    }
    this.keyboardText = value;
  }

  private enqueueRemoteImeDelete(backwardCount: number, forwardCount: number): void {
    if (backwardCount > 0) {
      this.keyboardCommandQueue.enqueueKeyTaps(KEYCODE_DEL, backwardCount,
        this.keyboardImeGeneration, 'didDelete-backward');
    }
    if (forwardCount > 0) {
      this.keyboardCommandQueue.enqueueKeyTaps(KEYCODE_FORWARD_DEL, forwardCount,
        this.keyboardImeGeneration, 'didDelete-forward');
    }
    if (this.keyboardCommandQueue.size() > 0) {
      this.scheduleRemoteImeCommandPump();
    }
  }

  private handleKeyboardSelectionChange(selectionStart: number, selectionEnd: number): void {
    const oldCaret = this.keyboardSyncedCaret;
    const result = resolveRemoteImeSelection({
      active: this.keyboardImeActive,
      programmatic: this.keyboardProgrammaticSelection,
      initialSelectionPending: this.keyboardInitialSelectionPending,
      expectedStart: this.keyboardExpectedStart,
      expectedEnd: this.keyboardExpectedEnd,
      syncedCaret: oldCaret,
      selectionStart,
      selectionEnd
    });
    if (result.consumeInitial) {
      this.keyboardInitialSelectionPending = false;
      this.clearRemoteImeSelectionAcknowledgement();
      this.keyboardExpectedStart = -1;
      this.keyboardExpectedEnd = -1;
      if (this.keyboardImeActive &&
        (selectionStart !== this.keyboardSyncedCaret || selectionEnd !== this.keyboardSyncedCaret)) {
        this.setRemoteImeSelection(this.keyboardSyncedCaret, 'initial-collapse');
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
    if (result.action === RemoteImeSelectionAction.MOVE_LEFT) {
      this.keyboardSyncedCaret = result.nextSyncedCaret;
      this.keyboardCommandQueue.enqueueKeyTaps(KEYCODE_DPAD_LEFT, result.count,
        this.keyboardImeGeneration, 'selection-left');
      this.logRemoteImeDiagnostic('selection', result.count, oldCaret, result.nextSyncedCaret, 'move-left');
      this.scheduleRemoteImeCommandPump();
    } else if (result.action === RemoteImeSelectionAction.MOVE_RIGHT) {
      this.keyboardSyncedCaret = result.nextSyncedCaret;
      this.keyboardCommandQueue.enqueueKeyTaps(KEYCODE_DPAD_RIGHT, result.count,
        this.keyboardImeGeneration, 'selection-right');
      this.logRemoteImeDiagnostic('selection', result.count, oldCaret, result.nextSyncedCaret, 'move-right');
      this.scheduleRemoteImeCommandPump();
    } else if (result.action === RemoteImeSelectionAction.COLLAPSE_LOCAL && this.keyboardImeActive) {
      this.setRemoteImeSelection(this.keyboardSyncedCaret, 'collapse-expanded-selection');
    }
  }

  private logRemoteImeDiagnostic(
    source: string,
    units: number,
    oldCaret: number,
    newCaret: number,
    result: string
  ): void {
    const diagnostic = createRemoteImeDiagnostic(source, units, oldCaret, newCaret, result);
    hilog.debug(RD_DOMAIN, RD_TAG,
      'kbd-ime source=' + diagnostic.source + ' units=' + diagnostic.units.toString() +
        ' old=' + diagnostic.oldCaret.toString() + ' new=' + diagnostic.newCaret.toString() +
        ' delta=' + diagnostic.delta.toString() + ' result=' + diagnostic.result);
  }

  private scheduleRemoteImeCommandPump(delayMs: number = 0): void {
    if (this.keyboardCommandPumpTimer >= 0 || this.keyboardCommandQueue.size() === 0) {
      return;
    }
    this.keyboardCommandPumpTimer = setTimeout((): void => {
      this.pumpRemoteImeCommands();
    }, delayMs);
  }

  private pumpRemoteImeCommands(): void {
    this.keyboardCommandPumpTimer = -1;
    const command: RemoteImeCommand | null = this.keyboardCommandQueue.shift();
    if (command === null) {
      this.recenterRemoteImeAnchor();
      return;
    }
    if (command.generation !== this.keyboardImeGeneration || !this.keyboardImeActive) {
      this.resetRemoteImeSession('input-unavailable');
      return;
    }
    if (shouldWaitForRemoteImeInput(this.connected, this.sessionId, this.inputForwardReady)) {
      this.keyboardCommandQueue.pushFront(command);
      this.scheduleRemoteImeCommandPump(REMOTE_IME_COMMAND_RETRY_MS);
      hilog.debug(RD_DOMAIN, RD_TAG,
        'kbd-ime-wait-input queue=' + this.keyboardCommandQueue.size().toString());
      return;
    }
    if (!this.canForwardInput('key')) {
      this.resetRemoteImeSession('input-unavailable');
      return;
    }
    try {
      if (command.kind === RemoteImeCommandKind.TEXT) {
        this.loader.sendText(this.sessionId, command.text);
        hilog.debug(RD_DOMAIN, RD_TAG,
          'kbd-ime-dispatch kind=text units=' + command.text.length.toString() +
            ' queue=' + this.keyboardCommandQueue.size().toString() +
            ' protocol=' + this.currentProtocolName());
      } else {
        const sendCount: number = Math.min(32, command.tapCount);
        for (let index = 0; index < sendCount; index++) {
          this.loader.sendKey(this.sessionId, command.keyCode, true);
          this.loader.sendKey(this.sessionId, command.keyCode, false);
        }
        command.tapCount -= sendCount;
        if (command.tapCount > 0) {
          this.keyboardCommandQueue.pushFront(command);
        }
        hilog.debug(RD_DOMAIN, RD_TAG,
          'kbd-ime-dispatch kind=key taps=' + sendCount.toString() +
            ' queue=' + this.keyboardCommandQueue.size().toString() +
            ' protocol=' + this.currentProtocolName());
      }
    } catch (err) {
      hilog.error(RD_DOMAIN, RD_TAG, 'kbd-ime-dispatch failed: ' + JSON.stringify(err));
      this.resetRemoteImeSession('dispatch-failed');
      return;
    }
    if (this.keyboardCommandQueue.size() > 0) {
      this.scheduleRemoteImeCommandPump();
    } else {
      this.recenterRemoteImeAnchor();
    }
  }

  private recenterRemoteImeAnchor(): void {
    if (!this.keyboardImeActive || this.keyboardCommandQueue.size() > 0 ||
      !shouldRecenterRemoteImeShadow(this.keyboardSyncedCaret, this.keyboardText.length)) {
      return;
    }
    const shadow = createRemoteImeShadow();
    this.keyboardText = shadow.text;
    this.keyboardSyncedCaret = shadow.caret;
    this.setRemoteImeSelection(shadow.caret, 'recenter');
  }

  private clearTouchIndicatorTimer(): void {
    if (this.touchIndicatorTimer >= 0) {
      clearTimeout(this.touchIndicatorTimer);
      this.touchIndicatorTimer = -1;
    }
  }

  private showTouchIndicator(localX: number, localY: number, button: number, autoHide: boolean): void {
    if (this.isKeyboardMouseControlMode()) {
      this.hideTouchIndicator();
      return;
    }
    this.clearTouchIndicatorTimer();
    this.touchIndicatorX = localX;
    this.touchIndicatorY = localY;
    this.touchIndicatorButton = button;
    this.touchIndicatorVisible = true;
    this.publishRemoteCursorOverlay();
    if (autoHide) {
      this.touchIndicatorTimer = setTimeout(() => {
        this.touchIndicatorVisible = false;
        this.touchIndicatorTimer = -1;
        this.publishRemoteCursorOverlay();
      }, this.touchIndicatorHideMs(button));
    }
  }

  private touchIndicatorHideMs(button: number): number {
    if (button === TOUCH_INDICATOR_BUTTON_RIGHT || button === TOUCH_INDICATOR_BUTTON_DRAG) {
      return TOUCH_INDICATOR_ACTION_HIDE_MS;
    }
    return TOUCH_INDICATOR_HIDE_MS;
  }

  private getTouchIndicatorColor(): string {
    if (this.touchIndicatorButton === TOUCH_INDICATOR_BUTTON_DRAG) {
      return '#FF3B30';
    }
    if (this.touchIndicatorButton === TOUCH_INDICATOR_BUTTON_RIGHT) {
      return '#FF9F0A';
    }
    return '#00D1FF';
  }

  private getTouchIndicatorRingSize(): number {
    if (this.touchIndicatorButton === TOUCH_INDICATOR_BUTTON_DRAG) {
      return 24;
    }
    if (this.touchIndicatorButton === TOUCH_INDICATOR_BUTTON_RIGHT) {
      return 22;
    }
    return 18;
  }

  private getTouchIndicatorOuterSize(): number {
    return this.touchIndicatorButton === TOUCH_INDICATOR_BUTTON_DRAG ? 34 : 28;
  }

  private getTouchIndicatorDotSize(): number {
    return this.touchIndicatorButton === TOUCH_INDICATOR_BUTTON_DRAG ? 4 : 3;
  }

  private showRemoteCursorIndicator(button: number, autoHide: boolean): void {
    if (this.isKeyboardMouseControlMode()) {
      this.hideTouchIndicator();
      return;
    }
    if (this.remoteCursorDisplayStyle() === 'arrow') {
      if (this.touchIndicatorVisible) {
        this.hideTouchIndicator();
      }
      return;
    }
    const local: LocalPoint = this.remoteToLocalPoint(this.remoteCursorX, this.remoteCursorY);
    if (!local.inside) { return; }
    const actualButton: number = this.touchDragActive && button < 0 ? TOUCH_INDICATOR_BUTTON_DRAG : button;
    this.showTouchIndicator(local.x, local.y, actualButton, autoHide);
  }

  private resetTouchGesture(): void {
    this.clearTouchRightClickTimer();
    this.clearTouchDirectRightClickTimer();
    const wasDragging: boolean = this.touchDragActive;
    if (this.touchDragActive) {
      // 拖拽结束 — 释放左键
      this.sendMouseNow(this.remoteCursorX, this.remoteCursorY, 0, false);
    }
    this.touchFingerCount = 0;
    this.touchDragActive = false;
    this.touchDragPending = false;
    this.touchMoved = false;
    this.touchGestureDone = false;
    this.touchMaxFingers = 0;
    this.touchWheelRemainder = 0;
    this.lastTouchWheelMs = 0;
    this.touchpadAnchorValid = false;
    this.activeTouchPoints.clear();
    if (this.touchpadPointerDown) {
      this.touchpadPointerDown = false;
      this.applyRemoteCursorMotionState(endLocalCursorGesture(this.remoteCursorMotion, Date.now()));
    }
    this.resetTouchpadPointerCurve();
    this.resetCanvasTwoFingerGesture();
    if (wasDragging) {
      this.showRemoteCursorIndicator(-1, true);
    }
  }

  private finishTwoFingerRightClick(): void {
    if (this.touchGestureDone) {
      return;
    }
    const savedX: number = this.touchDragCursorX;
    const savedY: number = this.touchDragCursorY;
    this.sendMouseNow(savedX, savedY, 2, true);
    this.sendMouseNow(savedX, savedY, 2, false);
    this.touchGestureDone = true;
    this.touchDragPending = false;
    this.showRemoteCursorIndicator(2, true);
    hilog.info(RD_DOMAIN, RD_TAG,
      'two-finger right-click anchor=' + savedX.toString() + ',' + savedY.toString());
  }

  private finishThreeFingerPanel(): void {
    if (this.touchGestureDone) {
      return;
    }
    this.showControlPanel = !this.showControlPanel;
    this.touchGestureDone = true;
    this.touchDragPending = false;
    hilog.info(RD_DOMAIN, RD_TAG, 'three-finger tap panel=' +
      (this.showControlPanel ? 'open' : 'close') + ' anchor=' +
      this.touchDragCursorX.toString() + ',' + this.touchDragCursorY.toString());
  }

  private syncActiveTouchPoints(event: TouchEvent): void {
    if (event.type === TouchType.Cancel) {
      this.activeTouchPoints.clear();
      return;
    }
    if (event.type === TouchType.Down && this.touchFingerCount <= 0) {
      this.activeTouchPoints.clear();
    }
    for (let i = 0; i < event.touches.length; i++) {
      const touch = event.touches[i];
      this.activeTouchPoints.set(touch.id, { x: touch.x, y: touch.y, inside: true });
    }
    for (let i = 0; i < event.changedTouches.length; i++) {
      const touch = event.changedTouches[i];
      this.activeTouchPoints.set(touch.id, { x: touch.x, y: touch.y, inside: true });
    }
    if (event.type === TouchType.Up) {
      for (let i = 0; i < event.changedTouches.length; i++) {
        this.activeTouchPoints.delete(event.changedTouches[i].id);
      }
    }
  }

  private canvasTouchPointEvent(event: TouchEvent): CanvasTouchPointEvent {
    if (event.type === TouchType.Down) {
      return 'down';
    }
    if (event.type === TouchType.Up) {
      return 'up';
    }
    if (event.type === TouchType.Cancel) {
      return 'cancel';
    }
    return 'move';
  }

  /** The ID-keyed map is authoritative after syncActiveTouchPoints(). */
  private trackedCanvasTouchCount(event: TouchEvent): number {
    return resolveCanvasActiveTouchCount(this.canvasTouchPointEvent(event),
      this.activeTouchPoints.size, event.touches.length, this.touchFingerCount,
      event.changedTouches.length);
  }

  private averageTouchPoint(event: TouchEvent): LocalPoint | null {
    let sumX: number = 0;
    let sumY: number = 0;
    let count: number = 0;
    this.activeTouchPoints.forEach((point: LocalPoint): void => {
      sumX += point.x;
      sumY += point.y;
      count++;
    });
    if (count === 0) {
      const points = event.touches.length > 0 ? event.touches : event.changedTouches;
      for (let i = 0; i < points.length; i++) {
        sumX += points[i].x;
        sumY += points[i].y;
      }
      count = points.length;
    }
    if (count === 0) {
      return null;
    }
    return {
      x: sumX / count,
      y: sumY / count,
      inside: true
    };
  }

  private primaryTouchPoint(event: TouchEvent): LocalPoint | null {
    const preferChanged: boolean = event.type === TouchType.Up || event.type === TouchType.Cancel;
    if (preferChanged && event.changedTouches.length > 0) {
      return { x: event.changedTouches[0].x, y: event.changedTouches[0].y, inside: true };
    }
    if (event.touches.length > 0) {
      return { x: event.touches[0].x, y: event.touches[0].y, inside: true };
    }
    if (event.changedTouches.length > 0) {
      return { x: event.changedTouches[0].x, y: event.changedTouches[0].y, inside: true };
    }
    return null;
  }

  private remainingTouchCountAfterLift(event: TouchEvent): number {
    return this.trackedCanvasTouchCount(event);
  }

  private captureCanvasGestureDensity(viewport: CanvasViewport): void {
    const widthDensity: number = this.surfaceWidth > 0 ? viewport.surfaceWidth / this.surfaceWidth : 0;
    const heightDensity: number = this.surfaceHeight > 0 ? viewport.surfaceHeight / this.surfaceHeight : 0;
    const density: number = widthDensity > 0 ? widthDensity : heightDensity;
    this.canvasGesturePxPerVp = Number.isFinite(density) && density > 0 ? density : this.vpToPx(1);
  }

  private canvasGestureVpToPx(value: number): number {
    return value * this.canvasGesturePxPerVp;
  }

  private sendTouchPadWheel(stepDy: number): void {
    if (!this.canForwardInput('mouseWheel')) {
      return;
    }
    this.touchWheelRemainder += stepDy * TOUCHPAD_SCROLL_GAIN;
    const now: number = Date.now();
    if (now - this.lastTouchWheelMs < TOUCHPAD_SCROLL_FLUSH_MS) {
      return;
    }
    let delta: number = this.touchWheelRemainder > 0 ?
      Math.floor(this.touchWheelRemainder) : Math.ceil(this.touchWheelRemainder);
    if (delta === 0) {
      if (Math.abs(stepDy) >= 1) {
        hilog.info(RD_DOMAIN, RD_TAG,
          'touchpad-scroll accumulate stepDy=' + stepDy.toString() +
            ' remainder=' + this.touchWheelRemainder.toString());
      }
      return;
    }
    if (delta > TOUCHPAD_SCROLL_MAX_DELTA) {
      delta = TOUCHPAD_SCROLL_MAX_DELTA;
    } else if (delta < -TOUCHPAD_SCROLL_MAX_DELTA) {
      delta = -TOUCHPAD_SCROLL_MAX_DELTA;
    }
    this.touchWheelRemainder -= delta;
    this.lastTouchWheelMs = now;
    const src = this.toSourceSpace(this.remoteCursorX, this.remoteCursorY);
    const sendDelta: number = this.rustdeskReverseWheel ? -delta : delta;
    this.loader.sendMouseWheel(this.sessionId, src['x'], src['y'], sendDelta);
    hilog.info(RD_DOMAIN, RD_TAG,
      'touchpad-scroll delta=' + sendDelta.toString() + ' stepDy=' + stepDy.toString() +
        ' remote=' + this.remoteCursorX.toString() + ',' + this.remoteCursorY.toString());
  }

  private sendRemoteKeyTap(keyCode: number, label: string): void {
    if (this.sessionId <= 0 || !this.connected || !this.canForwardInput('key')) {
      return;
    }
    try {
      this.loader.sendKey(this.sessionId, keyCode, true);
      this.loader.sendKey(this.sessionId, keyCode, false);
      hilog.info(RD_DOMAIN, RD_TAG, 'kbd-edit-key label=' + label + ' code=' + keyCode.toString());
    } catch (err) {
      hilog.error(RD_DOMAIN, RD_TAG, 'kbd-edit-key failed: ' + JSON.stringify(err));
    }
  }

  private sendKeyboardEnter(source: string): void {
    if (this.sessionId <= 0 || !this.connected || !this.canForwardInput('key')) {
      return;
    }
    try {
      this.loader.sendKey(this.sessionId, KEYCODE_ENTER, true);
      this.loader.sendKey(this.sessionId, KEYCODE_ENTER, false);
      hilog.info(RD_DOMAIN, RD_TAG, 'kbd-enter source=' + source);
    } catch (err) {
      hilog.error(RD_DOMAIN, RD_TAG, 'kbd-enter failed: ' + JSON.stringify(err));
    }
  }

  /**
   * 触控板模式手势处理
   *
   * 手势规则:
   *   1 指移动 -> 相对移动光标
   *   1 指抬起 (无移动) -> 左键点击
   *   1 指停留 1 秒后移动 -> 左键按住拖拽, 抬手释放
   *   2 指抬起 (无移动) -> 右键点击
   *   2 指纵向移动 -> 滚轮
   *
   * 防漂移: 第 2 指落下时记录光标位置; 双指抬起时无移动则回退到记录位置发右键,
   *   避免第 1 指落下瞬间的微移导致光标偏移。
   */
  private handleTouchPadInput = (event: TouchEvent): void => {
    // A read-only VNC session still needs to observe the touch sequence so a
    // three-finger tap can open the local control sheet. Every actual remote
    // send below remains guarded by canForwardInput().
    if (!this.canForwardInput('touch-pad') && !this.isVncViewOnlySession()) { return; }
    try {
      event.stopPropagation();
      const point: LocalPoint | null = this.primaryTouchPoint(event);
      if (!point) {
        if (event.type === TouchType.Cancel) {
          this.resetTouchGesture();
        }
        return;
      }

      if (event.type === TouchType.Down) {
        this.resetTouchpadPointerCurve();
        this.touchpadAnchorValid = true;
        if (!this.touchpadPointerDown) {
          this.touchpadPointerDown = true;
          this.applyRemoteCursorMotionState(beginLocalCursorGesture(this.remoteCursorMotion, Date.now()));
        }
        if (this.touchFingerCount <= 0 &&
          shouldResetRemoteImeOnPointerDown(this.keyboardOpen || this.hardwareKeyboardProxyActive)) {
          this.resetRemoteImeSession('touchpad-down');
        }
        const oldMaxFingers: number = this.touchMaxFingers;
        const currentTouches: number = this.trackedCanvasTouchCount(event);
        this.touchFingerCount = currentTouches;
        if (this.touchFingerCount > this.touchMaxFingers) {
          this.touchMaxFingers = this.touchFingerCount;
        }
        if (!this.remoteCursorReady) {
          this.rememberRemoteCursor(Math.round(this.remoteWidth / 2),
            Math.round(this.remoteHeight / 2));
        }
        if (this.touchFingerCount === 1) {
          // 第一根手指: 开始单指手势，并启动长按拖拽计时。
          this.touchStartLocalX = point.x;
          this.touchStartLocalY = point.y;
          this.touchLastLocalX = point.x;
          this.touchLastLocalY = point.y;
          this.touchMoved = false;
          this.touchDragActive = false;
          this.touchGestureDone = false;
          this.startTouchHoldDragTimer();
          this.showRemoteCursorIndicator(-1, false);
        } else if (this.touchFingerCount >= 2) {
          // 进入多指模式后锚定当前远端光标，禁止触点位置把光标吸走。
          this.clearTouchRightClickTimer();
          if (oldMaxFingers < 2) {
            this.touchDragCursorX = this.remoteCursorX;
            this.touchDragCursorY = this.remoteCursorY;
          }
          const avg: LocalPoint | null = this.averageTouchPoint(event);
          if (avg) {
            this.touchStartLocalX = avg.x;
            this.touchStartLocalY = avg.y;
            this.touchLastLocalX = avg.x;
            this.touchLastLocalY = avg.y;
          }
          this.touchWheelRemainder = 0;
          this.lastTouchWheelMs = 0;
          // 第 1 指无显著移动 -> 等待抬起确认双指右键。
          if (!this.touchMoved && this.touchMaxFingers === 2) {
            this.touchDragPending = true;
          } else if (this.touchMaxFingers >= 3) {
            this.touchDragPending = false;
          }
        }
      } else if (event.type === TouchType.Move) {
        this.touchFingerCount = this.trackedCanvasTouchCount(event);
        const movePoint: LocalPoint = this.touchFingerCount >= 2 ?
          (this.averageTouchPoint(event) || { x: point.x, y: point.y, inside: true }) :
          { x: point.x, y: point.y, inside: true };
        if (!this.touchpadAnchorValid) {
          // The surface may have changed coordinate space while the gesture
          // remained active.  Re-anchor without moving the remote pointer.
          this.touchLastLocalX = movePoint.x;
          this.touchLastLocalY = movePoint.y;
          this.touchStartLocalX = movePoint.x;
          this.touchStartLocalY = movePoint.y;
          this.touchpadAnchorValid = true;
          this.resetTouchpadPointerCurve();
          hilog.info(RD_DOMAIN, RD_TAG, 'touchpad-anchor reset after local surface change');
          return;
        }
        const stepDx: number = movePoint.x - this.touchLastLocalX;
        const stepDy: number = movePoint.y - this.touchLastLocalY;
        this.touchLastLocalX = movePoint.x;
        this.touchLastLocalY = movePoint.y;
        const dx: number = movePoint.x - this.touchStartLocalX;
        const dy: number = movePoint.y - this.touchStartLocalY;
        if (Math.sqrt(dx * dx + dy * dy) > TOUCH_CLICK_SLOP_PX) {
          this.touchMoved = true;
          this.clearTouchRightClickTimer();
        }

        if (this.touchFingerCount >= 2) {
          if (shouldApplyCanvasTwoFingerPan(this.canvasTwoFingerState) &&
            this.canvasTwoFingerState.owner === 'canvas-pan') {
            this.touchMoved = true;
            this.touchDragPending = false;
            if (!this.canvasPanActive) {
              this.startCanvasPanFromPoint(movePoint);
            }
            this.updateCanvasPanFromPoint(movePoint.x, movePoint.y);
            return;
          }
          if (this.canvasTwoFingerState.owner === 'remote-touch-pan') {
            this.touchMoved = true;
            this.touchDragPending = false;
            return;
          }
          if (shouldSendCanvasTwoFingerScroll(this.canvasTwoFingerState) &&
            Math.abs(stepDy) >= 0.5) {
            // 双指上下滑动只映射滚轮，不再触发拖拽。
            this.sendTouchPadWheel(stepDy);
          }
          if (this.canvasTwoFingerState.owner === 'touchpad-scroll' || this.touchMoved) {
            this.touchDragPending = false;
          }
        } else if (this.touchMaxFingers < 2 && (this.touchDragActive || !this.touchGestureDone) &&
          (Math.abs(stepDx) >= 0.1 || Math.abs(stepDy) >= 0.1)) {
          // 单指移动光标
          if (this.isTouchpadStepDiscontinuity(stepDx, stepDy)) {
            this.touchLastLocalX = movePoint.x;
            this.touchLastLocalY = movePoint.y;
            this.resetTouchpadPointerCurve();
            this.logTouchpadCurve(stepDx, stepDy, 0, 0, 0, 0, 0,
              this.remoteCursorPreciseX, this.remoteCursorPreciseY, true);
            return;
          }
          const nowMs: number = Date.now();
          const previousTimeMs: number = this.touchpadCurveState.lastTimeMs;
          const curve = touchpadPointerCurve(stepDx, stepDy, nowMs, this.touchpadCurveState);
          this.touchpadCurveState = curve.state;
          const userSpeed: number = this.isRustDeskSession() ? this.rustdeskTouchpadSpeed : 1.0;
          const pointerSpeed: number = clampTouchpadEffectiveGain(curve.gain, userSpeed);
          const remoteDelta: RemoteSurfaceDelta = this.remoteDeltaFromLocalPair(stepDx, stepDy);
          const nextX: number = this.remoteCursorPreciseX +
            remoteDelta.x * pointerSpeed;
          const nextY: number = this.remoteCursorPreciseY +
            remoteDelta.y * pointerSpeed;
          const dtMs: number = previousTimeMs > 0 && nowMs > previousTimeMs ?
            nowMs - previousTimeMs : 16;
          this.logTouchpadCurve(stepDx, stepDy, dtMs, curve.gain, pointerSpeed,
            remoteDelta.x, remoteDelta.y, nextX, nextY);
          this.setRemoteCursorPrediction(nextX, nextY);
          // Keep the fractional prediction in the pending queue; round only
          // at the protocol boundary in flushMouseMove().
          this.queueMouseMove(nextX, nextY, false);
          this.showRemoteCursorIndicator(this.touchDragActive ? TOUCH_INDICATOR_BUTTON_DRAG : -1, false);
        }
      } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
        this.clearTouchRightClickTimer();
        if (this.touchMaxFingers === 2 && event.type === TouchType.Up) {
          this.finishCanvasTwoFingerCandidateForRelease(this.touchMoved);
          if (!this.touchMoved && shouldPreserveCanvasTwoFingerRightClick(this.canvasTwoFingerState)) {
            this.touchDragPending = true;
          }
        }
        // HarmonyOS Up 事件里 touches 可能仍包含刚抬起的手指，剩余数量必须按 changedTouches 递减。
        this.touchFingerCount = this.remainingTouchCountAfterLift(event);
        hilog.info(RD_DOMAIN, RD_TAG,
          'touchpad-up type=' + event.type.toString() +
            ' touches=' + event.touches.length.toString() +
            ' changed=' + event.changedTouches.length.toString() +
            ' remaining=' + this.touchFingerCount.toString() +
            ' max=' + this.touchMaxFingers.toString() +
            ' moved=' + (this.touchMoved ? 'true' : 'false') +
            ' pending=' + (this.touchDragPending ? 'true' : 'false') +
            ' done=' + (this.touchGestureDone ? 'true' : 'false'));
        if (this.touchFingerCount <= 0) {
          // 所有手指抬起
          if (this.touchDragActive) {
            // 单指长按拖拽结束: 释放左键，避免随后触发普通点击。
            this.sendMouseNow(this.remoteCursorX, this.remoteCursorY, 0, false);
            this.touchDragActive = false;
            this.touchGestureDone = true;
            this.showRemoteCursorIndicator(-1, true);
            hilog.info(RD_DOMAIN, RD_TAG, 'one-finger hold drag end remote=' +
              this.remoteCursorX.toString() + ',' + this.remoteCursorY.toString());
          } else if (event.type === TouchType.Up && !this.touchMoved && this.touchMaxFingers >= 3) {
            // 三指点击只打开/关闭控制面板，不向远端发送鼠标事件。
            this.finishThreeFingerPanel();
          } else if (event.type === TouchType.Up && !this.touchMoved) {
            if (this.touchDragPending) {
              // 双指无移动抬起, 拖拽未启动 → 纯右键 (无左键干扰)
              this.finishTwoFingerRightClick();
            } else if (!this.touchGestureDone) {
              // 单指无移动抬起 → 左键 (跳过双指手势已完成的情况)
              this.sendMouseNow(this.remoteCursorX, this.remoteCursorY, 0, true);
              this.sendMouseNow(this.remoteCursorX, this.remoteCursorY, 0, false);
              this.showRemoteCursorIndicator(0, true);
              hilog.info(RD_DOMAIN, RD_TAG,
                'tap left-click remote=' + this.remoteCursorX.toString() + ',' +
                this.remoteCursorY.toString());
            }
          }
          // 移动后抬起 — 短暂显示环后隐藏
          if (this.touchMoved) {
            this.showRemoteCursorIndicator(-1, true);
          }
          this.resetTouchGesture();
        } else {
          // 从双指变单指 (一根手指抬起, 另一根还在屏幕上)
          if (this.touchMaxFingers >= 3) {
            // 三指候选手势等待所有手指抬起，期间不退化成双指右键或单指移动。
            this.touchDragPending = false;
          } else if (this.touchDragPending) {
            // 双指未移动就有一指抬起 → 双指点击 → 右键
            // (两指通常先后抬起, 必须在第1个Up就发右键, 否则pending会被清除)
            this.finishTwoFingerRightClick();
          }
          const wasDragging: boolean = this.touchDragActive;
          if (wasDragging) {
            // 结束拖拽 — 释放左键
            this.sendMouseNow(this.remoteCursorX, this.remoteCursorY, 0, false);
          }
          this.touchDragActive = false;
          if (wasDragging) {
            this.showRemoteCursorIndicator(-1, true);
          }
          this.touchDragPending = false;
          // 重置剩余手指位置，但多指手势完成前禁止继续作为单指移动光标。
          const remaining = event.touches.length > 0 ? event.touches[0] : point;
          this.touchStartLocalX = remaining.x;
          this.touchStartLocalY = remaining.y;
          this.touchLastLocalX = remaining.x;
          this.touchLastLocalY = remaining.y;
          this.touchMoved = false;
        }
      }
    } catch (err) {
      hilog.error(RD_DOMAIN, RD_TAG, 'touch-pad forward failed: ' + JSON.stringify(err));
    }
  }

  private handleXComponentTouch = (event: TouchEvent): void => {
    if (!this.canForwardInput('touch') && !this.isVncViewOnlySession()) { return; }
    try {
      // R0: 触控事件透传到 native InputHandler (暂用占位对象, R1 完善多点)
      event.stopPropagation();
      const point: LocalPoint | null = this.primaryTouchPoint(event);
      if (!point) {
        if (event.type === TouchType.Cancel) {
          this.resetTouchGesture();
        }
        return;
      }
      if (event.type === TouchType.Down) {
        if (this.touchFingerCount <= 0 &&
          shouldResetRemoteImeOnPointerDown(this.keyboardOpen || this.hardwareKeyboardProxyActive)) {
          this.resetRemoteImeSession('touch-down');
        }
        const oldMaxFingers: number = this.touchMaxFingers;
        if (this.touchFingerCount <= 0) {
          this.touchMoved = false;
          this.touchGestureDone = false;
          this.touchDragPending = false;
          this.touchMaxFingers = 0;
        }
        this.touchFingerCount = this.trackedCanvasTouchCount(event);
        if (this.touchFingerCount > this.touchMaxFingers) {
          this.touchMaxFingers = this.touchFingerCount;
        }
        if (this.touchFingerCount >= 2) {
          if (oldMaxFingers < 2) {
            this.touchDragCursorX = this.remoteCursorX;
            this.touchDragCursorY = this.remoteCursorY;
            const avg: LocalPoint | null = this.averageTouchPoint(event);
            if (avg) {
              this.touchStartLocalX = avg.x;
              this.touchStartLocalY = avg.y;
              this.touchLastLocalX = avg.x;
              this.touchLastLocalY = avg.y;
            }
          }
          if (this.touchLeftDown) {
            this.sendMouseNow(this.remoteCursorX, this.remoteCursorY, 0, false);
            this.touchLeftDown = false;
          }
          this.touchDragPending = this.touchMaxFingers === 2 && !this.touchMoved;
          return;
        }
        const mapped: MappedPoint = this.mapInputPoint(point.x, point.y);
        this.logMappedInput('touch', point.x, point.y, mapped);
        if (!mapped.inside) { return; }
        this.touchStartLocalX = point.x;
        this.touchStartLocalY = point.y;
        this.touchLastLocalX = point.x;
        this.touchLastLocalY = point.y;
        this.touchLeftDown = true;
        this.lastTouchMs = Date.now();
        this.sendMouseNow(mapped.x, mapped.y, 0, true);
        this.startDirectTouchRightClickTimer();
      } else if (event.type === TouchType.Move) {
        this.touchFingerCount = this.trackedCanvasTouchCount(event);
        if (this.touchMaxFingers >= 2) {
          const avg: LocalPoint | null = this.averageTouchPoint(event);
          if (avg) {
            if (this.canvasTwoFingerState.owner === 'canvas-pan') {
              this.touchMoved = true;
              this.touchDragPending = false;
              if (!this.canvasPanActive) {
                this.startCanvasPanFromPoint(avg);
              }
              this.updateCanvasPanFromPoint(avg.x, avg.y);
              return;
            }
            if (this.canvasTwoFingerState.owner === 'remote-touch-pan') {
              this.touchMoved = true;
              this.touchDragPending = false;
              return;
            }
            const dx: number = avg.x - this.touchStartLocalX;
            const dy: number = avg.y - this.touchStartLocalY;
            if (Math.sqrt(dx * dx + dy * dy) > TOUCH_CLICK_SLOP_PX) {
              this.touchMoved = true;
              this.touchDragPending = false;
            }
          }
          return;
        }
        const mapped: MappedPoint = this.mapInputPoint(point.x, point.y);
        this.logMappedInput('touch', point.x, point.y, mapped);
        if (!mapped.inside) { return; }
        if (this.touchLeftDown) {
          const dx: number = point.x - this.touchStartLocalX;
          const dy: number = point.y - this.touchStartLocalY;
          if (Math.sqrt(dx * dx + dy * dy) > TOUCH_CLICK_SLOP_PX) {
            this.touchMoved = true;
            this.clearTouchDirectRightClickTimer();
          }
        }
        this.queueMouseMove(mapped.x, mapped.y);
      } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
        this.clearTouchDirectRightClickTimer();
        this.touchFingerCount = this.remainingTouchCountAfterLift(event);
        if (this.touchMaxFingers === 2 && event.type === TouchType.Up) {
          this.finishCanvasTwoFingerCandidateForRelease(this.touchMoved);
          if (!this.touchMoved && shouldPreserveCanvasTwoFingerRightClick(this.canvasTwoFingerState)) {
            this.touchDragPending = true;
          }
        }
        hilog.info(RD_DOMAIN, RD_TAG,
          'touch-up type=' + event.type.toString() +
            ' touches=' + event.touches.length.toString() +
            ' changed=' + event.changedTouches.length.toString() +
            ' remaining=' + this.touchFingerCount.toString() +
            ' max=' + this.touchMaxFingers.toString() +
            ' moved=' + (this.touchMoved ? 'true' : 'false') +
            ' pending=' + (this.touchDragPending ? 'true' : 'false') +
            ' leftDown=' + (this.touchLeftDown ? 'true' : 'false'));
        if (this.touchMaxFingers >= 3) {
          if (this.touchFingerCount <= 0) {
            if (event.type === TouchType.Up && !this.touchMoved) {
              this.finishThreeFingerPanel();
            }
            this.resetTouchGesture();
          }
          return;
        }
        if (this.touchMaxFingers === 2) {
          if (this.touchFingerCount <= 0) {
            if (event.type === TouchType.Up && !this.touchMoved && this.touchDragPending) {
              this.finishTwoFingerRightClick();
            }
            this.resetTouchGesture();
          }
          return;
        }
        const mapped: MappedPoint = this.mapInputPoint(point.x, point.y);
        this.logMappedInput('touch', point.x, point.y, mapped);
        if (this.touchLeftDown) {
          this.sendMouseNow(mapped.x, mapped.y, 0, false);
        }
        this.touchLeftDown = false;
        this.resetTouchGesture();
      }
    } catch (err) {
      hilog.error(RD_DOMAIN, RD_TAG, 'touch forward failed: ' + JSON.stringify(err));
    }
  }

  private handleConfiguredTouchInput = (event: TouchEvent): void => {
    // RustDesk geometry is synchronized by its low-frequency stream timer;
    // input events must not perform renderer/NAPI reads.
    this.syncActiveTouchPoints(event);
    if (event.type === TouchType.Down && this.hardwareKeyboardProxyActive) {
      // 触摸获焦同样可能抢走隐藏 TextArea；不重置 IME 会话，稍后恢复代理焦点。
      this.scheduleRemoteInputFocus('touch-down');
    }
    const host: RemoteHost | null = this.pendingHost;
    const controlMode: number = this.currentControlMode();
    if (this.consumeCanvasPinchTouch(event)) {
      return;
    }
    this.observeCanvasTwoFingerTouch(event);
    if (controlMode === 2) {
      this.hideTouchIndicator();
      if (this.trackedCanvasTouchCount(event) >= 3 || this.touchMaxFingers >= 3) {
        // 键鼠模式下 3 指仅用于控制面板开关, Move 事件不发送鼠标/滚轮
        if (event.type === TouchType.Move) {
          // 只更新 touchMoved 状态 (区分滑动 vs 点击), 不发远端事件
          const avg: LocalPoint | null = this.averageTouchPoint(event);
          if (avg) {
            const dx: number = avg.x - this.touchStartLocalX;
            const dy: number = avg.y - this.touchStartLocalY;
            if (Math.sqrt(dx * dx + dy * dy) > TOUCH_CLICK_SLOP_PX) {
              this.touchMoved = true;
            }
          }
          return;
        }
        this.handleTouchPadInput(event);
      } else if (event.type === TouchType.Down || event.type === TouchType.Up ||
        event.type === TouchType.Cancel) {
        this.resetTouchGesture();
      }
      return;
    }
    if (controlMode === 1) {
      this.handleXComponentTouch(event);
      return;
    }
    this.handleTouchPadInput(event);
  }

  // T-171-PH4: 物理修饰键状态跟踪 (修复 keyText 抢走组合键)
  private physicalCtrlDown: boolean = false;
  private physicalAltDown: boolean = false;
  private physicalShiftDown: boolean = false;
  private physicalWinDown: boolean = false;
  private physicalModifierKeyCodesDown: Array<number> = [];
  private physicalRemoteKeyCodesDown: Array<number> = [];
  private rdpFilePasteKeyIntercepted: boolean = false;

  private isPhysicalModifierKey(keyCode: number): boolean {
    return keyCode === KEYCODE_CTRL_LEFT || keyCode === KEYCODE_CTRL_RIGHT ||
      keyCode === KEYCODE_ALT_LEFT || keyCode === KEYCODE_ALT_RIGHT ||
      keyCode === KEYCODE_SHIFT_LEFT || keyCode === KEYCODE_SHIFT_RIGHT ||
      keyCode === KEYCODE_META_LEFT || keyCode === KEYCODE_META_RIGHT;
  }

  private updatePhysicalModifierState(keyCode: number, down: boolean): boolean {
    const index: number = this.physicalModifierKeyCodesDown.indexOf(keyCode);
    if (down) {
      // 长按会重复产生 Down；同一个物理修饰键只允许向远端发送一次 Down。
      if (index >= 0) {
        return false;
      }
      this.physicalModifierKeyCodesDown.push(keyCode);
    } else {
      // 丢失 Down 后收到的 Up 不应凭空改变另一个同类修饰键的状态。
      if (index < 0) {
        return false;
      }
      this.physicalModifierKeyCodesDown.splice(index, 1);
    }
    this.physicalCtrlDown = this.physicalModifierKeyCodesDown.indexOf(KEYCODE_CTRL_LEFT) >= 0 ||
      this.physicalModifierKeyCodesDown.indexOf(KEYCODE_CTRL_RIGHT) >= 0;
    this.physicalAltDown = this.physicalModifierKeyCodesDown.indexOf(KEYCODE_ALT_LEFT) >= 0 ||
      this.physicalModifierKeyCodesDown.indexOf(KEYCODE_ALT_RIGHT) >= 0;
    this.physicalShiftDown = this.physicalModifierKeyCodesDown.indexOf(KEYCODE_SHIFT_LEFT) >= 0 ||
      this.physicalModifierKeyCodesDown.indexOf(KEYCODE_SHIFT_RIGHT) >= 0;
    this.physicalWinDown = this.physicalModifierKeyCodesDown.indexOf(KEYCODE_META_LEFT) >= 0 ||
      this.physicalModifierKeyCodesDown.indexOf(KEYCODE_META_RIGHT) >= 0;
    return true;
  }

  private markPhysicalRemoteKeyDown(keyCode: number): void {
    if (this.physicalRemoteKeyCodesDown.indexOf(keyCode) < 0) {
      this.physicalRemoteKeyCodesDown.push(keyCode);
    }
  }

  private clearPhysicalRemoteKeyDown(keyCode: number): boolean {
    const index: number = this.physicalRemoteKeyCodesDown.indexOf(keyCode);
    if (index < 0) {
      return false;
    }
    this.physicalRemoteKeyCodesDown.splice(index, 1);
    return true;
  }

  /** 物理修饰键 OR 虚拟面板修饰键 → 有任意修饰键活动 */
  private hasAnyModifier(): boolean {
    return this.physicalCtrlDown || this.physicalAltDown ||
      this.physicalShiftDown || this.physicalWinDown ||
      this.isModifierLatched('ctrl') || this.isModifierLatched('alt') ||
      this.isModifierLatched('shift') || this.isModifierLatched('win');
  }

  private resetPhysicalModifiers(): void {
    this.physicalCtrlDown = false;
    this.physicalAltDown = false;
    this.physicalShiftDown = false;
    this.physicalWinDown = false;
    this.physicalModifierKeyCodesDown = [];
    this.physicalRemoteKeyCodesDown = [];
  }

  private modifierStateFromEvent(event: KeyEvent, name: string, fallback: boolean): boolean {
    try {
      return event.getModifierKeyState ? event.getModifierKeyState([name]) : fallback;
    } catch (_err) {
      return fallback;
    }
  }

  private reconcilePhysicalModifierGroup(event: KeyEvent, name: string, keyCodes: Array<number>,
    fallback: boolean): void {
    const expectedDown: boolean = this.modifierStateFromEvent(event, name, fallback);
    const held: Array<number> = this.physicalModifierKeyCodesDown.filter((keyCode: number): boolean =>
      keyCodes.indexOf(keyCode) >= 0);
    if (expectedDown && held.length === 0) {
      const syntheticKey: number = keyCodes[0];
      if (this.updatePhysicalModifierState(syntheticKey, true)) {
        this.loader.sendKey(this.sessionId, this.mapPhysicalKeyCode(syntheticKey), true);
        hilog.info(RD_DOMAIN, RD_TAG, 'hwkey-modifier-synth name=' + name + ' down=1');
      }
    } else if (!expectedDown && held.length > 0) {
      for (let index = held.length - 1; index >= 0; index--) {
        if (this.updatePhysicalModifierState(held[index], false)) {
          this.loader.sendKey(this.sessionId, this.mapPhysicalKeyCode(held[index]), false);
        }
      }
      hilog.info(RD_DOMAIN, RD_TAG, 'hwkey-modifier-synth name=' + name + ' down=0');
    }
  }

  private reconcilePhysicalModifiersFromEvent(event: KeyEvent): void {
    this.reconcilePhysicalModifierGroup(event, 'Ctrl',
      [KEYCODE_CTRL_LEFT, KEYCODE_CTRL_RIGHT], this.physicalCtrlDown);
    this.reconcilePhysicalModifierGroup(event, 'Alt',
      [KEYCODE_ALT_LEFT, KEYCODE_ALT_RIGHT], this.physicalAltDown);
    this.reconcilePhysicalModifierGroup(event, 'Shift',
      [KEYCODE_SHIFT_LEFT, KEYCODE_SHIFT_RIGHT], this.physicalShiftDown);
    const metaDown: boolean = event.metaKey === 1;
    if (metaDown !== this.physicalWinDown) {
      const heldMeta: Array<number> = this.physicalModifierKeyCodesDown.filter(
        (keyCode: number): boolean => keyCode === KEYCODE_META_LEFT || keyCode === KEYCODE_META_RIGHT);
      if (metaDown) {
        if (this.updatePhysicalModifierState(KEYCODE_META_LEFT, true)) {
          this.loader.sendKey(this.sessionId, this.mapPhysicalKeyCode(KEYCODE_META_LEFT), true);
        }
      } else {
        for (let index = heldMeta.length - 1; index >= 0; index--) {
          if (this.updatePhysicalModifierState(heldMeta[index], false)) {
            this.loader.sendKey(this.sessionId, this.mapPhysicalKeyCode(heldMeta[index]), false);
          }
        }
      }
      hilog.info(RD_DOMAIN, RD_TAG, 'hwkey-modifier-synth name=Meta down=' + (metaDown ? '1' : '0'));
    }
  }

  /** HarmonyOS 将 F1-F12 与 F13-F24 分成两个连续的键码区间。 */
  private isFunctionKey(keyCode: number): boolean {
    return (keyCode >= KEY_F1 && keyCode <= KEY_F12) ||
      (keyCode >= KEY_F13 && keyCode <= KEY_F24);
  }

  /**
   * API 23 的按键派发顺序是 onKeyPreIme → IME → onKeyEvent。自动桌面代理
   * 模式下所有实体键都在 IME 之前拦截，避免本地输入法抢占控制端键盘；
   * 虚拟键盘模式只提前拦截非文本键，普通字符保留给 IME 组词。
   */
  private shouldInterceptKeyboardProxyKey(event: KeyEvent): boolean {
    if (this.hardwareKeyboardProxyActive || (!this.keyboardOpen && this.shouldUseHardwareKeyboardProxy())) {
      return true;
    }
    if (!this.keyboardOpen) {
      return false;
    }
    const keyCode: number = event.keyCode;
    if (this.isPhysicalModifierKey(keyCode) || this.isFixedControlKey(keyCode) ||
      this.isFunctionKey(keyCode) || this.hasAnyModifier()) {
      return true;
    }
    return this.printableTextForPhysicalKey(event).length === 0;
  }

  /** 输入框代理的前置按键回调：在 IME 消费功能键前将其发送到远端。 */
  private handleKeyboardProxyPreIme = (event: KeyEvent): boolean => {
    const intercept: boolean = this.shouldInterceptKeyboardProxyKey(event);
    hilog.info(RD_DOMAIN, RD_TAG, 'hwkey-pre-ime type=' + event.type.toString() +
      ' code=' + event.keyCode.toString() +
      ' textLength=' + (event.keyText ? event.keyText.length : 0).toString() +
      ' action=' + (intercept ? 'intercept' : 'ime'));
    if (!intercept) {
      return false;
    }
    // 返回 true 会阻断输入法，但 stopPropagation 还要阻止页面快捷键/父节点
    // 继续冒泡，尤其是 Ctrl+Space、Alt+Tab、Meta 组合键。
    event.stopPropagation();
    if (!this.canForwardInput('key-pre-ime')) {
      // 输入未就绪时也消费非文本键，避免它们改变隐藏 TextArea 的本地编辑状态。
      return true;
    }
    this.handleXComponentKey(event);
    return true;
  };

  private handleRemoteKeyboardFocusLost(source: string): void {
    if (!this.connected || this.sessionId <= 0) {
      return;
    }
    if (this.physicalMouseDownButton >= 0) {
      hilog.info(RD_DOMAIN, RD_TAG, 'remote-keyboard-focus-lost preserve-drag source=' + source +
        ' button=' + this.physicalMouseDownButton.toString());
      return;
    }
    hilog.info(RD_DOMAIN, RD_TAG, 'remote-keyboard-focus-lost source=' + source);
    this.releaseAllHeldKeys(false);
  }

  /**
   * macOS 布局通常把本地 Ctrl 映射为远端 Command，供 Ctrl+C/V 使用；但
   * macOS 默认切换输入源是 Control+Space。这里把本地 Ctrl+Space 保留为
   * 专用输入源快捷键：暂时释放远端 Command，发送 Control+Space，再恢复
   * 仍被实体键按住的 Command。keyboardShortcut 用于兜底鸿蒙未向
   * onKeyPreIme 下发 Space 的系统快捷键场景。
   */
  private sendMacInputSourceShortcut(source: string): void {
    if (!this.canForwardInput('mac-input-source') ||
      this.physicalKeyboardLayout !== RemoteKeyboardLayout.MACOS ||
      !this.physicalCtrlDown || this.physicalAltDown || this.physicalShiftDown || this.physicalWinDown) {
      return;
    }
    const now: number = Date.now();
    if (now - this.lastMacInputSourceShortcutMs < 80) {
      return;
    }
    this.lastMacInputSourceShortcutMs = now;
    const remoteCommandKey: number = this.mapPhysicalKeyCode(KEYCODE_CTRL_LEFT);
    try {
      this.loader.sendKey(this.sessionId, remoteCommandKey, false);
      this.loader.sendKey(this.sessionId, KEYCODE_CTRL_LEFT, true);
      this.loader.sendKey(this.sessionId, KEYCODE_SPACE, true);
      this.loader.sendKey(this.sessionId, KEYCODE_SPACE, false);
      this.loader.sendKey(this.sessionId, KEYCODE_CTRL_LEFT, false);
      if (this.physicalCtrlDown) {
        this.loader.sendKey(this.sessionId, remoteCommandKey, true);
      }
      hilog.info(RD_DOMAIN, RD_TAG, 'mac-input-source-shortcut source=' + source +
        ' remoteCommand=' + remoteCommandKey.toString());
    } catch (err) {
      hilog.error(RD_DOMAIN, RD_TAG, 'mac-input-source-shortcut failed source=' + source +
        ' error=' + JSON.stringify(err));
    }
  }

  private sendMacCapsInputSourceShortcut(source: string): void {
    if (!this.canForwardInput('mac-caps-input-source') ||
      this.physicalKeyboardLayout !== RemoteKeyboardLayout.MACOS) {
      return;
    }
    try {
      this.loader.sendKey(this.sessionId, KEYCODE_CTRL_LEFT, true);
      this.loader.sendKey(this.sessionId, KEYCODE_SPACE, true);
      this.loader.sendKey(this.sessionId, KEYCODE_SPACE, false);
      this.loader.sendKey(this.sessionId, KEYCODE_CTRL_LEFT, false);
      hilog.info(RD_DOMAIN, RD_TAG, 'mac-caps-input-source-shortcut source=' + source);
    } catch (err) {
      hilog.error(RD_DOMAIN, RD_TAG, 'mac-caps-input-source-shortcut failed source=' + source +
        ' error=' + JSON.stringify(err));
    }
  }

  private clearMacCapsLockHoldTimer(): void {
    if (this.macCapsLockHoldTimer >= 0) {
      clearTimeout(this.macCapsLockHoldTimer);
      this.macCapsLockHoldTimer = -1;
    }
  }

  private releasePendingMacCapsLock(): void {
    this.clearMacCapsLockHoldTimer();
    if (this.macCapsLockRawDown && this.sessionId > 0) {
      try {
        this.loader.sendKey(this.sessionId, RUSTDESK_MACOS_CAPS_LOCK_RAW, false);
      } catch (err) {
        hilog.warn(RD_DOMAIN, RD_TAG, 'release mac caps lock failed: ' + JSON.stringify(err));
      }
    }
    this.macCapsLockDownAtMs = 0;
    this.macCapsLockRawDown = false;
  }

  private handleRustDeskMacCapsLock(isDown: boolean, isUp: boolean): boolean {
    if (isDown) {
      if (this.macCapsLockDownAtMs > 0) {
        return true;
      }
      this.macCapsLockDownAtMs = Date.now();
      this.macCapsLockRawDown = false;
      this.clearMacCapsLockHoldTimer();
      this.macCapsLockHoldTimer = setTimeout((): void => {
        this.macCapsLockHoldTimer = -1;
        if (this.macCapsLockDownAtMs <= 0 || !this.canForwardInput('mac-caps-long')) {
          return;
        }
        this.loader.sendKey(this.sessionId, RUSTDESK_MACOS_CAPS_LOCK_RAW, true);
        this.macCapsLockRawDown = true;
        hilog.info(RD_DOMAIN, RD_TAG, 'mac-caps-long raw-down threshold=' +
          MACOS_CAPS_LOCK_LONG_PRESS_MS.toString());
      }, MACOS_CAPS_LOCK_LONG_PRESS_MS);
      return true;
    }
    if (!isUp || this.macCapsLockDownAtMs <= 0) {
      return true;
    }

    const durationMs: number = Date.now() - this.macCapsLockDownAtMs;
    this.clearMacCapsLockHoldTimer();
    if (this.macCapsLockRawDown || isMacCapsLockLongPress(durationMs)) {
      if (!this.macCapsLockRawDown) {
        this.loader.sendKey(this.sessionId, RUSTDESK_MACOS_CAPS_LOCK_RAW, true);
      }
      this.loader.sendKey(this.sessionId, RUSTDESK_MACOS_CAPS_LOCK_RAW, false);
      hilog.info(RD_DOMAIN, RD_TAG, 'mac-caps-long raw-up durationMs=' + durationMs.toString());
    } else {
      this.sendMacCapsInputSourceShortcut('caps-short');
      hilog.info(RD_DOMAIN, RD_TAG, 'mac-caps-short input-source durationMs=' + durationMs.toString());
    }
    this.macCapsLockDownAtMs = 0;
    this.macCapsLockRawDown = false;
    return true;
  }

  private handleXComponentKey = (event: KeyEvent): boolean => {
    hilog.info(RD_DOMAIN, RD_TAG, 'hwkey-entry type=' + event.type.toString() +
      ' code=' + event.keyCode.toString() +
      ' textLength=' + (event.keyText ? event.keyText.length : 0).toString());
    if (!this.canForwardInput('key')) { return true; }
    if (this.shouldRequirePhysicalKeyboardLayout() && !this.physicalKeyboardLayoutConfirmed) {
      this.promptPhysicalKeyboardLayout();
      return true;
    }
    try {
      event.stopPropagation();
      const isDown: boolean = event.type === KeyType.Down;
      const isUp: boolean = event.type === KeyType.Up;
      if (!isDown && !isUp) {
        return true;
      }
      const kc: number = event.keyCode;
      if (!this.isPhysicalModifierKey(kc)) {
        this.reconcilePhysicalModifiersFromEvent(event);
      }

      if (kc === KEY_V && isUp && this.rdpFilePasteKeyIntercepted) {
        this.rdpFilePasteKeyIntercepted = false;
        return true;
      }
      if (kc === KEY_V && isDown && this.physicalCtrlDown &&
        !this.physicalAltDown && !this.physicalShiftDown && !this.physicalWinDown &&
        this.physicalKeyboardLayout === RemoteKeyboardLayout.WINDOWS &&
        this.pendingHost !== null && this.pendingHost.protocol === 'rdp' &&
        this.systemPasteboardHasFileUri()) {
        this.rdpFilePasteKeyIntercepted = true;
        this.loader.sendKey(this.sessionId, this.mapPhysicalKeyCode(KEYCODE_CTRL_LEFT), false);
        this.loader.sendKey(this.sessionId, this.mapPhysicalKeyCode(KEYCODE_CTRL_RIGHT), false);
        this.handleRdpSystemFilePaste();
        return true;
      }

      // 物理修饰键: 跟踪状态 + 发送 down/up
      if (this.isPhysicalModifierKey(kc)) {
        const stateChanged: boolean = this.updatePhysicalModifierState(kc, isDown);
        const remoteKeyCode: number = this.mapPhysicalKeyCode(kc);
        if (stateChanged) {
          this.loader.sendKey(this.sessionId, remoteKeyCode, isDown);
        }
        hilog.info(RD_DOMAIN, RD_TAG,
          'hwkey-modifier code=' + kc.toString() + ' remote=' + remoteKeyCode.toString() +
            ' layout=' + this.physicalKeyboardLayout + ' down=' + (isDown ? 'yes' : 'no') +
            ' changed=' + (stateChanged ? 'yes' : 'no') +
            ' phys=[ctrl=' + (this.physicalCtrlDown ? '1' : '0') +
            ' alt=' + (this.physicalAltDown ? '1' : '0') +
            ' shift=' + (this.physicalShiftDown ? '1' : '0') +
            ' win=' + (this.physicalWinDown ? '1' : '0') + ']');
        return true;
      }

      // 非修饰键控制键: 始终走 sendKey (Tab/Enter/Esc/Del/方向键/F键等)
      if (this.isFixedControlKey(kc)) {
        const useRustDeskMacCaps: boolean = kc === KEYCODE_CAPS_LOCK &&
          this.physicalKeyboardLayout === RemoteKeyboardLayout.MACOS &&
          this.pendingHost !== null && this.pendingHost.protocol === 'rustdesk';
        if (useRustDeskMacCaps) {
          return this.handleRustDeskMacCapsLock(isDown, isUp);
        }
        const remoteKeyCode: number = this.mapPhysicalKeyCode(kc);
        this.loader.sendKey(this.sessionId, remoteKeyCode, isDown);
        hilog.info(RD_DOMAIN, RD_TAG,
          'hwkey-control code=' + kc.toString() + ' remote=' + remoteKeyCode.toString() +
            ' down=' + (isDown ? 'yes' : 'no'));
        return true;
      }

      if (kc === KEYCODE_SPACE && this.physicalKeyboardLayout === RemoteKeyboardLayout.MACOS &&
        this.physicalCtrlDown && !this.physicalAltDown && !this.physicalShiftDown && !this.physicalWinDown) {
        if (isDown) {
          this.sendMacInputSourceShortcut('pre-ime');
        }
        return true;
      }

      // 普通键 (字母/数字/符号)
      const remoteKeyCode: number = this.mapPhysicalKeyCode(kc);
      if (isDown) {
        // 实体键盘必须保留真实 down/up，让远端操作系统的键盘布局和 IME
        // 处理按键。sendText 会绕过 macOS/Windows 输入法，只适用于虚拟键盘。
        this.loader.sendKey(this.sessionId, remoteKeyCode, true);
        this.markPhysicalRemoteKeyDown(remoteKeyCode);
        hilog.info(RD_DOMAIN, RD_TAG, 'hwkey-physical code=' + kc.toString() +
          ' remote=' + remoteKeyCode.toString() + ' down');
      } else if (isUp) {
        if (this.clearPhysicalRemoteKeyDown(remoteKeyCode)) {
          this.loader.sendKey(this.sessionId, remoteKeyCode, false);
          hilog.info(RD_DOMAIN, RD_TAG, 'hwkey-physical code=' + kc.toString() +
            ' remote=' + remoteKeyCode.toString() + ' up');
        }
      }
    } catch (err) {
      hilog.error(RD_DOMAIN, RD_TAG, 'key forward failed: ' + JSON.stringify(err));
    }
    return true;
  }

  /** 非修饰键的控制键 (始终走 sendKey down/up) */
  private isFixedControlKey(keyCode: number): boolean {
    return keyCode === KEYCODE_DPAD_UP ||
      keyCode === KEYCODE_DPAD_DOWN ||
      keyCode === KEYCODE_DPAD_LEFT ||
      keyCode === KEYCODE_DPAD_RIGHT ||
      keyCode === KEYCODE_TAB ||
      keyCode === KEYCODE_SPACE ||
      keyCode === KEYCODE_ENTER ||
      keyCode === KEYCODE_DEL ||
      keyCode === KEYCODE_PAGE_UP ||
      keyCode === KEYCODE_PAGE_DOWN ||
      keyCode === KEYCODE_ESCAPE ||
      keyCode === KEYCODE_FORWARD_DEL ||
      keyCode === KEYCODE_MENU ||
      keyCode === KEYCODE_CAPS_LOCK ||
      keyCode === KEYCODE_SCROLL_LOCK ||
      keyCode === KEYCODE_MOVE_HOME ||
      keyCode === KEYCODE_MOVE_END ||
      keyCode === KEYCODE_INSERT ||
      keyCode === KEYCODE_NUM_LOCK;
  }

  /**
   * KeyEvent.keyText 是键名（例如 KEYCODE_A），不是可发送文本。
   * API 23 文档规定 unicode 才是当前按键的 Unicode 值；部分外设/系统
   * 版本可能不给 unicode，因此保留按键码回退以覆盖常见 US 键盘字符。
   */
  private printableTextForPhysicalKey(event: KeyEvent): string {
    const unicode: number | undefined = event.unicode;
    if (unicode !== undefined && unicode >= 0x21 && unicode <= 0x7E) {
      return String.fromCharCode(unicode);
    }

    const keyCode: number = event.keyCode;
    let base: string = '';
    if (keyCode >= KEYCODE_0 && keyCode <= KEYCODE_9) {
      base = String.fromCharCode(48 + keyCode - KEYCODE_0);
    } else if (keyCode >= KEY_A && keyCode <= KEY_Z) {
      base = String.fromCharCode(97 + keyCode - KEY_A);
    } else {
      switch (keyCode) {
        case KEYCODE_GRAVE: base = '`'; break;
        case KEYCODE_MINUS: base = '-'; break;
        case KEYCODE_EQUALS: base = '='; break;
        case KEYCODE_LEFT_BRACKET: base = '['; break;
        case KEYCODE_RIGHT_BRACKET: base = ']'; break;
        case KEYCODE_BACKSLASH: base = '\\'; break;
        case KEYCODE_SEMICOLON: base = ';'; break;
        case KEYCODE_APOSTROPHE: base = "'"; break;
        case KEYCODE_COMMA: base = ','; break;
        case KEYCODE_PERIOD: base = '.'; break;
        case KEYCODE_SLASH: base = '/'; break;
        case KEYCODE_AT: base = '@'; break;
        case KEYCODE_PLUS: base = '+'; break;
        default: return '';
      }
    }

    const eventShift: boolean = event.getModifierKeyState ?
      event.getModifierKeyState(['Shift']) : false;
    const shift: boolean = this.physicalShiftDown || eventShift;
    const capsLock: boolean = event.isCapsLockOn === true;
    if (base >= 'a' && base <= 'z') {
      return shift !== capsLock ? base.toUpperCase() : base;
    }
    if (!shift) {
      return base;
    }
    switch (base) {
      case '`': return '~';
      case '1': return '!';
      case '2': return '@';
      case '3': return '#';
      case '4': return '$';
      case '5': return '%';
      case '6': return '^';
      case '7': return '&';
      case '8': return '*';
      case '9': return '(';
      case '0': return ')';
      case '-': return '_';
      case '=': return '+';
      case '[': return '{';
      case ']': return '}';
      case '\\': return '|';
      case ';': return ':';
      case "'": return '"';
      case ',': return '<';
      case '.': return '>';
      case '/': return '?';
      default: return base;
    }
  }

  private mapArkMouseButton(button: number): number {
    // ArkUI MouseButton 是位值: Left=1, Right=2, Middle=4, None=0。
    // 协议层内部枚举是 Left=0, Middle=1, Right=2, Move=-1。
    if (button === MouseButton.Left || button === 1) { return 0; }
    if (button === MouseButton.Middle || button === 4) { return 1; }
    if (button === MouseButton.Right || button === 2) { return 2; }
    return -1;
  }

  private handleXComponentAxis = (event?: AxisEvent): void => {
    if (!event || !this.canForwardInput('mouseWheel')) { return; }
    try {
      const localX: number = event.x;
      const localY: number = event.y;
      const mapped: MappedPoint = this.mapInputPoint(localX, localY);
      if (!mapped.inside) { return; }
      const rawVertical: number = event.getVerticalAxisValue();
      if (!Number.isFinite(rawVertical) || rawVertical === 0) { return; }

      // Mouse wheels report discrete steps. Touchpads emit a continuous axis,
      // so accumulate its small vp deltas before creating protocol wheel ticks.
      let delta: number = 0;
      if (event.sourceTool === SourceTool.MOUSE) {
        delta = rawVertical > 0 ? 1 : -1;
      } else {
        this.physicalWheelRemainder += rawVertical * TOUCHPAD_SCROLL_GAIN;
        delta = this.physicalWheelRemainder > 0 ? Math.floor(this.physicalWheelRemainder) :
          Math.ceil(this.physicalWheelRemainder);
        if (delta === 0) { return; }
        if (delta > TOUCHPAD_SCROLL_MAX_DELTA) {
          delta = TOUCHPAD_SCROLL_MAX_DELTA;
        } else if (delta < -TOUCHPAD_SCROLL_MAX_DELTA) {
          delta = -TOUCHPAD_SCROLL_MAX_DELTA;
        }
        this.physicalWheelRemainder -= delta;
      }

      this.queueMouseMove(mapped.x, mapped.y);
      this.flushMouseMove();
      const src: Record<string, number> = this.toSourceSpace(mapped.x, mapped.y);
      const sendDelta: number = this.rustdeskReverseWheel ? -delta : delta;
      this.loader.sendMouseWheel(this.sessionId, src['x'], src['y'], sendDelta);
      hilog.info(RD_DOMAIN, RD_TAG, 'physical-wheel raw=' + rawVertical.toString() +
        ' delta=' + sendDelta.toString() + ' sourceTool=' + event.sourceTool.toString() +
        ' remote=' + mapped.x.toString() + ',' + mapped.y.toString());
    } catch (err) {
      hilog.error(RD_DOMAIN, RD_TAG, 'physical-wheel forward failed: ' + JSON.stringify(err));
    }
  }

  private handleXComponentMouse = (event: MouseEvent): void => {
    if (!this.canForwardInput('mouse')) { return; }
    try {
      event.stopPropagation();
      const localX: number = event.x as number;
      const localY: number = event.y as number;
      const mapped: MappedPoint = this.mapInputPoint(localX, localY);
      this.logMappedInput('mouse', localX, localY, mapped);
      if (!mapped.inside && event.action !== MouseAction.Release) {
        return;
      }
      const rawButton: number = event.button as number;
      const mappedButton: number = this.mapArkMouseButton(rawButton);
      const sendButton: number = event.action === MouseAction.Release && mappedButton < 0 ?
        this.physicalMouseDownButton : mappedButton;
      if (event.action === MouseAction.Press || event.action === MouseAction.Release) {
        hilog.info(RD_DOMAIN, RD_TAG,
          'physical-mouse action=' + (event.action as number).toString() +
            ' rawButton=' + rawButton.toString() +
            ' mappedButton=' + mappedButton.toString() +
            ' sendButton=' + sendButton.toString() +
            ' remote=' + mapped.x.toString() + ',' + mapped.y.toString());
      }
      if (event.action === MouseAction.Press) {
        if (shouldResetRemoteImeOnPointerDown(this.keyboardOpen || this.hardwareKeyboardProxyActive)) {
          this.resetRemoteImeSession('mouse-press');
        }
        if (sendButton >= 0) {
          this.physicalMouseDownButton = sendButton;
          this.sendMouseNow(mapped.x, mapped.y, sendButton, true);
        }
      } else if (event.action === MouseAction.Release) {
        if (sendButton >= 0) {
          this.sendMouseNow(mapped.x, mapped.y, sendButton, false);
        }
        this.physicalMouseDownButton = -1;
        if (this.hardwareKeyboardProxyActive) {
          this.scheduleRemoteInputFocus('mouse-release');
        }
      } else if (event.action === MouseAction.Move || event.action === MouseAction.Hover) {
        this.queueMouseMove(mapped.x, mapped.y);
      }
      // MouseAction only covers button and pointer motion. ArkUI dispatches
      // mouse wheels and touchpad two-finger scrolling via onAxisEvent.
    } catch (err) {
      hilog.error(RD_DOMAIN, RD_TAG, 'mouse forward failed: ' + JSON.stringify(err));
    }
  }

  private remoteImeAnchorX(): number {
    return Math.max(0, (this.surfaceWidth - 1) / 2);
  }

  private remoteImeAnchorY(): number {
    return Math.max(0, (this.surfaceHeight - 1) / 2);
  }

  @Builder
  private rustDeskDisplayResolutionMenu() {
    Column({ space: 8 }) {
      Row() {
        Column() {
          Text('远端显示器与分辨率').fontSize(15).fontWeight(FontWeight.Medium).fontColor('#1B1B1B')
          Text(this.rustDeskDisplayCapabilities.width.toString() + ' × ' +
            this.rustDeskDisplayCapabilities.height.toString())
            .fontSize(11).fontColor('#6B7280').margin({ top: 2 })
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        Button() {
          SymbolGlyph($r('sys.symbol.xmark')).fontSize(16).fontColor(['#4B5563'])
        }
        .width(32).height(32).backgroundColor(Color.Transparent)
        .onClick((): void => { this.showRustDeskDisplayResolutionMenu = false; })
      }.width('100%')
      Scroll() {
        Column({ space: 6 }) {
          if (this.rustDeskDisplayCapabilities.displays.length > 0) {
            Text('远端显示器').fontSize(12).fontColor('#6B7280').margin({ top: 2, bottom: 2 })
              .alignSelf(ItemAlign.Start)
            ForEach(this.rustDeskDisplayCapabilities.displays,
              (display: RustDeskDisplayInfo): void => {
                Row() {
                  Column() {
                    Text(this.rustDeskDisplayLabel(display))
                      .fontSize(13)
                      .fontColor(display.display === this.rustDeskDisplayCapabilities.currentDisplay ?
                        '#FFFFFF' : '#374151')
                      .maxLines(1)
                    Text(display.width.toString() + ' × ' + display.height.toString() +
                      '  ' + display.x.toString() + ', ' + display.y.toString())
                      .fontSize(10)
                      .fontColor(display.display === this.rustDeskDisplayCapabilities.currentDisplay ?
                        'rgba(255,255,255,0.78)' : '#6B7280')
                      .margin({ top: 2 })
                  }.alignItems(HorizontalAlign.Start).layoutWeight(1)
                  if (display.display === this.rustDeskDisplayCapabilities.currentDisplay) {
                    SymbolGlyph($r('sys.symbol.checkmark')).fontSize(15).fontColor(['#FFFFFF'])
                  }
                }
                .width('100%').height(44).padding({ left: 12, right: 12, top: 6, bottom: 6 })
                .backgroundColor(display.display === this.rustDeskDisplayCapabilities.currentDisplay ?
                  this.accentColor : '#F3F4F6')
                .borderRadius(6)
                .onClick((): void => { this.selectRustDeskDisplay(display); })
              }, (display: RustDeskDisplayInfo): string => display.display.toString())
            Divider().strokeWidth(1).color('#E5E7EB').margin({ top: 4, bottom: 2 })
          }
          Text('当前显示器分辨率').fontSize(12).fontColor('#6B7280').margin({ top: 2, bottom: 2 })
            .alignSelf(ItemAlign.Start)
          ForEach(this.rustDeskDisplayCapabilities.resolutions,
            (resolution: RustDeskDisplayResolution): void => {
              Row() {
                Text(resolution.width.toString() + ' × ' + resolution.height.toString())
                  .fontSize(13).fontColor(this.isRustDeskDisplayResolutionSelected(resolution) ? '#FFFFFF' : '#374151')
                  .layoutWeight(1)
                if (this.isRustDeskDisplayResolutionSelected(resolution)) {
                  SymbolGlyph($r('sys.symbol.checkmark')).fontSize(15).fontColor(['#FFFFFF'])
                }
              }
              .width('100%').height(40).padding({ left: 12, right: 12 })
              .backgroundColor(this.isRustDeskDisplayResolutionSelected(resolution) ? this.accentColor : '#F3F4F6')
              .borderRadius(6)
              .onClick((): void => { this.changeRustDeskDisplayResolution(resolution.width, resolution.height); })
            }, (resolution: RustDeskDisplayResolution): string =>
              resolution.width.toString() + 'x' + resolution.height.toString())
          if (this.rustDeskDisplayCapabilities.resolutions.length === 0) {
            Text('当前显示器暂无可选分辨率').fontSize(12).fontColor('#6B7280')
              .width('100%').textAlign(TextAlign.Center).padding({ top: 10, bottom: 10 })
          }
        }.width('100%')
      }.constraintSize({ maxHeight: 360 }).scrollBar(BarState.Off)
    }
    .width(260).padding(14).backgroundColor('rgba(255,255,255,0.98)').borderRadius(8)
    .shadow({ radius: 14, color: 'rgba(0,0,0,0.22)', offsetY: 4 })
    .position({ x: Math.max(12, this.surfaceWidth - 272), y: 70 })
  }

  build() {
    Stack() {
      // XComponent 全屏渲染层 — 始终存在, 连接前被 loading 层遮住
      XComponent({
        id: this.xcId,
        type: XComponentType.SURFACE,
        libraryname: 'rdpnapi',
        controller: this.xComponentController
      })
      .width('100%').height('100%')
      .backgroundColor('#000000')
      .focusable(true)
      .focusOnTouch(true)
      .onHover(this.handleRemoteSurfaceHover)
      .onLoad(this.onXComponentLoad)
      .onDestroy(this.onXComponentDestroy)
      .onTouch(this.handleConfiguredTouchInput)
      .onKeyEvent(this.handleXComponentKey)
      .onMouse(this.handleXComponentMouse)
      .onAreaChange((_o: Area, n: Area): void => {
        const wVp: number = n.width as number;
        const hVp: number = n.height as number;
        const wPx: number = Math.round(this.vpToPx(wVp));
        const hPx: number = Math.round(this.vpToPx(hVp));
        const previousSurfaceWidth: number = this.surfaceWidth;
        const previousSurfaceHeight: number = this.surfaceHeight;
        if (Math.abs(wVp - this.surfaceWidth) < 1 && Math.abs(hVp - this.surfaceHeight) < 1 &&
          Math.abs(wPx - this.renderWidthPx) < 1 && Math.abs(hPx - this.renderHeightPx) < 1) {
          return;
        }
        this.surfaceWidth = wVp;
        this.surfaceHeight = hVp;
        this.renderWidthPx = wPx;
        this.renderHeightPx = hPx;
        this.releaseCanvasPinchInput('surface-resize');
        this.invalidateRendererViewportCache();
        // A resize/orientation change can move the local TouchEvent origin
        // while a finger is still down.  Consume the first post-resize move
        // as a new anchor so the old coordinate space cannot create a jump.
        this.touchpadAnchorValid = false;
        this.resetTouchpadPointerCurve();
        this.restoreModifierPanelPositions(previousSurfaceWidth, previousSurfaceHeight);
        if (this.handleVisible) {
          this.handleX = this.handleSide === 'left' ?
            this.modifierHiddenLeftX() : this.modifierHiddenRightX(this.surfaceWidth);
        }
        if (this.shouldShowActiveDiagnostics()) {
          this.rustDeskDiagnosticsDockY = this.avoidRustDeskDiagnosticsDockCollision(
            this.rustDeskDiagnosticsDockSide, this.rustDeskDiagnosticsDockY);
        }
        hilog.info(RD_DOMAIN, RD_TAG, 'surface area=' + Math.round(wVp).toString() + 'x' +
          Math.round(hVp).toString() + 'vp render=' + wPx.toString() + 'x' + hPx.toString() + 'px');
        // resizeRenderer 告诉 GL 渲染器实际的 EGL surface 像素尺寸,
        // 使 contain/letterbox viewport 计算与表面一致。必须调用。
        if (this.rendererHandle > 0 && wPx > 0 && hPx > 0 &&
          !this.renderPreservedInPip && !this.pipSurfaceTransferInProgress) {
          this.loader.resizeRenderer(this.rendererHandle, wPx, hPx);
          if (this.canvasTransformGestureModified) {
            this.applyCanvasTransform();
          } else {
            this.resetCanvasToDisplayDefault();
          }
        }
        // HarmonyOS can restore the window cursor during a layout/orientation
        // transaction. Re-apply the current owner after the new surface
        // geometry is published so the system cursor and virtual overlay do
        // not diverge after a long-running session.
        this.syncRemoteSystemPointer('surface-area-change',
          this.remoteSurfaceHovered !== false, true);
      })

      // Loading / 错误覆盖层
      // 注意: 不透明白底会阻止底层 XComponent 的 surface 创建 (框架优化),
      // 因此必须保留微小透明通道让框架感知 XComponent 需要渲染表面。
      if (!this.connected) {
        Column() {
          if (this.connecting) {
            LoadingProgress().width(40).height(40).color(this.accentColor)
            Text($r('app.string.connecting')).fontSize(15)
              .fontColor('rgba(255,255,255,0.6)')
              .margin({ top: 16 })
            if (this.hostLabel !== '') {
              Text(this.hostLabel).fontSize(12)
                .fontColor('rgba(255,255,255,0.35)')
                .margin({ top: 8 })
            }
            if (this.pendingHost !== null && this.pendingHost.protocol === 'rustdesk' &&
              this.pendingHost.rustdeskAuthMode === 'request_approval') {
              Text('已请求被控端批准，请在对方设备上点击允许')
                .fontSize(12).fontColor('rgba(255,255,255,0.65)')
                .margin({ top: 12 })
              Text('等待最多约 90 秒，可返回后改用设备密码')
                .fontSize(11).fontColor('rgba(255,255,255,0.38)')
                .margin({ top: 5 })
            }
          } else {
            Text($r('app.string.connection_error')).fontSize(18).fontColor(this.pal().danger)
            Text(this.connectionError).fontSize(13)
              .fontColor('rgba(255,255,255,0.7)')
              .margin({ top: 8 })
            Text(this.connectionErrorDetail).fontSize(11)
              .fontColor('rgba(255,255,255,0.35)')
              .fontFamily('monospace')
              .margin({ top: 4 })
              .maxLines(3).textOverflow({ overflow: TextOverflow.Ellipsis })
            Button($r('app.string.btn_back')).margin({ top: 24 })
              .backgroundColor(this.accentColor)
              .borderRadius(10)
              .onClick(() => { this.goBack(); })
          }
        }
        .width('100%').height('100%')
        .justifyContent(FlexAlign.Center)
        .backgroundColor('rgba(0,0,0,0.01)')  // 几乎透明 — 保证 XComponent surface 创建
      }

      // XComponent 配置 libraryname 后, API 23 可能把触摸事件直接路由到 native 侧,
      // 绕过 ArkTS onTouch。这里使用 Gesture API (TapGesture + PanGesture) 作为兜底拦截层,
      // 并保留 onTouch 作为兼容路径。
      if (this.connected) {
        Stack() {
          Text(' ')
            .width('100%')
            .height('100%')
            .fontSize(1)
            .fontColor('rgba(0,0,0,0.01)')
        }
        .width('100%').height('100%')
        .id('remoteInputSurface')
        .backgroundColor('rgba(0,0,0,0.01)')
        .hitTestBehavior(HitTestMode.Block)
        .focusable(true)
        .focusOnTouch(true)
        .defaultFocus(true)
        .onFocus((): void => {
          hilog.info(RD_DOMAIN, RD_TAG, 'remote-input-focus target=overlay');
        })
        .onBlur((): void => {
          hilog.info(RD_DOMAIN, RD_TAG, 'remote-input-blur target=overlay');
          this.handleRemoteKeyboardFocusLost('overlay');
        })
        .onTouch(this.handleConfiguredTouchInput)
        .gesture(
          GestureGroup(GestureMode.Parallel,
            PinchGesture({ fingers: 2, distance: 5 })
              .allowedTypes([SourceTool.Finger])
              .onActionStart((event: GestureEvent): void => { this.startCanvasPinch(event); })
              .onActionUpdate((event: GestureEvent): void => { this.updateCanvasPinch(event); })
              .onActionEnd((_event: GestureEvent): void => { this.endCanvasPinchGesture('gesture-end'); })
              .onActionCancel((): void => { this.endCanvasPinchGesture('gesture-cancel'); }),
            LongPressGesture({ fingers: 2, duration: CANVAS_TWO_FINGER_HOLD_MS })
              .allowedTypes([SourceTool.Finger])
              .onAction((event: GestureEvent): void => { this.armCanvasTwoFingerPanFromLongPress(event); }),
            PanGesture({ fingers: 2, distance: 5 })
              .allowedTypes([SourceTool.Finger])
              .onActionStart((event: GestureEvent): void => { this.startCanvasPan(event); })
              .onActionUpdate((event: GestureEvent): void => { this.updateCanvasPan(event); })
              .onActionEnd((_event: GestureEvent): void => { this.endCanvasPanGesture('canvas-pan-end'); })
              .onActionCancel((): void => { this.endCanvasPanGesture('canvas-pan-cancel'); })
          )
        )
        .onMouse(this.handleXComponentMouse)
        .onAxisEvent(this.handleXComponentAxis)
        .onKeyEvent(this.handleXComponentKey)
        .allowDrop([uniformTypeDescriptor.UniformDataType.FILE])
        .onDragEnter((event: DragEvent): void => {
          this.dropHoverActive = true;
          hilog.info(RD_DOMAIN, RD_TAG, 'drop-enter');
        })
        .onDragLeave((event: DragEvent): void => {
          this.dropHoverActive = false;
          hilog.info(RD_DOMAIN, RD_TAG, 'drop-leave');
        })
        .onDrop((event: DragEvent): void => {
          this.dropHoverActive = false;
          hilog.info(RD_DOMAIN, RD_TAG, 'drop-file received');
          this.handleFileDrop(event);
        }, { disableDataPrefetch: !this.isDesktopDevice || this.breakpoint !== 'xl' })
      }

      if (this.connected && this.shouldShowRustDeskSessionTopBar()) {
        RemoteSessionTopBar({
          layout: remoteTopBarLayout(this.isDesktopDevice, this.breakpoint),
          privacyMode: this.rustdeskPrivacyMode,
          audioEnabled: this.rustdeskAudioEnabled,
          clipboardEnabled: this.rustdeskClipboardEnabled,
          filePasteEnabled: this.rustdeskFilePasteEnabled,
          viewScaleMode: this.remoteDisplayScaleMode,
          imageQuality: this.rustdeskImageQuality,
          codec: this.rustdeskCodec,
          showLocalCursor: this.rustdeskShowLocalCursor,
          browseMode: this.rustdeskBrowseMode,
          relativeMouseMode: this.rustdeskRelativeMouseMode,
          reverseWheel: this.rustdeskReverseWheel,
          swapMouseButtons: this.rustdeskSwapMouseButtons,
          touchpadSpeed: this.rustdeskTouchpadSpeed,
          keyboardOpen: this.keyboardOpen,
          capabilities: this.currentSessionCapabilities(),
          actions: this.rustDeskTopBarActions()
        })
      }

      if (this.showRustDeskDisplayResolutionMenu) {
        this.rustDeskDisplayResolutionMenu()
      }

      if (this.shouldShowActiveDiagnostics()) {
        RustDeskDiagnosticsHud({
          diagnostics: this.rustDeskDiagnostics,
          localResources: this.localResourceStats,
          protocolLabel: this.isVncSession() ? 'VNC' : 'RustDesk',
          proEnabled: this.shouldShowAdvancedDiagnostics(),
          expanded: this.rustDeskDiagnosticsDockExpanded,
          attachSide: this.rustDeskDiagnosticsDockSide,
          handleX: this.rustDeskDiagnosticsDockHandleX(),
          panelX: this.rustDeskDiagnosticsDockPanelX(),
          panelY: this.rustDeskDiagnosticsDockY,
          onToggle: (): void => {
            this.toggleRustDeskDiagnosticsDock();
          },
          onPositionChange: (x: number, y: number, fromPanel: boolean): void => {
            this.snapRustDeskDiagnosticsDockToEdge(x, y, fromPanel);
          }
        })
      }

      // T-171: 侧边吸附悬浮胶囊
      if (this.connected && this.handleVisible) {
        RemoteModifierHandle({
          handleX: this.handleX,
          handleY: this.handleY,
          handleSide: this.handleSide,
          panelVisible: this.modifierPanelVisible,
          ctrlLocked: this.isModifierLatched('ctrl'),
          altLocked: this.isModifierLatched('alt'),
          shiftLocked: this.isModifierLatched('shift'),
          winLocked: this.isModifierLatched('win'),
          fnLayer: this.fnLayer,
          onTogglePanel: (): void => {
            this.toggleModifierPanel();
            hilog.info(RD_DOMAIN, RD_TAG,
              'modifier panel ' + (this.modifierPanelVisible ? 'open' : 'close'));
          },
          onLongPress: (): void => {
            this.toggleShortcutPanel();
            hilog.info(RD_DOMAIN, RD_TAG,
              'shortcut panel ' + (this.shortcutPanelVisible ? 'open' : 'close'));
          },
          onPositionChange: (x: number, y: number): void => {
            this.snapHandleToEdge(x, y);
          }
        })
      }

      // T-171: 修饰键展开面板
      if (this.connected && this.modifierPanelMounted) {
        RemoteModifierPanel({
          visible: this.modifierPanelVisible,
          shortcutVisible: this.shortcutPanelVisible,
          attachSide: this.handleSide,
          ctrlLatch: this.ctrlLatch,
          altLatch: this.altLatch,
          shiftLatch: this.shiftLatch,
          winLatch: this.winLatch,
          fnLayer: this.fnLayer,
          panelX: this.modifierPanelX,
          panelY: this.modifierPanelY,
          shortcutX: this.shortcutPanelX,
          shortcutY: this.shortcutPanelY,
          onClose: (): void => {
            this.closeModifierPanel();
          },
          onCloseShortcut: (): void => {
            this.closeShortcutPanel();
          },
          onToggleModifier: (mod: string): void => {
            this.toggleModifierLatch(mod);
          },
          onLockModifier: (mod: string): void => {
            this.lockModifierLatch(mod);
          },
          onToggleFnLayer: (): void => {
            this.fnLayer = !this.fnLayer;
            this.clampModifierPanelsIntoView();
          },
          onKeyTap: (keyCode: number, label: string): void => {
            // 有活动修饰键 → 组合键; 无修饰键 → 单键
            if (this.isModifierLatched('ctrl') || this.isModifierLatched('alt') ||
              this.isModifierLatched('shift') || this.isModifierLatched('win')) {
              this.sendModifiedKey(keyCode, label);
            } else {
              this.sendVirtualKeyTap(keyCode, label);
            }
          },
          onShortcutTap: (keyCodes: number[], label: string): void => {
            // Ctrl+Alt+Del 特殊处理
            if (keyCodes.length === 3 && keyCodes[0] === KEYCODE_CTRL_LEFT &&
              keyCodes[1] === KEYCODE_ALT_LEFT && keyCodes[2] === KEYCODE_FORWARD_DEL) {
              this.sendCtrlAltDel();
            } else {
              this.sendShortcutSequence(keyCodes, label);
            }
          },
          onPanelPositionChange: (x: number, y: number): void => {
            this.moveModifierPanel(x, y);
          },
          onShortcutPositionChange: (x: number, y: number): void => {
            this.moveShortcutPanel(x, y);
          }
        })
      }

      // 三指控制面板改用 bindSheet — 弹到屏幕中央

      RemoteCursorOverlay({ cursor: this.remoteCursorOverlayState })

      // PC 模式: 拖拽文件悬停视觉反馈
      if (this.connected && this.dropHoverActive && this.isDesktopDevice && this.breakpoint === 'xl') {
        Stack() {
          Column() {
            SymbolGlyph($r('sys.symbol.doc'))
              .fontSize(48)
              .fontColor([this.accentColor])
            Text('释放文件以传输到远程桌面')
              .fontSize(16)
              .fontColor('#FFFFFF')
              .margin({ top: 12 })
            Text(this.pendingHost ? (this.pendingHost.protocol === 'rdp' ? '→ RDP 文件传输当前不可用' : '→ RustDesk 桌面') : '')
              .fontSize(12)
              .fontColor('rgba(255,255,255,0.55)')
              .margin({ top: 4 })
          }
          .width('100%').height('100%')
          .justifyContent(FlexAlign.Center)
          .alignItems(HorizontalAlign.Center)
        }
        .width('100%').height('100%')
        .backgroundColor('rgba(0,125,255,0.12)')
        .border({ width: 3, color: this.accentColor, style: BorderStyle.Dashed })
        .borderRadius(0)
        .hitTestBehavior(HitTestMode.None)
        .animation({ duration: 180, curve: Curve.EaseOut })
      }

      if (this.connected && this.fileTransferStatus.length > 0) {
        Column() {
          Row() {
            if (this.fileTransferBusy) {
              LoadingProgress()
                .width(20)
                .height(20)
                .color(this.accentColor)
                .margin({ right: 8 })
            } else {
              Text(this.fileTransferProgress >= 0 ? '完成' : '失败')
                .fontSize(12)
                .fontColor(this.fileTransferProgress >= 0 ? this.accentColor : this.pal().danger)
                .margin({ right: 8 })
            }
            Text(this.fileTransferStatus)
              .fontSize(12)
              .fontColor('#FFFFFF')
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)
          if (this.fileTransferProgress >= 0) {
            Progress({
              value: Math.floor(this.fileTransferProgress * 100),
              total: 100,
              type: ProgressType.Linear
            })
              .width('100%')
              .height(4)
              .color(this.accentColor)
              .backgroundColor('rgba(255,255,255,0.22)')
              .margin({ top: 8 })
          }
        }
        .width('88%')
        .padding({ left: 14, right: 14, top: 12, bottom: 12 })
        .backgroundColor('rgba(20,20,24,0.82)')
        .borderRadius(12)
        .position({ x: '6%', y: '72%' })
        .hitTestBehavior(HitTestMode.None)
      }

      // PC/键鼠模式不再显示底部工具栏, 固定左上角断开按钮必须覆盖所有 PC 窗口宽度。
      if (this.connected && this.isDesktopDevice &&
        (!this.pendingHost || this.pendingHost.protocol !== 'rustdesk')) {
        Button($r('app.string.btn_disconnect'))
          .height(28)
          .fontSize(11)
          .padding({ left: 10, right: 10 })
          .backgroundColor('rgba(20,20,24,0.58)')
          .fontColor('#FFFFFF')
          .borderRadius(8)
          .position({ x: 10, y: 10 })
          .shadow({ radius: 4, color: 'rgba(0,0,0,0.18)', offsetY: 1 })
          .onClick(() => {
            this.disconnectAndCleanup('pc-disconnect-button');
            this.goBack();
          })
      }

      Column().width('100%').height('100%').hitTestBehavior(HitTestMode.None)
        .bindSheet($$this.showRdpSessionErrorSheet, this.rdpSessionErrorSheet(), {
          height: SheetSize.FIT_CONTENT,
          preferType: rdpSessionErrorSheetPrefersLandscapeCenter(true) ? SheetType.CENTER :
            (this.breakpoint === 'sm' ? SheetType.BOTTOM : SheetType.CENTER),
          dragBar: false,
          backgroundColor: this.pal().sheetBg,
          blurStyle: BlurStyle.NONE,
          showClose: false,
          maskColor: 'rgba(0,0,0,0.48)',
          onWillDismiss: (action: DismissSheetAction): void => {
            this.rdpSessionErrorBackPending = true;
            action.dismiss();
          },
          onDisappear: (): void => { this.handleRdpSessionErrorSheetDisappear(); }
        })

      // Pro RustDesk 鉴权必须使用纵向底部 bindSheet；不能在横屏远程画布上用全屏 overlay。
      Column().width('100%').height('100%').hitTestBehavior(HitTestMode.None)
        .bindSheet($$this.showRustDeskAuthSheet, this.rustDeskAuthChoiceBuilder(), {
          height: SheetSize.FIT_CONTENT,
          preferType: SheetType.BOTTOM,
          dragBar: true,
          backgroundColor: this.pal().sheetBg,
          blurStyle: BlurStyle.NONE,
          showClose: false,
          maskColor: 'rgba(0,0,0,0.58)',
          onWillDismiss: (action: DismissSheetAction): void => {
            this.handleRustDeskAuthSheetDismiss(action);
          },
          onDisappear: (): void => { this.handleRustDeskAuthSheetDisappear(); }
        })

      Column().width('100%').height('100%').hitTestBehavior(HitTestMode.None)
        .bindSheet($$this.showRustDeskTwoFactorSheet, this.rustDeskTwoFactorSheetBuilder(), {
          height: SheetSize.FIT_CONTENT,
          preferType: SheetType.BOTTOM,
          dragBar: true,
          backgroundColor: this.pal().sheetBg,
          blurStyle: BlurStyle.NONE,
          showClose: false,
          maskColor: 'rgba(0,0,0,0.58)',
          onWillDismiss: (action: DismissSheetAction): void => {
            this.handleRustDeskTwoFactorSheetDismiss(action);
          }
        })

      Column().width('100%').height('100%').hitTestBehavior(HitTestMode.None)
        .bindSheet($$this.showVncPasswordSheet, this.vncPasswordSheetBuilder(), {
          height: SheetSize.FIT_CONTENT,
          preferType: this.breakpoint === 'sm' ? SheetType.BOTTOM : SheetType.CENTER,
          dragBar: true,
          backgroundColor: this.pal().sheetBg,
          blurStyle: BlurStyle.NONE,
          showClose: false,
          maskColor: 'rgba(0,0,0,0.58)',
          onWillDismiss: (action: DismissSheetAction): void => {
            this.handleVncPasswordSheetDismiss(action);
          },
          onDisappear: (): void => { this.handleVncPasswordSheetDisappear(); }
        })


      // 持久影子 TextArea：保留系统输入法的空格滑动/光标拖拽状态，内容只在本地使用。
      TextArea({ text: this.keyboardText, controller: this.keyboardController })
        .id('RemoteDesktopKeyboard')
        .width(1).height(1)
        .opacity(0.01)
        .fontColor('#00000000')
        .backgroundColor('#00000000')
        .caretColor('#00000000')
        .border({ width: 0 })
        // 输入法候选框以 TextArea 为锚点；放在远程画布中心，避免候选框
        // 固定出现在左上角覆盖顶栏。TextArea 本身仍不可见。
        .position({ x: this.remoteImeAnchorX(), y: this.remoteImeAnchorY() })
        .hitTestBehavior(HitTestMode.Transparent)
        .focusable(true)
        .defaultFocus(false)
        .focusOnTouch(true)
        .enableKeyboardOnFocus(this.keyboardOpen)
        .enablePreviewText(REMOTE_IME_PREVIEW_ENABLED)
        .selectionMenuHidden(true)
        .enterKeyType(EnterKeyType.Send)
        .onKeyPreIme(this.handleKeyboardProxyPreIme)
        .keyboardShortcut(' ', [ModifierKey.CTRL], (): void => {
          this.sendMacInputSourceShortcut('keyboard-shortcut');
        })
        // 输入法未消费的字符事件仍通过现有后置回调兜底；功能键已在 onKeyPreIme 拦截。
        .onKeyEvent(this.handleXComponentKey)
        .onFocus((): void => {
          hilog.info(RD_DOMAIN, RD_TAG, 'remote-input-focus target=keyboard-proxy');
        })
        .onBlur((): void => {
          this.handleRemoteKeyboardFocusLost('keyboard-proxy');
        })
        .onWillInsert((info: InsertValue): boolean => {
          return this.handleKeyboardWillInsert(info);
        })
        .onDidInsert((info: InsertValue): void => {
          this.handleKeyboardDidInsert(info);
        })
        .onWillDelete((info: DeleteValue): boolean => {
          return this.handleKeyboardWillDelete(info);
        })
        .onDidDelete((info: DeleteValue): void => {
          this.handleKeyboardDidDelete(info);
        })
        .onTextSelectionChange((start: number, end: number): void => {
          this.handleKeyboardSelectionChange(start, end);
        })
        .onEditChange((isEditing: boolean): void => {
          hilog.info(RD_DOMAIN, RD_TAG, 'kbd-editing=' + (isEditing ? 'true' : 'false') +
            ' open=' + (this.keyboardOpen ? 'true' : 'false') +
            ' proxy=' + (this.hardwareKeyboardProxyActive ? 'true' : 'false'));
          if (isEditing) {
            this.keyboardImeEditingObserved = true;
            return;
          }
          if (shouldCloseRemoteImeSessionOnEditChange(
            this.keyboardOpen, isEditing, this.keyboardImeEditingObserved,
            this.keyboardProgrammaticSelection)) {
            if (this.keyboardSubmitRefocusPending || this.keepKeyboardAfterSheetClose) {
              hilog.info(RD_DOMAIN, RD_TAG, 'kbd-editing-close ignored: refocus pending');
              return;
            }
            this.markKeyboardClosed('ime');
          }
        })
        .onChange((value: string, previewText?: PreviewText) => {
          this.handleKeyboardTextChange(value, previewText);
        })
        .onSubmit((enterKey: EnterKeyType, event: SubmitEvent): void => {
          hilog.info(RD_DOMAIN, RD_TAG, 'kbd-submit enterKey=' + enterKey.toString());
          this.keyboardSubmitRefocusPending = true;
          event.keepEditableState();
          this.keyboardCommandQueue.enqueueKeyTaps(KEYCODE_ENTER, 1,
            this.keyboardImeGeneration, 'submit');
          this.scheduleRemoteImeCommandPump();
          setTimeout((): void => {
            if (this.keyboardOpen) {
              try {
                focusControl.requestFocus('RemoteDesktopKeyboard');
              } catch (err) {
                hilog.warn(RD_DOMAIN, RD_TAG, 'kbd-refocus failed: ' + JSON.stringify(err));
              }
            }
            this.keyboardSubmitRefocusPending = false;
          }, 30);
        })
    }
    .width('100%').height('100%')
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    .overlay(this.passphraseOverlay(), { align: Alignment.Top })
    .bindSheet($$this.showControlPanel, this.controlPanelBuilder(), {
      preferType: SheetType.CENTER,
      backgroundColor: this.pal().sheetBg,
      onDisappear: (): void => { this.handleControlPanelDisappear(); }
    })
  }

  @Builder rdpSessionErrorSheet() {
    Column() {
      SymbolGlyph($r('sys.symbol.exclamationmark_triangle'))
        .fontSize(56)
        .fontColor(['#FFD21A'])
        .margin({ top: 8, bottom: 18 })
      Text(this.rdpSessionErrorTitle)
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.pal().text)
        .textAlign(TextAlign.Center)
        .width('100%')
      Text(this.rdpSessionErrorMessage)
        .fontSize(15)
        .fontColor(this.pal().text2)
        .lineHeight(22)
        .textAlign(TextAlign.Center)
        .width('100%')
        .margin({ top: 14 })
      Text('错误代码: ' + this.rdpSessionErrorCode)
        .fontSize(13)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.pal().text3)
        .textAlign(TextAlign.Center)
        .width('100%')
        .margin({ top: 12 })
      Button('断开')
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .height(48)
        .width('100%')
        .backgroundColor(this.accentColor)
        .fontColor('#FFFFFF')
        .borderRadius(14)
        .margin({ top: 26 })
        .onClick(() => { this.closeRdpSessionErrorSheet(); })
    }
    .width('100%')
    .constraintSize({ maxWidth: 520 })
    .padding({ left: 24, right: 24, top: 18, bottom: 28 })
    .backgroundColor(this.pal().sheetBg)
    .backgroundBlurStyle(BlurStyle.Regular)
    .borderRadius(rdpSessionErrorSheetPrefersLandscapeCenter(true) ? 24 :
      (this.breakpoint === 'sm' ? { topLeft: 22, topRight: 22, bottomLeft: 0, bottomRight: 0 } : 24))
    .border({ width: 0.5, color: this.pal().cardBorder, style: BorderStyle.Solid })
    .shadow({ radius: this.breakpoint === 'sm' ? 0 : 24,
      color: this.breakpoint === 'sm' ? 'rgba(0,0,0,0)' : 'rgba(0,0,0,0.18)', offsetY: 6 })
  }

  // Passphrase overlay (inside root Stack, outside bindSheet chain)
  @Builder passphraseOverlay() {
    Column() {
      if (this.showPassphraseSheet) {
        Column().width('100%').layoutWeight(1)
          .onClick(() => {
            this.showPassphraseSheet = false;
            if (this.rdpPassphraseResolve) { this.rdpPassphraseResolve(''); }
          })
        Column() { this.rdPassphraseBuilder() }
      }
    }
    .width('100%').height('100%')
    .position({ x: 0, y: 0 })
    .hitTestBehavior(this.showPassphraseSheet ? HitTestMode.Default : HitTestMode.None)
  }

  @Builder
  keyboardEditBarBuilder() {
    Row() {
      Button('Left')
        .height(36).layoutWeight(1).fontSize(12)
        .backgroundColor('rgba(20,20,24,0.86)').fontColor('#FFFFFF')
        .borderRadius(10)
        .onClick(() => { this.sendRemoteKeyTap(KEYCODE_DPAD_LEFT, 'Left'); })
      Button('Right')
        .height(36).layoutWeight(1).fontSize(12)
        .backgroundColor('rgba(20,20,24,0.86)').fontColor('#FFFFFF')
        .borderRadius(10)
        .margin({ left: 8 })
        .onClick(() => { this.sendRemoteKeyTap(KEYCODE_DPAD_RIGHT, 'Right'); })
      Button('Bksp')
        .height(36).layoutWeight(1).fontSize(12)
        .backgroundColor('rgba(20,20,24,0.86)').fontColor('#FFFFFF')
        .borderRadius(10)
        .margin({ left: 8 })
        .onClick(() => { this.sendRemoteKeyTap(KEYCODE_DEL, 'Backspace'); })
      Button('Del')
        .height(36).layoutWeight(1).fontSize(12)
        .backgroundColor('rgba(20,20,24,0.86)').fontColor('#FFFFFF')
        .borderRadius(10)
        .margin({ left: 8 })
        .onClick(() => { this.sendRemoteKeyTap(KEYCODE_FORWARD_DEL, 'Delete'); })
      Button('Enter')
        .height(36).layoutWeight(1).fontSize(12)
        .backgroundColor('rgba(42,120,58,0.92)').fontColor('#FFFFFF')
        .borderRadius(10)
        .margin({ left: 8 })
        .onClick(() => { this.sendKeyboardEnter('editbar'); })
    }
    .width('92%')
    .padding({ left: 8, right: 8, top: 6, bottom: 6 })
    .backgroundColor('rgba(0,0,0,0.22)')
    .borderRadius(14)
    .position({ x: '4%', y: '84%' })
  }

  @Builder controlPanelBuilder() {
    Column() {
      Text('控制面板')
        .fontSize(18).fontWeight(FontWeight.Medium)
        .fontColor(this.pal().text)
        .margin({ top: 8, bottom: 20 })
      if (this.isVncSession() && this.isVncViewOnlySession()) {
        Row() {
          SymbolGlyph($r('sys.symbol.info_circle'))
            .fontSize(18).fontColor([this.pal().text3]).margin({ right: 8 })
          Text('VNC 只读连接，键盘、鼠标和剪贴板发送已禁用')
            .fontSize(12).fontColor(this.pal().text3).layoutWeight(1)
        }
        .width('100%').padding({ left: 24, right: 24, bottom: 14 })
      }
      // 键盘按钮
      Row() {
        SymbolGlyph($r('sys.symbol.keyboard'))
          .fontSize(22).fontColor([Color.White])
          .margin({ right: 10 })
        Text(this.keyboardOpen ? '关闭键盘' : '虚拟键盘')
          .fontSize(16).fontColor('#FFFFFF')
      }
      .width('100%').height(52)
      .justifyContent(FlexAlign.Center)
      .backgroundColor(this.pal().primary)
      .borderRadius(14)
      .margin({ bottom: 12, left: 24, right: 24 })
      .onClick(() => {
        if (this.keyboardOpen) {
          this.keepKeyboardAfterSheetClose = false;
          this.showControlPanel = false;
          this.dismissKeyboard();
        } else {
          this.keepKeyboardAfterSheetClose = true;
          this.showControlPanel = false;
        }
      })
      // T-171: 组合键入口
      Row() {
        Text('⌨')
          .fontSize(22).fontColor('#FFFFFF')
          .margin({ right: 10 })
        Text('组合键')
          .fontSize(16).fontColor('#FFFFFF')
      }
      .width('100%').height(52)
      .justifyContent(FlexAlign.Center)
      .backgroundColor(this.pal().primary)
      .borderRadius(14)
      .margin({ bottom: 12, left: 24, right: 24 })
      .onClick(() => {
        this.showControlPanel = false;
        if (!this.handleVisible) {
          this.initHandlePosition();
          this.handleVisible = true;
        }
        this.ensureModifierPanelPositions();
        // 短暂延迟后展开面板, 避免和 sheet 关闭动画重叠
        setTimeout((): void => {
          this.openModifierPanel();
        }, 200);
      })
      if (!this.isVncSession()) {
        // 文件传输按钮
        Row() {
          SymbolGlyph($r('sys.symbol.doc'))
            .fontSize(22).fontColor([this.pal().primary])
            .margin({ right: 10 })
          Text('发送文件到桌面')
            .fontSize(16).fontColor(this.pal().text)
        }
        .width('100%').height(52)
        .justifyContent(FlexAlign.Center)
        .backgroundColor(this.pal().card)
        .borderRadius(14)
        .border({ width: 1, color: this.pal().cardBorder })
        .margin({ bottom: 20, left: 24, right: 24 })
        .enabled(!this.fileTransferBusy && this.connected)
        .onClick(() => {
          this.showControlPanel = false;
          this.pickAndSendFile();
        })
      }
    }
    .width('100%')
    .padding({ top: 8, bottom: 24 })
    .backgroundColor(this.pal().bg)
  }
}
