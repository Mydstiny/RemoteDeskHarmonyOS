/**
 * ColorPickerSheet.ets v2 — 二维色彩空间 + 灰阶合并面板 + 预设色系
 */
import { AppConfig, COLOR_PRESETS, ColorPreset, Palette, buildDark, buildLight } from '../common/Theme';
import { preferences } from '@kit.ArkData';
import { LengthMetrics } from '@kit.ArkUI';
import { AppSheetHeader } from './AppSheetHeader';
import { AppUiMetrics } from '../common/AppUiMetrics';
import { appUiButtonFill, appUiButtonText } from '../common/AppUiColorPolicy';
import { CloudStore } from '../services/CloudStore';

@Component
export struct ColorPickerSheet {
  @StorageLink('currentTheme') theme: string = 'light';
  @StorageLink('accentColor') accentColor: string = '#007DFF';
  @State selectedHex: string = '#007DFF';
  @State hue: number = 211;
  @State sat: number = 100;
  @State bri: number = 100;
  @State gray: number = 128;
  @State activeTab: number = 0;
  onColorChange?: (hex: string) => void;
  onClose: () => void = (): void => {};
  @Prop availableHeight: number = 620;
  @State private headerHeight: number = AppUiMetrics.sheetHeaderMinHeight;
  @State private presetColumns: number = 2;
  private colorPlaneWidth: number = 0;
  private colorPlaneHeight: number = 0;

  aboutToAppear(): void {
    this.selectedHex = this.accentColor;
    const rgb: number[] = this.hexToRgb(this.selectedHex);
    const hsv: number[] = this.rgbToHsv(rgb[0], rgb[1], rgb[2]);
    this.hue = hsv[0];
    this.sat = hsv[1];
    this.bri = hsv[2];
    this.gray = Math.round((rgb[0] + rgb[1] + rgb[2]) / 3);
  }

  private pal(): Palette {
    const accent: string = this.accentColor;
    return this.theme === 'light' ? buildLight(accent) : buildDark(accent);
  }

  private hexToRgb(hex: string): number[] {
    const r: number = parseInt(hex.substring(1, 3), 16);
    const g: number = parseInt(hex.substring(3, 5), 16);
    const b: number = parseInt(hex.substring(5, 7), 16);
    return [r, g, b];
  }

  private rgbToHex(r: number, g: number, b: number): string {
    return '#' + [r, g, b].map((v: number): string => {
      return Math.max(0, Math.min(255, Math.round(v))).toString(16).padStart(2, '0');
    }).join('').toUpperCase();
  }

  private rgbToHsv(r: number, g: number, b: number): number[] {
    const max: number = Math.max(r, g, b) / 255;
    const min: number = Math.min(r, g, b) / 255;
    const d: number = max - min;
    let h: number = 0;
    const s: number = max === 0 ? 0 : Math.round((d / max) * 100);
    const v: number = Math.round(max * 100);
    if (d !== 0) {
      if (max === r / 255) { h = ((g - b) / 255 / d + (g < b ? 6 : 0)) * 60; }
      else if (max === g / 255) { h = ((b - r) / 255 / d + 2) * 60; }
      else { h = ((r - g) / 255 / d + 4) * 60; }
    }
    return [Math.round(h), s, v];
  }

  private hsvToRgb(h: number, s: number, v: number): number[] {
    const pct: number = v / 100;
    const spct: number = s / 100;
    const c: number = pct * spct;
    const x: number = c * (1 - Math.abs((h / 60) % 2 - 1));
    const m: number = pct - c;
    let rgb: number[] = [0, 0, 0];
    if (h < 60) { rgb = [c, x, 0]; }
    else if (h < 120) { rgb = [x, c, 0]; }
    else if (h < 180) { rgb = [0, c, x]; }
    else if (h < 240) { rgb = [0, x, c]; }
    else if (h < 300) { rgb = [x, 0, c]; }
    else { rgb = [c, 0, x]; }
    return [Math.round((rgb[0] + m) * 255), Math.round((rgb[1] + m) * 255), Math.round((rgb[2] + m) * 255)];
  }

  private persistAccent(hex: string): void {
    try {
      const prefs = preferences.getPreferencesSync(getContext(this), { name: 'RemoteDesktopAppPrefs' });
      prefs.putSync('accentColor', hex);
      prefs.flushSync();
    } catch (_e) { /* ignore */ }
    CloudStore.getInstance().upsertUserSetting('accentColor', hex);
  }

  private applyHsvColor(h: number, s: number, b: number): void {
    this.hue = h; this.sat = s; this.bri = b;
    const rgb: number[] = this.hsvToRgb(h, s, b);
    this.selectedHex = this.rgbToHex(rgb[0], rgb[1], rgb[2]);
    this.gray = Math.round((rgb[0] + rgb[1] + rgb[2]) / 3);
    this.accentColor = this.selectedHex;
    AppStorage.setOrCreate('accentColor', this.selectedHex);
    this.persistAccent(this.selectedHex);
    if (this.onColorChange) { this.onColorChange(this.selectedHex); }
  }

  private applyGray(): void {
    const hex: string = this.rgbToHex(this.gray, this.gray, this.gray);
    this.selectedHex = hex;
    const rgb: number[] = this.hexToRgb(hex);
    const hsv: number[] = this.rgbToHsv(rgb[0], rgb[1], rgb[2]);
    this.hue = hsv[0]; this.sat = hsv[1]; this.bri = hsv[2];
    this.accentColor = hex;
    AppStorage.setOrCreate('accentColor', hex);
    this.persistAccent(hex);
    if (this.onColorChange) { this.onColorChange(hex); }
  }

  private selectPreset(hex: string): void {
    this.selectedHex = hex;
    const rgb: number[] = this.hexToRgb(hex);
    const hsv: number[] = this.rgbToHsv(rgb[0], rgb[1], rgb[2]);
    this.hue = hsv[0]; this.sat = hsv[1]; this.bri = hsv[2];
    this.gray = Math.round((rgb[0] + rgb[1] + rgb[2]) / 3);
    this.accentColor = hex;
    AppStorage.setOrCreate('accentColor', hex);
    this.persistAccent(hex);
    if (this.onColorChange) { this.onColorChange(hex); }
  }

  private getHueColor(): string {
    const rgb: number[] = this.hsvToRgb(this.hue, 100, 100);
    return this.rgbToHex(rgb[0], rgb[1], rgb[2]);
  }

  // 点击 2D 色板计算位置对应颜色
  private onSatBriTap(x: number, y: number, w: number, h: number): void {
    if (!Number.isFinite(x) || !Number.isFinite(y) || !Number.isFinite(w) ||
      !Number.isFinite(h) || w <= 0 || h <= 0) { return; }
    const s: number = Math.round(Math.max(0, Math.min(100, (x / w) * 100)));
    const b: number = Math.round(Math.max(0, Math.min(100, 100 - (y / h) * 100)));
    this.applyHsvColor(this.hue, s, b);
  }

  private onColorPlaneGesture(event: GestureEvent): void {
    if (event.fingerList.length === 0) { return; }
    this.onSatBriTap(event.fingerList[0].localX, event.fingerList[0].localY,
      this.colorPlaneWidth, this.colorPlaneHeight);
  }

  private scrollMaxHeight(): number {
    const available: number = Number.isFinite(this.availableHeight) && this.availableHeight > 0
      ? this.availableHeight : 620;
    return Math.max(AppUiMetrics.minTouchTarget, available - this.headerHeight);
  }

  private presetCardWidth(): string {
    if (this.presetColumns === 4) { return 'calc(25% - 6vp)'; }
    return this.presetColumns === 2 ? 'calc(50% - 4vp)' : '100%';
  }

  build() {
    Column() {
      AppSheetHeader({ title: '主题色', subtitle: '选择后立即应用',
        onClose: (): void => { this.onClose(); } })
        .onAreaChange((_oldArea: Area, newArea: Area): void => {
          const width: number = Number(newArea.width);
          if (Number.isFinite(width) && width > 0) {
            this.presetColumns = width >= 324 ? 4 : (width >= 164 ? 2 : 1);
          }
          const height: number = Number(newArea.height);
          if (Number.isFinite(height) && height > 0 && Math.abs(height - this.headerHeight) >= 1) {
            this.headerHeight = height;
          }
        })
      Scroll() {
        Column({ space: 16 }) {
          Row({ space: 12 }) {
            Column().width(AppUiMetrics.minTouchTarget).height(AppUiMetrics.minTouchTarget)
              .borderRadius(12).backgroundColor(this.selectedHex)
              .border({ width: 1, color: this.pal().cardBorder })
              .accessibilityLevel('no')
            Text(this.selectedHex).fontSize(16).fontFamily('monospace').fontColor(this.pal().text)
              .layoutWeight(1).accessibilityText('当前主题色 ' + this.selectedHex)
          }.width('100%')
          Row({ space: 8 }) {
            this.tabBtn('预设色系', 0)
            this.tabBtn('自定义', 1)
          }.width('100%')
          if (this.activeTab === 0) {
            this.presetGrid()
          } else {
            this.customPicker()
          }
        }.width('100%').padding({ left: AppUiMetrics.sheetPadding, right: AppUiMetrics.sheetPadding,
          top: 4, bottom: 24 })
      }.width('100%').constraintSize({ maxHeight: this.scrollMaxHeight() })
        .scrollBar(BarState.Auto)
    }.width('100%').backgroundColor(this.pal().sheetBg).borderRadius(20)
  }

  @Builder tabBtn(label: string, idx: number) {
    Button({ type: ButtonType.Normal }) {
      Text(label).fontSize(14).fontFamily(AppConfig.fontFamily)
        .fontColor(idx === this.activeTab ? appUiButtonText(this.accentColor) : this.pal().text2)
        .fontWeight(idx === this.activeTab ? FontWeight.Medium : FontWeight.Normal)
    }.layoutWeight(1).constraintSize({ minHeight: AppUiMetrics.minTouchTarget })
      .padding({ left: 12, right: 12, top: 10, bottom: 10 }).borderRadius(12)
      .backgroundColor(idx === this.activeTab ? appUiButtonFill(this.accentColor) : this.pal().surface)
      .focusable(true).accessibilityText(label).accessibilitySelected(idx === this.activeTab)
      .onClick(() => { this.activeTab = idx; })
  }

  @Builder presetGrid() {
    Flex({ wrap: FlexWrap.Wrap, alignItems: ItemAlign.Start,
      space: { main: LengthMetrics.vp(8), cross: LengthMetrics.vp(12) } }) {
      ForEach(COLOR_PRESETS, (preset: ColorPreset) => {
        Button({ type: ButtonType.Normal }) {
          Column({ space: 6 }) {
            Stack() {
              Column().width(48).height(48).borderRadius(14).backgroundColor(preset.hex)
                .border({ width: this.selectedHex === preset.hex ? 3 : 1,
                  color: this.selectedHex === preset.hex ? this.pal().text : this.pal().cardBorder })
              if (this.selectedHex === preset.hex) {
                SymbolGlyph($r('sys.symbol.checkmark')).fontSize(20)
                  .fontColor([appUiButtonText(preset.hex)])
              }
            }.width('100%').height(48).accessibilityLevel('no')
            Text(preset.pantone).fontSize(12).fontFamily(AppConfig.fontFamily)
              .fontColor(this.pal().text2).width('100%').textAlign(TextAlign.Center)
              .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
          }.width('100%').padding({ top: 4, bottom: 4 })
        }.width(this.presetCardWidth()).flexShrink(0).padding(0)
          .constraintSize({ minHeight: AppUiMetrics.minTouchTarget })
          .backgroundColor(Color.Transparent).borderRadius(12).focusable(true)
          .accessibilityText(preset.name + '，' + preset.pantone + '，' + preset.hex)
          .accessibilitySelected(this.selectedHex === preset.hex)
          .onClick(() => { this.selectPreset(preset.hex); })
      })
    }.width('100%')
  }

  @Builder customPicker() {
    Column({ space: 12 }) {
      Text('色板').fontSize(12).fontColor(this.pal().text2).fontFamily(AppConfig.fontFamily)
        .fontWeight(FontWeight.Medium).width('100%')
      Stack() {
        Column().width('100%').height('100%').borderRadius(12).backgroundColor(this.getHueColor())
        Column().width('100%').height('100%').borderRadius(12)
          .linearGradient({ direction: GradientDirection.Right,
            colors: [['#FFFFFF', 0], ['rgba(255,255,255,0)', 1]] })
        Column().width('100%').height('100%').borderRadius(12)
          .linearGradient({ direction: GradientDirection.Bottom,
            colors: [['rgba(0,0,0,0)', 0], ['#000000', 1]] })
        Column().width(12).height(12).borderRadius(6).backgroundColor(this.selectedHex)
          .border({ width: 2, color: '#FFFFFF', style: BorderStyle.Solid })
          .shadow({ radius: 4, color: 'rgba(0,0,0,0.3)' })
          .position({ x: `${this.sat}%`.toString(), y: `${100 - this.bri}%` })
          .translate({ x: '-50%', y: '-50%' })
      }.width('100%').height(180).borderRadius(12)
        .accessibilityLevel('no')
        .onAreaChange((_oldArea: Area, newArea: Area): void => {
          const width: number = Number(newArea.width);
          const height: number = Number(newArea.height);
          this.colorPlaneWidth = Number.isFinite(width) && width > 0 ? width : 0;
          this.colorPlaneHeight = Number.isFinite(height) && height > 0 ? height : 0;
        })
        .gesture(
          GestureGroup(GestureMode.Parallel,
            PanGesture({ direction: PanDirection.All, distance: 5 })
              .onActionStart((event: GestureEvent) => { this.onColorPlaneGesture(event); })
              .onActionUpdate((event: GestureEvent) => { this.onColorPlaneGesture(event); }),
            TapGesture({ count: 1 })
              .onAction((event: GestureEvent) => { this.onColorPlaneGesture(event); })
          )
        )
      Column() {
        this.sliderLabel('色相', this.hue.toString() + '°')
        Stack() {
          Column().width('100%').height(6).borderRadius(3)
            .linearGradient({ direction: GradientDirection.Right,
              colors: [['#FF0000', 0], ['#FFFF00', 0.17], ['#00FF00', 0.33],
                ['#00FFFF', 0.5], ['#0000FF', 0.67], ['#FF00FF', 0.83], ['#FF0000', 1]] })
            .accessibilityLevel('no')
          Slider({ style: SliderStyle.OutSet, value: this.hue, min: 0, max: 360, step: 1 })
            .width('100%').height(AppUiMetrics.minTouchTarget)
            .trackColor(Color.Transparent).selectedColor(Color.Transparent).blockColor(this.getHueColor())
            .showSteps(false).showTips(true, this.hue.toString() + '°')
            .focusable(true).accessibilityText('色相')
            .onChange((value: number): void => { this.applyHsvColor(value, this.sat, this.bri); })
        }.width('100%').height(AppUiMetrics.minTouchTarget)
      }.width('100%')
      Column() {
        this.sliderLabel('饱和度', this.sat.toString() + '%')
        Slider({ style: SliderStyle.OutSet, value: this.sat, min: 0, max: 100, step: 1 })
          .width('100%').height(AppUiMetrics.minTouchTarget).selectedColor(this.getHueColor())
          .showSteps(false).showTips(true, this.sat.toString() + '%')
          .focusable(true).accessibilityText('饱和度')
          .onChange((value: number): void => { this.applyHsvColor(this.hue, value, this.bri); })
      }.width('100%')
      Column() {
        this.sliderLabel('亮度', this.bri.toString() + '%')
        Slider({ style: SliderStyle.OutSet, value: this.bri, min: 0, max: 100, step: 1 })
          .width('100%').height(AppUiMetrics.minTouchTarget).selectedColor(this.getHueColor())
          .showSteps(false).showTips(true, this.bri.toString() + '%')
          .focusable(true).accessibilityText('亮度')
          .onChange((value: number): void => { this.applyHsvColor(this.hue, this.sat, value); })
      }.width('100%')
      Column() {
        this.sliderLabel('灰阶', this.gray.toString())
        Slider({ style: SliderStyle.OutSet, value: this.gray, min: 0, max: 255, step: 1 })
          .width('100%').height(AppUiMetrics.minTouchTarget).trackColor(this.pal().surface)
          .selectedColor(appUiButtonFill(this.selectedHex))
          .showSteps(false).showTips(true, this.gray.toString())
          .focusable(true).accessibilityText('灰阶')
          .onChange((value: number) => { this.gray = value; this.applyGray(); })
      }.width('100%')
    }.width('100%')
  }

  @Builder sliderLabel(label: string, value: string) {
    Flex({ wrap: FlexWrap.Wrap, alignItems: ItemAlign.Center,
      space: { main: LengthMetrics.vp(8), cross: LengthMetrics.vp(4) } }) {
      Text(label).fontSize(14).fontFamily(AppConfig.fontFamily).fontColor(this.pal().text)
      Text(value).fontSize(12).fontFamily(AppConfig.fontFamily).fontColor(this.pal().text2)
    }.width('100%')
  }
}
