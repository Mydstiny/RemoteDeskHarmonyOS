import { common } from '@kit.AbilityKit';
import { AppConfig, Palette, buildDark, buildLight } from '../../common/Theme';
import { AppUiMetrics } from '../../common/AppUiMetrics';
import { AppSettingsChoiceButton } from '../AppSettingsChoiceButton';
import { AiActionButton } from './AiActionButton';
import { AiFormField } from './AiFormField';
import { AppSheetHeader } from '../AppSheetHeader';
import { AiHost, AiBackend, emptyAiHost, aiHostError } from '../../services/ai/AiModels';
import { AiAccess, AiAccountLease } from '../../services/ai/AiAccess';
import { AiLocalStore } from '../../services/ai/AiLocalStore';
import { AiBridgeClient } from '../../services/ai/AiBridgeClient';
import { aiRandomId } from '../../services/ai/AiTransport';
import { aiErrorText } from '../../services/ai/AiWirePolicy';

@Component
export struct AiHostEditor {
  @StorageProp('currentTheme') theme: string = 'light';
  @StorageProp('accentColor') accent: string = '#007DFF';
  @Prop host: AiHost | null = null;
  @Prop modern: boolean = true;
  @Prop canReturnToProtocols: boolean = false;
  onBackToProtocols: () => void = (): void => {};
  @StorageProp('remoteDesktopBgFlag') @Watch('onBackgroundChanged') inBackground: boolean = false;
  @State step: number = 1;
  onClose: () => void = (): void => {};
  onSaved: (id: string, connect: boolean) => void = (_id: string, _connect: boolean): void => {};
  @State label: string = '';
  @State address: string = '';
  @State groupId: string = '';
  @State port: string = '9443';
  @State serverName: string = '';
  @State backend: AiBackend = 'codex';
  @State invite: string = '';
  @State error: string = '';
  @State busy: boolean = false;
  @State allowed: boolean = false;
  private draft: AiHost | null = null;
  private account: AiAccountLease | null = null;
  private alive: boolean = false;
  private editGeneration: number = 0;
  private unsubscribe: () => void = (): void => {};
  private pal(): Palette { return this.theme === 'light' ? buildLight(this.accent) : buildDark(this.accent); }
  aboutToAppear(): void {
    this.alive = true; this.editGeneration++; this.step = 1;
    try {
      this.account = AiAccess.getInstance().capture();
      this.draft = this.host === null ? emptyAiHost(this.account.owner, aiRandomId()) :
        JSON.parse(JSON.stringify(this.host)) as AiHost;
      this.groupId = this.draft.groupId; this.label = this.draft.label; this.address = this.draft.address; this.port = this.draft.port.toString();
      this.serverName = this.draft.serverName; this.backend = this.draft.backend;
    } catch (error) { this.error = aiErrorText((error as Error).message); }
    this.unsubscribe = AiAccess.getInstance().subscribe((): void => {
      this.allowed = AiAccess.getInstance().executable(this.backend);
      if (!this.allowed) { this.editGeneration++; this.invite = ''; }
      if (this.account !== null && !AiAccess.getInstance().current(this.account)) {
        this.editGeneration++; this.invite = ''; this.label = ''; this.address = ''; this.groupId = '';
        this.serverName = ''; this.draft = null; this.error = '账号已变化，请关闭后重新打开';
      }
    });
  }
  aboutToDisappear(): void { this.alive = false; this.editGeneration++; this.invite = ''; this.unsubscribe(); }
  private onBackgroundChanged(): void { if (this.inBackground) { this.editGeneration++; this.invite = ''; } }
  private draftHost(): AiHost | null {
    if (this.draft === null) { return null; }
    const next = JSON.parse(JSON.stringify(this.draft)) as AiHost;
    next.groupId = this.groupId.trim(); next.label = this.label.trim(); next.address = this.address.trim();
    next.port = Number(this.port); next.serverName = this.serverName.trim(); next.backend = this.backend;
    return next;
  }
  private nextStep(): void {
    if (this.busy || this.inBackground) { return; }
    const next = this.draftHost(); if (next === null) { return; }
    this.error = aiHostError(next); if (this.error === '') { this.step = 2; }
  }
  private previousStep(): void {
    if (this.busy) { return; } this.error = '';
    if (this.step === 2) { this.step = 1; }
    else if (this.canReturnToProtocols) { this.invite = ''; this.editGeneration++; this.onBackToProtocols(); }
  }
  private selectBackend(backend: AiBackend): void {
    if (this.busy || this.backend === backend) { return; }
    this.backend = backend; this.port = backend === 'codex' ? '9443' : '9444'; this.invite = '';
    this.allowed = AiAccess.getInstance().executable(backend);
  }
  private async save(connect: boolean): Promise<void> {
    if (this.busy || !this.alive || this.inBackground || this.draft === null || this.account === null) { return; }
    const next = this.draftHost(); if (next === null) { return; }
    const invitation = this.invite.trim(), account = this.account, generation = this.editGeneration;
    this.error = aiHostError(next); if (this.error !== '') { return; }
    this.busy = true;
    try {
      AiAccess.getInstance().assertCurrent(account);
      await AiLocalStore.getInstance().initialize(getContext(this) as common.UIAbilityContext);
      if (!this.alive || this.inBackground || generation !== this.editGeneration) { return; }
      AiAccess.getInstance().assertCurrent(account);
      if (invitation !== '') { await AiBridgeClient.pair(next, invitation, 'HarmonyOS'); }
      else { await AiLocalStore.getInstance().saveHost(account, next); }
      this.invite = '';
      if (this.alive && !this.inBackground && generation === this.editGeneration && AiAccess.getInstance().current(account)) {
        this.onSaved(next.id, connect);
      }
    } catch (error) { if (this.alive && generation === this.editGeneration) { this.error = aiErrorText((error as Error).message); } }
    finally { this.busy = false; }
  }
  @Builder private hostFields() {
    Text('选择电脑端 AI').fontSize(14).fontFamily(AppConfig.fontFamily).fontWeight(FontWeight.Medium)
      .fontColor(this.pal().text).width('100%')
    Row({ space: 10 }) {
      AppSettingsChoiceButton({ label: 'Codex', isSelected: this.backend === 'codex',
        onSelect: (): void => { this.selectBackend('codex'); } }).layoutWeight(1).enabled(!this.busy)
      AppSettingsChoiceButton({ label: 'DSH', isSelected: this.backend === 'dsh',
        onSelect: (): void => { this.selectBackend('dsh'); } }).layoutWeight(1).enabled(!this.busy)
    }.width('100%')
    AiFormField({ title: '名称', value: this.label, hint: '办公室 AI 工作区', limit: 100, isEnabled: !this.busy,
      onChange: (v: string): void => { this.label = v; } })
    AiFormField({ title: '分组（可选）', value: this.groupId, hint: '工作或个人', limit: 100, isEnabled: !this.busy,
      onChange: (v: string): void => { this.groupId = v; } })
    AiFormField({ title: '电脑地址', value: this.address, hint: '局域网 IP 或域名', isEnabled: !this.busy,
      onChange: (v: string): void => { this.address = v; } })
    AiFormField({ title: '端口', value: this.port, hint: this.backend === 'codex' ? '9443' : '9444',
      limit: 5, inputType: InputType.Number, isEnabled: !this.busy, onChange: (v: string): void => { this.port = v; } })
    AiFormField({ title: '证书服务器名称（可选）', value: this.serverName, hint: '默认使用电脑地址', isEnabled: !this.busy,
      onChange: (v: string): void => { this.serverName = v; } })
  }
  @Builder private pairingFields() {
    if (this.modern) {
      Column({ space: 6 }) {
        Text(this.label).fontSize(16).fontWeight(FontWeight.Medium).fontFamily(AppConfig.fontFamily).fontColor(this.pal().text)
        Text((this.backend === 'codex' ? 'Codex' : 'DSH') + ' · ' + this.address + ':' + this.port)
          .fontSize(13).fontFamily(AppConfig.fontFamily).fontColor(this.pal().text2)
      }.width('100%').alignItems(HorizontalAlign.Start).padding(16).borderRadius(16).backgroundColor(this.pal().card)
    }
    Text('配对邀请').fontSize(14).fontFamily(AppConfig.fontFamily).fontWeight(FontWeight.Medium)
      .fontColor(this.pal().text).width('100%')
    TextArea({ text: this.invite, placeholder: '粘贴电脑生成的邀请内容；留空可先保存主机' })
      .constraintSize({ minHeight: 112, maxHeight: 180 }).fontSize(13).fontFamily(AppConfig.fontFamily)
      .fontColor(this.pal().text).backgroundColor(this.pal().surface).borderRadius(12)
      .enabled(!this.busy && this.allowed && !this.inBackground).accessibilityText('配对邀请')
      .onChange((v: string): void => { if (this.alive && !this.inBackground && !this.busy && this.allowed) { this.invite = v; } }).maxLength(70000)
    Text('已配对主机可直接保存并连接。未配对主机请填写邀请，或先保存、稍后配对。')
      .fontSize(12).fontFamily(AppConfig.fontFamily).fontColor(this.pal().text2).width('100%')
    Text('配对凭据仅保存在本机。更换连接地址需要重新配对；配对邀请在退出或进入后台时清除。')
      .fontSize(12).fontFamily(AppConfig.fontFamily).fontColor(this.pal().text2).width('100%')
  }
  @Builder private actions() {
    if (this.modern && this.step === 1) {
      AiActionButton({ label: '下一步：配对与保存', primary: true, isEnabled: !this.busy,
        onAction: (): void => { this.nextStep(); } })
    } else {
      Row({ space: 10 }) {
        AiActionButton({ label: '保存', isEnabled: !this.busy, onAction: (): void => { void this.save(false); } }).layoutWeight(1)
        AiActionButton({ label: this.busy ? '处理中…' : '保存并连接', primary: true, isEnabled: !this.busy && this.allowed,
          onAction: (): void => { void this.save(true); } }).layoutWeight(1)
      }.width('100%')
    }
  }
  build() {
    Column() {
      AppSheetHeader({ title: this.host === null ? '添加远程 AI · Pro' : '编辑远程 AI',
        subtitle: this.modern ? (this.step === 1 ? '第 1 步，共 2 步 · 主机信息' : '第 2 步，共 2 步 · 配对与保存') : '主机信息与配对',
        horizontalPadding: AppUiMetrics.sheetPadding, onClose: this.onClose })
      // An intrinsic form lets the shared FIT_CONTENT sheet own scrolling and IME avoidance.
      Column({ space: AppUiMetrics.sectionGap }) {
        if (this.modern && (this.step === 2 || this.canReturnToProtocols)) {
          AiActionButton({ label: this.step === 2 ? '返回主机信息' : '返回协议选择', isEnabled: !this.busy,
            onAction: (): void => { this.previousStep(); } })
        }
        if (!this.modern || this.step === 1) { this.hostFields() }
        if (!this.modern || this.step === 2) { this.pairingFields() }
        Text('局域网直连 · RustDesk 中继将在后续版本开放')
          .fontSize(12).fontFamily(AppConfig.fontFamily).fontColor(this.pal().text2).width('100%')
        if (!this.allowed) {
          Text('远程 AI 为 Pro 实验功能。可先保存配置，配对与控制以 Pro 功能页开放状态为准。')
            .fontSize(13).fontFamily(AppConfig.fontFamily).fontColor(this.pal().text2).width('100%')
        }
        if (this.error !== '') { Text(this.error).fontSize(13).fontFamily(AppConfig.fontFamily).fontColor(this.pal().danger).width('100%') }
        this.actions()
      }.width('100%').padding({ left: AppUiMetrics.sheetPadding, right: AppUiMetrics.sheetPadding, bottom: 12 })
    }.width('100%').safeAreaPadding({ bottom: 20 }).backgroundColor(this.pal().sheetBg)
  }
}
