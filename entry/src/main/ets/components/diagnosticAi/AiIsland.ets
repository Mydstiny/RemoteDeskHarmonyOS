import { ComponentContent, curves, display, LevelOrder, promptAction, window } from '@kit.ArkUI';
import { inputMethod } from '@kit.IMEKit';
import { DiagnosticAiAssistantPanel } from './DiagnosticAiAssistantPanel';
import { DiagnosticAiAppActionId, diagnosticAiAppActionId, diagnosticAiAppActionLabel, diagnosticAiAppActionMode } from '../../services/diagnosticAi/DiagnosticAiAppActionPolicy';
import { AI_FLOAT_ORB, AiIslandGlass } from './AiIslandChrome';
import { AiThinkingIndicator } from './AiMotionViews';
import { AiLiftController, aiLiftLayer } from './AiLiftLayer';
import { AI_VOICE_REQUEST, AiChatMemory } from './AiChatView';
import { AI_VOICE_ENABLED } from '../../services/diagnosticAi/AiVoiceSettings';
import { AiReadAloud } from '../../services/diagnosticAi/AiSpeech';
import { AI_FLOAT_REQUEST, AI_HANDOVER_FADE_DELAY_MS, AI_HANDOVER_FADE_MS, AI_HANDOVER_RECT, AI_MODE_REQUEST } from '../../services/diagnosticAi/AiBridgeKeys';
import { AI_ORB_HINT_TEXT, aiOrbHintWanted } from '../../services/diagnosticAi/AiOrbHintStore';
import { aiIsSessionPage } from '../../services/diagnosticAi/AiSessionRouter';
import { AI_STYLE, AI_STYLE_WASH, aiInk, aiStyleIsXiaoyi, aiXiaoyiWash } from '../../services/diagnosticAi/AiStylePolicy';
import { aiPanelHeightShare, aiPanelRadius, aiPanelWidth, aiReclampOrb, aiSurfaceScale } from '../../services/diagnosticAi/AiSurfaceGeometry';
import { AI_MOTION_DONE, AI_MOTION_OPEN, aiMotionStyle } from '../../services/diagnosticAi/DiagnosticAiMotionPolicy';

export type DiagnosticAiDeviceClass = 'phone' | 'pad' | 'pc';

/**
 * Island geometry, from the reference GIF measured on a 375-wide logical canvas (source pixels ÷ 2) and scaled by the
 * window width on phones. These are estimates for reproduction, not platform constants.
 */
const AI_COMPACT_WIDTH: number = 226;   // F000 capsule ≈ 453 × 116 source px
const AI_COMPACT_HEIGHT: number = 58;
const AI_STATUS_HEIGHT: number = 97.5;  // F014 wide capsule ≈ 706 × 195 source px
const AI_TOP: number = 12.5;            // capsule and panels share this top anchor
const AI_RING_COMPACT: number = 34;     // six-core ring, orbit radius ≈ 12.4
const AI_RING_STATUS: number = 42;      // grows with the wide capsule
const AI_PHONE_ISLAND_WIDTH: number = 296; // phone capsule: room for a system island with a live activity
/** The lifted orb's layer: above the island's own (AiTopLayer, 99990), under voice mode (99995). */
const AI_LIFT_ORDER: number = 99992;

/**
 * 启动 AI 辅助 as one continuously morphing surface at the top of the window, rebuilt from the iOS 27 Siri reference
 * (14-send-wechat.gif, F000–F101) and its frame notes:
 *
 * compact  — black capsule at the top center; on a phone it encloses the Dynamic Island from the start while the
 *            thinking ring sits lower, under the status bar, clear of live system islands;
 * status   — the same surface widens to both sides and grows down, the ring moves lower-left and grows, the task line
 *            appears to its right;
 * panel    — it keeps growing down into the conversation panel: old content fades and defocuses while the question
 *            field comes into focus; on a phone the top edge rises over the camera so the open panel encloses it;
 * float    — while a capture or analysis runs it gathers back into a capsule on the island with the thinking ring; the
 *            app stays usable underneath; when the work ends it opens into the panel with the result.
 *
 * Closing runs the other way (panel → capsule → gone). There is one glass (AiIslandGlass) whose size, radius and
 * material follow the geometry through every step. The panel hosts DiagnosticAiAssistantPanel without a shell, so
 * capture, analysis and entitlement checks are unchanged.
 */
@Component
export struct AiIsland {
  @StorageProp('diagnosticAiReducedMotion') reducedMotion: boolean = false;
  @StorageProp(AI_STYLE) aiStyle: string = 'siri';
  @StorageProp(AI_STYLE_WASH) aiWash: string = 'on';
  @StorageProp('currentTheme') theme: string = 'light';
  /** Another surface (voice mode) is taking over: fold away as a close would. */
  @StorageProp('aiIsland.closeRequest') @Watch('onCloseRequest') closeRequest: number = 0;
  /** The chat asked for an app screen ('<id>@<time>'): open it as the assistant's own steps do. */
  @StorageProp('aiIsland.appAction') @Watch('onAppActionRequest') appActionRequest: string = '';
  /** The AI's float_orb tool: the open panel floats as the orb, as its own 缩成悬浮球 does. */
  @StorageProp(AI_FLOAT_REQUEST) @Watch('onFloatRequest') floatRequest: number = 0;
  /** Voice mode floated: the island starts as the orb (a tap brings voice mode back). */
  @Prop startFloat: boolean = false;
  /** Starting as the orb: with its small chat already shown (a session's AI the host list carries on). */
  @Prop startChat: boolean = false;
  /** Distance from the window top to the safe area (status bar); used only where there is no island anchor. */
  @Prop topInset: number = 24;
  @Prop deviceClass: DiagnosticAiDeviceClass = 'phone';
  /** Open straight into the panel (taking over from the voice card at the same place) rather than through the capsules. */
  @Prop quickOpen: boolean = false;
  /** Voice mode confirmed an app screen: start as text mode's action does (status capsule → done mark → orb). */
  @Prop startAction: string = '';
  /**
   * In a remote session (SessionAiHost): the AI appears as the orb with its small text chat; on that orb a tap
   * leaves the AI, a double tap starts voice mode and a long press drags it, clear of the session's side bar.
   */
  @Prop sessionMode: boolean = false;
  /** The session's side bar: which edge ('right' · 'left' · '') and how wide (vp), for the orb to keep clear of. */
  @Prop sessionAvoidSide: string = '';
  @Prop sessionAvoidWidth: number = 0;
  /** Whether this AI answers requests now (a session's: while it is the one in front; see AiSessionRouter). */
  answersNow: () => boolean = (): boolean => true;
  /** The AI top layer this island lives in: back keys are '<surface>:<layerId>@<time>' (see AiTopLayer). */
  @Prop layerId: string = '';
  /**
   * The back key reached the AI layer: an open panel folds away; a screen an app action opened closes; otherwise a
   * floating orb (or the AI in a session) goes away. A running capture or analysis is never stopped by it.
   */
  @StorageProp('aiTop.back') @Watch('onBackKey') backKey: string = '';
  /** In a session there is no panel to act on 拜拜 / 语音模式 / 回到文字 in the small chat: the island does it. */
  @StorageProp(AI_MODE_REQUEST) @Watch('onSessionModeRequest') modeRequest: string = '';
  onDismissed: () => void = (): void => {};
  /** Floating or not: the host lets touches through its overlay node only while the island floats. */
  onFloatingChanged: (floating: boolean) => void = (_floating: boolean): void => {};
  /** Mirrors provider thinking/capture activity to the persistent entry button on the host page. */
  onActivityChanged: (active: boolean) => void = (_active: boolean): void => {};
  onCaptureStateChanged: (capturing: boolean) => void = (_capturing: boolean): void => {};
  /** Opens the app screen an answer's step points to. */
  onAppAction: (action: DiagnosticAiAppActionId) => void = (_action: DiagnosticAiAppActionId): void => {};
  /** Whether a screen opened for an app action is showing. */
  isAppActionScreenOpen: () => boolean = (): boolean => false;
  /** Closes that screen (the user went back to the conversation from the orb). */
  closeAppActionScreen: () => void = (): void => {};
  /**
   * An app action is running (its label): the panel steps back to the status capsule with the thinking ring. When
   * the screen it opened is up, a drawn check says it is done and the assistant becomes the floating orb.
   */
  @State private executing: string = '';
  private executingPoll: number = -1;
  private executingClosedTicks: number = 0;
  private executingSawScreen: boolean = false;
  private executingStartedAt: number = 0;
  /** The done mark and then the floating orb, in one full-window layer above opened screens (AiLiftLayer). */
  private liftLayer: ComponentContent<AiLiftController> | null = null;
  private liftController: AiLiftController | null = null;
  private liftMode: string = 'assistant';
  /** Something of the island is lifted into the dialog layer (above opened screens); the island hides meanwhile. */
  @State private lifted: boolean = false;
  /** 0 hidden · 1 compact capsule · 2 status capsule · 3 panel (or the floating capsule while working). */
  @State private stage: number = 0;
  @State private working: boolean = false;
  @State private compact: boolean = false;
  /**
   * The content's own compact switch. The glass animates between orb and panel; the content swaps between the orb
   * and the panel (and takes its final width) at once, while it is faded out — never re-laid out at every in-between
   * width, which made opening from the orb stutter.
   */
  @State private contentCompact: boolean = false;
  /** A finger is down on the orb: it gives a little at once (a single tap waits for the double-tap window). */
  @State private orbPressed: boolean = false;
  /** The panel content is mounted from the status stage on (hidden) so its size is known before the panel opens. */
  @State private panelMounted: boolean = false;
  @State private revealed: boolean = false;
  @State private contentOpacity: number = 0;
  @State private contentBlur: number = 12;
  @State private statusOpacity: number = 0;
  @State private statusBlur: number = 8;
  /** The capsule comes in out of focus and sharpens as it settles, as in the reference recording. */
  @State private islandBlur: number = 14;
  /** Height of the panel content as last laid out; the glass morphs to it. */
  @State private cardHeight: number = 0;
  /** Taking over from the voice card: the glass waits unseen at its place until the card has grown to it. */
  @State private glassIn: number = 1;
  /** Until the cross-fade starts, the glass's place is told to the voice card again whenever it changes. */
  private handoverOpen: boolean = false;
  private handoverSent: boolean = false;
  private handoverFading: boolean = false;
  @State private dragX: number = 0;
  @State private dragY: number = 0;
  private dragStartX: number = 0;
  private dragStartY: number = 0;
  /** The island anchor: on a phone with a top cutout, the camera; elsewhere the top center. */
  @State private anchorTop: number = -1;
  /** The camera cutout (phone): where the island is, and its size. */
  private islandTop: number = -1;
  private islandPillWidth: number = 120;
  private islandPillHeight: number = 36;
  @State private areaWidth: number = 360;
  @State private areaHeight: number = 720;
  private timers: number[] = [];
  private closing: boolean = false;
  private statusBarHidden: boolean = false;
  /** Height of the soft keyboard (vp); the open panel always ends above it. */
  @State private keyboardHeight: number = 0;
  /** Folding away for voice mode (AiVoiceIsland takes over from the capsule). */
  @State private handingOver: boolean = false;
  /** The island's own orb (capture, floating action): its one-time hint. */
  @State private compactHint: boolean = false;
  /**
   * Whether the touch now being handled began on the orb. The orb's tap gestures run alongside the panel's own, and a
   * single tap is only recognised once the double-tap wait is over: by then a tap on 缩成悬浮球 has made the island
   * compact, and would otherwise open it again at once.
   */
  private touchStartedCompact: boolean = false;
  private keyboardWindow: window.Window | null = null;
  /** Fences delayed compact morphs so a rapid capture stop/start cannot apply an old layout. */
  private compactGeneration: number = 0;
  private readonly onKeyboard = (height: number): void => {
    this.keyboardHeight = this.getUIContext().px2vp(height);
  };

  aboutToAppear(): void {
    this.placeOnCutout();
    const context = this.getUIContext().getHostContext();
    if (context) {
      window.getLastWindow(context).then((win: window.Window): void => {
        this.keyboardWindow = win;
        try { win.on('keyboardHeightChange', this.onKeyboard); } catch (_error) { /* no keyboard events */ }
      }).catch((): void => { /* no window */ });
    }
    this.later(16, (): void => {
      const action: DiagnosticAiAppActionId | null = this.startAction !== '' ? diagnosticAiAppActionId(this.startAction) : null;
      if (this.sessionMode) {
        // In a session: no panel at all — the orb with its small text chat, right away. The island itself never
        // shows (it stays at stage 0 and takes no touches), so the session underneath keeps every touch.
        AiChatMemory.active = true;
        this.later(30, (): void => { this.liftSession(); });
        return;
      }
      if (action === null && this.startFloat) {
        // From voice: no panel to show — the orb appears at its spot at the edge, above whatever is on screen (no
        // panel-sized empty glass shrinking into it first). The island waits hidden behind it, already as the orb.
        this.panelMounted = true;
        this.islandBlur = 0;
        this.contentCompact = true;
        this.compact = true;
        this.lifted = true;
        this.stage = 3;
        this.onFloatingChanged(true);
        this.later(30, (): void => {
          this.dragX = this.areaWidth / 2 - AI_FLOAT_ORB / 2 - 14;
          this.dragY = this.areaHeight * 0.3;
          this.liftUp('', 'none', AiChatMemory.active ? 'chat' : 'assistant', 'chat', this.startChat && AiChatMemory.active,
            (this.areaWidth - AI_FLOAT_ORB) / 2 + this.dragX, this.topOffset() + this.dragY);
          // Should the layer not open, the island's own orb shows instead.
          this.later(400, (): void => { if (this.liftLayer === null) { this.lifted = false; } });
        });
        return;
      }
      if (action === null) { this.open(); return; }
      this.setStatusBarHidden(true);
      // From voice: the panel is there but hidden, and the action's status capsule grows out of the island at once.
      this.panelMounted = true;
      this.islandBlur = 0;
      this.morph((): void => { this.stage = 3; });
      this.runAppAction(action);
    });
  }

  aboutToDisappear(): void {
    this.clearTimers();
    this.stopExecutingPoll();
    this.closeLift();
    if (this.keyboardWindow !== null) {
      try { this.keyboardWindow.off('keyboardHeightChange', this.onKeyboard); } catch (_error) { /* already off */ }
      this.keyboardWindow = null;
    }
    if (!this.handingOver) { this.setStatusBarHidden(false); }
  }

  /**
   * On a phone the open panel covers the top of the screen like Siri's; the status bar would otherwise draw its
   * time and icons on top of the black. It is hidden while the panel is open and comes back for the capsules.
   */
  private setStatusBarHidden(hidden: boolean): void {
    // A session keeps its own system bars (most run full screen): the AI never shows or hides them there — neither
    // a session's own AI nor the host list's still floating over a session page.
    if (this.sessionMode || this.deviceClass !== 'phone') { return; }
    // The flag EntryAbility reads (a 0 status bar inset while the AI hides the bar is not the real inset): always the
    // latest request, so it can never stay set after the AI is gone.
    if (this.sessionPageOnTop()) { this.statusBarHidden = false; AppStorage.setOrCreate('ai.statusBarHidden', false); return; }
    AppStorage.setOrCreate('ai.statusBarHidden', hidden);
    if (hidden === this.statusBarHidden) { return; }
    this.statusBarHidden = hidden;
    const context = this.getUIContext().getHostContext();
    if (!context) { return; }
    window.getLastWindow(context).then((win: window.Window): void => {
      win.setSpecificSystemBarEnabled('status', !hidden, true).catch((): void => { /* keep the bar as it is */ });
    }).catch((): void => { /* no window */ });
  }

  private sessionPageOnTop(): boolean {
    try { return aiIsSessionPage(this.getUIContext().getRouter().getState().name); } catch (_error) { return false; }
  }

  private later(ms: number, action: () => void): void {
    this.timers.push(setTimeout(action, this.reducedMotion ? 0 : ms));
  }
  private clearTimers(): void {
    this.compactGeneration++;
    this.timers.forEach((id: number): void => { clearTimeout(id); });
    this.timers = [];
  }

  /** Phones scale the reference by width; larger windows keep its phone proportions. */
  /** The phone's scale from its short side (so a session turned sideways keeps the upright sizes); 1 elsewhere. */
  private k(): number { return aiSurfaceScale(this.deviceClass, this.areaWidth, this.areaHeight); }

  /**
   * On a phone with a camera cutout the surface encloses the Dynamic Island from the first frame, but its content
   * (the thinking ring and status line) sits lower, just under the status bar: this is an in-app surface, not a
   * system one, so its content must stay clear of a live system island (recording, calls, timers) on the camera.
   * This is the extra height above the content.
   */
  private headroom(): number {
    // The floating capsule is a plain capsule under the status bar, clear of the system island.
    if (this.deviceClass !== 'phone' || this.anchorTop < 0 || this.compact) { return 0; }
    return Math.max(0, this.topInset + 6 - this.anchorTop);
  }

  private topOffset(): number {
    if (this.deviceClass === 'phone' && this.compact) { return this.topInset + 6; }
    if (this.anchorTop >= 0) { return this.anchorTop; }
    if (this.deviceClass === 'phone' || this.deviceClass === 'pc') { return this.topInset + 6; }
    return AI_TOP * this.k();
  }

  private cutoutGeneration: number = 0;

  /** Find a top camera cutout so the open panel's top edge encloses it, as the Dynamic Island does. */
  private placeOnCutout(): void {
    // Read again after a rotation: sideways, the camera is at a side and the island hangs under the status bar.
    // A newer read (after a rotation) wins over one still on its way.
    const generation: number = ++this.cutoutGeneration;
    this.anchorTop = -1;
    this.islandTop = -1;
    if (this.deviceClass !== 'phone' || this.areaWidth > this.areaHeight) { return; }
    try {
      const screen: display.Display = display.getDefaultDisplaySync();
      const ui = this.getUIContext();
      screen.getCutoutInfo().then((info: display.CutoutInfo): void => {
        if (generation !== this.cutoutGeneration || this.areaWidth > this.areaHeight) { return; }
        const rects: display.Rect[] = info.boundingRects;
        for (let i: number = 0; i < rects.length; i++) {
          const top: number = ui.px2vp(rects[i].top);
          const height: number = ui.px2vp(rects[i].height);
          if (top > 60 || height <= 0) { continue; }
          this.anchorTop = Math.max(2, Math.min(AI_TOP * this.k(), top - 8));
          // The done mark opens out of the island itself: a pill just around the camera.
          this.islandPillWidth = Math.max(100, ui.px2vp(rects[i].width) + 18);
          this.islandPillHeight = Math.max(32, height + 8);
          this.islandTop = Math.max(0, top - 4);
          return;
        }
      }).catch((): void => { /* no cutout: top center */ });
    } catch (_error) { /* no display info: top center */ }
  }

  /** Geometry: quick build-up with a small settle, no toy bounce. */
  private morph(action: () => void): void {
    if (this.reducedMotion) { action(); return; }
    this.getUIContext().animateTo({ curve: curves.springMotion(0.42, 0.86) }, action);
  }

  private fade(duration: number, delay: number, action: () => void): void {
    if (this.reducedMotion) { action(); return; }
    this.getUIContext().animateTo({ duration: duration, delay: delay, curve: Curve.EaseOut }, action);
  }

  private open(): void {
    // Above the status bar from the first capsule (as the open panel is), so the system's own island — a live
    // activity — does not draw over it.
    this.setStatusBarHidden(true);
    if (this.quickOpen) { this.openFromVoice(); return; }
    const style: string = aiMotionStyle(AI_MOTION_OPEN);
    if (style !== 'morph') { this.openDirect(style); return; }
    this.morph((): void => { this.stage = 1; });
    this.fade(460, 80, (): void => { this.islandBlur = 0; });
    // compact → status: widen to both sides, grow down; the ring moves and grows, the task line comes into focus.
    this.later(560, (): void => {
      this.panelMounted = true;
      this.morph((): void => { this.stage = 2; });
      this.fade(260, 140, (): void => { this.statusOpacity = 1; this.statusBlur = 0; });
    });
    this.later(1240, (): void => { this.revealPanel(); });
  }

  /**
   * AI 动效 › 展开动画 other than the island morph: the panel is laid out first (hidden), then fades in where it
   * belongs, or simply appears.
   */
  private openDirect(style: string): void {
    this.panelMounted = true;
    // 模糊聚焦 starts out of focus; the others start sharp.
    this.islandBlur = style === 'focus' ? 18 : 0;
    this.later(60, (): void => {
      this.setStatusBarHidden(true);
      if (style === 'liquid') {
        // From the island with an elastic overshoot: a low-damping spring on the whole surface.
        this.getUIContext().animateTo({ curve: curves.springMotion(0.55, 0.58) }, (): void => {
          this.stage = 3; this.contentOpacity = 1; this.contentBlur = 0;
        });
      } else if (style === 'focus') {
        this.getUIContext().animateTo({ duration: 420, curve: Curve.EaseOut }, (): void => {
          this.stage = 3; this.contentOpacity = 1; this.contentBlur = 0; this.islandBlur = 0;
        });
      } else if (style === 'fade') {
        this.getUIContext().animateTo({ duration: 280, curve: Curve.EaseOut }, (): void => {
          this.stage = 3; this.contentOpacity = 1; this.contentBlur = 0;
        });
      } else {
        this.stage = 3; this.contentOpacity = 1; this.contentBlur = 0;
      }
      this.later(style === 'none' ? 20 : 340, (): void => { this.revealed = true; });
    });
  }

  /**
   * From voice mode: the panel is laid out at once, unseen; the voice card (above it) grows to the glass's exact
   * place and shape, then the two cross-fade — the card's dark glass becomes this one, and the chat focuses in.
   */
  private openFromVoice(): void {
    this.panelMounted = true;
    this.islandBlur = 0;
    this.glassIn = 0;
    this.contentOpacity = 0;
    this.contentBlur = 14;
    this.stage = 3;
    this.handoverOpen = true;
    // Once the content has been measured (onCardSize), or after a moment with whatever it has.
    this.later(this.reducedMotion ? 0 : 200, (): void => { this.publishHandover(); });
  }

  private publishHandover(): void {
    if (!this.handoverOpen || this.handoverFading) { return; }
    const first: boolean = !this.handoverSent;
    this.handoverSent = true;
    AppStorage.setOrCreate(AI_HANDOVER_RECT, [this.topOffset(), this.glassWidth(), this.glassHeight(), this.glassRadius(),
      Date.now()].map((n: number): string => n.toFixed(1)).join(','));
    if (!first) { return; }
    this.later(this.reducedMotion ? 0 : AI_HANDOVER_FADE_DELAY_MS, (): void => {
      this.handoverFading = true;
      this.setStatusBarHidden(true);
      const show = (): void => { this.glassIn = 1; this.contentOpacity = 1; this.contentBlur = 0; };
      if (this.reducedMotion) { show(); } else {
        this.getUIContext().animateTo({ duration: AI_HANDOVER_FADE_MS, curve: Curve.EaseInOut }, show);
      }
      this.later(this.reducedMotion ? 0 : AI_HANDOVER_FADE_MS, (): void => { this.revealed = true; this.handoverOpen = false; });
    });
  }

  /** status → panel: the status line and ring fade and defocus while the surface keeps growing; content focuses in. */
  private revealPanel(): void {
    this.setStatusBarHidden(true);
    this.fade(180, 0, (): void => { this.statusOpacity = 0; this.statusBlur = 8; });
    this.morph((): void => { this.stage = 3; });
    this.fade(300, 90, (): void => { this.contentOpacity = 1; this.contentBlur = 0; });
    this.later(320, (): void => { this.revealed = true; });
  }

  private setCompact(value: boolean, hint: boolean = true): void {
    if (value === this.compact) { return; }
    // The island's own orb, floating over a screen voice mode opened: back to voice mode.
    if (!value && AiChatMemory.voiceResume && !this.working) { this.resumeVoice(); return; }
    // Back to the panel: an orb lifted from the island's own orb goes with it.
    if (!value && this.liftLayer !== null) { this.closeLift(); this.lifted = false; }
    if (value && hint && !this.lifted && aiOrbHintWanted(this.getUIContext().getHostContext(), 'compact')) {
      this.later(700, (): void => {
        this.getUIContext().animateTo({ duration: 220, curve: Curve.EaseOut }, (): void => { this.compactHint = true; });
      });
      this.later(3900, (): void => {
        this.getUIContext().animateTo({ duration: 260, curve: Curve.EaseIn }, (): void => { this.compactHint = false; });
      });
    }
    // A new compact transition supersedes opening/reveal timers from the prior
    // state; otherwise a delayed panel reveal can reopen over a live orb.
    this.clearTimers();
    const generation: number = ++this.compactGeneration;
    if (value) {
      try { inputMethod.getController().hideTextInput(); } catch (_error) { /* keyboard already down */ }
    }
    this.setStatusBarHidden(!value);
    // Content loses focus first; then in one spring the surface shrinks into the orb while it travels to the right
    // edge (or grows back from there into the panel at the top), so it reads as one object moving, never a jump.
    this.fade(110, 0, (): void => {
      if (generation !== this.compactGeneration) { return; }
      this.contentOpacity = 0; this.contentBlur = 10;
    });
    this.later(110, (): void => {
      if (generation !== this.compactGeneration) { return; }
      // The content is faded out now: swap it outside any animation, at its final width.
      this.contentCompact = value;
      const applyCompact = (): void => {
        if (generation !== this.compactGeneration) { return; }
        this.compact = value;
        // The orb floats at the right edge, a third of the way down, out of the way of the page's content.
        this.dragX = value ? this.areaWidth / 2 - AI_FLOAT_ORB / 2 - 14 : 0;
        this.dragY = value ? this.areaHeight * 0.3 : 0;
      };
      if (this.reducedMotion) { applyCompact(); }
      else { this.getUIContext().animateTo({ curve: curves.springMotion(0.55, 0.8) }, applyCompact); }
      this.fade(280, value ? 180 : 260, (): void => {
        if (generation !== this.compactGeneration) { return; }
        this.contentOpacity = 1; this.contentBlur = 0;
      });
    });
    this.onFloatingChanged(value);
  }

  /**
   * Thinking stays in the panel, as Siri answers in place. Only a capture — where the user has to go and reproduce
   * the problem in the app — gathers the island into the floating orb; when it ends the panel opens again and shows
   * the analysis there.
   */
  private onWorkChanged(active: boolean): void {
    this.working = active;
    this.onActivityChanged(active);
  }

  private onCaptureChanged(capturing: boolean): void {
    this.onCaptureStateChanged(capturing);
    this.setCompact(capturing);
  }

  private runAppAction(action: DiagnosticAiAppActionId): void {
    if (this.executing !== '') { return; }
    const mode = diagnosticAiAppActionMode(action);
    if (mode === 'inline') {
      // Inline actions keep the Siri card open and reuse the same guarded callback as a normal tap.
      this.onAppAction(action);
      return;
    }
    if (mode === 'floating') {
      // Long-running work and diagnostic surfaces leave the page usable; the user can tap the orb to reopen the card.
      this.setCompact(true);
      this.later(220, (): void => { this.onAppAction(action); });
      return;
    }
    try { inputMethod.getController().hideTextInput(); } catch (_error) { /* keyboard already down */ }
    // The status capsule stays above the status bar too; the bar comes back with the orb (setCompact).
    this.setStatusBarHidden(true);
    this.fade(120, 0, (): void => { this.contentOpacity = 0; this.contentBlur = 10; });
    this.morph((): void => { this.executing = '正在执行：' + diagnosticAiAppActionLabel(action); });
    this.fade(240, 160, (): void => { this.statusOpacity = 1; this.statusBlur = 0; });
    this.onFloatingChanged(true);
    this.later(220, (): void => { this.onAppAction(action); });
    this.executingClosedTicks = 0;
    this.executingSawScreen = false;
    this.executingStartedAt = Date.now();
    this.stopExecutingPoll();
    this.executingPoll = setInterval((): void => { this.watchAppAction(); }, 300);
  }

  /** Done once the opened screen is up (an action that opens no screen of its own, such as a tab switch, is done
   * after a moment). */
  private watchAppAction(): void {
    const open: boolean = this.isAppActionScreenOpen();
    if (this.executing !== '') {
      if (open) { this.executingSawScreen = true; this.completeAppAction(true); return; }
      if (Date.now() - this.executingStartedAt > 1500) { this.completeAppAction(false); }
      return;
    }
    this.stopExecutingPoll();
  }

  private completeAppAction(_screenOpen: boolean): void {
    const label: string = this.executing.replace('正在执行：', '已完成：');
    const style: string = aiMotionStyle(AI_MOTION_DONE);
    // The done mark plays above the opened screen and then turns into the orb in place; the orb and its mini chat
    // stay there, above whatever the user opens or taps next, until the orb itself is tapped.
    this.liftUp(label, style);
    this.lifted = true;
    this.stopExecutingPoll();
    this.later(style === 'none' ? 0 : style === 'island' ? 1250 : 1150, (): void => {
      if (this.liftController !== null) { this.liftController.toOrb(); }
      this.executing = '';
      this.statusOpacity = 0;
      this.setCompact(true);
    });
  }

  /**
   * 聊天's 缩成悬浮球: the orb goes straight into the lift layer, above whatever the user opens next; a tap on it
   * shows the small chat, whose 展开 brings the island back.
   */
  private floatChat(): void {
    if (this.liftLayer !== null || this.compact) { return; }
    try { inputMethod.getController().hideTextInput(); } catch (_error) { /* keyboard already down */ }
    // The island shrinks into the orb as it always does; once the orb rests at the edge, the same orb moves into the
    // lift layer where it is (above whatever the user opens next, with its small chat a double tap away).
    this.setCompact(true, false);
    const generation: number = this.compactGeneration;
    this.later(this.reducedMotion ? 0 : 640, (): void => {
      if (generation !== this.compactGeneration || !this.compact || this.liftLayer !== null) { return; }
      const x: number = (this.areaWidth - AI_FLOAT_ORB) / 2 + this.dragX;
      const y: number = this.topOffset() + this.dragY;
      this.liftUp('', 'none', AiChatMemory.active ? 'chat' : 'assistant', 'chat', false, x, y);
      // The layer fades in over the island's orb (same orb, same spot); then the island's steps aside.
      this.later(140, (): void => { if (this.liftLayer !== null) { this.lifted = true; } });
    });
  }

  /** In a session: the orb, with its small chat open, at the edge away from the session's side bar. */
  private liftSession(): void {
    if (this.liftLayer !== null) { return; }
    const left: boolean = this.sessionAvoidSide === 'right';
    const x: number = left ? 14 : this.areaWidth - AI_FLOAT_ORB - 14;
    const y: number = Math.max(this.topInset + 8, this.areaHeight * 0.22);
    this.liftUp('', 'none', 'chat', 'session', true, x, y);
    this.later(140, (): void => { if (this.liftLayer !== null) { this.lifted = true; } });
  }

  /**
   * A tap on the session orb, or the back key while the AI floats: the AI goes away at once (the orb's own fade), and
   * the page underneath is back as it was.
   */
  private leaveFromOrb(): void {
    if (this.closing) { return; }
    this.closing = true;
    AiChatMemory.voiceResume = false;
    this.closeLift();
    this.lifted = false;
    this.stopExecutingPoll();
    this.clearTimers();
    this.stage = 0;
    this.setStatusBarHidden(false);
    this.onDismissed();
  }

  /** 语音模式 in a session: the orb's own voice mode (SessionAiHost; no voice ball over the session). */
  private voiceFromOrb(): void {
    if (AppStorage.get<boolean>(AI_VOICE_ENABLED) !== true) {
      try {
        this.getUIContext().getPromptAction().showToast({ message: 'AI 语音还没打开，可以在「设置 → AI 语音」里开启', duration: 2200 });
      } catch (_error) { /* no toast */ }
      return;
    }
    AppStorage.setOrCreate(AI_VOICE_REQUEST, Date.now());
  }

  /** Open the lift layer: the 完成动画 first (or the orb right away when it is 不显示). */
  private liftUp(label: string, style: string, mode: string = 'assistant', hintPath: string = 'action',
    openChat: boolean = false, startX: number = -1, startY: number = -1): void {
    if (this.liftLayer !== null) { return; }
    const controller: AiLiftController = new AiLiftController();
    controller.mode = mode;
    controller.hintPath = hintPath;
    controller.openChat = openChat;
    controller.startX = startX;
    controller.startY = startY;
    this.liftMode = mode;
    controller.onActivityChanged = (active: boolean): void => { this.onWorkChanged(active); };
    controller.deviceClass = this.deviceClass;
    controller.islandTop = this.islandTop;
    controller.pillWidth = this.islandPillWidth;
    controller.pillHeight = this.islandPillHeight;
    controller.topInset = this.topInset;
    controller.areaWidth = this.areaWidth;
    controller.areaHeight = this.areaHeight;
    controller.startWith = style === 'none' ? 'orb' : 'done';
    controller.label = label;
    controller.style = style;
    controller.onOrbTap = (x: number, y: number): void => { this.backFromOrb(x, y); };
    controller.sessionMode = this.sessionMode;
    controller.avoidSide = this.sessionAvoidSide;
    controller.avoidWidth = this.sessionAvoidWidth;
    controller.onExit = (): void => { this.leaveFromOrb(); };
    controller.onVoice = (): void => { this.voiceFromOrb(); };
    controller.place = (dx: number, dy: number): void => {
      const layer: ComponentContent<AiLiftController> | null = this.liftLayer;
      if (layer === null) { return; }
      this.getUIContext().getPromptAction().updateCustomDialog(layer, {
        alignment: DialogAlignment.TopStart, offset: { dx: dx, dy: dy }
      }).catch((): void => { /* the layer already closed */ });
    };
    const content: ComponentContent<AiLiftController> =
      new ComponentContent(this.getUIContext(), wrapBuilder(aiLiftLayer), controller);
    this.liftController = controller;
    this.liftLayer = content;
    const options: promptAction.BaseDialogOptions = {
      isModal: false,
      autoCancel: false,
      // Above the app's own dialogs and sheets opened later (a delete confirmation, a settings page), and above the
      // island's own layer (whose hidden orb would otherwise take the lifted orb's touches): AI stays on top.
      levelOrder: LevelOrder.clamp(AI_LIFT_ORDER),
      // The back key: the island decides (as for its own layer); the orb never just disappears.
      onWillDismiss: (_action: DismissDialogAction): void => {
        AppStorage.setOrCreate('aiTop.back', 'island:' + this.layerId + '@' + Date.now().toString());
      },
      alignment: DialogAlignment.TopStart,
      offset: { dx: 0, dy: 0 },
      maskColor: Color.Transparent,
      // The layer moves the orb and chat itself; it must not be pushed around by the keyboard.
      keyboardAvoidMode: KeyboardAvoidMode.NONE,
      transition: TransitionEffect.OPACITY.animation({ duration: 120 })
    };
    this.getUIContext().getPromptAction().openCustomDialog(content, options)
      .catch((): void => {
        this.liftLayer = null; this.liftController = null; content.dispose();
        // A session's AI is only this orb: without it, the AI goes (its button can open it again).
        if (this.sessionMode) { this.leaveFromOrb(); }
      });
  }

  /** Hand back to voice mode: the orb (lifted or the island's own) goes, and voice mode opens on its last answer. */
  private resumeVoice(): void {
    AiChatMemory.voiceResume = false;
    // Voice mode takes over at once (and keeps the status bar hidden): nothing to give back here.
    this.handingOver = true;
    this.closeLift();
    this.lifted = false;
    this.stopExecutingPoll();
    this.clearTimers();
    this.stage = 0;
    this.onDismissed();
    AppStorage.setOrCreate('aiVoice.resumeRequest', Date.now());
  }

  /**
   * The orb was tapped: close the screen the action opened and open the panel again, growing out of the spot where
   * the orb was (x, y: its top-left in the window) rather than from where the island last floated.
   */
  private backFromOrb(x: number, y: number): void {
    // A session has no panel to come back to (its orb's tap leaves the AI instead).
    if (this.sessionMode) { return; }
    // A screen an app action opened closes; whatever the user opened while 聊天 floated stays.
    if (this.liftMode !== 'chat') { this.closeAppActionScreen(); }
    // The action came from voice mode: the orb brings voice mode back (its panel, listening), not the text panel.
    if (AiChatMemory.voiceResume) { this.resumeVoice(); return; }
    this.dragX = x - (this.areaWidth - AI_FLOAT_ORB) / 2;
    this.dragY = Math.max(0, y - this.topOffset());
    this.closeLift();
    this.lifted = false;
    this.stopExecutingPoll();
    this.setCompact(false);
  }

  /**
   * A double tap on the island's own orb (a capture or a floating action runs): the same orb moves into the lift
   * layer where it is, with the small chat open beside it. A tap there, or the chat's 展开, brings the panel back.
   */
  private liftFromCompact(): void {
    if (!this.compact || this.executing !== '' || this.liftLayer !== null) { return; }
    this.compactHint = false;
    const x: number = (this.areaWidth - AI_FLOAT_ORB) / 2 + this.dragX;
    const y: number = this.topOffset() + this.dragY;
    this.liftUp('', 'none', AiChatMemory.active ? 'chat' : 'assistant', 'compact', true, x, y);
    this.lifted = true;
  }

  private closeLift(): void {
    const content: ComponentContent<AiLiftController> | null = this.liftLayer;
    if (content === null) { return; }
    this.liftLayer = null;
    this.liftController = null;
    this.getUIContext().getPromptAction().closeCustomDialog(content).catch((): void => { /* already closed */ })
      .finally((): void => { content.dispose(); });
  }

  private stopExecutingPoll(): void {
    if (this.executingPoll >= 0) { clearInterval(this.executingPoll); this.executingPoll = -1; }
  }

  /** The panel laid out new content: morph the glass to it. */
  private onCardSize(height: number): void {
    if (height <= 0 || Math.abs(height - this.cardHeight) < 0.5) { return; }
    if (this.handoverOpen && !this.handoverFading) {
      // Still unseen: take the size at once and tell the voice card where to grow to.
      this.cardHeight = height;
      this.publishHandover();
      return;
    }
    if (this.cardHeight <= 0 || this.stage < 3) { this.cardHeight = height; return; }
    this.morph((): void => { this.cardHeight = height; });
  }

  private onFloatRequest(): void {
    if (this.sessionMode) { return; }
    if (this.floatRequest > 0 && this.stage >= 3 && !this.compact && !this.closing && this.executing === '') { this.floatChat(); }
  }

  private onAppActionRequest(): void {
    const at: number = this.appActionRequest.indexOf('@');
    if (at <= 0 || this.closing || this.sessionMode) { return; }
    const id: DiagnosticAiAppActionId | null = diagnosticAiAppActionId(this.appActionRequest.slice(0, at));
    if (id !== null) { this.runAppAction(id); }
  }

  private onBackKey(): void {
    if (!this.backKey.startsWith('island:' + this.layerId + '@') || this.closing) { return; }
    // An app action is running, or a screen is up over the page (the AI's or the user's own): the key is for it.
    if (this.executing !== '' || this.isAppActionScreenOpen()) {
      this.closeAppActionScreen();
      return;
    }
    // Floating (the orb, the lifted orb, or the AI in a session): the AI goes away — unless work is running, which
    // only the orb itself may stop.
    if (this.sessionMode || this.compact || this.lifted) {
      if (!this.working) { this.leaveFromOrb(); return; }
      // The AI layer takes the key while it floats; say why nothing else happens.
      try {
        this.getUIContext().getPromptAction().showToast({ message: 'AI 正在处理，点悬浮球可以查看或结束', duration: 2000 });
      } catch (_error) { /* no toast */ }
      return;
    }
    this.close();
  }

  /**
   * 拜拜 / 语音模式 typed in a session's small chat, or chosen by the AI (elsewhere the hidden panel acts on them).
   * Only the session AI in front answers; 助理 is not in a session, so asking for it says where it is.
   */
  private onSessionModeRequest(): void {
    if (!this.sessionMode || this.closing || !this.answersNow()) { return; }
    const mode: string = this.modeRequest.split('@')[0];
    if (mode === 'exit') { this.leaveFromOrb(); return; }
    if (mode === 'voice') { this.voiceFromOrb(); return; }
    // 回到文字 / 用文字回答: the orb stops reading and leaves its voice mode (until 语音模式 again).
    if (mode === 'text') {
      AiChatMemory.sessionTalk = 'off';
      AiReadAloud.stop();
      return;
    }
    if (mode === 'assistant') {
      try {
        this.getUIContext().getPromptAction().showToast({ message: '助理在主机列表里，回到主机列表后可以打开', duration: 2200 });
      } catch (_error) { /* no toast */ }
    }
  }

  /** Voice mode is taking over: fold away quicker, without the ring, so the droplet grows out of a plain capsule. */
  private onCloseRequest(): void {
    // The host list's voice mode never takes over from a session's AI (SessionAiHost runs its own).
    if (this.closeRequest <= 0 || this.sessionMode) { return; }
    this.handingOver = true;
    this.close();
  }

  close(): void {
    // In a session the AI is only ever the orb: it goes away as a tap on it does.
    if (this.sessionMode) { this.leaveFromOrb(); return; }
    // Never stop a running capture or analysis by folding away: float instead.
    if (this.working) { this.setCompact(true); return; }
    if (this.closing) { return; }
    this.closing = true;
    this.clearTimers();
    try { inputMethod.getController().hideTextInput(); } catch (_error) { /* keyboard already down */ }
    this.fade(140, 0, (): void => { this.contentOpacity = 0; this.contentBlur = 10; this.statusOpacity = 0; });
    this.later(this.handingOver ? 60 : 80, (): void => { this.morph((): void => { this.stage = 1; }); });
    // Handing over, the capsule leaves as the droplet (mounted at ~300 ms over it) starts to swell.
    this.later(this.handingOver ? 330 : 520, (): void => {
      this.getUIContext().animateTo({ duration: this.handingOver ? 160 : 220, curve: Curve.EaseIn },
        (): void => { this.stage = 0; });
    });
    this.later(this.handingOver ? 520 : 760, (): void => {
      // The bar comes back once the capsule is gone — unless voice mode took over (it keeps the bar hidden).
      if (!this.handingOver) { this.setStatusBarHidden(false); }
      this.onDismissed();
    });
  }

  /** Siri's margins on a phone held upright; centred and capped elsewhere, never wider than the window. */
  private panelWidth(): number { return aiPanelWidth(this.deviceClass, this.areaWidth, this.areaHeight); }

  /** The open panel never runs into the keyboard: it ends a little above it, or at its usual share of the window. */
  private panelMaxHeight(): number {
    const share: number = aiPanelHeightShare(this.deviceClass, this.areaWidth, this.areaHeight);
    const aboveKeyboard: number = this.areaHeight - this.topOffset() - this.keyboardHeight - 14;
    return Math.max(160, Math.min(this.areaHeight * share, aboveKeyboard));
  }

  private floatWidth(): number { return AI_FLOAT_ORB; }

  /**
   * The first capsule. On a phone with a cutout it must hold the whole system island, which grows wide when a live
   * activity (music, recording, navigation) is showing, so it is wider than the reference capsule.
   */
  private compactWidth(): number {
    if (this.headroom() > 0) { return Math.min(this.areaWidth - 24, AI_PHONE_ISLAND_WIDTH * this.k()); }
    return AI_COMPACT_WIDTH * this.k();
  }

  /** The status capsule: while opening (stage 2) and while an app action runs. */
  private statusShape(): boolean { return this.stage === 2 || (this.stage >= 3 && this.executing !== ''); }

  private glassWidth(): number {
    if (this.stage <= 1) { return this.compactWidth(); }
    if (this.statusShape()) { return this.panelWidth(); }
    return this.compact ? this.floatWidth() : this.panelWidth();
  }

  private glassHeight(): number {
    if (this.stage >= 3 && this.compact) { return AI_FLOAT_ORB; }
    if (this.stage <= 1) { return AI_COMPACT_HEIGHT * this.k() + this.headroom(); }
    if (this.statusShape()) { return AI_STATUS_HEIGHT * this.k() + this.headroom(); }
    return Math.min(this.cardHeight > 0 ? this.cardHeight : 180, this.panelMaxHeight());
  }

  private glassRadius(): number {
    const panel: number = aiPanelRadius(this.deviceClass, this.areaWidth, this.areaHeight);
    if (this.stage <= 1 || this.statusShape() || this.compact) { return Math.min(this.glassHeight() / 2, panel); }
    return panel;
  }

  /** The panel's first line sits below the island like the reference question (≈ y 53 on the logical canvas). */
  private panelTopPadding(): number { return this.deviceClass === 'phone' ? 34 * this.k() : 26; }

  private showPanel(): boolean { return this.stage >= 3; }

  @Builder private panel() {
    DiagnosticAiAssistantPanel({
      siriMode: true,
      forceDark: true,
      embedded: true,
      shellless: true,
      revealed: this.revealed,
      maxCardHeight: this.panelMaxHeight(),
      compact: this.contentCompact,
      cardTopPadding: this.panelTopPadding(),
      deviceClass: this.deviceClass,
      onCardSize: (_width: number, height: number): void => { this.onCardSize(height); },
      onActivityChanged: (active: boolean): void => { this.onWorkChanged(active); },
      onCaptureStateChanged: (capturing: boolean): void => { this.onCaptureChanged(capturing); },
      onClose: (): void => { this.close(); },
      onAppAction: (action: DiagnosticAiAppActionId): void => { this.runAppAction(action); },
      onFloat: (): void => { this.floatChat(); }
    }).width('100%')
  }

  /** Compact and status capsules: the same ring instance moves and grows, the task line appears beside it. */
  /** Thinking ring size and position inside the capsule; the same instance moves and grows between stages. */
  private ringSize(): number { return (this.statusShape() ? AI_RING_STATUS : AI_RING_COMPACT) * this.k(); }
  private ringX(): number {
    if (this.statusShape()) { return 28 * this.k(); }
    // The phone capsule is wider (it holds the system island), so the ring keeps a little more room from the edge.
    return (this.headroom() > 0 ? 24 : 11) * this.k();
  }
  /** On the capsule's horizontal center line, left of the island, so ring and capsule read as one shape. */
  private ringY(): number { return (this.glassHeight() - this.ringSize()) / 2; }

  /** Compact and status capsules: the thinking ring, then the status line beside it. */
  @Builder private capsuleContent() {
    Stack({ alignContent: Alignment.TopStart }) {
      // Only while a capsule can show it: under the open panel it is invisible, and a live ring there would still
      // draw every frame.
      if (this.stage < 3 || this.executing !== '' || !this.revealed) {
        // Remounted as the panel folds back (or an action starts): it was there all along, so no opening from a dot.
        AiThinkingIndicator({ indicatorSize: this.ringSize(), opensFromDot: !this.revealed })
          .position({ x: this.ringX(), y: this.ringY() })
      }
      Text(this.executing !== '' ? this.executing : this.working ? '正在处理诊断请求' : '正在准备 AI 助手')
        .fontSize(17).fontWeight(FontWeight.Medium).fontColor('#FFFFFF')
        .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        .width(Math.max(0, this.glassWidth() - (28 + AI_RING_STATUS + 38 + 20) * this.k()))
        .height(this.glassHeight())
        .position({ x: (28 + AI_RING_STATUS + 38) * this.k(), y: 0 })
        .opacity(this.statusShape() ? this.statusOpacity : 0).blur(this.statusBlur)
    }
    .width(this.glassWidth()).height(this.glassHeight())
    .opacity(this.handingOver || (this.showPanel() && this.executing === '') ? 0 : 1)
    .hitTestBehavior(HitTestMode.None)
  }

  /** 小艺: the whole window takes a faint blue → lavender wash while the panel is open (any screen ratio). */
  private washShown(): boolean {
    return aiStyleIsXiaoyi(this.aiStyle) && this.aiWash !== 'off' && !this.sessionMode && this.stage >= 3 &&
      !this.compact && !this.lifted && this.executing === '' && !this.handingOver && !this.closing &&
      // Taking over from voice mode: the voice card's own wash is still fading; this one comes with the glass.
      !this.handoverOpen && this.glassIn > 0;
  }

  build() {
    Stack({ alignContent: Alignment.Top }) {
      Column().width('100%').height('100%')
        .linearGradient({ angle: 160, colors: [[aiXiaoyiWash(this.theme === 'dark')[0], 0],
          [aiXiaoyiWash(this.theme === 'dark')[1], 1]] })
        .opacity(this.washShown() ? 1 : 0)
        .animation({ duration: 320, curve: Curve.EaseOut })
        .hitTestBehavior(HitTestMode.None)
      // The page behind stays as it is; a tap outside folds the island away (or floats it while working).
      // As a floating capsule there is no catcher at all, so the app underneath takes every touch.
      if (!this.compact && this.executing === '' && !this.lifted && !this.sessionMode) {
        Column().width('100%').height('100%').backgroundColor(Color.Transparent)
          .onClick((): void => { this.close(); })
      }
      // In a session nothing of the island shows: the AI is the lifted orb and its small chat.
      if (!this.sessionMode) {
        Stack({ alignContent: Alignment.Top }) {
          // Floating, the orb is its own sphere; the glass fades out as it shrinks into it.
          AiIslandGlass({
            glassWidth: this.glassWidth(),
            glassHeight: this.glassHeight(),
            radius: this.glassRadius(),
            capHeight: this.compact ? 0 : this.headroom(),
            capWidth: this.islandPillWidth
          }).opacity(this.compact ? 0 : this.glassIn)
          this.capsuleContent()
          // The panel content, mounted early and kept hidden until the glass has grown to it.
          if (this.panelMounted) {
            Column() { this.panel() }
              .width(this.contentCompact ? this.floatWidth() : this.panelWidth())
              .padding({ top: this.compact ? this.headroom() : 0 })
              .constraintSize({ maxHeight: this.panelMaxHeight() + 120 })
              .opacity(this.showPanel() && this.executing === '' ? this.contentOpacity : 0)
              .blur(this.contentBlur)
              .hitTestBehavior(this.showPanel() && this.executing === '' && !this.lifted ? HitTestMode.Default : HitTestMode.None)
          }
        }
        .margin({ top: this.topOffset() })
        .blur(this.islandBlur)
        // While the capsule is lifted above an opened screen, the island itself steps aside.
        .opacity(this.stage === 0 || this.lifted ? 0 : 1)
        .scale({ x: this.stage === 0 ? 0.7 : this.orbPressed ? 0.88 : 1, y: this.stage === 0 ? 0.7 : this.orbPressed ? 0.88 : 1,
          centerX: '50%', centerY: this.compact ? '50%' : 0 })
        .translate({
          x: this.compact ? this.dragX : 0,
          y: this.compact ? this.dragY : 0
        })
        // The orb: a tap opens the panel again, a double tap the small chat beside it. Alongside the content's own
        // gestures (they only act while compact); the drag below stays an ordinary gesture so scrolling wins over it.
        .onTouch((event: TouchEvent): void => {
          if (event.type === TouchType.Down) {
            this.touchStartedCompact = this.compact;
            if (this.compact) {
              this.getUIContext().animateTo({ curve: curves.springMotion(0.25, 0.8) }, (): void => { this.orbPressed = true; });
            }
          } else if ((event.type === TouchType.Up || event.type === TouchType.Cancel) && this.orbPressed) {
            this.getUIContext().animateTo({ curve: curves.springMotion(0.35, 0.6) }, (): void => { this.orbPressed = false; });
          }
        })
        .parallelGesture(GestureGroup(GestureMode.Exclusive,
          TapGesture({ count: 2 }).onAction((): void => { if (this.touchStartedCompact) { this.liftFromCompact(); } }),
          TapGesture({ count: 1 }).onAction((): void => {
            if (this.touchStartedCompact && this.compact && this.executing === '') { this.setCompact(false); }
          })))
        .gesture(PanGesture({ direction: this.compact ? PanDirection.All : PanDirection.Up, distance: this.compact ? 8 : 24 })
          .onActionStart((): void => { this.dragStartX = this.dragX; this.dragStartY = this.dragY; })
          .onActionUpdate((event: GestureEvent): void => {
            // The floating capsule follows the finger; the panel only reacts to a swipe up.
            if (this.compact) {
              const half: number = this.areaWidth / 2 - AI_FLOAT_ORB / 2 - 6;
              this.dragX = Math.max(-half, Math.min(half, this.dragStartX + event.offsetX));
              this.dragY = Math.max(0, Math.min(this.areaHeight - this.topOffset() - AI_FLOAT_ORB - 24,
                this.dragStartY + event.offsetY));
            }
          })
          .onActionEnd((event: GestureEvent): void => {
            if (!this.compact && event.offsetY < -40) { this.close(); }
          }))
        // Lifted, the orb in the layer above takes the touches; the island's own (hidden) orb must not.
        .hitTestBehavior(this.lifted ? HitTestMode.None : HitTestMode.Default)
      }
      if (this.compact && this.compactHint && !this.lifted) {
        Stack() {
          Text(AI_ORB_HINT_TEXT).fontSize(12).fontColor('#FFFFFF').maxLines(1).textAlign(TextAlign.Center).width('100%')
        }
        .width(212).height(30).borderRadius(15).backgroundColor(aiInk(this.aiStyle, 'hint')).border({ width: 0.5, color: '#33FFFFFF' })
        .position({ x: this.dragX > 0 ? (this.areaWidth - AI_FLOAT_ORB) / 2 + this.dragX - 222 :
          (this.areaWidth + AI_FLOAT_ORB) / 2 + this.dragX + 10, y: this.topOffset() + this.dragY + (AI_FLOAT_ORB - 30) / 2 })
        .hitTestBehavior(HitTestMode.None)
        .transition(TransitionEffect.OPACITY)
      }
    }
    .width('100%').height('100%')
    .hitTestBehavior(this.stage === 0 || this.lifted || this.sessionMode ? HitTestMode.None :
      this.compact || this.executing !== '' ? HitTestMode.Transparent :
      this.stage >= 3 ? HitTestMode.Default : HitTestMode.Transparent)
    .onAreaChange((_old: Area, area: Area): void => {
      const w: number = Number(area.width);
      const h: number = Number(area.height);
      if (w > 0 && h > 0 && (Math.abs(w - this.areaWidth) > 1 || Math.abs(h - this.areaHeight) > 1)) {
        const oldW: number = this.areaWidth;
        const oldH: number = this.areaHeight;
        const turned: boolean = (oldW > oldH) !== (w > h);
        this.areaWidth = w; this.areaHeight = h;
        // The floating orb stays on its side, inside the new window (rotation, split screen, a resized PC window).
        if (this.compact) {
          const xy: number[] = aiReclampOrb(this.dragX, this.dragY, oldW, oldH, w, h, this.topOffset(), AI_FLOAT_ORB);
          this.dragX = xy[0];
          this.dragY = xy[1];
        }
        if (turned) { this.placeOnCutout(); }
      }
    })
  }
}
