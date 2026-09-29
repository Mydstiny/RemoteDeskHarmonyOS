import { common } from '@kit.AbilityKit';
import { DEBUG } from 'BuildProfile';
import { AppConfig, Palette, buildDark, buildLight } from '../common/Theme';
import { AppSettingsChoiceButton } from './AppSettingsChoiceButton';
import { ProAccessContext } from '../services/pro/ProAccessPolicy';
import { ProAppRuntime } from '../services/pro/ProAppRuntime';
import { ProEntries } from '../services/pro/ProEntries';
import { ProFeature } from '../services/pro/ProFeatureCatalog';
import { ProFeatureStatus, proFeatureScope, proFeatureStatus } from '../services/pro/ProFeatureStatus';
import { ProFeatureVisibility } from '../services/pro/ProFeatureVisibility';
import { ProDebugMode, ProRuntimeSnapshot } from '../services/pro/ProRuntime';

const DEBUG_MODES: ProDebugMode[] = ['real', 'free', 'pro'];

/** Every catalogued Pro feature with its live status and an individual display switch. */
@Component
export struct ProFeatureManagerPanel {
  @StorageProp('currentTheme') theme: string = 'light';
  @StorageProp('accentColor') accent: string = '#007DFF';
  @State revision: number = 0;
  private contextValue: common.UIAbilityContext | null = null;
  private stop: (() => void) | null = null;

  aboutToAppear(): void {
    this.contextValue = getContext(this) as common.UIAbilityContext;
    ProFeatureVisibility.getInstance().load(this.contextValue);
    this.stop = ProEntries.subscribe((): void => { this.revision++; });
  }
  aboutToDisappear(): void {
    this.stop?.(); this.stop = null; this.contextValue = null;
  }
  private pal(): Palette { return this.theme === 'light' ? buildLight(this.accent) : buildDark(this.accent); }
  private features(_revision: number): ProFeature[] { return ProFeatureVisibility.getInstance().proCatalog(); }
  private runtime(_revision: number): ProRuntimeSnapshot { return ProAppRuntime.getInstance().runtime.snapshot(); }
  private stateText(snapshot: ProRuntimeSnapshot): string {
    if (snapshot.label.length > 0) { return snapshot.label; }
    if (snapshot.effectiveState === 'active') { return 'Pro 已激活'; }
    if (snapshot.effectiveState === 'verificationRequired') { return '需要验证'; }
    if (snapshot.effectiveState === 'revoked') { return '已撤销'; }
    return '未开通';
  }
  // The same device, version, protocol and capability checks as the real entry points.
  private status(feature: ProFeature, _revision: number): ProFeatureStatus {
    const app = ProAppRuntime.getInstance();
    const context: ProAccessContext = app.context(feature.protocols.length > 0 ? feature.protocols[0] : '');
    feature.capabilities.forEach((capability: string): void => {
      if (canIUse(capability)) { context.capabilities.push(capability); }
    });
    context.requestablePermissions = feature.permissions.slice();
    return proFeatureStatus(feature, app.runtime.decision(feature.id, context), DEBUG);
  }
  private toneColor(status: ProFeatureStatus): ResourceColor {
    if (status.tone === 'ready') { return this.accent; }
    if (status.tone === 'experimental') { return '#B26A00'; }
    return this.pal().text3;
  }
  private modeLabel(mode: ProDebugMode): string {
    return mode === 'real' ? '跟随真实' : mode === 'free' ? '模拟免费' : '模拟 Pro';
  }
  private toggle(feature: ProFeature, visible: boolean): void {
    if (this.contextValue !== null) { ProFeatureVisibility.getInstance().setVisible(this.contextValue, feature.id, visible); }
  }
  @Builder private featureRow(feature: ProFeature) {
    Row({ space: 12 }) {
      Column({ space: 3 }) {
        Row({ space: 8 }) {
          Text(feature.title).fontSize(15).fontWeight(FontWeight.Medium).fontColor(this.pal().text)
            .fontFamily(AppConfig.fontFamily).layoutWeight(1)
          Text(this.status(feature, this.revision).label).fontSize(11).fontColor(this.toneColor(this.status(feature, this.revision)))
            .fontFamily(AppConfig.fontFamily).padding({ left: 8, right: 8, top: 2, bottom: 2 })
            .borderRadius(10).backgroundColor(this.pal().surface)
        }.width('100%')
        Text(this.status(feature, this.revision).detail).fontSize(12).fontColor(this.pal().text2)
          .fontFamily(AppConfig.fontFamily).width('100%')
        if (proFeatureScope(feature).length > 0) {
          Text(proFeatureScope(feature)).fontSize(11).fontColor(this.pal().text3)
            .fontFamily(AppConfig.fontFamily).width('100%')
        }
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      Toggle({ type: ToggleType.Switch, isOn: ProFeatureVisibility.getInstance().isVisible(feature.id) })
        .selectedColor(this.accent).accessibilityText(feature.title + ' 入口显示')
        .onChange((on: boolean): void => { this.toggle(feature, on); })
    }.width('100%').padding({ left: 16, right: 16, top: 12, bottom: 12 })
  }
  build() {
    Column() {
      Row() {
        Text('Pro 状态').fontSize(15).fontWeight(FontWeight.Medium).fontColor(this.pal().text)
          .fontFamily(AppConfig.fontFamily).layoutWeight(1)
        Text(this.stateText(this.runtime(this.revision))).fontSize(13).fontColor(this.accent)
          .fontFamily(AppConfig.fontFamily)
      }.width('100%').padding({ left: 16, right: 16, top: 14, bottom: 10 })
      if (DEBUG) {
        Row({ space: 8 }) {
          ForEach(DEBUG_MODES, (mode: ProDebugMode): void => {
            AppSettingsChoiceButton({ label: this.modeLabel(mode), isSelected: this.runtime(this.revision).mode === mode,
              onSelect: (): void => { ProAppRuntime.getInstance().runtime.setDebugMode(mode); } }).layoutWeight(1)
          }, (mode: ProDebugMode): string => mode)
        }.width('100%').padding({ left: 16, right: 16, bottom: 10 })
      }
      Text('开关只控制入口是否显示，不改变购买或权益；状态随账号、设备与模拟模式实时更新。')
        .fontSize(12).fontColor(this.pal().text3).fontFamily(AppConfig.fontFamily).lineHeight(18)
        .width('100%').padding({ left: 16, right: 16, bottom: 8 })
      Divider().strokeWidth(0.5).color(this.pal().cardBorder)
      ForEach(this.features(this.revision), (feature: ProFeature, index: number): void => {
        if (index > 0) { Divider().strokeWidth(0.5).color(this.pal().cardBorder).margin({ left: 16, right: 16 }) }
        this.featureRow(feature)
      }, (feature: ProFeature): string => feature.id + ':' + this.revision.toString())
    }.width('100%').borderRadius(24).backgroundColor(this.pal().card).backgroundBlurStyle(BlurStyle.Regular)
      .border({ width: 0.5, color: this.pal().cardBorder })
  }
}
