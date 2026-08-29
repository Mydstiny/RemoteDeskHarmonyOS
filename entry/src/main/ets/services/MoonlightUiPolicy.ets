import { MoonlightAppCacheEntry } from '../model/MoonlightAppCache';
import { MoonlightInputControlMode, MoonlightProfile } from '../model/MoonlightModels';
import { MoonlightSessionErrorCode, MoonlightSessionPhase } from './MoonlightSessionState';

export const MOONLIGHT_CONNECT_STAGE_DELAY_MS: number = 400;
export const MOONLIGHT_CONNECT_DURATION_DELAY_MS: number = 3000;
export const MOONLIGHT_CONNECT_DIAGNOSTICS_DELAY_MS: number = 10000;
export const MOONLIGHT_TOOLBAR_AUTO_HIDE_MS: number = 5000;
export const MOONLIGHT_DISAPPEAR_BACKGROUND_SIGNAL_WAIT_MS: number = 500;
export const MOONLIGHT_PRESENTATION_STALL_MS: number = 3000;

export type MoonlightCatalogStatus =
  'empty' | 'fresh' | 'stale' | 'partial' | 'offline' | 'host_busy' | 'error';
export type MoonlightCatalogFilter = 'all' | 'favorite' | 'available' | 'unavailable';
export type MoonlightLaunchBlocker =
  'none' | 'invalid_route' | 'host_unavailable' | 'certificate_changed' |
  'identity_unavailable' | 'app_unavailable' | 'metered_denied' |
  'host_busy' | 'session_active' | 'runtime_unavailable';
export type MoonlightConnectionQuality = 'good' | 'unstable' | 'poor' | 'reconnecting';
export type MoonlightToolbarAction =
  'control' | 'keyboard' | 'modifiers' | 'controller' | 'audio' | 'display' |
  'resetCanvas' | 'diagnostics' | 'more' | 'disconnect';
export type MoonlightSettingsSection =
  'video' | 'audio' | 'input' | 'networkSecurity' | 'diagnostics' | 'trust' |
  'data';

export interface MoonlightRouteIdentity {
  hostId: string;
  appId: string;
  valid: boolean;
}

export interface MoonlightCatalogItem {
  id: string;
  hostId: string;
  appId: string;
  title: string;
  artworkLocalPath: string;
  available: boolean;
  stale: boolean;
  favorite: boolean;
  profileId: string;
  sortOrder: number;
  lastCatalogAt: number;
}

export interface MoonlightCatalogOperationKey {
  ownerScopeId: string;
  hostId: string;
  generation: number;
}

export interface MoonlightTouchCancelPlan {
  cancelTrackedIds: number[];
  clearAllLocalContacts: boolean;
}

export type MoonlightResolvedControlMode = 'keyboardMouse' | 'trackpad';
export type MoonlightAdaptiveInputSource =
  'touch' | 'mouse' | 'touchpad' | 'keyboard' | 'unknown';

/** Device-class default used until adaptive mode observes a real input event. */
export function moonlightInitialAdaptiveControlMode(
  isPadDevice: boolean, isDesktopDevice: boolean, sessionWindowId: string
): MoonlightResolvedControlMode {
  return isPadDevice || isDesktopDevice || sessionWindowId.trim() !== '' ?
    'keyboardMouse' : 'trackpad';
}

/** Resolve an explicit preference without losing adaptive mode's live source. */
export function moonlightResolvedControlMode(
  preference: MoonlightInputControlMode,
  adaptiveMode: MoonlightResolvedControlMode
): MoonlightResolvedControlMode {
  return preference === 'adaptive' ? adaptiveMode : preference;
}

/** Adaptive mode follows the latest real touch or physical keyboard/pointer source. */
export function moonlightAdaptiveControlModeForSource(
  preference: MoonlightInputControlMode,
  current: MoonlightResolvedControlMode,
  source: MoonlightAdaptiveInputSource
): MoonlightResolvedControlMode {
  if (preference !== 'adaptive') { return moonlightResolvedControlMode(preference, current); }
  if (source === 'touch') { return 'trackpad'; }
  if (source === 'mouse' || source === 'touchpad' || source === 'keyboard') {
    return 'keyboardMouse';
  }
  return current;
}

/** Adaptive/key-mouse capture hardware keys; explicit phone trackpad stays opt-in. */
export function moonlightPhysicalKeyboardCaptureEnabled(
  configured: boolean, isPadDevice: boolean, isDesktopDevice: boolean,
  sessionWindowId: string, controlMode: MoonlightInputControlMode = 'trackpad'
): boolean {
  return configured || controlMode === 'adaptive' || controlMode === 'keyboardMouse' ||
    isPadDevice || isDesktopDevice || sessionWindowId.trim() !== '';
}

/**
 * Keep device/window-manager keys local unless system-shortcut forwarding is
 * explicitly available. Back, Home and power/lifecycle keys are never remote
 * input because they own the local session exit and device lifecycle.
 */
export function moonlightSystemKeyReserved(
  keyCode: number, altKey: boolean = false, ctrlKey: boolean = false,
  metaKey: boolean = false, forwardSystemShortcuts: boolean = false
): boolean {
  if (keyCode === 1 || keyCode === 2 || keyCode === 18 || keyCode === 19 ||
      keyCode === 2600 || keyCode === 2661 || keyCode === 2720 ||
      keyCode === 2721 || keyCode === 2722 || keyCode === 2802) {
    return true;
  }
  if (forwardSystemShortcuts) { return false; }
  if ((keyCode >= 9 && keyCode <= 17) || keyCode === 22 || keyCode === 23 ||
      keyCode === 40 || keyCode === 41 || (keyCode >= 2649 && keyCode <= 2651) ||
      keyCode === 2659 || keyCode === 2660 || (keyCode >= 2724 && keyCode <= 2725) ||
      keyCode === 2076 || keyCode === 2077) {
    return true;
  }
  return metaKey || (altKey && (keyCode === 2049 || keyCode === 2093)) ||
    (ctrlKey && keyCode === 2070);
}

/** PC session windows own immersion through RemoteSessionWindowFrameController. */
export function moonlightUsesEntryAbilityImmersiveBars(
  isDesktopDevice: boolean, sessionWindowId: string
): boolean {
  return !isDesktopDevice && sessionWindowId.trim() === '';
}

/**
 * A laid-out XComponent can change size without changing its native Surface or
 * renderer ownership. That geometry-only path must keep the decoder attached:
 * suspend/rebind is reserved for an actual Surface/renderer replacement where
 * the native renderer generation advances.
 */
export function moonlightCanResizeRendererInPlace(
  streamStartAttempted: boolean, nativeSessionId: number,
  surfaceSuspended: boolean, presentationTransferred: boolean
): boolean {
  if (surfaceSuspended || presentationTransferred) { return false; }
  return !streamStartAttempted || nativeSessionId > 0;
}

/**
 * Harmony TouchType.Cancel terminates the complete gesture even when the
 * framework supplies only a subset in changedTouches. The tracked contact
 * ledger is therefore authoritative for remote cancellation.
 */
export function moonlightTouchCancelPlan(trackedIds: number[],
  _changedTouchIds: number[], nativeInputAvailable: boolean): MoonlightTouchCancelPlan {
  const cancelTrackedIds: number[] = [];
  if (nativeInputAvailable) {
    trackedIds.forEach((id: number): void => {
      if (Number.isSafeInteger(id) && id > 0 && cancelTrackedIds.indexOf(id) < 0) {
        cancelTrackedIds.push(id);
      }
    });
  }
  return { cancelTrackedIds: cancelTrackedIds, clearAllLocalContacts: true };
}

/**
 * Content height for the embedded application-catalog BindSheet.
 *
 * The first two rows are allowed to grow the Sheet; additional rows stay in
 * the catalog Grid and scroll. This keeps short catalogs compact without
 * turning large catalogs into an unbounded Sheet.
 */
export function moonlightCatalogSheetHeight(
  itemCount: number, columnCount: number, topSafeHeightVp: number
): number {
  const safeItemCount: number = Number.isSafeInteger(itemCount) && itemCount > 0
    ? itemCount : 0;
  const safeColumnCount: number = Number.isSafeInteger(columnCount) && columnCount > 0
    ? columnCount : 1;
  const safeTopHeight: number = Number.isFinite(topSafeHeightVp)
    ? Math.min(72, Math.max(0, topSafeHeightVp)) : 0;
  // Header, status banner, search/filter row and bottom padding.
  const chromeHeight: number = 219 + safeTopHeight;
  if (safeItemCount === 0) { return chromeHeight + 190; }
  const rowCount: number = Math.ceil(safeItemCount / safeColumnCount);
  const visibleRows: number = Math.min(2, Math.max(1, rowCount));
  // The artwork consumes 200vp and the two-line metadata/actions section
  // needs another 124vp. Keeping the policy in sync with MoonlightAppCard
  // prevents the launch row being clipped in short, content-sized Sheets.
  const gridHeight: number = visibleRows * 324 + (visibleRows - 1) * 12;
  return Math.min(780, chromeHeight + gridHeight);
}

/**
 * Column count for the Moonlight application catalog.
 *
 * A centered BindSheet is much narrower than the Pad window that owns it, so
 * it must not inherit the window's lg/xl column count. Doing that squeezes the
 * cards into four or five phone-width columns and leaves unused tracks behind
 * when the catalog only contains one or two applications.
 */
export function moonlightCatalogGridColumnCount(
  breakpoint: string, embedded: boolean, itemCount: number
): number {
  let maximum: number = 5;
  if (breakpoint === 'sm') {
    maximum = 2;
  } else if (breakpoint === 'md') {
    maximum = 3;
  } else if (breakpoint === 'lg') {
    maximum = 4;
  }
  if (!embedded) { return maximum; }
  const sheetMaximum: number = Math.min(2, maximum);
  const safeItemCount: number = Number.isSafeInteger(itemCount) && itemCount > 0
    ? itemCount : sheetMaximum;
  return Math.min(sheetMaximum, safeItemCount);
}

export function moonlightCatalogHostReachable(
  serviceCode: string, operation: string, preflightTruth: string,
  partialAppCount: number
): boolean {
  if (operation !== 'catalog' || preflightTruth !== 'confirmed') { return false; }
  return serviceCode === 'ok' || serviceCode === 'cache_failed' ||
    (serviceCode === 'invalid_catalog' && partialAppCount > 0);
}

export interface MoonlightCatalogPresentation {
  status: MoonlightCatalogStatus;
  title: string;
  detail: string;
  preservesPreviousCatalog: boolean;
  refreshEnabled: boolean;
}

export interface MoonlightLaunchPreflightInput {
  routeValid: boolean;
  hostAvailable: boolean;
  certificateChanged: boolean;
  identityAvailable: boolean;
  appAvailable: boolean;
  meteredNetwork: boolean;
  meteredAllowed: boolean;
  hostBusy: boolean;
  activeSession: boolean;
  runtimeAvailable: boolean;
  adjustmentCount: number;
}

export interface MoonlightLaunchPreflightResult {
  allowed: boolean;
  blocker: MoonlightLaunchBlocker;
  title: string;
  detail: string;
  canRetry: boolean;
  canDowngrade: boolean;
}

export interface MoonlightConnectStagePresentation {
  visible: boolean;
  showElapsed: boolean;
  showDiagnostics: boolean;
  terminal: boolean;
  title: string;
  detail: string;
}

export interface MoonlightToolbarItem {
  action: MoonlightToolbarAction;
  label: string;
  dangerous: boolean;
  enabled: boolean;
  disabledReason: string;
}

export type MoonlightToolbarDeviceClass = 'pc' | 'pad' | 'phone';

export interface MoonlightToolbarLayout {
  deviceClass: MoonlightToolbarDeviceClass;
  edgeRail: boolean;
  iconSize: number;
  itemGap: number;
  maxVisibleItems: number;
  menuWidth: number;
  topOffset: number;
  autoHideMs: number;
  maxHeight: number;
}

export interface MoonlightControlCenterLayout {
  width: string;
  maxHeight: number;
  bodyMaxHeight: number;
  horizontalPadding: number;
  sectionGap: number;
  rowHeight: number;
}

export interface MoonlightDiagnosticsSnapshot {
  available: boolean;
  transportReady: boolean;
  videoReady: boolean;
  audioReady: boolean;
  inputReady: boolean;
  fps: number;
  latencyMs: number;
  bitrateKbps: number;
  configuredBitrateKbps: number;
  packetLossPercent: number;
  codec: string;
  width: number;
  height: number;
  targetFps: number;
  acceptedVideoFrames: number;
  droppedVideoFrames: number;
  decoderQueueDepth: number;
  decodeP50Us: number;
  decodeP95Us: number;
  renderP50Us: number;
  renderP95Us: number;
  codecLatencyMs: number;
  codecLatencyMaxMs: number;
  surfaceUpdateFailures: number;
  surfaceCoalescedNotifications: number;
  acceptedAudioPackets: number;
  rejectedAudioPackets: number;
  audioBytes: number;
  audioUnderruns: number;
  inputAccepted: number;
  inputDrops: number;
  presentedFrames: number;
  videoBytes: number;
  ingressAgeMs: number;
  presentationAgeMs: number;
  stalled: boolean;
}

/**
 * ArkUI can report page disappearance just before UIAbility.onWillBackground.
 * Preserve the connected page briefly so Home/background can be classified
 * before an explicit navigation teardown is allowed to stop the native owner.
 */
export function shouldDeferMoonlightDisappear(
  isBackground: boolean, sessionActive: boolean, routeTerminated: boolean
): boolean {
  return !isBackground && sessionActive && !routeTerminated;
}

/**
 * A native Sheet must not be mounted while the phone is still replacing its
 * portrait surface with the requested landscape surface. ArkUI otherwise can
 * retain the old SheetPage as an invisible hit-test owner after first frame.
 */
export function moonlightConnectSheetMountReady(
  gateNeeded: boolean, surfaceLayoutReady: boolean
): boolean {
  return gateNeeded && surfaceLayoutReady;
}

function boundedId(value: string): boolean {
  const normalized: string = typeof value === 'string' ? value.trim() : '';
  if (normalized.length < 1 || normalized.length > 128) { return false; }
  for (let i = 0; i < normalized.length; i++) {
    const code: number = normalized.charCodeAt(i);
    if (code < 0x20 || code === 0x7f) { return false; }
  }
  return true;
}

export function moonlightRouteIdentity(
  params: Record<string, Object> | null, requireApp: boolean = false
): MoonlightRouteIdentity {
  const hostValue: Object | undefined = params === null ? undefined : params['moonlightHostId'];
  const appValue: Object | undefined = params === null ? undefined : params['moonlightAppId'];
  const hostId: string = typeof hostValue === 'string' ? (hostValue as string).trim() : '';
  const appId: string = typeof appValue === 'string' ? (appValue as string).trim() : '';
  return {
    hostId: hostId,
    appId: appId,
    valid: boundedId(hostId) && (!requireApp || boundedId(appId))
  };
}

export function moonlightHostRouteParams(hostId: string): Record<string, Object> | null {
  if (!boundedId(hostId)) { return null; }
  const params: Record<string, Object> = {};
  params['moonlightHostId'] = hostId.trim();
  return params;
}

export function moonlightAppRouteParams(
  hostId: string, appId: string
): Record<string, Object> | null {
  if (!boundedId(hostId) || !boundedId(appId)) { return null; }
  const params: Record<string, Object> = {};
  params['moonlightHostId'] = hostId.trim();
  params['moonlightAppId'] = appId.trim();
  return params;
}

export function createMoonlightCatalogOperationKey(
  ownerScopeId: string, hostId: string, generation: number
): MoonlightCatalogOperationKey | null {
  if (!boundedId(ownerScopeId) || !boundedId(hostId) ||
      !Number.isSafeInteger(generation) || generation < 1) { return null; }
  return { ownerScopeId: ownerScopeId, hostId: hostId, generation: generation };
}

export function moonlightCatalogOperationIsCurrent(
  current: MoonlightCatalogOperationKey | null,
  candidate: MoonlightCatalogOperationKey | null
): boolean {
  return current !== null && candidate !== null &&
    current.ownerScopeId === candidate.ownerScopeId &&
    current.hostId === candidate.hostId &&
    current.generation === candidate.generation;
}

function profileForApp(
  profiles: MoonlightProfile[], hostId: string, appId: string
): MoonlightProfile | null {
  let selected: MoonlightProfile | null = null;
  for (let i = 0; i < profiles.length; i++) {
    if (profiles[i].hostId !== hostId || profiles[i].appId !== appId) { continue; }
    if (selected === null || profiles[i].favorite && !selected.favorite ||
        profiles[i].userOrder < selected.userOrder) {
      selected = profiles[i];
    }
  }
  return selected;
}

export function moonlightCatalogItems(
  entries: MoonlightAppCacheEntry[], profiles: MoonlightProfile[], nowMs: number
): MoonlightCatalogItem[] {
  const result: MoonlightCatalogItem[] = [];
  for (let i = 0; i < entries.length; i++) {
    const entry: MoonlightAppCacheEntry = entries[i];
    const profile: MoonlightProfile | null = profileForApp(
      profiles, entry.hostId, entry.appId);
    result.push({
      id: entry.id,
      hostId: entry.hostId,
      appId: entry.appId,
      title: entry.title,
      artworkLocalPath: entry.artworkLocalPath,
      available: entry.available,
      stale: entry.expiresAt <= nowMs,
      favorite: profile !== null && profile.favorite,
      profileId: profile === null ? '' : profile.id,
      sortOrder: profile === null ? entry.sortOrder : profile.userOrder,
      lastCatalogAt: entry.lastCatalogAt
    });
  }
  result.sort((left: MoonlightCatalogItem, right: MoonlightCatalogItem): number => {
    if (left.favorite !== right.favorite) { return left.favorite ? -1 : 1; }
    if (left.available !== right.available) { return left.available ? -1 : 1; }
    if (left.sortOrder !== right.sortOrder) { return left.sortOrder - right.sortOrder; }
    const leftTitle: string = left.title.toLocaleLowerCase();
    const rightTitle: string = right.title.toLocaleLowerCase();
    if (leftTitle !== rightTitle) { return leftTitle < rightTitle ? -1 : 1; }
    return left.id < right.id ? -1 : (left.id === right.id ? 0 : 1);
  });
  return result;
}

export function filterMoonlightCatalogItems(
  items: MoonlightCatalogItem[], query: string,
  filter: MoonlightCatalogFilter
): MoonlightCatalogItem[] {
  const needle: string = query.trim().toLocaleLowerCase();
  const result: MoonlightCatalogItem[] = [];
  for (let i = 0; i < items.length; i++) {
    const item: MoonlightCatalogItem = items[i];
    if (needle !== '' && item.title.toLocaleLowerCase().indexOf(needle) < 0) { continue; }
    if (filter === 'favorite' && !item.favorite) { continue; }
    if (filter === 'available' && (!item.available || item.stale)) { continue; }
    if (filter === 'unavailable' && item.available && !item.stale) { continue; }
    result.push(item);
  }
  return result;
}

export function moonlightCatalogPresentation(
  itemCount: number, staleCount: number, unavailableCount: number,
  online: boolean, refreshing: boolean, hostBusy: boolean,
  readFailed: boolean, partial: boolean
): MoonlightCatalogPresentation {
  if (hostBusy) {
    return {
      status: 'host_busy', title: '主机正在运行其他会话',
      detail: '保留当前目录；稍后刷新或先在主机端结束会话。',
      preservesPreviousCatalog: itemCount > 0, refreshEnabled: !refreshing
    };
  }
  if (readFailed) {
    return {
      status: itemCount > 0 ? 'stale' : 'error',
      title: itemCount > 0 ? '暂时无法更新，正在显示旧目录' : '无法读取应用目录',
      detail: '本地主机和应用配置不会因此删除。',
      preservesPreviousCatalog: itemCount > 0, refreshEnabled: !refreshing
    };
  }
  if (!online) {
    return {
      status: itemCount > 0 ? 'offline' : 'empty',
      title: itemCount > 0 ? '主机离线，正在显示缓存' : '主机离线',
      detail: itemCount > 0 ? '应用封面与配置来自本地缓存。' : '主机上线后可刷新应用目录。',
      preservesPreviousCatalog: itemCount > 0, refreshEnabled: !refreshing
    };
  }
  if (itemCount === 0) {
    return {
      status: 'empty', title: refreshing ? '正在读取应用目录' : '暂无可用应用',
      detail: refreshing ? '旧目录会保留到刷新成功。' : '请确认 Sunshine 已配置可串流应用。',
      preservesPreviousCatalog: false, refreshEnabled: !refreshing
    };
  }
  if (partial || unavailableCount > 0) {
    return {
      status: 'partial', title: '目录已部分更新',
      detail: '消失的应用会保留配置并标记为当前不可用。',
      preservesPreviousCatalog: true, refreshEnabled: !refreshing
    };
  }
  if (staleCount > 0) {
    return {
      status: 'stale', title: '正在显示缓存目录',
      detail: '刷新成功前不会清空现有应用。',
      preservesPreviousCatalog: true, refreshEnabled: !refreshing
    };
  }
  return {
    status: 'fresh', title: refreshing ? '正在检查更新' : '目录已更新',
    detail: refreshing ? '仍可使用当前目录。' : '应用信息来自当前本地目录快照。',
    preservesPreviousCatalog: true, refreshEnabled: !refreshing
  };
}

export function moonlightLaunchPreflight(
  input: MoonlightLaunchPreflightInput
): MoonlightLaunchPreflightResult {
  let blocker: MoonlightLaunchBlocker = 'none';
  if (!input.routeValid) { blocker = 'invalid_route'; }
  else if (input.activeSession) { blocker = 'session_active'; }
  else if (!input.hostAvailable) { blocker = 'host_unavailable'; }
  else if (input.certificateChanged) { blocker = 'certificate_changed'; }
  else if (!input.identityAvailable) { blocker = 'identity_unavailable'; }
  else if (!input.appAvailable) { blocker = 'app_unavailable'; }
  else if (input.meteredNetwork && !input.meteredAllowed) { blocker = 'metered_denied'; }
  else if (input.hostBusy) { blocker = 'host_busy'; }
  else if (!input.runtimeAvailable) { blocker = 'runtime_unavailable'; }
  if (blocker === 'none') {
    return {
      allowed: true, blocker: blocker, title: '准备开始串流',
      detail: input.adjustmentCount > 0 ?
        '有 ' + input.adjustmentCount.toString() + ' 项设置将按设备能力调整。' :
        '主机、身份、应用和设备能力检查已通过。',
      canRetry: false, canDowngrade: input.adjustmentCount > 0
    };
  }
  if (blocker === 'certificate_changed') {
    return { allowed: false, blocker: blocker, title: '主机证书已变化',
      detail: '为保护配对身份，必须重新核对并配对。', canRetry: false, canDowngrade: false };
  }
  if (blocker === 'runtime_unavailable') {
    return { allowed: false, blocker: blocker, title: '串流能力尚未开放',
      detail: '页面与本地数据已就绪，Host Control 和媒体运行时仍保持关闭。',
      canRetry: false, canDowngrade: false };
  }
  const retryable: boolean = blocker === 'host_unavailable' || blocker === 'host_busy' ||
    blocker === 'app_unavailable';
  return {
    allowed: false, blocker: blocker,
    title: blocker === 'session_active' ? '已有远程会话正在运行' : '启动前检查未通过',
    detail: blocker === 'metered_denied' ? '当前为计费网络，设置不允许自动串流。' :
      (blocker === 'identity_unavailable' ? '本地安全身份不可用，请重新配对。' :
        (blocker === 'host_unavailable' ? '主机当前不可用，请刷新目录后重试。' :
          (blocker === 'host_busy' ? '主机正在运行其他应用，请先结束现有会话。' :
            (blocker === 'app_unavailable' ? '主机当前未报告此应用，请刷新目录。' :
              '请按提示处理后再次检查。')))),
    canRetry: retryable, canDowngrade: false
  };
}

function phaseTitle(phase: MoonlightSessionPhase): string {
  if (phase === 'disconnected') { return '连接已结束'; }
  if (phase === 'launching') { return '正在启动主机应用'; }
  if (phase === 'negotiating') { return '正在协商串流'; }
  if (phase === 'video') { return '正在准备画面'; }
  if (phase === 'audio') { return '正在准备音频'; }
  if (phase === 'input') { return '正在准备控制'; }
  if (phase === 'firstFrame') { return '正在显示首帧'; }
  if (phase === 'reconnecting') { return '画面已暂停，正在重连'; }
  if (phase === 'stopping') { return '正在安全断开'; }
  if (phase === 'failed') { return '连接未完成'; }
  if (phase === 'streaming') { return '串流中'; }
  return '正在检查主机';
}

export function moonlightConnectStagePresentation(
  phase: MoonlightSessionPhase, elapsedMs: number,
  firstFrameSeen: boolean, errorCode: MoonlightSessionErrorCode = 'none'
): MoonlightConnectStagePresentation {
  const elapsed: number = Math.max(0, elapsedMs);
  const terminal: boolean = phase === 'failed' || phase === 'disconnected';
  const visible: boolean = !firstFrameSeen &&
    (elapsed >= MOONLIGHT_CONNECT_STAGE_DELAY_MS || terminal);
  return {
    visible: visible,
    showElapsed: visible && elapsed >= MOONLIGHT_CONNECT_DURATION_DELAY_MS,
    showDiagnostics: visible && elapsed >= MOONLIGHT_CONNECT_DIAGNOSTICS_DELAY_MS,
    terminal: terminal,
    title: phaseTitle(phase),
    detail: phase === 'failed' ? moonlightErrorActionText(errorCode) :
      (phase === 'disconnected' ? '连接已停止，可返回应用目录。' :
      (elapsed >= MOONLIGHT_CONNECT_DIAGNOSTICS_DELAY_MS ?
        '连接时间较长，可展开诊断或取消。' : '首帧出现前不会显示“已连接”。'))
  };
}

export function moonlightErrorActionText(errorCode: MoonlightSessionErrorCode): string {
  if (errorCode === 'certificate_changed') { return '证书已变化，请重新配对。'; }
  if (errorCode === 'host_busy') { return '主机正在运行其他会话，请稍后重试。'; }
  if (errorCode === 'codec_unsupported' || errorCode === 'decoder_failed') {
    return '当前画面能力不兼容，可降低设置后重试。';
  }
  if (errorCode === 'audio_failed') { return '音频初始化失败，可选择无音频继续。'; }
  if (errorCode === 'input_failed') { return '输入初始化失败，可选择只观看继续。'; }
  if (errorCode === 'network_unreachable' || errorCode === 'host_not_found') {
    return '无法到达主机，请检查网络或打开诊断。';
  }
  return '连接已停止，可重试或返回应用目录。';
}

export function moonlightToolbarDeviceClass(isDesktopDevice: boolean,
  isPadDevice: boolean): MoonlightToolbarDeviceClass {
  if (isDesktopDevice) { return 'pc'; }
  if (isPadDevice) { return 'pad'; }
  return 'phone';
}

export function moonlightToolbarLayout(isDesktopDevice: boolean, breakpoint: string,
  isPadDevice: boolean): MoonlightToolbarLayout {
  const normalized: string = breakpoint.trim().toLowerCase();
  const deviceClass: MoonlightToolbarDeviceClass =
    moonlightToolbarDeviceClass(isDesktopDevice, isPadDevice);
  const small: boolean = normalized === 'sm';
  // A phone stream is landscape-first, so its controls must remain a right
  // edge rail even after the wider viewport promotes the breakpoint to lg/xl.
  const edgeRail: boolean = deviceClass !== 'pc';
  const large: boolean = normalized === 'lg' || normalized === 'xl';
  return {
    deviceClass: deviceClass,
    edgeRail: edgeRail,
    iconSize: edgeRail ? 34 : (small ? 40 : 44),
    itemGap: edgeRail ? 4 : (small ? 6 : 8),
    maxVisibleItems: edgeRail ? 7 : (large ? 8 : 7),
    menuWidth: small ? 300 : (normalized === 'md' ? 340 : 360),
    topOffset: edgeRail ? 18 : (normalized === 'xl' ? 16 : 12),
    autoHideMs: !edgeRail && normalized === 'xl' ? MOONLIGHT_TOOLBAR_AUTO_HIDE_MS : 0,
    maxHeight: edgeRail ? 560 : 0
  };
}

/**
 * The remote input plane always owns the complete streamed viewport. The
 * floating rail is a transparent overlay whose visible children intercept
 * only their own hit regions. Reserving the rail's expanded width here leaves
 * a permanent dead strip at the right edge after the rail collapses and makes
 * HarmonyOS restore its local pointer before the remote desktop edge.
 */
export function moonlightRemoteInputSurfaceWidth(viewportWidth: number): number {
  return Number.isFinite(viewportWidth) ? Math.max(1, viewportWidth) : 1;
}

export function moonlightToolbarAutoHideDelayMs(layout: MoonlightToolbarLayout,
  pinned: boolean, menuOpen: boolean = false): number {
  if (pinned || menuOpen || layout.autoHideMs <= 0) { return 0; }
  return layout.autoHideMs;
}

export function moonlightControlCenterLayout(isDesktopDevice: boolean, breakpoint: string,
  isPadDevice: boolean, viewportWidth: number = 0,
  viewportHeight: number = 0): MoonlightControlCenterLayout {
  const normalized: string = breakpoint.trim().toLowerCase();
  const deviceClass: MoonlightToolbarDeviceClass =
    moonlightToolbarDeviceClass(isDesktopDevice, isPadDevice);
  const hasViewportWidth: boolean = Number.isFinite(viewportWidth) && viewportWidth > 0;
  const hasViewportHeight: boolean = Number.isFinite(viewportHeight) && viewportHeight > 0;
  const horizontalInset: number = deviceClass === 'phone' ? 16 : 24;
  const availableWidth: number = hasViewportWidth ?
    Math.max(1, viewportWidth - horizontalInset * 2) : 0;
  const preferredWidth: number = isDesktopDevice && normalized === 'xl' ? 620 :
    (deviceClass === 'phone' ? 520 : 560);
  const useFullWidth: boolean = normalized === 'sm' ||
    (hasViewportWidth && availableWidth < preferredWidth);

  const preferredHeight: number = deviceClass === 'phone' ? 520 :
    (deviceClass === 'pad' ? 680 : 720);
  const verticalInset: number = deviceClass === 'phone' ? 12 : 24;
  const availableHeight: number = hasViewportHeight ?
    Math.max(1, viewportHeight - verticalInset) : preferredHeight;
  const maxHeight: number = Math.round(Math.min(preferredHeight, availableHeight));
  const compact: boolean = maxHeight < 520;
  return {
    width: useFullWidth ? '100%' : Math.round(Math.min(preferredWidth,
      hasViewportWidth ? availableWidth : preferredWidth)).toString() + 'vp',
    maxHeight: maxHeight,
    // The fixed title area occupies about 66vp. Capping only the scrolling
    // body lets FIT_CONTENT shrink for short content while keeping every
    // control reachable in landscape phone and resized Pad windows.
    bodyMaxHeight: Math.max(1, maxHeight - 66),
    horizontalPadding: compact ? 16 : (normalized === 'sm' ? 20 : 24),
    sectionGap: compact ? 10 : (normalized === 'sm' ? 14 : 16),
    rowHeight: compact ? 56 : (normalized === 'sm' ? 64 : 68)
  };
}

function toolbarItem(action: MoonlightToolbarAction, label: string,
  dangerous: boolean = false): MoonlightToolbarItem {
  return { action: action, label: label, dangerous: dangerous,
    enabled: true, disabledReason: '' };
}

export function moonlightToolbarItems(
  breakpoint: string, audioAvailable: boolean,
  controllerAvailable: boolean, pipAvailable: boolean,
  maxVisibleItems: number = 0, keyboardAvailable: boolean = false,
  controlModeLabel: string = '触控板'
): MoonlightToolbarItem[] {
  const normalized: string = breakpoint.trim().toLowerCase();
  const keyboard: MoonlightToolbarItem = toolbarItem('keyboard', '键盘');
  keyboard.enabled = keyboardAvailable;
  keyboard.disabledReason = keyboardAvailable ? '' : '键盘输入通道尚未就绪';
  const items: MoonlightToolbarItem[] = [
    toolbarItem('control', controlModeLabel),
    keyboard, toolbarItem('modifiers', '组合键')
  ];
  const limit: number = maxVisibleItems > 0 ? maxVisibleItems :
    (normalized === 'sm' ? 7 : 8);
  if (limit <= 7) {
    const controller: MoonlightToolbarItem = toolbarItem('controller', '手柄');
    // This entry owns physical-controller management. It must remain
    // reachable before hardware is paired or a controller channel is ready.
    controller.enabled = true;
    controller.disabledReason = '';
    items.push(controller);
    const display: MoonlightToolbarItem = toolbarItem('display', pipAvailable ? '画中画' : '画面');
    display.enabled = pipAvailable;
    display.disabledReason = pipAvailable ? '' : '当前窗口或系统能力不支持画中画';
    items.push(display);
    items.push(toolbarItem('diagnostics', '性能'));
    items.push(toolbarItem('more', '更多'));
    items.push(toolbarItem('disconnect', '退出', true));
    return items;
  }
  const controller: MoonlightToolbarItem = toolbarItem('controller', '手柄');
  controller.enabled = true;
  controller.disabledReason = '';
  items.push(controller);
  if (normalized !== 'sm') {
    const audio: MoonlightToolbarItem = toolbarItem('audio', '音频');
    audio.enabled = false;
    audio.disabledReason = audioAvailable ? '音量请使用系统媒体音量调节' : '音频能力不可用';
    items.push(audio);
    const display: MoonlightToolbarItem = toolbarItem('display', pipAvailable ? '画中画' : '画面');
    display.enabled = pipAvailable;
    display.disabledReason = pipAvailable ? '' : '当前窗口或系统能力不支持画中画';
    items.push(display);
  }
  items.push(toolbarItem('diagnostics', '性能'));
  items.push(toolbarItem('more', '更多'));
  items.push(toolbarItem('disconnect', '退出', true));
  return items;
}

export function moonlightOverlayRequiresInputFlush(level: number): boolean {
  return Number.isSafeInteger(level) && level >= 3 && level <= 5;
}

/**
 * An in-flight recovery owns a native runtime lease until resume resolves.
 * Keep every interactive Sheet dismissal fenced so its onDisappear callback
 * cannot run before the successful launch handoff has been created.
 */
export function moonlightRecoverySheetDismissAllowed(recoveryActing: boolean): boolean {
  return !recoveryActing;
}

export function moonlightQualityLabel(quality: MoonlightConnectionQuality): string {
  if (quality === 'good') { return '良好'; }
  if (quality === 'unstable') { return '波动'; }
  if (quality === 'poor') { return '较差'; }
  return '正在重连';
}

export function moonlightSettingsSections(): MoonlightSettingsSection[] {
  return [
    'video', 'audio', 'input', 'networkSecurity', 'diagnostics', 'trust', 'data'
  ];
}

export function moonlightSettingsSectionLabel(section: MoonlightSettingsSection): string {
  if (section === 'video') { return '画面'; }
  if (section === 'audio') { return '音频'; }
  if (section === 'input') { return '控制与手柄'; }
  if (section === 'networkSecurity') { return '网络与安全'; }
  if (section === 'diagnostics') { return '诊断'; }
  if (section === 'trust') { return '配对与信任'; }
  return '数据管理';
}

export function moonlightMetric(value: number, suffix: string,
  digits: number = 0): string {
  if (!Number.isFinite(value) || value < 0) { return '—'; }
  return value.toFixed(Math.max(0, Math.min(2, digits))) + suffix;
}

export function moonlightMetricPairUs(firstUs: number, secondUs: number): string {
  if (!Number.isFinite(firstUs) || firstUs < 0 ||
      !Number.isFinite(secondUs) || secondUs < 0) { return '—'; }
  return (firstUs / 1000).toFixed(1) + ' / ' + (secondUs / 1000).toFixed(1) + ' ms';
}
