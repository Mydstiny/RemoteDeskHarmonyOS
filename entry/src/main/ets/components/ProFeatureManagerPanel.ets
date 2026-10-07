import { common } from '@kit.AbilityKit';
import { AppSheetHeader } from './AppSheetHeader';
import { settingsVisualIsModern } from '../services/SettingsVisualStylePolicy';
import { appUiOnAccentText } from '../common/AppUiColorPolicy';
import { ProSymbolIcon } from './pro/ProSymbolIcon';
import { AppConfig, Palette, buildDark, buildLight } from '../common/Theme';
import {
  ProBadge, ProBadgePreferences, ProBadgeSettings, ProBadgeStyle, ProBadgeMotion,
  ProBadgeStyleOption, ProBadgeMotionOption, PRO_BADGE_STYLE_OPTIONS,
  PRO_BADGE_MOTION_OPTIONS, proBadgePaletteStops, PRO_BADGE_PRESETS, ProBadgePreset
} from './ProBadge';
import { display } from '@kit.ArkUI';
import { badgePalette, mixHex, PRO_BADGE_PALETTES, ProBadgePalette, validBadgeHex } from '../services/pro/ProBadgeFlowPolicy';

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
import {
  WORKSPACE_PHONE_ENABLED_KEY, workspaceDeviceKind, WorkspaceDeviceKind, WorkspacePhonePreference
} from '../services/pro/workspace/WorkspaceDevicePolicy';
import { HostOrganizationManager } from './pro/org/HostOrganizationManager';
import { WorkspaceStore } from '../services/pro/workspace/WorkspaceStore';
import { ProWorkspaceEditorPanel } from './ProWorkspaceEditorPanel';
import { phonePasskeyEntryAvailable } from '../services/pro/passkey/ProPasskeyEntry';
import { ProAppRuntime } from '../services/pro/ProAppRuntime';
import { DEBUG } from 'BuildProfile';

/** Quick picks for the custom start/end color. */
const PRO_BADGE_CUSTOM_SWATCHES: string[] = [
  '#B9F3EA', '#8DE8FF', '#7FB8FF', '#7B61FF', '#CDC9FF', '#C58BFF', '#FF4FD8', '#FFB3C7',
  '#FF5A5F', '#FF9F43', '#FFD28A', '#F7E7B4', '#B7F7C1', '#5FD4A0', '#00F5D4', '#FFFFFF'
];

const HOST_MANAGEMENT_FEATURE: string = 'pro.hostManagement';
const WORKSPACES_FEATURE: string = 'pro.workspaces';
const PHONE_PASSKEY_FEATURE: string = 'pro.security.phonePasskey';


/** Settings sheet for one Pro feature: live status, scope, display switch and its own options. */
@Component
export struct ProFeatureDetailPanel {
  @StorageProp('currentTheme') theme: string = 'light';
  @StorageProp('accentColor') accent: string = '#007DFF';
  @StorageProp('isDesktopDevice') isDesktopDevice: boolean = false;
  @StorageProp('isPadDevice') isPadDevice: boolean = false;
  @StorageProp(WORKSPACE_PHONE_ENABLED_KEY) workspacePhoneEnabled: boolean = false;
  @Prop featureId: string = '';
  /** The settings sheet shows a close button (Pad and PC sheets have no drag bar) and fits the live window. */
  @Prop showClose: boolean = false;
  @Prop viewportHeight: number = 0;
  onClose: () => void = (): void => {};
  /** Opens 设置 → 安全与数据 → 手机通行密钥 (its page lives there now). */
  onOpenPasskey: () => void = (): void => {};
  /** 设置 → 个性化 → 全新视觉: the shared sheet header when opened from settings. */
  @StorageProp('settingsVisualStyle') visualStyle: string = 'classic';
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
      if (this.contextValue !== null) { WorkspacePhonePreference.load(this.contextValue); }
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
  /** The phone passkey prototype is a Debug experiment for an entitled account; Release never shows it. */
  private phonePasskeyAvailable(_revision: number): boolean { return phonePasskeyEntryAvailable(); }
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
          .fontColor([this.continuation.credentialMode === mode ? appUiOnAccentText(this.accent) : this.accent])
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
          Button('授予').fontSize(13).height(32).backgroundColor(this.accent).fontColor(appUiOnAccentText(this.accent))
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
          Text(detail).fontSize(12).fontColor(settingsVisualIsModern(this.visualStyle) ? this.pal().text2 : this.pal().text3)
            .fontFamily(AppConfig.fontFamily).lineHeight(17).width('100%')
        }
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      Toggle({ type: ToggleType.Switch, isOn }).selectedColor(this.accent).accessibilityText(title).onChange(onChange)
    }.width('100%').padding(16)
  }
  @Builder private sectionHeader(title: string, detail: string) {
    Column({ space: 2 }) {
      Text(title).fontSize(13).fontColor(this.pal().text2).fontFamily(AppConfig.fontFamily).width('100%')
      if (detail.length > 0) {
        Text(detail).fontSize(settingsVisualIsModern(this.visualStyle) ? 12 : 11)
          .fontColor(settingsVisualIsModern(this.visualStyle) ? this.pal().text2 : this.pal().text3)
          .fontFamily(AppConfig.fontFamily).lineHeight(16).width('100%')
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
      if (this.workspaceDevice() === 'phone') {
        Column() {
          this.switchRow('在手机上使用工作区', '受系统限制，手机无法同时显示多个远程会话，工作区只能一个接一个打开',
            this.workspacePhoneEnabled, (on: boolean): void => { this.setPhoneWorkspaces(on); })
        }.width('100%').backgroundColor(this.pal().card).borderRadius(16)
      }
      if (this.workspaceDevice() !== 'phone' || this.workspacePhoneEnabled) {
        this.sectionHeader('工作区', this.workspaceDevice() === 'pc' ?
          '保存常用的一组会话和布局；在主页或侧栏「工作区」中一键打开，并按布局摆放窗口' :
          this.workspaceDevice() === 'tablet' ? '平板上每个工作区最多 2 台主机；在主页工作区卡片中一键打开' :
          '保存常用的一组会话；在主页工作区卡片中按顺序依次打开')
        this.workspaceList()
      }
    }.width('100%')
  }

  private workspaceDevice(): WorkspaceDeviceKind { return workspaceDeviceKind(this.isDesktopDevice, this.isPadDevice); }

  /** Turning workspaces on for a phone asks first, since phones can show only one remote session at a time. */
  private setPhoneWorkspaces(on: boolean): void {
    const context = this.contextValue;
    if (context === null) { return; }
    if (!on) { WorkspacePhonePreference.set(context, false); return; }
    this.getUIContext().getPromptAction().showDialog({
      title: '在手机上使用工作区？',
      message: '受系统限制，手机不能同时显示多个远程会话，也不能自动分屏。打开工作区时会一个接一个连接：每次从会话返回主页后，才会打开下一台。',
      buttons: [{ text: '取消', color: this.pal().text2 }, { text: '仍要开启', color: this.accent }]
    }).then((result): void => {
      WorkspacePhonePreference.set(context, result.index === 1);
    }).catch((): void => { WorkspacePhonePreference.set(context, false); });
  }

  @Builder private workspaceList() {
    Column({ space: 8 }) {
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
                    Button('保存名称').height(36).fontSize(12).backgroundColor(this.accent).fontColor(appUiOnAccentText(this.accent))
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

  private maxPanelHeight(): number {
    if (this.viewportHeight > 0) { return Math.max(320, this.viewportHeight - 48); }
    try {
      const screen: display.Display = display.getDefaultDisplaySync();
      return Math.max(360, Math.round(screen.height / Math.max(1, screen.densityPixels) * 0.82));
    } catch (_error) {
      return 560;
    }
  }

  build() {
    Scroll() {
    Column({ space: 14 }) {
      if (this.feature(this.revision) !== undefined && this.showClose && settingsVisualIsModern(this.visualStyle)) {
        AppSheetHeader({ title: this.feature(this.revision)?.title ?? '', showProBadge: true, horizontalPadding: 0,
          whiteOnAccent: true, onClose: (): void => { this.onClose(); } })
      } else if (this.feature(this.revision) !== undefined) {
        Row() {
          Text(this.feature(this.revision)?.title ?? '').fontSize(20).fontWeight(FontWeight.Bold).fontColor(this.pal().text)
            .fontFamily(AppConfig.fontFamily).layoutWeight(1)
          ProBadge()
          if (this.showClose) {
            SymbolGlyph($r('sys.symbol.xmark')).fontSize(18).fontColor([this.pal().text2])
              .width(36).height(36).margin({ left: 6 }).accessibilityText('关闭')
              .onClick((): void => { this.onClose(); })
          }
        }.width('100%')
      }
      if (this.feature(this.revision) !== undefined) {
        Column({ space: 6 }) {
          Row() {
            Text('状态').fontSize(14).fontColor(this.pal().text2).fontFamily(AppConfig.fontFamily).layoutWeight(1)
            Text(this.status(this.revision)?.label ?? '').fontSize(14)
              .fontColor(this.toneColor(this.status(this.revision))).fontFamily(AppConfig.fontFamily)
          }.width('100%')
          Text(this.status(this.revision)?.detail ?? '').fontSize(12)
            .fontColor(settingsVisualIsModern(this.visualStyle) ? this.pal().text2 : this.pal().text3)
            .fontFamily(AppConfig.fontFamily).width('100%')
          Text('适用：' + proFeatureScope(this.feature(this.revision) as ProFeature)).fontSize(12)
            .fontColor(settingsVisualIsModern(this.visualStyle) ? this.pal().text2 : this.pal().text3)
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
        if (this.featureId === PHONE_PASSKEY_FEATURE && this.phonePasskeyAvailable(this.revision)) {
          // The passkey's own page is under 安全与数据; this only leads there.
          Button('打开手机通行密钥', { type: ButtonType.Capsule }).width('100%').height(44).fontSize(15)
            .fontColor(appUiOnAccentText(this.accent)).backgroundColor(this.accent)
            .onClick((): void => { this.onOpenPasskey(); })
        }
      } else {
        Text('此功能已不在目录中').fontSize(14).fontColor(this.pal().text2).fontFamily(AppConfig.fontFamily)
      }
    }.width('100%').padding({ left: 20, right: 20, top: 20, bottom: 28 })
    }.width('100%').scrollBar(BarState.Off).edgeEffect(EdgeEffect.Spring, { alwaysEnabled: false })
    // Long options (workspaces, phone passkey) scroll instead of running past a small window.
    .constraintSize({ maxHeight: this.maxPanelHeight() })
  }
}

/** Settings sheet for the Pro marker itself: style, motion, visibility and two custom colors. */
@Component
export struct ProBadgeSettingsPanel {
  @StorageProp('currentTheme') theme: string = 'light';
  @StorageProp('accentColor') accent: string = '#007DFF';
  @StorageProp('proBadgeVisible') visible: boolean = true;
  /** The settings sheet shows a close button (Pad and PC sheets have no drag bar) and fits the live window. */
  @Prop showClose: boolean = false;
  @Prop viewportHeight: number = 0;
  onClose: () => void = (): void => {};
  /** 设置 → 个性化 → 全新视觉: the shared sheet header when opened from settings. */
  @StorageProp('settingsVisualStyle') visualStyle: string = 'classic';
  @State badgeStyle: ProBadgeStyle = 'capsule';
  @State badgeMotion: ProBadgeMotion = 'sweep';
  @State palette: string = 'aurora';
  @State colors: string[] = [];
  /** Which custom color the swatches and hex field edit: 0 = 起始色, 1 = 结束色. */
  @State slot: number = 0;
  @State hexDraft: string = '';
  /** The saved look; any change (here, from another window or a preset) re-syncs the sheet. */
  @StorageProp('proBadgeStyle') @Watch('syncFromStorage') storedStyle: string = 'capsule';
  @StorageProp('proBadgeMotion') @Watch('syncFromStorage') storedMotion: string = 'sweep';
  @StorageProp('proBadgePalette') @Watch('syncFromStorage') storedPalette: string = 'aurora';
  @StorageProp('proBadgeColors') @Watch('syncFromStorage') storedColors: string = '';

  aboutToAppear(): void {
    ProBadgePreferences.load(getContext(this));
    this.syncFromStorage();
  }

  /** Mirrors the saved settings into the sheet; unchanged values are skipped so nothing re-renders needlessly. */
  syncFromStorage(): void {
    const settings: ProBadgeSettings = ProBadgePreferences.snapshot();
    if (this.badgeStyle !== settings.style) { this.badgeStyle = settings.style; }
    if (this.badgeMotion !== settings.motion) { this.badgeMotion = settings.motion; }
    if (this.palette !== settings.palette) { this.palette = settings.palette; }
    if (JSON.stringify(this.colors) !== JSON.stringify(settings.colors)) {
      this.colors = settings.colors;
      this.hexDraft = this.slotColor();
    }
    if (this.hexDraft.length === 0) { this.hexDraft = this.slotColor(); }
  }

  private pal(): Palette { return this.theme === 'light' ? buildLight(this.accent) : buildDark(this.accent); }
  private colorsJson(): string { return JSON.stringify(this.colors); }
  private maxPanelHeight(): number {
    if (this.viewportHeight > 0) { return Math.max(320, this.viewportHeight - 48); }
    try {
      const screen: display.Display = display.getDefaultDisplaySync();
      return Math.max(360, Math.round(screen.height / Math.max(1, screen.densityPixels) * 0.82));
    } catch (_error) {
      return 560;
    }
  }
  private save(): void {
    ProBadgePreferences.save(getContext(this), { visible: this.visible, style: this.badgeStyle,
      motion: this.badgeMotion, palette: this.palette, colors: this.colors });
  }
  private pickStyle(style: ProBadgeStyle): void { this.badgeStyle = style; this.save(); }
  /** One tap applies the preset's style, motion and palette together and saves them. */
  private applyPreset(preset: ProBadgePreset): void {
    const palette: ProBadgePalette | null = badgePalette(preset.palette);
    this.badgeStyle = preset.style; this.badgeMotion = preset.motion;
    if (palette !== null) { this.palette = palette.id; this.colors = palette.colors.slice(); }
    this.hexDraft = this.colors[this.slot === 0 ? 0 : 1];
    this.save();
  }
  private presetActive(preset: ProBadgePreset): boolean {
    return this.badgeStyle === preset.style && this.badgeMotion === preset.motion && this.palette === preset.palette;
  }
  private presetColors(preset: ProBadgePreset): string {
    const palette: ProBadgePalette | null = badgePalette(preset.palette);
    return JSON.stringify(palette === null ? this.colors : palette.colors);
  }
  private pickMotion(motion: ProBadgeMotion): void { this.badgeMotion = motion; this.save(); }
  private pickPalette(item: ProBadgePalette): void {
    this.palette = item.id; this.colors = item.colors.slice(); this.hexDraft = this.colors[this.slot === 0 ? 0 : 1];
    this.save();
  }
  /** Custom colors: a start and an end color, blended into a four-color loop. */
  private setCustom(index: number, color: string): void {
    if (!validBadgeHex(color)) { return; }
    const start: string = index === 0 ? color.toUpperCase() : this.colors[0];
    const end: string = index === 1 ? color.toUpperCase() : (this.colors.length > 1 ? this.colors[1] : this.colors[0]);
    this.palette = 'custom';
    this.colors = [start, end, mixHex(end, start, 0.45), mixHex(start, end, 0.45)];
    this.hexDraft = index === 0 ? start : end;
    this.save();
  }
  private slotColor(): string { return this.colors[this.slot === 0 ? 0 : Math.min(1, this.colors.length - 1)] ?? ''; }
  private pickSlot(index: number): void {
    this.slot = index; this.hexDraft = this.colors[index === 0 ? 0 : Math.min(1, this.colors.length - 1)];
  }

  @Builder private stage(dark: boolean) {
    Column({ space: 14 }) {
      if (this.visible) {
        ProBadge({ large: true, previewStyle: this.badgeStyle, previewMotion: this.badgeMotion,
          previewColors: this.colorsJson() })
        ProBadge({ previewStyle: this.badgeStyle, previewMotion: this.badgeMotion, previewColors: this.colorsJson() })
      } else {
        Text('已隐藏').fontSize(12).fontColor(dark ? '#99FFFFFF' : this.pal().text3)
      }
    }
    .layoutWeight(1).height(112).justifyContent(FlexAlign.Center).borderRadius(18)
    .backgroundColor(dark ? '#0E0E12' : this.pal().card)
    .border({ width: 0.5, color: dark ? '#22FFFFFF' : this.pal().cardBorder })
  }

  @Builder private presetCard(preset: ProBadgePreset) {
    Column({ space: 8 }) {
      Column() {
        // Presets preview as still images; the stages above show the live motion.
        ProBadge({ large: true, previewStyle: preset.style, previewMotion: 'static',
          previewColors: this.presetColors(preset) })
      }.width('100%').height(44).justifyContent(FlexAlign.Center).borderRadius(12)
      .backgroundColor(preset.style === 'outline' || preset.style === 'warp' || preset.style === 'carbon' ? '#0E0E12' :
        this.pal().surface)
      Text(preset.label).fontSize(12).fontWeight(FontWeight.Medium).fontColor(this.pal().text)
    }
    .width(108).padding(8).margin({ right: 10 }).borderRadius(16)
    .backgroundColor(this.pal().card)
    .border({ width: this.presetActive(preset) ? 1.5 : 0.5,
      color: this.presetActive(preset) ? this.accent : this.pal().cardBorder })
    .onClick((): void => { this.applyPreset(preset); })
    .accessibilityText('预设 ' + preset.label + (this.presetActive(preset) ? '，使用中' : ''))
  }

  @Builder private styleCard(option: ProBadgeStyleOption) {
    Column({ space: 8 }) {
      Column() {
        ProBadge({ large: true, previewStyle: option.id, previewMotion: 'static', previewColors: this.colorsJson() })
      }.height(34).justifyContent(FlexAlign.Center)
      Text(option.label).fontSize(13).fontWeight(FontWeight.Medium).fontColor(this.pal().text)
      Text(option.detail).fontSize(10).fontColor(this.pal().text3).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width(108).padding({ top: 12, bottom: 10, left: 6, right: 6 }).margin({ right: 8, bottom: 8 })
    .borderRadius(16).backgroundColor(this.badgeStyle === option.id ? this.pal().surface : this.pal().card)
    .border({ width: this.badgeStyle === option.id ? 1.5 : 0.5,
      color: this.badgeStyle === option.id ? this.accent : this.pal().cardBorder })
    .onClick((): void => { this.pickStyle(option.id); })
    .accessibilityText(option.label + (this.badgeStyle === option.id ? '，使用中' : '，选择'))
  }

  @Builder private motionRow(option: ProBadgeMotionOption) {
    Row({ space: 12 }) {
      Column() {
        // Only the chosen motion plays; the others show their still frame to keep the sheet light.
        ProBadge({ previewStyle: this.badgeStyle, previewMotion: this.badgeMotion === option.id ? option.id : 'static',
          previewColors: this.colorsJson() })
      }.width(64).height(32).justifyContent(FlexAlign.Center)
      Column({ space: 2 }) {
        Text(option.label).fontSize(14).fontWeight(FontWeight.Medium).fontColor(this.pal().text)
        Text(option.detail).fontSize(11).fontColor(this.pal().text3)
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      if (this.badgeMotion === option.id) {
        SymbolGlyph($r('sys.symbol.checkmark_circle_fill')).fontSize(18).fontColor([this.accent])
      }
    }.width('100%').padding({ left: 12, right: 14, top: 10, bottom: 10 })
    .onClick((): void => { this.pickMotion(option.id); })
    .accessibilityText(option.label + (this.badgeMotion === option.id ? '，使用中' : '，选择'))
  }

  @Builder private paletteChip(item: ProBadgePalette) {
    Column({ space: 6 }) {
      Row().width(56).height(28).borderRadius(10).linearGradient({ angle: 90, colors: proBadgePaletteStops(item.colors) })
        .border({ width: this.palette === item.id ? 2 : 0.5,
          color: this.palette === item.id ? this.pal().text : this.pal().cardBorder })
      Text(item.label).fontSize(11).fontColor(this.palette === item.id ? this.pal().text : this.pal().text3)
    }.margin({ right: 10, bottom: 10 }).onClick((): void => { this.pickPalette(item); })
  }

  build() {
    Scroll() {
      Column({ space: 14 }) {
        if (this.showClose && settingsVisualIsModern(this.visualStyle)) {
          AppSheetHeader({ title: 'Pro 标识', subtitle: '选择样式、动效和颜色，所有 Pro 入口会统一使用', horizontalPadding: 0,
            whiteOnAccent: true, onClose: (): void => { this.onClose(); } })
        } else {
          Row() {
            Column({ space: 3 }) {
              Text('Pro 标识').fontSize(20).fontWeight(FontWeight.Bold).fontColor(this.pal().text)
                .fontFamily(AppConfig.fontFamily)
              Text('选择样式、动效和颜色，所有 Pro 入口会统一使用').fontSize(12).fontColor(this.pal().text3)
            }.alignItems(HorizontalAlign.Start).layoutWeight(1)
            if (this.showClose) {
              SymbolGlyph($r('sys.symbol.xmark')).fontSize(18).fontColor([this.pal().text2])
                .width(36).height(36).accessibilityText('关闭')
                .onClick((): void => { this.onClose(); })
            }
          }.width('100%').alignItems(VerticalAlign.Top)
        }
        Row({ space: 10 }) {
          this.stage(false)
          this.stage(true)
        }.width('100%')
        Row({ space: 12 }) {
          Column({ space: 3 }) {
            Text('显示 Pro 标识').fontSize(15).fontColor(this.pal().text)
            Text('关闭后只隐藏标记，不影响 Pro 功能或权益').fontSize(12).fontColor(this.pal().text3)
          }.layoutWeight(1).alignItems(HorizontalAlign.Start)
          Toggle({ type: ToggleType.Switch, isOn: this.visible }).selectedColor(this.accent)
            .onChange((on: boolean): void => {
              ProBadgePreferences.save(getContext(this), { visible: on, style: this.badgeStyle,
                motion: this.badgeMotion, palette: this.palette, colors: this.colors });
            })
        }.width('100%').padding(16).backgroundColor(this.pal().card).borderRadius(16)

        Row() {
          Text('一键预设').fontSize(13).fontColor(this.pal().text2).layoutWeight(1)
          Text('点选即可整套应用').fontSize(11).fontColor(this.pal().text3)
        }.width('100%')
        Scroll() {
          Row() {
            ForEach(PRO_BADGE_PRESETS, (preset: ProBadgePreset): void => { this.presetCard(preset) },
              (preset: ProBadgePreset): string => preset.id)
          }
        }.scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off).width('100%').align(Alignment.Start)

        Text('样式').fontSize(13).fontColor(this.pal().text2).width('100%')
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(PRO_BADGE_STYLE_OPTIONS, (option: ProBadgeStyleOption): void => { this.styleCard(option) },
            (option: ProBadgeStyleOption): string => option.id + this.colorsJson())
        }.width('100%')

        Text('动效').fontSize(13).fontColor(this.pal().text2).width('100%')
        Column() {
          ForEach(PRO_BADGE_MOTION_OPTIONS, (option: ProBadgeMotionOption, index: number): void => {
            if (index > 0) { Divider().strokeWidth(0.5).color(this.pal().cardBorder).margin({ left: 88, right: 12 }) }
            this.motionRow(option)
          }, (option: ProBadgeMotionOption): string => option.id)
        }.width('100%').backgroundColor(this.pal().card).borderRadius(16)

        Text('颜色').fontSize(13).fontColor(this.pal().text2).width('100%')
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(PRO_BADGE_PALETTES, (item: ProBadgePalette): void => { this.paletteChip(item) },
            (item: ProBadgePalette): string => item.id)
        }.width('100%')

        Column({ space: 12 }) {
          Row({ space: 8 }) {
            Text('自定义').fontSize(14).fontWeight(FontWeight.Medium).fontColor(this.pal().text).layoutWeight(1)
            if (this.palette === 'custom') {
              Text('使用中').fontSize(11).fontColor(this.accent)
            }
          }.width('100%')
          Row({ space: 8 }) {
            ForEach([0, 1], (index: number): void => {
              Row({ space: 8 }) {
                Column().width(18).height(18).borderRadius(6)
                  .backgroundColor(this.colors[index === 0 ? 0 : Math.min(1, this.colors.length - 1)])
                Text(index === 0 ? '起始色' : '结束色').fontSize(13)
                  .fontColor(this.slot === index ? this.pal().text : this.pal().text2)
              }.layoutWeight(1).height(36).padding({ left: 10, right: 10 }).borderRadius(10)
              .backgroundColor(this.slot === index ? this.pal().surface : Color.Transparent)
              .border({ width: this.slot === index ? 1.2 : 0.5, color: this.slot === index ? this.accent : this.pal().cardBorder })
              .onClick((): void => { this.pickSlot(index); })
            }, (index: number): string => 'slot' + index.toString())
          }.width('100%')
          Flex({ wrap: FlexWrap.Wrap }) {
            ForEach(PRO_BADGE_CUSTOM_SWATCHES, (color: string): void => {
              Column().width(30).height(30).borderRadius(10).backgroundColor(color).margin({ right: 8, bottom: 8 })
                .border({ width: this.hexDraft.toUpperCase() === color ? 2 : 0, color: this.pal().text })
                .onClick((): void => { this.setCustom(this.slot, color); })
            }, (color: string): string => color)
          }.width('100%')
          Row({ space: 8 }) {
            Text('#').fontSize(14).fontColor(this.pal().text3)
            TextInput({ text: this.hexDraft.replace('#', ''), placeholder: 'RRGGBB' }).fontSize(13).height(36)
              .layoutWeight(1).maxLength(6).backgroundColor(this.pal().surface).borderRadius(9)
              .onChange((value: string): void => {
                const hex: string = '#' + value.trim().toUpperCase();
                // The field also reports its initial text; only a real edit switches to a custom palette.
                if (hex === this.slotColor().toUpperCase()) { return; }
                this.hexDraft = hex;
                if (validBadgeHex(hex)) { this.setCustom(this.slot, hex); }
              })
          }.width('100%')
          Text('起始色和结束色会混合成四色循环。颜色只改变 Pro 标识的外观，不影响功能权限。')
            .fontSize(11).fontColor(this.pal().text3).lineHeight(16).width('100%')
        }.width('100%').padding(14).backgroundColor(this.pal().card).borderRadius(16)
      }.width('100%').padding({ left: 20, right: 20, top: 20, bottom: 28 })
    }
    // Fit inside the sheet on every device; a fixed 760 made the bottom unreachable on Pad and PC.
    .width('100%').constraintSize({ maxHeight: this.maxPanelHeight() }).scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: false })
  }
}
