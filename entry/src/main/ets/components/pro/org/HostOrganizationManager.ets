import { searchGlassBorder, searchGlassShadow, searchGlassSheen } from '../../../common/SearchBarSurface';
import { appUiOnAccentText } from '../../../common/AppUiColorPolicy';
import { common } from '@kit.AbilityKit';
import { ProSymbolIcon } from '../ProSymbolIcon';
import { AppConfig, buildDark, buildLight, Palette } from '../../../common/Theme';
import {
  danglingRefs, duplicateHostGroups, HOST_GROUP_COLORS, HOST_GROUP_ICONS, HostDuplicateGroup, HostGroupDefinition,
  HostOrganizationHostView,
  HostMembership, HostTagUsage, MAX_HOST_GROUPS, nextGroupName, normalizeHostTag, subnetSuggestions, tagUsage
} from '../../../services/pro/org/HostOrganizationPolicy';
import { HostOrganizationStore } from '../../../services/pro/org/HostOrganizationStore';
import {
  hostFilterLabel, orgHostRows, orgHostView, OrgHostRow, orgRowDetail
} from '../../../services/pro/org/HostOrganizationDirectory';
import { HostSmartFilterPreferences } from '../../../services/pro/org/HostSmartFilterPreferences';

type OrgTab = 'groups' | 'tags' | 'smart' | 'tidy';

/**
 * 高级主机管理 editor: groups (name, color, icon, order, members), tags, which smart chips the home bar shows, and
 * tidy-up tools (duplicates, deleted-host cleanup, import/export). Used by the home bar sheet and by Settings.
 */
@Component
export struct HostOrganizationManager {
  @StorageProp('currentTheme') theme: string = 'light';
  @StorageProp('accentColor') accent: string = '#007DFF';
  /** Hosts the store cannot list on its own (Moonlight, from the home page). */
  @Prop extraRows: OrgHostRow[] = [];
  /** Export/import and "select on home" only make sense where the home list is available. */
  @Prop homeActions: boolean = false;
  @Prop initialTab: string = 'groups';
  onExport: () => void = (): void => {};
  onImport: () => void = (): void => {};
  onSelectHosts: (refs: string[]) => void = (_refs: string[]): void => {};
  @State tab: OrgTab = 'groups';
  @State revision: number = 0;
  @State openGroupId: string = '';
  @State nameDraft: string = '';
  @State newGroupName: string = '';
  @State hostQuery: string = '';
  @State openTag: string = '';
  @State tagDraft: string = '';
  @State newTag: string = '';
  @State smartRevision: number = 0;
  private context: common.UIAbilityContext | null = null;
  private stop: (() => void) | null = null;

  aboutToAppear(): void {
    this.context = getContext(this) as common.UIAbilityContext;
    HostSmartFilterPreferences.getInstance().load(this.context);
    const store: HostOrganizationStore = HostOrganizationStore.getInstance();
    store.load();
    this.stop = store.subscribe((): void => { this.revision++; });
    this.tab = this.initialTab === 'tags' || this.initialTab === 'smart' || this.initialTab === 'tidy' ?
      this.initialTab as OrgTab : 'groups';
  }
  aboutToDisappear(): void { this.stop?.(); this.stop = null; this.context = null; }

  private pal(): Palette { return this.theme === 'light' ? buildLight(this.accent) : buildDark(this.accent); }
  private tint(color: string, alpha: string): string {
    return /^#[0-9A-Fa-f]{6}$/.test(color) ? '#' + alpha + color.substring(1) : color;
  }
  private rows(_revision: number): OrgHostRow[] { return orgHostRows(this.extraRows); }
  private refs(): string[] { return this.rows(this.revision).map((row: OrgHostRow): string => row.ref); }
  private groups(_revision: number): HostGroupDefinition[] { return HostOrganizationStore.getInstance().listGroups(); }
  private membership(ref: string, _revision: number): HostMembership {
    return HostOrganizationStore.getInstance().membership(ref);
  }
  private memberCount(groupId: string, _revision: number): number {
    return this.rows(this.revision).filter((row: OrgHostRow): boolean =>
      HostOrganizationStore.getInstance().membership(row.ref).groupId === groupId).length;
  }
  private groupName(groupId: string): string {
    const group: HostGroupDefinition | null = HostOrganizationStore.getInstance().group(groupId);
    return group === null ? '' : group.name;
  }
  private filteredRows(_revision: number): OrgHostRow[] {
    const query: string = this.hostQuery.trim().toLowerCase();
    const rows: OrgHostRow[] = this.rows(this.revision);
    if (query === '') { return rows; }
    return rows.filter((row: OrgHostRow): boolean => row.label.toLowerCase().includes(query) ||
      row.address.toLowerCase().includes(query) || row.protocol.includes(query));
  }
  private tags(_revision: number): HostTagUsage[] {
    return tagUsage(HostOrganizationStore.getInstance().snapshot().byHost, this.refs());
  }
  private duplicates(_revision: number): HostDuplicateGroup[] {
    return duplicateHostGroups(this.rows(this.revision).map((row: OrgHostRow): HostOrganizationHostView => orgHostView(row, undefined)));
  }
  private dangling(_revision: number): string[] {
    return danglingRefs(HostOrganizationStore.getInstance().snapshot().byHost, this.refs());
  }
  private labelFor(ref: string): string {
    const row: OrgHostRow | undefined = this.rows(this.revision).find((item: OrgHostRow): boolean => item.ref === ref);
    return row === undefined ? ref : row.label;
  }
  private toast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message, duration: 1800 });
  }

  private createGroup(): void {
    const store: HostOrganizationStore = HostOrganizationStore.getInstance();
    const groups: HostGroupDefinition[] = store.listGroups();
    if (groups.length >= MAX_HOST_GROUPS) { this.toast('最多 ' + MAX_HOST_GROUPS.toString() + ' 个分组'); return; }
    const name: string = this.newGroupName.trim().length > 0 ? this.newGroupName.trim() : nextGroupName(groups);
    const id: string = 'group-' + Date.now().toString(36);
    if (store.createGroup({ id, name, color: HOST_GROUP_COLORS[groups.length % HOST_GROUP_COLORS.length],
      icon: HOST_GROUP_ICONS[0], order: groups.length, createdAt: 0, updatedAt: 0 })) {
      this.newGroupName = '';
      this.openGroupId = id;
      this.nameDraft = name;
    } else {
      this.toast('分组未保存，请检查名称后重试');
    }
  }
  private toggleGroup(group: HostGroupDefinition): void {
    this.openGroupId = this.openGroupId === group.id ? '' : group.id;
    this.nameDraft = group.name;
    this.hostQuery = '';
  }
  private deleteGroup(group: HostGroupDefinition): void {
    this.getUIContext().getPromptAction().showDialog({
      title: '删除分组', message: '删除「' + group.name + '」？组内主机不会被删除，只是回到未分组。',
      buttons: [{ text: '取消', color: this.pal().text2 }, { text: '删除', color: this.pal().danger }]
    }).then((result): void => {
      if (result.index === 1 && HostOrganizationStore.getInstance().deleteGroup(group.id)) { this.openGroupId = ''; }
    }).catch((): void => {});
  }
  private toggleTagHost(tag: string, ref: string, on: boolean): void {
    const store: HostOrganizationStore = HostOrganizationStore.getInstance();
    if (on) { store.addTags([ref], [tag]); } else { store.removeTags([ref], [tag]); }
  }
  private startTag(): void {
    const tag: string = normalizeHostTag(this.newTag);
    if (tag.length === 0) { return; }
    this.openTag = tag; this.tagDraft = tag; this.newTag = ''; this.hostQuery = '';
  }
  private renameTag(from: string): void {
    const to: string = normalizeHostTag(this.tagDraft);
    if (to.length === 0 || to === from) { return; }
    if (HostOrganizationStore.getInstance().renameTag(from, to)) { this.openTag = to; }
  }
  private deleteTag(tag: string): void {
    this.getUIContext().getPromptAction().showDialog({
      title: '删除标签', message: '从所有主机上移除「' + tag + '」？主机不受影响。',
      buttons: [{ text: '取消', color: this.pal().text2 }, { text: '删除', color: this.pal().danger }]
    }).then((result): void => {
      if (result.index === 1 && HostOrganizationStore.getInstance().deleteTag(tag)) { this.openTag = ''; }
    }).catch((): void => {});
  }
  private smartOn(key: string, _revision: number): boolean { return HostSmartFilterPreferences.getInstance().has(key); }
  private setSmart(key: string, on: boolean): void {
    if (this.context === null) { return; }
    HostSmartFilterPreferences.getInstance().toggle(this.context, key, on);
    this.smartRevision++;
  }
  private protocolKeys(): string[] {
    const protocols: string[] = [];
    this.rows(this.revision).forEach((row: OrgHostRow): void => {
      if (protocols.indexOf(row.protocol) < 0) { protocols.push(row.protocol); }
    });
    return protocols.sort().map((protocol: string): string => 'protocol:' + protocol);
  }
  private subnetKeys(): string[] {
    return subnetSuggestions(this.rows(this.revision).map((row: OrgHostRow): HostOrganizationHostView => orgHostView(row, undefined)))
      .slice(0, 8).map((subnet: string): string => 'subnet:' + subnet);
  }
  private tagKeys(): string[] {
    return this.tags(this.revision).slice(0, 12).map((usage: HostTagUsage): string => 'tag:' + usage.tag);
  }
  private pruneDangling(): void {
    const removed: number = HostOrganizationStore.getInstance().pruneDangling(this.refs());
    this.toast(removed > 0 ? '已清理 ' + removed.toString() + ' 条失效记录' : '没有需要清理的记录');
  }

  @Builder private tabButton(tab: OrgTab, title: string) {
    Text(title).fontSize(13).fontFamily(AppConfig.fontFamily)
      .fontColor(this.tab === tab ? Color.White : this.pal().text2)
      .fontWeight(this.tab === tab ? FontWeight.Medium : FontWeight.Normal)
      .padding({ left: 12, right: 12, top: 7, bottom: 7 }).borderRadius(16)
      .backgroundColor(this.tab === tab ? this.accent : Color.Transparent)
      .onClick((): void => { this.tab = tab; this.hostQuery = ''; })
  }

  @Builder private sectionHint(text: string) {
    Text(text).fontSize(11).fontColor(this.pal().text3).fontFamily(AppConfig.fontFamily).lineHeight(16)
      .width('100%').padding({ left: 4, right: 4 })
  }

  @Builder private hostChecklist(checked: (ref: string) => boolean, onToggle: (ref: string, on: boolean) => void,
    badge: (ref: string) => string) {
    Column({ space: 8 }) {
      if (this.rows(this.revision).length > 8) {
        Search({ value: this.hostQuery, placeholder: '搜索主机' }).height(36).borderRadius(18)
          .backgroundColor(this.pal().surface).linearGradient(searchGlassSheen(this.theme !== 'light')).backgroundBlurStyle(BlurStyle.Regular).border(searchGlassBorder(this.theme !== 'light')).shadow(searchGlassShadow(this.theme !== 'light'))
          .onChange((value: string): void => { this.hostQuery = value; })
      }
      if (this.rows(this.revision).length === 0) {
        Text('还没有主机').fontSize(12).fontColor(this.pal().text3).width('100%')
      }
      ForEach(this.filteredRows(this.revision), (row: OrgHostRow): void => {
        Row({ space: 10 }) {
          Column({ space: 2 }) {
            Text(row.label).fontSize(14).fontColor(this.pal().text).maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            Text(orgRowDetail(row) + badge(row.ref)).fontSize(11).fontColor(this.pal().text3).maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }.alignItems(HorizontalAlign.Start).layoutWeight(1)
          Checkbox().select(checked(row.ref)).selectedColor(this.accent)
            .onChange((on: boolean): void => { onToggle(row.ref, on); })
        }.width('100%').padding({ top: 2, bottom: 2 })
      }, (row: OrgHostRow): string => row.ref + ':' + this.revision.toString())
    }.width('100%')
  }

  @Builder private groupEditor(group: HostGroupDefinition) {
    Column({ space: 12 }) {
      Row({ space: 8 }) {
        TextInput({ text: this.nameDraft, placeholder: '分组名称' }).height(38).layoutWeight(1).maxLength(32)
          .backgroundColor(this.pal().surface).borderRadius(10)
          .onChange((value: string): void => { this.nameDraft = value; })
          .onSubmit((): void => { HostOrganizationStore.getInstance().renameGroup(group.id, this.nameDraft); })
        Button('改名').height(36).fontSize(12).backgroundColor(this.accent).fontColor(appUiOnAccentText(this.accent))
          .enabled(this.nameDraft.trim().length > 0 && this.nameDraft.trim() !== group.name)
          .onClick((): void => { HostOrganizationStore.getInstance().renameGroup(group.id, this.nameDraft); })
      }.width('100%')
      Text('颜色').fontSize(12).fontColor(this.pal().text3).width('100%')
      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach(HOST_GROUP_COLORS, (color: string): void => {
          Stack() {
            Circle().width(26).height(26).fill(color)
            if (group.color === color) { Circle().width(10).height(10).fill(Color.White) }
          }.width(34).height(34).onClick((): void => {
            HostOrganizationStore.getInstance().updateGroup(group.id, '', color, '');
          })
        }, (color: string): string => color)
      }.width('100%')
      Text('图标').fontSize(12).fontColor(this.pal().text3).width('100%')
      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach(HOST_GROUP_ICONS, (icon: string): void => {
          Column() { ProSymbolIcon({ icon: icon, glyphSize: 20, color: group.icon === icon ? group.color : this.pal().text2 }) }.width(40).height(40).justifyContent(FlexAlign.Center).borderRadius(12)
            .backgroundColor(group.icon === icon ? this.tint(group.color, '33') : Color.Transparent)
            .border({ width: group.icon === icon ? 1.5 : 0, color: group.color })
            .onClick((): void => { HostOrganizationStore.getInstance().updateGroup(group.id, '', '', icon); })
        }, (icon: string): string => icon)
      }.width('100%')
      Text('组内主机').fontSize(12).fontColor(this.pal().text3).width('100%')
      this.hostChecklist(
        (ref: string): boolean => this.membership(ref, this.revision).groupId === group.id,
        (ref: string, on: boolean): void => { HostOrganizationStore.getInstance().assignHost(ref, on ? group.id : ''); },
        (ref: string): string => {
          const current: string = this.membership(ref, this.revision).groupId;
          return current !== '' && current !== group.id ? ' · 当前在「' + this.groupName(current) + '」' : '';
        })
      Button('删除分组').width('100%').height(38).fontSize(13).fontColor(this.pal().danger)
        .backgroundColor(this.pal().surface).onClick((): void => { this.deleteGroup(group); })
    }.width('100%').padding({ left: 16, right: 16, bottom: 16 })
  }

  @Builder private groupsTab() {
    Column({ space: 8 }) {
      this.sectionHint('每台主机属于一个分组；所有协议都可以加入。点开分组可改名、换色、换图标和选择主机，删除分组不会删除主机。')
      Column() {
        ForEach(this.groups(this.revision), (group: HostGroupDefinition, index: number): void => {
          if (index > 0) { Divider().strokeWidth(0.5).color(this.pal().cardBorder).margin({ left: 16, right: 16 }) }
          Column() {
            Row({ space: 10 }) {
              Column() { ProSymbolIcon({ icon: group.icon, glyphSize: 18, color: group.color }) }.width(34).height(34).justifyContent(FlexAlign.Center).borderRadius(10)
                .backgroundColor(this.tint(group.color, '26'))
              Column({ space: 2 }) {
                Text(group.name).fontSize(15).fontColor(this.pal().text).fontFamily(AppConfig.fontFamily).maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                Text(this.memberCount(group.id, this.revision).toString() + ' 台主机').fontSize(11)
                  .fontColor(this.pal().text3)
              }.alignItems(HorizontalAlign.Start).layoutWeight(1)
              SymbolGlyph($r('sys.symbol.chevron_up')).fontSize(14).padding(6)
                .fontColor([index === 0 ? this.pal().cardBorder : this.pal().text3])
                .onClick((): void => { HostOrganizationStore.getInstance().moveGroup(group.id, -1); })
              SymbolGlyph($r('sys.symbol.chevron_down')).fontSize(14).padding(6)
                .fontColor([index === this.groups(this.revision).length - 1 ? this.pal().cardBorder : this.pal().text3])
                .onClick((): void => { HostOrganizationStore.getInstance().moveGroup(group.id, 1); })
              Circle().width(10).height(10).fill(group.color)
            }.width('100%').padding({ left: 14, right: 14, top: 12, bottom: 12 })
            .onClick((): void => { this.toggleGroup(group); })
            if (this.openGroupId === group.id) { this.groupEditor(group) }
          }.width('100%')
        }, (group: HostGroupDefinition): string => group.id + ':' + group.updatedAt.toString() + ':' +
          group.order.toString() + ':' + this.revision.toString())
        if (this.groups(this.revision).length > 0) {
          Divider().strokeWidth(0.5).color(this.pal().cardBorder).margin({ left: 16, right: 16 })
        }
        Row({ space: 8 }) {
          TextInput({ text: this.newGroupName, placeholder: '新分组名称，例如「生产」' }).height(38).layoutWeight(1)
            .maxLength(32).backgroundColor(this.pal().surface).borderRadius(10)
            .onChange((value: string): void => { this.newGroupName = value; })
            .onSubmit((): void => { this.createGroup(); })
          Button('＋ 新建').height(36).fontSize(12).backgroundColor(this.accent).fontColor(appUiOnAccentText(this.accent))
            .onClick((): void => { this.createGroup(); })
        }.width('100%').padding(14)
      }.width('100%').backgroundColor(this.pal().card).borderRadius(16)
    }.width('100%')
  }

  @Builder private tagEditor(tag: string) {
    Column({ space: 10 }) {
      Row({ space: 8 }) {
        TextInput({ text: this.tagDraft, placeholder: '标签名称' }).height(38).layoutWeight(1).maxLength(32)
          .backgroundColor(this.pal().surface).borderRadius(10)
          .onChange((value: string): void => { this.tagDraft = value; })
        Button('改名').height(36).fontSize(12).backgroundColor(this.accent).fontColor(appUiOnAccentText(this.accent))
          .enabled(normalizeHostTag(this.tagDraft).length > 0 && normalizeHostTag(this.tagDraft) !== tag)
          .onClick((): void => { this.renameTag(tag); })
      }.width('100%')
      Text('改成已有的标签名会合并两个标签').fontSize(11).fontColor(this.pal().text3).width('100%')
      this.hostChecklist(
        (ref: string): boolean => this.membership(ref, this.revision).tags.indexOf(tag) >= 0,
        (ref: string, on: boolean): void => { this.toggleTagHost(tag, ref, on); },
        (_ref: string): string => '')
      Button('删除标签').width('100%').height(38).fontSize(13).fontColor(this.pal().danger)
        .backgroundColor(this.pal().surface).onClick((): void => { this.deleteTag(tag); })
    }.width('100%').padding({ left: 16, right: 16, bottom: 16 })
  }

  @Builder private tagsTab() {
    Column({ space: 8 }) {
      this.sectionHint('一台主机最多 10 个标签，可用于搜索和首页筛选。也可以在首页多选主机后批量打标签。')
      Column() {
        ForEach(this.tags(this.revision), (usage: HostTagUsage, index: number): void => {
          if (index > 0) { Divider().strokeWidth(0.5).color(this.pal().cardBorder).margin({ left: 16, right: 16 }) }
          Column() {
            Row({ space: 10 }) {
              Text('#').fontSize(16).fontColor(this.accent).width(28).textAlign(TextAlign.Center)
              Text(usage.tag).fontSize(15).fontColor(this.pal().text).layoutWeight(1).maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              Text(usage.count.toString() + ' 台').fontSize(12).fontColor(this.pal().text3)
            }.width('100%').padding({ left: 14, right: 14, top: 12, bottom: 12 })
            .onClick((): void => {
              this.openTag = this.openTag === usage.tag ? '' : usage.tag; this.tagDraft = usage.tag; this.hostQuery = '';
            })
            if (this.openTag === usage.tag) { this.tagEditor(usage.tag) }
          }.width('100%')
        }, (usage: HostTagUsage): string => usage.tag + ':' + usage.count.toString() + ':' + this.revision.toString())
        if (this.openTag !== '' && !this.tags(this.revision).some((usage: HostTagUsage): boolean => usage.tag === this.openTag)) {
          Column() {
            Text('新标签「' + this.openTag + '」：勾选主机后保存').fontSize(13).fontColor(this.pal().text2)
              .width('100%').padding({ left: 16, right: 16, top: 12, bottom: 8 })
            this.hostChecklist(
              (_ref: string): boolean => false,
              (ref: string, on: boolean): void => { this.toggleTagHost(this.openTag, ref, on); },
              (_ref: string): string => '')
          }.width('100%').padding({ left: 0, right: 0, bottom: 12 })
        }
        if (this.tags(this.revision).length > 0) {
          Divider().strokeWidth(0.5).color(this.pal().cardBorder).margin({ left: 16, right: 16 })
        }
        Row({ space: 8 }) {
          TextInput({ text: this.newTag, placeholder: '新标签，例如「客户 A」' }).height(38).layoutWeight(1)
            .maxLength(32).backgroundColor(this.pal().surface).borderRadius(10)
            .onChange((value: string): void => { this.newTag = value; })
            .onSubmit((): void => { this.startTag(); })
          Button('＋ 新建').height(36).fontSize(12).backgroundColor(this.accent).fontColor(appUiOnAccentText(this.accent))
            .enabled(normalizeHostTag(this.newTag).length > 0).onClick((): void => { this.startTag(); })
        }.width('100%').padding(14)
      }.width('100%').backgroundColor(this.pal().card).borderRadius(16)
    }.width('100%')
  }

  @Builder private smartChip(key: string) {
    Row({ space: 4 }) {
      if (this.smartOn(key, this.smartRevision)) {
        SymbolGlyph($r('sys.symbol.checkmark')).fontSize(12).fontColor([this.accent])
      }
      Text(hostFilterLabel(key)).fontSize(13)
        .fontColor(this.smartOn(key, this.smartRevision) ? this.accent : this.pal().text2)
    }.padding({ left: 12, right: 12, top: 7, bottom: 7 }).borderRadius(16).margin({ right: 8, bottom: 8 })
    .backgroundColor(this.smartOn(key, this.smartRevision) ? this.tint(this.accent, '1F') : this.pal().surface)
    .border({ width: 1, color: this.smartOn(key, this.smartRevision) ? this.accent : Color.Transparent })
    .onClick((): void => { this.setSmart(key, !this.smartOn(key, this.smartRevision)); })
  }

  @Builder private smartSection(title: string, keys: string[], empty: string) {
    Column({ space: 8 }) {
      Text(title).fontSize(13).fontColor(this.pal().text2).width('100%')
      if (keys.length === 0) {
        Text(empty).fontSize(12).fontColor(this.pal().text3).width('100%')
      } else {
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(keys, (key: string): void => { this.smartChip(key) }, (key: string): string => key)
        }.width('100%')
      }
    }.width('100%').padding(14).backgroundColor(this.pal().card).borderRadius(16)
  }

  @Builder private smartTab() {
    Column({ space: 10 }) {
      this.sectionHint('智能分组按规则自动归类，不会改动主机。选中的项目会显示在首页分组栏中。')
      this.smartSection('常用', ['recent', 'online', 'offline', 'unassigned'], '')
      this.smartSection('按协议', this.protocolKeys(), '还没有主机')
      this.smartSection('按网段', this.subnetKeys(), '至少两台主机位于同一 /24 网段时会出现在这里')
      this.smartSection('按标签', this.tagKeys(), '给主机打上标签后可以按标签筛选')
    }.width('100%')
  }

  @Builder private tidyTab() {
    Column({ space: 10 }) {
      Column({ space: 8 }) {
        Text('重复主机').fontSize(14).fontWeight(FontWeight.Medium).fontColor(this.pal().text).width('100%')
        if (this.duplicates(this.revision).length === 0) {
          Text('没有发现协议、地址、端口和用户名都相同的主机').fontSize(12).fontColor(this.pal().text3).width('100%')
        }
        ForEach(this.duplicates(this.revision), (group: HostDuplicateGroup): void => {
          Row({ space: 8 }) {
            Column({ space: 2 }) {
              Text(group.hostIds.map((ref: string): string => this.labelFor(ref)).join('、')).fontSize(13)
                .fontColor(this.pal().text).maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
              Text(group.key.split('|').slice(1, 3).join(':')).fontSize(11).fontColor(this.pal().text3)
            }.alignItems(HorizontalAlign.Start).layoutWeight(1)
            if (this.homeActions) {
              Button('在列表中选中').height(30).fontSize(12).backgroundColor(this.pal().surface)
                .fontColor(this.accent).onClick((): void => { this.onSelectHosts(group.hostIds); })
            }
          }.width('100%').padding({ top: 4, bottom: 4 })
        }, (group: HostDuplicateGroup): string => group.key)
        Text('不会自动删除；确认后可以在首页多选删除多余的一台。').fontSize(11).fontColor(this.pal().text3).width('100%')
      }.width('100%').padding(14).backgroundColor(this.pal().card).borderRadius(16)
      Column({ space: 8 }) {
        Row() {
          Column({ space: 2 }) {
            Text('失效的分组记录').fontSize(14).fontWeight(FontWeight.Medium).fontColor(this.pal().text)
            Text(this.dangling(this.revision).length === 0 ? '没有指向已删除主机的记录' :
              this.dangling(this.revision).length.toString() + ' 条记录指向已删除的主机')
              .fontSize(12).fontColor(this.pal().text3)
          }.alignItems(HorizontalAlign.Start).layoutWeight(1)
          Button('清理').height(32).fontSize(12).backgroundColor(this.pal().surface).fontColor(this.accent)
            .enabled(this.dangling(this.revision).length > 0).onClick((): void => { this.pruneDangling(); })
        }.width('100%')
      }.width('100%').padding(14).backgroundColor(this.pal().card).borderRadius(16)
      if (this.homeActions) {
        Column({ space: 10 }) {
          Text('导入与导出').fontSize(14).fontWeight(FontWeight.Medium).fontColor(this.pal().text).width('100%')
          Text('导出为 JSON 文件，只包含名称、地址、端口、用户名、分组和标签，不含任何密码、私钥或令牌。')
            .fontSize(12).fontColor(this.pal().text3).lineHeight(17).width('100%')
          Row({ space: 8 }) {
            Button('导出主机').height(38).layoutWeight(1).fontSize(13).backgroundColor(this.pal().surface)
              .fontColor(this.accent).onClick((): void => { this.onExport(); })
            Button('导入主机').height(38).layoutWeight(1).fontSize(13).backgroundColor(this.pal().surface)
              .fontColor(this.accent).onClick((): void => { this.onImport(); })
          }.width('100%')
        }.width('100%').padding(14).backgroundColor(this.pal().card).borderRadius(16)
      }
    }.width('100%')
  }

  build() {
    Column({ space: 12 }) {
      Scroll() {
        Row({ space: 4 }) {
          this.tabButton('groups', '分组')
          this.tabButton('tags', '标签')
          this.tabButton('smart', '智能分组')
          this.tabButton('tidy', '整理')
        }.padding(3).borderRadius(19).backgroundColor(this.pal().surface)
      }.scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off).align(Alignment.Start).width('100%')
      if (this.tab === 'groups') { this.groupsTab() }
      if (this.tab === 'tags') { this.tagsTab() }
      if (this.tab === 'smart') { this.smartTab() }
      if (this.tab === 'tidy') { this.tidyTab() }
    }.width('100%')
  }
}
