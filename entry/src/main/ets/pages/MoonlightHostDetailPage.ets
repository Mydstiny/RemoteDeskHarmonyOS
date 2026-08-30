import { promptAction, router } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { AppTheme, Palette, buildDark, buildLight } from '../common/Theme';
import { MoonlightBrandIcon } from '../components/moonlight/MoonlightBrandIcon';
import { LockGateResult, lockGateErrorMessage, showLockGate } from '../components/LockGate';
import {
  MoonlightAppCatalogSurface,
  MoonlightCatalogLaunchHandoff,
  presentMoonlightCatalogLaunchHandoff,
  rejectMoonlightCatalogLaunchHandoff
} from './MoonlightAppCatalogPage';
import { MoonlightSettingsSurface } from './MoonlightSettingsPage';
import { MoonlightAddress, MoonlightHost } from '../model/MoonlightModels';
import { CloudStore } from '../services/CloudStore';
import {
  AccountSessionLease,
  accountSessionLeaseEquals
} from '../services/AccountScopePolicy';
import {
  MoonlightDeletionCommandResult,
  MoonlightDeletionPreview,
  MoonlightDeletionSelectionSnapshot
} from '../services/MoonlightDeletionCommandService';
import {
  MoonlightDeletionRuntime
} from '../services/MoonlightDeletionRuntime';
import {
  MoonlightLocalHostMutationResult,
  MoonlightLocalHostService
} from '../services/MoonlightLocalHostService';
import { MoonlightHostService } from '../services/MoonlightHostService';
import {
  MoonlightHostLocalView,
  MoonlightLocalViewService
} from '../services/MoonlightLocalViewService';
import {
  MoonlightCatalogItem,
  MoonlightRouteIdentity,
  moonlightHostRouteParams,
  moonlightRouteIdentity
} from '../services/MoonlightUiPolicy';

@Entry
@Component
struct MoonlightHostDetailPage {
  @StorageLink('currentTheme') theme: string = 'light';
  @StorageLink('accentColor') accentColor: string = '#007DFF';
  @StorageProp('topRectHeight') topRectHeight: number = 0;
  @StorageProp('currentBreakpoint') breakpoint: string = 'sm';
  @StorageProp('isDesktopDevice') isDesktopDevice: boolean = false;
  @State hostId: string = '';
  @State host: MoonlightHost | null = null;
  @State paired: boolean = false;
  @State cloudSelected: boolean = false;
  @State items: MoonlightCatalogItem[] = [];
  @State loadCode: string = 'loading';
  @State updatedAt: number = 0;
  @State showRenameEditor: boolean = false;
  @State renameValue: string = '';
  @State showCatalogSheet: boolean = false;
  @State catalogDismissAllowed: boolean = true;
  @State showSettingsSheet: boolean = false;
  @State settingsDirty: boolean = false;
  @State sensitiveAccessGranted: boolean = false;
  @State sensitiveAccessChecking: boolean = false;
  private pendingCatalogNavigation: string = '';
  private pendingCatalogLaunch: MoonlightCatalogLaunchHandoff | null = null;
  private authorizedHostId: string = '';
  private readonly viewService: MoonlightLocalViewService =
    new MoonlightLocalViewService(CloudStore.getInstance());
  private readonly hostService: MoonlightLocalHostService =
    new MoonlightLocalHostService(CloudStore.getInstance(), CloudStore.getInstance());
  private readonly deletionRuntime: MoonlightDeletionRuntime =
    MoonlightDeletionRuntime.getInstance();
  private pageActive: boolean = false;

  private pal(): Palette {
    return this.theme === 'light' ? buildLight(this.accentColor) : buildDark(this.accentColor);
  }

  private topSafeHeight(): number {
    return this.topRectHeight > 0 ? px2vp(this.topRectHeight) : AppTheme.layout.statusBarH;
  }

  aboutToAppear(): void {
    this.pageActive = true;
    const params: Record<string, Object> = router.getParams() as Record<string, Object>;
    const route: MoonlightRouteIdentity = moonlightRouteIdentity(params);
    this.hostId = route.valid ? route.hostId : '';
    this.load();
    if (this.host?.locked === true) { void this.ensureHostAccess(); }
  }

  aboutToDisappear(): void {
    this.pageActive = false;
    this.catalogDismissAllowed = true;
    this.authorizedHostId = '';
    this.sensitiveAccessGranted = false;
    this.sensitiveAccessChecking = false;
  }

  onPageShow(): void {
    if (this.hostId !== '') {
      this.load();
      if (this.host?.locked === true && !this.sensitiveAccessGranted) {
        void this.ensureHostAccess();
      }
    }
  }

  private load(): void {
    if (this.hostId === '') { this.loadCode = 'invalid_route'; return; }
    const store: CloudStore = CloudStore.getInstance();
    const lease: AccountSessionLease | null = store.currentAccountLease();
    const selection: MoonlightDeletionSelectionSnapshot | null =
      lease === null ? null : store.selectionSnapshot(lease);
    this.cloudSelected = selection !== null && selection.physicalSelected;
    const view: MoonlightHostLocalView = this.viewService.loadHost(this.hostId, Date.now());
    if (!view.ok || view.host === null) {
      this.loadCode = view.code;
      this.host = null;
      this.items = [];
      this.sensitiveAccessGranted = false;
      return;
    }
    this.host = view.host;
    this.paired = view.paired;
    this.items = view.catalogItems;
    this.updatedAt = view.updatedAt;
    this.loadCode = view.code;
    this.sensitiveAccessGranted = view.host.locked !== true ||
      this.authorizedHostId === view.host.id;
  }

  private applyLatestView(view: MoonlightHostLocalView): boolean {
    if (!view.ok || view.host === null || view.host.id !== this.hostId) { return false; }
    this.host = view.host;
    this.paired = view.paired;
    this.items = view.catalogItems;
    this.updatedAt = view.updatedAt;
    this.loadCode = view.code;
    return true;
  }

  /**
   * The legacy route remains registered for old bookmarks and post-save
   * handoffs, so it must enforce the same biometric boundary as HostList.
   * Sensitive host fields are not rendered until this latest-record check has
   * committed successfully.
   */
  private async ensureHostAccess(): Promise<boolean> {
    if (!this.pageActive || this.hostId.trim() === '') { return false; }
    const latest: MoonlightHostLocalView = this.viewService.loadHost(this.hostId, Date.now());
    if (!this.applyLatestView(latest) || latest.host === null) {
      this.sensitiveAccessGranted = false;
      return false;
    }
    if (latest.host.locked !== true) {
      this.authorizedHostId = '';
      this.sensitiveAccessGranted = true;
      return true;
    }
    if (this.authorizedHostId === latest.host.id) {
      this.sensitiveAccessGranted = true;
      return true;
    }
    if (this.sensitiveAccessChecking) { return false; }
    this.sensitiveAccessChecking = true;
    const gate: LockGateResult = await showLockGate(latest.host.displayName, 'biometric');
    this.sensitiveAccessChecking = false;
    if (!this.pageActive || this.hostId !== latest.host.id) { return false; }
    if (!gate.ok) {
      this.sensitiveAccessGranted = false;
      const message: string = lockGateErrorMessage(gate);
      if (message !== '') { promptAction.showToast({ message: message, duration: 2000 }); }
      return false;
    }
    const confirmed: MoonlightHostLocalView =
      this.viewService.loadHost(this.hostId, Date.now());
    if (!this.applyLatestView(confirmed) || confirmed.host === null) {
      this.sensitiveAccessGranted = false;
      return false;
    }
    this.authorizedHostId = confirmed.host.id;
    this.sensitiveAccessGranted = true;
    return true;
  }

  private addressLabel(): string {
    if (this.host === null || this.host.addresses.length === 0) { return '未保存地址'; }
    const first: MoonlightAddress = this.host.addresses[0];
    const scope: string = first.scope === undefined ? '' : first.scope;
    const scopedHost: string = first.host + (scope === '' ? '' : '%' + scope);
    return (first.family === 'ipv6' ? '[' + scopedHost + ']' : scopedHost) +
      ':' + first.port.toString();
  }

  private lastUpdateLabel(): string {
    if (this.updatedAt <= 0) { return '尚无更新时间'; }
    return new Date(this.updatedAt).toLocaleString();
  }

  private async openCatalog(): Promise<void> {
    if (!await this.ensureHostAccess() || this.host === null || this.hostId.trim() === '') { return; }
    this.catalogDismissAllowed = true;
    this.showCatalogSheet = true;
  }

  private closeCatalogSheet(navigation: string = ''): void {
    this.pendingCatalogNavigation = navigation;
    this.showCatalogSheet = false;
  }

  private handleCatalogSheetDisappear(): void {
    const navigation: string = this.pendingCatalogNavigation;
    const launch: MoonlightCatalogLaunchHandoff | null = this.pendingCatalogLaunch;
    this.pendingCatalogNavigation = '';
    this.pendingCatalogLaunch = null;
    if (navigation === 'launch' && launch !== null) {
      setTimeout((): void => { void this.presentCatalogLaunch(launch); }, 0);
      return;
    }
    if (navigation === '' || !this.pageActive) { return; }
    setTimeout((): void => {
      if (!this.pageActive) { return; }
      if (navigation === 'settings') { void this.openSettings(); }
    }, 0);
  }

  private requestCatalogLaunch(handoff: MoonlightCatalogLaunchHandoff): void {
    if (!this.showCatalogSheet || handoff.hostId !== this.hostId) {
      this.rejectCatalogLaunch(handoff);
      return;
    }
    this.pendingCatalogLaunch = handoff;
    this.closeCatalogSheet('launch');
  }

  private rejectCatalogLaunch(handoff: MoonlightCatalogLaunchHandoff): void {
    try {
      const context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
      rejectMoonlightCatalogLaunchHandoff(context, handoff);
    } catch (_error) {
      // The native owner must still be released if this legacy page loses its
      // UI context during the handoff.
      new MoonlightHostService().disposeOwner(handoff.ownerToken);
    }
  }

  private async presentCatalogLaunch(handoff: MoonlightCatalogLaunchHandoff): Promise<void> {
    let context: common.UIAbilityContext;
    try {
      context = getContext(this) as common.UIAbilityContext;
    } catch (_error) {
      new MoonlightHostService().disposeOwner(handoff.ownerToken);
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

  private async openSettings(): Promise<void> {
    if (!await this.ensureHostAccess() ||
        moonlightHostRouteParams(this.hostId) === null || this.host === null) { return; }
    this.showSettingsSheet = true;
  }

  private closeSettingsSheet(): void {
    if (!this.settingsDirty) {
      this.showSettingsSheet = false;
      return;
    }
    promptAction.showDialog({
      title: '放弃未保存的 Moonlight 设置？',
      message: '当前修改只在本地草稿中，放弃后不会写入 Moonlight 本地记录。',
      buttons: [{ text: '继续编辑', color: this.pal().text2 },
        { text: '放弃修改', color: this.pal().danger }]
    }).then((result: Object): void => {
      const dialogResult: Record<string, number> = result as Record<string, number>;
      if (dialogResult['index'] === 1) {
        this.settingsDirty = false;
        this.showSettingsSheet = false;
      }
    });
  }

  @Builder private catalogSheet() {
    MoonlightAppCatalogSurface({
      embedded: true,
      requestedHostId: this.hostId,
      onClose: (): void => { this.closeCatalogSheet(); },
      onOpenSettings: (): void => { this.closeCatalogSheet('settings'); },
      onOpenHostDetail: (): void => { this.closeCatalogSheet(); },
      onDismissAllowedChanged: (allowed: boolean): void => {
        this.catalogDismissAllowed = allowed;
      },
      onLaunchRequested: (handoff: MoonlightCatalogLaunchHandoff): void => {
        this.requestCatalogLaunch(handoff);
      }
    })
  }

  @Builder private settingsSheet() {
    MoonlightSettingsSurface({
      embedded: true,
      requestedSection: 'video',
      requestedHostId: this.hostId,
      onClose: (): void => { this.closeSettingsSheet(); },
      onDirtyChanged: (dirty: boolean): void => { this.settingsDirty = dirty; }
    })
  }

  private async beginRename(): Promise<void> {
    if (!await this.ensureHostAccess() || this.host === null) { return; }
    this.renameValue = this.host.displayName;
    this.showRenameEditor = true;
  }

  private async saveRename(): Promise<void> {
    if (!await this.ensureHostAccess()) { return; }
    const result: MoonlightLocalHostMutationResult =
      this.hostService.updateDisplayName(this.hostId, this.renameValue, Date.now());
    if (!result.ok) {
      promptAction.showToast({ message: result.errorText || '主机名称保存失败', duration: 2200 });
      return;
    }
    this.showRenameEditor = false;
    this.load();
    promptAction.showToast({
      message: result.code === 'pending_local_verification' ?
        '主机名称已保存，正在后台核验' : '主机名称已保存',
      duration: 1800
    });
  }

  private deletionFailureMessage(code: string): string {
    if (code === 'stale_lease') {
      return '当前账号数据域已变化，请重新进入页面';
    }
    if (code === 'stale_preview' || code === 'not_found') {
      return '主机数据在确认期间发生变化，请刷新后重新确认';
    }
    if (code === 'read_failed' || code === 'invalid_data') {
      return '本地主机数据暂时无法读取，请刷新或重启应用后重试';
    }
    if (code === 'local_write_failed') {
      return '本地主机删除未能保存，请检查设备存储后重试';
    }
    if (code === 'cloud_unavailable') {
      return '云端暂不可用；本地主机未发生不确定修改，请稍后重试';
    }
    return '主机删除未完成，请刷新后重试';
  }

  private async requestDelete(): Promise<void> {
    if (!await this.ensureHostAccess() || this.host === null) { return; }
    const lease: AccountSessionLease | null = this.deletionRuntime.currentLease();
    const capturedHostId: string = this.hostId;
    if (lease === null || !this.deletionRuntime.isLeaseCurrent(lease) ||
        capturedHostId === '') {
      promptAction.showToast({ message: '当前账号数据域已变化，请重新进入页面', duration: 2200 });
      return;
    }
    const preview: MoonlightDeletionPreview = this.deletionRuntime.preview(
      lease, 'forget_host', capturedHostId);
    if (preview.code !== 'ok') {
      promptAction.showToast({
        message: this.deletionFailureMessage(preview.code),
        duration: 2400
      });
      return;
    }
    const hostName: string = this.host.displayName;
    const cloudMessage: string = preview.impact.cloudTombstonesRequired > 0 ?
      ' 主机与配置会先从本机删除；云同步可用后自动同步删除状态。配对信任始终只从本机移除。' :
      ' 主机与配置会立即从本机删除，并保留防止以后重新启用同步时复活的删除状态。';
    promptAction.showDialog({
      title: '删除 Moonlight 主机？',
      message: '将删除“' + hostName + '”在此账号下的主机、' +
        preview.context.profileRecordCount.toString() + ' 个应用配置、配对信任和 ' +
        preview.context.appCacheCount.toString() + ' 条目录缓存。' + cloudMessage +
        ' 此操作不会删除 Sunshine 主机。',
      buttons: [
        { text: '取消', color: this.pal().text2 },
        { text: '删除', color: this.pal().danger }
      ]
    }).then((value: Object): void => {
      const selected: Record<string, number> = value as Record<string, number>;
      if (selected['index'] !== 1) { return; }
      void this.executeDelete(lease, preview, capturedHostId);
    });
  }

  private async executeDelete(lease: AccountSessionLease,
    preview: MoonlightDeletionPreview, capturedHostId: string): Promise<void> {
    const currentLease: AccountSessionLease | null =
      this.deletionRuntime.currentLease();
    if (!this.pageActive || this.hostId !== capturedHostId ||
        currentLease === null || !accountSessionLeaseEquals(currentLease, lease) ||
        !this.deletionRuntime.isLeaseCurrent(lease)) {
      if (this.pageActive) {
        promptAction.showToast({ message: '账号或页面状态已变化，未执行删除', duration: 2200 });
      }
      return;
    }
    const result: MoonlightDeletionCommandResult =
      await this.deletionRuntime.execute(lease, preview);
    if (!this.pageActive) { return; }
    if (!result.ok) {
      const message: string = this.deletionFailureMessage(result.code);
      promptAction.showToast({ message, duration: 2600 });
      if (result.localCommitted) { this.load(); }
      return;
    }
    promptAction.showToast({
      message: result.code === 'pending_cloud' ?
        '本机主机已删除；云同步可用后会自动同步删除状态' :
        result.code === 'pending_local_verification' ?
          '本机删除已保存，正在后台核验并同步状态' :
        'Moonlight 主机及其本机信任已删除',
      duration: 2200
    });
    router.back();
  }

  private async requestUnpair(): Promise<void> {
    if (!await this.ensureHostAccess() || this.host === null || !this.paired) { return; }
    const lease: AccountSessionLease | null = this.deletionRuntime.currentLease();
    const capturedHostId: string = this.hostId;
    if (lease === null || !this.deletionRuntime.isLeaseCurrent(lease)) {
      promptAction.showToast({ message: '当前账号数据域已变化，请重试', duration: 2200 });
      return;
    }
    const preview: MoonlightDeletionPreview = this.deletionRuntime.preview(
      lease, 'unpair_host', capturedHostId);
    if (preview.code !== 'ok') {
      promptAction.showToast({
        message: this.deletionFailureMessage(preview.code),
        duration: 2400
      });
      return;
    }
    promptAction.showDialog({
      title: '解除与此主机的配对？',
      message: '将先从本机撤销证书信任，再尽力通知 Sunshine 删除此客户端。' +
        '主机、应用配置、目录缓存和云端公开数据都会保留；再次连接需要重新输入 PIN。',
      buttons: [
        { text: '取消', color: this.pal().text2 },
        { text: '解除配对', color: this.pal().danger }
      ]
    }).then((value: Object): void => {
      const selected: Record<string, number> = value as Record<string, number>;
      if (selected['index'] === 1) {
        void this.executeUnpair(lease, preview, capturedHostId);
      }
    });
  }

  private async executeUnpair(lease: AccountSessionLease,
    preview: MoonlightDeletionPreview, capturedHostId: string): Promise<void> {
    const currentLease: AccountSessionLease | null =
      this.deletionRuntime.currentLease();
    if (!this.pageActive || this.hostId !== capturedHostId ||
        currentLease === null || !accountSessionLeaseEquals(currentLease, lease) ||
        !this.deletionRuntime.isLeaseCurrent(lease)) {
      if (this.pageActive) {
        promptAction.showToast({ message: '账号或页面状态已变化，未解除配对', duration: 2200 });
      }
      return;
    }
    const result: MoonlightDeletionCommandResult =
      await this.deletionRuntime.execute(lease, preview);
    if (!this.pageActive) { return; }
    if (!result.ok) {
      promptAction.showToast({
        message: result.code === 'host_unavailable' ?
          'Host Control 尚未就绪，配对信任保持不变' :
          '解除配对失败：' + result.code,
        duration: 2400
      });
      return;
    }
    this.load();
    promptAction.showToast({
      message: result.code === 'ok_with_remote_warning' ?
        '本机信任已撤销；Sunshine 当前不可达，可稍后在主机端清理客户端' :
        '已解除配对，主机和应用配置均已保留',
      duration: 2800
    });
  }

  @Builder private header() {
    Row() {
      Button() { SymbolGlyph($r('sys.symbol.chevron_left')).fontSize(21).fontColor([this.pal().text]) }
        .width(42).height(42).borderRadius(21).backgroundColor(this.pal().surface)
        .onClick((): void => { router.back(); }).accessibilityText('返回')
      Column() {
        Text('Moonlight 主机').fontSize(24).fontWeight(FontWeight.Bold)
          .fontColor(this.pal().text).fontFamily(AppTheme.fontFamily)
        Text('主机详情、应用目录与配对状态').fontSize(11).fontColor(this.pal().text3)
          .fontFamily(AppTheme.fontFamily).margin({ top: 2 })
      }.alignItems(HorizontalAlign.Start).layoutWeight(1).margin({ left: 12 })
      Button() { SymbolGlyph($r('sys.symbol.gearshape_fill')).fontSize(19).fontColor([this.pal().text]) }
        .width(42).height(42).borderRadius(21).backgroundColor(this.pal().surface)
        .enabled(this.host !== null).onClick((): void => { void this.openSettings(); })
        .accessibilityText('Moonlight 设置')
    }.width('100%').padding({ left: 18, right: 18, top: this.topSafeHeight() + 8, bottom: 12 })
  }

  @Builder private quickAction(icon: Resource, title: string, detail: string,
    enabled: boolean, action: () => void) {
    Button() {
      Column({ space: 5 }) {
        SymbolGlyph(icon).fontSize(21).fontColor([enabled ? this.accentColor : this.pal().text3])
        Text(title).fontSize(12).fontWeight(FontWeight.Medium)
          .fontColor(enabled ? this.pal().text : this.pal().text3)
        Text(detail).fontSize(9).fontColor(this.pal().text3).maxLines(1)
      }.width('100%')
    }.height(78).layoutWeight(1).borderRadius(16).backgroundColor(this.pal().surface)
      .enabled(true).opacity(enabled ? 1 : 0.64)
      .onClick((): void => {
        if (enabled) { action(); }
        else { promptAction.showToast({ message: detail, duration: 1800 }); }
      })
  }

  @Builder private hostSummary() {
    Column() {
      Row() {
        Stack({ alignContent: Alignment.Center }) {
          MoonlightBrandIcon({ iconSize: 38, tint: this.accentColor })
        }.width(66).height(66).borderRadius(20).backgroundColor(this.pal().surface)
        Column() {
          Text(this.host?.displayName || '未知主机').fontSize(21).fontWeight(FontWeight.Bold)
            .fontColor(this.pal().text).fontFamily(AppTheme.fontFamily)
          Text(this.addressLabel()).fontSize(12).fontColor(this.pal().text2)
            .fontFamily('monospace').margin({ top: 5 })
          Text(this.host?.hostType === 'gamestream' ? 'NVIDIA GameStream' : 'Sunshine')
            .fontSize(10).fontColor(this.pal().text3).margin({ top: 3 })
        }.alignItems(HorizontalAlign.Start).layoutWeight(1).margin({ left: 14 })
        Column() {
          Column().width(9).height(9).borderRadius(5).backgroundColor(this.pal().text3)
          Text('离线/未探测').fontSize(10).fontColor(this.pal().text3).margin({ top: 5 })
        }.alignItems(HorizontalAlign.End)
      }.width('100%')

      Flex({ wrap: FlexWrap.Wrap }) {
        // These values change after returning from catalog refresh. ArkUI V1
        // freezes primitive @Builder arguments at their first render, so keep
        // the state-dependent chips in the owning builder.
        Text(this.cloudSelected ? '此设备已选云同步' : '保存在本机')
          .fontSize(10).fontColor(this.accentColor).fontWeight(FontWeight.Medium)
          .padding({ left: 9, right: 9, top: 5, bottom: 5 })
          .backgroundColor(this.accentColor + '16').borderRadius(11)
          .margin({ right: 6, bottom: 6 })
        Text(this.items.length.toString() + ' 个缓存应用')
          .fontSize(10).fontColor(this.pal().text2).fontWeight(FontWeight.Medium)
          .padding({ left: 9, right: 9, top: 5, bottom: 5 })
          .backgroundColor(this.pal().text2 + '16').borderRadius(11)
          .margin({ right: 6, bottom: 6 })
        Text('Host Control 已接入')
          .fontSize(10).fontColor(this.pal().success).fontWeight(FontWeight.Medium)
          .padding({ left: 9, right: 9, top: 5, bottom: 5 })
          .backgroundColor(this.pal().success + '16').borderRadius(11)
          .margin({ right: 6, bottom: 6 })
      }.width('100%').margin({ top: 16 })

      Text('最近更新：' + this.lastUpdateLabel()).fontSize(10).fontColor(this.pal().text3)
        .width('100%').margin({ top: 4 })
    }.width('100%').padding(20).backgroundColor(this.pal().card).borderRadius(24)
      .border({ width: 0.5, color: this.pal().cardBorder })
      .shadow({ radius: 16, color: 'rgba(0,0,0,0.04)', offsetY: 4 })
  }

  @Builder private content() {
    Scroll() {
      Column() {
        this.hostSummary()
        Text('快捷操作').fontSize(13).fontWeight(FontWeight.Medium).fontColor(this.pal().text3)
          .width('100%').margin({ top: 20, bottom: 8, left: 6 })
        Grid() {
          GridItem() {
            this.quickAction($r('sys.symbol.list_bullet'), '应用', '刷新与启动应用', true,
              (): void => { void this.openCatalog(); })
          }
          GridItem() {
            this.quickAction($r('sys.symbol.square_and_pencil'), '重命名', '修改本地显示名称', true,
              (): void => { void this.beginRename(); })
          }
          GridItem() {
            this.quickAction($r('sys.symbol.gearshape_fill'), '设置', 'Moonlight 专属设置', true,
              (): void => { void this.openSettings(); })
          }
          if (this.paired) {
            GridItem() {
              this.quickAction($r('sys.symbol.lock_open'), '解除配对', '保留主机与应用配置', true,
                (): void => { void this.requestUnpair(); })
            }
          }
          GridItem() {
            this.quickAction($r('sys.symbol.ohos_trash'), '删除', '删除主机及关联配置', true,
              (): void => { void this.requestDelete(); })
          }
        }.columnsTemplate(this.breakpoint === 'sm' ? '1fr 1fr' : '1fr 1fr 1fr')
          .columnsGap(9).rowsGap(9).width('100%')

        if (this.showRenameEditor) {
          Column() {
            Text('本地显示名称').fontSize(12).fontWeight(FontWeight.Medium)
              .fontColor(this.pal().text).width('100%')
            TextInput({ text: this.renameValue, placeholder: '输入主机名称' })
              .height(44).fontSize(14).fontColor(this.pal().text)
              .backgroundColor(this.pal().surface).borderRadius(12).margin({ top: 9 })
              .onChange((value: string): void => { this.renameValue = value; })
            Row({ space: 12 }) {
              Button('取消').layoutWeight(1).height(42).borderRadius(12)
                .backgroundColor(this.pal().surface).fontColor(this.pal().text2)
                .onClick((): void => { this.showRenameEditor = false; })
              Button('保存').layoutWeight(1).height(42).borderRadius(12)
                .backgroundColor(this.accentColor).fontColor(Color.White)
                .enabled(this.renameValue.trim().length > 0 && this.renameValue.trim().length <= 128)
                .onClick((): void => { void this.saveRename(); })
            }.width('100%').margin({ top: 12 })
          }.width('100%').padding(16).backgroundColor(this.pal().card).borderRadius(18)
            .border({ width: 0.5, color: this.pal().cardBorder }).margin({ top: 12 })
        }

        Row() {
          Column() {
            Text('应用目录').fontSize(17).fontWeight(FontWeight.Bold).fontColor(this.pal().text)
            Text(this.items.length === 0 ? '本地尚无目录缓存' :
              '按主机分类，刷新失败不会清空旧目录').fontSize(11).fontColor(this.pal().text3)
              .margin({ top: 4 })
          }.alignItems(HorizontalAlign.Start).layoutWeight(1)
          Button('查看全部').height(36).fontSize(12).borderRadius(12)
            .backgroundColor(this.accentColor).fontColor(Color.White)
            .onClick((): void => { void this.openCatalog(); })
        }.width('100%').margin({ top: 24, bottom: 10 })

        if (this.items.length === 0) {
          Column() {
            MoonlightBrandIcon({ iconSize: 34, tint: this.pal().text3 })
            Text('主机上线后刷新应用目录').fontSize(13).fontColor(this.pal().text2).margin({ top: 10 })
            Text('不会删除已有主机或应用配置').fontSize(10).fontColor(this.pal().text3).margin({ top: 4 })
          }.width('100%').height(170).justifyContent(FlexAlign.Center)
            .backgroundColor(this.pal().card).borderRadius(20)
        } else {
          Column() {
            ForEach(this.items.slice(0, 4), (item: MoonlightCatalogItem): void => {
              Row() {
                Stack({ alignContent: Alignment.Center }) {
                  MoonlightBrandIcon({ iconSize: 22, tint: this.accentColor })
                }.width(44).height(44).borderRadius(12).backgroundColor(this.pal().surface)
                Column() {
                  Text(item.title).fontSize(14).fontWeight(FontWeight.Medium).fontColor(this.pal().text)
                    .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                  Text(item.available && !item.stale ? '可用' : '缓存/当前不可用')
                    .fontSize(10).fontColor(item.available && !item.stale ? this.pal().success : this.pal().text3)
                    .margin({ top: 3 })
                }.alignItems(HorizontalAlign.Start).layoutWeight(1).margin({ left: 10 })
                SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(15).fontColor([this.pal().text3])
              }.width('100%').height(62).padding({ left: 10, right: 12 })
              if (item.id !== this.items[Math.min(this.items.length, 4) - 1].id) {
                Divider().color(this.pal().divider).margin({ left: 64 })
              }
            }, (item: MoonlightCatalogItem): string => item.id)
          }.width('100%').backgroundColor(this.pal().card).borderRadius(20)
            .border({ width: 0.5, color: this.pal().cardBorder })
        }
      }.width('100%').constraintSize({ maxWidth: 1040 })
        .padding({ left: this.breakpoint === 'sm' ? 18 : 28, right: this.breakpoint === 'sm' ? 18 : 28,
          bottom: 32 })
    }.width('100%').layoutWeight(1).scrollBar(BarState.Off)
  }

  build() {
    Column() {
      this.header()
      if (this.host === null) {
        Column() {
          SymbolGlyph($r('sys.symbol.exclamationmark_triangle_fill')).fontSize(42)
            .fontColor([this.pal().editColor])
          Text(this.loadCode === 'loading' ? '正在读取本地主机' : '无法打开 Moonlight 主机')
            .fontSize(17).fontWeight(FontWeight.Bold).fontColor(this.pal().text).margin({ top: 14 })
          Text(this.loadCode).fontSize(11).fontColor(this.pal().text3).fontFamily('monospace').margin({ top: 6 })
          Button('返回').height(42).width(160).borderRadius(12).backgroundColor(this.accentColor)
            .fontColor(Color.White).margin({ top: 18 }).onClick((): void => { router.back(); })
        }.layoutWeight(1).width('100%').justifyContent(FlexAlign.Center)
      } else if (this.host.locked === true && !this.sensitiveAccessGranted) {
        Column() {
          SymbolGlyph($r('sys.symbol.ohos_lock')).fontSize(42)
            .fontColor([this.accentColor])
          Text('此 Moonlight 主机已锁定').fontSize(17).fontWeight(FontWeight.Bold)
            .fontColor(this.pal().text).margin({ top: 14 })
          Text('验证身份后才会显示地址、应用目录和主机操作')
            .fontSize(11).fontColor(this.pal().text3).margin({ top: 6 })
          Button(this.sensitiveAccessChecking ? '正在验证…' : '验证身份')
            .height(42).width(160).borderRadius(12).backgroundColor(this.accentColor)
            .fontColor(Color.White).enabled(!this.sensitiveAccessChecking)
            .margin({ top: 18 }).onClick((): void => { void this.ensureHostAccess(); })
        }.layoutWeight(1).width('100%').justifyContent(FlexAlign.Center)
      } else {
        this.content()
      }
    }.width('100%').height('100%').backgroundColor(this.pal().bg)
      .bindSheet($$this.showCatalogSheet, this.catalogSheet(), {
        height: SheetSize.LARGE,
        preferType: this.breakpoint === 'sm' ? SheetType.BOTTOM : SheetType.CENTER,
        dragBar: this.breakpoint === 'sm',
        backgroundColor: this.pal().sheetBg,
        blurStyle: BlurStyle.NONE,
        showClose: false,
        maskColor: 'rgba(0,0,0,0.4)',
        onWillDismiss: (action: DismissSheetAction): void => {
          if (!this.catalogDismissAllowed) { return; }
          this.showCatalogSheet = false;
          action.dismiss();
        },
        onDisappear: (): void => {
          this.catalogDismissAllowed = true;
          this.handleCatalogSheetDisappear();
        }
      })
      .bindSheet($$this.showSettingsSheet, this.settingsSheet(), {
        height: SheetSize.LARGE,
        preferType: this.breakpoint === 'sm' ? SheetType.BOTTOM : SheetType.CENTER,
        dragBar: this.breakpoint === 'sm',
        backgroundColor: this.pal().sheetBg,
        blurStyle: BlurStyle.NONE,
        showClose: false,
        maskColor: 'rgba(0,0,0,0.4)',
        onWillDismiss: (action: DismissSheetAction): void => {
          if (!this.settingsDirty) { action.dismiss(); }
        },
        onDisappear: (): void => {
          this.showSettingsSheet = false;
          this.settingsDirty = false;
        }
      })
  }
}
