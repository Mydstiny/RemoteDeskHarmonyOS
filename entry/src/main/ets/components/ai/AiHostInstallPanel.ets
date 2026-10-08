import { common, Want } from '@kit.AbilityKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { LengthMetrics } from '@kit.ArkUI';
import { AppConfig, Palette, buildDark, buildLight } from '../../common/Theme';
import { AppSettingsChoiceButton } from '../AppSettingsChoiceButton';
import { AiBackendChoiceCard } from './AiBackendChoiceCard';
import { AiActionButton } from './AiActionButton';
import { AiBackend, AI_BACKENDS, aiBackendName, aiBackendSubtitle } from '../../services/ai/AiModels';
import { AiInstallMode, aiInstallRelease, aiInstallPrompt, aiInstallManualUrl, aiInstallMirrorManualUrl } from '../../services/ai/AiHostInstallPolicy';

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
  /** The manual at the pinned commit: on GitHub, or on the Gitee mirror for networks that cannot reach GitHub. */
  private async openManual(mirror: boolean = false): Promise<void> {
    if (!this.alive || this.inBackground) { return; }
    const generation = this.generation;
    const want: Want = { action: 'ohos.want.action.viewData', entities: ['entity.system.browsable'],
      uri: mirror ? aiInstallMirrorManualUrl(this.backend) : aiInstallManualUrl(this.backend) };
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
        ForEach(AI_BACKENDS, (backend: AiBackend): void => {
          AiBackendChoiceCard({ backend, title: aiBackendName(backend), subtitle: aiBackendSubtitle(backend),
            isSelected: this.backend === backend, onSelect: (): void => { this.selectBackend(backend); } }).width('100%')
        }, (backend: AiBackend): string => backend)
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
      Text(this.mode === 'local' ? '先在电脑上装好并验收，稍后再改为局域网并配对手机。' :
        '电脑端会确认网卡、端口和项目目录，装好后台服务和控制面板；随后回到这里添加主机，扫描控制面板上的二维码配对。')
        .fontSize(13).fontFamily(AppConfig.fontFamily).fontColor(this.pal().text2).width('100%')
      Text('这里只生成安装提示词：复制后发给电脑上的 AI 编程助手（如 Codex、Pi），由它在电脑上完成安装、配置后台服务和控制面板。软件安装、项目权限和配对都需要你在电脑上确认；控制面板默认提供二维码，扫描不可用时可改用链接配对。')
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
      if (aiInstallMirrorManualUrl(this.backend) !== '') {
        AiActionButton({ label: 'GitHub 打不开？在 Gitee 镜像查看', isEnabled: !this.inBackground,
          onAction: (): void => { void this.openManual(true); } })
      }
      if (this.status !== '') {
        Text(this.status).fontSize(13).fontFamily(AppConfig.fontFamily).fontColor(this.pal().text2).width('100%')
      }
    }.width('100%').padding(18).backgroundColor(this.pal().card).borderRadius(20)
      .border({ width: 0.5, color: this.pal().cardBorder })
  }
}
