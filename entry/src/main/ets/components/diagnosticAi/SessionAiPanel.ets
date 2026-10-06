import { common } from '@kit.AbilityKit';
import { display } from '@kit.ArkUI';
import { appUiOnAccentText } from '../../common/AppUiColorPolicy';
import { Palette, buildDark, buildLight } from '../../common/Theme';
import { AiSegmented } from './AiSegmented';
import { AiVoiceConfig, AiVoiceSettings } from '../../services/diagnosticAi/AiVoiceSettings';
import { AI_SESSION_REPLY_MODES } from '../../services/diagnosticAi/AiSessionVoicePolicy';

/** What SessionAiHost hands its AI 控制面板. */
export class SessionAiPanelParams {
  owner: string = 'device-local';
  /** The AI is up in this session now (the button at the foot then closes it). */
  aiOpen: boolean = false;
  /** Voice mode: now, while the AI is up; otherwise how it will start. */
  talking: boolean = false;
  onVoiceMode: (on: boolean) => void = (_on: boolean): void => {};
  /** The foot button: start the AI as set here, or close it. */
  onStartOrClose: () => void = (): void => {};
  onClose: () => void = (): void => {};
}

@Builder
export function sessionAiPanel(params: SessionAiPanelParams) {
  SessionAiPanel({ params: params })
}

/**
 * AI 控制面板 of a remote session, from its AI button (or a long press on it, with 点 AI 按钮直接启动 on): how the AI
 * talks here — 语音模式, 连接中语音回答, 连续对话, AI 语音 itself — and whether the button starts the AI at once. The
 * button at its foot starts the AI as set, or closes it while it is up. Settings are the account's AI 语音 ones.
 */
@Component
struct SessionAiPanel {
  @StorageProp('currentTheme') theme: string = 'light';
  @StorageProp('accentColor') accent: string = '#007DFF';
  params: SessionAiPanelParams = new SessionAiPanelParams();
  @State private config: AiVoiceConfig = new AiVoiceConfig();
  @State private talking: boolean = false;
  @State private bodyMax: number = 420;
  private readonly settings: AiVoiceSettings = new AiVoiceSettings();

  aboutToAppear(): void {
    this.settings.init(this.getUIContext().getHostContext() as common.UIAbilityContext, this.params.owner);
    this.config = this.settings.read();
    this.talking = this.params.talking && this.config.enabled;
    try {
      const screen: display.Display = display.getDefaultDisplaySync();
      // Room for the title and the foot button on a phone held sideways too.
      this.bodyMax = Math.max(140, this.getUIContext().px2vp(screen.height) - 190);
    } catch (_error) { /* keep the default */ }
  }

  private pal(): Palette { return this.theme === 'light' ? buildLight(this.accent) : buildDark(this.accent); }

  private reload(): void { this.config = this.settings.read(); }

  private setTalking(on: boolean): void {
    this.talking = on;
    this.params.onVoiceMode(on);
  }

  @Builder private switchRow(title: string, detail: string, on: boolean, enabled: boolean, change: (on: boolean) => void) {
    Row({ space: 10 }) {
      Column({ space: 3 }) {
        Text(title).fontSize(15).fontWeight(FontWeight.Medium).fontColor(this.pal().text)
        Text(detail).fontSize(12).lineHeight(17).fontColor(this.pal().text3)
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      Toggle({ type: ToggleType.Switch, isOn: on }).selectedColor(this.accent).enabled(enabled)
        .onChange((value: boolean): void => { change(value); })
    }.width('100%').constraintSize({ minHeight: 44 }).padding({ top: 10, bottom: 10 }).opacity(enabled ? 1 : 0.5)
  }

  build() {
    Column({ space: 12 }) {
      Row() {
        Column({ space: 2 }) {
          Text('AI 助理').fontSize(18).fontWeight(FontWeight.Bold).fontColor(this.pal().text)
          Text(this.params.aiOpen ? (this.talking ? 'AI 开着 · 语音模式' : 'AI 开着 · 文字') : '设置好后点下面的按钮启动')
            .fontSize(12).fontColor(this.pal().text3)
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        Button() {
          SymbolGlyph($r('sys.symbol.xmark')).fontSize(18).fontColor([this.pal().text2])
        }
        .width(44).height(44).padding(0).backgroundColor(this.pal().surface)
        .accessibilityText('关闭 AI 控制面板')
        .onClick((): void => { this.params.onClose(); })
      }.width('100%')
      Scroll() {
        Column({ space: 12 }) {
          Column() { this.voiceCard() }
            .width('100%').padding({ left: 14, right: 14 }).borderRadius(16).backgroundColor(this.pal().card)
          if (this.config.enabled) {
            Column() { this.replyCard() }
              .width('100%').padding({ left: 14, right: 14 }).borderRadius(16).backgroundColor(this.pal().card)
          }
          Column() { this.buttonCard() }
            .width('100%').padding({ left: 14, right: 14 }).borderRadius(16).backgroundColor(this.pal().card)
        }.width('100%')
      }
      .constraintSize({ maxHeight: this.bodyMax })
      .scrollBar(BarState.Off).edgeEffect(EdgeEffect.Spring).align(Alignment.Top)
      Button(this.params.aiOpen ? '关闭 AI' : (this.talking ? '启动 AI（语音模式）' : '启动 AI'))
        .width('100%').height(48).fontSize(16).fontWeight(FontWeight.Medium)
        .fontColor(this.params.aiOpen ? this.pal().danger : appUiOnAccentText(this.accent))
        .backgroundColor(this.params.aiOpen ? this.pal().surface : this.accent)
        .onClick((): void => { this.params.onStartOrClose(); })
    }
    .width('100%').constraintSize({ maxWidth: 420 })
    .padding({ left: 16, right: 16, top: 14, bottom: 16 })
    .borderRadius(24).backgroundColor(this.pal().sheetBg)
  }

  @Builder private voiceCard() {
    this.switchRow('AI 语音', '对悬浮球说话、朗读回答都需要先打开', this.config.enabled, true,
      (on: boolean): void => {
        this.settings.setEnabled(on);
        this.reload();
        if (!on && this.talking) { this.setTalking(false); }
      })
    Divider().color(this.pal().divider)
    this.switchRow('语音模式', '每个回答都读出来，读完接着听你说；双击悬浮球或在这里关闭就退出', this.talking,
      this.config.enabled, (on: boolean): void => { this.settings.setSessionStartVoice(on); this.setTalking(on); })
  }

  @Builder private replyCard() {
    Column({ space: 10 }) {
      Text('不在语音模式时').fontSize(13).fontColor(this.pal().text3).width('100%')
      AiSegmented({ options: AI_SESSION_REPLY_MODES, current: this.config.sessionReply,
        trackColor: this.pal().surface, textColor: this.pal().text, segmentHeight: 36,
        onPick: (mode: string): void => { this.settings.setSessionReply(mode); this.reload(); } })
    }.width('100%').padding({ top: 12, bottom: 12 })
    Divider().color(this.pal().divider)
    this.switchRow('连续对话', '语音模式下回答读完接着听', this.config.continuous, true,
      (on: boolean): void => { this.settings.setContinuous(on); this.reload(); })
  }

  @Builder private buttonCard() {
    this.switchRow('点 AI 按钮直接启动', '开启后点侧栏的 AI 按钮直接按这里的设置启动或关闭 AI，长按 AI 按钮打开这个面板',
      this.config.sessionQuickStart, true,
      (on: boolean): void => { this.settings.setSessionQuickStart(on); this.reload(); })
  }
}
