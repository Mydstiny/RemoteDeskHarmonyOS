import { display, promptAction, router } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { connection } from '@kit.NetworkKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { AppTheme, Palette, buildDark, buildLight } from '../common/Theme';
import { MoonlightBrandIcon } from '../components/moonlight/MoonlightBrandIcon';
import { MoonlightLaunchSheet } from '../components/moonlight/MoonlightLaunchSheet';
import { MoonlightCatalogDataSource } from '../datasources/MoonlightCatalogDataSource';
import {
  MoonlightEffectiveSettings,
  MoonlightHost,
  MoonlightSettings,
  moonlightInputControlMode
} from '../model/MoonlightModels';
import { AccountSessionCoordinator } from '../services/AccountSessionCoordinator';
import { CloudStore } from '../services/CloudStore';
import { AccountSessionLease } from '../services/AccountScopePolicy';
import { MoonlightHostLocalView, MoonlightLocalViewService } from '../services/MoonlightLocalViewService';
import {
  MoonlightHostContext,
  MoonlightHostService,
  MoonlightHostServiceResult,
  MoonlightNativeLaunchConfiguration
} from '../services/MoonlightHostService';
import { MoonlightSettingsLocalService } from '../services/MoonlightSettingsLocalService';
import { MoonlightSessionCoordinator } from '../services/MoonlightSessionCoordinator';
import {
  decodeMoonlightEffectiveSettings,
  encodeMoonlightEffectiveSettings,
  resolveMoonlightProductSettings
} from '../services/MoonlightSettingsPolicy';
import {
  moonlightDecoderCapability,
  probeMoonlightHardwareDecoderCapabilities
} from
  '../services/MoonlightVideoCapabilityService';
import {
  moonlightInstallationId,
  moonlightSessionRecoveryId,
  moonlightOwnerScopeFingerprint
} from '../services/MoonlightRuntimeSupport';
import { MoonlightSessionRecoveryStore } from '../services/MoonlightSessionRecoveryStore';
import {
  MoonlightSessionRecoveryDecodeCode,
  MoonlightSessionRecoveryHostState,
  MoonlightSessionRecoveryMarker,
  moonlightSessionRecoveryHostState,
  moonlightSessionRecoveryRequiresRemoteReset
} from '../services/MoonlightSessionRecoveryPolicy';
import {
  MoonlightRuntimeOwnerTokenAllocator,
  moonlightLaunchConfiguration,
  moonlightRuntimeContext,
  moonlightSelectedHostAddress
} from '../services/MoonlightRuntimeContextFactory';
import {
  MoonlightCatalogFilter,
  MoonlightCatalogItem,
  MoonlightCatalogOperationKey,
  MoonlightCatalogPresentation,
  MoonlightRouteIdentity,
  createMoonlightCatalogOperationKey,
  filterMoonlightCatalogItems,
  moonlightCatalogHostReachable,
  moonlightCatalogGridColumnCount,
  moonlightCatalogOperationIsCurrent,
  moonlightCatalogPresentation,
  moonlightCatalogSheetHeight,
  moonlightAppRouteParams,
  moonlightHostRouteParams,
  moonlightRecoverySheetDismissAllowed,
  moonlightRouteIdentity
} from '../services/MoonlightUiPolicy';
import { RemoteSessionWindowLauncher } from '../services/RemoteSessionWindowLauncher';
import { RemoteSessionWindowRequest } from '../services/RemoteSessionWindowPolicy';
import { RemoteSessionWindowAuthorizationService } from '../services/RemoteSessionWindowAuthorization';

class MoonlightLaunchFence {
  pageGeneration: number = 0;
  ownerScopeId: string = '';
  accountGeneration: number = 0;
  storeIdentity: string = '';
  storeInstanceId: number = 0;
  hostRecordId: string = '';
  serverUuid: string = '';
  appId: string = '';
  numericAppId: number = 0;
  hostAddress: string = '';
  ownerToken: number = 0;
  recoverySessionId: string = '';
}

/**
 * Non-secret launch ownership passed to the Sheet host only after Sunshine
 * has confirmed the application launch. The parent drains it from the outer
 * Catalog Sheet's onDisappear callback before presenting the stream page or
 * desktop window.
 */
export class MoonlightCatalogLaunchHandoff {
  routeParams: Record<string, Object> = {};
  hostId: string = '';
  title: string = '';
  ownerToken: number = 0;
  recoverySessionId: string = '';
}

function moonlightCatalogLaunchHandoffIsValid(
  handoff: MoonlightCatalogLaunchHandoff
): boolean {
  return handoff.hostId.trim() !== '' && handoff.title.trim() !== '' &&
    Number.isSafeInteger(handoff.ownerToken) && handoff.ownerToken > 0 &&
    handoff.recoverySessionId.trim() !== '';
}

/** Present a confirmed launch after every native Sheet in front of it is gone. */
export async function presentMoonlightCatalogLaunchHandoff(
  context: common.UIAbilityContext,
  isDesktopDevice: boolean,
  handoff: MoonlightCatalogLaunchHandoff
): Promise<boolean> {
  if (!moonlightCatalogLaunchHandoffIsValid(handoff)) { return false; }
  try {
    if (!isDesktopDevice) {
      await router.pushUrl({ url: 'pages/MoonlightStreamPage', params: handoff.routeParams });
      return true;
    }
    const authorizationToken: string =
      RemoteSessionWindowAuthorizationService.getInstance().issue(
        'moonlight', handoff.hostId, 'moonlight_preflight_complete');
    if (authorizationToken.length === 0) { return false; }
    const request: RemoteSessionWindowRequest = {
      target: 'moonlight_stream',
      protocol: 'moonlight',
      hostId: handoff.hostId,
      title: handoff.title,
      authorizationToken: authorizationToken,
      routeParams: handoff.routeParams
    };
    return await RemoteSessionWindowLauncher.open(context, request);
  } catch (error) {
    hilog.error(0x0014, 'MoonlightCatalog',
      'present launch destination failed desktop=' + (isDesktopDevice ? '1' : '0') +
      ' error=' + JSON.stringify(error));
    return false;
  }
}

/** Release a confirmed native launch if its post-Sheet destination cannot open. */
export function rejectMoonlightCatalogLaunchHandoff(
  context: common.UIAbilityContext,
  handoff: MoonlightCatalogLaunchHandoff
): void {
  const lease: AccountSessionLease | null =
    CloudStore.getInstance().currentAccountLease();
  if (lease !== null && CloudStore.getInstance().isLeaseCurrent(lease)) {
    const recoveryStore: MoonlightSessionRecoveryStore =
      new MoonlightSessionRecoveryStore();
    const recovery = recoveryStore.bind(context, lease, handoff.hostId);
    if (recovery.code === 'ready' && recovery.marker !== null &&
        recovery.marker.sessionId === handoff.recoverySessionId) {
      recoveryStore.update(handoff.recoverySessionId, {
        stage: 'terminal_uncertain', heartbeatAt: Date.now(),
        hostAppMayStillBeRunning: true, inputMayBeStuck: false,
        terminalAction: 'none'
      });
    }
  }
  new MoonlightHostService().disposeOwner(handoff.ownerToken);
}

@Component
struct MoonlightAppCard {
  @StorageLink('currentTheme') theme: string = 'light';
  @StorageLink('accentColor') accentColor: string = '#007DFF';
  @Prop item: MoonlightCatalogItem = {
    id: '', hostId: '', appId: '', title: '', artworkLocalPath: '',
    available: false, stale: true, favorite: false, profileId: '',
    sortOrder: 0, lastCatalogAt: 0
  };
  @State private artworkFailed: boolean = false;
  @Prop hostOnline: boolean = false;
  onMore: (item: MoonlightCatalogItem) => void = (_item: MoonlightCatalogItem): void => {};

  private pal(): Palette {
    return this.theme === 'light' ? buildLight(this.accentColor) : buildDark(this.accentColor);
  }

  private usable(): boolean {
    return this.hostOnline && this.item.available && !this.item.stale;
  }

  private availabilityLabel(): string {
    if (!this.hostOnline) { return '主机离线'; }
    if (this.item.stale) { return '目录已过期'; }
    return this.item.available ? '可启动' : '主机未报告此应用';
  }

  build() {
    Column() {
      Stack({ alignContent: Alignment.Center }) {
        if (this.item.artworkLocalPath !== '' && !this.artworkFailed) {
          Image(this.item.artworkLocalPath).width('100%').height('100%')
            .objectFit(ImageFit.Cover).onError((): void => { this.artworkFailed = true; })
        } else {
          Column() {
            MoonlightBrandIcon({ iconSize: 42, tint: this.accentColor,
              accessibilityLabel: this.item.title + ' 默认封面' })
            Text(this.item.title.substring(0, Math.min(2, this.item.title.length)))
              .fontSize(18).fontWeight(FontWeight.Bold).fontColor(this.pal().text2).margin({ top: 12 })
          }
        }
        Row() {
          if (this.item.favorite) {
            SymbolGlyph($r('sys.symbol.star_fill')).fontSize(15).fontColor(['#FFD45C'])
              .padding(7).backgroundColor('rgba(14,18,28,0.66)').borderRadius(12)
          }
          Blank().layoutWeight(1)
          Button() { Text('⋯').fontSize(20).fontColor('#FFFFFF') }
            .width(34).height(34).borderRadius(17).backgroundColor('rgba(14,18,28,0.66)')
            .onClick((): void => { this.onMore(this.item); }).accessibilityText('更多操作')
        }.width('100%').position({ x: 0, y: 0 }).padding(10)
        if (!this.usable()) {
          Text(!this.hostOnline ? '离线' : (this.item.stale ? '缓存' : '不可用'))
            .fontSize(10).fontColor('#FFFFFF')
            .padding({ left: 8, right: 8, top: 4, bottom: 4 })
            .backgroundColor('rgba(14,18,28,0.72)').borderRadius(10)
            .position({ x: 10, y: 166 })
        }
      }.width('100%').height(200).backgroundColor(this.pal().surface)

      Column() {
        Text(this.item.title).fontSize(14).fontWeight(FontWeight.Medium).fontColor(this.pal().text)
          .fontFamily(AppTheme.fontFamily).maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%').onClick((): void => { this.onMore(this.item); })
        Text(this.item.profileId === '' ? '使用主机默认设置' : '已保存应用配置')
          .fontSize(10).fontColor(this.pal().text3).width('100%').margin({ top: 5 })
        Blank().layoutWeight(1)
        Row() {
          Text(this.availabilityLabel())
            .fontSize(10).fontColor(this.usable() ? this.pal().success : this.pal().text3)
          Blank().layoutWeight(1)
          Button('启动').height(28).fontSize(11).fontWeight(FontWeight.Medium)
            .borderRadius(9).backgroundColor(Color.Transparent)
            .fontColor(this.usable() ? this.accentColor : this.pal().text3)
            .enabled(this.usable())
            .onClick((): void => {
              this.onMore(this.item);
            })
        }.width('100%').margin({ top: 6 })
      }.width('100%').height(124).padding(13)
    }.width('100%').height(324).backgroundColor(this.pal().card).borderRadius(20)
      .clip(true).border({ width: 0.5, color: this.pal().cardBorder })
      .shadow({ radius: 14, color: 'rgba(0,0,0,0.04)', offsetY: 4 })
      .opacity(this.usable() ? 1 : 0.78)
      .onClick((): void => { this.onMore(this.item); })
      .accessibilityText(this.item.title + '，' + (this.usable() ? '可启动' : '当前不可用'))
  }
}

@Component
export struct MoonlightAppCatalogSurface {
  @StorageLink('currentTheme') theme: string = 'light';
  @StorageLink('accentColor') accentColor: string = '#007DFF';
  @StorageProp('topRectHeight') topRectHeight: number = 0;
  @StorageProp('currentBreakpoint') breakpoint: string = 'sm';
  @StorageProp('isDesktopDevice') isDesktopDevice: boolean = false;
  @Prop embedded: boolean = false;
  @Prop requestedHostId: string = '';
  @State hostId: string = '';
  @State host: MoonlightHost | null = null;
  @State paired: boolean = false;
  @State allItems: MoonlightCatalogItem[] = [];
  @State query: string = '';
  @State filter: MoonlightCatalogFilter = 'all';
  @State statusCode: string = 'loading';
  @State refreshing: boolean = false;
  @State hostOnline: boolean = false;
  @State hostBusy: boolean = false;
  @State catalogPartial: boolean = false;
  @State visibleItemCount: number = 0;
  @State selectedItem: MoonlightCatalogItem | null = null;
  @State showLaunchSheet: boolean = false;
  @State launching: boolean = false;
  @State launchFeedback: string = '';
  @State launchSettingsEncoded: string = '';
  @State currentNetworkMetered: boolean = false;
  @State networkMeteringUnknown: boolean = false;
  @State meteredApprovedOnce: boolean = false;
  @State showRecoverySheet: boolean = false;
  @State recoveryChecking: boolean = false;
  @State recoveryActing: boolean = false;
  @State recoveryDecodeCode: MoonlightSessionRecoveryDecodeCode = 'absent';
  @State recoveryHostState: MoonlightSessionRecoveryHostState = 'host_unreachable';
  private recoveryMarker: MoonlightSessionRecoveryMarker | null = null;
  private recoveryLease: AccountSessionLease | null = null;
  private readonly dataSource: MoonlightCatalogDataSource = new MoonlightCatalogDataSource();
  private readonly viewService: MoonlightLocalViewService =
    new MoonlightLocalViewService(CloudStore.getInstance());
  private readonly hostService: MoonlightHostService = new MoonlightHostService();
  private readonly settingsService: MoonlightSettingsLocalService =
    new MoonlightSettingsLocalService(CloudStore.getInstance());
  private readonly recoveryStore: MoonlightSessionRecoveryStore =
    new MoonlightSessionRecoveryStore();
  private pageActive: boolean = false;
  private ownerScopeId: string = '';
  private refreshGeneration: number = 0;
  private refreshTimer: number = -1;
  private currentRefresh: MoonlightCatalogOperationKey | null = null;
  private activeRefreshOwnerToken: number = 0;
  private serverCertificateSha256: string = '';
  private launchGeneration: number = 0;
  private activeLaunchFence: MoonlightLaunchFence | null = null;
  private pendingLaunchSheetAction: string = '';
  private pendingLaunchHandoff: MoonlightCatalogLaunchHandoff | null = null;
  private pendingRecoveryLaunchHandoff: MoonlightCatalogLaunchHandoff | null = null;
  onClose: () => void = (): void => {};
  onOpenSettings: () => void = (): void => {};
  onOpenHostDetail: () => void = (): void => {};
  onLaunchRequested: (handoff: MoonlightCatalogLaunchHandoff) => void =
    (_handoff: MoonlightCatalogLaunchHandoff): void => {};
  onDismissAllowedChanged: (allowed: boolean) => void = (_allowed: boolean): void => {};

  private pal(): Palette {
    return this.theme === 'light' ? buildLight(this.accentColor) : buildDark(this.accentColor);
  }

  private topSafeHeight(): number {
    // Native Sheets already live inside the safe area. Reapplying the window
    // status-bar inset creates a large blank strip at the top on Pad.
    if (this.embedded) { return 0; }
    return this.topRectHeight > 0 ? px2vp(this.topRectHeight) : AppTheme.layout.statusBarH;
  }

  private columns(): string {
    const count: number = this.columnCount();
    if (count === 1) { return '1fr'; }
    if (count === 2) { return '1fr 1fr'; }
    if (count === 3) { return '1fr 1fr 1fr'; }
    if (count === 4) { return '1fr 1fr 1fr 1fr'; }
    return '1fr 1fr 1fr 1fr 1fr';
  }

  private columnCount(): number {
    return moonlightCatalogGridColumnCount(
      this.breakpoint, this.embedded, this.visibleItemCount);
  }

  private catalogSurfaceHeight(): number | string {
    if (!this.embedded) { return '100%'; }
    return moonlightCatalogSheetHeight(
      this.visibleItemCount, this.columnCount(), this.topSafeHeight());
  }

  aboutToAppear(): void {
    this.pageActive = true;
    this.setEmbeddedDismissAllowed(true);
    if (this.embedded) {
      this.hostId = this.requestedHostId.trim();
    } else {
      const params: Record<string, Object> = router.getParams() as Record<string, Object>;
      const route: MoonlightRouteIdentity = moonlightRouteIdentity(params);
      this.hostId = route.valid ? route.hostId : '';
    }
    this.loadLocal();
    // Pairing is only the local trust state. Revalidate the Sunshine endpoint
    // in the background as soon as the catalog page is shown, so the host card
    // never enters a launch flow with a stale reachability decision. The
    // launch BindSheet remains on this page while this handshake runs.
    this.scheduleBackgroundAuthentication();
  }

  aboutToDisappear(): void {
    this.pageActive = false;
    this.setEmbeddedDismissAllowed(true);
    this.invalidateRefresh();
    this.launchGeneration += 1;
    const ownerToken: number = this.activeLaunchFence === null ? 0 :
      this.activeLaunchFence.ownerToken;
    this.activeLaunchFence = null;
    this.launching = false;
    if (ownerToken > 0) { this.hostService.disposeOwner(ownerToken); }
  }

  private setEmbeddedDismissAllowed(allowed: boolean): void {
    if (this.embedded) { this.onDismissAllowedChanged(allowed); }
  }

  onPageShow(): void {
    if (this.hostId !== '') {
      this.loadLocal();
      this.scheduleBackgroundAuthentication();
    }
  }

  private scheduleBackgroundAuthentication(): void {
    setTimeout((): void => {
      if (!this.pageActive || this.hostId === '' || this.ownerScopeId === '' ||
          this.refreshing) { return; }
      this.performCatalogRefresh(false).catch((): void => {
        // The cached catalog remains usable; the status banner reflects that
        // the host is not currently reachable without interrupting the page.
        if (this.pageActive) {
          this.refreshing = false;
          this.currentRefresh = null;
          this.hostOnline = false;
          this.hostBusy = false;
        }
      });
    }, 0);
  }

  private loadLocal(): void {
    if (this.hostId === '') { this.statusCode = 'invalid_route'; return; }
    const view: MoonlightHostLocalView = this.viewService.loadHost(this.hostId, Date.now());
    if (!view.ok || view.host === null) {
      this.statusCode = view.code;
      this.host = null;
      this.ownerScopeId = '';
      this.serverCertificateSha256 = '';
      this.allItems = [];
      this.recoveryLease = null;
      this.applyFilter();
      return;
    }
    this.host = view.host;
    this.ownerScopeId = view.lease === null ? '' : view.lease.ownerScopeId;
    this.paired = view.paired;
    this.serverCertificateSha256 = view.serverCertificateSha256;
    this.allItems = view.catalogItems;
    this.statusCode = view.code;
    this.applyFilter();
    this.inspectRecoveryMarker();
  }

  private inspectRecoveryMarker(): void {
    const lease: AccountSessionLease | null = CloudStore.getInstance().currentAccountLease();
    let context: common.UIAbilityContext | null = null;
    try { context = getContext(this) as common.UIAbilityContext; } catch (_error) {}
    if (lease === null || context === null ||
        !CloudStore.getInstance().isLeaseCurrent(lease)) {
      this.recoveryLease = null;
      return;
    }
    const decoded = this.recoveryStore.bind(context, lease, this.hostId);
    this.recoveryLease = lease;
    this.recoveryDecodeCode = decoded.code;
    this.recoveryMarker = decoded.marker;
    if (decoded.code === 'corrupt' || decoded.code === 'too_new') {
      this.showRecoverySheet = true;
      return;
    }
    if (decoded.code === 'ready' && decoded.marker !== null &&
        decoded.marker.hostId === this.hostId) {
      this.showRecoverySheet = true;
      this.verifyRecoveryHostState().catch((): void => {
        this.recoveryChecking = false;
        this.recoveryHostState = 'host_unreachable';
      });
      return;
    }
    this.showRecoverySheet = false;
  }

  private async verifyRecoveryHostState(): Promise<void> {
    if (this.recoveryChecking || this.recoveryActing || this.host === null ||
        this.recoveryMarker === null) { return; }
    const marker: MoonlightSessionRecoveryMarker = this.recoveryMarker;
    const appId: number = Number.parseInt(marker.appId, 10);
    const lease: AccountSessionLease | null = CloudStore.getInstance().currentAccountLease();
    if (lease === null || !CloudStore.getInstance().isLeaseCurrent(lease) ||
        !Number.isSafeInteger(appId) || appId <= 0) {
      this.recoveryHostState = 'host_unreachable';
      return;
    }
    const ownerToken: number = MoonlightRuntimeOwnerTokenAllocator.getInstance().next();
    const generation: number = Math.max(1, ++this.launchGeneration);
    const settings: MoonlightSettings = this.settingsService.load().settings;
    const context: MoonlightHostContext | null = this.runtimeContext(
      this.host, lease, ownerToken, generation,
      this.serverCertificateSha256, settings);
    if (context === null) {
      this.hostService.disposeOwner(ownerToken);
      this.recoveryHostState = 'host_unreachable';
      return;
    }
    this.recoveryChecking = true;
    let result: MoonlightHostServiceResult | null = null;
    try {
      // userConfirmedTermination=false is the existing read-only Host Control
      // preflight. It never quits an app.
      result = await this.hostService.quit(context, appId, false);
    } finally {
      this.hostService.disposeOwner(ownerToken);
      this.recoveryChecking = false;
    }
    const current = this.recoveryStore.snapshot();
    if (!this.pageActive || current.code !== 'ready' || current.marker === null ||
        current.marker.sessionId !== marker.sessionId || result === null) { return; }
    this.recoveryMarker = current.marker;
    this.recoveryHostState = moonlightSessionRecoveryHostState(
      result.code, result.nativeResult !== null && result.nativeResult.idempotent);
  }

  private recoveryStateLabel(): string {
    if (this.recoveryDecodeCode === 'corrupt') {
      return '本机会话恢复记录已损坏，无法安全判断上次会话状态。重置只删除本机恢复提示，不会结束 Sunshine 主机上的应用。';
    }
    if (this.recoveryDecodeCode === 'too_new') {
      return '这条本机会话恢复记录来自更高版本。建议保留记录并升级应用；只有确认不再需要恢复时才强制重置。';
    }
    if (this.recoveryChecking) { return '正在只读核对主机当前应用…'; }
    if (this.recoveryHostState === 'matching_app_running') {
      return '主机仍在运行该应用，可安全恢复串流或结束主机应用。';
    }
    if (this.recoveryHostState === 'host_stopped') {
      return '主机已停止该应用，可清除这条本地恢复记录。';
    }
    if (this.recoveryHostState === 'different_app_running') {
      return '主机正在运行另一个应用，本应用不会被自动结束。';
    }
    return '暂时无法确认主机状态；恢复记录会继续保留。';
  }

  private async resumeRecoveredSession(): Promise<void> {
    if (this.recoveryActing || this.recoveryChecking ||
        this.recoveryHostState !== 'matching_app_running' ||
        this.host === null || this.recoveryMarker === null) { return; }
    const previousMarker: MoonlightSessionRecoveryMarker = this.recoveryMarker;
    const lease: AccountSessionLease | null = CloudStore.getInstance().currentAccountLease();
    let uiContext: common.UIAbilityContext;
    try {
      uiContext = getContext(this) as common.UIAbilityContext;
    } catch (_error) {
      promptAction.showToast({ message: '无法刷新本地会话恢复边界', duration: 2200 });
      return;
    }
    if (lease === null || !CloudStore.getInstance().isLeaseCurrent(lease)) { return; }
    if (!MoonlightSessionCoordinator.getInstance().reconcileNativeTerminalReceipt()) {
      promptAction.showToast({
        message: '上一条 Moonlight 原生会话仍在安全释放，请稍后重试', duration: 2200
      });
      return;
    }
    // reconcileNativeTerminalReceipt() can synchronously prove that the old
    // local disconnect completed and remove its durable recovery marker. The
    // catalog component may still hold the pre-reconcile projection, though.
    // Rebind before mutating Sunshine and create a fresh recovery owner when
    // the old marker was cleanly cleared; otherwise the new Stream page would
    // reject the confirmed /resume and Sunshine would wait ten seconds for an
    // RTSP client that can never start.
    const rebound = this.recoveryStore.bind(uiContext, lease, this.hostId);
    let marker: MoonlightSessionRecoveryMarker | null = null;
    if (rebound.code === 'ready' && rebound.marker !== null &&
        rebound.marker.sessionId === previousMarker.sessionId &&
        rebound.marker.hostId === previousMarker.hostId &&
        rebound.marker.appId === previousMarker.appId) {
      marker = rebound.marker;
    } else if (rebound.code === 'absent') {
      marker = this.recoveryStore.begin({
        sessionId: moonlightSessionRecoveryId(),
        hostId: previousMarker.hostId,
        profileId: previousMarker.profileId,
        appId: previousMarker.appId
      }, Date.now());
    }
    if (marker === null) {
      this.recoveryDecodeCode = rebound.code;
      this.recoveryMarker = rebound.marker;
      this.showRecoverySheet = rebound.code !== 'absent';
      promptAction.showToast({
        message: rebound.code === 'absent' ?
          '无法建立新的本地会话恢复边界，请重试' :
          '会话恢复状态已变化，请重新确认',
        duration: 2400
      });
      return;
    }
    this.recoveryDecodeCode = 'ready';
    this.recoveryMarker = marker;
    const numericAppId: number = Number.parseInt(marker.appId, 10);
    const effective: MoonlightEffectiveSettings = this.productSettings(
      this.settingsService.load().settings);
    const encoded: string = encodeMoonlightEffectiveSettings(effective);
    if (encoded === '' || !Number.isSafeInteger(numericAppId) || numericAppId <= 0 ||
        !CloudStore.getInstance().isLeaseCurrent(lease)) { return; }
    const ownerToken: number = MoonlightRuntimeOwnerTokenAllocator.getInstance().next();
    const generation: number = Math.max(1, ++this.launchGeneration);
    const context: MoonlightHostContext | null = this.runtimeContext(
      this.host, lease, ownerToken, generation,
      this.serverCertificateSha256, effective.effective);
    const hostAddress: string = this.selectedHostAddress(this.host, effective.effective);
    if (context === null || hostAddress === '') {
      this.hostService.disposeOwner(ownerToken);
      return;
    }
    this.setEmbeddedDismissAllowed(false);
    this.recoveryActing = true;
    const configuration: MoonlightNativeLaunchConfiguration =
      this.launchConfiguration(effective.effective);
    const result: MoonlightHostServiceResult = await this.hostService.resume(
      context, numericAppId, configuration);
    if (!this.pageActive || !CloudStore.getInstance().isLeaseCurrent(lease) ||
        this.recoveryMarker === null ||
        this.recoveryMarker.sessionId !== marker.sessionId) {
      this.hostService.disposeOwner(ownerToken);
      this.recoveryActing = false;
      this.setEmbeddedDismissAllowed(true);
      return;
    }
    if (!result.ok || result.nativeResult === null) {
      this.markLaunchUncertain(marker.sessionId);
      this.hostService.disposeOwner(ownerToken);
      this.recoveryActing = false;
      this.setEmbeddedDismissAllowed(true);
      promptAction.showToast({ message: '恢复串流失败（' + result.code + '）', duration: 2200 });
      return;
    }
    this.recoveryStore.update(marker.sessionId, {
      stage: 'host_launch_confirmed', heartbeatAt: Date.now(),
      hostAppMayStillBeRunning: true,
      inputMayBeStuck: marker.inputMayBeStuck,
      terminalAction: 'none'
    });
    const params: Record<string, Object> | null =
      moonlightAppRouteParams(marker.hostId, marker.appId);
    if (params === null) {
      this.hostService.disposeOwner(ownerToken);
      this.recoveryActing = false;
      this.setEmbeddedDismissAllowed(true);
      return;
    }
    params['launchRequestId'] = result.key.requestId;
    params['launchGeneration'] = result.key.generation;
    params['launchOwnerToken'] = result.key.ownerToken;
    params['serverUuid'] = this.host.serverUuid;
    params['numericAppId'] = numericAppId;
    params['hostAddress'] = hostAddress;
    params['streamWidth'] = configuration.width as number;
    params['streamHeight'] = configuration.height as number;
    params['moonlightEffectiveSettings'] = encoded;
    params['launchOwnerScopeFingerprint'] = moonlightOwnerScopeFingerprint(lease.ownerScopeId);
    params['launchAccountGeneration'] = lease.generation;
    params['launchInstallationId'] = moonlightInstallationId(lease.storeIdentity);
    params['launchStoreInstanceId'] = lease.storeInstanceId;
    params['moonlightRecoverySessionId'] = marker.sessionId;
    params['resetRemoteInputBeforeAdmission'] =
      moonlightSessionRecoveryRequiresRemoteReset(marker);
    const recoveredAppId: string = marker.appId;
    const appTitle: string = this.allItems.find(
      (item: MoonlightCatalogItem): boolean => item.appId === recoveredAppId)?.title || recoveredAppId;
    const handoff: MoonlightCatalogLaunchHandoff = new MoonlightCatalogLaunchHandoff();
    handoff.routeParams = params;
    handoff.hostId = marker.hostId;
    handoff.title = (this.host.displayName || 'Moonlight') + ' — ' + appTitle;
    handoff.ownerToken = ownerToken;
    handoff.recoverySessionId = marker.sessionId;
    this.pendingRecoveryLaunchHandoff = handoff;
    this.recoveryActing = false;
    this.setEmbeddedDismissAllowed(true);
    this.showRecoverySheet = false;
    if (this.embedded) { this.handleRecoverySheetDisappear(); }
  }

  private async quitRecoveredHostApp(): Promise<void> {
    if (this.recoveryActing || this.recoveryChecking ||
        this.recoveryHostState !== 'matching_app_running' ||
        this.host === null || this.recoveryMarker === null) { return; }
    const marker: MoonlightSessionRecoveryMarker = this.recoveryMarker;
    const appId: number = Number.parseInt(marker.appId, 10);
    const lease: AccountSessionLease | null = CloudStore.getInstance().currentAccountLease();
    if (lease === null || !Number.isSafeInteger(appId) || appId <= 0 ||
        !CloudStore.getInstance().isLeaseCurrent(lease)) { return; }
    const ownerToken: number = MoonlightRuntimeOwnerTokenAllocator.getInstance().next();
    const context: MoonlightHostContext | null = this.runtimeContext(
      this.host, lease, ownerToken, Math.max(1, ++this.launchGeneration),
      this.serverCertificateSha256, this.settingsService.load().settings);
    if (context === null) { this.hostService.disposeOwner(ownerToken); return; }
    this.setEmbeddedDismissAllowed(false);
    this.recoveryActing = true;
    const result: MoonlightHostServiceResult = await this.hostService.quit(context, appId, true);
    this.hostService.disposeOwner(ownerToken);
    this.recoveryActing = false;
    this.setEmbeddedDismissAllowed(true);
    if (result.ok && this.recoveryStore.clear(marker.sessionId)) {
      this.recoveryMarker = null;
      this.recoveryDecodeCode = 'absent';
      this.showRecoverySheet = false;
      promptAction.showToast({ message: '主机应用已结束，恢复记录已清除', duration: 1800 });
      return;
    }
    promptAction.showToast({ message: '未能确认主机应用已结束', duration: 2200 });
    await this.verifyRecoveryHostState();
  }

  private clearStoppedRecovery(): void {
    const marker: MoonlightSessionRecoveryMarker | null = this.recoveryMarker;
    if (marker === null || (this.recoveryHostState !== 'host_stopped' &&
        this.recoveryHostState !== 'different_app_running')) { return; }
    if (this.recoveryStore.clear(marker.sessionId)) {
      this.recoveryMarker = null;
      this.recoveryDecodeCode = 'absent';
      this.showRecoverySheet = false;
    }
  }

  private confirmUnreadableRecoveryReset(): void {
    const expectedCode: MoonlightSessionRecoveryDecodeCode = this.recoveryDecodeCode;
    if (this.recoveryActing ||
        (expectedCode !== 'corrupt' && expectedCode !== 'too_new')) { return; }
    const title: string = expectedCode === 'too_new' ?
      '强制重置更高版本记录？' : '重置损坏的恢复记录？';
    const message: string = expectedCode === 'too_new' ?
      '建议先升级应用。继续只会删除当前账号数据域中的本机 Moonlight 恢复提示；不会结束主机应用，也不会删除主机、配对或设置。' :
      '继续只会删除当前账号数据域中的本机 Moonlight 恢复提示；不会结束主机应用，也不会删除主机、配对或设置。';
    promptAction.showDialog({
      title: title,
      message: message,
      buttons: [
        { text: expectedCode === 'too_new' ? '保留并稍后升级' : '取消', color: this.pal().text2 },
        { text: '重置本机记录', color: this.pal().danger }
      ]
    }).then((value: Object): void => {
      const selected: Record<string, number> = value as Record<string, number>;
      if (selected['index'] === 1) { this.clearUnreadableRecovery(expectedCode); }
    });
  }

  private clearUnreadableRecovery(
    expectedCode: MoonlightSessionRecoveryDecodeCode
  ): void {
    const lease: AccountSessionLease | null = this.recoveryLease;
    const snapshot = this.recoveryStore.snapshot();
    if (!this.pageActive || this.recoveryActing || lease === null ||
        !CloudStore.getInstance().isLeaseCurrent(lease) ||
        snapshot.code !== expectedCode ||
        (expectedCode !== 'corrupt' && expectedCode !== 'too_new')) {
      promptAction.showToast({ message: '账号或恢复记录已变化，请重新进入页面', duration: 2200 });
      return;
    }
    this.recoveryActing = true;
    const cleared: boolean = this.recoveryStore.clearUnreadable();
    this.recoveryActing = false;
    if (!cleared) {
      promptAction.showToast({ message: '本机恢复记录重置失败，原记录已保留', duration: 2200 });
      return;
    }
    this.recoveryMarker = null;
    this.recoveryLease = null;
    this.recoveryDecodeCode = 'absent';
    this.showRecoverySheet = false;
    promptAction.showToast({ message: '本机恢复记录已重置', duration: 1800 });
  }

  private applyFilter(): void {
    const filtered: MoonlightCatalogItem[] = filterMoonlightCatalogItems(
      this.allItems, this.query, this.filter);
    // LazyForEach's IDataSource count is not an observed ArkUI property. Keep
    // a state-owned count so the empty/grid branch changes after a refresh.
    this.visibleItemCount = filtered.length;
    this.dataSource.replaceAll(filtered);
  }

  private presentation(): MoonlightCatalogPresentation {
    let staleCount: number = 0;
    let unavailableCount: number = 0;
    for (let i = 0; i < this.allItems.length; i++) {
      if (this.allItems[i].stale) { staleCount++; }
      if (!this.allItems[i].available) { unavailableCount++; }
    }
    return moonlightCatalogPresentation(
      this.allItems.length, staleCount, unavailableCount,
      this.hostOnline || this.refreshing, this.refreshing, this.hostBusy,
      this.statusCode === 'cache_read_failed', this.catalogPartial || unavailableCount > 0);
  }

  private requestRefresh(): void {
    this.performCatalogRefresh().catch((): void => {
      if (this.pageActive) {
        this.refreshing = false;
        this.currentRefresh = null;
        this.hostOnline = false;
        this.hostBusy = false;
        this.catalogPartial = false;
        promptAction.showToast({ message: '应用目录刷新失败，已保留本地缓存', duration: 2200 });
      }
    });
  }

  private async performCatalogRefresh(showToast: boolean = true): Promise<void> {
    if (this.refreshing || !this.pageActive || this.ownerScopeId === '') { return; }
    const hostValue: MoonlightHost | null = this.host;
    const lease: AccountSessionLease | null = CloudStore.getInstance().currentAccountLease();
    if (hostValue === null || lease === null ||
        !CloudStore.getInstance().isLeaseCurrent(lease)) {
      if (showToast) {
        promptAction.showToast({ message: '当前账号数据域已变化，请重新进入页面', duration: 2200 });
      }
      return;
    }
    this.refreshGeneration += 1;
    const generation: number = Math.max(1, this.refreshGeneration);
    const key: MoonlightCatalogOperationKey | null = createMoonlightCatalogOperationKey(
      this.ownerScopeId, this.hostId, this.refreshGeneration);
    if (key === null) { return; }
    const ownerToken: number = MoonlightRuntimeOwnerTokenAllocator.getInstance().next();
    const settings: MoonlightSettings = this.settingsService.load().settings;
    const context: MoonlightHostContext | null = this.runtimeContext(
      hostValue, lease, ownerToken, generation, this.serverCertificateSha256, settings);
    if (context === null) {
      if (showToast) {
        promptAction.showToast({ message: '主机信任已变化，请重新验证主机', duration: 2200 });
      }
      return;
    }
    this.currentRefresh = key;
    this.activeRefreshOwnerToken = ownerToken;
    this.refreshing = true;
    let result: MoonlightHostServiceResult | null = null;
    try {
      result = await this.hostService.catalog(context);
    } finally {
      this.hostService.disposeOwner(ownerToken);
      if (this.activeRefreshOwnerToken === ownerToken) {
        this.activeRefreshOwnerToken = 0;
      }
    }
    if (!this.pageActive || !moonlightCatalogOperationIsCurrent(this.currentRefresh, key) ||
        !CloudStore.getInstance().isLeaseCurrent(lease)) {
      if (this.pageActive && moonlightCatalogOperationIsCurrent(this.currentRefresh, key)) {
        this.refreshing = false;
        this.currentRefresh = null;
      }
      return;
    }
    this.refreshing = false;
    this.currentRefresh = null;
    this.hostOnline = result !== null && moonlightCatalogHostReachable(
      result.code,
      result.nativeResult === null ? '' : result.nativeResult.operation,
      result.nativeResult === null ? '' : result.nativeResult.preflightTruth,
      result.nativeResult === null ? 0 : result.nativeResult.partialAppCount);
    this.hostBusy = result !== null && result.code === 'host_busy';
    this.catalogPartial = result !== null && result.nativeResult !== null &&
      result.nativeResult.partialAppCount > 0;
    this.loadLocal();
    if (showToast) {
      promptAction.showToast({
        message: result !== null && result.ok ? '应用目录已刷新' :
          '刷新失败（' + (result === null ? 'runtime_error' : result.code) + '），已保留本地缓存',
        duration: 2200
      });
    }
  }

  private invalidateRefresh(): void {
    this.refreshGeneration += 1;
    this.currentRefresh = null;
    this.refreshing = false;
    const ownerToken: number = this.activeRefreshOwnerToken;
    this.activeRefreshOwnerToken = 0;
    if (ownerToken > 0) { this.hostService.disposeOwner(ownerToken); }
    if (this.refreshTimer >= 0) {
      clearTimeout(this.refreshTimer);
      this.refreshTimer = -1;
    }
  }

  private openItem(item: MoonlightCatalogItem): void {
    if (this.recoveryDecodeCode === 'corrupt' ||
        this.recoveryDecodeCode === 'too_new') {
      this.showRecoverySheet = true;
      promptAction.showToast({ message: '请先处理本机会话恢复记录', duration: 2000 });
      return;
    }
    const resolved: MoonlightEffectiveSettings = this.productSettings(
      this.settingsService.load().settings);
    const encoded: string = encodeMoonlightEffectiveSettings(resolved);
    if (encoded === '') {
      promptAction.showToast({ message: 'Moonlight 设置无效，请先恢复安全默认值', duration: 2200 });
      return;
    }
    this.launchSettingsEncoded = encoded;
    this.launchFeedback = '';
    this.pendingLaunchSheetAction = '';
    this.pendingLaunchHandoff = null;
    this.meteredApprovedOnce = false;
    this.refreshNetworkMetering();
    this.selectedItem = item;
    this.showLaunchSheet = true;
  }

  private refreshNetworkMetering(): void {
    try {
      this.currentNetworkMetered = connection.isDefaultNetMeteredSync();
      this.networkMeteringUnknown = false;
    } catch (_error) {
      // Unknown is treated as metered. The saved policy must explicitly allow
      // it, or the user must approve this one launch from the preflight sheet.
      this.currentNetworkMetered = true;
      this.networkMeteringUnknown = true;
    }
  }

  private meteredAllowed(settings: MoonlightSettings): boolean {
    if (!this.currentNetworkMetered) { return true; }
    if (settings.network.meteredNetwork === 'allow') { return true; }
    return settings.network.meteredNetwork === 'ask' && this.meteredApprovedOnce;
  }

  private meteredApprovalAvailable(settings: MoonlightSettings): boolean {
    return this.currentNetworkMetered && settings.network.meteredNetwork === 'ask' &&
      !this.meteredApprovedOnce;
  }

  private selectedHostAddress(hostValue: MoonlightHost, settings: MoonlightSettings): string {
    return moonlightSelectedHostAddress(hostValue, settings);
  }

  private runtimeContext(hostValue: MoonlightHost, lease: AccountSessionLease,
    ownerToken: number, generation: number, certificateSha256: string,
    settings: MoonlightSettings): MoonlightHostContext | null {
    if (!this.paired || !/^[0-9a-f]{64}$/.test(certificateSha256) ||
        lease.ownerScopeId.trim() === '' || this.ownerScopeId !== lease.ownerScopeId ||
        !CloudStore.getInstance().isLeaseCurrent(lease) || hostValue.addresses.length === 0) {
      return null;
    }
    return moonlightRuntimeContext(
      hostValue, lease, ownerToken, generation, certificateSha256, settings);
  }

  private launchConfiguration(settings: MoonlightSettings): MoonlightNativeLaunchConfiguration {
    const capabilities = probeMoonlightHardwareDecoderCapabilities();
    const decoder = moonlightDecoderCapability(capabilities,
      settings.video.codecPreference);
    try {
      const current: display.Display = display.getDefaultDisplaySync();
      return moonlightLaunchConfiguration(settings, current.width, current.height,
        decoder.maxWidth, decoder.maxHeight);
    } catch (_error) {
      return moonlightLaunchConfiguration(settings, 0, 0,
        decoder.maxWidth, decoder.maxHeight);
    }
  }

  private productSettings(settings: MoonlightSettings): MoonlightEffectiveSettings {
    return resolveMoonlightProductSettings(
      settings, probeMoonlightHardwareDecoderCapabilities());
  }

  private launchSettings(): MoonlightEffectiveSettings | null {
    return decodeMoonlightEffectiveSettings(this.launchSettingsEncoded);
  }

  private resolutionLabel(settings: MoonlightSettings): string {
    if (settings.video.adaptiveResolution === 'device') { return '适配当前设备'; }
    if (settings.video.resolutionMode === 'host' ||
        settings.video.adaptiveResolution === 'host') { return '适配远端能力'; }
    if (settings.video.resolutionMode === 'custom') {
      return settings.video.customWidth.toString() + '×' + settings.video.customHeight.toString();
    }
    return settings.video.resolutionMode;
  }

  private codecLabel(settings: MoonlightSettings): string {
    if (settings.video.codecPreference === 'h264') { return 'H.264'; }
    if (settings.video.codecPreference === 'hevc') { return 'H.265 / HEVC'; }
    if (settings.video.codecPreference === 'av1') { return 'AV1'; }
    return '自动';
  }

  private audioLabel(settings: MoonlightSettings): string {
    if (!settings.audio.enabled) { return '不在本机播放'; }
    if (settings.audio.channels === 'surround51') { return '5.1 声道'; }
    if (settings.audio.channels === 'surround71') { return '7.1 声道'; }
    return '立体声';
  }

  private inputLabel(settings: MoonlightSettings): string {
    const mode = moonlightInputControlMode(
      settings.input.controlMode, settings.input.touchMode);
    if (mode === 'keyboardMouse') { return '键鼠'; }
    if (mode === 'trackpad') { return '虚拟触控板'; }
    return '自适应';
  }

  private launchEffectiveSettings(): MoonlightSettings {
    const snapshot: MoonlightEffectiveSettings | null = this.launchSettings();
    return snapshot === null ?
      this.productSettings(this.settingsService.load().settings).effective :
      snapshot.effective;
  }

  private launchAdjustmentCount(): number {
    const snapshot: MoonlightEffectiveSettings | null = this.launchSettings();
    return snapshot === null ? 0 : snapshot.adjustments.length;
  }

  private launchFenceCurrent(fence: MoonlightLaunchFence): boolean {
    if (!this.pageActive || this.activeLaunchFence !== fence ||
        this.launchGeneration !== fence.pageGeneration ||
        this.ownerScopeId !== fence.ownerScopeId || this.hostId !== fence.hostRecordId ||
        this.host === null || this.host.id !== fence.hostRecordId ||
        this.host.serverUuid !== fence.serverUuid || this.selectedItem === null ||
        this.selectedItem.appId !== fence.appId) {
      return false;
    }
    const lease: AccountSessionLease | null = CloudStore.getInstance().currentAccountLease();
    return lease !== null && CloudStore.getInstance().isLeaseCurrent(lease) &&
      lease.ownerScopeId === fence.ownerScopeId &&
      lease.generation === fence.accountGeneration &&
      lease.storeIdentity === fence.storeIdentity &&
      lease.storeInstanceId === fence.storeInstanceId;
  }

  private finishLaunch(fence: MoonlightLaunchFence, disposeOwner: boolean): void {
    if (disposeOwner) { this.hostService.disposeOwner(fence.ownerToken); }
    if (this.activeLaunchFence !== fence) { return; }
    this.activeLaunchFence = null;
    this.launching = false;
    this.setEmbeddedDismissAllowed(true);
  }

  private cancelLaunchSheet(): void {
    const fence: MoonlightLaunchFence | null = this.activeLaunchFence;
    if (fence !== null) {
      this.markLaunchUncertain(fence.recoverySessionId);
      this.finishLaunch(fence, true);
    }
    this.pendingLaunchSheetAction = '';
    this.pendingLaunchHandoff = null;
    this.launchFeedback = '';
    this.showLaunchSheet = false;
    this.setEmbeddedDismissAllowed(true);
  }

  private closeLaunchSurface(action: string): void {
    this.pendingLaunchSheetAction = action;
    this.pendingLaunchHandoff = null;
    this.showLaunchSheet = false;
    if (this.embedded) { this.handleLaunchSheetDisappear(); }
  }

  private async presentLaunchAfterSheet(
    handoff: MoonlightCatalogLaunchHandoff
  ): Promise<void> {
    let context: common.UIAbilityContext;
    try {
      context = getContext(this) as common.UIAbilityContext;
    } catch (_error) {
      this.markLaunchUncertain(handoff.recoverySessionId);
      this.hostService.disposeOwner(handoff.ownerToken);
      if (this.pageActive) {
        promptAction.showToast({ message: '串流窗口上下文不可用，启动租约已安全释放', duration: 2200 });
      }
      return;
    }
    const opened: boolean = await presentMoonlightCatalogLaunchHandoff(
      context, this.isDesktopDevice, handoff);
    if (opened) { return; }
    this.markLaunchUncertain(handoff.recoverySessionId);
    this.hostService.disposeOwner(handoff.ownerToken);
    if (this.pageActive) {
      promptAction.showToast({ message: '无法打开串流窗口，启动租约已安全释放', duration: 2200 });
    }
  }

  private handleLaunchSheetDisappear(): void {
    const action: string = this.pendingLaunchSheetAction;
    const handoff: MoonlightCatalogLaunchHandoff | null = this.pendingLaunchHandoff;
    this.pendingLaunchSheetAction = '';
    this.pendingLaunchHandoff = null;
    this.selectedItem = null;
    this.launchSettingsEncoded = '';
    this.launchFeedback = '';
    if (!this.pageActive) {
      if (handoff !== null) {
        this.hostService.disposeOwner(handoff.ownerToken);
      }
      return;
    }
    if (action === 'settings') {
      this.openSettings();
      return;
    }
    if (action === 'retry') {
      this.requestRefresh();
      return;
    }
    if (action !== 'launch' || handoff === null) { return; }
    if (this.embedded) {
      this.onLaunchRequested(handoff);
    } else {
      void this.presentLaunchAfterSheet(handoff);
    }
  }

  private handleRecoverySheetDisappear(): void {
    const handoff: MoonlightCatalogLaunchHandoff | null =
      this.pendingRecoveryLaunchHandoff;
    this.pendingRecoveryLaunchHandoff = null;
    if (handoff === null) { return; }
    if (!this.pageActive) {
      this.markLaunchUncertain(handoff.recoverySessionId);
      this.hostService.disposeOwner(handoff.ownerToken);
      return;
    }
    if (this.embedded) {
      this.onLaunchRequested(handoff);
    } else {
      void this.presentLaunchAfterSheet(handoff);
    }
  }

  private launchFailureMessage(result: MoonlightHostServiceResult): string {
    if (result.code === 'deadline_exceeded') {
      return '启动请求已超时。主机可能仍在准备画面，请稍后重试；如主机应用已启动，可按恢复提示继续。';
    }
    if (result.code === 'outcome_unknown') {
      return '主机是否已启动应用暂时无法确认，请先核对恢复提示，避免重复启动。';
    }
    if (result.code === 'host_busy') {
      return '主机正在运行其他应用，请先结束主机上的现有会话。';
    }
    if (result.code === 'unpaired' || result.code === 'repair_required') {
      return '配对或证书信任已失效，请返回主机详情重新验证。';
    }
    return '启动失败（' + result.code + '），请检查主机状态后重试。';
  }

  private launchDefinitelyDidNotMutate(result: MoonlightHostServiceResult): boolean {
    if (result.code === 'invalid_context' || result.code === 'lifecycle_closed') {
      return true;
    }
    const native = result.nativeResult;
    if (native === null) { return false; }
    if (native.operation !== 'launch' && native.operation !== 'resume') {
      return true;
    }
    return !native.mutationMayHaveBeenSent &&
      native.actionTruth !== 'confirmed' && native.actionTruth !== 'unknown';
  }

  private markLaunchUncertain(sessionId: string): void {
    this.recoveryStore.update(sessionId, {
      stage: 'terminal_uncertain', heartbeatAt: Date.now(),
      hostAppMayStillBeRunning: true, inputMayBeStuck: false,
      terminalAction: 'none'
    });
  }

  private async startSelected(): Promise<void> {
    if (!this.pageActive || this.host === null || this.selectedItem === null) { return; }
    if (this.launching) { return; }
    if (!MoonlightSessionCoordinator.getInstance().reconcileNativeTerminalReceipt()) {
      promptAction.showToast({
        message: '上一条 Moonlight 原生会话仍在安全释放，请稍后重试', duration: 2200
      });
      return;
    }
    this.refreshNetworkMetering();
    if (!this.meteredAllowed(this.launchEffectiveSettings())) {
      this.showLaunchSheet = true;
      promptAction.showToast({ message: '当前网络未获 Moonlight 串流授权', duration: 2200 });
      return;
    }
    const settingsSnapshot: MoonlightEffectiveSettings | null = this.launchSettings();
    if (settingsSnapshot === null) {
      promptAction.showToast({ message: '串流设置快照已失效，请重新确认', duration: 2200 });
      return;
    }
    const hostValue: MoonlightHost = this.host;
    const selectedAppId: string = this.selectedItem.appId;
    const numericAppId: number = Number.parseInt(selectedAppId, 10);
    const lease: AccountSessionLease | null = CloudStore.getInstance().currentAccountLease();
    if (lease === null) {
      promptAction.showToast({ message: '当前账号数据域不可用，请重新进入页面', duration: 2200 });
      return;
    }
    this.launchGeneration += 1;
    const generation: number = Math.max(1, this.launchGeneration);
    const ownerToken: number = MoonlightRuntimeOwnerTokenAllocator.getInstance().next();
    const certificateSha256: string = this.serverCertificateSha256;
    const context: MoonlightHostContext | null =
      this.runtimeContext(hostValue, lease, ownerToken, generation, certificateSha256,
        settingsSnapshot.effective);
    const hostAddress: string = this.selectedHostAddress(hostValue, settingsSnapshot.effective);
    if (context === null || hostAddress === '' ||
        !Number.isSafeInteger(numericAppId) || numericAppId <= 0) {
      promptAction.showToast({ message: '主机信任或应用信息无效，请重新验证主机', duration: 2200 });
      return;
    }
    let uiContext: common.UIAbilityContext;
    try {
      uiContext = getContext(this) as common.UIAbilityContext;
    } catch (_error) {
      this.hostService.disposeOwner(ownerToken);
      promptAction.showToast({ message: '无法建立本地会话恢复边界', duration: 2200 });
      return;
    }
    const recoveryState = this.recoveryStore.bind(
      uiContext, lease, hostValue.id);
    if (recoveryState.code !== 'absent') {
      this.hostService.disposeOwner(ownerToken);
      promptAction.showToast({
        message: recoveryState.code === 'ready' ?
          '检测到上次未完成的 Moonlight 会话，请先处理恢复提示' :
          '本地 Moonlight 恢复记录异常，请先处理当前恢复提示',
        duration: 2600
      });
      return;
    }
    const recoverySessionId: string = moonlightSessionRecoveryId();
    const recoveryMarker = this.recoveryStore.begin({
      sessionId: recoverySessionId,
      hostId: hostValue.id,
      profileId: this.selectedItem.profileId,
      appId: selectedAppId
    }, Date.now());
    if (recoveryMarker === null) {
      this.hostService.disposeOwner(ownerToken);
      promptAction.showToast({ message: '无法安全保存本地会话恢复记录', duration: 2200 });
      return;
    }
    const fence: MoonlightLaunchFence = new MoonlightLaunchFence();
    fence.pageGeneration = generation;
    fence.ownerScopeId = lease.ownerScopeId;
    fence.accountGeneration = lease.generation;
    fence.storeIdentity = lease.storeIdentity;
    fence.storeInstanceId = lease.storeInstanceId;
    fence.hostRecordId = hostValue.id;
    fence.serverUuid = hostValue.serverUuid;
    fence.appId = selectedAppId;
    fence.numericAppId = numericAppId;
    fence.hostAddress = hostAddress;
    fence.ownerToken = ownerToken;
    fence.recoverySessionId = recoverySessionId;
    this.activeLaunchFence = fence;
    this.launchFeedback = '';
    this.setEmbeddedDismissAllowed(false);
    this.launching = true;
    const launchConfiguration: MoonlightNativeLaunchConfiguration =
      this.launchConfiguration(settingsSnapshot.effective);
    let result: MoonlightHostServiceResult = await this.hostService.launch(
      context, numericAppId, launchConfiguration);
    if (result.code === 'resume_required') {
      if (!this.launchFenceCurrent(fence)) {
        this.finishLaunch(fence, true);
        return;
      }
      result = await this.hostService.resume(context, numericAppId, launchConfiguration);
    }
    if (result.ok && result.nativeResult !== null) {
      this.recoveryStore.update(fence.recoverySessionId, {
        stage: 'host_launch_confirmed', heartbeatAt: Date.now(),
        hostAppMayStillBeRunning: true, inputMayBeStuck: false,
        terminalAction: 'none'
      });
    } else if (this.launchDefinitelyDidNotMutate(result)) {
      this.recoveryStore.clear(fence.recoverySessionId);
    } else {
      this.markLaunchUncertain(fence.recoverySessionId);
    }
    if (!this.launchFenceCurrent(fence)) {
      this.finishLaunch(fence, true);
      return;
    }
    if (!result.ok || result.nativeResult === null) {
      this.launchFeedback = this.launchFailureMessage(result);
      this.finishLaunch(fence, true);
      promptAction.showToast({
        message: 'Moonlight 启动失败（' + result.code + '）',
        duration: 2200
      });
      return;
    }
    const params: Record<string, Object> | null =
      moonlightAppRouteParams(fence.hostRecordId, fence.appId);
    if (params !== null) {
      params['launchRequestId'] = result.key.requestId;
      params['launchGeneration'] = result.key.generation;
      params['launchOwnerToken'] = result.key.ownerToken;
      params['serverUuid'] = fence.serverUuid;
      params['numericAppId'] = fence.numericAppId;
      params['hostAddress'] = fence.hostAddress;
      params['streamWidth'] = launchConfiguration.width as number;
      params['streamHeight'] = launchConfiguration.height as number;
      params['moonlightEffectiveSettings'] = this.launchSettingsEncoded;
      params['launchOwnerScopeFingerprint'] = moonlightOwnerScopeFingerprint(fence.ownerScopeId);
      params['launchAccountGeneration'] = fence.accountGeneration;
      params['launchInstallationId'] = moonlightInstallationId(fence.storeIdentity);
      params['launchStoreInstanceId'] = fence.storeInstanceId;
      params['moonlightRecoverySessionId'] = fence.recoverySessionId;
      params['resetRemoteInputBeforeAdmission'] = false;
      if (!this.launchFenceCurrent(fence)) {
        this.finishLaunch(fence, true);
        return;
      }
      const handoff: MoonlightCatalogLaunchHandoff = new MoonlightCatalogLaunchHandoff();
      handoff.routeParams = params;
      handoff.hostId = fence.hostRecordId;
      handoff.title = (this.host?.displayName || 'Moonlight') + ' — ' +
        (this.selectedItem?.title || '串流');
      handoff.ownerToken = fence.ownerToken;
      handoff.recoverySessionId = fence.recoverySessionId;
      // Record the confirmed launch before dismissing the inner preflight
      // Sheet. Embedded surfaces forward it only from onDisappear; their
      // parent then closes the outer Catalog Sheet and presents the stream
      // from that Sheet's onDisappear boundary.
      this.pendingLaunchSheetAction = 'launch';
      this.pendingLaunchHandoff = handoff;
      this.finishLaunch(fence, false);
      this.showLaunchSheet = false;
      if (this.embedded) { this.handleLaunchSheetDisappear(); }
      return;
    }
    this.markLaunchUncertain(fence.recoverySessionId);
    this.finishLaunch(fence, true);
  }

  private openSettings(): void {
    const params: Record<string, Object> | null = moonlightHostRouteParams(this.hostId);
    if (params === null) { return; }
    if (this.embedded) {
      this.onOpenSettings();
    } else {
      router.pushUrl({ url: 'pages/MoonlightSettingsPage', params: params });
    }
  }

  private openHostDetail(): void {
    const params: Record<string, Object> | null = moonlightHostRouteParams(this.hostId);
    if (params === null) { return; }
    if (this.embedded) {
      this.onOpenHostDetail();
    } else {
      router.pushUrl({ url: 'pages/MoonlightHostDetailPage', params: params });
    }
  }

  @Builder private launchSheet() {
    MoonlightLaunchSheet({
      hostName: this.host?.displayName || '',
      appName: this.selectedItem?.title || '',
      resolutionLabel: this.resolutionLabel(this.launchEffectiveSettings()),
      fps: this.launchEffectiveSettings().video.fps,
      codecLabel: this.codecLabel(this.launchEffectiveSettings()),
      audioLabel: this.audioLabel(this.launchEffectiveSettings()),
      inputLabel: this.inputLabel(this.launchEffectiveSettings()),
      routeValid: this.host !== null && this.selectedItem !== null,
      hostAvailable: this.hostOnline || this.hostBusy,
      certificateChanged: false,
      identityAvailable: this.paired,
      appAvailable: this.selectedItem !== null && this.selectedItem.available && !this.selectedItem.stale,
      meteredNetwork: this.currentNetworkMetered,
      meteredAllowed: this.meteredAllowed(this.launchEffectiveSettings()),
      meteredStateUnknown: this.networkMeteringUnknown,
      meteredApprovalAvailable: this.meteredApprovalAvailable(this.launchEffectiveSettings()),
      hostBusy: this.hostBusy,
      runtimeAvailable: this.hostService.capabilities().hostControlReady,
      adjustmentCount: this.launchAdjustmentCount(),
      launching: this.launching,
      launchFeedback: this.launchFeedback,
      onCancel: (): void => { this.cancelLaunchSheet(); },
      onOpenSettings: (): void => {
        this.closeLaunchSurface('settings');
      },
      onRetry: (): void => {
        this.closeLaunchSurface('retry');
      },
      onAllowMetered: (): void => { this.meteredApprovedOnce = true; },
      onStart: (): void => {
        this.startSelected().catch((): void => {
          if (this.pageActive) {
            const fence: MoonlightLaunchFence | null = this.activeLaunchFence;
            if (fence !== null) { this.finishLaunch(fence, true); }
          }
        });
      }
    })
  }

  @Builder private recoverySheet() {
    Column() {
      Row() {
        MoonlightBrandIcon({ iconSize: 34, tint: this.accentColor })
        Column() {
          Text(this.recoveryDecodeCode === 'corrupt' || this.recoveryDecodeCode === 'too_new' ?
            '修复本机会话恢复记录' : '恢复上次 Moonlight 会话')
            .fontSize(20).fontWeight(FontWeight.Bold)
            .fontColor(this.pal().text)
          Text('仅保存在本机 · 不会自动恢复、删除或结束主机应用')
            .fontSize(10).fontColor(this.pal().text3).margin({ top: 3 })
        }.alignItems(HorizontalAlign.Start).margin({ left: 12 }).layoutWeight(1)
      }.width('100%')
      Text(this.recoveryStateLabel()).fontSize(12).lineHeight(19)
        .fontColor(this.pal().text2).width('100%').margin({ top: 16 })
      if (this.recoveryDecodeCode === 'corrupt' ||
          this.recoveryDecodeCode === 'too_new') {
        Button(this.recoveryActing ? '重置中…' :
          (this.recoveryDecodeCode === 'too_new' ? '仍要重置本机记录' : '重置本机恢复记录'))
          .height(46).width('100%').borderRadius(13).fontSize(13)
          .backgroundColor(this.theme === 'light' ? '#FFF0F0' : '#3A2024')
          .fontColor(this.pal().danger).margin({ top: 20 })
          .enabled(!this.recoveryActing)
          .onClick((): void => { this.confirmUnreadableRecoveryReset(); })
      } else if (this.recoveryHostState === 'matching_app_running') {
        Button(this.recoveryActing ? '处理中…' : '恢复串流').height(48).width('100%')
          .borderRadius(14).fontSize(14).fontWeight(FontWeight.Medium)
          .backgroundColor(this.accentColor).fontColor(Color.White).margin({ top: 20 })
          .enabled(!this.recoveryActing && !this.recoveryChecking)
          .onClick((): void => { void this.resumeRecoveredSession(); })
        Button('结束主机应用').height(44).width('100%').borderRadius(13).fontSize(13)
          .backgroundColor(this.theme === 'light' ? '#FFF0F0' : '#3A2024')
          .fontColor(this.pal().danger)
          .margin({ top: 9 }).enabled(!this.recoveryActing && !this.recoveryChecking)
          .onClick((): void => { void this.quitRecoveredHostApp(); })
      } else if (this.recoveryHostState === 'host_stopped' ||
          this.recoveryHostState === 'different_app_running') {
        Button('清除已失效的本地记录').height(46).width('100%').borderRadius(13)
          .fontSize(13).backgroundColor(this.accentColor).fontColor(Color.White)
          .margin({ top: 20 }).onClick((): void => { this.clearStoppedRecovery(); })
      } else {
        Button(this.recoveryChecking ? '核对中…' : '重试核对').height(46).width('100%')
          .borderRadius(13).fontSize(13).backgroundColor(this.accentColor)
          .fontColor(Color.White).margin({ top: 20 })
          .enabled(!this.recoveryChecking && !this.recoveryActing)
          .onClick((): void => { void this.verifyRecoveryHostState(); })
      }
      Button(this.recoveryDecodeCode === 'too_new' ? '保留并稍后升级' : '暂时忽略')
        .height(42).width('100%').borderRadius(12).fontSize(13)
        .backgroundColor(this.pal().surface).fontColor(this.pal().text2).margin({ top: 9 })
        .enabled(!this.recoveryActing)
        .onClick((): void => { this.showRecoverySheet = false; })
    }.width('100%').constraintSize({ maxWidth: 520 }).padding(24)
      .backgroundColor(this.pal().sheetBg)
  }

  @Builder private filterButton(label: string, value: MoonlightCatalogFilter) {
    Button(label).height(34).fontSize(11).borderRadius(11)
      .backgroundColor(this.filter === value ? this.accentColor : this.pal().surface)
      .fontColor(this.filter === value ? Color.White : this.pal().text2)
      .onClick((): void => { this.filter = value; this.applyFilter(); })
  }

  @Builder private header() {
    Row() {
      Button() { SymbolGlyph($r('sys.symbol.chevron_left')).fontSize(21).fontColor([this.pal().text]) }
        .width(42).height(42).borderRadius(21).backgroundColor(this.pal().surface)
        .onClick((): void => {
          if (this.embedded) { this.onClose(); } else { router.back(); }
        }).accessibilityText('返回')
      MoonlightBrandIcon({ iconSize: 28, tint: this.accentColor }).margin({ left: 12 })
      Column() {
        Text(this.host?.displayName || 'Moonlight 应用目录').fontSize(22).fontWeight(FontWeight.Bold)
          .fontColor(this.pal().text).fontFamily(AppTheme.fontFamily)
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
        Text('按主机分类 · 仅本地缓存').fontSize(10).fontColor(this.pal().text3).margin({ top: 2 })
      }.alignItems(HorizontalAlign.Start).layoutWeight(1).margin({ left: 10 })
      Button() { SymbolGlyph($r('sys.symbol.info_circle')).fontSize(18).fontColor([this.pal().text]) }
        .width(42).height(42).borderRadius(21).backgroundColor(this.pal().surface)
        .enabled(this.host !== null).onClick((): void => { this.openHostDetail(); })
        .accessibilityText('主机详情')
      Button() { SymbolGlyph($r('sys.symbol.gearshape_fill')).fontSize(18).fontColor([this.pal().text]) }
        .width(42).height(42).borderRadius(21).backgroundColor(this.pal().surface).margin({ left: 8 })
        .enabled(this.host !== null).onClick((): void => { this.openSettings(); })
        .accessibilityText('Moonlight 设置')
    }.width('100%').padding({ left: 18, right: 18, top: this.topSafeHeight() + 8, bottom: 10 })
  }

  @Builder private statusBanner() {
    Row() {
      Column().width(9).height(9).borderRadius(5)
        .backgroundColor(this.presentation().status === 'fresh' ? this.pal().success : this.pal().editColor)
      Column() {
        Text(this.presentation().title).fontSize(13).fontWeight(FontWeight.Medium).fontColor(this.pal().text)
        Text(this.presentation().detail).fontSize(10).fontColor(this.pal().text3).margin({ top: 3 })
      }.alignItems(HorizontalAlign.Start).layoutWeight(1).margin({ left: 10 })
      Button(this.refreshing ? '读取中' : '刷新').height(34).fontSize(11).borderRadius(11)
        .backgroundColor(this.pal().surface).fontColor(this.pal().text)
        .enabled(!this.refreshing).onClick((): void => { this.requestRefresh(); })
    }.width('100%').padding(13).backgroundColor(this.pal().card).borderRadius(16)
      .border({ width: 0.5, color: this.pal().cardBorder })
  }

  @Builder private catalogContent() {
    Column() {
      this.header()
      Column() {
        this.statusBanner()
        Row() {
          Row() {
            SymbolGlyph($r('sys.symbol.magnifyingglass')).fontSize(17).fontColor([this.pal().text3])
            TextInput({ placeholder: '搜索应用', text: this.query }).layoutWeight(1).height(42)
              .backgroundColor(Color.Transparent).fontColor(this.pal().text)
              .placeholderColor(this.pal().text3).fontSize(13).margin({ left: 8 })
              .onChange((value: string): void => { this.query = value; this.applyFilter(); })
          }.layoutWeight(1).height(46).padding({ left: 13, right: 10 })
            .backgroundColor(this.pal().searchBg).borderRadius(15)
          Scroll() {
            Row({ space: 7 }) {
              this.filterButton('全部', 'all')
              this.filterButton('收藏', 'favorite')
              this.filterButton('可用', 'available')
              this.filterButton('缓存/不可用', 'unavailable')
            }
          }.scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off)
            .constraintSize({ maxWidth: this.breakpoint === 'sm' ? 180 : 340 }).margin({ left: 10 })
        }.width('100%').margin({ top: 12, bottom: 12 })

        if (this.visibleItemCount === 0) {
          Column() {
            MoonlightBrandIcon({ iconSize: 46, tint: this.pal().text3 })
            Text(this.query === '' ? '暂无本地应用目录' : '没有匹配的应用')
              .fontSize(16).fontWeight(FontWeight.Bold).fontColor(this.pal().text).margin({ top: 14 })
            Text(this.query === '' ? '主机上线后刷新；旧配置不会被删除' : '尝试清除搜索或切换筛选')
              .fontSize(11).fontColor(this.pal().text3).margin({ top: 6 })
          }.width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
        } else {
          Grid() {
            LazyForEach(this.dataSource, (item: MoonlightCatalogItem): void => {
              GridItem() {
                MoonlightAppCard({
                  item: item,
                  hostOnline: this.hostOnline,
                  onMore: (selected: MoonlightCatalogItem): void => { this.openItem(selected); }
                })
              }
            }, (item: MoonlightCatalogItem): string => item.id)
          }.columnsTemplate(this.columns()).columnsGap(12).rowsGap(12)
            .layoutWeight(1).width('100%').scrollBar(BarState.Off)
        }
      }.width('100%').layoutWeight(1).constraintSize({ maxWidth: 1320 })
        .padding({ left: this.breakpoint === 'sm' ? 14 : 24, right: this.breakpoint === 'sm' ? 14 : 24,
          bottom: 24 })
    }.width('100%').height(this.catalogSurfaceHeight())
      .backgroundColor(this.embedded ? this.pal().sheetBg : this.pal().bg)
  }

  build() {
    if (this.embedded) {
      if (this.showRecoverySheet) {
        this.recoverySheet()
      } else if (this.showLaunchSheet) {
        this.launchSheet()
      } else {
        this.catalogContent()
      }
    } else {
      Column() {
        this.catalogContent()
      }.width('100%').height('100%').backgroundColor(this.pal().bg)
        .bindSheet($$this.showLaunchSheet, this.launchSheet(), {
          height: SheetSize.FIT_CONTENT,
          preferType: this.breakpoint === 'sm' ? SheetType.BOTTOM : SheetType.CENTER,
          dragBar: false,
          backgroundColor: this.pal().sheetBg,
          blurStyle: BlurStyle.NONE,
          showClose: false,
          onWillDismiss: (action: DismissSheetAction): void => {
            if (this.showLaunchSheet) { this.cancelLaunchSheet(); }
            action.dismiss();
          },
          onDisappear: (): void => { this.handleLaunchSheetDisappear(); }
        })
        .bindSheet($$this.showRecoverySheet, this.recoverySheet(), {
          height: SheetSize.FIT_CONTENT,
          preferType: this.breakpoint === 'sm' ? SheetType.BOTTOM : SheetType.CENTER,
          dragBar: false,
          backgroundColor: this.pal().sheetBg,
          blurStyle: BlurStyle.NONE,
          showClose: false,
          onWillDismiss: (action: DismissSheetAction): void => {
            if (!moonlightRecoverySheetDismissAllowed(this.recoveryActing)) {
              promptAction.showToast({
                message: '正在处理恢复请求，请稍候', duration: 1500
              });
              return;
            }
            action.dismiss();
          },
          onDisappear: (): void => { this.handleRecoverySheetDisappear(); }
        })
    }
  }
}

@Entry
@Component
struct MoonlightAppCatalogPage {
  build() {
    Column() {
      MoonlightAppCatalogSurface()
    }.width('100%').height('100%')
  }
}
