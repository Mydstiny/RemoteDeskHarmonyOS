import { ComponentContent, LevelOrder, promptAction, window } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { AiIslandLayerParams, AiTopLayer } from './AiTopLayer';
import { AI_VOICE_REQUEST, AiChatMemory, aiChatOwner } from './AiChatView';
import { DiagnosticAiDeviceClass } from './AiIsland';
import { AI_APP_ACTION_REQUEST, AI_ORB_LISTEN_REQUEST, AI_ORB_SPEAKING, AI_SESSION_HANDOVER, AI_SESSION_OPEN, AI_SESSION_PANEL_REQUEST } from '../../services/diagnosticAi/AiBridgeKeys';
import { SessionAiPanelParams, sessionAiPanel } from './SessionAiPanel';
import { AiSessionRouter } from '../../services/diagnosticAi/AiSessionRouter';
import { AiReadAloud } from '../../services/diagnosticAi/AiSpeech';
import { AI_VOICE_ENABLED, AiVoiceConfig, AiVoiceSettings } from '../../services/diagnosticAi/AiVoiceSettings';
import { DiagnosticAiAppActionId, diagnosticAiAppActionId } from '../../services/diagnosticAi/DiagnosticAiAppActionPolicy';

let sessionHostCount: number = 0;

/**
 * The AI inside a remote session (RDP, RustDesk, VNC, Moonlight, SSH). The session's own button (in its side bar, or
 * SSH's 「更多」) bumps `openRequest`: it opens AI 控制面板 (语音模式, 连接中语音回答, 连续对话, 点 AI 按钮直接启动)
 * whose foot button starts the AI as set — or, with 点 AI 按钮直接启动 on, starts it at once and a long press on the
 * button (AI_SESSION_PANEL_REQUEST) opens the panel. The AI is the floating orb with its small text chat beside it,
 * above the session, keeping clear of the side bar on whichever edge it is; the button (or the panel) closes it. On that orb a
 * tap folds the chat away or brings it back, a double tap makes the orb listen (the words go into its chat), and a drag
 * (on the orb or its chat) moves it. There is no voice ball over the session: answers are read aloud by the orb as
 * 连接中语音回答 says, and voice mode (the chat's voice button, 语音模式, 用语音回答我) is the orb reading every answer
 * and listening again. While this AI is up, voice and app-action requests come here rather than to the host list that
 * may still be alive under the session (AiSessionRouter). It works for the signed-in account (its AI 配置, chats and AI
 * 语音), stays up while the connection drops or reconnects, and when the session page goes away with the AI up, the
 * host list carries it on (AI_SESSION_HANDOVER).
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
  /** A long press on the session's AI button: AI 控制面板. */
  @StorageProp(AI_SESSION_PANEL_REQUEST) @Watch('onPanelRequest') panelRequest: number = 0;
  private panel: ComponentContent<SessionAiPanelParams> | null = null;
  /** Voice mode was turned on in the panel while the AI is up: the orb listens once the panel is gone. */
  private listenAfterPanel: boolean = false;
  private startTimer: number = -1;
  private readonly hostId: string = 'session-ai-' + (++sessionHostCount).toString() + '-' + Date.now().toString(36);
  private island: AiTopLayer = new AiTopLayer();
  private topInset: number = 24;
  private win: window.Window | null = null;
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
    // Up as the page goes: the user left the host, not the AI.
    const handover: boolean = this.island.isOpen();
    if (this.win !== null) {
      try { this.win.off('windowEvent', this.onWindowEvent); } catch (_error) { /* already off */ }
      this.win = null;
    }
    this.stopTalking();
    this.closePanel();
    if (this.startTimer >= 0) { clearTimeout(this.startTimer); this.startTimer = -1; }
    this.island.close();
    AppStorage.setOrCreate<boolean>(AI_SESSION_OPEN, false);
    AiSessionRouter.release(this.hostId);
    if (handover) {
      // The conversation (and an answer still on its way) is in AiChatMemory: the host list's orb picks it up.
      hilog.info(0x0000, 'AiChat', 'session AI hands over to the host list');
      AppStorage.setOrCreate(AI_SESSION_HANDOVER, Date.now());
    }
  }

  private active(): boolean { return AiSessionRouter.current() === this.hostId; }

  private releaseIfIdle(): void {
    if (!this.island.isOpen()) { AiSessionRouter.release(this.hostId); }
  }

  /** The orb's voice mode ends and nothing is read aloud any more (the AI closed, or the session went). */
  private stopTalking(): void {
    AiChatMemory.sessionTalk = '';
    if (this.active() || AppStorage.get<boolean>(AI_ORB_SPEAKING) === true) { AiReadAloud.stop(); }
    AppStorage.setOrCreate(AI_ORB_SPEAKING, false);
  }

  private toast(message: string): void {
    try { promptAction.showToast({ message: message, duration: 2200 }); } catch (_error) { /* no toast */ }
  }

  private voiceConfig(): AiVoiceConfig {
    const settings: AiVoiceSettings = new AiVoiceSettings();
    settings.init(this.getUIContext().getHostContext() as common.UIAbilityContext, aiChatOwner());
    return settings.read();
  }

  /**
   * The side bar's AI button: AI 控制面板; with 点 AI 按钮直接启动 on, the AI starts as set there (or closes when it is
   * up) and a long press opens the panel.
   */
  private onOpenRequest(): void {
    if (this.openRequest <= 0) { return; }
    if (!this.voiceConfig().sessionQuickStart) { this.openPanel(); return; }
    if (this.island.isOpen()) {
      this.closeAi();
      return;
    }
    this.startAi();
  }

  private onPanelRequest(): void {
    if (this.panelRequest <= 0 || this.disposed || !AiSessionRouter.isInFront(this.hostId)) { return; }
    this.openPanel();
  }

  /** Start the AI as AI 控制面板 says: the orb with its chat, in voice mode if chosen (the orb then listens). */
  private startAi(): void {
    const config: AiVoiceConfig = this.voiceConfig();
    this.openOrb();
    if (!config.sessionStartVoice || !config.enabled) { return; }
    AiChatMemory.sessionTalk = 'on';
    if (this.startTimer >= 0) { clearTimeout(this.startTimer); }
    // Once the orb has settled in.
    this.startTimer = setTimeout((): void => {
      this.startTimer = -1;
      if (!this.disposed && this.island.isOpen() && AiChatMemory.sessionTalk === 'on') {
        AppStorage.setOrCreate(AI_ORB_LISTEN_REQUEST, Date.now());
      }
    }, 900);
  }

  /** AI 控制面板 over the session (one at a time). */
  private openPanel(): void {
    if (this.panel !== null || this.disposed) { return; }
    const config: AiVoiceConfig = this.voiceConfig();
    const p: SessionAiPanelParams = new SessionAiPanelParams();
    p.owner = aiChatOwner();
    p.aiOpen = this.island.isOpen();
    p.talking = p.aiOpen ? AiChatMemory.sessionTalk === 'on' : config.sessionStartVoice;
    p.onVoiceMode = (on: boolean): void => { this.setVoiceMode(on); };
    p.onStartOrClose = (): void => {
      const wasOpen: boolean = this.island.isOpen();
      this.listenAfterPanel = false;
      this.closePanel();
      if (wasOpen) { this.closeAi(); } else { this.startAi(); }
    };
    p.onClose = (): void => { this.closePanel(); };
    const content: ComponentContent<SessionAiPanelParams> =
      new ComponentContent(this.getUIContext(), wrapBuilder(sessionAiPanel), p);
    this.panel = content;
    this.listenAfterPanel = false;
    hilog.info(0x0000, 'AiChat', 'session AI panel opens');
    this.getUIContext().getPromptAction().openCustomDialog(content, {
      isModal: true,
      autoCancel: true,
      alignment: DialogAlignment.Center,
      maskColor: '#66000000',
      // Above the orb and its chat.
      levelOrder: LevelOrder.clamp(100000),
      onDidDisappear: (): void => {
        if (this.panel === content) { this.panel = null; }
        content.dispose();
        this.afterPanel();
      }
    }).catch((): void => { if (this.panel === content) { this.panel = null; } content.dispose(); });
  }

  private closePanel(): void {
    const content: ComponentContent<SessionAiPanelParams> | null = this.panel;
    if (content === null) { return; }
    this.getUIContext().getPromptAction().closeCustomDialog(content).catch((): void => { /* already closed */ });
  }

  private afterPanel(): void {
    if (!this.listenAfterPanel) { return; }
    this.listenAfterPanel = false;
    if (!this.disposed && this.island.isOpen() && AiChatMemory.sessionTalk === 'on' &&
      AiChatMemory.requestId === '' && AiReadAloud.speakingId === '') {
      AppStorage.setOrCreate(AI_ORB_LISTEN_REQUEST, Date.now());
    }
  }

  /** 语音模式 switched in the panel: while the AI is up it applies now (on: the orb listens once the panel goes). */
  private setVoiceMode(on: boolean): void {
    if (!this.island.isOpen()) { return; }
    if (on) {
      AiChatMemory.sessionTalk = 'on';
      this.listenAfterPanel = true;
      return;
    }
    this.listenAfterPanel = false;
    this.leaveVoiceMode();
  }

  /** Out of voice mode: nothing more is read, and the orb stops listening. */
  private leaveVoiceMode(): void {
    AiChatMemory.sessionTalk = '';
    AiReadAloud.stop();
    AppStorage.setOrCreate(AI_ORB_LISTEN_REQUEST, -Date.now());
  }


  /** Closed from the side bar: the orb, its chat and its voice mode go (reading aloud stops). */
  private closeAi(): void {
    if (this.startTimer >= 0) { clearTimeout(this.startTimer); this.startTimer = -1; }
    AiChatMemory.voiceResume = false;
    this.stopTalking();
    this.island.close();
    this.publishOpen();
    AiSessionRouter.release(this.hostId);
  }

  private publishOpen(): void {
    AppStorage.setOrCreate<boolean>(AI_SESSION_OPEN, this.island.isOpen());
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
    // Text first: voice mode starts when asked for, here.
    AiChatMemory.sessionTalk = '';
    const p: AiIslandLayerParams = new AiIslandLayerParams();
    p.topInset = this.topInset;
    p.deviceClass = this.deviceClass;
    p.sessionMode = true;
    p.sessionAvoidSide = this.avoidSide;
    p.sessionAvoidWidth = this.avoidWidth;
    p.answersNow = (): boolean => this.active();
    p.onDismissed = (): void => {
      // 拜拜 / the back key: the AI goes, and so does its voice.
      this.stopTalking();
      this.island.close();
      this.releaseIfIdle();
      this.publishOpen();
    };
    p.onAppAction = (action: DiagnosticAiAppActionId): void => { this.runAction(action); };
    hilog.info(0x0000, 'AiChat', 'session AI opens as the orb');
    this.island.openIsland(this.getUIContext(), p);
    this.publishOpen();
  }

  /**
   * Voice mode in a session (the small chat's voice button, 「语音模式」, or the AI's switch_mode for 用语音回答我): the
   * orb talks — it reads every answer aloud and then listens again — never a voice ball over the remote screen. An
   * answer on its way is read first; otherwise the orb listens now.
   */
  private onVoiceRequest(): void {
    if (this.voiceRequest <= 0 || !this.active() || !this.island.isOpen()) { return; }
    if (AppStorage.get<boolean>(AI_VOICE_ENABLED) !== true) {
      this.toast('AI 语音还没打开，可以在「设置 → AI 语音」里开启');
      return;
    }
    hilog.info(0x0000, 'AiChat', 'session AI talks in its orb');
    AiChatMemory.sessionTalk = 'on';
    if (AiChatMemory.requestId === '' && AiReadAloud.speakingId === '') {
      AppStorage.setOrCreate(AI_ORB_LISTEN_REQUEST, Date.now());
    }
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
