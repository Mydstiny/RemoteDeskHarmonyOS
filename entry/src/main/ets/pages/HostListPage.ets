/**
 * HostListPage v9 — 多端响应式 + 悬浮卡片 sheet + 滑动删除 + 官方图标按钮
 */
import { router, promptAction, curves } from '@kit.ArkUI';
import { display, window } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { preferences } from '@kit.ArkData';
import { HdsTabs, HdsTabsController, hdsMaterial, DividerMode } from '@kit.UIDesignKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { abilityAccessCtrl, common, ConfigurationConstant, Want } from '@kit.AbilityKit';
import { authentication } from '@kit.AccountKit';
import { inputDevice } from '@kit.InputKit';
import { HostSyncService } from '../services/HostSyncService';
import { AuthService } from '../services/AuthService';
import { KeyVaultService } from '../services/KeyVaultService';
import { AccountKitService } from '../services/AccountKitService';
import { DataCrypto } from '../services/DataCrypto';
import { CloudStore } from '../services/CloudStore';
import { CloudSyncCoordinator } from '../services/CloudSyncCoordinator';
import { CloudSyncSelectionStore } from '../services/CloudSyncSelectionStore';
import { cloudSyncSelectableTables, effectiveCloudSyncTables } from '../services/CloudSyncSelectionPolicy';
import { LocalBackupDocument } from '../services/LocalBackupPolicy';
import { LocalBackupService } from '../services/LocalBackupService';
import { LightSensingService } from '../services/LightSensingService';
import { SshKey } from '../model/SshKey';
import {
  RemoteHost,
  LockType,
  RdpAuthMode,
  RdpRestrictedAdminSecretSource,
  normalizeRdpCredentialParts,
  normalizeRdpNtlmHash
} from '../model/RemoteHost';
import { RustDeskRelayConfig } from '../model/RustDeskRelayConfig';
import { RustDeskAccount } from '../model/RustDeskAccount';
import { RdpCredential } from '../model/RdpCredential';
import { RustDeskRelayPage } from './RustDeskRelayPage';
import { AppConfig, AppTheme, Palette, buildDark, buildLight } from '../common/Theme';
import { showLockGate, lockGateErrorMessage } from '../components/LockGate';
import { ColorPickerSheet } from '../components/ColorPickerSheet';
import { HostAddWizardSheet } from '../components/hostadd/HostAddWizardSheet';
import { RdpAddFlow } from '../components/hostadd/RdpAddFlow';
import { RustDeskAddFlow } from '../components/hostadd/RustDeskAddFlow';
import { SshAddFlow } from '../components/hostadd/SshAddFlow';
// Passphrase uses bindSheet (HostListPage is @Entry, no bindSheet limit)
import { KeyVaultPage } from './KeyVaultPage';
import { SshPreflightState } from '../components/SshPreflightSheet';
import { SshPreflightService } from '../services/SshPreflightService';
import {
  classifyRdpCertificateProbe,
  RDP_CERTIFICATE_EXPLICIT_TRUST_MODE,
  RDP_CERTIFICATE_UNKNOWN_TRUST_MODE,
  RdpCertificatePreflightDecision,
  RdpCertificateProbeView,
  RdpCertificatePreflightState,
  rdpCertificateRouteDelayMsAfterSheetClose,
  rdpCertificateWarningMessage,
  shouldRouteRdpCertificateAfterSheetDisappear,
  shouldShowRdpCertificateProbeSheetBeforeProbe,
  shouldPersistRdpCertificateTrust
} from '../services/RdpCertificatePreflightPolicy';
import { ExtensionLoader } from '../services/ExtensionLoader';
import { SshKeyImportService, SshKeyImportResult } from '../services/SshKeyImportService';
import {
  nextRdpCertificateProbeGeneration,
  shouldApplyRdpCertificateProbeResult
} from '../services/RdpCertificateProbeLifecyclePolicy';
import { RustDeskLanDiscoveryService, DiscoveredRustDeskPeer } from '../services/RustDeskLanDiscoveryService';
import {
  hostListProtocolForTab,
  searchHosts,
  visibleHostsForHostListMode
} from '../services/HostListFilterService';
import {
  displayConnectionHealth,
  filterHostsByWorkspace,
  groupIdsForHosts,
  nextWorkspaceGroupId
} from '../services/HostWorkspacePolicy';
import {
  resolveRustDeskHostEndpoint,
  rustDeskCardEndpoint,
  shouldAdoptRustDeskDirectPort,
  rustDeskAuthModeForConnection,
  normalizeRustDeskPort,
  rustDeskConnectionError,
  RUSTDESK_PEER_TCP_PORT,
  RustDeskHostEndpoint
} from '../services/RustDeskHostConfigPolicy';
import { rustDeskRelayKeyModeForFfi } from '../services/RustDeskRelayKeyPolicy';
import { sheetOpenDelayMsAfterDismiss } from '../services/SheetTransitionPolicy';
import { shouldPreserveManagedRustDeskRoute } from '../services/RustDeskProSyncPolicy';
import { resolveFabAddStyle } from '../services/FabAddStylePolicy';
import { resolveRustDeskBadges } from '../services/RustDeskCardBadgePolicy';
import { cloudSyncDetailSpec } from '../services/CloudSyncGuidancePolicy';
import {
  normalizeRemoteCursorStyle,
  shouldApplyCloudVirtualMouseStyle,
  VIRTUAL_MOUSE_STYLE_RESTORE_VERSION,
  VIRTUAL_MOUSE_STYLE_RESTORE_VERSION_KEY
} from '../services/RemoteCursorStylePolicy';
import {
  settingsLeafSheetClosedState,
  settingsLeafSheetDismissRequestedState,
  settingsLeafSheetPendingMode,
  shouldQueueSettingsLeafSheetOpen,
  shouldOpenRestoreConfirmation
} from '../services/SettingsLeafSheetLifecyclePolicy';
import {
  holdingHandStatusFromOperatingHandStatus,
  shouldAutoRequestGripPermission,
  shouldIgnoreActivityMotionForHoldingHand,
  shouldFallbackToOperatingHandOnSubscribeFailure,
  shouldMarkGripMonitorStaleAfterWatchdog,
  shouldRebindGripMonitorOnPageShow,
  shouldRunForegroundSensor,
  shouldRestartGripMonitor,
  shouldUseGripFabAlignment,
  shouldUseGripMonitor
} from '../services/GripMonitorLifecyclePolicy';
import {
  SETTINGS_SHEET_ACCOUNT,
  SETTINGS_SHEET_ACCENT_COLOR,
  SETTINGS_SHEET_FEEDBACK,
  SETTINGS_SHEET_HALO_COLOR,
  SETTINGS_SHEET_KEY_VAULT,
  SETTINGS_SHEET_NONE,
  SETTINGS_SHEET_POPUP,
  SETTINGS_SHEET_RDP_CREDENTIAL_EDITOR,
  SETTINGS_SHEET_RDP_CREDENTIALS,
  SETTINGS_SHEET_TERMINAL_FG_COLOR,
  SETTINGS_SHEET_TERMINAL_FONT_SIZE,
  SETTINGS_SHEET_WALLPAPER,
  settingsLeafSheetUsesSystemCloseButton,
  settingsLeafOpenDelayMs
} from '../services/SettingsSheetRoutePolicy';
import {
  SETTINGS_APP_BUNDLE_NAME,
  SETTINGS_BROWSER_VIEW_ACTION,
  SETTINGS_EMAIL_PANEL_TYPE,
  SETTINGS_RATING_SUBTITLE,
  SETTINGS_SECTION_ABOUT,
  SETTINGS_SECTION_APPEARANCE,
  SETTINGS_SECTION_CLOUD_SYNC,
  SETTINGS_SECTION_CONNECTION_LIVE,
  SETTINGS_SECTION_DISPLAY_INTERACTION,
  SETTINGS_SECTION_NONE,
  SETTINGS_SECTION_RDP,
  SETTINGS_SECTION_RUSTDESK,
  SETTINGS_SECTION_SECURITY,
  SETTINGS_SECTION_TUTORIAL,
  SettingsFeedbackLaunchAttempt,
  settingsFeedbackLaunchAttempts,
  settingsFeedbackMailPanelParams,
  settingsNextExpandedSection,
  settingsRatingUriCandidates,
  settingsRatingWantAction
} from '../services/SettingsAccordionPolicy';
import {
  legacyRdpPresetForResolutionId,
  normalizeRdpResolutionId,
  RemoteResolutionPreset,
  rdpResolutionLabel,
  rdpResolutionPresets
} from '../services/RemoteResolutionPresetPolicy';
import {
  localViewScalePercent,
  normalizeLocalViewScaleMode,
  REMOTE_DISPLAY_SCALE_PREFERENCE_VERSION,
  REMOTE_DISPLAY_SCALE_PREFERENCE_VERSION_KEY,
  resolveInitialRemoteDisplayScaleMode
} from '../services/RemoteCanvasTransformPolicy';
import {
  CLOUD_SYNC_SHEET_ACTIONS,
  CLOUD_SYNC_SHEET_DOWNLOADING,
  CLOUD_SYNC_SHEET_DOWNLOAD_CONFIRM,
  CLOUD_SYNC_SHEET_UNAVAILABLE,
  CLOUD_SYNC_SHEET_UPLOADING,
  CLOUD_SYNC_SHEET_MANAGE_TABLES,
  CLOUD_SYNC_SHEET_BACKUP_CONFIRM,
  CLOUD_SYNC_SHEET_DETAILS,
  CLOUD_SYNC_SHEET_RESTORE_CONFIRM,
  CLOUD_SYNC_SHEET_UPLOAD_CONFIRM,
  CloudSyncSheetSpec,
  cloudSyncSheetSpec
} from '../services/CloudSyncSheetPolicy';
import {
  HALO_COLOR_DARK_KEY,
  HALO_COLOR_LEGACY_KEY,
  HALO_COLOR_LIGHT_KEY,
  haloColorPreferenceKey,
  haloPresetsForTheme,
  resolveStoredHaloColorForTheme,
  shouldMigrateLegacyHaloColorToTheme
} from '../services/HaloColorPolicy';
import { CURRENT_RELEASE_VERSION } from '../services/ReleaseNotesRegistry';
import { AboutSettingsSheet } from '../components/AboutSettingsSheet';
import { FeedbackSettingsSheet } from '../components/FeedbackSettingsSheet';
import { RdpCertificateInfo, SshHostKeyInfo, SshPrivateKeyInfo, SshPublicKeyInstallResult } from '../types/rdpnapi';
import { SessionConfig } from '../types/rdpnapi';
import { ActiveRemoteSessionRegistry, ActiveRemoteSessionRecord } from '../services/ActiveRemoteSessionRegistry';
import { RemoteProtocol } from '../services/RemoteSessionState';
import {
  RustDeskProPreflightState,
  rustDeskProPeerIdForConnection,
  shouldOpenRustDeskProPreflight
} from '../services/RustDeskProConnectionPreflightPolicy';
import { shouldFallbackToNativeRdpConnectionAfterResolverFailure } from '../services/RdpCertificatePreflightPolicy';
import {
  nextConnectionAttemptGeneration,
  shouldBeginConnectionAttempt,
  shouldApplyConnectionAttempt
} from '../services/ConnectionAttemptPolicy';
import {
  pendingHostIdForHostAddSave,
  shouldAcceptHostAddSave,
  shouldStartHostAddConnectionAfterDisappear
} from '../services/HostAddConnectionHandoffPolicy';
import { motion } from '@kit.MultimodalAwarenessKit';
import { HostDataSource } from '../datasources/DataSources';
import { hashForLog, maskHost } from '../utils/SafeLogger';
import { util } from '@kit.ArkTS';

interface WallpaperItem { color: string; uri: string; }
interface AccountInfo { name: string; rdpCount: number; rustdeskCount: number; sshCount: number; }
interface SshKeyMaterial { privateKey: string; encryptedHint: boolean; }

const ENV_COLOR_MODE_UNKNOWN = -1;
const ENV_COLOR_MODE_LIGHT = 0;
const ENV_COLOR_MODE_DARK = 1;
const RDP_DRIVE_REDIRECTION_ENABLED = true;
const SETTINGS_ACCORDION_ANIMATION_MS = 280;
// The appearance card is taller than the original 620vp cap after the
// touchpad cursor controls are restored. Keep a stable expansion floor so an
// animation's intermediate layout height cannot collapse the card into a
// self-reinforcing narrow strip.
const APPEARANCE_EXPANDED_MIN_HEIGHT = 900;
const POPUP_SHEET_RDP_CERTIFICATES = 4;
const POPUP_SHEET_RUSTDESK_AUTH_TRUST = 5;

@Entry
@Component
struct HostListPage {
  @State hosts: RemoteHost[] = [];
  @State filteredHosts: RemoteHost[] = [];
  @State rdpCredentials: RdpCredential[] = [];
  private hostDataSource: HostDataSource = new HostDataSource();
  private hostDataSignature: string = '';
  private hostDataUnsubscribe: (() => void) | null = null;
  private skipInitialPageShowLoad: boolean = true;
  private keyVaultDataUnsubscribe: (() => void) | null = null;
  private pageActive: boolean = false;
  @State searchText: string = '';
  @State workspaceGroupId: string = '';
  @State isLoading: boolean = true;
  @StorageLink('currentTheme') @Watch('onThemeChange') theme: string = 'light';
  @StorageLink('accentColor') accentColor: string = '#007DFF';
  @State curTab: number = 0;
  @State hostCount: number = 0;
  @State lockedCount: number = 0;
  @State rdpCount: number = 0;
  @State rustdeskCount: number = 0;
  @State sshCount: number = 0;
  @State keyCount: number = 0;
  @State totpCount: number = 0;
  @State hostViewRevision: number = 0;
  @State hostPageTitle: string = '远程主机';
  @State loginRefreshKey: number = 0;
  @State accountDisplayName: string = '';
  @State accountAvatarUrl: string = '';
  @State hostSelectionMode: boolean = false;
  @State hostSelectedIds: Set<string> = new Set();
  @State hostActionPopupId: string = '';  // PC大屏模式: 当前弹出操作菜单的主机ID
  @StorageLink('followSystem') followSystem: boolean = true;
  @StorageLink('remoteDesktopBgFlag') @Watch('onRemoteDesktopBgFlagChange') appInBackground: boolean = false;
  @StorageProp('colorMode') @Watch('onSystemColorModeChange') systemUiColorMode: number = ENV_COLOR_MODE_UNKNOWN;
  @State showAddSheet: boolean = false;
  @State addSheetShowsModernPicker: boolean = false;
  @State modernAddProtocol: string = '';
  @State addSheetClosing: boolean = false;
  // Keep the released storage/cloud key while exposing the broader FAB-style semantics in UI code.
  @StorageLink('hostAddMode') fabAddStyle: string = 'modern';
  @StorageLink('virtualMouseStyle') virtualMouseStyle: string = 'circle';
  @State lanScanning: boolean = false;
  @State lanScanResults: DiscoveredRustDeskPeer[] = [];
  private lanDiscovery: RustDeskLanDiscoveryService = new RustDeskLanDiscoveryService();
  @State label: string = '';
  @State proto: string = 'rdp';
  @State hostAddr: string = '';
  @State portVal: number = 3389;
  @State rdpPortVal: number = 3389;
  @State sshPortVal: number = 22;
  @State username: string = '';
  @State chn: string = '';
  @State sheetErr: string = '';
  @State editingHostId: string = '';
  @State wallpaperIdx: number = 0;
  @State showWall: boolean = false;
  @State showColor: boolean = false;
  @State showAccount: boolean = false;
  @State showSettingsPanel: boolean = false;
  @State showSettingsLeafSheet: boolean = false;
  @State settingsLeafSheetMode: number = SETTINGS_SHEET_NONE;
  @State expandedSettingsSection: string = SETTINGS_SECTION_NONE;
  @State aboutSheetMode: number = 0; // 0=使用教程 1=关于应用 2=隐私政策 3=前置操作
  // 合并 Sheet: 单 bindSheet + mode 切换 (避免 $$ 多 bindSheet 错位)
  @State showPopupSheet: boolean = false;
  @State popupSheetMode: number = 0; // 0=crypto, 1=about(用 aboutSheetMode 子路由), 2=SSH host key, 4=RDP certificate
  @State cloudSyncStep: string = CLOUD_SYNC_SHEET_ACTIONS;
  @State cloudSyncError: string = '';
  @State cloudSyncSelectedTables: string[] = [];
  @State appearanceContentHeight: number = 0;
  private pendingLocalRestore: LocalBackupDocument | null = null;
  @State sheetPwd: string = '';
  @State sheetUseKey: boolean = false;
  @State sheetKeyPath: string = '';
  @State sheetKeyText: string = '';
  @State sheetKeyId: string = '';
  @State sheetKeyPassphrase: string = '';
  @State sheetKeyMode: number = 0; // 0=文件 1=粘贴
  // SSH 前置校验 (T-210) — @State 驱动 UI, 避免普通 class 不触发响应式更新
  @State showSshPreflight: boolean = false;
  @State sshPreflightState: number = 0;
  private sshPreflightOpenedAt: number = 0;
  @State sshPreflightHostId: string = '';
  @State sshPreflightHostLabel: string = '';
  @State sshPreflightSavedAlgorithm: string = '';
  @State sshPreflightHostKeyInfo: SshHostKeyInfo | null = null;
  @State sshPreflightError: string = '';
  @State sshPreflightPassphraseInput: string = '';
  @State sshPreflightPassphraseShowPw: boolean = false;
  @State sshPreflightPassphraseSaveToHost: boolean = false;
  @State showRdpCertificatePreflight: boolean = false;
  @State rdpCertificateState: number = RdpCertificatePreflightState.PROBING;
  private rdpCertificateOpenedAt: number = 0;
  @State rdpCertificateHostId: string = '';
  @State rdpCertificateHostLabel: string = '';
  @State rdpCertificateWarning: string = '';
  @State rdpCertificateInfo: RdpCertificateInfo | null = null;
  @State rdpCertificateError: string = '';
  @State rdpCertificateShowDetails: boolean = false;
  private rdpCertificatePendingRouteParams: Record<string, Object> | null = null;
  private rdpCertificateProbeGeneration: number = 0;
  // RDP certificate Sheet 的 native 退出动画完成前，不允许复用同一 bindSheet 宿主。
  private rdpCertificateClosing: boolean = false;
  private rdpCertificateClosingHostId: string = '';
  private rdpCertificatePendingHostId: string = '';
  private rdpCertificateAttemptGeneration: number = 0;
  private rdpCertificateClosingAttemptGeneration: number = 0;
  @State showRustDeskProPreflight: boolean = false;
  @State rustDeskProPreflightState: number = RustDeskProPreflightState.IDLE;
  @State rustDeskProPreflightHostId: string = '';
  @State rustDeskProAuthMode: string = 'password';
  @State rustDeskProPassword: string = '';
  @State rustDeskProPasswordMode: number = 0;
  @State rustDeskProPasswordVisible: boolean = false;
  @State rustDeskProRememberPassword: boolean = true;
  @State rustDeskProPreflightError: string = '';
  private rustDeskProPreflightGeneration: number = 0;
  // RustDesk preflight Sheet 退出动画完成前，不允许复用同一 bindSheet 宿主。
  private rustDeskProPreflightClosing: boolean = false;
  private rustDeskProPreflightClosingHostId: string = '';
  private rustDeskProPreflightPendingHostId: string = '';
  private rustDeskProPreflightPendingRouteParams: Record<string, Object> | null = null;
  // 保存并连接必须等新增主机 Sheet 的 native onDisappear 后再交给鉴权 Sheet。
  private pendingAddSheetConnectHostId: string = '';
  private connectionAttemptGeneration: number = 0;
  private connectionAttemptHostId: string = '';
  @StorageLink('rustdeskImageQuality') rustdeskImageQuality: number = 1; // 0=fast, 1=balanced, 2=quality
  @StorageLink('rustdeskCodec') rustdeskCodec: number = 0; // 0=auto, 1=VP8, 2=VP9, 3=AV1, 4=H264, 5=H265
  @StorageLink('rustdeskDirectIp') rustdeskDirectIp: boolean = false;
  @StorageLink('rustdeskDirectPort') rustdeskDirectPort: number = 21118;
  @StorageLink('rustdeskLanDiscovery') rustdeskLanDiscovery: boolean = true;
  @StorageLink('rustdeskPrivacyMode') rustdeskPrivacyMode: boolean = false;
  @StorageLink('rustdeskAudioEnabled') rustdeskAudioEnabled: boolean = true;
  @StorageLink('rustdeskShowDiagnostics') rustdeskShowDiagnostics: boolean = false;
  @StorageLink('rustdeskShowProDiagnostics') rustdeskShowProDiagnostics: boolean = false;
  @StorageLink('rustdeskClipboardEnabled') rustdeskClipboardEnabled: boolean = true;
  @StorageLink('rustdeskFilePasteEnabled') rustdeskFilePasteEnabled: boolean = true;
  @StorageLink('rustdeskRemoteAppTouchScaleEnabled') rustdeskRemoteAppTouchScaleEnabled: boolean = false;
  @StorageLink('rustdeskViewScaleMode') rustdeskViewScaleMode: string = 'fit';
  @StorageLink('rustdeskShowLocalCursor') rustdeskShowLocalCursor: boolean = true;
  @StorageLink('rustdeskRelativeMouseMode') rustdeskRelativeMouseMode: boolean = false;
  @StorageLink('rustdeskReverseWheel') rustdeskReverseWheel: boolean = false;
  @StorageLink('rustdeskSwapMouseButtons') rustdeskSwapMouseButtons: boolean = false;
  @StorageLink('rustdeskTouchpadSpeed') rustdeskTouchpadSpeed: number = 1.0;
  @StorageLink('rustdeskControlMode') rustdeskControlMode: number = 0; // 0=触控板, 1=直接触控, 2=键鼠
  @StorageLink('rdpDesktopPreset') rdpDesktopPreset: number = 1; // 0=自动, 1=1080p, 2=2K, 3=4K
  @StorageLink('rdpDesktopResolutionId') rdpDesktopResolutionId: string = '1920x1080';
  @StorageLink('remoteDisplayScaleMode') remoteDisplayScaleMode: string = 'fit';
  @StorageLink('remoteDisplayCustomScalePercent') remoteDisplayCustomScalePercent: number = 100;
  @StorageLink('canvasGestureZoomEnabled') canvasGestureZoomEnabled: boolean = false;
  @StorageLink('rdpColorDepth') rdpColorDepth: number = 32;
  @StorageLink('rdpAudioEnabled') rdpAudioEnabled: boolean = true;
  @StorageLink('rdpClipboardEnabled') rdpClipboardEnabled: boolean = true;
  @StorageLink('rdpDriveEnabled') rdpDriveEnabled: boolean = true;
  @StorageLink('rdpDriveName') rdpDriveName: string = 'RemoteDesktop';
  @StorageLink('rdpControlMode') rdpControlMode: number = 0; // 0=触控板, 1=直接触控, 2=键鼠
  @StorageLink('rdpAuthIdentityMode') rdpAuthIdentityMode: number = 1; // 0=MicrosoftAccount\\邮箱, 1=域+邮箱, 2=裸邮箱, 3=.\\AzureAD\\邮箱, 4=AzureAD域
  @State sheetUseProxy: boolean = false;
  @State sheetPwdMode: number = 0; // 0=一次性密码, 1=永久密码
  @State sheetRustdeskAuthMode: string = 'password'; // password | request_approval
  @State sheetRustdeskDirectEnabled: boolean = false; // per-host 直连开关
  @State sheetRustdeskDirectHost: string = '';
  @State sheetRustdeskDirectPort: number = RUSTDESK_PEER_TCP_PORT;
  @State sheetProxyHost: string = '';
  @State sheetProxyPort: number = 22;
  @State sheetProxyUser: string = '';
  @StorageLink('currentBreakpoint') @Watch('onBreakpointChange') breakpoint: string = 'sm';
  @StorageProp('isDesktopDevice') isDesktopDevice: boolean = false;
  @StorageProp('topRectHeight') topRectHeight: number = 0;
  @State windowW: number = 360;
  @State isFullScreen: boolean = false;
  @State holdingHand: motion.HoldingHandStatus = motion.HoldingHandStatus.UNKNOWN_STATUS;
  @State showKeyVaultSelect: boolean = false;
  @State keyVaultInnerTab: number = 0;
  @State kvAddTrigger: number = 0;
  @StorageLink('totpLocked') totpPageLocked: boolean = false;
  @StorageLink('haloColor') haloColor: string = '#FFFFFF';
  @StorageLink('ambientLightEffectEnabled') ambientLightEffectEnabled: boolean = false;
  // Mobile-only enhancement. Permission is requested asynchronously after the
  // host list has rendered; it is not a prerequisite for the home page.
  @StorageLink('gripAlignmentEnabled') gripAlignmentEnabled: boolean = true;
  @StorageLink('liveViewEnabled') liveViewEnabled: boolean = false;
  @StorageLink('liveViewMode') liveViewMode: number = 1; // 0=关闭, 1=AVSession, 2=后台通知
  @State ambientLightIntensity: number = 0.5;
  @State showHaloColor: boolean = false;
  @State selectedRelayId: string = '';
  @State selectedAccountId: string = '';
  @State selectedRdpCredentialId: string = '';
  @State sheetRdpAuthMode: RdpAuthMode = 'password';
  @State sheetRdpRestrictedAdminSecretSource: RdpRestrictedAdminSecretSource = 'ntlm_hash';
  // This field is write-only. Existing Restricted Admin hashes are never displayed in the editor.
  @State sheetRdpRestrictedAdminHash: string = '';
  @State sheetRdpBlankPasswordConfirmed: boolean = false;
  @StorageLink('terminalFgColor') terminalFgColor: string = '#33FF33';
  @State showTerminalFgColor: boolean = false;
  @StorageLink('terminalFontSize') terminalFontSize: number = 18;
  @State showTerminalFontSize: boolean = false;
  @State showRdpCredentialSheet: boolean = false;
  @State showRdpCredentialEditorSheet: boolean = false;
  @State rdpCredEditorKey: number = 0;
  @State rdpCredEditId: string = '';
  @State rdpCredLabel: string = '';
  @State rdpCredUsername: string = '';
  @State rdpCredPassword: string = '';
  private rdpCredentialEditorReturnToManager: boolean = false;
  @State relayAddTrigger: number = 0;
  private terminalFontSizes: number[] = [12, 13, 14, 15, 16, 17, 18, 20, 22, 24, 26, 28, 30, 32];
  private terminalColorPresets: string[] = [
    '#33FF33','#F0F0F0','#FFB000','#00FFFF',
    '#00FF00','#C0C0C0','#FF6600','#00CCFF',
    '#CCFF00','#FF4444','#FF00FF','#FFFFFF',
    '#00AA00','#E0E0E0','#FF8800','#33CCFF'
  ];
  @State haloPresets: string[] = [];
  // === 滚动收起悬浮栏 ===
  @State tabBarHidden: boolean = false;
  private lastScrollY: number = 0;
  private readonly SCROLL_THRESHOLD: number = 10;
  // === 握姿权限/状态追踪 (非UI, 用于权限检测逻辑) ===
  @State debugVisible: boolean = false;
  @State cryptoEnabled: boolean = false;   // 加密是否已设置
  @State cryptoUnlocked: boolean = false;  // DEK 是否已解锁
  // showPopupSheet → popupSheetMode=0, showPopupSheet
  @State cryptoPwd: string = '';           // 弹窗密码输入
  @State cryptoPwdConfirm: string = '';    // 弹窗确认密码 (仅设置模式)
  @State cryptoLoading: boolean = false;   // 加密操作进行中
  @State cryptoMode: number = 0;
  @State cryptoResetCountdown: number = 0;
  @State sshHostKeyBusyId: string = '';
  @State sshTrustedHostsView: RemoteHost[] = [];
  @State rdpCertificateBusyId: string = '';
  @State rdpTrustedHostsView: RemoteHost[] = [];
  @State dbgDgPerm: string = '?';
  @State dbgAmPerm: string = '?';
  @State dbgMonitor: string = '未注册';
  @State dbgHoldingHand: string = '';
  @State gripCallbackCount: number = 0;
  @State lastGripTime: string = '';
  @State lastErrorCode: string = '';
  @State lastErrorMsg: string = '';
  @State dbgTimestamp: string = '';
  private gripWatchdog: number = -1;
  private gripRestartTimer: number = -1;
  private gripWatchdogRetryCount: number = 0;
  private gripMonitorRegistered: boolean = false;
  private gripMonitorUsingOperatingFallback: boolean = false;
  @State gripPermissionGranted: boolean = false;
  private gripPermissionAttempted: boolean = false;
  private gripPermissionRequest: Promise<void> | null = null;
  private lastSheetDismissAtMs: number = 0;
  private pendingSheetOpenTimer: number = -1;
  // 添加主机 Sheet 关闭动画期间禁止重入，避免现代/经典 builder 竞态切换。
  private pendingSettingsLeafOpenTimer: number = -1;
  private pendingSettingsLeafOpenAtMs: number = 0;
  private pendingSettingsLeafSheetMode: number = SETTINGS_SHEET_NONE;
  private pendingSettingsLeafPrepare: (() => void) | null = null;
  private settingsLeafSheetCloseRequested: boolean = false;
  private settingsLeafSheetClosingMode: number = SETTINGS_SHEET_NONE;
  private settingsLeafSheetClosingPopupMode: number = 0;
  // ============================
  private srv: HostSyncService = HostSyncService.getInstance();
  private auth: AuthService = AuthService.getInstance();
  private keyVault: KeyVaultService = KeyVaultService.getInstance();
  private loader: ExtensionLoader = ExtensionLoader.getInstance();
  private sshKeyImporter: SshKeyImportService = new SshKeyImportService();
  private lightSensing: LightSensingService = LightSensingService.getInstance();
  @State showPassphraseSheet: boolean = false;
  private hlPassphraseResolve: ((v: string) => void) | null = null;
  @State hlPassphraseInput: string = '';
  @State hlPassphraseShowPw: boolean = false;
  @State showSshPublicKeyInstallSheet: boolean = false;
  @State sshPublicKeyInstallHost: RemoteHost | null = null;
  @State sshPublicKeyInstallKeyId: string = '';
  @State sshPublicKeyInstallPassword: string = '';
  @State sshPublicKeyInstallPassphrase: string = '';
  @State sshPublicKeyInstallBusy: boolean = false;
  @State sshPublicKeyInstallError: string = '';

  private promptKeyPassphrase(): Promise<string> {
    return new Promise<string>((resolve: (v: string) => void) => {
      this.hlPassphraseResolve = resolve;
      this.hlPassphraseInput = '';
      this.openSheetSafely((): void => { this.showPassphraseSheet = true; });
    });
  }

  @Builder hlPassphraseBuilder() {
    Column() {
      Text('私钥密码').fontSize(18).fontWeight(FontWeight.Bold)
        .fontColor(this.pal().text).margin({ bottom: 8 })
      Text('此私钥已加密, 请输入密码。\n留空则跳过, 连接时再输入。').fontSize(14)
        .fontColor(this.pal().text2).margin({ bottom: 16 })
      Row() {
        TextInput({ placeholder: '输入密码', text: this.hlPassphraseInput })
          .type(this.hlPassphraseShowPw ? InputType.Normal : InputType.Password)
          .height(40).backgroundColor(this.pal().surface).borderRadius(8)
          .fontColor(this.pal().text).placeholderColor(this.pal().text3)
          .layoutWeight(1).padding({ left: 12, right: 12 })
          .onChange((v: string) => { this.hlPassphraseInput = v; })
        SymbolGlyph(this.hlPassphraseShowPw ? $r('sys.symbol.eye_slash') : $r('sys.symbol.eye'))
          .fontSize(18).fontColor([this.pal().text3]).margin({ left: 8 })
          .onClick(() => { this.hlPassphraseShowPw = !this.hlPassphraseShowPw; })
      }.width('100%').margin({ bottom: 20 })
      Row() {
        Button('跳过').fontSize(14).height(38).layoutWeight(1)
          .backgroundColor(this.pal().surface).fontColor(this.pal().text2).borderRadius(8)
          .onClick(() => {
            this.showPassphraseSheet = false;
            if (this.hlPassphraseResolve) {
              this.hlPassphraseResolve('');
              this.hlPassphraseResolve = null;
            }
          })
        Button('确定').fontSize(14).height(38).layoutWeight(1)
          .backgroundColor(this.accentColor).fontColor('#FFFFFF').borderRadius(8).margin({ left: 12 })
          .onClick(() => {
            this.showPassphraseSheet = false;
            if (this.hlPassphraseResolve) {
              this.hlPassphraseResolve(this.hlPassphraseInput);
              this.hlPassphraseResolve = null;
            }
          })
      }.width('100%')
    }.padding(20)
  }
  private tabsCtrl: HdsTabsController = new HdsTabsController();
  private searchTimer: number = -1;
  private presetColors: string[] = ['#FFFFFF','#F0F0F0','#F0F5FA','#FFF8F0','#F5F0F8','#1A1A2E','#1E4377','#2D1B4E'];
  @State wallpaperItems: WallpaperItem[] = [];
  private inputDeviceListenerRegistered: boolean = false;
  private inputDevicePromptVisible: boolean = false;
  private externalInputPromptedThisSession: boolean = false;
  private inputDeviceBaselineIds: Array<number> = [];
  private inputDeviceListener: Callback<inputDevice.DeviceListener> =
    (data: inputDevice.DeviceListener): void => {
      if (data.type !== 'add') { return; }
      this.handleInputDeviceAdded(data.deviceId);
    };
  private lightChangeListener: (lux: number) => void = (_lux: number): void => {
    this.ambientLightIntensity = this.lightSensing.getLightIntensity();
  };

  private onRemoteDesktopBgFlagChange(): void {
    if (this.appInBackground) {
      this.pauseForegroundSensors('ability-background');
    } else {
      this.resumeForegroundSensors('ability-foreground');
    }
  }

  private pauseForegroundSensors(source: string): void {
    this.stopGripMonitor(true);
    this.lightSensing.offLightChange(this.lightChangeListener);
    this.lightSensing.stopMonitoring();
    hilog.info(0x0000, 'HostListPage', 'foreground sensors paused source=' + source);
  }

  private resumeForegroundSensors(source: string): void {
    if (!this.pageActive || this.appInBackground) {
      return;
    }
    this.syncAmbientLightMonitor();
    this.ensureGripMonitorOnPageShow();
    hilog.info(0x0000, 'HostListPage', 'foreground sensors resumed source=' + source);
  }

  /** 断点切换: 重置跨模式状态, 防止 xl↔非xl 切换残留 */
  private onBreakpointChange(): void {
    // 清理弹窗/多选状态
    this.hostActionPopupId = '';
    if (this.showAddSheet) {
      this.requestAddSheetClose();
    } else {
      this.showAddSheet = false;
    }
    this.showSettingsPanel = false;
    this.showSettingsLeafSheet = false;
    this.settingsLeafSheetMode = SETTINGS_SHEET_NONE;
    this.closeLegacySettingsSheetFlags();
    if (this.hostSelectionMode) {
      this.hostSelectionMode = false;
      this.hostSelectedIds = new Set();
    }
    // xl→非xl: curTab 越界修正 + 标题重置
    if (this.breakpoint !== 'xl') {
      if (this.curTab > 3) { this.curTab = 0; }
      this.hostPageTitle = '远程主机';
      this.updateHostFilter(); // 非xl显示全部主机
    } else {
      // 非xl→xl: 标题跟随当前 tab
      const titles: string[] = ['RDP 远程主机', 'RustDesk 远程主机', 'SSH 终端', '', '', '中继服务器'];
      this.hostPageTitle = titles[this.curTab] || '';
      this.updateHostFilter();
    }
  }

  async aboutToAppear(): Promise<void> {
    this.pageActive = true;
    this.registerDataRefreshListeners();
    this.ensureEnvironmentColorMode();
    const items: WallpaperItem[] = [];
    for (let i = 0; i < this.presetColors.length; i++) {
      const item: WallpaperItem = {} as WallpaperItem;
      item.color = this.presetColors[i]; item.uri = ''; items.push(item);
    }
    this.wallpaperItems = items;
    this.syncWallpaperColor();
    this.updateWindowMetrics();
    this.refreshHaloPresets();
    // 恢复 TOTP 隐私保护状态 (Preferences 持久化)
    try {
      const prefs = preferences.getPreferencesSync(getContext(this), { name: 'RemoteDesktopAppPrefs' });
      // 核心外观设置
      const savedTheme: string = prefs.getSync('currentTheme', '') as string;
      const savedAccent: string = prefs.getSync('accentColor', '') as string;
      const savedFollowSystem: boolean = prefs.getSync('followSystem', true) as boolean;
      const savedAmbientLightEffect: boolean = prefs.getSync('ambientLightEffectEnabled', false) as boolean;
      const savedLiveViewEnabled: boolean = prefs.getSync('liveViewEnabled', true) as boolean;
      const savedLiveViewMode: number = prefs.getSync('liveViewMode', 1) as number;
      const savedHostAddMode: string = prefs.getSync('hostAddMode', 'modern') as string;
      const savedVirtualMouseStyle: string = prefs.getSync('virtualMouseStyle', 'circle') as string;
      const savedWallpaper: string = prefs.getSync('wallpaperColor', '') as string;
      // 终端设置
      const savedTermFg: string = prefs.getSync('terminalFgColor', '') as string;
      const savedTermFontSize: number = prefs.getSync('terminalFontSize', 0) as number;
      const savedUseNativeCore: boolean = prefs.getSync('useNativeTerminalCore', true) as boolean;
      if (!savedFollowSystem && savedTheme !== '') {
        AppStorage.setOrCreate('currentTheme', savedTheme);
        this.theme = savedTheme;
        this.setApplicationColorModeForTheme(savedTheme, 'appear-manual');
      }
      if (savedAccent !== '') { AppStorage.setOrCreate('accentColor', savedAccent); }
      AppStorage.setOrCreate('followSystem', savedFollowSystem);
      this.followSystem = savedFollowSystem;
      if (savedFollowSystem) {
        this.syncFollowSystemTheme('appear');
      }
      this.syncHaloColorForCurrentTheme();
      this.ambientLightEffectEnabled = savedAmbientLightEffect;
      AppStorage.setOrCreate('ambientLightEffectEnabled', this.ambientLightEffectEnabled);
      // 1.0.8: mobile devices always use the grip alignment enhancement. The
      // preference key remains only as a compatibility marker for older data;
      // it is no longer a user-facing switch and never gates first paint.
      this.gripAlignmentEnabled = !this.isDesktopDevice;
      prefs.putSync('gripAlignmentEnabled', this.gripAlignmentEnabled);
      prefs.putSync('gripAlignmentPreferenceVersion', 2);
      AppStorage.setOrCreate('gripAlignmentEnabled', this.gripAlignmentEnabled);
      this.liveViewEnabled = savedLiveViewEnabled;
      AppStorage.setOrCreate('liveViewEnabled', this.liveViewEnabled);
      this.liveViewMode = savedLiveViewMode >= 0 && savedLiveViewMode <= 2 ? savedLiveViewMode : 1;
      AppStorage.setOrCreate('liveViewMode', this.liveViewMode);
      this.fabAddStyle = savedHostAddMode === 'classic' ? 'classic' : 'modern';
      AppStorage.setOrCreate('hostAddMode', this.fabAddStyle);
      this.virtualMouseStyle = normalizeRemoteCursorStyle(savedVirtualMouseStyle);
      AppStorage.setOrCreate('virtualMouseStyle', this.virtualMouseStyle);
      if (savedWallpaper !== '') { AppStorage.setOrCreate('wallpaperColor', savedWallpaper); }
      const savedWallIdx: number = prefs.getSync('wallpaperIdx', -1) as number;
      if (savedWallIdx >= 0 && savedWallIdx < this.wallpaperItems.length) {
        this.wallpaperIdx = savedWallIdx;
      }
      if (savedTermFg !== '') { AppStorage.setOrCreate('terminalFgColor', savedTermFg); }
      if (savedTermFontSize >= 12 && savedTermFontSize <= 32) {
        AppStorage.setOrCreate('terminalFontSize', savedTermFontSize);
      }
      AppStorage.setOrCreate('useNativeTerminalCore', savedUseNativeCore);
      // RustDesk / RDP 设置
      const savedLock: boolean = prefs.getSync('totpLocked', false) as boolean;
      const savedQuality: number = prefs.getSync('rustdeskImageQuality', 1) as number;
      const savedCodec: number = prefs.getSync('rustdeskCodec', 0) as number;
      const savedDirectIp: boolean = prefs.getSync('rustdeskDirectIp', false) as boolean;
      const savedDirectPort: number = prefs.getSync('rustdeskDirectPort', 21118) as number;
      const savedLanDiscovery: boolean = prefs.getSync('rustdeskLanDiscovery', true) as boolean;
      const savedPrivacyMode: boolean = prefs.getSync('rustdeskPrivacyMode', false) as boolean;
      const savedAudioEnabled: boolean = prefs.getSync('rustdeskAudioEnabled', true) as boolean;
      const savedShowDiagnostics: boolean = prefs.getSync('rustdeskShowDiagnostics', false) as boolean;
      const savedShowProDiagnostics: boolean = prefs.getSync('rustdeskShowProDiagnostics', false) as boolean;
      const savedRustDeskClipboardEnabled: boolean = prefs.getSync('rustdeskClipboardEnabled', true) as boolean;
      const savedRustDeskFilePasteEnabled: boolean = prefs.getSync('rustdeskFilePasteEnabled', true) as boolean;
      const savedRustDeskRemoteAppTouchScaleEnabled: boolean =
        prefs.getSync('rustdeskRemoteAppTouchScaleEnabled', false) as boolean;
      const savedRustDeskViewScaleMode: string = prefs.getSync('rustdeskViewScaleMode', 'fit') as string;
      const savedRustDeskShowLocalCursor: boolean = prefs.getSync('rustdeskShowLocalCursor', true) as boolean;
      const savedRustDeskRelativeMouseMode: boolean = prefs.getSync('rustdeskRelativeMouseMode', false) as boolean;
      const savedRustDeskReverseWheel: boolean = prefs.getSync('rustdeskReverseWheel', false) as boolean;
      const savedRustDeskSwapMouseButtons: boolean = prefs.getSync('rustdeskSwapMouseButtons', false) as boolean;
      const savedRustDeskTouchpadSpeed: number = prefs.getSync('rustdeskTouchpadSpeed', 1.0) as number;
      const savedControlMode: number = prefs.getSync('rustdeskControlMode', 0) as number;
      const savedRdpDesktopPreset: number = prefs.getSync('rdpDesktopPreset', 1) as number;
      const savedRdpDesktopResolutionId: string = prefs.getSync('rdpDesktopResolutionId', '') as string;
      const savedRemoteDisplayScaleMode: string = prefs.getSync('remoteDisplayScaleMode', '') as string;
      const remoteDisplayScalePreferenceVersion: number =
        prefs.getSync(REMOTE_DISPLAY_SCALE_PREFERENCE_VERSION_KEY, 0) as number;
      const savedRemoteDisplayCustomScalePercent: number =
        prefs.getSync('remoteDisplayCustomScalePercent', 100) as number;
      const canvasGestureZoomDefaultVersion: number =
        prefs.getSync('canvasGestureZoomDefaultVersion', 0) as number;
      let savedCanvasGestureZoomEnabled: boolean =
        prefs.getSync('canvasGestureZoomEnabled', !this.isDesktopDevice) as boolean;
      const savedRdpColorDepth: number = prefs.getSync('rdpColorDepth', 32) as number;
      const savedRdpAudioEnabled: boolean = prefs.getSync('rdpAudioEnabled', true) as boolean;
      const savedRdpClipboardEnabled: boolean = prefs.getSync('rdpClipboardEnabled', true) as boolean;
      const rdpDriveDefaultVersion: number = prefs.getSync('rdpDriveDefaultVersion', 0) as number;
      let savedRdpDriveEnabled: boolean = prefs.getSync('rdpDriveEnabled', true) as boolean;
      if (rdpDriveDefaultVersion < 3) {
        savedRdpDriveEnabled = true;
        prefs.putSync('rdpDriveEnabled', true);
        prefs.putSync('rdpDriveDefaultVersion', 3);
        prefs.flush();
      }
      const savedRdpDriveName: string = prefs.getSync('rdpDriveName', 'RemoteDesktop') as string;
      const savedRdpControlMode: number = prefs.getSync('rdpControlMode', 0) as number;
      const rdpAuthIdentityModeDefaultVersion: number =
        prefs.getSync('rdpAuthIdentityModeDefaultVersion', 0) as number;
      let savedRdpAuthIdentityMode: number = prefs.getSync('rdpAuthIdentityMode', 1) as number;
      if (rdpAuthIdentityModeDefaultVersion < 1) {
        if (savedRdpAuthIdentityMode === 0) {
          savedRdpAuthIdentityMode = 1;
          prefs.putSync('rdpAuthIdentityMode', 1);
        }
        prefs.putSync('rdpAuthIdentityModeDefaultVersion', 1);
        prefs.flush();
      }
      this.totpPageLocked = savedLock;
      this.rustdeskImageQuality = savedQuality >= 0 && savedQuality <= 2 ? savedQuality : 1;
      this.rustdeskCodec = savedCodec >= 0 && savedCodec <= 5 ? savedCodec : 0;
      this.rustdeskDirectIp = savedDirectIp;
      this.rustdeskDirectPort = savedDirectPort > 0 ? savedDirectPort : 21118;
      this.rustdeskLanDiscovery = savedLanDiscovery;
      this.rustdeskPrivacyMode = savedPrivacyMode;
      this.rustdeskAudioEnabled = savedAudioEnabled;
      this.rustdeskShowDiagnostics = savedShowDiagnostics;
      this.rustdeskShowProDiagnostics = savedShowProDiagnostics;
      this.rustdeskClipboardEnabled = savedRustDeskClipboardEnabled;
      this.rustdeskFilePasteEnabled = savedRustDeskFilePasteEnabled;
      this.rustdeskRemoteAppTouchScaleEnabled = savedRustDeskRemoteAppTouchScaleEnabled;
      this.rustdeskViewScaleMode =
        savedRustDeskViewScaleMode === 'original' || savedRustDeskViewScaleMode === 'custom' ?
          savedRustDeskViewScaleMode : 'fit';
      this.rustdeskShowLocalCursor = savedRustDeskShowLocalCursor;
      this.rustdeskRelativeMouseMode = savedRustDeskRelativeMouseMode;
      this.rustdeskReverseWheel = savedRustDeskReverseWheel;
      this.rustdeskSwapMouseButtons = savedRustDeskSwapMouseButtons;
      this.rustdeskTouchpadSpeed =
        Math.max(0.4, Math.min(2.2, savedRustDeskTouchpadSpeed > 0 ? savedRustDeskTouchpadSpeed : 1.0));
      this.rustdeskControlMode = this.clampRustDeskControlMode(savedControlMode);
      this.rdpDesktopPreset = savedRdpDesktopPreset >= 0 && savedRdpDesktopPreset <= 3 ? savedRdpDesktopPreset : 1;
      this.rdpDesktopResolutionId = normalizeRdpResolutionId(savedRdpDesktopResolutionId, this.rdpDesktopPreset);
      this.rdpDesktopPreset = legacyRdpPresetForResolutionId(this.rdpDesktopResolutionId);
      this.remoteDisplayScaleMode = resolveInitialRemoteDisplayScaleMode(savedRemoteDisplayScaleMode,
        remoteDisplayScalePreferenceVersion);
      this.remoteDisplayCustomScalePercent = Math.max(50, Math.min(300,
        Number.isFinite(savedRemoteDisplayCustomScalePercent) ? savedRemoteDisplayCustomScalePercent : 100));
      if (canvasGestureZoomDefaultVersion < 1) {
        savedCanvasGestureZoomEnabled = !this.isDesktopDevice;
        prefs.putSync('canvasGestureZoomEnabled', savedCanvasGestureZoomEnabled);
        prefs.putSync('canvasGestureZoomDefaultVersion', 1);
      }
      this.canvasGestureZoomEnabled = savedCanvasGestureZoomEnabled;
      prefs.putSync('rdpDesktopResolutionId', this.rdpDesktopResolutionId);
      prefs.putSync('remoteDisplayScaleMode', this.remoteDisplayScaleMode);
      prefs.putSync(REMOTE_DISPLAY_SCALE_PREFERENCE_VERSION_KEY,
        REMOTE_DISPLAY_SCALE_PREFERENCE_VERSION);
      prefs.putSync('remoteDisplayCustomScalePercent', this.remoteDisplayCustomScalePercent);
      prefs.flush();
      this.rdpColorDepth = savedRdpColorDepth === 16 || savedRdpColorDepth === 24 ? savedRdpColorDepth : 32;
      this.rdpAudioEnabled = savedRdpAudioEnabled;
      this.rdpClipboardEnabled = savedRdpClipboardEnabled;
      this.rdpDriveEnabled = savedRdpDriveEnabled;
      this.rdpDriveName = this.normalizeRdpDriveName(savedRdpDriveName);
      this.rdpControlMode = this.clampRdpControlMode(savedRdpControlMode);
      this.rdpAuthIdentityMode = this.clampRdpAuthIdentityMode(savedRdpAuthIdentityMode);
      AppStorage.setOrCreate('totpLocked', savedLock);
      AppStorage.setOrCreate('rustdeskImageQuality', this.rustdeskImageQuality);
      AppStorage.setOrCreate('rustdeskCodec', this.rustdeskCodec);
      AppStorage.setOrCreate('rustdeskDirectIp', this.rustdeskDirectIp);
      AppStorage.setOrCreate('rustdeskDirectPort', this.rustdeskDirectPort);
      AppStorage.setOrCreate('rustdeskLanDiscovery', this.rustdeskLanDiscovery);
      AppStorage.setOrCreate('rustdeskPrivacyMode', this.rustdeskPrivacyMode);
      AppStorage.setOrCreate('rustdeskAudioEnabled', this.rustdeskAudioEnabled);
      AppStorage.setOrCreate('rustdeskShowDiagnostics', this.rustdeskShowDiagnostics);
      AppStorage.setOrCreate('rustdeskShowProDiagnostics', this.rustdeskShowProDiagnostics);
      AppStorage.setOrCreate('rustdeskClipboardEnabled', this.rustdeskClipboardEnabled);
      AppStorage.setOrCreate('rustdeskFilePasteEnabled', this.rustdeskFilePasteEnabled);
      AppStorage.setOrCreate('rustdeskRemoteAppTouchScaleEnabled', this.rustdeskRemoteAppTouchScaleEnabled);
      AppStorage.setOrCreate('rustdeskViewScaleMode', this.rustdeskViewScaleMode);
      AppStorage.setOrCreate('rustdeskShowLocalCursor', this.rustdeskShowLocalCursor);
      AppStorage.setOrCreate('rustdeskRelativeMouseMode', this.rustdeskRelativeMouseMode);
      AppStorage.setOrCreate('rustdeskReverseWheel', this.rustdeskReverseWheel);
      AppStorage.setOrCreate('rustdeskSwapMouseButtons', this.rustdeskSwapMouseButtons);
      AppStorage.setOrCreate('rustdeskTouchpadSpeed', this.rustdeskTouchpadSpeed);
      AppStorage.setOrCreate('rustdeskControlMode', this.rustdeskControlMode);
      AppStorage.setOrCreate('rdpDesktopPreset', this.rdpDesktopPreset);
      AppStorage.setOrCreate('rdpDesktopResolutionId', this.rdpDesktopResolutionId);
      AppStorage.setOrCreate('remoteDisplayScaleMode', this.remoteDisplayScaleMode);
      AppStorage.setOrCreate('remoteDisplayCustomScalePercent', this.remoteDisplayCustomScalePercent);
      AppStorage.setOrCreate('canvasGestureZoomEnabled', this.canvasGestureZoomEnabled);
      AppStorage.setOrCreate('rdpColorDepth', this.rdpColorDepth);
      AppStorage.setOrCreate('rdpAudioEnabled', this.rdpAudioEnabled);
      AppStorage.setOrCreate('rdpClipboardEnabled', this.rdpClipboardEnabled);
      AppStorage.setOrCreate('rdpDriveEnabled', this.rdpDriveEnabled);
      AppStorage.setOrCreate('rdpDriveName', this.rdpDriveName);
      AppStorage.setOrCreate('rdpControlMode', this.rdpControlMode);
      AppStorage.setOrCreate('rdpAuthIdentityMode', this.rdpAuthIdentityMode);
    } catch (_err) { /* ignore */ }
    // The home page is a core path.  Loading it must not await an optional
    // permission dialog or sensor service.
    await this.load();
    this.migrateVirtualMouseStyleCloudSetting();
    this.loadAfterServiceReady();
    this.applyDesktopRdpInputMode();
    this.applyDesktopRustDeskInputMode();
    this.registerInputDeviceWatcher();
    this.syncAmbientLightMonitor();
    this.ensureGripMonitorOnPageShow();
  }

  onPageShow(): void {
    this.pageActive = true;
    CloudSyncCoordinator.getInstance().flushDeferredAutomaticPushes();
    this.migrateVirtualMouseStyleCloudSetting();
    this.updateWindowMetrics();
    if (this.skipInitialPageShowLoad) {
      this.skipInitialPageShowLoad = false;
    } else {
      if (this.followSystem) {
        this.syncFollowSystemTheme('page-show');
      } else {
        this.reapplyManualTheme('page-show');
      }
      this.load();
    }
    this.refreshCryptoStatus();
    this.applyDesktopRdpInputMode();
    this.applyDesktopRustDeskInputMode();
    this.syncAmbientLightMonitor();
    this.ensureGripMonitorOnPageShow();
  }

  private openSheetSafely(openAction: () => void, allowDuringConnectionAttempt: boolean = false): void {
    if (this.addSheetClosing || this.rustDeskProPreflightClosing ||
      (this.connectionAttemptHostId !== '' && !allowDuringConnectionAttempt)) {
      return;
    }
    if (this.pendingSheetOpenTimer !== -1) {
      clearTimeout(this.pendingSheetOpenTimer);
      this.pendingSheetOpenTimer = -1;
    }
    const delayMs: number = sheetOpenDelayMsAfterDismiss(Date.now(), this.lastSheetDismissAtMs);
    if (delayMs <= 0) {
      openAction();
      return;
    }
    this.pendingSheetOpenTimer = setTimeout((): void => {
      this.pendingSheetOpenTimer = -1;
      if (this.addSheetClosing || this.rustDeskProPreflightClosing ||
        (this.connectionAttemptHostId !== '' && !allowDuringConnectionAttempt)) {
        return;
      }
      openAction();
    }, delayMs);
  }

  private saveHostFromAddFlow(host: RemoteHost, connectNow: boolean, restrictedAdminHash: string = ''): void {
    if (!shouldAcceptHostAddSave(this.addSheetClosing, this.pendingAddSheetConnectHostId)) {
      hilog.info(0x0001, 'HostList', 'ignored repeated add-host save while Sheet is closing');
      return;
    }
    const requiresLocalRestrictedAdminHash: boolean = host.protocol === 'rdp' &&
      host.rdpAuthMode === 'restricted_admin' &&
      host.rdpRestrictedAdminSecretSource === 'ntlm_hash';
    if (requiresLocalRestrictedAdminHash &&
      !CloudStore.getInstance().saveRdpRestrictedAdminHash(host, restrictedAdminHash)) {
      promptAction.showToast({ message: '无法加密保存 NTLM Hash，请先解锁本地凭据存储后重试', duration: 2600 });
      return;
    }
    if (!this.srv.addHost(host)) {
      if (requiresLocalRestrictedAdminHash) {
        CloudStore.getInstance().clearRdpRestrictedAdminHash(host.id);
      }
      promptAction.showToast({ message: '保存主机失败，请稍后重试', duration: 1800 });
      return;
    }
    this.pendingAddSheetConnectHostId = pendingHostIdForHostAddSave(connectNow, host.id);
    this.requestAddSheetClose();
  }

  private handleAddSheetDisappear(): void {
    this.noteSheetDismissed();
    this.addSheetClosing = false;
    this.addSheetShowsModernPicker = false;
    this.modernAddProtocol = '';
    const pendingHostId: string = this.pendingAddSheetConnectHostId;
    this.pendingAddSheetConnectHostId = '';
    this.resetForm();

    if (!shouldStartHostAddConnectionAfterDisappear(
      this.pageActive, this.addSheetClosing, pendingHostId)) {
      if (pendingHostId !== '') {
        this.releaseConnectionAttempt(pendingHostId);
      }
      return;
    }
    const host: RemoteHost | undefined = this.srv.getHost(pendingHostId);
    if (!host) {
      hilog.warn(0x0001, 'HostList', 'saved host disappeared before connect id=' + pendingHostId);
      this.releaseConnectionAttempt(pendingHostId);
      return;
    }
    // 只保存稳定 ID，交接时重新读取，确保直连地址、端口、密码和密码类型
    // 都来自刚刚持久化的主机记录，而不是 Sheet 回调中的旧对象副本。
    hilog.info(0x0001, 'HostList', 'add-host Sheet disappeared; starting saved connection host=' + pendingHostId);
    this.handleHostCardClick(host);
  }

  private requestAddSheetClose(): void {
    if (this.pendingSheetOpenTimer !== -1) {
      clearTimeout(this.pendingSheetOpenTimer);
      this.pendingSheetOpenTimer = -1;
    }
    this.addSheetClosing = true;
    this.showAddSheet = false;
  }

  private noteSheetDismissed(): void {
    this.lastSheetDismissAtMs = Date.now();
  }

  private closeLegacySettingsSheetFlags(): void {
    this.showAccount = false;
    this.showColor = false;
    this.showWall = false;
    this.showHaloColor = false;
    this.showTerminalFgColor = false;
    this.showTerminalFontSize = false;
    this.showPopupSheet = false;
    this.showRdpCredentialSheet = false;
    this.showRdpCredentialEditorSheet = false;
    this.showKeyVaultSelect = false;
  }

  private clearPendingSettingsLeafOpen(clearRequest: boolean = true): void {
    if (this.pendingSettingsLeafOpenTimer !== -1) {
      clearTimeout(this.pendingSettingsLeafOpenTimer);
      this.pendingSettingsLeafOpenTimer = -1;
    }
    if (clearRequest) {
      this.pendingSettingsLeafOpenAtMs = 0;
      this.pendingSettingsLeafSheetMode = SETTINGS_SHEET_NONE;
      this.pendingSettingsLeafPrepare = null;
    }
  }

  private applySettingsLeafSheetOpen(mode: number, prepareAction: (() => void) | null): void {
    if (prepareAction !== null) {
      prepareAction();
    }
    this.closeLegacySettingsSheetFlags();
    this.settingsLeafSheetMode = mode;
    this.showSettingsLeafSheet = true;
  }

  private scheduleSettingsLeafSheetOpen(mode: number, prepareAction: (() => void) | null,
    delayMs: number): void {
    const nowMs: number = Date.now();
    const requestedOpenAtMs: number = nowMs + (delayMs > 0 ? delayMs : 0);
    const openAtMs: number = this.pendingSettingsLeafOpenAtMs > requestedOpenAtMs
      ? this.pendingSettingsLeafOpenAtMs
      : requestedOpenAtMs;
    this.clearPendingSettingsLeafOpen(false);
    this.pendingSettingsLeafOpenAtMs = openAtMs;
    this.pendingSettingsLeafSheetMode = settingsLeafSheetPendingMode(
      this.pendingSettingsLeafSheetMode, mode);
    this.pendingSettingsLeafPrepare = prepareAction;
    this.pendingSettingsLeafOpenTimer = setTimeout((): void => {
      this.pendingSettingsLeafOpenTimer = -1;
      this.pendingSettingsLeafOpenAtMs = 0;
      if (this.settingsLeafSheetCloseRequested || this.showSettingsLeafSheet) {
        return;
      }
      const remainingDelayMs: number = sheetOpenDelayMsAfterDismiss(Date.now(), this.lastSheetDismissAtMs);
      if (remainingDelayMs > 0) {
        this.scheduleSettingsLeafSheetOpen(this.pendingSettingsLeafSheetMode,
          this.pendingSettingsLeafPrepare, remainingDelayMs);
        return;
      }
      const pendingMode: number = this.pendingSettingsLeafSheetMode;
      const pendingPrepare: (() => void) | null = this.pendingSettingsLeafPrepare;
      this.pendingSettingsLeafSheetMode = SETTINGS_SHEET_NONE;
      this.pendingSettingsLeafPrepare = null;
      if (pendingMode !== SETTINGS_SHEET_NONE && this.pageActive) {
        this.applySettingsLeafSheetOpen(pendingMode, pendingPrepare);
      }
    }, openAtMs - nowMs);
  }

  private requestSettingsLeafSheetReplacement(mode: number, prepareAction: (() => void) | null): void {
    this.pendingSettingsLeafSheetMode = mode;
    this.pendingSettingsLeafPrepare = prepareAction;
    this.settingsLeafSheetCloseRequested = true;
    this.settingsLeafSheetClosingMode = this.settingsLeafSheetMode;
    this.settingsLeafSheetClosingPopupMode = this.popupSheetMode;
    this.lastSheetDismissAtMs = Date.now();
    const next = settingsLeafSheetDismissRequestedState(this.settingsLeafSheetMode);
    this.showSettingsLeafSheet = next.visible;
    this.scheduleSettingsLeafSheetOpen(mode, prepareAction,
      sheetOpenDelayMsAfterDismiss(Date.now(), this.lastSheetDismissAtMs));
  }

  private openSettingsLeafSheet(mode: number, prepareAction: (() => void) | null = null): void {
    if (shouldQueueSettingsLeafSheetOpen(this.showSettingsLeafSheet,
      this.settingsLeafSheetCloseRequested)) {
      if (this.showSettingsLeafSheet) {
        this.requestSettingsLeafSheetReplacement(mode, prepareAction);
        return;
      }
      const delayMs: number = sheetOpenDelayMsAfterDismiss(Date.now(), this.lastSheetDismissAtMs);
      this.scheduleSettingsLeafSheetOpen(mode, prepareAction, delayMs);
      return;
    }
    const panelWasOpen: boolean = this.showSettingsPanel;
    if (panelWasOpen) {
      this.lastSheetDismissAtMs = Date.now();
      this.showSettingsPanel = false;
    }
    const panelDelayMs: number = settingsLeafOpenDelayMs(panelWasOpen);
    const transitionDelayMs: number = sheetOpenDelayMsAfterDismiss(Date.now(), this.lastSheetDismissAtMs);
    const delayMs: number = panelDelayMs > transitionDelayMs ? panelDelayMs : transitionDelayMs;
    if (delayMs <= 0) {
      this.applySettingsLeafSheetOpen(mode, prepareAction);
      return;
    }
    this.scheduleSettingsLeafSheetOpen(mode, prepareAction, delayMs);
  }

  private closeSettingsLeafSheet(): void {
    const sheetWasVisible: boolean = this.showSettingsLeafSheet;
    this.clearPendingSettingsLeafOpen();
    if (sheetWasVisible) {
      this.settingsLeafSheetCloseRequested = true;
      this.settingsLeafSheetClosingMode = this.settingsLeafSheetMode;
      this.settingsLeafSheetClosingPopupMode = this.popupSheetMode;
      const next = settingsLeafSheetDismissRequestedState(this.settingsLeafSheetMode);
      if (next.cancelPendingOpen && this.pendingSheetOpenTimer !== -1) {
        clearTimeout(this.pendingSheetOpenTimer);
        this.pendingSheetOpenTimer = -1;
      }
      this.closeLegacySettingsSheetFlags();
      this.lastSheetDismissAtMs = Date.now();
      // Keep the current mode mounted until onDisappear. Resetting it here
      // swaps the builder to an empty Column before ArkUI can play the exit
      // transition, which makes button-driven dismissals look instantaneous.
      this.showSettingsLeafSheet = next.visible;
      return;
    }
    this.closeLegacySettingsSheetFlags();
    this.resetSettingsLeafSheetAfterDismiss();
  }

  private resetSettingsLeafSheetAfterDismiss(): void {
    const next = settingsLeafSheetClosedState();
    if (next.cancelPendingOpen && this.pendingSheetOpenTimer !== -1) {
      clearTimeout(this.pendingSheetOpenTimer);
      this.pendingSheetOpenTimer = -1;
    }
    this.showSettingsLeafSheet = next.visible;
    this.settingsLeafSheetMode = next.mode;
    this.noteSheetDismissed();
  }

  private handleSettingsLeafSheetDisappear(): void {
    const wasProgrammaticClose: boolean = this.settingsLeafSheetCloseRequested;
    const dismissedMode: number = wasProgrammaticClose
      ? this.settingsLeafSheetClosingMode
      : this.settingsLeafSheetMode;
    const dismissedPopupMode: number = wasProgrammaticClose
      ? this.settingsLeafSheetClosingPopupMode
      : this.popupSheetMode;
    this.settingsLeafSheetCloseRequested = false;
    this.settingsLeafSheetClosingMode = SETTINGS_SHEET_NONE;
    this.settingsLeafSheetClosingPopupMode = 0;
    // Both system (outside/drag/close button) and programmatic dismissals
    // finish here. Cleanup is deliberately delayed until after the native
    // Sheet transition has completed so the outgoing builder remains visible.
    this.closeLegacySettingsSheetFlags();
    this.resetSettingsLeafSheetAfterDismiss();
    if (this.pendingSettingsLeafSheetMode !== SETTINGS_SHEET_NONE) {
      this.scheduleSettingsLeafSheetOpen(this.pendingSettingsLeafSheetMode,
        this.pendingSettingsLeafPrepare,
        sheetOpenDelayMsAfterDismiss(Date.now(), this.lastSheetDismissAtMs));
    }
    if (dismissedMode === SETTINGS_SHEET_POPUP && dismissedPopupMode === 0) {
      this.refreshCryptoStatus();
    }
  }

  /**
   * Open every cloud sheet state atomically with the leaf Sheet transition.
   * The transition may be delayed while a previous Sheet is dismissing, so
   * callers must not assign cloudSyncStep after this method returns.
   */
  private openCloudSyncSheet(initialStep: string = ''): void {
    this.openSettingsLeafSheet(SETTINGS_SHEET_POPUP, (): void => {
      this.cloudSyncSelectedTables = CloudSyncSelectionStore.getInstance().selectedBusinessTables();
      this.cloudSyncError = '';
      this.cloudSyncStep = initialStep !== '' ? initialStep :
        (!CloudStore.getInstance().requiresCloudServiceGuidance()
          ? CLOUD_SYNC_SHEET_ACTIONS
          : CLOUD_SYNC_SHEET_UNAVAILABLE);
      this.popupSheetMode = 3;
    });
  }

  private openCloudSyncDetailsSheet(): void {
    this.openSettingsLeafSheet(SETTINGS_SHEET_POPUP, (): void => {
      this.cloudSyncError = '';
      this.cloudSyncStep = CLOUD_SYNC_SHEET_DETAILS;
      this.popupSheetMode = 3;
    });
  }

  private returnToCloudSyncActions(): void {
    this.cloudSyncError = '';
    this.cloudSyncStep = CLOUD_SYNC_SHEET_ACTIONS;
  }

  private toggleCloudSyncTable(table: string): void {
    const next: string[] = this.cloudSyncSelectedTables.slice();
    const index: number = next.indexOf(table);
    if (index >= 0) { next.splice(index, 1); } else { next.push(table); }
    CloudSyncSelectionStore.getInstance().replaceSelectedBusinessTables(getContext(this), next);
    this.cloudSyncSelectedTables = CloudSyncSelectionStore.getInstance().selectedBusinessTables();
  }

  private async createLocalBackup(): Promise<void> {
    try {
      const backup: LocalBackupService = LocalBackupService.getInstance();
      const saved: boolean = await backup.saveBackup(CURRENT_RELEASE_VERSION);
      if (saved) { promptAction.showToast({ message: '本地备份已保存', duration: 1600 }); this.closeSettingsLeafSheet(); }
      else { this.cloudSyncError = backup.getLastErrorMessage(); }
    } catch (_e) { this.cloudSyncError = '备份失败，请检查保存位置后重试'; }
  }

  private async chooseLocalRestore(): Promise<void> {
    try {
      const backup: LocalBackupService = LocalBackupService.getInstance();
      const document: LocalBackupDocument | null = await backup.selectAndValidate();
      if (!shouldOpenRestoreConfirmation(document !== null) || document === null) {
        promptAction.showToast({ message: backup.getLastErrorMessage(), duration: 2200 });
        return;
      }
      this.openSettingsLeafSheet(SETTINGS_SHEET_POPUP, (): void => {
        this.pendingLocalRestore = document;
        this.cloudSyncError = '';
        this.cloudSyncStep = CLOUD_SYNC_SHEET_RESTORE_CONFIRM;
        this.popupSheetMode = 3;
      });
    } catch (_e) {
      promptAction.showToast({ message: '读取或校验备份文件失败', duration: 1800 });
    }
  }

  private async confirmLocalRestore(): Promise<void> {
    if (!this.pendingLocalRestore) { this.cloudSyncError = '请重新选择备份文件'; return; }
    const restored: boolean = await LocalBackupService.getInstance().restore(this.pendingLocalRestore);
    if (!restored) { this.cloudSyncError = '恢复失败，原本地数据未被修改'; return; }
    this.pendingLocalRestore = null;
    promptAction.showToast({ message: '本地备份已恢复，未自动上传到云端', duration: 1800 });
    this.closeSettingsLeafSheet();
  }

  private currentCloudSyncSheetSpec(): CloudSyncSheetSpec {
    return cloudSyncSheetSpec(this.cloudSyncStep);
  }

  private async confirmCloudSyncUpload(): Promise<void> {
    const cloud: CloudStore = CloudStore.getInstance();
    if (cloud.requiresCloudServiceGuidance()) {
      this.cloudSyncStep = CLOUD_SYNC_SHEET_UNAVAILABLE;
      return;
    }
    this.cloudSyncError = '';
    this.cloudSyncStep = CLOUD_SYNC_SHEET_UPLOADING;
    const completed: boolean = await cloud.uploadAllToCloud();
    if (completed) {
      promptAction.showToast({ message: '已上传 ' + cloud.syncableTables().length.toString() + ' 类已选数据到华为云空间', duration: 2000 });
      this.closeSettingsLeafSheet();
      return;
    }
    if (cloud.requiresCloudServiceGuidance()) {
      this.cloudSyncStep = CLOUD_SYNC_SHEET_UNAVAILABLE;
      return;
    }
    const uploadError: string = cloud.getLastSyncErrorMessage();
    this.cloudSyncError = uploadError !== '' ? uploadError :
      '上传未确认全部完成，请检查网络后重试。';
    this.cloudSyncStep = CLOUD_SYNC_SHEET_UPLOAD_CONFIRM;
  }

  private async confirmCloudSyncDownload(): Promise<void> {
    const cloud: CloudStore = CloudStore.getInstance();
    if (cloud.requiresCloudServiceGuidance()) {
      this.cloudSyncStep = CLOUD_SYNC_SHEET_UNAVAILABLE;
      return;
    }
    this.cloudSyncError = '';
    this.cloudSyncStep = CLOUD_SYNC_SHEET_DOWNLOADING;
    const result = await cloud.downloadAllFromCloudResult();
    if (result.ok) {
      this.applyCloudUserSettings();
      promptAction.showToast({ message: '已从华为云空间恢复 ' + cloud.syncableTables().length.toString() + ' 类已选数据', duration: 2000 });
      this.closeSettingsLeafSheet();
      return;
    }
    if (cloud.requiresCloudServiceGuidance()) {
      this.cloudSyncStep = CLOUD_SYNC_SHEET_UNAVAILABLE;
      return;
    }
    const downloadError: string = cloud.getLastSyncErrorMessage();
    this.cloudSyncError = result.rollbackFailed
      ? '下载失败且本地恢复未完成。请勿继续修改数据，检查网络后重试或从本地备份恢复。'
      : (downloadError !== '' ? downloadError : '下载失败，已自动恢复操作前的本地数据。请检查网络后重试。');
    this.cloudSyncStep = CLOUD_SYNC_SHEET_DOWNLOAD_CONFIRM;
  }

  private toggleSettingsSection(section: string): void {
    animateTo({ duration: SETTINGS_ACCORDION_ANIMATION_MS, curve: Curve.FastOutSlowIn }, (): void => {
      this.expandedSettingsSection = settingsNextExpandedSection(this.expandedSettingsSection, section);
    });
  }

  private settingsSectionExpanded(section: string): boolean {
    return this.expandedSettingsSection === section;
  }

  private settingsSectionExpandedMaxHeight(section: string): number {
    if (section === SETTINGS_SECTION_APPEARANCE) {
      return this.appearanceExpandedMaxHeight();
    }
    if (section === SETTINGS_SECTION_CONNECTION_LIVE) {
      return 520;
    }
    if (section === SETTINGS_SECTION_DISPLAY_INTERACTION) {
      return 460;
    }
    if (section === SETTINGS_SECTION_RDP) {
      return 820;
    }
    if (section === SETTINGS_SECTION_RUSTDESK) {
      return 980;
    }
    if (section === SETTINGS_SECTION_SECURITY) {
      return 420;
    }
    if (section === SETTINGS_SECTION_TUTORIAL) {
      return 240;
    }
    if (section === SETTINGS_SECTION_ABOUT) {
      return 300;
    }
    return 0;
  }

  private appearanceExpandedMaxHeight(): number {
    const measured: number = Number.isFinite(this.appearanceContentHeight) ?
      this.appearanceContentHeight : 0;
    // constraintSize() changes the measured area while the accordion animates.
    // Never let those transient values become the next expansion's cap.
    return Math.max(APPEARANCE_EXPANDED_MIN_HEIGHT,
      measured > 0 ? Math.ceil(measured + 8) : 0);
  }

  private async openFeedbackEmail(): Promise<void> {
    const ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    const versionName: string = CURRENT_RELEASE_VERSION;
    const attempts: SettingsFeedbackLaunchAttempt[] =
      settingsFeedbackLaunchAttempts(versionName, this.breakpoint, this.isDesktopDevice);
    const params: Record<string, Object> =
      settingsFeedbackMailPanelParams(versionName, this.breakpoint, this.isDesktopDevice);
    for (let i = 0; i < attempts.length; i++) {
      try {
        const spec: SettingsFeedbackLaunchAttempt = attempts[i];
        if (spec.kind === 'mailPanel') {
          await this.openFeedbackEmailPanel(ctx, params);
          return;
        }
        const want: Want = {
          action: spec.action,
          uri: spec.uri
        };
        if (spec.entities.length > 0) {
          want.entities = spec.entities;
        }
        await ctx.startAbility(want);
        return;
      } catch (err) {
        hilog.warn(0x0000, 'HostListPage',
          'open feedback launch failed index=' + i.toString() +
            ' kind=' + attempts[i].kind + ': ' + JSON.stringify(err));
      }
    }
    promptAction.showToast({ message: '未找到可用的邮件应用', duration: 2200 });
  }

  private openFeedbackSheet(): void {
    this.openSettingsLeafSheet(SETTINGS_SHEET_FEEDBACK);
  }

  private openFeedbackEmailPanel(
    ctx: common.UIAbilityContext,
    params: Record<string, Object>
  ): Promise<void> {
    return new Promise<void>((resolve, reject): void => {
      const abilityStartCallback: common.AbilityStartCallback = {
        onError: (code: number, name: string, message: string): void => {
          hilog.warn(0x0000, 'HostListPage', 'feedback mail panel target error code=' +
            code.toString() + ' name=' + name + ' message=' + message);
        },
        onResult: (result: common.AbilityResult): void => {
          hilog.info(0x0000, 'HostListPage',
            'feedback mail panel result=' + JSON.stringify(result));
        }
      };
      ctx.startAbilityByType(SETTINGS_EMAIL_PANEL_TYPE, params, abilityStartCallback,
        (err: BusinessError): void => {
          if (err) {
            reject(err);
            return;
          }
          resolve();
        });
    });
  }

  private async openAppRatingPage(): Promise<void> {
    const candidates: string[] = settingsRatingUriCandidates();
    for (let i = 0; i < candidates.length; i++) {
      try {
        const ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
        const action: string = settingsRatingWantAction(candidates[i]);
        const want: Want = {
          action: action,
          uri: candidates[i]
        };
        if (action === SETTINGS_BROWSER_VIEW_ACTION) {
          want.entities = ['entity.system.browsable'];
        }
        await ctx.startAbility(want);
        return;
      } catch (err) {
        hilog.warn(0x0000, 'HostListPage',
          'open rating uri failed index=' + i.toString() + ': ' + JSON.stringify(err));
      }
    }
    promptAction.showToast({ message: '暂时无法打开应用市场评分页', duration: 2200 });
  }

  private ensureGripMonitorOnPageShow(): void {
    if (this.appInBackground) {
      this.stopGripMonitor(true);
      this.dbgMonitor = '后台暂停';
      hilog.info(0x0001, 'GripFAB', 'skip monitor while app is background');
      return;
    }
    if (!shouldUseGripMonitor(this.isDesktopDevice)) {
      if (this.gripMonitorRegistered) {
        this.stopGripMonitor(true);
      }
      this.holdingHand = motion.HoldingHandStatus.UNKNOWN_STATUS;
      this.dbgMonitor = 'PC不启用';
      hilog.info(0x0001, 'GripFAB', 'skip monitor on PC device');
      return;
    }
    if (!this.gripAlignmentEnabled) {
      if (this.gripMonitorRegistered) {
        this.stopGripMonitor(true);
      }
      this.holdingHand = motion.HoldingHandStatus.UNKNOWN_STATUS;
      this.dbgMonitor = '用户未启用';
      return;
    }
    hilog.info(0x0001, 'GripFAB', 'ensure pageActive=' + (this.pageActive ? '1' : '0') +
      ' permission=' + (this.gripPermissionGranted ? '1' : '0') +
      ' registered=' + (this.gripMonitorRegistered ? '1' : '0') +
      ' callbacks=' + this.gripCallbackCount.toString());
    if (!this.gripPermissionGranted) {
      this.scheduleGripPermissionRequest();
      return;
    }
    if (shouldRebindGripMonitorOnPageShow(this.pageActive, this.gripPermissionGranted, this.gripMonitorRegistered)) {
      this.forceRestartGripMonitor();
      return;
    }
    if (shouldRestartGripMonitor(this.pageActive, this.gripMonitorRegistered, this.gripPermissionGranted)) {
      this.startGripMonitor();
      return;
    }
    // An already-authorised monitor is rebound here. A first-time permission
    // request is scheduled separately so it cannot block this page lifecycle.
  }

  /**
   * Let ArkUI commit the host list before opening the optional system dialog.
   * A permission request from aboutToAppear can otherwise leave the first
   * window looking blank on devices that pause page composition for the dialog.
   */
  private scheduleGripPermissionRequest(): void {
    if (!shouldAutoRequestGripPermission(
      this.pageActive,
      this.appInBackground,
      this.isDesktopDevice,
      this.gripAlignmentEnabled,
      this.gripPermissionGranted,
      this.gripPermissionAttempted,
      this.gripPermissionRequest !== null
    ) || this.gripRestartTimer !== -1) {
      return;
    }
    this.gripRestartTimer = setTimeout((): void => {
      this.gripRestartTimer = -1;
      if (!shouldAutoRequestGripPermission(
        this.pageActive,
        this.appInBackground,
        this.isDesktopDevice,
        this.gripAlignmentEnabled,
        this.gripPermissionGranted,
        this.gripPermissionAttempted,
        this.gripPermissionRequest !== null
      )) {
        return;
      }
      void this.requestGripPermission();
    }, 320);
  }

  // 握持回调 — 直接赋值 @State, FAB 容器的 .animation() 自动处理弹簧过渡
  private gripCallback: Callback<motion.HoldingHandStatus> =
    (data: motion.HoldingHandStatus): void => {
      try {
        // 直接赋值触发重渲染, justifyContent 变化由 .animation(spring) 驱动动画
        this.holdingHand = data;
        this.gripCallbackCount++;
        this.gripWatchdogRetryCount = 0;
        if (this.gripWatchdog !== -1) { clearTimeout(this.gripWatchdog); this.gripWatchdog = -1; }
        // 握持回调成功 → 功能正常, 隐藏调试面板
        if (this.debugVisible && this.gripCallbackCount === 1) {
          this.debugVisible = false;
        }
        const now: Date = new Date();
        this.lastGripTime = now.getHours().toString().padStart(2,'0') + ':' + now.getMinutes().toString().padStart(2,'0') + ':' + now.getSeconds().toString().padStart(2,'0');
        this.dbgHoldingHand = data + ' (' + this.holdingHandLabel(data) + ')';
        hilog.info(0x0001, 'GripFAB', 'callback status=' + data.toString() +
          ' label=' + this.holdingHandLabel(data) + ' count=' + this.gripCallbackCount.toString());
      } catch (err) {
        this.lastErrorCode = 'E008';
        this.lastErrorMsg = JSON.stringify(err);
        this.debugVisible = true;
      }
    };

  private operatingHandFallbackCallback: Callback<motion.OperatingHandStatus> =
    (data: motion.OperatingHandStatus): void => {
      try {
        const nextStatus: motion.HoldingHandStatus =
          holdingHandStatusFromOperatingHandStatus(data as number, this.holdingHand as number) as motion.HoldingHandStatus;
        this.holdingHand = nextStatus;
        this.gripCallbackCount++;
        this.gripWatchdogRetryCount = 0;
        if (this.debugVisible && this.gripCallbackCount === 1) {
          this.debugVisible = false;
        }
        const now: Date = new Date();
        this.lastGripTime = now.getHours().toString().padStart(2, '0') + ':' +
          now.getMinutes().toString().padStart(2, '0') + ':' +
          now.getSeconds().toString().padStart(2, '0');
        this.dbgHoldingHand = nextStatus + ' (' + this.holdingHandLabel(nextStatus) + ', 操作手fallback)';
        hilog.info(0x0001, 'GripFAB', 'operating fallback callback status=' + data.toString() +
          ' mapped=' + nextStatus.toString() + ' label=' + this.holdingHandLabel(nextStatus) +
          ' count=' + this.gripCallbackCount.toString());
      } catch (err) {
        this.lastErrorCode = 'E108';
        this.lastErrorMsg = JSON.stringify(err);
        this.debugVisible = true;
      }
    };

  // 握持状态的可读标签
  private holdingHandLabel(v: motion.HoldingHandStatus): string {
    if (v === motion.HoldingHandStatus.NOT_HELD) { return '未握持'; }
    if (v === motion.HoldingHandStatus.LEFT_HAND_HELD) { return '左手'; }
    if (v === motion.HoldingHandStatus.RIGHT_HAND_HELD) { return '右手'; }
    if (v === motion.HoldingHandStatus.BOTH_HANDS_HELD) { return '双手'; }
    if (v === motion.HoldingHandStatus.UNKNOWN_STATUS) { return '未知'; }
    return '?';
  }

  aboutToDisappear(): void {
    this.pageActive = false;
    if (this.pendingSheetOpenTimer !== -1) {
      clearTimeout(this.pendingSheetOpenTimer);
      this.pendingSheetOpenTimer = -1;
    }
    const pendingHostId: string = this.pendingAddSheetConnectHostId;
    this.pendingAddSheetConnectHostId = '';
    if (pendingHostId !== '') {
      this.releaseConnectionAttempt(pendingHostId);
    }
    this.clearPendingSettingsLeafOpen();
    this.unregisterDataRefreshListeners();
    this.stopGripMonitor(true);
    try {
      if (this.inputDeviceListenerRegistered) {
        inputDevice.off('change', this.inputDeviceListener);
        this.inputDeviceListenerRegistered = false;
      }
    } catch (_err) { /* ignore */ }
    this.clearGripTimers();
    this.lightSensing.offLightChange(this.lightChangeListener);
    this.lightSensing.stopMonitoring();
  }

  private clearGripTimers(): void {
    if (this.gripWatchdog !== -1) { clearTimeout(this.gripWatchdog); this.gripWatchdog = -1; }
    if (this.gripRestartTimer !== -1) { clearTimeout(this.gripRestartTimer); this.gripRestartTimer = -1; }
  }

  private stopGripMonitor(forceOff: boolean = false): void {
    this.clearGripTimers();
    if (this.gripMonitorRegistered || forceOff) {
      if (this.gripMonitorUsingOperatingFallback) {
        try { motion.off('operatingHandChanged', this.operatingHandFallbackCallback); } catch (err) { }
      } else {
        try { motion.off('holdingHandChanged', this.gripCallback); } catch (err) { }
      }
      if (forceOff) {
        try { motion.off('holdingHandChanged'); } catch (err) { }
        try { motion.off('operatingHandChanged'); } catch (err) { }
      }
      this.gripMonitorRegistered = false;
      this.gripMonitorUsingOperatingFallback = false;
    }
  }

  private forceRestartGripMonitor(): void {
    this.stopGripMonitor(true);
    this.startGripMonitor();
  }

  // All explicit enable attempts share one in-flight permission request. This
  // prevents aboutToAppear/onPageShow/background timing from creating two
  // system dialogs or leaving the UI waiting for the wrong Promise.
  private requestGripPermission(): Promise<void> {
    if (this.gripPermissionRequest !== null) {
      return this.gripPermissionRequest;
    }
    const request: Promise<void> = this.requestGripPermissionInternal();
    this.gripPermissionRequest = request;
    request.then((): void => {
      if (this.gripPermissionRequest === request) { this.gripPermissionRequest = null; }
    }, (): void => {
      if (this.gripPermissionRequest === request) { this.gripPermissionRequest = null; }
    });
    return request;
  }

  // 智感握姿运行时权限请求: holdingHandChanged 官方只要求 DETECT_GESTURE。
  private async requestGripPermissionInternal(): Promise<void> {
    if (!this.gripAlignmentEnabled) {
      this.dbgMonitor = '用户未启用';
      return;
    }
    if (this.appInBackground) {
      this.dbgMonitor = '后台暂停';
      hilog.info(0x0001, 'GripFAB', 'permission request skipped while app is background');
      return;
    }
    this.gripPermissionAttempted = true;
    this.dbgTimestamp = new Date().toLocaleTimeString();
    let atManager: abilityAccessCtrl.AtManager;
    let ctx: common.UIAbilityContext;
    let tokenId: number;
    try {
      atManager = abilityAccessCtrl.createAtManager();
    } catch (err) {
      this.lastErrorCode = 'E001';
      this.lastErrorMsg = 'createAtManager() 失败: ' + JSON.stringify(err);
      this.dbgDgPerm = '✗'; this.dbgAmPerm = '✗'; return;
    }
    try {
      ctx = getContext(this) as common.UIAbilityContext;
      tokenId = ctx.applicationInfo.accessTokenId;
      if (!tokenId || tokenId === 0) {
        this.lastErrorCode = 'E002';
        this.lastErrorMsg = 'accessTokenId 无效: ' + tokenId;
        this.dbgDgPerm = '✗'; this.dbgAmPerm = '✗'; return;
      }
    } catch (err) {
      this.lastErrorCode = 'E002';
      this.lastErrorMsg = '无法获取 context/tokenId: ' + JSON.stringify(err);
      this.dbgDgPerm = '✗'; this.dbgAmPerm = '✗'; return;
    }
    // 权限: DETECT_GESTURE
    let detectGestureGranted: boolean = false;
    try {
      const dgStatus: abilityAccessCtrl.GrantStatus =
        atManager.checkAccessTokenSync(tokenId, 'ohos.permission.DETECT_GESTURE');
      if (dgStatus === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED) {
        this.dbgDgPerm = '✓';
        detectGestureGranted = true;
      } else {
        const dgResult = await atManager.requestPermissionsFromUser(ctx,
          ['ohos.permission.DETECT_GESTURE']);
        if (dgResult.authResults[0] === 0) {
          this.dbgDgPerm = '✓';
          detectGestureGranted = true;
        } else {
          this.gripPermissionGranted = false;
          this.dbgDgPerm = '✗'; this.lastErrorCode = 'E004';
          this.lastErrorMsg = 'DETECT_GESTURE 被用户拒绝'; return;
        }
      }
    } catch (err) {
      this.gripPermissionGranted = false;
      this.dbgDgPerm = '✗'; this.lastErrorCode = 'E003';
      this.lastErrorMsg = 'DETECT_GESTURE 检查/请求异常: ' + JSON.stringify(err); return;
    }

    this.dbgAmPerm = '无需';
    if (!shouldIgnoreActivityMotionForHoldingHand(detectGestureGranted, false)) {
      this.gripPermissionGranted = false;
      this.lastErrorCode = 'E009';
      this.lastErrorMsg = 'DETECT_GESTURE 未授权，握姿监听未启动';
      hilog.warn(0x0001, 'GripFAB', 'permission denied: DETECT_GESTURE not granted');
      return;
    }

    hilog.info(0x0001, 'GripFAB', 'permission ok: DETECT_GESTURE granted, ACTIVITY_MOTION not required');
    this.gripPermissionGranted = true;
    this.startGripMonitor();
  }

  // 智感握姿监听 — 使用保存的回调引用
  private startGripMonitor(): void {
    if (!this.pageActive || !this.gripAlignmentEnabled) {
      this.dbgMonitor = !this.gripAlignmentEnabled ? '用户未启用' : '页面未激活';
      return;
    }
    if (this.appInBackground) {
      this.dbgMonitor = '后台暂停';
      hilog.info(0x0001, 'GripFAB', 'start skipped while app is background');
      return;
    }
    if (this.gripMonitorRegistered) {
      hilog.info(0x0001, 'GripFAB', 'start skipped: already registered');
      return;
    }
    try {
      this.gripCallbackCount = 0;
      this.gripMonitorUsingOperatingFallback = false;
      motion.on('holdingHandChanged', this.gripCallback);
      this.gripMonitorRegistered = true;
      this.dbgMonitor = '已注册';
      hilog.info(0x0001, 'GripFAB', 'motion.on holdingHandChanged succeeded');
      // 超时检测: 10秒内无回调则认为设备不支持
      if (this.gripWatchdog !== -1) { clearTimeout(this.gripWatchdog); this.gripWatchdog = -1; }
      this.gripWatchdog = setTimeout(() => {
        if (shouldMarkGripMonitorStaleAfterWatchdog(this.pageActive, this.gripMonitorRegistered, this.gripCallbackCount)) {
          this.lastErrorCode = 'E102';
          this.lastErrorMsg = '注册成功但 10s 内无回调 — 设备可能不支持握持检测';
          this.dbgMonitor = '无回调(超时)';
          hilog.warn(0x0001, 'GripFAB', 'watchdog timeout: no holdingHandChanged callback');
          this.stopGripMonitor();
          if (this.pageActive && this.gripPermissionGranted) {
            this.startOperatingHandFallbackMonitor('holding watchdog timeout');
          }
        }
      }, 10000);
    } catch (err) {
      this.gripMonitorRegistered = false;
      this.gripMonitorUsingOperatingFallback = false;
      this.lastErrorCode = 'E007';
      this.lastErrorMsg = 'motion.on 注册失败: ' + JSON.stringify(err);
      this.dbgMonitor = '注册失败';
      const be: BusinessError = err as BusinessError;
      hilog.error(0x0001, 'GripFAB', 'motion.on holdingHandChanged failed: ' + JSON.stringify(err));
      if (shouldFallbackToOperatingHandOnSubscribeFailure(be.code)) {
        this.startOperatingHandFallbackMonitor('holding subscribe failed ' + be.code.toString());
      }
    }
  }

  private startOperatingHandFallbackMonitor(reason: string): void {
    if (!this.pageActive || !this.gripAlignmentEnabled) {
      this.dbgMonitor = !this.gripAlignmentEnabled ? '用户未启用' : '页面未激活';
      return;
    }
    if (this.appInBackground) {
      this.dbgMonitor = '后台暂停';
      hilog.info(0x0001, 'GripFAB', 'operating fallback skipped while app is background');
      return;
    }
    if (this.gripMonitorRegistered) {
      hilog.info(0x0001, 'GripFAB', 'operating fallback skipped: already registered');
      return;
    }
    try {
      this.gripCallbackCount = 0;
      this.gripMonitorUsingOperatingFallback = true;
      motion.on('operatingHandChanged', this.operatingHandFallbackCallback);
      this.gripMonitorRegistered = true;
      this.dbgMonitor = '操作手fallback';
      this.lastErrorCode = '';
      this.lastErrorMsg = '';
      hilog.info(0x0001, 'GripFAB', 'motion.on operatingHandChanged fallback succeeded: ' + reason);
    } catch (err) {
      this.gripMonitorRegistered = false;
      this.gripMonitorUsingOperatingFallback = false;
      this.lastErrorCode = 'E107';
      this.lastErrorMsg = 'operatingHandChanged fallback 注册失败: ' + JSON.stringify(err);
      this.dbgMonitor = 'fallback失败';
      this.debugVisible = true;
      hilog.error(0x0001, 'GripFAB', 'motion.on operatingHandChanged fallback failed: ' + JSON.stringify(err));
    }
  }

  async load(): Promise<void> {
    this.isLoading = true;
    try {
      this.refreshCryptoStatus();
      this.refreshHostListView();
      this.rdpCredentials = this.srv.getAllRdpCredentials();
      this.hostCount = this.srv.getHostCount();
      this.lockedCount = this.srv.getLockedHostCount();
      this.rdpCount = this.srv.getRdpCount();
      this.rustdeskCount = this.srv.getRustdeskCount();
      this.sshCount = this.srv.getSshCount();
      this.keyCount = KeyVaultService.getInstance().getSshKeyCount();
      this.totpCount = KeyVaultService.getInstance().getTotpCount();
      this.accountDisplayName = this.auth.isLoggedIn() ? this.auth.getDisplayName() : '';
      this.accountAvatarUrl = this.auth.isLoggedIn() ? this.auth.getAvatarUrl() : '';
    } catch (err) {
      // Optional storage/service failures must not reject the page lifecycle or
      // leave a new user behind an infinite loading layer.
      hilog.warn(0x0001, 'HostList', 'load failed; showing safe empty state: ' + JSON.stringify(err));
    } finally {
      // A storage/service exception must never leave the first-render loading
      // layer on screen indefinitely.
      this.isLoading = false;
    }
  }

  private loadAfterServiceReady(): void {
    if (!this.srv.isReady()) {
      this.srv.whenReady().then((): void => {
        this.applyCloudUserSettings();
        if (this.pageActive) { this.load(); }
      });
    }
    const keyVault: KeyVaultService = KeyVaultService.getInstance();
    if (!keyVault.isReady()) {
      keyVault.whenReady().then((): void => {
        if (this.pageActive) { this.load(); }
      });
    }
  }

  private registerDataRefreshListeners(): void {
    if (!this.hostDataUnsubscribe) {
      this.hostDataUnsubscribe = this.srv.onDataChange((): void => {
        this.applyCloudUserSettings();
        this.load();
      });
    }
    if (!this.keyVaultDataUnsubscribe) {
      this.keyVaultDataUnsubscribe = KeyVaultService.getInstance().onDataChange((): void => {
        this.load();
      });
    }
  }

  private unregisterDataRefreshListeners(): void {
    if (this.hostDataUnsubscribe) {
      this.hostDataUnsubscribe();
      this.hostDataUnsubscribe = null;
    }
    if (this.keyVaultDataUnsubscribe) {
      this.keyVaultDataUnsubscribe();
      this.keyVaultDataUnsubscribe = null;
    }
  }

  private refreshHostListView(): void {
    // 用新对象快照驱动列表和详情，避免服务层原地更新同一 RemoteHost
    // 引用时，LazyForEach/卡片内部只收到 reload 却继续显示旧字段。
    const nextHosts: RemoteHost[] = this.srv.getAllHosts().map((host: RemoteHost): RemoteHost =>
      RemoteHost.fromJSON(host.toJSON()));
    this.hostCount = this.srv.getHostCount();
    this.lockedCount = this.srv.getLockedHostCount();
    this.rdpCount = this.srv.getRdpCount();
    this.rustdeskCount = this.srv.getRustdeskCount();
    this.sshCount = this.srv.getSshCount();
    const nextSignature: string = JSON.stringify(
      nextHosts.map((host: RemoteHost): Object => host.toJSON()));
    if (nextSignature === this.hostDataSignature) { return; }
    this.hostDataSignature = nextSignature;
    this.hosts = nextHosts;
    this.filteredHosts = this.visibleHostsForCurrentMode();
    this.hostDataSource.replaceAll(this.filteredHosts);
    this.hostViewRevision += 1;
    this.refreshSshTrustedHostsView();
    this.refreshRdpTrustedHostsView();
  }

  private visibleHostsForCurrentMode(): RemoteHost[] {
    let visible = visibleHostsForHostListMode(
      this.hosts,
      this.searchText,
      this.isDesktopDevice,
      this.breakpoint,
      this.activeFilterProto,
      this.curTab
    );
    return filterHostsByWorkspace(visible, this.workspaceGroupId);
  }

  private pal(): Palette {
    return this.theme === 'light' ? buildLight(this.accentColor) : buildDark(this.accentColor);
  }
  private font(): string { return AppConfig.fontFamily; }

  private relayStatusColor(status: string): string {
    if (status === 'online') { return this.accentColor; }
    if (status === 'offline' || status === 'error') { return this.pal().danger; }
    return this.pal().text3;
  }

  private relayStatusLabel(status: string): string {
    if (status === 'online') { return '在线'; }
    if (status === 'offline') { return '离线'; }
    if (status === 'error') { return '异常'; }
    return '未检测';
  }

  private hostCountForRelayId(relayId: string): number {
    let count = 0;
    this.srv.getAllHosts().forEach((h) => {
      if (h.rustdeskRelayId === relayId) { count++; }
    });
    return count;
  }

  private hostCountForAccountId(relayId: string, accountId: string): number {
    let count = 0;
    this.srv.getAllHosts().forEach((h) => {
      if (h.rustdeskRelayId === relayId && h.rustdeskAccountId === accountId) { count++; }
    });
    return count;
  }

  private accountLoginLabel(status: string): string {
    if (status === 'logged_in') { return '已登录'; }
    if (status === 'expired') { return '已过期'; }
    return '未登录';
  }

  private accountLoginColor(status: string): string {
    if (status === 'logged_in') { return this.pal().success; }
    if (status === 'expired') { return this.pal().danger; }
    return this.pal().text3;
  }

  // 窗口尺寸 (用于 sheetW/fabEdgePadding 计算; 断点由 BreakpointUtil → AppStorage 统一管理)
  private updateWindowMetrics(): void {
    try {
      const d: display.Display = display.getDefaultDisplaySync();
      this.windowW = d.width;
      this.isFullScreen = (d.width >= d.width - 4);
    } catch (_err) { this.windowW = 360; }
  }

  // 手动切换主题时同步更新状态栏 (与 EntryAbility.updateStatusBar 一致)
  private async updateStatusBarForTheme(isDark: boolean): Promise<void> {
    try {
      const win = await window.getLastWindow(getContext(this));
      if (!win) { return; }
      await win.setWindowSystemBarProperties({
        statusBarColor: '#00000000',
        navigationBarColor: '#00000000',
        statusBarContentColor: isDark ? '#E6E6E6' : '#1C1C1C',
        navigationBarContentColor: isDark ? '#E6E6E6' : '#1C1C1C'
      });
    } catch (_e) { /* 静默 */ }
  }

  // 光晕颜色 → 渐变遮罩色；保持材质透亮，避免暗色模式被深色蒙层压成灰块。
  private haloMaskColor(): string {
    let alphaValue: number = 0x33;
    if (this.ambientLightEffectEnabled) {
      alphaValue = 0x22 + this.ambientLightIntensity * 0x22;
    }
    const alpha: string = this.alphaHex(alphaValue);
    return '#' + alpha + this.haloColor.substring(1);
  }

  private refreshHaloPresets(): void {
    this.haloPresets = haloPresetsForTheme(this.theme);
  }

  private syncHaloColorForCurrentTheme(): void {
    this.refreshHaloPresets();
    try {
      const prefs = preferences.getPreferencesSync(getContext(this), { name: 'RemoteDesktopAppPrefs' });
      const savedLightHalo: string = prefs.getSync(HALO_COLOR_LIGHT_KEY, '') as string;
      const savedDarkHalo: string = prefs.getSync(HALO_COLOR_DARK_KEY, '') as string;
      const legacyHalo: string = prefs.getSync(HALO_COLOR_LEGACY_KEY, '') as string;
      const lightHalo: string =
        resolveStoredHaloColorForTheme('light', savedLightHalo, savedDarkHalo, legacyHalo);
      const darkHalo: string =
        resolveStoredHaloColorForTheme('dark', savedLightHalo, savedDarkHalo, legacyHalo);
      AppStorage.setOrCreate(HALO_COLOR_LIGHT_KEY, lightHalo);
      AppStorage.setOrCreate(HALO_COLOR_DARK_KEY, darkHalo);
      const currentKey: string = haloColorPreferenceKey(this.theme);
      const savedCurrentHalo: string = this.theme === 'dark' ? savedDarkHalo : savedLightHalo;
      const currentHalo: string = this.theme === 'dark' ? darkHalo : lightHalo;
      if (shouldMigrateLegacyHaloColorToTheme(this.theme, savedCurrentHalo, legacyHalo)) {
        prefs.putSync(currentKey, currentHalo);
        prefs.flushSync();
      }
      this.haloColor = currentHalo;
      AppStorage.setOrCreate(HALO_COLOR_LEGACY_KEY, currentHalo);
    } catch (_e) {
      const lightHalo: string = AppStorage.get<string>(HALO_COLOR_LIGHT_KEY) ?? '';
      const darkHalo: string = AppStorage.get<string>(HALO_COLOR_DARK_KEY) ?? '';
      const legacyHalo: string = AppStorage.get<string>(HALO_COLOR_LEGACY_KEY) ?? '';
      this.haloColor = resolveStoredHaloColorForTheme(this.theme, lightHalo, darkHalo, legacyHalo);
      AppStorage.setOrCreate(HALO_COLOR_LEGACY_KEY, this.haloColor);
    }
  }

  private saveHaloColorForCurrentTheme(hex: string): void {
    if (this.haloPresets.indexOf(hex) < 0) {
      return;
    }
    const key: string = haloColorPreferenceKey(this.theme);
    this.haloColor = hex;
    AppStorage.setOrCreate(key, hex);
    AppStorage.setOrCreate(HALO_COLOR_LEGACY_KEY, hex);
    try {
      const prefs = preferences.getPreferencesSync(getContext(this), { name: 'RemoteDesktopAppPrefs' });
      prefs.putSync(key, hex);
      prefs.flushSync();
    } catch (_e) { /* ignore */ }
    CloudStore.getInstance().upsertUserSetting(key, hex);
  }

  private currentSystemColorMode(ctx: common.UIAbilityContext, preferEnvironment: boolean): number {
    const envMode: number | null = this.environmentColorMode();
    const mode: number | undefined = ctx.config.colorMode;
    if (preferEnvironment && envMode !== null) {
      return envMode;
    }
    if (mode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK) {
      return mode;
    }
    if (mode === ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT) {
      return ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT;
    }
    if (!preferEnvironment && envMode !== null) {
      return envMode;
    }
    return ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT;
  }

  private environmentColorMode(): number | null {
    if (this.systemUiColorMode === ENV_COLOR_MODE_DARK) {
      return ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    }
    if (this.systemUiColorMode === ENV_COLOR_MODE_LIGHT) {
      return ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT;
    }
    return null;
  }

  private ensureEnvironmentColorMode(): void {
    try {
      Environment.envProp('colorMode', ENV_COLOR_MODE_UNKNOWN);
    } catch (err) {
      hilog.warn(0x0000, 'HostListPage', 'Environment colorMode bind failed: ' + JSON.stringify(err));
    }
  }

  onSystemColorModeChange(): void {
    if (!this.followSystem) {
      return;
    }
    this.syncFollowSystemTheme('environment', true);
  }

  private syncFollowSystemTheme(source: string, preferEnvironment: boolean = true): void {
    try {
      this.ensureEnvironmentColorMode();
      const ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
      const sysMode: number = this.currentSystemColorMode(ctx, preferEnvironment);
      const isDark: boolean = sysMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
      AppStorage.setOrCreate('systemColorMode', sysMode);
      AppStorage.setOrCreate('currentTheme', isDark ? 'dark' : 'light');
      this.theme = isDark ? 'dark' : 'light';
      this.updateStatusBarForTheme(isDark);
      hilog.info(0x0000, 'HostListPage', 'follow-system theme sync source=' + source +
        ' mode=' + sysMode.toString() + ' theme=' + this.theme);
    } catch (err) {
      hilog.warn(0x0000, 'HostListPage', 'follow-system theme sync failed: ' + JSON.stringify(err));
    }
  }

  private alphaHex(value: number): string {
    const clamped: number = Math.max(0, Math.min(255, Math.round(value)));
    const hex: string = clamped.toString(16).toUpperCase();
    return hex.length === 1 ? '0' + hex : hex;
  }

  private topSafeHeightVp(): number {
    return this.topRectHeight > 0 ? px2vp(this.topRectHeight) : AppTheme.layout.statusBarH;
  }

  private hostTopBarHeight(): number {
    return this.topSafeHeightVp() + (this.breakpoint === 'xl' ? 104 : 96);
  }

  private titleTopBarHeight(): number {
    return this.topSafeHeightVp() + 64;
  }

  private titleOffsetY(): number {
    return 8;
  }

  // FAB 边缘间距 (响应式, 保证左右握持时按钮离边框足够远)
  private fabEdgePadding(): number {
    if (this.breakpoint === 'md') { return 48; }
    return 32;
  }

  // 滚动方向检测 → 控制悬浮栏+FAB 显隐
  // offset 是 onScrollFrameBegin 的帧增量 (正=向下, 负=向上)
  private handleScrollDirection(offset: number): void {
    if (Math.abs(offset) <= this.SCROLL_THRESHOLD) { return; }
    if (offset > 0 && !this.tabBarHidden) {
      animateTo({ duration: 300, curve: curves.interpolatingSpring(0, 1, 200, 17) }, () => {
        this.tabBarHidden = true;
      });
    } else if (offset < 0 && this.tabBarHidden) {
      animateTo({ duration: 300, curve: curves.interpolatingSpring(0, 1, 200, 17) }, () => {
        this.tabBarHidden = false;
      });
    }
  }

  // 根据握姿返回 FAB 水平对齐方式 (官方推荐: 对齐驱动而非 translate 手动计算)
  private getFabAlignment(): FlexAlign {
    if (this.holdingHand === motion.HoldingHandStatus.LEFT_HAND_HELD) {
      return FlexAlign.Start;
    }
    if (this.holdingHand === motion.HoldingHandStatus.RIGHT_HAND_HELD) {
      return FlexAlign.End;
    }
    return FlexAlign.Center;
  }

  private sheetW(): number {
    if (this.breakpoint === 'sm') { return 0; }
    const w: number = Math.round(this.windowW / 3);
    if (w < 320) { return 320; }
    if (w > 520) { return 520; }
    return w;
  }

  private doHostBatchDelete(): void {
    promptAction.showDialog({
      title: '批量删除',
      message: '确定要删除选中的 ' + this.hostSelectedIds.size + ' 个主机吗？',
      buttons: [
        { text: '取消', color: this.pal().text2 },
        { text: '删除', color: this.pal().danger }
      ]
    }).then((result: Object): void => {
      const r: Record<string, number> = result as Record<string, number>;
      if (r['index'] === 1) {
        const ids: string[] = [];
        this.hostSelectedIds.forEach((id: string): void => { ids.push(id); });
        this.srv.removeHosts(ids);
        this.hostSelectionMode = false;
        this.hostSelectedIds = new Set<string>();
      }
    });
  }

  private toggleHostSelect(id: string, checked: boolean): void {
    const next: Set<string> = new Set(this.hostSelectedIds);
    if (checked) { next.add(id); } else { next.delete(id); }
    this.hostSelectedIds = next;
  }

  private onSearchChange(value: string): void {
    this.searchText = value;
    if (this.searchTimer !== -1) { clearTimeout(this.searchTimer); }
    this.searchTimer = setTimeout(() => {
      this.filteredHosts = this.visibleHostsForCurrentMode();
      this.hostDataSource.replaceAll(this.filteredHosts);
    }, 300);
  }

  private beginConnectionAttempt(hostId: string): number {
    if (!shouldBeginConnectionAttempt(this.connectionAttemptHostId)) { return 0; }
    const generation: number = nextConnectionAttemptGeneration(this.connectionAttemptGeneration);
    this.connectionAttemptGeneration = generation;
    this.connectionAttemptHostId = hostId;
    return generation;
  }

  private isCurrentConnectionAttempt(hostId: string, generation: number): boolean {
    return shouldApplyConnectionAttempt(
      this.connectionAttemptGeneration,
      generation,
      this.connectionAttemptHostId,
      hostId
    );
  }

  private releaseConnectionAttempt(hostId: string): void {
    if (hostId.length > 0 && this.connectionAttemptHostId === hostId) {
      this.connectionAttemptHostId = '';
    }
  }

  private releaseConnectionAttemptIfCurrent(hostId: string, generation: number): void {
    if (generation !== this.connectionAttemptGeneration) {
      return;
    }
    this.releaseConnectionAttempt(hostId);
  }

  private async connectToHost(host: RemoteHost): Promise<void> {
    hilog.info(0x0001, 'HostList', 'connectToHost: proto=' + host.protocol +
      ' host=' + maskHost(host.host) + ':' + host.port);
    const protocolNeedsArbitration: boolean = host.protocol === 'rdp' || host.protocol === 'rustdesk';
    const connectionGeneration: number = protocolNeedsArbitration ?
      this.beginConnectionAttempt(host.id) : 0;
    if (protocolNeedsArbitration && connectionGeneration === 0) {
      promptAction.showToast({ message: '已有连接请求正在处理，请等待当前弹窗结束', duration: 1800 });
      return;
    }
    if (host.locked) {
      const r = await showLockGate(host.label, 'biometric');
      if (!r.ok) {
        this.releaseConnectionAttempt(host.id);
        const msg: string = lockGateErrorMessage(r);
        if (msg !== '') { promptAction.showToast({ message: msg, duration: 2000 }); }
        return;
      }
    }
    if (protocolNeedsArbitration && !this.isCurrentConnectionAttempt(host.id, connectionGeneration)) {
      return;
    }
    if (host.protocol === 'ssh') {
      // T-210: SSH 前置校验 (指纹 + 私钥密码) → 通过后才路由
      this.openSshPreflight(host);
    } else if (host.protocol === 'rdp') {
      this.openRdpCertificatePreflight(host);
    } else if (host.protocol === 'rustdesk') {
      const relay: RustDeskRelayConfig | undefined = host.rustdeskDirectEnabled ? undefined :
        this.srv.getAllRelays().find((item: RustDeskRelayConfig): boolean => item.id === host.rustdeskRelayId);
      const rustDeskError: string = rustDeskConnectionError({
        directEnabled: host.rustdeskDirectEnabled,
        directHost: host.rustdeskDirectHost,
        directPort: host.rustdeskDirectPort,
        relayId: host.rustdeskRelayId,
        relayExists: relay !== undefined,
        relayHost: relay ? relay.idServer : '',
        relayPort: relay ? relay.idServerPort : 0,
        relayKey: relay ? relay.key : '',
        relayKeyMode: relay ? relay.keyMode : 'auto',
        proManaged: host.rustdeskProManaged && host.sourceType === 'rustdesk_pro'
      });
      if (rustDeskError !== '') {
        this.releaseConnectionAttempt(host.id);
        promptAction.showToast({ message: rustDeskError, duration: 2600 });
        return;
      }
      if (shouldOpenRustDeskProPreflight(host.protocol, host.sourceType, host.rustdeskProManaged)) {
        this.openRustDeskProPreflight(host);
      } else {
        const params: Record<string, Object> = {};
        params['hostId'] = host.id;
        router.pushUrl({ url: 'pages/RemoteDesktop', params: params });
        this.releaseConnectionAttempt(host.id);
      }
    } else {
      const params: Record<string, Object> = {};
      params['hostId'] = host.id;
      router.pushUrl({ url: 'pages/RemoteDesktop', params: params });
    }
  }

  private openRdpCertificatePreflight(host: RemoteHost): void {
    if (this.rdpCertificateClosing || this.showRdpCertificatePreflight) {
      // connectToHost 已经为该主机占住了连接尝试；等旧 Sheet 的 onDisappear
      // 完成后再打开，避免旧退出动画和新 builder 同时存在。
      this.rdpCertificatePendingHostId = host.id;
      hilog.info(0x0001, 'HostList', 'RDP certificate preflight queued until previous Sheet disappears host=' +
        host.id);
      return;
    }
    const generation: number = nextRdpCertificateProbeGeneration(this.rdpCertificateProbeGeneration);
    this.rdpCertificateProbeGeneration = generation;
    this.rdpCertificateAttemptGeneration = this.connectionAttemptGeneration;
    this.rdpCertificatePendingHostId = '';
    this.rdpCertificateOpenedAt = Date.now();
    this.rdpCertificateHostId = host.id;
    this.rdpCertificateHostLabel = host.host;
    this.rdpCertificateState = RdpCertificatePreflightState.PROBING;
    this.rdpCertificateWarning = '';
    this.rdpCertificateInfo = null;
    this.rdpCertificateError = '';
    this.rdpCertificateShowDetails = false;
    this.showRdpCertificatePreflight = shouldShowRdpCertificateProbeSheetBeforeProbe(
      host.rdpCertificateTrustMode,
      host.rdpCertificateFingerprintSha256
    );
    this.doRdpCertificateProbe(host, generation);
  }

  private getRdpCertificateHost(): RemoteHost | undefined {
    return this.srv.getHost(this.rdpCertificateHostId);
  }

  private isRdpCertificateBusy(): boolean {
    return this.rdpCertificateState === RdpCertificatePreflightState.PROBING;
  }

  private handleRdpCertificateSheetDismiss(action: DismissSheetAction): void {
    if (this.rdpCertificateClosing || this.rdpCertificatePendingRouteParams !== null) {
      return;
    }
    const elapsed: number = Date.now() - this.rdpCertificateOpenedAt;
    if (elapsed < 500 || this.isRdpCertificateBusy()) {
      return;
    }
    this.doRdpCertificateCancel();
    action.dismiss();
  }

  private doRdpCertificateCancel(): void {
    if (this.rdpCertificateClosing) {
      return;
    }
    const hostId: string = this.rdpCertificateHostId;
    this.rdpCertificateProbeGeneration = nextRdpCertificateProbeGeneration(
      this.rdpCertificateProbeGeneration
    );
    this.rdpCertificatePendingRouteParams = null;
    this.rdpCertificateClosingHostId = hostId;
    this.rdpCertificateClosingAttemptGeneration = this.rdpCertificateAttemptGeneration;
    this.rdpCertificateClosing = true;
    this.lastSheetDismissAtMs = Date.now();
    this.showRdpCertificatePreflight = false;
    // 允许下一次连接请求排队，但保留 builder 状态直到 onDisappear，避免退出动画期间闪烁。
    this.releaseConnectionAttemptIfCurrent(hostId, this.rdpCertificateAttemptGeneration);
  }

  private handleRdpCertificateSheetDisappear(): void {
    this.noteSheetDismissed();
    const closingHostId: string = this.rdpCertificateClosingHostId.length > 0
      ? this.rdpCertificateClosingHostId : this.rdpCertificateHostId;
    const closingAttemptGeneration: number = this.rdpCertificateClosingAttemptGeneration > 0
      ? this.rdpCertificateClosingAttemptGeneration : this.rdpCertificateAttemptGeneration;
    const params: Record<string, Object> | null = this.rdpCertificatePendingRouteParams;
    const nextHostId: string = this.rdpCertificatePendingHostId;
    this.rdpCertificatePendingRouteParams = null;
    this.rdpCertificatePendingHostId = '';
    this.rdpCertificateClosingHostId = '';
    this.rdpCertificateClosingAttemptGeneration = 0;
    this.rdpCertificateClosing = false;
    this.rdpCertificateHostId = '';
    this.rdpCertificateHostLabel = '';
    this.rdpCertificateInfo = null;
    this.rdpCertificateWarning = '';
    this.rdpCertificateError = '';
    this.rdpCertificateShowDetails = false;
    this.rdpCertificateAttemptGeneration = 0;
    // 取消时已经释放过；generation 检查避免旧 Sheet 的 onDisappear 清掉同一主机的新请求。
    this.releaseConnectionAttemptIfCurrent(closingHostId, closingAttemptGeneration);

    if (params !== null) {
      if (nextHostId.length > 0) {
        this.releaseConnectionAttempt(nextHostId);
      }
      setTimeout((): void => {
        router.pushUrl({ url: 'pages/RemoteDesktop', params: params });
      }, rdpCertificateRouteDelayMsAfterSheetClose());
      return;
    }
    if (nextHostId.length === 0) {
      return;
    }
    const nextHost: RemoteHost | undefined = this.srv.getHost(nextHostId);
    if (!nextHost) {
      this.releaseConnectionAttempt(nextHostId);
      return;
    }
    const queuedAttemptGeneration: number = this.connectionAttemptGeneration;
    const reopen: () => void = (): void => {
      if (this.connectionAttemptGeneration !== queuedAttemptGeneration ||
        this.connectionAttemptHostId !== nextHostId) {
        return;
      }
      const queuedHost: RemoteHost | undefined = this.srv.getHost(nextHostId);
      if (queuedHost) {
        this.openRdpCertificatePreflight(queuedHost);
      } else {
        this.releaseConnectionAttempt(nextHostId);
      }
    };
    const delayMs: number = sheetOpenDelayMsAfterDismiss(Date.now(), this.lastSheetDismissAtMs);
    if (delayMs <= 0) {
      reopen();
    } else {
      setTimeout(reopen, delayMs);
    }
  }

  private doRdpCertificateRetryWrap(): void {
    const host = this.getRdpCertificateHost();
    if (host) {
      const generation: number = nextRdpCertificateProbeGeneration(this.rdpCertificateProbeGeneration);
      this.rdpCertificateProbeGeneration = generation;
      this.rdpCertificateState = RdpCertificatePreflightState.PROBING;
      this.rdpCertificateError = '';
      this.doRdpCertificateProbe(host, generation);
    }
  }

  private doRdpCertificateContinueOnceWrap(): void {
    const host = this.getRdpCertificateHost();
    if (host) { this.doRdpCertificateContinueOnce(host); }
  }

  private doRdpCertificateTrustWrap(): void {
    const host = this.getRdpCertificateHost();
    if (host) { this.doRdpCertificateTrust(host); }
  }

  private isCurrentRdpCertificateProbe(host: RemoteHost, generation: number): boolean {
    return shouldApplyRdpCertificateProbeResult(
      this.rdpCertificateProbeGeneration,
      generation,
      this.rdpCertificateHostId,
      host.id
    );
  }

  private async doRdpCertificateProbe(host: RemoteHost, generation: number): Promise<void> {
    const startedAt: number = Date.now();
    try {
      hilog.info(0x0001, 'HostList',
        'RDP certificate probe start host=' + maskHost(host.host) + ':' + host.port.toString() +
          ' visible=' + (this.showRdpCertificatePreflight ? 'true' : 'false') +
          ' generation=' + generation.toString());
      await new Promise<void>((r) => setTimeout(r, this.showRdpCertificatePreflight ? 160 : 80));
      if (!this.isCurrentRdpCertificateProbe(host, generation)) {
        hilog.info(0x0001, 'HostList',
          'RDP certificate probe skipped before native call [E-RDP-CERT-STALE-BEFORE]');
        return;
      }
      const info: RdpCertificateInfo = await this.loader.probeRdpCertificateAsync(
        host.host,
        host.port,
        host.customHostname
      );
      if (!this.isCurrentRdpCertificateProbe(host, generation)) {
        hilog.info(0x0001, 'HostList',
          'RDP certificate probe result ignored [E-RDP-CERT-STALE-AFTER]');
        return;
      }
      const elapsed: number = Date.now() - startedAt;
      hilog.info(0x0001, 'HostList',
        'RDP certificate probe done host=' + maskHost(host.host) + ':' + host.port.toString() +
          ' ok=' + (info.ok ? 'true' : 'false') + ' code=' + info.errorCode.toString() +
          ' elapsedMs=' + elapsed.toString());
      if (!info.ok || info.fingerprintSha256.length === 0) {
        if (shouldFallbackToNativeRdpConnectionAfterResolverFailure(
          info.errorCode,
          host.rdpCertificateTrustMode,
          host.rdpCertificateFingerprintSha256
        )) {
          hilog.warn(0x0001, 'HostList',
            'RDP certificate probe resolver failed; using saved fingerprint with native connection');
          this.doRdpCertificateRoute(host);
          return;
        }
        this.rdpCertificateState = RdpCertificatePreflightState.ERROR;
        this.rdpCertificateError = info.errorCode === -11 ?
          '当前设备无法解析该 RDP 地址，请检查设备 DNS、VPN 或 TUN；Windows 侧可解析不代表本设备可用。' :
          (info.errorMessage || '无法读取 RDP 主机证书');
        if (!this.showRdpCertificatePreflight) {
          this.openSheetSafely((): void => { this.showRdpCertificatePreflight = true; }, true);
        }
        return;
      }
      this.rdpCertificateInfo = info;
      const probeView: RdpCertificateProbeView = {
        ok: info.ok,
        fingerprintSha256: info.fingerprintSha256,
        commonName: info.commonName,
        subject: info.subject,
        issuer: info.issuer,
        flags: info.flags,
        rootTrusted: info.rootTrusted,
        hostMismatch: info.hostMismatch,
        errorMessage: info.errorMessage
      };
      this.rdpCertificateState = classifyRdpCertificateProbe(probeView, {
        trustMode: host.rdpCertificateTrustMode,
        savedFingerprintSha256: host.rdpCertificateFingerprintSha256,
        savedAllowHostMismatch: host.rdpCertificateAllowHostMismatch
      });
      this.rdpCertificateWarning = rdpCertificateWarningMessage(
        host.host,
        info.rootTrusted,
        info.hostMismatch
      );
      if (this.rdpCertificateState === RdpCertificatePreflightState.TRUSTED_MATCH) {
        this.doRdpCertificateRoute(host);
      } else {
        if (!this.showRdpCertificatePreflight) {
          this.openSheetSafely((): void => { this.showRdpCertificatePreflight = true; }, true);
        }
      }
    } catch (e) {
      if (!this.isCurrentRdpCertificateProbe(host, generation)) {
        hilog.info(0x0001, 'HostList',
          'RDP certificate probe exception ignored [E-RDP-CERT-STALE-ERROR]');
        return;
      }
      const elapsed: number = Date.now() - startedAt;
      this.rdpCertificateState = RdpCertificatePreflightState.ERROR;
      this.rdpCertificateError = '探测 RDP 证书异常: ' + (e instanceof Error ? e.message : JSON.stringify(e));
      hilog.error(0x0001, 'HostList',
        'RDP certificate probe exception host=' + maskHost(host.host) + ':' + host.port.toString() +
          ' elapsedMs=' + elapsed.toString() + ' err=' + this.rdpCertificateError);
      if (!this.showRdpCertificatePreflight) {
        this.openSheetSafely((): void => { this.showRdpCertificatePreflight = true; }, true);
      }
    }
  }

  private applyRdpCertificateDecisionToHost(
    host: RemoteHost,
    info: RdpCertificateInfo,
    decision: RdpCertificatePreflightDecision
  ): RemoteHost {
    const updated: RemoteHost = RemoteHost.fromJSON(host.toJSON());
    updated.rdpCertificateFingerprintSha256 = info.fingerprintSha256;
    updated.rdpCertificateSubject = info.subject;
    updated.rdpCertificateIssuer = info.issuer;
    updated.rdpCertificateCommonName = info.commonName;
    if (shouldPersistRdpCertificateTrust(decision)) {
      updated.rdpCertificateTrustedAt = Date.now();
      updated.rdpCertificateTrustMode = RDP_CERTIFICATE_EXPLICIT_TRUST_MODE;
    } else {
      updated.rdpCertificateTrustedAt = 0;
      updated.rdpCertificateTrustMode = RDP_CERTIFICATE_UNKNOWN_TRUST_MODE;
    }
    updated.rdpCertificateAllowUntrustedRoot = !info.rootTrusted;
    updated.rdpCertificateAllowHostMismatch = info.hostMismatch;
    return updated;
  }

  private doRdpCertificateContinueOnce(host: RemoteHost): void {
    if (!this.rdpCertificateInfo) { return; }
    const info = this.rdpCertificateInfo;
    const routed: RemoteHost = this.applyRdpCertificateDecisionToHost(
      host,
      info,
      RdpCertificatePreflightDecision.CONTINUE_ONCE
    );
    this.doRdpCertificateRoute(routed, info);
  }

  private doRdpCertificateTrust(host: RemoteHost): void {
    if (!this.rdpCertificateInfo) { return; }
    const info = this.rdpCertificateInfo;
    const updated: RemoteHost = this.applyRdpCertificateDecisionToHost(
      host,
      info,
      RdpCertificatePreflightDecision.TRUST
    );
    this.srv.updateHost(updated);
    this.doRdpCertificateRoute(updated);
  }

  private doRdpCertificateRoute(host: RemoteHost, oneTimeInfo?: RdpCertificateInfo): void {
    if (this.rdpCertificateClosing) {
      return;
    }
    const params: Record<string, Object> = {};
    params['hostId'] = host.id;
    if (oneTimeInfo) {
      params['rdpCertificateOneTimeFingerprintSha256'] = oneTimeInfo.fingerprintSha256;
      params['rdpCertificateOneTimeAllowUntrustedRoot'] = !oneTimeInfo.rootTrusted;
      params['rdpCertificateOneTimeAllowHostMismatch'] = oneTimeInfo.hostMismatch;
    }
    if (shouldRouteRdpCertificateAfterSheetDisappear(this.showRdpCertificatePreflight)) {
      this.rdpCertificatePendingRouteParams = params;
      this.rdpCertificateClosingHostId = host.id;
      this.rdpCertificateClosingAttemptGeneration = this.rdpCertificateAttemptGeneration;
      this.rdpCertificateClosing = true;
      this.lastSheetDismissAtMs = Date.now();
      this.showRdpCertificatePreflight = false;
      return;
    }
    this.rdpCertificateHostId = '';
    this.releaseConnectionAttempt(host.id);
    setTimeout((): void => {
      router.pushUrl({ url: 'pages/RemoteDesktop', params: params });
    }, rdpCertificateRouteDelayMsAfterSheetClose());
  }

  /** T-210: 打开 SSH 前置校验 Sheet (通过统一 bindSheet) */
  private openSshPreflight(host: RemoteHost): void {
    this.sshPreflightOpenedAt = Date.now();
    this.sshPreflightHostId = host.id;
    this.sshPreflightHostLabel = host.username + '@' + host.host + ':' + host.port.toString();
    this.sshPreflightSavedAlgorithm = host.sshHostKeyAlgorithm;
    this.sshPreflightState = SshPreflightState.PROBING;
    this.sshPreflightHostKeyInfo = null;
    this.sshPreflightError = '';
    this.sshPreflightPassphraseInput = '';
    // 使用独立 overlay (hostContent Stack 内)
    this.openSheetSafely((): void => { this.showSshPreflight = true; }, true);
    this.doSshPreflightProbe(host);
  }

  /** T-210: 关闭 preflight */
  private doSshPreflightCancel(): void {
    this.showSshPreflight = false;
    this.sshPreflightHostId = '';
  }

  private sshPreflightSheetHeight(): SheetSize | number {
    return SheetSize.FIT_CONTENT;
  }

  private isSshPreflightBusy(): boolean {
    return this.sshPreflightState === SshPreflightState.PROBING ||
      this.sshPreflightState === SshPreflightState.VERIFYING_PASSPHRASE;
  }

  private handleSshPreflightSheetDismiss(action: DismissSheetAction): void {
    const elapsed: number = Date.now() - this.sshPreflightOpenedAt;
    if (elapsed < 500 || this.isSshPreflightBusy()) {
      return;
    }
    this.doSshPreflightCancel();
    action.dismiss();
  }

  /** 获取当前 preflight host (从 CloudStore) */
  private getSshPreflightHost(): RemoteHost | undefined {
    return this.srv.getHost(this.sshPreflightHostId);
  }

  private resolveSshKeyMaterial(host: RemoteHost): SshKeyMaterial {
    let keyData = host.sshKeyData;
    let encryptedHint = false;
    if (host.sshKeyId !== '') {
      const ref = KeyVaultService.getInstance().getSshKey(host.sshKeyId);
      if (ref) {
        keyData = ref.privateKey;
        encryptedHint = ref.privateKeyEncrypted;
      }
    }
    return { privateKey: keyData, encryptedHint: encryptedHint };
  }

  // ---- T-210 onClick wrappers (从 @Builder 的 onClick 回调) ----

  private doSshPreflightRetryWrap(): void {
    const host = this.getSshPreflightHost();
    if (host) { this.sshPreflightState = SshPreflightState.PROBING; this.doSshPreflightProbe(host); }
  }

  private doSshPreflightTrustFirstWrap(): void {
    const host = this.getSshPreflightHost();
    if (host) { this.doSshPreflightTrustFirst(host); }
  }

  private doSshPreflightContinueWrap(): void {
    const host = this.getSshPreflightHost();
    if (host) { this.doSshPreflightCheckPassphrase(host); }
  }

  private doSshPreflightUpdateWrap(): void {
    const host = this.getSshPreflightHost();
    if (host) { this.doSshPreflightUpdateTrust(host); }
  }

  private doSshPreflightVerifyWrap(): void {
    const host = this.getSshPreflightHost();
    if (host) { this.doSshPreflightVerifyPassphrase(host); }
  }

  /** T-210: 探测主机指纹 (async, 完成后更新 @State) */
  private async doSshPreflightProbe(host: RemoteHost): Promise<void> {
    try {
      await new Promise<void>((r) => setTimeout(r, 80));
      const info = this.loader.probeSshHostKey(host.host, host.port);
      if (!info.ok) {
        this.sshPreflightState = SshPreflightState.ERROR;
        this.sshPreflightError = info.errorMessage || '无法读取 SSH 主机指纹';
        return;
      }
      this.sshPreflightHostKeyInfo = info;
      const savedRaw = host.sshHostKeyRawBase64;
      const trustMode = host.sshHostKeyTrustMode;
      if (trustMode === 1 && savedRaw === info.rawBase64) {
        this.sshPreflightState = SshPreflightState.TRUSTED_MATCH;
      } else if (trustMode === 1 && savedRaw !== '' && savedRaw !== info.rawBase64) {
        this.sshPreflightState = SshPreflightState.HOST_KEY_CHANGED;
      } else {
        this.sshPreflightState = SshPreflightState.TRUST_FIRST_TIME;
      }
    } catch (e) {
      this.sshPreflightState = SshPreflightState.ERROR;
      this.sshPreflightError = '探测主机指纹异常: ' + (e instanceof Error ? e.message : JSON.stringify(e));
    }
  }

  /** T-210: 用户确认信任 (首次) */
  private doSshPreflightTrustFirst(host: RemoteHost): void {
    if (!this.sshPreflightHostKeyInfo) { return; }
    const info = this.sshPreflightHostKeyInfo;
    const updated: RemoteHost = RemoteHost.fromJSON(host.toJSON());
    updated.sshHostKeyAlgorithm = info.algorithm;
    updated.sshHostKeyFingerprintSha256 = info.fingerprintSha256;
    updated.sshHostKeyRawBase64 = info.rawBase64;
    updated.sshHostKeyTrustedAt = Date.now();
    updated.sshHostKeyTrustMode = 1;
    this.srv.updateHost(updated);
    this.doSshPreflightCheckPassphrase(updated);
  }

  /** T-210: 指纹变更 → 更新信任 */
  private doSshPreflightUpdateTrust(host: RemoteHost): void {
    if (!this.sshPreflightHostKeyInfo) { return; }
    const info = this.sshPreflightHostKeyInfo;
    const updated: RemoteHost = RemoteHost.fromJSON(host.toJSON());
    updated.sshHostKeyAlgorithm = info.algorithm;
    updated.sshHostKeyFingerprintSha256 = info.fingerprintSha256;
    updated.sshHostKeyRawBase64 = info.rawBase64;
    updated.sshHostKeyTrustedAt = Date.now();
    updated.sshHostKeyTrustMode = 1;
    this.srv.updateHost(updated);
    this.doSshPreflightCheckPassphrase(updated);
  }

  /** T-210: 检查私钥密码 */
  private doSshPreflightCheckPassphrase(host: RemoteHost): void {
    if (!host.sshUseKey) { this.doSshPreflightReady(host); return; }
    const material = this.resolveSshKeyMaterial(host);
    const keyData = material.privateKey;
    if (keyData.length === 0) { this.doSshPreflightReady(host); return; }

    const keyInfo: SshPrivateKeyInfo = this.loader.inspectSshPrivateKey(keyData, host.sshKeyPassphrase);
    if (keyInfo.ok && !keyInfo.encrypted) {
      this.doSshPreflightVerifyKeyAuth(host, '', false);
      return;
    }
    if (host.sshKeyPassphrase === '' && (material.encryptedHint || keyInfo.encrypted)) {
      this.showSshPreflightPassphrase('');
    } else if (host.sshKeyPassphrase !== '' && !keyInfo.ok && keyInfo.encrypted) {
      this.showSshPreflightPassphrase('已保存的私钥密码不可用，请重新输入', true);
    } else {
      this.doSshPreflightVerifyKeyAuth(host, host.sshKeyPassphrase, false);
    }
  }

  private showSshPreflightPassphrase(error: string, saveDefault: boolean = false): void {
    this.sshPreflightState = SshPreflightState.PASSPHRASE_REQUIRED;
    this.sshPreflightPassphraseInput = '';
    this.sshPreflightPassphraseSaveToHost = saveDefault;
    this.sshPreflightError = error;
  }

  private async doSshPreflightVerifyKeyAuth(host: RemoteHost, passphrase: string, allowPassphraseRetry: boolean): Promise<void> {
    this.sshPreflightState = SshPreflightState.VERIFYING_PASSPHRASE;
    try {
      await new Promise<void>((r) => setTimeout(r, 60));
      const keyData = this.resolveSshKeyMaterial(host).privateKey;
      const result = this.loader.testSshKeyAuth(host.host, host.port, host.username, keyData, passphrase);
      if (result.ok) {
        this.doSshPreflightReady(host);
        return;
      }
      if (allowPassphraseRetry || passphrase !== '') {
        this.showSshPreflightPassphrase(
          passphrase !== '' ? '已保存的私钥密码不可用，请重新输入' : '私钥密码错误或密钥不可用',
          passphrase !== '');
      } else {
        this.sshPreflightState = SshPreflightState.ERROR;
        this.sshPreflightError = '密钥认证失败: ' + (result.message || '请确认公钥已安装到服务器 authorized_keys');
      }
    } catch (e) {
      this.sshPreflightState = SshPreflightState.ERROR;
      this.sshPreflightError = '密钥认证验证异常: ' + (e instanceof Error ? e.message : JSON.stringify(e));
    }
  }

  private hasSavedSshPreflightPassphrase(): boolean {
    const host = this.getSshPreflightHost();
    return host !== undefined && host.sshKeyPassphrase !== '';
  }

  /** T-210: 验证私钥密码 */
  private async doSshPreflightVerifyPassphrase(host: RemoteHost): Promise<void> {
    this.sshPreflightState = SshPreflightState.VERIFYING_PASSPHRASE;
    try {
      await new Promise<void>((r) => setTimeout(r, 60));
      const keyData = this.resolveSshKeyMaterial(host).privateKey;
      const keyInfo: SshPrivateKeyInfo = this.loader.inspectSshPrivateKey(keyData, this.sshPreflightPassphraseInput);
      if (keyInfo.ok && !keyInfo.encrypted) {
        this.showSshPreflightPassphrase('此私钥实际未设置密码，请在密钥管理中重新设置密码');
        return;
      }
      const result = this.loader.testSshKeyAuth(
        host.host, host.port, host.username, keyData, this.sshPreflightPassphraseInput
      );
      if (result.ok) {
        if (this.sshPreflightPassphraseSaveToHost) {
          host.sshKeyPassphrase = this.sshPreflightPassphraseInput;
          this.srv.updateHost(host);
        }
        this.doSshPreflightReady(host);
      } else {
        this.showSshPreflightPassphrase('私钥密码错误或密钥不可用');
      }
    } catch (e) {
      this.showSshPreflightPassphrase('验证异常');
    }
  }

  /** T-210: 一切就绪 — 创建 token 并路由 */
  private doSshPreflightReady(host: RemoteHost): void {
    const svc = SshPreflightService.getInstance();
    const passphrase = this.sshPreflightPassphraseInput || host.sshKeyPassphrase;
    const rawBase64 = this.sshPreflightHostKeyInfo?.rawBase64 || host.sshHostKeyRawBase64;
    const fp = this.sshPreflightHostKeyInfo?.fingerprintSha256 || host.sshHostKeyFingerprintSha256;
    const tokenId = svc.createToken({
      hostId: host.id,
      expectedHostKeyRawBase64: rawBase64,
      expectedHostKeyFingerprintSha256: fp,
      privateKeyPassphrase: passphrase
    });
    this.showSshPreflight = false;
    this.sshPreflightHostId = '';
    const params: Record<string, Object> = {};
    params['hostId'] = host.id;
    params['sshPreflightToken'] = tokenId;
    router.pushUrl({ url: 'pages/SshTerminal', params: params });
  }

  private handleHostCardClick(host: RemoteHost): void {
    if (this.hostSelectionMode) {
      this.toggleHostSelect(host.id, !this.hostSelectedIds.has(host.id));
      return;
    }
    this.connectToHost(host);
  }

  private async toggleLock(host: RemoteHost): Promise<void> {
    const r = await showLockGate(host.label, 'biometric');
    if (!r.ok) {
      const msg: string = lockGateErrorMessage(r);
      if (msg !== '') { promptAction.showToast({ message: msg, duration: 2000 }); }
      return;
    }
    host.locked = !host.locked;
    host.lockType = host.locked ? LockType.BIOMETRIC : LockType.NONE;
    if (!this.srv.updateHost(host)) {
      promptAction.showToast({ message: '保存主机状态失败', duration: 2000 });
      return;
    }
    promptAction.showToast({ message: host.locked ? '已锁定' : '已解锁', duration: 1500 });
  }

  private prepareRustDeskProPreflight(host: RemoteHost): number {
    this.rustDeskProPreflightGeneration += 1;
    const generation: number = this.rustDeskProPreflightGeneration;
    this.rustDeskProPreflightHostId = host.id;
    this.rustDeskProAuthMode = host.rustdeskDirectEnabled ? 'password' :
      (host.rustdeskAuthMode === 'request_approval' ? 'request_approval' : 'password');
    this.rustDeskProPassword = host.password;
    this.rustDeskProPasswordMode = host.rustdeskPasswordMode === 1 ? 1 : 0;
    this.rustDeskProPasswordVisible = false;
    this.rustDeskProRememberPassword = true;
    this.rustDeskProPreflightError = '';
    this.rustDeskProPreflightState = RustDeskProPreflightState.IDLE;
    return generation;
  }

  private openRustDeskProPreflight(host: RemoteHost): void {
    if (this.rustDeskProPreflightClosing || this.showRustDeskProPreflight) {
      // connectToHost 已经为该主机占住了连接尝试；等旧 Sheet 的 onDisappear
      // 完成后再把同一个请求打开，避免旧动画和新 builder 同时存在。
      this.rustDeskProPreflightPendingHostId = host.id;
      hilog.info(0x0001, 'HostList', 'RustDesk preflight queued until previous Sheet disappears host=' +
        host.id);
      return;
    }
    const generation: number = this.prepareRustDeskProPreflight(host);
    this.openSheetSafely((): void => {
      if (generation !== this.rustDeskProPreflightGeneration || this.rustDeskProPreflightClosing) {
        return;
      }
      this.showRustDeskProPreflight = true;
    }, true);
  }

  private isCurrentRustDeskPreflightDirect(): boolean {
    const host: RemoteHost | undefined = this.srv.getHost(this.rustDeskProPreflightHostId);
    return host !== undefined && host.rustdeskDirectEnabled;
  }

  private cancelRustDeskProPreflight(): void {
    const hostId: string = this.rustDeskProPreflightHostId;
    this.rustDeskProPreflightGeneration += 1;
    if (this.rustDeskProPreflightState === RustDeskProPreflightState.CONNECTING) {
      this.loader.disconnect();
    }
    this.rustDeskProPreflightPendingRouteParams = null;
    this.rustDeskProPreflightClosingHostId = hostId;
    this.rustDeskProPreflightClosing = true;
    this.lastSheetDismissAtMs = Date.now();
    this.showRustDeskProPreflight = false;
    // 保留 hostId 到 onDisappear，避免退出动画期间清空 builder 状态并误伤下一次请求。
    this.releaseConnectionAttempt(hostId);
  }

  private handleRustDeskProPreflightDisappear(): void {
    this.noteSheetDismissed();
    const closingHostId: string = this.rustDeskProPreflightClosingHostId.length > 0
      ? this.rustDeskProPreflightClosingHostId : this.rustDeskProPreflightHostId;
    const routeParams: Record<string, Object> | null = this.rustDeskProPreflightPendingRouteParams;
    const nextHostId: string = this.rustDeskProPreflightPendingHostId;
    this.rustDeskProPreflightPendingRouteParams = null;
    this.rustDeskProPreflightPendingHostId = '';
    this.rustDeskProPreflightClosingHostId = '';
    this.rustDeskProPreflightClosing = false;
    this.rustDeskProPreflightHostId = '';
    this.rustDeskProPreflightState = RustDeskProPreflightState.IDLE;
    this.rustDeskProPreflightError = '';
    this.rustDeskProPassword = '';
    this.releaseConnectionAttempt(closingHostId);

    if (routeParams !== null) {
      // 认证成功的会话必须先完成 Sheet 退出，再切换页面；连接尝试也在这里
      // 释放，防止新页面出现时 HostList 仍被旧请求占用。
      if (nextHostId.length > 0) {
        this.releaseConnectionAttempt(nextHostId);
      }
      setTimeout((): void => {
        router.pushUrl({ url: 'pages/RemoteDesktop', params: routeParams });
      }, 0);
      return;
    }

    if (nextHostId.length === 0) {
      return;
    }
    const nextHost: RemoteHost | undefined = this.srv.getHost(nextHostId);
    if (!nextHost) {
      this.releaseConnectionAttempt(nextHostId);
      return;
    }
    // openSheetSafely 会使用刚刚记录的 dismiss 时间，再等待一个完整的
    // Sheet 防重入窗口；此时旧 native Sheet 已经收到 onDisappear。
    this.openRustDeskProPreflight(nextHost);
  }

  private rustDeskProConfig(host: RemoteHost): SessionConfig {
    const relay: RustDeskRelayConfig | undefined = this.srv.getAllRelays()
      .find((item: RustDeskRelayConfig): boolean => item.id === host.rustdeskRelayId);
    const direct: boolean = host.rustdeskDirectEnabled;
    const endpoint: RustDeskHostEndpoint = resolveRustDeskHostEndpoint(
      relay ?? null,
      host.host,
      direct,
      host.rustdeskDirectHost,
      host.rustdeskDirectPort
    );
    return {
      protocol: 'rustdesk',
      host: endpoint.host,
      port: endpoint.port,
      username: '', password: host.password, width: 1920, height: 1080,
      customHostname: rustDeskProPeerIdForConnection(host.rustdeskProPeerId, host.customHostname),
      gatewayHost: '', gatewayPort: 0, domain: '', codec: '',
      multiMonitor: false, monitorCount: 1, colorDepth: 32,
      authMethod: 'password', privateKeyPem: '', privateKeyPassphrase: '',
      rdImageQuality: this.rustdeskImageQuality, rdDirectIp: direct,
      rdDirectPort: endpoint.port,
      rdLanDiscovery: this.rustdeskLanDiscovery, rdPrivacyMode: this.rustdeskPrivacyMode,
      rdAudioEnabled: this.rustdeskAudioEnabled, rdClipboardEnabled: this.rustdeskClipboardEnabled,
      rdPasswordMode: host.rustdeskPasswordMode,
      rdAuthMode: rustDeskAuthModeForConnection(direct, host.rustdeskAuthMode) === 'request_approval' ? 1 : 0,
      rdRelayId: host.rustdeskRelayId, rdAccountId: host.rustdeskAccountId,
      rdServerKey: relay ? relay.key : '',
      rdServerKeyMode: relay ? rustDeskRelayKeyModeForFfi(relay.key, relay.keyMode) : 1
    };
  }

  private async confirmRustDeskProPreflight(): Promise<void> {
    const stored: RemoteHost | undefined = this.srv.getHost(this.rustDeskProPreflightHostId);
    if (!stored || this.rustDeskProPreflightState === RustDeskProPreflightState.CONNECTING) { return; }
    if (this.rustDeskProAuthMode === 'password' && this.rustDeskProPassword.trim().length === 0) {
      this.rustDeskProPreflightError = '请输入远程 RustDesk 设备密码。';
      return;
    }
    if (this.rustDeskProAuthMode === 'request_approval' && stored.rustdeskDirectEnabled) {
      this.rustDeskProPreflightError = '直连模式只能使用设备密码。';
      return;
    }
    const generation: number = ++this.rustDeskProPreflightGeneration;
    const host: RemoteHost = RemoteHost.fromJSON(stored.toJSON());
    host.rustdeskAuthMode = this.rustDeskProAuthMode === 'request_approval' ? 'request_approval' : 'password';
    host.rustdeskPasswordMode = this.rustDeskProPasswordMode === 1 ? 1 : 0;
    if (host.rustdeskAuthMode === 'password') { host.password = this.rustDeskProPassword; }
    this.rustDeskProPreflightError = '';
    this.rustDeskProPreflightState = RustDeskProPreflightState.CONNECTING;
    try {
      if (!await this.loader.waitForPendingTeardown(5000)) {
        throw new Error('上一连接尚未完全结束，请稍后重试。');
      }
      const sid: number = this.loader.connect(this.rustDeskProConfig(host));
      if (sid <= 0) { throw new Error('无法启动 RustDesk 连接 [E-RUSTDESK-PREFLIGHT-' + Math.abs(sid).toString() + ']'); }
      const timeoutMs: number = host.rustdeskAuthMode === 'request_approval' ? 100000 : 25000;
      const startedAt: number = Date.now();
      while (Date.now() - startedAt < timeoutMs) {
        if (generation !== this.rustDeskProPreflightGeneration) { return; }
        const state: number = this.loader.getConnectionState(sid);
        if (state === 2) {
          this.rustDeskProPreflightState = RustDeskProPreflightState.AUTHENTICATED;
          const saved: RemoteHost = RemoteHost.fromJSON(stored.toJSON());
          saved.rustdeskAuthMode = host.rustdeskAuthMode;
          saved.rustdeskPasswordMode = host.rustdeskPasswordMode;
          if (this.rustDeskProRememberPassword && host.rustdeskAuthMode === 'password') {
            saved.password = host.password;
          }
          const now: number = Date.now();
          const record: ActiveRemoteSessionRecord = {
            sessionId: sid, hostId: host.id, protocol: RemoteProtocol.rustdesk,
            hostAddress: host.host, protocolConnected: true, renderAttached: false,
            restoreNeeded: true, latestSurfaceId: '', createdAtMs: now, updatedAtMs: now
          };
          ActiveRemoteSessionRegistry.getInstance().setActive(record);
          this.srv.updateHost(saved);
          const params: Record<string, Object> = {};
          params['hostId'] = host.id;
          params['rustdeskPreauthenticated'] = true;
          this.rustDeskProPreflightPendingRouteParams = params;
          this.rustDeskProPreflightClosingHostId = host.id;
          this.rustDeskProPreflightClosing = true;
          this.lastSheetDismissAtMs = Date.now();
          this.showRustDeskProPreflight = false;
          return;
        }
        if (state === 4 || state === 0) {
          const detail: string = this.loader.getRustDeskLastError() || this.loader.getConnectionLastMessage(sid);
          throw new Error(detail || '远端鉴权失败，请检查密码后重试。');
        }
        await new Promise<void>((resolve: () => void): void => { setTimeout(resolve, 100); });
      }
      throw new Error(host.rustdeskAuthMode === 'request_approval' ? '等待远端批准超时，请重新发起。' : '鉴权超时，请检查网络或密码。');
    } catch (err) {
      if (generation !== this.rustDeskProPreflightGeneration) { return; }
      this.loader.disconnect();
      this.rustDeskProPreflightState = RustDeskProPreflightState.ERROR;
      this.rustDeskProPreflightError = err instanceof Error ? err.message : JSON.stringify(err);
    }
  }

  // 编辑主机 (锁定状态需先鉴权)
  private async editHost(host: RemoteHost): Promise<void> {
    const latestHost: RemoteHost = this.srv.getHost(host.id) ?? host;
    if (latestHost.locked) {
      const r = await showLockGate(latestHost.label, 'biometric');
      if (!r.ok) {
        const msg: string = lockGateErrorMessage(r);
        if (msg !== '') { promptAction.showToast({ message: msg, duration: 2000 }); }
        return;
      }
    }
    hilog.info(0x0001, 'HostList', 'edit host protocol=' + latestHost.protocol +
      ' rdpCredentialHash=' + hashForLog(latestHost.rdpCredentialId));
    this.editingHostId = latestHost.id;
    this.label = latestHost.label;
    this.proto = latestHost.protocol;
    this.hostAddr = latestHost.host;
    this.portVal = latestHost.port;
    if (latestHost.protocol === 'rdp') {
      this.rdpPortVal = latestHost.port;
    } else if (latestHost.protocol === 'ssh') {
      this.sshPortVal = latestHost.port;
    }
    this.username = latestHost.username;
    this.sheetPwd = latestHost.password;
    this.chn = latestHost.customHostname;
    this.selectedRelayId = latestHost.rustdeskRelayId;
    this.selectedAccountId = latestHost.rustdeskAccountId;
    this.selectedRdpCredentialId = latestHost.rdpCredentialId;
    this.sheetRdpAuthMode = latestHost.rdpAuthMode;
    this.sheetRdpRestrictedAdminSecretSource = latestHost.rdpRestrictedAdminSecretSource;
    this.sheetRdpRestrictedAdminHash = '';
    // An existing blank-password host has already passed the explicit creation confirmation.
    this.sheetRdpBlankPasswordConfirmed = latestHost.protocol === 'rdp' &&
      latestHost.rdpAuthMode === 'blank_password';
    this.sheetPwdMode = latestHost.rustdeskPasswordMode;
    this.sheetRustdeskAuthMode = latestHost.rustdeskDirectEnabled ? 'password' :
      (latestHost.rustdeskAuthMode === 'request_approval' ? 'request_approval' : 'password');
    this.sheetRustdeskDirectEnabled = latestHost.rustdeskDirectEnabled;
    this.sheetRustdeskDirectHost = latestHost.rustdeskDirectHost;
    this.sheetRustdeskDirectPort = latestHost.rustdeskDirectPort > 0 ? latestHost.rustdeskDirectPort : RUSTDESK_PEER_TCP_PORT;
    this.sheetUseKey = latestHost.sshUseKey;
    this.sheetKeyPath = latestHost.sshKeyPath;
    this.sheetKeyText = latestHost.sshKeyData;
    this.sheetKeyId = latestHost.sshKeyId;
    this.sheetKeyPassphrase = latestHost.sshKeyPassphrase;
    this.sheetKeyMode = latestHost.sshKeyId !== '' ? 1 : 0;
    this.sheetProxyHost = latestHost.proxyHost;
    this.sheetProxyPort = latestHost.proxyPort;
    this.sheetProxyUser = latestHost.proxyUsername;
    this.sheetUseProxy = (latestHost.proxyHost !== '');
    this.openSheetSafely((): void => { this.showAddSheet = true; });
  }

  private isEditingProHost(): boolean {
    if (this.editingHostId === '') { return false; }
    const host = this.srv.getHost(this.editingHostId);
    return host !== undefined && host.rustdeskProManaged && host.sourceType === 'rustdesk_pro';
  }

  private hostPlatformText(host: RemoteHost): string {
    if (host.rustdeskProManaged && host.rustdeskProPlatform.trim() !== '') {
      return host.rustdeskProPlatform.trim();
    }
    return host.protocol.toUpperCase();
  }

  // 直接删除主机 (滑动触发)
  private deleteHost(host: RemoteHost): void {
    this.srv.removeHost(host.id);
  }

  // PC大屏模式 + 滑动删除共用: 锁验证 + 确认弹窗 + 动画移除
  private async doDeleteHost(host: RemoteHost): Promise<void> {
    if (host.locked) {
      const r = await showLockGate(host.label, 'biometric');
      if (!r.ok) {
        const msg: string = lockGateErrorMessage(r);
        if (msg !== '') { promptAction.showToast({ message: msg, duration: 2000 }); }
        return;
      }
    }
    promptAction.showDialog({
      title: '确认删除',
      message: '确定要删除主机 "' + host.label + '" 吗？此操作不可恢复。',
      buttons: [
        { text: '取消', color: this.pal().text2 },
        { text: '删除', color: this.pal().danger }
      ]
    }).then((result: Object): void => {
      const r: Record<string, number> = result as Record<string, number>;
      if (r['index'] === 1) {
        this.srv.removeHost(host.id);
      }
    });
  }

  private async doLogout(): Promise<void> {
    // 1. 清空 App 内存登录态
    this.auth.logout();
    // 2. 清空持久化登录模式
    try {
      const prefs = preferences.getPreferencesSync(getContext(this), { name: 'RemoteDesktopAppPrefs' });
      prefs.putSync('loginMode', '');
      prefs.flushSync();
    } catch (_e) { /* ignore */ }
    // 3. 清空磁盘凭据
    AccountKitService.getInstance().clearCredential();
    // 4. 清除 HMS Core 系统级授权 session
    try {
      const cancelReq: authentication.CancelAuthorizationRequest =
        new authentication.HuaweiIDProvider().createCancelAuthorizationRequest();
      const cancelCtrl: authentication.AuthenticationController =
        new authentication.AuthenticationController(getContext(this));
      await cancelCtrl.executeRequest(cancelReq);
    } catch (_e) { /* 无缓存时可能抛异常, 忽略 */ }
    // 5. 清除内存 DEK (保留云端盐值+验证器, 重新登录后可在设置中解锁)
    try {
      DataCrypto.getInstance().lock();
    } catch (_e) { /* ignore */ }
    // 6. 跳转登录页
    this.closeSettingsLeafSheet();
    router.replaceUrl({ url: 'pages/LoginPage' });
  }

  // 直接从设置页呼出系统 Huawei ID 登录 (不跳转 LoginPage)
  private async triggerSystemLogin(): Promise<void> {
    try {
      const request = new authentication.HuaweiIDProvider().createAuthorizationWithHuaweiIDRequest();
      request.forceAuthorization = true;
      request.scopes = ['openid', 'profile'];
      request.permissions = ['serviceauthcode'];
      request.state = util.generateRandomUUID();
      const controller = new authentication.AuthenticationController(getContext(this));
      const response: authentication.AuthorizationWithHuaweiIDResponse =
        await controller.executeRequest(request);
      const credential: authentication.AuthorizationWithHuaweiIDCredential | undefined = response.data;
      if (!credential) { return; }
      const dataObj: Record<string, Object> = credential as Record<string, Object>;
      const nickName: string = (dataObj['nickName'] as string) ?? '';
      const avatarUri: string = (dataObj['avatarUri'] as string) ?? '';
      this.auth.setLoginResult(
        credential.unionID ?? '',
        nickName || '华为用户',
        avatarUri,
        credential.openID ?? ''
      );
      // 持久化 (参照 LoginPage.onLoginSuccess)
      AccountKitService.getInstance().saveCredential({
        unionID: credential.unionID ?? '',
        openID: credential.openID ?? '',
        authorizationCode: credential.authorizationCode ?? '',
        idToken: '',
        displayName: nickName || '华为用户'
      });
      this.saveLoginModeToPrefs('account');
      // 刷新 UI 状态
      this.accountDisplayName = nickName || '华为用户';
      this.accountAvatarUrl = avatarUri;
      this.loginRefreshKey++;
      this.applyCloudUserSettings();
      this.load();
      promptAction.showToast({ message: '登录成功', duration: 1500 });
    } catch (_err) {
      // 用户取消或登录失败, 静默
    }
  }

  private saveLoginModeToPrefs(mode: string): void {
    try {
      const prefs = preferences.getPreferencesSync(getContext(this), { name: 'RemoteDesktopAppPrefs' });
      prefs.putSync('loginMode', mode);
      prefs.flushSync();
    } catch (_e) { /* ignore */ }
  }

  private saveTotpLock(locked: boolean): void {
    try {
      const prefs = preferences.getPreferencesSync(getContext(this), { name: 'RemoteDesktopAppPrefs' });
      prefs.putSync('totpLocked', locked);
      prefs.flushSync();
    } catch (_err) { /* ignore */ }
  }

  private persistRustDeskNumberPref(key: string, value: number): void {
    AppStorage.setOrCreate(key, value);
    try {
      const prefs = preferences.getPreferencesSync(getContext(this), { name: 'RemoteDesktopAppPrefs' });
      prefs.putSync(key, value);
      prefs.flushSync();
    } catch (_e) { /* ignore */ }
    CloudStore.getInstance().upsertUserSetting(key, value);
  }

  private persistRustDeskBooleanPref(key: string, value: boolean): void {
    AppStorage.setOrCreate(key, value);
    try {
      const prefs = preferences.getPreferencesSync(getContext(this), { name: 'RemoteDesktopAppPrefs' });
      prefs.putSync(key, value);
      prefs.flushSync();
    } catch (_e) { /* ignore */ }
    CloudStore.getInstance().upsertUserSetting(key, value);
  }

  /** RustDesk diagnostics are device-local UI preferences; never cloud-sync them. */
  private persistLocalRustDeskBooleanPref(key: string, value: boolean): void {
    AppStorage.setOrCreate(key, value);
    try {
      const prefs = preferences.getPreferencesSync(getContext(this), { name: 'RemoteDesktopAppPrefs' });
      prefs.putSync(key, value);
      prefs.flushSync();
    } catch (_e) { /* best effort: AppStorage remains available for this process */ }
  }

  /** 通用设置持久化 — 同时写 AppStorage + Preferences, 杀后台不丢失 */
  private persistPref(key: string, value: string | number | boolean): void {
    AppStorage.setOrCreate(key, value);
    try {
      const prefs = preferences.getPreferencesSync(getContext(this), { name: 'RemoteDesktopAppPrefs' });
      prefs.putSync(key, value);
      prefs.flushSync();
    } catch (_e) { /* ignore */ }
    CloudStore.getInstance().upsertUserSetting(key, value);
  }

  /**
   * Re-enable style sync without allowing the old release's cloud value to
   * override the local choice on first launch after the feature is restored.
   */
  private migrateVirtualMouseStyleCloudSetting(): void {
    const cloud = CloudStore.getInstance();
    if (!cloud.isReady()) { return; }
    try {
      const prefs = preferences.getPreferencesSync(getContext(this), { name: 'RemoteDesktopAppPrefs' });
      const restoreVersion: number = prefs.getSync(VIRTUAL_MOUSE_STYLE_RESTORE_VERSION_KEY, 0) as number;
      if (shouldApplyCloudVirtualMouseStyle(restoreVersion)) { return; }
      const style: string = normalizeRemoteCursorStyle(this.virtualMouseStyle);
      if (!cloud.upsertUserSetting('virtualMouseStyle', style)) { return; }
      prefs.putSync(VIRTUAL_MOUSE_STYLE_RESTORE_VERSION_KEY, VIRTUAL_MOUSE_STYLE_RESTORE_VERSION);
      prefs.flushSync();
    } catch (_e) { /* cloud migration retries on the next page show */ }
  }

  /** 初始云端恢复完成后覆盖本地的可同步偏好；账号/锁定状态不会进入此路径。 */
  private applyCloudUserSettings(): void {
    const settings = CloudStore.getInstance().loadUserSettings();
    const keys: string[] = Object.keys(settings);
    if (keys.length === 0) { return; }
    let applyVirtualMouseStyle: boolean = false;
    try {
      const prefs = preferences.getPreferencesSync(getContext(this), { name: 'RemoteDesktopAppPrefs' });
      const restoreVersion: number = prefs.getSync(VIRTUAL_MOUSE_STYLE_RESTORE_VERSION_KEY, 0) as number;
      applyVirtualMouseStyle = shouldApplyCloudVirtualMouseStyle(restoreVersion);
      for (let i = 0; i < keys.length; i++) {
        const key: string = keys[i];
        if (key === 'virtualMouseStyle' && !applyVirtualMouseStyle) { continue; }
        const value = settings[key];
        prefs.putSync(key, value);
        AppStorage.setOrCreate(key, value);
      }
      prefs.flushSync();
    } catch (_e) { return; }
    const accent = settings['accentColor'];
    if (typeof accent === 'string') { this.accentColor = accent; }
    const liveEnabled = settings['liveViewEnabled'];
    if (typeof liveEnabled === 'boolean') { this.liveViewEnabled = liveEnabled; }
    const liveMode = settings['liveViewMode'];
    if (typeof liveMode === 'number' && liveMode >= 0 && liveMode <= 2) { this.liveViewMode = liveMode; }
    const syncedTheme = settings['currentTheme'];
    if (typeof syncedTheme === 'string' && (syncedTheme === 'light' || syncedTheme === 'dark')) {
      this.theme = syncedTheme;
      this.refreshHaloPresets();
      this.syncHaloColorForCurrentTheme();
    }
    const syncedVirtualMouseStyle = settings['virtualMouseStyle'];
    if (applyVirtualMouseStyle && typeof syncedVirtualMouseStyle === 'string') {
      this.virtualMouseStyle = normalizeRemoteCursorStyle(syncedVirtualMouseStyle);
      AppStorage.setOrCreate('virtualMouseStyle', this.virtualMouseStyle);
    }
  }

  private saveRustDeskImageQuality(mode: number): void {
    this.rustdeskImageQuality = mode >= 0 && mode <= 2 ? mode : 1;
    this.persistRustDeskNumberPref('rustdeskImageQuality', this.rustdeskImageQuality);
  }

  private saveRustDeskCodec(codec: number): void {
    this.rustdeskCodec = codec >= 0 && codec <= 5 ? codec : 0;
    this.persistRustDeskNumberPref('rustdeskCodec', this.rustdeskCodec);
  }

  private saveRustDeskDirectIp(on: boolean): void {
    this.rustdeskDirectIp = on;
    this.persistRustDeskBooleanPref('rustdeskDirectIp', this.rustdeskDirectIp);
  }

  private saveRustDeskDirectPort(port: number): void {
    const previousPort: number = this.rustdeskDirectPort;
    this.rustdeskDirectPort = port > 0 ? port : 21118;
    this.persistRustDeskNumberPref('rustdeskDirectPort', this.rustdeskDirectPort);
    if (this.rustdeskDirectPort === previousPort) { return; }
    const hosts: RemoteHost[] = this.srv.getAllHosts();
    for (let i: number = 0; i < hosts.length; i++) {
      const host: RemoteHost = hosts[i];
      if (!shouldAdoptRustDeskDirectPort(host.rustdeskDirectEnabled,
        host.rustdeskDirectPort, previousPort)) { continue; }
      const next: RemoteHost = RemoteHost.fromJSON(host.toJSON());
      next.rustdeskDirectPort = this.rustdeskDirectPort;
      next.port = this.rustdeskDirectPort;
      this.srv.updateHost(next);
    }
  }

  private saveFabAddStyle(style: string): void {
    this.fabAddStyle = style === 'classic' ? 'classic' : 'modern';
    // CloudSyncSettingsPolicy intentionally still whitelists this legacy key.
    this.persistPref('hostAddMode', this.fabAddStyle);
  }

  private saveVirtualMouseStyle(style: string): void {
    this.virtualMouseStyle = style === 'arrow' ? 'arrow' : 'circle';
    this.persistPref('virtualMouseStyle', this.virtualMouseStyle);
  }

  private saveRustDeskLanDiscovery(on: boolean): void {
    this.rustdeskLanDiscovery = on;
    this.persistRustDeskBooleanPref('rustdeskLanDiscovery', this.rustdeskLanDiscovery);
  }

  private startLanScan(): void {
    if (this.lanScanning) {
      return;
    }
    this.lanScanResults = [];
    this.lanScanning = true;
    this.lanDiscovery.startScan(5000, (peer: DiscoveredRustDeskPeer): void => {
      this.lanScanResults = this.lanScanResults.concat([peer]);
    }).then((peers: DiscoveredRustDeskPeer[]) => {
      this.lanScanResults = peers;
      this.lanScanning = false;
    });
  }

  private addLanPeer(peer: DiscoveredRustDeskPeer): void {
    // 从发现的设备创建 RustDesk Host: 预填直连配置
    this.label = peer.deviceName;
    this.proto = 'rustdesk';
    this.chn = peer.peerId;
    this.sheetPwdMode = 1;
    this.sheetRustdeskDirectEnabled = true;
    this.sheetRustdeskDirectHost = peer.host;
    this.sheetRustdeskDirectPort = peer.port;
    this.sheetPwd = '';
    this.sheetErr = '';
    this.selectedRelayId = '';
    this.selectedAccountId = '';
    this.selectedRdpCredentialId = '';
    this.editingHostId = '';
    this.openSheetSafely((): void => { this.showAddSheet = true; });
  }

  private saveRustDeskPrivacyMode(on: boolean): void {
    this.rustdeskPrivacyMode = on;
    this.persistRustDeskBooleanPref('rustdeskPrivacyMode', this.rustdeskPrivacyMode);
  }

  private saveRustDeskAudioEnabled(on: boolean): void {
    this.rustdeskAudioEnabled = on;
    this.persistRustDeskBooleanPref('rustdeskAudioEnabled', this.rustdeskAudioEnabled);
  }

  private saveRustDeskShowDiagnostics(on: boolean): void {
    this.rustdeskShowDiagnostics = on;
    this.persistLocalRustDeskBooleanPref('rustdeskShowDiagnostics', on);
  }

  private saveRustDeskShowProDiagnostics(on: boolean): void {
    if (on && !this.rustdeskShowDiagnostics) {
      this.rustdeskShowDiagnostics = true;
      this.persistLocalRustDeskBooleanPref('rustdeskShowDiagnostics', true);
    }
    this.rustdeskShowProDiagnostics = on;
    this.persistLocalRustDeskBooleanPref('rustdeskShowProDiagnostics', on);
  }

  private saveRustDeskClipboardEnabled(on: boolean): void {
    this.rustdeskClipboardEnabled = on;
    this.persistPref('rustdeskClipboardEnabled', this.rustdeskClipboardEnabled);
  }

  private saveRustDeskFilePasteEnabled(on: boolean): void {
    this.rustdeskFilePasteEnabled = on;
    this.persistPref('rustdeskFilePasteEnabled', this.rustdeskFilePasteEnabled);
  }

  /** Retain the legacy RustDesk key so existing wheel preferences migrate without data loss. */
  private saveRemoteReverseWheel(on: boolean): void {
    this.rustdeskReverseWheel = on;
    this.persistPref('rustdeskReverseWheel', on);
  }

  private saveRustDeskControlMode(mode: number): void {
    this.rustdeskControlMode = this.clampRustDeskControlMode(mode);
    this.persistRustDeskNumberPref('rustdeskControlMode', this.rustdeskControlMode);
  }

  private clampRustDeskControlMode(mode: number): number {
    return mode >= 0 && mode <= 2 ? mode : 0;
  }

  private clampRdpControlMode(mode: number): number {
    return mode >= 0 && mode <= 2 ? mode : 0;
  }

  private applyDesktopRdpInputMode(): void {
    if (this.isDesktopDevice && this.breakpoint === 'xl') {
      hilog.info(0x0001, 'HostList',
        'desktop RDP input mode respects user setting=' + this.rdpControlMode.toString());
    }
  }

  private applyDesktopRustDeskInputMode(): void {
    if (this.isDesktopDevice && this.breakpoint === 'xl') {
      hilog.info(0x0001, 'HostList',
        'desktop RustDesk input mode respects user setting=' + this.rustdeskControlMode.toString());
    }
  }

  private registerInputDeviceWatcher(): void {
    if (this.inputDeviceListenerRegistered) { return; }
    try {
      inputDevice.getDeviceList().then((ids: Array<number>): void => {
        this.inputDeviceBaselineIds = ids;
        hilog.info(0x0001, 'HostList', 'inputDevice baseline count=' + ids.length.toString());
      }).catch((err: Error): void => {
        hilog.warn(0x0001, 'HostList', 'inputDevice baseline unavailable: ' + JSON.stringify(err));
      });
      inputDevice.on('change', this.inputDeviceListener);
      this.inputDeviceListenerRegistered = true;
    } catch (err) {
      hilog.warn(0x0001, 'HostList', 'inputDevice watcher unavailable: ' + JSON.stringify(err));
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
        hilog.info(0x0001, 'HostList', 'ignore baseline inputDevice add id=' + deviceId.toString());
        return;
      }
      const device: inputDevice.InputDeviceData = await inputDevice.getDeviceInfo(deviceId);
      if (this.isKeyboardMouseDevice(device)) {
        this.promptSwitchToKeyboardMouseMode(device.name);
      }
    } catch (err) {
      hilog.warn(0x0001, 'HostList', 'inputDevice add ignored: ' + JSON.stringify(err));
    }
  }

  private promptSwitchToKeyboardMouseMode(deviceName: string): void {
    if (this.inputDevicePromptVisible || this.externalInputPromptedThisSession) {
      return;
    }
    if (this.rdpControlMode === 2 && this.rustdeskControlMode === 2) {
      return;
    }
    this.externalInputPromptedThisSession = true;
    this.inputDevicePromptVisible = true;
    const name: string = deviceName && deviceName.length > 0 ? deviceName : '键盘/鼠标';
    promptAction.showDialog({
      title: '检测到外接键鼠',
      message: '已检测到 ' + name + '，是否将 RDP 和 RustDesk 操控模式切换为键鼠模式？',
      buttons: [
        { text: '稍后', color: this.pal().text2 },
        { text: '切换', color: this.accentColor }
      ]
    }).then((result: Object): void => {
      this.inputDevicePromptVisible = false;
      const r: Record<string, number> = result as Record<string, number>;
      if (r['index'] === 1) {
        this.saveRdpControlMode(2);
        this.saveRustDeskControlMode(2);
        promptAction.showToast({ message: '已切换为键鼠模式', duration: 1500 });
      }
    }).catch((_err: Error): void => {
      this.inputDevicePromptVisible = false;
    });
  }

  private saveRdpDesktopPreset(preset: number): void {
    this.saveRdpDesktopResolutionId(normalizeRdpResolutionId('', preset));
  }

  private saveRustDeskRemoteAppTouchScaleEnabled(on: boolean): void {
    this.rustdeskRemoteAppTouchScaleEnabled = on;
    this.persistPref('rustdeskRemoteAppTouchScaleEnabled', on);
    if (on && this.canvasGestureZoomEnabled) {
      this.canvasGestureZoomEnabled = false;
      this.persistPref('canvasGestureZoomEnabled', false);
    }
  }

  private saveRdpDesktopResolutionId(resolutionId: string): void {
    this.rdpDesktopResolutionId = normalizeRdpResolutionId(resolutionId, this.rdpDesktopPreset);
    this.rdpDesktopPreset = legacyRdpPresetForResolutionId(this.rdpDesktopResolutionId);
    this.persistPref('rdpDesktopResolutionId', this.rdpDesktopResolutionId);
    this.persistPref('rdpDesktopPreset', this.rdpDesktopPreset);
  }

  private saveRemoteDisplayScaleMode(mode: string): void {
    this.remoteDisplayScaleMode = normalizeLocalViewScaleMode(mode);
    this.persistPref('remoteDisplayScaleMode', this.remoteDisplayScaleMode);
    this.persistPref(REMOTE_DISPLAY_SCALE_PREFERENCE_VERSION_KEY,
      REMOTE_DISPLAY_SCALE_PREFERENCE_VERSION);
  }

  private saveRemoteDisplayCustomScalePercent(value: string): void {
    const parsed: number = Number(value);
    if (!Number.isFinite(parsed)) {
      return;
    }
    this.remoteDisplayCustomScalePercent = Math.max(50, Math.min(300, Math.round(parsed)));
    this.persistPref('remoteDisplayCustomScalePercent', this.remoteDisplayCustomScalePercent);
    this.persistPref(REMOTE_DISPLAY_SCALE_PREFERENCE_VERSION_KEY,
      REMOTE_DISPLAY_SCALE_PREFERENCE_VERSION);
  }

  private saveCanvasGestureZoomEnabled(on: boolean): void {
    this.canvasGestureZoomEnabled = on;
    this.persistPref('canvasGestureZoomEnabled', on);
    if (on && this.rustdeskRemoteAppTouchScaleEnabled) {
      this.rustdeskRemoteAppTouchScaleEnabled = false;
      this.persistPref('rustdeskRemoteAppTouchScaleEnabled', false);
    }
  }

  private saveRdpColorDepth(depth: number): void {
    this.rdpColorDepth = depth === 16 || depth === 24 ? depth : 32;
    this.persistPref('rdpColorDepth', this.rdpColorDepth);
  }

  private saveRdpAudioEnabled(on: boolean): void {
    this.rdpAudioEnabled = on;
    this.persistPref('rdpAudioEnabled', this.rdpAudioEnabled);
  }

  private saveRdpClipboardEnabled(on: boolean): void {
    this.rdpClipboardEnabled = on;
    this.persistPref('rdpClipboardEnabled', this.rdpClipboardEnabled);
  }

  private saveRdpDriveEnabled(on: boolean): void {
    if (on && !RDP_DRIVE_REDIRECTION_ENABLED) {
      this.rdpDriveEnabled = false;
      this.persistPref('rdpDriveEnabled', false);
      promptAction.showToast({
        message: 'RDP 文件共享盘暂时停用，优先保证连接稳定',
        duration: 2400
      });
      return;
    }
    this.rdpDriveEnabled = on;
    this.persistPref('rdpDriveEnabled', this.rdpDriveEnabled);
  }

  private saveAmbientLightEffectEnabled(on: boolean): void {
    this.ambientLightEffectEnabled = on;
    this.persistPref('ambientLightEffectEnabled', on);
    this.syncAmbientLightMonitor();
  }

  private applyFollowSystemColorMode(): void {
    try {
      const ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
      this.followSystem = true;
      AppStorage.setOrCreate('followSystem', true);
      this.persistPref('followSystem', true);
      ctx.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
      setTimeout((): void => {
        this.syncFollowSystemTheme('toggle-on', false);
      }, 160);
    } catch (_e) {
      this.followSystem = true;
      AppStorage.setOrCreate('followSystem', true);
      this.persistPref('followSystem', true);
    }
  }

  private applyManualTheme(isDark: boolean, source: string): void {
    this.followSystem = false;
    AppStorage.setOrCreate('followSystem', false);
    this.persistPref('followSystem', false);
    this.theme = isDark ? 'dark' : 'light';
    AppStorage.setOrCreate('currentTheme', this.theme);
    this.persistPref('currentTheme', this.theme);
    this.setApplicationColorModeForTheme(this.theme, source);
    this.updateStatusBarForTheme(isDark);
  }

  private reapplyManualTheme(source: string): void {
    const theme: string = this.theme === 'dark' ? 'dark' : 'light';
    AppStorage.setOrCreate('currentTheme', theme);
    this.setApplicationColorModeForTheme(theme, source);
    this.updateStatusBarForTheme(theme === 'dark');
  }

  private setApplicationColorModeForTheme(theme: string, source: string): void {
    try {
      const ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
      ctx.getApplicationContext().setColorMode(
        theme === 'dark' ? ConfigurationConstant.ColorMode.COLOR_MODE_DARK
          : ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT
      );
      hilog.info(0x0000, 'HostListPage', 'manual app color mode source=' + source + ' theme=' + theme);
    } catch (err) {
      hilog.warn(0x0000, 'HostListPage', 'manual app color mode failed: ' + JSON.stringify(err));
    }
  }

  private syncAmbientLightMonitor(): void {
    this.lightSensing.offLightChange(this.lightChangeListener);
    if (shouldRunForegroundSensor(this.pageActive, this.appInBackground, this.ambientLightEffectEnabled)) {
      this.lightSensing.onLightChange(this.lightChangeListener);
      this.lightSensing.startMonitoring();
      this.ambientLightIntensity = this.lightSensing.getLightIntensity();
    } else {
      this.lightSensing.stopMonitoring();
    }
  }

  private normalizeRdpDriveName(value: string): string {
    let out: string = '';
    for (let i = 0; i < value.length && out.length < 20; i++) {
      const ch: string = value.charAt(i);
      const code: number = ch.charCodeAt(0);
      const alnum: boolean = (code >= 48 && code <= 57) || (code >= 65 && code <= 90) ||
        (code >= 97 && code <= 122);
      if (alnum || ch === '_' || ch === '-') {
        out += ch;
      } else if (ch === ' ' || ch === '.' || ch === '/' || ch === '\\') {
        out += '_';
      }
    }
    return out.length > 0 ? out : 'RemoteDesktop';
  }

  private saveRdpDriveName(name: string): void {
    this.rdpDriveName = this.normalizeRdpDriveName(name);
    this.persistPref('rdpDriveName', this.rdpDriveName);
  }

  private saveRdpControlMode(mode: number): void {
    this.rdpControlMode = this.clampRdpControlMode(mode);
    this.persistPref('rdpControlMode', this.rdpControlMode);
  }

  private saveRdpAuthIdentityMode(mode: number): void {
    this.rdpAuthIdentityMode = this.clampRdpAuthIdentityMode(mode);
    this.persistPref('rdpAuthIdentityMode', this.rdpAuthIdentityMode);
  }

  private clampRdpAuthIdentityMode(mode: number): number {
    return mode >= 0 && mode <= 4 ? mode : 1;
  }

  private rustdeskCodecLabel(): string {
    if (this.rustdeskCodec === 1) { return 'VP8'; }
    if (this.rustdeskCodec === 2) { return 'VP9'; }
    if (this.rustdeskCodec === 3) { return 'AV1'; }
    if (this.rustdeskCodec === 4) { return 'H264'; }
    if (this.rustdeskCodec === 5) { return 'H265'; }
    return '自动';
  }

  private getCurrentWallpaperColor(): string {
    const idx: number = this.wallpaperIdx;
    if (idx < this.wallpaperItems.length) { return this.wallpaperItems[idx].color; }
    return '#FFFFFF';
  }

  // 主题切换时更新光晕预设面板; 若用户未手动选色则自动匹配色系默认
  private onThemeChange(): void {
    this.syncHaloColorForCurrentTheme();
  }

  private syncWallpaperColor(): void {
    const c: string = this.getCurrentWallpaperColor();
    AppStorage.setOrCreate('wallpaperColor', c);
  }

  private async pickWallpaperPhoto(): Promise<void> {
    try {
      const options: photoAccessHelper.PhotoSelectOptions = new photoAccessHelper.PhotoSelectOptions();
      options.MIMEType = photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE;
      options.maxSelectNumber = 1;
      const pp: photoAccessHelper.PhotoViewPicker = new photoAccessHelper.PhotoViewPicker();
      const result: photoAccessHelper.PhotoSelectResult = await pp.select(options);
      if (result.photoUris.length > 0) {
        const newWall: WallpaperItem = { color: '#000000', uri: result.photoUris[0] };
        this.wallpaperItems.push(newWall);
        this.wallpaperIdx = this.wallpaperItems.length - 1;
        this.syncWallpaperColor();
      }
    } catch (err) { promptAction.showToast({ message: '未选择照片', duration: 1500 }); }
  }

  build() {
    Stack() {
      Column().width('100%').height('100%').backgroundColor(this.pal().bg)
      // SSH 前置校验 bindSheet 挂到独立空宿主, 避免主内容重建导致半模态消失。
      .bindSheet($$this.showSshPreflight, this.sshPreflightPanel(), {
        height: this.sshPreflightSheetHeight(),
        preferType: this.breakpoint === 'sm' ? SheetType.BOTTOM : SheetType.CENTER,
        dragBar: this.breakpoint === 'sm',
        backgroundColor: this.pal().sheetBg,
        blurStyle: BlurStyle.NONE,
        showClose: false,
        maskColor: 'rgba(0,0,0,0.4)',
        onWillDismiss: (action: DismissSheetAction): void => { this.handleSshPreflightSheetDismiss(action); },
        onDisappear: (): void => { this.noteSheetDismissed(); }
      })

      Column().width('100%').height('100%').hitTestBehavior(HitTestMode.None)
      .bindSheet($$this.showRdpCertificatePreflight, this.rdpCertificatePanel(), {
        height: SheetSize.FIT_CONTENT,
        preferType: this.breakpoint === 'sm' ? SheetType.BOTTOM : SheetType.CENTER,
        dragBar: this.breakpoint === 'sm',
        backgroundColor: this.pal().sheetBg,
        blurStyle: BlurStyle.NONE,
        showClose: false,
        maskColor: 'rgba(0,0,0,0.4)',
        onWillDismiss: (action: DismissSheetAction): void => { this.handleRdpCertificateSheetDismiss(action); },
        onDisappear: (): void => { this.handleRdpCertificateSheetDisappear(); }
      })

      Column().width('100%').height('100%').hitTestBehavior(HitTestMode.None)
      .bindSheet($$this.showRustDeskProPreflight, this.rustDeskProPreflightPanel(), {
        height: SheetSize.FIT_CONTENT,
        preferType: this.breakpoint === 'sm' ? SheetType.BOTTOM : SheetType.CENTER,
        dragBar: this.breakpoint === 'sm',
        backgroundColor: this.pal().sheetBg,
        blurStyle: BlurStyle.NONE,
        showClose: false,
        maskColor: 'rgba(0,0,0,0.4)',
        onWillDismiss: (action: DismissSheetAction): void => {
          if (this.rustDeskProPreflightClosing || this.rustDeskProPreflightPendingRouteParams !== null) {
            return;
          }
          if (this.rustDeskProPreflightState !== RustDeskProPreflightState.CONNECTING) {
            this.cancelRustDeskProPreflight();
            action.dismiss();
          }
        },
        onDisappear: (): void => { this.handleRustDeskProPreflightDisappear(); }
      })

      Column().width('100%').height('100%').hitTestBehavior(HitTestMode.None)
      // 旧路径私钥密码 Sheet 使用独立宿主, 不与 SSH preflight 共用 bindSheet 链。
      .bindSheet($$this.showPassphraseSheet, this.hlPassphraseBuilder(), {
        height: SheetSize.FIT_CONTENT,
        preferType: this.breakpoint === 'sm' ? SheetType.BOTTOM : SheetType.CENTER,
        dragBar: this.breakpoint === 'sm',
        backgroundColor: this.pal().sheetBg,
        blurStyle: BlurStyle.NONE,
        showClose: false,
        maskColor: 'rgba(0,0,0,0.4)',
        onWillDismiss: (action: DismissSheetAction): void => {
          if (this.hlPassphraseResolve) {
            this.hlPassphraseResolve('');
            this.hlPassphraseResolve = null;
          }
          action.dismiss();
        },
        onDisappear: (): void => { this.noteSheetDismissed(); }
      })
      Column().width('100%').height('100%').hitTestBehavior(HitTestMode.None)
      .bindSheet($$this.showSshPublicKeyInstallSheet, this.sshPublicKeyInstallPanel(), {
        height: SheetSize.FIT_CONTENT,
        preferType: this.breakpoint === 'sm' ? SheetType.BOTTOM : SheetType.CENTER,
        dragBar: this.breakpoint === 'sm',
        backgroundColor: this.pal().sheetBg,
        blurStyle: BlurStyle.NONE,
        showClose: false,
        maskColor: 'rgba(0,0,0,0.4)',
        onWillDismiss: (action: DismissSheetAction): void => {
          if (!this.sshPublicKeyInstallBusy) { this.closeSshPublicKeyInstallSheet(); action.dismiss(); }
        },
        onDisappear: (): void => {
          this.resetSshPublicKeyInstallSheetState();
          this.noteSheetDismissed();
        }
      })
      Column().width('100%').height('100%').hitTestBehavior(HitTestMode.None)
      .bindSheet($$this.showSettingsLeafSheet, this.settingsLeafSheet(), {
        height: SheetSize.FIT_CONTENT,
        preferType: this.breakpoint === 'sm' ? SheetType.BOTTOM : SheetType.CENTER,
        dragBar: this.breakpoint === 'sm',
        backgroundColor: this.pal().sheetBg,
        blurStyle: BlurStyle.NONE,
        showClose: settingsLeafSheetUsesSystemCloseButton(),
        maskColor: 'rgba(0,0,0,0.4)',
        onDisappear: (): void => {
          this.handleSettingsLeafSheetDisappear();
        }
      })
      Column() {
        Column()
          .width('100%').height('100%')
          .backgroundColor(this.getCurrentWallpaperColor())
          .position({ x: 0, y: 0 }).opacity(this.theme === 'dark' ? 0.20 : 1.0)

        if (this.isDesktopDevice && this.breakpoint === 'xl') {
          // PC/2in1 全屏: 手搓5选项卡侧边栏 + 内容区
          // PC/2in1 小窗口: 走 else 分支 (旧版底部 Tab UI)
          Row() {
            Column() {
              Row().width('100%').height(44)
              Column() {
                this.sidebarTab('RDP 远程桌面', $rawfile('icons/computer-desktop.svg'), 0)
                this.sidebarTab('RustDesk', $rawfile('icons/globe-alt.svg'), 1)
                this.sidebarTab('SSH 终端', $rawfile('icons/command-line.svg'), 2)
                this.sidebarTab('密钥保险库', $rawfile('icons/key.svg'), 3)
                this.sidebarTab('2FA 验证器', $rawfile('icons/shield-check.svg'), 4)
                this.sidebarRelayTab('中继服务器', 5)
              }.layoutWeight(1).padding({ top: 24 })
              // 设置
              this.sidebarSettingsBtn()
            }
            .width(300).height('100%')
            .backgroundColor(this.pal().card).backgroundBlurStyle(BlurStyle.Regular)
            .border({ width: { right: 0.5 }, color: this.pal().divider })

            // 主内容区 (hostContent 使用 updateHostFilter 预过滤的数据源)
            Column() {
              if (this.curTab <= 2) { this.hostContent() }
              else if (this.curTab === 5) { this.relayContent() }
              else { this.keyVaultContent() }
            }.layoutWeight(1).height('100%')
          }
          .width('100%').height('100%')
        } else {
          // 手机/Pad: 沉浸光感悬浮底栏 (禁止左右滑动切换)
          HdsTabs({ controller: this.tabsCtrl }) {
            TabContent() { this.hostContent() }
              .focusable(false)
              .tabBar(this.tabHostIcon)
            TabContent() { this.keyVaultContent() }
              .focusable(false)
              .tabBar(this.tabKeyVaultIcon)
            TabContent() { this.relayContent() }
              .focusable(false)
              .tabBar(this.tabRelayIcon)
            TabContent() { this.settingsContent() }
              .focusable(false)
              .tabBar(this.tabSettingsIcon)
          }
          .barOverlap(true)
          .priorityGesture(PanGesture({ direction: PanDirection.Horizontal, distance: 10 }))
          .barPosition(BarPosition.End).vertical(false).barHeight(64)
          .barFloatingStyle({
            // 交给 HDS 根据 Tab 数量、容器宽度和断点计算官方宽度/侧距。
            barBottomMargin: 28,
            gradientMask: {
              maskColor: this.haloMaskColor(),
              maskHeight: 92
            },
            systemMaterialEffect: {
              materialType: hdsMaterial.MaterialType.IMMERSIVE,
              materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE
            },
            adaptToHandedness: true
          })
          .divider({ mode: DividerMode.FOLLOW_SCROLL })
          .animationDuration(300)
          .onChange((i: number) => {
            this.curTab = i;
            this.lastScrollY = 0;
            if (this.tabBarHidden) {
              animateTo({ duration: 300, curve: curves.interpolatingSpring(0, 1, 200, 17) }, () => {
                this.tabBarHidden = false;
              });
            }
          })
          .width('100%').height('100%')
        }
      }.width('100%').height('100%')

      // FAB — 智感握姿悬浮加号按钮
      // 官方推荐: 对齐驱动 (justifyContent) 而非 translate, .animation() 保证弹簧动画可靠触发
      Row() {
        Button() {
          SymbolGlyph($r('sys.symbol.plus'))
            .fontSize(28)
            .fontColor([Color.White])
        }
        .width(this.breakpoint === 'xl' ? 64 : 56)
        .height(this.breakpoint === 'xl' ? 64 : 56)
        .borderRadius(this.breakpoint === 'xl' ? 32 : 28).padding(0)
        .backgroundColor(this.accentColor)
        .onClick(() => {
          if (this.isDesktopDevice && this.breakpoint === 'xl') {
            // PC 全屏侧边栏: RDP/RustDesk/SSH/密钥/2FA/中继
            if (this.curTab <= 2) {
              this.resetForm();
              const nextProto: string = this.activeFilterProto !== '' ? this.activeFilterProto : 'rdp';
              this.switchHostProtocol(nextProto, RemoteHost.getDefaultPort(nextProto));
              this.addSheetShowsModernPicker =
                resolveFabAddStyle(this.fabAddStyle, this.isDesktopDevice) === 'modern';
              this.modernAddProtocol = '';
              this.openSheetSafely((): void => { this.showAddSheet = true; });
            } else if (this.curTab === 3) {
              this.kvAddTrigger++;
            } else if (this.curTab === 4) {
              this.keyVaultInnerTab = 1;
              this.kvAddTrigger++;
            } else if (this.curTab === 5) {
              this.relayAddTrigger++;
            }
          } else {
            // 手机/平板/PC小窗: 主机/密钥/中继/设置
            if (this.curTab === 0) {
              this.resetForm();
              this.addSheetShowsModernPicker =
                resolveFabAddStyle(this.fabAddStyle, this.isDesktopDevice) === 'modern';
              this.modernAddProtocol = '';
              this.openSheetSafely((): void => { this.showAddSheet = true; });
            }
            if (this.curTab === 1) { this.kvAddTrigger++; }
            if (this.curTab === 2) { this.relayAddTrigger++; }
          }
        })
        .bindSheet($$this.showAddSheet, this.hostAddSheetContent(), {
          height: SheetSize.FIT_CONTENT,
          preferType: this.breakpoint === 'sm' ? SheetType.BOTTOM : SheetType.CENTER,
          dragBar: false,
          backgroundColor: this.pal().sheetBg,
          blurStyle: BlurStyle.NONE,
          showClose: false,
          onDisappear: () => {
            this.handleAddSheetDisappear();
          }
        })
      }
      .width('100%')
      .padding({ left: this.fabEdgePadding(), right: this.fabEdgePadding() })
      .justifyContent(shouldUseGripFabAlignment(this.isDesktopDevice, this.breakpoint) ? this.getFabAlignment() : FlexAlign.Start)
      .position({ x: 0, y: '100%' })
      .markAnchor({ x: 0, y: '100%' })
      .translate({ y: (!this.isDesktopDevice && this.curTab === 3 ? 120 : (this.breakpoint === 'sm' ? -120 : -100)) })
      .opacity((!this.isDesktopDevice && this.curTab === 3) ? 0 : 1)
      .animation({ curve: curves.interpolatingSpring(0, 1, 200, 17) })
    }.width('100%').height('100%').backgroundColor(this.pal().bg)
    .bindSheet($$this.showSettingsPanel, this.settingsContent(), {
      height: this.breakpoint === 'xl' ? 760 : SheetSize.FIT_CONTENT,
      preferType: this.breakpoint === 'sm' ? SheetType.BOTTOM : SheetType.CENTER,
      dragBar: false,
      backgroundColor: this.pal().sheetBg,
      blurStyle: BlurStyle.Regular,
      showClose: true,
      maskColor: Color.Transparent,
      onDisappear: (): void => {
        this.noteSheetDismissed();
        this.refreshCryptoStatus();
      }
    })
  }


  // ==================== 悬浮栏 Tab 图标 (华为官方Symbol + 主题色绑定) ====================
  @Builder tabHostIcon() {
    Column() {
      SymbolGlyph($r('sys.symbol.house_fill'))
        .fontSize(this.breakpoint === 'xl' ? 22 : 24)
        .fontColor([this.curTab === 0 ? this.accentColor : this.pal().text3])
      if (this.breakpoint === 'xl') {
        Text('远程主机').fontSize(11).fontColor(this.curTab === 0 ? this.accentColor : this.pal().text3)
          .margin({ top: 4 })
      }
    }.alignItems(HorizontalAlign.Center)
  }
  @Builder tabKeyVaultIcon() {
    Column() {
      SymbolGlyph($r('sys.symbol.key_fill'))
        .fontSize(this.breakpoint === 'xl' ? 22 : 24)
        .fontColor([this.curTab === 1 ? this.accentColor : this.pal().text3])
      if (this.breakpoint === 'xl') {
        Text('密钥保险库').fontSize(11).fontColor(this.curTab === 1 ? this.accentColor : this.pal().text3)
          .margin({ top: 4 })
      }
    }.alignItems(HorizontalAlign.Center)
  }
  @Builder tabRelayIcon() {
    Column() {
      SymbolGlyph($r('sys.symbol.cloud_fill'))
        .fontSize(this.breakpoint === 'xl' ? 22 : 24)
        .fontColor([this.curTab === 2 ? this.accentColor : this.pal().text3])
      if (this.breakpoint === 'xl') {
        Text('中继').fontSize(11).fontColor(this.curTab === 2 ? this.accentColor : this.pal().text3).margin({ top: 4 })
      }
    }.alignItems(HorizontalAlign.Center)
  }
  @Builder tabSettingsIcon() {
    Column() {
      SymbolGlyph($r('sys.symbol.gearshape_fill'))
        .fontSize(this.breakpoint === 'xl' ? 22 : 24)
        .fontColor([this.curTab === 3 ? this.accentColor : this.pal().text3])
      if (this.breakpoint === 'xl') {
        Text('设置').fontSize(11).fontColor(this.curTab === 3 ? this.accentColor : this.pal().text3)
          .margin({ top: 4 })
      }
    }.alignItems(HorizontalAlign.Center)
  }

  // ==================== 主机列表 ====================
  // PC 侧边栏 Tab 按钮
  @Builder sidebarTab(label: string, icon: ResourceStr, index: number) {
    Row() {
      Image(icon).width(28).height(28)
        .fillColor(this.curTab === index ? this.accentColor : this.pal().text3)
      Text(label)
        .fontSize(16).fontWeight(FontWeight.Medium)
        .fontColor(this.curTab === index ? this.accentColor : this.pal().text3)
        .fontFamily(this.font()).margin({ left: 14 })
    }
    .width('100%').height(56).padding({ left: 24, right: 24 })
    .borderRadius(12).margin({ left: 12, right: 12, bottom: 4 })
    .backgroundColor(this.curTab === index ? this.pal().surface : Color.Transparent)
    .onClick(() => {
      this.curTab = index;
      if (this.isDesktopDevice) {
        const titles: string[] = ['RDP 远程主机', 'RustDesk 远程主机', 'SSH 终端', '', '', '中继服务器'];
        this.hostPageTitle = titles[index] || '';
        if (index === 3) { this.keyVaultInnerTab = 0; }
        if (index === 4) { this.keyVaultInnerTab = 1; }
      }
      this.updateHostFilter();
    })
  }

  @Builder sidebarRelayTab(label: string, index: number) {
    Row() {
      SymbolGlyph($r('sys.symbol.cloud_fill'))
        .fontSize(28)
        .fontColor([this.curTab === index ? this.accentColor : this.pal().text3])
      Text(label)
        .fontSize(16).fontWeight(FontWeight.Medium)
        .fontColor(this.curTab === index ? this.accentColor : this.pal().text3)
        .fontFamily(this.font()).margin({ left: 14 })
    }
    .width('100%').height(56).padding({ left: 24, right: 24 })
    .borderRadius(12).margin({ left: 12, right: 12, bottom: 4 })
    .backgroundColor(this.curTab === index ? this.pal().surface : Color.Transparent)
    .onClick(() => {
      this.curTab = index;
      if (this.isDesktopDevice) {
        const titles: string[] = ['RDP 远程主机', 'RustDesk 远程主机', 'SSH 终端', '', '', '中继服务器'];
        this.hostPageTitle = titles[index] || '';
      }
      this.updateHostFilter();
    })
  }

  @Builder sidebarSettingsBtn() {
    Row() {
      Image($rawfile('icons/cog-6-tooth.svg')).width(28).height(28)
        .fillColor(this.pal().text3)
      Text('设置')
        .fontSize(16).fontWeight(FontWeight.Medium)
        .fontColor(this.pal().text3)
        .fontFamily(this.font()).margin({ left: 14 })
    }
    .width('100%').height(56).padding({ left: 24, right: 24 })
    .borderRadius(12).margin({ left: 12, right: 12, bottom: 16 })
    .onClick(() => {
      this.showSettingsPanel = false;
      this.openSheetSafely((): void => { this.showSettingsPanel = true; });
    })
  }

  private activeFilterProto: string = '';

  private updateHostFilter(): void {
    this.activeFilterProto = this.isDesktopDevice && this.breakpoint === 'xl' ?
      hostListProtocolForTab(this.curTab) : '';
    this.filteredHosts = this.visibleHostsForCurrentMode();
    this.hostDataSource.replaceAll(this.filteredHosts);
  }

  private refreshWorkspaceView(): void {
    this.filteredHosts = this.visibleHostsForCurrentMode();
    this.hostDataSource.replaceAll(this.filteredHosts);
  }

  @Builder HostWorkspaceFilterBar() {
    Column() {
      Row() {
        ForEach(groupIdsForHosts(this.hosts), (groupId: string): void => {
          Text(groupId).fontSize(12)
            .fontColor(this.workspaceGroupId === groupId ? this.accentColor : this.pal().text2)
            .margin({ right: 12 })
            .onClick((): void => {
              this.workspaceGroupId = nextWorkspaceGroupId(this.workspaceGroupId, groupId);
              this.refreshWorkspaceView();
            })
        }, (groupId: string): string => groupId)
      }
      .width('100%').padding({ left: 4, right: 4 })
    }
    .width('100%').padding({ left: 16, right: 16, top: 4, bottom: 6 })
  }

  @Builder HostGroupChip(host: RemoteHost) {
    if (host.groupId.length > 0) {
      Text(host.groupId)
        .fontSize(11).fontColor(this.accentColor)
        .padding({ left: 6, right: 6, top: 2, bottom: 2 })
        .borderRadius(6).backgroundColor(this.pal().surface)
    }
  }

  @Builder HostConnectionHealth(host: RemoteHost) {
    if (displayConnectionHealth(host.lastHealth, host.lastLatency).length > 0) {
      Text(displayConnectionHealth(host.lastHealth, host.lastLatency))
        .fontSize(11).fontColor(this.pal().text3).margin({ top: 3 })
    }
  }

  @Builder hostContent() {
    Column() {
      Stack() {
        List({ space: 8 }) {
          // 顶栏占位: 跟随真实系统避让区, 与渐变玻璃层高度一致
          ListItem() { Column().height(this.hostTopBarHeight() + 8) }
          ListItem() { this.HostWorkspaceFilterBar() }

        // 批量选择工具栏 (带出入动画)
        if (this.hostSelectionMode) {
          ListItem() {
            // desktop: 按钮全部左移 (侧边栏右侧); 手机/平板: 两端分布
            if (this.isDesktopDevice) {
              Row() {
                Button(this.hostSelectedIds.size === this.filteredHosts.length ? '取消全选' : '全选').fontSize(12)
                  .height(32).borderRadius(8)
                  .backgroundColor(this.pal().surface).fontColor(this.accentColor)
                  .onClick(() => {
                    if (this.hostSelectedIds.size === this.filteredHosts.length) { this.hostSelectedIds = new Set(); }
                    else { this.hostSelectedIds = new Set(this.filteredHosts.map((h: RemoteHost) => h.id)); }
                  })
                Text('已选 ' + this.hostSelectedIds.size).fontSize(13).fontColor(this.pal().text2)
                  .margin({ left: 12, right: 12 })
                if (this.hostSelectedIds.size > 0) {
                  Button('删除(' + this.hostSelectedIds.size + ')').fontSize(12)
                    .height(32).borderRadius(8)
                    .backgroundColor(this.pal().danger).fontColor('#FFFFFF')
                    .margin({ right: 6 })
                    .onClick(() => { this.doHostBatchDelete(); })
                }
                Button('取消').fontSize(12)
                  .height(32).borderRadius(8)
                  .backgroundColor(this.pal().surface).fontColor(this.pal().text2)
                  .onClick(() => {
                    animateTo({ duration: 200, curve: Curve.FastOutSlowIn }, () => {
                      this.hostSelectionMode = false; this.hostSelectedIds = new Set();
                    });
                  })
              }.width('100%').padding({ left: 20, right: 20, bottom: 6 })
                .transition(
                  TransitionEffect.asymmetric(
                    TransitionEffect.translate({ y: -40 }).combine(TransitionEffect.OPACITY)
                      .animation({ duration: 250, curve: Curve.FastOutSlowIn }),
                    TransitionEffect.translate({ y: -40 }).combine(TransitionEffect.OPACITY)
                      .animation({ duration: 200, curve: Curve.FastOutSlowIn })
                  )
                )
            } else {
              Row() {
                Button(this.hostSelectedIds.size === this.filteredHosts.length ? '取消全选' : '全选').fontSize(12)
                  .height(32).borderRadius(8)
                  .backgroundColor(this.pal().surface).fontColor(this.accentColor)
                  .onClick(() => {
                    if (this.hostSelectedIds.size === this.filteredHosts.length) { this.hostSelectedIds = new Set(); }
                    else { this.hostSelectedIds = new Set(this.filteredHosts.map((h: RemoteHost) => h.id)); }
                  })
                Blank()
                Text('已选 ' + this.hostSelectedIds.size).fontSize(13).fontColor(this.pal().text2)
                Blank()
                if (this.hostSelectedIds.size > 0) {
                  Button('删除(' + this.hostSelectedIds.size + ')').fontSize(12)
                    .height(32).borderRadius(8)
                    .backgroundColor(this.pal().danger).fontColor('#FFFFFF')
                    .margin({ right: 6 })
                    .onClick(() => { this.doHostBatchDelete(); })
                }
                Button('取消').fontSize(12)
                  .height(32).borderRadius(8)
                  .backgroundColor(this.pal().surface).fontColor(this.pal().text2)
                  .onClick(() => {
                    animateTo({ duration: 200, curve: Curve.FastOutSlowIn }, () => {
                      this.hostSelectionMode = false; this.hostSelectedIds = new Set();
                    });
                  })
              }.width('100%').padding({ left: 20, right: 20, bottom: 6 })
                .transition(
                  TransitionEffect.asymmetric(
                    TransitionEffect.translate({ y: -40 }).combine(TransitionEffect.OPACITY)
                      .animation({ duration: 250, curve: Curve.FastOutSlowIn }),
                    TransitionEffect.translate({ y: -40 }).combine(TransitionEffect.OPACITY)
                      .animation({ duration: 200, curve: Curve.FastOutSlowIn })
                  )
                )
            }
          }
        }

        if (this.isLoading) {
          ListItem() {
            Column() { LoadingProgress().width(32).height(32).color(this.accentColor) }
            .width('100%').height(300).justifyContent(FlexAlign.Center)
          }
        } else if (this.filteredHosts.length === 0) {
          ListItem() {
            Column() {
              SymbolGlyph($r('sys.symbol.desktop_fill'))
                .fontSize(48).fontColor([this.pal().text3])
              Text('还没有远程主机')
                .fontSize(17).fontWeight(FontWeight.Medium).fontColor(this.pal().text).fontFamily(this.font())
                .margin({ top: 16 })
              Text('点击底部 + 添加远程主机')
                .fontSize(13).fontColor(this.pal().text3).fontFamily(this.font())
                .margin({ top: 6 }).lineHeight(20)
            }.width('100%').constraintSize({ minHeight: 400 }).justifyContent(FlexAlign.Center)
              .alignItems(HorizontalAlign.Center)
          }
        } else {
          LazyForEach(this.hostDataSource, (host: RemoteHost, idx: number) => {
            ListItem() {
              Row() {
                if (this.hostSelectionMode) {
                  Checkbox()
                    .select(this.hostSelectedIds.has(host.id))
                    .selectedColor(this.accentColor)
                    .margin({ right: 8 })
                    .onChange((v: boolean) => { this.toggleHostSelect(host.id, v); })
                }
                // 协议图标 (sm: 42 circle, md+: 46 rounded)
                Column() {
                  Image(host.protocol === 'ssh' ? $r('app.media.icon_terminal') :
                    (host.protocol === 'rdp' ? $r('app.media.icon_desktop') : $r('app.media.icon_laptop')))
                    .width(this.breakpoint === 'sm' ? 24 : 26)
                    .height(this.breakpoint === 'sm' ? 24 : 26).fillColor(Color.White)
                }
                .width(this.breakpoint === 'sm' ? 42 : 46)
                .height(this.breakpoint === 'sm' ? 42 : 46)
                .borderRadius(this.breakpoint === 'sm' ? 21 : 14)
                .backgroundColor(host.protocol === 'ssh' ? this.pal().editColor :
                  (host.protocol === 'rdp' ? this.accentColor : this.pal().success))
                .justifyContent(FlexAlign.Center)
                .margin({ right: this.breakpoint === 'sm' ? 10 : 12 })
                .onClick(() => { this.handleHostCardClick(host); })

                // 主机信息 (sm: old smaller, md+: new larger)
                Column() {
                  Row() {
                    Text(host.label)
                      .fontSize(this.breakpoint === 'sm' ? (AppTheme.fontSize.body as number) : 17)
                      .fontWeight(FontWeight.Medium)
                      .fontColor(this.pal().text).fontFamily(this.font()).layoutWeight(1)
                    if (host.protocol === 'rustdesk') {
                      ForEach(resolveRustDeskBadges(host.rustdeskDirectEnabled,
                        host.rustdeskProManaged || host.sourceType === 'rustdesk_pro'), (badge: string) => {
                        Text(badge).fontSize(10)
                          .fontColor(badge === 'Pro' ? this.accentColor :
                            (badge === '直连' ? this.pal().success : this.pal().text2))
                          .fontFamily(this.font()).padding({ left: 6, right: 6, top: 2, bottom: 2 })
                          .borderRadius(6).backgroundColor(this.pal().surface).margin({ left: 6 })
                      })
                    }
                    if (host.protocol === 'ssh' &&
                      displayConnectionHealth(host.lastHealth, host.lastLatency).length > 0) {
                      Text(displayConnectionHealth(host.lastHealth, host.lastLatency))
                        .fontSize(10).fontColor(this.pal().text3).fontFamily(this.font())
                        .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                        .borderRadius(6).backgroundColor(this.pal().surface).margin({ left: 6 })
                    }
                    if (host.locked) {
                      SymbolGlyph($r('sys.symbol.ohos_lock'))
                        .fontSize(this.breakpoint === 'sm' ? 14 : 18)
                        .fontColor([this.pal().danger])
                        .margin({ left: this.breakpoint === 'sm' ? 6 : 8 })
                    }
                  }
                  if (!host.locked) {
                    Text(this.hostPlatformText(host) + '  ·  ' +
                      (host.protocol === 'rustdesk' ? rustDeskCardEndpoint(host.rustdeskDirectEnabled,
                        host.rustdeskDirectHost, host.rustdeskDirectPort, host.host, host.port) :
                        host.host + ':' + host.port))
                      .fontSize(this.breakpoint === 'sm' ? 12 : 14)
                      .fontColor(this.pal().text2).margin({ top: this.breakpoint === 'sm' ? 3 : 4 })
                      .fontFamily(this.font())
                  } else {
                    Text('已锁定 · 需验证')
                      .fontSize(this.breakpoint === 'sm' ? 12 : 13)
                      .fontColor(this.pal().text3).margin({ top: this.breakpoint === 'sm' ? 3 : 4 })
                      .fontFamily(this.font())
                  }
                  Row() {
                    this.HostGroupChip(host)
                    if (host.groupId.length > 0) {
                      Blank().width(6)
                    }
                    if (host.protocol !== 'ssh') {
                      this.HostConnectionHealth(host)
                    }
                  }
                  .margin({ top: 2 })
                }
                .alignItems(HorizontalAlign.Start).layoutWeight(1)
                .onClick(() => {
                  if (this.hostSelectionMode) { this.toggleHostSelect(host.id, !this.hostSelectedIds.has(host.id)); }
                  else { this.connectToHost(host); }
                })

                // PC/2in1: 省略号按钮 → bindPopup 气泡弹窗 (编辑/上锁/多选/删除)
                if (this.isDesktopDevice && !this.hostSelectionMode) {
                  Button() {
                    Text('⋯')
                      .fontSize(18)
                      .fontColor(this.pal().text)
                  }
                  .width(36).height(36).borderRadius(18)
                  .backgroundColor(this.pal().surface)
                  .margin({ left: 4 })
                  .bindPopup(this.hostActionPopupId === host.id, {
                    builder: this.hostActionMenuBuilder(host),
                    placement: Placement.BottomRight,
                    enableArrow: true,
                    popupColor: this.pal().card,
                    onStateChange: (e: Object) => {
                      const ev: Record<string, boolean> = e as Record<string, boolean>;
                      if (!ev['isVisible']) { this.hostActionPopupId = ''; }
                    }
                  })
                  .onClick(() => {
                    animateTo({ duration: 200, curve: Curve.FastOutSlowIn }, () => {
                      this.hostActionPopupId = (this.hostActionPopupId === host.id ? '' : host.id);
                    });
                  })
                }
              }
              .width('100%').constraintSize({ minHeight: this.breakpoint === 'sm' ? 66 : 80 })
              .padding(this.breakpoint === 'sm' ? { left: 12, right: 14, top: 12, bottom: 12 } : 14)
              .borderRadius(14).backgroundColor(this.pal().card).backgroundBlurStyle(BlurStyle.Regular)
              .border({ width: 0.5, color: this.pal().cardBorder, style: BorderStyle.Solid })
            }
            .gesture(
              LongPressGesture().onAction(() => {
                if (!this.hostSelectionMode) {
                  animateTo({ duration: 250, curve: Curve.FastOutSlowIn }, () => {
                    this.hostSelectionMode = true; this.hostSelectedIds = new Set(); this.hostSelectedIds.add(host.id);
                  });
                }
              })
            )
            .swipeAction((this.hostSelectionMode || this.isDesktopDevice) ? {
              start: { builder: () => {} }, end: { builder: () => {} }, edgeEffect: SwipeEdgeEffect.Spring
            } : {
              start: { builder: () => { this.hostEditLockRow(host); } },
              end: { builder: () => { this.hostDeleteBtn(host); } },
              edgeEffect: SwipeEdgeEffect.Spring
            })
            .transition(
              TransitionEffect.asymmetric(
                TransitionEffect.translate({ x: -200 })
                  .animation({ duration: 250, curve: Curve.FastOutSlowIn }),
                TransitionEffect.translate({ x: -200, y: -10 })
                  .combine(TransitionEffect.scale({ x: 0.7, y: 0.7 }))
                  .combine(TransitionEffect.OPACITY)
                  .animation({ duration: 350, curve: curves.interpolatingSpring(0, 0.8, 300, 20) })
              )
            )
          }, (host: RemoteHost, idx: number) => host.id + ':' + this.hostViewRevision.toString())
        }

        // 底部 FAB 占位
        ListItem() { Column().height(140) }
      }
        .width('100%').height('100%')
        .padding({ left: 16, right: 16, top: 0, bottom: 0 })
        .scrollBar(BarState.Off).edgeEffect(EdgeEffect.Spring)
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP])
        .onScrollFrameBegin((offset: number, _state: ScrollState) => {
          this.handleScrollDirection(offset);
          return { offsetRemain: offset };
        })
        .onReachEnd(() => {
          if (this.tabBarHidden) {
            animateTo({ duration: 300, curve: curves.interpolatingSpring(0, 1, 200, 17) }, () => {
              this.tabBarHidden = false;
            });
          }
        })
        .onReachStart(() => {
          if (this.tabBarHidden) {
            animateTo({ duration: 300, curve: curves.interpolatingSpring(0, 1, 200, 17) }, () => {
              this.tabBarHidden = false;
            });
          }
        })

        // 沉浸顶栏 — Stack内绝对定位, 标题穿透, 搜索栏可交互
        Column() {
          Column() {
            Row().width('100%').height(this.topSafeHeightVp() + this.titleOffsetY())
            Row() {
              Text(this.hostPageTitle).fontSize(27).fontWeight(FontWeight.Bold)
                .fontColor(this.pal().text).fontFamily(this.font())
              Blank()
            }.width('100%').padding({ left: 24, right: 24, bottom: 8 })
          }
          .width('100%').backgroundColor(Color.Transparent)

          // xl: 搜索框右上角; 非xl: 居中
          if (this.breakpoint === 'xl') {
            Row() {
              Blank()
              Row() {
                Text('⌕').fontSize(18).fontColor(this.pal().text3).margin({ left: 14, right: 8 })
                TextInput({ placeholder: '搜索主机...', text: this.searchText })
                  .backgroundColor(Color.Transparent).height(40)
                  .fontColor(this.pal().text).placeholderColor(this.pal().text3)
                  .fontFamily(this.font()).layoutWeight(1)
                  .onChange((v: string) => { this.onSearchChange(v); })
                if (this.searchText !== '') {
                  Text('✕').fontSize(14).fontColor(this.pal().text3).margin({ right: 14 })
                    .onClick(() => {
                      this.searchText = '';
                      this.filteredHosts = this.visibleHostsForCurrentMode();
                      this.hostDataSource.replaceAll(this.filteredHosts);
                    })
                }
              }.width('50%').constraintSize({ maxWidth: 480 })
                .height(44).borderRadius(22)
                .backgroundColor(this.pal().card).backgroundBlurStyle(BlurStyle.Regular)
                .alignItems(VerticalAlign.Center)
                .shadow({ radius: 12, color: 'rgba(0,0,0,0.06)', offsetY: 2 })
                .border({ width: 0.5, color: this.pal().cardBorder, style: BorderStyle.Solid })
            }.width('100%')
          } else {
            Row() {
              Text('⌕').fontSize(18).fontColor(this.pal().text3).margin({ left: 14, right: 8 })
              TextInput({ placeholder: '搜索主机...', text: this.searchText })
                .backgroundColor(Color.Transparent).height(40)
                .fontColor(this.pal().text).placeholderColor(this.pal().text3)
                .fontFamily(this.font()).layoutWeight(1)
                .onChange((v: string) => { this.onSearchChange(v); })
              if (this.searchText !== '') {
                Text('✕').fontSize(14).fontColor(this.pal().text3).margin({ right: 14 })
                  .onClick(() => {
                    this.searchText = '';
                    this.filteredHosts = this.visibleHostsForCurrentMode();
                    this.hostDataSource.replaceAll(this.filteredHosts);
                  })
              }
            }.width('92%')
              .height(44).borderRadius(22)
              .backgroundColor(this.pal().card).backgroundBlurStyle(BlurStyle.Regular)
              .alignItems(VerticalAlign.Center)
              .shadow({ radius: 12, color: 'rgba(0,0,0,0.06)', offsetY: 2 })
              .border({ width: 0.5, color: this.pal().cardBorder, style: BorderStyle.Solid })
          }
        }
        .width('100%')
        .padding({ left: 16, right: 16 })
        .position({ x: 0, y: 0 })
        .hitTestBehavior(HitTestMode.Transparent)
      }
      .width('100%').height('100%')

    }
    .width('100%').height('100%')
  }

  private async openSshPublicKeyInstall(host: RemoteHost): Promise<void> {
    const latest = this.srv.getHost(host.id) ?? host;
    if (latest.locked) {
      const gate = await showLockGate(latest.label, 'biometric');
      if (!gate.ok) { return; }
    }
    this.sshPublicKeyInstallHost = latest;
    const keys = this.keyVault.getAllSshKeys();
    this.sshPublicKeyInstallKeyId = keys.length > 0 ? keys[0].id : '';
    this.sshPublicKeyInstallPassword = latest.sshUseKey ? '' : latest.password;
    this.sshPublicKeyInstallPassphrase = latest.sshUseKey ? latest.sshKeyPassphrase : '';
    this.sshPublicKeyInstallError = '';
    this.sshPublicKeyInstallBusy = false;
    this.openSheetSafely((): void => { this.showSshPublicKeyInstallSheet = true; });
  }

  private closeSshPublicKeyInstallSheet(): void {
    this.showSshPublicKeyInstallSheet = false;
  }

  private resetSshPublicKeyInstallSheetState(): void {
    this.sshPublicKeyInstallHost = null;
    this.sshPublicKeyInstallKeyId = '';
    this.sshPublicKeyInstallPassword = '';
    this.sshPublicKeyInstallPassphrase = '';
    this.sshPublicKeyInstallBusy = false;
    this.sshPublicKeyInstallError = '';
  }

  private async doSshPublicKeyInstall(): Promise<void> {
    const host = this.sshPublicKeyInstallHost;
    if (host === null || this.sshPublicKeyInstallBusy) { return; }
    const targetKey = this.keyVault.getSshKey(this.sshPublicKeyInstallKeyId);
    if (targetKey === undefined) { this.sshPublicKeyInstallError = '请先选择要部署的 SSH 公钥'; return; }
    if (!host.sshUseKey && this.sshPublicKeyInstallPassword.length === 0) {
      this.sshPublicKeyInstallError = '请输入当前服务器密码'; return;
    }
    let publicKey = targetKey.publicKey.trim();
    if (publicKey.length === 0) {
      const info = this.loader.inspectSshPrivateKey(targetKey.privateKey, this.sshPublicKeyInstallPassphrase);
      if (!info.ok || info.publicKeyOpenSsh.length === 0) {
        this.sshPublicKeyInstallError = '无法读取所选私钥的公钥，请检查密钥密码'; return;
      }
      publicKey = info.publicKeyOpenSsh.trim();
    }
    if (!this.loader.validatePublicKeyForAuthorizedKeys(publicKey)) {
      this.sshPublicKeyInstallError = '所选密钥不是有效的 SSH 公钥'; return;
    }
    let authPrivateKey = '';
    if (host.sshUseKey) {
      const authKey = this.keyVault.getSshKey(host.sshKeyId);
      if (authKey === undefined) { this.sshPublicKeyInstallError = '当前主机的认证私钥不在密钥保险库中'; return; }
      authPrivateKey = authKey.privateKey;
    }
    this.sshPublicKeyInstallBusy = true;
    this.sshPublicKeyInstallError = '';
    try {
      const result: SshPublicKeyInstallResult = await new Promise<SshPublicKeyInstallResult>((resolve) => {
        setTimeout((): void => {
          resolve(this.loader.installSshPublicKey(host.host, host.port, host.username,
            host.sshUseKey ? '' : this.sshPublicKeyInstallPassword, authPrivateKey,
            this.sshPublicKeyInstallPassphrase, publicKey));
        }, 0);
      });
      if (!result.ok) {
        this.sshPublicKeyInstallError = result.message || '公钥部署失败，请检查认证信息和服务器权限';
        return;
      }
      promptAction.showToast({
        message: result.alreadyInstalled ? '公钥已存在，无需重复部署' : 'SSH 公钥已部署到服务器', duration: 1800
      });
      this.closeSshPublicKeyInstallSheet();
    } catch (_err) {
      this.sshPublicKeyInstallError = '公钥部署失败，请稍后重试';
    } finally {
      this.sshPublicKeyInstallBusy = false;
    }
  }

  @Builder sshPublicKeyInstallPanel() {
    Column() {
      Row() {
        Column() {
          Text('部署 SSH 公钥').fontSize(20).fontWeight(FontWeight.Bold).fontColor(this.pal().text)
          if (this.sshPublicKeyInstallHost !== null) {
            Text(this.sshPublicKeyInstallHost.username + '@' + this.sshPublicKeyInstallHost.host + ':' +
              this.sshPublicKeyInstallHost.port.toString()).fontSize(12).fontColor(this.pal().text3).margin({ top: 4 })
          }
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        Button() { SymbolGlyph($r('sys.symbol.xmark')).fontSize(17).fontColor([this.pal().text2]) }
          .width(36).height(36).borderRadius(18).padding(0).backgroundColor(this.pal().surface)
          .enabled(!this.sshPublicKeyInstallBusy).onClick((): void => { this.closeSshPublicKeyInstallSheet(); })
      }.width('100%').margin({ bottom: 14 })
      Text('选择密钥后，将公钥追加到远端 authorized_keys；不会上传私钥。')
        .fontSize(12).fontColor(this.pal().text2).width('100%').margin({ bottom: 12 })
      if (this.keyVault.getAllSshKeys().length === 0) {
        Text('密钥保险库为空，请先添加 SSH 密钥。').fontSize(13).fontColor(this.pal().danger)
          .width('100%').padding(12).backgroundColor(this.pal().surface).borderRadius(10)
      } else {
        ForEach(this.keyVault.getAllSshKeys(), (key: SshKey) => {
          Row() {
            SymbolGlyph(key.id === this.sshPublicKeyInstallKeyId
              ? $r('sys.symbol.checkmark_circle_fill') : $r('sys.symbol.circle'))
              .fontSize(20).fontColor([key.id === this.sshPublicKeyInstallKeyId ? this.accentColor : this.pal().text3])
            Column() {
              Text(key.label !== '' ? key.label : SshKey.typeLabel(key.keyType)).fontSize(14).fontColor(this.pal().text)
              Text(key.fingerprint !== '' ? key.fingerprint : '未生成指纹').fontSize(10).fontColor(this.pal().text3)
                .maxLines(1).margin({ top: 3 })
            }.alignItems(HorizontalAlign.Start).layoutWeight(1).margin({ left: 10 })
          }.width('100%').padding(11).borderRadius(10).backgroundColor(this.pal().surface).margin({ bottom: 7 })
            .onClick((): void => { this.sshPublicKeyInstallKeyId = key.id; })
        }, (key: SshKey): string => key.id + ':' + this.hostViewRevision.toString())
        if (this.sshPublicKeyInstallHost !== null && this.sshPublicKeyInstallHost.sshUseKey) {
          Text('将使用当前主机配置的私钥进行服务器认证。').fontSize(11).fontColor(this.pal().text3)
            .width('100%').margin({ top: 2, bottom: 8 })
        } else {
          TextInput({ text: this.sshPublicKeyInstallPassword, placeholder: '当前服务器密码' })
            .type(InputType.Password).showPasswordIcon(true).height(44).width('100%')
            .backgroundColor(this.pal().surface).borderRadius(10).fontColor(this.pal().text)
            .onChange((value: string): void => { this.sshPublicKeyInstallPassword = value; })
            .margin({ top: 2, bottom: 8 })
        }
        TextInput({ text: this.sshPublicKeyInstallPassphrase, placeholder: '认证私钥密码（如有）' })
          .type(InputType.Password).showPasswordIcon(true).height(44).width('100%')
          .backgroundColor(this.pal().surface).borderRadius(10).fontColor(this.pal().text)
          .onChange((value: string): void => { this.sshPublicKeyInstallPassphrase = value; })
          .margin({ bottom: 10 })
      }
      if (this.sshPublicKeyInstallError.length > 0) {
        Text(this.sshPublicKeyInstallError).fontSize(12).fontColor(this.pal().danger).width('100%')
          .padding(10).backgroundColor(this.pal().surface).borderRadius(9).margin({ bottom: 10 })
      }
      Button(this.sshPublicKeyInstallBusy ? '部署中…' : '部署公钥').width('100%').height(44).borderRadius(11)
        .backgroundColor(this.sshPublicKeyInstallBusy ? this.pal().text3 : this.accentColor).fontColor(Color.White)
        .enabled(!this.sshPublicKeyInstallBusy && this.keyVault.getAllSshKeys().length > 0)
        .onClick((): void => { void this.doSshPublicKeyInstall(); })
    }.width('100%').padding({ left: 20, right: 20, top: 20, bottom: 24 }).backgroundColor(this.pal().card)
  }

  // PC/2in1: 省略号弹出操作菜单 (小巧精致 + 过渡动画)
  @Builder hostActionMenuBuilder(host: RemoteHost) {
    Column() {
      Row() {
        SymbolGlyph($r('sys.symbol.square_and_pencil'))
          .fontSize(16).fontColor([this.pal().text])
        Text('编辑').fontSize(13).fontColor(this.pal().text).fontFamily(this.font()).margin({ left: 8 })
      }
      .width('100%').padding({ left: 12, right: 12, top: 8, bottom: 8 })
      .onClick(() => { animateTo({ duration: 150 }, () => { this.hostActionPopupId = ''; }); this.editHost(host); })

      Divider().strokeWidth(0.5).color(this.pal().cardBorder).width('100%')

      if (host.protocol === 'ssh') {
        Row() {
          SymbolGlyph($r('sys.symbol.key_fill')).fontSize(16).fontColor([this.pal().text])
          Text('部署公钥').fontSize(13).fontColor(this.pal().text).fontFamily(this.font()).margin({ left: 8 })
        }
        .width('100%').padding({ left: 12, right: 12, top: 8, bottom: 8 })
        .onClick(() => {
          animateTo({ duration: 150 }, () => { this.hostActionPopupId = ''; });
          void this.openSshPublicKeyInstall(host);
        })

        Divider().strokeWidth(0.5).color(this.pal().cardBorder).width('100%')
      }

      Row() {
        SymbolGlyph(host.locked ? $r('sys.symbol.lock_open') : $r('sys.symbol.ohos_lock'))
          .fontSize(16).fontColor([this.pal().text])
        Text(host.locked ? '解锁' : '上锁').fontSize(13).fontColor(this.pal().text).fontFamily(this.font()).margin({ left: 8 })
      }
      .width('100%').padding({ left: 12, right: 12, top: 8, bottom: 8 })
      .onClick(() => { animateTo({ duration: 150 }, () => { this.hostActionPopupId = ''; }); this.toggleLock(host); })

      Divider().strokeWidth(0.5).color(this.pal().cardBorder).width('100%')

      Row() {
        SymbolGlyph($r('sys.symbol.list_bullet'))
          .fontSize(16).fontColor([this.pal().text])
        Text('多选').fontSize(13).fontColor(this.pal().text).fontFamily(this.font()).margin({ left: 8 })
      }
      .width('100%').padding({ left: 12, right: 12, top: 8, bottom: 8 })
      .onClick(() => {
        animateTo({ duration: 150 }, () => { this.hostActionPopupId = ''; });
        this.hostSelectionMode = true; this.hostSelectedIds = new Set();
      })

      Divider().strokeWidth(0.5).color(this.pal().cardBorder).width('100%')

      Row() {
        SymbolGlyph($r('sys.symbol.folder_badge_plus'))
          .fontSize(16).fontColor([this.pal().text])
        Text(host.groupId === 'ops' ? '移出工作组' : '加入 ops 工作组')
          .fontSize(13).fontColor(this.pal().text).fontFamily(this.font()).margin({ left: 8 })
      }
      .width('100%').padding({ left: 12, right: 12, top: 8, bottom: 8 })
      .onClick(() => {
        const nextGroup = host.groupId === 'ops' ? '' : 'ops';
        if (!this.srv.setGroup(host.id, nextGroup)) {
          promptAction.showToast({ message: '工作组保存失败 [E-HOST-WS-2]', duration: 1800 });
        }
        animateTo({ duration: 150 }, () => { this.hostActionPopupId = ''; });
      })

      Divider().strokeWidth(0.5).color(this.pal().cardBorder).width('100%')

      Row() {
        SymbolGlyph($r('sys.symbol.ohos_trash'))
          .fontSize(16).fontColor([this.pal().danger])
        Text('删除').fontSize(13).fontColor(this.pal().danger).fontFamily(this.font()).margin({ left: 8 })
      }
      .width('100%').padding({ left: 12, right: 12, top: 8, bottom: 8 })
      .onClick(() => { animateTo({ duration: 150 }, () => { this.hostActionPopupId = ''; }); this.doDeleteHost(host); })
    }
    .width(148).padding({ top: 2, bottom: 2 }).borderRadius(12)
    .transition(TransitionEffect.asymmetric(
      TransitionEffect.scale({ x: 0.8, y: 0.8 }).combine(TransitionEffect.OPACITY)
        .animation({ duration: 200, curve: Curve.FastOutSlowIn }),
      TransitionEffect.scale({ x: 0.8, y: 0.8 }).combine(TransitionEffect.OPACITY)
        .animation({ duration: 150, curve: Curve.FastOutSlowIn })
    ))
  }

  // 右滑: 编辑(黄) + 上锁(蓝) 按钮 (圆角矩形)
  @Builder hostEditLockRow(host: RemoteHost) {
    Row() {
      Button() {
        SymbolGlyph($r('sys.symbol.square_and_pencil'))
          .fontSize(17)
          .fontColor([Color.White])
      }
      .width(48).height(48).borderRadius(12)
      .backgroundColor(this.pal().editColor)
      .onClick(() => { this.editHost(host); })

      Button() {
        SymbolGlyph(host.locked ? $r('sys.symbol.ohos_lock') : $r('sys.symbol.ohos_lock'))
          .fontSize(17)
          .fontColor([Color.White])
      }
      .width(48).height(48).borderRadius(12)
      .backgroundColor(host.locked ? this.pal().success : this.accentColor)
      .margin({ left: 4 })
      .onClick(() => { this.toggleLock(host); })

      if (host.protocol === 'ssh') {
        Button() {
          SymbolGlyph($r('sys.symbol.key_fill'))
            .fontSize(17)
            .fontColor([Color.White])
        }
        .width(48).height(48).borderRadius(12)
        .backgroundColor(this.accentColor)
        .margin({ left: 4 })
        .onClick(() => { void this.openSshPublicKeyInstall(host); })
      }
    }
    .height('100%').alignItems(VerticalAlign.Center)
    .borderRadius(14)
  }

  // 左滑: 删除按钮 — 全断点正方形 60×60
  @Builder hostDeleteBtn(host: RemoteHost) {
    Column() {
      SymbolGlyph($r('sys.symbol.ohos_trash'))
        .fontSize(24)
        .fontColor([Color.White])
        .symbolEffect(new PulseSymbolEffect(), true)
        .symbolEffect(new BounceSymbolEffect(EffectScope.WHOLE, EffectDirection.UP), true)
      Text('删除')
        .fontSize(9)
        .fontColor(Color.White)
        .margin({ top: 2 })
    }
    .width(60).height(60)
    .justifyContent(FlexAlign.Center)
    .borderRadius(14)
    .backgroundColor(this.pal().danger)
    .onClick(() => { this.doDeleteHost(host); })
  }

  // ==================== 设置 ====================
  @Builder settingsLeafSheet() {
    if (this.settingsLeafSheetMode === SETTINGS_SHEET_ACCOUNT) {
      this.accountSheet()
    } else if (this.settingsLeafSheetMode === SETTINGS_SHEET_ACCENT_COLOR) {
      this.colorPickerSheet()
    } else if (this.settingsLeafSheetMode === SETTINGS_SHEET_WALLPAPER) {
      this.wallPicker()
    } else if (this.settingsLeafSheetMode === SETTINGS_SHEET_HALO_COLOR) {
      this.haloColorSheet()
    } else if (this.settingsLeafSheetMode === SETTINGS_SHEET_TERMINAL_FG_COLOR) {
      this.terminalFgColorSheet()
    } else if (this.settingsLeafSheetMode === SETTINGS_SHEET_TERMINAL_FONT_SIZE) {
      this.terminalFontSizeSheet()
    } else if (this.settingsLeafSheetMode === SETTINGS_SHEET_POPUP) {
      this.unifiedPopupSheet()
    } else if (this.settingsLeafSheetMode === SETTINGS_SHEET_RDP_CREDENTIALS) {
      this.rdpCredentialSheet()
    } else if (this.settingsLeafSheetMode === SETTINGS_SHEET_RDP_CREDENTIAL_EDITOR) {
      this.rdpCredentialEditorSheet()
    } else if (this.settingsLeafSheetMode === SETTINGS_SHEET_KEY_VAULT) {
      this.keyVaultSheet()
    } else if (this.settingsLeafSheetMode === SETTINGS_SHEET_FEEDBACK) {
      FeedbackSettingsSheet({
        onClose: (): void => { this.closeSettingsLeafSheet(); },
        onOpenMail: (): void => { this.openFeedbackEmail(); }
      })
    } else {
      Column().width('100%').height(1)
    }
  }

  @Builder settingsAccordionHeader(section: string, icon: Resource, title: string, subtitle: string) {
    Row() {
      Stack({ alignContent: Alignment.Center }) {
        Column()
          .width(34)
          .height(34)
          .borderRadius(10)
          .backgroundColor(this.pal().surface)
          .opacity(this.settingsSectionExpanded(section) ? 1 : 0)
          .scale({ x: this.settingsSectionExpanded(section) ? 1 : 0.92,
            y: this.settingsSectionExpanded(section) ? 1 : 0.92 })
          .animation({ duration: SETTINGS_ACCORDION_ANIMATION_MS, curve: Curve.FastOutSlowIn })

        SymbolGlyph(icon)
          .fontSize(21)
          .fontColor([this.pal().text])
          .opacity(this.settingsSectionExpanded(section) ? 0 : 1)
          .scale({ x: this.settingsSectionExpanded(section) ? 0.92 : 1,
            y: this.settingsSectionExpanded(section) ? 0.92 : 1 })
          .animation({ duration: SETTINGS_ACCORDION_ANIMATION_MS, curve: Curve.FastOutSlowIn })

        SymbolGlyph(icon)
          .fontSize(21)
          .fontColor([this.accentColor])
          .opacity(this.settingsSectionExpanded(section) ? 1 : 0)
          .scale({ x: this.settingsSectionExpanded(section) ? 1 : 0.92,
            y: this.settingsSectionExpanded(section) ? 1 : 0.92 })
          .animation({ duration: SETTINGS_ACCORDION_ANIMATION_MS, curve: Curve.FastOutSlowIn })
      }
      .width(34).height(34).borderRadius(10)
      .margin({ right: 12 })

      Column() {
        Text(title)
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.pal().text)
          .fontFamily(this.font())
        Text(subtitle)
          .fontSize(11)
          .fontColor(this.pal().text3)
          .fontFamily(this.font())
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ top: 2 })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(18)
        .fontColor([this.pal().text3])
        .rotate({ angle: this.settingsSectionExpanded(section) ? 90 : 0 })
        .animation({ duration: SETTINGS_ACCORDION_ANIMATION_MS, curve: Curve.FastOutSlowIn })
    }
    .width('100%')
    .height(64)
    .padding({ left: 16, right: 18 })
    .borderRadius(20)
    .backgroundColor(this.pal().card)
    .backgroundBlurStyle(BlurStyle.Regular)
    .shadow({ radius: 12, color: 'rgba(0,0,0,0.035)', offsetY: 3 })
    .border({ width: 0.5, color: this.pal().cardBorder, style: BorderStyle.Solid })
    .onClick((): void => { this.toggleSettingsSection(section); })
  }

  @Builder settingsActionHeader(icon: Resource, title: string, subtitle: string, action: () => void) {
    Row() {
      Row() {
        SymbolGlyph(icon).fontSize(21).fontColor([this.pal().text])
      }
      .width(34).height(34).borderRadius(10)
      .justifyContent(FlexAlign.Center)
      .backgroundColor(this.pal().surface)
      .margin({ right: 12 })

      Column() {
        Text(title)
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.pal().text)
          .fontFamily(this.font())
        Text(subtitle)
          .fontSize(11)
          .fontColor(this.pal().text3)
          .fontFamily(this.font())
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ top: 2 })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(18).fontColor([this.pal().text3])
    }
    .width('100%')
    .height(64)
    .padding({ left: 16, right: 18 })
    .borderRadius(20)
    .backgroundColor(this.pal().card)
    .backgroundBlurStyle(BlurStyle.Regular)
    .shadow({ radius: 12, color: 'rgba(0,0,0,0.035)', offsetY: 3 })
    .border({ width: 0.5, color: this.pal().cardBorder, style: BorderStyle.Solid })
    .onClick(action)
  }

  @Builder settingsContent() {
    Column() {
      // 参照 Melotopia-HMOS: 标题栏覆盖在滚动内容之上, content extend under → blur 可见
      List() {
        // --- 顶栏占位 (标题87, 首项Y=95 与KV无切换栏对齐) ---
        ListItem() { Column().height(95) }

        // --- 账号卡片 (小卡片, 点击弹出Sheet) ---
        ListItem() {
          Row() {
            // 左侧头像
            if (this.accountAvatarUrl !== '') {
              Image(this.accountAvatarUrl).width(40).height(40).borderRadius(20)
            } else if (this.auth.isLoggedIn()) {
              Text('👤').fontSize(30)
            } else {
              Text('👤').fontSize(30)
            }
            // 中间信息列
            Column() {
              Text(this.accountDisplayName !== '' ? this.accountDisplayName : '华为账号')
                .fontSize(19).fontWeight(FontWeight.Medium).fontColor(this.pal().text)
                .fontFamily(this.font())
              Text('' + this.hostCount + ' 主机 · ' + this.keyCount + ' 密钥 · ' + this.totpCount + ' 2FA')
                .fontSize(11).fontColor(this.pal().text3).fontFamily(this.font()).margin({ top: 2 })
            }
            .alignItems(HorizontalAlign.Start).layoutWeight(1).margin({ left: 12 })
            SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(20).fontColor([this.pal().text3])
          }
          .width('100%').height(75).padding({ left: 24, right: 24 }).alignItems(VerticalAlign.Center)
          .borderRadius(22).backgroundColor(this.pal().card).backgroundBlurStyle(BlurStyle.Regular)
          .shadow({ radius: 16, color: 'rgba(0,0,0,0.04)', offsetY: 4 })
          .border({ width: 0.5, color: this.pal().cardBorder, style: BorderStyle.Solid })
          .onClick(() => { this.openSettingsLeafSheet(SETTINGS_SHEET_ACCOUNT); })
        }.width('100%').padding({ left: 20, right: 20 }).margin({ bottom: 20 })
        .id('account_card_' + this.loginRefreshKey)

        ListItem() {
          this.settingsAccordionHeader(SETTINGS_SECTION_APPEARANCE, $r('sys.symbol.paintpalette_fill'),
            '个性化', '添加方式、主题色、壁纸、光晕和终端显示')
        }.width('100%').padding({ left: 20, right: 20 }).margin({ bottom: 10 })

        // --- 个性化卡片 ---
        ListItem() {
          Column() {
            Text('个性化').fontSize(13).fontWeight(FontWeight.Medium).fontColor(this.pal().text3)
              .fontFamily(this.font()).padding({ left: 8, bottom: 8 })
            Column() {
              Column() {
                Row() {
                  Row() { SymbolGlyph($r('sys.symbol.plus_circle_fill')).fontSize(22).fontColor([this.pal().text]) }
                    .width(22).height(22).justifyContent(FlexAlign.Center).margin({ left: 9, right: 9 })
                  Column() {
                    Text('添加 FAB 风格').fontSize(AppTheme.fontSize.body).fontWeight(FontWeight.Medium)
                      .fontColor(this.pal().text).fontFamily(this.font())
                Text('控制添加主机、SSH 密钥、2FA 和中继服务器的界面风格')
                      .fontSize(11).fontColor(this.pal().text3)
                      .fontFamily(this.font())
                  }.alignItems(HorizontalAlign.Start).layoutWeight(1).margin({ left: 4 })
                }.width('100%').padding({ left: 16, right: 16, top: 12, bottom: 8 })
                Row() {
                  Button('全新模式').layoutWeight(1).height(36).fontSize(13)
                    .fontColor(this.fabAddStyle === 'modern' ? Color.White : this.pal().text2)
                    .backgroundColor(this.fabAddStyle === 'modern' ? this.accentColor : this.pal().surface)
                    .borderRadius(10).onClick((): void => { this.saveFabAddStyle('modern'); })
                  Button('经典模式').layoutWeight(1).height(36).fontSize(13).margin({ left: 8 })
                    .fontColor(this.fabAddStyle === 'classic' ? Color.White : this.pal().text2)
                    .backgroundColor(this.fabAddStyle === 'classic' ? this.accentColor : this.pal().surface)
                    .borderRadius(10).onClick((): void => { this.saveFabAddStyle('classic'); })
                }.width('100%').padding({ left: 16, right: 16, bottom: 12 })
              }
              this.cardDivider()
              Column() {
                Row() {
                  Row() { Text('⌖').fontSize(22).fontColor(this.pal().text) }
                    .width(22).height(22).justifyContent(FlexAlign.Center).margin({ left: 9, right: 9 })
                  Column() {
                    Text('触控板鼠标样式').fontSize(AppTheme.fontSize.body).fontWeight(FontWeight.Medium)
                      .fontColor(this.pal().text).fontFamily(this.font())
                    Text('仅手机和平板触控板模式，选择圆环或官方远端鼠标').fontSize(11).fontColor(this.pal().text3)
                      .fontFamily(this.font())
                  }.alignItems(HorizontalAlign.Start).layoutWeight(1).margin({ left: 4 })
                }.width('100%').padding({ left: 16, right: 16, top: 12, bottom: 8 })
                Row() {
                  Button('圆环').layoutWeight(1).height(36).fontSize(13)
                    .fontColor(this.virtualMouseStyle === 'circle' ? Color.White : this.pal().text2)
                    .backgroundColor(this.virtualMouseStyle === 'circle' ? this.accentColor : this.pal().surface)
                    .borderRadius(10).onClick((): void => { this.saveVirtualMouseStyle('circle'); })
                  Button('官方远端鼠标').layoutWeight(1).height(36).fontSize(13).margin({ left: 8 })
                    .fontColor(this.virtualMouseStyle === 'arrow' ? Color.White : this.pal().text2)
                    .backgroundColor(this.virtualMouseStyle === 'arrow' ? this.accentColor : this.pal().surface)
                    .borderRadius(10).onClick((): void => { this.saveVirtualMouseStyle('arrow'); })
                }.width('100%').padding({ left: 16, right: 16, bottom: 12 })
              }
              this.cardDivider()
              Row() {
                Row() { SymbolGlyph($r('sys.symbol.paintpalette_fill')).fontSize(22).fontColor([this.pal().text]) }
                  .width(22).height(22).justifyContent(FlexAlign.Center).margin({ left: 9, right: 9 })
                Text('主题色').fontSize(AppTheme.fontSize.body).fontWeight(FontWeight.Medium)
                  .fontColor(this.pal().text).fontFamily(this.font()).layoutWeight(1).margin({ left: 4 })
                Column().width(44).height(24).borderRadius(12).backgroundColor(this.accentColor)
                Text(' >').fontSize(14).fontColor(this.pal().text3).margin({ left: 6 })
              }.width('100%').height(60).padding({ left: 16, right: 16 })
              .onClick(() => { this.openSettingsLeafSheet(SETTINGS_SHEET_ACCENT_COLOR); })
              this.cardDivider()
              // 深色模式(含跟随系统)
              Column() {
                Row() {
                  Row() { SymbolGlyph($r('sys.symbol.moon_fill')).fontSize(22).fontColor([this.pal().text]) }
                    .width(22).height(22).justifyContent(FlexAlign.Center).margin({ left: 9, right: 9 })
                  Text('深色模式').fontSize(AppTheme.fontSize.body).fontWeight(FontWeight.Medium)
                    .fontColor(this.pal().text).fontFamily(this.font()).layoutWeight(1).margin({ left: 4 })
                  Toggle({ type: ToggleType.Switch, isOn: this.theme === 'dark' })
                    .selectedColor(this.accentColor)
                    .onChange((on: boolean) => {
                      if (this.followSystem) {
                        hilog.info(0x0000, 'HostListPage',
                          'manual theme toggle ignored while follow-system is active');
                        return;
                      }
                      this.applyManualTheme(on, 'manual-toggle');
                    })
                    .scale({ x: 0.92, y: 0.92 }).enabled(!this.followSystem)
                }.width('100%').height(60).padding({ left: 16, right: 16 })
                Row() {
                  Blank().width(16)
                  Column().layoutWeight(1).height(0.5).backgroundColor(this.pal().divider)
                  Blank().width(16)
                }.width('100%')
                Row() {
                  Row() { SymbolGlyph($r('sys.symbol.gearshape_fill')).fontSize(20)
                      .fontColor([this.pal().text]) }
                    .width(22).height(22).justifyContent(FlexAlign.Center).margin({ left: 9, right: 9 })
                  Text('跟随系统').fontSize(14).fontWeight(FontWeight.Normal)
                    .fontColor(this.pal().text).fontFamily(this.font()).layoutWeight(1).margin({ left: 4 })
                  Toggle({ type: ToggleType.Switch, isOn: this.followSystem })
                    .selectedColor(this.accentColor)
                    .onChange((on: boolean) => {
                      if (on === this.followSystem) {
                        hilog.info(0x0000, 'HostListPage',
                          'follow-system toggle ignored unchanged=' + (on ? 'true' : 'false'));
                        return;
                      }
                      if (on) {
                        this.applyFollowSystemColorMode();
                      } else {
                        this.applyManualTheme(this.theme === 'dark', 'follow-off');
                      }
                    })
                    .scale({ x: 0.88, y: 0.88 })
                }.width('100%').height(52).padding({ left: 16, right: 16 })
              }
              this.cardDivider()
              Row() {
                Row() { SymbolGlyph($r('sys.symbol.camera_fill')).fontSize(22).fontColor([this.pal().text]) }
                  .width(22).height(22).justifyContent(FlexAlign.Center).margin({ left: 9, right: 9 })
                Text('壁纸').fontSize(AppTheme.fontSize.body).fontWeight(FontWeight.Medium)
                  .fontColor(this.pal().text).fontFamily(this.font()).layoutWeight(1).margin({ left: 4 })
                Row() {
                  ForEach(this.wallpaperItems.slice(0, 4), (item: WallpaperItem, idx: number) => {
                    Column().width(20).height(20).borderRadius(10).backgroundColor(item.color).margin({ left: idx > 0 ? 4 : 0 })
                      .border({ width: this.wallpaperIdx === idx ? 2 : 0, color: this.accentColor })
                  })
                }
                Text(' >').fontSize(14).fontColor(this.pal().text3).margin({ left: 8 })
              }.width('100%').height(60).padding({ left: 16, right: 16 })
              .onClick(() => { this.openSettingsLeafSheet(SETTINGS_SHEET_WALLPAPER); })
              this.cardDivider()
              // 光晕颜色 (沉浸光感悬浮栏渐变遮罩色)
              Row() {
                Row() { SymbolGlyph($r('sys.symbol.sun_max_fill')).fontSize(22).fontColor([this.pal().text]) }
                  .width(22).height(22).justifyContent(FlexAlign.Center).margin({ left: 9, right: 9 })
                Text('光晕颜色').fontSize(AppTheme.fontSize.body).fontWeight(FontWeight.Medium)
                  .fontColor(this.pal().text).fontFamily(this.font()).layoutWeight(1).margin({ left: 4 })
                Column().width(24).height(24).borderRadius(12).backgroundColor(this.haloColor)
                Text(' >').fontSize(14).fontColor(this.pal().text3).margin({ left: 6 })
              }.width('100%').height(60).padding({ left: 16, right: 16 })
              .onClick(() => { this.openSettingsLeafSheet(SETTINGS_SHEET_HALO_COLOR); })
              this.cardDivider()
              Row() {
                Row() { SymbolGlyph($r('sys.symbol.sun_max_fill')).fontSize(22).fontColor([this.pal().text]) }
                  .width(22).height(22).justifyContent(FlexAlign.Center).margin({ left: 9, right: 9 })
                Column() {
                  Text('环境光调节光效').fontSize(AppTheme.fontSize.body).fontWeight(FontWeight.Medium)
                    .fontColor(this.pal().text).fontFamily(this.font())
                  Text('根据环境亮度微调光晕强度').fontSize(11).fontColor(this.pal().text3).fontFamily(this.font())
                }.alignItems(HorizontalAlign.Start).layoutWeight(1).margin({ left: 4 })
                Toggle({ type: ToggleType.Switch, isOn: this.ambientLightEffectEnabled })
                  .selectedColor(this.accentColor)
                  .scale({ x: 0.88, y: 0.88 })
                  .onChange((on: boolean): void => { this.saveAmbientLightEffectEnabled(on); })
              }.width('100%').height(62).padding({ left: 16, right: 16 })
              this.cardDivider()
              Row() {
                Row() { SymbolGlyph($r('sys.symbol.person_2_fill')).fontSize(22).fontColor([this.pal().text]) }
                  .width(22).height(22).justifyContent(FlexAlign.Center).margin({ left: 9, right: 9 })
                Column() {
                  Text('握持手感知对齐').fontSize(AppTheme.fontSize.body).fontWeight(FontWeight.Medium)
                    .fontColor(this.pal().text).fontFamily(this.font())
                  Text(this.isDesktopDevice ? 'PC 端不启用' :
                    (this.gripPermissionGranted ? '已启用；根据握持手移动添加按钮' :
                      '启动后自动申请权限，不影响主机列表显示'))
                    .fontSize(11).fontColor(this.pal().text3).fontFamily(this.font())
                }.alignItems(HorizontalAlign.Start).layoutWeight(1).margin({ left: 4 })
                Text(this.isDesktopDevice ? '不适用' :
                  (this.gripPermissionGranted ? '已开启' : '启动申请'))
                  .fontSize(12).fontColor(this.isDesktopDevice ? this.pal().text3 : this.accentColor)
                  .fontFamily(this.font()).margin({ right: 8 })
              }.width('100%').height(62).padding({ left: 16, right: 16 })
              this.cardDivider()
              // 终端字体颜色
              Row() {
                Row() { Text('Aa').fontSize(16).fontColor(this.pal().text).fontWeight(FontWeight.Bold) }
                  .width(22).height(22).justifyContent(FlexAlign.Center).margin({ left: 9, right: 9 })
                Text('终端字体颜色').fontSize(AppTheme.fontSize.body).fontWeight(FontWeight.Medium)
                  .fontColor(this.pal().text).fontFamily(this.font()).layoutWeight(1).margin({ left: 4 })
                Column().width(24).height(24).borderRadius(12).backgroundColor(this.terminalFgColor)
                Text(' >').fontSize(14).fontColor(this.pal().text3).margin({ left: 6 })
              }.width('100%').height(60).padding({ left: 16, right: 16 })
              .onClick(() => { this.openSettingsLeafSheet(SETTINGS_SHEET_TERMINAL_FG_COLOR); })
              this.cardDivider()
              // 终端字体大小
              Row() {
                Row() { Text('T').fontSize(14).fontColor(this.pal().text).fontWeight(FontWeight.Bold) }
                  .width(22).height(22).justifyContent(FlexAlign.Center).margin({ left: 9, right: 9 })
                Text('终端字体大小').fontSize(AppTheme.fontSize.body).fontWeight(FontWeight.Medium)
                  .fontColor(this.pal().text).fontFamily(this.font()).layoutWeight(1).margin({ left: 4 })
                Text(this.terminalFontSize + 'vp').fontSize(13).fontColor(this.pal().text2)
                Text(' >').fontSize(14).fontColor(this.pal().text3).margin({ left: 6 })
              }.width('100%').height(60).padding({ left: 16, right: 16 })
              .onClick(() => { this.openSettingsLeafSheet(SETTINGS_SHEET_TERMINAL_FONT_SIZE); })
            }.borderRadius(24).backgroundColor(this.pal().card).backgroundBlurStyle(BlurStyle.Regular)
            .shadow({ radius: 16, color: 'rgba(0,0,0,0.04)', offsetY: 4 })
            .border({ width: 0.5, color: this.pal().cardBorder, style: BorderStyle.Solid })
          }.width('100%').padding({ left: 20, right: 20 }).margin({ bottom: 20 })
          .onAreaChange((_old: Area, next: Area): void => {
            const nextHeight: number = next.height as number;
            // Ignore the collapse animation and its intermediate frames. A
            // max-height animation reports those clipped heights here; using
            // one as the cached natural height is what previously locked this
            // card at a few dozen vp after the first expansion.
            if (this.settingsSectionExpanded(SETTINGS_SECTION_APPEARANCE) &&
              Number.isFinite(nextHeight) && nextHeight >= APPEARANCE_EXPANDED_MIN_HEIGHT &&
              nextHeight > this.appearanceContentHeight) {
              this.appearanceContentHeight = nextHeight;
            }
          })
        }
        .constraintSize({ maxHeight: this.settingsSectionExpanded(SETTINGS_SECTION_APPEARANCE) ?
          this.settingsSectionExpandedMaxHeight(SETTINGS_SECTION_APPEARANCE) : 0 })
        .opacity(this.settingsSectionExpanded(SETTINGS_SECTION_APPEARANCE) ? 1 : 0)
        .scale({ x: 1, y: this.settingsSectionExpanded(SETTINGS_SECTION_APPEARANCE) ? 1 : 0.98 })
        .translate({ y: this.settingsSectionExpanded(SETTINGS_SECTION_APPEARANCE) ? 0 : -8 })
        .clip(true)
        .animation({ duration: SETTINGS_ACCORDION_ANIMATION_MS, curve: Curve.FastOutSlowIn })

        ListItem() {
          this.settingsAccordionHeader(SETTINGS_SECTION_CLOUD_SYNC, $r('sys.symbol.cloud_fill'),
            '云同步', '华为云空间、跨设备数据恢复与手动同步')
        }.width('100%').padding({ left: 20, right: 20 }).margin({ bottom: 10 })

        ListItem() {
          Column() {
            Text('云端数据').fontSize(13).fontWeight(FontWeight.Medium).fontColor(this.pal().text3)
              .fontFamily(this.font()).padding({ left: 8, bottom: 8 })
            Column() {
              Row() {
                Row() { SymbolGlyph($r('sys.symbol.cloud_fill')).fontSize(21).fontColor([this.accentColor]) }
                  .width(40).height(40).borderRadius(20).backgroundColor(this.pal().card).justifyContent(FlexAlign.Center)
                Column() { Text('管理云同步').fontSize(AppTheme.fontSize.body).fontWeight(FontWeight.Medium).fontColor(this.pal().text).fontFamily(this.font());
                  Text(cloudSyncDetailSpec(CloudStore.getInstance().isCloudAvailable()).statusText).fontSize(11).fontColor(this.pal().text3).fontFamily(this.font())
                }.alignItems(HorizontalAlign.Start).layoutWeight(1).margin({ left: 12 })
                SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(16).fontColor([this.pal().text3])
              }.width('100%').height(68).padding({ left: 14, right: 16 }).onClick((): void => { this.openCloudSyncSheet(); })
              this.cardDivider()
              Row() {
                Row() { SymbolGlyph($r('sys.symbol.info_circle')).fontSize(20).fontColor([this.accentColor]) }
                  .width(40).height(40).borderRadius(20).backgroundColor(this.pal().card).justifyContent(FlexAlign.Center)
                Column() { Text('云同步详情').fontSize(AppTheme.fontSize.body).fontWeight(FontWeight.Medium).fontColor(this.pal().text).fontFamily(this.font());
                  Text(cloudSyncDetailSpec(CloudStore.getInstance().isCloudAvailable()).statusText).fontSize(11).fontColor(this.pal().text3).fontFamily(this.font())
                }.alignItems(HorizontalAlign.Start).layoutWeight(1).margin({ left: 12 })
                SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(16).fontColor([this.pal().text3])
              }.width('100%').height(68).padding({ left: 14, right: 16 }).onClick((): void => { this.openCloudSyncDetailsSheet(); })
              this.cardDivider()
              Row() {
                Row() { SymbolGlyph($r('sys.symbol.doc_plaintext')).fontSize(20).fontColor([this.accentColor]) }
                  .width(40).height(40).borderRadius(20).backgroundColor(this.pal().card).justifyContent(FlexAlign.Center)
                Column() { Text('本地备份').fontSize(AppTheme.fontSize.body).fontWeight(FontWeight.Medium).fontColor(this.pal().text).fontFamily(this.font());
                  Text('导出全部 7 类数据为明文 JSON').fontSize(11).fontColor(this.pal().text3).fontFamily(this.font())
                }.alignItems(HorizontalAlign.Start).layoutWeight(1).margin({ left: 12 })
                SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(16).fontColor([this.pal().text3])
              }.width('100%').height(68).padding({ left: 14, right: 16 })
                .onClick((): void => { this.openCloudSyncSheet(CLOUD_SYNC_SHEET_BACKUP_CONFIRM); })
              this.cardDivider()
              Row() {
                Row() { SymbolGlyph($r('sys.symbol.doc')).fontSize(20).fontColor([this.pal().danger]) }
                  .width(40).height(40).borderRadius(20).backgroundColor(this.pal().card).justifyContent(FlexAlign.Center)
                Column() { Text('从本地恢复').fontSize(AppTheme.fontSize.body).fontWeight(FontWeight.Medium).fontColor(this.pal().text).fontFamily(this.font());
                  Text('选择 JSON 并覆盖此设备的全部数据').fontSize(11).fontColor(this.pal().text3).fontFamily(this.font())
                }.alignItems(HorizontalAlign.Start).layoutWeight(1).margin({ left: 12 })
                SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(16).fontColor([this.pal().text3])
              }.width('100%').height(68).padding({ left: 14, right: 16 }).onClick((): void => { this.chooseLocalRestore(); })
            }.borderRadius(24).backgroundColor(this.pal().card).backgroundBlurStyle(BlurStyle.Regular)
            .shadow({ radius: 16, color: 'rgba(0,0,0,0.04)', offsetY: 4 })
            .border({ width: 0.5, color: this.pal().cardBorder, style: BorderStyle.Solid })
          }.width('100%').padding({ left: 20, right: 20 }).margin({ bottom: 20 })
        }
        .constraintSize({ maxHeight: this.settingsSectionExpanded(SETTINGS_SECTION_CLOUD_SYNC) ? 390 : 0 })
        .opacity(this.settingsSectionExpanded(SETTINGS_SECTION_CLOUD_SYNC) ? 1 : 0)
        .scale({ x: 1, y: this.settingsSectionExpanded(SETTINGS_SECTION_CLOUD_SYNC) ? 1 : 0.98 })
        .translate({ y: this.settingsSectionExpanded(SETTINGS_SECTION_CLOUD_SYNC) ? 0 : -8 })
        .clip(true)
        .animation({ duration: SETTINGS_ACCORDION_ANIMATION_MS, curve: Curve.FastOutSlowIn })

        ListItem() {
          this.settingsAccordionHeader(SETTINGS_SECTION_CONNECTION_LIVE, $r('sys.symbol.gearshape_fill'),
            '连接实况窗', '主机统计、后台展示和系统实况窗')
        }.width('100%').padding({ left: 20, right: 20 }).margin({ bottom: 10 })

        // --- 连接卡片 ---
        ListItem() {
          Column() {
            Text('连接').fontSize(13).fontWeight(FontWeight.Medium).fontColor(this.pal().text3)
              .fontFamily(this.font()).padding({ left: 8, bottom: 8 })
            Column() {
              this.cardItemRow($r('app.media.icon_desktop'), '远程主机', this.hostCount + ' 台')
              this.cardDivider()
              this.cardItemRow($r('app.media.icon_desktop'), 'RDP 协议', this.rdpCount + ' 台')
              this.cardDivider()
              this.cardItemRow($r('app.media.icon_laptop'), 'RustDesk 协议', this.rustdeskCount + ' 台')
              this.cardDivider()
              this.cardItemRow($r('app.media.icon_terminal'), 'SSH 终端', this.sshCount + ' 台')
              this.cardDivider()
              this.cardItemRow($r('app.media.icon_lock'), '已锁定', this.lockedCount + ' 台')
            }.borderRadius(24).backgroundColor(this.pal().card).backgroundBlurStyle(BlurStyle.Regular)
            .shadow({ radius: 16, color: 'rgba(0,0,0,0.04)', offsetY: 4 })
            .border({ width: 0.5, color: this.pal().cardBorder, style: BorderStyle.Solid })
          }.width('100%').padding({ left: 20, right: 20 }).margin({ bottom: 20 })
        }
        .constraintSize({ maxHeight: this.settingsSectionExpanded(SETTINGS_SECTION_CONNECTION_LIVE) ?
          this.settingsSectionExpandedMaxHeight(SETTINGS_SECTION_CONNECTION_LIVE) : 0 })
        .opacity(this.settingsSectionExpanded(SETTINGS_SECTION_CONNECTION_LIVE) ? 1 : 0)
        .scale({ x: 1, y: this.settingsSectionExpanded(SETTINGS_SECTION_CONNECTION_LIVE) ? 1 : 0.98 })
        .translate({ y: this.settingsSectionExpanded(SETTINGS_SECTION_CONNECTION_LIVE) ? 0 : -8 })
        .clip(true)
        .animation({ duration: SETTINGS_ACCORDION_ANIMATION_MS, curve: Curve.FastOutSlowIn })

        // --- 实况窗卡片 ---
        ListItem() {
          Column() {
            Text('实况窗').fontSize(13).fontWeight(FontWeight.Medium).fontColor(this.pal().text3)
              .fontFamily(this.font()).padding({ left: 8, bottom: 8 })
            Column() {
              // 总开关
              this.rustdeskSwitchRow($r('app.media.icon_desktop'), '后台连接展示',
                '应用退到后台时保持远程连接，并显示系统允许的状态入口',
                this.liveViewEnabled,
                (on: boolean): void => {
                  this.liveViewEnabled = on;
                  this.persistPref('liveViewEnabled', on);
                }, true)
              this.cardDivider()
              // 模式选择: AVSession
              this.liveViewModeRow('系统媒体胶囊',
                '有真实视频时尝试 VIDEO_PLAY 画中画；AVSession 负责系统媒体控制胶囊',
                1)
              this.cardDivider()
              // 模式选择: 普通后台通知。第三方远程连接不能直接创建系统实况窗。
              this.liveViewModeRow('后台通知',
                '使用系统允许的普通通知展示连接状态和时长，不显示视频画中画',
                2)
            }.borderRadius(24).backgroundColor(this.pal().card).backgroundBlurStyle(BlurStyle.Regular)
            .shadow({ radius: 16, color: 'rgba(0,0,0,0.04)', offsetY: 4 })
            .border({ width: 0.5, color: this.pal().cardBorder, style: BorderStyle.Solid })
          }.width('100%').padding({ left: 20, right: 20 }).margin({ bottom: 20 })
        }
        .constraintSize({ maxHeight: this.settingsSectionExpanded(SETTINGS_SECTION_CONNECTION_LIVE) ?
          this.settingsSectionExpandedMaxHeight(SETTINGS_SECTION_CONNECTION_LIVE) : 0 })
        .opacity(this.settingsSectionExpanded(SETTINGS_SECTION_CONNECTION_LIVE) ? 1 : 0)
        .scale({ x: 1, y: this.settingsSectionExpanded(SETTINGS_SECTION_CONNECTION_LIVE) ? 1 : 0.98 })
        .translate({ y: this.settingsSectionExpanded(SETTINGS_SECTION_CONNECTION_LIVE) ? 0 : -8 })
        .clip(true)
        .animation({ duration: SETTINGS_ACCORDION_ANIMATION_MS, curve: Curve.FastOutSlowIn })

        ListItem() {
          this.settingsAccordionHeader(SETTINGS_SECTION_DISPLAY_INTERACTION, $r('sys.symbol.desktop_fill'),
            '显示与交互', '本地缩放、滚轮方向与双指画布缩放')
        }.width('100%').padding({ left: 20, right: 20 }).margin({ bottom: 10 })

        ListItem() {
          Column() {
            Text('显示与交互').fontSize(13).fontWeight(FontWeight.Medium).fontColor(this.pal().text3)
              .fontFamily(this.font()).padding({ left: 8, bottom: 8 })
            Column() {
              this.remoteDisplayScaleRow()
              this.cardDivider()
              this.remoteWheelDirectionRow()
              if (!this.isDesktopDevice) {
                this.cardDivider()
                this.canvasGestureZoomRow()
              }
            }.borderRadius(24).backgroundColor(this.pal().card).backgroundBlurStyle(BlurStyle.Regular)
            .shadow({ radius: 16, color: 'rgba(0,0,0,0.04)', offsetY: 4 })
            .border({ width: 0.5, color: this.pal().cardBorder, style: BorderStyle.Solid })
          }.width('100%').padding({ left: 20, right: 20 }).margin({ bottom: 20 })
        }
        .constraintSize({ maxHeight: this.settingsSectionExpanded(SETTINGS_SECTION_DISPLAY_INTERACTION) ?
          this.settingsSectionExpandedMaxHeight(SETTINGS_SECTION_DISPLAY_INTERACTION) : 0 })
        .opacity(this.settingsSectionExpanded(SETTINGS_SECTION_DISPLAY_INTERACTION) ? 1 : 0)
        .scale({ x: 1, y: this.settingsSectionExpanded(SETTINGS_SECTION_DISPLAY_INTERACTION) ? 1 : 0.98 })
        .translate({ y: this.settingsSectionExpanded(SETTINGS_SECTION_DISPLAY_INTERACTION) ? 0 : -8 })
        .clip(true)
        .animation({ duration: SETTINGS_ACCORDION_ANIMATION_MS, curve: Curve.FastOutSlowIn })

        ListItem() {
          this.settingsAccordionHeader(SETTINGS_SECTION_RDP, $r('sys.symbol.gearshape_fill'),
            'Windows RDP', '分辨率、色深、输入、音频和凭据')
        }.width('100%').padding({ left: 20, right: 20 }).margin({ bottom: 10 })

        // --- Windows RDP 个性化卡片 ---
        ListItem() {
          Column() {
            Text('Windows RDP').fontSize(13).fontWeight(FontWeight.Medium).fontColor(this.pal().text3)
              .fontFamily(this.font()).padding({ left: 8, bottom: 8 })
            Column() {
              this.rdpDesktopPresetRow()
              this.cardDivider()
              this.rdpColorDepthRow()
              this.cardDivider()
              this.rdpControlModeRow()
              this.cardDivider()
              this.rdpAuthIdentityModeRow()
              this.cardDivider()
              this.rustdeskSwitchRow($r('app.media.icon_audio'), '远端音频',
                '播放 Windows 远端会话声音', this.rdpAudioEnabled,
                (on: boolean): void => { this.saveRdpAudioEnabled(on); }, true)
              this.cardDivider()
              this.rustdeskSwitchRow($r('app.media.icon_desktop'), '剪贴板同步',
                '连接时启用文本剪贴板通道', this.rdpClipboardEnabled,
                (on: boolean): void => { this.saveRdpClipboardEnabled(on); }, true)
              this.cardDivider()
              this.rustdeskSwitchRow($r('app.media.icon_folder'), '文件共享盘',
                RDP_DRIVE_REDIRECTION_ENABLED ? '连接时挂载 \\\\tsclient\\' + this.rdpDriveName : '暂时停用，避免影响 Pad/手机连接',
                this.rdpDriveEnabled,
                (on: boolean): void => { this.saveRdpDriveEnabled(on); }, true)
              this.cardDivider()
              this.rdpDriveNameRow()
              this.cardDivider()
              this.rdpCredentialManagerRow()
            }.borderRadius(24).backgroundColor(this.pal().card).backgroundBlurStyle(BlurStyle.Regular)
            .shadow({ radius: 16, color: 'rgba(0,0,0,0.04)', offsetY: 4 })
            .border({ width: 0.5, color: this.pal().cardBorder, style: BorderStyle.Solid })
          }.width('100%').padding({ left: 20, right: 20 }).margin({ bottom: 20 })
        }
        .constraintSize({ maxHeight: this.settingsSectionExpanded(SETTINGS_SECTION_RDP) ?
          this.settingsSectionExpandedMaxHeight(SETTINGS_SECTION_RDP) : 0 })
        .opacity(this.settingsSectionExpanded(SETTINGS_SECTION_RDP) ? 1 : 0)
        .scale({ x: 1, y: this.settingsSectionExpanded(SETTINGS_SECTION_RDP) ? 1 : 0.98 })
        .translate({ y: this.settingsSectionExpanded(SETTINGS_SECTION_RDP) ? 0 : -8 })
        .clip(true)
        .animation({ duration: SETTINGS_ACCORDION_ANIMATION_MS, curve: Curve.FastOutSlowIn })

        ListItem() {
          this.settingsAccordionHeader(SETTINGS_SECTION_RUSTDESK, $r('sys.symbol.gearshape_fill'),
            'RustDesk', '画质、编码、LAN 发现、隐私和音频')
        }.width('100%').padding({ left: 20, right: 20 }).margin({ bottom: 10 })

        // --- RustDesk 个性化卡片 ---
        ListItem() {
          Column() {
            Text('RustDesk').fontSize(13).fontWeight(FontWeight.Medium).fontColor(this.pal().text3)
              .fontFamily(this.font()).padding({ left: 8, bottom: 8 })
            Column() {
              this.rustdeskImageQualityRow()
              this.cardDivider()
              this.rustdeskCodecRow()
              this.cardDivider()
              this.rustdeskControlModeRow()
              this.cardDivider()
              // LAN 发现 — 手动扫描按钮
              Row() {
                Row() { Image($r('app.media.icon_desktop')).width(22).height(22).fillColor(this.pal().text3) }
                  .width(22).height(22).justifyContent(FlexAlign.Center).margin({ left: 9, right: 9 })
                Column() {
                  Text('LAN 发现').fontSize(AppTheme.fontSize.body).fontWeight(FontWeight.Medium)
                    .fontColor(this.pal().text).fontFamily(this.font())
                  Text(this.lanScanning ? '正在扫描...' : (this.lanScanResults.length > 0 ?
                    '发现 ' + this.lanScanResults.length + ' 台设备' : '扫描同局域网 RustDesk 设备'))
                    .fontSize(11).fontColor(this.pal().text3).fontFamily(this.font())
                }.alignItems(HorizontalAlign.Start).layoutWeight(1).margin({ left: 4 })
                Button(this.lanScanning ? '扫描中' : '扫描')
                  .fontSize(12).fontWeight(FontWeight.Medium)
                  .backgroundColor(this.accentColor).fontColor('#FFFFFF')
                  .borderRadius(16).height(30).padding({ left: 12, right: 12 })
                  .enabled(!this.lanScanning)
                  .onClick(() => { this.startLanScan(); })
              }.width('100%').height(64).padding({ left: 16, right: 16 })
              // 扫描结果
              if (this.lanScanResults.length > 0) {
                Column() {
                  ForEach(this.lanScanResults, (peer: DiscoveredRustDeskPeer) => {
                    Row() {
                      Column() {
                        Text(peer.deviceName).fontSize(13).fontColor(this.pal().text).fontFamily(this.font())
                        Row() {
                          Text(peer.peerId).fontSize(10).fontColor(this.pal().text3).fontFamily(this.font())
                          Text(' · ' + peer.host + ':' + peer.port.toString())
                            .fontSize(10).fontColor(this.pal().text3).fontFamily(this.font())
                        }.margin({ top: 2 })
                      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
                      Button('添加').fontSize(11).fontWeight(FontWeight.Medium)
                        .backgroundColor(this.accentColor).fontColor('#FFFFFF')
                        .borderRadius(14).height(26).padding({ left: 10, right: 10 })
                        .onClick(() => { this.addLanPeer(peer); })
                    }.width('100%').padding({ left: 8, right: 8, top: 6, bottom: 6 })
                    .borderRadius(8).backgroundColor(this.pal().surface).margin({ bottom: 6 })
                  })
                }.width('100%').padding({ left: 16, right: 16, bottom: 8 })
              }
              this.cardDivider()
              this.rustdeskSwitchRow($r('app.media.icon_lock'), '允许隐私模式',
                '连接时可请求隐藏远端屏幕', this.rustdeskPrivacyMode,
                (on: boolean): void => { this.saveRustDeskPrivacyMode(on); })
              this.cardDivider()
              this.rustdeskSwitchRow($r('app.media.icon_audio'), '远端音频',
                '接收并播放远端设备声音', this.rustdeskAudioEnabled,
                (on: boolean): void => { this.saveRustDeskAudioEnabled(on); }, true)
              this.cardDivider()
              this.rustdeskSwitchRow($r('app.media.icon_desktop'), '远端应用双指缩放',
                '将双指事件发送到 RustDesk 被控端应用；启用后取代本地画布缩放',
                this.rustdeskRemoteAppTouchScaleEnabled,
                (on: boolean): void => { this.saveRustDeskRemoteAppTouchScaleEnabled(on); }, true)
              this.cardDivider()
              this.rustdeskSwitchRow($r('app.media.icon_desktop'), '显示连接诊断信息',
                '连接时显示延迟、帧率、码率、分辨率和编码信息', this.rustdeskShowDiagnostics,
                (on: boolean): void => { this.saveRustDeskShowDiagnostics(on); }, true)
              this.cardDivider()
              this.rustdeskSwitchRow($r('app.media.icon_desktop'), '专业性能数据（Pro）',
                '进一步显示解码、队列和本机 CPU、内存、GPU 负载', this.rustdeskShowProDiagnostics,
                (on: boolean): void => { this.saveRustDeskShowProDiagnostics(on); }, true)
            }.borderRadius(24).backgroundColor(this.pal().card).backgroundBlurStyle(BlurStyle.Regular)
            .shadow({ radius: 16, color: 'rgba(0,0,0,0.04)', offsetY: 4 })
            .border({ width: 0.5, color: this.pal().cardBorder, style: BorderStyle.Solid })
          }.width('100%').padding({ left: 20, right: 20 }).margin({ bottom: 20 })
        }
        .constraintSize({ maxHeight: this.settingsSectionExpanded(SETTINGS_SECTION_RUSTDESK) ?
          this.settingsSectionExpandedMaxHeight(SETTINGS_SECTION_RUSTDESK) : 0 })
        .opacity(this.settingsSectionExpanded(SETTINGS_SECTION_RUSTDESK) ? 1 : 0)
        .scale({ x: 1, y: this.settingsSectionExpanded(SETTINGS_SECTION_RUSTDESK) ? 1 : 0.98 })
        .translate({ y: this.settingsSectionExpanded(SETTINGS_SECTION_RUSTDESK) ? 0 : -8 })
        .clip(true)
        .animation({ duration: SETTINGS_ACCORDION_ANIMATION_MS, curve: Curve.FastOutSlowIn })

        ListItem() {
          this.settingsAccordionHeader(SETTINGS_SECTION_SECURITY, $r('sys.symbol.lock_shield_fill'),
            '数据安全', '端到端加密、2FA 隐私和 SSH 指纹')
        }.width('100%').padding({ left: 20, right: 20 }).margin({ bottom: 10 })

        // --- 数据安全卡片 ---
        ListItem() {
          Column() {
            Text('数据安全').fontSize(13).fontWeight(FontWeight.Medium).fontColor(this.pal().text3)
              .fontFamily(this.font()).padding({ left: 8, bottom: 8 })
            Column() {
              // ---- 端到端加密 ----
              Row() {
                Row() {
                  SymbolGlyph($r('sys.symbol.lock_shield_fill'))
                    .fontSize(22).fontColor([this.cryptoEnabled ? this.accentColor : this.pal().text3])
                }.width(22).height(22).justifyContent(FlexAlign.Center).margin({ left: 9, right: 9 })
                Column() {
                  Text('端到端加密')
                    .fontSize(AppTheme.fontSize.body).fontWeight(FontWeight.Medium)
                    .fontColor(this.pal().text).fontFamily(this.font())
                  Text(this.cryptoEnabled ? (this.cryptoUnlocked ? '已启用 · 数据已加密保护' : '已锁定 · 需解锁后解密数据') : '未启用 · 主机密码、SSH密钥、2FA将加密后云同步')
                    .fontSize(11).fontColor(this.pal().text3).fontFamily(this.font())
                    .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
                }.alignItems(HorizontalAlign.Start).layoutWeight(1).margin({ left: 10 })
                if (this.cryptoEnabled) {
                  if (this.cryptoUnlocked) {
                    Row() {
                      Text('已启用').fontSize(12).fontColor(this.pal().success).fontWeight(FontWeight.Medium)
                        .margin({ right: 6 })
                      Text('关闭').fontSize(11).fontColor(this.pal().text3)
                        .onClick(() => { this.confirmDisableEncryption(); })
                      Text('·').fontSize(11).fontColor(this.pal().text3)
                        .margin({ left: 4, right: 4 })
                      Text('重置').fontSize(11).fontColor(this.pal().danger)
                        .onClick(() => { this.confirmResetEncryption(); })
                    }
                  } else {
                    Row() {
                      Text('已锁定').fontSize(12).fontColor(this.pal().danger).fontWeight(FontWeight.Medium)
                        .onClick(() => {
                          this.openSettingsLeafSheet(SETTINGS_SHEET_POPUP, (): void => {
                            this.cryptoMode = 1;
                            this.popupSheetMode = 0;
                          });
                        })
                        .margin({ right: 6 })
                      Text('重置').fontSize(11).fontColor(this.pal().danger)
                        .onClick(() => { this.confirmResetEncryption(); })
                    }
                  }
                } else {
                  Button('启用').height(32).fontSize(12)
                    .backgroundColor(this.accentColor).fontColor('#FFFFFF').borderRadius(8)
                    .onClick(() => {
                      this.openSettingsLeafSheet(SETTINGS_SHEET_POPUP, (): void => {
                        this.cryptoMode = 0;
                        this.popupSheetMode = 0;
                      });
                    })
                }
              }.width('100%').height(64).padding({ left: 16, right: 16 })

              this.cardDivider()

              // ---- TOTP 隐私保护 ----
              Row() {
                Row() {
                  SymbolGlyph($r('sys.symbol.lock_fill'))
                    .fontSize(22).fontColor([this.totpPageLocked ? this.accentColor : this.pal().text3])
                }.width(22).height(22).justifyContent(FlexAlign.Center).margin({ left: 9, right: 9 })
                Text('TOTP 隐私保护')
                  .fontSize(AppTheme.fontSize.body).fontWeight(FontWeight.Medium)
                  .fontColor(this.pal().text).fontFamily(this.font()).layoutWeight(1).margin({ left: 4 })
                Toggle({ type: ToggleType.Switch, isOn: this.totpPageLocked })
                  .selectedColor(this.accentColor)
                  .scale({ x: 0.88, y: 0.88 })
                  .onChange(async (on: boolean) => {
                    if (on) {
                      const r = await showLockGate('绑定 2FA 保护', 'biometric');
                      if (r.ok) {
                        this.totpPageLocked = true;
                        this.saveTotpLock(true);
                        promptAction.showToast({ message: '2FA 已锁定', duration: 1500 });
                      } else {
                        promptAction.showToast({ message: lockGateErrorMessage(r) || '验证未通过', duration: 2000 });
                        this.totpPageLocked = false;
                      }
                    } else {
                      const r = await showLockGate('解除 2FA 保护', 'biometric');
                      if (r.ok) {
                        this.totpPageLocked = false;
                        AppStorage.setOrCreate('totpUnlocked', false);
                        this.saveTotpLock(false);
                        promptAction.showToast({ message: '2FA 已解锁', duration: 1500 });
                      } else {
                        promptAction.showToast({ message: lockGateErrorMessage(r) || '验证未通过', duration: 2000 });
                      }
                    }
                  })
              }.width('100%').height(60).padding({ left: 16, right: 16 })

              this.cardDivider()

              this.cardActionRow($r('app.media.icon_terminal'), 'SSH 主机指纹',
                this.sshTrustedHostsView.length.toString() + ' 条已信任记录',
                (): void => {
                  this.openSettingsLeafSheet(SETTINGS_SHEET_POPUP, (): void => {
                    this.popupSheetMode = 2;
                  });
                })
              this.cardDivider()
              this.cardActionRow($r('app.media.icon_desktop'), 'RDP 证书信任',
                this.rdpTrustedHostsView.length.toString() + ' 条已信任记录',
                (): void => {
                  this.openSettingsLeafSheet(SETTINGS_SHEET_POPUP, (): void => {
                    this.popupSheetMode = POPUP_SHEET_RDP_CERTIFICATES;
                  });
                })
              this.cardDivider()
              this.cardActionRow($r('app.media.icon_lock'), 'RustDesk 认证信任',
                this.rustDeskHosts().length.toString() + ' 台主机',
                (): void => {
                  this.openSettingsLeafSheet(SETTINGS_SHEET_POPUP, (): void => {
                    this.popupSheetMode = POPUP_SHEET_RUSTDESK_AUTH_TRUST;
                  });
                })
            }.borderRadius(24).backgroundColor(this.pal().card).backgroundBlurStyle(BlurStyle.Regular)
            .shadow({ radius: 16, color: 'rgba(0,0,0,0.04)', offsetY: 4 })
            .border({ width: 0.5, color: this.pal().cardBorder, style: BorderStyle.Solid })
          }.width('100%').padding({ left: 20, right: 20 }).margin({ bottom: 20 })
        }
        .constraintSize({ maxHeight: this.settingsSectionExpanded(SETTINGS_SECTION_SECURITY) ?
          this.settingsSectionExpandedMaxHeight(SETTINGS_SECTION_SECURITY) : 0 })
        .opacity(this.settingsSectionExpanded(SETTINGS_SECTION_SECURITY) ? 1 : 0)
        .scale({ x: 1, y: this.settingsSectionExpanded(SETTINGS_SECTION_SECURITY) ? 1 : 0.98 })
        .translate({ y: this.settingsSectionExpanded(SETTINGS_SECTION_SECURITY) ? 0 : -8 })
        .clip(true)
        .animation({ duration: SETTINGS_ACCORDION_ANIMATION_MS, curve: Curve.FastOutSlowIn })

        ListItem() {
          this.settingsAccordionHeader(SETTINGS_SECTION_TUTORIAL, $r('sys.symbol.doc_plaintext'),
            '教程', '快速使用和前置操作指南')
        }.width('100%').padding({ left: 20, right: 20 }).margin({ bottom: 10 })

        // --- 教程卡片 ---
        ListItem() {
          Column() {
            Text('教程').fontSize(13).fontWeight(FontWeight.Medium).fontColor(this.pal().text3)
              .fontFamily(this.font()).padding({ left: 8, bottom: 8 })
            Column() {
              this.cardActionRow($r('app.media.icon_info'), '简单使用教程', '了解连接、传输、同步、安全与反馈',
                (): void => {
                  this.openSettingsLeafSheet(SETTINGS_SHEET_POPUP, (): void => {
                    this.aboutSheetMode = 0;
                    this.popupSheetMode = 1;
                  });
                })
              this.cardDivider()
              this.cardActionRow($r('app.media.icon_info'), '如何进行前置操作', 'FreeRDP 与 RustDesk 部署指南',
                (): void => {
                  this.openSettingsLeafSheet(SETTINGS_SHEET_POPUP, (): void => {
                    this.aboutSheetMode = 3;
                    this.popupSheetMode = 1;
                  });
                })
            }.borderRadius(24).backgroundColor(this.pal().card).backgroundBlurStyle(BlurStyle.Regular)
            .shadow({ radius: 16, color: 'rgba(0,0,0,0.04)', offsetY: 4 })
            .border({ width: 0.5, color: this.pal().cardBorder, style: BorderStyle.Solid })
          }.width('100%').padding({ left: 20, right: 20 }).margin({ bottom: 20 })
        }
        .constraintSize({ maxHeight: this.settingsSectionExpanded(SETTINGS_SECTION_TUTORIAL) ?
          this.settingsSectionExpandedMaxHeight(SETTINGS_SECTION_TUTORIAL) : 0 })
        .opacity(this.settingsSectionExpanded(SETTINGS_SECTION_TUTORIAL) ? 1 : 0)
        .scale({ x: 1, y: this.settingsSectionExpanded(SETTINGS_SECTION_TUTORIAL) ? 1 : 0.98 })
        .translate({ y: this.settingsSectionExpanded(SETTINGS_SECTION_TUTORIAL) ? 0 : -8 })
        .clip(true)
        .animation({ duration: SETTINGS_ACCORDION_ANIMATION_MS, curve: Curve.FastOutSlowIn })

        ListItem() {
          this.settingsAccordionHeader(SETTINGS_SECTION_ABOUT, $r('sys.symbol.message'),
            '关于', '版本、隐私政策和应用信息')
        }.width('100%').padding({ left: 20, right: 20 }).margin({ bottom: 10 })

        // --- 关于卡片 ---
        ListItem() {
          Column() {
            Text('关于').fontSize(13).fontWeight(FontWeight.Medium).fontColor(this.pal().text3)
              .fontFamily(this.font()).padding({ left: 8, bottom: 8 })
            Column() {
              this.cardItemRow($r('app.media.icon_info'), '版本', CURRENT_RELEASE_VERSION + ' · FreeRDP+RustDesk+SSH')
              this.cardDivider()
              this.cardActionRow($r('app.media.icon_info'), '关于应用', '开源协议、作者说明和联系方式',
                (): void => {
                  this.openSettingsLeafSheet(SETTINGS_SHEET_POPUP, (): void => {
                    this.aboutSheetMode = 1;
                    this.popupSheetMode = 1;
                  });
                })
              this.cardDivider()
              this.cardActionRow($r('app.media.icon_lock'), '隐私政策', '数据收集、权限和安全说明',
                (): void => {
                  this.openSettingsLeafSheet(SETTINGS_SHEET_POPUP, (): void => {
                    this.aboutSheetMode = 2;
                    this.popupSheetMode = 1;
                  });
                })
            }.borderRadius(24).backgroundColor(this.pal().card).backgroundBlurStyle(BlurStyle.Regular)
            .shadow({ radius: 16, color: 'rgba(0,0,0,0.04)', offsetY: 4 })
            .border({ width: 0.5, color: this.pal().cardBorder, style: BorderStyle.Solid })
          }.width('100%').padding({ left: 20, right: 20 }).margin({ bottom: 20 })
        }
        .constraintSize({ maxHeight: this.settingsSectionExpanded(SETTINGS_SECTION_ABOUT) ?
          this.settingsSectionExpandedMaxHeight(SETTINGS_SECTION_ABOUT) : 0 })
        .opacity(this.settingsSectionExpanded(SETTINGS_SECTION_ABOUT) ? 1 : 0)
        .scale({ x: 1, y: this.settingsSectionExpanded(SETTINGS_SECTION_ABOUT) ? 1 : 0.98 })
        .translate({ y: this.settingsSectionExpanded(SETTINGS_SECTION_ABOUT) ? 0 : -8 })
        .clip(true)
        .animation({ duration: SETTINGS_ACCORDION_ANIMATION_MS, curve: Curve.FastOutSlowIn })

        ListItem() {
          this.settingsActionHeader($r('sys.symbol.message'), '反馈',
            '邮箱反馈或加入畅联群聊',
            (): void => { this.openFeedbackSheet(); })
        }.width('100%').padding({ left: 20, right: 20 }).margin({ bottom: 10 })

        ListItem() {
          this.settingsActionHeader($r('sys.symbol.star_fill'), '评价',
            SETTINGS_RATING_SUBTITLE,
            (): void => { this.openAppRatingPage(); })
        }.width('100%').padding({ left: 20, right: 20 }).margin({ bottom: 20 })

        ListItem() { Column().height(120) }
      }
      .width('100%').layoutWeight(1)
      .scrollBar(BarState.Off).edgeEffect(EdgeEffect.Spring)
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
      .overlay(this.TitleBarOverlay(), { align: Alignment.Top })
    }
    .width('100%').height('100%')

  }

  // T-210: 前置校验面板 (单 @Builder, 内联状态以避免 ArkTS 限制)
  // T-210: 前置校验面板 (bindSheet builder — 系统管理模态层+样式)
  @Builder rdpCertificatePanel() {
    Column() {
      if (this.rdpCertificateState === RdpCertificatePreflightState.PROBING) {
        Row() {
          LoadingProgress().width(32).height(32).color(this.accentColor)
          Text('正在检查 RDP 证书...')
            .fontSize(17).fontWeight(FontWeight.Bold).fontColor(this.pal().text)
            .fontFamily(this.font()).margin({ left: 12 }).layoutWeight(1)
        }.width('100%').margin({ bottom: 18 })
        Text(this.rdpCertificateHostLabel)
          .fontSize(13).fontColor(this.pal().text3).fontFamily(this.font()).width('100%')
      } else if (this.rdpCertificateState === RdpCertificatePreflightState.ERROR) {
        Row() {
          SymbolGlyph($r('sys.symbol.exclamationmark_triangle'))
            .fontSize(42).fontColor(['#F5C400'])
          Column() {
            Text('RDP 证书检查失败')
              .fontSize(17).fontWeight(FontWeight.Bold).fontColor(this.pal().text)
              .fontFamily(this.font())
            Text(this.rdpCertificateError || '无法读取 RDP 主机证书')
              .fontSize(14).fontColor(this.pal().text2).fontFamily(this.font())
              .margin({ top: 8 })
          }.layoutWeight(1).margin({ left: 16 })
        }.width('100%')
      } else {
        Row() {
          SymbolGlyph($r('sys.symbol.lock_shield_fill'))
            .fontSize(58).fontColor(['#A87300'])
          Text(this.rdpCertificateWarning)
            .fontSize(16).fontWeight(FontWeight.Bold).fontColor(this.pal().text)
            .fontFamily(this.font()).lineHeight(24).layoutWeight(1).margin({ left: 18 })
        }.width('100%').alignItems(VerticalAlign.Top)
        if (this.rdpCertificateShowDetails) {
          this.rdpCertificateInfoCard()
        }
      }
      this.rdpCertificateButtonsContent()
    }
    .width('100%')
    .padding(20)
    .backgroundColor(this.pal().bg)
    .backgroundBlurStyle(BlurStyle.Regular)
    .borderRadius(this.breakpoint === 'sm' ? { topLeft: 20, topRight: 20, bottomLeft: 0, bottomRight: 0 } : 20)
    .constraintSize({ maxWidth: 760 })
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
  }

  @Builder rdpCertificateInfoCard() {
    Column() {
      Text('证书').fontSize(13).fontWeight(FontWeight.Medium)
        .fontColor(this.pal().text2).fontFamily(this.font()).width('100%')
      Text('主机: ' + this.rdpCertificateHostLabel)
        .fontSize(12).fontColor(this.pal().text).fontFamily('monospace')
        .width('100%').margin({ top: 8 })
      Text('CN: ' + (this.rdpCertificateInfo?.commonName || '(无)'))
        .fontSize(12).fontColor(this.pal().text).fontFamily('monospace')
        .width('100%').margin({ top: 4 })
      Text('Issuer: ' + (this.rdpCertificateInfo?.issuer || '(无)'))
        .fontSize(12).fontColor(this.pal().text).fontFamily('monospace')
        .width('100%').margin({ top: 4 })
      Text('Subject: ' + (this.rdpCertificateInfo?.subject || '(无)'))
        .fontSize(12).fontColor(this.pal().text).fontFamily('monospace')
        .width('100%').margin({ top: 4 })
      Text(this.rdpCertificateInfo?.fingerprintSha256 || '')
        .fontSize(12).fontColor(this.pal().text).fontFamily('monospace')
        .width('100%').margin({ top: 8 })
    }
    .width('100%')
    .padding(14)
    .backgroundColor(this.pal().surface)
    .borderRadius(10)
    .margin({ top: 16 })
  }

  @Builder rdpCertificateButtonsContent() {
    if (this.rdpCertificateState === RdpCertificatePreflightState.PROBING) {
      Row() {
        Button('取消').fontSize(14).height(40).layoutWeight(1)
          .backgroundColor(this.pal().surface).fontColor(this.pal().text2).borderRadius(10)
          .onClick(() => { this.doRdpCertificateCancel(); })
      }.width('100%').margin({ top: 20 })
    } else if (this.rdpCertificateState === RdpCertificatePreflightState.ERROR) {
      Row() {
        Button('取消').fontSize(14).height(40).layoutWeight(1)
          .backgroundColor(this.pal().surface).fontColor(this.pal().text2).borderRadius(10)
          .onClick(() => { this.doRdpCertificateCancel(); })
        Button('重试').fontSize(14).height(40).layoutWeight(1)
          .backgroundColor(this.accentColor).fontColor('#FFFFFF').borderRadius(10).margin({ left: 12 })
          .onClick(() => { this.doRdpCertificateRetryWrap(); })
      }.width('100%').margin({ top: 20 })
    } else {
      Column() {
        Row() {
          Button(this.rdpCertificateShowDetails ? '隐藏证书' : '显示证书')
            .fontSize(14).height(40).layoutWeight(1)
            .backgroundColor(this.pal().surface).fontColor(this.pal().text).borderRadius(10)
            .onClick(() => { this.rdpCertificateShowDetails = !this.rdpCertificateShowDetails; })
          Button('取消').fontSize(14).height(40).layoutWeight(1)
            .backgroundColor(this.pal().surface).fontColor(this.pal().text2).borderRadius(10).margin({ left: 12 })
            .onClick(() => { this.doRdpCertificateCancel(); })
        }.width('100%')
        Row() {
          Button('继续连接').fontSize(14).height(40).layoutWeight(1)
            .backgroundColor(this.pal().surface).fontColor(this.pal().text).borderRadius(10)
            .onClick(() => { this.doRdpCertificateContinueOnceWrap(); })
          Button('信任').fontSize(14).height(40).layoutWeight(1)
            .backgroundColor(this.accentColor).fontColor('#FFFFFF').borderRadius(10).margin({ left: 12 })
            .onClick(() => { this.doRdpCertificateTrustWrap(); })
        }.width('100%').margin({ top: 12 })
      }.width('100%').margin({ top: 20 })
    }
  }

  @Builder sshPreflightPanel() {
    Column() {
      this.sshPreflightTitle()
      Scroll() {
        Column() {
          if (this.sshPreflightState === SshPreflightState.PROBING ||
              this.sshPreflightState === SshPreflightState.VERIFYING_PASSPHRASE) {
            this.sshPreflightProbingContent()
          } else if (this.sshPreflightState === SshPreflightState.TRUST_FIRST_TIME) {
            this.sshPreflightTrustFirstContent()
          } else if (this.sshPreflightState === SshPreflightState.TRUSTED_MATCH) {
            this.sshPreflightTrustedMatchContent()
          } else if (this.sshPreflightState === SshPreflightState.HOST_KEY_CHANGED) {
            this.sshPreflightChangedContent()
          } else if (this.sshPreflightState === SshPreflightState.PASSPHRASE_REQUIRED) {
            this.sshPreflightPassphraseContent()
          } else if (this.sshPreflightState === SshPreflightState.ERROR) {
            this.sshPreflightErrorContent()
          }
        }.width('100%')
      }.constraintSize({ maxHeight: 380 }).scrollBar(BarState.Off)
      this.sshPreflightButtonsContent()
    }
    .width('100%')
    .padding(20)
    .backgroundColor(this.pal().bg)
    .backgroundBlurStyle(BlurStyle.Regular)
    .borderRadius(this.breakpoint === 'sm' ? { topLeft: 20, topRight: 20, bottomLeft: 0, bottomRight: 0 } : 20)
    .constraintSize({ maxWidth: 560 })
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
  }

  @Builder sshPreflightTitle() {
    Row() {
      if (this.sshPreflightState === SshPreflightState.PROBING) {
        Text('正在获取主机指纹...').fontSize(17).fontWeight(FontWeight.Bold).fontColor(this.pal().text).fontFamily(this.font()).layoutWeight(1)
      } else if (this.sshPreflightState === SshPreflightState.VERIFYING_PASSPHRASE) {
        Text('正在验证私钥...').fontSize(17).fontWeight(FontWeight.Bold).fontColor(this.pal().text).fontFamily(this.font()).layoutWeight(1)
      } else if (this.sshPreflightState === SshPreflightState.TRUST_FIRST_TIME) {
        Text('首次连接 SSH 主机').fontSize(17).fontWeight(FontWeight.Bold).fontColor(this.pal().text).fontFamily(this.font()).layoutWeight(1)
      } else if (this.sshPreflightState === SshPreflightState.TRUSTED_MATCH) {
        Text('主机指纹已验证').fontSize(17).fontWeight(FontWeight.Bold).fontColor(this.pal().text).fontFamily(this.font()).layoutWeight(1)
      } else if (this.sshPreflightState === SshPreflightState.HOST_KEY_CHANGED) {
        Text('⚠ SSH 主机指纹已改变').fontSize(17).fontWeight(FontWeight.Bold).fontColor('#FF5252').fontFamily(this.font()).layoutWeight(1)
      } else if (this.sshPreflightState === SshPreflightState.PASSPHRASE_REQUIRED) {
        Text('输入私钥密码').fontSize(17).fontWeight(FontWeight.Bold).fontColor(this.pal().text).fontFamily(this.font()).layoutWeight(1)
      } else if (this.sshPreflightState === SshPreflightState.ERROR) {
        Text('连接预检失败').fontSize(17).fontWeight(FontWeight.Bold).fontColor('#FF5252').fontFamily(this.font()).layoutWeight(1)
      }
      if (this.sshPreflightState !== SshPreflightState.PROBING &&
          this.sshPreflightState !== SshPreflightState.VERIFYING_PASSPHRASE) {
        SymbolGlyph($r('sys.symbol.xmark'))
          .fontSize(16).fontColor([this.pal().text3])
          .onClick(() => { this.doSshPreflightCancel(); })
      }
    }.width('100%').margin({ bottom: 16 })
  }

  @Builder sshPreflightProbingContent() {
    Column() {
      LoadingProgress().width(32).height(32).color(this.accentColor)
      Text(this.sshPreflightState === SshPreflightState.VERIFYING_PASSPHRASE ? '正在验证私钥认证...' : '正在获取主机指纹...')
        .fontSize(14).fontColor(this.pal().text2).margin({ top: 12 }).fontFamily(this.font())
      Text(this.sshPreflightHostLabel)
        .fontSize(13).fontColor(this.pal().text3).margin({ top: 4 }).fontFamily(this.font())
    }.width('100%').padding({ top: 30, bottom: 30 })
  }

  @Builder sshPreflightTrustFirstContent() {
    Column() {
      this.sshHostKeyInfoCard()
      Text('这是首次连接该 SSH 主机。请确认此指纹与服务器管理员提供的一致。')
        .fontSize(13).fontColor(this.pal().text2).margin({ top: 16 }).fontFamily(this.font())
      Text('确认后, RemoteDesktop 会保存此主机指纹, 后续连接会自动校验。')
        .fontSize(12).fontColor(this.pal().text3).margin({ top: 8 }).fontFamily(this.font())
    }.width('100%')
  }

  @Builder sshPreflightTrustedMatchContent() {
    Column() {
      Row() {
        SymbolGlyph($r('sys.symbol.checkmark_shield')).fontSize(40).fontColor(['#4CAF50'])
        Text('主机指纹已验证').fontSize(16).fontWeight(FontWeight.Medium).fontColor('#4CAF50').fontFamily(this.font()).margin({ left: 10 })
      }.margin({ bottom: 16 })
      this.sshHostKeyInfoCard()
    }.width('100%')
  }

  @Builder sshPreflightChangedContent() {
    Column() {
      Row() {
        SymbolGlyph($r('sys.symbol.exclamationmark_triangle')).fontSize(40).fontColor(['#FF5252'])
        Text('主机指纹已改变').fontSize(16).fontWeight(FontWeight.Bold).fontColor('#FF5252').fontFamily(this.font()).margin({ left: 10 })
      }.margin({ bottom: 16 })
      Text('已保存的指纹').fontSize(13).fontWeight(FontWeight.Medium).fontColor(this.pal().text2).fontFamily(this.font()).margin({ bottom: 8 })
      Row() {
        Text('算法: ').fontSize(13).fontColor(this.pal().text3).fontFamily(this.font())
        Text(this.sshPreflightSavedAlgorithm).fontSize(13).fontColor(this.pal().text).fontFamily('monospace').fontWeight(FontWeight.Medium)
      }.width('100%')
      Divider().margin({ top: 12, bottom: 12 }).color(this.pal().divider)
      Text('当前指纹').fontSize(13).fontWeight(FontWeight.Medium).fontColor(this.pal().text2).fontFamily(this.font()).margin({ bottom: 8 })
      this.sshHostKeyInfoCard()
      Text('这可能表示服务器重装或密钥轮换, 也可能是中间人攻击。')
        .fontSize(13).fontColor('#FF5252').margin({ top: 16 }).fontFamily(this.font())
    }.width('100%')
  }

  @Builder sshPreflightPassphraseContent() {
    Column() {
      Text('主机指纹已确认。此私钥受密码保护, 请输入私钥密码后继续连接。')
        .fontSize(13).fontColor(this.pal().text2).margin({ bottom: 16 }).fontFamily(this.font())
      Row() {
        TextInput({ placeholder: '输入私钥密码', text: this.sshPreflightPassphraseInput })
          .type(this.sshPreflightPassphraseShowPw ? InputType.Normal : InputType.Password)
          .height(44).backgroundColor(this.pal().surface).borderRadius(8)
          .fontColor(this.pal().text).placeholderColor(this.pal().text3)
          .layoutWeight(1).padding({ left: 12, right: 12 })
          .onChange((v: string) => { this.sshPreflightPassphraseInput = v; })
        SymbolGlyph(this.sshPreflightPassphraseShowPw ? $r('sys.symbol.eye_slash') : $r('sys.symbol.eye'))
          .fontSize(18).fontColor([this.pal().text3]).margin({ left: 8 })
          .onClick(() => { this.sshPreflightPassphraseShowPw = !this.sshPreflightPassphraseShowPw; })
      }.width('100%').margin({ bottom: 12 })
      Row() {
        Checkbox()
          .select(this.sshPreflightPassphraseSaveToHost)
          .selectedColor(this.accentColor)
          .onChange((v: boolean) => { this.sshPreflightPassphraseSaveToHost = v; })
        Text(this.hasSavedSshPreflightPassphrase() ? '验证成功后更新保存的私钥密码' : '保存到此主机 (加密存储)')
          .fontSize(13).fontColor(this.pal().text2).fontFamily(this.font()).margin({ left: 6 })
      }
      if (this.sshPreflightError !== '') {
        Text(this.sshPreflightError).fontSize(13).fontColor('#FF5252').margin({ top: 12 }).fontFamily(this.font())
      }
    }.width('100%')
  }

  @Builder sshPreflightErrorContent() {
    Column() {
      Row() {
        SymbolGlyph($r('sys.symbol.xmark_circle')).fontSize(36).fontColor(['#FF5252'])
        Text(this.sshPreflightError || '无法读取 SSH 主机指纹')
          .fontSize(14).fontColor('#FF5252').fontFamily(this.font()).margin({ left: 10 }).layoutWeight(1)
      }.width('100%').margin({ bottom: 16 })
      Text('原因: 网络不可达、端口不是 SSH 或 KEX 握手失败。')
        .fontSize(12).fontColor(this.pal().text3).fontFamily(this.font())
    }.width('100%').padding({ top: 20, bottom: 16 })
  }

  @Builder sshHostKeyInfoCard() {
    Column() {
      Row() {
        Text(this.sshPreflightHostLabel)
          .fontSize(13).fontColor(this.pal().text).fontFamily(this.font()).fontWeight(FontWeight.Medium)
      }.width('100%').margin({ bottom: 10 })
      if (this.sshPreflightHostKeyInfo) {
        Row() {
          Text('算法: ').fontSize(13).fontColor(this.pal().text3).fontFamily(this.font())
          Text(this.sshPreflightHostKeyInfo.algorithm).fontSize(13).fontColor(this.pal().text).fontFamily('monospace').fontWeight(FontWeight.Medium)
        }.width('100%').margin({ bottom: 4 })
        Row() {
          Text('SHA256:').fontSize(13).fontWeight(FontWeight.Medium).fontColor(this.pal().text2).fontFamily(this.font())
          Text(this.sshPreflightHostKeyInfo.fingerprintSha256)
            .fontSize(12).fontColor(this.pal().text).fontFamily('monospace').margin({ left: 6 }).layoutWeight(1)
        }.width('100%')
      }
    }
    .width('100%').padding(14)
    .backgroundColor(this.pal().surface).borderRadius(10)
  }

  @Builder sshPreflightButtonsContent() {
    Row() {
      if (this.sshPreflightState === SshPreflightState.PROBING ||
          this.sshPreflightState === SshPreflightState.VERIFYING_PASSPHRASE) {
        Button('取消').fontSize(14).height(40).layoutWeight(1)
          .backgroundColor(this.pal().surface).fontColor(this.pal().text2).borderRadius(10)
          .onClick(() => { this.doSshPreflightCancel(); })
      } else if (this.sshPreflightState === SshPreflightState.ERROR) {
        Button('取消').fontSize(14).height(40).layoutWeight(1)
          .backgroundColor(this.pal().surface).fontColor(this.pal().text2).borderRadius(10)
          .onClick(() => { this.doSshPreflightCancel(); })
        Button('重试').fontSize(14).height(40).layoutWeight(1)
          .backgroundColor(this.accentColor).fontColor('#FFFFFF').borderRadius(10).margin({ left: 12 })
          .onClick(() => { this.doSshPreflightRetryWrap(); })
      } else if (this.sshPreflightState === SshPreflightState.TRUST_FIRST_TIME) {
        Button('取消').fontSize(14).height(40).layoutWeight(1)
          .backgroundColor(this.pal().surface).fontColor(this.pal().text2).borderRadius(10)
          .onClick(() => { this.doSshPreflightCancel(); })
        Button('信任并继续').fontSize(14).height(40).layoutWeight(1)
          .backgroundColor(this.accentColor).fontColor('#FFFFFF').borderRadius(10).margin({ left: 12 })
          .onClick(() => { this.doSshPreflightTrustFirstWrap(); })
      } else if (this.sshPreflightState === SshPreflightState.TRUSTED_MATCH) {
        Button('取消').fontSize(14).height(40).layoutWeight(1)
          .backgroundColor(this.pal().surface).fontColor(this.pal().text2).borderRadius(10)
          .onClick(() => { this.doSshPreflightCancel(); })
        Button('继续连接').fontSize(14).height(40).layoutWeight(1)
          .backgroundColor(this.accentColor).fontColor('#FFFFFF').borderRadius(10).margin({ left: 12 })
          .onClick(() => { this.doSshPreflightContinueWrap(); })
      } else if (this.sshPreflightState === SshPreflightState.HOST_KEY_CHANGED) {
        Button('断开').fontSize(14).height(40).layoutWeight(1)
          .backgroundColor('#FF5252').fontColor('#FFFFFF').borderRadius(10)
          .onClick(() => { this.doSshPreflightCancel(); })
        Button('更新并继续').fontSize(14).height(40).layoutWeight(1)
          .backgroundColor(this.accentColor).fontColor('#FFFFFF').borderRadius(10).margin({ left: 12 })
          .onClick((): void => { this.doSshPreflightUpdateWrap(); })
      } else if (this.sshPreflightState === SshPreflightState.PASSPHRASE_REQUIRED) {
        Button('取消').fontSize(14).height(40).layoutWeight(1)
          .backgroundColor(this.pal().surface).fontColor(this.pal().text2).borderRadius(10)
          .onClick(() => { this.doSshPreflightCancel(); })
        Button('验证并连接').fontSize(14).height(40).layoutWeight(1)
          .backgroundColor(this.accentColor).fontColor('#FFFFFF').borderRadius(10).margin({ left: 12 })
          .onClick(() => { this.doSshPreflightVerifyWrap(); })
      }
    }.width('100%').margin({ top: 16 })
  }

  @Builder TitleBarOverlay() {
    Stack() {
      Column() {
        Row().width('100%').height(this.topSafeHeightVp() + this.titleOffsetY())
        Row() {
          Text('设置').fontSize(27).fontWeight(FontWeight.Bold).fontColor(this.pal().text).fontFamily(this.font())
        }.width('100%').padding({ left: 24, right: 24, bottom: 8 })
      }.width('100%')
      .backgroundColor(Color.Transparent)
    }
    .width('100%')
    .height(this.titleTopBarHeight())
    .hitTestBehavior(HitTestMode.Transparent)
  }

  // ==================== 统一弹窗 (单 bindSheet) ====================

  @Builder unifiedPopupSheet() {
    if (this.popupSheetMode === 0) {
      this.cryptoSheet()
    } else if (this.popupSheetMode === 2) {
      this.sshHostKeyManagerSheet()
    } else if (this.popupSheetMode === POPUP_SHEET_RDP_CERTIFICATES) {
      this.rdpCertificateManagerSheet()
    } else if (this.popupSheetMode === POPUP_SHEET_RUSTDESK_AUTH_TRUST) {
      this.rustDeskAuthTrustManagerSheet()
    } else if (this.popupSheetMode === 3) {
      this.cloudSyncSheet()
    } else {
      AboutSettingsSheet({
        aboutSheetMode: this.aboutSheetMode,
        onClose: (): void => { this.closeSettingsLeafSheet(); }
      })
    }
  }

  @Builder cloudSyncSheet() {
    Column() {
      Row() {
        if (this.cloudSyncStep === CLOUD_SYNC_SHEET_UPLOAD_CONFIRM ||
          this.cloudSyncStep === CLOUD_SYNC_SHEET_DOWNLOAD_CONFIRM ||
          this.cloudSyncStep === CLOUD_SYNC_SHEET_MANAGE_TABLES ||
          this.cloudSyncStep === CLOUD_SYNC_SHEET_BACKUP_CONFIRM ||
          this.cloudSyncStep === CLOUD_SYNC_SHEET_RESTORE_CONFIRM) {
          Text('返回').fontSize(14).fontWeight(FontWeight.Medium).fontColor(this.accentColor)
            .width(44).onClick((): void => { this.returnToCloudSyncActions(); })
        } else {
          Blank().width(44)
        }
        Text('云同步').fontSize(20).fontWeight(FontWeight.Bold).fontColor(this.pal().text)
          .fontFamily(this.font()).layoutWeight(1).textAlign(TextAlign.Center)
        if (this.currentCloudSyncSheetSpec().canDismiss) {
          SymbolGlyph($r('sys.symbol.xmark')).fontSize(18).fontColor([this.pal().text2]).width(44).height(36)
            .onClick((): void => { this.closeSettingsLeafSheet(); })
        } else {
          Blank().width(44)
        }
      }.width('100%').padding({ left: 20, right: 20, top: 18 })

      if (this.cloudSyncStep === CLOUD_SYNC_SHEET_ACTIONS) {
        Column() {
          Row() {
            Row() { SymbolGlyph($r('sys.symbol.cloud_fill')).fontSize(24).fontColor([this.accentColor]) }
              .width(46).height(46).borderRadius(23).backgroundColor(this.pal().surface).justifyContent(FlexAlign.Center)
            Column() {
              Text('华为云空间').fontSize(16).fontWeight(FontWeight.Bold).fontColor(this.pal().text).fontFamily(this.font())
              Text('主机、RDP 凭据、SSH 密钥、2FA 与个性化设置共 7 类数据')
                .fontSize(11).fontColor(this.pal().text3).fontFamily(this.font()).maxLines(2).margin({ top: 3 })
            }.alignItems(HorizontalAlign.Start).layoutWeight(1).margin({ left: 12 })
          }.width('100%').alignItems(VerticalAlign.Center)

          Text('两项操作都会覆盖其中一端的数据，继续前会再次确认。')
            .fontSize(12).fontColor(this.pal().text2).fontFamily(this.font()).width('100%').margin({ top: 16, bottom: 10 })

          Column() {
            Row() {
              Row() { SymbolGlyph($r('sys.symbol.arrowshape_right_fill')).fontSize(19).fontColor(['#B66A00']) }
                .width(40).height(40).borderRadius(20).backgroundColor(this.pal().surface).justifyContent(FlexAlign.Center)
              Column() {
                Text(this.currentCloudSyncSheetSpec().primaryLabel).fontSize(15).fontWeight(FontWeight.Medium).fontColor(this.pal().text).fontFamily(this.font())
                Text('以当前设备为准，覆盖云端存档').fontSize(12).fontColor(this.pal().text3).fontFamily(this.font()).margin({ top: 3 })
              }.alignItems(HorizontalAlign.Start).layoutWeight(1).margin({ left: 12 })
              SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(16).fontColor([this.pal().text3])
            }.width('100%').padding({ left: 14, right: 16, top: 13, bottom: 13 })
          }.width('100%').borderRadius(16).backgroundColor(this.pal().surface)
            .border({ width: 0.5, color: this.pal().cardBorder, style: BorderStyle.Solid })
            .onClick((): void => { this.cloudSyncError = ''; this.cloudSyncStep = this.cloudSyncSelectedTables.length > 0 ? CLOUD_SYNC_SHEET_UPLOAD_CONFIRM : CLOUD_SYNC_SHEET_MANAGE_TABLES; })

          Column() {
            Row() {
              Row() { SymbolGlyph($r('sys.symbol.cloud_fill')).fontSize(20).fontColor([this.accentColor]) }
                .width(40).height(40).borderRadius(20).backgroundColor(this.pal().surface).justifyContent(FlexAlign.Center)
              Column() {
                Text(this.currentCloudSyncSheetSpec().secondaryLabel).fontSize(15).fontWeight(FontWeight.Medium).fontColor(this.pal().text).fontFamily(this.font())
                Text('从云端恢复此设备的全部可同步数据').fontSize(12).fontColor(this.pal().text3).fontFamily(this.font()).margin({ top: 3 })
              }.alignItems(HorizontalAlign.Start).layoutWeight(1).margin({ left: 12 })
              SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(16).fontColor([this.pal().text3])
            }.width('100%').padding({ left: 14, right: 16, top: 13, bottom: 13 })
          }.width('100%').borderRadius(16).backgroundColor(this.pal().surface)
            .border({ width: 0.5, color: this.pal().cardBorder, style: BorderStyle.Solid }).margin({ top: 10 })
            .onClick((): void => { this.cloudSyncError = ''; this.cloudSyncStep = this.cloudSyncSelectedTables.length > 0 ? CLOUD_SYNC_SHEET_DOWNLOAD_CONFIRM : CLOUD_SYNC_SHEET_MANAGE_TABLES; })

          Column() {
            Row() {
              Row() { SymbolGlyph($r('sys.symbol.checkmark_circle')).fontSize(20).fontColor([this.accentColor]) }
                .width(40).height(40).borderRadius(20).backgroundColor(this.pal().surface).justifyContent(FlexAlign.Center)
              Column() {
                Text('管理同步数据表').fontSize(15).fontWeight(FontWeight.Medium).fontColor(this.pal().text).fontFamily(this.font())
                Text('选择此设备参与云同步的数据类型').fontSize(12).fontColor(this.pal().text3).fontFamily(this.font()).margin({ top: 3 })
              }.alignItems(HorizontalAlign.Start).layoutWeight(1).margin({ left: 12 })
              SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(16).fontColor([this.pal().text3])
            }.width('100%').padding({ left: 14, right: 16, top: 13, bottom: 13 })
          }.width('100%').borderRadius(16).backgroundColor(this.pal().surface)
            .border({ width: 0.5, color: this.pal().cardBorder, style: BorderStyle.Solid }).margin({ top: 10 })
            .onClick((): void => { this.cloudSyncStep = CLOUD_SYNC_SHEET_MANAGE_TABLES; })
        }.width('100%').padding({ left: 24, right: 24, top: 22, bottom: 28 }).alignItems(HorizontalAlign.Start)
      } else if (this.cloudSyncStep === CLOUD_SYNC_SHEET_MANAGE_TABLES) {
        Column() {
          Text('管理同步数据').fontSize(18).fontWeight(FontWeight.Bold).fontColor(this.pal().text).fontFamily(this.font())
          Text('取消勾选不会删除数据，只会停止此设备未来的上传和下载。加密参数会随敏感数据自动保护。')
            .fontSize(12).fontColor(this.pal().text3).fontFamily(this.font()).lineHeight(19).margin({ top: 8, bottom: 14 })
          ForEach(cloudSyncSelectableTables(), (table: string) => {
            Row() {
              Checkbox().select(this.cloudSyncSelectedTables.indexOf(table) >= 0).selectedColor(this.accentColor)
                .onChange((): void => { this.toggleCloudSyncTable(table); })
              Column() {
                Text(table === 'usersettings' ? '个性化与协议设置' : table === 'remotehosts' ? '远程主机' : table === 'rdpcredentials' ? 'Windows 登录凭据' : table === 'rustdeskrelays' ? 'RustDesk 中继配置' : table === 'sshkeys' ? 'SSH 密钥' : '双重验证动态口令')
                  .fontSize(14).fontWeight(FontWeight.Medium).fontColor(this.pal().text).fontFamily(this.font())
                Text(table === 'usersettings' ? '主题、外观和协议偏好' : '包含敏感数据，启用时自动同步加密参数')
                  .fontSize(11).fontColor(this.pal().text3).fontFamily(this.font()).margin({ top: 3 })
              }.alignItems(HorizontalAlign.Start).layoutWeight(1).margin({ left: 10 })
            }.width('100%').padding(14).borderRadius(14).backgroundColor(this.pal().surface).margin({ bottom: 8 })
          }, (table: string): string => table)
          Row() {
            Checkbox().select(effectiveCloudSyncTables(this.cloudSyncSelectedTables).indexOf('cryptoparams') >= 0)
              .selectedColor(this.accentColor).enabled(false)
            Column() {
              Text('加密参数').fontSize(14).fontWeight(FontWeight.Medium).fontColor(this.pal().text).fontFamily(this.font())
              Text('为已选择的敏感数据提供解密能力，自动随其同步').fontSize(11).fontColor(this.pal().text3).fontFamily(this.font()).margin({ top: 3 })
            }.alignItems(HorizontalAlign.Start).layoutWeight(1).margin({ left: 10 })
          }.width('100%').padding(14).borderRadius(14).backgroundColor(this.pal().surface).margin({ bottom: 8 })
          Text('加密参数会自动随已选择的敏感数据同步。').fontSize(11).fontColor(this.pal().text3).fontFamily(this.font()).margin({ top: 6 })
        }.width('100%').padding({ left: 24, right: 24, top: 22, bottom: 28 }).alignItems(HorizontalAlign.Start)
      } else if (this.cloudSyncStep === CLOUD_SYNC_SHEET_DETAILS) {
        Column() {
          Row() {
            SymbolGlyph($r('sys.symbol.cloud_fill')).fontSize(34).fontColor([this.accentColor])
            Column() {
              Text(this.currentCloudSyncSheetSpec().title).fontSize(17).fontWeight(FontWeight.Bold).fontColor(this.pal().text).fontFamily(this.font())
              Text(this.currentCloudSyncSheetSpec().message).fontSize(13).fontColor(this.pal().text2).fontFamily(this.font()).lineHeight(20).margin({ top: 6 })
            }.alignItems(HorizontalAlign.Start).layoutWeight(1).margin({ left: 12 })
          }.width('100%').alignItems(VerticalAlign.Top)
          Column() {
            Text('应用端状态').fontSize(13).fontWeight(FontWeight.Medium).fontColor(this.pal().text2).fontFamily(this.font())
            Text(cloudSyncDetailSpec(CloudStore.getInstance().isCloudAvailable()).statusText)
              .fontSize(13).fontColor(this.accentColor).fontFamily(this.font()).margin({ top: 7 })
          }.width('100%').padding(14).borderRadius(14).backgroundColor(this.pal().surface).margin({ top: 20 }).alignItems(HorizontalAlign.Start)
          Text('请依次确认').fontSize(13).fontWeight(FontWeight.Medium).fontColor(this.pal().text2).fontFamily(this.font()).margin({ top: 20 })
            .width('100%')
          ForEach(cloudSyncDetailSpec(CloudStore.getInstance().isCloudAvailable()).prerequisites,
            (item: string, index: number): void => {
              Row() {
                Text((index + 1).toString()).fontSize(11).fontWeight(FontWeight.Bold).fontColor(this.accentColor)
                  .width(22).height(22).borderRadius(11).backgroundColor(this.pal().surface).textAlign(TextAlign.Center).padding({ top: 3 })
                Text(item).fontSize(13).fontColor(this.pal().text2).fontFamily(this.font()).layoutWeight(1).margin({ left: 10 })
              }.width('100%').margin({ top: 10 }).alignItems(VerticalAlign.Center)
            }, (item: string): string => item)
          Text('应用无法直接读取系统云同步开关状态；端云连接异常时，请检查以上条件。')
            .fontSize(11).fontColor(this.pal().text3).fontFamily(this.font()).lineHeight(18).margin({ top: 18 })
        }.width('100%').padding({ left: 24, right: 24, top: 24, bottom: 30 }).alignItems(HorizontalAlign.Start)
      } else if (this.cloudSyncStep === CLOUD_SYNC_SHEET_UNAVAILABLE) {
        Column() {
          Row() {
            SymbolGlyph($r('sys.symbol.exclamationmark_triangle')).fontSize(34).fontColor(['#B66A00'])
            Column() {
              Text(this.currentCloudSyncSheetSpec().title).fontSize(17).fontWeight(FontWeight.Bold).fontColor(this.pal().text).fontFamily(this.font())
              Text(this.currentCloudSyncSheetSpec().message).fontSize(13).fontColor(this.pal().text2).fontFamily(this.font()).lineHeight(20).margin({ top: 6 })
            }.alignItems(HorizontalAlign.Start).layoutWeight(1).margin({ left: 12 })
          }.width('100%').alignItems(VerticalAlign.Top)
          Column() {
            Text('请依次确认').fontSize(13).fontWeight(FontWeight.Medium).fontColor(this.pal().text2).fontFamily(this.font())
            Text('1. 已登录与其他设备相同的华为账号\n2. 华为云空间服务已开通\n3. 系统设置中的云同步开关已打开')
              .fontSize(12).fontColor(this.pal().text3).fontFamily(this.font()).lineHeight(21).margin({ top: 8 })
          }.width('100%').padding(14).borderRadius(14).backgroundColor(this.pal().surface).margin({ top: 20 })
          Button(this.currentCloudSyncSheetSpec().primaryLabel).width('100%').height(46).fontSize(15).fontWeight(FontWeight.Medium)
            .backgroundColor(this.accentColor).fontColor('#FFFFFF').borderRadius(14).margin({ top: 22 })
            .onClick((): void => { this.closeSettingsLeafSheet(); })
        }.width('100%').padding({ left: 24, right: 24, top: 24, bottom: 30 }).alignItems(HorizontalAlign.Start)
      } else if (this.cloudSyncStep === CLOUD_SYNC_SHEET_UPLOADING || this.cloudSyncStep === CLOUD_SYNC_SHEET_DOWNLOADING) {
        Column() {
          LoadingProgress().width(36).height(36).color(this.accentColor)
          Text(this.currentCloudSyncSheetSpec().title).fontSize(17).fontWeight(FontWeight.Bold).fontColor(this.pal().text).fontFamily(this.font()).margin({ top: 16 })
          Text(this.currentCloudSyncSheetSpec().message).fontSize(13).fontColor(this.pal().text2).fontFamily(this.font()).textAlign(TextAlign.Center).lineHeight(20).margin({ top: 8 })
        }.width('100%').padding({ left: 36, right: 36, top: 48, bottom: 54 }).alignItems(HorizontalAlign.Center)
      } else {
        Column() {
          Row() {
            Row() { SymbolGlyph($r('sys.symbol.exclamationmark_triangle')).fontSize(24).fontColor([this.pal().danger]) }
              .width(46).height(46).borderRadius(23).backgroundColor(this.pal().surface).justifyContent(FlexAlign.Center)
            Column() {
              Text(this.currentCloudSyncSheetSpec().title).fontSize(18).fontWeight(FontWeight.Bold).fontColor(this.pal().text).fontFamily(this.font())
              Text('此操作不可撤销，请在继续前确认数据来源。').fontSize(12).fontColor(this.pal().text3).fontFamily(this.font()).margin({ top: 3 })
            }.alignItems(HorizontalAlign.Start).layoutWeight(1).margin({ left: 12 })
          }.width('100%').alignItems(VerticalAlign.Center)
          Text(this.currentCloudSyncSheetSpec().message).fontSize(14).fontColor(this.pal().text2).fontFamily(this.font()).lineHeight(21).margin({ top: 18 })
          Column() {
            Text('影响范围').fontSize(12).fontWeight(FontWeight.Medium).fontColor(this.pal().text2).fontFamily(this.font())
            Text('主机、RDP 凭据、RustDesk 中继、SSH 密钥、2FA、加密参数和个性化设置')
              .fontSize(12).fontColor(this.pal().text3).fontFamily(this.font()).lineHeight(19).margin({ top: 5 })
          }.width('100%').padding(14).borderRadius(14).backgroundColor(this.pal().surface).margin({ top: 18 })
          if (this.cloudSyncError !== '') {
            Text(this.cloudSyncError).fontSize(12).fontColor(this.pal().danger).fontFamily(this.font()).lineHeight(19).margin({ top: 14 })
          }
          Row() {
            Button(this.currentCloudSyncSheetSpec().secondaryLabel).layoutWeight(1).height(46).fontSize(15).fontWeight(FontWeight.Medium)
              .backgroundColor(this.pal().surface).fontColor(this.pal().text2).borderRadius(14)
              .onClick((): void => { this.returnToCloudSyncActions(); })
            Button(this.currentCloudSyncSheetSpec().primaryLabel).layoutWeight(1).height(46).fontSize(15).fontWeight(FontWeight.Medium)
              .backgroundColor(this.pal().danger).fontColor('#FFFFFF').borderRadius(14).margin({ left: 12 })
              .onClick(async (): Promise<void> => {
                if (this.cloudSyncStep === CLOUD_SYNC_SHEET_UPLOAD_CONFIRM) {
                  await this.confirmCloudSyncUpload();
                } else if (this.cloudSyncStep === CLOUD_SYNC_SHEET_DOWNLOAD_CONFIRM) {
                  await this.confirmCloudSyncDownload();
                } else if (this.cloudSyncStep === CLOUD_SYNC_SHEET_BACKUP_CONFIRM) {
                  await this.createLocalBackup();
                } else if (this.cloudSyncStep === CLOUD_SYNC_SHEET_RESTORE_CONFIRM) {
                  await this.confirmLocalRestore();
                }
              })
          }.width('100%').margin({ top: 22 })
        }.width('100%').padding({ left: 24, right: 24, top: 24, bottom: 32 }).alignItems(HorizontalAlign.Start)
      }
    }.width('100%').backgroundColor(this.pal().bg).borderRadius(24)
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
  }

  @Builder sshHostKeyManagerSheet() {
    Column() {
      Row() {
        Text('SSH 主机指纹').fontSize(20).fontWeight(FontWeight.Bold)
          .fontColor(this.pal().text).fontFamily(this.font())
        Blank()
        SymbolGlyph($r('sys.symbol.xmark')).fontSize(18).fontColor([this.pal().text2])
          .width(36).height(36).onClick((): void => { this.closeSettingsLeafSheet(); })
      }.width('100%').padding({ left: 24, right: 20, top: 20 }).margin({ bottom: 6 })

      if (this.sshTrustedHostsView.length === 0) {
        Column() {
          SymbolGlyph($r('sys.symbol.lock_shield_fill')).fontSize(34).fontColor([this.pal().text3])
          Text('暂无已信任的 SSH 主机指纹')
            .fontSize(15).fontColor(this.pal().text).fontFamily(this.font()).margin({ top: 12 })
          Text('首次连接 SSH 主机并确认指纹后，会在这里显示。')
            .fontSize(12).fontColor(this.pal().text3).fontFamily(this.font())
            .textAlign(TextAlign.Center).margin({ top: 6 })
        }
        .width('100%').padding({ left: 24, right: 24, top: 34, bottom: 38 })
      } else {
        Scroll() {
          Column() {
            ForEach(this.sshTrustedHostsView, (host: RemoteHost) => {
              Column() {
                Row() {
                  Column() {
                    Text(host.label).fontSize(15).fontWeight(FontWeight.Medium)
                      .fontColor(this.pal().text).fontFamily(this.font()).maxLines(1)
                    Text(host.username + '@' + host.host + ':' + host.port.toString())
                      .fontSize(11).fontColor(this.pal().text3).fontFamily(this.font())
                      .maxLines(1).margin({ top: 2 })
                  }.alignItems(HorizontalAlign.Start).layoutWeight(1)
                  Text(host.sshHostKeyAlgorithm || 'unknown')
                    .fontSize(11).fontColor(this.accentColor).fontWeight(FontWeight.Medium)
                    .padding({ left: 8, right: 8, top: 4, bottom: 4 })
                    .borderRadius(6).backgroundColor(this.pal().surface)
                }.width('100%').margin({ bottom: 8 })

                Text(host.sshHostKeyFingerprintSha256 || '(无指纹)')
                  .fontSize(11).fontColor(this.pal().text2).fontFamily('monospace')
                  .maxLines(2).width('100%')
                  .padding({ left: 10, right: 10, top: 8, bottom: 8 })
                  .borderRadius(8).backgroundColor(this.pal().surface)

                Row() {
                  Text('信任时间 ' + this.formatTimestamp(host.sshHostKeyTrustedAt))
                    .fontSize(11).fontColor(this.pal().text3).fontFamily(this.font())
                    .layoutWeight(1)
                  Button(this.sshHostKeyBusyId === host.id ? '刷新中' : '重新获取')
                    .height(32).fontSize(12).padding({ left: 10, right: 10 })
                    .backgroundColor(this.pal().surface).fontColor(this.accentColor)
                    .borderRadius(8).enabled(this.sshHostKeyBusyId === '')
                    .onClick((): void => { this.refreshSshHostKey(host); })
                  Button('忘记')
                    .height(32).fontSize(12).padding({ left: 10, right: 10 })
                    .backgroundColor(this.pal().surface).fontColor(this.pal().danger)
                    .borderRadius(8).margin({ left: 8 }).enabled(this.sshHostKeyBusyId === '')
                    .onClick((): void => { this.forgetSshHostKey(host); })
                }.width('100%').margin({ top: 10 })
              }
              .width('100%').padding(14).borderRadius(14)
              .backgroundColor(this.pal().card)
              .border({ width: 0.5, color: this.pal().cardBorder, style: BorderStyle.Solid })
              .margin({ bottom: 10 })
            }, (host: RemoteHost) => host.id + ':' + this.hostViewRevision.toString())
          }.width('100%').padding({ left: 24, right: 24, bottom: 18 })
        }
        .constraintSize({ maxHeight: 480 }).scrollBar(BarState.Auto).edgeEffect(EdgeEffect.Spring)
      }
    }
    .width('100%')
    .constraintSize({ maxWidth: 620 })
    .backgroundColor(this.pal().bg)
    .backgroundBlurStyle(BlurStyle.Regular)
    .borderRadius(this.breakpoint === 'sm' ? { topLeft: 22, topRight: 22, bottomLeft: 0, bottomRight: 0 } : 24)
  }

  @Builder rdpCertificateManagerSheet() {
    Column() {
      Row() {
        Text('RDP 证书信任').fontSize(20).fontWeight(FontWeight.Bold)
          .fontColor(this.pal().text).fontFamily(this.font())
        Blank()
        SymbolGlyph($r('sys.symbol.xmark')).fontSize(18).fontColor([this.pal().text2])
          .width(36).height(36).onClick((): void => { this.closeSettingsLeafSheet(); })
      }.width('100%').padding({ left: 24, right: 20, top: 20 }).margin({ bottom: 6 })

      if (this.rdpTrustedHostsView.length === 0) {
        Column() {
          SymbolGlyph($r('sys.symbol.lock_shield_fill')).fontSize(34).fontColor([this.pal().text3])
          Text('暂无已信任的 RDP 证书')
            .fontSize(15).fontColor(this.pal().text).fontFamily(this.font()).margin({ top: 12 })
          Text('在首次连接 RDP 主机时选择“信任”，记录会显示在这里。')
            .fontSize(12).fontColor(this.pal().text3).fontFamily(this.font())
            .textAlign(TextAlign.Center).margin({ top: 6 })
        }
        .width('100%').padding({ left: 24, right: 24, top: 34, bottom: 38 })
      } else {
        Scroll() {
          Column() {
            ForEach(this.rdpTrustedHostsView, (host: RemoteHost) => {
              Column() {
                Row() {
                  Column() {
                    Text(host.label).fontSize(15).fontWeight(FontWeight.Medium)
                      .fontColor(this.pal().text).fontFamily(this.font()).maxLines(1)
                    Text(host.host + ':' + host.port.toString())
                      .fontSize(11).fontColor(this.pal().text3).fontFamily(this.font())
                      .maxLines(1).margin({ top: 2 })
                  }.alignItems(HorizontalAlign.Start).layoutWeight(1)
                  Text('RDP').fontSize(11).fontColor(this.accentColor).fontWeight(FontWeight.Medium)
                    .padding({ left: 8, right: 8, top: 4, bottom: 4 })
                    .borderRadius(6).backgroundColor(this.pal().surface)
                }.width('100%').margin({ bottom: 8 })

                Text('CN: ' + (host.rdpCertificateCommonName || '(无)'))
                  .fontSize(11).fontColor(this.pal().text2).fontFamily('monospace')
                  .maxLines(1).width('100%')
                Text('Issuer: ' + (host.rdpCertificateIssuer || '(无)'))
                  .fontSize(11).fontColor(this.pal().text2).fontFamily('monospace')
                  .maxLines(1).width('100%').margin({ top: 3 })
                Text(host.rdpCertificateFingerprintSha256 || '(无指纹)')
                  .fontSize(11).fontColor(this.pal().text2).fontFamily('monospace')
                  .maxLines(2).width('100%')
                  .padding({ left: 10, right: 10, top: 8, bottom: 8 })
                  .borderRadius(8).backgroundColor(this.pal().surface).margin({ top: 8 })

                Row() {
                  Text('信任时间 ' + this.formatTimestamp(host.rdpCertificateTrustedAt))
                    .fontSize(11).fontColor(this.pal().text3).fontFamily(this.font())
                    .layoutWeight(1)
                  Button(this.rdpCertificateBusyId === host.id ? '更新中' : '重新获取')
                    .height(32).fontSize(12).padding({ left: 10, right: 10 })
                    .backgroundColor(this.pal().surface).fontColor(this.accentColor)
                    .borderRadius(8).enabled(this.rdpCertificateBusyId === '')
                    .onClick((): void => { this.refreshRdpCertificate(host); })
                  Button('忘记')
                    .height(32).fontSize(12).padding({ left: 10, right: 10 })
                    .backgroundColor(this.pal().surface).fontColor(this.pal().danger)
                    .borderRadius(8).margin({ left: 8 }).enabled(this.rdpCertificateBusyId === '')
                    .onClick((): void => { this.forgetRdpCertificate(host); })
                }.width('100%').margin({ top: 10 })
              }
              .width('100%').padding(14).borderRadius(14)
              .backgroundColor(this.pal().card)
              .border({ width: 0.5, color: this.pal().cardBorder, style: BorderStyle.Solid })
              .margin({ bottom: 10 })
            }, (host: RemoteHost) => host.id + ':' + this.hostViewRevision.toString())
          }.width('100%').padding({ left: 24, right: 24, bottom: 18 })
        }
        .constraintSize({ maxHeight: 480 }).scrollBar(BarState.Auto).edgeEffect(EdgeEffect.Spring)
      }
    }
    .width('100%')
    .constraintSize({ maxWidth: 620 })
    .backgroundColor(this.pal().bg)
    .backgroundBlurStyle(BlurStyle.Regular)
    .borderRadius(this.breakpoint === 'sm' ? { topLeft: 22, topRight: 22, bottomLeft: 0, bottomRight: 0 } : 24)
  }

  // ==================== 加密设置弹窗 ====================

  @Builder cryptoSheet() {
    Column() {
      Text(this.cryptoMode === 0 ? '启用端到端加密' : (this.cryptoMode === 1 ? '解锁加密' : '关闭端到端加密'))
        .fontSize(19).fontWeight(FontWeight.Bold).fontColor(this.pal().text)
        .margin({ top: 24, bottom: 16 }).fontFamily(this.font())

      // 说明文字
      Column() {
        Text('• AES-256-GCM 加密保护，数据在本地加密后云同步')
          .fontSize(12).fontColor(this.pal().text2).fontFamily(this.font()).margin({ bottom: 4 })
        Text('• 主密码通过系统密码保险箱跨设备同步，不会上传到服务器')
          .fontSize(12).fontColor(this.pal().text2).fontFamily(this.font()).margin({ bottom: 4 })
        Text('• 忘记密码将无法恢复已加密的数据，请妥善保管')
          .fontSize(12).fontColor(this.pal().danger).fontFamily(this.font()).margin({ bottom: 4 })
        Text('• 关闭加密后，数据恢复明文存储和同步')
          .fontSize(12).fontColor(this.pal().text2).fontFamily(this.font())
      }.width('100%').padding(12).backgroundColor(this.pal().surface)
        .borderRadius(12).margin({ bottom: 20 })

      if (this.cryptoMode === 1) {
        // 解锁模式: 只需输入密码
        TextInput({ placeholder: '输入主密码解锁', text: this.cryptoPwd })
          .type(InputType.Password).enableAutoFill(true)
          .height(44).width('100%').fontSize(15)
          .backgroundColor(this.pal().surface).borderRadius(10)
          .padding({ left: 12, right: 12 }).margin({ bottom: 16 })
          .onChange((v: string) => { this.cryptoPwd = v; })

        Row() {
          Button('取消').layoutWeight(1).height(44).fontSize(14)
            .backgroundColor(this.pal().surface).fontColor(this.pal().text2).borderRadius(12)
            .onClick(() => { this.closeSettingsLeafSheet(); this.cryptoPwd = ''; this.cryptoMode = 0; this.cryptoResetCountdown = 0; })
          Blank().width(12)
          Button('解锁').layoutWeight(1).height(44).fontSize(14)
            .backgroundColor(this.accentColor).fontColor('#FFFFFF').borderRadius(12)
            .enabled(this.cryptoPwd.length > 0 && !this.cryptoLoading)
            .onClick(async () => { await this.handleUnlock(); })
        }.width('100%').margin({ bottom: 8 })

        Text('忘记密码? 重置加密并清空所有数据')
          .fontSize(11).fontColor(this.pal().danger).textAlign(TextAlign.Center).width('100%')
          .onClick(() => {
            this.closeSettingsLeafSheet();
            this.cryptoPwd = '';
            this.confirmResetEncryption();
          })
      } else if (this.cryptoMode === 2) {
        // 关闭模式: 确认密码 + 5秒倒计时
        TextInput({ placeholder: '输入主密码确认关闭', text: this.cryptoPwd })
          .type(InputType.Password).enableAutoFill(true)
          .height(44).width('100%').fontSize(15)
          .backgroundColor(this.pal().surface).borderRadius(10)
          .padding({ left: 12, right: 12 }).margin({ bottom: 16 })
          .onChange((v: string) => { this.cryptoPwd = v; })
        Row() {
          Button('取消').layoutWeight(1).height(44).fontSize(14)
            .backgroundColor(this.pal().surface).fontColor(this.pal().text2).borderRadius(12)
            .onClick(() => { this.closeSettingsLeafSheet(); this.cryptoPwd = ''; this.cryptoMode = 0; this.cryptoResetCountdown = 0; })
          Blank().width(12)
          Button(this.cryptoResetCountdown > 0 ? '确认关闭 (' + this.cryptoResetCountdown + 's)' : '确认关闭')
            .layoutWeight(1).height(44).fontSize(14)
            .backgroundColor(this.cryptoResetCountdown > 0 ? this.pal().text3 : this.pal().danger)
            .fontColor('#FFFFFF').borderRadius(12)
            .enabled(this.cryptoResetCountdown <= 0 && this.cryptoPwd.length > 0)
            .onClick(() => { this.doCloseEncryption(); })
        }.width('100%')
      } else if (this.cryptoMode === 3) {
        // 重置模式: 忘记密码, 红色警告 + 5s 倒计时, 无需输入密码
        Text('⚠️ 确定要重置加密吗?')
          .fontSize(15).fontWeight(FontWeight.Bold).fontColor(this.pal().danger)
          .width('100%').margin({ bottom: 10 }).fontFamily(this.font())
        Text('所有加密数据将被永久删除, 此操作不可恢复。\n其他登录了同一华为账号的设备也会同步清空。')
          .fontSize(12).fontColor(this.pal().text2).fontFamily(this.font())
          .width('100%').margin({ bottom: 16 })
        Row() {
          Button('取消').layoutWeight(1).height(44).fontSize(14)
            .backgroundColor(this.pal().surface).fontColor(this.pal().text2).borderRadius(12)
            .onClick(() => { this.closeSettingsLeafSheet(); this.cryptoMode = 0; this.cryptoResetCountdown = 0; })
          Blank().width(12)
          Button(this.cryptoResetCountdown > 0 ? '确认重置 (' + this.cryptoResetCountdown + 's)' : '确认重置')
            .layoutWeight(1).height(44).fontSize(14)
            .backgroundColor(this.cryptoResetCountdown > 0 ? this.pal().text3 : this.pal().danger)
            .fontColor('#FFFFFF').borderRadius(12)
            .enabled(this.cryptoResetCountdown <= 0)
            .onClick(() => { this.doResetEncryption(); })
        }.width('100%')
      } else {
        // 设置模式: 输入密码 + 确认
        TextInput({ placeholder: '输入主密码 (12-32位, 大写开头, 含特殊字符)', text: this.cryptoPwd })
          .type(InputType.NEW_PASSWORD).enableAutoFill(true)
          .passwordRules('begin:[upper],special:[yes],len:[maxlen:32,minlen:12]')
          .height(44).width('100%').fontSize(15)
          .backgroundColor(this.pal().surface).borderRadius(10)
          .padding({ left: 12, right: 12 }).margin({ bottom: 10 })
          .onChange((v: string) => { this.cryptoPwd = v; })
        TextInput({ placeholder: '确认主密码', text: this.cryptoPwdConfirm })
          .type(InputType.NEW_PASSWORD).enableAutoFill(true)
          .height(44).width('100%').fontSize(15)
          .backgroundColor(this.pal().surface).borderRadius(10)
          .padding({ left: 12, right: 12 }).margin({ bottom: 16 })
          .onChange((v: string) => { this.cryptoPwdConfirm = v; })

        Row() {
          Button('取消').layoutWeight(1).height(44).fontSize(14)
            .backgroundColor(this.pal().surface).fontColor(this.pal().text2).borderRadius(12)
            .onClick(() => { this.closeSettingsLeafSheet(); this.cryptoPwd = ''; this.cryptoPwdConfirm = ''; })
          Blank().width(12)
          Button('启用加密').layoutWeight(1).height(44).fontSize(14)
            .backgroundColor(this.accentColor).fontColor('#FFFFFF').borderRadius(12)
            .enabled(this.cryptoPwd.length >= 8 && this.cryptoPwd === this.cryptoPwdConfirm && !this.cryptoLoading)
            .onClick(async () => { await this.handleEnable(); })
        }.width('100%')
      }
      Blank().height(20)
    }.width('100%')
    .padding({ left: 24, right: 24, top: 8, bottom: 40 })
    .borderRadius(this.breakpoint === 'sm' ? { topLeft: 20, topRight: 20, bottomLeft: 0, bottomRight: 0 } : 20)
    .backgroundColor(this.pal().bg).backgroundBlurStyle(BlurStyle.Regular)
    .shadow({ radius: this.breakpoint === 'sm' ? 0 : 24, color: this.breakpoint === 'sm' ? 'rgba(0,0,0,0)' : 'rgba(0,0,0,0.12)', offsetY: this.breakpoint === 'sm' ? 0 : 6 })
    .border(this.breakpoint === 'sm'
      ? { width: 0, color: Color.Transparent, style: BorderStyle.Solid }
      : { width: 0.5, color: this.pal().cardBorder, style: BorderStyle.Solid })
  }

  private doCountdownTick(): void { this.cryptoResetCountdown--; if (this.cryptoResetCountdown > 0) { setTimeout(() => { this.doCountdownTick(); }, 1000); } }
  private async handleEnable(): Promise<void> {
    this.cryptoLoading = true;
    try {
      const crypto = DataCrypto.getInstance();
      await crypto.setMasterPassword(this.cryptoPwd);
      const cloud = CloudStore.getInstance();
      const count = await crypto.autoMigrate(cloud);
      promptAction.showToast({ message: '加密已启用, ' + count + ' 条数据已加密', duration: 2000 });
      this.closeSettingsLeafSheet();
      this.cryptoPwd = '';
      this.cryptoPwdConfirm = '';
      this.refreshCryptoStatus();
    } catch (err) {
      const detail = DataCrypto.errDetail(err);
      hilog.error(0x0001, 'CloudSync', '[handleEnable] 设置主密码失败: ' + detail);
      promptAction.showToast({
        message: '设置失败: ' + detail,
        duration: 3000
      });
    } finally {
      this.cryptoLoading = false;
    }
  }

  private async handleUnlock(): Promise<void> {
    this.cryptoLoading = true;
    try {
      const crypto = DataCrypto.getInstance();
      const ok = await crypto.unlock(this.cryptoPwd);
      if (ok) {
        const cloud = CloudStore.getInstance();
        const count = await crypto.autoMigrate(cloud);
        if (count > 0) { promptAction.showToast({ message: count + ' 条新数据已加密', duration: 1500 }); }
        else { promptAction.showToast({ message: '已解锁', duration: 1500 }); }
        this.closeSettingsLeafSheet();
        this.cryptoPwd = '';
        this.refreshCryptoStatus();
      } else {
        promptAction.showToast({ message: '密码错误, 请重试', duration: 2000 });
      }
    } catch (err) {
      const detail = DataCrypto.errDetail(err);
      hilog.error(0x0001, 'CloudSync', '[handleUnlock] 解锁失败: ' + detail);
      promptAction.showToast({ message: '解锁失败: ' + detail, duration: 3000 });
    } finally {
      this.cryptoLoading = false;
    }
  }


  private async doCloseEncryption(): Promise<void> {
    const crypto = DataCrypto.getInstance();
    const cloud = CloudStore.getInstance();
    // 1. 验证主密码
    const ok = await crypto.unlock(this.cryptoPwd);
    if (!ok) {
      promptAction.showToast({ message: '密码错误, 无法关闭加密', duration: 2000 });
      return;
    }
    // 2. 先完成本地解密，再发布关闭信令；任一步写入失败都不能向云端发布半成品状态。
    const count = cloud.decryptAllData(crypto, false);
    hilog.info(0x0001, 'CloudSync', 'doCloseEncryption: 已解密 ' + count + ' 条数据');
    if (count < 0) {
      promptAction.showToast({ message: '关闭加密失败：本地数据未完整解密，请重试', duration: 2500 });
      return;
    }
    if (!cloud.setCryptoStatus('disabled')) {
      promptAction.showToast({ message: '关闭加密失败：本地状态未写入，请重试', duration: 2500 });
      return;
    }
    // 3. 清除本地盐值和验证器后，先显式推送 cryptoparams，再推送所有敏感业务表。
    if (!(await cloud.clearCryptoParams())) {
      cloud.setCryptoStatus('active');
      promptAction.showToast({ message: '关闭加密失败：参数未清除，请重试', duration: 2500 });
      return;
    }
    cloud.pushTable('cryptoparams');
    cloud.pushTable('remotehosts');
    cloud.pushTable('rdpcredentials');
    cloud.pushTable('rustdeskrelays');
    cloud.pushTable('sshkeys');
    cloud.pushTable('totpentries');
    // 4. 清除内存 DEK。
    crypto.resetSetup();
    this.closeSettingsLeafSheet();
    this.cryptoPwd = '';
    this.cryptoResetCountdown = 0;
    this.refreshCryptoStatus();
    promptAction.showToast({ message: '加密已关闭, ' + count + ' 条数据已恢复明文', duration: 2000 });
  }

  private async doResetEncryption(): Promise<void> {
    const cloud = CloudStore.getInstance();
    // 1. 跨设备信令: 通知所有设备重置 (其他设备 checkCryptoStatusChange 读到 'reset' 后自毁)
    if (!cloud.setCryptoStatus('reset')) {
      promptAction.showToast({ message: '重置失败：本地状态未写入，请重试', duration: 2500 });
      return;
    }
    // 2. 清空三张业务表 (异步, 必须 await — 确保数据清完再推送)
    if (!(await cloud.clearAllTables(false))) {
      cloud.setCryptoStatus('active');
      promptAction.showToast({ message: '重置失败：本地数据未完整清空，请重试', duration: 2500 });
      return;
    }
    // 3. 清除加密参数 (异步, 必须 await — 盐值+验证器, crypto_status 保留 'reset')
    if (!(await cloud.clearCryptoParams())) {
      promptAction.showToast({ message: '重置未完成：加密参数未清除，请重试', duration: 2500 });
      return;
    }
    DataCrypto.getInstance().lock();
    // 4. 推送 cryptoparams 到云端 (此时本地清空已完成, 其他设备收到后也清空)
    cloud.pushTable('cryptoparams');
    cloud.pushTable('remotehosts');
    cloud.pushTable('rdpcredentials');
    cloud.pushTable('rustdeskrelays');
    cloud.pushTable('sshkeys');
    cloud.pushTable('totpentries');
    this.closeSettingsLeafSheet();
    this.cryptoPwd = '';
    this.cryptoResetCountdown = 0;
    this.refreshCryptoStatus();
    promptAction.showToast({ message: '加密已重置, 所有加密数据已清空', duration: 2000 });
  }

  private confirmResetEncryption(): void {
    this.openSettingsLeafSheet(SETTINGS_SHEET_POPUP, (): void => {
      this.cryptoPwd = '';
      this.cryptoResetCountdown = 5;
      this.cryptoMode = 3;
      this.popupSheetMode = 0;
      setTimeout(() => { this.doCountdownTick(); }, 1000);
    });
  }

  private confirmDisableEncryption(): void {
    this.openSettingsLeafSheet(SETTINGS_SHEET_POPUP, (): void => {
      this.cryptoPwd = '';
      this.cryptoResetCountdown = 5;
      this.cryptoMode = 2;
      this.popupSheetMode = 0;
      setTimeout(() => { this.doCountdownTick(); }, 1000);
    });
  }

  @Builder cardItemRow(icon: Resource, label: string, value: string) {
    Row() {
      Row() { Image(icon).width(22).height(22).fillColor(this.pal().text3) }
        .width(22).height(22).justifyContent(FlexAlign.Center).margin({ left: 9, right: 9 })
      Text(label).fontSize(AppTheme.fontSize.body).fontWeight(FontWeight.Medium)
        .fontColor(this.pal().text).fontFamily(this.font()).layoutWeight(1).margin({ left: 4 })
      Text(value).fontSize(14).fontColor(this.pal().text2).margin({ right: 16 })
    }.width('100%').height(60).padding({ left: 16, right: 16 })
  }

  @Builder cardActionRow(icon: Resource, label: string, value: string, action: () => void) {
    Row() {
      Row() { Image(icon).width(22).height(22).fillColor(this.pal().text3) }
        .width(22).height(22).justifyContent(FlexAlign.Center).margin({ left: 9, right: 9 })
      Column() {
        Text(label).fontSize(AppTheme.fontSize.body).fontWeight(FontWeight.Medium)
          .fontColor(this.pal().text).fontFamily(this.font())
        Text(value).fontSize(11).fontColor(this.pal().text3).fontFamily(this.font())
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).margin({ top: 2 })
      }.alignItems(HorizontalAlign.Start).layoutWeight(1).margin({ left: 4 })
      SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(18).fontColor([this.pal().text3])
        .margin({ right: 14 })
    }
    .width('100%').height(62).padding({ left: 16, right: 16 })
    .onClick(action)
  }

  @Builder cardDivider() {
    // 对称缩进, 与卡内行 padding 保持一致
    Row() {
      Blank().width(16)
      Column().layoutWeight(1).height(0.5).backgroundColor(this.pal().divider)
      Blank().width(16)
    }.width('100%')
  }

  // 图像质量芯片 — 直接读 @StorageLink rustdeskImageQuality (跟 _codecChip 一样的模式)
  @Builder _qualityChip(label: string, value: number) {
    Column() {
      Text(label)
        .fontSize(12)
        .fontColor(this.rustdeskImageQuality === value ? '#FFFFFF' : this.pal().text2)
        .fontWeight(this.rustdeskImageQuality === value ? FontWeight.Medium : FontWeight.Normal)
        .textAlign(TextAlign.Center)
        .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        .padding({ left: 10, right: 10, top: 6, bottom: 6 })
        .borderRadius(8)
        .onClick((): void => { this.saveRustDeskImageQuality(value); })
    }.width(44).justifyContent(FlexAlign.Center)
  }

  @Builder rustdeskImageQualityRow() {
    Row() {
      Row() { Image($r('app.media.icon_laptop')).width(22).height(22).fillColor(this.pal().text3) }
        .width(22).height(22).justifyContent(FlexAlign.Center).margin({ left: 9, right: 9 })
      Column() {
        Text('图像质量').fontSize(AppTheme.fontSize.body).fontWeight(FontWeight.Medium)
          .fontColor(this.pal().text).fontFamily(this.font())
        Text(this.rustdeskImageQuality === 0 ? '速度优先' : (this.rustdeskImageQuality === 2 ? '画质优先' : '平衡'))
          .fontSize(11).fontColor(this.pal().text3).fontFamily(this.font())
      }.alignItems(HorizontalAlign.Start).layoutWeight(1).margin({ left: 4 })
      Stack({ alignContent: Alignment.Start }) {
        // 滑动指示器背景
        Column()
          .width(44).height(30).borderRadius(8)
          .backgroundColor(this.accentColor)
          .translate({ x: this.rustdeskImageQuality * 48, y: 0 })
          .animation({ duration: 300, curve: Curve.FastOutSlowIn })
        Row() {
          this._qualityChip('速度', 0)
          Blank().width(4)
          this._qualityChip('平衡', 1)
          Blank().width(4)
          this._qualityChip('画质', 2)
        }
      }.padding(3).borderRadius(11).backgroundColor(this.pal().surface)
    }.width('100%').height(64).padding({ left: 16, right: 16 })
  }

  @Builder rustdeskCodecRow() {
    if (this.breakpoint === 'sm') {
      Column() {
        Row() {
          Row() { Image($r('app.media.icon_laptop')).width(22).height(22).fillColor(this.pal().text3) }
            .width(22).height(22).justifyContent(FlexAlign.Center).margin({ left: 9, right: 9 })
          Column() {
            Text('默认编码').fontSize(AppTheme.fontSize.body).fontWeight(FontWeight.Medium)
              .fontColor(this.pal().text).fontFamily(this.font())
            Text(this.rustdeskCodecLabel()).fontSize(11).fontColor(this.pal().text3).fontFamily(this.font())
            Text(this.rustdeskCodecLongRunHint()).fontSize(10).fontColor(this.pal().text3).fontFamily(this.font())
              .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          }.alignItems(HorizontalAlign.Start).layoutWeight(1).margin({ left: 4 })
        }.width('100%').height(50).padding({ left: 16, right: 16, top: 8 })
        Row() {
          Stack({ alignContent: Alignment.Start }) {
            Column()
              .width(40).height(26).borderRadius(6)
              .backgroundColor(this.accentColor)
              .translate({ x: this.rustdeskCodec * 41, y: 0 })
              .animation({ duration: 280, curve: Curve.FastOutSlowIn })
            Row() { this._codecChip('自动', 0); this._codecChip('VP8', 1)
              this._codecChip('VP9', 2); this._codecChip('AV1', 3)
              this._codecChip('H264', 4); this._codecChip('H265', 5) }
          }.padding(3).borderRadius(10).backgroundColor(this.pal().surface)
        }.width('100%').justifyContent(FlexAlign.Center)
        .margin({ left: 16, right: 16, bottom: 12 })
      }.width('100%')
    } else {
      Row() {
        Row() { Image($r('app.media.icon_laptop')).width(22).height(22).fillColor(this.pal().text3) }
          .width(22).height(22).justifyContent(FlexAlign.Center).margin({ left: 9, right: 9 })
          Column() {
            Text('默认编码').fontSize(AppTheme.fontSize.body).fontWeight(FontWeight.Medium)
              .fontColor(this.pal().text).fontFamily(this.font())
            Text(this.rustdeskCodecLabel()).fontSize(11).fontColor(this.pal().text3).fontFamily(this.font())
            Text(this.rustdeskCodecLongRunHint()).fontSize(10).fontColor(this.pal().text3).fontFamily(this.font())
              .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          }.alignItems(HorizontalAlign.Start).layoutWeight(1).margin({ left: 4 })
        Stack({ alignContent: Alignment.Start }) {
          Column()
            .width(40).height(26).borderRadius(6)
            .backgroundColor(this.accentColor)
            .translate({ x: this.rustdeskCodec * 41, y: 0 })
            .animation({ duration: 280, curve: Curve.FastOutSlowIn })
          Row() { this._codecChip('自动', 0); this._codecChip('VP8', 1)
            this._codecChip('VP9', 2); this._codecChip('AV1', 3)
            this._codecChip('H264', 4); this._codecChip('H265', 5) }
        }.padding(3).borderRadius(10).backgroundColor(this.pal().surface)
      }.width('100%').height(76).padding({ left: 16, right: 16 })
    }
  }

  private rustdeskCodecLongRunHint(): string {
    if (this.rustdeskCodec === 4 || this.rustdeskCodec === 5) {
      return '适合长时间连接';
    }
    return '长时间连接建议优先 H264 / H265';
  }

  @Builder _codecChip(label: string, codecIdx: number) {
    Column() {
      Text(label).fontSize(10)
        .fontColor(this.rustdeskCodec === codecIdx ? '#FFFFFF' : this.pal().text2)
        .fontWeight(this.rustdeskCodec === codecIdx ? FontWeight.Medium : FontWeight.Normal)
        .textAlign(TextAlign.Center)
        .padding({ left: 3, right: 3, top: 4, bottom: 4 })
        .borderRadius(6).onClick((): void => { this.saveRustDeskCodec(codecIdx); })
    }.width(40).justifyContent(FlexAlign.Center)
    if (codecIdx < 5) { Blank().width(1) }
  }

  private rdpDesktopPresetLabel(): string {
    return rdpResolutionLabel(this.rdpDesktopResolutionId);
  }

  @Builder rdpDesktopPresetRow() {
    Column() {
      this.rdpDesktopPresetLabelBlock()
      Scroll() {
        Row({ space: 8 }) {
          this.rdpResolutionPresetChip('自适应', 'auto')
          ForEach(rdpResolutionPresets(), (preset: RemoteResolutionPreset): void => {
            this.rdpResolutionPresetChip(preset.label, preset.id)
          }, (preset: RemoteResolutionPreset): string => preset.id)
        }.padding({ left: 16, right: 16 })
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .width('100%')
      .height(42)
      .margin({ top: 4 })
    }.width('100%').height(110).padding({ top: 10, bottom: 10 })
  }

  @Builder rdpDesktopPresetLabelBlock() {
    Row() {
      Row() { Image($r('app.media.icon_desktop')).width(22).height(22).fillColor(this.pal().text3) }
        .width(22).height(22).justifyContent(FlexAlign.Center).margin({ left: 9, right: 9 })
      Column() {
        Text('远端桌面大小').fontSize(AppTheme.fontSize.body).fontWeight(FontWeight.Medium)
          .fontColor(this.pal().text).fontFamily(this.font())
        Text(this.rdpDesktopPresetLabel()).fontSize(11).fontColor(this.pal().text3).fontFamily(this.font())
      }.alignItems(HorizontalAlign.Start).layoutWeight(1).margin({ left: 4 })
    }.layoutWeight(1)
  }

  @Builder rdpResolutionPresetChip(label: string, id: string) {
    Text(label)
      .fontSize(11)
      .fontColor(this.rdpDesktopResolutionId === id ? '#FFFFFF' : this.pal().text2)
      .fontWeight(this.rdpDesktopResolutionId === id ? FontWeight.Medium : FontWeight.Normal)
      .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
      .padding({ left: 10, right: 10, top: 7, bottom: 7 })
      .backgroundColor(this.rdpDesktopResolutionId === id ? this.accentColor : this.pal().surface)
      .borderRadius(6)
      .onClick((): void => { this.saveRdpDesktopResolutionId(id); })
  }

  private remoteDisplayScaleLabel(): string {
    const mode = normalizeLocalViewScaleMode(this.remoteDisplayScaleMode);
    const percent: number = localViewScalePercent(mode, this.remoteDisplayCustomScalePercent);
    return percent > 0 ? percent.toString() + '%' : '适应窗口';
  }

  @Builder remoteDisplayScaleRow() {
    Column() {
      Row() {
        Row() { Image($r('app.media.icon_desktop')).width(22).height(22).fillColor(this.pal().text3) }
          .width(22).height(22).justifyContent(FlexAlign.Center).margin({ left: 9, right: 9 })
        Column() {
          Text('本地显示缩放').fontSize(AppTheme.fontSize.body).fontWeight(FontWeight.Medium)
            .fontColor(this.pal().text).fontFamily(this.font())
          Text(this.remoteDisplayScaleLabel() + '，不改变远端分辨率')
            .fontSize(11).fontColor(this.pal().text3).fontFamily(this.font())
        }.alignItems(HorizontalAlign.Start).layoutWeight(1).margin({ left: 4 })
      }.width('100%').height(54).padding({ left: 16, right: 16 })
      Scroll() {
        Row({ space: 8 }) {
          this.remoteDisplayScaleChip('适应', 'fit')
          this.remoteDisplayScaleChip('100%', '100')
          this.remoteDisplayScaleChip('125%', '125')
          this.remoteDisplayScaleChip('150%', '150')
          this.remoteDisplayScaleChip('175%', '175')
          this.remoteDisplayScaleChip('200%', '200')
          this.remoteDisplayScaleChip('自定义', 'custom')
        }.padding({ left: 16, right: 16 })
      }
      .scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off)
      .width('100%').height(42)
      if (normalizeLocalViewScaleMode(this.remoteDisplayScaleMode) === 'custom') {
        Row({ space: 8 }) {
          Text('自定义比例').fontSize(12).fontColor(this.pal().text2)
          TextInput({ text: this.remoteDisplayCustomScalePercent.toString(), placeholder: '50 - 300' })
            .width(96).height(34).type(InputType.Number).fontSize(13)
            .fontColor(this.pal().text).backgroundColor(this.pal().surface).borderRadius(6)
            .onChange((value: string): void => { this.saveRemoteDisplayCustomScalePercent(value); })
          Text('%').fontSize(12).fontColor(this.pal().text3)
        }.width('100%').padding({ left: 16, right: 16, bottom: 10 })
      }
    }.width('100%')
  }

  @Builder remoteDisplayScaleChip(label: string, mode: string) {
    Text(label).fontSize(11)
      .fontColor(this.remoteDisplayScaleMode === mode ? '#FFFFFF' : this.pal().text2)
      .fontWeight(this.remoteDisplayScaleMode === mode ? FontWeight.Medium : FontWeight.Normal)
      .padding({ left: 10, right: 10, top: 7, bottom: 7 })
      .backgroundColor(this.remoteDisplayScaleMode === mode ? this.accentColor : this.pal().surface)
      .borderRadius(6)
      .onClick((): void => { this.saveRemoteDisplayScaleMode(mode); })
  }

  @Builder remoteWheelDirectionRow() {
    Column() {
      Row() {
        Row() { Image($r('app.media.icon_desktop')).width(22).height(22).fillColor(this.pal().text3) }
          .width(22).height(22).justifyContent(FlexAlign.Center).margin({ left: 9, right: 9 })
        Column() {
          Text('远程滚轮方向').fontSize(AppTheme.fontSize.body).fontWeight(FontWeight.Medium)
            .fontColor(this.pal().text).fontFamily(this.font())
          Text('适用于 RDP、RustDesk、实体鼠标和触控板')
            .fontSize(11).fontColor(this.pal().text3).fontFamily(this.font())
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        }.alignItems(HorizontalAlign.Start).layoutWeight(1).margin({ left: 4 })
      }.width('100%').height(54).padding({ left: 16, right: 16 })
      Row({ space: 8 }) {
        this.remoteWheelDirectionChip('正常', false)
        this.remoteWheelDirectionChip('反向', true)
      }.width('100%').height(42).justifyContent(FlexAlign.Center)
    }.width('100%')
  }

  @Builder remoteWheelDirectionChip(label: string, reverse: boolean) {
    Text(label).fontSize(11).fontWeight(this.rustdeskReverseWheel === reverse ? FontWeight.Medium : FontWeight.Normal)
      .fontColor(this.rustdeskReverseWheel === reverse ? '#FFFFFF' : this.pal().text2)
      .textAlign(TextAlign.Center).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
      .width(88).padding({ top: 7, bottom: 7 })
      .backgroundColor(this.rustdeskReverseWheel === reverse ? this.accentColor : this.pal().surface)
      .borderRadius(6)
      .onClick((): void => { this.saveRemoteReverseWheel(reverse); })
  }

  @Builder canvasGestureZoomRow() {
    if (!this.isDesktopDevice) {
      this.rustdeskSwitchRow($r('app.media.icon_desktop'), '双指画布缩放',
        '捏合后缩放和平移画面；双指轻点始终保留右键，关闭后保留原有双指右键和滚轮',
        this.canvasGestureZoomEnabled,
        (on: boolean): void => { this.saveCanvasGestureZoomEnabled(on); }, true)
    }
  }

  @Builder rdpColorDepthRow() {
    if (this.breakpoint === 'md' || this.breakpoint === 'lg') {
      Row() {
        this.rdpColorDepthLabelBlock()
        this.rdpColorDepthSlider()
      }.width('100%').height(64).padding({ left: 16, right: 16 })
    } else {
      Column() {
        Row() {
          this.rdpColorDepthLabelBlock()
        }.width('100%')
        Row() {
          this.rdpColorDepthSlider()
        }.width('100%').justifyContent(FlexAlign.Center).margin({ top: 10 })
      }.width('100%').height(92).padding({ left: 16, right: 16, top: 14, bottom: 12 })
    }
  }

  private rdpColorDepthIndex(): number {
    if (this.rdpColorDepth === 16) { return 0; }
    if (this.rdpColorDepth === 24) { return 1; }
    return 2;
  }

  @Builder rdpColorDepthLabelBlock() {
    Row() {
      Row() { Image($r('app.media.icon_laptop')).width(22).height(22).fillColor(this.pal().text3) }
        .width(22).height(22).justifyContent(FlexAlign.Center).margin({ left: 9, right: 9 })
      Column() {
        Text('色彩深度').fontSize(AppTheme.fontSize.body).fontWeight(FontWeight.Medium)
          .fontColor(this.pal().text).fontFamily(this.font())
        Text(this.rdpColorDepth.toString() + ' 位色').fontSize(11).fontColor(this.pal().text3).fontFamily(this.font())
      }.alignItems(HorizontalAlign.Start).layoutWeight(1).margin({ left: 4 })
    }.layoutWeight(1)
  }

  @Builder rdpColorDepthSlider() {
    Stack({ alignContent: Alignment.Start }) {
      Column()
        .width(72).height(30).borderRadius(8)
        .backgroundColor(this.accentColor)
        .translate({ x: this.rdpColorDepthIndex() * 76, y: 0 })
        .animation({ duration: 260, curve: Curve.FastOutSlowIn })
      Row() {
        this._rdpColorDepthSliderChip('16', 16)
        Blank().width(4)
        this._rdpColorDepthSliderChip('24', 24)
        Blank().width(4)
        this._rdpColorDepthSliderChip('32', 32)
      }
    }.padding(3).borderRadius(11).backgroundColor(this.pal().surface)
  }

  @Builder _rdpColorDepthSliderChip(label: string, value: number) {
    Column() {
      Text(label)
        .fontSize(11)
        .fontColor(this.rdpColorDepth === value ? '#FFFFFF' : this.pal().text2)
        .fontWeight(this.rdpColorDepth === value ? FontWeight.Medium : FontWeight.Normal)
        .textAlign(TextAlign.Center)
        .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        .padding({ left: 8, right: 8, top: 6, bottom: 6 })
        .borderRadius(8)
        .onClick((): void => { this.saveRdpColorDepth(value); })
    }.width(72).justifyContent(FlexAlign.Center)
  }

  @Builder rdpControlModeRow() {
    if (this.breakpoint === 'md' || this.breakpoint === 'lg') {
      Row() {
        this.rdpControlModeLabel()
        this.rdpControlModeSlider()
      }.width('100%').height(64).padding({ left: 16, right: 16 })
    } else {
      Column() {
        Row() {
          this.rdpControlModeLabel()
        }.width('100%')
        Row() {
          this.rdpControlModeSlider()
        }.width('100%').justifyContent(FlexAlign.Center).margin({ top: 10 })
      }.width('100%').height(92).padding({ left: 16, right: 16, top: 14, bottom: 12 })
    }
  }

  private rdpControlModeDetail(): string {
    if (this.rdpControlMode === 1) { return '直接触控，按下即拖动'; }
    if (this.rdpControlMode === 2) { return '键盘鼠标直通，适合 PC 和外接键鼠'; }
    return '触控板映射，适合 Windows 精确操作';
  }

  @Builder rdpControlModeLabel() {
    Row() {
      Row() { Image($r('app.media.icon_desktop')).width(22).height(22).fillColor(this.pal().text3) }
        .width(22).height(22).justifyContent(FlexAlign.Center).margin({ left: 9, right: 9 })
      Column() {
        Text('操控模式').fontSize(AppTheme.fontSize.body).fontWeight(FontWeight.Medium)
          .fontColor(this.pal().text).fontFamily(this.font())
        Text(this.rdpControlModeDetail())
          .fontSize(11).fontColor(this.pal().text3).fontFamily(this.font())
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
      }.alignItems(HorizontalAlign.Start).layoutWeight(1).margin({ left: 4 })
    }.layoutWeight(1)
  }

  @Builder rdpControlModeSlider() {
    Stack({ alignContent: Alignment.Start }) {
      Column()
        .width(72).height(30).borderRadius(8)
        .backgroundColor(this.accentColor)
        .translate({ x: this.rdpControlMode * 76, y: 0 })
        .animation({ duration: 260, curve: Curve.FastOutSlowIn })
      Row() {
        this._rdpControlModeChip('触控板', 0)
        Blank().width(4)
        this._rdpControlModeChip('触控', 1)
        Blank().width(4)
        this._rdpControlModeChip('键鼠', 2)
      }
    }.padding(3).borderRadius(11).backgroundColor(this.pal().surface)
  }

  @Builder _rdpControlModeChip(label: string, mode: number) {
    Column() {
      Text(label)
        .fontSize(11)
        .fontColor(this.rdpControlMode === mode ? '#FFFFFF' : this.pal().text2)
        .fontWeight(this.rdpControlMode === mode ? FontWeight.Medium : FontWeight.Normal)
        .textAlign(TextAlign.Center)
        .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        .padding({ left: 8, right: 8, top: 6, bottom: 6 })
        .borderRadius(8)
        .onClick((): void => { this.saveRdpControlMode(mode); })
    }.width(72).justifyContent(FlexAlign.Center)
  }

  private rdpAuthIdentityModeLabel(): string {
    if (this.rdpAuthIdentityMode === 1) { return 'MicrosoftAccount 域 + 邮箱'; }
    if (this.rdpAuthIdentityMode === 2) { return '仅邮箱'; }
    if (this.rdpAuthIdentityMode === 3) { return '.\\AzureAD\\邮箱'; }
    if (this.rdpAuthIdentityMode === 4) { return 'AzureAD 域 + 邮箱'; }
    return 'MicrosoftAccount\\邮箱';
  }

  @Builder rdpAuthIdentityModeRow() {
    if (this.breakpoint === 'md' || this.breakpoint === 'lg') {
      Row() {
        this.rdpAuthIdentityModeLabelBlock()
        this.rdpAuthIdentityModeSlider()
      }.width('100%').height(64).padding({ left: 16, right: 16 })
    } else {
      Column() {
        Row() {
          this.rdpAuthIdentityModeLabelBlock()
        }.width('100%')
        Row() {
          this.rdpAuthIdentityModeSlider()
        }.width('100%').justifyContent(FlexAlign.Center).margin({ top: 10 })
      }.width('100%').height(92).padding({ left: 16, right: 16, top: 14, bottom: 12 })
    }
  }

  @Builder rdpAuthIdentityModeLabelBlock() {
    Row() {
      Row() { Image($r('app.media.icon_lock')).width(22).height(22).fillColor(this.pal().text3) }
        .width(22).height(22).justifyContent(FlexAlign.Center).margin({ left: 9, right: 9 })
      Column() {
        Text('账号格式').fontSize(AppTheme.fontSize.body).fontWeight(FontWeight.Medium)
          .fontColor(this.pal().text).fontFamily(this.font())
        Text(this.rdpAuthIdentityModeLabel()).fontSize(11).fontColor(this.pal().text3).fontFamily(this.font())
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
      }.alignItems(HorizontalAlign.Start).layoutWeight(1).margin({ left: 4 })
    }.layoutWeight(1)
  }

  @Builder rdpAuthIdentityModeSlider() {
    Stack({ alignContent: Alignment.Start }) {
      Column()
        .width(58).height(30).borderRadius(8)
        .backgroundColor(this.accentColor)
        .translate({ x: this.rdpAuthIdentityMode * 61, y: 0 })
        .animation({ duration: 260, curve: Curve.FastOutSlowIn })
      Row() {
        this._rdpAuthIdentityModeSliderChip('MSA前', 0)
        Blank().width(3)
        this._rdpAuthIdentityModeSliderChip('MSA域', 1)
        Blank().width(3)
        this._rdpAuthIdentityModeSliderChip('邮箱', 2)
        Blank().width(3)
        this._rdpAuthIdentityModeSliderChip('AAD.', 3)
        Blank().width(3)
        this._rdpAuthIdentityModeSliderChip('AAD域', 4)
      }
    }.padding(3).borderRadius(11).backgroundColor(this.pal().surface)
  }

  @Builder _rdpAuthIdentityModeSliderChip(label: string, mode: number) {
    Column() {
      Text(label)
        .fontSize(11)
        .fontColor(this.rdpAuthIdentityMode === mode ? '#FFFFFF' : this.pal().text2)
        .fontWeight(this.rdpAuthIdentityMode === mode ? FontWeight.Medium : FontWeight.Normal)
        .textAlign(TextAlign.Center)
        .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        .padding({ left: 8, right: 8, top: 6, bottom: 6 })
        .borderRadius(8)
        .onClick((): void => { this.saveRdpAuthIdentityMode(mode); })
    }.width(58).justifyContent(FlexAlign.Center)
  }

  @Builder rdpDriveNameRow() {
    Row() {
      Row() { Image($r('app.media.icon_folder')).width(22).height(22).fillColor(this.pal().text3) }
        .width(22).height(22).justifyContent(FlexAlign.Center).margin({ left: 9, right: 9 })
      Column() {
        Text('文件共享盘名称').fontSize(AppTheme.fontSize.body).fontWeight(FontWeight.Medium)
          .fontColor(this.pal().text).fontFamily(this.font())
        Text('Windows 路径: \\\\tsclient\\' + this.rdpDriveName)
          .fontSize(11).fontColor(this.pal().text3).fontFamily(this.font())
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
      }.alignItems(HorizontalAlign.Start).layoutWeight(1).margin({ left: 4 })
      TextInput({ text: this.rdpDriveName, placeholder: 'RemoteDesktop' })
        .width(144).height(36).fontSize(13).fontColor(this.pal().text).placeholderColor(this.pal().text3)
        .backgroundColor(this.pal().surface).borderRadius(10).padding({ left: 10, right: 10 })
        .enabled(this.rdpDriveEnabled)
        .opacity(this.rdpDriveEnabled ? 1.0 : 0.55)
        .onChange((v: string): void => { this.saveRdpDriveName(v); })
    }.width('100%').height(64).padding({ left: 16, right: 16 })
  }

  @Builder rdpCredentialManagerRow() {
    Row() {
      Row() { Image($r('app.media.icon_lock')).width(22).height(22).fillColor(this.pal().text3) }
        .width(22).height(22).justifyContent(FlexAlign.Center).margin({ left: 9, right: 9 })
      Column() {
        Text('Windows 凭据').fontSize(AppTheme.fontSize.body).fontWeight(FontWeight.Medium)
          .fontColor(this.pal().text).fontFamily(this.font())
        Text(this.rdpCredentials.length > 0 ? '已保存 ' + this.rdpCredentials.length + ' 个账户' : '添加邮箱或本地 Windows 账户')
          .fontSize(11).fontColor(this.pal().text3).fontFamily(this.font())
      }.alignItems(HorizontalAlign.Start).layoutWeight(1).margin({ left: 4 })
      Text('管理').fontSize(13).fontColor(this.accentColor).fontWeight(FontWeight.Medium)
        .fontFamily(this.font()).margin({ right: 6 })
      Text(' >').fontSize(14).fontColor(this.pal().text3)
    }.width('100%').height(64).padding({ left: 16, right: 16 })
    .onClick((): void => {
      this.openRdpCredentialManager();
    })
  }

  @Builder rustdeskControlModeRow() {
    if (this.breakpoint === 'md' || this.breakpoint === 'lg') {
      Row() {
        this.rustdeskControlModeLabel()
        this.rustdeskControlModeSlider()
      }.width('100%').height(64).padding({ left: 16, right: 16 })
    } else {
      Column() {
        Row() {
          this.rustdeskControlModeLabel()
        }.width('100%')
        Row() {
          Blank().layoutWeight(1)
          this.rustdeskControlModeSlider()
        }.width('100%').margin({ top: 10 })
      }.width('100%').height(92).padding({ left: 16, right: 16, top: 14, bottom: 12 })
    }
  }

  private rustdeskControlModeDetail(): string {
    if (this.rustdeskControlMode === 1) { return '直接触控，按下即拖动'; }
    if (this.rustdeskControlMode === 2) { return '键盘鼠标直通，适合 PC 和外接键鼠'; }
    return '触控板映射，移动指针后抬手点击/右键';
  }

  @Builder rustdeskControlModeLabel() {
    Row() {
      Row() { Image($r('app.media.icon_desktop')).width(22).height(22).fillColor(this.pal().text3) }
        .width(22).height(22).justifyContent(FlexAlign.Center).margin({ left: 9, right: 9 })
      Column() {
        Text('操控模式').fontSize(AppTheme.fontSize.body).fontWeight(FontWeight.Medium)
          .fontColor(this.pal().text).fontFamily(this.font())
        Text(this.rustdeskControlModeDetail())
          .fontSize(11).fontColor(this.pal().text3).fontFamily(this.font())
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
      }.alignItems(HorizontalAlign.Start).layoutWeight(1).margin({ left: 4 })
    }.layoutWeight(1)
  }

  @Builder rustdeskControlModeSlider() {
    Stack({ alignContent: Alignment.Start }) {
      Column()
        .width(72).height(30).borderRadius(8)
        .backgroundColor(this.accentColor)
        .translate({ x: this.rustdeskControlMode * 76, y: 0 })
        .animation({ duration: 260, curve: Curve.FastOutSlowIn })
      Row() {
        this._controlModeChip('触控板', 0)
        Blank().width(4)
        this._controlModeChip('触控', 1)
        Blank().width(4)
        this._controlModeChip('键鼠', 2)
      }
    }.padding(3).borderRadius(11).backgroundColor(this.pal().surface)
  }

  @Builder _controlModeChip(label: string, mode: number) {
    Column() {
      Text(label)
        .fontSize(11)
        .fontColor(this.rustdeskControlMode === mode ? '#FFFFFF' : this.pal().text2)
        .fontWeight(this.rustdeskControlMode === mode ? FontWeight.Medium : FontWeight.Normal)
        .textAlign(TextAlign.Center)
        .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        .padding({ left: 8, right: 8, top: 6, bottom: 6 })
        .borderRadius(8)
        .onClick((): void => { this.saveRustDeskControlMode(mode); })
    }.width(72).justifyContent(FlexAlign.Center)
  }
  @Builder rustdeskSwitchRow(icon: Resource, label: string, detail: string, isOn: boolean,
    onToggle: (on: boolean) => void, neutralIcon: boolean = false, enabled: boolean = true) {
    Row() {
      Row() { Image(icon).width(22).height(22).fillColor(neutralIcon ? this.pal().text3 : (isOn ? this.accentColor : this.pal().text3)) }
        .width(22).height(22).justifyContent(FlexAlign.Center).margin({ left: 9, right: 9 })
      Column() {
        Text(label).fontSize(AppTheme.fontSize.body).fontWeight(FontWeight.Medium)
          .fontColor(this.pal().text).fontFamily(this.font())
        Text(detail).fontSize(11).fontColor(this.pal().text3).fontFamily(this.font())
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
      }.alignItems(HorizontalAlign.Start).layoutWeight(1).margin({ left: 4 })
      Toggle({ type: ToggleType.Switch, isOn: isOn })
        .selectedColor(this.accentColor)
        .scale({ x: 0.88, y: 0.88 })
        .enabled(enabled)
        .onChange((on: boolean) => {
          animateTo({ duration: 250, curve: Curve.FastOutSlowIn }, () => {
            onToggle(on);
          })
        })
    }.width('100%').height(64).padding({ left: 16, right: 16 })
  }

  /** 灵动岛模式选择行: 类似 radio 按钮的视觉效果 */
  @Builder liveViewModeRow(label: string, detail: string, mode: number) {
    Row() {
      Row() {
        // 选中指示器: 实心圆 / 空心圆
        if (this.liveViewMode === mode && this.liveViewEnabled) {
          Column().width(18).height(18).borderRadius(9)
            .backgroundColor(this.accentColor)
        } else {
          Column().width(18).height(18).borderRadius(9)
            .border({ width: 1.5, color: this.liveViewEnabled ? this.pal().text3 : this.pal().divider })
        }
      }.width(22).height(22).justifyContent(FlexAlign.Center).margin({ left: 9, right: 9 })
      Column() {
        Text(label).fontSize(AppTheme.fontSize.body).fontWeight(FontWeight.Medium)
          .fontColor(this.liveViewEnabled ? this.pal().text : this.pal().text3).fontFamily(this.font())
        Text(detail).fontSize(11).fontColor(this.pal().text3).fontFamily(this.font())
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
      }.alignItems(HorizontalAlign.Start).layoutWeight(1).margin({ left: 4 })
    }.width('100%').height(64).padding({ left: 16, right: 16 })
    .onClick(() => {
      animateTo({ duration: 250, curve: Curve.FastOutSlowIn }, () => {
        // 选择模式时自动启用开关
        if (!this.liveViewEnabled) {
          this.liveViewEnabled = true;
          this.persistPref('liveViewEnabled', true);
        }
        this.liveViewMode = mode;
        this.persistPref('liveViewMode', mode);
      })
    })
  }

  @Builder rustdeskPortRow() {
    Row() {
      Row() { Image($r('app.media.icon_desktop')).width(22).height(22).fillColor(this.rustdeskDirectIp ? this.accentColor : this.pal().text3) }
        .width(22).height(22).justifyContent(FlexAlign.Center).margin({ left: 9, right: 9 })
      Column() {
        Text('直连端口').fontSize(AppTheme.fontSize.body).fontWeight(FontWeight.Medium)
          .fontColor(this.pal().text).fontFamily(this.font())
        Text('默认 21118').fontSize(11).fontColor(this.pal().text3).fontFamily(this.font())
      }.alignItems(HorizontalAlign.Start).layoutWeight(1).margin({ left: 4 })
      TextInput({ text: this.rustdeskDirectPort.toString(), placeholder: '21118' })
        .width(96).height(36).fontSize(13).fontColor(this.pal().text).placeholderColor(this.pal().text3)
        .backgroundColor(this.pal().surface).borderRadius(10).padding({ left: 10, right: 10 })
        .enabled(this.rustdeskDirectIp)
        .onChange((v: string): void => {
          const n: number = parseInt(v);
          if (!isNaN(n)) { this.saveRustDeskDirectPort(n); }
        })
    }.width('100%').height(64).padding({ left: 16, right: 16 })
  }

  @Builder colorPickerSheet() {
    ColorPickerSheet()
  }

  // ==================== Sheet builder ====================
  @Builder hostAddSheetContent() {
    if (this.addSheetShowsModernPicker) {
      HostAddWizardSheet({
        onSelectProtocol: (protocol: string): void => {
          this.modernAddProtocol = protocol;
          this.addSheetShowsModernPicker = false;
          if (protocol !== 'rdp') {
            this.switchHostProtocol(protocol, RemoteHost.getDefaultPort(protocol));
          }
        },
        onClose: (): void => { this.requestAddSheetClose(); }
      })
    } else if (this.modernAddProtocol === 'rdp') {
      RdpAddFlow({
        credentials: this.rdpCredentials,
        onBackToProtocols: (): void => { this.modernAddProtocol = ''; this.addSheetShowsModernPicker = true; },
        onAddCredential: (): void => { this.openRdpCredentialManager(); },
        onSave: (host: RemoteHost, connectNow: boolean, restrictedAdminHash: string): void => {
          this.saveHostFromAddFlow(host, connectNow, restrictedAdminHash);
        }
      })
    } else if (this.modernAddProtocol === 'rustdesk') {
      RustDeskAddFlow({
        relays: this.srv.getAllRelays(),
        lanScanning: this.lanScanning,
        lanPeers: this.lanScanResults,
        defaultDirectPort: this.rustdeskDirectPort,
        onBackToProtocols: (): void => { this.modernAddProtocol = ''; this.addSheetShowsModernPicker = true; },
        onStartLanScan: (): void => { this.startLanScan(); },
        onAddRelay: (relay: RustDeskRelayConfig): boolean => {
          return this.srv.addRelay(relay);
        },
        onSave: (host: RemoteHost, connectNow: boolean): void => {
          this.saveHostFromAddFlow(host, connectNow);
        }
      })
    } else if (this.modernAddProtocol === 'ssh') {
      SshAddFlow({
        keys: this.keyVault.getAllSshKeys(),
        onBackToProtocols: (): void => { this.modernAddProtocol = ''; this.addSheetShowsModernPicker = true; },
        onSave: (host: RemoteHost, connectNow: boolean): void => {
          this.saveHostFromAddFlow(host, connectNow);
        }
      })
    } else {
      this.sheetBuilder()
    }
  }

  @Builder rustDeskAuthTrustManagerSheet() {
    Column() {
      Row() {
        Column() {
          Text('RustDesk 认证信任').fontSize(20).fontWeight(FontWeight.Bold).fontColor(this.pal().text)
          Text('管理各主机默认认证方式；密码内容不会在此显示').fontSize(11).fontColor(this.pal().text3)
            .margin({ top: 3 })
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        Text('完成').fontSize(13).fontColor(this.accentColor).onClick((): void => { this.closeSettingsLeafSheet(); })
      }.width('100%').padding({ left: 22, right: 22, top: 22 }).margin({ bottom: 14 })
      if (this.rustDeskHosts().length === 0) {
        Text('暂无 RustDesk 主机').fontSize(13).fontColor(this.pal().text3)
          .width('100%').textAlign(TextAlign.Center).padding(32)
      } else {
        List({ space: 8 }) {
          ForEach(this.rustDeskHosts(), (host: RemoteHost) => {
            ListItem() {
              Column() {
                Row() {
                  Column() {
                    Text(host.label).fontSize(14).fontWeight(FontWeight.Medium).fontColor(this.pal().text)
                    Text((host.customHostname !== '' ? host.customHostname : host.host) + ' · ' +
                      (host.rustdeskDirectEnabled ? '直连' : (host.rustdeskProManaged ? 'Pro 中继' : '中继')))
                      .fontSize(11).fontColor(this.pal().text3).margin({ top: 2 })
                  }.alignItems(HorizontalAlign.Start).layoutWeight(1)
                  Text(this.rustDeskAuthTrustLabel(host)).fontSize(11).fontColor(this.accentColor)
                    .padding({ left: 8, right: 8, top: 4, bottom: 4 }).borderRadius(8)
                    .backgroundColor(this.pal().surface)
                }.width('100%')
                Row() {
                  if (!host.rustdeskDirectEnabled) {
                    Button(host.rustdeskAuthMode === 'request_approval' ? '改用密码' : '改为请求批准')
                      .height(32).layoutWeight(1).fontSize(11).borderRadius(8)
                      .backgroundColor(this.pal().surface).fontColor(this.accentColor)
                      .onClick((): void => { this.toggleRustDeskAuthTrust(host); })
                  }
                  if (host.password !== '') {
                    Button('清除密码').height(32).layoutWeight(1).fontSize(11).borderRadius(8)
                      .margin({ left: host.rustdeskDirectEnabled ? 0 : 6 })
                      .backgroundColor(this.pal().surface).fontColor(this.pal().danger)
                      .onClick((): void => { this.clearRustDeskSavedPassword(host); })
                  }
                  Button('每次询问').height(32).layoutWeight(1).fontSize(11).borderRadius(8).margin({ left: 6 })
                    .backgroundColor(this.pal().surface).fontColor(this.pal().text2)
                    .onClick((): void => { this.clearRustDeskAuthTrust(host); })
                }.width('100%').margin({ top: 10 })
              }.width('100%').padding(13).borderRadius(12).backgroundColor(this.pal().card)
              .border({ width: 0.5, color: this.pal().cardBorder, style: BorderStyle.Solid })
            }
          }, (host: RemoteHost): string => host.id + ':' + this.hostViewRevision.toString())
        }.width('100%')
        .height(this.rustDeskHosts().length > 4 ? 420 : (this.rustDeskHosts().length * 112 + 12))
        .padding({ left: 20, right: 20 }).margin({ bottom: 22 })
      }
    }.width('100%').backgroundColor(this.pal().bg).constraintSize({ maxWidth: 620, maxHeight: 620 })
    .borderRadius(this.breakpoint === 'sm' ? { topLeft: 20, topRight: 20, bottomLeft: 0, bottomRight: 0 } : 20)
  }

  @Builder sheetBuilder() {
    Column() {
      // 标题
      Text(this.editingHostId !== '' ? '编辑主机' :
        (this.proto === 'ssh' ? '添加 SSH 终端' : (this.proto === 'rustdesk' ? '添加 RustDesk 主机' : '添加 RDP 主机')))
        .fontSize(16).fontWeight(FontWeight.Bold).fontColor(this.pal().text)
        .width('100%').margin({ bottom: 12 }).fontFamily(this.font())

      Scroll() {
        Column() {
          // 协议选择
          Row() {
            this.protoBtn('RDP', 'rdp', 3389)
            this.protoBtn('RustDesk', 'rustdesk', 21116)
            this.protoBtn('SSH', 'ssh', 22)
          }.width('100%').margin({ bottom: 12 })

          // 名称
          this.fieldRow('名称', this.proto === 'ssh' ? 'Web 服务器' : '办公室电脑', this.label, (v: string): void => { this.label = v; })

          // RustDesk: 无需地址/端口/用户名, 走远程ID + 中继
          if (this.proto !== 'rustdesk') {
            // 地址
            this.fieldRow('地址', this.proto === 'ssh' ? '192.168.1.10' : '192.168.1.100', this.hostAddr, (v: string): void => { this.hostAddr = v; })

            // 端口 + 用户名
            Row() {
              Column() {
                if (this.proto === 'ssh') {
                  this.fieldRow('端口', '22', this.sshPortVal.toString(), (v: string): void => {
                    const n: number = parseInt(v);
                    this.sshPortVal = isNaN(n) ? RemoteHost.getDefaultPort('ssh') : n;
                    this.portVal = this.sshPortVal;
                  })
                } else {
                  this.fieldRow('端口', '3389', this.rdpPortVal.toString(), (v: string): void => {
                    const n: number = parseInt(v);
                    this.rdpPortVal = isNaN(n) ? RemoteHost.getDefaultPort('rdp') : n;
                    this.portVal = this.rdpPortVal;
                  })
                }
              }.width('30%')
              Column() {
                this.fieldRow('用户名', this.proto === 'rdp' && this.sheetRdpAuthMode === 'password' &&
                  this.selectedRdpCredentialId !== '' ? '已使用 Windows 凭据' :
                  (this.proto === 'rdp' ? 'user 或 DOMAIN\\user' : 'root'),
                  this.username, (v: string): void => { this.username = v; },
                  !(this.proto === 'rdp' && this.sheetRdpAuthMode === 'password' &&
                    this.selectedRdpCredentialId !== ''))
              }.width('60%').margin({ left: 12 })
            }.width('100%')
          }

          if (this.proto === 'rdp') {
            this.rdpAuthenticationModeSection()
            if (this.sheetRdpAuthMode === 'password') {
              this.rdpCredentialSection()
            }
          }

          // 密码
          if (this.proto !== 'rdp' || this.sheetRdpAuthMode === 'password') {
            this.pwdRow(!(this.proto === 'rdp' && this.selectedRdpCredentialId !== ''))
          }

          if (this.proto === 'rdp') {
            this.fieldRow('主机名(可选)', '标识', this.chn, (v: string): void => { this.chn = v; })
          }

          if (this.proto === 'rustdesk') {
            // RustDesk 远程设备 ID
            this.fieldRow('远程 ID', this.isEditingProHost() ? 'Pro 设备 ID（只读）' :
              (this.sheetRustdeskDirectEnabled ? '直连模式可留空' : '中继模式必填'),
              this.chn, (v: string): void => { this.chn = v; }, !this.isEditingProHost())

            // 密码模式切换
            Text('密码模式').fontSize(11).fontColor(this.pal().text2).margin({ bottom: 4 }).fontFamily(this.font())
            Row() {
              Text('一次性密码 (临时会话)').fontSize(13)
                .fontColor(this.sheetPwdMode === 0 ? this.accentColor : this.pal().text2)
                .fontWeight(this.sheetPwdMode === 0 ? FontWeight.Medium : FontWeight.Normal)
              Toggle({ type: ToggleType.Switch, isOn: this.sheetPwdMode === 1 })
                .selectedColor(this.accentColor).scale({ x: 0.82, y: 0.82 }).margin({ left: 8, right: 8 })
                .enabled(!this.isEditingProHost())
                .onChange((on: boolean) => { this.sheetPwdMode = on ? 1 : 0; })
              Text('永久密码').fontSize(13)
                .fontColor(this.sheetPwdMode === 1 ? this.accentColor : this.pal().text2)
                .fontWeight(this.sheetPwdMode === 1 ? FontWeight.Medium : FontWeight.Normal)
            }.width('100%').justifyContent(FlexAlign.Start).margin({ bottom: 8 })

            if (this.sheetPwdMode === 0) {
              Row() {
                SymbolGlyph($r('sys.symbol.key_fill'))
                  .fontSize(14).fontColor([this.pal().text3])
                Text('对方设备生成临时密码后直接输入即可连接')
                  .fontSize(11).fontColor(this.pal().text3).fontFamily(this.font()).margin({ left: 4 })
              }.width('100%').margin({ bottom: 8 })
            }
            if (this.sheetPwdMode === 1) {
              Row() {
                Text('⚠️').fontSize(14)
                Text('永久密码需在对方设备 RustDesk 设置中预先配置')
                  .fontSize(11).fontColor(this.pal().text3).fontFamily(this.font()).margin({ left: 4 })
              }.width('100%').margin({ bottom: 8 })
            }

            Text('连接授权').fontSize(11).fontColor(this.pal().text2).margin({ bottom: 4 }).fontFamily(this.font())
            Row() {
              Text('使用设备密码').fontSize(13)
                .fontColor(this.sheetRustdeskAuthMode === 'password' ? this.accentColor : this.pal().text2)
                .fontWeight(this.sheetRustdeskAuthMode === 'password' ? FontWeight.Medium : FontWeight.Normal)
              Toggle({ type: ToggleType.Switch, isOn: this.sheetRustdeskAuthMode === 'request_approval' })
                .selectedColor(this.accentColor).scale({ x: 0.82, y: 0.82 }).margin({ left: 8, right: 8 })
                .onChange((on: boolean) => {
                  this.sheetRustdeskAuthMode = on ? 'request_approval' : 'password';
                })
              Text('请求被控端批准').fontSize(13)
                .fontColor(this.sheetRustdeskAuthMode === 'request_approval' ? this.accentColor : this.pal().text2)
                .fontWeight(this.sheetRustdeskAuthMode === 'request_approval' ? FontWeight.Medium : FontWeight.Normal)
            }.width('100%').justifyContent(FlexAlign.Start).margin({ bottom: 4 })
            Row() {
              SymbolGlyph($r('sys.symbol.info_circle')).fontSize(14).fontColor([this.pal().text3])
              Text(this.sheetRustdeskAuthMode === 'request_approval' ?
                '对方需启用点击批准；应用会保持连接等待批准，不会把空密码当成密码登录' :
                '一次性/永久密码由对方 RustDesk 设置决定；账户密码不能代替设备密码')
                .fontSize(11).fontColor(this.pal().text3).fontFamily(this.font()).margin({ left: 4 })
            }.width('100%').margin({ bottom: 8 })

            // 中继服务器选择
            Row() {
              Text('中继配置').fontSize(11).fontColor(this.pal().text2).margin({ bottom: 4 }).fontFamily(this.font())
              Blank()
            }.width('100%')
            if (this.srv.getRelayCount() === 0) {
              // 无中继: 引导卡
              Column() {
                SymbolGlyph($r('sys.symbol.cloud_fill')).fontSize(28).fontColor([this.pal().text3])
                Text('还没有 RustDesk 中继').fontSize(13).fontColor(this.pal().text).fontFamily(this.font()).margin({ top: 6 })
                Text('先添加中继配置后再绑定主机').fontSize(11).fontColor(this.pal().text3).fontFamily(this.font()).margin({ top: 2 })
                Button('去添加中继').fontSize(12).height(32)
                  .backgroundColor(this.accentColor).fontColor('#FFFFFF').borderRadius(16)
                  .margin({ top: 10 }).padding({ left: 16, right: 16 })
                  .onClick(() => {
                    this.requestAddSheetClose();
                    // PC侧边栏 relay=5, 移动 Tabs relay=2
                    if (this.isDesktopDevice && this.breakpoint === 'xl') {
                      this.curTab = 5;
                    } else {
                      this.curTab = 2;
                    }
                    this.relayAddTrigger++;
                  })
              }.width('100%').padding({ top: 16, bottom: 16 })
              .borderRadius(10).backgroundColor(this.pal().surface)
              .border({ width: 0.5, color: this.pal().cardBorder, style: BorderStyle.Dashed })
              .margin({ bottom: 10 })
            } else {
              Column() {
                ForEach(this.srv.getAllRelays(), (relay: RustDeskRelayConfig) => {
                  Row() {
                    Column() {
                      Row() {
                        Text(relay.displayName()).fontSize(13).fontColor(this.pal().text).fontFamily(this.font())
                      }
                      Row() {
                        Column().width(5).height(5).borderRadius(2)
                          .backgroundColor(this.relayStatusColor(relay.healthStatus))
                        Text(this.relayStatusLabel(relay.healthStatus))
                          .fontSize(9).fontColor(this.relayStatusColor(relay.healthStatus)).margin({ left: 3 })
                        if (relay.healthLatency > 0 && relay.healthStatus === 'online') {
                          Text(' · ' + relay.healthLatency + 'ms')
                            .fontSize(9).fontColor(this.pal().text3).margin({ left: 2 })
                        }
                        Text(' · ' + this.hostCountForRelayId(relay.id) + '台主机')
                          .fontSize(9).fontColor(this.pal().text3).margin({ left: 2 })
                        Text(' · ' + relay.accounts.length + '账户')
                          .fontSize(9).fontColor(this.pal().text3).margin({ left: 2 })
                      }.margin({ top: 2 })
                    }.alignItems(HorizontalAlign.Start).layoutWeight(1)
                    if (this.selectedRelayId === relay.id) {
                      SymbolGlyph($r('sys.symbol.checkmark')).fontSize(18).fontColor([this.accentColor])
                    }
                  }.width('100%').padding({ left: 10, right: 10, top: 8, bottom: 8 })
                  .backgroundColor(this.selectedRelayId === relay.id ? this.pal().surface : Color.Transparent)
                  .borderRadius(8)
                  .enabled(!this.isEditingProHost())
                  .onClick(() => { this.selectedRelayId = relay.id; this.selectedAccountId = ''; })
                }, (relay: RustDeskRelayConfig): string =>
                  relay.id + ':' + this.hostViewRevision.toString())
              }.width('100%').backgroundColor(this.pal().surface).borderRadius(8).padding(6).margin({ bottom: 10 })
            }

            // Server Pro 账户选择 (二级: 依赖选中的 relay)
            if (this.selectedRelayId !== '') {
              Row() {
                Text('Server Pro 账户').fontSize(11).fontColor(this.pal().text2).margin({ bottom: 4 }).fontFamily(this.font())
                Blank()
              }.width('100%')
              Column() {
                if (this.srv.getAllRelays().find((r: RustDeskRelayConfig) => r.id === this.selectedRelayId) &&
                    (this.srv.getAllRelays().find((r: RustDeskRelayConfig) => r.id === this.selectedRelayId) as RustDeskRelayConfig).accounts.length > 0) {
                  ForEach((this.srv.getAllRelays().find((r: RustDeskRelayConfig) => r.id === this.selectedRelayId) as RustDeskRelayConfig).accounts, (acct: RustDeskAccount) => {
                    Row() {
                      Column() {
                        Text(acct.displayName()).fontSize(13).fontColor(this.pal().text).fontFamily(this.font())
                        Row() {
                          Text(this.accountLoginLabel(acct.loginStatus))
                            .fontSize(9).fontColor(this.accountLoginColor(acct.loginStatus))
                          Text(' · ' + this.hostCountForAccountId(this.selectedRelayId, acct.id) + '台主机')
                            .fontSize(9).fontColor(this.pal().text3).margin({ left: 2 })
                        }.margin({ top: 2 })
                      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
                      if (this.selectedAccountId === acct.id) {
                        SymbolGlyph($r('sys.symbol.checkmark')).fontSize(18).fontColor([this.accentColor])
                      }
                    }.width('100%').padding({ left: 10, right: 10, top: 8, bottom: 8 })
                    .backgroundColor(this.selectedAccountId === acct.id ? this.pal().surface : Color.Transparent)
                    .borderRadius(8).enabled(!this.isEditingProHost()).onClick(() => { this.selectedAccountId = acct.id; })
                  }, (acct: RustDeskAccount): string =>
                    acct.id + ':' + this.hostViewRevision.toString())
                } else {
                  Row() {
                    Text('该中继暂无账户').fontSize(12).fontColor(this.pal().text3).fontFamily(this.font())
                    Blank()
                    Text('去添加 →').fontSize(11).fontColor(this.accentColor).fontFamily(this.font())
                      .onClick(() => {
                        this.requestAddSheetClose();
                        if (this.isDesktopDevice && this.breakpoint === 'xl') {
                          this.curTab = 5;
                        } else {
                          this.curTab = 2;
                        }
                        this.relayAddTrigger++;
                      })
                  }.width('100%').padding({ left: 10, right: 10, top: 8, bottom: 8 })
                }
              }.width('100%').backgroundColor(this.pal().surface).borderRadius(8).padding(6).margin({ bottom: 10 })
            }
          }

          // RustDesk 直连配置 (per-host)
          if (this.proto === 'rustdesk') {
            Row() {
              Text('直连配置').fontSize(11).fontColor(this.pal().text2).margin({ bottom: 4 }).fontFamily(this.font())
            }.width('100%')
            Row() {
              Row() {
                Text('直连此设备').fontSize(13).fontColor(this.pal().text).fontFamily(this.font())
                Text('跳过 ID 服务器').fontSize(10).fontColor(this.pal().text3).fontFamily(this.font()).margin({ left: 4 })
              }.layoutWeight(1)
              Toggle({ type: ToggleType.Switch, isOn: this.sheetRustdeskDirectEnabled })
                .selectedColor(this.accentColor)
                .scale({ x: 0.82, y: 0.82 })
                .enabled(!this.isEditingProHost())
                .onChange((on: boolean) => {
                  this.sheetRustdeskDirectEnabled = on;
                  if (on) {
                    this.sheetRustdeskAuthMode = 'password';
                    this.selectedRelayId = '';
                    this.selectedAccountId = '';
                  }
                })
            }.width('100%').margin({ bottom: 8 })
            if (this.sheetRustdeskDirectEnabled) {
              Row() {
                Column() {
                  this.fieldRow('直连地址', '192.168.1.100', this.sheetRustdeskDirectHost,
                    (v: string): void => { this.sheetRustdeskDirectHost = v; })
                }.width('60%')
                Column() {
                  this.fieldRow('端口', RUSTDESK_PEER_TCP_PORT.toString(), this.sheetRustdeskDirectPort.toString(),
                    (v: string): void => {
                      const n: number = parseInt(v);
                      this.sheetRustdeskDirectPort = isNaN(n) ? RUSTDESK_PEER_TCP_PORT : n;
                    })
                }.width('30%').margin({ left: 12 })
              }.width('100%').margin({ bottom: 8 })
            }
          }

          if (this.proto === 'ssh') {
            this.sshKeySection()
          }

          if (this.sheetErr !== '') {
            Text(this.sheetErr).fontSize(12).fontColor(this.pal().danger).width('100%').margin({ top: 8 })
          }

          Button(this.editingHostId === '' ? '添加' : '保存').width('100%').height(40).fontSize(14).fontWeight(FontWeight.Medium)
            .backgroundColor(this.accentColor).fontColor('#FFFFFF').borderRadius(10).margin({ top: 16 })
            .onClick(() => { this.doAdd(); })
        }.width('100%')
      }
      .constraintSize({ maxHeight: 420 })
      .scrollBar(BarState.Auto)
      .edgeEffect(EdgeEffect.Spring)
      .width('100%')
    }
    .padding({ left: 24, right: 24, top: 24, bottom: 40 })
    .borderRadius(this.breakpoint === 'sm' ? 0 : 20)
    .backgroundColor(this.pal().bg)
    .backgroundBlurStyle(BlurStyle.Regular)
    .shadow({ radius: this.breakpoint === 'sm' ? 0 : 24, color: this.breakpoint === 'sm' ? 'rgba(0,0,0,0)' : 'rgba(0,0,0,0.12)', offsetY: this.breakpoint === 'sm' ? 0 : 6 })
    .border(this.breakpoint === 'sm'
      ? { width: 0, color: Color.Transparent, style: BorderStyle.Solid }
      : { width: 0.5, color: this.pal().cardBorder, style: BorderStyle.Solid })
  }

  @Builder protoBtn(label: string, protoVal: string, defaultPort: number) {
    Button(label).layoutWeight(1).height(36).fontSize(12)
      .fontWeight(this.proto === protoVal ? FontWeight.Medium : FontWeight.Normal)
      .backgroundColor(this.proto === protoVal ? this.accentColor : this.pal().surface)
      .fontColor(this.proto === protoVal ? '#FFFFFF' : this.pal().text).borderRadius(10)
      .shadow(this.proto === protoVal
        ? { radius: 8, color: this.pal().fabGlow, offsetY: 2 }
        : { radius: 0, color: 'rgba(0,0,0,0)', offsetY: 0 })
      .margin({ right: label !== 'SSH' ? 8 : 0 })
      .enabled(this.editingHostId === '')
      .opacity(this.editingHostId === '' || this.proto === protoVal ? 1.0 : 0.4)
      .onClick(() => {
        if (this.editingHostId !== '') { return; }
        this.switchHostProtocol(protoVal, defaultPort);
        if (protoVal === 'rustdesk') { this.sheetPwdMode = 0; }
      })
  }

  @Builder fieldRow(l: string, h: string, v: string, cb: (v: string) => void, enabled: boolean = true) {
    Column() {
      Text(l).fontSize(11).fontColor(this.pal().text2).fontFamily(this.font()).margin({ bottom: 4 })
      TextInput({ placeholder: h, text: v }).height(38).backgroundColor(this.pal().surface).borderRadius(8)
        .fontColor(this.pal().text).placeholderColor(this.pal().text3).fontFamily(this.font())
        .fontSize(13).padding({ left: 10, right: 10 }).enabled(enabled)
        .opacity(enabled ? 1.0 : 0.55)
        .onChange(cb)
    }.margin({ bottom: 8 })
  }

  @Builder pwdRow(enabled: boolean = true) {
    Column() {
      Text('密码').fontSize(11).fontColor(this.pal().text2).fontFamily(this.font()).margin({ bottom: 4 })
      TextInput({ placeholder: enabled ? '输入密码' : '已使用 Windows 凭据', text: this.sheetPwd })
        .type(InputType.Password).height(38).backgroundColor(this.pal().surface).borderRadius(8)
        .fontColor(this.pal().text).placeholderColor(this.pal().text3).fontFamily(this.font())
        .fontSize(13).padding({ left: 10, right: 10 }).enabled(enabled)
        .opacity(enabled ? 1.0 : 0.55)
        .onChange((v: string): void => { this.sheetPwd = v; })
    }.margin({ bottom: 8 })
  }

  @Builder rdpAuthModeButton(label: string, mode: RdpAuthMode, marginLeft: number = 0) {
    Button(label).layoutWeight(1).height(34).borderRadius(8).margin({ left: marginLeft })
      .backgroundColor(this.sheetRdpAuthMode === mode ? this.accentColor : this.pal().surface)
      .fontColor(this.sheetRdpAuthMode === mode ? '#FFFFFF' : this.pal().text2)
      .fontSize(11)
      .onClick((): void => {
        this.sheetRdpAuthMode = mode;
        this.sheetErr = '';
        if (mode !== 'password') {
          this.selectedRdpCredentialId = '';
          this.sheetPwd = '';
        }
        if (mode !== 'blank_password') { this.sheetRdpBlankPasswordConfirmed = false; }
        if (mode !== 'restricted_admin') { this.sheetRdpRestrictedAdminHash = ''; }
      })
  }

  @Builder rdpRestrictedAdminHashRow() {
    Column() {
      Text('NTLM Hash').fontSize(11).fontColor(this.pal().text2).fontFamily(this.font()).margin({ bottom: 4 })
      TextInput({ placeholder: '32 位十六进制 Hash', text: this.sheetRdpRestrictedAdminHash })
        .type(InputType.Password).height(38).backgroundColor(this.pal().surface).borderRadius(8)
        .fontColor(this.pal().text).placeholderColor(this.pal().text3).fontFamily(this.font())
        .fontSize(13).padding({ left: 10, right: 10 })
        .onChange((value: string): void => { this.sheetRdpRestrictedAdminHash = value; })
    }.margin({ bottom: 8 })
  }

  @Builder rdpAuthenticationModeSection() {
    Column() {
      Text('连接认证').fontSize(11).fontColor(this.pal().text2).fontFamily(this.font()).margin({ bottom: 4 })
      Row() {
        this.rdpAuthModeButton('密码/凭据', 'password')
        this.rdpAuthModeButton('空密码账户', 'blank_password', 6)
        this.rdpAuthModeButton('Restricted Admin', 'restricted_admin', 6)
      }.width('100%').margin({ bottom: 8 })

      if (this.sheetRdpAuthMode === 'blank_password') {
        Text('密码为空。目标 Windows 必须允许空密码本地账户通过远程桌面登录；应用不会修改目标机策略。')
          .fontSize(11).fontColor(this.pal().text3).fontFamily(this.font()).margin({ bottom: 6 })
        Row({ space: 6 }) {
          Checkbox({ name: 'confirmClassicRdpBlankPassword', group: 'classicRdpAuth' })
            .select(this.sheetRdpBlankPasswordConfirmed).selectedColor(this.accentColor)
            .onChange((value: boolean): void => { this.sheetRdpBlankPasswordConfirmed = value; })
          Text('我确认目标是允许远程登录的空密码本地账户。')
            .fontSize(11).fontColor(this.pal().text2).fontFamily(this.font()).layoutWeight(1)
        }.width('100%').margin({ bottom: 8 })
      } else if (this.sheetRdpAuthMode === 'restricted_admin') {
        Text('凭据来源：账户 NTLM Hash（必填）').fontSize(11).fontColor(this.pal().text2)
          .fontFamily(this.font()).margin({ bottom: 4 })
        this.rdpRestrictedAdminHashRow()
        if (this.editingHostId !== '' && this.sheetRdpRestrictedAdminHash === '') {
          Text('未输入新 Hash 时，仅在目标地址、有效用户名/域和身份模式未改变时保留本机密文。')
            .fontSize(10).fontColor(this.pal().text3).fontFamily(this.font()).margin({ bottom: 6 })
        }
        Text('目标机需开启 Restricted Admin（DisableRestrictedAdmin=0）。应用不会从“空密码”推导 Hash；Hash 仅加密保存在本机，不会云同步。')
          .fontSize(11).fontColor(this.pal().text3).fontFamily(this.font()).margin({ bottom: 8 })
      }
    }.width('100%')
  }

  @Builder rdpCredentialSection() {
    Column() {
      Row() {
        Text('Windows 凭据').fontSize(11).fontColor(this.pal().text2).fontFamily(this.font())
        Blank()
        Text('管理').fontSize(11).fontColor(this.accentColor).fontFamily(this.font())
          .onClick(() => {
            this.openRdpCredentialManager();
          })
      }.width('100%').margin({ bottom: 4 })

      Column() {
        Row() {
          Text('使用主机内填写的账号').fontSize(13).fontColor(this.pal().text).fontFamily(this.font())
          Blank()
          if (this.selectedRdpCredentialId === '') {
            SymbolGlyph($r('sys.symbol.checkmark')).fontSize(18).fontColor([this.accentColor])
          }
        }.width('100%').padding({ left: 10, right: 10, top: 8, bottom: 8 })
        .backgroundColor(this.selectedRdpCredentialId === '' ? this.pal().surface : Color.Transparent)
        .borderRadius(8)
        .onClick(() => { this.selectRdpCredential(''); })

        ForEach(this.rdpCredentials, (credential: RdpCredential) => {
          Row() {
            Column() {
              Text(credential.displayName()).fontSize(13).fontColor(this.pal().text).fontFamily(this.font())
              Text(credential.username).fontSize(9).fontColor(this.pal().text3).fontFamily(this.font())
                .margin({ top: 2 })
            }.alignItems(HorizontalAlign.Start).layoutWeight(1)
            if (this.selectedRdpCredentialId === credential.id) {
              SymbolGlyph($r('sys.symbol.checkmark')).fontSize(18).fontColor([this.accentColor])
            }
          }.width('100%').padding({ left: 10, right: 10, top: 8, bottom: 8 })
          .backgroundColor(this.selectedRdpCredentialId === credential.id ? this.pal().surface : Color.Transparent)
          .borderRadius(8)
          .onClick(() => {
            this.selectRdpCredential(credential.id);
          })
        }, (credential: RdpCredential) => credential.id + ':' + this.hostViewRevision.toString())
      }.width('100%').backgroundColor(this.pal().surface).borderRadius(8).padding(6).margin({ bottom: 8 })

      if (this.selectedRdpCredentialId !== '') {
        Row() {
          SymbolGlyph($r('sys.symbol.lock_fill')).fontSize(13).fontColor([this.accentColor])
          Text('已使用保存的 Windows 凭据，用户名和密码由凭据提供')
            .fontSize(11).fontColor(this.pal().text3).fontFamily(this.font()).margin({ left: 4 })
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        }.width('100%').margin({ bottom: 8 })
      }
    }.width('100%')
  }

  @Builder rdpCredentialSheet() {
    Column() {
      Row() {
        Text('Windows 凭据').fontSize(19).fontWeight(FontWeight.Bold)
          .fontColor(this.pal().text).fontFamily(this.font())
        Blank()
        Text('完成').fontSize(13).fontColor(this.accentColor).fontWeight(FontWeight.Medium)
          .fontFamily(this.font()).onClick(() => { this.closeSettingsLeafSheet(); })
      }.width('100%').padding({ left: 24, right: 24, top: 22 }).margin({ bottom: 14 })

      if (this.rdpCredentials.length === 0) {
        Text('还没有保存的 Windows 登录凭据。可以添加邮箱账号、DOMAIN\\user 或本地用户名。')
          .fontSize(13).fontColor(this.pal().text3).fontFamily(this.font())
          .textAlign(TextAlign.Center)
          .padding({ left: 28, right: 28, top: 18, bottom: 18 })
      } else {
        List({ space: 8 }) {
          ForEach(this.rdpCredentials, (credential: RdpCredential) => {
            ListItem() {
              Row() {
                Row() {
                  SymbolGlyph($r('sys.symbol.key_fill')).fontSize(18).fontColor([this.accentColor])
                }.width(36).height(36).borderRadius(10).backgroundColor(this.pal().surface)
                .justifyContent(FlexAlign.Center).alignItems(VerticalAlign.Center)
                Column() {
                  Text(credential.displayName()).fontSize(14).fontWeight(FontWeight.Medium)
                    .fontColor(this.pal().text).fontFamily(this.font()).maxLines(1)
                  Text(credential.username).fontSize(11).fontColor(this.pal().text3)
                    .fontFamily(this.font()).maxLines(1).margin({ top: 2 })
                }.alignItems(HorizontalAlign.Start).layoutWeight(1).margin({ left: 10 })
                Text('编辑').fontSize(12).fontColor(this.accentColor).fontWeight(FontWeight.Medium)
                  .padding({ left: 8, right: 8, top: 5, bottom: 5 }).borderRadius(8)
                  .backgroundColor(this.pal().surface)
                  .onClick((): void => { this.editRdpCredential(credential); })
                Text('删除').fontSize(12).fontColor(this.pal().danger).fontWeight(FontWeight.Medium)
                  .padding({ left: 8, right: 8, top: 5, bottom: 5 }).borderRadius(8)
                  .margin({ left: 6 }).backgroundColor(this.pal().surface)
                  .onClick((): void => { this.confirmDeleteRdpCredential(credential); })
              }
              .width('100%').padding({ left: 14, right: 14, top: 10, bottom: 10 })
              .borderRadius(12).backgroundColor(this.pal().card)
              .border({ width: 0.5, color: this.pal().cardBorder, style: BorderStyle.Solid })
            }
          }, (credential: RdpCredential) => credential.id + ':' + this.hostViewRevision.toString())
        }.height(this.rdpCredentials.length > 2 ? 220 : (this.rdpCredentials.length * 66 + 10))
        .width('100%').padding({ left: 24, right: 24 }).margin({ bottom: 14 })
      }

      Column() {
        Button('添加 Windows 凭据')
          .height(40).width('100%').fontSize(13).fontWeight(FontWeight.Medium)
          .backgroundColor(this.accentColor).fontColor('#FFFFFF').borderRadius(10)
          .onClick((): void => {
            this.resetRdpCredentialEditor();
            this.rdpCredentialEditorReturnToManager = true;
            this.openSettingsLeafSheet(SETTINGS_SHEET_RDP_CREDENTIAL_EDITOR);
          })
      }.width('100%').padding({ left: 24, right: 24, bottom: 28 })
    }
    .width('100%')
    .backgroundColor(this.pal().bg)
    .backgroundBlurStyle(BlurStyle.Regular)
    .shadow(this.breakpoint === 'sm'
      ? { radius: 0, color: 'rgba(0,0,0,0)', offsetY: 0 } as ShadowOptions
      : { radius: 24, color: 'rgba(0,0,0,0.12)', offsetY: 6 } as ShadowOptions)
    .border(this.breakpoint === 'sm'
      ? { width: 0, color: Color.Transparent, style: BorderStyle.Solid }
      : { width: 0.5, color: this.pal().cardBorder, style: BorderStyle.Solid })
    .borderRadius(this.breakpoint === 'sm' ? { topLeft: 20, topRight: 20, bottomLeft: 0, bottomRight: 0 } : 20)
    .constraintSize({ maxWidth: 560 })
  }

  @Builder rdpCredentialEditorSheet() {
    Column() {
      Row() {
        Text(this.rdpCredEditId === '' ? '添加凭据' : '编辑凭据')
          .fontSize(19).fontWeight(FontWeight.Bold).fontColor(this.pal().text).fontFamily(this.font())
        Blank()
        Text('取消').fontSize(13).fontColor(this.pal().text2).fontWeight(FontWeight.Medium)
          .fontFamily(this.font()).onClick((): void => {
            this.closeSettingsLeafSheet();
            this.rdpCredentialEditorReturnToManager = false;
          })
      }.width('100%').padding({ left: 24, right: 24, top: 22 }).margin({ bottom: 14 })

      Column() {
        this.rdpCredentialFieldRow('名称', '例如：个人 Microsoft 账户', this.rdpCredLabel,
          (v: string): void => { this.rdpCredLabel = v; })
        this.rdpCredentialFieldRow('用户名 / 邮箱', 'name@example.com 或 DOMAIN\\user', this.rdpCredUsername,
          (v: string): void => { this.rdpCredUsername = v; })
        Column() {
          Text('密码').fontSize(11).fontColor(this.pal().text2).fontFamily(this.font()).margin({ bottom: 4 })
          TextInput({ placeholder: 'Windows 登录密码', text: this.rdpCredPassword })
            .type(InputType.Password).height(38).backgroundColor(this.pal().surface).borderRadius(8)
            .fontColor(this.pal().text).placeholderColor(this.pal().text3).fontFamily(this.font())
            .fontSize(13).padding({ left: 10, right: 10 })
            .onChange((v: string): void => { this.rdpCredPassword = v; })
        }.margin({ bottom: 12 })
        Row() {
          Button(this.rdpCredEditId === '' ? '保存凭据' : '更新凭据')
            .height(40).layoutWeight(1).fontSize(13).fontWeight(FontWeight.Medium)
            .backgroundColor(this.accentColor).fontColor('#FFFFFF').borderRadius(10)
            .onClick((): void => { this.saveRdpCredentialFromSettings(); })
          Button('清空')
            .height(40).width(82).fontSize(13).backgroundColor(this.pal().surface)
            .fontColor(this.pal().text2).borderRadius(10).margin({ left: 10 })
            .onClick((): void => { this.resetRdpCredentialEditor(); })
        }.width('100%')
      }.width('100%').padding({ left: 24, right: 24, bottom: 28 })
    }
    .id('rdpCredentialEditor-' + this.rdpCredEditorKey.toString())
    .width('100%')
    .backgroundColor(this.pal().bg)
    .backgroundBlurStyle(BlurStyle.Regular)
    .shadow(this.breakpoint === 'sm'
      ? { radius: 0, color: 'rgba(0,0,0,0)', offsetY: 0 } as ShadowOptions
      : { radius: 24, color: 'rgba(0,0,0,0.12)', offsetY: 6 } as ShadowOptions)
    .border(this.breakpoint === 'sm'
      ? { width: 0, color: Color.Transparent, style: BorderStyle.Solid }
      : { width: 0.5, color: this.pal().cardBorder, style: BorderStyle.Solid })
    .borderRadius(this.breakpoint === 'sm' ? { topLeft: 20, topRight: 20, bottomLeft: 0, bottomRight: 0 } : 20)
    .constraintSize({ maxWidth: 520 })
  }

  @Builder rdpCredentialFieldRow(label: string, placeholder: string, value: string, cb: (v: string) => void) {
    Column() {
      Text(label).fontSize(11).fontColor(this.pal().text2).fontFamily(this.font()).margin({ bottom: 4 })
      TextInput({ placeholder: placeholder, text: value }).height(38).backgroundColor(this.pal().surface).borderRadius(8)
        .fontColor(this.pal().text).placeholderColor(this.pal().text3).fontFamily(this.font())
        .fontSize(13).padding({ left: 10, right: 10 }).onChange(cb)
    }.margin({ bottom: 8 })
  }

  @Builder sshKeySection() {
    Column() {
      // 私钥认证开关
      Row() {
        Text('使用私钥认证').fontSize(13).fontColor(this.pal().text).fontFamily(this.font())
        Blank()
        Toggle({ type: ToggleType.Switch, isOn: this.sheetUseKey }).selectedColor(this.accentColor)
          .scale({ x: 0.88, y: 0.88 })
          .onChange((on: boolean) => { this.sheetUseKey = on; })
      }.width('100%').height(36).margin({ bottom: 6 })

      if (this.sheetUseKey) {
        // 从密钥库选择
        Button() {
          Row() {
            SymbolGlyph($r('sys.symbol.key_fill')).fontSize(16).fontColor([this.accentColor])
            Blank().width(4)
            Text('从密钥库选择').fontSize(12).fontColor(this.accentColor)
          }
        }
        .width('100%').height(36).borderRadius(8)
        .backgroundColor(this.pal().surface)
        .margin({ bottom: 10 })
        .onClick(() => { this.openSettingsLeafSheet(SETTINGS_SHEET_KEY_VAULT); })
        // 文件/粘贴 切换
        Row() {
          Text('文件').fontSize(12).fontColor(this.sheetKeyMode === 0 ? this.accentColor : this.pal().text3)
            .fontWeight(this.sheetKeyMode === 0 ? FontWeight.Medium : FontWeight.Normal)
            .padding({ left: 12, right: 12, top: 6, bottom: 6 }).borderRadius(8)
            .backgroundColor(this.sheetKeyMode === 0 ? this.pal().surface : Color.Transparent)
            .onClick(() => { this.switchSshKeyMode(0); })
          Text('粘贴').fontSize(12).fontColor(this.sheetKeyMode === 1 ? this.accentColor : this.pal().text3)
            .fontWeight(this.sheetKeyMode === 1 ? FontWeight.Medium : FontWeight.Normal)
            .padding({ left: 12, right: 12, top: 6, bottom: 6 }).borderRadius(8)
            .backgroundColor(this.sheetKeyMode === 1 ? this.pal().surface : Color.Transparent)
            .margin({ left: 8 }).onClick(() => { this.switchSshKeyMode(1); })
        }.width('100%').margin({ bottom: 10 })

        if (this.sheetKeyMode === 0) {
          Row() {
            Text(this.sheetKeyPath !== '' ? '已选择: ' + this.sheetKeyPath.split('/').pop() : '点击选择私钥文件')
              .fontSize(13).fontColor(this.sheetKeyPath !== '' ? this.pal().text : this.pal().text3)
              .fontFamily(this.font()).layoutWeight(1).maxLines(1)
          }.width('100%').height(36).borderRadius(8).backgroundColor(this.pal().surface)
            .padding({ left: 12, right: 12 }).onClick(() => { this.pickSshKey(); }).margin({ bottom: 8 })
        } else {
          TextInput({ placeholder: '粘贴私钥内容...', text: this.sheetKeyText })
            .height(80).backgroundColor(this.pal().surface).borderRadius(8)
            .fontColor(this.pal().text).placeholderColor(this.pal().text3)
            .fontFamily('monospace').fontSize(12)
            .padding({ left: 12, right: 12, top: 10, bottom: 10 })
            .onChange((v: string): void => {
              this.sheetKeyText = v;
              this.sheetKeyId = '';
              this.sheetKeyPath = '';
              this.sheetKeyPassphrase = '';
            })
            .margin({ bottom: 8 })
        }
      }

      // 代理开关
      Row() {
        Text('代理转发 (跳板机)').fontSize(13).fontColor(this.pal().text).fontFamily(this.font())
        Blank()
        Toggle({ type: ToggleType.Switch, isOn: this.sheetUseProxy }).selectedColor(this.accentColor)
          .scale({ x: 0.88, y: 0.88 })
          .onChange((on: boolean) => { this.sheetUseProxy = on; })
      }.width('100%').height(36).margin({ top: 6 })

      if (this.sheetUseProxy) {
        this.fieldRow('代理地址', 'gateway.example.com', this.sheetProxyHost, (v: string): void => { this.sheetProxyHost = v; })
        Row() {
          Column() {
            this.fieldRow('代理端口', '22', this.sheetProxyPort.toString(), (v: string): void => {
              const n: number = parseInt(v); this.sheetProxyPort = isNaN(n) ? 22 : n;
            })
          }.width('30%')
          Column() {
            this.fieldRow('代理用户', 'root', this.sheetProxyUser, (v: string): void => { this.sheetProxyUser = v; })
          }.width('60%').margin({ left: 12 })
        }.width('100%')
      }
    }.width('100%')
  }

  private switchSshKeyMode(mode: number): void {
    if (this.sheetKeyMode === mode) { return; }
    this.sheetKeyMode = mode;
    this.sheetKeyId = '';
    this.sheetKeyPassphrase = '';
    this.sheetKeyPath = '';
    this.sheetKeyText = '';
  }

  @Builder rustDeskProPreflightPanel() {
    Column({ space: 14 }) {
      Row() {
        Column({ space: 4 }) {
          Text('连接鉴权').fontSize(20).fontWeight(FontWeight.Bold).fontColor(this.pal().text)
          Text('鉴权成功后才会进入远程画面').fontSize(13).fontColor(this.pal().text2)
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        Button('取消').fontSize(14).backgroundColor(Color.Transparent).fontColor(this.accentColor)
          .enabled(this.rustDeskProPreflightState !== RustDeskProPreflightState.CONNECTING)
          .onClick((): void => { this.cancelRustDeskProPreflight(); })
      }.width('100%')

      Row({ space: 8 }) {
        Button('设备密码')
          .backgroundColor(this.rustDeskProAuthMode === 'password' ? this.accentColor : this.pal().surface)
          .fontColor(this.rustDeskProAuthMode === 'password' ? Color.White : this.pal().text)
          .enabled(this.rustDeskProPreflightState !== RustDeskProPreflightState.CONNECTING)
          .onClick((): void => { this.rustDeskProAuthMode = 'password'; this.rustDeskProPreflightError = ''; })
        if (!this.isCurrentRustDeskPreflightDirect()) {
          Button('请求远端批准')
            .backgroundColor(this.rustDeskProAuthMode === 'request_approval' ? this.accentColor : this.pal().surface)
            .fontColor(this.rustDeskProAuthMode === 'request_approval' ? Color.White : this.pal().text)
            .enabled(this.rustDeskProPreflightState !== RustDeskProPreflightState.CONNECTING)
            .onClick((): void => { this.rustDeskProAuthMode = 'request_approval'; this.rustDeskProPreflightError = ''; })
        }
      }.width('100%')

      if (this.rustDeskProAuthMode === 'password') {
        TextInput({ text: this.rustDeskProPassword, placeholder: '远程 RustDesk 设备密码' })
          .type(this.rustDeskProPasswordVisible ? InputType.Normal : InputType.Password)
          .showPasswordIcon(true)
          .enabled(this.rustDeskProPreflightState !== RustDeskProPreflightState.CONNECTING)
          .height(48).width('100%').backgroundColor(this.pal().surface).borderRadius(10)
          .onChange((value: string): void => { this.rustDeskProPassword = value; this.rustDeskProPreflightError = ''; })
        Text('密码类型').fontSize(12).fontColor(this.pal().text2)
          .margin({ top: 2, bottom: 5 })
        Row({ space: 8 }) {
          Button('一次性密码').layoutWeight(1).height(36).fontSize(12)
            .backgroundColor(this.rustDeskProPasswordMode === 0 ? this.accentColor : this.pal().surface)
            .fontColor(this.rustDeskProPasswordMode === 0 ? Color.White : this.pal().text2)
            .enabled(this.rustDeskProPreflightState !== RustDeskProPreflightState.CONNECTING)
            .onClick((): void => { this.rustDeskProPasswordMode = 0; })
          Button('永久密码').layoutWeight(1).height(36).fontSize(12)
            .backgroundColor(this.rustDeskProPasswordMode === 1 ? this.accentColor : this.pal().surface)
            .fontColor(this.rustDeskProPasswordMode === 1 ? Color.White : this.pal().text2)
            .enabled(this.rustDeskProPreflightState !== RustDeskProPreflightState.CONNECTING)
            .onClick((): void => { this.rustDeskProPasswordMode = 1; })
        }.width('100%').margin({ bottom: 6 })
        Text(this.rustDeskProPasswordMode === 0 ?
          '一次性密码过期后，下次连接需要重新输入。' :
          '永久密码由被控端 RustDesk 设置决定。')
          .fontSize(11).fontColor(this.pal().text3).width('100%').margin({ bottom: 8 })
        Row({ space: 8 }) {
          Checkbox({ name: 'rememberRustDeskProPassword', group: 'rustDeskProAuth' })
            .select(this.rustDeskProRememberPassword)
            .onChange((value: boolean): void => { this.rustDeskProRememberPassword = value; })
          Text('记住设备密码').fontSize(14).fontColor(this.pal().text2)
        }.width('100%')
      } else {
        Text('连接请求会发送到远端设备，请在对方设备上点击批准。')
          .fontSize(14).fontColor(this.pal().text2).width('100%')
      }

      if (this.rustDeskProPreflightError.length > 0) {
        Text(this.rustDeskProPreflightError).fontSize(13).fontColor('#D92D20').width('100%')
      }
      if (this.rustDeskProPreflightState === RustDeskProPreflightState.CONNECTING) {
        Row({ space: 10 }) {
          LoadingProgress().width(20).height(20).color(this.accentColor)
          Text(this.rustDeskProAuthMode === 'request_approval' ? '等待远端批准…' : '正在后台验证密码…')
            .fontSize(14).fontColor(this.pal().text2)
        }.width('100%')
      }
      Button(this.rustDeskProPreflightState === RustDeskProPreflightState.ERROR ? '重新连接' : '连接')
        .width('100%').height(46).backgroundColor(this.accentColor).fontColor(Color.White)
        .enabled(this.rustDeskProPreflightState !== RustDeskProPreflightState.CONNECTING)
        .onClick((): void => { this.confirmRustDeskProPreflight(); })
    }
    .width('100%').padding({ left: 20, right: 20, top: 18, bottom: 24 })
    .backgroundColor(this.pal().card)
  }

  private async importSshKeyToVault(): Promise<SshKey | null> {
    const result: SshKeyImportResult | null = await this.sshKeyImporter.pickAndInspect();
    if (result === null) { return null; }
    if (!result.ok || result.key === null) {
      promptAction.showToast({ message: result.error || '私钥文件不可用', duration: 2500 });
      return null;
    }

    let key: SshKey = result.key;
    if (key.fingerprint !== '') {
      const existing: SshKey | undefined = this.keyVault.getAllSshKeys().find(
        (item: SshKey): boolean => item.fingerprint === key.fingerprint);
      if (existing !== undefined) { key = existing; }
    }
    if (key.id === result.key.id && !this.keyVault.addSshKey(key)) {
      promptAction.showToast({ message: '私钥保存到密钥保险库失败', duration: 2500 });
      return null;
    }

    promptAction.showToast({ message: '私钥已保存到密钥保险库', duration: 1800 });
    return key;
  }

  private async pickSshKey(): Promise<void> {
    const key: SshKey | null = await this.importSshKeyToVault();
    if (key === null) { return; }

    this.sheetUseKey = true;
    this.sheetKeyPath = '';
    this.sheetKeyText = key.privateKey;
    this.sheetKeyId = key.id;
    this.sheetKeyPassphrase = '';
    this.sheetKeyMode = 0;
    this.sheetErr = '';
  }

  @Builder keyVaultContent() {
    KeyVaultPage({ keyVaultInnerTab: $keyVaultInnerTab, addTrigger: this.kvAddTrigger, hideTabBar: this.isDesktopDevice && this.breakpoint === 'xl' })
  }

  @Builder relayContent() {
    RustDeskRelayPage({ addTrigger: this.relayAddTrigger, hideTabBar: this.isDesktopDevice && this.breakpoint === 'xl' })
  }

  @Builder keyVaultSheet() {
    Column() {
      Text('选择 SSH 密钥').fontSize(18).fontWeight(FontWeight.Bold)
        .fontColor(this.pal().text).margin({ bottom: 16 }).width('100%')

      if (this.keyVault.getAllSshKeys().length === 0) {
        Text('密钥库为空，请先在密钥保险库中添加密钥')
          .fontSize(13).fontColor(this.pal().text3).textAlign(TextAlign.Center)
          .padding({ left: 24, right: 24, top: 20, bottom: 20 })
      }

      if (this.keyVault.getAllSshKeys().length > 0) {
        List({ space: 8 }) {
          ForEach(this.keyVault.getAllSshKeys(), (key: SshKey) => {
            ListItem() {
              Row() {
                Text(SshKey.typeLabel(key.keyType))
                  .fontSize(11).fontWeight(FontWeight.Bold).fontColor('#FFFFFF')
                  .width(36).height(36).borderRadius(10).backgroundColor(this.accentColor)
                  .textAlign(TextAlign.Center)
                Column() {
                  Text(key.label).fontSize(14).fontWeight(FontWeight.Medium)
                    .fontColor(this.pal().text).maxLines(1)
                  if (key.comment !== '') {
                    Text(key.comment).fontSize(11).fontColor(this.pal().text2).maxLines(1)
                  }
                }.alignItems(HorizontalAlign.Start).layoutWeight(1).margin({ left: 10 })
                Text(SshKey.typeLabel(key.keyType))
                  .fontSize(10).fontColor(this.accentColor).fontWeight(FontWeight.Medium)
                  .padding({ left: 6, right: 6, top: 2, bottom: 2 }).borderRadius(4)
                  .backgroundColor(this.pal().surface)
              }
              .width('100%').padding({ left: 14, right: 14, top: 10, bottom: 10 })
              .borderRadius(12).backgroundColor(this.pal().card)
              .border({ width: 0.5, color: this.pal().cardBorder, style: BorderStyle.Solid })
              .onClick(async () => {
                // 锁定密钥需要先鉴权
                if (key.locked) {
                  const r = await showLockGate(key.label, 'biometric');
                  if (!r.ok) {
                    const msg: string = lockGateErrorMessage(r);
                    if (msg !== '') { promptAction.showToast({ message: msg, duration: 2000 }); }
                    return;
                  }
                }
                // 加密私钥需要输入密码
                if (key.privateKeyEncrypted) {
                  const pass: string = await this.promptKeyPassphrase();
                  this.sheetKeyPassphrase = pass;
                } else {
                  this.sheetKeyPassphrase = '';
                }
                this.sheetKeyText = key.privateKey;
                this.sheetKeyId = key.id;
                this.sheetKeyPath = key.label;
                this.sheetKeyMode = 1;
                this.closeSettingsLeafSheet();
              })
            }
          }, (key: SshKey) => key.id + ':' + this.hostViewRevision.toString())
        }.height(260)
      }
    }
    .padding({ left: 24, right: 24, top: 24, bottom: 40 })
    .width('100%')
    .backgroundColor(this.pal().bg)
    .backgroundBlurStyle(BlurStyle.Regular)
    .shadow(this.breakpoint === 'sm'
      ? { radius: 0, color: 'rgba(0,0,0,0)', offsetY: 0 } as ShadowOptions
      : { radius: 24, color: 'rgba(0,0,0,0.12)', offsetY: 6 } as ShadowOptions)
    .border(this.breakpoint === 'sm'
      ? { width: 0, color: Color.Transparent, style: BorderStyle.Solid }
      : { width: 0.5, color: this.pal().cardBorder, style: BorderStyle.Solid })
    .borderRadius(this.breakpoint === 'sm' ? { topLeft: 20, topRight: 20, bottomLeft: 0, bottomRight: 0 } : 20)
  }

  // ==================== 光晕颜色选择 Sheet ====================
  @Builder haloColorSheet() {
    Column() {
      // 标题 + 预览 (与主题色面板一致)
      Row() {
        Text('光晕颜色').fontSize(19).fontWeight(FontWeight.Bold).fontColor(this.pal().text)
        Blank()
        Column()
          .width(36).height(36).borderRadius(12)
          .backgroundColor(this.haloColor)
          .border({ width: 2, color: this.pal().cardBorder, style: BorderStyle.Solid })
      }.width('100%').padding({ left: 24, right: 24, top: 20 }).margin({ bottom: 14 })

      Grid() {
        ForEach(this.haloPresets, (hex: string) => {
          GridItem() {
            Column().width(48).height(48).borderRadius(14)
              .backgroundColor(hex)
              .border({ width: this.haloColor === hex ? 3 : 0, color: this.pal().text })
              .onClick(() => {
                this.saveHaloColorForCurrentTheme(hex);
              })
          }
        })
      }
      .columnsTemplate('1fr 1fr 1fr 1fr').rowsGap(14).columnsGap(8)
      .width('100%').padding({ left: 24, right: 24 })
      Blank().height(24)
    }
    .width('100%').backgroundColor(this.pal().bg).borderRadius(20).constraintSize({ maxWidth: 720 })
  }

  // ==================== 终端字体颜色选择 Sheet ====================
  @Builder terminalFgColorSheet() {
    Column() {
      Row() {
        Text('终端字体颜色').fontSize(19).fontWeight(FontWeight.Bold).fontColor(this.pal().text)
        Blank()
        Column()
          .width(36).height(36).borderRadius(12)
          .backgroundColor(this.terminalFgColor)
          .border({ width: 2, color: this.pal().cardBorder, style: BorderStyle.Solid })
      }.width('100%').padding({ left: 24, right: 24, top: 20 }).margin({ bottom: 14 })

      Grid() {
        ForEach(this.terminalColorPresets, (hex: string) => {
          GridItem() {
            Column().width(48).height(48).borderRadius(14)
              .backgroundColor(hex)
              .border({ width: this.terminalFgColor === hex ? 3 : 0, color: this.pal().text })
              .onClick(() => {
                this.terminalFgColor = hex;
                AppStorage.setOrCreate('terminalFgColor', hex);
                this.persistPref('terminalFgColor', hex);
              })
          }
        })
      }
      .columnsTemplate('1fr 1fr 1fr 1fr').rowsGap(14).columnsGap(8)
      .width('100%').padding({ left: 24, right: 24 })
      Blank().height(24)
    }
    .width('100%').backgroundColor(this.pal().bg).borderRadius(20).constraintSize({ maxWidth: 720 })
  }

  // ==================== 终端字体大小选择 Sheet ====================
  @Builder terminalFontSizeSheet() {
    Column() {
      Row() {
        Text('终端字体大小').fontSize(19).fontWeight(FontWeight.Bold).fontColor(this.pal().text)
        Blank()
        Text(this.terminalFontSize + 'vp').fontSize(16).fontWeight(FontWeight.Bold)
          .fontColor(this.pal().primary)
      }.width('100%').padding({ left: 24, right: 24, top: 20 }).margin({ bottom: 14 })

      Grid() {
        ForEach(this.terminalFontSizes, (sz: number) => {
          GridItem() {
            Column() {
              Text(sz.toString())
                .fontSize(sz > 20 ? 10 : sz > 16 ? 11 : 12)
                .fontColor(this.terminalFontSize === sz ? '#FFFFFF' : this.pal().text)
              Text('vp').fontSize(9).fontColor(this.terminalFontSize === sz ? '#FFFFFF' : this.pal().text3)
            }
            .width(56).height(48).borderRadius(12).justifyContent(FlexAlign.Center)
            .backgroundColor(this.terminalFontSize === sz ? this.accentColor : this.pal().card)
            .border({ width: this.terminalFontSize === sz ? 0 : 1, color: this.pal().cardBorder })
            .onClick(() => {
              this.terminalFontSize = sz;
              AppStorage.setOrCreate('terminalFontSize', sz);
              this.persistPref('terminalFontSize', sz);
            })
          }
        })
      }
      .columnsTemplate('1fr 1fr 1fr 1fr').rowsGap(12).columnsGap(10)
      .width('100%').padding({ left: 24, right: 24 })
      Blank().height(24)
    }
    .width('100%').backgroundColor(this.pal().bg).borderRadius(20).constraintSize({ maxWidth: 720 })
  }

  @Builder wallPicker() {
    Column() {
      Text('选择壁纸').fontSize(19).fontWeight(FontWeight.Bold).fontColor(this.pal().text)
        .margin({ bottom: 20 }).width('100%').fontFamily(this.font())
      Grid() {
        ForEach(this.wallpaperItems, (item: WallpaperItem, idx: number) => {
          GridItem() {
            Column().width('100%').height(80).borderRadius(12).backgroundColor(item.color)
              .border({ width: this.wallpaperIdx === idx ? 3 : 0, color: this.accentColor })
              .onClick(() => { this.wallpaperIdx = idx; this.syncWallpaperColor(); this.persistPref('wallpaperIdx', idx); })
          }
        })
      }.columnsTemplate('1fr 1fr 1fr').rowsGap(12).columnsGap(12).width('100%').height(200)
    }.padding({ left: 24, right: 24, top: 24, bottom: 40 }).width('100%')
      .backgroundColor(this.pal().bg).borderRadius(this.breakpoint === 'sm' ? { topLeft: 20, topRight: 20, bottomLeft: 0, bottomRight: 0 } : 20)
  }

  @Builder statItem(label: string, count: number, color: string) {
    Column() {
      Text('' + count).fontSize(28).fontWeight(FontWeight.Bold).fontColor(color).fontFamily(this.font())
      Text(label).fontSize(12).fontColor(this.pal().text2).margin({ top: 4 }).fontFamily(this.font())
    }.alignItems(HorizontalAlign.Center)
  }

  @Builder accountSheet() {
    Column() {
      Text('账号管理').fontSize(19).fontWeight(FontWeight.Bold).fontColor(this.pal().text)
        .margin({ top: 24, bottom: 20 }).fontFamily(this.font())
      Column() {
        if (this.auth.isLoggedIn() && this.auth.getAvatarUrl() !== '') {
          Image(this.auth.getAvatarUrl())
            .width(64).height(64).borderRadius(32)
            .margin({ bottom: 8 })
        }
        Text(this.auth.isLoggedIn() ? this.auth.getDisplayName() : '未登录')
          .fontSize(AppTheme.fontSize.subtitle)
          .fontWeight(FontWeight.Bold).fontColor(this.pal().text)
        Text(this.auth.isLoggedIn() ? '华为账号已登录' : '离线模式 · 主机仅本地存储')
          .fontSize(12).fontColor(this.pal().text3).margin({ top: 4 })
      }.width('100%').alignItems(HorizontalAlign.Center).margin({ bottom: 24 })
      Row() {
        this.statItem('RDP', this.rdpCount, this.accentColor)
        this.statItem('RustDesk', this.rustdeskCount, this.pal().success)
        this.statItem('SSH', this.sshCount, this.pal().editColor)
      }.width('90%').justifyContent(FlexAlign.SpaceEvenly).margin({ bottom: 24 })
      Button('华为账号登录').width('86%').height(46).fontSize(13).fontWeight(FontWeight.Normal)
        .backgroundColor(this.accentColor).fontColor('#FFFFFF').borderRadius(12).margin({ bottom: 10 })
        .onClick(() => {
          this.closeSettingsLeafSheet();
          this.triggerSystemLogin();
        })
      Button('退出登录').width('86%').height(44).fontSize(14)
        .backgroundColor(this.pal().surface).fontColor(this.pal().danger).borderRadius(12)
        .onClick(() => { this.doLogout(); })
      Blank().height(32)
    }.width('100%')
    .backgroundColor(this.pal().bg).borderRadius(this.breakpoint === 'sm' ? { topLeft: 20, topRight: 20, bottomLeft: 0, bottomRight: 0 } : 20)
  }

  // ==================== Private ====================
  private rememberCurrentHostPort(): void {
    if (this.proto === 'rdp') {
      this.rdpPortVal = this.portVal;
    } else if (this.proto === 'ssh') {
      this.sshPortVal = this.portVal;
    }
  }

  private switchHostProtocol(protocol: string, defaultPort: number): void {
    this.rememberCurrentHostPort();
    this.proto = protocol;
    if (protocol === 'rdp') {
      this.portVal = this.rdpPortVal > 0 ? this.rdpPortVal : defaultPort;
    } else if (protocol === 'ssh') {
      this.portVal = this.sshPortVal > 0 ? this.sshPortVal : defaultPort;
    } else {
      // RustDesk 的主机端点由中继/直连配置决定，通用端口只作为表单过渡值。
      this.portVal = defaultPort;
    }
  }

  private resetForm(): void {
    this.editingHostId = '';
    this.label = ''; this.proto = 'rdp'; this.hostAddr = ''; this.portVal = 3389;
    this.rdpPortVal = 3389; this.sshPortVal = 22;
    this.username = ''; this.sheetPwd = ''; this.chn = ''; this.sheetErr = '';
    this.sheetPwdMode = 0;
    this.sheetRustdeskAuthMode = 'password';
    this.sheetRustdeskDirectEnabled = false;
    this.sheetRustdeskDirectHost = '';
    this.sheetRustdeskDirectPort = RUSTDESK_PEER_TCP_PORT;
    this.selectedRelayId = ''; this.selectedAccountId = '';
    this.selectedRdpCredentialId = '';
    this.sheetRdpAuthMode = 'password';
    this.sheetRdpRestrictedAdminSecretSource = 'ntlm_hash';
    this.sheetRdpRestrictedAdminHash = '';
    this.sheetRdpBlankPasswordConfirmed = false;
    this.sheetUseKey = false; this.sheetKeyPath = ''; this.sheetKeyText = '';
    this.sheetKeyId = ''; this.sheetKeyPassphrase = '';
    this.sheetKeyMode = 0; this.sheetUseProxy = false;
    this.sheetProxyHost = ''; this.sheetProxyPort = 22; this.sheetProxyUser = '';
  }

  private doAdd(): void {
    if (!shouldAcceptHostAddSave(this.addSheetClosing, this.pendingAddSheetConnectHostId)) {
      return;
    }
    const editingId: string = this.editingHostId;
    const existingHost: RemoteHost | undefined = editingId !== '' ? this.srv.getHost(editingId) : undefined;
    const h: RemoteHost = existingHost ? RemoteHost.fromJSON(existingHost.toJSON()) : new RemoteHost();
    if (editingId !== '') { h.id = editingId; }
    else { h.id = RemoteHost.generateId(); }
    h.label = this.label; h.protocol = this.proto;
    if (this.proto === 'rustdesk') {
      // RustDesk: 地址从选中继的ID服务器自动获取; 远程ID存入customHostname
      const selRelay: RustDeskRelayConfig | undefined =
        this.srv.getAllRelays().find((r: RustDeskRelayConfig) => r.id === this.selectedRelayId);
      const endpoint: RustDeskHostEndpoint = resolveRustDeskHostEndpoint(
        selRelay ? selRelay : null,
        this.hostAddr,
        this.sheetRustdeskDirectEnabled,
        this.sheetRustdeskDirectHost,
        this.sheetRustdeskDirectPort
      );
      h.host = endpoint.host;
      h.port = endpoint.port;
      h.username = '';  // RustDesk 不使用用户名
      h.customHostname = this.chn;  // 远程设备ID
      h.rustdeskRelayId = this.sheetRustdeskDirectEnabled ? '' : this.selectedRelayId;
      h.rustdeskAccountId = this.sheetRustdeskDirectEnabled ? '' : this.selectedAccountId;
      h.rustdeskPasswordMode = this.sheetPwdMode;
      h.rustdeskAuthMode = rustDeskAuthModeForConnection(
        this.sheetRustdeskDirectEnabled, this.sheetRustdeskAuthMode);
      h.rustdeskDirectEnabled = this.sheetRustdeskDirectEnabled;
      h.rustdeskDirectHost = this.sheetRustdeskDirectHost;
      h.rustdeskDirectPort = this.sheetRustdeskDirectPort > 0 ? this.sheetRustdeskDirectPort : RUSTDESK_PEER_TCP_PORT;
      h.rdpCredentialId = '';
      // Server Pro 管理主机的连接身份由地址簿控制；本地编辑只允许修改显示/凭据等字段。
      if (existingHost && existingHost.rustdeskProManaged && existingHost.sourceType === 'rustdesk_pro') {
        const preserveManagedRoute: boolean = shouldPreserveManagedRustDeskRoute(
          existingHost.rustdeskProManaged, existingHost.rustdeskDirectEnabled);
        h.protocol = existingHost.protocol;
        h.host = existingHost.host;
        h.port = existingHost.port;
        h.customHostname = existingHost.customHostname;
        h.rustdeskRelayId = existingHost.rustdeskRelayId;
        h.rustdeskAccountId = existingHost.rustdeskAccountId;
        h.rustdeskDirectEnabled = existingHost.rustdeskDirectEnabled;
        if (preserveManagedRoute) {
          h.rustdeskDirectHost = existingHost.rustdeskDirectHost;
          h.rustdeskDirectPort = existingHost.rustdeskDirectPort;
        }
        h.sourceType = existingHost.sourceType;
        h.rustdeskProAccountId = existingHost.rustdeskProAccountId;
        h.rustdeskProPeerId = existingHost.rustdeskProPeerId;
        h.rustdeskProPlatform = existingHost.rustdeskProPlatform;
        h.rustdeskProManaged = existingHost.rustdeskProManaged;
        h.rustdeskProLastSeenAt = existingHost.rustdeskProLastSeenAt;
        h.rustdeskProSyncError = existingHost.rustdeskProSyncError;
      }
    } else {
      h.host = this.hostAddr;
      h.port = this.proto === 'rdp' ? this.rdpPortVal : this.sshPortVal;
      this.portVal = h.port;
      h.customHostname = this.chn;
      if (this.proto === 'rdp') {
        h.rdpAuthMode = this.sheetRdpAuthMode;
        h.rdpRestrictedAdminSecretSource = this.sheetRdpRestrictedAdminSecretSource;
        if (this.sheetRdpAuthMode === 'password' && this.selectedRdpCredentialId !== '') {
          h.rdpCredentialId = this.selectedRdpCredentialId;
          h.username = '';
        } else {
          h.rdpCredentialId = '';
          h.username = this.username.trim();
        }
      } else {
        h.rdpCredentialId = '';
        h.username = this.username;
      }
    }
    if (this.proto === 'rdp') {
      h.password = this.sheetRdpAuthMode === 'password' && this.selectedRdpCredentialId === '' ?
        this.sheetPwd : '';
      h.normalizeRdpAuthentication();
    } else {
      h.password = this.sheetPwd;
    }
    if (this.proto === 'ssh') {
      h.sshUseKey = this.sheetUseKey; h.sshKeyPath = this.sheetKeyPath;
      h.sshKeyData = this.sheetKeyText;
      h.sshKeyId = this.sheetKeyId;
      h.sshKeyPassphrase = this.sheetKeyPassphrase;
      if (this.sheetUseProxy) {
        h.proxyHost = this.sheetProxyHost; h.proxyPort = this.sheetProxyPort;
        h.proxyUsername = this.sheetProxyUser;
      }
    }
    const e: string[] = h.getValidationErrors();
    if (e.length > 0) { this.sheetErr = e[0]; return; }
    if (h.protocol === 'rdp' && h.rdpAuthMode === 'blank_password' &&
      !this.sheetRdpBlankPasswordConfirmed) {
      this.sheetErr = '请确认目标是允许远程登录的空密码本地账户';
      return;
    }

    let restrictedAdminHashToPersist: string = '';
    let shouldPersistRestrictedAdminHash: boolean = false;
    if (h.protocol === 'rdp' && h.rdpAuthMode === 'restricted_admin' &&
      h.rdpRestrictedAdminSecretSource === 'ntlm_hash') {
      const hashEntered: boolean = this.sheetRdpRestrictedAdminHash.trim() !== '';
      restrictedAdminHashToPersist = normalizeRdpNtlmHash(this.sheetRdpRestrictedAdminHash);
      if (hashEntered && restrictedAdminHashToPersist === '') {
        this.sheetErr = 'NTLM Hash 必须是 32 位十六进制字符';
        return;
      }
      const authIdentityMode: number = AppStorage.get<number>('rdpAuthIdentityMode') ?? 1;
      const existingIdentity = existingHost === undefined ? undefined :
        normalizeRdpCredentialParts(existingHost.username, authIdentityMode);
      const nextIdentity = normalizeRdpCredentialParts(h.username, authIdentityMode);
      const canKeepExistingHash: boolean = !hashEntered && existingHost !== undefined &&
        existingHost.protocol === 'rdp' && existingHost.rdpAuthMode === 'restricted_admin' &&
        existingHost.rdpRestrictedAdminSecretSource === 'ntlm_hash' &&
        existingHost.host.trim().toLowerCase() === h.host.trim().toLowerCase() &&
        existingHost.port === h.port &&
        existingHost.customHostname.trim().toLowerCase() === h.customHostname.trim().toLowerCase() &&
        existingIdentity !== undefined &&
        existingIdentity.username.trim().toLowerCase() === nextIdentity.username.trim().toLowerCase() &&
        existingIdentity.domain.trim().toLowerCase() === nextIdentity.domain.trim().toLowerCase();
      if (!canKeepExistingHash && restrictedAdminHashToPersist === '') {
        this.sheetErr = '请重新输入该 Restricted Admin 主机的 NTLM Hash';
        return;
      }
      shouldPersistRestrictedAdminHash = restrictedAdminHashToPersist !== '';
    }
    // The local Restricted Admin secret is written before the existing
    // synchronous host-save path.  Keep a short-lived copy of a valid old
    // secret so a failed host-row transaction can restore the old binding
    // instead of deleting a credential that was already working.
    let previousRestrictedAdminHash: string = '';
    let hasPreviousRestrictedAdminHash: boolean = false;
    if (shouldPersistRestrictedAdminHash && existingHost !== undefined &&
      existingHost.protocol === 'rdp' && existingHost.rdpAuthMode === 'restricted_admin' &&
      existingHost.rdpRestrictedAdminSecretSource === 'ntlm_hash') {
      const previousSecret = CloudStore.getInstance().loadRdpRestrictedAdminHash(existingHost);
      if (previousSecret.status === 'ready') {
        previousRestrictedAdminHash = previousSecret.hash;
        hasPreviousRestrictedAdminHash = true;
      }
    }
    if (shouldPersistRestrictedAdminHash &&
      !CloudStore.getInstance().saveRdpRestrictedAdminHash(h, restrictedAdminHashToPersist)) {
      this.sheetErr = '无法加密保存 NTLM Hash，请先解锁本地凭据存储后重试';
      previousRestrictedAdminHash = '';
      return;
    }
    let saved: boolean = false;
    if (editingId !== '') {
      saved = this.srv.updateHost(h);
      if (saved) { this.editingHostId = ''; }
    } else {
      saved = this.srv.addHost(h);
    }
    if (!saved) {
      if (shouldPersistRestrictedAdminHash) {
        // The local secret was written before the host row so that the
        // existing save path can remain synchronous.  If the row fails,
        // discard the new secret. For an edit, restore the previous valid
        // secret because the host row should still contain the old binding.
        CloudStore.getInstance().clearRdpRestrictedAdminHash(h.id);
        if (hasPreviousRestrictedAdminHash && existingHost !== undefined &&
          !CloudStore.getInstance().saveRdpRestrictedAdminHash(
            existingHost, previousRestrictedAdminHash)) {
          hilog.error(0x0001, 'HostList',
            'failed to restore previous RDP Restricted Admin Hash after host save failure id=' + h.id);
        }
      }
      this.sheetErr = '保存主机失败，请稍后重试';
      hilog.error(0x0001, 'HostList', 'save host failed protocol=' + h.protocol + ' id=' + h.id);
      previousRestrictedAdminHash = '';
      return;
    }
    previousRestrictedAdminHash = '';
    hilog.info(0x0001, 'HostList', 'save host protocol=' + h.protocol +
      ' host=' + maskHost(h.host) + ':' + h.port +
      (h.protocol === 'rustdesk' && h.rustdeskDirectEnabled
        ? ' direct=' + maskHost(h.rustdeskDirectHost) + ':' + h.rustdeskDirectPort : '') +
      ' rdpCredentialHash=' + hashForLog(h.rdpCredentialId));
    this.requestAddSheetClose();
    this.rdpCredentials = this.srv.getAllRdpCredentials();
  }

  private saveCurrentRdpCredential(): void {
    if (this.username.trim() === '' || this.sheetPwd === '') {
      promptAction.showToast({ message: '先填写用户名和密码', duration: 1500 });
      return;
    }
    const credential = new RdpCredential();
    credential.id = RdpCredential.generateId();
    credential.username = this.username.trim();
    credential.password = this.sheetPwd;
    credential.label = credential.username.indexOf('@') > 0 ? credential.username : credential.username;
    this.srv.addRdpCredential(credential);
    this.rdpCredentials = this.srv.getAllRdpCredentials();
    this.selectRdpCredential(credential.id);
    promptAction.showToast({ message: 'Windows 凭据已保存', duration: 1500 });
  }

  private selectRdpCredential(id: string): void {
    this.selectedRdpCredentialId = id;
    if (id !== '') {
      this.username = '';
      this.sheetPwd = '';
    }
  }

  private resetRdpCredentialEditor(): void {
    this.rdpCredEditId = '';
    this.rdpCredLabel = '';
    this.rdpCredUsername = '';
    this.rdpCredPassword = '';
    this.rdpCredEditorKey++;
  }

  private openRdpCredentialManager(): void {
    this.resetRdpCredentialEditor();
    this.rdpCredentials = this.srv.getAllRdpCredentials();
    this.showRdpCredentialEditorSheet = false;
    this.openSettingsLeafSheet(SETTINGS_SHEET_RDP_CREDENTIALS);
  }

  private openRdpCredentialEditorFromManager(): void {
    this.rdpCredentialEditorReturnToManager = true;
    this.openSettingsLeafSheet(SETTINGS_SHEET_RDP_CREDENTIAL_EDITOR);
  }

  private editRdpCredential(credential: RdpCredential): void {
    this.rdpCredEditId = credential.id;
    this.rdpCredLabel = credential.label;
    this.rdpCredUsername = credential.username;
    this.rdpCredPassword = credential.password;
    this.rdpCredEditorKey++;
    this.openRdpCredentialEditorFromManager();
  }

  private saveRdpCredentialFromSettings(): void {
    const username: string = this.rdpCredUsername.trim();
    if (username === '' || this.rdpCredPassword === '') {
      promptAction.showToast({ message: '用户名和密码不能为空', duration: 1500 });
      return;
    }
    const credential = new RdpCredential();
    credential.id = this.rdpCredEditId !== '' ? this.rdpCredEditId : RdpCredential.generateId();
    credential.label = this.rdpCredLabel.trim();
    credential.username = username;
    credential.password = this.rdpCredPassword;
    if (this.rdpCredEditId === '') {
      this.srv.addRdpCredential(credential);
      this.selectRdpCredential(credential.id);
      promptAction.showToast({ message: 'Windows 凭据已保存', duration: 1500 });
    } else {
      this.srv.updateRdpCredential(credential);
      promptAction.showToast({ message: 'Windows 凭据已更新', duration: 1500 });
    }
    this.rdpCredentials = this.srv.getAllRdpCredentials();
    this.closeSettingsLeafSheet();
    this.resetRdpCredentialEditor();
    this.rdpCredentialEditorReturnToManager = false;
  }

  private confirmDeleteRdpCredential(credential: RdpCredential): void {
    promptAction.showDialog({
      title: '删除 Windows 凭据',
      message: '确定删除“' + credential.displayName() + '”吗？绑定它的 RDP 主机会改为使用主机内填写的账号。',
      buttons: [
        { text: '取消', color: this.pal().text2 },
        { text: '删除', color: this.pal().danger }
      ]
    }).then((result: Object): void => {
      const r: Record<string, number> = result as Record<string, number>;
      if (r['index'] === 1) {
        this.srv.removeRdpCredential(credential.id);
        if (this.selectedRdpCredentialId === credential.id) { this.selectedRdpCredentialId = ''; }
        if (this.rdpCredEditId === credential.id) { this.resetRdpCredentialEditor(); }
        this.rdpCredentials = this.srv.getAllRdpCredentials();
        promptAction.showToast({ message: 'Windows 凭据已删除', duration: 1500 });
      }
    });
  }

  private search(q: string): RemoteHost[] {
    return searchHosts(this.hosts, q);
  }

  private collectSshTrustedHosts(): RemoteHost[] {
    return this.srv.getAllHosts().filter((h: RemoteHost): boolean => {
      return h.protocol === 'ssh' &&
        (h.sshHostKeyTrustMode === 1 || h.sshHostKeyFingerprintSha256 !== '' || h.sshHostKeyRawBase64 !== '');
    });
  }

  private rustDeskHosts(): RemoteHost[] {
    return this.hosts.filter((host: RemoteHost): boolean => host.protocol === 'rustdesk');
  }

  private rustDeskAuthTrustLabel(host: RemoteHost): string {
    if (host.rustdeskAuthMode === 'request_approval' && !host.rustdeskDirectEnabled) { return '请求远端批准'; }
    if (host.password !== '') {
      return host.rustdeskPasswordMode === 1 ? '永久密码 · 已保存' : '一次性密码 · 已保存';
    }
    return '每次询问';
  }

  private toggleRustDeskAuthTrust(host: RemoteHost): void {
    const updated: RemoteHost = RemoteHost.fromJSON(host.toJSON());
    updated.rustdeskAuthMode = host.rustdeskAuthMode === 'request_approval' ? 'password' : 'request_approval';
    this.srv.updateHost(updated);
  }

  private clearRustDeskSavedPassword(host: RemoteHost): void {
    const updated: RemoteHost = RemoteHost.fromJSON(host.toJSON());
    updated.password = '';
    if (this.srv.updateHost(updated)) {
      promptAction.showToast({ message: '已清除保存的 RustDesk 密码', duration: 1500 });
    }
  }

  private clearRustDeskAuthTrust(host: RemoteHost): void {
    const updated: RemoteHost = RemoteHost.fromJSON(host.toJSON());
    updated.rustdeskAuthMode = 'password';
    updated.password = '';
    if (this.srv.updateHost(updated)) {
      promptAction.showToast({ message: '下次连接将重新询问认证方式', duration: 1500 });
    }
  }

  private refreshSshTrustedHostsView(): void {
    this.sshTrustedHostsView = this.collectSshTrustedHosts();
  }

  private collectRdpTrustedHosts(): RemoteHost[] {
    return this.srv.getAllHosts().filter((h: RemoteHost): boolean => {
      return h.protocol === 'rdp' &&
        h.rdpCertificateTrustMode === RDP_CERTIFICATE_EXPLICIT_TRUST_MODE &&
        h.rdpCertificateFingerprintSha256 !== '';
    });
  }

  private refreshRdpTrustedHostsView(): void {
    this.rdpTrustedHostsView = this.collectRdpTrustedHosts();
  }

  private formatTimestamp(ts: number): string {
    if (ts <= 0) { return '未知'; }
    const d: Date = new Date(ts);
    const pad = (n: number): string => n < 10 ? '0' + n.toString() : n.toString();
    return d.getFullYear().toString() + '-' + pad(d.getMonth() + 1) + '-' + pad(d.getDate()) +
      ' ' + pad(d.getHours()) + ':' + pad(d.getMinutes());
  }

  private forgetSshHostKey(host: RemoteHost): void {
    promptAction.showDialog({
      title: '忘记 SSH 指纹',
      message: '确定忘记“' + host.label + '”的已信任主机指纹吗？下次连接会重新要求确认。',
      buttons: [
        { text: '取消', color: this.pal().text2 },
        { text: '忘记', color: this.pal().danger }
      ]
    }).then((result: Object): void => {
      const r: Record<string, number> = result as Record<string, number>;
      if (r['index'] !== 1) { return; }
      const updated: RemoteHost = RemoteHost.fromJSON(host.toJSON());
      updated.sshHostKeyAlgorithm = '';
      updated.sshHostKeyFingerprintSha256 = '';
      updated.sshHostKeyRawBase64 = '';
      updated.sshHostKeyTrustedAt = 0;
      updated.sshHostKeyTrustMode = 0;
      this.srv.updateHost(updated);
      promptAction.showToast({ message: '已忘记 SSH 指纹', duration: 1500 });
    });
  }

  private async refreshSshHostKey(host: RemoteHost): Promise<void> {
    if (this.sshHostKeyBusyId !== '') { return; }
    if (host.locked) {
      const r = await showLockGate(host.label, 'biometric');
      if (!r.ok) {
        const msg: string = lockGateErrorMessage(r);
        if (msg !== '') { promptAction.showToast({ message: msg, duration: 2000 }); }
        return;
      }
    }
    this.sshHostKeyBusyId = host.id;
    try {
      const info: SshHostKeyInfo = this.loader.probeSshHostKey(host.host, host.port);
      if (!info.ok) {
        promptAction.showToast({
          message: '重新获取失败: ' + (info.errorMessage || '无法读取 SSH 主机指纹'),
          duration: 2500
        });
        return;
      }
      const updated: RemoteHost = RemoteHost.fromJSON(host.toJSON());
      updated.sshHostKeyAlgorithm = info.algorithm;
      updated.sshHostKeyFingerprintSha256 = info.fingerprintSha256;
      updated.sshHostKeyRawBase64 = info.rawBase64;
      updated.sshHostKeyTrustedAt = Date.now();
      updated.sshHostKeyTrustMode = 1;
      this.srv.updateHost(updated);
      promptAction.showToast({ message: 'SSH 指纹已更新', duration: 1500 });
    } catch (err) {
      promptAction.showToast({ message: '重新获取异常: ' + JSON.stringify(err), duration: 2500 });
    } finally {
      this.sshHostKeyBusyId = '';
    }
  }

  private forgetRdpCertificate(host: RemoteHost): void {
    promptAction.showDialog({
      title: '忘记 RDP 证书',
      message: '确定忘记“' + host.label + '”的已信任 RDP 证书吗？下次连接会重新要求确认。',
      buttons: [
        { text: '取消', color: this.pal().text2 },
        { text: '忘记', color: this.pal().danger }
      ]
    }).then((result: Object): void => {
      const r: Record<string, number> = result as Record<string, number>;
      if (r['index'] !== 1) { return; }
      const updated: RemoteHost = RemoteHost.fromJSON(host.toJSON());
      updated.rdpCertificateFingerprintSha256 = '';
      updated.rdpCertificateSubject = '';
      updated.rdpCertificateIssuer = '';
      updated.rdpCertificateCommonName = '';
      updated.rdpCertificateTrustedAt = 0;
      updated.rdpCertificateTrustMode = RDP_CERTIFICATE_UNKNOWN_TRUST_MODE;
      updated.rdpCertificateAllowUntrustedRoot = false;
      updated.rdpCertificateAllowHostMismatch = false;
      this.srv.updateHost(updated);
      promptAction.showToast({ message: '已忘记 RDP 证书', duration: 1500 });
    });
  }

  private async refreshRdpCertificate(host: RemoteHost): Promise<void> {
    if (this.rdpCertificateBusyId !== '') { return; }
    if (host.locked) {
      const r = await showLockGate(host.label, 'biometric');
      if (!r.ok) {
        const msg: string = lockGateErrorMessage(r);
        if (msg !== '') { promptAction.showToast({ message: msg, duration: 2000 }); }
        return;
      }
    }
    this.rdpCertificateBusyId = host.id;
    try {
      const info: RdpCertificateInfo = await this.loader.probeRdpCertificateAsync(
        host.host,
        host.port,
        host.customHostname
      );
      if (!info.ok || info.fingerprintSha256.length === 0) {
        promptAction.showToast({
          message: '重新获取失败: ' + (info.errorMessage || '无法读取 RDP 主机证书'),
          duration: 2500
        });
        return;
      }
      const updated: RemoteHost = RemoteHost.fromJSON(host.toJSON());
      updated.rdpCertificateFingerprintSha256 = info.fingerprintSha256;
      updated.rdpCertificateSubject = info.subject;
      updated.rdpCertificateIssuer = info.issuer;
      updated.rdpCertificateCommonName = info.commonName;
      updated.rdpCertificateTrustedAt = Date.now();
      updated.rdpCertificateTrustMode = RDP_CERTIFICATE_EXPLICIT_TRUST_MODE;
      updated.rdpCertificateAllowUntrustedRoot = !info.rootTrusted;
      updated.rdpCertificateAllowHostMismatch = info.hostMismatch;
      this.srv.updateHost(updated);
      promptAction.showToast({ message: 'RDP 证书已更新并信任', duration: 1500 });
    } catch (err) {
      promptAction.showToast({ message: '重新获取异常: ' + JSON.stringify(err), duration: 2500 });
    } finally {
      this.rdpCertificateBusyId = '';
    }
  }

  /** 刷新加密状态 (设置页卡片使用) */
  private refreshCryptoStatus(): void {
    try {
      const crypto = DataCrypto.getInstance();
      this.cryptoEnabled = crypto.isSetupComplete();
      this.cryptoUnlocked = crypto.isReady();
    } catch (_e) { /* ignore */ }
  }
}
