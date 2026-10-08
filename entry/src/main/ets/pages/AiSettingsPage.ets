import { AppUiMetrics } from '../common/AppUiMetrics';
import { AppSettingsActionRow } from '../components/AppSettingsActionRow';
import { AppSettingsSwitchRow } from '../components/AppSettingsSwitchRow';
import { resolveFabAddStyle } from '../services/FabAddStylePolicy';
import { protocolIcon } from '../services/ProtocolIconPolicy';
import { router, promptAction } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { AppConfig, Palette, buildDark, buildLight } from '../common/Theme';
import { ProBadge } from '../components/ProBadge';
import { SettingsSavedBadge } from '../components/SettingsSavedBadge';
import { AppSheetHeader } from '../components/AppSheetHeader';
import { settingsVisualIsModern } from '../services/SettingsVisualStylePolicy';
import { ProFeatureGate } from '../components/ProFeatureGate';
import { AiBackendChoiceCard } from '../components/ai/AiBackendChoiceCard';
import { AiHostEditor } from '../components/ai/AiHostEditor';
import { AiHostInstallPanel } from '../components/ai/AiHostInstallPanel';
import { AiHostService } from '../services/ai/AiHostService';
import { AiBackend, AiHost, AiSettings, AiUiStyle, aiBackendName, aiSettingsMerged, aiUiStyle, defaultAiSettings } from '../services/ai/AiModels';
import { AiAccess, AiAccountLease } from '../services/ai/AiAccess';
import { AiLocalStore } from '../services/ai/AiLocalStore';
import { AiDataTransfer } from '../services/ai/AiDataTransfer';
import { aiErrorText } from '../services/ai/AiWirePolicy';
import { ProAppRuntime } from '../services/pro/ProAppRuntime';

interface AiSettingsRouteParams { section?: string; }

@Component
export struct AiSettingsSurface {
  @StorageProp('hostAddMode') fabAddStyle: string = 'modern';
  @StorageProp('isDesktopDevice') isDesktopDevice: boolean = false;
  @StorageProp('currentBreakpoint') breakpoint: string = 'sm';
  @StorageProp('currentTheme') theme: string = 'light';
  @StorageProp('accentColor') accent: string = '#007DFF';
  @StorageProp('topRectHeight') topInset: number = 0;
  /** 设置 → 个性化 → 全新视觉: the shared sheet header when embedded, icons and plain wording on the rows. */
  @StorageProp('settingsVisualStyle') visualStyle: string = 'modern';
  // When hosted by HostListPage this surface is rendered inside its shared
  // settings bindSheet. Route pages keep using router params as before.
  @Prop @Watch('onRequestedSectionChange') requestedSection: string = '';
  @Prop embedded: boolean = false;
  @Prop viewportHeight: number = 720;
  onClose: () => void = (): void => {};
  @State settings: AiSettings = defaultAiSettings();
  @State section: string = '';
  private savedSettings: AiSettings | null = null;
  private savedSettingsAccount: AiAccountLease | null = null;
  @State settingsReady: boolean = false;
  @State hosts: AiHost[] = [];
  @State error: string = '';
  /** Bumped after each successful save to flash 已保存 in the header. */
  @State savedTick: number = 0;
  @State busy: boolean = false;
  @State showEditor: boolean = false;
  @State editing: AiHost | null = null;
  @State accessText: string = '';
  @State allowed: boolean = false;
  private account: AiAccountLease | null = null;
  private pendingConnect: string = '';
  private pendingAccount: AiAccountLease | null = null;
  private pendingReload: boolean = false;
  private editorAccount: AiAccountLease | null = null;
  private editorGeneration: number = 0;
  private alive: boolean = false;
  private initialized: boolean = false;
  private stop: () => void = (): void => {};
  private stopStore: () => void = (): void => {};
  private pal(): Palette { return this.theme === 'light' ? buildLight(this.accent) : buildDark(this.accent); }
  private normalizedSection(value: string): string {
    return ['hosts', 'display', 'data', 'install'].includes(value) ? value : '';
  }
  private onRequestedSectionChange(): void {
    this.section = this.normalizedSection(this.requestedSection);
  }
  private embeddedSheetMaxHeight(): number {
    return Math.max(320, this.viewportHeight - 48);
  }
  onPageShow(): void {
    if (this.requestedSection !== '') {
      this.section = this.normalizedSection(this.requestedSection);
      return;
    }
    const params = router.getParams() as AiSettingsRouteParams;
    this.section = this.normalizedSection(params?.section ?? '');
  }
  private sectionVisible(section: string): boolean { return this.section === '' || this.section === section; }
  private backendFeature(backend: AiBackend): string { return 'pro.ai.' + backend; }
  private title(): string {
    if (this.section === 'hosts') { return '连接与配对'; }
    if (this.section === 'display') { return '显示与恢复'; }
    if (this.section === 'data') { return '本机数据管理'; }
    if (this.section === 'install') { return '电脑端安装'; }
    return '远程 AI';
  }
  async aboutToAppear(): Promise<void> {
    this.alive = true;
    this.initialized = false;
    if (this.requestedSection !== '') {
      this.section = this.normalizedSection(this.requestedSection);
    }
    this.stop = AiAccess.getInstance().subscribe((): void => {
      const wasAllowed = this.allowed;
      this.allowed = AiAccess.getInstance().proVisible();
      this.accessText = this.allowed ? 'Pro 远程 AI 已开放' : 'Pro 远程 AI 需要有效权益 · 请先完成购买或验证';
      const accountChanged = this.account !== null && !AiAccess.getInstance().current(this.account);
      if (!this.allowed || accountChanged) { this.hosts = []; this.settings = defaultAiSettings();
        this.savedSettings = null; this.savedSettingsAccount = null; this.settingsReady = false; this.showEditor = false; this.editing = null;
        this.account = null; this.pendingConnect = ''; this.pendingAccount = null; this.editorAccount = null; this.editorGeneration++;
        this.scheduleReload();
      } else if (!wasAllowed && this.allowed && this.initialized) {
        this.scheduleReload();
      }
    });
    await this.run(async (): Promise<void> => { await this.load(); });
    this.initialized = true;
    // What another writer saves (the AI 助理 changing 界面风格, another sheet) shows here, and is what this page edits.
    if (this.alive) {
      this.stopStore = AiLocalStore.getInstance().subscribe((): void => { if (this.initialized) { this.scheduleReload(); } });
    }
  }
  aboutToDisappear(): void { this.alive = false; this.initialized = false; this.stop(); this.stopStore(); }
  private scheduleReload(): void {
    if (!this.alive) { return; }
    this.pendingReload = true;
    if (this.initialized && !this.busy) {
      this.pendingReload = false;
      void this.run(async (): Promise<void> => { await this.load(); });
    }
  }
  private async load(): Promise<void> {
    if (!AiAccess.getInstance().proVisible()) {
      this.allowed = false; this.account = null; this.hosts = []; this.settings = defaultAiSettings();
      this.savedSettings = null; this.savedSettingsAccount = null; this.settingsReady = false;
      return;
    }
    this.allowed = true;
    const account = AiAccess.getInstance().capture();
    if (this.savedSettingsAccount === null || !AiAccess.getInstance().current(this.savedSettingsAccount)) {
      this.savedSettings = null; this.savedSettingsAccount = null; this.settingsReady = false;
    }
    this.account = account;
    await AiLocalStore.getInstance().initialize(getContext(this) as common.UIAbilityContext);
    const settings = await AiLocalStore.getInstance().settings(account);
    const hosts = await AiLocalStore.getInstance().hosts(account);
    if (this.alive && AiAccess.getInstance().current(account)) { this.account = account; this.settings = settings; this.savedSettings = JSON.parse(JSON.stringify(settings)) as AiSettings; this.savedSettingsAccount = account;
      this.settingsReady = true; this.hosts = hosts; }
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
    const account = this.account;
    if (!this.allowed || !AiAccess.getInstance().proVisible() || account === null || this.busy || !this.settingsReady || this.savedSettings === null ||
      this.savedSettingsAccount === null || !AiAccess.getInstance().current(this.savedSettingsAccount)) { return; }
    // Only a new default must be usable; a hidden unchanged default must not block other settings.
    if (this.settings.defaultBackend !== this.savedSettings.defaultBackend &&
      !AiAccess.getInstance().executable(this.settings.defaultBackend)) {
      this.settings = JSON.parse(JSON.stringify(this.savedSettings)) as AiSettings;
      this.error = '所选默认 AI 后端已隐藏或暂不可用'; return;
    }
    const previous = JSON.parse(JSON.stringify(this.savedSettings)) as AiSettings;
    const next = JSON.parse(JSON.stringify(this.settings)) as AiSettings;
    void this.run(async (): Promise<void> => {
      try {
        // Only what was changed here, on what is stored now: a setting the AI 助理 changed meanwhile stays.
        const saved: AiSettings = await AiLocalStore.getInstance().updateSettings(account,
          (stored: AiSettings): AiSettings | null => aiSettingsMerged(stored, previous, next));
        if (!this.alive || !AiAccess.getInstance().proVisible() || !AiAccess.getInstance().current(account)) {
          throw new Error('AI_PRO_ACCESS_REQUIRED');
        }
        this.savedSettings = saved; this.savedSettingsAccount = account;
        this.settings = JSON.parse(JSON.stringify(saved)) as AiSettings;
        this.savedTick++;
      } catch (error) {
        if (this.alive && AiAccess.getInstance().proVisible() && AiAccess.getInstance().current(account)) {
          this.settings = JSON.parse(JSON.stringify(previous)) as AiSettings;
        }
        throw error as Error;
      }
    });
  }
  private confirmClearOperations(): void {
    this.getUIContext().getPromptAction().showDialog({
      title: '清理已确认的操作记录？',
      message: '已经确认完成的操作记录会从本机删除；还在等待确认的操作会保留。',
      buttons: [{ text: '取消', color: this.pal().text2 }, { text: '清理', color: this.pal().danger }]
    }).then((result): void => {
      if (result.index !== 1) { return; }
      void this.run(async (): Promise<void> => {
        if (this.account !== null) { await AiLocalStore.getInstance().clearCompletedOperations(this.account); }
        promptAction.showToast({ message: '已清理确认完成的记录，待确认操作已保留' });
      });
    }).catch((): void => {});
  }
  private openEditor(host: AiHost | null): void {
    if (this.busy || !this.allowed) { this.error = '远程 AI 需要有效 Pro 权益'; return; }
    try {
      const account = AiAccess.getInstance().capture();
      if (host !== null && host.owner !== account.owner) { throw new Error('AI_ACCOUNT_CHANGED'); }
      this.editorAccount = account; this.editorGeneration++; this.pendingConnect = '';
      this.editing = host; this.showEditor = true;
    } catch (error) { this.error = aiErrorText((error as Error).message); }
  }
  @Builder private backendChoiceCard(backend: AiBackend, title: string, subtitle: string) {
    AiBackendChoiceCard({ backend: backend, title: title, subtitle: subtitle,
      isSelected: this.settings.defaultBackend === backend,
      onSelect: (): void => { if (!this.busy && this.settingsReady) { this.settings.defaultBackend = backend; this.save(); } } })
      .width('100%').enabled(!this.busy && this.settingsReady)
  }
  @Builder private styleCard(style: AiUiStyle, title: string, detail: string, swatches: string[]) {
    Column({ space: 8 }) {
      Row({ space: 4 }) {
        ForEach(swatches, (color: string): void => {
          Column().width(14).height(14).borderRadius(7).backgroundColor(color)
            .border({ width: 0.5, color: this.pal().cardBorder })
        }, (color: string): string => color)
      }
      Text(title).fontSize(15).fontWeight(FontWeight.Medium).fontFamily(AppConfig.fontFamily).fontColor(this.pal().text)
      Text(detail).fontSize(12).fontFamily(AppConfig.fontFamily).fontColor(this.pal().text3).maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .alignItems(HorizontalAlign.Start).layoutWeight(1).padding(14).borderRadius(16)
    .backgroundColor(this.pal().surface)
    .border({ width: aiUiStyle(this.settings) === style ? 1.5 : 0.5,
      color: aiUiStyle(this.settings) === style ? this.accent : this.pal().cardBorder })
    .enabled(!this.busy && this.settingsReady).focusable(true)
    .accessibilityText(title).accessibilitySelected(aiUiStyle(this.settings) === style)
    .onClick((): void => {
      if (this.busy || !this.settingsReady || aiUiStyle(this.settings) === style) { return; }
      this.settings.uiStyle = style; this.save();
    })
  }
  @Builder private hostActionRow(host: AiHost) {
    AppSettingsActionRow({ icon: protocolIcon('ai'), title: host.label,
      detail: aiBackendName(host.backend) + ' · ' + host.address + ':' + host.port + ' · 编辑与配对',
      isEnabled: !this.busy, onAction: (): void => { this.openEditor(host); } })
  }
  @Builder private editor() {
    AiHostEditor({ host: this.editing, modern: resolveFabAddStyle(this.fabAddStyle, this.isDesktopDevice) === 'modern',
      viewportHeight: this.viewportHeight,
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
  private modern(): boolean { return settingsVisualIsModern(this.visualStyle); }

  build() {
    Column() {
      if (this.embedded && this.modern()) {
        AppSheetHeader({ title: this.title(), subtitle: this.accessText === '' ? 'Pro 远程 AI' : this.accessText,
          showProBadge: true, savedTick: this.savedTick, whiteOnAccent: true, onClose: (): void => { this.onClose(); } })
      } else {
      Row({ space: 12 }) {
        Button() { SymbolGlyph($r('sys.symbol.chevron_left')).fontSize(20).fontColor([this.pal().text]) }
          .width(44).height(44).padding(0).backgroundColor(Color.Transparent)
          .accessibilityText('返回设置').onClick((): void => {
            if (this.embedded) { this.onClose(); } else { router.back(); }
          })
        Column({ space: 3 }) {
          Text(this.title()).fontSize(20).fontWeight(FontWeight.Bold).fontFamily(AppConfig.fontFamily).fontColor(this.pal().text)
          Text(this.accessText === '' ? 'Pro 远程 AI' : this.accessText).fontSize(12).fontFamily(AppConfig.fontFamily).fontColor(this.pal().text3)
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        SettingsSavedBadge({ savedTick: this.savedTick })
        ProBadge()
      }.width('100%').padding({ left: 12, right: 24, top: 8, bottom: 8 })
      }
      // Errors show under the title, where they are seen, instead of after the last section.
      if (this.error !== '') {
        Row({ space: 8 }) {
          SymbolGlyph($r('sys.symbol.exclamationmark_circle')).fontSize(16).fontColor([this.pal().danger])
          Text(this.error).fontSize(13).fontFamily(AppConfig.fontFamily).fontColor(this.pal().danger)
            .layoutWeight(1)
        }.width('100%').padding({ left: 24, right: 24, bottom: 8 })
      }
      if (!this.allowed) {
        Column({ space: 12 }) {
          Text('远程 AI 需要有效 Pro 权益').fontSize(18).fontWeight(FontWeight.Medium)
            .fontFamily(AppConfig.fontFamily).fontColor(this.pal().text).width('100%')
          Text('当前账号处于免费版、退款待确认或权益撤销状态。恢复有效 Pro 权益后，添加、配对、设置和会话控制会重新开放。')
            .fontSize(13).fontFamily(AppConfig.fontFamily).fontColor(this.pal().text2)
            .lineHeight(20).width('100%')
        }.padding(AppUiMetrics.sheetPadding).width('100%').layoutWeight(1)
      } else {
        Scroll() {
          Column({ space: AppUiMetrics.sectionGap }) {
          if (this.sectionVisible('hosts')) {
          this.sectionTitle('默认 AI', '仅影响新主机，已有连接保持原来的 AI。')
          Column({ space: 10 }) {
            ProFeatureGate({ featureId: this.backendFeature('codex'), context: ProAppRuntime.getInstance().context('ai'), content: (): void => {
              this.backendChoiceCard('codex', 'Codex', 'OpenAI Codex · 9443');
            } })
            ProFeatureGate({ featureId: this.backendFeature('dsh'), context: ProAppRuntime.getInstance().context('ai'), content: (): void => {
              this.backendChoiceCard('dsh', 'DSH', 'DeepSeek Harness · 9444');
            } })
            ProFeatureGate({ featureId: this.backendFeature('pi'), context: ProAppRuntime.getInstance().context('ai'), content: (): void => {
              this.backendChoiceCard('pi', 'Pi', 'Pi 编程代理 · 9445');
            } })
          }.width('100%')
          this.sectionTitle('主机与配对', '局域网连接 · RustDesk 中继将在后续版本开放')
          if (this.hosts.length === 0) {
            Text('还没有 AI 主机。添加电脑地址后，扫描电脑控制面板上的二维码完成配对；PC 上可粘贴配对链接。')
              .fontSize(13).fontFamily(AppConfig.fontFamily).fontColor(this.pal().text2).width('100%')
          }
          ForEach(this.hosts, (host: AiHost): void => {
            ProFeatureGate({ featureId: this.backendFeature(host.backend), context: ProAppRuntime.getInstance().context('ai'), content: (): void => {
              this.hostActionRow(host);
            } })
          }, (host: AiHost): string => host.id + ':' + host.revision.toString())
          AppSettingsActionRow({ icon: this.modern() ? $r('sys.symbol.plus_circle_fill') : protocolIcon('ai'), title: '添加主机',
            detail: this.modern() ? '填写电脑地址，再扫描电脑控制面板上的二维码配对' : '沿用当前经典／全新添加偏好',
            isEnabled: !this.busy, onAction: (): void => { this.openEditor(null); } })
          }
          if (this.sectionVisible('display')) {
          this.sectionTitle('界面风格', '远程 AI 会话页的外观；切换后下次打开会话生效。')
          Row({ space: 10 }) {
            this.styleCard('claude', 'Claude 风格', '仿 Claude App · 米白与陶土橙', ['#F5F4EE', '#C96442', '#262624'])
            this.styleCard('codex', 'Codex 风格', '仿 Codex App · 黑白与蓝色', ['#FFFFFF', '#0D0D0D', '#2F2F2F'])
          }.width('100%')
          this.sectionTitle('显示与恢复')
          Column() {
            AppSettingsSwitchRow({ title: '显示工具执行过程', detail: '在会话中查看工具调用与执行记录',
              isOn: this.settings.showExecution, isEnabled: !this.busy && this.settingsReady, onChange: (value: boolean): void => {
                this.settings.showExecution = value; this.save();
              } })
            Divider().strokeWidth(0.5).color(this.pal().divider)
            AppSettingsSwitchRow({ title: '回到前台后恢复查看', detail: '重新校验服务并读取会话；发送时自动取得控制权',
              isOn: this.settings.reconnectOnForeground, isEnabled: !this.busy && this.settingsReady, onChange: (value: boolean): void => {
                this.settings.reconnectOnForeground = value; this.save();
              } })
            Divider().strokeWidth(0.5).color(this.pal().divider)
            Column({ space: 8 }) {
              Text('会话文字大小：' + this.settings.textSize).fontSize(15).fontFamily(AppConfig.fontFamily)
                .fontColor(this.pal().text).width('100%')
              Text('文字预览 · 远程 AI 工作区').fontSize(this.settings.textSize).fontFamily(AppConfig.fontFamily)
                .fontColor(this.pal().text2).width('100%')
              Slider({ value: this.settings.textSize, min: 12, max: 22, step: 1 }).selectedColor(this.accent)
                .enabled(!this.busy && this.settingsReady).accessibilityText('会话文字大小').onChange((value: number, mode: SliderChangeMode): void => {
                  if (this.busy || !this.settingsReady) { return; } this.settings.textSize = value; if (mode === SliderChangeMode.End) { this.save(); }
                })
            }.padding(16).width('100%')
          }.width('100%').backgroundColor(this.pal().card).borderRadius(20).border({ width: 0.5, color: this.pal().cardBorder })
          }
          if (this.sectionVisible('data')) {
          this.sectionTitle('本机数据管理', '配置备份只包含主机地址和显示偏好，不含配对凭据、会话正文或操作内容。')
          AppSettingsActionRow({ icon: this.modern() ? $r('sys.symbol.arrow_up') : undefined, title: '导出 AI 配置', detail: '保存不含配对凭据的配置备份', isEnabled: !this.busy && this.allowed,
            onAction: (): void => {
              void this.run(async (): Promise<void> => { if (await AiDataTransfer.exportConfig()) { promptAction.showToast({ message: 'AI 配置已导出' }); } });
            } })
          AppSettingsActionRow({ icon: this.modern() ? $r('sys.symbol.arrow_down') : undefined, title: '导入 AI 配置', detail: '新增未配对主机，保留已有主机', isEnabled: !this.busy && this.allowed,
            onAction: (): void => {
              void this.run(async (): Promise<void> => {
                const count = await AiDataTransfer.importConfig(); await this.load();
                promptAction.showToast({ message: '已新增 ' + count + ' 个未配对主机' });
              });
            } })
          AppSettingsActionRow({ icon: this.modern() ? $r('sys.symbol.trash') : undefined, title: '清理已确认操作记录', detail: '待确认操作继续保留，避免重复执行', isEnabled: !this.busy && this.allowed,
            onAction: (): void => { this.confirmClearOperations(); } })
          }
          if (this.sectionVisible('install')) {
          this.sectionTitle('电脑端安装', '生成固定版本安装说明，复制后交给电脑端 Agent。')
          AiHostInstallPanel()
          }
          }.padding(AppUiMetrics.sheetPadding).width('100%').constraintSize({ maxWidth: 900 })
        }.layoutWeight(this.embedded ? 0 : 1).width('100%')
          .constraintSize({ maxHeight: this.embedded ? this.embeddedSheetMaxHeight() : 10000 })
          .scrollBar(BarState.Auto).edgeEffect(EdgeEffect.Spring)
      }
    }.height(this.embedded ? 'auto' : '100%').width('100%')
      .padding({ top: this.embedded ? 0 : (this.topInset > 0 ? px2vp(this.topInset) : 0) })
      .safeAreaPadding({ bottom: 16 }).backgroundColor(this.pal().sheetBg)
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

@Entry
@Component
struct AiSettingsPage {
  @State routeSection: string = '';
  private normalizedSection(value: string): string {
    return ['hosts', 'display', 'data', 'install'].includes(value) ? value : '';
  }
  private readRouteSection(): string {
    const params = router.getParams() as AiSettingsRouteParams;
    return this.normalizedSection(params?.section ?? '');
  }
  aboutToAppear(): void {
    this.routeSection = this.readRouteSection();
  }
  onPageShow(): void {
    this.routeSection = this.readRouteSection();
  }
  build() {
    Column() {
      AiSettingsSurface({ requestedSection: this.routeSection })
    }.width('100%').height('100%')
  }
}
