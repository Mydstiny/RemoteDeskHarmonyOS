import { displaySync } from '@kit.ArkGraphics2D';

/** Orbit speed of the six dots, clockwise (measured on the reference recording: about 75°/s, one turn in 4.8 s). */
const AI_RING_ORBIT_DEG_PER_S: number = 75;
/** The size peak travels the other way, counter-clockwise on screen (about 150°/s, one turn in 2.4 s). */
const AI_RING_WAVE_DEG_PER_S: number = -150;
/** Dot diameters as a share of the ring radius: smallest and largest. */
const AI_RING_DOT_MIN: number = 0.44;
const AI_RING_DOT_MAX: number = 0.7;

/**
 * The assistant's thinking / loading indicator, rebuilt from a frame-by-frame measurement of the reference: six
 * crisp, solid white dots on a ring turn clockwise at a steady speed, while a size peak runs around the ring the
 * other way, so about two neighbouring dots are large and the rest small at any moment; a large soft white light
 * sits behind the ring on the side of the large dots and turns with the peak.
 *
 * One clock drives everything (the display's vsync, falling back to a timer). Positions and sizes are computed from
 * the wall-clock time, so every instance is in phase and a ring that is re-created during a morph never jumps.
 */
@Component
export struct AiKernelRing {
  @Prop ringSize: number = 34;
  @State private clock: number = 0;
  private sync: displaySync.DisplaySync | null = null;
  private timer: number = -1;

  aboutToAppear(): void {
    this.clock = Date.now();
    try {
      const sync: displaySync.DisplaySync = displaySync.create();
      sync.setExpectedFrameRateRange({ min: 30, max: 60, expected: 60 });
      sync.on('frame', (): void => { this.clock = Date.now(); });
      sync.start();
      this.sync = sync;
    } catch (_error) {
      this.timer = setInterval((): void => { this.clock = Date.now(); }, 16);
    }
  }

  aboutToDisappear(): void {
    if (this.sync !== null) {
      try { this.sync.stop(); this.sync.off('frame'); } catch (_error) { /* already stopped */ }
      this.sync = null;
    }
    if (this.timer !== -1) { clearInterval(this.timer); this.timer = -1; }
  }

  /** Ring radius: the ring plus its largest dot fills the box. */
  private radius(): number { return this.ringSize / (2 + AI_RING_DOT_MAX + 0.1); }
  private seconds(): number { return (this.clock % 3600000) / 1000; }
  private orbit(i: number): number { return (i * 60 + AI_RING_ORBIT_DEG_PER_S * this.seconds()) * Math.PI / 180; }
  private peak(): number { return (AI_RING_WAVE_DEG_PER_S * this.seconds()) * Math.PI / 180; }

  /** Narrow bump around the peak: about two neighbours large, the far side small. */
  private dot(i: number): number {
    const w: number = Math.pow((1 + Math.cos(this.orbit(i) - this.peak())) / 2, 1.6);
    return this.radius() * (AI_RING_DOT_MIN + (AI_RING_DOT_MAX - AI_RING_DOT_MIN) * w);
  }
  private x(i: number): number { return this.ringSize / 2 + Math.cos(this.orbit(i)) * this.radius() - this.dot(i) / 2; }
  private y(i: number): number { return this.ringSize / 2 + Math.sin(this.orbit(i)) * this.radius() - this.dot(i) / 2; }

  private glowSize(): number { return this.radius() * 4.4; }
  private glowX(): number { return this.ringSize / 2 + Math.cos(this.peak()) * this.radius() * 0.45 - this.glowSize() / 2; }
  private glowY(): number { return this.ringSize / 2 + Math.sin(this.peak()) * this.radius() * 0.45 - this.glowSize() / 2; }

  build() {
    Stack() {
      // Soft white light behind the ring, on the side of the large dots.
      Column().width(this.glowSize()).height(this.glowSize()).borderRadius(this.glowSize() / 2)
        .radialGradient({ center: ['50%', '50%'], radius: this.glowSize() / 2,
          colors: [['#C8FFFFFF', 0], ['#5CFFFFFF', 0.45], ['#00FFFFFF', 1]] })
        .position({ x: this.glowX(), y: this.glowY() })
      ForEach([0, 1, 2, 3, 4, 5], (i: number): void => {
        Circle().width(this.dot(i)).height(this.dot(i)).fill('#FFFFFF')
          .position({ x: this.x(i), y: this.y(i) })
      }, (i: number): string => 'kernel' + i.toString())
    }
    .width(this.ringSize).height(this.ringSize)
    .hitTestBehavior(HitTestMode.None)
  }
}
