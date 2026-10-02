import { common, Want } from '@kit.AbilityKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { LengthMetrics } from '@kit.ArkUI';
import { AppConfig, Palette, buildDark, buildLight } from '../../common/Theme';
import { AppSettingsChoiceButton } from '../AppSettingsChoiceButton';
import { AiBackendChoiceCard } from './AiBackendChoiceCard';
import { AiActionButton } from './AiActionButton';
import { AiBackend } from '../../services/ai/AiModels';
import { AiInstallMode, aiInstallRelease, aiInstallPrompt, aiInstallManualUrl } from '../../services/ai/AiHostInstallPolicy';

/** Public help only. All device/service/credential operations stay on the host. */
@Component
export struct AiHostInstallPanel {
  @StorageProp('currentTheme') theme: string = 'light';
  @StorageProp('accentColor') accent: string = '#007DFF';
  @StorageProp('remoteDesktopBgFlag') inBackground: boolean = false;
  @State backend: AiBackend = 'codex';
  @State mode: AiInstallMode = 'local';
  @State preview: string = '';
  @State status: string = '';
  private alive: boolean = false;
  private generation: number = 0;
  private pal(): Palette { return this.theme === 'light' ? buildLight(this.accent) : buildDark(this.accent); }
  aboutToAppear(): void { this.alive = true; this.generation++; }
  aboutToDisappear(): void { this.alive = false; this.generation++; }
  private selectBackend(backend: AiBackend): void {
    if (!this.alive || this.inBackground || this.backend === backend) { return; }
    this.backend = backend; this.preview = ''; this.status = ''; this.generation++;
  }
  private selectMode(mode: AiInstallMode): void {
    if (!this.alive || this.inBackground || this.mode === mode) { return; }
    this.mode = mode; this.preview = ''; this.status = ''; this.generation++;
  }
  private showPreview(): void {
    if (!this.alive || this.inBackground) { return; }
    this.preview = aiInstallPrompt(this.backend, this.mode); this.status = '';
  }
  private copyPreview(): void {
    if (!this.alive || this.inBackground || this.preview === '' ||
      this.preview !== aiInstallPrompt(this.backend, this.mode)) { return; }
    try {
      const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, this.preview);
      const property = data.getProperty();
      property.shareOption = pasteboard.ShareOption.LOCALDEVICE;
      data.setProperty(property);
      pasteboard.getSystemPasteboard().setDataSync(data);
      this.status = '已复制到本机剪贴板，请自行传给电脑端 Agent。';
    } catch (_error) { this.status = '复制失败，可重试或选择预览文字复制。'; }
  }
  private async openManual(): Promise<void> {
    if (!this.alive || this.inBackground) { return; }
    const generation = this.generation;
    const want: Want = { action: 'ohos.want.action.viewData', entities: ['entity.system.browsable'],
      uri: aiInstallManualUrl(this.backend) };
    try {
      const context = getContext(this) as common.UIAbilityContext;
      await context.startAbility(want);
    } catch (_error) {
      if (this.alive && !this.inBackground && generation === this.generation) {
        this.status = '无法打开浏览器，可从安装提示词预览复制固定版本说明链接。';
      }
    }
  }
  build() {
    Column({ space: 12 }) {
      Text('选择电脑端 AI').fontSize(14).fontFamily(AppConfig.fontFamily).fontColor(this.pal().text).width('100%')
      Column({ space: 10 }) {
        AiBackendChoiceCard({ backend: 'codex', title: 'Codex', subtitle: 'OpenAI Codex · 9443', isSelected: this.backend === 'codex',
          onSelect: (): void => { this.selectBackend('codex'); } }).width('100%')
        AiBackendChoiceCard({ backend: 'dsh', title: 'DSH', subtitle: 'DeepSeek Harness · 9444', isSelected: this.backend === 'dsh',
          onSelect: (): void => { this.selectBackend('dsh'); } }).width('100%')
      }.width('100%')
      Text('插件 ' + aiInstallRelease(this.backend).version + ' · ' + aiInstallRelease(this.backend).engine)
        .fontSize(12).fontFamily(AppConfig.fontFamily).fontColor(this.pal().text2).width('100%')
      Text('连接方式').fontSize(14).fontFamily(AppConfig.fontFamily).fontColor(this.pal().text).width('100%')
      Flex({ wrap: FlexWrap.Wrap, space: { main: LengthMetrics.vp(8), cross: LengthMetrics.vp(8) } }) {
        AppSettingsChoiceButton({ label: '仅本机准备', isSelected: this.mode === 'local',
          onSelect: (): void => { this.selectMode('local'); } })
        AppSettingsChoiceButton({ label: '局域网连接', isSelected: this.mode === 'lan',
          onSelect: (): void => { this.selectMode('lan'); } })
      }.width('100%')
      Text(this.mode === 'local' ? '先在电脑上准备并验收，稍后再设置手机连接。' : '电脑端需确认网卡、端口和项目目录，随后回到这里添加主机并配对。')
        .fontSize(13).fontFamily(AppConfig.fontFamily).fontColor(this.pal().text2).width('100%')
      Text('这里只生成安装说明。软件安装、项目权限和后续配对由电脑端确认；设置页默认提供二维码，扫描不可用时可切换链接配对。')
        .fontSize(12).fontFamily(AppConfig.fontFamily).fontColor(this.pal().text2).width('100%')
      AiActionButton({ label: '预览安装提示词', isEnabled: !this.inBackground,
        onAction: (): void => { this.showPreview(); } })
      if (this.preview !== '') {
        Text(this.preview).fontSize(13).fontFamily(AppConfig.fontFamily).fontColor(this.pal().text)
          .copyOption(CopyOptions.LocalDevice).width('100%')
        AiActionButton({ label: '复制给 Agent 的安装提示词', primary: true, isEnabled: !this.inBackground,
          onAction: (): void => { this.copyPreview(); } })
      }
      AiActionButton({ label: '查看手工安装说明', isEnabled: !this.inBackground,
        onAction: (): void => { void this.openManual(); } })
      if (this.status !== '') {
        Text(this.status).fontSize(13).fontFamily(AppConfig.fontFamily).fontColor(this.pal().text2).width('100%')
      }
    }.width('100%').padding(18).backgroundColor(this.pal().card).borderRadius(20)
      .border({ width: 0.5, color: this.pal().cardBorder })
  }
}
