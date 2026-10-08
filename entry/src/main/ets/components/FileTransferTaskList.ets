import { AccountSessionCoordinator } from '../services/AccountSessionCoordinator';
import { common } from '@kit.AbilityKit';
import { ManagedTransferTaskService } from '../services/ManagedTransferTaskService';
import { ManagedTransferRecord, managedTransferSettled, managedTransferTerminal } from '../services/ManagedTransferTaskPolicy';
import { transferTaskCancellable, transferTaskDescription } from '../services/TransferUserTextPolicy';
import { Palette, buildDark, buildLight } from '../common/Theme';

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

  private progressPercent(record: ManagedTransferRecord): number {
    const done: number = Math.max(record.readBytes, record.sentBytes, record.writtenBytes);
    return Math.min(100, Math.floor(done * 100 / record.totalBytes));
  }

  private hasFinished(): boolean {
    return this.records.some((record: ManagedTransferRecord): boolean => managedTransferSettled(record.stage));
  }

  build() {
    Column({ space: 10 }) {
      Row({ space: 8 }) {
        Text('任务记录').fontSize(16).fontWeight(FontWeight.Medium)
          .fontColor(this.pal().text).layoutWeight(1)
        if (this.hasFinished()) {
          Button('清除已完成').fontSize(12).height(32)
            .onClick((): void => {
              ManagedTransferTaskService.getInstance().clearFinished(this.accountScopeId, this.hostId);
            })
        }
      }.width('100%')
      if (this.records.length === 0) {
        Text('暂无文件任务').fontSize(13).fontColor(this.pal().text2).width('100%')
      }
      ForEach(this.records, (record: ManagedTransferRecord) => {
        Column({ space: 6 }) {
          Row({ space: 8 }) {
            Text(record.fileName).fontSize(14).fontColor(this.pal().text)
              .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
            if (transferTaskCancellable(record.stage)) {
              Button('取消').fontSize(12).height(28).onClick((): void => {
                ManagedTransferTaskService.getInstance().cancel(this.accountScopeId, record.taskId, record.attemptId);
              })
            }
          }.width('100%')
          Text(this.description(record)).fontSize(12).fontColor(this.pal().text2).width('100%')
          if (!managedTransferTerminal(record.stage) && record.totalBytes > 0) {
            Progress({ value: this.progressPercent(record), total: 100, type: ProgressType.Linear })
              .width('100%')
          }
        }.padding(10).width('100%').borderRadius(10).backgroundColor(this.pal().card)
      }, (record: ManagedTransferRecord): string => record.taskId + ':' + record.attemptId.toString() + ':' +
        record.stage + ':' + record.diagnosticCode + ':' +
        Math.max(record.readBytes, record.sentBytes, record.writtenBytes).toString())
    }.width('100%')
  }
}
