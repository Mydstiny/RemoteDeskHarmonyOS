import { ProBadge } from './ProBadge';
import { AppSheetHeader } from './AppSheetHeader';
import { settingsVisualIsModern } from '../services/SettingsVisualStylePolicy';
import { Palette, buildDark, buildLight } from '../common/Theme';
import { ProAppRuntime } from '../services/pro/ProAppRuntime';
import { ProAppIcons } from '../services/pro/ProAppIcons';
import { ProAppIconSnapshot } from '../services/pro/ProAppIconController';
import { ProPurchaseLifecycle } from '../services/pro/ProPurchaseLifecycle';
import { ProFeatureGate } from './ProFeatureGate';
import { ProEntries } from '../services/pro/ProEntries';
import { APP_ICON_PRESETS, AppIconPreset, appIconLabel } from '../common/AppIconPolicy';

@Component
export struct ProAppIconPanel {
  @StorageProp('currentTheme') theme: string = 'light';
  @StorageProp('accentColor') accent: string = '#007DFF';
  @State state: ProAppIconSnapshot = ProAppIcons.getInstance().snapshot();
  @State proLabel: string = '';
  @State entitled: boolean = ProEntries.visible('pro.personalization.appIcon');
  private live: boolean = false;
  isOpen: () => boolean = (): boolean => true;
  /** The settings sheet shows a close button on Pad and PC, where it has no drag bar. */
  @Prop showClose: boolean = false;
  onClose: () => void = (): void => {};
  /** 设置 → 个性化 → 全新视觉: the shared sheet header when opened from settings. */
  @StorageProp('settingsVisualStyle') visualStyle: string = 'modern';
  private stopIcons: (() => void) | null = null;
  private stopRuntime: (() => void) | null = null;

  aboutToAppear(): void {
    this.live = true;
    this.stopIcons = ProAppIcons.getInstance().subscribe((): void => {
      this.state = ProAppIcons.getInstance().snapshot();
    });
    this.stopRuntime = ProEntries.subscribe((): void => {
      this.proLabel = ProAppRuntime.getInstance().runtime.snapshot().label;
      this.entitled = ProEntries.visible('pro.personalization.appIcon');
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
    return this.state.currentName === '' ? '默认图标' : appIconLabel(this.state.currentName);
  }
  // Pre-composed previews: the layered launcher icons are not plain bitmaps for Image.
  private preview(name: string): Resource {
    if (name === 'rd_white') { return $r('app.media.icon_preview_rd_white'); }
    if (name === 'rd_transparent') { return $r('app.media.icon_preview_rd_transparent'); }
    if (name === 'rd_night') { return $r('app.media.icon_preview_rd_night'); }
    if (name === 'rd_sky') { return $r('app.media.icon_preview_rd_sky'); }
    if (name === 'rd_aurora') { return $r('app.media.icon_preview_rd_aurora'); }
    if (name === 'rd_vivid') { return $r('app.media.icon_preview_rd_vivid'); }
    if (name === 'rd_soft') { return $r('app.media.icon_preview_rd_soft'); }
    if (name === 'rd_glow') { return $r('app.media.icon_preview_rd_glow'); }
    if (name === 'rd_glow_mist') { return $r('app.media.icon_preview_rd_glow_mist'); }
    if (name === 'rd_classic') { return $r('app.media.icon_preview_rd_classic'); }
    if (name === 'rd_glow_night') { return $r('app.media.icon_preview_rd_glow_night'); }
    if (name === 'rd_glow_frost') { return $r('app.media.icon_preview_rd_glow_frost'); }
    if (name === 'rd_vivid_night') { return $r('app.media.icon_preview_rd_vivid_night'); }
    if (name === 'rd_vivid_ocean') { return $r('app.media.icon_preview_rd_vivid_ocean'); }
    if (name === 'rd_vivid_aurora') { return $r('app.media.icon_preview_rd_vivid_aurora'); }
    return $r('app.media.icon_preview_default');
  }
  private rows(): AppIconPreset[][] {
    const rows: AppIconPreset[][] = [];
    for (let index = 0; index < APP_ICON_PRESETS.length; index += 3) { rows.push(APP_ICON_PRESETS.slice(index, index + 3)); }
    return rows;
  }
  private current(name: string): boolean { return this.state.loaded && this.state.currentName === name; }
  // A Column card: Button(Normal) ignored the corner radius on device.
  @Builder private option(preset: AppIconPreset) {
    Column({ space: 8 }) {
      Image(this.preview(preset.name)).width(56).height(56).objectFit(ImageFit.Contain)
      Text(preset.label).fontSize(13).fontColor(this.pal().text).maxLines(1)
      Text(this.current(preset.name) ? '使用中' : ' ').fontSize(11).fontColor(this.accent)
    }
    .layoutWeight(1).padding({ top: 12, bottom: 10, left: 4, right: 4 })
    .borderRadius(16).clip(true).backgroundColor(this.pal().surface)
    .border({ width: this.current(preset.name) ? 1.5 : 0.5,
      color: this.current(preset.name) ? this.accent : this.pal().cardBorder })
    .opacity(this.state.busy ? 0.6 : 1).enabled(!this.state.busy)
    .clickEffect({ level: ClickEffectLevel.LIGHT }).focusable(true)
    .accessibilityText(preset.label + (this.current(preset.name) ? '，使用中' : '，应用此图标'))
    .onClick((): void => { this.select(preset.name); })
  }
  @Builder private presets() {
    Column({ space: 8 }) {
      Text(this.proLabel).fontSize(12).fontColor(this.accent).width('100%')
      ForEach(this.rows(), (row: AppIconPreset[]): void => {
        Row({ space: 8 }) {
          ForEach(row, (preset: AppIconPreset): void => { this.option(preset); },
            (preset: AppIconPreset): string => preset.name === '' ? 'default' : preset.name)
        }.width('100%').alignItems(VerticalAlign.Top)
      }, (row: AppIconPreset[]): string => row.map((preset: AppIconPreset): string => preset.name).join('|'))
    }.width('100%')
  }
  @Builder private title() {
    if (this.showClose && settingsVisualIsModern(this.visualStyle)) {
      AppSheetHeader({ title: '应用图标', subtitle: '换成预设的桌面图标，可随时恢复默认', showProBadge: true,
        horizontalPadding: 0, whiteOnAccent: true, onClose: (): void => { this.onClose(); } })
    } else {
      this.classicTitle()
    }
  }
  @Builder private classicTitle() {
    Row() {
      Text('应用图标').fontSize(16).fontWeight(FontWeight.Medium).fontColor(this.pal().text).layoutWeight(1)
      ProBadge()
      if (this.showClose) {
        SymbolGlyph($r('sys.symbol.xmark')).fontSize(18).fontColor([this.pal().text2])
          .width(36).height(36).margin({ left: 6 }).accessibilityText('关闭')
          .onClick((): void => { this.onClose(); })
      }
    }.width('100%')
  }
  build() {
    if (this.state.supported) {
      Column({ space: 12 }) {
        this.title()
        Text('当前：' + this.name()).fontSize(13).fontColor(this.pal().text2).width('100%')
        ProFeatureGate({ featureId: 'pro.personalization.appIcon', content: (): void => { this.presets(); } })
        if (!this.entitled) {
          Text('预设图标需要有效的 Pro 权益。当前图标会保留，你可以随时恢复默认图标。')
            .fontSize(13).fontColor(this.pal().text2).width('100%')
        }
        if (!this.state.loaded || this.state.currentName !== '') {
          Button('恢复默认图标').fontSize(13).fontColor(this.accent).backgroundColor(this.pal().surface)
            .constraintSize({ minHeight: 44 }).enabled(!this.state.busy)
            .onClick((): void => { this.select(''); })
        }
        if (!this.state.loaded) {
          Button('重新读取图标状态').fontSize(13).constraintSize({ minHeight: 44 }).enabled(!this.state.busy)
            .onClick((): void => { ProAppIcons.getInstance().refresh(); })
        }
        if (this.state.busy) {
          Text('正在应用…').fontSize(12).fontColor(this.pal().text2)
        } else if (this.state.message.length > 0) {
          Text(this.state.message).fontSize(12).fontColor(this.pal().text2).width('100%')
        }
      }.width('100%').padding(16).backgroundColor(this.pal().card).borderRadius(20)
    } else {
      // Say why instead of opening an empty sheet.
      Column({ space: 12 }) {
        this.title()
        Text('这台设备暂不支持更换应用图标，桌面图标保持默认。').fontSize(13).fontColor(this.pal().text2)
          .lineHeight(19).width('100%')
      }.width('100%').padding(16).backgroundColor(this.pal().card).borderRadius(20)
    }
  }
}
