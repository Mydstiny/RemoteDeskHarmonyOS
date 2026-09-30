import { AccountSessionCoordinator } from '../services/AccountSessionCoordinator';
import { common } from '@kit.AbilityKit';
import { ManagedTransferTaskService } from '../services/ManagedTransferTaskService';
import { ManagedTransferRecord, managedTransferTerminal } from '../services/ManagedTransferTaskPolicy';
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
      if (scope.ownerScopeId !== this.accountScopeId) { this.records = []; this.unsubscribe?.(); this.unsubscribe = null; }
    });
    this.unsubscribe = service.subscribe(this.accountScopeId, (records: ManagedTransferRecord[]): void => {
      if (AccountSessionCoordinator.getInstance().currentScope().ownerScopeId !== this.accountScopeId) { this.records = []; return; }
      this.records = records.filter((record: ManagedTransferRecord): boolean => record.hostId === this.hostId)
        .sort((left: ManagedTransferRecord, right: ManagedTransferRecord): number => right.createdAt - left.createdAt);
    });
  }
  aboutToDisappear(): void {
    this.unsubscribe?.(); this.unsubscribe = null;
    this.accountUnsubscribe?.(); this.accountUnsubscribe = null;
  }

  private description(record: ManagedTransferRecord): string {
    if (record.stage === 'completed') {
      if (record.evidence === 'exported') { return '已保存到所选位置'; }
      if (record.evidence === 'contentVerified') { return '目标内容已校验'; }
      if (record.evidence === 'metadataVerified') { return record.direction === 'download' ?
        '本机副本大小已校验，远端内容哈希未知' : '目标大小与时间已核对'; }
      return '已发送，目标文件尚未校验';
    }
    if (record.stage === 'commitUnknown') { return '保存结果未知，请先检查目标文件'; }
    if (record.stage === 'paused') { return record.evidence === 'offered' ? '已提供给远端，目标写入未确认' : '已暂停，需要重新选择来源后重试'; }
    if (record.stage === 'cancelled') { return '已取消'; }
    if (record.stage === 'failed') { return '未完成，可重新选择文件重试'; }
    if (record.stage === 'cancelling') { return '正在停止传输'; }
    if (record.stage === 'verifying') { return '正在校验文件'; }
    if (record.stage === 'committing') { return '正在保存文件'; }
    return '正在传输';
  }

  build() {
    Column({ space: 10 }) {
      Text('任务记录').fontSize(16).fontWeight(FontWeight.Medium)
        .fontColor(this.pal().text).width('100%')
      if (this.records.length === 0) {
        Text('暂无文件任务').fontSize(13).fontColor(this.pal().text2).width('100%')
      }
      ForEach(this.records, (record: ManagedTransferRecord) => {
        Column({ space: 6 }) {
          Row({ space: 8 }) {
            Text(record.fileName).fontSize(14).fontColor(this.pal().text)
              .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
            if (!managedTransferTerminal(record.stage) && record.stage !== 'commitUnknown' && record.stage !== 'paused') {
              Button('取消').fontSize(12).height(28).onClick((): void => {
                ManagedTransferTaskService.getInstance().cancel(this.accountScopeId, record.taskId, record.attemptId);
              })
            }
          }.width('100%')
          Text(this.description(record)).fontSize(12).fontColor(this.pal().text2).width('100%')
          if (!managedTransferTerminal(record.stage) && record.totalBytes > 0) {
            Progress({ value: Math.min(100, Math.floor(Math.max(record.sentBytes, record.writtenBytes) * 100 / record.totalBytes)), total: 100, type: ProgressType.Linear })
              .width('100%')
          }
        }.padding(10).width('100%').borderRadius(10).backgroundColor(this.pal().card)
      }, (record: ManagedTransferRecord): string => record.taskId + ':' + record.attemptId.toString())
    }.width('100%')
  }
}
