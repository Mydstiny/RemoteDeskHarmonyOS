import { ComponentContent, curves, display, promptAction, window } from '@kit.ArkUI';
import { inputMethod } from '@kit.IMEKit';
import { DiagnosticAiAssistantPanel } from './DiagnosticAiAssistantPanel';
import { DiagnosticAiAppActionId, diagnosticAiAppActionLabel, diagnosticAiAppActionMode } from '../../services/diagnosticAi/DiagnosticAiAppActionPolicy';
import { AiKernelRing } from './XiaoyiOrb';
import { AI_FLOAT_ORB, AiCheckmark, AiIslandGlass, AiSiriOrb } from './AiIslandChrome';

export type DiagnosticAiDeviceClass = 'phone' | 'pad' | 'pc';

/** The capsule or orb lifted into the dialog layer, above whatever screen an app action opened. */
class AiLiftParams {
  label: string = '';
  capsuleWidth: number = 300;
  deviceClass: DiagnosticAiDeviceClass = 'phone';
  /** Mini chat above the orb (the orb sits low on the screen) instead of below it. */
  chatAbove: boolean = false;
  /** Orb and chat aligned to the right edge (the orb is on the right half) instead of the left. */
  alignEnd: boolean = true;
  onTap: () => void = (): void => {};
  onDragStart: () => void = (): void => {};
  onDragMove: (dx: number, dy: number) => void = (_dx: number, _dy: number): void => {};
  onDragEnd: () => void = (): void => {};
  onChatHeight: (height: number) => void = (_height: number): void => {};
}

/** "Done" for an app action, above the screen it opened: Apple's drawn check and what was done. */
@Builder
function aiDoneCapsule(params: AiLiftParams) {
  Row({ space: 14 }) {
    Stack() { AiCheckmark({ markSize: 30 }) }.width(34).height(34)
    Text(params.label).fontSize(16).fontWeight(FontWeight.Medium).fontColor('#FFFFFF')
      .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
  }
  .width(params.capsuleWidth).height(58).padding({ left: 16, right: 20 }).borderRadius(29)
  .backgroundColor('#F5000000')
  .border({ width: { top: 0, left: 0.6, right: 0.6, bottom: 1 },
    color: { top: '#00FFFFFF', left: '#1AFFFFFF', right: '#1AFFFFFF', bottom: '#5CE6F4FF' } })
  .shadow({ radius: 24, color: '#59000000', offsetY: 8 })
}

/**
 * The floating orb above an opened screen, with a small chat growing out under it so the user can keep talking to
 * the assistant without leaving that screen. A tap on the orb itself goes back to the island (closing the screen).
 */
@Builder
function aiLiftedOrb(params: AiLiftParams) {
  // Orb first, chat second; the order reverses when the chat has to open above the orb. One chat instance either
  // way, so a half-typed question survives the orb being dragged across the screen.
  Flex({ direction: params.chatAbove ? FlexDirection.ColumnReverse : FlexDirection.Column,
    alignItems: params.alignEnd ? ItemAlign.End : ItemAlign.Start }) {
    Stack() { AiSiriOrb({ orbSize: AI_FLOAT_ORB }) }
      .width(AI_FLOAT_ORB).height(AI_FLOAT_ORB)
      .accessibilityText('AI 助手，轻点回到完整对话，按住可拖动')
      .onClick((): void => { params.onTap(); })
      .gesture(PanGesture({ distance: 6 })
        .onActionStart((): void => { params.onDragStart(); })
        .onActionUpdate((event: GestureEvent): void => { params.onDragMove(event.offsetX, event.offsetY); })
        .onActionEnd((): void => { params.onDragEnd(); }))
    DiagnosticAiAssistantPanel({ siriMode: true, forceDark: true, embedded: true, mini: true, revealed: true,
      deviceClass: params.deviceClass,
      onCardSize: (_width: number, height: number): void => { params.onChatHeight(height); } })
      .width(params.capsuleWidth)
      .margin(params.chatAbove ? { bottom: 10 } : { top: 10 })
      .transition(TransitionEffect.OPACITY.combine(TransitionEffect.scale({ x: 0.6, y: 0.6 }))
        .animation({ curve: curves.springMotion(0.5, 0.72), delay: 160 }))
  }.width(params.capsuleWidth)
}

/**
 * Island geometry, from the reference GIF measured on a 375-wide logical canvas (source pixels ÷ 2) and scaled by the
 * window width on phones. These are estimates for reproduction, not platform constants.
 */
const AI_REF_WIDTH: number = 375;
const AI_COMPACT_WIDTH: number = 226;   // F000 capsule ≈ 453 × 116 source px
const AI_COMPACT_HEIGHT: number = 58;
const AI_STATUS_HEIGHT: number = 97.5;  // F014 wide capsule ≈ 706 × 195 source px
const AI_TOP: number = 12.5;            // capsule and panels share this top anchor
const AI_SIDE: number = 12.5;           // F020 panel ≈ 700 wide on 750
const AI_PANEL_RADIUS: number = 46;     // F020 corners ≈ 100…115 source px
const AI_RING_COMPACT: number = 34;     // six-core ring, orbit radius ≈ 12.4
const AI_RING_STATUS: number = 42;      // grows with the wide capsule
const AI_PHONE_ISLAND_WIDTH: number = 296; // phone capsule: room for a system island with a live activity

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
  /** Distance from the window top to the safe area (status bar); used only where there is no island anchor. */
  @Prop topInset: number = 24;
  @Prop deviceClass: DiagnosticAiDeviceClass = 'phone';
  onDismissed: () => void = (): void => {};
  /** Floating or not: the host lets touches through its overlay node only while the island floats. */
  onFloatingChanged: (floating: boolean) => void = (_floating: boolean): void => {};
  /** Mirrors provider thinking/capture activity to the persistent entry button on the host page. */
  onActivityChanged: (active: boolean) => void = (_active: boolean): void => {};
  onCaptureStateChanged: (capturing: boolean) => void = (_capturing: boolean): void => {};
  onOpenMailDraft: (subject: string, body: string) => void = (_subject: string, _body: string): void => {};
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
  private doneDialog: ComponentContent<AiLiftParams> | null = null;
  private orbDialog: ComponentContent<AiLiftParams> | null = null;
  /** Something of the island is lifted into the dialog layer (above opened screens); the island hides meanwhile. */
  @State private lifted: boolean = false;
  /** 0 hidden · 1 compact capsule · 2 status capsule · 3 panel (or the floating capsule while working). */
  @State private stage: number = 0;
  @State private working: boolean = false;
  @State private compact: boolean = false;
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
  @State private dragX: number = 0;
  @State private dragY: number = 0;
  private dragStartX: number = 0;
  private dragStartY: number = 0;
  /** The island anchor: on a phone with a top cutout, the camera; elsewhere the top center. */
  @State private anchorTop: number = -1;
  @State private areaWidth: number = 360;
  @State private areaHeight: number = 720;
  private timers: number[] = [];
  private closing: boolean = false;
  private statusBarHidden: boolean = false;
  /** Height of the soft keyboard (vp); the open panel always ends above it. */
  @State private keyboardHeight: number = 0;
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
    this.later(16, (): void => { this.open(); });
  }

  aboutToDisappear(): void {
    this.clearTimers();
    this.stopExecutingPoll();
    this.closeLift(true);
    this.closeLift(false);
    if (this.keyboardWindow !== null) {
      try { this.keyboardWindow.off('keyboardHeightChange', this.onKeyboard); } catch (_error) { /* already off */ }
      this.keyboardWindow = null;
    }
    this.setStatusBarHidden(false);
  }

  /**
   * On a phone the open panel covers the top of the screen like Siri's; the status bar would otherwise draw its
   * time and icons on top of the black. It is hidden while the panel is open and comes back for the capsules.
   */
  private setStatusBarHidden(hidden: boolean): void {
    if (this.deviceClass !== 'phone' || hidden === this.statusBarHidden) { return; }
    this.statusBarHidden = hidden;
    const context = this.getUIContext().getHostContext();
    if (!context) { return; }
    window.getLastWindow(context).then((win: window.Window): void => {
      win.setSpecificSystemBarEnabled('status', !hidden, true).catch((): void => { /* keep the bar as it is */ });
    }).catch((): void => { /* no window */ });
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
  private k(): number { return this.deviceClass === 'phone' ? Math.min(1.15, Math.max(0.85, this.areaWidth / AI_REF_WIDTH)) : 1; }

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

  /** Find a top camera cutout so the open panel's top edge encloses it, as the Dynamic Island does. */
  private placeOnCutout(): void {
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
          this.anchorTop = Math.max(2, Math.min(AI_TOP * this.k(), top - 8));
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

  /** status → panel: the status line and ring fade and defocus while the surface keeps growing; content focuses in. */
  private revealPanel(): void {
    this.setStatusBarHidden(true);
    this.fade(180, 0, (): void => { this.statusOpacity = 0; this.statusBlur = 8; });
    this.morph((): void => { this.stage = 3; });
    this.fade(300, 90, (): void => { this.contentOpacity = 1; this.contentBlur = 0; });
    this.later(320, (): void => { this.revealed = true; });
  }

  private setCompact(value: boolean): void {
    if (value === this.compact) { return; }
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
    this.later(70, (): void => {
      if (generation !== this.compactGeneration) { return; }
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
    this.setStatusBarHidden(false);
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
    this.liftDone(label);
    this.lifted = true;
    this.later(1150, (): void => {
      this.closeLift(true);
      this.executing = '';
      this.statusOpacity = 0;
      this.setCompact(true);
      // After an action the orb and its mini chat stay in the dialog layer, above whatever the user opens or taps
      // next, until the orb itself is tapped to go back to the island.
      this.liftOrb();
      this.stopExecutingPoll();
    });
  }

  private liftOptions(alignment: DialogAlignment, dx: number, dy: number): promptAction.BaseDialogOptions {
    const options: promptAction.BaseDialogOptions = {
      isModal: false,
      autoCancel: false,
      alignment: alignment,
      offset: { dx: dx, dy: dy },
      maskColor: Color.Transparent,
      transition: TransitionEffect.OPACITY.combine(TransitionEffect.scale({ x: 0.8, y: 0.8 }))
        .animation({ curve: curves.springMotion(0.42, 0.82) })
    };
    return options;
  }

  private liftDone(label: string): void {
    if (this.doneDialog !== null) { return; }
    const params: AiLiftParams = new AiLiftParams();
    params.label = label;
    params.capsuleWidth = Math.min(this.areaWidth - 32, 340);
    const content: ComponentContent<AiLiftParams> =
      new ComponentContent(this.getUIContext(), wrapBuilder(aiDoneCapsule), params);
    this.doneDialog = content;
    this.getUIContext().getPromptAction().openCustomDialog(content,
      this.liftOptions(DialogAlignment.Top, 0, this.topInset + 6))
      .catch((): void => { this.doneDialog = null; });
  }

  /** The lifted orb's own position (left/top of the orb) and the mini chat's last measured height. */
  private liftX: number = 0;
  private liftY: number = 0;
  private liftStartX: number = 0;
  private liftStartY: number = 0;
  private liftChatHeight: number = 150;
  private liftParams: AiLiftParams | null = null;

  /** Where the dialog goes so the orb sits at liftX/liftY with the chat on the side that has room. */
  private placeLift(): void {
    const content: ComponentContent<AiLiftParams> | null = this.orbDialog;
    const params: AiLiftParams | null = this.liftParams;
    if (content === null || params === null) { return; }
    const alignEnd: boolean = this.liftX + AI_FLOAT_ORB / 2 > this.areaWidth / 2;
    const chatAbove: boolean = this.liftY + AI_FLOAT_ORB / 2 > this.areaHeight * 0.55;
    if (alignEnd !== params.alignEnd || chatAbove !== params.chatAbove) {
      params.alignEnd = alignEnd;
      params.chatAbove = chatAbove;
      content.update(params);
    }
    const width: number = params.capsuleWidth;
    const left: number = Math.max(6, Math.min(this.areaWidth - width - 6,
      alignEnd ? this.liftX + AI_FLOAT_ORB - width : this.liftX));
    const top: number = chatAbove ? this.liftY - this.liftChatHeight - 10 : this.liftY;
    this.getUIContext().getPromptAction().updateCustomDialog(content, {
      alignment: DialogAlignment.TopStart, offset: { dx: left, dy: Math.max(0, top) }
    }).catch((): void => { /* dialog already closed */ });
  }

  private liftOrb(): void {
    if (this.orbDialog !== null) { return; }
    const params: AiLiftParams = new AiLiftParams();
    params.capsuleWidth = Math.min(this.areaWidth - 28, 300);
    params.deviceClass = this.deviceClass;
    // Starts at the right edge, halfway down; dragged anywhere, it settles against the nearer side.
    this.liftX = this.areaWidth - AI_FLOAT_ORB - 14;
    this.liftY = this.areaHeight * 0.48;
    params.onDragStart = (): void => { this.liftStartX = this.liftX; this.liftStartY = this.liftY; };
    params.onDragMove = (dx: number, dy: number): void => {
      this.liftX = Math.max(6, Math.min(this.areaWidth - AI_FLOAT_ORB - 6, this.liftStartX + dx));
      this.liftY = Math.max(this.topInset, Math.min(this.areaHeight - AI_FLOAT_ORB - 24, this.liftStartY + dy));
      this.placeLift();
    };
    params.onDragEnd = (): void => {
      this.liftX = this.liftX + AI_FLOAT_ORB / 2 > this.areaWidth / 2 ? this.areaWidth - AI_FLOAT_ORB - 14 : 14;
      this.placeLift();
    };
    params.onChatHeight = (height: number): void => {
      if (height > 0 && Math.abs(height - this.liftChatHeight) > 1) {
        this.liftChatHeight = height;
        if (params.chatAbove) { this.placeLift(); }
      }
    };
    this.liftParams = params;
    params.onTap = (): void => {
      // Back to the conversation: close the screen the action opened, then open the panel.
      this.closeAppActionScreen();
      this.closeLift(false);
      this.lifted = false;
      this.stopExecutingPoll();
      this.setCompact(false);
    };
    const content: ComponentContent<AiLiftParams> =
      new ComponentContent(this.getUIContext(), wrapBuilder(aiLiftedOrb), params);
    this.orbDialog = content;
    this.getUIContext().getPromptAction().openCustomDialog(content,
      this.liftOptions(DialogAlignment.TopStart, Math.max(6, this.liftX + AI_FLOAT_ORB - params.capsuleWidth), this.liftY))
      .then((): void => { this.placeLift(); })
      .catch((): void => { this.orbDialog = null; });
  }

  /** Close the lifted "done" capsule (done) or the lifted orb. */
  private closeLift(done: boolean): void {
    const content: ComponentContent<AiLiftParams> | null = done ? this.doneDialog : this.orbDialog;
    if (content === null) { return; }
    if (done) { this.doneDialog = null; } else { this.orbDialog = null; }
    this.getUIContext().getPromptAction().closeCustomDialog(content).catch((): void => { /* already closed */ })
      .finally((): void => { content.dispose(); });
  }

  private stopExecutingPoll(): void {
    if (this.executingPoll >= 0) { clearInterval(this.executingPoll); this.executingPoll = -1; }
  }

  /** The panel laid out new content: morph the glass to it. */
  private onCardSize(height: number): void {
    if (height <= 0 || Math.abs(height - this.cardHeight) < 0.5) { return; }
    if (this.cardHeight <= 0 || this.stage < 3) { this.cardHeight = height; return; }
    this.morph((): void => { this.cardHeight = height; });
  }

  close(): void {
    // Never stop a running capture or analysis by folding away: float instead.
    if (this.working) { this.setCompact(true); return; }
    if (this.closing) { return; }
    this.closing = true;
    this.clearTimers();
    try { inputMethod.getController().hideTextInput(); } catch (_error) { /* keyboard already down */ }
    this.setStatusBarHidden(false);
    this.fade(140, 0, (): void => { this.contentOpacity = 0; this.contentBlur = 10; this.statusOpacity = 0; });
    this.later(80, (): void => { this.morph((): void => { this.stage = 1; }); });
    this.later(520, (): void => {
      this.getUIContext().animateTo({ duration: 220, curve: Curve.EaseIn }, (): void => { this.stage = 0; });
    });
    this.later(760, (): void => { this.onDismissed(); });
  }

  private panelWidth(): number {
    if (this.deviceClass === 'phone') { return this.areaWidth - AI_SIDE * 2 * this.k(); }
    if (this.deviceClass === 'pad') { return Math.min(Math.max(this.areaWidth - 48, 460), 640); }
    return Math.min(Math.max(this.areaWidth - 64, 520), 620);
  }

  /** The open panel never runs into the keyboard: it ends a little above it, or at its usual share of the window. */
  private panelMaxHeight(): number {
    const share: number = this.deviceClass === 'phone' ? 0.72 : this.deviceClass === 'pad' ? 0.76 : 0.82;
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
    const panel: number = (this.deviceClass === 'phone' ? AI_PANEL_RADIUS : 38) * this.k();
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
      compact: this.compact,
      cardTopPadding: this.panelTopPadding(),
      deviceClass: this.deviceClass,
      onCardSize: (_width: number, height: number): void => { this.onCardSize(height); },
      onActivityChanged: (active: boolean): void => { this.onWorkChanged(active); },
      onCaptureStateChanged: (capturing: boolean): void => { this.onCaptureChanged(capturing); },
      onClose: (): void => { this.close(); },
      onOpenMailDraft: (subject: string, body: string): void => { this.onOpenMailDraft(subject, body); },
      onAppAction: (action: DiagnosticAiAppActionId): void => { this.runAppAction(action); }
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
      AiKernelRing({ ringSize: this.ringSize() })
        .position({ x: this.ringX(), y: this.ringY() })
      Text(this.executing !== '' ? this.executing : this.working ? '正在处理诊断请求' : '正在准备 AI 助手')
        .fontSize(17).fontWeight(FontWeight.Medium).fontColor('#FFFFFF')
        .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        .width(Math.max(0, this.glassWidth() - (28 + AI_RING_STATUS + 38 + 20) * this.k()))
        .height(this.glassHeight())
        .position({ x: (28 + AI_RING_STATUS + 38) * this.k(), y: 0 })
        .opacity(this.statusShape() ? this.statusOpacity : 0).blur(this.statusBlur)
    }
    .width(this.glassWidth()).height(this.glassHeight())
    .opacity(this.showPanel() && this.executing === '' ? 0 : 1)
    .hitTestBehavior(HitTestMode.None)
  }

  build() {
    Stack({ alignContent: Alignment.Top }) {
      // The page behind stays as it is; a tap outside folds the island away (or floats it while working).
      // As a floating capsule there is no catcher at all, so the app underneath takes every touch.
      if (!this.compact && this.executing === '') {
        Column().width('100%').height('100%').backgroundColor(Color.Transparent)
          .onClick((): void => { this.close(); })
      }
      Stack({ alignContent: Alignment.Top }) {
        // Floating, the orb is its own sphere; the glass fades out as it shrinks into it.
        AiIslandGlass({
          glassWidth: this.glassWidth(),
          glassHeight: this.glassHeight(),
          radius: this.glassRadius()
        }).opacity(this.compact ? 0 : 1)
        this.capsuleContent()
        // The panel content, mounted early and kept hidden until the glass has grown to it.
        if (this.panelMounted) {
          Column() { this.panel() }
            .width(this.glassWidth())
            .padding({ top: this.compact ? this.headroom() : 0 })
            .constraintSize({ maxHeight: this.panelMaxHeight() + 120 })
            .opacity(this.showPanel() && this.executing === '' ? this.contentOpacity : 0)
            .blur(this.contentBlur)
            .hitTestBehavior(this.showPanel() && this.executing === '' ? HitTestMode.Default : HitTestMode.None)
        }
      }
      .margin({ top: this.topOffset() })
      .blur(this.islandBlur)
      // While the capsule is lifted above an opened screen, the island itself steps aside.
      .opacity(this.stage === 0 || this.lifted ? 0 : 1)
      .scale({ x: this.stage === 0 ? 0.7 : 1, y: this.stage === 0 ? 0.7 : 1, centerX: '50%', centerY: 0 })
      .translate({
        x: this.compact ? this.dragX : 0,
        y: this.compact ? this.dragY : 0
      })
      .onClick((): void => { if (this.compact && this.executing === '') { this.setCompact(false); } })
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
    }
    .width('100%').height('100%')
    .hitTestBehavior(this.stage === 0 ? HitTestMode.None : this.compact || this.executing !== '' ? HitTestMode.Transparent :
      this.stage >= 3 ? HitTestMode.Default : HitTestMode.Transparent)
    .onAreaChange((_old: Area, area: Area): void => {
      const w: number = Number(area.width);
      const h: number = Number(area.height);
      if (w > 0 && h > 0 && (Math.abs(w - this.areaWidth) > 1 || Math.abs(h - this.areaHeight) > 1)) {
        this.areaWidth = w; this.areaHeight = h;
      }
    })
  }
}
