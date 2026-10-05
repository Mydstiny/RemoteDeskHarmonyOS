import { AppConfig } from '../../common/Theme';
import { AiMdBlock, AiMdSpan, aiMarkdownBlocks } from '../../services/diagnosticAi/AiMarkdownPolicy';
import { AiStylePalette } from '../../services/ai/AiStylePalette';

// Keys change whenever a block's text grows, so streamed answers re-render as they arrive.
function aiBlockKey(block: AiMdBlock, index: number): string {
  let size: number = block.text.length;
  block.spans.forEach((span: AiMdSpan): void => { size += span.text.length; });
  block.rows.forEach((row: string[]): void => { row.forEach((cell: string): void => { size += cell.length; }); });
  return index.toString() + ':' + block.kind + ':' + size.toString();
}

/** Assistant text in the remote AI page: headings, paragraphs, lists, quotes, rules, code blocks and tables. */
@Component
export struct AiRemoteMarkdown {
  @Prop text: string = '';
  @Prop textSize: number = 15;
  @Prop palette: AiStylePalette = {
    bg: '#FFFFFF', surface: '#F7F7F8', raised: '#FFFFFF', border: '#E5E5E5', text: '#0D0D0D', text2: '#5D5D5D',
    text3: '#8F8F8F', userBubble: '#F4F4F4', codeBg: '#F7F7F8', codeText: '#24292F', accent: '#0D0D0D',
    onAccent: '#FFFFFF', addBg: '#E6F4EA', addText: '#1A7F37', delBg: '#FDECEA', delText: '#CF222E',
    danger: '#CF222E', ok: '#1A7F37'
  };

  @Builder private spansText(spans: AiMdSpan[], size: number, color: string, weight: FontWeight) {
    Text() {
      ForEach(spans, (span: AiMdSpan): void => {
        if (span.code) {
          Span(span.text).fontSize(size - 1).fontFamily('monospace').fontColor(this.palette.codeText)
            .textBackgroundStyle({ color: this.palette.codeBg, radius: 4 })
        } else {
          Span(span.text).fontSize(size).fontColor(color).fontWeight(span.bold ? FontWeight.Bold : weight)
        }
      }, (span: AiMdSpan, index: number): string => index.toString() + ':' + span.text.length.toString() +
        (span.bold ? 'b' : '') + (span.code ? 'c' : ''))
    }
    .fontSize(size).lineHeight(Math.round(size * 1.55)).fontColor(color).fontFamily(AppConfig.fontFamily)
    .width('100%').copyOption(CopyOptions.LocalDevice)
  }

  @Builder private table(rows: string[][]) {
    Scroll() {
      Column() {
        ForEach(rows, (row: string[], r: number): void => {
          Row() {
            ForEach(row, (cell: string, c: number): void => {
              Text(cell).fontSize(this.textSize - 2).lineHeight(Math.round((this.textSize - 2) * 1.4))
                .fontColor(r === 0 ? this.palette.text : this.palette.text2)
                .fontWeight(r === 0 ? FontWeight.Medium : FontWeight.Normal).fontFamily(AppConfig.fontFamily)
                .constraintSize({ minWidth: 72, maxWidth: 220 }).padding({ left: 10, right: 10, top: 7, bottom: 7 })
            }, (cell: string, c: number): string => r.toString() + '-' + c.toString())
          }
          .backgroundColor(r === 0 ? this.palette.surface : Color.Transparent)
          .border({ width: { bottom: r === rows.length - 1 ? 0 : 0.5 }, color: { bottom: this.palette.border } })
        }, (_row: string[], r: number): string => 'tr-' + r.toString())
      }.borderRadius(10).clip(true).border({ width: 0.5, color: this.palette.border })
    }.scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off).width('100%').align(Alignment.Start)
  }

  @Builder private block(block: AiMdBlock) {
    if (block.kind === 'h1' || block.kind === 'h2' || block.kind === 'h3') {
      this.spansText(block.spans, this.textSize + (block.kind === 'h1' ? 5 : block.kind === 'h2' ? 3 : 1),
        this.palette.text, FontWeight.Bold)
    } else if (block.kind === 'bullet' || block.kind === 'number') {
      Row({ space: 6 }) {
        Text(block.kind === 'bullet' ? '•' : block.marker).fontSize(this.textSize)
          .lineHeight(Math.round(this.textSize * 1.55)).fontColor(this.palette.text3)
          .width(block.kind === 'bullet' ? 12 : 24)
        Column() { this.spansText(block.spans, this.textSize, this.palette.text, FontWeight.Normal) }.layoutWeight(1)
      }.width('100%').alignItems(VerticalAlign.Top).padding({ left: block.level * 16 })
    } else if (block.kind === 'quote') {
      Row({ space: 10 }) {
        Column().width(3).height('100%').borderRadius(2).backgroundColor(this.palette.border)
        Column() { this.spansText(block.spans, this.textSize, this.palette.text2, FontWeight.Normal) }.layoutWeight(1)
      }.width('100%').alignItems(VerticalAlign.Top)
    } else if (block.kind === 'rule') {
      Divider().color(this.palette.border).strokeWidth(0.5)
    } else if (block.kind === 'code') {
      Scroll() {
        Text(block.text).fontSize(this.textSize - 2).lineHeight(Math.round((this.textSize - 2) * 1.5))
          .fontColor(this.palette.codeText).fontFamily('monospace').copyOption(CopyOptions.LocalDevice).padding(12)
      }.scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off).width('100%').align(Alignment.Start)
      .borderRadius(10).backgroundColor(this.palette.codeBg).border({ width: 0.5, color: this.palette.border })
    } else if (block.kind === 'table') {
      this.table(block.rows)
    } else {
      this.spansText(block.spans, this.textSize, this.palette.text, FontWeight.Normal)
    }
  }

  build() {
    Column({ space: 8 }) {
      ForEach(aiMarkdownBlocks(this.text), (block: AiMdBlock): void => {
        this.block(block)
      }, (block: AiMdBlock, index: number): string => aiBlockKey(block, index))
    }.width('100%').alignItems(HorizontalAlign.Start)
  }
}
