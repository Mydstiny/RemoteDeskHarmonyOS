import { common } from '@kit.AbilityKit';
import { AppConfig, Palette, buildDark, buildLight } from '../../common/Theme';
import { AppUiMetrics } from '../../common/AppUiMetrics';
import { DiagnosticAiProviderProfile, DiagnosticAiResult, DiagnosticAiSettingProposal } from '../../services/diagnosticAi/DiagnosticAiModels';
import { DiagnosticModuleId } from '../../services/DiagnosticCapturePolicy';
import { diagnosticAiModulesForQuestion, diagnosticAiCaptureStatus } from '../../services/diagnosticAi/DiagnosticAiBundlePolicy';
import { DiagnosticAiCaptureOrchestrator } from '../../services/diagnosticAi/DiagnosticAiCaptureOrchestrator';
import { DiagnosticAiProfileStore } from '../../services/diagnosticAi/DiagnosticAiProfileStore';
import { DiagnosticAiProviderService } from '../../services/diagnosticAi/DiagnosticAiProviderService';
import { diagnosticAiMailDraft } from '../../services/diagnosticAi/DiagnosticAiMailPolicy';
import { diagnosticAiApplyProposal, diagnosticAiSettingActionText } from '../../services/diagnosticAi/DiagnosticAiSettingsActionPolicy';
import { ProAppRuntime } from '../../services/pro/ProAppRuntime';
import { ProEntries } from '../../services/pro/ProEntries';
import { PRO_DIAGNOSTICS_ASSISTANT_FEATURE } from '../../services/pro/ProFeatureCatalog';
import { AccountSessionCoordinator } from '../../services/AccountSessionCoordinator';

@Component
export struct DiagnosticAiAssistantPanel {
  @StorageProp('currentTheme') theme: string = 'light';
  @StorageProp('accentColor') accent: string = '#007DFF';
  @StorageProp('breakpoint') breakpoint: string = 'md';
  onClose: () => void = (): void => {};
  onCaptureStateChanged: (capturing: boolean) => void = (_capturing: boolean): void => {};
  onOpenMailDraft: (subject: string, body: string) => void = (_subject: string, _body: string): void => {};
  @State question: string = '';
  @State status: string = '';
  @State busy: boolean = false;
  @State result: DiagnosticAiResult | null = null;
  @State modules: DiagnosticModuleId[] = [];
  @State eventCount: number = 0;
  @State elapsed: number = 0;
  @State private latestBundleText: string = '';
  @State private mailPreviewVisible: boolean = false;
  @State private mailSubject: string = '';
  @State private mailBody: string = '';
  private readonly capture: DiagnosticAiCaptureOrchestrator = DiagnosticAiCaptureOrchestrator.getInstance();
  private readonly provider: DiagnosticAiProviderService = new DiagnosticAiProviderService();
  private store: DiagnosticAiProfileStore = new DiagnosticAiProfileStore();
  private owner: string = 'device-local';
  private timer: number = -1;
  private lifecycleGeneration: number = 0;
  private captureOwnedByPanel: boolean = false;

  private pal(): Palette { return this.theme === 'light' ? buildLight(this.accent) : buildDark(this.accent); }

  aboutToAppear(): void {
    this.lifecycleGeneration++;
    const scope = AccountSessionCoordinator.getInstance().currentScope();
    this.owner = scope.ownerScopeId.trim() === '' ? 'device-local' : scope.ownerScopeId;
    this.store.init(getContext(this) as common.UIAbilityContext, this.owner);
    this.timer = setInterval((): void => { this.syncCapture(); }, 500);
  }

  aboutToDisappear(): void {
    this.lifecycleGeneration++;
    if (this.timer >= 0) { clearInterval(this.timer); this.timer = -1; }
    if (this.captureOwnedByPanel) {
      this.capture.cancel(this.owner);
      this.captureOwnedByPanel = false;
      this.onCaptureStateChanged(false);
    }
  }

  private allowed(): boolean {
    return ProEntries.visible(PRO_DIAGNOSTICS_ASSISTANT_FEATURE, ProAppRuntime.getInstance().context());
  }

  private syncCapture(): void {
    const snapshot = this.capture.status(); this.status = snapshot.phase + ' · ' + snapshot.eventCount.toString() + ' 条事件 · ' + snapshot.approximateBytes.toString() + ' bytes';
    this.eventCount = snapshot.eventCount; this.elapsed = snapshot.durationMinutes * 60 - snapshot.remainingSeconds;
  }

  private beginCapture(): void {
    if (!this.allowed() || this.busy || this.question.trim() === '') { return; }
    this.modules = diagnosticAiModulesForQuestion(this.question);
    const result = this.capture.start(this.owner, { modules: this.modules, durationMinutes: 3, consentId: 'consent-' + Date.now().toString() });
    this.syncCapture();
    if (result === 'ok') {
      this.captureOwnedByPanel = true;
      this.onCaptureStateChanged(true);
      this.status = '正在抓取脱敏诊断事件…';
    } else {
      this.status = '无法开始抓取：' + result;
    }
  }

  private async finishCapture(): Promise<void> {
    if (this.busy) { return; }
    const requestGeneration: number = this.lifecycleGeneration;
    const requestOwner: string = this.owner;
    this.busy = true; const stopCode = this.capture.stop(requestOwner); this.captureOwnedByPanel = false;
    this.onCaptureStateChanged(false); this.syncCapture();
    if (stopCode !== 'ok' && stopCode !== 'not_active') {
      this.status = '无法结束抓取：' + stopCode; this.busy = false; return;
    }
    const bundle = this.capture.bundle(requestOwner);
    if (bundle === null) {
      this.capture.cancel(requestOwner);
      this.status = '没有可分析的诊断事件'; this.busy = false; return;
    }
    this.latestBundleText = bundle.text;
    this.capture.discard(requestOwner, bundle.captureId);
    const profiles = this.store.list();
    const settings = this.store.settingsSnapshot();
    const selected = profiles.find((value: DiagnosticAiProviderProfile): boolean =>
      value.providerId === settings.selectedProviderId && value.modelId === settings.selectedModelId && value.modelId !== '') ??
      profiles.find((value: DiagnosticAiProviderProfile): boolean => value.modelId !== '');
    if (selected === undefined) { this.status = '请先在辅助 AI 配置中保存 Provider 和模型'; this.busy = false; return; }
    const selectedRevision: number = selected.revision;
    try {
      const secret = this.store.secret(selected);
      const analyzed: DiagnosticAiResult = await this.provider.analyze(selected, secret, {
        question: this.question, bundle: bundle.text, knowledge: 'RemoteDesktop 使用、隐私和数据安全文档 v1'
      });
      const currentScope = AccountSessionCoordinator.getInstance().currentScope();
      const currentOwner: string = currentScope.ownerScopeId.trim() === '' ? 'device-local' : currentScope.ownerScopeId;
      const latestProfile = this.store.list().find((value: DiagnosticAiProviderProfile): boolean => value.id === selected.id);
      if (requestGeneration !== this.lifecycleGeneration || currentOwner !== requestOwner || !this.allowed() ||
        latestProfile === undefined || latestProfile.revision !== selectedRevision) {
        this.status = '页面或账号作用域已变化，已丢弃旧诊断结果';
        return;
      }
      this.result = analyzed;
      this.status = '分析完成。结果仅供参考，请根据证据和应用提示操作。';
    } catch (error) {
      this.status = error instanceof Error ? error.message : 'AI 分析失败';
    } finally { this.busy = false; }
  }

  build() {
    Column({ space: 12 }) {
      Row({ space: 10 }) {
        Text('启动 AI 辅助').fontSize(20).fontWeight(FontWeight.Bold).fontColor(this.pal().text).fontFamily(AppConfig.fontFamily).layoutWeight(1)
        Button('关闭').height(40).backgroundColor(Color.Transparent).fontColor(this.accent).onClick((): void => { this.onClose(); })
      }.width('100%')
      Text('助手只分析脱敏结构化事件。开始前会显示当前页面/会话范围、模组和时长；抓取时可随时点击“取消”停止，不会自动修改设置或发送邮件。')
        .fontSize(12).lineHeight(18).fontColor(this.pal().text2).width('100%')
      TextInput({ placeholder: '例如：RDP 连接后黑屏，或 RustDesk 中继很慢', text: this.question })
        .height(AppUiMetrics.minTouchTarget).fontSize(15).fontFamily(AppConfig.fontFamily)
        .backgroundColor(this.pal().surface).borderRadius(14).padding(12).enabled(!this.busy)
        .onChange((value: string): void => { this.question = value; })
      if (this.modules.length > 0) {
        Text('建议抓取：' + this.modules.join('、') + ' · 3 分钟').fontSize(12).fontColor(this.pal().text2).width('100%')
      }
      Row({ space: 10 }) {
        Button(this.capture.status().phase === 'capturing' ? '结束并分析' : '开始抓取')
          .height(46).layoutWeight(1).borderRadius(14).backgroundColor(this.accent).fontColor(Color.White)
          .enabled(!this.busy && this.question.trim() !== '')
          .onClick((): void => { if (this.capture.status().phase === 'capturing') { void this.finishCapture(); } else { this.beginCapture(); } })
        Button('取消').height(46).layoutWeight(1).borderRadius(14).backgroundColor(this.pal().surface).fontColor(this.pal().text)
          .enabled(!this.busy && this.capture.status().phase === 'capturing')
          .onClick((): void => { this.capture.cancel(this.owner); this.captureOwnedByPanel = false; this.onCaptureStateChanged(false); this.syncCapture(); })
      }.width('100%')
      Text(this.status).fontSize(12).lineHeight(18).fontColor(this.pal().text2).width('100%')
      if (this.capture.status().phase === 'capturing') {
        Text('事件 ' + this.eventCount.toString() + ' · 已运行 ' + this.elapsed.toString() + ' 秒')
          .fontSize(13).fontColor(this.accent).width('100%')
      }
      if (this.result !== null) {
        Column({ space: 8 }) {
          Text('诊断结果').fontSize(16).fontWeight(FontWeight.Medium).fontColor(this.pal().text).width('100%')
          Text(this.result.summary).fontSize(14).lineHeight(21).fontColor(this.pal().text).width('100%').copyOption(CopyOptions.InApp)
          Text('置信度：' + Math.round(this.result.confidence * 100).toString() + '% · 未知：' + this.result.unknowns.join('；'))
            .fontSize(12).lineHeight(18).fontColor(this.pal().text2).width('100%')
          if (this.result.settingProposals.length > 0) {
            Text('可选设置建议（逐项确认）').fontSize(14).fontWeight(FontWeight.Medium).fontColor(this.pal().text).width('100%')
            ForEach(this.result.settingProposals, (proposal: DiagnosticAiSettingProposal, index: number): void => {
              Row({ space: 8 }) {
                Column({ space: 3 }) {
                  Text(diagnosticAiSettingActionText(proposal.settingId) + '：' + proposal.proposedValue)
                    .fontSize(13).fontColor(this.pal().text).width('100%')
                  Text(proposal.reason).fontSize(11).lineHeight(16).fontColor(this.pal().text2).width('100%')
                }.layoutWeight(1)
                Button('应用').height(36).enabled(proposal.requiresUserConfirmation)
                  .onClick((): void => {
                    const applied: boolean = diagnosticAiApplyProposal(proposal);
                    this.status = applied ? '已应用：' + diagnosticAiSettingActionText(proposal.settingId) : '该建议未通过安全白名单';
                  })
              }.width('100%').padding(8).backgroundColor(this.pal().surface).borderRadius(10)
            }, (_proposal: DiagnosticAiSettingProposal, index: number): string => index.toString())
          }
          Text('邮件发送需要单独预览和确认，当前不会自动发送。').fontSize(12).fontColor(this.pal().text3).width('100%')
          Button('生成邮件草稿').height(40).width('100%').backgroundColor(this.pal().surface).fontColor(this.accent)
            .onClick((): void => {
              const draft = diagnosticAiMailDraft(this.question, this.result as DiagnosticAiResult, {
                captureId: 'latest', schemaVersion: 8, modules: this.modules,
                text: this.latestBundleText, eventCount: this.eventCount, bytes: this.latestBundleText.length
              });
              this.mailSubject = draft.subject; this.mailBody = draft.body; this.mailPreviewVisible = true;
            })
          if (this.mailPreviewVisible) {
            Column({ space: 8 }) {
              Text('邮件二次预览').fontSize(14).fontWeight(FontWeight.Medium).fontColor(this.pal().text).width('100%')
              Text('主题：' + this.mailSubject).fontSize(12).fontColor(this.pal().text2).width('100%')
              Scroll() {
                Text(this.mailBody).fontSize(11).lineHeight(16).fontColor(this.pal().text).width('100%').copyOption(CopyOptions.InApp)
              }.height(150).width('100%').backgroundColor(this.pal().surface).borderRadius(10).padding(8)
              Row({ space: 8 }) {
                Button('打开系统邮件').layoutWeight(1).height(40).backgroundColor(this.accent).fontColor(Color.White)
                  .onClick((): void => { this.onOpenMailDraft(this.mailSubject, this.mailBody); this.mailPreviewVisible = false; })
                Button('取消').layoutWeight(1).height(40).backgroundColor(this.pal().surface).fontColor(this.pal().text)
                  .onClick((): void => { this.mailPreviewVisible = false; })
              }.width('100%')
            }.width('100%').padding(10).backgroundColor(this.pal().surface).borderRadius(12)
          }
        }.width('100%').padding(14).borderRadius(16).backgroundColor(this.pal().card)
      }
    }.width('100%').padding(20).backgroundColor(this.pal().sheetBg)
  }
}
