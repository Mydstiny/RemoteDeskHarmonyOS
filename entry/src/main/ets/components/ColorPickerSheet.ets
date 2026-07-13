/**
 * ColorPickerSheet.ets v2 — 二维色彩空间 + 灰阶合并面板 + 预设色系
 */
import { COLOR_PRESETS, ColorPreset, Palette, buildDark, buildLight } from '../common/Theme';
import { preferences } from '@kit.ArkData';
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
    const s: number = Math.round(Math.max(0, Math.min(100, (x / w) * 100)));
    const b: number = Math.round(Math.max(0, Math.min(100, 100 - (y / h) * 100)));
    this.applyHsvColor(this.hue, s, b);
  }

  build() {
    Column() {
      // 标题 + 预览
      Row() {
        Text('主题色').fontSize(19).fontWeight(FontWeight.Bold).fontColor(this.pal().text)
        Blank()
        Column()
          .width(36).height(36).borderRadius(12)
          .backgroundColor(this.selectedHex)
          .border({ width: 2, color: this.pal().cardBorder, style: BorderStyle.Solid })
      }.width('100%').padding({ left: 24, right: 24, top: 20 }).margin({ bottom: 12 })

      // Tab: 预设 / 自定义
      Row() {
        this.tabBtn('预设色系', 0)
        this.tabBtn('自定义', 1)
      }.width('100%').padding({ left: 24, right: 24 }).margin({ bottom: 14 })

      if (this.activeTab === 0) {
        this.presetGrid()
      } else {
        this.customPicker()
      }
      Blank().height(24)
    }.width('100%')
    .backgroundColor(this.pal().bg).borderRadius(20)
  }

  @Builder tabBtn(label: string, idx: number) {
    Text(label).fontSize(14)
      .fontColor(idx === this.activeTab ? this.pal().text : this.pal().text3)
      .fontWeight(idx === this.activeTab ? FontWeight.Medium : FontWeight.Normal)
      .padding({ left: 16, right: 16, top: 8, bottom: 8 })
      .borderRadius(8)
      .backgroundColor(idx === this.activeTab ? this.pal().surface : Color.Transparent)
      .onClick(() => { this.activeTab = idx; })
  }

  @Builder presetGrid() {
    Grid() {
      ForEach(COLOR_PRESETS, (preset: ColorPreset) => {
        GridItem() {
          Column() {
            Column().width(48).height(48).borderRadius(14).backgroundColor(preset.hex)
              .border({ width: this.selectedHex === preset.hex ? 3 : 0, color: this.pal().text })
            Text(preset.pantone).fontSize(9).fontColor(this.pal().text3).margin({ top: 4 }).maxLines(1)
          }.alignItems(HorizontalAlign.Center)
          .onClick(() => { this.selectPreset(preset.hex); })
        }
      })
    }
    .columnsTemplate('1fr 1fr 1fr 1fr').rowsGap(14).columnsGap(8)
    .width('100%').padding({ left: 24, right: 24 }).height(260)
  }

  @Builder customPicker() {
    Column() {
      // ===== 二维色板 (Saturation × Brightness) =====
      Text('色板').fontSize(12).fontColor(this.pal().text3).fontWeight(FontWeight.Medium).margin({ bottom: 6 }).width('90%')
      Stack() {
        // 背景：纯色 hue
        Column()
          .width('100%').height('100%')
          .borderRadius(12)
          .backgroundColor(this.getHueColor())
        // 白→透明 水平渐变 (饱和度)
        Column()
          .width('100%').height('100%')
          .borderRadius(12)
          .linearGradient({ direction: GradientDirection.Right, colors: [['#FFFFFF', 0], ['rgba(255,255,255,0)', 1]] })
        // 透明→黑 垂直渐变 (亮度)
        Column()
          .width('100%').height('100%')
          .borderRadius(12)
          .linearGradient({ direction: GradientDirection.Bottom, colors: [['rgba(0,0,0,0)', 0], ['#000000', 1]] })
        // 选取指示点
        Column()
          .width(12).height(12).borderRadius(6)
          .backgroundColor(this.selectedHex)
          .border({ width: 2, color: '#FFFFFF', style: BorderStyle.Solid })
          .shadow({ radius: 4, color: 'rgba(0,0,0,0.3)' })
          .position({ x: `${this.sat}%`.toString(), y: `${100 - this.bri}%` })
          .translate({ x: '-50%', y: '-50%' })
      }
      .width('90%').height(180).borderRadius(12)
      .gesture(
        GestureGroup(GestureMode.Parallel,
          PanGesture({ direction: PanDirection.All, distance: 5 })
            .onActionStart((event: GestureEvent) => {
              const x = event.fingerList[0].localX;
              const y = event.fingerList[0].localY;
              this.onSatBriTap(x, y, 300, 180);
            })
            .onActionUpdate((event: GestureEvent) => {
              const x = event.fingerList[0].localX;
              const y = event.fingerList[0].localY;
              this.onSatBriTap(x, y, 300, 180);
            }),
          TapGesture({ count: 1 })
            .onAction((event: GestureEvent) => {
              const x = event.fingerList[0].localX;
              const y = event.fingerList[0].localY;
              this.onSatBriTap(x, y, 300, 180);
            })
        )
      )
      .margin({ bottom: 16 })

      // ===== 色相滑块 (彩虹条) =====
      Row() {
        Text('色相').fontSize(12).fontColor(this.pal().text3).width(36)
        Column()
          .layoutWeight(1).height(28).borderRadius(14)
          .linearGradient({
            direction: GradientDirection.Right,
            colors: [
              ['#FF0000',0], ['#FFFF00',0.17], ['#00FF00',0.33],
              ['#00FFFF',0.5], ['#0000FF',0.67], ['#FF00FF',0.83], ['#FF0000',1]
            ]
          })
          .margin({ left: 8, right: 8 })
          .gesture(
            GestureGroup(GestureMode.Parallel,
              PanGesture({ direction: PanDirection.Horizontal, distance: 5 })
                .onActionStart((event: GestureEvent) => {
                  const ratio: number = Math.max(0, Math.min(1, event.fingerList[0].localX / 280));
                  this.applyHsvColor(Math.round(ratio * 360), this.sat, this.bri);
                })
                .onActionUpdate((event: GestureEvent) => {
                  const ratio: number = Math.max(0, Math.min(1, event.fingerList[0].localX / 280));
                  this.applyHsvColor(Math.round(ratio * 360), this.sat, this.bri);
                }),
              TapGesture({ count: 1 })
                .onAction((event: GestureEvent) => {
                  const ratio: number = Math.max(0, Math.min(1, event.fingerList[0].localX / 280));
                  this.applyHsvColor(Math.round(ratio * 360), this.sat, this.bri);
                })
            )
          )
      }.width('90%').height(36).margin({ bottom: 14 })

      // ===== 灰阶滑块 (不重置 RGB) =====
      Row() {
        Text('灰阶').fontSize(12).fontColor(this.pal().text3).width(36)
        Slider({ style: SliderStyle.OutSet, value: this.gray, min: 0, max: 255, step: 1 })
          .layoutWeight(1).margin({ left: 8, right: 8 })
          .trackColor('#E0E0E0')
          .selectedColor(this.selectedHex)
          .showSteps(false)
          .onChange((value: number) => { this.gray = value; this.applyGray(); })
      }.width('90%').height(36).margin({ bottom: 14 })

      // 色值显示
      Row() {
        Text(this.selectedHex).fontSize(16).fontFamily('monospace').fontColor(this.pal().text)
        Blank()
        Text(`H:${this.hue}° S:${this.sat}% B:${this.bri}%`)
          .fontSize(11).fontColor(this.pal().text3)
      }.width('90%').margin({ top: 4 })
    }.width('100%')
  }
}
