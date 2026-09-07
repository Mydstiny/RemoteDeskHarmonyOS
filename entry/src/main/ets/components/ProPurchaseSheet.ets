import { DEBUG } from 'BuildProfile';
import { AppSheetHeader } from './AppSheetHeader';
import { ProAppIconPanel } from './ProAppIconPanel';
import { ProAppRuntime } from '../services/pro/ProAppRuntime';
import { ProDebugMode } from '../services/pro/ProRuntime';
import { ProPurchaseLifecycle } from '../services/pro/ProPurchaseLifecycle';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Palette, buildDark, buildLight } from '../common/Theme';
import { ProFeature, proFeatures } from '../services/pro/ProFeatureCatalog';
import {
  HuaweiProBillingProvider, ProStoreProduct, ProPurchaseCoordinator,
  PRO_LAUNCH_PRICE, PRO_REGULAR_PRICE, proBillingError
} from '../services/pro/ProBillingService';

@Component
export struct ProPurchaseSheet {
  @StorageProp('currentTheme') theme: string = 'light';
  @StorageProp('accentColor') accent: string = '#007DFF';
  @State entered: boolean = false;
  @State busy: boolean = false;
  @State testing: boolean = false;
  @State proLabel: string = '免费版';
  @State debugMode: ProDebugMode = 'real';
  private unsubscribe: (() => void) | null = null;
  @State productId: string = 'RemoteDesktop_Pro_Test';
  @State storePrice: string = '';
  @State storeName: string = '';
  @State message: string = 'Pro 正在准备中，当前版本的功能继续免费使用。';
  private provider: HuaweiProBillingProvider = new HuaweiProBillingProvider();
  private product: ProStoreProduct | null = null;
  private generation: number = 0;
  private live: boolean = false;
  onClose: () => void = (): void => {};

  aboutToAppear(): void {
    this.live = true;
    this.unsubscribe = ProAppRuntime.getInstance().runtime.subscribe((): void => {
      const snapshot = ProAppRuntime.getInstance().runtime.snapshot();
      this.proLabel = snapshot.label;
      this.debugMode = snapshot.mode;
    });
  }
  aboutToDisappear(): void { this.live = false; this.generation++; this.unsubscribe?.(); this.unsubscribe = null; }
  private pal(): Palette { return this.theme === 'light' ? buildLight(this.accent) : buildDark(this.accent); }
  private context(): common.UIAbilityContext { return getContext(this) as common.UIAbilityContext; }

  private async operate(action: string): Promise<void> {
    if (!DEBUG) { return; }
    if (this.busy) { return; }
    if (!ProPurchaseCoordinator.enter()) { this.message = '上一项操作仍在处理中，请稍后再试。'; return; }
    const generation: number = ++this.generation;
    const epoch: number = ProPurchaseLifecycle.capture();
    this.busy = true;
    try {
      if (action === 'load') {
        this.product = null;
        this.storePrice = '';
        const product = await this.provider.product(this.context(), this.productId.trim());
        if (!this.live || generation !== this.generation || !ProPurchaseLifecycle.current(epoch)) { return; }
        this.product = product;
        this.storePrice = product.price;
        this.storeName = product.name;
        this.message = '沙盒已确认。购买仅验证支付链路，不授予正式 Pro 权益。';
      } else if (action === 'buy' && this.product !== null && this.testing) {
        await this.provider.purchase(this.context(), this.product.id, (): boolean =>
          this.live && generation === this.generation && ProPurchaseLifecycle.current(epoch));
        if (!this.live || generation !== this.generation || !ProPurchaseLifecycle.current(epoch)) { return; }
        this.message = '已收到购买回调。订单验签与发货尚未接入，权益未开通；可查询待处理订单。';
        this.product = null;
        this.storePrice = '';
      } else if (action === 'restore') {
        const count = await this.provider.restore(this.context());
        if (!this.live || generation !== this.generation || !ProPurchaseLifecycle.current(epoch)) { return; }
        this.message = count > 0 ? '已查询到购买记录。验签服务尚未接入，本次未恢复正式权益。' :
          '当前查询未返回购买记录；沙盒记录行为不等同于正式购买恢复。';
      }
    } catch (error) {
      if (this.live && generation === this.generation) {
        this.message = proBillingError(error as BusinessError);
        this.product = null;
        this.storePrice = '';
      }
    } finally {
      ProPurchaseCoordinator.leave();
      if (this.live && generation === this.generation) { this.busy = false; }
    }
  }

  @Builder private featureCard(feature: ProFeature, index: number) {
    Row({ space: 14 }) {
      Text((index + 1).toString().padStart(2, '0'))
        .fontSize(16).fontWeight(FontWeight.Bold).fontColor(this.accent)
        .width(44).height(44).textAlign(TextAlign.Center)
        .backgroundColor(this.pal().surface).borderRadius(14)
      Column({ space: 6 }) {
        Row({ space: 8 }) {
          Text(feature.title).fontSize(16).fontWeight(FontWeight.Medium).fontColor(this.pal().text)
          Text(feature.availability === 'planned' ? '规划中' : 'Pro').fontSize(10).fontColor(this.pal().text2)
            .padding({ left: 7, right: 7, top: 3, bottom: 3 }).backgroundColor(this.pal().surface).borderRadius(6)
        }.width('100%')
        Text(feature.description).fontSize(13).fontColor(this.pal().text2).lineHeight(20).width('100%')
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
    }.width('100%').padding(16).backgroundColor(this.pal().card).borderRadius(20)
    .border({ width: 0.5, color: this.pal().cardBorder })
  }

  build() {
    Column() {
      AppSheetHeader({ title: 'RemoteDesk Pro', closeLabel: '完成',
        onClose: (): void => {
          this.live = false; this.generation++; ProPurchaseLifecycle.dismiss(); this.onClose();
        }
      })
      Scroll() {
        Column({ space: 14 }) {
          Column({ space: 12 }) {
            Text('PRO').fontSize(14).fontWeight(FontWeight.Bold).fontColor(Color.White)
              .letterSpacing(4).padding({ left: 18, right: 18, top: 8, bottom: 8 })
              .backgroundColor(this.accent).borderRadius(12)
            Text('让每次连接\n更得心应手').fontSize(30).fontWeight(FontWeight.Bold)
              .fontColor(this.pal().text).textAlign(TextAlign.Center).lineHeight(39)
            Text('全部协议免费连接，专业工具提升效率。')
              .fontSize(14).fontColor(this.pal().text2).textAlign(TextAlign.Center)
            Text(this.proLabel).fontSize(13).fontColor(this.accent)
            Text('一次购买 · 不自动续费').fontSize(12).fontColor(this.accent)
          }.width('100%').padding({ top: 16, bottom: 18 })
          ProAppIconPanel()
          ForEach(proFeatures().filter((item: ProFeature): boolean => item.requiredEntitlementId.length > 0),
            (feature: ProFeature, index: number): void => { this.featureCard(feature, index) },
            (feature: ProFeature): string => feature.id)
          Text('核心功能一直免费').fontSize(15).fontWeight(FontWeight.Medium).fontColor(this.pal().text)
            .width('100%').margin({ top: 8 })
          Text('协议连接、正常画质、键鼠操作、基础文件传输和安全更新保持免费。标注“规划中”的能力尚未交付，Pro 正式购买仍在准备中。')
            .fontSize(13).fontColor(this.pal().text2).lineHeight(21).width('100%')
          if (DEBUG) {
            Column({ space: 8 }) {
              Text('开发者调试 · 权益模拟').fontSize(14).fontColor(this.pal().text)
              ForEach(['real', 'free', 'pro'], (mode: string): void => {
                Button((this.debugMode === mode ? '✓ ' : '') +
                  (mode === 'real' ? '跟随真实权益' : mode === 'free' ? '模拟免费用户' : '模拟 Pro 用户'))
                  .fontSize(13).fontColor(this.accent).backgroundColor(this.pal().surface)
                  .enabled(!this.busy).onClick((): void => {
                    ProAppRuntime.getInstance().runtime.setDebugMode(mode as ProDebugMode);
                  })
              })
              Text('仅当前运行有效，重启恢复真实权益。模拟不购买、不退款，也不解锁规划中的功能。')
                .fontSize(12).fontColor(this.pal().text2).lineHeight(19)
            }.width('100%').padding(16).backgroundColor(this.pal().card).borderRadius(16)
          Button(this.testing ? '收起沙盒测试' : '开发者沙盒测试')
            .fontSize(12).fontColor(this.pal().text2).backgroundColor(Color.Transparent)
            .enabled(!this.busy).onClick((): void => {
              this.testing = !this.testing;
              this.product = null; this.storePrice = ''; this.storeName = '';
            })
          if (this.testing) {
            Column({ space: 10 }) {
              Text('仅测试购买链路，不会开通正式权益。请使用 AGC 非消耗型测试商品及沙盒账号。')
                .fontSize(12).fontColor(this.pal().text2).lineHeight(19)
              TextInput({ text: this.productId, placeholder: 'AGC 测试商品 ID' })
                .enabled(!this.busy).maxLength(128).fontSize(14)
                .onChange((value: string): void => {
                  this.productId = value; this.product = null; this.storePrice = ''; this.storeName = '';
                })
              Button('检查沙盒并读取商品').fontSize(13).enabled(!this.busy && this.productId.trim().length > 0)
                .onClick((): void => { this.operate('load'); })
              if (this.storeName.length > 0) {
                Text(this.storeName).fontSize(13).fontColor(this.pal().text)
              }
            }.padding(16).width('100%').backgroundColor(this.pal().surface).borderRadius(16)
          }
          }
        }.width('100%').constraintSize({ maxWidth: 640 }).padding({ left: 24, right: 24, bottom: 20 })
        .opacity(this.entered ? 1 : 0).translate({ y: this.entered ? 0 : 12 })
        .animation({ duration: 240, curve: Curve.EaseOut })
        .onAppear((): void => { this.entered = true; })
      }.width('100%').layoutWeight(1).scrollBar(BarState.Off)
      Column({ space: 8 }) {
        Text(this.message).fontSize(12).fontColor(this.pal().text2).lineHeight(18).width('100%')
        if (this.storePrice.length === 0) {
          Text('计划首发 ' + PRO_LAUNCH_PRICE + ' · 后续常规价 ' + PRO_REGULAR_PRICE)
            .fontSize(13).fontColor(this.pal().text2)
        }
        Button(this.busy ? '正在处理…' : this.storePrice.length > 0 ? '沙盒购买 Pro · ' + this.storePrice : 'Pro 即将推出')
          .width('100%').height(48).fontSize(16).fontWeight(FontWeight.Medium)
          .fontColor(Color.White).backgroundColor(this.accent)
          .enabled(!this.busy && this.testing && this.storePrice.length > 0)
          .onClick((): void => { this.operate('buy'); })
        if (this.testing) {
          Button('恢复购买 / 查询订单').fontSize(12).fontColor(this.accent).backgroundColor(Color.Transparent)
            .enabled(!this.busy).onClick((): void => { this.operate('restore'); })
        } else {
          Text('正式价格与权益以上线时的商品说明为准').fontSize(11).fontColor(this.pal().text3)
        }
      }.width('100%').padding({ left: 24, right: 24, top: 12, bottom: 20 })
        .backgroundColor(this.pal().sheetBg)
    }.width('100%').height('100%').backgroundColor(this.pal().sheetBg)
  }
}
