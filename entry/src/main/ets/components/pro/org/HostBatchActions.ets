import { display } from '@kit.ArkUI';
import { AppConfig, buildDark, buildLight, Palette } from '../../../common/Theme';
import { ProSymbolIcon } from '../ProSymbolIcon';
import { RemoteHost } from '../../../model/RemoteHost';
import { SshKey } from '../../../model/SshKey';
import { HostSyncService } from '../../../services/HostSyncService';
import { KeyVaultService } from '../../../services/KeyVaultService';
import {
  batchDiffCounts, batchEditDiff, batchFieldHint, batchFieldLabel, batchFieldProtocols, batchResolutionLabel,
  HOST_BATCH_COLOR_DEPTHS, HOST_BATCH_FIELDS, HOST_BATCH_RESOLUTIONS, HostBatchDiff, HostBatchEdit, HostBatchField,
  HostBatchHost
} from '../../../services/pro/org/HostBatchEditPolicy';
import {
  HOST_GROUP_COLORS, HOST_GROUP_ICONS, HostGroupDefinition, HostTagUsage, MAX_HOST_GROUPS, nextGroupName,
  normalizeHostTag, tagUsage
} from '../../../services/pro/org/HostOrganizationPolicy';
import { HostOrganizationStore } from '../../../services/pro/org/HostOrganizationStore';
import { orgProtocolLabel, OrgHostRow } from '../../../services/pro/org/HostOrganizationDirectory';

function sheetBodyMaxHeight(): number {
  try {
    const screen: display.Display = display.getDefaultDisplaySync();
    return Math.round(screen.height / Math.max(1, screen.densityPixels) * 0.85) - 80;
  } catch (_error) {
    return 560;
  }
}

type BatchSheet = 'group' | 'tags' | 'edit';

/** The fields batch edit touched on one host, so 撤销 can put exactly those back. */
interface BatchUndo {
  id: string; port: number; username: string; dynamicResolution: boolean; width: number; height: number;
  colorDepth: number; multiMonitor: boolean; sshUseKey: boolean; sshKeyId: string;
}

function resolutionValue(host: RemoteHost): string {
  return host.displayConfig.dynamicResolution ? 'auto' :
    host.displayConfig.width.toString() + 'x' + host.displayConfig.height.toString();
}

function batchView(host: RemoteHost): HostBatchHost {
  const values: Record<string, Object> = {};
  values['port'] = host.port;
  values['username'] = host.username;
  values['rdpResolution'] = resolutionValue(host);
  values['rdpColorDepth'] = host.displayConfig.colorDepth;
  values['rdpMultiMonitor'] = host.displayConfig.multiMonitor;
  values['sshKeyId'] = host.sshUseKey ? host.sshKeyId : '';
  return { id: host.id, protocol: host.protocol, values };
}

/**
 * Floating action bar shown while hosts are multi-selected (Pro 高级主机管理). Group, tag and batch-edit work happens
 * here; probing, export, lock and delete are handed back to the host list, which owns those flows.
 */
@Component
export struct HostBatchActions {
  @StorageProp('currentTheme') theme: string = 'light';
  @StorageProp('accentColor') accent: string = '#007DFF';
  @Prop selectedRefs: string[] = [];
  @Prop rows: OrgHostRow[] = [];
  @Prop probing: boolean = false;
  onProbe: () => void = (): void => {};
  onExport: () => void = (): void => {};
  onDelete: () => void = (): void => {};
  onLock: (lock: boolean) => void = (_lock: boolean): void => {};
  onChanged: () => void = (): void => {};
  @State sheet: BatchSheet = 'group';
  @State showSheet: boolean = false;
  @State revision: number = 0;
  @State newGroupName: string = '';
  @State newTag: string = '';
  // Batch edit drafts.
  @State fieldOn: boolean[] = [false, false, false, false, false, false];
  @State portDraft: string = '3389';
  @State resolutionDraft: string = 'auto';
  @State depthDraft: number = 32;
  @State multiDraft: boolean = false;
  @State userDraft: string = '';
  @State keyDraft: string = '';
  @State previewing: boolean = false;
  @State resultText: string = '';
  @State undoCount: number = 0;
  private undo: BatchUndo[] = [];
  private stop: (() => void) | null = null;

  aboutToAppear(): void {
    this.stop = HostOrganizationStore.getInstance().subscribe((): void => { this.revision++; });
  }
  aboutToDisappear(): void { this.stop?.(); this.stop = null; }

  private pal(): Palette { return this.theme === 'light' ? buildLight(this.accent) : buildDark(this.accent); }
  private tint(color: string, alpha: string): string {
    return /^#[0-9A-Fa-f]{6}$/.test(color) ? '#' + alpha + color.substring(1) : color;
  }
  private toast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message, duration: 2000 });
  }
  private count(): number { return this.selectedRefs.length; }
  private open(sheet: BatchSheet): void {
    if (this.count() === 0) { this.toast('先选择主机'); return; }
    this.sheet = sheet; this.previewing = false; this.resultText = ''; this.showSheet = true;
  }
  private groups(_revision: number): HostGroupDefinition[] { return HostOrganizationStore.getInstance().listGroups(); }
  private moveTo(groupId: string, name: string): void {
    if (HostOrganizationStore.getInstance().assignHosts(this.selectedRefs, groupId)) {
      this.toast(groupId === '' ? '已将 ' + this.count().toString() + ' 台移出分组' :
        '已将 ' + this.count().toString() + ' 台移入「' + name + '」');
      this.showSheet = false; this.onChanged();
    } else {
      this.toast('分组未保存，请稍后重试');
    }
  }
  private createAndMove(): void {
    const store: HostOrganizationStore = HostOrganizationStore.getInstance();
    const groups: HostGroupDefinition[] = store.listGroups();
    if (groups.length >= MAX_HOST_GROUPS) { this.toast('最多 ' + MAX_HOST_GROUPS.toString() + ' 个分组'); return; }
    const name: string = this.newGroupName.trim().length > 0 ? this.newGroupName.trim() : nextGroupName(groups);
    const id: string = 'group-' + Date.now().toString(36);
    if (store.createGroup({ id, name, color: HOST_GROUP_COLORS[groups.length % HOST_GROUP_COLORS.length],
      icon: HOST_GROUP_ICONS[0], order: groups.length, createdAt: 0, updatedAt: 0 })) {
      this.newGroupName = '';
      this.moveTo(id, name);
    }
  }
  private tags(_revision: number): HostTagUsage[] {
    return tagUsage(HostOrganizationStore.getInstance().snapshot().byHost,
      this.rows.map((row: OrgHostRow): string => row.ref));
  }
  /** 2 = every selected host has the tag, 1 = some, 0 = none. */
  private tagState(tag: string, _revision: number): number {
    const store: HostOrganizationStore = HostOrganizationStore.getInstance();
    const having: number = this.selectedRefs.filter((ref: string): boolean =>
      store.membership(ref).tags.indexOf(tag) >= 0).length;
    return having === 0 ? 0 : having === this.selectedRefs.length ? 2 : 1;
  }
  private toggleTag(tag: string): void {
    const store: HostOrganizationStore = HostOrganizationStore.getInstance();
    const ok: boolean = this.tagState(tag, this.revision) === 2 ? store.removeTags(this.selectedRefs, [tag]) :
      store.addTags(this.selectedRefs, [tag]);
    if (!ok) { this.toast('标签未保存，单台主机最多 10 个标签'); } else { this.onChanged(); }
  }
  private addNewTag(): void {
    const tag: string = normalizeHostTag(this.newTag);
    if (tag.length === 0) { return; }
    if (HostOrganizationStore.getInstance().addTags(this.selectedRefs, [tag])) { this.newTag = ''; this.onChanged(); }
    else { this.toast('标签未保存，单台主机最多 10 个标签'); }
  }

  // ---------- 批量编辑 ----------
  private selectedHosts(): RemoteHost[] {
    const srv: HostSyncService = HostSyncService.getInstance();
    const result: RemoteHost[] = [];
    this.selectedRefs.forEach((ref: string): void => {
      const host: RemoteHost | undefined = srv.getHost(ref);
      if (host !== undefined) { result.push(host); }
    });
    return result;
  }
  private fieldUsable(field: HostBatchField): boolean {
    const protocols: string[] = batchFieldProtocols(field);
    return this.rows.some((row: OrgHostRow): boolean =>
      this.selectedRefs.indexOf(row.ref) >= 0 && protocols.indexOf(row.protocol) >= 0);
  }
  private keys(): SshKey[] { return KeyVaultService.getInstance().getAllSshKeys(); }
  private setFieldOn(index: number, on: boolean): void {
    const next: boolean[] = this.fieldOn.slice();
    next[index] = on;
    this.fieldOn = next;
    this.previewing = false;
  }
  private draftValue(field: HostBatchField): string | number | boolean {
    if (field === 'port') { return Number(this.portDraft); }
    if (field === 'rdpResolution') { return this.resolutionDraft; }
    if (field === 'rdpColorDepth') { return this.depthDraft; }
    if (field === 'rdpMultiMonitor') { return this.multiDraft; }
    if (field === 'username') { return this.userDraft; }
    return this.keyDraft;
  }
  private edits(): HostBatchEdit[] {
    return HOST_BATCH_FIELDS.map((field: HostBatchField, index: number): HostBatchEdit => ({
      field, value: this.draftValue(field), enabled: this.fieldOn[index] === true && this.fieldUsable(field) }));
  }
  private diffs(): HostBatchDiff[] { return batchEditDiff(this.selectedHosts().map(batchView), this.edits()); }
  private hostLabel(id: string): string {
    const row: OrgHostRow | undefined = this.rows.find((item: OrgHostRow): boolean => item.ref === id);
    return row === undefined ? id : row.label;
  }
  private previewLines(): string[] {
    return this.diffs().map((diff: HostBatchDiff): string => this.hostLabel(diff.hostId) + ' · ' +
      batchFieldLabel(diff.field) + '：' + (diff.skipped ? '不适用，跳过' : diff.unchanged ? '无变化' :
        (diff.oldValue.length > 0 ? diff.oldValue : '空') + ' → ' + diff.newValue));
  }
  private applyEdits(): void {
    const srv: HostSyncService = HostSyncService.getInstance();
    const edits: HostBatchEdit[] = this.edits().filter((edit: HostBatchEdit): boolean => edit.enabled);
    const diffs: HostBatchDiff[] = this.diffs();
    let changed: number = 0;
    let failed: number = 0;
    this.undo = [];
    this.selectedHosts().forEach((host: RemoteHost): void => {
      const pending: HostBatchDiff[] = diffs.filter((diff: HostBatchDiff): boolean =>
        diff.hostId === host.id && !diff.skipped && !diff.unchanged);
      if (pending.length === 0) { return; }
      const next: RemoteHost = host.runtimeClone();
      edits.forEach((edit: HostBatchEdit): void => {
        if (!pending.some((diff: HostBatchDiff): boolean => diff.field === edit.field)) { return; }
        if (edit.field === 'port') { next.port = edit.value as number; }
        if (edit.field === 'username') { next.username = (edit.value as string).trim(); }
        if (edit.field === 'rdpColorDepth') { next.displayConfig.colorDepth = edit.value as number; }
        if (edit.field === 'rdpMultiMonitor') { next.displayConfig.multiMonitor = edit.value as boolean; }
        if (edit.field === 'sshKeyId') { next.sshUseKey = true; next.sshKeyId = edit.value as string; }
        if (edit.field === 'rdpResolution') {
          const value: string = edit.value as string;
          next.displayConfig.dynamicResolution = value === 'auto';
          if (value !== 'auto') {
            const parts: string[] = value.split('x');
            next.displayConfig.width = Number(parts[0]); next.displayConfig.height = Number(parts[1]);
          }
        }
      });
      if (next.getValidationErrors().length > 0 || !srv.updateHost(next)) { failed++; return; }
      this.undo.push({ id: host.id, port: host.port, username: host.username,
        dynamicResolution: host.displayConfig.dynamicResolution, width: host.displayConfig.width,
        height: host.displayConfig.height, colorDepth: host.displayConfig.colorDepth,
        multiMonitor: host.displayConfig.multiMonitor, sshUseKey: host.sshUseKey, sshKeyId: host.sshKeyId });
      changed++;
    });
    const counts: number[] = batchDiffCounts(diffs);
    this.undoCount = this.undo.length;
    this.resultText = '已修改 ' + changed.toString() + ' 台' + (failed > 0 ? '，' + failed.toString() + ' 台未通过校验' : '') +
      (counts[1] > 0 ? '，' + counts[1].toString() + ' 项不适用已跳过' : '');
    this.previewing = false;
    this.onChanged();
  }
  private undoEdits(): void {
    const srv: HostSyncService = HostSyncService.getInstance();
    let restored: number = 0;
    this.undo.forEach((item: BatchUndo): void => {
      const current: RemoteHost | undefined = srv.getHost(item.id);
      if (current === undefined) { return; }
      const next: RemoteHost = current.runtimeClone();
      next.port = item.port; next.username = item.username;
      next.displayConfig.dynamicResolution = item.dynamicResolution;
      next.displayConfig.width = item.width; next.displayConfig.height = item.height;
      next.displayConfig.colorDepth = item.colorDepth; next.displayConfig.multiMonitor = item.multiMonitor;
      next.sshUseKey = item.sshUseKey; next.sshKeyId = item.sshKeyId;
      if (srv.updateHost(next)) { restored++; }
    });
    this.undo = [];
    this.undoCount = 0;
    this.resultText = '已撤销，恢复了 ' + restored.toString() + ' 台';
    this.onChanged();
  }

  @Builder private action(icon: Resource, label: string, color: ResourceColor, onTap: () => void) {
    Column({ space: 4 }) {
      SymbolGlyph(icon).fontSize(20).fontColor([color])
      Text(label).fontSize(11).fontColor(color).fontFamily(AppConfig.fontFamily).maxLines(1)
    }.width(64).height(54).justifyContent(FlexAlign.Center).borderRadius(14)
    .opacity(this.count() === 0 ? 0.4 : 1)
    .onClick((): void => { onTap(); })
  }

  @Builder private sheetTitle(title: string) {
    Row() {
      Column({ space: 2 }) {
        Text(title).fontSize(19).fontWeight(FontWeight.Bold).fontColor(this.pal().text).fontFamily(AppConfig.fontFamily)
        Text('已选 ' + this.count().toString() + ' 台主机').fontSize(12).fontColor(this.pal().text3)
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      Text('完成').fontSize(15).fontColor(this.accent).padding(6).onClick((): void => { this.showSheet = false; })
    }.width('100%').padding({ left: 20, right: 16, top: 18, bottom: 12 })
  }

  @Builder private groupSheet() {
    Column({ space: 8 }) {
      Column() {
        ForEach(this.groups(this.revision), (group: HostGroupDefinition, index: number): void => {
          if (index > 0) { Divider().strokeWidth(0.5).color(this.pal().cardBorder).margin({ left: 16, right: 16 }) }
          Row({ space: 10 }) {
            Column() { ProSymbolIcon({ icon: group.icon, glyphSize: 17, color: group.color }) }.width(32).height(32).justifyContent(FlexAlign.Center).borderRadius(10)
              .backgroundColor(this.tint(group.color, '26'))
            Text(group.name).fontSize(15).fontColor(this.pal().text).layoutWeight(1).maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            Circle().width(10).height(10).fill(group.color)
          }.width('100%').padding({ left: 14, right: 14, top: 11, bottom: 11 })
          .onClick((): void => { this.moveTo(group.id, group.name); })
        }, (group: HostGroupDefinition): string => group.id + ':' + group.updatedAt.toString())
        if (this.groups(this.revision).length > 0) {
          Divider().strokeWidth(0.5).color(this.pal().cardBorder).margin({ left: 16, right: 16 })
        }
        Row({ space: 8 }) {
          TextInput({ text: this.newGroupName, placeholder: '新分组名称' }).height(38).layoutWeight(1).maxLength(32)
            .backgroundColor(this.pal().surface).borderRadius(10)
            .onChange((value: string): void => { this.newGroupName = value; })
          Button('新建并移入').height(36).fontSize(12).backgroundColor(this.accent).fontColor(Color.White)
            .onClick((): void => { this.createAndMove(); })
        }.width('100%').padding(14)
      }.width('100%').backgroundColor(this.pal().card).borderRadius(16)
      Button('移出分组').width('100%').height(42).fontSize(14).fontColor(this.pal().text2)
        .backgroundColor(this.pal().card).onClick((): void => { this.moveTo('', ''); })
    }.width('100%')
  }

  @Builder private tagSheet() {
    Column({ space: 10 }) {
      Text('点按标签：全部已有则移除，否则给所选主机都加上').fontSize(12).fontColor(this.pal().text3).width('100%')
      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach(this.tags(this.revision), (usage: HostTagUsage): void => {
          Row({ space: 4 }) {
            if (this.tagState(usage.tag, this.revision) === 2) {
              SymbolGlyph($r('sys.symbol.checkmark')).fontSize(12).fontColor([this.accent])
            } else if (this.tagState(usage.tag, this.revision) === 1) {
              Text('–').fontSize(13).fontColor(this.accent)
            }
            Text('#' + usage.tag).fontSize(13)
              .fontColor(this.tagState(usage.tag, this.revision) > 0 ? this.accent : this.pal().text2)
          }.padding({ left: 12, right: 12, top: 7, bottom: 7 }).borderRadius(16).margin({ right: 8, bottom: 8 })
          .backgroundColor(this.tagState(usage.tag, this.revision) > 0 ? this.tint(this.accent, '1F') : this.pal().surface)
          .onClick((): void => { this.toggleTag(usage.tag); })
        }, (usage: HostTagUsage): string => usage.tag + ':' + this.revision.toString())
      }.width('100%')
      Row({ space: 8 }) {
        TextInput({ text: this.newTag, placeholder: '新标签' }).height(38).layoutWeight(1).maxLength(32)
          .backgroundColor(this.pal().surface).borderRadius(10)
          .onChange((value: string): void => { this.newTag = value; })
          .onSubmit((): void => { this.addNewTag(); })
        Button('添加').height(36).fontSize(12).backgroundColor(this.accent).fontColor(Color.White)
          .enabled(normalizeHostTag(this.newTag).length > 0).onClick((): void => { this.addNewTag(); })
      }.width('100%')
    }.width('100%').padding(16).backgroundColor(this.pal().card).borderRadius(16)
  }

  @Builder private optionChip(label: string, selected: boolean, onTap: () => void) {
    Text(label).fontSize(12).fontColor(selected ? this.accent : this.pal().text2)
      .padding({ left: 11, right: 11, top: 6, bottom: 6 }).borderRadius(14).margin({ right: 6, bottom: 6 })
      .backgroundColor(selected ? this.tint(this.accent, '1F') : this.pal().surface)
      .border({ width: 1, color: selected ? this.accent : Color.Transparent })
      .onClick((): void => { onTap(); })
  }

  @Builder private fieldEditor(field: HostBatchField) {
    if (field === 'port') {
      TextInput({ text: this.portDraft, placeholder: '1–65535' }).type(InputType.Number).height(38).maxLength(5)
        .backgroundColor(this.pal().surface).borderRadius(10)
        .onChange((value: string): void => { this.portDraft = value; this.previewing = false; })
    } else if (field === 'rdpResolution') {
      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach(HOST_BATCH_RESOLUTIONS, (value: string): void => {
          this.optionChip(batchResolutionLabel(value), this.resolutionDraft === value, (): void => {
            this.resolutionDraft = value; this.previewing = false;
          })
        }, (value: string): string => value)
      }.width('100%')
    } else if (field === 'rdpColorDepth') {
      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach(HOST_BATCH_COLOR_DEPTHS, (value: number): void => {
          this.optionChip(value.toString() + ' 位', this.depthDraft === value, (): void => {
            this.depthDraft = value; this.previewing = false;
          })
        }, (value: number): string => value.toString())
      }.width('100%')
    } else if (field === 'rdpMultiMonitor') {
      Row() {
        Text(this.multiDraft ? '开启' : '关闭').fontSize(13).fontColor(this.pal().text2).layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.multiDraft }).selectedColor(this.accent)
          .onChange((on: boolean): void => { this.multiDraft = on; this.previewing = false; })
      }.width('100%')
    } else if (field === 'username') {
      TextInput({ text: this.userDraft, placeholder: 'SSH 用户名' }).height(38).maxLength(256)
        .backgroundColor(this.pal().surface).borderRadius(10)
        .onChange((value: string): void => { this.userDraft = value; this.previewing = false; })
    } else {
      if (this.keys().length === 0) {
        Text('密钥库中还没有 SSH 密钥').fontSize(12).fontColor(this.pal().text3).width('100%')
      }
      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach(this.keys(), (key: SshKey): void => {
          this.optionChip(key.label.length > 0 ? key.label : key.id, this.keyDraft === key.id, (): void => {
            this.keyDraft = key.id; this.previewing = false;
          })
        }, (key: SshKey): string => key.id)
      }.width('100%')
    }
  }

  @Builder private editSheet() {
    Column({ space: 10 }) {
      Text('只能修改不涉及密码的连接偏好；打开某一项的开关后才会修改它，不适用的主机自动跳过。')
        .fontSize(12).fontColor(this.pal().text3).lineHeight(17).width('100%')
      ForEach(HOST_BATCH_FIELDS, (field: HostBatchField, index: number): void => {
        if (this.fieldUsable(field)) {
          Column({ space: 8 }) {
            Row({ space: 8 }) {
              Column({ space: 2 }) {
                Text(batchFieldLabel(field)).fontSize(14).fontColor(this.pal().text)
                Text(batchFieldHint(field)).fontSize(11).fontColor(this.pal().text3).lineHeight(15)
              }.alignItems(HorizontalAlign.Start).layoutWeight(1)
              Toggle({ type: ToggleType.Switch, isOn: this.fieldOn[index] === true }).selectedColor(this.accent)
                .onChange((on: boolean): void => { this.setFieldOn(index, on); })
            }.width('100%')
            if (this.fieldOn[index] === true) { this.fieldEditor(field) }
          }.width('100%').padding(14).backgroundColor(this.pal().card).borderRadius(16)
        }
      }, (field: HostBatchField, index: number): string => field + ':' + (this.fieldOn[index] === true ? '1' : '0'))
      if (!HOST_BATCH_FIELDS.some((field: HostBatchField): boolean => this.fieldUsable(field))) {
        Text('所选主机没有可批量修改的项目（目前支持 RDP 与 SSH 主机）').fontSize(13).fontColor(this.pal().text2)
          .width('100%').padding(14).backgroundColor(this.pal().card).borderRadius(16)
      }
      if (this.previewing) {
        Column({ space: 6 }) {
          Text('变更预览').fontSize(14).fontWeight(FontWeight.Medium).fontColor(this.pal().text).width('100%')
          if (this.previewLines().length === 0) {
            Text('没有打开任何修改项，或填写的值无效').fontSize(12).fontColor(this.pal().text3).width('100%')
          }
          ForEach(this.previewLines(), (line: string): void => {
            Text(line).fontSize(12).fontColor(this.pal().text2).width('100%').lineHeight(17)
          }, (line: string, index: number): string => index.toString() + line)
        }.width('100%').padding(14).backgroundColor(this.pal().card).borderRadius(16)
      }
      if (this.resultText.length > 0) {
        Row({ space: 8 }) {
          Text(this.resultText).fontSize(13).fontColor(this.pal().text2).layoutWeight(1)
          if (this.undoCount > 0) {
            Button('撤销').height(32).fontSize(12).backgroundColor(this.pal().surface).fontColor(this.accent)
              .onClick((): void => { this.undoEdits(); })
          }
        }.width('100%').padding(14).backgroundColor(this.pal().card).borderRadius(16)
      }
      if (!this.previewing) {
        Button('预览变更').width('100%').height(44).fontSize(15).backgroundColor(this.pal().card).fontColor(this.accent)
          .enabled(this.fieldOn.some((on: boolean): boolean => on))
          .onClick((): void => { this.previewing = true; this.resultText = ''; })
      } else {
        Button('应用到 ' + batchDiffCounts(this.diffs())[0].toString() + ' 项').width('100%').height(44).fontSize(15)
          .backgroundColor(this.accent).fontColor(Color.White)
          .enabled(batchDiffCounts(this.diffs())[0] > 0)
          .onClick((): void => { this.applyEdits(); })
      }
    }.width('100%')
  }

  @Builder private sheetBody() {
    Column() {
      this.sheetTitle(this.sheet === 'group' ? '移入分组' : this.sheet === 'tags' ? '标签' : '批量编辑')
      Scroll() {
        Column() {
          if (this.sheet === 'group') { this.groupSheet() }
          if (this.sheet === 'tags') { this.tagSheet() }
          if (this.sheet === 'edit') { this.editSheet() }
        }.padding({ left: 16, right: 16, bottom: 28 })
      }.constraintSize({ maxHeight: sheetBodyMaxHeight() }).scrollBar(BarState.Off).align(Alignment.Top)
      .edgeEffect(EdgeEffect.Spring)
    }.width('100%').backgroundColor(this.pal().sheetBg)
  }

  build() {
    Row() {
      Scroll() {
        Row({ space: 2 }) {
          this.action($r('sys.symbol.folder'), '移入分组', this.pal().text, (): void => { this.open('group'); })
          this.action($r('sys.symbol.pin'), '标签', this.pal().text, (): void => { this.open('tags'); })
          this.action($r('sys.symbol.square_and_pencil'), '批量编辑', this.pal().text, (): void => { this.open('edit'); })
          this.action($r('sys.symbol.bolt_fill'), this.probing ? '检测中' : '检测连通', this.pal().text, (): void => {
            if (this.count() > 0 && !this.probing) { this.onProbe(); }
          })
          this.action($r('sys.symbol.doc'), '导出', this.pal().text, (): void => {
            if (this.count() > 0) { this.onExport(); }
          })
          this.action($r('sys.symbol.lock_fill'), '上锁', this.pal().text, (): void => {
            if (this.count() > 0) { this.onLock(true); }
          })
          this.action($r('sys.symbol.lock_open'), '解锁', this.pal().text, (): void => {
            if (this.count() > 0) { this.onLock(false); }
          })
          this.action($r('sys.symbol.ohos_trash'), '删除', this.pal().danger, (): void => {
            if (this.count() > 0) { this.onDelete(); }
          })
        }.padding({ left: 8, right: 8 })
      }.scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off).layoutWeight(1)
    }
    .height(66).borderRadius(24).backgroundColor(this.pal().floatBg)
    .backgroundBlurStyle(BlurStyle.Thick)
    .border({ width: 0.5, color: this.pal().floatBorder })
    .shadow({ radius: 18, color: '#22000000', offsetY: 6 })
    .bindSheet($$this.showSheet, this.sheetBody(), {
      height: SheetSize.FIT_CONTENT, dragBar: true, showClose: false,
      backgroundColor: this.pal().sheetBg
    })
  }
}
