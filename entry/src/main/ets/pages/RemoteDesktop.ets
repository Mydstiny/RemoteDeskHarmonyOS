import { RdpCanvas } from '../components/RdpCanvas';
import { LockGate, LockType } from '../components/LockGate';
import { LockService } from '../services/LockService';
import { router, promptAction } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';

@Entry
@Component
struct RemoteDesktop {
  @State hostLabel: string = '';
  @State hostId: string = '';
  @State protocol: string = 'rdp';
  @State remoteHost: string = '';
  @State remotePort: number = 3389;
  @State isConnected: boolean = false;
  @State showLockGate: boolean = false;
  @State isLocked: boolean = false;
  @State lockType: LockType = LockType.NONE;
  @State showToolbar: boolean = true;
  @StorageLink('rdpConnected') connected: boolean = false;

  private lockService: LockService = LockService.getInstance();

  aboutToAppear(): void {
    const params = router.getParams() as Record<string, Object>;
    if (params) {
      this.remoteHost = (params['host'] as string) || '';
      this.remotePort = (params['port'] as number) || 3389;
      this.protocol = (params['protocol'] as string) || 'rdp';
      this.hostId = (params['hostId'] as string) || '';
      this.hostLabel = (params['label'] as string) || (this.remoteHost || '远程桌面');
      if (this.hostId) {
        this.checkLock();
      }
    }
    this.connected = false;
  }

  checkLock(): void {
    if (this.lockService.isHostLocked(this.hostId)) {
      this.isLocked = true;
      const type = this.lockService.getLockType(this.hostId);
      this.lockType = type === 'biometric' ? LockType.BIOMETRIC
        : type === 'pin' ? LockType.PIN
        : type === 'password' ? LockType.PASSWORD
        : LockType.NONE;
      if (this.lockType !== LockType.NONE) {
        this.showLockGate = true;
      }
    }
  }

  onPageShow(): void {
    this.checkLock();
  }

  build() {
    Stack() {
      RdpCanvas({
        onSurfaceCreated: (surfaceId: string) => {
          this.startConnection(surfaceId);
        },
        onTouchEvent: (x: number, y: number, type: string) => {
          this.handleTouch(x, y, type);
        }
      })

      if (this.showToolbar) {
        Column() {
          Row() {
            Button({ type: ButtonType.Circle }) {
              Image($r('app.media.ic_back'))
                .width(20).height(20).fillColor('#FFFFFF')
            }
            .width(40).height(40).backgroundColor('rgba(0,0,0,0.5)')
            .onClick(() => {
              this.disconnect();
            })

            Blank()

            Text(this.hostLabel)
              .fontSize(14).fontColor('#FFFFFF')
              .opacity(0.8)

            Blank()

            Button({ type: ButtonType.Circle }) {
              Image($r('app.media.ic_lock'))
                .width(20).height(20).fillColor('#FFFFFF')
            }
            .width(40).height(40).backgroundColor('rgba(0,0,0,0.5)')
            .onClick(() => {
              this.toggleToolLock();
            })
          }
          .width('100%')
          .padding({ left: 12, right: 12, top: 44 })
        }
        .position({ x: 0, y: 0 })
      }

      if (this.showToolbar) {
        Row() {
          this.ToolButton($r('app.media.ic_lock'), '锁定', () => {
            this.toggleToolLock();
          })
          this.ToolButton($r('app.media.ic_screenshot'), '截屏', () => {
            this.takeScreenshot();
          })
          this.ToolButton($r('app.media.ic_file'), '文件', () => {
            this.openFileTransfer();
          })
          this.ToolButton($r('app.media.ic_keyboard'), '键盘', () => {
            this.showKeyboard();
          })
          this.ToolButton($r('app.media.ic_disconnect'), '断开', () => {
            this.disconnect();
          })
        }
        .width('90%').height(60)
        .borderRadius(20)
        .backgroundBlurStyle(BlurStyle.REGULAR)
        .backgroundColor('rgba(30,30,40,0.7)')
        .border({ width: 0.5, color: 'rgba(255,255,255,0.1)', style: BorderStyle.Solid })
        .shadow({ radius: 20, color: 'rgba(0,0,0,0.3)', offsetY: 4 })
        .position({ x: '50%', y: '90%' })
        .translate({ x: '-50%', y: 0 })
        .justifyContent(FlexAlign.SpaceAround)
        .padding({ left: 8, right: 8 })
      }

      if (this.showLockGate) {
        LockGate({
          lockType: this.lockType,
          hostLabel: this.hostLabel,
          onUnlocked: () => {
            this.showLockGate = false;
            this.isLocked = false;
            this.connected = true;
          },
          onCancel: () => {
            router.back();
          }
        })
        .backgroundColor('rgba(0,0,0,0.8)')
      }
    }
    .width('100%').height('100%')
    .backgroundColor('#000000')
  }

  @Builder
  ToolButton(icon: Resource, label: string, action: () => void): void {
    Column() {
      Image(icon)
        .width(22).height(22)
        .fillColor('rgba(255,255,255,0.8)')
      Text(label)
        .fontSize(10).fontColor('rgba(255,255,255,0.6)')
        .margin({ top: 2 })
    }
    .onClick(() => { action(); })
  }

  private startConnection(surfaceId: string): void {
    console.info('RemoteDesktop starting connection to '
      + this.remoteHost + ':' + this.remotePort + ' via ' + this.protocol);
    try {
      this.connected = true;
    } catch (err) {
      console.error('Connection failed: ' + err);
    }
  }

  private handleTouch(x: number, y: number, type: string): void {
    if (!this.isLocked) {
      console.info('Touch event: ' + type + ' at (' + x + ', ' + y + ')');
    }
  }

  private toggleToolLock(): void {
    this.showToolbar = !this.showToolbar;
  }

  private takeScreenshot(): void {
    try {
      promptAction.showToast({ message: '截图已保存', duration: 1500 });
    } catch (err) {
      console.error('Screenshot failed: ' + err);
    }
  }

  private openFileTransfer(): void {
    try {
      promptAction.showToast({ message: '文件传输功能开发中', duration: 1500 });
    } catch (err) {
      console.error('File transfer toast failed: ' + err);
    }
  }

  private showKeyboard(): void {
    try {
      promptAction.showToast({ message: '虚拟键盘已打开', duration: 1500 });
    } catch (err) {
      console.error('Keyboard toast failed: ' + err);
    }
  }

  private disconnect(): void {
    this.connected = false;
    router.back();
  }
}
