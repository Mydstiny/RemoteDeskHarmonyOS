import { BusinessError } from '@kit.BasicServicesKit';

@Component
export struct RdpCanvas {
  @State canvasWidth: number = 0;
  @State canvasHeight: number = 0;
  @State isActive: boolean = false;
  @StorageLink('rdpConnected') connected: boolean = false;
  onSurfaceCreated?: (surfaceId: string) => void;
  onTouchEvent?: (x: number, y: number, type: string) => void;

  private surfaceId: string = '';

  aboutToAppear(): void {
    this.isActive = true;
  }

  onPageShow(): void {
    this.isActive = true;
    console.info('RdpCanvas onPageShow');
  }

  onPageHide(): void {
    this.isActive = false;
    console.info('RdpCanvas onPageHide — pausing render');
  }

  build() {
    Stack() {
      XComponent({
        id: 'rdp_canvas',
        type: 'surface',
        libraryname: ''
      })
        .onLoad((xcomponentContext?: Object) => {
          if (xcomponentContext) {
            this.surfaceId = (xcomponentContext as Record<string, string>).surfaceId ?? '';
            console.info('RdpCanvas surfaceId: ' + this.surfaceId);
            this.onSurfaceCreated?.(this.surfaceId);
          }
        })
        .width('100%')
        .height('100%')

      if (!this.connected) {
        Column() {
          Text('远程桌面')
            .fontSize(24).fontWeight(FontWeight.Bold).fontColor('#FFFFFF')
          Text('正在等待连接...')
            .fontSize(15).fontColor('rgba(255,255,255,0.5)')
            .margin({ top: 8 })
          LoadingProgress()
            .width(48).height(48)
            .color('#6677ff')
            .margin({ top: 24 })
        }
        .width('100%').height('100%')
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .backgroundColor('rgba(0,0,0,0.6)')
      }
    }
    .width('100%').height('100%')
    .onTouch((event: TouchEvent) => {
      if (!this.isActive) return;
      const touch = event.touches[0];
      if (!touch) return;
      const x = touch.x;
      const y = touch.y;
      let typeStr: string = '';
      switch (event.type) {
        case TouchType.Down:
          typeStr = 'down';
          break;
        case TouchType.Up:
          typeStr = 'up';
          break;
        case TouchType.Move:
          typeStr = 'move';
          break;
        default:
          return;
      }
      this.onTouchEvent?.(x, y, typeStr);
    })
  }
}
