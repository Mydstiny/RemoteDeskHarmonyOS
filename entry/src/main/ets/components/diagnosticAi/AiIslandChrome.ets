import { displaySync } from '@kit.ArkGraphics2D';
import { curves, uiMaterial } from '@kit.ArkUI';
import { deviceInfo } from '@kit.BasicServicesKit';
import { AI_STYLE, AiGlassColors, aiInk, aiStyleIsXiaoyi, aiXiaoyiGlass } from '../../services/diagnosticAi/AiStylePolicy';

/**
 * The AI island's glass and light, after the iOS 27 Siri island: one dark liquid-glass shape whose size the island
 * animates through every stage (capsule → status → card → floating capsule), a brighter lens rim along its lower edge,
 * and iridescent light flowing along that edge. All motion is transform/opacity on the render thread.
 */

/**
 * The island's material, after the reference: one rounded surface that is nearly black at the top (where it grows
 * out of the Dynamic Island and carries the text) and lets the page show through more and more towards the bottom,
 * with only a light blur, so what is behind stays recognizable. A fine blue-white rim runs along the lower edge
 * (sides weaker) to give the glass its thickness. As the small capsule it stays solid black.
 */
@Component
export struct AiIslandGlass {
  @Prop glassWidth: number = 226;
  @Prop glassHeight: number = 58;
  @Prop radius: number = 29;
  /** Height over a camera cutout the glass encloses (its top stays dark there in the 小艺 style). */
  @Prop capHeight: number = 0;
  /** The width of the island's pill around that camera (the 小艺 glass shades just that much). */
  @Prop capWidth: number = 0;
  @StorageProp(AI_STYLE) aiStyle: string = 'siri';
  @StorageProp('currentTheme') theme: string = 'light';

  private tall(): boolean { return this.glassHeight > 90; }
  private dense(): boolean { return this.glassHeight > 320; }

  build() {
    // One shape through every stage: its size and corners follow the island's spring. In the 小艺 style the material
    // cross-fades from the black capsule to the blue glass as it grows (and back as it shrinks or becomes the orb),
    // instead of one glass being swapped for another at its final size.
    Stack({ alignContent: Alignment.Bottom }) {
      if (aiStyleIsXiaoyi(this.aiStyle)) {
        Column().width(this.glassWidth).height(this.glassHeight)
          .linearGradient({ angle: 180, colors: [['#FF000000', 0], ['#FF000000', 0.7], ['#F0050508', 1]] })
        if (this.tall()) {
          AiXiaoyiGlass({ glassWidth: this.glassWidth, glassHeight: this.glassHeight, radius: this.radius,
            capHeight: this.capHeight, capWidth: this.capWidth, framed: false })
            .transition(TransitionEffect.OPACITY.animation({ duration: 260, curve: Curve.EaseInOut }))
        }
      } else {
        this.siriGlass()
      }
    }
    .width(this.glassWidth).height(this.glassHeight).borderRadius(this.radius).clip(true)
    .shadow(aiStyleIsXiaoyi(this.aiStyle) && this.tall() ? { radius: 26, color: '#4D2B3A86', offsetY: 8 } :
      { radius: 24, color: '#40000000', offsetY: 8 })
    .hitTestBehavior(HitTestMode.None)
  }

  @Builder private siriGlass() {
    Stack({ alignContent: Alignment.Bottom }) {
      if (this.tall()) {
        // As Siri's: one piece of smoky glass over a strong blur of the page, darkest only where it grows out of the
        // Dynamic Island (top center) and lighter everywhere else, so the page stays faintly visible through it.
        Column().width(this.glassWidth).height(this.glassHeight).backdropBlur(26)
        // A tall card is mostly reading (a long answer, a chat): the glass stays dark all the way down so text and the
        // input bar keep their contrast; a short card keeps Siri's see-through foot.
        Column().width(this.glassWidth).height(this.glassHeight)
          .linearGradient({ angle: 180, colors: this.dense() ?
            [['#E6050506', 0], ['#DB0A0A0C', 0.55], ['#CF121214', 1]] :
            [['#B3050506', 0], ['#990A0A0C', 0.55], ['#6B121214', 1]] })
        Column().width(this.glassWidth).height(this.glassHeight)
          .radialGradient({ center: ['50%', 0], radius: Math.max(this.glassWidth * 0.62, this.glassHeight * 0.7),
            colors: [['#FA000000', 0], ['#C7000000', 0.3], ['#59000000', 0.65], ['#00000000', 1]] })
      } else {
        // The small capsule is the island itself: solid black.
        Column().width(this.glassWidth).height(this.glassHeight)
          .linearGradient({ angle: 180, colors: [['#FF000000', 0], ['#FF000000', 0.7], ['#F0050508', 1]] })
      }
      // Clear glass: light gathers up the sides and along the lower edge, as through a thick lens.
      if (this.tall()) {
        Column().width(this.glassWidth).height(this.glassHeight)
          .linearGradient({ angle: 90, colors: [['#17FFFFFF', 0], ['#00FFFFFF', 0.1], ['#00FFFFFF', 0.9],
            ['#17FFFFFF', 1]] })
        // Siri's lower edge: a soft pale sheen where the glass is thickest, not a colored band.
        Column().width(this.glassWidth).height(Math.min(56, this.glassHeight * 0.26))
          .linearGradient({ angle: 180, colors: [['#00FFFFFF', 0], ['#0FFFFFFF', 0.55], ['#29F2F2F7', 1]] })
      }
      // Fine rim: pale along the bottom where the lens is thickest, faint on the sides, none on top.
      Column().width(this.glassWidth).height(this.glassHeight).borderRadius(this.radius)
        .border({ width: { top: 0, left: 0.6, right: 0.6, bottom: 1.2 },
          color: { top: '#00FFFFFF', left: '#14FFFFFF', right: '#14FFFFFF', bottom: '#59FFFFFF' } })
    }
    .width(this.glassWidth).height(this.glassHeight)
  }
}

/**
 * The 小艺 glass, after the HarmonyOS assistant's voice screen: a blue → lavender diagonal (deep navy → dark violet
 * in dark mode) with a slow light drifting through it, a fine white rim, and — only where it encloses a camera
 * cutout — a dark cap, so the camera disappears into it as in the Siri glass. The drift is transform-only (render
 * thread) and stops when motion is reduced.
 */
@Component
export struct AiXiaoyiGlass {
  @Prop glassWidth: number = 226;
  @Prop glassHeight: number = 58;
  @Prop radius: number = 29;
  @Prop capHeight: number = 0;
  /** The width of the island's pill around the camera (0: a usual pill). */
  @Prop capWidth: number = 0;
  /** Its own shadow (false inside AiIslandGlass, whose shape carries it). */
  @Prop framed: boolean = true;
  @StorageProp('currentTheme') theme: string = 'light';
  @StorageProp('diagnosticAiReducedMotion') reduced: boolean = false;
  @State private driftX: number = 0;
  @State private driftY: number = 0;

  aboutToAppear(): void {
    if (this.reduced) { return; }
    // A slow drift: a low frame rate is plenty and keeps the render pipeline free.
    setTimeout((): void => {
      this.getUIContext().animateTo({ duration: 9000, iterations: -1, playMode: PlayMode.Alternate, curve: Curve.EaseInOut,
        expectedFrameRateRange: { min: 10, max: 30, expected: 20 } }, (): void => { this.driftX = 1; });
      this.getUIContext().animateTo({ duration: 7000, iterations: -1, playMode: PlayMode.Alternate, curve: Curve.EaseInOut,
        expectedFrameRateRange: { min: 10, max: 30, expected: 20 } }, (): void => { this.driftY = 1; });
    }, 32);
  }

  private colors(): AiGlassColors { return aiXiaoyiGlass(this.theme === 'dark'); }
  private glowSize(): number { return Math.max(this.glassWidth, this.glassHeight) * 1.3; }

  /**
   * The island's glow (方案 B): centred on the camera, wider than half the panel and reaching down about two and a half
   * caps (never past three quarters of a short shape) — black at the camera, through deep navy and indigo into the
   * glass's own blue, the hue kept all the way so no grey band shows. A small near-black core keeps the camera hidden.
   */
  private pillWidth(): number { return this.capWidth > 0 ? this.capWidth : 110; }
  private glowRx(): number { return Math.max(this.glassWidth * 0.55, this.pillWidth() / 2 + 100); }
  private glowRy(): number { return Math.min(this.capHeight * 2.6, this.glassHeight * 0.75); }
  private coreRx(): number { return this.pillWidth() / 2 + 18; }
  private coreRy(): number { return this.capHeight * 0.85; }
  private cameraY(): number { return this.capHeight * 0.48; }

  /** '#AARRGGBB' between two 'RRGGBB' colours (`e` of the way), at `alpha`. */
  private mixColor(from: string, to: string, e: number, alpha: number): string {
    const channel = (at: number): string => {
      const a: number = parseInt(from.slice(at, at + 2), 16);
      const b: number = parseInt(to.slice(at, at + 2), 16);
      const v: string = Math.round(a + (b - a) * e).toString(16).toUpperCase();
      return v.length < 2 ? '0' + v : v;
    };
    const al: string = Math.round(Math.max(0, Math.min(1, alpha)) * 255).toString(16).toUpperCase();
    return '#' + (al.length < 2 ? '0' + al : al) + channel(0) + channel(2) + channel(4);
  }

  /** The glow's colours, eased (smoothstep) between its anchors: no edge anywhere in it. */
  private glowStops(): Array<[ResourceColor, number]> {
    const dark: boolean = this.theme === 'dark';
    const colors: string[] = dark ? ['020309', '05081C', '0B1238', '141D57', '1C2870', '1D2E70'] :
      ['03040D', '080D2A', '121B52', '203184', '3150B4', '4E8CE6'];
    const alphas: number[] = dark ? [1, 0.96, 0.8, 0.52, 0.24, 0] : [1, 0.95, 0.78, 0.5, 0.22, 0];
    const at: number[] = [0, 0.22, 0.42, 0.62, 0.82, 1];
    const stops: Array<[ResourceColor, number]> = [];
    for (let k = 0; k <= 24; k++) {
      const u: number = k / 24;
      let i: number = 0;
      while (i < at.length - 2 && u > at[i + 1]) { i++; }
      const t: number = Math.max(0, Math.min(1, (u - at[i]) / (at[i + 1] - at[i])));
      const e: number = t * t * (3 - 2 * t);
      stops.push([this.mixColor(colors[i], colors[i + 1], e, alphas[i] + (alphas[i + 1] - alphas[i]) * e), u]);
    }
    return stops;
  }

  /** The core round the camera: near-black over its inner half, then eased out to nothing. */
  private coreStops(): Array<[ResourceColor, number]> {
    const stops: Array<[ResourceColor, number]> = [];
    for (let i = 0; i <= 10; i++) {
      const u: number = i / 10;
      const f: number = u <= 0.55 ? 0 : (u - 0.55) / 0.45;
      stops.push([this.mixColor('020309', '020309', 0, 1 - f * f * (3 - 2 * f)), u]);
    }
    return stops;
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column().width(this.glassWidth).height(this.glassHeight)
        .linearGradient({ angle: 135, colors: [[this.colors().from, 0], [this.colors().to, 1]] })
      // The light drifting slowly through the glass.
      Column().width(this.glowSize()).height(this.glowSize())
        .radialGradient({ center: ['50%', '50%'], radius: this.glowSize() / 2,
          colors: [[this.colors().glow, 0], ['#00000000', 1]] })
        .position({ x: (this.glassWidth - this.glowSize()) / 2, y: (this.glassHeight - this.glowSize()) / 2 })
        .translate({ x: (this.driftX - 0.5) * this.glassWidth * 0.7, y: (this.driftY - 0.5) * this.glassHeight * 0.6 })
      if (this.capHeight > 0) {
        // The island's glow over the camera, and its near-black core (glowStops / coreStops).
        Column().width(this.glowRx() * 2).height(this.glowRx() * 2)
          .radialGradient({ center: ['50%', '50%'], radius: this.glowRx(), colors: this.glowStops() })
          .position({ x: this.glassWidth / 2 - this.glowRx(), y: this.cameraY() - this.glowRx() })
          .scale({ x: 1, y: this.glowRy() / this.glowRx(), centerX: '50%', centerY: '50%' })
        Column().width(this.coreRx() * 2).height(this.coreRx() * 2)
          .radialGradient({ center: ['50%', '50%'], radius: this.coreRx(), colors: this.coreStops() })
          .position({ x: this.glassWidth / 2 - this.coreRx(), y: this.cameraY() - this.coreRx() })
          .scale({ x: 1, y: this.coreRy() / this.coreRx(), centerX: '50%', centerY: '50%' })
      }
      Column().width(this.glassWidth).height(this.glassHeight).borderRadius(this.radius)
        .border({ width: 0.8, color: this.colors().rim })
    }
    .width(this.glassWidth).height(this.glassHeight).borderRadius(this.radius).clip(true)
    .shadow(this.framed ? { radius: 26, color: '#4D2B3A86', offsetY: 8 } : { radius: 0, color: Color.Transparent })
    .hitTestBehavior(HitTestMode.None)
  }
}

/** Primary action in the island: a blue-to-cyan pill with a highlight sweeping across, like Siri's Send. */
@Component
export struct AiPrimaryPill {
  @StorageProp('diagnosticAiReducedMotion') reducedMotion: boolean = false;
  @Prop label: string = '';
  onTap: () => void = (): void => {};
  @State private pillWidth: number = 0;
  @State private sweep: number = 0;

  aboutToAppear(): void {
    if (this.reducedMotion) { return; }
    setTimeout((): void => {
      this.getUIContext().animateTo({ duration: 2400, iterations: -1, curve: Curve.EaseInOut,
        expectedFrameRateRange: { min: 30, max: 60, expected: 60 } }, (): void => { this.sweep = 1; });
    }, 16);
  }

  build() {
    Stack({ alignContent: Alignment.Start }) {
      Row().width(Math.max(this.pillWidth * 0.5, 1)).height(32)
        .linearGradient({ angle: 90, colors: [['#0055FFFF', 0], ['#7342CBF7', 0.5], ['#0055FFFF', 1]] })
        .translate({ x: -this.pillWidth * 0.5 + this.sweep * this.pillWidth * 1.5 })
      Text(this.label).fontSize(13).fontWeight(FontWeight.Medium).fontColor('#FFFFFF')
        .padding({ left: 16, right: 16 }).height(32)
    }
    .height(32).borderRadius(16).clip(true)
    .linearGradient({ angle: 90, colors: [['#3B5BFF', 0], ['#2A7DFF', 0.45], ['#2FB8F5', 1]] })
    .border({ width: 0.6, color: '#40FFFFFF' })
    .shadow({ radius: 14, color: '#662A7DFF', offsetY: 4 })
    .onAreaChange((_old: Area, area: Area): void => {
      const w: number = Number(area.width);
      if (w > 0 && Math.abs(w - this.pillWidth) > 1) { this.pillWidth = w; }
    })
    .onClick((): void => { this.onTap(); })
  }
}

/**
 * The new 小艺 mark: a concave six-pointed star outline with a dot beyond each point, drawn as vectors in the
 * button's ink color (the SDK only ships the previous Celia glyph as a system symbol).
 */
@Component
export struct AiAssistantGlyph {
  @Prop glyphSize: number = 22;
  @Prop ink: string = '#3C3C43';
  private readonly settings: RenderingContextSettings = new RenderingContextSettings(true);
  private readonly ctx: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.settings);

  private draw(): void {
    const w: number = this.ctx.width;
    const h: number = this.ctx.height;
    if (w <= 0 || h <= 0) { return; }
    const cx: number = w / 2;
    const cy: number = h / 2;
    this.ctx.clearRect(0, 0, w, h);
    // As in the mark: the star's points face left and right, and the six dots (one at the top) sit in the notches
    // between the points, at about the points' own radius.
    const tip: number = w * 0.39;
    const waist: number = w * 0.1;   // concave sides pull in towards the center
    const dotRing: number = w * 0.43;
    const point = (k: number): number => (k * 60) * Math.PI / 180;
    const angle = (k: number): number => (-90 + k * 60) * Math.PI / 180;
    this.ctx.beginPath();
    for (let k: number = 0; k < 6; k++) {
      const a0: number = point(k);
      const a1: number = point(k + 1);
      const mid: number = (a0 + a1) / 2;
      if (k === 0) { this.ctx.moveTo(cx + Math.cos(a0) * tip, cy + Math.sin(a0) * tip); }
      this.ctx.quadraticCurveTo(cx + Math.cos(mid) * waist, cy + Math.sin(mid) * waist,
        cx + Math.cos(a1) * tip, cy + Math.sin(a1) * tip);
    }
    this.ctx.closePath();
    this.ctx.lineWidth = Math.max(1, w * 0.07);
    this.ctx.lineJoin = 'round';
    this.ctx.strokeStyle = this.ink;
    this.ctx.stroke();
    this.ctx.fillStyle = this.ink;
    for (let k: number = 0; k < 6; k++) {
      this.ctx.beginPath();
      this.ctx.arc(cx + Math.cos(angle(k)) * dotRing, cy + Math.sin(angle(k)) * dotRing, Math.max(0.8, w * 0.048), 0,
        Math.PI * 2);
      this.ctx.fill();
    }
  }

  build() {
    Canvas(this.ctx).width(this.glyphSize).height(this.glyphSize)
      .onReady((): void => { this.draw(); })
  }
}

/** The official HarmonyOS immersive (沉浸光感) material, available from API 26 on capable devices. */
function aiImmersiveMaterialAvailable(): boolean {
  try {
    return deviceInfo.sdkApiVersion >= 26 && uiMaterial.isImmersiveMaterialSupported();
  } catch (_error) {
    return false;
  }
}

/**
 * Round 沉浸光感 button for the assistant. On API 26 devices that support it, it is the system's own immersive
 * material (uiMaterial.ImmersiveMaterial) with its interactive deformation and light feedback, so it matches the
 * HDS bars; elsewhere a drawn lens stands in: a clear disc with a bright top rim and a soft lower glow, drawn with
 * gradients only (no blur layer, which would leave a square behind the disc).
 */
@Component
export struct AiLiquidGlassButton {
  @Prop buttonSize: number = 38;
  @Prop dark: boolean = false;
  @Prop active: boolean = false;
  @Prop reducedMotion: boolean = false;
  @State private turn: number = 0;
  private readonly official: boolean = aiImmersiveMaterialAvailable();

  aboutToAppear(): void {
    if (this.reducedMotion) { return; }
    setTimeout((): void => {
      this.getUIContext().animateTo({ duration: 6000, iterations: -1, curve: Curve.Linear,
        expectedFrameRateRange: { min: 30, max: 60, expected: 60 } }, (): void => { this.turn = 360; });
    }, 16);
  }

  @Builder private glyph() {
    AiAssistantGlyph({ glyphSize: this.buttonSize * 0.66, ink: this.dark ? '#F2F2F7' : '#2C2C30' })
      .rotate({ angle: this.active ? this.turn : 0 })
  }

  /** Lens light drawn over the material: a specular cap at the top, a soft glow gathering at the bottom, a rim. */
  @Builder private lensLight() {
    // Dark mode: a lighter, neutral lens with a soft even rim (a bright top edge reads as a black ball, not glass).
    if (this.dark) {
      Column().width(this.buttonSize).height(this.buttonSize).borderRadius(this.buttonSize / 2)
        .linearGradient({ angle: 180, colors: [['#2EFFFFFF', 0], ['#14FFFFFF', 0.55], ['#21FFFFFF', 1]] })
    } else {
      // Light mode: a white lens on a white page disappears, so the glass gets a faint cool-gray body.
      Column().width(this.buttonSize).height(this.buttonSize).borderRadius(this.buttonSize / 2)
        .linearGradient({ angle: 180, colors: [['#F2F7F8FA', 0], ['#E6E8EBF0', 0.6], ['#F0DDE1E8', 1]] })
    }
    Column().width(this.buttonSize).height(this.buttonSize).borderRadius(this.buttonSize / 2)
      .radialGradient({ center: ['50%', '92%'], radius: this.buttonSize * 0.6,
        colors: [[this.active ? '#598C7BFF' : this.dark ? '#1FFFFFFF' : '#2E42CBF7', 0], ['#00FFFFFF', 1]] })
    Column().width(this.buttonSize).height(this.buttonSize).borderRadius(this.buttonSize / 2)
      .radialGradient({ center: ['50%', '6%'], radius: this.buttonSize * 0.46,
        colors: [[this.dark ? '#29FFFFFF' : '#E6FFFFFF', 0], ['#00FFFFFF', 1]] })
    Column().width(this.buttonSize).height(this.buttonSize).borderRadius(this.buttonSize / 2)
      .border({ width: this.dark ? 0.8 : { top: 1.2, left: 0.8, right: 0.8, bottom: 1 },
        color: this.dark ? { top: '#4DFFFFFF', left: '#2EFFFFFF', right: '#2EFFFFFF', bottom: '#3DFFFFFF' } :
          { top: '#29000000', left: '#24000000', right: '#24000000', bottom: '#33000000' } })
  }

  build() {
    if (this.official) {
      // The system's immersive material does the refraction, deformation and touch light; the lens light on top
      // keeps the glass legible over a plain white page.
      Stack() {
        this.lensLight()
        this.glyph()
      }
        .width(this.buttonSize).height(this.buttonSize).borderRadius(this.buttonSize / 2)
        .systemMaterial(new uiMaterial.ImmersiveMaterial({
          style: uiMaterial.ImmersiveStyle.REGULAR,
          materialColor: this.dark ? '#1FFFFFFF' : '#40F4F6FA',
          interactive: true,
          lightEffect: { color: this.active ? '#8C7BFF' : Color.White }
        }))
    } else {
      Stack() {
        Column().width(this.buttonSize).height(this.buttonSize).borderRadius(this.buttonSize / 2)
          .linearGradient({ angle: 160, colors: this.dark ? [['#38FFFFFF', 0], ['#14FFFFFF', 1]] :
            [['#F2FFFFFF', 0], ['#D9EEF1F6', 1]] })
        // Soft lower glow, as light gathering in the bottom of the lens.
        Column().width(this.buttonSize).height(this.buttonSize).borderRadius(this.buttonSize / 2)
          .radialGradient({ center: ['50%', '92%'], radius: this.buttonSize * 0.6,
            colors: [[this.active ? '#598C7BFF' : '#3342CBF7', 0], ['#0042CBF7', 1]] })
        // Specular highlight along the top.
        Column().width(this.buttonSize).height(this.buttonSize).borderRadius(this.buttonSize / 2)
          .radialGradient({ center: ['50%', '8%'], radius: this.buttonSize * 0.42,
            colors: [[this.dark ? '#40FFFFFF' : '#CCFFFFFF', 0], ['#00FFFFFF', 1]] })
        this.glyph()
        Column().width(this.buttonSize).height(this.buttonSize).borderRadius(this.buttonSize / 2)
          .border({ width: { top: 1, left: 0.8, right: 0.8, bottom: 0.8 },
            color: this.dark ? { top: '#E6FFFFFF', left: '#66FFFFFF', right: '#66FFFFFF', bottom: '#40FFFFFF' } :
              { top: '#FFFFFFFF', left: '#1F000000', right: '#1F000000', bottom: '#29000000' } })
      }
      .width(this.buttonSize).height(this.buttonSize).borderRadius(this.buttonSize / 2)
      .shadow({ radius: this.active ? 18 : 10, color: this.active ? '#592A7DFF' : '#1F000000', offsetY: 3 })
    }
  }
}

/** Siri's caret light: warm at the top, through pink and violet, to blue at the bottom. */
const AI_CARET_GLOW: Array<[ResourceColor, number]> = [
  ['#FFB547', 0], ['#FF5E8A', 0.25], ['#A86BFF', 0.5], ['#4A8DFF', 0.75], ['#FFB547', 1]
];

/**
 * Send button in the Siri AI manner: a quiet gray disc while there is nothing to send; once there is text it turns
 * white with a dark arrow and gets a narrow, soft glow in the colors of Siri's text caret around it; the colors flow
 * round the button and the glow breathes gently. No ribbon: only diffuse light.
 */
@Component
export struct AiSendButton {
  @StorageProp('diagnosticAiReducedMotion') reducedMotion: boolean = false;
  /** AI 动效 › 发送按钮光晕: flow (turning), static, off. `glowStyle` overrides it for the settings preview. */
  @StorageProp('aiMotion.sendGlow') savedGlow: string = 'flow';
  @StorageProp(AI_STYLE) aiStyle: string = 'siri';
  @Prop glowStyle: string = '';
  @Prop @Watch('onActiveChanged') active: boolean = false;
  @Prop buttonSize: number = 34;
  onTap: () => void = (): void => {};
  @State private lit: number = 0;
  @State private breath: number = 0;
  @State private flow: number = 0;
  /** The small bounce as it lights up. */
  @State private pop: number = 1;

  aboutToAppear(): void {
    // Appearing already active (the voice button gave way to it as typing began): it still lights up, from grey.
    this.lit = this.active && this.reducedMotion ? 1 : 0;
    if (this.active && !this.reducedMotion) { setTimeout((): void => { this.light(); }, 16); }
    const style: string = this.glow_();
    if (this.reducedMotion || style === 'static' || style === 'off') { return; }
    setTimeout((): void => {
      // 呼吸 breathes deeper; 流动 and 彗星 breathe lightly while they turn (彗星 faster, a light running round).
      this.getUIContext().animateTo({ duration: style === 'breath' ? 1400 : 1800, iterations: -1,
        playMode: PlayMode.Alternate, curve: Curve.EaseInOut,
        expectedFrameRateRange: { min: 30, max: 60, expected: 60 } }, (): void => { this.breath = 1; });
      if (style !== 'breath') {
        this.getUIContext().animateTo({ duration: style === 'comet' ? 1500 : 3200, iterations: -1, curve: Curve.Linear,
          expectedFrameRateRange: { min: 30, max: 60, expected: 60 } }, (): void => { this.flow = 360; });
      }
    }, 16);
  }

  private onActiveChanged(): void {
    if (this.reducedMotion) { this.lit = this.active ? 1 : 0; return; }
    if (this.active) { this.light(); return; }
    this.getUIContext().animateTo({ curve: curves.springMotion(0.38, 0.9) }, (): void => { this.lit = 0; this.pop = 1; });
  }

  /** Lights up: white fills the disc from its middle, the arrow turns black, and the button gives a small bounce. */
  private light(): void {
    if (!this.active) { return; }
    this.pop = 0.84;
    this.getUIContext().animateTo({ curve: curves.springMotion(0.34, 0.6) }, (): void => { this.lit = 1; this.pop = 1; });
  }

  private glow_(): string {
    if (this.glowStyle !== '') { return this.glowStyle; }
    return this.reducedMotion ? 'off' : this.savedGlow;
  }

  private glow(): number { return this.buttonSize + 12; }
  private readonly ringSettings: RenderingContextSettings = new RenderingContextSettings(true);
  private readonly ring: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.ringSettings);

  /**
   * A narrow ring of Siri's caret colors drawn with its own soft glow on a canvas: no blur layer, so nothing square
   * shows behind the button on a dark panel.
   */
  private paintRing(): void {
    const w: number = this.ring.width;
    const h: number = this.ring.height;
    if (w <= 0 || h <= 0) { return; }
    this.ring.clearRect(0, 0, w, h);
    if (this.glow_() === 'comet') {
      // A faint ring with one bright head and a tail fading behind it; the canvas turns, so it runs round.
      this.ring.strokeStyle = 'rgba(168,107,255,0.28)';
      this.ring.lineWidth = 1.2;
      this.ring.beginPath(); this.ring.arc(w / 2, h / 2, this.buttonSize / 2 + 2, 0, Math.PI * 2); this.ring.stroke();
      const tail: CanvasGradient = this.ring.createConicGradient(0, w / 2, h / 2);
      tail.addColorStop(0, 'rgba(255,255,255,0)');
      tail.addColorStop(0.18, 'rgba(74,141,255,0.6)');
      tail.addColorStop(0.3, 'rgba(255,94,138,1)');
      tail.addColorStop(0.31, 'rgba(255,94,138,0)');
      tail.addColorStop(1, 'rgba(255,255,255,0)');
      this.ring.strokeStyle = tail;
      this.ring.lineWidth = 2.2;
      this.ring.shadowColor = 'rgba(255,94,138,0.9)';
      this.ring.shadowBlur = 6;
      this.ring.beginPath(); this.ring.arc(w / 2, h / 2, this.buttonSize / 2 + 2, 0, Math.PI * 2); this.ring.stroke();
      this.ring.shadowBlur = 0;
      return;
    }
    const g: CanvasGradient = this.ring.createConicGradient(0, w / 2, h / 2);
    g.addColorStop(0, '#FFB547');
    g.addColorStop(0.25, '#FF5E8A');
    g.addColorStop(0.5, '#A86BFF');
    g.addColorStop(0.75, '#4A8DFF');
    g.addColorStop(1, '#FFB547');
    this.ring.strokeStyle = g;
    this.ring.lineWidth = 1.6;
    this.ring.shadowColor = 'rgba(168,107,255,0.9)';
    this.ring.shadowBlur = 5;
    this.ring.beginPath();
    this.ring.arc(w / 2, h / 2, this.buttonSize / 2 + 2, 0, Math.PI * 2);
    this.ring.stroke();
    this.ring.shadowBlur = 0;
  }

  build() {
    Stack() {
      // The canvas turns, so the colors flow round the button.
      if (this.glow_() !== 'off') {
        Canvas(this.ring).width(this.glow()).height(this.glow())
          .onReady((): void => { this.paintRing(); })
          .rotate({ angle: this.flow })
          .opacity(this.lit * (this.glow_() === 'breath' ? 0.45 + this.breath * 0.55 : 0.75 + this.breath * 0.25))
          .scale(this.glow_() === 'breath' ?
            { x: 0.92 + this.lit * 0.04 + this.breath * 0.1, y: 0.92 + this.lit * 0.04 + this.breath * 0.1 } :
            { x: 0.9 + this.lit * 0.1, y: 0.9 + this.lit * 0.1 })
      }
      // The unlit disc, and the white one filling it from the middle as the button lights up.
      Circle().width(this.buttonSize).height(this.buttonSize).fill(aiInk(this.aiStyle, 'surfaceRaised'))
      Circle().width(this.buttonSize).height(this.buttonSize).fill('#FFFFFF')
        .opacity(this.lit).scale({ x: 0.45 + 0.55 * this.lit, y: 0.45 + 0.55 * this.lit })
      // The arrow turns from grey to black and lifts a little (two glyphs cross-fading: a glyph's colour itself
      // cannot be animated).
      SymbolGlyph($r('sys.symbol.arrow_up')).fontSize(this.buttonSize * 0.48)
        .fontWeight(FontWeight.Bold)
        .fontColor([aiInk(this.aiStyle, 'text2')])
        .opacity(1 - this.lit)
      SymbolGlyph($r('sys.symbol.arrow_up')).fontSize(this.buttonSize * 0.48)
        .fontWeight(FontWeight.Bold)
        .fontColor(['#000000'])
        .opacity(this.lit)
        .translate({ y: (1 - this.lit) * 3 })
    }
    // The glow spills past the disc; the button keeps the disc's size in layout.
    .width(this.buttonSize).height(this.buttonSize)
    .scale({ x: this.pop, y: this.pop })
    .accessibilityText('发送给 AI 助手')
    .onClick((): void => { if (this.active) { this.onTap(); } })
  }
}

/**
 * Siri's input field: a smoky glass capsule with a fine rim, brighter on top, that holds the text field. The send
 * orb sits beside it, outside the capsule, like Siri's microphone.
 */
@Component
export struct AiInputCapsule {
  @BuilderParam content: () => void;

  build() {
    Row() { this.content() }
      .layoutWeight(1).constraintSize({ minHeight: 44 }).alignItems(VerticalAlign.Center)
      .padding({ left: 16, right: 12, top: 2, bottom: 2 })
      .borderRadius(22)
      .backgroundColor('#1FFFFFFF')
      .backdropBlur(12)
      .border({ width: { top: 1, left: 0.8, right: 0.8, bottom: 0.8 },
        color: { top: '#59FFFFFF', left: '#29FFFFFF', right: '#29FFFFFF', bottom: '#1FFFFFFF' } })
  }
}

/** Size of the floating Siri orb. */
export const AI_FLOAT_ORB: number = 48;

/** One wave of the orb's ribbon: color, amplitude and frequency (share of the orb), speed and phase. */
class AiOrbWave {
  color: string;
  amplitude: number;
  cycles: number;
  speed: number;
  phase: number;
  offset: number;
  width: number;

  constructor(color: string, amplitude: number, cycles: number, speed: number, phase: number, offset: number,
    width: number) {
    this.color = color;
    this.amplitude = amplitude;
    this.cycles = cycles;
    this.speed = speed;
    this.phase = phase;
    this.offset = offset;
    this.width = width;
  }
}

/** '#RRGGBB' as an rgba() string, unambiguous for the canvas. */
function aiRgba(hex: string, alpha: number): string {
  const n: number = parseInt(hex.substring(1), 16);
  return 'rgba(' + ((n >> 16) & 255).toString() + ',' + ((n >> 8) & 255).toString() + ',' + (n & 255).toString() + ',' +
    alpha.toString() + ')';
}

/** Warm waves ride a little above the center line, cool ones below, a white core in between. */
const AI_ORB_WAVES: AiOrbWave[] = [
  // After Siri's orb: fine bright strands of warm red-orange over a white-hot core over blue and cyan, each with a
  // luminous halo, flowing briskly in long waves across the orb.
  new AiOrbWave('#FF3B26', 0.11, 0.8, 2.2, 0.0, -0.055, 0.05),
  new AiOrbWave('#FF9A3A', 0.09, 0.95, -2.6, 1.1, -0.028, 0.04),
  new AiOrbWave('#FF5C9A', 0.06, 0.7, 1.9, 2.0, -0.012, 0.03),
  new AiOrbWave('#2E6BFF', 0.12, 0.75, 2.0, 2.6, 0.055, 0.05),
  new AiOrbWave('#3CDCFF', 0.09, 0.9, -2.4, 3.7, 0.03, 0.04),
  new AiOrbWave('#FFFFFF', 0.05, 0.85, 2.8, 0.6, 0.004, 0.025)
];

/**
 * The floating assistant as Siri's voice orb: a dark glass sphere with a ribbon of sine waves of light flowing across
 * its middle — deep red and orange above, blue and cyan below, a white core — that taper out towards the rim and add
 * up where they cross. One clock (vsync) drives it; `active` makes the waves faster and taller.
 */
@Component
export struct AiSiriOrb {
  @Prop orbSize: number = AI_FLOAT_ORB;
  /** One still frame, no clock (settings tiles that are not selected). */
  @Prop still: boolean = false;
  @Prop @Watch('onActiveChanged') active: boolean = false;
  @StorageProp('diagnosticAiReducedMotion') @Watch('onReducedMotionChanged') reducedMotion: boolean = false;
  private readonly settings: RenderingContextSettings = new RenderingContextSettings(true);
  private readonly ctx: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.settings);
  private sync: displaySync.DisplaySync | null = null;
  private timer: number = -1;
  private ready: boolean = false;

  aboutToAppear(): void {
    if (this.reducedMotion || this.still) { return; }
    this.startTicker();
  }

  private onReducedMotionChanged(): void {
    if (this.reducedMotion) { this.stopTicker(); }
    else { this.startTicker(); }
    this.draw();
  }

  private onActiveChanged(): void {
    if (this.reducedMotion) { this.draw(); }
  }

  private startTicker(): void {
    if (this.reducedMotion || this.sync !== null || this.timer !== -1) { return; }
    try {
      const sync: displaySync.DisplaySync = displaySync.create();
      sync.setExpectedFrameRateRange({ min: 30, max: 60, expected: 60 });
      sync.on('frame', (): void => { this.draw(); });
      sync.start();
      this.sync = sync;
    } catch (_error) {
      this.timer = setInterval((): void => { this.draw(); }, 16);
    }
  }

  aboutToDisappear(): void {
    this.stopTicker();
  }

  private stopTicker(): void {
    if (this.sync !== null) {
      try { this.sync.stop(); this.sync.off('frame'); } catch (_error) { /* already stopped */ }
      this.sync = null;
    }
    if (this.timer !== -1) { clearInterval(this.timer); this.timer = -1; }
  }

  private draw(): void {
    if (!this.ready) { return; }
    const w: number = this.ctx.width;
    const h: number = this.ctx.height;
    if (w <= 0 || h <= 0) { return; }
    const t: number = (Date.now() % 600000) / 1000 * (this.active ? 1.8 : 1.3);
    const lift: number = this.active ? 1.3 : 1;
    this.ctx.clearRect(0, 0, w, h);
    this.ctx.globalCompositeOperation = 'lighter';
    this.ctx.lineCap = 'round';
    AI_ORB_WAVES.forEach((wave: AiOrbWave): void => {
      this.ctx.beginPath();
      const steps: number = 40;
      for (let i: number = 0; i <= steps; i++) {
        const u: number = i / steps;                       // 0 … 1 across the orb
        const taper: number = Math.sin(Math.PI * u);       // waves fade out towards the rim
        const x: number = w * (0.08 + 0.84 * u);
        const y: number = h * (0.5 + wave.offset) +
          Math.sin(u * Math.PI * 2 * wave.cycles + t * wave.speed + wave.phase) * h * wave.amplitude * taper * lift;
        if (i === 0) { this.ctx.moveTo(x, y); } else { this.ctx.lineTo(x, y); }
      }
      const g: CanvasGradient = this.ctx.createLinearGradient(w * 0.08, 0, w * 0.92, 0);
      g.addColorStop(0, aiRgba(wave.color, 0));
      g.addColorStop(0.5, aiRgba(wave.color, 1));
      g.addColorStop(1, aiRgba(wave.color, 0));
      this.ctx.strokeStyle = g;
      // A wide faint pass for the glow, then the brighter body of the band.
      // A luminous halo, then the fine bright strand itself.
      this.ctx.globalAlpha = 0.55;
      this.ctx.lineWidth = Math.max(1.2, w * wave.width * 2.4);
      this.ctx.shadowColor = wave.color;
      this.ctx.shadowBlur = w * 0.22;
      this.ctx.stroke();
      this.ctx.globalAlpha = 1;
      this.ctx.lineWidth = Math.max(0.6, w * wave.width);
      this.ctx.shadowBlur = w * 0.08;
      this.ctx.stroke();
      this.ctx.globalAlpha = 1;
    });
    this.ctx.shadowBlur = 0;
    this.ctx.globalCompositeOperation = 'source-over';
  }

  build() {
    Stack() {
      // Soft light the orb casts around itself.
      Column().width(this.orbSize * 1.5).height(this.orbSize * 1.5).borderRadius(this.orbSize)
        .radialGradient({ center: ['50%', '52%'], radius: this.orbSize * 0.75,
          colors: [[this.active ? '#4D4D8CFF' : '#2E4D8CFF', 0], ['#1FFF6A3D', 0.5], ['#00000000', 1]] })
      Stack() {
        Column().width('100%').height('100%')
          .radialGradient({ center: ['50%', '36%'], radius: this.orbSize * 0.64,
            colors: [['#FF15151C', 0], ['#FF07070B', 0.7], ['#FF1C2434', 1]] })
        Canvas(this.ctx).width('100%').height('100%')
          .onReady((): void => { this.ready = true; this.draw(); })
        Column().width('100%').height('100%').borderRadius(this.orbSize / 2)
          .border({ width: 1, color: { top: '#40FFFFFF', left: '#59FF6A3D', right: '#5939D5FF', bottom: '#4DA0C4FF' } })
        Column().width('100%').height('100%')
          .radialGradient({ center: ['50%', '6%'], radius: this.orbSize * 0.42,
            colors: [['#2EFFFFFF', 0], ['#00FFFFFF', 1]] })
      }
      .width(this.orbSize).height(this.orbSize).borderRadius(this.orbSize / 2).clip(true)
    }
    .width(this.orbSize).height(this.orbSize)
    .hitTestBehavior(HitTestMode.Transparent)
  }
}

/**
 * Apple-style "done" mark, played once: the circle draws itself, then the check strokes in, and the mark gives a
 * small pop as it completes.
 */
@Component
export struct AiCheckmark {
  @Prop markSize: number = 30;
  @State private pop: number = 1;
  private readonly settings: RenderingContextSettings = new RenderingContextSettings(true);
  private readonly ctx: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.settings);
  private sync: displaySync.DisplaySync | null = null;
  private timer: number = -1;
  private startedAt: number = 0;
  private finished: boolean = false;

  aboutToAppear(): void {
    this.startedAt = Date.now();
    try {
      const sync: displaySync.DisplaySync = displaySync.create();
      sync.setExpectedFrameRateRange({ min: 30, max: 60, expected: 60 });
      sync.on('frame', (): void => { this.draw(); });
      sync.start();
      this.sync = sync;
    } catch (_error) {
      this.timer = setInterval((): void => { this.draw(); }, 16);
    }
  }

  aboutToDisappear(): void { this.stop(); }

  private stop(): void {
    if (this.sync !== null) {
      try { this.sync.stop(); this.sync.off('frame'); } catch (_error) { /* already stopped */ }
      this.sync = null;
    }
    if (this.timer !== -1) { clearInterval(this.timer); this.timer = -1; }
  }

  private ease(x: number): number { return 1 - Math.pow(1 - Math.min(1, Math.max(0, x)), 3); }

  private draw(): void {
    const w: number = this.ctx.width;
    const h: number = this.ctx.height;
    if (w <= 0 || h <= 0) { return; }
    const elapsed: number = Date.now() - this.startedAt;
    const circle: number = this.ease(elapsed / 420);          // 0–420 ms: the circle
    const check: number = this.ease((elapsed - 300) / 360);   // 300–660 ms: the check
    const line: number = Math.max(1.6, w * 0.085);
    const r: number = w / 2 - line;
    this.ctx.clearRect(0, 0, w, h);
    this.ctx.lineCap = 'round';
    this.ctx.lineJoin = 'round';
    this.ctx.lineWidth = line;
    this.ctx.strokeStyle = '#FFFFFF';
    this.ctx.beginPath();
    this.ctx.arc(w / 2, h / 2, r, -Math.PI / 2, -Math.PI / 2 + Math.PI * 2 * circle);
    this.ctx.stroke();
    if (check > 0) {
      // Two strokes: down to the corner, then up to the right; drawn by length.
      const ax: number = w * 0.3; const ay: number = h * 0.52;
      const bx: number = w * 0.44; const by: number = h * 0.66;
      const cx: number = w * 0.71; const cy: number = h * 0.37;
      const first: number = Math.hypot(bx - ax, by - ay);
      const second: number = Math.hypot(cx - bx, cy - by);
      const drawn: number = (first + second) * check;
      this.ctx.beginPath();
      this.ctx.moveTo(ax, ay);
      if (drawn <= first) {
        this.ctx.lineTo(ax + (bx - ax) * drawn / first, ay + (by - ay) * drawn / first);
      } else {
        this.ctx.lineTo(bx, by);
        const rest: number = (drawn - first) / second;
        this.ctx.lineTo(bx + (cx - bx) * rest, by + (cy - by) * rest);
      }
      this.ctx.stroke();
    }
    if (elapsed > 700 && !this.finished) {
      this.finished = true;
      this.stop();
      this.getUIContext().animateTo({ duration: 120, curve: Curve.EaseOut }, (): void => { this.pop = 1.12; });
      this.getUIContext().animateTo({ duration: 260, delay: 120, curve: curves.springMotion(0.3, 0.6) },
        (): void => { this.pop = 1; });
    }
  }

  build() {
    Canvas(this.ctx).width(this.markSize).height(this.markSize)
      .scale({ x: this.pop, y: this.pop })
      .onReady((): void => { this.draw(); })
  }
}
