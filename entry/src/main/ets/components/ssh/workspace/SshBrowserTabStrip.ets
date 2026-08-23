import {
  sshTerminalTabChromeRenderKey,
  SshTerminalTabView
} from '../../../services/SshTerminalTabStore';
import {
  SSH_TAB_STRIP_HEIGHT_VP,
  sshTabWidthVp
} from '../../../services/ssh/workspace/SshTabChromePolicy';

/** Browser-style SSH tab chrome; global actions live in the page-level text menu. */
@Component
export struct SshBrowserTabStrip {
  @StorageProp('accentColor') accentColor: string = '#007DFF';
  @Prop tabs: Array<SshTerminalTabView> = [];
  @Prop compact: boolean = false;
  @Prop terminalTabsActive: boolean = true;
  @Prop sftpTabVisible: boolean = false;
  @Prop sftpTabActive: boolean = false;
  @Prop sftpTabTitle: string = 'SFTP';
  onActivate: (hostId: string) => void = (_hostId: string): void => {};
  onClose: (hostId: string) => void = (_hostId: string): void => {};
  onTogglePin: (hostId: string) => void = (_hostId: string): void => {};
  onMove: (hostId: string, delta: number) => void = (_hostId: string, _delta: number): void => {};
  onMoveBefore: (hostId: string, beforeHostId: string) => void =
    (_hostId: string, _beforeHostId: string): void => {};
  onRename: (hostId: string) => void = (_hostId: string): void => {};
  onCloseOthers: (hostId: string) => void = (_hostId: string): void => {};
  onCloseRight: (hostId: string) => void = (_hostId: string): void => {};
  onActivateSftp: () => void = (): void => {};
  onCloseSftp: () => void = (): void => {};

  @State hoveredTabId: string = '';
  @State draggingTabId: string = '';

  private tabTitle(tab: SshTerminalTabView): string {
    return tab.label.length > 0 ? tab.label : tab.address;
  }

  private stateLabel(tab: SshTerminalTabView): string {
    if (tab.state === 'disconnected') { return '未连接'; }
    if (tab.state === 'connecting') { return '连接中'; }
    if (tab.state === 'reconnecting') { return '恢复中'; }
    if (tab.state === 'error') { return '错误'; }
    return '已连接';
  }

  private tabBackground(tab: SshTerminalTabView): string {
    if (this.terminalTabsActive && tab.active) { return this.accentColor + '42'; }
    if (this.hoveredTabId === tab.tabId) { return 'rgba(255,255,255,0.13)'; }
    return 'rgba(255,255,255,0.065)';
  }

  private terminalTabActive(tab: SshTerminalTabView): boolean {
    return this.terminalTabsActive && tab.active;
  }

  private statusColor(tab: SshTerminalTabView): string {
    if (tab.state === 'disconnected') { return 'rgba(242,244,247,0.34)'; }
    if (tab.state === 'error') { return '#FF7777'; }
    if (tab.state === 'connecting' || tab.state === 'reconnecting') { return '#F5B942'; }
    return '#34C759';
  }

  @Builder
  private TabMenu(tab: SshTerminalTabView) {
    Menu() {
      MenuItem({ content: tab.pinned ? '取消固定' : '固定标签' })
        .onClick((): void => { this.onTogglePin(tab.hostId); })
      MenuItem({ content: '向左移动' })
        .onClick((): void => { this.onMove(tab.hostId, -1); })
      MenuItem({ content: '向右移动' })
        .onClick((): void => { this.onMove(tab.hostId, 1); })
      MenuItem({ content: '重命名显示标题' })
        .onClick((): void => { this.onRename(tab.hostId); })
      MenuItem({ content: '关闭其他标签' })
        .onClick((): void => { this.onCloseOthers(tab.hostId); })
      MenuItem({ content: '关闭右侧标签' })
        .onClick((): void => { this.onCloseRight(tab.hostId); })
      MenuItem({ content: '断开并关闭' })
        .onClick((): void => { this.onClose(tab.hostId); })
    }
  }

  @Builder
  private TabBody(tab: SshTerminalTabView) {
    Row({ space: 6 }) {
      if (tab.pinned) {
        Text('●').fontSize(8).fontColor(this.accentColor)
          .accessibilityText('已固定')
      }
      Column({ space: 1 }) {
        Text(this.tabTitle(tab))
          .fontSize(11).fontWeight(this.terminalTabActive(tab) ?
            FontWeight.Medium : FontWeight.Regular)
          .fontColor(this.terminalTabActive(tab) ? '#F4F7FA' : 'rgba(242,244,247,0.76)')
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        Row({ space: 4 }) {
          Column().width(5).height(5).borderRadius(3).backgroundColor(this.statusColor(tab))
          Text(this.stateLabel(tab)).fontSize(8)
            .fontColor(tab.state === 'error' ? '#FF8989' : 'rgba(242,244,247,0.46)')
            .maxLines(1)
        }
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      Button('×')
        .width(48).height(48).padding(0).fontSize(16)
        .fontColor('rgba(242,244,247,0.76)')
        .borderRadius(8).backgroundColor('rgba(255,255,255,0.035)')
        .onClick((): void => { this.onClose(tab.hostId); })
        .accessibilityText('断开并关闭 ' + this.tabTitle(tab))
    }
    .width('100%').height('100%')
    .padding({ left: 9, right: 4 })
    .onClick((): void => { this.onActivate(tab.hostId); })
    .bindContextMenu(this.TabMenu(tab), ResponseType.LongPress)
  }

  @Builder
  private Tab(tab: SshTerminalTabView) {
    Stack() {
      this.TabBody(tab)
    }
    .width(sshTabWidthVp(this.compact, tab.pinned))
    .height(48)
    .borderRadius(9)
    .backgroundColor(this.tabBackground(tab))
    .border({ width: this.terminalTabActive(tab) ? 1 : 0.5,
      color: this.terminalTabActive(tab) ?
        this.accentColor + '99' : 'rgba(255,255,255,0.08)' })
    .onHover((hover: boolean): void => { this.hoveredTabId = hover ? tab.tabId : ''; })
    .onDragStart((_event: DragEvent): DragItemInfo => {
      this.draggingTabId = tab.hostId;
      return { extraInfo: tab.hostId };
    })
    .onDrop((_event: DragEvent): void => {
      const dragging: string = this.draggingTabId;
      this.draggingTabId = '';
      if (dragging.length > 0 && dragging !== tab.hostId) {
        this.onMoveBefore(dragging, tab.hostId);
      }
    })
    .onDragEnd((_event: DragEvent): void => { this.draggingTabId = ''; })
    .bindContextMenu(this.TabMenu(tab), ResponseType.RightClick)
    .accessibilityText(this.tabTitle(tab) + '，' + this.stateLabel(tab) +
      (this.terminalTabActive(tab) ? '，当前标签' : '') + (tab.pinned ? '，已固定' : ''))
  }

  @Builder
  private SftpTab() {
    Row({ space: 6 }) {
      SymbolGlyph($r('sys.symbol.folder_fill'))
        .fontSize(16)
        .fontColor([this.sftpTabActive ? this.accentColor : 'rgba(242,244,247,0.70)'])
      Column({ space: 1 }) {
        Text(this.sftpTabTitle)
          .fontSize(11)
          .fontWeight(this.sftpTabActive ? FontWeight.Medium : FontWeight.Regular)
          .fontColor(this.sftpTabActive ? '#F4F7FA' : 'rgba(242,244,247,0.76)')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text('文件工作台').fontSize(8).fontColor('rgba(242,244,247,0.46)').maxLines(1)
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      Button('×')
        .width(48).height(48).padding(0).fontSize(16)
        .fontColor('rgba(242,244,247,0.76)')
        .borderRadius(8).backgroundColor('rgba(255,255,255,0.035)')
        .onClick((): void => { this.onCloseSftp(); })
        .accessibilityText('关闭 SFTP 工作台标签')
    }
    .width(sshTabWidthVp(this.compact, false))
    .height(48)
    .padding({ left: 9, right: 4 })
    .borderRadius(9)
    .backgroundColor(this.sftpTabActive ? this.accentColor + '42' : 'rgba(255,255,255,0.065)')
    .border({ width: this.sftpTabActive ? 1 : 0.5,
      color: this.sftpTabActive ? this.accentColor + '99' : 'rgba(255,255,255,0.08)' })
    .onClick((): void => { this.onActivateSftp(); })
    .accessibilityText('SFTP 文件工作台' + (this.sftpTabActive ? '，当前标签' : ''))
  }

  build() {
    Row() {
      Scroll() {
        Row({ space: 6 }) {
          ForEach(this.tabs, (tab: SshTerminalTabView): void => {
            this.Tab(tab)
          }, (tab: SshTerminalTabView): string => sshTerminalTabChromeRenderKey(tab))
          if (this.sftpTabVisible) {
            this.SftpTab()
          }
        }.height(50).padding({ left: 2, right: 2 })
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .layoutWeight(1).height(50)
    }
    .width('100%').height(SSH_TAB_STRIP_HEIGHT_VP)
    .padding({ left: 6, right: 6 })
  }
}
