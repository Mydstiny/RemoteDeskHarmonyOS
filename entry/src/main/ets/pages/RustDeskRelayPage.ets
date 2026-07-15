/**
 * RustDeskRelayPage.ets — RustDesk 中继服务器管理页面 v2
 *
 * v2 改进:
 * - 卡片样式对齐 HostCard/SshKeyCard/TotpCodeCard (圆角14, 无阴影, padding 12)
 * - 顶部概览条: 中继/在线/异常/账户统计
 * - PC端 ⋯ popup 菜单替代4个文字按钮 (对齐 SshKeyCard)
 * - 移动端 swipeAction 右滑测试+编辑, 左滑删除 (对齐 KeyVaultPage)
 * - 空状态引导式设计
 * - 展开/折叠动画 + 服务器信息区
 * - 账户行样式对齐 TotpCodeCard
 * - FAB + bindSheet 添加/编辑流程保持不变
 */
import { promptAction, curves } from '@kit.ArkUI';
import { socket } from '@kit.NetworkKit';
import { RustDeskRelayConfig } from '../model/RustDeskRelayConfig';
import { RustDeskAccount } from '../model/RustDeskAccount';
import { HostSyncService } from '../services/HostSyncService';
import { snapshotSelectedRelay } from '../services/RustDeskRelayHealthPolicy';
import { Palette, buildDark, buildLight, AppTheme } from '../common/Theme';

class TcpTestResult {
  ok: boolean = false;
  lat: number = 0;
}

@Component
export struct RustDeskRelayPage {
  @StorageLink('currentTheme') theme: string = 'light';
  @StorageLink('accentColor') accentColor: string = '#007DFF';
  @Prop @Watch('onAddTrigger') addTrigger: number = 0;
  @Prop hideTabBar: boolean = false;
  @StorageProp('currentBreakpoint') breakpoint: string = 'sm';
  @StorageProp('isDesktopDevice') isDesktopDevice: boolean = false;
  @StorageProp('topRectHeight') topRectHeight: number = 0;
  @State relays: RustDeskRelayConfig[] = [];
  @State expandedRelayIds: string[] = [];
  @State showSheet: boolean = false;
  @State sheetContent: number = 1;  // 1=relay, 2=account
  @State editingRelayId: string = '';
  // PC: selected relay object for detail panel (reference change = guaranteed re-render)
  @State selectedPcRelay: RustDeskRelayConfig | null = null;
  // PC popup menu
  @State menuVisibleRelayId: string = '';
  // Relay form
  @State formIdServer: string = '';
  @State formIdPort: number = 21116;
  @State formRelayServer: string = '';
  @State formRelayPort: number = 21117;
  @State formApiServer: string = '';
  @State formKey: string = '';
  @State formTestResult: string = '';
  // Account form
  @State editingAccountId: string = '';
  @State accountRelayId: string = '';
  @State formAcctUser: string = '';
  @State formAcctPwd: string = '';
  private srv: HostSyncService = HostSyncService.getInstance();
  private dataUnsubscribe: (() => void) | null = null;
  private pageActive: boolean = false;

  private pal(): Palette {
    return this.theme === 'light' ? buildLight(this.accentColor) : buildDark(this.accentColor);
  }
  private font(): string { return AppTheme.fontFamily; }
  private topSafeH(): number { return this.topRectHeight > 0 ? px2vp(this.topRectHeight) : AppTheme.layout.statusBarH; }
  private titleBarH(): number { return this.topSafeH() + 66; }
  private titleOffsetY(): number { return 8; }
  private contentTopSpacer(): number { return this.titleBarH() + 14; }

  aboutToAppear(): void {
    this.pageActive = true;
    this.registerDataRefreshListener();
    this.load();
    this.srv.whenReady().then((): void => {
      if (this.pageActive) { this.load(); }
    });
  }
  onPageShow(): void { this.load(); }
  aboutToDisappear(): void {
    this.pageActive = false;
    if (this.dataUnsubscribe) {
      this.dataUnsubscribe();
      this.dataUnsubscribe = null;
    }
  }
  private registerDataRefreshListener(): void {
    if (!this.dataUnsubscribe) {
      this.dataUnsubscribe = this.srv.onDataChange((): void => {
        this.load();
      });
    }
  }
  private load(): void {
    const selectedRelayId = this.selectedPcRelay ? this.selectedPcRelay.id : '';
    const nextRelays = this.srv.getAllRelays();
    this.relays = nextRelays;
    if (selectedRelayId !== '') {
      this.selectedPcRelay = snapshotSelectedRelay(nextRelays, selectedRelayId);
    }
  }
  onAddTrigger(): void {
    if (this.addTrigger > 0) { this.openAddRelaySheet(); }
  }

  // ==================== Stats ====================

  private onlineCount(): number {
    let c = 0;
    this.relays.forEach((r: RustDeskRelayConfig) => { if (r.healthStatus === 'online') { c++; } });
    return c;
  }
  private errorCount(): number {
    let c = 0;
    this.relays.forEach((r: RustDeskRelayConfig) => { if (r.healthStatus === 'offline' || r.healthStatus === 'error') { c++; } });
    return c;
  }
  private totalAccountCount(): number {
    let c = 0;
    this.relays.forEach((r: RustDeskRelayConfig) => { c += r.accounts.length; });
    return c;
  }
  private totalHostCount(): number {
    let c = 0;
    this.relays.forEach((r: RustDeskRelayConfig) => { c += this.hostCountForRelay(r.id); });
    return c;
  }

  // ==================== Expand / Collapse ====================

  private isRelayExpanded(id: string): boolean { return this.expandedRelayIds.includes(id); }
  private toggleRelayExpanded(id: string): void {
    animateTo({ duration: 280, curve: curves.interpolatingSpring(0, 0.82, 260, 22) }, () => {
      if (this.isRelayExpanded(id)) {
        this.expandedRelayIds = this.expandedRelayIds.filter((relayId: string): boolean => relayId !== id);
      } else {
        const ids: string[] = this.expandedRelayIds.slice();
        ids.push(id);
        this.expandedRelayIds = ids;
      }
    });
  }

  // ==================== Status helpers ====================

  private relayStatusColor(relay: RustDeskRelayConfig): string {
    if (relay.healthStatus === 'online') { return this.pal().success; }
    if (relay.healthStatus === 'offline' || relay.healthStatus === 'error') { return this.pal().danger; }
    return this.pal().text3;
  }

  private relayStatusLabel(relay: RustDeskRelayConfig): string {
    if (relay.healthStatus === 'online') {
      return relay.healthLatency > 0 ? '在线 · ' + relay.healthLatency + 'ms' : '在线';
    }
    if (relay.healthStatus === 'offline') { return '离线'; }
    if (relay.healthStatus === 'error') { return '异常'; }
    return '未检测';
  }

  private relayCheckedAtLabel(relay: RustDeskRelayConfig): string {
    if (relay.healthCheckedAt <= 0) { return ''; }
    const diff: number = Date.now() - relay.healthCheckedAt;
    if (diff < 60000) { return '刚刚'; }
    if (diff < 3600000) { return Math.floor(diff / 60000) + '分钟前'; }
    if (diff < 86400000) { return Math.floor(diff / 3600000) + '小时前'; }
    return Math.floor(diff / 86400000) + '天前';
  }

  private hostCountForRelay(relayId: string): number {
    let count = 0;
    this.srv.getAllHosts().forEach((h) => {
      if (h.rustdeskRelayId === relayId) { count++; }
    });
    return count;
  }

  private hostCountForAccount(relayId: string, accountId: string): number {
    let count = 0;
    this.srv.getAllHosts().forEach((h) => {
      if (h.rustdeskRelayId === relayId && h.rustdeskAccountId === accountId) { count++; }
    });
    return count;
  }

  private accountStatusLabel(acct: RustDeskAccount): string {
    if (acct.loginStatus === 'logged_in') { return '已登录'; }
    if (acct.loginStatus === 'expired') { return '已过期'; }
    return '未登录';
  }

  private accountStatusColor(acct: RustDeskAccount): string {
    if (acct.loginStatus === 'logged_in') { return this.pal().success; }
    if (acct.loginStatus === 'expired') { return this.pal().danger; }
    return this.pal().text3;
  }

  // ==================== Sheet openers ====================

  private openAddRelaySheet(): void {
    this.resetRelayForm();
    this.sheetContent = 1;
    this.showSheet = true;
  }

  private closeSheet(): void {
    this.showSheet = false;
    this.sheetContent = 1;
    this.resetRelayForm();
    this.editingAccountId = '';
    this.accountRelayId = '';
    this.formAcctUser = '';
    this.formAcctPwd = '';
    this.load();
  }

  private openEditRelaySheet(relay: RustDeskRelayConfig): void {
    this.menuVisibleRelayId = '';
    this.editingRelayId = relay.id;
    this.formIdServer = relay.idServer;
    this.formIdPort = relay.idServerPort;
    this.formRelayServer = relay.relayServer;
    this.formRelayPort = relay.relayPort;
    this.formApiServer = relay.apiServer;
    this.formKey = relay.key;
    this.formTestResult = '';
    this.sheetContent = 1;
    this.showSheet = true;
  }

  private openAccountSheet(relay: RustDeskRelayConfig, account?: RustDeskAccount): void {
    this.accountRelayId = relay.id;
    this.editingAccountId = account ? account.id : '';
    this.formAcctUser = account ? account.username : '';
    this.formAcctPwd = account ? account.password : '';
    this.sheetContent = 2;
    this.showSheet = true;
  }

  // ==================== Relay CRUD ====================

  private resetRelayForm(): void {
    this.editingRelayId = ''; this.formIdServer = ''; this.formIdPort = 21116;
    this.formRelayServer = ''; this.formRelayPort = 21117;
    this.formApiServer = ''; this.formKey = ''; this.formTestResult = '';
  }

  private doSaveRelay(): void {
    if (this.formIdServer.trim() === '' || this.formRelayServer.trim() === '') {
      promptAction.showToast({ message: 'ID服务器和中继服务器地址不能为空', duration: 2000 }); return;
    }
    const r = new RustDeskRelayConfig();
    r.id = this.editingRelayId !== '' ? this.editingRelayId : RustDeskRelayConfig.generateId();
    r.idServer = this.formIdServer.trim(); r.idServerPort = this.formIdPort;
    r.relayServer = this.formRelayServer.trim(); r.relayPort = this.formRelayPort;
    r.apiServer = this.formApiServer.trim(); r.key = this.formKey.trim();
    if (this.editingRelayId !== '') {
      const existing = this.relays.find((x: RustDeskRelayConfig) => x.id === this.editingRelayId);
      if (existing) { r.accounts = existing.accounts; }
      this.srv.updateRelay(r);
    } else { this.srv.addRelay(r); }
    this.closeSheet();
  }

  // TCP socket 连通性测试
  private async tcpTest(host: string, port: number): Promise<TcpTestResult> {
    const start = Date.now();
    const result: TcpTestResult = new TcpTestResult();
    let tcp: socket.TCPSocket | null = null;
    try {
      tcp = socket.constructTCPSocketInstance();
      const addr: socket.NetAddress = { address: host, port: port, family: 1 };
      await tcp.connect({ address: addr, timeout: 5000 });
      result.ok = true;
      result.lat = Date.now() - start;
    } catch (_e) {
      result.ok = false;
      result.lat = 0;
    }
    try { tcp?.close(); } catch (_e2) { /* ignore */ }
    return result;
  }

  private async doTestConnection(): Promise<void> {
    if (this.formRelayServer.trim() === '') { this.formTestResult = '✗ 请先输入中继服务器地址'; return; }
    this.formTestResult = '⏳ 检测中...';
    const r = await this.tcpTest(this.formRelayServer.trim(), this.formRelayPort);
    if (r.ok) {
      this.formTestResult = '✓ TCP 连通 (' + r.lat + 'ms)';
      this._updateRelayHealth('online', r.lat);
    } else {
      if (this.formIdServer.trim() !== '') {
        const idR = await this.tcpTest(this.formIdServer.trim(), this.formIdPort);
        if (idR.ok) {
          this.formTestResult = '△ ID服务器可达 (' + idR.lat + 'ms), 中继端口不通';
          this._updateRelayHealth('error', 0);
        } else {
          this.formTestResult = '✗ 服务器不可达 (ID和中继均不通)';
          this._updateRelayHealth('offline', 0);
        }
      } else {
        this.formTestResult = '✗ 中继端口不可达';
        this._updateRelayHealth('offline', 0);
      }
    }
  }

  private _updateRelayHealth(status: string, latency: number): void {
    if (this.editingRelayId !== '') {
      const relay = this.relays.find((x: RustDeskRelayConfig) => x.id === this.editingRelayId);
      if (relay) {
        relay.healthStatus = status;
        relay.healthLatency = latency;
        relay.healthCheckedAt = Date.now();
        this.srv.updateRelay(relay);
        this.load();
      }
    }
  }

  private async doTestRelay(relay: RustDeskRelayConfig): Promise<void> {
    relay.healthStatus = 'unknown';
    this.srv.updateRelay(relay);
    this.load();
    const r1 = await this.tcpTest(relay.relayServer, relay.relayPort);
    if (r1.ok) {
      relay.healthStatus = 'online';
      relay.healthLatency = r1.lat;
    } else {
      const r2 = await this.tcpTest(relay.idServer, relay.idServerPort);
      if (r2.ok) {
        relay.healthStatus = 'error';
        relay.healthLatency = r2.lat;
      } else {
        relay.healthStatus = 'offline';
        relay.healthLatency = 0;
      }
    }
    relay.healthCheckedAt = Date.now();
    this.srv.updateRelay(relay);
    this.load();
  }

  private doDeleteRelay(id: string): void {
    promptAction.showDialog({
      title: '确认删除', message: '确定要删除此中继服务器及其所有账户吗？',
      buttons: [{ text: '取消', color: this.pal().text2 }, { text: '删除', color: this.pal().danger }]
    }).then((result: Object): void => {
      const r: Record<string, number> = result as Record<string, number>;
      if (r['index'] === 1) {
        animateTo({ duration: 280, curve: curves.interpolatingSpring(0, 0.82, 260, 22) }, () => {
          this.srv.removeRelay(id);
          this.expandedRelayIds = this.expandedRelayIds.filter((relayId: string): boolean => relayId !== id);
          this.relays = this.relays.filter((relay: RustDeskRelayConfig): boolean => relay.id !== id);
        });
      }
    });
  }

  // ==================== Account CRUD ====================

  private doSaveAccount(): void {
    if (this.formAcctUser.trim() === '') { promptAction.showToast({ message: '用户名不能为空', duration: 2000 }); return; }
    const relay = this.relays.find((x: RustDeskRelayConfig) => x.id === this.accountRelayId);
    if (!relay) { return; }
    const a = new RustDeskAccount();
    a.id = this.editingAccountId !== '' ? this.editingAccountId : RustDeskAccount.generateId();
    a.relayId = this.accountRelayId; a.username = this.formAcctUser.trim(); a.password = this.formAcctPwd.trim();
    if (this.editingAccountId !== '') {
      const idx = relay.accounts.findIndex((x: RustDeskAccount) => x.id === this.editingAccountId);
      if (idx >= 0) { relay.accounts[idx] = a; }
    } else { relay.accounts.push(a); }
    if (!this.isRelayExpanded(relay.id)) {
      const ids: string[] = this.expandedRelayIds.slice();
      ids.push(relay.id);
      this.expandedRelayIds = ids;
    }
    this.srv.updateRelay(relay); this.closeSheet();
  }

  private doDeleteAccount(accountId: string): void {
    promptAction.showDialog({
      title: '确认删除', message: '确定要删除此账户吗？',
      buttons: [{ text: '取消', color: this.pal().text2 }, { text: '删除', color: this.pal().danger }]
    }).then((result: Object): void => {
      const r: Record<string, number> = result as Record<string, number>;
      if (r['index'] === 1) {
        const relay = this.relays.find((x: RustDeskRelayConfig) =>
          x.accounts.some((a: RustDeskAccount) => a.id === accountId));
        if (relay) { relay.accounts = relay.accounts.filter((a: RustDeskAccount) => a.id !== accountId); this.srv.updateRelay(relay); }
        this.closeSheet();
      }
    });
  }

  // ==================== Layout helpers ====================

  private cardColumns(): number {
    if (this.breakpoint === 'xl') { return this.isDesktopDevice ? 1 : 3; }
    if (this.breakpoint === 'lg') { return 3; }
    if (this.breakpoint === 'md') { return 2; }
    return 1;
  }
  private cardGap(): number { return 10; }
  private gridColumnsTemplate(): string {
    const columns: number = this.cardColumns();
    if (columns >= 4) { return '1fr 1fr 1fr 1fr'; }
    if (columns === 3) { return '1fr 1fr 1fr'; }
    if (columns === 2) { return '1fr 1fr'; }
    return '1fr';
  }
  private contentSidePadding(): number {
    if (this.breakpoint === 'xl') { return 24; }
    if (this.breakpoint === 'lg') { return 22; }
    return 16;
  }

  private isPC(): boolean {
    return this.isDesktopDevice && this.breakpoint === 'xl';
  }

  // ==================== Build ====================

  build() {
    Stack() {
      if (this.isPC()) {
        // PC: fixed-height layout — left list + right detail each scroll independently
        Column() {
          Column().height(this.contentTopSpacer())
          if (this.relays.length > 0) {
            this.statsBar()
          }
          if (this.relays.length === 0) {
            Column() {
              this.emptyState()
            }.width('100%').layoutWeight(1).alignItems(HorizontalAlign.Start)
          } else {
            this.pcLayout()
          }
        }
        .width('100%').height('100%')
        .padding({ left: this.contentSidePadding(), right: this.contentSidePadding() })
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
      } else {
        // Mobile/tablet: scrollable content
        Scroll() {
          Column() {
            Column().height(this.contentTopSpacer())
            if (this.relays.length > 0) {
              this.statsBar()
            }
            if (this.relays.length === 0) {
              Column() {
                this.emptyState()
              }.width('100%').alignItems(HorizontalAlign.Start)
            } else {
              if (this.breakpoint === 'sm') {
                this.mobileList()
              } else {
                this.tabletGrid()
              }
            }
            Column().height(120)
          }.width('100%').padding({ left: this.contentSidePadding(), right: this.contentSidePadding() })
        }
        .width('100%').height('100%').align(Alignment.TopStart)
        .scrollBar(this.breakpoint === 'sm' ? BarState.Off : BarState.Auto).edgeEffect(EdgeEffect.Spring)
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
      }
    }
    .width('100%').height('100%')
    .overlay(this.TitleBarOverlay(), { align: Alignment.Top })
    .bindSheet($$this.showSheet, this.relaySheetBuilder(), {
      height: SheetSize.FIT_CONTENT,
      preferType: this.breakpoint === 'sm' ? SheetType.BOTTOM : SheetType.CENTER,
      dragBar: false,
      backgroundColor: Color.Transparent, blurStyle: BlurStyle.NONE, showClose: false,
      onDisappear: () => { this.closeSheet(); }
    })
  }

  // ==================== Stats Bar ====================

  @Builder statsBar() {
    Scroll() {
      Row() {
        this._statChip('中继', this.relays.length.toString(), this.pal().text)
        this._statChip('在线', this.onlineCount().toString(), this.pal().success)
        this._statChip('异常', this.errorCount().toString(), this.pal().danger)
        this._statChip('账户', this.totalAccountCount().toString(), this.pal().text)
        this._statChip('主机', this.totalHostCount().toString(), this.pal().text)
      }
    }
    .scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off)
    .width('100%').padding({ bottom: 14 }).align(Alignment.Start)
  }

  @Builder _statChip(label: string, value: string, color: string) {
    Row() {
      Text(label).fontSize(11).fontColor(this.pal().text3).fontFamily(this.font())
      Text(value).fontSize(11).fontWeight(FontWeight.Bold).fontColor(color).fontFamily(this.font()).margin({ left: 3 })
    }
    .padding({ left: 10, right: 10, top: 5, bottom: 5 })
    .borderRadius(10)
    .backgroundColor(this.pal().surface)
    .margin({ right: 8 })
  }

  // ==================== Empty State ====================

  @Builder emptyState() {
    Column() {
      SymbolGlyph($r('sys.symbol.cloud_fill'))
        .fontSize(48)
        .fontColor([this.pal().text3])
      Text('还没有 RustDesk 中继')
        .fontSize(17).fontWeight(FontWeight.Medium).fontColor(this.pal().text).fontFamily(this.font())
        .margin({ top: 16 })
      Text('点击底部 + 添加中继服务器')
        .fontSize(13).fontColor(this.pal().text3).fontFamily(this.font())
        .textAlign(TextAlign.Center).margin({ top: 6 })
        .lineHeight(20)
    }
    .width('100%').constraintSize({ minHeight: 420 })
    .justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
  }

  // ==================== Mobile List (swipeAction) ====================

  @Builder mobileList() {
    List() {
      ForEach(this.relays, (relay: RustDeskRelayConfig) => {
        ListItem() {
          this.relayCardContent(relay)
        }
        .swipeAction({
          start: {
            builder: () => { this.rightSwipeActions(relay) },
            actionAreaDistance: 100
          },
          end: {
            builder: () => { this.leftSwipeDelete(relay) },
            actionAreaDistance: 60
          },
          edgeEffect: SwipeEdgeEffect.Spring
        })
        .transition(
          TransitionEffect.asymmetric(
            TransitionEffect.translate({ y: 18 }).combine(TransitionEffect.OPACITY),
            TransitionEffect.translate({ x: -160, y: -8 })
              .combine(TransitionEffect.scale({ x: 0.82, y: 0.82 }))
              .combine(TransitionEffect.OPACITY)
          )
        )
      }, (relay: RustDeskRelayConfig): string => relay.id)
    }
    .width('100%')
    .listDirection(Axis.Vertical)
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
    .divider({ strokeWidth: this.cardGap(), color: Color.Transparent })
  }

  // Right swipe: test + edit (same pattern as KeyVaultPage editLockRow)
  @Builder rightSwipeActions(relay: RustDeskRelayConfig) {
    Row() {
      Button() {
        SymbolGlyph($r('sys.symbol.bolt_fill')).fontSize(17).fontColor([Color.White])
      }
      .width(48).height(48).borderRadius(12)
      .backgroundColor(this.accentColor)
      .onClick(() => { this.doTestRelay(relay); })

      Button() {
        SymbolGlyph($r('sys.symbol.square_and_pencil')).fontSize(17).fontColor([Color.White])
      }
      .width(48).height(48).borderRadius(12)
      .backgroundColor(this.pal().editColor)
      .margin({ left: 4 })
      .onClick(() => { this.openEditRelaySheet(relay); })
    }
    .height('100%').alignItems(VerticalAlign.Center)
    .borderRadius(14)
  }

  // Left swipe: delete — square 60×60 all breakpoints
  @Builder leftSwipeDelete(relay: RustDeskRelayConfig) {
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
    .onClick(() => { this.doDeleteRelay(relay.id); })
  }

  // ==================== Tablet Grid ====================

  @Builder tabletGrid() {
    Grid() {
      ForEach(this.relays, (relay: RustDeskRelayConfig) => {
        GridItem() {
          this.relayCardContent(relay)
        }
        .transition(
          TransitionEffect.asymmetric(
            TransitionEffect.translate({ y: 18 }).combine(TransitionEffect.OPACITY),
            TransitionEffect.translate({ x: -160, y: -8 })
              .combine(TransitionEffect.scale({ x: 0.82, y: 0.82 }))
              .combine(TransitionEffect.OPACITY)
          )
        )
      }, (relay: RustDeskRelayConfig): string => relay.id)
    }
    .columnsTemplate(this.gridColumnsTemplate())
    .columnsGap(this.cardGap())
    .rowsGap(this.cardGap())
    .width('100%')
    .align(Alignment.TopStart)
  }

  // ==================== PC Layout (左侧列表 + 右侧详情) ====================

  @Builder pcLayout() {
    Row() {
      // Left: relay list
      Column() {
        List() {
          ForEach(this.relays, (relay: RustDeskRelayConfig) => {
            ListItem() {
              this.pcListItem(relay)
            }
          }, (relay: RustDeskRelayConfig): string => relay.id)
        }
        .width('100%').layoutWeight(1)
        .scrollBar(BarState.Off).edgeEffect(EdgeEffect.Spring)
        .divider({ strokeWidth: 4, color: Color.Transparent })
      }
      .width(300).padding({ right: 12 })

      // Right: detail panel — card with explicit height constraint
      Column() {
        if (this.selectedPcRelay !== null) {
          ForEach([(this.selectedPcRelay as RustDeskRelayConfig).id], (id: string) => {
            Column() {
              this.pcDetailPanelContent()
            }
            .width('100%').height('100%')
            .borderRadius(20).backgroundColor(this.pal().card).backgroundBlurStyle(BlurStyle.Regular)
            .border({ width: 0.5, color: this.pal().cardBorder, style: BorderStyle.Solid })
            .shadow({ radius: 24, color: 'rgba(0,0,0,0.10)', offsetY: 8 })
            .transition(
              TransitionEffect.OPACITY.animation({ duration: 200, curve: Curve.EaseOut })
                .combine(TransitionEffect.scale({ x: 0.96, y: 0.96 })
                  .animation({ duration: 280, curve: Curve.FastOutSlowIn }))
            )
          }, (id: string): string => id)
        } else {
          Column() {
            SymbolGlyph($r('sys.symbol.cloud_fill')).fontSize(36).fontColor([this.pal().text3])
            Text('选择一个中继').fontSize(14).fontColor(this.pal().text2).fontFamily(this.font()).margin({ top: 8 })
            Text('查看详细信息').fontSize(12).fontColor(this.pal().text3).fontFamily(this.font()).margin({ top: 2 })
          }.width('100%').height('100%').justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
        }
      }.layoutWeight(1).height('100%')
    }.width('100%').layoutWeight(1).constraintSize({ minHeight: 420 })
  }

  @Builder pcListItem(relay: RustDeskRelayConfig) {
    Row() {
      SymbolGlyph($r('sys.symbol.cloud_fill'))
        .fontSize(22)
        .fontColor([this.relayStatusColor(relay)])
        .margin({ right: 10 })
      Column() {
        Text(relay.displayName())
          .fontSize(15).fontWeight(FontWeight.Medium).fontColor(this.pal().text).fontFamily(this.font())
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        Row() {
          Column().width(6).height(6).borderRadius(3).backgroundColor(this.relayStatusColor(relay))
          Text(this.relayStatusLabel(relay)).fontSize(12).fontColor(this.relayStatusColor(relay)).margin({ left: 4 })
          Text(' · ' + this.hostCountForRelay(relay.id) + '台').fontSize(11).fontColor(this.pal().text3)
          Text(' · ' + relay.accounts.length + '账户').fontSize(11).fontColor(this.pal().text3)
        }.margin({ top: 2 })
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      // ⋯ menu
      Button() {
        Text('⋯').fontSize(20).fontColor(this.pal().text)
      }
      .width(40).height(40).borderRadius(20)
      .backgroundColor(this.pal().surface)
      .bindPopup(this.menuVisibleRelayId === relay.id, {
        builder: this.pcMenuBuilder(relay),
        placement: Placement.BottomRight,
        enableArrow: true,
        popupColor: this.pal().card,
        onStateChange: (e: Object) => {
          const ev: Record<string, boolean> = e as Record<string, boolean>;
          if (!ev['isVisible']) { this.menuVisibleRelayId = ''; }
        }
      })
      .onClick(() => {
        animateTo({ duration: 200, curve: Curve.FastOutSlowIn }, () => {
          this.menuVisibleRelayId = (this.menuVisibleRelayId === relay.id) ? '' : relay.id;
        });
      })
    }
    .width('100%').padding({ left: 12, right: 12, top: 10, bottom: 10 })
    .borderRadius(10)
    .backgroundColor(this.selectedPcRelay !== null && (this.selectedPcRelay as RustDeskRelayConfig).id === relay.id ? this.pal().surface : Color.Transparent)
    .onClick(() => {
      this.selectedPcRelay = relay;
    })
  }

  @Builder pcMenuBuilder(relay: RustDeskRelayConfig) {
    Column() {
      Button() {
        Row() {
          SymbolGlyph($r('sys.symbol.bolt_fill')).fontSize(16).fontColor([this.pal().text])
          Text('测试连接').fontSize(13).fontColor(this.pal().text).margin({ left: 8 })
        }.width('100%')
      }
      .width('100%').height(42).backgroundColor(Color.Transparent)
      .borderRadius(8).padding({ left: 8, right: 8 })
      .onClick(() => { this.menuVisibleRelayId = ''; this.doTestRelay(relay); })

      Divider().strokeWidth(0.5).color(this.pal().cardBorder).width('100%')

      Button() {
        Row() {
          SymbolGlyph($r('sys.symbol.square_and_pencil')).fontSize(16).fontColor([this.pal().text])
          Text('编辑').fontSize(13).fontColor(this.pal().text).margin({ left: 8 })
        }.width('100%')
      }
      .width('100%').height(42).backgroundColor(Color.Transparent)
      .borderRadius(8).padding({ left: 8, right: 8 })
      .onClick(() => { this.menuVisibleRelayId = ''; this.openEditRelaySheet(relay); })

      Divider().strokeWidth(0.5).color(this.pal().cardBorder).width('100%')

      Button() {
        Row() {
          SymbolGlyph($r('sys.symbol.ohos_trash')).fontSize(16).fontColor([this.pal().danger])
          Text('删除').fontSize(13).fontColor(this.pal().danger).margin({ left: 8 })
        }.width('100%')
      }
      .width('100%').height(42).backgroundColor(Color.Transparent)
      .borderRadius(8).padding({ left: 8, right: 8 })
      .onClick(() => { this.menuVisibleRelayId = ''; this.doDeleteRelay(relay.id); })
    }
    .width(156).padding(4).borderRadius(12)
  }

  // PC detail panel — horizontal landscape layout with two columns (no scroll)
  @Builder pcDetailPanelContent() {
    Column() {
        if (this.selectedPcRelay !== null) {
          // ===== Header bar: name + status + actions =====
          Row() {
            Column() {
              Text((this.selectedPcRelay as RustDeskRelayConfig).displayName())
                .fontSize(28).fontWeight(FontWeight.Bold).fontColor(this.pal().text).fontFamily(this.font())
              Row() {
                Column().width(8).height(8).borderRadius(4)
                  .backgroundColor(this.relayStatusColor(this.selectedPcRelay as RustDeskRelayConfig))
                Text(this.relayStatusLabel(this.selectedPcRelay as RustDeskRelayConfig))
                  .fontSize(14).fontColor(this.relayStatusColor(this.selectedPcRelay as RustDeskRelayConfig))
                  .fontFamily(this.font()).margin({ left: 5 })
                if ((this.selectedPcRelay as RustDeskRelayConfig).healthCheckedAt > 0) {
                  Text(' · ' + this.relayCheckedAtLabel(this.selectedPcRelay as RustDeskRelayConfig))
                    .fontSize(13).fontColor(this.pal().text3).fontFamily(this.font())
                }
              }.margin({ top: 4 })
            }.alignItems(HorizontalAlign.Start).layoutWeight(1)
            Row() {
              Button('测试连接').fontSize(14).height(36)
                .backgroundColor(this.accentColor).fontColor('#FFFFFF').borderRadius(8)
                .padding({ left: 16, right: 16 }).fontWeight(FontWeight.Medium)
                .onClick(() => { this.doTestRelay(this.selectedPcRelay as RustDeskRelayConfig); })
              Button('编辑').fontSize(14).height(36)
                .backgroundColor(this.pal().surface).fontColor(this.pal().text2).borderRadius(8)
                .margin({ left: 8 }).padding({ left: 16, right: 16 })
                .onClick(() => { this.openEditRelaySheet(this.selectedPcRelay as RustDeskRelayConfig); })
            }
          }.width('100%').padding({ bottom: 16 })
          .border({ width: { bottom: 0.5 }, color: this.pal().divider }).margin({ bottom: 16 })

          // ===== Two-column body =====
          Row() {
            // Left column: 服务器 + 健康诊断
            Column() {
              // 服务器信息
              Text('服务器').fontSize(13).fontColor(this.pal().text3).fontFamily(this.font())
                .fontWeight(FontWeight.Medium).margin({ bottom: 8 }).width('100%')
              Column() {
                this._pcEndpointRow('ID', (this.selectedPcRelay as RustDeskRelayConfig).idServer,
                  (this.selectedPcRelay as RustDeskRelayConfig).idServerPort)
                Row().width('100%').height(0.5).backgroundColor(this.pal().divider).margin({ top: 5, bottom: 5 })
                this._pcEndpointRow('Relay', (this.selectedPcRelay as RustDeskRelayConfig).relayServer,
                  (this.selectedPcRelay as RustDeskRelayConfig).relayPort)
                if ((this.selectedPcRelay as RustDeskRelayConfig).apiServer !== '') {
                  Row().width('100%').height(0.5).backgroundColor(this.pal().divider).margin({ top: 5, bottom: 5 })
                  this._pcEndpointRow('API', (this.selectedPcRelay as RustDeskRelayConfig).apiServer, 0)
                }
                Row().width('100%').height(0.5).backgroundColor(this.pal().divider).margin({ top: 5, bottom: 5 })
                Row() {
                  Text('密钥').fontSize(14).fontColor(this.pal().text3).fontFamily(this.font()).width(48)
                  Text((this.selectedPcRelay as RustDeskRelayConfig).key !== '' ? '已配置' : '默认 (官方)')
                    .fontSize(14).fontColor((this.selectedPcRelay as RustDeskRelayConfig).key !== '' ? this.pal().success : this.pal().text3)
                    .fontFamily(this.font())
                  Blank()
                }.width('100%').padding({ top: 4, bottom: 4 })
              }
              .width('100%').borderRadius(10).backgroundColor(this.pal().surface).padding(14).margin({ bottom: 14 })

              // 健康诊断
              Text('健康诊断').fontSize(13).fontColor(this.pal().text3).fontFamily(this.font())
                .fontWeight(FontWeight.Medium).margin({ bottom: 8 }).width('100%')
              this._pcHealthCard('ID TCP',
                (this.selectedPcRelay as RustDeskRelayConfig).idServer + ':' + (this.selectedPcRelay as RustDeskRelayConfig).idServerPort,
                (this.selectedPcRelay as RustDeskRelayConfig).healthStatus)
              Blank().height(8)
              this._pcHealthCard('Relay TCP',
                (this.selectedPcRelay as RustDeskRelayConfig).relayServer + ':' + (this.selectedPcRelay as RustDeskRelayConfig).relayPort,
                (this.selectedPcRelay as RustDeskRelayConfig).healthStatus)
              if ((this.selectedPcRelay as RustDeskRelayConfig).apiServer !== '') {
                Blank().height(8)
                this._pcHealthCard('API', (this.selectedPcRelay as RustDeskRelayConfig).apiServer, 'unknown')
              }
            }.width('50%').padding({ right: 10 }).alignItems(HorizontalAlign.Start)

            // Right column: 账户 + 绑定主机 — top-aligned
            Column() {
              // 账户标题
              Row() {
                Text('账户 (' + (this.selectedPcRelay as RustDeskRelayConfig).accounts.length + ')')
                  .fontSize(13).fontColor(this.pal().text3).fontFamily(this.font()).fontWeight(FontWeight.Medium)
                Blank()
                Text('+ 添加').fontSize(14).fontColor(this.accentColor).fontFamily(this.font())
                  .onClick(() => { this.openAccountSheet(this.selectedPcRelay as RustDeskRelayConfig); })
              }.width('100%').margin({ bottom: 8 })
              // 账户列表
              Column() {
                if ((this.selectedPcRelay as RustDeskRelayConfig).accounts.length === 0) {
                  Text('暂无账户').fontSize(13).fontColor(this.pal().text3).fontFamily(this.font())
                    .width('100%').textAlign(TextAlign.Center).padding({ top: 10, bottom: 10 })
                }
                ForEach((this.selectedPcRelay as RustDeskRelayConfig).accounts, (acct: RustDeskAccount) => {
                  Row() {
                    SymbolGlyph($r('sys.symbol.key_fill'))
                      .fontSize(16).fontColor([this.accountStatusColor(acct)])
                    Column() {
                      Text(acct.displayName()).fontSize(14).fontColor(this.pal().text).fontFamily(this.font())
                      Text(this.accountStatusLabel(acct) + ' · ' +
                        this.hostCountForAccount((this.selectedPcRelay as RustDeskRelayConfig).id, acct.id) + '台主机')
                        .fontSize(11).fontColor(this.pal().text3).fontFamily(this.font())
                    }.alignItems(HorizontalAlign.Start).layoutWeight(1).margin({ left: 8 })
                    Text('编辑').fontSize(12).fontColor(this.accentColor).fontFamily(this.font())
                      .onClick(() => { this.openAccountSheet(this.selectedPcRelay as RustDeskRelayConfig, acct); })
                  }.width('100%').padding({ left: 10, right: 10, top: 7, bottom: 7 })
                  .borderRadius(8).backgroundColor(this.pal().card)
                  .margin({ bottom: 3 })
                })
              }
              .width('100%').borderRadius(10).backgroundColor(this.pal().surface).padding(10).margin({ bottom: 14 })

              // 绑定主机
              Text('绑定主机').fontSize(13).fontColor(this.pal().text3).fontFamily(this.font())
                .fontWeight(FontWeight.Medium).margin({ bottom: 8 }).width('100%')
              Column() {
                Row() {
                  SymbolGlyph($r('sys.symbol.desktop_fill')).fontSize(18).fontColor([this.pal().text3])
                  Text((this.hostCountForRelay((this.selectedPcRelay as RustDeskRelayConfig).id)) + ' 台主机已绑定')
                    .fontSize(15).fontColor(this.pal().text).fontFamily(this.font()).margin({ left: 8 })
                  Blank()
                  Text('查看 →').fontSize(13).fontColor(this.accentColor).fontFamily(this.font())
                }.width('100%').padding({ left: 10, right: 10, top: 8, bottom: 8 })
              }
              .width('100%').borderRadius(10).backgroundColor(this.pal().surface).padding(10)

              Blank().layoutWeight(1)
            }.width('50%').padding({ left: 10 })
          }.width('100%').alignItems(VerticalAlign.Top)

          Blank().height(32)
        }
      }.width('100%').padding({ left: 24, right: 24, top: 20, bottom: 20 })
  }

  @Builder _pcEndpointRow(label: string, host: string, port: number) {
    Row() {
      Text(label).fontSize(14).fontColor(this.pal().text3).fontFamily(this.font()).width(48)
      Text(host).fontSize(14).fontColor(this.pal().text).fontFamily(this.font())
        .textOverflow({ overflow: TextOverflow.Ellipsis }).maxLines(1).layoutWeight(1)
      if (port > 0) {
        Text(':' + port.toString()).fontSize(13).fontColor(this.pal().text3).fontFamily(this.font())
          .margin({ left: 4 })
      }
    }.width('100%').padding({ top: 3, bottom: 3 })
  }

  @Builder _pcHealthCard(label: string, endpoint: string, status: string) {
    Column() {
      Row() {
        Text(label).fontSize(13).fontColor(this.pal().text3).fontFamily(this.font())
        Blank()
        if (status === 'online') {
          SymbolGlyph($r('sys.symbol.checkmark')).fontSize(16).fontColor([this.pal().success])
        } else if (status === 'offline' || status === 'error') {
          SymbolGlyph($r('sys.symbol.xmark')).fontSize(16).fontColor([this.pal().danger])
        } else {
          Text('未检测').fontSize(12).fontColor(this.pal().text3).fontFamily(this.font())
        }
      }.width('100%')
      Text(endpoint).fontSize(13).fontColor(this.pal().text2).fontFamily(this.font())
        .textOverflow({ overflow: TextOverflow.Ellipsis }).maxLines(1).margin({ top: 4 })
    }
    .width('100%').padding(12).borderRadius(10).backgroundColor(this.pal().surface)
  }

  // ==================== Relay Card Content (shared by mobile & tablet) ====================

  @Builder relayCardContent(relay: RustDeskRelayConfig) {
    Column() {
      // Card header
      Row() {
        SymbolGlyph($r('sys.symbol.cloud_fill'))
          .fontSize(this.breakpoint === 'sm' ? 22 : 24)
          .fontColor([this.accentColor])
        Column() {
          Text(relay.displayName())
            .fontSize(this.breakpoint === 'sm' ? 15 : 17).fontWeight(FontWeight.Medium)
            .fontColor(this.pal().text).fontFamily(this.font())
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          Row() {
            Column().width(this.breakpoint === 'sm' ? 6 : 7)
              .height(this.breakpoint === 'sm' ? 6 : 7)
              .borderRadius(this.breakpoint === 'sm' ? 3 : 4)
              .backgroundColor(this.relayStatusColor(relay))
            Text(this.relayStatusLabel(relay))
              .fontSize(this.breakpoint === 'sm' ? 11 : 13)
              .fontColor(this.relayStatusColor(relay)).fontFamily(this.font())
              .margin({ left: this.breakpoint === 'sm' ? 4 : 5 })
            Text(' · ' + this.hostCountForRelay(relay.id) + '台')
              .fontSize(this.breakpoint === 'sm' ? 11 : 12)
              .fontColor(this.pal().text3).fontFamily(this.font())
            Text(' · ' + relay.accounts.length + '账户')
              .fontSize(this.breakpoint === 'sm' ? 11 : 12)
              .fontColor(this.pal().text3).fontFamily(this.font())
          }.margin({ top: this.breakpoint === 'sm' ? 2 : 3 })
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        .margin({ left: this.breakpoint === 'sm' ? 10 : 12 })

        // Right-side controls: [▸ chevron] [⋯ menu]
        // sm: chevron only | md/lg/xl: chevron + ⋯ | PC: ⋯ only
        // All vertically centered in card, chevron between text and ⋯ button
        Row() {
          if (!this.isPC()) {
            SymbolGlyph($r('sys.symbol.chevron_right'))
              .fontSize(14)
              .fontColor([this.pal().text3])
              .rotate({ angle: this.isRelayExpanded(relay.id) ? 90 : 0 })
              .animation({ duration: 250, curve: Curve.FastOutSlowIn })
              .margin({ right: this.breakpoint !== 'sm' ? 10 : 0 })
          }
          if (this.breakpoint !== 'sm') {
            Button() {
              Text('⋯').fontSize(18).fontColor(this.pal().text)
            }
            .width(32).height(32).borderRadius(16)
            .backgroundColor(this.pal().surface)
            .bindPopup(this.menuVisibleRelayId === relay.id, {
              builder: this.pcMenuBuilder(relay),
              placement: Placement.BottomRight,
              enableArrow: true,
              popupColor: this.pal().card,
              onStateChange: (e: Object) => {
                const ev: Record<string, boolean> = e as Record<string, boolean>;
                if (!ev['isVisible']) { this.menuVisibleRelayId = ''; }
              }
            })
            .onClick(() => {
              animateTo({ duration: 200, curve: Curve.FastOutSlowIn }, () => {
                this.menuVisibleRelayId = (this.menuVisibleRelayId === relay.id) ? '' : relay.id;
              });
            })
          }
        }.alignItems(VerticalAlign.Center).margin({ right: 6 })
      }
      .width('100%')
      .onClick(() => { this.toggleRelayExpanded(relay.id); })

      // Expanded: server info
      if (this.isRelayExpanded(relay.id)) {
        Column() {
          // Server endpoints
          Column() {
            this._cardInfoRow('ID', relay.idServer + ':' + relay.idServerPort)
            this._cardInfoRow('Relay', relay.relayServer + ':' + relay.relayPort)
            if (relay.apiServer !== '') {
              this._cardInfoRow('API', relay.apiServer)
            }
          }
          .width('100%').borderRadius(10).backgroundColor(this.pal().surface)
          .padding({ left: 10, right: 10, top: 6, bottom: 6 }).margin({ top: 8 })

          // Account section
          Row() {
            Text('账户 (' + relay.accounts.length + ')')
              .fontSize(11).fontColor(this.pal().text3).fontFamily(this.font())
            Blank()
            Text('+ 添加').fontSize(11).fontColor(this.accentColor).fontFamily(this.font())
              .onClick(() => { this.openAccountSheet(relay); })
          }.width('100%').margin({ top: 8, bottom: 4 })

          if (relay.accounts.length === 0) {
            Text('暂无账户，点击添加')
              .fontSize(11).fontColor(this.pal().text3).fontFamily(this.font())
              .width('100%').textAlign(TextAlign.Center)
              .padding({ top: 8, bottom: 8 })
              .borderRadius(10).backgroundColor(this.pal().surface)
          }

          ForEach(relay.accounts, (acct: RustDeskAccount) => {
            Row() {
              SymbolGlyph($r('sys.symbol.key_fill'))
                .fontSize(this.breakpoint === 'sm' ? 15 : 18)
                .fontColor([this.accountStatusColor(acct)])
              Column() {
                Text(acct.displayName()).fontSize(this.breakpoint === 'sm' ? 13 : 15)
                  .fontColor(this.pal().text).fontFamily(this.font())
                Text(this.accountStatusLabel(acct) + ' · ' + this.hostCountForAccount(relay.id, acct.id) + '台主机')
                  .fontSize(this.breakpoint === 'sm' ? 10 : 11)
                  .fontColor(this.pal().text3).fontFamily(this.font())
              }.alignItems(HorizontalAlign.Start).layoutWeight(1)
              .margin({ left: this.breakpoint === 'sm' ? 8 : 10 })
              SymbolGlyph($r('sys.symbol.chevron_right'))
                .fontSize(this.breakpoint === 'sm' ? 14 : 16).fontColor([this.pal().text3])
            }
            .width('100%')
            .constraintSize({ minHeight: this.breakpoint === 'sm' ? 52 : 68 })
            .padding(this.breakpoint === 'sm' ? { left: 10, right: 10, top: 7, bottom: 7 } : 12)
            .borderRadius(10).backgroundColor(this.pal().surface)
            .margin({ bottom: 3 })
            .onClick(() => { this.openAccountSheet(relay, acct); })
          })
        }
        .transition(
          TransitionEffect.OPACITY
            .animation({ duration: 250, curve: Curve.FastOutSlowIn })
            .combine(
              TransitionEffect.translate({ y: -8 })
                .animation({ duration: 280, curve: curves.interpolatingSpring(0, 0.82, 260, 22) })
            )
        )
      }
    }
    .width('100%')
    .constraintSize({ minHeight: this.breakpoint === 'sm' ? 66 : 80 })
    .padding(this.breakpoint === 'sm' ? 12 : 14)
    .borderRadius(14)
    .backgroundColor(this.pal().card)
    .backgroundBlurStyle(BlurStyle.Regular)
    .border({ width: 0.5, color: this.pal().cardBorder, style: BorderStyle.Solid })
  }

  @Builder _cardInfoRow(label: string, value: string) {
    Row() {
      Text(label).fontSize(11).fontColor(this.pal().text3).fontFamily(this.font()).width(32)
      Text(value).fontSize(12).fontColor(this.pal().text2).fontFamily(this.font())
        .textOverflow({ overflow: TextOverflow.Ellipsis }).maxLines(1).layoutWeight(1)
    }.width('100%').padding({ top: 2, bottom: 2 })
  }

  // ==================== Title Bar ====================

  @Builder TitleBarOverlay() {
    Stack() {
      Column() {
        Row().width('100%').height(this.topSafeH() + this.titleOffsetY())
        Row() {
          Text('RustDesk 中继').fontSize(27).fontWeight(FontWeight.Bold)
            .fontColor(this.pal().text).fontFamily(this.font())
          Blank()
        }.width('100%').padding({ left: 24, right: 24, bottom: 8 })
      }.width('100%').backgroundColor(Color.Transparent)
    }.width('100%').height(this.titleBarH()).hitTestBehavior(HitTestMode.Transparent)
  }

  // ==================== Sheets (unchanged from original) ====================

  @Builder relayEditSheet() {
    Column() {
      Text(this.editingRelayId === '' ? '添加中继服务器' : '编辑中继服务器')
        .fontSize(19).fontWeight(FontWeight.Bold).fontColor(this.pal().text).fontFamily(this.font())
        .width('100%').margin({ bottom: 16 })
      Scroll() {
        Column() {
          this._f('ID服务器地址', 'rs.example.com', this.formIdServer, (v: string) => { this.formIdServer = v; })
          this._f('ID服务器端口', '21116', this.formIdPort.toString(), (v: string) => { const n = parseInt(v); this.formIdPort = isNaN(n) ? 21116 : n; })
          this._f('中继服务器地址', 'relay.example.com', this.formRelayServer, (v: string) => { this.formRelayServer = v; })
          this._f('中继端口', '21117', this.formRelayPort.toString(), (v: string) => { const n = parseInt(v); this.formRelayPort = isNaN(n) ? 21117 : n; })
          this._f('API服务器(可选)', '', this.formApiServer, (v: string) => { this.formApiServer = v; })
          this._f('密钥(可选)', '', this.formKey, (v: string) => { this.formKey = v; })
          if (this.formTestResult !== '') {
            Text(this.formTestResult).fontSize(12).fontColor(this.formTestResult.startsWith('✓') ? this.accentColor : this.pal().danger).margin({ top: 4 })
          }
          Row() {
            Button('测试连接').width('48%').height(36).fontSize(13).backgroundColor(this.pal().surface).fontColor(this.accentColor).borderRadius(8)
              .onClick(() => { this.doTestConnection(); })
            Button('保存').width('48%').height(36).fontSize(13).fontWeight(FontWeight.Medium)
              .backgroundColor(this.accentColor).fontColor('#FFFFFF').borderRadius(8).margin({ left: 12 })
              .onClick(() => { this.doSaveRelay(); })
          }.width('100%').margin({ top: 12 })
        }.width('100%')
      }.constraintSize({ maxHeight: 380 }).scrollBar(BarState.Auto).edgeEffect(EdgeEffect.Spring)
      Blank().height(24)
    }.width('100%')
    .padding({ left: 24, right: 24, top: 24, bottom: 40 })
    .borderRadius(this.breakpoint === 'sm' ? 0 : 20)
    .backgroundColor(this.pal().bg)
    .backgroundBlurStyle(BlurStyle.Regular)
    .shadow(this.breakpoint === 'sm'
      ? { radius: 0, color: 'rgba(0,0,0,0)', offsetY: 0 } as ShadowOptions
      : { radius: 24, color: 'rgba(0,0,0,0.12)', offsetY: 6 } as ShadowOptions)
    .border(this.breakpoint === 'sm'
      ? { width: 0, color: Color.Transparent, style: BorderStyle.Solid }
      : { width: 0.5, color: this.pal().cardBorder, style: BorderStyle.Solid })
  }

  @Builder accountEditSheet() {
    Column() {
      Text(this.editingAccountId === '' ? '添加账户' : '编辑账户')
        .fontSize(19).fontWeight(FontWeight.Bold).fontColor(this.pal().text).fontFamily(this.font())
        .width('100%').margin({ bottom: 16 })
      this._f('用户名', 'admin', this.formAcctUser, (v: string) => { this.formAcctUser = v; })
      this._f('密码', '', this.formAcctPwd, (v: string) => { this.formAcctPwd = v; })
      Row() {
        Button('保存').width('100%').height(40).fontSize(14).fontWeight(FontWeight.Medium)
          .backgroundColor(this.accentColor).fontColor('#FFFFFF').borderRadius(10).margin({ top: 12 })
          .onClick(() => { this.doSaveAccount(); })
      }.width('100%')
      if (this.editingAccountId !== '') {
        Row() {
          Button('删除账户').width('100%').height(40).fontSize(14)
            .backgroundColor(Color.Transparent).fontColor(this.pal().danger).borderRadius(10).margin({ top: 8 })
            .onClick(() => { this.doDeleteAccount(this.editingAccountId); })
        }.width('100%')
      }
      Blank().height(24)
    }.width('100%')
    .padding({ left: 24, right: 24, top: 24, bottom: 40 })
    .borderRadius(this.breakpoint === 'sm' ? 0 : 20)
    .backgroundColor(this.pal().bg)
    .backgroundBlurStyle(BlurStyle.Regular)
    .shadow(this.breakpoint === 'sm'
      ? { radius: 0, color: 'rgba(0,0,0,0)', offsetY: 0 } as ShadowOptions
      : { radius: 24, color: 'rgba(0,0,0,0.12)', offsetY: 6 } as ShadowOptions)
    .border(this.breakpoint === 'sm'
      ? { width: 0, color: Color.Transparent, style: BorderStyle.Solid }
      : { width: 0.5, color: this.pal().cardBorder, style: BorderStyle.Solid })
  }

  @Builder relaySheetBuilder() {
    if (this.sheetContent === 1) {
      this.relayEditSheet()
    } else if (this.sheetContent === 2) {
      this.accountEditSheet()
    }
  }

  @Builder _f(l: string, h: string, v: string, cb: (v: string) => void) {
    Column() {
      Text(l).fontSize(11).fontColor(this.pal().text2).margin({ bottom: 4 }).fontFamily(this.font())
      TextInput({ placeholder: h, text: v }).height(38).backgroundColor(this.pal().surface).borderRadius(8)
        .fontColor(this.pal().text).placeholderColor(this.pal().text3).fontFamily(this.font()).fontSize(13)
        .padding({ left: 10, right: 10 }).onChange(cb)
    }.width('100%').margin({ bottom: 10 })
  }
}
