import { ImmersiveBackground } from '../components/ImmersiveBackground';
import { GlassmorphicCard } from '../components/GlassmorphicCard';
import { ProtocolSelector, ProtocolType } from '../components/ProtocolSelector';
import { HostSyncService, RemoteHost } from '../services/HostSyncService';
import { AuthService } from '../services/AuthService';
import { router, promptAction } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';

@Entry
@Component
struct ConnectionForm {
  @State label: string = '';
  @State host: string = '';
  @State port: number = 3389;
  @State username: string = '';
  @State password: string = '';
  @State protocol: ProtocolType = ProtocolType.RDP;
  @State isSaving: boolean = false;
  @State errorMessage: string = '';
  @State editHostId: string = '';

  private syncService: HostSyncService = HostSyncService.getInstance();
  private authService: AuthService = AuthService.getInstance();

  async aboutToAppear(): Promise<void> {
    const params = router.getParams() as Record<string, Object>;
    if (params && params['editHostId']) {
      this.editHostId = params['editHostId'] as string;
      await this.loadHostForEdit(this.editHostId);
    }
  }

  async loadHostForEdit(hostId: string): Promise<void> {
    try {
      const user = this.authService.getUser();
      const userId = user?.unionId ?? 'local';
      const hosts = await this.syncService.loadFromCloud(userId);
      const host = hosts.find((h) => h.id === hostId);
      if (host) {
        this.label = host.label;
        this.host = host.host;
        this.port = host.port;
        this.username = host.username;
        this.password = host.password;
        this.protocol = host.protocol as ProtocolType;
      }
    } catch (err) {
      console.error('Failed to load host for edit: ' + err);
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
          .onClick(() => {
            router.back();
          })
        Text(this.editHostId ? '编辑主机' : '添加主机')
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
              this.port = p === ProtocolType.RDP ? 3389 : 21116;
            }
          })

          this.FieldItem('主机名称', TextInput({
            placeholder: '例如: 我的办公电脑',
            text: this.label
          })
            .backgroundColor('rgba(255,255,255,0.08)')
            .borderRadius(12)
            .height(48)
            .fontColor('#FFFFFF')
            .placeholderColor('rgba(255,255,255,0.4)')
            .onChange((v: string) => { this.label = v; }))

          this.FieldItem('主机地址', TextInput({
            placeholder: 'IP 地址或域名',
            text: this.host
          })
            .backgroundColor('rgba(255,255,255,0.08)')
            .borderRadius(12)
            .height(48)
            .fontColor('#FFFFFF')
            .placeholderColor('rgba(255,255,255,0.4)')
            .onChange((v: string) => { this.host = v; }))

          Row() {
            Column() {
              Text('端口')
                .fontSize(13).fontColor('rgba(255,255,255,0.5)')
                .margin({ bottom: 6 })
              TextInput({ placeholder: '3389', text: this.port.toString() })
                .backgroundColor('rgba(255,255,255,0.08)')
                .borderRadius(12)
                .height(48)
                .fontColor('#FFFFFF')
                .placeholderColor('rgba(255,255,255,0.4)')
                .type(InputType.Number)
                .onChange((v: string) => {
                  const n = parseInt(v);
                  if (!isNaN(n)) this.port = n;
                })
            }
            .layoutWeight(1)

            Column() {
              Text('用户名')
                .fontSize(13).fontColor('rgba(255,255,255,0.5)')
                .margin({ bottom: 6 })
              TextInput({ placeholder: '用户名', text: this.username })
                .backgroundColor('rgba(255,255,255,0.08)')
                .borderRadius(12)
                .height(48)
                .fontColor('#FFFFFF')
                .placeholderColor('rgba(255,255,255,0.4)')
                .onChange((v: string) => { this.username = v; })
            }
            .layoutWeight(1)
            .margin({ left: 8 })
          }

          this.FieldItem('密码', TextInput({ placeholder: '登录密码', text: this.password })
            .backgroundColor('rgba(255,255,255,0.08)')
            .borderRadius(12)
            .height(48)
            .fontColor('#FFFFFF')
            .placeholderColor('rgba(255,255,255,0.4)')
            .type(InputType.Password)
            .onChange((v: string) => { this.password = v; }))

          if (this.errorMessage.length > 0) {
            Text(this.errorMessage)
              .fontSize(12).fontColor('#FF6B6B')
              .margin({ top: 8 })
          }

          Button(this.editHostId ? '保存修改' : '添加并连接')
            .width('100%').height(52)
            .borderRadius(16)
            .backgroundColor('#6677ff')
            .fontColor('#FFFFFF')
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .margin({ top: 20 })
            .onClick(() => {
              this.handleSave();
            })
            .enabled(!this.isSaving)
        }
        .width('100%')
      }
      .margin({ left: 16, right: 16, top: 16 })
    }
    .width('100%').height('100%')
  }

  @Builder
  FieldItem(label: string, input: void): void {
    Column() {
      Text(label)
        .fontSize(13).fontColor('rgba(255,255,255,0.5)')
        .margin({ bottom: 6 })
      input
    }
    .width('100%')
    .margin({ top: 8 })
  }

  private async handleSave(): Promise<void> {
    this.errorMessage = '';
    if (this.host.length === 0) {
      this.errorMessage = '请输入主机地址';
      return;
    }
    this.isSaving = true;
    try {
      const user = this.authService.getUser();
      const hostEntry: RemoteHost = {
        id: this.editHostId || Date.now().toString(),
        userId: user?.unionId ?? 'local',
        label: this.label || this.host,
        protocol: this.protocol,
        host: this.host,
        port: this.port,
        username: this.username,
        password: this.password,
        locked: false,
        lockType: 'none',
        syncVersion: 0
      };
      await this.syncService.saveToCloud(hostEntry);
      console.info('ConnectionForm saved host: ' + hostEntry.label);
      router.pushUrl({
        url: 'pages/RemoteDesktop',
        params: {
          host: this.host,
          port: this.port,
          username: this.username,
          password: this.password,
          protocol: this.protocol,
          hostId: hostEntry.id
        }
      });
    } catch (err) {
      this.errorMessage = '保存失败: ' + err;
      console.error('ConnectionForm save failed: ' + err);
    } finally {
      this.isSaving = false;
    }
  }
}
