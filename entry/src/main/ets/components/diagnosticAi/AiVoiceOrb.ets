import { displaySync } from '@kit.ArkGraphics2D';
import { AI_MOTION_SPEED, aiMotionSpeedFactor } from '../../services/diagnosticAi/DiagnosticAiMotionPolicy';

/**
 * One ribbon of the voice orb. All ribbons share one motion; each follows it `delay` seconds later (the layered
 * trail), with its own color weighting along the band, its own thickness and its own side of the wave.
 */
class AiVoiceRibbon {
  color: number[];
  /** Which end the color sits at: -1 left, 1 right, 0 both. */
  side: number;
  thickness: number;
  phase: number;
  delay: number;
  alpha: number;

  constructor(color: number[], side: number, thickness: number, phase: number, delay: number, alpha: number) {
    this.color = color;
    this.side = side;
    this.thickness = thickness;
    this.phase = phase;
    this.delay = delay;
    this.alpha = alpha;
  }
}

/**
 * Measured on the reference recording (475 frames): spindle-shaped ribbons spanning the sphere, 9–22 % of its
 * diameter thick at the middle; a point on them rises and falls about twice a second by ±9 % of the diameter; the
 * orange and cyan ribbons move in opposite phase (orange weighted to the left, cyan to the right) and add up to a
 * white core where they cross; thin red and blue strands under them; five layers trailing one another by ~67 ms;
 * thickness and swing breathe together on a ~4 s cycle.
 */
const AI_VOICE_RIBBONS: AiVoiceRibbon[] = [
  new AiVoiceRibbon([255, 140, 54], -1, 0.85, 0, 0, 0.95),
  new AiVoiceRibbon([93, 214, 255], 1, 0.85, Math.PI, 0.067, 0.95),
  new AiVoiceRibbon([255, 36, 20], 1, 0.32, Math.PI * 0.25, 0.133, 0.7),
  new AiVoiceRibbon([20, 90, 245], -1, 0.6, Math.PI * 1.15, 0.2, 0.8),
  new AiVoiceRibbon([147, 250, 252], 1, 0.55, Math.PI * 0.85, 0.267, 0.75)
];

/** Local rise-and-fall rate of the ribbons (rad/s): about two cycles a second. */
const AI_VOICE_OMEGA: number = Math.PI * 2 * 1.9;
/** Spatial frequency: a little under one wave across the sphere. */
const AI_VOICE_WAVES: number = 0.85;
/** The activity cycle that swells and calms the ribbons. */
const AI_VOICE_BREATH_S: number = 4;

function rgba(c: number[], a: number): string {
  return 'rgba(' + c[0].toString() + ',' + c[1].toString() + ',' + c[2].toString() + ',' + a.toFixed(3) + ')';
}

/**
 * The assistant's voice orb, rebuilt natively from the reference: a near-black glass sphere with a faint
 * iridescence, a pale glass rim, a blue glow on the left of its equator and a pink one on the right, and the layered
 * spindle ribbons flowing across it. One vsync clock drives it; `active` (capturing or thinking) swells the ribbons.
 */
@Component
export struct AiVoiceOrb {
  @Prop orbSize: number = 48;
  @Prop active: boolean = false;
  /** Sphere and rim; off to draw only the ribbons (the thinking indicator's 语音波). */
  @Prop sphere: boolean = true;
  /** One still frame, no clock (settings tiles that are not selected). */
  @Prop still: boolean = false;
  @StorageProp('diagnosticAiReducedMotion') @Watch('onReducedMotionChanged') reducedMotion: boolean = false;
  @StorageProp(AI_MOTION_SPEED) speed: string = 'normal';
  private readonly settings: RenderingContextSettings = new RenderingContextSettings(true);
  private readonly ctx: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.settings);
  private sync: displaySync.DisplaySync | null = null;
  private timer: number = -1;
  private ready: boolean = false;
  private readonly born: number = Date.now();

  aboutToAppear(): void { if (!this.reducedMotion && !this.still) { this.start(); } }

  aboutToDisappear(): void { this.stop(); }

  private onReducedMotionChanged(): void {
    if (this.reducedMotion) { this.stop(); } else { this.start(); }
    this.draw();
  }

  private start(): void {
    if (this.sync !== null || this.timer !== -1) { return; }
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

  private seconds(): number {
    if (this.reducedMotion || this.still) { return 0.6; }
    return (Date.now() - this.born) / 1000 * aiMotionSpeedFactor(this.speed);
  }

  /** Centre line of a ribbon at u (0…1 across) and time t: two waves for an organic, non-repeating swing. */
  private centre(u: number, t: number, phase: number, swing: number, h: number): number {
    const a: number = Math.sin(Math.PI * 2 * AI_VOICE_WAVES * u + AI_VOICE_OMEGA * t + phase);
    const b: number = Math.sin(Math.PI * 2 * 1.6 * u - AI_VOICE_OMEGA * 0.55 * t + phase * 0.7 + 1.3);
    return h / 2 + (a * 0.72 + b * 0.28) * swing * Math.pow(Math.sin(Math.PI * u), 0.8);
  }

  private drawSphere(w: number, h: number): void {
    const c = this.ctx;
    const cx: number = w / 2;
    const cy: number = h / 2;
    const r: number = w / 2 - 0.5;
    const body: CanvasGradient = c.createRadialGradient(cx, cy * 0.85, r * 0.1, cx, cy, r);
    body.addColorStop(0, 'rgba(14,14,20,1)');
    body.addColorStop(0.75, 'rgba(5,5,9,1)');
    body.addColorStop(1, 'rgba(22,26,36,1)');
    c.fillStyle = body;
    c.beginPath(); c.arc(cx, cy, r, 0, Math.PI * 2); c.fill();
    // Faint iridescence inside the glass: soft violet low, warm high.
    const iris1: CanvasGradient = c.createRadialGradient(cx - r * 0.35, cy + r * 0.45, 0, cx - r * 0.35, cy + r * 0.45, r * 0.7);
    iris1.addColorStop(0, 'rgba(188,91,219,0.12)'); iris1.addColorStop(1, 'rgba(188,91,219,0)');
    c.fillStyle = iris1; c.fillRect(0, 0, w, h);
    const iris2: CanvasGradient = c.createRadialGradient(cx + r * 0.4, cy - r * 0.5, 0, cx + r * 0.4, cy - r * 0.5, r * 0.6);
    iris2.addColorStop(0, 'rgba(240,145,87,0.08)'); iris2.addColorStop(1, 'rgba(240,145,87,0)');
    c.fillStyle = iris2; c.fillRect(0, 0, w, h);
    // Equator glows: blue on the left, pink on the right.
    const blue: CanvasGradient = c.createRadialGradient(cx - r * 0.97, cy, 0, cx - r * 0.97, cy, r * 0.26);
    blue.addColorStop(0, 'rgba(47,107,255,0.65)'); blue.addColorStop(1, 'rgba(47,107,255,0)');
    c.fillStyle = blue; c.fillRect(0, 0, w, h);
    const pink: CanvasGradient = c.createRadialGradient(cx + r * 0.95, cy, 0, cx + r * 0.95, cy, r * 0.32);
    pink.addColorStop(0, 'rgba(255,111,168,0.4)'); pink.addColorStop(1, 'rgba(255,111,168,0)');
    c.fillStyle = pink; c.fillRect(0, 0, w, h);
  }

  private drawRim(w: number, h: number): void {
    const c = this.ctx;
    const cx: number = w / 2;
    const cy: number = h / 2;
    const r: number = w / 2 - 0.8;
    // Pale glass edge, brightest along the sides and bottom.
    const rim: CanvasGradient = c.createLinearGradient(0, 0, 0, h);
    rim.addColorStop(0, 'rgba(255,255,255,0.22)');
    rim.addColorStop(0.5, 'rgba(255,255,255,0.4)');
    rim.addColorStop(1, 'rgba(255,255,255,0.55)');
    c.strokeStyle = rim;
    c.lineWidth = Math.max(0.8, w * 0.022);
    c.shadowColor = 'rgba(255,255,255,0.35)';
    c.shadowBlur = w * 0.06;
    c.beginPath(); c.arc(cx, cy, r, 0, Math.PI * 2); c.stroke();
    c.shadowBlur = 0;
  }

  private drawRibbons(w: number, h: number, t: number): void {
    const c = this.ctx;
    const breath: number = 1 + 0.35 * Math.sin(Math.PI * 2 * t / AI_VOICE_BREATH_S);
    const lift: number = this.active ? 1.25 : 1;
    const thick: number = h * 0.13 * breath * lift;
    const swing: number = h * 0.09 * breath * lift;
    // Edge to edge: the circle clips the ribbons, so their pointed ends meet the rim as in the reference.
    const left: number = 0;
    const span: number = w;
    const steps: number = 28;
    c.globalCompositeOperation = 'lighter';
    // A wide faint pass first (the glow), then the ribbons themselves.
    for (let pass: number = 0; pass < 2; pass++) {
      AI_VOICE_RIBBONS.forEach((ribbon: AiVoiceRibbon): void => {
        const tt: number = t - ribbon.delay;
        const half: number = thick * ribbon.thickness / 2 * (pass === 0 ? 1.3 : 1);
        c.beginPath();
        for (let i: number = 0; i <= steps; i++) {
          const u: number = i / steps;
          const y: number = this.centre(u, tt, ribbon.phase, swing, h) - half * Math.pow(Math.sin(Math.PI * u), 1.0);
          if (i === 0) { c.moveTo(left + span * u, y); } else { c.lineTo(left + span * u, y); }
        }
        for (let i: number = steps; i >= 0; i--) {
          const u: number = i / steps;
          c.lineTo(left + span * u, this.centre(u, tt, ribbon.phase, swing, h) + half * Math.pow(Math.sin(Math.PI * u), 1.0));
        }
        c.closePath();
        const g: CanvasGradient = c.createLinearGradient(left, 0, left + span, 0);
        // Crisp, solid sheets of color carried right out to their own side of the sphere; the glow stays restrained.
        const a: number = ribbon.alpha * (pass === 0 ? 0.12 : 1);
        if (ribbon.side < 0) {
          g.addColorStop(0, rgba(ribbon.color, a * 0.9)); g.addColorStop(0.5, rgba(ribbon.color, a));
          g.addColorStop(0.82, rgba(ribbon.color, a * 0.4)); g.addColorStop(1, rgba(ribbon.color, 0));
        } else {
          g.addColorStop(0, rgba(ribbon.color, 0)); g.addColorStop(0.18, rgba(ribbon.color, a * 0.4));
          g.addColorStop(0.5, rgba(ribbon.color, a)); g.addColorStop(1, rgba(ribbon.color, a * 0.9));
        }
        c.fillStyle = g;
        c.shadowColor = rgba(ribbon.color, pass === 0 ? 0.5 : 0.7);
        c.shadowBlur = w * (pass === 0 ? 0.08 : 0.015);
        c.fill();
      });
    }
    c.shadowBlur = 0;
    c.globalCompositeOperation = 'source-over';
  }

  private draw(): void {
    if (!this.ready) { return; }
    const w: number = this.ctx.width;
    const h: number = this.ctx.height;
    if (w <= 0 || h <= 0) { return; }
    const t: number = this.seconds();
    const c = this.ctx;
    c.clearRect(0, 0, w, h);
    c.save();
    // The whole orb breathes a little with the ribbons.
    const pulse: number = this.sphere ? 1 + 0.04 * Math.sin(Math.PI * 2 * t / AI_VOICE_BREATH_S) : 1;
    c.translate(w / 2, h / 2); c.scale(pulse, pulse); c.translate(-w / 2, -h / 2);
    if (this.sphere) {
      this.drawSphere(w, h);
      c.save();
      c.beginPath(); c.arc(w / 2, h / 2, w / 2 - 1, 0, Math.PI * 2); c.clip();
      this.drawRibbons(w, h, t);
      c.restore();
      this.drawRim(w, h);
    } else {
      this.drawRibbons(w, h, t);
    }
    c.restore();
  }

  build() {
    Canvas(this.ctx).width(this.orbSize).height(this.orbSize)
      .onReady((): void => { this.ready = true; this.draw(); })
      .hitTestBehavior(HitTestMode.Transparent)
  }
}
