import { GlassmorphicCard } from './GlassmorphicCard';
import { SessionQuality } from '../models/RemoteHost';

interface QualityOption {
  value: SessionQuality;
  label: string;
  description: string;
  icon: string;
  color: string;
}

@Component
export struct SessionQualityPicker {
  @Prop selected: SessionQuality = SessionQuality.AUTO;
  @State currentSelected: SessionQuality = SessionQuality.AUTO;
  onChange?: (value: SessionQuality) => void;

  private options: QualityOption[] = [
    {
      value: SessionQuality.AUTO,
      label: '自动',
      description: '根据网络状况自适应调整画质与性能',
      icon: '⚡',
      color: '#6677ff'
    },
    {
      value: SessionQuality.BEST_QUALITY,
      label: '最佳画质',
      description: '高色彩深度 (32bpp)、GFX 加速、流畅动画',
      icon: '🖥️',
      color: '#51CF66'
    },
    {
      value: SessionQuality.BEST_PERFORMANCE,
      label: '最佳性能',
      description: '低带宽模式、减少色彩深度 (16bpp)、关闭视觉特效',
      icon: '🚀',
      color: '#FF6B6B'
    }
  ];

  aboutToAppear(): void {
    this.currentSelected = this.selected;
  }

  build() {
    Column() {
      Text('选择会话质量')
        .fontSize(18).fontWeight(FontWeight.Bold).fontColor('#FFFFFF')
        .margin({ bottom: 16 })

      ForEach(this.options, (opt: QualityOption) => {
        GlassmorphicCard({
          borderRadius: 16,
          paddingSize: 14
        }) {
          Row() {
            Text(opt.icon)
              .fontSize(28)
              .margin({ right: 12 })

            Column() {
              Text(opt.label)
                .fontSize(16).fontWeight(FontWeight.SemiBold).fontColor('#FFFFFF')

              Text(opt.description)
                .fontSize(12).fontColor('rgba(255,255,255,0.5)')
                .margin({ top: 4 })
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)

            if (this.currentSelected === opt.value) {
              Column()
                .width(22).height(22)
                .borderRadius(11)
                .backgroundColor(opt.color)
                .border({ width: 2, color: '#FFFFFF' })
            } else {
              Column()
                .width(22).height(22)
                .borderRadius(11)
                .border({ width: 2, color: 'rgba(255,255,255,0.3)' })
            }
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)
        }
        .margin({ bottom: 10 })
        .onClick(() => {
          this.currentSelected = opt.value;
          this.onChange?.(opt.value);
        })
      })
    }
    .width('100%')
    .padding(16)
  }
}
