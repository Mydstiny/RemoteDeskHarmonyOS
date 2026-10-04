import { ComponentContent, LevelOrder, promptAction, window } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { AiIsland, DiagnosticAiDeviceClass } from './AiIsland';
import { AiVoiceIsland } from './AiVoiceIsland';
import { DiagnosticAiAppActionId } from '../../services/diagnosticAi/DiagnosticAiAppActionPolicy';

/**
 * AppStorage: the back key reached an AI layer ('<surface>:<layerId>@<time>'); the surface in that layer decides what
 * it means. The layer id keeps two AIs apart (a PC session window's and the host list's).
 */
export const AI_TOP_BACK: string = 'aiTop.back';

/** Dialog orders: voice mode above the panel (the panel opens under the voice card when it hands over). */
const AI_ORDER_ISLAND: number = 99990;
const AI_ORDER_VOICE: number = 99995;

let aiTopLayerCount: number = 0;

/** What AiIsland gets when it lives in the top layer (the same props and callbacks it takes in a page). */
export class AiIslandLayerParams {
  /** Set by AiTopLayer when it opens. */
  layerId: string = '';
  topInset: number = 24;
  deviceClass: DiagnosticAiDeviceClass = 'phone';
  quickOpen: boolean = false;
  startAction: string = '';
  startFloat: boolean = false;
  /** In a remote session: the AI starts as the orb with its small chat (see AiIsland.sessionMode). */
  sessionMode: boolean = false;
  /** In a session: the side bar's edge ('right' · 'left' · '') and width, for the orb to keep clear of. */
  sessionAvoidSide: string = '';
  sessionAvoidWidth: number = 0;
  /** Whether this AI answers requests now (a session's: while it is the one in front). */
  answersNow: () => boolean = (): boolean => true;
  onDismissed: () => void = (): void => {};
  onFloatingChanged: (floating: boolean) => void = (_floating: boolean): void => {};
  onActivityChanged: (active: boolean) => void = (_active: boolean): void => {};
  onCaptureStateChanged: (capturing: boolean) => void = (_capturing: boolean): void => {};
  onAppAction: (action: DiagnosticAiAppActionId) => void = (_action: DiagnosticAiAppActionId): void => {};
  isAppActionScreenOpen: () => boolean = (): boolean => false;
  closeAppActionScreen: () => void = (): void => {};
}

/** What AiVoiceIsland gets in the top layer. */
export class AiVoiceLayerParams {
  /** Set by AiTopLayer when it opens. */
  layerId: string = '';
  owner: string = 'device-local';
  topInset: number = 24;
  deviceClass: string = 'phone';
  mode: string = 'hands';
  startShape: string = 'island';
  resume: boolean = false;
  /** In a session: voice mode leaves the system bars as the session keeps them. */
  keepSystemBars: boolean = false;
  onDismissed: () => void = (): void => {};
  onOpenChat: () => void = (): void => {};
  onOpenScreen: (action: string) => void = (_action: string): void => {};
  onFloat: () => void = (): void => {};
}

/**
 * Lays an AI surface over the whole window from a dialog layer. The dialog's own frame is a 1 vp anchor (as the
 * floating orb's AiLiftLayer does): the surface is drawn outside it at window coordinates — compensating for where
 * the system put the anchor — so only the surface's own nodes take touches; a surface that floats (hit-test
 * transparent) lets every other touch through to the app underneath.
 */
@Component
struct AiTopLayerFrame {
  @BuilderParam content: () => void;
  @State private originX: number = 0;
  @State private originY: number = 0;
  @State private windowW: number = 360;
  @State private windowH: number = 780;
  private win: window.Window | null = null;
  private readonly onWindowSize = (size: window.Size): void => {
    this.windowW = this.getUIContext().px2vp(size.width);
    this.windowH = this.getUIContext().px2vp(size.height);
  };

  aboutToAppear(): void {
    const context = this.getUIContext().getHostContext();
    if (!context) { return; }
    window.getLastWindow(context).then((win: window.Window): void => {
      this.win = win;
      try {
        const rect: window.Rect = win.getWindowProperties().windowRect;
        this.windowW = this.getUIContext().px2vp(rect.width);
        this.windowH = this.getUIContext().px2vp(rect.height);
      } catch (_error) { /* keep the defaults until the size event */ }
      // Rotation, split screen and PC window resizes.
      try { win.on('windowSizeChange', this.onWindowSize); } catch (_error) { /* no size events */ }
    }).catch((): void => { /* no window */ });
  }

  aboutToDisappear(): void {
    if (this.win !== null) {
      try { this.win.off('windowSizeChange', this.onWindowSize); } catch (_error) { /* already off */ }
      this.win = null;
    }
  }

  build() {
    Stack() {
      Stack() { this.content() }
        .width(this.windowW).height(this.windowH)
        .position({ x: -this.originX, y: -this.originY })
        .hitTestBehavior(HitTestMode.Transparent)
    }
    .width(1).height(1)
    .hitTestBehavior(HitTestMode.Transparent)
    .onAreaChange((_old: Area, area: Area): void => {
      const x: number = Number(area.globalPosition.x);
      const y: number = Number(area.globalPosition.y);
      if (Math.abs(x - this.originX) > 0.5 || Math.abs(y - this.originY) > 0.5) {
        this.originX = x;
        this.originY = y;
        hilog.info(0x0000, 'AiChat', 'top layer anchor at %{public}s,%{public}s', Math.round(x).toString(),
          Math.round(y).toString());
      }
    })
  }
}

@Builder
function aiIslandLayer(p: AiIslandLayerParams) {
  AiTopLayerFrame() {
    AiIsland({
      layerId: p.layerId, topInset: p.topInset, deviceClass: p.deviceClass, quickOpen: p.quickOpen, startAction: p.startAction,
      startFloat: p.startFloat, sessionMode: p.sessionMode, sessionAvoidSide: p.sessionAvoidSide,
      sessionAvoidWidth: p.sessionAvoidWidth, answersNow: p.answersNow, onDismissed: p.onDismissed,
      onFloatingChanged: p.onFloatingChanged, onActivityChanged: p.onActivityChanged,
      onCaptureStateChanged: p.onCaptureStateChanged, onAppAction: p.onAppAction,
      isAppActionScreenOpen: p.isAppActionScreenOpen, closeAppActionScreen: p.closeAppActionScreen
    }).width('100%').height('100%')
  }
}

@Builder
function aiVoiceLayer(p: AiVoiceLayerParams) {
  AiTopLayerFrame() {
    AiVoiceIsland({
      layerId: p.layerId, owner: p.owner, topInset: p.topInset, deviceClass: p.deviceClass, mode: p.mode,
      startShape: p.startShape, resume: p.resume, keepSystemBars: p.keepSystemBars, onDismissed: p.onDismissed, onOpenChat: p.onOpenChat, onOpenScreen: p.onOpenScreen,
      onFloat: p.onFloat
    }).width('100%').height('100%')
  }
}

function layerOptions(order: number, surface: string, layerId: string): promptAction.BaseDialogOptions {
  return {
    isModal: false, autoCancel: false, alignment: DialogAlignment.TopStart, offset: { dx: 0, dy: 0 },
    maskColor: Color.Transparent, keyboardAvoidMode: KeyboardAvoidMode.NONE,
    levelOrder: LevelOrder.clamp(order),
    // The back key: the surface closes (or ignores it while it floats); the layer itself never just disappears.
    onWillDismiss: (_action: DismissDialogAction): void => {
      AppStorage.setOrCreate(AI_TOP_BACK, surface + ':' + layerId + '@' + Date.now().toString());
    }
  };
}

/**
 * One AI surface (the panel or voice mode) above everything the app shows — sheets and dialogs opened before it
 * included — instead of inside a page. The host keeps deciding when it is shown; it opens and closes it here.
 */
export class AiTopLayer {
  /** Closes and frees the open layer; null when none is open. */
  private closer: (() => void) | null = null;
  private readonly id: string = 'ai-layer-' + (++aiTopLayerCount).toString();

  isOpen(): boolean { return this.closer !== null; }

  openIsland(ui: UIContext, params: AiIslandLayerParams): void {
    if (this.closer !== null) { return; }
    params.layerId = this.id;
    const content: ComponentContent<AiIslandLayerParams> = new ComponentContent(ui, wrapBuilder(aiIslandLayer), params);
    const closer = (): void => {
      ui.getPromptAction().closeCustomDialog(content).catch((): void => { /* already closed */ })
        .finally((): void => { content.dispose(); });
    };
    this.closer = closer;
    ui.getPromptAction().openCustomDialog(content, layerOptions(AI_ORDER_ISLAND, 'island', this.id)).catch((error: Error): void => {
      hilog.warn(0x0000, 'AiChat', 'AI panel layer did not open: %{public}s', error.message);
      if (this.closer === closer) { this.closer = null; }
      content.dispose();
      // The host's state goes back as if the AI had closed.
      params.onDismissed();
    });
  }

  openVoice(ui: UIContext, params: AiVoiceLayerParams): void {
    if (this.closer !== null) { return; }
    params.layerId = this.id;
    const content: ComponentContent<AiVoiceLayerParams> = new ComponentContent(ui, wrapBuilder(aiVoiceLayer), params);
    const closer = (): void => {
      ui.getPromptAction().closeCustomDialog(content).catch((): void => { /* already closed */ })
        .finally((): void => { content.dispose(); });
    };
    this.closer = closer;
    ui.getPromptAction().openCustomDialog(content, layerOptions(AI_ORDER_VOICE, 'voice', this.id)).catch((error: Error): void => {
      hilog.warn(0x0000, 'AiChat', 'voice layer did not open: %{public}s', error.message);
      if (this.closer === closer) { this.closer = null; }
      content.dispose();
      params.onDismissed();
    });
  }

  close(): void {
    const closer: (() => void) | null = this.closer;
    this.closer = null;
    if (closer !== null) { closer(); }
  }
}
