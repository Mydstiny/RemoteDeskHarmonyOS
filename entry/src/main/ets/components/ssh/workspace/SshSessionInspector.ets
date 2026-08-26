import { SshTerminalTabState } from '../../../services/SshTerminalTabStore';

/**
 * Read-only context for the active workspace session. The page keeps ownership
 * of native sessions and emits the small set of semantic actions below.
 */
@Component
export struct SshSessionInspector {
  @StorageProp('accentColor') accentColor: string = '#007DFF';
  @Prop title: string = 'SSH 会话';
  @Prop address: string = '';
  @Prop state: SshTerminalTabState = 'disconnected';
  @Prop latencyMs: number = -1;
  @Prop paneLabel: string = '未分配 Pane';
  @Prop profileLabel: string = '默认终端配置';
  @Prop gridLabel: string = '--';
  @Prop pinned: boolean = false;
  @Prop actionEnabled: boolean = false;
  @Prop profileEnabled: boolean = false;
  @Prop transferAttentionCount: number = 0;
  @Prop forwardingCount: number = 0;
  onClose: () => void = (): void => {};
  onTogglePin: () => void = (): void => {};
  onOpenProfile: () => void = (): void => {};
  onOpenSftp: () => void = (): void => {};
  onOpenForwarding: () => void = (): void => {};

  private stateLabel(): string {
    if (this.state === 'connecting') { return '连接中'; }
    if (this.state === 'reconnecting') { return '恢复中'; }
    if (this.state === 'connected') { return '已连接'; }
    if (this.state === 'error') { return '连接错误'; }
    return '未连接';
  }

  private stateColor(): string {
    if (this.state === 'connected') { return '#34C759'; }
    if (this.state === 'connecting' || this.state === 'reconnecting') { return '#F5B942'; }
    if (this.state === 'error') { return '#FF7777'; }
    return 'rgba(242,244,247,0.30)';
  }

  private latencyLabel(): string {
    return this.state === 'connected' && this.latencyMs >= 0 ?
      this.latencyMs.toString() + ' ms' : '-- ms';
  }

  @Builder
  private DetailRow(label: string, value: string) {
    Row({ space: 12 }) {
      Text(label)
        .fontSize(11).fontColor('rgba(242,244,247,0.45)')
        .width(68).maxLines(1)
      Text(value)
        .fontSize(12).fontColor('rgba(242,244,247,0.82)')
        .layoutWeight(1).maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .textAlign(TextAlign.End)
    }
    .width('100%').constraintSize({ minHeight: 38 })
  }

  @Builder
  private ActionRow(icon: Resource, label: string, detail: string,
    enabled: boolean, action: () => void) {
    Row({ space: 10 }) {
      SymbolGlyph(icon)
        .fontSize(17)
        .fontColor([enabled ? 'rgba(242,244,247,0.78)' : 'rgba(242,244,247,0.28)'])
        .width(24)
      Column({ space: 2 }) {
        Text(label)
          .fontSize(12)
          .fontColor(enabled ? 'rgba(242,244,247,0.82)' : 'rgba(242,244,247,0.34)')
          .maxLines(1)
        Text(detail)
          .fontSize(9).fontColor('rgba(242,244,247,0.40)').maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(13)
        .fontColor([enabled ? 'rgba(242,244,247,0.42)' : 'rgba(242,244,247,0.18)'])
    }
    .width('100%').height(52)
    .padding({ left: 11, right: 10 })
    .borderRadius(10)
    .backgroundColor('rgba(255,255,255,0.035)')
    .opacity(enabled ? 1 : 0.65)
    .enabled(enabled)
    .onClick(action)
    .accessibilityText(label + '，' + detail)
  }

  build() {
    Column() {
      Row({ space: 8 }) {
        Column({ space: 2 }) {
          Text('会话详情').fontSize(10).fontColor('rgba(242,244,247,0.40)')
          Text(this.title)
            .fontSize(14).fontWeight(FontWeight.Medium).fontColor('#F2F4F7')
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        Button() {
          SymbolGlyph($r('sys.symbol.xmark'))
            .fontSize(16).fontColor(['rgba(242,244,247,0.70)'])
        }
        .width(40).height(40).padding(0)
        .borderRadius(10).backgroundColor('rgba(255,255,255,0.045)')
        .onClick((): void => { this.onClose(); })
        .accessibilityText('关闭会话详情')
      }
      .width('100%').height(58).padding({ left: 13, right: 8 })

      Divider().strokeWidth(0.5).color('rgba(255,255,255,0.08)').width('100%')

      Scroll() {
        Column({ space: 14 }) {
          Column({ space: 8 }) {
            Row({ space: 8 }) {
              Column().width(8).height(8).borderRadius(4).backgroundColor(this.stateColor())
              Text(this.stateLabel())
                .fontSize(13).fontWeight(FontWeight.Medium).fontColor('#F2F4F7')
              Text(this.latencyLabel())
                .fontSize(10).fontColor('rgba(242,244,247,0.52)')
                .layoutWeight(1).textAlign(TextAlign.End)
            }.width('100%')
            Text(this.address.length > 0 ? this.address : '未绑定主机地址')
              .fontSize(11).fontColor('rgba(242,244,247,0.52)').fontFamily('monospace')
              .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')
          }
          .width('100%')
          .padding({ left: 12, right: 12, top: 12, bottom: 12 })
          .borderRadius(12)
          .backgroundColor('rgba(255,255,255,0.045)')
          .border({ width: 0.5, color: 'rgba(255,255,255,0.08)' })

          Column() {
            Text('工作区')
              .fontSize(10).fontColor('rgba(242,244,247,0.40)')
              .width('100%').margin({ bottom: 4 })
            this.DetailRow('位置', this.paneLabel)
            this.DetailRow('标签', this.pinned ? '已固定' : '普通标签')
            this.DetailRow('终端', this.gridLabel)
            this.DetailRow('外观', this.profileLabel)
          }
          .width('100%').alignItems(HorizontalAlign.Start)

          Column({ space: 6 }) {
            Text('会话操作')
              .fontSize(10).fontColor('rgba(242,244,247,0.40)')
              .width('100%').margin({ bottom: 2 })
            this.ActionRow(this.pinned ? $r('sys.symbol.pin_fill') : $r('sys.symbol.pin'),
              this.pinned ? '取消固定标签' : '固定标签',
              this.pinned ? '恢复普通标签排序' : '在工作区中保留此标签',
              this.title.length > 0, (): void => { this.onTogglePin(); })
            this.ActionRow($r('sys.symbol.gearshape_fill'), '终端外观',
              '字体、配色与光标', this.profileEnabled, (): void => { this.onOpenProfile(); })
            this.ActionRow($r('sys.symbol.folder'), 'SFTP 文件',
              this.transferAttentionCount > 0 ?
                this.transferAttentionCount.toString() + ' 个传输任务需要处理' : '浏览与传输远端文件',
              this.actionEnabled, (): void => { this.onOpenSftp(); })
            this.ActionRow($r('sys.symbol.link'), '隧道转发',
              this.forwardingCount > 0 ?
                this.forwardingCount.toString() + ' 条转发正在监听' : '管理端口转发规则',
              this.actionEnabled, (): void => { this.onOpenForwarding(); })
          }
          .width('100%').alignItems(HorizontalAlign.Start)
        }
        .width('100%')
        .padding({ left: 12, right: 12, top: 14, bottom: 16 })
      }
      .width('100%').layoutWeight(1)
      .scrollable(ScrollDirection.Vertical).scrollBar(BarState.Auto)
    }
    .width('100%').height('100%')
    .backgroundColor('#10161D')
    .border({ width: { left: 0.5 }, color: 'rgba(255,255,255,0.09)' })
    .id('ssh-workspace-focus-inspector')
    .focusable(true)
    .focusOnTouch(false)
  }
}
