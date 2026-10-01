import { common } from '@kit.AbilityKit';
import { ProSymbolIcon } from './pro/ProSymbolIcon';
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
import { HostOrganizationStore } from '../services/pro/org/HostOrganizationStore';
import { copyWorkspace, Workspace, workspaceLayoutLabel } from '../services/pro/workspace/WorkspacePolicy';
import { createWorkspace } from './pro/workspace/WorkspaceActions';
import { HostOrganizationManager } from './pro/org/HostOrganizationManager';
import { WorkspaceStore } from '../services/pro/workspace/WorkspaceStore';
import { ProWorkspaceEditorPanel } from './ProWorkspaceEditorPanel';

const HOST_MANAGEMENT_FEATURE: string = 'pro.hostManagement';
const WORKSPACES_FEATURE: string = 'pro.workspaces';


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
  private colorTint(color: string): string {
    return /^#[0-9A-Fa-f]{6}$/.test(color) ? '#2E' + color.substring(1) : color;
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
      this.sectionHeader('分组、标签与智能分组', '这里的修改会立即同步到主页分组栏；导入导出与批量操作在主页多选主机后使用')
      HostOrganizationManager()
    }.width('100%')
  }

  // ---------- 工作区与布局 ----------
  private workspaces(_revision: number): Workspace[] { return WorkspaceStore.getInstance().list(); }
  private createWorkspace(): void {
    const workspace: Workspace | null = createWorkspace(this.getUIContext());
    if (workspace !== null) { this.editingWorkspace = workspace; }
  }
  private renameWorkspace(workspace: Workspace): void {
    const name: string = this.workspaceNameDraft.trim();
    if (name.length === 0) { return; }
    const next: Workspace = copyWorkspace(workspace);
    next.name = name.slice(0, 48);
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
  private layoutLabel(workspace: Workspace): string { return workspaceLayoutLabel(workspace.layout); }

  @Builder private workspaceOptions() {
    Column({ space: 8 }) {
      this.sectionHeader('工作区', '保存常用的一组会话和布局；在主页工作区卡片中一键依次打开，PC 上按布局摆放窗口')
      if (this.editingWorkspace !== null) {
        ProWorkspaceEditorPanel({ workspace: this.editingWorkspace as Workspace,
          onClose: (): void => { this.editingWorkspace = null; } })
      } else {
        Column() {
          ForEach(this.workspaces(this.orgRevision), (workspace: Workspace, index: number): void => {
            if (index > 0) { Divider().strokeWidth(0.5).color(this.pal().cardBorder).margin({ left: 16, right: 16 }) }
            Column() {
              Row({ space: 10 }) {
                Column() { ProSymbolIcon({ icon: workspace.icon, glyphSize: 18, color: workspace.color }) }.width(30).height(30).justifyContent(FlexAlign.Center).borderRadius(9)
                  .backgroundColor(this.colorTint(workspace.color))
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
