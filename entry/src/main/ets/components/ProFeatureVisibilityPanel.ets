import { common } from '@kit.AbilityKit';
import { ProFeature, proFeatures } from '../services/pro/ProFeatureCatalog';
import { ProFeatureVisibility } from '../services/pro/ProFeatureVisibility';
import { ProBadge } from './ProBadge';
import { buildDark, buildLight, Palette } from '../common/Theme';

@Component
export struct ProFeatureVisibilityPanel {
  @StorageProp('currentTheme') theme: string = 'light';
  @StorageProp('accentColor') accent: string = '#007DFF';
  @State revision: number = 0;
  @State values: ProFeature[] = [];
  private contextValue: common.UIAbilityContext | null = null;
  private visibilityUnsubscribe: (() => void) | null = null;
  live: boolean = false;
  isOpen: () => boolean = (): boolean => true;

  static prepare(context: common.UIAbilityContext): void {
    ProFeatureVisibility.getInstance().load(context);
  }

  aboutToAppear(): void {
    this.live = true;
    this.contextValue = getContext(this) as common.UIAbilityContext;
    const visibility = ProFeatureVisibility.getInstance();
    visibility.load(this.contextValue);
    this.values = visibility.proCatalog();
    this.visibilityUnsubscribe = visibility.subscribe((): void => {
      this.values = visibility.proCatalog();
      this.revision++;
    });
  }

  aboutToDisappear(): void {
    this.live = false;
    this.visibilityUnsubscribe?.(); this.visibilityUnsubscribe = null;
    this.contextValue = null;
  }

  private pal(): Palette { return this.theme === 'light' ? buildLight(this.accent) : buildDark(this.accent); }

  private toggle(feature: ProFeature, visible: boolean): void {
    if (!this.live || this.contextValue === null) { return; }
    ProFeatureVisibility.getInstance().setVisible(this.contextValue, feature.id, visible);
  }

  build() {
    Column({ space: 10 }) {
      Row() {
        Text('Pro 功能显示').fontSize(16).fontWeight(FontWeight.Medium).fontColor(this.pal().text)
        Blank()
        ProBadge()
      }.width('100%')
      Text('选择要在应用中显示的 Pro 入口。隐藏只影响界面展示，不会改变购买或权益状态；新增功能默认显示。')
        .fontSize(12).fontColor(this.pal().text2).lineHeight(18).width('100%')
      Column() {
        ForEach(this.values, (feature: ProFeature): void => {
          Row() {
            Column() {
              Text(feature.title).fontSize(14).fontColor(this.pal().text)
              Text(feature.description).fontSize(11).fontColor(this.pal().text2).maxLines(2)
            }.layoutWeight(1).alignItems(HorizontalAlign.Start)
            Toggle({ type: ToggleType.Switch, isOn: ProFeatureVisibility.getInstance().isVisible(feature.id) })
              .selectedColor(this.accent).onChange((on: boolean): void => { this.toggle(feature, on); })
          }.width('100%').padding({ left: 14, right: 14, top: 10, bottom: 10 })
          Divider().strokeWidth(0.5).color(this.pal().divider).margin({ left: 14, right: 14 })
        }, (feature: ProFeature): string => feature.id)
      }.width('100%').backgroundColor(this.pal().card).borderRadius(16)
    }.width('100%').padding(16).backgroundColor(this.pal().surface).borderRadius(16)
  }
}
