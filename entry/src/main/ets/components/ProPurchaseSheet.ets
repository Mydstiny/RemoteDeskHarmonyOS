import { ProBadge } from './ProBadge';
import { DEBUG } from 'BuildProfile';
import { ProUsbFidoProbePanel } from './ProUsbFidoProbePanel';
import { ProAppRuntime } from '../services/pro/ProAppRuntime';
import { ProDebugMode } from '../services/pro/ProRuntime';
import { ProPurchaseLifecycle } from '../services/pro/ProPurchaseLifecycle';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Palette, buildDark, buildLight } from '../common/Theme';
import { ProFeature, proFeatureProgress, proFeatures } from '../services/pro/ProFeatureCatalog';
import { markProTrialStarted, proTrialStarted } from '../services/pro/ProTrialNotice';
import {
  HuaweiProBillingProvider, ProStoreProduct, ProPurchaseCoordinator,
  PRO_LAUNCH_PRICE, PRO_REGULAR_PRICE, proBillingError, proRefundError
} from '../services/pro/ProBillingService';

@Component
export struct ProPurchaseSheet {
  @StorageProp('currentTheme') theme: string = 'light';
  @StorageProp('accentColor') accent: string = '#007DFF';
  @State entered: boolean = false;
  @State busy: boolean = false;
  @State testing: boolean = false;
  @State billingReady: boolean = false;
  @State purchased: boolean = false;
  @State proLabel: string = '免费版';
  @State debugMode: ProDebugMode = 'real';
  /** 1.2.0 free trial: Pro for everyone, so the page offers 立即试用 instead of a purchase. */
  @State trial: boolean = false;
  @State trialStarted: boolean = false;
  private unsubscribe: (() => void) | null = null;
  @State productId: string = '';
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
    this.trialStarted = proTrialStarted(this.context());
    this.syncBilling();
    this.unsubscribe = ProAppRuntime.getInstance().runtime.subscribe((): void => {
      this.syncBilling();
      const snapshot = ProAppRuntime.getInstance().runtime.snapshot();
      this.proLabel = snapshot.label;
      this.debugMode = snapshot.mode;
      this.purchased = snapshot.effectiveState === 'active';
      this.trial = snapshot.complimentary;
    });
  }

  /** 立即试用: everyone already has Pro; this records that the user started it and says what it means. */
  private startTrial(): void {
    markProTrialStarted(this.context());
    this.trialStarted = true;
    this.message = '已开启免费试用，全部 Pro 功能可以直接使用。';
  }
  aboutToDisappear(): void {
    this.live = false; this.generation++;
    this.unsubscribe?.(); this.unsubscribe = null;
  }
  private pal(): Palette { return this.theme === 'light' ? buildLight(this.accent) : buildDark(this.accent); }
  private context(): common.UIAbilityContext { return getContext(this) as common.UIAbilityContext; }

  private syncBilling(): void {
    const runtime = ProAppRuntime.getInstance();
    const productId = runtime.billingProductId();
    const ready = runtime.billingAvailable();
    const testing = runtime.sandboxSelected();
    if (this.productId === productId && this.billingReady === ready && this.testing === testing) { return; }
    this.generation++;
    this.busy = false;
    this.testing = testing;
    this.productId = productId;
    this.billingReady = ready;
    this.product = null; this.storePrice = ''; this.storeName = '';
    this.message = this.billingReady ? '读取商品价格后可购买；已购买的账号可直接恢复权益。' :
      'Pro 正在准备中，当前版本的功能继续免费使用。';
  }
  private prefix(): string { return this.testing ? '沙盒 ' : ''; }
  private async operate(action: string): Promise<void> {
    if (!this.billingReady || (this.testing && !DEBUG)) { return; }
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
        this.message = this.prefix() + '商品已确认，购买后将验证订单并开通 Pro。';
      } else if (action === 'buy' && this.product !== null && !this.purchased) {
        const outcome = await this.provider.purchase(this.context(), this.product.id, (): boolean =>
          this.live && generation === this.generation && ProPurchaseLifecycle.current(epoch));
        if (!this.live || generation !== this.generation || !ProPurchaseLifecycle.current(epoch)) { return; }
        this.message = outcome.verified ? this.prefix() + '订单验证通过，Pro 已开通。' :
          '已收到购买结果，权益仍待核验；请使用恢复购买，不必重复付款。';
        this.product = null;
        this.storePrice = '';
      } else if (action === 'refund' && DEBUG && this.testing) {
        const outcome = await this.provider.refund(this.context(), this.productId, (): boolean =>
          this.live && generation === this.generation && ProPurchaseLifecycle.current(epoch));
        if (!this.live || generation !== this.generation || !ProPurchaseLifecycle.current(epoch)) { return; }
        const snapshot = ProAppRuntime.getInstance().runtime.snapshot();
        this.message = snapshot.realState === 'revoked' ? '服务端已确认' + this.prefix() + 'Pro 权益撤销。' :
          snapshot.refundPending ? '退款已提交，Pro 功能已暂停，等待服务端确认；请稍后恢复购买核验。' :
          '退款页面已返回，请使用恢复购买同步最新权益；退款结果以华为订单状态为准。';
        this.product = null;
        this.storePrice = '';
      } else if (action === 'restore') {
        const outcome = await this.provider.restore(this.context(), this.productId, (): boolean =>
          this.live && generation === this.generation && ProPurchaseLifecycle.current(epoch));
        if (!this.live || generation !== this.generation || !ProPurchaseLifecycle.current(epoch)) { return; }
        this.message = outcome.verified ? this.prefix() + '权益已验证并恢复。' :
          ProAppRuntime.getInstance().runtime.snapshot().realState === 'revoked' ? '服务端已确认' + this.prefix() + 'Pro 权益撤销。' : outcome.records > 0 ?
          '已查询到订单，本次尚未恢复有效权益，请稍后重试。' : '当前账号未恢复到有效的' + this.prefix() + 'Pro 权益。';
      }
    } catch (error) {
      if (this.live && generation === this.generation) {
        this.message = action === 'refund' ? proRefundError(error as BusinessError) : proBillingError(error as BusinessError);
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
          Text(feature.title).fontSize(16).fontWeight(FontWeight.Medium).fontColor(this.pal().text).layoutWeight(1)
          ProBadge()
        }.width('100%')
        if (proFeatureProgress(feature.id).length > 0) {
          Text(proFeatureProgress(feature.id)).fontSize(11).lineHeight(16)
            .fontColor(feature.availability === 'planned' ? this.pal().text2 : this.accent)
            .padding({ left: 8, right: 8, top: 4, bottom: 4 }).backgroundColor(this.pal().surface).borderRadius(8)
        }
        Text(feature.description).fontSize(13).fontColor(this.pal().text2).lineHeight(20).width('100%')
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
    }.width('100%').padding(16).backgroundColor(this.pal().card).borderRadius(20)
    .border({ width: 0.5, color: this.pal().cardBorder })
  }

  // Every Pro feature is introduced here; the display switches live in 设置 > Pro 功能.
  private proCatalog(): ProFeature[] {
    return proFeatures().filter((item: ProFeature): boolean => item.requiredEntitlementId.length > 0);
  }

  build() {
    Column() {
      Row() {
        Text('RemoteDesk Pro').fontSize(18).fontWeight(FontWeight.Bold).fontColor(this.pal().text)
        Blank()
        Button('完成').fontSize(14).fontColor(this.accent).backgroundColor(Color.Transparent)
          .onClick((): void => { this.live = false; this.generation++; ProPurchaseLifecycle.dismiss(); this.onClose(); })
      }.width('100%').padding({ left: 24, right: 16, top: 12, bottom: 8 })
      Scroll() {
        Column({ space: 14 }) {
          Column({ space: 12 }) {
            ProBadge({ large: true })
            Text('让每次连接\n更得心应手').fontSize(30).fontWeight(FontWeight.Bold)
              .fontColor(this.pal().text).textAlign(TextAlign.Center).lineHeight(39)
            Text('全部协议免费连接，专业工具提升效率。')
              .fontSize(14).fontColor(this.pal().text2).textAlign(TextAlign.Center)
            Text(this.proLabel).fontSize(13).fontColor(this.accent)
            if (this.trial) {
              Text('1.2.0 起全部 Pro 功能免费试用 · 正式收费前会提前通知').fontSize(12).fontColor(this.accent)
            } else {
              Text('一次购买 · 不自动续费').fontSize(12).fontColor(this.accent)
            }
          }.width('100%').padding({ top: 16, bottom: 18 })
          ForEach(this.proCatalog(),
            (feature: ProFeature, index: number): void => { this.featureCard(feature, index) },
            (feature: ProFeature): string => feature.id)
          Text('核心功能一直免费').fontSize(15).fontWeight(FontWeight.Medium).fontColor(this.pal().text)
            .width('100%').margin({ top: 8 })
          Text(this.trial ? '协议连接、正常画质、键鼠操作、基础文件传输和安全更新永久免费。免费试用期间，其余已开发的 Pro 功能全部开放；标注“规划中”的能力尚未交付，碰一碰等验证中的功能稍后开放。' :
            '协议连接、正常画质、键鼠操作、基础文件传输和安全更新保持免费。标注“规划中”的能力尚未交付，Pro 正式购买仍在准备中。')
            .fontSize(13).fontColor(this.pal().text2).lineHeight(21).width('100%')
          if (DEBUG) {
            ProUsbFidoProbePanel({ isOpen: (): boolean => this.live })
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
              ProAppRuntime.getInstance().setSandbox(this.testing);
              this.generation++; this.syncBilling();
            })
          if (this.testing) {
            Column({ space: 10 }) {
              Text('沙盒订单只开通沙盒权益。请使用已加入测试名单的华为账号。')
                .fontSize(12).fontColor(this.pal().text2).lineHeight(19)
              Text('测试商品：' + this.productId).fontSize(12).fontColor(this.pal().text2)
              Button('检查沙盒并读取商品').fontSize(13).enabled(!this.busy && this.productId.trim().length > 0)
                .onClick((): void => { this.operate('load'); })
              // During the free trial the main button is 立即试用: the sandbox purchase lives here.
              if (this.trial && this.storePrice.length > 0) {
                Button('沙盒购买 Pro · ' + this.storePrice).fontSize(13).enabled(!this.busy)
                  .onClick((): void => { this.operate('buy'); })
              }
              Button('申请沙盒订单退款').fontSize(13).enabled(!this.busy)
                .onClick((): void => { this.operate('refund'); })
              Text('打开华为退款页面后自行确认。仅选择唯一的当前沙盒 Pro 订单，返回后重新核验权益。')
                .fontSize(12).fontColor(this.pal().text2).lineHeight(19)
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
      if (this.trial) {
        Column({ space: 8 }) {
          Text(this.trialStarted ? '全部 Pro 功能免费试用中。商户审核通过、正式收费前，会在应用内提前通知。' : this.message)
            .fontSize(12).fontColor(this.pal().text2).lineHeight(18).width('100%')
          Button(this.trialStarted ? 'Pro 试用中' : '立即试用')
            .width('100%').height(48).fontSize(16).fontWeight(FontWeight.Medium)
            .fontColor(Color.White).backgroundColor(this.accent)
            .enabled(!this.trialStarted)
            .onClick((): void => { this.startTrial(); })
          Text('试用无需付款，也不会自动扣费').fontSize(11).fontColor(this.pal().text3)
        }.width('100%').padding({ left: 24, right: 24, top: 12, bottom: 20 })
        .backgroundColor(this.pal().sheetBg)
      } else {
      Column({ space: 8 }) {
        Text(this.message).fontSize(12).fontColor(this.pal().text2).lineHeight(18).width('100%')
        if (this.storePrice.length === 0) {
          Text('计划首发 ' + PRO_LAUNCH_PRICE + ' · 后续常规价 ' + PRO_REGULAR_PRICE)
            .fontSize(13).fontColor(this.pal().text2)
        }
        Button(this.busy ? '正在处理…' : this.purchased ? 'Pro 已开通' : !this.billingReady ? 'Pro 即将推出' :
          this.storePrice.length > 0 ? this.prefix() + '购买 Pro · ' + this.storePrice : '读取商品价格')
          .width('100%').height(48).fontSize(16).fontWeight(FontWeight.Medium)
          .fontColor(Color.White).backgroundColor(this.accent)
          .enabled(!this.busy && this.billingReady && !this.purchased)
          .onClick((): void => { this.operate(this.storePrice.length > 0 ? 'buy' : 'load'); })
        if (this.billingReady) {
          Button('恢复购买 / 查询订单').fontSize(12).fontColor(this.accent).backgroundColor(Color.Transparent)
            .enabled(!this.busy).onClick((): void => { this.operate('restore'); })
        } else {
          Text('正式价格与权益以上线时的商品说明为准').fontSize(11).fontColor(this.pal().text3)
        }
      }.width('100%').padding({ left: 24, right: 24, top: 12, bottom: 20 })
        .backgroundColor(this.pal().sheetBg)
      }
    }.width('100%').height('100%').backgroundColor(this.pal().sheetBg)
  }
}
