import { promptAction } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { AppConfig, Palette, buildDark, buildLight } from '../common/Theme';
import {
  DIAGNOSTIC_DEFAULT_DURATION_MINUTES,
  DiagnosticModuleId,
  DiagnosticModuleSpec,
  diagnosticAllModules,
  diagnosticDurationOptions,
  diagnosticModuleSpecs,
  normalizeDiagnosticModules
} from '../services/DiagnosticCapturePolicy';
import {
  DiagnosticCapturePhase,
  DiagnosticCaptureRuntime,
  DiagnosticCaptureStatus
} from '../services/DiagnosticCaptureRuntime';
import {
  DiagnosticCaptureExportService,
  DiagnosticSaveResult
} from '../services/DiagnosticCaptureExportService';

@Component
export struct DiagnosticCaptureSettingsSheet {
  @StorageProp('currentTheme') theme: string = 'light';
  @StorageProp('accentColor') accentColor: string = '#007DFF';
  @StorageProp('breakpoint') breakpoint: string = 'md';
  onClose: () => void = (): void => {};

  @State selectedDurationMinutes: number = DIAGNOSTIC_DEFAULT_DURATION_MINUTES;
  @State selectedModules: DiagnosticModuleId[] = ['core.app'];
  @State phase: DiagnosticCapturePhase = 'idle';
  @State captureId: string = '';
  @State remainingSeconds: number = 0;
  @State eventCount: number = 0;
  @State droppedEventCount: number = 0;
  @State approximateBytes: number = 0;
  @State stopReason: string = '';
  @State message: string = '';
  @State messageIsError: boolean = false;

  private readonly runtime: DiagnosticCaptureRuntime = DiagnosticCaptureRuntime.getInstance();
  private readonly exporter: DiagnosticCaptureExportService =
    DiagnosticCaptureExportService.getInstance();
  private refreshTimer: number = -1;
  private readonly durationOptions: number[] = diagnosticDurationOptions();
  private readonly moduleSpecs: DiagnosticModuleSpec[] = diagnosticModuleSpecs();

  aboutToAppear(): void {
    this.syncStatus(true);
    this.refreshTimer = setInterval((): void => { this.syncStatus(false); }, 500);
  }

  aboutToDisappear(): void {
    if (this.refreshTimer >= 0) {
      clearInterval(this.refreshTimer);
      this.refreshTimer = -1;
    }
  }

  private pal(): Palette {
    return this.theme === 'light' ? buildLight(this.accentColor) : buildDark(this.accentColor);
  }

  private font(): string {
    return AppConfig.fontFamily;
  }

  private syncStatus(loadActiveSelection: boolean): void {
    const status: DiagnosticCaptureStatus = this.runtime.status();
    this.phase = status.phase;
    this.captureId = status.captureId;
    this.remainingSeconds = status.remainingSeconds;
    this.eventCount = status.eventCount;
    this.droppedEventCount = status.droppedEventCount;
    this.approximateBytes = status.approximateBytes;
    this.stopReason = status.stopReason;
    if (loadActiveSelection && status.phase !== 'idle') {
      this.selectedDurationMinutes = status.durationMinutes;
      this.selectedModules = status.selectedModules.slice();
    }
  }

  private optionsLocked(): boolean {
    return this.phase !== 'idle';
  }

  private moduleSelected(moduleId: DiagnosticModuleId): boolean {
    return this.selectedModules.indexOf(moduleId) >= 0;
  }

  private toggleModule(moduleId: DiagnosticModuleId, selected: boolean): void {
    if (this.optionsLocked() || moduleId === 'core.app') { return; }
    const next: string[] = this.selectedModules.slice();
    const index: number = next.indexOf(moduleId);
    if (selected && index < 0) { next.push(moduleId); }
    if (!selected && index >= 0) { next.splice(index, 1); }
    this.selectedModules = normalizeDiagnosticModules(next);
  }

  private toggleAllModules(): void {
    if (this.optionsLocked()) { return; }
    this.selectedModules = this.selectedModules.length === this.moduleSpecs.length ?
      ['core.app'] : diagnosticAllModules();
  }

  private statusTitle(): string {
    if (this.phase === 'capturing') {
      return '抓取中 · 剩余 ' + this.formatRemaining(this.remainingSeconds);
    }
    if (this.phase === 'saving') { return '正在保存日志…'; }
    if (this.phase === 'readyToSave') {
      return this.stopReason === 'deadline' ? '已到时，待保存' : '抓取已结束，待保存';
    }
    return '未开始抓取';
  }

  private statusDetail(): string {
    if (this.phase === 'idle') {
      return '选择模组和最长时长后开始；关闭此页面不会停止抓取。';
    }
    const dropped: string = this.droppedEventCount > 0 ?
      ' · 已丢弃 ' + this.droppedEventCount.toString() + ' 条' : '';
    return this.eventCount.toString() + ' 条事件 · ' +
      this.formatBytes(this.approximateBytes) + dropped;
  }

  private formatRemaining(seconds: number): string {
    const safe: number = Math.max(0, Math.floor(seconds));
    const minutes: number = Math.floor(safe / 60);
    const remain: number = safe % 60;
    return minutes.toString() + ':' + (remain < 10 ? '0' : '') + remain.toString();
  }

  private formatBytes(bytes: number): string {
    if (bytes < 1024) { return bytes.toString() + ' B'; }
    if (bytes < 1024 * 1024) { return (bytes / 1024).toFixed(1) + ' KiB'; }
    return (bytes / (1024 * 1024)).toFixed(1) + ' MiB';
  }

  private startCapture(): void {
    const code = this.runtime.start(this.selectedDurationMinutes, this.selectedModules);
    this.message = code === 'ok' ? '日志抓取已开始，请离开设置复现问题。' :
      code === 'already_active' ? '已有一项抓取正在进行。' :
        code === 'invalid_duration' ? '请选择有效的抓取时长。' : '无法启动日志抓取。';
    this.messageIsError = code !== 'ok';
    this.syncStatus(true);
  }

  private async stopAndSave(): Promise<void> {
    this.message = '';
    this.messageIsError = false;
    if (this.phase === 'capturing') {
      const stopCode = this.runtime.stop();
      if (stopCode !== 'ok') {
        this.message = '无法结束当前抓取，请稍后重试。';
        this.messageIsError = true;
        this.syncStatus(false);
        return;
      }
    }
    this.syncStatus(false);
    const context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    const pending: Promise<DiagnosticSaveResult> =
      this.exporter.save(this.runtime, context);
    this.syncStatus(false);
    const result: DiagnosticSaveResult = await pending;
    if (result.ok) {
      this.message = '日志已保存：' + result.fileName;
      this.messageIsError = false;
    } else if (result.code === 'cancelled') {
      this.message = '已取消保存，抓取内容仍保留，可再次保存。';
      this.messageIsError = false;
    } else {
      this.message = '保存失败（' + result.code + '），抓取内容仍保留。';
      this.messageIsError = true;
    }
    this.syncStatus(false);
  }

  private confirmDiscard(): void {
    if (this.phase === 'idle' || this.phase === 'saving') { return; }
    const expectedCaptureId: string = this.captureId;
    if (expectedCaptureId.length === 0) { return; }
    promptAction.showDialog({
      title: '丢弃本次日志？',
      message: '未保存的抓取内容会从内存中删除，且无法恢复。',
      buttons: [
        { text: '取消', color: this.pal().text2 },
        { text: '丢弃', color: this.pal().danger }
      ]
    }).then((result: Object): void => {
      const dialogResult: Record<string, number> = result as Record<string, number>;
      if (dialogResult['index'] !== 1) { return; }
      const code = this.runtime.discard(expectedCaptureId);
      if (code === 'ok') {
        this.message = '本次抓取已丢弃。';
        this.messageIsError = false;
      } else if (code === 'busy') {
        this.message = '日志正在保存，未丢弃任何内容。';
        this.messageIsError = true;
      } else {
        this.message = '抓取状态已变化，未丢弃任何内容。';
        this.messageIsError = false;
      }
      this.syncStatus(false);
    });
  }

  private primaryButtonText(): string {
    if (this.phase === 'idle') { return '开始抓取'; }
    if (this.phase === 'capturing') { return '结束并保存'; }
    if (this.phase === 'saving') { return '正在保存…'; }
    return '保存日志';
  }

  private primaryAction(): void {
    if (this.phase === 'idle') {
      this.startCapture();
      return;
    }
    if (this.phase === 'saving') { return; }
    void this.stopAndSave();
  }

  build() {
    Column() {
      Row() {
        Row() {
          SymbolGlyph($r('sys.symbol.doc_plaintext'))
            .fontSize(22)
            .fontColor([this.accentColor])
        }
        .width(38).height(38).borderRadius(11)
        .justifyContent(FlexAlign.Center)
        .backgroundColor(this.pal().surface)

        Column() {
          Text('日志').fontSize(20).fontWeight(FontWeight.Bold)
            .fontColor(this.pal().text).fontFamily(this.font())
          Text('手动抓取脱敏诊断事件').fontSize(12).fontColor(this.pal().text3)
            .fontFamily(this.font()).margin({ top: 2 })
        }.alignItems(HorizontalAlign.Start).margin({ left: 12 }).layoutWeight(1)

        SymbolGlyph($r('sys.symbol.xmark')).fontSize(18).fontColor([this.pal().text2])
          .width(36).height(36).onClick((): void => { this.onClose(); })
      }.width('100%').padding({ left: 24, right: 20, top: 20, bottom: 12 })

      Scroll() {
        Column() {
          Column() {
            Row() {
              Column()
                .width(10).height(10).borderRadius(5)
                .backgroundColor(this.phase === 'capturing' ? this.accentColor :
                  this.phase === 'readyToSave' ? '#E6A23C' : this.pal().text3)
              Column() {
                Text(this.statusTitle()).fontSize(16).fontWeight(FontWeight.Medium)
                  .fontColor(this.pal().text).fontFamily(this.font())
                Text(this.statusDetail()).fontSize(12).lineHeight(18)
                  .fontColor(this.pal().text2).fontFamily(this.font()).margin({ top: 4 })
              }.alignItems(HorizontalAlign.Start).layoutWeight(1).margin({ left: 12 })
            }.width('100%').alignItems(VerticalAlign.Center)
          }
          .width('100%').padding(16).borderRadius(18)
          .backgroundColor(this.pal().card)
          .border({ width: 0.5, color: this.pal().cardBorder, style: BorderStyle.Solid })

          Row() {
            Text('最长时长').fontSize(14).fontWeight(FontWeight.Medium)
              .fontColor(this.pal().text).fontFamily(this.font())
            Blank()
            Text(this.selectedDurationMinutes.toString() + ' 分钟').fontSize(12)
              .fontColor(this.pal().text3).fontFamily(this.font())
          }.width('100%').margin({ top: 20, bottom: 10 })

          Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Start }) {
            ForEach(this.durationOptions, (minutes: number) => {
              Button(minutes.toString() + ' 分钟')
                .height(36).padding({ left: 14, right: 14 })
                .fontSize(13).fontFamily(this.font())
                .fontColor(this.selectedDurationMinutes === minutes ? Color.White : this.pal().text2)
                .backgroundColor(this.selectedDurationMinutes === minutes ?
                  this.accentColor : this.pal().surface)
                .borderRadius(12).margin({ right: 8, bottom: 8 })
                .enabled(!this.optionsLocked())
                .opacity(this.optionsLocked() ? 0.65 : 1)
                .onClick((): void => { this.selectedDurationMinutes = minutes; })
            }, (minutes: number): string => minutes.toString())
          }.width('100%')

          Row() {
            Text('抓取模组').fontSize(14).fontWeight(FontWeight.Medium)
              .fontColor(this.pal().text).fontFamily(this.font())
            Blank()
            Text(this.selectedModules.length === this.moduleSpecs.length ? '仅保留应用状态' : '全选')
              .fontSize(13).fontWeight(FontWeight.Medium).fontColor(this.accentColor)
              .opacity(this.optionsLocked() ? 0.45 : 1)
              .onClick((): void => { this.toggleAllModules(); })
          }.width('100%').margin({ top: 12, bottom: 8 })

          Column() {
            ForEach(this.moduleSpecs, (spec: DiagnosticModuleSpec, index: number) => {
              Row() {
                Checkbox({ name: 'diagnostic-' + spec.id, group: 'diagnostic-modules' })
                  .select(this.moduleSelected(spec.id))
                  .selectedColor(this.accentColor)
                  .enabled(!this.optionsLocked() && !spec.alwaysEnabled)
                  .onChange((selected: boolean): void => { this.toggleModule(spec.id, selected); })
                Text(spec.label).fontSize(14).fontColor(this.pal().text)
                  .fontFamily(this.font()).margin({ left: 10 }).layoutWeight(1)
                if (spec.alwaysEnabled) {
                  Text('始终启用').fontSize(11).fontColor(this.pal().text3).fontFamily(this.font())
                }
              }
              .width('100%').height(44).padding({ left: 14, right: 14 })
              if (index < this.moduleSpecs.length - 1) {
                Divider().strokeWidth(0.5).color(this.pal().divider).margin({ left: 50 })
              }
            }, (spec: DiagnosticModuleSpec): string => spec.id)
          }
          .width('100%').borderRadius(18).backgroundColor(this.pal().card)
          .border({ width: 0.5, color: this.pal().cardBorder, style: BorderStyle.Solid })

          Column() {
            Text('隐私说明').fontSize(13).fontWeight(FontWeight.Medium)
              .fontColor(this.pal().text).fontFamily(this.font())
            Text('只记录固定状态码和数值指标，不包含密码、密钥正文、主机地址、终端内容、文件路径、剪贴板、屏幕或数据库内容。应用进程被系统终止时，未保存日志会丢失。')
              .fontSize(12).lineHeight(19).fontColor(this.pal().text2)
              .fontFamily(this.font()).margin({ top: 6 })
          }
          .width('100%').alignItems(HorizontalAlign.Start).padding(14)
          .borderRadius(16).backgroundColor(this.pal().surface).margin({ top: 14 })

          if (this.message !== '') {
            Text(this.message).fontSize(12).lineHeight(18)
              .fontColor(this.messageIsError ? this.pal().danger : this.pal().text2)
              .fontFamily(this.font()).width('100%').margin({ top: 12 })
          }

          Row() {
            if (this.phase !== 'idle') {
              Button('丢弃')
                .height(46).borderRadius(14).layoutWeight(1)
                .fontSize(15).fontColor(this.pal().danger)
                .backgroundColor(this.pal().surface)
                .enabled(this.phase !== 'saving')
                .onClick((): void => { this.confirmDiscard(); })
            }
            Button(this.primaryButtonText())
              .height(46).borderRadius(14)
              .layoutWeight(this.phase === 'idle' ? 1 : 2)
              .fontSize(15).fontWeight(FontWeight.Medium).fontColor(Color.White)
              .backgroundColor(this.accentColor)
              .margin({ left: this.phase === 'idle' ? 0 : 10 })
              .enabled(this.phase !== 'saving')
              .onClick((): void => { this.primaryAction(); })
          }.width('100%').margin({ top: 18, bottom: 24 })
        }
        .width('100%').padding({ left: 24, right: 24 })
      }
      .width('100%').layoutWeight(1).scrollBar(BarState.Off)
    }
    .width('100%')
    .constraintSize({ maxWidth: 620 })
    .height(this.breakpoint === 'sm' ? 680 : 740)
    .backgroundColor(this.pal().bg)
    .backgroundBlurStyle(BlurStyle.Regular)
    .borderRadius(this.breakpoint === 'sm' ?
      { topLeft: 22, topRight: 22, bottomLeft: 0, bottomRight: 0 } : 24)
  }
}
