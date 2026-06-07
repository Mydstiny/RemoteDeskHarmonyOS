import { GlassmorphicCard } from './GlassmorphicCard';
import { DisplayConfig } from '../models/RemoteHost';

interface ResolutionPreset {
  label: string;
  width: number;
  height: number;
}

@Component
export struct DisplayConfigSheet {
  @Prop config: DisplayConfig = { width: 1920, height: 1080, useAllMonitors: false, colorDepth: 32 };
  @State currentConfig: DisplayConfig = { width: 1920, height: 1080, useAllMonitors: false, colorDepth: 32 };
  @State customWidth: string = '1920';
  @State customHeight: string = '1080';
  onChange?: (config: DisplayConfig) => void;

  private presets: ResolutionPreset[] = [
    { label: '3840 × 2160 (4K)', width: 3840, height: 2160 },
    { label: '2560 × 1440 (2K)', width: 2560, height: 1440 },
    { label: '1920 × 1080 (全高清)', width: 1920, height: 1080 },
    { label: '1280 × 720 (高清)', width: 1280, height: 720 },
    { label: '1024 × 768 (XGA)', width: 1024, height: 768 },
  ];

  aboutToAppear(): void {
    this.currentConfig = { ...this.config };
    this.customWidth = String(this.config.width);
    this.customHeight = String(this.config.height);
  }

  build() {
    Column() {
      Text('显示设置')
        .fontSize(18).fontWeight(FontWeight.Bold).fontColor('#FFFFFF')
        .margin({ bottom: 16 })

      GlassmorphicCard({ borderRadius: 16, paddingSize: 14 }) {
        Column() {
          Text('使用所有显示器')
            .fontSize(15).fontColor('#FFFFFF')
          Text('启用后自动使用所有可用显示器')
            .fontSize(12).fontColor('rgba(255,255,255,0.5)')
            .margin({ top: 2 })

          Toggle({ type: ToggleType.Switch, isOn: this.currentConfig.useAllMonitors })
            .margin({ top: 8 })
            .onChange((isOn: boolean) => {
              this.currentConfig.useAllMonitors = isOn;
              this.emitChange();
            })
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }
      .margin({ bottom: 12 })

      Text('分辨率')
        .fontSize(15).fontWeight(FontWeight.SemiBold).fontColor('#FFFFFF')
        .margin({ bottom: 8 })

      ForEach(this.presets, (preset: ResolutionPreset) => {
        Row() {
          Text(preset.label)
            .fontSize(14).fontColor('#FFFFFF')
          Blank()
          if (this.currentConfig.width === preset.width && this.currentConfig.height === preset.height) {
            Text('✓')
              .fontSize(16).fontColor('#6677ff')
          }
        }
        .width('100%')
        .padding({ top: 8, bottom: 8 })
        .onClick(() => {
          this.currentConfig.width = preset.width;
          this.currentConfig.height = preset.height;
          this.customWidth = String(preset.width);
          this.customHeight = String(preset.height);
          this.emitChange();
        })
      })

      Row() {
        TextInput({ placeholder: '宽度', text: this.customWidth })
          .width(100).height(36)
          .backgroundColor('rgba(255,255,255,0.1)')
          .fontColor('#FFFFFF')
          .borderRadius(8)
          .onChange((value: string) => {
            this.customWidth = value;
          })

        Text('×')
          .fontSize(16).fontColor('rgba(255,255,255,0.5)')
          .margin({ left: 8, right: 8 })

        TextInput({ placeholder: '高度', text: this.customHeight })
          .width(100).height(36)
          .backgroundColor('rgba(255,255,255,0.1)')
          .fontColor('#FFFFFF')
          .borderRadius(8)
          .onChange((value: string) => {
            this.customHeight = value;
          })

        Button('应用')
          .height(36)
          .borderRadius(8)
          .backgroundColor('#6677ff')
          .fontColor('#FFFFFF')
          .fontSize(13)
          .margin({ left: 8 })
          .onClick(() => {
            const w = parseInt(this.customWidth, 10);
            const h = parseInt(this.customHeight, 10);
            if (!isNaN(w) && !isNaN(h) && w > 0 && h > 0) {
              this.currentConfig.width = w;
              this.currentConfig.height = h;
              this.emitChange();
            }
          })
      }
      .margin({ top: 12 })

      Text('色彩深度')
        .fontSize(15).fontWeight(FontWeight.SemiBold).fontColor('#FFFFFF')
        .margin({ top: 16, bottom: 8 })

      Row() {
        this.ColorDepthButton(16)
        this.ColorDepthButton(24)
        this.ColorDepthButton(32)
      }
      .width('100%')
      .justifyContent(FlexAlign.SpaceEvenly)
    }
    .width('100%')
    .padding(16)
  }

  @Builder
  ColorDepthButton(depth: number): void {
    Column() {
      Text(String(depth) + ' bpp')
        .fontSize(14).fontColor(this.currentConfig.colorDepth === depth ? '#FFFFFF' : 'rgba(255,255,255,0.6)')
    }
    .width(80).height(44)
    .backgroundColor(this.currentConfig.colorDepth === depth
      ? 'rgba(102,119,255,0.4)' : 'rgba(255,255,255,0.08)')
    .borderRadius(10)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .onClick(() => {
      this.currentConfig.colorDepth = depth;
      this.emitChange();
    })
  }

  private emitChange(): void {
    this.onChange?.({ ...this.currentConfig });
  }
}
