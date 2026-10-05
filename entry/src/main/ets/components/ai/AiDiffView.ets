import { AppConfig } from '../../common/Theme';
import { AiDiffFile, AiDiffLine, aiDiffStats } from '../../services/ai/AiTimeline';
import { AiStylePalette } from '../../services/ai/AiStylePalette';

const PREVIEW_LINES: number = 80;

/** Unified diff by file: header with counts, coloured lines, long files folded until asked. */
@Component
export struct AiDiffView {
  @Prop files: AiDiffFile[] = [];
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
  @State unfolded: string[] = [];

  private fileKey(file: AiDiffFile, index: number): string { return index.toString() + ':' + file.path; }

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
                ForEach(this.unfolded.includes(this.fileKey(file, index)) ? file.lines :
                  file.lines.slice(0, PREVIEW_LINES), (line: AiDiffLine): void => {
                  this.line(line)
                }, (line: AiDiffLine, row: number): string => row.toString() + line.kind)
              }.alignItems(HorizontalAlign.Start)
            }.scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off).width('100%').align(Alignment.Start)
            .backgroundColor(this.palette.codeBg).padding({ top: 4, bottom: 4 })
            if (file.lines.length > PREVIEW_LINES && !this.unfolded.includes(this.fileKey(file, index))) {
              Text('显示其余 ' + (file.lines.length - PREVIEW_LINES).toString() + ' 行').fontSize(12)
                .fontFamily(AppConfig.fontFamily).fontColor(this.palette.accent).padding(10).width('100%')
                .textAlign(TextAlign.Center).backgroundColor(this.palette.codeBg)
                .onClick((): void => { this.unfolded = this.unfolded.concat([this.fileKey(file, index)]); })
            }
          }
        }
        .width('100%').borderRadius(10).clip(true).border({ width: 0.5, color: this.palette.border })
      }, (file: AiDiffFile, index: number): string => this.fileKey(file, index) + ':' + file.lines.length.toString())
    }.width('100%')
  }
}
