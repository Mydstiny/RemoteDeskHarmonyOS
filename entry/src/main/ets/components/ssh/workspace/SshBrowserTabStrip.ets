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
  @State hoveredCloseId: string = '';
  @State sftpTabHovered: boolean = false;
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
    if (this.terminalTabsActive && tab.active) { return 'rgba(255,255,255,0.095)'; }
    if (this.hoveredTabId === tab.tabId) { return 'rgba(255,255,255,0.065)'; }
    return 'rgba(255,255,255,0.018)';
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

  private closeButtonBackground(tabId: string): string {
    return this.hoveredCloseId === tabId ? 'rgba(255,255,255,0.12)' : 'transparent';
  }

  private closeButtonOpacity(tab: SshTerminalTabView): number {
    return this.terminalTabActive(tab) || this.hoveredTabId === tab.tabId ? 0.86 : 0.42;
  }

  private sftpTabBackground(): string {
    if (this.sftpTabActive) { return 'rgba(255,255,255,0.095)'; }
    return this.sftpTabHovered ? 'rgba(255,255,255,0.065)' : 'rgba(255,255,255,0.018)';
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
    Row({ space: 7 }) {
      Column()
        .width(6).height(6).borderRadius(3)
        .backgroundColor(this.statusColor(tab))
      if (tab.pinned) {
        SymbolGlyph($r('sys.symbol.pin_fill'))
          .fontSize(11)
          .fontColor([this.accentColor])
          .accessibilityText('已固定')
      }
      Text(this.tabTitle(tab))
        .fontSize(12)
        .fontWeight(this.terminalTabActive(tab) ? FontWeight.Medium : FontWeight.Regular)
        .fontColor(this.terminalTabActive(tab) ? '#F7F9FB' : 'rgba(242,244,247,0.70)')
        .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
      Button() {
        SymbolGlyph($r('sys.symbol.xmark'))
          .fontSize(11)
          .fontColor(['rgba(242,244,247,0.82)'])
      }
        .width(this.compact ? 40 : 32).height(40).padding(0)
        .opacity(this.closeButtonOpacity(tab))
        .borderRadius(7).backgroundColor(this.closeButtonBackground(tab.tabId))
        .onHover((hover: boolean): void => { this.hoveredCloseId = hover ? tab.tabId : ''; })
        .onClick((): void => { this.onClose(tab.hostId); })
        .accessibilityText('断开并关闭 ' + this.tabTitle(tab))
    }
    .width('100%').height(40)
    .padding({ left: 11, right: 5 })
    .onClick((): void => { this.onActivate(tab.hostId); })
    .bindContextMenu(this.TabMenu(tab), ResponseType.LongPress)
  }

  @Builder
  private Tab(tab: SshTerminalTabView) {
    Column() {
      this.TabBody(tab)
      Column()
        .width('100%').height(2)
        .borderRadius(1)
        .backgroundColor(this.terminalTabActive(tab) ? this.accentColor : 'transparent')
    }
    .width(sshTabWidthVp(this.compact, tab.pinned))
    .height(44)
    .borderRadius(7)
    .backgroundColor(this.tabBackground(tab))
    .border({ width: { right: 0.5 }, color: 'rgba(255,255,255,0.07)' })
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
    Column() {
      Row({ space: 7 }) {
        SymbolGlyph($r('sys.symbol.folder_fill'))
          .fontSize(14)
          .fontColor([this.sftpTabActive ? this.accentColor : 'rgba(242,244,247,0.62)'])
        Text(this.sftpTabTitle)
          .fontSize(12)
          .fontWeight(this.sftpTabActive ? FontWeight.Medium : FontWeight.Regular)
          .fontColor(this.sftpTabActive ? '#F7F9FB' : 'rgba(242,244,247,0.70)')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        Button() {
          SymbolGlyph($r('sys.symbol.xmark'))
            .fontSize(11)
            .fontColor(['rgba(242,244,247,0.82)'])
        }
          .width(this.compact ? 40 : 32).height(40).padding(0)
          .opacity(this.sftpTabActive || this.sftpTabHovered ? 0.86 : 0.42)
          .borderRadius(7).backgroundColor(this.closeButtonBackground('__sftp__'))
          .onHover((hover: boolean): void => { this.hoveredCloseId = hover ? '__sftp__' : ''; })
          .onClick((): void => { this.onCloseSftp(); })
          .accessibilityText('关闭 SFTP 工作台标签')
      }
      .width('100%').height(40)
      .padding({ left: 11, right: 5 })
      Column()
        .width('100%').height(2)
        .borderRadius(1)
        .backgroundColor(this.sftpTabActive ? this.accentColor : 'transparent')
    }
    .width(sshTabWidthVp(this.compact, false))
    .height(44)
    .borderRadius(7)
    .backgroundColor(this.sftpTabBackground())
    .border({ width: { right: 0.5 }, color: 'rgba(255,255,255,0.07)' })
    .onHover((hover: boolean): void => { this.sftpTabHovered = hover; })
    .onClick((): void => { this.onActivateSftp(); })
    .accessibilityText('SFTP 文件工作台' + (this.sftpTabActive ? '，当前标签' : ''))
  }

  build() {
    Row() {
      Scroll() {
        Row({ space: 3 }) {
          ForEach(this.tabs, (tab: SshTerminalTabView): void => {
            this.Tab(tab)
          }, (tab: SshTerminalTabView): string => sshTerminalTabChromeRenderKey(tab))
          if (this.sftpTabVisible) {
            this.SftpTab()
          }
        }.height(48).padding({ left: 2, right: 2 })
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .layoutWeight(1).height(48)
    }
    .width('100%').height(SSH_TAB_STRIP_HEIGHT_VP)
    .padding({ left: 6, right: 6 })
  }
}
