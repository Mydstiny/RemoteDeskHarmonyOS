import { SshTerminalTabView } from '../../../services/SshTerminalTabStore';
import { sshTabWidthVp } from '../../../services/ssh/workspace/SshTabChromePolicy';

/** Browser-style SSH tab chrome with fixed, always reachable edge actions. */
@Component
export struct SshBrowserTabStrip {
  @StorageProp('accentColor') accentColor: string = '#007DFF';
  @Prop tabs: Array<SshTerminalTabView> = [];
  @Prop compact: boolean = false;
  onActivate: (hostId: string) => void = (_hostId: string): void => {};
  onClose: (hostId: string) => void = (_hostId: string): void => {};
  onTogglePin: (hostId: string) => void = (_hostId: string): void => {};
  onMove: (hostId: string, delta: number) => void = (_hostId: string, _delta: number): void => {};
  onMoveBefore: (hostId: string, beforeHostId: string) => void =
    (_hostId: string, _beforeHostId: string): void => {};
  onRename: (hostId: string) => void = (_hostId: string): void => {};
  onCloseOthers: (hostId: string) => void = (_hostId: string): void => {};
  onCloseRight: (hostId: string) => void = (_hostId: string): void => {};
  onNewSession: () => void = (): void => {};
  onShowAllTabs: () => void = (): void => {};
  onOpenPalette: () => void = (): void => {};

  @State hoveredTabId: string = '';
  @State draggingTabId: string = '';

  private tabTitle(tab: SshTerminalTabView): string {
    return tab.label.length > 0 ? tab.label : tab.address;
  }

  private stateLabel(tab: SshTerminalTabView): string {
    if (tab.state === 'connecting') { return '连接中'; }
    if (tab.state === 'reconnecting') { return '恢复中'; }
    if (tab.state === 'error') { return '错误'; }
    return '已连接';
  }

  private tabBackground(tab: SshTerminalTabView): string {
    if (tab.active) { return this.accentColor + '42'; }
    if (this.hoveredTabId === tab.tabId) { return 'rgba(255,255,255,0.13)'; }
    return 'rgba(255,255,255,0.065)';
  }

  private statusColor(tab: SshTerminalTabView): string {
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
          .fontSize(11).fontWeight(tab.active ? FontWeight.Medium : FontWeight.Regular)
          .fontColor(tab.active ? '#F4F7FA' : 'rgba(242,244,247,0.76)')
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        Row({ space: 4 }) {
          Column().width(5).height(5).borderRadius(3).backgroundColor(this.statusColor(tab))
          Text(this.stateLabel(tab)).fontSize(8)
            .fontColor(tab.state === 'error' ? '#FF8989' : 'rgba(242,244,247,0.46)')
            .maxLines(1)
        }
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      Button('×')
        .width(30).height(30).padding(0).fontSize(16)
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
    .height(38)
    .borderRadius(9)
    .backgroundColor(this.tabBackground(tab))
    .border({ width: tab.active ? 1 : 0.5,
      color: tab.active ? this.accentColor + '99' : 'rgba(255,255,255,0.08)' })
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
      (tab.active ? '，当前标签' : '') + (tab.pinned ? '，已固定' : ''))
  }

  @Builder
  private EdgeAction(label: string, description: string, action: () => void) {
    Button(label)
      .width(34).height(34).padding(0).fontSize(label === '＋' ? 18 : 14)
      .fontColor('rgba(242,244,247,0.86)')
      .borderRadius(9).backgroundColor('rgba(255,255,255,0.08)')
      .onClick(action)
      .accessibilityText(description)
  }

  build() {
    Row({ space: 6 }) {
      Scroll() {
        Row({ space: 6 }) {
          ForEach(this.tabs, (tab: SshTerminalTabView): void => {
            this.Tab(tab)
          }, (tab: SshTerminalTabView): string => tab.tabId)
        }.height(40).padding({ left: 2, right: 2 })
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .layoutWeight(1).height(40)

      this.EdgeAction('☰', '显示所有 SSH 标签', (): void => { this.onShowAllTabs(); })
      this.EdgeAction('⌕', '打开 SSH 命令面板', (): void => { this.onOpenPalette(); })
      this.EdgeAction('＋', '新建 SSH 会话', (): void => { this.onNewSession(); })
    }
    .width('100%').height(42)
    .padding({ left: 6, right: 6 })
  }
}
