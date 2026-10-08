import { AppConfig } from '../../common/Theme';
import { AiDiffFile, AiDiffLine, aiDiffStats } from '../../services/ai/AiTimeline';
import { AiStylePalette } from '../../services/ai/AiStylePalette';

const PREVIEW_LINES: number = 80;
const MORE_LINES: number = 400;

/**
 * Unified diff by file: header with counts, coloured lines, long files shown a page at a time. `files` is set once:
 * callers rebuild the view (through its list key) when the diff changes, so large diffs are not copied per render.
 */
@Component
export struct AiDiffView {
  files: AiDiffFile[] = [];
  @Prop textSize: number = 13;
  @Prop palette: AiStylePalette = {
    bg: '#FFFFFF', surface: '#F7F7F8', raised: '#FFFFFF', border: '#E5E5E5', text: '#0D0D0D', text2: '#5D5D5D',
    text3: '#8F8F8F', userBubble: '#F4F4F4', codeBg: '#F7F7F8', codeText: '#24292F', accent: '#0D0D0D',
    onAccent: '#FFFFFF', addBg: '#E6F4EA', addText: '#1A7F37', delBg: '#FDECEA', delText: '#CF222E',
    danger: '#CF222E', ok: '#1A7F37'
  };
  /** Files start open when there are few of them. */
  @Prop startOpen: boolean = true;
  @State toggled: string[] = [];
  /** Lines shown per file beyond the preview, by file key. */
  @State shown: Map<string, number> = new Map();

  private fileKey(file: AiDiffFile, index: number): string { return index.toString() + ':' + file.path; }

  private visible(file: AiDiffFile, key: string): number {
    return Math.min(file.lines.length, this.shown.get(key) ?? PREVIEW_LINES);
  }

  private showMore(file: AiDiffFile, key: string): void {
    const next: Map<string, number> = new Map(this.shown);
    next.set(key, Math.min(file.lines.length, this.visible(file, key) + MORE_LINES));
    this.shown = next;
  }

  private open(key: string): boolean { return this.startOpen !== this.toggled.includes(key); }

  private toggle(key: string): void {
    this.toggled = this.toggled.includes(key) ? this.toggled.filter((value: string): boolean => value !== key) :
      this.toggled.concat([key]);
  }

  @Builder private line(line: AiDiffLine) {
    Text((line.kind === 'add' ? '+ ' : line.kind === 'del' ? '− ' : line.kind === 'hunk' ? '' : '  ') + line.text)
      .fontSize(this.textSize).lineHeight(Math.round(this.textSize * 1.45)).fontFamily('monospace')
      .fontColor(line.kind === 'add' ? this.palette.addText : line.kind === 'del' ? this.palette.delText :
        line.kind === 'hunk' ? this.palette.text3 : this.palette.codeText)
      .backgroundColor(line.kind === 'add' ? this.palette.addBg : line.kind === 'del' ? this.palette.delBg :
        Color.Transparent)
      .padding({ left: 10, right: 10 }).constraintSize({ minWidth: '100%' }).copyOption(CopyOptions.LocalDevice)
  }

  build() {
    Column({ space: 10 }) {
      ForEach(this.files, (file: AiDiffFile, index: number): void => {
        Column() {
          Row({ space: 8 }) {
            SymbolGlyph(this.open(this.fileKey(file, index)) ? $r('sys.symbol.chevron_down') : $r('sys.symbol.chevron_right'))
              .fontSize(14).fontColor([this.palette.text3])
            Text(file.path === '' ? '（未命名文件）' : file.path).fontSize(this.textSize).fontFamily('monospace')
              .fontColor(this.palette.text).layoutWeight(1).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
            Text('+' + file.added.toString()).fontSize(12).fontFamily(AppConfig.fontFamily).fontColor(this.palette.addText)
            Text('−' + file.removed.toString()).fontSize(12).fontFamily(AppConfig.fontFamily).fontColor(this.palette.delText)
          }
          .width('100%').padding({ left: 10, right: 12, top: 9, bottom: 9 }).backgroundColor(this.palette.surface)
          .accessibilityText(file.path + ' ' + aiDiffStats(file.added, file.removed))
          .onClick((): void => { this.toggle(this.fileKey(file, index)); })
          if (this.open(this.fileKey(file, index))) {
            Scroll() {
              Column() {
                ForEach(file.lines.slice(0, this.visible(file, this.fileKey(file, index))), (line: AiDiffLine): void => {
                  this.line(line)
                }, (line: AiDiffLine, row: number): string => row.toString() + line.kind)
              }.alignItems(HorizontalAlign.Start)
            }.scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off).width('100%').align(Alignment.Start)
            .backgroundColor(this.palette.codeBg).padding({ top: 4, bottom: 4 })
            if (file.lines.length > this.visible(file, this.fileKey(file, index))) {
              Text('再显示 ' + Math.min(MORE_LINES, file.lines.length - this.visible(file, this.fileKey(file, index))).toString() +
                ' 行（还有 ' + (file.lines.length - this.visible(file, this.fileKey(file, index))).toString() + ' 行）')
                .fontSize(12).fontFamily(AppConfig.fontFamily).fontColor(this.palette.accent).padding(10).width('100%')
                .textAlign(TextAlign.Center).backgroundColor(this.palette.codeBg)
                .onClick((): void => { this.showMore(file, this.fileKey(file, index)); })
            } else if (file.truncated === true) {
              Text('改动较大，其余内容请在电脑端查看').fontSize(12).fontFamily(AppConfig.fontFamily)
                .fontColor(this.palette.text3).padding(10).width('100%').textAlign(TextAlign.Center)
                .backgroundColor(this.palette.codeBg)
            }
          }
        }
        .width('100%').borderRadius(10).clip(true).border({ width: 0.5, color: this.palette.border })
      }, (file: AiDiffFile, index: number): string => this.fileKey(file, index) + ':' + file.lines.length.toString())
    }.width('100%')
  }
}
