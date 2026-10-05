import { ComponentContent } from '@kit.ArkUI';
import { AppConfig, Palette, buildDark, buildLight } from '../../../common/Theme';

/** What the phone's confirmation dialog shows. `onAnswer` is set by PasskeyConfirmation and runs once. */
export class PasskeyDialogParams {
  title: string = '';
  message: string = '';
  /** Pairing: the six digits both devices show; '' otherwise. */
  code: string = '';
  cancel: string = '拒绝';
  confirm: string = '允许';
  /** When the request expires (ms since epoch); the dialog counts down to it and then closes as a refusal. */
  deadline: number = 0;
  onAnswer: (allowed: boolean) => void = (_allowed: boolean): void => {};
}

@Component
struct ProPasskeyConfirmCard {
  @StorageProp('currentTheme') theme: string = 'light';
  @StorageProp('accentColor') accent: string = '#007DFF';
  params: PasskeyDialogParams = new PasskeyDialogParams();
  @State remaining: number = 0;
  private timer: number = -1;

  aboutToAppear(): void {
    this.tick();
    this.timer = setInterval((): void => { this.tick(); }, 1000);
  }

  aboutToDisappear(): void {
    if (this.timer >= 0) { clearInterval(this.timer); this.timer = -1; }
  }

  private tick(): void { this.remaining = Math.max(0, Math.ceil((this.params.deadline - Date.now()) / 1000)); }

  private pal(): Palette { return this.theme === 'light' ? buildLight(this.accent) : buildDark(this.accent); }

  build() {
    Column({ space: 14 }) {
      Text(this.params.title).fontSize(18).fontWeight(FontWeight.Medium).fontFamily(AppConfig.fontFamily)
        .fontColor(this.pal().text).width('100%')
      Text(this.params.message).fontSize(14).lineHeight(21).fontFamily(AppConfig.fontFamily).fontColor(this.pal().text2)
        .width('100%')
      if (this.params.code !== '') {
        Text(this.params.code).fontSize(34).fontWeight(FontWeight.Bold).fontFamily('monospace').letterSpacing(4)
          .fontColor(this.pal().text).width('100%').textAlign(TextAlign.Center).padding({ top: 4, bottom: 4 })
      }
      Text(this.remaining.toString() + ' 秒后自动' + this.params.cancel).fontSize(12).fontFamily(AppConfig.fontFamily)
        .fontColor(this.pal().text3).width('100%')
      Row({ space: 12 }) {
        Button(this.params.cancel).layoutWeight(1).height(44).fontSize(15).fontFamily(AppConfig.fontFamily)
          .fontColor(this.pal().text).backgroundColor(this.pal().surface)
          .onClick((): void => { this.params.onAnswer(false); })
        Button(this.params.confirm).layoutWeight(1).height(44).fontSize(15).fontFamily(AppConfig.fontFamily)
          .fontColor('#FFFFFF').backgroundColor(this.accent)
          .onClick((): void => { this.params.onAnswer(true); })
      }.width('100%').padding({ top: 4 })
    }
    .width('88%').constraintSize({ maxWidth: 420 }).padding(24).borderRadius(24)
    .backgroundColor(this.pal().sheetBg)
    .shadow({ radius: 24, color: '#33000000', offsetY: 6 })
  }
}

@Builder
function passkeyConfirmLayer(params: PasskeyDialogParams) {
  ProPasskeyConfirmCard({ params: params })
}

/**
 * One confirmation on the phone. `answer` resolves once: with the user's choice, or false when the request expires,
 * is withdrawn (close()) or the dialog is dismissed. The dialog is taken down in every case.
 */
export class PasskeyConfirmation {
  readonly answer: Promise<boolean>;
  private finish: (allowed: boolean) => void = (_allowed: boolean): void => {};

  constructor(ui: UIContext, params: PasskeyDialogParams) {
    let settle: (allowed: boolean) => void = (_allowed: boolean): void => {};
    this.answer = new Promise<boolean>((resolve: (allowed: boolean) => void): void => { settle = resolve; });
    let done: boolean = false;
    let opened: boolean = false;
    let timer: number = -1;
    let content: ComponentContent<PasskeyDialogParams> | null = null;
    const takeDown = (shown: ComponentContent<PasskeyDialogParams>): void => {
      ui.getPromptAction().closeCustomDialog(shown).catch((): void => { /* already closed */ })
        .finally((): void => { shown.dispose(); });
    };
    const finish = (allowed: boolean): void => {
      if (done) { return; }
      done = true;
      if (timer >= 0) { clearTimeout(timer); timer = -1; }
      // A dialog still opening is taken down as soon as it has opened.
      if (content !== null && opened) { takeDown(content); }
      settle(allowed);
    };
    this.finish = finish;
    params.onAnswer = finish;
    timer = setTimeout((): void => { finish(false); }, Math.max(0, params.deadline - Date.now()));
    try {
      const created: ComponentContent<PasskeyDialogParams> = new ComponentContent(ui, wrapBuilder(passkeyConfirmLayer), params);
      content = created;
      ui.getPromptAction().openCustomDialog(created, {
        isModal: true, autoCancel: false, alignment: DialogAlignment.Center,
        // Back or a tap outside refuses, like the refuse button.
        onWillDismiss: (_action: DismissDialogAction): void => { finish(false); }
      }).then((): void => {
        opened = true;
        if (done) { takeDown(created); }
      }).catch((): void => {
        created.dispose();
        finish(false);
      });
    } catch (_error) {
      finish(false);
    }
  }

  /** The request went away (withdrawn, expired elsewhere): refuse and take the dialog down. */
  close(): void { this.finish(false); }
}
