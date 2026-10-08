import { common } from '@kit.AbilityKit';
import { appUiOnAccentText } from '../../common/AppUiColorPolicy';
import { Palette, buildDark, buildLight } from '../../common/Theme';
import { AiSegmented } from './AiSegmented';
import { AiVoiceConfig, AiVoiceSettings, AiTtsProvider, aiTtsProvider } from '../../services/diagnosticAi/AiVoiceSettings';
import { AI_SESSION_REPLY_MODES } from '../../services/diagnosticAi/AiSessionVoicePolicy';
import { DiagnosticAiProfileStore } from '../../services/diagnosticAi/DiagnosticAiProfileStore';
import { DiagnosticAiProviderProfile } from '../../services/diagnosticAi/DiagnosticAiModels';
import { DiagnosticAiAssistantPreferences, DiagnosticAiConversationStore } from '../../services/diagnosticAi/DiagnosticAiConversationStore';
import { AiSkillStore } from '../../services/diagnosticAi/AiSkillStore';
import { AiSettingChoice, AiSettingSpec, diagnosticAiSettingSpec } from '../../services/diagnosticAi/DiagnosticAiSettingsActionPolicy';
import { DiagnosticAiMotionStore } from '../../services/diagnosticAi/DiagnosticAiMotionPolicy';

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
  /** 开始新对话 (only while the AI is up). */
  onNewChat: () => void = (): void => {};
  onClose: () => void = (): void => {};
}

@Builder
export function sessionAiPanel(params: SessionAiPanelParams) {
  SessionAiPanel({ params: params })
}

const AI_PANEL_STYLES: string[][] = [['balanced', '均衡'], ['warm', '温和'], ['concise', '简洁'], ['technical', '技术']];
const AI_PANEL_LENGTHS: string[][] = [['concise', '简短'], ['standard', '标准'], ['detailed', '详细']];
const AI_PANEL_RATES: string[][] = [['slow', '慢'], ['normal', '正常'], ['fast', '快']];

function choicePairs(id: string): string[][] {
  const spec: AiSettingSpec | undefined = diagnosticAiSettingSpec(id);
  return spec === undefined ? [] : spec.choices.map((c: AiSettingChoice): string[] => [c.value, c.label]);
}

/**
 * AI 控制面板 of a remote session, a sheet from its AI button (or a long press on it, with 点 AI 按钮直接启动 on): how
 * the AI starts here, which model answers and how, how it talks (AI 语音, 语音模式, 连接中语音回答, 连续对话, 语速, 声音)
 * and how it looks (AI 风格, 悬浮球样式). The button at its foot starts the AI as set, or closes it while it is up. All
 * of it is the account's own AI settings — the same ones 设置 › AI 助理 / AI 语音 change.
 */
@Component
struct SessionAiPanel {
  @StorageProp('currentTheme') theme: string = 'light';
  @StorageProp('accentColor') accent: string = '#007DFF';
  @StorageProp('aiStyle') aiStyle: string = 'siri';
  @StorageProp('aiMotion.orb') orbStyle: string = 'voice';
  params: SessionAiPanelParams = new SessionAiPanelParams();
  @State private config: AiVoiceConfig = new AiVoiceConfig();
  @State private talking: boolean = false;
  @State private profiles: DiagnosticAiProviderProfile[] = [];
  @State private profileId: string = '';
  @State private prefs: DiagnosticAiAssistantPreferences | null = null;
  @State private webOn: boolean = false;
  private readonly settings: AiVoiceSettings = new AiVoiceSettings();
  private readonly profileStore: DiagnosticAiProfileStore = new DiagnosticAiProfileStore();
  private readonly conversationStore: DiagnosticAiConversationStore = new DiagnosticAiConversationStore();
  private readonly skillStore: AiSkillStore = new AiSkillStore();

  aboutToAppear(): void {
    const context: common.UIAbilityContext = this.context();
    this.settings.init(context, this.params.owner);
    this.profileStore.init(context, this.params.owner);
    this.conversationStore.init(context, this.params.owner);
    this.skillStore.init(context, this.params.owner);
    this.config = this.settings.read();
    this.talking = this.params.talking && this.config.enabled;
    this.loadProfiles();
    try { this.prefs = this.conversationStore.assistantPreferences(); } catch (_error) { this.prefs = null; }
    this.webOn = this.skillStore.toolEnabled('web.search');
  }

  private context(): common.UIAbilityContext { return this.getUIContext().getHostContext() as common.UIAbilityContext; }
  private pal(): Palette { return this.theme === 'light' ? buildLight(this.accent) : buildDark(this.accent); }
  private reload(): void { this.config = this.settings.read(); }

  private loadProfiles(): void {
    try {
      this.profiles = this.profileStore.list().filter((p: DiagnosticAiProviderProfile): boolean => p.modelId !== '');
      const s = this.profileStore.settingsSnapshot();
      const chosen: DiagnosticAiProviderProfile | undefined = this.profiles.find((p: DiagnosticAiProviderProfile): boolean =>
        p.providerId === s.selectedProviderId && p.modelId === s.selectedModelId &&
        (s.selectedAuthMode === '' || p.authMode === s.selectedAuthMode));
      this.profileId = chosen !== undefined ? chosen.id : (this.profiles.length === 1 ? this.profiles[0].id : '');
    } catch (_error) { this.profiles = []; }
  }

  /** The model that answers (the next question goes to it). */
  private pickProfile(id: string): void {
    const profile: DiagnosticAiProviderProfile | undefined = this.profiles.find((p: DiagnosticAiProviderProfile): boolean => p.id === id);
    if (profile === undefined) { return; }
    const next = this.profileStore.settingsSnapshot();
    next.selectedProviderId = profile.providerId;
    next.selectedModelId = profile.modelId;
    next.selectedAuthMode = profile.authMode;
    if (this.profileStore.saveSettings(next)) { this.profileId = id; }
  }

  private savePrefs(change: (p: DiagnosticAiAssistantPreferences) => void): void {
    if (this.prefs === null) { return; }
    const next: DiagnosticAiAssistantPreferences = this.conversationStore.assistantPreferences();
    change(next);
    next.updatedAt = Date.now();
    if (this.conversationStore.saveAssistantPreferences(next)) { this.prefs = next; }
  }

  private setWeb(on: boolean): void {
    this.skillStore.setToolEnabled('web.search', on);
    this.skillStore.setToolEnabled('web.read', on);
    this.webOn = this.skillStore.toolEnabled('web.search');
  }

  private setTalking(on: boolean): void {
    this.talking = on;
    this.params.onVoiceMode(on);
  }

  private profileLabel(p: DiagnosticAiProviderProfile): string {
    return p.displayName !== '' && p.displayName !== p.modelId ? p.displayName + ' · ' + p.modelId : p.modelId;
  }

  @Builder private section(title: string) {
    Text(title).fontSize(14).fontWeight(FontWeight.Bold).fontColor(this.pal().text2).width('100%')
      .padding({ left: 4, top: 6 })
  }

  @Builder private switchRow(title: string, detail: string, on: boolean, enabled: boolean, change: (on: boolean) => void) {
    Row({ space: 10 }) {
      Column({ space: 3 }) {
        Text(title).fontSize(16).fontWeight(FontWeight.Medium).fontColor(this.pal().text)
        if (detail !== '') {
          Text(detail).fontSize(13).lineHeight(19).fontColor(this.pal().text2)
        }
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      Toggle({ type: ToggleType.Switch, isOn: on }).selectedColor(this.accent).enabled(enabled)
        .onChange((value: boolean): void => { change(value); })
    }.width('100%').constraintSize({ minHeight: 48 }).padding({ top: 8, bottom: 8 }).opacity(enabled ? 1 : 0.5)
  }

  @Builder private segmentRow(title: string, options: string[][], current: string, pick: (id: string) => void) {
    Column({ space: 8 }) {
      Text(title).fontSize(16).fontWeight(FontWeight.Medium).fontColor(this.pal().text).width('100%')
      // The chosen one in the accent with its own readable text; the others in the normal text colour.
      AiSegmented({ options: options, current: current, trackColor: this.pal().surface,
        thumbColor: this.accent, textColor: appUiOnAccentText(this.accent), mutedColor: this.pal().text,
        segmentHeight: 40, labelSize: 15, onPick: (id: string): void => { pick(id); } })
    }.width('100%').padding({ top: 10, bottom: 12 })
  }

  @Builder private chipRow(title: string, options: string[][], current: string, pick: (id: string) => void) {
    Column({ space: 8 }) {
      Text(title).fontSize(16).fontWeight(FontWeight.Medium).fontColor(this.pal().text).width('100%')
      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach(options, (option: string[]): void => {
          Text(option[1]).fontSize(14).fontWeight(option[0] === current ? FontWeight.Medium : FontWeight.Regular)
            .fontColor(option[0] === current ? appUiOnAccentText(this.accent) : this.pal().text)
            .padding({ left: 14, right: 14 }).height(40).margin({ right: 8, bottom: 8 }).borderRadius(20)
            .backgroundColor(option[0] === current ? this.accent : this.pal().surface)
            .border({ width: 1, color: option[0] === current ? this.accent : this.pal().divider })
            .accessibilityText(option[1] + (option[0] === current ? '，已选中' : ''))
            .onClick((): void => { pick(option[0]); })
        }, (option: string[]): string => option[0] + (option[0] === current ? '-on' : ''))
      }.width('100%')
    }.width('100%').padding({ top: 10, bottom: 4 })
  }

  build() {
    Column({ space: 10 }) {
      Row() {
        Column({ space: 2 }) {
          Text('AI 助理').fontSize(20).fontWeight(FontWeight.Bold).fontColor(this.pal().text)
          Text(this.params.aiOpen ? (this.talking ? 'AI 开着 · 语音模式' : 'AI 开着 · 文字') : '设置好后点下面的按钮启动')
            .fontSize(13).fontColor(this.pal().text2)
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        Button() {
          SymbolGlyph($r('sys.symbol.xmark')).fontSize(18).fontColor([this.pal().text2])
        }
        .width(44).height(44).padding(0).backgroundColor(this.pal().surface)
        .accessibilityText('关闭 AI 控制面板')
        .onClick((): void => { this.params.onClose(); })
      }.width('100%').padding({ top: 4 })
      Scroll() {
        Column({ space: 10 }) {
          this.section('启动')
          Column() {
            this.switchRow('语音模式', this.config.enabled ? '每个回答都读出来，读完接着听；双击悬浮球或在这里关闭就退出' :
              '先在下面打开 AI 语音', this.talking, this.config.enabled,
              (on: boolean): void => { this.settings.setSessionStartVoice(on); this.setTalking(on); })
            Divider().color(this.pal().divider)
            this.switchRow('点 AI 按钮直接启动', '开启后点侧栏的 AI 按钮直接启动或关闭 AI，长按 AI 按钮打开这个面板',
              this.config.sessionQuickStart, true,
              (on: boolean): void => { this.settings.setSessionQuickStart(on); this.reload(); })
            if (this.params.aiOpen) {
              Divider().color(this.pal().divider)
              Row() {
                Text('开始新对话').fontSize(16).fontWeight(FontWeight.Medium).fontColor(this.pal().text).layoutWeight(1)
                SymbolGlyph($r('sys.symbol.plus')).fontSize(20).fontColor([this.pal().text])
              }.width('100%').height(48)
              .accessibilityText('开始新对话，当前对话保存在对话记录里')
              .onClick((): void => { this.params.onNewChat(); })
            }
          }.width('100%').padding({ left: 14, right: 14 }).borderRadius(16).backgroundColor(this.pal().card)

          this.section('回答')
          Column() {
            if (this.profiles.length > 1) {
              this.chipRow('模型', this.profiles.map((p: DiagnosticAiProviderProfile): string[] => [p.id, this.profileLabel(p)]),
                this.profileId, (id: string): void => { this.pickProfile(id); })
              Divider().color(this.pal().divider)
            } else if (this.profiles.length === 1) {
              Row() {
                Text('模型').fontSize(16).fontWeight(FontWeight.Medium).fontColor(this.pal().text)
                Text(this.profileLabel(this.profiles[0])).fontSize(14).fontColor(this.pal().text2)
                  .layoutWeight(1).textAlign(TextAlign.End).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
              }.width('100%').height(48)
              Divider().color(this.pal().divider)
            }
            if (this.prefs !== null) {
              this.segmentRow('回答风格', AI_PANEL_STYLES, (this.prefs as DiagnosticAiAssistantPreferences).personality,
                (id: string): void => {
                  this.savePrefs((p: DiagnosticAiAssistantPreferences): void => {
                    p.personality = id as 'balanced' | 'warm' | 'concise' | 'technical';
                  });
                })
              Divider().color(this.pal().divider)
              this.segmentRow('回答长度', AI_PANEL_LENGTHS, (this.prefs as DiagnosticAiAssistantPreferences).verbosity,
                (id: string): void => {
                  this.savePrefs((p: DiagnosticAiAssistantPreferences): void => {
                    p.verbosity = id as 'concise' | 'standard' | 'detailed';
                  });
                })
              Divider().color(this.pal().divider)
            }
            this.switchRow('联网搜索', '需要最新信息时让 AI 搜索网页（只发送搜索词）', this.webOn, true,
              (on: boolean): void => { this.setWeb(on); })
          }.width('100%').padding({ left: 14, right: 14 }).borderRadius(16).backgroundColor(this.pal().card)

          this.section('语音')
          Column() {
            this.switchRow('AI 语音', '对悬浮球说话、朗读回答都需要先打开', this.config.enabled, true,
              (on: boolean): void => {
                this.settings.setEnabled(on);
                this.reload();
                if (!on && this.talking) { this.setTalking(false); }
              })
            if (this.config.enabled) {
              Divider().color(this.pal().divider)
              this.segmentRow('不在语音模式时', AI_SESSION_REPLY_MODES, this.config.sessionReply,
                (mode: string): void => { this.settings.setSessionReply(mode); this.reload(); })
              Divider().color(this.pal().divider)
              this.switchRow('连续对话', '语音模式下回答读完接着听', this.config.continuous, true,
                (on: boolean): void => { this.settings.setContinuous(on); this.reload(); })
              Divider().color(this.pal().divider)
              this.segmentRow('朗读语速', AI_PANEL_RATES, this.config.rate,
                (rate: string): void => { this.settings.setRate(rate); this.reload(); })
              if (this.voices().length > 1) {
                Divider().color(this.pal().divider)
                this.chipRow('声音（' + aiTtsProvider(this.config.provider).name + '）', this.voices(), this.config.voice,
                  (voice: string): void => { this.settings.setVoice(this.config.provider, voice); this.reload(); })
              }
            }
          }.width('100%').padding({ left: 14, right: 14 }).borderRadius(16).backgroundColor(this.pal().card)

          this.section('外观')
          Column() {
            this.segmentRow('AI 风格', choicePairs('ai.style'), this.aiStyle,
              (style: string): void => { DiagnosticAiMotionStore.save(this.context(), 'aiStyle', style); })
            Divider().color(this.pal().divider)
            this.chipRow('悬浮球样式', choicePairs('ai.motion.orb'), this.orbStyle,
              (orb: string): void => { DiagnosticAiMotionStore.save(this.context(), 'aiMotion.orb', orb); })
          }.width('100%').padding({ left: 14, right: 14 }).borderRadius(16).backgroundColor(this.pal().card)
          Text('这些都是本账号的 AI 设置，「设置 → AI 助理」里改的是同一份；引擎、密钥和语音识别在「设置 → AI 语音」。')
            .fontSize(13).lineHeight(19).fontColor(this.pal().text2).width('100%').padding({ left: 4, right: 4, bottom: 8 })
        }.width('100%')
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off).edgeEffect(EdgeEffect.Spring).align(Alignment.Top)
      Button(this.params.aiOpen ? '关闭 AI' : (this.talking ? '启动 AI（语音模式）' : '启动 AI'))
        .width('100%').height(50).fontSize(17).fontWeight(FontWeight.Bold)
        .fontColor(this.params.aiOpen ? this.pal().danger : appUiOnAccentText(this.accent))
        .backgroundColor(this.params.aiOpen ? this.pal().surface : this.accent)
        .onClick((): void => { this.params.onStartOrClose(); })
    }
    .width('100%').height('100%')
    .padding({ left: 16, right: 16, top: 8, bottom: 16 })
  }

  /** The chosen engine's voices ([id, label]). */
  private voices(): string[][] {
    const provider: AiTtsProvider = aiTtsProvider(this.config.provider);
    return provider.voices;
  }
}
