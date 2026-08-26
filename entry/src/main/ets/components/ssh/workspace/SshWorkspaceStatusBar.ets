import {
  SshWorkspaceStatusItem,
  SshWorkspaceStatusTone
} from '../../../services/ssh/workspace/SshWorkspaceStatusPolicy';

/** Read-only bottom status chrome; it never competes for terminal focus. */
@Component
export struct SshWorkspaceStatusBar {
  @Prop items: Array<SshWorkspaceStatusItem> = [];
  @Prop compact: boolean = false;

  private toneColor(tone: SshWorkspaceStatusTone): string {
    if (tone === 'positive') { return '#73D992'; }
    if (tone === 'warning') { return '#F0C66C'; }
    if (tone === 'danger') { return '#FF8989'; }
    return 'rgba(242,244,247,0.55)';
  }

  build() {
    Row({ space: 9 }) {
      ForEach(this.items, (item: SshWorkspaceStatusItem, index: number): void => {
        if (index > 0) {
          Column().width(1).height(10).backgroundColor('rgba(255,255,255,0.10)')
        }
        Row({ space: 5 }) {
          if (item.id === 'connection') {
            Column().width(6).height(6).borderRadius(3).backgroundColor(this.toneColor(item.tone))
          }
          Text(item.label)
            .fontSize(this.compact ? 9 : 10)
            .fontColor(this.toneColor(item.tone))
            .maxLines(1)
        }
      }, (item: SshWorkspaceStatusItem): string => item.id)
    }
    .width('100%')
    .height(this.compact ? 26 : 28)
    .padding({ left: 10, right: 10 })
    .backgroundColor('#0F151C')
    .border({ width: { top: 0.5 }, color: 'rgba(255,255,255,0.08)' })
    .clip(true)
    .hitTestBehavior(HitTestMode.None)
    .accessibilityText(this.items.map((item: SshWorkspaceStatusItem): string => item.label).join('，'))
  }
}
