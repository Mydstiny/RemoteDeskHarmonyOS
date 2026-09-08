import { AppConfig, Palette, buildDark, buildLight } from '../common/Theme';
import { AppUiMetrics } from '../common/AppUiMetrics';
import { LengthMetrics } from '@kit.ArkUI';
import { ProAppRuntime } from '../services/pro/ProAppRuntime';
import { ProAppIcons } from '../services/pro/ProAppIcons';
import { ProAppIconSnapshot } from '../services/pro/ProAppIconController';
import { ProPurchaseLifecycle } from '../services/pro/ProPurchaseLifecycle';
import { ProFeatureGate } from './ProFeatureGate';

@Component
export struct ProAppIconPanel {
  @StorageProp('currentTheme') theme: string = 'light';
  @StorageProp('accentColor') accent: string = '#007DFF';
  @State state: ProAppIconSnapshot = ProAppIcons.getInstance().snapshot();
  @State proLabel: string = '';
  private live: boolean = false;
  isOpen: () => boolean = (): boolean => true;
  private stopIcons: (() => void) | null = null;
  private stopRuntime: (() => void) | null = null;

  aboutToAppear(): void {
    this.live = true;
    this.stopIcons = ProAppIcons.getInstance().subscribe((): void => {
      this.state = ProAppIcons.getInstance().snapshot();
    });
    this.stopRuntime = ProAppRuntime.getInstance().runtime.subscribe((): void => {
      this.proLabel = ProAppRuntime.getInstance().runtime.snapshot().label;
    });
    ProAppIcons.getInstance().refresh();
  }
  aboutToDisappear(): void {
    this.live = false; this.stopIcons?.(); this.stopRuntime?.(); this.stopIcons = null; this.stopRuntime = null;
  }
  private pal(): Palette { return this.theme === 'light' ? buildLight(this.accent) : buildDark(this.accent); }
  private select(name: string): void {
    const epoch = ProPurchaseLifecycle.capture();
    ProAppIcons.getInstance().select(name, (): boolean =>
      this.live && this.isOpen() && ProPurchaseLifecycle.current(epoch));
  }
  private name(): string {
    if (!this.state.loaded) { return '暂未确认'; }
    if (this.state.currentName === '') { return '默认图标'; }
    if (this.state.currentName === 'rd_white') { return '白底版'; }
    if (this.state.currentName === 'rd_transparent') { return '透明底版'; }
    return '其他预设';
  }
  @Builder private option(name: string, label: string, icon: Resource) {
    Button({ type: ButtonType.Normal }) {
      Column({ space: 8 }) {
        Image(icon).width(64).height(64).objectFit(ImageFit.Contain).borderRadius(14)
        Text(label).fontFamily(AppConfig.fontFamily).fontSize(13).fontColor(this.pal().text).textAlign(TextAlign.Center).width('100%')
        if (this.state.loaded && this.state.currentName === name) {
          Text('使用中').fontFamily(AppConfig.fontFamily).fontSize(11).fontColor(this.accent)
        }
      }.width('100%').padding({ top: 12, bottom: 12, left: 4, right: 4 })
    }
    .width('100%').constraintSize({ maxWidth: 120, minHeight: AppUiMetrics.minTouchTarget }).flexShrink(0)
    .borderRadius(16).backgroundColor(this.pal().surface).focusable(true)
    .border({ width: this.state.loaded && this.state.currentName === name ? 1.5 : 0.5,
      color: this.state.loaded && this.state.currentName === name ? this.accent : this.pal().cardBorder })
    .enabled(!this.state.busy).accessibilityText(label +
      (this.state.loaded && this.state.currentName === name ? '，使用中' : '，应用此图标'))
    .onClick((): void => { this.select(name); })
  }
  @Builder private presets() {
    Column({ space: 10 }) {
      Text(this.proLabel).fontFamily(AppConfig.fontFamily).fontSize(12).fontColor(this.accent).width('100%')
      Flex({ wrap: FlexWrap.Wrap, space: { main: LengthMetrics.vp(8), cross: LengthMetrics.vp(8) } }) {
        this.option('', '默认', $r('app.media.layered_image'))
        this.option('rd_white', '白底版', $r('app.media.rd_logo_white'))
        this.option('rd_transparent', '透明底版', $r('app.media.rd_logo_transparent'))
      }.width('100%')
    }.width('100%')
  }
  build() {
    if (this.state.supported) {
      Column({ space: 12 }) {
        Text('应用图标').fontFamily(AppConfig.fontFamily).fontSize(16).fontWeight(FontWeight.Medium).fontColor(this.pal().text).width('100%')
        Text('当前：' + this.name()).fontFamily(AppConfig.fontFamily).fontSize(13).fontColor(this.pal().text2).width('100%')
        ProFeatureGate({ featureId: 'pro.personalization.appIcon', content: this.presets })
        if (!this.state.loaded || this.state.currentName !== '') {
          Button({ type: ButtonType.Normal }) {
            Text('恢复默认图标').fontFamily(AppConfig.fontFamily).fontSize(13).fontColor(this.pal().text).textAlign(TextAlign.Center).width('100%')
          }.width('100%').constraintSize({ minHeight: AppUiMetrics.minTouchTarget })
            .padding(12).borderRadius(12).backgroundColor(this.pal().surface).focusable(true)
            .enabled(!this.state.busy)
            .onClick((): void => { this.select(''); })
        }
        if (!this.state.loaded) {
          Button({ type: ButtonType.Normal }) {
            Text('重新读取图标状态').fontFamily(AppConfig.fontFamily).fontSize(13).fontColor(this.pal().text).textAlign(TextAlign.Center).width('100%')
          }.width('100%').constraintSize({ minHeight: AppUiMetrics.minTouchTarget })
            .padding(12).borderRadius(12).backgroundColor(this.pal().surface).focusable(true)
            .enabled(!this.state.busy)
            .onClick((): void => { ProAppIcons.getInstance().refresh(); })
        }
        if (this.state.busy) {
          Text('正在应用…').fontFamily(AppConfig.fontFamily).fontSize(12).fontColor(this.pal().text2)
        } else if (this.state.message.length > 0) {
          Text(this.state.message).fontFamily(AppConfig.fontFamily).fontSize(12).fontColor(this.pal().text2).width('100%')
        }
      }.width('100%').padding(16).backgroundColor(this.pal().card).borderRadius(20)
    }
  }
}
