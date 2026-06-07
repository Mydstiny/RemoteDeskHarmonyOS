import { ImmersiveBackground } from '../components/ImmersiveBackground';
import { GlassmorphicCard } from '../components/GlassmorphicCard';
import { FloatNavigation } from '../components/FloatNavigation';
import { HostCard, RemoteHost } from '../components/HostCard';
import { LightSensingService } from '../services/LightSensingService';
import { HostSyncService } from '../services/HostSyncService';
import { AuthService } from '../services/AuthService';
import { router, promptAction } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';

@Entry
@Component
struct HostListPage {
  @State hosts: RemoteHost[] = [];
  @State filteredHosts: RemoteHost[] = [];
  @State lightIntensity: number = 0.6;
  @State searchText: string = '';
  @State isRefreshing: boolean = false;
  @StorageLink('currentTheme') theme: string = 'dark';
  private lightService: LightSensingService = LightSensingService.getInstance();
  private syncService: HostSyncService = HostSyncService.getInstance();
  private authService: AuthService = AuthService.getInstance();

  async aboutToAppear(): Promise<void> {
    this.lightService.startMonitoring();
    this.lightService.onLightChange((lux: number) => {
      this.lightIntensity = this.lightService.getLightIntensity();
    });
    await this.loadHosts();
  }

  async loadHosts(): Promise<void> {
    try {
      const user = this.authService.getUser();
      const userId = user?.unionId ?? 'local';
      this.hosts = await this.syncService.loadFromCloud(userId);
      this.filteredHosts = [...this.hosts];
      console.info('HostListPage loaded ' + this.hosts.length + ' hosts');
    } catch (err) {
      console.error('Failed to load hosts: ' + err);
    }
  }

  onPageShow(): void {
    this.loadHosts();
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
      GlassmorphicCard({ borderRadius: 16, paddingSize: 8 }) {
        Row() {
          Image($r('app.media.ic_search'))
            .width(20).height(20)
            .fillColor('rgba(255,255,255,0.7)')
            .margin({ left: 8 })
          TextInput({ placeholder: '搜索远程主机...', text: this.searchText })
            .backgroundColor(Color.Transparent)
            .fontColor('#FFFFFF')
            .placeholderColor('rgba(255,255,255,0.4)')
            .layoutWeight(1)
            .height(44)
            .onChange((value: string) => {
              this.searchText = value;
              this.filterHosts(value);
            })
        }
      }
      .margin({ top: 16, left: 16, right: 16 })

      Row() {
        Text('我的主机')
          .fontSize(20).fontWeight(FontWeight.Bold).fontColor('#FFFFFF')
        Blank()
        Text(this.hosts.length + ' 台')
          .fontSize(13).fontColor('rgba(255,255,255,0.5)')
        Button({ type: ButtonType.Circle }) {
          Image($r('app.media.ic_add'))
            .width(22).height(22).fillColor('#FFFFFF')
        }
        .width(36).height(36)
        .backgroundColor('#6677ff')
        .margin({ left: 8 })
        .onClick(() => {
          router.pushUrl({ url: 'pages/ConnectionForm' });
        })
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: 16 })

      if (this.filteredHosts.length > 0) {
        List({ space: 12 }) {
          ForEach(this.filteredHosts, (host: RemoteHost) => {
            ListItem() {
              HostCard({
                host: host,
                onConnect: (h: RemoteHost) => {
                  this.connectToHost(h);
                },
                onLongPress: (h: RemoteHost) => {
                  this.showHostActions(h);
                }
              })
            }
          })
        }
        .layoutWeight(1)
        .padding({ left: 16, right: 16, top: 12 })
      } else {
        Column() {
          Text('暂无远程主机')
            .fontSize(16).fontColor('rgba(255,255,255,0.4)')
          Text('点击右上角 + 添加')
            .fontSize(13).fontColor('rgba(255,255,255,0.3)')
            .margin({ top: 4 })
        }
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
      }

      FloatNavigation({
        bottomAvoidHeight: 80,
        onTabChange: (index: number) => {
          this.onTabSwitch(index);
        }
      })
    }
    .width('100%').height('100%')
  }

  private filterHosts(query: string): void {
    if (query.length === 0) {
      this.filteredHosts = [...this.hosts];
      return;
    }
    const lower = query.toLowerCase();
    this.filteredHosts = this.hosts.filter((h) => {
      return h.label.toLowerCase().includes(lower)
        || h.host.toLowerCase().includes(lower)
        || h.protocol.toLowerCase().includes(lower);
    });
  }

  private connectToHost(host: RemoteHost): void {
    router.pushUrl({
      url: 'pages/RemoteDesktop',
      params: { hostId: host.id, protocol: host.protocol }
    });
  }

  private showHostActions(host: RemoteHost): void {
    try {
      promptAction.showDialog({
        title: host.label,
        message: host.host + ':' + host.port,
        buttons: [
          { text: '编辑', color: '#6677ff' },
          { text: host.locked ? '解锁' : '加锁', color: '#FF6B6B' },
          { text: '删除', color: '#FF4444' }
        ]
      }).then((result) => {
        if (result.index === 0) {
          router.pushUrl({
            url: 'pages/ConnectionForm',
            params: { editHostId: host.id }
          });
        } else if (result.index === 1) {
          this.toggleLock(host);
        } else if (result.index === 2) {
          this.deleteHost(host);
        }
      });
    } catch (err) {
      console.error('Show host actions failed: ' + err);
    }
  }

  private async toggleLock(host: RemoteHost): Promise<void> {
    host.locked = !host.locked;
    host.lockType = host.locked ? 'biometric' : 'none';
    await this.syncService.saveToCloud(host);
    this.filterHosts(this.searchText);
  }

  private async deleteHost(host: RemoteHost): Promise<void> {
    try {
      await this.syncService.deleteFromCloud(host.id);
      this.hosts = this.hosts.filter((h) => h.id !== host.id);
      this.filterHosts(this.searchText);
    } catch (err) {
      console.error('Delete host failed: ' + err);
    }
  }

  private onTabSwitch(index: number): void {
    switch (index) {
      case 0:
        break;
      case 1:
        router.pushUrl({ url: 'pages/ConnectionForm' });
        break;
      case 2:
        router.pushUrl({ url: 'pages/Settings' });
        break;
    }
  }
}
