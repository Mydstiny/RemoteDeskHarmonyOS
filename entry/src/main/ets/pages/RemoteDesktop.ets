/**
 * RemoteDesktop.ets v4 — 全屏远程桌面 + XComponent 生命周期 + 输入转发 + 错误诊断
 */
import { display, promptAction, router, window } from '@kit.ArkUI';
import { inputDevice, pointer } from '@kit.InputKit';
import { abilityAccessCtrl, common } from '@kit.AbilityKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { HostSyncService } from '../services/HostSyncService';
import { ExtensionLoader } from '../services/ExtensionLoader';
import { KeyVaultService } from '../services/KeyVaultService';
import { RemoteHost, LockType } from '../model/RemoteHost';
import { RustDeskRelayConfig } from '../model/RustDeskRelayConfig';
import { RdpCredential } from '../model/RdpCredential';
import { AppConfig, Palette, buildDark, buildLight } from '../common/Theme';
import { showLockGate, lockGateErrorMessage } from '../components/LockGate';
import { RemoteModifierHandle } from '../components/RemoteModifierHandle';
import { RemoteModifierPanel } from '../components/RemoteModifierPanel';
import { RemoteSessionTopBar, RemoteSessionTopBarActions } from '../components/RemoteSessionTopBar';
// PassphraseDialog replaced with inline bindSheet (RemoteDesktop is @Entry, no bindSheet limit)
import { RemoteKeyDispatcher } from '../services/RemoteKeyDispatcher';
import { ClipboardBridgeService } from '../services/ClipboardBridgeService';
import { clipboardSyncEnabledForProtocol } from '../services/ClipboardSyncPolicy';
import { FileTransferLiveTaskService } from '../services/FileTransferLiveTaskService';
import { RemoteSessionBackgroundTaskService, RemoteSessionBgInfo } from '../services/RemoteSessionBackgroundTaskService';
import { RemoteSessionLiveViewService, LiveViewConnectionInfo } from '../services/RemoteSessionLiveViewService';
import { ActiveRemoteSessionRegistry, ActiveRemoteSessionRecord } from '../services/ActiveRemoteSessionRegistry';
import { NativeSessionHandles, ProductionNativeHandleAdapter } from '../services/NativeSessionHandles';
import {
  decideRemoteDesktopBackgroundAction,
  RemoteDesktopBackgroundAction
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
  shouldRenderTouchPointerIndicator,
  shouldUseSystemMousePointer
} from '../services/RemotePointerModePolicy';
import {
  remoteInputBlockedReason,
  shouldBlockRemoteInputForBrowseMode
} from '../services/RemoteInputGuardPolicy';
import { RemoteProtocol } from '../services/RemoteSessionState';
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
import { RdpRenderStats, SessionConfig, SessionTransferStatus } from '../types/rdpnapi';
import {
  normalizeRustDeskPort,
  RUSTDESK_PEER_TCP_PORT,
  rustDeskAuthModeForConnection
} from '../services/RustDeskHostConfigPolicy';
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
const KEYCODE_META_LEFT = 2076;
const KEYCODE_META_RIGHT = 2077;
const KEYCODE_MOVE_HOME = 2081;
const KEYCODE_MOVE_END = 2082;
// T-172 P0-3: Harmony keyCode namespace (统一虚拟面板+实体键盘)
const KEY_A = 2017;
const KEY_C = 2019;
const KEY_D = 2020;
const KEY_E = 2021;
const KEY_R = 2034;
const KEY_V = 2038;
const KEY_W = 2039;
const KEY_X = 2040;
const KEY_F1 = 2090;
const KEY_F4 = 2093;

interface RemoteDesktopSurfaceListener {
  onSurfaceCreated(surfaceId: string): void;
  onSurfaceDestroyed(surfaceId: string): void;
}

interface RdpCredentialParts {
  username: string;
  domain: string;
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

type ModifierLatch = 'off' | 'once' | 'locked';
type RustDeskAuthChoice = 'password' | 'request_approval';
type RustDeskAuthDismissReason = 'none' | 'confirm' | 'cancel';

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
  @StorageLink('rustdeskControlMode') rustdeskControlMode: number = 0; // 0=touchpad, 1=direct touch, 2=keyboard/mouse
  @StorageLink('rustdeskImageQuality') rustdeskImageQuality: number = 1;
  @StorageLink('rustdeskCodec') rustdeskCodec: number = 0;
  @StorageLink('rustdeskPrivacyMode') rustdeskPrivacyMode: boolean = false;
  @StorageLink('rustdeskAudioEnabled') rustdeskAudioEnabled: boolean = true;
  @StorageLink('rustdeskClipboardEnabled') rustdeskClipboardEnabled: boolean = true;
  @StorageLink('rustdeskFilePasteEnabled') rustdeskFilePasteEnabled: boolean = true;
  @StorageLink('rustdeskViewScaleMode') rustdeskViewScaleMode: string = 'fit';
  @StorageLink('rustdeskShowLocalCursor') rustdeskShowLocalCursor: boolean = true;
  @StorageLink('rustdeskBrowseMode') rustdeskBrowseMode: boolean = false;
  @StorageLink('rustdeskRelativeMouseMode') rustdeskRelativeMouseMode: boolean = false;
  @StorageLink('rustdeskReverseWheel') rustdeskReverseWheel: boolean = false;
  @StorageLink('rustdeskSwapMouseButtons') rustdeskSwapMouseButtons: boolean = false;
  @StorageLink('rustdeskTouchpadSpeed') rustdeskTouchpadSpeed: number = 1.0;
  @StorageLink('rdpControlMode') rdpControlMode: number = 0; // 0=touchpad, 1=direct touch, 2=keyboard/mouse
  @StorageLink('rdpDriveEnabled') rdpDriveEnabled: boolean = true;
  @StorageLink('rdpDriveName') rdpDriveName: string = 'RemoteDesktop';
  @StorageLink('remoteDesktopBgFlag') @Watch('onRemoteDesktopBgFlagChange') remoteDesktopBgFlag: boolean = false;
  @State connected: boolean = false;
  @State connecting: boolean = true;
  @State connectionError: string = '';
  @State connectionErrorDetail: string = '';
  @State showRdpSessionErrorSheet: boolean = false;
  @State rdpSessionErrorTitle: string = '你的会话已断开';
  @State rdpSessionErrorMessage: string = '';
  @State rdpSessionErrorCode: string = '';
  @State showRustDeskAuthSheet: boolean = false;
  @State rustDeskAuthChoice: RustDeskAuthChoice = 'password';
  @State rustDeskAuthPasswordInput: string = '';
  @State rustDeskAuthPasswordShow: boolean = false;
  @State rustDeskAuthRememberPassword: boolean = true;
  @State rustDeskAuthError: string = '';
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
  private nativeHandles: NativeSessionHandles =
    new NativeSessionHandles(new ProductionNativeHandleAdapter((): ExtensionLoader => this.loader));
  private clipboardBridge: ClipboardBridgeService | null = null;
  private keyDispatcher: RemoteKeyDispatcher = new RemoteKeyDispatcher();
  private hostId: string = '';
  private xcId: string = 'rdpSurface';
  // R0: session/renderer/decoder handle 追踪
  private sessionId: number = -1;
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
  private rustDeskAuthDismissReason: RustDeskAuthDismissReason = 'none';
  private rustDeskSessionAuthChoice: RustDeskAuthChoice = 'password';
  private rustDeskSessionPassword: string = '';
  private rustDeskSessionRememberPassword: boolean = false;
  private remoteNavigationHidden: boolean = false;
  private backgroundAudioPollTimer: number = -1;
  private backgroundSessionInfo: RemoteSessionBgInfo | null = null;
  private backgroundHasAudio: boolean = false;
  private backgroundHasVideo: boolean = false;
  private restoreFrameRefreshTimers: number[] = [];
  private xComponentController: RemoteDesktopXComponentController = new RemoteDesktopXComponentController();
  private surfaceWidth: number = 0;
  private surfaceHeight: number = 0;
  private renderWidthPx: number = 0;
  private renderHeightPx: number = 0;
  private remoteWidth: number = 1920;
  private remoteHeight: number = 1080;
  private remoteCursorX: number = 960;
  private remoteCursorY: number = 540;
  private remoteCursorReady: boolean = false;
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
  private pendingMouseMoveX: number = 0;
  private pendingMouseMoveY: number = 0;
  private pendingMouseMoveValid: boolean = false;
  private mouseMoveTimer: number = -1;
  private physicalMouseDownButton: number = -1;
  private inputDeviceListenerRegistered: boolean = false;
  private inputDevicePromptVisible: boolean = false;
  private externalInputPromptedThisSession: boolean = false;
  private inputDeviceBaselineIds: Array<number> = [];
  private fileTransferHideTimer: number = -1;
  private rdpClipboardBatchSequence: number = 0;
  private rdpRenderWatchdogTimer: number = -1;
  private rdpNativeStateMonitorTimer: number = -1;
  private lastBrowseModeBlockedToastMs: number = 0;

  private inputDeviceListener: Callback<inputDevice.DeviceListener> =
    (data: inputDevice.DeviceListener): void => {
      if (data.type !== 'add') { return; }
      this.handleInputDeviceAdded(data.deviceId);
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
    if (host.protocol !== 'rdp' && host.protocol !== 'rustdesk') { return; }
    this.externalInputPromptedThisSession = true;
    this.inputDevicePromptVisible = true;
    const name: string = deviceName && deviceName.length > 0 ? deviceName : '键盘/鼠标';
    const protocolLabel: string = host.protocol === 'rdp' ? 'Windows RDP' : 'RustDesk';
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
        } else {
          this.rustdeskControlMode = 2;
          AppStorage.setOrCreate('rustdeskControlMode', 2);
        }
        this.hideTouchIndicator();
        promptAction.showToast({ message: '已切换为键鼠模式', duration: 1500 });
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
    return false;
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

  private isProRustDeskHost(host: RemoteHost | null): boolean {
    return host !== null && host.protocol === 'rustdesk' &&
      host.sourceType === 'rustdesk_pro' && host.rustdeskProManaged;
  }

  /**
   * Pro 地址簿主机每次新建会话都显式选择认证方式；后台恢复不经过这里，
   * 因为恢复的是已有 RustDesk 会话而不是重新认证。
   */
  private openRustDeskAuthSheet(message: string = ''): void {
    const host: RemoteHost | null = this.pendingHost;
    if (host === null || host.protocol !== 'rustdesk' || host.sourceType !== 'rustdesk_pro' ||
      !host.rustdeskProManaged) {
      this.tryStartConnect();
      return;
    }
    this.rustDeskAuthChoice = host.rustdeskDirectEnabled ? 'password' :
      (host.rustdeskAuthMode === 'request_approval' ? 'request_approval' : 'password');
    this.rustDeskAuthPasswordInput = host.password;
    this.rustDeskAuthPasswordShow = false;
    this.rustDeskAuthRememberPassword = true;
    this.rustDeskAuthError = message;
    this.rustDeskAuthDismissReason = 'none';
    this.showRustDeskAuthSheet = true;
    setTimeout((): void => { this.focusRustDeskAuthPassword(); }, 120);
  }

  private cancelRustDeskAuthChoice(): void {
    this.rustDeskAuthDismissReason = 'cancel';
    this.showRustDeskAuthSheet = false;
    this.rustDeskAuthError = '';
    this.connectStarted = false;
    this.connecting = false;
    this.connectionError = '连接已取消';
    this.connectionErrorDetail = '未建立 RustDesk 会话';
    this.goBack();
  }

  private confirmRustDeskAuthChoice(): void {
    const host: RemoteHost | null = this.pendingHost;
    if (host === null || host.protocol !== 'rustdesk' || host.sourceType !== 'rustdesk_pro' ||
      !host.rustdeskProManaged) {
      this.rustDeskAuthDismissReason = 'confirm';
      this.showRustDeskAuthSheet = false;
      this.tryStartConnect();
      return;
    }
    if (this.rustDeskAuthChoice === 'request_approval' && host.rustdeskDirectEnabled) {
      this.rustDeskAuthError = '当前主机使用直连模式，不能请求远端批准，请改用设备密码。';
      return;
    }

    const selected = RemoteHost.fromJSON(host.toJSON());
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
    this.rustDeskSessionAuthChoice = this.rustDeskAuthChoice;
    this.pendingHost = selected;
    this.rustDeskAuthDismissReason = 'confirm';
    this.showRustDeskAuthSheet = false;
    this.rustDeskAuthError = '';
    this.connectionError = '';
    this.connectionErrorDetail = '';
    this.connectStarted = false;
    this.connecting = true;
    this.tryStartConnect();
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
    this.cancelRustDeskAuthChoice();
    action.dismiss();
  }

  private handleRustDeskAuthSheetDisappear(): void {
    const reason: RustDeskAuthDismissReason = this.rustDeskAuthDismissReason;
    this.rustDeskAuthDismissReason = 'none';
    // 系统下滑/返回键关闭时必须视为取消，不能让连接绕过授权选择。
    if (reason === 'none') {
      this.cancelRustDeskAuthChoice();
    }
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
    return value.indexOf('wrong password') >= 0 ||
      value.indexOf('empty password') >= 0 ||
      value.indexOf('no password access') >= 0 ||
      value.indexOf('remote approval timed out') >= 0 ||
      value.indexOf('approval') >= 0;
  }

  private currentProtocolName(): string {
    const host: RemoteHost | null = this.pendingHost;
    return host === null ? '' : host.protocol;
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
      rustDeskTransferConfirmed: this.connected && this.currentProtocolName() === 'rustdesk'
    });
  }

  private shouldShowTouchIndicator(): boolean {
    return shouldRenderTouchPointerIndicator(this.touchIndicatorVisible,
      shouldUseSystemMousePointer(this.isKeyboardMouseControlMode()));
  }

  private setRemoteSurfacePointerStyle(useSystemPointer: boolean): void {
    try {
      const cursorController = this.getUIContext().getCursorController();
      if (useSystemPointer) {
        cursorController.setCursor(pointer.PointerStyle.DEFAULT);
      } else {
        cursorController.restoreDefault();
      }
    } catch (err) {
      hilog.warn(RD_DOMAIN, RD_TAG, 'remote pointer style update failed: ' + JSON.stringify(err));
    }
  }

  private handleRemoteSurfaceHover = (hovered: boolean): void => {
    this.setRemoteSurfacePointerStyle(hovered && shouldUseSystemMousePointer(this.isKeyboardMouseControlMode()));
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

  private setRustDeskViewScaleMode(mode: string): void {
    const next: string = mode === 'original' || mode === 'custom' ? mode : 'fit';
    this.rustdeskViewScaleMode = next;
    this.persistSessionPref('rustdeskViewScaleMode', next);
    promptAction.showToast({ message: '显示缩放已切换为 ' + this.rustDeskViewScaleLabel(next), duration: 1400 });
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

  private setRustDeskReverseWheel(on: boolean): void {
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
        this.openKeyboard();
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
        this.setRustDeskViewScaleMode(mode);
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
        this.setRustDeskReverseWheel(on);
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

  private ensureModifierPanelPositions(): void {
    if (this.modifierPanelPositionReady) {
      this.clampModifierPanelsIntoView();
      return;
    }
    const screenW: number = this.surfaceWidth > 0 ? this.surfaceWidth : 360;
    const panelW: number = this.modifierPanelWidth();
    const defaultX: number = this.handleSide === 'right' ? Math.max(8, screenW - panelW - 8) : 8;
    const defaultY: number = this.clampModifierPanelY(this.handleY - 20, this.fnLayer ? 300 : 136);
    this.modifierPanelX = this.clampModifierPanelX(defaultX);
    this.modifierPanelY = defaultY;
    this.shortcutPanelX = this.modifierPanelX;
    this.shortcutPanelY = this.clampModifierPanelY(defaultY + 150, 238);
    this.modifierPanelPositionReady = true;
  }

  private clampModifierPanelsIntoView(): void {
    this.modifierPanelX = this.clampModifierPanelX(this.modifierPanelX);
    this.modifierPanelY = this.clampModifierPanelY(this.modifierPanelY, this.fnLayer ? 300 : 136);
    this.shortcutPanelX = this.clampModifierPanelX(this.shortcutPanelX);
    this.shortcutPanelY = this.clampModifierPanelY(this.shortcutPanelY, 238);
  }

  private moveModifierPanel(x: number, y: number): void {
    this.modifierPanelX = this.clampModifierPanelX(x);
    this.modifierPanelY = this.clampModifierPanelY(y, this.fnLayer ? 300 : 136);
  }

  private moveShortcutPanel(x: number, y: number): void {
    this.shortcutPanelX = this.clampModifierPanelX(x);
    this.shortcutPanelY = this.clampModifierPanelY(y, 238);
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
    if (this.sessionId <= 0 || !this.connected) {
      return;
    }
    this.keyDispatcher.sendVirtualKeyTap(this.loader, this.sessionId, keyCode, label);
  }

  /** 发送带修饰键的按键序列 → RemoteKeyDispatcher */
  private sendModifiedKey(keyCode: number, label: string): void {
    if (this.sessionId <= 0 || !this.connected) {
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
    if (this.sessionId <= 0 || !this.connected) {
      return;
    }
    this.keyDispatcher.sendShortcutSequence(this.loader, this.sessionId, keyCodes, label,
      (mod: string): string => this.getLatch(mod),
      (mod: string): boolean => this.isRemoteModDown(mod),
      (mod: string, down: boolean): void => { this.setRemoteModDown(mod, down); });
  }

  /** Ctrl+Alt+Del → RemoteKeyDispatcher */
  private sendCtrlAltDel(): void {
    if (this.sessionId <= 0 || !this.connected) {
      return;
    }
    this.keyDispatcher.sendCtrlAltDel(this.loader, this.sessionId, this.accentColor,
      (mod: string): string => this.getLatch(mod),
      (mod: string): boolean => this.isRemoteModDown(mod),
      (mod: string, down: boolean): void => { this.setRemoteModDown(mod, down); });
  }

  /** 释放所有可能按下的修饰键 + 鼠标键 → RemoteKeyDispatcher */
  private releaseAllHeldKeys(): void {
    if (this.sessionId <= 0) {
      return;
    }
    this.keyDispatcher.releaseAllHeldKeys(this.loader, this.sessionId,
      (x: number, y: number): Record<string, number> => this.toSourceSpace(x, y),
      this.remoteCursorX, this.remoteCursorY);
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
        } catch (_e) {
          // 初始读取失败, 后续 avoidAreaChange 会更新
        }
        this.kbAvoidCb = (data: window.AvoidAreaOptions): void => {
          if (data.type === window.AvoidAreaType.TYPE_KEYBOARD) {
            this.kbHeight = px2vp(data.area.bottomRect.height);
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

  private onRemoteDesktopBgFlagChange(): void {
    const action: RemoteDesktopBackgroundAction = decideRemoteDesktopBackgroundAction(
      this.remoteDesktopBgFlag,
      this.connected,
      this.sessionId,
      this.bgRestorePending,
      this.cleanupStarted
    );
    if (action === RemoteDesktopBackgroundAction.detach) {
      hilog.info(RD_DOMAIN, RD_TAG, 'bgFlagChange: background preserve');
      this.detachForBackground();
      return;
    }
    if (action === RemoteDesktopBackgroundAction.restore) {
      hilog.info(RD_DOMAIN, RD_TAG, 'bgFlagChange: foreground restore');
      this.restoreFromBackground();
      this.tryStartConnect();
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

  private adaptiveSurfaceSize(maxEdgePx: number = RUSTDESK_ADAPTIVE_MAX_EDGE_PX): DesktopSize | null {
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

  async aboutToAppear(): Promise<void> {
    this.xComponentController.setListener(this);
    await this.setPreferredOrientation(window.Orientation.LANDSCAPE, 'LANDSCAPE');
    this.registerInputDeviceWatcher();
    this.registerKeyboardAvoidListener();
    const params: Object = router.getParams();
    if (params) {
      const p: Record<string, Object> = params as Record<string, Object>;
      const id: string = p['hostId'] as string;
      if (id) {
        this.hostId = id;
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
          this.applyDesktopKeyboardMouseMode();
          const restoring: boolean = this.prepareRegistryRestore(host);
          if (restoring) {
            this.restoreFromBackground();
            this.tryStartConnect();
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

  aboutToDisappear(): void {
    try {
      if (this.inputDeviceListenerRegistered) {
        inputDevice.off('change', this.inputDeviceListener);
        this.inputDeviceListenerRegistered = false;
      }
    } catch (_err) { /* ignore */ }

    // 路由感知策略 (T-252):
    // - 后台标志=true (EntryAbility.onBackground 已触发) → 保活: 脱附渲染, 保留协议+音频
    // - 后台标志=false (用户显式退出/back/swipe) → 完全断连
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
        this.detachForBackground();
      } else {
        hilog.info(RD_DOMAIN, RD_TAG, 'aboutToDisappear: background skip action=' + action.toString());
      }
      return;
    }

    // 显式 back / 左右滑退出 / 断开按钮 → 完全断连
    hilog.info(RD_DOMAIN, RD_TAG, 'aboutToDisappear: full disconnect reason=explicit-exit');
    this.disconnectAndCleanup('explicit-exit');
  }

  private tryStartConnect(): void {
    // 后台恢复路径: 协议连接仍存在, 只需重建渲染
    // 使用 bgRestorePending 实例变量, 不受 AppStorage/onForeground 时序影响
    if (this.bgRestorePending && this.sessionId > 0 && this.surfaceReady && !this.cleanupStarted) {
      hilog.info(RD_DOMAIN, RD_TAG, 'tryStartConnect: background restore — reattaching renderer only');
      this.doBackgroundRestoreRender();
      return;
    }

    if (this.connectStarted || !this.pendingHost || this.connected || !this.connecting ||
      this.showRustDeskAuthSheet) {
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
      const adaptive: DesktopSize | null = this.adaptiveSurfaceSize();
      if (adaptive) {
        adaptive.colorDepth = display.colorDepth > 0 ? display.colorDepth : 32;
        hilog.info(RD_DOMAIN, RD_TAG, 'RustDesk adaptive size=' + adaptive.width.toString() + 'x' +
          adaptive.height.toString() + ' surfacePx=' + this.renderWidthPx.toString() + 'x' +
          this.renderHeightPx.toString());
        return adaptive;
      }
    }
    if (host.protocol === 'rdp') {
      const preset: number = AppStorage.get<number>('rdpDesktopPreset') ?? 1;
      const colorDepthPref: number = AppStorage.get<number>('rdpColorDepth') ?? 32;
      const colorDepth: number = colorDepthPref === 16 || colorDepthPref === 24 ? colorDepthPref : 32;
      if (preset === 0) {
        const adaptiveRdp: DesktopSize | null = this.adaptiveSurfaceSize(3840);
        if (adaptiveRdp) {
          adaptiveRdp.colorDepth = colorDepth;
          hilog.info(RD_DOMAIN, RD_TAG, 'RDP adaptive size=' + adaptiveRdp.width.toString() + 'x' +
            adaptiveRdp.height.toString() + ' colorDepth=' + colorDepth.toString());
          return adaptiveRdp;
        }
      }
      let width: number = 1920;
      let height: number = 1080;
      if (preset === 2) {
        width = 2560;
        height = 1440;
      } else if (preset === 3) {
        width = 3840;
        height = 2160;
      }
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

  private async startRemoteSessionBackgroundTask(ctx: common.UIAbilityContext,
    info: RemoteSessionBgInfo): Promise<void> {
    await RemoteSessionBackgroundTaskService.getInstance().startSessionTask(ctx, info);
    if (info.hasAudio || info.hasVideo) {
      await RemoteSessionBackgroundTaskService.getInstance().startAudioPlaybackTask(ctx, info);
    }
  }

  /**
   * 启动实况窗 (仅在退后台时调用)。
   * 有真实音频或视频活动时优先使用 video AVSession 策略,
   * 系统拒绝 AVSession 时由服务降级到通知实况窗。
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
      await service.reconcile(ctx, liveViewInfo);

      // 如果有音频, AVSession 策略启动后注入静音回调
      if (info.hasAudio) {
        service.setMuteCommandCallback((mute: boolean): void => {
          this.setRemoteAudioMute(mute);
        });
      }

      hilog.info(RD_DOMAIN, RD_TAG, 'startSessionLiveView: live view started protocol=' +
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
   * 停止实况窗 (前台恢复或断连时调用)。
   */
  private async stopSessionLiveView(ctx: common.UIAbilityContext): Promise<void> {
    try {
      await RemoteSessionLiveViewService.getInstance().stop(ctx);
      hilog.info(RD_DOMAIN, RD_TAG, 'stopSessionLiveView: live view stopped');
    } catch (err) {
      hilog.warn(RD_DOMAIN, RD_TAG, 'stopSessionLiveView: failed: ' + JSON.stringify(err));
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

  private currentRemoteMediaSnapshot(): RemoteSessionMediaSnapshot {
    return {
      hasAudio: this.loader.isAudioActive(),
      hasVideo: this.loader.isVideoActive()
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
      const surfaceId: string = this.latestSurfaceId.length > 0 ? this.latestSurfaceId : this.xcId;
      const result = this.loader.reattachRenderForForeground(surfaceId, desktop.width, desktop.height);
      if (result.ok && result.value !== undefined && result.value > 0) {
        this.rendererHandle = result.value;
        this.nativeHandles.markSurfaceAttached(this.rendererHandle);
        if (this.renderWidthPx > 0 && this.renderHeightPx > 0 &&
          (this.renderWidthPx !== desktop.width || this.renderHeightPx !== desktop.height)) {
          this.loader.resizeRenderer(this.rendererHandle, this.renderWidthPx, this.renderHeightPx);
        }
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
    this.remoteWidth = desktop.width;
    this.remoteHeight = desktop.height;
    if (!this.remoteCursorReady) {
      this.remoteCursorX = Math.round(this.remoteWidth / 2);
      this.remoteCursorY = Math.round(this.remoteHeight / 2);
    } else {
      this.remoteCursorX = this.clampRemoteX(this.remoteCursorX);
      this.remoteCursorY = this.clampRemoteY(this.remoteCursorY);
    }
  }

  private clampRemoteX(x: number): number {
    const maxX: number = Math.max(0, (this.remoteWidth > 0 ? this.remoteWidth : 1280) - 1);
    return Math.max(0, Math.min(maxX, Math.round(x)));
  }

  private clampRemoteY(y: number): number {
    const maxY: number = Math.max(0, (this.remoteHeight > 0 ? this.remoteHeight : 720) - 1);
    return Math.max(0, Math.min(maxY, Math.round(y)));
  }

  private rememberRemoteCursor(x: number, y: number): void {
    this.remoteCursorX = this.clampRemoteX(x);
    this.remoteCursorY = this.clampRemoteY(y);
    this.remoteCursorReady = true;
  }

  private localDeltaToSurfacePx(delta: number, axis: 'x' | 'y'): number {
    const localSize: number = axis === 'x' ? this.surfaceWidth : this.surfaceHeight;
    const surfacePx: number = axis === 'x' ? this.renderWidthPx : this.renderHeightPx;
    if (localSize > 0 && surfacePx > 0) {
      return delta * surfacePx / localSize;
    }
    return this.vpToPx(delta);
  }

  private remoteDeltaFromLocal(delta: number, axis: 'x' | 'y'): number {
    // 始终使用真实桌面尺寸 — 光标在桌面上移动，不在视频帧上移动
    // sourceWidth/sourceHeight 是编码后的视频帧尺寸，可能与桌面不同 (横竖屏/缩放等)
    const remoteSize: number = axis === 'x' ? this.remoteWidth : this.remoteHeight;
    let viewportSize: number = axis === 'x' ? this.renderWidthPx : this.renderHeightPx;
    try {
      const vp = this.loader.getRendererViewport(this.rendererHandle);
      if (vp && vp['sourceWidth'] > 0 && vp['sourceHeight'] > 0 &&
        vp['viewportW'] > 0 && vp['viewportH'] > 0) {
        // 使用视口物理尺寸补偿 letterbox 黑边
        viewportSize = axis === 'x' ? vp['viewportW'] : vp['viewportH'];
      }
    } catch (_e) {
      // 使用 XComponent surface 尺寸
    }
    const surfaceDelta: number = this.localDeltaToSurfacePx(delta, axis);
    if (remoteSize > 0 && viewportSize > 0) {
      return surfaceDelta * remoteSize / viewportSize * TOUCHPAD_POINTER_GAIN;
    }
    return surfaceDelta * TOUCHPAD_POINTER_GAIN;
  }

  /**
   * 将桌面空间坐标转换为 Host 端鼠标空间 (SwitchDisplay 分辨率)
   *
   * 客户端光标在 desktop 空间 (remoteWidth×remoteHeight) 中追踪,
   * 但 RustDesk Host 接收鼠标事件的坐标空间是 SwitchDisplay 分辨率
   * (即视频帧 sourceWidth×sourceHeight)。两者可能不同 (横竖屏/缩放)。
   * 此处按比例映射, 确保 Host 端光标覆盖全桌面。
   */
  private toSourceSpace(desktopX: number, desktopY: number): Record<string, number> {
    let sw: number = this.remoteWidth;
    let sh: number = this.remoteHeight;
    try {
      const vp = this.loader.getRendererViewport(this.rendererHandle);
      if (vp && vp['sourceWidth'] > 0 && vp['sourceHeight'] > 0) {
        sw = vp['sourceWidth'] as number;
        sh = vp['sourceHeight'] as number;
      }
    } catch (_e) { /* 使用桌面尺寸兜底 */ }
    if (sw <= 0 || sh <= 0) {
      const r: Record<string, number> = { 'x': desktopX, 'y': desktopY };
      return r;
    }
    const sx: number = Math.round(desktopX * sw / this.remoteWidth);
    const sy: number = Math.round(desktopY * sh / this.remoteHeight);
    const r: Record<string, number> = {
      'x': Math.max(0, Math.min(sw - 1, sx)),
      'y': Math.max(0, Math.min(sh - 1, sy))
    };
    return r;
  }

  private remoteToLocalPoint(remoteX: number, remoteY: number): LocalPoint {
    // 始终使用真实桌面尺寸 — 触摸环投影的是桌面光标位置，不是视频帧位置
    const remoteW: number = this.remoteWidth > 0 ? this.remoteWidth : 1280;
    const remoteH: number = this.remoteHeight > 0 ? this.remoteHeight : 720;
    try {
      const vp = this.loader.getRendererViewport(this.rendererHandle);
      if (vp && vp['sourceWidth'] > 0 && vp['sourceHeight'] > 0 &&
        vp['viewportW'] > 0 && vp['viewportH'] > 0) {
        const localScaleX: number = this.renderWidthPx > 0 && this.surfaceWidth > 0 ?
          this.surfaceWidth / this.renderWidthPx : 1;
        const localScaleY: number = this.renderHeightPx > 0 && this.surfaceHeight > 0 ?
          this.surfaceHeight / this.renderHeightPx : 1;
        const pxX: number = vp['viewportX'] + remoteX * vp['viewportW'] / remoteW;
        const pxY: number = vp['viewportY'] + remoteY * vp['viewportH'] / remoteH;
        return {
          x: pxX * localScaleX,
          y: pxY * localScaleY,
          inside: remoteX >= 0 && remoteY >= 0 && remoteX < remoteW && remoteY < remoteH
        };
      }
    } catch (_e) {
      // 使用 ArkTS contain 兜底
    }
    const viewW: number = this.surfaceWidth > 0 ? this.surfaceWidth : remoteW;
    const viewH: number = this.surfaceHeight > 0 ? this.surfaceHeight : remoteH;
    const scale: number = Math.min(viewW / remoteW, viewH / remoteH);
    const offsetX: number = (viewW - remoteW * scale) / 2;
    const offsetY: number = (viewH - remoteH * scale) / 2;
    return {
      x: offsetX + remoteX * scale,
      y: offsetY + remoteY * scale,
      inside: remoteX >= 0 && remoteY >= 0 && remoteX < remoteW && remoteY < remoteH
    };
  }

  private mapInputPoint(localX: number, localY: number): MappedPoint {
    // 优先使用 native renderer 的真实 contain 视口，避免 vp/px 或 letterbox 重算导致偏移。
    // 桌面坐标始终使用真实桌面尺寸 remoteWidth/remoteHeight，不替换为视频帧尺寸。
    const remoteW: number = this.remoteWidth > 0 ? this.remoteWidth : 1280;
    const remoteH: number = this.remoteHeight > 0 ? this.remoteHeight : 720;
    try {
      const vp = this.loader.getRendererViewport(this.rendererHandle);
      if (vp && vp['sourceWidth'] > 0 && vp['sourceHeight'] > 0 &&
        vp['viewportW'] > 0 && vp['viewportH'] > 0) {
        const localPxX: number = this.surfaceWidth > 0 && localX <= this.surfaceWidth + 1 ?
          this.vpToPx(localX) : localX;
        const localPxY: number = this.surfaceHeight > 0 && localY <= this.surfaceHeight + 1 ?
          this.vpToPx(localY) : localY;
        const viewportX: number = vp['viewportX'] as number;
        const viewportY: number = vp['viewportY'] as number;
        const viewportW: number = vp['viewportW'] as number;
        const viewportH: number = vp['viewportH'] as number;
        const rawX: number = (localPxX - viewportX) * remoteW / viewportW;
        const rawY: number = (localPxY - viewportY) * remoteH / viewportH;
        return {
          x: Math.max(0, Math.min(remoteW - 1, Math.round(rawX))),
          y: Math.max(0, Math.min(remoteH - 1, Math.round(rawY))),
          inside: rawX >= 0 && rawY >= 0 && rawX < remoteW && rawY < remoteH
        };
      }
    } catch (_e) {
      // 查询失败时使用缓存的 remoteWidth/remoteHeight
    }

    const viewW: number = this.surfaceWidth > 0 ? this.surfaceWidth : remoteW;
    const viewH: number = this.surfaceHeight > 0 ? this.surfaceHeight : remoteH;
    const scale: number = Math.min(viewW / remoteW, viewH / remoteH);
    const contentW: number = remoteW * scale;
    const contentH: number = remoteH * scale;
    const offsetX: number = (viewW - contentW) / 2;
    const offsetY: number = (viewH - contentH) / 2;
    const rawX: number = (localX - offsetX) / scale;
    const rawY: number = (localY - offsetY) / scale;
    const x: number = Math.max(0, Math.min(remoteW - 1, Math.round(rawX)));
    const y: number = Math.max(0, Math.min(remoteH - 1, Math.round(rawY)));
    return {
      x,
      y,
      inside: rawX >= 0 && rawY >= 0 && rawX < remoteW && rawY < remoteH
    };
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

  private clearMouseMoveTimer(): void {
    if (this.mouseMoveTimer >= 0) {
      clearTimeout(this.mouseMoveTimer);
      this.mouseMoveTimer = -1;
    }
  }

  private flushMouseMove(): void {
    this.clearMouseMoveTimer();
    if (!this.pendingMouseMoveValid) {
      return;
    }
    if (this.canForwardInput('mouseMove')) {
      const src = this.toSourceSpace(this.pendingMouseMoveX, this.pendingMouseMoveY);
      this.loader.sendMouse(this.sessionId, src['x'], src['y'], -1, false);
    }
    this.pendingMouseMoveValid = false;
  }

  private queueMouseMove(x: number, y: number): void {
    this.rememberRemoteCursor(x, y);
    this.pendingMouseMoveX = x;
    this.pendingMouseMoveY = y;
    this.pendingMouseMoveValid = true;
    if (this.mouseMoveTimer < 0) {
      this.mouseMoveTimer = setTimeout(() => {
        this.flushMouseMove();
      }, MOUSE_MOVE_FLUSH_MS);
    }
  }

  private sendMouseNow(x: number, y: number, button: number, pressed: boolean): void {
    this.rememberRemoteCursor(x, y);
    if (button < 0) {
      this.queueMouseMove(x, y);
      return;
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
    const authIdentityMode: number = AppStorage.get<number>('rdpAuthIdentityMode') ?? 1;
    const rawUsername: string = host.username.trim();
    const slashIndex: number = rawUsername.indexOf('\\');

    if (authIdentityMode === 3) {
      let emailUsername: string = rawUsername;
      if (rawUsername.startsWith('.\\AzureAD\\')) {
        emailUsername = rawUsername.substring('.\\AzureAD\\'.length);
      } else if (rawUsername.startsWith('\\AzureAD\\')) {
        emailUsername = rawUsername.substring('\\AzureAD\\'.length);
      } else if (rawUsername.startsWith('AzureAD\\')) {
        emailUsername = rawUsername.substring('AzureAD\\'.length);
      }
      hilog.info(RD_DOMAIN, RD_TAG, 'RDP credential normalized: AzureAD dot-domain format');
      return { username: 'AzureAD\\' + emailUsername, domain: '.' };
    }

    if (authIdentityMode === 4) {
      let emailUsername: string = rawUsername;
      if (rawUsername.startsWith('.\\AzureAD\\')) {
        emailUsername = rawUsername.substring('.\\AzureAD\\'.length);
      } else if (rawUsername.startsWith('\\AzureAD\\')) {
        emailUsername = rawUsername.substring('\\AzureAD\\'.length);
      } else if (rawUsername.startsWith('AzureAD\\')) {
        emailUsername = rawUsername.substring('AzureAD\\'.length);
      }
      hilog.info(RD_DOMAIN, RD_TAG, 'RDP credential normalized: AzureAD domain format');
      return { username: emailUsername, domain: 'AzureAD' };
    }

    if (rawUsername.startsWith('.\\AzureAD\\') || rawUsername.startsWith('\\AzureAD\\') ||
      rawUsername.startsWith('AzureAD\\')) {
      let azureUsername: string = rawUsername;
      if (rawUsername.startsWith('.\\AzureAD\\')) {
        azureUsername = rawUsername.substring('.\\'.length);
      } else if (rawUsername.startsWith('\\AzureAD\\')) {
        azureUsername = rawUsername.substring('\\'.length);
      }
      hilog.info(RD_DOMAIN, RD_TAG, 'RDP credential normalized: explicit AzureAD dot-domain format');
      return { username: azureUsername, domain: '.' };
    }

    if (slashIndex > 0 && slashIndex < rawUsername.length - 1 &&
      !rawUsername.startsWith('MicrosoftAccount\\')) {
      const domainPart: string = rawUsername.substring(0, slashIndex);
      const userPart: string = rawUsername.substring(slashIndex + 1);
      hilog.info(RD_DOMAIN, RD_TAG, 'RDP credential normalized: domain user domain=' + maskUser(domainPart) +
        ' username=' + maskUser(userPart));
      return {
        username: userPart,
        domain: domainPart
      };
    }

    if ((rawUsername.startsWith('MicrosoftAccount\\') && rawUsername.indexOf('@') > 0) ||
      rawUsername.indexOf('@') > 0) {
      let emailUsername: string = rawUsername;
      if (rawUsername.startsWith('MicrosoftAccount\\')) {
        emailUsername = rawUsername.substring('MicrosoftAccount\\'.length);
      }
      if (authIdentityMode === 1) {
        hilog.info(RD_DOMAIN, RD_TAG, 'RDP credential normalized: email username uses MicrosoftAccount domain');
        return { username: emailUsername, domain: 'MicrosoftAccount' };
      }
      if (authIdentityMode === 2) {
        hilog.info(RD_DOMAIN, RD_TAG, 'RDP credential normalized: email username uses bare email');
        return { username: emailUsername, domain: '' };
      }
      hilog.info(RD_DOMAIN, RD_TAG, 'RDP credential normalized: Microsoft account uses full username');
      return { username: 'MicrosoftAccount\\' + emailUsername, domain: '' };
    }
    hilog.info(RD_DOMAIN, RD_TAG, 'RDP credential normalized: plain username=' + maskUser(rawUsername));
    return { username: rawUsername, domain: '' };
  }

  private hostWithResolvedCredential(host: RemoteHost): RemoteHost {
    if (host.protocol !== 'rdp' || host.rdpCredentialId === '') {
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
    protocol: string
  ): Promise<boolean> {
    const startedAt: number = Date.now();
    let lastState: number = -1;
    let lastLogMs: number = 0;
    while (Date.now() - startedAt < timeoutMs) {
      if (attemptId !== this.connectAttemptId || this.sessionId !== sessionId) {
        hilog.info(RD_DOMAIN, RD_TAG, 'Native connection wait canceled');
        return false;
      }
      const state: number = this.loader.getConnectionState(sessionId);
      const transferStatus: SessionTransferStatus = this.loader.getSessionTransferStatus(sessionId);
      this.rdpDriveMounted = transferStatus.rdpDriveMounted;
      if (state === 2) {
        return true;
      }
      if (state === 4 || state === 0) {
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
      throw new Error('RustDesk 握手超时 [E-RUSTDESK-TIMEOUT]');
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
          const sourceWidth: number = vp['sourceWidth'] as number;
          const sourceHeight: number = vp['sourceHeight'] as number;
          if (sourceWidth > 0 && sourceHeight > 0 &&
            (sourceWidth !== this.remoteWidth || sourceHeight !== this.remoteHeight)) {
            this.updateRemoteSize({
              width: sourceWidth,
              height: sourceHeight,
              colorDepth: 32,
              multiMonitor: false,
              monitorCount: 1
            });
            hilog.info(RD_DOMAIN, RD_TAG, 'RDP desktop size synchronized from renderer: ' +
              sourceWidth.toString() + 'x' + sourceHeight.toString());
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

  // XComponent 就绪后初始化渲染管线并连接
  private async doConnect(host: RemoteHost): Promise<void> {
    const attemptId: number = ++this.connectAttemptId;
    try {
      if (!(await this.loader.waitForPendingTeardown())) {
        throw new Error('上一会话资源清理未完成 [E-TEARDOWN-PENDING]');
      }
      const desktop: DesktopSize = this.desktopSize(host);
      this.updateRemoteSize(desktop);
      const credentials: RdpCredentialParts = this.rdpCredentialParts(host);
      const w: number = desktop.width;
      const h: number = desktop.height;

      // 初始化渲染器 (XComponent surface 已就绪)
      console.info('[RD-DIAG] initRenderer: xcId=' + this.xcId + ' w=' + w + ' h=' + h);
      const rHandle: number = this.loader.initRenderer(this.xcId, w, h);
      console.info('[RD-DIAG] initRenderer returned: ' + rHandle);
      if (rHandle <= 0) {
        throw new Error('渲染器初始化失败 [E-RENDERER-INIT] rc=' + rHandle);
      }
      this.rendererHandle = rHandle;
      this.nativeHandles.markSurfaceAttached(this.rendererHandle);
      if (this.renderWidthPx > 0 && this.renderHeightPx > 0 &&
        (this.renderWidthPx !== w || this.renderHeightPx !== h)) {
        this.loader.resizeRenderer(this.rendererHandle, this.renderWidthPx, this.renderHeightPx);
        hilog.info(RD_DOMAIN, RD_TAG, 'renderer resized after init: surface=' +
          this.renderWidthPx.toString() + 'x' + this.renderHeightPx.toString() +
          ' remote=' + w.toString() + 'x' + h.toString());
      }

      // 初始化解码器 (非阻塞 — 解码器未就绪不影响连接建立)
      const rdCodecVal: number = AppStorage.get<number>('rustdeskCodec') ?? 0;
      // RustDesk 自动模式不强制 H264；本地解码器按 RustDesk 常见 VP9 起步。
      let decoderCodec: number = host.protocol === 'rustdesk' ? 3 : 0;
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
      let dHandle: number = this.loader.initDecoder(w, h, decoderCodec);
      hilog.info(RD_DOMAIN, RD_TAG, 'initDecoder returned: ' + dHandle);
      if (dHandle > 0) {
        this.decoderHandle = dHandle;
        const bindOk: boolean = this.loader.bindVideoPipeline(this.decoderHandle, this.rendererHandle);
        hilog.info(RD_DOMAIN, RD_TAG, 'bindVideoPipeline returned: ' + bindOk);
      } else {
        hilog.warn(RD_DOMAIN, RD_TAG, '解码器未就绪 (rc=' + dHandle + '), 连接将继续, 待后续初始化');
      }

      if (host.protocol === 'rustdesk') {
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

      // 密钥解析: sshKeyId 优先 (引用 KeyVault), 回退 sshKeyData (旧副本)
      let keyData: string = host.sshKeyData;
      if (host.sshKeyId !== '') {
        const kvs = KeyVaultService.getInstance();
        const ref = kvs.getSshKey(host.sshKeyId);
        if (ref) { keyData = ref.privateKey; }
      }
      const useKey: boolean = host.sshUseKey && keyData.length > 0;
      // 检测私钥是否需要密码
      let keyPassphrase: string = host.sshKeyPassphrase || '';
      if (useKey) {
        const keyInfo = this.loader.inspectSshPrivateKey(keyData, keyPassphrase);
        if (keyInfo['encrypted'] && keyPassphrase === '') {
          keyPassphrase = await this.promptSshPassphrase();
        }
      }
      const rdpDriveName: string = this.sanitizedRdpDriveName();
      if (host.protocol === 'rdp' && this.rdpDriveEnabled && !RDP_DRIVE_REDIRECTION_ENABLED) {
        hilog.warn(RD_DOMAIN, RD_TAG, 'RDP drive redirection disabled for stable connect path');
      }
      const rdpDrivePath: string = host.protocol === 'rdp' && this.rdpDriveEnabled && RDP_DRIVE_REDIRECTION_ENABLED ?
        this.ensureRdpTransferDir() : '';
      let rdServerKey: string = '';
      if (host.protocol === 'rustdesk' && host.rustdeskRelayId.length > 0) {
        const relay: RustDeskRelayConfig | undefined = this.srv.getAllRelays()
          .find((r: RustDeskRelayConfig): boolean => r.id === host.rustdeskRelayId);
        if (relay) { rdServerKey = relay.key; }
      }
      const rustDeskDirect: boolean = host.protocol === 'rustdesk' && host.rustdeskDirectEnabled;
      const directHost: string = host.rustdeskDirectHost.trim();
      if (rustDeskDirect && directHost.length === 0) {
        throw new Error('RustDesk 直连地址为空，请在主机编辑中填写局域网地址 [E-RUSTDESK-DIRECT-HOST]');
      }
      const sessionHost: string = rustDeskDirect ? directHost : host.host;
      const sessionPort: number = rustDeskDirect ?
        normalizeRustDeskPort(host.rustdeskDirectPort, RUSTDESK_PEER_TCP_PORT) : host.port;
      const cfg: SessionConfig = {
        protocol: host.protocol,
        host: sessionHost,
        port: sessionPort,
        username: credentials.username,
        password: host.password,
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
        rdpAuthIdentityMode: AppStorage.get<number>('rdpAuthIdentityMode') ?? 1,
        authMethod: useKey ? 'publickey' : 'password',
        privateKeyPem: useKey ? keyData : '',
        privateKeyPassphrase: keyPassphrase,
        // RustDesk 设置 — 从 AppStorage 全局偏好 + 主机绑定中继/账户
        rdImageQuality: AppStorage.get<number>('rustdeskImageQuality') ?? 1,
        rdDirectIp: rustDeskDirect,
        rdDirectPort: sessionPort,
        rdLanDiscovery: AppStorage.get<boolean>('rustdeskLanDiscovery') ?? true,
        rdPrivacyMode: AppStorage.get<boolean>('rustdeskPrivacyMode') ?? false,
        rdAudioEnabled: host.protocol === 'rdp' ?
          (AppStorage.get<boolean>('rdpAudioEnabled') ?? true) :
          (AppStorage.get<boolean>('rustdeskAudioEnabled') ?? true),
        rdClipboardEnabled: host.protocol === 'rustdesk' ?
          (AppStorage.get<boolean>('rustdeskClipboardEnabled') ?? true) :
          (AppStorage.get<boolean>('rdpClipboardEnabled') ?? true),
        rdDriveName: rdpDriveName,
        rdDrivePath: rdpDrivePath,
        expectedRdpCertificateFingerprintSha256: host.rdpCertificateFingerprintSha256,
        rdpAllowUntrustedRoot: host.rdpCertificateAllowUntrustedRoot,
        rdpAllowHostMismatch: host.rdpCertificateAllowHostMismatch,
        rdPasswordMode: host.rustdeskPasswordMode,
        rdAuthMode: rustDeskAuthModeForConnection(rustDeskDirect, host.rustdeskAuthMode) ===
          'request_approval' ? 1 : 0,
        rdRelayId: host.rustdeskRelayId,
        rdAccountId: host.rustdeskAccountId,
        rdServerKey: rdServerKey
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
      const sid: number = this.loader.connect(cfg);
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
        else if (sid === -31 && host.protocol === 'rustdesk') { errMsg = 'RustDesk 握手失败，请查看 FFI 日志 [E-CONNECT-31]'; }
        throw new Error(errMsg);
      }
      this.sessionId = sid;
      this.inputForwardReady = false;
      const rustDeskApprovalWait: boolean = host.protocol === 'rustdesk' &&
        rustDeskAuthModeForConnection(host.rustdeskDirectEnabled, host.rustdeskAuthMode) ===
        'request_approval';
      const nativeReady: boolean = await this.waitForNativeConnected(
        sid, host.protocol === 'rustdesk' ? (rustDeskApprovalWait ? 100000 : 25000) : 45000,
        attemptId, host.protocol);
      if (!nativeReady) {
        return;
      }

      this.nativeHandles.attachConnectedSession(sid, this.remoteProtocolOf(host));
      this.connected = true;
      this.connecting = false;
      this.persistRustDeskSessionAuth(host);
      this.recordActiveSession(host, sid, true);
      // T-171: 连接成功后显示悬浮胶囊
      this.initHandlePosition();
      this.handleVisible = true;
      if (host.protocol === 'rdp') {
        this.startRdpRenderWatchdog(sid, attemptId);
        this.startRdpNativeStateMonitor(sid, attemptId);
        setTimeout((): void => {
          if (this.sessionId === sid && this.connected && this.connectAttemptId === attemptId) {
            this.inputForwardReady = true;
            hilog.info(RD_DOMAIN, RD_TAG, 'RDP input forwarding enabled after video-stability gate');
          }
        }, 2000);
      } else {
        this.inputForwardReady = true;
      }
      await this.setPreferredOrientation(window.Orientation.LANDSCAPE, 'LANDSCAPE');
      await this.setRemoteKeepScreenOn(true);
      await this.setRemoteNavigationHidden(true, 'connect-success');
      // 所有协议统一记录成功连接时间；健康字段由实际探测结果另行更新。
      // RDP 之前为了诊断临时跳过该写入，导致卡片和详情长期显示旧状态。
      await this.srv.updateLastConnected(host.id);
      this.startClipboardBridgeBestEffort(sid, attemptId,
        clipboardSyncEnabledForProtocol(host.protocol,
          AppStorage.get<boolean>('rdpClipboardEnabled') ?? true, this.rustdeskClipboardEnabled));
    } catch (err) {
      this.clearRdpRenderWatchdog();
      this.clearRdpNativeStateMonitor();
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
      }
      this.nativeHandles.markProtocolDisconnected();
      this.activeSessionRegistry.clear('connect-failed');
      this.inputForwardReady = false;
      this.connectStarted = false;
      this.connecting = false;
      const errObj: Error = err as Error;
      // 连接失败也要立即刷新本机健康状态；云写入由服务按节流策略处理，
      // 页面监听器仍会立刻收到 UNKNOWN，避免缩略卡片继续显示上次成功结果。
      await this.srv.updateConnectionHealth(host.id, -1, false);
      this.connectionError = '无法建立远程连接';
      this.connectionErrorDetail = errObj.message ? errObj.message : '未知连接错误 [E-CONNECT-UNKNOWN]';
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
    if (this.cleanupStarted) {
      return;
    }
    this.cleanupStarted = true;
    const cleanupStartedAtMs: number = Date.now();
    if (shouldRestoreRemoteNavigation(reason, false)) {
      this.setRemoteNavigationHidden(false, reason);
    }
    this.resetRemoteImeSession('disconnect-' + reason);
    this.bgRestorePending = false; // 清除任何待恢复状态
    this.activeSessionRegistry.clear(reason);
    this.clearRdpRenderWatchdog();
    this.clearRdpNativeStateMonitor();
    hilog.info(RD_DOMAIN, RD_TAG, '[RDP-SHUTDOWN] phase=arkts-entry reason=' + reason +
      ' sessionId=' + this.sessionId.toString());
    // T-171: 断开时隐藏胶囊和面板 + 释放所有修饰键
    this.handleVisible = false;
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
      if (this.sessionId > 0 || this.rendererHandle > 0 || this.decoderHandle > 0) {
        if (this.sessionId > 0) {
          this.disableRdpBackgroundVideoPrewarm('disconnect-cleanup');
        }
        this.flushMouseMove();
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
        this.rendererHandle = -1;
        this.decoderHandle = -1;
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
      // 停止实况窗
      try {
        const ctx: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
        if (ctx) {
          this.stopSessionLiveView(ctx).catch((_e: Error): void => {
            // 停止失败不影响清理流程
          });
        }
      } catch (_e) { /* ignore */ }
      // 停止后台保活任务
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
        (Date.now() - cleanupStartedAtMs).toString());
    } catch (err) {
      hilog.error(RD_DOMAIN, RD_TAG, '[RDP-SHUTDOWN] phase=arkts-error elapsedMs=' +
        (Date.now() - cleanupStartedAtMs).toString() + ' err=' + JSON.stringify(err));
    }
  }

  /**
   * 后台保活: 仅脱附渲染, 保留协议连接和音频管线。
   * 系统通过 home gesture / onBackground 触发。
   */
  private detachForBackground(): void {
    if (this.cleanupStarted) {
      return;
    }
    this.cleanupStarted = true;
    this.resetRemoteImeSession('background');
    hilog.info(RD_DOMAIN, RD_TAG, 'detachForBackground: preserving protocol + audio');
    this.clearRestoreFrameRefreshPump();
    this.clearRdpRenderWatchdog();
    this.clearRdpNativeStateMonitor();

    // 隐藏 UI 元素
    this.handleVisible = false;
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
    this.applyBackgroundVideoPrewarm(backgroundMedia, 'detach');

    // 仅脱附渲染, 不触碰协议连接、解码器和音频.
    // 注意: 不销毁解码器 — destroyDecoder 会级联断开协议连接.
    if (this.decoderHandle > 0) {
      this.loader.detachVideoPipelineForBackground();
    }
    const rendererHandleBeforeDetach: number = this.rendererHandle;
    if (this.rendererHandle > 0) {
      this.nativeHandles.detachRenderForBackground();
      this.rendererHandle = -1;
    }
    if (shouldInvalidateSurfaceAfterBackgroundDetach(rendererHandleBeforeDetach, this.sessionId)) {
      this.surfaceReady = false;
      hilog.info(RD_DOMAIN, RD_TAG, 'detachForBackground: surface invalidated after render detach');
    }
    if (this.pendingHost !== null && this.sessionId > 0) {
      this.recordActiveSession(this.pendingHost, this.sessionId, false);
      this.activeSessionRegistry.markRenderDetached();
    }

    // 启动后台保活任务
    try {
      const ctx: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
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
        this.startRemoteSessionBackgroundTask(ctx, info).catch((err: Error): void => {
          hilog.warn(RD_DOMAIN, RD_TAG, 'detachForBackground: background task async failed: ' +
            (err.message ? err.message : JSON.stringify(err)));
        });
        hilog.info(RD_DOMAIN, RD_TAG, 'detachForBackground: background task started protocol=' +
          info.protocolLabel);

        // 启动实况窗 (仅退后台时)
        this.startSessionLiveView(ctx, info).catch((err: Error): void => {
          hilog.warn(RD_DOMAIN, RD_TAG, 'detachForBackground: live view async failed: ' +
            (err.message ? err.message : JSON.stringify(err)));
        });
        this.startBackgroundAudioPolling(ctx, info);
      }
    } catch (err) {
      hilog.warn(RD_DOMAIN, RD_TAG, 'detachForBackground: startSessionTask failed: ' +
        JSON.stringify(err));
    }

    // 标记状态: 连接协议仍存活但 UI 已脱附
    this.connected = false;
    this.connectStarted = false;
    this.bgRestorePending = true;
    hilog.info(RD_DOMAIN, RD_TAG, 'detachForBackground: bgRestorePending=true, awaiting foreground');
  }

  /**
   * 从后台恢复: 清除保活标志, 停止后台任务, 等待 XComponent 重建渲染。
   */
  private restoreFromBackground(): void {
    this.cleanupStarted = false; // 允许重新 attach
    // bgFlag 保留到 tryStartConnect → doBackgroundRestoreRender 使用
    this.stopBackgroundAudioPolling();
    this.clearRestoreFrameRefreshPump();
    try {
      const ctx: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
      if (ctx) {
        // 移除实况窗
        this.stopSessionLiveView(ctx).catch((_e: Error): void => {
          // 停止失败不影响恢复流程
        });
        RemoteSessionBackgroundTaskService.getInstance().stopSessionTask(ctx);
      }
    } catch (_e) { /* ignore */ }
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
  }

  /**
   * 后台恢复 — 仅重建渲染器, 不新建协议连接。
   */
  private doBackgroundRestoreRender(): void {
    // cleanupStarted 已在 restoreFromBackground 中重置为 false
    if (this.cleanupStarted) {
      hilog.warn(RD_DOMAIN, RD_TAG, 'doBackgroundRestoreRender: cleanupStarted=true, aborting');
      return;
    }
    this.bgRestorePending = false; // 防止重入
    this.connectStarted = true;
    try {
      const desktop: DesktopSize = this.desktopSize(this.pendingHost);
      const surfaceId: string = this.latestSurfaceId.length > 0 ? this.latestSurfaceId : this.xcId;
      const result = this.loader.reattachRenderForForeground(
        surfaceId, desktop.width, desktop.height);
      if (result.ok && result.value !== undefined && result.value > 0) {
        this.rendererHandle = result.value;
        this.nativeHandles.markSurfaceAttached(this.rendererHandle);
        hilog.info(RD_DOMAIN, RD_TAG, 'doBackgroundRestoreRender: renderer reattached handle=' +
          this.rendererHandle.toString());
        if (this.renderWidthPx > 0 && this.renderHeightPx > 0 &&
          (this.renderWidthPx !== desktop.width || this.renderHeightPx !== desktop.height)) {
          this.loader.resizeRenderer(this.rendererHandle, this.renderWidthPx, this.renderHeightPx);
          hilog.info(RD_DOMAIN, RD_TAG, 'doBackgroundRestoreRender: renderer resized surface=' +
            this.renderWidthPx.toString() + 'x' + this.renderHeightPx.toString() +
            ' remote=' + desktop.width.toString() + 'x' + desktop.height.toString());
        }

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
        this.inputForwardReady = true;
        this.activeSessionRegistry.markRenderAttached(surfaceId);
        this.setRemoteKeepScreenOn(true);
        if (shouldReapplyRemoteNavigation(this.currentProtocolName(), this.connected, true)) {
          this.setRemoteNavigationHidden(true, 'foreground-restore');
        }
        if (this.clipboardBridge === null) {
          const clipboardEnabled: boolean = clipboardSyncEnabledForProtocol(this.currentProtocolName(),
            AppStorage.get<boolean>('rdpClipboardEnabled') ?? true,
            AppStorage.get<boolean>('rustdeskClipboardEnabled') ?? true);
          this.startClipboardBridgeBestEffort(this.sessionId, this.connectAttemptId, clipboardEnabled);
        }
        this.scheduleRestoreFrameRefreshPump();
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
      const desktop: DesktopSize = this.desktopSize(this.pendingHost);
      this.updateRemoteSize(desktop);
      const ok: boolean = rdpnapi.setXComponentSurfaceId(surfaceId, desktop.width, desktop.height) as boolean;
      hilog.info(RD_DOMAIN, RD_TAG, 'setXComponentSurfaceId: surfaceId=' + surfaceId +
        ' size=' + desktop.width + 'x' + desktop.height + ' ok=' + (ok ? 'true' : 'false'));
      this.surfaceReady = ok;
      this.tryStartConnect();
    } catch (_e) {
      this.surfaceReady = false;
      hilog.error(RD_DOMAIN, RD_TAG, 'setXComponentSurfaceId threw: ' + JSON.stringify(_e));
    }
  }

  onSurfaceDestroyed(_surfaceId: string): void {
    hilog.info(RD_DOMAIN, RD_TAG, 'XComponentController.onSurfaceDestroyed');
    this.surfaceReady = false;
    if (_surfaceId === this.latestSurfaceId) {
      this.latestSurfaceId = '';
    }
    this.markXComponentSurfaceDetached('surfaceDestroyed');
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
    this.markXComponentSurfaceDetached('xcomponentDestroy');
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
    this.keyboardOpen = true;
    this.startRemoteImeSession();
    hilog.info(RD_DOMAIN, RD_TAG, 'kbd-open');
    try {
      focusControl.requestFocus('RemoteDesktopKeyboard');
    } catch (err) {
      hilog.error(RD_DOMAIN, RD_TAG,
        'openKeyboard focus failed: ' + JSON.stringify(err));
    }
  }

  private markKeyboardClosed(source: string): void {
    this.keyboardOpen = false;
    this.resetRemoteImeSession('closed-' + source);
    this.keyboardSubmitRefocusPending = false;
    hilog.info(RD_DOMAIN, RD_TAG, 'kbd-close source=' + source);
  }

  private dismissKeyboard(): void {
    if (!this.keyboardOpen) {
      return;
    }
    this.markKeyboardClosed('control-panel');
    // 将焦点移到 XComponent 以收起键盘
    try {
      focusControl.requestFocus('rdpSurface');
    } catch (err) {
      hilog.error(RD_DOMAIN, RD_TAG,
        'dismissKeyboard failed: ' + JSON.stringify(err));
    }
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
            ' queue=' + this.keyboardCommandQueue.size().toString());
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
            ' queue=' + this.keyboardCommandQueue.size().toString());
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
    if (autoHide) {
      this.touchIndicatorTimer = setTimeout(() => {
        this.touchIndicatorVisible = false;
        this.touchIndicatorTimer = -1;
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

  private averageTouchPoint(event: TouchEvent): LocalPoint | null {
    if (event.touches.length === 0) {
      return null;
    }
    let sumX: number = 0;
    let sumY: number = 0;
    for (let i = 0; i < event.touches.length; i++) {
      sumX += event.touches[i].x;
      sumY += event.touches[i].y;
    }
    return {
      x: sumX / event.touches.length,
      y: sumY / event.touches.length,
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
    if (event.type === TouchType.Cancel) {
      return 0;
    }
    const changedCount: number = event.changedTouches.length > 0 ? event.changedTouches.length : 1;
    const previousCount: number = this.touchFingerCount > 0 ?
      this.touchFingerCount : Math.max(event.touches.length, changedCount);
    return Math.max(0, previousCount - changedCount);
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
    const sendDelta: number = this.isRustDeskSession() && this.rustdeskReverseWheel ? -delta : delta;
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
    if (!this.canForwardInput('touch-pad')) { return; }
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
        if (this.touchFingerCount <= 0 && shouldResetRemoteImeOnPointerDown(this.keyboardOpen)) {
          this.resetRemoteImeSession('touchpad-down');
        }
        const oldMaxFingers: number = this.touchMaxFingers;
        const currentTouches: number = event.touches.length > 0 ? event.touches.length :
          Math.max(1, event.changedTouches.length);
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
        this.touchFingerCount = event.touches.length;
        const movePoint: LocalPoint = this.touchFingerCount >= 2 ?
          (this.averageTouchPoint(event) || { x: point.x, y: point.y, inside: true }) :
          { x: point.x, y: point.y, inside: true };
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
          if (Math.abs(stepDy) >= 0.5) {
            // 双指上下滑动只映射滚轮，不再触发拖拽。
            this.sendTouchPadWheel(stepDy);
          }
          if (this.touchMoved) {
            this.touchDragPending = false;
          }
        } else if (this.touchMaxFingers < 2 && (this.touchDragActive || !this.touchGestureDone) &&
          (Math.abs(stepDx) >= 0.1 || Math.abs(stepDy) >= 0.1)) {
          // 单指移动光标
          const pointerSpeed: number = this.isRustDeskSession() ?
            Math.max(0.4, Math.min(2.2, this.rustdeskTouchpadSpeed)) : 1.0;
          const nextX: number = this.remoteCursorX +
            this.remoteDeltaFromLocal(stepDx, 'x') * pointerSpeed;
          const nextY: number = this.remoteCursorY +
            this.remoteDeltaFromLocal(stepDy, 'y') * pointerSpeed;
          this.rememberRemoteCursor(nextX, nextY);
          this.queueMouseMove(this.remoteCursorX, this.remoteCursorY);
          this.showRemoteCursorIndicator(this.touchDragActive ? TOUCH_INDICATOR_BUTTON_DRAG : -1, false);
        }
      } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
        this.clearTouchRightClickTimer();
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
    if (!this.canForwardInput('touch')) { return; }
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
        if (this.touchFingerCount <= 0 && shouldResetRemoteImeOnPointerDown(this.keyboardOpen)) {
          this.resetRemoteImeSession('touch-down');
        }
        const oldMaxFingers: number = this.touchMaxFingers;
        if (this.touchFingerCount <= 0) {
          this.touchMoved = false;
          this.touchGestureDone = false;
          this.touchDragPending = false;
          this.touchMaxFingers = 0;
        }
        this.touchFingerCount = Math.max(event.touches.length, this.touchFingerCount + 1);
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
        this.touchFingerCount = event.touches.length;
        if (this.touchMaxFingers >= 2) {
          const avg: LocalPoint | null = this.averageTouchPoint(event);
          if (avg) {
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
    const host: RemoteHost | null = this.pendingHost;
    const controlMode: number = host && host.protocol === 'rdp' ? this.rdpControlMode : this.rustdeskControlMode;
    if (controlMode === 2) {
      this.hideTouchIndicator();
      if (event.touches.length >= 3 || this.touchMaxFingers >= 3) {
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
      } else if (event.type === TouchType.Down || event.type === TouchType.Cancel) {
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
  private rdpFilePasteKeyIntercepted: boolean = false;

  private isPhysicalModifierKey(keyCode: number): boolean {
    return keyCode === KEYCODE_CTRL_LEFT || keyCode === KEYCODE_CTRL_RIGHT ||
      keyCode === KEYCODE_ALT_LEFT || keyCode === KEYCODE_ALT_RIGHT ||
      keyCode === KEYCODE_SHIFT_LEFT || keyCode === KEYCODE_SHIFT_RIGHT ||
      keyCode === KEYCODE_META_LEFT || keyCode === KEYCODE_META_RIGHT;
  }

  private updatePhysicalModifierState(keyCode: number, down: boolean): void {
    if (keyCode === KEYCODE_CTRL_LEFT || keyCode === KEYCODE_CTRL_RIGHT) {
      this.physicalCtrlDown = down;
    } else if (keyCode === KEYCODE_ALT_LEFT || keyCode === KEYCODE_ALT_RIGHT) {
      this.physicalAltDown = down;
    } else if (keyCode === KEYCODE_SHIFT_LEFT || keyCode === KEYCODE_SHIFT_RIGHT) {
      this.physicalShiftDown = down;
    } else if (keyCode === KEYCODE_META_LEFT || keyCode === KEYCODE_META_RIGHT) {
      this.physicalWinDown = down;
    }
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
  }

  private handleXComponentKey = (event: KeyEvent): void => {
    if (!this.canForwardInput('key')) { return; }
    try {
      event.stopPropagation();
      const isDown: boolean = event.type === KeyType.Down;
      const isUp: boolean = event.type === KeyType.Up;
      if (!isDown && !isUp) {
        return;
      }
      const kc: number = event.keyCode;

      if (kc === KEY_V && isUp && this.rdpFilePasteKeyIntercepted) {
        this.rdpFilePasteKeyIntercepted = false;
        return;
      }
      if (kc === KEY_V && isDown && this.physicalCtrlDown &&
        !this.physicalAltDown && !this.physicalShiftDown && !this.physicalWinDown &&
        this.pendingHost !== null && this.pendingHost.protocol === 'rdp' &&
        this.systemPasteboardHasFileUri()) {
        this.rdpFilePasteKeyIntercepted = true;
        this.loader.sendKey(this.sessionId, KEYCODE_CTRL_LEFT, false);
        this.loader.sendKey(this.sessionId, KEYCODE_CTRL_RIGHT, false);
        this.handleRdpSystemFilePaste();
        return;
      }

      // 物理修饰键: 跟踪状态 + 发送 down/up
      if (this.isPhysicalModifierKey(kc)) {
        this.updatePhysicalModifierState(kc, isDown);
        this.loader.sendKey(this.sessionId, kc, isDown);
        hilog.info(RD_DOMAIN, RD_TAG,
          'hwkey-modifier code=' + kc.toString() + ' down=' + (isDown ? 'yes' : 'no') +
            ' phys=[ctrl=' + (this.physicalCtrlDown ? '1' : '0') +
            ' alt=' + (this.physicalAltDown ? '1' : '0') +
            ' shift=' + (this.physicalShiftDown ? '1' : '0') +
            ' win=' + (this.physicalWinDown ? '1' : '0') + ']');
        return;
      }

      // 非修饰键控制键: 始终走 sendKey (Tab/Enter/Esc/Del/方向键/F键等)
      if (this.isFixedControlKey(kc)) {
        this.loader.sendKey(this.sessionId, kc, isDown);
        hilog.info(RD_DOMAIN, RD_TAG,
          'hwkey-control code=' + kc.toString() + ' down=' + (isDown ? 'yes' : 'no'));
        return;
      }

      // 普通键 (字母/数字/符号)
      if (isDown) {
        if (this.hasAnyModifier()) {
          // 有修饰键按下 → 字母/符号走 sendKey (不抢组合键)
          this.loader.sendKey(this.sessionId, kc, true);
          hilog.info(RD_DOMAIN, RD_TAG,
            'hwkey-modkey code=' + kc.toString() + ' down (modifier active)');
        } else {
          const kt: string = event.keyText;
          if (kt && kt.length > 0) {
            // 无修饰键 + 有可打印字符 → 发文本 (支持中文/emoji/输入法)
            this.loader.sendText(this.sessionId, kt);
          } else {
            // 无修饰键 + 无文本 → 功能键 tap
            this.loader.sendKey(this.sessionId, kc, true);
            this.loader.sendKey(this.sessionId, kc, false);
          }
        }
      } else if (isUp) {
        if (this.hasAnyModifier()) {
          this.loader.sendKey(this.sessionId, kc, false);
        }
      }
    } catch (err) {
      hilog.error(RD_DOMAIN, RD_TAG, 'key forward failed: ' + JSON.stringify(err));
    }
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
      keyCode === KEYCODE_MOVE_HOME ||
      keyCode === KEYCODE_MOVE_END;
  }

  private mapArkMouseButton(button: number): number {
    // ArkUI MouseButton 是位值: Left=1, Right=2, Middle=4, None=0。
    // 协议层内部枚举是 Left=0, Middle=1, Right=2, Move=-1。
    if (button === MouseButton.Left || button === 1) { return 0; }
    if (button === MouseButton.Middle || button === 4) { return 1; }
    if (button === MouseButton.Right || button === 2) { return 2; }
    return -1;
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
        if (shouldResetRemoteImeOnPointerDown(this.keyboardOpen)) {
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
      } else if (event.action === MouseAction.Move || event.action === MouseAction.Hover) {
        this.queueMouseMove(mapped.x, mapped.y);
      }
      // MouseAction: Press=1, Release=2, Move=3, Hover=4, HoverExit=5
      // 滚轮事件通过 action==Move + button 判断
    } catch (err) {
      hilog.error(RD_DOMAIN, RD_TAG, 'mouse forward failed: ' + JSON.stringify(err));
    }
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
        if (Math.abs(wVp - this.surfaceWidth) < 1 && Math.abs(hVp - this.surfaceHeight) < 1 &&
          Math.abs(wPx - this.renderWidthPx) < 1 && Math.abs(hPx - this.renderHeightPx) < 1) {
          return;
        }
        this.surfaceWidth = wVp;
        this.surfaceHeight = hVp;
        this.renderWidthPx = wPx;
        this.renderHeightPx = hPx;
        if (this.handleVisible) {
          this.handleX = this.handleSide === 'left' ?
            this.modifierHiddenLeftX() : this.modifierHiddenRightX(this.surfaceWidth);
          this.clampModifierPanelsIntoView();
        }
        hilog.info(RD_DOMAIN, RD_TAG, 'surface area=' + Math.round(wVp).toString() + 'x' +
          Math.round(hVp).toString() + 'vp render=' + wPx.toString() + 'x' + hPx.toString() + 'px');
        // resizeRenderer 告诉 GL 渲染器实际的 EGL surface 像素尺寸,
        // 使 contain/letterbox viewport 计算与表面一致。必须调用。
        if (this.rendererHandle > 0 && wPx > 0 && hPx > 0) {
          this.loader.resizeRenderer(this.rendererHandle, wPx, hPx);
        }
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
        .backgroundColor('rgba(0,0,0,0.01)')
        .hitTestBehavior(HitTestMode.Block)
        .onTouch(this.handleConfiguredTouchInput)
        .onMouse(this.handleXComponentMouse)
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
          viewScaleMode: this.rustdeskViewScaleMode,
          imageQuality: this.rustdeskImageQuality,
          codec: this.rustdeskCodec,
          showLocalCursor: this.rustdeskShowLocalCursor,
          browseMode: this.rustdeskBrowseMode,
          relativeMouseMode: this.rustdeskRelativeMouseMode,
          reverseWheel: this.rustdeskReverseWheel,
          swapMouseButtons: this.rustdeskSwapMouseButtons,
          touchpadSpeed: this.rustdeskTouchpadSpeed,
          capabilities: this.currentSessionCapabilities(),
          actions: this.rustDeskTopBarActions()
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

      if (this.connected && this.shouldShowTouchIndicator()) {
        Stack() {
          Stack()
            .width(this.getTouchIndicatorRingSize())
            .height(this.getTouchIndicatorRingSize())
            .borderRadius(this.getTouchIndicatorRingSize() / 2)
            .backgroundColor('rgba(0,0,0,0.08)')
            .border({ width: this.touchIndicatorButton === TOUCH_INDICATOR_BUTTON_DRAG ? 2 : 1.5,
              color: this.getTouchIndicatorColor() })
          Column()
            .width(this.getTouchIndicatorDotSize())
            .height(this.getTouchIndicatorDotSize())
            .borderRadius(2)
            .backgroundColor(this.getTouchIndicatorColor())
        }
        .width(this.getTouchIndicatorOuterSize())
        .height(this.getTouchIndicatorOuterSize())
        .position({
          x: this.touchIndicatorX - this.getTouchIndicatorOuterSize() / 2,
          y: this.touchIndicatorY - this.getTouchIndicatorOuterSize() / 2
        })
        .animation({ duration: 180, curve: Curve.EaseOut })
        .hitTestBehavior(HitTestMode.None)
      }

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

      // PC/键鼠模式不再显示底部工具栏, 避免覆盖或扰动远端画面。
      if (this.connected && this.isDesktopDevice && this.breakpoint === 'xl' &&
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
          backgroundColor: Color.Transparent,
          blurStyle: BlurStyle.NONE,
          showClose: false,
          maskColor: 'rgba(0,0,0,0.48)',
          onDisappear: (): void => { this.handleRdpSessionErrorSheetDisappear(); }
        })

      // Pro RustDesk 鉴权必须使用纵向底部 bindSheet；不能在横屏远程画布上用全屏 overlay。
      Column().width('100%').height('100%').hitTestBehavior(HitTestMode.None)
        .bindSheet($$this.showRustDeskAuthSheet, this.rustDeskAuthChoiceBuilder(), {
          height: SheetSize.FIT_CONTENT,
          preferType: SheetType.BOTTOM,
          dragBar: true,
          backgroundColor: Color.Transparent,
          blurStyle: BlurStyle.NONE,
          showClose: false,
          maskColor: 'rgba(0,0,0,0.58)',
          onWillDismiss: (action: DismissSheetAction): void => {
            this.handleRustDeskAuthSheetDismiss(action);
          },
          onDisappear: (): void => { this.handleRustDeskAuthSheetDisappear(); }
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
        .position({ x: 0, y: 0 })
        .hitTestBehavior(HitTestMode.Transparent)
        .defaultFocus(false)
        .focusOnTouch(true)
        .enableKeyboardOnFocus(true)
        .enablePreviewText(REMOTE_IME_PREVIEW_ENABLED)
        .selectionMenuHidden(true)
        .enterKeyType(EnterKeyType.Send)
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
            ' open=' + (this.keyboardOpen ? 'true' : 'false'));
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
      backgroundColor: this.pal().bg,
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
    .backgroundColor(this.pal().bg)
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
    .width('100%')
    .padding({ top: 8, bottom: 24 })
    .backgroundColor(this.pal().bg)
  }
}
