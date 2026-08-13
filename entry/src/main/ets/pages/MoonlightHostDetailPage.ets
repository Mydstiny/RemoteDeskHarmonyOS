import { promptAction, router } from '@kit.ArkUI';
import { AppTheme, Palette, buildDark, buildLight } from '../common/Theme';
import { MoonlightBrandIcon } from '../components/moonlight/MoonlightBrandIcon';
import { MoonlightHost } from '../model/MoonlightModels';
import { CloudStore } from '../services/CloudStore';
import { AccountSessionLease } from '../services/AccountScopePolicy';
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
  @State items: MoonlightCatalogItem[] = [];
  @State loadCode: string = 'loading';
  @State updatedAt: number = 0;
  @State showRenameEditor: boolean = false;
  @State renameValue: string = '';
  private readonly viewService: MoonlightLocalViewService =
    new MoonlightLocalViewService(CloudStore.getInstance());
  private readonly hostService: MoonlightLocalHostService =
    new MoonlightLocalHostService(CloudStore.getInstance(), CloudStore.getInstance());
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
    promptAction.showToast({ message: '主机名称已保存到本地', duration: 1600 });
  }

  private requestDelete(): void {
    if (this.host === null) { return; }
    const store: CloudStore = CloudStore.getInstance();
    const lease: AccountSessionLease | null = store.currentAccountLease();
    const capturedHostId: string = this.hostId;
    if (lease === null || !store.isLeaseCurrent(lease) || capturedHostId === '') {
      promptAction.showToast({ message: '当前账号数据域已变化，请重新进入页面', duration: 2200 });
      return;
    }
    const hostName: string = this.host.displayName;
    promptAction.showDialog({
      title: '删除 Moonlight 主机？',
      message: '将删除“' + hostName + '”的本地主机、信任、配置与应用缓存。此操作不影响 Sunshine 主机。',
      buttons: [
        { text: '取消', color: this.pal().text2 },
        { text: '删除', color: this.pal().danger }
      ]
    }).then((value: Object): void => {
      const selected: Record<string, number> = value as Record<string, number>;
      if (selected['index'] !== 1) { return; }
      const currentLease: AccountSessionLease | null = store.currentAccountLease();
      if (!this.pageActive || this.hostId !== capturedHostId || currentLease === null ||
          !store.isLeaseCurrent(lease) || !store.isLeaseCurrent(currentLease) ||
          currentLease.ownerScopeId !== lease.ownerScopeId ||
          currentLease.generation !== lease.generation ||
          currentLease.storeIdentity !== lease.storeIdentity ||
          currentLease.storeInstanceId !== lease.storeInstanceId) {
        if (this.pageActive) {
          promptAction.showToast({ message: '账号或页面状态已变化，未执行删除', duration: 2200 });
        }
        return;
      }
      const result: MoonlightLocalHostMutationResult =
        this.hostService.deleteHost(capturedHostId, Date.now());
      if (!result.ok) {
        promptAction.showToast({ message: result.errorText || '本地主机删除失败', duration: 2200 });
        return;
      }
      promptAction.showToast({ message: 'Moonlight 本地主机已删除', duration: 1600 });
      router.back();
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
        Text('本地主机详情与应用目录').fontSize(11).fontColor(this.pal().text3)
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
        this.chip('仅本地', this.accentColor)
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
          GridItem() {
            this.quickAction($r('sys.symbol.ohos_trash'), '删除', '删除本地主机数据', true,
              (): void => { this.requestDelete(); })
          }
        }.columnsTemplate(this.breakpoint === 'sm' ? '1fr 1fr' : '1fr 1fr 1fr 1fr')
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
