import { AppConfig, buildDark, buildLight, Palette } from '../common/Theme';
import { ProSymbolIcon } from './pro/ProSymbolIcon';
import { ProEntries } from '../services/pro/ProEntries';
import {
  addWorkspaceEntries, applyLayoutPreset, copyWorkspace, MAX_WORKSPACE_ENTRIES, MAX_WORKSPACE_NAME_LENGTH,
  moveWorkspaceEntry, newWorkspace, removeWorkspaceEntry, snapWorkspaceFrame, sortedEntries, Workspace,
  WORKSPACE_COLORS, WORKSPACE_ICONS, WORKSPACE_LAYOUT_PRESETS, WorkspaceEntry, workspaceEntryFrame, WorkspaceFrame,
  WorkspaceLayoutPreset, workspaceLayoutLabel
} from '../services/pro/workspace/WorkspacePolicy';
import { WorkspaceStore } from '../services/pro/workspace/WorkspaceStore';
import { orgHostRows, OrgHostRow, orgProtocolLabel, orgRowDetail } from '../services/pro/org/HostOrganizationDirectory';

type EditorTab = 'sessions' | 'layout';
const CANVAS_RATIO: number = 10 / 16;

/**
 * Full Pro workspace editor: name, color, icon, ordered session entries with per-entry options, a host picker over
 * every protocol, and a layout canvas whose window rectangles snap to an 8 × 8 grid. Every change saves at once.
 */
@Component
export struct ProWorkspaceEditorPanel {
  @StorageProp('currentTheme') theme: string = 'light';
  @StorageProp('accentColor') accent: string = '#007DFF';
  @Prop workspace: Workspace = newWorkspace('', '', '#007DFF', 'sym.desktop_fill', 0, 0);
  /** Hosts the stores cannot list on their own (Moonlight, from the home page). */
  @Prop extraRows: OrgHostRow[] = [];
  @Prop showClose: boolean = true;
  onClose: () => void = (): void => {};
  @State draft: Workspace = newWorkspace('', '', '#007DFF', 'sym.desktop_fill', 0, 0);
  @State nameDraft: string = '';
  @State tab: EditorTab = 'sessions';
  @State openRef: string = '';
  @State dirDraft: string = '';
  @State picking: boolean = false;
  @State pickQuery: string = '';
  @State picked: string[] = [];
  @State selectedFrameRef: string = '';
  @State canvasWidth: number = 300;
  private dragStart: WorkspaceFrame | null = null;

  aboutToAppear(): void {
    this.draft = copyWorkspace(this.workspace);
    this.nameDraft = this.workspace.name;
    if (this.draft.entries.length === 0) { this.picking = true; }
  }

  private pal(): Palette { return this.theme === 'light' ? buildLight(this.accent) : buildDark(this.accent); }
  private tint(color: string, alpha: string): string {
    return /^#[0-9A-Fa-f]{6}$/.test(color) ? '#' + alpha + color.substring(1) : color;
  }
  private toast(message: string): void { this.getUIContext().getPromptAction().showToast({ message, duration: 1800 }); }
  private rows(): OrgHostRow[] { return orgHostRows(this.extraRows); }
  private row(ref: string): OrgHostRow | undefined { return this.rows().find((item: OrgHostRow): boolean => item.ref === ref); }
  private entries(): WorkspaceEntry[] { return sortedEntries(this.draft.entries); }

  private commit(next: Workspace): void {
    if (!ProEntries.visible('pro.workspaces')) { this.toast('工作区与布局需要 Pro'); return; }
    if (WorkspaceStore.getInstance().save(next)) { this.draft = next; }
    else { this.toast('工作区未保存，请检查内容后重试'); }
  }
  private update(change: (next: Workspace) => void): void {
    const next: Workspace = copyWorkspace(this.draft);
    change(next);
    this.commit(next);
  }
  private saveName(): void {
    const name: string = this.nameDraft.trim().slice(0, MAX_WORKSPACE_NAME_LENGTH);
    if (name.length === 0 || name === this.draft.name) { return; }
    this.update((next: Workspace): void => { next.name = name; });
  }
  private close(): void { this.saveName(); this.onClose(); }
  private addPicked(): void {
    const refs: string[] = this.picked.slice();
    const protocols: string[] = refs.map((ref: string): string => {
      const row: OrgHostRow | undefined = this.row(ref);
      return row === undefined ? '' : row.protocol;
    });
    if (this.draft.entries.length + refs.length > MAX_WORKSPACE_ENTRIES) {
      this.toast('每个工作区最多 ' + MAX_WORKSPACE_ENTRIES.toString() + ' 个会话，多出的未添加');
    }
    this.update((next: Workspace): void => {
      next.entries = addWorkspaceEntries(next.entries, refs, protocols);
      if (next.layout !== undefined && next.layout !== 'custom') { next.entries = applyLayoutPreset(next.entries, next.layout); }
    });
    this.picked = []; this.picking = false; this.pickQuery = '';
  }
  private togglePick(ref: string, on: boolean): void {
    this.picked = on ? this.picked.concat([ref]) : this.picked.filter((item: string): boolean => item !== ref);
  }
  private pickRows(): OrgHostRow[] {
    const query: string = this.pickQuery.trim().toLowerCase();
    const used: string[] = this.draft.entries.map((entry: WorkspaceEntry): string => entry.hostRef);
    return this.rows().filter((row: OrgHostRow): boolean => used.indexOf(row.ref) < 0 && (query === '' ||
      row.label.toLowerCase().includes(query) || row.address.toLowerCase().includes(query) ||
      row.protocol.includes(query)));
  }
  private setEntry(ref: string, change: (entry: WorkspaceEntry) => void): void {
    this.update((next: Workspace): void => {
      next.entries.forEach((entry: WorkspaceEntry): void => { if (entry.hostRef === ref) { change(entry); } });
    });
  }
  private saveDirectory(entry: WorkspaceEntry): void {
    const dir: string = this.dirDraft.trim();
    if (dir === entry.view.sshDirectory) { return; }
    if (dir !== '' && !dir.startsWith('/')) { this.toast('目录需要以 / 开头'); return; }
    this.setEntry(entry.hostRef, (item: WorkspaceEntry): void => { item.view.sshDirectory = dir; });
  }
  private applyPreset(preset: WorkspaceLayoutPreset): void {
    this.update((next: Workspace): void => { next.entries = applyLayoutPreset(next.entries, preset); next.layout = preset; });
  }

  // ---------- 布局画布 ----------
  private canvasHeight(): number { return Math.round(this.canvasWidth * CANVAS_RATIO); }
  private liveFrame(ref: string, frame: WorkspaceFrame): void {
    const next: Workspace = copyWorkspace(this.draft);
    next.entries.forEach((entry: WorkspaceEntry): void => { if (entry.hostRef === ref) { entry.frame = frame; } });
    next.layout = 'custom';
    this.draft = next;
  }
  private endFrame(ref: string): void {
    const next: Workspace = copyWorkspace(this.draft);
    next.entries.forEach((entry: WorkspaceEntry): void => {
      if (entry.hostRef === ref) { entry.frame = snapWorkspaceFrame(workspaceEntryFrame(entry)); }
    });
    this.dragStart = null;
    this.commit(next);
  }
  private moved(start: WorkspaceFrame, dx: number, dy: number): WorkspaceFrame {
    const x: number = Math.min(1 - start.w, Math.max(0, start.x + dx / Math.max(1, this.canvasWidth)));
    const y: number = Math.min(1 - start.h, Math.max(0, start.y + dy / Math.max(1, this.canvasHeight())));
    return { x, y, w: start.w, h: start.h, fullscreen: false };
  }
  private resized(start: WorkspaceFrame, dx: number, dy: number): WorkspaceFrame {
    const w: number = Math.min(1 - start.x, Math.max(0.125, start.w + dx / Math.max(1, this.canvasWidth)));
    const h: number = Math.min(1 - start.y, Math.max(0.125, start.h + dy / Math.max(1, this.canvasHeight())));
    return { x: start.x, y: start.y, w, h, fullscreen: false };
  }

  @Builder private tabButton(tab: EditorTab, title: string) {
    Text(title).fontSize(13).fontColor(this.tab === tab ? Color.White : this.pal().text2)
      .padding({ left: 14, right: 14, top: 7, bottom: 7 }).borderRadius(16)
      .backgroundColor(this.tab === tab ? this.accent : Color.Transparent)
      .onClick((): void => { this.tab = tab; })
  }

  @Builder private chip(label: string, selected: boolean, onTap: () => void) {
    Text(label).fontSize(12).fontColor(selected ? this.accent : this.pal().text2)
      .padding({ left: 11, right: 11, top: 6, bottom: 6 }).borderRadius(14).margin({ right: 6, bottom: 6 })
      .backgroundColor(selected ? this.tint(this.accent, '1F') : this.pal().surface)
      .border({ width: 1, color: selected ? this.accent : Color.Transparent })
      .onClick((): void => { onTap(); })
  }

  @Builder private identity() {
    Column({ space: 12 }) {
      Row({ space: 10 }) {
        Column() { ProSymbolIcon({ icon: this.draft.icon, glyphSize: 22, color: this.draft.color }) }.width(44).height(44).justifyContent(FlexAlign.Center).borderRadius(14)
          .backgroundColor(this.tint(this.draft.color, '2E'))
        TextInput({ text: this.nameDraft, placeholder: '工作区名称' }).height(42).layoutWeight(1)
          .maxLength(MAX_WORKSPACE_NAME_LENGTH).backgroundColor(this.pal().surface).borderRadius(12)
          .onChange((value: string): void => { this.nameDraft = value; })
          .onSubmit((): void => { this.saveName(); })
          .onBlur((): void => { this.saveName(); })
      }.width('100%')
      Row({ space: 6 }) {
        ForEach(WORKSPACE_COLORS, (color: string): void => {
          Stack() {
            Circle().width(24).height(24).fill(color)
            if (this.draft.color === color) { Circle().width(9).height(9).fill(Color.White) }
          }.width(30).height(30).onClick((): void => { this.update((next: Workspace): void => { next.color = color; }); })
        }, (color: string): string => color)
      }.width('100%')
      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach(WORKSPACE_ICONS, (icon: string): void => {
          Column() { ProSymbolIcon({ icon: icon, glyphSize: 19, color: this.draft.icon === icon ? this.draft.color : this.pal().text2 }) }.width(38).height(38).justifyContent(FlexAlign.Center).borderRadius(11)
            .backgroundColor(this.draft.icon === icon ? this.tint(this.draft.color, '2E') : Color.Transparent)
            .onClick((): void => { this.update((next: Workspace): void => { next.icon = icon; }); })
        }, (icon: string): string => icon)
      }.width('100%')
    }.width('100%').padding(14).backgroundColor(this.pal().card).borderRadius(16)
  }

  @Builder private entryOptions(entry: WorkspaceEntry) {
    Column({ space: 10 }) {
      Row() {
        Column({ space: 2 }) {
          Text('打开工作区时自动连接').fontSize(13).fontColor(this.pal().text)
          Text('关闭后会停在这一项，由你手动点「连接」').fontSize(11).fontColor(this.pal().text3)
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: entry.autoConnect }).selectedColor(this.accent)
          .onChange((on: boolean): void => { this.setEntry(entry.hostRef, (item: WorkspaceEntry): void => { item.autoConnect = on; }); })
      }.width('100%')
      if (entry.protocol === 'ssh') {
        Text('连接后显示').fontSize(12).fontColor(this.pal().text3).width('100%')
        Flex({ wrap: FlexWrap.Wrap }) {
          this.chip('终端', entry.view.sshPane === 'terminal', (): void => {
            this.setEntry(entry.hostRef, (item: WorkspaceEntry): void => { item.view.sshPane = 'terminal'; });
          })
          this.chip('文件（SFTP）', entry.view.sshPane === 'files', (): void => {
            this.setEntry(entry.hostRef, (item: WorkspaceEntry): void => { item.view.sshPane = 'files'; });
          })
        }.width('100%')
        TextInput({ text: this.dirDraft, placeholder: '打开目录（可选），例如 /var/log' }).height(38)
          .maxLength(512).backgroundColor(this.pal().surface).borderRadius(10)
          .onChange((value: string): void => { this.dirDraft = value; })
          .onSubmit((): void => { this.saveDirectory(entry); })
          .onBlur((): void => { this.saveDirectory(entry); })
      }
      Button('从工作区移除').width('100%').height(36).fontSize(13).fontColor(this.pal().danger)
        .backgroundColor(this.pal().surface)
        .onClick((): void => {
          this.update((next: Workspace): void => { next.entries = removeWorkspaceEntry(next.entries, entry.hostRef); });
          this.openRef = '';
        })
    }.width('100%').padding({ left: 14, right: 14, bottom: 14 })
  }

  @Builder private sessionsTab() {
    Column({ space: 8 }) {
      Column() {
        ForEach(this.entries(), (entry: WorkspaceEntry, index: number): void => {
          if (index > 0) { Divider().strokeWidth(0.5).color(this.pal().cardBorder).margin({ left: 14, right: 14 }) }
          Column() {
            Row({ space: 10 }) {
              Text((index + 1).toString()).fontSize(12).fontColor(this.draft.color).width(22).height(22)
                .textAlign(TextAlign.Center).borderRadius(11).backgroundColor(this.tint(this.draft.color, '26'))
              Column({ space: 2 }) {
                Text(this.row(entry.hostRef)?.label ?? '已删除的主机').fontSize(14)
                  .fontColor(this.row(entry.hostRef) === undefined ? this.pal().danger : this.pal().text)
                  .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                Text(orgProtocolLabel(entry.protocol) + (entry.autoConnect ? '' : ' · 手动连接') +
                  (entry.protocol === 'ssh' && entry.view.sshPane === 'files' ? ' · 打开文件' : '') +
                  (entry.view.sshDirectory !== '' ? ' · ' + entry.view.sshDirectory : ''))
                  .fontSize(11).fontColor(this.pal().text3).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
              }.alignItems(HorizontalAlign.Start).layoutWeight(1)
              SymbolGlyph($r('sys.symbol.chevron_up')).fontSize(14).padding(6)
                .fontColor([index === 0 ? this.pal().cardBorder : this.pal().text3])
                .onClick((): void => {
                  this.update((next: Workspace): void => { next.entries = moveWorkspaceEntry(next.entries, entry.hostRef, -1); });
                })
              SymbolGlyph($r('sys.symbol.chevron_down')).fontSize(14).padding(6)
                .fontColor([index === this.entries().length - 1 ? this.pal().cardBorder : this.pal().text3])
                .onClick((): void => {
                  this.update((next: Workspace): void => { next.entries = moveWorkspaceEntry(next.entries, entry.hostRef, 1); });
                })
            }.width('100%').padding({ left: 14, right: 10, top: 11, bottom: 11 })
            .onClick((): void => {
              this.openRef = this.openRef === entry.hostRef ? '' : entry.hostRef;
              this.dirDraft = entry.view.sshDirectory;
            })
            if (this.openRef === entry.hostRef) { this.entryOptions(entry) }
          }.width('100%')
        }, (entry: WorkspaceEntry): string => entry.hostRef + ':' + entry.order.toString() + ':' +
          (entry.autoConnect ? '1' : '0') + entry.view.sshPane + entry.view.sshDirectory)
        if (this.entries().length === 0) {
          Text('还没有会话。添加几台主机，打开工作区时会按顺序连接。').fontSize(13).fontColor(this.pal().text3)
            .width('100%').padding(16)
        }
      }.width('100%').backgroundColor(this.pal().card).borderRadius(16)
      if (!this.picking) {
        Button('＋ 添加主机（' + this.draft.entries.length.toString() + '/' + MAX_WORKSPACE_ENTRIES.toString() + '）')
          .width('100%').height(44).fontSize(14).fontColor(this.accent).backgroundColor(this.pal().card)
          .enabled(this.draft.entries.length < MAX_WORKSPACE_ENTRIES)
          .onClick((): void => { this.picking = true; this.picked = []; })
      } else {
        Column({ space: 8 }) {
          Row() {
            Text('选择主机').fontSize(14).fontWeight(FontWeight.Medium).fontColor(this.pal().text).layoutWeight(1)
            Text('取消').fontSize(13).fontColor(this.pal().text2).padding(4)
              .onClick((): void => { this.picking = false; this.picked = []; })
          }.width('100%')
          Search({ value: this.pickQuery, placeholder: '搜索名称、地址或协议' }).height(36)
            .backgroundColor(this.pal().surface).onChange((value: string): void => { this.pickQuery = value; })
          if (this.pickRows().length === 0) {
            Text(this.rows().length === 0 ? '还没有主机' : '没有更多可添加的主机').fontSize(12)
              .fontColor(this.pal().text3).width('100%')
          }
          List({ space: 2 }) {
            ForEach(this.pickRows(), (row: OrgHostRow): void => {
              ListItem() {
                Row({ space: 10 }) {
                  Column({ space: 2 }) {
                    Text(row.label).fontSize(14).fontColor(this.pal().text).maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                    Text(orgRowDetail(row)).fontSize(11).fontColor(this.pal().text3).maxLines(1)
                  }.alignItems(HorizontalAlign.Start).layoutWeight(1)
                  Checkbox().select(this.picked.indexOf(row.ref) >= 0).selectedColor(this.accent)
                    .onChange((on: boolean): void => { this.togglePick(row.ref, on); })
                }.width('100%').padding({ top: 6, bottom: 6 })
              }
            }, (row: OrgHostRow): string => row.ref)
          }.width('100%').constraintSize({ maxHeight: 320 }).scrollBar(BarState.Auto)
          Button('添加 ' + this.picked.length.toString() + ' 台').width('100%').height(40).fontSize(14)
            .backgroundColor(this.accent).fontColor(Color.White).enabled(this.picked.length > 0)
            .onClick((): void => { this.addPicked(); })
        }.width('100%').padding(14).backgroundColor(this.pal().card).borderRadius(16)
      }
    }.width('100%')
  }

  @Builder private frameBox(entry: WorkspaceEntry, index: number) {
    Stack({ alignContent: Alignment.TopStart }) {
      Column({ space: 2 }) {
        Text((index + 1).toString() + ' · ' + orgProtocolLabel(entry.protocol)).fontSize(10).fontColor(Color.White)
          .opacity(0.9)
        Text(this.row(entry.hostRef)?.label ?? '已删除').fontSize(12).fontColor(Color.White).maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }.alignItems(HorizontalAlign.Start).padding(6).width('100%')
      if (this.selectedFrameRef === entry.hostRef) {
        Row().width(18).height(18).borderRadius(9).backgroundColor(Color.White)
          .border({ width: 2, color: this.draft.color })
          .position({ right: 2, bottom: 2 })
          .gesture(PanGesture({ distance: 1 })
            .onActionStart((): void => { this.dragStart = workspaceEntryFrame(entry); })
            .onActionUpdate((event: GestureEvent): void => {
              if (this.dragStart !== null) { this.liveFrame(entry.hostRef, this.resized(this.dragStart, event.offsetX, event.offsetY)); }
            })
            .onActionEnd((): void => { this.endFrame(entry.hostRef); }))
      }
    }
    .width(Math.max(24, workspaceEntryFrame(entry).w * this.canvasWidth - 4))
    .height(Math.max(24, workspaceEntryFrame(entry).h * this.canvasHeight() - 4))
    .position({ x: workspaceEntryFrame(entry).x * this.canvasWidth + 2, y: workspaceEntryFrame(entry).y * this.canvasHeight() + 2 })
    .borderRadius(10).clip(false)
    .backgroundColor(this.tint(this.draft.color, this.selectedFrameRef === entry.hostRef ? 'E6' : 'A6'))
    .border({ width: this.selectedFrameRef === entry.hostRef ? 2 : 0, color: Color.White })
    .zIndex(this.selectedFrameRef === entry.hostRef ? 2 : 1)
    .onClick((): void => { this.selectedFrameRef = entry.hostRef; })
    .gesture(PanGesture({ distance: 4 })
      .onActionStart((): void => { this.selectedFrameRef = entry.hostRef; this.dragStart = workspaceEntryFrame(entry); })
      .onActionUpdate((event: GestureEvent): void => {
        if (this.dragStart !== null) { this.liveFrame(entry.hostRef, this.moved(this.dragStart, event.offsetX, event.offsetY)); }
      })
      .onActionEnd((): void => { this.endFrame(entry.hostRef); }))
  }

  @Builder private layoutTab() {
    Column({ space: 10 }) {
      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach(WORKSPACE_LAYOUT_PRESETS, (preset: WorkspaceLayoutPreset): void => {
          this.chip(workspaceLayoutLabel(preset), this.draft.layout === preset, (): void => { this.applyPreset(preset); })
        }, (preset: WorkspaceLayoutPreset): string => preset)
        if (this.draft.layout === 'custom') { this.chip('自定义', true, (): void => {}) }
      }.width('100%')
      Stack({ alignContent: Alignment.TopStart }) {
        ForEach([1, 2, 3, 4, 5, 6, 7], (line: number): void => {
          Row().width(0.5).height('100%').backgroundColor(this.pal().cardBorder)
            .position({ x: line / 8 * this.canvasWidth, y: 0 })
          Row().height(0.5).width('100%').backgroundColor(this.pal().cardBorder)
            .position({ x: 0, y: line / 8 * this.canvasHeight() })
        }, (line: number): string => line.toString())
        ForEach(this.entries(), (entry: WorkspaceEntry, index: number): void => {
          this.frameBox(entry, index)
        }, (entry: WorkspaceEntry): string => entry.hostRef + JSON.stringify(entry.frame ?? null) + this.selectedFrameRef +
          this.canvasWidth.toString())
      }
      .width('100%').height(this.canvasHeight()).borderRadius(14).backgroundColor(this.pal().surface).clip(true)
      .onAreaChange((_old: Area, area: Area): void => {
        const width: number = Number(area.width);
        if (width > 0 && Math.abs(width - this.canvasWidth) > 1) { this.canvasWidth = width; }
      })
      Text(this.entries().length === 0 ? '先在「会话」里添加主机' :
        '拖动窗口移动，选中后拖动右下角圆点调整大小，松手后对齐网格。PC 上按此布局摆放独立窗口；平板和手机按顺序打开。')
        .fontSize(11).fontColor(this.pal().text3).lineHeight(16).width('100%')
    }.width('100%').padding(14).backgroundColor(this.pal().card).borderRadius(16)
  }

  build() {
    Column({ space: 12 }) {
      Row() {
        Text('编辑工作区').fontSize(17).fontWeight(FontWeight.Medium).fontColor(this.pal().text)
          .fontFamily(AppConfig.fontFamily).layoutWeight(1)
        if (this.showClose) {
          Button('完成').fontSize(13).height(32).borderRadius(16).backgroundColor(this.accent).fontColor(Color.White)
            .onClick((): void => { this.close(); })
        }
      }.width('100%')
      this.identity()
      Row({ space: 4 }) {
        this.tabButton('sessions', '会话 ' + this.draft.entries.length.toString())
        this.tabButton('layout', '布局 · ' + workspaceLayoutLabel(this.draft.layout))
      }.padding(3).borderRadius(19).backgroundColor(this.pal().surface)
      if (this.tab === 'sessions') { this.sessionsTab() } else { this.layoutTab() }
    }.width('100%')
  }
}
