import {
  sshTerminalTabChromeRenderKey,
  SshTerminalTabView
} from '../../../services/SshTerminalTabStore';

/**
 * Wide-screen workspace navigation. Session ownership remains in the existing
 * tab/session stores; this component only emits semantic navigation actions.
 */
@Component
export struct SshWorkspaceSideBar {
  @StorageProp('accentColor') accentColor: string = '#007DFF';
  @Prop workspaceName: string = 'SSH 工作区';
  @Prop tabs: Array<SshTerminalTabView> = [];
  @Prop compact: boolean = false;
  @Prop disconnectedCount: number = 0;
  @State hoveredTabId: string = '';
  onActivateTab: (tabId: string) => void = (_tabId: string): void => {};
  onNewSession: () => void = (): void => {};
  onOpenPalette: () => void = (): void => {};
  onOpenTransfers: () => void = (): void => {};
  onCollapse: () => void = (): void => {};

  private tabTitle(tab: SshTerminalTabView): string {
    const label: string = tab.label.trim();
    if (label.length > 0) { return label; }
    const address: string = tab.address.trim();
    return address.length > 0 ? address : 'SSH 会话';
  }

  private tabInitial(tab: SshTerminalTabView): string {
    const title: string = this.tabTitle(tab);
    return title.length > 0 ? title.substring(0, 1).toUpperCase() : 'S';
  }

  private tabStateLabel(tab: SshTerminalTabView): string {
    if (tab.state === 'disconnected') { return '未连接'; }
    if (tab.state === 'connecting') { return '连接中'; }
    if (tab.state === 'reconnecting') { return '恢复中'; }
    if (tab.state === 'error') { return '错误'; }
    return '已连接';
  }

  private tabStateColor(tab: SshTerminalTabView): string {
    if (tab.state === 'error') { return '#FF7777'; }
    if (tab.state === 'connecting' || tab.state === 'reconnecting') { return '#F5B942'; }
    if (tab.state === 'disconnected') { return 'rgba(242,244,247,0.30)'; }
    return '#34C759';
  }

  private tabBackground(tab: SshTerminalTabView): string {
    if (tab.active) { return this.accentColor + '2E'; }
    if (this.hoveredTabId === tab.tabId) { return 'rgba(255,255,255,0.09)'; }
    return 'rgba(0,0,0,0)';
  }

  @Builder
  private SessionRow(tab: SshTerminalTabView) {
    if (this.compact) {
      Stack({ alignContent: Alignment.BottomEnd }) {
        Text(this.tabInitial(tab))
          .fontSize(14)
          .fontWeight(tab.active ? FontWeight.Bold : FontWeight.Medium)
          .fontColor(tab.active ? '#FFFFFF' : 'rgba(242,244,247,0.72)')
          .textAlign(TextAlign.Center)
          .width(42)
          .height(42)
          .borderRadius(12)
          .backgroundColor(this.tabBackground(tab))
          .border({ width: tab.active ? 1 : 0.5,
            color: tab.active ? this.accentColor + '99' : 'rgba(255,255,255,0.08)' })
        Column()
          .width(8).height(8).borderRadius(4)
          .backgroundColor(this.tabStateColor(tab))
          .margin({ right: 1, bottom: 1 })
      }
      .width(48).height(48)
      .onClick((): void => { this.onActivateTab(tab.tabId); })
      .onHover((hover: boolean): void => { this.hoveredTabId = hover ? tab.tabId : ''; })
      .accessibilityText(this.tabTitle(tab) + '，' + this.tabStateLabel(tab) +
        (tab.active ? '，当前会话' : ''))
    } else {
      Row({ space: 9 }) {
        Stack({ alignContent: Alignment.BottomEnd }) {
          Text(this.tabInitial(tab))
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor(tab.active ? '#FFFFFF' : 'rgba(242,244,247,0.72)')
            .textAlign(TextAlign.Center)
            .width(34).height(34)
            .borderRadius(10)
            .backgroundColor(tab.active ? this.accentColor + '38' : 'rgba(255,255,255,0.06)')
          Column().width(7).height(7).borderRadius(4)
            .backgroundColor(this.tabStateColor(tab))
        }.width(36).height(36)
        Column({ space: 2 }) {
          Text(this.tabTitle(tab))
            .fontSize(12)
            .fontWeight(tab.active ? FontWeight.Medium : FontWeight.Regular)
            .fontColor(tab.active ? '#F4F7FA' : 'rgba(242,244,247,0.78)')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.tabStateLabel(tab))
            .fontSize(9)
            .fontColor(tab.state === 'error' ? '#FF8989' : 'rgba(242,244,247,0.44)')
            .maxLines(1)
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      }
      .width('100%').height(52)
      .padding({ left: 9, right: 9 })
      .borderRadius(10)
      .backgroundColor(this.tabBackground(tab))
      .onClick((): void => { this.onActivateTab(tab.tabId); })
      .onHover((hover: boolean): void => { this.hoveredTabId = hover ? tab.tabId : ''; })
      .accessibilityText(this.tabTitle(tab) + '，' + this.tabStateLabel(tab) +
        (tab.active ? '，当前会话' : ''))
    }
  }

  @Builder
  private ActionRow(icon: Resource, label: string, action: () => void) {
    if (this.compact) {
      Button() {
        SymbolGlyph(icon).fontSize(18).fontColor(['rgba(242,244,247,0.80)'])
      }
      .width(48).height(48).padding(0)
      .borderRadius(12).backgroundColor('rgba(255,255,255,0.045)')
      .onClick(action)
      .accessibilityText(label)
    } else {
      Row({ space: 10 }) {
        SymbolGlyph(icon).fontSize(17).fontColor(['rgba(242,244,247,0.76)'])
        Text(label).fontSize(12).fontColor('rgba(242,244,247,0.78)').maxLines(1)
      }
      .width('100%').height(44)
      .padding({ left: 12, right: 10 })
      .borderRadius(9)
      .backgroundColor('rgba(255,255,255,0.035)')
      .onClick(action)
      .accessibilityText(label)
    }
  }

  build() {
    Column() {
      Row({ space: 8 }) {
        if (!this.compact) {
          Column({ space: 2 }) {
            Text('工作区').fontSize(10).fontColor('rgba(242,244,247,0.40)')
            Text(this.workspaceName)
              .fontSize(14).fontWeight(FontWeight.Medium).fontColor('#F2F4F7')
              .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        } else {
          Text('SSH').fontSize(11).fontWeight(FontWeight.Bold).fontColor('#F2F4F7')
            .layoutWeight(1).textAlign(TextAlign.Center)
        }
        Button() {
          SymbolGlyph($r('sys.symbol.chevron_left'))
            .fontSize(16).fontColor(['rgba(242,244,247,0.70)'])
        }
        .width(40).height(40).padding(0)
        .borderRadius(10).backgroundColor('rgba(255,255,255,0.045)')
        .onClick((): void => { this.onCollapse(); })
        .accessibilityText('收起工作区侧栏')
      }
      .width('100%').height(58)
      .padding({ left: this.compact ? 6 : 12, right: this.compact ? 6 : 8 })

      Divider().strokeWidth(0.5).color('rgba(255,255,255,0.08)').width('100%')

      if (!this.compact) {
        Row() {
          Text('会话').fontSize(10).fontColor('rgba(242,244,247,0.40)').layoutWeight(1)
          Text(this.tabs.length.toString())
            .fontSize(10).fontColor('rgba(242,244,247,0.42)')
          if (this.disconnectedCount > 0) {
            Text(' · ' + this.disconnectedCount.toString() + ' 待恢复')
              .fontSize(9).fontColor('#F5B942')
          }
        }.width('100%').height(34).padding({ left: 12, right: 12 })
      }

      Scroll() {
        Column({ space: this.compact ? 4 : 3 }) {
          ForEach(this.tabs, (tab: SshTerminalTabView): void => {
            this.SessionRow(tab)
          }, (tab: SshTerminalTabView): string => sshTerminalTabChromeRenderKey(tab))
        }
        .width('100%')
        .padding({ left: this.compact ? 6 : 7, right: this.compact ? 6 : 7,
          top: this.compact ? 8 : 2, bottom: 8 })
      }
      .width('100%').layoutWeight(1)
      .scrollable(ScrollDirection.Vertical).scrollBar(BarState.Auto)

      Divider().strokeWidth(0.5).color('rgba(255,255,255,0.08)').width('100%')
      Column({ space: 5 }) {
        this.ActionRow($r('sys.symbol.plus'), '新建 SSH 会话',
          (): void => { this.onNewSession(); })
        this.ActionRow($r('sys.symbol.magnifyingglass'), '命令面板',
          (): void => { this.onOpenPalette(); })
        this.ActionRow($r('sys.symbol.folder'), '传输中心',
          (): void => { this.onOpenTransfers(); })
      }
      .width('100%')
      .padding({ left: this.compact ? 6 : 8, right: this.compact ? 6 : 8,
        top: 8, bottom: 10 })
    }
    .width('100%').height('100%')
    .backgroundColor('#10161D')
    .border({ width: { right: 0.5 }, color: 'rgba(255,255,255,0.09)' })
  }
}
