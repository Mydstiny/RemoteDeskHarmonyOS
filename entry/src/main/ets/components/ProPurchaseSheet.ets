import { DEBUG } from 'BuildProfile';
import { AppSheetHeader } from './AppSheetHeader';
import { ProAppIconPanel } from './ProAppIconPanel';
import { ProUsbFidoProbePanel } from './ProUsbFidoProbePanel';
import { ProAppRuntime } from '../services/pro/ProAppRuntime';
import { ProDebugMode } from '../services/pro/ProRuntime';
import { ProPurchaseLifecycle } from '../services/pro/ProPurchaseLifecycle';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { LengthMetrics } from '@kit.ArkUI';
import { AppConfig, Palette, buildDark, buildLight } from '../common/Theme';
import { AppUiMetrics } from '../common/AppUiMetrics';
import { appUiButtonFill, appUiButtonText } from '../common/AppUiColorPolicy';
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
  private provider: HuaweiProBillingProvider = new HuaweiProBillingProvider(ProAppRuntime.getInstance());
  private product: ProStoreProduct | null = null;
  private generation: number = 0;
  private live: boolean = false;
  onClose: () => void = (): void => {};

  aboutToAppear(): void {
    this.live = true;
    this.testing = ProAppRuntime.getInstance().sandboxSelected();
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
        this.message = '沙盒商品已确认，购买后将验证订单并开通沙盒 Pro。';
      } else if (action === 'buy' && this.product !== null && this.testing) {
        const outcome = await this.provider.purchase(this.context(), this.product.id, (): boolean =>
          this.live && generation === this.generation && ProPurchaseLifecycle.current(epoch));
        if (!this.live || generation !== this.generation || !ProPurchaseLifecycle.current(epoch)) { return; }
        this.message = outcome.verified ? '沙盒订单验证通过，沙盒 Pro 已开通。' :
          '本次尚未开通沙盒 Pro，请使用恢复购买继续核验。';
        this.product = null;
        this.storePrice = '';
      } else if (action === 'restore') {
        const outcome = await this.provider.restore(this.context(), this.productId, (): boolean =>
          this.live && generation === this.generation && ProPurchaseLifecycle.current(epoch));
        if (!this.live || generation !== this.generation || !ProPurchaseLifecycle.current(epoch)) { return; }
        this.message = outcome.verified ? '沙盒权益已验证并恢复。' : outcome.records > 0 ?
          '已查询到订单，本次尚未恢复有效沙盒权益，请稍后重试。' : '当前未恢复到有效的沙盒 Pro 权益。';
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
        .fontFamily(AppConfig.fontFamily).fontSize(16).fontWeight(FontWeight.Bold).fontColor(this.accent)
        .width(44).constraintSize({ minHeight: AppUiMetrics.minTouchTarget }).textAlign(TextAlign.Center)
        .backgroundColor(this.pal().surface).borderRadius(14)
      Column({ space: 6 }) {
        Flex({ wrap: FlexWrap.Wrap, space: { main: LengthMetrics.vp(8), cross: LengthMetrics.vp(6) } }) {
          Text(feature.title).fontFamily(AppConfig.fontFamily).fontSize(16).fontWeight(FontWeight.Medium).fontColor(this.pal().text)
          Text(feature.availability === 'planned' ? '规划中' : feature.availability === 'experimental' ?
            '验证中' : feature.availability === 'disabled' ? '暂不可用' : 'Pro').fontFamily(AppConfig.fontFamily).fontSize(10).fontColor(this.pal().text2)
            .padding({ left: 7, right: 7, top: 3, bottom: 3 }).backgroundColor(this.pal().surface).borderRadius(6)
        }.width('100%')
        Text(feature.description).fontFamily(AppConfig.fontFamily).fontSize(13).fontColor(this.pal().text2).width('100%')
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
    }.width('100%').padding(16).backgroundColor(this.pal().card).borderRadius(20)
    .border({ width: 0.5, color: this.pal().cardBorder })
  }

  build() {
    Column() {
      AppSheetHeader({ title: 'RemoteDesk Pro', closeLabel: '完成', horizontalPadding: AppUiMetrics.sheetPadding,
        onClose: (): void => {
          this.live = false; this.generation++; ProPurchaseLifecycle.dismiss(); this.onClose();
        }
      })
      Scroll() {
        Column({ space: 14 }) {
          Column({ space: 12 }) {
            Text('PRO').fontFamily(AppConfig.fontFamily).fontSize(14).fontWeight(FontWeight.Bold).fontColor(appUiButtonText(this.accent))
              .letterSpacing(4).padding({ left: 18, right: 18, top: 8, bottom: 8 })
              .backgroundColor(appUiButtonFill(this.accent)).borderRadius(12)
            Text('让每次连接\n更得心应手').fontFamily(AppConfig.fontFamily).fontSize(30).fontWeight(FontWeight.Bold)
              .fontColor(this.pal().text).textAlign(TextAlign.Center).width('100%')
            Text('全部协议免费连接，专业工具提升效率。')
              .fontFamily(AppConfig.fontFamily).fontSize(14).fontColor(this.pal().text2).textAlign(TextAlign.Center)
            Text(this.proLabel).fontFamily(AppConfig.fontFamily).fontSize(13).fontColor(this.accent)
            Text('一次购买 · 不自动续费').fontFamily(AppConfig.fontFamily).fontSize(12).fontColor(this.accent)
          }.width('100%').padding({ top: 16, bottom: 18 })
          ProAppIconPanel({ isOpen: (): boolean => this.live })
          ForEach(proFeatures().filter((item: ProFeature): boolean => item.requiredEntitlementId.length > 0),
            (feature: ProFeature, index: number): void => { this.featureCard(feature, index) },
            (feature: ProFeature): string => feature.id)
          Text('核心功能一直免费').fontFamily(AppConfig.fontFamily).fontSize(15).fontWeight(FontWeight.Medium).fontColor(this.pal().text)
            .width('100%').margin({ top: 8 })
          Text('协议连接、正常画质、键鼠操作、基础文件传输和安全更新保持免费。标注“规划中”的能力尚未交付，Pro 正式购买仍在准备中。')
            .fontFamily(AppConfig.fontFamily).fontSize(13).fontColor(this.pal().text2).width('100%')
          if (DEBUG) {
            ProUsbFidoProbePanel({ isOpen: (): boolean => this.live })
            Column({ space: 8 }) {
              Text('开发者调试 · 权益模拟').fontFamily(AppConfig.fontFamily).fontSize(14).fontColor(this.pal().text)
              ForEach(['real', 'free', 'pro'], (mode: string): void => {
                Button({ type: ButtonType.Normal }) {
                  Text((this.debugMode === mode ? '✓ ' : '') +
                    (mode === 'real' ? '跟随真实权益' : mode === 'free' ? '模拟免费用户' : '模拟 Pro 用户'))
                    .fontFamily(AppConfig.fontFamily).fontSize(13).fontColor(this.pal().text).textAlign(TextAlign.Center).width('100%')
                }.width('100%').constraintSize({ minHeight: AppUiMetrics.minTouchTarget })
                  .padding(12).borderRadius(12).backgroundColor(this.pal().surface)
                  .focusable(true).accessibilitySelected(this.debugMode === mode)
                  .enabled(!this.busy).onClick((): void => {
                    ProAppRuntime.getInstance().runtime.setDebugMode(mode as ProDebugMode);
                  })
              })
              Text('仅当前运行有效，重启恢复真实权益。模拟不购买、不退款，也不解锁规划中的功能。')
                .fontFamily(AppConfig.fontFamily).fontSize(12).fontColor(this.pal().text2).width('100%')
            }.width('100%').padding(16).backgroundColor(this.pal().card).borderRadius(16)
            Button({ type: ButtonType.Normal }) {
              Text(this.testing ? '收起沙盒测试' : '开发者沙盒测试')
                .fontFamily(AppConfig.fontFamily).fontSize(12).fontColor(this.pal().text2).textAlign(TextAlign.Center).width('100%')
            }.width('100%').constraintSize({ minHeight: AppUiMetrics.minTouchTarget })
              .padding(12).borderRadius(12).backgroundColor(Color.Transparent).focusable(true)
              .enabled(!this.busy).onClick((): void => {
                this.testing = !this.testing;
                ProAppRuntime.getInstance().setSandbox(this.testing);
                this.product = null; this.storePrice = ''; this.storeName = '';
              })
            if (this.testing) {
              Column({ space: 10 }) {
                Text('沙盒订单只开通沙盒权益。请使用已加入测试名单的华为账号。')
                  .fontFamily(AppConfig.fontFamily).fontSize(12).fontColor(this.pal().text2).width('100%')
                Text('测试商品：' + this.productId).fontFamily(AppConfig.fontFamily).fontSize(12).fontColor(this.pal().text2)
                Button({ type: ButtonType.Normal }) {
                  Text('检查沙盒并读取商品').fontFamily(AppConfig.fontFamily).fontSize(13).fontColor(this.pal().text)
                    .textAlign(TextAlign.Center).width('100%')
                }.width('100%').constraintSize({ minHeight: AppUiMetrics.minTouchTarget })
                  .padding(12).borderRadius(12).backgroundColor(this.pal().card).focusable(true)
                  .enabled(!this.busy && this.productId.trim().length > 0)
                  .onClick((): void => { this.operate('load'); })
                if (this.storeName.length > 0) {
                  Text(this.storeName).fontFamily(AppConfig.fontFamily).fontSize(13).fontColor(this.pal().text)
                }
              }.padding(16).width('100%').backgroundColor(this.pal().surface).borderRadius(16)
            }
          }
          Column({ space: 8 }) {
            Text(this.message).fontFamily(AppConfig.fontFamily).fontSize(12).fontColor(this.pal().text2).width('100%')
            if (this.storePrice.length === 0) {
              Text('计划首发 ' + PRO_LAUNCH_PRICE + ' · 后续常规价 ' + PRO_REGULAR_PRICE)
                .fontFamily(AppConfig.fontFamily).fontSize(13).fontColor(this.pal().text2)
            }
            Button({ type: ButtonType.Normal }) {
              Text(this.busy ? '正在处理…' : this.storePrice.length > 0 ? '沙盒购买 Pro · ' + this.storePrice : 'Pro 即将推出')
                .fontFamily(AppConfig.fontFamily).fontSize(16).fontWeight(FontWeight.Medium).fontColor(appUiButtonText(this.accent))
                .textAlign(TextAlign.Center).width('100%')
            }.width('100%').constraintSize({ minHeight: AppUiMetrics.minTouchTarget })
              .padding(14).borderRadius(14).backgroundColor(appUiButtonFill(this.accent)).focusable(true)
              .enabled(!this.busy && this.testing && this.storePrice.length > 0)
              .onClick((): void => { this.operate('buy'); })
            if (this.testing) {
              Button({ type: ButtonType.Normal }) {
                Text('恢复购买 / 查询订单').fontFamily(AppConfig.fontFamily).fontSize(12).fontColor(this.pal().text)
                  .textAlign(TextAlign.Center).width('100%')
              }.width('100%').constraintSize({ minHeight: AppUiMetrics.minTouchTarget })
                .padding(12).borderRadius(12).backgroundColor(this.pal().surface).focusable(true)
                .enabled(!this.busy).onClick((): void => { this.operate('restore'); })
            } else {
              Text('正式价格与权益以上线时的商品说明为准').fontFamily(AppConfig.fontFamily).fontSize(11).fontColor(this.pal().text3)
            }
          }.width('100%').padding({ top: 12, bottom: 8 })
            .backgroundColor(this.pal().sheetBg)
        }.width('100%').constraintSize({ maxWidth: 640 }).padding({ left: AppUiMetrics.sheetPadding, right: AppUiMetrics.sheetPadding, bottom: 20 })
        .opacity(this.entered ? 1 : 0).translate({ y: this.entered ? 0 : 12 })
        .animation({ duration: 240, curve: Curve.EaseOut })
        .onAppear((): void => { this.entered = true; })
      }.width('100%').layoutWeight(1).scrollBar(BarState.Auto)
    }.width('100%').height('100%').backgroundColor(this.pal().sheetBg)
  }
}
