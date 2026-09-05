import {
  SshTransferCenterAction,
  SshTransferCenterFilter,
  SshTransferCenterSummary,
  SshTransferCenterTaskView
} from '../../../services/ssh/sftp/SshTransferCenterPolicy';

/** Path-free task projection for the process-wide SSH transfer store. */
@Component
export struct SshTransferCenter {
  @StorageProp('accentColor') accentColor: string = '#007DFF';
  @Prop sheetBackgroundColor: string = '#111820';
  @Prop tasks: Array<SshTransferCenterTaskView> = [];
  @Prop summary: SshTransferCenterSummary = { total: 0, active: 0, attention: 0, completed: 0 };
  @Prop compact: boolean = false;
  onClose: () => void = (): void => {};
  onAction: (taskId: string, action: SshTransferCenterAction) => void =
    (_taskId: string, _action: SshTransferCenterAction): void => {};

  @State filter: SshTransferCenterFilter = 'all';

  private filterLabel(filter: SshTransferCenterFilter): string {
    if (filter === 'active') { return '进行中'; }
    if (filter === 'attention') { return '需处理'; }
    if (filter === 'completed') { return '已结束'; }
    return '全部';
  }

  private filteredTasks(): Array<SshTransferCenterTaskView> {
    if (this.filter === 'all') { return this.tasks; }
    return this.tasks.filter((task: SshTransferCenterTaskView): boolean => {
      if (this.filter === 'active') {
        return !task.canClear && !task.canRetry && task.stage !== 'paused';
      }
      if (this.filter === 'attention') {
        return task.canRetry || task.stage === 'paused';
      }
      return task.canClear;
    });
  }

  @Builder
  private FilterChip(filter: SshTransferCenterFilter, count: number) {
    Button(this.filterLabel(filter) + ' ' + count.toString())
      .height(32).padding({ left: 10, right: 10 }).fontSize(11)
      .fontColor(this.filter === filter ? '#FFFFFF' : 'rgba(242,244,247,0.72)')
      .backgroundColor(this.filter === filter ? this.accentColor : 'rgba(255,255,255,0.07)')
      .borderRadius(16)
      .onClick((): void => { this.filter = filter; })
  }

  @Builder
  private TaskAction(label: string, task: SshTransferCenterTaskView,
    action: SshTransferCenterAction, enabled: boolean, danger: boolean = false) {
    Button(label)
      .height(30).padding({ left: 9, right: 9 }).fontSize(10)
      .enabled(enabled)
      .fontColor(danger ? '#FFFFFF' : 'rgba(242,244,247,0.86)')
      .backgroundColor(danger ? '#B4232C' : 'rgba(255,255,255,0.08)')
      .borderRadius(8)
      .onClick((): void => { this.onAction(task.taskId, action); })
  }

  @Builder
  private TaskRow(task: SshTransferCenterTaskView) {
    Column({ space: 8 }) {
      Row({ space: 8 }) {
        Column({ space: 2 }) {
          Text(task.title).fontSize(13).fontColor('#F4F7FA')
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(task.hostAlias + ' · ' + task.directionLabel + ' · ' + task.stageLabel)
            .fontSize(10).fontColor('rgba(242,244,247,0.55)')
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        Text(task.progressLabel).fontSize(11).fontColor('rgba(242,244,247,0.72)')
      }.width('100%')
      Progress({ value: Math.floor(task.progress * 100), total: 100, type: ProgressType.Linear })
        .width('100%').height(4).color(this.accentColor)
        .backgroundColor('rgba(255,255,255,0.10)')
      Row({ space: 6 }) {
        if (task.canPause) { this.TaskAction('暂停', task, 'pause', true) }
        if (task.canResume) { this.TaskAction('继续', task, 'resume', true) }
        if (task.canRetry) { this.TaskAction('重试', task, 'retry', true) }
        if (task.canCancel) { this.TaskAction('取消', task, 'cancel', true, true) }
        if (task.canClear) { this.TaskAction('清除记录', task, 'clear', true) }
      }.width('100%').justifyContent(FlexAlign.End)
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 11, bottom: 11 })
    .borderRadius(10)
    .backgroundColor('rgba(255,255,255,0.055)')
    .border({ width: 0.5, color: 'rgba(255,255,255,0.09)' })
  }

  build() {
    Column() {
      Row() {
        Column({ space: 2 }) {
          Text('SSH 传输中心').fontSize(18).fontWeight(FontWeight.Medium).fontColor('#F4F7FA')
          Text('任务由现有 SFTP 引擎继续执行，关闭终端标签不会取消传输')
            .fontSize(10).fontColor('rgba(242,244,247,0.52)').maxLines(2)
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        Button('×').width(34).height(34).padding(0).fontSize(20)
          .fontColor('rgba(242,244,247,0.76)')
          .borderRadius(17).backgroundColor('rgba(255,255,255,0.07)')
          .onClick((): void => { this.onClose(); })
          .accessibilityText('关闭 SSH 传输中心')
      }.width('100%')

      Scroll() {
        Row({ space: 6 }) {
          this.FilterChip('all', this.summary.total)
          this.FilterChip('active', this.summary.active)
          this.FilterChip('attention', this.summary.attention)
          this.FilterChip('completed', this.summary.completed)
        }
      }
      .scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off)
      .width('100%').height(38).margin({ top: 14, bottom: 10 })

      if (this.filteredTasks().length === 0) {
        Column({ space: 8 }) {
          SymbolGlyph($r('sys.symbol.folder'))
            .fontSize(28).fontColor(['rgba(242,244,247,0.32)'])
          Text('当前筛选下没有传输任务').fontSize(12).fontColor('rgba(242,244,247,0.52)')
        }.width('100%').height(180).justifyContent(FlexAlign.Center)
      } else {
        List({ space: 8 }) {
          ForEach(this.filteredTasks(), (task: SshTransferCenterTaskView): void => {
            ListItem() { this.TaskRow(task) }
          }, (task: SshTransferCenterTaskView): string => task.taskId)
        }
        .width('100%').height(0).layoutWeight(1)
        .scrollBar(BarState.Auto).edgeEffect(EdgeEffect.None)
      }
    }
    .width('100%').height('100%')
    .padding({ left: this.compact ? 14 : 20, right: this.compact ? 14 : 20,
      top: 18, bottom: 16 })
    .backgroundColor(this.sheetBackgroundColor)
  }
}
