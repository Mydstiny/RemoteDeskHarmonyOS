import { GlassmorphicCard } from './GlassmorphicCard';
import { HostCard } from './HostCard';
import { RemoteHost, ConnectionGroup } from '../models/RemoteHost';

@Component
export struct ConnectionGroupCard {
  @Prop group: ConnectionGroup | null = null;
  @Prop hosts: RemoteHost[] = [];
  @State isExpanded: boolean = false;
  onHostClick?: (host: RemoteHost) => void;
  onGroupClick?: (group: ConnectionGroup) => void;

  build() {
    if (this.group === null) {
      return;
    }
    Column() {
      GlassmorphicCard({ borderRadius: 16, paddingSize: 12 }) {
        Row() {
          Column() {
            Text(this.group!.name)
              .fontSize(17).fontWeight(FontWeight.SemiBold).fontColor('#FFFFFF')
            Text(this.hosts.length + ' 台主机')
              .fontSize(12).fontColor('rgba(255,255,255,0.5)')
              .margin({ top: 2 })
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)

          Image(this.isExpanded ? $r('app.media.ic_chevron_down') : $r('app.media.ic_chevron_right'))
            .width(20).height(20)
            .fillColor('rgba(255,255,255,0.6)')
        }
        .width('100%')
        .onClick(() => {
          this.isExpanded = !this.isExpanded;
          this.onGroupClick?.(this.group!);
        })
      }

      if (this.isExpanded) {
        Column() {
          ForEach(this.hosts, (host: RemoteHost) => {
            HostCard({
              host: host,
              onConnect: (h: RemoteHost) => {
                this.onHostClick?.(h);
              }
            })
            .margin({ top: 8 })
          })
        }
        .padding({ left: 12, right: 12 })
        .transition({ type: TransitionType.Insert, opacity: 0, translate: { y: -10 } })
      }
    }
    .width('100%')
  }
}
