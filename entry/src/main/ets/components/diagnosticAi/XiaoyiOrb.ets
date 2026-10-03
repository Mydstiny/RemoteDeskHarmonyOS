import { displaySync } from '@kit.ArkGraphics2D';
import { aiMotionSpeedFactor } from '../../services/diagnosticAi/DiagnosticAiMotionPolicy';

/** Orbit speed of the six dots, clockwise (measured on the reference recording: about 75°/s, one turn in 4.8 s). */
const AI_RING_ORBIT_DEG_PER_S: number = 75;
/** The size peak travels the other way, counter-clockwise on screen (about 150°/s, one turn in 2.4 s). */
const AI_RING_WAVE_DEG_PER_S: number = -150;
/** Dot diameters as a share of the ring radius: smallest and largest. */
const AI_RING_DOT_MIN: number = 0.44;
const AI_RING_DOT_MAX: number = 0.7;
/** How long a new ring takes to open from one dot (the Siri reference: a dot, a tight ring, then the full ring). */
const AI_RING_BLOOM_MS: number = 560;

/**
 * The assistant's thinking / loading indicator, rebuilt from a frame-by-frame measurement of the reference: six
 * crisp, solid white dots on a ring turn clockwise at a steady speed, while a size peak runs around the ring the
 * other way, so about two neighbouring dots are large and the rest small at any moment; a large soft white light
 * sits behind the ring on the side of the large dots and turns with the peak.
 *
 * Each dot glows: a white core in a soft bloom whose rim turns faintly cool blue, over a dim haze that follows the ring
 * and leaves its middle dark. A ring that starts thinking opens from a single dot into a tight ring that springs out
 * to full size; one that is only re-created during a morph (another ring was on screen a moment ago) does not.
 *
 * One clock drives everything (the display's vsync, falling back to a timer). Positions and sizes are computed from
 * the wall-clock time, so every instance is in phase and a ring that is re-created during a morph never jumps.
 */
@Component
export struct AiKernelRing {
  @Prop ringSize: number = 34;
  /** One still frame, no clock (settings tiles that are not selected). */
  @Prop still: boolean = false;
  @StorageProp('diagnosticAiReducedMotion') @Watch('onReducedMotionChanged') reducedMotion: boolean = false;
  @State private clock: number = 0;
  private sync: displaySync.DisplaySync | null = null;
  private timer: number = -1;
  /** When this ring started opening (0: it shows open at once). */
  private bornAt: number = 0;
  /** The last frame any ring drew: a ring re-created right after another one continues it instead of opening again. */
  private static lastFrameAt: number = 0;

  aboutToAppear(): void {
    this.clock = Date.now();
    if (this.reducedMotion || this.still) { return; }
    this.bornAt = this.clock - AiKernelRing.lastFrameAt > 300 ? this.clock : 0;
    this.startClock();
  }

  private onReducedMotionChanged(): void {
    this.clock = Date.now();
    if (this.reducedMotion) { this.stopClock(); }
    else { this.startClock(); }
  }

  private startClock(): void {
    if (this.reducedMotion || this.sync !== null || this.timer !== -1) { return; }
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

  private tick(): void {
    this.clock = Date.now();
    AiKernelRing.lastFrameAt = this.clock;
  }

  aboutToDisappear(): void {
    this.stopClock();
  }

  private stopClock(): void {
    if (this.sync !== null) {
      try { this.sync.stop(); this.sync.off('frame'); } catch (_error) { /* already stopped */ }
      this.sync = null;
    }
    if (this.timer !== -1) { clearInterval(this.timer); this.timer = -1; }
  }

  /** 0…1 while the ring opens (eased), 1 once open. */
  private opening(): number {
    if (this.bornAt === 0) { return 1; }
    const p: number = Math.min(1, Math.max(0, (this.clock - this.bornAt) / AI_RING_BLOOM_MS));
    return p;
  }
  /** Ring radius share while opening: a dot, then a tight ring that springs a little past full size and settles. */
  private spread(): number {
    const p: number = this.opening();
    if (p >= 1) { return 1; }
    const tight: number = Math.min(1, p / 0.28);
    if (p < 0.28) { return 0.04 + 0.26 * tight * tight; }
    const q: number = (p - 0.28) / 0.72;
    const c: number = 1.70158 * 1.15;
    return 0.3 + 0.7 * (1 + (c + 1) * Math.pow(q - 1, 3) + c * Math.pow(q - 1, 2));
  }
  /** Ring radius: the ring plus its largest dot fills the box. */
  private radius(): number { return this.ringSize / (2 + AI_RING_DOT_MAX + 0.1); }
  private orbitRadius(): number { return this.radius() * this.spread(); }
  @StorageProp('aiMotion.speed') speed: string = 'normal';
  /** Wall-clock seconds scaled by AI 动效 › 动效速度 (all rings stay in step with one another). */
  private seconds(): number { return (this.clock % 3600000) / 1000 * aiMotionSpeedFactor(this.speed); }
  private orbit(i: number): number { return (i * 60 + AI_RING_ORBIT_DEG_PER_S * this.seconds()) * Math.PI / 180; }
  private peak(): number { return (AI_RING_WAVE_DEG_PER_S * this.seconds()) * Math.PI / 180; }

  /** Narrow bump around the peak: about two neighbours large, the far side small. */
  private dot(i: number): number {
    const w: number = Math.pow((1 + Math.cos(this.orbit(i) - this.peak())) / 2, 1.6);
    // While the ring opens the dots start small (the first dot is one of them) and grow with the spread.
    const grow: number = 0.55 + 0.45 * Math.min(1, this.opening() / 0.6);
    return this.radius() * (AI_RING_DOT_MIN + (AI_RING_DOT_MAX - AI_RING_DOT_MIN) * w) * grow;
  }
  private cx(i: number): number { return this.ringSize / 2 + Math.cos(this.orbit(i)) * this.orbitRadius(); }
  private cy(i: number): number { return this.ringSize / 2 + Math.sin(this.orbit(i)) * this.orbitRadius(); }
  private core(i: number): number { return this.dot(i) * 0.84; }
  private bloom(i: number): number { return this.dot(i) * 2.2; }

  private glowSize(): number { return this.radius() * 4.4; }
  private glowX(): number { return this.ringSize / 2 + Math.cos(this.peak()) * this.orbitRadius() * 0.45 - this.glowSize() / 2; }
  private glowY(): number { return this.ringSize / 2 + Math.sin(this.peak()) * this.orbitRadius() * 0.45 - this.glowSize() / 2; }
  private hazeSize(): number { return this.radius() * 3.9; }

  build() {
    Stack() {
      // Dim haze along the ring, its middle left dark (the grey bloom between the reference's dots).
      Column().width(this.hazeSize()).height(this.hazeSize()).borderRadius(this.hazeSize() / 2)
        .radialGradient({ center: ['50%', '50%'], radius: this.hazeSize() / 2,
          colors: [['#00FFFFFF', 0], ['#00FFFFFF', 0.28], ['#2ED6E4FF', 0.52], ['#18FFFFFF', 0.72], ['#00FFFFFF', 1]] })
        .position({ x: (this.ringSize - this.hazeSize()) / 2, y: (this.ringSize - this.hazeSize()) / 2 })
        .opacity(Math.min(1, this.opening() * 1.4))
      // Soft white light behind the ring, on the side of the large dots.
      Column().width(this.glowSize()).height(this.glowSize()).borderRadius(this.glowSize() / 2)
        .radialGradient({ center: ['50%', '50%'], radius: this.glowSize() / 2,
          colors: [['#9EFFFFFF', 0], ['#3DFFFFFF', 0.45], ['#00FFFFFF', 1]] })
        .position({ x: this.glowX(), y: this.glowY() })
        .opacity(this.opening())
      // Each dot's bloom: white at the core, a faint cool blue at the rim.
      ForEach([0, 1, 2, 3, 4, 5], (i: number): void => {
        Column().width(this.bloom(i)).height(this.bloom(i)).borderRadius(this.bloom(i) / 2)
          .radialGradient({ center: ['50%', '50%'], radius: this.bloom(i) / 2,
            colors: [['#F2FFFFFF', 0], ['#B3EAF2FF', 0.36], ['#47A8C9FF', 0.62], ['#00A8C9FF', 1]] })
          .position({ x: this.cx(i) - this.bloom(i) / 2, y: this.cy(i) - this.bloom(i) / 2 })
      }, (i: number): string => 'bloom' + i.toString())
      ForEach([0, 1, 2, 3, 4, 5], (i: number): void => {
        Circle().width(this.core(i)).height(this.core(i)).fill('#FFFFFF')
          .position({ x: this.cx(i) - this.core(i) / 2, y: this.cy(i) - this.core(i) / 2 })
      }, (i: number): string => 'kernel' + i.toString())
    }
    .width(this.ringSize).height(this.ringSize)
    .hitTestBehavior(HitTestMode.None)
  }
}
