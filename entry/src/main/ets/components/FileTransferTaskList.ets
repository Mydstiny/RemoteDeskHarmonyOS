import { AccountSessionCoordinator } from '../services/AccountSessionCoordinator';
import { common } from '@kit.AbilityKit';
import { ManagedTransferTaskService } from '../services/ManagedTransferTaskService';
import { ManagedTransferRecord, managedTransferSettled, managedTransferTerminal } from '../services/ManagedTransferTaskPolicy';
import { transferTaskDescription } from '../services/TransferUserTextPolicy';
import { Palette, buildDark, buildLight } from '../common/Theme';
import { appUiTint } from '../common/AppUiColorPolicy';
import { TransferProgressBar, transferSymbol } from './transfer/TransferUi';
import { curves } from '@kit.ArkUI';

@Component
export struct FileTransferTaskList {
  @Prop accountScopeId: string = '';
  @Prop hostId: string = '';
  @StorageLink('currentTheme') theme: string = 'light';
  @StorageLink('accentColor') accentColor: string = '#007DFF';
  @State private records: ManagedTransferRecord[] = [];
  private unsubscribe: (() => void) | null = null;
  private accountUnsubscribe: (() => void) | null = null;

  private pal(): Palette {
    return this.theme === 'light' ? buildLight(this.accentColor) : buildDark(this.accentColor);
  }

  aboutToAppear(): void {
    const service: ManagedTransferTaskService = ManagedTransferTaskService.getInstance();
    const context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
    if (!service.init(context)) { return; }
    this.accountUnsubscribe = AccountSessionCoordinator.getInstance().onChange((scope): void => {
      if (scope.ownerScopeId !== this.accountScopeId) {
        this.records = []; this.unsubscribe?.(); this.unsubscribe = null;
      } else if (this.unsubscribe === null) {
        this.subscribe(service);
      }
    });
    this.subscribe(service);
  }
  aboutToDisappear(): void {
    this.unsubscribe?.(); this.unsubscribe = null;
    this.accountUnsubscribe?.(); this.accountUnsubscribe = null;
  }

  private subscribe(service: ManagedTransferTaskService): void {
    this.unsubscribe = service.subscribe(this.accountScopeId, (records: ManagedTransferRecord[]): void => {
      if (AccountSessionCoordinator.getInstance().currentScope().ownerScopeId !== this.accountScopeId) { this.records = []; return; }
      this.records = records.filter((record: ManagedTransferRecord): boolean => record.hostId === this.hostId)
        .sort((left: ManagedTransferRecord, right: ManagedTransferRecord): number => right.createdAt - left.createdAt);
    });
  }

  private description(record: ManagedTransferRecord): string {
    return transferTaskDescription({ stage: record.stage, direction: record.direction, evidence: record.evidence,
      diagnosticCode: record.diagnosticCode,
      queued: ManagedTransferTaskService.getInstance().isQueued(record.accountScopeId, record.taskId, record.attemptId) });
  }

  private progressFraction(record: ManagedTransferRecord): number {
    // An upload shows what the remote took once that started; before, its local staging.
    const done: number = record.direction === 'upload' && record.sentBytes > 0 ? record.sentBytes :
      Math.max(record.readBytes, record.writtenBytes, record.sentBytes);
    return record.totalBytes > 0 ? Math.min(1, done / record.totalBytes) : -1;
  }

  private hasFinished(): boolean {
    return this.records.some((record: ManagedTransferRecord): boolean => managedTransferSettled(record.stage));
  }

  private runningCount(): number {
    return this.records.filter((record: ManagedTransferRecord): boolean => !managedTransferSettled(record.stage)).length;
  }

  /** The row's colour: the accent while it runs, green when it arrived, red when it stopped short, grey when cancelled. */
  private stateColor(record: ManagedTransferRecord): string {
    if (!managedTransferSettled(record.stage)) { return this.accentColor; }
    if (record.stage === 'completed' || record.stage === 'handedOff') { return this.pal().success; }
    if (record.stage === 'cancelled' || record.stage === 'expired') { return this.pal().text3; }
    return this.pal().danger;
  }

  private stateIcon(record: ManagedTransferRecord): string {
    if (!managedTransferSettled(record.stage)) { return record.direction === 'upload' ? 'upload' : 'download'; }
    if (record.stage === 'completed' || record.stage === 'handedOff') { return 'done'; }
    if (record.stage === 'cancelled' || record.stage === 'expired') { return 'close'; }
    return 'warning';
  }

  private sizeText(bytes: number): string {
    if (bytes < 1024) { return bytes.toString() + ' B'; }
    if (bytes < 1024 * 1024) { return (bytes / 1024).toFixed(1) + ' KB'; }
    if (bytes < 1024 * 1024 * 1024) { return (bytes / 1024 / 1024).toFixed(1) + ' MB'; }
    return (bytes / 1024 / 1024 / 1024).toFixed(2) + ' GB';
  }

  private meta(record: ManagedTransferRecord): string {
    const fraction: number = this.progressFraction(record);
    if (!managedTransferTerminal(record.stage) && fraction >= 0 && record.stage !== 'preparing') {
      return Math.floor(fraction * 100).toString() + '% · ' + this.sizeText(record.totalBytes);
    }
    return record.totalBytes > 0 ? this.sizeText(record.totalBytes) : '';
  }

  private keyOf(record: ManagedTransferRecord): string {
    return record.taskId + ':' + record.attemptId.toString();
  }

  /** The record as it is now: rows keep their key while progress changes, and read the live values by it. */
  private live(key: string): ManagedTransferRecord {
    return this.records.find((record: ManagedTransferRecord): boolean => this.keyOf(record) === key) ??
      new ManagedTransferRecord();
  }

  @Builder private row(key: string, last: boolean) {
    Column({ space: 8 }) {
      Row({ space: 12 }) {
        Stack() {
          Circle().width(36).height(36).fill(appUiTint(this.stateColor(this.live(key)), '24'))
          SymbolGlyph(transferSymbol(this.stateIcon(this.live(key)))).fontSize(17).fontWeight(FontWeight.Medium)
            .fontColor([this.stateColor(this.live(key))])
        }.width(36).height(36)
        Column({ space: 2 }) {
          Text(this.live(key).fileName).fontSize(14).fontWeight(FontWeight.Medium).fontColor(this.pal().text)
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
          Row({ space: 6 }) {
            Text(this.description(this.live(key))).fontSize(12).fontColor(this.pal().text2)
              .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
            if (this.meta(this.live(key)).length > 0) {
              Text(this.meta(this.live(key))).fontSize(11).fontColor(this.pal().text3).fontFeature('"tnum" on')
            }
          }.width('100%')
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        if (ManagedTransferTaskService.getInstance().isCancellable(this.live(key).accountScopeId,
          this.live(key).taskId, this.live(key).attemptId)) {
          Button() {
            SymbolGlyph(transferSymbol('close')).fontSize(13).fontColor([this.pal().text2])
          }
          .width(30).height(30).padding(0).type(ButtonType.Circle)
          .backgroundColor(this.theme === 'light' ? 'rgba(0,0,0,0.06)' : 'rgba(255,255,255,0.12)')
          .accessibilityText('取消 ' + this.live(key).fileName)
          .onClick((): void => {
            ManagedTransferTaskService.getInstance().cancel(this.accountScopeId, this.live(key).taskId,
              this.live(key).attemptId);
          })
        }
      }.width('100%')
      if (!managedTransferSettled(this.live(key).stage)) {
        TransferProgressBar({ value: this.live(key).stage === 'preparing' && this.progressFraction(this.live(key)) <= 0 ? -1 :
          this.progressFraction(this.live(key)), color: this.accentColor, barHeight: 3 })
          .padding({ left: 48 })
      }
    }
    .width('100%').padding({ left: 12, right: 12, top: 11, bottom: 11 })
    .border({ width: { bottom: last ? 0 : 0.5 }, color: this.pal().divider })
  }

  build() {
    Column({ space: 10 }) {
      Row({ space: 8 }) {
        Text('任务记录').fontSize(15).fontWeight(FontWeight.Medium).fontColor(this.pal().text)
        if (this.runningCount() > 0) {
          Text(this.runningCount().toString() + ' 个进行中').fontSize(11).fontColor(this.accentColor)
            .padding({ left: 8, right: 8, top: 2, bottom: 2 }).borderRadius(10)
            .backgroundColor(appUiTint(this.accentColor, '1F'))
        }
        Blank()
        if (this.hasFinished()) {
          Text('清除已完成').fontSize(13).fontColor(this.accentColor)
            .padding({ left: 8, right: 4, top: 6, bottom: 6 })
            .onClick((): void => {
              this.getUIContext().animateTo({ curve: curves.springMotion(0.4, 0.86) }, (): void => {
                ManagedTransferTaskService.getInstance().clearFinished(this.accountScopeId, this.hostId);
              });
            })
        }
      }.width('100%')
      if (this.records.length === 0) {
        Row({ space: 10 }) {
          SymbolGlyph(transferSymbol('clock')).fontSize(16).fontColor([this.pal().text3])
          Text('还没有文件任务').fontSize(13).fontColor(this.pal().text2)
        }.width('100%').padding({ left: 14, right: 14, top: 14, bottom: 14 })
        .borderRadius(16).backgroundColor(this.pal().surface)
      } else {
        Column() {
          ForEach(this.records, (record: ManagedTransferRecord, index: number) => {
            Column() { this.row(this.keyOf(record), index === this.records.length - 1) }
              .width('100%')
              .transition(TransitionEffect.OPACITY.combine(TransitionEffect.translate({ y: -8 }))
                .animation({ curve: curves.springMotion(0.42, 0.86) }))
          }, (record: ManagedTransferRecord, index: number): string => this.keyOf(record) +
            (index === this.records.length - 1 ? ':last' : ''))
        }.width('100%').borderRadius(16).backgroundColor(this.pal().surface).clip(true)
      }
    }.width('100%')
  }
}
