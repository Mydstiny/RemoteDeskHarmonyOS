import { AppConfig, buildDark, buildLight, Palette } from '../../../common/Theme';
import {
  connectingRunIndex, nextQueuedRunIndex, WorkspaceRun, WorkspaceRunItem, workspaceRunFinished, workspaceRunSummary
} from '../../../services/pro/workspace/WorkspacePolicy';
import { orgProtocolLabel } from '../../../services/pro/org/HostOrganizationDirectory';

/**
 * Floating progress panel while a workspace opens: one row per entry (排队 → 连接中 → 已打开 / 未完成 / 已跳过),
 * with 打开下一个, 重试 and 跳过. It collapses to a single line so it never covers the host list.
 */
@Component
export struct WorkspaceRunPanel {
  @StorageProp('currentTheme') theme: string = 'light';
  @StorageProp('accentColor') accent: string = '#007DFF';
  @Prop run: WorkspaceRun = { workspaceId: '', name: '', color: '#007DFF', items: [], startedAt: 0 };
  onNext: () => void = (): void => {};
  onRetry: (index: number) => void = (_index: number): void => {};
  onSkip: (index: number) => void = (_index: number): void => {};
  onClose: () => void = (): void => {};
  @State expanded: boolean = true;

  private pal(): Palette { return this.theme === 'light' ? buildLight(this.accent) : buildDark(this.accent); }
  private stateText(item: WorkspaceRunItem): string {
    if (item.state === 'queued') { return item.autoConnect ? '排队中' : '等待手动连接'; }
    if (item.state === 'connecting') { return '连接中…'; }
    if (item.state === 'opened') { return '已打开'; }
    if (item.state === 'failed') { return item.message.length > 0 ? item.message : '未完成'; }
    return item.message.length > 0 ? item.message : '已跳过';
  }
  private stateColor(item: WorkspaceRunItem): ResourceColor {
    if (item.state === 'opened') { return this.pal().success; }
    if (item.state === 'failed') { return this.pal().danger; }
    if (item.state === 'connecting') { return this.run.color; }
    return this.pal().text3;
  }
  private nextLabel(): string {
    const next: number = nextQueuedRunIndex(this.run);
    return next < 0 ? '' : '连接「' + this.run.items[next].label + '」';
  }

  @Builder private stateIcon(item: WorkspaceRunItem) {
    if (item.state === 'connecting') {
      LoadingProgress().width(18).height(18).color(this.run.color)
    } else if (item.state === 'opened') {
      SymbolGlyph($r('sys.symbol.checkmark_circle_fill')).fontSize(17).fontColor([this.pal().success])
    } else if (item.state === 'failed') {
      SymbolGlyph($r('sys.symbol.exclamationmark_circle_fill')).fontSize(17).fontColor([this.pal().danger])
    } else if (item.state === 'skipped') {
      SymbolGlyph($r('sys.symbol.xmark_circle')).fontSize(17).fontColor([this.pal().text3])
    } else {
      SymbolGlyph($r('sys.symbol.circle')).fontSize(17).fontColor([this.pal().text3])
    }
  }

  build() {
    Column({ space: 8 }) {
      Row({ space: 8 }) {
        Circle().width(10).height(10).fill(this.run.color)
        Column({ space: 1 }) {
          Text(this.run.name).fontSize(14).fontWeight(FontWeight.Medium).fontColor(this.pal().text)
            .fontFamily(AppConfig.fontFamily).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(workspaceRunFinished(this.run) ? '已完成 · ' + workspaceRunSummary(this.run) : workspaceRunSummary(this.run))
            .fontSize(11).fontColor(this.pal().text3).maxLines(1)
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        SymbolGlyph(this.expanded ? $r('sys.symbol.chevron_down') : $r('sys.symbol.chevron_up')).fontSize(15)
          .fontColor([this.pal().text2]).padding(6).onClick((): void => { this.expanded = !this.expanded; })
        SymbolGlyph($r('sys.symbol.xmark')).fontSize(15).fontColor([this.pal().text2]).padding(6)
          .accessibilityText('结束工作区').onClick((): void => { this.onClose(); })
      }.width('100%')
      if (this.expanded) {
        Column({ space: 2 }) {
          ForEach(this.run.items, (item: WorkspaceRunItem, index: number): void => {
            Row({ space: 10 }) {
              this.stateIcon(item)
              Column({ space: 1 }) {
                Text(item.label).fontSize(13).fontColor(this.pal().text).maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                Text(orgProtocolLabel(item.protocol) + ' · ' + this.stateText(item)).fontSize(11)
                  .fontColor(this.stateColor(item)).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
              }.alignItems(HorizontalAlign.Start).layoutWeight(1)
              if (item.state === 'failed' || item.state === 'connecting' ||
                (item.state === 'skipped' && item.message !== '主机不存在')) {
                Text(item.state === 'connecting' ? '重新连接' : '重试').fontSize(12).fontColor(this.accent).padding(6)
                  .onClick((): void => { this.onRetry(index); })
              }
              if (item.state === 'queued' || item.state === 'connecting') {
                Text('跳过').fontSize(12).fontColor(this.pal().text2).padding(6)
                  .onClick((): void => { this.onSkip(index); })
              }
            }.width('100%').padding({ top: 5, bottom: 5 })
          }, (item: WorkspaceRunItem, index: number): string => index.toString() + item.hostRef + item.state + item.message)
        }.width('100%').constraintSize({ maxHeight: 260 })
        if (nextQueuedRunIndex(this.run) >= 0 && connectingRunIndex(this.run) < 0) {
          Button(this.nextLabel()).width('100%').height(38).fontSize(13).backgroundColor(this.run.color)
            .fontColor(Color.White).onClick((): void => { this.onNext(); })
        }
      }
    }
    .width('100%').padding(14).borderRadius(22).backgroundColor(this.pal().floatBg)
    .backgroundBlurStyle(BlurStyle.Thick)
    .border({ width: 0.5, color: this.pal().floatBorder })
    .shadow({ radius: 18, color: '#22000000', offsetY: 6 })
  }
}
