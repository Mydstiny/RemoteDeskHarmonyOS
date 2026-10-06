import { settingsVisualIsModern } from '../../../services/SettingsVisualStylePolicy';
import { appUiOnAccentText } from '../../../common/AppUiColorPolicy';
import { buildDark, buildLight, Palette } from '../../../common/Theme';
import { ProSymbolIcon } from '../ProSymbolIcon';
import {
  addWorkspaceEntries, MAX_WORKSPACE_NAME_LENGTH, newWorkspace, Workspace, WORKSPACE_COLORS, WORKSPACE_ICONS
} from '../../../services/pro/workspace/WorkspacePolicy';
import { WorkspaceStore } from '../../../services/pro/workspace/WorkspaceStore';
import {
  currentWorkspaceDeviceKind, workspaceEntryLimit
} from '../../../services/pro/workspace/WorkspaceDevicePolicy';
import { orgHostRows, OrgHostRow, orgRowDetail } from '../../../services/pro/org/HostOrganizationDirectory';

function freeName(base: string): string {
  const names: string[] = WorkspaceStore.getInstance().list().map((item: Workspace): string => item.name);
  for (let index: number = 1; index <= 99; index++) {
    const name: string = base + ' ' + index.toString();
    if (names.indexOf(name) < 0) { return name; }
  }
  return base;
}

/**
 * 「+」→ 工作区: the add-sheet flow for a new workspace, styled like the host add flows. Step 1 names it and picks a
 * color and icon; step 2 chooses its hosts. Nothing is saved until 创建.
 */
@Component
export struct WorkspaceAddFlow {
  @StorageProp('currentTheme') theme: string = 'light';
  @StorageProp('settingsVisualStyle') visualStyle: string = 'classic';
  @StorageProp('accentColor') accentColor: string = '#007DFF';
  /** Hosts the stores cannot list on their own (Moonlight, from the home page). */
  @Prop extraRows: OrgHostRow[] = [];
  onBackToProtocols: () => void = (): void => {};
  onClose: () => void = (): void => {};
  /** Whether anything differs from how the flow opened (the page asks before throwing it away). */
  onDirtyChange: (dirty: boolean) => void = (_dirty: boolean): void => {};
  private draftBaseline: string = '';
  private draftDirty: boolean = false;
  onCreated: (workspace: Workspace, openNow: boolean) => void = (_workspace: Workspace, _openNow: boolean): void => {};
  @State step: number = 1;
  @State @Watch('reportDirty') name: string = '';
  @State @Watch('reportDirty') color: string = WORKSPACE_COLORS[0];
  @State @Watch('reportDirty') icon: string = WORKSPACE_ICONS[0];
  @State query: string = '';
  @State @Watch('reportDirty') picked: string[] = [];
  @State errorText: string = '';

  aboutToAppear(): void {
    const count: number = WorkspaceStore.getInstance().list().length;
    this.name = freeName('工作区');
    this.color = WORKSPACE_COLORS[count % WORKSPACE_COLORS.length];
    this.icon = WORKSPACE_ICONS[count % WORKSPACE_ICONS.length];
    this.draftBaseline = this.draftSnapshot();
  }

  private draftSnapshot(): string {
    return JSON.stringify([this.name, this.color, this.icon, this.picked]);
  }

  private reportDirty(): void {
    if (this.draftBaseline === '') { return; }
    const dirty: boolean = this.draftSnapshot() !== this.draftBaseline;
    if (dirty !== this.draftDirty) {
      this.draftDirty = dirty;
      this.onDirtyChange(dirty);
    }
  }

  /** 全新视觉: header buttons are 44vp touch targets (36 in the classic look). */
  private headerButtonSize(): number {
    return settingsVisualIsModern(this.visualStyle) ? 44 : 36;
  }

  private pal(): Palette { return this.theme === 'light' ? buildLight(this.accentColor) : buildDark(this.accentColor); }
  private tint(color: string, alpha: string): string {
    return /^#[0-9A-Fa-f]{6}$/.test(color) ? '#' + alpha + color.substring(1) : color;
  }
  private limit(): number { return workspaceEntryLimit(currentWorkspaceDeviceKind()); }
  private rows(): OrgHostRow[] { return orgHostRows(this.extraRows); }
  private filteredRows(): OrgHostRow[] {
    const query: string = this.query.trim().toLowerCase();
    return this.rows().filter((row: OrgHostRow): boolean => query === '' || row.label.toLowerCase().includes(query) ||
      row.address.toLowerCase().includes(query) || row.protocol.includes(query));
  }
  private toggle(ref: string, on: boolean): void {
    if (on && this.picked.length >= this.limit()) {
      this.errorText = this.limit() < 16 ? '平板上每个工作区最多 ' + this.limit().toString() + ' 台主机' :
        '每个工作区最多 ' + this.limit().toString() + ' 台主机';
      return;
    }
    this.errorText = '';
    this.picked = on ? this.picked.concat([ref]) : this.picked.filter((item: string): boolean => item !== ref);
  }
  private create(openNow: boolean): void {
    const name: string = this.name.trim().slice(0, MAX_WORKSPACE_NAME_LENGTH);
    if (name.length === 0) { this.step = 1; this.errorText = '请填写工作区名称'; return; }
    const store: WorkspaceStore = WorkspaceStore.getInstance();
    if (!store.canAdd()) { this.errorText = '工作区已达上限'; return; }
    const workspace: Workspace = newWorkspace('workspace-' + Date.now().toString(36), name, this.color, this.icon,
      store.list().length);
    const protocols: string[] = this.picked.map((ref: string): string => {
      const row: OrgHostRow | undefined = this.rows().find((item: OrgHostRow): boolean => item.ref === ref);
      return row === undefined ? '' : row.protocol;
    });
    workspace.entries = addWorkspaceEntries([], this.picked, protocols, this.limit());
    if (!store.save(workspace)) { this.errorText = '工作区未保存，请稍后重试'; return; }
    this.onCreated(workspace, openNow && workspace.entries.length > 0);
  }

  @Builder private header() {
    Row() {
      Button() { SymbolGlyph($r('sys.symbol.chevron_left')).fontSize(18).fontColor([this.pal().text2]) }
        .width(this.headerButtonSize()).height(this.headerButtonSize()).borderRadius(this.headerButtonSize() / 2).padding(0).backgroundColor(this.pal().surface)
        .onClick((): void => { if (this.step === 1) { this.onBackToProtocols(); } else { this.step = 1; } })
      Column() {
        Text('新建工作区').fontSize(20).fontWeight(FontWeight.Bold).fontColor(this.pal().text)
        Text(this.step === 1 ? '1/2  名称与外观' : '2/2  选择主机').fontSize(12).fontColor(this.pal().text3).margin({ top: 3 })
      }.alignItems(HorizontalAlign.Start).layoutWeight(1).margin({ left: 12 })
      Button() {
        SymbolGlyph($r('sys.symbol.xmark')).fontSize(18).fontColor([this.pal().text2])
      }.width(44).height(44).borderRadius(22).padding(0).backgroundColor(this.pal().surface)
        .onClick((): void => { this.onClose(); })
    }.width('100%').margin({ bottom: 18 })
  }

  @Builder private appearanceStep() {
    Column() {
      Row({ space: 12 }) {
        Column() { ProSymbolIcon({ icon: this.icon, glyphSize: 22, color: this.color }) }
          .width(44).height(44).borderRadius(14).justifyContent(FlexAlign.Center)
          .backgroundColor(this.tint(this.color, '2E'))
        TextInput({ text: this.name, placeholder: '例如：日常开发' }).height(44).fontSize(14).layoutWeight(1)
          .maxLength(MAX_WORKSPACE_NAME_LENGTH).fontColor(this.pal().text).placeholderColor(this.pal().text3)
          .backgroundColor(this.pal().surface).borderRadius(11).padding({ left: 12, right: 12 })
          .onChange((value: string): void => { this.name = value; this.errorText = ''; })
      }.width('100%').margin({ bottom: 16 })
      Text('颜色').fontSize(12).fontColor(this.pal().text2).width('100%').margin({ bottom: 8 })
      Row({ space: 6 }) {
        ForEach(WORKSPACE_COLORS, (color: string): void => {
          Stack() {
            Circle().width(26).height(26).fill(color)
            if (this.color === color) { Circle().width(10).height(10).fill(Color.White) }
          }.width(32).height(32).onClick((): void => { this.color = color; })
        }, (color: string): string => color)
      }.width('100%').margin({ bottom: 16 })
      Text('图标').fontSize(12).fontColor(this.pal().text2).width('100%').margin({ bottom: 8 })
      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach(WORKSPACE_ICONS, (icon: string): void => {
          Column() {
            ProSymbolIcon({ icon: icon, glyphSize: 19, color: this.icon === icon ? this.color : this.pal().text2 })
          }.width(40).height(40).borderRadius(12).justifyContent(FlexAlign.Center)
          .backgroundColor(this.icon === icon ? this.tint(this.color, '2E') : Color.Transparent)
          .onClick((): void => { this.icon = icon; })
        }, (icon: string): string => icon)
      }.width('100%').margin({ bottom: 16 })
      Button('下一步').width('100%').height(44).borderRadius(12).backgroundColor(this.accentColor).fontColor(appUiOnAccentText(this.accentColor))
        .onClick((): void => {
          if (this.name.trim().length === 0) { this.errorText = '请填写工作区名称'; return; }
          this.errorText = ''; this.step = 2;
        })
    }.width('100%')
  }

  @Builder private hostsStep() {
    Column() {
      Text(this.limit() < 16 ? '平板上每个工作区最多 ' + this.limit().toString() + ' 台主机，会左右分屏打开' :
        '按勾选顺序打开；之后可以在编辑里调整顺序和布局')
        .fontSize(12).fontColor(this.pal().text3).width('100%').margin({ bottom: 10 })
      if (this.rows().length > 6) {
        Search({ value: this.query, placeholder: '搜索名称、地址或协议' }).height(38).backgroundColor(this.pal().surface)
          .margin({ bottom: 8 }).onChange((value: string): void => { this.query = value; })
      }
      if (this.rows().length === 0) {
        Text('还没有主机，先添加主机再创建工作区').fontSize(13).fontColor(this.pal().text3).width('100%').padding(14)
      }
      List({ space: 2 }) {
        ForEach(this.filteredRows(), (row: OrgHostRow): void => {
          ListItem() {
            Row({ space: 10 }) {
              Column({ space: 2 }) {
                Text(row.label).fontSize(14).fontColor(this.pal().text).maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                Text(orgRowDetail(row)).fontSize(11).fontColor(this.pal().text3).maxLines(1)
              }.alignItems(HorizontalAlign.Start).layoutWeight(1)
              if (this.picked.indexOf(row.ref) >= 0) {
                Text((this.picked.indexOf(row.ref) + 1).toString()).fontSize(11).fontColor(appUiOnAccentText(this.color))
                  .width(20).height(20).textAlign(TextAlign.Center).borderRadius(10).backgroundColor(this.color)
              }
              Checkbox().select(this.picked.indexOf(row.ref) >= 0).selectedColor(this.accentColor)
                .onChange((on: boolean): void => { this.toggle(row.ref, on); })
            }.width('100%').padding({ left: 12, right: 8, top: 8, bottom: 8 })
          }
        }, (row: OrgHostRow): string => row.ref + ':' + (this.picked.indexOf(row.ref)).toString())
      }.width('100%').constraintSize({ maxHeight: 340 }).borderRadius(14).backgroundColor(this.pal().surface)
      Row() {
        Button('创建').layoutWeight(1).height(44).borderRadius(12).backgroundColor(this.pal().surface)
          .fontColor(this.accentColor).onClick((): void => { this.create(false); })
        Button('创建并打开').layoutWeight(1).height(44).borderRadius(12).margin({ left: 8 })
          .backgroundColor(this.accentColor).fontColor(appUiOnAccentText(this.accentColor)).enabled(this.picked.length > 0)
          .onClick((): void => { this.create(true); })
      }.width('100%').margin({ top: 16 })
    }.width('100%')
  }

  build() {
    Column() {
      this.header()
      if (this.step === 1) { this.appearanceStep() } else { this.hostsStep() }
      if (this.errorText !== '') {
        Text(this.errorText).fontSize(12).fontColor(this.pal().danger).margin({ top: 10 })
      }
    }
    .width('100%').height('auto')
    .padding({ left: 20, right: 20, top: 20, bottom: 22 })
    .backgroundColor(this.pal().sheetBg)
  }
}
