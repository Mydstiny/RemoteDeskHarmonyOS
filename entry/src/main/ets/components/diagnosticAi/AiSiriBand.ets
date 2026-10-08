import { displaySync } from '@kit.ArkGraphics2D';

/** One coloured strand of the band. */
class AiBandStrand {
  rgb: number[];
  /** Waves across the band, speed (rad/s) and phase: no two strands move together. */
  waves: number;
  speed: number;
  phase: number;
  /** Thickness as a share of the band's, and which way it leans from the middle (−1 up … 1 down). */
  thickness: number;
  lean: number;
  /** Where along the band its colour is strongest (0 left … 1 right). */
  focus: number;
  alpha: number;

  constructor(rgb: number[], waves: number, speed: number, phase: number, thickness: number, lean: number, focus: number,
    alpha: number) {
    this.rgb = rgb;
    this.waves = waves;
    this.speed = speed;
    this.phase = phase;
    this.thickness = thickness;
    this.lean = lean;
    this.focus = focus;
    this.alpha = alpha;
  }
}

/**
 * The reference's band: warm colour on the left (orange, pink, a little yellow), cool on the right (cyan, blue),
 * meeting in a white core; the strands drift past one another so the fringes shimmer.
 */
const AI_BAND_STRANDS: AiBandStrand[] = [
  new AiBandStrand([255, 108, 56], 0.9, 2.6, 0.0, 1.0, -0.55, 0.28, 0.9),
  new AiBandStrand([255, 70, 150], 1.15, -2.1, 1.7, 0.75, 0.6, 0.38, 0.75),
  new AiBandStrand([255, 206, 92], 0.7, 1.7, 3.1, 0.5, -0.2, 0.46, 0.55),
  new AiBandStrand([84, 206, 255], 1.0, -2.8, 4.2, 0.95, 0.5, 0.7, 0.9),
  new AiBandStrand([96, 112, 255], 1.3, 2.2, 5.3, 0.7, -0.6, 0.8, 0.8)
];

function rgba(rgb: number[], a: number): string {
  return 'rgba(' + rgb[0].toString() + ',' + rgb[1].toString() + ',' + rgb[2].toString() + ',' +
    Math.max(0, Math.min(1, a)).toFixed(3) + ')';
}

/** Siri's taper: full in the middle, easing smoothly to nothing at both ends (x in −1…1). */
function taper(x: number): number {
  const k: number = 2.2;
  const s: number = x * 2;
  return Math.pow(k / (k + s * s * s * s), k);
}

/**
 * The light inside the voice droplet, drawn on a canvas every frame: tapered colour strands that drift and cross,
 * blended additively into a white core, with a soft glow. `level` (0…1, the voice or the speech) swells the swing,
 * the thickness and the brightness; at 0 the band still shimmers a little so the droplet never looks dead.
 */
@Component
export struct AiSiriBand {
  @Prop level: number = 0;
  /** Stronger colour (dark theme, or while the answer is spoken). */
  @Prop vivid: boolean = false;
  @StorageProp('diagnosticAiReducedMotion') reducedMotion: boolean = false;
  private readonly settings: RenderingContextSettings = new RenderingContextSettings(true);
  private readonly ctx: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.settings);
  private sync: displaySync.DisplaySync | null = null;
  private timer: number = -1;
  private ready: boolean = false;
  private readonly born: number = Date.now();

  aboutToAppear(): void { if (!this.reducedMotion) { this.start(); } }

  aboutToDisappear(): void { this.stop(); }

  private start(): void {
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

  private stop(): void {
    if (this.sync !== null) {
      try { this.sync.stop(); this.sync.off('frame'); } catch (_error) { /* already stopped */ }
      this.sync = null;
    }
    if (this.timer !== -1) { clearInterval(this.timer); this.timer = -1; }
  }

  /** Centre line of a strand at x (−1…1). */
  private centre(x: number, t: number, strand: AiBandStrand, swing: number, mid: number): number {
    const a: number = Math.sin(Math.PI * strand.waves * x + strand.speed * t + strand.phase);
    const b: number = Math.sin(Math.PI * strand.waves * 1.7 * x - strand.speed * 0.6 * t + strand.phase * 1.3);
    return mid + (a * 0.75 + b * 0.25) * swing * taper(x) + strand.lean * swing * 0.18 * taper(x);
  }

  private spindle(w: number, h: number, t: number, strand: AiBandStrand, swing: number, half: number): void {
    const c = this.ctx;
    const mid: number = h / 2;
    const steps: number = 56;
    c.beginPath();
    for (let i = 0; i <= steps; i++) {
      const x: number = i / steps * 2 - 1;
      const y: number = this.centre(x, t, strand, swing, mid) - half * taper(x);
      const px: number = (x + 1) / 2 * w;
      if (i === 0) { c.moveTo(px, y); } else { c.lineTo(px, y); }
    }
    for (let i = steps; i >= 0; i--) {
      const x: number = i / steps * 2 - 1;
      c.lineTo((x + 1) / 2 * w, this.centre(x, t, strand, swing, mid) + half * taper(x));
    }
    c.closePath();
  }

  private draw(): void {
    if (!this.ready) { return; }
    const c = this.ctx;
    const w: number = c.width;
    const h: number = c.height;
    if (w <= 0 || h <= 0) { return; }
    const t: number = this.reducedMotion ? 0.8 : (Date.now() - this.born) / 1000;
    const level: number = Math.max(0, Math.min(1, this.level));
    // Even at rest the light breathes a little.
    const amp: number = 0.16 + 0.84 * level + 0.05 * Math.sin(t * 1.3);
    const swing: number = h * 0.2 * amp;
    const thick: number = h * (0.07 + 0.2 * amp);
    const strength: number = (this.vivid ? 1 : 0.8) * (0.55 + 0.45 * Math.min(1, amp * 1.2));
    c.clearRect(0, 0, w, h);
    c.globalCompositeOperation = 'lighter';
    // Colour strands: a wide faint glow pass, then the strands.
    for (let pass = 0; pass < 2; pass++) {
      AI_BAND_STRANDS.forEach((strand: AiBandStrand): void => {
        this.spindle(w, h, t, strand, swing, thick * strand.thickness * (pass === 0 ? 1.6 : 1) / 2);
        const g: CanvasGradient = c.createLinearGradient(0, 0, w, 0);
        const a: number = strand.alpha * strength * (pass === 0 ? 0.22 : 0.85);
        g.addColorStop(0, rgba(strand.rgb, 0));
        g.addColorStop(Math.max(0.02, strand.focus - 0.3), rgba(strand.rgb, a * 0.35));
        g.addColorStop(strand.focus, rgba(strand.rgb, a));
        g.addColorStop(Math.min(0.98, strand.focus + 0.3), rgba(strand.rgb, a * 0.35));
        g.addColorStop(1, rgba(strand.rgb, 0));
        c.fillStyle = g;
        c.shadowColor = rgba(strand.rgb, pass === 0 ? 0.6 : 0.45);
        c.shadowBlur = h * (pass === 0 ? 0.5 : 0.18);
        c.fill();
      });
    }
    // The white core where the colours meet.
    const core: AiBandStrand = new AiBandStrand([255, 255, 255], 0.6, 1.4, 0.6, 1, 0, 0.5, 1);
    this.spindle(w, h, t, core, swing * 0.45, h * (0.025 + 0.075 * amp));
    const white: CanvasGradient = c.createLinearGradient(0, 0, w, 0);
    white.addColorStop(0, 'rgba(255,255,255,0)');
    white.addColorStop(0.3, 'rgba(255,255,255,' + (0.55 * strength).toFixed(3) + ')');
    white.addColorStop(0.5, 'rgba(255,255,255,' + Math.min(1, 0.95 * strength + 0.1).toFixed(3) + ')');
    white.addColorStop(0.7, 'rgba(255,255,255,' + (0.55 * strength).toFixed(3) + ')');
    white.addColorStop(1, 'rgba(255,255,255,0)');
    c.fillStyle = white;
    c.shadowColor = 'rgba(255,255,255,0.85)';
    c.shadowBlur = h * 0.35;
    c.fill();
    c.shadowBlur = 0;
    c.globalCompositeOperation = 'source-over';
  }

  build() {
    // Fills whatever box it is given (its owner animates that box), drawing at the box's current size each frame.
    Canvas(this.ctx).width('100%').height('100%')
      .onReady((): void => { this.ready = true; this.draw(); })
      .hitTestBehavior(HitTestMode.None)
  }
}
