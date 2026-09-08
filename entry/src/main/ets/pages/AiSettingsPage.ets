import { router, promptAction } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { Palette, buildDark, buildLight } from '../common/Theme';
import { AppSheetHeader } from '../components/AppSheetHeader';
import { AiHostEditor } from '../components/ai/AiHostEditor';
import { AiHostService } from '../services/ai/AiHostService';
import { AiHost, AiSettings, defaultAiSettings } from '../services/ai/AiModels';
import { AiAccess, AiAccountLease } from '../services/ai/AiAccess';
import { AiLocalStore } from '../services/ai/AiLocalStore';
import { AiDataTransfer } from '../services/ai/AiDataTransfer';
import { aiErrorText } from '../services/ai/AiWirePolicy';

@Entry
@Component
export struct AiSettingsPage {
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
      if (this.account !== null && !AiAccess.getInstance().current(this.account)) { this.hosts = []; this.showEditor = false; this.pendingConnect = ''; this.editorGeneration++;
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
    try {
      const account = AiAccess.getInstance().capture();
      if (host !== null && host.owner !== account.owner) { throw new Error('AI_ACCOUNT_CHANGED'); }
      this.editorAccount = account; this.editorGeneration++; this.pendingConnect = '';
      this.editing = host; this.showEditor = true;
    } catch (error) { this.error = aiErrorText((error as Error).message); }
  }
  @Builder private editor() {
    AiHostEditor({ host: this.editing, modern: true,
      onClose: (): void => { this.showEditor = false; },
      onSaved: (id: string, connect: boolean): void => {
        if (!this.alive || this.editorAccount === null || !AiAccess.getInstance().current(this.editorAccount)) { return; }
        this.pendingConnect = connect ? id : ''; this.pendingAccount = this.editorAccount;
        this.showEditor = false; void this.run(async (): Promise<void> => { await this.load(); });
      }
    })
  }
  build() {
    Column() {
      AppSheetHeader({ title: '远程 AI · Pro', onClose: (): void => { router.back(); } })
      Scroll() {
        Column({ space: 16 }) {
          Text(this.accessText).fontSize(14).fontColor(this.accent).width('100%')
          Column({ space: 12 }) {
            Text('电脑端准备').fontSize(16).fontWeight(FontWeight.Medium).fontColor(this.pal().text).width('100%')
            Text('请在电脑的 Codex 或 DSH 中发送以下内容，完成安装后获取配对邀请：').fontSize(13).fontColor(this.pal().text2)
            Text('请安装官方 RemoteDesk AI 宿主插件（Codex：Mydstiny/remotedesk-codex-plugin；DSH：Mydstiny/remotedesk-dsh-plugin），按照仓库安装说明配置本地授权项目与局域网 TLS 服务，生成此 HarmonyOS 设备的配对邀请。不要把账户密钥或模型凭据发给远程客户端。')
              .fontSize(13).fontColor(this.pal().text).copyOption(CopyOptions.InApp)
            Text('连接和认证独立于模型账号；模型与项目权限在电脑上管理。').fontSize(12).fontColor(this.pal().text3)
          }.padding(18).backgroundColor(this.pal().card).borderRadius(16)
          Column({ space: 12 }) {
            Text('显示与恢复').fontSize(16).fontColor(this.pal().text).width('100%')
            Row() {
              Text('显示工具执行过程').fontSize(14).fontColor(this.pal().text).layoutWeight(1)
              Toggle({ type: ToggleType.Switch, isOn: this.settings.showExecution }).enabled(!this.busy).onChange((value: boolean): void => {
                this.settings.showExecution = value; this.save();
              })
            }
            Row() {
              Text('回到前台后恢复查看').fontSize(14).fontColor(this.pal().text).layoutWeight(1)
              Toggle({ type: ToggleType.Switch, isOn: this.settings.reconnectOnForeground }).enabled(!this.busy).onChange((value: boolean): void => {
                this.settings.reconnectOnForeground = value; this.save();
              })
            }
            Text('文字大小：' + this.settings.textSize).fontSize(14).fontColor(this.pal().text).width('100%')
            Slider({ value: this.settings.textSize, min: 12, max: 22, step: 1 }).enabled(!this.busy).onChange((value: number, mode: SliderChangeMode): void => {
              this.settings.textSize = value; if (mode === SliderChangeMode.End) { this.save(); }
            })
            Text('恢复查看会重新校验服务并读取快照；取得控制权后才能发送新任务。').fontSize(12).fontColor(this.pal().text3)
          }.padding(18).backgroundColor(this.pal().card).borderRadius(16)
          Column({ space: 12 }) {
            Text('主机与配对').fontSize(16).fontColor(this.pal().text).width('100%')
            ForEach(this.hosts, (host: AiHost): void => {
              Row() {
                Column({ space: 4 }) {
                  Text(host.label).fontSize(15).fontColor(this.pal().text).width('100%')
                  Text(host.backend + ' · ' + host.address + ':' + host.port).fontSize(12).fontColor(this.pal().text3).width('100%')
                }.layoutWeight(1)
                Button('编辑与配对').fontSize(12).onClick((): void => { this.openEditor(host); })
              }
            }, (host: AiHost): string => host.id)
            Button('添加主机').width('100%').onClick((): void => { this.openEditor(null); })
            Text('RustDesk 中继：尚未开放。当前使用局域网直连。').fontSize(12).fontColor(this.pal().text3)
          }.padding(18).backgroundColor(this.pal().card).borderRadius(16)
          Column({ space: 12 }) {
            Text('本机数据管理').fontSize(16).fontColor(this.pal().text).width('100%')
            Text('配置备份包含主机地址与显示偏好，不含配对证书、设备私钥、会话正文和操作内容。导入会新增未配对主机，不覆盖已有主机。').fontSize(12).fontColor(this.pal().text3)
            Button('导出 AI 配置').enabled(!this.busy).width('100%').onClick((): void => {
              void this.run(async (): Promise<void> => { if (await AiDataTransfer.exportConfig()) { promptAction.showToast({ message: 'AI 配置已导出' }); } });
            })
            Button('导入 AI 配置').enabled(!this.busy).width('100%').onClick((): void => {
              void this.run(async (): Promise<void> => {
                const count = await AiDataTransfer.importConfig(); await this.load();
                promptAction.showToast({ message: '已新增 ' + count + ' 个未配对主机' });
              });
            })
            Button('清理已确认操作记录').enabled(!this.busy).width('100%').onClick((): void => {
              void this.run(async (): Promise<void> => {
                if (this.account !== null) { await AiLocalStore.getInstance().clearCompletedOperations(this.account); }
                promptAction.showToast({ message: '已清理确认完成的记录，待确认操作已保留' });
              });
            })
          }.padding(18).backgroundColor(this.pal().card).borderRadius(16)
          if (this.error !== '') { Text(this.error).fontSize(13).fontColor(this.pal().danger).width('100%') }
        }.padding(20).width('100%').constraintSize({ maxWidth: 900 })
      }.layoutWeight(1).width('100%')
    }.height('100%').width('100%').padding({ top: this.topInset }).backgroundColor(this.pal().sheetBg)
      .bindSheet($$this.showEditor, this.editor(), { height: SheetSize.LARGE, showClose: false,
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
