import { GlassmorphicCard } from './GlassmorphicCard';
import { GatewayConfig } from '../models/RemoteHost';

@Component
export struct GatewayConfigForm {
  @Prop config: GatewayConfig | null = null;
  @State currentConfig: GatewayConfig = { host: '', port: 443, username: '', password: '', bypassLocal: false };
  @State isEnabled: boolean = false;
  onChange?: (config: GatewayConfig | null) => void;

  aboutToAppear(): void {
    if (this.config) {
      this.currentConfig = { ...this.config };
      this.isEnabled = this.config.host.length > 0;
    }
  }

  build() {
    GlassmorphicCard({ borderRadius: 16, paddingSize: 16 }) {
      Column() {
        Row() {
          Text('RD 网关设置')
            .fontSize(16).fontWeight(FontWeight.SemiBold).fontColor('#FFFFFF')
          Blank()
          Toggle({ type: ToggleType.Switch, isOn: this.isEnabled })
            .onChange((isOn: boolean) => {
              this.isEnabled = isOn;
              if (!isOn) {
                this.currentConfig.host = '';
                this.onChange?.(null);
              } else {
                this.onChange?.({ ...this.currentConfig });
              }
            })
        }
        .width('100%')

        if (this.isEnabled) {
          Text('通过 RD 网关服务器连接远程主机')
            .fontSize(12).fontColor('rgba(255,255,255,0.4)')
            .margin({ top: 2, bottom: 12 })

          Text('网关主机')
            .fontSize(13).fontColor('rgba(255,255,255,0.7)')
            .margin({ bottom: 4 })
          TextInput({ placeholder: 'gateway.example.com', text: this.currentConfig.host })
            .width('100%').height(40)
            .backgroundColor('rgba(255,255,255,0.08)')
            .fontColor('#FFFFFF')
            .placeholderColor('rgba(255,255,255,0.3)')
            .borderRadius(10)
            .margin({ bottom: 10 })
            .onChange((value: string) => {
              this.currentConfig.host = value;
              this.onChange?.({ ...this.currentConfig });
            })

          Text('端口')
            .fontSize(13).fontColor('rgba(255,255,255,0.7)')
            .margin({ bottom: 4 })
          TextInput({ placeholder: '443', text: String(this.currentConfig.port) })
            .width('100%').height(40)
            .backgroundColor('rgba(255,255,255,0.08)')
            .fontColor('#FFFFFF')
            .placeholderColor('rgba(255,255,255,0.3)')
            .borderRadius(10)
            .margin({ bottom: 10 })
            .onChange((value: string) => {
              const port = parseInt(value, 10);
              if (!isNaN(port)) {
                this.currentConfig.port = port;
                this.onChange?.({ ...this.currentConfig });
              }
            })

          Text('用户名')
            .fontSize(13).fontColor('rgba(255,255,255,0.7)')
            .margin({ bottom: 4 })
          TextInput({ placeholder: 'domain\\user', text: this.currentConfig.username })
            .width('100%').height(40)
            .backgroundColor('rgba(255,255,255,0.08)')
            .fontColor('#FFFFFF')
            .placeholderColor('rgba(255,255,255,0.3)')
            .borderRadius(10)
            .margin({ bottom: 10 })
            .onChange((value: string) => {
              this.currentConfig.username = value;
              this.onChange?.({ ...this.currentConfig });
            })

          if (this.config === null || this.config.password.length === 0) {
            Text('密码（可选）')
              .fontSize(13).fontColor('rgba(255,255,255,0.7)')
              .margin({ bottom: 4 })
            TextInput({ placeholder: '••••••••', text: this.currentConfig.password })
              .width('100%').height(40)
              .backgroundColor('rgba(255,255,255,0.08)')
              .fontColor('#FFFFFF')
              .placeholderColor('rgba(255,255,255,0.3)')
              .borderRadius(10)
              .type(InputType.Password)
              .margin({ bottom: 12 })
              .onChange((value: string) => {
                this.currentConfig.password = value;
                this.onChange?.({ ...this.currentConfig });
              })
          }

          Row() {
            Text('绕过本地地址的网关')
              .fontSize(14).fontColor('#FFFFFF')
              .layoutWeight(1)
            Toggle({ type: ToggleType.Switch, isOn: this.currentConfig.bypassLocal })
              .onChange((isOn: boolean) => {
                this.currentConfig.bypassLocal = isOn;
                this.onChange?.({ ...this.currentConfig });
              })
          }
          .width('100%')
          .margin({ top: 4 })
        }
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    }
  }
}
