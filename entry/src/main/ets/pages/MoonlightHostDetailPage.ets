import { promptAction, router } from '@kit.ArkUI';
import { AppTheme, Palette, buildDark, buildLight } from '../common/Theme';
import { MoonlightBrandIcon } from '../components/moonlight/MoonlightBrandIcon';
import { MoonlightHost } from '../model/MoonlightModels';
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
  @State hostId: string = '';
  @State host: MoonlightHost | null = null;
  @State paired: boolean = false;
  @State cloudSelected: boolean = false;
  @State items: MoonlightCatalogItem[] = [];
  @State loadCode: string = 'loading';
  @State updatedAt: number = 0;
  @State showRenameEditor: boolean = false;
  @State renameValue: string = '';
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
  }

  aboutToDisappear(): void { this.pageActive = false; }

  onPageShow(): void { if (this.hostId !== '') { this.load(); } }

  private load(): void {
    if (this.hostId === '') { this.loadCode = 'invalid_route'; return; }
    const store: CloudStore = CloudStore.getInstance();
    const lease: AccountSessionLease | null = store.currentAccountLease();
    const selection: MoonlightDeletionSelectionSnapshot | null =
      lease === null ? null : store.selectionSnapshot(lease);
    this.cloudSelected = selection !== null &&
      (selection.physicalSelected || selection.selectedScopes.length > 0);
    const view: MoonlightHostLocalView = this.viewService.loadHost(this.hostId, Date.now());
    if (!view.ok || view.host === null) {
      this.loadCode = view.code;
      this.host = null;
      this.items = [];
      return;
    }
    this.host = view.host;
    this.paired = view.paired;
    this.items = view.catalogItems;
    this.updatedAt = view.updatedAt;
    this.loadCode = view.code;
  }

  private addressLabel(): string {
    if (this.host === null || this.host.addresses.length === 0) { return '未保存地址'; }
    const first = this.host.addresses[0];
    return first.host + ':' + first.port.toString();
  }

  private lastUpdateLabel(): string {
    if (this.updatedAt <= 0) { return '尚无更新时间'; }
    return new Date(this.updatedAt).toLocaleString();
  }

  private openCatalog(): void {
    const params: Record<string, Object> | null = moonlightHostRouteParams(this.hostId);
    if (params !== null) {
      router.pushUrl({ url: 'pages/MoonlightAppCatalogPage', params: params });
    }
  }

  private openSettings(): void {
    const params: Record<string, Object> | null = moonlightHostRouteParams(this.hostId);
    if (params !== null) {
      router.pushUrl({ url: 'pages/MoonlightSettingsPage', params: params });
    }
  }

  private beginRename(): void {
    if (this.host === null) { return; }
    this.renameValue = this.host.displayName;
    this.showRenameEditor = true;
  }

  private saveRename(): void {
    const result: MoonlightLocalHostMutationResult =
      this.hostService.updateDisplayName(this.hostId, this.renameValue, Date.now());
    if (!result.ok) {
      promptAction.showToast({ message: result.errorText || '主机名称保存失败', duration: 2200 });
      return;
    }
    this.showRenameEditor = false;
    this.load();
    promptAction.showToast({ message: '主机名称已保存', duration: 1600 });
  }

  private requestDelete(): void {
    if (this.host === null) { return; }
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
        message: preview.code === 'cloud_unavailable' ?
          'Moonlight 云端状态尚未就绪，未删除任何数据' :
          '主机数据已变化，请刷新后重试：' + preview.code,
        duration: 2400
      });
      return;
    }
    const hostName: string = this.host.displayName;
    const cloudMessage: string = preview.impact.cloudTombstonesRequired > 0 ?
      ' 已选择云同步的主机与配置会写入删除标记，并等待云端完成；配对信任始终只从本机移除。' :
      ' 当前设备未选择 Moonlight 云同步，不会改动云端副本。';
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
      const message: string = result.code === 'stale_preview' ?
        '主机数据在确认期间发生变化，请重新确认' :
        result.code === 'cloud_unavailable' ?
          '无法确认云端删除边界，未删除本地主机' :
          '删除失败，未完成的数据仍会保留：' + result.code;
      promptAction.showToast({ message, duration: 2600 });
      if (result.localCommitted) { this.load(); }
      return;
    }
    promptAction.showToast({
      message: result.code === 'pending_cloud' ?
        '本机主机已删除，云端删除标记正在安全上传' :
        'Moonlight 主机及其本机信任已删除',
      duration: 2200
    });
    router.back();
  }

  private requestUnpair(): void {
    if (this.host === null || !this.paired) { return; }
    const lease: AccountSessionLease | null = this.deletionRuntime.currentLease();
    const capturedHostId: string = this.hostId;
    if (lease === null || !this.deletionRuntime.isLeaseCurrent(lease)) {
      promptAction.showToast({ message: '当前账号数据域已变化，请重试', duration: 2200 });
      return;
    }
    const preview: MoonlightDeletionPreview = this.deletionRuntime.preview(
      lease, 'unpair_host', capturedHostId);
    if (preview.code !== 'ok') {
      promptAction.showToast({ message: '当前配对状态无法安全修改：' + preview.code, duration: 2400 });
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
        .enabled(this.host !== null).onClick((): void => { this.openSettings(); })
        .accessibilityText('Moonlight 设置')
    }.width('100%').padding({ left: 18, right: 18, top: this.topSafeHeight() + 8, bottom: 12 })
  }

  @Builder private chip(text: string, color: string) {
    Text(text).fontSize(10).fontColor(color).fontWeight(FontWeight.Medium)
      .padding({ left: 9, right: 9, top: 5, bottom: 5 })
      .backgroundColor(color + '16').borderRadius(11).margin({ right: 6, bottom: 6 })
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
        this.chip(this.cloudSelected ? '此设备已选云同步' : '保存在本机', this.accentColor)
        this.chip(this.paired ? '已配对' : '未配对', this.paired ? this.pal().success : this.pal().editColor)
        this.chip(this.items.length.toString() + ' 个缓存应用', this.pal().text2)
        this.chip('Host Control 已接入', this.pal().success)
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
              (): void => { this.openCatalog(); })
          }
          GridItem() {
            this.quickAction($r('sys.symbol.square_and_pencil'), '重命名', '修改本地显示名称', true,
              (): void => { this.beginRename(); })
          }
          GridItem() {
            this.quickAction($r('sys.symbol.gearshape_fill'), '设置', 'Moonlight 专属设置', true,
              (): void => { this.openSettings(); })
          }
          if (this.paired) {
            GridItem() {
              this.quickAction($r('sys.symbol.lock_open'), '解除配对', '保留主机与应用配置', true,
                (): void => { this.requestUnpair(); })
            }
          }
          GridItem() {
            this.quickAction($r('sys.symbol.ohos_trash'), '删除', '删除主机及关联配置', true,
              (): void => { this.requestDelete(); })
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
                .onClick((): void => { this.saveRename(); })
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
            .onClick((): void => { this.openCatalog(); })
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
      } else {
        this.content()
      }
    }.width('100%').height('100%').backgroundColor(this.pal().bg)
  }
}
