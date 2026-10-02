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
  /** Inside the 启动 AI 辅助 sub-setting sheet, which already shows the title and close button. */
  @Prop embedded: boolean = false;
  @State private pulse: boolean = false;
  @State private captureBytes: number = 0;
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
    const snapshot = this.capture.status();
    this.eventCount = snapshot.eventCount; this.elapsed = snapshot.durationMinutes * 60 - snapshot.remainingSeconds;
    this.captureBytes = snapshot.approximateBytes;
    if (snapshot.phase === 'capturing') {
      this.status = '正在抓取脱敏诊断事件，复现问题后点「结束并分析」';
      this.pulse = !this.pulse;
    }
  }

  private capturing(): boolean { return this.capture.status().phase === 'capturing'; }
  private sizeText(): string {
    return this.captureBytes >= 1024 ? (this.captureBytes / 1024).toFixed(1) + ' KB' : this.captureBytes.toString() + ' B';
  }
  private severityText(): string {
    const severity: string = this.result === null ? 'unknown' : this.result.severity;
    if (severity === 'high') { return '高'; }
    if (severity === 'medium') { return '中'; }
    if (severity === 'low') { return '低'; }
    if (severity === 'info') { return '提示'; }
    return '未知';
  }
  private severityColor(): string {
    const severity: string = this.result === null ? 'unknown' : this.result.severity;
    if (severity === 'high') { return '#E5484D'; }
    if (severity === 'medium') { return '#F08C00'; }
    if (severity === 'low') { return '#2BB673'; }
    return this.accent;
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

  @Builder private metric(value: string, label: string) {
    Column({ space: 2 }) {
      Text(value).fontSize(20).fontWeight(FontWeight.Bold).fontColor(this.pal().text).fontFamily(AppConfig.fontFamily)
      Text(label).fontSize(11).fontColor(this.pal().text3)
    }.layoutWeight(1).alignItems(HorizontalAlign.Start)
  }

  @Builder private captureCard() {
    Column({ space: 12 }) {
      Row({ space: 8 }) {
        Circle().width(10).height(10).fill('#E5484D')
          .opacity(this.pulse ? 1 : 0.35).animation({ duration: 480, curve: Curve.EaseInOut })
        Text('抓取中').fontSize(14).fontWeight(FontWeight.Medium).fontColor(this.pal().text).layoutWeight(1)
        Text('最长 3 分钟').fontSize(11).fontColor(this.pal().text3)
      }.width('100%')
      Row() {
        this.metric(this.eventCount.toString(), '事件')
        this.metric(this.elapsed.toString() + ' 秒', '已运行')
        this.metric(this.sizeText(), '数据量')
      }.width('100%')
    }.width('100%').padding(14).borderRadius(16).backgroundColor(this.pal().card)
    .border({ width: 1, color: '#33E5484D' })
  }

  @Builder private resultCard() {
    Column({ space: 10 }) {
      Row({ space: 8 }) {
        Text('诊断结果').fontSize(16).fontWeight(FontWeight.Bold).fontColor(this.pal().text).layoutWeight(1)
        Text('影响 ' + this.severityText()).fontSize(11).fontColor(this.severityColor())
          .padding({ left: 8, right: 8, top: 3, bottom: 3 }).borderRadius(9)
          .backgroundColor('#1A' + this.severityColor().substring(1))
      }.width('100%')
      Text((this.result as DiagnosticAiResult).summary).fontSize(14).lineHeight(21).fontColor(this.pal().text)
        .width('100%').copyOption(CopyOptions.InApp)
      Column({ space: 4 }) {
        Row() {
          Text('置信度').fontSize(11).fontColor(this.pal().text3).layoutWeight(1)
          Text(Math.round((this.result as DiagnosticAiResult).confidence * 100).toString() + '%').fontSize(11)
            .fontColor(this.pal().text2)
        }.width('100%')
        Progress({ value: Math.round((this.result as DiagnosticAiResult).confidence * 100), total: 100,
          type: ProgressType.Linear }).width('100%').color(this.accent).style({ strokeWidth: 5 })
      }.width('100%')
      if ((this.result as DiagnosticAiResult).unknowns.length > 0) {
        Text('尚不确定：' + (this.result as DiagnosticAiResult).unknowns.join('；')).fontSize(12).lineHeight(18)
          .fontColor(this.pal().text2).width('100%')
      }
      if ((this.result as DiagnosticAiResult).settingProposals.length > 0) {
        Text('可选设置建议 · 逐项确认后才会应用').fontSize(13).fontWeight(FontWeight.Medium)
          .fontColor(this.pal().text).width('100%').margin({ top: 4 })
        ForEach((this.result as DiagnosticAiResult).settingProposals, (proposal: DiagnosticAiSettingProposal): void => {
          Row({ space: 10 }) {
            Column({ space: 3 }) {
              Text(diagnosticAiSettingActionText(proposal.settingId) + ' → ' + proposal.proposedValue)
                .fontSize(13).fontWeight(FontWeight.Medium).fontColor(this.pal().text).width('100%')
              Text(proposal.reason).fontSize(11).lineHeight(16).fontColor(this.pal().text2).width('100%')
            }.layoutWeight(1)
            Button('应用').height(34).fontSize(13).padding({ left: 14, right: 14 }).borderRadius(17)
              .backgroundColor(this.accent).fontColor(Color.White).enabled(proposal.requiresUserConfirmation)
              .onClick((): void => {
                const applied: boolean = diagnosticAiApplyProposal(proposal);
                this.status = applied ? '已应用：' + diagnosticAiSettingActionText(proposal.settingId) : '该建议未通过安全白名单';
              })
          }.width('100%').padding(10).backgroundColor(this.pal().surface).borderRadius(12)
        }, (_proposal: DiagnosticAiSettingProposal, index: number): string => index.toString())
      }
      Divider().color(this.pal().divider).margin({ top: 2, bottom: 2 })
      Row({ space: 8 }) {
        SymbolGlyph($r('sys.symbol.envelope_fill')).fontSize(16).fontColor([this.pal().text3])
        Text('需要人工协助时，可生成邮件草稿；发送前会再预览一次，不会自动发送。').fontSize(12).lineHeight(17)
          .fontColor(this.pal().text2).layoutWeight(1)
      }.width('100%')
      Button('生成邮件草稿').height(42).width('100%').borderRadius(21).backgroundColor(this.pal().surface)
        .fontColor(this.accent)
        .onClick((): void => {
          const draft = diagnosticAiMailDraft(this.question, this.result as DiagnosticAiResult, {
            captureId: 'latest', schemaVersion: 8, modules: this.modules,
            text: this.latestBundleText, eventCount: this.eventCount, bytes: this.latestBundleText.length
          });
          this.mailSubject = draft.subject; this.mailBody = draft.body; this.mailPreviewVisible = true;
        })
      if (this.mailPreviewVisible) {
        Column({ space: 8 }) {
          Text('邮件预览').fontSize(14).fontWeight(FontWeight.Medium).fontColor(this.pal().text).width('100%')
          Text('主题：' + this.mailSubject).fontSize(12).fontColor(this.pal().text2).width('100%')
          Scroll() {
            Text(this.mailBody).fontSize(11).lineHeight(16).fontColor(this.pal().text).width('100%')
              .copyOption(CopyOptions.InApp)
          }.height(150).width('100%').backgroundColor(this.pal().card).borderRadius(10).padding(8)
          Row({ space: 8 }) {
            Button('取消').layoutWeight(1).height(40).borderRadius(20).backgroundColor(this.pal().card)
              .fontColor(this.pal().text).onClick((): void => { this.mailPreviewVisible = false; })
            Button('打开系统邮件').layoutWeight(1).height(40).borderRadius(20).backgroundColor(this.accent)
              .fontColor(Color.White)
              .onClick((): void => { this.onOpenMailDraft(this.mailSubject, this.mailBody); this.mailPreviewVisible = false; })
          }.width('100%')
        }.width('100%').padding(12).backgroundColor(this.pal().surface).borderRadius(14)
      }
    }.width('100%').padding(16).borderRadius(18).backgroundColor(this.pal().card)
    .border({ width: 0.5, color: this.pal().cardBorder })
  }

  build() {
    Column() {
      if (!this.embedded) {
        Row({ space: 10 }) {
          Text('启动 AI 辅助').fontSize(20).fontWeight(FontWeight.Bold).fontColor(this.pal().text)
            .fontFamily(AppConfig.fontFamily).layoutWeight(1)
          SymbolGlyph($r('sys.symbol.xmark')).fontSize(18).fontColor([this.pal().text2]).padding(8)
            .onClick((): void => { this.onClose(); })
        }.width('100%').margin({ bottom: 12 })
      }
      Scroll() {
        Column({ space: 12 }) {
          Row({ space: 10 }) {
            SymbolGlyph($r('sys.symbol.checkmark_shield')).fontSize(18).fontColor(['#2BB673'])
            Text('只分析脱敏后的结构化事件。抓取可随时取消；不会自动修改设置，也不会自动发送邮件。')
              .fontSize(12).lineHeight(18).fontColor(this.pal().text2).layoutWeight(1)
          }.width('100%').padding(12).borderRadius(14).backgroundColor('#142BB673').alignItems(VerticalAlign.Top)
          Column({ space: 8 }) {
            Text('遇到了什么问题？').fontSize(14).fontWeight(FontWeight.Medium).fontColor(this.pal().text).width('100%')
            TextArea({ placeholder: '例如：RDP 连接后黑屏；RustDesk 走中继很慢', text: this.question })
              .height(96).fontSize(15).fontFamily(AppConfig.fontFamily)
              .backgroundColor(this.pal().surface).borderRadius(14).enabled(!this.busy && !this.capturing())
              .onChange((value: string): void => { this.question = value; })
            if (this.modules.length > 0) {
              Flex({ wrap: FlexWrap.Wrap }) {
                Text('抓取范围').fontSize(11).fontColor(this.pal().text3).margin({ right: 6, bottom: 6, top: 4 })
                ForEach(this.modules, (module: DiagnosticModuleId): void => {
                  Text(module).fontSize(11).fontColor(this.accent).padding({ left: 8, right: 8, top: 3, bottom: 3 })
                    .borderRadius(9).backgroundColor(this.pal().surface).margin({ right: 6, bottom: 6 })
                }, (module: DiagnosticModuleId): string => module)
              }.width('100%')
            }
          }.width('100%').padding(14).borderRadius(18).backgroundColor(this.pal().card)
          .border({ width: 0.5, color: this.pal().cardBorder })
          if (this.capturing()) {
            this.captureCard()
          }
          if (this.status.length > 0 && !this.capturing()) {
            Row({ space: 8 }) {
              SymbolGlyph($r('sys.symbol.info_circle_fill')).fontSize(15).fontColor([this.accent])
              Text(this.status).fontSize(12).lineHeight(17).fontColor(this.pal().text).layoutWeight(1)
            }.width('100%').padding(10).borderRadius(12).backgroundColor(this.pal().surface)
          }
          if (this.result !== null) {
            this.resultCard()
          }
        }.width('100%').padding({ bottom: 12 })
      }.layoutWeight(1).width('100%').scrollBar(BarState.Off).edgeEffect(EdgeEffect.Spring).align(Alignment.Top)
      Row({ space: 10 }) {
        if (this.capturing()) {
          Button('取消').height(48).layoutWeight(1).borderRadius(24).backgroundColor(this.pal().surface)
            .fontColor(this.pal().text).enabled(!this.busy)
            .onClick((): void => { this.capture.cancel(this.owner); this.captureOwnedByPanel = false;
              this.onCaptureStateChanged(false); this.syncCapture(); this.status = '已取消抓取'; })
        }
        Button(this.busy ? '分析中…' : this.capturing() ? '结束并分析' : '开始抓取')
          .height(48).layoutWeight(1).borderRadius(24).fontSize(16).fontWeight(FontWeight.Medium)
          .backgroundColor(this.accent).fontColor(Color.White)
          .enabled(!this.busy && this.question.trim() !== '')
          .onClick((): void => { if (this.capturing()) { void this.finishCapture(); } else { this.beginCapture(); } })
      }.width('100%').margin({ top: 10 })
    }.width('100%').height('100%').padding(this.embedded ? 0 : 20)
    .backgroundColor(this.embedded ? Color.Transparent : this.pal().sheetBg)
  }
}
