import { common } from '@kit.AbilityKit';
import { displaySync } from '@kit.ArkGraphics2D';
import { curves, display, window } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { AiThinkingIndicator } from './AiMotionViews';
import { AiSiriBand } from './AiSiriBand';
import { AiChatMemory, AiChatMessage, aiChatAllowed, aiChatAppData, aiChatErrorText, aiChatOwnerStill, aiChatPreferenceText,
  aiChatRecordUsage, aiChatSaveSession, aiChatSelectedProfile, aiChatTurnText, newMessageId } from './AiChatView';
import { DiagnosticAiProviderProfile } from '../../services/diagnosticAi/DiagnosticAiModels';
import { DiagnosticAiProfileStore } from '../../services/diagnosticAi/DiagnosticAiProfileStore';
import { diagnosticAiProviderIsHarmonyLocal } from '../../services/diagnosticAi/DiagnosticAiProviderCatalog';
import { DiagnosticAiAssistantPreferences, DiagnosticAiConversationStore, defaultDiagnosticAiAssistantPreferences } from '../../services/diagnosticAi/DiagnosticAiConversationStore';
import { DiagnosticAiModelCatalog } from '../../services/diagnosticAi/DiagnosticAiModelCatalog';
import { AiChatReply, AiChatService, AiChatTurn } from '../../services/diagnosticAi/AiChatService';
import { AI_ASSISTANT_HANDOFF, AI_FLOAT_REQUEST, AI_HANDOVER_FADE_DELAY_MS, AI_HANDOVER_FADE_MS, AI_HANDOVER_RECT, AI_MODE_REQUEST } from '../../services/diagnosticAi/AiBridgeKeys';
import { AiSkillStore } from '../../services/diagnosticAi/AiSkillStore';
import { aiThinkingPhrases } from '../../services/diagnosticAi/AiSkillCatalog';
import { aiModeCommand, aiQuestionIsAboutApp, aiQuestionIsFeatureIdea } from '../../services/diagnosticAi/AiChatRoutePolicy';
import { DiagnosticAiAgentMode, DiagnosticAiAgentService, diagnosticAiAgentModeForQuestion } from '../../services/diagnosticAi/DiagnosticAiAgentService';
import { DiagnosticAiResult, DiagnosticAiSettingProposal } from '../../services/diagnosticAi/DiagnosticAiModels';
import { AiSettingChoice, diagnosticAiProposalChoice, diagnosticAiProposalIsSafe, diagnosticAiSettingActionText, diagnosticAiSettingCurrent, diagnosticAiSettingIntents } from '../../services/diagnosticAi/DiagnosticAiSettingsActionPolicy';
import { diagnosticAiAppActionId, diagnosticAiAppActionLabel } from '../../services/diagnosticAi/DiagnosticAiAppActionPolicy';
import { AiMdBlock, AiMdSpan, aiMarkdownBlocks } from '../../services/diagnosticAi/AiMarkdownPolicy';
import { AiChatAction, aiActionErrorText, aiRunAction } from '../../services/diagnosticAi/AiSystemTools';
import { AiReadAloud, AiVoiceInput } from '../../services/diagnosticAi/AiSpeech';
import { AiVoiceConfig, AiVoiceSettings } from '../../services/diagnosticAi/AiVoiceSettings';
import { aiChatRefresh } from '../../services/diagnosticAi/AiShareInbox';
import { AiDocument } from '../../services/diagnosticAi/AiDocumentService';
import { aiIsSessionPage } from '../../services/diagnosticAi/AiSessionRouter';

/** AppStorage: 按住说话 presses on the AI button ('down:<time>' / 'up:<time>'). */
export const AI_VOICE_HOLD_EVENT: string = 'aiVoice.hold';

/** Same logical canvas as the island (AiIsland): phones scale by width. */
const AI_REF_WIDTH: number = 375;
const YES: RegExp = /^(好|好的|好啊|确认|可以|行|是的|是|对|嗯|没问题|执行|去吧)[。！!.]*$/;
const NO: RegExp = /^(不|不要|取消|算了|不用)[。！!.]*$/;

/**
 * Talking over the answer: the echo-cancelled microphone this loud (0…1) for this long stops the voice. With only the
 * answer playing it reads 0.00–0.01 (the echo is removed), so a normal voice is enough.
 */
const AI_BARGE_LEVEL: number = 0.3;
const AI_BARGE_MS: number = 160;

/** What voice mode asks of the model on top of the usual chat instructions. */
const VOICE_STYLE: string = '。当前是语音对话（像 Siri 一样）：回答显示在没有输入框的面板里，同时被朗读出来。先用一两句口语说结论，' +
  '需要时再给简短的要点；不要长篇大论、不要写网址。能用工具办到的事就直接调用工具（发消息、打电话、导航、提醒、改设置、打开页面、' +
  '交给助理诊断等），它们会变成面板里的卡片让用户确认，并用一句话说明要做什么、请用户说“好的”或点确认';

/**
 * Siri-style voice mode (AI 语音, Beta), over the page like the AI island and anchored on the same camera island.
 *
 * listen — the island swells into a liquid-glass droplet: a dark core inside a clear rim, a light band across its
 *          middle that flows and grows with the user's voice (the microphone level, measured as it records);
 * think  — the droplet springs back into a capsule and the thinking ring opens from a dot at its left;
 * speak  — the answer card drops out of the island: black at the top (the camera hides in it), liquid glass below,
 *          with the answer, any confirm buttons, and a small band that moves while the voice reads it;
 * then   — hands-free it listens again (连续对话); held (按住 AI 按钮说话) it waits for the next press.
 *
 * Every turn is a turn of the current 聊天 conversation, saved like a typed one: tapping the card opens the chat.
 * "好的" confirms a waiting action, "再见" ends voice mode.
 */
@Component
export struct AiVoiceIsland {
  /** The AI top layer this lives in: back keys are '<surface>:<layerId>@<time>' (see AiTopLayer). */
  @Prop layerId: string = '';
  @Prop owner: string = 'device-local';
  @Prop topInset: number = 24;
  @Prop deviceClass: string = 'phone';
  /** 'hands' (连续对话 from the chat's voice button) or 'hold' (按住 AI 按钮说话). */
  @Prop mode: string = 'hands';
  /**
   * Where the surface starts: 'panel' — where the AI island folds to as it closes (its compact capsule), so the chat
   * panel seems to gather into the droplet; 'island' — the camera island itself (a long press on the AI button).
   */
  @Prop startShape: string = 'island';
  /** Coming back from the orb over a screen voice mode opened: the last answer and its cards, listening again. */
  @Prop resume: boolean = false;
  /** In a remote session: the system bars stay as the session keeps them (voice mode never shows or hides them). */
  @Prop keepSystemBars: boolean = false;
  @StorageProp('diagnosticAiReducedMotion') reducedMotion: boolean = false;
  @StorageProp('currentTheme') theme: string = 'light';
  @StorageProp(AI_VOICE_HOLD_EVENT) @Watch('onHoldEvent') holdEvent: string = '';
  /** The back key reached the voice layer: voice mode closes, as a swipe up does. */
  @StorageProp('aiTop.back') @Watch('onBackKey') backKey: string = '';
  /** Handing over to the chat panel: where its glass is (AiIsland says so once it has laid itself out). */
  @StorageProp(AI_HANDOVER_RECT) @Watch('onHandoverRect') handoverRect: string = '';
  onDismissed: () => void = (): void => {};
  /** Open the full chat on this conversation. */
  onOpenChat: () => void = (): void => {};
  /** A confirmed card opens an app screen: the island takes over (status capsule, done mark, the orb above it). */
  onOpenScreen: (action: string) => void = (_action: string): void => {};
  /** Voice mode floats as the orb over the page; a tap on the orb brings it back. */
  onFloat: () => void = (): void => {};

  /** start · pill · listen · think · speak · answer · error */
  @State private phase: string = 'start';
  @State private shown: boolean = false;
  /** The card's content is in: it comes in after the surface has begun to grow, and leaves before it shrinks. */
  @State private contentIn: boolean = false;
  /** The answer as Markdown blocks, and how many are in: they come in one after another as the panel opens. */
  @State private answerBlocks: AiMdBlock[] = [];
  @State private shownBlocks: number = 0;
  /** What the AI suggests asking next: pills to tap (or just say it). */
  @State private suggestions: string[] = [];
  /** After an answer, voice mode listens inside the panel (its lower edge lights up) instead of shrinking back. */
  @State private panelListening: boolean = false;
  /** The surface is handing over to the chat panel (fading while the panel opens under it). */
  @State private handingOver: boolean = false;
  /** Closing: the island's capsule sinks into the island (shrinking toward the top as it fades), as text mode's does. */
  @State private leaving: boolean = false;
  /** The chat panel's glass (top, width, height, radius) the surface grows to while handing over; top < 0 none yet. */
  @State private handTop: number = -1;
  @State private handWidth: number = 0;
  @State private handHeight: number = 0;
  @State private handRadius: number = 0;
  private awaitingPanel: boolean = false;
  /** What the thinking capsule says (as in text mode): lines that fit the question, a tool's own status first. */
  @State private status: string = '';
  private clock: number = 0;
  private revealTimer: number = -1;
  private statusTimer: number = -1;
  private phrases: string[] = [];
  private phraseIndex: number = 0;
  private toolStatusAt: number = 0;
  private retries: number = 0;
  /** How many of the heard characters are on screen: they come in one at a time, whatever the recognizer sends. */
  @State private shownChars: number = 0;
  /** Long quiet: still in voice mode, the microphone resting until a tap. */
  @State private paused: boolean = false;
  private typeTimer: number = -1;
  private quietSince: number = 0;
  /** Handing over to the chat while the answer is still being read: keep reading. */
  private keepSpeech: boolean = false;
  /** Microphone level as drawn: follows the measured level quickly up, slowly down. */
  @State private level: number = 0;
  @State private transcript: string = '';
  @State private answer: string = '';
  @State private note: string = '';
  @State private actions: AiChatAction[] = [];
  @State private documents: string[] = [];
  @State private cardContent: number = 0;
  @State private areaWidth: number = 360;
  @State private areaHeight: number = 720;
  @State private holding: boolean = false;
  private targetLevel: number = 0;
  /** Level of the voice being played (our own player reports it), for the speaking light. */
  private outLevel: number = 0;
  private islandTop: number = -1;
  private cutoutTop: number = -1;
  private pillWidth: number = 120;
  private pillHeight: number = 36;
  private sync: displaySync.DisplaySync | null = null;
  private timer: number = -1;
  private timers: number[] = [];
  private closing: boolean = false;
  private answerMessageId: string = '';
  private turnGeneration: number = 0;
  private statusBarHidden: boolean = false;
  private config: AiVoiceConfig = new AiVoiceConfig();
  private preferences: DiagnosticAiAssistantPreferences = defaultDiagnosticAiAssistantPreferences();
  private readonly chat: AiChatService = new AiChatService();
  /** 助理's own service: voice mode asks it the app's questions (how to, settings) and shows its cards. */
  private readonly agent: DiagnosticAiAgentService = new DiagnosticAiAgentService();
  private assistantHistory: string = '';
  private readonly store: DiagnosticAiProfileStore = new DiagnosticAiProfileStore();
  private readonly conversationStore: DiagnosticAiConversationStore = new DiagnosticAiConversationStore();
  private readonly modelCatalog: DiagnosticAiModelCatalog = new DiagnosticAiModelCatalog();
  private readonly skillStore: AiSkillStore = new AiSkillStore();
  private readonly voiceSettings: AiVoiceSettings = new AiVoiceSettings();

  aboutToAppear(): void {
    const context: common.UIAbilityContext = this.context();
    try {
      this.store.init(context, this.owner);
      this.conversationStore.init(context, this.owner);
      this.modelCatalog.init(context, this.owner);
      this.skillStore.init(context, this.owner);
      this.voiceSettings.init(context, this.owner);
      this.config = this.voiceSettings.read();
      this.preferences = this.conversationStore.assistantPreferences();
    } catch (_error) { /* the turn below fails closed */ }
    if (AiChatMemory.owner !== this.owner) { AiChatMemory.clear(this.owner); }
    this.holding = this.mode === 'hold';
    // From the first frame to the last, voice mode sits above the status bar: the system's own island (a live
    // activity) must not draw over the droplet or the card.
    this.setStatusBarHidden(true);
    this.placeOnCutout();
    this.startClock();
    // Appear where the start shape is, then swell into the droplet (listen()) — or, coming back from the orb, open
    // the panel again on the last answer and listen there.
    const last: AiChatMessage | undefined = this.resume ? this.lastAnswer() : undefined;
    this.later(16, (): void => {
      this.getUIContext().animateTo({ duration: 140, curve: Curve.EaseOut }, (): void => { this.shown = true; });
      if (last !== undefined) {
        this.answerMessageId = last.id;
        this.answer = last.text;
        this.answerBlocks = aiMarkdownBlocks(last.text);
        this.shownBlocks = this.answerBlocks.length;
        this.actions = last.actions;
        this.documents = last.documents.map((d: AiDocument): string => d.name);
        this.suggestions = last.suggestions.slice(0, 3);
        this.setStatusBarHidden(true);
        this.go('answer');
        this.later(260, (): void => { this.listen(); });
        return;
      }
      this.later(this.startShape === 'panel' ? 60 : 30, (): void => { this.listen(); });
    });
  }

  aboutToDisappear(): void {
    this.closing = true;
    this.turnGeneration++;
    this.clearTimers();
    this.stopReveal();
    this.stopStatus();
    this.stopTyping();
    this.stopClock();
    AiVoiceInput.cancel();
    void AiVoiceInput.stopMonitor();
    if (!this.keepSpeech) { AiReadAloud.stop(); }
    // Handed over to the island, which keeps the bar hidden and gives it back itself.
    if (!this.handingOver) { this.setStatusBarHidden(false); }
  }

  private context(): common.UIAbilityContext { return this.getUIContext().getHostContext() as common.UIAbilityContext; }

  private lastAnswer(): AiChatMessage | undefined {
    for (let i = AiChatMemory.messages.length - 1; i >= 0; i--) {
      if (AiChatMemory.messages[i].role === 'assistant') { return AiChatMemory.messages[i]; }
    }
    return undefined;
  }

  private later(ms: number, action: () => void): void { this.timers.push(setTimeout(action, ms)); }
  private clearTimers(): void {
    this.timers.forEach((id: number): void => { clearTimeout(id); });
    this.timers = [];
  }

  /** Surface geometry: a liquid spring, a touch of overshoot as the droplet swells or the card drops. */
  private morph(action: () => void): void {
    if (this.reducedMotion) { action(); return; }
    this.getUIContext().animateTo({ curve: curves.springMotion(0.5, 0.74) }, action);
  }

  private fadeContent(on: boolean, duration: number, delay: number): void {
    if (this.reducedMotion) { this.contentIn = on; return; }
    this.getUIContext().animateTo({ duration: duration, delay: delay, curve: on ? Curve.EaseOut : Curve.EaseIn },
      (): void => { this.contentIn = on; });
  }

  private isCard(phase: string): boolean { return phase === 'speak' || phase === 'answer' || phase === 'error'; }

  /**
   * One surface goes from shape to shape. Into the card, the surface grows first and the content comes into focus
   * as it settles; out of the card, the content leaves first and the surface then gathers into the next shape.
   */
  private go(next: string): void {
    if (next === this.phase) { return; }
    const fromCard: boolean = this.isCard(this.phase);
    const toCard: boolean = this.isCard(next);
    if (fromCard && !toCard) {
      this.fadeContent(false, 120, 0);
      this.later(this.reducedMotion ? 0 : 90, (): void => { this.morph((): void => { this.phase = next; }); });
      return;
    }
    this.morph((): void => { this.phase = next; });
    if (toCard && !fromCard) { this.fadeContent(true, 260, 150); }
  }

  // ------------------------------------------------------------------ clock (the band and the level)

  private startClock(): void {
    this.clock = Date.now();
    if (this.reducedMotion) { return; }
    try {
      const sync: displaySync.DisplaySync = displaySync.create();
      sync.setExpectedFrameRateRange({ min: 30, max: 60, expected: 60 });
      sync.on('frame', (): void => { this.tick(); });
      sync.start();
      this.sync = sync;
    } catch (_error) {
      this.timer = setInterval((): void => { this.tick(); }, 16);
    }
  }

  private stopClock(): void {
    if (this.sync !== null) {
      try { this.sync.stop(); this.sync.off('frame'); } catch (_error) { /* already stopped */ }
      this.sync = null;
    }
    if (this.timer !== -1) { clearInterval(this.timer); this.timer = -1; }
  }

  private tick(): void {
    this.clock = Date.now();
    if (this.handingOver) { return; }
    const target: number = this.phase === 'speak' ? Math.min(1, this.outLevel * 1.15) :
      this.phase === 'listen' || this.panelListening ? this.targetLevel : 0;
    const k: number = target > this.level ? 0.34 : 0.1;
    const next: number = this.level + (target - this.level) * k;
    if (Math.abs(next - this.level) > 0.002) { this.level = next; }
  }

  // ------------------------------------------------------------------ geometry

  private k(): number { return this.deviceClass === 'phone' ? Math.min(1.15, Math.max(0.85, this.areaWidth / AI_REF_WIDTH)) : 1; }

  private placeOnCutout(): void {
    this.islandTop = this.topInset + 6;
    this.cutoutTop = -1;
    if (this.deviceClass !== 'phone') { return; }
    try {
      const screen: display.Display = display.getDefaultDisplaySync();
      const ui = this.getUIContext();
      screen.getCutoutInfo().then((info: display.CutoutInfo): void => {
        const rects: display.Rect[] = info.boundingRects;
        for (let i: number = 0; i < rects.length; i++) {
          const top: number = ui.px2vp(rects[i].top);
          const height: number = ui.px2vp(rects[i].height);
          if (top > 60 || height <= 0) { continue; }
          this.cutoutTop = top;
          this.pillWidth = Math.max(100, ui.px2vp(rects[i].width) + 18);
          this.pillHeight = Math.max(32, height + 8);
          this.islandTop = Math.max(0, top - 4);
          return;
        }
      }).catch((): void => { /* no cutout: top center */ });
    } catch (_error) { /* no display info: top center */ }
  }

  private cardPhase(): boolean { return this.isCard(this.phase); }

  /** The AI island's compact capsule (AiIsland): where the closing chat panel gathers to. */
  private panelAnchorTop(): number {
    return this.cutoutTop >= 0 ? Math.max(2, Math.min(12.5 * this.k(), this.cutoutTop - 8)) : this.topInset + 6;
  }
  private panelCapsuleWidth(): number {
    return this.cutoutTop >= 0 ? Math.min(this.areaWidth - 24, 296 * this.k()) : 226 * this.k();
  }
  private panelCapsuleHeight(): number {
    const headroom: number = this.cutoutTop >= 0 ? Math.max(0, this.topInset + 6 - this.panelAnchorTop()) : 0;
    return 58 * this.k() + headroom;
  }
  private startFromPanel(): boolean { return this.phase === 'start' && this.startShape === 'panel'; }

  /** The thinking capsule is text mode's status capsule (AiIsland, stage 2): as wide as the panel, ring and line. */
  private statusHeight(): number {
    const headroom: number = this.cutoutTop >= 0 ? Math.max(0, this.topInset + 6 - this.panelAnchorTop()) : 0;
    return 97.5 * this.k() + headroom;
  }
  /** The pill voice mode starts from and ends in: a little larger than the camera, so it is always covered. */
  private pillW(): number { return this.pillWidth + 16; }
  private pillH(): number { return this.pillHeight + 8; }

  /** Closing: the AI island's compact capsule (AiIsland stage 1), where text mode also closes through. */
  private closingCapsule(): boolean { return this.phase === 'capsule'; }
  /** That capsule's ring, as AiIsland draws it at stage 1: 34 vp, left of the system island, on the centre line. */
  private capsuleRingSize(): number { return 34 * this.k(); }
  private capsuleRingX(): number {
    const headroom: number = this.cutoutTop >= 0 ? Math.max(0, this.topInset + 6 - this.panelAnchorTop()) : 0;
    return (headroom > 0 ? 24 : 11) * this.k();
  }

  private surfaceWidth(): number {
    if (this.handTop >= 0) { return this.handWidth; }
    if (this.startFromPanel() || this.closingCapsule()) { return this.panelCapsuleWidth(); }
    if (this.phase === 'listen') { return Math.min(196 * this.k(), Math.max(150 * this.k(), this.pillWidth * 1.32)); }
    if (this.phase === 'think' || this.cardPhase()) { return this.cardWidth(); }
    return this.pillW();
  }

  private headerHeight(): number { return this.pillHeight + 20; }
  private listenEdgeHeight(): number { return this.transcript.length > 18 ? 104 : 80; }

  private surfaceHeight(): number {
    if (this.handTop >= 0) { return this.handHeight; }
    if (this.startFromPanel() || this.closingCapsule()) { return this.panelCapsuleHeight(); }
    if (this.phase === 'listen') { return this.surfaceWidth() * 0.72; }
    if (this.phase === 'think') { return this.statusHeight(); }
    if (this.cardPhase()) {
      const max: number = this.areaHeight * 0.58;
      // Header, the measured content, the scroll's own bottom padding, and the listening edge while it listens.
      return Math.min(max + (this.panelListening ? this.listenEdgeHeight() : 0),
        this.headerHeight() + Math.max(64, this.cardContent) + 26 + (this.panelListening ? this.listenEdgeHeight() : 0));
    }
    return this.pillH();
  }

  private surfaceTop(): number {
    if (this.handTop >= 0) { return this.handTop; }
    if (this.startFromPanel() || this.closingCapsule()) { return this.panelAnchorTop(); }
    if (this.phase === 'listen') { return this.islandTop - 3; }
    if (this.phase === 'think') { return this.panelAnchorTop(); }
    if (this.cardPhase()) { return Math.max(4, this.islandTop - 8); }
    return Math.max(0, this.islandTop - 4);
  }

  private surfaceRadius(): number {
    if (this.handTop >= 0) { return this.handRadius; }
    if (this.phase === 'listen') { return this.surfaceHeight() * 0.47; }
    if (this.cardPhase()) { return 38 * this.k(); }
    if (this.phase === 'think') { return Math.min(this.surfaceHeight() / 2, 46 * this.k()); }
    return this.surfaceHeight() / 2;
  }
  private ringSize(): number { return 42 * this.k(); }

  /** The card's content keeps the card's final width while the surface grows to it (no reflow on the way). */
  private cardWidth(): number {
    return this.deviceClass === 'phone' ? this.areaWidth - 25 * this.k() : Math.min(Math.max(this.areaWidth - 64, 420), 560);
  }

  // ------------------------------------------------------------------ the conversation

  private listen(overAnswer: boolean = false): void {
    if (this.closing) { return; }
    // A new turn before anything is stopped: the answer's reading, ending below, must find itself outdated (it would
    // otherwise let go of the microphone the user is talking into).
    const generation: number = ++this.turnGeneration;
    const afterSpeech: boolean = this.cardPhase();
    // Once there is an answer, the conversation goes on in the panel (as Siri's does): its lower edge listens.
    const inPanel: boolean = this.cardPhase() && this.phase !== 'error' && this.answer !== '';
    const stopAt: number = Date.now();
    AiReadAloud.stop();
    if (Date.now() - stopAt > 50) {
      hilog.warn(0x0000, 'AiChat', 'voice stop took %{public}s ms', (Date.now() - stopAt).toString());
    }
    this.targetLevel = 0;
    this.transcript = '';
    this.stopTyping();
    this.shownChars = 0;
    this.paused = false;
    this.note = '';
    this.stopReveal();
    this.stopStatus();
    if (inPanel) {
      this.morph((): void => { this.panelListening = true; });
      this.go('answer');
    } else {
      this.panelListening = false;
      this.go('listen');
    }
    this.retries = 0;
    this.quietSince = Date.now();
    // Right after the answer was read, give the speaker a moment to let go of the audio before the microphone opens.
    // (Talking over the answer, the microphone is already live: no pause, and what was said so far goes first.)
    this.later(afterSpeech && !overAnswer && !this.reducedMotion ? 320 : 0, (): void => {
      if (generation === this.turnGeneration && !this.closing) { this.hear(generation, overAnswer); }
    });
  }

  /** One recognition session for this turn. */
  private hear(generation: number, overAnswer: boolean = false): void {
    const startedAt: number = Date.now();
    hilog.info(0x0000, 'AiChat', 'voice hear over=%{public}s phase=%{public}s', String(overAnswer), this.phase);
    void AiVoiceInput.start(this.context(), (text: string, _final: boolean): void => {
      if (generation === this.turnGeneration) { this.transcript = text; this.typeIn(); }
    }, (problem: string): void => {
      if (generation !== this.turnGeneration || this.closing) { return; }
      this.targetLevel = 0;
      const question: string = this.transcript.trim();
      hilog.info(0x0000, 'AiChat', 'voice hear ended chars=%{public}s after=%{public}s ms', question.length.toString(),
        (Date.now() - startedAt).toString());
      // The recognizer may hand back a lone full stop for silence or noise: that is nothing said.
      if (question.replace(/[\s。，、！？!?,.…~～]/g, '') !== '') { void this.ask(question, generation); return; }
      if (problem !== '') { this.fail(problem); return; }
      // A session that ends at once, having heard nothing, did not really listen: try again (twice at most).
      if (Date.now() - startedAt < 1500 && this.retries < 2) {
        this.retries++;
        hilog.info(0x0000, 'AiChat', 'voice session ended early, listening again');
        this.later(200, (): void => { if (generation === this.turnGeneration && !this.closing) { this.hear(generation); } });
        return;
      }
      // Nothing was said. A held press just ends. Hands-free, voice mode never leaves by itself: it keeps listening,
      // and after a long quiet rests (the droplet dims) until a tap.
      if (this.mode === 'hold') {
        if (this.answer !== '') { this.go('answer'); } else { this.close(); }
        return;
      }
      if (Date.now() - this.quietSince > 60000) {
        this.getUIContext().animateTo({ duration: 300, curve: Curve.EaseOut }, (): void => { this.paused = true; });
        return;
      }
      this.later(150, (): void => { if (generation === this.turnGeneration && !this.closing) { this.hear(generation); } });
    }, (level: number): void => {
      // Room noise sits under ~0.28: below it the light stays a thin line; speech swells it.
      if (generation === this.turnGeneration) { this.targetLevel = Math.max(0, (level - 0.28) / 0.72); }
    }, overAnswer, this.owner);
  }

  /** Catch the shown characters up with what was heard, one at a time; the rest glide aside to make room. */
  private typeIn(): void {
    if (this.shownChars > this.transcript.length) { this.shownChars = this.transcript.length; }
    if (this.typeTimer !== -1 || this.shownChars >= this.transcript.length) { return; }
    if (this.reducedMotion) { this.shownChars = this.transcript.length; return; }
    this.typeTimer = setInterval((): void => {
      if (this.shownChars >= this.transcript.length) { this.stopTyping(); return; }
      this.getUIContext().animateTo({ curve: curves.springMotion(0.34, 0.86) }, (): void => { this.shownChars++; });
    }, 46);
  }

  private stopTyping(): void {
    if (this.typeTimer !== -1) { clearInterval(this.typeTimer); this.typeTimer = -1; }
  }

  /** The droplet is tapped: send now while listening, or wake up after a long quiet. */
  private tapDroplet(): void {
    if (this.paused) { this.listen(); return; }
    AiVoiceInput.stop();
  }

  private fail(problem: string): void {
    this.stopStatus();
    this.answer = '';
    this.answerBlocks = [];
    this.suggestions = [];
    this.panelListening = false;
    this.note = problem;
    this.actions = [];
    this.documents = [];
    this.go('error');
    // Voice mode stays: hands-free it listens again after showing what went wrong.
    const generation: number = this.turnGeneration;
    this.later(3600, (): void => {
      if (this.phase === 'error' && generation === this.turnGeneration && this.mode === 'hands') { this.listen(); }
    });
  }

  private pendingAction(): AiChatAction | undefined {
    return this.actions.find((a: AiChatAction): boolean => a.status === 'pending');
  }

  private async ask(question: string, generation: number): Promise<void> {
    hilog.info(0x0000, 'AiChat', 'voice heard chars=%{public}s', question.length.toString());
    // A card waiting for an answer first ("不用了" cancels it there, rather than ending voice mode).
    const waiting: AiChatAction | undefined = this.pendingAction();
    if (waiting !== undefined && YES.test(question)) { await this.confirm(waiting, generation); return; }
    if (waiting !== undefined && NO.test(question)) {
      this.cancelAction(waiting);
      await this.say('好的，已取消。', generation);
      this.next(generation);
      return;
    }
    // 拜拜 / 回到文字 / 切到助理 / 悬浮球: done at once.
    const command: string = aiModeCommand(question);
    if (command !== '') { await this.applyMode(command, generation, ''); return; }
    // 助理 or 聊天, decided for every question. About the app (how to, its settings): 助理 answers here, its cards in
    // the voice panel. A fault to diagnose or a report to send needs 助理's capture and mail flow: it carries on there.
    // A feature idea goes to 聊天 (it keeps the list); everything else about the app is 助理's.
    if (aiQuestionIsAboutApp(question) && !aiQuestionIsFeatureIdea(question)) {
      const mode: DiagnosticAiAgentMode = diagnosticAiAgentModeForQuestion(question);
      if (mode === 'diagnose' || mode === 'feedback') {
        AppStorage.setOrCreate(AI_ASSISTANT_HANDOFF, Date.now().toString() + '|' + question.slice(0, 500));
        AiChatMemory.active = false;
        void AiReadAloud.speak(this.context(), this.owner, 'voice-handoff',
          mode === 'diagnose' ? '好的，我在助理里帮你排查。' : '好的，我在助理里帮你整理反馈。', (_id: string): void => {});
        this.openChat(true);
        return;
      }
      await this.askAssistant(question, mode, generation);
      return;
    }
    this.panelListening = false;
    this.startStatus(aiThinkingPhrases(question, []));
    this.setStatusBarHidden(true);
    this.go('think');
    if (!aiChatAllowed()) { this.fail('当前账号没有 AI 助理权限'); return; }
    const profile: DiagnosticAiProviderProfile | undefined = aiChatSelectedProfile(this.store);
    if (profile === undefined) { this.fail('请先在辅助 AI 配置中保存 API Key 并选择模型'); return; }
    let secret: string = '';
    try { secret = this.store.secret(profile); } catch (_error) { secret = ''; }
    if (!diagnosticAiProviderIsHarmonyLocal(profile.providerId) && secret.trim() === '') {
      this.fail('API Key 无法从本机安全存储读回，请在辅助 AI 配置中重新保存'); return;
    }
    if (AiChatMemory.owner !== this.owner) { AiChatMemory.clear(this.owner); }
    AiChatMemory.active = true;
    if (AiChatMemory.sessionId === '') {
      AiChatMemory.sessionId = 'chat-' + Date.now().toString() + '-' + Math.floor(Math.random() * 100000).toString();
    }
    const sessionId: string = AiChatMemory.sessionId;
    const asked: AiChatMessage = new AiChatMessage(newMessageId(), 'user', question, [], [], Date.now());
    AiChatMemory.messages = AiChatMemory.messages.concat([asked]);
    const requestId: string = newMessageId();
    AiChatMemory.requestId = requestId;
    const handoffBefore: string = AppStorage.get<string>(AI_ASSISTANT_HANDOFF) ?? '';
    const floatBefore: number = AppStorage.get<number>(AI_FLOAT_REQUEST) ?? 0;
    const modeBefore: string = AppStorage.get<string>(AI_MODE_REQUEST) ?? '';
    // 记忆 may have changed (update_memory in an earlier turn).
    try { this.preferences = this.conversationStore.assistantPreferences(); } catch (_error) { /* keep what we have */ }
    try {
      const turns: AiChatTurn[] = AiChatMemory.messages
        .filter((m: AiChatMessage): boolean => m.role === 'user' || m.role === 'assistant')
        .map((m: AiChatMessage): AiChatTurn => new AiChatTurn(m.role, aiChatTurnText(m)));
      const reply: AiChatReply = await this.chat.respond(this.context(), profile, secret, {
        turns: turns, attachments: AiChatMemory.attachments, preferences: aiChatPreferenceText(this.preferences) + VOICE_STYLE,
        memory: this.preferences.memoryEnabled ? this.preferences.manualMemorySummary.trim().slice(0, 1200) : '',
        tools: this.skillStore.enabledTools(), skills: this.skillStore.installedSkills(), chosenSkills: [],
        appData: aiChatAppData(this.conversationStore), onProgress: (status: string): void => { this.progress(status); }
      });
      if (AiChatMemory.requestId !== requestId || generation !== this.turnGeneration || this.closing) { return; }
      if (!aiChatOwnerStill(this.owner) || !aiChatAllowed()) { this.fail('账号已变化，已丢弃这次回答'); return; }
      const answer: AiChatMessage = new AiChatMessage(newMessageId(), 'assistant', reply.text, [], reply.documents, Date.now(),
        reply.suggestions, reply.actions);
      AiChatMemory.messages = AiChatMemory.messages.concat([answer]);
      aiChatSaveSession(this.conversationStore, sessionId, AiChatMemory.messages, profile);
      aiChatRecordUsage(this.conversationStore, this.modelCatalog, profile, reply);
      hilog.info(0x0000, 'AiChat', 'voice answered chars=%{public}s actions=%{public}s', reply.text.length.toString(),
        reply.actions.length.toString());
      this.answerMessageId = answer.id;
      this.actions = reply.actions;
      this.documents = reply.documents.map((d: AiDocument): string => d.name);
      this.suggestions = reply.suggestions.slice(0, 3);
      // Handed to 助理 (a diagnosis, a log capture): it carries on in the panel, in 助理.
      if ((AppStorage.get<string>(AI_ASSISTANT_HANDOFF) ?? '') !== handoffBefore) {
        AiChatMemory.active = false;
        this.openChat(false);
        return;
      }
      // The AI changed mode (switch_mode): its short reply is said on the way.
      const modeNow: string = AppStorage.get<string>(AI_MODE_REQUEST) ?? '';
      if (modeNow !== modeBefore && modeNow.split('@')[0] !== 'voice') {
        await this.applyMode(modeNow.split('@')[0], generation, reply.text);
        return;
      }
      // The AI floated voice mode (float_orb): say the short reply on the way into the orb.
      if ((AppStorage.get<number>(AI_FLOAT_REQUEST) ?? 0) !== floatBefore) {
        void AiReadAloud.speak(this.context(), this.owner, answer.id, reply.text, (_id: string): void => {});
        this.floatToOrb(true);
        return;
      }
      // Everything else — the answer, cards to confirm, documents, next steps — opens in the voice panel.
      await this.say(reply.text, generation);
      this.next(generation);
    } catch (error) {
      if (AiChatMemory.requestId !== requestId || generation !== this.turnGeneration) { return; }
      this.fail(aiChatErrorText(error as Object));
    } finally {
      if (AiChatMemory.requestId === requestId) { AiChatMemory.requestId = ''; AiChatMemory.status = ''; }
      aiChatRefresh();
    }
  }

  /**
   * A question about the app, answered by 助理's own service in the voice panel: its answer read aloud, its setting
   * proposals as cards to confirm (or "好的"), the screens it points to as cards that open them.
   */
  private async askAssistant(question: string, mode: DiagnosticAiAgentMode, generation: number): Promise<void> {
    this.panelListening = false;
    this.startStatus(mode === 'configure' ? ['正在查看可以调整的设置', '正在准备设置建议'] : ['正在查找使用说明', '正在整理回答']);
    this.setStatusBarHidden(true);
    this.go('think');
    if (!aiChatAllowed()) { this.fail('当前账号没有 AI 助理权限'); return; }
    const profile: DiagnosticAiProviderProfile | undefined = aiChatSelectedProfile(this.store);
    if (profile === undefined) { this.fail('请先在辅助 AI 配置中保存 API Key 并选择模型'); return; }
    let secret: string = '';
    try { secret = this.store.secret(profile); } catch (_error) { secret = ''; }
    if (!diagnosticAiProviderIsHarmonyLocal(profile.providerId) && secret.trim() === '') {
      this.fail('API Key 无法从本机安全存储读回，请在辅助 AI 配置中重新保存'); return;
    }
    try {
      const p: DiagnosticAiAssistantPreferences = this.preferences;
      const result: DiagnosticAiResult = await this.agent.respond(profile, secret, {
        mode: mode, question: question, history: this.assistantHistory, bundle: '',
        assistantContext: p.name + '；语气：' + p.personality + '；详细程度：' + p.verbosity + '；语言：' + p.language +
          '；这是语音对话，回答会被朗读：summary 用一两句口语',
        answerStyle: 'plain'
      });
      if (generation !== this.turnGeneration || this.closing) { return; }
      if (!aiChatOwnerStill(this.owner) || !aiChatAllowed()) { this.fail('账号已变化，已丢弃这次回答'); return; }
      // As 助理's panel does: the settings the question itself names come along with the model's proposals.
      diagnosticAiSettingIntents(question).forEach((proposal: DiagnosticAiSettingProposal): void => {
        if (!result.settingProposals.some((x: DiagnosticAiSettingProposal): boolean => x.settingId === proposal.settingId)) {
          result.settingProposals.push(proposal);
        }
      });
      const actions: AiChatAction[] = [];
      result.settingProposals.forEach((proposal: DiagnosticAiSettingProposal): void => {
        const choice: AiSettingChoice | null = diagnosticAiProposalChoice(proposal);
        if (choice === null || !diagnosticAiProposalIsSafe(proposal) ||
          diagnosticAiSettingCurrent(proposal.settingId) === choice.value) { return; }
        const args: Record<string, string> = {};
        args['setting_id'] = proposal.settingId;
        args['value'] = choice.value;
        actions.push(new AiChatAction('act-' + Date.now().toString(36) + actions.length.toString(), 'change_setting',
          '把「' + diagnosticAiSettingActionText(proposal.settingId) + '」改为「' + choice.label + '」',
          proposal.reason.slice(0, 60), JSON.stringify(args)));
      });
      result.appActions.forEach((value: string): void => {
        const id = diagnosticAiAppActionId(value);
        if (id === null || id.startsWith('session.') || actions.length >= 4) { return; }
        const args: Record<string, string> = {};
        args['screen'] = id;
        actions.push(new AiChatAction('act-' + Date.now().toString(36) + actions.length.toString(), 'open_app_screen',
          '打开「' + diagnosticAiAppActionLabel(id) + '」', '在 App 里打开这个页面', JSON.stringify(args)));
      });
      const steps: string[] = result.recommendedReadOnlySteps.slice(0, 4);
      const text: string = result.summary + (steps.length > 0 ?
        '\n\n' + steps.map((step: string, i: number): string => (i + 1).toString() + '. ' + step).join('\n') : '');
      this.assistantHistory = (this.assistantHistory + '\n用户：' + question + '\n助手：' + result.summary).slice(-6000);
      // The turn joins the conversation, so 在聊天中继续 shows it.
      if (AiChatMemory.owner !== this.owner) { AiChatMemory.clear(this.owner); }
      if (AiChatMemory.sessionId === '') {
        AiChatMemory.sessionId = 'chat-' + Date.now().toString() + '-' + Math.floor(Math.random() * 100000).toString();
      }
      const asked: AiChatMessage = new AiChatMessage(newMessageId(), 'user', question, [], [], Date.now());
      const answer: AiChatMessage = new AiChatMessage(newMessageId(), 'assistant', text, [], [], Date.now(), [], actions);
      AiChatMemory.messages = AiChatMemory.messages.concat([asked, answer]);
      aiChatSaveSession(this.conversationStore, AiChatMemory.sessionId, AiChatMemory.messages, profile);
      if (result.usage !== undefined) {
        const cost: number = this.modelCatalog.estimateCost(profile.providerId, profile.modelId, result.usage.promptTokens,
          result.usage.completionTokens, result.usage.cachedTokens);
        this.conversationStore.recordUsage(result.usage.promptTokens, result.usage.completionTokens, result.usage.cachedTokens,
          cost, profile.providerId, profile.modelId, result.usage.estimated === true, false);
      }
      hilog.info(0x0000, 'AiChat', 'voice assistant mode=%{public}s actions=%{public}s', mode, actions.length.toString());
      this.answerMessageId = answer.id;
      this.actions = actions;
      this.documents = [];
      this.suggestions = [];
      aiChatRefresh();
      await this.say(text, generation);
      this.next(generation);
    } catch (error) {
      if (generation !== this.turnGeneration) { return; }
      this.fail(aiChatErrorText(error as Object));
    }
  }

  private onBackKey(): void {
    if (this.backKey.startsWith('voice:' + this.layerId + '@') && !this.closing) { this.close(); }
  }

  /**
   * A mode the user asked for (or the AI chose with switch_mode): 'exit' closes the AI, 'text' / 'chat' go to the
   * chat panel, 'assistant' to 助理, 'orb' floats. `words` is said on the way ('' for the usual short line).
   */
  private async applyMode(mode: string, generation: number, words: string): Promise<void> {
    hilog.info(0x0000, 'AiChat', 'voice mode command %{public}s', mode);
    if (mode === 'voice') {
      await this.say(words !== '' ? words : '我在听，请说。', generation);
      this.next(generation);
      return;
    }
    const line: string = words !== '' ? words : mode === 'exit' ? '好的，再见。' : '';
    if (line !== '') {
      void AiReadAloud.speak(this.context(), this.owner, 'voice-mode', line, (_id: string): void => {});
    }
    if (mode === 'exit') { this.close(line !== ''); return; }
    if (mode === 'orb') { this.floatToOrb(line !== ''); return; }
    this.openChat(line !== '', mode === 'assistant');
  }

  /** Shows the card with `text` and reads it; resolves when the voice is done (or stopped). */
  private async say(text: string, generation: number): Promise<void> {
    this.stopStatus();
    this.answer = text;
    this.answerBlocks = aiMarkdownBlocks(text);
    this.note = '';
    this.setStatusBarHidden(true);
    this.startReveal();
    this.go('speak');
    // Full duplex: our own player (echo-cancelled) reads, and hands-free the microphone listens for the user meanwhile.
    if (this.mode === 'hands') { this.watchForBargeIn(generation); }
    const note: string = await AiReadAloud.speak(this.context(), this.owner, 'voice-' + generation.toString(), text,
      (_id: string): void => {}, true, (level: number): void => { this.outLevel = level; });
    this.outLevel = 0;
    // Read to the end (no barge-in): the microphone that waited for one is not needed any more — unless the user is
    // talking into it.
    if (generation === this.turnGeneration && !AiVoiceInput.monitorClaimed()) { void AiVoiceInput.stopMonitor(); }
    if (note !== '' && generation === this.turnGeneration) { this.note = note; }
  }

  /**
   * While the answer is read: the echo-cancelled microphone. The user talking (loud enough, long enough — the
   * answer's own echo is mostly removed) stops the voice, and recognition starts with what they already said.
   */
  private watchForBargeIn(generation: number): void {
    const startedAt: number = Date.now();
    let loudSince: number = 0;
    let peak: number = 0;
    let loggedAt: number = 0;
    void AiVoiceInput.startMonitor(this.context(), (level: number): void => {
      if (generation !== this.turnGeneration || this.phase !== 'speak' || this.closing) { return; }
      const now: number = Date.now();
      peak = Math.max(peak, level);
      if (now - loggedAt > 1000) {
        hilog.info(0x0000, 'AiChat', 'duplex mic=%{public}s out=%{public}s', peak.toFixed(2), this.outLevel.toFixed(2));
        loggedAt = now;
        peak = 0;
      }
      if (now - startedAt < 400) { return; }
      if (level >= AI_BARGE_LEVEL) {
        if (loudSince === 0) { loudSince = now; }
        else if (now - loudSince >= AI_BARGE_MS) { this.bargeIn(); }
      } else {
        loudSince = 0;
      }
    });
  }

  /** The user talked over the answer: the voice stops and recognition takes over the microphone already listening. */
  private bargeIn(): void {
    hilog.info(0x0000, 'AiChat', 'voice interrupted by speech');
    // First, before the voice stops: the microphone keeps everything from here on for the recognizer.
    const claimed: boolean = AiVoiceInput.claimMonitor();
    this.listen(claimed);
  }

  /** After an answer (unless the user already talked over it): listen again (hands-free), or wait as the card. */
  private next(generation: number): void {
    if (this.closing || generation !== this.turnGeneration) { return; }
    const waiting: boolean = this.pendingAction() !== undefined;
    if (this.mode === 'hands' && (this.config.continuous || waiting)) { this.listen(); return; }
    this.go('answer');
  }

  /** Rotates through the thinking lines, as text mode does; a tool's own status wins for a while. */
  private startStatus(phrases: string[]): void {
    this.stopStatus();
    this.phrases = phrases.length > 0 ? phrases : ['正在思考'];
    this.phraseIndex = 0;
    this.status = this.phrases[0];
    this.statusTimer = setInterval((): void => {
      if (Date.now() - this.toolStatusAt < 2600 || this.phrases.length === 0) { return; }
      this.phraseIndex = Math.min(this.phraseIndex + 1, this.phrases.length - 1);
      this.showStatus(this.phrases[this.phraseIndex]);
    }, 2800);
  }

  private stopStatus(): void {
    if (this.statusTimer !== -1) { clearInterval(this.statusTimer); this.statusTimer = -1; }
  }

  private progress(status: string): void {
    this.toolStatusAt = Date.now();
    this.showStatus(status);
  }

  private showStatus(next: string): void {
    if (next === this.status || this.phase !== 'think') { this.status = next; return; }
    this.getUIContext().animateTo({ duration: 260, curve: Curve.EaseOut }, (): void => { this.status = next; });
  }

  /** The answer's blocks come in one after another as the panel opens (each rising into focus). */
  private startReveal(): void {
    this.stopReveal();
    if (this.reducedMotion) { this.shownBlocks = this.answerBlocks.length; return; }
    this.shownBlocks = 0;
    this.revealTimer = setInterval((): void => {
      if (this.shownBlocks >= this.answerBlocks.length) { this.stopReveal(); return; }
      this.getUIContext().animateTo({ curve: curves.springMotion(0.42, 0.86) }, (): void => { this.shownBlocks++; });
    }, 110);
  }

  private stopReveal(): void {
    if (this.revealTimer !== -1) { clearInterval(this.revealTimer); this.revealTimer = -1; }
    this.shownBlocks = this.answerBlocks.length;
  }

  /** A pill (or a tap on a suggestion): ask it at once, over the voice if it is still reading. */
  private askPill(text: string): void {
    const generation: number = ++this.turnGeneration;
    AiVoiceInput.cancel();
    AiReadAloud.stop();
    void this.ask(text, generation);
  }

  private setActionStatus(action: AiChatAction, status: string, result: string): void {
    this.actions = this.actions.map((a: AiChatAction): AiChatAction => {
      if (a.id !== action.id) { return a; }
      const copy: AiChatAction = new AiChatAction(a.id, a.tool, a.title, a.detail, a.args);
      copy.status = status;
      copy.result = result;
      return copy;
    });
    // The saved conversation keeps what became of the card, so the model does not ask again.
    AiChatMemory.messages = AiChatMemory.messages.map((m: AiChatMessage): AiChatMessage => {
      if (m.id !== this.answerMessageId) { return m; }
      return new AiChatMessage(m.id, m.role, m.text, m.attachments, m.documents, m.createdAt, m.suggestions, this.actions);
    });
    aiChatRefresh();
  }

  private async confirm(action: AiChatAction, generation: number): Promise<void> {
    // The host's edit sheet or delete dialog comes up over the app: voice mode waits there as the orb.
    if (action.tool === 'edit_host' || action.tool === 'delete_host') {
      this.setActionStatus(action, 'running', '');
      this.floatToOrb();
      const context: common.UIAbilityContext = this.context();
      setTimeout((): void => {
        aiRunAction(context, action, this.owner).then((result: string): void => { this.setActionStatus(action, 'done', result); })
          .catch((error: Object): void => { this.setActionStatus(action, 'failed', aiActionErrorText(error)); });
      }, 380);
      return;
    }
    if (action.tool === 'open_app_screen') {
      let screen: string = '';
      try { screen = String((JSON.parse(action.args) as Record<string, Object>)['screen'] ?? ''); } catch (_error) { screen = ''; }
      this.setActionStatus(action, 'done', '已打开');
      this.openScreen(screen);
      return;
    }
    this.setActionStatus(action, 'running', '');
    try {
      const result: string = await aiRunAction(this.context(), action, this.owner);
      this.setActionStatus(action, 'done', result);
      await this.say(result !== '' ? result : '好了。', generation);
    } catch (error) {
      const why: string = aiActionErrorText(error as Object);
      this.setActionStatus(action, 'failed', why);
      await this.say('没有完成：' + why, generation);
    }
    this.next(generation);
  }

  private cancelAction(action: AiChatAction): void { this.setActionStatus(action, 'cancelled', ''); }

  private tapConfirm(action: AiChatAction): void {
    const generation: number = ++this.turnGeneration;
    AiVoiceInput.cancel();
    AiReadAloud.stop();
    void this.confirm(action, generation);
  }

  private tapCancel(action: AiChatAction): void {
    this.cancelAction(action);
    if (this.phase === 'listen') { return; }
    this.next(this.turnGeneration);
  }

  // ------------------------------------------------------------------ hold to talk, closing

  private onHoldEvent(): void {
    if (this.closing || this.mode !== 'hold') { return; }
    if (this.holdEvent.startsWith('up:')) {
      this.holding = false;
      if (this.phase === 'listen') { AiVoiceInput.stop(); }
    } else if (this.holdEvent.startsWith('down:')) {
      this.holding = true;
      if (this.phase !== 'listen') { this.listen(); }
    }
  }

  private sessionPageOnTop(): boolean {
    try { return aiIsSessionPage(this.getUIContext().getRouter().getState().name); } catch (_error) { return false; }
  }

  private setStatusBarHidden(hidden: boolean): void {
    if (this.keepSystemBars || this.deviceClass !== 'phone') { return; }
    // A session page came over the host list (voice connected a host): its bars are the session's.
    if (this.sessionPageOnTop()) { this.statusBarHidden = false; return; }
    if (hidden === this.statusBarHidden) { return; }
    this.statusBarHidden = hidden;
    const context = this.getUIContext().getHostContext();
    if (!context) { return; }
    window.getLastWindow(context).then((win: window.Window): void => {
      win.setSpecificSystemBarEnabled('status', !hidden, true).catch((): void => { /* keep the bar as it is */ });
    }).catch((): void => { /* no window */ });
  }

  close(keepSpeech: boolean = false): void {
    if (this.closing) { return; }
    hilog.info(0x0000, 'AiChat', 'voice close phase=%{public}s', this.phase);
    this.closing = true;
    this.keepSpeech = keepSpeech;
    this.turnGeneration++;
    AiVoiceInput.cancel();
    void AiVoiceInput.stopMonitor();
    if (!keepSpeech) { AiReadAloud.stop(); }
    this.clearTimers();
    this.stopReveal();
    this.stopStatus();
    this.stopTyping();
    // As text mode closes (AiIsland.close), on the same beats: what the surface shows leaves first; the surface —
    // card, droplet or thinking capsule — gathers into the island's capsule over the camera; the capsule then sinks
    // into the island. Each step starts while the one before is settling, so it reads as one movement.
    const fromCard: boolean = this.cardPhase();
    if (fromCard || this.contentIn) { this.fadeContent(false, 140, 0); }
    this.later(this.reducedMotion ? 0 : (fromCard ? 80 : 0), (): void => {
      const gather = (): void => { this.panelListening = false; this.transcript = ''; this.phase = 'capsule'; };
      if (this.reducedMotion) { gather(); } else {
        this.getUIContext().animateTo({ curve: curves.springMotion(0.42, 0.86) }, gather);
      }
    });
    this.later(this.reducedMotion ? 0 : 520, (): void => {
      this.getUIContext().animateTo({ duration: this.reducedMotion ? 0 : 220, curve: Curve.EaseIn }, (): void => {
        this.leaving = true;
        this.shown = false;
      });
    });
    this.later(this.reducedMotion ? 0 : 760, (): void => {
      this.setStatusBarHidden(false);
      this.onDismissed();
    });
  }

  /**
   * A confirmed screen: voice mode steps out and the island runs the action as text mode does (状态胶囊 → done mark
   * → the orb above the opened screen). The orb remembers it came from voice: a tap brings voice mode back.
   */
  private openScreen(screen: string): void {
    if (this.closing || screen === '') { return; }
    hilog.info(0x0000, 'AiChat', 'voice opens screen %{public}s', screen);
    this.closing = true;
    this.turnGeneration++;
    AiVoiceInput.cancel();
    void AiVoiceInput.stopMonitor();
    AiReadAloud.stop();
    this.clearTimers();
    this.stopReveal();
    this.stopStatus();
    AiChatMemory.voiceResume = true;
    this.handingOver = true;
    this.onOpenScreen(screen);
    this.fadeContent(false, 120, 0);
    this.later(160, (): void => {
      this.getUIContext().animateTo({ duration: 220, curve: Curve.EaseInOut }, (): void => {
        this.handingOver = true;
        this.shown = false;
      });
    });
    this.later(420, (): void => { this.onDismissed(); });
  }

  /** Into the orb: the island takes over as the floating orb; tapping it brings voice mode back here. */
  private floatToOrb(keepSpeech: boolean = false): void {
    if (this.closing) { return; }
    hilog.info(0x0000, 'AiChat', 'voice floats as the orb');
    this.closing = true;
    this.keepSpeech = keepSpeech;
    this.turnGeneration++;
    AiVoiceInput.cancel();
    void AiVoiceInput.stopMonitor();
    if (!keepSpeech) { AiReadAloud.stop(); }
    this.clearTimers();
    this.stopReveal();
    this.stopStatus();
    this.stopTyping();
    AiChatMemory.voiceResume = true;
    this.go('pill');
    this.later(200, (): void => {
      this.setStatusBarHidden(false);
      this.handingOver = true;
      this.onFloat();
      this.getUIContext().animateTo({ duration: 180, curve: Curve.EaseIn }, (): void => { this.shown = false; });
    });
    this.later(420, (): void => { this.onDismissed(); });
  }

  /**
   * Back to the chat panel (every way out of voice mode but a swipe up and 拜拜); `keepSpeech` lets a reading go on;
   * `toAssistant` opens it in 助理.
   */
  private openChat(keepSpeech: boolean = false, toAssistant: boolean = false): void {
    if (this.closing) { return; }
    hilog.info(0x0000, 'AiChat', 'voice open chat phase=%{public}s', this.phase);
    this.closing = true;
    this.keepSpeech = keepSpeech;
    this.turnGeneration++;
    AiVoiceInput.cancel();
    void AiVoiceInput.stopMonitor();
    if (!keepSpeech) { AiReadAloud.stop(); }
    this.clearTimers();
    this.stopReveal();
    this.stopStatus();
    this.stopTyping();
    this.handingOver = true;
    AiChatMemory.active = !toAssistant;
    aiChatRefresh();
    // One surface into the other: what the card shows leaves first, and whatever shape voice mode was in (droplet,
    // capsule, card) becomes the card's dark glass; the chat panel is laid out unseen underneath and says where its
    // glass is (onHandoverRect): the card grows to exactly that, then the two cross-fade.
    this.fadeContent(false, 140, 0);
    this.morph((): void => { this.panelListening = false; this.transcript = ''; this.phase = 'answer'; });
    this.awaitingPanel = true;
    this.onOpenChat();
    // No word from the panel (it was already open): simply dissolve, as before.
    this.later(700, (): void => {
      if (this.handTop >= 0) { return; }
      this.awaitingPanel = false;
      this.getUIContext().animateTo({ duration: 260, curve: Curve.EaseInOut }, (): void => { this.shown = false; });
      this.later(300, (): void => { this.onDismissed(); });
    });
  }

  /** The chat panel's glass, for the handover: grow to it (again, if it changed), then cross-fade into it once. */
  private onHandoverRect(): void {
    if (!this.awaitingPanel) { return; }
    const parts: number[] = this.handoverRect.split(',').map((x: string): number => Number(x));
    if (parts.length < 4 || parts.slice(0, 4).some((n: number): boolean => !Number.isFinite(n)) || parts[1] <= 0 || parts[2] <= 0) {
      return;
    }
    const first: boolean = this.handTop < 0;
    const apply = (): void => {
      this.handTop = parts[0]; this.handWidth = parts[1]; this.handHeight = parts[2]; this.handRadius = parts[3];
    };
    if (this.reducedMotion) { apply(); } else {
      this.getUIContext().animateTo({ curve: curves.springMotion(0.4, 0.88) }, apply);
    }
    if (!first) { return; }
    hilog.info(0x0000, 'AiChat', 'voice hands over to the panel');
    this.later(this.reducedMotion ? 0 : AI_HANDOVER_FADE_DELAY_MS, (): void => {
      this.awaitingPanel = false;
      if (this.reducedMotion) { this.shown = false; } else {
        this.getUIContext().animateTo({ duration: AI_HANDOVER_FADE_MS, curve: Curve.EaseInOut }, (): void => { this.shown = false; });
      }
      this.later((this.reducedMotion ? 0 : AI_HANDOVER_FADE_MS) + 40, (): void => { this.onDismissed(); });
    });
  }

  // ------------------------------------------------------------------ drawing

  private dark(): boolean { return this.theme === 'dark'; }
  private listening(): boolean { return this.phase === 'listen'; }
  /** The capsules (start, think, closing pill) are the island's own black. */
  private blackShape(): boolean { return !this.listening() && !this.cardPhase(); }

  /** The heard characters on screen so far (they come in one at a time). */
  private transcriptChars(): string[] {
    const chars: string[] = [];
    const count: number = Math.min(this.shownChars, this.transcript.length);
    for (let i = 0; i < count; i++) { chars.push(this.transcript.charAt(i)); }
    return chars;
  }

  @Builder private actionButtons(action: AiChatAction) {
    Row({ space: 8 }) {
      Column({ space: 2 }) {
        Text(action.title).fontSize(14).fontWeight(FontWeight.Medium).fontColor('#FFFFFF').maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(action.status === 'done' ? '✓ ' + action.result : action.status === 'failed' ? action.result :
          action.status === 'cancelled' ? '已取消' : action.status === 'running' ? '正在执行…' : '说“好的”或点确认')
          .fontSize(12).fontColor(action.status === 'done' ? '#34C759' : '#AEAEB2').maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      if (action.status === 'pending') {
        Text('取消').fontSize(13).fontColor('#FFFFFF').height(32).padding({ left: 14, right: 14 }).borderRadius(16)
          .backgroundColor('#3A3A3C').onClick((): void => { this.tapCancel(action); })
        Text('确认').fontSize(13).fontWeight(FontWeight.Medium).fontColor('#000000').height(32)
          .padding({ left: 14, right: 14 }).borderRadius(16).backgroundColor('#FFFFFF')
          .onClick((): void => { this.tapConfirm(action); })
      }
    }.width('100%').padding({ left: 12, right: 12, top: 10, bottom: 10 }).borderRadius(16).backgroundColor('#26FFFFFF')
    .transition(TransitionEffect.OPACITY.combine(TransitionEffect.translate({ y: 8 })))
  }

  /** One line of Markdown: bold spans bold, code spans monospaced. */
  @Builder private spans(spans: AiMdSpan[], size: number, weight: FontWeight) {
    Text() {
      ForEach(spans, (span: AiMdSpan): void => {
        Span(span.text).fontWeight(span.bold ? FontWeight.Bold : weight)
          .fontFamily(span.code ? 'monospace' : 'HarmonyOS Sans')
      }, (span: AiMdSpan, index: number): string => index.toString() + span.text.slice(0, 8))
    }.fontSize(size).lineHeight(size + 8).fontColor('#FFFFFF').width('100%')
  }

  /** The answer as text mode draws it (headings, lists, quotes, tables as rows), without its editing tools. */
  @Builder private block(block: AiMdBlock) {
    if (block.kind === 'h1' || block.kind === 'h2' || block.kind === 'h3') {
      this.spans(block.spans, block.kind === 'h1' ? 20 : 18, FontWeight.Bold)
    } else if (block.kind === 'bullet' || block.kind === 'number') {
      Row({ space: 8 }) {
        Text(block.kind === 'number' ? block.marker : '•').fontSize(16).lineHeight(24).fontColor('#AEAEB2')
          .width(block.kind === 'number' ? 22 : 10)
        Column() { this.spans(block.spans, 16, FontWeight.Normal) }.layoutWeight(1)
      }.width('100%').alignItems(VerticalAlign.Top).padding({ left: block.level * 14 })
    } else if (block.kind === 'quote') {
      Row({ space: 10 }) {
        Column().width(3).height('100%').borderRadius(2).backgroundColor('#48484A')
        Column() { this.spans(block.spans, 15, FontWeight.Normal) }.layoutWeight(1)
      }.width('100%').alignItems(VerticalAlign.Top)
    } else if (block.kind === 'table') {
      Column({ space: 4 }) {
        ForEach(block.rows, (row: string[], r: number): void => {
          Text(row.join('  ·  ')).fontSize(14).lineHeight(21).fontColor(r === 0 ? '#AEAEB2' : '#FFFFFF')
            .fontWeight(r === 0 ? FontWeight.Medium : FontWeight.Normal).width('100%')
        }, (row: string[], r: number): string => r.toString() + row.join('|').slice(0, 16))
      }.width('100%').padding(10).borderRadius(14).backgroundColor('#1FFFFFFF')
    } else if (block.kind === 'code') {
      Text(block.text).fontSize(13).lineHeight(19).fontFamily('monospace').fontColor('#E5E5EA').width('100%')
        .padding(10).borderRadius(12).backgroundColor('#1FFFFFFF')
    } else if (block.kind !== 'rule') {
      this.spans(block.spans, 17, FontWeight.Normal)
    }
  }

  /** The panel's lower edge while it listens: what is heard comes in above a strip of light. */
  @Builder private listeningEdge() {
    Column({ space: 6 }) {
      Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Center }) {
        if (this.paused) {
          Text('点一下继续说').fontSize(15).lineHeight(24).fontColor('#8E8E93').transition(TransitionEffect.OPACITY)
        } else if (this.transcript === '') {
          Text('请说…').fontSize(15).lineHeight(24).fontColor('#8E8E93').transition(TransitionEffect.OPACITY)
        } else {
          ForEach(this.transcriptChars(), (ch: string): void => {
            Text(ch).fontSize(17).lineHeight(24).fontWeight(FontWeight.Medium).fontColor('#FFFFFF')
              .transition(TransitionEffect.OPACITY.animation({ duration: 160, curve: Curve.EaseOut })
                .combine(TransitionEffect.translate({ y: 14 }))
                .combine(TransitionEffect.scale({ x: 0.3, y: 0.3, centerY: '100%' }))
                .animation({ curve: curves.springMotion(0.3, 0.55) }))
          }, (_ch: string, index: number): string => 'p' + index.toString())
        }
      }.width('100%').padding({ left: 20, right: 20 })
      AiSiriBand({ level: this.paused ? 0 : this.level, vivid: true }).width('100%').height(30)
        .opacity(this.paused ? 0.35 : 1)
    }
    .width('100%').height(this.listenEdgeHeight()).justifyContent(FlexAlign.End).padding({ bottom: 6 })
    .transition(TransitionEffect.OPACITY.combine(TransitionEffect.translate({ y: 12 })))
    .onClick((): void => { if (this.paused) { this.listen(); } else { AiVoiceInput.stop(); } })
  }

  /** The card's content, laid out at the card's final width from the first frame. */
  @Builder private cardBody() {
    Column() {
      // Header (in the black): the speaking light at the left, back to the chat at the right — the camera between.
      Row() {
        Stack() {
          if (this.phase === 'speak') {
            AiSiriBand({ level: this.level, vivid: true }).width(60).height(26)
              .transition(TransitionEffect.OPACITY)
          } else {
            SymbolGlyph($r(this.phase === 'error' ? 'sys.symbol.exclamationmark_circle' : 'sys.symbol.waveform_1'))
              .fontSize(18).fontColor(['#AEAEB2'])
              .transition(TransitionEffect.OPACITY)
          }
        }.width(64).height(this.pillHeight).alignContent(Alignment.Start)
        Blank()
        SymbolGlyph($r('sys.symbol.xmark')).fontSize(16).fontColor(['#AEAEB2']).padding(8)
          .accessibilityText('回到聊天').onClick((): void => { this.openChat(); })
      }.width('100%').height(this.headerHeight()).padding({ left: 16, right: 10, top: 6 })
      Scroll() {
        Column({ space: 10 }) {
          ForEach(this.answerBlocks.slice(0, this.shownBlocks), (b: AiMdBlock): void => {
            Column() { this.block(b) }.width('100%')
              .transition(TransitionEffect.OPACITY.combine(TransitionEffect.translate({ y: 10 })))
          }, (b: AiMdBlock, index: number): string => this.answerMessageId + '-' + index.toString() + b.kind)
          if (this.note !== '') {
            Text(this.note).fontSize(13).lineHeight(19).fontColor(this.phase === 'error' ? '#FF9F0A' : '#AEAEB2').width('100%')
              .transition(TransitionEffect.OPACITY)
          }
          if (this.shownBlocks >= this.answerBlocks.length) {
            ForEach(this.actions, (action: AiChatAction): void => { this.actionButtons(action) },
              (action: AiChatAction): string => action.id + action.status)
            ForEach(this.documents, (name: string): void => {
              Row({ space: 10 }) {
                SymbolGlyph($r('sys.symbol.doc_text')).fontSize(18).fontColor(['#64D2FF'])
                Text(name).fontSize(14).fontColor('#FFFFFF').layoutWeight(1).maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                Text('在聊天里打开').fontSize(12).fontColor('#64D2FF')
              }.width('100%').padding({ left: 12, right: 12, top: 10, bottom: 10 }).borderRadius(16)
              .backgroundColor('#26FFFFFF').onClick((): void => { this.openChat(); })
              .transition(TransitionEffect.OPACITY.combine(TransitionEffect.translate({ y: 8 })))
            }, (name: string): string => 'doc-' + name)
            if (this.suggestions.length > 0 && this.phase !== 'error') {
              Flex({ wrap: FlexWrap.Wrap }) {
                ForEach(this.suggestions, (pill: string): void => {
                  Row({ space: 6 }) {
                    SymbolGlyph($r('sys.symbol.wand_and_stars')).fontSize(12).fontColor(['#C7C7CC'])
                    Text(pill).fontSize(13).fontColor('#FFFFFF').maxLines(1)
                  }.height(32).padding({ left: 12, right: 12 }).margin({ right: 8, bottom: 8 }).borderRadius(16)
                  .backgroundColor('#26FFFFFF').onClick((): void => { this.askPill(pill); })
                }, (pill: string): string => 'pill-' + pill)
              }.width('100%').transition(TransitionEffect.OPACITY)
            }
          }
        }.width('100%').alignItems(HorizontalAlign.Start)
        .onAreaChange((_old: Area, area: Area): void => {
          const height: number = Number(area.height);
          if (Math.abs(height - this.cardContent) > 0.5) { this.morph((): void => { this.cardContent = height; }); }
        })
      }.layoutWeight(1).width('100%').scrollBar(BarState.Off).edgeEffect(EdgeEffect.Spring).align(Alignment.Top)
      .padding({ left: 20, right: 20, bottom: 12 })
      .onClick((): void => {
        // Over the voice while it reads: stop and listen; listening: send what was said.
        if (this.phase === 'speak' || (this.phase === 'answer' && !this.panelListening)) { this.listen(); }
      })
      if (this.panelListening) {
        this.listeningEdge()
      }
    }
    .width(this.cardWidth()).height('100%')
    .opacity(this.contentIn ? 1 : 0)
    .blur(this.contentIn ? 0 : 10)
    .translate({ y: this.contentIn ? 0 : -8 })
  }

  /**
   * The one surface. Its size, corners and place spring from shape to shape; its layers (the glass, the island's
   * black, the card's black top, the droplet's dark core and light, the ring, the card's content) cross-fade inside
   * it in the same animation, so the droplet, the capsule and the card are one thing changing shape.
   */
  @Builder private surface() {
    Stack({ alignContent: Alignment.TopStart }) {
      // The island's black: the droplet and the capsules are solid black throughout, so going from one to the other
      // never passes through a see-through grey.
      Column().width('100%').height('100%').backgroundColor('#FF000000')
        .opacity(this.cardPhase() ? 0 : 1)
      // Card: liquid glass below…
      Column().width('100%').height('100%')
        .backdropBlur(28)
        .backgroundColor(this.dark() ? '#B3141416' : '#A6141416')
        .opacity(this.cardPhase() ? 1 : 0)
      // …and black at the top, where the camera hides.
      Column().width('100%').height('100%')
        .linearGradient({ angle: 180, colors: [['#FF000000', 0],
          ['#FF000000', Math.min(0.6, this.headerHeight() / Math.max(1, this.surfaceHeight()))],
          ['#00000000', Math.min(0.95, (this.headerHeight() + 46) / Math.max(1, this.surfaceHeight()))]] })
        .opacity(this.cardPhase() ? 1 : 0)
      // Droplet: a lens — light gathered low inside the glass.
      Column().width('100%').height('100%')
        .radialGradient({ center: ['50%', '100%'], radius: this.surfaceWidth() * 0.62,
          colors: [['#2EFFFFFF', 0], ['#0DFFFFFF', 0.45], ['#00FFFFFF', 1]] })
        .opacity(this.listening() ? 1 : 0)
      // The light, swelling with the voice; it gathers into the middle as the droplet leaves.
      if (this.listening()) {
        Column() {
          AiSiriBand({ level: this.level, vivid: this.dark() }).width('100%').height('100%')
        }.width('100%').height('100%')
        .opacity(this.paused ? 0.35 : 1)
        .padding({ left: 8, right: 8, top: this.surfaceHeight() * 0.1, bottom: this.surfaceHeight() * 0.16 })
        .transition(TransitionEffect.OPACITY.combine(TransitionEffect.scale({ x: 0.55, y: 0.25 })))
      }
      // Thinking, as in text mode: the ring (it opens from a dot) and the line beside it.
      if (this.phase === 'think') {
        Row() {
          AiThinkingIndicator({ indicatorSize: this.ringSize() })
          Text(this.status).fontSize(17).fontWeight(FontWeight.Medium).fontColor('#FFFFFF')
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1).margin({ left: 38 * this.k() - 10 })
            .transition(TransitionEffect.OPACITY)
            .id('aiVoiceStatus')
        }
        .width(this.cardWidth()).height(this.surfaceHeight())
        .padding({ left: 28 * this.k(), right: 20 * this.k() })
        .transition(TransitionEffect.OPACITY.animation({ duration: 220, delay: 120 }))
      }
      if (this.cardPhase() || this.contentIn) {
        this.cardBody()
      }
      // Closing, as text mode's capsule: the thinking ring (shown open, not opening from a dot — in text mode it was
      // there all along) comes into view as the surface gathers, and sinks into the island with it.
      if (this.closingCapsule()) {
        AiThinkingIndicator({ indicatorSize: this.capsuleRingSize(), opensFromDot: false })
          .position({ x: this.capsuleRingX(), y: (this.surfaceHeight() - this.capsuleRingSize()) / 2 })
          .hitTestBehavior(HitTestMode.None)
          .transition(TransitionEffect.OPACITY)
      }
      // A fine glass edge on the droplet, a hairline on the card, none on the black capsules — but the island's own
      // capsule (closing) has text mode's rim: pale along the bottom, faint at the sides.
      if (this.closingCapsule()) {
        Column().width('100%').height('100%').borderRadius(this.surfaceRadius())
          .border({ width: { top: 0, left: 0.6, right: 0.6, bottom: 1.2 },
            color: { top: '#00FFFFFF', left: '#14FFFFFF', right: '#14FFFFFF', bottom: '#59FFFFFF' } })
          .hitTestBehavior(HitTestMode.None)
          .transition(TransitionEffect.OPACITY.animation({ duration: 200 }))
      } else {
        Column().width('100%').height('100%').borderRadius(this.surfaceRadius())
          .border({ width: this.listening() ? 0.8 : 0.5,
            color: this.listening() ? { top: '#40FFFFFF', left: '#24FFFFFF', right: '#24FFFFFF', bottom: '#4DFFFFFF' } :
              this.cardPhase() ? '#40FFFFFF' : '#00FFFFFF' })
          .hitTestBehavior(HitTestMode.None)
      }
    }
    .width(this.surfaceWidth()).height(this.surfaceHeight())
    .borderRadius(this.surfaceRadius()).clip(true)
    .scale({ x: this.listening() ? 1 - 0.02 * this.level : 1, y: this.listening() ? 1 + 0.045 * this.level : 1, centerY: 0 })
    .shadow({ radius: 26, color: this.cardPhase() ? '#59000000' : '#00000000', offsetY: 10 })
    .onClick((): void => { if (this.listening()) { this.tapDroplet(); } })
  }

  /**
   * Under the droplet: what is being heard, as plain text (no box). The characters come in one at a time (typeIn),
   * each jumping up into place on a lively spring while the ones before glide aside; a correction by the recognizer
   * changes a character where it stands.
   */
  @Builder private transcriptView() {
    Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Center }) {
      if (this.paused) {
        Text('点一下继续说').fontSize(16).lineHeight(26).fontColor(this.dark() ? '#AEAEB2' : '#8E8E93')
          .transition(TransitionEffect.OPACITY)
      } else {
        ForEach(this.transcriptChars(), (ch: string): void => {
          Text(ch).fontSize(18).lineHeight(26).fontWeight(FontWeight.Medium)
            .fontColor(this.dark() ? '#FFFFFF' : '#1C1C1E')
            .textShadow({ radius: 10, color: this.dark() ? '#99000000' : '#F2FFFFFF', offsetX: 0, offsetY: 0 })
            .transition(TransitionEffect.OPACITY.animation({ duration: 160, curve: Curve.EaseOut })
              .combine(TransitionEffect.translate({ y: 16 }))
              .combine(TransitionEffect.scale({ x: 0.3, y: 0.3, centerY: '100%' }))
              .animation({ curve: curves.springMotion(0.3, 0.55) }))
        }, (_ch: string, index: number): string => 'c' + index.toString())
      }
    }
    .width(this.areaWidth - 48)
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      // A tap outside leaves voice mode for the chat (a held press simply ends).
      Column().width('100%').height('100%').backgroundColor(Color.Transparent)
        .onClick((): void => { if (this.mode === 'hold') { this.close(); } else { this.openChat(); } })
      Stack() { this.surface() }
        .position({ x: (this.areaWidth - this.surfaceWidth()) / 2, y: this.surfaceTop() })
        .opacity(this.shown ? 1 : 0)
        .scale({ x: this.leaving ? 0.7 : 1, y: this.leaving ? 0.7 : 1, centerX: '50%', centerY: 0 })
        .gesture(PanGesture({ direction: PanDirection.Up, distance: 24 })
          .onActionEnd((event: GestureEvent): void => { if (event.offsetY < -40) { this.close(); } }))
      if (this.listening() && (this.transcript !== '' || this.paused)) {
        Stack() { this.transcriptView() }
          .position({ x: 24, y: this.surfaceTop() + this.surfaceHeight() + 14 })
          .transition(TransitionEffect.OPACITY.animation({ duration: 200 }))
          .hitTestBehavior(HitTestMode.None)
      }
    }
    .width('100%').height('100%')
    .onAreaChange((_old: Area, area: Area): void => {
      const w: number = Number(area.width);
      const h: number = Number(area.height);
      if (w > 0 && h > 0 && (Math.abs(w - this.areaWidth) > 1 || Math.abs(h - this.areaHeight) > 1)) {
        this.areaWidth = w; this.areaHeight = h;
      }
    })
  }
}
