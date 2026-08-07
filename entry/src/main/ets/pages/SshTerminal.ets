/**
 * SshTerminal.ets v5 — 推送式 SSH 终端页 (Phase 4 统一输入模型)
 *
 * ## 输入模型 (单向: 输入→SSH, 显示←SSH echo)
 *
 *   软键盘 (手机/平板):
 *     onWill* 记录并放行, onDid* exactly-once 提交 → bounded enqueue
 *
 *   物理/系统键盘:
 *     onKeyPreIme → SshTerminalInputPolicy → bounded enqueue；未识别的 IME 组合态放行给 onWillInsert
 *
 *   通用 (fallback):
 *     onChange 更新本地影子/预编辑状态；非系统 IME 的稳定差异作为 fallback
 *     提交一次；PC 粘贴 → handlePaste
 *
 * ## 防重复设计
 *   - onWill* 不发送，onDid* 消费一次 pending mutation 后发送
 *   - 系统 IME 的 onDid* 已提交时 onChange 不重复发送；非系统 IME 只发送稳定 shadow diff
 *   - PreviewText 始终留在本地，不把候选态当成终端输入
 *   - 移动端 onPaste 返回后直接忽略, 避免和软键盘输入路径重复
 *   - PC 端 Ctrl+V 是唯一粘贴路径 (onPaste 保留)
 *
 * ## 数据流
 *   输入 → SSH bounded writer → 远端 shell → echo → readerLoop → termOutput → 终端渲染
 *   终端显示完全来自 SSH echo, 本地输入不参与显示
 */
import { KeyboardAvoidMode, promptAction, router, window } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { pasteboard, BusinessError } from '@kit.BasicServicesKit';
import { fileIo } from '@kit.CoreFileKit';
import { inputDevice, KeyCode } from '@kit.InputKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { HostSyncService } from '../services/HostSyncService';
import { ExtensionLoader } from '../services/ExtensionLoader';
import { KeyVaultService } from '../services/KeyVaultService';
import { RemoteHost } from '../model/RemoteHost';
import { Palette, buildDark, buildLight } from '../common/Theme';
import { showLockGate, lockGateErrorMessage } from '../components/LockGate';
import { SshXtermSurface, XtermOutputBuffer } from '../components/SshXtermSurface';
import { GpuTerminalRenderer } from '../components/GpuTerminalRenderer';
import { TerminalInputBuffer } from '../components/SshTerminalSurface';
import { TerminalCoreBridge } from '../napi/TerminalCoreBridge';
import { SshTerminalRendererBridge } from '../napi/SshTerminalRendererBridge';
import { SshTerminalTranscriptStore } from '../services/SshTerminalTranscriptStore';
import {
  SessionConfig,
  SftpFileEntry,
  SftpListAsyncResult,
  SshJumpHop,
  SshJumpHopHandoff,
  SshPrivateKeyInfo,
  SshRoute,
  SshRouteType,
  SshAuthPrompt,
  SshAuthPromptRequest,
  SshAuthPromptResponse,
  SshTerminalInputEnqueueResult,
  TerminalCoreMode
} from '../types/rdpnapi';
import { SshPreflightService } from '../services/SshPreflightService';
import {
  SshTerminalBackgroundInfo,
  SshTerminalBackgroundTaskService
} from '../services/SshTerminalBackgroundTaskService';
import {
  SshTerminalPipInfo,
  SshTerminalPipService
} from '../services/SshTerminalPipService';
import {
  terminalLogicalViewportHeight,
  terminalTouchDragScrollLines,
  terminalVisualBottomOffset,
} from '../services/SshTerminalScrollPolicy';
import {
  SshEncodedKey,
  TerminalModifierState,
  SshImeCallbackState,
  createSshImeCallbackState,
  recordSshImeWillInsert,
  consumeSshImeDidInsert,
  recordSshImeWillDelete,
  consumeSshImeDidDelete,
  inspectSshImeChange,
  resetSshImeShadow,
  encodePhysicalKey,
  encodeSoftDelete,
  encodeTextInput
} from '../services/SshTerminalInputPolicy';
import {
  defaultSshTerminalOrientation,
  SshTerminalOrientation,
  toggleSshTerminalOrientation
} from '../services/SshTerminalOrientationPolicy';
import {
  SshTerminalTabStore,
  SshTerminalTabView,
  SshTerminalTabState
} from '../services/SshTerminalTabStore';
import { TerminalCoreRegistry } from '../services/TerminalCoreRegistry';
import { SshTerminalRendererRegistry } from '../services/SshTerminalRendererRegistry';
import {
  makeSshTerminalSurfaceBindingKey,
  makeSshTerminalSurfaceRenderKey
} from '../services/SshTerminalSurfaceBindingPolicy';
import {
  makeSshXtermTabCoreKey,
  sshXtermTabRenderRevision
} from '../services/SshXtermTabSurfacePolicy';
import { VirtualKeyBar } from '../components/VirtualKeyBar';
import { normalizeSshTerminalLineSpacing } from '../services/SshSettingsPolicy';
import {
  TransferSession,
  TransferStage,
  cancelTransfer,
  pauseTransfer,
  recordConfirmedUploadWrite,
  resumeTransfer,
  shouldShowTransferCancelAction,
  transferProgressPanelHeight
} from '../services/TransferSessionPolicy';
import {
  SshSftpCheckpoint,
  SshSftpFileIdentity,
  sshSftpCommitSizeMatches,
  sshSftpIdentityMatches,
  sshSftpOffsetIsValid,
  sshSftpPartialSuffix
} from '../services/SshSftpIntegrityPolicy';
import {
  SshSftpTaskDirection,
  SshSftpTaskRecord,
  SshSftpTaskStage,
  SftpEndpointKind
} from '../services/SshSftpTaskPolicy';
import {
  SshSftpBatchTaskEnqueueResult,
  SshSftpTaskStore
} from '../services/SshSftpTaskStore';
import {
  SshSftpTaskEngine,
  SshSftpTaskEngineEvent,
  SshSftpEngineSession
} from '../services/SshSftpTaskEngine';
import {
  SshLocalFileProvider,
  SshLocalFileEntry,
  SshLocalProviderSnapshot
} from '../services/SshLocalFileProvider';
import {
  DEFAULT_SSH_SFTP_BATCH_LIMITS,
  SshSftpConflictPolicy,
  SshSftpBatchLimits,
  SshSftpTreeItem,
  nextSshSftpKeepBothName,
  planSshSftpBatch,
  resolveSshSftpConflict
} from '../services/SshSftpBatchPolicy';
import {
  noteSshSftpSheetDismissed,
  sftpPeerPickerExitPending
} from '../services/SheetTransitionPolicy';
// Passphrase uses bindSheet (SshTerminal is @Entry, no bindSheet limit)

const SFTP_MAX_TRANSFER_BYTES: number = 512 * 1024 * 1024;
const SFTP_UPLOAD_CHUNK_BYTES: number = 64 * 1024;
const SFTP_DOWNLOAD_CHUNK_BYTES: number = 64 * 1024;
const SFTP_LIST_TIMEOUT_MS: number = 10000;
const SFTP_BATCH_LIMITS: SshSftpBatchLimits = {
  maxDepth: DEFAULT_SSH_SFTP_BATCH_LIMITS.maxDepth,
  maxItems: DEFAULT_SSH_SFTP_BATCH_LIMITS.maxItems,
  maxFiles: DEFAULT_SSH_SFTP_BATCH_LIMITS.maxFiles,
  maxTotalBytes: DEFAULT_SSH_SFTP_BATCH_LIMITS.maxTotalBytes,
  maxSingleFileBytes: SFTP_MAX_TRANSFER_BYTES,
  maxPathLength: DEFAULT_SSH_SFTP_BATCH_LIMITS.maxPathLength,
  allowSymbolicLinks: false,
  allowSpecialFiles: false
};
const SFTP_DURABILITY_UNSUPPORTED: number = -56;
const SFTP_CONFLICT: number = -409;
const SSH_STATE_CONNECTING: number = 1;
const SSH_STATE_CONNECTED: number = 2;
const SSH_STATE_RECONNECTING: number = 3;
const SSH_INPUT_PASTE_CHUNK_CHARS: number = 4096;
const SSH_INPUT_PENDING_DATA_MAX_BYTES: number = 512 * 1024;
const SSH_INPUT_PENDING_CONTROL_MAX_BYTES: number = 32 * 1024;
const SSH_OUTPUT_QUEUE_MAX_CHUNKS: number = 512;
const SSH_OUTPUT_QUEUE_MAX_BYTES: number = 8 * 1024 * 1024;
const SSH_NATIVE_RENDERER_READY_TIMEOUT_MS: number = 1500;
/**
 * A surface can be created after several ArkUI turns during an in-page tab
 * switch. Keep the page-owned refresh fence alive for a bounded window so a
 * refresh watch delivered before XComponent attach cannot strand the target
 * host with a connected socket and a stale frame.
 */
const SSH_TERMINAL_SURFACE_WAKE_INTERVAL_MS: number = 64;
const SSH_TERMINAL_SURFACE_WAKE_RETRIES: number = 12;

interface PendingTerminalInput {
  /** Monotonic ArkUI admission order used to keep a later paste behind older input. */
  order: number;
  data: string;
  control: boolean;
  /** Paste chunks share a non-preemptive lane with their bracket markers. */
  ordered: boolean;
  orderedEnd: boolean;
}

type SftpRemoteCommitResult = 'failed' | 'skipped' | 'committed' | 'committed-session-stale';

type SftpConflictAction = 'cancel' | 'skip' | 'keepBoth' | 'overwrite';

interface SftpConflictDecision {
  action: SftpConflictAction;
  applyToBatch: boolean;
}

interface SftpRemoteConflictPlan {
  action: 'failed' | 'skip' | 'keepBoth' | 'overwrite';
  policy: SshSftpConflictPolicy;
  targetPath: string;
  errorCode: number;
}

interface SftpLocalConflictPlan {
  action: 'failed' | 'skip' | 'keepBoth' | 'overwrite';
  policy: SshSftpConflictPolicy;
  targetPath: string;
}

interface TerminalDecodedChunk {
  text: string;
  remainder: Uint8Array;
}

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
  /** Observable identity of the host currently rendered by this page. */
  @State visibleSshHostId: string = '';
  @State sshTabViews: SshTerminalTabView[] = [];
  @State showSshTabPicker: boolean = false;
  /** 当前 SSH 输出 chunk；终端核心拥有 scrollback，不在页面累计完整历史。 */
  @State termOutput: string = '';
  /**
   * 原始 SSH 输出 chunk 的稳定载体；Native terminal core 直接消费字节，避免
   * UTF-8/VT 损坏。必须是普通字段：ArrayBuffer 不能进 @State/@Prop（观察代理
   * 会让 byteLength 访问抛 “don't have internal slot” 闪退）。
   */
  /** xterm 页面未完成加载时的有序输出 FIFO，按主机隔离。 */
  private xtermOutputBuffers: Map<string, XtermOutputBuffer> =
    new Map<string, XtermOutputBuffer>();
  /** Last ready document revision per SSH tab; switching tabs does not clear it. */
  private xtermReadyGenerations: Map<string, number> = new Map<string, number>();
  /** 即使连续两个 chunk 文本相同，也用序号触发终端核心消费。 */
  @State termOutputSequence: number = 0;
  /** 由成熟终端前端/VT 状态驱动的输入模式；保留给虚拟功能栏策略。 */
  @State bracketedPasteEnabled: boolean = false;
  @State terminalMouseTracking: number = 0;
  @State terminalSgrMouse: boolean = false;
  @State terminalApplicationCursorKeys: boolean = false;
  @State terminalApplicationKeypad: boolean = false;
  @StorageLink('currentBreakpoint') @Watch('onFontSizeChange') breakpoint: string = 'sm';
  @StorageProp('isDesktopDevice') isDesktopDevice: boolean = false;
  @StorageProp('isPadDevice') isPadDevice: boolean = false;
  @StorageLink('sshTerminalFontSize') @Watch('onFontSizeChange') fontSize: number = 18;
  @StorageLink('sshTerminalLineSpacing') @Watch('onLineSpacingChange') lineSpacing: number = 1.12;
  /** 0=自动, 1=虚拟键盘, 2=实体键鼠; persisted from the SSH settings card. */
  @StorageLink('sshInputMode') @Watch('onSshInputModeChange') sshInputMode: number = 0;
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
  /** 外接键盘存在时，实体按键不应再触发系统软键盘。 */
  @State physicalKeyboardConnected: boolean = false;
  /** 与 RDP/RustDesk 保持一致：记录外接键盘或鼠标设备是否存在。 */
  @State externalKeyboardMouseConnected: boolean = false;
  /** 终端焦点模式：Tab 发送给远端；Shift+Tab 退出并交回应用焦点链。 */
  @State terminalFocusMode: boolean = true;
  @State softKeyboardRequested: boolean = false;
  @State terminalFocusRequest: number = 0;
  @State xtermReady: boolean = false;
  /**
   * The SSH socket can stay alive while the visible terminal is rebound to a
   * different host. Keep the WebView mounted only after that binding has
   * installed its callback and replay buffer; this prevents ArkUI from
   * coalescing an old and new host into one stale document.
   */
  @State terminalSurfaceMounted: boolean = false;
  /** Forces the xterm surface to observe every same-page SSH host switch. */
  @State terminalSurfaceGeneration: number = 0;
  /** Observable identity for the currently mounted xterm document. */
  @State terminalSurfaceBindingKey: string = '';
  /** Forces renderer prop reconciliation even when a host/session is reused. */
  @State terminalSurfaceRenderRevision: number = 0;
  /** Stable page-owned slot; the host binding changes in place. */
  @State terminalSurfaceViewKey: string = '';
  /** Host id captured by the same commit that publishes the visible surface. */
  @State terminalSurfaceCommittedHostId: string = '';
  /** Monotonic commit id used as the actual ArkUI renderer-list identity. */
  @State terminalSurfaceCommitSequence: number = 0;
  /** Explicit repaint fence for a committed visible host binding. */
  @State terminalSurfaceRefreshRequest: number = 0;
  /** Pad/PC native renderer failure is scoped to this visible binding only. */
  @State nativeRendererUnavailable: boolean = false;
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
  /** One-shot keyboard-interactive/MFA prompt currently owned by this page. */
  @State sshAuthPrompt: SshAuthPromptRequest | null = null;
  @State sshAuthPromptValues: string[] = [];
  @State showSshAuthPromptSheet: boolean = false;
  /** SFTP 文件传输面板 */
  @State showSftpPanel: boolean = false;
  @State showSftpSheet: boolean = false;
  @State sftpPath: string = '.';
  @State sftpEntries: SftpFileEntry[] = [];
  @State sftpSelectedPath: string = '';
  @State sftpSelectedName: string = '';
  @State sftpSelectedIsDir: boolean = false;
  @State sftpSelectedSize: number = 0;
  private sftpSelectedMtime: number = -1;
  @State sftpPathInput: string = '.';
  @State sftpNameInput: string = '';
  @State sftpBusy: boolean = false;
  @State sftpStatus: string = '打开后会加载远端当前目录。';
  @State sftpProgress: number = -1;
  @State sftpProgressLabel: string = '处理中';
  @State sftpTransferSession: TransferSession | null = null;
  @State sftpPickerBusy: boolean = false;
  @State sftpLocalProviderStatus: string = '本机传输箱';
  @State sftpLocalPath: string = '';
  @State sftpLocalEntries: SshLocalFileEntry[] = [];
  @State sftpLocalSelectedUri: string = '';
  @State sftpLocalSelectedName: string = '';
  @State sftpLocalSelectedIsDir: boolean = false;
  @State sftpLocalSelectedSize: number = 0;
  /** The left pane is always the current SSH host; the right endpoint starts empty. */
  @State sftpRightEndpoint: SftpEndpointKind = 'local';
  @State sftpRightEndpointChosen: boolean = false;
  @State sftpPeerHostId: string = '';
  @State sftpPeerHostPicker: boolean = false;
  @State sftpPeerPath: string = '.';
  @State sftpPeerPathInput: string = '.';
  @State sftpPeerEntries: SftpFileEntry[] = [];
  @State sftpPeerSelectedPath: string = '';
  @State sftpPeerSelectedName: string = '';
  @State sftpPeerSelectedIsDir: boolean = false;
  @State sftpPeerSelectedSize: number = 0;
  @State sftpPeerBusy: boolean = false;
  @State sftpPeerStatus: string = '选择 SSH 主机后浏览远端目录';
  @State sftpRecoveredTasks: SshSftpTaskRecord[] = [];
  @State isLandscape: boolean = false;
  // Kept only in-memory to retry the current picker grant; never logged or placed in diagnostics.
  private sftpTransferUri: string = '';
  private sftpTransferRemotePath: string = '';
  private sftpTransferFinalUri: string = '';
  private sftpTransferPartialRemotePath: string = '';
  private sftpTransferPartialMtime: number = -1;
  private sftpTransferSourceMtime: number = -1;
  private sftpTransferRemoteMtime: number = -1;
  private sftpTransferSourceSize: number = -1;
  private sftpTransferRemoteSize: number = -1;
  private sftpTransferCheckpoint: SshSftpCheckpoint | null = null;
  private sftpTransferConflictPolicy: SshSftpConflictPolicy = 'ask';
  private sftpTransferGeneration: number = 0;
  private sftpTransferSessionId: number = -1;
  private sftpTransferPageGeneration: number = 0;
  private sftpCancelRequested: boolean = false;
  private sftpPauseRequested: boolean = false;
  private sftpTransferTaskSequence: number = 0;
  private sftpTaskSequence: number = 0;
  private sftpAtomicCommitErrorCode: number = 0;
  private sftpTaskStore: SshSftpTaskStore = SshSftpTaskStore.getInstance();
  private sftpTaskEngine: SshSftpTaskEngine = SshSftpTaskEngine.getInstance();
  private sftpLocalProvider: SshLocalFileProvider = new SshLocalFileProvider();
  private sftpBatchLocalRoots: Map<string, string> = new Map<string, string>();
  private sftpBatchRemoteRoots: Map<string, string> = new Map<string, string>();
  private sftpBatchConflictPolicies: Map<string, SshSftpConflictPolicy> =
    new Map<string, SshSftpConflictPolicy>();
  private sftpEngineBatchId: string = '';
  private sftpEngineBatchTargetHostId: string = '';
  private sftpBatchRunning: boolean = false;
  private sftpTaskUnsubscribe: (() => void) | null = null;
  private sftpEngineUnsubscribe: (() => void) | null = null;
  private sftpDetached: boolean = false;
  private sftpWaitingForConnection: boolean = false;
  private sftpPeerSelectedMtime: number = -1;
  private sftpPeerSessionId: number = -1;
  private sftpPeerSessionGeneration: number = 0;
  private sftpPeerConnectPromise: Promise<number> | null = null;
  private sftpPeerConnectHostId: string = '';
  private sftpPeerRequestToken: number = 0;
  private explicitSessionClose: boolean = false;
  private sshBackgroundTaskService: SshTerminalBackgroundTaskService =
    SshTerminalBackgroundTaskService.getInstance();
  private sshPipService: SshTerminalPipService = SshTerminalPipService.getInstance();
  private sshTabStore: SshTerminalTabStore = SshTerminalTabStore.getInstance();
  private sshTranscriptStore: SshTerminalTranscriptStore =
    SshTerminalTranscriptStore.getInstance();
  private terminalCoreRegistry: TerminalCoreRegistry = TerminalCoreRegistry.getInstance();
  private sshTerminalRendererRegistry: SshTerminalRendererRegistry =
    SshTerminalRendererRegistry.getInstance();
  /** Native VT input queues are retained per host while its surface is hidden. */
  private nativeTerminalInputBuffers: Map<string, TerminalInputBuffer> =
    new Map<string, TerminalInputBuffer>();
  /** Transcript decoding is independent from the xterm fallback decoder. */
  private terminalTranscriptDecodeRemainders: Map<string, Uint8Array> =
    new Map<string, Uint8Array>();
  /** Fallback decoding is also kept per host so a hidden tab cannot split UTF-8. */
  private terminalFallbackDecodeRemainders: Map<string, Uint8Array> =
    new Map<string, Uint8Array>();
  private sshTabStoreUnsubscribe: (() => void) | null = null;
  /** Serializes same-page SSH tab activation and prevents overlapping rebinds. */
  private tabSwitchInFlight: boolean = false;
  /** Separates old-surface teardown from the next surface mount by one frame. */
  private terminalSurfaceMountTimer: number = -1;
  private terminalSurfaceMountToken: number = 0;
  /** Wakes a newly committed renderer after ArkUI has created its surface. */
  private terminalSurfaceCommitWakeTimer: number = -1;
  /** Retries a mount that observes the live session during a state transition. */
  private terminalSurfaceMountRetryCount: number = 0;
  /** Prevents repeated connected-state probes from starving one mount turn. */
  private terminalSurfacePendingBindingKey: string = '';
  /** Bounds a native surface that never reports ready; xterm is the fallback. */
  private terminalRendererReadyTimer: number = -1;
  /** 功能开关: true=使用 Rust terminal_core 渲染 (NativeTerminalRenderer), false=旧 TerminalEmulator */

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
  private sftpRefreshTimeoutTimer: number = -1;
  private sftpRefreshRequestToken: number = 0;
  private sftpRefreshOwnerToken: number = 0;
  private sftpPanelOpenedAt: number = 0;
  /** Root and nested SFTP sheets must not mount or dismiss in the same frame. */
  private sftpRootSheetOpenTimer: number = -1;
  private sftpSheetTransitionToken: number = 0;
  /** Native callbacks are tied to the root sheet instance that mounted them. */
  private sftpRootSheetMountToken: number = 0;
  /** Reopen requests are held until the previous native sheet has disappeared. */
  private sftpRootSheetReopenRequested: boolean = false;
  private sftpRootSheetClosing: boolean = false;
  private sftpCloseRootAfterPeerPicker: boolean = false;
  /** Prevent a late nested-picker callback from closing a newer picker. */
  private sftpPeerHostPickerMountToken: number = 0;
  /** The nested picker also has an exit animation; do not remount it early. */
  private sftpPeerHostPickerOpenTimer: number = -1;
  private sftpPeerHostPickerTransitionToken: number = 0;
  private sftpPeerHostPickerReopenRequested: boolean = false;
  private sftpPeerHostPickerClosing: boolean = false;
  private latencyProbeRunning: boolean = false;
  /** Identifies the currently outstanding latency request across reconnects. */
  private latencyProbeToken: number = 0;
  private sshAuthPromptPollTimer: number = -1;
  private sshAuthPromptRequestId: number = 0;
  private sshAuthPromptSubmitting: boolean = false;
  // Native snapshot() can briefly outlive respond()/cancel() while the owner
  // reactor wakes. Keep the handled identity so that window does not reopen
  // the same prompt before the next MFA round is published.
  private sshAuthPromptHandledSessionId: number = 0;
  private sshAuthPromptHandledGeneration: number = 0;
  private sshAuthPromptHandledRequestId: number = 0;
  private terminalClosing: boolean = false;
  private terminalPanStartOffsetY: number = 0;
  private terminalPanLastLines: number = 0;
  private terminalMouseDownButton: number = -1;
  private oldKeyboardAvoidMode: KeyboardAvoidMode = KeyboardAvoidMode.OFFSET;
  private keyboardAvoidModeChanged: boolean = false;
  private sshHost: string = '';
  private sshPort: number = 22;
  /** 进入 SSH 终端前的系统状态栏文字颜色, 用于离开时恢复 */
  private savedStatusBarColor: string = '#E6E6E6';
  private terminalDecoder: util.TextDecoder = new util.TextDecoder('utf-8');
  private terminalDecodeRemainder: Uint8Array = new Uint8Array(0);
  private terminalOutputQueue: ArrayBuffer[] = [];
  private terminalOutputQueueBytes: number = 0;
  private terminalOutputFlushTimer: number = -1;
  private terminalInputFlushTimer: number = -1;
  private terminalInputControlPending: PendingTerminalInput[] = [];
  private terminalInputDataPending: PendingTerminalInput[] = [];
  private terminalInputOrderedPending: PendingTerminalInput[] = [];
  private terminalInputControlPendingBytes: number = 0;
  private terminalInputDataPendingBytes: number = 0;
  private terminalInputOrderedPendingBytes: number = 0;
  private terminalInputOrder: number = 0;
  private sshSessionGeneration: number = 0;
  /** Invalidates connect/dialog/callback continuations when the page is rebuilt. */
  private pageGeneration: number = 0;
  /** Invalidates async SSH work when the visible host changes in-place. */
  private sshBindingGeneration: number = 0;
  private terminalOutputQueueOverflowed: boolean = false;
  private inputDeviceListenerRegistered: boolean = false;
  private inputDeviceRefreshEpoch: number = 0;
  private physicalKeyboardDeviceIds: Array<number> = [];
  private imeCallbackState: SshImeCallbackState = createSshImeCallbackState();

  private inputDeviceListener: Callback<inputDevice.DeviceListener> =
    (data: inputDevice.DeviceListener): void => {
      this.refreshPhysicalKeyboardPresence('device-' + data.type);
    };

  private clearTerminalInputQueue(): void {
    if (this.terminalInputFlushTimer !== -1) {
      clearTimeout(this.terminalInputFlushTimer);
      this.terminalInputFlushTimer = -1;
    }
    this.terminalInputControlPending = [];
    this.terminalInputDataPending = [];
    this.terminalInputOrderedPending = [];
    this.terminalInputControlPendingBytes = 0;
    this.terminalInputDataPendingBytes = 0;
    this.terminalInputOrderedPendingBytes = 0;
    this.terminalInputOrder = 0;
  }

  /**
   * Keep the SSH page aware of external keyboard hot-plug state. The state is
   * used only for input routing and layout; it never changes the SSH session.
   */
  private async refreshPhysicalKeyboardPresence(reason: string): Promise<void> {
    const epoch: number = ++this.inputDeviceRefreshEpoch;
    let keyboardConnected: boolean = false;
    let keyboardMouseConnected: boolean = false;
    const keyboardIds: Array<number> = [];
    try {
      const ids: Array<number> = await inputDevice.getDeviceList();
      for (let index: number = 0; index < ids.length; index++) {
        try {
          const device: inputDevice.InputDeviceData = await inputDevice.getDeviceInfo(ids[index]);
          const sources: Array<inputDevice.SourceType> = device.sources ?? [];
          if (sources.indexOf('keyboard') >= 0) {
            keyboardConnected = true;
            keyboardIds.push(ids[index]);
          }
          if (sources.indexOf('keyboard') >= 0 || sources.indexOf('mouse') >= 0) {
            keyboardMouseConnected = true;
          }
        } catch (deviceErr) {
          hilog.warn(0x0001, 'SshTerminal',
            '[inputDevice] inspect failed id=' + ids[index].toString() +
            ' err=' + JSON.stringify(deviceErr));
        }
      }
    } catch (err) {
      hilog.warn(0x0001, 'SshTerminal',
        '[inputDevice] refresh failed reason=' + reason + ' err=' + JSON.stringify(err));
      return;
    }
    if (epoch !== this.inputDeviceRefreshEpoch || this.terminalClosing) { return; }
    const changed: boolean = this.physicalKeyboardConnected !== keyboardConnected;
    const externalChanged: boolean =
      this.externalKeyboardMouseConnected !== keyboardMouseConnected;
    this.physicalKeyboardDeviceIds = keyboardIds;
    this.physicalKeyboardConnected = keyboardConnected;
    this.externalKeyboardMouseConnected = keyboardMouseConnected;
    if (changed || externalChanged) {
      hilog.info(0x0000, 'SshTerminal',
        '[inputDevice] keyboard=' + (keyboardConnected ? 'connected' : 'disconnected') +
        ' keyboardMouse=' + (keyboardMouseConnected ? 'connected' : 'disconnected') +
        ' changed=' + (changed ? '1' : '0') +
        ' externalChanged=' + (externalChanged ? '1' : '0') + ' reason=' + reason);
      if (keyboardConnected && (this.breakpoint === 'sm' || this.sshInputMode !== 1)) {
        // A connected physical keyboard owns the fast path and should not
        // resurrect a stale software-IME session.
        this.softKeyboardRequested = false;
        if (this.connected && this.sessionId > 0) {
          this.focusKeyboard(false);
        }
      }
    }
  }

  private registerInputDeviceWatcher(): void {
    if (this.inputDeviceListenerRegistered) { return; }
    try {
      inputDevice.on('change', this.inputDeviceListener);
      this.inputDeviceListenerRegistered = true;
      this.refreshPhysicalKeyboardPresence('watcher-registered');
    } catch (err) {
      hilog.warn(0x0001, 'SshTerminal',
        '[inputDevice] watcher unavailable: ' + JSON.stringify(err));
    }
  }

  private unregisterInputDeviceWatcher(): void {
    if (!this.inputDeviceListenerRegistered) { return; }
    try {
      inputDevice.off('change', this.inputDeviceListener);
    } catch (_err) {
      // Device services can already be torn down during Ability destruction.
    }
    this.inputDeviceListenerRegistered = false;
    this.inputDeviceRefreshEpoch++;
    this.physicalKeyboardDeviceIds = [];
    this.physicalKeyboardConnected = false;
    this.externalKeyboardMouseConnected = false;
  }

  private isPhysicalKeyboardEvent(event: KeyEvent): boolean {
    try {
      if (event.keySource === KeySource.Keyboard) { return true; }
    } catch (_err) {
      // Older API 23 builds may expose keySource only at runtime.
    }
    const deviceId: number | undefined = event.deviceId;
    return this.physicalKeyboardConnected && deviceId !== undefined &&
      this.physicalKeyboardDeviceIds.indexOf(deviceId) >= 0;
  }

  private isKnownPhysicalKeyboardEvent(event: KeyEvent): boolean {
    const deviceId: number | undefined = event.deviceId;
    return deviceId !== undefined && this.physicalKeyboardDeviceIds.indexOf(deviceId) >= 0;
  }

  private isPageGenerationActive(generation: number): boolean {
    return !this.terminalClosing && this.pageGeneration === generation;
  }

  private isSshBindingGenerationActive(pageGeneration: number, bindingGeneration: number): boolean {
    return this.isPageGenerationActive(pageGeneration) &&
      this.sshBindingGeneration === bindingGeneration;
  }

  private isSshBindingActive(pageGeneration: number, bindingGeneration: number,
    hostId: string): boolean {
    return this.isSshBindingGenerationActive(pageGeneration, bindingGeneration) &&
      this.hostId.trim() === hostId.trim();
  }

  private sshAuthPromptSessionId(): number {
    // connectSshAsync publishes its reserved native session id before KEX and
    // authentication complete. Prefer that id so PAM/MFA prompts are visible
    // while the promise is still pending; fall back to the attached tab after
    // the pending connect is consumed or detached.
    const pendingOrCurrent: number = this.loader.getSessionId();
    return pendingOrCurrent > 0 ? pendingOrCurrent : this.sessionId;
  }

  private sshAuthPromptGeneration(sessionId: number): number {
    if (sessionId === this.sessionId && this.sshSessionGeneration > 0) {
      return this.sshSessionGeneration;
    }
    if (sessionId <= 0) { return 0; }
    return this.loader.getSshTerminalDiagnostics(sessionId).sessionGeneration;
  }

  private clearSshAuthPromptState(): void {
    this.showSshAuthPromptSheet = false;
    this.sshAuthPrompt = null;
    this.sshAuthPromptValues = [];
    this.sshAuthPromptRequestId = 0;
    this.sshAuthPromptSubmitting = false;
  }

  private cancelSshAuthPrompt(): void {
    const prompt: SshAuthPromptRequest | null = this.sshAuthPrompt;
    if (prompt !== null && prompt.requestId > 0) {
      this.sshAuthPromptHandledSessionId = prompt.sessionId;
      this.sshAuthPromptHandledGeneration = prompt.generation;
      this.sshAuthPromptHandledRequestId = prompt.requestId;
      // The request identity comes from the broker snapshot, not from the
      // currently visible tab. This also handles a prompt from a detached
      // SFTP peer while the main tab remains active.
      this.loader.cancelSshAuthPrompt(prompt.sessionId, prompt.generation, prompt.requestId);
    }
    this.clearSshAuthPromptState();
  }

  private pollSshAuthPrompt(): void {
    if (this.terminalClosing) { return; }
    const sessionId: number = this.sshAuthPromptSessionId();
    const generation: number = this.sshAuthPromptGeneration(sessionId);
    if (sessionId <= 0 || generation <= 0) { return; }
    const prompt: SshAuthPromptRequest | null = this.loader.getSshAuthPrompt(sessionId, generation);
    if (prompt === null) {
      if (this.showSshAuthPromptSheet && !this.sshAuthPromptSubmitting) {
        this.clearSshAuthPromptState();
      }
      return;
    }
    if (prompt.sessionId !== sessionId || prompt.generation !== generation ||
      prompt.prompts.length === 0) { return; }
    if (prompt.expiresAtMs > 0 && prompt.expiresAtMs <= Date.now()) {
      this.sshAuthPromptHandledSessionId = prompt.sessionId;
      this.sshAuthPromptHandledGeneration = prompt.generation;
      this.sshAuthPromptHandledRequestId = prompt.requestId;
      this.loader.cancelSshAuthPrompt(prompt.sessionId, prompt.generation, prompt.requestId);
      this.clearSshAuthPromptState();
      return;
    }
    if (prompt.sessionId === this.sshAuthPromptHandledSessionId &&
      prompt.generation === this.sshAuthPromptHandledGeneration &&
      prompt.requestId === this.sshAuthPromptHandledRequestId) {
      return;
    }
    if (this.showSshAuthPromptSheet && this.sshAuthPromptRequestId === prompt.requestId) {
      return;
    }
    const values: string[] = [];
    for (let index: number = 0; index < prompt.prompts.length; index++) {
      values.push('');
    }
    this.sshAuthPrompt = prompt;
    this.sshAuthPromptValues = values;
    this.sshAuthPromptRequestId = prompt.requestId;
    this.sshAuthPromptSubmitting = false;
    this.showSshAuthPromptSheet = true;
  }

  private startSshAuthPromptPolling(): void {
    if (this.sshAuthPromptPollTimer !== -1) { return; }
    this.pollSshAuthPrompt();
    this.sshAuthPromptPollTimer = setInterval((): void => {
      this.pollSshAuthPrompt();
    }, 160);
  }

  private stopSshAuthPromptPolling(cancelPending: boolean): void {
    if (this.sshAuthPromptPollTimer !== -1) {
      clearInterval(this.sshAuthPromptPollTimer);
      this.sshAuthPromptPollTimer = -1;
    }
    if (cancelPending) {
      this.cancelSshAuthPrompt();
    } else {
      this.clearSshAuthPromptState();
    }
  }

  private updateSshAuthPromptValue(index: number, value: string): void {
    if (index < 0 || index >= this.sshAuthPromptValues.length) { return; }
    const values: string[] = this.sshAuthPromptValues.slice();
    values[index] = value;
    this.sshAuthPromptValues = values;
  }

  private submitSshAuthPrompt(): void {
    const prompt: SshAuthPromptRequest | null = this.sshAuthPrompt;
    if (prompt === null || this.sshAuthPromptSubmitting ||
      this.sshAuthPromptValues.length !== prompt.prompts.length) { return; }
    const responseValues: string[] = this.sshAuthPromptValues.slice();
    this.sshAuthPromptSubmitting = true;
    this.sshAuthPromptHandledSessionId = prompt.sessionId;
    this.sshAuthPromptHandledGeneration = prompt.generation;
    this.sshAuthPromptHandledRequestId = prompt.requestId;
    const accepted: boolean = this.loader.respondSshAuthPrompt({
      schemaVersion: prompt.schemaVersion,
      requestId: prompt.requestId,
      sessionId: prompt.sessionId,
      generation: prompt.generation,
      responses: responseValues,
      cancelled: false
    } as SshAuthPromptResponse);
    if (!accepted) {
      this.sshAuthPromptSubmitting = false;
      promptAction.showToast({ message: '认证请求已失效，请重新连接', duration: 1800 });
      this.clearSshAuthPromptState();
      return;
    }
    // Do not retain password/OTP material while the native broker advances to
    // a possible next keyboard-interactive round.
    this.clearSshAuthPromptState();
  }

  @Builder
  SshAuthPromptSheet() {
    Column() {
      if (this.sshAuthPrompt !== null) {
        Row() {
          Column() {
            Text('SSH 需要额外认证')
              .fontSize(18).fontWeight(FontWeight.Medium).fontColor(this.pal().text)
            Text(this.sshAuthPrompt!.targetHost)
              .fontSize(12).fontColor(this.pal().text2).margin({ top: 4 })
              .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          }.alignItems(HorizontalAlign.Start).layoutWeight(1)
          Text('第 ' + this.sshAuthPrompt!.round.toString() + ' 轮')
            .fontSize(11).fontColor(this.pal().text3)
        }.width('100%').alignItems(VerticalAlign.Center)

        if (this.sshAuthPrompt!.hop.trim().length > 0) {
          Text('跳板: ' + this.sshAuthPrompt!.hop)
            .fontSize(11).fontColor(this.pal().text2).margin({ top: 8 })
            .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        if (this.sshAuthPrompt!.name.trim().length > 0) {
          Text(this.sshAuthPrompt!.name)
            .fontSize(12).fontColor(this.pal().text).margin({ top: 10 })
            .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        if (this.sshAuthPrompt!.instruction.trim().length > 0) {
          Text(this.sshAuthPrompt!.instruction)
            .fontSize(12).fontColor(this.pal().text2).margin({ top: 6 })
            .maxLines(6).textOverflow({ overflow: TextOverflow.Ellipsis })
        }

        Scroll() {
          Column({ space: 10 }) {
            ForEach(this.sshAuthPrompt!.prompts, (item: SshAuthPrompt, index: number): void => {
              Column() {
                Text(item.text.length > 0 ? item.text : '请输入认证响应')
                  .fontSize(12).fontColor(this.pal().text)
                  .width('100%').maxLines(3)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                TextInput({
                  placeholder: item.echo ? '输入响应' : '输入密码或验证码',
                  text: this.sshAuthPromptValues[index]
                })
                  .type(item.echo ? InputType.Normal : InputType.Password)
                  .enableAutoFill(false)
                  .height(42).width('100%')
                  .backgroundColor(this.pal().surface)
                  .fontColor(this.pal().text).placeholderColor(this.pal().text3)
                  .borderRadius(8).padding({ left: 12, right: 12 })
                  .onChange((value: string): void => {
                    this.updateSshAuthPromptValue(index, value);
                  })
                  .onSubmit((): void => { this.submitSshAuthPrompt(); })
              }.width('100%').alignItems(HorizontalAlign.Start)
            }, (item: SshAuthPrompt, index: number): string => index.toString())
          }.width('100%')
        }
          .width('100%')
          .constraintSize({ maxHeight: this.isDesktopDevice ? 560 : 480 })
          .margin({ top: 16 })
          .scrollBar(BarState.Auto)

        Row() {
          Button('取消')
            .height(40).layoutWeight(1)
            .backgroundColor(this.pal().surface).fontColor(this.pal().text2)
            .borderRadius(8)
            .enabled(!this.sshAuthPromptSubmitting)
            .onClick((): void => { this.cancelSshAuthPrompt(); })
          Button(this.sshAuthPromptSubmitting ? '提交中...' : '提交')
            .height(40).layoutWeight(1).margin({ left: 10 })
            .backgroundColor(this.accentColor).fontColor('#FFFFFF')
            .borderRadius(8)
            .enabled(!this.sshAuthPromptSubmitting)
            .onClick((): void => { this.submitSshAuthPrompt(); })
        }.width('100%').margin({ top: 16 })
      }
    }
      .width('100%')
      .constraintSize({ maxWidth: this.isDesktopDevice ? 560 : 620 })
      .padding({ left: 20, right: 20, top: 20, bottom: 20 })
      .backgroundColor(this.pal().sheetBg)
  }

  /**
   * Keep the visible SSH surface on the mature xterm.js path for now. On API
   * 23, OH_Drawing_SurfaceFlush can abort the whole process after a stale
   * XComponent BufferQueue is reported as 41207000; ArkTS cannot catch that
   * native GPU abort. The native VT core remains available for later work,
   * but it must not own a user-visible surface until that backend is safe.
   */
  private nativeTerminalFormFactor(): boolean {
    return false;
  }

  private shouldUseNativeTerminal(): boolean {
    return this.nativeTerminalFormFactor() && !this.nativeRendererUnavailable;
  }

  /**
   * Renderer props are valid only after host, binding key and mount state have
   * crossed the same page-owned commit. This prevents an intermediate ArkUI
   * turn from pairing a new surface with the previous host's input buffer.
   */
  private terminalSurfaceBindingReady(): boolean {
    const committedHostId: string = this.terminalSurfaceCommittedHostId.trim();
    return this.terminalSurfaceMounted && this.terminalSurfaceBindingKey.trim().length > 0 &&
      committedHostId.length > 0 && committedHostId === this.hostId.trim() &&
      committedHostId === this.visibleSshHostId.trim();
  }

  private terminalSurfaceVisible(): boolean {
    return this.terminalSurfaceBindingReady() && this.xtermReady;
  }

  /**
   * A stale WebView must never drain the next host's pending transcript. Keep
   * the fallback queue owned by the host binding, not by the page singleton.
   */
  private xtermOutputBufferForHost(hostId: string): XtermOutputBuffer {
    const key: string = hostId.trim();
    let buffer: XtermOutputBuffer | undefined = this.xtermOutputBuffers.get(key);
    if (buffer === undefined) {
      buffer = new XtermOutputBuffer();
      this.xtermOutputBuffers.set(key, buffer);
    }
    return buffer;
  }

  private clearXtermOutputBuffers(): void {
    this.xtermOutputBuffers.forEach((buffer: XtermOutputBuffer): void => {
      buffer.clear();
    });
    this.xtermOutputBuffers.clear();
    this.xtermReadyGenerations.clear();
  }

  private xtermSurfaceCoreKey(hostId: string): string {
    return makeSshXtermTabCoreKey(hostId);
  }

  private xtermSurfaceIdentityForHost(hostId: string, revision: number): string {
    const coreKey: string = this.xtermSurfaceCoreKey(hostId);
    if (coreKey.length === 0) { return ''; }
    return coreKey + ':render:' + sshXtermTabRenderRevision(revision).toString();
  }

  private xtermSurfaceGenerationForHost(hostId: string): number {
    const normalizedHostId: string = hostId.trim();
    return sshXtermTabRenderRevision(this.sshTabStore.sessionGeneration(normalizedHostId));
  }

  private xtermSurfaceReadyForHost(hostId: string): boolean {
    const normalizedHostId: string = hostId.trim();
    if (normalizedHostId.length === 0) { return false; }
    return this.xtermReadyGenerations.get(normalizedHostId) ===
      this.xtermSurfaceGenerationForHost(normalizedHostId);
  }

  private markXtermSurfaceNotReady(hostId: string): void {
    const normalizedHostId: string = hostId.trim();
    if (normalizedHostId.length > 0) { this.xtermReadyGenerations.delete(normalizedHostId); }
    if (normalizedHostId === this.hostId.trim()) { this.xtermReady = false; }
  }

  private nativeTerminalInputBuffer(hostId: string): TerminalInputBuffer {
    const normalizedHostId: string = hostId.trim();
    let buffer: TerminalInputBuffer | undefined = this.nativeTerminalInputBuffers.get(normalizedHostId);
    if (buffer === undefined) {
      buffer = new TerminalInputBuffer();
      this.nativeTerminalInputBuffers.set(normalizedHostId, buffer);
    }
    return buffer;
  }

  private clearNativeTerminalBuffers(): void {
    this.nativeTerminalInputBuffers.forEach((buffer: TerminalInputBuffer): void => {
      buffer.clear();
    });
    this.nativeTerminalInputBuffers.clear();
    this.terminalTranscriptDecodeRemainders.clear();
    this.terminalFallbackDecodeRemainders.clear();
  }

  private refreshSshTabViews(): void {
    // Always publish a fresh array. The store can notify several times during
    // one attach, and ArkUI must observe each state transition independently.
    this.sshTabViews = this.sshTabStore.views().slice();
    if (this.hostId.trim().length > 0) {
      this.xtermReady = this.xtermSurfaceReadyForHost(this.hostId);
    }
  }

  /**
   * Invalidate the visible terminal before adopting another SSH binding. The
   * binding key is observable; hostId itself is intentionally page-owned and
   * is not sufficient to drive an ArkUI rebuild.
   */
  private resetTerminalSurfaceBinding(): void {
    this.markXtermSurfaceNotReady(this.hostId);
    this.terminalSurfaceMountToken++;
    if (this.terminalSurfaceMountTimer !== -1) {
      clearTimeout(this.terminalSurfaceMountTimer);
      this.terminalSurfaceMountTimer = -1;
    }
    if (this.terminalSurfaceCommitWakeTimer !== -1) {
      clearTimeout(this.terminalSurfaceCommitWakeTimer);
      this.terminalSurfaceCommitWakeTimer = -1;
    }
    if (this.terminalRendererReadyTimer !== -1) {
      clearTimeout(this.terminalRendererReadyTimer);
      this.terminalRendererReadyTimer = -1;
    }
    this.terminalSurfacePendingBindingKey = '';
    this.terminalSurfaceMountRetryCount = 0;
    this.terminalSurfaceBindingKey = '';
    // Remove the visible child before the next binding is committed. Native
    // renderer handles remain in the per-host registry, so this only releases
    // the transient XComponent/WebView surface and makes the next document
    // lifecycle deterministic.
    this.terminalSurfaceRenderRevision = this.terminalSurfaceRenderRevision + 1;
    this.terminalSurfaceCommitSequence = this.terminalSurfaceCommitSequence + 1;
    this.terminalSurfaceViewKey = '';
    this.terminalSurfaceCommittedHostId = '';
    this.terminalSurfaceMounted = false;
    this.xtermReady = false;
  }

  /** Commit one visible host binding after the session callback is installed. */
  private commitTerminalSurfaceBinding(bindingHostId: string, bindingKey: string): boolean {
    const normalizedHostId: string = bindingHostId.trim();
    const normalizedBindingKey: string = bindingKey.trim();
    if (normalizedHostId.length === 0 || normalizedBindingKey.length === 0) { return false; }
    const nextRenderRevision: number = this.terminalSurfaceRenderRevision + 1;
    const nextViewKey: string = makeSshTerminalSurfaceRenderKey(normalizedHostId,
      normalizedBindingKey, nextRenderRevision, this.shouldUseNativeTerminal());
    if (nextViewKey.length === 0) { return false; }

    const nextCommitSequence: number = this.terminalSurfaceCommitSequence + 1;
    // Populate every prop consumed by the renderer before publishing the
    // ForEach key. ArkUI may schedule a render between state assignments; the
    // key is deliberately last so a new child can never be born with an empty
    // committed host and then miss the remaining prop transition.
    this.terminalSurfaceBindingKey = normalizedBindingKey;
    this.terminalSurfaceRenderRevision = nextRenderRevision;
    this.terminalSurfaceCommittedHostId = normalizedHostId;
    this.terminalSurfaceCommitSequence = nextCommitSequence;
    this.termOutputSequence = this.termOutputSequence + 1;
    this.terminalSurfaceRefreshRequest = this.terminalSurfaceRefreshRequest + 1;
    this.terminalSurfaceMounted = true;
    this.terminalSurfaceViewKey = nextViewKey;
    this.scheduleTerminalSurfaceCommitWake(normalizedHostId, normalizedBindingKey,
      nextRenderRevision, nextCommitSequence);
    return true;
  }

  /**
   * The first XComponent frame can be created after the page commit. Advance
   * both wake counters once more on the next UI turn so a reused renderer drains
   * the target host FIFO and repaints even when initial @Watch delivery was
   * coalesced with the keyed child creation.
   */
  private scheduleTerminalSurfaceCommitWake(hostId: string, bindingKey: string,
    renderRevision: number, commitSequence: number, attempt: number = 0): void {
    if (this.terminalSurfaceCommitWakeTimer !== -1) {
      clearTimeout(this.terminalSurfaceCommitWakeTimer);
      this.terminalSurfaceCommitWakeTimer = -1;
    }
    const pageGeneration: number = this.pageGeneration;
    const bindingGeneration: number = this.sshBindingGeneration;
    this.terminalSurfaceCommitWakeTimer = setTimeout((): void => {
      this.terminalSurfaceCommitWakeTimer = -1;
      if (!this.isSshBindingGenerationActive(pageGeneration, bindingGeneration) ||
        this.hostId.trim() !== hostId.trim() ||
        this.terminalSurfaceBindingKey.trim() !== bindingKey.trim() ||
        this.terminalSurfaceRenderRevision !== renderRevision ||
        this.terminalSurfaceCommitSequence !== commitSequence ||
        !this.terminalSurfaceMounted || !this.connected) {
        return;
      }
      this.termOutputSequence = this.termOutputSequence + 1;
      this.terminalSurfaceRefreshRequest = this.terminalSurfaceRefreshRequest + 1;
      const nextAttempt: number = attempt + 1;
      // The renderer may report ready before or after this fence. Keep
      // nudging the same committed binding only while the native path is still
      // expected; a fallback renderer has its own keyed lifecycle and does not
      // need this native retry loop.
      if (this.shouldUseNativeTerminal() && !this.xtermReady &&
        nextAttempt < SSH_TERMINAL_SURFACE_WAKE_RETRIES) {
        this.scheduleTerminalSurfaceCommitWake(hostId, bindingKey, renderRevision,
          commitSequence, nextAttempt);
      }
    }, attempt === 0 ? 32 : SSH_TERMINAL_SURFACE_WAKE_INTERVAL_MS);
  }

  /**
   * Mount the new WebView on a later UI turn. This makes the old WebView's
   * aboutToDisappear and the new document's aboutToAppear separate commits,
   * which prevents a fast tab switch from being coalesced into one stale DOM.
   */
  private scheduleTerminalSurfaceMount(pageGeneration: number, bindingGeneration: number,
    bindingHostId: string, bindingSessionId: number): void {
    if (bindingSessionId <= 0 || !this.isSshBindingActive(pageGeneration, bindingGeneration, bindingHostId) ||
      this.terminalClosing) {
      return;
    }
    // The visible renderer is xterm.js. Each tab owns its WebView, so a normal
    // host switch only changes the active tab and must never clear the shared
    // page binding or schedule a destroy/recreate cycle.
    if (!this.shouldUseNativeTerminal()) {
      const surfaceKey: string = this.xtermSurfaceCoreKey(bindingHostId);
      if (surfaceKey.length === 0) { return; }
      this.terminalSurfaceMounted = true;
      this.terminalSurfaceCommittedHostId = bindingHostId.trim();
      this.terminalSurfaceBindingKey = surfaceKey;
      this.terminalSurfaceRenderRevision = sshXtermTabRenderRevision(
        this.sshTabStore.sessionGeneration(bindingHostId));
      this.terminalSurfaceViewKey = surfaceKey;
      this.xtermReady = this.xtermSurfaceReadyForHost(bindingHostId);
      return;
    }
    const bindingKey: string = makeSshTerminalSurfaceBindingKey(bindingHostId,
      this.terminalSurfaceGeneration, bindingGeneration, bindingSessionId);
    if (bindingKey.length === 0) { return; }
    if (this.terminalSurfaceMounted && this.terminalSurfaceBindingKey === bindingKey) {
      return;
    }
    if (this.terminalSurfaceMountTimer !== -1 &&
      this.terminalSurfacePendingBindingKey === bindingKey) {
      return;
    }
    // A native state probe can request the same binding while the previous
    // mount turn is still pending. Replace that turn with the newest binding
    // instead of silently leaving the page behind the loading view.
    if (this.terminalSurfaceMountTimer !== -1) {
      clearTimeout(this.terminalSurfaceMountTimer);
      this.terminalSurfaceMountTimer = -1;
    }
    this.terminalSurfaceMounted = false;
    this.xtermReady = false;
    this.terminalSurfaceBindingKey = '';
    if (this.terminalSurfacePendingBindingKey !== bindingKey) {
      this.terminalSurfaceMountRetryCount = 0;
    }
    const mountToken: number = ++this.terminalSurfaceMountToken;
    this.terminalSurfacePendingBindingKey = bindingKey;
    this.terminalSurfaceMountTimer = setTimeout((): void => {
      this.terminalSurfaceMountTimer = -1;
      this.terminalSurfacePendingBindingKey = '';
      if (mountToken !== this.terminalSurfaceMountToken || this.terminalClosing) {
        return;
      }
      if (!this.isSshBindingActive(pageGeneration, bindingGeneration, bindingHostId) ||
        this.sessionId !== bindingSessionId) {
        return;
      }
      // Native connection state and ArkUI state can settle on adjacent turns.
      // Keep the binding pending while the current session is still connecting
      // instead of leaving the page permanently behind the loading view.
      if (!this.connected) {
        // An adopted session can report CONNECTING for one native turn after
        // resumeSshSession() even though attachSshSession() has already
        // installed the page callback and marked this binding live. Refresh
        // the native state here so the mount does not wait for the 5-second
        // latency probe to wake it up.
        const mountTokenBeforeStateSync: number = this.terminalSurfaceMountToken;
        this.syncNativeConnectionState();
        // A CONNECTED probe schedules its own mount turn. Do not let the
        // current timer commit the same binding a second time with a newer
        // revision, which can race the renderer's final prop transaction.
        if (mountTokenBeforeStateSync !== this.terminalSurfaceMountToken) {
          return;
        }
      }
      if (!this.connected) {
        if (!this.connecting || this.terminalSurfaceMountRetryCount >= 120) {
          return;
        }
        this.terminalSurfaceMountRetryCount++;
        this.terminalSurfacePendingBindingKey = bindingKey;
        this.terminalSurfaceMountTimer = setTimeout((): void => {
          this.terminalSurfaceMountTimer = -1;
          this.scheduleTerminalSurfaceMount(pageGeneration, bindingGeneration,
            bindingHostId, bindingSessionId);
        }, 32);
        return;
      }
      this.terminalSurfaceMountRetryCount = 0;
      if (!this.commitTerminalSurfaceBinding(bindingHostId, bindingKey)) { return; }
      if (this.terminalRendererReadyTimer !== -1) {
        clearTimeout(this.terminalRendererReadyTimer);
      }
      this.terminalRendererReadyTimer = setTimeout((): void => {
        this.terminalRendererReadyTimer = -1;
        if (this.isSshBindingActive(pageGeneration, bindingGeneration, bindingHostId) &&
          this.sessionId === bindingSessionId && this.terminalSurfaceMounted &&
          this.terminalSurfaceBindingKey === bindingKey && this.shouldUseNativeTerminal() &&
          !this.xtermReady) {
          hilog.warn(0x0000, 'SshTerminal',
            '[terminal] native renderer ready timeout, fallback host=' + bindingHostId);
          this.onNativeRendererUnavailable(bindingHostId, bindingKey);
        }
      }, SSH_NATIVE_RENDERER_READY_TIMEOUT_MS);
    }, 32);
  }

  private tabStateLabel(state: SshTerminalTabState): string {
    if (state === 'connecting') { return '连接中'; }
    if (state === 'reconnecting') { return '恢复中'; }
    if (state === 'error') { return '错误'; }
    return '已连接';
  }

  private sshTabHosts(): RemoteHost[] {
    return this.srv.getAllHosts().filter((host: RemoteHost): boolean => host.protocol === 'ssh');
  }

  private navigateToSshTab(host: RemoteHost): void {
    const targetHostId: string = host.id.trim();
    if (targetHostId.length === 0 || this.terminalClosing || this.tabSwitchInFlight) { return; }
    if (targetHostId === this.hostId) {
      this.showSshTabPicker = false;
      return;
    }
    this.showSshTabPicker = false;
    // Keep one page alive for the whole SSH workspace. The switch operation
    // detaches only the old session callback, adopts the target session and
    // rebinds the visible renderer; it must never route-replace the page.
    this.tabSwitchInFlight = true;
    void this.switchSshTab(host)
      .catch((err: Error): void => {
        if (this.terminalClosing) { return; }
        const message: string = err?.message || 'SSH 主机切换失败';
        this.connecting = false;
        this.connectionError = message;
        this.sshTabStore.invalidateSession(targetHostId, 'error', message);
        this.refreshSshTabViews();
        hilog.error(0x0001, 'SshTerminal', '[tab] in-page switch failed: ' + message);
      })
      .finally((): void => { this.tabSwitchInFlight = false; });
  }

  /**
   * Switch the visible SSH binding without rebuilding the route/WebView.
   * Detached native sessions remain connected and are adopted again when the
   * corresponding tab is selected. The renderer bridge can therefore keep a
   * stable page lifecycle while the native session owner keeps the socket.
   */
  private async switchSshTab(host: RemoteHost): Promise<void> {
    const targetHostId: string = host.id.trim();
    if (targetHostId.length === 0 || targetHostId === this.hostId) { return; }
    const pageGeneration: number = this.pageGeneration;
    const previousBindingGeneration: number = this.sshBindingGeneration;
    const previousHostId: string = this.hostId;

    if (host.locked) {
      const lockResult = await showLockGate(host.label, 'biometric');
      if (!this.isSshBindingGenerationActive(pageGeneration, previousBindingGeneration)) { return; }
      if (!lockResult.ok) {
        this.connectionError = lockGateErrorMessage(lockResult) || '验证未通过';
        this.connecting = false;
        this.connected = true;
        this.sshTabStore.activate(previousHostId);
        this.refreshSshTabViews();
        return;
      }
    }
    if (!this.isSshBindingGenerationActive(pageGeneration, previousBindingGeneration)) { return; }

    // The old host may finish its first async handshake while the lock gate
    // is open. Capture the session only after that await so it is detached
    // before the new binding is committed.
    const previousSessionId: number = this.sessionId;
    const bindingGeneration: number = previousBindingGeneration + 1;
    this.sshBindingGeneration = bindingGeneration;

    // Preflight credentials are page-local, but their trust is host-specific.
    // Clear the previous host's binding before opening a different tab so its
    // host key can never be used to validate the new SSH endpoint.
    this.clearPreflightBinding();

    if (previousSessionId > 0 && previousHostId.length > 0) {
      this.sftpTaskEngine.detachSession(previousHostId, previousSessionId);
      const detached: boolean = this.loader.detachSshSession(previousSessionId, previousHostId);
      if (!detached) {
        hilog.warn(0x0001, 'SshTerminal',
          '[tab] native detach fence unavailable; continuing logical handoff host=' +
          previousHostId + ' session=' + previousSessionId.toString());
      }
      // The binding generation above already invalidates callbacks owned by
      // the previous page. Keep the old native session alive when detach is
      // unavailable; its late bytes are routed to that host's retained queue.
      this.sshTabStore.update(previousHostId, 'connected', previousSessionId);
    } else {
      // A connect still in DNS/KEX has no page session yet. Cancel its
      // reserved native session before starting the target host.
      const pendingSessionId: number = this.loader.getSessionId();
      if (pendingSessionId > 0) {
        this.loader.disconnectSshSession(pendingSessionId);
        await this.loader.waitForPendingTeardown();
        if (!this.isSshBindingGenerationActive(pageGeneration, bindingGeneration)) { return; }
      }
    }

    this.hostId = targetHostId;
    this.visibleSshHostId = targetHostId;
    this.hostLabel = host.label;
    this.userAtHost = host.username + '@' + host.host + ':' + host.port.toString();
    this.sshHost = host.host;
    this.sshPort = host.port;
    // The target tab keeps its own xterm document and scrollback. Switching
    // only changes the active surface; session generation still controls a
    // rebuild when the target is actually reconnected.
    this.sshTabStore.open(targetHostId, this.hostLabel, this.userAtHost);
    this.sshTabStore.activate(targetHostId);
    this.refreshSshTabViews();

    // Reset only view-local state. The native session/core for the target tab
    // is adopted below, so the connection itself is never recreated on a tab
    // switch.
    this.sessionId = -1;
    this.sshSessionGeneration = 0;
    this.connected = false;
    this.connecting = true;
    this.connectionError = '';
    this.latencyMs = -1;
    this.stopLatencyProbe();
    this.preserveTerminalOutputQueue(previousHostId);
    this.clearTerminalOutputQueue();
    this.clearTerminalInputQueue();
    this.terminalDecodeRemainder = new Uint8Array(0);
    this.terminalOutputQueueOverflowed = false;
    this.termOutput = '';
    this.nativeRendererUnavailable = false;
    this.xtermReady = this.xtermSurfaceReadyForHost(targetHostId);
    this.bracketedPasteEnabled = false;
    this.terminalMouseTracking = 0;
    this.terminalSgrMouse = false;
    this.terminalApplicationCursorKeys = false;
    this.terminalApplicationKeypad = false;
    this.ctrlActive = false;
    this.altActive = false;
    this.shiftActive = false;
    this.kbInput = '';
    this.terminalFocusMode = true;
    this.softKeyboardRequested = false;
    this.clearSftpSheetTransitionTimers();
    ++this.sftpSheetTransitionToken;
    ++this.sftpRootSheetMountToken;
    ++this.sftpPeerHostPickerMountToken;
    ++this.sftpPeerHostPickerTransitionToken;
    this.sftpRootSheetReopenRequested = false;
    this.sftpRootSheetClosing = false;
    this.sftpCloseRootAfterPeerPicker = false;
    this.sftpPeerHostPickerReopenRequested = false;
    this.sftpPeerHostPickerClosing = false;
    this.showSftpPanel = false;
    this.showSftpSheet = false;
    this.sftpPath = '.';
    this.sftpEntries = [];
    this.sftpSelectedPath = '';
    this.sftpSelectedName = '';
    this.sftpSelectedIsDir = false;
    this.sftpLocalEntries = [];
    this.sftpRightEndpoint = 'local';
    this.sftpRightEndpointChosen = false;
    this.sftpPeerHostId = '';
    this.sftpPeerHostPicker = false;
    this.sftpPeerPath = '.';
    this.sftpPeerPathInput = '.';
    this.sftpPeerEntries = [];
    this.sftpPeerSelectedPath = '';
    this.sftpPeerSelectedName = '';
    this.sftpPeerSelectedIsDir = false;
    this.sftpPeerSelectedSize = 0;
    this.sftpPeerBusy = false;
    this.sftpPeerStatus = '选择 SSH 主机后浏览远端目录';
    this.sftpPeerSelectedMtime = -1;
    this.sftpPeerSessionId = -1;
    this.sftpPeerSessionGeneration = 0;
    this.sftpPeerRequestToken = 0;
    this.sftpRecoveredTasks = [];
    this.sftpBusy = false;
    this.sftpProgress = -1;
    this.sftpEngineBatchId = '';
    this.sftpEngineBatchTargetHostId = '';
    this.sftpWaitingForConnection = false;
    this.sftpDetached = false;
    this.refreshRecoveredSftpTasks();

    const adoptedSessionId: number = this.loader.adoptDetachedSshSession(targetHostId);
    if (adoptedSessionId > 0) {
      if (!await this.attachSshSession(pageGeneration, bindingGeneration, adoptedSessionId, targetHostId)) {
        if (this.isSshBindingActive(pageGeneration, bindingGeneration, targetHostId)) {
          await this.connect(host, pageGeneration, bindingGeneration);
        }
      }
      return;
    }

    const knownSessionId: number = this.sshTabStore.sessionId(targetHostId);
    if (knownSessionId > 0 &&
      await this.attachSshSession(pageGeneration, bindingGeneration, knownSessionId, targetHostId)) {
      return;
    }
    await this.connect(host, pageGeneration, bindingGeneration);
  }

  private closeAllSshTabs(): void {
    const sessionIds: number[] = this.sshTabStore.closeAll();
    for (let index = 0; index < sessionIds.length; index++) {
      this.loader.disconnectSshSession(sessionIds[index]);
    }
    // This also cancels a connect whose native session id is still pending and
    // is intentionally scoped to the SSH facade's current pending request.
    this.loader.disconnect();
  }

  private openSshTabPicker(): void {
    // SFTP host selection is rendered inside the existing SFTP surface. Do
    // not stack another native sheet while that surface is visible.
    if (this.showSftpPanel || this.showSftpSheet || this.sftpPeerHostPicker) { return; }
    this.showSshTabPicker = true;
  }

  @Builder
  private sshTabButton(tab: SshTerminalTabView) {
    Row() {
      Column() {
        Text(tab.label.length > 0 ? tab.label : tab.address)
          .fontSize(12).fontColor(tab.active ? '#F4F7FA' : 'rgba(242,244,247,0.76)')
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.tabStateLabel(tab.state))
          .fontSize(9).fontColor(tab.state === 'error' ? '#FF7777' : 'rgba(242,244,247,0.48)')
          .maxLines(1)
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      if (tab.active) {
        Column().width(5).height(5).borderRadius(3).backgroundColor('#34C759')
      }
    }
    .height(34)
    .width(142)
    .padding({ left: 10, right: 10 })
    .borderRadius(8)
    .backgroundColor(tab.active ? 'rgba(0,125,255,0.34)' : 'rgba(255,255,255,0.07)')
    .onClick((): void => {
      const host: RemoteHost | undefined = this.srv.getHost(tab.hostId);
      if (host !== undefined) { this.navigateToSshTab(host); }
    })
  }

  @Builder
  private sshTabStripItems() {
    Row({ space: 6 }) {
      ForEach(this.sshTabViews, (tab: SshTerminalTabView): void => {
        this.sshTabButton(tab);
      }, (tab: SshTerminalTabView): string => tab.tabId)
      Row() {
        SymbolGlyph($r('sys.symbol.plus')).fontSize(17).fontColor(['rgba(242,244,247,0.86)'])
      }
      .width(34).height(34).justifyContent(FlexAlign.Center).borderRadius(8)
      .backgroundColor('rgba(255,255,255,0.07)')
      .onClick((): void => { this.openSshTabPicker(); })
    }
    .height(40).width('100%')
    .padding({ left: 10, right: 10 })
    .justifyContent(FlexAlign.Start)
  }

  @Builder
  private sshTabStrip() {
    Column() {
      Scroll() {
        this.sshTabStripItems()
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .width('100%').height(40)
    }
    .width('100%').height(40 + this.topChromeOffset())
    .padding({ top: this.topChromeOffset() })
    .backgroundColor(this.chromeBg())
    .border({ width: { bottom: 0.5 }, color: 'rgba(255,255,255,0.08)' })
  }

  @Builder
  private sshTabStripInline() {
    Row() {
      Scroll() {
        this.sshTabStripItems()
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .width('100%').height(40)
    }
    .layoutWeight(1)
    .height(40)
    .borderRadius(10)
    .backgroundColor(this.chromeBg())
    .border({ width: { bottom: 0.5 }, color: 'rgba(255,255,255,0.08)' })
    .margin({ left: 10, right: 8 })
  }

  @Builder
  private sshTabPickerSheet() {
    Column() {
      Row() {
        Text('选择 SSH 主机').fontSize(17).fontWeight(FontWeight.Medium)
          .fontColor('#F4F7FA').layoutWeight(1)
        SymbolGlyph($r('sys.symbol.xmark')).fontSize(18).fontColor(['rgba(242,244,247,0.78)'])
          .width(34).height(34).onClick((): void => { this.showSshTabPicker = false; })
      }.width('100%').alignItems(VerticalAlign.Center)
      Scroll() {
        Column({ space: 8 }) {
          ForEach(this.sshTabHosts(), (host: RemoteHost): void => {
            Row() {
              Column() {
                Text(host.label).fontSize(14).fontColor('#F4F7FA')
                  .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                Text(host.username + '@' + host.host + ':' + host.port.toString())
                  .fontSize(11).fontColor('rgba(242,244,247,0.56)')
                  .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
              }.alignItems(HorizontalAlign.Start).layoutWeight(1)
              if (this.sshTabStore.has(host.id)) {
                Text('已打开').fontSize(10).fontColor(this.accentColor)
              }
            }
            .width('100%').height(52).padding({ left: 12, right: 12 })
            .borderRadius(8).backgroundColor('rgba(255,255,255,0.07)')
            .onClick((): void => { this.navigateToSshTab(host); })
          }, (host: RemoteHost): string => host.id)
        }.width('100%')
      }
      .layoutWeight(1).width('100%')
      .scrollBar(BarState.Off)
    }
    .width('100%').height(this.breakpoint === 'sm' ? '62%' : 420)
    .padding({ left: 16, right: 16, top: 20, bottom: 14 })
    .backgroundColor('#171D25')
    .borderRadius(this.breakpoint === 'sm'
      ? { topLeft: 20, topRight: 20, bottomLeft: 0, bottomRight: 0 } : 20)
    .constraintSize({ maxWidth: 620 })
  }

  private isSftpRequestActive(pageGeneration: number, sessionId: number,
    sessionGeneration: number): boolean {
    return this.isPageGenerationActive(pageGeneration) && this.sessionId === sessionId &&
      this.sshSessionGeneration === sessionGeneration;
  }

  private isSftpRefreshRequestActive(pageGeneration: number, sessionId: number,
    sessionGeneration: number, requestToken: number): boolean {
    return requestToken === this.sftpRefreshRequestToken &&
      requestToken === this.sftpRefreshOwnerToken &&
      this.isSftpRequestActive(pageGeneration, sessionId, sessionGeneration);
  }

  private isAltGraphEvent(event: KeyEvent): boolean {
    try {
      return event.getModifierKeyState !== undefined &&
        event.getModifierKeyState(['AltGraph']);
    } catch (_err) {
      return false;
    }
  }

  private isTerminalControlSequence(sequence: string): boolean {
    if (sequence.length === 0) { return false; }
    const first: number = sequence.charCodeAt(0);
    return first < 0x20 || first === 0x7F || first === 0x1B;
  }

  private scheduleTerminalInputFlush(): void {
    if (this.terminalInputFlushTimer !== -1 || this.terminalClosing) { return; }
    this.terminalInputFlushTimer = setTimeout((): void => {
      this.terminalInputFlushTimer = -1;
      this.flushTerminalInputQueue();
    }, 4);
  }

  /**
   * Serialize ArkUI input before the native bounded queue. A queue-full
   * response leaves the head item in place and retries later, so a slow SSH
   * channel cannot reorder or silently drop physical-key bursts/paste chunks.
   */
  private flushTerminalInputQueue(): void {
    if (this.terminalClosing || this.sessionId <= 0) { return; }
    /**
     * Submit one lane head. The lane is selected below so an ordered paste
     * cannot jump over older control/data input, while controls still retain
     * their low-latency priority after the transaction boundary.
     */
    const flushHead = (queue: PendingTerminalInput[], lane: number): number => {
      if (queue.length === 0) { return 0; }
      const item: PendingTerminalInput = queue[0];
      const result: SshTerminalInputEnqueueResult = this.loader.enqueueTerminalInput(
        this.sessionId, item.data, this.sshSessionGeneration, item.control,
        lane === 2, item.orderedEnd);
      if (result.accepted) {
        queue.shift();
        if (lane === 2) {
          this.terminalInputOrderedPendingBytes = Math.max(0,
            this.terminalInputOrderedPendingBytes - item.data.length);
        } else if (lane === 0) {
          this.terminalInputControlPendingBytes = Math.max(0,
            this.terminalInputControlPendingBytes - item.data.length);
        } else {
          this.terminalInputDataPendingBytes = Math.max(0,
            this.terminalInputDataPendingBytes - item.data.length);
        }
        return 0;
      }
      if (result.status === 'queueFull') {
        this.scheduleTerminalInputFlush();
        return 1;
      }
      // A generation/session rejection belongs to the old page/session. Do
      // not replay stale keystrokes into a newly connected host.
      this.clearTerminalInputQueue();
      return 2;
    };

    while (true) {
      let lane: number = -1;
      if (this.terminalInputOrderedPending.length > 0) {
        // Preserve every item that was produced before the paste marker.
        // Once the marker is the oldest pending item, flush the entire
        // ordered lane before considering any later control/data item.
        const boundary: number = this.terminalInputOrderedPending[0].order;
        const controlBefore: boolean = this.terminalInputControlPending.length > 0 &&
          this.terminalInputControlPending[0].order < boundary;
        const dataBefore: boolean = this.terminalInputDataPending.length > 0 &&
          this.terminalInputDataPending[0].order < boundary;
        if (controlBefore && dataBefore) {
          lane = this.terminalInputControlPending[0].order <=
            this.terminalInputDataPending[0].order ? 0 : 1;
        } else if (controlBefore) {
          lane = 0;
        } else if (dataBefore) {
          lane = 1;
        } else {
          lane = 2;
        }
      } else if (this.terminalInputControlPending.length > 0) {
        // Outside a paste transaction controls retain the reserved lane.
        lane = 0;
      } else if (this.terminalInputDataPending.length > 0) {
        lane = 1;
      } else {
        return;
      }

      const queue: PendingTerminalInput[] = lane === 2
        ? this.terminalInputOrderedPending
        : (lane === 0 ? this.terminalInputControlPending : this.terminalInputDataPending);
      if (flushHead(queue, lane) !== 0) { return; }
    }
  }

  private queueTerminalInput(data: string, control: boolean = false,
    ordered: boolean = false, orderedEnd: boolean = false): void {
    if (this.terminalClosing || this.sessionId <= 0 || data.length === 0) { return; }
    if (ordered && this.terminalInputOrderedPendingBytes + data.length >
        SSH_INPUT_PENDING_DATA_MAX_BYTES) {
      promptAction.showToast({ message: '粘贴输入队列已满，请稍后继续', duration: 1200 });
      return;
    }
    if (control && this.terminalInputControlPendingBytes + data.length >
        SSH_INPUT_PENDING_CONTROL_MAX_BYTES) {
      promptAction.showToast({ message: '控制输入队列已满，请稍后继续', duration: 1200 });
      return;
    }
    if (!control && this.terminalInputDataPendingBytes + data.length >
        SSH_INPUT_PENDING_DATA_MAX_BYTES) {
      promptAction.showToast({ message: '输入队列已满，请稍后继续', duration: 1200 });
      return;
    }
    const item: PendingTerminalInput = {
      order: ++this.terminalInputOrder, data, control, ordered, orderedEnd
    };
    if (ordered) {
      this.terminalInputOrderedPending.push(item);
      this.terminalInputOrderedPendingBytes += data.length;
    } else if (control) {
      this.terminalInputControlPending.push(item);
      this.terminalInputControlPendingBytes += data.length;
    } else {
      this.terminalInputDataPending.push(item);
      this.terminalInputDataPendingBytes += data.length;
    }
    this.flushTerminalInputQueue();
  }

  private clearTerminalOutputQueue(): void {
    if (this.terminalOutputFlushTimer !== -1) {
      clearTimeout(this.terminalOutputFlushTimer);
      this.terminalOutputFlushTimer = -1;
    }
    this.terminalOutputQueue = [];
    this.terminalOutputQueueBytes = 0;
  }

  /** Preserve bytes admitted for the old host before its visible binding moves. */
  private preserveTerminalOutputQueue(hostId: string): void {
    const normalizedHostId: string = hostId.trim();
    if (normalizedHostId.length === 0 || this.terminalOutputQueue.length === 0) { return; }
    if (this.terminalOutputFlushTimer !== -1) {
      clearTimeout(this.terminalOutputFlushTimer);
      this.terminalOutputFlushTimer = -1;
    }
    const pending: ArrayBuffer[] = this.terminalOutputQueue;
    this.terminalOutputQueue = [];
    this.terminalOutputQueueBytes = 0;
    const replayBuffer: TerminalInputBuffer = this.nativeTerminalInputBuffer(normalizedHostId);
    for (let index = 0; index < pending.length; index++) {
      const chunk: ArrayBuffer = pending[index];
      if (chunk.byteLength === 0) { continue; }
      replayBuffer.enqueue(chunk);
      const transcript: string = this.decodeTranscriptChunk(normalizedHostId, chunk);
      if (transcript.length > 0) {
        this.sshTranscriptStore.append(normalizedHostId, transcript);
      }
      const decoded: string = this.decodeTerminalChunk(chunk, normalizedHostId);
      if (decoded.length > 0) {
        this.xtermOutputBufferForHost(normalizedHostId).enqueue(decoded);
      }
    }
  }

  /** A callback can finish after detach; route that final chunk to its host. */
  private enqueueDetachedTerminalOutput(hostId: string, data: ArrayBuffer): void {
    const normalizedHostId: string = hostId.trim();
    if (this.terminalClosing || normalizedHostId.length === 0 || data.byteLength === 0 ||
      !this.sshTabStore.has(normalizedHostId)) { return; }
    this.nativeTerminalInputBuffer(normalizedHostId).enqueue(data);
    const transcript: string = this.decodeTranscriptChunk(normalizedHostId, data);
    if (transcript.length > 0) {
      this.sshTranscriptStore.append(normalizedHostId, transcript);
    }
    const decoded: string = this.decodeTerminalChunk(data, normalizedHostId);
    if (decoded.length > 0) {
      // The corresponding inactive xterm document remains mounted. Queue the
      // decoded chunk there so activating the tab resumes at its real cursor
      // and scrollback position instead of replaying a transcript snapshot.
      this.xtermOutputBufferForHost(normalizedHostId).enqueue(decoded);
    }
  }

  private scheduleTerminalOutputFlush(): void {
    if (this.terminalOutputFlushTimer !== -1) { return; }
    this.terminalOutputFlushTimer = setTimeout((): void => {
      this.terminalOutputFlushTimer = -1;
      this.flushTerminalOutput();
    }, 0);
  }

  private enqueueTerminalOutput(data: ArrayBuffer): void {
    if (this.terminalClosing || data.byteLength === 0) { return; }
    if (this.terminalOutputQueue.length >= SSH_OUTPUT_QUEUE_MAX_CHUNKS ||
      this.terminalOutputQueueBytes + data.byteLength > SSH_OUTPUT_QUEUE_MAX_BYTES) {
      if (!this.terminalOutputQueueOverflowed) {
        this.terminalOutputQueueOverflowed = true;
        hilog.error(0x0001, 'SshTerminal',
          '[output] queue overflow bytes=' + this.terminalOutputQueueBytes.toString());
        this.connectionError = 'SSH 输出过快，终端为避免静默丢字节已断开';
        promptAction.showToast({ message: 'SSH 输出过快，已断开以避免丢失终端内容', duration: 2200 });
        const requestSessionId: number = this.sessionId;
        this.clearTerminalOutputQueue();
        if (requestSessionId > 0) {
          try { this.loader.setOnDataCallback(requestSessionId, null); } catch (_e) { /* best effort */ }
        }
        this.loader.disconnect();
        this.stopLatencyProbe();
        this.sessionId = -1;
        this.sshSessionGeneration = 0;
        this.clearTerminalInputQueue();
        this.resetTerminalSurfaceBinding();
        this.connected = false;
        this.connecting = false;
      }
      return;
    }
    this.terminalOutputQueue.push(data);
    this.terminalOutputQueueBytes += data.byteLength;
    this.scheduleTerminalOutputFlush();
  }

  private flushTerminalOutput(): void {
    if (this.terminalClosing || this.terminalOutputQueue.length === 0) { return; }
    // Keep each ArkTS state update small enough for Canvas and the fallback
    // renderer while preserving every queued chunk's order.
    // Keep one page-to-Canvas batch within the renderer's per-frame budget.
    // Additional queued chunks are scheduled on the next event-loop turn.
    const maxBatchBytes: number = 256 * 1024;
    let batchBytes: number = 0;
    let batchCount: number = 0;
    let queuedChunksConsumed: number = 0;
    const firstChunk: ArrayBuffer = this.terminalOutputQueue[0];
    if (firstChunk.byteLength > maxBatchBytes) {
      // A native callback may exceed the page budget by itself. Keep the
      // remainder at the queue head so output order and queue accounting stay
      // exact while the renderer receives bounded updates.
      const boundedChunk: ArrayBuffer = firstChunk.slice(0, maxBatchBytes);
      this.terminalOutputQueue[0] = firstChunk.slice(maxBatchBytes);
      batchBytes = boundedChunk.byteLength;
      batchCount = 1;
    } else {
      while (batchCount < this.terminalOutputQueue.length &&
        batchBytes + this.terminalOutputQueue[batchCount].byteLength <= maxBatchBytes) {
        batchBytes += this.terminalOutputQueue[batchCount].byteLength;
        batchCount++;
      }
      queuedChunksConsumed = batchCount;
    }
    let merged: ArrayBuffer;
    if (firstChunk.byteLength > maxBatchBytes) {
      merged = firstChunk.slice(0, maxBatchBytes);
    } else {
      merged = new ArrayBuffer(batchBytes);
      const mergedView: Uint8Array = new Uint8Array(merged);
      let offset: number = 0;
      for (let index: number = 0; index < batchCount; index++) {
        const chunk: Uint8Array = new Uint8Array(this.terminalOutputQueue[index]);
        mergedView.set(chunk, offset);
        offset += chunk.length;
      }
    }
    // A bounded prefix from an oversized first chunk is already represented
    // by the replacement at queue[0]; remove only whole chunks consumed by
    // this batch so the remainder cannot be dropped.
    if (queuedChunksConsumed > 0) {
      this.terminalOutputQueue.splice(0, queuedChunksConsumed);
    }
    this.terminalOutputQueueBytes -= batchBytes;
    const outputHostId: string = this.hostId.trim();
    const transcriptOutput: string = this.decodeTranscriptChunk(outputHostId, merged);
    if (transcriptOutput.length > 0) {
      this.sshTranscriptStore.append(outputHostId, transcriptOutput);
    }
    if (this.shouldUseNativeTerminal()) {
      this.nativeTerminalInputBuffer(outputHostId).enqueue(merged);
      this.termOutput = transcriptOutput;
    } else {
      const decodedOutput: string = this.decodeTerminalChunk(merged);
      this.xtermOutputBufferForHost(outputHostId).enqueue(decodedOutput);
      this.termOutput = decodedOutput;
    }
    this.termOutputSequence++;
    if (this.terminalOutputQueue.length > 0) {
      this.scheduleTerminalOutputFlush();
    }
  }

  private updateCellSize(): void {
    const normalized: number = Math.max(12, Math.min(32, this.fontSize));
    this.renderFontVp = normalized;
    const rowRatio: number = normalizeSshTerminalLineSpacing(this.lineSpacing);
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

  private onLineSpacingChange(): void {
    this.updateCellSize();
    this.recalcGrid();
  }

  /** 根据 termAreaW/H + 字号反推 cols/rows, 同步到 PTY */
  private recalcGrid(): void {
    if (this.cellHvp <= 0 || this.cellWvp <= 0) { return; }
    // Once the visible xterm document is ready, its measured DOM cell size is
    // the authority for cols/rows. Recomputing from an ArkUI approximation at
    // the same time creates a resize ping-pong when font/line spacing changes.
    if (this.xtermReady) { return; }
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
    const requestPageGeneration: number = this.pageGeneration;
    const requestSessionId: number = this.sessionId;
    const requestSessionGeneration: number = this.sshSessionGeneration;
    if (this.resizePtyTimer !== -1) {
      clearTimeout(this.resizePtyTimer);
      this.resizePtyTimer = -1;
    }
    this.resizePtyTimer = setTimeout((): void => {
      this.resizePtyTimer = -1;
      if (!this.isPageGenerationActive(requestPageGeneration) ||
        this.sessionId !== requestSessionId || this.sshSessionGeneration !== requestSessionGeneration) {
        return;
      }
      this.loader.resizePty(requestSessionId, this.termCols, this.termRows);
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

  private virtualKeyBarRequested(): boolean {
    // 手机保持原有输入和底部栏逻辑；设置项只作用于 Pad/PC。
    if (this.breakpoint === 'sm') { return !this.physicalKeyboardConnected; }
    if (this.sshInputMode === 1) { return true; }
    if (this.sshInputMode === 2) { return false; }
    if (this.isDesktopDevice) { return false; }
    return !this.physicalKeyboardConnected;
  }

  private virtualKeyBarVisible(): boolean {
    // The bar belongs to the connected SSH workspace, not to the xterm boot
    // lifecycle. Its height is reserved independently, so it remains usable
    // while a retained WebView is waiting for its first ready callback.
    return this.connected && this.sshTabViews.length > 0 && this.virtualKeyBarRequested();
  }

  private virtualKeyBarHeight(): number {
    return this.virtualKeyBarRequested() ? VirtualKeyBar.TOTAL_H : 0;
  }

  private rowsBottomOffset(): number {
    // PTY rows and the visible WebView must use the same bottom boundary. The
    // old rows-only policy ignored the software keyboard while the WebView
    // excluded it, producing a second fit/resize with too many rows.
    return this.barBottomOffset();
  }

  private topChromeOffset(): number {
    if (this.isDesktopDevice) { return 0; }
    return Math.max(8, this.topSafeHeight);
  }

  private sshTabsInline(): boolean {
    // 手机继续使用原始独立标签条; Pad/PC 将标签嵌入连接顶栏。
    return this.sshTabViews.length > 0 && (this.isDesktopDevice || this.breakpoint !== 'sm');
  }

  private sshInlineHostWidth(): number {
    if (this.isDesktopDevice) { return 220; }
    return this.breakpoint === 'md' ? 160 : 200;
  }

  private headerTopOffset(): number {
    // The phone-only standalone strip owns the system top inset. Inline tabs
    // stay inside the toolbar, so the toolbar keeps the inset on Pad/PC.
    return this.sshTabViews.length > 0 && !this.sshTabsInline() ? 0 : this.topChromeOffset();
  }

  private headerHeight(): number {
    return 56 + this.headerTopOffset();
  }

  private terminalChromeHeight(): number {
    // The terminal surface is laid out below both chrome variants. Inline
    // tabs live inside the header; phone tabs have their own 40vp strip.
    const standaloneTabStripHeight: number =
      this.sshTabViews.length > 0 && !this.sshTabsInline()
        ? 40 + this.topChromeOffset() : 0;
    return standaloneTabStripHeight + this.headerHeight();
  }

  private shellViewportHeight(): number {
    if (this.shellAreaH > 0) {
      return Math.max(this.cellHvp * 3, this.shellAreaH - this.terminalChromeHeight());
    }
    return Math.max(this.cellHvp * 3, this.calcRowsFallback() * this.cellHvp);
  }

  private terminalPaneHeight(): number {
    return this.terminalRowsViewportHeight();
  }

  private terminalRowsViewportHeight(): number {
    const shellHeight: number = this.shellViewportHeight();
    return terminalLogicalViewportHeight(
      this.isDesktopDevice,
      shellHeight,
      this.cellHvp,
      this.rowsBottomOffset(),
      this.virtualKeyBarHeight()
    );
  }

  private terminalCanvasOffsetY(): number {
    // xterm is laid out in its actual viewport. The old Canvas surface used a
    // negative offset to hide the system bar and virtual key bar, which moves
    // a WebView twice when those bars are already excluded from its height.
    return 0;
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

  private terminalMouseButton(rawButton: number): number {
    if (rawButton === 1 || rawButton === 0) { return 0; }
    if (rawButton === 4) { return 1; }
    if (rawButton === 2) { return 2; }
    return -1;
  }

  private terminalMouseModifiers(event: MouseEvent | AxisEvent): number {
    let modifiers: number = 0;
    if (event.getModifierKeyState && event.getModifierKeyState(['Shift'])) { modifiers += 4; }
    if (event.getModifierKeyState && event.getModifierKeyState(['Alt'])) { modifiers += 8; }
    if (event.getModifierKeyState && event.getModifierKeyState(['Ctrl'])) { modifiers += 16; }
    return modifiers;
  }

  private terminalMousePosition(x: number, y: number): number[] {
    const col: number = Math.max(0, Math.min(this.termCols - 1, Math.floor(x / Math.max(1, this.cellWvp))));
    const row: number = Math.max(0, Math.min(this.termRows - 1, Math.floor(y / Math.max(1, this.cellHvp))));
    return [col + 1, row + 1];
  }

  private encodeTerminalMouse(button: number, col: number, row: number,
    modifiers: number, release: boolean, motion: boolean): string {
    const code: number = button + modifiers + (motion ? 32 : 0);
    if (this.terminalSgrMouse) {
      return '\u001b[<' + code.toString() + ';' + col.toString() + ';' + row.toString() +
        (release ? 'm' : 'M');
    }
    // X10 mouse release uses button 3 while preserving modifier bits.
    const legacyReleaseCode: number = 3 + modifiers;
    const legacyCode: number = Math.max(0, Math.min(223,
      32 + (release ? legacyReleaseCode : code)));
    const legacyCol: number = Math.max(33, Math.min(255, 32 + col));
    const legacyRow: number = Math.max(33, Math.min(255, 32 + row));
    return '\u001b[M' + String.fromCharCode(legacyCode, legacyCol, legacyRow);
  }

  private handleTerminalMouse = (event: MouseEvent): void => {
    if (this.selectMode || this.terminalMouseTracking === 0) { return; }
    const position: number[] = this.terminalMousePosition(event.x as number, event.y as number);
    const col: number = position[0];
    const row: number = position[1];
    const modifiers: number = this.terminalMouseModifiers(event);
    const action: MouseAction = event.action;
    const rawButton: number = event.button as number;
    const button: number = this.terminalMouseButton(rawButton);

    if (action === MouseAction.Press) {
      if (button < 0) { return; }
      this.terminalMouseDownButton = button;
      this.sendTerminalBytes(this.encodeTerminalMouse(button, col, row, modifiers, false, false), true);
    } else if (action === MouseAction.Release) {
      const releasedButton: number = button >= 0 ? button : this.terminalMouseDownButton;
      if (releasedButton >= 0) {
        this.sendTerminalBytes(this.encodeTerminalMouse(releasedButton, col, row, modifiers, true, false), true);
      }
      this.terminalMouseDownButton = -1;
    } else if (action === MouseAction.Move || action === MouseAction.Hover) {
      const reportMotion: boolean = this.terminalMouseTracking >= 1003 ||
        (this.terminalMouseTracking >= 1002 && this.terminalMouseDownButton >= 0);
      if (reportMotion) {
        const motionButton: number = this.terminalMouseDownButton >= 0 ? this.terminalMouseDownButton : 0;
        this.sendTerminalBytes(this.encodeTerminalMouse(
          motionButton, col, row, modifiers, false, true), true);
      }
    }
  };

  private handleTerminalAxis = (event: AxisEvent): void => {
    if (this.selectMode || this.terminalMouseTracking === 0) { return; }
    const raw: number = event.getVerticalAxisValue();
    if (!Number.isFinite(raw) || raw === 0) { return; }
    const position: number[] = this.terminalMousePosition(event.x as number, event.y as number);
    const wheelButton: number = raw < 0 ? 64 : 65;
    this.sendTerminalBytes(this.encodeTerminalMouse(
      wheelButton, position[0], position[1], this.terminalMouseModifiers(event), false, false), true);
  };

  private handleTerminalPanEnd(): void {
    this.terminalPanLastLines = 0;
  }

  private requestTerminalScrollToBottomSettled(): void {
    const generation: number = this.pageGeneration;
    this.requestTerminalScrollToBottom();
    setTimeout((): void => {
      if (this.isPageGenerationActive(generation)) { this.requestTerminalScrollToBottom(); }
    }, 48);
    setTimeout((): void => {
      if (this.isPageGenerationActive(generation)) { this.requestTerminalScrollToBottom(); }
    }, 140);
    setTimeout((): void => {
      if (this.isPageGenerationActive(generation)) { this.requestTerminalScrollToBottom(); }
    }, 260);
  }

  private onKeyboardInsetChange(): void {
    if (this.isDesktopDevice || !this.connected) { return; }
    this.recalcGrid();
    // 键盘收起 (kbHeight → 0) 时, terminalPaneHeight 会先增大再触发 onAreaChange→recalcGrid→PTY resize (140ms)。
    // 标准 Settled (0/48/140/260ms) 的 0ms 可能跑在 resize 之前被 followBottom=false 覆盖。
    // 扩展延迟确保键盘收起后有足够时间让 PTY resize + 布局稳定, 最末一次 scrollToBottom 做最后兜底。
    const generation: number = this.pageGeneration;
    if (this.kbHeight <= 0) {
      // 键盘已收起 — 先立即滚动, 再等 resize 做完后滚动
      this.requestTerminalScrollToBottom();
      setTimeout((): void => {
        if (this.isPageGenerationActive(generation)) { this.requestTerminalScrollToBottom(); }
      }, 200);
      setTimeout((): void => {
        if (this.isPageGenerationActive(generation)) { this.requestTerminalScrollToBottom(); }
      }, 450);
      setTimeout((): void => {
        if (this.isPageGenerationActive(generation)) { this.requestTerminalScrollToBottom(); }
      }, 700);
    } else {
      this.requestTerminalScrollToBottomSettled();
    }
  }

  private onSshInputModeChange(): void {
    if (this.breakpoint === 'sm') {
      this.recalcGrid();
      return;
    }
    if (this.sshInputMode === 2) {
      this.softKeyboardRequested = false;
      try { this.kbCtrl.stopEditing(); } catch (_err) { /* input may not be mounted */ }
    }
    this.recalcGrid();
    if (this.connected) {
      this.forceScrollToBottomRequest = this.forceScrollToBottomRequest + 1;
      this.requestTerminalScrollToBottomSettled();
    }
  }

  private async restoreSshLocalProvider(pageGeneration: number): Promise<void> {
    const snapshot: SshLocalProviderSnapshot = await this.sftpLocalProvider.restoreAuthorization();
    if (!this.isPageGenerationActive(pageGeneration)) { return; }
    if (snapshot.state === 'ready') {
      this.sftpLocalPath = snapshot.rootPath;
      this.sftpLocalProviderStatus = snapshot.rootLabel.length > 0
        ? snapshot.rootLabel : '本机传输箱';
    } else if (snapshot.state === 'needsAuthorization') {
      this.sftpLocalPath = '';
      this.sftpLocalProviderStatus = snapshot.plan.kind === 'directory'
        ? '请选择并授权本机目录' : '本机传输箱';
    } else {
      this.sftpLocalPath = '';
      this.sftpLocalProviderStatus = '本机文件能力不可用';
    }
    await this.refreshSftpLocal(pageGeneration);
  }

  private localProviderNeedsAuthorization(): boolean {
    const snapshot: SshLocalProviderSnapshot = this.sftpLocalProvider.snapshot();
    return snapshot.plan.kind === 'directory' && snapshot.state === 'needsAuthorization';
  }

  private async authorizeLocalProvider(): Promise<void> {
    if (this.sftpBusy || this.sftpPickerBusy) { return; }
    this.sftpPickerBusy = true;
    this.sftpStatus = '正在打开本机目录选择器...';
    try {
      // The terminal keeps a hidden TextInput focused for SSH input. Release it
      // before launching the system picker so the picker is attached to the
      // visible page window instead of the terminal's IME session.
      try { this.kbCtrl.stopEditing(); } catch (_err) { /* input may not be mounted */ }
      try { this.getUIContext().getFocusController().clearFocus(); } catch (_err) { /* best effort */ }
      this.softKeyboardRequested = false;
      const snapshot: SshLocalProviderSnapshot =
        await this.sftpLocalProvider.chooseAuthorizedFolder();
      if (snapshot.state === 'ready') {
        this.sftpLocalPath = snapshot.rootPath;
        this.sftpLocalSelectedUri = '';
        this.sftpLocalSelectedName = '';
        this.sftpLocalSelectedIsDir = false;
        this.sftpLocalSelectedSize = 0;
        this.sftpLocalProviderStatus = snapshot.rootLabel.length > 0
          ? snapshot.rootLabel : '已授权目录';
        this.sftpStatus = '本机目录已授权，正在刷新...';
      } else if (snapshot.plan.kind === 'directory') {
        this.sftpStatus = '本机目录授权未完成，请重新选择目录';
      }
    } catch (err) {
      this.sftpStatus = '本机目录授权失败: ' + JSON.stringify(err);
    } finally {
      this.sftpPickerBusy = false;
      await this.refreshSftpLocal(this.pageGeneration);
    }
  }

  private sortSftpLocalEntries(entries: SshLocalFileEntry[]): SshLocalFileEntry[] {
    return entries.sort((a: SshLocalFileEntry, b: SshLocalFileEntry): number => {
      if (a.isDirectory !== b.isDirectory) { return a.isDirectory ? -1 : 1; }
      return a.name.localeCompare(b.name);
    });
  }

  private refreshRecoveredSftpTasks(): void {
    const owners: string[] = [];
    const currentOwner: string = this.hostId.trim();
    if (currentOwner.length > 0) { owners.push(currentOwner); }
    const peerOwner: string = this.sftpRightEndpoint === 'ssh' ? this.sftpPeerHostId.trim() : '';
    if (peerOwner.length > 0 && owners.indexOf(peerOwner) < 0) { owners.push(peerOwner); }
    if (owners.length === 0) {
      this.sftpRecoveredTasks = [];
      return;
    }
    const restored: SshSftpTaskRecord[] = [];
    for (let ownerIndex: number = 0; ownerIndex < owners.length; ownerIndex++) {
      const ownerTasks: SshSftpTaskRecord[] = this.sftpTaskStore.list(owners[ownerIndex]);
      for (let taskIndex: number = 0; taskIndex < ownerTasks.length; taskIndex++) {
        const task: SshSftpTaskRecord = ownerTasks[taskIndex];
        if (task.stage !== 'completed' && task.stage !== 'cancelled') { restored.push(task); }
      }
    }
    this.sftpRecoveredTasks = restored
      .sort((a: SshSftpTaskRecord, b: SshSftpTaskRecord): number => b.updatedAt - a.updatedAt)
      .slice(0, 8);
  }

  private sftpTaskStageLabel(stage: SshSftpTaskStage): string {
    switch (stage) {
      case 'queued': return '排队中';
      case 'inspecting': return '检查中';
      case 'awaitingConflictDecision': return '等待冲突处理';
      case 'transferring': return '传输中';
      case 'paused': return '已暂停';
      case 'waitingForConnection': return '等待连接';
      case 'verifying': return '校验中';
      case 'committing': return '提交中';
      case 'needsAuthorization': return '需要本机授权';
      case 'needsAuthentication': return '需要重新认证';
      case 'failed': return '失败';
      case 'cancelled': return '已取消';
      case 'completed': return '已完成';
      default: return '未知状态';
    }
  }

  private onSftpEngineEvent(event: SshSftpTaskEngineEvent): void {
    const record: SshSftpTaskRecord | null = event.record;
    if (record !== null && record.hostId !== this.hostId &&
      record.hostId !== this.sftpEngineBatchTargetHostId) { return; }
    if (event.batchId.trim().length > 0) { this.sftpEngineBatchId = event.batchId; }
    if (event.kind === 'conflict' && record !== null) {
      this.sftpBusy = false;
      this.sftpTransferSession = null;
      this.sftpStatus = 'SFTP 等待处理冲突: ' + record.fileName;
      void this.resolveSftpEngineConflict(event, record);
      return;
    }
    if (event.kind === 'batchCompleted') {
      this.sftpBusy = false;
      this.sftpProgress = -1;
      this.sftpTransferSession = null;
      this.sftpEngineBatchId = '';
      this.sftpEngineBatchTargetHostId = '';
      this.sftpStatus = 'SFTP 批次已完成';
      this.refreshRecoveredSftpTasks();
      return;
    }
    if (event.kind === 'batchBlocked') {
      this.sftpBusy = false;
      this.sftpProgress = record !== null && record.totalBytes > 0
        ? Math.min(1, record.verifiedOffset / record.totalBytes) : -1;
      this.sftpStatus = event.reason === 'waiting-for-connection'
        ? 'SFTP 任务等待 SSH 会话' : 'SFTP 批次已暂停: ' + event.reason;
      if (record !== null) {
        this.sftpTransferSession = this.engineTransferSession(record, event.reason);
      }
      this.refreshRecoveredSftpTasks();
      return;
    }
    if (record === null) { return; }
    this.refreshRecoveredSftpTasks();
    this.sftpTransferSession = this.engineTransferSession(record, event.reason);
    if (record.stage === 'transferring') {
      this.sftpBusy = true;
      this.sftpProgress = record.totalBytes > 0
        ? Math.min(1, record.verifiedOffset / record.totalBytes) : 0;
      this.sftpProgressLabel = record.direction === 'upload' ? '上传中' : '下载中';
    } else if (record.stage === 'waitingForConnection' || record.stage === 'paused' ||
      record.stage === 'awaitingConflictDecision') {
      this.sftpBusy = false;
      this.sftpProgress = record.totalBytes > 0
        ? Math.min(1, record.verifiedOffset / record.totalBytes) : -1;
      this.sftpProgressLabel = this.sftpTaskStageLabel(record.stage);
    }
  }

  private engineTransferSession(record: SshSftpTaskRecord, reason: string): TransferSession {
    let stage: TransferStage = 'preparing';
    if (record.stage === 'transferring') { stage = 'transferring'; }
    else if (record.stage === 'paused') { stage = 'paused'; }
    else if (record.stage === 'waitingForConnection') { stage = 'waitingRemote'; }
    else if (record.stage === 'failed') { stage = 'failed'; }
    else if (record.stage === 'cancelled') { stage = 'cancelled'; }
    else if (record.stage === 'completed') { stage = 'completed'; }
    return {
      id: record.taskId,
      protocol: 'ssh',
      direction: record.direction,
      fileName: record.fileName,
      totalBytes: record.totalBytes >= 0 ? record.totalBytes : 0,
      transferredBytes: Math.max(0, record.verifiedOffset),
      stage,
      canCancel: stage === 'transferring' || stage === 'paused' || stage === 'waitingRemote',
      diagnosticCode: reason
    };
  }

  private async resolveSftpEngineConflict(event: SshSftpTaskEngineEvent,
    record: SshSftpTaskRecord): Promise<void> {
    if (this.terminalClosing ||
      (record.hostId !== this.hostId && record.hostId !== this.sftpEngineBatchTargetHostId)) { return; }
    const remoteToRemote: boolean = record.sourceEndpoint?.kind === 'ssh' &&
      record.targetEndpoint?.kind === 'ssh';
    const side: string = remoteToRemote ? '目标 SSH' :
      (record.direction === 'upload' ? '远端' : '本机');
    const decision: SftpConflictDecision = await this.askSftpConflictAction(record.fileName, side);
    if (this.terminalClosing) { return; }
    if (decision.action === 'cancel') {
      this.sftpTaskEngine.cancelBatch(event.batchId);
      this.sftpStatus = '已取消 SFTP 批次';
      return;
    }
    const policy: SshSftpConflictPolicy = decision.action === 'skip' ? 'skip' :
      decision.action === 'keepBoth' ? 'keepBoth' : 'overwrite';
    this.sftpTaskEngine.resolveBatchConflict(event.batchId, policy, record.taskId,
      decision.applyToBatch);
  }

  private startSftpEngineBatch(batchId: string): void {
    const id: string = batchId.trim();
    const localRoot: string | undefined = this.sftpBatchLocalRoots.get(id);
    const remoteRoot: string | undefined = this.sftpBatchRemoteRoots.get(id);
    if (id.length === 0 || localRoot === undefined || remoteRoot === undefined) {
      this.sftpStatus = '[SFTP-BATCH] 批次本机或远端根目录未绑定';
      return;
    }
    if (!this.sftpTaskEngine.bindBatch(id, this.hostId, localRoot, remoteRoot,
      this.sftpConflictPolicyForBatch(id))) {
      this.sftpStatus = '[SFTP-BATCH] 批次引擎绑定失败';
      return;
    }
    this.sftpBusy = true;
    this.sftpEngineBatchId = id;
    this.sftpEngineBatchTargetHostId = this.hostId;
    this.sftpProgress = 0;
    this.sftpProgressLabel = '准备中';
    this.sftpStatus = 'SFTP 批次开始执行';
    this.sftpTaskEngine.startBatch(id);
  }

  private startSftpRemoteEngineBatch(batchId: string, targetHostId: string): void {
    const id: string = batchId.trim();
    const owner: string = targetHostId.trim();
    if (id.length === 0 || owner.length === 0) {
      this.sftpStatus = '[SFTP-REMOTE] 批次绑定信息无效';
      return;
    }
    // Remote-to-remote tasks do not use a local provider. The engine still
    // requires non-empty roots to keep the binding contract explicit.
    if (!this.sftpTaskEngine.bindBatch(id, owner, '.', '.',
      this.sftpConflictPolicyForBatch(id))) {
      this.sftpStatus = '[SFTP-REMOTE] 双 SSH 批次绑定失败';
      return;
    }
    this.sftpBusy = true;
    this.sftpEngineBatchId = id;
    this.sftpEngineBatchTargetHostId = owner;
    this.sftpProgress = 0;
    this.sftpProgressLabel = '准备双 SSH 传输';
    this.sftpStatus = '双 SSH 传输开始执行';
    this.sftpTaskEngine.startBatch(id);
  }

  private sftpPeerHost(): RemoteHost | undefined {
    const peerId: string = this.sftpPeerHostId.trim();
    if (peerId.length === 0) { return undefined; }
    return this.srv.getHost(peerId);
  }

  private sftpPeerHostLabel(): string {
    const host: RemoteHost | undefined = this.sftpPeerHost();
    return host === undefined ? '选择 SSH 主机' : host.label;
  }

  private sftpPeerHostAddress(): string {
    const host: RemoteHost | undefined = this.sftpPeerHost();
    return host === undefined ? '' : host.username + '@' + host.host + ':' + host.port.toString();
  }

  private sshRouteTypeForHost(host: RemoteHost): SshRouteType {
    const configuredType: string = host.proxyHost.trim().length > 0 ? host.sshProxyType : 'direct';
    // legacy_gateway remains an invalid native route. Keeping the value in
    // this explicit object makes the policy reject it instead of mapping it
    // to a direct socket.
    return configuredType as SshRouteType;
  }

  private sshRouteForHost(host: RemoteHost): SshRoute {
    const routeType: SshRouteType = this.sshRouteTypeForHost(host);
    const hops: SshJumpHop[] = [];
    if (routeType === 'ssh_jump') {
      hops.push({
        host: host.proxyHost,
        port: host.proxyPort,
        username: host.proxyUsername,
        authMethod: host.sshProxyAuthMethod,
        expectedHostKeyRawBase64: host.sshJumpHostKeyRawBase64,
        expectedHostKeyFingerprintSha256: host.sshJumpHostKeyFingerprintSha256,
        connectTimeoutMs: 10000
      });
    }
    return {
      schemaVersion: 1,
      type: routeType,
      endpointHost: host.host,
      endpointPort: host.port,
      hops: hops,
      connectTimeoutMs: 10000
    };
  }

  private sshJumpHopHandoffsForHost(host: RemoteHost, privateKeyPem: string,
    privateKeyPassphrase: string): SshJumpHopHandoff[] {
    if (this.sshRouteTypeForHost(host) !== 'ssh_jump') { return []; }
    const publicKey: boolean = host.sshProxyAuthMethod === 'publickey';
    return [{
      password: publicKey ? '' : host.sshProxyPassword,
      privateKeyPem: publicKey ? privateKeyPem : '',
      privateKeyPassphrase: publicKey ? privateKeyPassphrase : '',
      keyboardInteractiveResponses: []
    }];
  }

  private sftpSessionForHost(hostId: string): SshSftpEngineSession | null {
    const owner: string = hostId.trim();
    if (owner.length === 0) { return null; }
    let sessionId: number = -1;
    let generation: number = 0;
    if (owner === this.hostId.trim()) {
      sessionId = this.sessionId;
      generation = this.sshSessionGeneration;
    } else {
      sessionId = this.sshTabStore.sessionId(owner);
      generation = this.sshTabStore.sessionGeneration(owner);
    }
    if (sessionId <= 0) { return null; }
    const state: number = this.loader.getConnectionState(sessionId);
    if (state !== SSH_STATE_CONNECTED && state !== SSH_STATE_RECONNECTING) { return null; }
    const liveGeneration: number = this.loader.getSshTerminalDiagnostics(sessionId).sessionGeneration;
    if (liveGeneration > 0) { generation = liveGeneration; }
    if (generation <= 0) { return null; }
    if (owner === this.hostId.trim() && this.sshSessionGeneration !== generation) {
      this.sshSessionGeneration = generation;
    }
    const session: SshSftpEngineSession = { hostId: owner, sessionId, generation };
    this.sftpTaskEngine.attachSession(session);
    if (owner !== this.hostId.trim()) {
      this.sftpPeerSessionId = sessionId;
      this.sftpPeerSessionGeneration = generation;
      this.sshTabStore.update(owner, state === SSH_STATE_RECONNECTING ? 'reconnecting' : 'connected',
        sessionId, '', generation);
    }
    return session;
  }

  private async buildSftpPeerSessionConfig(host: RemoteHost): Promise<SessionConfig> {
    let keyData: string = host.sshKeyData;
    let keyEncryptedHint: boolean = false;
    if (host.sshKeyId.length > 0) {
      const key = KeyVaultService.getInstance().getSshKey(host.sshKeyId);
      if (key !== undefined) {
        keyData = key.privateKey;
        keyEncryptedHint = key.privateKeyEncrypted;
      }
    }
    const useKey: boolean = host.sshUseKey && keyData.length > 0;
    let keyPassphrase: string = host.sshKeyPassphrase;
    if (useKey) {
      let keyInfo: SshPrivateKeyInfo = this.loader.inspectSshPrivateKey(keyData, keyPassphrase);
      if (keyInfo.ok && !keyInfo.encrypted) {
        keyPassphrase = '';
      } else if (keyPassphrase.length === 0 || keyEncryptedHint || !keyInfo.ok) {
        keyPassphrase = await this.promptPassphrase();
        keyInfo = this.loader.inspectSshPrivateKey(keyData, keyPassphrase);
        if (!keyInfo.ok) { throw new Error('SSH 私钥密码错误或密钥不可用'); }
      }
    }

    let proxyKeyData: string = '';
    let proxyKeyPassphrase: string = host.sshProxyKeyPassphrase;
    let proxyKeyEncryptedHint: boolean = false;
    if (host.sshProxyKeyId.length > 0) {
      const proxyKey = KeyVaultService.getInstance().getSshKey(host.sshProxyKeyId);
      if (proxyKey !== undefined) {
        proxyKeyData = proxyKey.privateKey;
        proxyKeyEncryptedHint = proxyKey.privateKeyEncrypted;
      }
    }
    if (host.sshProxyType === 'ssh_jump' && host.sshProxyAuthMethod === 'publickey') {
      if (proxyKeyData.length === 0) { throw new Error('跳板机私钥不存在'); }
      let proxyInfo: SshPrivateKeyInfo = this.loader.inspectSshPrivateKey(
        proxyKeyData, proxyKeyPassphrase);
      if (proxyInfo.ok && !proxyInfo.encrypted) {
        proxyKeyPassphrase = '';
      } else if (proxyKeyPassphrase.length === 0 || proxyKeyEncryptedHint || !proxyInfo.ok) {
        proxyKeyPassphrase = await this.promptPassphrase();
        proxyInfo = this.loader.inspectSshPrivateKey(proxyKeyData, proxyKeyPassphrase);
        if (!proxyInfo.ok) { throw new Error('跳板机私钥密码错误'); }
      }
    }
    return {
      protocol: 'ssh',
      host: host.host,
      port: host.port,
      username: host.username,
      password: host.password,
      width: this.termCols,
      height: this.termRows,
      customHostname: host.customHostname,
      gatewayHost: '',
      gatewayPort: 0,
      sshRoute: this.sshRouteForHost(host),
      sshJumpHopHandoffs: this.sshJumpHopHandoffsForHost(host, proxyKeyData, proxyKeyPassphrase),
      sshProxyType: host.proxyHost.length > 0 ? host.sshProxyType : 'direct',
      sshProxyHost: host.proxyHost,
      sshProxyPort: host.proxyPort,
      sshProxyUsername: host.proxyUsername,
      sshProxyPassword: '',
      sshProxyAuthMethod: host.sshProxyType === 'ssh_jump' ? host.sshProxyAuthMethod : undefined,
      sshProxyPrivateKeyPem: '',
      sshProxyPrivateKeyPassphrase: '',
      domain: '',
      codec: '',
      multiMonitor: false,
      monitorCount: 1,
      colorDepth: 32,
      authMethod: useKey ? 'publickey' : 'password',
      privateKeyPem: useKey ? keyData : '',
      privateKeyPassphrase: keyPassphrase,
      expectedHostKeyRawBase64: host.sshHostKeyRawBase64,
      expectedHostKeyFingerprintSha256: host.sshHostKeyFingerprintSha256,
      sshJumpHostKeyRawBase64: host.sshJumpHostKeyRawBase64,
      sshJumpHostKeyFingerprintSha256: host.sshJumpHostKeyFingerprintSha256
    };
  }

  /** Reuse a detached tab session or establish one for the right SFTP pane. */
  private async ensureSftpHostSession(hostId: string,
    requestPageGeneration: number = this.pageGeneration): Promise<SshSftpEngineSession | null> {
    const owner: string = hostId.trim();
    if (!this.isPageGenerationActive(requestPageGeneration) || owner.length === 0) { return null; }
    const existing: SshSftpEngineSession | null = this.sftpSessionForHost(owner);
    if (existing !== null) { return existing; }
    if (owner === this.hostId.trim()) { return null; }
    const host: RemoteHost | undefined = this.srv.getHost(owner);
    if (host === undefined || host.protocol !== 'ssh') { return null; }
    if (host.locked) {
      const lockResult = await showLockGate(host.label, 'biometric');
      if (!this.isPageGenerationActive(requestPageGeneration) || !lockResult.ok) {
        this.sftpPeerStatus = lockResult.ok ? 'SSH 主机验证已失效' : '验证未通过';
        return null;
      }
    }
    if (this.sftpPeerConnectPromise !== null) {
      const pending: Promise<number> = this.sftpPeerConnectPromise;
      const pendingHostId: string = this.sftpPeerConnectHostId;
      const pendingId: number = await pending;
      if (!this.isPageGenerationActive(requestPageGeneration)) { return null; }
      if (pendingHostId === owner) {
        return pendingId > 0 ? this.sftpSessionForHost(owner) : null;
      }
      // A second peer request for another host still shares this page-owned
      // operation, so wait for the existing peer task before replacing it.
      return await this.ensureSftpHostSession(owner, requestPageGeneration);
    }
    const pending: Promise<number> = (async (): Promise<number> => {
      try {
        this.sftpPeerStatus = '正在建立 ' + host.label + ' 的 SFTP 会话...';
        if (!(await this.loader.waitForPendingTeardown())) { return -1; }
        const config: SessionConfig = await this.buildSftpPeerSessionConfig(host);
        if (!this.isPageGenerationActive(requestPageGeneration)) { return -1; }
        // This session belongs to the right SFTP endpoint. Do not replace the
        // foreground terminal target while its authentication is in flight.
        const connectedSessionId: number = await this.loader.connectSshAsync(config, false);
        if (!this.isPageGenerationActive(requestPageGeneration)) {
          if (connectedSessionId > 0) { this.loader.disconnectSshSession(connectedSessionId); }
          return -1;
        }
        if (connectedSessionId <= 0) { return connectedSessionId; }
        const generation: number = this.loader.getSshTerminalDiagnostics(
          connectedSessionId).sessionGeneration;
        if (generation <= 0 || !this.loader.detachSshSession(connectedSessionId, owner)) {
          this.loader.disconnectSshSession(connectedSessionId);
          return -1;
        }
        this.sshTabStore.open(owner, host.label,
          host.username + '@' + host.host + ':' + host.port.toString());
        this.sshTabStore.update(owner, 'connected', connectedSessionId, '', generation);
        this.sftpPeerSessionId = connectedSessionId;
        this.sftpPeerSessionGeneration = generation;
        this.sftpTaskEngine.attachSession({ hostId: owner, sessionId: connectedSessionId, generation });
        return connectedSessionId;
      } catch (err) {
        hilog.warn(0x0001, 'SshTerminal', '[sftp-peer] session unavailable: ' + JSON.stringify(err));
        return -1;
      }
    })();
    this.sftpPeerConnectPromise = pending;
    this.sftpPeerConnectHostId = owner;
    const connectedSessionId: number = await pending;
    if (this.sftpPeerConnectPromise === pending) {
      this.sftpPeerConnectPromise = null;
      this.sftpPeerConnectHostId = '';
    }
    if (connectedSessionId <= 0) {
      this.sftpPeerStatus = 'SSH 主机未连接，认证未完成';
      return null;
    }
    return this.sftpSessionForHost(owner);
  }

  private selectSftpPeerHost(host: RemoteHost): void {
    if (host.protocol !== 'ssh' || host.id.trim().length === 0) { return; }
    this.sftpPeerRequestToken++;
    this.sftpRightEndpoint = 'ssh';
    this.sftpRightEndpointChosen = true;
    this.sftpPeerHostId = host.id.trim();
    this.requestSftpPeerHostPickerClose();
    this.sftpPeerPath = '.';
    this.sftpPeerPathInput = '.';
    this.sftpPeerEntries = [];
    this.sftpPeerSelectedPath = '';
    this.sftpPeerSelectedName = '';
    this.sftpPeerSelectedIsDir = false;
    this.sftpPeerSelectedSize = 0;
    this.sftpPeerSelectedMtime = -1;
    this.sftpPeerSessionId = -1;
    this.sftpPeerSessionGeneration = 0;
    this.sftpPeerBusy = false;
    this.sftpPeerStatus = '正在准备 SSH 会话...';
    this.refreshRecoveredSftpTasks();
    void this.refreshSftpPeer();
  }

  private useSftpLocalEndpoint(): void {
    this.sftpRightEndpoint = 'local';
    this.sftpRightEndpointChosen = true;
    this.requestSftpPeerHostPickerClose();
    this.sftpPeerRequestToken++;
    this.sftpPeerBusy = false;
    this.sftpPeerEntries = [];
    this.sftpPeerSelectedPath = '';
    this.sftpPeerSelectedName = '';
    this.sftpPeerSelectedIsDir = false;
    this.sftpPeerSelectedSize = 0;
    this.sftpPeerStatus = '本机传输箱';
    this.refreshRecoveredSftpTasks();
  }

  private resetSftpRightEndpointSelection(): void {
    if (this.sftpBusy) { return; }
    this.sftpRightEndpoint = 'local';
    this.sftpRightEndpointChosen = false;
    this.requestSftpPeerHostPickerClose();
    this.sftpPeerRequestToken++;
    this.sftpPeerBusy = false;
    this.sftpPeerHostId = '';
    this.sftpPeerEntries = [];
    this.sftpPeerSelectedPath = '';
    this.sftpPeerSelectedName = '';
    this.sftpPeerSelectedIsDir = false;
    this.sftpPeerSelectedSize = 0;
    this.sftpPeerSelectedMtime = -1;
    this.sftpPeerSessionId = -1;
    this.sftpPeerSessionGeneration = 0;
    this.sftpPeerStatus = '选择 SSH 主机后浏览远端目录';
    this.refreshRecoveredSftpTasks();
  }

  private isSftpPeerRequestActive(pageGeneration: number, token: number,
    hostId: string, session: SshSftpEngineSession): boolean {
    return this.isPageGenerationActive(pageGeneration) && token === this.sftpPeerRequestToken &&
      this.sftpRightEndpoint === 'ssh' && this.sftpPeerHostId === hostId &&
      this.sftpPeerSessionId === session.sessionId && this.sftpPeerSessionGeneration === session.generation;
  }

  private async refreshSftpPeer(path: string = this.sftpPeerPath): Promise<void> {
    if (this.sftpRightEndpoint !== 'ssh' || this.sftpPeerHostId.trim().length === 0 ||
      this.terminalClosing || this.sftpBusy) { return; }
    const requestPageGeneration: number = this.pageGeneration;
    const hostId: string = this.sftpPeerHostId.trim();
    const session: SshSftpEngineSession | null = await this.ensureSftpHostSession(
      hostId, requestPageGeneration);
    if (session === null) {
      if (this.isPageGenerationActive(requestPageGeneration)) {
        this.sftpPeerStatus = 'SSH 主机不可用或需要认证';
      }
      return;
    }
    if (!this.isPageGenerationActive(requestPageGeneration) ||
      this.sftpRightEndpoint !== 'ssh' || this.sftpPeerHostId !== hostId) {
      return;
    }
    const requestToken: number = ++this.sftpPeerRequestToken;
    const target: string = this.normalizeRemoteDir(path);
    this.sftpPeerBusy = true;
    this.sftpPeerStatus = '正在读取远端目录...';
    try {
      const result: SftpListAsyncResult = await this.loader.listRemoteDirAsync(
        session.sessionId, target);
      if (!this.isSftpPeerRequestActive(requestPageGeneration, requestToken, hostId, session)) { return; }
      if (result.errorCode < 0) {
        this.sftpPeerStatus = '[SFTP-LIST] 读取失败 ret=' + result.errorCode.toString();
        return;
      }
      this.sftpPeerEntries = this.sortSftpEntries(result.entries.slice());
      this.sftpPeerPath = target;
      this.sftpPeerPathInput = target;
      this.sftpPeerSelectedPath = '';
      this.sftpPeerSelectedName = '';
      this.sftpPeerSelectedIsDir = false;
      this.sftpPeerSelectedSize = 0;
      this.sftpPeerSelectedMtime = -1;
      this.sftpPeerStatus = '已加载 ' + result.entries.length.toString() + ' 项';
    } catch (_err) {
      if (this.isSftpPeerRequestActive(requestPageGeneration, requestToken, hostId, session)) {
        this.sftpPeerStatus = '[SFTP-LIST] 读取目录失败';
      }
    } finally {
      if (this.isSftpPeerRequestActive(requestPageGeneration, requestToken, hostId, session)) {
        this.sftpPeerBusy = false;
      }
    }
  }

  private selectSftpPeerEntry(entry: SftpFileEntry): void {
    this.sftpPeerSelectedPath = entry.path;
    this.sftpPeerSelectedName = entry.name;
    this.sftpPeerSelectedIsDir = entry.isDirectory;
    this.sftpPeerSelectedSize = entry.size;
    this.sftpPeerSelectedMtime = entry.mtime;
    this.sftpPeerStatus = entry.isDirectory ? '已选择目录 ' + entry.name :
      '已选择 ' + entry.name + ' (' + this.formatFileSize(entry.size) + ')';
  }

  private async scanSftpRemoteTree(rootPath: string, rootName: string,
    session: SshSftpEngineSession, requestPageGeneration: number): Promise<SshSftpTreeItem[] | null> {
    const normalizedRoot: string = this.normalizeRemoteDir(rootPath);
    const normalizedName: string = rootName.trim();
    if (!this.isSafeSftpTreeName(normalizedName)) { return null; }
    const items: SshSftpTreeItem[] = [{
      relativePath: normalizedName,
      name: normalizedName,
      isDirectory: true,
      isSymbolicLink: false,
      isSpecialFile: false,
      size: 0,
      mtime: 0,
      mode: 0,
      uid: -1,
      gid: -1
    }];
    const visit = async (directory: string, relativeDirectory: string,
      depth: number): Promise<boolean> => {
      if (depth > SFTP_BATCH_LIMITS.maxDepth || items.length >= SFTP_BATCH_LIMITS.maxItems) {
        return false;
      }
      const listed: SftpListAsyncResult = await this.loader.listRemoteDirAsync(
        session.sessionId, directory);
      const live: SshSftpEngineSession | null = this.sftpSessionForHost(session.hostId);
      if (!this.isPageGenerationActive(requestPageGeneration) || live === null ||
        live.sessionId !== session.sessionId || live.generation !== session.generation ||
        listed.errorCode < 0) { return false; }
      const entries: SftpFileEntry[] = this.sortSftpEntries(listed.entries.slice());
      for (let index: number = 0; index < entries.length; index++) {
        const entry: SftpFileEntry = entries[index];
        const name: string = entry.name.trim();
        if (!this.isSafeSftpTreeName(name) ||
          (!entry.isDirectory && (!Number.isFinite(entry.size) || entry.size < 0 ||
            !Number.isFinite(entry.mtime) || entry.mtime < 0))) { return false; }
        const relativePath: string = relativeDirectory + '/' + name;
        items.push({
          relativePath,
          name,
          isDirectory: entry.isDirectory,
          isSymbolicLink: entry.isSymbolicLink,
          isSpecialFile: entry.isSpecialFile,
          size: entry.size,
          mtime: entry.mtime,
          mode: entry.mode,
          uid: entry.uid,
          gid: entry.gid
        });
        if (items.length > SFTP_BATCH_LIMITS.maxItems) { return false; }
        if (entry.isDirectory && !entry.isSymbolicLink &&
          !await visit(this.joinRemotePath(directory, name), relativePath, depth + 1)) {
          return false;
        }
      }
      return true;
    };
    return await visit(normalizedRoot, normalizedName, 0) ? items : null;
  }

  private async refreshSftpLocal(requestPageGeneration: number = this.pageGeneration): Promise<void> {
    if (!this.isPageGenerationActive(requestPageGeneration) || this.sftpBusy) { return; }
    try {
      const requestedPath: string = this.sftpLocalPath.trim();
      const target: string = requestedPath.length > 0 ? requestedPath :
        await this.sftpLocalProvider.currentRoot();
      if (!this.isPageGenerationActive(requestPageGeneration)) { return; }
      if (target.length === 0) {
        this.sftpLocalPath = '';
        this.sftpLocalEntries = [];
        this.sftpLocalSelectedUri = '';
        this.sftpLocalSelectedName = '';
        this.sftpLocalSelectedIsDir = false;
        this.sftpLocalSelectedSize = 0;
        return;
      }
      const entries: SshLocalFileEntry[] = await this.sftpLocalProvider.list(target);
      if (!this.isPageGenerationActive(requestPageGeneration)) { return; }
      this.sftpLocalPath = target;
      this.sftpLocalEntries = this.sortSftpLocalEntries(entries);
      this.sftpLocalSelectedUri = '';
      this.sftpLocalSelectedName = '';
      this.sftpLocalSelectedIsDir = false;
      this.sftpLocalSelectedSize = 0;
    } catch (_err) {
      if (this.isPageGenerationActive(requestPageGeneration)) {
        this.sftpLocalEntries = [];
        this.sftpStatus = '[SFTP-LOCAL] 本机目录不可读，请重新授权';
      }
    }
  }

  private selectSftpLocalEntry(entry: SshLocalFileEntry): void {
    this.sftpLocalSelectedUri = entry.uri;
    this.sftpLocalSelectedName = entry.name;
    this.sftpLocalSelectedIsDir = entry.isDirectory;
    this.sftpLocalSelectedSize = entry.size;
    this.sftpStatus = entry.isDirectory ? '已选择本机目录 ' + entry.name :
      '已选择本机文件 ' + entry.name + ' (' + this.formatFileSize(entry.size) + ')';
  }

  /** Scan one selected local directory and durably enqueue its file tasks. */
  private async enqueueSftpUploadDirectory(): Promise<void> {
    if (this.sftpBusy || this.sessionId <= 0 || !this.sftpLocalSelectedIsDir ||
      this.sftpLocalSelectedUri.length === 0 || this.sftpLocalSelectedName.trim().length === 0) {
      return;
    }
    const requestPageGeneration: number = this.pageGeneration;
    const requestSessionId: number = this.sessionId;
    const requestSessionGeneration: number = this.sshSessionGeneration;
    const sourceRoot: string = this.sftpLocalSelectedUri;
    const rootName: string = this.sftpLocalSelectedName.trim();
    const remoteRoot: string = this.sftpPath;
    let queuedBatchId: string = '';
    this.sftpBusy = true;
    this.sftpStatus = '正在扫描本机目录 ' + rootName + '...';
    try {
      const scanned: SshSftpTreeItem[] = await this.sftpLocalProvider.walk(sourceRoot);
      if (!this.isSftpRequestActive(requestPageGeneration, requestSessionId,
        requestSessionGeneration)) { return; }
      const items: SshSftpTreeItem[] = [{
        relativePath: rootName,
        name: rootName,
        isDirectory: true,
        isSymbolicLink: false,
        isSpecialFile: false,
        size: 0,
        mtime: 0,
        mode: 0,
        uid: -1,
        gid: -1
      }];
      for (let index = 0; index < scanned.length; index++) {
        const item: SshSftpTreeItem = scanned[index];
        items.push({
          relativePath: rootName + '/' + item.relativePath,
          name: item.name,
          isDirectory: item.isDirectory,
          isSymbolicLink: item.isSymbolicLink,
          isSpecialFile: item.isSpecialFile,
          size: item.size,
          mtime: item.mtime,
          mode: item.mode,
          uid: item.uid,
          gid: item.gid
        });
      }
      const plan = planSshSftpBatch(items);
      if (!plan.accepted) {
        this.sftpStatus = '[SFTP-BATCH] 批量计划拒绝: ' + plan.reason;
        return;
      }
      const result: SshSftpBatchTaskEnqueueResult = this.sftpTaskStore.enqueueBatch(
        this.hostId, 'upload', remoteRoot, plan);
      if (!result.accepted) {
        this.sftpStatus = '[SFTP-BATCH] 创建任务失败: ' + result.reason;
        return;
      }
      this.sftpBatchLocalRoots.set(result.batchId, sourceRoot);
      this.sftpBatchRemoteRoots.set(result.batchId, remoteRoot);
      queuedBatchId = result.batchId;
      this.refreshRecoveredSftpTasks();
      const directoryCount: number = result.records.filter(
        (record: SshSftpTaskRecord): boolean => record.isDirectory).length;
      const fileCount: number = result.records.length - directoryCount;
      this.sftpStatus = '已加入批量上传 ' + fileCount.toString() + ' 个文件、' +
        directoryCount.toString() + ' 个目录，总计 ' + this.formatFileSize(plan.totalBytes) + '，等待执行';
    } catch (_err) {
      if (this.isSftpRequestActive(requestPageGeneration, requestSessionId,
        requestSessionGeneration)) {
        this.sftpStatus = '[SFTP-BATCH] 本机目录扫描失败';
      }
    } finally {
      if (this.isSftpRequestActive(requestPageGeneration, requestSessionId,
        requestSessionGeneration)) {
        this.sftpBusy = false;
        if (queuedBatchId.length > 0) { this.startSftpEngineBatch(queuedBatchId); }
      }
    }
  }

  /** Read a remote directory tree without following links or trusting entry paths. */
  private async scanRemoteSftpBatch(rootPath: string, rootName: string,
    requestPageGeneration: number, requestSessionId: number,
    requestSessionGeneration: number): Promise<SshSftpTreeItem[] | null> {
    const normalizedRoot: string = this.normalizeRemoteDir(rootPath);
    const normalizedName: string = rootName.trim();
    if (!this.isSafeSftpTreeName(normalizedName)) { return null; }
    const items: SshSftpTreeItem[] = [{
      relativePath: normalizedName,
      name: normalizedName,
      isDirectory: true,
      isSymbolicLink: false,
      isSpecialFile: false,
      size: 0,
      mtime: 0,
      mode: 0,
      uid: -1,
      gid: -1
    }];
    const visit = async (directory: string, relativeDirectory: string,
      depth: number): Promise<boolean> => {
      if (depth > SFTP_BATCH_LIMITS.maxDepth || items.length >= SFTP_BATCH_LIMITS.maxItems) {
        return false;
      }
      const listed: SftpListAsyncResult = await this.loader.listRemoteDirAsync(
        requestSessionId, directory);
      if (!this.isSftpRequestActive(requestPageGeneration, requestSessionId,
        requestSessionGeneration) || listed.errorCode < 0) {
        return false;
      }
      const entries: SftpFileEntry[] = this.sortSftpEntries(listed.entries.slice());
      for (let index = 0; index < entries.length; index++) {
        const entry: SftpFileEntry = entries[index];
        const name: string = entry.name.trim();
        if (!this.isSafeSftpTreeName(name)) { return false; }
        if (!entry.isDirectory && (!Number.isFinite(entry.size) || entry.size < 0 ||
          !Number.isFinite(entry.mtime) || entry.mtime < 0)) { return false; }
        const relativePath: string = relativeDirectory + '/' + name;
        items.push({
          relativePath,
          name,
          isDirectory: entry.isDirectory,
          isSymbolicLink: entry.isSymbolicLink,
          isSpecialFile: entry.isSpecialFile,
          size: entry.size,
          mtime: entry.mtime,
          mode: entry.mode,
          uid: entry.uid,
          gid: entry.gid
        });
        if (items.length > SFTP_BATCH_LIMITS.maxItems) { return false; }
        if (entry.isDirectory && !entry.isSymbolicLink) {
          const childPath: string = this.joinRemotePath(directory, name);
          if (!await visit(childPath, relativePath, depth + 1)) { return false; }
        }
      }
      return true;
    };
    return await visit(normalizedRoot, normalizedName, 0) ? items : null;
  }

  private isSafeSftpTreeName(name: string): boolean {
    const trimmed: string = name.trim();
    return trimmed.length > 0 && trimmed !== '.' && trimmed !== '..' &&
      trimmed.indexOf('/') < 0 && trimmed.indexOf('\\') < 0 && trimmed.indexOf('\0') < 0;
  }

  /** Select a destination directory and create the remote root below it. */
  private async prepareLocalSftpDownloadRoot(parentUri: string, rootName: string): Promise<string | null> {
    const parent: SshLocalFileEntry | null = await this.sftpLocalProvider.stat(parentUri);
    if (parent === null || !parent.isDirectory || parent.isSymbolicLink ||
      !this.isSafeSftpTreeName(rootName)) { return null; }
    if (parent.name === rootName) { return parent.uri; }
    return await this.ensureLocalSftpDirectory(parent.uri, rootName);
  }

  private async ensureLocalSftpDirectory(parentUri: string, name: string): Promise<string | null> {
    if (!this.isSafeSftpTreeName(name)) { return null; }
    const target: string | null = await this.sftpLocalProvider.resolveRelative(parentUri, name);
    if (target === null) { return null; }
    let existing: SshLocalFileEntry | null = await this.sftpLocalProvider.stat(target);
    if (existing !== null) {
      return existing.isDirectory && !existing.isSymbolicLink ? target : null;
    }
    if (!await this.sftpLocalProvider.createDirectory(parentUri, name)) {
      existing = await this.sftpLocalProvider.stat(target);
      return existing !== null && existing.isDirectory && !existing.isSymbolicLink ? target : null;
    }
    existing = await this.sftpLocalProvider.stat(target);
    return existing !== null && existing.isDirectory && !existing.isSymbolicLink ? target : null;
  }

  /** Ensure every directory component of a batch item exists locally. */
  private async ensureLocalSftpBatchPath(localRoot: string, relativePath: string,
    leafIsDirectory: boolean): Promise<string | null> {
    const raw: string = relativePath.replace(/\\/g, '/').trim();
    const parts: string[] = raw.length === 0 ? [] : raw.split('/');
    const componentCount: number = leafIsDirectory ? parts.length : Math.max(0, parts.length - 1);
    let current: string = localRoot;
    const rootEntry: SshLocalFileEntry | null = await this.sftpLocalProvider.stat(current);
    if (rootEntry === null || !rootEntry.isDirectory || rootEntry.isSymbolicLink) { return null; }
    for (let index = 0; index < componentCount; index++) {
      const next: string | null = await this.ensureLocalSftpDirectory(current, parts[index]);
      if (next === null) { return null; }
      current = next;
    }
    return current;
  }

  private async prepareLocalSftpConflict(parentUri: string, fileName: string,
    batchId: string): Promise<SftpLocalConflictPlan> {
    const target: string | null = await this.sftpLocalProvider.resolveRelative(parentUri, fileName);
    if (target === null) { return { action: 'failed', policy: 'ask', targetPath: '' }; }
    const existing: SshLocalFileEntry | null = await this.sftpLocalProvider.stat(target);
    if (existing === null) { return { action: 'overwrite', policy: 'overwrite', targetPath: target }; }
    if (existing.isDirectory || existing.isSymbolicLink || existing.isSpecialFile) {
      return { action: 'failed', policy: 'ask', targetPath: target };
    }
    const rememberedPolicy: SshSftpConflictPolicy = this.sftpConflictPolicyForBatch(batchId);
    const resolution = resolveSshSftpConflict(true, false, rememberedPolicy);
    let action: SftpConflictAction = resolution.action === 'skip' ? 'skip' :
      resolution.action === 'keepBoth' ? 'keepBoth' : 'overwrite';
    let policy: SshSftpConflictPolicy = action === 'skip' ? 'skip' :
      action === 'keepBoth' ? 'keepBoth' : 'overwrite';
    if (resolution.requiresDecision) {
      const decision: SftpConflictDecision = await this.askSftpConflictAction(fileName, '本机');
      action = decision.action;
      if (decision.applyToBatch && batchId.trim().length > 0 && action !== 'cancel') {
        this.sftpBatchConflictPolicies.set(batchId.trim(), action);
      }
      policy = action === 'skip' ? 'skip' : action === 'keepBoth' ? 'keepBoth' : 'overwrite';
    }
    if (action === 'cancel') { return { action: 'failed', policy: 'ask', targetPath: target }; }
    if (action === 'keepBoth') {
      const siblings: SshLocalFileEntry[] = await this.sftpLocalProvider.list(parentUri);
      const existingNames: string[] = siblings.map((entry: SshLocalFileEntry): string => entry.name);
      const keepBothName: string = nextSshSftpKeepBothName(fileName, existingNames);
      const keepBothPath: string | null = keepBothName.length === 0 ? null :
        await this.sftpLocalProvider.resolveRelative(parentUri, keepBothName);
      if (keepBothPath === null) { return { action: 'failed', policy, targetPath: target }; }
      return { action: 'keepBoth', policy, targetPath: keepBothPath };
    }
    if (action === 'overwrite' && !await this.sftpLocalProvider.remove(target, false)) {
      return { action: 'failed', policy, targetPath: target };
    }
    return { action, policy, targetPath: target };
  }

  private completeSftpBatchFileTask(task: SshSftpTaskRecord): boolean {
    this.sftpTaskSequence = Math.max(this.sftpTaskSequence + 1, Date.now());
    return this.sftpTaskStore.upsert({
      taskId: task.taskId,
      batchId: task.batchId,
      relativePath: task.relativePath,
      hostId: task.hostId,
      direction: task.direction,
      isDirectory: false,
      remotePath: task.remotePath,
      fileName: task.fileName,
      totalBytes: task.totalBytes,
      verifiedOffset: task.totalBytes,
      sourceSize: task.sourceSize,
      sourceMtime: task.sourceMtime,
      partialSize: -1,
      partialMtime: -1,
      sessionGeneration: this.sshSessionGeneration,
      sequence: this.sftpTaskSequence,
      stage: 'completed',
      updatedAt: Date.now()
    });
  }

  private async enqueueSftpDownloadDirectory(): Promise<void> {
    if (this.sftpBusy || this.sessionId <= 0 || !this.sftpSelectedIsDir ||
      this.sftpSelectedPath.length === 0 || !this.sftpLocalSelectedIsDir ||
      this.sftpLocalSelectedUri.length === 0) {
      this.sftpStatus = '请先在本机文件区选择下载目标目录';
      return;
    }
    const requestPageGeneration: number = this.pageGeneration;
    const requestSessionId: number = this.sessionId;
    const requestSessionGeneration: number = this.sshSessionGeneration;
    const remotePath: string = this.sftpSelectedPath;
    const remoteName: string = this.sftpSelectedName.trim();
    const localParent: string = this.sftpLocalSelectedUri;
    let queuedBatchId: string = '';
    this.sftpBusy = true;
    this.sftpStatus = '正在扫描远端目录 ' + remoteName + '...';
    try {
      const scanned: SshSftpTreeItem[] | null = await this.scanRemoteSftpBatch(
        remotePath, remoteName, requestPageGeneration, requestSessionId,
        requestSessionGeneration);
      if (!this.isSftpRequestActive(requestPageGeneration, requestSessionId,
        requestSessionGeneration)) { return; }
      if (scanned === null) {
        this.sftpStatus = '[SFTP-BATCH] 远端目录扫描失败或超出批次限制';
        return;
      }
      const plan = planSshSftpBatch(scanned, SFTP_BATCH_LIMITS);
      if (!plan.accepted) {
        this.sftpStatus = '[SFTP-BATCH] 批量下载计划拒绝: ' + plan.reason;
        return;
      }
      const localRoot: string | null = await this.prepareLocalSftpDownloadRoot(localParent, remoteName);
      if (localRoot === null) {
        this.sftpStatus = '[SFTP-BATCH] 无法创建本机下载目录 ' + remoteName;
        return;
      }
      const remoteRoot: string = this.parentRemotePath(remotePath);
      const result: SshSftpBatchTaskEnqueueResult = this.sftpTaskStore.enqueueBatch(
        this.hostId, 'download', remoteRoot, plan);
      if (!result.accepted) {
        this.sftpStatus = '[SFTP-BATCH] 创建下载任务失败: ' + result.reason;
        return;
      }
      this.sftpBatchLocalRoots.set(result.batchId, localRoot);
      this.sftpBatchRemoteRoots.set(result.batchId, remoteRoot);
      queuedBatchId = result.batchId;
      this.refreshRecoveredSftpTasks();
      const directoryCount: number = result.records.filter(
        (record: SshSftpTaskRecord): boolean => record.isDirectory).length;
      const fileCount: number = result.records.length - directoryCount;
      this.sftpStatus = '已加入批量下载 ' + fileCount.toString() + ' 个文件、' +
        directoryCount.toString() + ' 个目录，总计 ' + this.formatFileSize(plan.totalBytes) + '，等待执行';
    } catch (_err) {
      if (this.isSftpRequestActive(requestPageGeneration, requestSessionId,
        requestSessionGeneration)) {
        this.sftpStatus = '[SFTP-BATCH] 远端目录扫描失败';
      }
    } finally {
      if (this.isSftpRequestActive(requestPageGeneration, requestSessionId,
        requestSessionGeneration)) {
        this.sftpBusy = false;
        if (queuedBatchId.length > 0) { this.startSftpEngineBatch(queuedBatchId); }
      }
    }
  }

  /** Enqueue a direct SSH-to-SSH copy; no file contents are staged locally. */
  private async enqueueSftpRemoteBatch(forward: boolean): Promise<void> {
    if (this.sftpBusy || this.sftpRightEndpoint !== 'ssh' ||
      this.sftpPeerHostId.trim().length === 0) { return; }
    const sourceHostId: string = (forward ? this.hostId : this.sftpPeerHostId).trim();
    const targetHostId: string = (forward ? this.sftpPeerHostId : this.hostId).trim();
    const sourcePath: string = (forward ? this.sftpSelectedPath : this.sftpPeerSelectedPath).trim();
    const sourceName: string = (forward ? this.sftpSelectedName : this.sftpPeerSelectedName).trim();
    const sourceIsDir: boolean = forward ? this.sftpSelectedIsDir : this.sftpPeerSelectedIsDir;
    const sourceSize: number = forward ? this.sftpSelectedSize : this.sftpPeerSelectedSize;
    const sourceMtime: number = forward ? this.sftpSelectedMtime : this.sftpPeerSelectedMtime;
    const targetRoot: string = forward ? this.sftpPeerPath : this.sftpPath;
    if (sourceHostId.length === 0 || targetHostId.length === 0 || sourcePath.length === 0 ||
      sourceName.length === 0 || targetRoot.trim().length === 0) {
      this.sftpStatus = '请选择源文件或目录';
      return;
    }
    const requestPageGeneration: number = this.pageGeneration;
    this.sftpBusy = true;
    this.sftpStatus = forward ? '正在准备传输到目标 SSH...' : '正在准备传输到当前 SSH...';
    try {
      const sourceSession: SshSftpEngineSession | null = await this.ensureSftpHostSession(
        sourceHostId, requestPageGeneration);
      const targetSession: SshSftpEngineSession | null = await this.ensureSftpHostSession(
        targetHostId, requestPageGeneration);
      if (!this.isPageGenerationActive(requestPageGeneration) || sourceSession === null ||
        targetSession === null) {
        this.sftpStatus = '双 SSH 会话不可用，请完成认证后重试';
        return;
      }
      const sourceRoot: string = this.parentRemotePath(sourcePath);
      let items: SshSftpTreeItem[] = [];
      if (sourceIsDir) {
        const scanned: SshSftpTreeItem[] | null = sourceHostId === this.hostId.trim()
          ? await this.scanRemoteSftpBatch(sourcePath, sourceName, requestPageGeneration,
            sourceSession.sessionId, sourceSession.generation)
          : await this.scanSftpRemoteTree(sourcePath, sourceName, sourceSession, requestPageGeneration);
        if (scanned === null) {
          this.sftpStatus = '源 SSH 目录扫描失败，批次未创建';
          return;
        }
        items = scanned;
      } else {
        if (!Number.isFinite(sourceSize) || sourceSize < 0 ||
          !Number.isFinite(sourceMtime) || sourceMtime < 0) {
          this.sftpStatus = '源文件身份不可验证，批次未创建';
          return;
        }
        items = [{
          relativePath: sourceName,
          name: sourceName,
          isDirectory: false,
          isSymbolicLink: false,
          isSpecialFile: false,
          size: sourceSize,
          mtime: sourceMtime,
          mode: 0,
          uid: -1,
          gid: -1
        }];
      }
      const plan = planSshSftpBatch(items, SFTP_BATCH_LIMITS);
      if (!plan.accepted) {
        this.sftpStatus = '[SFTP-REMOTE] 批量计划拒绝: ' + plan.reason;
        return;
      }
      const direction: SshSftpTaskDirection = forward ? 'upload' : 'download';
      const result: SshSftpBatchTaskEnqueueResult = this.sftpTaskStore.enqueueRemoteBatch(
        sourceHostId, targetHostId, sourceRoot, targetRoot, direction, plan);
      if (!result.accepted) {
        this.sftpStatus = '[SFTP-REMOTE] 创建任务失败: ' + result.reason;
        return;
      }
      this.refreshRecoveredSftpTasks();
      const directoryCount: number = result.records.filter(
        (record: SshSftpTaskRecord): boolean => record.isDirectory).length;
      const fileCount: number = result.records.length - directoryCount;
      this.sftpStatus = (forward ? '已加入传输到 ' : '已加入传输到当前 SSH ') +
        this.sftpPeerHostLabel() + '：' + fileCount.toString() + ' 个文件、' +
        directoryCount.toString() + ' 个目录，总计 ' + this.formatFileSize(plan.totalBytes);
      this.startSftpRemoteEngineBatch(result.batchId, targetHostId);
    } catch (_err) {
      if (this.isPageGenerationActive(requestPageGeneration)) {
        this.sftpStatus = '[SFTP-REMOTE] 双 SSH 批次准备失败';
      }
    } finally {
      if (this.sftpEngineBatchId.length === 0) { this.sftpBusy = false; }
    }
  }

  private batchTaskSourceRelativePath(task: SshSftpTaskRecord): string {
    const slash: number = task.relativePath.indexOf('/');
    return slash >= 0 ? task.relativePath.substring(slash + 1) :
      (task.isDirectory ? '' : task.fileName);
  }

  private async ensureRemoteSftpDirectory(path: string, requestPageGeneration: number,
    requestSessionId: number, requestSessionGeneration: number): Promise<boolean> {
    if (!this.isSftpRequestActive(requestPageGeneration, requestSessionId, requestSessionGeneration)) {
      return false;
    }
    const parent: string = this.parentRemotePath(path);
    const name: string = this.remoteBaseName(path);
    const listed: SftpListAsyncResult = await this.loader.listRemoteDirAsync(requestSessionId, parent);
    if (!this.isSftpRequestActive(requestPageGeneration, requestSessionId, requestSessionGeneration) ||
      listed.errorCode < 0) { return false; }
    for (let index = 0; index < listed.entries.length; index++) {
      const entry: SftpFileEntry = listed.entries[index];
      if (entry.isDirectory && (entry.path === path || entry.name === name)) { return true; }
    }
    const created = await this.loader.makeRemoteDirAsync(requestSessionId, path);
    if (!this.isSftpRequestActive(requestPageGeneration, requestSessionId, requestSessionGeneration)) {
      return false;
    }
    if (created.errorCode === 0) { return true; }
    const confirmed: SftpListAsyncResult = await this.loader.listRemoteDirAsync(requestSessionId, parent);
    if (confirmed.errorCode < 0) { return false; }
    for (let index = 0; index < confirmed.entries.length; index++) {
      const entry: SftpFileEntry = confirmed.entries[index];
      if (entry.isDirectory && (entry.path === path || entry.name === name)) { return true; }
    }
    return false;
  }

  private async ensureRemoteSftpBatchDirectories(task: SshSftpTaskRecord, remoteRoot: string,
    requestPageGeneration: number, requestSessionId: number,
    requestSessionGeneration: number): Promise<boolean> {
    const parts: string[] = task.relativePath.replace(/\\/g, '/').split('/');
    if (parts.length < 2) { return false; }
    let current: string = this.normalizeRemoteDir(remoteRoot);
    for (let index = 0; index < parts.length - 1; index++) {
      if (parts[index].length === 0 || !this.isValidRemoteName(parts[index])) { return false; }
      current = this.joinRemotePath(current, parts[index]);
      if (!await this.ensureRemoteSftpDirectory(current, requestPageGeneration,
        requestSessionId, requestSessionGeneration)) { return false; }
    }
    return true;
  }

  /** Execute one in-memory batch sequentially; durable records remain the source of truth. */
  private async runSftpUploadBatch(batchId: string): Promise<void> {
    if (this.sftpBatchRunning || this.sftpBusy || this.sessionId <= 0 || batchId.trim().length === 0) {
      return;
    }
    const sourceRoot: string | undefined = this.sftpBatchLocalRoots.get(batchId);
    const remoteRoot: string | undefined = this.sftpBatchRemoteRoots.get(batchId);
    if (sourceRoot === undefined || remoteRoot === undefined) {
      this.sftpStatus = '[SFTP-BATCH] 批次需要重新授权本机目录';
      return;
    }
    const tasks: SshSftpTaskRecord[] = this.sftpTaskStore.listBatch(this.hostId, batchId)
      .filter((task: SshSftpTaskRecord): boolean => task.stage === 'queued')
      .sort((left: SshSftpTaskRecord, right: SshSftpTaskRecord): number =>
        left.sequence - right.sequence);
    if (tasks.length === 0) { return; }
    const requestPageGeneration: number = this.pageGeneration;
    const requestSessionId: number = this.sessionId;
    const requestSessionGeneration: number = this.sshSessionGeneration;
    this.sftpBatchRunning = true;
    this.sftpBusy = true;
    let completedFiles: number = 0;
    let completedDirectories: number = 0;
    try {
      for (let index = 0; index < tasks.length; index++) {
        const task: SshSftpTaskRecord | null = this.sftpTaskStore.get(tasks[index].taskId);
        if (task === null || task.stage !== 'queued') { continue; }
        if (!this.isSftpRequestActive(requestPageGeneration, requestSessionId,
          requestSessionGeneration)) { return; }
        if (index > 0) { this.sftpBusy = true; }
        const sourceUri: string | null = await this.sftpLocalProvider.resolveRelative(
          sourceRoot, this.batchTaskSourceRelativePath(task));
        if (sourceUri === null) {
          this.sftpStatus = '[SFTP-BATCH] 找不到本机项目 ' + task.fileName + '，已停在当前任务';
          return;
        }
        if (task.isDirectory) {
          const sourceEntry: SshLocalFileEntry | null = await this.sftpLocalProvider.stat(sourceUri);
          if (sourceEntry === null || !sourceEntry.isDirectory) {
            this.sftpStatus = '[SFTP-BATCH] 本机目录不可读 ' + task.fileName + '，已停在当前任务';
            return;
          }
          if (!await this.ensureRemoteSftpDirectory(task.remotePath, requestPageGeneration,
            requestSessionId, requestSessionGeneration)) {
            this.sftpStatus = '[SFTP-BATCH] 无法创建远端目录 ' + task.fileName + '，已停在当前任务';
            return;
          }
          const completed = this.sftpTaskStore.command(task.taskId, { kind: 'complete' });
          if (!completed.accepted) {
            this.sftpStatus = '[SFTP-BATCH] 目录任务无法落盘完成状态 ' + task.fileName;
            return;
          }
          completedDirectories++;
          continue;
        }
        if (!await this.ensureRemoteSftpBatchDirectories(task, remoteRoot,
          requestPageGeneration, requestSessionId, requestSessionGeneration)) {
          this.sftpStatus = '[SFTP-BATCH] 无法创建远端目录，已停在 ' + task.fileName;
          return;
        }
        const offset: number = task.verifiedOffset >= 0 ? task.verifiedOffset : 0;
        this.sftpTransferCheckpoint = null;
        this.sftpTransferPartialRemotePath = offset > 0
          ? task.remotePath + sshSftpPartialSuffix(task.taskId) : '';
        this.sftpTransferPartialMtime = task.partialMtime;
        this.sftpTransferSourceSize = task.sourceSize;
        this.sftpTransferSourceMtime = task.sourceMtime;
        this.sftpTransferRemoteSize = task.totalBytes;
        this.sftpTransferRemoteMtime = -1;
        await this.uploadSftpToRemote(sourceUri, task.fileName, task.remotePath, offset, task.taskId,
          requestPageGeneration, requestSessionId, requestSessionGeneration);
        const updated: SshSftpTaskRecord | null = this.sftpTaskStore.get(task.taskId);
        if (updated === null || updated.stage !== 'completed') {
          return;
        }
        completedFiles++;
      }
      this.sftpBatchConflictPolicies.delete(batchId);
      this.sftpStatus = '批量上传完成，共 ' + completedFiles.toString() + ' 个文件、' +
        completedDirectories.toString() + ' 个目录';
      this.refreshSftp(this.sftpPath);
    } finally {
      this.sftpBatchRunning = false;
      if (this.sftpTransferSession === null || this.sftpTransferSession.stage === 'completed' ||
        this.sftpTransferSession.stage === 'failed' || this.sftpTransferSession.stage === 'cancelled') {
        this.sftpBusy = false;
      }
      this.refreshRecoveredSftpTasks();
    }
  }

  /** Execute a persisted download batch with the same single-file integrity floor. */
  private async runSftpDownloadBatch(batchId: string): Promise<void> {
    if (this.sftpBatchRunning || this.sftpBusy || this.sessionId <= 0 || batchId.trim().length === 0) {
      return;
    }
    const localRoot: string | undefined = this.sftpBatchLocalRoots.get(batchId);
    if (localRoot === undefined || !this.sftpBatchRemoteRoots.has(batchId)) {
      this.sftpStatus = '[SFTP-BATCH] 批次需要重新选择本机下载目录';
      return;
    }
    const tasks: SshSftpTaskRecord[] = this.sftpTaskStore.listBatch(this.hostId, batchId)
      .filter((task: SshSftpTaskRecord): boolean => task.direction === 'download' && task.stage === 'queued')
      .sort((left: SshSftpTaskRecord, right: SshSftpTaskRecord): number =>
        left.sequence - right.sequence);
    if (tasks.length === 0) { return; }
    const requestPageGeneration: number = this.pageGeneration;
    const requestSessionId: number = this.sessionId;
    const requestSessionGeneration: number = this.sshSessionGeneration;
    this.sftpBatchRunning = true;
    this.sftpBusy = true;
    let completedFiles: number = 0;
    let completedDirectories: number = 0;
    try {
      for (let index = 0; index < tasks.length; index++) {
        const task: SshSftpTaskRecord | null = this.sftpTaskStore.get(tasks[index].taskId);
        if (task === null || task.stage !== 'queued' || task.direction !== 'download') { continue; }
        if (!this.isSftpRequestActive(requestPageGeneration, requestSessionId,
          requestSessionGeneration)) { return; }
        if (index > 0) { this.sftpBusy = true; }
        const relativePath: string = this.batchTaskSourceRelativePath(task);
        if (task.isDirectory) {
          if (await this.ensureLocalSftpBatchPath(localRoot, relativePath, true) === null) {
            this.sftpStatus = '[SFTP-BATCH] 无法创建本机目录 ' + task.fileName + '，已停在当前任务';
            return;
          }
          const completed = this.sftpTaskStore.command(task.taskId, { kind: 'complete' });
          if (!completed.accepted) {
            this.sftpStatus = '[SFTP-BATCH] 目录任务无法落盘完成状态 ' + task.fileName;
            return;
          }
          completedDirectories++;
          continue;
        }
        const slash: number = relativePath.lastIndexOf('/');
        const parentRelative: string = slash >= 0 ? relativePath.substring(0, slash) : '';
        const localParent: string | null = await this.ensureLocalSftpBatchPath(
          localRoot, parentRelative, true);
        const finalUri: string | null = await this.sftpLocalProvider.resolveRelative(
          localRoot, relativePath);
        if (localParent === null || finalUri === null) {
          this.sftpStatus = '[SFTP-BATCH] 本机路径无效 ' + task.fileName + '，已停在当前任务';
          return;
        }
        let targetUri: string = finalUri;
        if (task.verifiedOffset <= 0) {
          const conflict: SftpLocalConflictPlan = await this.prepareLocalSftpConflict(
            localParent, task.fileName, task.batchId);
          if (conflict.action === 'failed') {
            this.sftpStatus = '[SFTP-BATCH] 本机目标冲突未处理 ' + task.fileName;
            return;
          }
          if (conflict.action === 'skip') {
            if (!this.completeSftpBatchFileTask(task)) {
              this.sftpStatus = '[SFTP-BATCH] 跳过任务状态无法落盘 ' + task.fileName;
              return;
            }
            completedFiles++;
            continue;
          }
          targetUri = conflict.targetPath;
        }
        const offset: number = task.verifiedOffset >= 0 ? task.verifiedOffset : 0;
        const partialPath: string = await this.sftpSandboxPartialPath(task.taskId);
        if (partialPath.length === 0) {
          this.sftpStatus = '[SFTP-BATCH] 无法建立本机 partial ' + task.fileName;
          return;
        }
        if (offset > 0) {
          const partialIdentity: SshSftpFileIdentity | null =
            await this.readLocalSftpIdentity(partialPath);
          if (partialIdentity === null || partialIdentity.size !== offset || partialIdentity.mtime < 0 ||
            task.partialSize !== offset || task.partialMtime < 0 ||
            task.partialMtime !== partialIdentity.mtime) {
            this.sftpStatus = '[SFTP-BATCH] partial 身份不匹配 ' + task.fileName + '，拒绝续传';
            return;
          }
        }
        this.sftpTransferCheckpoint = null;
        this.sftpTransferUri = partialPath;
        this.sftpTransferFinalUri = targetUri;
        this.sftpTransferRemotePath = task.remotePath;
        this.sftpTransferPartialRemotePath = '';
        this.sftpTransferPartialMtime = task.partialMtime;
        this.sftpTransferSourceSize = -1;
        this.sftpTransferSourceMtime = -1;
        this.sftpTransferRemoteSize = task.sourceSize;
        this.sftpTransferRemoteMtime = task.sourceMtime;
        await this.downloadSftpToLocal(partialPath, targetUri, task.fileName, task.remotePath,
          task.totalBytes, offset, task.taskId, requestPageGeneration, requestSessionId,
          requestSessionGeneration);
        const updated: SshSftpTaskRecord | null = this.sftpTaskStore.get(task.taskId);
        if (updated === null || updated.stage !== 'completed') { return; }
        completedFiles++;
      }
      this.sftpBatchConflictPolicies.delete(batchId);
      this.sftpStatus = '批量下载完成，共 ' + completedFiles.toString() + ' 个文件、' +
        completedDirectories.toString() + ' 个目录';
    } finally {
      this.sftpBatchRunning = false;
      if (this.sftpTransferSession === null || this.sftpTransferSession.stage === 'completed' ||
        this.sftpTransferSession.stage === 'failed' || this.sftpTransferSession.stage === 'cancelled') {
        this.sftpBusy = false;
      }
      this.refreshRecoveredSftpTasks();
    }
  }

  private continueSftpBatchAfterTask(taskId: string): void {
    const task: SshSftpTaskRecord | null = this.sftpTaskStore.get(taskId);
    if (task === null || task.stage !== 'completed' || task.batchId.trim().length === 0 ||
      !this.sftpBatchLocalRoots.has(task.batchId) || !this.sftpBatchRemoteRoots.has(task.batchId)) {
      return;
    }
    if (task.direction === 'download') { void this.runSftpDownloadBatch(task.batchId); }
    else { void this.runSftpUploadBatch(task.batchId); }
  }

  private batchSourceRootName(tasks: SshSftpTaskRecord[]): string {
    if (tasks.length === 0) { return ''; }
    const relativePath: string = tasks[0].relativePath.replace(/\\/g, '/').trim();
    const slash: number = relativePath.indexOf('/');
    return (slash >= 0 ? relativePath.substring(0, slash) : tasks[0].fileName).trim();
  }

  /** Recover the remote parent without trusting a stored local URI. */
  private batchRemoteRoot(task: SshSftpTaskRecord): string {
    const relativePath: string = task.relativePath.replace(/\\/g, '/').trim();
    const remotePath: string = this.normalizeRemoteDir(task.remotePath);
    if (relativePath.length === 0) { return this.parentRemotePath(remotePath); }
    const suffix: string = '/' + relativePath;
    if (!remotePath.endsWith(suffix)) { return ''; }
    const prefix: string = remotePath.substring(0, remotePath.length - suffix.length);
    if (prefix.length > 0) { return prefix; }
    return remotePath.startsWith('/') ? '/' : '.';
  }

  /** Rebind a persisted batch to a fresh, user-authorized local directory. */
  private async recoverSftpBatch(batchId: string): Promise<void> {
    const id: string = batchId.trim();
    if (id.length === 0 || this.sftpBusy || this.sessionId <= 0 || this.hostId.trim().length === 0) {
      return;
    }
    if (this.sftpBatchLocalRoots.has(id) && this.sftpBatchRemoteRoots.has(id)) {
      this.resumeSftpBatch(id);
      return;
    }
    const tasks: SshSftpTaskRecord[] = this.sftpTaskStore.listBatch(this.hostId, id)
      .filter((task: SshSftpTaskRecord): boolean =>
        task.stage !== 'completed' && task.stage !== 'cancelled')
      .sort((left: SshSftpTaskRecord, right: SshSftpTaskRecord): number =>
        left.sequence - right.sequence);
    if (tasks.length === 0) {
      this.sftpStatus = '[SFTP-BATCH] 找不到待恢复任务';
      return;
    }
    const rootName: string = this.batchSourceRootName(tasks);
    const remoteRoot: string = this.batchRemoteRoot(tasks[0]);
    const isDownloadBatch: boolean = tasks[0].direction === 'download';
    if (rootName.length === 0 || remoteRoot.length === 0) {
      this.sftpStatus = '[SFTP-BATCH] 批次路径元数据无效，拒绝恢复';
      return;
    }

    const requestPageGeneration: number = this.pageGeneration;
    const requestSessionId: number = this.sessionId;
    const requestSessionGeneration: number = this.sshSessionGeneration;
    this.sftpBusy = true;
    this.sftpStatus = isDownloadBatch
      ? '请选择本机目录 ' + rootName + ' 作为下载目标'
      : '请选择本机目录 ' + rootName + ' 以恢复批次';
    try {
      let sourceRoot: string = '';
      if (isDownloadBatch) {
        if (this.sftpLocalSelectedIsDir && this.sftpLocalSelectedUri.length > 0) {
          sourceRoot = await this.prepareLocalSftpDownloadRoot(
            this.sftpLocalSelectedUri, rootName) || '';
        }
        if (sourceRoot.length === 0 && this.sftpLocalPath.length > 0) {
          sourceRoot = await this.prepareLocalSftpDownloadRoot(
            this.sftpLocalPath, rootName) || '';
        }
        if (sourceRoot.length === 0) {
          const currentRoot: string = await this.sftpLocalProvider.currentRoot();
          if (currentRoot.length > 0) {
            sourceRoot = await this.prepareLocalSftpDownloadRoot(currentRoot, rootName) || '';
          }
        }
        if (sourceRoot.length === 0 && this.localProviderNeedsAuthorization()) {
          const authorized: SshLocalProviderSnapshot =
            await this.sftpLocalProvider.chooseAuthorizedFolder();
          if (authorized.state === 'ready') {
            sourceRoot = await this.prepareLocalSftpDownloadRoot(
              authorized.rootPath, rootName) || '';
            this.sftpLocalProviderStatus = authorized.rootLabel;
          }
        }
      } else {
        if (this.sftpLocalSelectedIsDir && this.sftpLocalSelectedUri.length > 0 &&
          this.sftpLocalSelectedName.trim() === rootName) {
          const selected: SshLocalFileEntry | null =
            await this.sftpLocalProvider.stat(this.sftpLocalSelectedUri);
          if (selected !== null && selected.isDirectory && selected.name === rootName) {
            sourceRoot = selected.uri;
          }
        }
        if (sourceRoot.length === 0) {
          const currentRoot: string = await this.sftpLocalProvider.currentRoot();
          if (currentRoot.length > 0) {
            const currentEntry: SshLocalFileEntry | null =
              await this.sftpLocalProvider.stat(currentRoot);
            if (currentEntry !== null && currentEntry.isDirectory && currentEntry.name === rootName) {
              sourceRoot = currentRoot;
            }
          }
        }
        if (sourceRoot.length === 0 && this.localProviderNeedsAuthorization()) {
          const authorized: SshLocalProviderSnapshot =
            await this.sftpLocalProvider.chooseAuthorizedFolder();
          if (authorized.state === 'ready' && authorized.rootLabel === rootName) {
            sourceRoot = authorized.rootPath;
            this.sftpLocalProviderStatus = authorized.rootLabel;
          }
        }
      }
      if (!this.isSftpRequestActive(requestPageGeneration, requestSessionId,
        requestSessionGeneration)) { return; }
      if (sourceRoot.length === 0) {
        this.sftpStatus = '[SFTP-BATCH] 请在本机文件区选中目录 ' + rootName + ' 后再次恢复';
        return;
      }
      this.sftpBatchLocalRoots.set(id, sourceRoot);
      this.sftpBatchRemoteRoots.set(id, remoteRoot);
      this.sftpStatus = isDownloadBatch ? '已重新绑定下载目录，开始恢复' : '已重新绑定批次目录，开始恢复';
    } catch (_err) {
      if (this.isSftpRequestActive(requestPageGeneration, requestSessionId,
        requestSessionGeneration)) {
        this.sftpStatus = '[SFTP-BATCH] 本机目录重新授权失败';
      }
      return;
    } finally {
      this.sftpBusy = false;
    }
    if (this.isSftpRequestActive(requestPageGeneration, requestSessionId, requestSessionGeneration)) {
      this.startSftpEngineBatch(id);
    }
  }

  private async recoverSftpRemoteBatch(batchId: string): Promise<void> {
    const id: string = batchId.trim();
    if (id.length === 0 || this.sftpBusy) { return; }
    const tasks: SshSftpTaskRecord[] = this.sftpTaskStore.list().filter(
      (task: SshSftpTaskRecord): boolean => task.batchId === id &&
        task.stage !== 'completed' && task.stage !== 'cancelled' &&
        task.sourceEndpoint?.kind === 'ssh' && task.targetEndpoint?.kind === 'ssh');
    if (tasks.length === 0) {
      this.sftpStatus = '[SFTP-REMOTE] 找不到待恢复双 SSH 任务';
      return;
    }
    const first: SshSftpTaskRecord = tasks[0];
    const sourceHostId: string = (first.sourceEndpoint?.hostId || '').trim();
    const targetHostId: string = (first.targetEndpoint?.hostId || '').trim();
    const requestPageGeneration: number = this.pageGeneration;
    this.sftpBusy = true;
    this.sftpStatus = '正在恢复双 SSH 会话...';
    try {
      const source: SshSftpEngineSession | null = await this.ensureSftpHostSession(
        sourceHostId, requestPageGeneration);
      const target: SshSftpEngineSession | null = await this.ensureSftpHostSession(
        targetHostId, requestPageGeneration);
      if (!this.isPageGenerationActive(requestPageGeneration) || source === null || target === null) {
        this.sftpStatus = '[SFTP-REMOTE] 源或目标 SSH 需要认证';
        return;
      }
      for (let index: number = 0; index < tasks.length; index++) {
        const task: SshSftpTaskRecord | null = this.sftpTaskStore.get(tasks[index].taskId);
        if (task === null) { continue; }
        if (task.stage === 'waitingForConnection' || task.stage === 'paused') {
          this.sftpTaskStore.command(task.taskId, { kind: 'resume' });
        } else if (task.stage === 'failed' || task.stage === 'awaitingConflictDecision') {
          this.sftpTaskStore.command(task.taskId, { kind: 'retry' });
        }
      }
      this.sftpEngineBatchTargetHostId = targetHostId;
      this.sftpStatus = '双 SSH 任务已恢复，开始继续传输';
      this.startSftpRemoteEngineBatch(id, targetHostId);
    } finally {
      if (this.sftpEngineBatchId.length === 0) { this.sftpBusy = false; }
      this.refreshRecoveredSftpTasks();
    }
  }

  private resumeSftpBatch(batchId: string): void {
    const id: string = batchId.trim();
    if (id.length === 0 || this.sftpBusy || this.sessionId <= 0) { return; }
    if (!this.sftpBatchLocalRoots.has(id) || !this.sftpBatchRemoteRoots.has(id)) {
      this.sftpStatus = '[SFTP-BATCH] 批次需要重新授权本机目录';
      return;
    }
    const current: TransferSession | null = this.sftpTransferSession;
    const currentTask: SshSftpTaskRecord | null = current === null
      ? null : this.sftpTaskStore.get(current.id);
    if (current !== null && currentTask !== null && currentTask.batchId === id &&
      (current.stage === 'paused' || current.stage === 'waitingRemote')) {
      void this.resumeSftpTransfer();
      return;
    }
    if (current !== null && currentTask !== null && currentTask.batchId === id &&
      (current.stage === 'failed' || current.stage === 'cancelled')) {
      void this.retrySftpTransfer();
      return;
    }
    const tasks: SshSftpTaskRecord[] = this.sftpTaskStore.listBatch(this.hostId, id)
      .filter((task: SshSftpTaskRecord): boolean => task.stage !== 'completed' && task.stage !== 'cancelled')
      .sort((left: SshSftpTaskRecord, right: SshSftpTaskRecord): number =>
        left.sequence - right.sequence);
    let queued: boolean = false;
    for (let index = 0; index < tasks.length; index++) {
      const task: SshSftpTaskRecord = tasks[index];
      if (task.stage === 'queued') { queued = true; break; }
      if (task.stage === 'paused' || task.stage === 'waitingForConnection') {
        if (!this.sftpTaskStore.command(task.taskId, { kind: 'resume' }).accepted) { return; }
        queued = true;
        break;
      }
      if (task.stage === 'failed' || task.stage === 'awaitingConflictDecision') {
        if (!this.sftpTaskStore.command(task.taskId, { kind: 'retry' }).accepted) { return; }
        queued = true;
        break;
      }
    }
    if (queued) {
      this.startSftpEngineBatch(id);
    }
  }

  private openSftpLocalSelectedDir(): void {
    if (!this.sftpLocalSelectedIsDir || this.sftpLocalSelectedUri.length === 0) { return; }
    void this.refreshSftpLocalAt(this.sftpLocalSelectedUri);
  }

  private async refreshSftpLocalAt(path: string): Promise<void> {
    if (this.terminalClosing || path.trim().length === 0) { return; }
    this.sftpLocalPath = path.trim();
    await this.refreshSftpLocal(this.pageGeneration);
  }

  private async openSftpLocalParent(): Promise<void> {
    if (this.sftpLocalPath.length === 0) { return; }
    const root: string = await this.sftpLocalProvider.currentRoot();
    if (root.length === 0 || this.sftpLocalPath === root) { return; }
    const normalized: string = this.sftpLocalPath.replace(/\\+$/g, '');
    const slash: number = normalized.lastIndexOf('/');
    const parent: string = slash > 0 ? normalized.substring(0, slash) : root;
    await this.refreshSftpLocalAt(parent.length >= root.length ? parent : root);
  }

  async aboutToAppear(): Promise<void> {
    this.stopSshAuthPromptPolling(true);
    const pageGeneration: number = ++this.pageGeneration;
    const bindingGeneration: number = ++this.sshBindingGeneration;
    this.terminalClosing = false;
    this.nativeRendererUnavailable = false;
    this.clearPreflightBinding();
    this.showSshTabPicker = false;
    if (this.sshTabStoreUnsubscribe !== null) {
      this.sshTabStoreUnsubscribe();
      this.sshTabStoreUnsubscribe = null;
    }
    this.sshTabStoreUnsubscribe = this.sshTabStore.subscribe((): void => {
      if (this.isPageGenerationActive(pageGeneration)) {
        this.refreshSshTabViews();
      }
    });
    this.refreshSshTabViews();
    this.invalidateSftpRefreshRequest();
    this.explicitSessionClose = false;
    this.sftpDetached = false;
    this.sftpWaitingForConnection = false;
    this.sftpTaskUnsubscribe = null;
    this.sftpEngineUnsubscribe = null;
    try {
      const taskContext: common.Context = this.getUIContext().getHostContext() as common.Context;
      // PiP cleanup and local-folder permission restoration are ancillary to
      // the SSH surface. Starting them here lets the xterm document begin
      // loading while those services finish their own lifecycle work.
      void this.sshPipService.stop().catch((err: Error): void => {
        hilog.warn(0x0017, 'SshTerminal', 'SSH PiP stop deferred: ' + JSON.stringify(err));
      });
      this.sftpTaskStore.init(taskContext);
      this.sftpLocalProvider.init(taskContext as common.UIAbilityContext);
      this.sftpEngineUnsubscribe = this.sftpTaskEngine.subscribe(
        (event: SshSftpTaskEngineEvent): void => { this.onSftpEngineEvent(event); });
      // The engine defers session attachment until its provider restore has
      // completed, so SFTP retains its lifecycle guarantees without blocking
      // SSH connection and terminal first paint.
      void this.sftpTaskEngine.init(taskContext as common.UIAbilityContext).catch((err: Error): void => {
        hilog.warn(0x0017, 'SshTerminal', 'SFTP engine init deferred: ' + JSON.stringify(err));
      });
      void this.restoreSshLocalProvider(pageGeneration);
    } catch (_err) {
      // A task store failure must not block terminal startup; the in-memory
      // transfer coordinator remains authoritative for the active session.
    }
    this.lastTermAreaPosition = '';
    this.lastShellAreaPosition = '';
    this.termAreaH = 0;
    this.termAreaW = 0;
    this.shellAreaH = 0;
    this.shellAreaW = 0;
    this.orientationApplied = false;
    // ArkUI 可能复用页面实例；每次进入都必须从全新的会话输出开始。
    this.termOutput = '';
    this.clearXtermOutputBuffers();
    this.clearTerminalOutputQueue();
    this.clearTerminalInputQueue();
    this.terminalDecodeRemainder = new Uint8Array(0);
    this.terminalOutputQueueOverflowed = false;
    this.bracketedPasteEnabled = false;
    this.terminalMouseTracking = 0;
    this.terminalSgrMouse = false;
    this.terminalApplicationCursorKeys = false;
    this.terminalApplicationKeypad = false;
    this.termOutputSequence++;
    this.connected = false;
    this.connecting = true;
    this.connectionError = '';
    this.visibleSshHostId = '';
    this.latencyMs = -1;
    this.sessionId = -1;
    this.sshSessionGeneration = 0;
    this.sshAuthPromptHandledSessionId = 0;
    this.sshAuthPromptHandledGeneration = 0;
    this.sshAuthPromptHandledRequestId = 0;
    this.startSshAuthPromptPolling();
    this.ctrlActive = false;
    this.altActive = false;
    this.shiftActive = false;
    this.kbInput = '';
    this.selectMode = false;
    this.terminalMouseDownButton = -1;
    this.terminalFocusMode = true;
    this.softKeyboardRequested = false;
    this.terminalFocusRequest = 0;
    this.resetTerminalSurfaceBinding();
    this.terminalSurfaceGeneration = this.terminalSurfaceGeneration + 1;
    this.clearSftpSheetTransitionTimers();
    ++this.sftpSheetTransitionToken;
    ++this.sftpRootSheetMountToken;
    ++this.sftpPeerHostPickerMountToken;
    ++this.sftpPeerHostPickerTransitionToken;
    this.sftpRootSheetReopenRequested = false;
    this.sftpRootSheetClosing = false;
    this.sftpCloseRootAfterPeerPicker = false;
    this.sftpPeerHostPickerReopenRequested = false;
    this.sftpPeerHostPickerClosing = false;
    this.showSftpPanel = false;
    this.showSftpSheet = false;
    this.sftpPath = '.';
    this.sftpEntries = [];
    this.sftpSelectedPath = '';
    this.sftpSelectedName = '';
    this.sftpSelectedIsDir = false;
    this.sftpSelectedSize = 0;
    this.sftpSelectedMtime = -1;
    this.sftpPathInput = '.';
    this.sftpLocalPath = '';
    this.sftpLocalEntries = [];
    this.sftpRightEndpoint = 'local';
    this.sftpRightEndpointChosen = false;
    this.sftpPeerHostId = '';
    this.sftpPeerHostPicker = false;
    this.sftpPeerPath = '.';
    this.sftpPeerPathInput = '.';
    this.sftpPeerEntries = [];
    this.sftpPeerSelectedPath = '';
    this.sftpPeerSelectedName = '';
    this.sftpPeerSelectedIsDir = false;
    this.sftpPeerSelectedSize = 0;
    this.sftpPeerBusy = false;
    this.sftpPeerStatus = '选择 SSH 主机后浏览远端目录';
    this.sftpPeerSelectedMtime = -1;
    this.sftpPeerSessionId = -1;
    this.sftpPeerSessionGeneration = 0;
    this.sftpPeerRequestToken = 0;
    this.sftpLocalSelectedUri = '';
    this.sftpLocalSelectedName = '';
    this.sftpLocalSelectedIsDir = false;
    this.sftpLocalSelectedSize = 0;
    this.sftpRecoveredTasks = [];
    this.sftpNameInput = '';
    this.sftpBusy = false;
    this.sftpPickerBusy = false;
    this.sftpProgress = -1;
    this.sftpEngineBatchId = '';
    this.sftpEngineBatchTargetHostId = '';
    this.sftpCancelRequested = false;
    this.sftpPauseRequested = false;
    this.sftpTransferSession = null;
    this.sftpTransferUri = '';
    this.sftpTransferFinalUri = '';
    this.sftpTransferRemotePath = '';
    this.sftpTransferPartialRemotePath = '';
    this.sftpTransferPartialMtime = -1;
    this.sftpTransferSourceMtime = -1;
    this.sftpTransferRemoteMtime = -1;
    this.sftpTransferSourceSize = -1;
    this.sftpTransferRemoteSize = -1;
    this.sftpTransferCheckpoint = null;
    this.sftpTransferGeneration = 0;
    this.sftpTransferSessionId = -1;
    this.sftpTransferPageGeneration = 0;
    this.sftpAtomicCommitErrorCode = 0;
    this.sftpCancelRequested = false;
    this.sftpPauseRequested = false;
    this.imeCallbackState = createSshImeCallbackState();
    this.updateCellSize();
    this.termRows = this.calcRowsFallback();
    this.termCols = this.calcColsFallback();

    // 进入 SSH 终端跟随设备当前朝向（不锁定窗口方向）；用户仍可手动切换横竖屏。
    const defaultOrientation: SshTerminalOrientation = defaultSshTerminalOrientation(this.isDesktopDevice);
    if (defaultOrientation === 'system') {
      this.isLandscape = await this.readDeviceIsLandscape();
      if (!this.isPageGenerationActive(pageGeneration)) { return; }
    } else {
      this.isLandscape = defaultOrientation === 'landscape';
      await this.setPreferredOrientation(
        defaultOrientation === 'landscape' ? window.Orientation.LANDSCAPE : window.Orientation.PORTRAIT,
        defaultOrientation === 'landscape' ? 'SSH-LANDSCAPE' : 'SSH-PORTRAIT'
      );
      if (!this.isPageGenerationActive(pageGeneration)) { return; }
    }

    // SSH 终端始终深色模式 — 强制系统状态栏/导航栏亮色图标
    this.forceStatusBarDark();

    this.setupKeyboardAvoidMode();
    // 注册键盘/系统栏高度监听 — 用于手动定位移动端虚拟键栏
    this.registerAvoidAreaListener();
    this.registerInputDeviceWatcher();

    const params: Object = router.getParams();
    if (params) {
      const p: Record<string, Object> = params as Record<string, Object>;
      const id: string = p['hostId'] as string;
      if (id) {
        this.hostId = id;
        this.visibleSshHostId = id.trim();
        const transcript: string = this.sshTranscriptStore.snapshot(this.hostId);
        if (transcript.length > 0) {
          this.xtermOutputBufferForHost(this.hostId).enqueue(transcript);
        }
        if (!this.nativeTerminalFormFactor()) {
          this.replayNativeOutputToXterm(this.hostId);
        }
        this.sftpTaskUnsubscribe = this.sftpTaskStore.subscribe((event): void => {
          if (event.record.hostId !== this.hostId || this.sftpBusy) { return; }
          this.refreshRecoveredSftpTasks();
          if (event.record.stage === 'needsAuthorization') {
            this.sftpStatus = 'SFTP 任务需要重新授权本机文件后才能继续';
          } else if (event.record.stage === 'needsAuthentication') {
            this.sftpStatus = 'SFTP 任务需要重新认证 SSH 会话后才能继续';
          } else if (event.record.stage === 'waitingForConnection') {
            this.sftpStatus = 'SFTP 任务等待 SSH 会话，可重新打开后重试';
          }
        });

        // T-210: 消费 preflight token (获取 passphrase + expected host key)
        const preflightTokenId: string = (p['sshPreflightToken'] as string) || '';
        if (preflightTokenId !== '') {
          const tokenSvc = SshPreflightService.getInstance();
          const tokenData = tokenSvc.consume(preflightTokenId);
          if (tokenData) {
            this.preflightHostId = tokenData.hostId.trim() || this.hostId;
            this.preflightPassphrase = tokenData.privateKeyPassphrase;
            this.preflightProxyPassphrase = tokenData.proxyPrivateKeyPassphrase || '';
            this.preflightExpectedHostKeyRaw = tokenData.expectedHostKeyRawBase64;
            this.preflightExpectedHostKeyFp = tokenData.expectedHostKeyFingerprintSha256;
            this.preflightExpectedJumpHostKeyRaw = tokenData.expectedJumpHostKeyRawBase64;
            this.preflightExpectedJumpHostKeyFp = tokenData.expectedJumpHostKeyFingerprintSha256;
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
          this.sshTabStore.open(this.hostId, this.hostLabel, this.userAtHost);
          this.sshTabStore.activate(this.hostId);
          this.refreshSshTabViews();
          const recoveredTasks: SshSftpTaskRecord[] = this.sftpTaskStore.list(this.hostId).filter(
            (task: SshSftpTaskRecord): boolean => task.stage !== 'completed' && task.stage !== 'cancelled');
          this.refreshRecoveredSftpTasks();
          if (recoveredTasks.length > 0) {
            this.sftpStatus = '有 ' + recoveredTasks.length.toString() +
              ' 个未完成 SFTP 任务，需要重新授权后重试';
          }
          const authenticated: boolean = (p['authenticated'] as boolean) === true;
          if (host.locked && !authenticated) {
            const r = await showLockGate(host.label, 'biometric');
            if (!this.isSshBindingActive(pageGeneration, bindingGeneration, this.hostId)) { return; }
            if (!r.ok) { this.connecting = false; this.connectionError = lockGateErrorMessage(r) || '验证未通过'; return; }
          }
          if (!this.isSshBindingActive(pageGeneration, bindingGeneration, this.hostId)) { return; }
          const detachedSessionId: number = this.loader.adoptDetachedSshSession(this.hostId);
          if (detachedSessionId > 0) {
            const attached: boolean = await this.attachSshSession(
              pageGeneration, bindingGeneration, detachedSessionId, this.hostId);
            if (!attached && this.isSshBindingActive(pageGeneration, bindingGeneration, this.hostId)) {
              await this.connect(host, pageGeneration, bindingGeneration);
            }
          } else {
            await this.connect(host, pageGeneration, bindingGeneration);
          }
        }
      }
    }
  }

  aboutToDisappear(): void {
    this.stopSshAuthPromptPolling(true);
    ++this.pageGeneration;
    ++this.sshBindingGeneration;
    this.terminalClosing = true;
    this.clearSftpSheetTransitionTimers();
    ++this.sftpSheetTransitionToken;
    ++this.sftpRootSheetMountToken;
    ++this.sftpPeerHostPickerMountToken;
    ++this.sftpPeerHostPickerTransitionToken;
    this.sftpRootSheetReopenRequested = false;
    this.sftpCloseRootAfterPeerPicker = false;
    this.sftpPeerHostPickerReopenRequested = false;
    this.sftpPeerHostPickerClosing = false;
    this.noteSftpSheetDismissalIfVisible();
    this.sftpPeerHostPicker = false;
    this.showSftpPanel = false;
    this.showSftpSheet = false;
    // Hide the virtual-key layer before the old route is detached so it cannot
    // flash above the next SSH page during router replacement.
    this.resetTerminalSurfaceBinding();
    const backgroundInfos: SshTerminalBackgroundInfo[] = this.backgroundSshInfos();
    let preserveSshInBackground: boolean =
      (AppStorage.get<boolean>('remoteDesktopBgFlag') ?? false) &&
      !this.explicitSessionClose && backgroundInfos.length > 0;
    let backgroundContext: common.UIAbilityContext | null = null;
    try {
      backgroundContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
    } catch (err) {
      hilog.warn(0x0016, 'SshTerminal', 'background context unavailable: ' + JSON.stringify(err));
    }
    if (backgroundContext === null) {
      preserveSshInBackground = false;
    }
    if (preserveSshInBackground) {
      if (backgroundContext !== null) {
        if (this.sshPipService.isPreparedOrPreparing()) {
          this.sshPipService.update(this.makeSshPipInfo('后台保留'));
          void this.sshPipService.start().then((started: boolean): void => {
            hilog.info(0x0017, 'SshTerminal', 'SSH PiP auto-start=' + started.toString());
          });
        } else {
          hilog.info(0x0017, 'SshTerminal', 'SSH PiP skipped: prepare was not requested');
        }
        for (let index = 0; index < backgroundInfos.length; index++) {
          const backgroundInfo: SshTerminalBackgroundInfo = backgroundInfos[index];
          // A tab switch detaches its SFTP owner even though the native SSH
          // session remains live. Reattach every retained tab before the page
          // disappears so queued SFTP work can run without a view listener.
          this.sftpTaskEngine.attachSession({
            hostId: backgroundInfo.hostId,
            sessionId: backgroundInfo.sessionId,
            generation: this.sshTabStore.sessionGeneration(backgroundInfo.hostId)
          });
          void this.sshBackgroundTaskService.start(backgroundContext, backgroundInfo).then(
            (started: boolean): void => {
              hilog.info(0x0016, 'SshTerminal', 'background preserve task started=' +
                started.toString() + ' session=' + backgroundInfo.sessionId.toString());
              if (started || !this.terminalClosing ||
                this.sshTabStore.sessionId(backgroundInfo.hostId) !== backgroundInfo.sessionId) {
                return;
              }
              // A rejected continuous task cannot be presented as a durable
              // background connection. Stop the detached session and leave
              // any active SFTP record paused at its last durable checkpoint.
              this.sftpTaskEngine.detachSession(backgroundInfo.hostId, backgroundInfo.sessionId);
              this.sshTabStore.invalidateSession(backgroundInfo.hostId, 'error', 'backgroundLimited');
              this.loader.disconnectSshSession(backgroundInfo.sessionId);
            });
        }
      } else {
        hilog.warn(0x0016, 'SshTerminal', 'SSH session detached without background task context');
      }
    } else {
      void this.sshPipService.stop();
      if (backgroundContext !== null) {
        void this.sshBackgroundTaskService.stop(backgroundContext);
      }
    }
    this.invalidateSftpRefreshRequest();
    this.sftpDetached = true;
    if (!preserveSshInBackground && this.sftpTransferSession !== null && this.sftpBusy) {
      this.sftpWaitingForConnection = true;
      this.sftpCancelRequested = true;
      this.sftpTaskStore.command(this.sftpTransferSession.id, { kind: 'detach' });
      this.persistSftpTaskMetadata('waitingForConnection');
    }
    void this.sftpTaskStore.flushNow();
    if (this.sftpTaskUnsubscribe !== null) {
      this.sftpTaskUnsubscribe();
      this.sftpTaskUnsubscribe = null;
    }
    if (this.sftpEngineUnsubscribe !== null) {
      this.sftpEngineUnsubscribe();
      this.sftpEngineUnsubscribe = null;
    }
    if (this.sshTabStoreUnsubscribe !== null) {
      this.sshTabStoreUnsubscribe();
      this.sshTabStoreUnsubscribe = null;
    }
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
    this.unregisterInputDeviceWatcher();
    this.imeCallbackState = createSshImeCallbackState();
    // 恢复系统状态栏颜色到进入前的值
    this.restoreStatusBar();
    const requestSessionId: number = this.sessionId;
    const shouldCloseAllSshSessions: boolean = !preserveSshInBackground;
    if (shouldCloseAllSshSessions) {
      const allSessionIds: number[] = this.sshTabStore.closeAll();
      this.sshTranscriptStore.clearAll();
      for (let index = 0; index < allSessionIds.length; index++) {
        if (allSessionIds[index] !== requestSessionId) {
          this.loader.disconnectSshSession(allSessionIds[index]);
        }
      }
      this.clearNativeTerminalBuffers();
      this.terminalCoreRegistry.destroyAll(new TerminalCoreBridge());
      // Native GPU renderers outlive the transient XComponent while tabs are
      // switched, but they must not outlive the SSH page's final teardown.
      // Otherwise a later entry can inherit a handle bound to a dead surface.
      this.sshTerminalRendererRegistry.destroyAll(new SshTerminalRendererBridge());
      if (requestSessionId > 0) {
        this.loader.disconnectSshSession(requestSessionId);
      } else {
        this.loader.disconnect();
      }
    } else if (requestSessionId > 0) {
      this.sshTabStore.update(this.hostId, 'connected', requestSessionId);
      if (!preserveSshInBackground) {
        this.sftpTaskEngine.detachSession(this.hostId, requestSessionId);
      }
      if (!this.loader.detachSshSession(requestSessionId, this.hostId)) {
        // If the native session is already leaving, explicit cleanup is safer
        // than leaving an unowned socket behind.
        this.loader.disconnectSshSession(requestSessionId);
      }
    } else if (this.connecting) {
      // A pending async connect has a reserved native id held by the facade.
      // It cannot be safely detached because no page-owned session exists yet.
      this.loader.disconnect();
    }
    this.sessionId = -1;
    this.connected = false;
    this.visibleSshHostId = '';
    this.termOutput = '';
    this.clearXtermOutputBuffers();
    this.clearTerminalOutputQueue();
    this.clearTerminalInputQueue();
    this.terminalDecodeRemainder = new Uint8Array(0);
    this.sshSessionGeneration = 0;
    this.resetTerminalSurfaceBinding();
    this.termOutputSequence++;
    if (this.orientationApplied) {
      const restoreGeneration: number = this.pageGeneration;
      setTimeout((): void => {
        if (this.pageGeneration !== restoreGeneration) { return; }
        this.setPreferredOrientation(window.Orientation.UNSPECIFIED, 'SSH-UNSPECIFIED');
      }, 250);
    }
  }

  private backgroundSshInfos(): SshTerminalBackgroundInfo[] {
    const result: SshTerminalBackgroundInfo[] = [];
    const seenSessions: Set<number> = new Set<number>();
    const views: SshTerminalTabView[] = this.sshTabStore.views();
    for (let index = 0; index < views.length; index++) {
      const view: SshTerminalTabView = views[index];
      if (view.sessionId <= 0 || (view.state !== 'connected' && view.state !== 'reconnecting')) {
        continue;
      }
      result.push({
        hostId: view.hostId,
        sessionId: view.sessionId,
        hostLabel: view.label,
        hostAddress: view.address
      });
      seenSessions.add(view.sessionId);
    }
    // The tab registry is normally updated before this callback. Keep a
    // current-page fallback for a detach race so the active session is not
    // omitted from the background handoff.
    if (this.sessionId > 0 && this.hostId.trim().length > 0 &&
      !seenSessions.has(this.sessionId)) {
      result.push({
        hostId: this.hostId,
        sessionId: this.sessionId,
        hostLabel: this.hostLabel,
        hostAddress: this.userAtHost.length > 0 ? this.userAtHost : this.sshHost
      });
    }
    return result;
  }

  /** 读取设备当前窗口朝向（宽 > 高 为横屏），用于进入终端时跟随设备朝向。 */
  private async readDeviceIsLandscape(): Promise<boolean> {
    try {
      const ctx = this.getUIContext().getHostContext();
      if (!ctx) { return false; }
      const win: window.Window = await window.getLastWindow(ctx);
      const props: window.WindowProperties = win.getWindowProperties();
      return props.windowRect.width > props.windowRect.height;
    } catch (err) {
      hilog.warn(0x0001, 'SshTerminal', 'readDeviceIsLandscape failed: ' + JSON.stringify(err));
      return false;
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
    const generation: number = this.pageGeneration;
    this.orientationSettleTimer = setTimeout((): void => {
      this.orientationSettleTimer = -1;
      if (!this.isPageGenerationActive(generation) || this.terminalClosing) { return; }
      this.recalcGrid();
      this.forceScrollToBottomRequest = this.forceScrollToBottomRequest + 1;
      this.requestTerminalScrollToBottom();
      // 第一阶段只确认尺寸已停止变化；PTY resize 和 Canvas 属性更新可能还在同一帧之后提交。
      // 保持 transitioning，避免最后一组 onAreaChange 被当作普通布局变化处理。
      this.orientationFinalTimer = setTimeout((): void => {
        this.orientationFinalTimer = -1;
        if (!this.isPageGenerationActive(generation) || this.terminalClosing) { return; }
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
      const generation: number = this.pageGeneration;
      window.getLastWindow(ctx).then((w: window.Window): void => {
        if (!this.isPageGenerationActive(generation) || this.terminalClosing) { return; }
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

  private syncNativeConnectionState(): boolean {
    if (this.sessionId <= 0) { return false; }
    const state: number = this.loader.getConnectionState(this.sessionId);
    if (state === SSH_STATE_CONNECTED) {
      const wasConnected: boolean = this.connected;
      if (!this.terminalClosing) {
        // Native SSH recovery keeps the same session id and callback. Restore
        // the page state when the owner has completed the new handshake.
        this.connected = true;
        this.connecting = false;
        this.scheduleTerminalSurfaceMount(this.pageGeneration, this.sshBindingGeneration,
          this.hostId, this.sessionId);
      }
      if (!wasConnected && !this.terminalClosing) {
        // Match the other connection pages: refresh the device snapshot when
        // the transport becomes usable, not only when the page first appears.
        void this.refreshPhysicalKeyboardPresence('connection-state');
      }
      this.sshTabStore.update(this.hostId, 'connected', this.sessionId);
      return !this.terminalClosing;
    }
    if (state === SSH_STATE_RECONNECTING) {
      // Keep the live terminal surface during a short transport recovery so
      // the latency timer can observe the eventual CONNECTED state. Do not
      // turn a transient reconnect into the page's terminal error screen.
      if (!this.connected) { this.connecting = true; }
      this.sshTabStore.update(this.hostId, 'reconnecting', this.sessionId);
      return false;
    }
    if (state === SSH_STATE_CONNECTING) {
      // resumeSshSession() may publish CONNECTING briefly while the already
      // attached session finishes its native resume gate. Do not tear down a
      // live page binding or hide its surface for that transient state. A
      // session that has not been attached yet still follows the normal
      // connecting branch below.
      if (this.connected && this.sessionId > 0) {
        this.connecting = false;
        this.sshTabStore.update(this.hostId, 'connected', this.sessionId);
        this.scheduleTerminalSurfaceMount(this.pageGeneration, this.sshBindingGeneration,
          this.hostId, this.sessionId);
        return false;
      }
      this.connected = false;
      this.connecting = true;
      this.sshTabStore.update(this.hostId, 'connecting', this.sessionId);
      return false;
    }
    this.connected = false;
    this.connecting = false;
    const message: string = this.loader.getConnectionLastMessage(this.sessionId);
    this.connectionError = message.length > 0 ? message : 'SSH 会话已断开';
    this.markXtermSurfaceNotReady(this.hostId);
    this.sshTabStore.invalidateSession(this.hostId, 'error', this.connectionError);
    return false;
  }

  private probeLatencyOnce(): void {
    if (!this.connected || this.sessionId <= 0 || this.latencyProbeRunning) { return; }
    if (!this.syncNativeConnectionState()) { return; }
    const pageGeneration: number = this.pageGeneration;
    const requestSessionId: number = this.sessionId;
    const probeToken: number = ++this.latencyProbeToken;
    this.latencyProbeRunning = true;
    this.loader.measureSshLatencyAsync(requestSessionId).then((latency: number): void => {
      if (probeToken !== this.latencyProbeToken) { return; }
      if (!this.isPageGenerationActive(pageGeneration) || this.sessionId !== requestSessionId) {
        this.latencyProbeRunning = false;
        return;
      }
      this.latencyMs = latency;
      this.latencyProbeRunning = false;
      this.srv.updateConnectionHealth(this.hostId, latency, false);
    }).catch((err: BusinessError): void => {
      if (probeToken !== this.latencyProbeToken) { return; }
      if (!this.isPageGenerationActive(pageGeneration) || this.sessionId !== requestSessionId) {
        this.latencyProbeRunning = false;
        return;
      }
      this.latencyMs = -1;
      this.latencyProbeRunning = false;
      this.syncNativeConnectionState();
      this.srv.updateConnectionHealth(this.hostId, -1, false);
      hilog.warn(0x0001, 'SshTerminal', '[latency] TCP 检测失败: ' + err.message);
    });
  }

  private startLatencyProbe(): void {
    this.stopLatencyProbe();
    this.probeLatencyOnce();
    this.latencyTimer = setInterval((): void => {
      this.probeLatencyOnce();
    }, 5000);
  }

  private stopLatencyProbe(): void {
    ++this.latencyProbeToken;
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
  private preflightHostId: string = '';
  private preflightPassphrase: string = '';
  private preflightProxyPassphrase: string = '';
  private preflightExpectedHostKeyRaw: string = '';
  private preflightExpectedHostKeyFp: string = '';
  private preflightExpectedJumpHostKeyRaw: string = '';
  private preflightExpectedJumpHostKeyFp: string = '';

  private clearPreflightBinding(): void {
    this.preflightHostId = '';
    this.preflightPassphrase = '';
    this.preflightProxyPassphrase = '';
    this.preflightExpectedHostKeyRaw = '';
    this.preflightExpectedHostKeyFp = '';
    this.preflightExpectedJumpHostKeyRaw = '';
    this.preflightExpectedJumpHostKeyFp = '';
  }

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
          .onMouse(this.handleTerminalMouse)
          .onAxisEvent(this.handleTerminalAxis)
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

  private async connect(host: RemoteHost, pageGeneration: number,
    bindingGeneration: number): Promise<void> {
    const bindingHostId: string = host.id.trim();
    if (!this.isSshBindingActive(pageGeneration, bindingGeneration, bindingHostId)) { return; }
    this.sshTabStore.open(bindingHostId, host.label,
      host.username + '@' + host.host + ':' + host.port.toString());
    this.sshTabStore.activate(bindingHostId);
    this.sshTabStore.beginConnection(bindingHostId);
    this.markXtermSurfaceNotReady(bindingHostId);
    this.refreshSshTabViews();
    try {
      if (!(await this.loader.waitForPendingTeardown())) {
        throw new Error('上一会话资源清理未完成 [E-TEARDOWN-PENDING]');
      }
      if (!this.isSshBindingActive(pageGeneration, bindingGeneration, bindingHostId)) { return; }
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
      let proxyKeyData: string = '';
      let proxyKeyEncryptedHint: boolean = false;
      if (host.sshProxyKeyId !== '') {
        const proxyKey = KeyVaultService.getInstance().getSshKey(host.sshProxyKeyId);
        if (proxyKey) {
          proxyKeyData = proxyKey.privateKey;
          proxyKeyEncryptedHint = proxyKey.privateKeyEncrypted;
        }
      }
      const useKey: boolean = host.sshUseKey && keyData.length > 0;
      // T-210: 优先使用 preflight token 中的 passphrase; 否则用 host 保存的; 最后才弹窗
      const preflightMatchesHost: boolean = this.preflightHostId === host.id;
      let resolvedProxyPassphrase: string = (preflightMatchesHost ? this.preflightProxyPassphrase : '') ||
        host.sshProxyKeyPassphrase || '';
      if (host.sshProxyType === 'ssh_jump' && host.sshProxyAuthMethod === 'publickey') {
        if (proxyKeyData.length === 0) {
          throw new Error('跳板机私钥不存在或已从密钥保险库移除 [E-SSH-PROXY-KEY-MISSING]');
        }
        let proxyKeyInfo: SshPrivateKeyInfo = this.loader.inspectSshPrivateKey(
          proxyKeyData, resolvedProxyPassphrase);
        if (proxyKeyInfo.ok && !proxyKeyInfo.encrypted) {
          resolvedProxyPassphrase = '';
        } else if (resolvedProxyPassphrase === '' || proxyKeyEncryptedHint || !proxyKeyInfo.ok) {
          resolvedProxyPassphrase = await this.promptPassphrase();
          if (!this.isSshBindingActive(pageGeneration, bindingGeneration, bindingHostId)) { return; }
          proxyKeyInfo = this.loader.inspectSshPrivateKey(proxyKeyData, resolvedProxyPassphrase);
          if (!proxyKeyInfo.ok) {
            throw new Error('跳板机私钥密码错误或密钥不可用 [E-SSH-PROXY-PASSPHRASE]');
          }
        }
      }
      let keyPassphrase: string = (preflightMatchesHost ? this.preflightPassphrase : '') ||
        host.sshKeyPassphrase || '';
      if (useKey) {
        const keyInfo: SshPrivateKeyInfo = this.loader.inspectSshPrivateKey(keyData, keyPassphrase);
        if (keyInfo.ok && !keyInfo.encrypted) {
          keyPassphrase = '';
        } else if (keyPassphrase === '' && (keyEncryptedHint || keyInfo.encrypted)) {
          // fallback: 无 preflight token 时弹窗 (兼容直接路由进入的旧路径)
          keyPassphrase = await this.promptPassphrase();
          if (!this.isSshBindingActive(pageGeneration, bindingGeneration, bindingHostId)) { return; }
        }
      }
      if (!this.isSshBindingActive(pageGeneration, bindingGeneration, bindingHostId)) { return; }

      const cfg: SessionConfig = {
        protocol: 'ssh',
        host: host.host,
        port: host.port,
        username: host.username,
        password: host.password,
        width: this.termCols,
        height: this.termRows,
        customHostname: host.customHostname,
        // SSH route is explicit. ProxyJump carries a separate bastion
        // credential and never falls back to the target credential.
        gatewayHost: '',
        gatewayPort: 0,
        sshRoute: this.sshRouteForHost(host),
        sshJumpHopHandoffs: this.sshJumpHopHandoffsForHost(
          host, proxyKeyData, resolvedProxyPassphrase),
        sshProxyType: host.proxyHost.length > 0 ? host.sshProxyType : 'direct',
        sshProxyHost: host.proxyHost,
        sshProxyPort: host.proxyPort,
        sshProxyUsername: host.proxyUsername,
        sshProxyPassword: '',
        sshProxyAuthMethod: host.sshProxyType === 'ssh_jump' ? host.sshProxyAuthMethod : undefined,
        sshProxyPrivateKeyPem: '',
        sshProxyPrivateKeyPassphrase: '',
        domain: '',
        codec: '',
        multiMonitor: false,
        monitorCount: 1,
        colorDepth: 32,
        authMethod: useKey ? 'publickey' : 'password',
        privateKeyPem: useKey ? keyData : '',
        privateKeyPassphrase: keyPassphrase,
        expectedHostKeyRawBase64: (preflightMatchesHost ? this.preflightExpectedHostKeyRaw : '') ||
          host.sshHostKeyRawBase64,
        expectedHostKeyFingerprintSha256: (preflightMatchesHost ? this.preflightExpectedHostKeyFp : '') ||
          host.sshHostKeyFingerprintSha256,
        sshJumpHostKeyRawBase64: (preflightMatchesHost ? this.preflightExpectedJumpHostKeyRaw : '') ||
          host.sshJumpHostKeyRawBase64,
        sshJumpHostKeyFingerprintSha256: (preflightMatchesHost ? this.preflightExpectedJumpHostKeyFp : '') ||
          host.sshJumpHostKeyFingerprintSha256
      };
      const connectedSessionId: number = await this.loader.connectSshAsync(cfg);
      if (!this.isSshBindingActive(pageGeneration, bindingGeneration, bindingHostId)) {
        // ExtensionLoader cancels an in-flight connect during page teardown;
        // only disconnect a resolved session if it is still the current one.
        if (connectedSessionId > 0) { this.loader.disconnectSshSession(connectedSessionId); }
        return;
      }
      hilog.info(0x0001, 'SshTerminal',
        '[connect] sessionId=' + connectedSessionId.toString() + ' auth=' + cfg.authMethod);
      if (connectedSessionId <= 0) {
        throw new Error('连接失败 (code=' + connectedSessionId.toString() + ')');
      }
      if (!await this.attachSshSession(
        pageGeneration, bindingGeneration, connectedSessionId, bindingHostId)) {
        if (this.isSshBindingActive(pageGeneration, bindingGeneration, bindingHostId)) {
          throw new Error('SSH 会话重新绑定失败');
        }
        return;
      }
    } catch (err) {
      const msg: string = (err as Error).message || 'SSH 连接失败';
      if (!this.isSshBindingActive(pageGeneration, bindingGeneration, bindingHostId)) { return; }
      this.connecting = false;
      await this.srv.updateConnectionHealth(bindingHostId, -1, false);
      if (!this.isSshBindingActive(pageGeneration, bindingGeneration, bindingHostId)) { return; }
      hilog.error(0x0001, 'SshTerminal', '[connect] 异常: ' + msg);
      this.connectionError = msg;
      this.sshTabStore.invalidateSession(bindingHostId, 'error', msg);
      this.refreshSshTabViews();
    }
  }

  /** Bind page-owned rendering/input state to a live native SSH session. */
  private async attachSshSession(pageGeneration: number, bindingGeneration: number,
    connectedSessionId: number, bindingHostId: string): Promise<boolean> {
    if (connectedSessionId <= 0 ||
      !this.isSshBindingActive(pageGeneration, bindingGeneration, bindingHostId)) { return false; }
    this.sessionId = connectedSessionId;
    const sessionGeneration: number = this.loader.getSshTerminalDiagnostics(
      connectedSessionId).sessionGeneration;
    if (!this.isSshBindingActive(pageGeneration, bindingGeneration, bindingHostId)) {
      this.loader.disconnectSshSession(connectedSessionId);
      this.sessionId = -1;
      return false;
    }
    this.sshSessionGeneration = sessionGeneration;
    this.sshTabStore.update(bindingHostId, 'connected', connectedSessionId, '', sessionGeneration);
    this.refreshSshTabViews();
    if (!this.isSshBindingActive(pageGeneration, bindingGeneration, bindingHostId) ||
      this.sessionId !== connectedSessionId) {
      this.loader.disconnectSshSession(connectedSessionId);
      this.sessionId = -1;
      return false;
    }
    // 推送式数据接收: C++ reader 线程读到数据 → TSFN → 这里
    let dataChunkCount: number = 0;
    this.loader.setOnDataCallback(connectedSessionId, (data: ArrayBuffer): void => {
      if (!data || data.byteLength === 0 || !this.isPageGenerationActive(pageGeneration) ||
        this.terminalClosing) { return; }
      const currentBinding: boolean = this.isSshBindingActive(
        pageGeneration, bindingGeneration, bindingHostId) &&
        this.sessionId === connectedSessionId &&
        this.sshSessionGeneration === sessionGeneration;
      dataChunkCount++;
      if (dataChunkCount <= 5 || dataChunkCount % 100 === 0) {
        hilog.info(0x0000, 'SshTerminal',
          'SSH data #' + dataChunkCount.toString() + ' len=' + data.byteLength.toString() +
          ' host=' + bindingHostId + ' active=' + (currentBinding ? '1' : '0') +
          ' seq=' + (this.termOutputSequence + 1).toString());
      }
      if (currentBinding) {
        this.enqueueTerminalOutput(data);
      } else {
        this.enqueueDetachedTerminalOutput(bindingHostId, data);
      }
    });
    if (!this.loader.resumeSshSession(connectedSessionId)) {
      this.loader.disconnectSshSession(connectedSessionId);
      this.sessionId = -1;
      this.resetTerminalSurfaceBinding();
      this.connected = false;
      this.connecting = false;
      return false;
    }

    this.sftpTaskEngine.attachSession({
      hostId: bindingHostId,
      sessionId: connectedSessionId,
      generation: sessionGeneration
    });

    if (!this.isSshBindingActive(pageGeneration, bindingGeneration, bindingHostId) ||
      this.sessionId !== connectedSessionId) {
      this.loader.disconnectSshSession(connectedSessionId);
      this.sessionId = -1;
      return false;
    }

    // Do not advertise a session as connected until the page-owned callback
    // and the detached-session resume gate are both installed. This keeps an
    // Ability exit during the preceding await from starting PiP for a session
    // that was never fully rebound to the page.
    this.connected = true;
    this.connecting = false;
    // A keyboard can be attached while SSH is negotiating. Re-enumerate at
    // the same connection boundary used by RDP/RustDesk before routing input.
    void this.refreshPhysicalKeyboardPresence('connection-state');
    // Persisting the last-connected timestamp is ancillary. It must never sit
    // in front of the visible binding or prevent the new tab from rendering.
    void this.srv.updateLastConnected(bindingHostId).catch((err: Error): void => {
      hilog.warn(0x0001, 'SshTerminal',
        '[tab] last-connected persistence failed: ' + JSON.stringify(err));
    });
    this.refreshSshTabViews();
    this.scheduleTerminalSurfaceMount(pageGeneration, bindingGeneration, bindingHostId,
      connectedSessionId);
    this.startLatencyProbe();
    void this.prepareSshPip(pageGeneration, bindingGeneration, bindingHostId);

    if (this.isDesktopDevice) {
      setTimeout((): void => {
        if (this.isSshBindingActive(pageGeneration, bindingGeneration, bindingHostId) &&
          this.sessionId === connectedSessionId) {
          this.focusKeyboard();
        }
      }, 100);
    }
    return true;
  }

  private makeSshPipInfo(status: string = '已连接'): SshTerminalPipInfo {
    return {
      hostLabel: this.hostLabel,
      hostAddress: this.userAtHost.length > 0 ? this.userAtHost :
        (this.sshHost + ':' + this.sshPort.toString()),
      status: status,
      outputSummary: this.termOutput
    };
  }

  private async prepareSshPip(pageGeneration: number, bindingGeneration: number,
    bindingHostId: string): Promise<void> {
    if (!this.isSshBindingActive(pageGeneration, bindingGeneration, bindingHostId) ||
      this.sessionId <= 0) {
      return;
    }
    try {
      const context: common.UIAbilityContext =
        this.getUIContext().getHostContext() as common.UIAbilityContext;
      const prepared: boolean = await this.sshPipService.prepare(
        context, this.makeSshPipInfo(), (reason: string): void => {
          hilog.info(0x0017, 'SshTerminal', 'SSH PiP stopped reason=' + reason);
        });
      if (prepared && this.isSshBindingActive(pageGeneration, bindingGeneration, bindingHostId)) {
        hilog.info(0x0017, 'SshTerminal', 'SSH PiP prepared session=' + this.sessionId.toString());
      }
    } catch (err) {
      hilog.warn(0x0017, 'SshTerminal', 'SSH PiP prepare failed: ' + JSON.stringify(err));
    }
  }

  private async retryConnection(): Promise<void> {
    if (this.terminalClosing || this.connecting || this.hostId.length === 0) { return; }
    const pageGeneration: number = this.pageGeneration;
    const bindingHostId: string = this.hostId;
    const bindingGeneration: number = ++this.sshBindingGeneration;
    const host: RemoteHost | undefined = this.srv.getHost(this.hostId);
    if (!host) {
      this.connectionError = '主机记录不存在';
      return;
    }
    this.connecting = true;
    this.connectionError = '';
    this.nativeRendererUnavailable = false;
    this.terminalSurfaceGeneration = this.terminalSurfaceGeneration + 1;
    this.resetTerminalSurfaceBinding();
    this.sshTabStore.beginConnection(this.hostId);
    this.refreshSshTabViews();
    this.terminalOutputQueueOverflowed = false;
    this.clearTerminalInputQueue();
    // A reconnect pauses an in-flight SFTP continuation at its last durable
    // checkpoint. It is not a user cancellation and remains retryable.
    this.sftpWaitingForConnection = true;
    this.sftpCancelRequested = true;
    if (this.sftpTransferSession !== null && this.sftpBusy) {
      this.sftpTaskStore.command(this.sftpTransferSession.id, { kind: 'detach' });
      this.persistSftpTaskMetadata('waitingForConnection');
    }
    if (this.sessionId > 0) {
      this.sftpTaskEngine.detachSession(this.hostId, this.sessionId);
      this.loader.disconnectSshSession(this.sessionId);
      await this.loader.waitForPendingTeardown();
    }
    this.sessionId = -1;
    this.sshSessionGeneration = 0;
    this.connected = false;
    if (!this.isSshBindingActive(pageGeneration, bindingGeneration, bindingHostId)) { return; }
    await this.connect(host, pageGeneration, bindingGeneration);
  }

  /** Explicit page exit owns the SSH session; ordinary page disposal only detaches the view. */
  private closeSessionAndBack(): void {
    if (this.terminalClosing) { return; }
    this.explicitSessionClose = true;
    const sftpVisible: boolean = this.showSftpPanel || this.showSftpSheet ||
      this.sftpPeerHostPicker;
    if (sftpVisible) {
      this.closeSftpPanel();
      return;
    }
    router.back();
  }

  /**
   * 将当前 chunk 解码给旧 ArkTS fallback renderer，同时保留跨 chunk 的
   * UTF-8 尾部。Native renderer 不使用该字符串，而是直接消费 bytes。
   */
  private decodeTerminalChunk(data: ArrayBuffer, hostId: string = ''): string {
    const requestedHostId: string = hostId.trim();
    const normalizedHostId: string = requestedHostId.length > 0 ? requestedHostId : this.hostId.trim();
    const previous: Uint8Array = this.terminalFallbackDecodeRemainders.get(normalizedHostId) ??
      new Uint8Array(0);
    const decoded: TerminalDecodedChunk = this.decodeTerminalBytes(data, previous);
    this.terminalFallbackDecodeRemainders.set(normalizedHostId, decoded.remainder);
    if (normalizedHostId === this.hostId.trim()) {
      this.terminalDecodeRemainder = decoded.remainder;
    }
    return decoded.text;
  }

  private decodeTranscriptChunk(hostId: string, data: ArrayBuffer): string {
    const normalizedHostId: string = hostId.trim();
    const previous: Uint8Array = this.terminalTranscriptDecodeRemainders.get(normalizedHostId) ??
      new Uint8Array(0);
    const decoded: TerminalDecodedChunk = this.decodeTerminalBytes(data, previous);
    this.terminalTranscriptDecodeRemainders.set(normalizedHostId, decoded.remainder);
    return decoded.text;
  }

  private decodeTerminalBytes(data: ArrayBuffer, remainder: Uint8Array): TerminalDecodedChunk {
    const incoming: Uint8Array = new Uint8Array(data);
    const merged: Uint8Array = new Uint8Array(
      remainder.length + incoming.length);
    merged.set(remainder, 0);
    merged.set(incoming, remainder.length);

    let continuationCount: number = 0;
    let leadIndex: number = merged.length;
    while (leadIndex > 0 && continuationCount < 3 &&
      (merged[leadIndex - 1] & 0xC0) === 0x80) {
      leadIndex--;
      continuationCount++;
    }
    let expectedLength: number = 0;
    if (leadIndex < merged.length) {
      const lead: number = merged[leadIndex];
      if ((lead & 0xE0) === 0xC0) { expectedLength = 2; }
      else if ((lead & 0xF0) === 0xE0) { expectedLength = 3; }
      else if ((lead & 0xF8) === 0xF0) { expectedLength = 4; }
    }
    // A trailing continuation byte is not necessarily an incomplete code
    // point: when the lead byte plus all continuations are already present,
    // decode the sequence in this chunk. Only retain a genuinely incomplete
    // suffix for the next push event.
    const incompleteSuffix: boolean = leadIndex < merged.length && expectedLength > 0 &&
      continuationCount + 1 < expectedLength;
    const prefixLength: number = incompleteSuffix ? leadIndex : merged.length;
    const nextRemainder: Uint8Array = merged.slice(prefixLength);
    if (prefixLength === 0) {
      return { text: '', remainder: nextRemainder };
    }
    return {
      text: this.terminalDecoder.decodeToString(merged.slice(0, prefixLength)),
      remainder: nextRemainder
    };
  }

  private virtualModifiers(): TerminalModifierState {
    return { ctrl: this.ctrlActive, alt: this.altActive, shift: this.shiftActive };
  }

  private sendTerminalBytes(data: string, control: boolean = false): void {
    this.queueTerminalInput(data, control);
  }

  private onTerminalModeChange(mode: TerminalCoreMode): void {
    this.bracketedPasteEnabled = mode.bracketedPaste;
    this.terminalMouseTracking = mode.mouseTracking;
    this.terminalSgrMouse = mode.sgrMouse;
    this.terminalApplicationCursorKeys = mode.applicationCursorKeys;
    this.terminalApplicationKeypad = mode.applicationKeypad;
  }

  private replayNativeOutputToXterm(hostId: string): void {
    const normalizedHostId: string = hostId.trim();
    if (normalizedHostId.length === 0) { return; }
    const buffer: TerminalInputBuffer | undefined =
      this.nativeTerminalInputBuffers.get(normalizedHostId);
    // Every raw chunk placed in this buffer is also committed to the bounded
    // transcript. Rebuild the xterm document from that single source even if
    // the native renderer already drained the byte buffer before it failed.
    if (buffer !== undefined) { buffer.clear(); }
    this.terminalFallbackDecodeRemainders.set(normalizedHostId, new Uint8Array(0));
    const xtermOutputBuffer: XtermOutputBuffer =
      this.xtermOutputBufferForHost(normalizedHostId);
    xtermOutputBuffer.clear();
    const transcript: string = this.sshTranscriptStore.snapshot(normalizedHostId);
    if (transcript.length > 0) { xtermOutputBuffer.enqueue(transcript); }
    this.termOutputSequence++;
  }

  private onNativeRendererReady(hostId: string, surfaceIdentity: string): void {
    if (this.terminalClosing || this.hostId.trim() !== hostId.trim() ||
      this.terminalSurfaceBindingKey.trim() !== surfaceIdentity.trim() ||
      !this.terminalSurfaceMounted ||
      !this.shouldUseNativeTerminal()) { return; }
    if (this.terminalRendererReadyTimer !== -1) {
      clearTimeout(this.terminalRendererReadyTimer);
      this.terminalRendererReadyTimer = -1;
    }
    this.xtermReady = true;
    this.focusKeyboard(false);
    this.requestTerminalScrollToBottomSettled();
  }

  private onNativeRendererUnavailable(hostId: string, surfaceIdentity: string): void {
    if (this.terminalClosing || this.hostId.trim() !== hostId.trim() ||
      this.terminalSurfaceBindingKey.trim() !== surfaceIdentity.trim() ||
      !this.terminalSurfaceMounted) { return; }
    if (this.terminalRendererReadyTimer !== -1) {
      clearTimeout(this.terminalRendererReadyTimer);
      this.terminalRendererReadyTimer = -1;
    }
    if (this.nativeRendererUnavailable) { return; }
    hilog.warn(0x0000, 'SshTerminal',
      '[terminal] native renderer unavailable, fallback host=' + hostId);
    this.nativeRendererUnavailable = true;
    this.xtermReady = false;
    this.terminalSurfaceCommitSequence = this.terminalSurfaceCommitSequence + 1;
    this.terminalSurfaceViewKey = makeSshTerminalSurfaceRenderKey(hostId,
      surfaceIdentity, this.terminalSurfaceRenderRevision, false);
    this.replayNativeOutputToXterm(hostId);
    // The fallback document is a new visible renderer. Advance the same
    // page-owned repaint fence used by the native path so its initial output
    // cannot depend on a coincidentally delivered output sequence watch.
    this.terminalSurfaceRefreshRequest = this.terminalSurfaceRefreshRequest + 1;
    this.requestTerminalScrollToBottomSettled();
  }

  /** 发送文本到 SSH 服务端; 修饰键 active 时由统一策略编码组合。 */
  private onTerminalData(data: string): void {
    const encoded: string = encodeTextInput(data, this.virtualModifiers());
    this.sendTerminalBytes(encoded, this.isTerminalControlSequence(encoded));
  }

  /** xterm owns physical keyboard/IME encoding; forward only the active tab. */
  private onXtermDataForHost(hostId: string, sessionGeneration: number, data: string,
    surfaceIdentity: string): void {
    const normalizedHostId: string = hostId.trim();
    const reportedRevision: number = sshXtermTabRenderRevision(sessionGeneration);
    if (data.length === 0 || this.terminalClosing || normalizedHostId !== this.hostId.trim() ||
      this.xtermSurfaceIdentityForHost(normalizedHostId, reportedRevision) !== surfaceIdentity.trim() ||
      reportedRevision !==
        this.xtermSurfaceGenerationForHost(normalizedHostId)) { return; }
    this.sendTerminalBytes(data, this.isTerminalControlSequence(data));
  }

  private onXtermReadyForHost(hostId: string, sessionGeneration: number,
    surfaceIdentity: string): void {
    const normalizedHostId: string = hostId.trim();
    const reportedRevision: number = sshXtermTabRenderRevision(sessionGeneration);
    const expectedRevision: number = this.xtermSurfaceGenerationForHost(normalizedHostId);
    if (this.terminalClosing || normalizedHostId.length === 0) { return; }
    if (this.xtermSurfaceIdentityForHost(normalizedHostId, reportedRevision) !==
      surfaceIdentity.trim()) {
      hilog.warn(0x0000, 'SshTerminal', '[xterm] ready identity rejected host=' + normalizedHostId +
        ' reported=' + reportedRevision.toString() + ' surface=' + surfaceIdentity);
      return;
    }
    if (reportedRevision !== expectedRevision) {
      hilog.warn(0x0000, 'SshTerminal', '[xterm] ready generation rejected host=' + normalizedHostId +
        ' reported=' + reportedRevision.toString() + ' expected=' + expectedRevision.toString());
      return;
    }
    this.xtermReadyGenerations.set(normalizedHostId, reportedRevision);
    if (normalizedHostId === this.hostId.trim()) {
      this.xtermReady = true;
      this.focusKeyboard(false);
      this.requestTerminalScrollToBottomSettled();
    }
  }

  private onXtermResizeForHost(hostId: string, sessionGeneration: number, cols: number,
    rows: number, surfaceIdentity: string): void {
    const normalizedHostId: string = hostId.trim();
    const reportedRevision: number = sshXtermTabRenderRevision(sessionGeneration);
    if (this.terminalClosing || normalizedHostId !== this.hostId.trim() ||
      this.xtermSurfaceIdentityForHost(normalizedHostId, reportedRevision) !== surfaceIdentity.trim() ||
      reportedRevision !==
        this.xtermSurfaceGenerationForHost(normalizedHostId)) { return; }
    const nextCols: number = Math.max(20, Math.min(300, Math.floor(cols)));
    const nextRows: number = Math.max(3, Math.min(80, Math.floor(rows)));
    if (nextCols === this.termCols && nextRows === this.termRows) { return; }
    this.termCols = nextCols;
    this.termRows = nextRows;
    this.schedulePtyResize();
  }

  private setVirtualModifier(modifier: string, active: boolean): void {
    if (modifier === 'ctrl') { this.ctrlActive = active; }
    else if (modifier === 'alt') { this.altActive = active; }
    else if (modifier === 'shift') { this.shiftActive = active; }
  }

  private focusKeyboard(openSoftwareKeyboard: boolean = false): void {
    this.terminalFocusMode = true;
    if (openSoftwareKeyboard && this.virtualKeyBarVisible()) {
      this.softKeyboardRequested = true;
    }
    // ArkWeb's helper textarea is not a reliable HarmonyOS IME anchor. Keep
    // the existing native TextInput as the single input owner after xterm is
    // ready; its key/IME policy handles both physical and virtual keyboards.
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
    // libssh2 reports entries from the relative current directory as
    // "./name". Keep the same spelling for mutations so identity lookups and
    // atomic rename compare the exact same remote reference.
    if (d === '.') { return './' + cleanName; }
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
    if (!Number.isFinite(size) || size < 0) { return '未知大小'; }
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

  private async refreshSftp(path?: string): Promise<void> {
    if (this.terminalClosing || this.sessionId <= 0 || this.sftpBusy) { return; }
    this.clearSftpRefreshTimer();
    this.invalidateSftpRefreshRequest();
    const target: string = this.normalizeRemoteDir(path || this.sftpPath);
    const requestSessionId: number = this.sessionId;
    const requestSessionGeneration: number = this.sshSessionGeneration;
    const requestPageGeneration: number = this.pageGeneration;
    const requestToken: number = this.sftpRefreshRequestToken;
    this.sftpRefreshOwnerToken = requestToken;
    this.sftpBusy = true;
    this.sftpStatus = '正在读取远端目录...';
    this.sftpRefreshTimeoutTimer = setTimeout((): void => {
      if (!this.isSftpRefreshRequestActive(requestPageGeneration, requestSessionId,
        requestSessionGeneration, requestToken) || !this.sftpBusy) {
        return;
      }
      this.sftpRefreshTimeoutTimer = -1;
      this.invalidateSftpRefreshRequest();
      this.sftpBusy = false;
      this.sftpStatus = '[SFTP-LIST] 读取目录超时，请重试';
    }, SFTP_LIST_TIMEOUT_MS);
    try {
      const result = await this.loader.listRemoteDirAsync(requestSessionId, target);
      if (!this.isSftpRefreshRequestActive(requestPageGeneration, requestSessionId,
        requestSessionGeneration, requestToken)) { return; }
      if (result.errorCode < 0) {
        this.sftpStatus = '[SFTP-LIST] 读取目录失败 ret=' + result.errorCode.toString();
        return;
      }
      const entries: SftpFileEntry[] = result.entries;
      this.sftpEntries = this.sortSftpEntries(entries);
      this.sftpPath = target;
      this.sftpPathInput = target;
      this.sftpSelectedPath = '';
      this.sftpSelectedName = '';
      this.sftpSelectedIsDir = false;
      this.sftpSelectedSize = 0;
      this.sftpSelectedMtime = -1;
      this.sftpNameInput = '';
      this.sftpStatus = '已加载 ' + entries.length.toString() + ' 项';
    } catch (err) {
      if (this.isSftpRefreshRequestActive(requestPageGeneration, requestSessionId,
        requestSessionGeneration, requestToken)) {
        this.sftpStatus = '[SFTP-LIST] 读取目录失败: ' + JSON.stringify(err);
      }
    } finally {
      if (!this.isSftpRefreshRequestActive(requestPageGeneration, requestSessionId,
        requestSessionGeneration, requestToken)) { return; }
      this.clearSftpRefreshTimeout();
      this.sftpRefreshOwnerToken = 0;
      this.sftpBusy = false;
    }
  }

  private openSftpPanel(): void {
    if (this.terminalClosing) { return; }
    if (this.sftpRootSheetClosing || this.sftpCloseRootAfterPeerPicker) {
      // ArkUI keeps the old native sheet alive during its exit animation. Do
      // not mutate that instance; replay the user's open after onDisappear.
      this.sftpRootSheetReopenRequested = true;
      return;
    }
    this.sftpPanelOpenedAt = Date.now();
    this.showSshTabPicker = false;
    this.requestSftpPeerHostPickerClose();
    // A closed surface starts with an empty right pane. Do not reset a sheet
    // that is already visible, because a repeated toolbar tap must not erase
    // the user's current endpoint while a transfer is running.
    const surfaceAlreadyVisible: boolean = this.showSftpPanel || this.showSftpSheet;
    if (!surfaceAlreadyVisible) {
      this.resetSftpRightEndpointSelection();
    }
    this.showSftpPanel = true;
    // Phone and Pad use the root bindSheet; only PC keeps the workspace inline.
    // Give the parent content one UI turn to mount before opening the native
    // sheet host. This prevents the nested host-picker bindSheet from being
    // attached to a stale SFTP content instance.
    if (this.sftpUsesRootBindSheet() && !this.showSftpSheet) {
      this.scheduleSftpRootSheetOpen();
    }
    if (this.sftpEntries.length === 0) {
      // 先让半模态完成挂载和高度测量, 避免打开瞬间刷新目录触发重建后被系统反向 dismiss。
      this.scheduleSftpRefresh(this.sftpPath, 260);
    }
  }

  private clearSftpSheetTransitionTimers(): void {
    if (this.sftpRootSheetOpenTimer !== -1) {
      clearTimeout(this.sftpRootSheetOpenTimer);
      this.sftpRootSheetOpenTimer = -1;
    }
    if (this.sftpPeerHostPickerOpenTimer !== -1) {
      clearTimeout(this.sftpPeerHostPickerOpenTimer);
      this.sftpPeerHostPickerOpenTimer = -1;
    }
  }

  private scheduleSftpRootSheetOpen(): void {
    this.clearSftpSheetTransitionTimers();
    const token: number = ++this.sftpSheetTransitionToken;
    this.sftpRootSheetOpenTimer = setTimeout((): void => {
      this.sftpRootSheetOpenTimer = -1;
      if (token !== this.sftpSheetTransitionToken || this.terminalClosing ||
        !this.showSftpPanel || this.sftpRootSheetClosing || !this.sftpUsesRootBindSheet()) {
        return;
      }
      ++this.sftpRootSheetMountToken;
      this.showSftpSheet = true;
    }, 32);
  }

  private scheduleSftpRootSheetReopen(): void {
    this.clearSftpSheetTransitionTimers();
    const token: number = ++this.sftpSheetTransitionToken;
    this.sftpRootSheetOpenTimer = setTimeout((): void => {
      this.sftpRootSheetOpenTimer = -1;
      if (token !== this.sftpSheetTransitionToken || this.terminalClosing ||
        this.sftpRootSheetClosing || !this.sftpRootSheetReopenRequested) {
        return;
      }
      this.sftpRootSheetReopenRequested = false;
      this.openSftpPanel();
    }, 32);
  }

  private dismissSftpRootSheet(): void {
    this.clearSftpSheetTransitionTimers();
    ++this.sftpSheetTransitionToken;
    this.sftpCloseRootAfterPeerPicker = false;
    if (this.showSftpSheet) {
      this.sftpRootSheetClosing = true;
      this.noteSftpSheetDismissalIfVisible();
    } else if (!this.sftpRootSheetClosing) {
      this.sftpRootSheetClosing = false;
    }
    ++this.sftpPeerHostPickerMountToken;
    ++this.sftpPeerHostPickerTransitionToken;
    this.sftpPeerHostPickerReopenRequested = false;
    this.sftpPeerHostPickerClosing = false;
    this.sftpPeerHostPicker = false;
    this.showSftpPanel = false;
    this.showSftpSheet = false;
  }

  private handleSftpRootSheetDisappear(mountToken: number): void {
    if (mountToken !== this.sftpRootSheetMountToken) { return; }
    this.noteSftpSheetDismissalIfVisible();
    this.clearSftpSheetTransitionTimers();
    ++this.sftpSheetTransitionToken;
    this.sftpRootSheetClosing = false;
    this.sftpCloseRootAfterPeerPicker = false;
    ++this.sftpPeerHostPickerMountToken;
    ++this.sftpPeerHostPickerTransitionToken;
    this.sftpPeerHostPickerReopenRequested = false;
    this.sftpPeerHostPickerClosing = false;
    this.sftpPeerHostPicker = false;
    this.showSftpPanel = false;
    this.showSftpSheet = false;
    if (this.sftpRootSheetReopenRequested && !this.terminalClosing) {
      this.scheduleSftpRootSheetReopen();
    } else {
      this.sftpRootSheetReopenRequested = false;
    }
  }

  private handleSftpPeerHostPickerDisappear(mountToken: number): void {
    if (mountToken !== this.sftpPeerHostPickerMountToken) { return; }
    this.sftpPeerHostPicker = false;
    this.sftpPeerHostPickerClosing = false;
    if (this.sftpCloseRootAfterPeerPicker) {
      if (this.terminalClosing) { return; }
      // The child native Sheet is now gone. Give ArkUI one turn to commit that
      // transition before toggling the parent Sheet; no timeout may close the
      // parent while the child is still animating out.
      const token: number = ++this.sftpSheetTransitionToken;
      setTimeout((): void => {
        if (token !== this.sftpSheetTransitionToken || this.terminalClosing ||
          sftpPeerPickerExitPending(this.sftpPeerHostPicker, this.sftpPeerHostPickerClosing) ||
          !this.sftpCloseRootAfterPeerPicker) {
          return;
        }
        this.dismissSftpRootSheet();
      }, 0);
      return;
    }
    if (this.terminalClosing) {
      this.sftpPeerHostPickerReopenRequested = false;
      return;
    }
    if (this.sftpPeerHostPickerReopenRequested && this.showSftpPanel &&
      !this.sftpRootSheetClosing && (!this.sftpUsesRootBindSheet() || this.showSftpSheet)) {
      this.scheduleSftpPeerHostPickerReopen();
    } else {
      this.sftpPeerHostPickerReopenRequested = false;
    }
  }

  private scheduleSftpPeerHostPickerReopen(): void {
    if (this.sftpPeerHostPickerOpenTimer !== -1) {
      clearTimeout(this.sftpPeerHostPickerOpenTimer);
    }
    const token: number = ++this.sftpPeerHostPickerTransitionToken;
    this.sftpPeerHostPickerOpenTimer = setTimeout((): void => {
      this.sftpPeerHostPickerOpenTimer = -1;
      if (token !== this.sftpPeerHostPickerTransitionToken || this.terminalClosing ||
        !this.sftpPeerHostPickerReopenRequested || !this.showSftpPanel ||
        this.sftpRootSheetClosing || this.sftpCloseRootAfterPeerPicker ||
        this.sftpPeerHostPickerClosing || this.sftpPeerHostPicker ||
        (this.sftpUsesRootBindSheet() && !this.showSftpSheet)) {
        return;
      }
      this.sftpPeerHostPickerReopenRequested = false;
      ++this.sftpPeerHostPickerMountToken;
      this.sftpPeerHostPicker = true;
    }, 32);
  }

  private noteSftpSheetDismissalIfVisible(): void {
    if (this.showSftpSheet) {
      noteSshSftpSheetDismissed(Date.now());
    }
  }

  private requestSftpPeerHostPickerClose(): void {
    this.sftpPeerHostPickerReopenRequested = false;
    if (!this.sftpPeerHostPicker) { return; }
    this.sftpPeerHostPickerClosing = true;
    this.sftpPeerHostPicker = false;
  }

  private closeSftpPanel(): void {
    if (sftpPeerPickerExitPending(this.sftpPeerHostPicker, this.sftpPeerHostPickerClosing)) {
      this.sftpCloseRootAfterPeerPicker = true;
      this.requestSftpPeerHostPickerClose();
      return;
    }
    this.dismissSftpRootSheet();
  }

  private openSftpPeerPicker(): void {
    if (this.sftpBusy || this.terminalClosing || !this.showSftpPanel ||
      this.sftpRootSheetClosing || this.sftpCloseRootAfterPeerPicker ||
      this.sftpPeerHostPicker) { return; }
    if (this.sftpPeerHostPickerClosing) {
      this.sftpPeerHostPickerReopenRequested = true;
      return;
    }
    if (this.sftpUsesRootBindSheet() && !this.showSftpSheet) { return; }
    // Keep the current right endpoint visible until the user commits a host.
    // The picker is a child bindSheet of the SFTP surface, so it can animate
    // above the phone or Pad SFTP sheet without replacing that surface.
    this.sftpPeerHostPickerReopenRequested = false;
    ++this.sftpPeerHostPickerTransitionToken;
    ++this.sftpPeerHostPickerMountToken;
    this.sftpPeerHostPicker = true;
  }

  private sftpRootSheetHeight(): SheetSize | number {
    // The Pad root surface is the complete two-pane workspace. Keep its
    // geometry independent from the desktop breakpoint so it cannot collapse
    // into a phone-sized sheet during a window-class update.
    return this.isPadDevice ? SheetSize.LARGE : SheetSize.FIT_CONTENT;
  }

  private sftpRootSheetType(): SheetType {
    return this.isPadDevice ? SheetType.CENTER : SheetType.BOTTOM;
  }

  private sftpRootSheetWidth(): Dimension {
    return this.isPadDevice ? '96%' : '100%';
  }

  private sftpSheetMaxHeight(): number {
    if (this.sftpWideLayout()) { return 1400; }
    return this.breakpoint === 'sm' ? 640 : 820;
  }

  private sftpListHeight(): number {
    if (this.sftpWideLayout()) { return 360; }
    return this.breakpoint === 'sm' ? 190 : 220;
  }

  private sftpLocalListHeight(): number {
    return this.sftpWideLayout() ? 160 : this.sftpListHeight();
  }

  private sftpWideLayout(): boolean {
    // Width alone cannot distinguish a phone in landscape from a Pad. Keep
    // the phone workflow on its original bottom sheet and reserve the
    // two-pane workspace for actual Pad/desktop surfaces.
    return this.isDesktopDevice || this.isPadDevice;
  }

  private sftpUsesRootBindSheet(): boolean {
    // A Pad owns the complete two-pane SFTP workspace in a wide root sheet.
    // Phones keep the same root sheet but use the original bottom-sheet flow;
    // PC/2in1 keeps SFTP inline in the resizable desktop workspace.
    return this.isPadDevice || !this.isDesktopDevice;
  }

  private sftpHeaderTopPadding(): number {
    if (this.isPadDevice) { return 24; }
    return this.sftpWideLayout() ? 16 : 18;
  }

  private sftpHeaderCloseTopMargin(): number {
    // The header already has a sheet-safe top inset. A small independent
    // offset keeps the close affordance below that inset instead of hugging
    // the top edge of the Pad root sheet.
    return this.isPadDevice ? 12 : 6;
  }

  private handleSftpPeerHostPickerDismiss(action: DismissSheetAction, mountToken: number): void {
    if (mountToken !== this.sftpPeerHostPickerMountToken) {
      action.dismiss();
      return;
    }
    this.sftpPeerHostPickerReopenRequested = false;
    this.sftpPeerHostPickerClosing = true;
    this.sftpPeerHostPicker = false;
    action.dismiss();
  }

  private handleSftpSheetDismiss(action: DismissSheetAction, mountToken: number): void {
    if (mountToken !== this.sftpRootSheetMountToken) {
      action.dismiss();
      return;
    }
    const elapsed: number = Date.now() - this.sftpPanelOpenedAt;
    if (elapsed < 500 || this.sftpBusy) {
      return;
    }
    if (sftpPeerPickerExitPending(this.sftpPeerHostPicker, this.sftpPeerHostPickerClosing)) {
      // Let the nested picker finish its own native dismissal first. The
      // picker onDisappear callback will then close the parent sheet.
      this.sftpCloseRootAfterPeerPicker = true;
      this.requestSftpPeerHostPickerClose();
      return;
    }
    this.dismissSftpRootSheet();
    action.dismiss();
  }

  private sftpRootSheetDismissHandler(mountToken: number): (action: DismissSheetAction) => void {
    return (action: DismissSheetAction): void => {
      this.handleSftpSheetDismiss(action, mountToken);
    };
  }

  private sftpRootSheetDisappearHandler(mountToken: number): () => void {
    return (): void => { this.handleSftpRootSheetDisappear(mountToken); };
  }

  private enterSftpEntry(entry: SftpFileEntry): void {
    this.sftpSelectedPath = entry.path;
    this.sftpSelectedName = entry.name;
    this.sftpSelectedIsDir = entry.isDirectory;
    this.sftpSelectedSize = entry.size;
    this.sftpSelectedMtime = entry.mtime;
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

  private clearSftpRefreshTimeout(): void {
    if (this.sftpRefreshTimeoutTimer !== -1) {
      clearTimeout(this.sftpRefreshTimeoutTimer);
      this.sftpRefreshTimeoutTimer = -1;
    }
  }

  private invalidateSftpRefreshRequest(): void {
    this.sftpRefreshRequestToken++;
    this.sftpRefreshOwnerToken = 0;
    this.clearSftpRefreshTimeout();
  }

  private scheduleSftpRefresh(path: string, delayMs: number): void {
    this.clearSftpRefreshTimer();
    const requestPageGeneration: number = this.pageGeneration;
    const requestSessionId: number = this.sessionId;
    const requestSessionGeneration: number = this.sshSessionGeneration;
    this.sftpRefreshTimer = setTimeout((): void => {
      this.sftpRefreshTimer = -1;
      if (!this.isSftpRequestActive(requestPageGeneration, requestSessionId, requestSessionGeneration)) { return; }
      this.refreshSftp(path);
    }, delayMs);
  }

  private nextSftpTaskId(direction: 'upload' | 'download'): string {
    this.sftpTransferTaskSequence = (this.sftpTransferTaskSequence + 1) % 1000000;
    return 'ssh-' + direction + '-' + Date.now().toString() + '-' +
      this.sftpTransferTaskSequence.toString();
  }

  private sftpTaskStageForTransfer(stage: TransferStage): SshSftpTaskStage {
    if (stage === 'completed') { return 'completed'; }
    if (stage === 'failed') { return 'failed'; }
    if (stage === 'cancelled') { return 'cancelled'; }
    if (stage === 'paused') { return 'paused'; }
    if (stage === 'waitingRemote') { return 'waitingForConnection'; }
    if (stage === 'preparing') { return 'queued'; }
    return 'transferring';
  }

  /** Persist only resumable metadata; picker URIs and credentials never leave page memory. */
  private persistSftpTaskMetadata(stageOverride: SshSftpTaskStage | null = null): void {
    const session: TransferSession | null = this.sftpTransferSession;
    const checkpoint: SshSftpCheckpoint | null = this.sftpTransferCheckpoint;
    const existingTask: SshSftpTaskRecord | null = session === null
      ? null : this.sftpTaskStore.get(session.id);
    const remotePath: string = this.sftpTransferRemotePath.trim();
    if (session === null || this.hostId.trim().length === 0 || remotePath.length === 0) { return; }
    const isUpload: boolean = session.direction === 'upload';
    const sourceSize: number = checkpoint !== null ? checkpoint.sourceSize :
      (isUpload ? this.sftpTransferSourceSize : this.sftpTransferRemoteSize);
    const sourceMtime: number = checkpoint !== null ? checkpoint.sourceMtime :
      (isUpload ? this.sftpTransferSourceMtime : this.sftpTransferRemoteMtime);
    const partialSize: number = checkpoint === null ? -1 : checkpoint.partialSize;
    const partialMtime: number = checkpoint === null ? -1 : checkpoint.partialMtime;
    const offset: number = checkpoint === null ? session.transferredBytes : checkpoint.confirmedOffset;
    // Each durable checkpoint gets a new sequence. Date.now() keeps sequence
    // ordering stable across page instances while the increment handles
    // multiple checkpoints created within one millisecond.
    this.sftpTaskSequence = Math.max(this.sftpTaskSequence + 1, Date.now());
    const record: SshSftpTaskRecord = {
      taskId: session.id,
      batchId: existingTask === null ? '' : existingTask.batchId,
      relativePath: existingTask === null ? '' : existingTask.relativePath,
      hostId: this.hostId.trim(),
      direction: session.direction,
      isDirectory: existingTask !== null && existingTask.isDirectory,
      remotePath,
      fileName: session.fileName,
      totalBytes: session.totalBytes,
      verifiedOffset: offset,
      sourceSize,
      sourceMtime,
      partialSize,
      partialMtime,
      sessionGeneration: checkpoint === null ? this.sftpTransferGeneration : checkpoint.generation,
      sequence: this.sftpTaskSequence,
      stage: stageOverride === null ? this.sftpTaskStageForTransfer(session.stage) : stageOverride,
      updatedAt: Date.now()
    };
    this.sftpTaskStore.upsert(record);
  }

  private async sftpSandboxPartialPath(taskId: string): Promise<string> {
    const transferBoxRoot: string = await this.sftpLocalProvider.transferBoxRoot();
    if (transferBoxRoot.length > 0) {
      return transferBoxRoot + '/ssh-sftp-' + taskId + '.partial';
    }
    try {
      const context: common.UIAbilityContext =
        this.getUIContext().getHostContext() as common.UIAbilityContext;
      return context.cacheDir + '/ssh-sftp-' + taskId + '.partial';
    } catch (_err) {
      return '';
    }
  }

  private async readLocalSftpIdentity(uri: string): Promise<SshSftpFileIdentity | null> {
    try {
      const info = await fileIo.stat(uri);
      const size: number = Number(info.size);
      const mtime: number = Number(info.mtime);
      return {
        size: Number.isFinite(size) && size >= 0 ? size : -1,
        mtime: Number.isFinite(mtime) && mtime >= 0 ? mtime : -1
      };
    } catch (_err) {
      return null;
    }
  }

  private async readRemoteSftpIdentity(remotePath: string,
    requestSessionId: number = this.sessionId): Promise<SshSftpFileIdentity | null> {
    if (requestSessionId <= 0 || remotePath.length === 0) { return null; }
    const parent: string = this.parentRemotePath(remotePath);
    const result = await this.loader.listRemoteDirAsync(requestSessionId, parent);
    if (result.errorCode < 0) { return null; }
    for (let index = 0; index < result.entries.length; index++) {
      const entry: SftpFileEntry = result.entries[index];
      if (!entry.isDirectory && entry.path === remotePath) {
        const size: number = Number(entry.size);
        const mtime: number = Number(entry.mtime);
        return {
          size: Number.isFinite(size) && size >= 0 ? size : -1,
          mtime: Number.isFinite(mtime) && mtime >= 0 ? mtime : -1
        };
      }
    }
    return null;
  }

  private writeSftpCheckpoint(direction: 'upload' | 'download', sourceRef: string,
    targetRef: string, sourceSize: number, sourceMtime: number,
    confirmedOffset: number, partialRef: string,
    partialIdentity: SshSftpFileIdentity | null = null): void {
    this.sftpTransferGeneration = this.sshSessionGeneration;
    this.sftpTransferPartialMtime = partialIdentity === null ? -1 : partialIdentity.mtime;
    this.sftpTransferCheckpoint = {
      direction,
      sourceRef,
      targetRef,
      sourceSize,
      sourceMtime,
      confirmedOffset,
      partialRef,
      partialSize: partialIdentity === null ? -1 : partialIdentity.size,
      partialMtime: partialIdentity === null ? -1 : partialIdentity.mtime,
      generation: this.sftpTransferGeneration
    };
    this.persistSftpTaskMetadata();
  }

  private updateSftpCheckpointOffset(offset: number,
    partialIdentity: SshSftpFileIdentity | null = null): void {
    if (this.sftpTransferCheckpoint === null) { return; }
    const checkpoint: SshSftpCheckpoint = this.sftpTransferCheckpoint;
    const nextPartialSize: number = partialIdentity === null ? checkpoint.partialSize : partialIdentity.size;
    const nextPartialMtime: number = partialIdentity === null ? checkpoint.partialMtime : partialIdentity.mtime;
    this.sftpTransferPartialMtime = nextPartialMtime;
    this.sftpTransferCheckpoint = {
      direction: checkpoint.direction,
      sourceRef: checkpoint.sourceRef,
      targetRef: checkpoint.targetRef,
      sourceSize: checkpoint.sourceSize,
      sourceMtime: checkpoint.sourceMtime,
      confirmedOffset: offset,
      partialRef: checkpoint.partialRef,
      partialSize: nextPartialSize,
      partialMtime: nextPartialMtime,
      generation: checkpoint.generation
    };
    this.persistSftpTaskMetadata();
  }

  private sftpConflictPolicyForBatch(batchId: string): SshSftpConflictPolicy {
    const id: string = batchId.trim();
    if (id.length > 0 && this.sftpBatchConflictPolicies.has(id)) {
      return this.sftpBatchConflictPolicies.get(id) as SshSftpConflictPolicy;
    }
    return 'ask';
  }

  private async askSftpConflictAction(fileName: string, sideLabel: string = '远端'):
    Promise<SftpConflictDecision> {
    const decision = await promptAction.showDialog({
      title: sideLabel + '文件已存在',
      message: '目标文件 ' + fileName + ' 已存在，请选择本项或本批次的处理方式。',
      buttons: [
        { text: '取消', color: this.pal().text2 },
        { text: '跳过本项', color: this.pal().text2 },
        { text: '跳过本批次', color: this.pal().text2 },
        { text: '保留两份本项', color: this.pal().text },
        { text: '保留两份本批次', color: this.pal().text },
        { text: '覆盖本项', color: this.pal().danger },
        { text: '覆盖本批次', color: this.pal().danger }
      ]
    });
    if (decision.index === 1 || decision.index === 2) {
      return { action: 'skip', applyToBatch: decision.index === 2 };
    }
    if (decision.index === 3 || decision.index === 4) {
      return { action: 'keepBoth', applyToBatch: decision.index === 4 };
    }
    if (decision.index === 5 || decision.index === 6) {
      return { action: 'overwrite', applyToBatch: decision.index === 6 };
    }
    return { action: 'cancel', applyToBatch: false };
  }

  private async prepareRemoteSftpConflict(remotePath: string, fileName: string,
    batchId: string, requestSessionId: number): Promise<SftpRemoteConflictPlan> {
    const parent: string = this.parentRemotePath(remotePath);
    const listed = await this.loader.listRemoteDirAsync(requestSessionId, parent);
    if (listed.errorCode < 0) {
      return { action: 'failed', policy: 'ask', targetPath: remotePath, errorCode: listed.errorCode };
    }
    let existingFinal: boolean = false;
    let existingFinalDirectory: boolean = false;
    for (let index = 0; index < listed.entries.length; index++) {
      const entry: SftpFileEntry = listed.entries[index];
      if (entry.path === remotePath) {
        existingFinal = true;
        existingFinalDirectory = entry.isDirectory;
        break;
      }
    }
    if (!existingFinal) {
      return { action: 'overwrite', policy: 'ask', targetPath: remotePath, errorCode: 0 };
    }
    if (existingFinalDirectory) {
      return { action: 'failed', policy: 'ask', targetPath: remotePath, errorCode: SFTP_CONFLICT };
    }
    const rememberedPolicy: SshSftpConflictPolicy = this.sftpConflictPolicyForBatch(batchId);
    const resolution = resolveSshSftpConflict(true, false, rememberedPolicy);
    let action: SftpConflictAction = resolution.action === 'skip' ? 'skip' :
      resolution.action === 'keepBoth' ? 'keepBoth' : 'overwrite';
    let policy: SshSftpConflictPolicy = action === 'skip' ? 'skip' :
      action === 'keepBoth' ? 'keepBoth' : 'overwrite';
    if (resolution.requiresDecision) {
      const decision: SftpConflictDecision = await this.askSftpConflictAction(fileName);
      action = decision.action;
      if (decision.applyToBatch && batchId.trim().length > 0 && action !== 'cancel') {
        this.sftpBatchConflictPolicies.set(batchId.trim(), action);
      }
      policy = action === 'skip' ? 'skip' : action === 'keepBoth' ? 'keepBoth' : 'overwrite';
    }
    if (action === 'cancel') {
      return { action: 'failed', policy: 'ask', targetPath: remotePath, errorCode: SFTP_CONFLICT };
    }
    if (action === 'keepBoth') {
      const existingNames: string[] = [];
      for (let index = 0; index < listed.entries.length; index++) {
        existingNames.push(listed.entries[index].name);
      }
      const keepBothName: string = nextSshSftpKeepBothName(fileName, existingNames);
      const keepBothPath: string = this.joinRemotePath(parent, keepBothName);
      if (keepBothName.length === 0 || keepBothPath === remotePath) {
        return { action: 'failed', policy, targetPath: remotePath, errorCode: SFTP_CONFLICT };
      }
      return { action: 'keepBoth', policy, targetPath: keepBothPath, errorCode: 0 };
    }
    return { action, policy, targetPath: remotePath, errorCode: 0 };
  }

  private async commitRemoteSftpPartial(expectedSize: number,
    session: TransferSession): Promise<SftpRemoteCommitResult> {
    this.sftpAtomicCommitErrorCode = 0;
    const commitSessionId: number = this.sftpTransferSessionId;
    const commitGeneration: number = this.sftpTransferGeneration;
    if (this.sftpTransferPartialRemotePath.length === 0 || this.sftpTransferRemotePath.length === 0 ||
      commitSessionId <= 0 || commitSessionId !== this.sessionId ||
      !sshSftpOffsetIsValid(expectedSize, expectedSize) || this.shouldStopSftpTransfer(session)) {
      return 'failed';
    }
    const partialIdentity: SshSftpFileIdentity | null =
      await this.readRemoteSftpIdentity(this.sftpTransferPartialRemotePath, commitSessionId);
    const checkpoint: SshSftpCheckpoint | null = this.sftpTransferCheckpoint;
    if (this.shouldStopSftpTransfer(session) || partialIdentity === null ||
      !sshSftpCommitSizeMatches(partialIdentity.size, expectedSize) || partialIdentity.mtime < 0 ||
      (checkpoint !== null && (checkpoint.partialSize !== expectedSize ||
        checkpoint.partialMtime < 0 || checkpoint.partialMtime !== partialIdentity.mtime))) {
      return 'failed';
    }
    this.updateSftpCheckpointOffset(expectedSize, partialIdentity);
    const parent: string = this.parentRemotePath(this.sftpTransferRemotePath);
    const listed = await this.loader.listRemoteDirAsync(commitSessionId, parent);
    if (this.shouldStopSftpTransfer(session) || listed.errorCode < 0) {
      this.sftpAtomicCommitErrorCode = listed.errorCode;
      return 'failed';
    }
    let existingFinal: boolean = false;
    let existingFinalDirectory: boolean = false;
    for (let index = 0; index < listed.entries.length; index++) {
      const entry: SftpFileEntry = listed.entries[index];
      if (entry.path === this.sftpTransferRemotePath) {
        existingFinal = true;
        existingFinalDirectory = entry.isDirectory;
        break;
      }
    }
    if (existingFinal) {
      this.sftpAtomicCommitErrorCode = SFTP_CONFLICT;
      if (existingFinalDirectory) { return 'failed'; }
      const task: SshSftpTaskRecord | null = this.sftpTaskStore.get(session.id);
      const batchId: string = task === null ? '' : task.batchId.trim();
      let rememberedPolicy: SshSftpConflictPolicy = this.sftpTransferConflictPolicy;
      if (rememberedPolicy === 'ask') {
        rememberedPolicy = this.sftpConflictPolicyForBatch(batchId);
      }
      const resolution = resolveSshSftpConflict(true, false, rememberedPolicy);
      let conflictAction: 'skip' | 'keepBoth' | 'overwrite' = 'overwrite';
      if (resolution.action === 'skip') { conflictAction = 'skip'; }
      else if (resolution.action === 'keepBoth') { conflictAction = 'keepBoth'; }
      if (resolution.requiresDecision) {
        this.persistSftpTaskMetadata('awaitingConflictDecision');
        const decision: SftpConflictDecision = await this.askSftpConflictAction(session.fileName);
        if (this.shouldStopSftpTransfer(session) || decision.action === 'cancel') { return 'failed'; }
        conflictAction = decision.action === 'skip' ? 'skip' :
          decision.action === 'keepBoth' ? 'keepBoth' : 'overwrite';
        if (decision.applyToBatch && batchId.length > 0) {
          this.sftpBatchConflictPolicies.set(batchId, conflictAction);
        }
        if (conflictAction === 'skip') {
          const removed = await this.loader.removeRemoteFileAsync(
            commitSessionId, this.sftpTransferPartialRemotePath);
          if (this.shouldStopSftpTransfer(session) || removed.errorCode < 0) {
            this.sftpAtomicCommitErrorCode = removed.errorCode;
            return 'failed';
          }
          this.sftpTransferCheckpoint = null;
          this.sftpTransferPartialRemotePath = '';
          this.sftpTransferPartialMtime = -1;
          return 'skipped';
        }
      }
      if (conflictAction === 'skip') {
        const removed = await this.loader.removeRemoteFileAsync(
          commitSessionId, this.sftpTransferPartialRemotePath);
        if (this.shouldStopSftpTransfer(session) || removed.errorCode < 0) {
          this.sftpAtomicCommitErrorCode = removed.errorCode;
          return 'failed';
        }
        this.sftpTransferCheckpoint = null;
        this.sftpTransferPartialRemotePath = '';
        this.sftpTransferPartialMtime = -1;
        return 'skipped';
      }
      if (conflictAction === 'keepBoth') {
        const existingNames: string[] = [];
        for (let index = 0; index < listed.entries.length; index++) {
          existingNames.push(listed.entries[index].name);
        }
        const keepBothName: string = nextSshSftpKeepBothName(session.fileName, existingNames);
        const keepBothPath: string = this.joinRemotePath(parent, keepBothName);
        if (keepBothName.length === 0 || keepBothPath === this.sftpTransferRemotePath) {
          return 'failed';
        }
        this.sftpTransferRemotePath = keepBothPath;
        this.updateSftpCheckpointRefs(
          checkpoint === null ? '' : checkpoint.sourceRef, keepBothPath);
      }
      if (resolution.requiresDecision) {
        this.persistSftpTaskMetadata('transferring');
      }
    }
    // A cancel request may arrive while the metadata read is in flight. Do
    // not start the remote rename after that request has been observed.
    if (this.shouldStopSftpTransfer(session)) { return 'failed'; }
    const renameResult = await this.loader.renameRemotePathAsync(
      commitSessionId, this.sftpTransferPartialRemotePath, this.sftpTransferRemotePath, true);
    if (renameResult.errorCode < 0 || renameResult.atomic !== true) {
      this.sftpAtomicCommitErrorCode = renameResult.errorCode;
      return 'failed';
    }
    // The remote rename is the commit point. A reconnect, page teardown or
    // user cancel can invalidate the caller after this await, but it cannot
    // undo an already-successful atomic rename. Report that state explicitly
    // so retry does not look for a partial that no longer exists.
    if (this.sftpTransferGeneration !== this.sshSessionGeneration ||
      commitGeneration !== this.sshSessionGeneration || this.sessionId !== commitSessionId ||
      this.sftpTransferSession === null || this.sftpTransferSession.id !== session.id ||
      this.sftpTransferSession.stage === 'cancelled' || this.sftpCancelRequested ||
      this.sftpTransferPageGeneration !== this.pageGeneration) {
      return 'committed-session-stale';
    }
    const finalIdentity: SshSftpFileIdentity | null =
      await this.readRemoteSftpIdentity(this.sftpTransferRemotePath, commitSessionId);
    return !this.shouldStopSftpTransfer(session) && finalIdentity !== null &&
      sshSftpCommitSizeMatches(finalIdentity.size, expectedSize) ? 'committed' : 'failed';
  }

  private isSftpCheckpointResumable(direction: 'upload' | 'download',
    sourceRef: string, targetRef: string, partialRef: string, offset: number): boolean {
    const checkpoint: SshSftpCheckpoint | null = this.sftpTransferCheckpoint;
    if (checkpoint === null || checkpoint.direction !== direction ||
      checkpoint.sourceRef !== sourceRef || checkpoint.targetRef !== targetRef ||
      checkpoint.partialRef !== partialRef || checkpoint.generation !== this.sshSessionGeneration ||
      !sshSftpOffsetIsValid(offset, checkpoint.sourceSize) ||
      checkpoint.confirmedOffset !== offset || checkpoint.partialSize !== offset ||
      checkpoint.partialMtime < 0) {
      return false;
    }
    return true;
  }

  /**
   * Picker URIs are provider references, not application sandbox paths. API 23
   * only guarantees URI access through open/stat, so renameSync must never be
   * used for them. The transfer first completes a sandbox partial, then makes
   * an asynchronous, size-verified export into the granted URI. A failed
   * export is never reported as completed and the sandbox partial remains for
   * a later retry.
   */
  private async exportLocalSftpPartial(partialPath: string, finalUri: string,
    expectedSize: number, session: TransferSession, requestPageGeneration: number,
    requestSessionId: number, requestSessionGeneration: number): Promise<boolean> {
    if (partialPath.length === 0 || finalUri.length === 0 || partialPath === finalUri ||
      !sshSftpOffsetIsValid(expectedSize, expectedSize) ||
      !this.isSftpRequestActive(requestPageGeneration, requestSessionId, requestSessionGeneration) ||
      this.shouldStopSftpTransfer(session)) { return false; }
    const partialIdentity: SshSftpFileIdentity | null = await this.readLocalSftpIdentity(partialPath);
    if (!this.isSftpRequestActive(requestPageGeneration, requestSessionId, requestSessionGeneration)) {
      return false;
    }
    if (partialIdentity === null || !sshSftpCommitSizeMatches(partialIdentity.size, expectedSize)) {
      return false;
    }
    if (this.shouldStopSftpTransfer(session)) { return false; }
    // A provider URI has no portable atomic rename on API 23. Refuse a
    // recognizable non-empty target before opening it, then roll back any
    // newly-created target if the verified export does not reach commit.
    const existingFinalIdentity: SshSftpFileIdentity | null = await this.readLocalSftpIdentity(finalUri);
    if (existingFinalIdentity !== null && existingFinalIdentity.size > 0) {
      if (this.isSftpRequestActive(requestPageGeneration, requestSessionId, requestSessionGeneration)) {
        this.sftpStatus = '[SFTP-DOWNLOAD] 目标文件已存在且非空，请另选保存位置';
      }
      return false;
    }
    let source: fileIo.File | null = null;
    let destination: fileIo.File | null = null;
    let destinationOpened: boolean = false;
    let destinationCommitted: boolean = false;
    try {
      source = await fileIo.open(partialPath, fileIo.OpenMode.READ_ONLY);
      if (this.shouldStopSftpTransfer(session)) { return false; }
      destination = await fileIo.open(finalUri,
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE);
      destinationOpened = true;
      if (this.shouldStopSftpTransfer(session)) { return false; }
      let copied: number = 0;
      while (copied < expectedSize) {
        if (this.shouldStopSftpTransfer(session)) { return false; }
        const chunkSize: number = Math.min(SFTP_DOWNLOAD_CHUNK_BYTES, expectedSize - copied);
        const chunk = new ArrayBuffer(chunkSize);
        const readLen: number = await fileIo.read(source.fd, chunk);
        if (readLen <= 0) { return false; }
        if (this.shouldStopSftpTransfer(session)) { return false; }
        const payload: ArrayBuffer = readLen === chunkSize ? chunk : chunk.slice(0, readLen);
        const written: number = await fileIo.write(destination.fd, payload);
        if (written !== readLen) { return false; }
        copied += readLen;
        if (this.shouldStopSftpTransfer(session)) { return false; }
        await this.yieldUi(0);
      }
      await fileIo.fsync(destination.fd);
      if (this.shouldStopSftpTransfer(session)) { return false; }
      await fileIo.close(destination);
      destination = null;
      if (this.shouldStopSftpTransfer(session)) { return false; }
      const finalIdentity: SshSftpFileIdentity | null = await this.readLocalSftpIdentity(finalUri);
      if (!this.isSftpRequestActive(requestPageGeneration, requestSessionId, requestSessionGeneration)) {
        return false;
      }
      if (finalIdentity === null || !sshSftpCommitSizeMatches(finalIdentity.size, expectedSize)) {
        return false;
      }
      // From this point the provider URI is a verified delivered file. A
      // later page/session change must not roll it back.
      destinationCommitted = true;
      try { await fileIo.close(source); } catch (_closeErr) { /* source is already verified */ }
      source = null;
      try { await fileIo.unlink(partialPath); } catch (_cleanupErr) { /* retain if cleanup is unavailable */ }
      return true;
    } catch (_err) {
      return false;
    } finally {
      if (source !== null) { try { await fileIo.close(source); } catch (_closeErr) { /* ignore */ } }
      if (destination !== null) {
        try { await fileIo.close(destination); } catch (_closeErr) { /* ignore */ }
      }
      if (destinationOpened && !destinationCommitted) {
        let rollbackVerified: boolean = false;
        try { await fileIo.unlink(finalUri); } catch (_rollbackErr) { /* provider may not support URI unlink */ }
        try {
          const probe: fileIo.File = await fileIo.open(finalUri, fileIo.OpenMode.READ_ONLY);
          await fileIo.close(probe);
        } catch (_probeErr) {
          rollbackVerified = true;
        }
        if (!rollbackVerified && this.isSftpRequestActive(requestPageGeneration,
          requestSessionId, requestSessionGeneration)) {
          this.sftpStatus = '[SFTP-DOWNLOAD] 导出失败且无法回滚目标文件，partial 已保留';
        }
      }
    }
  }

  private resetSftpTransferState(): void {
    this.sftpBusy = false;
    this.sftpProgress = -1;
    this.sftpProgressLabel = '处理中';
  }

  private beginSftpTransfer(direction: 'upload' | 'download', fileName: string, totalBytes: number,
    offset: number = 0, transferId: string = ''): TransferSession {
    const session: TransferSession = {
      id: transferId.length > 0 ? transferId : this.nextSftpTaskId(direction),
      protocol: 'ssh', direction, fileName,
      totalBytes, transferredBytes: offset, stage: 'transferring', canCancel: true, diagnosticCode: ''
    };
    this.sftpTransferSession = session;
    this.sftpTaskSequence = Math.max(this.sftpTaskSequence + 1, Date.now());
    this.sftpTransferPageGeneration = this.pageGeneration;
    this.sftpCancelRequested = false;
    this.sftpPauseRequested = false;
    this.sftpDetached = false;
    this.sftpWaitingForConnection = false;
    this.sftpAtomicCommitErrorCode = 0;
    this.sftpTransferConflictPolicy = 'ask';
    this.sftpBusy = true;
    this.sftpProgress = totalBytes > 0 ? offset / totalBytes : 0;
    return session;
  }

  private shouldStopSftpTransfer(session: TransferSession): boolean {
    return this.terminalClosing || this.sessionId <= 0 || this.sftpTransferSession === null ||
      this.sftpTransferSession.id !== session.id || this.sftpTransferSession.stage === 'cancelled' ||
      this.sftpPauseRequested || this.sftpCancelRequested ||
      this.sftpTransferSession.stage === 'paused' ||
      this.sftpTransferPageGeneration !== this.pageGeneration ||
      this.sftpTransferGeneration !== this.sshSessionGeneration;
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
    this.updateSftpCheckpointOffset(transferredBytes);
    this.sftpProgress = session.totalBytes === 0 ? 1 :
      Math.min(1, transferredBytes / session.totalBytes);
    this.persistSftpTaskMetadata();
  }

  private finishSftpTransfer(session: TransferSession, stage: TransferStage, diagnosticCode: string = ''): void {
    if (this.sftpTransferSession === null || this.sftpTransferSession.id !== session.id) { return; }
    const current: TransferSession = this.sftpTransferSession;
    this.sftpTransferSession = {
      id: current.id, protocol: current.protocol, direction: current.direction, fileName: current.fileName,
      totalBytes: current.totalBytes, transferredBytes: current.transferredBytes, stage,
      canCancel: stage === 'paused' || stage === 'waitingRemote', diagnosticCode
    };
    this.sftpCancelRequested = false;
    this.sftpPauseRequested = false;
    this.sftpWaitingForConnection = false;
    if (stage === 'paused' || stage === 'waitingRemote') {
      this.sftpBusy = false;
      this.sftpProgress = current.totalBytes > 0
        ? Math.min(1, current.transferredBytes / current.totalBytes) : 1;
      this.sftpProgressLabel = stage === 'waitingRemote' ? '等待连接' : '已暂停';
    } else {
      this.resetSftpTransferState();
    }
    this.persistSftpTaskMetadata(this.sftpTaskStageForTransfer(stage));
  }

  private stopSftpTransfer(session: TransferSession, failureCode: string): void {
    if (this.sftpDetached || this.sftpWaitingForConnection) {
      this.finishSftpTransfer(session, 'waitingRemote', 'waiting-for-connection');
      return;
    }
    if (this.sftpPauseRequested || this.sftpTransferSession !== null &&
      this.sftpTransferSession.id === session.id && this.sftpTransferSession.stage === 'paused') {
      this.finishSftpTransfer(session, 'paused', 'paused-by-user');
      if (this.isSftpRequestActive(this.sftpTransferPageGeneration, this.sessionId,
        this.sshSessionGeneration)) {
        this.sftpStatus = '已暂停 ' + session.fileName + '，可继续传输或取消';
      }
      return;
    }
    if (this.isSftpTransferCancelled(session)) {
      const diagnosticCode: string = this.sftpTransferSession === null ? 'cancelled-by-user' :
        this.sftpTransferSession.diagnosticCode;
      this.finishSftpTransfer(session, 'cancelled', diagnosticCode);
      return;
    }
    this.finishSftpTransfer(session, 'failed', failureCode);
  }

  private isSftpUserCancellationRequested(session: TransferSession): boolean {
    return this.isSftpTransferCancelled(session) && !this.sftpPauseRequested &&
      !this.sftpDetached && !this.sftpWaitingForConnection;
  }

  private pauseSftpTransfer(): void {
    if (this.sftpEngineBatchId.length > 0) {
      this.sftpTaskEngine.pauseBatch(this.sftpEngineBatchId);
      return;
    }
    const current: TransferSession | null = this.sftpTransferSession;
    if (current === null || !this.sftpBusy || current.stage !== 'transferring') { return; }
    const paused: TransferSession = pauseTransfer(current);
    if (paused.stage !== 'paused') { return; }
    this.sftpPauseRequested = true;
    this.sftpCancelRequested = true;
    this.sftpTaskStore.command(current.id, { kind: 'pause' });
    this.sftpTransferSession = paused;
    this.sftpProgressLabel = '暂停中';
    this.sftpStatus = '正在暂停 ' + current.fileName + '，等待当前 I/O 结束';
    this.persistSftpTaskMetadata('paused');
  }

  private async resumeSftpTransfer(): Promise<void> {
    if (this.sftpEngineBatchId.length > 0) {
      this.sftpBusy = true;
      this.sftpStatus = '正在继续 SFTP 批次';
      this.sftpTaskEngine.resumeBatch(this.sftpEngineBatchId);
      return;
    }
    const previous: TransferSession | null = this.sftpTransferSession;
    if (previous === null || (previous.stage !== 'paused' && previous.stage !== 'waitingRemote') || this.sftpBusy ||
      !this.isSftpRequestActive(this.pageGeneration, this.sessionId, this.sshSessionGeneration) ||
      this.sftpTransferUri.length === 0 || this.sftpTransferRemotePath.length === 0) {
      return;
    }
    const resumed: TransferSession = resumeTransfer(previous);
    if (resumed.stage !== 'transferring') { return; }
    this.sftpTaskStore.command(previous.id, { kind: 'resume' });
    this.sftpTransferSession = resumed;
    this.sftpPauseRequested = false;
    this.sftpCancelRequested = false;
    this.sftpDetached = false;
    this.sftpWaitingForConnection = false;
    this.sftpBusy = true;
    this.sftpProgress = previous.totalBytes > 0
      ? Math.min(1, previous.transferredBytes / previous.totalBytes) : 1;
    this.sftpProgressLabel = previous.direction === 'upload' ? '上传中' : '下载中';
    this.sftpStatus = '正在继续 ' + previous.fileName;
    const requestPageGeneration: number = this.pageGeneration;
    const requestSessionId: number = this.sessionId;
    const requestSessionGeneration: number = this.sshSessionGeneration;
    if (previous.direction === 'upload') {
      await this.uploadSftpToRemote(this.sftpTransferUri, previous.fileName,
        this.sftpTransferRemotePath, previous.transferredBytes, previous.id,
        requestPageGeneration, requestSessionId, requestSessionGeneration);
    } else {
      await this.downloadSftpToLocal(this.sftpTransferUri, this.sftpTransferFinalUri,
        previous.fileName, this.sftpTransferRemotePath, previous.totalBytes,
        previous.transferredBytes, previous.id, requestPageGeneration, requestSessionId,
        requestSessionGeneration);
    }
    this.continueSftpBatchAfterTask(previous.id);
  }

  private cancelSftpTransfer(): void {
    if (this.sftpEngineBatchId.length > 0) {
      this.sftpTaskEngine.cancelBatch(this.sftpEngineBatchId);
      this.sftpBusy = false;
      this.sftpProgress = -1;
      this.sftpStatus = '已取消 SFTP 批次，partial 已保留';
      return;
    }
    if (this.sftpTransferSession === null) { return; }
    this.sftpWaitingForConnection = false;
    this.sftpPauseRequested = false;
    this.sftpCancelRequested = true;
    this.sftpTaskStore.command(this.sftpTransferSession.id, { kind: 'cancel' });
    this.sftpTransferSession = cancelTransfer(this.sftpTransferSession);
    this.persistSftpTaskMetadata('cancelled');
    if (this.sftpTransferSession.stage === 'cancelled') {
      this.sftpStatus = '已取消 ' + this.sftpTransferSession.fileName +
        '，partial 已保留，可重试或清理';
    }
  }

  private async yieldUi(ms: number = 0): Promise<void> {
    await new Promise<void>((resolve: () => void): void => {
      setTimeout(resolve, ms);
    });
  }

  private async uploadSftpFile(): Promise<void> {
    if (this.sessionId <= 0 || this.sftpBusy) { return; }
    const requestPageGeneration: number = this.pageGeneration;
    const requestSessionId: number = this.sessionId;
    const requestSessionGeneration: number = this.sshSessionGeneration;
    const requestRemoteDir: string = this.sftpPath;
    try {
      let uri: string = '';
      let fileName: string = '';
      if (this.sftpLocalSelectedUri.length > 0 && !this.sftpLocalSelectedIsDir) {
        uri = this.sftpLocalSelectedUri;
        fileName = this.sftpLocalSelectedName;
      } else {
        const uris: string[] = await this.sftpLocalProvider.chooseFiles(1);
        if (!uris || uris.length === 0) { return; }
        uri = uris[0];
      }
      if (!this.isSftpRequestActive(requestPageGeneration, requestSessionId, requestSessionGeneration)) {
        return;
      }
      if (fileName.length === 0) {
        fileName = uri.substring(Math.max(uri.lastIndexOf('/'), uri.lastIndexOf('\\')) + 1);
        try { fileName = decodeURIComponent(fileName); } catch (_e) { /* ignore */ }
      }
      if (fileName.trim().length === 0) {
        this.sftpStatus = '[SFTP-UPLOAD] 无法确定本机文件名';
        return;
      }
      const remotePath: string = this.joinRemotePath(requestRemoteDir, fileName);
      this.sftpTransferCheckpoint = null;
      this.sftpTransferPartialRemotePath = '';
      this.sftpTransferPartialMtime = -1;
      this.sftpTransferSourceMtime = -1;
      this.sftpTransferSourceSize = -1;
      await this.uploadSftpToRemote(uri, fileName, remotePath, 0, '', requestPageGeneration,
        requestSessionId, requestSessionGeneration);
    } catch (_err) {
      if (this.isSftpRequestActive(requestPageGeneration, requestSessionId, requestSessionGeneration)) {
        this.sftpStatus = '[SFTP-UPLOAD] 选择文件失败';
      }
    }
  }

  private async uploadSftpToRemote(uri: string, fileName: string, remotePath: string,
    recordedOffset: number, transferId: string = '', requestPageGeneration: number = this.pageGeneration,
    requestSessionId: number = this.sessionId,
    requestSessionGeneration: number = this.sshSessionGeneration): Promise<void> {
    let file: fileIo.File | null = null;
    let session: TransferSession | null = null;
    try {
      if (!this.isSftpRequestActive(requestPageGeneration, requestSessionId, requestSessionGeneration)) {
        return;
      }
      const sourceIdentity: SshSftpFileIdentity | null = await this.readLocalSftpIdentity(uri);
      if (!this.isSftpRequestActive(requestPageGeneration, requestSessionId, requestSessionGeneration)) {
        return;
      }
      if (sourceIdentity === null || sourceIdentity.size > SFTP_MAX_TRANSFER_BYTES) {
        this.sftpStatus = '[SFTP-UPLOAD] 无法读取源文件或文件超过 512MB';
        return;
      }
      const fileSize: number = sourceIdentity.size;
      if (recordedOffset > 0 && (this.sftpTransferSourceSize < 0 ||
        !sshSftpIdentityMatches(
          { size: this.sftpTransferSourceSize, mtime: this.sftpTransferSourceMtime },
          sourceIdentity))) {
        this.sftpStatus = '[SFTP-UPLOAD] 源文件身份已变化，拒绝续传';
        return;
      }
      if (!sshSftpOffsetIsValid(recordedOffset, fileSize)) {
        this.sftpStatus = '[SFTP-UPLOAD] 已确认偏移无效，拒绝续传';
        return;
      }
      const effectiveTransferId: string = transferId.length > 0 ? transferId : this.nextSftpTaskId('upload');
      const task: SshSftpTaskRecord | null = this.sftpTaskStore.get(effectiveTransferId);
      const batchId: string = task === null ? '' : task.batchId.trim();
      let targetRemotePath: string = remotePath;
      let conflictPlan: SftpRemoteConflictPlan = {
        action: 'overwrite', policy: 'ask', targetPath: remotePath, errorCode: 0
      };
      // A resumed task already owns a partial path. Keep its target stable;
      // new uploads can decide the final target before creating any partial.
      if (recordedOffset === 0) {
        conflictPlan = await this.prepareRemoteSftpConflict(
          remotePath, fileName, batchId, requestSessionId);
        if (!this.isSftpRequestActive(requestPageGeneration, requestSessionId,
          requestSessionGeneration)) { return; }
        if (conflictPlan.action === 'failed') {
          this.sftpAtomicCommitErrorCode = conflictPlan.errorCode;
          this.sftpStatus = conflictPlan.errorCode === SFTP_CONFLICT
            ? '[SFTP-UPLOAD] 目标冲突未处理'
            : '[SFTP-UPLOAD] 无法检查远端目标';
          return;
        }
        targetRemotePath = conflictPlan.targetPath;
      }
      if (conflictPlan.action === 'skip') {
        session = this.beginSftpTransfer('upload', fileName, fileSize, recordedOffset, effectiveTransferId);
        this.sftpTransferConflictPolicy = conflictPlan.policy;
        this.sftpTransferUri = uri;
        this.sftpTransferRemotePath = targetRemotePath;
        this.sftpTransferPartialRemotePath = '';
        this.sftpTransferPartialMtime = -1;
        this.sftpTransferSourceSize = sourceIdentity.size;
        this.sftpTransferSourceMtime = sourceIdentity.mtime;
        this.sftpTransferRemoteSize = fileSize;
        this.sftpTransferRemoteMtime = -1;
        this.sftpTransferSessionId = requestSessionId;
        this.sftpTransferCheckpoint = null;
        this.finishSftpTransfer(session, 'completed', 'conflict-skipped');
        this.sftpStatus = '已跳过 ' + fileName + '（远端文件未修改）';
        return;
      }
      const partialSuffix: string = sshSftpPartialSuffix(effectiveTransferId);
      const partialRemotePath: string = this.sftpTransferPartialRemotePath.length > 0 && recordedOffset > 0 ?
        this.sftpTransferPartialRemotePath : targetRemotePath + partialSuffix;
      let partialIdentity: SshSftpFileIdentity | null = null;
      if (recordedOffset > 0) {
        partialIdentity = await this.readRemoteSftpIdentity(partialRemotePath, requestSessionId);
        if (!this.isSftpRequestActive(requestPageGeneration, requestSessionId, requestSessionGeneration)) {
          return;
        }
        const checkpoint: SshSftpCheckpoint | null = this.sftpTransferCheckpoint;
        if (partialIdentity === null || partialIdentity.size !== recordedOffset ||
          partialIdentity.mtime < 0 || (checkpoint !== null &&
            (checkpoint.partialSize !== recordedOffset || checkpoint.partialMtime !== partialIdentity.mtime))) {
          this.sftpStatus = '[SFTP-UPLOAD] 远端 partial 身份不匹配，拒绝续传';
          return;
        }
      }
      session = this.beginSftpTransfer('upload', fileName, fileSize, recordedOffset, effectiveTransferId);
      this.sftpTransferConflictPolicy = conflictPlan.policy;
      this.sftpTransferUri = uri;
      this.sftpTransferRemotePath = targetRemotePath;
      this.sftpTransferPartialRemotePath = partialRemotePath;
      this.sftpTransferPartialMtime = partialIdentity === null ? -1 : partialIdentity.mtime;
      this.sftpTransferSourceSize = sourceIdentity.size;
      this.sftpTransferSourceMtime = sourceIdentity.mtime;
      this.sftpTransferRemoteSize = fileSize;
      this.sftpTransferRemoteMtime = -1;
      this.sftpTransferSessionId = requestSessionId;
      this.writeSftpCheckpoint('upload', uri, targetRemotePath, sourceIdentity.size,
        sourceIdentity.mtime, recordedOffset, partialRemotePath, partialIdentity);
      this.sftpProgressLabel = '上传中';
      this.sftpStatus = '正在上传 ' + fileName + ' ' + Math.floor(this.sftpProgress * 100).toString() + '%';
      await this.yieldUi(16);
      if (this.shouldStopSftpTransfer(session)) {
        this.stopSftpTransfer(session, 'upload-connection-unavailable');
        return;
      }
      file = await fileIo.open(uri, fileIo.OpenMode.READ_ONLY);
      if (!this.isSftpRequestActive(requestPageGeneration, requestSessionId, requestSessionGeneration)) {
        await fileIo.close(file);
        file = null;
        if (this.shouldStopSftpTransfer(session)) {
          this.stopSftpTransfer(session, 'upload-connection-unavailable');
        }
        return;
      }
      let uploaded: number = session.transferredBytes;
      if (fileIo.lseek(file.fd, uploaded) !== uploaded) {
        await fileIo.close(file);
        file = null;
        this.stopSftpTransfer(session, 'upload-local-seek-failed');
        return;
      }
      if (fileSize === 0) {
        // Opening a zero-length remote partial is still a real SFTP mutation;
        // without this call there is nothing to atomically rename at commit.
        const emptyWrite = await this.loader.writeRemoteFileChunkAsync(
          requestSessionId, partialRemotePath, new ArrayBuffer(0), 0, true);
        if (this.shouldStopSftpTransfer(session)) {
          await fileIo.close(file); file = null;
          this.stopSftpTransfer(session, 'upload-connection-unavailable');
          return;
        }
        if (emptyWrite.errorCode < 0 || emptyWrite.bytesWritten !== 0) {
          await fileIo.close(file);
          file = null;
          this.sftpStatus = emptyWrite.errorCode === SFTP_DURABILITY_UNSUPPORTED
            ? '[SFTP-UPLOAD] 服务器不支持可靠落盘，已拒绝提交 partial'
            : '[SFTP-UPLOAD] 无法创建空文件 partial，已保留当前状态';
          this.stopSftpTransfer(session, 'upload-empty-partial-create-failed');
          return;
        }
        const emptyIdentity: SshSftpFileIdentity | null =
          await this.readRemoteSftpIdentity(partialRemotePath, requestSessionId);
        if (this.shouldStopSftpTransfer(session)) {
          await fileIo.close(file); file = null;
          this.stopSftpTransfer(session, 'upload-connection-unavailable');
          return;
        }
        if (emptyIdentity === null || emptyIdentity.size !== 0 || emptyIdentity.mtime < 0) {
          await fileIo.close(file);
          file = null;
          this.sftpStatus = '[SFTP-UPLOAD] 无法验证空文件 partial，已保留当前状态';
          this.stopSftpTransfer(session, 'upload-empty-partial-verify-failed');
          return;
        }
        this.updateSftpTransfer(session, 0);
        this.updateSftpCheckpointOffset(0, emptyIdentity);
      }
      while (uploaded < fileSize) {
        if (this.shouldStopSftpTransfer(session)) {
          await fileIo.close(file); file = null;
          this.stopSftpTransfer(session, 'upload-connection-unavailable');
          return;
        }
        const chunkSize: number = Math.min(SFTP_UPLOAD_CHUNK_BYTES, fileSize - uploaded);
        const chunk = new ArrayBuffer(chunkSize);
        const readLen: number = await fileIo.read(file.fd, chunk);
        if (this.shouldStopSftpTransfer(session)) {
          await fileIo.close(file); file = null;
          this.stopSftpTransfer(session, 'upload-connection-unavailable');
          return;
        }
        if (readLen <= 0) {
          this.sftpStatus = '[SFTP-UPLOAD] 文件读取中断';
          await fileIo.close(file);
          file = null;
          this.stopSftpTransfer(session, 'upload-local-read-failed');
          return;
        }
        const payload: ArrayBuffer = readLen === chunkSize ? chunk : chunk.slice(0, readLen);
        if (this.shouldStopSftpTransfer(session)) {
          await fileIo.close(file); file = null;
          this.stopSftpTransfer(session, 'upload-connection-unavailable');
          return;
        }
        const writeResult = await this.loader.writeRemoteFileChunkAsync(
          requestSessionId,
          partialRemotePath,
          payload,
          uploaded,
          uploaded === 0);
        if (this.shouldStopSftpTransfer(session)) {
          await fileIo.close(file); file = null;
          this.stopSftpTransfer(session, 'upload-connection-unavailable');
          return;
        }
        const ret: number = writeResult.errorCode === 0 ? writeResult.bytesWritten : writeResult.errorCode;
        const confirmedOffset: number = recordConfirmedUploadWrite(uploaded, ret, payload.byteLength);
        if (confirmedOffset !== uploaded) {
          uploaded = confirmedOffset;
          this.updateSftpTransfer(session, uploaded);
        }
        if (ret !== payload.byteLength) {
          this.sftpStatus = writeResult.durability === 'unsupported' ||
            writeResult.errorCode === SFTP_DURABILITY_UNSUPPORTED
            ? '[SFTP-UPLOAD] 服务器不支持可靠落盘，已保留 partial'
            : '[SFTP-UPLOAD] 上传中断，可从已确认进度重试';
          await fileIo.close(file);
          file = null;
          this.stopSftpTransfer(session, 'upload-remote-write-unconfirmed');
          return;
        }
        const partialIdentityAfterWrite: SshSftpFileIdentity | null =
          await this.readRemoteSftpIdentity(partialRemotePath, requestSessionId);
        if (this.shouldStopSftpTransfer(session)) {
          await fileIo.close(file); file = null;
          this.stopSftpTransfer(session, 'upload-connection-unavailable');
          return;
        }
        if (partialIdentityAfterWrite === null || partialIdentityAfterWrite.size !== uploaded ||
          partialIdentityAfterWrite.mtime < 0) {
          this.sftpStatus = '[SFTP-UPLOAD] partial 身份校验失败，已保留当前状态';
          await fileIo.close(file);
          file = null;
          this.stopSftpTransfer(session, 'upload-partial-identity-failed');
          return;
        }
        this.updateSftpCheckpointOffset(uploaded, partialIdentityAfterWrite);
        this.sftpStatus = '正在上传 ' + fileName + ' ' + Math.floor(this.sftpProgress * 100).toString() + '%';
        await this.yieldUi(16);
        if (this.shouldStopSftpTransfer(session)) {
          await fileIo.close(file);
          file = null;
          this.stopSftpTransfer(session, 'upload-connection-unavailable');
          return;
        }
      }
      await fileIo.close(file);
      file = null;
      const finalSourceIdentity: SshSftpFileIdentity | null = await this.readLocalSftpIdentity(uri);
      if (this.shouldStopSftpTransfer(session)) {
        this.stopSftpTransfer(session, 'upload-connection-unavailable');
        return;
      }
      if (finalSourceIdentity === null || !sshSftpIdentityMatches(sourceIdentity, finalSourceIdentity)) {
        this.sftpStatus = '[SFTP-UPLOAD] 源文件在传输期间发生变化，partial 已保留';
        this.stopSftpTransfer(session, 'upload-source-identity-changed');
        return;
      }
      const commitResult: SftpRemoteCommitResult = await this.commitRemoteSftpPartial(fileSize, session);
      if (commitResult === 'failed') {
        this.sftpStatus = this.sftpAtomicCommitErrorCode === SFTP_DURABILITY_UNSUPPORTED
          ? '[SFTP-UPLOAD] 服务器不支持原子可靠提交，partial 已保留'
          : '[SFTP-UPLOAD] 校验或原子提交失败，partial 已保留';
        this.stopSftpTransfer(session, 'upload-atomic-commit-failed');
        return;
      }
      if (commitResult === 'committed-session-stale') {
        this.finishSftpTransfer(session, 'completed', 'committed-session-stale');
        this.sftpStatus = '已上传 ' + fileName + '（远端已提交，会话已切换）';
        return;
      }
      if (commitResult === 'skipped') {
        this.finishSftpTransfer(session, 'completed', 'conflict-skipped');
        this.sftpStatus = '已跳过 ' + fileName + '（远端文件未修改）';
        this.scheduleSftpRefresh(this.sftpPath, 180);
        return;
      }
      if (this.isSftpUserCancellationRequested(session)) {
        this.finishSftpTransfer(session, 'cancelled', 'cancel-requested-at-commit');
        this.sftpStatus = '取消请求到达原子提交阶段，已保留完整远端文件';
        return;
      }
      this.finishSftpTransfer(session, 'completed');
      this.sftpStatus = '已上传 ' + fileName;
      promptAction.showToast({ message: 'SFTP 上传完成', duration: 1500 });
      this.scheduleSftpRefresh(this.sftpPath, 180);
    } catch (err) {
      if (file !== null) {
        try { await fileIo.close(file); } catch (_e2) { /* ignore */ }
      }
      if (session !== null) { this.stopSftpTransfer(session, 'upload-exception'); }
      if (this.isSftpRequestActive(requestPageGeneration, requestSessionId, requestSessionGeneration)) {
        this.sftpStatus = '[SFTP-UPLOAD] 上传失败，partial 已保留';
      }
    }
  }

  private async downloadSftpSelected(): Promise<void> {
    if (this.sessionId <= 0 || this.sftpBusy || this.sftpSelectedPath.length === 0) { return; }
    const requestPageGeneration: number = this.pageGeneration;
    const requestSessionId: number = this.sessionId;
    const requestSessionGeneration: number = this.sshSessionGeneration;
    const selectedRemotePath: string = this.sftpSelectedPath;
    const selectedName: string = this.sftpSelectedName;
    const selectedSize: number = this.sftpSelectedSize;
    const selectedMtime: number = this.sftpSelectedMtime;
    try {
      const totalSize: number = selectedSize;
      if (totalSize < 0 || totalSize > SFTP_MAX_TRANSFER_BYTES) {
        this.sftpStatus = '[SFTP-DOWNLOAD] 文件超过 512MB';
        return;
      }
      const transferId: string = this.nextSftpTaskId('download');
      const finalName: string = this.remoteBaseName(selectedRemotePath);
      // Picker URIs are provider references. Download into an app-sandbox
      // partial first, then export the verified bytes to this final URI.
      const uris: string[] = await this.sftpLocalProvider.chooseSave(finalName);
      if (!uris || uris.length === 0) {
        this.sftpStatus = '已取消保存';
        return;
      }
      if (!this.isSftpRequestActive(requestPageGeneration, requestSessionId, requestSessionGeneration) ||
        this.sftpSelectedPath !== selectedRemotePath) {
        return;
      }
      const finalUri: string = uris[0];
      const partialPath: string = await this.sftpSandboxPartialPath(transferId);
      if (finalUri.length === 0 || partialPath.length === 0) {
        this.sftpStatus = '[SFTP-DOWNLOAD] 无法建立本地临时文件，已取消';
        return;
      }
      this.sftpTransferCheckpoint = null;
      this.sftpTransferFinalUri = finalUri;
      this.sftpTransferPartialRemotePath = '';
      this.sftpTransferPartialMtime = -1;
      this.sftpTransferRemoteSize = totalSize;
      this.sftpTransferRemoteMtime = selectedMtime;
      await this.downloadSftpToLocal(
        partialPath, finalUri, selectedName, selectedRemotePath, totalSize, 0, transferId,
        requestPageGeneration, requestSessionId, requestSessionGeneration);
    } catch (_err) {
      if (this.isSftpRequestActive(requestPageGeneration, requestSessionId, requestSessionGeneration)) {
        this.sftpStatus = '[SFTP-DOWNLOAD] 选择保存位置失败';
      }
    }
  }

  private async downloadSftpToLocal(uri: string, finalUri: string, fileName: string, remotePath: string,
    totalSize: number, recordedOffset: number, transferId: string = '',
    requestPageGeneration: number = this.pageGeneration,
    requestSessionId: number = this.sessionId,
    requestSessionGeneration: number = this.sshSessionGeneration): Promise<void> {
    let outFile: fileIo.File | null = null;
    let session: TransferSession | null = null;
    try {
      if (!this.isSftpRequestActive(requestPageGeneration, requestSessionId, requestSessionGeneration) ||
        uri.length === 0 || finalUri.length === 0 || uri === finalUri) {
        this.sftpStatus = '[SFTP-DOWNLOAD] 本地 partial/final URI 无效，拒绝传输';
        return;
      }
      const remoteIdentity: SshSftpFileIdentity | null =
        await this.readRemoteSftpIdentity(remotePath, requestSessionId);
      if (!this.isSftpRequestActive(requestPageGeneration, requestSessionId, requestSessionGeneration)) {
        return;
      }
      if (remoteIdentity === null || remoteIdentity.size !== totalSize || remoteIdentity.mtime < 0 ||
        this.sftpTransferRemoteMtime < 0 ||
        !sshSftpIdentityMatches(
          { size: this.sftpTransferRemoteSize, mtime: this.sftpTransferRemoteMtime },
          remoteIdentity)) {
        this.sftpStatus = '[SFTP-DOWNLOAD] 远端文件身份已变化，拒绝续传';
        return;
      }
      if (!this.isSftpRequestActive(requestPageGeneration, requestSessionId, requestSessionGeneration)) {
        return;
      }
      const openMode: number = fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE |
        (recordedOffset === 0 ? fileIo.OpenMode.TRUNC : 0);
      outFile = await fileIo.open(uri, openMode);
      const existingLocalIdentity: SshSftpFileIdentity | null = await this.readLocalSftpIdentity(uri);
      if (!this.isSftpRequestActive(requestPageGeneration, requestSessionId, requestSessionGeneration)) {
        await fileIo.close(outFile);
        outFile = null;
        return;
      }
      const localBytes: number = existingLocalIdentity === null ? -1 : existingLocalIdentity.size;
      const checkpoint: SshSftpCheckpoint | null = this.sftpTransferCheckpoint;
      if (recordedOffset > 0 && (localBytes !== recordedOffset || existingLocalIdentity === null ||
        existingLocalIdentity.mtime < 0 || (checkpoint !== null &&
          (checkpoint.partialSize !== recordedOffset || checkpoint.partialMtime !== existingLocalIdentity.mtime)))) {
        await fileIo.close(outFile);
        outFile = null;
        this.sftpStatus = '[SFTP-DOWNLOAD] 本地 partial 身份不匹配，拒绝续传';
        return;
      }
      const resumeOffset: number = recordedOffset > 0 ? localBytes : 0;
      if (!sshSftpOffsetIsValid(resumeOffset, totalSize)) {
        await fileIo.close(outFile);
        outFile = null;
        this.sftpStatus = '[SFTP-DOWNLOAD] 已确认偏移无效，拒绝续传';
        return;
      }
      const effectiveTransferId: string = transferId.length > 0 ? transferId : this.nextSftpTaskId('download');
      session = this.beginSftpTransfer('download', fileName, totalSize, resumeOffset, effectiveTransferId);
      this.sftpTransferUri = uri;
      this.sftpTransferFinalUri = finalUri;
      this.sftpTransferRemotePath = remotePath;
      this.sftpTransferRemoteSize = remoteIdentity.size;
      this.sftpTransferRemoteMtime = remoteIdentity.mtime;
      this.sftpTransferSessionId = requestSessionId;
      this.writeSftpCheckpoint('download', remotePath, finalUri, remoteIdentity.size,
        remoteIdentity.mtime, resumeOffset, uri, existingLocalIdentity);
      this.sftpProgressLabel = '下载中';
      this.sftpStatus = '正在下载 ' + fileName + ' ' + Math.floor(this.sftpProgress * 100).toString() + '%';
      await this.yieldUi(16);
      if (this.shouldStopSftpTransfer(session)) {
        await fileIo.close(outFile);
        outFile = null;
        this.stopSftpTransfer(session, 'download-connection-unavailable');
        return;
      }
      const targetFile: fileIo.File = outFile;
      let downloaded: number = session.transferredBytes;
      if (fileIo.lseek(targetFile.fd, downloaded) !== downloaded) {
        await fileIo.close(targetFile);
        outFile = null;
        this.stopSftpTransfer(session, 'download-local-seek-failed');
        return;
      }
      while (downloaded < totalSize) {
        if (this.shouldStopSftpTransfer(session)) {
          await fileIo.close(targetFile); outFile = null;
          this.stopSftpTransfer(session, 'download-connection-unavailable');
          return;
        }
        const chunkSize: number = Math.min(SFTP_DOWNLOAD_CHUNK_BYTES, totalSize - downloaded);
        const dataResult = await this.loader.readRemoteFileChunkAsync(
          requestSessionId,
          remotePath,
          downloaded,
          chunkSize);
        if (this.shouldStopSftpTransfer(session)) {
          await fileIo.close(targetFile); outFile = null;
          this.stopSftpTransfer(session, 'download-connection-unavailable');
          return;
        }
        if (dataResult.errorCode < 0) {
          await fileIo.close(targetFile);
          outFile = null;
          this.sftpStatus = '[SFTP-DOWNLOAD] 远端读取失败 ret=' + dataResult.errorCode.toString();
          this.stopSftpTransfer(session, 'download-remote-read-failed');
          return;
        }
        const data: ArrayBuffer = dataResult.data;
        if (data.byteLength <= 0) {
          await fileIo.close(targetFile);
          outFile = null;
          this.sftpStatus = '[SFTP-DOWNLOAD] 远端读取中断';
          this.stopSftpTransfer(session, 'download-remote-read-failed');
          return;
        }
        if (data.byteLength > totalSize - downloaded) {
          await fileIo.close(targetFile);
          outFile = null;
          this.sftpStatus = '[SFTP-DOWNLOAD] 远端返回超出预期，partial 已保留';
          this.stopSftpTransfer(session, 'download-size-overrun');
          return;
        }
        if (this.shouldStopSftpTransfer(session)) {
          await fileIo.close(targetFile); outFile = null;
          this.stopSftpTransfer(session, 'download-connection-unavailable');
          return;
        }
        const written: number = await fileIo.write(targetFile.fd, data);
        if (this.shouldStopSftpTransfer(session)) {
          await fileIo.close(targetFile); outFile = null;
          this.stopSftpTransfer(session, 'download-connection-unavailable');
          return;
        }
        if (written !== data.byteLength) {
          await fileIo.close(targetFile);
          outFile = null;
          this.sftpStatus = '[SFTP-DOWNLOAD] 本地写入不完整';
          this.stopSftpTransfer(session, 'download-local-write-failed');
          return;
        }
        downloaded += data.byteLength;
        this.updateSftpTransfer(session, downloaded);
        const partialIdentityAfterWrite: SshSftpFileIdentity | null =
          await this.readLocalSftpIdentity(uri);
        if (this.shouldStopSftpTransfer(session)) {
          await fileIo.close(targetFile); outFile = null;
          this.stopSftpTransfer(session, 'download-connection-unavailable');
          return;
        }
        if (partialIdentityAfterWrite === null || partialIdentityAfterWrite.size !== downloaded ||
          partialIdentityAfterWrite.mtime < 0) {
          await fileIo.close(targetFile);
          outFile = null;
          this.sftpStatus = '[SFTP-DOWNLOAD] partial 身份校验失败，已保留当前状态';
          this.stopSftpTransfer(session, 'download-partial-identity-failed');
          return;
        }
        this.updateSftpCheckpointOffset(downloaded, partialIdentityAfterWrite);
        this.sftpStatus = '正在下载 ' + fileName + ' ' +
          Math.floor(this.sftpProgress * 100).toString() + '%';
        await this.yieldUi(16);
        if (this.shouldStopSftpTransfer(session)) {
          await fileIo.close(targetFile);
          outFile = null;
          this.stopSftpTransfer(session, 'download-connection-unavailable');
          return;
        }
      }
      await fileIo.fsync(targetFile.fd);
      await fileIo.close(targetFile);
      outFile = null;
      if (this.shouldStopSftpTransfer(session)) {
        this.stopSftpTransfer(session, 'download-connection-unavailable');
        return;
      }
      const completedRemoteIdentity: SshSftpFileIdentity | null =
        await this.readRemoteSftpIdentity(remotePath, requestSessionId);
      if (this.shouldStopSftpTransfer(session) || completedRemoteIdentity === null ||
        !sshSftpIdentityMatches(remoteIdentity, completedRemoteIdentity)) {
        this.sftpStatus = '[SFTP-DOWNLOAD] 远端文件在传输期间发生变化，partial 已保留';
        this.stopSftpTransfer(session, 'download-remote-identity-changed');
        return;
      }
      const completedLocalIdentity: SshSftpFileIdentity | null = await this.readLocalSftpIdentity(uri);
      if (this.shouldStopSftpTransfer(session)) {
        this.stopSftpTransfer(session, 'download-connection-unavailable');
        return;
      }
      if (completedLocalIdentity === null || !sshSftpCommitSizeMatches(completedLocalIdentity.size, totalSize) ||
        !await this.exportLocalSftpPartial(uri, finalUri, totalSize, session,
          requestPageGeneration, requestSessionId, requestSessionGeneration)) {
        this.sftpStatus = '[SFTP-DOWNLOAD] 校验或 Picker 导出失败，partial 已保留';
        this.stopSftpTransfer(session, 'download-atomic-commit-failed');
        return;
      }
      if (this.isSftpUserCancellationRequested(session)) {
        this.finishSftpTransfer(session, 'cancelled', 'cancel-requested-at-export');
        this.sftpStatus = '取消请求到达导出阶段，已保留已验证文件';
        return;
      }
      this.finishSftpTransfer(session, 'completed');
      this.sftpStatus = '已保存 ' + downloaded.toString() + ' 字节';
      promptAction.showToast({ message: 'SFTP 下载完成', duration: 1500 });
    } catch (err) {
      if (outFile !== null) {
        try { await fileIo.close(outFile); } catch (_e2) { /* ignore */ }
      }
      if (session !== null) { this.stopSftpTransfer(session, 'download-exception'); }
      if (this.isSftpRequestActive(requestPageGeneration, requestSessionId, requestSessionGeneration)) {
        this.sftpStatus = '[SFTP-DOWNLOAD] 下载失败，partial 已保留';
      }
    }
  }

  private updateSftpCheckpointRefs(sourceRef: string, targetRef: string): void {
    if (this.sftpTransferCheckpoint === null) { return; }
    const checkpoint: SshSftpCheckpoint = this.sftpTransferCheckpoint;
    this.sftpTransferCheckpoint = {
      direction: checkpoint.direction,
      sourceRef,
      targetRef,
      sourceSize: checkpoint.sourceSize,
      sourceMtime: checkpoint.sourceMtime,
      confirmedOffset: checkpoint.confirmedOffset,
      partialRef: checkpoint.partialRef,
      partialSize: checkpoint.partialSize,
      partialMtime: checkpoint.partialMtime,
      generation: checkpoint.generation
    };
  }

  private async retrySftpTransfer(): Promise<void> {
    if (this.sftpEngineBatchId.length > 0) {
      this.sftpBusy = true;
      this.sftpStatus = '正在重试 SFTP 批次';
      this.sftpTaskEngine.retryBatch(this.sftpEngineBatchId);
      return;
    }
    const previous: TransferSession | null = this.sftpTransferSession;
    if (previous !== null && (previous.stage === 'paused' || previous.stage === 'waitingRemote')) {
      await this.resumeSftpTransfer();
      return;
    }
    const requestPageGeneration: number = this.pageGeneration;
    const requestSessionId: number = this.sessionId;
    const requestSessionGeneration: number = this.sshSessionGeneration;
    if (!this.isSftpRequestActive(requestPageGeneration, requestSessionId, requestSessionGeneration) ||
      this.sftpBusy || previous === null ||
      (previous.stage !== 'failed' && previous.stage !== 'cancelled') ||
      this.sftpTransferUri.length === 0 || this.sftpTransferRemotePath.length === 0) { return; }
    try {
      if (previous.direction === 'upload') {
        const remotePartialIdentity: SshSftpFileIdentity | null =
          await this.readRemoteSftpIdentity(this.sftpTransferPartialRemotePath, requestSessionId);
        if (!this.isSftpRequestActive(requestPageGeneration, requestSessionId, requestSessionGeneration) ||
          this.sftpTransferSession === null || this.sftpTransferSession.id !== previous.id) { return; }
        const checkpoint: SshSftpCheckpoint | null = this.sftpTransferCheckpoint;
        const oldSourceUri: string = this.sftpTransferUri;
        if (!this.isSftpCheckpointResumable('upload', oldSourceUri,
          this.sftpTransferRemotePath, this.sftpTransferPartialRemotePath,
          previous.transferredBytes) || checkpoint === null || remotePartialIdentity === null ||
          remotePartialIdentity.size !== checkpoint.partialSize ||
          remotePartialIdentity.mtime !== checkpoint.partialMtime) {
          this.sftpStatus = '[SFTP-UPLOAD] checkpoint 已失效，拒绝续传';
          return;
        }
        const uris: string[] = await this.sftpLocalProvider.chooseFiles(1);
        if (!uris || uris.length === 0 ||
          !this.isSftpRequestActive(requestPageGeneration, requestSessionId, requestSessionGeneration)) {
          return;
        }
        const sourceUri: string = uris[0];
        const sourceIdentity: SshSftpFileIdentity | null = await this.readLocalSftpIdentity(sourceUri);
        if (!this.isSftpRequestActive(requestPageGeneration, requestSessionId, requestSessionGeneration) ||
          this.sftpTransferSession === null || this.sftpTransferSession.id !== previous.id ||
          sourceIdentity === null || !sshSftpIdentityMatches(
            { size: checkpoint.sourceSize, mtime: checkpoint.sourceMtime }, sourceIdentity)) {
          if (this.isSftpRequestActive(requestPageGeneration, requestSessionId, requestSessionGeneration)) {
            this.sftpStatus = '[SFTP-UPLOAD] 新授权文件身份不匹配，拒绝续传';
          }
          return;
        }
        this.sftpTransferUri = sourceUri;
        this.updateSftpCheckpointRefs(sourceUri, this.sftpTransferRemotePath);
        await this.uploadSftpToRemote(sourceUri, previous.fileName, this.sftpTransferRemotePath,
          previous.transferredBytes, previous.id, requestPageGeneration, requestSessionId,
          requestSessionGeneration);
      } else {
        const localPartialIdentity: SshSftpFileIdentity | null =
          await this.readLocalSftpIdentity(this.sftpTransferUri);
        if (!this.isSftpRequestActive(requestPageGeneration, requestSessionId, requestSessionGeneration) ||
          this.sftpTransferSession === null || this.sftpTransferSession.id !== previous.id) { return; }
        const checkpoint: SshSftpCheckpoint | null = this.sftpTransferCheckpoint;
        if (this.sftpTransferFinalUri.length === 0 ||
          !this.isSftpCheckpointResumable('download', this.sftpTransferRemotePath,
            this.sftpTransferFinalUri, this.sftpTransferUri, previous.transferredBytes)) {
          this.sftpStatus = '[SFTP-DOWNLOAD] checkpoint 或最终 URI 已失效，拒绝续传';
          return;
        }
        if (checkpoint === null || localPartialIdentity === null ||
          localPartialIdentity.size !== checkpoint.partialSize ||
          localPartialIdentity.mtime !== checkpoint.partialMtime) {
          this.sftpStatus = '[SFTP-DOWNLOAD] partial 身份已变化，拒绝续传';
          return;
        }
        const uris: string[] = await this.sftpLocalProvider.chooseSave(previous.fileName);
        if (!uris || uris.length === 0 ||
          !this.isSftpRequestActive(requestPageGeneration, requestSessionId, requestSessionGeneration)) {
          return;
        }
        const finalUri: string = uris[0];
        if (finalUri.length === 0 || finalUri === this.sftpTransferUri) {
          this.sftpStatus = '[SFTP-DOWNLOAD] 新授权目标无效，拒绝续传';
          return;
        }
        this.sftpTransferFinalUri = finalUri;
        this.updateSftpCheckpointRefs(this.sftpTransferRemotePath, finalUri);
        await this.downloadSftpToLocal(this.sftpTransferUri, finalUri,
          previous.fileName, this.sftpTransferRemotePath, previous.totalBytes,
          previous.transferredBytes, previous.id, requestPageGeneration, requestSessionId,
          requestSessionGeneration);
      }
      this.continueSftpBatchAfterTask(previous.id);
    } catch (_err) {
      if (this.isSftpRequestActive(requestPageGeneration, requestSessionId, requestSessionGeneration)) {
        this.sftpStatus = previous.direction === 'upload'
          ? '[SFTP-UPLOAD] 重新授权失败，partial 已保留'
          : '[SFTP-DOWNLOAD] 重新授权失败，partial 已保留';
      }
    }
  }

  private cancelRecoveredSftpTask(task: SshSftpTaskRecord): void {
    if (this.sftpBusy) { return; }
    const result = this.sftpTaskStore.command(task.taskId, { kind: 'cancel' });
    if (result.accepted) {
      this.sftpStatus = '已取消待恢复任务 ' + task.fileName;
      this.refreshRecoveredSftpTasks();
    }
  }

  /** Rebind a persisted metadata record to fresh, user-authorized provider references. */
  private async recoverSftpTask(task: SshSftpTaskRecord): Promise<void> {
    if (this.sftpBusy || this.sessionId <= 0 || task.hostId !== this.hostId ||
      task.stage === 'completed' || task.stage === 'cancelled') { return; }
    if (task.batchId.trim().length > 0) {
      void this.recoverSftpBatch(task.batchId);
      return;
    }
    const requestPageGeneration: number = this.pageGeneration;
    const requestSessionId: number = this.sessionId;
    const requestSessionGeneration: number = this.sshSessionGeneration;
    const offset: number = task.verifiedOffset >= 0 ? task.verifiedOffset : 0;
    try {
      if (task.direction === 'upload') {
        const uris: string[] = await this.sftpLocalProvider.chooseFiles(1);
        if (!uris || uris.length === 0 || !this.isSftpRequestActive(
          requestPageGeneration, requestSessionId, requestSessionGeneration)) { return; }
        const sourceUri: string = uris[0];
        const sourceIdentity: SshSftpFileIdentity | null = await this.readLocalSftpIdentity(sourceUri);
        if (sourceIdentity === null || sourceIdentity.size > SFTP_MAX_TRANSFER_BYTES ||
          (offset > 0 && (task.sourceSize < 0 || task.sourceMtime < 0 ||
            !sshSftpIdentityMatches({ size: task.sourceSize, mtime: task.sourceMtime }, sourceIdentity)))) {
          this.sftpStatus = '[SFTP-UPLOAD] 恢复文件身份不匹配，拒绝续传';
          return;
        }
        if (!sshSftpOffsetIsValid(offset, sourceIdentity.size)) {
          this.sftpStatus = '[SFTP-UPLOAD] 持久偏移无效，拒绝续传';
          return;
        }
        const partialRemotePath: string = task.remotePath + sshSftpPartialSuffix(task.taskId);
        if (offset > 0) {
          const partialIdentity: SshSftpFileIdentity | null =
            await this.readRemoteSftpIdentity(partialRemotePath, requestSessionId);
          if (partialIdentity === null || partialIdentity.size !== offset || partialIdentity.mtime < 0 ||
            task.partialSize !== offset || (task.partialMtime >= 0 && task.partialMtime !== partialIdentity.mtime)) {
            this.sftpStatus = '[SFTP-UPLOAD] 远端 partial 身份不匹配，拒绝续传';
            return;
          }
        }
        if (task.stage !== 'queued') {
          const command = this.sftpTaskStore.command(task.taskId, { kind: 'retry' });
          if (!command.accepted) {
            this.sftpStatus = '[SFTP-UPLOAD] 持久任务状态不可恢复';
            return;
          }
        }
        this.sftpTransferCheckpoint = null;
        this.sftpTransferUri = sourceUri;
        this.sftpTransferRemotePath = task.remotePath;
        this.sftpTransferPartialRemotePath = partialRemotePath;
        this.sftpTransferSourceSize = sourceIdentity.size;
        this.sftpTransferSourceMtime = sourceIdentity.mtime;
        this.sftpTransferRemoteSize = sourceIdentity.size;
        this.sftpTransferRemoteMtime = -1;
        await this.uploadSftpToRemote(sourceUri, task.fileName, task.remotePath, offset, task.taskId,
          requestPageGeneration, requestSessionId, requestSessionGeneration);
      } else {
        const remoteIdentity: SshSftpFileIdentity | null =
          await this.readRemoteSftpIdentity(task.remotePath, requestSessionId);
        if (remoteIdentity === null || remoteIdentity.size > SFTP_MAX_TRANSFER_BYTES ||
          (task.sourceSize >= 0 && !sshSftpIdentityMatches(
            { size: task.sourceSize, mtime: task.sourceMtime }, remoteIdentity))) {
          this.sftpStatus = '[SFTP-DOWNLOAD] 远端文件身份已变化，拒绝续传';
          return;
        }
        if (!sshSftpOffsetIsValid(offset, remoteIdentity.size)) {
          this.sftpStatus = '[SFTP-DOWNLOAD] 持久偏移无效，拒绝续传';
          return;
        }
        const partialPath: string = await this.sftpSandboxPartialPath(task.taskId);
        const partialIdentity: SshSftpFileIdentity | null =
          await this.readLocalSftpIdentity(partialPath);
        if (offset > 0 && (partialIdentity === null || partialIdentity.size !== offset ||
          partialIdentity.mtime < 0 || task.partialSize !== offset ||
          (task.partialMtime >= 0 && task.partialMtime !== partialIdentity.mtime))) {
          this.sftpStatus = '[SFTP-DOWNLOAD] 本机 partial 身份不匹配，拒绝续传';
          return;
        }
        const uris: string[] = await this.sftpLocalProvider.chooseSave(task.fileName);
        if (!uris || uris.length === 0 || !this.isSftpRequestActive(
          requestPageGeneration, requestSessionId, requestSessionGeneration)) { return; }
        const finalUri: string = uris[0];
        if (finalUri.length === 0 || finalUri === partialPath) {
          this.sftpStatus = '[SFTP-DOWNLOAD] 新授权目标无效，拒绝续传';
          return;
        }
        if (task.stage !== 'queued') {
          const command = this.sftpTaskStore.command(task.taskId, { kind: 'retry' });
          if (!command.accepted) {
            this.sftpStatus = '[SFTP-DOWNLOAD] 持久任务状态不可恢复';
            return;
          }
        }
        this.sftpTransferCheckpoint = null;
        this.sftpTransferUri = partialPath;
        this.sftpTransferFinalUri = finalUri;
        this.sftpTransferRemotePath = task.remotePath;
        this.sftpTransferRemoteSize = remoteIdentity.size;
        this.sftpTransferRemoteMtime = remoteIdentity.mtime;
        await this.downloadSftpToLocal(partialPath, finalUri, task.fileName, task.remotePath,
          remoteIdentity.size, offset, task.taskId, requestPageGeneration, requestSessionId,
          requestSessionGeneration);
      }
      this.refreshRecoveredSftpTasks();
    } catch (_err) {
      if (this.isSftpRequestActive(requestPageGeneration, requestSessionId, requestSessionGeneration)) {
        this.sftpStatus = task.direction === 'upload'
          ? '[SFTP-UPLOAD] 恢复失败，partial 已保留'
          : '[SFTP-DOWNLOAD] 恢复失败，partial 已保留';
      }
    }
  }

  private deleteSftpSelected(): void {
    if (this.sessionId <= 0 || this.sftpBusy || this.sftpSelectedPath.length === 0) { return; }
    const targetIsDir: boolean = this.sftpSelectedIsDir;
    const requestSessionId: number = this.sessionId;
    const requestSessionGeneration: number = this.sshSessionGeneration;
    const requestPageGeneration: number = this.pageGeneration;
    const targetPath: string = this.sftpSelectedPath;
    const targetName: string = this.sftpSelectedName;
    promptAction.showDialog({
      title: targetIsDir ? '删除远端目录' : '删除远端文件',
      message: '确定删除 ' + targetName + ' 吗？' + (targetIsDir ? ' 目录必须为空。' : ''),
      buttons: [
        { text: '取消', color: this.pal().text2 },
        { text: '删除', color: this.pal().danger }
      ]
    }).then((res): void => {
      if (res.index !== 1 || !this.isSftpRequestActive(requestPageGeneration, requestSessionId,
        requestSessionGeneration)) { return; }
      this.deleteSftpPath(requestSessionId, targetPath, targetName, targetIsDir, requestPageGeneration,
        requestSessionGeneration);
    }).catch((err: BusinessError): void => {
      if (this.isSftpRequestActive(requestPageGeneration, requestSessionId, requestSessionGeneration)) {
        this.sftpStatus = '[SFTP-DELETE] 对话框失败: ' + err.message;
      }
    });
  }

  private async deleteSftpPath(sessionId: number, remotePath: string,
    name: string, targetIsDir: boolean, requestPageGeneration: number,
    requestSessionGeneration: number): Promise<void> {
    if (!this.isSftpRequestActive(requestPageGeneration, sessionId, requestSessionGeneration)) { return; }
    this.sftpBusy = true;
    let errorCode: number = -1;
    try {
      const result = targetIsDir ?
        await this.loader.removeRemoteDirAsync(sessionId, remotePath) :
        await this.loader.removeRemoteFileAsync(sessionId, remotePath);
      if (!this.isSftpRequestActive(requestPageGeneration, sessionId, requestSessionGeneration)) { return; }
      errorCode = result.errorCode;
    } catch (_err) {
      errorCode = -1;
    } finally {
      if (this.isSftpRequestActive(requestPageGeneration, sessionId, requestSessionGeneration)) {
        this.sftpBusy = false;
      }
    }
    if (!this.isSftpRequestActive(requestPageGeneration, sessionId, requestSessionGeneration)) { return; }
    if (errorCode === 0) {
      this.sftpStatus = '已删除 ' + name;
      this.refreshSftp(this.sftpPath);
    } else {
      this.sftpStatus = '[SFTP-DELETE] 删除失败 ret=' + errorCode.toString();
    }
  }

  private async makeSftpDir(): Promise<void> {
    if (this.sessionId <= 0 || this.sftpBusy) { return; }
    const candidate: string = this.sftpNameInput.trim();
    if (candidate.length > 0 && !this.isValidRemoteName(candidate)) {
      this.sftpStatus = '[SFTP-MKDIR] 目录名无效';
      return;
    }
    const dirName: string = candidate.length > 0 ? candidate : 'NewFolder-' + Date.now().toString();
    const remotePath: string = this.joinRemotePath(this.sftpPath, dirName);
    const requestSessionId: number = this.sessionId;
    const requestSessionGeneration: number = this.sshSessionGeneration;
    const requestPageGeneration: number = this.pageGeneration;
    this.sftpBusy = true;
    let errorCode: number = -1;
    try {
      const result = await this.loader.makeRemoteDirAsync(requestSessionId, remotePath);
      if (!this.isSftpRequestActive(requestPageGeneration, requestSessionId, requestSessionGeneration)) { return; }
      errorCode = result.errorCode;
    } catch (_err) {
      errorCode = -1;
    } finally {
      if (this.isSftpRequestActive(requestPageGeneration, requestSessionId, requestSessionGeneration)) {
        this.sftpBusy = false;
      }
    }
    if (!this.isSftpRequestActive(requestPageGeneration, requestSessionId, requestSessionGeneration)) { return; }
    if (errorCode === 0) {
      this.sftpStatus = '已创建目录 ' + dirName;
      this.refreshSftp(this.sftpPath);
    } else {
      this.sftpStatus = '[SFTP-MKDIR] 创建失败 ret=' + errorCode.toString();
    }
  }

  private async renameSftpSelected(): Promise<void> {
    if (this.sessionId <= 0 || this.sftpBusy || this.sftpSelectedPath.length === 0) { return; }
    const trimmed: string = this.sftpNameInput.trim();
    if (!this.isValidRemoteName(trimmed)) {
      this.sftpStatus = '[SFTP-RENAME] 新名称无效';
      return;
    }
    const newPath: string = this.joinRemotePath(this.parentRemotePath(this.sftpSelectedPath), trimmed);
    const requestSessionId: number = this.sessionId;
    const requestSessionGeneration: number = this.sshSessionGeneration;
    const requestPageGeneration: number = this.pageGeneration;
    const oldPath: string = this.sftpSelectedPath;
    this.sftpBusy = true;
    let errorCode: number = -1;
    try {
      const result = await this.loader.renameRemotePathAsync(requestSessionId, oldPath, newPath);
      if (!this.isSftpRequestActive(requestPageGeneration, requestSessionId, requestSessionGeneration)) { return; }
      errorCode = result.errorCode;
    } catch (_err) {
      errorCode = -1;
    } finally {
      if (this.isSftpRequestActive(requestPageGeneration, requestSessionId, requestSessionGeneration)) {
        this.sftpBusy = false;
      }
    }
    if (!this.isSftpRequestActive(requestPageGeneration, requestSessionId, requestSessionGeneration)) { return; }
    if (errorCode === 0) {
      this.sftpStatus = '已重命名为 ' + trimmed;
      this.refreshSftp(this.sftpPath);
    } else {
      this.sftpStatus = '[SFTP-RENAME] 重命名失败 ret=' + errorCode.toString();
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
    if (content.length === 0) { this.resetKeyboardBuffer(); return; }
    const maxPasteLength: number = 256 * 1024;
    if (content.length > maxPasteLength) {
      promptAction.showToast({ message: '粘贴内容过大，已拒绝（上限 256 KB）', duration: 1800 });
      this.resetKeyboardBuffer();
      return;
    }

    const hasNewline: boolean = content.indexOf('\n') >= 0 || content.indexOf('\r') >= 0;
    if (hasNewline) {
      const pageGeneration: number = this.pageGeneration;
      const requestSessionId: number = this.sessionId;
      const requestSessionGeneration: number = this.sshSessionGeneration;
      const lineCount: number = content.split(/\r\n|\r|\n/).length;
      const preview: string = content.replace(/[\r\n]+/g, ' ').substring(0, 96);
      promptAction.showDialog({
        title: '确认多行粘贴',
        message: '将发送 ' + lineCount.toString() + ' 行到远端终端。\n预览：' + preview,
        buttons: [
          { text: '取消', color: this.pal().text2 },
          { text: '发送', color: this.accentColor }
        ]
      }).then((result): void => {
        if (result.index !== 1 || !this.isPageGenerationActive(pageGeneration) ||
          this.sessionId !== requestSessionId || this.sshSessionGeneration !== requestSessionGeneration) { return; }
        this.sendPastedText(content);
      }).catch((_err: BusinessError): void => {
        // 用户关闭系统对话框等同于取消，不发送剪贴板内容。
      });
    } else {
      this.sendPastedText(content);
    }
    this.resetKeyboardBuffer();
  }

  private sendPastedText(content: string): void {
    if (this.bracketedPasteEnabled) {
      // Mark every part of the bracketed paste as one ordered transaction.
      // The native reactor will not let a later control byte split it.
      this.queueTerminalInput('\u001b[200~', false, true, false);
      for (let offset: number = 0; offset < content.length; offset += SSH_INPUT_PASTE_CHUNK_CHARS) {
        this.queueTerminalInput(
          content.substring(offset, offset + SSH_INPUT_PASTE_CHUNK_CHARS), false, true, false);
      }
      this.queueTerminalInput('\u001b[201~', false, true, true);
    } else {
      for (let offset: number = 0; offset < content.length; offset += SSH_INPUT_PASTE_CHUNK_CHARS) {
        this.sendTerminalBytes(content.substring(offset, offset + SSH_INPUT_PASTE_CHUNK_CHARS));
      }
    }
  }

  /** 清空隐藏输入框缓存。提交/提交键/焦点生命周期结束时调用。 */
  private resetKeyboardBuffer(committedValue: string = ''): void {
    resetSshImeShadow(this.imeCallbackState, committedValue);
    this.kbInput = '';
    try { this.kbCtrl.caretPosition(0); } catch (_e) { /* ignore */ }
  }

  private handleSoftWillInsert(info: InsertValue): boolean {
    return recordSshImeWillInsert(this.imeCallbackState, info.insertValue);
  }

  private handleSoftDidInsert(info: InsertValue): void {
    const committed: string = consumeSshImeDidInsert(this.imeCallbackState, info.insertValue);
    if (committed.length > 0) { this.onTerminalData(committed); }
    this.resetKeyboardBuffer(committed);
  }

  private handleSoftWillDelete(info: DeleteValue): boolean {
    return recordSshImeWillDelete(this.imeCallbackState, info.deleteValue);
  }

  private handleSoftDidDelete(info: DeleteValue): void {
    const deleted: string | null = consumeSshImeDidDelete(this.imeCallbackState, info.deleteValue);
    if (deleted !== null) {
      this.sendTerminalBytes(encodeSoftDelete(deleted), true);
    }
    this.resetKeyboardBuffer();
  }

  /** onChange only maintains the hidden editor; it never emits terminal data. */
  private handleChangeGuard(v: string, previewText?: PreviewText): void {
    const previewUnits: number = previewText ? previewText.value.length : 0;
    const decision = inspectSshImeChange(this.imeCallbackState, v, previewUnits);
    if (decision.updateShadow) { this.kbInput = v; }
    if (previewUnits > 0) {
      hilog.debug(0x0000, 'SshTerminal', '[input] IME preview kept local units=' + previewUnits.toString());
    }
    if (decision.sendRemote) {
      if (decision.remoteDelete.length > 0) {
        this.sendTerminalBytes(encodeSoftDelete(decision.remoteDelete), true);
      }
      if (decision.remoteInsert.length > 0) {
        this.onTerminalData(decision.remoteInsert);
      }
    }
    if (decision.resetLocal) { this.resetKeyboardBuffer(v); }
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
  SftpRightEndpointChooser() {
    Column() {
      Row({ space: 10 }) {
        Button('本机文件')
          .width(this.sftpWideLayout() ? 150 : 132)
          .height(40).fontSize(12)
          .backgroundColor(this.sshPal().card)
          .fontColor(this.sshPal().text)
          .enabled(!this.sftpBusy)
          .onClick((): void => { this.useSftpLocalEndpoint(); })
        Button('选择 SSH 主机')
          .width(this.sftpWideLayout() ? 150 : 132)
          .height(40).fontSize(12)
          .backgroundColor(this.accentColor)
          .fontColor('#FFFFFF')
          .enabled(!this.sftpBusy)
          .onClick((): void => { this.openSftpPeerPicker(); })
      }
      .width('100%')
      .justifyContent(FlexAlign.Center)
    }
    .width('100%')
    .height(this.sftpWideLayout() ? '100%' : this.sftpListHeight())
    .constraintSize({ minHeight: 0 })
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .backgroundColor(this.sshPal().surface)
    .borderRadius(10)
    .border({ width: 0.5, color: this.sshPal().divider })
  }

  @Builder
  SftpPeerHostPickerSheet() {
    Column() {
      Row() {
        Text('选择目标 SSH 主机').fontSize(17).fontWeight(FontWeight.Medium)
          .fontColor('#F4F7FA').layoutWeight(1)
        SymbolGlyph($r('sys.symbol.xmark')).fontSize(18)
          .fontColor(['rgba(242,244,247,0.78)'])
          .width(34).height(34)
          .margin({ top: this.sftpHeaderCloseTopMargin() })
          .onClick((): void => { this.requestSftpPeerHostPickerClose(); })
      }.width('100%').alignItems(VerticalAlign.Center)
      Scroll() {
        Column({ space: 8 }) {
          ForEach(this.sshTabHosts(), (host: RemoteHost): void => {
            Row() {
              Column() {
                Text(host.label).fontSize(14).fontColor('#F4F7FA')
                  .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                Text(host.username + '@' + host.host + ':' + host.port.toString())
                  .fontSize(11).fontColor('rgba(242,244,247,0.56)')
                  .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
              }.alignItems(HorizontalAlign.Start).layoutWeight(1)
              if (host.id === this.hostId) {
                Text('当前 host').fontSize(10).fontColor(this.accentColor)
              } else if (this.sshTabStore.sessionId(host.id) > 0) {
                Text('已打开').fontSize(10).fontColor(this.accentColor)
              }
            }
            .width('100%').height(52).padding({ left: 12, right: 12 })
            .borderRadius(8).backgroundColor('rgba(255,255,255,0.07)')
            .onClick((): void => { this.selectSftpPeerHost(host); })
          }, (host: RemoteHost): string => host.id)
        }.width('100%')
      }.layoutWeight(1).width('100%').scrollBar(BarState.Off)
    }
    .width('100%').height(this.sftpWideLayout() ? '100%' : this.sftpSheetMaxHeight())
    .padding({ left: 16, right: 16, top: 12, bottom: 14 })
    .backgroundColor('#171D25')
    .borderRadius(this.sftpWideLayout() ? 0 : 18)
    .constraintSize({ maxWidth: 620 })
  }

  @Builder
  SftpPeerNavigation() {
    Row() {
      Button('上级').height(32).fontSize(11)
        .enabled(!this.sftpBusy && !this.sftpPeerBusy)
        .onClick((): void => { void this.refreshSftpPeer(this.parentRemotePath(this.sftpPeerPath)); })
      Button('刷新').height(32).fontSize(11).margin({ left: 6 })
        .enabled(!this.sftpBusy && !this.sftpPeerBusy)
        .onClick((): void => { void this.refreshSftpPeer(this.sftpPeerPath); })
      Button('根目录').height(32).fontSize(11).margin({ left: 6 })
        .enabled(!this.sftpBusy && !this.sftpPeerBusy)
        .onClick((): void => { void this.refreshSftpPeer('/'); })
    }.width('100%').margin({ bottom: 8 })
    Row() {
      TextInput({ text: this.sftpPeerPathInput })
        .fontSize(11).fontColor(this.sshPal().text).fontFamily('monospace')
        .backgroundColor(this.sshPal().surface).height(36).borderRadius(8).layoutWeight(1)
        .onChange((value: string): void => { this.sftpPeerPathInput = value; })
        .onSubmit((): void => { void this.refreshSftpPeer(this.sftpPeerPathInput); })
      Button('跳转').height(36).fontSize(11).margin({ left: 6 })
        .enabled(!this.sftpBusy && !this.sftpPeerBusy)
        .onClick((): void => { void this.refreshSftpPeer(this.sftpPeerPathInput); })
    }.width('100%').margin({ bottom: 8 })
  }

  @Builder
  SftpPeerWorkspace() {
    Column() {
      Row() {
        Column() {
          Text(this.sftpPeerHostLabel()).fontSize(14).fontWeight(FontWeight.Medium)
            .fontColor(this.sshPal().text)
          Text(this.sftpPeerPath).fontSize(10).fontColor(this.sshPal().text3).margin({ top: 3 })
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        Text(this.sftpPeerEntries.length.toString() + ' 项')
          .fontSize(10).fontColor(this.sshPal().text3)
        Button('切换').height(28).fontSize(10).width(52)
          .enabled(!this.sftpBusy && !this.sftpPeerBusy)
          .onClick((): void => { this.resetSftpRightEndpointSelection(); })
      }.width('100%').margin({ bottom: 6 })
      if (this.sftpPeerBusy) {
        Column() {
          LoadingProgress().width(24).height(24).color(this.accentColor)
          Text(this.sftpPeerStatus).fontSize(11).fontColor(this.sshPal().text2).margin({ top: 8 })
        }.layoutWeight(1).width('100%').justifyContent(FlexAlign.Center)
      } else if (this.sftpPeerEntries.length === 0) {
        Column() {
          Text(this.sftpPeerStatus).fontSize(12).fontColor(this.sshPal().text2)
          Text('目标目录为空或尚未完成认证').fontSize(10)
            .fontColor(this.sshPal().text3).margin({ top: 4 })
        }.layoutWeight(1).width('100%').justifyContent(FlexAlign.Center)
      } else {
        List() {
          ForEach(this.sftpPeerEntries, (entry: SftpFileEntry): void => {
            ListItem() {
              Row() {
                SymbolGlyph(entry.isDirectory ? $r('sys.symbol.folder') : $r('sys.symbol.doc'))
                  .fontSize(18)
                  .fontColor([entry.isDirectory ? this.accentColor : this.sshPal().text3])
                  .width(28)
                Column() {
                  Text(entry.name).fontSize(12).fontColor(this.sshPal().text)
                    .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                  Text(entry.isDirectory ? '目录' : this.formatFileSize(entry.size))
                    .fontSize(10).fontColor(this.sshPal().text3).margin({ top: 2 })
                }.alignItems(HorizontalAlign.Start).layoutWeight(1)
                if (this.sftpPeerSelectedPath === entry.path) {
                  SymbolGlyph($r('sys.symbol.checkmark')).fontSize(16).fontColor([this.accentColor])
                }
              }
              .width('100%').height(46).padding({ left: 8, right: 8 })
              .borderRadius(7)
              .backgroundColor(this.sftpPeerSelectedPath === entry.path
                ? this.sshPal().card : Color.Transparent)
              .onClick((): void => { this.selectSftpPeerEntry(entry); })
            }
          }, (entry: SftpFileEntry): string => entry.path)
        }.layoutWeight(1).width('100%').constraintSize({ minHeight: 0 })
      }
      Row() {
        Button('进入目录').height(32).fontSize(11).layoutWeight(1)
          .enabled(!this.sftpBusy && !this.sftpPeerBusy && this.sftpPeerSelectedIsDir)
          .onClick((): void => { void this.refreshSftpPeer(this.sftpPeerSelectedPath); })
        Button('刷新').height(32).fontSize(11).layoutWeight(1).margin({ left: 6 })
          .enabled(!this.sftpBusy && !this.sftpPeerBusy && this.sftpPeerHostId.length > 0)
          .onClick((): void => { void this.refreshSftpPeer(this.sftpPeerPath); })
      }.width('100%').margin({ top: 8 })
    }.width('100%').height('100%').constraintSize({ minHeight: 0 })
      .padding({ top: 6, bottom: 6, left: 10, right: 10 })
      .backgroundColor(this.sshPal().surface)
      .borderRadius(10)
      .border({ width: 0.5, color: this.sshPal().divider })
  }

  @Builder
  SftpLocalWorkspace() {
    Column() {
      Row() {
        Column() {
          Text('本机文件').fontSize(14).fontWeight(FontWeight.Medium).fontColor(this.sshPal().text)
          if (this.sftpWideLayout()) {
            Text(this.sftpLocalProviderStatus)
              .fontSize(10).fontColor(this.sshPal().text2).margin({ top: 3 })
              .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          Text(this.sftpLocalPath.length > 0 ? this.sftpLocalPath : '未选择本机目录')
            .fontSize(10).fontColor(this.sshPal().text3).margin({ top: 3 })
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        Button('切换').height(30).fontSize(10).width(52)
          .enabled(!this.sftpBusy && !this.sftpPickerBusy)
          .onClick((): void => { this.resetSftpRightEndpointSelection(); })
        Button('上级').height(32).fontSize(11).margin({ left: 6 })
          .enabled(!this.sftpBusy && this.sftpLocalPath.length > 0)
          .onClick((): void => { void this.openSftpLocalParent(); })
        Button('刷新').height(32).fontSize(11).margin({ left: 6 })
          .enabled(!this.sftpBusy)
          .onClick((): void => { void this.refreshSftpLocal(this.pageGeneration); })
      }.width('100%').margin({ bottom: this.sftpWideLayout() ? 4 : 8 })

      if (this.sftpWideLayout() && this.localProviderNeedsAuthorization()) {
        Button(this.sftpPickerBusy ? '正在选择本机目录...' : '授权本机目录')
          .height(this.sftpWideLayout() ? 32 : 36).fontSize(12).width('100%')
          .margin({ bottom: this.sftpWideLayout() ? 4 : 8 })
          .enabled(!this.sftpBusy && !this.sftpPickerBusy)
          .onClick((): void => { void this.authorizeLocalProvider(); })
      }

      if (this.sftpLocalEntries.length === 0) {
        Column() {
          Text(this.sftpLocalProviderStatus === '本机文件能力不可用'
            ? '当前设备没有可用的本机文件能力'
            : '本机目录为空或尚未授权')
            .fontSize(12).fontColor(this.sshPal().text2)
          Text('选择本机文件后可上传到当前远端目录')
            .fontSize(10).fontColor(this.sshPal().text3).margin({ top: 4 })
        }.height(this.sftpWideLayout() ? 0 : this.sftpListHeight())
          .layoutWeight(this.sftpWideLayout() ? 1 : 0)
          .constraintSize({ minHeight: 0 })
          .justifyContent(FlexAlign.Center)
      } else {
        List() {
          ForEach(this.sftpLocalEntries, (entry: SshLocalFileEntry) => {
            ListItem() {
              Row() {
                SymbolGlyph(entry.isDirectory ? $r('sys.symbol.folder') : $r('sys.symbol.doc'))
                  .fontSize(17)
                  .fontColor([entry.isDirectory ? this.accentColor : this.sshPal().text3])
                  .width(28)
                Column() {
                  Text(entry.name)
                    .fontSize(12).fontColor(this.sshPal().text)
                    .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                  Text(entry.isDirectory ? '目录' : this.formatFileSize(entry.size))
                    .fontSize(10).fontColor(this.sshPal().text3).margin({ top: 2 })
                }.alignItems(HorizontalAlign.Start).layoutWeight(1)
                if (this.sftpLocalSelectedUri === entry.uri) {
                  SymbolGlyph($r('sys.symbol.checkmark'))
                    .fontSize(16).fontColor([this.accentColor])
                }
              }
              .width('100%').height(44).padding({ left: 8, right: 8 })
              .borderRadius(7)
              .backgroundColor(this.sftpLocalSelectedUri === entry.uri
                ? this.sshPal().card : Color.Transparent)
              .onClick((): void => { this.selectSftpLocalEntry(entry); })
            }
          }, (entry: SshLocalFileEntry) => entry.uri)
        }
        .height(this.sftpWideLayout() ? 0 : this.sftpLocalListHeight())
        .layoutWeight(this.sftpWideLayout() ? 1 : 0)
        .constraintSize({ minHeight: 0 })
        .width('100%')
      }

      Row() {
        Button('进入目录')
          .height(this.sftpWideLayout() ? 32 : 36).fontSize(11).layoutWeight(1)
          .enabled(!this.sftpBusy && this.sftpLocalSelectedIsDir)
          .onClick((): void => { this.openSftpLocalSelectedDir(); })
        Button(this.sftpWideLayout() ? '选择/上传文件' : '选中文件上传')
          .height(this.sftpWideLayout() ? 32 : 36).fontSize(11).layoutWeight(1)
          .margin({ left: this.sftpWideLayout() ? 6 : 8 })
          .enabled(this.sftpWideLayout()
            ? !this.sftpBusy
            : !this.sftpBusy && this.sftpLocalSelectedUri.length > 0 && !this.sftpLocalSelectedIsDir)
          .onClick((): void => { void this.uploadSftpFile(); })
        Button('递归上传目录')
          .height(this.sftpWideLayout() ? 32 : 36).fontSize(11).layoutWeight(1)
          .margin({ left: this.sftpWideLayout() ? 6 : 8 })
          .enabled(!this.sftpBusy && this.sftpLocalSelectedUri.length > 0 &&
            this.sftpLocalSelectedIsDir)
          .onClick((): void => { void this.enqueueSftpUploadDirectory(); })
      }.width('100%').margin({ top: 8 })
    }
    .width('100%')
    .height(this.sftpWideLayout() ? '100%' : 'auto')
    .constraintSize({ minHeight: 0 })
    .padding({
      top: this.sftpWideLayout() ? 6 : 10,
      bottom: this.sftpWideLayout() ? 6 : 10,
      left: 10,
      right: 10
    })
    .backgroundColor(this.sshPal().surface)
    .borderRadius(10)
    .border({ width: 0.5, color: this.sshPal().divider })
  }

  @Builder
  SftpRecoveredTasks() {
    if (this.sftpRecoveredTasks.length > 0) {
      Column() {
        Row() {
          Text('待恢复任务').fontSize(13).fontWeight(FontWeight.Medium).fontColor(this.sshPal().text)
          Text(this.sftpRecoveredTasks.length.toString() + ' 项')
            .fontSize(10).fontColor(this.sshPal().text3).margin({ left: 6 })
        }.width('100%').margin({ bottom: 6 })
          ForEach(this.sftpRecoveredTasks, (task: SshSftpTaskRecord) => {
            Row() {
              Column() {
              Text((task.sourceEndpoint?.kind === 'ssh' && task.targetEndpoint?.kind === 'ssh'
                ? '双 SSH ' : (task.direction === 'upload' ? '上传 ' : '下载 ')) +
                (task.isDirectory ? '目录 ' : '') + task.fileName)
                .fontSize(11).fontColor(this.sshPal().text)
                .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
              Text(this.sftpTaskStageLabel(task.stage) + ' · ' + (task.isDirectory ? '目录' :
                (task.totalBytes >= 0 ? this.formatFileSize(task.verifiedOffset) + ' / ' +
                  this.formatFileSize(task.totalBytes) : '大小未知')))
                .fontSize(10).fontColor(this.sshPal().text3).margin({ top: 2 })
            }.alignItems(HorizontalAlign.Start).layoutWeight(1)
            Button(task.sourceEndpoint?.kind === 'ssh' && task.targetEndpoint?.kind === 'ssh'
              ? '恢复双 SSH' : (task.batchId.trim().length > 0 ? '恢复批次' : '恢复'))
              .height(30).fontSize(10)
              .enabled(!this.sftpBusy && this.sessionId > 0)
              .onClick((): void => {
                if (task.sourceEndpoint?.kind === 'ssh' && task.targetEndpoint?.kind === 'ssh') {
                  void this.recoverSftpRemoteBatch(task.batchId);
                } else if (task.batchId.trim().length > 0) { void this.recoverSftpBatch(task.batchId); }
                else { void this.recoverSftpTask(task); }
              })
            Button('取消').height(30).fontSize(10).margin({ left: 6 })
              .enabled(!this.sftpBusy)
              .onClick((): void => { this.cancelRecoveredSftpTask(task); })
          }
          .width('100%').height(46).padding({ left: 8, right: 8 })
          .borderRadius(7).backgroundColor(this.sshPal().surface)
          .margin({ bottom: 4 })
        }, (task: SshSftpTaskRecord) => task.taskId)
      }
      .width('100%').padding({ top: 8, bottom: 8, left: 10, right: 10 })
      .backgroundColor(this.sshPal().surface)
      .borderRadius(10)
      .border({ width: 0.5, color: this.sshPal().divider })
      .margin({ bottom: 10 })
    }
  }

  @Builder
  SftpRemoteWorkspace() {
    Column() {
      Row() {
        Column() {
          Text('远端文件').fontSize(14).fontWeight(FontWeight.Medium).fontColor(this.sshPal().text)
          Text(this.sftpPath).fontSize(10).fontColor(this.sshPal().text3).margin({ top: 3 })
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        Text(this.sftpEntries.length.toString() + ' 项')
          .fontSize(10).fontColor(this.sshPal().text3)
      }.width('100%').margin({ bottom: 8 })

      Column() {
        if (this.sftpBusy || this.sftpTransferSession !== null &&
          (this.sftpTransferSession.stage === 'paused' ||
            this.sftpTransferSession.stage === 'waitingRemote')) {
          Column() {
            Row() {
              if (this.sftpBusy) {
                LoadingProgress().width(22).height(22).color(this.accentColor)
              } else {
                Text(this.sftpTransferSession !== null &&
                  this.sftpTransferSession.stage === 'waitingRemote' ? '等待连接' : '暂停')
                  .fontSize(12).fontColor(this.accentColor)
                  .width(22).height(22).textAlign(TextAlign.Center)
              }
              Text(this.sftpProgress >= 0
                ? (this.sftpProgressLabel + ' ' + Math.floor(this.sftpProgress * 100).toString() + '%')
                : '处理中...')
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
          }.height(this.sftpWideLayout() ? 0 : this.sftpListHeight())
            .layoutWeight(this.sftpWideLayout() ? 1 : 0)
            .constraintSize({ minHeight: 0 })
            .justifyContent(FlexAlign.Center)
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
                .backgroundColor(this.sftpSelectedPath === entry.path
                  ? this.sshPal().card : Color.Transparent)
                .onClick((): void => { this.enterSftpEntry(entry); })
              }
            }, (entry: SftpFileEntry) => entry.path)
          }
          .height(this.sftpWideLayout() ? 0 : this.sftpListHeight())
          .layoutWeight(this.sftpWideLayout() ? 1 : 0)
          .constraintSize({ minHeight: 0 })
          .width('100%')
        }
      }
      .width('100%')
      .height(this.sftpWideLayout() ? 0 : 'auto')
      .layoutWeight(this.sftpWideLayout() ? 1 : 0)
      .constraintSize({ minHeight: 0 })
      .padding({ top: 6, bottom: 6 })
    }
    .width('100%')
    .height(this.sftpWideLayout() ? '100%' : 'auto')
    .constraintSize({ minHeight: 0 })
    .padding({ top: 10, bottom: 10, left: 10, right: 10 })
    .backgroundColor(this.sshPal().surface)
    .borderRadius(10)
    .border({ width: 0.5, color: this.sshPal().divider })
  }

  @Builder
  SftpTransferHeader() {
    Column() {
      Row() {
        Column() {
          Text('SFTP 文件传输').fontSize(18).fontWeight(FontWeight.Medium)
            .fontColor(this.sshPal().text)
          Text(this.userAtHost).fontSize(12).fontColor(this.sshPal().text2).margin({ top: 4 })
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          if (!this.sftpWideLayout()) {
            Text('本机: ' + this.sftpLocalProviderStatus).fontSize(11).fontColor(this.sshPal().text3)
              .margin({ top: 3 }).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          }
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        Row() {
          SymbolGlyph($r('sys.symbol.xmark')).fontSize(18)
            .fontColor([this.sshPal().text2])
        }
        .width(36).height(36).justifyContent(FlexAlign.Center)
        .borderRadius(18).backgroundColor(this.sshPal().surface)
        .margin({ top: this.sftpHeaderCloseTopMargin() })
        .onClick((): void => { this.closeSftpPanel(); })
      }.width('100%').alignItems(VerticalAlign.Center)
    }
    // Keep the close affordance away from the sheet edge and the Pad window
    // safe-area inset. The title and close control move as one header row.
    .width('100%')
    .padding({ top: this.sftpHeaderTopPadding() })
    .margin({ bottom: 14 })
  }

  @Builder
  SftpTransferNavigation() {
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
  }

  @Builder
  SftpWideRemoteActions() {
    if (this.sftpRightEndpointChosen && this.sftpRightEndpoint === 'ssh') {
      Row() {
        Button('传输到目标 SSH')
          .height(38).fontSize(12).layoutWeight(1)
          .enabled(!this.sftpBusy && this.sftpSelectedPath.length > 0)
          .onClick((): void => { void this.enqueueSftpRemoteBatch(true); })
        Button('传输到当前 host')
          .height(38).fontSize(12).layoutWeight(1).margin({ left: 8 })
          .enabled(!this.sftpBusy && this.sftpPeerSelectedPath.length > 0)
          .onClick((): void => { void this.enqueueSftpRemoteBatch(false); })
      }.width('100%').margin({ top: 8 })
    } else if (this.sftpRightEndpointChosen) {
      Row() {
        Button('下载选中文件')
          .height(38).fontSize(12).layoutWeight(1)
          .enabled(!this.sftpBusy && this.sftpSelectedPath.length > 0 && !this.sftpSelectedIsDir)
          .onClick((): void => { this.downloadSftpSelected(); })
        Button('递归下载选中目录')
          .height(38).fontSize(12).layoutWeight(1).margin({ left: 8 })
          .enabled(!this.sftpBusy && this.sftpSelectedPath.length > 0 &&
            this.sftpSelectedIsDir && this.sftpLocalSelectedIsDir &&
            this.sftpLocalSelectedUri.length > 0)
          .onClick((): void => { void this.enqueueSftpDownloadDirectory(); })
      }.width('100%').margin({ top: 8 })
    }

    if (this.sftpRightEndpointChosen) {
      Row() {
        Button('进入目录')
          .height(36).fontSize(11).layoutWeight(1)
          .enabled(!this.sftpBusy && this.sftpSelectedPath.length > 0 && this.sftpSelectedIsDir)
          .onClick((): void => { this.openSftpSelectedDir(); })
        Button('删除选中项')
          .height(36).fontSize(11).layoutWeight(1).margin({ left: 8 })
          .enabled(!this.sftpBusy && this.sftpSelectedPath.length > 0)
          .backgroundColor(this.sshPal().danger).fontColor('#FFFFFF')
          .onClick((): void => { this.deleteSftpSelected(); })
      }.width('100%').margin({ top: 8 })
    }
  }

  @Builder
  SftpTransferWorkspace() {
    if (this.sftpWideLayout()) {
      Row() {
        Column() {
          this.SftpTransferNavigation()
          Column() {
            this.SftpRemoteWorkspace()
          }.layoutWeight(1).constraintSize({ minHeight: 0 })
          this.SftpWideRemoteActions()
        }.layoutWeight(1).height('100%').constraintSize({ minWidth: 0, minHeight: 0 })
          .margin({ right: 6 })
        Column() {
          if (!this.sftpRightEndpointChosen) {
            this.SftpRightEndpointChooser()
          } else if (this.sftpRightEndpoint === 'ssh') {
            Column() {
              this.SftpPeerNavigation()
              this.SftpPeerWorkspace()
            }.layoutWeight(1).constraintSize({ minHeight: 0 })
          } else {
            Column() {
              this.SftpLocalWorkspace()
            }.layoutWeight(1).constraintSize({ minHeight: 0 })
          }
        }.layoutWeight(1).height('100%').constraintSize({ minWidth: 0, minHeight: 0 })
          .margin({ left: 6 })
      }.width('100%').layoutWeight(1).constraintSize({ minHeight: 0 })
    } else {
      Column() {
        this.SftpRemoteWorkspace()
        if (!this.sftpRightEndpointChosen) {
          this.SftpRightEndpointChooser()
        } else if (this.sftpRightEndpoint === 'ssh') {
          this.SftpPeerNavigation()
          this.SftpPeerWorkspace()
        } else {
          this.SftpLocalWorkspace()
        }
      }.width('100%')
    }
  }

  @Builder
  SftpTransferStatus() {
    if (shouldShowTransferCancelAction(this.sftpTransferSession)) {
      if (this.sftpTransferSession !== null && this.sftpTransferSession.stage === 'transferring') {
        Button('暂停传输')
          .height(36).fontSize(12).width('100%').margin({ top: 8 })
          .onClick((): void => { this.pauseSftpTransfer(); })
      }
      if (this.sftpTransferSession !== null &&
        (this.sftpTransferSession.stage === 'paused' ||
          this.sftpTransferSession.stage === 'waitingRemote') && !this.sftpBusy) {
        Button('继续传输')
          .height(36).fontSize(12).width('100%').margin({ top: 8 })
          .onClick((): void => { void this.resumeSftpTransfer(); })
      }
      Button('取消传输')
        .height(36).fontSize(12).width('100%').margin({ top: 8 })
        .backgroundColor(this.sshPal().danger).fontColor('#FFFFFF').borderRadius(8)
        .onClick((): void => { this.cancelSftpTransfer(); })
    }

    Text(this.sftpStatus)
      .fontSize(11).fontColor(this.sshPal().text2).width('100%')
      .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
      .margin({ top: 8 })

    if (!this.sftpBusy && this.sftpTransferSession !== null &&
      (this.sftpTransferSession.stage === 'failed' || this.sftpTransferSession.stage === 'cancelled')) {
      Button('重试传输')
        .height(32).fontSize(11).width('100%').margin({ top: 8 })
        .onClick((): void => { this.retrySftpTransfer(); })
    }
  }

  @Builder
  SftpTransferActions() {
    if (shouldShowTransferCancelAction(this.sftpTransferSession)) {
      if (this.sftpTransferSession !== null && this.sftpTransferSession.stage === 'transferring') {
        Button('暂停传输')
          .height(40).fontSize(13).width('100%').margin({ top: 10 })
          .onClick((): void => { this.pauseSftpTransfer(); })
      }
      if (this.sftpTransferSession !== null &&
        (this.sftpTransferSession.stage === 'paused' ||
          this.sftpTransferSession.stage === 'waitingRemote') && !this.sftpBusy) {
        Button('继续传输')
          .height(40).fontSize(13).width('100%').margin({ top: 10 })
          .onClick((): void => { void this.resumeSftpTransfer(); })
      }
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

    if (this.sftpRightEndpointChosen && this.sftpRightEndpoint === 'ssh') {
      Row() {
        Button('传输到目标 SSH')
          .height(40).layoutWeight(1).enabled(!this.sftpBusy && this.sftpSelectedPath.length > 0)
          .fontSize(12)
          .onClick((): void => { void this.enqueueSftpRemoteBatch(true); })
        Button('传输到当前 host')
          .height(40).layoutWeight(1)
          .enabled(!this.sftpBusy && this.sftpPeerSelectedPath.length > 0)
          .fontSize(12).margin({ left: 10 })
          .onClick((): void => { void this.enqueueSftpRemoteBatch(false); })
      }.width('100%').margin({ top: 14 })
    } else if (this.sftpRightEndpointChosen) {
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

      Button('递归下载选中目录')
        .height(40).width('100%').margin({ top: 10 })
        .enabled(!this.sftpBusy && this.sftpSelectedPath.length > 0 &&
          this.sftpSelectedIsDir && this.sftpLocalSelectedIsDir &&
          this.sftpLocalSelectedUri.length > 0)
        .onClick((): void => { void this.enqueueSftpDownloadDirectory(); })
    }

    if (this.sftpRightEndpointChosen) {
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
  }

  @Builder
  SftpTransferSheet(peerPickerMountToken: number) {
    Stack() {
      if (this.sftpWideLayout()) {
        Column() {
          this.SftpTransferHeader()
          this.SftpRecoveredTasks()
          this.SftpTransferWorkspace()
          this.SftpTransferStatus()
        }
        .width('100%').height('100%')
        .constraintSize({ maxWidth: 2000, minHeight: 0 })
        .padding({ left: 24, right: 24, top: 22, bottom: 24 })
        .backgroundColor(this.sshPal().bg)
      } else {
        Scroll() {
          Column() {
            this.SftpTransferHeader()
            if (this.localProviderNeedsAuthorization()) {
              Button('授权本机目录')
                .height(36).fontSize(12).width('100%').margin({ bottom: 10 })
                .enabled(!this.sftpBusy)
                .onClick((): void => { void this.authorizeLocalProvider(); })
            }
            this.SftpRecoveredTasks()
            this.SftpTransferNavigation()
            this.SftpTransferWorkspace()
            this.SftpTransferActions()
          }
          .width('100%')
          .constraintSize({ maxWidth: 620 })
          .padding({ left: 22, right: 22, top: 20, bottom: 22 })
          .borderRadius(18)
          .backgroundColor(this.sshPal().bg)
        }
        .width('100%')
        .height('auto')
        .constraintSize({ maxHeight: this.sftpSheetMaxHeight() })
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
      }
    }
    .width('100%')
    .height(this.sftpWideLayout() ? '100%' : 'auto')
    .constraintSize({ minHeight: 0 })
    .backgroundColor(this.sshPal().bg)
    .bindSheet($$this.sftpPeerHostPicker, this.SftpPeerHostPickerSheet(), {
      height: this.sftpWideLayout() ? SheetSize.LARGE : this.sftpSheetMaxHeight(),
      preferType: this.sftpWideLayout() ? SheetType.CENTER : SheetType.BOTTOM,
      width: this.sftpWideLayout() ? '88%' : '100%',
      dragBar: !this.sftpWideLayout(),
      backgroundColor: '#171D25',
      blurStyle: BlurStyle.NONE,
      showClose: false,
      maskColor: 'rgba(0,0,0,0.42)',
      onWillDismiss: (action: DismissSheetAction): void => {
        this.handleSftpPeerHostPickerDismiss(action, peerPickerMountToken);
      },
      onDisappear: (): void => { this.handleSftpPeerHostPickerDisappear(peerPickerMountToken); }
    })
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column() {
      // 手机保留原始独立标签条; Pad/PC 的标签条嵌入连接顶栏。
      if (this.sshTabViews.length > 0 && !this.sshTabsInline()) {
        this.sshTabStrip()
      }

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
          .onClick((): void => { this.closeSessionAndBack(); })
        } else {
          Text('<').fontSize(20).fontColor('#E6E6E6')
            .width(40).height(40).textAlign(TextAlign.Center)
            .borderRadius(20)
            .backgroundColor('rgba(255,255,255,0.06)')
            .onClick((): void => { this.closeSessionAndBack(); })
        }
        Column() {
          Text(this.hostLabel).fontSize(15).fontWeight(FontWeight.Medium).fontColor('#F2F4F7')
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.userAtHost).fontSize(11).fontColor('rgba(242,244,247,0.58)')
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        }.alignItems(HorizontalAlign.Start)
          .layoutWeight(this.sshTabsInline() ? 0 : 1)
          .width(this.sshTabsInline() ? this.sshInlineHostWidth() : 'auto')
          .margin({ left: 10 })
        if (this.sshTabsInline()) {
          this.sshTabStripInline()
        }
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
      .justifyContent(FlexAlign.Start)
      .height(this.headerHeight())
      .padding({ left: 10, right: 16, top: 6 + this.headerTopOffset(), bottom: 6 })
      .backgroundColor(this.chromeBg())
      .backgroundBlurStyle(BlurStyle.NONE)
      .linearGradient({
        direction: GradientDirection.Bottom,
        colors: [['rgba(255,255,255,0.09)', 0], ['rgba(255,255,255,0.00)', 1]]
      })

      // Keep one keyed surface slot per committed SSH binding. During the
      // handoff the old document is masked; the new document is mounted only
      // after the host/binding commit has become observable.
      if (this.sshTabViews.length === 0) {
        Column() {
          if (this.connecting || (this.connected && !this.terminalSurfaceMounted)) {
            LoadingProgress().width(32).height(32).color(this.accentColor)
            Text('Connecting...').fontSize(13).fontColor('#888').margin({ top: 10 })
          } else {
            Text(this.connectionError).fontSize(14).fontColor('#FF6B6B')
            Button('重试').margin({ top: 16 }).backgroundColor(this.accentColor).fontColor('#FFFFFF').borderRadius(8)
              .onClick((): void => { this.retryConnection(); })
            Button('返回').margin({ top: 16 }).backgroundColor(this.accentColor).fontColor('#FFFFFF').borderRadius(8)
              .onClick((): void => { this.closeSessionAndBack(); })
          }
        }.width('100%').layoutWeight(1).justifyContent(FlexAlign.Center).backgroundColor('#0D0D0D')
      } else {
        Stack({ alignContent: Alignment.TopStart }) {
          // Once the xterm WebView is mounted it must remain visible even if a
          // late ArkWeb ready callback is still being retried. Otherwise a
          // missed proxy callback turns a real terminal into a permanent full
          // screen "Preparing terminal..." mask.
          if (!this.xtermReady && !this.terminalSurfaceMounted) {
            Column() {
              if (this.connecting || (this.connected &&
                (!this.terminalSurfaceMounted || !this.xtermReady))) {
                LoadingProgress().width(32).height(32).color(this.accentColor)
                Text(this.connected ? 'Preparing terminal...' : 'Connecting...')
                  .fontSize(13).fontColor('#888').margin({ top: 10 })
              } else {
                Text(this.connectionError).fontSize(14).fontColor('#FF6B6B')
                Button('重试').margin({ top: 16 }).backgroundColor(this.accentColor)
                  .fontColor('#FFFFFF').borderRadius(8)
                  .onClick((): void => { this.retryConnection(); })
                Button('返回').margin({ top: 16 }).backgroundColor(this.accentColor)
                  .fontColor('#FFFFFF').borderRadius(8)
                  .onClick((): void => { this.closeSessionAndBack(); })
              }
            }
            .width('100%').height(this.terminalPaneHeight()).justifyContent(FlexAlign.Center)
            .backgroundColor('#0D0D0D').zIndex(30)
          }

          Stack({ alignContent: Alignment.TopStart }) {
            ForEach(this.sshTabViews, (tab: SshTerminalTabView): void => {
              SshXtermSurface({
                coreKey: this.xtermSurfaceCoreKey(tab.hostId),
                renderRevision: sshXtermTabRenderRevision(
                  this.sshTabStore.sessionGeneration(tab.hostId)),
                surfaceRefreshRequest: this.terminalSurfaceRefreshRequest,
                active: tab.active,
                cols: this.termCols,
                rows: this.termRows,
                viewportWidth: this.termAreaW,
                fontSize: this.fontSize,
                lineSpacing: normalizeSshTerminalLineSpacing(this.lineSpacing),
                bottomAlignSparseContent: !this.isDesktopDevice,
                viewportHeight: this.terminalPaneHeight(),
                outputBuffer: this.xtermOutputBufferForHost(tab.hostId),
                outputSequence: this.termOutputSequence,
                focusRequest: this.terminalFocusRequest,
                copyRequest: this.copyRequest,
                copiedText: this.copiedText,
                scrollToBottomRequest: this.scrollToBottomRequest,
                forceScrollToBottomRequest: this.forceScrollToBottomRequest,
                externalScrollLines: this.terminalExternalScrollLines,
                externalScrollRequest: this.terminalExternalScrollRequest,
                onData: (data: string, surfaceIdentity: string): void => {
                  this.onXtermDataForHost(tab.hostId,
                    this.sshTabStore.sessionGeneration(tab.hostId),
                    data, surfaceIdentity);
                },
                onResize: (cols: number, rows: number, surfaceIdentity: string): void => {
                  this.onXtermResizeForHost(tab.hostId,
                    this.sshTabStore.sessionGeneration(tab.hostId),
                    cols, rows, surfaceIdentity);
                },
                onReady: (surfaceIdentity: string): void => {
                  this.onXtermReadyForHost(tab.hostId,
                    this.sshTabStore.sessionGeneration(tab.hostId),
                    surfaceIdentity);
                }
              })
                .width('100%')
                .height(this.terminalPaneHeight())
                .opacity(tab.active ? 1 : 0)
                .zIndex(tab.active ? 1 : 0)
                .hitTestBehavior(tab.active ? HitTestMode.Default : HitTestMode.None)
            }, (tab: SshTerminalTabView): string => tab.tabId)

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
              .opacity(0)
              .position({ x: 0, y: 0 })
              .hitTestBehavior(HitTestMode.Transparent)  // 透明命中, 不拦截父 onClick
              .defaultFocus(!this.xtermReady && (this.isDesktopDevice || this.physicalKeyboardConnected ||
                (this.breakpoint !== 'sm' && this.sshInputMode === 2)))
              .focusOnTouch(true)
              .enableKeyboardOnFocus(!this.isDesktopDevice && this.virtualKeyBarVisible() &&
                (!this.physicalKeyboardConnected || this.softKeyboardRequested))
              .autoCapitalizationMode(AutoCapitalizationMode.NONE)
              .enterKeyType(EnterKeyType.Send)
              .copyOption(CopyOptions.None)
              .selectionMenuHidden(true)
              .onWillInsert((info: InsertValue): boolean => {
                return this.handleSoftWillInsert(info);
              })
              .onDidInsert((info: InsertValue): void => {
                this.handleSoftDidInsert(info);
              })
              .onWillDelete((info: DeleteValue): boolean => {
                return this.handleSoftWillDelete(info);
              })
              .onDidDelete((info: DeleteValue): void => {
                this.handleSoftDidDelete(info);
              })
              .onChange((v: string, previewText?: PreviewText): void => {
                this.handleChangeGuard(v, previewText);
              })
              .onSubmit((_enterKey: EnterKeyType, event: SubmitEvent): void => {
                this.sendTerminalBytes('\r', true);
                this.resetKeyboardBuffer();
                // HarmonyOS 非 TV 设备默认会在提交后失焦并收起软键盘。
                // SSH 终端需要连续输入命令, 保持隐藏输入框的编辑态。
                event.keepEditableState();
                setTimeout((): void => {
                  this.focusKeyboard(this.virtualKeyBarVisible());
                }, 30);
              })
              .onPaste((content: string): void => {
                this.handlePaste(content);
              })
              .onKeyPreIme((event: KeyEvent): boolean => {
                // 仅 KeyType.Down (=0); ArkUI KeyType 枚举: Down=0 Up=1 LongPress=2
                if (event.type !== KeyType.Down) { return false; }
                const physicalKeyboard: boolean = this.isPhysicalKeyboardEvent(event);
                const code: number = event.keyCode;
                const ctrl: boolean = event.getModifierKeyState ? event.getModifierKeyState(['Ctrl']) : false;
                const alt: boolean = event.getModifierKeyState ? event.getModifierKeyState(['Alt']) : false;
                const shift: boolean = event.getModifierKeyState ? event.getModifierKeyState(['Shift']) : false;
                // Shift+Tab is the explicit escape hatch from terminal focus.
                // Returning false lets ArkUI continue its normal application
                // focus traversal; no timer reclaims the focus afterwards.
                if (physicalKeyboard && code === KeyCode.KEYCODE_TAB && shift &&
                  !ctrl && !alt && this.terminalFocusMode) {
                  this.terminalFocusMode = false;
                  return false;
                }
                // PC 退出快捷键: Ctrl+Shift+Q
                if (this.isDesktopDevice && code === KeyCode.KEYCODE_Q && ctrl && shift) {
                  this.closeSessionAndBack();
                  return true;
                }
                const encoded: SshEncodedKey = encodePhysicalKey({
                  keyCode: code,
                  unicode: event.unicode,
                  ctrl: ctrl || this.ctrlActive,
                  alt: alt || this.altActive,
                  shift: shift || this.shiftActive,
                  capsLock: event.isCapsLockOn === true,
                  altGraph: this.isAltGraphEvent(event),
                  // Some API 23 keyboard events omit deviceId after a hot-plug
                  // or do not expose unicode at all. keySource is already a
                  // positive hardware signal, so it must enable the fallback
                  // instead of sending the same key back through the IME.
                  allowKeyCodeFallback: physicalKeyboard || this.isKnownPhysicalKeyboardEvent(event),
                  applicationCursorKeys: this.terminalApplicationCursorKeys,
                  applicationKeypad: this.terminalApplicationKeypad
                });
                if (encoded.consume) {
                  if (physicalKeyboard) {
                    try { event.stopPropagation(); } catch (_err) { /* best effort */ }
                  }
                  this.sendTerminalBytes(encoded.sequence,
                    this.isTerminalControlSequence(encoded.sequence));
                  return true;
                }
                // Unknown physical keys are likely dead-key/preedit events;
                // leave only those to the IME so CJK and composition remain
                // possible. Known printable keys are consumed above.
                return false;
              })
          }
          .width('100%')
          .height('100%')
          .position({ x: 0, y: 0 })
          .onClick(() => {
            // 点击终端显式进入终端焦点；移动端同时请求软键盘。
            this.focusKeyboard(this.virtualKeyBarVisible());
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

          // 虚拟键盘栏 — 仅手机/平板, 悬浮到系统键盘或导航栏上边缘。
          if (this.virtualKeyBarVisible()) {
            Column() {
              VirtualKeyBar({
                ctrlActive: $ctrlActive,
                altActive: $altActive,
                shiftActive: $shiftActive,
                onKey: (seq: string): void => { this.onTerminalData(seq); },
                onModifierLock: (modifier: string): void => { this.setVirtualModifier(modifier, true); },
                onModifierUnlock: (modifier: string): void => { this.setVirtualModifier(modifier, false); },
                onModifierTap: (): void => {
                  setTimeout((): void => { this.focusKeyboard(true); }, 30);
                }
              })
            }
            .width('100%')
            .height(VirtualKeyBar.TOTAL_H)
            .align(Alignment.BottomStart)
            .margin({ bottom: this.barBottomOffset() })
            .zIndex(20)
            .hitTestBehavior(HitTestMode.Default)
          }
        }
        .width('100%')
        .height('100%')
        .constraintSize({ minHeight: 0 })
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
      .width('100%')
      .layoutWeight(1)
      .constraintSize({ minHeight: 0 })
      .backgroundColor('#0D0D0D')
      .id('ssh-terminal-pane')
      if (this.showSftpPanel && this.sftpWideLayout() && !this.sftpUsesRootBindSheet()) {
        Column() {
          this.SftpTransferSheet(this.sftpPeerHostPickerMountToken)
        }
        .width('100%')
        .height('100%')
        .backgroundColor(this.sshPal().bg)
        .clip(true)
        .zIndex(100)
      }
    }
    .width('100%').height('100%')
    .bindSheet($$this.showPassphraseSheet, this.passphraseSheet(), {
      height: SheetSize.FIT_CONTENT,
      preferType: this.isDesktopDevice ? SheetType.CENTER : SheetType.BOTTOM,
      dragBar: !this.isDesktopDevice,
      backgroundColor: this.pal().sheetBg,
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
    .bindSheet($$this.showSshAuthPromptSheet, this.SshAuthPromptSheet(), {
      height: SheetSize.FIT_CONTENT,
      preferType: this.isDesktopDevice ? SheetType.CENTER : SheetType.BOTTOM,
      width: this.isDesktopDevice ? '560vp' : '100%',
      dragBar: !this.isDesktopDevice,
      backgroundColor: this.pal().sheetBg,
      blurStyle: BlurStyle.NONE,
      showClose: false,
      maskColor: 'rgba(0,0,0,0.46)',
      // System back/swipe must cancel the native broker request; dismissing
      // only the ArkUI surface would leave libssh2 waiting for credentials.
      onWillDismiss: (action: DismissSheetAction): void => {
        if (this.sshAuthPromptSubmitting) {
          this.clearSshAuthPromptState();
        } else {
          this.cancelSshAuthPrompt();
        }
        action.dismiss();
      },
      onDisappear: (): void => {
        if (this.sshAuthPrompt !== null) {
          this.cancelSshAuthPrompt();
        } else {
          this.clearSshAuthPromptState();
        }
      }
    })
    .bindSheet($$this.showSftpSheet, this.SftpTransferSheet(this.sftpPeerHostPickerMountToken), {
      // The Pad root surface is the complete SFTP workspace, not an inline
      // terminal overlay. Keep its sheet geometry explicit and wide.
      height: this.sftpRootSheetHeight(),
      preferType: this.sftpRootSheetType(),
      width: this.sftpRootSheetWidth(),
      dragBar: !this.isPadDevice,
      backgroundColor: this.pal().sheetBg,
      blurStyle: BlurStyle.NONE,
      showClose: false,
      onWillDismiss: this.sftpRootSheetDismissHandler(this.sftpRootSheetMountToken),
      onDisappear: this.sftpRootSheetDisappearHandler(this.sftpRootSheetMountToken)
    })
    .bindSheet($$this.showSshTabPicker, this.sshTabPickerSheet(), {
      height: this.breakpoint === 'sm' ? SheetSize.LARGE : SheetSize.FIT_CONTENT,
      preferType: this.breakpoint === 'sm' ? SheetType.BOTTOM : SheetType.CENTER,
      dragBar: this.breakpoint === 'sm',
      backgroundColor: '#171D25',
      blurStyle: BlurStyle.NONE,
      showClose: false
    })
  }
}
