import { appUiOnAccentText } from '../../../common/AppUiColorPolicy';
import {
  WorkspaceStepRun,
  WorkspaceStepRunItem,
  workspaceStepRunFinished,
  workspaceStepRunSummary,
  workspaceStepStateLabel
} from '../../../services/pro/workspace/WorkspaceStepPolicy';

/**
 * 连接后步骤 running in an SSH session (Pro): each step's state, and 暂停/继续, 跳过下一步, 重试, 取消. Dark glass over
 * the terminal; it stays small and out of the way of the prompt.
 */
@Component
export struct WorkspaceStepRunCard {
  @StorageProp('accentColor') accentColor: string = '#007DFF';
  @Prop run: WorkspaceStepRun = {
    workspaceId: '', workspaceName: '', workspaceUpdatedAt: 0, hostId: '', items: [], paused: false, cancelled: false
  };
  onPause: (paused: boolean) => void = (_paused: boolean): void => {};
  onSkip: () => void = (): void => {};
  onRetry: () => void = (): void => {};
  onCancel: () => void = (): void => {};
  onClose: () => void = (): void => {};

  private stateColor(item: WorkspaceStepRunItem): string {
    if (item.state === 'done') { return '#66DD7A'; }
    if (item.state === 'failed' || item.state === 'invalid') { return '#FF7A6E'; }
    if (item.state === 'running') { return this.accentColor; }
    return '#9AA4B2';
  }

  private hasFailed(): boolean {
    return this.run.items.some((item: WorkspaceStepRunItem): boolean => item.state === 'failed');
  }

  private hasPending(): boolean {
    return this.run.items.some((item: WorkspaceStepRunItem): boolean => item.state === 'pending');
  }

  @Builder private smallButton(label: string, primary: boolean, action: () => void) {
    Button(label).height(30).fontSize(12).padding({ left: 10, right: 10 })
      .fontColor(primary ? appUiOnAccentText(this.accentColor) : '#FFFFFF')
      .backgroundColor(primary ? this.accentColor : '#33FFFFFF')
      .onClick(action)
  }

  build() {
    Column({ space: 6 }) {
      Row({ space: 6 }) {
        SymbolGlyph($r('sys.symbol.bolt_fill')).fontSize(14).fontColor([this.accentColor])
        Text(this.run.workspaceName + ' · 连接后步骤').fontSize(13).fontWeight(FontWeight.Medium)
          .fontColor('#FFFFFF').layoutWeight(1).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        if (workspaceStepRunFinished(this.run)) {
          Button() { SymbolGlyph($r('sys.symbol.xmark')).fontSize(13).fontColor(['#FFFFFF']) }
            .width(28).height(28).padding(0).backgroundColor('#33FFFFFF')
            .onClick(() => { this.onClose(); }).accessibilityText('关闭')
        }
      }.width('100%')
      ForEach(this.run.items, (item: WorkspaceStepRunItem, index: number) => {
        Row({ space: 8 }) {
          Text((index + 1).toString()).fontSize(11).fontColor('#9AA4B2').width(14)
          Column({ space: 1 }) {
            Text(item.label).fontSize(12).fontColor('#FFFFFF').maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            if (item.message !== '') {
              Text(item.message).fontSize(11).fontColor('#B8C0CC').maxLines(2)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
          }.alignItems(HorizontalAlign.Start).layoutWeight(1)
          Text(workspaceStepStateLabel(item.state)).fontSize(11).fontColor(this.stateColor(item))
        }.width('100%')
      }, (item: WorkspaceStepRunItem, index: number) => index.toString() + item.state + item.message)
      Text(workspaceStepRunSummary(this.run) + (this.run.paused ? ' · 已暂停' : ''))
        .fontSize(11).fontColor('#B8C0CC').width('100%')
      if (!workspaceStepRunFinished(this.run)) {
        Row({ space: 6 }) {
          this.smallButton(this.run.paused ? '继续' : '暂停', this.run.paused,
            () => { this.onPause(!this.run.paused); })
          if (this.hasPending()) {
            this.smallButton('跳过下一步', false, () => { this.onSkip(); })
          }
          Blank()
          this.smallButton('取消', false, () => { this.onCancel(); })
        }.width('100%')
      } else if (this.hasFailed() && !this.run.cancelled) {
        Row() {
          this.smallButton('重试失败的步骤', true, () => { this.onRetry(); })
        }.width('100%')
      }
    }
    .width(300).padding(12).borderRadius(14)
    .backgroundColor('#E6141A22').border({ width: 0.5, color: '#33FFFFFF' })
  }
}
