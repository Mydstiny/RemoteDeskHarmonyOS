import { promptAction, window } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { AiIslandLayerParams, AiTopLayer, AiVoiceLayerParams } from './AiTopLayer';
import { AI_VOICE_REQUEST, AiChatMemory, aiChatOwner } from './AiChatView';
import { DiagnosticAiDeviceClass } from './AiIsland';
import { AI_APP_ACTION_REQUEST, AI_SESSION_HANDOVER } from '../../services/diagnosticAi/AiBridgeKeys';
import { AiSessionRouter } from '../../services/diagnosticAi/AiSessionRouter';
import { AI_VOICE_ENABLED } from '../../services/diagnosticAi/AiVoiceSettings';
import { DiagnosticAiAppActionId, diagnosticAiAppActionId } from '../../services/diagnosticAi/DiagnosticAiAppActionPolicy';

let sessionHostCount: number = 0;

/**
 * The AI inside a remote session (RDP, RustDesk, VNC, Moonlight, SSH). The session's own button (in its side bar, or
 * SSH's 「更多」) bumps `openRequest`: the AI appears as the floating orb with its small text chat beside it, above the
 * session, keeping clear of the side bar on whichever edge it is. On that orb a tap leaves the AI, a double tap starts
 * voice mode (in this window), and a drag moves it. While this AI is up, voice and app-action requests come here
 * rather than to the host list that may still be alive under the session (AiSessionRouter). It works for the signed-in
 * account (its AI 配置 and chats), stays up while the connection drops or reconnects, and when the session page goes
 * away with the AI up, the host list carries it on (AI_SESSION_HANDOVER).
 */
@Component
export struct SessionAiHost {
  /** Bumped by the session's AI button. */
  @Prop @Watch('onOpenRequest') openRequest: number = 0;
  @Prop deviceClass: DiagnosticAiDeviceClass = 'phone';
  /** Where the session's side bar is ('right' · 'left' · '' for a top bar or none) and how wide it is (vp). */
  @Prop avoidSide: string = 'right';
  @Prop avoidWidth: number = 64;
  /** The session's own toolbar actions the AI may run (session.* app actions); others answer with a note. */
  onSessionAction: (action: DiagnosticAiAppActionId) => boolean = (_action: DiagnosticAiAppActionId): boolean => false;
  @StorageProp(AI_VOICE_REQUEST) @Watch('onVoiceRequest') voiceRequest: number = 0;
  @StorageProp(AI_APP_ACTION_REQUEST) @Watch('onAppActionRequest') appActionRequest: string = '';
  private readonly hostId: string = 'session-ai-' + (++sessionHostCount).toString() + '-' + Date.now().toString(36);
  private island: AiTopLayer = new AiTopLayer();
  private voice: AiTopLayer = new AiTopLayer();
  private topInset: number = 24;
  private win: window.Window | null = null;
  private reopenTimer: number = -1;
  private disposed: boolean = false;
  /** A PC session window behind the main one leaves AI requests to the window the user is in. */
  private readonly onWindowEvent = (event: window.WindowEventType): void => {
    if (event === window.WindowEventType.WINDOW_ACTIVE || event === window.WindowEventType.WINDOW_SHOWN) {
      AiSessionRouter.setInFront(this.hostId, true);
    } else if (event === window.WindowEventType.WINDOW_INACTIVE || event === window.WindowEventType.WINDOW_HIDDEN) {
      AiSessionRouter.setInFront(this.hostId, false);
    }
  };

  aboutToAppear(): void {
    const context = this.getUIContext().getHostContext();
    if (!context) { return; }
    window.getLastWindow(context).then((win: window.Window): void => {
      if (this.disposed) { return; }
      this.win = win;
      try {
        const top: number = this.getUIContext().px2vp(win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM).topRect.height);
        if (top > 0) { this.topInset = top; }
      } catch (_error) { /* keep the default */ }
      try { win.on('windowEvent', this.onWindowEvent); } catch (_error) { /* no window events: always in front */ }
    }).catch((): void => { /* no window */ });
  }

  aboutToDisappear(): void {
    this.disposed = true;
    // Up (or between voice and the orb) as the page goes: the user left the host, not the AI.
    const handover: boolean = this.island.isOpen() || this.voice.isOpen() || this.reopenTimer >= 0;
    if (this.reopenTimer >= 0) { clearTimeout(this.reopenTimer); this.reopenTimer = -1; }
    if (this.win !== null) {
      try { this.win.off('windowEvent', this.onWindowEvent); } catch (_error) { /* already off */ }
      this.win = null;
    }
    this.island.close();
    this.voice.close();
    AiSessionRouter.release(this.hostId);
    if (handover) {
      // The conversation (and an answer still on its way) is in AiChatMemory: the host list's orb picks it up.
      hilog.info(0x0000, 'AiChat', 'session AI hands over to the host list');
      AppStorage.setOrCreate(AI_SESSION_HANDOVER, Date.now());
    }
  }

  private active(): boolean { return AiSessionRouter.current() === this.hostId; }

  private releaseIfIdle(): void {
    if (!this.island.isOpen() && !this.voice.isOpen()) { AiSessionRouter.release(this.hostId); }
  }

  private toast(message: string): void {
    try { promptAction.showToast({ message: message, duration: 2200 }); } catch (_error) { /* no toast */ }
  }

  private onOpenRequest(): void {
    if (this.openRequest <= 0) { return; }
    if (this.island.isOpen() || this.voice.isOpen()) { return; }
    this.openOrb();
  }

  /** The orb with its small text chat (text mode is the default in a session). */
  private openOrb(): void {
    if (this.disposed) { return; }
    AiSessionRouter.claim(this.hostId);
    // The user opened it here, in this window: it answers from now on.
    AiSessionRouter.setInFront(this.hostId, true);
    // The signed-in account's AI 配置 and chat, also when the host list's panel never opened in this run of the app.
    const owner: string = aiChatOwner();
    if (AiChatMemory.owner !== owner) { AiChatMemory.clear(owner); }
    AiChatMemory.active = true;
    // No orb here leads back to a voice mode the host list started.
    AiChatMemory.voiceResume = false;
    const p: AiIslandLayerParams = new AiIslandLayerParams();
    p.topInset = this.topInset;
    p.deviceClass = this.deviceClass;
    p.sessionMode = true;
    p.sessionAvoidSide = this.avoidSide;
    p.sessionAvoidWidth = this.avoidWidth;
    p.answersNow = (): boolean => this.active();
    p.onDismissed = (): void => {
      this.island.close();
      this.releaseIfIdle();
    };
    p.onAppAction = (action: DiagnosticAiAppActionId): void => { this.runAction(action); };
    hilog.info(0x0000, 'AiChat', 'session AI opens as the orb');
    this.island.openIsland(this.getUIContext(), p);
  }

  private onVoiceRequest(): void {
    if (this.voiceRequest <= 0 || !this.active() || this.voice.isOpen()) { return; }
    if (AppStorage.get<boolean>(AI_VOICE_ENABLED) !== true) {
      this.toast('AI 语音还没打开，可以在「设置 → AI 语音」里开启');
      return;
    }
    this.island.close();
    const p: AiVoiceLayerParams = new AiVoiceLayerParams();
    p.owner = aiChatOwner();
    p.topInset = this.topInset;
    p.deviceClass = this.deviceClass;
    p.mode = 'hands';
    p.startShape = 'island';
    p.keepSystemBars = true;
    p.onDismissed = (): void => {
      this.voice.close();
      this.releaseIfIdle();
    };
    // Back to text: the orb with its chat again (a session has no full panel to hand over to).
    p.onOpenChat = (): void => { this.reopenOrbAfterVoice(); };
    p.onFloat = (): void => { this.reopenOrbAfterVoice(); };
    // Voice confirmed an app screen: a session action runs here, the rest is on the host list. Either way the orb
    // comes back (no orb here leads back to voice mode, so voice's resume mark goes).
    p.onOpenScreen = (action: string): void => {
      AiChatMemory.voiceResume = false;
      const id: DiagnosticAiAppActionId | null = diagnosticAiAppActionId(action);
      if (id !== null) { this.runAction(id); } else { this.toast('这个页面在主机列表里，回到主机列表后再打开'); }
      this.reopenOrbAfterVoice();
    };
    hilog.info(0x0000, 'AiChat', 'session AI starts voice mode');
    this.voice.openVoice(this.getUIContext(), p);
  }

  private reopenOrbAfterVoice(): void {
    if (this.reopenTimer >= 0) { clearTimeout(this.reopenTimer); }
    this.reopenTimer = setTimeout((): void => {
      this.reopenTimer = -1;
      if (!this.disposed && !this.island.isOpen()) { this.openOrb(); }
    }, 360);
  }

  private onAppActionRequest(): void {
    if (!this.active()) { return; }
    const at: number = this.appActionRequest.indexOf('@');
    if (at <= 0) { return; }
    const id: DiagnosticAiAppActionId | null = diagnosticAiAppActionId(this.appActionRequest.slice(0, at));
    if (id !== null) { this.runAction(id); }
  }

  /** In a session only its own toolbar actions can run; the app's pages are on the host list. */
  private runAction(action: DiagnosticAiAppActionId): void {
    if (!this.onSessionAction(action)) { this.toast('这个页面在主机列表里，回到主机列表后再打开'); }
  }

  build() {
    // Nothing of its own on screen: the orb, the chat and voice mode live in the AI top layer.
    Column().width(0).height(0).hitTestBehavior(HitTestMode.None)
  }
}
