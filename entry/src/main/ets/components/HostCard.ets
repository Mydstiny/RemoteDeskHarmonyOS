import { promptAction } from '@kit.ArkUI';
import { GlassmorphicCard } from './GlassmorphicCard';
import { RemoteHost, LockType } from '../models/RemoteHost';

@Component
export struct HostCard {
  @Prop host: RemoteHost | null = null;
  onConnect?: (host: RemoteHost) => void;
  onLongPress?: (host: RemoteHost) => void;

  build() {
    if (this.host === null) {
      return;
    }
    GlassmorphicCard() {
      Row() {
        Image($r('app.media.default_host'))
          .width(48).height(48).borderRadius(12)
        Column() {
          Text(this.host!.label)
            .fontSize(17).fontWeight(FontWeight.Medium).fontColor('#FFFFFF')
          Text(`${this.host!.protocol.toUpperCase()} · ${this.host!.host}:${this.host!.port}`)
            .fontSize(13).fontColor('rgba(255,255,255,0.6)')
            .margin({ top: 2 })
          if (this.host!.tags.length > 0) {
            Row() {
              ForEach(this.host!.tags.slice(0, 3), (tag: string) => {
                Text(tag)
                  .fontSize(10)
                  .fontColor('rgba(102,119,255,0.8)')
                  .backgroundColor('rgba(102,119,255,0.15)')
                  .borderRadius(4)
                  .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                  .margin({ right: 4 })
              })
            }
            .margin({ top: 4 })
          }
        }
        .layoutWeight(1).alignItems(HorizontalAlign.Start)
        .margin({ left: 12 })
        if (this.host!.locked) {
          Image($r('app.media.icon_locked'))
            .width(24).height(24)
            .fillColor('#FF6B6B')
        } else {
          Image($r('app.media.icon_unlocked'))
            .width(24).height(24)
            .fillColor('#51CF66')
        }
      }
    }
    .onClick(() => {
      this.onConnect?.(this.host!);
    })
    .onTouch((event: TouchEvent) => {
      if (event.type === TouchType.LongPress) {
        this.onLongPress?.(this.host!);
        this.showContextMenu(this.host!);
      }
    })
  }

  private showContextMenu(host: RemoteHost): void {
    try {
      promptAction.showDialog({
        title: host.label,
        message: '操作',
        buttons: [
          { text: '编辑', color: '#6677ff' },
          { text: host.locked ? '解锁' : '加锁', color: '#FF6B6B' },
          { text: '删除', color: '#FF4444' }
        ]
      });
    } catch (err) {
      console.error('Context menu failed: ' + err);
    }
  }
}
