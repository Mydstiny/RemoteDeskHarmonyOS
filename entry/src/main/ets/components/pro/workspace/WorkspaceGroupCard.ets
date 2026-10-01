import { AppConfig, buildDark, buildLight, Palette } from '../../../common/Theme';
import { ProBadge } from '../../ProBadge';
import { ProEntries } from '../../../services/pro/ProEntries';
import { Workspace } from '../../../services/pro/workspace/WorkspacePolicy';
import { WorkspaceStore } from '../../../services/pro/workspace/WorkspaceStore';
import { OrgHostRow } from '../../../services/pro/org/HostOrganizationDirectory';
import {
  createWorkspace, saveCurrentWorkspace, showWorkspaceMenu, workspaceProtocols, workspaceSubtitle, workspaceTint
} from './WorkspaceActions';

/** 工作区 category card for the categorized host page; it expands in place like the protocol cards. */
@Component
export struct WorkspaceGroupCard {
  @StorageProp('currentTheme') theme: string = 'light';
  @StorageProp('accentColor') accent: string = '#007DFF';
  @Prop runningId: string = '';
  @Prop expanded: boolean = false;
  @Prop compact: boolean = true;
  @Prop cardHeight: number = 88;
  onToggle: () => void = (): void => {};
  @State revision: number = 0;
  private stop: (() => void) | null = null;

  aboutToAppear(): void {
    const store: WorkspaceStore = WorkspaceStore.getInstance();
    store.load();
    this.stop = store.subscribe((): void => { this.revision++; });
  }
  aboutToDisappear(): void { this.stop?.(); this.stop = null; }

  private pal(): Palette { return this.theme === 'light' ? buildLight(this.accent) : buildDark(this.accent); }
  private workspaces(_revision: number): Workspace[] { return WorkspaceStore.getInstance().list(); }
  private sessionCount(_revision: number): number {
    let count: number = 0;
    this.workspaces(this.revision).forEach((workspace: Workspace): void => { count += workspace.entries.length; });
    return count;
  }
  private runningName(_revision: number): string {
    const running: Workspace | undefined = this.workspaces(this.revision)
      .find((workspace: Workspace): boolean => workspace.id === this.runningId);
    return running === undefined ? '' : running.name;
  }

  build() {
    if (ProEntries.visible('pro.workspaces')) {
      Column() {
        Row() {
          Column() {
            SymbolGlyph($r('sys.symbol.rectangle_on_rectangle')).fontSize(this.compact ? 20 : 24)
              .fontColor([this.accent])
          }
          .width(this.compact ? 38 : 44).height(this.compact ? 38 : 44)
          .borderRadius(this.compact ? 19 : 14).backgroundColor(this.pal().surface)
          .justifyContent(FlexAlign.Center)
          Column() {
            Text('工作区').fontSize(this.compact ? 16 : 18).fontWeight(FontWeight.Medium)
              .fontColor(this.pal().text).fontFamily(AppConfig.fontFamily)
            Text('一键依次打开常用会话').fontSize(this.compact ? 10 : 11).fontColor(this.pal().text3)
              .fontFamily(AppConfig.fontFamily).margin({ top: 3 }).maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }.alignItems(HorizontalAlign.Start).layoutWeight(1).margin({ left: this.compact ? 8 : 10 })
          ProBadge().margin({ right: 8 }).alignSelf(ItemAlign.Center)
          SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(this.compact ? 16 : 18).fontColor([this.pal().text3])
            .rotate({ angle: this.expanded ? 90 : 0 })
            .animation({ duration: 220, curve: Curve.FastOutSlowIn })
        }.width('100%')
        Row() {
          Text(this.workspaces(this.revision).length === 0 ? '还没有工作区' :
            this.workspaces(this.revision).length.toString() + ' 个工作区')
            .fontSize(this.compact ? 10 : 11).fontColor(this.pal().text2).fontFamily(AppConfig.fontFamily)
          Blank()
          Text(this.runningId !== '' ? '正在打开 ' + this.runningName(this.revision) :
            this.sessionCount(this.revision).toString() + ' 个会话')
            .fontSize(this.compact ? 9 : 10).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
            .fontColor(this.runningId !== '' ? this.accent : this.pal().text3).fontFamily(AppConfig.fontFamily)
        }.width('100%').margin({ top: this.compact ? 8 : 10 })
      }
      .width('100%').height(this.cardHeight)
      .padding(this.compact ? 10 : 12)
      .borderRadius(this.compact ? 16 : 14)
      .backgroundColor(this.pal().card).backgroundBlurStyle(BlurStyle.Regular)
      .border({ width: this.expanded || this.runningId !== '' ? 1.5 : 0.5,
        color: this.expanded || this.runningId !== '' ? this.accent : this.pal().cardBorder, style: BorderStyle.Solid })
      .onClick((): void => { this.onToggle(); })
    }
  }
}

/**
 * Workspace list with 打开 / 编辑 / 新建 / 保存当前会话. `columns` = 1 renders compact rows (the expanded category
 * panel); more columns render a card grid (the PC sidebar 工作区 page).
 */
@Component
export struct WorkspacePanel {
  @StorageProp('currentTheme') theme: string = 'light';
  @StorageProp('accentColor') accent: string = '#007DFF';
  @Prop rows: OrgHostRow[] = [];
  @Prop activeRefs: string[] = [];
  @Prop runningId: string = '';
  @Prop columns: number = 1;
  onOpen: (workspace: Workspace) => void = (_workspace: Workspace): void => {};
  /** The editor sheet lives on the page: this panel sits in a subtree the host list rebuilds on refresh. */
  onEdit: (workspace: Workspace) => void = (_workspace: Workspace): void => {};
  @State revision: number = 0;
  private stop: (() => void) | null = null;

  aboutToAppear(): void {
    const store: WorkspaceStore = WorkspaceStore.getInstance();
    store.load();
    this.stop = store.subscribe((): void => { this.revision++; });
  }
  aboutToDisappear(): void { this.stop?.(); this.stop = null; }

  private pal(): Palette { return this.theme === 'light' ? buildLight(this.accent) : buildDark(this.accent); }
  private workspaces(_revision: number): Workspace[] { return WorkspaceStore.getInstance().list(); }
  private edit(workspace: Workspace): void { this.onEdit(workspace); }
  private open(workspace: Workspace): void {
    if (workspace.entries.length === 0) { this.edit(workspace); return; }
    this.onOpen(workspace);
  }
  private menu(workspace: Workspace): void {
    showWorkspaceMenu(this.getUIContext(), workspace, this.pal().text, this.pal().danger,
      (item: Workspace): void => { this.edit(item); });
  }
  /** Workspaces split into rows of `columns` cards for the PC grid. */
  private gridRows(_revision: number): Workspace[][] {
    const all: Workspace[] = this.workspaces(this.revision);
    const size: number = Math.max(1, this.columns);
    const result: Workspace[][] = [];
    for (let start: number = 0; start < all.length; start += size) { result.push(all.slice(start, start + size)); }
    return result;
  }
  private gridFillers(count: number): number[] {
    const result: number[] = [];
    for (let index: number = count; index < Math.max(1, this.columns); index++) { result.push(index); }
    return result;
  }

  @Builder private openButton(workspace: Workspace) {
    Button(workspace.entries.length === 0 ? '编辑' : (this.runningId === workspace.id ? '打开中' : '打开'))
      .height(32).fontSize(13).padding({ left: 14, right: 14 })
      .backgroundColor(workspace.entries.length === 0 ? this.pal().surface : workspace.color)
      .fontColor(workspace.entries.length === 0 ? this.accent : Color.White)
      .onClick((): void => { this.open(workspace); })
  }

  @Builder private protocolChips(workspace: Workspace) {
    Row({ space: 4 }) {
      ForEach(workspaceProtocols(workspace), (label: string): void => {
        Text(label).fontSize(10).fontColor(workspace.color).padding({ left: 5, right: 5, top: 1, bottom: 1 })
          .borderRadius(5).backgroundColor(workspaceTint(workspace.color, '1F'))
      }, (label: string): string => label)
    }
  }

  @Builder private listRow(workspace: Workspace) {
    Row({ space: 12 }) {
      Text(workspace.icon).fontSize(19).width(40).height(40).textAlign(TextAlign.Center).borderRadius(13)
        .backgroundColor(workspaceTint(workspace.color, '2E'))
      Column({ space: 3 }) {
        Text(workspace.name).fontSize(15).fontWeight(FontWeight.Medium).fontColor(this.pal().text)
          .fontFamily(AppConfig.fontFamily).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(workspaceSubtitle(workspace, this.rows)).fontSize(11).fontColor(this.pal().text3).maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        this.protocolChips(workspace)
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      this.openButton(workspace)
    }
    .width('100%').padding({ left: 12, right: 10, top: 10, bottom: 10 })
    .onClick((): void => { this.edit(workspace); })
    .gesture(LongPressGesture().onAction((): void => { this.menu(workspace); }))
  }

  @Builder private gridCard(workspace: Workspace) {
    Column({ space: 8 }) {
      Row() {
        Text(workspace.icon).fontSize(22).width(44).height(44).textAlign(TextAlign.Center).borderRadius(14)
          .backgroundColor(workspaceTint(workspace.color, '2E'))
        Blank()
        SymbolGlyph($r('sys.symbol.line_3_horizontal')).fontSize(16).fontColor([this.pal().text3]).padding(6)
          .onClick((): void => { this.menu(workspace); })
      }.width('100%')
      Text(workspace.name).fontSize(16).fontWeight(FontWeight.Medium).fontColor(this.pal().text)
        .fontFamily(AppConfig.fontFamily).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
      Text(workspaceSubtitle(workspace, this.rows)).fontSize(12).fontColor(this.pal().text3).maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
      Row() { this.protocolChips(workspace) }.width('100%').height(18)
      Row() { this.openButton(workspace) }.width('100%').justifyContent(FlexAlign.End)
    }
    .width('100%').padding(14).borderRadius(18).backgroundColor(this.pal().card)
    .backgroundBlurStyle(BlurStyle.Regular)
    .border({ width: this.runningId === workspace.id ? 1.5 : 0.5,
      color: this.runningId === workspace.id ? workspace.color : this.pal().cardBorder })
    .onClick((): void => { this.edit(workspace); })
    .gesture(LongPressGesture().onAction((): void => { this.menu(workspace); }))
  }

  @Builder private actions() {
    Row({ space: 10 }) {
      Button('＋ 新建工作区').layoutWeight(1).height(40).fontSize(13).backgroundColor(this.pal().surface)
        .fontColor(this.accent).onClick((): void => {
          const created: Workspace | null = createWorkspace(this.getUIContext());
          if (created !== null) { this.edit(created); }
        })
      if (this.activeRefs.length > 0) {
        Button('保存当前会话').layoutWeight(1).height(40).fontSize(13).backgroundColor(this.pal().surface)
          .fontColor(this.accent).onClick((): void => {
            const saved: Workspace | null = saveCurrentWorkspace(this.getUIContext(), this.rows, this.activeRefs);
            if (saved !== null) { this.edit(saved); }
          })
      }
    }.width('100%')
  }

  build() {
    Column({ space: 10 }) {
      if (this.columns <= 1) {
        if (this.workspaces(this.revision).length === 0) {
          Text('把常用的几台主机存成工作区，点「打开」会按顺序连接；PC 上还能按布局摆放窗口。')
            .fontSize(12).fontColor(this.pal().text3).lineHeight(17).width('100%').padding({ left: 4, right: 4 })
        } else {
          Column() {
            ForEach(this.workspaces(this.revision), (workspace: Workspace, index: number): void => {
              if (index > 0) { Divider().strokeWidth(0.5).color(this.pal().cardBorder).margin({ left: 64, right: 12 }) }
              this.listRow(workspace)
            }, (workspace: Workspace): string => workspace.id + ':' + workspace.updatedAt.toString() + ':' +
              workspace.order.toString() + ':' + (this.runningId === workspace.id ? 'r' : ''))
          }.width('100%').backgroundColor(this.pal().card).borderRadius(16)
          .border({ width: 0.5, color: this.pal().cardBorder })
        }
      } else {
        if (this.workspaces(this.revision).length === 0) {
          Text('还没有工作区。把常用的几台主机存成工作区，一键依次打开，并按布局摆放独立窗口。')
            .fontSize(13).fontColor(this.pal().text3).width('100%').padding({ top: 8, bottom: 8 })
        } else {
          ForEach(this.gridRows(this.revision), (line: Workspace[], lineIndex: number): void => {
            Row({ space: 12 }) {
              ForEach(line, (workspace: Workspace): void => {
                Column() { this.gridCard(workspace) }.layoutWeight(1)
              }, (workspace: Workspace): string => workspace.id + ':' + workspace.updatedAt.toString() + ':' +
                workspace.order.toString() + ':' + (this.runningId === workspace.id ? 'r' : ''))
              ForEach(this.gridFillers(line.length), (filler: number): void => {
                Blank().layoutWeight(1)
              }, (filler: number): string => 'f' + lineIndex.toString() + ':' + filler.toString())
            }.width('100%').alignItems(VerticalAlign.Top)
          }, (line: Workspace[], lineIndex: number): string => lineIndex.toString() + ':' +
            line.map((item: Workspace): string => item.id + item.updatedAt.toString()).join(',') + this.runningId)
        }
      }
      this.actions()
    }
    .width('100%')
  }
}
