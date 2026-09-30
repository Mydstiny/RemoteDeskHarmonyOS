import { common } from '@kit.AbilityKit';
import { AppConfig, Palette, buildDark, buildLight } from '../common/Theme';
import { ProBadge, ProBadgePreferences } from './ProBadge';
import { ProEntries } from '../services/pro/ProEntries';
import { ProFeature } from '../services/pro/ProFeatureCatalog';
import { ProFeatureStatus, proFeatureScope } from '../services/pro/ProFeatureStatus';
import { proFeatureCurrentStatus } from '../services/pro/ProFeatureStatusReader';
import { ProFeatureVisibility } from '../services/pro/ProFeatureVisibility';
import { PRO_CONTINUATION_PROTOCOLS, ProContinuationCredentialMode, ProContinuationPreferences,
  ProContinuationSettings, proContinuationProtocolLabel } from '../services/pro/ProContinuationPreferences';
import { ProConnectionProtocol } from '../services/pro/ProConnectionEnvelope';
import { PRO_CONTINUATION_FEATURE, ProContinuationService } from '../services/pro/ProContinuationService';
import { RemoteHost } from '../model/RemoteHost';
import { HostSyncService } from '../services/HostSyncService';
import { VncHostService, VncHostView } from '../services/VncHostService';
import { projectVncHost } from '../services/VncHostListProjectionPolicy';
import { HostGroupDefinition, hostRefForProtocol } from '../services/pro/org/HostOrganizationPolicy';
import { HostOrganizationStore } from '../services/pro/org/HostOrganizationStore';
import { Workspace } from '../services/pro/workspace/WorkspacePolicy';
import { WorkspaceStore } from '../services/pro/workspace/WorkspaceStore';
import { ProWorkspaceEditorPanel } from './ProWorkspaceEditorPanel';

const HOST_MANAGEMENT_FEATURE: string = 'pro.hostManagement';
const WORKSPACES_FEATURE: string = 'pro.workspaces';
const GROUP_COLORS: string[] = ['#007DFF', '#34C759', '#FF9500', '#AF52DE', '#FF3B30', '#5AC8FA', '#FFCC00', '#8E8E93'];

/** One host row in the group editor; `ref` is the cross-protocol organization reference. */
interface OrgHostRow { ref: string; label: string; detail: string; }

/** Settings sheet for one Pro feature: live status, scope, display switch and its own options. */
@Component
export struct ProFeatureDetailPanel {
  @StorageProp('currentTheme') theme: string = 'light';
  @StorageProp('accentColor') accent: string = '#007DFF';
  @Prop featureId: string = '';
  @State revision: number = 0;
  @State continuation: ProContinuationSettings = ProContinuationPreferences.getInstance().settings();
  @State collaborationGranted: boolean = true;
  // 高级主机管理 / 工作区与布局 options.
  @State orgRevision: number = 0;
  @State openGroupId: string = '';
  @State groupNameDraft: string = '';
  @State newGroupName: string = '';
  @State openWorkspaceId: string = '';
  @State workspaceNameDraft: string = '';
  @State editingWorkspace: Workspace | null = null;
  private stopOrg: (() => void) | null = null;
  private stopWorkspaces: (() => void) | null = null;
  private contextValue: common.UIAbilityContext | null = null;
  private stop: (() => void) | null = null;
  private stopContinuation: (() => void) | null = null;

  aboutToAppear(): void {
    this.contextValue = getContext(this) as common.UIAbilityContext;
    ProFeatureVisibility.getInstance().load(this.contextValue);
    ProContinuationPreferences.getInstance().load(this.contextValue);
    this.stop = ProEntries.subscribe((): void => { this.revision++; });
    if (this.featureId === PRO_CONTINUATION_FEATURE) { void this.syncCollaboration(false); }
    this.stopContinuation = ProContinuationPreferences.getInstance().subscribe((): void => {
      this.continuation = ProContinuationPreferences.getInstance().settings();
    });
    if (this.featureId === HOST_MANAGEMENT_FEATURE) {
      HostOrganizationStore.getInstance().load();
      this.stopOrg = HostOrganizationStore.getInstance().subscribe((): void => { this.orgRevision++; });
    }
    if (this.featureId === WORKSPACES_FEATURE) {
      WorkspaceStore.getInstance().load();
      this.stopWorkspaces = WorkspaceStore.getInstance().subscribe((): void => { this.orgRevision++; });
    }
  }
  aboutToDisappear(): void {
    this.stop?.(); this.stop = null; this.stopContinuation?.(); this.stopContinuation = null; this.contextValue = null;
    this.stopOrg?.(); this.stopOrg = null; this.stopWorkspaces?.(); this.stopWorkspaces = null;
  }
  private pal(): Palette { return this.theme === 'light' ? buildLight(this.accent) : buildDark(this.accent); }
  private feature(_revision: number): ProFeature | undefined {
    return ProFeatureVisibility.getInstance().proCatalog().find((item: ProFeature): boolean => item.id === this.featureId);
  }
  private status(_revision: number): ProFeatureStatus | null {
    const feature = this.feature(this.revision);
    return feature === undefined ? null : proFeatureCurrentStatus(feature);
  }
  private toneColor(status: ProFeatureStatus | null): ResourceColor {
    if (status !== null && status.tone === 'ready') { return this.accent; }
    if (status !== null && status.tone === 'experimental') { return '#B26A00'; }
    return this.pal().text3;
  }
  private async syncCollaboration(request: boolean): Promise<void> {
    if (this.contextValue === null) { return; }
    const context = this.contextValue;
    this.collaborationGranted = await ProContinuationService.getInstance().syncPermission(context, request);
  }
  private updateContinuation(next: ProContinuationSettings): void {
    if (this.contextValue === null) { return; }
    ProContinuationPreferences.getInstance().update(this.contextValue, next);
  }
  private withAuto(auto: boolean): ProContinuationSettings {
    return { auto, credentialMode: this.continuation.credentialMode, protocols: this.continuation.protocols };
  }
  private withMode(mode: ProContinuationCredentialMode): ProContinuationSettings {
    return { auto: this.continuation.auto, credentialMode: mode, protocols: this.continuation.protocols };
  }
  private withProtocol(protocol: ProConnectionProtocol, on: boolean): ProContinuationSettings {
    const protocols = PRO_CONTINUATION_PROTOCOLS.filter((item: ProConnectionProtocol): boolean =>
      item === protocol ? on : this.continuation.protocols.indexOf(item) >= 0);
    return { auto: this.continuation.auto, credentialMode: this.continuation.credentialMode, protocols };
  }
  private protocolDetail(protocol: ProConnectionProtocol): string {
    if (protocol === 'ssh') { return '连接后自动开启，恢复当前终端或文件目录'; }
    if (protocol === 'rdp') { return '连接后自动开启，恢复显示器、缩放与视图位置；也可在控制中心按当前画面重新准备'; }
    return '连接后自动开启，在目标设备重新连接同一台主机';
  }
  /** #AARRGGBB tint of the accent for the selected option card. */
  private accentTint(alpha: string): string {
    return /^#[0-9A-Fa-f]{6}$/.test(this.accent) ? '#' + alpha + this.accent.substring(1) : this.accent;
  }
  @Builder private sectionTitle(title: string) {
    Text(title).fontSize(13).fontColor(this.pal().text2).fontFamily(AppConfig.fontFamily).width('100%')
      .padding({ left: 4 })
  }
  @Builder private credentialOption(mode: ProContinuationCredentialMode, icon: Resource, title: string, detail: string) {
    Row({ space: 12 }) {
      Stack() {
        SymbolGlyph(icon).fontSize(18)
          .fontColor([this.continuation.credentialMode === mode ? Color.White : this.accent])
      }.width(36).height(36).borderRadius(18)
      .backgroundColor(this.continuation.credentialMode === mode ? this.accent : this.accentTint('1F'))
      Column({ space: 3 }) {
        Text(title).fontSize(15).fontWeight(FontWeight.Medium).fontColor(this.pal().text)
          .fontFamily(AppConfig.fontFamily).width('100%')
        Text(detail).fontSize(12).fontColor(this.pal().text3).fontFamily(AppConfig.fontFamily).lineHeight(17).width('100%')
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      SymbolGlyph(this.continuation.credentialMode === mode ? $r('sys.symbol.checkmark_circle_fill') : $r('sys.symbol.circle'))
        .fontSize(20).fontColor([this.continuation.credentialMode === mode ? this.accent : this.pal().text3])
    }
    .width('100%').padding(14).borderRadius(16)
    .backgroundColor(this.continuation.credentialMode === mode ? this.accentTint('14') : this.pal().card)
    .border({ width: this.continuation.credentialMode === mode ? 1.5 : 1,
      color: this.continuation.credentialMode === mode ? this.accent : this.pal().cardBorder })
    .onClick((): void => { this.updateContinuation(this.withMode(mode)); })
    .accessibilityText(title + '，' + detail)
    .accessibilityChecked(this.continuation.credentialMode === mode)
  }
  @Builder private continuationOptions() {
    Column() {
      this.switchRow('Pro 下自动开启接续', '连上下方开启的协议后自动允许在同账号设备继续；关闭后只有 RDP 可在控制中心手动准备',
        this.continuation.auto, (on: boolean): void => { this.updateContinuation(this.withAuto(on)); })
      if (!this.collaborationGranted) {
        Divider().strokeWidth(0.5).color(this.pal().cardBorder).margin({ left: 16, right: 16 })
        Row({ space: 12 }) {
          Column({ space: 3 }) {
            Text('需要“多设备协同”权限').fontSize(15).fontColor(this.pal().text).fontFamily(AppConfig.fontFamily).width('100%')
            Text('未授予时不会出现接续图标').fontSize(12).fontColor(this.pal().text3).fontFamily(AppConfig.fontFamily).width('100%')
          }.layoutWeight(1).alignItems(HorizontalAlign.Start)
          Button('授予').fontSize(13).height(32).backgroundColor(this.accent).fontColor(Color.White)
            .onClick((): void => { void this.syncCollaboration(true); })
        }.width('100%').padding(16)
      }
    }.width('100%').backgroundColor(this.pal().card).borderRadius(16)
    Column({ space: 8 }) {
      this.sectionTitle('允许接续的协议')
      Column() {
        ForEach(PRO_CONTINUATION_PROTOCOLS, (protocol: ProConnectionProtocol, index: number): void => {
          if (index > 0) { Divider().strokeWidth(0.5).color(this.pal().cardBorder).margin({ left: 16, right: 16 }) }
          this.switchRow(proContinuationProtocolLabel(protocol), this.protocolDetail(protocol),
            this.continuation.protocols.indexOf(protocol) >= 0,
            (on: boolean): void => { this.updateContinuation(this.withProtocol(protocol, on)); })
        }, (protocol: ProConnectionProtocol): string => protocol + ':' +
          (this.continuation.protocols.indexOf(protocol) >= 0 ? '1' : '0'))
      }.width('100%').backgroundColor(this.pal().card).borderRadius(16)
      Text('关闭的协议在本设备既不会发起接续，也不会接收来自其他设备的接续。')
        .fontSize(12).fontColor(this.pal().text3).fontFamily(AppConfig.fontFamily).lineHeight(17).width('100%')
        .padding({ left: 4, right: 4 })
    }.width('100%')
    Column({ space: 10 }) {
      this.sectionTitle('接续时的密码与密钥')
      this.credentialOption('manual', $r('sys.symbol.keyboard'), '在目标设备输入（默认）',
        '目标设备使用自己保存的凭据；没有保存时弹窗让你输入密码或选择本机密钥')
      this.credentialOption('transfer', $r('sys.symbol.key_fill'), '随接续传输',
        '把这台主机在本机保存的密码或私钥一次性交给目标设备，免去再次输入；适用于 SSH、RDP、RustDesk、VNC')
      if (this.continuation.credentialMode === 'transfer') {
        Row({ space: 10 }) {
          SymbolGlyph($r('sys.symbol.exclamationmark_triangle_fill')).fontSize(16).fontColor(['#B26A00'])
          Text('风险提示：接续时，本设备会把这台主机保存的密码或私钥经系统分布式通道加密发送给同账号的目标设备，只用于那一次连接、不写入目标设备，最长保留 2 分钟。若同账号的其他设备丢失或被他人使用，对方可能借接续获得这台主机的访问凭据。请只在自己信任的设备间开启；私钥口令未保存时仍需在目标设备输入。')
            .fontSize(12).fontColor('#B26A00').fontFamily(AppConfig.fontFamily).lineHeight(18).layoutWeight(1)
        }.width('100%').padding(12).borderRadius(12).backgroundColor('#1FB26A00').alignItems(VerticalAlign.Top)
      } else {
        Row({ space: 10 }) {
          SymbolGlyph($r('sys.symbol.lock_shield_fill')).fontSize(16).fontColor([this.accent])
          Text('密码和私钥不会离开本设备。')
            .fontSize(12).fontColor(this.pal().text2).fontFamily(AppConfig.fontFamily).lineHeight(18).layoutWeight(1)
        }.width('100%').padding(12).borderRadius(12).backgroundColor(this.accentTint('14'))
      }
    }.width('100%')
  }
  @Builder private switchRow(title: string, detail: string, isOn: boolean, onChange: (on: boolean) => void) {
    Row({ space: 12 }) {
      Column({ space: 3 }) {
        Text(title).fontSize(15).fontColor(this.pal().text).fontFamily(AppConfig.fontFamily).width('100%')
        if (detail.length > 0) {
          Text(detail).fontSize(12).fontColor(this.pal().text3).fontFamily(AppConfig.fontFamily).lineHeight(17).width('100%')
        }
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      Toggle({ type: ToggleType.Switch, isOn }).selectedColor(this.accent).accessibilityText(title).onChange(onChange)
    }.width('100%').padding(16)
  }
  // ---------- 高级主机管理 ----------
  private orgGroups(_revision: number): HostGroupDefinition[] { return HostOrganizationStore.getInstance().listGroups(); }
  /** Hosts that can join a group: the synced RDP/RustDesk/SSH records plus VNC hosts. */
  private orgHosts(): OrgHostRow[] {
    const rows: OrgHostRow[] = HostSyncService.getInstance().getAllHosts()
      .filter((host: RemoteHost): boolean => host.protocol === 'rdp' || host.protocol === 'rustdesk' || host.protocol === 'ssh')
      .map((host: RemoteHost): OrgHostRow => ({ ref: hostRefForProtocol(host.protocol, host.id),
        label: host.label.length > 0 ? host.label : host.host, detail: host.protocol.toUpperCase() + ' · ' + host.host }));
    VncHostService.getInstance().list().forEach((view: VncHostView): void => {
      rows.push({ ref: hostRefForProtocol('vnc', view.id), label: view.label.length > 0 ? view.label : view.host,
        detail: 'VNC · ' + view.host });
    });
    return rows;
  }
  private groupMemberCount(groupId: string, _revision: number): number {
    const store: HostOrganizationStore = HostOrganizationStore.getInstance();
    return this.orgHosts().filter((row: OrgHostRow): boolean => store.membership(row.ref).groupId === groupId).length;
  }
  private inGroup(ref: string, groupId: string, _revision: number): boolean {
    return HostOrganizationStore.getInstance().membership(ref).groupId === groupId;
  }
  private createGroup(): void {
    const name: string = this.newGroupName.trim();
    if (name.length === 0) { return; }
    const count: number = this.orgGroups(this.orgRevision).length;
    const ok: boolean = HostOrganizationStore.getInstance().createGroup({ id: 'group-' + Date.now().toString(36),
      name, color: GROUP_COLORS[count % GROUP_COLORS.length], icon: 'folder', order: count, createdAt: 0, updatedAt: 0 });
    if (ok) { this.newGroupName = ''; }
  }
  private toggleGroup(group: HostGroupDefinition): void {
    this.openGroupId = this.openGroupId === group.id ? '' : group.id;
    this.groupNameDraft = group.name;
  }
  private deleteGroup(group: HostGroupDefinition): void {
    this.getUIContext().getPromptAction().showDialog({
      title: '删除分组', message: '删除「' + group.name + '」？主机不会被删除，只是回到未分组。',
      buttons: [{ text: '取消', color: this.pal().text2 }, { text: '删除', color: this.pal().danger }]
    }).then((result): void => {
      if (result.index === 1 && HostOrganizationStore.getInstance().deleteGroup(group.id)) { this.openGroupId = ''; }
    }).catch((): void => {});
  }

  @Builder private sectionHeader(title: string, detail: string) {
    Column({ space: 2 }) {
      Text(title).fontSize(13).fontColor(this.pal().text2).fontFamily(AppConfig.fontFamily).width('100%')
      if (detail.length > 0) {
        Text(detail).fontSize(11).fontColor(this.pal().text3).fontFamily(AppConfig.fontFamily).lineHeight(16).width('100%')
      }
    }.width('100%').padding({ left: 4, right: 4 })
  }

  @Builder private hostManagementOptions() {
    Column({ space: 8 }) {
      this.sectionHeader('分组', '跨协议整理主机；每台主机属于一个分组，展开分组可改名、选择主机或删除')
      Column() {
        ForEach(this.orgGroups(this.orgRevision), (group: HostGroupDefinition, index: number): void => {
          if (index > 0) { Divider().strokeWidth(0.5).color(this.pal().cardBorder).margin({ left: 16, right: 16 }) }
          Column() {
            Row({ space: 10 }) {
              Circle().width(12).height(12).fill(group.color.length > 0 ? group.color : this.accent)
              Text(group.name).fontSize(15).fontColor(this.pal().text).fontFamily(AppConfig.fontFamily)
                .layoutWeight(1).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
              Text(this.groupMemberCount(group.id, this.orgRevision).toString() + ' 台').fontSize(12)
                .fontColor(this.pal().text3)
              SymbolGlyph(this.openGroupId === group.id ? $r('sys.symbol.chevron_up') : $r('sys.symbol.chevron_down'))
                .fontSize(14).fontColor([this.pal().text3])
            }.width('100%').padding(16).onClick((): void => { this.toggleGroup(group); })
            if (this.openGroupId === group.id) {
              Column({ space: 10 }) {
                Row({ space: 8 }) {
                  TextInput({ text: this.groupNameDraft, placeholder: '分组名称' }).height(38).layoutWeight(1)
                    .maxLength(32).backgroundColor(this.pal().surface).borderRadius(10)
                    .onChange((value: string): void => { this.groupNameDraft = value; })
                  Button('保存名称').height(36).fontSize(12).backgroundColor(this.accent).fontColor(Color.White)
                    .enabled(this.groupNameDraft.trim().length > 0 && this.groupNameDraft.trim() !== group.name)
                    .onClick((): void => { HostOrganizationStore.getInstance().renameGroup(group.id, this.groupNameDraft); })
                }.width('100%')
                if (this.orgHosts().length === 0) {
                  Text('还没有可加入分组的主机').fontSize(12).fontColor(this.pal().text3).width('100%')
                }
                ForEach(this.orgHosts(), (row: OrgHostRow): void => {
                  Row({ space: 10 }) {
                    Column({ space: 2 }) {
                      Text(row.label).fontSize(14).fontColor(this.pal().text).maxLines(1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                      Text(row.detail).fontSize(11).fontColor(this.pal().text3).maxLines(1)
                    }.alignItems(HorizontalAlign.Start).layoutWeight(1)
                    Checkbox().select(this.inGroup(row.ref, group.id, this.orgRevision)).selectedColor(this.accent)
                      .onChange((on: boolean): void => {
                        HostOrganizationStore.getInstance().assignHost(row.ref, on ? group.id : '',
                          HostOrganizationStore.getInstance().membership(row.ref).tags);
                      })
                  }.width('100%')
                }, (row: OrgHostRow): string => row.ref + ':' + this.orgRevision.toString())
                Button('删除分组').width('100%').height(38).fontSize(13).fontColor(this.pal().danger)
                  .backgroundColor(this.pal().surface).onClick((): void => { this.deleteGroup(group); })
              }.width('100%').padding({ left: 16, right: 16, bottom: 16 })
            }
          }.width('100%')
        }, (group: HostGroupDefinition): string => group.id + ':' + group.name + ':' + this.orgRevision.toString())
        if (this.orgGroups(this.orgRevision).length > 0) {
          Divider().strokeWidth(0.5).color(this.pal().cardBorder).margin({ left: 16, right: 16 })
        }
        Row({ space: 8 }) {
          TextInput({ text: this.newGroupName, placeholder: '新分组名称，例如「生产」' }).height(38).layoutWeight(1)
            .maxLength(32).backgroundColor(this.pal().surface).borderRadius(10)
            .onChange((value: string): void => { this.newGroupName = value; })
            .onSubmit((): void => { this.createGroup(); })
          Button('＋ 新建').height(36).fontSize(12).backgroundColor(this.accent).fontColor(Color.White)
            .enabled(this.newGroupName.trim().length > 0).onClick((): void => { this.createGroup(); })
        }.width('100%').padding(16)
      }.width('100%').backgroundColor(this.pal().card).borderRadius(16)
    }.width('100%')
  }

  // ---------- 工作区与布局 ----------
  private workspaces(_revision: number): Workspace[] { return WorkspaceStore.getInstance().list(); }
  private workspaceHosts(): RemoteHost[] {
    const hosts: RemoteHost[] = HostSyncService.getInstance().getAllHosts()
      .filter((host: RemoteHost): boolean => host.protocol === 'rdp' || host.protocol === 'rustdesk' || host.protocol === 'ssh');
    VncHostService.getInstance().list().forEach((view: VncHostView): void => { hosts.push(projectVncHost(view)); });
    return hosts;
  }
  private createWorkspace(): void {
    const now: number = Date.now();
    const count: number = this.workspaces(this.orgRevision).length;
    const workspace: Workspace = { schemaVersion: 1, id: 'workspace-' + now.toString(36), name: '工作区 ' + (count + 1).toString(),
      color: this.accent, icon: 'desktop', order: count, entries: [], layout: 'split', updatedAt: now };
    if (WorkspaceStore.getInstance().save(workspace)) { this.editingWorkspace = workspace; }
  }
  private renameWorkspace(workspace: Workspace): void {
    const name: string = this.workspaceNameDraft.trim();
    if (name.length === 0) { return; }
    const next: Workspace = { schemaVersion: workspace.schemaVersion, id: workspace.id, name: name.slice(0, 48),
      color: workspace.color, icon: workspace.icon, order: workspace.order, entries: workspace.entries,
      layout: workspace.layout, updatedAt: Date.now() };
    WorkspaceStore.getInstance().save(next);
  }
  private deleteWorkspace(workspace: Workspace): void {
    this.getUIContext().getPromptAction().showDialog({
      title: '删除工作区', message: '删除「' + workspace.name + '」？主机和会话不受影响。',
      buttons: [{ text: '取消', color: this.pal().text2 }, { text: '删除', color: this.pal().danger }]
    }).then((result): void => {
      if (result.index === 1 && WorkspaceStore.getInstance().remove(workspace.id)) { this.openWorkspaceId = ''; }
    }).catch((): void => {});
  }
  private layoutLabel(workspace: Workspace): string {
    const layout: string = workspace.layout ?? 'custom';
    return layout === 'split' ? '左右平分' : layout === 'columns3' ? '三栏' : layout === 'masterDetail' ? '主副' :
      layout === 'grid4' ? '四宫格' : '自定义';
  }

  @Builder private workspaceOptions() {
    Column({ space: 8 }) {
      this.sectionHeader('工作区', '保存常用的一组会话和布局；在主页工作区卡片中一键打开')
      if (this.editingWorkspace !== null) {
        ProWorkspaceEditorPanel({ workspace: this.editingWorkspace as Workspace, hosts: this.workspaceHosts(),
          onClose: (): void => { this.editingWorkspace = null; } })
      } else {
        Column() {
          ForEach(this.workspaces(this.orgRevision), (workspace: Workspace, index: number): void => {
            if (index > 0) { Divider().strokeWidth(0.5).color(this.pal().cardBorder).margin({ left: 16, right: 16 }) }
            Column() {
              Row({ space: 10 }) {
                SymbolGlyph($r('sys.symbol.rectangle_on_rectangle')).fontSize(18).fontColor([this.accent])
                Column({ space: 2 }) {
                  Text(workspace.name).fontSize(15).fontColor(this.pal().text).maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                  Text(workspace.entries.length.toString() + ' 个会话 · ' + this.layoutLabel(workspace))
                    .fontSize(11).fontColor(this.pal().text3)
                }.alignItems(HorizontalAlign.Start).layoutWeight(1)
                SymbolGlyph(this.openWorkspaceId === workspace.id ? $r('sys.symbol.chevron_up') : $r('sys.symbol.chevron_down'))
                  .fontSize(14).fontColor([this.pal().text3])
              }.width('100%').padding(16).onClick((): void => {
                this.openWorkspaceId = this.openWorkspaceId === workspace.id ? '' : workspace.id;
                this.workspaceNameDraft = workspace.name;
              })
              if (this.openWorkspaceId === workspace.id) {
                Column({ space: 10 }) {
                  Row({ space: 8 }) {
                    TextInput({ text: this.workspaceNameDraft, placeholder: '工作区名称' }).height(38).layoutWeight(1)
                      .maxLength(48).backgroundColor(this.pal().surface).borderRadius(10)
                      .onChange((value: string): void => { this.workspaceNameDraft = value; })
                    Button('保存名称').height(36).fontSize(12).backgroundColor(this.accent).fontColor(Color.White)
                      .enabled(this.workspaceNameDraft.trim().length > 0 && this.workspaceNameDraft.trim() !== workspace.name)
                      .onClick((): void => { this.renameWorkspace(workspace); })
                  }.width('100%')
                  Row({ space: 8 }) {
                    Button('编辑会话与布局').height(38).layoutWeight(1).fontSize(13).fontColor(this.accent)
                      .backgroundColor(this.pal().surface).onClick((): void => { this.editingWorkspace = workspace; })
                    Button('删除').height(38).layoutWeight(1).fontSize(13).fontColor(this.pal().danger)
                      .backgroundColor(this.pal().surface).onClick((): void => { this.deleteWorkspace(workspace); })
                  }.width('100%')
                }.width('100%').padding({ left: 16, right: 16, bottom: 16 })
              }
            }.width('100%')
          }, (workspace: Workspace): string => workspace.id + ':' + workspace.name + ':' + this.orgRevision.toString())
          if (this.workspaces(this.orgRevision).length > 0) {
            Divider().strokeWidth(0.5).color(this.pal().cardBorder).margin({ left: 16, right: 16 })
          }
          Button('＋ 新建工作区').width('100%').height(44).fontSize(14).fontColor(this.accent)
            .backgroundColor(Color.Transparent).onClick((): void => { this.createWorkspace(); })
        }.width('100%').backgroundColor(this.pal().card).borderRadius(16)
      }
    }.width('100%')
  }

  build() {
    Scroll() {
    Column({ space: 14 }) {
      if (this.feature(this.revision) !== undefined) {
        Row() {
          Text(this.feature(this.revision)?.title ?? '').fontSize(20).fontWeight(FontWeight.Bold).fontColor(this.pal().text)
            .fontFamily(AppConfig.fontFamily).layoutWeight(1)
          ProBadge()
        }.width('100%')
        Column({ space: 6 }) {
          Row() {
            Text('状态').fontSize(14).fontColor(this.pal().text2).fontFamily(AppConfig.fontFamily).layoutWeight(1)
            Text(this.status(this.revision)?.label ?? '').fontSize(14)
              .fontColor(this.toneColor(this.status(this.revision))).fontFamily(AppConfig.fontFamily)
          }.width('100%')
          Text(this.status(this.revision)?.detail ?? '').fontSize(12).fontColor(this.pal().text3)
            .fontFamily(AppConfig.fontFamily).width('100%')
          Text('适用：' + proFeatureScope(this.feature(this.revision) as ProFeature)).fontSize(12).fontColor(this.pal().text3)
            .fontFamily(AppConfig.fontFamily).width('100%')
          Text(this.feature(this.revision)?.description ?? '').fontSize(13).fontColor(this.pal().text2)
            .fontFamily(AppConfig.fontFamily).lineHeight(19).width('100%').margin({ top: 4 })
        }.width('100%').padding(16).backgroundColor(this.pal().card).borderRadius(16)
        Column() {
          this.switchRow('显示入口', '只控制应用中是否显示此功能入口，不改变购买或权益',
            ProFeatureVisibility.getInstance().isVisible(this.featureId), (on: boolean): void => {
              if (this.contextValue !== null) { ProFeatureVisibility.getInstance().setVisible(this.contextValue, this.featureId, on); }
            })
        }.width('100%').backgroundColor(this.pal().card).borderRadius(16)
        if (this.featureId === PRO_CONTINUATION_FEATURE) { this.continuationOptions() }
        if (this.featureId === HOST_MANAGEMENT_FEATURE) { this.hostManagementOptions() }
        if (this.featureId === WORKSPACES_FEATURE) { this.workspaceOptions() }
      } else {
        Text('此功能已不在目录中').fontSize(14).fontColor(this.pal().text2).fontFamily(AppConfig.fontFamily)
      }
    }.width('100%').padding({ left: 20, right: 20, top: 20, bottom: 28 })
    }.width('100%').scrollBar(BarState.Off).edgeEffect(EdgeEffect.Spring, { alwaysEnabled: false })
  }
}

/** Settings sheet for the Pro marker itself: whether it shows and whether its colors flow. */
@Component
export struct ProBadgeSettingsPanel {
  @StorageProp('currentTheme') theme: string = 'light';
  @StorageProp('accentColor') accent: string = '#007DFF';
  @StorageProp('proBadgeFlow') flow: boolean = true;
  @StorageProp('proBadgeVisible') visible: boolean = true;
  aboutToAppear(): void { ProBadgePreferences.load(getContext(this)); }
  private pal(): Palette { return this.theme === 'light' ? buildLight(this.accent) : buildDark(this.accent); }
  @Builder private switchRow(title: string, detail: string, isOn: boolean, enabled: boolean,
    onChange: (on: boolean) => void) {
    Row({ space: 12 }) {
      Column({ space: 3 }) {
        Text(title).fontSize(15).fontColor(this.pal().text).fontFamily(AppConfig.fontFamily).width('100%')
        Text(detail).fontSize(12).fontColor(this.pal().text3).fontFamily(AppConfig.fontFamily).lineHeight(17).width('100%')
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      Toggle({ type: ToggleType.Switch, isOn }).selectedColor(this.accent).enabled(enabled)
        .accessibilityText(title).onChange(onChange)
    }.width('100%').padding(16).opacity(enabled ? 1 : 0.5)
  }
  build() {
    Column({ space: 14 }) {
      Text('Pro 标识').fontSize(20).fontWeight(FontWeight.Bold).fontColor(this.pal().text)
        .fontFamily(AppConfig.fontFamily).width('100%')
      Row({ space: 12 }) {
        if (this.visible) {
          ProBadge()
          ProBadge({ large: true })
        } else {
          Text('Pro 标识已隐藏').fontSize(13).fontColor(this.pal().text3).fontFamily(AppConfig.fontFamily)
        }
      }.width('100%').height(64).justifyContent(FlexAlign.Center)
      .backgroundColor(this.pal().card).borderRadius(16)
      Column() {
        this.switchRow('显示 Pro 标识', '关闭后应用内的 Pro 标识都不显示；Pro 功能和入口不受影响',
          this.visible, true, (on: boolean): void => { ProBadgePreferences.update(getContext(this), this.flow, on); })
        Divider().strokeWidth(0.5).color(this.pal().cardBorder).margin({ left: 16, right: 16 })
        this.switchRow('幻彩流动', '关闭后保持静态幻彩配色', this.flow, this.visible,
          (on: boolean): void => { ProBadgePreferences.update(getContext(this), on, this.visible); })
      }.width('100%').backgroundColor(this.pal().card).borderRadius(16)
    }.width('100%').padding({ left: 20, right: 20, top: 20, bottom: 28 })
  }
}
