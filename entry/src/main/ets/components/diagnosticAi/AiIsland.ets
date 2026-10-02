import { curves } from '@kit.ArkUI';
import { inputMethod } from '@kit.IMEKit';
import { DiagnosticAiAssistantPanel } from './DiagnosticAiAssistantPanel';
import { AiKernelRing } from './XiaoyiOrb';

/** System AI gradient colors (ai_intelligent_gradient_color1–4). */
const AI_ISLAND_COLORS: Array<[ResourceColor, number]> = [
  ['#42CBF7', 0], ['#2A7DFF', 0.28], ['#A479FF', 0.55], ['#FF678C', 0.8], ['#42CBF7', 1]
];
const AI_ISLAND_MAX_WIDTH: number = 560;
export type DiagnosticAiDeviceClass = 'phone' | 'pad' | 'pc';

/**
 * 启动 AI 辅助 as an island at the top center of the window, after the iOS 27 Siri text mode: no edge glow; a dark
 * capsule with the AI light appears and opens into a translucent dark card where the question is typed directly,
 * with the keyboard up and small pill actions under the text. The result opens in the same card. Tapping outside,
 * the close button or swiping the card's top up folds it back into the capsule. The card hosts the regular
 * DiagnosticAiAssistantPanel in its Siri layout, so capture, analysis and entitlement checks are unchanged.
 */
@Component
export struct AiIsland {
  /** Distance from the window top to the island (status bar / cutout). */
  @Prop topInset: number = 24;
  @Prop deviceClass: DiagnosticAiDeviceClass = 'phone';
  onDismissed: () => void = (): void => {};
  /** Floating or not: the host lets touches through its overlay node only while the island floats. */
  onFloatingChanged: (floating: boolean) => void = (_floating: boolean): void => {};
  /** Mirrors provider thinking/capture activity to the persistent entry button on the host page. */
  onActivityChanged: (active: boolean) => void = (_active: boolean): void => {};
  onCaptureStateChanged: (capturing: boolean) => void = (_capturing: boolean): void => {};
  onOpenMailDraft: (subject: string, body: string) => void = (_subject: string, _body: string): void => {};
  /** 0 hidden · 1 compact kernel capsule · 2 task/status capsule · 3 conversation card. */
  @State private stage: number = 0;
  @State private working: boolean = false;
  /**
   * While a capture or analysis runs the island floats as a small capsule: the rest of the screen stays usable and
   * the assistant keeps running. A tap on the capsule opens the card again.
   */
  @State private compact: boolean = false;
  @State private dragX: number = 0;
  @State private dragY: number = 0;
  private dragStartX: number = 0;
  private dragStartY: number = 0;
  @State private areaWidth: number = 360;
  @State private areaHeight: number = 720;
  private timers: number[] = [];
  private closing: boolean = false;

  aboutToAppear(): void { this.later(16, (): void => { this.open(); }); }

  aboutToDisappear(): void { this.clearTimers(); }

  private later(ms: number, action: () => void): void { this.timers.push(setTimeout(action, ms)); }
  private clearTimers(): void { this.timers.forEach((id: number): void => { clearTimeout(id); }); this.timers = []; }

  private morph(stage: number): void {
    this.getUIContext().animateTo({ curve: curves.springMotion(0.52, 0.72) }, (): void => { this.stage = stage; });
  }

  private open(): void {
    this.morph(1);
    // The reference sequence holds the compact processing state before it grows into a task/status capsule,
    // then opens the confirmation/input card. Keep each state observable so users can follow what is happening.
    this.later(1000, (): void => { this.morph(2); });
    this.later(2000, (): void => { this.morph(3); });
  }

  private setCompact(value: boolean): void {
    if (value === this.compact) { return; }
    if (value) {
      try { inputMethod.getController().hideTextInput(); } catch (_error) { /* keyboard already down */ }
    } else {
      this.dragX = 0; this.dragY = 0;
    }
    this.getUIContext().animateTo({ curve: curves.springMotion(0.48, 0.8) }, (): void => { this.compact = value; });
    this.onFloatingChanged(value);
  }

  /** Work starts → float; work ends (result or error) → open the card to show it. */
  private onWorkChanged(active: boolean): void {
    this.working = active;
    this.onActivityChanged(active);
    this.setCompact(active);
  }

  close(): void {
    // Never stop a running capture or analysis by folding away: float instead.
    if (this.working) { this.setCompact(true); return; }
    if (this.closing) { return; }
    this.closing = true;
    this.clearTimers();
    try { inputMethod.getController().hideTextInput(); } catch (_error) { /* keyboard already down */ }
    this.morph(1);
    this.later(380, (): void => {
      this.getUIContext().animateTo({ duration: 200, curve: Curve.EaseIn }, (): void => { this.stage = 0; });
    });
    this.later(600, (): void => { this.onDismissed(); });
  }

  private cardWidth(): number {
    if (this.deviceClass === 'phone') { return Math.min(Math.max(this.areaWidth - 14, 300), 560); }
    if (this.deviceClass === 'pad') { return Math.min(Math.max(this.areaWidth - 48, 460), 720); }
    return Math.min(Math.max(this.areaWidth - 64, 520), 680);
  }

  private cardMaxHeight(): number {
    if (this.deviceClass === 'phone') { return this.areaHeight * 0.70; }
    if (this.deviceClass === 'pad') { return this.areaHeight * 0.76; }
    return this.areaHeight * 0.82;
  }

  /** The Siri-style text card and its floating pills; the panel draws both. Swipe up anywhere on it to fold away. */
  @Builder private card() {
    Column() {
      DiagnosticAiAssistantPanel({
        siriMode: true,
        forceDark: true,
        embedded: true,
        compact: this.compact,
        deviceClass: this.deviceClass,
        onActivityChanged: (active: boolean): void => { this.onWorkChanged(active); },
        onCaptureStateChanged: (capturing: boolean): void => { this.onCaptureStateChanged(capturing); },
        onClose: (): void => { this.close(); },
        onOpenMailDraft: (subject: string, body: string): void => { this.onOpenMailDraft(subject, body); }
      }).width('100%')
    }
    .width(this.compact ? Math.min(this.areaWidth - 32, 320) : this.cardWidth())
    .constraintSize({ maxHeight: this.cardMaxHeight() })
    .translate({ x: this.compact ? this.dragX : 0, y: this.compact ? this.dragY : 0 })
    .onClick((): void => { if (this.compact) { this.setCompact(false); } })
    .gesture(PanGesture({ direction: this.compact ? PanDirection.All : PanDirection.Up, distance: this.compact ? 8 : 24 })
      .onActionStart((): void => { this.dragStartX = this.dragX; this.dragStartY = this.dragY; })
      .onActionUpdate((event: GestureEvent): void => {
        // The floating capsule follows the finger; the card only reacts to a swipe up.
        if (this.compact) {
          this.dragX = Math.max(-this.areaWidth / 2 + 60, Math.min(this.areaWidth / 2 - 60, this.dragStartX + event.offsetX));
          this.dragY = Math.max(0, Math.min(this.areaHeight - this.topInset - 120, this.dragStartY + event.offsetY));
        }
      })
      .onActionEnd((event: GestureEvent): void => {
        if (!this.compact && event.offsetY < -40) { this.close(); }
      }))
  }

  build() {
    Stack({ alignContent: Alignment.Top }) {
      // Like Siri, the page behind stays as it is; a tap outside folds the island away (or floats it while working).
      // As a floating capsule there is no catcher at all, so the app underneath takes every touch.
      if (!this.compact) {
        Column().width('100%').height('100%').backgroundColor(Color.Transparent)
          .onClick((): void => { this.close(); })
      }
      // F000: compact six-kernel processing capsule. It stays text-free while the assistant is waking up.
      Row() { AiKernelRing({ ringSize: 24 }) }
        .width(126).height(37).borderRadius(18.5).justifyContent(FlexAlign.Center)
        .backgroundColor('#000000')
        .shadow({ radius: 16, color: '#40000000', offsetY: 6 })
        .margin({ top: this.topInset + 6 })
        .opacity(this.stage === 1 ? 1 : 0)
        .scale({ x: this.stage === 1 ? 1 : 0.6, y: this.stage === 1 ? 1 : 0.6 })
      // F010: a wider status capsule gives the user a short explanation before controls appear.
      Row({ space: 9 }) {
        AiKernelRing({ ringSize: 22 })
        Text(this.working ? '正在处理诊断请求' : '正在准备 RemoteDesktop 助手')
          .fontSize(13).fontColor('#FFFFFF').maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
      }.width(258).height(42).padding({ left: 13, right: 13 }).borderRadius(21)
        .backgroundBlurStyle(BlurStyle.COMPONENT_THICK, { colorMode: ThemeColorMode.DARK, adaptiveColor: AdaptiveColor.DEFAULT })
        .backgroundColor('#E6000000').border({ width: 0.5, color: '#33FFFFFF' })
        .shadow({ radius: 18, color: '#40000000', offsetY: 6 })
        .margin({ top: this.topInset + 6 })
        .opacity(this.stage === 2 ? 1 : 0)
        .scale({ x: this.stage === 2 ? 1 : 0.6, y: this.stage === 2 ? 1 : 0.6 })
      // F020: the card opens from the top center; its height follows its content.
      Column() { this.card() }
        .margin({ top: this.topInset + 6 })
        .opacity(this.stage >= 3 ? 1 : 0)
        .scale({ x: this.stage >= 3 ? 1 : 0.24, y: this.stage >= 3 ? 1 : 0.12, centerX: '50%', centerY: 0 })
        .hitTestBehavior(this.stage >= 3 ? HitTestMode.Default : HitTestMode.None)
    }
    .width('100%').height('100%')
    .hitTestBehavior(this.stage === 0 ? HitTestMode.None : this.compact ? HitTestMode.Transparent :
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
