import { common } from '@kit.AbilityKit';
import { Palette, buildDark, buildLight } from '../../common/Theme';
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
  private unsubscribe: () => void = (): void => {};
  private pal(): Palette { return this.theme === 'light' ? buildLight(this.accent) : buildDark(this.accent); }
  aboutToAppear(): void {
    this.alive = true;
    try {
      this.account = AiAccess.getInstance().capture();
      this.draft = this.host === null ? emptyAiHost(this.account.owner, aiRandomId()) :
        JSON.parse(JSON.stringify(this.host)) as AiHost;
      this.groupId = this.draft.groupId; this.label = this.draft.label; this.address = this.draft.address; this.port = this.draft.port.toString();
      this.serverName = this.draft.serverName; this.backend = this.draft.backend;
    } catch (error) { this.error = aiErrorText((error as Error).message); }
    this.unsubscribe = AiAccess.getInstance().subscribe((): void => {
      this.allowed = AiAccess.getInstance().executable(this.backend);
      if (this.account !== null && !AiAccess.getInstance().current(this.account)) { this.invite = ''; }
    });
  }
  aboutToDisappear(): void { this.alive = false; this.invite = ''; this.unsubscribe(); }
  private async save(connect: boolean): Promise<void> {
    if (this.busy || this.draft === null || this.account === null) { return; }
    this.busy = true; this.error = '';
    try {
      AiAccess.getInstance().assertCurrent(this.account);
      const next = JSON.parse(JSON.stringify(this.draft)) as AiHost;
      next.groupId = this.groupId.trim(); next.label = this.label.trim(); next.address = this.address.trim(); next.port = Number(this.port);
      next.serverName = this.serverName.trim(); next.backend = this.backend;
      const invalid = aiHostError(next);
      if (invalid !== '') { this.error = invalid; return; }
      await AiLocalStore.getInstance().initialize(getContext(this) as common.UIAbilityContext);
      AiAccess.getInstance().assertCurrent(this.account);
      if (this.invite.trim() !== '') { await AiBridgeClient.pair(next, this.invite.trim(), 'HarmonyOS'); }
      else { await AiLocalStore.getInstance().saveHost(this.account, next); }
      this.invite = '';
      if (this.alive) { this.onSaved(next.id, connect); }
    } catch (error) { if (this.alive) { this.error = aiErrorText((error as Error).message); } }
    finally { this.busy = false; }
  }
  @Builder private field(title: string, value: string, hint: string, change: (value: string) => void) {
    Column({ space: 6 }) {
      Text(title).fontSize(13).fontColor(this.pal().text2).width('100%')
      TextInput({ text: value, placeholder: hint }).height(44).borderRadius(12)
        .backgroundColor(this.pal().surface).fontColor(this.pal().text).onChange(change)
    }.width('100%').margin({ bottom: 12 })
  }
  build() {
    Column() {
      AppSheetHeader({ title: this.host === null ? '添加远程 AI · Pro' : '编辑远程 AI', onClose: this.onClose })
      Scroll() {
        Column({ space: 12 }) {
          Text(this.modern ? '连接电脑上的 AI 工作区' : '远程 AI 主机信息').fontSize(16)
            .fontWeight(FontWeight.Medium).fontColor(this.pal().text).width('100%')
          Row({ space: 10 }) {
            Button('Codex').layoutWeight(1).backgroundColor(this.backend === 'codex' ? this.accent : this.pal().surface)
              .fontColor(this.backend === 'codex' ? Color.White : this.pal().text)
              .onClick((): void => { this.backend = 'codex'; this.port = '9443'; this.allowed = AiAccess.getInstance().executable(this.backend); })
            Button('DSH').layoutWeight(1).backgroundColor(this.backend === 'dsh' ? this.accent : this.pal().surface)
              .fontColor(this.backend === 'dsh' ? Color.White : this.pal().text)
              .onClick((): void => { this.backend = 'dsh'; this.port = '9444'; this.allowed = AiAccess.getInstance().executable(this.backend); })
          }
          this.field('名称', this.label, '办公室 AI 工作区', (v: string): void => { this.label = v; })
          this.field('分组（可选）', this.groupId, '工作或个人', (v: string): void => { this.groupId = v; })
          this.field('电脑地址', this.address, '局域网 IP 或域名', (v: string): void => { this.address = v; })
          this.field('端口', this.port, '9443', (v: string): void => { this.port = v; })
          this.field('证书服务器名称（可选）', this.serverName, '默认使用电脑地址', (v: string): void => { this.serverName = v; })
          Text('连接方式：局域网直连').fontSize(14).fontColor(this.pal().text).width('100%')
          Text('RustDesk 中继将在后续版本开放').fontSize(12).fontColor(this.pal().text3).width('100%')
          Text('配对邀请').fontSize(14).fontColor(this.pal().text).width('100%')
          TextArea({ text: this.invite, placeholder: '粘贴电脑生成的邀请内容；留空可先保存主机' })
            .height(112).fontSize(12).fontColor(this.pal().text).backgroundColor(this.pal().surface)
            .onChange((v: string): void => { this.invite = v; }).maxLength(70000)
          Text('仅本机保存配对凭据。备份和云同步不包含设备私钥；更换电脑地址后需重新配对。')
            .fontSize(12).fontColor(this.pal().text3).width('100%')
          if (!this.allowed) {
            Text('远程 AI 为 Pro 功能，当前处于实验阶段。可先保存配置，配对与控制以 Pro 功能页开放状态为准。')
              .fontSize(13).fontColor(this.accent).width('100%')
          }
          if (this.error !== '') { Text(this.error).fontSize(13).fontColor(this.pal().danger).width('100%') }
        }.width('100%').padding({ left: 24, right: 24, bottom: 18 })
      }.width('100%').constraintSize({ maxHeight: 500 }).scrollBar(BarState.Auto)
      Row({ space: 10 }) {
        Button('保存').layoutWeight(1).enabled(!this.busy).onClick((): void => { void this.save(false); })
        Button(this.busy ? '处理中…' : '保存并连接').layoutWeight(1).backgroundColor(this.accent)
          .fontColor(Color.White).enabled(!this.busy && this.allowed).onClick((): void => { void this.save(true); })
      }.padding({ left: 24, right: 24, top: 12, bottom: 20 }).width('100%')
    }.width('100%').backgroundColor(this.pal().sheetBg)
  }
}
