import { common } from '@kit.AbilityKit';
import { image } from '@kit.ImageKit';
import { promptAction } from '@kit.ArkUI';
import { appUiOnAccentText } from '../../../common/AppUiColorPolicy';
import { Palette, buildDark, buildLight } from '../../../common/Theme';
import { AI_DEVELOPER_EMAIL, AiMailDraft, aiOpenMailEditor } from '../../../services/diagnosticAi/AiMailService';
import {
  SessionFrame,
  captureSessionFrame,
  recognizeSessionFrameText,
  saveSessionFrameToGallery,
  shareSessionEvidence,
  writeSessionEvidenceText,
  writeSessionFramePng
} from '../../../services/pro/evidence/SessionEvidenceService';
import { sessionScreenshotQuestion } from '../../../services/pro/evidence/SessionEvidencePolicy';

type ScreenshotPhase = 'capturing' | 'ready' | 'failed' | 'reading' | 'text' | 'pack';

/**
 * 截屏给 AI 看 / 诊断证据包 (Pro): the remote picture as it is (not the local toolbars), then — read its text on this
 * device and hand it to the AI, save it to 图库, share it, or pack it with the session summary for the developer.
 */
@Component
export struct SessionScreenshotSheet {
  @StorageProp('currentTheme') theme: string = 'light';
  @StorageProp('accentColor') accentColor: string = '#007DFF';
  @Prop rendererHandle: number = 0;
  @Prop protocol: string = '';
  /** The session summary at the moment of the screenshot (SessionEvidencePolicy.sessionEvidenceSummary). */
  @Prop summary: string = '';
  @State private phase: ScreenshotPhase = 'capturing';
  @State private pixels: image.PixelMap | undefined = undefined;
  @State private frameWidth: number = 0;
  @State private frameHeight: number = 0;
  @State private text: string = '';
  @State private message: string = '';
  @State private packScreenshot: boolean = true;
  @State private packSummary: boolean = true;
  @State private busy: boolean = false;
  private frame: SessionFrame | null = null;
  private pngPath: string = '';
  private alive: boolean = true;
  onAskAi: (question: string) => void = (_question: string): void => {};
  onClose: () => void = (): void => {};

  aboutToAppear(): void { void this.capture(); }

  aboutToDisappear(): void {
    this.alive = false;
    const frame: SessionFrame | null = this.frame;
    this.frame = null;
    this.pixels = undefined;
    if (frame !== null) { void frame.pixelMap.release(); }
  }

  private pal(): Palette { return this.theme === 'light' ? buildLight(this.accentColor) : buildDark(this.accentColor); }

  private async capture(): Promise<void> {
    this.phase = 'capturing';
    try {
      const frame: SessionFrame = await captureSessionFrame(this.rendererHandle);
      if (!this.alive) { void frame.pixelMap.release(); return; }
      this.frame = frame;
      this.pixels = frame.pixelMap;
      this.frameWidth = frame.width;
      this.frameHeight = frame.height;
      this.pngPath = await writeSessionFramePng(getContext(this), frame);
      if (this.alive) { this.phase = 'ready'; }
    } catch (_error) {
      if (!this.alive) { return; }
      this.message = '没有截到画面：远端画面还没显示出来，或会话已经断开。稍后再试。';
      this.phase = 'failed';
    }
  }

  private async readText(): Promise<void> {
    if (this.frame === null || this.busy) { return; }
    this.busy = true;
    this.phase = 'reading';
    try {
      const text: string = await recognizeSessionFrameText(this.frame);
      if (!this.alive) { return; }
      this.text = text.trim();
      this.message = this.text === '' ? '画面里没有识别到文字。可以直接打包证据发给开发者。' : '';
      this.phase = 'text';
    } catch (_error) {
      if (!this.alive) { return; }
      this.message = '这台设备不支持本机识别文字。可以保存截图，或打包证据发给开发者。';
      this.phase = 'ready';
    } finally {
      this.busy = false;
    }
  }

  private packPaths(): string[] {
    const paths: string[] = [];
    if (this.packScreenshot && this.pngPath !== '') { paths.push(this.pngPath); }
    if (this.packSummary && this.summary.trim() !== '' && this.frame !== null) {
      paths.push(writeSessionEvidenceText(getContext(this), this.frame.capturedAt, this.summary));
    }
    return paths;
  }

  private async sharePack(): Promise<void> {
    const paths: string[] = this.packPaths();
    if (paths.length === 0) { promptAction.showToast({ message: '至少选一项', duration: 1500 }); return; }
    try {
      await shareSessionEvidence(getContext(this) as common.UIAbilityContext, paths);
    } catch (_error) {
      promptAction.showToast({ message: '无法打开分享面板', duration: 1800 });
    }
  }

  private async mailPack(): Promise<void> {
    const paths: string[] = this.packPaths();
    if (paths.length === 0) { promptAction.showToast({ message: '至少选一项', duration: 1500 }); return; }
    try {
      const note: string = await aiOpenMailEditor(getContext(this) as common.UIAbilityContext, new AiMailDraft(
        [AI_DEVELOPER_EMAIL], 'RemoteDesktop 会话证据包', '附件是会话截图和会话摘要。请在这里补充：发生了什么、你做了哪些操作。\n\n' +
          this.summary, paths));
      if (note !== '') { promptAction.showToast({ message: note, duration: 2600 }); }
    } catch (_error) {
      promptAction.showToast({ message: '没有可用的邮件应用，可以改用「分享」', duration: 2200 });
    }
  }

  @Builder private header(title: string) {
    Row({ space: 10 }) {
      Text(title).fontSize(17).fontWeight(FontWeight.Medium).fontColor(this.pal().text).layoutWeight(1)
      Button() { SymbolGlyph($r('sys.symbol.xmark')).fontSize(16).fontColor([this.pal().text2]) }
        .width(36).height(36).padding(0).backgroundColor(this.pal().surface)
        .onClick(() => { this.onClose(); })
        .accessibilityText('关闭')
    }.width('100%').padding({ left: 16, right: 16, top: 14, bottom: 10 })
  }

  @Builder private preview() {
    Stack() {
      if (this.pixels !== undefined) {
        Image(this.pixels).objectFit(ImageFit.Contain).width('100%').height('100%')
      } else if (this.phase === 'capturing') {
        LoadingProgress().width(32).height(32).color(this.accentColor)
      }
    }
    .width('100%').aspectRatio(this.frameWidth > 0 && this.frameHeight > 0 ? this.frameWidth / this.frameHeight : 16 / 9)
    .constraintSize({ maxHeight: 300 })
    .borderRadius(14).clip(true).backgroundColor(Color.Black)
  }

  build() {
    Column() {
      this.header(this.phase === 'pack' ? '诊断证据包' : this.phase === 'text' ? '交给 AI 看' : '截屏')
      Scroll() {
        Column({ space: 12 }) {
          if (this.phase !== 'text' && this.phase !== 'pack') {
            this.preview()
            if (this.frameWidth > 0) {
              Text('远端画面 ' + this.frameWidth.toString() + ' × ' + this.frameHeight.toString())
                .fontSize(12).fontColor(this.pal().text3).width('100%')
            }
          }
          if (this.message !== '') {
            Text(this.message).fontSize(13).fontColor(this.pal().text2).width('100%')
          }
          if (this.phase === 'ready' || this.phase === 'reading') {
            Button(this.phase === 'reading' ? '正在识别文字…' : '交给 AI 看')
              .width('100%').height(44).fontSize(15)
              .fontColor(appUiOnAccentText(this.accentColor)).backgroundColor(this.accentColor)
              .enabled(this.phase === 'ready').opacity(this.phase === 'ready' ? 1 : 0.6)
              .onClick(() => { void this.readText(); })
            Text('先在本机识别画面里的文字，你确认后只把文字交给 AI，图片不上传。')
              .fontSize(12).fontColor(this.pal().text3).width('100%')
            Row({ space: 10 }) {
              // A security component takes no layoutWeight: its row does.
              Row() {
                SaveButton({ icon: SaveIconStyle.FULL_FILLED, text: SaveDescription.SAVE_IMAGE,
                  buttonType: ButtonType.Capsule })
                  .height(40).width('100%')
                  .onClick((_event: ClickEvent, result: SaveButtonOnClickResult) => {
                    if (result !== SaveButtonOnClickResult.SUCCESS || this.pngPath === '') { return; }
                    saveSessionFrameToGallery(getContext(this), this.pngPath).then(() => {
                      promptAction.showToast({ message: '已保存到图库', duration: 1500 });
                    }).catch(() => {
                      promptAction.showToast({ message: '保存失败', duration: 1500 });
                    });
                  })
              }.layoutWeight(1)
              Button('打包证据').height(40).layoutWeight(1).fontSize(14)
                .fontColor(this.pal().text).backgroundColor(this.pal().surface)
                .onClick(() => { this.phase = 'pack'; })
            }.width('100%')
          }
          if (this.phase === 'failed') {
            Button('再试一次').width('100%').height(44).fontSize(15)
              .fontColor(appUiOnAccentText(this.accentColor)).backgroundColor(this.accentColor)
              .onClick(() => { this.message = ''; void this.capture(); })
          }
          if (this.phase === 'text') {
            Text('识别出的文字（可以修改，发送前不会离开本机）').fontSize(13).fontColor(this.pal().text2).width('100%')
            TextArea({ text: this.text, placeholder: '没有识别到文字' })
              .height(220).fontSize(14)
              .onChange((value: string) => { this.text = value; })
            Row({ space: 10 }) {
              Button('返回').height(42).layoutWeight(1).fontSize(14)
                .fontColor(this.pal().text).backgroundColor(this.pal().surface)
                .onClick(() => { this.phase = 'ready'; this.message = ''; })
              Button('发给 AI').height(42).layoutWeight(1).fontSize(14)
                .fontColor(appUiOnAccentText(this.accentColor)).backgroundColor(this.accentColor)
                .enabled(this.text.trim() !== '').opacity(this.text.trim() !== '' ? 1 : 0.5)
                .onClick(() => { this.onAskAi(sessionScreenshotQuestion(this.text, this.protocol)); })
            }.width('100%')
          }
          if (this.phase === 'pack') {
            Text('选择要带上的内容；默认不上传，由你决定分享给谁。').fontSize(13).fontColor(this.pal().text2).width('100%')
            Row({ space: 10 }) {
              Checkbox().select(this.packScreenshot).selectedColor(this.accentColor)
                .onChange((value: boolean) => { this.packScreenshot = value; })
              Text('远端截图').fontSize(14).fontColor(this.pal().text).layoutWeight(1)
            }.width('100%')
            Row({ space: 10 }) {
              Checkbox().select(this.packSummary).selectedColor(this.accentColor)
                .onChange((value: boolean) => { this.packSummary = value; })
              Text('会话摘要').fontSize(14).fontColor(this.pal().text).layoutWeight(1)
            }.width('100%')
            if (this.packSummary) {
              Text(this.summary).fontSize(12).fontColor(this.pal().text2).width('100%')
                .padding(12).borderRadius(12).backgroundColor(this.pal().surface)
            }
            Row({ space: 10 }) {
              Button('分享').height(42).layoutWeight(1).fontSize(14)
                .fontColor(this.pal().text).backgroundColor(this.pal().surface)
                .onClick(() => { void this.sharePack(); })
              Button('发给开发者').height(42).layoutWeight(1).fontSize(14)
                .fontColor(appUiOnAccentText(this.accentColor)).backgroundColor(this.accentColor)
                .onClick(() => { void this.mailPack(); })
            }.width('100%')
            Button('返回截图').width('100%').height(40).fontSize(14)
              .fontColor(this.pal().text2).backgroundColor(Color.Transparent)
              .onClick(() => { this.phase = 'ready'; })
          }
        }.width('100%').padding({ left: 16, right: 16, bottom: 20 })
      }.layoutWeight(1).scrollBar(BarState.Auto)
    }.width('100%').height('100%').backgroundColor(this.pal().sheetBg)
  }
}
