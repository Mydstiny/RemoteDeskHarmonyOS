import { AppUiMetrics } from '../common/AppUiMetrics';
import { AppSettingsActionRow } from '../components/AppSettingsActionRow';
import { AppSettingsSwitchRow } from '../components/AppSettingsSwitchRow';
import { resolveFabAddStyle } from '../services/FabAddStylePolicy';
import { protocolIcon } from '../services/ProtocolIconPolicy';
import { router, promptAction } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { AppConfig, Palette, buildDark, buildLight } from '../common/Theme';
import { AppSheetHeader } from '../components/AppSheetHeader';
import { AiHostEditor } from '../components/ai/AiHostEditor';
import { AiHostInstallPanel } from '../components/ai/AiHostInstallPanel';
import { AiHostService } from '../services/ai/AiHostService';
import { AiHost, AiSettings, defaultAiSettings } from '../services/ai/AiModels';
import { AiAccess, AiAccountLease } from '../services/ai/AiAccess';
import { AiLocalStore } from '../services/ai/AiLocalStore';
import { AiDataTransfer } from '../services/ai/AiDataTransfer';
import { aiErrorText } from '../services/ai/AiWirePolicy';

@Entry
@Component
export struct AiSettingsPage {
  @StorageProp('hostAddMode') fabAddStyle: string = 'modern';
  @StorageProp('isDesktopDevice') isDesktopDevice: boolean = false;
  @StorageProp('currentBreakpoint') breakpoint: string = 'sm';
  @StorageProp('currentTheme') theme: string = 'light';
  @StorageProp('accentColor') accent: string = '#007DFF';
  @StorageProp('topRectHeight') topInset: number = 0;
  @State settings: AiSettings = defaultAiSettings();
  @State hosts: AiHost[] = [];
  @State error: string = '';
  @State busy: boolean = false;
  @State showEditor: boolean = false;
  @State editing: AiHost | null = null;
  @State accessText: string = '';
  private account: AiAccountLease | null = null;
  private pendingConnect: string = '';
  private pendingAccount: AiAccountLease | null = null;
  private pendingReload: boolean = false;
  private editorAccount: AiAccountLease | null = null;
  private editorGeneration: number = 0;
  private alive: boolean = false;
  private stop: () => void = (): void => {};
  private pal(): Palette { return this.theme === 'light' ? buildLight(this.accent) : buildDark(this.accent); }
  async aboutToAppear(): Promise<void> {
    this.alive = true;
    this.stop = AiAccess.getInstance().subscribe((): void => {
      this.accessText = AiAccess.getInstance().executable('codex') ? 'Pro 远程 AI 已开放' : 'Pro 实验功能 · 以 Pro 功能页开放状态为准';
      if (this.account !== null && !AiAccess.getInstance().current(this.account)) { this.hosts = []; this.settings = defaultAiSettings(); this.showEditor = false; this.editing = null;
        this.pendingConnect = ''; this.pendingAccount = null; this.editorAccount = null; this.editorGeneration++;
        this.pendingReload = true;
        if (!this.busy) { this.pendingReload = false; void this.run(async (): Promise<void> => { await this.load(); }); } }
    });
    await this.run(async (): Promise<void> => { await this.load(); });
  }
  aboutToDisappear(): void { this.alive = false; this.stop(); }
  private async load(): Promise<void> {
    const account = AiAccess.getInstance().capture();
    this.account = account;
    await AiLocalStore.getInstance().initialize(getContext(this) as common.UIAbilityContext);
    const settings = await AiLocalStore.getInstance().settings(account);
    const hosts = await AiLocalStore.getInstance().hosts(account);
    if (this.alive && AiAccess.getInstance().current(account)) { this.account = account; this.settings = settings; this.hosts = hosts; }
  }
  private async run(work: () => Promise<void>): Promise<void> {
    if (this.busy) { return; } this.busy = true; this.error = '';
    try { await work(); } catch (error) { this.error = aiErrorText((error as Error).message); }
    finally {
      this.busy = false;
      if (this.pendingReload && this.alive) { this.pendingReload = false; void this.run(async (): Promise<void> => { await this.load(); }); }
    }
  }
  private save(): void {
    void this.run(async (): Promise<void> => {
      if (this.account === null) { return; }
      await AiLocalStore.getInstance().saveSettings(this.account, this.settings);
    });
  }
  private openEditor(host: AiHost | null): void {
    if (this.busy) { return; }
    try {
      const account = AiAccess.getInstance().capture();
      if (host !== null && host.owner !== account.owner) { throw new Error('AI_ACCOUNT_CHANGED'); }
      this.editorAccount = account; this.editorGeneration++; this.pendingConnect = '';
      this.editing = host; this.showEditor = true;
    } catch (error) { this.error = aiErrorText((error as Error).message); }
  }
  @Builder private editor() {
    AiHostEditor({ host: this.editing, modern: resolveFabAddStyle(this.fabAddStyle, this.isDesktopDevice) === 'modern',
      onClose: (): void => { this.showEditor = false; },
      onSaved: (id: string, connect: boolean): void => {
        if (!this.alive || this.editorAccount === null || !AiAccess.getInstance().current(this.editorAccount)) { return; }
        this.pendingConnect = connect ? id : ''; this.pendingAccount = this.editorAccount;
        this.showEditor = false; void this.run(async (): Promise<void> => { await this.load(); });
      }
    })
  }
  @Builder private sectionTitle(title: string, detail: string = '') {
    Column({ space: 6 }) {
      Text(title).fontSize(16).fontWeight(FontWeight.Medium).fontFamily(AppConfig.fontFamily).fontColor(this.pal().text).width('100%')
      if (detail !== '') { Text(detail).fontSize(12).fontFamily(AppConfig.fontFamily).fontColor(this.pal().text2).width('100%') }
    }.width('100%').padding({ left: 4, right: 4 })
  }
  build() {
    Column() {
      AppSheetHeader({ title: '远程 AI · Pro', subtitle: this.accessText,
        horizontalPadding: AppUiMetrics.sheetPadding, onClose: (): void => { router.back(); } })
      Scroll() {
        Column({ space: AppUiMetrics.sectionGap }) {
          this.sectionTitle('主机与配对', '局域网直连 · RustDesk 中继将在后续版本开放')
          if (this.hosts.length === 0) {
            Text('还没有 AI 主机。添加电脑地址后，可粘贴电脑生成的邀请完成配对。')
              .fontSize(13).fontFamily(AppConfig.fontFamily).fontColor(this.pal().text2).width('100%')
          }
          ForEach(this.hosts, (host: AiHost): void => {
            AppSettingsActionRow({ icon: protocolIcon('ai'), title: host.label,
              detail: (host.backend === 'codex' ? 'Codex' : 'DSH') + ' · ' + host.address + ':' + host.port + ' · 编辑与配对',
              isEnabled: !this.busy, onAction: (): void => { this.openEditor(host); } })
          }, (host: AiHost): string => host.id)
          AppSettingsActionRow({ icon: protocolIcon('ai'), title: '添加主机', detail: '沿用当前经典／全新添加偏好',
            isEnabled: !this.busy, onAction: (): void => { this.openEditor(null); } })
          this.sectionTitle('显示与恢复')
          Column() {
            AppSettingsSwitchRow({ title: '显示工具执行过程', detail: '在会话中查看工具调用与执行记录',
              isOn: this.settings.showExecution, isEnabled: !this.busy, onChange: (value: boolean): void => {
                this.settings.showExecution = value; this.save();
              } })
            Divider().strokeWidth(0.5).color(this.pal().divider)
            AppSettingsSwitchRow({ title: '回到前台后恢复查看', detail: '重新校验服务并读取会话，控制权仍需手动取得',
              isOn: this.settings.reconnectOnForeground, isEnabled: !this.busy, onChange: (value: boolean): void => {
                this.settings.reconnectOnForeground = value; this.save();
              } })
            Divider().strokeWidth(0.5).color(this.pal().divider)
            Column({ space: 8 }) {
              Text('会话文字大小：' + this.settings.textSize).fontSize(15).fontFamily(AppConfig.fontFamily)
                .fontColor(this.pal().text).width('100%')
              Text('文字预览 · 远程 AI 工作区').fontSize(this.settings.textSize).fontFamily(AppConfig.fontFamily)
                .fontColor(this.pal().text2).width('100%')
              Slider({ value: this.settings.textSize, min: 12, max: 22, step: 1 }).selectedColor(this.accent)
                .enabled(!this.busy).accessibilityText('会话文字大小').onChange((value: number, mode: SliderChangeMode): void => {
                  if (this.busy) { return; } this.settings.textSize = value; if (mode === SliderChangeMode.End) { this.save(); }
                })
            }.padding(16).width('100%')
          }.width('100%').backgroundColor(this.pal().card).borderRadius(20).border({ width: 0.5, color: this.pal().cardBorder })
          this.sectionTitle('本机数据管理', '配置备份只包含主机地址和显示偏好，不含配对凭据、会话正文或操作内容。')
          AppSettingsActionRow({ title: '导出 AI 配置', detail: '保存不含配对凭据的配置备份', isEnabled: !this.busy,
            onAction: (): void => {
              void this.run(async (): Promise<void> => { if (await AiDataTransfer.exportConfig()) { promptAction.showToast({ message: 'AI 配置已导出' }); } });
            } })
          AppSettingsActionRow({ title: '导入 AI 配置', detail: '新增未配对主机，保留已有主机', isEnabled: !this.busy,
            onAction: (): void => {
              void this.run(async (): Promise<void> => {
                const count = await AiDataTransfer.importConfig(); await this.load();
                promptAction.showToast({ message: '已新增 ' + count + ' 个未配对主机' });
              });
            } })
          AppSettingsActionRow({ title: '清理已确认操作记录', detail: '待确认操作继续保留，避免重复执行', isEnabled: !this.busy,
            onAction: (): void => {
              void this.run(async (): Promise<void> => {
                if (this.account !== null) { await AiLocalStore.getInstance().clearCompletedOperations(this.account); }
                promptAction.showToast({ message: '已清理确认完成的记录，待确认操作已保留' });
              });
            } })
          this.sectionTitle('电脑端安装', '生成固定版本安装说明，复制后交给电脑端 Agent。')
          AiHostInstallPanel()
          if (this.error !== '') { Text(this.error).fontSize(13).fontFamily(AppConfig.fontFamily).fontColor(this.pal().danger).width('100%') }
        }.padding(AppUiMetrics.sheetPadding).width('100%').constraintSize({ maxWidth: 900 })
      }.layoutWeight(1).width('100%').scrollBar(BarState.Auto)
    }.height('100%').width('100%').padding({ top: this.topInset }).safeAreaPadding({ bottom: 16 }).backgroundColor(this.pal().sheetBg)
      .bindSheet($$this.showEditor, this.editor(), { height: SheetSize.FIT_CONTENT, showClose: false, dragBar: false,
        preferType: this.breakpoint === 'sm' ? SheetType.BOTTOM : SheetType.CENTER,
        keyboardAvoidMode: SheetKeyboardAvoidMode.TRANSLATE_AND_SCROLL, backgroundColor: this.pal().sheetBg, blurStyle: BlurStyle.NONE,
        onDisappear: (): void => {
          const id = this.pendingConnect, account = this.pendingAccount, generation = this.editorGeneration;
          this.pendingConnect = ''; this.pendingAccount = null;
          if (id !== '' && account !== null) {
            setTimeout((): void => {
              if (this.alive && AppStorage.get<boolean>('remoteDesktopBgFlag') !== true && !this.showEditor && generation === this.editorGeneration && AiAccess.getInstance().current(account)) {
                router.pushUrl({ url: 'pages/RemoteAiWorkspace', params: { hostId: id } });
              }
            }, 100);
          }
        }
      })
  }
}
