import { display } from '@kit.ArkUI';
import { ProSymbolIcon } from '../ProSymbolIcon';
import { AppConfig, buildDark, buildLight, Palette } from '../../../common/Theme';
import { ProBadge } from '../../ProBadge';
import { ProEntries } from '../../../services/pro/ProEntries';
import { newWorkspace, Workspace } from '../../../services/pro/workspace/WorkspacePolicy';
import { WorkspaceStore } from '../../../services/pro/workspace/WorkspaceStore';
import { OrgHostRow } from '../../../services/pro/org/HostOrganizationDirectory';
import { ProWorkspaceEditorPanel } from '../../ProWorkspaceEditorPanel';
import {
  saveCurrentWorkspace, showWorkspaceMenu, workspaceSubtitle, workspaceTint
} from './WorkspaceActions';

/**
 * Compact workspace row for the classic (flat) host list: one slim line when empty, otherwise slim cards with a
 * play button. The editor opens in a sheet owned by this row.
 */
@Component
export struct WorkspaceStrip {
  @StorageProp('currentTheme') theme: string = 'light';
  @StorageProp('accentColor') accent: string = '#007DFF';
  @Prop rows: OrgHostRow[] = [];
  @Prop activeRefs: string[] = [];
  @Prop runningId: string = '';
  onOpen: (workspace: Workspace) => void = (_workspace: Workspace): void => {};
  @State revision: number = 0;
  @State showEditor: boolean = false;
  @State editing: Workspace = newWorkspace('', '', '#007DFF', 'sym.desktop_fill', 0, 0);
  private stop: (() => void) | null = null;

  aboutToAppear(): void {
    const store: WorkspaceStore = WorkspaceStore.getInstance();
    store.load();
    this.stop = store.subscribe((): void => { this.revision++; });
  }
  aboutToDisappear(): void { this.stop?.(); this.stop = null; }

  private sheetMaxHeight(): number {
    try {
      const screen: display.Display = display.getDefaultDisplaySync();
      return Math.round(screen.height / Math.max(1, screen.densityPixels) * 0.85);
    } catch (_error) {
      return 640;
    }
  }
  private pal(): Palette { return this.theme === 'light' ? buildLight(this.accent) : buildDark(this.accent); }
  private workspaces(_revision: number): Workspace[] { return WorkspaceStore.getInstance().list(); }
  private edit(workspace: Workspace): void { this.editing = workspace; this.showEditor = true; }
  private saveCurrent(): void {
    const workspace: Workspace | null = saveCurrentWorkspace(this.getUIContext(), this.rows, this.activeRefs);
    if (workspace !== null) { this.edit(workspace); }
  }
  private menu(workspace: Workspace): void {
    showWorkspaceMenu(this.getUIContext(), workspace, this.pal().text, this.pal().danger,
      (item: Workspace): void => { this.edit(item); });
  }

  @Builder private card(workspace: Workspace) {
    Row({ space: 10 }) {
      Column() { ProSymbolIcon({ icon: workspace.icon, glyphSize: 17, color: workspace.color }) }.width(34).height(34).justifyContent(FlexAlign.Center).borderRadius(11)
        .backgroundColor(workspaceTint(workspace.color, '2E'))
      Column({ space: 2 }) {
        Text(workspace.name).fontSize(14).fontWeight(FontWeight.Medium).fontColor(this.pal().text)
          .fontFamily(AppConfig.fontFamily).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.runningId === workspace.id ? '打开中…' : workspaceSubtitle(workspace, this.rows)).fontSize(11)
          .fontColor(this.runningId === workspace.id ? workspace.color : this.pal().text3).maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      Row() {
        SymbolGlyph($r('sys.symbol.arrowshape_right_fill')).fontSize(14)
          .fontColor([workspace.entries.length === 0 ? this.pal().text3 : Color.White])
      }.width(32).height(32).borderRadius(16).justifyContent(FlexAlign.Center)
      .backgroundColor(workspace.entries.length === 0 ? this.pal().surface : workspace.color)
      .accessibilityText('打开 ' + workspace.name)
      .onClick((): void => {
        if (workspace.entries.length === 0) { this.edit(workspace); return; }
        this.onOpen(workspace);
      })
    }
    .width(212).height(56).padding({ left: 10, right: 10 }).borderRadius(18).margin({ right: 8 })
    .backgroundColor(this.pal().card).backgroundBlurStyle(BlurStyle.Regular)
    .border({ width: this.runningId === workspace.id ? 1.5 : 0.5,
      color: this.runningId === workspace.id ? workspace.color : this.pal().cardBorder })
    .onClick((): void => { this.edit(workspace); })
    .gesture(LongPressGesture().onAction((): void => { this.menu(workspace); }))
  }

  @Builder private smallAction(icon: Resource, label: string, onTap: () => void) {
    Row({ space: 4 }) {
      SymbolGlyph(icon).fontSize(14).fontColor([this.accent])
      Text(label).fontSize(12).fontColor(this.accent)
    }.height(56).padding({ left: 12, right: 12 }).borderRadius(18).margin({ right: 8 })
    .border({ width: 1, color: workspaceTint(this.accent, '55'), style: BorderStyle.Dashed })
    .onClick((): void => { onTap(); })
  }

  @Builder private editorSheet() {
    Column() {
      Scroll() {
        Column() {
          ProWorkspaceEditorPanel({
            workspace: this.editing,
            extraRows: this.rows.filter((row: OrgHostRow): boolean => row.protocol === 'moonlight'),
            onClose: (): void => { this.showEditor = false; }
          })
        }.padding({ left: 16, right: 16, top: 18, bottom: 28 })
      }.constraintSize({ maxHeight: this.sheetMaxHeight() }).scrollBar(BarState.Off).align(Alignment.Top)
      .edgeEffect(EdgeEffect.Spring)
    }.width('100%').backgroundColor(this.pal().sheetBg)
  }

  build() {
    Column() {
      if (ProEntries.visible('pro.workspaces')) {
        if (this.workspaces(this.revision).length === 0) {
          Row({ space: 8 }) {
            SymbolGlyph($r('sys.symbol.rectangle_on_rectangle')).fontSize(16).fontColor([this.accent])
            Text('工作区').fontSize(14).fontWeight(FontWeight.Medium).fontColor(this.pal().text)
            ProBadge()
            Text('点「+」→「工作区」新建').fontSize(12).fontColor(this.pal().text3).layoutWeight(1).maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            if (this.activeRefs.length > 0) {
              Text('保存当前会话').fontSize(12).fontColor(this.accent).padding(4)
                .onClick((): void => { this.saveCurrent(); })
            }
          }
          .width('100%').height(44).padding({ left: 14, right: 10 }).borderRadius(16)
          .backgroundColor(this.pal().card).backgroundBlurStyle(BlurStyle.Regular)
          .border({ width: 0.5, color: this.pal().cardBorder })
          .margin({ left: 16, right: 16 })
        } else {
          Scroll() {
            Row() {
              ForEach(this.workspaces(this.revision), (workspace: Workspace): void => { this.card(workspace) },
                (workspace: Workspace): string => workspace.id + ':' + workspace.updatedAt.toString() + ':' +
                  workspace.order.toString() + ':' + (this.runningId === workspace.id ? 'r' : ''))
              if (this.activeRefs.length > 0) {
                this.smallAction($r('sys.symbol.rectangle_on_rectangle'), '保存当前', (): void => { this.saveCurrent(); })
              }
            }.padding({ left: 16, right: 8 })
          }.scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off).align(Alignment.Start).width('100%')
        }
      }
    }
    .width('100%').padding({ top: 2, bottom: 6 })
    .bindSheet($$this.showEditor, this.editorSheet(), {
      height: SheetSize.FIT_CONTENT, dragBar: true, showClose: false, backgroundColor: this.pal().sheetBg
    })
  }
}
