import { sensor } from '@kit.SensorServiceKit';
import { BusinessError } from '@kit.BasicServicesKit';

export enum TransparencyLevel {
  STRONG = 0.85,
  BALANCED = 0.70,
  WEAK = 0.55
}

@Component
export struct FloatNavigation {
  @State currentTab: number = 0;
  @State navTransparency: number = TransparencyLevel.BALANCED;
  @Prop bottomAvoidHeight: number = 0;
  onTabChange?: (index: number) => void;

  private tabs: Array<{ icon: Resource; label: string }> = [
    { icon: $r('app.media.ic_hosts'), label: '主机' },
    { icon: $r('app.media.ic_connection'), label: '连接' },
    { icon: $r('app.media.ic_settings'), label: '设置' }
  ];

  build() {
    Column() {
      Row() {
        ForEach(this.tabs, (tab: { icon: Resource; label: string }, index: number) => {
          Column() {
            Image(tab.icon)
              .width(24).height(24)
              .fillColor(index === this.currentTab ? '#FFFFFF' : 'rgba(255,255,255,0.6)')
            Text(tab.label)
              .fontSize(10)
              .fontColor(index === this.currentTab ? '#FFFFFF' : 'rgba(255,255,255,0.6)')
              .margin({ top: 2 })
          }
          .layoutWeight(1)
          .onClick(() => {
            this.currentTab = index;
            this.onTabChange?.(index);
            this.triggerHaptic();
          })
        })
      }
      .width('90%').height(64)
      .justifyContent(FlexAlign.SpaceAround)
      .borderRadius(24)
      .backgroundBlurStyle(BlurStyle.REGULAR)
      .backgroundColor(`rgba(30, 30, 40, ${this.navTransparency})`)
      .border({
        width: 0.5,
        color: 'rgba(255, 255, 255, 0.1)',
        style: BorderStyle.Solid
      })
      .shadow({
        radius: 30,
        color: 'rgba(0, 0, 0, 0.3)',
        offsetY: 8
      })
    }
    .width('100%')
    .position({ x: '50%', y: '90%' })
    .translate({ x: '-50%', y: 0 })
    .animation({ duration: 300, curve: Curve.EaseOut })
  }

  private triggerHaptic(): void {
    try {
      sensor.vibrator.startVibration({
        type: 'time',
        duration: 30
      }, { id: 0 });
    } catch (err) {
      console.error('Haptic feedback failed: ' + err);
    }
  }
}
