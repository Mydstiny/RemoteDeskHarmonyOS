import { promptAction, router } from '@kit.ArkUI';
import { AppTheme, Palette, buildDark, buildLight } from '../common/Theme';
import { MoonlightBrandIcon } from '../components/moonlight/MoonlightBrandIcon';
import { MoonlightLaunchSheet } from '../components/moonlight/MoonlightLaunchSheet';
import { MoonlightCatalogDataSource } from '../datasources/MoonlightCatalogDataSource';
import { MoonlightAddress, MoonlightHost, moonlightAddressKey } from '../model/MoonlightModels';
import { AccountSessionCoordinator } from '../services/AccountSessionCoordinator';
import { CloudStore } from '../services/CloudStore';
import { MoonlightHostLocalView, MoonlightLocalViewService } from '../services/MoonlightLocalViewService';
import {
  MoonlightHostContext,
  MoonlightHostService,
  MoonlightHostServiceResult,
  MoonlightNativeLaunchConfiguration
} from '../services/MoonlightHostService';
import { MoonlightSettingsLocalService } from '../services/MoonlightSettingsLocalService';
import {
  moonlightInstallationId,
  moonlightOwnerScopeFingerprint
} from '../services/MoonlightRuntimeSupport';
import {
  MoonlightCatalogFilter,
  MoonlightCatalogItem,
  MoonlightCatalogOperationKey,
  MoonlightCatalogPresentation,
  MoonlightRouteIdentity,
  createMoonlightCatalogOperationKey,
  filterMoonlightCatalogItems,
  moonlightCatalogOperationIsCurrent,
  moonlightCatalogPresentation,
  moonlightAppRouteParams,
  moonlightHostRouteParams,
  moonlightRouteIdentity
} from '../services/MoonlightUiPolicy';

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
  onOpen: (item: MoonlightCatalogItem) => void = (_item: MoonlightCatalogItem): void => {};
  onMore: (item: MoonlightCatalogItem) => void = (_item: MoonlightCatalogItem): void => {};

  private pal(): Palette {
    return this.theme === 'light' ? buildLight(this.accentColor) : buildDark(this.accentColor);
  }

  private usable(): boolean { return this.item.available && !this.item.stale; }

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
          Text(this.item.stale ? '缓存' : '不可用').fontSize(10).fontColor('#FFFFFF')
            .padding({ left: 8, right: 8, top: 4, bottom: 4 })
            .backgroundColor('rgba(14,18,28,0.72)').borderRadius(10)
            .position({ x: 10, y: 166 })
        }
      }.width('100%').height(200).backgroundColor(this.pal().surface)

      Column() {
        Text(this.item.title).fontSize(14).fontWeight(FontWeight.Medium).fontColor(this.pal().text)
          .fontFamily(AppTheme.fontFamily).maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Text(this.item.profileId === '' ? '使用主机默认设置' : '已保存应用配置')
          .fontSize(10).fontColor(this.pal().text3).width('100%').margin({ top: 5 })
        Row() {
          Text(this.usable() ? '可启动' : (this.item.stale ? '目录已过期' : '主机未报告此应用'))
            .fontSize(10).fontColor(this.usable() ? this.pal().success : this.pal().text3)
          Blank().layoutWeight(1)
          Text('启动').fontSize(11).fontWeight(FontWeight.Medium)
            .fontColor(this.usable() ? this.accentColor : this.pal().text3)
        }.width('100%').margin({ top: 8 })
      }.width('100%').padding(13)
    }.width('100%').height(292).backgroundColor(this.pal().card).borderRadius(20)
      .clip(true).border({ width: 0.5, color: this.pal().cardBorder })
      .shadow({ radius: 14, color: 'rgba(0,0,0,0.04)', offsetY: 4 })
      .opacity(this.usable() ? 1 : 0.78)
      .onClick((): void => { this.onOpen(this.item); })
      .accessibilityText(this.item.title + '，' + (this.usable() ? '可启动' : '当前不可用'))
  }
}

@Entry
@Component
struct MoonlightAppCatalogPage {
  @StorageLink('currentTheme') theme: string = 'light';
  @StorageLink('accentColor') accentColor: string = '#007DFF';
  @StorageProp('topRectHeight') topRectHeight: number = 0;
  @StorageProp('currentBreakpoint') breakpoint: string = 'sm';
  @State hostId: string = '';
  @State host: MoonlightHost | null = null;
  @State paired: boolean = false;
  @State allItems: MoonlightCatalogItem[] = [];
  @State query: string = '';
  @State filter: MoonlightCatalogFilter = 'all';
  @State statusCode: string = 'loading';
  @State refreshing: boolean = false;
  @State selectedItem: MoonlightCatalogItem | null = null;
  @State showLaunchSheet: boolean = false;
  @State launching: boolean = false;
  private readonly dataSource: MoonlightCatalogDataSource = new MoonlightCatalogDataSource();
  private readonly viewService: MoonlightLocalViewService =
    new MoonlightLocalViewService(CloudStore.getInstance());
  private readonly hostService: MoonlightHostService = new MoonlightHostService();
  private readonly settingsService: MoonlightSettingsLocalService =
    new MoonlightSettingsLocalService(CloudStore.getInstance());
  private pageActive: boolean = false;
  private ownerScopeId: string = '';
  private refreshGeneration: number = 0;
  private refreshTimer: number = -1;
  private currentRefresh: MoonlightCatalogOperationKey | null = null;
  private serverCertificateSha256: string = '';
  private launchGeneration: number = 0;

  private pal(): Palette {
    return this.theme === 'light' ? buildLight(this.accentColor) : buildDark(this.accentColor);
  }

  private topSafeHeight(): number {
    return this.topRectHeight > 0 ? px2vp(this.topRectHeight) : AppTheme.layout.statusBarH;
  }

  private columns(): string {
    if (this.breakpoint === 'sm') { return '1fr 1fr'; }
    if (this.breakpoint === 'md') { return '1fr 1fr 1fr'; }
    if (this.breakpoint === 'lg') { return '1fr 1fr 1fr 1fr'; }
    return '1fr 1fr 1fr 1fr 1fr';
  }

  aboutToAppear(): void {
    this.pageActive = true;
    const params: Record<string, Object> = router.getParams() as Record<string, Object>;
    const route: MoonlightRouteIdentity = moonlightRouteIdentity(params);
    this.hostId = route.valid ? route.hostId : '';
    this.loadLocal();
  }

  aboutToDisappear(): void {
    this.pageActive = false;
    this.invalidateRefresh();
  }

  onPageShow(): void { if (this.hostId !== '') { this.loadLocal(); } }

  private loadLocal(): void {
    if (this.hostId === '') { this.statusCode = 'invalid_route'; return; }
    const view: MoonlightHostLocalView = this.viewService.loadHost(this.hostId, Date.now());
    if (!view.ok || view.host === null) {
      this.statusCode = view.code;
      this.host = null;
      this.ownerScopeId = '';
      this.serverCertificateSha256 = '';
      this.allItems = [];
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
  }

  private applyFilter(): void {
    this.dataSource.replaceAll(filterMoonlightCatalogItems(
      this.allItems, this.query, this.filter));
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
      false, this.refreshing, false, this.statusCode === 'cache_read_failed',
      unavailableCount > 0);
  }

  private requestRefresh(): void {
    if (this.refreshing || !this.pageActive || this.ownerScopeId === '') { return; }
    this.refreshGeneration += 1;
    const key: MoonlightCatalogOperationKey | null = createMoonlightCatalogOperationKey(
      this.ownerScopeId, this.hostId, this.refreshGeneration);
    if (key === null) { return; }
    this.currentRefresh = key;
    this.refreshing = true;
    this.refreshTimer = setTimeout((): void => {
      this.refreshTimer = -1;
      if (!this.pageActive || !moonlightCatalogOperationIsCurrent(this.currentRefresh, key)) { return; }
      this.refreshing = false;
      this.currentRefresh = null;
      this.loadLocal();
      promptAction.showToast({
        message: 'Host Control 尚未开放，已重新读取本地目录缓存', duration: 2200
      });
    }, 250);
  }

  private invalidateRefresh(): void {
    this.refreshGeneration += 1;
    this.currentRefresh = null;
    this.refreshing = false;
    if (this.refreshTimer >= 0) {
      clearTimeout(this.refreshTimer);
      this.refreshTimer = -1;
    }
  }

  private openItem(item: MoonlightCatalogItem): void {
    this.selectedItem = item;
    this.showLaunchSheet = true;
  }

  private selectedHostAddress(): string {
    if (this.host === null || this.host.addresses.length === 0) { return ''; }
    let selected: MoonlightAddress = this.host.addresses[0];
    for (let i = 0; i < this.host.addresses.length; i++) {
      if (moonlightAddressKey(this.host.addresses[i]) === this.host.preferredAddressKey) {
        selected = this.host.addresses[i];
        break;
      }
    }
    const host: string = selected.family === 'ipv6' ? '[' + selected.host + ']' : selected.host;
    return host + ':' + selected.port.toString();
  }

  private runtimeContext(): MoonlightHostContext | null {
    if (this.host === null || !this.paired ||
        !/^[0-9a-f]{64}$/.test(this.serverCertificateSha256)) { return null; }
    const lease = CloudStore.getInstance().currentAccountLease();
    const scope = CloudStore.getInstance().currentScope();
    if (lease === null || scope.ownerScopeId.trim() === '' || this.host.addresses.length === 0) {
      return null;
    }
    let selected: MoonlightAddress = this.host.addresses[0];
    for (let index = 0; index < this.host.addresses.length; index++) {
      if (moonlightAddressKey(this.host.addresses[index]) === this.host.preferredAddressKey) {
        selected = this.host.addresses[index]; break;
      }
    }
    this.launchGeneration += 1;
    const generation: number = Math.max(1, this.launchGeneration);
    const ownerToken: number = Math.min(9007199254740991,
      Math.max(1, Date.now() * 100 + generation % 100));
    return {
      lease: lease,
      ownerScopeFingerprint: moonlightOwnerScopeFingerprint(scope.ownerScopeId),
      ownerToken: ownerToken,
      generation: generation,
      hostId: this.host.serverUuid,
      serverUuid: this.host.serverUuid,
      installationId: moonlightInstallationId(scope.storeIdentity),
      pinnedCertificateSha256: this.serverCertificateSha256,
      endpoint: {
        serverName: selected.family === 'hostname' ? selected.host : this.host.displayName,
        addresses: [{ value: selected.host,
          family: selected.family === 'ipv4' ? 'ipv4' : selected.family === 'ipv6' ? 'ipv6' : 'unspecified' }],
        httpPort: selected.port,
        httpsPort: 47984,
        pinnedTrustAvailable: true,
        allowHttpPairingCandidate: false
      },
      timeoutMs: 30000
    };
  }

  private launchConfiguration(): MoonlightNativeLaunchConfiguration {
    const loaded = this.settingsService.load();
    const video = loaded.settings.video;
    const audio = loaded.settings.audio;
    let width: number = 1920;
    let height: number = 1080;
    if (video.resolutionMode === '720p') { width = 1280; height = 720; }
    else if (video.resolutionMode === '1440p') { width = 2560; height = 1440; }
    else if (video.resolutionMode === '2160p') { width = 3840; height = 2160; }
    else if (video.resolutionMode === 'custom') {
      width = video.customWidth; height = video.customHeight;
    }
    return {
      width: width, height: height, refreshRate: video.fps,
      additionalStates: true, sops: true, hdr: false,
      playAudioOnHost: audio.playOnHost, surroundAudioInfo: 196610,
      remoteControllersBitmap: loaded.settings.input.controllerSlot >= 0 ? 1 : 0,
      gamepadMask: loaded.settings.input.controllerSlot >= 0 ? 1 : 0,
      persistGamepads: false
    };
  }

  private async startSelected(): Promise<void> {
    if (this.host === null || this.selectedItem === null) { return; }
    if (this.launching) { return; }
    const context: MoonlightHostContext | null = this.runtimeContext();
    const numericAppId: number = Number.parseInt(this.selectedItem.appId, 10);
    if (context === null || !Number.isSafeInteger(numericAppId) || numericAppId <= 0) {
      promptAction.showToast({ message: '主机信任或应用信息无效，请重新验证主机', duration: 2200 });
      return;
    }
    this.launching = true;
    let result: MoonlightHostServiceResult = await this.hostService.launch(
      context, numericAppId, this.launchConfiguration());
    if (result.code === 'resume_required') {
      result = await this.hostService.resume(context, numericAppId, this.launchConfiguration());
    }
    this.launching = false;
    if (!this.pageActive || !result.ok || result.nativeResult === null) {
      promptAction.showToast({
        message: 'Moonlight 启动失败（' + result.code + '）',
        duration: 2200
      });
      return;
    }
    const params: Record<string, Object> | null =
      moonlightAppRouteParams(this.host.id, this.selectedItem.appId);
    if (params !== null) {
      params['launchRequestId'] = result.key.requestId;
      params['launchGeneration'] = result.key.generation;
      params['launchOwnerToken'] = result.key.ownerToken;
      params['serverUuid'] = this.host.serverUuid;
      params['numericAppId'] = numericAppId;
      params['hostAddress'] = this.selectedHostAddress();
      this.showLaunchSheet = false;
      router.pushUrl({ url: 'pages/MoonlightStreamPage', params: params });
    }
  }

  private openSettings(): void {
    const params: Record<string, Object> | null = moonlightHostRouteParams(this.hostId);
    if (params !== null) { router.pushUrl({ url: 'pages/MoonlightSettingsPage', params: params }); }
  }

  private openHostDetail(): void {
    const params: Record<string, Object> | null = moonlightHostRouteParams(this.hostId);
    if (params !== null) { router.pushUrl({ url: 'pages/MoonlightHostDetailPage', params: params }); }
  }

  @Builder private launchSheet() {
    MoonlightLaunchSheet({
      hostName: this.host?.displayName || '',
      appName: this.selectedItem?.title || '',
      routeValid: this.host !== null && this.selectedItem !== null,
      hostAvailable: this.paired,
      certificateChanged: false,
      identityAvailable: this.paired,
      appAvailable: this.selectedItem !== null && this.selectedItem.available && !this.selectedItem.stale,
      runtimeAvailable: this.hostService.capabilities().hostControlReady,
      onCancel: (): void => { this.showLaunchSheet = false; },
      onOpenSettings: (): void => { this.showLaunchSheet = false; this.openSettings(); },
      onRetry: (): void => { this.showLaunchSheet = false; this.requestRefresh(); },
      onStart: (): void => { this.startSelected().catch((): void => { this.launching = false; }); }
    })
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
        .onClick((): void => { router.back(); }).accessibilityText('返回')
      MoonlightBrandIcon({ iconSize: 28, tint: this.accentColor }).margin({ left: 12 })
      Column() {
        Text(this.host?.displayName || 'Moonlight 应用目录').fontSize(22).fontWeight(FontWeight.Bold)
          .fontColor(this.pal().text).fontFamily(AppTheme.fontFamily)
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

  build() {
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

        if (this.dataSource.totalCount() === 0) {
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
                  onOpen: (selected: MoonlightCatalogItem): void => { this.openItem(selected); },
                  onMore: (selected: MoonlightCatalogItem): void => {
                    promptAction.showToast({
                      message: selected.profileId === '' ? '可为此应用创建独立配置' : '已保存此应用配置',
                      duration: 1800
                    });
                  }
                })
              }
            }, (item: MoonlightCatalogItem): string => item.id)
          }.columnsTemplate(this.columns()).columnsGap(12).rowsGap(12)
            .layoutWeight(1).width('100%').scrollBar(BarState.Off)
        }
      }.width('100%').layoutWeight(1).constraintSize({ maxWidth: 1320 })
        .padding({ left: this.breakpoint === 'sm' ? 14 : 24, right: this.breakpoint === 'sm' ? 14 : 24,
          bottom: 24 })
    }.width('100%').height('100%').backgroundColor(this.pal().bg)
      .bindSheet($$this.showLaunchSheet, this.launchSheet(), {
        height: SheetSize.FIT_CONTENT,
        preferType: this.breakpoint === 'sm' ? SheetType.BOTTOM : SheetType.CENTER,
        dragBar: false,
        showClose: false,
        onDisappear: (): void => { this.selectedItem = null; }
      })
  }
}
