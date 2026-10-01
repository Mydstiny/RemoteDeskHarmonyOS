import { AppConfig, buildDark, buildLight, Palette } from '../../../common/Theme';
import { ProBadge } from '../../ProBadge';
import { ProEntries } from '../../../services/pro/ProEntries';
import { Workspace } from '../../../services/pro/workspace/WorkspacePolicy';
import { WorkspaceStore } from '../../../services/pro/workspace/WorkspaceStore';
import { OrgHostRow } from '../../../services/pro/org/HostOrganizationDirectory';
import { ProWorkspaceEditorPanel } from '../../ProWorkspaceEditorPanel';
import {
  createWorkspace, saveCurrentWorkspace, showWorkspaceMenu, workspaceProtocols, workspaceSubtitle, workspaceTint
} from './WorkspaceActions';

/**
 * Workspace entry for the categorized host page: a category card in the same style as RDP / SSH / VNC. Tapping it
 * opens a sheet listing every workspace with 打开, plus 新建 / 保存当前会话 and the editor.
 */
@Component
export struct WorkspaceGroupCard {
  @StorageProp('currentTheme') theme: string = 'light';
  @StorageProp('accentColor') accent: string = '#007DFF';
  @Prop rows: OrgHostRow[] = [];
  @Prop activeRefs: string[] = [];
  @Prop runningId: string = '';
  @Prop compact: boolean = true;
  @Prop cardHeight: number = 88;
  onOpen: (workspace: Workspace) => void = (_workspace: Workspace): void => {};
  @State revision: number = 0;
  @State showList: boolean = false;
  @State editing: Workspace | null = null;
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
  private open(workspace: Workspace): void {
    if (workspace.entries.length === 0) { this.editing = workspace; return; }
    this.showList = false;
    this.onOpen(workspace);
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
        Row({ space: 4 }) {
          ForEach(workspaceProtocols(workspace), (label: string): void => {
            Text(label).fontSize(10).fontColor(workspace.color).padding({ left: 5, right: 5, top: 1, bottom: 1 })
              .borderRadius(5).backgroundColor(workspaceTint(workspace.color, '1F'))
          }, (label: string): string => label)
        }
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      Button(workspace.entries.length === 0 ? '编辑' : (this.runningId === workspace.id ? '打开中' : '打开'))
        .height(32).fontSize(13).padding({ left: 14, right: 14 })
        .backgroundColor(workspace.entries.length === 0 ? this.pal().surface : workspace.color)
        .fontColor(workspace.entries.length === 0 ? this.accent : Color.White)
        .onClick((): void => { this.open(workspace); })
    }
    .width('100%').padding({ left: 14, right: 12, top: 12, bottom: 12 })
    .onClick((): void => { this.editing = workspace; })
    .gesture(LongPressGesture().onAction((): void => {
      showWorkspaceMenu(this.getUIContext(), workspace, this.pal().text, this.pal().danger,
        (item: Workspace): void => { this.editing = item; });
    }))
  }

  @Builder private listSheet() {
    Column() {
      if (this.editing !== null) {
        Scroll() {
          Column() {
            ProWorkspaceEditorPanel({
              workspace: this.editing as Workspace,
              extraRows: this.rows.filter((row: OrgHostRow): boolean => row.protocol === 'moonlight'),
              onClose: (): void => { this.editing = null; }
            })
          }.padding({ left: 16, right: 16, top: 18, bottom: 28 })
        }.layoutWeight(1).scrollBar(BarState.Off).align(Alignment.Top).edgeEffect(EdgeEffect.Spring)
      } else {
        Row({ space: 6 }) {
          Text('工作区').fontSize(20).fontWeight(FontWeight.Bold).fontColor(this.pal().text).fontFamily(AppConfig.fontFamily)
          Blank()
          Text('完成').fontSize(15).fontColor(this.accent).padding(6).onClick((): void => { this.showList = false; })
        }.width('100%').padding({ left: 20, right: 16, top: 18, bottom: 6 })
        Text('点「打开」按顺序连接工作区里的会话；点工作区可编辑，长按可排序或删除。').fontSize(12)
          .fontColor(this.pal().text3).width('100%').padding({ left: 20, right: 20, bottom: 10 })
        Scroll() {
          Column({ space: 10 }) {
            if (this.workspaces(this.revision).length > 0) {
              Column() {
                ForEach(this.workspaces(this.revision), (workspace: Workspace, index: number): void => {
                  if (index > 0) { Divider().strokeWidth(0.5).color(this.pal().cardBorder).margin({ left: 66, right: 14 }) }
                  this.listRow(workspace)
                }, (workspace: Workspace): string => workspace.id + ':' + workspace.updatedAt.toString() + ':' +
                  workspace.order.toString() + ':' + (this.runningId === workspace.id ? 'r' : ''))
              }.width('100%').backgroundColor(this.pal().card).borderRadius(18)
            }
            Row({ space: 10 }) {
              Button('＋ 新建工作区').layoutWeight(1).height(44).fontSize(14).backgroundColor(this.pal().card)
                .fontColor(this.accent).onClick((): void => {
                  const created: Workspace | null = createWorkspace(this.getUIContext());
                  if (created !== null) { this.editing = created; }
                })
              if (this.activeRefs.length > 0) {
                Button('保存当前会话').layoutWeight(1).height(44).fontSize(14).backgroundColor(this.pal().card)
                  .fontColor(this.accent).onClick((): void => {
                    const saved: Workspace | null = saveCurrentWorkspace(this.getUIContext(), this.rows, this.activeRefs);
                    if (saved !== null) { this.editing = saved; }
                  })
              }
            }.width('100%')
          }.padding({ left: 16, right: 16, bottom: 28 })
        }.layoutWeight(1).scrollBar(BarState.Off).align(Alignment.Top).edgeEffect(EdgeEffect.Spring)
      }
    }.width('100%').height('100%').backgroundColor(this.pal().sheetBg)
  }

  build() {
    Column() {
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
              Row({ space: 6 }) {
                Text('工作区').fontSize(this.compact ? 16 : 18).fontWeight(FontWeight.Medium)
                  .fontColor(this.pal().text).fontFamily(AppConfig.fontFamily)
                ProBadge()
              }
              Text('一键依次打开常用会话').fontSize(this.compact ? 10 : 11).fontColor(this.pal().text3)
                .fontFamily(AppConfig.fontFamily).margin({ top: 3 }).maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }.alignItems(HorizontalAlign.Start).layoutWeight(1).margin({ left: this.compact ? 8 : 10 })
            SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(this.compact ? 16 : 18).fontColor([this.pal().text3])
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
        .border({ width: this.runningId !== '' ? 1.5 : 0.5,
          color: this.runningId !== '' ? this.accent : this.pal().cardBorder, style: BorderStyle.Solid })
        .onClick((): void => { this.editing = null; this.showList = true; })
      }
    }
    .width('100%')
    .bindSheet($$this.showList, this.listSheet(), {
      height: SheetSize.LARGE, dragBar: true, showClose: false, backgroundColor: this.pal().sheetBg,
      onDisappear: (): void => { this.editing = null; }
    })
  }
}
