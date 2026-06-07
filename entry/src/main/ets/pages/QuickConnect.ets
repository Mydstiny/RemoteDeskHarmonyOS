import { ImmersiveBackground } from '../components/ImmersiveBackground';
import { GlassmorphicCard } from '../components/GlassmorphicCard';
import { ProtocolSelector, ProtocolType } from '../components/ProtocolSelector';
import { HostSyncService } from '../services/HostSyncService';
import { AuthService } from '../services/AuthService';
import { RemoteHost, createDefaultRemoteHost, SessionQuality, KeyboardMode } from '../models/RemoteHost';
import { router, promptAction } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';

@Entry
@Component
struct QuickConnect {
  @State hostInput: string = '';
  @State portInput: string = '3389';
  @State username: string = '';
  @State password: string = '';
  @State protocol: ProtocolType = ProtocolType.RDP;
  @State recentConnections: Array<{ label: string; host: string; port: number; protocol: string }> = [];
  @State showRecent: boolean = false;
  @State isConnecting: boolean = false;

  private syncService: HostSyncService = HostSyncService.getInstance();
  private authService: AuthService = AuthService.getInstance();

  aboutToAppear(): void {
    this.loadRecentConnections();
  }

  private async loadRecentConnections(): Promise<void> {
    try {
      const user = this.authService.getUser();
      const userId = user?.unionId ?? 'local';
      const hosts = await this.syncService.loadFromCloud(userId);
      this.recentConnections = hosts
        .sort((a, b) => b.lastConnected - a.lastConnected)
        .slice(0, 5)
        .map((h) => ({
          label: h.label,
          host: h.host,
          port: h.port,
          protocol: h.protocol
        }));
    } catch (err) {
      console.error('Failed to load recent connections: ' + err);
    }
  }

  build() {
    ImmersiveBackground({
      contentBuilder: () => {
        this.MainContent()
      }
    })
  }

  @Builder
  MainContent() {
    Column() {
      Row() {
        Image($r('app.media.ic_back'))
          .width(24).height(24)
          .fillColor('#FFFFFF')
          .onClick(() => { router.back(); })
        Text('快速连接')
          .fontSize(20).fontWeight(FontWeight.Bold).fontColor('#FFFFFF')
          .margin({ left: 12 })
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: 16 })
      .alignItems(VerticalAlign.Center)

      GlassmorphicCard({ borderRadius: 24, paddingSize: 20 }) {
        Column() {
          ProtocolSelector({
            selectedProtocol: this.protocol,
            onProtocolChange: (p: ProtocolType) => {
              this.protocol = p;
              this.portInput = p === ProtocolType.RDP ? '3389' : '21116';
            }
          })

          Text('主机地址')
            .fontSize(13).fontColor('rgba(255,255,255,0.5)')
            .margin({ top: 12, bottom: 6 })
          TextInput({ placeholder: 'IP 地址或域名:端口', text: this.hostInput })
            .width('100%').height(48)
            .backgroundColor('rgba(255,255,255,0.08)')
            .fontColor('#FFFFFF')
            .placeholderColor('rgba(255,255,255,0.4)')
            .borderRadius(12)
            .onChange((v: string) => {
              this.hostInput = v;
              if (v.includes(':')) {
                const parts = v.split(':');
                const portNum = parseInt(parts[parts.length - 1], 10);
                if (!isNaN(portNum)) {
                  this.portInput = String(portNum);
                }
              }
            })

          Row() {
            Column() {
              Text('端口')
                .fontSize(13).fontColor('rgba(255,255,255,0.5)')
                .margin({ bottom: 6 })
              TextInput({ placeholder: '3389', text: this.portInput })
                .width('100%').height(48)
                .backgroundColor('rgba(255,255,255,0.08)')
                .fontColor('#FFFFFF')
                .placeholderColor('rgba(255,255,255,0.4)')
                .borderRadius(12)
                .type(InputType.Number)
                .onChange((v: string) => { this.portInput = v; })
            }
            .layoutWeight(1)

            Column() {
              Text('用户名（可选）')
                .fontSize(13).fontColor('rgba(255,255,255,0.5)')
                .margin({ bottom: 6 })
              TextInput({ placeholder: '用户名', text: this.username })
                .width('100%').height(48)
                .backgroundColor('rgba(255,255,255,0.08)')
                .fontColor('#FFFFFF')
                .placeholderColor('rgba(255,255,255,0.4)')
                .borderRadius(12)
                .onChange((v: string) => { this.username = v; })
            }
            .layoutWeight(1)
            .margin({ left: 8 })
          }

          Text('密码（可选）')
            .fontSize(13).fontColor('rgba(255,255,255,0.5)')
            .margin({ top: 8, bottom: 6 })
          TextInput({ placeholder: '登录密码', text: this.password })
            .width('100%').height(48)
            .backgroundColor('rgba(255,255,255,0.08)')
            .fontColor('#FFFFFF')
            .placeholderColor('rgba(255,255,255,0.4)')
            .borderRadius(12)
            .type(InputType.Password)
            .onChange((v: string) => { this.password = v; })

          Button('连接')
            .width('100%').height(52)
            .borderRadius(16)
            .backgroundColor('#6677ff')
            .fontColor('#FFFFFF')
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .margin({ top: 20 })
            .enabled(!this.isConnecting && this.hostInput.length > 0)
            .onClick(() => {
              this.handleConnect();
            })
        }
        .width('100%')
      }
      .margin({ left: 16, right: 16, top: 16 })

      if (this.recentConnections.length > 0) {
        Text('最近连接')
          .fontSize(15).fontWeight(FontWeight.SemiBold).fontColor('#FFFFFF')
          .margin({ top: 16, left: 20, bottom: 8 })

        Column() {
          ForEach(this.recentConnections, (conn: { label: string; host: string; port: number; protocol: string }) => {
            GlassmorphicCard({ borderRadius: 12, paddingSize: 12 }) {
              Row() {
                Column() {
                  Text(conn.label)
                    .fontSize(15).fontWeight(FontWeight.Medium).fontColor('#FFFFFF')
                  Text(conn.host + ':' + conn.port + ' · ' + conn.protocol.toUpperCase())
                    .fontSize(12).fontColor('rgba(255,255,255,0.5)')
                    .margin({ top: 2 })
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)

                Text('连接')
                  .fontSize(13).fontColor('#6677ff')
              }
              .width('100%')
              .alignItems(VerticalAlign.Center)
            }
            .margin({ left: 16, right: 16, bottom: 6 })
            .onClick(() => {
              this.hostInput = conn.host;
              this.portInput = String(conn.port);
              this.protocol = conn.protocol === 'rustdesk' ? ProtocolType.RUSTDESK : ProtocolType.RDP;
              this.handleConnect();
            })
          })
        }
        .width('100%')
      }
    }
    .width('100%').height('100%')
  }

  private handleConnect(): void {
    if (this.hostInput.length === 0) return;
    this.isConnecting = true;

    const port = parseInt(this.portInput, 10);
    const host = this.hostInput.includes(':') ? this.hostInput.split(':')[0] : this.hostInput;

    router.pushUrl({
      url: 'pages/RemoteDesktop',
      params: {
        host: host,
        port: isNaN(port) ? 3389 : port,
        username: this.username,
        password: this.password,
        protocol: this.protocol
      }
    });
    this.isConnecting = false;
  }
}
