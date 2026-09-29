import { ProBadge } from './ProBadge';
import { Palette, buildDark, buildLight } from '../common/Theme';
import { ProAppRuntime } from '../services/pro/ProAppRuntime';
import { ProAppIcons } from '../services/pro/ProAppIcons';
import { ProAppIconSnapshot } from '../services/pro/ProAppIconController';
import { ProPurchaseLifecycle } from '../services/pro/ProPurchaseLifecycle';
import { ProFeatureGate } from './ProFeatureGate';
import { APP_ICON_PRESETS, AppIconPreset, appIconLabel } from '../common/AppIconPolicy';

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
  build() {
    if (this.state.supported) {
      Column({ space: 12 }) {
        Row() {
          Text('应用图标').fontSize(16).fontWeight(FontWeight.Medium).fontColor(this.pal().text).layoutWeight(1)
          ProBadge()
        }.width('100%')
        Text('当前：' + this.name()).fontSize(13).fontColor(this.pal().text2).width('100%')
        ProFeatureGate({ featureId: 'pro.personalization.appIcon', content: (): void => { this.presets(); } })
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
    }
  }
}
