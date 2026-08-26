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
import {
  AccountSessionCoordinator,
  AccountTransitionResult
} from '../services/AccountSessionCoordinator';
import { DataCrypto } from '../services/DataCrypto';
import { CloudStore } from '../services/CloudStore';
import { AccountSessionLease, accountSessionLeaseEquals } from '../services/AccountScopePolicy';
import { cloudUserSettingIsSyncable } from '../services/CloudSyncSettingsPolicy';
import {
  VncTrustService,
  VncTrustView,
  VncTrustEndpoint,
  vncStoreIdentityFingerprint
} from '../services/VncTrustService';
import { VncHostService, VncHostView } from '../services/VncHostService';
import { VncGatewayService } from '../services/VncGatewayService';
import { VncGatewayView } from '../services/VncGatewayService';
import {
  VncHostValues, VncTransport, VncRepeaterMode, VncScalingMode, VncSecurityPolicy,
  VncTrustCertificateMetadata, validateVncHost
} from '../services/VncModelPolicy';
import {
  isVncHostProjection, projectVncHost, vncHostRecordIdFromUiId, vncHostUiId
} from '../services/VncHostListProjectionPolicy';
import { CloudSyncCoordinator } from '../services/CloudSyncCoordinator';
import { cloudFirstCompatibleTablesAfterOptionalFailure } from '../services/CloudSyncCoordinatorPolicy';
import { CloudSyncSelectionStore } from '../services/CloudSyncSelectionStore';
import { cloudSyncSelectableTables, effectiveCloudSyncTables } from '../services/CloudSyncSelectionPolicy';
import {
  moonlightForcedCloudSyncSelection
} from '../services/MoonlightCloudSyncSelectionPolicy';
import { LocalBackupDocument } from '../services/LocalBackupPolicy';
import { LocalBackupService } from '../services/LocalBackupService';
import { BackupRestorePreview } from '../services/BackupManifestV3';
import { LightSensingService } from '../services/LightSensingService';
import { SshKey } from '../model/SshKey';
import {
  RemoteHost,
  ConnectionHealth,
  LockType,
  RdpAuthMode,
  RdpRestrictedAdminSecretSource,
  normalizeRdpCredentialParts,
  normalizeRdpNtlmHash,
  normalizeRdpAuthMode,
  normalizeRdpEndpointMode,
  rdpRouteIdentity
} from '../model/RemoteHost';
import { RustDeskRelayConfig } from '../model/RustDeskRelayConfig';
import { RustDeskAccount } from '../model/RustDeskAccount';
import { TotpEntry } from '../model/TotpEntry';
import {
  MoonlightAddress,
  MoonlightAddressFamily,
  MoonlightHost,
  MoonlightHostType,
  MOONLIGHT_DEFAULT_HTTPS_PORT,
  moonlightAddressKey
} from '../model/MoonlightModels';
import { MOONLIGHT_CLOUD_TABLE } from '../model/MoonlightRecord';
import { RdpCredential } from '../model/RdpCredential';
import { RustDeskRelayPage } from './RustDeskRelayPage';
import { RustDeskProSyncService } from '../services/RustDeskProSyncService';
import { RustDeskProAccountState } from '../model/RustDeskProModels';
import { TotpEngine } from '../services/TotpEngine';
import {
  isRustDeskPeerTwoFactorManualCode,
  rustDeskPeerTwoFactorAutoSubmitError
} from '../services/RustDeskPeerTwoFactorPolicy';
import {
  RustDeskAuthDraft,
  RustDeskAuthDraftStore
} from '../services/RustDeskAuthDraftStore';
import { copyRustDeskPeerTwoFactorRuntime } from '../services/RustDeskPeerTwoFactorBindingStore';
import { AppConfig, AppTheme, Palette, buildDark, buildLight } from '../common/Theme';
import { LockGateResult, showLockGate, lockGateErrorMessage } from '../components/LockGate';
import { ColorPickerSheet } from '../components/ColorPickerSheet';
import { HostAddWizardSheet } from '../components/hostadd/HostAddWizardSheet';
import { RdpAddFlow } from '../components/hostadd/RdpAddFlow';
import { RustDeskAddFlow } from '../components/hostadd/RustDeskAddFlow';
import {
  MoonlightHostAddFlow,
  MoonlightLocalSaveResult,
  MoonlightPairingPreparation,
  MoonlightPairingCompletion
} from '../components/hostadd/MoonlightHostAddFlow';
import { MoonlightBrandIcon } from '../components/moonlight/MoonlightBrandIcon';
import { MoonlightSettingsSurface } from './MoonlightSettingsPage';
import {
  MoonlightAppCatalogSurface,
  MoonlightCatalogLaunchHandoff,
  presentMoonlightCatalogLaunchHandoff,
  rejectMoonlightCatalogLaunchHandoff
} from './MoonlightAppCatalogPage';
import {
  MoonlightSettingsSection,
  MoonlightCatalogItem,
  moonlightHostRouteParams
} from '../services/MoonlightUiPolicy';
import {
  MoonlightHostAddOperationKey,
  MoonlightHostAddState,
  MoonlightHostAddCandidate,
  MoonlightHostAddDiscoveryKey,
  MoonlightHostAddVerification,
  MoonlightHostAddCatalogSummary,
  parseMoonlightHostAddAddress
} from '../services/MoonlightHostAddFlowPolicy';
import {
  MoonlightLocalHostMutationResult,
  MoonlightLocalHostSaveResult,
  MoonlightLocalHostService
} from '../services/MoonlightLocalHostService';
import {
  MoonlightDeletionCommandResult,
  MoonlightDeletionPreview
} from '../services/MoonlightDeletionCommandService';
import { MoonlightDeletionRuntime } from '../services/MoonlightDeletionRuntime';
import { MoonlightSettingsLocalService } from '../services/MoonlightSettingsLocalService';
import {
  MoonlightHostDirectoryView,
  MoonlightHostLocalView,
  MoonlightLocalViewService
} from '../services/MoonlightLocalViewService';
import {
  MoonlightLanDiscoveryCandidate,
  MoonlightLanDiscoveryService
} from '../services/MoonlightLanDiscoveryService';
import {
  MoonlightHostOperationFence,
  MoonlightLanProbeService,
  cloneMoonlightHostOperationFence,
  createMoonlightHostOperationFence,
  moonlightHostOperationFenceEquals,
  moonlightVerificationUuidHint,
  moonlightVerificationMatchesFence
} from '../services/MoonlightLanProbeService';
import {
  MoonlightBridgeCapabilities,
  MoonlightHostContext,
  MoonlightHostService,
  MoonlightHostServiceResult
} from '../services/MoonlightHostService';
import {
  moonlightInstallationId,
  moonlightOwnerScopeFingerprint,
  moonlightPairingPin
} from '../services/MoonlightRuntimeSupport';
import { SshAddFlow } from '../components/hostadd/SshAddFlow';
import { VncAddFlow } from '../components/hostadd/VncAddFlow';
import {
  RustDeskHostAddDraft,
  RustDeskHostAddHandoff
} from '../services/RustDeskHostAddHandoff';
import { VncSessionCredentialHandoff } from '../services/VncSessionCredentialHandoff';
import {
  vncCredentialPreflightMessage,
  vncCredentialPreflightNeedsPrompt,
  VncCredentialPreflightState
} from '../services/VncCredentialPreflightPolicy';
import { VncSettingsService } from '../services/VncSettingsService';
import { VncSettingsSheet } from '../components/VncSettingsSheet';
import { VncCertificateTrustManagerSheet } from '../components/VncCertificateTrustManagerSheet';
import { buildVncTrustDirectory, VncTrustDirectoryItem } from '../services/VncTrustEndpointDirectory';
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
  rdpCertificateRouteIsCurrent,
  rdpCertificateErrorTitle,
  rdpGatewayTransportSummary,
  rdpCertificateLegacyProbeErrorCode,
  rdpCertificateLegacyProbeStage,
  rdpCertificateEffectiveRiskFlags,
  rdpCertificatePreflightAllowsRealConnection,
  rdpCertificateRoutePreflightAllowsRealConnection,
  rdpCertificateValidityState,
  rdpCertificateRiskSummary,
  rdpPreflightStatusLabel,
  rdpCertificateWarningMessage,
  shouldEnableStandardRdpSecurityOnce,
  shouldRouteRdpCertificateAfterSheetDisappear,
  shouldShowRdpCertificateProbeSheetBeforeProbe,
  shouldPersistRdpCertificateTrust
} from '../services/RdpCertificatePreflightPolicy';
import {
  ExtensionLoader,
  NativeDisconnectIdentity,
  NativeDisconnectSubmission
} from '../services/ExtensionLoader';
import { RemoteSessionWindowLauncher } from '../services/RemoteSessionWindowLauncher';
import {
  RemoteSessionWindowProtocol,
  RemoteSessionWindowRequest,
  RemoteSessionWindowTarget
} from '../services/RemoteSessionWindowPolicy';
import {
  RemoteSessionWindowAuthorizationKind,
  RemoteSessionWindowAuthorizationService
} from '../services/RemoteSessionWindowAuthorization';
import { RemoteSessionWindowNativeHandoff } from '../services/RemoteSessionWindowCoordinator';
import {
  RemoteSessionConnectionIntent,
  RemoteSessionConnectionIntentValue
} from '../services/RemoteSessionConnectionIntent';
import { SshKeyImportService, SshKeyImportResult } from '../services/SshKeyImportService';
import { SshXtermPrewarmSurface } from '../components/SshXtermSurface';
import { SshProxyEditor } from '../components/ssh/SshProxyEditor';
import { SshSettingsService } from '../services/SshSettingsService';
import { SshNotificationService } from '../services/ssh/notification/SshNotificationService';
import {
  SSH_WORKBENCH_V2_DEFAULT_ENABLED,
  SSH_WORKBENCH_V2_FLAG_KEY
} from '../services/ssh/workspace/SshWorkspaceCapabilityPolicy';
import { SshWorkspaceCapabilityStore } from
  '../services/ssh/workspace/SshWorkspaceCapabilityStore';
import { SshProxyProfileV1 } from '../services/SshProxyProfilePolicy';
import { SshProxyProfileStore } from '../services/SshProxyProfileStore';
import {
  SshProxyEditorBuildResult,
  SshProxyEditorKind,
  SshProxyEditorValue,
  applySshProxyProfileToLegacyHost,
  buildSshProxyProfile,
  defaultSshProxyEditorValue,
  defaultSshProxyHop,
  sshProxyEditorValueFromProfile
} from '../services/SshProxyEditorPolicy';
import {
  SshProxyRuntimePlan,
  resolveSshProxyRuntimePlan,
  sshProxyRuntimeHasStrictJumpBindings,
  sshProxyRuntimeNeedsTerminalSecrets
} from '../services/SshProxyRuntimePolicy';
import {
  nextRdpCertificateProbeGeneration,
  shouldApplyRdpCertificateProbeResult
} from '../services/RdpCertificateProbeLifecyclePolicy';
import {
  classifyVncCertificateProbeForOwner,
  isVncSha256Fingerprint,
  VncCertificatePreflightDecision,
  VncCertificatePreflightState,
  VncCertificateProbeView,
  VncCertificateTrustView
} from '../services/VncCertificatePreflightPolicy';
import {
  nextVncCertificateProbeGeneration,
  shouldApplyVncCertificateProbeResult,
  VncCertificateProbeIdentity
} from '../services/VncCertificateProbeLifecyclePolicy';
import {
  VncTlsGatewayInput,
  VncTlsEndpointResolution,
  resolveVncTlsEndpoint,
  vncTlsGatewayInput,
  vncTlsHostInput
} from '../services/VncTlsEndpointPolicy';
import { VncCertificateDecisionHandoff } from '../services/VncCertificateDecisionHandoff';
import { VncPlaintextDecisionHandoff } from '../services/VncPlaintextDecisionHandoff';
import { RustDeskLanDiscoveryService, DiscoveredRustDeskPeer } from '../services/RustDeskLanDiscoveryService';
import {
  DiscoveredRdpHost,
  rdpLanProbeRecognized,
  RdpLanDiscoveryService,
  RdpLanIdentityProbeResult,
  RdpLanScanStatus
} from '../services/RdpLanDiscoveryService';
import {
  lanHostNeedsAddressRefresh,
  lanHostRefreshCandidateMatches,
  LanHostRefreshCandidate,
  lanHostUsesLocalOnlyStorage
} from '../services/LanHostAddressPolicy';
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
  buildHostGroupCards,
  HOST_PRESENCE_PROBE_OFFLINE,
  HOST_PRESENCE_PROBE_PENDING,
  HOST_PRESENCE_PROBE_UNKNOWN,
  hostGroupColumnsForBreakpoint,
  hostGroupTitle,
  hostGroupTypeForHost,
  hostIdentifier,
  hostIdentifierLabel,
  hostPresenceLabel,
  hostPresenceLastSeenAt,
  hostPresenceState,
  shouldUseGroupedHostCards,
  HostGroupCardModel,
  HostGroupType,
  HostPresenceState
} from '../services/HostGroupCardPolicy';
import {
  resolveRustDeskHostEndpoint,
  rustDeskCardEndpoint,
  shouldAdoptRustDeskDirectPort,
  rustDeskAuthModeForConnection,
  normalizeRustDeskPort,
  rustDeskRelayFallbackPort,
  rustDeskConnectionError,
  RUSTDESK_PEER_TCP_PORT,
  RustDeskHostEndpoint
} from '../services/RustDeskHostConfigPolicy';
import { rustDeskRelayKeyModeForFfi } from '../services/RustDeskRelayKeyPolicy';
import { rustDeskConnectionStrategyForHost } from '../services/RustDeskConnectionStrategyPolicy';
import {
  sheetOpenDelayMsAfterDismiss,
  sshSftpSheetOpenDelayMs
} from '../services/SheetTransitionPolicy';
import { nextRemoteHostSheetGeneration } from '../services/RemoteHostSheetLifecyclePolicy';
import { shouldPreserveManagedRustDeskRoute } from '../services/RustDeskProSyncPolicy';
import {
  canUseRustDeskAdaptiveOrientation,
  isRustDeskMobilePlatform,
  normalizeRustDeskTargetDevice,
  RustDeskTargetDevice
} from '../services/RemoteOrientationPolicy';
import { resolveFabAddStyle } from '../services/FabAddStylePolicy';
import { shouldPrepareClassicVncEditor } from '../services/VncHostFlowPolicy';
import { resolveRustDeskBadges } from '../services/RustDeskCardBadgePolicy';
import { cloudSyncDetailSpec } from '../services/CloudSyncGuidancePolicy';
import {
  normalizeRemoteCursorStyle
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
  SETTINGS_SHEET_DIAGNOSTIC_LOG,
  SETTINGS_SHEET_FEEDBACK,
  SETTINGS_SHEET_HALO_COLOR,
  SETTINGS_SHEET_KEY_VAULT,
  SETTINGS_SHEET_NONE,
  SETTINGS_SHEET_POPUP,
  SETTINGS_SHEET_RDP_CREDENTIAL_EDITOR,
  SETTINGS_SHEET_RDP_CREDENTIALS,
  SETTINGS_SHEET_TERMINAL_FG_COLOR,
  SETTINGS_SHEET_TERMINAL_FONT_SIZE,
  SETTINGS_SHEET_TERMINAL_LINE_SPACING,
  SETTINGS_SHEET_MOONLIGHT_VIDEO,
  SETTINGS_SHEET_MOONLIGHT_AUDIO,
  SETTINGS_SHEET_MOONLIGHT_INPUT,
  SETTINGS_SHEET_MOONLIGHT_NETWORK_SECURITY,
  SETTINGS_SHEET_MOONLIGHT_DIAGNOSTICS,
  SETTINGS_SHEET_MOONLIGHT_TRUST,
  SETTINGS_SHEET_MOONLIGHT_DATA,
  SETTINGS_SHEET_VNC_CLIPBOARD,
  SETTINGS_SHEET_VNC_CONNECTION,
  SETTINGS_SHEET_VNC_DISPLAY,
  SETTINGS_SHEET_VNC_GATEWAY,
  SETTINGS_SHEET_VNC_HOSTS,
  SETTINGS_SHEET_VNC_INPUT,
  SETTINGS_SHEET_VNC_PERFORMANCE,
  SETTINGS_SHEET_VNC_SECURITY,
  SETTINGS_SHEET_VNC_TIMEOUT,
  SETTINGS_SHEET_VNC_TRUST,
  SETTINGS_SHEET_VIRTUAL_KEYBOARD,
  SETTINGS_SHEET_VIRTUAL_KEYBOARD_BEHAVIOR,
  SETTINGS_SHEET_VIRTUAL_KEYBOARD_CUSTOM,
  SETTINGS_SHEET_VIRTUAL_KEYBOARD_FUNCTIONS,
  SETTINGS_SHEET_VIRTUAL_KEYBOARD_SHORTCUTS,
  SETTINGS_SHEET_WALLPAPER,
  SETTINGS_PANEL_DISMISS_TO_LEAF_OPEN_MS,
  MoonlightSettingsRouteSpec,
  VirtualKeyboardSettingsSection,
  VirtualKeyboardSettingsRouteSpec,
  diagnosticLogSettingsLeafSheetHeight,
  isVirtualKeyboardSettingsMode,
  moonlightSettingsLeafSheetHeight,
  moonlightSettingsRouteSpec,
  settingsLeafSheetUsesSystemCloseButton,
  settingsLeafOpenDelayMs,
  virtualKeyboardSettingsRouteSpec,
  vncSettingsLeafSheetHeight
} from '../services/SettingsSheetRoutePolicy';
import { protocolIcon } from '../services/ProtocolIconPolicy';
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
  SETTINGS_SECTION_VIRTUAL_KEYBOARD,
  SETTINGS_SECTION_HOME,
  SETTINGS_SECTION_NONE,
  SETTINGS_SECTION_MOONLIGHT,
  SETTINGS_SECTION_RDP,
  SETTINGS_SECTION_RUSTDESK,
  SETTINGS_SECTION_SSH,
  SETTINGS_SECTION_VNC,
  SETTINGS_SECTION_SECURITY,
  SETTINGS_SECTION_TUTORIAL,
  SETTINGS_VNC_ACTION_ROW_COUNT,
  SETTINGS_MOONLIGHT_ACTION_ROW_COUNT,
  SettingsFeedbackLaunchAttempt,
  settingsFeedbackLaunchAttempts,
  settingsFeedbackMailPanelParams,
  settingsNextExpandedSection,
  settingsRatingUriCandidates,
  settingsRatingWantAction,
  settingsMoonlightExpandedMaxHeight,
  settingsVncExpandedMaxHeight
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
  PC_SESSION_TOP_BAR_HIDDEN_KEY,
  REMOTE_SESSION_CONTROL_BAR_HIDDEN_MOONLIGHT_KEY,
  REMOTE_SESSION_CONTROL_BAR_HIDDEN_RDP_KEY,
  REMOTE_SESSION_CONTROL_BAR_HIDDEN_RUSTDESK_KEY,
  REMOTE_SESSION_CONTROL_BAR_HIDDEN_VNC_KEY,
  RemoteSessionControlBarVisibility,
  remoteSessionControlBarHidden,
  remoteSessionControlBarSelectionSummary,
  resolveRemoteSessionControlBarVisibility
} from '../services/RemoteSessionTopBarPolicy';
import {
  resolveCanvasGestureZoomPreference
} from '../services/RemoteCanvasZoomPreferencePolicy';
import {
  PERSONALIZATION_DEFAULTS_FRESH_INSTALL_KEY,
  PersonalizationDefaults,
  personalizationDefaults
} from '../services/PersonalizationDefaultsPolicy';
import {
  HOST_CARD_SENSITIVE_INFO_HIDDEN_KEY,
  hostCardDisplayLabel,
  hostCardSensitiveValue,
  shouldHideHostCardSensitiveInfo
} from '../services/HostCardPrivacyPolicy';
import {
  buildUnifiedHostCardRefs,
  mergeVisibleHostOrder,
  moonlightHostCardKey as unifiedMoonlightHostCardKey,
  moonlightHostIdFromCardKey,
  moveUnifiedHostCard,
  remoteHostCardKey,
  remoteHostIdFromCardKey,
  UnifiedHostCardRef
} from '../services/UnifiedHostCardPolicy';
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
import { DiagnosticCaptureSettingsSheet } from '../components/DiagnosticCaptureSettingsSheet';
import { FeedbackSettingsSheet } from '../components/FeedbackSettingsSheet';
import { VirtualKeyboardSettingsSheet } from '../components/VirtualKeyboardSettingsSheet';
import {
  VncCertificateInfo,
  RdpCertificateInfo,
  RdpCertificateRecord,
  RdpPreflightRequest,
  RdpPreflightResult,
  RustDeskPresenceResult,
  SshHostKeyInfo,
  SshPrivateKeyInfo,
  SshPublicKeyInstallResult,
  SshProxyConfig
} from '../types/rdpnapi';
import { SessionConfig } from '../types/rdpnapi';
import {
  ActiveRemoteSessionRegistry,
  ActiveRemoteSessionRecord,
  ActiveRemoteSessionTermination
} from '../services/ActiveRemoteSessionRegistry';
import { MoonlightSessionCoordinator } from '../services/MoonlightSessionCoordinator';
import { RemoteProtocol } from '../services/RemoteSessionState';
import {
  nativeDisconnectStateIsFailed,
  nextRemoteSessionHandoffGeneration,
  remoteSessionExactDisconnectIdentityEquals,
  remoteSessionHandoffFailureOwnsSession,
  RemoteSessionExactDisconnectCallbackPort,
  RemoteSessionExactDisconnectIdentity,
  RemoteSessionExactDisconnectSubmission,
  submitRemoteSessionExactDisconnectWithRetry
} from '../services/RemoteSessionTerminationPolicy';
import {
  RustDeskProPreflightState,
  rustDeskProPeerIdForConnection,
  shouldOpenRustDeskProPreflight,
  classifyRustDeskProNativeError,
  rustDeskProAccountIdForConnection,
  rustDeskProNativeErrorMessage,
  canInvalidateRustDeskProSession,
  rustDeskNativeErrorDetail,
  RustDeskProNativeErrorKind
} from '../services/RustDeskProConnectionPreflightPolicy';
import {
  RustDeskControlPlaneProfile,
  RUSTDESK_CONTROL_PLANE_DEFAULT
} from '../services/RustDeskControlPlanePolicy';
import {
  resolveRustDeskConnectionContext,
  RustDeskConnectionContext
} from '../services/RustDeskConnectionContextPolicy';
import {
  nextConnectionAttemptGeneration,
  shouldBeginConnectionAttempt,
  shouldApplyConnectionAttempt
} from '../services/ConnectionAttemptPolicy';
import {
  createHostAddPostSaveHandoff,
  emptyHostAddPostSaveHandoff,
  HostAddPostSaveHandoff,
  hostAddPostSaveHandoffIsPending,
  pendingHostIdForHostAddSave,
  shouldAcceptHostAddPostSaveHandoff,
  shouldAcceptHostAddSave,
  shouldCloseHostAddAfterCommittedSave,
  shouldStartHostAddConnectionAfterDisappear,
  shouldStartHostAddPostSaveAfterDisappear
} from '../services/HostAddConnectionHandoffPolicy';
import { motion } from '@kit.MultimodalAwarenessKit';
import { HostDataSource } from '../datasources/DataSources';
import { hashForLog, maskHost } from '../utils/SafeLogger';
import { util } from '@kit.ArkTS';

interface WallpaperItem { color: string; uri: string; }
interface AccountInfo { name: string; rdpCount: number; rustdeskCount: number; sshCount: number; }
interface SshKeyMaterial { privateKey: string; encryptedHint: boolean; }
interface RustDeskTwoFactorEntryOption {
  id: string;
  label: string;
  detail: string;
  locked: boolean;
}

interface HostPresenceOverride {
  state: HostPresenceState;
  latencyMs: number;
  observedAt: number;
}

interface RdpCertificateCredentialParts {
  username: string;
  password: string;
  domain: string;
}

const ENV_COLOR_MODE_UNKNOWN = -1;
const ENV_COLOR_MODE_LIGHT = 0;
const ENV_COLOR_MODE_DARK = 1;
const DYNAMIC_LAN_ADDRESS_FRESHNESS_MS: number = 5 * 60 * 1000;
const DYNAMIC_LAN_SWEEP_COOLDOWN_MS: number = 30 * 1000;
const RDP_DRIVE_REDIRECTION_ENABLED = true;
const SETTINGS_ACCORDION_ANIMATION_MS = 280;
// A native Sheet can finish its dismiss animation before ArkUI has completed
// the pointer-up dispatch that closed it. Keep the host list covered for one
// short release window so that pointer-up cannot activate the card underneath.
const SHEET_RELEASE_FENCE_MS = 420;
// The appearance card is taller than the original 620vp cap after the
// touchpad cursor controls are restored. Keep a stable expansion floor so an
// animation's intermediate layout height cannot collapse the card into a
// self-reinforcing narrow strip.
const APPEARANCE_EXPANDED_MIN_HEIGHT = 900;
const POPUP_SHEET_RDP_CERTIFICATES = 4;
const POPUP_SHEET_RUSTDESK_AUTH_TRUST = 5;
const POPUP_SHEET_VNC_CERTIFICATES = 6;
const REMOTE_HOST_SHEET_NONE = 0;
const REMOTE_HOST_SHEET_SSH_PREFLIGHT = 1;
const REMOTE_HOST_SHEET_RDP_CERTIFICATE = 2;
const REMOTE_HOST_SHEET_RUSTDESK_PREFLIGHT = 3;
const REMOTE_HOST_SHEET_PASSPHRASE = 4;
const REMOTE_HOST_SHEET_PUBLIC_KEY = 5;
const REMOTE_HOST_SHEET_RUSTDESK_TOTP_BINDING = 6;
const REMOTE_HOST_SHEET_VNC_CERTIFICATE = 7;
const REMOTE_HOST_SHEET_VNC_CREDENTIAL = 8;
// Moonlight host cards use the same host-list Sheet host as every other
// protocol.  Keeping this as a mode (instead of a second bindSheet) also
// preserves the list's single-dismiss lifecycle and prevents route switches
// from racing a card expansion.
const REMOTE_HOST_SHEET_MOONLIGHT_DETAIL = 9;
const REMOTE_HOST_SHEET_MOONLIGHT_CATALOG = 10;
const REMOTE_HOST_SHEET_MOONLIGHT_EDIT = 11;
const DESKTOP_MOONLIGHT_TAB = 7;

@Entry
@Component
struct HostListPage {
  @State hosts: RemoteHost[] = [];
  @State filteredHosts: RemoteHost[] = [];
  @State rdpCredentials: RdpCredential[] = [];
  private hostDataSource: HostDataSource = new HostDataSource();
  private hostDataSignature: string = '';
  private hostDataUnsubscribe: (() => void) | null = null;
  private vncHostDataUnsubscribe: (() => void) | null = null;
  private vncTrustDataUnsubscribe: (() => void) | null = null;
  private skipInitialPageShowLoad: boolean = true;
  private hostLoadRefreshTimer: number = -1;
  private hostLoadRefreshPresence: boolean = false;
  private keyVaultDataUnsubscribe: (() => void) | null = null;
  @State pageActive: boolean = false;
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
  @State vncCount: number = 0;
  @State keyCount: number = 0;
  @State totpCount: number = 0;
  @State hostViewRevision: number = 0;
  @State hostPageTitle: string = '远程主机';
  @State loginRefreshKey: number = 0;
  @StorageLink('groupedHostCards') groupedHostCards: boolean = false;
  @StorageLink(HOST_CARD_SENSITIVE_INFO_HIDDEN_KEY) hostCardSensitiveInfoHidden: boolean = false;
  @StorageLink('rustdeskPresenceDetectionEnabled') rustdeskPresenceDetectionEnabled: boolean = false;
  @State expandedHostGroup: string = '';
  @State activeRemoteHostId: string = '';
  @State accountDisplayName: string = '';
  @State accountAvatarUrl: string = '';
  @State hostSelectionMode: boolean = false;
  @State hostSelectedIds: Set<string> = new Set();
  @State hostReorderEnabled: boolean = false;
  private hostManualOrder: string[] = [];
  private hostReorderOriginalOrder: string[] = [];
  private draggingHostId: string = '';
  @State hostPresenceProbeBusyIds: Set<string> = new Set();
  @State hostGroupProbeBusyType: string = '';
  // The service snapshot is persisted asynchronously and can be replaced by
  // a cloud callback while the probe result is being rendered. Keep a small
  // page-local result so the card reflects the completed probe immediately.
  private hostPresenceOverrides: Map<string, HostPresenceOverride> = new Map();
  // A probe result is scoped to both the visible page and its host. A single
  // page-wide counter lets another host's refresh invalidate this host's
  // result before the card can consume it.
  private hostPresencePageGeneration: number = 0;
  private hostPresenceProbeGenerations: Map<string, number> = new Map();
  private hostPresenceRefreshRunning: boolean = false;
  // HostSyncService emits synchronously for local presence observations. Keep
  // that callback from starting a second list snapshot while the probe owns
  // the UI update for the same transition.
  private hostPresenceLocalObservationWrite: boolean = false;
  @State hostActionPopupId: string = '';  // PC大屏模式: 当前弹出操作菜单的主机ID
  @StorageLink('followSystem') followSystem: boolean = true;
  @StorageLink('remoteDesktopBgFlag') @Watch('onRemoteDesktopBgFlagChange') appInBackground: boolean = false;
  @StorageProp('colorMode') @Watch('onSystemColorModeChange') systemUiColorMode: number = ENV_COLOR_MODE_UNKNOWN;
  @State showAddSheet: boolean = false;
  @State addSheetShowsModernPicker: boolean = false;
  @State modernAddProtocol: string = '';
  @State moonlightAddOwnerToken: number = 1;
  @State moonlightLanCandidates: MoonlightHostAddCandidate[] = [];
  @State moonlightDiscoveryRunning: boolean = false;
  @State moonlightDiscoveryResultOwnerToken: number = 0;
  @State moonlightDiscoveryResultGeneration: number = 0;
  @State moonlightProtocolAvailable: boolean = false;
  @State moonlightHosts: MoonlightHostLocalView[] = [];
  @State moonlightDirectoryCode: string = 'loading';
  private readonly moonlightSettingsService: MoonlightSettingsLocalService =
    new MoonlightSettingsLocalService(CloudStore.getInstance());
  private moonlightDirectoryOwnerScopeId: string = '';
  private moonlightDirectoryAccountGeneration: number = 0;
  private moonlightDirectoryStoreInstanceId: number = 0;
  @State vncAddFromModernPicker: boolean = false;
  @State addSheetClosing: boolean = false;
  @State sheetReleaseFenceActive: boolean = false;
  private sheetReleaseFenceGeneration: number = 0;
  private sheetReleaseFenceTimer: number = -1;
  // Keep the released storage/cloud key while exposing the broader FAB-style semantics in UI code.
  @StorageLink('hostAddMode') fabAddStyle: string = 'modern';
  @StorageLink('virtualMouseStyle') virtualMouseStyle: string = 'arrow';
  @StorageLink('totpLogoMode') totpLogoMode: string = 'logo';
  @State lanScanning: boolean = false;
  @State lanScanResults: DiscoveredRustDeskPeer[] = [];
  private lanDiscovery: RustDeskLanDiscoveryService = new RustDeskLanDiscoveryService();
  @State rdpLanScanning: boolean = false;
  @State rdpLanScanResults: DiscoveredRdpHost[] = [];
  @State rdpLanStatusText: string = '';
  private rdpLanDiscovery: RdpLanDiscoveryService = new RdpLanDiscoveryService();
  private dynamicRustDeskDiscovery: RustDeskLanDiscoveryService = new RustDeskLanDiscoveryService();
  private dynamicRdpDiscovery: RdpLanDiscoveryService = new RdpLanDiscoveryService();
  private dynamicLanRefreshPromise: Promise<void> | null = null;
  private dynamicLanLastSweepAt: number = 0;
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
  @State vncSettingsLeafDirty: boolean = false;
  @State moonlightSettingsLeafDirty: boolean = false;
  @State moonlightSettingsLeafHostId: string = '';
  @State expandedSettingsSection: string = SETTINGS_SECTION_NONE;
  @State aboutSheetMode: number = 0; // 0=简单教程 1=关于应用 2=隐私政策 3=连接前准备 4=更新日志 5=操作引导中心
  // 合并 Sheet: 单 bindSheet + mode 切换 (避免 $$ 多 bindSheet 错位)
  @State showPopupSheet: boolean = false;
  @State popupSheetMode: number = 0; // 0=crypto, 1=about(用 aboutSheetMode 子路由), 2=SSH host key, 4=RDP certificate
  @State cloudSyncStep: string = CLOUD_SYNC_SHEET_ACTIONS;
  @State cloudConnectionAvailable: boolean = false;
  /** User's explicit portable-backup sensitivity choice at export time. */
  @State backupFullMode: boolean = false;
  @State cloudSyncError: string = '';
  @State cloudSyncSelectedTables: string[] = [];
  @State moonlightCloudSelectedScopes: string[] = [];
  @State moonlightRestoreActivationState: string = 'clear';
  @State appearanceContentHeight: number = 0;
  private pendingLocalRestore: LocalBackupDocument | null = null;
  @State sheetPwd: string = '';
  @State vncHostTransport: VncTransport = 'direct_tcp';
  @State vncHostRepeaterMode: VncRepeaterMode = 'mode12';
  @State vncHostGatewayId: string = '';
  @State vncHostPasswordConfigured: boolean = false;
  @State vncHostRememberPassword: boolean = false;
  @State vncHostViewOnly: boolean = true;
  @State vncHostDisplayOverrideEnabled: boolean = false;
  @State vncHostScalingMode: VncScalingMode = 'fit';
  @State vncHostClipboardEnabled: boolean = false;
  @State vncHostSecurityPolicy: VncSecurityPolicy = 'secure_only';
  @State vncHostTls: boolean = true;
  @State sheetUseKey: boolean = false;
  @State sheetKeyPath: string = '';
  @State sheetKeyText: string = '';
  @State sheetKeyId: string = '';
  @State sheetKeyPassphrase: string = '';
  @State sheetKeyMode: number = 0; // 0=文件 1=粘贴
  // SSH 前置校验 (T-210) — @State 驱动 UI, 避免普通 class 不触发响应式更新
  @State showSshPreflight: boolean = false;
  @State showRemoteHostSheet: boolean = false;
  @State remoteHostSheetMode: number = REMOTE_HOST_SHEET_NONE;
  @State moonlightSheetHostId: string = '';
  @State moonlightEditName: string = '';
  @State moonlightEditAddress: string = '';
  @State moonlightEditPortText: string = '';
  @State moonlightEditHttpsPortText: string = '';
  @State moonlightEditHostType: MoonlightHostType = 'sunshine';
  @State moonlightEditWakeEnabled: boolean = false;
  @State moonlightEditWakeMac: string = '';
  @State moonlightEditWakeBroadcast: string = '';
  @State moonlightEditError: string = '';
  private pendingMoonlightCatalogHostId: string = '';
  private pendingMoonlightSettingsHostId: string = '';
  private pendingMoonlightCatalogNavigation: string = '';
  private pendingMoonlightCatalogLaunch: MoonlightCatalogLaunchHandoff | null = null;
  private moonlightCatalogReturnsToDetail: boolean = false;
  @State moonlightCatalogDismissAllowed: boolean = true;
  @State sshPreflightState: number = 0;
  private sshPreflightOpenedAt: number = 0;
  private sshPreflightGeneration: number = 0;
  private sshPreflightPendingRouteParams: Record<string, Object> | null = null;
  private sshPreflightClosing: boolean = false;
  private sshPreflightClosingHostId: string = '';
  private sshPreflightPendingHostId: string = '';
  @State sshPreflightHostId: string = '';
  @State sshPreflightHostLabel: string = '';
  @State sshPreflightSavedAlgorithm: string = '';
  @State sshPreflightHostKeyInfo: SshHostKeyInfo | null = null;
  @State sshPreflightJumpHostLabel: string = '';
  @State sshPreflightJumpHostKeyInfo: SshHostKeyInfo | null = null;
  @State sshPreflightError: string = '';
  @State sshPreflightPassphraseInput: string = '';
  @State sshPreflightProxyPassphraseInput: string = '';
  @State sshPreflightPassphraseShowPw: boolean = false;
  @State sshPreflightPassphraseSaveToHost: boolean = false;
  @State sshPreflightProxyPassphraseSaveToHost: boolean = false;
  @State sshPreflightPassphraseScope: string = 'target'; // target | proxy
  @State showRdpCertificatePreflight: boolean = false;
  @State rdpCertificateState: number = RdpCertificatePreflightState.PROBING;
  private rdpCertificateOpenedAt: number = 0;
  @State rdpCertificateHostId: string = '';
  @State rdpCertificateHostLabel: string = '';
  @State rdpCertificateWarning: string = '';
  @State rdpCertificateInfo: RdpCertificateInfo | null = null;
  @State rdpGatewayCertificateInfo: RdpCertificateInfo | null = null;
  @State rdpCertificateRouteResult: RdpPreflightResult | null = null;
  @State rdpCertificateError: string = '';
  @State rdpCertificateErrorStage: string = '';
  @State rdpCertificateErrorCode: string = '';
  @State rdpCertificateShowDetails: boolean = false;
  private rdpGatewayPreflightOneTimeFingerprint: string = '';
  private rdpGatewayPreflightOneTimeAllowUntrustedRoot: boolean = false;
  private rdpGatewayPreflightOneTimeAllowHostMismatch: boolean = false;
  private rdpGatewayPreflightOneTimeAllowTimeAnomaly: boolean = false;
  private rdpGatewayPreflightOneTimeRouteIdentity: string = '';
  private rdpCertificatePendingRouteParams: Record<string, Object> | null = null;
  private rdpCertificateProbeGeneration: number = 0;
  // RDP certificate Sheet 的 native 退出动画完成前，不允许复用同一 bindSheet 宿主。
  private rdpCertificateClosing: boolean = false;
  private rdpCertificateClosingHostId: string = '';
  private rdpCertificatePendingHostId: string = '';
  private rdpCertificateAttemptGeneration: number = 0;
  private rdpCertificateClosingAttemptGeneration: number = 0;
  @State showVncCertificatePreflight: boolean = false;
  @State vncCertificateState: VncCertificatePreflightState = VncCertificatePreflightState.IDLE;
  @State vncCertificateHostId: string = '';
  @State vncCertificateHostLabel: string = '';
  @State vncCertificateWarning: string = '';
  @State vncCertificateInfo: VncCertificateInfo | null = null;
  @State vncCertificateError: string = '';
  @State vncCertificateShowDetails: boolean = false;
  private vncCertificateProbeGeneration: number = 0;
  private vncCertificateAttemptGeneration: number = 0;
  private vncCertificateProbeRequestId: number = 0;
  private vncCertificateEndpoint: VncTlsEndpointResolution | null = null;
  private vncCertificateTrustOwner: VncTrustEndpoint | null = null;
  private vncCertificateProbeIdentity: VncCertificateProbeIdentity | null = null;
  private vncCertificatePendingRouteParams: Record<string, Object> | null = null;
  private vncCertificateClosing: boolean = false;
  private vncCertificateClosingHostId: string = '';
  private vncCertificateClosingAttemptGeneration: number = 0;
  private vncCertificatePendingHostId: string = '';
  private vncCertificateAccountOwnerScopeId: string = '';
  private vncCertificateAccountStoreIdentityFingerprint: string = '';
  private vncCertificateAccountGeneration: number = 0;
  private vncCertificateHandoff: VncCertificateDecisionHandoff =
    VncCertificateDecisionHandoff.getInstance();
  private vncPlaintextHandoff: VncPlaintextDecisionHandoff =
    VncPlaintextDecisionHandoff.getInstance();
  @State vncCredentialHostId: string = '';
  @State vncCredentialHostLabel: string = '';
  @State vncCredentialPassword: string = '';
  @State vncCredentialRememberPassword: boolean = false;
  @State vncCredentialNoPassword: boolean = false;
  @State vncCredentialPasswordVisible: boolean = false;
  @State vncCredentialState: VncCredentialPreflightState = 'missing';
  @State vncCredentialError: string = '';
  private vncCredentialRouteHostId: string = '';
  private vncCredentialPendingRouteParams: Record<string, Object> | null = null;
  private vncCredentialRouteAfterClose: boolean = false;
  private vncCredentialClosing: boolean = false;
  private vncCredentialRetryHostId: string = '';
  private vncCredentialRetryReplaceSavedHostId: string = '';
  private vncCredentialReplacingFailedPassword: boolean = false;
  private vncCredentialEndpointBinding: string = '';
  private vncCredentialOwnerScopeId: string = '';
  private vncCredentialAccountGeneration: number = 0;
  private vncCredentialCertificateFingerprint: string = '';
  private vncCredentialCertificateGeneration: number = 0;
  private vncCredentialCertificateEndpointBinding: string = '';
  private vncCredentialCertificateOwnerScopeId: string = '';
  private vncCredentialCertificateStoreFingerprint: string = '';
  private vncCredentialCertificateAccountGeneration: number = 0;
  @State showRustDeskProPreflight: boolean = false;
  @State rustDeskProPreflightState: number = RustDeskProPreflightState.IDLE;
  @State rustDeskProPreflightHostId: string = '';
  @State rustDeskProAuthMode: string = 'password';
  @State rustDeskProPassword: string = '';
  @State rustDeskProPasswordMode: number = 0;
  @State rustDeskProPasswordVisible: boolean = false;
  @State rustDeskProRememberPassword: boolean = true;
  @State rustDeskProPreflightError: string = '';
  @State rustDeskProTwoFactorActive: boolean = false;
  @State rustDeskProTwoFactorInput: string = '';
  @State rustDeskProTwoFactorError: string = '';
  @State rustDeskProTwoFactorSubmitting: boolean = false;
  @State rustDeskProTwoFactorEntryOptions: RustDeskTwoFactorEntryOption[] = [];
  @State rustDeskProTwoFactorSelectedEntryId: string = '';
  private rustDeskProTwoFactorSessionId: number = -1;
  private rustDeskProTwoFactorAutoAttemptSessionId: number = -1;
  private rustDeskProDisconnectIdentity: NativeDisconnectIdentity | null = null;
  private rustDeskProPreflightGeneration: number = 0;
  // RustDesk preflight Sheet 退出动画完成前，不允许复用同一 bindSheet 宿主。
  private rustDeskProPreflightClosing: boolean = false;
  private rustDeskProPreflightClosingHostId: string = '';
  private rustDeskProPreflightPendingHostId: string = '';
  private rustDeskProBackgroundResumeHostId: string = '';
  private rustDeskProBackgroundDismissConfirmed: boolean = false;
  private rustDeskProDismissClassificationTimer: number = -1;
  private readonly rustDeskAuthDrafts: RustDeskAuthDraftStore =
    RustDeskAuthDraftStore.getInstance();
  private rustDeskProPreflightPendingRouteParams: Record<string, Object> | null = null;
  private remoteHostSheetClosing: boolean = false;
  private remoteHostSheetClosingMode: number = REMOTE_HOST_SHEET_NONE;
  // TOTP 绑定与主机编辑 Sheet 不能同时占用 native bindSheet 宿主。
  // generation 使系统认证、旧 Sheet 回调和新一轮绑定严格隔离。
  private rustDeskTotpBindingGeneration: number = 0;
  private rustDeskTotpBindingClosing: boolean = false;
  private rustDeskTotpBindingPendingOpen: boolean = false;
  private rustDeskTotpBindingReturnToAddSheet: boolean = false;
  private rustDeskTotpBindingReturnToModernAdd: boolean = false;
  private preserveFormOnAddSheetDisappear: boolean = false;
  // 保存并连接必须等新增主机 Sheet 的 native onDisappear 后再交给鉴权 Sheet。
  private pendingAddSheetConnectHostId: string = '';
  private pendingVncConnectHostId: string = '';
  private moonlightCatalogHandoffGeneration: number = 0;
  private pendingMoonlightCatalogHandoff: HostAddPostSaveHandoff =
    emptyHostAddPostSaveHandoff();
  private moonlightAddCommitted: boolean = false;
  private pendingVncGatewayDirectoryOpen: boolean = false;
  private pendingRustDeskRelayDirectoryOpen: boolean = false;
  private connectionAttemptGeneration: number = 0;
  private connectionAttemptHostId: string = '';
  private rustDeskWindowHandoffGeneration: number = 0;
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
  @StorageLink(REMOTE_SESSION_CONTROL_BAR_HIDDEN_RDP_KEY)
  sessionControlBarHiddenRdp: boolean = false;
  @StorageLink(REMOTE_SESSION_CONTROL_BAR_HIDDEN_RUSTDESK_KEY)
  sessionControlBarHiddenRustDesk: boolean = false;
  @StorageLink(REMOTE_SESSION_CONTROL_BAR_HIDDEN_VNC_KEY)
  sessionControlBarHiddenVnc: boolean = false;
  @StorageLink(REMOTE_SESSION_CONTROL_BAR_HIDDEN_MOONLIGHT_KEY)
  sessionControlBarHiddenMoonlight: boolean = false;
  @State sessionControlBarProtocolPickerExpanded: boolean = false;
  @StorageLink('canvasGestureZoomEnabled') canvasGestureZoomEnabled: boolean = false;
  @StorageLink('rdpColorDepth') rdpColorDepth: number = 32;
  @StorageLink('rdpAudioEnabled') rdpAudioEnabled: boolean = true;
  @StorageLink('rdpClipboardEnabled') rdpClipboardEnabled: boolean = true;
  @StorageLink('rdpDriveEnabled') rdpDriveEnabled: boolean = true;
  @StorageLink('rdpShowDiagnostics') rdpShowDiagnostics: boolean = false;
  @StorageLink('rdpDriveName') rdpDriveName: string = 'RemoteDesktop';
  @StorageLink('rdpControlMode') rdpControlMode: number = 0; // 0=触控板, 1=直接触控, 2=键鼠
  @StorageLink('rdpAuthIdentityMode') rdpAuthIdentityMode: number = 1; // 0=MicrosoftAccount\\邮箱, 1=域+邮箱, 2=裸邮箱, 3=.\\AzureAD\\邮箱, 4=AzureAD域
  @StorageLink('rdpTlsWithoutNla') rdpTlsWithoutNla: boolean = false;
  @State sheetPwdMode: number = 0; // 0=一次性密码, 1=永久密码
  @State sheetRustdeskAuthMode: string = 'password'; // password | request_approval
  @State sheetRustdeskDirectEnabled: boolean = false; // per-host 直连开关
  @State sheetRustdeskDirectHost: string = '';
  @State sheetRustdeskDirectPort: number = RUSTDESK_PEER_TCP_PORT;
  @State sheetRustdeskTotpEntryId: string = '';
  @State sheetRustdeskTotpAutoSubmit: boolean = false;
  @State sheetRustdeskTargetDevice: RustDeskTargetDevice = 'computer';
  @State sheetRustdeskAdaptiveOrientation: boolean = false;
  @State sheetSshProxyEditorValue: SshProxyEditorValue = defaultSshProxyEditorValue();
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
  @StorageLink('liveViewEnabled') liveViewEnabled: boolean = true;
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
  @StorageLink('sshTerminalForegroundColor') terminalFgColor: string = '#33FF33';
  @State showTerminalFgColor: boolean = false;
  @StorageLink('sshTerminalFontSize') terminalFontSize: number = 18;
  @StorageLink('sshTerminalLineSpacing') terminalLineSpacing: number = 1.12;
  @StorageLink('sshInputMode') sshInputMode: number = 1; // 0=自动, 1=虚拟键盘, 2=实体键鼠
  @StorageLink(SSH_WORKBENCH_V2_FLAG_KEY)
  sshWorkbenchEnabled: boolean = SSH_WORKBENCH_V2_DEFAULT_ENABLED;
  @State sshSystemNotificationsEnabled: boolean = false;
  @State sshNotificationAuthorizationPending: boolean = false;
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
  @State relayRustDeskAddTrigger: number = 0;
  @State relayVncAddTrigger: number = 0;
  @State rustDeskRelayReturnToHostAdd: boolean = false;
  @State rustDeskAddResumeDraft: RustDeskHostAddDraft | null = null;
  @State rustDeskAddResumeRevision: number = 0;
  private rustDeskHostAddReturnTab: number = 0;
  private lastVncRelayRouteRequestId: string = '';
  private terminalFontSizes: number[] = [12, 13, 14, 15, 16, 17, 18, 20, 22, 24, 26, 28, 30, 32];
  private terminalLineSpacings: number[] = [1.00, 1.05, 1.10, 1.12, 1.20, 1.30, 1.40, 1.50];
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
  @State vncTrustViews: VncTrustView[] = [];
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
  private readonly proSync: RustDeskProSyncService = RustDeskProSyncService.getInstance();
  private auth: AuthService = AuthService.getInstance();
  private keyVault: KeyVaultService = KeyVaultService.getInstance();
  private readonly vncHosts: VncHostService = VncHostService.getInstance();
  private readonly vncGateways: VncGatewayService = VncGatewayService.getInstance();
  private readonly vncTrust: VncTrustService = VncTrustService.getInstance();
  private readonly vncSettings: VncSettingsService = VncSettingsService.getInstance();
  private readonly moonlightLocalHostService: MoonlightLocalHostService =
    new MoonlightLocalHostService(CloudStore.getInstance(), CloudStore.getInstance());
  private readonly moonlightDeletionRuntime: MoonlightDeletionRuntime =
    MoonlightDeletionRuntime.getInstance();
  private readonly moonlightLocalViewService: MoonlightLocalViewService =
    new MoonlightLocalViewService(CloudStore.getInstance());
  private readonly moonlightHostService: MoonlightHostService = new MoonlightHostService();
  private readonly moonlightLanProbeService: MoonlightLanProbeService =
    new MoonlightLanProbeService();
  private moonlightDiscovery: MoonlightLanDiscoveryService | null = null;
  private moonlightActiveVerification: MoonlightHostAddVerification | null = null;
  private moonlightPendingVerificationFence: MoonlightHostOperationFence | null = null;
  private moonlightActiveVerificationFence: MoonlightHostOperationFence | null = null;
  private moonlightPairingExpiresAt: number = 0;
  private loader: ExtensionLoader = ExtensionLoader.getInstance();
  private sshKeyImporter: SshKeyImportService = new SshKeyImportService();
  private readonly sshSettings: SshSettingsService = SshSettingsService.getInstance();
  private readonly sshNotificationService: SshNotificationService =
    SshNotificationService.getInstance();
  private readonly sshWorkspaceCapabilityStore: SshWorkspaceCapabilityStore =
    new SshWorkspaceCapabilityStore();
  private readonly sshProxyProfiles: SshProxyProfileStore = new SshProxyProfileStore();
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

  private finishHostPassphrasePrompt(value: string): void {
    if (this.hlPassphraseResolve) {
      this.hlPassphraseResolve(value);
      this.hlPassphraseResolve = null;
    }
  }

  private closeHostPassphraseSheet(value: string): void {
    this.beginRemoteHostSheetClose(REMOTE_HOST_SHEET_PASSPHRASE);
    this.showPassphraseSheet = false;
    this.showRemoteHostSheet = false;
    this.finishHostPassphrasePrompt(value);
  }

  private promptKeyPassphrase(): Promise<string> {
    return new Promise<string>((resolve: (v: string) => void) => {
      this.hlPassphraseResolve = resolve;
      this.hlPassphraseInput = '';
      this.openSheetSafely((): void => {
        this.openRemoteHostSheet(REMOTE_HOST_SHEET_PASSPHRASE, (): void => {
          this.showPassphraseSheet = true;
        });
      });
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
            this.closeHostPassphraseSheet('');
          })
        Button('确定').fontSize(14).height(38).layoutWeight(1)
          .backgroundColor(this.accentColor).fontColor('#FFFFFF').borderRadius(8).margin({ left: 12 })
          .onClick(() => {
            this.closeHostPassphraseSheet(this.hlPassphraseInput);
          })
      }.width('100%')
    }.padding(20)
  }
  private tabsCtrl: HdsTabsController = new HdsTabsController();
  private searchTimer: number = -1;
  private presetColors: string[] = ['#FFFFFF','#F0F0F0','#F0F5FA','#FFF8F0','#F5F0F8','#1A1A2E','#1E4377','#2D1B4E'];
  @State wallpaperItems: WallpaperItem[] = [];
  // The long VNC/SSH add flows use a bounded sheet on phones. Keep the
  // viewport height in vp so the sheet can leave room for the system bars.
  @State windowH: number = 720;
  @State pageViewportHeight: number = 720;
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
      this.clearRustDeskProDismissClassificationTimer();
      if (this.showRustDeskProPreflight && this.rustDeskProPreflightHostId !== '') {
        this.saveRustDeskProAuthDraft();
        this.rustDeskProBackgroundResumeHostId = this.rustDeskProPreflightHostId;
      }
      if (this.rustDeskProBackgroundResumeHostId !== '') {
        this.rustDeskProBackgroundDismissConfirmed = true;
      }
      this.pauseForegroundSensors('ability-background');
    } else {
      this.resumeForegroundSensors('ability-foreground');
      this.resumeRustDeskProPreflightAfterBackground();
    }
  }

  private clearRustDeskProDismissClassificationTimer(): void {
    if (this.rustDeskProDismissClassificationTimer >= 0) {
      clearTimeout(this.rustDeskProDismissClassificationTimer);
      this.rustDeskProDismissClassificationTimer = -1;
    }
  }

  private settleRustDeskProImplicitDismiss(): void {
    this.clearRustDeskProDismissClassificationTimer();
    const hostId: string = this.rustDeskProBackgroundResumeHostId;
    if (hostId === '') { return; }
    if (this.appInBackground) {
      this.rustDeskProBackgroundDismissConfirmed = true;
      return;
    }
    if (this.rustDeskProBackgroundDismissConfirmed) {
      setTimeout((): void => { this.resumeRustDeskProPreflightAfterBackground(); }, 0);
      return;
    }
    // ArkUI may dismiss a Sheet just before the ability background flag is
    // delivered. Keep the process-memory draft through that short ordering
    // window; if no background signal arrives, the dismissal was an explicit
    // gesture and the draft is securely cleared without reopening the Sheet.
    this.rustDeskProDismissClassificationTimer = setTimeout((): void => {
      this.rustDeskProDismissClassificationTimer = -1;
      if (this.appInBackground ||
        this.rustDeskProBackgroundResumeHostId !== hostId) {
        return;
      }
      this.clearRustDeskProAuthDraft(hostId);
    }, 180);
  }

  private resumeRustDeskProPreflightAfterBackground(): void {
    const hostId: string = this.rustDeskProBackgroundResumeHostId;
    if (hostId === '' || !this.pageActive || this.appInBackground ||
      this.showRustDeskProPreflight ||
      this.showRemoteHostSheet || this.rustDeskProPreflightClosing ||
      this.remoteHostSheetClosing) {
      return;
    }
    this.rustDeskProBackgroundResumeHostId = '';
    this.rustDeskProBackgroundDismissConfirmed = false;
    setTimeout((): void => {
      if (!this.pageActive || this.appInBackground) { return; }
      const host: RemoteHost | undefined = this.srv.getHost(hostId);
      if (host === undefined) {
        this.rustDeskAuthDrafts.clearHost(hostId);
        return;
      }
      void this.connectToHost(host);
    }, 0);
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
    void this.refreshDynamicLanHosts(false);
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
      this.hostReorderEnabled = false;
      this.hostSelectedIds = new Set();
    }
    if (this.groupedHostCardsActive()) {
      this.curTab = 0;
      this.hostPageTitle = '远程主机';
      this.updateHostFilter();
      return;
    }
    // xl→非xl: curTab 越界修正 + 标题重置
    if (this.breakpoint !== 'xl') {
      if (this.curTab > 3) { this.curTab = 0; }
      this.hostPageTitle = '远程主机';
      this.updateHostFilter(); // 非xl显示全部主机
    } else {
      // 非xl→xl: 标题跟随当前 tab
      const titles: string[] = ['RDP 远程主机', 'RustDesk 远程主机', 'SSH 终端', 'VNC 主机', '', '', '中继服务器'];
      this.hostPageTitle = titles[this.curTab] || '';
      this.updateHostFilter();
    }
  }

  onBackPress(): boolean {
    if (this.hostSelectionMode) {
      this.cancelHostEdit();
      return true;
    }
    return false;
  }

  async aboutToAppear(): Promise<void> {
    this.pageActive = true;
    this.cloudConnectionAvailable =
      CloudStore.getInstance().isCloudAvailable();
    // Keep VNC storage isolated while preparing its display projection before
    // the first host-list snapshot is built.
    this.prepareVncAddFlow();
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
    this.sshSettings.init(getContext(this) as common.Context);
    this.sshWorkbenchEnabled = this.sshWorkspaceCapabilityStore.load(
      getContext(this) as common.Context);
    this.refreshSshNotificationAuthorization();
    this.sshProxyProfiles.init(getContext(this) as common.Context);
    this.proSync.init(getContext(this) as common.Context);
    // 恢复 TOTP 隐私保护状态 (Preferences 持久化)
    try {
      const prefs = preferences.getPreferencesSync(getContext(this), { name: 'RemoteDesktopAppPrefs' });
      const defaults: PersonalizationDefaults = personalizationDefaults(
        prefs.getSync(PERSONALIZATION_DEFAULTS_FRESH_INSTALL_KEY,
          AppStorage.get<boolean>(PERSONALIZATION_DEFAULTS_FRESH_INSTALL_KEY) ?? false) as boolean,
        this.isDesktopDevice);
      // 核心外观设置
      const savedTheme: string = prefs.getSync('currentTheme', '') as string;
      const savedAccent: string = prefs.getSync('accentColor', '') as string;
      const savedFollowSystem: boolean = prefs.getSync('followSystem', true) as boolean;
      const savedAmbientLightEffect: boolean = prefs.getSync('ambientLightEffectEnabled', false) as boolean;
      const savedLiveViewEnabled: boolean =
        prefs.getSync('liveViewEnabled', defaults.liveViewEnabled) as boolean;
      const savedLiveViewMode: number = prefs.getSync('liveViewMode', defaults.liveViewMode) as number;
      const savedHostAddMode: string = prefs.getSync('hostAddMode', 'modern') as string;
      const savedVirtualMouseStyle: string =
        prefs.getSync('virtualMouseStyle', defaults.virtualMouseStyle) as string;
      const savedTotpLogoMode: string = prefs.getSync('totpLogoMode', defaults.totpLogoMode) as string;
      const savedGroupedHostCards: boolean =
        prefs.getSync('groupedHostCards', defaults.groupedHostCards) as boolean;
      const savedHostCardSensitiveInfoHidden: boolean =
        prefs.getSync(HOST_CARD_SENSITIVE_INFO_HIDDEN_KEY, false) as boolean;
      const sessionControlBarVisibility: RemoteSessionControlBarVisibility =
        resolveRemoteSessionControlBarVisibility({
          rdpHidden: prefs.getSync(REMOTE_SESSION_CONTROL_BAR_HIDDEN_RDP_KEY, false) as boolean,
          rustDeskHidden:
            prefs.getSync(REMOTE_SESSION_CONTROL_BAR_HIDDEN_RUSTDESK_KEY, false) as boolean,
          vncHidden: prefs.getSync(REMOTE_SESSION_CONTROL_BAR_HIDDEN_VNC_KEY, false) as boolean,
          moonlightHidden:
            prefs.getSync(REMOTE_SESSION_CONTROL_BAR_HIDDEN_MOONLIGHT_KEY, false) as boolean
        }, {
          rustDeskPresent: prefs.hasSync(REMOTE_SESSION_CONTROL_BAR_HIDDEN_RUSTDESK_KEY),
          vncPresent: prefs.hasSync(REMOTE_SESSION_CONTROL_BAR_HIDDEN_VNC_KEY)
        }, prefs.getSync(PC_SESSION_TOP_BAR_HIDDEN_KEY, false) as boolean);
      const savedRustDeskPresenceDetection: boolean =
        prefs.getSync('rustdeskPresenceDetectionEnabled',
          defaults.rustdeskPresenceDetectionEnabled) as boolean;
      const savedWallpaper: string = prefs.getSync('wallpaperColor', '') as string;
      const savedUseNativeCore: boolean = prefs.getSync('useNativeTerminalCore', true) as boolean;
      const savedSshInputMode: number = prefs.getSync('sshInputMode', defaults.sshInputMode) as number;
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
      this.liveViewMode = savedLiveViewMode >= 0 && savedLiveViewMode <= 2 ?
        savedLiveViewMode : defaults.liveViewMode;
      AppStorage.setOrCreate('liveViewMode', this.liveViewMode);
      this.fabAddStyle = savedHostAddMode === 'classic' ? 'classic' : 'modern';
      AppStorage.setOrCreate('hostAddMode', this.fabAddStyle);
      this.virtualMouseStyle = normalizeRemoteCursorStyle(savedVirtualMouseStyle);
      AppStorage.setOrCreate('virtualMouseStyle', this.virtualMouseStyle);
      this.totpLogoMode = savedTotpLogoMode === 'initials' ? 'initials' : 'logo';
      AppStorage.setOrCreate('totpLogoMode', this.totpLogoMode);
      this.groupedHostCards = savedGroupedHostCards;
      AppStorage.setOrCreate('groupedHostCards', this.groupedHostCards);
      // 恢复主机手动排序顺序 (纯本地持久化)
      const savedManualOrder: string = prefs.getSync('hostManualSortOrder', '') as string;
      if (savedManualOrder.length > 0) {
        try { this.hostManualOrder = JSON.parse(savedManualOrder) as string[]; } catch (_) {
          this.hostManualOrder = [];
        }
      }
      this.hostCardSensitiveInfoHidden = savedHostCardSensitiveInfoHidden;
      AppStorage.setOrCreate(HOST_CARD_SENSITIVE_INFO_HIDDEN_KEY,
        this.hostCardSensitiveInfoHidden);
      this.sessionControlBarHiddenRdp = sessionControlBarVisibility.rdpHidden;
      this.sessionControlBarHiddenRustDesk = sessionControlBarVisibility.rustDeskHidden;
      this.sessionControlBarHiddenVnc = sessionControlBarVisibility.vncHidden;
      this.sessionControlBarHiddenMoonlight = sessionControlBarVisibility.moonlightHidden;
      AppStorage.setOrCreate(REMOTE_SESSION_CONTROL_BAR_HIDDEN_RDP_KEY,
        this.sessionControlBarHiddenRdp);
      AppStorage.setOrCreate(REMOTE_SESSION_CONTROL_BAR_HIDDEN_RUSTDESK_KEY,
        this.sessionControlBarHiddenRustDesk);
      AppStorage.setOrCreate(REMOTE_SESSION_CONTROL_BAR_HIDDEN_VNC_KEY,
        this.sessionControlBarHiddenVnc);
      AppStorage.setOrCreate(REMOTE_SESSION_CONTROL_BAR_HIDDEN_MOONLIGHT_KEY,
        this.sessionControlBarHiddenMoonlight);
      this.rustdeskPresenceDetectionEnabled = savedRustDeskPresenceDetection;
      AppStorage.setOrCreate('rustdeskPresenceDetectionEnabled', this.rustdeskPresenceDetectionEnabled);
      if (savedWallpaper !== '') { AppStorage.setOrCreate('wallpaperColor', savedWallpaper); }
      const savedWallIdx: number = prefs.getSync('wallpaperIdx', -1) as number;
      if (savedWallIdx >= 0 && savedWallIdx < this.wallpaperItems.length) {
        this.wallpaperIdx = savedWallIdx;
      }
      AppStorage.setOrCreate('useNativeTerminalCore', savedUseNativeCore);
      this.sshInputMode = this.clampSshInputMode(savedSshInputMode);
      AppStorage.setOrCreate('sshInputMode', this.sshInputMode);
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
      const savedControlMode: number =
        prefs.getSync('rustdeskControlMode', defaults.rustdeskControlMode) as number;
      const savedRdpDesktopPreset: number = prefs.getSync('rdpDesktopPreset', 1) as number;
      const savedRdpDesktopResolutionId: string = prefs.getSync('rdpDesktopResolutionId', '') as string;
      const savedRemoteDisplayScaleMode: string = prefs.getSync('remoteDisplayScaleMode', '') as string;
      const remoteDisplayScalePreferenceVersion: number =
        prefs.getSync(REMOTE_DISPLAY_SCALE_PREFERENCE_VERSION_KEY, 0) as number;
      const savedRemoteDisplayCustomScalePercent: number =
        prefs.getSync('remoteDisplayCustomScalePercent', 100) as number;
      const canvasGestureZoomDefaultVersion: number =
        prefs.getSync('canvasGestureZoomDefaultVersion', 0) as number;
      const canvasZoomPreference = resolveCanvasGestureZoomPreference(
        prefs.getSync('canvasGestureZoomEnabled', defaults.canvasGestureZoomEnabled) as boolean,
        canvasGestureZoomDefaultVersion,
        prefs.getSync('canvasGestureZoomUserConfigured', false) as boolean,
        prefs.hasSync('canvasGestureZoomEnabled'),
        defaults.canvasGestureZoomEnabled);
      const savedCanvasGestureZoomEnabled: boolean = canvasZoomPreference.enabled;
      const savedRdpColorDepth: number = prefs.getSync('rdpColorDepth', 32) as number;
      const savedRdpAudioEnabled: boolean = prefs.getSync('rdpAudioEnabled', true) as boolean;
      const savedRdpClipboardEnabled: boolean = prefs.getSync('rdpClipboardEnabled', true) as boolean;
      const savedRdpShowDiagnostics: boolean = prefs.getSync('rdpShowDiagnostics', false) as boolean;
      const savedRdpTlsWithoutNla: boolean = prefs.getSync('rdpTlsWithoutNla', false) as boolean;
      const rdpDriveDefaultVersion: number = prefs.getSync('rdpDriveDefaultVersion', 0) as number;
      const hasSavedRdpDriveEnabled: boolean = prefs.hasSync('rdpDriveEnabled');
      let savedRdpDriveEnabled: boolean = prefs.getSync('rdpDriveEnabled', true) as boolean;
      if (rdpDriveDefaultVersion < 3) {
        if (!hasSavedRdpDriveEnabled) {
          savedRdpDriveEnabled = true;
          prefs.putSync('rdpDriveEnabled', savedRdpDriveEnabled);
        }
        prefs.putSync('rdpDriveDefaultVersion', 3);
      }
      const savedRdpDriveName: string = prefs.getSync('rdpDriveName', 'RemoteDesktop') as string;
      const savedRdpControlMode: number =
        prefs.getSync('rdpControlMode', defaults.rdpControlMode) as number;
      const rdpAuthIdentityModeDefaultVersion: number =
        prefs.getSync('rdpAuthIdentityModeDefaultVersion', 0) as number;
      const hasSavedRdpAuthIdentityMode: boolean = prefs.hasSync('rdpAuthIdentityMode');
      let savedRdpAuthIdentityMode: number = prefs.getSync('rdpAuthIdentityMode', 1) as number;
      if (rdpAuthIdentityModeDefaultVersion < 1) {
        if (!hasSavedRdpAuthIdentityMode) {
          savedRdpAuthIdentityMode = 1;
          prefs.putSync('rdpAuthIdentityMode', 1);
        }
        prefs.putSync('rdpAuthIdentityModeDefaultVersion', 1);
      }
      if (!prefs.hasSync('liveViewEnabled')) { prefs.putSync('liveViewEnabled', savedLiveViewEnabled); }
      if (!prefs.hasSync('liveViewMode')) { prefs.putSync('liveViewMode', defaults.liveViewMode); }
      if (!prefs.hasSync('virtualMouseStyle')) { prefs.putSync('virtualMouseStyle', savedVirtualMouseStyle); }
      if (!prefs.hasSync('totpLogoMode')) { prefs.putSync('totpLogoMode', savedTotpLogoMode); }
      if (!prefs.hasSync('groupedHostCards')) { prefs.putSync('groupedHostCards', savedGroupedHostCards); }
      if (!prefs.hasSync('rustdeskPresenceDetectionEnabled')) {
        prefs.putSync('rustdeskPresenceDetectionEnabled', savedRustDeskPresenceDetection);
      }
      if (!prefs.hasSync('sshInputMode')) { prefs.putSync('sshInputMode', savedSshInputMode); }
      if (!prefs.hasSync('rustdeskControlMode')) { prefs.putSync('rustdeskControlMode', savedControlMode); }
      if (!prefs.hasSync('rdpControlMode')) { prefs.putSync('rdpControlMode', savedRdpControlMode); }
      if (!prefs.hasSync('canvasGestureZoomEnabled')) {
        prefs.putSync('canvasGestureZoomEnabled', savedCanvasGestureZoomEnabled);
      }
      if (!prefs.hasSync(REMOTE_SESSION_CONTROL_BAR_HIDDEN_RUSTDESK_KEY)) {
        prefs.putSync(REMOTE_SESSION_CONTROL_BAR_HIDDEN_RUSTDESK_KEY,
          this.sessionControlBarHiddenRustDesk);
      }
      if (!prefs.hasSync(REMOTE_SESSION_CONTROL_BAR_HIDDEN_VNC_KEY)) {
        prefs.putSync(REMOTE_SESSION_CONTROL_BAR_HIDDEN_VNC_KEY,
          this.sessionControlBarHiddenVnc);
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
        remoteDisplayScalePreferenceVersion, prefs.hasSync('remoteDisplayScaleMode'));
      this.remoteDisplayCustomScalePercent = Math.max(50, Math.min(300,
        Number.isFinite(savedRemoteDisplayCustomScalePercent) ? savedRemoteDisplayCustomScalePercent : 100));
      this.canvasGestureZoomEnabled = savedCanvasGestureZoomEnabled;
      prefs.putSync('rdpDesktopResolutionId', this.rdpDesktopResolutionId);
      prefs.putSync('remoteDisplayScaleMode', this.remoteDisplayScaleMode);
      prefs.putSync(REMOTE_DISPLAY_SCALE_PREFERENCE_VERSION_KEY,
        REMOTE_DISPLAY_SCALE_PREFERENCE_VERSION);
      prefs.putSync('remoteDisplayCustomScalePercent', this.remoteDisplayCustomScalePercent);
      prefs.putSync('canvasGestureZoomDefaultVersion', canvasZoomPreference.version);
      prefs.putSync('canvasGestureZoomUserConfigured', canvasZoomPreference.userConfigured);
      prefs.flush();
      this.rdpColorDepth = savedRdpColorDepth === 16 || savedRdpColorDepth === 24 ? savedRdpColorDepth : 32;
      this.rdpAudioEnabled = savedRdpAudioEnabled;
      this.rdpClipboardEnabled = savedRdpClipboardEnabled;
      this.rdpShowDiagnostics = savedRdpShowDiagnostics;
      this.rdpDriveEnabled = savedRdpDriveEnabled;
      this.rdpDriveName = this.normalizeRdpDriveName(savedRdpDriveName);
      this.rdpControlMode = this.clampRdpControlMode(savedRdpControlMode);
      this.rdpAuthIdentityMode = this.clampRdpAuthIdentityMode(savedRdpAuthIdentityMode);
      this.rdpTlsWithoutNla = savedRdpTlsWithoutNla;
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
      AppStorage.setOrCreate('rdpShowDiagnostics', this.rdpShowDiagnostics);
      AppStorage.setOrCreate('rdpDriveEnabled', this.rdpDriveEnabled);
      AppStorage.setOrCreate('rdpDriveName', this.rdpDriveName);
      AppStorage.setOrCreate('rdpControlMode', this.rdpControlMode);
      AppStorage.setOrCreate('rdpAuthIdentityMode', this.rdpAuthIdentityMode);
      AppStorage.setOrCreate('rdpTlsWithoutNla', this.rdpTlsWithoutNla);
    } catch (_err) { /* ignore */ }
    // The home page is a core path.  Loading it must not await an optional
    // permission dialog or sensor service.
    await this.load(true, true);
    void this.refreshDynamicLanHosts(false);
    this.consumeRemoteSessionConnectionIntent();
    this.refreshMoonlightDirectory();
    this.registerDataRefreshListeners();
    this.loadAfterServiceReady();
    this.registerInputDeviceWatcher();
    this.syncAmbientLightMonitor();
    this.ensureGripMonitorOnPageShow();
    this.handleVncRelayRouteRequest();
    this.refreshCloudRegistration();
  }

  onPageShow(): void {
    this.pageActive = true;
    this.cloudConnectionAvailable =
      CloudStore.getInstance().isCloudAvailable();
    this.refreshMoonlightDirectory();
    this.refreshCloudRegistration();
    CloudSyncCoordinator.getInstance().flushDeferredAutomaticPushes();
    this.updateWindowMetrics();
    if (this.skipInitialPageShowLoad) {
      this.skipInitialPageShowLoad = false;
    } else {
      if (this.followSystem) {
        this.syncFollowSystemTheme('page-show');
      } else {
        this.reapplyManualTheme('page-show');
      }
      void this.load(true, false).then((): void => {
        this.consumeRemoteSessionConnectionIntent();
      });
    }
    this.refreshCryptoStatus();
    this.refreshSshNotificationAuthorization();
    this.syncAmbientLightMonitor();
    this.ensureGripMonitorOnPageShow();
    void this.refreshDynamicLanHosts(false);
    this.handleVncRelayRouteRequest();
    this.consumeRemoteSessionConnectionIntent();
  }

  private consumeRemoteSessionConnectionIntent(): void {
    if (!this.pageActive || !this.vncHosts.isReady()) { return; }
    const intent: RemoteSessionConnectionIntentValue | null =
      RemoteSessionConnectionIntent.getInstance().take();
    if (intent === null) { return; }
    if (intent.protocol === 'vnc') {
      const host: VncHostView | null = this.vncHosts.find(intent.hostId);
      if (host === null) {
        promptAction.showToast({ message: 'VNC 主机不存在，未开始连接', duration: 2200 });
        return;
      }
      this.vncCredentialRetryHostId = intent.reason === 'authentication_retry' ? host.id : '';
      this.vncCredentialRetryReplaceSavedHostId = intent.reason === 'authentication_retry' &&
        intent.replaceSavedCredential ? host.id : '';
      void this.connectToHost(projectVncHost(host));
    }
  }

  private openSheetSafely(openAction: () => void, allowDuringConnectionAttempt: boolean = false): void {
    if (this.addSheetClosing || this.remoteHostSheetClosing || this.showRemoteHostSheet ||
      (this.connectionAttemptHostId !== '' && !allowDuringConnectionAttempt)) {
      return;
    }
    if (this.pendingSheetOpenTimer !== -1) {
      clearTimeout(this.pendingSheetOpenTimer);
      this.pendingSheetOpenTimer = -1;
    }
    const nowMs: number = Date.now();
    const localDelayMs: number = sheetOpenDelayMsAfterDismiss(nowMs, this.lastSheetDismissAtMs);
    const delayMs: number = Math.max(localDelayMs, sshSftpSheetOpenDelayMs(nowMs));
    if (delayMs <= 0) {
      openAction();
      return;
    }
    this.pendingSheetOpenTimer = setTimeout((): void => {
      this.pendingSheetOpenTimer = -1;
      if (this.addSheetClosing || this.remoteHostSheetClosing || this.showRemoteHostSheet ||
        (this.connectionAttemptHostId !== '' && !allowDuringConnectionAttempt)) {
        return;
      }
      const retryNowMs: number = Date.now();
      const retryLocalDelayMs: number = sheetOpenDelayMsAfterDismiss(
        retryNowMs, this.lastSheetDismissAtMs);
      const retryDelayMs: number = Math.max(
        retryLocalDelayMs, sshSftpSheetOpenDelayMs(retryNowMs));
      if (retryDelayMs > 0) {
        this.pendingSheetOpenTimer = setTimeout((): void => {
          this.pendingSheetOpenTimer = -1;
          this.openSheetSafely(openAction, allowDuringConnectionAttempt);
        }, retryDelayMs);
        return;
      }
      openAction();
    }, delayMs);
  }

  private beginRemoteHostSheetClose(mode: number): void {
    this.activateSheetReleaseFence();
    if (!this.remoteHostSheetClosing) {
      this.remoteHostSheetClosing = true;
      this.remoteHostSheetClosingMode = mode;
    }
    this.lastSheetDismissAtMs = Date.now();
  }

  private activateSheetReleaseFence(): void {
    const generation: number = this.sheetReleaseFenceGeneration + 1;
    this.sheetReleaseFenceGeneration = generation;
    this.sheetReleaseFenceActive = true;
    if (this.sheetReleaseFenceTimer !== -1) {
      clearTimeout(this.sheetReleaseFenceTimer);
    }
    this.sheetReleaseFenceTimer = setTimeout((): void => {
      if (this.sheetReleaseFenceGeneration !== generation) { return; }
      this.sheetReleaseFenceTimer = -1;
      this.sheetReleaseFenceActive = false;
    }, SHEET_RELEASE_FENCE_MS);
  }

  private openRemoteHostSheet(mode: number, makeVisible: () => void): void {
    if (this.remoteHostSheetClosing || this.showRemoteHostSheet) {
      return;
    }
    this.remoteHostSheetMode = mode;
    makeVisible();
    this.showRemoteHostSheet = true;
  }

  private isCurrentRustDeskTotpBinding(generation: number): boolean {
    return !this.rustDeskTotpBindingClosing &&
      this.rustDeskTotpBindingGeneration === generation &&
      this.remoteHostSheetMode === REMOTE_HOST_SHEET_RUSTDESK_TOTP_BINDING &&
      this.showRemoteHostSheet;
  }

  private rustDeskTotpBindingSummary(): string {
    if (this.sheetRustdeskTotpEntryId === '') {
      return '未绑定，点击选择本机验证器';
    }
    const entry: TotpEntry | undefined =
      this.keyVault.getTotpEntry(this.sheetRustdeskTotpEntryId);
    return entry === undefined ? '绑定条目已不存在，请重新选择' :
      '已绑定：' + entry.displayLabel();
  }

  /**
   * 2FA 绑定单独使用统一安全 Sheet。先让编辑 Sheet 完整退场，再挂载
   * 绑定 Sheet，避免两个 native bindSheet 同时争抢宿主导致错位/复活。
   */
  private openRustDeskTotpBinding(): void {
    if (this.proto !== 'rustdesk') {
      return;
    }
    this.beginRustDeskTotpBinding(false);
  }

  private openRustDeskTotpBindingFromModern(draft: RustDeskHostAddDraft): void {
    this.proto = 'rustdesk';
    this.modernAddProtocol = 'rustdesk';
    this.addSheetShowsModernPicker = false;
    this.sheetRustdeskTotpEntryId = draft.totpEntryId;
    this.sheetRustdeskTotpAutoSubmit = draft.totpAutoSubmit && draft.totpEntryId !== '';
    this.rustDeskAddResumeDraft = draft;
    this.rustDeskAddResumeRevision++;
    this.beginRustDeskTotpBinding(true);
  }

  private beginRustDeskTotpBinding(returnToModernAdd: boolean): void {
    if (this.rustDeskTotpBindingClosing ||
      this.remoteHostSheetClosing || this.showRemoteHostSheet) {
      return;
    }
    if (this.keyVault.getAllTotpEntries().length === 0) {
      promptAction.showToast({ message: '请先在“2FA 验证器”中添加条目', duration: 2200 });
      return;
    }
    const generation: number = this.rustDeskTotpBindingGeneration + 1;
    this.rustDeskTotpBindingGeneration = generation;
    this.rustDeskTotpBindingClosing = false;
    this.rustDeskTotpBindingReturnToAddSheet = this.showAddSheet;
    this.rustDeskTotpBindingReturnToModernAdd = returnToModernAdd && this.showAddSheet;
    this.rustDeskTotpBindingPendingOpen = this.showAddSheet;
    this.preserveFormOnAddSheetDisappear = this.showAddSheet;
    if (this.showAddSheet) {
      this.requestAddSheetClose();
      return;
    }
    this.openSheetSafely((): void => {
      if (this.rustDeskTotpBindingGeneration !== generation ||
        this.rustDeskTotpBindingClosing) {
        return;
      }
      this.openRemoteHostSheet(REMOTE_HOST_SHEET_RUSTDESK_TOTP_BINDING, (): void => {});
    }, true);
  }

  private closeRustDeskTotpBinding(closeSheet: boolean = true): void {
    this.rustDeskTotpBindingGeneration += 1;
    this.rustDeskTotpBindingClosing = true;
    this.beginRemoteHostSheetClose(REMOTE_HOST_SHEET_RUSTDESK_TOTP_BINDING);
    if (closeSheet) {
      this.showRemoteHostSheet = false;
    }
  }

  private updateRustDeskTotpResumeDraft(entryId: string, autoSubmit: boolean): void {
    if (!this.rustDeskTotpBindingReturnToModernAdd || this.rustDeskAddResumeDraft === null) {
      return;
    }
    this.rustDeskAddResumeDraft.totpEntryId = entryId;
    this.rustDeskAddResumeDraft.totpAutoSubmit = autoSubmit && entryId !== '';
    this.rustDeskAddResumeRevision++;
  }

  private async bindRustDeskTotpEntry(entryId: string): Promise<void> {
    const generation: number = this.rustDeskTotpBindingGeneration;
    if (!this.isCurrentRustDeskTotpBinding(generation)) {
      return;
    }
    const entry: TotpEntry | undefined = this.keyVault.getTotpEntry(entryId);
    if (entry === undefined) {
      promptAction.showToast({ message: '2FA 条目不存在或已被删除', duration: 2200 });
      return;
    }
    if (this.totpPageLocked) {
      const gate: LockGateResult = await showLockGate(
        'TOTP 隐私保护已开启，请验证系统身份后绑定 RustDesk 2FA', 'biometric');
      if (!this.isCurrentRustDeskTotpBinding(generation)) {
        return;
      }
      if (!gate.ok) {
        const detail: string = lockGateErrorMessage(gate);
        let message: string =
          'TOTP 隐私保护已开启，绑定 RustDesk 2FA 前需要完成系统身份认证。';
        if (gate.code === 12500010) {
          message = 'TOTP 隐私保护已开启，但系统尚未录入 PIN、指纹或人脸。请先到系统设置完成锁屏认证，或关闭 TOTP 隐私保护后再绑定。';
        } else if (gate.code === 12500003) {
          message = 'TOTP 隐私保护已开启，系统身份认证已取消，RustDesk 2FA 未绑定。';
        } else if (detail !== '') {
          message += '（' + detail + '）';
        }
        promptAction.showToast({ message: message, duration: 3000 });
        return;
      }
    }
    if (this.editingHostId !== '') {
      const current: RemoteHost | undefined = this.srv.getHost(this.editingHostId);
      if (current === undefined || current.protocol !== 'rustdesk') {
        promptAction.showToast({ message: '主机已不存在，请重新打开编辑', duration: 2200 });
        return;
      }
      // A successful binding is immediately usable on the next connection.
      // The user can turn this off from the compact binding row afterwards.
      if (!this.srv.setRustDeskPeerTwoFactorBinding(current.id, entry.id, true)) {
        promptAction.showToast({ message: 'RustDesk 2FA 绑定保存失败', duration: 2200 });
        return;
      }
    }
    this.sheetRustdeskTotpEntryId = entry.id;
    this.sheetRustdeskTotpAutoSubmit = true;
    this.updateRustDeskTotpResumeDraft(entry.id, true);
    promptAction.showToast({
      message: this.editingHostId !== '' ?
        'RustDesk 2FA 已绑定' : 'RustDesk 2FA 已选择，保存主机后生效',
      duration: 1800
    });
    this.closeRustDeskTotpBinding(true);
  }

  private clearRustDeskTotpBinding(): void {
    if (this.rustDeskTotpBindingClosing) { return; }
    if (this.editingHostId !== '') {
      const current: RemoteHost | undefined = this.srv.getHost(this.editingHostId);
      if (current !== undefined && current.protocol === 'rustdesk') {
        if (!this.srv.clearRustDeskPeerTwoFactorBinding(current.id)) {
          promptAction.showToast({ message: '解除 RustDesk 2FA 绑定失败', duration: 2200 });
          return;
        }
      }
    }
    this.sheetRustdeskTotpEntryId = '';
    this.sheetRustdeskTotpAutoSubmit = false;
    this.updateRustDeskTotpResumeDraft('', false);
    promptAction.showToast({
      message: this.editingHostId !== '' ?
        'RustDesk 2FA 已解除绑定' : '已从新增主机草稿移除 RustDesk 2FA',
      duration: 1800
    });
    this.closeRustDeskTotpBinding(true);
  }

  private onRustDeskTotpAutoSubmitChange(enabled: boolean): void {
    if (this.sheetRustdeskTotpEntryId === '') {
      this.sheetRustdeskTotpAutoSubmit = false;
      return;
    }
    this.sheetRustdeskTotpAutoSubmit = enabled;
    if (this.editingHostId === '') { return; }
    const current: RemoteHost | undefined = this.srv.getHost(this.editingHostId);
    if (current === undefined || current.protocol !== 'rustdesk') { return; }
    if (!this.srv.setRustDeskPeerTwoFactorBinding(
      current.id, this.sheetRustdeskTotpEntryId, enabled)) {
      this.sheetRustdeskTotpAutoSubmit = !enabled;
      promptAction.showToast({ message: '自动提交设置保存失败', duration: 2200 });
    }
  }

  private handleRustDeskTotpBindingSheetDisappear(): void {
    this.noteSheetDismissed();
    const shouldReturnToAddSheet: boolean = this.rustDeskTotpBindingReturnToAddSheet;
    const returnToModernAdd: boolean = this.rustDeskTotpBindingReturnToModernAdd;
    const generation: number = this.rustDeskTotpBindingGeneration;
    this.rustDeskTotpBindingReturnToAddSheet = false;
    this.rustDeskTotpBindingReturnToModernAdd = false;
    this.rustDeskTotpBindingPendingOpen = false;
    this.rustDeskTotpBindingClosing = false;
    if (!shouldReturnToAddSheet || !this.pageActive) {
      return;
    }
    // 父级 onDisappear 还要先释放统一 Sheet 宿主，下一轮再恢复编辑 Sheet。
    setTimeout((): void => {
      if (!this.pageActive || this.rustDeskTotpBindingGeneration !== generation ||
        this.showRemoteHostSheet || this.remoteHostSheetClosing || this.showAddSheet) {
        return;
      }
      this.addSheetShowsModernPicker = false;
      this.modernAddProtocol = returnToModernAdd ? 'rustdesk' : '';
      this.vncAddFromModernPicker = false;
      this.openSheetSafely((): void => {
        if (this.rustDeskTotpBindingGeneration === generation &&
          !this.rustDeskTotpBindingClosing) {
          this.showAddSheet = true;
        }
      });
    }, 0);
  }

  private isCurrentSshPreflight(host: RemoteHost, generation: number): boolean {
    return !this.sshPreflightClosing && this.sshPreflightGeneration === generation &&
      this.sshPreflightHostId === host.id;
  }

  private saveHostFromAddFlow(host: RemoteHost, connectNow: boolean, restrictedAdminHash: string = ''): void {
    if (!shouldAcceptHostAddSave(this.addSheetClosing, this.pendingAddSheetConnectHostId)) {
      hilog.info(0x0001, 'HostList', 'ignored repeated add-host save while Sheet is closing');
      return;
    }
    const requiresLocalRestrictedAdminHash: boolean = host.protocol === 'rdp' &&
      host.rdpAuthMode === 'restricted_admin' &&
      host.rdpRestrictedAdminSecretSource === 'ntlm_hash';
    const rustDeskTotpEntryId: string = host.protocol === 'rustdesk' ?
      host.rustdeskTotpEntryId.trim() : '';
    const rustDeskTotpAutoSubmit: boolean = host.protocol === 'rustdesk' &&
      host.rustdeskTotpAutoSubmit && rustDeskTotpEntryId !== '';
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
    if (host.protocol === 'rustdesk' && rustDeskTotpEntryId !== '' &&
      !this.srv.setRustDeskPeerTwoFactorBinding(
        host.id, rustDeskTotpEntryId, rustDeskTotpAutoSubmit)) {
      const rolledBack: boolean = this.srv.removeHost(host.id);
      promptAction.showToast({
        message: rolledBack ?
          'RustDesk 2FA 绑定保存失败，主机新增已撤销，请重试' :
          'RustDesk 2FA 绑定保存失败，且主机回滚未完成；请返回列表检查',
        duration: 3000
      });
      return;
    }
    this.refreshHostSnapshotAfterMutation();
    this.pendingAddSheetConnectHostId = pendingHostIdForHostAddSave(connectNow, host.id);
    this.requestAddSheetClose();
  }

  private saveSshHostFromAddFlow(host: RemoteHost, connectNow: boolean,
    proxyProfile: SshProxyProfileV1): void {
    if (!shouldAcceptHostAddSave(this.addSheetClosing, this.pendingAddSheetConnectHostId)) {
      hilog.info(0x0001, 'HostList', 'ignored repeated SSH add-host save while Sheet is closing');
      return;
    }
    if (host.protocol !== 'ssh' || proxyProfile.hostId !== host.id ||
      !this.sshProxyProfiles.upsert(proxyProfile)) {
      promptAction.showToast({ message: 'SSH 连接方式保存失败，未写入主机', duration: 2200 });
      return;
    }
    if (!this.srv.addHost(host)) {
      this.sshProxyProfiles.remove(host.id);
      promptAction.showToast({ message: '保存主机失败，请稍后重试', duration: 1800 });
      return;
    }
    this.refreshHostSnapshotAfterMutation();
    this.pendingAddSheetConnectHostId = pendingHostIdForHostAddSave(connectNow, host.id);
    this.requestAddSheetClose();
  }

  private prepareVncAddFlow(): void {
    const context: common.Context = getContext(this) as common.Context;
    this.vncSettings.init(context);
    this.vncHosts.init(context);
    this.vncGateways.init(context);
    this.vncTrust.init(context);
  }

  private saveVncHostFromAddFlow(values: VncHostValues, password: string, connectNow: boolean,
    plainStorageConfirmed: boolean = false): void {
    if (this.addSheetClosing || this.pendingAddSheetConnectHostId !== '' ||
      this.pendingVncConnectHostId !== '') {
      hilog.info(0x0001, 'HostList', 'ignored repeated VNC add-host save while Sheet is closing');
      return;
    }
    if (!this.vncHosts.isReady()) {
      promptAction.showToast({ message: 'VNC 服务尚未完成云同步初始化，请稍后重试', duration: 2200 });
      return;
    }
    const result = this.vncHosts.save(values, '', password, plainStorageConfirmed);
    if (!result.ok) {
      promptAction.showToast({ message: result.message || '保存 VNC 主机失败', duration: 2200 });
      return;
    }
    this.refreshHostSnapshotAfterMutation();
    this.pendingVncConnectHostId = connectNow ? result.id : '';
    if (connectNow && !values.rememberPassword && password.length > 0) {
      VncSessionCredentialHandoff.getInstance().put(this.vncHosts.currentUserId(), result.id, password);
    }
    promptAction.showToast({
      message: connectNow ? 'VNC 主机已保存，正在准备连接' : 'VNC 主机已保存',
      duration: 1800
    });
    this.requestAddSheetClose();
  }

  private invalidateMoonlightCatalogHandoff(): void {
    this.moonlightCatalogHandoffGeneration += 1;
    this.pendingMoonlightCatalogHandoff = emptyHostAddPostSaveHandoff();
  }

  private refreshMoonlightDirectory(): void {
    const lease: AccountSessionLease | null = CloudStore.getInstance().currentAccountLease();
    if (lease === null || !CloudStore.getInstance().isLeaseCurrent(lease)) {
      this.moonlightDirectoryOwnerScopeId = '';
      this.moonlightDirectoryAccountGeneration = 0;
      this.moonlightDirectoryStoreInstanceId = 0;
      this.moonlightDirectoryCode = 'account_scope_unavailable';
      this.moonlightHosts = [];
      return;
    }
    const sameScope: boolean =
      lease.ownerScopeId === this.moonlightDirectoryOwnerScopeId &&
      lease.generation === this.moonlightDirectoryAccountGeneration &&
      lease.storeInstanceId === this.moonlightDirectoryStoreInstanceId;
    this.moonlightDirectoryOwnerScopeId = lease.ownerScopeId;
    this.moonlightDirectoryAccountGeneration = lease.generation;
    this.moonlightDirectoryStoreInstanceId = lease.storeInstanceId;
    const directory: MoonlightHostDirectoryView =
      this.moonlightLocalViewService.loadHosts(Date.now());
    this.moonlightDirectoryCode = directory.code;
    if (directory.ok) {
      this.moonlightHosts = directory.hosts.slice();
    } else if (!sameScope) {
      // Never carry cards across accounts/stores. A transient read failure in
      // the same local database keeps the last known-good cards, matching the
      // other protocol lists instead of flashing an empty Moonlight section.
      this.moonlightHosts = [];
    }
  }

  private visibleMoonlightHosts(): MoonlightHostLocalView[] {
    const query: string = this.searchText.trim().toLowerCase();
    if (query === '') { return this.moonlightHosts.slice(); }
    return this.moonlightHosts.filter((view: MoonlightHostLocalView): boolean => {
      const host: MoonlightHost | null = view.host;
      if (host === null) { return false; }
      if (host.displayName.toLowerCase().indexOf(query) >= 0 ||
          host.serverUuid.toLowerCase().indexOf(query) >= 0) { return true; }
      for (let index: number = 0; index < host.addresses.length; index++) {
        if (host.addresses[index].host.toLowerCase().indexOf(query) >= 0) { return true; }
      }
      return false;
    });
  }

  private flatHostCardRefs(): UnifiedHostCardRef[] {
    const remoteIds: string[] = [];
    const moonlightIds: string[] = [];
    const desktopProtocolTab: boolean = this.isDesktopDevice && this.breakpoint === 'xl';
    if (!desktopProtocolTab || this.curTab !== DESKTOP_MOONLIGHT_TAB) {
      for (let index: number = 0; index < this.filteredHosts.length; index++) {
        remoteIds.push(this.filteredHosts[index].id);
      }
    }
    // Phone/Pad unclassified mode is one host collection. On desktop, the
    // dedicated protocol tabs still filter that same collection and only the
    // Moonlight tab receives Moonlight rows. A workspace chip excludes
    // Moonlight because Moonlight currently has no workspace-group field.
    if ((desktopProtocolTab && this.curTab === DESKTOP_MOONLIGHT_TAB) ||
        (!desktopProtocolTab && this.workspaceGroupId === '')) {
      const views: MoonlightHostLocalView[] = this.visibleMoonlightHosts();
      for (let index: number = 0; index < views.length; index++) {
        if (views[index].host !== null) { moonlightIds.push((views[index].host as MoonlightHost).id); }
      }
    }
    return buildUnifiedHostCardRefs(remoteIds, moonlightIds, this.hostManualOrder);
  }

  private allHostCardRefsForOrder(): UnifiedHostCardRef[] {
    const remoteIds: string[] = this.hosts.map((host: RemoteHost): string => host.id);
    const moonlightIds: string[] = [];
    for (let index: number = 0; index < this.moonlightHosts.length; index++) {
      if (this.moonlightHosts[index].host !== null) {
        moonlightIds.push((this.moonlightHosts[index].host as MoonlightHost).id);
      }
    }
    return buildUnifiedHostCardRefs(remoteIds, moonlightIds, this.hostManualOrder);
  }

  private remoteHostForCardRef(ref: UnifiedHostCardRef): RemoteHost | null {
    if (ref.kind !== 'remote') { return null; }
    const host: RemoteHost | undefined = this.filteredHosts.find(
      (candidate: RemoteHost): boolean => candidate.id === ref.hostId);
    return host === undefined ? null : host;
  }

  private moonlightViewForCardRef(ref: UnifiedHostCardRef): MoonlightHostLocalView | null {
    if (ref.kind !== 'moonlight') { return null; }
    const view: MoonlightHostLocalView | undefined = this.visibleMoonlightHosts().find(
      (candidate: MoonlightHostLocalView): boolean =>
        candidate.host !== null && candidate.host.id === ref.hostId);
    return view === undefined ? null : view;
  }

  private selectionKeysForCurrentView(): string[] {
    if (!this.groupedHostCardsActive()) {
      return this.flatHostCardRefs().map((ref: UnifiedHostCardRef): string => ref.key);
    }
    const keys: string[] = this.filteredHosts.map(
      (host: RemoteHost): string => remoteHostCardKey(host.id));
    const moonlight: MoonlightHostLocalView[] = this.visibleMoonlightHosts();
    for (let index: number = 0; index < moonlight.length; index++) {
      if (moonlight[index].host !== null) {
        keys.push(unifiedMoonlightHostCardKey((moonlight[index].host as MoonlightHost).id));
      }
    }
    return keys;
  }

  private beginHostSelection(selectionKey: string, reorderEnabled: boolean,
    preserveActiveDrag: boolean = false): void {
    const currentOrder: string[] = this.flatHostCardRefs().map(
      (ref: UnifiedHostCardRef): string => ref.key);
    this.hostReorderOriginalOrder = this.hostManualOrder.slice();
    if (reorderEnabled) {
      this.hostManualOrder = mergeVisibleHostOrder(
        this.hostManualOrder, currentOrder, currentOrder);
    }
    if (preserveActiveDrag) {
      // onDragStart already owns a live platform drag session. Re-keying the
      // ForEach here would destroy its source ListItem before onDrop. @State
      // updates are enough to reveal selection controls without replacing the
      // card identity; the final drop performs the ordered revision refresh.
      this.hostSelectionMode = true;
      this.hostReorderEnabled = reorderEnabled;
      this.hostSelectedIds = selectionKey === ''
        ? new Set<string>() : new Set<string>([selectionKey]);
      return;
    }
    animateTo({ duration: 250, curve: Curve.FastOutSlowIn }, (): void => {
      this.hostSelectionMode = true;
      this.hostReorderEnabled = reorderEnabled;
      this.hostSelectedIds = selectionKey === ''
        ? new Set<string>() : new Set<string>([selectionKey]);
      this.hostViewRevision += 1;
    });
  }

  private moonlightHostCardKey(view: MoonlightHostLocalView): string {
    const hostId: string = view.host?.id || 'invalid-moonlight-host';
    const displayName: string = view.host?.displayName || '';
    const preferredAddressKey: string =
      view.host?.preferredAddressKey || '';
    const userOrder: number = view.host?.userOrder || 0;
    let newestCatalogAt: number = 0;
    let availableCount: number = 0;
    for (let index: number = 0; index < view.catalogItems.length; index++) {
      newestCatalogAt = Math.max(newestCatalogAt, view.catalogItems[index].lastCatalogAt);
      if (view.catalogItems[index].available && !view.catalogItems[index].stale) {
        availableCount++;
      }
    }
    return hostId + ':' + view.updatedAt.toString() + ':' +
      displayName + ':' + preferredAddressKey + ':' + userOrder.toString() + ':' +
      (view.host?.locked === true ? 'locked' : 'unlocked') + ':' +
      (view.paired ? 'paired' : 'unpaired') + ':' +
      view.catalogItems.length.toString() + ':' + availableCount.toString() + ':' +
      newestCatalogAt.toString();
  }

  private moonlightAddressLabel(host: MoonlightHost): string {
    const selected: MoonlightAddress | null = this.moonlightPreferredAddress(host);
    return selected === null ? '未保存地址' : selected.host + ':' + selected.port.toString();
  }

  private moonlightPreferredAddress(host: MoonlightHost): MoonlightAddress | null {
    if (host.addresses.length === 0) { return null; }
    let selected: MoonlightAddress = host.addresses[0];
    for (let index: number = 0; index < host.addresses.length; index++) {
      const address: MoonlightAddress = host.addresses[index];
      if (moonlightAddressKey(address) === host.preferredAddressKey) {
        selected = address;
        break;
      }
    }
    return selected;
  }

  private moonlightAddressFamily(value: string): MoonlightAddressFamily {
    const host: string = value.trim();
    if (host.indexOf(':') >= 0) { return 'ipv6'; }
    return /^\d{1,3}(\.\d{1,3}){3}$/.test(host) ? 'ipv4' : 'hostname';
  }

  private protectedMoonlightCardValue(host: MoonlightHost, visibleValue: string): string {
    return hostCardSensitiveValue(shouldHideHostCardSensitiveInfo(
      this.hostCardSensitiveInfoHidden, host.locked === true), visibleValue);
  }

  private async openMoonlightHost(hostId: string, catalog: boolean = false): Promise<void> {
    const params: Record<string, Object> | null = moonlightHostRouteParams(hostId);
    if (params === null) { return; }
    const view: MoonlightHostLocalView | undefined = this.moonlightHosts.find(
      (candidate: MoonlightHostLocalView): boolean =>
        candidate.host !== null && candidate.host.id === hostId);
    if (view === undefined || view.host === null) { return; }
    if (view.host.locked === true) {
      const gate: LockGateResult = await showLockGate(view.host.displayName, 'biometric');
      if (!gate.ok) {
        const message: string = lockGateErrorMessage(gate);
        if (message !== '') { promptAction.showToast({ message: message, duration: 2000 }); }
        return;
      }
    }
    if (!this.pageActive) { return; }
    // A card tap is an in-place expansion, matching the RDP/RustDesk/SSH/VNC
    // host-list contract.  Full pages remain explicit actions from the Sheet
    // (catalog/settings), never an implicit card navigation.
    if (!catalog) {
      this.openMoonlightHostSheet(hostId);
      return;
    }
    this.openMoonlightCatalogSheet(hostId);
  }

  private handleMoonlightHostCardClick(hostId: string, catalog: boolean = false): void {
    const key: string = unifiedMoonlightHostCardKey(hostId);
    if (this.hostSelectionMode) {
      this.toggleHostSelect(key, !this.hostSelectedIds.has(key));
      return;
    }
    void this.openMoonlightHost(hostId, catalog);
  }

  private async openMoonlightEditSheet(view: MoonlightHostLocalView): Promise<void> {
    if (view.host === null || this.remoteHostSheetClosing || this.showRemoteHostSheet ||
        this.addSheetClosing) { return; }
    const hostId: string = view.host.id;
    // Swipe actions must obey the same lock boundary as a card tap. Reload the
    // latest local record first so a stale rendered card cannot bypass a lock
    // that was just enabled on another surface.
    this.refreshMoonlightDirectory();
    let current: MoonlightHostLocalView | undefined = this.moonlightHosts.find(
      (candidate: MoonlightHostLocalView): boolean =>
        candidate.host !== null && candidate.host.id === hostId);
    if (current === undefined || current.host === null) { return; }
    if (current.host.locked === true) {
      const gate: LockGateResult = await showLockGate(current.host.displayName, 'biometric');
      if (!gate.ok) {
        const message: string = lockGateErrorMessage(gate);
        if (message !== '') { promptAction.showToast({ message: message, duration: 2000 }); }
        return;
      }
    }
    if (!this.pageActive || this.remoteHostSheetClosing || this.showRemoteHostSheet ||
        this.addSheetClosing) { return; }
    this.refreshMoonlightDirectory();
    current = this.moonlightHosts.find(
      (candidate: MoonlightHostLocalView): boolean =>
        candidate.host !== null && candidate.host.id === hostId);
    if (current === undefined || current.host === null) { return; }
    const preferred: MoonlightAddress | null = this.moonlightPreferredAddress(current.host);
    this.moonlightSheetHostId = hostId;
    this.moonlightEditName = current.host.displayName;
    this.moonlightEditAddress = preferred === null ? '' : preferred.host;
    this.moonlightEditPortText = preferred === null ? '47989' : preferred.port.toString();
    this.moonlightEditHttpsPortText = (current.host.httpsPort === undefined
      ? MOONLIGHT_DEFAULT_HTTPS_PORT : current.host.httpsPort).toString();
    this.moonlightEditHostType = current.host.hostType;
    this.moonlightEditWakeEnabled = current.host.wakeOnLan.enabled;
    this.moonlightEditWakeMac = current.host.wakeOnLan.mac;
    this.moonlightEditWakeBroadcast = current.host.wakeOnLan.broadcast;
    this.moonlightEditError = '';
    this.openSheetSafely((): void => {
      if (!this.pageActive || this.moonlightSheetHostId !== hostId) { return; }
      this.openRemoteHostSheet(REMOTE_HOST_SHEET_MOONLIGHT_EDIT, (): void => {});
    }, true);
  }

  private saveMoonlightEdit(): void {
    const hostId: string = this.moonlightSheetHostId;
    const view: MoonlightHostLocalView | null = this.moonlightSheetView();
    if (view === null || view.host === null || view.host.id !== hostId) {
      this.moonlightEditError = '主机记录已变化，请关闭后重试';
      return;
    }
    const port: number = Number(this.moonlightEditPortText);
    const httpsPort: number = Number(this.moonlightEditHttpsPortText);
    if (this.moonlightEditName.trim() === '' || this.moonlightEditName.trim().length > 128) {
      this.moonlightEditError = '主机名称需为 1–128 个字符';
      return;
    }
    if (this.moonlightEditAddress.trim() === '') {
      this.moonlightEditError = '请输入 Sunshine / GameStream 主机地址';
      return;
    }
    if (!Number.isSafeInteger(port) || port < 1 || port > 65535 ||
        !Number.isSafeInteger(httpsPort) || httpsPort < 1 || httpsPort > 65535) {
      this.moonlightEditError = '端口必须在 1–65535 之间';
      return;
    }
    if (this.moonlightEditWakeEnabled) {
      if (!/^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$/.test(this.moonlightEditWakeMac.trim())) {
        this.moonlightEditError = 'MAC 地址格式应为 AA:BB:CC:DD:EE:FF';
        return;
      }
      if (this.moonlightEditWakeBroadcast.trim() === '') {
        this.moonlightEditError = '启用网络唤醒后必须填写广播地址';
        return;
      }
    }
    const current: MoonlightHost = view.host;
    const previousPreferred: MoonlightAddress | null = this.moonlightPreferredAddress(current);
    const preferred: MoonlightAddress = {
      host: this.moonlightEditAddress.trim(),
      family: this.moonlightAddressFamily(this.moonlightEditAddress),
      port: port
    };
    const addresses: MoonlightAddress[] = [];
    let replaced: boolean = false;
    for (let index: number = 0; index < current.addresses.length; index++) {
      const address: MoonlightAddress = current.addresses[index];
      if (!replaced && previousPreferred !== null &&
          moonlightAddressKey(address) === moonlightAddressKey(previousPreferred)) {
        addresses.push(preferred);
        replaced = true;
      } else {
        addresses.push({ host: address.host, family: address.family, port: address.port });
      }
    }
    if (!replaced) { addresses.push(preferred); }
    const edited: MoonlightHost = {
      id: current.id,
      serverUuid: current.serverUuid,
      displayName: this.moonlightEditName.trim(),
      addresses: addresses,
      preferredAddressKey: moonlightAddressKey(preferred),
      httpsPort: httpsPort,
      hostType: this.moonlightEditHostType,
      wakeOnLan: {
        enabled: this.moonlightEditWakeEnabled,
        mac: this.moonlightEditWakeMac.trim(),
        broadcast: this.moonlightEditWakeBroadcast.trim()
      },
      locked: current.locked === true,
      userOrder: current.userOrder
    };
    const result: MoonlightLocalHostMutationResult =
      this.moonlightLocalHostService.updateHost(edited, Date.now());
    if (!result.ok) {
      this.moonlightEditError = result.errorText || 'Moonlight 主机配置保存失败';
      return;
    }
    this.refreshMoonlightDirectory();
    this.hostViewRevision += 1;
    this.beginRemoteHostSheetClose(REMOTE_HOST_SHEET_MOONLIGHT_EDIT);
    this.showRemoteHostSheet = false;
    promptAction.showToast({ message: 'Moonlight 主机配置已保存', duration: 1600 });
  }

  private async toggleMoonlightLock(view: MoonlightHostLocalView): Promise<void> {
    if (view.host === null) { return; }
    const gate: LockGateResult = await showLockGate(view.host.displayName, 'biometric');
    if (!gate.ok) {
      const message: string = lockGateErrorMessage(gate);
      if (message !== '') { promptAction.showToast({ message: message, duration: 2000 }); }
      return;
    }
    const nextLocked: boolean = view.host.locked !== true;
    const result: MoonlightLocalHostMutationResult = this.moonlightLocalHostService.updateLocked(
      view.host.id, nextLocked, Date.now());
    if (!result.ok) {
      promptAction.showToast({ message: result.errorText || '保存主机状态失败', duration: 2200 });
      return;
    }
    this.refreshMoonlightDirectory();
    this.hostViewRevision += 1;
    promptAction.showToast({ message: nextLocked ? '已锁定' : '已解锁', duration: 1500 });
  }

  private async doDeleteMoonlightHost(view: MoonlightHostLocalView): Promise<void> {
    if (view.host === null) { return; }
    const hostId: string = view.host.id;
    const hostName: string = view.host.displayName;
    if (view.host.locked === true) {
      const gate: LockGateResult = await showLockGate(hostName, 'biometric');
      if (!gate.ok) {
        const message: string = lockGateErrorMessage(gate);
        if (message !== '') { promptAction.showToast({ message: message, duration: 2000 }); }
        return;
      }
    }
    const lease: AccountSessionLease | null = this.moonlightDeletionRuntime.currentLease();
    if (lease === null || !this.moonlightDeletionRuntime.isLeaseCurrent(lease)) {
      promptAction.showToast({ message: '当前账号数据域已变化，请刷新后重试', duration: 2200 });
      return;
    }
    const preview: MoonlightDeletionPreview = this.moonlightDeletionRuntime.preview(
      lease, 'forget_host', hostId);
    if (preview.code !== 'ok') {
      promptAction.showToast({
        message: preview.code === 'cloud_unavailable' ?
          'Moonlight 云端状态尚未就绪，未删除任何数据' :
          '主机数据已变化，请刷新后重试：' + preview.code,
        duration: 2400
      });
      return;
    }
    const dialogResult: Object = await promptAction.showDialog({
      title: '确认删除',
      message: '确定要删除 Moonlight 主机“' + hostName + '”吗？将同时清理本机配对信任、应用配置和目录缓存。',
      buttons: [
        { text: '取消', color: this.pal().text2 },
        { text: '删除', color: this.pal().danger }
      ]
    });
    const selected: Record<string, number> = dialogResult as Record<string, number>;
    if (selected['index'] !== 1 || !this.pageActive) { return; }
    const currentLease: AccountSessionLease | null = this.moonlightDeletionRuntime.currentLease();
    if (currentLease === null || !accountSessionLeaseEquals(currentLease, lease) ||
        !this.moonlightDeletionRuntime.isLeaseCurrent(lease)) {
      promptAction.showToast({ message: '账号状态已变化，未执行删除', duration: 2200 });
      return;
    }
    const result: MoonlightDeletionCommandResult =
      await this.moonlightDeletionRuntime.execute(lease, preview);
    if (!this.pageActive) { return; }
    if (result.ok) {
      const key: string = unifiedMoonlightHostCardKey(hostId);
      this.hostManualOrder = this.hostManualOrder.filter(
        (stored: string): boolean => stored !== key);
      this.persistHostManualOrder();
    }
    this.refreshMoonlightDirectory();
    this.hostViewRevision += 1;
    promptAction.showToast({
      message: result.ok ? (result.code === 'pending_cloud' ?
        '本机主机已删除，云端删除标记正在安全上传' : 'Moonlight 主机已删除') :
        '删除失败：' + result.code,
      duration: 2400
    });
  }

  private moonlightSheetView(): MoonlightHostLocalView | null {
    if (this.moonlightSheetHostId === '') { return null; }
    for (let index: number = 0; index < this.moonlightHosts.length; index++) {
      const view: MoonlightHostLocalView = this.moonlightHosts[index];
      if (view.host !== null && view.host.id === this.moonlightSheetHostId) {
        return view;
      }
    }
    return null;
  }

  private openMoonlightHostSheet(hostId: string): void {
    if (hostId.trim() === '' || this.remoteHostSheetClosing ||
        this.showRemoteHostSheet || this.addSheetClosing) {
      return;
    }
    const view: MoonlightHostLocalView | null = this.moonlightHosts.find(
      (candidate: MoonlightHostLocalView): boolean =>
        candidate.host !== null && candidate.host.id === hostId) ?? null;
    if (view === null || view.host === null) { return; }
    this.moonlightSheetHostId = hostId;
    this.openSheetSafely((): void => {
      if (!this.pageActive || this.moonlightSheetHostId !== hostId) { return; }
      this.openRemoteHostSheet(REMOTE_HOST_SHEET_MOONLIGHT_DETAIL, (): void => {});
    }, true);
  }

  private openMoonlightCatalogSheet(hostId: string): void {
    if (hostId.trim() === '' || this.remoteHostSheetClosing ||
        this.showRemoteHostSheet || this.addSheetClosing) {
      return;
    }
    const view: MoonlightHostLocalView | null = this.moonlightHosts.find(
      (candidate: MoonlightHostLocalView): boolean =>
        candidate.host !== null && candidate.host.id === hostId) ?? null;
    if (view === null || view.host === null) { return; }
    this.moonlightSheetHostId = hostId;
    this.moonlightCatalogReturnsToDetail = false;
    this.moonlightCatalogDismissAllowed = true;
    this.openSheetSafely((): void => {
      if (!this.pageActive || this.moonlightSheetHostId !== hostId) { return; }
      this.openRemoteHostSheet(REMOTE_HOST_SHEET_MOONLIGHT_CATALOG, (): void => {});
    }, true);
  }

  private openMoonlightHostSettings(hostId: string): void {
    this.openMoonlightSettingsSheet(hostId, SETTINGS_SHEET_MOONLIGHT_VIDEO);
  }

  private openMoonlightSettingsSheet(hostId: string, mode: number): void {
    const spec: MoonlightSettingsRouteSpec | null = moonlightSettingsRouteSpec(mode);
    if (hostId.trim() === '' || spec === null || spec.owner !== 'moonlight' || !this.pageActive) {
      return;
    }
    const view: MoonlightHostLocalView | null = this.moonlightHosts.find(
      (candidate: MoonlightHostLocalView): boolean =>
        candidate.host !== null && candidate.host.id === hostId) ?? null;
    if (view === null || view.host === null) { return; }
    this.moonlightSettingsLeafHostId = hostId;
    this.openSettingsLeafSheet(mode);
  }

  private closeMoonlightCatalogSheet(navigation: string = ''): void {
    if (this.remoteHostSheetMode !== REMOTE_HOST_SHEET_MOONLIGHT_CATALOG ||
        this.moonlightSheetHostId === '') {
      return;
    }
    if ((navigation === 'detail' ||
        (navigation === '' && this.moonlightCatalogReturnsToDetail)) &&
        this.showRemoteHostSheet && !this.remoteHostSheetClosing) {
      this.moonlightCatalogReturnsToDetail = false;
      this.pendingMoonlightCatalogNavigation = '';
      this.pendingMoonlightCatalogLaunch = null;
      this.moonlightCatalogDismissAllowed = true;
      this.remoteHostSheetMode = REMOTE_HOST_SHEET_MOONLIGHT_DETAIL;
      hilog.info(0x0001, 'Moonlight', 'catalog returned to host detail in shared Sheet');
      return;
    }
    this.moonlightCatalogReturnsToDetail = false;
    this.moonlightCatalogDismissAllowed = true;
    this.pendingMoonlightCatalogNavigation = navigation;
    this.beginRemoteHostSheetClose(REMOTE_HOST_SHEET_MOONLIGHT_CATALOG);
    this.showRemoteHostSheet = false;
  }

  private requestMoonlightCatalogLaunch(handoff: MoonlightCatalogLaunchHandoff): void {
    if (this.remoteHostSheetMode !== REMOTE_HOST_SHEET_MOONLIGHT_CATALOG ||
        this.moonlightSheetHostId === '' ||
        handoff.hostId !== this.moonlightSheetHostId) {
      this.rejectMoonlightCatalogLaunch(handoff);
      return;
    }
    // Store launch ownership before hiding the outer Catalog Sheet. Actual
    // navigation is drained only by that Sheet's onDisappear callback.
    this.pendingMoonlightCatalogLaunch = handoff;
    this.closeMoonlightCatalogSheet('launch');
  }

  private rejectMoonlightCatalogLaunch(handoff: MoonlightCatalogLaunchHandoff): void {
    try {
      const context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
      rejectMoonlightCatalogLaunchHandoff(context, handoff);
    } catch (_error) {
      this.moonlightHostService.disposeOwner(handoff.ownerToken);
    }
  }

  private async presentMoonlightCatalogLaunch(
    handoff: MoonlightCatalogLaunchHandoff
  ): Promise<void> {
    let context: common.UIAbilityContext;
    try {
      context = getContext(this) as common.UIAbilityContext;
    } catch (_error) {
      this.moonlightHostService.disposeOwner(handoff.ownerToken);
      return;
    }
    if (!this.pageActive) {
      rejectMoonlightCatalogLaunchHandoff(context, handoff);
      return;
    }
    const opened: boolean = await presentMoonlightCatalogLaunchHandoff(
      context, this.isDesktopDevice, handoff);
    if (opened) { return; }
    rejectMoonlightCatalogLaunchHandoff(context, handoff);
    if (this.pageActive) {
      promptAction.showToast({ message: '无法打开 Moonlight 串流窗口，启动租约已安全释放', duration: 2200 });
    }
  }

  private closeMoonlightHostSheet(openCatalog: boolean = false,
    openSettings: boolean = false): void {
    const hostId: string = this.moonlightSheetHostId;
    if (hostId === '') { return; }
    const params: Record<string, Object> | null = moonlightHostRouteParams(hostId);
    if (openCatalog && this.remoteHostSheetMode === REMOTE_HOST_SHEET_MOONLIGHT_DETAIL &&
        this.showRemoteHostSheet && !this.remoteHostSheetClosing) {
      // Detail and catalog are two states of the same native BindSheet. Keeping
      // the Sheet mounted avoids an ArkUI nativeRef race on foldables and also
      // removes the transient interval in which a closing tap can reach a host
      // card underneath it.
      this.pendingMoonlightCatalogHostId = '';
      this.pendingMoonlightSettingsHostId = '';
      this.pendingMoonlightCatalogNavigation = '';
      this.pendingMoonlightCatalogLaunch = null;
      this.moonlightCatalogReturnsToDetail = true;
      this.moonlightCatalogDismissAllowed = true;
      this.remoteHostSheetMode = REMOTE_HOST_SHEET_MOONLIGHT_CATALOG;
      hilog.info(0x0001, 'Moonlight', 'host detail switched to catalog in shared Sheet');
      return;
    }
    // Route only after the Sheet has fully disappeared. This keeps a card tap
    // in-place and avoids a page transition being rendered underneath the
    // native Sheet exit animation.
    if (openCatalog) {
      this.pendingMoonlightCatalogHostId = hostId;
    }
    if (params !== null && openSettings) {
      this.pendingMoonlightSettingsHostId = hostId;
    }
    // Record the handoff before changing Sheet visibility so even a platform
    // that dispatches dismissal callbacks eagerly cannot lose the next panel.
    this.beginRemoteHostSheetClose(REMOTE_HOST_SHEET_MOONLIGHT_DETAIL);
    this.showRemoteHostSheet = false;
  }

  private probeMoonlightCapabilityForPicker(): void {
    // Called only after an explicit FAB action. Homepage rendering remains
    // side-effect free. The add route requires the compiled HTTP transport,
    // which is sufficient for LAN discovery and host verification. Pairing
    // remains separately gated on the stronger secure-identity capability.
    const capabilities: MoonlightBridgeCapabilities =
      this.moonlightHostService.capabilities();
    this.moonlightProtocolAvailable =
      capabilities.bridgeCompiled && capabilities.transportReady;
    hilog.info(0x0001, 'Moonlight',
      'FAB capability bridge=' + (capabilities.bridgeCompiled ? '1' : '0') +
      ' identity=' + (capabilities.identityReady ? '1' : '0') +
      ' transport=' + (capabilities.transportReady ? '1' : '0') +
      ' pairing=' + (capabilities.pairingReady ? '1' : '0') +
      ' hostControl=' + (capabilities.hostControlReady ? '1' : '0') +
      ' blocker=' + capabilities.blocker);
  }

  private moonlightDiscoveryCandidate(
    key: MoonlightHostAddDiscoveryKey,
    candidate: MoonlightLanDiscoveryCandidate
  ): void {
    if (!this.pageActive || key.ownerToken !== this.moonlightAddOwnerToken ||
        key.generation !== this.moonlightDiscoveryResultGeneration ||
        !this.moonlightDiscoveryRunning) {
      return;
    }
    const hostText: string = candidate.family === 'ipv6' ?
      '[' + candidate.host + ']' : candidate.host;
    const parsed = parseMoonlightHostAddAddress(hostText, candidate.port.toString());
    if (!parsed.ok) { return; }
    const serverUuid: string = candidate.serverUuid.trim() !== '' ?
      candidate.serverUuid.trim() : parsed.canonical;
    const nextCandidate: MoonlightHostAddCandidate = {
      serverUuid: serverUuid,
      displayName: candidate.serviceName.trim() || parsed.address.host,
      address: parsed.address,
      paired: false,
      reachable: true,
      lastSeenAt: Date.now()
    };
    const next: MoonlightHostAddCandidate[] = this.moonlightLanCandidates.slice();
    let replaceIndex: number = -1;
    for (let index = 0; index < next.length; index++) {
      if (next[index].serverUuid === serverUuid ||
          next[index].address.host === parsed.address.host &&
          next[index].address.port === parsed.address.port) {
        replaceIndex = index;
        break;
      }
    }
    if (replaceIndex >= 0) {
      next[replaceIndex] = nextCandidate;
    } else if (next.length < 32) {
      next.push(nextCandidate);
    }
    this.moonlightLanCandidates = next;
  }

  private startMoonlightLanDiscovery(key: MoonlightHostAddDiscoveryKey): void {
    this.stopMoonlightLanDiscovery();
    this.moonlightLanCandidates = [];
    this.moonlightDiscoveryResultOwnerToken = key.ownerToken;
    this.moonlightDiscoveryResultGeneration = key.generation;
    try {
      this.moonlightDiscovery = new MoonlightLanDiscoveryService(
        getContext(this) as common.Context);
      const started: boolean = this.moonlightDiscovery.start(
        key.ownerToken.toString(), key.generation,
        (candidate: MoonlightLanDiscoveryCandidate): void => {
          this.moonlightDiscoveryCandidate(key, candidate);
        });
      this.moonlightDiscoveryRunning = started;
    } catch (_error) {
      this.moonlightDiscovery = null;
      this.moonlightDiscoveryRunning = false;
    }
  }

  private stopMoonlightLanDiscovery(): void {
    if (this.moonlightDiscovery !== null) {
      this.moonlightDiscovery.stop();
    }
    this.moonlightDiscovery = null;
    this.moonlightDiscoveryRunning = false;
  }

  private clearMoonlightVerificationState(): void {
    this.moonlightActiveVerification = null;
    this.moonlightPendingVerificationFence = null;
    this.moonlightActiveVerificationFence = null;
    this.moonlightPairingExpiresAt = 0;
  }

  private async revokeMoonlightTemporaryPairing(
    capturedFence: MoonlightHostOperationFence | null = null
  ): Promise<void> {
    const verification: MoonlightHostAddVerification | null =
      this.moonlightActiveVerification;
    const fence: MoonlightHostOperationFence | null = capturedFence === null ?
      this.moonlightActiveVerificationFence : capturedFence;
    let context: MoonlightHostContext | null = null;
    if (verification !== null && verification.paired && fence !== null &&
        moonlightVerificationMatchesFence(verification, fence)) {
      const key = new MoonlightHostAddOperationKey();
      key.ownerToken = fence.ownerToken;
      key.generation = fence.generation;
      key.operation = 'trust';
      context = this.moonlightRuntimeContext(key, verification, true, fence);
      if (context !== null) { context.timeoutMs = 7000; }
    }

    // Invalidate the page projection immediately. ProductRuntime independently
    // revokes its local trust before attempting the best-effort Sunshine call.
    this.clearMoonlightVerificationState();
    if (context === null) { return; }

    try {
      const result: MoonlightHostServiceResult =
        await this.moonlightHostService.unpair(context);
      if (result.nativeResult === null ||
          result.nativeResult.postconditionTruth !== 'confirmed') {
        hilog.warn(0x0001, 'Moonlight',
          'temporary pairing local revoke was not confirmed code=' + result.code);
      } else if (!result.ok) {
        hilog.warn(0x0001, 'Moonlight',
          'temporary pairing revoked locally; remote unpair warning code=' + result.code);
      }
    } catch (_error) {
      hilog.warn(0x0001, 'Moonlight',
        'temporary pairing native unpair bridge failed');
    }
  }

  private invalidateMoonlightOwnerFence(ownerToken: number): void {
    if (ownerToken !== this.moonlightAddOwnerToken) { return; }
    this.moonlightPendingVerificationFence = null;
    this.moonlightPairingExpiresAt = 0;
    const verification: MoonlightHostAddVerification | null =
      this.moonlightActiveVerification;
    const current: MoonlightHostOperationFence | null =
      this.moonlightActiveVerificationFence;
    if (verification === null || current === null ||
        current.generation >= Number.MAX_SAFE_INTEGER ||
        !this.moonlightFenceLeaseCurrent(current) ||
        !moonlightVerificationMatchesFence(verification, current)) {
      this.moonlightActiveVerificationFence = null;
      return;
    }
    this.moonlightActiveVerificationFence = createMoonlightHostOperationFence(
      current.ownerToken, current.generation + 1,
      current.ownerScopeId, current.accountGeneration,
      verification.serverUuid, verification.address);
  }

  private moonlightFenceLeaseCurrent(fence: MoonlightHostOperationFence): boolean {
    const store: CloudStore = CloudStore.getInstance();
    const lease: AccountSessionLease | null = store.currentAccountLease();
    return lease !== null && store.isLeaseCurrent(lease) &&
      lease.ownerScopeId === fence.ownerScopeId &&
      lease.generation === fence.accountGeneration;
  }

  private adoptMoonlightVerificationFence(
    key: MoonlightHostAddOperationKey
  ): MoonlightHostOperationFence | null {
    const verification: MoonlightHostAddVerification | null =
      this.moonlightActiveVerification;
    const current: MoonlightHostOperationFence | null =
      this.moonlightActiveVerificationFence;
    if (verification === null || current === null ||
        key.ownerToken !== this.moonlightAddOwnerToken ||
        current.ownerToken !== key.ownerToken || key.generation < current.generation ||
        !this.moonlightFenceLeaseCurrent(current) ||
        !moonlightVerificationMatchesFence(verification, current)) {
      return null;
    }
    if (key.generation === current.generation) {
      return cloneMoonlightHostOperationFence(current);
    }
    const next: MoonlightHostOperationFence | null = createMoonlightHostOperationFence(
      key.ownerToken, key.generation, current.ownerScopeId, current.accountGeneration,
      verification.serverUuid, verification.address);
    if (next === null) { return null; }
    this.moonlightPendingVerificationFence = null;
    this.moonlightPairingExpiresAt = 0;
    this.moonlightActiveVerificationFence = next;
    return cloneMoonlightHostOperationFence(next);
  }

  private currentMoonlightVerificationFence(
    key: MoonlightHostAddOperationKey
  ): MoonlightHostOperationFence | null {
    const verification: MoonlightHostAddVerification | null =
      this.moonlightActiveVerification;
    const current: MoonlightHostOperationFence | null =
      this.moonlightActiveVerificationFence;
    if (verification === null || current === null ||
        key.ownerToken !== this.moonlightAddOwnerToken ||
        key.ownerToken !== current.ownerToken || key.generation !== current.generation ||
        !this.moonlightFenceLeaseCurrent(current) ||
        !moonlightVerificationMatchesFence(verification, current)) {
      return null;
    }
    return cloneMoonlightHostOperationFence(current);
  }

  private moonlightRuntimeContext(
    key: MoonlightHostAddOperationKey,
    verification: MoonlightHostAddVerification,
    pinnedTrustAvailable: boolean,
    fence: MoonlightHostOperationFence
  ): MoonlightHostContext | null {
    const store: CloudStore = CloudStore.getInstance();
    const lease: AccountSessionLease | null = store.currentAccountLease();
    const fingerprint: string = verification.fingerprintSha256.trim().toLowerCase();
    if (lease === null || !store.isLeaseCurrent(lease) ||
        lease.ownerScopeId !== fence.ownerScopeId ||
        lease.generation !== fence.accountGeneration ||
        key.ownerToken !== fence.ownerToken || key.generation !== fence.generation ||
        key.ownerToken <= 0 || key.generation <= 0 ||
        verification.serverUuid.trim() === '' || verification.address.host.trim() === '' ||
        pinnedTrustAvailable && !/^[0-9a-f]{64}$/.test(fingerprint)) {
      return null;
    }
    const family: 'unspecified' | 'ipv4' | 'ipv6' = verification.address.family === 'ipv4' ?
      'ipv4' : verification.address.family === 'ipv6' ? 'ipv6' : 'unspecified';
    const context: MoonlightHostContext = {
      lease: lease,
      ownerScopeFingerprint: moonlightOwnerScopeFingerprint(lease.ownerScopeId),
      ownerToken: key.ownerToken,
      generation: key.generation,
      hostId: verification.serverUuid,
      serverUuid: verification.serverUuid,
      installationId: moonlightInstallationId(lease.storeIdentity),
      endpoint: {
        serverName: verification.serverName.trim() || verification.address.host,
        addresses: [{ value: verification.address.host, family: family }],
        httpPort: verification.address.port,
        httpsPort: verification.httpsPort === undefined ? MOONLIGHT_DEFAULT_HTTPS_PORT :
          verification.httpsPort,
        pinnedTrustAvailable: pinnedTrustAvailable,
        allowHttpPairingCandidate: !pinnedTrustAvailable
      },
      timeoutMs: 120000
    };
    if (pinnedTrustAvailable) {
      context.pinnedCertificateSha256 = fingerprint;
    }
    return context;
  }

  private moonlightPairingPreparation(
    key: MoonlightHostAddOperationKey
  ): Promise<MoonlightPairingPreparation> {
    const capabilities: MoonlightBridgeCapabilities =
      this.moonlightHostService.capabilities();
    if (!capabilities.hostControlReady) {
      hilog.warn(0x0001, 'Moonlight',
        'pairing blocked identity=' + (capabilities.identityReady ? '1' : '0') +
        ' transport=' + (capabilities.transportReady ? '1' : '0') +
        ' pairing=' + (capabilities.pairingReady ? '1' : '0') +
        ' blocker=' + capabilities.blocker);
      const unavailable: MoonlightPairingPreparation = {
        ok: false,
        pin: '',
        expiresAt: 0,
        errorText: '当前设备的本地安全身份能力不可用，暂时无法完成主机配对'
      };
      return Promise.resolve(unavailable);
    }
    const fence: MoonlightHostOperationFence | null = key.operation === 'pair' ?
      this.adoptMoonlightVerificationFence(key) : null;
    if (fence === null) {
      const rejected: MoonlightPairingPreparation = {
        ok: false, pin: '', expiresAt: 0, errorText: '请先完成主机验证'
      };
      return Promise.resolve(rejected);
    }
    const pin: string = moonlightPairingPin();
    const expiresAt: number = Math.min(Number.MAX_SAFE_INTEGER, Date.now() + 120000);
    this.moonlightPairingExpiresAt = expiresAt;
    const prepared: MoonlightPairingPreparation = {
      ok: true, pin: pin, expiresAt: expiresAt, errorText: ''
    };
    return Promise.resolve(prepared);
  }

  private async moonlightAwaitPairing(
    pin: string,
    key: MoonlightHostAddOperationKey
  ): Promise<MoonlightPairingCompletion> {
    if (key.operation !== 'pair') {
      return { paired: false, errorText: '当前主机连接上下文已失效' };
    }
    const capturedFence: MoonlightHostOperationFence | null =
      this.currentMoonlightVerificationFence(key);
    const verification: MoonlightHostAddVerification | null = this.moonlightActiveVerification;
    const context: MoonlightHostContext | null = verification === null || capturedFence === null ? null :
      this.moonlightRuntimeContext(key, verification, false, capturedFence);
    const expiresAt: number = this.moonlightPairingExpiresAt;
    const installationId: string = context === null || context.installationId === undefined ?
      '' : context.installationId;
    if (context === null || installationId === '' ||
        !/^[0-9]{4}$/.test(pin) || expiresAt <= Date.now()) {
      return { paired: false, errorText: '当前主机连接上下文已失效' };
    }
    const pinBytes: Uint8Array = new Uint8Array([
      pin.charCodeAt(0), pin.charCodeAt(1), pin.charCodeAt(2), pin.charCodeAt(3)
    ]);
    let result: MoonlightHostServiceResult | null = null;
    try {
      result = await this.moonlightHostService.pair(
        context, installationId, pinBytes,
        this.moonlightSettingsService.load().settings.network.allowLegacySha1);
    } finally {
      pinBytes.fill(0);
    }
    if (result === null) {
      return { paired: false, errorText: '主机配对请求未完成' };
    }
    const nativeResult = result.nativeResult;
    const fingerprint: string = nativeResult === null ||
      nativeResult.certificateSha256 === undefined ? '' :
      nativeResult.certificateSha256.toLowerCase();
    const currentFence: MoonlightHostOperationFence | null =
      this.currentMoonlightVerificationFence(key);
    const stillCurrent: boolean = currentFence !== null &&
      moonlightHostOperationFenceEquals(currentFence, capturedFence) &&
      Date.now() < expiresAt;
    const succeeded: boolean = result.ok && nativeResult !== null &&
      nativeResult.code === 'ok' && /^[0-9a-f]{64}$/.test(fingerprint);
    if (!stillCurrent) {
      return { paired: false, errorText: '当前主机连接上下文已失效' };
    }
    this.moonlightPairingExpiresAt = 0;
    if (!succeeded || verification === null) {
      return {
        paired: false,
        errorText: '主机未完成配对（' + result.code + '）'
      };
    }
    this.moonlightActiveVerification = {
      serverUuid: verification.serverUuid,
      serverName: verification.serverName,
      hostType: verification.hostType,
      version: verification.version,
      address: {
        host: verification.address.host,
        family: verification.address.family,
        port: verification.address.port
      },
      httpsPort: verification.httpsPort,
      paired: true,
      fingerprintSha256: fingerprint,
      certificateChanged: false,
      udpVerified: verification.udpVerified,
      duplicateHostId: verification.duplicateHostId
    };
    return {
      paired: true,
      certificateSha256: fingerprint,
      errorText: ''
    };
  }

  private async moonlightVerifyHost(
    address: MoonlightAddress,
    selectedServerUuid: string,
    key: MoonlightHostAddOperationKey
  ): Promise<MoonlightHostAddVerification | null> {
    if (!this.pageActive || key.ownerToken !== this.moonlightAddOwnerToken ||
        key.operation !== 'verify') {
      return null;
    }
    const store: CloudStore = CloudStore.getInstance();
    const capturedLease: AccountSessionLease | null = store.currentAccountLease();
    if (capturedLease === null || !store.isLeaseCurrent(capturedLease)) { return null; }
    const verificationUuidHint: string =
      moonlightVerificationUuidHint(address, selectedServerUuid);
    const previousVerification: MoonlightHostAddVerification | null =
      this.moonlightActiveVerification;
    const targetMatchesPrevious: boolean = previousVerification !== null &&
      ((verificationUuidHint !== '' &&
        verificationUuidHint === previousVerification.serverUuid) ||
       (address.host === previousVerification.address.host &&
        address.port === previousVerification.address.port));
    if (previousVerification !== null && previousVerification.paired &&
        !targetMatchesPrevious) {
      await this.revokeMoonlightTemporaryPairing();
      if (!this.pageActive || key.ownerToken !== this.moonlightAddOwnerToken ||
          !store.isLeaseCurrent(capturedLease)) {
        return null;
      }
    }
    const requestedFence: MoonlightHostOperationFence | null =
      createMoonlightHostOperationFence(
        key.ownerToken, key.generation,
        capturedLease.ownerScopeId, capturedLease.generation,
        verificationUuidHint, address);
    if (requestedFence === null) { return null; }
    this.clearMoonlightVerificationState();
    this.moonlightPendingVerificationFence = requestedFence;
    const verification: MoonlightHostAddVerification | null =
      await this.moonlightLanProbeService.verify(address, verificationUuidHint);
    if (verification === null || !this.pageActive ||
        !store.isLeaseCurrent(capturedLease) ||
        key.ownerToken !== this.moonlightAddOwnerToken ||
        !moonlightHostOperationFenceEquals(
          this.moonlightPendingVerificationFence, requestedFence) ||
        !moonlightVerificationMatchesFence(verification, requestedFence)) {
      if (moonlightHostOperationFenceEquals(
        this.moonlightPendingVerificationFence, requestedFence)) {
        this.moonlightPendingVerificationFence = null;
      }
      return null;
    }
    const activeFence: MoonlightHostOperationFence | null =
      createMoonlightHostOperationFence(
        key.ownerToken, key.generation,
        capturedLease.ownerScopeId, capturedLease.generation,
        verification.serverUuid, verification.address);
    if (activeFence === null) {
      this.moonlightPendingVerificationFence = null;
      return null;
    }
    this.moonlightActiveVerification = verification;
    this.moonlightActiveVerificationFence = activeFence;
    this.moonlightPendingVerificationFence = null;
    return verification;
  }

  private async moonlightLoadCatalog(
    key: MoonlightHostAddOperationKey
  ): Promise<MoonlightHostAddCatalogSummary> {
    const adoptedFence: MoonlightHostOperationFence | null = key.operation === 'catalog' ?
      this.adoptMoonlightVerificationFence(key) : null;
    const verification: MoonlightHostAddVerification | null = this.moonlightActiveVerification;
    const context: MoonlightHostContext | null = adoptedFence === null || verification === null ? null :
      this.moonlightRuntimeContext(key, verification, true, adoptedFence);
    if (context === null) {
      return { appCount: 0, titles: [], stale: false, errorText: '主机连接上下文已失效' };
    }
    const result: MoonlightHostServiceResult =
      await this.moonlightHostService.catalogRuntime(context);
    const currentFence: MoonlightHostOperationFence | null =
      this.currentMoonlightVerificationFence(key);
    if (currentFence === null ||
        !moonlightHostOperationFenceEquals(currentFence, adoptedFence)) {
      return { appCount: 0, titles: [], stale: true,
        errorText: '主机连接上下文已失效' };
    }
    if (!result.ok || result.nativeResult === null) {
      return { appCount: 0, titles: [], stale: result.stale,
        errorText: '应用目录加载失败（' + result.code + '）' };
    }
    const titles: string[] = [];
    for (let index = 0; index < result.nativeResult.apps.length && index < 128; index++) {
      titles.push(result.nativeResult.apps[index].title);
    }
    return { appCount: titles.length, titles: titles, stale: false, errorText: '' };
  }

  private async moonlightCommitTrust(
    accepted: boolean,
    key: MoonlightHostAddOperationKey
  ): Promise<boolean> {
    const fence: MoonlightHostOperationFence | null = key.operation === 'trust' ?
      this.adoptMoonlightVerificationFence(key) : null;
    if (!accepted) {
      await this.revokeMoonlightTemporaryPairing(fence);
      return true;
    }
    const verification: MoonlightHostAddVerification | null = this.moonlightActiveVerification;
    return fence !== null && verification !== null && verification.paired &&
      /^[0-9a-f]{64}$/.test(verification.fingerprintSha256);
  }

  private saveMoonlightHostLocally(
    state: MoonlightHostAddState,
    _openCatalog: boolean,
    key: MoonlightHostAddOperationKey
  ): Promise<MoonlightLocalSaveResult> {
    return this.saveMoonlightHostLocallyWithRetry(state, key);
  }

  private async saveMoonlightHostLocallyWithRetry(
    state: MoonlightHostAddState,
    key: MoonlightHostAddOperationKey
  ): Promise<MoonlightLocalSaveResult> {
    let result: MoonlightLocalHostSaveResult =
      this.moonlightLocalHostService.save(state, key, Date.now());
    // A normal cloud-first apply briefly owns the RDB transaction gate. Match
    // the forgiving behavior users expect from the other host editors by
    // waiting for that short operation instead of surfacing an immediate,
    // misleading permanent write failure. Never retry an uncertain/committed
    // result, so this cannot duplicate a durable host or trust record.
    const retryDelays: number[] = [250, 500, 1000, 1500, 2000, 3000];
    for (let i = 0; i < retryDelays.length && !result.ok &&
        !result.localCommitted && result.code === 'local_write_failed'; i++) {
      await new Promise<void>((resolve: () => void): void => {
        setTimeout(resolve, retryDelays[i]);
      });
      result = this.moonlightLocalHostService.save(
        state, key, Date.now());
    }
    if (!result.ok) {
      const failed: MoonlightLocalSaveResult = {
        localCommitted: false,
        hostId: result.hostId,
        errorText: result.errorText,
        commitState: result.commitState
      };
      return Promise.resolve(failed);
    }
    const saved: MoonlightLocalSaveResult = {
      localCommitted: true,
      hostId: result.hostId,
      errorText: '',
      commitState: result.commitState
    };
    return Promise.resolve(saved);
  }

  private openExistingMoonlightHost(hostId: string, ownerToken: number): void {
    if (!shouldAcceptHostAddPostSaveHandoff(
      this.pageActive,
      this.addSheetClosing,
      this.pendingMoonlightCatalogHandoff,
      this.moonlightAddOwnerToken,
      ownerToken,
      hostId
    )) {
      hilog.info(0x0001, 'HostList',
        'ignored stale or repeated Moonlight existing-host handoff');
      return;
    }
    const generation: number = this.moonlightCatalogHandoffGeneration + 1;
    this.moonlightCatalogHandoffGeneration = generation;
    this.pendingMoonlightCatalogHandoff = createHostAddPostSaveHandoff(
      'moonlight_host_detail', hostId, ownerToken, generation);
    this.requestAddSheetClose();
  }

  private handleMoonlightHostSaved(
    hostId: string,
    openCatalog: boolean,
    ownerToken: number
  ): void {
    this.moonlightAddCommitted = true;
    if (hostId.trim() === '') {
      if (shouldCloseHostAddAfterCommittedSave(
        this.pageActive,
        this.addSheetClosing,
        this.moonlightAddOwnerToken,
        ownerToken
      )) {
        hilog.warn(0x0001, 'HostList',
          'Moonlight host committed without stable ID; closing add Sheet without catalog handoff');
        this.requestAddSheetClose();
      }
      return;
    }
    if (!shouldAcceptHostAddPostSaveHandoff(
      this.pageActive,
      this.addSheetClosing,
      this.pendingMoonlightCatalogHandoff,
      this.moonlightAddOwnerToken,
      ownerToken,
      hostId
    )) {
      hilog.info(0x0001, 'HostList',
        'ignored stale or repeated Moonlight post-save handoff');
      return;
    }
    if (openCatalog) {
      const generation: number = this.moonlightCatalogHandoffGeneration + 1;
      this.moonlightCatalogHandoffGeneration = generation;
      this.pendingMoonlightCatalogHandoff = createHostAddPostSaveHandoff(
        'moonlight_catalog', hostId, ownerToken, generation);
    }
    this.refreshMoonlightDirectory();
    this.requestAddSheetClose();
  }

  private handleAddSheetDisappear(): void {
    const moonlightDraftWasOpen: boolean = this.modernAddProtocol === 'moonlight';
    const moonlightDraftWasCommitted: boolean = this.moonlightAddCommitted;
    if (moonlightDraftWasOpen && !moonlightDraftWasCommitted) {
      void this.revokeMoonlightTemporaryPairing();
    } else if (moonlightDraftWasOpen) {
      // The durable local host owns this pairing now. Drop only the add-flow
      // projection; the host record will restore trust for later operations.
      this.clearMoonlightVerificationState();
    }
    this.moonlightAddCommitted = false;
    this.noteSheetDismissed();
    this.addSheetClosing = false;
    this.addSheetShowsModernPicker = false;
    this.modernAddProtocol = '';
    this.vncAddFromModernPicker = false;
    const pendingVncHostId: string = this.pendingVncConnectHostId;
    this.pendingVncConnectHostId = '';
    const pendingHostId: string = this.pendingAddSheetConnectHostId;
    this.pendingAddSheetConnectHostId = '';
    const pendingMoonlightDestination: HostAddPostSaveHandoff =
      this.pendingMoonlightCatalogHandoff;
    this.pendingMoonlightCatalogHandoff = emptyHostAddPostSaveHandoff();
    const openVncGatewayDirectory: boolean = this.pendingVncGatewayDirectoryOpen;
    this.pendingVncGatewayDirectoryOpen = false;
    const openRustDeskRelayDirectory: boolean = this.pendingRustDeskRelayDirectoryOpen;
    this.pendingRustDeskRelayDirectoryOpen = false;
    const openRustDeskTotpBinding: boolean = this.rustDeskTotpBindingPendingOpen;
    const preserveForm: boolean = this.preserveFormOnAddSheetDisappear;
    this.rustDeskTotpBindingPendingOpen = false;
    this.preserveFormOnAddSheetDisappear = false;

    if (openRustDeskTotpBinding) {
      const generation: number = this.rustDeskTotpBindingGeneration;
      setTimeout((): void => {
        if (!this.pageActive || this.rustDeskTotpBindingGeneration !== generation ||
          this.rustDeskTotpBindingClosing || this.showRemoteHostSheet) {
          return;
        }
        this.openSheetSafely((): void => {
          if (this.rustDeskTotpBindingGeneration === generation &&
            !this.rustDeskTotpBindingClosing) {
            this.openRemoteHostSheet(REMOTE_HOST_SHEET_RUSTDESK_TOTP_BINDING, (): void => {});
          }
        }, true);
      }, 0);
      return;
    }

    if (!preserveForm) {
      this.resetForm();
      this.rustDeskAddResumeDraft = null;
    }

    if (hostAddPostSaveHandoffIsPending(pendingMoonlightDestination)) {
      if (!shouldStartHostAddPostSaveAfterDisappear(
        this.pageActive,
        this.addSheetClosing,
        this.moonlightAddOwnerToken,
        this.moonlightCatalogHandoffGeneration,
        pendingMoonlightDestination,
        pendingMoonlightDestination.destination
      )) {
        hilog.info(0x0001, 'HostList',
          'dropped stale Moonlight catalog handoff after add-host Sheet disappeared');
        return;
      }
      hilog.info(0x0001, 'HostList',
        'Moonlight post-save handoff accepted after add-host Sheet disappeared');
      if (pendingMoonlightDestination.destination === 'moonlight_catalog') {
        this.openMoonlightCatalogSheet(pendingMoonlightDestination.hostId);
      } else {
        // Existing Moonlight hosts follow the same in-place card expansion as
        // every normal host-list tap. Do not revive the retired full-page
        // detail route after the add Sheet disappears.
        this.openMoonlightHostSheet(pendingMoonlightDestination.hostId);
      }
      return;
    }

    if (openVncGatewayDirectory || openRustDeskRelayDirectory) {
      if (!this.pageActive) { return; }
      if (this.isDesktopDevice && this.breakpoint === 'xl') {
        this.curTab = 6;
        this.hostPageTitle = '中继服务器';
      } else {
        this.curTab = 2;
        this.tabsCtrl.changeIndex(2);
      }
      this.updateHostFilter();
      if (openVncGatewayDirectory) {
        this.relayVncAddTrigger++;
      } else {
        this.relayRustDeskAddTrigger++;
      }
      return;
    }

    if (pendingVncHostId !== '') {
      if (!this.pageActive) { return; }
      hilog.info(0x0001, 'HostList', 'VNC add-host Sheet disappeared; starting saved connection host=' +
        pendingVncHostId);
      const savedVncHost: VncHostView | null = this.vncHosts.find(pendingVncHostId);
      if (savedVncHost === null) {
        promptAction.showToast({ message: 'VNC 主机已保存，但连接目标不存在，请刷新后重试', duration: 2200 });
        return;
      }
      // Reuse the normal card path so a newly added TLS endpoint gets the
      // same certificate preflight Sheet before RemoteDesktop is entered.
      void this.connectToHost(projectVncHost(savedVncHost));
      return;
    }

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

  private resumeRustDeskHostAddFromRelayDirectory(
    savedRelayId: string
  ): void {
    if (!this.rustDeskRelayReturnToHostAdd) { return; }
    this.rustDeskRelayReturnToHostAdd = false;
    const scope = CloudStore.getInstance().currentScope();
    const handoff: RustDeskHostAddHandoff =
      RustDeskHostAddHandoff.getInstance();
    if (savedRelayId.trim() !== '') {
      handoff.selectRelay(
        scope.ownerScopeId, scope.storeIdentity,
        scope.generation, savedRelayId);
    }
    const draft: RustDeskHostAddDraft | null =
      handoff.take(
        scope.ownerScopeId, scope.storeIdentity,
        scope.generation);
    if (draft === null) {
      promptAction.showToast({
        message: '主机草稿已过期或账号已切换，请重新添加',
        duration: 2400
      });
      return;
    }
    this.noteSheetDismissed();
    if (this.isDesktopDevice && this.breakpoint === 'xl') {
      this.curTab = this.rustDeskHostAddReturnTab;
      const titles: string[] =
        ['RDP 远程桌面', 'RustDesk', 'SSH 终端', 'VNC 主机'];
      this.hostPageTitle =
        titles[this.curTab] ?? '远程主机';
    } else {
      this.curTab = 0;
      this.tabsCtrl.changeIndex(0);
    }
    this.updateHostFilter();
    this.rustDeskAddResumeDraft = draft;
    this.rustDeskAddResumeRevision++;
    this.addSheetShowsModernPicker = false;
    this.modernAddProtocol = 'rustdesk';
    this.openSheetSafely((): void => {
      this.showAddSheet = true;
    });
  }

  private requestAddSheetClose(): void {
    if (this.pendingSheetOpenTimer !== -1) {
      clearTimeout(this.pendingSheetOpenTimer);
      this.pendingSheetOpenTimer = -1;
    }
    this.activateSheetReleaseFence();
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

  private settingsLeafHasUnsavedChanges(): boolean {
    return this.vncSettingsLeafDirty || this.moonlightSettingsLeafDirty;
  }

  private dismissSettingsLeafIfNeeded(continueAction: () => void): void {
    if (!this.settingsLeafHasUnsavedChanges()) {
      continueAction();
      return;
    }
    const moonlightDirty: boolean = this.moonlightSettingsLeafDirty;
    promptAction.showDialog({
      title: moonlightDirty ? '放弃未保存的 Moonlight 设置？' : '放弃未保存的 VNC 设置？',
      message: moonlightDirty ? '当前修改只在本地草稿中，放弃后不会写入 Moonlight 本地记录。' :
        '当前叶子设置还有未保存修改。放弃后这些修改不会写入本地或云端。',
      buttons: [{ text: '继续编辑', color: this.pal().text2 }, { text: '放弃修改', color: this.pal().danger }]
    }).then((result: Object): void => {
      const dialogResult: Record<string, number> = result as Record<string, number>;
      if (dialogResult['index'] === 1) {
        this.vncSettingsLeafDirty = false;
        this.moonlightSettingsLeafDirty = false;
        continueAction();
      }
    });
  }

  private handleSettingsLeafWillDismiss(action: DismissSheetAction): void {
    if (!this.settingsLeafHasUnsavedChanges()) {
      action.dismiss();
      return;
    }
    this.dismissSettingsLeafIfNeeded((): void => { action.dismiss(); });
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
    this.vncSettingsLeafDirty = false;
    this.moonlightSettingsLeafDirty = false;
    if (moonlightSettingsRouteSpec(dismissedMode) !== null) {
      this.moonlightSettingsLeafHostId = '';
    }
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
   * setDistributedTables can fail transiently while the already-downloaded
   * account cache remains readable. Re-register the same fenced store and then
   * let the existing coordinator perform its normal cloud-first bootstrap.
   */
  private refreshCloudRegistration(): void {
    const cloud: CloudStore = CloudStore.getInstance();
    this.cloudConnectionAvailable = cloud.isCloudAvailable();
    if (this.cloudConnectionAvailable) {
      if (CloudSyncSelectionStore.getInstance()
        .persistedSelectedBusinessTables()
        .indexOf(MOONLIGHT_CLOUD_TABLE) >= 0) {
        void cloud.retryMoonlightCloudRegistration();
      }
      return;
    }
    void cloud.retryCloudRegistration().then((restored: boolean): void => {
      this.cloudConnectionAvailable = cloud.isCloudAvailable();
      if (!restored) { return; }
      void CloudSyncCoordinator.getInstance().requestStartupPull().then(
        (_result): void => {
          this.cloudConnectionAvailable = cloud.isCloudAvailable();
        },
        (_error: Error): void => {
          this.cloudConnectionAvailable = cloud.isCloudAvailable();
        });
    }, (_error: Error): void => {
      this.cloudConnectionAvailable = cloud.isCloudAvailable();
    });
  }

  /**
   * Open every cloud sheet state atomically with the leaf Sheet transition.
   * The transition may be delayed while a previous Sheet is dismissing, so
   * callers must not assign cloudSyncStep after this method returns.
   */
  private openCloudSyncSheet(initialStep: string = ''): void {
    this.refreshCloudRegistration();
    this.openSettingsLeafSheet(SETTINGS_SHEET_POPUP, (): void => {
      this.cloudSyncSelectedTables = CloudSyncSelectionStore.getInstance()
        .persistedSelectedBusinessTables();
      this.moonlightCloudSelectedScopes = CloudStore.getInstance()
        .moonlightSelectedCloudScopes();
      this.moonlightRestoreActivationState = CloudStore.getInstance()
        .moonlightRestoredDataActivationState();
      this.cloudSyncError = '';
      this.cloudSyncStep = initialStep !== '' ? initialStep :
        (!CloudStore.getInstance().requiresCloudServiceGuidance()
          ? CLOUD_SYNC_SHEET_ACTIONS
          : CLOUD_SYNC_SHEET_UNAVAILABLE);
      this.popupSheetMode = 3;
    });
  }

  private openCloudSyncDetailsSheet(): void {
    this.refreshCloudRegistration();
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

  private cloudDirectionConfirmationAvailable():
    boolean {
    // Keep dormant optional-table intent visible in the management UI, but
    // only runtime-admitted tables may enable a transfer action.
    return CloudSyncSelectionStore.getInstance()
      .selectedBusinessTables().length > 0 ||
      CloudStore.getInstance()
        .requiresRestoreDirectionDecision();
  }

  private async toggleCloudSyncTable(
    table: string
  ): Promise<void> {
    const next: string[] = this.cloudSyncSelectedTables.slice();
    const index: number = next.indexOf(table);
    if (index >= 0) { next.splice(index, 1); } else { next.push(table); }
    const cloud: CloudStore = CloudStore.getInstance();
    const resolvingRestore: boolean =
      cloud.requiresRestoreDirectionDecision();
    const moonlightRestoreState: string =
      table === MOONLIGHT_CLOUD_TABLE ?
        cloud.moonlightRestoredDataActivationState() : 'clear';
    if (table === MOONLIGHT_CLOUD_TABLE &&
        !cloud.moonlightCloudSelectionChangesAllowed()) {
      this.cloudSyncError =
        'Moonlight 云端删除正在完成；为避免数据重新出现，暂不能修改同步范围';
      return;
    }
    if (index < 0 && table === MOONLIGHT_CLOUD_TABLE) {
      const logical = await cloud.replaceMoonlightCloudScopes(
        moonlightForcedCloudSyncSelection());
      this.moonlightCloudSelectedScopes = logical.selected.slice();
      if (!logical.ok && logical.code !== 'reconcile_pending') {
        this.cloudSyncError =
          'Moonlight 整体同步状态未能恢复，请稍后重试';
        return;
      }
    }
    if (index < 0 && table === MOONLIGHT_CLOUD_TABLE &&
        !await cloud.retryMoonlightCloudRegistration()) {
      this.cloudSyncError = cloud.isCloudAvailable() ?
        'Moonlight 云表尚未就绪；现有协议云同步未受影响' :
        'Moonlight 云表检查后旧版云连接需要恢复，请稍后重试';
      return;
    }
    if (index < 0 && table === MOONLIGHT_CLOUD_TABLE &&
        moonlightRestoreState === 'blocked') {
      this.cloudSyncError =
        'Moonlight 恢复隔离状态不可读；为保护本机和旧版云数据，已拒绝启用';
      return;
    }
    if (index < 0 &&
      !resolvingRestore &&
      !(table === MOONLIGHT_CLOUD_TABLE &&
        moonlightRestoreState === 'pending') &&
      !cloud.beginSelectionReenableBarrier(table)) {
      this.cloudSyncError =
        '同步范围禁写门禁未能保存，已拒绝重新启用';
      return;
    }
    if (!CloudSyncSelectionStore.getInstance()
      .replaceSelectedBusinessTables(getContext(this), next)) {
      if (index < 0 && !resolvingRestore) {
        if (!(table === MOONLIGHT_CLOUD_TABLE &&
          moonlightRestoreState === 'pending')) {
          cloud.abortSelectionReenableBarrier(table);
        }
      }
      this.cloudSyncError = '同步范围未能安全保存，请重试';
      return;
    }
    this.cloudSyncSelectedTables = CloudSyncSelectionStore.getInstance()
      .persistedSelectedBusinessTables();
    this.moonlightRestoreActivationState =
      cloud.moonlightRestoredDataActivationState();
    // Every re-enabled physical table crosses a fresh cloud-first barrier.
    // This is especially important after a local crypto reset: pending local
    // deletes must never become native-first merely because the user later
    // turned the table back on.
    if (index < 0) {
      if (table === MOONLIGHT_CLOUD_TABLE &&
          moonlightRestoreState === 'pending') {
        this.cloudSyncError =
          '已保留 Moonlight 同步选择；恢复的数据仍仅在本机，需完成云端核对并再次确认后才会上传';
        return;
      }
      if (resolvingRestore) {
        this.cloudSyncError =
          '恢复数据等待方向确认：请选择“上传本机”或“下载云端”完成同步';
        return;
      }
      const result =
        await cloud.requestSelectionReenableCloudFirst(
          table);
      if (!result.ok) {
        hilog.warn(0x0001, 'CloudSync',
          '[HostListPage] table re-enable pull failed table=' + table);
        this.cloudSyncError =
          '云表重新启用失败：上传仍被暂停，请检查云空间后重试';
        promptAction.showToast({
          message: '云表重新启用失败，上传仍保持暂停',
          duration: 2600
        });
      }
    } else if (!cloud.abortSelectionReenableBarrier(
      table)) {
      this.cloudSyncError =
        '同步范围已关闭，但旧门禁清理失败；上传仍保持暂停';
    }
  }

  private confirmMoonlightRestoreActivation(): void {
    promptAction.showDialog({
      title: '允许恢复的 Moonlight 数据上传？',
      message: '应用会先下载并核对当前账号的 Moonlight 云端数据，再解除本机恢复隔离并排队上传已选择的串流设置、主机和配置档。配对信任、证书与客户端私钥始终不会上传。',
      buttons: [
        { text: '暂不启用', color: this.pal().text2 },
        { text: '核对并启用', color: this.accentColor }
      ]
    }).then((value: Object): void => {
      const result: Record<string, number> =
        value as Record<string, number>;
      if (result['index'] === 1) {
        void this.activateMoonlightRestoredData();
      }
    });
  }

  private async activateMoonlightRestoredData(): Promise<void> {
    const cloud: CloudStore = CloudStore.getInstance();
    const result = await cloud.activateMoonlightRestoredData();
    this.moonlightRestoreActivationState =
      cloud.moonlightRestoredDataActivationState();
    this.moonlightCloudSelectedScopes =
      cloud.moonlightSelectedCloudScopes();
    if (result.ok) {
      this.cloudSyncError = '';
      promptAction.showToast({
        message: '云端核对完成，Moonlight 恢复数据已进入安全上传队列',
        duration: 2600
      });
      return;
    }
    if (result.code === 'selection_required') {
      this.cloudSyncError =
        'Moonlight 云表尚未完成自动注册，请稍后重试';
    } else if (result.code === 'bootstrap_pending') {
      this.cloudSyncError =
        '当前账号的基础云端核对尚未完成；旧版数据保持可用，请稍后重试';
    } else if (result.code === 'registration_unavailable') {
      this.cloudSyncError =
        'Moonlight 云表尚未就绪；现有协议云同步未受影响';
    } else if (result.code === 'metadata_blocked' ||
        result.code === 'marker_clear_failed') {
      this.cloudSyncError =
        '恢复隔离状态未能安全确认；数据仍只保存在本机，未执行上传';
    } else if (result.code === 'stale_lease') {
      this.cloudSyncError = '账号状态已变化，请重新打开数据管理后再试';
    } else {
      this.cloudSyncError =
        'Moonlight 云端核对未完成；恢复数据仍只保存在本机';
    }
  }

  private async createLocalBackup(): Promise<void> {
    try {
      const backup: LocalBackupService = LocalBackupService.getInstance();
      const saved: boolean = await backup.saveBackup(
        CURRENT_RELEASE_VERSION, getContext(this).cacheDir,
        this.backupFullMode ? 'full' : 'redacted');
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
    const backup: LocalBackupService =
      LocalBackupService.getInstance();
    const restored: boolean = await backup.restore(
      this.pendingLocalRestore,
      this.pendingLocalRestore.version < 3);
    if (!restored) {
      this.cloudSyncError = backup.getLastErrorMessage();
      return;
    }
    this.pendingLocalRestore = null;
    promptAction.showToast({
      message: '本地配置已合并，未自动上传到云端',
      duration: 1800
    });
    this.closeSettingsLeafSheet();
  }

  private localRestorePreviewSummary(): string {
    const preview: BackupRestorePreview | null =
      LocalBackupService.getInstance().getSelectedPreview();
    if (preview === null) {
      return '尚未选择备份文件';
    }
    const legacy: string = preview.legacyOwnerUnbound
      ? '；旧版文件将在确认后绑定当前本地数据作用域' : '';
    const redacted: string = !preview.secretsIncluded
      ? '；该备份为脱敏配置，不含密码、SSH 私钥、2FA 与设备信任（SSH 公钥/RDP 证书），恢复后需重新导入/确认' : '';
    return '格式 v' + preview.formatVersion.toString() +
      ' · ' + preview.rowCount.toString() + ' 行 · ' +
      preview.presentTables.length.toString() + ' 个数据表' +
      legacy + redacted;
  }

  private currentCloudSyncSheetSpec(): CloudSyncSheetSpec {
    return cloudSyncSheetSpec(this.cloudSyncStep);
  }

  private async confirmCloudSyncUpload(): Promise<void> {
    const cloud: CloudStore = CloudStore.getInstance();
    const resolvingRestore: boolean =
      cloud.requiresRestoreDirectionDecision();
    if (cloud.requiresCloudServiceGuidance()) {
      this.cloudSyncStep = CLOUD_SYNC_SHEET_UNAVAILABLE;
      return;
    }
    this.cloudSyncError = '';
    this.cloudSyncStep = CLOUD_SYNC_SHEET_UPLOADING;
    const completed: boolean = await cloud.uploadAllToCloud();
    if (completed) {
      promptAction.showToast({
        message: resolvingRestore
          ? '恢复方向已确认：已选数据已上传，未选数据保留本机'
          : '已上传 ' + cloud.syncableTables().length.toString() + ' 类已选数据到华为云空间',
        duration: 2400
      });
      this.closeSettingsLeafSheet();
      return;
    }
    if (cloud.requiresCloudServiceGuidance()) {
      this.cloudSyncStep = CLOUD_SYNC_SHEET_UNAVAILABLE;
      return;
    }
    const blockedReason: string = cloud.manualUploadBlockedReason();
    const uploadError: string =
      blockedReason !== '' ? blockedReason :
        cloud.getLastSyncErrorMessage();
    this.cloudSyncError = uploadError !== '' ? uploadError :
      '上传未确认全部完成，请检查网络后重试。';
    this.cloudSyncStep = CLOUD_SYNC_SHEET_UPLOAD_CONFIRM;
  }

  private async confirmCloudSyncDownload(): Promise<void> {
    const cloud: CloudStore = CloudStore.getInstance();
    const resolvingRestore: boolean =
      cloud.requiresRestoreDirectionDecision();
    if (cloud.requiresCloudServiceGuidance()) {
      this.cloudSyncStep = CLOUD_SYNC_SHEET_UNAVAILABLE;
      return;
    }
    this.cloudSyncError = '';
    this.cloudSyncStep = CLOUD_SYNC_SHEET_DOWNLOADING;
    const result = await cloud.downloadAllFromCloudResult();
    if (result.ok) {
      this.applyCloudUserSettings();
      promptAction.showToast({
        message: resolvingRestore
          ? '恢复方向已确认：已选数据已下载，未选数据保留本机'
          : '已从华为云空间恢复 ' + cloud.syncableTables().length.toString() + ' 类已选数据',
        duration: 2400
      });
      this.closeSettingsLeafSheet();
      return;
    }
    const compatibilityTables: string[] =
      cloudFirstCompatibleTablesAfterOptionalFailure(
        'cloudFirst', result.tables, result.failedTables);
    if (compatibilityTables.length > 0) {
      if (compatibilityTables.indexOf('usersettings') >= 0) {
        this.applyCloudUserSettings();
      }
      this.cloudSyncError =
        '老版本云数据已成功下载并保留；Moonlight 云表本次未完成，' +
        'Moonlight 本地数据保持不变并等待重试，其他协议数据没有回滚。';
      this.cloudSyncStep = CLOUD_SYNC_SHEET_DOWNLOAD_CONFIRM;
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

  private openSshHostListFromSettings(): void {
    this.showSettingsPanel = false;
    if (this.isDesktopDevice && this.breakpoint === 'xl') {
      this.curTab = 2;
      this.activeFilterProto = 'ssh';
      this.hostPageTitle = 'SSH 终端';
      this.updateHostFilter();
      return;
    }
    this.curTab = 0;
    this.activeFilterProto = '';
    this.tabsCtrl.changeIndex(0);
    this.updateHostFilter();
  }

  private openSshKeyVaultFromSettings(): void {
    this.showSettingsPanel = false;
    if (this.isDesktopDevice && this.breakpoint === 'xl') {
      this.curTab = 4;
      this.keyVaultInnerTab = 0;
      return;
    }
    this.curTab = 1;
    this.tabsCtrl.changeIndex(1);
  }

  private openVncHostManagerFromSettings(): void {
    this.dismissSettingsLeafIfNeeded((): void => {
      this.closeSettingsLeafSheet();
      setTimeout((): void => {
        if (this.pageActive) { router.pushUrl({ url: 'pages/VncSettingsPage' }); }
      }, SETTINGS_PANEL_DISMISS_TO_LEAF_OPEN_MS);
    });
  }

  private openVncGatewayManagerFromSettings(): void {
    this.dismissSettingsLeafIfNeeded((): void => {
      this.closeSettingsLeafSheet();
      setTimeout((): void => {
        if (!this.pageActive) { return; }
        if (this.isDesktopDevice && this.breakpoint === 'xl') {
          this.curTab = 6;
          this.hostPageTitle = '中继服务器';
        } else {
          this.curTab = 2;
          this.tabsCtrl.changeIndex(2);
        }
        this.updateHostFilter();
      }, SETTINGS_PANEL_DISMISS_TO_LEAF_OPEN_MS);
    });
  }

  private openVncTrustManagerFromSettings(): void {
    this.openSettingsLeafSheet(SETTINGS_SHEET_POPUP, (): void => {
      this.popupSheetMode = POPUP_SHEET_VNC_CERTIFICATES;
    });
  }

  private openMoonlightSettingsFromSettings(mode: number): void {
    const spec: MoonlightSettingsRouteSpec | null = moonlightSettingsRouteSpec(mode);
    if (spec === null || spec.owner !== 'moonlight' || !this.pageActive) { return; }
    this.moonlightSettingsLeafHostId = '';
    this.openSettingsLeafSheet(mode);
  }

  private recheckVncTrust(trust: VncTrustView, selectedHostId: string): void {
    const hosts: VncHostView[] = this.vncHosts.list();
    const gateways: VncGatewayView[] = this.vncGateways.list();
    const directory: VncTrustDirectoryItem[] = buildVncTrustDirectory([trust], hosts, gateways);
    const directoryItem: VncTrustDirectoryItem | undefined = directory[0];
    if (directoryItem === undefined || directoryItem.selectedHostId === '' ||
      directoryItem.selectedHostId !== selectedHostId || directoryItem.status !== 'current') {
      promptAction.showToast({ message: 'VNC endpoint 已变化或无法唯一定位，请从当前主机重新检查', duration: 2200 });
      return;
    }
    const host: VncHostView | null = this.vncHosts.find(selectedHostId);
    if (host === null) {
      promptAction.showToast({ message: '找不到当前账号下的 VNC endpoint，请先确认主机或 Gateway 仍存在', duration: 2200 });
      return;
    }
    this.closeSettingsLeafSheet();
    setTimeout((): void => {
      if (this.pageActive) {
        // A trust-manager recheck is still a new connection request. Re-enter
        // the existing VNC lock/certificate preflight instead of constructing
        // an independent window before that flow has committed.
        void this.connectToHost(projectVncHost(host));
      }
    }, SETTINGS_PANEL_DISMISS_TO_LEAF_OPEN_MS);
  }

  private handleVncRelayRouteRequest(): void {
    const params: Object = router.getParams();
    if (params === null || params === undefined) { return; }
    const values: Record<string, Object> = params as Record<string, Object>;
    const requestId: string = typeof values['vncRelayRequestId'] === 'string'
      ? values['vncRelayRequestId'] as string : '';
    const openGateway: boolean = values['openVncGateway'] === true || values['openVncGateway'] === 'true';
    if (!openGateway || requestId === '' || requestId === this.lastVncRelayRouteRequestId) { return; }
    this.lastVncRelayRouteRequestId = requestId;
    if (this.isDesktopDevice && this.breakpoint === 'xl') {
      this.curTab = 6;
      this.hostPageTitle = '中继服务器';
    } else {
      this.curTab = 2;
      this.tabsCtrl.changeIndex(2);
    }
    this.updateHostFilter();
    this.relayVncAddTrigger++;
  }

  private resetSshTerminalAppearance(): void {
    this.terminalFgColor = this.sshSettings.saveForegroundColor('#33FF33');
    this.terminalFontSize = this.sshSettings.saveFontSize(18);
    this.terminalLineSpacing = this.sshSettings.saveLineSpacing(1.12);
    promptAction.showToast({ message: 'SSH 终端显示已恢复默认', duration: 1500 });
  }

  private normalizedTerminalLineSpacing(): number {
    const value: number = this.terminalLineSpacing;
    if (!Number.isFinite(value)) { return 1.12; }
    return Math.max(1.0, Math.min(1.6, Math.round(value * 100) / 100));
  }

  private terminalLineSpacingLabel(): string {
    return Math.round(this.normalizedTerminalLineSpacing() * 100).toString() + '%';
  }

  private terminalPreviewLineHeight(): number {
    return Math.ceil(Math.max(12, Math.min(32, this.terminalFontSize)) *
      this.normalizedTerminalLineSpacing());
  }

  private terminalPreviewWidth(): number {
    const fontSize: number = Math.max(12, Math.min(32, this.terminalFontSize));
    const desired: number = Math.ceil(fontSize * 0.62 * 12 + 24);
    const minimum: number = this.breakpoint === 'sm' ? 150 : 188;
    const maximum: number = this.breakpoint === 'sm' ? 196 : 280;
    return Math.max(minimum, Math.min(maximum, desired));
  }

  private terminalPreviewHeight(): number {
    return Math.max(88, this.terminalPreviewLineHeight() * 2 + 24);
  }

  private settingsSectionExpanded(section: string): boolean {
    return this.expandedSettingsSection === section;
  }

  private settingsSectionExpandedMaxHeight(section: string): number {
    if (section === SETTINGS_SECTION_APPEARANCE) {
      return this.appearanceExpandedMaxHeight();
    }
    if (section === SETTINGS_SECTION_HOME) {
      return 520;
    }
    if (section === SETTINGS_SECTION_CONNECTION_LIVE) {
      return 520;
    }
    if (section === SETTINGS_SECTION_DISPLAY_INTERACTION) {
      return 1040;
    }
    if (section === SETTINGS_SECTION_VIRTUAL_KEYBOARD) {
      return 390;
    }
    if (section === SETTINGS_SECTION_RDP) {
      return 820;
    }
    if (section === SETTINGS_SECTION_RUSTDESK) {
      return 980;
    }
    if (section === SETTINGS_SECTION_SSH) {
      return 830;
    }
    if (section === SETTINGS_SECTION_VNC) {
      return settingsVncExpandedMaxHeight(SETTINGS_VNC_ACTION_ROW_COUNT);
    }
    if (section === SETTINGS_SECTION_MOONLIGHT) {
      return settingsMoonlightExpandedMaxHeight(SETTINGS_MOONLIGHT_ACTION_ROW_COUNT);
    }
    if (section === SETTINGS_SECTION_SECURITY) {
      return 560;
    }
    if (section === SETTINGS_SECTION_TUTORIAL) {
      return 300;
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
    this.sheetReleaseFenceGeneration += 1;
    this.sheetReleaseFenceActive = false;
    if (this.sheetReleaseFenceTimer !== -1) {
      clearTimeout(this.sheetReleaseFenceTimer);
      this.sheetReleaseFenceTimer = -1;
    }
    this.lanDiscovery.stopScan();
    this.rdpLanDiscovery.stopScan();
    this.dynamicRustDeskDiscovery.stopScan();
    this.dynamicRdpDiscovery.stopScan();
    this.lanScanning = false;
    this.rdpLanScanning = false;
    this.stopMoonlightLanDiscovery();
    if (!this.moonlightAddCommitted) {
      void this.revokeMoonlightTemporaryPairing();
    }
    this.moonlightHostService.disposeOwner(this.moonlightAddOwnerToken);
    this.clearMoonlightVerificationState();
    this.moonlightDiscoveryResultOwnerToken = 0;
    this.moonlightDiscoveryResultGeneration = 0;
    this.moonlightLanCandidates = [];
    this.moonlightAddOwnerToken += 1;
    this.invalidateMoonlightCatalogHandoff();
    this.hostPresencePageGeneration += 1;
    this.hostLoadRefreshPresence = false;
    if (this.hostLoadRefreshTimer !== -1) {
      clearTimeout(this.hostLoadRefreshTimer);
      this.hostLoadRefreshTimer = -1;
    }
    this.vncCertificateProbeGeneration = nextVncCertificateProbeGeneration(
      this.vncCertificateProbeGeneration);
    if (this.vncCertificateProbeRequestId > 0) {
      this.loader.cancelVncCertificateProbe(this.vncCertificateProbeRequestId);
      this.vncCertificateProbeRequestId = 0;
    }
    this.vncCertificatePendingRouteParams = null;
    this.vncCertificatePendingHostId = '';
    if (this.pendingSheetOpenTimer !== -1) {
      clearTimeout(this.pendingSheetOpenTimer);
      this.pendingSheetOpenTimer = -1;
    }
    const pendingHostId: string = this.pendingAddSheetConnectHostId;
    this.pendingAddSheetConnectHostId = '';
    this.pendingVncConnectHostId = '';
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

  async load(refreshPresence: boolean = false, showLoading: boolean = false): Promise<void> {
    if (showLoading) { this.isLoading = true; }
    try {
      this.refreshCryptoStatus();
      // The Moonlight overlay and app cache can change without changing the
      // account lease. Reload it on the same lifecycle/data-change cadence as
      // the RDP/RustDesk/SSH/VNC cards.
      this.refreshMoonlightDirectory();
      this.refreshHostListView();
      this.rdpCredentials = this.srv.getAllRdpCredentials();
      this.rdpCount = this.srv.getRdpCount();
      this.rustdeskCount = this.srv.getRustdeskCount();
      this.sshCount = this.srv.getSshCount();
      this.vncCount = this.vncHosts.list().length;
      this.refreshVncTrustView();
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
      if (showLoading) { this.isLoading = false; }
      if (refreshPresence) { void this.refreshRustDeskPresence(); }
    }
  }

  private scheduleHostListLoad(refreshPresence: boolean = false): void {
    if (!this.pageActive) { return; }
    this.hostLoadRefreshPresence = this.hostLoadRefreshPresence || refreshPresence;
    if (this.hostLoadRefreshTimer !== -1) { return; }
    this.hostLoadRefreshTimer = setTimeout((): void => {
      this.hostLoadRefreshTimer = -1;
      const shouldRefreshPresence: boolean = this.hostLoadRefreshPresence;
      this.hostLoadRefreshPresence = false;
      if (this.pageActive) { void this.load(shouldRefreshPresence, false); }
    }, 80);
  }

  private loadAfterServiceReady(): void {
    if (!this.srv.isReady()) {
      this.srv.whenReady().then((): void => {
        this.applyCloudUserSettings();
        if (this.pageActive) {
          this.scheduleHostListLoad(true);
          void this.refreshDynamicLanHosts(false);
        }
      });
    }
    const keyVault: KeyVaultService = KeyVaultService.getInstance();
    if (!keyVault.isReady()) {
      keyVault.whenReady().then((): void => {
        if (this.pageActive) { this.scheduleHostListLoad(false); }
      });
    }
  }

  private registerDataRefreshListeners(): void {
    if (!this.hostDataUnsubscribe) {
      this.hostDataUnsubscribe = this.srv.onDataChange((): void => {
        this.applyCloudUserSettings();
        if (this.hostPresenceLocalObservationWrite) { return; }
        // Presence probes already refresh the visible snapshot themselves.
        // Starting a second sweep from this callback races the result and can
        // make a completed probe look stale to the card.
        this.scheduleHostListLoad(false);
      });
    }
    if (!this.keyVaultDataUnsubscribe) {
      this.keyVaultDataUnsubscribe = KeyVaultService.getInstance().onDataChange((): void => {
        this.scheduleHostListLoad(false);
      });
    }
    if (!this.vncHostDataUnsubscribe) {
      this.vncHostDataUnsubscribe = this.vncHosts.onChange((): void => {
        this.scheduleHostListLoad(false);
      });
    }
    if (!this.vncTrustDataUnsubscribe) {
      this.vncTrustDataUnsubscribe = this.vncTrust.onChange((): void => {
        this.refreshVncTrustView();
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
    if (this.vncHostDataUnsubscribe) {
      this.vncHostDataUnsubscribe();
      this.vncHostDataUnsubscribe = null;
    }
    if (this.vncTrustDataUnsubscribe) {
      this.vncTrustDataUnsubscribe();
      this.vncTrustDataUnsubscribe = null;
    }
  }

  private refreshHostListView(force: boolean = false): void {
    // 用新对象快照驱动列表和详情，避免服务层原地更新同一 RemoteHost
    // 引用时，LazyForEach/卡片内部只收到 reload 却继续显示旧字段。
    MoonlightSessionCoordinator.getInstance().reconcileNativeTerminalReceipt();
    const activeSession: ActiveRemoteSessionRecord | null = ActiveRemoteSessionRegistry.getInstance().getActive();
    const nextActiveRemoteHostId: string = activeSession === null ? '' : activeSession.hostId;
    const activeSessionChanged: boolean = this.activeRemoteHostId !== nextActiveRemoteHostId;
    this.activeRemoteHostId = nextActiveRemoteHostId;
    const nextHosts: RemoteHost[] = this.srv.getAllHosts().map((host: RemoteHost): RemoteHost =>
      RemoteHost.fromJSON(host.toJSON()));
    const vncViews: VncHostView[] = this.vncHosts.list();
    for (let i = 0; i < vncViews.length; i++) {
      nextHosts.push(projectVncHost(vncViews[i]));
    }
    this.hostCount = nextHosts.length;
    this.lockedCount = 0;
    for (let i = 0; i < nextHosts.length; i++) {
      if (nextHosts[i].locked) { this.lockedCount += 1; }
    }
    this.rdpCount = this.srv.getRdpCount();
    this.rustdeskCount = this.srv.getRustdeskCount();
    this.sshCount = this.srv.getSshCount();
    this.vncCount = vncViews.length;
    const nextSignature: string = JSON.stringify(
      nextHosts.map((host: RemoteHost): Object => host.toJSON()));
    if (!force && nextSignature === this.hostDataSignature && !activeSessionChanged) { return; }
    this.hostDataSignature = nextSignature;
    this.hosts = nextHosts;
    this.refreshFilteredHostView();
    this.refreshSshTrustedHostsView();
    this.refreshRdpTrustedHostsView();
  }

  // The classic list is invalidated by HostDataSource.reload. Grouped cards
  // live inside a ListItem and need the same explicit revision to rebuild
  // their header and detail snapshots.
  private refreshFilteredHostView(): void {
    this.filteredHosts = this.visibleHostsForCurrentMode();
    // 非分类模式下应用本地手动排序
    if (!this.groupedHostCardsActive() && this.hostManualOrder.length > 0) {
      this.filteredHosts = this.applyManualSortOrder(this.filteredHosts);
    }
    this.hostDataSource.replaceAll(this.filteredHosts);
    this.hostViewRevision += 1;
  }

  /** 根据本地保存的手动排序顺序重排主机列表。已排序的主机按保存顺序排列，新主机追加到末尾。 */
  private applyManualSortOrder(hosts: RemoteHost[]): RemoteHost[] {
    if (this.hostManualOrder.length === 0) { return hosts; }
    const orderMap: Map<string, number> = new Map<string, number>();
    for (let i = 0; i < this.hostManualOrder.length; i++) {
      orderMap.set(this.hostManualOrder[i], i);
    }
    const sorted: RemoteHost[] = hosts.slice();
    sorted.sort((a: RemoteHost, b: RemoteHost): number => {
      const oa: number = orderMap.has(a.id) ? (orderMap.get(a.id) as number) : Number.MAX_SAFE_INTEGER;
      const ob: number = orderMap.has(b.id) ? (orderMap.get(b.id) as number) : Number.MAX_SAFE_INTEGER;
      if (oa !== ob) { return oa - ob; }
      return 0;
    });
    return sorted;
  }

  // CRUD handlers use the same immediate snapshot refresh as the classic list.
  // Cloud callbacks remain responsible for later cross-device reconciliation.
  private refreshHostSnapshotAfterMutation(): void {
    if (this.pageActive) { this.refreshHostListView(true); }
  }

  private visibleHostsForCurrentMode(): RemoteHost[] {
    if (this.groupedHostCardsActive()) {
      return searchHosts(this.hosts, this.searchText);
    }
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
      this.windowH = d.height;
      this.isFullScreen = (d.width >= d.width - 4);
    } catch (_err) {
      this.windowW = 360;
      this.windowH = 720;
    }
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
    const localSaved: boolean = this.persistPreferenceValue(key, hex);
    const cloudSaved: boolean = CloudStore.getInstance().upsertUserSetting(key, hex);
    this.reportPreferencePersistence(localSaved, cloudSaved);
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
    // On xl the title and search field share one compact header row. Keep the
    // list spacer in sync so the first host card starts below that row.
    return this.topSafeHeightVp() + (this.breakpoint === 'xl' ? 72 : 96);
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

  private mutationFailureMessage(fallback: string): string {
    const message: string = CloudStore.getInstance().getLastMutationResult().message.trim();
    return message === '' ? fallback : message;
  }

  private async doHostBatchDelete(): Promise<void> {
    const selectedKeys: string[] = Array.from(this.hostSelectedIds);
    if (selectedKeys.length === 0) { return; }
    const remoteHosts: RemoteHost[] = [];
    const moonlightViews: MoonlightHostLocalView[] = [];
    for (let index: number = 0; index < selectedKeys.length; index++) {
      const key: string = selectedKeys[index];
      const remoteId: string = remoteHostIdFromCardKey(key) ||
        (this.hosts.some((host: RemoteHost): boolean => host.id === key) ? key : '');
      const moonlightId: string = moonlightHostIdFromCardKey(key);
      if (remoteId !== '') {
        const host: RemoteHost | undefined = this.hosts.find(
          (candidate: RemoteHost): boolean => candidate.id === remoteId);
        if (host !== undefined) { remoteHosts.push(host); }
      } else if (moonlightId !== '') {
        const view: MoonlightHostLocalView | undefined = this.moonlightHosts.find(
          (candidate: MoonlightHostLocalView): boolean =>
            candidate.host !== null && candidate.host.id === moonlightId);
        if (view !== undefined && view.host !== null) { moonlightViews.push(view); }
      }
    }
    for (let index: number = 0; index < remoteHosts.length; index++) {
      if (!remoteHosts[index].locked) { continue; }
      const gate: LockGateResult = await showLockGate(remoteHosts[index].label, 'biometric');
      if (!gate.ok) {
        const message: string = lockGateErrorMessage(gate);
        if (message !== '') { promptAction.showToast({ message: message, duration: 2000 }); }
        return;
      }
    }
    for (let index: number = 0; index < moonlightViews.length; index++) {
      const host: MoonlightHost = moonlightViews[index].host as MoonlightHost;
      if (host.locked !== true) { continue; }
      const gate: LockGateResult = await showLockGate(host.displayName, 'biometric');
      if (!gate.ok) {
        const message: string = lockGateErrorMessage(gate);
        if (message !== '') { promptAction.showToast({ message: message, duration: 2000 }); }
        return;
      }
    }
    const moonlightLease: AccountSessionLease | null = moonlightViews.length === 0
      ? null : this.moonlightDeletionRuntime.currentLease();
    const moonlightPreviews: MoonlightDeletionPreview[] = [];
    if (moonlightViews.length > 0 && (moonlightLease === null ||
        !this.moonlightDeletionRuntime.isLeaseCurrent(moonlightLease))) {
      promptAction.showToast({ message: 'Moonlight 数据域已变化，请刷新后重试', duration: 2200 });
      return;
    }
    for (let index: number = 0; index < moonlightViews.length; index++) {
      const host: MoonlightHost = moonlightViews[index].host as MoonlightHost;
      const preview: MoonlightDeletionPreview = this.moonlightDeletionRuntime.preview(
        moonlightLease as AccountSessionLease, 'forget_host', host.id);
      if (preview.code !== 'ok') {
        promptAction.showToast({
          message: preview.code === 'cloud_unavailable'
            ? 'Moonlight 云端状态尚未就绪，未删除任何主机'
            : 'Moonlight 主机数据已变化，请刷新后重试：' + preview.code,
          duration: 2400
        });
        return;
      }
      moonlightPreviews.push(preview);
    }
    const dialogResult: Object = await promptAction.showDialog({
      title: '批量删除',
      message: '确定要删除选中的 ' + selectedKeys.length +
        ' 个主机吗？Moonlight 主机还会清理配对信任、应用配置和目录缓存。',
      buttons: [
        { text: '取消', color: this.pal().text2 },
        { text: '删除', color: this.pal().danger }
      ]
    });
    const selected: Record<string, number> = dialogResult as Record<string, number>;
    if (selected['index'] !== 1 || !this.pageActive) { return; }
    if (moonlightLease !== null) {
      const currentLease: AccountSessionLease | null = this.moonlightDeletionRuntime.currentLease();
      if (currentLease === null || !this.moonlightDeletionRuntime.isLeaseCurrent(moonlightLease) ||
          !accountSessionLeaseEquals(currentLease, moonlightLease)) {
        promptAction.showToast({ message: '账号状态已变化，未执行删除', duration: 2200 });
        return;
      }
    }
    const failedKeys: Set<string> = new Set<string>();
    const regularIds: string[] = [];
    for (let index: number = 0; index < remoteHosts.length; index++) {
      const host: RemoteHost = remoteHosts[index];
      const vncId: string = this.vncRecordIdForHost(host);
      if (vncId !== '') {
        if (!this.vncHosts.remove(vncId)) { failedKeys.add(remoteHostCardKey(host.id)); }
      } else {
        regularIds.push(host.id);
      }
    }
    if (regularIds.length > 0) { this.srv.removeHosts(regularIds); }
    for (let index: number = 0; index < regularIds.length; index++) {
      if (this.srv.getHost(regularIds[index]) !== undefined) {
        failedKeys.add(remoteHostCardKey(regularIds[index]));
      }
    }
    for (let index: number = 0; index < moonlightPreviews.length; index++) {
      const result: MoonlightDeletionCommandResult = await this.moonlightDeletionRuntime.execute(
        moonlightLease as AccountSessionLease, moonlightPreviews[index]);
      if (!result.ok) {
        failedKeys.add(unifiedMoonlightHostCardKey(moonlightPreviews[index].hostId));
      }
    }
    const succeeded: Set<string> = new Set<string>();
    for (let index: number = 0; index < selectedKeys.length; index++) {
      if (!failedKeys.has(selectedKeys[index])) { succeeded.add(selectedKeys[index]); }
    }
    this.hostManualOrder = this.hostManualOrder.filter(
      (key: string): boolean => !succeeded.has(key));
    this.persistHostManualOrder();
    this.refreshHostSnapshotAfterMutation();
    this.refreshMoonlightDirectory();
    this.hostViewRevision += 1;
    this.hostSelectionMode = failedKeys.size > 0;
    this.hostReorderEnabled = false;
    this.hostSelectedIds = failedKeys;
    if (failedKeys.size > 0) {
      promptAction.showToast({
        message: failedKeys.size.toString() + ' 个主机删除失败，已保留选择，请重试',
        duration: 2600
      });
    } else {
      promptAction.showToast({ message: '已删除 ' + succeeded.size.toString() + ' 个主机', duration: 1800 });
    }
  }

  private toggleHostSelect(id: string, checked: boolean): void {
    const next: Set<string> = new Set(this.hostSelectedIds);
    if (checked) { next.add(id); } else { next.delete(id); }
    this.hostSelectedIds = next;
  }

  /** 拖拽重排回调: 在同一个未分类卡片序列中移动任意协议。 */
  private handleHostMove(draggingKey: string, targetKey: string): void {
    const refs: UnifiedHostCardRef[] = this.flatHostCardRefs();
    const previousVisible: string[] = refs.map((ref: UnifiedHostCardRef): string => ref.key);
    const nextVisible: string[] = moveUnifiedHostCard(previousVisible, draggingKey, targetKey);
    this.hostManualOrder = mergeVisibleHostOrder(this.hostManualOrder, previousVisible, nextVisible);
    this.hostViewRevision += 1;
  }

  /** 完成排序: 将当前显示顺序持久化到本地 Preferences 并退出编辑模式 */
  private commitHostReorder(): void {
    this.persistHostManualOrder();
    const refs: UnifiedHostCardRef[] = this.allHostCardRefsForOrder();
    let orderFailed: boolean = false;
    let moonlightOrder: number = 0;
    const now: number = Date.now();
    for (let index: number = 0; index < refs.length; index++) {
      if (refs[index].kind !== 'moonlight') { continue; }
      const result: MoonlightLocalHostMutationResult = this.moonlightLocalHostService.updateUserOrder(
        refs[index].hostId, moonlightOrder, now + moonlightOrder);
      orderFailed = !result.ok || orderFailed;
      moonlightOrder += 1;
    }
    this.refreshMoonlightDirectory();
    this.hostReorderOriginalOrder = [];
    animateTo({ duration: 200, curve: Curve.FastOutSlowIn }, (): void => {
      this.hostSelectionMode = false;
      this.hostReorderEnabled = false;
      this.hostSelectedIds = new Set();
      this.hostViewRevision += 1;
    });
    if (orderFailed) {
      promptAction.showToast({ message: '排序已保存到本机，但部分 Moonlight 云同步顺序更新失败', duration: 2400 });
    }
  }

  /** 取消编辑: 丢弃拖拽变更, 从 Preferences 恢复原始排序 */
  private cancelHostEdit(): void {
    this.hostManualOrder = this.hostReorderOriginalOrder.slice();
    this.hostReorderOriginalOrder = [];
    animateTo({ duration: 200, curve: Curve.FastOutSlowIn }, (): void => {
      this.hostSelectionMode = false;
      this.hostReorderEnabled = false;
      this.hostSelectedIds = new Set();
      this.hostViewRevision += 1;
    });
    // 从服务层重新加载原始排序
    this.refreshHostSnapshotAfterMutation();
  }

  /** 将手动排序顺序写入本地 Preferences (不触发云同步) */
  private persistHostManualOrder(): void {
    this.reportPreferencePersistence(this.persistPreferenceValue(
      'hostManualSortOrder', JSON.stringify(this.hostManualOrder)));
  }

  @Builder hostDragPreviewBuilder(host: RemoteHost) {
    Row() {
      Column() {
        Image(host.protocol === 'ssh' ? $r('app.media.icon_terminal') :
          (host.protocol === 'rdp' ? $r('app.media.icon_desktop') : $r('app.media.icon_laptop')))
          .width(24).height(24).fillColor(Color.White)
      }
      .width(42).height(42).borderRadius(21)
      .backgroundColor(host.protocol === 'ssh' ? this.pal().editColor :
        (host.protocol === 'rdp' ? this.accentColor : this.pal().success))
      .justifyContent(FlexAlign.Center)
      .margin({ right: 10 })

      Text(host.label || host.host)
        .fontSize(16).fontWeight(FontWeight.Medium).fontColor(this.pal().text)
        .layoutWeight(1)

      SymbolGlyph($r('sys.symbol.line_3_horizontal'))
        .fontSize(20).fontColor([this.pal().text3])
    }
    .width(this.windowW > 0 ? Math.min(this.windowW - 32, 600) : 320)
    .height(66).padding(12)
    .borderRadius(14).backgroundColor(this.pal().card)
    .shadow({ radius: 16, color: '#33000000', offsetY: 4 })
  }

  private onSearchChange(value: string): void {
    this.searchText = value;
    if (this.searchTimer !== -1) { clearTimeout(this.searchTimer); }
    this.searchTimer = setTimeout(() => {
      this.refreshFilteredHostView();
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

  /**
   * PC/2-in-1 sessions are independent multiton abilities. Phone and tablet
   * keep the existing in-app router flow. Desktop must never silently fall
   * back to an in-window route: that would turn a window-launch failure into
   * the exact single-window navigation regression this boundary prevents.
   */
  private openSessionDestination(url: string, params: Record<string, Object>,
    authorizationKind: RemoteSessionWindowAuthorizationKind): void {
    if (!this.isDesktopDevice) {
      void router.pushUrl({ url, params });
      return;
    }
    let target: RemoteSessionWindowTarget;
    let protocol: RemoteSessionWindowProtocol;
    let hostId: string = '';
    let title: string = '远程会话';
    if (url === 'pages/SshTerminal') {
      target = 'ssh_terminal';
      protocol = 'ssh';
      hostId = ((params['hostId'] as string) || '').trim();
      const host: RemoteHost | undefined = this.srv.getHost(hostId);
      title = host === undefined ? 'SSH 终端' : host.label + ' — SSH';
    } else if (url === 'pages/RemoteDesktop') {
      target = 'remote_desktop';
      const vncHostId: string = ((params['vncHostId'] as string) || '').trim();
      if (vncHostId.length > 0) {
        protocol = 'vnc';
        hostId = vncHostId;
        const vncHost: VncHostView | null = this.vncHosts.find(vncHostId);
        title = vncHost === null ? 'VNC 会话' : vncHost.label + ' — VNC';
      } else {
        hostId = ((params['hostId'] as string) || '').trim();
        const host: RemoteHost | undefined = this.srv.getHost(hostId);
        if (host === undefined || (host.protocol !== 'rdp' && host.protocol !== 'rustdesk')) {
          promptAction.showToast({ message: '无法识别远程会话，未打开窗口', duration: 2200 });
          return;
        }
        protocol = host.protocol === 'rustdesk' ? 'rustdesk' : 'rdp';
        title = host.label + (protocol === 'rdp' ? ' — RDP' : ' — RustDesk');
      }
    } else { return; }
    const routeParams: Record<string, Object> = {};
    Object.keys(params).forEach((key: string): void => { routeParams[key] = params[key]; });
    // The HostList lock gate has already committed before any authorization
    // handoff can be staged. Preserve that original result so the existing
    // session page cannot ask for the same biometric twice.
    routeParams['authenticated'] = true;
    if (protocol === 'rdp' || protocol === 'vnc' || protocol === 'ssh') {
      // Certificate/host-key preflight is not the remote protocol's login
      // commit. Keep the original RemoteDesktop/SshTerminal authentication UI
      // in this ability, then let that page transfer the connected native
      // session to a new PC window. No window is created on cancel/failure.
      routeParams['pcWindowAfterAuthentication'] = true;
      routeParams['pcWindowPreflightKind'] = authorizationKind;
      void router.pushUrl({ url, params: routeParams }).catch((_err: Error): void => {
        promptAction.showToast({ message: '无法打开原鉴权流程，未创建会话窗口', duration: 2200 });
      });
      return;
    }
    const authorizationToken: string =
      RemoteSessionWindowAuthorizationService.getInstance().issue(
        protocol, hostId, authorizationKind);
    if (authorizationToken.length === 0) {
      promptAction.showToast({ message: '连接鉴权状态无效，未打开独立窗口', duration: 2200 });
      return;
    }
    const request: RemoteSessionWindowRequest = {
      target,
      protocol,
      hostId,
      title,
      authorizationToken,
      routeParams
    };
    let nativeHandoff: RemoteSessionWindowNativeHandoff | null = null;
    let rustDeskHandoffIdentity: ActiveRemoteSessionRecord | null = null;
    let rustDeskDisconnectIdentity: NativeDisconnectIdentity | null = null;
    let rustDeskHandoffGeneration: number = 0;
    if (protocol === 'rustdesk') {
      const registry: ActiveRemoteSessionRegistry = ActiveRemoteSessionRegistry.getInstance();
      const active: ActiveRemoteSessionRecord | null = registry.getActive();
      if (active === null || active.hostId !== hostId ||
        active.protocol !== RemoteProtocol.rustdesk || !active.protocolConnected ||
        active.sessionId <= 0 || this.loader.getSessionId() !== active.sessionId) {
        RemoteSessionWindowAuthorizationService.getInstance().revoke(authorizationToken);
        promptAction.showToast({ message: 'RustDesk 已鉴权会话交接失败，未打开窗口', duration: 2400 });
        return;
      }
      rustDeskDisconnectIdentity =
        this.loader.captureDisconnectIdentity(active.sessionId);
      if (rustDeskDisconnectIdentity === null) {
        RemoteSessionWindowAuthorizationService.getInstance().revoke(authorizationToken);
        promptAction.showToast({ message: 'RustDesk 会话所有权已变化，未打开窗口', duration: 2400 });
        return;
      }
      const authenticatedHandoff: RemoteSessionWindowNativeHandoff =
        new RemoteSessionWindowNativeHandoff(this.loader, registry, active);
      nativeHandoff = authenticatedHandoff;
      rustDeskHandoffIdentity = active;
      rustDeskHandoffGeneration = nextRemoteSessionHandoffGeneration(
        this.rustDeskWindowHandoffGeneration);
      this.rustDeskWindowHandoffGeneration = rustDeskHandoffGeneration;
    }
    let context: common.UIAbilityContext;
    try {
      context = getContext(this) as common.UIAbilityContext;
    } catch (_err) {
      RemoteSessionWindowAuthorizationService.getInstance().revoke(authorizationToken);
      promptAction.showToast({ message: '独立窗口上下文不可用，未打开会话', duration: 2200 });
      return;
    }
    void RemoteSessionWindowLauncher.open(context, request, nativeHandoff).then((opened: boolean): void => {
      if (opened) { return; }
      if (rustDeskHandoffIdentity !== null) {
        this.discardFailedRustDeskWindowHandoff(
          rustDeskHandoffIdentity, rustDeskHandoffGeneration,
          rustDeskDisconnectIdentity);
      }
      promptAction.showToast({ message: '独立窗口启动失败，未打开会话', duration: 2200 });
    }).catch((_err: Error): void => {
      if (rustDeskHandoffIdentity !== null) {
        this.discardFailedRustDeskWindowHandoff(
          rustDeskHandoffIdentity, rustDeskHandoffGeneration,
          rustDeskDisconnectIdentity);
      }
      promptAction.showToast({ message: '独立窗口启动失败', duration: 2200 });
    });
  }

  private discardFailedRustDeskWindowHandoff(expected: ActiveRemoteSessionRecord,
    operationGeneration: number,
    disconnectIdentity: NativeDisconnectIdentity | null): void {
    const registry: ActiveRemoteSessionRegistry = ActiveRemoteSessionRegistry.getInstance();
    const active: ActiveRemoteSessionRecord | null = registry.getActive();
    if (disconnectIdentity === null || !remoteSessionHandoffFailureOwnsSession(
      expected, active, this.loader.getSessionId(), operationGeneration,
      this.rustDeskWindowHandoffGeneration)) {
      return;
    }
    this.rustDeskWindowHandoffGeneration = nextRemoteSessionHandoffGeneration(
      this.rustDeskWindowHandoffGeneration);
    const termination: ActiveRemoteSessionTermination | null =
      registry.beginTermination(active as ActiveRemoteSessionRecord, null);
    if (termination === null) { return; }
    this.submitFailedRustDeskWindowHandoffTeardown(
      registry, termination, disconnectIdentity);
  }

  private submitFailedRustDeskWindowHandoffTeardown(
    registry: ActiveRemoteSessionRegistry,
    termination: ActiveRemoteSessionTermination,
    disconnectIdentity: NativeDisconnectIdentity
  ): void {
    if (!registry.isTerminationCurrent(termination)) { return; }
    const submission: NativeDisconnectSubmission =
      this.loader.disconnectWithReceipt(disconnectIdentity);
    if (!submission.accepted) {
      if (!submission.retryable) {
        hilog.error(0x0001, 'HostList',
          'RustDesk failed-window teardown owner changed before submission');
        return;
      }
      setTimeout((): void => {
        this.submitFailedRustDeskWindowHandoffTeardown(
          registry, termination, disconnectIdentity);
      }, 250);
      return;
    }
    if (submission.terminal) {
      if (submission.successful) {
        registry.completeTermination(termination);
      } else {
        hilog.error(0x0001, 'HostList',
          'RustDesk failed-window synchronous teardown failed');
      }
      return;
    }
    this.waitForFailedRustDeskWindowHandoffTeardown(
      registry, termination, submission.requestId);
  }

  private waitForFailedRustDeskWindowHandoffTeardown(
    registry: ActiveRemoteSessionRegistry,
    termination: ActiveRemoteSessionTermination,
    requestId: number
  ): void {
    void this.loader.waitForTeardownRequest(requestId).then((completed: boolean): void => {
      if (!registry.isTerminationCurrent(termination)) { return; }
      if (completed) {
        registry.completeTermination(termination);
        return;
      }
      const state: number = this.loader.getDisconnectState(requestId);
      if (nativeDisconnectStateIsFailed(state) || state === 0) {
        hilog.error(0x0001, 'HostList',
          'RustDesk failed-window teardown not successful request=' +
          requestId.toString() + ' state=' + state.toString());
        return;
      }
      setTimeout((): void => {
        this.waitForFailedRustDeskWindowHandoffTeardown(
          registry, termination, requestId);
      }, 250);
    }).catch((err: Error): void => {
      if (!registry.isTerminationCurrent(termination)) { return; }
      hilog.warn(0x0001, 'HostList',
        'RustDesk failed-window teardown wait unavailable request=' +
        requestId.toString() + ' err=' +
        (err.message ? err.message : JSON.stringify(err)));
      setTimeout((): void => {
        this.waitForFailedRustDeskWindowHandoffTeardown(
          registry, termination, requestId);
      }, 250);
    });
  }

  private async connectToHost(host: RemoteHost): Promise<void> {
    hilog.info(0x0001, 'HostList', 'connectToHost: proto=' + host.protocol +
      ' host=' + maskHost(host.host) + ':' + host.port);
    const moonlightReleased: boolean = MoonlightSessionCoordinator.getInstance()
      .reconcileNativeTerminalReceipt();
    const processActive: ActiveRemoteSessionRecord | null =
      ActiveRemoteSessionRegistry.getInstance().getActive();
    if (!moonlightReleased && processActive !== null &&
        processActive.protocol === RemoteProtocol.moonlight) {
      this.clearPendingVncCredentialForRemoteHost(host);
      promptAction.showToast({
        message: 'Moonlight 正在安全释放媒体与输入资源，请稍后重试', duration: 2200
      });
      return;
    }
    const protocolNeedsArbitration: boolean = host.protocol === 'rdp' ||
      host.protocol === 'rustdesk' || host.protocol === 'vnc';
    const connectionGeneration: number = protocolNeedsArbitration ?
      this.beginConnectionAttempt(host.id) : 0;
    if (protocolNeedsArbitration && connectionGeneration === 0) {
      if (host.id !== this.connectionAttemptHostId) {
        this.clearPendingVncCredentialForRemoteHost(host);
      }
      promptAction.showToast({ message: '已有连接请求正在处理，请等待当前弹窗结束', duration: 1800 });
      return;
    }
    if (lanHostUsesLocalOnlyStorage(host)) {
      promptAction.showToast({ message: '正在刷新局域网动态地址…', duration: 1200 });
      await this.refreshDynamicLanHosts(true, host.id);
      const refreshed: RemoteHost | undefined = this.srv.getHost(host.id);
      if (refreshed !== undefined && lanHostUsesLocalOnlyStorage(refreshed)) {
        host = RemoteHost.fromJSON(refreshed.toJSON());
      }
      if (protocolNeedsArbitration &&
        !this.isCurrentConnectionAttempt(host.id, connectionGeneration)) {
        return;
      }
    }
    if (host.locked) {
      const r = await showLockGate(host.label, 'biometric');
      if (protocolNeedsArbitration &&
        !this.isCurrentConnectionAttempt(host.id, connectionGeneration)) {
        return;
      }
      if (!r.ok) {
        this.clearPendingVncCredentialForRemoteHost(host);
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
      const storedProxyProfile: SshProxyProfileV1 | null = this.sshProxyProfiles.load(host.id);
      if (storedProxyProfile !== null) {
        const proxyPlan: SshProxyRuntimePlan = resolveSshProxyRuntimePlan(host, storedProxyProfile);
        if (!proxyPlan.valid) {
          promptAction.showToast({ message: proxyPlan.message, duration: 2400 });
          return;
        }
        if (proxyPlan.route.type === 'ssh_jump' &&
          !sshProxyRuntimeHasStrictJumpBindings(proxyPlan)) {
          promptAction.showToast({
            message: 'ProxyJump 每一跳都必须填写 SHA256 host-key 指纹', duration: 2600
          });
          return;
        }
        // The legacy preflight API can only authenticate a single flat hop.
        // Credential-bearing profiles are handed to the terminal's one-shot
        // broker, where all ordered hops and dynamic MFA prompts are retained.
        if (proxyPlan.route.type === 'ssh_jump' ||
          sshProxyRuntimeNeedsTerminalSecrets(proxyPlan)) {
          const sshParams: Record<string, Object> = {};
          sshParams['hostId'] = host.id;
          sshParams['authenticated'] = true;
          this.openSessionDestination('pages/SshTerminal', sshParams, 'ssh_broker_handoff');
          return;
        }
      }
      // T-210: SSH 前置校验 (指纹 + 私钥密码) → 通过后才路由
      this.openSshPreflight(host);
    } else if (host.protocol === 'rdp') {
      this.openRdpCertificatePreflight(host);
    } else if (host.protocol === 'rustdesk') {
      const relay: RustDeskRelayConfig | undefined = host.rustdeskDirectEnabled ? undefined :
        this.srv.getAllRelays().find((item: RustDeskRelayConfig): boolean => item.id === host.rustdeskRelayId);
      const connectionContext: RustDeskConnectionContext =
        this.rustDeskConnectionContext(host, relay);
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
        proManaged: relay !== undefined && connectionContext.requiresAccount
      });
      if (rustDeskError !== '') {
        this.releaseConnectionAttempt(host.id);
        promptAction.showToast({ message: rustDeskError, duration: 2600 });
        return;
      }
      if (shouldOpenRustDeskProPreflight(host.protocol, host.sourceType, host.rustdeskProManaged)) {
        this.openRustDeskProPreflight(host);
      } else {
        // Fail closed if a future policy ever removes this host from the
        // preflight owner. A desktop window may only receive an already-live,
        // authenticated RustDesk session through the atomic handoff below.
        this.releaseConnectionAttempt(host.id);
        promptAction.showToast({ message: 'RustDesk 鉴权流程不可用，未打开独立窗口', duration: 2400 });
      }
    } else if (host.protocol === 'vnc') {
      const vncHostId: string = this.vncRecordIdForHost(host);
      if (vncHostId === '') {
        this.clearPendingVncCredentialForRemoteHost(host);
        this.releaseConnectionAttempt(host.id);
        promptAction.showToast({ message: 'VNC 主机记录无效，请重新添加', duration: 2200 });
        return;
      }
      const vncHost: VncHostView | null = this.vncHosts.find(vncHostId);
      if (vncHost === null) {
        this.clearPendingVncCredentialForRemoteHost(host);
        this.releaseConnectionAttempt(host.id);
        promptAction.showToast({ message: 'VNC 主机记录不存在，请刷新后重试', duration: 2200 });
        return;
      }
      this.openVncCertificatePreflight(vncHost, host.id, connectionGeneration);
    } else {
      this.releaseConnectionAttempt(host.id);
      promptAction.showToast({ message: '暂不支持该连接协议', duration: 2000 });
    }
  }

  private openRdpCertificatePreflight(host: RemoteHost): void {
    if (this.rdpCertificateClosing || this.showRdpCertificatePreflight ||
      this.remoteHostSheetClosing || this.showRemoteHostSheet) {
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
    this.rdpGatewayCertificateInfo = null;
    this.rdpCertificateRouteResult = null;
    this.rdpCertificateError = '';
    this.rdpCertificateErrorStage = '';
    this.rdpCertificateErrorCode = '';
    this.rdpCertificateShowDetails = false;
    this.rdpGatewayPreflightOneTimeFingerprint = '';
    this.rdpGatewayPreflightOneTimeAllowUntrustedRoot = false;
    this.rdpGatewayPreflightOneTimeAllowHostMismatch = false;
    this.rdpGatewayPreflightOneTimeAllowTimeAnomaly = false;
    this.rdpGatewayPreflightOneTimeRouteIdentity = '';
    this.showRdpCertificatePreflight = shouldShowRdpCertificateProbeSheetBeforeProbe(
      host.rdpCertificateTrustMode,
      host.rdpCertificateFingerprintSha256,
      this.rdpCertificateTrustRouteBound(host)
    );
    if (this.showRdpCertificatePreflight) {
      this.openSheetSafely((): void => {
        this.openRemoteHostSheet(REMOTE_HOST_SHEET_RDP_CERTIFICATE, (): void => { });
      }, true);
    }
    this.doRdpCertificateProbe(host, generation);
  }

  private getRdpCertificateHost(): RemoteHost | undefined {
    return this.srv.getHost(this.rdpCertificateHostId);
  }

  private rdpCertificateRouteMode(host: RemoteHost): string {
    return normalizeRdpEndpointMode(host.rdpEndpointMode, host.gatewayHost);
  }

  private rdpCertificateTrustRouteBound(host: RemoteHost): boolean {
    const routeIdentity: string = rdpRouteIdentity(host);
    if (!rdpCertificateRouteIsCurrent(host.rdpCertificateRouteIdentity, routeIdentity)) {
      return false;
    }
    return this.rdpCertificateRouteMode(host) !== 'microsoft_rd_gateway' ||
      rdpCertificateRouteIsCurrent(host.rdpGatewayCertificateRouteIdentity, routeIdentity);
  }

  private rdpCertificateUsesRouteProbe(host: RemoteHost): boolean {
    const mode: string = this.rdpCertificateRouteMode(host);
    return mode !== 'direct_rdp' && mode !== 'transparent_tcp_rdp';
  }

  private rdpCertificateCredentialParts(host: RemoteHost): RdpCertificateCredentialParts {
    const authMode: RdpAuthMode = normalizeRdpAuthMode(host.rdpAuthMode);
    let username: string = host.username;
    let password: string = authMode === 'password' ? host.password : '';
    if (authMode === 'password' && host.rdpCredentialId.trim() !== '') {
      const credential: RdpCredential | undefined = this.srv.getRdpCredential(
        host.rdpCredentialId.trim());
      if (credential === undefined) {
        // A stale credential binding must not fall back to a possibly empty
        // host password and accidentally look like a blank-password account.
        hilog.warn(0x0001, 'HostList',
          'RDP Gateway preflight credential binding is unavailable; forcing auth failure');
        username = '';
        password = '';
      } else {
        username = credential.username;
        password = credential.password;
        if (username.trim() === '' || password.length === 0) {
          // An empty password on a bound credential means the encrypted
          // store is still locked or the row is corrupt; it is not the
          // explicit blank-password RDP mode.
          username = '';
          password = '';
        }
      }
    }
    if (authMode === 'password' && password.length === 0) {
      // Keep password-auth failures distinct from the explicit blank-password
      // mode so a Gateway cannot accidentally receive an empty credential.
      username = '';
    }
    const identity = normalizeRdpCredentialParts(
      username, AppStorage.get<number>('rdpAuthIdentityMode') ?? 1);
    return { username: identity.username, password, domain: identity.domain };
  }

  private rdpCertificateRouteRequest(host: RemoteHost, generation: number): RdpPreflightRequest {
    const mode = this.rdpCertificateRouteMode(host) as
      'direct_rdp' | 'transparent_tcp_rdp' | 'microsoft_rd_gateway' |
      'vendor_https_bastion' | 'azure_bastion' | 'unknown_gateway';
    const credentials = this.rdpCertificateCredentialParts(host);
    const routeIdentity: string = rdpRouteIdentity(host);
    const useOneTimeGatewayTrust: boolean =
      this.rdpGatewayPreflightOneTimeFingerprint.length > 0 &&
      rdpCertificateRouteIsCurrent(
        this.rdpGatewayPreflightOneTimeRouteIdentity, routeIdentity);
    return {
      route: {
        endpointMode: mode,
        targetHost: host.host,
        targetPort: host.port,
        targetServerName: host.customHostname || host.host,
        gatewayHost: host.gatewayHost,
        gatewayPort: host.gatewayPort > 0 ? host.gatewayPort : 443,
        gatewayServerName: host.rdpGatewayServerName || host.gatewayHost,
        gatewayTransport: (host.rdpGatewayTransport || 'auto') as
          'auto' | 'http' | 'rpc' | 'websocket' | 'no-websockets'
      },
      username: credentials.username,
      password: credentials.password,
      domain: credentials.domain,
      targetRestrictedAdmin: normalizeRdpAuthMode(host.rdpAuthMode) === 'restricted_admin',
      expectedTargetFingerprintSha256: host.rdpCertificateFingerprintSha256,
      expectedGatewayFingerprintSha256: useOneTimeGatewayTrust ?
        this.rdpGatewayPreflightOneTimeFingerprint : host.rdpGatewayCertificateFingerprintSha256,
      targetAllowUntrustedRoot: host.rdpCertificateAllowUntrustedRoot,
      targetAllowHostMismatch: host.rdpCertificateAllowHostMismatch,
      targetAllowTimeAnomaly: false,
      gatewayAllowUntrustedRoot: useOneTimeGatewayTrust ?
        this.rdpGatewayPreflightOneTimeAllowUntrustedRoot :
        host.rdpGatewayCertificateAllowUntrustedRoot,
      gatewayAllowHostMismatch: useOneTimeGatewayTrust ?
        this.rdpGatewayPreflightOneTimeAllowHostMismatch :
        host.rdpGatewayCertificateAllowHostMismatch,
      gatewayAllowTimeAnomaly: useOneTimeGatewayTrust &&
        this.rdpGatewayPreflightOneTimeAllowTimeAnomaly,
      generation,
      requestId: host.id + ':' + generation.toString()
    };
  }

  private rdpCertificateInfoFromRecord(record: RdpCertificateRecord): RdpCertificateInfo {
    return {
      ok: record.present,
      host: record.host,
      port: record.port,
      serverName: record.serverName,
      commonName: record.commonName,
      subject: record.subject,
      issuer: record.issuer,
      fingerprintSha256: record.fingerprintSha256,
      notBeforeMs: record.notBeforeMs,
      notAfterMs: record.notAfterMs,
      flags: record.flags,
      rootTrusted: record.rootTrusted,
      hostMismatch: record.hostMismatch,
      errorCode: record.present ? 0 : -1,
      errorMessage: record.present ? '' : '未收到该阶段的证书',
      preflightStatus: record.present ? 'completed' : 'inconclusive',
      riskFlags: record.riskFlags || []
    };
  }

  private rdpCertificateResultFromDirectProbe(host: RemoteHost,
    info: RdpCertificateInfo, generation: number): RdpPreflightResult {
    return {
      ok: info.ok && info.fingerprintSha256.length > 0,
      preflightStatus: info.ok ? 'completed' :
        (info.preflightStatus || 'unavailable'),
      riskFlags: info.riskFlags || [],
      gatewayRiskFlags: [],
      targetRiskFlags: info.riskFlags || [],
      endpointMode: this.rdpCertificateRouteMode(host),
      routeIdentity: rdpRouteIdentity(host),
      generation,
      requestId: host.id + ':' + generation.toString(),
      stage: info.ok ? 'target' : rdpCertificateLegacyProbeStage(info.errorCode),
      errorCode: info.ok ? '' : rdpCertificateLegacyProbeErrorCode(info.errorCode),
      errorMessage: info.errorMessage,
      gatewayTransportRequested: host.rdpGatewayTransport || 'auto',
      gatewayTransportNegotiated: 'unknown',
      gatewayTransportSelected: host.rdpGatewayTransport || 'auto',
      requiresGatewayAuth: false,
      requiresUserDecision: info.ok || rdpCertificatePreflightAllowsRealConnection(
        info.preflightStatus, info.errorCode),
      gatewayCertificate: {
        present: false, rootTrusted: false, hostMismatch: false, flags: 0,
        host: host.gatewayHost, port: host.gatewayPort, stage: 'gateway',
        serverName: host.rdpGatewayServerName || host.gatewayHost,
        commonName: '', subject: '', issuer: '', fingerprintSha256: '',
        notBeforeMs: 0, notAfterMs: 0, riskFlags: []
      },
      targetCertificate: {
        present: info.ok && info.fingerprintSha256.length > 0,
        rootTrusted: info.rootTrusted,
        hostMismatch: info.hostMismatch,
        flags: info.flags,
        host: info.host,
        port: info.port,
        stage: 'target',
        serverName: host.customHostname || host.host,
        commonName: info.commonName,
        subject: info.subject,
        issuer: info.issuer,
        fingerprintSha256: info.fingerprintSha256,
        notBeforeMs: info.notBeforeMs,
        notAfterMs: info.notAfterMs,
        riskFlags: info.riskFlags || []
      }
    };
  }

  private combineRdpCertificateStates(
    target: RdpCertificatePreflightState,
    gateway: RdpCertificatePreflightState | null
  ): RdpCertificatePreflightState {
    const states: RdpCertificatePreflightState[] = gateway === null ? [target] : [target, gateway];
    if (states.indexOf(RdpCertificatePreflightState.ERROR) >= 0) {
      return RdpCertificatePreflightState.ERROR;
    }
    if (states.indexOf(RdpCertificatePreflightState.CERTIFICATE_CHANGED) >= 0) {
      return RdpCertificatePreflightState.CERTIFICATE_CHANGED;
    }
    if (states.indexOf(RdpCertificatePreflightState.TRUST_FIRST_TIME) >= 0) {
      return RdpCertificatePreflightState.TRUST_FIRST_TIME;
    }
    return RdpCertificatePreflightState.TRUSTED_MATCH;
  }

  private rdpCertificateWarningForRoute(host: RemoteHost,
    target: RdpCertificateInfo, gateway: RdpCertificateInfo): string {
    const result: RdpPreflightResult | null = this.rdpCertificateRouteResult;
    const gatewayFlags: string[] = result === null ? gateway.riskFlags :
      rdpCertificateEffectiveRiskFlags(result.gatewayRiskFlags, gateway.riskFlags);
    const targetFlags: string[] = result === null ? target.riskFlags :
      rdpCertificateEffectiveRiskFlags(result.targetRiskFlags, target.riskFlags);
    const structuredRisk: string = rdpCertificateRiskSummary(
      gatewayFlags.concat(targetFlags));
    const gatewayRisk: string = rdpCertificateRiskSummary(gatewayFlags);
    const targetRisk: string = rdpCertificateRiskSummary(targetFlags);
    const gatewayWarning: string = !gateway.ok
      ? (gatewayRisk.length > 0 ? 'Gateway 证书未取得，风险：' + gatewayRisk + '。'
        : 'Gateway 证书尚未取得。')
      : (gatewayRisk.length > 0 ? 'Gateway 风险：' + gatewayRisk + '。'
        : (gateway.rootTrusted
          ? (gateway.hostMismatch ? 'Gateway 证书名称不匹配。' : 'Gateway 证书链已受信。')
          : 'Gateway 证书链不受信。'));
    const targetWarning: string = !target.ok
      ? (targetRisk.length > 0 ? '目标 RDP 证书未取得，风险：' + targetRisk + '。'
        : '目标 RDP 证书尚未取得。')
      : (targetRisk.length > 0 ? '目标 RDP 风险：' + targetRisk + '。'
        : (target.rootTrusted
          ? (target.hostMismatch ? '目标 RDP 证书名称不匹配。' : '目标 RDP 证书链已受信。')
          : '目标 RDP 证书链不受信。'));
    return '连接将先经过 RD Gateway，再进入目标 RDP。' + gatewayWarning + targetWarning +
      (structuredRisk.length > 0 ? ' 风险：' + structuredRisk + '。' : '');
  }

  private isRdpCertificateBusy(): boolean {
    return this.rdpCertificateState === RdpCertificatePreflightState.PROBING;
  }

  private doRdpCertificateCancel(closeSheet: boolean = true): void {
    if (this.rdpCertificateClosing) {
      return;
    }
    const hostId: string = this.rdpCertificateHostId;
    this.rdpCertificateProbeGeneration = nextRdpCertificateProbeGeneration(
      this.rdpCertificateProbeGeneration
    );
    this.rdpCertificatePendingRouteParams = null;
    this.rdpGatewayPreflightOneTimeFingerprint = '';
    this.rdpGatewayPreflightOneTimeAllowUntrustedRoot = false;
    this.rdpGatewayPreflightOneTimeAllowHostMismatch = false;
    this.rdpGatewayPreflightOneTimeAllowTimeAnomaly = false;
    this.rdpGatewayPreflightOneTimeRouteIdentity = '';
    this.rdpCertificateClosingHostId = hostId;
    this.rdpCertificateClosingAttemptGeneration = this.rdpCertificateAttemptGeneration;
    this.rdpCertificateClosing = true;
    this.beginRemoteHostSheetClose(REMOTE_HOST_SHEET_RDP_CERTIFICATE);
    this.lastSheetDismissAtMs = Date.now();
    if (closeSheet) {
      this.showRdpCertificatePreflight = false;
      this.showRemoteHostSheet = false;
    }
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
    this.showRdpCertificatePreflight = false;
    this.rdpCertificateHostId = '';
    this.rdpCertificateHostLabel = '';
    this.rdpCertificateInfo = null;
    this.rdpGatewayCertificateInfo = null;
    this.rdpCertificateRouteResult = null;
    this.rdpCertificateWarning = '';
    this.rdpCertificateError = '';
    this.rdpCertificateErrorStage = '';
    this.rdpCertificateErrorCode = '';
    this.rdpCertificateShowDetails = false;
    this.rdpGatewayPreflightOneTimeFingerprint = '';
    this.rdpGatewayPreflightOneTimeAllowUntrustedRoot = false;
    this.rdpGatewayPreflightOneTimeAllowHostMismatch = false;
    this.rdpGatewayPreflightOneTimeAllowTimeAnomaly = false;
    this.rdpGatewayPreflightOneTimeRouteIdentity = '';
    this.rdpCertificateAttemptGeneration = 0;
    // 取消时已经释放过；generation 检查避免旧 Sheet 的 onDisappear 清掉同一主机的新请求。
    this.releaseConnectionAttemptIfCurrent(closingHostId, closingAttemptGeneration);

    if (params !== null) {
      if (nextHostId.length > 0) {
        this.releaseConnectionAttempt(nextHostId);
      }
      setTimeout((): void => {
        this.openSessionDestination('pages/RemoteDesktop', params, 'rdp_preflight_complete');
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

  private isCurrentRdpCertificateProbe(host: RemoteHost, generation: number,
    resultRouteIdentity: string = ''): boolean {
    if (!shouldApplyRdpCertificateProbeResult(
      this.rdpCertificateProbeGeneration,
      generation,
      this.rdpCertificateHostId,
      host.id
    )) {
      return false;
    }
    const liveHost: RemoteHost | undefined = this.srv.getHost(host.id);
    if (liveHost === undefined || rdpRouteIdentity(liveHost) !== rdpRouteIdentity(host)) {
      return false;
    }
    const resultRoute: string = resultRouteIdentity.trim();
    return resultRoute.length === 0 || rdpCertificateRouteIsCurrent(
      resultRoute, rdpRouteIdentity(host));
  }

  private rdpCertificateResultMatchesLiveRoute(host: RemoteHost,
    result: RdpPreflightResult): boolean {
    const expectedRoute: string = rdpRouteIdentity(host);
    const liveHost: RemoteHost | undefined = this.srv.getHost(host.id);
    return rdpCertificateRouteIsCurrent(result.routeIdentity, expectedRoute) &&
      liveHost !== undefined && rdpRouteIdentity(liveHost) === expectedRoute;
  }

  private rdpGatewayConfirmationPending(result: RdpPreflightResult | null =
    this.rdpCertificateRouteResult): boolean {
    return result !== null && result.ok && result.requiresUserDecision &&
      result.endpointMode === 'microsoft_rd_gateway' && result.stage === 'gateway' &&
      result.gatewayCertificate.present && !result.targetCertificate.present;
  }

  private classifyRdpGatewayCertificate(host: RemoteHost,
    result: RdpPreflightResult): RdpCertificatePreflightState {
    const gateway: RdpCertificateInfo = this.rdpCertificateInfoFromRecord(
      result.gatewayCertificate);
    return classifyRdpCertificateProbe({
      ok: gateway.ok,
      fingerprintSha256: gateway.fingerprintSha256,
      commonName: gateway.commonName,
      subject: gateway.subject,
      issuer: gateway.issuer,
      notBeforeMs: gateway.notBeforeMs,
      notAfterMs: gateway.notAfterMs,
      flags: gateway.flags,
      rootTrusted: gateway.rootTrusted,
      hostMismatch: gateway.hostMismatch,
      errorMessage: gateway.errorMessage,
      preflightStatus: gateway.preflightStatus,
      riskFlags: gateway.riskFlags
    }, {
      trustMode: host.rdpGatewayCertificateTrustMode,
      savedFingerprintSha256: host.rdpGatewayCertificateFingerprintSha256,
      routeBound: rdpCertificateRouteIsCurrent(
        host.rdpGatewayCertificateRouteIdentity, result.routeIdentity),
      savedAllowUntrustedRoot: host.rdpGatewayCertificateAllowUntrustedRoot,
      savedAllowHostMismatch: host.rdpGatewayCertificateAllowHostMismatch
    });
  }

  private handleStaleRdpCertificateProbe(host: RemoteHost, generation: number): void {
    if (!shouldApplyRdpCertificateProbeResult(
      this.rdpCertificateProbeGeneration,
      generation,
      this.rdpCertificateHostId,
      host.id
    )) {
      return;
    }
    if (this.srv.getHost(host.id) !== undefined) {
      this.rejectStaleRdpCertificateResult();
    }
  }

  private rejectStaleRdpCertificateResult(): void {
    this.rdpCertificateState = RdpCertificatePreflightState.ERROR;
    this.rdpCertificateErrorStage = 'endpoint';
    this.rdpCertificateErrorCode = 'E-RDP-CERT-ROUTE-STALE';
    this.rdpCertificateError = 'RDP 路由在证书检查期间发生变化，请重新进行证书检查 [E-RDP-CERT-ROUTE-STALE]';
    if (!this.showRdpCertificatePreflight) {
      this.openSheetSafely((): void => {
        this.openRemoteHostSheet(REMOTE_HOST_SHEET_RDP_CERTIFICATE, (): void => {
          this.showRdpCertificatePreflight = true;
        });
      }, true);
    }
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
        this.handleStaleRdpCertificateProbe(host, generation);
        hilog.info(0x0001, 'HostList',
          'RDP certificate probe skipped before native call [E-RDP-CERT-STALE-BEFORE]');
        return;
      }
      let info: RdpCertificateInfo;
      let routeResult: RdpPreflightResult;
      if (this.rdpCertificateUsesRouteProbe(host)) {
        routeResult = await this.loader.probeRdpCertificateRouteAsync(
          this.rdpCertificateRouteRequest(host, generation));
        info = routeResult.targetCertificate.present
          ? this.rdpCertificateInfoFromRecord(routeResult.targetCertificate)
          : {
            ok: false, host: host.host, port: host.port,
            serverName: host.customHostname || host.host, commonName: '', subject: '', issuer: '',
            fingerprintSha256: '', notBeforeMs: 0, notAfterMs: 0,
            flags: 0, rootTrusted: false, hostMismatch: false,
            errorCode: -1, errorMessage: routeResult.errorMessage,
            preflightStatus: routeResult.preflightStatus,
            riskFlags: routeResult.riskFlags || []
          };
        // Apply the gateway view only after the full result has passed the
        // generation and route-identity checks below.
      } else {
        info = await this.loader.probeRdpCertificateAsync(
          host.host,
          host.port,
          host.customHostname
        );
        routeResult = this.rdpCertificateResultFromDirectProbe(host, info, generation);
      }
      if (!this.isCurrentRdpCertificateProbe(host, generation, routeResult.routeIdentity)) {
        this.handleStaleRdpCertificateProbe(host, generation);
        hilog.info(0x0001, 'HostList',
          'RDP certificate probe result ignored [E-RDP-CERT-STALE-AFTER]');
        return;
      }
      this.rdpCertificateRouteResult = routeResult;
      this.rdpCertificateErrorStage = routeResult.stage;
      this.rdpCertificateErrorCode = routeResult.errorCode;
      this.rdpGatewayCertificateInfo = routeResult.gatewayCertificate.present
        ? this.rdpCertificateInfoFromRecord(routeResult.gatewayCertificate) : null;
      const elapsed: number = Date.now() - startedAt;
      hilog.info(0x0001, 'HostList',
        'RDP certificate probe done host=' + maskHost(host.host) + ':' + host.port.toString() +
          ' ok=' + (info.ok ? 'true' : 'false') + ' code=' + info.errorCode.toString() +
          ' elapsedMs=' + elapsed.toString());
      if (this.rdpGatewayConfirmationPending(routeResult)) {
        this.rdpCertificateInfo = null;
        this.rdpCertificateState = this.classifyRdpGatewayCertificate(host, routeResult);
        const gatewayRiskSummary: string = rdpCertificateRiskSummary(
          rdpCertificateEffectiveRiskFlags(
            routeResult.gatewayRiskFlags, routeResult.gatewayCertificate.riskFlags));
        this.rdpCertificateWarning = (gatewayRiskSummary || '已取得 Gateway 证书') +
          '。已在不发送账号密码的独立 TLS 连接中取得 Gateway 证书；' +
          '确认后才会使用凭据建立 Gateway 隧道并检查目标 RDP 证书。';
        if (!this.showRdpCertificatePreflight) {
          this.openSheetSafely((): void => {
            this.openRemoteHostSheet(REMOTE_HOST_SHEET_RDP_CERTIFICATE, (): void => {
              this.showRdpCertificatePreflight = true;
            });
          }, true);
        }
        return;
      }
      if (!routeResult.ok || !info.ok || info.fingerprintSha256.length === 0) {
        // `requiresUserDecision` is diagnostic metadata from native code, not
        // an admission control. Only a known transport/configuration failure
        // may prevent the user from handing the route to real FreeRDP.
        const advisory: boolean = rdpCertificateRoutePreflightAllowsRealConnection(
          routeResult.preflightStatus, routeResult.errorCode, routeResult.riskFlags || []);
        if (!advisory) {
          this.rdpCertificateInfo = info.ok ? info : null;
          this.rdpCertificateState = RdpCertificatePreflightState.ERROR;
          this.rdpCertificateErrorStage = routeResult.stage;
          this.rdpCertificateErrorCode = routeResult.errorCode;
          const riskSummary: string = rdpCertificateRiskSummary(routeResult.riskFlags || []);
          const errorMessage: string = routeResult.errorMessage || info.errorMessage ||
            'RDP 连接通道无法建立';
          this.rdpCertificateError = riskSummary.length > 0
            ? '风险：' + riskSummary + '。' + errorMessage
            : errorMessage;
          this.rdpCertificateWarning = rdpPreflightStatusLabel(routeResult.preflightStatus) +
            '：' + this.rdpCertificateError;
          if (!this.showRdpCertificatePreflight) {
            this.openSheetSafely((): void => {
              this.openRemoteHostSheet(REMOTE_HOST_SHEET_RDP_CERTIFICATE, (): void => {
                this.showRdpCertificatePreflight = true;
              });
            }, true);
          }
          return;
        }
        // A certificate probe is advisory. Standard RDP Security, an
        // intermediary reset, or a protocol-compatible probe that cannot
        // expose a certificate is a risk result, not a user decision made by
        // the program. The real FreeRDP callback remains authoritative.
        this.rdpCertificateInfo = info.ok ? info : null;
        this.rdpCertificateState = RdpCertificatePreflightState.TRUST_FIRST_TIME;
        this.rdpCertificateErrorStage = routeResult.stage;
        this.rdpCertificateErrorCode = routeResult.errorCode;
        const riskSummary: string = rdpCertificateRiskSummary(routeResult.riskFlags || []);
        const diagnosticMessage: string = riskSummary || routeResult.errorMessage ||
          info.errorMessage || '无法完整读取 RDP 主机证书';
        this.rdpCertificateWarning = rdpPreflightStatusLabel(routeResult.preflightStatus) +
          '：' + diagnosticMessage + ' 最终是否继续由你决定。';
        if (!this.showRdpCertificatePreflight) {
          this.openSheetSafely((): void => {
            this.openRemoteHostSheet(REMOTE_HOST_SHEET_RDP_CERTIFICATE, (): void => {
              this.showRdpCertificatePreflight = true;
            });
          }, true);
        }
        return;
      }
      this.rdpCertificateInfo = info;
      const gatewayInfo: RdpCertificateInfo | null = this.rdpGatewayCertificateInfo;
      const probeRouteIdentity: string = routeResult.routeIdentity;
      const probeView: RdpCertificateProbeView = {
        ok: info.ok,
        fingerprintSha256: info.fingerprintSha256,
        commonName: info.commonName,
        subject: info.subject,
        issuer: info.issuer,
        notBeforeMs: info.notBeforeMs,
        notAfterMs: info.notAfterMs,
        flags: info.flags,
        rootTrusted: info.rootTrusted,
        hostMismatch: info.hostMismatch,
        errorMessage: info.errorMessage,
        preflightStatus: routeResult.preflightStatus,
        riskFlags: rdpCertificateEffectiveRiskFlags(
          routeResult.targetRiskFlags, info.riskFlags),
        requiresUserDecision: routeResult.requiresUserDecision
      };
      this.rdpCertificateState = classifyRdpCertificateProbe(probeView, {
        trustMode: host.rdpCertificateTrustMode,
        savedFingerprintSha256: host.rdpCertificateFingerprintSha256,
        routeBound: rdpCertificateRouteIsCurrent(
          host.rdpCertificateRouteIdentity, probeRouteIdentity),
        savedAllowUntrustedRoot: host.rdpCertificateAllowUntrustedRoot,
        savedAllowHostMismatch: host.rdpCertificateAllowHostMismatch
      });
      const oneTimeGatewayTrust: boolean =
        this.rdpGatewayPreflightOneTimeFingerprint.length > 0 &&
        rdpCertificateRouteIsCurrent(
          this.rdpGatewayPreflightOneTimeRouteIdentity, probeRouteIdentity);
      const gatewayState: RdpCertificatePreflightState | null = gatewayInfo === null ? null :
        classifyRdpCertificateProbe({
          ok: gatewayInfo.ok,
          fingerprintSha256: gatewayInfo.fingerprintSha256,
          commonName: gatewayInfo.commonName,
          subject: gatewayInfo.subject,
          issuer: gatewayInfo.issuer,
          notBeforeMs: gatewayInfo.notBeforeMs,
          notAfterMs: gatewayInfo.notAfterMs,
          flags: gatewayInfo.flags,
          rootTrusted: gatewayInfo.rootTrusted,
          hostMismatch: gatewayInfo.hostMismatch,
          errorMessage: gatewayInfo.errorMessage,
          preflightStatus: gatewayInfo.preflightStatus,
          riskFlags: rdpCertificateEffectiveRiskFlags(
            routeResult.gatewayRiskFlags, gatewayInfo.riskFlags),
          requiresUserDecision: routeResult.requiresUserDecision
        }, {
          trustMode: oneTimeGatewayTrust ? RDP_CERTIFICATE_EXPLICIT_TRUST_MODE :
            host.rdpGatewayCertificateTrustMode,
          savedFingerprintSha256: oneTimeGatewayTrust ?
            this.rdpGatewayPreflightOneTimeFingerprint :
            host.rdpGatewayCertificateFingerprintSha256,
          routeBound: oneTimeGatewayTrust || rdpCertificateRouteIsCurrent(
            host.rdpGatewayCertificateRouteIdentity, probeRouteIdentity),
          savedAllowUntrustedRoot: oneTimeGatewayTrust ?
            this.rdpGatewayPreflightOneTimeAllowUntrustedRoot :
            host.rdpGatewayCertificateAllowUntrustedRoot,
          savedAllowHostMismatch: oneTimeGatewayTrust ?
            this.rdpGatewayPreflightOneTimeAllowHostMismatch :
            host.rdpGatewayCertificateAllowHostMismatch
        });
      this.rdpCertificateState = this.combineRdpCertificateStates(
        this.rdpCertificateState, gatewayState);
      this.rdpCertificateWarning = rdpCertificateWarningMessage(
        host.host,
        info.rootTrusted,
        info.hostMismatch,
        rdpCertificateEffectiveRiskFlags(routeResult.targetRiskFlags, info.riskFlags)
      );
      if (gatewayInfo !== null) {
        this.rdpCertificateWarning = this.rdpCertificateWarningForRoute(host, info, gatewayInfo);
      }
      if (this.rdpCertificateState === RdpCertificatePreflightState.TRUSTED_MATCH) {
        this.doRdpCertificateRoute(host, routeResult);
      } else {
        if (!this.showRdpCertificatePreflight) {
          this.openSheetSafely((): void => {
            this.openRemoteHostSheet(REMOTE_HOST_SHEET_RDP_CERTIFICATE, (): void => {
              this.showRdpCertificatePreflight = true;
            });
          }, true);
        }
      }
    } catch (e) {
      if (!this.isCurrentRdpCertificateProbe(host, generation)) {
        this.handleStaleRdpCertificateProbe(host, generation);
        hilog.info(0x0001, 'HostList',
          'RDP certificate probe exception ignored [E-RDP-CERT-STALE-ERROR]');
        return;
      }
      const elapsed: number = Date.now() - startedAt;
      const routeMode: string = this.rdpCertificateRouteMode(host);
      const gatewayRoute: boolean = routeMode === 'microsoft_rd_gateway';
      const exceptionMessage: string = e instanceof Error ? e.message : JSON.stringify(e);
      const exceptionRiskFlags: string[] = gatewayRoute
        ? ['GATEWAY_CERTIFICATE_RISK', 'TARGET_CERTIFICATE_RISK']
        : ['TARGET_CERTIFICATE_RISK'];
      const emptyRecord = (stage: string, endpointHost: string, endpointPort: number,
        serverName: string): RdpCertificateRecord => ({
        present: false, rootTrusted: false, hostMismatch: false, flags: 0,
        host: endpointHost, port: endpointPort, stage, serverName,
        commonName: '', subject: '', issuer: '', fingerprintSha256: '',
        notBeforeMs: 0, notAfterMs: 0,
        riskFlags: ['CERTIFICATE_METADATA_UNAVAILABLE']
      });
      const advisoryResult: RdpPreflightResult = {
        ok: false,
        preflightStatus: 'unavailable',
        riskFlags: exceptionRiskFlags,
        gatewayRiskFlags: gatewayRoute ? ['GATEWAY_CERTIFICATE_RISK'] : [],
        targetRiskFlags: ['TARGET_CERTIFICATE_RISK'],
        endpointMode: routeMode,
        routeIdentity: rdpRouteIdentity(host),
        generation,
        requestId: host.id + ':' + generation.toString(),
        stage: gatewayRoute ? 'gateway' : 'target',
        errorCode: 'E-RDP-PREFLIGHT-EXCEPTION',
        errorMessage: 'RDP 证书预检不可用：' + exceptionMessage,
        gatewayTransportRequested: host.rdpGatewayTransport || 'auto',
        gatewayTransportNegotiated: 'unknown',
        gatewayTransportSelected: host.rdpGatewayTransport || 'auto',
        requiresGatewayAuth: false,
        requiresUserDecision: true,
        gatewayCertificate: emptyRecord('gateway', host.gatewayHost,
          host.gatewayPort > 0 ? host.gatewayPort : 443,
          host.rdpGatewayServerName || host.gatewayHost),
        targetCertificate: emptyRecord('target', host.host, host.port,
          host.customHostname || host.host)
      };
      this.rdpCertificateRouteResult = advisoryResult;
      this.rdpCertificateInfo = null;
      this.rdpGatewayCertificateInfo = null;
      this.rdpCertificateState = RdpCertificatePreflightState.TRUST_FIRST_TIME;
      this.rdpCertificateErrorStage = advisoryResult.stage;
      this.rdpCertificateErrorCode = advisoryResult.errorCode;
      this.rdpCertificateError = advisoryResult.errorMessage;
      this.rdpCertificateWarning = rdpPreflightStatusLabel(advisoryResult.preflightStatus) +
        '：' + rdpCertificateRiskSummary(advisoryResult.riskFlags) +
        '。最终是否继续由你决定。';
      hilog.error(0x0001, 'HostList',
        'RDP certificate probe exception host=' + maskHost(host.host) + ':' + host.port.toString() +
          ' elapsedMs=' + elapsed.toString() + ' err=' + exceptionMessage);
      if (!this.showRdpCertificatePreflight) {
        this.openSheetSafely((): void => {
          this.openRemoteHostSheet(REMOTE_HOST_SHEET_RDP_CERTIFICATE, (): void => {
            this.showRdpCertificatePreflight = true;
          });
        }, true);
      }
    }
  }

  private applyRdpCertificateDecisionToHost(
    host: RemoteHost,
    result: RdpPreflightResult,
    decision: RdpCertificatePreflightDecision
  ): RemoteHost {
    const updated: RemoteHost = RemoteHost.fromJSON(host.toJSON());
    // Continue Once is scoped to this connection. Keep every persisted
    // target/Gateway trust record unchanged; the one-time pins travel through
    // doRdpCertificateRoute's transient result instead.
    if (!shouldPersistRdpCertificateTrust(decision)) {
      return updated;
    }
    const info: RdpCertificateInfo = this.rdpCertificateInfoFromRecord(result.targetCertificate);
    updated.rdpCertificateFingerprintSha256 = info.fingerprintSha256;
    updated.rdpCertificateSubject = info.subject;
    updated.rdpCertificateIssuer = info.issuer;
    updated.rdpCertificateCommonName = info.commonName;
    updated.rdpCertificateNotBeforeMs = info.notBeforeMs;
    updated.rdpCertificateNotAfterMs = info.notAfterMs;
    updated.rdpCertificateRouteIdentity = result.routeIdentity;
    updated.rdpCertificateTrustedAt = Date.now();
    updated.rdpCertificateTrustMode = RDP_CERTIFICATE_EXPLICIT_TRUST_MODE;
    updated.rdpCertificateAllowUntrustedRoot = !info.rootTrusted;
    updated.rdpCertificateAllowHostMismatch = info.hostMismatch;
    if (result.gatewayCertificate.present) {
      const gateway: RdpCertificateInfo = this.rdpCertificateInfoFromRecord(result.gatewayCertificate);
      updated.rdpGatewayCertificateFingerprintSha256 = gateway.fingerprintSha256;
      updated.rdpGatewayCertificateSubject = gateway.subject;
      updated.rdpGatewayCertificateIssuer = gateway.issuer;
      updated.rdpGatewayCertificateCommonName = gateway.commonName;
      updated.rdpGatewayCertificateNotBeforeMs = gateway.notBeforeMs;
      updated.rdpGatewayCertificateNotAfterMs = gateway.notAfterMs;
      updated.rdpGatewayCertificateRouteIdentity = result.routeIdentity;
      updated.rdpGatewayCertificateTrustedAt = Date.now();
      updated.rdpGatewayCertificateTrustMode = RDP_CERTIFICATE_EXPLICIT_TRUST_MODE;
      updated.rdpGatewayCertificateAllowUntrustedRoot = !gateway.rootTrusted;
      updated.rdpGatewayCertificateAllowHostMismatch = gateway.hostMismatch;
    }
    return updated;
  }

  private continueAfterRdpGatewayCertificateDecision(
    host: RemoteHost,
    result: RdpPreflightResult,
    decision: RdpCertificatePreflightDecision
  ): void {
    if (!this.rdpGatewayConfirmationPending(result) ||
      !this.rdpCertificateResultMatchesLiveRoute(host, result)) {
      this.rejectStaleRdpCertificateResult();
      return;
    }
    const gateway: RdpCertificateInfo = this.rdpCertificateInfoFromRecord(
      result.gatewayCertificate);
    const gatewayRiskFlags: string[] = rdpCertificateEffectiveRiskFlags(
      result.gatewayRiskFlags, gateway.riskFlags);
    const gatewayTimeAnomaly: boolean = gatewayRiskFlags.indexOf(
      'CERTIFICATE_TIME_INVALID') >= 0;
    const gatewayMetadataUnavailable: boolean = gatewayRiskFlags.indexOf(
      'CERTIFICATE_METADATA_UNAVAILABLE') >= 0;
    const gatewayNeedsOneTimeDiagnosticAllowance: boolean =
      gatewayTimeAnomaly || gatewayMetadataUnavailable;
    if (shouldPersistRdpCertificateTrust(decision) && gateway.fingerprintSha256.trim() === '') {
      this.rdpCertificateWarning =
        '预检未取得可保存的 Gateway 证书；请选择“确认并检查目标”一次，或返回修改配置。';
      return;
    }

    let probeHost: RemoteHost = host;
    if (shouldPersistRdpCertificateTrust(decision)) {
      const updated: RemoteHost = RemoteHost.fromJSON(host.toJSON());
      updated.rdpGatewayCertificateFingerprintSha256 = gateway.fingerprintSha256;
      updated.rdpGatewayCertificateSubject = gateway.subject;
      updated.rdpGatewayCertificateIssuer = gateway.issuer;
      updated.rdpGatewayCertificateCommonName = gateway.commonName;
      updated.rdpGatewayCertificateNotBeforeMs = gateway.notBeforeMs;
      updated.rdpGatewayCertificateNotAfterMs = gateway.notAfterMs;
      updated.rdpGatewayCertificateRouteIdentity = result.routeIdentity;
      updated.rdpGatewayCertificateTrustedAt = Date.now();
      updated.rdpGatewayCertificateTrustMode = RDP_CERTIFICATE_EXPLICIT_TRUST_MODE;
      updated.rdpGatewayCertificateAllowUntrustedRoot = !gateway.rootTrusted;
      updated.rdpGatewayCertificateAllowHostMismatch = gateway.hostMismatch;
      if (!this.srv.updateHost(updated)) {
        // Persistence is not a transport failure. Keep the observed risk and
        // let the user explicitly fall back to a one-time connection.
        this.rdpCertificateState = RdpCertificatePreflightState.TRUST_FIRST_TIME;
        this.rdpCertificateErrorStage = '';
        this.rdpCertificateErrorCode = '';
        this.rdpCertificateError = '';
        this.rdpCertificateWarning =
          '无法保存 Gateway 证书信任；风险仍保留。可选择继续连接一次，或返回修改配置。';
        return;
      }
      probeHost = updated;
      // Persist the observed pin, but keep the time/metadata exception scoped
      // to this probe and real connection. A later connection shows the risk
      // again instead of silently accepting it.
      this.rdpGatewayPreflightOneTimeFingerprint = gatewayNeedsOneTimeDiagnosticAllowance ?
        gateway.fingerprintSha256 : '';
      this.rdpGatewayPreflightOneTimeAllowUntrustedRoot =
        gatewayNeedsOneTimeDiagnosticAllowance && !gateway.rootTrusted;
      this.rdpGatewayPreflightOneTimeAllowHostMismatch =
        gatewayNeedsOneTimeDiagnosticAllowance && gateway.hostMismatch;
      this.rdpGatewayPreflightOneTimeAllowTimeAnomaly = gatewayNeedsOneTimeDiagnosticAllowance;
      this.rdpGatewayPreflightOneTimeRouteIdentity = gatewayNeedsOneTimeDiagnosticAllowance ?
        result.routeIdentity : '';
    } else {
      this.rdpGatewayPreflightOneTimeFingerprint = gateway.fingerprintSha256;
      this.rdpGatewayPreflightOneTimeAllowUntrustedRoot = !gateway.rootTrusted;
      this.rdpGatewayPreflightOneTimeAllowHostMismatch = gateway.hostMismatch;
      this.rdpGatewayPreflightOneTimeAllowTimeAnomaly =
        gatewayRiskFlags.indexOf('CERTIFICATE_TIME_INVALID') >= 0 ||
        gatewayRiskFlags.indexOf('CERTIFICATE_METADATA_UNAVAILABLE') >= 0;
      this.rdpGatewayPreflightOneTimeRouteIdentity = result.routeIdentity;
    }

    const generation: number = nextRdpCertificateProbeGeneration(
      this.rdpCertificateProbeGeneration);
    this.rdpCertificateProbeGeneration = generation;
    this.rdpCertificateState = RdpCertificatePreflightState.PROBING;
    this.rdpCertificateInfo = null;
    this.rdpCertificateRouteResult = null;
    this.rdpCertificateError = '';
    this.rdpCertificateErrorStage = '';
    this.rdpCertificateErrorCode = '';
    this.doRdpCertificateProbe(probeHost, generation);
  }

  private doRdpCertificateContinueOnce(host: RemoteHost): void {
    if (!this.rdpCertificateRouteResult) { return; }
    const result: RdpPreflightResult = this.rdpCertificateRouteResult;
    if (this.rdpGatewayConfirmationPending(result)) {
      this.continueAfterRdpGatewayCertificateDecision(
        host, result, RdpCertificatePreflightDecision.CONTINUE_ONCE);
      return;
    }
    if (!this.rdpCertificateResultMatchesLiveRoute(host, result)) {
      this.rejectStaleRdpCertificateResult();
      return;
    }
    if (!this.rdpCertificateInfo) {
      // Continue without a one-time pin.  The real FreeRDP certificate
      // callback remains authoritative and can present a fresh risk to the
      // user when the advisory probe could not observe a certificate.
      this.doRdpCertificateRoute(host, result, true);
      return;
    }
    const routed: RemoteHost = this.applyRdpCertificateDecisionToHost(
      host,
      result,
      RdpCertificatePreflightDecision.CONTINUE_ONCE
    );
    this.doRdpCertificateRoute(routed, result, true);
  }

  private doRdpCertificateTrust(host: RemoteHost): void {
    if (!this.rdpCertificateRouteResult) { return; }
    const result: RdpPreflightResult = this.rdpCertificateRouteResult;
    if (this.rdpGatewayConfirmationPending(result)) {
      this.continueAfterRdpGatewayCertificateDecision(
        host, result, RdpCertificatePreflightDecision.TRUST);
      return;
    }
    if (!this.rdpCertificateInfo || this.rdpCertificateInfo.fingerprintSha256.trim() === '') {
      this.rdpCertificateWarning = '预检未取得可保存的证书，不能保存未知证书；请选择“继续连接”一次。';
      return;
    }
    if (!this.rdpCertificateResultMatchesLiveRoute(host, result)) {
      this.rejectStaleRdpCertificateResult();
      return;
    }
    const updated: RemoteHost = this.applyRdpCertificateDecisionToHost(
      host,
      result,
      RdpCertificatePreflightDecision.TRUST
    );
    if (!this.srv.updateHost(updated)) {
      // Saving a pin can fail independently of connection viability. Leave
      // the user at the decision point rather than converting it into a
      // preflight veto.
      this.rdpCertificateState = RdpCertificatePreflightState.TRUST_FIRST_TIME;
      this.rdpCertificateErrorStage = '';
      this.rdpCertificateErrorCode = '';
      this.rdpCertificateError = '';
      this.rdpCertificateWarning =
        '无法保存 RDP 证书信任；风险仍保留。可选择继续连接一次，或返回修改配置。';
      return;
    }
    this.doRdpCertificateRoute(updated);
  }

  private doRdpCertificateRoute(host: RemoteHost, oneTimeResult?: RdpPreflightResult,
    userApprovedAdvisory: boolean = false): void {
    if (this.rdpCertificateClosing) {
      return;
    }
    const diagnosticResult: RdpPreflightResult | null = oneTimeResult ||
      this.rdpCertificateRouteResult;
    if (diagnosticResult && !this.rdpCertificateResultMatchesLiveRoute(host, diagnosticResult)) {
      this.rejectStaleRdpCertificateResult();
      return;
    }
    const params: Record<string, Object> = {};
    params['hostId'] = host.id;
    if (diagnosticResult) {
      const target = diagnosticResult.targetCertificate;
      const gateway = diagnosticResult.gatewayCertificate;
      const targetRiskFlags: string[] = rdpCertificateEffectiveRiskFlags(
        diagnosticResult.targetRiskFlags, target.riskFlags);
      const gatewayRiskFlags: string[] = rdpCertificateEffectiveRiskFlags(
        diagnosticResult.gatewayRiskFlags, gateway.riskFlags);
      const preflightAllowsRealConnection: boolean =
        rdpCertificateRoutePreflightAllowsRealConnection(
          diagnosticResult.preflightStatus, diagnosticResult.errorCode,
          diagnosticResult.riskFlags || []);
      params['rdpCertificateOneTimeRouteIdentity'] = diagnosticResult.routeIdentity;
      params['rdpCertificatePreflightStatus'] = diagnosticResult.preflightStatus;
      params['rdpCertificatePreflightRiskFlags'] = diagnosticResult.riskFlags;
      params['rdpGatewayCertificatePreflightRiskFlags'] = diagnosticResult.gatewayRiskFlags;
      const standardSecurityRisk: boolean =
        targetRiskFlags.indexOf(
          'STANDARD_RDP_SECURITY') >= 0;
      // A diagnostic risk must not enable Standard RDP Security by itself.
      // Only the explicit Continue Once action can set this transient flag.
      params['rdpAllowStandardSecurityOnce'] = shouldEnableStandardRdpSecurityOnce(
        userApprovedAdvisory, targetRiskFlags.length > 0
          ? targetRiskFlags : diagnosticResult.riskFlags);
      if (target.present && target.fingerprintSha256.length > 0) {
        params['rdpCertificateOneTimeFingerprintSha256'] = target.fingerprintSha256;
        params['rdpCertificateOneTimeAllowUntrustedRoot'] = !target.rootTrusted;
        params['rdpCertificateOneTimeAllowHostMismatch'] = target.hostMismatch;
        params['rdpCertificateAllowTimeAnomalyOnce'] =
          targetRiskFlags.indexOf('CERTIFICATE_TIME_INVALID') >= 0 ||
          targetRiskFlags.indexOf('CERTIFICATE_METADATA_UNAVAILABLE') >= 0;
        params['rdpCertificateAllowUnpinnedOnce'] = userApprovedAdvisory &&
          targetRiskFlags.indexOf(
            'CERTIFICATE_METADATA_UNAVAILABLE') >= 0;
      } else if (userApprovedAdvisory && preflightAllowsRealConnection &&
        !standardSecurityRisk) {
        params['rdpCertificateAllowUnpinnedOnce'] = true;
      }
      if (gateway.present && gateway.fingerprintSha256.length > 0) {
        params['rdpGatewayCertificateOneTimeFingerprintSha256'] = gateway.fingerprintSha256;
        params['rdpGatewayCertificateOneTimeAllowUntrustedRoot'] = !gateway.rootTrusted;
        params['rdpGatewayCertificateOneTimeAllowHostMismatch'] = gateway.hostMismatch;
        params['rdpGatewayCertificateAllowTimeAnomalyOnce'] =
          gatewayRiskFlags.indexOf('CERTIFICATE_TIME_INVALID') >= 0 ||
          gatewayRiskFlags.indexOf('CERTIFICATE_METADATA_UNAVAILABLE') >= 0;
        params['rdpGatewayCertificateAllowUnpinnedOnce'] = userApprovedAdvisory &&
          gatewayRiskFlags.indexOf(
            'CERTIFICATE_METADATA_UNAVAILABLE') >= 0;
      } else if (userApprovedAdvisory && preflightAllowsRealConnection &&
        diagnosticResult.endpointMode === 'microsoft_rd_gateway') {
        params['rdpGatewayCertificateAllowUnpinnedOnce'] = true;
      }
    }
    if (shouldRouteRdpCertificateAfterSheetDisappear(this.showRdpCertificatePreflight)) {
      this.rdpCertificatePendingRouteParams = params;
      this.rdpCertificateClosingHostId = host.id;
      this.rdpCertificateClosingAttemptGeneration = this.rdpCertificateAttemptGeneration;
      this.rdpCertificateClosing = true;
      this.beginRemoteHostSheetClose(REMOTE_HOST_SHEET_RDP_CERTIFICATE);
      this.lastSheetDismissAtMs = Date.now();
      this.showRdpCertificatePreflight = false;
      this.showRemoteHostSheet = false;
      return;
    }
    this.rdpCertificateHostId = '';
    this.releaseConnectionAttempt(host.id);
    setTimeout((): void => {
      this.openSessionDestination('pages/RemoteDesktop', params, 'rdp_preflight_complete');
    }, rdpCertificateRouteDelayMsAfterSheetClose());
  }

  private vncCertificateStoreFingerprint(): string {
    return vncStoreIdentityFingerprint(AccountSessionCoordinator.getInstance().currentScope().storeIdentity);
  }

  private resolveVncCertificateEndpoint(host: VncHostView): VncTlsEndpointResolution {
    const scope = AccountSessionCoordinator.getInstance().currentScope();
    const store: string = this.vncCertificateStoreFingerprint();
    const hostInput = vncTlsHostInput(host.id, host.userId, host, host.host, store);
    let gatewayInput: VncTlsGatewayInput | null = null;
    if (host.gatewayId.trim() !== '') {
      const gateway: VncGatewayView | null = this.vncGateways.find(host.gatewayId);
      if (gateway !== null) {
        gatewayInput = vncTlsGatewayInput(gateway.id, gateway.userId, gateway, store);
      }
    }
    // Account scope and physical store are part of the resolver input. A
    // stale account therefore produces an endpoint error instead of a route.
    if (scope.ownerScopeId.trim() === '' || scope.generation <= 0 ||
      host.userId.trim() !== scope.ownerScopeId.trim()) {
      return resolveVncTlsEndpoint(hostInput, gatewayInput);
    }
    return resolveVncTlsEndpoint(hostInput, gatewayInput);
  }

  private vncCertificateTrustEndpoint(endpoint: VncTlsEndpointResolution): VncTrustEndpoint | null {
    if (!endpoint.ok || endpoint.trustOwner === null) { return null; }
    return {
      ownerType: endpoint.trustOwner.ownerType,
      ownerId: endpoint.trustOwner.ownerId,
      userId: endpoint.trustOwner.userId,
      storeIdentityFingerprint: endpoint.trustOwner.storeIdentityFingerprint,
      endpointBindingFingerprint: endpoint.trustOwner.endpointBindingFingerprint
    };
  }

  private vncCertificateIdentity(host: VncHostView,
    endpoint: VncTlsEndpointResolution): VncCertificateProbeIdentity {
    const scope = AccountSessionCoordinator.getInstance().currentScope();
    return {
      userId: host.userId.trim(),
      accountOwnerScopeId: scope.ownerScopeId.trim(),
      hostId: host.id.trim(),
      gatewayId: host.gatewayId.trim(),
      endpointBindingFingerprint: endpoint.endpointBindingFingerprint,
      storeIdentityFingerprint: endpoint.trustOwner === null ? '' :
        endpoint.trustOwner.storeIdentityFingerprint,
      storeGeneration: scope.generation
    };
  }

  private vncCertificateProbeView(info: VncCertificateInfo): VncCertificateProbeView {
    return {
      ok: info.ok,
      fingerprintSha256: info.fingerprintSha256,
      commonName: info.commonName,
      subject: info.subject,
      issuer: info.issuer,
      notBeforeMs: info.notBeforeMs,
      notAfterMs: info.notAfterMs,
      rootTrusted: info.rootTrusted,
      hostMismatch: info.hostMismatch,
      errorCode: info.errorMessageCategory,
      errorMessage: info.errorMessage
    };
  }

  private vncCertificateTrustView(trust: VncTrustView | null): VncCertificateTrustView | null {
    if (trust === null) { return null; }
    return {
      ownerType: trust.ownerType,
      ownerId: trust.ownerId,
      userId: trust.userId,
      storeIdentityFingerprint: trust.storeIdentityFingerprint,
      endpointBindingFingerprint: trust.endpointBindingFingerprint,
      fingerprintSha256: trust.fingerprintSha256,
      confirmed: trust.confirmed,
      confirmedAt: trust.confirmedAt,
      cloudCandidate: trust.cloudCandidate
    };
  }

  private vncCertificateWarningText(info: VncCertificateInfo): string {
    const warnings: string[] = [];
    if (!info.rootTrusted) { warnings.push('系统信任根未验证'); }
    if (info.hostMismatch) { warnings.push('证书名称与连接地址不匹配'); }
    if (info.notAfterMs > 0 && Date.now() > info.notAfterMs) { warnings.push('证书已过期'); }
    if (info.notBeforeMs > 0 && Date.now() < info.notBeforeMs) { warnings.push('证书尚未生效'); }
    return warnings.join('；');
  }

  private vncCertificateCurrentIdentity(identity: VncCertificateProbeIdentity,
    attemptGeneration: number): boolean {
    if (!this.pageActive || this.vncCertificateAttemptGeneration !== attemptGeneration ||
      this.vncCertificateProbeIdentity === null) { return false; }
    const scope = AccountSessionCoordinator.getInstance().currentScope();
    if (scope.ownerScopeId.trim() === '' || scope.generation <= 0 ||
      scope.ownerScopeId.trim() !== identity.accountOwnerScopeId.trim() ||
      scope.ownerScopeId.trim() !== identity.userId.trim() ||
      scope.generation !== identity.storeGeneration ||
      this.vncCertificateStoreFingerprint() !== identity.storeIdentityFingerprint) {
      return false;
    }
    const host: VncHostView | null = this.vncHosts.find(this.vncCertificateHostId);
    if (host === null) { return false; }
    const endpoint: VncTlsEndpointResolution = this.resolveVncCertificateEndpoint(host);
    return endpoint.ok && endpoint.endpointBindingFingerprint === identity.endpointBindingFingerprint;
  }

  private openVncCertificatePreflight(host: VncHostView,
    routeHostId: string, attemptGeneration: number): void {
    if (this.vncCertificateClosing || this.showVncCertificatePreflight ||
      this.remoteHostSheetClosing || this.showRemoteHostSheet) {
      this.vncCertificatePendingHostId = routeHostId;
      return;
    }
    this.vncCertificateProbeGeneration = nextVncCertificateProbeGeneration(
      this.vncCertificateProbeGeneration);
    this.vncCertificateAttemptGeneration = attemptGeneration;
    // Connection arbitration is owned by the projected HostList record. Keep
    // that exact ID so cancelling this VNC preflight releases the right lock.
    this.vncCertificateClosingHostId = routeHostId;
    this.vncCertificateHostId = host.id;
    this.vncCertificateHostLabel = host.label;
    this.vncCertificateWarning = '';
    this.vncCertificateInfo = null;
    this.vncCertificateError = '';
    this.vncCertificateShowDetails = false;
    this.vncCertificatePendingRouteParams = null;
    this.vncCertificateEndpoint = this.resolveVncCertificateEndpoint(host);
    this.vncCertificateTrustOwner = this.vncCertificateTrustEndpoint(this.vncCertificateEndpoint);
    this.vncCertificateProbeIdentity = this.vncCertificateIdentity(host, this.vncCertificateEndpoint);
    const scope = AccountSessionCoordinator.getInstance().currentScope();
    this.vncCertificateAccountOwnerScopeId = scope.ownerScopeId.trim();
    this.vncCertificateAccountStoreIdentityFingerprint =
      this.vncCertificateTrustOwner === null ? '' : this.vncCertificateTrustOwner.storeIdentityFingerprint;
    this.vncCertificateAccountGeneration = scope.generation;
    if (!this.vncCertificateEndpoint.ok) {
      this.vncCertificateState = VncCertificatePreflightState.ERROR;
      this.vncCertificateError = this.vncCertificateEndpoint.errorCode || 'E-VNC-ENDPOINT-INVALID';
      this.openSheetSafely((): void => {
        this.openRemoteHostSheet(REMOTE_HOST_SHEET_VNC_CERTIFICATE, (): void => {
          this.showVncCertificatePreflight = true;
        });
      }, true);
      return;
    }
    if (!this.vncCertificateEndpoint.tlsRequired) {
      // Plaintext VNC still requires an explicit, endpoint-bound confirmation.
      // Do not model it as certificate trust: no pin or trust record is created.
      this.vncCertificateState = VncCertificatePreflightState.PLAINTEXT_WARNING;
      this.vncCertificateWarning = '当前 endpoint 未启用 TLS，仅在确认网络可信时继续。';
      this.openSheetSafely((): void => {
        this.openRemoteHostSheet(REMOTE_HOST_SHEET_VNC_CERTIFICATE, (): void => {
          this.showVncCertificatePreflight = true;
        });
      }, true);
      return;
    }
    this.vncCertificateState = VncCertificatePreflightState.PROBING;
    this.openSheetSafely((): void => {
      this.openRemoteHostSheet(REMOTE_HOST_SHEET_VNC_CERTIFICATE, (): void => {
        this.showVncCertificatePreflight = true;
      });
    }, true);
    const generation: number = this.vncCertificateProbeGeneration;
    const identity: VncCertificateProbeIdentity = this.vncCertificateProbeIdentity;
    setTimeout((): void => {
      if (this.vncCertificateProbeGeneration !== generation ||
        !this.vncCertificateCurrentIdentity(identity, attemptGeneration)) { return; }
      void this.doVncCertificateProbe(host, generation, attemptGeneration, identity);
    }, 160);
  }

  private async doVncCertificateProbe(host: VncHostView, generation: number,
    attemptGeneration: number, identity: VncCertificateProbeIdentity): Promise<void> {
    const endpoint: VncTlsEndpointResolution | null = this.vncCertificateEndpoint;
    if (endpoint === null || !endpoint.ok) { return; }
    try {
      const probe = this.loader.probeVncCertificateAsync(
        endpoint.connectHost, endpoint.connectPort, endpoint.serverName, 10000);
      this.vncCertificateProbeRequestId = probe.requestId;
      const info: VncCertificateInfo = await probe;
      if (this.vncCertificateProbeGeneration !== generation ||
        !shouldApplyVncCertificateProbeResult(
          this.vncCertificateProbeGeneration, generation,
          this.vncCertificateAttemptGeneration, attemptGeneration,
          this.vncCertificateProbeIdentity === null ? identity : this.vncCertificateProbeIdentity,
          identity) || !this.vncCertificateCurrentIdentity(identity, attemptGeneration)) {
        return;
      }
      this.vncCertificateProbeRequestId = 0;
      this.vncCertificateInfo = info;
      this.vncCertificateWarning = this.vncCertificateWarningText(info);
      const trustOwner: VncTrustEndpoint | null = this.vncCertificateTrustOwner;
      const trustRecord: VncTrustView | null = trustOwner === null ? null :
        this.vncTrust.trustForEndpoint(trustOwner);
      const trust: VncCertificateTrustView | null = this.vncCertificateTrustView(trustRecord);
      this.vncCertificateState = classifyVncCertificateProbeForOwner(
        this.vncCertificateProbeView(info), trust,
        trustOwner === null ? 'host' : trustOwner.ownerType,
        trustOwner === null ? '' : trustOwner.ownerId,
        trustOwner === null ? '' : trustOwner.userId,
        trustOwner === null ? '' : trustOwner.storeIdentityFingerprint,
        trustOwner === null ? '' : trustOwner.endpointBindingFingerprint);
      if (this.vncCertificateState === VncCertificatePreflightState.TRUSTED_MATCH) {
        this.routeVncCertificatePreflight(true);
      } else if (this.vncCertificateState === VncCertificatePreflightState.ERROR) {
        this.vncCertificateError = info.errorMessageCategory || 'E-VNC-CERT-PROBE';
      }
    } catch (err) {
      if (this.vncCertificateProbeGeneration !== generation ||
        !this.vncCertificateCurrentIdentity(identity, attemptGeneration)) { return; }
      this.vncCertificateProbeRequestId = 0;
      this.vncCertificateState = VncCertificatePreflightState.ERROR;
      this.vncCertificateInfo = null;
      this.vncCertificateError = 'E-VNC-CERT-PROBE';
      hilog.warn(0x0001, 'HostList', 'VNC certificate probe failed: ' +
        (err instanceof Error ? err.message : JSON.stringify(err)));
    }
  }

  private cancelVncCertificatePreflight(closeSheet: boolean = true): void {
    // A decision already started the programmatic Sheet close. ArkUI invokes
    // onWillDismiss for that transition too; do not reinterpret it as a user
    // cancel or clear the pending RemoteDesktop route before onDisappear.
    if (this.vncCertificateClosing) {
      return;
    }
    const hostId: string = this.vncCertificateClosingHostId.length > 0
      ? this.vncCertificateClosingHostId : this.vncCertificateHostId;
    const vncHost: VncHostView | null = this.vncHosts.find(this.vncCertificateHostId);
    if (vncHost !== null) {
      VncSessionCredentialHandoff.getInstance().clear(vncHost.userId, vncHost.id);
      this.vncCertificateHandoff.clear(vncHost.userId, 'vnc-cert:' + vncHost.id);
      this.vncPlaintextHandoff.clear(vncHost.userId, 'vnc-cert:' + vncHost.id);
    }
    this.vncCertificateProbeGeneration = nextVncCertificateProbeGeneration(
      this.vncCertificateProbeGeneration);
    if (this.vncCertificateProbeRequestId > 0) {
      this.loader.cancelVncCertificateProbe(this.vncCertificateProbeRequestId);
      this.vncCertificateProbeRequestId = 0;
    }
    this.vncCertificatePendingRouteParams = null;
    this.vncCertificateClosingHostId = hostId;
    this.vncCertificateClosingAttemptGeneration = this.vncCertificateAttemptGeneration;
    this.vncCertificateClosing = true;
    this.beginRemoteHostSheetClose(REMOTE_HOST_SHEET_VNC_CERTIFICATE);
    if (closeSheet) {
      this.showVncCertificatePreflight = false;
      this.showRemoteHostSheet = false;
    }
    this.releaseConnectionAttempt(hostId);
  }

  private retryVncCertificatePreflight(): void {
    const host: VncHostView | null = this.vncHosts.find(this.vncCertificateHostId);
    if (host === null) { return; }
    this.vncCertificateProbeGeneration = nextVncCertificateProbeGeneration(
      this.vncCertificateProbeGeneration);
    this.vncCertificateState = VncCertificatePreflightState.PROBING;
    this.vncCertificateError = '';
    const identity: VncCertificateProbeIdentity = this.vncCertificateIdentity(
      host, this.resolveVncCertificateEndpoint(host));
    this.vncCertificateProbeIdentity = identity;
    const generation: number = this.vncCertificateProbeGeneration;
    void this.doVncCertificateProbe(host, generation, this.vncCertificateAttemptGeneration, identity);
  }

  private stageVncCertificateHandoff(fingerprint: string): boolean {
    const host: VncHostView | null = this.vncHosts.find(this.vncCertificateHostId);
    const endpoint: VncTlsEndpointResolution | null = this.vncCertificateEndpoint;
    const scope = AccountSessionCoordinator.getInstance().currentScope();
    if (host === null || endpoint === null || !endpoint.ok || endpoint.trustOwner === null ||
      !isVncSha256Fingerprint(fingerprint) || scope.ownerScopeId.trim() === '' || scope.generation <= 0) {
      return false;
    }
    return this.vncCertificateHandoff.put(
      host.userId, 'vnc-cert:' + host.id, this.vncCertificateProbeGeneration,
      endpoint.endpointBindingFingerprint, fingerprint,
      scope.ownerScopeId, this.vncCertificateStoreFingerprint(), scope.generation);
  }

  private acceptVncCertificateDecision(decision: VncCertificatePreflightDecision): void {
    if (this.vncCertificateInfo === null || this.vncCertificateTrustOwner === null ||
      this.vncCertificateState === VncCertificatePreflightState.PROBING ||
      this.vncCertificateState === VncCertificatePreflightState.ERROR ||
      !isVncSha256Fingerprint(this.vncCertificateInfo.fingerprintSha256)) { return; }
    const host: VncHostView | null = this.vncHosts.find(this.vncCertificateHostId);
    if (host === null || this.vncCertificateProbeIdentity === null ||
      !this.vncCertificateCurrentIdentity(this.vncCertificateProbeIdentity,
        this.vncCertificateAttemptGeneration)) { return; }
    const fingerprint: string = this.vncCertificateInfo.fingerprintSha256.trim().toLowerCase();
    if (decision === VncCertificatePreflightDecision.TRUST ||
      decision === VncCertificatePreflightDecision.UPDATE_TRUST) {
      const metadata: VncTrustCertificateMetadata = {
        endpointLabel: host.label,
        commonName: this.vncCertificateInfo.commonName,
        subject: this.vncCertificateInfo.subject,
        issuer: this.vncCertificateInfo.issuer,
        notBeforeMs: this.vncCertificateInfo.notBeforeMs,
        notAfterMs: this.vncCertificateInfo.notAfterMs,
        rootTrusted: this.vncCertificateInfo.rootTrusted,
        hostMismatch: this.vncCertificateInfo.hostMismatch
      };
      const saved = this.vncTrust.saveForEndpoint(this.vncCertificateTrustOwner, fingerprint, metadata);
      if (!saved.ok) {
        this.vncCertificateState = VncCertificatePreflightState.ERROR;
        this.vncCertificateError = saved.message || 'E-VNC-CERT-TRUST-SAVE';
        return;
      }
    }
    if (!this.stageVncCertificateHandoff(fingerprint)) {
      this.vncCertificateState = VncCertificatePreflightState.ERROR;
      this.vncCertificateError = 'E-VNC-CERT-HANDOFF';
      return;
    }
    this.routeVncCertificatePreflight(true);
  }

  private continueVncPlaintextPreflight(): void {
    if (this.vncCertificateState !== VncCertificatePreflightState.PLAINTEXT_WARNING ||
      this.vncCertificateEndpoint === null || !this.vncCertificateEndpoint.ok ||
      this.vncCertificateEndpoint.tlsRequired || this.vncCertificateProbeIdentity === null ||
      !this.vncCertificateCurrentIdentity(this.vncCertificateProbeIdentity,
        this.vncCertificateAttemptGeneration)) {
      return;
    }
    this.routeVncCertificatePreflight(false, true);
  }

  private routeVncCertificatePreflight(tlsHandoff: boolean,
    plaintextConfirmed: boolean = false): void {
    const hostId: string = this.vncCertificateClosingHostId.length > 0
      ? this.vncCertificateClosingHostId : this.vncCertificateHostId;
    const vncHostId: string = this.vncCertificateHostId;
    if (vncHostId === '') { this.releaseConnectionAttempt(hostId); return; }
    const params: Record<string, Object> = {};
    params['vncHostId'] = vncHostId;
    const host: VncHostView | null = this.vncHosts.find(vncHostId);
    const endpoint: VncTlsEndpointResolution | null = this.vncCertificateEndpoint;
    const scope = AccountSessionCoordinator.getInstance().currentScope();
    const storeFingerprint: string = this.vncCertificateStoreFingerprint();
    if (host === null || endpoint === null || !endpoint.ok ||
      !isVncSha256Fingerprint(endpoint.endpointBindingFingerprint) ||
      !isVncSha256Fingerprint(storeFingerprint) ||
      scope.ownerScopeId.trim() !== host.userId.trim() || scope.generation <= 0) {
      this.vncCertificateState = VncCertificatePreflightState.ERROR;
      this.vncCertificateError = 'E-VNC-CERT-HANDOFF';
      return;
    }
    this.vncCredentialCertificateEndpointBinding = endpoint.endpointBindingFingerprint;
    this.vncCredentialCertificateOwnerScopeId = scope.ownerScopeId.trim();
    this.vncCredentialCertificateStoreFingerprint = storeFingerprint;
    this.vncCredentialCertificateAccountGeneration = scope.generation;
    if (tlsHandoff) {
      const fingerprint: string = this.vncCertificateInfo === null ? '' :
        this.vncCertificateInfo.fingerprintSha256.trim().toLowerCase();
      if (!isVncSha256Fingerprint(fingerprint)) {
        this.vncCertificateState = VncCertificatePreflightState.ERROR;
        this.vncCertificateError = 'E-VNC-CERT-HANDOFF';
        return;
      }
      this.vncCredentialCertificateFingerprint = fingerprint;
      this.vncCredentialCertificateGeneration = this.vncCertificateProbeGeneration;
    } else {
      this.vncCredentialCertificateFingerprint = '';
      this.vncCredentialCertificateGeneration = this.vncCertificateProbeGeneration;
    }
    if (tlsHandoff) { params['vncCertificateHandoffGeneration'] = this.vncCertificateProbeGeneration; }
    if (plaintextConfirmed) {
      if (endpoint.tlsRequired || !this.vncPlaintextHandoff.put(
        host.userId, 'vnc-cert:' + host.id, this.vncCertificateProbeGeneration,
        endpoint.endpointBindingFingerprint, scope.ownerScopeId.trim(), storeFingerprint,
        scope.generation)) {
        this.vncCertificateState = VncCertificatePreflightState.ERROR;
        this.vncCertificateError = 'E-VNC-PLAINTEXT-HANDOFF';
        return;
      }
      params['vncPlaintextHandoffGeneration'] = this.vncCertificateProbeGeneration;
    }
    this.vncCertificatePendingRouteParams = params;
    if (this.showRemoteHostSheet && !this.vncCertificateClosing) {
      this.vncCertificateClosing = true;
      this.vncCertificateClosingHostId = hostId;
      this.vncCertificateClosingAttemptGeneration = this.vncCertificateAttemptGeneration;
      this.beginRemoteHostSheetClose(REMOTE_HOST_SHEET_VNC_CERTIFICATE);
      this.showVncCertificatePreflight = false;
      this.showRemoteHostSheet = false;
      return;
    }
    const route: Record<string, Object> = params;
    this.vncCertificatePendingRouteParams = null;
    setTimeout((): void => {
      this.prepareVncCredentialPreflight(route, hostId);
    }, 0);
  }

  private handleVncCertificatePreflightDisappear(): void {
    this.noteSheetDismissed();
    const hostId: string = this.vncCertificateClosingHostId.length > 0
      ? this.vncCertificateClosingHostId : this.vncCertificateHostId;
    const route: Record<string, Object> | null = this.vncCertificatePendingRouteParams;
    this.vncCertificatePendingRouteParams = null;
    this.vncCertificateClosing = false;
    this.showVncCertificatePreflight = false;
    this.vncCertificateClosingHostId = '';
    this.vncCertificateClosingAttemptGeneration = 0;
    this.vncCertificateProbeRequestId = 0;
    this.vncCertificateHostId = '';
    this.vncCertificateHostLabel = '';
    this.vncCertificateInfo = null;
    this.vncCertificateWarning = '';
    this.vncCertificateError = '';
    this.vncCertificateShowDetails = false;
    this.vncCertificateState = VncCertificatePreflightState.IDLE;
    if (route !== null && this.pageActive) {
      setTimeout((): void => {
        this.prepareVncCredentialPreflight(route, hostId);
      }, 0);
      return;
    }
    this.releaseConnectionAttempt(hostId);
    this.clearVncCredentialCertificateRoute();
    const nextHostId: string = this.vncCertificatePendingHostId;
    this.vncCertificatePendingHostId = '';
    if (nextHostId !== '') {
      const nextHost: RemoteHost | undefined = this.srv.getHost(nextHostId);
      if (nextHost !== undefined) { void this.connectToHost(nextHost); }
    }
  }

  private clearVncCredentialCertificateRoute(): void {
    this.vncCredentialCertificateFingerprint = '';
    this.vncCredentialCertificateGeneration = 0;
    this.vncCredentialCertificateEndpointBinding = '';
    this.vncCredentialCertificateOwnerScopeId = '';
    this.vncCredentialCertificateStoreFingerprint = '';
    this.vncCredentialCertificateAccountGeneration = 0;
  }

  private refreshVncCertificateHandoffForRoute(host: VncHostView,
    route: Record<string, Object>): boolean {
    const scope = AccountSessionCoordinator.getInstance().currentScope();
    const endpoint: VncTlsEndpointResolution = this.resolveVncCertificateEndpoint(host);
    if (!endpoint.ok ||
      endpoint.endpointBindingFingerprint !== this.vncCredentialCertificateEndpointBinding ||
      scope.ownerScopeId.trim() !== this.vncCredentialCertificateOwnerScopeId ||
      scope.generation !== this.vncCredentialCertificateAccountGeneration ||
      this.vncCertificateStoreFingerprint() !== this.vncCredentialCertificateStoreFingerprint) {
      return false;
    }
    if (this.vncCredentialCertificateFingerprint === '') {
      const plaintextGeneration: number =
        typeof route['vncPlaintextHandoffGeneration'] === 'number' ?
          route['vncPlaintextHandoffGeneration'] as number : 0;
      return !endpoint.tlsRequired && plaintextGeneration > 0 &&
        plaintextGeneration === this.vncCredentialCertificateGeneration &&
        this.vncPlaintextHandoff.put(
          host.userId, 'vnc-cert:' + host.id, this.vncCredentialCertificateGeneration,
          this.vncCredentialCertificateEndpointBinding,
          this.vncCredentialCertificateOwnerScopeId,
          this.vncCredentialCertificateStoreFingerprint,
          this.vncCredentialCertificateAccountGeneration);
    }
    return this.vncCertificateHandoff.put(
      host.userId, 'vnc-cert:' + host.id, this.vncCredentialCertificateGeneration,
      this.vncCredentialCertificateEndpointBinding,
      this.vncCredentialCertificateFingerprint,
      this.vncCredentialCertificateOwnerScopeId,
      this.vncCredentialCertificateStoreFingerprint,
      this.vncCredentialCertificateAccountGeneration);
  }

  private prepareVncCredentialPreflight(route: Record<string, Object>, routeHostId: string): void {
    const vncHostId: string = typeof route['vncHostId'] === 'string' ?
      (route['vncHostId'] as string).trim() : '';
    const host: VncHostView | null = vncHostId === '' ? null : this.vncHosts.find(vncHostId);
    if (!this.pageActive || host === null ||
      host.userId.trim() !== this.vncHosts.currentUserId().trim()) {
      if (vncHostId !== '') {
        VncSessionCredentialHandoff.getInstance().clear(
          this.vncHosts.currentUserId(), vncHostId);
        this.vncPlaintextHandoff.clear(
          this.vncHosts.currentUserId(), 'vnc-cert:' + vncHostId);
      }
      this.releaseConnectionAttempt(routeHostId);
      this.clearVncCredentialCertificateRoute();
      promptAction.showToast({ message: 'VNC 主机或账号状态已变化，连接已停止', duration: 2200 });
      return;
    }
    const endpoint: VncTlsEndpointResolution = this.resolveVncCertificateEndpoint(host);
    const scope = AccountSessionCoordinator.getInstance().currentScope();
    if (!endpoint.ok ||
      endpoint.endpointBindingFingerprint !== this.vncCredentialCertificateEndpointBinding ||
      scope.ownerScopeId.trim() !== host.userId.trim() ||
      scope.ownerScopeId.trim() !== this.vncCredentialCertificateOwnerScopeId ||
      scope.generation !== this.vncCredentialCertificateAccountGeneration ||
      this.vncCertificateStoreFingerprint() !== this.vncCredentialCertificateStoreFingerprint) {
      VncSessionCredentialHandoff.getInstance().clear(host.userId, host.id);
      this.vncPlaintextHandoff.clear(host.userId, 'vnc-cert:' + host.id);
      this.releaseConnectionAttempt(routeHostId);
      this.clearVncCredentialCertificateRoute();
      promptAction.showToast({ message: 'VNC endpoint 或账号状态已变化，连接已停止', duration: 2200 });
      return;
    }
    this.vncCredentialEndpointBinding = this.vncCredentialCertificateEndpointBinding;
    this.vncCredentialOwnerScopeId = this.vncCredentialCertificateOwnerScopeId;
    this.vncCredentialAccountGeneration = this.vncCredentialCertificateAccountGeneration;
    const forcePrompt: boolean = this.vncCredentialRetryHostId === host.id;
    const replaceSavedPassword: boolean =
      this.vncCredentialRetryReplaceSavedHostId === host.id;
    this.vncCredentialRetryHostId = '';
    this.vncCredentialRetryReplaceSavedHostId = '';
    const state: VncCredentialPreflightState = this.vncHosts.passwordStateFor(host.id).state;
    const transientAvailable: boolean = VncSessionCredentialHandoff.getInstance().bind(
      host.userId, host.id, this.vncCredentialEndpointBinding,
      this.vncCredentialOwnerScopeId, this.vncCredentialAccountGeneration);
    if (!vncCredentialPreflightNeedsPrompt(state, transientAvailable, forcePrompt)) {
      this.routePreparedVncSession(route, routeHostId, host);
      return;
    }
    this.vncCredentialHostId = host.id;
    this.vncCredentialHostLabel = host.label;
    this.vncCredentialPassword = '';
    this.vncCredentialRememberPassword = false;
    this.vncCredentialNoPassword = false;
    this.vncCredentialPasswordVisible = false;
    this.vncCredentialState = state;
    this.vncCredentialError = vncCredentialPreflightMessage(state, forcePrompt);
    this.vncCredentialRouteHostId = routeHostId;
    this.vncCredentialPendingRouteParams = route;
    this.vncCredentialRouteAfterClose = false;
    this.vncCredentialClosing = false;
    this.vncCredentialReplacingFailedPassword = replaceSavedPassword;
    this.openSheetSafely((): void => {
      this.openRemoteHostSheet(REMOTE_HOST_SHEET_VNC_CREDENTIAL, (): void => {});
    }, true);
  }

  private finishVncCredentialPreflight(password: string, remember: boolean,
    allowPlaintext: boolean): void {
    const host: VncHostView | null = this.vncHosts.find(this.vncCredentialHostId);
    if (host === null || this.vncCredentialPendingRouteParams === null) { return; }
    if (!this.vncCredentialBindingIsCurrent(host)) {
      this.vncCredentialError = 'VNC endpoint 或账号状态已变化，请取消后重新预检。';
      return;
    }
    if (remember) {
      const saved = this.vncHosts.savePassword(host.id, password, true, allowPlaintext);
      if (!saved.ok) {
        promptAction.showToast({
          message: (saved.message || 'VNC 密码保存失败') + '；本次仍使用临时密码连接',
          duration: 2400
        });
      }
    } else if (this.vncCredentialReplacingFailedPassword) {
      const removed = this.vncHosts.savePassword(host.id, '', false, false);
      if (!removed.ok) {
        promptAction.showToast({
          message: (removed.message || '旧 VNC 密码清理失败') + '；本次仍使用临时选择连接',
          duration: 2400
        });
      }
    }
    if (!VncSessionCredentialHandoff.getInstance().put(
      host.userId, host.id, password, this.vncCredentialEndpointBinding,
      this.vncCredentialOwnerScopeId, this.vncCredentialAccountGeneration)) {
      this.vncCredentialError = 'VNC 一次性凭据交接失败，请重试。';
      return;
    }
    this.vncCredentialPassword = '';
    this.vncCredentialRouteAfterClose = true;
    this.vncCredentialClosing = true;
    this.beginRemoteHostSheetClose(REMOTE_HOST_SHEET_VNC_CREDENTIAL);
    this.showRemoteHostSheet = false;
  }

  private confirmVncCredentialPreflight(): void {
    if (this.vncCredentialNoPassword) {
      this.finishVncCredentialPreflight('', false, false);
      return;
    }
    if (this.vncCredentialPassword.length === 0) {
      this.vncCredentialError = '请输入 VNC 密码，或明确选择“无密码连接”。';
      return;
    }
    const crypto: DataCrypto = DataCrypto.getInstance();
    if (this.vncCredentialRememberPassword && crypto.isSetupComplete() && !crypto.isReady()) {
      this.vncCredentialError = '应用加密已锁定；请先解锁，或关闭“记住密码”后连接。';
      return;
    }
    if (this.vncCredentialRememberPassword && !crypto.isSetupComplete()) {
      promptAction.showDialog({
        title: '确认保存未加密密码',
        message: '应用加密未启用。记住此密码会以未加密形式保存；也可以关闭后仅本次使用。',
        buttons: [{ text: '取消', color: this.pal().text2 },
          { text: '确认保存', color: this.pal().danger }]
      }).then((dialog: Object): void => {
        const values: Record<string, number> = dialog as Record<string, number>;
        if (values['index'] === 1) {
          this.finishVncCredentialPreflight(this.vncCredentialPassword, true, true);
        }
      });
      return;
    }
    this.finishVncCredentialPreflight(
      this.vncCredentialPassword, this.vncCredentialRememberPassword, false);
  }

  private useSavedVncCredential(): void {
    const host: VncHostView | null = this.vncHosts.find(this.vncCredentialHostId);
    if (host === null || !this.vncCredentialBindingIsCurrent(host)) {
      this.vncCredentialError = 'VNC endpoint 或账号状态已变化，请取消后重新预检。';
      return;
    }
    if (!this.vncHosts.grantPlaintextPasswordConsent(host.id)) {
      this.vncCredentialError = '本地确认失败，请重新输入一次性密码。';
      return;
    }
    const loaded = this.vncHosts.passwordStateFor(host.id);
    if (loaded.state !== 'available') {
      this.vncCredentialError = '已保存密码不可用，请重新输入一次性密码。';
      return;
    }
    this.finishVncCredentialPreflight(loaded.plaintext, false, false);
  }

  private vncCredentialBindingIsCurrent(host: VncHostView): boolean {
    const endpoint: VncTlsEndpointResolution = this.resolveVncCertificateEndpoint(host);
    const scope = AccountSessionCoordinator.getInstance().currentScope();
    return endpoint.ok &&
      endpoint.endpointBindingFingerprint === this.vncCredentialEndpointBinding &&
      scope.ownerScopeId.trim() === this.vncCredentialOwnerScopeId &&
      scope.generation === this.vncCredentialAccountGeneration &&
      this.vncCertificateStoreFingerprint() === this.vncCredentialCertificateStoreFingerprint;
  }

  private cancelVncCredentialPreflight(closeSheet: boolean = true): void {
    if (this.vncCredentialClosing) { return; }
    const host: VncHostView | null = this.vncHosts.find(this.vncCredentialHostId);
    if (host !== null) {
      VncSessionCredentialHandoff.getInstance().clear(host.userId, host.id);
      this.vncCertificateHandoff.clear(host.userId, 'vnc-cert:' + host.id);
      this.vncPlaintextHandoff.clear(host.userId, 'vnc-cert:' + host.id);
    }
    this.vncCredentialRouteAfterClose = false;
    this.vncCredentialClosing = true;
    this.beginRemoteHostSheetClose(REMOTE_HOST_SHEET_VNC_CREDENTIAL);
    if (closeSheet) { this.showRemoteHostSheet = false; }
  }

  private handleVncCredentialPreflightDisappear(): void {
    const route: Record<string, Object> | null = this.vncCredentialPendingRouteParams;
    const routeHostId: string = this.vncCredentialRouteHostId;
    const host: VncHostView | null = this.vncHosts.find(this.vncCredentialHostId);
    const shouldRoute: boolean = this.vncCredentialRouteAfterClose && route !== null && host !== null;
    this.vncCredentialHostId = '';
    this.vncCredentialHostLabel = '';
    this.vncCredentialPassword = '';
    this.vncCredentialRememberPassword = false;
    this.vncCredentialNoPassword = false;
    this.vncCredentialPasswordVisible = false;
    this.vncCredentialState = 'missing';
    this.vncCredentialError = '';
    this.vncCredentialRouteHostId = '';
    this.vncCredentialPendingRouteParams = null;
    this.vncCredentialRouteAfterClose = false;
    this.vncCredentialClosing = false;
    this.vncCredentialReplacingFailedPassword = false;
    this.vncCredentialEndpointBinding = '';
    this.vncCredentialOwnerScopeId = '';
    this.vncCredentialAccountGeneration = 0;
    this.noteSheetDismissed();
    if (shouldRoute) {
      setTimeout((): void => {
        this.routePreparedVncSession(route as Record<string, Object>, routeHostId,
          host as VncHostView);
      }, 0);
      return;
    }
    this.releaseConnectionAttempt(routeHostId);
    this.clearVncCredentialCertificateRoute();
  }

  private routePreparedVncSession(route: Record<string, Object>, routeHostId: string,
    host: VncHostView): void {
    if (!this.refreshVncCertificateHandoffForRoute(host, route)) {
      VncSessionCredentialHandoff.getInstance().clear(host.userId, host.id);
      this.vncCertificateHandoff.clear(host.userId, 'vnc-cert:' + host.id);
      this.vncPlaintextHandoff.clear(host.userId, 'vnc-cert:' + host.id);
      this.releaseConnectionAttempt(routeHostId);
      this.clearVncCredentialCertificateRoute();
      promptAction.showToast({ message: 'VNC endpoint 已变化，请重新进行证书预检', duration: 2400 });
      return;
    }
    this.releaseConnectionAttempt(routeHostId);
    this.clearVncCredentialCertificateRoute();
    this.openSessionDestination('pages/RemoteDesktop', route, 'vnc_preflight_complete');
  }

  /** T-210: 打开 SSH 前置校验 Sheet (通过统一 bindSheet) */
  private openSshPreflight(host: RemoteHost): void {
    if (this.sshPreflightClosing || this.showSshPreflight ||
      this.remoteHostSheetClosing || this.showRemoteHostSheet) {
      this.sshPreflightPendingHostId = host.id;
      hilog.info(0x0001, 'HostList', 'SSH preflight queued until previous Sheet disappears host=' + host.id);
      return;
    }
    const generation: number = nextRemoteHostSheetGeneration(this.sshPreflightGeneration);
    this.sshPreflightGeneration = generation;
    this.sshPreflightOpenedAt = Date.now();
    this.sshPreflightHostId = host.id;
    this.sshPreflightHostLabel = host.username + '@' + host.host + ':' + host.port.toString();
    this.sshPreflightSavedAlgorithm = host.sshHostKeyAlgorithm;
    this.sshPreflightJumpHostLabel = host.sshProxyType === 'ssh_jump' && host.proxyHost.trim() !== ''
      ? host.proxyHost + ':' + host.proxyPort.toString() : '';
    this.sshPreflightState = SshPreflightState.PROBING;
    this.sshPreflightHostKeyInfo = null;
    this.sshPreflightJumpHostKeyInfo = null;
    this.sshPreflightError = '';
    this.sshPreflightPassphraseInput = '';
    this.sshPreflightProxyPassphraseInput = '';
    this.sshPreflightPassphraseScope = 'target';
    this.sshPreflightPassphraseSaveToHost = false;
    this.sshPreflightProxyPassphraseSaveToHost = false;
    this.sshPreflightPendingRouteParams = null;
    this.openSheetSafely((): void => {
      this.openRemoteHostSheet(REMOTE_HOST_SHEET_SSH_PREFLIGHT, (): void => {
        this.showSshPreflight = true;
      });
    }, true);
    this.doSshPreflightProbe(host, generation);
  }

  /** T-210: 关闭 preflight */
  private doSshPreflightCancel(closeSheet: boolean = true): void {
    const hostId: string = this.sshPreflightHostId;
    this.sshPreflightGeneration = nextRemoteHostSheetGeneration(this.sshPreflightGeneration);
    this.sshPreflightClosingHostId = hostId;
    this.sshPreflightClosing = true;
    this.beginRemoteHostSheetClose(REMOTE_HOST_SHEET_SSH_PREFLIGHT);
    if (closeSheet) {
      this.showSshPreflight = false;
      this.showRemoteHostSheet = false;
    }
  }

  private sshPreflightSheetHeight(): SheetSize | number {
    return SheetSize.FIT_CONTENT;
  }

  private isSshPreflightBusy(): boolean {
    return this.sshPreflightState === SshPreflightState.PROBING ||
      this.sshPreflightState === SshPreflightState.VERIFYING_PASSPHRASE;
  }

  private handleSshPreflightSheetDisappear(): void {
    this.noteSheetDismissed();
    const routeParams: Record<string, Object> | null = this.sshPreflightPendingRouteParams;
    const nextHostId: string = this.sshPreflightPendingHostId;
    this.sshPreflightPendingRouteParams = null;
    this.sshPreflightPendingHostId = '';
    this.sshPreflightClosing = false;
    this.sshPreflightClosingHostId = '';
    this.showSshPreflight = false;
    this.sshPreflightHostId = '';
    this.sshPreflightHostLabel = '';
    this.sshPreflightHostKeyInfo = null;
    this.sshPreflightJumpHostLabel = '';
    this.sshPreflightJumpHostKeyInfo = null;
    this.sshPreflightError = '';
    if (routeParams !== null) {
      setTimeout((): void => {
        this.openSessionDestination('pages/SshTerminal', routeParams, 'ssh_preflight_complete');
      }, 0);
      return;
    }
    if (nextHostId === '') {
      return;
    }
    const nextHost: RemoteHost | undefined = this.srv.getHost(nextHostId);
    if (nextHost) {
      const delayMs: number = sheetOpenDelayMsAfterDismiss(Date.now(), this.lastSheetDismissAtMs);
      setTimeout((): void => { this.openSshPreflight(nextHost); }, delayMs);
    }
  }

  /** 获取当前 preflight host (从 CloudStore) */
  private getSshPreflightHost(): RemoteHost | undefined {
    return this.srv.getHost(this.sshPreflightHostId);
  }

  /**
   * 主机指纹/密钥预检必须使用与最终 SSH 会话相同的传输路径。
   * 指纹探测本身不带 expected key, 否则 native 会在变化时只返回失败，
   * UI 无法展示新指纹供用户比较；认证预检和最终连接再带上绑定值。
   */
  private sshPreflightProxy(host: RemoteHost, includeExpectedJumpKey: boolean = false): SshProxyConfig {
    const isJump: boolean = host.sshProxyType === 'ssh_jump';
    const proxyKeyMaterial: SshKeyMaterial = this.resolveSshProxyKeyMaterial(host);
    const proxyAuthMethod = host.sshProxyAuthMethod;
    const proxyPassphrase: string = this.sshPreflightProxyPassphraseInput || host.sshProxyKeyPassphrase;
    return {
      type: host.proxyHost.length > 0 ? host.sshProxyType : 'direct',
      host: host.proxyHost,
      port: host.proxyPort,
      username: host.proxyUsername,
      password: isJump && proxyAuthMethod !== 'publickey' ? host.sshProxyPassword : '',
      privateKeyPem: isJump && proxyAuthMethod === 'publickey' ? proxyKeyMaterial.privateKey : '',
      privateKeyPassphrase: isJump && proxyAuthMethod === 'publickey'
        ? proxyPassphrase : '',
      authMethod: isJump ? proxyAuthMethod : undefined,
      expectedHostKeyRawBase64: includeExpectedJumpKey && isJump ? host.sshJumpHostKeyRawBase64 : '',
      expectedHostKeyFingerprintSha256: includeExpectedJumpKey && isJump
        ? host.sshJumpHostKeyFingerprintSha256 : ''
    };
  }

  private resolveSshProxyKeyMaterial(host: RemoteHost): SshKeyMaterial {
    let keyData: string = '';
    let encryptedHint: boolean = false;
    if (host.sshProxyKeyId !== '') {
      const ref = KeyVaultService.getInstance().getSshKey(host.sshProxyKeyId);
      if (ref) {
        keyData = ref.privateKey;
        encryptedHint = ref.privateKeyEncrypted;
      }
    }
    return { privateKey: keyData, encryptedHint: encryptedHint };
  }

  private sshPreflightUsesJump(host: RemoteHost): boolean {
    return host.sshProxyType === 'ssh_jump' && host.proxyHost.trim() !== '' &&
      host.proxyPort > 0 && host.proxyPort <= 65535;
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
    if (host) {
      this.sshPreflightState = SshPreflightState.PROBING;
      this.doSshPreflightProbe(host, this.sshPreflightGeneration);
    }
  }

  private doSshPreflightTrustFirstWrap(): void {
    const host = this.getSshPreflightHost();
    if (host) { this.doSshPreflightTrustFirst(host, this.sshPreflightGeneration); }
  }

  private doSshPreflightContinueWrap(): void {
    const host = this.getSshPreflightHost();
    if (host) { this.doSshPreflightCheckPassphrase(host, this.sshPreflightGeneration); }
  }

  private doSshPreflightUpdateWrap(): void {
    const host = this.getSshPreflightHost();
    if (host) { this.doSshPreflightUpdateTrust(host, this.sshPreflightGeneration); }
  }

  private doSshPreflightVerifyWrap(): void {
    const host = this.getSshPreflightHost();
    if (host) { this.doSshPreflightVerifyPassphrase(host, this.sshPreflightGeneration); }
  }

  /** T-210: 探测主机指纹 (async, 完成后更新 @State) */
  private async doSshPreflightProbe(host: RemoteHost, generation: number): Promise<void> {
    try {
      await new Promise<void>((r) => setTimeout(r, 80));
      if (!this.isCurrentSshPreflight(host, generation)) { return; }
      const info = await this.loader.probeSshHostKeyAsync(
        host.host, host.port, this.sshPreflightProxy(host));
      if (!this.isCurrentSshPreflight(host, generation)) { return; }
      if (!info.ok) {
        this.sshPreflightState = SshPreflightState.ERROR;
        this.sshPreflightError = info.errorMessage || '无法读取 SSH 主机指纹';
        return;
      }
      let jumpInfo: SshHostKeyInfo | null = null;
      if (this.sshPreflightUsesJump(host)) {
        jumpInfo = await this.loader.probeSshHostKeyAsync(host.proxyHost, host.proxyPort);
        if (!this.isCurrentSshPreflight(host, generation)) { return; }
        if (!jumpInfo.ok) {
          this.sshPreflightState = SshPreflightState.ERROR;
          this.sshPreflightError = '无法读取跳板机 SSH 主机指纹: ' +
            (jumpInfo.errorMessage || '跳板机 KEX 握手失败');
          return;
        }
      }
      this.sshPreflightHostKeyInfo = info;
      this.sshPreflightJumpHostKeyInfo = jumpInfo;
      const targetChanged = host.sshHostKeyTrustMode === 1 && host.sshHostKeyRawBase64 !== '' &&
        host.sshHostKeyRawBase64 !== info.rawBase64;
      const jumpChanged = jumpInfo !== null && host.sshJumpHostKeyTrustMode === 1 &&
        host.sshJumpHostKeyRawBase64 !== '' && host.sshJumpHostKeyRawBase64 !== jumpInfo.rawBase64;
      const targetNeedsTrust = host.sshHostKeyTrustMode !== 1 || host.sshHostKeyRawBase64 === '' ||
        host.sshHostKeyRawBase64 !== info.rawBase64;
      const jumpNeedsTrust = jumpInfo !== null &&
        (host.sshJumpHostKeyTrustMode !== 1 || host.sshJumpHostKeyRawBase64 === '' ||
          host.sshJumpHostKeyRawBase64 !== jumpInfo.rawBase64);
      if (targetChanged || jumpChanged) {
        this.sshPreflightState = SshPreflightState.HOST_KEY_CHANGED;
      } else if (!targetNeedsTrust && !jumpNeedsTrust) {
        this.sshPreflightState = SshPreflightState.TRUSTED_MATCH;
      } else {
        this.sshPreflightState = SshPreflightState.TRUST_FIRST_TIME;
      }
    } catch (e) {
      if (!this.isCurrentSshPreflight(host, generation)) { return; }
      this.sshPreflightState = SshPreflightState.ERROR;
      this.sshPreflightError = '探测主机指纹异常: ' + (e instanceof Error ? e.message : JSON.stringify(e));
    }
  }

  /** T-210: 用户确认信任 (首次) */
  private doSshPreflightTrustFirst(host: RemoteHost, generation: number): void {
    if (!this.isCurrentSshPreflight(host, generation) || !this.sshPreflightHostKeyInfo) { return; }
    const info = this.sshPreflightHostKeyInfo;
    if (this.sshPreflightUsesJump(host) && !this.sshPreflightJumpHostKeyInfo) { return; }
    const updated: RemoteHost = RemoteHost.fromJSON(host.toJSON());
    this.applySshPreflightTrust(updated, info, this.sshPreflightJumpHostKeyInfo);
    if (!this.srv.updateHost(updated)) {
      this.sshPreflightState = SshPreflightState.ERROR;
      this.sshPreflightError = 'SSH 指纹验证成功，但信任记录保存失败；连接已停止。';
      return;
    }
    this.doSshPreflightCheckPassphrase(updated, generation);
  }

  /** T-210: 指纹变更 → 更新信任 */
  private doSshPreflightUpdateTrust(host: RemoteHost, generation: number): void {
    if (!this.isCurrentSshPreflight(host, generation) || !this.sshPreflightHostKeyInfo) { return; }
    const info = this.sshPreflightHostKeyInfo;
    if (this.sshPreflightUsesJump(host) && !this.sshPreflightJumpHostKeyInfo) { return; }
    const updated: RemoteHost = RemoteHost.fromJSON(host.toJSON());
    this.applySshPreflightTrust(updated, info, this.sshPreflightJumpHostKeyInfo);
    if (!this.srv.updateHost(updated)) {
      this.sshPreflightState = SshPreflightState.ERROR;
      this.sshPreflightError = 'SSH 新指纹验证成功，但信任记录保存失败；连接已停止。';
      return;
    }
    this.doSshPreflightCheckPassphrase(updated, generation);
  }

  private applySshPreflightTrust(host: RemoteHost, targetInfo: SshHostKeyInfo,
    jumpInfo: SshHostKeyInfo | null): void {
    const trustedAt: number = Date.now();
    host.sshHostKeyAlgorithm = targetInfo.algorithm;
    host.sshHostKeyFingerprintSha256 = targetInfo.fingerprintSha256;
    host.sshHostKeyRawBase64 = targetInfo.rawBase64;
    host.sshHostKeyTrustedAt = trustedAt;
    host.sshHostKeyTrustMode = 1;
    if (jumpInfo !== null) {
      host.sshJumpHostKeyAlgorithm = jumpInfo.algorithm;
      host.sshJumpHostKeyFingerprintSha256 = jumpInfo.fingerprintSha256;
      host.sshJumpHostKeyRawBase64 = jumpInfo.rawBase64;
      host.sshJumpHostKeyTrustedAt = trustedAt;
      host.sshJumpHostKeyTrustMode = 1;
    }
  }

  /** T-210: 检查私钥密码 */
  private doSshPreflightCheckPassphrase(host: RemoteHost, generation: number): void {
    if (!this.isCurrentSshPreflight(host, generation)) { return; }
    if (this.sshPreflightUsesJump(host) && host.sshProxyAuthMethod === 'publickey') {
      const proxyMaterial: SshKeyMaterial = this.resolveSshProxyKeyMaterial(host);
      if (proxyMaterial.privateKey.length === 0) {
        this.sshPreflightState = SshPreflightState.ERROR;
        this.sshPreflightError = '跳板机私钥不存在或已从密钥保险库移除';
        return;
      }
      const proxyKeyInfo: SshPrivateKeyInfo = this.loader.inspectSshPrivateKey(
        proxyMaterial.privateKey, host.sshProxyKeyPassphrase);
      if (proxyKeyInfo.ok && !proxyKeyInfo.encrypted) {
        this.sshPreflightProxyPassphraseInput = '';
      } else if (host.sshProxyKeyPassphrase === '' &&
        (proxyMaterial.encryptedHint || proxyKeyInfo.encrypted)) {
        this.showSshPreflightPassphrase('', false, 'proxy');
        return;
      } else if (host.sshProxyKeyPassphrase !== '' && !proxyKeyInfo.ok) {
        this.showSshPreflightPassphrase('已保存的跳板机私钥密码不可用，请重新输入', true, 'proxy');
        return;
      } else if (!proxyKeyInfo.ok) {
        this.sshPreflightState = SshPreflightState.ERROR;
        this.sshPreflightError = '跳板机私钥不可用: ' +
          (proxyKeyInfo.error || '无法解析私钥');
        return;
      } else {
        this.sshPreflightProxyPassphraseInput = host.sshProxyKeyPassphrase;
      }
    }
    if (!host.sshUseKey) { this.doSshPreflightReady(host, generation); return; }
    const material = this.resolveSshKeyMaterial(host);
    const keyData = material.privateKey;
    if (keyData.length === 0) { this.doSshPreflightReady(host, generation); return; }

    const keyInfo: SshPrivateKeyInfo = this.loader.inspectSshPrivateKey(keyData, host.sshKeyPassphrase);
    if (keyInfo.ok && !keyInfo.encrypted) {
      this.doSshPreflightVerifyKeyAuth(host, '', false, generation);
      return;
    }
    if (host.sshKeyPassphrase === '' && (material.encryptedHint || keyInfo.encrypted)) {
      this.showSshPreflightPassphrase('');
    } else if (host.sshKeyPassphrase !== '' && !keyInfo.ok && keyInfo.encrypted) {
      this.showSshPreflightPassphrase('已保存的私钥密码不可用，请重新输入', true);
    } else {
      this.doSshPreflightVerifyKeyAuth(host, host.sshKeyPassphrase, false, generation);
    }
  }

  private showSshPreflightPassphrase(error: string, saveDefault: boolean = false,
    scope: string = 'target'): void {
    this.sshPreflightState = SshPreflightState.PASSPHRASE_REQUIRED;
    this.sshPreflightPassphraseScope = scope;
    if (scope === 'proxy') {
      this.sshPreflightProxyPassphraseInput = '';
      this.sshPreflightProxyPassphraseSaveToHost = saveDefault;
    } else {
      this.sshPreflightPassphraseInput = '';
      this.sshPreflightPassphraseSaveToHost = saveDefault;
    }
    this.sshPreflightError = error;
  }

  private async doSshPreflightVerifyKeyAuth(host: RemoteHost, passphrase: string,
    allowPassphraseRetry: boolean, generation: number): Promise<void> {
    if (!this.isCurrentSshPreflight(host, generation)) { return; }
    this.sshPreflightState = SshPreflightState.VERIFYING_PASSPHRASE;
    try {
      await new Promise<void>((r) => setTimeout(r, 60));
      if (!this.isCurrentSshPreflight(host, generation)) { return; }
      const keyData = this.resolveSshKeyMaterial(host).privateKey;
      const result = await this.loader.testSshKeyAuthAsync(
        host.host, host.port, host.username, keyData, passphrase,
        this.sshPreflightProxy(host, true)
      );
      if (!this.isCurrentSshPreflight(host, generation)) { return; }
      if (result.ok) {
        this.doSshPreflightReady(host, generation);
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
      if (!this.isCurrentSshPreflight(host, generation)) { return; }
      this.sshPreflightState = SshPreflightState.ERROR;
      this.sshPreflightError = '密钥认证验证异常: ' + (e instanceof Error ? e.message : JSON.stringify(e));
    }
  }

  private hasSavedSshPreflightPassphrase(): boolean {
    const host = this.getSshPreflightHost();
    if (host === undefined) { return false; }
    return this.sshPreflightPassphraseScope === 'proxy'
      ? host.sshProxyKeyPassphrase !== '' : host.sshKeyPassphrase !== '';
  }

  private async doSshPreflightVerifyProxyPassphrase(host: RemoteHost,
    generation: number): Promise<void> {
    if (!this.isCurrentSshPreflight(host, generation)) { return; }
    try {
      await new Promise<void>((r) => setTimeout(r, 60));
      if (!this.isCurrentSshPreflight(host, generation)) { return; }
      const keyData: string = this.resolveSshProxyKeyMaterial(host).privateKey;
      const keyInfo: SshPrivateKeyInfo = this.loader.inspectSshPrivateKey(
        keyData, this.sshPreflightProxyPassphraseInput);
      if (!keyInfo.ok || !keyInfo.encrypted) {
        this.showSshPreflightPassphrase(
          keyInfo.ok ? '此跳板机私钥实际未设置密码，请在密钥管理中重新设置密码' :
            '跳板机私钥密码错误或密钥不可用',
          keyInfo.ok ? false : true, 'proxy');
        return;
      }
      if (this.sshPreflightProxyPassphraseSaveToHost) {
        const updated: RemoteHost = RemoteHost.fromJSON(host.toJSON());
        updated.sshProxyKeyPassphrase = this.sshPreflightProxyPassphraseInput;
        if (!this.srv.updateHost(updated)) {
          this.sshPreflightState = SshPreflightState.PASSPHRASE_REQUIRED;
          this.sshPreflightError = '跳板机私钥密码验证成功，但保存失败；连接已停止。';
          return;
        }
        host = updated;
      }
      this.sshPreflightPassphraseScope = 'target';
      this.sshPreflightPassphraseInput = '';
      this.sshPreflightError = '';
      this.doSshPreflightCheckPassphrase(host, generation);
    } catch (_e) {
      if (!this.isCurrentSshPreflight(host, generation)) { return; }
      this.showSshPreflightPassphrase('跳板机私钥验证异常', false, 'proxy');
    }
  }

  /** T-210: 验证私钥密码 */
  private async doSshPreflightVerifyPassphrase(host: RemoteHost, generation: number): Promise<void> {
    if (!this.isCurrentSshPreflight(host, generation)) { return; }
    if (this.sshPreflightPassphraseScope === 'proxy') {
      await this.doSshPreflightVerifyProxyPassphrase(host, generation);
      return;
    }
    this.sshPreflightState = SshPreflightState.VERIFYING_PASSPHRASE;
    try {
      await new Promise<void>((r) => setTimeout(r, 60));
      if (!this.isCurrentSshPreflight(host, generation)) { return; }
      const keyData = this.resolveSshKeyMaterial(host).privateKey;
      const keyInfo: SshPrivateKeyInfo = this.loader.inspectSshPrivateKey(keyData, this.sshPreflightPassphraseInput);
      if (keyInfo.ok && !keyInfo.encrypted) {
        this.showSshPreflightPassphrase('此私钥实际未设置密码，请在密钥管理中重新设置密码');
        return;
      }
      const result = await this.loader.testSshKeyAuthAsync(
        host.host, host.port, host.username, keyData, this.sshPreflightPassphraseInput,
        this.sshPreflightProxy(host, true)
      );
      if (!this.isCurrentSshPreflight(host, generation)) { return; }
      if (result.ok) {
        if (this.sshPreflightPassphraseSaveToHost) {
          const updated: RemoteHost = RemoteHost.fromJSON(host.toJSON());
          updated.sshKeyPassphrase = this.sshPreflightPassphraseInput;
          if (!this.srv.updateHost(updated)) {
            this.sshPreflightState = SshPreflightState.PASSPHRASE_REQUIRED;
            this.sshPreflightError = '私钥密码验证成功，但保存失败；连接已停止。';
            return;
          }
          host = updated;
        }
        this.doSshPreflightReady(host, generation);
      } else {
        this.showSshPreflightPassphrase('私钥密码错误或密钥不可用');
      }
    } catch (e) {
      if (!this.isCurrentSshPreflight(host, generation)) { return; }
      this.showSshPreflightPassphrase('验证异常');
    }
  }

  /** T-210: 一切就绪 — 创建 token 并路由 */
  private doSshPreflightReady(host: RemoteHost, generation: number): void {
    if (!this.isCurrentSshPreflight(host, generation)) { return; }
    const svc = SshPreflightService.getInstance();
    const passphrase = this.sshPreflightPassphraseInput || host.sshKeyPassphrase;
    const proxyPassphrase = this.sshPreflightProxyPassphraseInput || host.sshProxyKeyPassphrase;
    const rawBase64 = this.sshPreflightHostKeyInfo?.rawBase64 || host.sshHostKeyRawBase64;
    const fp = this.sshPreflightHostKeyInfo?.fingerprintSha256 || host.sshHostKeyFingerprintSha256;
    const jumpRawBase64 = this.sshPreflightJumpHostKeyInfo?.rawBase64 || host.sshJumpHostKeyRawBase64;
    const jumpFp = this.sshPreflightJumpHostKeyInfo?.fingerprintSha256 ||
      host.sshJumpHostKeyFingerprintSha256;
    const tokenId = svc.createToken({
      hostId: host.id,
      expectedHostKeyRawBase64: rawBase64,
      expectedHostKeyFingerprintSha256: fp,
      expectedJumpHostKeyRawBase64: jumpRawBase64,
      expectedJumpHostKeyFingerprintSha256: jumpFp,
      privateKeyPassphrase: passphrase,
      proxyPrivateKeyPassphrase: proxyPassphrase
    });
    const params: Record<string, Object> = {};
    params['hostId'] = host.id;
    params['sshPreflightToken'] = tokenId;
    this.sshPreflightPendingRouteParams = params;
    this.sshPreflightClosingHostId = host.id;
    this.sshPreflightClosing = true;
    this.beginRemoteHostSheetClose(REMOTE_HOST_SHEET_SSH_PREFLIGHT);
    this.showRemoteHostSheet = false;
  }

  private handleHostCardClick(host: RemoteHost): void {
    if (this.hostSelectionMode) {
      const key: string = remoteHostCardKey(host.id);
      this.toggleHostSelect(key, !this.hostSelectedIds.has(key));
      return;
    }
    this.connectToHost(host);
  }

  private setHostPresenceProbeBusy(hostId: string, busy: boolean): void {
    const wasBusy: boolean = this.hostPresenceProbeBusyIds.has(hostId);
    const next: Set<string> = new Set(this.hostPresenceProbeBusyIds);
    if (busy) { next.add(hostId); } else { next.delete(hostId); }
    this.hostPresenceProbeBusyIds = next;
    // Grouped cards are cached inside one ListItem. Invalidate that root on
    // both edges so the completed probe is rendered after "checking" clears.
    if (wasBusy !== busy) { this.hostViewRevision += 1; }
  }

  private updateLocalPresenceObservation(host: RemoteHost): void {
    this.hostPresenceLocalObservationWrite = true;
    try {
      this.srv.updateLocalHostObservation(host);
    } finally {
      this.hostPresenceLocalObservationWrite = false;
    }
  }

  private nextHostPresenceProbeGeneration(hostId: string): number {
    const next: number = (this.hostPresenceProbeGenerations.get(hostId) ?? 0) + 1;
    this.hostPresenceProbeGenerations.set(hostId, next);
    return next;
  }

  private isCurrentHostPresenceProbe(hostId: string, pageGeneration: number,
    probeGeneration: number): boolean {
    return this.pageActive && pageGeneration === this.hostPresencePageGeneration &&
      probeGeneration === (this.hostPresenceProbeGenerations.get(hostId) ?? 0);
  }

  private hostHealthForLatency(latencyMs: number): ConnectionHealth {
    if (latencyMs < 0) { return ConnectionHealth.UNKNOWN; }
    if (latencyMs < 20) { return ConnectionHealth.EXCELLENT; }
    if (latencyMs < 50) { return ConnectionHealth.GOOD; }
    if (latencyMs < 100) { return ConnectionHealth.FAIR; }
    if (latencyMs < 200) { return ConnectionHealth.POOR; }
    return ConnectionHealth.BAD;
  }

  private async probeRustDeskPresenceWithTimeout(
    endpointHost: string,
    endpointPort: number,
    serverKey: string,
    peerId: string,
    token: string,
    direct: boolean,
    keyMode: number
  ): Promise<RustDeskPresenceResult> {
    const timeoutResult: Promise<RustDeskPresenceResult> = new Promise<RustDeskPresenceResult>((resolve): void => {
      setTimeout((): void => {
        resolve({ state: 0, latencyMs: -1, errorCode: 6 });
      }, 5000);
    });
    // The native probe has transport-level timeouts, but the UI also needs a
    // bounded completion when a native async request is delayed during device
    // sleep, relay startup, or an interrupted network transition.
    return await Promise.race([
      this.loader.probeRustDeskPresenceAsync(
        endpointHost, endpointPort, serverKey, peerId, token, direct, keyMode),
      timeoutResult
    ]);
  }

  private async probeHostConnectivity(host: RemoteHost, showToast: boolean = true): Promise<void> {
    if (this.hostPresenceProbeBusyIds.has(host.id)) { return; }
    if (host.protocol === 'rustdesk') {
      if (host.rustdeskDirectEnabled) {
        if (showToast) {
          promptAction.showToast({ message: '直连主机无需在线探测', duration: 1800 });
        }
        return;
      }
      await this.probeRustDeskPresence(host, showToast, true);
      return;
    }

    this.setHostPresenceProbeBusy(host.id, true);
    const startedAt: number = Date.now();
    try {
      let ok: boolean = false;
      if (host.protocol === 'rdp') {
        if (this.rdpCertificateUsesRouteProbe(host)) {
          const result: RdpPreflightResult = await this.loader.probeRdpCertificateRouteAsync(
            this.rdpCertificateRouteRequest(host, Date.now()));
          ok = result.ok && result.targetCertificate.present &&
            (this.rdpCertificateRouteMode(host) !== 'microsoft_rd_gateway' ||
              result.gatewayCertificate.present);
        } else {
          const info: RdpCertificateInfo = await this.loader.probeRdpCertificateAsync(
            host.host, host.port, host.customHostname);
          ok = info.ok;
        }
      } else if (host.protocol === 'vnc') {
        const probe = this.loader.probeVncCertificateAsync(host.host, host.port, host.host, 3000);
        const info: VncCertificateInfo = await probe;
        ok = info.ok;
      } else if (host.protocol === 'ssh') {
        const info: SshHostKeyInfo = await this.loader.probeSshHostKeyAsync(
          host.host, host.port, this.sshPreflightProxy(host));
        ok = info.ok;
      }
      const latencyMs: number = Date.now() - startedAt;
      if (host.protocol !== 'vnc') {
        // Use the observation path so the local card updates even when a
        // throttled cloud write is unavailable. The service also replaces the
        // host object instead of mutating the object captured by the card.
        await this.srv.updateConnectionHealth(host.id, ok ? latencyMs : -1, ok);
      }
      // VNC owns a separate record and cannot persist health in remotehosts.
      // Keep all three non-RustDesk protocols on the same immediate card path.
      this.setHostPresenceOverride(host.id, ok ? 'online' : 'unknown', ok ? latencyMs : -1);
      this.refreshHostListView(true);
      if (showToast) {
        promptAction.showToast({
          message: ok ? host.protocol.toUpperCase() + ' 可达 · ' + latencyMs.toString() + ' ms' :
            host.protocol.toUpperCase() + ' 未检测到主机',
          duration: 1800
        });
      }
    } catch (_err) {
      this.setHostPresenceOverride(host.id, 'unknown');
      if (showToast) {
        promptAction.showToast({ message: host.protocol.toUpperCase() + ' 检测失败', duration: 1800 });
      }
    } finally {
      this.setHostPresenceProbeBusy(host.id, false);
    }
  }

  private async probeRustDeskPresence(host: RemoteHost, showToast: boolean,
    manual: boolean = false): Promise<void> {
    if (this.hostPresenceProbeBusyIds.has(host.id) || host.rustdeskDirectEnabled) { return; }
    if (!this.rustdeskPresenceDetectionEnabled && !manual) { return; }
    const pageGeneration: number = this.hostPresencePageGeneration;
    const probeGeneration: number = this.nextHostPresenceProbeGeneration(host.id);
    this.setHostPresenceProbeBusy(host.id, true);
    this.setHostPresenceOverride(host.id, 'checking');
    // Checking is page-local. Persist only the completed result so entering
    // the page does not emit an extra data-change event for every host.
    const markResult = (state: number, latencyMs: number = -1): void => {
      if (!this.isCurrentHostPresenceProbe(host.id, pageGeneration, probeGeneration)) { return; }
      // Resolve the latest service object so a delayed probe result cannot
      // restore fields from the card snapshot that existed when it started.
      const latest: RemoteHost = this.srv.getHost(host.id) ?? host;
      const updated: RemoteHost = RemoteHost.fromJSON(latest.toJSON());
      if (state === 1) {
        updated.rustdeskProLastSeenAt = Date.now();
        updated.rustdeskProSyncError = '';
        updated.lastLatency = latencyMs >= 0 ? Math.max(1, Math.floor(latencyMs)) : 0;
        updated.lastHealth = latencyMs >= 0 ? this.hostHealthForLatency(latencyMs) : ConnectionHealth.UNKNOWN;
      } else if (state === 2) {
        updated.rustdeskProLastSeenAt = 0;
        updated.rustdeskProSyncError = HOST_PRESENCE_PROBE_OFFLINE;
        updated.lastLatency = 0;
        updated.lastHealth = ConnectionHealth.UNKNOWN;
      } else {
        updated.rustdeskProLastSeenAt = 0;
        updated.rustdeskProSyncError = HOST_PRESENCE_PROBE_UNKNOWN;
        updated.lastLatency = 0;
        updated.lastHealth = ConnectionHealth.UNKNOWN;
      }
      this.updateLocalPresenceObservation(updated);
      const displayState: HostPresenceState = state === 1 ? 'online' :
        (state === 2 ? 'offline' : 'unknown');
      this.setHostPresenceOverride(host.id, displayState, displayState === 'online' ? latencyMs : -1);
      hilog.info(0x0001, 'HostList', 'RustDesk probe result state=' + state.toString() +
        ' latency=' + latencyMs.toString());
    };
    try {
      const direct: boolean = host.rustdeskDirectEnabled;
      const relay: RustDeskRelayConfig | undefined = direct ? undefined :
        this.srv.getAllRelays().find((item: RustDeskRelayConfig): boolean =>
          item.id === host.rustdeskRelayId);
      const peerId: string = rustDeskProPeerIdForConnection(
        host.rustdeskProPeerId, host.customHostname);
      let endpointHost: string = '';
      let endpointPort: number = 0;
      let serverKey: string = '';
      let token: string = '';
      let keyMode: number = 1;
      if (direct) {
        const endpoint: RustDeskHostEndpoint = resolveRustDeskHostEndpoint(
          null, host.host, true, host.rustdeskDirectHost, host.rustdeskDirectPort);
        endpointHost = endpoint.host;
        endpointPort = endpoint.port;
      } else if (relay !== undefined) {
        const context: RustDeskConnectionContext = this.rustDeskConnectionContext(host, relay);
        endpointHost = relay.idServer;
        endpointPort = relay.idServerPort;
        serverKey = relay.key;
        token = context.accessToken;
        keyMode = rustDeskRelayKeyModeForFfi(relay.key, relay.keyMode);
        if (!context.ready && context.requiresAccount) {
          markResult(0);
          if (showToast) {
            promptAction.showToast({ message: 'RustDesk 控制面未就绪，状态未知', duration: 2200 });
          }
          return;
        }
      } else {
        markResult(0);
        if (showToast) {
          promptAction.showToast({ message: 'RustDesk 中继配置不存在，状态未知', duration: 2200 });
        }
        return;
      }
      if (endpointHost.trim() === '' || endpointPort <= 0 || (!direct && peerId.trim() === '')) {
        markResult(0);
        if (showToast) {
          promptAction.showToast({ message: 'RustDesk 探测参数不完整，状态未知', duration: 2200 });
        }
        return;
      }
      const result: RustDeskPresenceResult = await this.probeRustDeskPresenceWithTimeout(
        endpointHost, endpointPort, serverKey, peerId, token, direct, keyMode);
      markResult(result.state, result.latencyMs);
      if (showToast) {
        const text: string = result.state === 1 ?
          'RustDesk 在线 · ' + result.latencyMs.toString() + ' ms' :
          (result.state === 2 ? 'RustDesk 离线' : 'RustDesk 状态未知');
        promptAction.showToast({ message: text, duration: 1800 });
      }
    } catch (_err) {
      markResult(0);
      if (showToast) {
        promptAction.showToast({ message: 'RustDesk 状态检测失败，状态未知', duration: 2200 });
      }
    } finally {
      this.setHostPresenceProbeBusy(host.id, false);
    }
  }

  private async refreshRustDeskPresence(): Promise<void> {
    if (this.hostPresenceRefreshRunning || !this.pageActive || !this.rustdeskPresenceDetectionEnabled) { return; }
    this.hostPresenceRefreshRunning = true;
    try {
      const rustDeskHosts: RemoteHost[] = this.hosts.filter((host: RemoteHost): boolean =>
        host.protocol === 'rustdesk' && !host.rustdeskDirectEnabled);
      for (let i = 0; i < rustDeskHosts.length; i++) {
        if (!this.pageActive || !this.rustdeskPresenceDetectionEnabled) { break; }
        await this.probeRustDeskPresence(rustDeskHosts[i], false);
      }
    } finally {
      this.hostPresenceRefreshRunning = false;
    }
  }

  private async probeHostGroup(card: HostGroupCardModel): Promise<void> {
    if (this.hostGroupProbeBusyType !== '' || card.hosts.length === 0) { return; }
    const targets: RemoteHost[] = card.hosts.filter((host: RemoteHost): boolean =>
      !(host.protocol === 'rustdesk' && host.rustdeskDirectEnabled));
    const skipped: number = card.hosts.length - targets.length;
    if (targets.length === 0) {
      promptAction.showToast({ message: card.title + ' 直连主机无需在线探测', duration: 1800 });
      return;
    }

    this.hostGroupProbeBusyType = card.type;
    let online: number = 0;
    let offline: number = 0;
    let unknown: number = 0;
    try {
      for (let i = 0; i < targets.length; i++) {
        if (!this.pageActive) { break; }
        const host: RemoteHost = targets[i];
        await this.probeHostConnectivity(host, false);
        const state: HostPresenceState = this.hostGroupPresenceForHost(host);
        if (state === 'online' || state === 'recently_online') {
          online++;
        } else if (state === 'offline') {
          offline++;
        } else {
          unknown++;
        }
      }
      if (this.pageActive) {
        const parts: string[] = [];
        if (online > 0) { parts.push(online.toString() + ' 在线'); }
        if (offline > 0) { parts.push(offline.toString() + ' 离线'); }
        if (unknown > 0) { parts.push(unknown.toString() + ' 未检测到'); }
        if (skipped > 0) { parts.push(skipped.toString() + ' 直连无需探测'); }
        promptAction.showToast({
          message: card.title + ' 检测完成' + (parts.length > 0 ? ' · ' + parts.join(' · ') : ''),
          duration: 2200
        });
      }
    } finally {
      this.hostGroupProbeBusyType = '';
      this.hostViewRevision += 1;
    }
  }

  private vncRecordIdForHost(host: RemoteHost): string {
    return isVncHostProjection(host) ? vncHostRecordIdFromUiId(host.id) : '';
  }

  private clearPendingVncCredentialForRemoteHost(host: RemoteHost): void {
    const vncHostId: string = this.vncRecordIdForHost(host);
    if (vncHostId === '') { return; }
    const owner: VncHostView | null = this.vncHosts.find(vncHostId);
    const userId: string = owner === null ? host.userId.trim() : owner.userId.trim();
    if (userId === '') { return; }
    VncSessionCredentialHandoff.getInstance().clear(userId, vncHostId);
    this.vncCertificateHandoff.clear(userId, 'vnc-cert:' + vncHostId);
    this.vncPlaintextHandoff.clear(userId, 'vnc-cert:' + vncHostId);
  }

  private async toggleLock(host: RemoteHost): Promise<void> {
    const r = await showLockGate(host.label, 'biometric');
    if (!r.ok) {
      const msg: string = lockGateErrorMessage(r);
      if (msg !== '') { promptAction.showToast({ message: msg, duration: 2000 }); }
      return;
    }
    const vncHostId: string = this.vncRecordIdForHost(host);
    if (vncHostId !== '') {
      const nextLocked: boolean = !host.locked;
      if (!this.vncHosts.updateLock(vncHostId, nextLocked,
        nextLocked ? LockType.BIOMETRIC : LockType.NONE)) {
        promptAction.showToast({ message: '保存 VNC 主机状态失败', duration: 2000 });
        return;
      }
      this.refreshHostSnapshotAfterMutation();
      promptAction.showToast({ message: nextLocked ? '已锁定' : '已解锁', duration: 1500 });
      return;
    }
    const updated: RemoteHost = RemoteHost.fromJSON(host.toJSON());
    updated.locked = !host.locked;
    updated.lockType = updated.locked ? LockType.BIOMETRIC : LockType.NONE;
    if (!this.srv.updateHost(updated)) {
      promptAction.showToast({ message: '保存主机状态失败', duration: 2000 });
      return;
    }
    this.refreshHostSnapshotAfterMutation();
    promptAction.showToast({ message: updated.locked ? '已锁定' : '已解锁', duration: 1500 });
  }

  private prepareRustDeskProPreflight(host: RemoteHost): number {
    this.rustDeskProPreflightGeneration += 1;
    const generation: number = this.rustDeskProPreflightGeneration;
    const scope = AccountSessionCoordinator.getInstance().currentScope();
    const draft: RustDeskAuthDraft | null = this.rustDeskAuthDrafts.load(
      scope.ownerScopeId, scope.generation, host.id);
    this.rustDeskProPreflightHostId = host.id;
    this.rustDeskProAuthMode = host.rustdeskDirectEnabled ? 'password' :
      (draft !== null ? draft.authChoice :
        (host.rustdeskAuthMode === 'request_approval' ? 'request_approval' : 'password'));
    this.rustDeskProPassword = draft === null ? host.password : draft.password;
    this.rustDeskProPasswordMode = draft === null ?
      (host.rustdeskPasswordMode === 1 ? 1 : 0) : draft.passwordMode;
    this.rustDeskProPasswordVisible = false;
    this.rustDeskProRememberPassword = draft === null ? true : draft.rememberPassword;
    this.rustDeskProPreflightError = '';
    this.rustDeskProPreflightState = RustDeskProPreflightState.IDLE;
    this.rustDeskProTwoFactorActive = false;
    this.rustDeskProTwoFactorSessionId = -1;
    this.rustDeskProTwoFactorAutoAttemptSessionId = -1;
    this.rustDeskProTwoFactorInput = '';
    this.rustDeskProTwoFactorError = '';
    this.rustDeskProTwoFactorSubmitting = false;
    this.rustDeskProTwoFactorEntryOptions = [];
    this.rustDeskProTwoFactorSelectedEntryId = '';
    this.rustDeskProDisconnectIdentity = null;
    return generation;
  }

  private saveRustDeskProAuthDraft(): void {
    const hostId: string = this.rustDeskProPreflightHostId.trim();
    if (hostId === '') { return; }
    const scope = AccountSessionCoordinator.getInstance().currentScope();
    this.rustDeskAuthDrafts.save({
      ownerScopeId: scope.ownerScopeId,
      accountGeneration: scope.generation,
      hostId,
      authChoice: this.rustDeskProAuthMode === 'request_approval' ?
        'request_approval' : 'password',
      password: this.rustDeskProPassword,
      passwordMode: this.rustDeskProPasswordMode === 1 ? 1 : 0,
      rememberPassword: this.rustDeskProRememberPassword,
      updatedAt: Date.now()
    });
  }

  private clearRustDeskProAuthDraft(hostId: string): void {
    const scope = AccountSessionCoordinator.getInstance().currentScope();
    this.rustDeskAuthDrafts.clear(scope.ownerScopeId, scope.generation, hostId);
    if (this.rustDeskProBackgroundResumeHostId === hostId) {
      this.rustDeskProBackgroundResumeHostId = '';
      this.rustDeskProBackgroundDismissConfirmed = false;
    }
  }

  private openRustDeskProPreflight(host: RemoteHost): void {
    if (this.rustDeskProPreflightClosing || this.showRustDeskProPreflight ||
      this.remoteHostSheetClosing || this.showRemoteHostSheet) {
      // connectToHost 已经为该主机占住了连接尝试；等旧 Sheet 的 onDisappear
      // 完成后再把同一个请求打开，避免旧动画和新 builder 同时存在。
      this.rustDeskProPreflightPendingHostId = host.id;
      hilog.info(0x0001, 'HostList', 'RustDesk preflight queued until previous Sheet disappears host=' +
        hashForLog(host.id));
      return;
    }
    const generation: number = this.prepareRustDeskProPreflight(host);
    this.openSheetSafely((): void => {
      if (generation !== this.rustDeskProPreflightGeneration || this.rustDeskProPreflightClosing) {
        return;
      }
      this.openRemoteHostSheet(REMOTE_HOST_SHEET_RUSTDESK_PREFLIGHT, (): void => {
        this.showRustDeskProPreflight = true;
      });
    }, true);
  }

  private isCurrentRustDeskPreflightDirect(): boolean {
    const host: RemoteHost | undefined = this.srv.getHost(this.rustDeskProPreflightHostId);
    return host !== undefined && host.rustdeskDirectEnabled;
  }

  /**
   * Retry a RustDesk preflight teardown with the identity captured when that
   * exact native session was created. Delayed Sheet callbacks must never ask
   * ExtensionLoader to recapture whichever facade happens to be current.
   */
  private submitRustDeskProExactDisconnect(
    identity: NativeDisconnectIdentity
  ): void {
    const retryPort: RemoteSessionExactDisconnectCallbackPort =
      new RemoteSessionExactDisconnectCallbackPort(
      (expected: RemoteSessionExactDisconnectIdentity):
        RemoteSessionExactDisconnectSubmission => {
        return this.loader.disconnectWithReceipt(expected);
      },
      (expected: RemoteSessionExactDisconnectIdentity,
        submission: RemoteSessionExactDisconnectSubmission): void => {
        if (!submission.accepted) {
          if (!submission.retryable) {
            hilog.warn(0x0001, 'HostList',
              'ignored stale RustDesk preflight teardown session=' +
              expected.sessionId.toString());
          }
          return;
        }
        if (remoteSessionExactDisconnectIdentityEquals(
          this.rustDeskProDisconnectIdentity, expected)) {
          this.rustDeskProDisconnectIdentity = null;
        }
        if (!submission.terminal && submission.requestId > 0) {
          void this.loader.waitForTeardownRequest(submission.requestId).then(
            (completed: boolean): void => {
              if (!completed) {
                hilog.error(0x0001, 'HostList',
                  'RustDesk preflight teardown did not complete request=' +
                  submission.requestId.toString());
              }
            });
          return;
        }
        if (!submission.successful) {
          hilog.error(0x0001, 'HostList',
            'RustDesk preflight synchronous teardown failed');
        }
      },
      (task: () => void, delayMs: number): void => {
        setTimeout(task, delayMs);
      });
    submitRemoteSessionExactDisconnectWithRetry(identity, retryPort);
  }

  private cancelRustDeskProPreflight(closeSheet: boolean = true,
    preserveDraft: boolean = false): void {
    const hostId: string = this.rustDeskProPreflightHostId;
    if (preserveDraft) {
      this.saveRustDeskProAuthDraft();
      this.rustDeskProBackgroundResumeHostId = hostId;
    } else {
      this.rustDeskProBackgroundDismissConfirmed = false;
      this.clearRustDeskProAuthDraft(hostId);
    }
    const disconnectIdentity: NativeDisconnectIdentity | null =
      this.rustDeskProDisconnectIdentity;
    this.rustDeskProPreflightGeneration += 1;
    if (this.rustDeskProPreflightState === RustDeskProPreflightState.CONNECTING &&
        disconnectIdentity !== null) {
      this.submitRustDeskProExactDisconnect(disconnectIdentity);
    }
    this.rustDeskProTwoFactorActive = false;
    this.rustDeskProTwoFactorSessionId = -1;
    this.rustDeskProTwoFactorAutoAttemptSessionId = -1;
    this.rustDeskProTwoFactorInput = '';
    this.rustDeskProTwoFactorError = '';
    this.rustDeskProTwoFactorSubmitting = false;
    this.rustDeskProTwoFactorEntryOptions = [];
    this.rustDeskProTwoFactorSelectedEntryId = '';
    this.rustDeskProPreflightPendingRouteParams = null;
    this.rustDeskProPreflightClosingHostId = hostId;
    this.rustDeskProPreflightClosing = true;
    this.beginRemoteHostSheetClose(REMOTE_HOST_SHEET_RUSTDESK_PREFLIGHT);
    this.lastSheetDismissAtMs = Date.now();
    if (closeSheet) {
      this.showRustDeskProPreflight = false;
      this.showRemoteHostSheet = false;
    }
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
    this.showRustDeskProPreflight = false;
    this.rustDeskProPreflightHostId = '';
    this.rustDeskProPreflightState = RustDeskProPreflightState.IDLE;
    this.rustDeskProPreflightError = '';
    this.rustDeskProPassword = '';
    this.rustDeskProTwoFactorActive = false;
    this.rustDeskProTwoFactorSessionId = -1;
    this.rustDeskProTwoFactorAutoAttemptSessionId = -1;
    this.rustDeskProTwoFactorInput = '';
    this.rustDeskProTwoFactorError = '';
    this.rustDeskProTwoFactorSubmitting = false;
    this.rustDeskProTwoFactorEntryOptions = [];
    this.rustDeskProTwoFactorSelectedEntryId = '';
    this.releaseConnectionAttempt(closingHostId);

    if (routeParams !== null) {
      // 认证成功的会话必须先完成 Sheet 退出，再切换页面；连接尝试也在这里
      // 释放，防止新页面出现时 HostList 仍被旧请求占用。
      if (nextHostId.length > 0) {
        this.releaseConnectionAttempt(nextHostId);
      }
      setTimeout((): void => {
        this.openSessionDestination('pages/RemoteDesktop', routeParams, 'rustdesk_authenticated');
      }, 0);
      return;
    }

    if (nextHostId.length === 0) {
      this.settleRustDeskProImplicitDismiss();
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

  private rustDeskProAccountForHost(host: RemoteHost): RustDeskProAccountState | undefined {
    const accountId: string = rustDeskProAccountIdForConnection(
      host.rustdeskProAccountId, host.rustdeskAccountId);
    if (accountId !== '') { return this.proSync.getAccount(accountId); }
    const candidates: RustDeskProAccountState[] = this.proSync.getAccounts()
      .filter((account: RustDeskProAccountState): boolean =>
        account.relayId === host.rustdeskRelayId &&
        account.loginStatus === 'logged_in' &&
        account.accessToken.trim() !== '');
    return candidates.length === 1 ? candidates[0] : undefined;
  }

  private rustDeskConnectionContext(
    host: RemoteHost,
    relay: RustDeskRelayConfig | undefined
  ): RustDeskConnectionContext {
    const explicitAccountId: string = rustDeskProAccountIdForConnection(
      host.rustdeskProAccountId, host.rustdeskAccountId);
    const account: RustDeskProAccountState | undefined =
      this.rustDeskProAccountForHost(host);
    const accountId: string = account === undefined
      ? explicitAccountId : account.id;
    return resolveRustDeskConnectionContext({
      direct: host.rustdeskDirectEnabled,
      relayId: relay === undefined ? host.rustdeskRelayId : relay.id,
      profile: relay === undefined
        ? RUSTDESK_CONTROL_PLANE_DEFAULT : relay.controlPlaneProfile,
      keyMode: relay === undefined ? 'server_public_key' : relay.keyMode,
      accountId,
      accountRelayId: account === undefined ? '' : account.relayId,
      accountPresent: account !== undefined,
      accountLoginStatus: account === undefined ? 'none' : account.loginStatus,
      accessToken: account === undefined ? '' : account.accessToken,
      accessTokenFingerprint: account === undefined
        ? '' : account.accessTokenFingerprint,
      tokenGeneration: account === undefined ? 0 : account.tokenGeneration,
      ownerScopeId: CloudStore.getInstance().currentScope().ownerScopeId,
      accountApiServer: account === undefined ? '' : account.serverUrl,
      configuredApiServer: relay === undefined ? '' : relay.apiServer,
      idServer: relay === undefined ? '' : relay.idServer,
      idServerPort: relay === undefined ? 0 : relay.idServerPort,
      relayServer: relay === undefined ? '' : relay.relayServer,
      relayPort: relay === undefined ? 0 : relay.relayPort,
      serverKeyMode: relay === undefined ? '' : relay.keyMode,
      serverKey: relay === undefined ? '' : relay.key,
      capabilityProof: account === undefined
        ? undefined : account.controlPlaneCapabilityProof
    });
  }

  private rustDeskProBindingError(host: RemoteHost): string {
    if (host.rustdeskDirectEnabled) { return ''; }
    const relay: RustDeskRelayConfig | undefined = this.srv.getAllRelays()
      .find((item: RustDeskRelayConfig): boolean => item.id === host.rustdeskRelayId);
    if (relay === undefined) {
      return 'RustDesk 中继配置不存在，请检查中继服务器设置。';
    }
    const connectionContext: RustDeskConnectionContext =
      this.rustDeskConnectionContext(host, relay);
    return connectionContext.ready ? '' : connectionContext.message;
  }

  private rustDeskProConfig(host: RemoteHost): SessionConfig {
    const relay: RustDeskRelayConfig | undefined = this.srv.getAllRelays()
      .find((item: RustDeskRelayConfig): boolean => item.id === host.rustdeskRelayId);
    const direct: boolean = host.rustdeskDirectEnabled;
    const account: RustDeskProAccountState | undefined =
      this.rustDeskProAccountForHost(host);
    const accountId: string = account === undefined
      ? rustDeskProAccountIdForConnection(
        host.rustdeskProAccountId, host.rustdeskAccountId)
      : account.id;
    const connectionContext: RustDeskConnectionContext =
      this.rustDeskConnectionContext(host, relay);
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
      // Request-approval is a passwordless RustDesk login.  Never forward a
      // saved device password as an accidental fallback for this attempt.
      username: '',
      password: rustDeskAuthModeForConnection(direct, host.rustdeskAuthMode) ===
        'request_approval' ? '' : host.password,
      width: 1920, height: 1080,
      customHostname: rustDeskProPeerIdForConnection(host.rustdeskProPeerId, host.customHostname),
      gatewayHost: '', gatewayPort: 0, domain: '', codec: '',
      multiMonitor: false, monitorCount: 1, colorDepth: 32,
      authMethod: 'password', privateKeyPem: '', privateKeyPassphrase: '',
      rdImageQuality: this.rustdeskImageQuality, rdDirectIp: direct,
      rdConnectionStrategy: rustDeskConnectionStrategyForHost(direct),
      rdDirectPort: endpoint.port,
      rdLanDiscovery: this.rustdeskLanDiscovery, rdPrivacyMode: this.rustdeskPrivacyMode,
      rdAudioEnabled: this.rustdeskAudioEnabled, rdClipboardEnabled: this.rustdeskClipboardEnabled,
      rdPasswordMode: host.rustdeskPasswordMode,
      rdAuthMode: rustDeskAuthModeForConnection(direct, host.rustdeskAuthMode) === 'request_approval' ? 1 : 0,
      rdRelayId: host.rustdeskRelayId, rdAccountId: accountId,
      rdServerKey: relay ? relay.key : '',
      rdServerKeyMode: relay ? rustDeskRelayKeyModeForFfi(relay.key, relay.keyMode) : 1,
      rdRelayPort: rustDeskRelayFallbackPort(relay ?? null),
      rdAccessToken: connectionContext.accessToken
    };
  }

  private openRustDeskProTwoFactorPrompt(sessionId: number, message: string): void {
    if (this.rustDeskProTwoFactorSessionId !== sessionId) {
      this.rustDeskProTwoFactorInput = '';
      this.rustDeskProTwoFactorError = '';
      this.rustDeskProTwoFactorSubmitting = false;
      this.rustDeskProTwoFactorEntryOptions = [];
      this.rustDeskProTwoFactorSelectedEntryId = '';
    }
    this.rustDeskProTwoFactorSessionId = sessionId;
    this.rustDeskProTwoFactorActive = true;
    if (message.indexOf('Wrong 2FA Code') >= 0) {
      this.rustDeskProTwoFactorError = '验证码错误，请输入远端设备当前显示的 2FA 验证码。';
      this.rustDeskProTwoFactorSubmitting = false;
    } else if (message.length > 0 && message !== '2FA Required' &&
      message !== '2FA code submitted') {
      this.rustDeskProTwoFactorError = message;
    }
    this.refreshRustDeskProTwoFactorEntries(sessionId).catch((err: Error): void => {
      hilog.warn(0x0001, 'HostList', 'load RustDesk temporary 2FA entries failed: ' +
        (err.message ? err.message : JSON.stringify(err)));
    });
  }

  private async refreshRustDeskProTwoFactorEntries(sessionId: number): Promise<void> {
    if (this.rustDeskProTwoFactorSessionId !== sessionId ||
      !this.rustDeskProTwoFactorActive) {
      return;
    }
    if (!this.keyVault.isReady()) {
      await this.keyVault.init(getContext(this) as common.Context);
      await this.keyVault.whenReady();
    }
    if (this.rustDeskProTwoFactorSessionId !== sessionId ||
      !this.rustDeskProTwoFactorActive) {
      return;
    }
    const entries: TotpEntry[] = this.keyVault.getAllTotpEntries();
    const options: RustDeskTwoFactorEntryOption[] = [];
    for (let index = 0; index < entries.length; index++) {
      const entry: TotpEntry = entries[index];
      options.push({
        id: entry.id,
        label: entry.displayLabel(),
        detail: TotpEntry.algoLabel(entry.algorithm) + ' · ' + entry.digits.toString() + ' 位',
        locked: entry.locked
      });
    }
    this.rustDeskProTwoFactorEntryOptions = options;
    let selectedExists: boolean = false;
    for (let index = 0; index < options.length; index++) {
      if (options[index].id === this.rustDeskProTwoFactorSelectedEntryId) {
        selectedExists = true;
        break;
      }
    }
    if (!selectedExists) {
      const host: RemoteHost | undefined = this.srv.getHost(this.rustDeskProPreflightHostId);
      const preferredId: string = host === undefined ? '' : host.rustdeskTotpEntryId;
      for (let index = 0; index < options.length; index++) {
        if (options[index].id === preferredId) {
          this.rustDeskProTwoFactorSelectedEntryId = preferredId;
          selectedExists = true;
          break;
        }
      }
      if (!selectedExists) {
        this.rustDeskProTwoFactorSelectedEntryId = '';
      }
    }
  }

  private async authorizeRustDeskProTwoFactorEntry(entry: TotpEntry): Promise<boolean> {
    if (!this.totpPageLocked && !entry.locked) {
      return true;
    }
    const message: string = entry.locked
      ? '此 2FA 条目已锁定，请验证系统身份后临时使用。'
      : 'TOTP 隐私保护已开启，请验证系统身份后临时使用 RustDesk 2FA。';
    const gate = await showLockGate(message, 'biometric');
    return gate.ok;
  }

  private async submitSelectedRustDeskProTwoFactor(): Promise<void> {
    const sessionId: number = this.rustDeskProTwoFactorSessionId;
    if (sessionId <= 0 || !this.rustDeskProTwoFactorActive ||
      this.rustDeskProPreflightState !== RustDeskProPreflightState.CONNECTING) {
      this.rustDeskProTwoFactorError = '2FA 会话已失效，请重新连接。';
      return;
    }
    const entry: TotpEntry | undefined = this.keyVault.getTotpEntry(
      this.rustDeskProTwoFactorSelectedEntryId.trim());
    if (entry === undefined || entry.secret.length === 0) {
      this.rustDeskProTwoFactorError = '所选 2FA 条目不可用，请重新选择。';
      return;
    }
    if (!(await this.authorizeRustDeskProTwoFactorEntry(entry))) {
      if (this.rustDeskProTwoFactorSessionId === sessionId && this.rustDeskProTwoFactorActive) {
        this.rustDeskProTwoFactorError = '系统身份认证未通过，请手动输入验证码。';
      }
      return;
    }
    if (this.rustDeskProTwoFactorSessionId !== sessionId ||
      !this.rustDeskProTwoFactorActive ||
      this.rustDeskProPreflightState !== RustDeskProPreflightState.CONNECTING) {
      return;
    }
    const generated = TotpEngine.generateCode(entry);
    const autoSubmitError: string = rustDeskPeerTwoFactorAutoSubmitError(entry, generated);
    if (autoSubmitError !== '') {
      this.rustDeskProTwoFactorError = autoSubmitError;
      return;
    }
    if (!this.loader.submitRustDesk2FA(sessionId, generated.code)) {
      this.rustDeskProTwoFactorError = this.loader.getRustDeskLastError() ||
        '验证码提交失败，请重新选择或手动输入。';
      this.rustDeskProTwoFactorSubmitting = false;
      return;
    }
    this.rustDeskProTwoFactorInput = '';
    this.rustDeskProTwoFactorError = '';
    this.rustDeskProTwoFactorSubmitting = true;
  }

  private async tryAutoSubmitRustDeskProTwoFactor(sessionId: number, host: RemoteHost): Promise<boolean> {
    if (!host.rustdeskTotpAutoSubmit || host.rustdeskTotpEntryId === '' ||
      this.rustDeskProTwoFactorAutoAttemptSessionId === sessionId) {
      // `true` means an automatic flow was already handled for this session;
      // the caller must not reopen the manual sheet on every poll.
      return host.rustdeskTotpAutoSubmit && host.rustdeskTotpEntryId !== '';
    }
    this.rustDeskProTwoFactorAutoAttemptSessionId = sessionId;
    if (this.totpPageLocked) {
      const gate = await showLockGate(
        'TOTP 隐私保护已开启，请验证系统身份后自动填写 RustDesk 2FA', 'biometric');
      if (this.rustDeskProPreflightState !== RustDeskProPreflightState.CONNECTING) {
        return true;
      }
      if (!gate.ok) {
        let message: string =
          'TOTP 隐私保护已开启，自动填写 RustDesk 2FA 前需要完成系统身份认证。';
        if (gate.code === 12500010) {
          message = 'TOTP 隐私保护已开启，但系统尚未录入 PIN、指纹或人脸。请先到系统设置完成锁屏认证，或手动输入验证码。';
        } else if (gate.code === 12500003) {
          message = 'TOTP 隐私保护已开启，系统身份认证已取消，请手动输入验证码。';
        } else {
          const detail: string = lockGateErrorMessage(gate);
          if (detail !== '') { message += '（' + detail + '）'; }
        }
        this.openRustDeskProTwoFactorPrompt(sessionId, message);
        return true;
      }
    }
    if (this.rustDeskProPreflightState !== RustDeskProPreflightState.CONNECTING) {
      return true;
    }
    const entry: TotpEntry | undefined = this.keyVault.getTotpEntry(host.rustdeskTotpEntryId);
    if (entry === undefined || entry.secret.length === 0) {
      this.openRustDeskProTwoFactorPrompt(sessionId, '已绑定的 2FA 条目不可用，请手动输入验证码。');
      return true;
    }
    if (entry.locked && !(await this.authorizeRustDeskProTwoFactorEntry(entry))) {
      this.openRustDeskProTwoFactorPrompt(sessionId, '此 2FA 条目已锁定，请手动输入验证码或临时选择其他条目。');
      return true;
    }
    const generated = TotpEngine.generateCode(entry);
    const autoSubmitError: string = rustDeskPeerTwoFactorAutoSubmitError(entry, generated);
    if (autoSubmitError !== '') {
      this.openRustDeskProTwoFactorPrompt(sessionId, autoSubmitError);
      return true;
    }
    if (!this.loader.submitRustDesk2FA(sessionId, generated.code)) {
      this.openRustDeskProTwoFactorPrompt(sessionId, this.loader.getRustDeskLastError() ||
        '自动提交验证码失败，请手动输入。');
      return true;
    }
    this.rustDeskProTwoFactorSubmitting = true;
    // Do not open the manual input state after an automatic submission.  The
    // preflight sheet remains the single owner of the waiting status and is
    // dismissed only after native reports authentication success/failure.
    return true;
  }

  private cancelRustDeskProTwoFactor(): void {
    const disconnectIdentity: NativeDisconnectIdentity | null =
      this.rustDeskProDisconnectIdentity;
    this.rustDeskProPreflightGeneration += 1;
    if (disconnectIdentity !== null) {
      this.submitRustDeskProExactDisconnect(disconnectIdentity);
    }
    this.rustDeskProTwoFactorActive = false;
    this.rustDeskProTwoFactorSessionId = -1;
    this.rustDeskProTwoFactorAutoAttemptSessionId = -1;
    this.rustDeskProTwoFactorInput = '';
    this.rustDeskProTwoFactorError = '';
    this.rustDeskProTwoFactorSubmitting = false;
    this.rustDeskProTwoFactorEntryOptions = [];
    this.rustDeskProTwoFactorSelectedEntryId = '';
    this.rustDeskProPreflightState = RustDeskProPreflightState.ERROR;
    this.rustDeskProPreflightError = '连接已取消。';
  }

  private submitRustDeskProTwoFactor(): void {
    const code: string = this.rustDeskProTwoFactorInput.trim();
    if (!isRustDeskPeerTwoFactorManualCode(code)) {
      this.rustDeskProTwoFactorError = '请输入 6 或 8 位数字验证码。';
      return;
    }
    if (this.rustDeskProTwoFactorSessionId <= 0 ||
      !this.loader.submitRustDesk2FA(this.rustDeskProTwoFactorSessionId, code)) {
      this.rustDeskProTwoFactorError = this.loader.getRustDeskLastError() ||
        '验证码提交失败，请重新连接。';
      this.rustDeskProTwoFactorSubmitting = false;
      return;
    }
    this.rustDeskProTwoFactorInput = '';
    this.rustDeskProTwoFactorError = '';
    this.rustDeskProTwoFactorSubmitting = true;
  }

  private async confirmRustDeskProPreflight(): Promise<void> {
    const stored: RemoteHost | undefined = this.srv.getHost(this.rustDeskProPreflightHostId);
    if (!stored || this.rustDeskProPreflightState === RustDeskProPreflightState.CONNECTING) { return; }
    const bindingError: string = this.rustDeskProBindingError(stored);
    if (bindingError !== '') {
      this.rustDeskProPreflightError = bindingError;
      this.rustDeskProPreflightState = RustDeskProPreflightState.ERROR;
      return;
    }
    if (this.rustDeskProAuthMode === 'password' && this.rustDeskProPassword.trim().length === 0) {
      this.rustDeskProPreflightError = '请输入远程 RustDesk 设备密码。';
      return;
    }
    if (this.rustDeskProAuthMode === 'request_approval' && stored.rustdeskDirectEnabled) {
      this.rustDeskProPreflightError = '直连模式只能使用设备密码。';
      return;
    }
    const generation: number = ++this.rustDeskProPreflightGeneration;
    const accountScopeReady: boolean = await AccountSessionCoordinator.getInstance().init(
      getContext(this) as common.Context);
    if (!accountScopeReady) {
      this.rustDeskProPreflightState = RustDeskProPreflightState.ERROR;
      this.rustDeskProPreflightError = '账号数据域初始化失败，无法安全保留后台会话。';
      return;
    }
    const connectionScope = AccountSessionCoordinator.getInstance().currentScope();
    const host: RemoteHost = RemoteHost.fromJSON(stored.toJSON());
    copyRustDeskPeerTwoFactorRuntime(stored, host);
    const relay: RustDeskRelayConfig | undefined = this.srv.getAllRelays()
      .find((item: RustDeskRelayConfig): boolean => item.id === host.rustdeskRelayId);
    let controlPlaneProfile: RustDeskControlPlaneProfile =
      'third_party_api_only';
    let tokenProjected: boolean = false;
    let connectionAccount: RustDeskProAccountState | undefined =
      undefined;
    let expectedTokenFingerprint: string = '';
    let expectedTokenGeneration: number = 0;
    host.rustdeskAuthMode = this.rustDeskProAuthMode === 'request_approval' ? 'request_approval' : 'password';
    host.rustdeskPasswordMode = this.rustDeskProPasswordMode === 1 ? 1 : 0;
    if (host.rustdeskAuthMode === 'password') {
      host.password = this.rustDeskProPassword;
    } else {
      // The approval request is intentionally passwordless.  Do not let the
      // saved password on `stored` leak into this transient SessionConfig.
      host.password = '';
    }
    this.rustDeskProPreflightError = '';
    this.rustDeskProTwoFactorActive = false;
    this.rustDeskProTwoFactorSessionId = -1;
    this.rustDeskProTwoFactorAutoAttemptSessionId = -1;
    this.rustDeskProTwoFactorInput = '';
    this.rustDeskProTwoFactorError = '';
    this.rustDeskProTwoFactorSubmitting = false;
    this.rustDeskProTwoFactorEntryOptions = [];
    this.rustDeskProTwoFactorSelectedEntryId = '';
    this.rustDeskProPreflightState = RustDeskProPreflightState.CONNECTING;
    let preflightDisconnectIdentity: NativeDisconnectIdentity | null = null;
    try {
      if (!await this.loader.waitForPendingTeardown(5000)) {
        throw new Error('上一连接尚未完全结束，请稍后重试。');
      }
      const scopeAfterTeardown = AccountSessionCoordinator.getInstance().currentScope();
      if (scopeAfterTeardown.ownerScopeId !== connectionScope.ownerScopeId ||
        scopeAfterTeardown.generation !== connectionScope.generation) {
        throw new Error('账号已切换，旧账号连接已取消。');
      }
      const effectiveContext: RustDeskConnectionContext =
        this.rustDeskConnectionContext(host, relay);
      if (!effectiveContext.ready) {
        throw new Error(effectiveContext.message);
      }
      controlPlaneProfile = effectiveContext.profile;
      tokenProjected = effectiveContext.accessToken !== '';
      connectionAccount = this.rustDeskProAccountForHost(host);
      expectedTokenFingerprint =
        tokenProjected && connectionAccount !== undefined
          ? connectionAccount.accessTokenFingerprint : '';
      expectedTokenGeneration =
        tokenProjected && connectionAccount !== undefined
          ? connectionAccount.tokenGeneration : 0;
      const sessionConfig: SessionConfig =
        this.rustDeskProConfig(host);
      if (sessionConfig.rdAccessToken !==
        effectiveContext.accessToken) {
        throw new Error(
          '账号状态已变化，请重新发起连接。');
      }
      const sid: number = this.loader.connect(sessionConfig);
      if (sid <= 0) { throw new Error('无法启动 RustDesk 连接 [E-RUSTDESK-PREFLIGHT-' + Math.abs(sid).toString() + ']'); }
      preflightDisconnectIdentity = this.loader.captureDisconnectIdentity(sid);
      if (preflightDisconnectIdentity === null) {
        throw new Error('RustDesk 会话所有权回执不可用，已停止预鉴权流程。');
      }
      this.rustDeskProDisconnectIdentity = preflightDisconnectIdentity;
      const timeoutMs: number = 120000;
      const startedAt: number = Date.now();
      while (Date.now() - startedAt < timeoutMs) {
        if (generation !== this.rustDeskProPreflightGeneration) {
          this.submitRustDeskProExactDisconnect(preflightDisconnectIdentity);
          return;
        }
        const activeConnectionScope = AccountSessionCoordinator.getInstance().currentScope();
        if (activeConnectionScope.ownerScopeId !== connectionScope.ownerScopeId ||
          activeConnectionScope.generation !== connectionScope.generation) {
          this.submitRustDeskProExactDisconnect(preflightDisconnectIdentity);
          return;
        }
        const state: number = this.loader.getConnectionState(sid);
        if (state === 2) {
          this.rustDeskProTwoFactorActive = false;
          this.rustDeskProTwoFactorSessionId = -1;
          this.rustDeskProTwoFactorAutoAttemptSessionId = -1;
          this.rustDeskProTwoFactorInput = '';
          this.rustDeskProTwoFactorError = '';
          this.rustDeskProTwoFactorSubmitting = false;
          this.rustDeskProTwoFactorEntryOptions = [];
          this.rustDeskProTwoFactorSelectedEntryId = '';
          this.rustDeskProPreflightState = RustDeskProPreflightState.AUTHENTICATED;
          const saved: RemoteHost = RemoteHost.fromJSON(stored.toJSON());
          saved.rustdeskAuthMode = host.rustdeskAuthMode;
          saved.rustdeskPasswordMode = host.rustdeskPasswordMode;
          if (host.rustdeskAuthMode === 'password') {
            saved.password = this.rustDeskProRememberPassword ? host.password : '';
          }
          if (!this.srv.updateHost(saved)) {
            throw new Error('远端鉴权已通过，但设备密码保存失败；会话已安全停止，请重试。');
          }
          const now: number = Date.now();
          const record: ActiveRemoteSessionRecord = {
            ownerScopeId: connectionScope.ownerScopeId,
            accountGeneration: connectionScope.generation,
            sessionId: sid, hostId: host.id, protocol: RemoteProtocol.rustdesk,
            hostAddress: host.host, protocolConnected: true, renderAttached: false,
            restoreNeeded: true, latestSurfaceId: '', createdAtMs: now, updatedAtMs: now
          };
          if (!ActiveRemoteSessionRegistry.getInstance().setActive(record)) {
            throw new Error('远程会话账号作用域未登记，无法交接预鉴权会话。');
          }
          this.clearRustDeskProAuthDraft(host.id);
          const params: Record<string, Object> = {};
          params['hostId'] = host.id;
          params['rustdeskPreauthenticated'] = true;
          this.rustDeskProPreflightPendingRouteParams = params;
          this.rustDeskProPreflightClosingHostId = host.id;
          this.rustDeskProPreflightClosing = true;
          this.beginRemoteHostSheetClose(REMOTE_HOST_SHEET_RUSTDESK_PREFLIGHT);
          this.lastSheetDismissAtMs = Date.now();
          this.showRustDeskProPreflight = false;
          this.showRemoteHostSheet = false;
          if (remoteSessionExactDisconnectIdentityEquals(
            this.rustDeskProDisconnectIdentity, preflightDisconnectIdentity)) {
            this.rustDeskProDisconnectIdentity = null;
          }
          return;
        }
        if (state === 5) {
          const authMessage: string = this.loader.getConnectionLastMessage(sid);
          const automaticFlowHandled: boolean =
            await this.tryAutoSubmitRustDeskProTwoFactor(sid, host);
          if (!automaticFlowHandled || authMessage.indexOf('Wrong 2FA Code') >= 0) {
            this.openRustDeskProTwoFactorPrompt(sid, authMessage);
          }
        }
        if (state === 4 || state === 0) {
          const detail: string = this.loader.getRustDeskLastError() || this.loader.getConnectionLastMessage(sid);
          throw new Error(detail || '远端鉴权失败，请检查密码后重试。');
        }
        await new Promise<void>((resolve: () => void): void => { setTimeout(resolve, 100); });
      }
      throw new Error(host.rustdeskAuthMode === 'request_approval' ? '等待远端批准超时，请重新发起。' : '鉴权超时，请检查网络或密码。');
    } catch (err) {
      if (preflightDisconnectIdentity !== null) {
        this.submitRustDeskProExactDisconnect(preflightDisconnectIdentity);
      }
      if (generation !== this.rustDeskProPreflightGeneration) { return; }
      const failureScope = AccountSessionCoordinator.getInstance().currentScope();
      if (failureScope.ownerScopeId !== connectionScope.ownerScopeId ||
        failureScope.generation !== connectionScope.generation) {
        return;
      }
      this.rustDeskProTwoFactorActive = false;
      this.rustDeskProTwoFactorSessionId = -1;
      this.rustDeskProTwoFactorAutoAttemptSessionId = -1;
      this.rustDeskProTwoFactorInput = '';
      this.rustDeskProTwoFactorError = '';
      this.rustDeskProTwoFactorSubmitting = false;
      this.rustDeskProTwoFactorEntryOptions = [];
      this.rustDeskProTwoFactorSelectedEntryId = '';
      this.rustDeskProPreflightState = RustDeskProPreflightState.ERROR;
      const detail: string = err instanceof Error ? err.message : JSON.stringify(err);
      let kind: RustDeskProNativeErrorKind = classifyRustDeskProNativeError(detail);
      if (kind === 'unknown' && host.rustdeskAuthMode === 'request_approval' &&
        detail.indexOf('等待远端批准超时') >= 0) {
        kind = 'approval_timeout';
      }
      if (kind === 'pro_session_expired' &&
        canInvalidateRustDeskProSession(
          detail, controlPlaneProfile, tokenProjected)) {
        const invalidatedAccountId: string = connectionAccount === undefined
          ? rustDeskProAccountIdForConnection(
            host.rustdeskProAccountId, host.rustdeskAccountId)
          : connectionAccount.id;
        this.proSync.markConnectionSessionExpired(invalidatedAccountId, 'connection_token_expired',
          expectedTokenFingerprint, expectedTokenGeneration,
          connectionScope.ownerScopeId, connectionScope.generation);
      }
      this.rustDeskProPreflightError = kind === 'unknown'
        ? rustDeskNativeErrorDetail(detail)
        : rustDeskProNativeErrorMessage(
          kind, host.rustdeskAuthMode, controlPlaneProfile);
    }
  }

  private sshProxyEditorValueForHost(host: RemoteHost): SshProxyEditorValue {
    const stored: SshProxyProfileV1 | null = this.sshProxyProfiles.load(host.id);
    if (stored !== null) { return sshProxyEditorValueFromProfile(stored); }
    const value: SshProxyEditorValue = defaultSshProxyEditorValue();
    const legacyType: string = host.proxyHost.trim().length === 0 ? 'direct' : host.sshProxyType;
    if (legacyType === 'direct' || legacyType === 'http_connect' || legacyType === 'socks5' ||
      legacyType === 'ssh_jump' || legacyType === 'frp_tcp') {
      value.kind = legacyType as SshProxyEditorKind;
    }
    if (value.kind === 'http_connect' || value.kind === 'socks5' || value.kind === 'frp_tcp') {
      value.proxyHost = host.proxyHost;
      value.proxyPortText = host.proxyPort.toString();
      value.proxyUsername = host.proxyUsername;
    } else if (value.kind === 'ssh_jump') {
      const hop = defaultSshProxyHop(0);
      hop.hopId = 'legacy-hop-1';
      hop.host = host.proxyHost;
      hop.portText = host.proxyPort.toString();
      hop.username = host.proxyUsername;
      hop.authMethod = host.sshProxyAuthMethod;
      hop.keyId = host.sshProxyAuthMethod === 'publickey' ? host.sshProxyKeyId : '';
      hop.expectedHostKeyFingerprintSha256 = host.sshJumpHostKeyFingerprintSha256;
      value.hops = [hop];
    }
    return value;
  }

  // 编辑主机 (锁定状态需先鉴权)
  private async editHost(host: RemoteHost): Promise<void> {
    const vncHostId: string = this.vncRecordIdForHost(host);
    if (vncHostId !== '') {
      const latestVnc: VncHostView | null = this.vncHosts.find(vncHostId);
      if (latestVnc === null) {
        promptAction.showToast({ message: 'VNC 主机记录不存在或已删除', duration: 2000 });
        return;
      }
      if (latestVnc.locked) {
        const gate = await showLockGate(latestVnc.label, 'biometric');
        if (!gate.ok) {
          const msg: string = lockGateErrorMessage(gate);
          if (msg !== '') { promptAction.showToast({ message: msg, duration: 2000 }); }
          return;
        }
      }
      this.prepareClassicVncEditor(latestVnc);
      this.addSheetShowsModernPicker = false;
      this.modernAddProtocol = '';
      this.vncAddFromModernPicker = false;
      this.openSheetSafely((): void => { this.showAddSheet = true; });
      return;
    }
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
    const proPlatformKnown: boolean = latestHost.rustdeskProManaged &&
      latestHost.sourceType === 'rustdesk_pro' && latestHost.rustdeskProPlatform.trim() !== '';
    this.sheetRustdeskTargetDevice = proPlatformKnown ?
      (isRustDeskMobilePlatform(latestHost.rustdeskProPlatform) ? 'phone' : 'computer') :
      normalizeRustDeskTargetDevice(latestHost.rustdeskTargetDevice);
    this.sheetRustdeskAdaptiveOrientation = canUseRustDeskAdaptiveOrientation(
      latestHost.protocol, this.sheetRustdeskTargetDevice, latestHost.rustdeskAdaptiveOrientation,
      latestHost.sourceType, latestHost.rustdeskProManaged, latestHost.rustdeskProPlatform);
    this.sheetRustdeskTotpEntryId = latestHost.rustdeskTotpEntryId;
    this.sheetRustdeskTotpAutoSubmit = latestHost.rustdeskTotpAutoSubmit;
    this.sheetUseKey = latestHost.sshUseKey;
    this.sheetKeyPath = latestHost.sshKeyPath;
    this.sheetKeyText = latestHost.sshKeyData;
    this.sheetKeyId = latestHost.sshKeyId;
    this.sheetKeyPassphrase = latestHost.sshKeyPassphrase;
    this.sheetKeyMode = latestHost.sshKeyId !== '' ? 1 : 0;
    this.sheetSshProxyEditorValue = latestHost.protocol === 'ssh'
      ? this.sshProxyEditorValueForHost(latestHost) : defaultSshProxyEditorValue();
    if (latestHost.protocol === 'ssh' && latestHost.proxyHost.trim().length > 0 &&
      latestHost.sshProxyType !== 'http_connect' && latestHost.sshProxyType !== 'socks5' &&
      latestHost.sshProxyType !== 'ssh_jump' && latestHost.sshProxyType !== 'frp_tcp') {
      this.sheetErr = '旧 FRP 控制面模式不能直接迁移，请重新选择外部 FRP TCP 入口';
    }
    this.openSheetSafely((): void => { this.showAddSheet = true; });
  }

  private prepareClassicVncEditor(host: VncHostView | null): void {
    const defaults = this.vncSettings.get();
    this.editingHostId = host === null ? '' : vncHostUiId(host.id);
    this.label = host === null ? '' : host.label;
    this.proto = 'vnc';
    this.hostAddr = host === null ? '' : host.host;
    this.portVal = host === null ? defaults.defaultPort : host.port;
    this.username = '';
    // Never materialize a VNC password into the classic editor.
    this.sheetPwd = '';
    this.chn = '';
    this.sheetErr = '';
    this.vncHostTransport = host === null ? defaults.defaultTransport : host.transport;
    this.vncHostRepeaterMode = host === null ? defaults.repeaterMode : host.repeaterMode;
    this.vncHostGatewayId = host === null ? defaults.defaultGatewayId : host.gatewayId;
    this.vncHostPasswordConfigured = host === null ? false : host.passwordConfigured;
    this.vncHostRememberPassword = host === null ? false : host.rememberPassword;
    this.vncHostViewOnly = host === null ? defaults.viewOnly : host.viewOnly;
    this.vncHostDisplayOverrideEnabled = host === null ? false : host.displayOverrideEnabled;
    this.vncHostScalingMode = host === null ? defaults.scalingMode : host.scalingMode;
    this.vncHostClipboardEnabled = host === null ? defaults.clipboardEnabled : host.clipboardEnabled;
    this.vncHostSecurityPolicy = host === null ? defaults.securityPolicy : host.securityPolicy;
    this.vncHostTls = host === null ? defaults.securityPolicy === 'secure_only' : host.tls;
  }

  private isEditingProHost(): boolean {
    if (this.editingHostId === '') { return false; }
    const host = this.srv.getHost(this.editingHostId);
    return host !== undefined && host.rustdeskProManaged && host.sourceType === 'rustdesk_pro';
  }

  private rustDeskEditorTargetLocked(): boolean {
    if (!this.isEditingProHost()) { return false; }
    const host: RemoteHost | undefined = this.srv.getHost(this.editingHostId);
    return host !== undefined && host.rustdeskProPlatform.trim() !== '';
  }

  private effectiveSheetRustDeskTargetDevice(): RustDeskTargetDevice {
    if (this.rustDeskEditorTargetLocked()) {
      const host: RemoteHost | undefined = this.srv.getHost(this.editingHostId);
      return host !== undefined && isRustDeskMobilePlatform(host.rustdeskProPlatform) ? 'phone' : 'computer';
    }
    return normalizeRustDeskTargetDevice(this.sheetRustdeskTargetDevice);
  }

  private rustDeskEditorPlatformLabel(): string {
    const host: RemoteHost | undefined = this.srv.getHost(this.editingHostId);
    return host === undefined ? '未知' : this.hostPlatformText(host);
  }

  @Builder rustDeskTargetDeviceSection() {
    Text('控制目标').fontSize(11).fontColor(this.pal().text2).fontFamily(this.font()).margin({ bottom: 4 })
    if (this.rustDeskEditorTargetLocked()) {
      Row() {
        Text('Pro 设备平台').fontSize(13).fontColor(this.pal().text).fontFamily(this.font()).layoutWeight(1)
        Text(this.rustDeskEditorPlatformLabel())
          .fontSize(12).fontColor(this.pal().text3).fontFamily(this.font())
      }.width('100%').padding({ top: 8, bottom: 8 })
    } else {
      Row() {
        Button('控制电脑').layoutWeight(1).height(34).fontSize(11).borderRadius(8)
          .backgroundColor(this.effectiveSheetRustDeskTargetDevice() === 'computer' ?
            this.accentColor : this.pal().surface)
          .fontColor(this.effectiveSheetRustDeskTargetDevice() === 'computer' ? Color.White : this.pal().text2)
          .onClick((): void => {
            this.sheetRustdeskTargetDevice = 'computer';
            this.sheetRustdeskAdaptiveOrientation = false;
          })
        Button('控制手机').layoutWeight(1).height(34).fontSize(11).borderRadius(8).margin({ left: 6 })
          .backgroundColor(this.effectiveSheetRustDeskTargetDevice() === 'phone' ?
            this.accentColor : this.pal().surface)
          .fontColor(this.effectiveSheetRustDeskTargetDevice() === 'phone' ? Color.White : this.pal().text2)
          .onClick((): void => { this.sheetRustdeskTargetDevice = 'phone'; })
      }.width('100%').margin({ bottom: 6 })
    }
    Row() {
      Column() {
        Text('自适应翻转').fontSize(13).fontColor(this.pal().text).fontFamily(this.font())
        Text(this.effectiveSheetRustDeskTargetDevice() === 'phone' ?
          '根据手机方向切换本机窗口，默认关闭' : '仅控制手机时可用')
          .fontSize(10).fontColor(this.pal().text3).fontFamily(this.font()).margin({ top: 2 })
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      Toggle({ type: ToggleType.Switch, isOn: this.sheetRustdeskAdaptiveOrientation })
        .selectedColor(this.accentColor).scale({ x: 0.82, y: 0.82 })
        .enabled(this.effectiveSheetRustDeskTargetDevice() === 'phone')
        .onChange((on: boolean): void => {
          this.sheetRustdeskAdaptiveOrientation =
            this.effectiveSheetRustDeskTargetDevice() === 'phone' && on;
        })
    }.width('100%').margin({ bottom: 8 })
  }

  private hostPlatformText(host: RemoteHost): string {
    if (host.rustdeskProManaged && host.rustdeskProPlatform.trim() !== '') {
      return host.rustdeskProPlatform.trim();
    }
    return host.protocol.toUpperCase();
  }

  // 直接删除主机 (滑动触发)
  private deleteHost(host: RemoteHost): void {
    const vncHostId: string = this.vncRecordIdForHost(host);
    let removed: boolean = false;
    if (vncHostId !== '') {
      removed = this.vncHosts.remove(vncHostId);
    } else {
      removed = this.srv.removeHost(host.id);
    }
    if (removed) {
      const key: string = remoteHostCardKey(host.id);
      this.hostManualOrder = this.hostManualOrder.filter(
        (stored: string): boolean => stored !== key && stored !== host.id);
      this.persistHostManualOrder();
      this.refreshHostSnapshotAfterMutation();
    } else {
      promptAction.showToast({
        message: this.mutationFailureMessage('删除主机失败，请稍后重试'), duration: 2400
      });
    }
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
        const vncHostId: string = this.vncRecordIdForHost(host);
        const removed: boolean = vncHostId !== ''
          ? this.vncHosts.remove(vncHostId)
          : this.srv.removeHost(host.id);
        if (removed) {
          const key: string = remoteHostCardKey(host.id);
          this.hostManualOrder = this.hostManualOrder.filter(
            (stored: string): boolean => stored !== key && stored !== host.id);
          this.persistHostManualOrder();
          this.refreshHostSnapshotAfterMutation();
        } else {
          promptAction.showToast({
            message: this.mutationFailureMessage('删除主机失败，请稍后重试'), duration: 2400
          });
        }
      }
    });
  }

  private async doLogout(): Promise<void> {
    // The coordinator drains sessions, clears plaintext caches and switches to
    // the device-local physical store before this page leaves the account UI.
    const transition: AccountTransitionResult =
      await AccountSessionCoordinator.getInstance().transitionToOffline('logout');
    if (!transition.ok) {
      promptAction.showToast({
        message: transition.message === '' ? '退出账号未完成，当前账号保持不变' : transition.message,
        duration: 3000
      });
      return;
    }
    // 清除 HMS Core 系统级授权 session
    try {
      const cancelReq: authentication.CancelAuthorizationRequest =
        new authentication.HuaweiIDProvider().createCancelAuthorizationRequest();
      const cancelCtrl: authentication.AuthenticationController =
        new authentication.AuthenticationController(getContext(this));
      await cancelCtrl.executeRequest(cancelReq);
    } catch (_e) { /* 无缓存时可能抛异常, 忽略 */ }
    // 跳转登录页
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
      const unionId: string = (credential.unionID ?? '').trim();
      if (unionId.length === 0) {
        promptAction.showToast({ message: '登录失败：账号没有返回稳定标识', duration: 2500 });
        return;
      }
      const transition: AccountTransitionResult =
        await AccountSessionCoordinator.getInstance().transitionToAccount({
          unionID: unionId,
          openID: credential.openID ?? '',
          authorizationCode: credential.authorizationCode ?? '',
          idToken: '',
          displayName: nickName || '华为用户',
          avatarUrl: avatarUri
        });
      if (!transition.ok) {
        promptAction.showToast({
          message: transition.message === '' ? '登录失败：账号数据域切换未完成' : transition.message,
          duration: 2500
        });
        return;
      }
      // 刷新 UI 状态
      this.accountDisplayName = nickName || '华为用户';
      this.accountAvatarUrl = avatarUri;
      this.loginRefreshKey++;
      this.applyCloudUserSettings();
      this.refreshMoonlightDirectory();
      this.scheduleHostListLoad(false);
      promptAction.showToast({ message: '登录成功', duration: 1500 });
    } catch (_err) {
      // 用户取消或登录失败, 静默
    }
  }

  private saveTotpLock(locked: boolean): void {
    if (this.persistPreferenceValue('totpLocked', locked)) { return; }
    this.totpPageLocked = !locked;
    promptAction.showToast({ message: '2FA 隐私保护设置保存失败，已恢复原状态', duration: 2600 });
  }

  private persistPreferenceValue(key: string,
    value: string | number | boolean): boolean {
    try {
      const prefs = preferences.getPreferencesSync(
        getContext(this), { name: 'RemoteDesktopAppPrefs' });
      prefs.putSync(key, value);
      prefs.flushSync();
      return true;
    } catch (_error) {
      return false;
    }
  }

  private reportPreferencePersistence(localSaved: boolean,
    cloudSaved: boolean = true): void {
    if (localSaved && cloudSaved) { return; }
    promptAction.showToast({
      message: localSaved ?
        '设置已保存在本机，但云同步失败，请稍后重试' :
        '设置未能写入本机，当前仅在本次运行中生效',
      duration: 2600
    });
  }

  private persistRustDeskNumberPref(key: string, value: number): void {
    AppStorage.setOrCreate(key, value);
    const localSaved: boolean = this.persistPreferenceValue(key, value);
    const cloudSaved: boolean = !cloudUserSettingIsSyncable(key) ||
      CloudStore.getInstance().upsertUserSetting(key, value);
    this.reportPreferencePersistence(localSaved, cloudSaved);
  }

  private persistRustDeskBooleanPref(key: string, value: boolean): void {
    AppStorage.setOrCreate(key, value);
    const localSaved: boolean = this.persistPreferenceValue(key, value);
    const cloudSaved: boolean = !cloudUserSettingIsSyncable(key) ||
      CloudStore.getInstance().upsertUserSetting(key, value);
    this.reportPreferencePersistence(localSaved, cloudSaved);
  }

  /** RustDesk diagnostics are device-local UI preferences; never cloud-sync them. */
  private persistLocalRustDeskBooleanPref(key: string, value: boolean): void {
    this.persistLocalBooleanPref(key, value);
  }

  /** Device-local preference; layout choices do not enter cloud host settings. */
  private persistLocalBooleanPref(key: string, value: boolean): void {
    AppStorage.setOrCreate(key, value);
    this.reportPreferencePersistence(this.persistPreferenceValue(key, value));
  }

  /** 通用设置持久化 — 同时写 AppStorage + Preferences, 杀后台不丢失 */
  private persistPref(key: string, value: string | number | boolean): void {
    AppStorage.setOrCreate(key, value);
    const localSaved: boolean = this.persistPreferenceValue(key, value);
    const cloudSaved: boolean = !cloudUserSettingIsSyncable(key) ||
      CloudStore.getInstance().upsertUserSetting(key, value);
    this.reportPreferencePersistence(localSaved, cloudSaved);
  }

  /** 初始云端恢复完成后覆盖本地的可同步偏好；账号/锁定状态不会进入此路径。 */
  private applyCloudUserSettings(): void {
    const settings = CloudStore.getInstance().loadUserSettings();
    const keys: string[] = Object.keys(settings);
    if (keys.length === 0) { return; }
    try {
      const prefs = preferences.getPreferencesSync(getContext(this), { name: 'RemoteDesktopAppPrefs' });
      this.sshSettings.applyCloudSettings(settings);
      for (let i = 0; i < keys.length; i++) {
        const key: string = keys[i];
        if (!cloudUserSettingIsSyncable(key)) { continue; }
        if (key === 'sshTerminalForegroundColor' || key === 'sshTerminalFontSize' ||
          key === 'sshTerminalLineSpacing' || key === 'terminalFgColor' ||
          key === 'terminalFontSize' || key === 'terminalLineSpacing' ||
          key === 'groupedHostCards') { continue; }
        const value = settings[key];
        prefs.putSync(key, value);
        AppStorage.setOrCreate(key, value);
      }
      prefs.flushSync();
    } catch (_e) { return; }
    const accent = settings['accentColor'];
    if (typeof accent === 'string') { this.accentColor = accent; }
    const syncedTheme = settings['currentTheme'];
    if (typeof syncedTheme === 'string' && (syncedTheme === 'light' || syncedTheme === 'dark')) {
      this.theme = syncedTheme;
      this.refreshHaloPresets();
      this.syncHaloColorForCurrentTheme();
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
    let failed: number = 0;
    for (let i: number = 0; i < hosts.length; i++) {
      const host: RemoteHost = hosts[i];
      if (!shouldAdoptRustDeskDirectPort(host.rustdeskDirectEnabled,
        host.rustdeskDirectPort, previousPort)) { continue; }
      const next: RemoteHost = RemoteHost.fromJSON(host.toJSON());
      next.rustdeskDirectPort = this.rustdeskDirectPort;
      next.port = this.rustdeskDirectPort;
      if (!this.srv.updateHost(next)) { failed++; }
    }
    if (failed > 0) {
      promptAction.showToast({
        message: failed.toString() + ' 个 RustDesk 主机的直连端口保存失败，请逐项检查',
        duration: 2800
      });
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

  private saveTotpLogoMode(mode: string): void {
    this.totpLogoMode = mode === 'initials' ? 'initials' : 'logo';
    this.persistPref('totpLogoMode', this.totpLogoMode);
  }

  private saveGroupedHostCards(on: boolean): void {
    this.groupedHostCards = on;
    this.expandedHostGroup = '';
    if (this.groupedHostCardsActive()) {
      this.workspaceGroupId = '';
      this.activeFilterProto = '';
    }
    AppStorage.setOrCreate('groupedHostCards', this.groupedHostCards);
    this.persistLocalBooleanPref('groupedHostCards', this.groupedHostCards);
    this.updateHostFilter();
  }

  private saveHostCardSensitiveInfoHidden(on: boolean): void {
    this.hostCardSensitiveInfoHidden = on;
    this.persistLocalBooleanPref(HOST_CARD_SENSITIVE_INFO_HIDDEN_KEY, on);
    // LazyForEach keys include this revision so every visible card immediately
    // drops or restores its connection summary without reloading host data.
    this.hostViewRevision += 1;
  }

  private sessionControlBarVisibility(): RemoteSessionControlBarVisibility {
    return {
      rdpHidden: this.sessionControlBarHiddenRdp,
      rustDeskHidden: this.sessionControlBarHiddenRustDesk,
      vncHidden: this.sessionControlBarHiddenVnc,
      moonlightHidden: this.sessionControlBarHiddenMoonlight
    };
  }

  private sessionControlBarHidden(protocol: string): boolean {
    return remoteSessionControlBarHidden(protocol, this.sessionControlBarVisibility());
  }

  private sessionControlBarProtocolLabel(protocol: string): string {
    if (protocol === 'rdp') { return 'RDP'; }
    if (protocol === 'rustdesk') { return 'RustDesk'; }
    if (protocol === 'vnc') { return 'VNC'; }
    return 'Moonlight';
  }

  private setSessionControlBarHidden(protocol: string, hidden: boolean): void {
    if (protocol === 'rdp') {
      this.sessionControlBarHiddenRdp = hidden;
      this.persistLocalBooleanPref(REMOTE_SESSION_CONTROL_BAR_HIDDEN_RDP_KEY, hidden);
    } else if (protocol === 'rustdesk') {
      this.sessionControlBarHiddenRustDesk = hidden;
      this.persistLocalBooleanPref(REMOTE_SESSION_CONTROL_BAR_HIDDEN_RUSTDESK_KEY, hidden);
    } else if (protocol === 'vnc') {
      this.sessionControlBarHiddenVnc = hidden;
      this.persistLocalBooleanPref(REMOTE_SESSION_CONTROL_BAR_HIDDEN_VNC_KEY, hidden);
    } else if (protocol === 'moonlight') {
      this.sessionControlBarHiddenMoonlight = hidden;
      this.persistLocalBooleanPref(REMOTE_SESSION_CONTROL_BAR_HIDDEN_MOONLIGHT_KEY, hidden);
    }
  }

  private saveSessionControlBarHidden(protocol: string, on: boolean): void {
    const label: string = this.sessionControlBarProtocolLabel(protocol);
    this.setSessionControlBarHidden(protocol, on);
    promptAction.showToast({
      message: label + (on ? ' 会话控制栏已隐藏' : ' 会话控制栏已恢复'),
      duration: 1400
    });
  }

  private saveRustDeskPresenceDetection(on: boolean): void {
    this.rustdeskPresenceDetectionEnabled = on;
    this.persistLocalBooleanPref('rustdeskPresenceDetectionEnabled', on);
    // Invalidate an in-flight probe and remove page-local results. Turning the
    // feature back on starts a fresh sweep against the current host snapshot.
    this.hostPresencePageGeneration += 1;
    this.hostPresenceOverrides.clear();
    this.hostPresenceProbeGenerations.clear();
    this.hostPresenceProbeBusyIds = new Set<string>();
    this.hostViewRevision += 1;
    if (on && this.pageActive) { void this.refreshRustDeskPresence(); }
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

  private startRdpLanScan(port: number): void {
    if (this.rdpLanScanning) { return; }
    this.rdpLanScanResults = [];
    this.rdpLanStatusText = '正在检查当前局域网和 RDP 端口…';
    this.rdpLanScanning = true;
    void this.rdpLanDiscovery.startScan(port,
      async (address: string, candidatePort: number): Promise<RdpLanIdentityProbeResult> => {
        const info: RdpCertificateInfo = await this.loader.probeRdpCertificateAsync(
          address, candidatePort, address);
        return {
          recognized: rdpLanProbeRecognized(info.preflightStatus, info.errorCode),
          fingerprintSha256: info.fingerprintSha256,
          commonName: info.commonName
        };
      }, (host: DiscoveredRdpHost): void => {
        this.rdpLanScanResults = this.rdpLanScanResults.concat([host]);
      }).then((hosts: DiscoveredRdpHost[]): void => {
        this.rdpLanScanResults = hosts;
        this.rdpLanScanning = false;
        this.rdpLanStatusText = this.rdpLanScanStatusMessage(
          this.rdpLanDiscovery.getLastScanStatus(), hosts.length);
      }).catch((_err: Error): void => {
        this.rdpLanScanning = false;
        this.rdpLanStatusText = '搜索失败，请检查网络权限后重试';
      });
  }

  private rdpLanScanStatusMessage(status: RdpLanScanStatus, count: number): string {
    if (status === 'completed') { return '已发现 ' + count.toString() + ' 台可用 RDP 主机'; }
    if (status === 'no_private_network') { return '当前网络没有可扫描的私有 IPv4 地址'; }
    if (status === 'network_error') { return '无法读取当前网络信息，请检查网络权限'; }
    if (status === 'no_open_port') { return '当前子网未发现开放此端口的主机'; }
    if (status === 'preflight_rejected') { return '发现开放端口，但未通过 RDP 证书预检'; }
    if (status === 'invalid_port') { return '扫描端口无效，请填写 1-65535'; }
    return status === 'cancelled' ? '搜索已取消' : '';
  }

  private async refreshDynamicLanHosts(force: boolean = false, targetHostId: string = ''): Promise<void> {
    if (!this.srv.isReady()) { return; }
    if (this.dynamicLanRefreshPromise !== null) {
      await this.dynamicLanRefreshPromise;
      // A background sweep may have excluded this still-fresh target before
      // the user pressed Connect. Re-run the explicit target after the active
      // work completes so connection never silently proceeds on that basis.
      if (force && targetHostId !== '' && this.srv.isReady()) {
        await this.refreshDynamicLanHosts(true, targetHostId);
      }
      return;
    }
    const now: number = Date.now();
    if (targetHostId === '' && !force &&
      now - this.dynamicLanLastSweepAt < DYNAMIC_LAN_SWEEP_COOLDOWN_MS) {
      return;
    }
    const task: Promise<void> = this.performDynamicLanRefresh(force, targetHostId);
    this.dynamicLanRefreshPromise = task;
    try {
      await task;
    } finally {
      if (this.dynamicLanRefreshPromise === task) { this.dynamicLanRefreshPromise = null; }
    }
  }

  private async performDynamicLanRefresh(force: boolean, targetHostId: string): Promise<void> {
    const scope = CloudStore.getInstance().currentScope();
    const now: number = Date.now();
    const targets: RemoteHost[] = this.srv.getAllHosts().filter((host: RemoteHost): boolean => {
      if (!lanHostUsesLocalOnlyStorage(host)) { return false; }
      if (targetHostId !== '' && host.id !== targetHostId) { return false; }
      return force || lanHostNeedsAddressRefresh(
        host, now, DYNAMIC_LAN_ADDRESS_FRESHNESS_MS);
    });
    if (targets.length === 0) {
      if (targetHostId === '') { this.dynamicLanLastSweepAt = now; }
      return;
    }

    const rustDeskTargets: RemoteHost[] = targets.filter((host: RemoteHost): boolean =>
      host.protocol === 'rustdesk');
    if (rustDeskTargets.length > 0) {
      const peers: DiscoveredRustDeskPeer[] =
        await this.dynamicRustDeskDiscovery.startScan(3000);
      for (let i = 0; i < peers.length; i++) {
        const peer: DiscoveredRustDeskPeer = peers[i];
        const candidate: LanHostRefreshCandidate = {
          protocol: 'rustdesk', identity: peer.peerId,
          host: peer.host, port: peer.port, observedAt: Date.now()
        };
        this.applyDynamicLanCandidate(rustDeskTargets, candidate, scope.ownerScopeId,
          scope.storeIdentity, scope.generation);
      }
    }

    const rdpPorts: number[] = [];
    for (let i = 0; i < targets.length; i++) {
      if (targets[i].protocol === 'rdp' && rdpPorts.indexOf(targets[i].port) < 0) {
        rdpPorts.push(targets[i].port);
      }
    }
    for (let i = 0; i < rdpPorts.length; i++) {
      const port: number = rdpPorts[i];
      const rdpTargets: RemoteHost[] = targets.filter((host: RemoteHost): boolean =>
        host.protocol === 'rdp' && host.port === port);
      const found: DiscoveredRdpHost[] = await this.dynamicRdpDiscovery.startScan(port,
        async (address: string, candidatePort: number): Promise<RdpLanIdentityProbeResult> => {
          const info: RdpCertificateInfo = await this.loader.probeRdpCertificateAsync(
            address, candidatePort, address);
          return {
            recognized: rdpLanProbeRecognized(info.preflightStatus, info.errorCode),
            fingerprintSha256: info.fingerprintSha256,
            commonName: info.commonName
          };
        });
      for (let j = 0; j < found.length; j++) {
        if (!found[j].dynamicCapable) { continue; }
        const candidate: LanHostRefreshCandidate = {
          protocol: 'rdp', identity: found[j].fingerprintSha256,
          host: found[j].host, port: found[j].port, observedAt: Date.now()
        };
        this.applyDynamicLanCandidate(rdpTargets, candidate, scope.ownerScopeId,
          scope.storeIdentity, scope.generation);
      }
    }
    if (targetHostId === '') { this.dynamicLanLastSweepAt = Date.now(); }
  }

  private applyDynamicLanCandidate(targets: RemoteHost[], candidate: LanHostRefreshCandidate,
    ownerScopeId: string, storeIdentity: string, generation: number): void {
    const currentScope = CloudStore.getInstance().currentScope();
    if (currentScope.ownerScopeId !== ownerScopeId || currentScope.storeIdentity !== storeIdentity ||
      currentScope.generation !== generation) {
      return;
    }
    for (let i = 0; i < targets.length; i++) {
      if (!lanHostRefreshCandidateMatches(targets[i], candidate)) { continue; }
      const latest: RemoteHost | undefined = this.srv.getHost(targets[i].id);
      if (latest === undefined || !lanHostRefreshCandidateMatches(latest, candidate)) { continue; }
      const next: RemoteHost = RemoteHost.fromJSON(latest.toJSON());
      next.host = candidate.host;
      next.port = candidate.port;
      next.lanLastResolvedAt = candidate.observedAt;
      if (next.protocol === 'rustdesk') {
        next.rustdeskDirectHost = candidate.host;
        next.rustdeskDirectPort = candidate.port;
      } else if (next.protocol === 'rdp' &&
        next.rdpCertificateFingerprintSha256.trim().toLowerCase() ===
          candidate.identity.trim().toLowerCase()) {
        // Exact fingerprint discovery is the authority for this DHCP move;
        // retain the prior explicit certificate decision for the new route.
        next.rdpCertificateRouteIdentity = rdpRouteIdentity(next);
      }
      if (this.srv.updateDynamicLanAddress(next)) {
        hilog.info(0x0001, 'HostList',
          'dynamic LAN address refreshed hostId=' + hashForLog(next.id));
      }
    }
  }

  private addLanPeer(peer: DiscoveredRustDeskPeer): void {
    // Settings LAN discovery shares the same next-step strategy chooser as
    // the modern add flow; it must not bypass static/dynamic selection.
    const draft = new RustDeskHostAddDraft();
    draft.step = 2;
    draft.direct = true;
    draft.useLan = true;
    draft.selectedLanPeerId = peer.peerId;
    draft.lanAddressMode = '';
    draft.label = peer.deviceName;
    draft.controlId = peer.peerId;
    draft.directHost = peer.host;
    draft.directPortText = peer.port.toString();
    draft.passwordMode = 1;
    this.rustDeskAddResumeDraft = draft;
    this.rustDeskAddResumeRevision += 1;
    this.modernAddProtocol = 'rustdesk';
    this.addSheetShowsModernPicker = false;
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

  private saveSshInputMode(mode: number): void {
    this.sshInputMode = this.clampSshInputMode(mode);
    this.persistPref('sshInputMode', this.sshInputMode);
  }

  private saveSshWorkbenchEnabled(enabled: boolean): void {
    this.sshWorkbenchEnabled = enabled;
    this.sshWorkspaceCapabilityStore.save(getContext(this) as common.Context, enabled);
  }

  private refreshSshNotificationAuthorization(): void {
    void this.sshNotificationService.isEnabled().then((enabled: boolean): void => {
      if (!this.pageActive) { return; }
      this.sshSystemNotificationsEnabled = enabled;
    });
  }

  private requestSshNotificationAuthorization(): void {
    if (this.sshSystemNotificationsEnabled || this.sshNotificationAuthorizationPending) { return; }
    this.sshNotificationAuthorizationPending = true;
    void this.requestSshNotificationAuthorizationForeground();
  }

  private async requestSshNotificationAuthorizationForeground(): Promise<void> {
    let enabled: boolean = false;
    try {
      const context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
      enabled = await this.sshNotificationService.ensureEnabled(context);
    } catch (_err) {
      enabled = false;
    }
    this.sshNotificationAuthorizationPending = false;
    if (!this.pageActive) { return; }
    this.sshSystemNotificationsEnabled = enabled;
    promptAction.showToast({
      message: enabled ? 'SSH 系统通知已开启' : '系统通知未开启，SSH 提醒保持关闭',
      duration: enabled ? 1500 : 2200
    });
  }

  private saveSshLineSpacing(value: number): void {
    this.terminalLineSpacing = this.sshSettings.saveLineSpacing(value);
  }

  private clampSshInputMode(mode: number): number {
    return mode >= 0 && mode <= 2 ? Math.floor(mode) : 0;
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
    return sources.indexOf('keyboard') >= 0 || sources.indexOf('mouse') >= 0;
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
    this.persistPref('canvasGestureZoomUserConfigured', true);
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

  private saveRdpShowDiagnostics(on: boolean): void {
    this.rdpShowDiagnostics = on;
    this.persistPref('rdpShowDiagnostics', this.rdpShowDiagnostics);
  }

  private saveRdpTlsWithoutNla(on: boolean): void {
    if (!on) {
      this.rdpTlsWithoutNla = false;
      this.persistPref('rdpTlsWithoutNla', false);
      return;
    }
    promptAction.showDialog({
      title: '启用 TLS 兼容登录？',
      message: '仅当被控 Windows 已取消“需要使用网络级别身份验证”时使用。此模式仍验证 TLS 证书，但登录保护弱于 NLA，并且只支持直连和普通密码。',
      buttons: [
        { text: '取消', color: this.pal().text2 },
        { text: '仍然启用', color: this.accentColor }
      ]
    }).then((result: Object): void => {
      const value: Record<string, number> = result as Record<string, number>;
      if (value['index'] !== 1) { return; }
      this.rdpTlsWithoutNla = true;
      this.persistPref('rdpTlsWithoutNla', true);
    }).catch((_err: Error): void => { });
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

  @Builder
  remoteHostSheetBuilder() {
    if (this.remoteHostSheetMode === REMOTE_HOST_SHEET_SSH_PREFLIGHT) {
      this.sshPreflightPanel();
    } else if (this.remoteHostSheetMode === REMOTE_HOST_SHEET_RDP_CERTIFICATE) {
      this.rdpCertificatePanel();
    } else if (this.remoteHostSheetMode === REMOTE_HOST_SHEET_VNC_CERTIFICATE) {
      this.vncCertificatePanel();
    } else if (this.remoteHostSheetMode === REMOTE_HOST_SHEET_VNC_CREDENTIAL) {
      this.vncCredentialPanel();
    } else if (this.remoteHostSheetMode === REMOTE_HOST_SHEET_RUSTDESK_PREFLIGHT) {
      this.rustDeskProPreflightPanel();
    } else if (this.remoteHostSheetMode === REMOTE_HOST_SHEET_RUSTDESK_TOTP_BINDING) {
      this.rustDeskTotpBindingPanel();
    } else if (this.remoteHostSheetMode === REMOTE_HOST_SHEET_PASSPHRASE) {
      this.hlPassphraseBuilder();
    } else if (this.remoteHostSheetMode === REMOTE_HOST_SHEET_PUBLIC_KEY) {
      this.sshPublicKeyInstallPanel();
    } else if (this.remoteHostSheetMode === REMOTE_HOST_SHEET_MOONLIGHT_DETAIL) {
      this.moonlightHostDetailSheet();
    } else if (this.remoteHostSheetMode === REMOTE_HOST_SHEET_MOONLIGHT_CATALOG) {
      this.moonlightCatalogSheet();
    } else if (this.remoteHostSheetMode === REMOTE_HOST_SHEET_MOONLIGHT_EDIT) {
      this.moonlightEditSheet();
    }
  }

  private handleRemoteHostSheetWillDismiss(action: DismissSheetAction): void {
    if (this.remoteHostSheetMode === REMOTE_HOST_SHEET_MOONLIGHT_CATALOG &&
        !this.moonlightCatalogDismissAllowed) {
      promptAction.showToast({ message: '正在处理 Moonlight 请求，请稍候', duration: 1500 });
      return;
    }
    switch (this.remoteHostSheetMode) {
      case REMOTE_HOST_SHEET_SSH_PREFLIGHT:
        this.doSshPreflightCancel(false);
        break;
      case REMOTE_HOST_SHEET_RDP_CERTIFICATE:
        this.doRdpCertificateCancel(false);
        break;
      case REMOTE_HOST_SHEET_VNC_CERTIFICATE:
        this.cancelVncCertificatePreflight(false);
        break;
      case REMOTE_HOST_SHEET_VNC_CREDENTIAL:
        this.cancelVncCredentialPreflight(false);
        break;
      case REMOTE_HOST_SHEET_RUSTDESK_PREFLIGHT:
        if (!this.rustDeskProPreflightClosing) {
          this.cancelRustDeskProPreflight(false, true);
        }
        break;
      case REMOTE_HOST_SHEET_PASSPHRASE:
        this.beginRemoteHostSheetClose(REMOTE_HOST_SHEET_PASSPHRASE);
        break;
      case REMOTE_HOST_SHEET_PUBLIC_KEY:
        this.beginRemoteHostSheetClose(REMOTE_HOST_SHEET_PUBLIC_KEY);
        break;
      case REMOTE_HOST_SHEET_RUSTDESK_TOTP_BINDING:
        this.closeRustDeskTotpBinding(false);
        break;
      case REMOTE_HOST_SHEET_MOONLIGHT_DETAIL:
        this.beginRemoteHostSheetClose(REMOTE_HOST_SHEET_MOONLIGHT_DETAIL);
        break;
      case REMOTE_HOST_SHEET_MOONLIGHT_CATALOG:
        this.beginRemoteHostSheetClose(REMOTE_HOST_SHEET_MOONLIGHT_CATALOG);
        break;
      case REMOTE_HOST_SHEET_MOONLIGHT_EDIT:
        this.beginRemoteHostSheetClose(REMOTE_HOST_SHEET_MOONLIGHT_EDIT);
        break;
      default:
        return;
    }
    // Registering onWillDismiss normally makes ArkUI spring the Sheet back
    // before dismissing it. onWillSpringBackWhenDismiss below suppresses that
    // default bounce, so this remains a single native exit animation while the
    // cancellation generation is advanced before any async success can route.
    action.dismiss();
  }

  private handleRemoteHostSheetDisappear(): void {
    const mode: number = this.remoteHostSheetClosingMode !== REMOTE_HOST_SHEET_NONE
      ? this.remoteHostSheetClosingMode : this.remoteHostSheetMode;
    // onWillDismiss normally cancels before the native exit starts. Keep this
    // fallback for lifecycle-driven closes that reach onDisappear without the
    // interactive callback; the generation must still be invalidated before
    // cleanup and routing decisions are drained.
    if (!this.remoteHostSheetClosing) {
      if (mode === REMOTE_HOST_SHEET_SSH_PREFLIGHT) {
        this.doSshPreflightCancel(false);
      } else if (mode === REMOTE_HOST_SHEET_RDP_CERTIFICATE) {
        this.doRdpCertificateCancel(false);
      } else if (mode === REMOTE_HOST_SHEET_VNC_CERTIFICATE) {
        this.cancelVncCertificatePreflight(false);
      } else if (mode === REMOTE_HOST_SHEET_VNC_CREDENTIAL) {
        this.cancelVncCredentialPreflight(false);
      } else if (mode === REMOTE_HOST_SHEET_RUSTDESK_PREFLIGHT) {
        this.cancelRustDeskProPreflight(false, true);
      } else if (mode === REMOTE_HOST_SHEET_RUSTDESK_TOTP_BINDING) {
        this.closeRustDeskTotpBinding(false);
      }
    }
    switch (mode) {
      case REMOTE_HOST_SHEET_SSH_PREFLIGHT:
        this.handleSshPreflightSheetDisappear();
        break;
      case REMOTE_HOST_SHEET_RDP_CERTIFICATE:
        this.handleRdpCertificateSheetDisappear();
        break;
      case REMOTE_HOST_SHEET_VNC_CERTIFICATE:
        this.handleVncCertificatePreflightDisappear();
        break;
      case REMOTE_HOST_SHEET_VNC_CREDENTIAL:
        this.handleVncCredentialPreflightDisappear();
        break;
      case REMOTE_HOST_SHEET_RUSTDESK_PREFLIGHT:
        this.handleRustDeskProPreflightDisappear();
        break;
      case REMOTE_HOST_SHEET_RUSTDESK_TOTP_BINDING:
        this.handleRustDeskTotpBindingSheetDisappear();
        break;
      case REMOTE_HOST_SHEET_PASSPHRASE:
        this.finishHostPassphrasePrompt('');
        this.showPassphraseSheet = false;
        this.noteSheetDismissed();
        break;
      case REMOTE_HOST_SHEET_PUBLIC_KEY:
        this.resetSshPublicKeyInstallSheetState();
        this.noteSheetDismissed();
        break;
      case REMOTE_HOST_SHEET_MOONLIGHT_DETAIL: {
        const nextCatalogHostId: string = this.pendingMoonlightCatalogHostId;
        const nextSettingsHostId: string = this.pendingMoonlightSettingsHostId;
        this.pendingMoonlightCatalogHostId = '';
        this.pendingMoonlightSettingsHostId = '';
        this.moonlightSheetHostId = '';
        this.noteSheetDismissed();
        if (nextCatalogHostId !== '' && this.pageActive) {
          setTimeout((): void => {
            if (this.pageActive) { this.openMoonlightCatalogSheet(nextCatalogHostId); }
          }, 0);
        } else if (nextSettingsHostId !== '' && this.pageActive) {
          setTimeout((): void => {
            if (this.pageActive) {
              this.openMoonlightSettingsSheet(nextSettingsHostId, SETTINGS_SHEET_MOONLIGHT_VIDEO);
            }
          }, 0);
        }
        break;
      }
      case REMOTE_HOST_SHEET_MOONLIGHT_CATALOG: {
        const hostId: string = this.moonlightSheetHostId;
        const navigation: string = this.pendingMoonlightCatalogNavigation;
        const launch: MoonlightCatalogLaunchHandoff | null =
          this.pendingMoonlightCatalogLaunch;
        this.pendingMoonlightCatalogNavigation = '';
        this.pendingMoonlightCatalogLaunch = null;
        this.moonlightCatalogReturnsToDetail = false;
        this.moonlightCatalogDismissAllowed = true;
        this.moonlightSheetHostId = '';
        this.noteSheetDismissed();
        if (navigation === 'launch' && launch !== null) {
          setTimeout((): void => { void this.presentMoonlightCatalogLaunch(launch); }, 0);
        } else if (navigation !== '' && hostId !== '') {
          setTimeout((): void => {
            if (!this.pageActive) { return; }
            if (navigation === 'settings') {
              this.openMoonlightSettingsSheet(hostId, SETTINGS_SHEET_MOONLIGHT_VIDEO);
            } else {
              this.openMoonlightHostSheet(hostId);
            }
          }, 0);
        }
        break;
      }
      case REMOTE_HOST_SHEET_MOONLIGHT_EDIT:
        this.moonlightSheetHostId = '';
        this.moonlightEditName = '';
        this.moonlightEditAddress = '';
        this.moonlightEditPortText = '';
        this.moonlightEditHttpsPortText = '';
        this.moonlightEditHostType = 'sunshine';
        this.moonlightEditWakeEnabled = false;
        this.moonlightEditWakeMac = '';
        this.moonlightEditWakeBroadcast = '';
        this.moonlightEditError = '';
        this.noteSheetDismissed();
        break;
      default:
        break;
    }
    this.drainRemoteHostSheetQueue(mode);
    this.showRemoteHostSheet = false;
    this.remoteHostSheetMode = REMOTE_HOST_SHEET_NONE;
    this.remoteHostSheetClosing = false;
    this.remoteHostSheetClosingMode = REMOTE_HOST_SHEET_NONE;
  }

  private remoteHostSheetHeight(): SheetSize | string {
    // Moonlight detail and catalog surfaces are both content-sized. The
    // catalog component grows with its visible row count and caps itself at
    // two rows; LARGE leaves a conspicuous white tail for short catalogs.
    return SheetSize.FIT_CONTENT;
  }

  private drainRemoteHostSheetQueue(dismissedMode: number): void {
    let nextMode: number = REMOTE_HOST_SHEET_NONE;
    let nextHostId: string = '';
    if (dismissedMode !== REMOTE_HOST_SHEET_SSH_PREFLIGHT && this.sshPreflightPendingHostId !== '') {
      nextMode = REMOTE_HOST_SHEET_SSH_PREFLIGHT;
      nextHostId = this.sshPreflightPendingHostId;
      this.sshPreflightPendingHostId = '';
    } else if (dismissedMode !== REMOTE_HOST_SHEET_RDP_CERTIFICATE &&
      this.rdpCertificatePendingHostId !== '') {
      nextMode = REMOTE_HOST_SHEET_RDP_CERTIFICATE;
      nextHostId = this.rdpCertificatePendingHostId;
      this.rdpCertificatePendingHostId = '';
    } else if (dismissedMode !== REMOTE_HOST_SHEET_RUSTDESK_PREFLIGHT &&
      this.rustDeskProPreflightPendingHostId !== '') {
      nextMode = REMOTE_HOST_SHEET_RUSTDESK_PREFLIGHT;
      nextHostId = this.rustDeskProPreflightPendingHostId;
      this.rustDeskProPreflightPendingHostId = '';
    } else if (dismissedMode !== REMOTE_HOST_SHEET_VNC_CERTIFICATE &&
      this.vncCertificatePendingHostId !== '') {
      nextMode = REMOTE_HOST_SHEET_VNC_CERTIFICATE;
      nextHostId = this.vncCertificatePendingHostId;
      this.vncCertificatePendingHostId = '';
    }
    if (nextMode === REMOTE_HOST_SHEET_NONE || nextHostId === '') {
      return;
    }
    const nextHost: RemoteHost | undefined = this.srv.getHost(nextHostId);
    if (!nextHost) {
      this.releaseConnectionAttempt(nextHostId);
      return;
    }
    const openNext: () => void = (): void => {
      if (nextMode === REMOTE_HOST_SHEET_SSH_PREFLIGHT) {
        this.openSshPreflight(nextHost);
      } else if (nextMode === REMOTE_HOST_SHEET_RDP_CERTIFICATE) {
        this.openRdpCertificatePreflight(nextHost);
      } else if (nextMode === REMOTE_HOST_SHEET_VNC_CERTIFICATE) {
        const nextVncHostId: string = this.vncRecordIdForHost(nextHost);
        const nextVncHost: VncHostView | null = nextVncHostId === ''
          ? null : this.vncHosts.find(nextVncHostId);
        if (nextVncHost === null) {
          this.releaseConnectionAttempt(nextHostId);
          return;
        }
        this.openVncCertificatePreflight(nextVncHost, nextHost.id,
          this.connectionAttemptGeneration);
      } else {
        this.openRustDeskProPreflight(nextHost);
      }
    };
    const delayMs: number = sheetOpenDelayMsAfterDismiss(Date.now(), this.lastSheetDismissAtMs);
    setTimeout(openNext, delayMs);
  }

  build() {
    Stack() {
      Column().width('100%').height('100%').backgroundColor(this.pal().bg)
      // 所有连接/安全弹窗共用一个 bindSheet 宿主。面板内容由 mode 路由，
      // 关闭和路由统一在宿主 onDisappear 后完成，避免多个 native Sheet 同时退场。
      .bindSheet($$this.showRemoteHostSheet, this.remoteHostSheetBuilder(), {
        height: this.remoteHostSheetHeight(),
        preferType: this.breakpoint === 'sm' ? SheetType.BOTTOM : SheetType.CENTER,
        dragBar: this.breakpoint === 'sm',
        backgroundColor: this.pal().sheetBg,
        blurStyle: BlurStyle.NONE,
        showClose: false,
        maskColor: 'rgba(0,0,0,0.4)',
        onWillDismiss: (action: DismissSheetAction): void => {
          this.handleRemoteHostSheetWillDismiss(action);
        },
        onWillSpringBackWhenDismiss: (_action: SpringBackAction): void => {
          // Deliberately do not spring back: cancellation has already been
          // recorded and action.dismiss() owns the one native exit transition.
        },
        onDisappear: (): void => {
          this.handleRemoteHostSheetDisappear();
        }
      })

      // The native Sheet needs a normal hit-test owner while visible. Keeping
      // this host transparent made the same tap fall through to the settings
      // list and reload the editor, so choice highlights immediately reverted.
      // When the Sheet is closed the empty host must not block the page.
      Column().width('100%').height('100%')
        .hitTestBehavior(this.showSettingsLeafSheet ? HitTestMode.Default : HitTestMode.None)
      .bindSheet($$this.showSettingsLeafSheet, this.settingsLeafSheet(), {
        height: this.settingsLeafSheetHeight(),
        preferType: this.breakpoint === 'sm' ? SheetType.BOTTOM : SheetType.CENTER,
        dragBar: this.breakpoint === 'sm',
        keyboardAvoidMode: this.settingsLeafKeyboardAvoidMode(),
        backgroundColor: this.pal().sheetBg,
        blurStyle: BlurStyle.NONE,
        showClose: settingsLeafSheetUsesSystemCloseButton(),
        maskColor: 'rgba(0,0,0,0.4)',
        onWillDismiss: (action: DismissSheetAction): void => {
          this.handleSettingsLeafWillDismiss(action);
        },
        onWillSpringBackWhenDismiss: (action: SpringBackAction): void => {
          // Only an unsaved VNC editor must stay open while its confirmation
          // dialog is shown. Ordinary settings Sheets skip the default bounce
          // and dismiss with the same single native transition as the FAB.
          if (this.settingsLeafHasUnsavedChanges()) {
            action.springBack();
          }
        },
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
                if (this.groupedHostCardsActive()) {
                  this.sidebarTab('远程主机', protocolIcon('rdp'), 0)
                } else {
                  this.sidebarTab('RDP 远程桌面', protocolIcon('rdp'), 0)
                  this.sidebarTab('RustDesk', protocolIcon('rustdesk'), 1)
                  this.sidebarTab('SSH 终端', protocolIcon('ssh'), 2)
                  this.sidebarTab('VNC 主机', protocolIcon('vnc'), 3)
                }
                this.sidebarMoonlightTab()
                this.sidebarTab('密钥保险库', protocolIcon('key_vault'), 4)
                this.sidebarTab('2FA 验证器', protocolIcon('totp'), 5)
                this.sidebarRelayTab('中继服务器', 6)
              }.layoutWeight(1).padding({ top: 24 })
              // 设置
              this.sidebarSettingsBtn()
            }
            .width(300).height('100%')
            .backgroundColor(this.pal().card).backgroundBlurStyle(BlurStyle.Regular)
            .border({ width: { right: 0.5 }, color: this.pal().divider })

            // 主内容区 (hostContent 使用 updateHostFilter 预过滤的数据源)
            Column() {
              if (this.curTab <= 3 || this.curTab === DESKTOP_MOONLIGHT_TAB) { this.hostContent() }
              else if (this.curTab === 6) { this.relayContent() }
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

      // Start ArkWeb/xterm while the host list is visible so opening an SSH
      // host does not pay the first WebView/vendor-script cold-start cost.
      if (this.sshCount > 0) {
        SshXtermPrewarmSurface({ prewarmEnabled: true })
          .width(1).height(1)
          .position({ x: 0, y: 0 })
          .hitTestBehavior(HitTestMode.None);
      }

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
            // PC 全屏侧边栏: 所有主机协议共用同一添加 Sheet 宿主。
            if (this.curTab <= 3 || this.curTab === DESKTOP_MOONLIGHT_TAB) {
              this.resetForm();
              const nextProto: string = this.activeFilterProto !== '' ? this.activeFilterProto : 'rdp';
              this.switchHostProtocol(nextProto, RemoteHost.getDefaultPort(nextProto));
              const modernPicker: boolean =
                this.curTab === DESKTOP_MOONLIGHT_TAB ||
                resolveFabAddStyle(this.fabAddStyle, this.isDesktopDevice) === 'modern';
              this.addSheetShowsModernPicker = modernPicker;
              if (modernPicker) { this.probeMoonlightCapabilityForPicker(); }
              this.modernAddProtocol = '';
              if (shouldPrepareClassicVncEditor(nextProto, modernPicker)) {
                this.prepareClassicVncEditor(null);
              }
              this.openSheetSafely((): void => { this.showAddSheet = true; });
            } else if (this.curTab === 4) {
              this.kvAddTrigger++;
            } else if (this.curTab === 5) {
              this.keyVaultInnerTab = 1;
              this.kvAddTrigger++;
            } else if (this.curTab === 6) {
              this.relayAddTrigger++;
            }
          } else {
            // 手机/平板/PC小窗: 主机/密钥/中继/设置
            if (this.curTab === 0) {
              this.resetForm();
              this.addSheetShowsModernPicker =
                resolveFabAddStyle(this.fabAddStyle, this.isDesktopDevice) === 'modern';
              if (this.addSheetShowsModernPicker) { this.probeMoonlightCapabilityForPicker(); }
              this.modernAddProtocol = '';
              this.openSheetSafely((): void => { this.showAddSheet = true; });
            }
            if (this.curTab === 1) { this.kvAddTrigger++; }
            if (this.curTab === 2) { this.relayAddTrigger++; }
          }
        })
        .bindSheet($$this.showAddSheet, this.hostAddSheetContent(), {
          height: this.hostAddSheetHeight(),
          preferType: this.breakpoint === 'sm' ? SheetType.BOTTOM : SheetType.CENTER,
          dragBar: false,
          keyboardAvoidMode: this.hostAddSheetKeyboardAvoidMode(),
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
      .opacity(!this.pageActive || (!this.isDesktopDevice && this.curTab === 3) ? 0 : 1)
      .animation({ curve: curves.interpolatingSpring(0, 1, 200, 17) })

      if (this.sheetReleaseFenceActive) {
        // Render last in the Stack so the native Sheet's closing pointer-up
        // cannot fall through to a host card or FAB. The overlay is invisible
        // and exists only for SHEET_RELEASE_FENCE_MS.
        Column()
          .width('100%').height('100%')
          .backgroundColor(Color.Transparent)
          .hitTestBehavior(HitTestMode.Block)
          .zIndex(1000)
      }
    }.width('100%').height('100%').backgroundColor(this.pal().bg)
    .onAreaChange((_oldArea: Area, nextArea: Area): void => {
      const nextHeight: number = nextArea.height as number;
      if (Number.isFinite(nextHeight) && nextHeight > 0 &&
        Math.abs(nextHeight - this.pageViewportHeight) >= 1) {
        this.pageViewportHeight = nextHeight;
      }
    })
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
  @Builder sidebarTab(label: string, icon: Resource, index: number) {
    Row() {
      SymbolGlyph(icon).fontSize(28)
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
        const titles: string[] = ['RDP 远程主机', 'RustDesk 远程主机', 'SSH 终端', 'VNC 主机', '', '', '中继服务器'];
        this.hostPageTitle = titles[index] || '';
        if (index === 4) { this.keyVaultInnerTab = 0; }
        if (index === 5) { this.keyVaultInnerTab = 1; }
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
        const titles: string[] = ['RDP 远程主机', 'RustDesk 远程主机', 'SSH 终端', 'VNC 主机', '', '', '中继服务器'];
        this.hostPageTitle = titles[index] || '';
      }
      this.updateHostFilter();
    })
  }

  @Builder sidebarMoonlightTab() {
    Row() {
      MoonlightBrandIcon({
        iconSize: 28,
        tint: this.curTab === DESKTOP_MOONLIGHT_TAB ? this.accentColor : this.pal().text3,
        accessibilityLabel: 'Moonlight 主机'
      })
      Text('Moonlight').fontSize(16).fontWeight(FontWeight.Medium)
        .fontColor(this.curTab === DESKTOP_MOONLIGHT_TAB ? this.accentColor : this.pal().text3)
        .fontFamily(this.font()).margin({ left: 14 })
    }
    .width('100%').height(56).padding({ left: 24, right: 24 })
    .borderRadius(12).margin({ left: 12, right: 12, bottom: 4 })
    .backgroundColor(this.curTab === DESKTOP_MOONLIGHT_TAB ? this.pal().surface : Color.Transparent)
    .accessibilityText('Moonlight 主机')
    .onClick((): void => {
      this.curTab = DESKTOP_MOONLIGHT_TAB;
      this.hostPageTitle = 'Moonlight 主机';
      this.searchText = '';
      this.refreshMoonlightDirectory();
    })
  }

  @Builder sidebarSettingsBtn() {
    Row() {
      SymbolGlyph(protocolIcon('settings')).fontSize(28).fontColor([this.pal().text3])
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

  private groupedHostCardsActive(): boolean {
    return shouldUseGroupedHostCards(this.groupedHostCards, this.isDesktopDevice, this.breakpoint);
  }

  private updateHostFilter(): void {
    this.activeFilterProto = !this.groupedHostCardsActive() && this.isDesktopDevice && this.breakpoint === 'xl' ?
      hostListProtocolForTab(this.curTab) : '';
    this.refreshFilteredHostView();
  }

  private refreshWorkspaceView(): void {
    this.refreshFilteredHostView();
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

  private hostGroupCardsSnapshot(): HostGroupCardModel[] {
    const displayHosts: RemoteHost[] = this.filteredHosts.map((host: RemoteHost): RemoteHost =>
      this.hostWithPresenceOverride(host));
    return buildHostGroupCards(displayHosts, Date.now(), this.activeRemoteHostId);
  }

  private hostWithPresenceOverride(host: RemoteHost): RemoteHost {
    if (host.protocol === 'rustdesk' && !host.rustdeskDirectEnabled &&
      !this.rustdeskPresenceDetectionEnabled) {
      const disabled: RemoteHost = RemoteHost.fromJSON(host.toJSON());
      disabled.rustdeskProLastSeenAt = 0;
      disabled.rustdeskProSyncError = HOST_PRESENCE_PROBE_UNKNOWN;
      disabled.lastLatency = 0;
      disabled.lastHealth = ConnectionHealth.UNKNOWN;
      return disabled;
    }
    const override: HostPresenceOverride | undefined = this.hostPresenceOverrides.get(host.id);
    if (override === undefined) { return host; }
    const next: RemoteHost = RemoteHost.fromJSON(host.toJSON());
    if (override.state === 'checking') {
      next.rustdeskProLastSeenAt = 0;
      next.rustdeskProSyncError = HOST_PRESENCE_PROBE_PENDING;
      next.lastLatency = 0;
      next.lastHealth = ConnectionHealth.UNKNOWN;
    } else if (override.state === 'online') {
      next.rustdeskProLastSeenAt = override.observedAt;
      next.rustdeskProSyncError = '';
      next.lastConnected = override.observedAt;
      next.lastLatency = override.latencyMs > 0 ? override.latencyMs : 0;
      next.lastHealth = override.latencyMs >= 0 ? this.hostHealthForLatency(override.latencyMs) :
        ConnectionHealth.UNKNOWN;
    } else if (override.state === 'offline') {
      next.rustdeskProLastSeenAt = 0;
      next.rustdeskProSyncError = HOST_PRESENCE_PROBE_OFFLINE;
      next.lastLatency = 0;
      next.lastHealth = ConnectionHealth.UNKNOWN;
    } else {
      next.rustdeskProLastSeenAt = 0;
      next.rustdeskProSyncError = HOST_PRESENCE_PROBE_UNKNOWN;
      next.lastLatency = 0;
      next.lastHealth = ConnectionHealth.UNKNOWN;
    }
    return next;
  }

  private setHostPresenceOverride(hostId: string, state: HostPresenceState,
    latencyMs: number = -1): void {
    const next: HostPresenceOverride = {
      state: state,
      latencyMs: latencyMs,
      observedAt: Date.now()
    };
    this.hostPresenceOverrides.set(hostId, next);
    // Force the grouped builders to consume the new page-local snapshot even
    // when the service/cloud snapshot has not changed yet.
    this.hostViewRevision += 1;
  }

  private hostGroupCardForType(type: HostGroupType): HostGroupCardModel {
    const cards: HostGroupCardModel[] = this.hostGroupCardsSnapshot();
    let selected: HostGroupCardModel = cards[0];
    for (let i = 0; i < cards.length; i++) {
      if (cards[i].type === type) {
        selected = cards[i];
        break;
      }
    }
    return selected;
  }

  private hostGroupCardHeight(): number {
    // Keep grouped cards close to the compact settings-card rhythm. The xl
    // desktop layout is excluded from this grouped view and keeps its existing
    // categorized cards.
    return this.breakpoint === 'sm' ? 88 : 96;
  }

  private hostGroupHostCardHeight(): number {
    // The card stays compact, while the larger touch targets get one shared
    // vertical rhythm on phone, Pad, and small-screen PC layouts.
    return this.breakpoint === 'sm' ? 102 : 98;
  }

  private hostGroupHostGridHeight(count: number): number {
    const columns: number = hostGroupColumnsForBreakpoint(this.breakpoint);
    const rows: number = Math.max(1, Math.ceil(count / columns));
    return rows * this.hostGroupHostCardHeight() + Math.max(0, rows - 1) * 10;
  }

  private hostGroupStatusColor(state: HostPresenceState): string {
    if (state === 'online') { return this.pal().success; }
    if (state === 'offline') { return this.pal().danger; }
    if (state === 'recently_online') { return this.accentColor; }
    // Unknown/checking follows the user's current theme accent; online and
    // offline retain their semantic success/danger colors.
    return this.accentColor;
  }

  private hostGroupStatusColorForHost(host: RemoteHost): string {
    if (host.protocol === 'rustdesk' && host.rustdeskDirectEnabled) {
      return this.pal().text2;
    }
    if (host.protocol === 'rustdesk' && !this.rustdeskPresenceDetectionEnabled) {
      return this.accentColor;
    }
    return this.hostGroupStatusColor(this.hostGroupPresenceForHost(host));
  }

  private hostGroupSummaryText(card: HostGroupCardModel): string {
    if (card.hosts.length === 0) { return '暂无主机'; }
    if (card.type === 'rustdesk' && !this.rustdeskPresenceDetectionEnabled) {
      return '';
    }
    const parts: string[] = [];
    if (card.summary.online > 0) { parts.push(card.summary.online.toString() + ' 在线'); }
    if (card.summary.recentlyOnline > 0) {
      parts.push(card.summary.recentlyOnline.toString() + ' 最近在线');
    }
    if (card.summary.offline > 0) { parts.push(card.summary.offline.toString() + ' 离线'); }
    if (card.summary.unknown > 0) { parts.push(card.summary.unknown.toString() + ' 未知'); }
    if (card.summary.checking > 0) { parts.push(card.summary.checking.toString() + ' 检测中'); }
    return parts.length > 0 ? parts.join(' · ') : '未检测';
  }

  private hostGroupLastSeenText(host: RemoteHost): string {
    const state: HostPresenceState = this.hostGroupPresenceForHost(host);
    if (state === 'checking') { return '检测中'; }
    const override: HostPresenceOverride | undefined = this.hostPresenceOverrides.get(host.id);
    if (override !== undefined && override.observedAt > 0) {
      const elapsedMs: number = Math.max(0, Date.now() - override.observedAt);
      if (elapsedMs < 60 * 1000) {
        return state === 'online' ? '刚刚' : '检测于刚刚';
      }
    }
    const timestamp: number = hostPresenceLastSeenAt(host);
    if (timestamp <= 0) { return '未检测'; }
    const elapsedMs: number = Math.max(0, Date.now() - timestamp);
    if (elapsedMs < 60 * 1000) { return '刚刚'; }
    if (elapsedMs < 60 * 60 * 1000) {
      return Math.floor(elapsedMs / (60 * 1000)).toString() + ' 分钟前';
    }
    if (elapsedMs < 24 * 60 * 60 * 1000) {
      return Math.floor(elapsedMs / (60 * 60 * 1000)).toString() + ' 小时前';
    }
    return Math.floor(elapsedMs / (24 * 60 * 60 * 1000)).toString() + ' 天前';
  }

  private hostGroupStatusLine(host: RemoteHost): string {
    if (host.protocol === 'rustdesk' && !this.rustdeskPresenceDetectionEnabled) {
      return '';
    }
    if (host.protocol === 'rustdesk' && host.rustdeskDirectEnabled) {
      return '直连';
    }
    const state: HostPresenceState = this.hostGroupPresenceForHost(host);
    const label: string = hostPresenceLabel(state);
    if (state === 'checking') {
      return label + ' · ' + this.hostGroupProtocolStatusText(host);
    }
    const override: HostPresenceOverride | undefined = this.hostPresenceOverrides.get(host.id);
    const latencyMs: number = override !== undefined ? override.latencyMs : host.lastLatency;
    if (state === 'online') {
      return latencyMs > 0 ? label + ' · ' + latencyMs.toString() + ' ms' : label;
    }
    return label + ' · ' + this.hostGroupLastSeenText(host);
  }

  private hostGroupIconForHost(host: RemoteHost): Resource {
    const type: HostGroupType | null = hostGroupTypeForHost(host);
    if (type === 'rustdesk') { return protocolIcon('rustdesk'); }
    if (type === 'ssh') { return protocolIcon('ssh'); }
    if (type === 'vnc') { return protocolIcon('vnc'); }
    return protocolIcon('rdp');
  }

  private hostGroupPresenceForHost(host: RemoteHost): HostPresenceState {
    if (this.hostPresenceProbeBusyIds.has(host.id)) { return 'checking'; }
    const override: HostPresenceOverride | undefined = this.hostPresenceOverrides.get(host.id);
    if (override !== undefined) { return override.state; }
    return hostPresenceState(host, Date.now(), host.id === this.activeRemoteHostId);
  }

  private rustDeskPresenceStatusText(host: RemoteHost): string {
    if (host.rustdeskDirectEnabled) { return '直连'; }
    if (!this.rustdeskPresenceDetectionEnabled) { return ''; }
    const state: HostPresenceState = this.hostGroupPresenceForHost(host);
    if (state === 'checking') { return '检测中'; }
    const override: HostPresenceOverride | undefined = this.hostPresenceOverrides.get(host.id);
    const latencyMs: number = override !== undefined ? override.latencyMs : host.lastLatency;
    if (state === 'online' && latencyMs > 0) {
      return '在线 · ' + latencyMs.toString() + ' ms';
    }
    return hostPresenceLabel(state);
  }

  private rustDeskPresenceStatusColor(host: RemoteHost): string {
    if (host.rustdeskDirectEnabled) { return this.pal().text2; }
    if (!this.rustdeskPresenceDetectionEnabled) { return this.accentColor; }
    return this.hostGroupStatusColorForHost(host);
  }

  private hostGroupHostModeLabel(host: RemoteHost): string {
    if (host.protocol !== 'rustdesk') { return ''; }
    if (host.rustdeskDirectEnabled) { return '直连'; }
    if (host.rustdeskProManaged || host.sourceType === 'rustdesk_pro') { return 'Pro'; }
    return '';
  }

  private hostGroupHostModeColor(host: RemoteHost): string {
    if (host.rustdeskDirectEnabled) { return this.pal().success; }
    if (host.rustdeskProManaged || host.sourceType === 'rustdesk_pro') {
      return this.accentColor;
    }
    return this.pal().text2;
  }

  private hostGroupCanProbe(host: RemoteHost): boolean {
    return !(host.protocol === 'rustdesk' && host.rustdeskDirectEnabled);
  }

  private toggleHostGroup(type: HostGroupType): void {
    animateTo({ duration: 220, curve: Curve.FastOutSlowIn }, (): void => {
      this.expandedHostGroup = this.expandedHostGroup === type ? '' : type;
    });
  }

  @Builder hostGroupTypeCard(card: HostGroupCardModel) {
    Column() {
      Row() {
        Column() {
          SymbolGlyph(protocolIcon(card.type)).fontSize(this.breakpoint === 'sm' ? 20 : 24)
            .fontColor([this.accentColor])
        }
        .width(this.breakpoint === 'sm' ? 38 : 44)
        .height(this.breakpoint === 'sm' ? 38 : 44)
        .borderRadius(this.breakpoint === 'sm' ? 19 : 14)
        .backgroundColor(this.pal().surface)
        .justifyContent(FlexAlign.Center)
        Column() {
          Text(card.title).fontSize(this.breakpoint === 'sm' ? 16 : 18)
            .fontWeight(FontWeight.Medium).fontColor(this.pal().text).fontFamily(this.font())
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(card.subtitle).fontSize(this.breakpoint === 'sm' ? 10 : 11)
            .fontColor(this.pal().text3).fontFamily(this.font()).margin({ top: 3 })
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        }.alignItems(HorizontalAlign.Start).layoutWeight(1).margin({ left: this.breakpoint === 'sm' ? 8 : 10 })
          SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(this.breakpoint === 'sm' ? 16 : 18)
          .fontColor([this.pal().text3])
          .rotate({ angle: this.expandedHostGroup === card.type ? 90 : 0 })
          .animation({ duration: 220, curve: Curve.FastOutSlowIn })
      }.width('100%')
      Row() {
        Text(card.hosts.length.toString() + ' 台主机').fontSize(this.breakpoint === 'sm' ? 10 : 11)
          .fontColor(this.pal().text2).fontFamily(this.font())
        Blank()
        if (this.hostGroupSummaryText(card) !== '') {
          Text(this.hostGroupSummaryText(card)).fontSize(this.breakpoint === 'sm' ? 9 : 10)
            .fontColor(this.pal().text3).fontFamily(this.font()).maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }.width('100%').margin({ top: this.breakpoint === 'sm' ? 8 : 10 })
    }
    .layoutWeight(1).height(this.hostGroupCardHeight())
    .padding(this.breakpoint === 'sm' ? 10 : 12)
    .borderRadius(this.breakpoint === 'sm' ? 16 : 14)
    .backgroundColor(this.pal().card).backgroundBlurStyle(BlurStyle.Regular)
    .border({ width: this.expandedHostGroup === card.type ? 1.5 : 0.5,
      color: this.expandedHostGroup === card.type ? this.accentColor : this.pal().cardBorder,
      style: BorderStyle.Solid })
    .onClick((): void => { this.toggleHostGroup(card.type); })
  }

  private hostGroupProtocolStatusText(host: RemoteHost): string {
    if (host.protocol === 'rustdesk') {
      if (host.rustdeskDirectEnabled) { return '无需探测'; }
      return host.rustdeskProManaged || host.sourceType === 'rustdesk_pro' ? 'Pro 中继探测' : '中继探测';
    }
    if (host.protocol === 'rdp') {
      return host.rdpCertificateTrustMode > 0 ? '证书已信任' : '证书待验证';
    }
    if (host.protocol === 'ssh') {
      return host.sshUseKey ? '密钥认证' : '密码认证';
    }
    return host.gatewayHost.trim() === '' ? '直连屏幕' : '网关屏幕';
  }

  private protectedHostCardValue(host: RemoteHost, visibleValue: string): string {
    return hostCardSensitiveValue(shouldHideHostCardSensitiveInfo(
      this.hostCardSensitiveInfoHidden, host.locked), visibleValue);
  }

  @Builder hostGroupedProtocolDetails(host: RemoteHost) {
    Row() {
      if (host.protocol === 'rustdesk') {
        Text('ID').fontSize(this.breakpoint === 'sm' ? 12 : 13).fontColor(this.pal().text3).width(30)
        Text(this.protectedHostCardValue(host, hostIdentifier(host)))
          .fontSize(this.breakpoint === 'sm' ? 15 : 16)
          .fontWeight(FontWeight.Medium).fontColor(this.pal().text2).fontFamily(this.font()).layoutWeight(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis }).maxLines(1)
          .accessibilityText(this.protectedHostCardValue(host, hostIdentifier(host)))
      } else if (host.protocol === 'ssh') {
        Text('SSH').fontSize(11).fontColor(this.pal().text3).width(30)
        Text(this.protectedHostCardValue(host,
          (host.username.trim() === '' ? '' : host.username + '@') +
            host.host + ':' + host.port.toString()))
          .fontSize(this.breakpoint === 'sm' ? 12 : 13).fontColor(this.pal().text2)
          .fontFamily(this.font()).layoutWeight(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis }).maxLines(1)
      } else if (host.protocol === 'vnc') {
        Text('VNC').fontSize(11).fontColor(this.pal().text3).width(30)
        Text(this.protectedHostCardValue(host, host.gatewayHost.trim() === '' ?
          host.host + ':' + host.port.toString() :
          host.host + ':' + host.port.toString() + ' · 网关 ' + host.gatewayHost))
          .fontSize(this.breakpoint === 'sm' ? 12 : 13).fontColor(this.pal().text2)
          .fontFamily(this.font()).layoutWeight(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis }).maxLines(1)
      } else {
        Text('RDP').fontSize(11).fontColor(this.pal().text3).width(30)
        Text(this.protectedHostCardValue(host, host.host + ':' + host.port.toString()))
          .fontSize(this.breakpoint === 'sm' ? 12 : 13)
          .fontColor(this.pal().text2).fontFamily(this.font()).layoutWeight(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis }).maxLines(1)
      }
    }.width('100%').margin({ top: 3 })
  }

  @Builder hostGroupedHostCard(host: RemoteHost) {
    Row() {
      if (this.hostSelectionMode) {
        Checkbox()
          .select(this.hostSelectedIds.has(remoteHostCardKey(host.id))).selectedColor(this.accentColor)
          .margin({ right: 7 })
          .monopolizeEvents(true)
          .onChange((checked: boolean): void => {
            this.toggleHostSelect(remoteHostCardKey(host.id), checked);
          })
      }
      Column() {
        SymbolGlyph(this.hostGroupIconForHost(host)).fontSize(this.breakpoint === 'sm' ? 21 : 23)
          .fontColor([Color.White])
      }
      .width(this.breakpoint === 'sm' ? 40 : 42)
      .height(this.breakpoint === 'sm' ? 40 : 42)
      .borderRadius(this.breakpoint === 'sm' ? 12 : 13)
      .backgroundColor(this.accentColor)
      .justifyContent(FlexAlign.Center)
      .margin({ right: this.breakpoint === 'sm' ? 9 : 10 })
      .onClick((): void => { this.handleHostCardClick(host); })
      Column() {
        Row() {
          Text(hostCardDisplayLabel(
            shouldHideHostCardSensitiveInfo(this.hostCardSensitiveInfoHidden, host.locked),
            host.protocol, host.label, host.rustdeskProPeerId, host.customHostname))
            .fontSize(this.breakpoint === 'sm' ? 15 : 16)
            .fontWeight(FontWeight.Medium).fontColor(this.pal().text).fontFamily(this.font())
            .layoutWeight(1).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        }.width('100%')
        if (this.hostGroupStatusLine(host) !== '') {
          Text(this.hostGroupStatusLine(host))
            .fontSize(this.breakpoint === 'sm' ? 12 : 13)
            .fontColor(this.hostGroupStatusColorForHost(host))
            .fontFamily(this.font()).margin({ top: 2 })
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        this.hostGroupedProtocolDetails(host)
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        .onClick((): void => { this.handleHostCardClick(host); })
      Column() {
        // Keep the top action row for direct hosts as well. Direct hosts do
        // not probe, but the reserved probe slot keeps every action row aligned.
        Row() {
          if (this.hostGroupHostModeLabel(host) !== '') {
            Text(this.hostGroupHostModeLabel(host))
              .fontSize(this.breakpoint === 'sm' ? 10 : 11)
              .fontColor(this.hostGroupHostModeColor(host)).fontFamily(this.font())
              .padding({ left: 7, right: 7, top: 3, bottom: 3 })
              .borderRadius(7).backgroundColor(this.pal().surface).margin({ right: 6 })
              .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          if (this.hostGroupCanProbe(host)) {
            Button() {
              if (this.hostPresenceProbeBusyIds.has(host.id)) {
                LoadingProgress().width(21).height(21).color(this.accentColor)
              } else {
                SymbolGlyph($r('sys.symbol.bolt_fill')).fontSize(19).fontColor([this.accentColor])
              }
            }
            .width(this.breakpoint === 'sm' ? 38 : 40)
            .height(this.breakpoint === 'sm' ? 38 : 40).borderRadius(19).padding(0)
            .backgroundColor(this.pal().surface).accessibilityText('检测在线状态')
            .enabled(!this.hostPresenceProbeBusyIds.has(host.id))
            .onClick((): void => { void this.probeHostConnectivity(host); })
          } else {
            Blank()
              .width(this.breakpoint === 'sm' ? 38 : 40)
              .height(this.breakpoint === 'sm' ? 38 : 40)
          }
        }
        Row() {
          Button() {
            SymbolGlyph($r('sys.symbol.square_and_pencil')).fontSize(16).fontColor([this.pal().text2])
          }
          .width(36).height(36).borderRadius(18).padding(0).backgroundColor(this.pal().surface)
          .accessibilityText('编辑').onClick((): void => { void this.editHost(host); })
          Button() {
            SymbolGlyph(host.locked ? $r('sys.symbol.lock_open') : $r('sys.symbol.ohos_lock'))
              .fontSize(16).fontColor([this.pal().text2])
          }
          .width(36).height(36).borderRadius(18).padding(0).backgroundColor(this.pal().surface)
          .margin({ left: 8 }).accessibilityText(host.locked ? '解锁' : '上锁')
          .onClick((): void => { void this.toggleLock(host); })
          Button() {
            SymbolGlyph($r('sys.symbol.ohos_trash')).fontSize(16).fontColor([this.pal().danger])
          }
          .width(36).height(36).borderRadius(18).padding(0).backgroundColor(this.pal().surface)
          .margin({ left: 8 }).accessibilityText('删除')
          .onClick((): void => { void this.doDeleteHost(host); })
        }.margin({ top: 7 })
      }.alignItems(HorizontalAlign.End).margin({ left: 10 })
    }
    .width('100%').height(this.hostGroupHostCardHeight()).padding(6)
    .borderRadius(12).backgroundColor(this.pal().card).backgroundBlurStyle(BlurStyle.Regular)
    .border({ width: 0.5, color: this.pal().cardBorder, style: BorderStyle.Solid })
    // Grouped cards intentionally have no swipe actions. Long press remains
    // the explicit entry point for multi-select.
    .priorityGesture(LongPressGesture({ duration: 450 }).onAction((): void => {
      if (!this.hostSelectionMode) {
        this.beginHostSelection(remoteHostCardKey(host.id), false);
      }
    }))
  }

  private hostGroupDetailPanelHeight(card: HostGroupCardModel): number {
    const padding: number = this.breakpoint === 'sm' ? 12 : 14;
    const header: number = this.breakpoint === 'sm' ? 34 : 38;
    const content: number = card.hosts.length === 0
      ? header + (this.breakpoint === 'sm' ? 92 : 100)
      : header + 10 + this.hostGroupHostGridHeight(card.hosts.length);
    return padding * 2 + content;
  }

  @Builder hostGroupedDetailPanel(card: HostGroupCardModel) {
    // Read the state directly in component properties so the panel rebuilds
    // when the selected group changes. Passing a boolean builder argument can
    // leave the initial collapsed value cached by the list item.
    Column() {
      Row() {
        Column() {
          Text(card.title + ' 主机').fontSize(this.breakpoint === 'sm' ? 15 : 17)
            .fontWeight(FontWeight.Medium).fontColor(this.pal().text).fontFamily(this.font())
          Text(card.hosts.length.toString() + ' 台' +
            (this.hostGroupSummaryText(card) === '' ? '' : ' · ' + this.hostGroupSummaryText(card)))
            .fontSize(11).fontColor(this.pal().text3).fontFamily(this.font()).margin({ top: 4 })
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        Button() {
          if (this.hostGroupProbeBusyType === card.type) {
            LoadingProgress().width(15).height(15).color(this.accentColor)
          } else {
            SymbolGlyph($r('sys.symbol.bolt_fill')).fontSize(15).fontColor([this.accentColor])
          }
        }
        .width(28).height(28).borderRadius(14).padding(0).backgroundColor(this.pal().surface)
        .accessibilityText('检测全部' + card.title + '主机')
        .enabled(this.hostGroupProbeBusyType === '' && card.hosts.length > 0)
        .onClick((): void => { void this.probeHostGroup(card); })
      }.width('100%')
      if (card.hosts.length === 0) {
        Column() {
          SymbolGlyph(protocolIcon(card.type)).fontSize(32).fontColor([this.pal().text3])
          Text('暂无 ' + hostGroupTitle(card.type) + ' 主机').fontSize(13).fontColor(this.pal().text2)
            .fontFamily(this.font()).margin({ top: 10 })
          Text('点击底部按钮添加主机').fontSize(11).fontColor(this.pal().text3)
            .fontFamily(this.font()).margin({ top: 4 })
        }.width('100%').height(this.breakpoint === 'sm' ? 92 : 100)
          .justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
      } else {
        Grid() {
          ForEach(card.hosts, (host: RemoteHost): void => {
            GridItem() { this.hostGroupedHostCard(host) }
          }, (host: RemoteHost): string => host.id + ':' + this.hostViewRevision.toString())
        }
        .columnsTemplate(hostGroupColumnsForBreakpoint(this.breakpoint) === 1 ? '1fr' : '1fr 1fr')
        .rowsGap(10).columnsGap(10).width('100%')
        .height(this.hostGroupHostGridHeight(card.hosts.length)).margin({ top: 10 })
      }
    }
    .width('100%').height(this.expandedHostGroup === card.type ? this.hostGroupDetailPanelHeight(card) : 0)
    .padding(this.expandedHostGroup === card.type ? (this.breakpoint === 'sm' ? 12 : 14) : 0)
    .opacity(this.expandedHostGroup === card.type ? 1 : 0).clip(true)
    .borderRadius(this.breakpoint === 'sm' ? 16 : 15)
    .backgroundColor(this.pal().surface).backgroundBlurStyle(BlurStyle.Regular)
    .border({ width: 0.5, color: this.pal().cardBorder, style: BorderStyle.Solid })
    .margin({ top: this.expandedHostGroup === card.type ? 8 : 0,
      bottom: this.expandedHostGroup === card.type ? 10 : 0 })
    .animation({ duration: 220, curve: Curve.FastOutSlowIn })
  }

  @Builder hostGroupedPhoneGroup(type: HostGroupType) {
    Column() {
      Row() {
        this.hostGroupTypeCard(this.hostGroupCardForType(type))
      }.width('100%').height(this.hostGroupCardHeight())
      this.hostGroupedDetailPanel(this.hostGroupCardForType(type))
    }
    .width('100%').margin({ bottom: 10 })
  }

  @Builder hostGroupedDesktopRow(first: HostGroupType, second: HostGroupType) {
    Column() {
      Row() {
        this.hostGroupTypeCard(this.hostGroupCardForType(first))
        Blank().width(10)
        this.hostGroupTypeCard(this.hostGroupCardForType(second))
      }.width('100%').height(this.hostGroupCardHeight()).alignItems(VerticalAlign.Top)
      this.hostGroupedDetailPanel(this.hostGroupCardForType(first))
      this.hostGroupedDetailPanel(this.hostGroupCardForType(second))
    }
    .width('100%').margin({ bottom: 10 })
  }

  private moonlightGroupCatalogCount(): number {
    const hosts: MoonlightHostLocalView[] = this.visibleMoonlightHosts();
    let count: number = 0;
    for (let index: number = 0; index < hosts.length; index++) {
      count += hosts[index].catalogItems.length;
    }
    return count;
  }

  private toggleMoonlightGroup(): void {
    animateTo({ duration: 220, curve: Curve.FastOutSlowIn }, (): void => {
      this.expandedHostGroup = this.expandedHostGroup === 'moonlight' ? '' : 'moonlight';
    });
  }

  @Builder moonlightGroupTypeCard() {
    Column() {
      Row() {
        Column() {
          MoonlightBrandIcon({ iconSize: this.breakpoint === 'sm' ? 20 : 24,
            tint: this.accentColor, accessibilityLabel: 'Moonlight' })
        }
        .width(this.breakpoint === 'sm' ? 38 : 44)
        .height(this.breakpoint === 'sm' ? 38 : 44)
        .borderRadius(this.breakpoint === 'sm' ? 19 : 14)
        .backgroundColor(this.pal().surface)
        .justifyContent(FlexAlign.Center)
        Column() {
          Text('Moonlight').fontSize(this.breakpoint === 'sm' ? 16 : 18)
            .fontWeight(FontWeight.Medium).fontColor(this.pal().text).fontFamily(this.font())
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          Text('Sunshine / GameStream').fontSize(this.breakpoint === 'sm' ? 10 : 11)
            .fontColor(this.pal().text3).fontFamily(this.font()).margin({ top: 3 })
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
          .margin({ left: this.breakpoint === 'sm' ? 8 : 10 })
        SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(this.breakpoint === 'sm' ? 16 : 18)
          .fontColor([this.pal().text3])
          .rotate({ angle: this.expandedHostGroup === 'moonlight' ? 90 : 0 })
          .animation({ duration: 220, curve: Curve.FastOutSlowIn })
      }.width('100%')
      Row() {
        Text(this.visibleMoonlightHosts().length.toString() + ' 台主机')
          .fontSize(this.breakpoint === 'sm' ? 10 : 11)
          .fontColor(this.pal().text2).fontFamily(this.font())
        Blank()
        Text(this.moonlightGroupCatalogCount().toString() + ' 个应用')
          .fontSize(this.breakpoint === 'sm' ? 9 : 10)
          .fontColor(this.pal().text3).fontFamily(this.font()).maxLines(1)
      }.width('100%').margin({ top: this.breakpoint === 'sm' ? 8 : 10 })
    }
    .layoutWeight(1).height(this.hostGroupCardHeight())
    .padding(this.breakpoint === 'sm' ? 10 : 12)
    .borderRadius(this.breakpoint === 'sm' ? 16 : 14)
    .backgroundColor(this.pal().card).backgroundBlurStyle(BlurStyle.Regular)
    .border({ width: this.expandedHostGroup === 'moonlight' ? 1.5 : 0.5,
      color: this.expandedHostGroup === 'moonlight' ? this.accentColor : this.pal().cardBorder,
      style: BorderStyle.Solid })
    .onClick((): void => { this.toggleMoonlightGroup(); })
  }

  private moonlightGroupDetailPanelHeight(): number {
    const count: number = this.visibleMoonlightHosts().length;
    const padding: number = this.breakpoint === 'sm' ? 12 : 14;
    const header: number = this.breakpoint === 'sm' ? 34 : 38;
    const content: number = count === 0
      ? header + (this.breakpoint === 'sm' ? 92 : 100)
      : header + 10 + this.hostGroupHostGridHeight(count);
    return padding * 2 + content;
  }

  @Builder moonlightGroupedDetailPanel() {
    Column() {
      Row() {
        Column() {
          Text('Moonlight 主机').fontSize(this.breakpoint === 'sm' ? 15 : 17)
            .fontWeight(FontWeight.Medium).fontColor(this.pal().text).fontFamily(this.font())
          Text(this.visibleMoonlightHosts().length.toString() + ' 台 · ' +
            this.moonlightGroupCatalogCount().toString() + ' 个应用')
            .fontSize(11).fontColor(this.pal().text3).fontFamily(this.font()).margin({ top: 4 })
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        Button() {
          MoonlightBrandIcon({ iconSize: 15, tint: this.accentColor, accessibilityLabel: '应用目录' })
        }
        .width(28).height(28).borderRadius(14).padding(0).backgroundColor(this.pal().surface)
        .accessibilityText('打开 Moonlight 应用目录')
        .enabled(this.visibleMoonlightHosts().length > 0)
        .onClick((): void => {
          const first: MoonlightHostLocalView | undefined = this.visibleMoonlightHosts()[0];
          if (first !== undefined && first.host !== null) {
            void this.openMoonlightHost(first.host.id, true);
          }
        })
      }.width('100%')
      if (this.visibleMoonlightHosts().length === 0) {
        Column() {
          MoonlightBrandIcon({ iconSize: 32, tint: this.pal().text3 })
          Text('暂无 Moonlight 主机').fontSize(13).fontColor(this.pal().text2)
            .fontFamily(this.font()).margin({ top: 10 })
          Text('点击底部按钮添加主机').fontSize(11).fontColor(this.pal().text3)
            .fontFamily(this.font()).margin({ top: 4 })
        }.width('100%').height(this.breakpoint === 'sm' ? 92 : 100)
          .justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
      } else {
        Grid() {
          ForEach(this.visibleMoonlightHosts(), (view: MoonlightHostLocalView): void => {
            GridItem() { this.moonlightGroupedHostCard(view) }
          }, (view: MoonlightHostLocalView): string =>
            this.moonlightHostCardKey(view) + ':' + this.hostViewRevision.toString())
        }
        .columnsTemplate(hostGroupColumnsForBreakpoint(this.breakpoint) === 1 ? '1fr' : '1fr 1fr')
        .rowsGap(10).columnsGap(10).width('100%')
        .height(this.hostGroupHostGridHeight(this.visibleMoonlightHosts().length)).margin({ top: 10 })
      }
    }
    .width('100%').height(this.expandedHostGroup === 'moonlight' ?
      this.moonlightGroupDetailPanelHeight() : 0)
    .padding(this.expandedHostGroup === 'moonlight' ? (this.breakpoint === 'sm' ? 12 : 14) : 0)
    .opacity(this.expandedHostGroup === 'moonlight' ? 1 : 0).clip(true)
    .borderRadius(this.breakpoint === 'sm' ? 16 : 15)
    .backgroundColor(this.pal().surface).backgroundBlurStyle(BlurStyle.Regular)
    .border({ width: 0.5, color: this.pal().cardBorder, style: BorderStyle.Solid })
    .margin({ top: this.expandedHostGroup === 'moonlight' ? 8 : 0,
      bottom: this.expandedHostGroup === 'moonlight' ? 10 : 0 })
    .animation({ duration: 220, curve: Curve.FastOutSlowIn })
  }

  @Builder moonlightGroupedPhoneGroup() {
    Column() {
      Row() { this.moonlightGroupTypeCard() }
        .width('100%').height(this.hostGroupCardHeight())
      this.moonlightGroupedDetailPanel()
    }.width('100%').margin({ bottom: 10 })
  }

  @Builder moonlightGroupedDesktopRow() {
    Column() {
      Row() {
        this.moonlightGroupTypeCard()
        Blank().width(10)
        Blank().layoutWeight(1)
      }.width('100%').height(this.hostGroupCardHeight()).alignItems(VerticalAlign.Top)
      this.moonlightGroupedDetailPanel()
    }.width('100%').margin({ bottom: 10 })
  }

  @Builder hostGroupedContent() {
    Column() {
      if (this.breakpoint === 'sm') {
        this.hostGroupedPhoneGroup('rdp')
        this.hostGroupedPhoneGroup('rustdesk')
        this.hostGroupedPhoneGroup('ssh')
        this.hostGroupedPhoneGroup('vnc')
        this.moonlightGroupedPhoneGroup()
      } else {
        this.hostGroupedDesktopRow('rdp', 'rustdesk')
        this.hostGroupedDesktopRow('ssh', 'vnc')
        this.moonlightGroupedDesktopRow()
      }
    }
    .width('100%').padding({ top: 8, bottom: 140 })
  }

  @Builder moonlightFlatHostCard(view: MoonlightHostLocalView) {
    if (view.host !== null) {
      Row() {
        if (this.hostSelectionMode) {
          Checkbox()
            .select(this.hostSelectedIds.has(unifiedMoonlightHostCardKey(view.host.id)))
            .selectedColor(this.accentColor).margin({ right: 8 })
            .onChange((checked: boolean): void => {
              this.toggleHostSelect(unifiedMoonlightHostCardKey(view.host?.id || ''), checked);
            })
        }
        Column() {
          MoonlightBrandIcon({ iconSize: this.breakpoint === 'sm' ? 24 : 26,
            tint: '#FFFFFF', accessibilityLabel: 'Moonlight 主机' })
        }
        .width(this.breakpoint === 'sm' ? 42 : 46)
        .height(this.breakpoint === 'sm' ? 42 : 46)
        .borderRadius(this.breakpoint === 'sm' ? 21 : 14)
        .backgroundColor(this.accentColor)
        .justifyContent(FlexAlign.Center)
        .margin({ right: this.breakpoint === 'sm' ? 10 : 12 })
        .onClick((): void => {
          this.handleMoonlightHostCardClick(view.host?.id || '');
        })
        Column() {
          Row() {
            Text(view.host.displayName)
              .fontSize(this.breakpoint === 'sm' ? (AppTheme.fontSize.body as number) : 17)
              .fontWeight(FontWeight.Medium).fontColor(this.pal().text).fontFamily(this.font())
              .layoutWeight(1).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
            if (view.host.locked === true) {
              SymbolGlyph($r('sys.symbol.ohos_lock'))
                .fontSize(this.breakpoint === 'sm' ? 14 : 18).fontColor([this.pal().danger])
                .margin({ left: this.breakpoint === 'sm' ? 6 : 8 })
            }
          }.width('100%')
          if (view.host.locked === true) {
            Text('已锁定 · 需验证')
              .fontSize(this.breakpoint === 'sm' ? 12 : 13).fontColor(this.pal().text3)
              .fontFamily(this.font()).margin({ top: this.breakpoint === 'sm' ? 3 : 4 })
          } else {
            Text('MOONLIGHT  ·  ' + this.protectedMoonlightCardValue(
              view.host, this.moonlightAddressLabel(view.host)) + '  ·  ' +
              view.catalogItems.length.toString() + ' 个应用')
              .fontSize(this.breakpoint === 'sm' ? 12 : 14).fontColor(this.pal().text2)
              .fontFamily(this.font()).margin({ top: this.breakpoint === 'sm' ? 3 : 4 })
              .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          }
        }
        .alignItems(HorizontalAlign.Start).layoutWeight(1)
        .onClick((): void => {
          this.handleMoonlightHostCardClick(view.host?.id || '');
        })
        Column() {
          if (this.hostSelectionMode && this.hostReorderEnabled) {
            SymbolGlyph($r('sys.symbol.line_3_horizontal'))
              .fontSize(20).fontColor([this.pal().text3]).margin({ left: 8 })
          }
          if (!this.hostSelectionMode && this.isDesktopDevice) {
            Button() {
              Text('⋯').fontSize(18).fontColor(this.pal().text)
            }
            .width(36).height(36).borderRadius(18).backgroundColor(this.pal().surface)
            .bindPopup(this.hostActionPopupId === unifiedMoonlightHostCardKey(view.host.id), {
              builder: this.moonlightActionMenuBuilder(view),
              placement: Placement.BottomRight,
              enableArrow: true,
              popupColor: this.pal().card,
              width: 152,
              onStateChange: (event: Object): void => {
                const value: Record<string, boolean> = event as Record<string, boolean>;
                if (!value['isVisible']) { this.hostActionPopupId = ''; }
              }
            })
            .onClick((): void => {
              const key: string = unifiedMoonlightHostCardKey(view.host?.id || '');
              this.hostActionPopupId = this.hostActionPopupId === key ? '' : key;
            })
          }
        }.alignItems(HorizontalAlign.End).margin({ left: 6 })
      }
      .width('100%').constraintSize({ minHeight: this.breakpoint === 'sm' ? 66 : 80 })
      .padding(this.breakpoint === 'sm' ? { left: 12, right: 14, top: 12, bottom: 12 } : 14)
      .borderRadius(14).backgroundColor(this.pal().card).backgroundBlurStyle(BlurStyle.Regular)
      .border({ width: 0.5, color: this.pal().cardBorder, style: BorderStyle.Solid })
    }
  }

  @Builder moonlightGroupedHostCard(view: MoonlightHostLocalView) {
    if (view.host !== null) {
      Row() {
        if (this.hostSelectionMode) {
          Checkbox()
            .select(this.hostSelectedIds.has(unifiedMoonlightHostCardKey(view.host.id)))
            .selectedColor(this.accentColor).margin({ right: 7 }).monopolizeEvents(true)
            .onChange((checked: boolean): void => {
              this.toggleHostSelect(unifiedMoonlightHostCardKey(view.host?.id || ''), checked);
            })
        }
        Column() {
          MoonlightBrandIcon({ iconSize: this.breakpoint === 'sm' ? 21 : 23,
            tint: '#FFFFFF', accessibilityLabel: 'Moonlight 主机' })
        }
        .width(this.breakpoint === 'sm' ? 40 : 42)
        .height(this.breakpoint === 'sm' ? 40 : 42)
        .borderRadius(this.breakpoint === 'sm' ? 12 : 13)
        .backgroundColor(this.accentColor)
        .justifyContent(FlexAlign.Center)
        .margin({ right: this.breakpoint === 'sm' ? 9 : 10 })
        .onClick((): void => {
          this.handleMoonlightHostCardClick(view.host?.id || '');
        })
        Column() {
          Text(view.host.displayName)
            .fontSize(this.breakpoint === 'sm' ? 15 : 16)
            .fontWeight(FontWeight.Medium).fontColor(this.pal().text).fontFamily(this.font())
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(view.catalogItems.length.toString() + ' 个应用')
            .fontSize(this.breakpoint === 'sm' ? 12 : 13)
            .fontColor(this.pal().text2).fontFamily(this.font())
            .margin({ top: 2 }).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          Row() {
            Text('端点').fontSize(11).fontColor(this.pal().text3).width(30)
            Text(this.protectedMoonlightCardValue(view.host, this.moonlightAddressLabel(view.host)))
              .fontSize(this.breakpoint === 'sm' ? 12 : 13)
              .fontColor(this.pal().text2).fontFamily(this.font()).layoutWeight(1)
              .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          }.width('100%').margin({ top: 3 })
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
          .onClick((): void => {
            this.handleMoonlightHostCardClick(view.host?.id || '');
          })
        Column() {
          Row() {
            Button() {
              MoonlightBrandIcon({ iconSize: 18, tint: this.accentColor,
                accessibilityLabel: '应用目录' })
            }
            .width(this.breakpoint === 'sm' ? 38 : 40)
            .height(this.breakpoint === 'sm' ? 38 : 40).borderRadius(19).padding(0)
            .backgroundColor(this.pal().surface).accessibilityText('打开 Moonlight 应用目录')
            .onClick((): void => {
              if (!this.hostSelectionMode) {
                void this.openMoonlightHost(view.host?.id || '', true);
              }
            })
          }
          Row() {
            Button() {
              SymbolGlyph($r('sys.symbol.square_and_pencil')).fontSize(16).fontColor([this.pal().text2])
            }
            .width(36).height(36).borderRadius(18).padding(0).backgroundColor(this.pal().surface)
            .accessibilityText('编辑')
            .onClick((): void => {
              if (!this.hostSelectionMode) { void this.openMoonlightEditSheet(view); }
            })
            Button() {
              SymbolGlyph(view.host.locked === true ? $r('sys.symbol.lock_open') :
                $r('sys.symbol.ohos_lock')).fontSize(16).fontColor([this.pal().text2])
            }
            .width(36).height(36).borderRadius(18).padding(0).backgroundColor(this.pal().surface)
            .margin({ left: 8 }).accessibilityText(view.host.locked === true ? '解锁' : '上锁')
            .onClick((): void => {
              if (!this.hostSelectionMode) { void this.toggleMoonlightLock(view); }
            })
            Button() {
              SymbolGlyph($r('sys.symbol.ohos_trash')).fontSize(16).fontColor([this.pal().danger])
            }
            .width(36).height(36).borderRadius(18).padding(0).backgroundColor(this.pal().surface)
            .margin({ left: 8 }).accessibilityText('删除')
            .onClick((): void => {
              if (!this.hostSelectionMode) { void this.doDeleteMoonlightHost(view); }
            })
          }.margin({ top: 7 })
        }.alignItems(HorizontalAlign.End).margin({ left: 10 })
      }
      .width('100%').height(this.hostGroupHostCardHeight()).padding(6)
      .borderRadius(12).backgroundColor(this.pal().card).backgroundBlurStyle(BlurStyle.Regular)
      .border({ width: 0.5, color: this.pal().cardBorder, style: BorderStyle.Solid })
      .priorityGesture(LongPressGesture({ duration: 450 }).onAction((): void => {
        if (!this.hostSelectionMode) {
          this.beginHostSelection(unifiedMoonlightHostCardKey(view.host?.id || ''), false);
        }
      }))
    }
  }

  @Builder moonlightActionMenuBuilder(view: MoonlightHostLocalView) {
    if (view.host !== null) {
      Column() {
        Row() {
          SymbolGlyph($r('sys.symbol.square_and_pencil')).fontSize(16).fontColor([this.pal().text])
          Text('编辑').fontSize(13).fontColor(this.pal().text).fontFamily(this.font()).margin({ left: 8 })
        }.width('100%').padding({ left: 12, right: 12, top: 8, bottom: 8 })
          .onClick((): void => {
            this.hostActionPopupId = '';
            void this.openMoonlightEditSheet(view);
          })
        Divider().strokeWidth(0.5).color(this.pal().cardBorder).width('100%')
        Row() {
          SymbolGlyph(view.host.locked === true ? $r('sys.symbol.lock_open') : $r('sys.symbol.ohos_lock'))
            .fontSize(16).fontColor([this.pal().text])
          Text(view.host.locked === true ? '解锁' : '上锁').fontSize(13)
            .fontColor(this.pal().text).fontFamily(this.font()).margin({ left: 8 })
        }.width('100%').padding({ left: 12, right: 12, top: 8, bottom: 8 })
          .onClick((): void => {
            this.hostActionPopupId = '';
            void this.toggleMoonlightLock(view);
          })
        Divider().strokeWidth(0.5).color(this.pal().cardBorder).width('100%')
        Row() {
          SymbolGlyph($r('sys.symbol.list_bullet')).fontSize(16).fontColor([this.pal().text])
          Text('多选 / 排序').fontSize(13).fontColor(this.pal().text)
            .fontFamily(this.font()).margin({ left: 8 })
        }.width('100%').padding({ left: 12, right: 12, top: 8, bottom: 8 })
          .onClick((): void => {
            this.hostActionPopupId = '';
            this.beginHostSelection('', true);
          })
        Divider().strokeWidth(0.5).color(this.pal().cardBorder).width('100%')
        Row() {
          SymbolGlyph($r('sys.symbol.ohos_trash')).fontSize(16).fontColor([this.pal().danger])
          Text('删除').fontSize(13).fontColor(this.pal().danger)
            .fontFamily(this.font()).margin({ left: 8 })
        }.width('100%').padding({ left: 12, right: 12, top: 8, bottom: 8 })
          .onClick((): void => {
            this.hostActionPopupId = '';
            void this.doDeleteMoonlightHost(view);
          })
      }.width('100%').padding({ top: 2, bottom: 2 }).borderRadius(12)
    }
  }

  @Builder moonlightEditLockRow(view: MoonlightHostLocalView) {
    if (view.host !== null) {
      Row() {
        Button() {
          SymbolGlyph($r('sys.symbol.square_and_pencil')).fontSize(17).fontColor([Color.White])
        }
        .width(48).height(48).borderRadius(12).backgroundColor(this.pal().editColor)
        .accessibilityText('编辑')
        .onClick((): void => { void this.openMoonlightEditSheet(view); })
        Button() {
          SymbolGlyph($r('sys.symbol.ohos_lock')).fontSize(17).fontColor([Color.White])
        }
        .width(48).height(48).borderRadius(12)
        .backgroundColor(view.host.locked === true ? this.pal().success : this.accentColor)
        .margin({ left: 4 }).accessibilityText(view.host.locked === true ? '解锁' : '上锁')
        .onClick((): void => { void this.toggleMoonlightLock(view); })
      }
      .height('100%').alignItems(VerticalAlign.Center).borderRadius(14)
    }
  }

  @Builder moonlightDeleteBtn(view: MoonlightHostLocalView) {
    Column() {
      SymbolGlyph($r('sys.symbol.ohos_trash')).fontSize(24).fontColor([Color.White])
        .symbolEffect(new PulseSymbolEffect(), true)
        .symbolEffect(new BounceSymbolEffect(EffectScope.WHOLE, EffectDirection.UP), true)
      Text('删除').fontSize(9).fontColor(Color.White).margin({ top: 2 })
    }
    .width(60).height(60).justifyContent(FlexAlign.Center)
    .borderRadius(14).backgroundColor(this.pal().danger)
    .onClick((): void => { void this.doDeleteMoonlightHost(view); })
  }

  private moonlightSheetHost(): MoonlightHost | null {
    const view: MoonlightHostLocalView | null = this.moonlightSheetView();
    return view === null ? null : view.host;
  }

  private moonlightSheetItems(): MoonlightCatalogItem[] {
    const view: MoonlightHostLocalView | null = this.moonlightSheetView();
    return view === null ? [] : view.catalogItems;
  }

  private moonlightSheetRecentListHeight(): number {
    const count: number = Math.min(this.moonlightSheetItems().length, 6);
    // Keep a short sheet when only one or two cached apps exist; a fixed
    // 160vp panel left a conspicuous empty block below the last row.
    return count === 0 ? 68 : Math.min(160, 18 + count * 48);
  }

  @Builder moonlightHostDetailSheet() {
    if (this.moonlightSheetHost() === null) {
      Column() {
        Text('Moonlight 主机已不存在').fontSize(16).fontWeight(FontWeight.Medium)
          .fontColor(this.pal().text)
        Button('关闭').width('100%').height(42).margin({ top: 16 }).borderRadius(11)
          .backgroundColor(this.accentColor).fontColor(Color.White)
          .onClick((): void => { this.closeMoonlightHostSheet(); })
      }.width('100%').padding(22).backgroundColor(this.pal().sheetBg)
    } else {
    Column() {
      Row() {
        Column() {
          MoonlightBrandIcon({ iconSize: 26, tint: '#FFFFFF', accessibilityLabel: 'Moonlight 主机' })
        }.width(48).height(48).borderRadius(14).backgroundColor(this.accentColor)
          .justifyContent(FlexAlign.Center)
        Column() {
          Text(this.moonlightSheetHost()?.displayName || '').fontSize(19).fontWeight(FontWeight.Bold)
            .fontColor(this.pal().text).fontFamily(this.font()).maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text('Moonlight 主机 · ' + this.moonlightAddressLabel(this.moonlightSheetHost() as MoonlightHost))
            .fontSize(11).fontColor(this.pal().text3).fontFamily(this.font())
            .margin({ top: 4 }).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        }.alignItems(HorizontalAlign.Start).layoutWeight(1).margin({ left: 12 })
      }.width('100%')

      Row() {
        Text('地址').fontSize(11).fontColor(this.pal().text3).width(48)
        Text(this.moonlightAddressLabel(this.moonlightSheetHost() as MoonlightHost)).fontSize(13).fontColor(this.pal().text2)
          .fontFamily('monospace').layoutWeight(1).maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }.width('100%').margin({ top: 18 })
      Row() {
        Text('目录').fontSize(11).fontColor(this.pal().text3).width(48)
        Text(this.moonlightSheetItems().length.toString() + ' 个应用 · 本地缓存')
          .fontSize(13).fontColor(this.pal().text2).fontFamily(this.font()).layoutWeight(1)
      }.width('100%').margin({ top: 9 })

      Text('最近使用的应用').fontSize(13).fontWeight(FontWeight.Medium)
        .fontColor(this.pal().text).width('100%').margin({ top: 20, bottom: 8 })
      Scroll() {
        Column() {
          if (this.moonlightSheetItems().length === 0) {
            Text('主机上线后刷新应用目录').fontSize(12).fontColor(this.pal().text3)
              .width('100%').padding({ top: 18, bottom: 18 }).textAlign(TextAlign.Center)
          } else {
            ForEach(this.moonlightSheetItems().slice(0, 6), (item: MoonlightCatalogItem): void => {
              Row() {
                MoonlightBrandIcon({ iconSize: 18, tint: this.accentColor })
                Column() {
                  Text(item.title).fontSize(13).fontColor(this.pal().text)
                    .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                  Text(item.available && !item.stale ? '可用' : '缓存/当前不可用')
                    .fontSize(10)
                    .fontColor(item.available && !item.stale ? this.pal().success : this.pal().text3)
                    .margin({ top: 2 })
                }.alignItems(HorizontalAlign.Start).layoutWeight(1).margin({ left: 10 })
              }.width('100%').height(48).padding({ left: 8, right: 8 })
            }, (item: MoonlightCatalogItem): string => item.id)
          }
        }.width('100%')
      }.width('100%').height(this.moonlightSheetRecentListHeight()).scrollBar(BarState.Off)
        .backgroundColor(this.pal().surface).borderRadius(12)

      Row({ space: 8 }) {
        Button('应用目录').layoutWeight(1).height(42).borderRadius(11)
          .backgroundColor(this.accentColor).fontColor(Color.White)
          .onClick((): void => { this.closeMoonlightHostSheet(true, false); })
        Button('设置').layoutWeight(1).height(42).borderRadius(11)
          .backgroundColor(this.pal().surface).fontColor(this.pal().text2)
          .onClick((): void => { this.closeMoonlightHostSheet(false, true); })
      }.width('100%').margin({ top: 16 })
      Button('关闭').width('100%').height(40).borderRadius(11)
        .backgroundColor(Color.Transparent).fontColor(this.pal().text3)
        .margin({ top: 4 }).onClick((): void => { this.closeMoonlightHostSheet(); })
    }.width('100%').padding({ left: 22, right: 22, top: 20, bottom: 24 })
      .backgroundColor(this.pal().sheetBg)
    }
  }

  @Builder moonlightCatalogSheet() {
    MoonlightAppCatalogSurface({
      embedded: true,
      requestedHostId: this.moonlightSheetHostId,
      onClose: (): void => { this.closeMoonlightCatalogSheet(); },
      onOpenSettings: (): void => { this.closeMoonlightCatalogSheet('settings'); },
      onOpenHostDetail: (): void => { this.closeMoonlightCatalogSheet('detail'); },
      onLaunchRequested: (handoff: MoonlightCatalogLaunchHandoff): void => {
        this.requestMoonlightCatalogLaunch(handoff);
      },
      onDismissAllowedChanged: (allowed: boolean): void => {
        this.moonlightCatalogDismissAllowed = allowed;
      }
    })
  }

  @Builder moonlightEditSheet() {
    Column() {
      Row() {
        Column() {
          MoonlightBrandIcon({ iconSize: 22, tint: '#FFFFFF', accessibilityLabel: 'Moonlight 主机' })
        }.width(42).height(42).borderRadius(12).backgroundColor(this.accentColor)
          .justifyContent(FlexAlign.Center)
        Column() {
          Text('编辑 Moonlight 主机').fontSize(18).fontWeight(FontWeight.Bold)
            .fontColor(this.pal().text).fontFamily(this.font())
          Text('主机信息、连接端点与网络唤醒').fontSize(11)
            .fontColor(this.pal().text3).fontFamily(this.font()).margin({ top: 3 })
        }.alignItems(HorizontalAlign.Start).layoutWeight(1).margin({ left: 12 })
        Button() {
          SymbolGlyph($r('sys.symbol.xmark')).fontSize(16).fontColor([this.pal().text2])
        }.width(34).height(34).borderRadius(17).padding(0).backgroundColor(this.pal().surface)
          .accessibilityText('关闭编辑')
          .onClick((): void => {
            this.beginRemoteHostSheetClose(REMOTE_HOST_SHEET_MOONLIGHT_EDIT);
            this.showRemoteHostSheet = false;
          })
      }.width('100%')

      Scroll() {
        Column() {
          Text('主机名称').fontSize(12).fontColor(this.pal().text2).fontFamily(this.font())
            .width('100%').margin({ bottom: 7 })
          TextInput({ text: this.moonlightEditName, placeholder: 'Moonlight 主机名称' })
            .width('100%').height(44).borderRadius(11).backgroundColor(this.pal().surface)
            .fontColor(this.pal().text).fontFamily(this.font())
            .onChange((value: string): void => {
              this.moonlightEditName = value;
              this.moonlightEditError = '';
            })

          Text('连接端点').fontSize(12).fontColor(this.pal().text2).fontFamily(this.font())
            .width('100%').margin({ top: 16, bottom: 7 })
          Row({ space: 8 }) {
            TextInput({ text: this.moonlightEditAddress, placeholder: '主机名或 IP 地址' })
              .layoutWeight(1).height(44).borderRadius(11).backgroundColor(this.pal().surface)
              .fontColor(this.pal().text).fontFamily(this.font())
              .onChange((value: string): void => {
                this.moonlightEditAddress = value;
                this.moonlightEditError = '';
              })
            TextInput({ text: this.moonlightEditPortText, placeholder: '47989' })
              .width(92).height(44).type(InputType.Number).borderRadius(11)
              .backgroundColor(this.pal().surface).fontColor(this.pal().text).fontFamily(this.font())
              .onChange((value: string): void => {
                this.moonlightEditPortText = value;
                this.moonlightEditError = '';
              })
          }.width('100%')

          Row() {
            Column() {
              Text('HTTPS 控制端口').fontSize(12).fontColor(this.pal().text2).fontFamily(this.font())
              Text('用于鉴权、配对和应用目录').fontSize(10).fontColor(this.pal().text3)
                .fontFamily(this.font()).margin({ top: 3 })
            }.alignItems(HorizontalAlign.Start).layoutWeight(1)
            TextInput({ text: this.moonlightEditHttpsPortText,
              placeholder: MOONLIGHT_DEFAULT_HTTPS_PORT.toString() })
              .width(104).height(40).type(InputType.Number).borderRadius(10)
              .backgroundColor(this.pal().surface).fontColor(this.pal().text).fontFamily(this.font())
              .onChange((value: string): void => {
                this.moonlightEditHttpsPortText = value;
                this.moonlightEditError = '';
              })
          }.width('100%').margin({ top: 14 })

          Text('主机实现').fontSize(12).fontColor(this.pal().text2).fontFamily(this.font())
            .width('100%').margin({ top: 16, bottom: 7 })
          Row({ space: 8 }) {
            Button('Sunshine').layoutWeight(1).height(38).borderRadius(10)
              .backgroundColor(this.moonlightEditHostType === 'sunshine' ?
                this.accentColor : this.pal().surface)
              .fontColor(this.moonlightEditHostType === 'sunshine' ? Color.White : this.pal().text2)
              .onClick((): void => { this.moonlightEditHostType = 'sunshine'; })
            Button('GameStream').layoutWeight(1).height(38).borderRadius(10)
              .backgroundColor(this.moonlightEditHostType === 'gamestream' ?
                this.accentColor : this.pal().surface)
              .fontColor(this.moonlightEditHostType === 'gamestream' ? Color.White : this.pal().text2)
              .onClick((): void => { this.moonlightEditHostType = 'gamestream'; })
          }.width('100%')

          Row() {
            Column() {
              Text('网络唤醒').fontSize(13).fontColor(this.pal().text).fontFamily(this.font())
              Text('保存目标网卡与广播地址').fontSize(10).fontColor(this.pal().text3)
                .fontFamily(this.font()).margin({ top: 3 })
            }.alignItems(HorizontalAlign.Start).layoutWeight(1)
            Toggle({ type: ToggleType.Switch, isOn: this.moonlightEditWakeEnabled })
              .selectedColor(this.accentColor)
              .onChange((enabled: boolean): void => {
                this.moonlightEditWakeEnabled = enabled;
                this.moonlightEditError = '';
              })
          }.width('100%').margin({ top: 18 })
          if (this.moonlightEditWakeEnabled) {
            TextInput({ text: this.moonlightEditWakeMac, placeholder: 'MAC，例如 AA:BB:CC:DD:EE:FF' })
              .width('100%').height(42).borderRadius(10).backgroundColor(this.pal().surface)
              .fontColor(this.pal().text).fontFamily(this.font()).margin({ top: 10 })
              .onChange((value: string): void => { this.moonlightEditWakeMac = value; })
            TextInput({ text: this.moonlightEditWakeBroadcast, placeholder: '广播地址，例如 192.168.1.255' })
              .width('100%').height(42).borderRadius(10).backgroundColor(this.pal().surface)
              .fontColor(this.pal().text).fontFamily(this.font()).margin({ top: 8 })
              .onChange((value: string): void => { this.moonlightEditWakeBroadcast = value; })
          }

          Column() {
            Text('配对身份').fontSize(11).fontColor(this.pal().text3).fontFamily(this.font())
            Text(this.moonlightSheetHost()?.serverUuid || '—').fontSize(11)
              .fontColor(this.pal().text2).fontFamily('monospace').margin({ top: 4 })
              .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          }.alignItems(HorizontalAlign.Start).width('100%').padding(10)
            .borderRadius(10).backgroundColor(this.pal().surface).margin({ top: 14 })

          if (this.moonlightEditError !== '') {
            Text(this.moonlightEditError).fontSize(12).fontColor(this.pal().danger)
              .fontFamily(this.font()).width('100%').margin({ top: 12 })
          }
        }.width('100%')
      }.width('100%').constraintSize({ maxHeight: this.breakpoint === 'sm' ? 520 : 560 })
        .scrollBar(BarState.Auto).edgeEffect(EdgeEffect.Spring).margin({ top: 18 })

      Row({ space: 8 }) {
        Button('取消').layoutWeight(1).height(42).borderRadius(11)
          .backgroundColor(this.pal().surface).fontColor(this.pal().text2)
          .onClick((): void => {
            this.beginRemoteHostSheetClose(REMOTE_HOST_SHEET_MOONLIGHT_EDIT);
            this.showRemoteHostSheet = false;
          })
        Button('保存').layoutWeight(1).height(42).borderRadius(11)
          .backgroundColor(this.accentColor).fontColor(Color.White)
          .enabled(this.moonlightEditName.trim().length > 0 &&
            this.moonlightEditName.trim().length <= 128 && this.moonlightEditAddress.trim().length > 0)
          .onClick((): void => { this.saveMoonlightEdit(); })
      }.width('100%').margin({ top: 20 })
    }.width('100%').padding({ left: 22, right: 22, top: 20, bottom: 24 })
      .backgroundColor(this.pal().sheetBg)
  }

  @Builder moonlightHostCard(view: MoonlightHostLocalView) {
    if (this.groupedHostCardsActive()) {
      this.moonlightGroupedHostCard(view)
    } else {
      this.moonlightFlatHostCard(view)
    }
  }

  @Builder moonlightDirectorySection() {
    Column() {
      ForEach(this.visibleMoonlightHosts(), (view: MoonlightHostLocalView): void => {
        this.moonlightHostCard(view)
        Blank().height(8)
      }, (view: MoonlightHostLocalView): string => this.moonlightHostCardKey(view))
    }.width('100%')
  }

  @Builder moonlightDirectoryContent() {
    Column() {
      Row() {
        Column() {
          Text('Moonlight 主机').fontSize(27).fontWeight(FontWeight.Bold)
            .fontColor(this.pal().text).fontFamily(this.font())
          Text('局域网发现、配对与低延迟串流').fontSize(12).fontColor(this.pal().text3)
            .fontFamily(this.font()).margin({ top: 4 })
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      }.width('100%').padding({ left: 28, right: 28,
        top: this.topSafeHeightVp() + this.titleOffsetY() + 14, bottom: 16 })
      List({ space: 8 }) {
        if (this.moonlightDirectoryCode === 'loading') {
          ListItem() {
            Column() { LoadingProgress().width(32).height(32).color(this.accentColor) }
              .width('100%').height(280).justifyContent(FlexAlign.Center)
          }
        } else if (this.visibleMoonlightHosts().length === 0) {
          ListItem() {
            Column() {
              MoonlightBrandIcon({ iconSize: 48, tint: this.pal().text3 })
              Text(this.moonlightDirectoryCode === 'ok' || this.moonlightDirectoryCode === 'cache_read_failed'
                ? '还没有 Moonlight 主机' : '本地主机数据暂不可用')
                .fontSize(17).fontWeight(FontWeight.Medium).fontColor(this.pal().text).margin({ top: 16 })
              Text('点击底部 + 添加主机，自动发现局域网中的 Sunshine / GameStream')
                .fontSize(12).fontColor(this.pal().text3).margin({ top: 7 }).textAlign(TextAlign.Center)
            }.width('100%').height(360).justifyContent(FlexAlign.Center)
          }
        } else {
          ForEach(this.visibleMoonlightHosts(), (view: MoonlightHostLocalView): void => {
            ListItem() { this.moonlightFlatHostCard(view) }
              .swipeAction((this.hostSelectionMode ||
                (this.isDesktopDevice && this.breakpoint === 'xl')) ? {
                start: { builder: () => {} }, end: { builder: () => {} },
                edgeEffect: SwipeEdgeEffect.Spring
              } : {
                start: { builder: () => { this.moonlightEditLockRow(view); } },
                end: { builder: () => { this.moonlightDeleteBtn(view); } },
                edgeEffect: SwipeEdgeEffect.Spring
              })
          }, (view: MoonlightHostLocalView): string => this.moonlightHostCardKey(view))
        }
        ListItem() { Column().height(110) }
      }.layoutWeight(1).width('100%').padding({ left: 28, right: 28 })
        .scrollBar(BarState.Off).edgeEffect(EdgeEffect.Spring)
    }.width('100%').height('100%')
  }

  @Builder flatRemoteHostListItem(host: RemoteHost) {
    ListItem() {
      Row() {
        if (this.hostSelectionMode) {
          Checkbox()
            .select(this.hostSelectedIds.has(remoteHostCardKey(host.id)))
            .selectedColor(this.accentColor).margin({ right: 8 })
            .onChange((checked: boolean): void => {
              this.toggleHostSelect(remoteHostCardKey(host.id), checked);
            })
        }
        Column() {
          Image(host.protocol === 'ssh' ? $r('app.media.icon_terminal') :
            (host.protocol === 'rdp' ? $r('app.media.icon_desktop') : $r('app.media.icon_laptop')))
            .width(this.breakpoint === 'sm' ? 24 : 26)
            .height(this.breakpoint === 'sm' ? 24 : 26).fillColor(Color.White)
        }
        .width(this.breakpoint === 'sm' ? 42 : 46).height(this.breakpoint === 'sm' ? 42 : 46)
        .borderRadius(this.breakpoint === 'sm' ? 21 : 14)
        .backgroundColor(host.protocol === 'ssh' ? this.pal().editColor :
          (host.protocol === 'rdp' ? this.accentColor : this.pal().success))
        .justifyContent(FlexAlign.Center).margin({ right: this.breakpoint === 'sm' ? 10 : 12 })
        .onClick((): void => { this.handleHostCardClick(host); })

        Column() {
          Row() {
            Text(hostCardDisplayLabel(
              shouldHideHostCardSensitiveInfo(this.hostCardSensitiveInfoHidden, host.locked),
              host.protocol, host.label, host.rustdeskProPeerId, host.customHostname))
              .fontSize(this.breakpoint === 'sm' ? (AppTheme.fontSize.body as number) : 17)
              .fontWeight(FontWeight.Medium).fontColor(this.pal().text).fontFamily(this.font())
              .layoutWeight(1).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
            if (host.protocol === 'ssh' &&
              displayConnectionHealth(host.lastHealth, host.lastLatency).length > 0) {
              Text(displayConnectionHealth(host.lastHealth, host.lastLatency))
                .fontSize(10).fontColor(this.pal().text3).fontFamily(this.font())
                .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                .borderRadius(6).backgroundColor(this.pal().surface).margin({ left: 6 })
            }
            if (host.locked) {
              SymbolGlyph($r('sys.symbol.ohos_lock')).fontSize(this.breakpoint === 'sm' ? 14 : 18)
                .fontColor([this.pal().danger]).margin({ left: this.breakpoint === 'sm' ? 6 : 8 })
            }
          }.width('100%')
          if (!host.locked) {
            Text(this.hostPlatformText(host) + '  ·  ' + this.protectedHostCardValue(host,
              host.protocol === 'rustdesk' ? rustDeskCardEndpoint(host.rustdeskDirectEnabled,
                host.rustdeskDirectHost, host.rustdeskDirectPort, host.host, host.port) :
                host.host + ':' + host.port))
              .fontSize(this.breakpoint === 'sm' ? 12 : 14).fontColor(this.pal().text2)
              .margin({ top: this.breakpoint === 'sm' ? 3 : 4 }).fontFamily(this.font())
              .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          } else {
            Text('已锁定 · 需验证').fontSize(this.breakpoint === 'sm' ? 12 : 13)
              .fontColor(this.pal().text3).margin({ top: this.breakpoint === 'sm' ? 3 : 4 })
              .fontFamily(this.font())
          }
          Row() {
            this.HostGroupChip(host)
            if (host.groupId.length > 0) { Blank().width(6) }
            if (host.protocol !== 'ssh' && host.protocol !== 'rustdesk') {
              this.HostConnectionHealth(host)
            }
          }.margin({ top: 2 })
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
          .onClick((): void => { this.handleHostCardClick(host); })

        Column() {
          if (host.protocol === 'rustdesk') {
            Row() {
              ForEach(resolveRustDeskBadges(host.rustdeskDirectEnabled,
                host.rustdeskProManaged || host.sourceType === 'rustdesk_pro'), (badge: string): void => {
                Text(badge).fontSize(10)
                  .fontColor(badge === 'Pro' ? this.accentColor :
                    (badge === '直连' ? this.pal().success : this.pal().text2))
                  .fontFamily(this.font()).padding({ left: 6, right: 6, top: 2, bottom: 2 })
                  .borderRadius(6).backgroundColor(this.pal().surface).margin({ left: 6 })
              })
            }.justifyContent(FlexAlign.End)
            if (!host.rustdeskDirectEnabled && this.rustdeskPresenceDetectionEnabled) {
              Text(this.rustDeskPresenceStatusText(host)).fontSize(this.breakpoint === 'sm' ? 11 : 12)
                .fontColor(this.rustDeskPresenceStatusColor(host)).fontFamily(this.font()).margin({ top: 3 })
                .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
            }
          }
          if (this.hostSelectionMode && this.hostReorderEnabled) {
            SymbolGlyph($r('sys.symbol.line_3_horizontal')).fontSize(20)
              .fontColor([this.pal().text3]).margin({ left: 8 })
          }
          if (!this.hostSelectionMode && this.isDesktopDevice) {
            Row() {
              if (host.protocol === 'rustdesk' && !host.rustdeskDirectEnabled &&
                this.breakpoint === 'xl') {
                Button() {
                  if (this.hostPresenceProbeBusyIds.has(host.id)) {
                    LoadingProgress().width(18).height(18).color(this.accentColor)
                  } else {
                    SymbolGlyph($r('sys.symbol.bolt_fill')).fontSize(17).fontColor([this.accentColor])
                  }
                }.width(36).height(36).borderRadius(18).padding(0).backgroundColor(this.pal().surface)
                  .accessibilityText('检测 RustDesk 在线状态')
                  .enabled(!this.hostPresenceProbeBusyIds.has(host.id))
                  .onClick((): void => { void this.probeHostConnectivity(host); })
              }
              Button() { Text('⋯').fontSize(18).fontColor(this.pal().text) }
                .width(36).height(36).borderRadius(18).backgroundColor(this.pal().surface)
                .margin({ left: 4 })
                .bindPopup(this.hostActionPopupId === remoteHostCardKey(host.id), {
                  builder: this.hostActionMenuBuilder(host), placement: Placement.BottomRight,
                  enableArrow: true, popupColor: this.pal().card, width: this.hostActionPopupWidth(host),
                  onStateChange: (event: Object): void => {
                    const value: Record<string, boolean> = event as Record<string, boolean>;
                    if (!value['isVisible']) { this.hostActionPopupId = ''; }
                  }
                })
                .onClick((): void => {
                  const key: string = remoteHostCardKey(host.id);
                  this.hostActionPopupId = this.hostActionPopupId === key ? '' : key;
                })
            }
          }
        }.alignItems(HorizontalAlign.End).margin({ left: 6 })
      }
      .width('100%').constraintSize({ minHeight: this.breakpoint === 'sm' ? 66 : 80 })
      .padding(this.breakpoint === 'sm' ? { left: 12, right: 14, top: 12, bottom: 12 } : 14)
      .borderRadius(14).backgroundColor(this.pal().card).backgroundBlurStyle(BlurStyle.Regular)
      .border({ width: 0.5, color: this.pal().cardBorder, style: BorderStyle.Solid })
    }
    .swipeAction((this.hostSelectionMode || (this.isDesktopDevice && this.breakpoint === 'xl')) ? {
      start: { builder: () => {} }, end: { builder: () => {} }, edgeEffect: SwipeEdgeEffect.Spring
    } : {
      start: { builder: () => { this.hostEditLockRow(host); } },
      end: { builder: () => { this.hostDeleteBtn(host); } }, edgeEffect: SwipeEdgeEffect.Spring
    })
    .transition(TransitionEffect.asymmetric(
      TransitionEffect.translate({ x: -200 }).animation({ duration: 250, curve: Curve.FastOutSlowIn }),
      TransitionEffect.translate({ x: -200, y: -10 })
        .combine(TransitionEffect.scale({ x: 0.7, y: 0.7 })).combine(TransitionEffect.OPACITY)
        .animation({ duration: 350, curve: curves.interpolatingSpring(0, 0.8, 300, 20) })
    ))
    .onDragStart((_event: DragEvent): DragItemInfo => {
      const key: string = remoteHostCardKey(host.id);
      if (!this.hostSelectionMode) {
        // Let the platform's native drag recognizer own the initial long
        // press. Entering selection here keeps that same pointer sequence
        // alive so the card can move immediately instead of requiring a
        // second long press after the list rebuilds.
        this.beginHostSelection(key, true, true);
      } else if (!this.hostReorderEnabled) {
        return {};
      }
      this.draggingHostId = key;
      return { extraInfo: key };
    })
    .onDrop((_event: DragEvent): void => {
      const dragging: string = this.draggingHostId;
      this.draggingHostId = '';
      const target: string = remoteHostCardKey(host.id);
      if (this.hostSelectionMode && this.hostReorderEnabled && dragging !== '' && dragging !== target) {
        this.handleHostMove(dragging, target);
      }
    })
    .onDragEnd((_event: DragEvent): void => { this.draggingHostId = ''; })
  }

  @Builder flatMoonlightHostListItem(view: MoonlightHostLocalView) {
    if (view.host !== null) {
      ListItem() { this.moonlightFlatHostCard(view) }
        .swipeAction((this.hostSelectionMode || (this.isDesktopDevice && this.breakpoint === 'xl')) ? {
          start: { builder: () => {} }, end: { builder: () => {} }, edgeEffect: SwipeEdgeEffect.Spring
        } : {
          start: { builder: () => { this.moonlightEditLockRow(view); } },
          end: { builder: () => { this.moonlightDeleteBtn(view); } }, edgeEffect: SwipeEdgeEffect.Spring
        })
        .transition(TransitionEffect.asymmetric(
          TransitionEffect.translate({ x: -200 }).animation({ duration: 250, curve: Curve.FastOutSlowIn }),
          TransitionEffect.translate({ x: -200, y: -10 })
            .combine(TransitionEffect.scale({ x: 0.7, y: 0.7 })).combine(TransitionEffect.OPACITY)
            .animation({ duration: 350, curve: curves.interpolatingSpring(0, 0.8, 300, 20) })
        ))
        .onDragStart((_event: DragEvent): DragItemInfo => {
          const key: string = unifiedMoonlightHostCardKey(view.host?.id || '');
          if (!this.hostSelectionMode) {
            this.beginHostSelection(key, true, true);
          } else if (!this.hostReorderEnabled) {
            return {};
          }
          this.draggingHostId = key;
          return { extraInfo: key };
        })
        .onDrop((_event: DragEvent): void => {
          const dragging: string = this.draggingHostId;
          this.draggingHostId = '';
          const target: string = unifiedMoonlightHostCardKey(view.host?.id || '');
          if (this.hostSelectionMode && this.hostReorderEnabled && dragging !== '' && dragging !== target) {
            this.handleHostMove(dragging, target);
          }
        })
        .onDragEnd((_event: DragEvent): void => { this.draggingHostId = ''; })
    }
  }

  @Builder unifiedFlatHostListItem(ref: UnifiedHostCardRef) {
    if (ref.kind === 'remote' && this.remoteHostForCardRef(ref) !== null) {
      this.flatRemoteHostListItem(this.remoteHostForCardRef(ref) as RemoteHost)
    } else if (ref.kind === 'moonlight' && this.moonlightViewForCardRef(ref) !== null) {
      this.flatMoonlightHostListItem(this.moonlightViewForCardRef(ref) as MoonlightHostLocalView)
    }
  }

  @Builder hostContent() {
    Column() {
      Stack() {
        List({ space: 8 }) {
          // 顶栏占位: 跟随真实系统避让区, 与渐变玻璃层高度一致
          ListItem() { Column().height(this.hostTopBarHeight() + 8) }
          if (!this.groupedHostCardsActive()) {
            ListItem() { this.HostWorkspaceFilterBar() }
          }

        // 批量选择工具栏 (带出入动画)
        if (this.hostSelectionMode) {
          ListItem() {
            // desktop: 按钮全部左移 (侧边栏右侧); 手机/平板: 两端分布
            if (this.isDesktopDevice) {
              Row() {
                Button(this.hostSelectedIds.size === this.selectionKeysForCurrentView().length ? '取消全选' : '全选').fontSize(12)
                  .height(32).borderRadius(8)
                  .backgroundColor(this.pal().surface).fontColor(this.accentColor)
                  .onClick(() => {
                    if (this.hostSelectedIds.size === this.selectionKeysForCurrentView().length) {
                      this.hostSelectedIds = new Set();
                    } else { this.hostSelectedIds = new Set(this.selectionKeysForCurrentView()); }
                  })
                Text('已选 ' + this.hostSelectedIds.size).fontSize(13).fontColor(this.pal().text2)
                  .margin({ left: 12, right: 12 })
                if (this.hostSelectedIds.size > 0) {
                  Button('删除(' + this.hostSelectedIds.size + ')').fontSize(12)
                    .height(32).borderRadius(8)
                    .backgroundColor(this.pal().danger).fontColor('#FFFFFF')
                    .margin({ right: 6 })
                    .onClick(() => { void this.doHostBatchDelete(); })
                }
                if (this.hostReorderEnabled) {
                  Button('完成').fontSize(12).height(32).borderRadius(8)
                    .backgroundColor(this.accentColor).fontColor('#FFFFFF')
                    .margin({ right: 6 })
                    .onClick(() => { this.commitHostReorder(); })
                }
                Button('取消').fontSize(12)
                  .height(32).borderRadius(8)
                  .backgroundColor(this.pal().surface).fontColor(this.pal().text2)
                  .onClick(() => { this.cancelHostEdit(); })
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
                Button(this.hostSelectedIds.size === this.selectionKeysForCurrentView().length ? '取消全选' : '全选').fontSize(12)
                  .height(32).borderRadius(8)
                  .backgroundColor(this.pal().surface).fontColor(this.accentColor)
                  .onClick(() => {
                    if (this.hostSelectedIds.size === this.selectionKeysForCurrentView().length) {
                      this.hostSelectedIds = new Set();
                    } else { this.hostSelectedIds = new Set(this.selectionKeysForCurrentView()); }
                  })
                Blank()
                if (!this.hostReorderEnabled) {
                  Text('已选 ' + this.hostSelectedIds.size).fontSize(13).fontColor(this.pal().text2)
                }
                Blank()
                if (this.hostSelectedIds.size > 0) {
                  Button('删除(' + this.hostSelectedIds.size + ')').fontSize(12)
                    .height(32).borderRadius(8)
                    .backgroundColor(this.pal().danger).fontColor('#FFFFFF')
                    .margin({ right: 6 })
                    .onClick(() => { void this.doHostBatchDelete(); })
                }
                if (this.hostReorderEnabled) {
                  Button('完成').fontSize(12).height(32).borderRadius(8)
                    .backgroundColor(this.accentColor).fontColor('#FFFFFF')
                    .margin({ right: 6 })
                    .onClick(() => { this.commitHostReorder(); })
                }
                Button('取消').fontSize(12)
                  .height(32).borderRadius(8)
                  .backgroundColor(this.pal().surface).fontColor(this.pal().text2)
                  .onClick(() => { this.cancelHostEdit(); })
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
        } else if (this.groupedHostCardsActive()) {
          // Match the classic LazyForEach invalidation boundary: the grouped
          // subtree owns one ListItem, so its key must change at that item
          // rather than only on a nested Column builder.
          ForEach([this.hostViewRevision], (_revision: number): void => {
            ListItem() { this.hostGroupedContent() }
          }, (revision: number): string => 'host-grouped-item-' + revision.toString())
        } else if (this.flatHostCardRefs().length === 0) {
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
        } else if (!this.groupedHostCardsActive()) {
          ForEach(this.flatHostCardRefs(), (ref: UnifiedHostCardRef): void => {
            this.unifiedFlatHostListItem(ref)
          }, (ref: UnifiedHostCardRef): string =>
            ref.key + ':' + this.hostViewRevision.toString())
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
          // xl: 标题和搜索框同排，标题固定在内容区左侧，搜索框靠右。
          if (this.breakpoint === 'xl') {
            Column() {
              Row().width('100%').height(this.topSafeHeightVp() + this.titleOffsetY())
              Row() {
                Text(this.hostPageTitle).fontSize(27).fontWeight(FontWeight.Bold)
                  .fontColor(this.pal().text).fontFamily(this.font()).layoutWeight(1)
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
                      this.refreshFilteredHostView();
                    })
                }
              }.width('50%').constraintSize({ maxWidth: 480 })
                .height(44).borderRadius(22)
                .backgroundColor(this.pal().card).backgroundBlurStyle(BlurStyle.Regular)
                .alignItems(VerticalAlign.Center)
                .shadow({ radius: 12, color: 'rgba(0,0,0,0.06)', offsetY: 2 })
                .border({ width: 0.5, color: this.pal().cardBorder, style: BorderStyle.Solid })
              }.width('100%').height(52).padding({ left: 8, right: 8, bottom: 8 })
            }.width('100%').backgroundColor(Color.Transparent)
          } else {
            Column() {
              Row().width('100%').height(this.topSafeHeightVp() + this.titleOffsetY())
              Row() {
                Text(this.hostPageTitle).fontSize(27).fontWeight(FontWeight.Bold)
                  .fontColor(this.pal().text).fontFamily(this.font())
              }.width('100%').padding({ left: 24, right: 24, bottom: 8 })
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
                      this.refreshFilteredHostView();
                    })
                }
              }.width('92%')
                .height(44).borderRadius(22)
                .backgroundColor(this.pal().card).backgroundBlurStyle(BlurStyle.Regular)
                .alignItems(VerticalAlign.Center)
                .shadow({ radius: 12, color: 'rgba(0,0,0,0.06)', offsetY: 2 })
                .border({ width: 0.5, color: this.pal().cardBorder, style: BorderStyle.Solid })
            }.width('100%').backgroundColor(Color.Transparent)
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
    this.openSheetSafely((): void => {
      this.openRemoteHostSheet(REMOTE_HOST_SHEET_PUBLIC_KEY, (): void => {
        this.showSshPublicKeyInstallSheet = true;
      });
    });
  }

  private closeSshPublicKeyInstallSheet(): void {
    this.beginRemoteHostSheetClose(REMOTE_HOST_SHEET_PUBLIC_KEY);
    this.showSshPublicKeyInstallSheet = false;
    this.showRemoteHostSheet = false;
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
  private hostActionPopupWidth(host: RemoteHost): number {
    const labels: string[] = ['编辑', host.locked ? '解锁' : '上锁', '多选 / 排序', '删除'];
    if (host.protocol === 'ssh') { labels.push('部署公钥'); }
    if (!isVncHostProjection(host)) {
      labels.push(host.groupId === 'ops' ? '移出工作组' : '加入 ops 工作组');
    }
    let longestTextVp: number = 0;
    const uiContext = this.getUIContext();
    labels.forEach((label: string): void => {
      const measuredPx: number = uiContext.getMeasureUtils().measureText({
        textContent: label,
        fontSize: 13,
        fontFamily: this.font()
      });
      longestTextVp = Math.max(longestTextVp, uiContext.px2vp(measuredPx));
    });
    // Popup shell padding + row padding + 16vp icon + 8vp text gap.
    return Math.ceil(longestTextVp + 64);
  }

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
        Text('多选 / 排序').fontSize(13).fontColor(this.pal().text).fontFamily(this.font()).margin({ left: 8 })
      }
      .width('100%').padding({ left: 12, right: 12, top: 8, bottom: 8 })
      .onClick(() => {
        animateTo({ duration: 150 }, () => { this.hostActionPopupId = ''; });
        this.beginHostSelection('', !this.groupedHostCardsActive());
      })

      Divider().strokeWidth(0.5).color(this.pal().cardBorder).width('100%')

      if (!isVncHostProjection(host)) {
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
      }

      Row() {
        SymbolGlyph($r('sys.symbol.ohos_trash'))
          .fontSize(16).fontColor([this.pal().danger])
        Text('删除').fontSize(13).fontColor(this.pal().danger).fontFamily(this.font()).margin({ left: 8 })
      }
      .width('100%').padding({ left: 12, right: 12, top: 8, bottom: 8 })
      .onClick(() => { animateTo({ duration: 150 }, () => { this.hostActionPopupId = ''; }); this.doDeleteHost(host); })
    }
    .width('100%').padding({ top: 2, bottom: 2 }).borderRadius(12)
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

      if (host.protocol === 'rustdesk' && !host.rustdeskDirectEnabled) {
        Button() {
          if (this.hostPresenceProbeBusyIds.has(host.id)) {
            LoadingProgress().width(22).height(22).color(Color.White)
          } else {
            SymbolGlyph($r('sys.symbol.bolt_fill'))
              .fontSize(18)
              .fontColor([Color.White])
          }
        }
        .width(48).height(48).borderRadius(12)
        .backgroundColor(this.accentColor)
        .margin({ left: 4 })
        .accessibilityText('检测 RustDesk 在线状态')
        .enabled(!this.hostPresenceProbeBusyIds.has(host.id))
        .onClick((): void => { void this.probeHostConnectivity(host); })
      }

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
  private isVncSettingsLeafSheet(): boolean {
    return this.settingsLeafSheetMode >= SETTINGS_SHEET_VNC_CONNECTION &&
      this.settingsLeafSheetMode <= SETTINGS_SHEET_VNC_CLIPBOARD;
  }

  private isMoonlightSettingsLeafSheet(): boolean {
    return moonlightSettingsRouteSpec(this.settingsLeafSheetMode) !== null;
  }

  private isVirtualKeyboardSettingsLeafSheet(): boolean {
    return isVirtualKeyboardSettingsMode(this.settingsLeafSheetMode);
  }

  private virtualKeyboardSettingsSectionForLeaf(): VirtualKeyboardSettingsSection {
    const spec: VirtualKeyboardSettingsRouteSpec | null =
      virtualKeyboardSettingsRouteSpec(this.settingsLeafSheetMode);
    return spec === null ? 'system' : spec.section;
  }

  private moonlightSettingsSectionForLeaf(): MoonlightSettingsSection {
    const spec: MoonlightSettingsRouteSpec | null =
      moonlightSettingsRouteSpec(this.settingsLeafSheetMode);
    if (spec === null) { return 'video'; }
    return spec.section as MoonlightSettingsSection;
  }

  private settingsLeafSheetHeight(): SheetSize | number {
    if (this.settingsLeafSheetMode === SETTINGS_SHEET_POPUP && this.popupSheetMode === 1 &&
      this.aboutSheetMode === 3) {
      return SheetSize.LARGE;
    }
    if (this.settingsLeafSheetMode === SETTINGS_SHEET_POPUP && this.popupSheetMode === 1 &&
      this.aboutSheetMode === 5) {
      // The operation guide owns its measured height. FIT_CONTENT lets it
      // shrink for short lessons and grow only up to the live window.
      return SheetSize.FIT_CONTENT;
    }
    // Virtual-keyboard leaves own their scrolling body. Let the native large
    // sheet follow the current phone, tablet, or freeform-window height.
    if (this.isVirtualKeyboardSettingsLeafSheet()) {
      return SheetSize.LARGE;
    }
    const diagnosticHeight: number = diagnosticLogSettingsLeafSheetHeight(this.settingsLeafSheetMode);
    if (diagnosticHeight > 0) { return diagnosticHeight; }
    const moonlightHeight: number = moonlightSettingsLeafSheetHeight(this.settingsLeafSheetMode);
    if (moonlightHeight > 0) { return moonlightHeight; }
    const vncHeight: number = vncSettingsLeafSheetHeight(this.settingsLeafSheetMode);
    return vncHeight > 0 ? vncHeight : SheetSize.FIT_CONTENT;
  }

  private settingsLeafKeyboardAvoidMode(): SheetKeyboardAvoidMode {
    return this.isVncSettingsLeafSheet()
      ? SheetKeyboardAvoidMode.RESIZE_ONLY
      : SheetKeyboardAvoidMode.TRANSLATE_AND_SCROLL;
  }

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
    } else if (this.settingsLeafSheetMode === SETTINGS_SHEET_TERMINAL_LINE_SPACING) {
      this.terminalLineSpacingSheet()
    } else if (this.settingsLeafSheetMode === SETTINGS_SHEET_POPUP) {
      this.unifiedPopupSheet()
    } else if (this.settingsLeafSheetMode === SETTINGS_SHEET_RDP_CREDENTIALS) {
      this.rdpCredentialSheet()
    } else if (this.settingsLeafSheetMode === SETTINGS_SHEET_RDP_CREDENTIAL_EDITOR) {
      this.rdpCredentialEditorSheet()
    } else if (this.settingsLeafSheetMode === SETTINGS_SHEET_KEY_VAULT) {
      this.keyVaultSheet()
    } else if (this.settingsLeafSheetMode === SETTINGS_SHEET_DIAGNOSTIC_LOG) {
      DiagnosticCaptureSettingsSheet({
        onClose: (): void => { this.closeSettingsLeafSheet(); }
      })
    } else if (this.settingsLeafSheetMode === SETTINGS_SHEET_FEEDBACK) {
      FeedbackSettingsSheet({
        onClose: (): void => { this.closeSettingsLeafSheet(); },
        onOpenMail: (): void => { this.openFeedbackEmail(); }
      })
    } else if (this.isVirtualKeyboardSettingsLeafSheet()) {
      VirtualKeyboardSettingsSheet({
        requestedSection: this.virtualKeyboardSettingsSectionForLeaf(),
        onClose: (): void => { this.closeSettingsLeafSheet(); }
      })
    } else if (this.isMoonlightSettingsLeafSheet()) {
      MoonlightSettingsSurface({
        embedded: true,
        requestedSection: this.moonlightSettingsSectionForLeaf(),
        requestedHostId: this.moonlightSettingsLeafHostId,
        onClose: (): void => {
          this.dismissSettingsLeafIfNeeded((): void => { this.closeSettingsLeafSheet(); });
        },
        onDirtyChanged: (dirty: boolean): void => { this.moonlightSettingsLeafDirty = dirty; }
      })
    } else if (this.settingsLeafSheetMode >= SETTINGS_SHEET_VNC_CONNECTION &&
      this.settingsLeafSheetMode <= SETTINGS_SHEET_VNC_CLIPBOARD) {
      VncSettingsSheet({
        mode: this.settingsLeafSheetMode,
        onClose: (): void => {
          this.dismissSettingsLeafIfNeeded((): void => { this.closeSettingsLeafSheet(); });
        },
        onOpenHostManager: (): void => { this.openVncHostManagerFromSettings(); },
        onOpenGatewayManager: (): void => { this.openVncGatewayManagerFromSettings(); },
        onOpenTrustManager: (): void => { this.openVncTrustManagerFromSettings(); },
        onSaved: (): void => { this.refreshCryptoStatus(); },
        onReverseWheelSaved: (reverse: boolean): void => {
          this.saveRemoteReverseWheel(reverse);
        },
        onDirtyChanged: (dirty: boolean): void => { this.vncSettingsLeafDirty = dirty; }
      })
    } else {
      Column().width('100%').height(1)
    }
  }

  @Builder settingsAccordionHeader(section: string, icon: Resource, title: string, subtitle: string,
    terminalStyle: boolean = false, moonlightStyle: boolean = false) {
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

        if (moonlightStyle) {
          MoonlightBrandIcon({
            iconSize: 21,
            tint: this.settingsSectionExpanded(section) ? this.accentColor : this.pal().text,
            accessibilityLabel: 'Moonlight'
          })
        } else if (terminalStyle) {
          Image($r('app.media.icon_terminal'))
            .width(21).height(21).fillColor(this.pal().text)
            .opacity(this.settingsSectionExpanded(section) ? 0 : 1)
            .scale({ x: this.settingsSectionExpanded(section) ? 0.92 : 1,
              y: this.settingsSectionExpanded(section) ? 0.92 : 1 })
            .animation({ duration: SETTINGS_ACCORDION_ANIMATION_MS, curve: Curve.FastOutSlowIn })
          Image($r('app.media.icon_terminal'))
            .width(21).height(21).fillColor(this.accentColor)
            .opacity(this.settingsSectionExpanded(section) ? 1 : 0)
            .scale({ x: this.settingsSectionExpanded(section) ? 1 : 0.92,
              y: this.settingsSectionExpanded(section) ? 1 : 0.92 })
            .animation({ duration: SETTINGS_ACCORDION_ANIMATION_MS, curve: Curve.FastOutSlowIn })
        } else {
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
            '个性化', '主题色、深色模式、壁纸与光晕')
        }.width('100%').padding({ left: 20, right: 20 }).margin({ bottom: 10 })

        // --- 个性化卡片 ---
        ListItem() {
          Column() {
            Text('个性化').fontSize(13).fontWeight(FontWeight.Medium).fontColor(this.pal().text3)
              .fontFamily(this.font()).padding({ left: 8, bottom: 8 })
            Column() {
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
                Row() { SymbolGlyph($r('sys.symbol.eye_slash')).fontSize(22).fontColor([this.pal().text]) }
                  .width(22).height(22).justifyContent(FlexAlign.Center).margin({ left: 9, right: 9 })
                Column() {
                  Text('隐藏主机卡片敏感信息').fontSize(AppTheme.fontSize.body)
                    .fontWeight(FontWeight.Medium).fontColor(this.pal().text).fontFamily(this.font())
                  Text('隐藏地址、端口、用户名和 RustDesk ID；自定义主机名称仍显示')
                    .fontSize(11).fontColor(this.pal().text3).fontFamily(this.font())
                }.alignItems(HorizontalAlign.Start).layoutWeight(1).margin({ left: 4 })
                Toggle({ type: ToggleType.Switch, isOn: this.hostCardSensitiveInfoHidden })
                  .selectedColor(this.accentColor).scale({ x: 0.88, y: 0.88 })
                  .onChange((on: boolean): void => { this.saveHostCardSensitiveInfoHidden(on); })
              }.width('100%').height(66).padding({ left: 16, right: 16 })
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
          this.settingsAccordionHeader(SETTINGS_SECTION_HOME, $r('sys.symbol.list_bullet'),
            '主页与主机列表', '添加入口、主机分组与 RustDesk 在线检测')
        }.width('100%').padding({ left: 20, right: 20 }).margin({ bottom: 10 })

        ListItem() {
          Column() {
            Text('主页与主机列表').fontSize(13).fontWeight(FontWeight.Medium).fontColor(this.pal().text3)
              .fontFamily(this.font()).padding({ left: 8, bottom: 8 })
            Column() {
              this.rustdeskSwitchRow($r('app.media.icon_laptop'), 'RustDesk 在线检测',
                this.rustdeskPresenceDetectionEnabled ? '打开主页时自动检测非直连主机；卡片仍可手动检测' : '已关闭自动检测，可在主机卡片上手动检测',
                this.rustdeskPresenceDetectionEnabled,
                (on: boolean): void => { this.saveRustDeskPresenceDetection(on); })
              this.cardDivider()
              Column() {
                Row() {
                  Row() { SymbolGlyph($r('sys.symbol.plus_circle_fill')).fontSize(22).fontColor([this.pal().text]) }
                    .width(22).height(22).justifyContent(FlexAlign.Center).margin({ left: 9, right: 9 })
                  Column() {
                    Text('添加 FAB 风格').fontSize(AppTheme.fontSize.body).fontWeight(FontWeight.Medium)
                      .fontColor(this.pal().text).fontFamily(this.font())
                    Text('控制添加主机、SSH 密钥、2FA 和中继服务器的界面风格')
                      .fontSize(11).fontColor(this.pal().text3).fontFamily(this.font())
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
              Row() {
                Row() { SymbolGlyph($r('sys.symbol.list_bullet')).fontSize(22).fontColor([this.pal().text]) }
                  .width(22).height(22).justifyContent(FlexAlign.Center).margin({ left: 9, right: 9 })
                Column() {
                  Text('按主机类型分组').fontSize(AppTheme.fontSize.body).fontWeight(FontWeight.Medium)
                    .fontColor(this.pal().text).fontFamily(this.font())
                  Text('手机、Pad 和 PC 小屏按协议显示分类卡；PC 大屏保留侧栏分类')
                    .fontSize(11).fontColor(this.pal().text3).fontFamily(this.font())
                }.alignItems(HorizontalAlign.Start).layoutWeight(1).margin({ left: 4 })
                Toggle({ type: ToggleType.Switch, isOn: this.groupedHostCards })
                  .selectedColor(this.accentColor).scale({ x: 0.88, y: 0.88 })
                  .onChange((on: boolean): void => { this.saveGroupedHostCards(on); })
              }.width('100%').height(66).padding({ left: 16, right: 16 })
            }.borderRadius(24).backgroundColor(this.pal().card).backgroundBlurStyle(BlurStyle.Regular)
              .shadow({ radius: 16, color: 'rgba(0,0,0,0.04)', offsetY: 4 })
              .border({ width: 0.5, color: this.pal().cardBorder, style: BorderStyle.Solid })
          }.width('100%').padding({ left: 20, right: 20 }).margin({ bottom: 20 })
        }
        .constraintSize({ maxHeight: this.settingsSectionExpanded(SETTINGS_SECTION_HOME) ? 520 : 0 })
        .opacity(this.settingsSectionExpanded(SETTINGS_SECTION_HOME) ? 1 : 0)
        .scale({ x: 1, y: this.settingsSectionExpanded(SETTINGS_SECTION_HOME) ? 1 : 0.98 })
        .translate({ y: this.settingsSectionExpanded(SETTINGS_SECTION_HOME) ? 0 : -8 })
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
                  Text(cloudSyncDetailSpec(this.cloudConnectionAvailable).statusText).fontSize(11).fontColor(this.pal().text3).fontFamily(this.font())
                }.alignItems(HorizontalAlign.Start).layoutWeight(1).margin({ left: 12 })
                SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(16).fontColor([this.pal().text3])
              }.width('100%').height(68).padding({ left: 14, right: 16 }).onClick((): void => { this.openCloudSyncSheet(); })
              this.cardDivider()
              Row() {
                Row() { SymbolGlyph($r('sys.symbol.info_circle')).fontSize(20).fontColor([this.accentColor]) }
                  .width(40).height(40).borderRadius(20).backgroundColor(this.pal().card).justifyContent(FlexAlign.Center)
                Column() { Text('云同步详情').fontSize(AppTheme.fontSize.body).fontWeight(FontWeight.Medium).fontColor(this.pal().text).fontFamily(this.font());
                  Text(cloudSyncDetailSpec(this.cloudConnectionAvailable).statusText).fontSize(11).fontColor(this.pal().text3).fontFamily(this.font())
                }.alignItems(HorizontalAlign.Start).layoutWeight(1).margin({ left: 12 })
                SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(16).fontColor([this.pal().text3])
              }.width('100%').height(68).padding({ left: 14, right: 16 }).onClick((): void => { this.openCloudSyncDetailsSheet(); })
              this.cardDivider()
              Row() {
                Row() { SymbolGlyph($r('sys.symbol.doc_plaintext')).fontSize(20).fontColor([this.accentColor]) }
                  .width(40).height(40).borderRadius(20).backgroundColor(this.pal().card).justifyContent(FlexAlign.Center)
                Column() { Text('本地备份').fontSize(AppTheme.fontSize.body).fontWeight(FontWeight.Medium).fontColor(this.pal().text).fontFamily(this.font());
                  Text('可导出脱敏配置或完整备份；VNC trust 只作为候选元数据，本机确认标记不导出').fontSize(11).fontColor(this.pal().text3).fontFamily(this.font())
                }.alignItems(HorizontalAlign.Start).layoutWeight(1).margin({ left: 12 })
                SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(16).fontColor([this.pal().text3])
              }.width('100%').height(68).padding({ left: 14, right: 16 })
                .onClick((): void => { this.openCloudSyncSheet(CLOUD_SYNC_SHEET_BACKUP_CONFIRM); })
              this.cardDivider()
              Row() {
                Row() { SymbolGlyph($r('sys.symbol.doc')).fontSize(20).fontColor([this.pal().danger]) }
                  .width(40).height(40).borderRadius(20).backgroundColor(this.pal().card).justifyContent(FlexAlign.Center)
                Column() { Text('从本地恢复').fontSize(AppTheme.fontSize.body).fontWeight(FontWeight.Medium).fontColor(this.pal().text).fontFamily(this.font());
                  Text('校验 v1/v2/v3 文件并安全合并；缺表不会清空新版数据').fontSize(11).fontColor(this.pal().text3).fontFamily(this.font())
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
              this.protocolStatItemRow(protocolIcon('rdp'), '远程主机', this.hostCount + ' 台')
              this.cardDivider()
              this.protocolStatItemRow(protocolIcon('rdp'), 'RDP 协议', this.rdpCount + ' 台')
              this.cardDivider()
              this.protocolStatItemRow(protocolIcon('rustdesk'), 'RustDesk 协议', this.rustdeskCount + ' 台')
              this.cardDivider()
              this.protocolStatItemRow(protocolIcon('ssh'), 'SSH 终端', this.sshCount + ' 台')
              this.cardDivider()
              this.protocolStatItemRow(protocolIcon('vnc'), 'VNC 主机', this.vncCount + ' 台')
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
              this.liveViewModeRow('画中画模式',
                '应用退到后台时优先进入 VIDEO_PLAY 画中画，并同步系统媒体控制胶囊',
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
            '显示与交互', '本地缩放、滚轮方向与会话控制栏')
        }.width('100%').padding({ left: 20, right: 20 }).margin({ bottom: 10 })

        ListItem() {
          Column() {
            Text('显示与交互').fontSize(13).fontWeight(FontWeight.Medium).fontColor(this.pal().text3)
              .fontFamily(this.font()).padding({ left: 8, bottom: 8 })
            Column() {
              this.remoteDisplayScaleRow()
              this.cardDivider()
              this.remoteWheelDirectionRow()
              this.cardDivider()
              this.sessionControlBarVisibilityRow()
              if (!this.isDesktopDevice) {
                this.cardDivider()
                this.canvasGestureZoomRow()
                this.cardDivider()
                Column() {
                  Row() {
                    Row() { Text('⌖').fontSize(22).fontColor(this.pal().text) }
                      .width(22).height(22).justifyContent(FlexAlign.Center).margin({ left: 9, right: 9 })
                    Column() {
                      Text('触控板鼠标样式').fontSize(AppTheme.fontSize.body).fontWeight(FontWeight.Medium)
                        .fontColor(this.pal().text).fontFamily(this.font())
                      Text('手机和平板触控板模式，选择圆环或官方远端鼠标').fontSize(11)
                        .fontColor(this.pal().text3).fontFamily(this.font())
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
                  Row() { SymbolGlyph($r('sys.symbol.person_2_fill')).fontSize(22).fontColor([this.pal().text]) }
                    .width(22).height(22).justifyContent(FlexAlign.Center).margin({ left: 9, right: 9 })
                  Column() {
                    Text('握持手感知对齐').fontSize(AppTheme.fontSize.body).fontWeight(FontWeight.Medium)
                      .fontColor(this.pal().text).fontFamily(this.font())
                    Text(this.gripPermissionGranted ? '已启用；根据握持手移动添加按钮' : '启动后自动申请权限，不影响主机列表显示')
                      .fontSize(11).fontColor(this.pal().text3).fontFamily(this.font())
                  }.alignItems(HorizontalAlign.Start).layoutWeight(1).margin({ left: 4 })
                  Text(this.gripPermissionGranted ? '已开启' : '启动申请')
                    .fontSize(12).fontColor(this.accentColor).fontFamily(this.font()).margin({ right: 8 })
                }.width('100%').height(62).padding({ left: 16, right: 16 })
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
          this.settingsAccordionHeader(SETTINGS_SECTION_VIRTUAL_KEYBOARD,
            $r('sys.symbol.keyboard'), '虚拟键盘',
            'HarmonyOS 输入法、Windows/macOS 组合键、功能键与自定义')
        }.width('100%').padding({ left: 20, right: 20 }).margin({ bottom: 10 })

        ListItem() {
          Column() {
            Text('虚拟键盘').fontSize(13).fontWeight(FontWeight.Medium)
              .fontColor(this.pal().text3).fontFamily(this.font()).padding({ left: 8, bottom: 8 })
            Column() {
              this.cardActionRow($r('app.media.icon_phone'), '系统输入法',
                '当前输入法、语言子类型与 HarmonyOS 官方设置',
                (): void => { this.openSettingsLeafSheet(SETTINGS_SHEET_VIRTUAL_KEYBOARD); })
              this.cardDivider()
              this.protocolActionRow($r('sys.symbol.keyboard'), '输入行为',
                '精简键盘、文本发送与候选预编辑规则',
                (): void => { this.openSettingsLeafSheet(SETTINGS_SHEET_VIRTUAL_KEYBOARD_BEHAVIOR); })
              this.cardDivider()
              this.cardActionRow($r('app.media.icon_desktop'), '快捷键平台',
                'Windows 与 macOS 默认组合键语义',
                (): void => { this.openSettingsLeafSheet(SETTINGS_SHEET_VIRTUAL_KEYBOARD_SHORTCUTS); })
              this.cardDivider()
              this.cardActionRow($r('app.media.icon_info'), '功能键与面板',
                'F1–F12、导航键、连续发送与面板触控',
                (): void => { this.openSettingsLeafSheet(SETTINGS_SHEET_VIRTUAL_KEYBOARD_FUNCTIONS); })
              this.cardDivider()
              this.cardActionRow($r('app.media.icon_palette'), '自定义组合键',
                '创建、编辑与删除跨连接复用的快捷键',
                (): void => { this.openSettingsLeafSheet(SETTINGS_SHEET_VIRTUAL_KEYBOARD_CUSTOM); })
            }.borderRadius(24).backgroundColor(this.pal().card)
              .backgroundBlurStyle(BlurStyle.Regular)
              .shadow({ radius: 16, color: 'rgba(0,0,0,0.04)', offsetY: 4 })
              .border({ width: 0.5, color: this.pal().cardBorder, style: BorderStyle.Solid })
          }.width('100%').padding({ left: 20, right: 20 }).margin({ bottom: 20 })
        }
        .constraintSize({ maxHeight: this.settingsSectionExpanded(SETTINGS_SECTION_VIRTUAL_KEYBOARD) ?
          this.settingsSectionExpandedMaxHeight(SETTINGS_SECTION_VIRTUAL_KEYBOARD) : 0 })
        .opacity(this.settingsSectionExpanded(SETTINGS_SECTION_VIRTUAL_KEYBOARD) ? 1 : 0)
        .scale({ x: 1, y: this.settingsSectionExpanded(SETTINGS_SECTION_VIRTUAL_KEYBOARD) ? 1 : 0.98 })
        .translate({ y: this.settingsSectionExpanded(SETTINGS_SECTION_VIRTUAL_KEYBOARD) ? 0 : -8 })
        .clip(true)
        .animation({ duration: SETTINGS_ACCORDION_ANIMATION_MS, curve: Curve.FastOutSlowIn })

        ListItem() {
          this.settingsAccordionHeader(SETTINGS_SECTION_RDP, protocolIcon('rdp'),
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
              this.rustdeskSwitchRow($r('app.media.icon_info'), 'TLS 兼容登录',
                '仅用于已取消强制 NLA 的 Windows；直连密码登录，安全性低于 NLA',
                this.rdpTlsWithoutNla,
                (on: boolean): void => { this.saveRdpTlsWithoutNla(on); }, true)
              this.cardDivider()
              this.rustdeskSwitchRow($r('app.media.icon_audio'), '远端音频',
                '播放 Windows 远端会话声音', this.rdpAudioEnabled,
                (on: boolean): void => { this.saveRdpAudioEnabled(on); }, true)
              this.cardDivider()
              this.rustdeskSwitchRow($r('app.media.icon_desktop'), '剪贴板同步',
                '连接时启用文本剪贴板通道', this.rdpClipboardEnabled,
                (on: boolean): void => { this.saveRdpClipboardEnabled(on); }, true)
              this.cardDivider()
              this.rustdeskSwitchRow($r('app.media.icon_info'), '性能监视与诊断日志',
                '连接后显示送显、队列和 GFX 指标，并写入 hilog', this.rdpShowDiagnostics,
                (on: boolean): void => { this.saveRdpShowDiagnostics(on); }, true)
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
          this.settingsAccordionHeader(SETTINGS_SECTION_RUSTDESK, protocolIcon('rustdesk'),
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
          this.settingsAccordionHeader(SETTINGS_SECTION_SSH, protocolIcon('ssh'),
            'SSH 终端', '终端显示、SSH 主机与密钥', true)
        }.width('100%').padding({ left: 20, right: 20 }).margin({ bottom: 10 })

        // --- SSH 终端卡片 ---
        ListItem() {
          Column() {
            Text('SSH 终端').fontSize(13).fontWeight(FontWeight.Medium).fontColor(this.pal().text3)
              .fontFamily(this.font()).padding({ left: 8, bottom: 8 })
            Column() {
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
              Row() {
                Row() { Text('T').fontSize(14).fontColor(this.pal().text).fontWeight(FontWeight.Bold) }
                  .width(22).height(22).justifyContent(FlexAlign.Center).margin({ left: 9, right: 9 })
                Text('终端字体大小').fontSize(AppTheme.fontSize.body).fontWeight(FontWeight.Medium)
                  .fontColor(this.pal().text).fontFamily(this.font()).layoutWeight(1).margin({ left: 4 })
                Text(this.terminalFontSize + 'vp').fontSize(13).fontColor(this.pal().text2)
                Text(' >').fontSize(14).fontColor(this.pal().text3).margin({ left: 6 })
              }.width('100%').height(60).padding({ left: 16, right: 16 })
                .onClick(() => { this.openSettingsLeafSheet(SETTINGS_SHEET_TERMINAL_FONT_SIZE); })
              this.cardDivider()
              Row() {
                Row() {
                  Column() {
                    SymbolGlyph($r('sys.symbol.arrow_up')).fontSize(9).fontColor([this.pal().text])
                    SymbolGlyph($r('sys.symbol.arrow_down')).fontSize(9).fontColor([this.pal().text])
                  }
                }
                  .width(22).height(22).justifyContent(FlexAlign.Center).margin({ left: 9, right: 9 })
                Text('终端行距').fontSize(AppTheme.fontSize.body).fontWeight(FontWeight.Medium)
                  .fontColor(this.pal().text).fontFamily(this.font()).layoutWeight(1).margin({ left: 4 })
                Text(this.terminalLineSpacingLabel()).fontSize(13).fontColor(this.pal().text2)
                Text(' >').fontSize(14).fontColor(this.pal().text3).margin({ left: 6 })
              }.width('100%').height(60).padding({ left: 16, right: 16 })
                .onClick(() => { this.openSettingsLeafSheet(SETTINGS_SHEET_TERMINAL_LINE_SPACING); })
              this.cardDivider()
              Row() {
                Column() {
                  Text('新 SSH 工作台').fontSize(AppTheme.fontSize.body)
                    .fontWeight(FontWeight.Medium).fontColor(this.pal().text).fontFamily(this.font())
                  Text('启用终端搜索、命名 Profile 与后续分屏能力；关闭时沿用现有终端')
                    .fontSize(11).fontColor(this.pal().text3).fontFamily(this.font())
                    .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
                }.alignItems(HorizontalAlign.Start).layoutWeight(1).margin({ left: 16 })
                Toggle({ type: ToggleType.Switch, isOn: this.sshWorkbenchEnabled })
                  .selectedColor(this.accentColor)
                  .onChange((enabled: boolean): void => {
                    this.saveSshWorkbenchEnabled(enabled);
                  })
              }.width('100%').height(66).padding({ right: 16 })
              this.cardDivider()
              Row() {
                Column() {
                  Text('SSH 系统通知').fontSize(AppTheme.fontSize.body)
                    .fontWeight(FontWeight.Medium).fontColor(this.pal().text).fontFamily(this.font())
                  Text('用于后台连接与命令完成提醒；不显示命令、IP、用户名或路径')
                    .fontSize(11).fontColor(this.pal().text3).fontFamily(this.font())
                    .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
                }.alignItems(HorizontalAlign.Start).layoutWeight(1).margin({ left: 16 })
                Button(this.sshSystemNotificationsEnabled ? '已开启' :
                  (this.sshNotificationAuthorizationPending ? '请求中' : '开启'))
                  .height(32).fontSize(12).borderRadius(8)
                  .fontColor(this.sshSystemNotificationsEnabled ? this.pal().text3 : '#FFFFFF')
                  .backgroundColor(this.sshSystemNotificationsEnabled ? this.pal().surface : this.accentColor)
                  .enabled(!this.sshSystemNotificationsEnabled && !this.sshNotificationAuthorizationPending)
                  .onClick((): void => { this.requestSshNotificationAuthorization(); })
              }.width('100%').height(68).padding({ right: 16 })
              this.cardDivider()
              this.sshInputModeRow()
              this.cardDivider()
              Row() {
                Column() {
                  Text('终端预览').fontSize(AppTheme.fontSize.body).fontWeight(FontWeight.Medium)
                    .fontColor(this.pal().text).fontFamily(this.font())
                  Text('显示当前颜色、字号和行距，实时映射终端外观')
                    .fontSize(11).fontColor(this.pal().text3).fontFamily(this.font())
                    .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
                }.alignItems(HorizontalAlign.Start).layoutWeight(1).margin({ left: 16 })
                Column() {
                  Text('user@host:$ ls -la').fontSize(Math.max(12, Math.min(32, this.terminalFontSize)))
                    .lineHeight(this.terminalPreviewLineHeight())
                    .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                    .fontColor(this.terminalFgColor).fontFamily('monospace').width('100%')
                  Text('drwxr-xr-x  4 user').fontSize(Math.max(10, Math.min(24, this.terminalFontSize - 4)))
                    .lineHeight(this.terminalPreviewLineHeight())
                    .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                    .fontColor(this.terminalFgColor).fontFamily('monospace').width('100%')
                }.width(this.terminalPreviewWidth()).height(this.terminalPreviewHeight())
                  .alignItems(HorizontalAlign.Start).padding({ left: 10, right: 10, top: 8, bottom: 8 })
                  .backgroundColor('#0D0D0D').borderRadius(8)
              }.width('100%').height(this.terminalPreviewHeight()).padding({ left: 0, right: 16 })
              this.cardDivider()
              this.cardActionRow($r('app.media.icon_terminal'), '管理 SSH 主机',
                this.sshCount.toString() + ' 台主机 · 地址、认证和代理仍按主机配置',
                (): void => { this.openSshHostListFromSettings(); })
              this.cardDivider()
              this.cardActionRow($r('app.media.icon_lock'), 'SSH 密钥保险库',
                this.keyCount.toString() + ' 个密钥 · 私钥和 passphrase 不进入通用设置',
                (): void => { this.openSshKeyVaultFromSettings(); })
              this.cardDivider()
              Row() {
                Column() {
                  Text('主机指纹').fontSize(AppTheme.fontSize.body).fontWeight(FontWeight.Medium)
                    .fontColor(this.pal().text).fontFamily(this.font())
                  Text('继续在“数据安全”中管理，暂不迁移 trust 入口')
                    .fontSize(11).fontColor(this.pal().text3).fontFamily(this.font())
                    .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                }.alignItems(HorizontalAlign.Start).layoutWeight(1).margin({ left: 16 })
                Button('恢复默认').height(32).fontSize(12).backgroundColor(this.pal().surface)
                  .fontColor(this.pal().text2).borderRadius(8)
                  .onClick((): void => { this.resetSshTerminalAppearance(); })
              }.width('100%').height(62).padding({ left: 0, right: 16 })
            }.borderRadius(24).backgroundColor(this.pal().card).backgroundBlurStyle(BlurStyle.Regular)
              .shadow({ radius: 16, color: 'rgba(0,0,0,0.04)', offsetY: 4 })
              .border({ width: 0.5, color: this.pal().cardBorder, style: BorderStyle.Solid })
          }.width('100%').padding({ left: 20, right: 20 }).margin({ bottom: 20 })
        }
        .constraintSize({ maxHeight: this.settingsSectionExpanded(SETTINGS_SECTION_SSH) ?
          this.settingsSectionExpandedMaxHeight(SETTINGS_SECTION_SSH) : 0 })
        .opacity(this.settingsSectionExpanded(SETTINGS_SECTION_SSH) ? 1 : 0)
        .scale({ x: 1, y: this.settingsSectionExpanded(SETTINGS_SECTION_SSH) ? 1 : 0.98 })
        .translate({ y: this.settingsSectionExpanded(SETTINGS_SECTION_SSH) ? 0 : -8 })
        .clip(true)
        .animation({ duration: SETTINGS_ACCORDION_ANIMATION_MS, curve: Curve.FastOutSlowIn })

        ListItem() {
          this.settingsAccordionHeader(SETTINGS_SECTION_VNC, protocolIcon('vnc'),
            'VNC', '连接、画面、输入、性能监视和证书信任')
        }.width('100%').padding({ left: 20, right: 20 }).margin({ bottom: 10 })

        // --- VNC protocol settings: leaf bindSheets, not a cloud-data card ---
        ListItem() {
          Column() {
            Text('VNC').fontSize(13).fontWeight(FontWeight.Medium).fontColor(this.pal().text3)
              .fontFamily(this.font()).padding({ left: 8, bottom: 8 })
            Column() {
              this.protocolActionRow($r('sys.symbol.link'), '连接默认值',
                'TCP 直连、Repeater mode12 与默认端口',
                (): void => { this.openSettingsLeafSheet(SETTINGS_SHEET_VNC_CONNECTION); })
              this.cardDivider()
              this.protocolActionRow($r('sys.symbol.timer'), '超时与连接行为',
                '连接、认证与首帧超时，只作用于 VNC',
                (): void => { this.openSettingsLeafSheet(SETTINGS_SHEET_VNC_TIMEOUT); })
              this.cardDivider()
              this.protocolActionRow($r('sys.symbol.lock_shield'), '安全策略与 TLS',
                '仅安全、可信网络与明文风险策略',
                (): void => { this.openSettingsLeafSheet(SETTINGS_SHEET_VNC_SECURITY); })
              this.cardDivider()
              this.protocolActionRow($r('sys.symbol.display'), '显示与画面',
                '本地缩放、画质、编码、色深和帧率',
                (): void => { this.openSettingsLeafSheet(SETTINGS_SHEET_VNC_DISPLAY); })
              this.cardDivider()
              this.protocolActionRow($r('sys.symbol.mouse'), '输入与光标',
                '只读、控制模式、鼠标、触控板和滚轮',
                (): void => { this.openSettingsLeafSheet(SETTINGS_SHEET_VNC_INPUT); })
              this.cardDivider()
              this.protocolActionRow($r('sys.symbol.performance'), '性能监视看板',
                '连接实况、帧率、送显、停滞与采样频率',
                (): void => { this.openSettingsLeafSheet(SETTINGS_SHEET_VNC_PERFORMANCE); })
              this.cardDivider()
              this.protocolActionRow($r('sys.symbol.text_clipboard'), '剪贴板',
                '单独控制 VNC 文本剪贴板',
                (): void => { this.openSettingsLeafSheet(SETTINGS_SHEET_VNC_CLIPBOARD); })
              this.cardDivider()
              this.protocolActionRow($r('sys.symbol.checkmark_shield'), 'Trust / 证书管理',
                '独立于 RDP 证书和 SSH 主机指纹',
                (): void => { this.openSettingsLeafSheet(SETTINGS_SHEET_VNC_TRUST); })
              this.cardDivider()
              this.protocolActionRow($r('sys.symbol.computer_host_fill'), '管理 VNC 主机',
                this.vncHosts.list().length.toString() + ' 台 · 不写入 remotehosts',
                (): void => { this.openSettingsLeafSheet(SETTINGS_SHEET_VNC_HOSTS); })
              this.cardDivider()
              this.protocolActionRow($r('sys.symbol.cloud_fill'), '管理 VNC Gateway',
                this.vncGateways.list().length.toString() + ' 个 · 在第三页中继目录管理',
                (): void => { this.openSettingsLeafSheet(SETTINGS_SHEET_VNC_GATEWAY); })
            }.borderRadius(24).backgroundColor(this.pal().card).backgroundBlurStyle(BlurStyle.Regular)
              .shadow({ radius: 16, color: 'rgba(0,0,0,0.04)', offsetY: 4 })
              .border({ width: 0.5, color: this.pal().cardBorder, style: BorderStyle.Solid })
          }.width('100%').padding({ left: 20, right: 20 }).margin({ bottom: 20 })
        }
        .constraintSize({ maxHeight: this.settingsSectionExpanded(SETTINGS_SECTION_VNC) ?
          this.settingsSectionExpandedMaxHeight(SETTINGS_SECTION_VNC) : 0 })
        .opacity(this.settingsSectionExpanded(SETTINGS_SECTION_VNC) ? 1 : 0)
        .scale({ x: 1, y: this.settingsSectionExpanded(SETTINGS_SECTION_VNC) ? 1 : 0.98 })
        .translate({ y: this.settingsSectionExpanded(SETTINGS_SECTION_VNC) ? 0 : -8 })
        .clip(true)
        .animation({ duration: SETTINGS_ACCORDION_ANIMATION_MS, curve: Curve.FastOutSlowIn })

        ListItem() {
          this.settingsAccordionHeader(SETTINGS_SECTION_MOONLIGHT, protocolIcon('moonlight'),
            'Moonlight', '串流画面、音频、控制与本地安全设置', false, true)
        }.width('100%').padding({ left: 20, right: 20 }).margin({ bottom: 10 })

        ListItem() {
          if (this.settingsSectionExpanded(SETTINGS_SECTION_MOONLIGHT)) {
            Column() {
              Text('Moonlight').fontSize(13).fontWeight(FontWeight.Medium).fontColor(this.pal().text3)
                .fontFamily(this.font()).padding({ left: 8, bottom: 8 })
              Column() {
              this.protocolActionRow($r('sys.symbol.display'), '画面',
                '预设、H.264、分辨率、帧率、码率与无画面策略',
                (): void => { this.openMoonlightSettingsFromSettings(SETTINGS_SHEET_MOONLIGHT_VIDEO); })
              this.cardDivider()
              this.protocolActionRow($r('sys.symbol.circle'), '音频',
                '接收音频、后台音频、系统音量与主机播放',
                (): void => { this.openMoonlightSettingsFromSettings(SETTINGS_SHEET_MOONLIGHT_AUDIO); })
              this.cardDivider()
              this.protocolActionRow($r('sys.symbol.mouse'), '控制与手柄',
                '触控、鼠标、键盘、虚拟与实体控制器',
                (): void => { this.openMoonlightSettingsFromSettings(SETTINGS_SHEET_MOONLIGHT_INPUT); })
              this.cardDivider()
              this.protocolActionRow($r('sys.symbol.link'), '网络与安全',
                '局域网发现、计费网络、重连、加密与兼容',
                (): void => {
                  this.openMoonlightSettingsFromSettings(SETTINGS_SHEET_MOONLIGHT_NETWORK_SECURITY);
                })
              this.cardDivider()
              this.protocolActionRow($r('sys.symbol.performance'), '诊断',
                '性能浮窗、脱敏日志与会话指标',
                (): void => { this.openMoonlightSettingsFromSettings(SETTINGS_SHEET_MOONLIGHT_DIAGNOSTICS); })
              this.cardDivider()
              this.protocolActionRow($r('sys.symbol.lock_shield'), '配对与信任',
                '证书变化、本地安全身份与重新配对边界',
                (): void => { this.openMoonlightSettingsFromSettings(SETTINGS_SHEET_MOONLIGHT_TRUST); })
              this.cardDivider()
              this.protocolActionRow($r('sys.symbol.cloud_fill'), '数据管理',
                '停止同步、分别删除云端或本机 Moonlight 数据',
                (): void => { this.openMoonlightSettingsFromSettings(SETTINGS_SHEET_MOONLIGHT_DATA); })
              }.borderRadius(24).backgroundColor(this.pal().card).backgroundBlurStyle(BlurStyle.Regular)
                .shadow({ radius: 16, color: 'rgba(0,0,0,0.04)', offsetY: 4 })
                .border({ width: 0.5, color: this.pal().cardBorder, style: BorderStyle.Solid })
            }.width('100%').padding({ left: 20, right: 20 }).margin({ bottom: 20 })
          }
        }
        .constraintSize({ maxHeight: this.settingsSectionExpanded(SETTINGS_SECTION_MOONLIGHT) ?
          this.settingsSectionExpandedMaxHeight(SETTINGS_SECTION_MOONLIGHT) : 0 })
        .opacity(this.settingsSectionExpanded(SETTINGS_SECTION_MOONLIGHT) ? 1 : 0)
        .scale({ x: 1, y: this.settingsSectionExpanded(SETTINGS_SECTION_MOONLIGHT) ? 1 : 0.98 })
        .translate({ y: this.settingsSectionExpanded(SETTINGS_SECTION_MOONLIGHT) ? 0 : -8 })
        .clip(true)
        .animation({ duration: SETTINGS_ACCORDION_ANIMATION_MS, curve: Curve.FastOutSlowIn })

        ListItem() {
          this.settingsAccordionHeader(SETTINGS_SECTION_SECURITY, $r('sys.symbol.lock_shield_fill'),
            '数据安全', '端到端加密、2FA 隐私和设备信任')
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
                Column() {
                  Text('TOTP 隐私保护')
                    .fontSize(AppTheme.fontSize.body).fontWeight(FontWeight.Medium)
                    .fontColor(this.pal().text).fontFamily(this.font())
                  Text(this.totpPageLocked ?
                    '已开启 · 查看或绑定 2FA 前需要系统身份认证' :
                    '未开启 · 绑定 RustDesk 2FA 无需额外认证')
                    .fontSize(10).fontColor(this.pal().text3).fontFamily(this.font())
                    .margin({ top: 3 })
                }.alignItems(HorizontalAlign.Start).layoutWeight(1).margin({ left: 4 })
                Toggle({ type: ToggleType.Switch, isOn: this.totpPageLocked })
                  .selectedColor(this.accentColor)
                  .scale({ x: 0.88, y: 0.88 })
                  .onChange(async (on: boolean) => {
                    if (on) {
                      const r = await showLockGate('开启 TOTP 隐私保护，请验证系统身份', 'biometric');
                      if (r.ok) {
                        this.totpPageLocked = true;
                        this.saveTotpLock(true);
                        promptAction.showToast({ message: '2FA 已锁定', duration: 1500 });
                      } else {
                        promptAction.showToast({ message: lockGateErrorMessage(r) || '验证未通过', duration: 2000 });
                        this.totpPageLocked = false;
                      }
                    } else {
                      const r = await showLockGate('关闭 TOTP 隐私保护，请验证系统身份', 'biometric');
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

              Column() {
                Row() {
                  Row() { Text('◎').fontSize(22).fontColor(this.pal().text) }
                    .width(22).height(22).justifyContent(FlexAlign.Center).margin({ left: 9, right: 9 })
                  Column() {
                    Text('2FA 验证器头像').fontSize(AppTheme.fontSize.body).fontWeight(FontWeight.Medium)
                      .fontColor(this.pal().text).fontFamily(this.font())
                    Text('切换真实品牌 Logo 或高对比度首字母')
                      .fontSize(11).fontColor(this.pal().text3).fontFamily(this.font())
                  }.alignItems(HorizontalAlign.Start).layoutWeight(1).margin({ left: 4 })
                }.width('100%').padding({ left: 16, right: 16, top: 12, bottom: 8 })
                Row() {
                  Button('真实 Logo').layoutWeight(1).height(36).fontSize(13)
                    .fontColor(this.totpLogoMode === 'logo' ? Color.White : this.pal().text2)
                    .backgroundColor(this.totpLogoMode === 'logo' ? this.accentColor : this.pal().surface)
                    .borderRadius(10).onClick((): void => { this.saveTotpLogoMode('logo'); })
                  Button('首字母').layoutWeight(1).height(36).fontSize(13).margin({ left: 8 })
                    .fontColor(this.totpLogoMode === 'initials' ? Color.White : this.pal().text2)
                    .backgroundColor(this.totpLogoMode === 'initials' ? this.accentColor : this.pal().surface)
                    .borderRadius(10).onClick((): void => { this.saveTotpLogoMode('initials'); })
                }.width('100%').padding({ left: 16, right: 16, bottom: 12 })
              }

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
              this.cardActionRow($r('app.media.icon_lock'), 'VNC TLS 证书信任',
                this.vncTrustSummary(),
                (): void => { this.openVncTrustManagerFromSettings(); })
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
            '教程', '快速认识、按设备操作和连接前准备')
        }.width('100%').padding({ left: 20, right: 20 }).margin({ bottom: 10 })

        // --- 教程卡片 ---
        ListItem() {
          Column() {
            Text('教程').fontSize(13).fontWeight(FontWeight.Medium).fontColor(this.pal().text3)
              .fontFamily(this.font()).padding({ left: 8, bottom: 8 })
            Column() {
              this.cardActionRow($r('app.media.icon_info'), '本版本更新日志',
                CURRENT_RELEASE_VERSION + ' · 查看全部 12 项功能与修复',
                (): void => {
                  this.openSettingsLeafSheet(SETTINGS_SHEET_POPUP, (): void => {
                    this.aboutSheetMode = 4;
                    this.popupSheetMode = 1;
                  });
                })
              this.cardDivider()
              this.cardActionRow($r('app.media.icon_info'), '快速认识应用', '用 7 页了解协议、设备、安全与数据',
                (): void => {
                  this.openSettingsLeafSheet(SETTINGS_SHEET_POPUP, (): void => {
                    this.aboutSheetMode = 0;
                    this.popupSheetMode = 1;
                  });
                })
              this.cardDivider()
              this.cardActionRow($r('app.media.icon_desktop'), '操作引导中心',
                '按手机、Pad、PC 和五种协议查看具体步骤',
                (): void => {
                  this.openSettingsLeafSheet(SETTINGS_SHEET_POPUP, (): void => {
                    this.aboutSheetMode = 5;
                    this.popupSheetMode = 1;
                  });
                })
              this.cardDivider()
              this.cardActionRow($r('app.media.icon_info'), '连接前准备', 'RDP、RustDesk、SSH、VNC 与 Sunshine',
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
          this.settingsActionHeader($r('sys.symbol.doc_plaintext'), '日志',
            '抓取连接、同步与数据模组的脱敏诊断事件',
            (): void => { this.openSettingsLeafSheet(SETTINGS_SHEET_DIAGNOSTIC_LOG); })
        }.width('100%').padding({ left: 20, right: 20 }).margin({ bottom: 10 })

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
            Text(rdpCertificateErrorTitle(
              this.rdpCertificateErrorStage,
              this.rdpCertificateErrorCode))
              .fontSize(17).fontWeight(FontWeight.Bold).fontColor(this.pal().text)
              .fontFamily(this.font())
            Text(this.rdpCertificateError || '无法读取 RDP 主机证书')
              .fontSize(14).fontColor(this.pal().text2).fontFamily(this.font())
              .margin({ top: 8 })
          }.layoutWeight(1).margin({ left: 16 })
        }.width('100%')
        if (this.rdpCertificateShowDetails) {
          this.rdpCertificateInfoCard()
        }
      } else {
        if (this.rdpCertificateRouteResult !== null) {
          Text(rdpPreflightStatusLabel(this.rdpCertificateRouteResult.preflightStatus) +
            ((this.rdpCertificateRouteResult.riskFlags || []).length > 0
              ? ' · 风险：' + rdpCertificateRiskSummary(this.rdpCertificateRouteResult.riskFlags || [])
              : ''))
            .fontSize(12).fontColor(this.pal().text2).fontFamily(this.font())
            .width('100%').margin({ bottom: 10 })
        }
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

  private rdpCertificateValidityText(info: RdpCertificateInfo): string {
    return this.rdpCertificateValidityRange(info.notBeforeMs, info.notAfterMs);
  }

  private rdpCertificateValidityRange(notBeforeMs: number, notAfterMs: number): string {
    const state: string = rdpCertificateValidityState(notBeforeMs, notAfterMs);
    if (state === 'unknown' || state === 'invalid') {
      return '有效期: 未知';
    }
    const status: string = state === 'expired' ? '已过期' :
      (state === 'not_yet_valid' ? '尚未生效' : '当前有效');
    return '有效期: ' + this.formatTimestamp(notBeforeMs) + ' 至 ' +
      this.formatTimestamp(notAfterMs) + ' (' + status + ')';
  }

  private rdpGatewayTransportSummaryText(): string {
    const result: RdpPreflightResult | null = this.rdpCertificateRouteResult;
    if (result === null) {
      return rdpGatewayTransportSummary('auto', 'unknown');
    }
    return rdpGatewayTransportSummary(
      result.gatewayTransportRequested || result.gatewayTransportSelected || 'auto',
      result.gatewayTransportNegotiated || 'unknown');
  }

  @Builder rdpCertificateRecordInfoCard(title: string, info: RdpCertificateInfo) {
    Column() {
      Text(title)
        .fontSize(13).fontWeight(FontWeight.Medium)
        .fontColor(this.pal().text2).fontFamily(this.font()).width('100%')
      Text(info.ok ? '证书已取得' : '尚未取得该阶段证书')
        .fontSize(12).fontColor(info.ok ? this.pal().text : this.pal().text3)
        .fontFamily(this.font()).width('100%').margin({ top: 6 })
      Text('入口: ' + (info.host || '(未知)') + ':' + info.port.toString())
        .fontSize(12).fontColor(this.pal().text).fontFamily('monospace')
        .width('100%').margin({ top: 8 })
      Text('SNI / Server name: ' + (info.serverName || '(未知)'))
        .fontSize(12).fontColor(this.pal().text).fontFamily('monospace')
        .width('100%').margin({ top: 4 })
      Text('CN: ' + (info.commonName || '(无)'))
        .fontSize(12).fontColor(this.pal().text).fontFamily('monospace')
        .width('100%').margin({ top: 4 })
      Text('Issuer: ' + (info.issuer || '(无)'))
        .fontSize(12).fontColor(this.pal().text).fontFamily('monospace')
        .width('100%').margin({ top: 4 })
      Text('Subject: ' + (info.subject || '(无)'))
        .fontSize(12).fontColor(this.pal().text).fontFamily('monospace')
        .width('100%').margin({ top: 4 })
      Text('根证书: ' + (info.rootTrusted ? '已受信' : '未受信') +
        ' · 名称: ' + (info.hostMismatch ? '不匹配' : '匹配'))
        .fontSize(12).fontColor(this.pal().text).fontFamily(this.font())
        .width('100%').margin({ top: 4 })
      Text(this.rdpCertificateValidityText(info))
        .fontSize(12).fontColor(this.pal().text).fontFamily(this.font())
        .width('100%').margin({ top: 4 })
      if (info.riskFlags.length > 0) {
        Text('风险: ' + rdpCertificateRiskSummary(info.riskFlags))
          .fontSize(12).fontColor('#B45309').fontFamily(this.font())
          .width('100%').margin({ top: 4 })
      }
      Text('SHA-256: ' + (info.fingerprintSha256 || '(无)'))
        .fontSize(12).fontColor(this.pal().text).fontFamily('monospace')
        .width('100%').margin({ top: 8 })
    }
    .width('100%')
    .padding(14)
    .backgroundColor(this.pal().surface)
    .borderRadius(10)
    .margin({ top: 12 })
  }

  @Builder rdpCertificateInfoCard() {
    Column() {
      if (this.rdpCertificateRouteResult !== null &&
        this.rdpCertificateRouteResult.endpointMode === 'microsoft_rd_gateway') {
        Text(this.rdpGatewayTransportSummaryText())
          .fontSize(12).fontColor(this.pal().text2).fontFamily(this.font())
          .width('100%').margin({ bottom: 4 })
      }
      if (this.rdpGatewayCertificateInfo !== null) {
        this.rdpCertificateRecordInfoCard('Gateway TLS 证书', this.rdpGatewayCertificateInfo)
      }
      if (this.rdpCertificateInfo !== null) {
        this.rdpCertificateRecordInfoCard('目标 RDP TLS 证书', this.rdpCertificateInfo)
      }
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
        Button(this.rdpCertificateShowDetails ? '隐藏详情' : '显示详情')
          .fontSize(14).height(40).layoutWeight(1)
          .backgroundColor(this.pal().surface).fontColor(this.pal().text).borderRadius(10)
          .margin({ left: 12 })
          .onClick(() => { this.rdpCertificateShowDetails = !this.rdpCertificateShowDetails; })
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
          Button(this.rdpGatewayConfirmationPending() ? '确认并检查目标' : '继续连接')
            .fontSize(14).height(40).layoutWeight(1)
            .backgroundColor(this.pal().surface).fontColor(this.pal().text).borderRadius(10)
            .onClick(() => { this.doRdpCertificateContinueOnceWrap(); })
          Button(this.rdpGatewayConfirmationPending() ? '信任 Gateway 并检查目标' :
            (this.rdpGatewayCertificateInfo === null ? '信任' : '同时信任两张'))
            .fontSize(14).height(40).layoutWeight(1)
            .backgroundColor(this.accentColor).fontColor('#FFFFFF').borderRadius(10).margin({ left: 12 })
            .onClick(() => { this.doRdpCertificateTrustWrap(); })
        }.width('100%').margin({ top: 12 })
      }.width('100%').margin({ top: 20 })
    }
  }

  @Builder vncCertificatePanel() {
    Column() {
      if (this.vncCertificateState === VncCertificatePreflightState.PROBING) {
        Row() {
          LoadingProgress().width(32).height(32).color(this.accentColor)
          Column() {
            Text('正在检查 VNC TLS 证书')
              .fontSize(17).fontWeight(FontWeight.Bold).fontColor(this.pal().text)
              .fontFamily(this.font())
            Text(this.vncCertificateHostLabel)
              .fontSize(13).fontColor(this.pal().text3).margin({ top: 6 })
          }.layoutWeight(1).margin({ left: 12 })
        }.width('100%').margin({ bottom: 12 })
        Text('确认前不会发送 RFB、密码或剪贴板数据。')
          .fontSize(13).fontColor(this.pal().text2).fontFamily(this.font())
          .width('100%')
      } else if (this.vncCertificateState === VncCertificatePreflightState.PLAINTEXT_WARNING) {
        Row() {
          SymbolGlyph($r('sys.symbol.exclamationmark_triangle'))
            .fontSize(42).fontColor(['#F0B429'])
          Column() {
            Text('确认 VNC 明文连接')
              .fontSize(17).fontWeight(FontWeight.Bold).fontColor(this.pal().text)
              .fontFamily(this.font())
            Text(this.vncCertificateWarning || '当前 endpoint 未启用 TLS。')
              .fontSize(13).fontColor(this.pal().text2).fontFamily(this.font())
              .lineHeight(19).margin({ top: 8 })
          }.layoutWeight(1).margin({ left: 16 })
        }.width('100%').alignItems(VerticalAlign.Top)
        Text('明文连接不会发送证书指纹；请确认当前网络可信后再继续。')
          .fontSize(13).fontColor(this.pal().text2).fontFamily(this.font())
          .lineHeight(19).width('100%').margin({ top: 12 })
      } else if (this.vncCertificateState === VncCertificatePreflightState.ERROR) {
        Row() {
          SymbolGlyph($r('sys.symbol.exclamationmark_triangle'))
            .fontSize(42).fontColor(['#F5C400'])
          Column() {
            Text('VNC TLS 证书检查失败')
              .fontSize(17).fontWeight(FontWeight.Bold).fontColor(this.pal().text)
              .fontFamily(this.font())
            Text(this.vncCertificateError || '无法读取 VNC endpoint 证书')
              .fontSize(14).fontColor(this.pal().text2).fontFamily(this.font())
              .margin({ top: 8 })
          }.layoutWeight(1).margin({ left: 16 })
        }.width('100%')
      } else {
        Row() {
          SymbolGlyph($r('sys.symbol.lock_shield_fill'))
            .fontSize(48).fontColor(['#A87300'])
          Column() {
            Text(this.vncCertificateState === VncCertificatePreflightState.CERTIFICATE_CHANGED ?
              'VNC TLS 证书已变化' : '确认 VNC TLS 证书')
              .fontSize(17).fontWeight(FontWeight.Bold).fontColor(this.pal().text)
              .fontFamily(this.font())
            Text(this.vncCertificateWarning || '请核对指纹后再继续连接。')
              .fontSize(13).fontColor(this.pal().text2).fontFamily(this.font())
              .lineHeight(19).margin({ top: 8 })
          }.layoutWeight(1).margin({ left: 14 })
        }.width('100%').alignItems(VerticalAlign.Top)
        if (this.vncCertificateShowDetails) {
          Column() {
            Text('endpoint: ' + (this.vncCertificateEndpoint === null ? '' :
              this.vncCertificateEndpoint.connectHost + ':' +
              this.vncCertificateEndpoint.connectPort.toString()))
              .fontSize(12).fontColor(this.pal().text).fontFamily('monospace').width('100%')
            Text('CN: ' + (this.vncCertificateInfo?.commonName || '(无)'))
              .fontSize(12).fontColor(this.pal().text).fontFamily('monospace')
              .width('100%').margin({ top: 5 })
            Text('Issuer: ' + (this.vncCertificateInfo?.issuer || '(无)'))
              .fontSize(12).fontColor(this.pal().text).fontFamily('monospace')
              .width('100%').margin({ top: 5 })
            Text('Subject: ' + (this.vncCertificateInfo?.subject || '(无)'))
              .fontSize(12).fontColor(this.pal().text).fontFamily('monospace')
              .width('100%').margin({ top: 5 })
            Text('SHA-256: ' + (this.vncCertificateInfo?.fingerprintSha256 || '(无)'))
              .fontSize(12).fontColor(this.pal().text).fontFamily('monospace')
              .width('100%').margin({ top: 5 })
            Text('TLS: ' + (this.vncCertificateInfo?.tlsVersion || '(未知)') + ' · ' +
              (this.vncCertificateInfo?.cipherCategory || '(未知)'))
              .fontSize(12).fontColor(this.pal().text).fontFamily('monospace')
              .width('100%').margin({ top: 5 })
          }.width('100%').padding(14).margin({ top: 14 })
            .backgroundColor(this.pal().surface).borderRadius(10)
        }
      }
      if (this.vncCertificateState === VncCertificatePreflightState.PROBING) {
        Button('取消').width('100%').height(40).fontSize(14)
          .backgroundColor(this.pal().surface).fontColor(this.pal().text2).borderRadius(10)
          .margin({ top: 20 }).onClick((): void => { this.cancelVncCertificatePreflight(); })
      } else if (this.vncCertificateState === VncCertificatePreflightState.ERROR) {
        Row() {
          Button('取消').height(40).layoutWeight(1).fontSize(14)
            .backgroundColor(this.pal().surface).fontColor(this.pal().text2).borderRadius(10)
            .onClick((): void => { this.cancelVncCertificatePreflight(); })
          Button('重试').height(40).layoutWeight(1).fontSize(14)
            .backgroundColor(this.accentColor).fontColor(Color.White).borderRadius(10)
            .margin({ left: 12 }).onClick((): void => { this.retryVncCertificatePreflight(); })
          }.width('100%').margin({ top: 20 })
      } else if (this.vncCertificateState === VncCertificatePreflightState.PLAINTEXT_WARNING) {
        Row() {
          Button('取消').height(40).layoutWeight(1).fontSize(14)
            .backgroundColor(this.pal().surface).fontColor(this.pal().text2).borderRadius(10)
            .onClick((): void => { this.cancelVncCertificatePreflight(); })
          Button('继续明文连接').height(40).layoutWeight(1).fontSize(14)
            .backgroundColor(this.accentColor).fontColor(Color.White).borderRadius(10)
            .margin({ left: 12 }).onClick((): void => { this.continueVncPlaintextPreflight(); })
        }.width('100%').margin({ top: 20 })
      } else {
        Row() {
          Button(this.vncCertificateShowDetails ? '隐藏证书' : '显示证书')
            .height(40).layoutWeight(1).fontSize(14)
            .backgroundColor(this.pal().surface).fontColor(this.pal().text).borderRadius(10)
            .onClick((): void => { this.vncCertificateShowDetails = !this.vncCertificateShowDetails; })
          Button('取消').height(40).layoutWeight(1).fontSize(14)
            .backgroundColor(this.pal().surface).fontColor(this.pal().text2).borderRadius(10)
            .margin({ left: 12 }).onClick((): void => { this.cancelVncCertificatePreflight(); })
        }.width('100%').margin({ top: 20 })
        Row() {
          Button('仅本次继续').height(40).layoutWeight(1).fontSize(14)
            .backgroundColor(this.pal().surface).fontColor(this.pal().text).borderRadius(10)
            .onClick((): void => {
              this.acceptVncCertificateDecision(VncCertificatePreflightDecision.CONTINUE_ONCE);
            })
          Button(this.vncCertificateState === VncCertificatePreflightState.CERTIFICATE_CHANGED ?
            '更新并信任' : '信任').height(40).layoutWeight(1).fontSize(14)
            .backgroundColor(this.accentColor).fontColor(Color.White).borderRadius(10)
            .margin({ left: 12 }).onClick((): void => {
              this.acceptVncCertificateDecision(this.vncCertificateState ===
                VncCertificatePreflightState.CERTIFICATE_CHANGED ?
                VncCertificatePreflightDecision.UPDATE_TRUST :
                VncCertificatePreflightDecision.TRUST);
            })
        }.width('100%').margin({ top: 12 })
      }
    }.width('100%').padding(20).backgroundColor(this.pal().bg)
      .backgroundBlurStyle(BlurStyle.Regular)
      .borderRadius(this.breakpoint === 'sm' ?
        { topLeft: 20, topRight: 20, bottomLeft: 0, bottomRight: 0 } : 20)
      .constraintSize({ maxWidth: 760 })
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
  }

  @Builder vncCredentialPanel() {
    Column() {
      Row() {
        SymbolGlyph($r('sys.symbol.key_fill'))
          .fontSize(40).fontColor([this.accentColor])
        Column() {
          Text('VNC 连接认证')
            .fontSize(17).fontWeight(FontWeight.Bold).fontColor(this.pal().text)
            .fontFamily(this.font())
          Text(this.vncCredentialHostLabel)
            .fontSize(13).fontColor(this.pal().text3).margin({ top: 5 })
        }.layoutWeight(1).margin({ left: 14 })
      }.width('100%')

      Text('证书或明文风险确认已完成。请先完成密码选择，再进入连接界面。')
        .fontSize(13).fontColor(this.pal().text2).lineHeight(19)
        .width('100%').margin({ top: 14 })

      if (this.vncCredentialState === 'consent_required') {
        Button('确认使用本机已保存密码')
          .width('100%').height(40).fontSize(13).margin({ top: 14 })
          .backgroundColor(this.pal().surface).fontColor(this.pal().text).borderRadius(10)
          .onClick((): void => { this.useSavedVncCredential(); })
      }

      Row() {
        TextInput({
          placeholder: this.vncCredentialNoPassword ? '已选择无密码连接' : '输入 VNC 密码',
          text: this.vncCredentialPassword
        })
          .type(this.vncCredentialPasswordVisible ? InputType.Normal : InputType.Password)
          .enabled(!this.vncCredentialNoPassword)
          .layoutWeight(1).height(42)
          .backgroundColor(this.pal().surface).fontColor(this.pal().text)
          .onChange((value: string): void => {
            this.vncCredentialPassword = value;
            this.vncCredentialError = '';
          })
          .onSubmit((): void => { this.confirmVncCredentialPreflight(); })
        SymbolGlyph(this.vncCredentialPasswordVisible ?
          $r('sys.symbol.eye_slash') : $r('sys.symbol.eye'))
          .fontSize(20).fontColor([this.pal().text2]).margin({ left: 10 })
          .enabled(!this.vncCredentialNoPassword)
          .onClick((): void => {
            this.vncCredentialPasswordVisible = !this.vncCredentialPasswordVisible;
          })
      }.width('100%').margin({ top: 14 })

      Row() {
        Toggle({ type: ToggleType.Switch, isOn: this.vncCredentialRememberPassword })
          .enabled(!this.vncCredentialNoPassword)
          .onChange((value: boolean): void => {
            this.vncCredentialRememberPassword = value;
            this.vncCredentialError = '';
          })
        Text('记住密码').fontSize(13).fontColor(this.pal().text2).margin({ left: 8 })
        Blank()
        Toggle({ type: ToggleType.Switch, isOn: this.vncCredentialNoPassword })
          .onChange((value: boolean): void => {
            this.vncCredentialNoPassword = value;
            if (value) {
              this.vncCredentialPassword = '';
              this.vncCredentialRememberPassword = false;
            }
            this.vncCredentialError = '';
          })
        Text('无密码连接').fontSize(13).fontColor(this.pal().text2).margin({ left: 8 })
      }.width('100%').margin({ top: 12 }).alignItems(VerticalAlign.Center)

      if (this.vncCredentialError !== '') {
        Text(this.vncCredentialError).fontSize(12).fontColor(this.pal().danger)
          .lineHeight(18).width('100%').margin({ top: 10 })
      }

      Row() {
        Button('取消').height(40).layoutWeight(1).fontSize(14)
          .backgroundColor(this.pal().surface).fontColor(this.pal().text2).borderRadius(10)
          .onClick((): void => { this.cancelVncCredentialPreflight(); })
        Button('验证并连接').height(40).layoutWeight(1).fontSize(14)
          .backgroundColor(this.accentColor).fontColor(Color.White).borderRadius(10)
          .margin({ left: 12 }).onClick((): void => { this.confirmVncCredentialPreflight(); })
      }.width('100%').margin({ top: 18 })
    }.width('100%').padding(20).backgroundColor(this.pal().bg)
      .backgroundBlurStyle(BlurStyle.Regular)
      .borderRadius(this.breakpoint === 'sm' ?
        { topLeft: 20, topRight: 20, bottomLeft: 0, bottomRight: 0 } : 20)
      .constraintSize({ maxWidth: 620 })
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
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
      Text(this.sshPreflightJumpHostKeyInfo ?
        '这是首次连接该 SSH 主机或跳板机。请分别确认指纹与服务器管理员提供的一致。' :
        '这是首次连接该 SSH 主机。请确认此指纹与服务器管理员提供的一致。')
        .fontSize(13).fontColor(this.pal().text2).margin({ top: 16 }).fontFamily(this.font())
      Text('确认后, RemoteDesktop 会分别保存 endpoint 指纹, 后续连接会自动校验。')
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
      Text(this.sshPreflightPassphraseScope === 'proxy' ?
        '跳板机指纹已确认。跳板机私钥受密码保护, 请输入 passphrase 后继续。' :
        '主机指纹已确认。此私钥受密码保护, 请输入私钥密码后继续连接。')
        .fontSize(13).fontColor(this.pal().text2).margin({ bottom: 16 }).fontFamily(this.font())
      Row() {
        TextInput({ placeholder: this.sshPreflightPassphraseScope === 'proxy' ?
          '输入跳板机私钥密码' : '输入私钥密码',
          text: this.sshPreflightPassphraseScope === 'proxy' ?
            this.sshPreflightProxyPassphraseInput : this.sshPreflightPassphraseInput })
          .type(this.sshPreflightPassphraseShowPw ? InputType.Normal : InputType.Password)
          .height(44).backgroundColor(this.pal().surface).borderRadius(8)
          .fontColor(this.pal().text).placeholderColor(this.pal().text3)
          .layoutWeight(1).padding({ left: 12, right: 12 })
          .onChange((v: string) => {
            if (this.sshPreflightPassphraseScope === 'proxy') {
              this.sshPreflightProxyPassphraseInput = v;
            }
            else { this.sshPreflightPassphraseInput = v; }
          })
        SymbolGlyph(this.sshPreflightPassphraseShowPw ? $r('sys.symbol.eye_slash') : $r('sys.symbol.eye'))
          .fontSize(18).fontColor([this.pal().text3]).margin({ left: 8 })
          .onClick(() => { this.sshPreflightPassphraseShowPw = !this.sshPreflightPassphraseShowPw; })
      }.width('100%').margin({ bottom: 12 })
      Row() {
        Checkbox()
          .select(this.sshPreflightPassphraseScope === 'proxy' ?
            this.sshPreflightProxyPassphraseSaveToHost :
            this.sshPreflightPassphraseSaveToHost)
          .selectedColor(this.accentColor)
          .onChange((v: boolean) => {
            if (this.sshPreflightPassphraseScope === 'proxy') {
              this.sshPreflightProxyPassphraseSaveToHost = v;
            }
            else { this.sshPreflightPassphraseSaveToHost = v; }
          })
        Text(this.hasSavedSshPreflightPassphrase() ?
          (this.sshPreflightPassphraseScope === 'proxy' ?
            '验证成功后更新保存的跳板机私钥密码' : '验证成功后更新保存的私钥密码') :
          '保存到此主机 (加密存储)')
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
      if (this.sshPreflightJumpHostKeyInfo) {
        Divider().margin({ top: 12, bottom: 12 }).color(this.pal().divider)
        Text('跳板机: ' + this.sshPreflightJumpHostLabel)
          .fontSize(13).fontColor(this.pal().text).fontFamily(this.font()).fontWeight(FontWeight.Medium)
          .margin({ top: 2, bottom: 8 })
        Row() {
          Text('算法: ').fontSize(13).fontColor(this.pal().text3).fontFamily(this.font())
          Text(this.sshPreflightJumpHostKeyInfo.algorithm).fontSize(13).fontColor(this.pal().text)
            .fontFamily('monospace').fontWeight(FontWeight.Medium)
        }.width('100%').margin({ bottom: 4 })
        Row() {
          Text('SHA256:').fontSize(13).fontWeight(FontWeight.Medium).fontColor(this.pal().text2)
            .fontFamily(this.font())
          Text(this.sshPreflightJumpHostKeyInfo.fingerprintSha256)
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
    } else if (this.popupSheetMode === POPUP_SHEET_VNC_CERTIFICATES) {
      VncCertificateTrustManagerSheet({
        onClose: (): void => { this.closeSettingsLeafSheet(); },
        onRecheck: (trust: VncTrustView, hostId: string): void => { this.recheckVncTrust(trust, hostId); }
      })
    } else if (this.popupSheetMode === 3) {
      this.cloudSyncSheet()
    } else {
      AboutSettingsSheet({
        aboutSheetMode: this.aboutSheetMode,
        guideViewportHeight: this.pageViewportHeight,
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
              Text('主机、凭据、密钥、2FA、VNC、自动启用的 Moonlight 与个性化设置共 8 类业务数据')
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
            .onClick((): void => { this.cloudSyncError = ''; this.cloudSyncStep = this.cloudDirectionConfirmationAvailable() ? CLOUD_SYNC_SHEET_UPLOAD_CONFIRM : CLOUD_SYNC_SHEET_MANAGE_TABLES; })

          Column() {
            Row() {
              Row() { SymbolGlyph($r('sys.symbol.cloud_fill')).fontSize(20).fontColor([this.accentColor]) }
                .width(40).height(40).borderRadius(20).backgroundColor(this.pal().surface).justifyContent(FlexAlign.Center)
              Column() {
                Text(this.currentCloudSyncSheetSpec().secondaryLabel).fontSize(15).fontWeight(FontWeight.Medium).fontColor(this.pal().text).fontFamily(this.font())
                Text('以已选数据的云端版本为准，覆盖本机').fontSize(12).fontColor(this.pal().text3).fontFamily(this.font()).margin({ top: 3 })
              }.alignItems(HorizontalAlign.Start).layoutWeight(1).margin({ left: 12 })
              SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(16).fontColor([this.pal().text3])
            }.width('100%').padding({ left: 14, right: 16, top: 13, bottom: 13 })
          }.width('100%').borderRadius(16).backgroundColor(this.pal().surface)
            .border({ width: 0.5, color: this.pal().cardBorder, style: BorderStyle.Solid }).margin({ top: 10 })
            .onClick((): void => { this.cloudSyncError = ''; this.cloudSyncStep = this.cloudDirectionConfirmationAvailable() ? CLOUD_SYNC_SHEET_DOWNLOAD_CONFIRM : CLOUD_SYNC_SHEET_MANAGE_TABLES; })

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
          if (CloudStore.getInstance().requiresRestoreDirectionDecision()) {
            Text('本地备份恢复尚未完成方向确认。勾选需要同步的数据后返回；未勾选的数据会保留本机，不会阻塞其他表。')
              .fontSize(12).fontColor(this.accentColor).fontFamily(this.font())
              .lineHeight(19).margin({ top: 8 })
          }
          Text('取消勾选不会删除数据，只会停止此设备未来的上传和下载。加密参数会随敏感数据自动保护。')
            .fontSize(12).fontColor(this.pal().text3).fontFamily(this.font()).lineHeight(19).margin({ top: 8, bottom: 14 })
          Row() {
            Checkbox()
              .select(this.cloudSyncSelectedTables.indexOf(
                MOONLIGHT_CLOUD_TABLE) >= 0)
              .selectedColor(this.accentColor).enabled(false)
            Column() {
              Text('Moonlight 串流数据')
                .fontSize(14).fontWeight(FontWeight.Medium)
                .fontColor(this.pal().text).fontFamily(this.font())
              Text('设置、主机目录和应用配置固定整体同步（自动启用）')
                .fontSize(11).fontColor(this.pal().text3)
                .fontFamily(this.font()).margin({ top: 3 })
            }.alignItems(HorizontalAlign.Start).layoutWeight(1)
              .margin({ left: 10 })
          }.width('100%').padding(14).borderRadius(14)
            .backgroundColor(this.pal().surface).margin({ bottom: 8 })
          if (this.moonlightRestoreActivationState === 'pending' ||
              this.moonlightRestoreActivationState === 'blocked') {
            Column() {
              Text(this.moonlightRestoreActivationState === 'blocked' ?
                'Moonlight 恢复隔离状态不可读，传输暂时暂停' :
                '从备份恢复的 Moonlight 数据仍处于仅本地隔离，需要先核对云端。')
                .fontSize(11).fontColor(this.moonlightRestoreActivationState ===
                  'blocked' ? this.pal().danger : '#B66A00')
                .fontFamily(this.font()).lineHeight(18).width('100%')
              if (this.moonlightRestoreActivationState === 'pending') {
                Button('核对云端并允许恢复数据上传')
                  .fontSize(12).fontWeight(FontWeight.Medium)
                  .fontColor(Color.White).backgroundColor(this.accentColor)
                  .height(38).borderRadius(12).width('100%')
                  .margin({ top: 10 })
                  .onClick((): void => {
                    this.confirmMoonlightRestoreActivation();
                  })
              }
            }.width('100%').padding(12).borderRadius(12)
              .backgroundColor(this.pal().surface).margin({ bottom: 8 })
          }
          ForEach(cloudSyncSelectableTables(), (table: string) => {
            Row() {
              Checkbox().select(this.cloudSyncSelectedTables.indexOf(table) >= 0).selectedColor(this.accentColor)
                .onChange((): void => {
                  void this.toggleCloudSyncTable(table);
                })
              Column() {
                Text(table === 'usersettings' ? '跨设备外观设置' : table === 'remotehosts' ? '远程主机' : table === 'rdpcredentials' ? 'Windows 登录凭据' : table === 'rustdeskrelays' ? 'RustDesk 中继配置' : table === 'sshkeys' ? 'SSH 密钥' : table === 'totpentries' ? '双重验证动态口令' : table === 'vncrecordv2' ? 'VNC 记录（vncrecord）' : 'Moonlight 串流数据')
                  .fontSize(14).fontWeight(FontWeight.Medium).fontColor(this.pal().text).fontFamily(this.font())
                Text(table === 'usersettings' ? '仅同步主题、壁纸等可跨设备复用的外观偏好' : table === 'vncrecordv2' ? 'VNC 设置、主机、Gateway、加密机密和 trust 候选元数据' : '包含敏感数据，启用时自动同步加密参数')
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
            Text(cloudSyncDetailSpec(this.cloudConnectionAvailable).statusText)
              .fontSize(13).fontColor(this.accentColor).fontFamily(this.font()).margin({ top: 7 })
          }.width('100%').padding(14).borderRadius(14).backgroundColor(this.pal().surface).margin({ top: 20 }).alignItems(HorizontalAlign.Start)
          Text('请依次确认').fontSize(13).fontWeight(FontWeight.Medium).fontColor(this.pal().text2).fontFamily(this.font()).margin({ top: 20 })
            .width('100%')
          ForEach(cloudSyncDetailSpec(this.cloudConnectionAvailable).prerequisites,
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
              Text(this.currentCloudSyncSheetSpec().primaryDestructive
                ? '此操作会覆盖数据，请在继续前确认数据来源。'
                : '继续前请确认备份来源和影响范围。')
                .fontSize(12).fontColor(this.pal().text3)
                .fontFamily(this.font()).margin({ top: 3 })
            }.alignItems(HorizontalAlign.Start).layoutWeight(1).margin({ left: 12 })
          }.width('100%').alignItems(VerticalAlign.Center)
          Text(this.currentCloudSyncSheetSpec().message).fontSize(14).fontColor(this.pal().text2).fontFamily(this.font()).lineHeight(21).margin({ top: 18 })
          if (this.cloudSyncStep === CLOUD_SYNC_SHEET_BACKUP_CONFIRM) {
            Column() {
              Text('备份内容').fontSize(12).fontWeight(FontWeight.Medium).fontColor(this.pal().text2).fontFamily(this.font())
                .width('100%').margin({ bottom: 8 })
              Row() {
                SymbolGlyph(this.backupFullMode
                  ? $r('sys.symbol.circle')
                  : $r('sys.symbol.checkmark_circle_fill'))
                  .fontSize(18).fontColor([this.backupFullMode ? this.pal().text3 : this.accentColor])
                Column() {
                  Text('脱敏配置（推荐）').fontSize(14).fontWeight(FontWeight.Medium).fontColor(this.pal().text).fontFamily(this.font())
                  Text('不含密码、SSH 私钥、2FA 与登录令牌；保留 SSH/RDP 设备信任，VNC trust 候选和本机确认标记均不导出')
                    .fontSize(11).fontColor(this.pal().text3).fontFamily(this.font()).lineHeight(17).margin({ top: 2 })
                }.alignItems(HorizontalAlign.Start).layoutWeight(1).margin({ left: 10 })
              }.width('100%').padding(12).borderRadius(14).backgroundColor(this.pal().surface)
                .onClick((): void => { this.backupFullMode = false; this.cloudSyncError = ''; })
              Row() {
                SymbolGlyph(this.backupFullMode
                  ? $r('sys.symbol.checkmark_circle_fill')
                  : $r('sys.symbol.circle'))
                  .fontSize(18).fontColor([this.backupFullMode ? this.accentColor : this.pal().text3])
                Column() {
                  Text('完整备份').fontSize(14).fontWeight(FontWeight.Medium).fontColor(this.pal().text).fontFamily(this.font())
                  Text('包含密码、SSH 私钥、2FA、VNC 配置与 trust 候选；本机 confirmation marker 不导出。源已加密则携带加密参数（恢复需相同主密码），未加密则按你的选择以明文保存')
                    .fontSize(11).fontColor(this.pal().text3).fontFamily(this.font()).lineHeight(17).margin({ top: 2 })
                }.alignItems(HorizontalAlign.Start).layoutWeight(1).margin({ left: 10 })
              }.width('100%').padding(12).borderRadius(14).backgroundColor(this.pal().surface).margin({ top: 8 })
                .onClick((): void => { this.backupFullMode = true; this.cloudSyncError = ''; })
            }.width('100%').margin({ top: 16 })
          }
          Column() {
            Text('影响范围').fontSize(12).fontWeight(FontWeight.Medium).fontColor(this.pal().text2).fontFamily(this.font())
            Text(this.cloudSyncStep === CLOUD_SYNC_SHEET_BACKUP_CONFIRM
              ? (this.backupFullMode
                ? '全部连接配置、密码、私钥、2FA、VNC 配置与 trust 候选；不含本机 confirmation marker'
                : '连接配置与个性化设置；保留 SSH/RDP 设备信任，不含密码、私钥、2FA、登录令牌和 VNC trust marker')
              : (this.cloudSyncStep === CLOUD_SYNC_SHEET_RESTORE_CONFIRM
                ? this.localRestorePreviewSummary()
                : '主机、RDP 凭据、RustDesk 中继、SSH 密钥、2FA、加密参数和个性化设置'))
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
              .backgroundColor(this.currentCloudSyncSheetSpec().primaryDestructive
                ? this.pal().danger : this.accentColor)
              .fontColor('#FFFFFF').borderRadius(14).margin({ left: 12 })
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
                Text(this.rdpCertificateValidityRange(
                  host.rdpCertificateNotBeforeMs, host.rdpCertificateNotAfterMs))
                  .fontSize(11).fontColor(this.pal().text2).fontFamily(this.font())
                  .maxLines(1).width('100%').margin({ top: 3 })
                if (host.rdpGatewayCertificateFingerprintSha256 !== '') {
                  Text('Gateway CN: ' + (host.rdpGatewayCertificateCommonName || '(无)'))
                    .fontSize(11).fontColor(this.pal().text2).fontFamily('monospace')
                    .maxLines(1).width('100%').margin({ top: 3 })
                  Text(this.rdpCertificateValidityRange(
                    host.rdpGatewayCertificateNotBeforeMs,
                    host.rdpGatewayCertificateNotAfterMs))
                    .fontSize(11).fontColor(this.pal().text2).fontFamily(this.font())
                    .maxLines(1).width('100%').margin({ top: 3 })
                }
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
        Text('• 主密码不会持久化或上传；新设备需要重新输入后解锁')
          .fontSize(12).fontColor(this.pal().text2).fontFamily(this.font()).margin({ bottom: 4 })
        Text('• 忘记密码将无法恢复已加密的数据，请妥善保管')
          .fontSize(12).fontColor(this.pal().danger).fontFamily(this.font()).margin({ bottom: 4 })
        Text('• 关闭加密后仅恢复本机明文；敏感云同步会自动暂停')
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
            .enabled(this.cryptoResetCountdown <= 0 &&
              this.cryptoPwd.length > 0 && !this.cryptoLoading)
            .onClick(() => { this.doCloseEncryption(); })
        }.width('100%')
      } else if (this.cryptoMode === 3) {
        // 重置模式: 忘记密码, 红色警告 + 5s 倒计时, 无需输入密码
        Text('⚠️ 确定要重置加密吗?')
          .fontSize(15).fontWeight(FontWeight.Bold).fontColor(this.pal().danger)
          .width('100%').margin({ bottom: 10 }).fontFamily(this.font())
        Text('本机当前账号的所有加密数据将被永久删除，此操作不可恢复。\n跨设备远程清空协议尚未启用，其他设备不会被本次操作自动清空。')
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
            .enabled(this.cryptoResetCountdown <= 0 && !this.cryptoLoading)
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
    if (this.cryptoLoading) { return; }
    this.cryptoLoading = true;
    const crypto = DataCrypto.getInstance();
    const cloud = CloudStore.getInstance();
    try {
      // 1. 验证主密码
      const ok = await crypto.unlock(this.cryptoPwd);
      if (!ok) {
        promptAction.showToast({ message: '密码错误, 无法关闭加密', duration: 2000 });
        return;
      }
      // 2. 业务数据解密、VNC 降级、KDF 参数清除和 disabled 状态由
      // CloudStore 在一个事务中提交；任一步失败都会完整回滚。
      const count = await cloud.disableCryptoV3(
        crypto, cloud.currentAccountLease());
      hilog.info(0x0001, 'CloudSync', 'doCloseEncryption: 已解密 ' + count + ' 条数据');
      if (count < 0) {
        promptAction.showToast({ message: '关闭加密失败：本地数据未完整解密，请重试', duration: 2500 });
        return;
      }
      // 3. 数据库已提交后再清除内存 DEK。
      crypto.resetSetup();
      this.closeSettingsLeafSheet();
      this.cryptoPwd = '';
      this.cryptoResetCountdown = 0;
      this.refreshCryptoStatus();
      promptAction.showToast({
        message: '加密已关闭，' + count +
          ' 条数据已恢复为本机明文；敏感云同步已暂停',
        duration: 2600
      });
    } finally {
      this.cryptoLoading = false;
    }
  }

  private async doResetEncryption(): Promise<void> {
    if (this.cryptoLoading) { return; }
    this.cryptoLoading = true;
    const cloud = CloudStore.getInstance();
    try {
      // 本机账号数据、KDF 参数、VNC reset epoch 与恢复状态单事务提交。
      if (!(await cloud.resetCryptoV3(cloud.currentAccountLease()))) {
        promptAction.showToast({ message: '重置失败：本地数据未完整清空，请重试', duration: 2500 });
        return;
      }
      VncTrustService.getInstance().clearLocalConfirmationState(getContext(this) as common.Context);
      this.closeSettingsLeafSheet();
      this.cryptoPwd = '';
      this.cryptoResetCountdown = 0;
      this.refreshCryptoStatus();
      promptAction.showToast({
        message: '加密已重置，本机加密数据已清空；敏感云同步已暂停',
        duration: 2600
      });
    } finally {
      this.cryptoLoading = false;
    }
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

  @Builder protocolStatItemRow(icon: Resource, label: string, value: string) {
    Row() {
      Row() { SymbolGlyph(icon).fontSize(22).fontColor([this.pal().text3]) }
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

  @Builder protocolActionRow(icon: Resource, label: string, value: string, action: () => void) {
    Row() {
      SymbolGlyph(icon).fontSize(22).fontColor([this.pal().text3])
        .width(22).height(22).margin({ left: 9, right: 9 })
      Column() {
        Text(label).fontSize(AppTheme.fontSize.body).fontWeight(FontWeight.Medium)
          .fontColor(this.pal().text).fontFamily(this.font())
        Text(value).fontSize(11).fontColor(this.pal().text3).fontFamily(this.font())
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).margin({ top: 2 })
      }.alignItems(HorizontalAlign.Start).layoutWeight(1).margin({ left: 4 })
      SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(18).fontColor([this.pal().text3])
        .margin({ right: 14 })
    }.width('100%').height(62).padding({ left: 16, right: 16 }).onClick(action)
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
          Text('适用于 RDP、RustDesk、VNC、实体鼠标和触控板')
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

  @Builder sessionControlBarVisibilityRow() {
    Column() {
      Row() {
        Row() {
          Image($r('app.media.icon_desktop')).width(22).height(22).fillColor(this.pal().text3)
        }.width(22).height(22).justifyContent(FlexAlign.Center).margin({ left: 9, right: 9 })
        Column() {
          Text('会话侧栏与顶栏').fontSize(AppTheme.fontSize.body).fontWeight(FontWeight.Medium)
            .fontColor(this.pal().text).fontFamily(this.font())
          Text(remoteSessionControlBarSelectionSummary(this.sessionControlBarVisibility()))
            .fontSize(11).fontColor(this.pal().text3).fontFamily(this.font())
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        }.alignItems(HorizontalAlign.Start).layoutWeight(1).margin({ left: 4 })
        Button(this.sessionControlBarProtocolPickerExpanded ? '收起' : '选择协议')
          .height(34).padding({ left: 12, right: 12 }).fontSize(12)
          .fontColor(this.accentColor).backgroundColor(this.pal().surface).borderRadius(8)
          .onClick((): void => {
            this.sessionControlBarProtocolPickerExpanded =
              !this.sessionControlBarProtocolPickerExpanded;
          })
      }.width('100%').height(64).padding({ left: 16, right: 16 })
      if (this.sessionControlBarProtocolPickerExpanded) {
        Text('选中的协议会同时隐藏手机/平板侧栏和 PC 顶栏；可在此随时恢复。')
          .fontSize(11).fontColor(this.pal().text3).fontFamily(this.font())
          .width('100%').padding({ left: 20, right: 20, bottom: 6 })
        this.sessionControlBarProtocolSwitchRow('rdp', 'RDP')
        this.sessionControlBarProtocolSwitchRow('rustdesk', 'RustDesk')
        this.sessionControlBarProtocolSwitchRow('vnc', 'VNC')
        this.sessionControlBarProtocolSwitchRow('moonlight', 'Moonlight')
      }
    }.width('100%')
  }

  @Builder sessionControlBarProtocolSwitchRow(protocol: string, label: string) {
    Row() {
      Column() {
        Text(label).fontSize(13).fontWeight(FontWeight.Medium)
          .fontColor(this.pal().text).fontFamily(this.font())
        Text(this.sessionControlBarHidden(protocol) ? '侧栏和顶栏均已隐藏' : '显示会话控制栏')
          .fontSize(11).fontColor(this.pal().text3).fontFamily(this.font())
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      Toggle({ type: ToggleType.Switch, isOn: this.sessionControlBarHidden(protocol) })
        .selectedColor(this.accentColor).scale({ x: 0.88, y: 0.88 })
        .accessibilityText((this.sessionControlBarHidden(protocol) ? '显示 ' : '隐藏 ') +
          label + ' 会话控制栏')
        .onChange((on: boolean): void => { this.saveSessionControlBarHidden(protocol, on); })
    }.width('100%').height(58).padding({ left: 52, right: 16 })
  }

  @Builder canvasGestureZoomRow() {
    if (!this.isDesktopDevice) {
      this.rustdeskSwitchRow($r('app.media.icon_desktop'), '双指画布缩放',
        '缩放后抬手，再双指长按约0.4秒拖动画布；关闭后保留双指右键和滚轮',
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

  @Builder sshInputModeRow() {
    if (this.breakpoint === 'md' || this.breakpoint === 'lg') {
      Row() {
        this.sshInputModeLabel()
        this.sshInputModeSlider()
      }.width('100%').height(64).padding({ left: 16, right: 16 })
    } else {
      Column() {
        Row() {
          this.sshInputModeLabel()
        }.width('100%')
        Row() {
          Blank().layoutWeight(1)
          this.sshInputModeSlider()
        }.width('100%').margin({ top: 10 })
      }.width('100%').height(92).padding({ left: 16, right: 16, top: 14, bottom: 12 })
    }
  }

  private sshInputModeDetail(): string {
    if (this.sshInputMode === 1) { return '始终显示虚拟功能栏并使用软键盘'; }
    if (this.sshInputMode === 2) { return '隐藏虚拟功能栏，使用实体键盘和鼠标'; }
    return '自动检测：有实体键盘时隐藏虚拟功能栏';
  }

  @Builder sshInputModeLabel() {
    Row() {
      Row() { Image($r('app.media.icon_terminal')).width(22).height(22).fillColor(this.pal().text3) }
        .width(22).height(22).justifyContent(FlexAlign.Center).margin({ left: 9, right: 9 })
      Column() {
        Text('输入设备').fontSize(AppTheme.fontSize.body).fontWeight(FontWeight.Medium)
          .fontColor(this.pal().text).fontFamily(this.font())
        Text(this.sshInputModeDetail()).fontSize(11).fontColor(this.pal().text3).fontFamily(this.font())
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
      }.alignItems(HorizontalAlign.Start).layoutWeight(1).margin({ left: 4 })
    }.layoutWeight(1)
  }

  @Builder sshInputModeSlider() {
    Stack({ alignContent: Alignment.Start }) {
      Column()
        .width(72).height(30).borderRadius(8)
        .backgroundColor(this.accentColor)
        .translate({ x: this.sshInputMode * 76, y: 0 })
        .animation({ duration: 260, curve: Curve.FastOutSlowIn })
      Row() {
        this._sshInputModeChip('自动', 0)
        Blank().width(4)
        this._sshInputModeChip('虚拟键盘', 1)
        Blank().width(4)
        this._sshInputModeChip('实体键鼠', 2)
      }
    }.padding(3).borderRadius(11).backgroundColor(this.pal().surface)
  }

  @Builder _sshInputModeChip(label: string, mode: number) {
    Column() {
      Text(label)
        .fontSize(11)
        .fontColor(this.sshInputMode === mode ? '#FFFFFF' : this.pal().text2)
        .fontWeight(this.sshInputMode === mode ? FontWeight.Medium : FontWeight.Normal)
        .textAlign(TextAlign.Center)
        .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        .padding({ left: 8, right: 8, top: 6, bottom: 6 })
        .borderRadius(8)
        .onClick((): void => { this.saveSshInputMode(mode); })
    }.width(72).justifyContent(FlexAlign.Center)
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
  private isClassicVncAddSheet(): boolean {
    return !this.addSheetShowsModernPicker && this.modernAddProtocol === '' && this.proto === 'vnc';
  }

  private isVncAddSheet(): boolean {
    return this.isClassicVncAddSheet() || this.modernAddProtocol === 'vnc';
  }

  private hostAddSheetHeight(): SheetSize | number {
    if (this.modernAddProtocol === 'moonlight') {
      // Moonlight follows the same intrinsic/adaptive host-add sheet as RustDesk;
      // the host page must not force a large desktop sheet below short content.
      return SheetSize.FIT_CONTENT;
    }
    const isLongFlow: boolean = this.isVncAddSheet() || this.modernAddProtocol === 'ssh';
    if (isLongFlow && this.breakpoint === 'sm') {
      // Long forms need a bounded viewport so keyboard avoidance can shrink
      // the scrollable body without pushing the sheet actions off screen.
      const availableHeight: number = Math.max(420,
        this.windowH - this.topSafeHeightVp() - 24);
      return Math.min(760, availableHeight);
    }
    return isLongFlow ? SheetSize.LARGE : SheetSize.FIT_CONTENT;
  }

  private hostAddSheetKeyboardAvoidMode(): SheetKeyboardAvoidMode {
    return this.isVncAddSheet()
      ? SheetKeyboardAvoidMode.RESIZE_ONLY
      : SheetKeyboardAvoidMode.TRANSLATE_AND_SCROLL;
  }

  @Builder hostAddSheetContent() {
    if (this.addSheetShowsModernPicker) {
      HostAddWizardSheet({
        moonlightFabEntryAvailable: false,
        moonlightProtocolAvailable: this.moonlightProtocolAvailable,
        onSelectProtocol: (protocol: string): void => {
          this.modernAddProtocol = protocol;
          this.addSheetShowsModernPicker = false;
          if (protocol === 'moonlight') {
            this.invalidateMoonlightCatalogHandoff();
            this.clearMoonlightVerificationState();
            this.moonlightAddCommitted = false;
            this.moonlightAddOwnerToken += 1;
          }
          if (protocol === 'vnc') {
            this.prepareVncAddFlow();
            this.vncAddFromModernPicker = true;
          }
          if (protocol !== 'rdp') {
            this.switchHostProtocol(protocol, RemoteHost.getDefaultPort(protocol));
          }
        },
        onClose: (): void => { this.requestAddSheetClose(); }
      })
    } else if (this.modernAddProtocol === 'rdp') {
      RdpAddFlow({
        credentials: this.rdpCredentials,
        lanScanning: this.rdpLanScanning,
        lanHosts: this.rdpLanScanResults,
        lanStatusText: this.rdpLanStatusText,
        onBackToProtocols: (): void => { this.modernAddProtocol = ''; this.addSheetShowsModernPicker = true; },
        onAddCredential: (): void => { this.openRdpCredentialManager(); },
        onStartLanScan: (port: number): void => { this.startRdpLanScan(port); },
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
        initialDraft: this.rustDeskAddResumeDraft,
        initialDraftRevision:
          this.rustDeskAddResumeRevision,
        onBackToProtocols: (): void => { this.modernAddProtocol = ''; this.addSheetShowsModernPicker = true; },
        onStartLanScan: (): void => { this.startLanScan(); },
        onManageRelays: (
          draft: RustDeskHostAddDraft): void => {
          const scope = CloudStore.getInstance().currentScope();
          if (!RustDeskHostAddHandoff.getInstance().put(
            scope.ownerScopeId, scope.storeIdentity,
            scope.generation, draft)) {
            promptAction.showToast({
              message: '当前账号数据域不可用，无法暂存主机草稿',
              duration: 2200
            });
            return;
          }
          this.rustDeskHostAddReturnTab =
            this.isDesktopDevice &&
            this.breakpoint === 'xl' &&
            this.curTab >= 0 && this.curTab <= 3
              ? this.curTab : 0;
          this.rustDeskRelayReturnToHostAdd = true;
          this.pendingRustDeskRelayDirectoryOpen = true;
          this.requestAddSheetClose();
        },
        onOpenTotpBinding: (draft: RustDeskHostAddDraft): void => {
          this.openRustDeskTotpBindingFromModern(draft);
        },
        onSave: (host: RemoteHost, connectNow: boolean): void => {
          this.saveHostFromAddFlow(host, connectNow);
        }
      })
    } else if (this.modernAddProtocol === 'moonlight') {
      MoonlightHostAddFlow({
        ownerToken: this.moonlightAddOwnerToken,
        candidates: this.moonlightLanCandidates,
        discoveryRunning: this.moonlightDiscoveryRunning,
        discoveryResultOwnerToken: this.moonlightDiscoveryResultOwnerToken,
        discoveryResultGeneration: this.moonlightDiscoveryResultGeneration,
        initialDiscoveryEnabled:
          this.moonlightSettingsService.load().settings.network.discovery !== 'manualOnly',
        onStartDiscovery: (key: MoonlightHostAddDiscoveryKey): void => {
          this.startMoonlightLanDiscovery(key);
        },
        onPauseDiscovery: (_key: MoonlightHostAddDiscoveryKey): void => {
          this.stopMoonlightLanDiscovery();
        },
        onCancelOwner: (ownerToken: number): void => {
          this.invalidateMoonlightOwnerFence(ownerToken);
          this.moonlightHostService.cancelOwner(ownerToken);
        },
        onVerify: (
          address: MoonlightAddress,
          selectedServerUuid: string,
          key: MoonlightHostAddOperationKey
        ): Promise<MoonlightHostAddVerification | null> =>
          this.moonlightVerifyHost(address, selectedServerUuid, key),
        onPreparePairing: (key: MoonlightHostAddOperationKey):
          Promise<MoonlightPairingPreparation> => this.moonlightPairingPreparation(key),
        onAwaitPairing: (
          pin: string,
          key: MoonlightHostAddOperationKey
        ): Promise<MoonlightPairingCompletion> => this.moonlightAwaitPairing(pin, key),
        onCommitTrust: (accepted: boolean, key: MoonlightHostAddOperationKey): Promise<boolean> =>
          this.moonlightCommitTrust(accepted, key),
        onLoadCatalog: (key: MoonlightHostAddOperationKey):
          Promise<MoonlightHostAddCatalogSummary> => this.moonlightLoadCatalog(key),
        onSaveLocal: (
          state: MoonlightHostAddState,
          openCatalog: boolean,
          key: MoonlightHostAddOperationKey
        ): Promise<MoonlightLocalSaveResult> =>
          this.saveMoonlightHostLocally(state, openCatalog, key),
        onOpenExistingHost: (hostId: string, ownerToken: number): void => {
          this.openExistingMoonlightHost(hostId, ownerToken);
        },
        onBackToProtocols: (): void => {
          this.stopMoonlightLanDiscovery();
          this.moonlightHostService.disposeOwner(this.moonlightAddOwnerToken);
          this.clearMoonlightVerificationState();
          this.invalidateMoonlightCatalogHandoff();
          this.moonlightAddOwnerToken += 1;
          this.modernAddProtocol = '';
          this.addSheetShowsModernPicker = true;
        },
        onDiscardTemporaryState: (): Promise<void> =>
          this.revokeMoonlightTemporaryPairing(),
        onSaved: (hostId: string, openCatalog: boolean, ownerToken: number): void => {
          this.handleMoonlightHostSaved(hostId, openCatalog, ownerToken);
        }
      })
    } else if (this.modernAddProtocol === 'ssh') {
      SshAddFlow({
        keys: this.keyVault.getAllSshKeys(),
        onBackToProtocols: (): void => { this.modernAddProtocol = ''; this.addSheetShowsModernPicker = true; },
        onClose: (): void => { this.requestAddSheetClose(); },
        onSave: (host: RemoteHost, connectNow: boolean, proxyProfile: SshProxyProfileV1): void => {
          this.saveSshHostFromAddFlow(host, connectNow, proxyProfile);
        }
      })
    } else if (this.modernAddProtocol === 'vnc') {
      VncAddFlow({
        gateways: this.vncGateways.list(),
        onBackToProtocols: (): void => {
          this.modernAddProtocol = '';
          this.addSheetShowsModernPicker = this.vncAddFromModernPicker;
          this.vncAddFromModernPicker = false;
        },
        onOpenSettings: (): void => {
          this.pendingVncGatewayDirectoryOpen = true;
          this.requestAddSheetClose();
        },
        onSave: (values: VncHostValues, password: string, connectNow: boolean,
          plainStorageConfirmed: boolean): void => {
          this.saveVncHostFromAddFlow(values, password, connectNow, plainStorageConfirmed);
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

  private vncClassicGateways(): VncGatewayView[] {
    return this.vncGateways.list().filter((gateway: VncGatewayView): boolean =>
      gateway.enabled && gateway.transport === 'ultravnc_repeater' && gateway.repeaterMode === 'mode12');
  }

  private selectClassicVncTransport(transport: VncTransport): void {
    this.vncHostTransport = transport;
    this.sheetErr = '';
    if (transport === 'direct_tcp') {
      this.vncHostGatewayId = '';
      if (this.portVal <= 0) { this.portVal = 5900; }
      return;
    }
    const gateways: VncGatewayView[] = this.vncClassicGateways();
    if (this.vncHostGatewayId === '' && gateways.length > 0) {
      this.vncHostGatewayId = gateways[0].id;
    }
    const selected: VncGatewayView | undefined = gateways.find(
      (gateway: VncGatewayView): boolean => gateway.id === this.vncHostGatewayId);
    if (selected !== undefined) {
      this.portVal = selected.port;
      if (this.hostAddr.trim() === '' && selected.targetId.trim() !== '') {
        this.hostAddr = selected.targetId;
      }
    }
  }

  private selectClassicVncGateway(gateway: VncGatewayView): void {
    this.vncHostGatewayId = gateway.id;
    this.portVal = gateway.port;
    if (this.hostAddr.trim() === '' && gateway.targetId.trim() !== '') {
      this.hostAddr = gateway.targetId;
    }
    this.sheetErr = '';
  }

  @Builder vncClassicEditorFields() {
    Column() {
      Row() {
        Text('连接方式').fontSize(11).fontColor(this.pal().text2).fontFamily(this.font())
        Blank()
        Text('VNC Viewer').fontSize(10).fontColor(this.pal().text3).fontFamily(this.font())
      }.width('100%').margin({ bottom: 4 })
      Row() {
        Button('TCP 直连').layoutWeight(1).height(34).fontSize(11).borderRadius(8)
          .backgroundColor(this.vncHostTransport === 'direct_tcp' ? this.accentColor : this.pal().surface)
          .fontColor(this.vncHostTransport === 'direct_tcp' ? Color.White : this.pal().text2)
          .onClick((): void => { this.selectClassicVncTransport('direct_tcp'); })
        Button('UltraVNC Repeater').layoutWeight(1).height(34).fontSize(11).borderRadius(8)
          .margin({ left: 6 })
          .backgroundColor(this.vncHostTransport === 'ultravnc_repeater' ? this.accentColor : this.pal().surface)
          .fontColor(this.vncHostTransport === 'ultravnc_repeater' ? Color.White : this.pal().text2)
          .onClick((): void => { this.selectClassicVncTransport('ultravnc_repeater'); })
      }.width('100%').margin({ bottom: 8 })

      if (this.vncHostTransport === 'direct_tcp') {
        this.fieldRow('地址', '192.168.1.100 或 mac.local', this.hostAddr,
          (v: string): void => { this.hostAddr = v; })
        this.fieldRow('端口', '5900', this.portVal.toString(), (v: string): void => {
          const value: number = parseInt(v);
          this.portVal = isNaN(value) ? 5900 : value;
        })
      } else {
        this.fieldRow('Repeater Target ID', '目标 ID', this.hostAddr,
          (v: string): void => { this.hostAddr = v; })
        Text('仅支持 Viewer mode12；mode2 是服务端监听角色，不能从此处连接。')
          .fontSize(10).fontColor(this.pal().text3).fontFamily(this.font()).margin({ bottom: 8 })
        Text('选择 VNC Gateway').fontSize(11).fontColor(this.pal().text2).fontFamily(this.font())
          .margin({ bottom: 4 })
        if (this.vncClassicGateways().length === 0) {
          Text('暂无可用的 VNC Gateway，请先到中继服务器添加。')
            .fontSize(11).fontColor(this.pal().danger).width('100%').padding(10)
            .backgroundColor(this.pal().surface).borderRadius(8).margin({ bottom: 8 })
        } else {
          Column() {
            ForEach(this.vncClassicGateways(), (gateway: VncGatewayView) => {
              Row() {
                Column() {
                  Text(gateway.label).fontSize(12).fontColor(this.pal().text).fontFamily(this.font())
                  Text(gateway.host + ':' + gateway.port.toString() + ' · mode12')
                    .fontSize(10).fontColor(this.pal().text3).fontFamily(this.font()).margin({ top: 2 })
                }.alignItems(HorizontalAlign.Start).layoutWeight(1)
                if (this.vncHostGatewayId === gateway.id) {
                  SymbolGlyph($r('sys.symbol.checkmark')).fontSize(17).fontColor([this.accentColor])
                }
              }.width('100%').padding({ left: 10, right: 10, top: 8, bottom: 8 })
                .borderRadius(8)
                .backgroundColor(this.vncHostGatewayId === gateway.id ? this.pal().surface : Color.Transparent)
                .onClick((): void => { this.selectClassicVncGateway(gateway); })
            }, (gateway: VncGatewayView): string => gateway.id + ':' + this.hostViewRevision.toString())
          }.width('100%').backgroundColor(this.pal().surface).borderRadius(8).padding(4).margin({ bottom: 8 })
        }
        this.fieldRow('端口', 'Gateway 端口', this.portVal.toString(), (v: string): void => {
          const value: number = parseInt(v);
          this.portVal = isNaN(value) ? 5901 : value;
        })
      }

      this.pwdRow()
      if (this.vncHostPasswordConfigured && this.sheetPwd === '') {
        Text('已保存密码不会在编辑页回显；留空保存会保留现有密码，输入新密码才会替换。')
          .fontSize(10).fontColor(this.pal().text3).fontFamily(this.font()).lineHeight(16)
          .margin({ top: -4, bottom: 8 })
      }
      Row() {
        Text('记住密码').fontSize(13).fontColor(this.pal().text).fontFamily(this.font()).layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.vncHostRememberPassword })
          .selectedColor(this.accentColor).scale({ x: 0.82, y: 0.82 })
          .onChange((on: boolean): void => { this.vncHostRememberPassword = on; })
      }.width('100%').margin({ bottom: 8 })
      Text(this.vncHostRememberPassword
        ? '密码只会写入 VNC secret；编辑时不会回显已保存密码。'
        : '关闭后不保存密码，连接时可临时输入。')
        .fontSize(10).fontColor(this.pal().text3).fontFamily(this.font()).margin({ bottom: 8 })

      Row() {
        Text('只读模式').fontSize(13).fontColor(this.pal().text).fontFamily(this.font()).layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.vncHostViewOnly })
          .selectedColor(this.accentColor).scale({ x: 0.82, y: 0.82 })
          .onChange((on: boolean): void => { this.vncHostViewOnly = on; })
      }.width('100%').margin({ bottom: 8 })
      Row() {
        Text('剪贴板文本').fontSize(13).fontColor(this.pal().text).fontFamily(this.font()).layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.vncHostClipboardEnabled })
          .selectedColor(this.accentColor).scale({ x: 0.82, y: 0.82 })
          .onChange((on: boolean): void => { this.vncHostClipboardEnabled = on; })
      }.width('100%').margin({ bottom: 8 })

      Row() {
        Column() {
          Text('此主机单独设置缩放').fontSize(13).fontColor(this.pal().text).fontFamily(this.font())
          Text(this.vncHostDisplayOverrideEnabled ? '覆盖 VNC 全局显示设置' : '跟随 VNC 全局显示设置')
            .fontSize(10).fontColor(this.pal().text3).fontFamily(this.font()).margin({ top: 2 })
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.vncHostDisplayOverrideEnabled })
          .selectedColor(this.accentColor).scale({ x: 0.82, y: 0.82 })
          .onChange((on: boolean): void => { this.vncHostDisplayOverrideEnabled = on; })
      }.width('100%').margin({ bottom: 8 })
      if (this.vncHostDisplayOverrideEnabled) {
        Text('缩放').fontSize(11).fontColor(this.pal().text2).fontFamily(this.font()).margin({ bottom: 4 })
        Row() {
          Button('自适应').layoutWeight(1).height(32).fontSize(10).borderRadius(8)
            .backgroundColor(this.vncHostScalingMode === 'fit' ? this.accentColor : this.pal().surface)
            .fontColor(this.vncHostScalingMode === 'fit' ? Color.White : this.pal().text2)
            .onClick((): void => { this.vncHostScalingMode = 'fit'; })
          Button('整数').layoutWeight(1).height(32).fontSize(10).borderRadius(8).margin({ left: 5 })
            .backgroundColor(this.vncHostScalingMode === 'integer' ? this.accentColor : this.pal().surface)
            .fontColor(this.vncHostScalingMode === 'integer' ? Color.White : this.pal().text2)
            .onClick((): void => { this.vncHostScalingMode = 'integer'; })
          Button('1:1').layoutWeight(1).height(32).fontSize(10).borderRadius(8).margin({ left: 5 })
            .backgroundColor(this.vncHostScalingMode === 'one_to_one' ? this.accentColor : this.pal().surface)
            .fontColor(this.vncHostScalingMode === 'one_to_one' ? Color.White : this.pal().text2)
            .onClick((): void => { this.vncHostScalingMode = 'one_to_one'; })
          Button('平移').layoutWeight(1).height(32).fontSize(10).borderRadius(8).margin({ left: 5 })
            .backgroundColor(this.vncHostScalingMode === 'pan' ? this.accentColor : this.pal().surface)
            .fontColor(this.vncHostScalingMode === 'pan' ? Color.White : this.pal().text2)
            .onClick((): void => { this.vncHostScalingMode = 'pan'; })
        }.width('100%').margin({ bottom: 8 })
      }

      Text('安全策略').fontSize(11).fontColor(this.pal().text2).fontFamily(this.font()).margin({ bottom: 4 })
      Row() {
        Button('仅 TLS').layoutWeight(1).height(32).fontSize(10).borderRadius(8)
          .backgroundColor(this.vncHostSecurityPolicy === 'secure_only' ? this.accentColor : this.pal().surface)
          .fontColor(this.vncHostSecurityPolicy === 'secure_only' ? Color.White : this.pal().text2)
          .onClick((): void => { this.vncHostSecurityPolicy = 'secure_only'; this.vncHostTls = true; })
        Button('可信网络').layoutWeight(1).height(32).fontSize(10).borderRadius(8).margin({ left: 5 })
          .backgroundColor(this.vncHostSecurityPolicy === 'trusted_network' ? this.accentColor : this.pal().surface)
          .fontColor(this.vncHostSecurityPolicy === 'trusted_network' ? Color.White : this.pal().text2)
          .onClick((): void => { this.vncHostSecurityPolicy = 'trusted_network'; })
        Button('允许明文').layoutWeight(1).height(32).fontSize(10).borderRadius(8).margin({ left: 5 })
          .backgroundColor(this.vncHostSecurityPolicy === 'allow_plaintext' ? this.pal().danger : this.pal().surface)
          .fontColor(this.vncHostSecurityPolicy === 'allow_plaintext' ? Color.White : this.pal().text2)
          .onClick((): void => { this.vncHostSecurityPolicy = 'allow_plaintext'; })
      }.width('100%').margin({ bottom: 8 })
      Row() {
        Text('TLS').fontSize(13).fontColor(this.pal().text).fontFamily(this.font()).layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.vncHostTls })
          .selectedColor(this.accentColor).scale({ x: 0.82, y: 0.82 })
          .onChange((on: boolean): void => { this.vncHostTls = on; })
      }.width('100%').margin({ bottom: 4 })
      Text('VNC 当前不使用用户名；高级超时和 trust 仍在 VNC 设置页管理。')
        .fontSize(10).fontColor(this.pal().text3).fontFamily(this.font())
    }.width('100%')
  }

  @Builder sheetBuilder() {
    if (this.proto === 'vnc') {
      Column() {
        this.classicHostEditorForm()
      }.width('100%').height('100%')
    } else {
      this.classicHostEditorForm()
    }
  }

  @Builder private classicHostEditorForm() {
    Column() {
      // 标题
      Text(this.editingHostId !== '' ? '编辑主机' :
        (this.proto === 'ssh' ? '添加 SSH 终端' :
          (this.proto === 'rustdesk' ? '添加 RustDesk 主机' :
            (this.proto === 'vnc' ? '添加 VNC 主机' : '添加 RDP 主机'))))
        .fontSize(16).fontWeight(FontWeight.Bold).fontColor(this.pal().text)
        .width('100%').margin({ bottom: 12 }).fontFamily(this.font())

      Scroll() {
        Column() {
          // 协议选择
          Row() {
            this.protoBtn('RDP', 'rdp', 3389)
            this.protoBtn('RustDesk', 'rustdesk', 21116)
            this.protoBtn('VNC', 'vnc', 5900)
            this.protoBtn('SSH', 'ssh', 22)
          }.width('100%').margin({ bottom: 12 })

          // 名称
          this.fieldRow('名称', this.proto === 'ssh' ? 'Web 服务器' : '办公室电脑', this.label, (v: string): void => { this.label = v; })

          // RustDesk: 无需地址/端口/用户名, 走远程ID + 中继
          if (this.proto !== 'rustdesk') {
            if (this.proto === 'vnc') {
              this.vncClassicEditorFields()
            } else {
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
          }

          if (this.proto === 'rdp') {
            this.rdpAuthenticationModeSection()
            if (this.sheetRdpAuthMode === 'password') {
              this.rdpCredentialSection()
            }
          }

          // 密码：VNC 的密码/记住密码已由 vncClassicEditorFields 提供，
          // 通用密码行必须排除 VNC，避免 sheetRdpAuthMode 默认值造成双密码槽位。
          if (this.proto !== 'vnc' &&
            ((this.proto !== 'rdp' && this.proto !== 'vnc') || this.sheetRdpAuthMode === 'password')) {
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

            this.rustDeskTargetDeviceSection()

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

            this.rustDeskTotpBindingSection()

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
                    this.pendingRustDeskRelayDirectoryOpen = true;
                    this.requestAddSheetClose();
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
                        this.pendingRustDeskRelayDirectoryOpen = true;
                        this.requestAddSheetClose();
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
          if (this.proto !== 'vnc') {
            Button(this.editingHostId === '' ? '添加' : '保存').width('100%').height(40).fontSize(14)
              .fontWeight(FontWeight.Medium).backgroundColor(this.accentColor).fontColor('#FFFFFF')
              .borderRadius(10).margin({ top: 16 })
              .onClick((): void => { this.doAdd(); })
          }
        }.width('100%')
      }
      // The VNC editor owns a large Sheet. Its Scroll receives only the space
      // above the fixed footer, including while the keyboard resizes the Sheet.
      .constraintSize({ maxHeight: this.proto === 'vnc' ? '100%' : 420 })
      .layoutWeight(this.proto === 'vnc' ? 1 : 0)
      .scrollBar(BarState.Auto)
      .edgeEffect(EdgeEffect.Spring)
      .width('100%')
      if (this.proto === 'vnc') {
        Row() {
          Button(this.editingHostId === '' ? '添加' : '保存').width('100%').height(40).fontSize(14)
            .fontWeight(FontWeight.Medium).backgroundColor(this.accentColor).fontColor('#FFFFFF')
            .borderRadius(10).onClick((): void => { this.doAdd(); })
        }.width('100%').margin({ top: 12 })
      }
    }
    .layoutWeight(this.proto === 'vnc' ? 1 : 0)
    .padding({ left: 24, right: 24, top: 24, bottom: 24 })
    .safeAreaPadding({ bottom: 20 })
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
        if (protoVal === 'vnc') {
          this.prepareClassicVncEditor(null);
        }
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
      TextInput({ placeholder: enabled ?
        (this.proto === 'vnc' && this.vncHostPasswordConfigured
          ? '已保存密码（不回显；留空保留）' : '输入密码') : '已使用 Windows 凭据', text: this.sheetPwd })
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

      SshProxyEditor({
        keys: this.keyVault.getAllSshKeys(),
        value: this.sheetSshProxyEditorValue,
        onChange: (value: SshProxyEditorValue): void => {
          this.sheetSshProxyEditorValue = value;
        }
      })
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

  @Builder rustDeskTotpBindingSection() {
    Column({ space: 6 }) {
      Row() {
        Column() {
          Text('RustDesk 2FA 验证器（可选）').fontSize(12).fontColor(this.pal().text)
            .fontFamily(this.font()).maxLines(1)
          Text(this.rustDeskTotpBindingSummary()).fontSize(10).fontColor(this.pal().text3)
            .fontFamily(this.font()).maxLines(1)
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(16).fontColor([this.pal().text3])
      }.width('100%').padding({ left: 12, right: 10, top: 10, bottom: 10 })
      .borderRadius(10).backgroundColor(this.pal().surface)
      .onClick((): void => { this.openRustDeskTotpBinding(); })
      if (this.sheetRustdeskTotpEntryId !== '') {
        Row() {
          Column() {
            Text('连接时自动生成并填写').fontSize(12).fontColor(this.pal().text)
              .fontFamily(this.font())
            Text(this.totpPageLocked ?
              '仅保存条目 ID，连接前仍需系统身份认证' :
              '仅保存条目 ID，连接前无需额外身份认证')
              .fontSize(10).fontColor(this.pal().text3)
              .fontFamily(this.font())
          }.alignItems(HorizontalAlign.Start).layoutWeight(1)
          Toggle({ type: ToggleType.Switch, isOn: this.sheetRustdeskTotpAutoSubmit })
            .selectedColor(this.accentColor).scale({ x: 0.82, y: 0.82 })
            .onChange((on: boolean): void => { this.onRustDeskTotpAutoSubmitChange(on); })
        }.width('100%').padding({ left: 12, right: 8, top: 4, bottom: 4 })
      }
    }.width('100%').padding({ top: 6, bottom: 8 })
  }

  @Builder rustDeskTotpBindingPanel() {
    Column({ space: 12 }) {
      Row() {
        Column({ space: 3 }) {
          Text('绑定 RustDesk 2FA').fontSize(20).fontWeight(FontWeight.Bold)
            .fontColor(this.pal().text)
          Text('选择本机验证器后立即绑定并关闭此弹窗')
            .fontSize(12).fontColor(this.pal().text2)
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        Button('关闭').fontSize(13).backgroundColor(Color.Transparent)
          .fontColor(this.accentColor)
          .onClick((): void => { this.closeRustDeskTotpBinding(true); })
      }.width('100%')
      Text(this.totpPageLocked ?
        'TOTP 隐私保护已开启：绑定前需要系统身份认证。绑定只保存验证器条目 ID，不会复制或同步 TOTP 密钥。' :
        'TOTP 隐私保护未开启：绑定无需额外身份认证。绑定只保存验证器条目 ID，不会复制或同步 TOTP 密钥。')
        .fontSize(12).fontColor(this.pal().text2).width('100%')
      if (this.keyVault.getAllTotpEntries().length === 0) {
        Column({ space: 8 }) {
          Text('当前没有可用的 2FA 验证器').fontSize(14).fontColor(this.pal().text2)
          Text('请先在“2FA 验证器”中添加条目。').fontSize(12).fontColor(this.pal().text3)
        }.width('100%').padding(18).backgroundColor(this.pal().surface).borderRadius(10)
      } else {
        ForEach(this.keyVault.getAllTotpEntries(), (entry: TotpEntry) => {
          Row() {
            Column() {
              Text(entry.displayLabel()).fontSize(14).fontColor(this.pal().text)
                .fontFamily(this.font()).maxLines(1)
              Text(TotpEntry.algoLabel(entry.algorithm) + ' · ' + entry.digits.toString() + ' 位')
                .fontSize(11).fontColor(this.pal().text3).fontFamily(this.font())
            }.alignItems(HorizontalAlign.Start).layoutWeight(1)
            Button(this.sheetRustdeskTotpEntryId === entry.id ? '解除绑定' : '选择')
              .height(34).fontSize(12).borderRadius(9)
              .backgroundColor(this.sheetRustdeskTotpEntryId === entry.id ? this.pal().surface : this.accentColor)
              .fontColor(this.sheetRustdeskTotpEntryId === entry.id ? this.accentColor : Color.White)
              .onClick(async (): Promise<void> => {
                if (this.sheetRustdeskTotpEntryId === entry.id) {
                  this.clearRustDeskTotpBinding();
                } else {
                  await this.bindRustDeskTotpEntry(entry.id);
                }
              })
          }.width('100%').padding({ left: 12, right: 8, top: 8, bottom: 8 })
            .borderRadius(10).backgroundColor(this.pal().surface)
        }, (entry: TotpEntry): string => entry.id)
      }
    }.width('100%').padding({ left: 20, right: 20, top: 18, bottom: 24 })
      .backgroundColor(this.pal().card)
  }

  @Builder rustDeskProPreflightPanel() {
    Column({ space: 14 }) {
      Row() {
        Column({ space: 4 }) {
          Text('连接鉴权').fontSize(20).fontWeight(FontWeight.Bold).fontColor(this.pal().text)
          Text('鉴权成功后才会进入远程画面').fontSize(13).fontColor(this.pal().text2)
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        Button('取消').fontSize(14).backgroundColor(Color.Transparent).fontColor(this.accentColor)
          .enabled(this.rustDeskProPreflightState !== RustDeskProPreflightState.CONNECTING ||
            this.rustDeskProTwoFactorActive)
          .onClick((): void => {
            if (this.rustDeskProTwoFactorActive) {
              this.cancelRustDeskProTwoFactor();
            } else {
              this.cancelRustDeskProPreflight();
            }
          })
      }.width('100%')

      if (this.rustDeskProTwoFactorActive) {
        Text('远端设备要求 2FA 验证，请输入当前动态验证码。')
          .fontSize(14).fontColor(this.pal().text2).width('100%')
        if (this.rustDeskProTwoFactorEntryOptions.length > 0) {
          Text('本机 2FA 验证器（仅本次连接）')
            .fontSize(12).fontColor(this.pal().text2).width('100%')
          Scroll() {
            Column({ space: 6 }) {
              ForEach(this.rustDeskProTwoFactorEntryOptions,
                (option: RustDeskTwoFactorEntryOption) => {
                  Row({ space: 8 }) {
                    Column() {
                      Text(option.label).fontSize(13).fontColor(this.pal().text)
                        .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                      Text(option.locked ? option.detail + ' · 需身份认证' : option.detail)
                        .fontSize(10).fontColor(this.pal().text3)
                    }.alignItems(HorizontalAlign.Start).layoutWeight(1)
                    Button(this.rustDeskProTwoFactorSelectedEntryId === option.id ? '已选择' : '选择')
                      .height(30).fontSize(11)
                      .backgroundColor(this.rustDeskProTwoFactorSelectedEntryId === option.id
                        ? this.accentColor : this.pal().surface)
                      .fontColor(this.rustDeskProTwoFactorSelectedEntryId === option.id
                        ? Color.White : this.pal().text2)
                      .enabled(!this.rustDeskProTwoFactorSubmitting)
                      .onClick((): void => {
                        this.rustDeskProTwoFactorSelectedEntryId = option.id;
                        this.rustDeskProTwoFactorError = '';
                      })
                  }.width('100%').padding({ left: 10, right: 8, top: 6, bottom: 6 })
                    .backgroundColor(this.pal().surface).borderRadius(8)
                }, (option: RustDeskTwoFactorEntryOption): string => option.id)
            }.width('100%')
          }.width('100%').height(126)
          Button('填入所选验证码').width('100%').height(38).fontSize(12)
            .backgroundColor(this.accentColor).fontColor(Color.White).borderRadius(9)
            .enabled(!this.rustDeskProTwoFactorSubmitting &&
              this.rustDeskProTwoFactorSelectedEntryId.length > 0)
            .onClick((): void => {
              this.submitSelectedRustDeskProTwoFactor().catch((err: Error): void => {
                hilog.warn(0x0001, 'HostList', 'temporary RustDesk Pro 2FA submit failed: ' +
                  (err.message ? err.message : JSON.stringify(err)));
              });
            })
        }
        TextInput({ text: this.rustDeskProTwoFactorInput, placeholder: '输入 2FA 验证码' })
          .type(InputType.Normal).height(48).width('100%')
          .backgroundColor(this.pal().surface).borderRadius(10).maxLength(8)
          .onChange((value: string): void => {
            this.rustDeskProTwoFactorInput = value.replace(/[^0-9]/g, '');
            this.rustDeskProTwoFactorError = '';
            this.rustDeskProTwoFactorSubmitting = false;
          })
        Text(this.rustDeskProTwoFactorSubmitting ? '验证码已提交，等待远端确认…' :
          '验证码只用于当前连接，不会写入主机配置。')
          .fontSize(11).fontColor(this.pal().text3).width('100%')
        if (this.rustDeskProTwoFactorError.length > 0) {
          Text(this.rustDeskProTwoFactorError).fontSize(13).fontColor('#D92D20').width('100%')
        }
        Row({ space: 10 }) {
          Button('取消').layoutWeight(1).height(42).fontSize(13)
            .backgroundColor(this.pal().surface).fontColor(this.pal().text2).borderRadius(10)
            .onClick((): void => { this.cancelRustDeskProTwoFactor(); })
          Button(this.rustDeskProTwoFactorSubmitting ? '等待中' : '验证')
            .layoutWeight(1).height(42).fontSize(13).fontWeight(FontWeight.Medium)
            .backgroundColor(this.accentColor).fontColor(Color.White).borderRadius(10)
            .enabled(!this.rustDeskProTwoFactorSubmitting)
            .onClick((): void => { this.submitRustDeskProTwoFactor(); })
        }.width('100%')
      } else {
      Row({ space: 8 }) {
        Button('设备密码')
          .backgroundColor(this.rustDeskProAuthMode === 'password' ? this.accentColor : this.pal().surface)
          .fontColor(this.rustDeskProAuthMode === 'password' ? Color.White : this.pal().text)
          .enabled(this.rustDeskProPreflightState !== RustDeskProPreflightState.CONNECTING)
          .onClick((): void => {
            this.rustDeskProAuthMode = 'password';
            this.rustDeskProPreflightError = '';
            this.saveRustDeskProAuthDraft();
          })
        if (!this.isCurrentRustDeskPreflightDirect()) {
          Button('请求远端批准')
            .backgroundColor(this.rustDeskProAuthMode === 'request_approval' ? this.accentColor : this.pal().surface)
            .fontColor(this.rustDeskProAuthMode === 'request_approval' ? Color.White : this.pal().text)
            .enabled(this.rustDeskProPreflightState !== RustDeskProPreflightState.CONNECTING)
            .onClick((): void => {
              this.rustDeskProAuthMode = 'request_approval';
              this.rustDeskProPreflightError = '';
              this.saveRustDeskProAuthDraft();
            })
        }
      }.width('100%')

      if (this.rustDeskProAuthMode === 'password') {
        TextInput({ text: this.rustDeskProPassword, placeholder: '远程 RustDesk 设备密码' })
          .type(this.rustDeskProPasswordVisible ? InputType.Normal : InputType.Password)
          .showPasswordIcon(true)
          .enabled(this.rustDeskProPreflightState !== RustDeskProPreflightState.CONNECTING)
          .height(48).width('100%').backgroundColor(this.pal().surface).borderRadius(10)
          .onChange((value: string): void => {
            this.rustDeskProPassword = value;
            this.rustDeskProPreflightError = '';
            this.saveRustDeskProAuthDraft();
          })
        Text('密码类型').fontSize(12).fontColor(this.pal().text2)
          .margin({ top: 2, bottom: 5 })
        Row({ space: 8 }) {
          Button('一次性密码').layoutWeight(1).height(36).fontSize(12)
            .backgroundColor(this.rustDeskProPasswordMode === 0 ? this.accentColor : this.pal().surface)
            .fontColor(this.rustDeskProPasswordMode === 0 ? Color.White : this.pal().text2)
            .enabled(this.rustDeskProPreflightState !== RustDeskProPreflightState.CONNECTING)
            .onClick((): void => {
              this.rustDeskProPasswordMode = 0;
              this.saveRustDeskProAuthDraft();
            })
          Button('永久密码').layoutWeight(1).height(36).fontSize(12)
            .backgroundColor(this.rustDeskProPasswordMode === 1 ? this.accentColor : this.pal().surface)
            .fontColor(this.rustDeskProPasswordMode === 1 ? Color.White : this.pal().text2)
            .enabled(this.rustDeskProPreflightState !== RustDeskProPreflightState.CONNECTING)
            .onClick((): void => {
              this.rustDeskProPasswordMode = 1;
              this.saveRustDeskProAuthDraft();
            })
        }.width('100%').margin({ bottom: 6 })
        Text(this.rustDeskProPasswordMode === 0 ?
          '一次性密码过期后，下次连接需要重新输入。' :
          '永久密码由被控端 RustDesk 设置决定。')
          .fontSize(11).fontColor(this.pal().text3).width('100%').margin({ bottom: 8 })
        Row({ space: 8 }) {
          Checkbox({ name: 'rememberRustDeskProPassword', group: 'rustDeskProAuth' })
            .select(this.rustDeskProRememberPassword)
            .onChange((value: boolean): void => {
              this.rustDeskProRememberPassword = value;
              this.saveRustDeskProAuthDraft();
            })
          Text('记住设备密码').fontSize(14).fontColor(this.pal().text2)
        }.width('100%')
      } else {
        Text('连接请求会发送到远端设备，请在对方设备上点击批准。')
          .fontSize(14).fontColor(this.pal().text2).width('100%')
      }
      }

      if (this.rustDeskProPreflightError.length > 0) {
        Text(this.rustDeskProPreflightError).fontSize(13).fontColor('#D92D20').width('100%')
      }
      if (this.rustDeskProPreflightState === RustDeskProPreflightState.CONNECTING) {
        Row({ space: 10 }) {
          LoadingProgress().width(20).height(20).color(this.accentColor)
          Text(this.rustDeskProTwoFactorActive ? '等待远端确认 2FA…' :
            (this.rustDeskProAuthMode === 'request_approval' ? '等待远端批准…' : '正在后台验证密码…'))
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
    RustDeskRelayPage({ addTrigger: this.relayAddTrigger,
      rustDeskAddTrigger: this.relayRustDeskAddTrigger, vncAddTrigger: this.relayVncAddTrigger,
      hideTabBar: this.isDesktopDevice && this.breakpoint === 'xl',
      returnToHostAdd: this.rustDeskRelayReturnToHostAdd,
      onReturnToHostAdd: (relayId: string): void => {
        this.resumeRustDeskHostAddFromRelayDirectory(
          relayId);
      } })
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
                this.terminalFgColor = this.sshSettings.saveForegroundColor(hex);
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
              this.terminalFontSize = this.sshSettings.saveFontSize(sz);
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

  // ==================== 终端行距选择 Sheet ====================
  @Builder terminalLineSpacingSheet() {
    Column() {
      Row() {
        Text('终端行距').fontSize(19).fontWeight(FontWeight.Bold).fontColor(this.pal().text)
        Blank()
        Text(this.terminalLineSpacingLabel()).fontSize(16).fontWeight(FontWeight.Bold)
          .fontColor(this.pal().primary)
      }.width('100%').padding({ left: 24, right: 24, top: 20 }).margin({ bottom: 14 })

      Grid() {
        ForEach(this.terminalLineSpacings, (spacing: number) => {
          GridItem() {
            Column() {
              Text(Math.round(spacing * 100).toString() + '%')
                .fontSize(12)
                .fontColor(this.normalizedTerminalLineSpacing() === spacing ? '#FFFFFF' : this.pal().text)
            }
            .width(56).height(48).borderRadius(12).justifyContent(FlexAlign.Center)
            .backgroundColor(this.normalizedTerminalLineSpacing() === spacing
              ? this.accentColor : this.pal().card)
            .border({
              width: this.normalizedTerminalLineSpacing() === spacing ? 0 : 1,
              color: this.pal().cardBorder
            })
            .onClick((): void => { this.saveSshLineSpacing(spacing); })
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
    this.sheetRustdeskTargetDevice = 'computer';
    this.sheetRustdeskAdaptiveOrientation = false;
    this.sheetRustdeskTotpEntryId = '';
    this.sheetRustdeskTotpAutoSubmit = false;
    this.selectedRelayId = ''; this.selectedAccountId = '';
    this.selectedRdpCredentialId = '';
    this.sheetRdpAuthMode = 'password';
    this.sheetRdpRestrictedAdminSecretSource = 'ntlm_hash';
    this.sheetRdpRestrictedAdminHash = '';
    this.sheetRdpBlankPasswordConfirmed = false;
    this.sheetUseKey = false; this.sheetKeyPath = ''; this.sheetKeyText = '';
    this.sheetKeyId = ''; this.sheetKeyPassphrase = '';
    this.sheetKeyMode = 0;
    this.sheetSshProxyEditorValue = defaultSshProxyEditorValue();
    this.vncHostTransport = 'direct_tcp'; this.vncHostRepeaterMode = 'mode12';
    this.vncHostGatewayId = ''; this.vncHostPasswordConfigured = false;
    this.vncHostRememberPassword = false;
    this.vncHostViewOnly = true; this.vncHostDisplayOverrideEnabled = false;
    this.vncHostScalingMode = 'fit';
    this.vncHostClipboardEnabled = false; this.vncHostSecurityPolicy = 'secure_only';
    this.vncHostTls = true;
  }

  private commitClassicVncSave(values: VncHostValues, recordId: string, password: string,
    allowPlaintext: boolean, securityConfirmed: boolean = false): void {
    if (values.securityPolicy === 'allow_plaintext' && !securityConfirmed) {
      promptAction.showDialog({
        title: '确认允许 VNC 明文连接',
        message: '该策略会允许不加密的 VNC 连接。请确认当前网络可信，并了解密码和屏幕内容可能被窃听。',
        buttons: [{ text: '取消', color: this.pal().text2 }, { text: '确认保存', color: this.pal().danger }]
      }).then((result: Object): void => {
        const dialogResult: Record<string, number> = result as Record<string, number>;
        if (dialogResult['index'] === 1) {
          this.commitClassicVncSave(values, recordId, password, allowPlaintext, true);
        }
      });
      return;
    }
    if (!this.vncHosts.isReady()) {
      this.sheetErr = 'VNC 服务尚未完成云同步初始化，请稍后重试';
      return;
    }
    const result = this.vncHosts.save(values, recordId, password, allowPlaintext);
    if (!result.ok) {
      this.sheetErr = result.message || '保存 VNC 主机失败';
      return;
    }
    this.refreshHostSnapshotAfterMutation();
    promptAction.showToast({ message: recordId === '' ? 'VNC 主机已保存' : 'VNC 主机已更新', duration: 1800 });
    this.requestAddSheetClose();
  }

  private saveVncHostFromClassicForm(): void {
    const recordId: string = vncHostRecordIdFromUiId(this.editingHostId);
    const existing: VncHostView | null = recordId === '' ? null : this.vncHosts.find(recordId);
    const values: VncHostValues = {
      label: this.label.trim(),
      host: this.hostAddr.trim(),
      port: this.portVal,
      username: '',
      gatewayId: this.vncHostTransport === 'direct_tcp' ? '' : this.vncHostGatewayId.trim(),
      transport: this.vncHostTransport,
      repeaterMode: this.vncHostRepeaterMode,
      rememberPassword: this.vncHostRememberPassword,
      viewOnly: this.vncHostViewOnly,
      displayOverrideEnabled: this.vncHostDisplayOverrideEnabled,
      scalingMode: this.vncHostScalingMode,
      clipboardEnabled: this.vncHostClipboardEnabled,
      securityPolicy: this.vncHostSecurityPolicy,
      tls: this.vncHostTls,
      locked: existing === null ? false : existing.locked,
      lockType: existing === null ? 0 : existing.lockType
    };
    const errors: string[] = validateVncHost(values);
    if (errors.length > 0) { this.sheetErr = errors[0]; return; }
    if (values.securityPolicy === 'secure_only' && !values.tls) {
      this.sheetErr = '当前安全策略要求 TLS，请打开 TLS 或选择可信网络/允许明文';
      return;
    }
    if (values.transport === 'ultravnc_repeater' &&
      this.vncClassicGateways().find((gateway: VncGatewayView): boolean => gateway.id === values.gatewayId) === undefined) {
      this.sheetErr = '请选择已启用且支持 mode12 的 VNC Gateway';
      return;
    }
    const password: string = this.sheetPwd;
    if (password.length > 0 && values.rememberPassword) {
      const crypto: DataCrypto = DataCrypto.getInstance();
      if (crypto.isSetupComplete() && !crypto.isReady()) {
        this.sheetErr = '应用加密已锁定；请先解锁，或关闭“记住密码”后保存';
        return;
      }
      if (!crypto.isSetupComplete()) {
        promptAction.showDialog({
          title: '确认保存未加密密码',
          message: '应用加密未启用。打开“记住密码”会把 VNC 密码以未加密形式保存；关闭此选项即可仅临时使用。',
          buttons: [{ text: '关闭记住密码', color: this.pal().text2 },
            { text: '确认保存', color: this.pal().danger }]
        }).then((result: Object): void => {
          const dialogResult: Record<string, number> = result as Record<string, number>;
          if (dialogResult['index'] === 1) {
            this.commitClassicVncSave(values, recordId, password, true);
          }
        });
        return;
      }
    }
    this.commitClassicVncSave(values, recordId, password, false);
  }

  private doAdd(): void {
    if (!shouldAcceptHostAddSave(this.addSheetClosing, this.pendingAddSheetConnectHostId)) {
      return;
    }
    if (this.proto === 'vnc') {
      this.saveVncHostFromClassicForm();
      return;
    }
    const editingId: string = this.editingHostId;
    const existingHost: RemoteHost | undefined = editingId !== '' ? this.srv.getHost(editingId) : undefined;
    const h: RemoteHost = existingHost ? RemoteHost.fromJSON(existingHost.toJSON()) : new RemoteHost();
    let sshProxyProfileToSave: SshProxyProfileV1 | null = null;
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
      h.rustdeskTotpEntryId = this.sheetRustdeskTotpEntryId;
      h.rustdeskTotpAutoSubmit = this.sheetRustdeskTotpAutoSubmit && this.sheetRustdeskTotpEntryId !== '';
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
      h.rustdeskTargetDevice = this.effectiveSheetRustDeskTargetDevice();
      h.rustdeskAdaptiveOrientation = canUseRustDeskAdaptiveOrientation(
        h.protocol, h.rustdeskTargetDevice, this.sheetRustdeskAdaptiveOrientation,
        h.sourceType, h.rustdeskProManaged, h.rustdeskProPlatform);
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
      const proxyBuild: SshProxyEditorBuildResult = buildSshProxyProfile(
        h.id, h.host, h.port, this.sheetSshProxyEditorValue);
      if (!proxyBuild.valid || proxyBuild.profile === null) {
        this.sheetErr = proxyBuild.message || 'SSH 连接方式无效';
        return;
      }
      sshProxyProfileToSave = proxyBuild.profile;
      applySshProxyProfileToLegacyHost(h, proxyBuild.profile);
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
    const previousSshProxyProfile: SshProxyProfileV1 | null =
      h.protocol === 'ssh' ? this.sshProxyProfiles.load(h.id) : null;
    if (sshProxyProfileToSave !== null && !this.sshProxyProfiles.upsert(sshProxyProfileToSave)) {
      this.sheetErr = 'SSH 连接方式保存失败，主机未修改';
      return;
    }
    const desiredRustDeskTotpEntryId: string = h.protocol === 'rustdesk' ?
      h.rustdeskTotpEntryId.trim() : '';
    const desiredRustDeskTotpAutoSubmit: boolean = h.protocol === 'rustdesk' &&
      h.rustdeskTotpAutoSubmit && desiredRustDeskTotpEntryId !== '';
    let saved: boolean = false;
    if (editingId !== '') {
      saved = this.srv.updateHost(h);
    } else {
      saved = this.srv.addHost(h);
    }
    if (!saved) {
      if (sshProxyProfileToSave !== null) {
        if (previousSshProxyProfile !== null) {
          this.sshProxyProfiles.upsert(previousSshProxyProfile);
        } else {
          this.sshProxyProfiles.remove(h.id);
        }
      }
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
    if (h.protocol === 'rustdesk') {
      const hadBinding: boolean = existingHost !== undefined &&
        existingHost.rustdeskTotpEntryId !== '';
      const bindingSaved: boolean = desiredRustDeskTotpEntryId !== '' ?
        this.srv.setRustDeskPeerTwoFactorBinding(
          h.id, desiredRustDeskTotpEntryId, desiredRustDeskTotpAutoSubmit) :
        (!hadBinding || this.srv.clearRustDeskPeerTwoFactorBinding(h.id));
      if (!bindingSaved) {
        if (editingId === '') {
          const rolledBack: boolean = this.srv.removeHost(h.id);
          this.sheetErr = rolledBack ?
            'RustDesk 2FA 绑定保存失败，主机新增已撤销，请重试' :
            'RustDesk 2FA 绑定保存失败，且主机新增回滚未完成；请返回列表检查';
        } else {
          this.sheetErr = '主机配置已保存，但 RustDesk 2FA 绑定未能落盘，请重试绑定';
        }
        previousRestrictedAdminHash = '';
        return;
      }
    }
    if (editingId !== '') { this.editingHostId = ''; }
    if (existingHost !== undefined && existingHost.protocol === 'ssh' && h.protocol !== 'ssh') {
      this.sshProxyProfiles.remove(existingHost.id);
    }
    this.refreshHostSnapshotAfterMutation();
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
    if (!this.srv.addRdpCredential(credential)) {
      promptAction.showToast({
        message: this.mutationFailureMessage('Windows 凭据保存失败，请重试'), duration: 2400
      });
      return;
    }
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
    let saved: boolean = false;
    if (this.rdpCredEditId === '') {
      saved = this.srv.addRdpCredential(credential);
      if (!saved) {
        promptAction.showToast({
          message: this.mutationFailureMessage('Windows 凭据保存失败，请重试'), duration: 2400
        });
        return;
      }
      this.selectRdpCredential(credential.id);
      promptAction.showToast({ message: 'Windows 凭据已保存', duration: 1500 });
    } else {
      saved = this.srv.updateRdpCredential(credential);
      if (!saved) {
        promptAction.showToast({
          message: this.mutationFailureMessage('Windows 凭据更新失败，请重试'), duration: 2400
        });
        return;
      }
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
        if (!this.srv.removeRdpCredential(credential.id)) {
          promptAction.showToast({
            message: this.mutationFailureMessage('Windows 凭据删除失败，请重试'), duration: 2400
          });
          return;
        }
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
    if (!this.srv.updateHost(updated)) {
      promptAction.showToast({
        message: this.mutationFailureMessage('RustDesk 认证方式保存失败'), duration: 2200
      });
    }
  }

  private clearRustDeskSavedPassword(host: RemoteHost): void {
    const updated: RemoteHost = RemoteHost.fromJSON(host.toJSON());
    updated.password = '';
    if (this.srv.updateHost(updated)) {
      promptAction.showToast({ message: '已清除保存的 RustDesk 密码', duration: 1500 });
    } else {
      promptAction.showToast({
        message: this.mutationFailureMessage('RustDesk 密码清除失败'), duration: 2200
      });
    }
  }

  private clearRustDeskAuthTrust(host: RemoteHost): void {
    const updated: RemoteHost = RemoteHost.fromJSON(host.toJSON());
    updated.rustdeskAuthMode = 'password';
    updated.password = '';
    if (this.srv.updateHost(updated)) {
      promptAction.showToast({ message: '下次连接将重新询问认证方式', duration: 1500 });
    } else {
      promptAction.showToast({
        message: this.mutationFailureMessage('RustDesk 认证记录清除失败'), duration: 2200
      });
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

  private refreshVncTrustView(): void {
    this.vncTrustViews = this.vncTrust.list();
  }

  private vncTrustSummary(): string {
    const confirmed: number = this.vncTrustViews.filter((trust: VncTrustView): boolean => trust.confirmed).length;
    const pending: number = this.vncTrustViews.length - confirmed;
    return confirmed.toString() + ' 条已信任 · ' + pending.toString() + ' 条待本机确认';
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
      updated.sshJumpHostKeyAlgorithm = '';
      updated.sshJumpHostKeyFingerprintSha256 = '';
      updated.sshJumpHostKeyRawBase64 = '';
      updated.sshJumpHostKeyTrustedAt = 0;
      updated.sshJumpHostKeyTrustMode = 0;
      if (this.srv.updateHost(updated)) {
        promptAction.showToast({ message: '已忘记 SSH 指纹', duration: 1500 });
      } else {
        promptAction.showToast({
          message: this.mutationFailureMessage('SSH 指纹删除失败'), duration: 2200
        });
      }
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
      const info: SshHostKeyInfo = await this.loader.probeSshHostKeyAsync(
        host.host, host.port, this.sshPreflightProxy(host));
      if (!info.ok) {
        promptAction.showToast({
          message: '重新获取失败: ' + (info.errorMessage || '无法读取 SSH 主机指纹'),
          duration: 2500
        });
        return;
      }
      let jumpInfo: SshHostKeyInfo | null = null;
      if (this.sshPreflightUsesJump(host)) {
        jumpInfo = await this.loader.probeSshHostKeyAsync(host.proxyHost, host.proxyPort);
        if (!jumpInfo.ok) {
          promptAction.showToast({
            message: '跳板机指纹获取失败: ' + (jumpInfo.errorMessage || '无法读取 SSH 主机指纹'),
            duration: 2500
          });
          return;
        }
      }
      const updated: RemoteHost = RemoteHost.fromJSON(host.toJSON());
      this.applySshPreflightTrust(updated, info, jumpInfo);
      if (this.srv.updateHost(updated)) {
        promptAction.showToast({ message: 'SSH 指纹已更新', duration: 1500 });
      } else {
        promptAction.showToast({
          message: this.mutationFailureMessage('SSH 指纹保存失败'), duration: 2200
        });
      }
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
      updated.rdpCertificateNotBeforeMs = 0;
      updated.rdpCertificateNotAfterMs = 0;
      updated.rdpCertificateTrustedAt = 0;
      updated.rdpCertificateTrustMode = RDP_CERTIFICATE_UNKNOWN_TRUST_MODE;
      updated.rdpCertificateAllowUntrustedRoot = false;
      updated.rdpCertificateAllowHostMismatch = false;
      updated.rdpCertificateRouteIdentity = '';
      updated.rdpGatewayCertificateFingerprintSha256 = '';
      updated.rdpGatewayCertificateSubject = '';
      updated.rdpGatewayCertificateIssuer = '';
      updated.rdpGatewayCertificateCommonName = '';
      updated.rdpGatewayCertificateNotBeforeMs = 0;
      updated.rdpGatewayCertificateNotAfterMs = 0;
      updated.rdpGatewayCertificateTrustedAt = 0;
      updated.rdpGatewayCertificateTrustMode = RDP_CERTIFICATE_UNKNOWN_TRUST_MODE;
      updated.rdpGatewayCertificateAllowUntrustedRoot = false;
      updated.rdpGatewayCertificateAllowHostMismatch = false;
      updated.rdpGatewayCertificateRouteIdentity = '';
      if (this.srv.updateHost(updated)) {
        promptAction.showToast({ message: '已忘记 RDP 证书', duration: 1500 });
      } else {
        promptAction.showToast({
          message: this.mutationFailureMessage('RDP 证书删除失败'), duration: 2200
        });
      }
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
      let result: RdpPreflightResult;
      if (this.rdpCertificateUsesRouteProbe(host)) {
        result = await this.loader.probeRdpCertificateRouteAsync(
          this.rdpCertificateRouteRequest(host, Date.now()));
      } else {
        const info: RdpCertificateInfo = await this.loader.probeRdpCertificateAsync(
          host.host, host.port, host.customHostname);
        result = this.rdpCertificateResultFromDirectProbe(host, info, Date.now());
      }
      if (!result.ok || !result.targetCertificate.present ||
        (this.rdpCertificateRouteMode(host) === 'microsoft_rd_gateway' &&
          !result.gatewayCertificate.present)) {
        promptAction.showToast({
          message: '重新获取失败: ' + (result.errorMessage || '无法读取 RDP 主机证书'),
          duration: 2500
        });
        return;
      }
      const targetRiskFlags: string[] = rdpCertificateEffectiveRiskFlags(
        result.targetRiskFlags, result.targetCertificate.riskFlags);
      const gatewayRiskFlags: string[] = rdpCertificateEffectiveRiskFlags(
        result.gatewayRiskFlags, result.gatewayCertificate.riskFlags);
      if (!this.rdpCertificateResultMatchesLiveRoute(host, result)) {
        promptAction.showToast({
          message: 'RDP 路由在证书刷新期间发生变化，请重新获取 [E-RDP-CERT-ROUTE-STALE]',
          duration: 2500
        });
        return;
      }
      const updated: RemoteHost = RemoteHost.fromJSON(host.toJSON());
      const info: RdpCertificateInfo = this.rdpCertificateInfoFromRecord(result.targetCertificate);
      updated.rdpCertificateFingerprintSha256 = info.fingerprintSha256;
      updated.rdpCertificateSubject = info.subject;
      updated.rdpCertificateIssuer = info.issuer;
      updated.rdpCertificateCommonName = info.commonName;
      updated.rdpCertificateNotBeforeMs = info.notBeforeMs;
      updated.rdpCertificateNotAfterMs = info.notAfterMs;
      updated.rdpCertificateTrustedAt = Date.now();
      updated.rdpCertificateTrustMode = RDP_CERTIFICATE_EXPLICIT_TRUST_MODE;
      updated.rdpCertificateAllowUntrustedRoot = !info.rootTrusted;
      updated.rdpCertificateAllowHostMismatch = info.hostMismatch;
      updated.rdpCertificateRouteIdentity = result.routeIdentity;
      if (result.gatewayCertificate.present) {
        const gateway: RdpCertificateInfo = this.rdpCertificateInfoFromRecord(result.gatewayCertificate);
        updated.rdpGatewayCertificateFingerprintSha256 = gateway.fingerprintSha256;
        updated.rdpGatewayCertificateSubject = gateway.subject;
        updated.rdpGatewayCertificateIssuer = gateway.issuer;
        updated.rdpGatewayCertificateCommonName = gateway.commonName;
        updated.rdpGatewayCertificateNotBeforeMs = gateway.notBeforeMs;
        updated.rdpGatewayCertificateNotAfterMs = gateway.notAfterMs;
        updated.rdpGatewayCertificateTrustedAt = Date.now();
        updated.rdpGatewayCertificateTrustMode = RDP_CERTIFICATE_EXPLICIT_TRUST_MODE;
        updated.rdpGatewayCertificateAllowUntrustedRoot = !gateway.rootTrusted;
        updated.rdpGatewayCertificateAllowHostMismatch = gateway.hostMismatch;
        updated.rdpGatewayCertificateRouteIdentity = result.routeIdentity;
      }
      if (!this.srv.updateHost(updated)) {
        promptAction.showToast({ message: 'RDP 证书已读取，但保存信任失败', duration: 2200 });
        return;
      }
      const riskSummary: string = rdpCertificateRiskSummary(
        targetRiskFlags.concat(gatewayRiskFlags));
      promptAction.showToast({
        message: riskSummary.length > 0 ?
          'RDP 证书已更新并信任；仍需注意：' + riskSummary :
          'RDP 证书已更新并信任',
        duration: riskSummary.length > 0 ? 2800 : 1500
      });
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
