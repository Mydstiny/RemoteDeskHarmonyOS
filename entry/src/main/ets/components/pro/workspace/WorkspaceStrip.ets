import { AppConfig, buildDark, buildLight, Palette } from '../../../common/Theme';
import { ProBadge } from '../../ProBadge';
import { ProEntries } from '../../../services/pro/ProEntries';
import {
  MAX_WORKSPACES, missingWorkspaceRefs, newWorkspace, sortedEntries, Workspace, WORKSPACE_COLORS, WORKSPACE_ICONS,
  WorkspaceEntry, workspaceLayoutLabel
} from '../../../services/pro/workspace/WorkspacePolicy';
import { WorkspaceStore } from '../../../services/pro/workspace/WorkspaceStore';
import { captureWorkspace, WorkspaceCaptureSession } from '../../../services/pro/workspace/WorkspaceCapture';
import { orgProtocolLabel, OrgHostRow } from '../../../services/pro/org/HostOrganizationDirectory';
import { ProWorkspaceEditorPanel } from '../../ProWorkspaceEditorPanel';

/**
 * Home-page band of Pro workspaces: one card per workspace with its sessions and a one-tap 打开, plus 新建 and
 * 保存当前会话. The full editor opens in a sheet owned by this band.
 */
@Component
export struct WorkspaceStrip {
  @StorageProp('currentTheme') theme: string = 'light';
  @StorageProp('accentColor') accent: string = '#007DFF';
  @Prop rows: OrgHostRow[] = [];
  /** Hosts with a live session right now, offered by 保存当前会话. */
  @Prop activeRefs: string[] = [];
  /** The workspace being opened, if any. */
  @Prop runningId: string = '';
  onOpen: (workspace: Workspace) => void = (_workspace: Workspace): void => {};
  @State revision: number = 0;
  @State showEditor: boolean = false;
  @State editing: Workspace = newWorkspace('', '', '#007DFF', '🖥️', 0, 0);
  private stop: (() => void) | null = null;

  aboutToAppear(): void {
    const store: WorkspaceStore = WorkspaceStore.getInstance();
    store.load();
    this.stop = store.subscribe((): void => { this.revision++; });
  }
  aboutToDisappear(): void { this.stop?.(); this.stop = null; }

  private pal(): Palette { return this.theme === 'light' ? buildLight(this.accent) : buildDark(this.accent); }
  private tint(color: string, alpha: string): string {
    return /^#[0-9A-Fa-f]{6}$/.test(color) ? '#' + alpha + color.substring(1) : color;
  }
  private toast(message: string): void { this.getUIContext().getPromptAction().showToast({ message, duration: 1800 }); }
  private workspaces(_revision: number): Workspace[] { return WorkspaceStore.getInstance().list(); }
  private liveRefs(): string[] { return this.rows.map((row: OrgHostRow): string => row.ref); }
  private protocols(workspace: Workspace): string[] {
    const result: string[] = [];
    sortedEntries(workspace.entries).forEach((entry: WorkspaceEntry): void => {
      const label: string = orgProtocolLabel(entry.protocol);
      if (result.indexOf(label) < 0) { result.push(label); }
    });
    return result.slice(0, 4);
  }
  private subtitle(workspace: Workspace): string {
    const missing: number = missingWorkspaceRefs(workspace, this.liveRefs()).length;
    return workspace.entries.length.toString() + ' 个会话 · ' + workspaceLayoutLabel(workspace.layout) +
      (missing > 0 ? ' · ' + missing.toString() + ' 台已删除' : '');
  }
  private edit(workspace: Workspace): void { this.editing = workspace; this.showEditor = true; }
  private create(): void {
    const store: WorkspaceStore = WorkspaceStore.getInstance();
    if (!store.canAdd()) { this.toast('最多 ' + MAX_WORKSPACES.toString() + ' 个工作区'); return; }
    const count: number = this.workspaces(this.revision).length;
    const workspace: Workspace = newWorkspace('workspace-' + Date.now().toString(36), '工作区 ' + (count + 1).toString(),
      WORKSPACE_COLORS[count % WORKSPACE_COLORS.length], WORKSPACE_ICONS[count % WORKSPACE_ICONS.length], count);
    if (store.save(workspace)) { this.edit(workspace); } else { this.toast('工作区未保存，请稍后重试'); }
  }
  private saveCurrent(): void {
    const store: WorkspaceStore = WorkspaceStore.getInstance();
    if (!store.canAdd()) { this.toast('最多 ' + MAX_WORKSPACES.toString() + ' 个工作区'); return; }
    const sessions: WorkspaceCaptureSession[] = [];
    this.activeRefs.forEach((ref: string): void => {
      const row: OrgHostRow | undefined = this.rows.find((item: OrgHostRow): boolean => item.ref === ref);
      if (row !== undefined) { sessions.push({ hostRef: ref, protocol: row.protocol }); }
    });
    if (sessions.length === 0) { this.toast('当前没有已连接的会话'); return; }
    const count: number = this.workspaces(this.revision).length;
    try {
      const workspace: Workspace = captureWorkspace('workspace-' + Date.now().toString(36), '当前会话 ' + (count + 1).toString(),
        WORKSPACE_COLORS[count % WORKSPACE_COLORS.length], WORKSPACE_ICONS[0], sessions, 'custom');
      workspace.order = count;
      if (store.save(workspace)) { this.edit(workspace); } else { this.toast('工作区未保存，请稍后重试'); }
    } catch (_error) {
      this.toast('当前会话无法保存为工作区');
    }
  }
  private remove(workspace: Workspace): void {
    this.getUIContext().getPromptAction().showDialog({
      title: '删除工作区', message: '删除「' + workspace.name + '」？主机和正在进行的会话不受影响。',
      buttons: [{ text: '取消', color: this.pal().text2 }, { text: '删除', color: this.pal().danger }]
    }).then((result): void => {
      if (result.index === 1) { WorkspaceStore.getInstance().remove(workspace.id); }
    }).catch((): void => {});
  }
  private menu(workspace: Workspace): void {
    this.getUIContext().getPromptAction().showActionMenu({
      title: workspace.name,
      buttons: [{ text: '编辑', color: this.pal().text }, { text: '前移', color: this.pal().text },
        { text: '后移', color: this.pal().text }, { text: '删除', color: this.pal().danger }]
    }).then((result): void => {
      if (result.index === 0) { this.edit(workspace); }
      if (result.index === 1) { WorkspaceStore.getInstance().move(workspace.id, -1); }
      if (result.index === 2) { WorkspaceStore.getInstance().move(workspace.id, 1); }
      if (result.index === 3) { this.remove(workspace); }
    }).catch((): void => {});
  }

  @Builder private card(workspace: Workspace) {
    Column({ space: 8 }) {
      Row() {
        Text(workspace.icon).fontSize(20).width(38).height(38).textAlign(TextAlign.Center).borderRadius(12)
          .backgroundColor(this.tint(workspace.color, '2E'))
        Blank()
        SymbolGlyph($r('sys.symbol.line_3_horizontal')).fontSize(16).fontColor([this.pal().text3]).padding(6)
          .onClick((): void => { this.menu(workspace); })
      }.width('100%')
      Text(workspace.name).fontSize(15).fontWeight(FontWeight.Medium).fontColor(this.pal().text)
        .fontFamily(AppConfig.fontFamily).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
      Text(this.subtitle(workspace)).fontSize(11).fontColor(this.pal().text3).maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
      Row({ space: 4 }) {
        ForEach(this.protocols(workspace), (label: string): void => {
          Text(label).fontSize(10).fontColor(workspace.color).padding({ left: 6, right: 6, top: 2, bottom: 2 })
            .borderRadius(6).backgroundColor(this.tint(workspace.color, '1F'))
        }, (label: string): string => label)
      }.width('100%').height(18)
      Button(this.runningId === workspace.id ? '打开中…' : '打开').width('100%').height(32).fontSize(13)
        .backgroundColor(workspace.entries.length === 0 ? this.pal().surface : workspace.color)
        .fontColor(workspace.entries.length === 0 ? this.pal().text3 : Color.White)
        .onClick((): void => {
          if (workspace.entries.length === 0) { this.edit(workspace); return; }
          this.onOpen(workspace);
        })
    }
    .width(168).padding(12).borderRadius(20).backgroundColor(this.pal().card)
    .border({ width: this.runningId === workspace.id ? 1.5 : 0.5,
      color: this.runningId === workspace.id ? workspace.color : this.pal().cardBorder })
    .margin({ right: 10 })
    .gesture(LongPressGesture().onAction((): void => { this.menu(workspace); }))
  }

  @Builder private addCard(icon: Resource, title: string, detail: string, onTap: () => void) {
    Column({ space: 6 }) {
      SymbolGlyph(icon).fontSize(22).fontColor([this.accent])
      Text(title).fontSize(13).fontColor(this.accent).fontWeight(FontWeight.Medium)
      Text(detail).fontSize(11).fontColor(this.pal().text3).textAlign(TextAlign.Center).maxLines(2)
    }
    .width(132).height(156).justifyContent(FlexAlign.Center).padding(10).borderRadius(20).margin({ right: 10 })
    .border({ width: 1, color: this.tint(this.accent, '66'), style: BorderStyle.Dashed })
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
      }.layoutWeight(1).scrollBar(BarState.Off).align(Alignment.Top).edgeEffect(EdgeEffect.Spring)
    }.width('100%').height('100%').backgroundColor(this.pal().sheetBg)
  }

  build() {
    Column({ space: 8 }) {
      if (ProEntries.visible('pro.workspaces')) {
        Row({ space: 6 }) {
          Text('工作区').fontSize(15).fontWeight(FontWeight.Medium).fontColor(this.pal().text)
            .fontFamily(AppConfig.fontFamily)
          ProBadge()
          Blank()
          if (this.workspaces(this.revision).length > 0) {
            Text(this.workspaces(this.revision).length.toString() + ' 个').fontSize(12).fontColor(this.pal().text3)
          }
        }.width('100%').padding({ left: 20, right: 20 })
        Scroll() {
          Row() {
            ForEach(this.workspaces(this.revision), (workspace: Workspace): void => { this.card(workspace) },
              (workspace: Workspace): string => workspace.id + ':' + workspace.updatedAt.toString() + ':' +
                workspace.order.toString() + ':' + (this.runningId === workspace.id ? 'r' : ''))
            if (this.activeRefs.length > 0) {
              this.addCard($r('sys.symbol.rectangle_on_rectangle'), '保存当前会话',
                this.activeRefs.length.toString() + ' 个会话进行中', (): void => { this.saveCurrent(); })
            }
            this.addCard($r('sys.symbol.plus'), '新建工作区', '保存一组常用会话，一键依次打开',
              (): void => { this.create(); })
          }.padding({ left: 16, right: 6 }).alignItems(VerticalAlign.Top)
        }.scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off).align(Alignment.Start).width('100%')
      }
    }
    .width('100%').padding({ top: 4, bottom: 8 })
    .bindSheet($$this.showEditor, this.editorSheet(), {
      height: SheetSize.LARGE, dragBar: true, showClose: false, backgroundColor: this.pal().sheetBg
    })
  }
}
