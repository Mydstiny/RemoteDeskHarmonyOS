import { window } from '@kit.ArkUI';
import { sensor } from '@kit.SensorServiceKit';
import { BusinessError } from '@kit.BasicServicesKit';

@Component
export struct ImmersiveBackground {
  @State lightIntensity: number = 0.6;
  @State dominantColor: string = '#1a1a2e';
  @StorageLink('currentTheme') theme: string = 'dark';

  aboutToAppear(): void {
    try {
      sensor.on(sensor.SensorId.AMBIENT_LIGHT, (data: sensor.AmbientLightResponse) => {
        const lux: number = data.light;
        this.lightIntensity = this.mapLuxToIntensity(lux);
      }, { interval: 1000000000 });
    } catch (err) {
      console.warn('Ambient light sensor unavailable, using default intensity');
    }
  }

  private mapLuxToIntensity(lux: number): number {
    if (lux < 50) return 0.85;
    if (lux < 200) return 0.70;
    if (lux < 500) return 0.50;
    return 0.30;
  }

  build() {
    Stack() {
      Column()
        .width('100%').height('100%')
        .backgroundColor(this.dominantColor)
        .overlay(
          Column()
            .width(300).height(300)
            .backgroundColor('#6677ff')
            .blur(120)
            .opacity(this.lightIntensity * 0.5)
            .position({ x: '50%', y: 100 })
        )
        .overlay(
          Column()
            .width(250).height(250)
            .backgroundColor('#ff6688')
            .blur(100)
            .opacity(this.lightIntensity * 0.4)
            .position({ x: '30%', y: '70%' })
        )
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])

      Column()
        .width('100%').height('100%')
        .linearGradient({
          direction: GradientDirection.Top,
          colors: [
            ['rgba(0,0,0,0.4)', 0.0],
            ['rgba(0,0,0,0.2)', 0.5],
            ['rgba(0,0,0,0.5)', 1.0]
          ]
        })
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])

      Column() {
        this.contentBuilder()
      }
      .width('100%').height('100%')
      .padding({ top: 44, bottom: 80 })
    }
    .width('100%').height('100%')
  }

  @BuilderParam contentBuilder: () => void;
}
