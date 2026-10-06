import { curves, window } from '@kit.ArkUI';
import { AI_ORB_LISTEN_REQUEST, AI_ORB_SPEAKING, AI_SESSION_RAIL_EXPANDED } from '../../services/diagnosticAi/AiBridgeKeys';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { DiagnosticAiAssistantPanel } from './DiagnosticAiAssistantPanel';
import { AI_FLOAT_ORB } from './AiIslandChrome';
import { AiDoneMark, AiFloatingOrb, AiIslandRingsCheck } from './AiMotionViews';
import { AiChatMemory, AiChatView, aiChatOwner } from './AiChatView';
import { AI_CHAT_REFRESH_KEY } from '../../services/diagnosticAi/AiShareInbox';
import { AI_ORB_HINT_TEXT, AI_ORB_VOICE_HINT_TEXT, AI_SESSION_ORB_HINT_TEXT, aiOrbHintWanted } from '../../services/diagnosticAi/AiOrbHintStore';
import { AI_STYLE, aiInk } from '../../services/diagnosticAi/AiStylePolicy';
import { AI_VOICE_ENABLED } from '../../services/diagnosticAi/AiVoiceSettings';
import { AI_ORB_DICTATION, aiOrbDictationEncode } from '../../services/diagnosticAi/AiBridgeKeys';
import { AiReadAloud, AiVoiceInput } from '../../services/diagnosticAi/AiSpeech';
import { XyLiveLevel } from '../../services/diagnosticAi/AiXiaoyiLight';
import { common } from '@kit.AbilityKit';

/** The island's square when 灵动岛光环 opens out of it. */
const AI_ISLAND_CARD: number = 148;
const AI_ISLAND_CARD_RADIUS: number = 46;
const AI_CAPSULE_HEIGHT: number = 58;
/** Between the orb and its mini chat. */
const AI_CHAT_GAP: number = 10;
/** The small chat at its tallest (a full answer area); a window with less room than this puts it beside the orb. */
const AI_CHAT_TALL: number = 380;
/** The small chat's own parts around its answer area (question, field, padding). */
const AI_CHAT_FRAME: number = 150;
/** Orb resting distance from the side it snaps to. */
const AI_EDGE: number = 14;
/** The one-time hint beside the orb. */
const AI_HINT_WIDTH: number = 212;
const AI_HINT_HEIGHT: number = 30;

/**
 * What AiIsland hands the layer, and how it talks to it once it is up. The layer fills in the `to…` hooks when it
 * appears; until then the opening request (`startWith`, `label`, `style`) says what to show first.
 */
export class AiLiftController {
  deviceClass: string = 'phone';
  /** The camera cutout in window coordinates (phone), or -1 without one. */
  islandTop: number = -1;
  pillWidth: number = 120;
  pillHeight: number = 36;
  /** Status bar height (vp), used when the window's avoid areas cannot be read. */
  topInset: number = 24;
  /** 'done' plays the 完成动画 first, then becomes the orb; 'orb' shows the orb right away. */
  startWith: string = 'done';
  label: string = '';
  style: string = 'check';
  /** The orb was tapped where it is (window coordinates of its top-left): back to the island from there. */
  onOrbTap: (x: number, y: number) => void = (_x: number, _y: number): void => {};
  /** Set by the layer: the done mark gives way to the orb. */
  toOrb: () => void = (): void => {};
  /** Asked before the layer is up. */
  orbRequested: boolean = false;
  /** Set by AiIsland: move the dialog to (dx, dy) from where it opened (the layer's own top-left). */
  place: (dx: number, dy: number) => void = (_dx: number, _dy: number): void => {};
  /** The window's size as AiIsland measured it (vp), until the layer reads the window itself. */
  areaWidth: number = 360;
  areaHeight: number = 780;
  /**
   * 'assistant': after an app action; 'chat': 聊天 floated by the user. Either way a tap on the orb goes back to the
   * island and a double tap shows or hides the small chat beside it.
   */
  mode: string = 'assistant';
  /** Whether a request is out (the orb shows it thinks). */
  onActivityChanged: (active: boolean) => void = (_active: boolean): void => {};
  /** Which way into the orb this is, for its one-time hint: action · chat · compact. */
  hintPath: string = 'action';
  /** Open with the small chat already shown (a double tap on the island's own orb). */
  openChat: boolean = false;
  /** Where the orb starts, in window coordinates (−1: its usual spot at the right edge). */
  startX: number = -1;
  startY: number = -1;
  /**
   * In a remote session: a tap folds the small chat away or brings it back, a double tap makes the orb listen, a press
   * only drags, and the orb keeps clear of the session's side bar (on `avoidSide`, `avoidWidth` wide while the rail is
   * expanded). The side bar's AI button closes it.
   */
  sessionMode: boolean = false;
  onExit: () => void = (): void => {};
  onVoice: () => void = (): void => {};
  avoidSide: string = '';
  avoidWidth: number = 0;
}

@Builder
export function aiLiftLayer(controller: AiLiftController) {
  AiLiftLayer({ controller: controller })
}

/**
 * Everything of the assistant that has to stay above a screen an app action opened (sheets included), in one dialog
 * layer: the 完成动画, then the floating orb with its mini chat. Being one layer, the done mark can turn into the orb
 * in place and fly to its spot, the orb follows the finger frame by frame and springs to the nearer side, and orb plus
 * chat are always fitted inside the window (status bar, gesture bar and keyboard excluded).
 *
 * A dialog takes every touch inside its own frame. So the layer's own frame is a 1 vp anchor strip at the left edge and
 * the mark, orb and chat are drawn outside it, at their window positions: children beyond an unclipped parent still
 * take touches, and the screen underneath takes every other touch. The dialog never moves, so nothing twitches.
 * Should the system's dialog wrapper clip (the orb would then be invisible and untouchable), the layer notices from
 * the orb's visible area and falls back to covering the window while things move and the orb's region at rest.
 */
@Component
struct AiLiftLayer {
  /** AI 语音 › 按住 AI 按钮说话 is on: the orb listens while held and sends when let go. */
  @StorageProp('aiVoice.holdToTalk') holdToTalk: boolean = false;
  @StorageProp(AI_VOICE_ENABLED) voiceEnabled: boolean = false;
  @StorageProp(AI_STYLE) aiStyle: string = 'siri';
  /** In a session: its side rail collapses to a thin handle, and the orb may then rest at the real edge. */
  @StorageProp(AI_SESSION_RAIL_EXPANDED) @Watch('onRailChange') railExpanded: boolean = true;
  /** In a session: its voice mode asks the orb to listen (SessionAiHost, or the chat after reading an answer). */
  @StorageProp(AI_ORB_LISTEN_REQUEST) @Watch('onListenRequest') listenRequest: number = 0;
  /** In a session: an answer is being read aloud (the orb shows itself busy). */
  @StorageProp(AI_ORB_SPEAKING) orbSpeaking: boolean = false;
  /** The chat beside the orb is waiting for an answer: the orb itself turns (its ring thinks). */
  @State private chatBusy: boolean = false;
  /**
   * The orb is listening (a long press): it hears the user itself — no voice mode — and the words go into its small
   * chat as they are recognized, sent there when the user stops (or lets go, with 按住说话).
   */
  @State private orbListening: boolean = false;
  /** Held to talk: letting go sends. */
  private listenHeld: boolean = false;
  private heardText: string = '';

  private toast(message: string): void {
    try { this.getUIContext().getPromptAction().showToast({ message: message, duration: 2200 }); } catch (_error) { /* no toast */ }
  }

  private startOrbVoice(held: boolean): void {
    if (this.phase !== 2 || this.orbListening || this.dragging) { return; }
    if (!this.voiceEnabled) { this.toast('AI 语音还没打开，可以在「设置 → AI 语音」里开启'); return; }
    // Talking over an answer being read: the reading stops, the orb listens.
    if (AiReadAloud.speakingId !== '') { AiReadAloud.stop(); }
    this.hintShown = false;
    if (!this.chatShown) { this.unread = false; this.setChatShown(true); }
    this.orbListening = true;
    this.listenHeld = held;
    this.heardText = '';
    XyLiveLevel.value = 0;
    AppStorage.setOrCreate(AI_ORB_DICTATION, aiOrbDictationEncode('listen', ''));
    this.getUIContext().animateTo({ curve: curves.springMotion(0.3, 0.6) }, (): void => { this.boxScale = 1.1; });
    hilog.info(0x0000, 'AiChat', 'orb listens held=%{public}s', String(held));
    // The signed-in account's voice settings, also when no panel has opened yet (a session's orb).
    const owner: string = aiChatOwner();
    void AiVoiceInput.start(this.getUIContext().getHostContext() as common.UIAbilityContext,
      (text: string, _final: boolean): void => {
        if (!this.orbListening) { return; }
        this.heardText = text;
        AppStorage.setOrCreate(AI_ORB_DICTATION, aiOrbDictationEncode('listen', text));
      },
      (problem: string): void => {
        const listening: boolean = this.orbListening;
        this.endListening();
        if (!listening) { return; }
        // A lone full stop for silence or noise is nothing said.
        const text: string = this.heardText.trim();
        if (text.replace(/[\s。，、！？!?,.…~～]/g, '') !== '') {
          AppStorage.setOrCreate(AI_ORB_DICTATION, aiOrbDictationEncode('done', text));
        } else {
          AppStorage.setOrCreate(AI_ORB_DICTATION, aiOrbDictationEncode('cancel', ''));
          this.toast(problem !== '' ? problem : '没有听清，请再说一次');
        }
      },
      (level: number): void => { XyLiveLevel.value = level; }, false, owner);
  }

  /** A session's voice mode: the orb listens now (its voice button, 语音模式, or its turn after an answer was read). */
  private onListenRequest(): void {
    if (this.listenRequest <= 0 || !this.controller.sessionMode || this.phase !== 2 || this.orbListening) { return; }
    this.startOrbVoice(false);
  }

  /** Done listening: send what was heard (`send`), or drop it. */
  private stopOrbVoice(send: boolean): void {
    if (!this.orbListening) { return; }
    if (send) { AiVoiceInput.stop(); return; }
    this.endListening();
    AiVoiceInput.cancel();
    AppStorage.setOrCreate(AI_ORB_DICTATION, aiOrbDictationEncode('cancel', ''));
  }

  private endListening(): void {
    this.orbListening = false;
    this.listenHeld = false;
    XyLiveLevel.value = 0;
    this.getUIContext().animateTo({ curve: curves.springMotion(0.35, 0.6) }, (): void => { this.boxScale = 1; });
  }

  controller: AiLiftController = new AiLiftController();
  /** Layer size and where it starts in the window (the dialog may begin under the status bar). */
  @State private layerW: number = 360;
  @State private layerH: number = 780;
  @State private originY: number = 0;
  @State private windowH: number = 0;
  @State private topSafe: number = 24;
  @State private bottomSafe: number = 16;
  @State private keyboard: number = 0;
  /** 1 the done mark, 2 the orb. */
  @State private phase: number = 0;
  /** The morphing box: the island's pill → its square (or the done capsule) → the orb. Layer coordinates. */
  @State private boxX: number = 0;
  @State private boxY: number = 0;
  @State private boxW: number = AI_FLOAT_ORB;
  @State private boxH: number = AI_FLOAT_ORB;
  @State private boxR: number = AI_FLOAT_ORB / 2;
  @State private boxColor: string = '#FF000000';
  @State private boxScale: number = 1;
  @State private boxOpacity: number = 1;
  @State private boxShadow: number = 0;
  @State private doneOpacity: number = 1;
  @State private ringsOn: boolean = false;
  @State private orbMounted: boolean = false;
  @State private orbOpacity: number = 0;
  @State private chatShown: boolean = false;
  @State private chatH: number = 150;
  /** 聊天: an answer landed while the small chat was hidden — a dot on the orb says so. */
  @StorageProp(AI_CHAT_REFRESH_KEY) @Watch('onChatRefresh') chatRefresh: number = 0;
  @State private unread: boolean = false;
  /** "轻点返回 · 双击打开小窗", for a moment after the orb appears. */
  @State private hintShown: boolean = false;
  @State private dragging: boolean = false;
  /** Overflow from a 1×1 anchor (normal), or the fallback: full window / the region at rest. */
  @State private anchored: boolean = true;
  private overflowSeen: boolean = false;
  /** Where the chat sits relative to the orb; changes during a drag glide (chatShift eases back to zero). */
  @State private chatBelowSide: boolean = true;
  @State private chatRightSide: boolean = true;
  @State private chatShiftX: number = 0;
  @State private chatShiftY: number = 0;
  /** Fallback at rest: the dialog covers only regionX/Y/W/H (layer coordinates) around the orb and chat. */
  @State private boxMode: boolean = false;
  @State private regionX: number = 0;
  @State private regionY: number = 0;
  @State private regionW: number = 0;
  @State private regionH: number = 0;
  private restTimer: number = -1;
  private measured: boolean = false;
  private dragStartX: number = 0;
  private dragStartY: number = 0;
  private timers: number[] = [];
  private keyboardWindow: window.Window | null = null;
  /**
   * The window turned or was resized (a session switching between landscape and portrait, a PC window): the layer
   * takes the new size and the orb settles on the same side, fitted with its chat.
   */
  private readonly onWindowSize = (size: window.Size): void => {
    const ui = this.getUIContext();
    const width: number = ui.px2vp(size.width);
    const height: number = ui.px2vp(size.height);
    if (Math.abs(width - this.layerW) < 1 && Math.abs(height - this.windowH) < 1) { return; }
    const onRight: boolean = this.orbOnRight();
    this.toFull();
    this.windowH = height;
    if (this.anchored) { this.layerW = width; this.layerH = height - this.originY; }
    if (this.phase !== 2 || this.dragging) { return; }
    this.getUIContext().animateTo({ curve: curves.springMotion(0.45, 0.86) }, (): void => {
      this.boxX = this.edgeX(onRight);
      this.boxY = this.fitY(this.boxY);
      this.syncChatSides(false);
    });
    this.restSoon(700);
  };
  private readonly onKeyboard = (height: number): void => {
    const next: number = this.getUIContext().px2vp(height);
    this.toFull();
    this.getUIContext().animateTo({ curve: curves.springMotion(0.4, 0.9) }, (): void => {
      this.keyboard = next;
      if (this.phase === 2 && !this.dragging) { this.boxY = this.fitY(this.boxY); this.syncChatSides(false); }
    });
    this.restSoon(520);
  };

  aboutToAppear(): void {
    // Floated while an answer is still coming: the orb thinks from the start.
    this.chatBusy = AiChatMemory.requestId !== '';
    this.topSafe = this.controller.topInset;
    this.layerW = this.controller.areaWidth;
    this.layerH = this.controller.areaHeight;
    this.controller.toOrb = (): void => { this.toOrb(); };
    const context = this.getUIContext().getHostContext();
    if (context) {
      window.getLastWindow(context).then((win: window.Window): void => {
        this.keyboardWindow = win;
        const ui = this.getUIContext();
        try {
          const top: number = ui.px2vp(win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM).topRect.height);
          const bottom: number = ui.px2vp(
            win.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR).bottomRect.height);
          if (top > 0) { this.topSafe = top; }
          this.bottomSafe = Math.max(8, bottom);
          const rect: window.Rect = win.getWindowProperties().windowRect;
          this.windowH = ui.px2vp(rect.height);
          if (this.anchored) {
            this.layerW = ui.px2vp(rect.width);
            this.layerH = this.windowH - this.originY;
          }
        } catch (_error) { /* keep the fallbacks */ }
        try { win.on('keyboardHeightChange', this.onKeyboard); } catch (_error) { /* no keyboard events */ }
        try { win.on('windowSizeChange', this.onWindowSize); } catch (_error) { /* no size events */ }
      }).catch((): void => { /* no window */ });
    }
  }

  aboutToDisappear(): void {
    if (this.orbListening) {
      this.orbListening = false;
      AiVoiceInput.cancel();
      XyLiveLevel.value = 0;
    }
    this.timers.forEach((id: number): void => { clearTimeout(id); });
    this.timers = [];
    if (this.restTimer !== -1) { clearTimeout(this.restTimer); this.restTimer = -1; }
    if (this.keyboardWindow !== null) {
      try { this.keyboardWindow.off('keyboardHeightChange', this.onKeyboard); } catch (_error) { /* already off */ }
      try { this.keyboardWindow.off('windowSizeChange', this.onWindowSize); } catch (_error) { /* already off */ }
      this.keyboardWindow = null;
    }
  }

  private later(ms: number, action: () => void): void { this.timers.push(setTimeout(action, ms)); }

  private chatMode(): boolean { return this.controller.mode === 'chat'; }

  private onChatRefresh(): void {
    if (!this.chatMode() || this.phase !== 2) { return; }
    this.controller.onActivityChanged(AiChatMemory.requestId !== '');
    this.chatBusy = AiChatMemory.requestId !== '';
    if (!this.chatShown && AiChatMemory.requestId === '') {
      this.getUIContext().animateTo({ curve: curves.springMotion(0.4, 0.7) }, (): void => { this.unread = true; });
    }
  }

  /** The orb is up: the first time it comes this way, say how to use it. */
  private showHint(): void {
    if (!aiOrbHintWanted(this.getUIContext().getHostContext(), this.controller.hintPath)) { return; }
    this.getUIContext().animateTo({ duration: 220, curve: Curve.EaseOut }, (): void => { this.hintShown = true; });
    this.later(3200, (): void => {
      this.getUIContext().animateTo({ duration: 260, curve: Curve.EaseIn }, (): void => { this.hintShown = false; });
      // The resting region held the hint too: shrink it back to the orb.
      this.later(300, (): void => { this.toFull(); this.restSoon(60); });
    });
  }

  /** Show or hide the small chat beside the orb (聊天); the orb moves only if the two would not fit. */
  private setChatShown(shown: boolean): void {
    if (shown === this.chatShown) { return; }
    this.toFull();
    this.getUIContext().animateTo({ curve: curves.springMotion(0.5, 0.86) }, (): void => {
      this.chatShown = shown;
      this.boxY = this.fitY(this.boxY);
      this.syncChatSides(false);
    });
    this.restSoon(700);
  }

  /** A tap: back to the island, from where the orb is (in a session: the AI goes away). */
  private orbTapped(): void {
    if (this.phase !== 2) { return; }
    // Listening: a tap means "that's all" — what was heard is sent.
    if (this.orbListening) { this.stopOrbVoice(true); return; }
    // In a session: the small chat folds away (or comes back); the orb stays. The side bar's AI button closes it.
    if (this.controller.sessionMode) {
      this.hintShown = false;
      if (!this.chatShown) { this.unread = false; }
      this.setChatShown(!this.chatShown);
      return;
    }
    this.controller.onOrbTap(this.boxX, this.boxY + this.originY);
  }

  /** A double tap: the small chat beside the orb, or away again (in a session: voice mode). */
  private orbDoubleTapped(): void {
    if (this.phase !== 2) { return; }
    if (this.orbListening) { this.stopOrbVoice(false); return; }
    // In a session: the orb itself listens (what it hears goes into its small chat), as a long press does at home.
    if (this.controller.sessionMode) { this.hintShown = false; this.startOrbVoice(this.holdToTalk); return; }
    this.hintShown = false;
    if (!this.chatShown) { this.unread = false; }
    this.setChatShown(!this.chatShown);
  }

  /** Full window: needed while anything moves (positions are window positions, so nothing visibly changes). */
  private toFull(): void {
    if (this.restTimer !== -1) { clearTimeout(this.restTimer); this.restTimer = -1; }
    if (this.anchored || !this.boxMode) { return; }
    this.controller.place(0, 0);
    this.boxMode = false;
  }

  /** Once things have settled, shrink to the orb and chat so the screen underneath works again. */
  private restSoon(ms: number): void {
    if (this.anchored) { return; }
    if (this.restTimer !== -1) { clearTimeout(this.restTimer); }
    this.restTimer = setTimeout((): void => {
      this.restTimer = -1;
      this.toBox();
    }, ms);
  }

  private toBox(): void {
    if (this.anchored || this.phase !== 2 || this.dragging) { return; }
    // The orb (with room for its pressed scale) and, when shown, the chat.
    let left: number = this.boxX - 6;
    let top: number = this.boxY - 6;
    let right: number = this.boxX + AI_FLOAT_ORB + 6;
    let bottom: number = this.boxY + AI_FLOAT_ORB + 6;
    if (this.chatShown) {
      left = Math.min(left, this.chatX());
      top = Math.min(top, this.chatY());
      right = Math.max(right, this.chatX() + this.chatWidth());
      bottom = Math.max(bottom, this.chatY() + this.chatH);
    }
    if (this.hintShown) {
      // The hint beside the orb must not be cut down to the orb's region.
      left = Math.min(left, this.hintX());
      top = Math.min(top, this.hintY());
      right = Math.max(right, this.hintX() + AI_HINT_WIDTH);
      bottom = Math.max(bottom, this.hintY() + AI_HINT_HEIGHT);
    }
    left = Math.max(0, Math.floor(left));
    top = Math.max(0, Math.floor(top));
    right = Math.min(this.layerW, Math.ceil(right));
    bottom = Math.min(this.layerH, Math.ceil(bottom));
    if (right - left <= 0 || bottom - top <= 0) { return; }
    this.regionX = left; this.regionY = top; this.regionW = right - left; this.regionH = bottom - top;
    this.controller.place(left, top);
    this.boxMode = true;
  }

  /** Children are placed in layer coordinates; at rest the layer's own origin is the region's corner. */
  private offsetX(): number { return this.boxMode ? this.regionX : 0; }
  private offsetY(): number { return this.boxMode ? this.regionY : 0; }

  /** The layer is laid out: start what AiIsland asked for, now that the window geometry is known. */
  private start(): void {
    // If the orb or the mark never shows as visible, the dialog wrapper clips what overflows the anchor.
    this.later(700, (): void => {
      if (this.anchored && !this.overflowSeen) {
        hilog.info(0x0000, 'AiLift', 'overflow is clipped: covering the window instead');
        this.anchored = false;
        this.restSoon(900);
      }
    });
    if (this.controller.startWith === 'orb') { this.showOrb(); return; }
    if (this.controller.style === 'island') { this.islandDone(); } else { this.capsuleDone(); }
    if (this.controller.orbRequested) { this.toOrb(); }
  }

  // Geometry, in layer coordinates.
  private topLimit(): number { return Math.max(0, this.topSafe + 4 - this.originY); }
  private bottomLimit(): number {
    const windowBottom: number = this.windowH > 0 ? this.windowH - this.originY : this.layerH;
    return Math.min(this.layerH, windowBottom) - Math.max(this.bottomSafe + 6, this.keyboard + 8);
  }
  private chatWidth(): number { return Math.min(this.layerW - 28, this.chatMode() ? 340 : 300); }
  private orbOnRight(): boolean { return this.boxX + AI_FLOAT_ORB / 2 > this.layerW / 2; }

  /** Room for the chat under and over the orb, as much of the chat as would fit there. */
  private fitBelow(): number {
    return Math.min(this.chatH, this.bottomLimit() - (this.boxY + AI_FLOAT_ORB + AI_CHAT_GAP));
  }
  private fitAbove(): number { return Math.min(this.chatH, this.boxY - AI_CHAT_GAP - this.topLimit()); }

  /**
   * Choose the chat's side: under the orb unless clearly more of it fits over it, on the orb's side of the screen. A
   * little hysteresis keeps it from flipping back and forth near the middle. During a drag the flip glides (the chat
   * is shifted back to where it was and eases to its new place); otherwise the caller's animation carries it.
   */
  private syncChatSides(glide: boolean): void {
    const below: number = this.fitBelow();
    const above: number = this.fitAbove();
    const wantBelow: boolean = this.chatBelowSide ? !(above > below + 16) : below > above + 16 || below >= this.chatH;
    const center: number = this.boxX + AI_FLOAT_ORB / 2;
    const wantRight: boolean = this.chatRightSide ? center > this.layerW / 2 - 24 : center > this.layerW / 2 + 24;
    if (wantBelow === this.chatBelowSide && wantRight === this.chatRightSide) { return; }
    if (!glide || !this.chatShown) {
      this.chatBelowSide = wantBelow;
      this.chatRightSide = wantRight;
      return;
    }
    const fromX: number = this.chatX();
    const fromY: number = this.chatY();
    this.chatBelowSide = wantBelow;
    this.chatRightSide = wantRight;
    this.chatShiftX += fromX - this.chatX();
    this.chatShiftY += fromY - this.chatY();
    this.getUIContext().animateTo({ curve: curves.springMotion(0.42, 0.84) }, (): void => {
      this.chatShiftX = 0;
      this.chatShiftY = 0;
    });
  }
  private hintX(): number {
    const x: number = this.orbOnRight() ? this.boxX - AI_HINT_WIDTH - 10 : this.boxX + AI_FLOAT_ORB + 10;
    return Math.max(4, Math.min(this.layerW - AI_HINT_WIDTH - 4, x));
  }
  private hintY(): number { return this.boxY + (AI_FLOAT_ORB - AI_HINT_HEIGHT) / 2; }

  private edgeX(right: boolean): number {
    // A session's side bar takes its edge: the orb rests just inside it.
    const avoid: number = this.controller.sessionMode && this.controller.avoidSide === (right ? 'right' : 'left') ?
      (this.railExpanded ? Math.max(0, this.controller.avoidWidth) : 0) : 0;
    return right ? this.layerW - AI_FLOAT_ORB - AI_EDGE - avoid : AI_EDGE + avoid;
  }

  /** The side rail opened or folded: an orb resting on that side moves to the new edge. */
  private onRailChange(): void {
    if (!this.controller.sessionMode || this.phase !== 2 || this.dragging) { return; }
    const right: boolean = this.orbOnRight();
    if (this.controller.avoidSide !== (right ? 'right' : 'left')) { return; }
    this.toFull();
    this.getUIContext().animateTo({ curve: curves.springMotion(0.42, 0.86) }, (): void => {
      this.boxX = this.edgeX(right);
      this.syncChatSides(false);
    });
    this.restSoon(600);
  }

  private hintText(): string {
    if (this.controller.sessionMode) { return AI_SESSION_ORB_HINT_TEXT; }
    return this.voiceEnabled ? AI_ORB_VOICE_HINT_TEXT : AI_ORB_HINT_TEXT;
  }
  private chatSpace(): number { return this.chatShown && !this.chatBeside() ? this.chatH + AI_CHAT_GAP : 0; }

  /**
   * A short window (a phone held sideways, or the keyboard up): the chat cannot fit over or under the orb once an
   * answer is in, so it sits beside the orb, as tall as the window allows — it never covers the orb.
   */
  private chatBeside(): boolean {
    return this.bottomLimit() - this.topLimit() - AI_FLOAT_ORB - AI_CHAT_GAP < AI_CHAT_TALL &&
      this.layerW >= this.chatWidth() + AI_FLOAT_ORB + AI_CHAT_GAP + 24;
  }

  /** How tall the chat's answer may grow: all of it over or under the orb, or the window's height beside it. */
  private answerLimit(): number {
    const room: number = this.chatBeside() ? this.bottomLimit() - this.topLimit() :
      this.bottomLimit() - this.topLimit() - AI_FLOAT_ORB - AI_CHAT_GAP;
    return Math.max(60, Math.min(240, room - AI_CHAT_FRAME));
  }

  private chatX(): number {
    const w: number = this.chatWidth();
    if (this.chatBeside()) {
      const side: number = this.orbOnRight() ? this.boxX - AI_CHAT_GAP - w : this.boxX + AI_FLOAT_ORB + AI_CHAT_GAP;
      return Math.max(8, Math.min(this.layerW - w - 8, side));
    }
    const x: number = this.chatRightSide ? this.boxX + AI_FLOAT_ORB - w : this.boxX;
    return Math.max(8, Math.min(this.layerW - w - 8, x));
  }
  private chatY(): number {
    if (this.chatBeside()) {
      const centered: number = this.boxY + (AI_FLOAT_ORB - this.chatH) / 2;
      return Math.max(this.topLimit(), Math.min(this.bottomLimit() - this.chatH, centered));
    }
    const y: number = this.chatBelowSide ? this.boxY + AI_FLOAT_ORB + AI_CHAT_GAP : this.boxY - AI_CHAT_GAP - this.chatH;
    // While dragging the orb may sit where neither side fits; the chat still never leaves the window.
    return Math.max(this.topLimit(), Math.min(this.bottomLimit() - this.chatH, y));
  }

  /** The orb's y nearest to `y` where the orb and its chat both fit (chat under or over it). */
  private fitY(y: number): number {
    const minY: number = this.topLimit();
    const maxY: number = this.bottomLimit() - AI_FLOAT_ORB;
    const orbY: number = Math.max(minY, Math.min(maxY, y));
    const chat: number = this.chatSpace();
    if (orbY + AI_FLOAT_ORB + chat <= this.bottomLimit() || orbY - chat >= minY) { return orbY; }
    const withChatBelow: number = this.bottomLimit() - AI_FLOAT_ORB - chat;
    const withChatAbove: number = minY + chat;
    const options: number[] = [withChatBelow, withChatAbove].filter((v: number): boolean => v >= minY && v <= maxY);
    if (options.length === 0) { return minY; }
    return options.reduce((best: number, v: number): number => Math.abs(v - orbY) < Math.abs(best - orbY) ? v : best);
  }

  /** 灵动岛光环: the island's own pill opens into a square, the rings tumble briefly and close into the check. */
  private islandDone(): void {
    const top: number = this.controller.islandTop >= 0 ? this.controller.islandTop - this.originY : this.topLimit() + 2;
    const pillW: number = this.controller.islandTop >= 0 ? this.controller.pillWidth : 120;
    const pillH: number = this.controller.islandTop >= 0 ? this.controller.pillHeight : 36;
    this.phase = 1;
    this.boxW = pillW; this.boxH = pillH; this.boxR = pillH / 2;
    this.boxX = (this.layerW - pillW) / 2; this.boxY = top;
    this.boxColor = '#FF000000'; this.boxOpacity = 1; this.boxScale = 1; this.doneOpacity = 1;
    this.later(30, (): void => {
      this.getUIContext().animateTo({ curve: curves.springMotion(0.42, 0.76) }, (): void => {
        this.boxW = AI_ISLAND_CARD; this.boxH = AI_ISLAND_CARD; this.boxR = AI_ISLAND_CARD_RADIUS;
        this.boxX = (this.layerW - AI_ISLAND_CARD) / 2;
        this.boxShadow = 28;
      });
    });
    this.later(150, (): void => { this.ringsOn = true; });
  }

  /** The other 完成动画 styles: a capsule under the status bar with the mark and what was done. */
  private capsuleDone(): void {
    const w: number = Math.min(this.layerW - 32, 340);
    this.phase = 1;
    this.boxW = w; this.boxH = AI_CAPSULE_HEIGHT; this.boxR = AI_CAPSULE_HEIGHT / 2;
    this.boxX = (this.layerW - w) / 2; this.boxY = this.topLimit() + 2;
    this.boxColor = '#F5000000'; this.boxScale = 0.8; this.boxOpacity = 0; this.boxShadow = 24; this.doneOpacity = 1;
    this.later(16, (): void => {
      this.getUIContext().animateTo({ curve: curves.springMotion(0.42, 0.82) }, (): void => {
        this.boxScale = 1; this.boxOpacity = 1;
      });
    });
  }

  /**
   * The done mark becomes the orb: its content fades, the box shrinks into a sphere while it travels to the orb's spot
   * on the right, the orb comes alive inside it, and then the mini chat grows out of it.
   */
  private toOrb(): void {
    if (this.phase === 0) { this.controller.orbRequested = true; return; }
    if (this.phase === 2) { return; }
    this.orbMounted = true;
    const ui = this.getUIContext();
    const x: number = this.edgeX(true);
    const y: number = this.fitY(this.layerH * 0.46);
    ui.animateTo({ duration: 140, curve: Curve.EaseIn }, (): void => { this.doneOpacity = 0; });
    ui.animateTo({ curve: curves.springMotion(0.55, 0.78), delay: 60 }, (): void => {
      this.boxX = x; this.boxY = y;
      this.boxW = AI_FLOAT_ORB; this.boxH = AI_FLOAT_ORB; this.boxR = AI_FLOAT_ORB / 2;
      this.boxScale = 1; this.boxOpacity = 1; this.boxShadow = 0;
    });
    ui.animateTo({ duration: 300, delay: 260, curve: Curve.EaseOut }, (): void => {
      this.orbOpacity = 1; this.boxColor = '#00000000';
    });
    this.later(620, (): void => {
      this.phase = 2;
      this.ringsOn = false;
      // Just the orb: a double tap brings the small chat.
      this.showHint();
      this.restSoon(700);
    });
  }

  /** Straight to the orb (完成动画 › 不显示). */
  private showOrb(): void {
    this.phase = 2;
    this.orbMounted = true;
    this.orbOpacity = 1;
    this.boxColor = '#00000000';
    this.boxW = AI_FLOAT_ORB; this.boxH = AI_FLOAT_ORB; this.boxR = AI_FLOAT_ORB / 2;
    const fromIsland: boolean = this.controller.startX >= 0 && this.controller.startY >= 0;
    this.boxX = fromIsland ? Math.max(4, Math.min(this.layerW - AI_FLOAT_ORB - 4, this.controller.startX)) : this.edgeX(true);
    // In a session: on the edge away from the side bar.
    if (this.controller.sessionMode) { this.boxX = this.edgeX(this.controller.avoidSide !== 'right'); }
    this.boxY = this.fitY(fromIsland ? this.controller.startY - this.originY : this.layerH * 0.46);
    // Taking over the island's orb where it is: no pop.
    this.boxScale = fromIsland ? 1 : 0.6; this.boxOpacity = fromIsland ? 1 : 0;
    this.later(16, (): void => {
      this.getUIContext().animateTo({ curve: curves.springMotion(0.45, 0.78) }, (): void => {
        this.boxScale = 1; this.boxOpacity = 1;
      });
    });
    this.later(fromIsland ? 16 : 200, (): void => {
      if (this.controller.openChat) {
        this.setChatShown(true);
        // A session's orb taps differently: say so the first time.
        if (this.controller.sessionMode) { this.showHint(); }
        return;
      }
      // Just the orb, out of the way: a double tap brings the small chat.
      this.showHint();
      this.restSoon(700);
    });
  }

  /**
   * Let go: the orb springs to the nearer side (where the throw was heading), and up or down just enough that the
   * orb and its chat fit, carrying the finger's speed into the spring so there is no stop-and-go.
   */
  private settle(velocityX: number, velocityY: number): void {
    const vx: number = this.getUIContext().px2vp(velocityX);
    const vy: number = this.getUIContext().px2vp(velocityY);
    const projectedX: number = this.boxX + AI_FLOAT_ORB / 2 + vx * 0.12;
    const targetX: number = this.edgeX(projectedX > this.layerW / 2);
    const targetY: number = this.fitY(this.boxY + Math.max(-160, Math.min(160, vy * 0.08)));
    const distance: number = Math.max(Math.abs(targetX - this.boxX), Math.abs(targetY - this.boxY));
    const speed: number = Math.abs(targetX - this.boxX) >= Math.abs(targetY - this.boxY) ?
      vx * Math.sign(targetX - this.boxX) : vy * Math.sign(targetY - this.boxY);
    const velocity: number = distance > 1 ? Math.max(0, Math.min(12, speed / distance)) : 0;
    this.getUIContext().animateTo({
      curve: curves.interpolatingSpring(velocity, 1, 240, 22),
      onFinish: (): void => { this.restSoon(60); }
    }, (): void => {
      this.boxX = targetX; this.boxY = targetY; this.boxScale = 1;
      this.syncChatSides(false);
    });
    // In case onFinish does not come (an interrupted animation), shrink anyway.
    this.restSoon(900);
  }

  /** A drag on the orb, or on its chat (the chat moves with it, and the session under it gets no touch). */
  private dragBegin(): void {
    // Listening, the orb stays where it is (a finger drifting while it is held is not a drag).
    if (this.phase !== 2 || this.orbListening) { return; }
    // The orb may now travel anywhere: the layer covers the window again until it settles.
    this.toFull();
    this.dragging = true;
    this.dragStartX = this.boxX; this.dragStartY = this.boxY;
    this.getUIContext().animateTo({ curve: curves.springMotion(0.3, 0.8) }, (): void => { this.boxScale = 1.08; });
  }

  private dragMove(event: GestureEvent): void {
    if (this.phase !== 2 || !this.dragging) { return; }
    // Exactly under the finger, every frame: no animation, no fitting while the finger is down.
    this.boxX = Math.max(4, Math.min(this.layerW - AI_FLOAT_ORB - 4, this.dragStartX + event.offsetX));
    this.boxY = Math.max(this.topLimit(), Math.min(this.bottomLimit() - AI_FLOAT_ORB, this.dragStartY + event.offsetY));
    this.syncChatSides(true);
  }

  private dragEnd(velocityX: number, velocityY: number): void {
    if (this.phase !== 2 || !this.dragging) { return; }
    this.dragging = false;
    this.settle(velocityX, velocityY);
  }

  /** An answer arrived (or went): the chat grows, and the orb moves only if the two no longer fit. */
  private chatResized(height: number): void {
    if (height <= 0 || Math.abs(height - this.chatH) < 1) { return; }
    this.toFull();
    this.getUIContext().animateTo({ curve: curves.springMotion(0.45, 0.86) }, (): void => {
      this.chatH = height;
      if (!this.dragging) { this.boxY = this.fitY(this.boxY); this.syncChatSides(false); }
    });
    this.restSoon(560);
  }

  @Builder private doneContent() {
    if (this.controller.style === 'island') {
      if (this.ringsOn) {
        AiIslandRingsCheck({ markSize: 88 })
      }
    } else {
      Row({ space: 14 }) {
        Stack() { AiDoneMark({ markSize: 30, style: this.controller.style }) }.width(34).height(34)
        Text(this.controller.label).fontSize(16).fontWeight(FontWeight.Medium).fontColor('#FFFFFF')
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
      }.width('100%').height('100%').padding({ left: 16, right: 20 })
    }
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      if (this.phase > 0) {
        Stack() {
          if (this.phase === 1 || this.doneOpacity > 0) {
            Stack() { this.doneContent() }
              .width('100%').height('100%').opacity(this.doneOpacity)
          }
          if (this.orbMounted) {
            AiFloatingOrb({ orbSize: AI_FLOAT_ORB, active: this.chatBusy || (this.controller.sessionMode && this.orbSpeaking),
              listening: this.orbListening }).opacity(this.orbOpacity)
          }
        }
        .width(this.boxW).height(this.boxH).borderRadius(this.boxR)
        .backgroundColor(this.boxColor)
        .clip(true)
        .shadow({ radius: this.boxShadow, color: '#59000000', offsetY: this.boxShadow > 0 ? 8 : 0 })
        .position({ x: this.boxX - this.offsetX(), y: this.boxY - this.offsetY() })
        .scale({ x: this.boxScale, y: this.boxScale })
        .opacity(this.boxOpacity)
        // Any visible part means overflow beyond the anchor is drawn (and so also touchable).
        .onVisibleAreaChange([0.0, 0.05, 0.5], (visible: boolean, ratio: number): void => {
          if (visible && ratio > 0.01) { this.overflowSeen = true; }
        }, true)
        .accessibilityText(this.phase !== 2 ? this.controller.label : this.orbListening ? 'AI 正在听，单击发送，双击取消' :
          this.controller.sessionMode && this.orbSpeaking ? 'AI 正在朗读回答，双击打断并说话' :
          this.controller.sessionMode ?
          'AI 助手，单击' + (this.chatShown ? '收起' : '展开') + '对话框，双击说话，按住可拖动；在侧栏的 AI 按钮关闭' :
          (this.chatMode() ? 'AI 聊天' : 'AI 助手') + '，单击展开主对话，双击' + (this.chatShown ? '收起' : '启动') +
          '小对话框' + (this.voiceEnabled ? '，长按语音' : '') + '，按住可拖动')
        // A finger on the orb: it gives a little at once, before a tap or a double tap is known.
        .onTouch((event: TouchEvent): void => {
          if (this.phase !== 2 || this.dragging) { return; }
          if (event.type === TouchType.Down) {
            this.getUIContext().animateTo({ curve: curves.springMotion(0.25, 0.8) }, (): void => { this.boxScale = 0.88; });
          } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
            this.getUIContext().animateTo({ curve: curves.springMotion(0.35, 0.6) }, (): void => { this.boxScale = 1; });
          }
        })
        // A double tap is told apart from a tap (the tap waits a moment); a drag wins over both.
        .gesture(GestureGroup(GestureMode.Exclusive,
          // A long press: the orb listens, right here (the words go into its small chat). With 按住说话 it listens
          // while held and sends when let go; otherwise it stops by itself when the user does (or at a tap).
          LongPressGesture({ duration: 450 })
            .onAction((): void => {
              // In a session a press only drags (a double tap makes the orb listen there).
              if (this.phase !== 2 || this.dragging || this.controller.sessionMode) { return; }
              this.startOrbVoice(this.holdToTalk);
            })
            .onActionEnd((): void => { if (this.listenHeld) { this.stopOrbVoice(true); } })
            .onActionCancel((): void => { if (this.listenHeld) { this.stopOrbVoice(true); } }),
          TapGesture({ count: 2 }).onAction((): void => { this.orbDoubleTapped(); }),
          TapGesture({ count: 1 }).onAction((): void => { this.orbTapped(); })))
        .parallelGesture(PanGesture({ distance: 4 })
          .onActionStart((): void => { this.dragBegin(); })
          .onActionUpdate((event: GestureEvent): void => { this.dragMove(event); })
          .onActionEnd((event: GestureEvent): void => { this.dragEnd(event.velocityX, event.velocityY); })
          .onActionCancel((): void => { this.dragEnd(0, 0); }))
      }
      if (this.phase === 2 && this.unread && !this.chatShown) {
        Circle().width(12).height(12).fill('#FF453A').stroke('#FFFFFF').strokeWidth(1.5)
          .position({ x: this.boxX + AI_FLOAT_ORB - 12 - this.offsetX(), y: this.boxY - this.offsetY() })
          .hitTestBehavior(HitTestMode.None)
          .transition(TransitionEffect.scale({ x: 0, y: 0 }).animation({ curve: curves.springMotion(0.4, 0.6) }))
      }
      if (this.phase === 2 && this.hintShown && !this.dragging) {
        // A box of its own size around the text, as the orb has: the layer's 1 vp anchor must not narrow the text.
        Stack() {
          Text(this.hintText()).fontSize(12).fontColor('#FFFFFF').maxLines(1).textAlign(TextAlign.Center).width('100%')
        }
        .width(AI_HINT_WIDTH).height(AI_HINT_HEIGHT).borderRadius(AI_HINT_HEIGHT / 2).backgroundColor(aiInk(this.aiStyle, 'hint'))
        .border({ width: 0.5, color: '#33FFFFFF' })
        .position({ x: this.hintX() - this.offsetX(), y: this.hintY() - this.offsetY() })
        .hitTestBehavior(HitTestMode.None)
        .transition(TransitionEffect.OPACITY)
      }
      if (this.chatShown && this.chatMode()) {
        AiChatView({ mini: true, owner: aiChatOwner(),
          deviceClass: this.controller.deviceClass, canExpand: !this.controller.sessionMode,
          sessionVoice: this.controller.sessionMode, miniAnswerLimit: this.answerLimit(),
          onCardSize: (height: number): void => { this.chatResized(height); },
          onActivityChanged: (active: boolean): void => { this.chatBusy = active; this.controller.onActivityChanged(active); },
          onExpand: (): void => { this.controller.onOrbTap(this.boxX, this.boxY + this.originY); } })
          .width(this.chatWidth())
          .position({ x: this.chatX() - this.offsetX(), y: this.chatY() - this.offsetY() })
          .translate({ x: this.chatShiftX, y: this.chatShiftY })
          // Dragging the chat moves it with the orb, and keeps the touch from the screen underneath (a remote session).
          .gesture(PanGesture({ distance: 8 })
            .onActionStart((): void => { this.dragBegin(); })
            .onActionUpdate((event: GestureEvent): void => { this.dragMove(event); })
            .onActionEnd((event: GestureEvent): void => { this.dragEnd(event.velocityX, event.velocityY); })
            .onActionCancel((): void => { this.dragEnd(0, 0); }))
          .transition(TransitionEffect.OPACITY.combine(TransitionEffect.scale({ x: 0.6, y: 0.6 }))
            .animation({ curve: curves.springMotion(0.5, 0.78) }))
      } else if (this.chatShown) {
        DiagnosticAiAssistantPanel({ siriMode: true, forceDark: true, embedded: true, mini: true, revealed: true,
          deviceClass: this.controller.deviceClass === 'pc' ? 'pc' : this.controller.deviceClass === 'pad' ? 'pad' : 'phone',
          onCardSize: (_width: number, height: number): void => { this.chatResized(height); },
          onActivityChanged: (active: boolean): void => { this.chatBusy = active; },
          onExpand: (): void => { this.controller.onOrbTap(this.boxX, this.boxY + this.originY); } })
          .width(this.chatWidth())
          .position({ x: this.chatX() - this.offsetX(), y: this.chatY() - this.offsetY() })
          .translate({ x: this.chatShiftX, y: this.chatShiftY })
          // Dragging the chat moves it with the orb, and keeps the touch from the screen underneath (a remote session).
          .gesture(PanGesture({ distance: 8 })
            .onActionStart((): void => { this.dragBegin(); })
            .onActionUpdate((event: GestureEvent): void => { this.dragMove(event); })
            .onActionEnd((event: GestureEvent): void => { this.dragEnd(event.velocityX, event.velocityY); })
            .onActionCancel((): void => { this.dragEnd(0, 0); }))
          .transition(TransitionEffect.OPACITY.combine(TransitionEffect.scale({ x: 0.6, y: 0.6 }))
            .animation({ curve: curves.springMotion(0.5, 0.78) }))
      }
    }
    // Anchored: a 1 vp wide strip down the left edge. Its full height gives the chat room to lay out its own
    // height (a child's auto size is capped by its parent); the children's widths are all explicit.
    .width(this.anchored ? 1 : this.boxMode ? this.regionW : '100%')
    .height(this.anchored ? '100%' : this.boxMode ? this.regionH : '100%')
    // Full window: under the status and gesture bars too. A region at rest stays exactly its size.
    .expandSafeArea(this.anchored || this.boxMode ? [] : [SafeAreaType.SYSTEM, SafeAreaType.KEYBOARD])
    // The layer itself never takes a touch: only the mark, the orb and the chat do.
    .hitTestBehavior(HitTestMode.None)
    .onAreaChange((_old: Area, area: Area): void => {
      const w: number = Number(area.width);
      const h: number = Number(area.height);
      if (w <= 0 || h <= 0) { return; }
      if (this.anchored) {
        // The anchor's corner is the layer's origin; the window gives its size.
        this.originY = Number(area.globalPosition.y);
        if (this.windowH > 0) { this.layerH = this.windowH - this.originY; }
        hilog.info(0x0000, 'AiLift', 'anchor at %{public}s,%{public}s layer %{public}sx%{public}s',
          Math.round(Number(area.globalPosition.x)).toString(), Math.round(this.originY).toString(),
          Math.round(this.layerW).toString(), Math.round(this.layerH).toString());
        if (!this.measured) { this.measured = true; this.start(); }
        return;
      }
      if (this.boxMode) {
        // At rest: where the dialog really put the region, to check it matches the orb's place.
        hilog.info(0x0000, 'AiLift', 'region %{public}s,%{public}s placed at %{public}s,%{public}s',
          Math.round(this.regionX).toString(), Math.round(this.regionY + this.originY).toString(),
          Math.round(Number(area.globalPosition.x)).toString(), Math.round(Number(area.globalPosition.y)).toString());
        return;
      }
      this.layerW = w; this.layerH = h;
      this.originY = Number(area.globalPosition.y);
      hilog.info(0x0000, 'AiLift', 'layer %{public}sx%{public}s at y %{public}s',
        Math.round(w).toString(), Math.round(h).toString(), Math.round(this.originY).toString());
      if (!this.measured) { this.measured = true; this.start(); }
    })
  }
}
