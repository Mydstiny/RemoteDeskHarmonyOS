import { appUiOnAccentText } from '../../../common/AppUiColorPolicy';
import { Palette, buildDark, buildLight } from '../../../common/Theme';

/**
 * 屏幕文字交给 AI (Pro, SSH): the text on the terminal screen, editable; only what the user sends reaches the AI.
 */
@Component
export struct SessionTextToAiSheet {
  @StorageProp('currentTheme') theme: string = 'light';
  @StorageProp('accentColor') accentColor: string = '#007DFF';
  @Prop title: string = '屏幕文字交给 AI';
  @Prop note: string = '这是终端当前屏幕上的文字。可以删掉不想给 AI 看的部分（例如密码、内网地址），只有你发送的文字会交给 AI。';
  @Prop initialText: string = '';
  @State private text: string = '';
  onSend: (text: string) => void = (_text: string): void => {};
  onClose: () => void = (): void => {};

  aboutToAppear(): void { this.text = this.initialText; }

  private pal(): Palette { return this.theme === 'light' ? buildLight(this.accentColor) : buildDark(this.accentColor); }

  build() {
    Column({ space: 12 }) {
      Row({ space: 10 }) {
        Text(this.title).fontSize(17).fontWeight(FontWeight.Medium).fontColor(this.pal().text).layoutWeight(1)
        Button() { SymbolGlyph($r('sys.symbol.xmark')).fontSize(16).fontColor([this.pal().text2]) }
          .width(36).height(36).padding(0).backgroundColor(this.pal().surface)
          .onClick(() => { this.onClose(); })
          .accessibilityText('关闭')
      }.width('100%')
      Text(this.note).fontSize(12).fontColor(this.pal().text3).width('100%')
      TextArea({ text: this.text, placeholder: '屏幕上没有文字' })
        .layoutWeight(1).constraintSize({ minHeight: 160 }).fontSize(13)
        .fontFamily('monospace')
        .onChange((value: string) => { this.text = value; })
      Row({ space: 10 }) {
        Button('取消').height(42).layoutWeight(1).fontSize(14)
          .fontColor(this.pal().text).backgroundColor(this.pal().surface)
          .onClick(() => { this.onClose(); })
        Button('发给 AI').height(42).layoutWeight(1).fontSize(14)
          .fontColor(appUiOnAccentText(this.accentColor)).backgroundColor(this.accentColor)
          .enabled(this.text.trim() !== '').opacity(this.text.trim() !== '' ? 1 : 0.5)
          .onClick(() => { this.onSend(this.text); })
      }.width('100%')
    }
    .width('100%').height('100%').padding({ left: 16, right: 16, top: 14, bottom: 16 })
    .backgroundColor(this.pal().sheetBg)
  }
}
