import { GlassmorphicCard } from './GlassmorphicCard';
import { KeyboardMode } from '../models/RemoteHost';

interface KeyboardOption {
  value: KeyboardMode;
  label: string;
  description: string;
  mappings: string[];
}

@Component
export struct KeyboardMappingPicker {
  @Prop selected: KeyboardMode = KeyboardMode.GENERIC;
  @State currentSelected: KeyboardMode = KeyboardMode.GENERIC;
  onChange?: (mode: KeyboardMode) => void;

  private options: KeyboardOption[] = [
    {
      value: KeyboardMode.GENERIC,
      label: '通用模式',
      description: '标准键盘映射，适配大多数系统',
      mappings: ['标准按键布局', '无修饰键转换']
    },
    {
      value: KeyboardMode.WINDOWS,
      label: 'Windows 模式',
      description: '原生 Windows 键盘映射',
      mappings: ['Win 键 → Win', 'Alt → Alt', 'Ctrl → Ctrl']
    },
    {
      value: KeyboardMode.MACOS,
      label: 'macOS 模式',
      description: 'macOS 键盘映射（Command/Option 适配）',
      mappings: ['Cmd → Win', 'Option → Alt', 'Ctrl → Ctrl (RDP)']
    }
  ];

  aboutToAppear(): void {
    this.currentSelected = this.selected;
  }

  build() {
    Column() {
      Text('键盘映射模式')
        .fontSize(18).fontWeight(FontWeight.Bold).fontColor('#FFFFFF')
        .margin({ bottom: 16 })

      Text('选择键盘映射方式以匹配您的物理键盘布局')
        .fontSize(13).fontColor('rgba(255,255,255,0.5)')
        .margin({ bottom: 16 })

      ForEach(this.options, (opt: KeyboardOption) => {
        GlassmorphicCard({
          borderRadius: 16,
          paddingSize: 14
        }) {
          Column() {
            Row() {
              Column() {
                Image($r('app.media.ic_keyboard'))
                  .width(28).height(28)
                  .fillColor(this.currentSelected === opt.value ? '#6677ff' : 'rgba(255,255,255,0.6)')
              }
              .width(40).height(40)
              .borderRadius(10)
              .backgroundColor(this.currentSelected === opt.value
                ? 'rgba(102,119,255,0.2)' : 'rgba(255,255,255,0.06)')
              .justifyContent(FlexAlign.Center)
              .alignItems(HorizontalAlign.Center)

              Column() {
                Text(opt.label)
                  .fontSize(16).fontWeight(FontWeight.SemiBold).fontColor('#FFFFFF')
                  .margin({ left: 10 })
                Text(opt.description)
                  .fontSize(12).fontColor('rgba(255,255,255,0.4)')
                  .margin({ left: 10, top: 2 })
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)

              if (this.currentSelected === opt.value) {
                Column()
                  .width(22).height(22)
                  .borderRadius(11)
                  .backgroundColor('#6677ff')
                  .border({ width: 2, color: '#FFFFFF' })
              }
            }
            .width('100%')
            .alignItems(VerticalAlign.Center)

            if (this.currentSelected === opt.value) {
              Column() {
                ForEach(opt.mappings, (mapping: string) => {
                  Row() {
                    Text('⌨')
                      .fontSize(12).margin({ right: 6 })
                    Text(mapping)
                      .fontSize(12).fontColor('rgba(255,255,255,0.6)')
                  }
                  .margin({ top: 4 })
                  .alignItems(VerticalAlign.Center)
                })
              }
              .margin({ top: 10 })
              .padding({ left: 50 })
              .width('100%')
              .alignItems(HorizontalAlign.Start)
            }
          }
          .width('100%')
        }
        .margin({ bottom: 10 })
        .onClick(() => {
          this.currentSelected = opt.value;
          this.onChange?.(opt.value);
        })
      })

      Text('提示：键盘映射仅在 RDP 协议中完整生效')
        .fontSize(11).fontColor('rgba(255,255,255,0.3)')
        .margin({ top: 12 })
    }
    .width('100%')
    .padding(16)
  }
}
