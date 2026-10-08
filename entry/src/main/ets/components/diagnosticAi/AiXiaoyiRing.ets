import { hilog } from '@kit.PerformanceAnalysisKit';
import { AiFrameClock } from './AiMotionCanvas';
import { AI_MOTION_REDUCED, AI_MOTION_SPEED, aiMotionSpeedFactor } from '../../services/diagnosticAi/DiagnosticAiMotionPolicy';
import { XY_CYAN, XY_WHITE, XyLiveLevel, XyReach, XyRipple, XyVoice, xyCss, xyCssClear, xyLight, xyRingPoints,
  xyRippleShine, xyRipples } from '../../services/diagnosticAi/AiXiaoyiLight';

const TAU: number = Math.PI * 2;
/** Color stops round each gradient: enough for the flowing glows, few enough to stay cheap every frame. */
const XY_STOPS: number = 18;
const XY_POINTS: number = 72;
/** A small ring (indicators, the orb) is as round with fewer points; every point is a call into the canvas. */
const XY_POINTS_SMALL: number = 48;
/** The trail's copies are blurred: a coarser outline each is plenty. */
const XY_TRAIL_POINTS: number = 36;
/** The tumbling ring's motion trail: this many copies, this far apart (s) — close enough to read as one smear. */
const XY_TRAIL: number = 8;
const XY_TRAIL_STEP: number = 0.0135;

/**
 * The 小艺 halo ring (see AiXiaoyiLight): a canvas that adds its light onto whatever is behind it (BlendMode.PLUS),
 * as the light of the reference does on its glass. `mode` is 'idle', 'listen', 'think' or 'speak'; `level` is the
 * voice (the microphone while listening, the voice read out while speaking). With `ripples` off (indicators, the
 * floating orb) only the ring, its sphere and its trails are drawn, larger in the same canvas.
 */
@Component
export struct AiXiaoyiRing {
  /** The canvas's side (vp). The ring's radius is 22 % of it with ripples, 34 % without. */
  @Prop ringSize: number = 120;
  @Prop mode: string = 'idle';
  @Prop level: number = 0;
  @Prop ripples: boolean = true;
  /** One still frame, no clock (settings tiles that are not selected). Turned on later, the ring stops where it is. */
  @Prop @Watch('onMotionChanged') still: boolean = false;
  /** Comes out of a soft tilted blur into the ring, as the reference opens. */
  @Prop opensFromBlur: boolean = false;
  /** At most this many frames a second (120 on displays that have it; settings previews draw at 20–30). */
  @Prop maxFps: number = 120;
  /** The voice comes from voice mode itself (XyLiveLevel), read every frame, instead of `level`. */
  @Prop live: boolean = false;
  /** The ring's radius (vp); 0 for its usual share of the canvas. A larger canvas leaves room for the glow. */
  @Prop radius: number = 0;
  @StorageProp(AI_MOTION_SPEED) speed: string = 'normal';
  @StorageProp(AI_MOTION_REDUCED) @Watch('onMotionChanged') reduced: boolean = false;
  private readonly settings: RenderingContextSettings = new RenderingContextSettings(true);
  private readonly ctx: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.settings);
  private readonly clock: AiFrameClock = new AiFrameClock();
  private readonly voice: XyVoice = new XyVoice();
  private ready: boolean = false;
  /** The last drawn frame's vsync time (s); 0 before the first. */
  private last: number = 0;
  /** Frame statistics for the log (a large running ring only): frames, late frames, time spent drawing. */
  private statFrames: number = 0;
  private statLate: number = 0;
  private statDrawMs: number = 0;
  private statFrom: number = 0;
  private time: number = 0;
  private age: number = 0;

  aboutToAppear(): void {
    if (this.still || this.reduced) {
      // A representative frame: the mode's mix settled, the voice at a middling level.
      for (let i = 0; i < 90; i++) { this.voice.step(1 / 60, this.mode, 0.45 + 0.25 * Math.sin(i * 0.37)); }
      this.time = 1.6;
      this.age = 10;
      return;
    }
    this.run();
  }

  aboutToDisappear(): void { this.clock.stop(); }

  private run(): void {
    this.last = 0;
    this.clock.start((time: number): void => { this.frame(time); }, this.maxFps);
  }

  /** 减少 AI 动效 switched on (or the ring told to rest): it stops on the frame it shows; switched off, it runs on. */
  private onMotionChanged(): void {
    if (this.still || this.reduced) { this.clock.stop(); } else { this.run(); }
  }

  private frame(time: number): void {
    // At rest (the floating orb waiting) 30 frames are plenty.
    const resting: boolean = this.mode === 'idle' && this.voice.think < 0.01 && this.voice.listen < 0.01 &&
      this.voice.speak < 0.01;
    const fps: number = Math.min(this.maxFps, resting ? 30 : 120);
    if (this.last > 0 && time - this.last < 1 / fps - 0.002) { return; }
    // Motion follows the display's own frame times: evenly spaced, so the turning ring never stutters.
    const dt: number = this.last > 0 ? Math.min(0.05, Math.max(0, time - this.last)) : 1 / 60;
    this.last = time;
    const k: number = aiMotionSpeedFactor(this.speed);
    this.time += dt * k;
    this.age += dt;
    this.voice.step(dt * k, this.mode, this.live ? XyLiveLevel.value : this.level);
    const started: number = Date.now();
    this.draw();
    this.stat(time, dt, fps, Date.now() - started);
  }

  /** Every 5 s of a large running ring: how evenly it drew, for the log. */
  private stat(time: number, dt: number, fps: number, drawMs: number): void {
    if (this.ringSize < 40) { return; }
    if (this.statFrom === 0) { this.statFrom = time; }
    this.statFrames++;
    this.statDrawMs += drawMs;
    if (dt > 1.6 / fps) { this.statLate++; }
    if (time - this.statFrom < 5) { return; }
    hilog.info(0x0000, 'AiChat', 'xyRing size=%{public}s mode=%{public}s fps=%{public}s late=%{public}s draw=%{public}s ms',
      Math.round(this.ringSize).toString(), this.mode, (this.statFrames / (time - this.statFrom)).toFixed(1),
      this.statLate.toString(), (this.statDrawMs / Math.max(1, this.statFrames)).toFixed(2));
    this.statFrom = time;
    this.statFrames = 0;
    this.statLate = 0;
    this.statDrawMs = 0;
  }

  private conic(cx: number, cy: number, fn: (a: number) => number[]): CanvasGradient {
    const g: CanvasGradient = this.ctx.createConicGradient(0, cx, cy);
    // A small ring needs fewer stops for the same smoothness.
    const stops: number = this.ringSize < 90 ? 12 : XY_STOPS;
    for (let i = 0; i <= stops; i++) {
      const a: number = i / stops * TAU;
      const v: number[] = fn(a);
      g.addColorStop(i / stops, xyCss([v[0], v[1], v[2]], v[3]));
    }
    return g;
  }

  private setBlur(vp: number): void { this.ctx.filter = 'blur(' + Math.max(0, vp).toFixed(2) + 'vp)'; }

  private trace(points: number[][], cx: number, cy: number, r: number, from: number, to: number): void {
    this.ctx.beginPath();
    this.addTrace(points, cx, cy, r, from, to);
  }

  /** One more piece of the current path. */
  private addTrace(points: number[][], cx: number, cy: number, r: number, from: number, to: number): void {
    const c = this.ctx;
    for (let i = from; i <= to; i++) {
      const p: number[] = points[i];
      if (i === from) { c.moveTo(cx + p[0] * r, cy + p[1] * r); } else { c.lineTo(cx + p[0] * r, cy + p[1] * r); }
    }
  }

  private draw(): void {
    if (!this.ready) { return; }
    const c = this.ctx;
    const w: number = c.width;
    const h: number = c.height;
    if (w <= 0 || h <= 0) { return; }
    c.globalCompositeOperation = 'source-over';
    c.filter = 'none';
    c.clearRect(0, 0, w, h);
    const v: XyVoice = this.voice;
    const t: number = this.time;
    const cx: number = w / 2;
    const cy: number = h / 2;
    const R: number = this.radius > 0 ? this.radius : Math.min(w, h) * (this.ripples ? 0.22 : 0.34);
    const half: number = Math.min(w, h) / 2;
    const think: number = v.think;
    const speak: number = v.speak;
    const listen: number = v.listen;
    const appear: number = this.opensFromBlur ? Math.min(1, this.age / 0.56) : 1;
    c.globalCompositeOperation = 'lighter';

    // The ring's shape: tumbling while thinking (with its motion trail), tilted and soft while it opens.
    // Few, wide copies: the same smear for a fraction of the blur passes.
    const trail: number = think > 0.05 ? XY_TRAIL + 1 : 1;
    const copies: number[][][] = [];
    const tumble: number = Math.max(think, 0.8 * (1 - appear) * (1 - appear));
    for (let j = 0; j < trail; j++) {
      // Just starting to turn, the trail gathers on the ring (no copies from "before" it began).
      copies.push(xyRingPoints(appear < 1 ? 0.35 : Math.max(0, v.thinkTime - j * XY_TRAIL_STEP), tumble,
        j === 0 ? (this.ringSize < 120 ? XY_POINTS_SMALL : XY_POINTS) : XY_TRAIL_POINTS));
    }

    // 1. The glow: the ring lights the glass around it — strongest along the ring, fading out on both sides.
    const amk: number = (0.6 + 0.6 * v.level * (listen + speak) + 0.45 * think) * appear;
    const amR: number = Math.min(half, R * (this.ripples ? 2.3 : 1.95));
    const inner: number = R * 0.45;
    const am: CanvasGradient = c.createRadialGradient(cx, cy, inner, cx, cy, amR);
    const peak: number = Math.max(0.05, Math.min(0.95, (R - inner) / Math.max(1, amR - inner)));
    const glow: number[] = [28, 70, 96];
    am.addColorStop(0, xyCssClear(glow));
    am.addColorStop(peak, xyCss(glow, amk));
    am.addColorStop(Math.min(1, peak + (1 - peak) * 0.45), xyCss(glow, amk * 0.43));
    am.addColorStop(1, xyCssClear(glow));
    c.fillStyle = am;
    c.beginPath(); c.arc(cx, cy, amR, 0, TAU); c.fill();

    // The sphere's light: every other copy is plenty (the trail's reach is the same).
    const reach: XyReach | null = think > 0.02 ?
      new XyReach(copies.filter((_p: number[][], j: number): boolean => j % 2 === 0), t) : null;

    // 2. Ripples: they reflect the ring's light and move with the voice; thinking keeps them where they were.
    if (this.ripples && Math.max(listen, think) > 0.02) {
      xyRipples(v).forEach((rp: XyRipple): void => {
        const ox: number = cx + rp.ox * R;
        const oy: number = cy + rp.oy * R;
        const rr: number = rp.radius * R;
        // A ripple stays a soft band of light even on a small ring.
        const bw: number = Math.max(rp.width * R, 3.5);
        const shine = (a: number): number[] => {
          const color: number[] = reach !== null && think > 0.3 ? reach.colorAt(a) : xyLight(a, t - rp.delay, XY_CYAN, 0.7, 3);
          const lit: number = reach !== null && think > 0.3 ? 0.2 + reach.rippleLightAt(a) : 1;
          return [color[0], color[1], color[2], xyRippleShine(rp, a, t) * lit * appear];
        };
        this.setBlur(Math.max(bw * 0.4, 1.6));
        c.lineWidth = bw;
        c.strokeStyle = this.conic(ox, oy, shine);
        c.beginPath(); c.arc(ox, oy, rr, 0, TAU); c.stroke();
        // the brighter inner lip, facing the light (thin: no blur pass of its own)
        c.filter = 'none';
        c.lineWidth = bw * 0.24;
        c.strokeStyle = this.conic(ox, oy, (a: number): number[] => { const s: number[] = shine(a); return [s[0], s[1], s[2], s[3] * 0.35]; });
        c.beginPath(); c.arc(ox, oy, rr - bw * 0.3, 0, TAU); c.stroke();
      });
    }

    // 3. Thinking: the still sphere the spinning ring sweeps out — a faint haze and a soft rim, lit where it passes.
    if (reach !== null) {
      const hz: CanvasGradient = c.createRadialGradient(cx, cy, 0, cx, cy, R * 1.04);
      hz.addColorStop(0, xyCss([0, 4, 4], think));
      hz.addColorStop(0.85, xyCss([0, 9, 8], think));
      hz.addColorStop(1, xyCssClear([0, 9, 8]));
      c.filter = 'none';
      c.fillStyle = hz;
      c.beginPath(); c.arc(cx, cy, R * 1.04, 0, TAU); c.fill();
      const lit: XyReach = reach;
      this.setBlur(Math.max(R * 0.035, 1.5));
      c.lineWidth = Math.max(R * 0.06, 2.2);
      c.strokeStyle = this.conic(cx, cy, (a: number): number[] => {
        const color: number[] = lit.colorAt(a);
        return [color[0], color[1], color[2], think * (0.3 + 0.6 * lit.lightAt(a))];
      });
      c.beginPath(); c.arc(cx, cy, R * 0.99, 0, TAU); c.stroke();
    }

    // 4. Speaking: the ring's light refracted into a displaced, wide band that swells with the voice read out.
    if (speak > 0.02) {
      const ls: number = v.levelAgo(0.04);
      const dir: number = v.dirAgo(0.04) * 0.4 + 3.9;
      const off: number = R * (0.08 + 0.08 * ls);
      const bx: number = cx + Math.cos(dir) * off;
      const by: number = cy + Math.sin(dir) * off;
      this.setBlur(R * 0.09);
      c.lineWidth = R * (0.3 + 0.12 * ls);
      c.strokeStyle = this.conic(bx, by, (a: number): number[] => {
        const color: number[] = xyLight(a, t, XY_CYAN, 0.35, 3.2);
        return [color[0], color[1], color[2], 1.15 * speak];
      });
      c.beginPath(); c.arc(bx, by, R * 1.04, 0, TAU); c.stroke();
      this.setBlur(R * 0.035);
      c.lineWidth = R * (0.1 + 0.08 * ls);
      c.strokeStyle = this.conic(bx, by, (a: number): number[] => {
        const color: number[] = xyLight(a, t, XY_CYAN, 0.45, 2.4);
        return [color[0], color[1], color[2], 0.35 * speak];
      });
      c.beginPath(); c.arc(bx, by, R * 1.02, 0, TAU); c.stroke();
    }

    // 5. The tumbling ring's motion trail: colored, soft, it makes the spinning sphere — a dense smear in two soft
    // passes (near the ring brighter, further back fainter), not a few separate copies.
    if (think > 0.05) {
      const mid: number = Math.floor(copies.length / 2);
      const smear = (from: number, to: number, alpha: number, blur: number, width: number): void => {
        this.setBlur(blur);
        c.lineWidth = width;
        c.strokeStyle = this.conic(cx, cy, (a: number): number[] => {
          const color: number[] = xyLight(a, t, XY_CYAN, 0.2, 2);
          return [color[0], color[1], color[2], alpha];
        });
        c.beginPath();
        for (let j = from; j < to; j++) { this.addTrace(copies[j], cx, cy, R, 0, copies[j].length - 1); }
        c.stroke();
      };
      smear(1, mid + 1, 0.5 * think, Math.max(R * 0.05, 2), Math.max(R * 0.11, 2.6));
      smear(mid + 1, copies.length, 0.3 * think, Math.max(R * 0.09, 3), Math.max(R * 0.15, 3.2));
    }

    // 6. The ring: a colored bloom, then a thin core whose brightness and tint follow the flowing glows.
    const ring: number[][] = copies[0];
    this.setBlur(Math.max(R * 0.05, 2.2) + R * 0.15 * (1 - appear));
    c.lineWidth = Math.max(R * (0.12 + 0.05 * v.level), 3);
    c.strokeStyle = this.conic(cx, cy, (a: number): number[] => {
      const color: number[] = xyLight(a, t, XY_CYAN, 0.6, 2);
      return [color[0], color[1], color[2], 0.75 * (1 - 0.3 * think) * (1 - 0.5 * speak) * appear];
    });
    this.trace(ring, cx, cy, R, 0, ring.length - 1);
    c.stroke();
    // The crisp core: no blur pass, except while it opens out of the blur.
    if (appear < 1) { this.setBlur(R * 0.12 * (1 - appear)); } else { c.filter = 'none'; }
    c.lineWidth = Math.max(1.2, R * 0.03);
    // The core glows (a shadow glow: soft light right around the line, at any size).
    c.shadowColor = 'rgba(150,212,255,0.85)';
    c.shadowBlur = Math.max(R * 0.1, 4);
    if (think > 0.05) {
      // Spinning, only the half facing us is crisp.
      const frontAlpha: number = (this.ripples ? 0.45 : 0.65) * think;
      c.strokeStyle = this.conic(cx, cy, (a: number): number[] => {
        const color: number[] = xyLight(a, t, XY_WHITE, 0.4, 2);
        return [color[0], color[1], color[2], frontAlpha];
      });
      // All the front arcs in one stroke (one glow pass).
      let start: number = -1;
      c.beginPath();
      const last: number = ring.length - 1;
      for (let i = 0; i <= last; i++) {
        const front: boolean = ring[i][2] > 0.35 && i < last;
        if (front && start < 0) { start = i; }
        if (!front && start >= 0) {
          if (i - start > 1) { this.addTrace(ring, cx, cy, R, start, i); }
          start = -1;
        }
      }
      c.stroke();
      // The flat part of the ring still easing out of thinking.
      if (think < 0.6) {
        c.strokeStyle = this.conic(cx, cy, (a: number): number[] => {
          const color: number[] = xyLight(a, t, XY_WHITE, 0.35, 2.6);
          return [color[0], color[1], color[2], (0.6 - think) / 0.6];
        });
        this.trace(ring, cx, cy, R, 0, ring.length - 1);
        c.stroke();
      }
    } else {
      c.strokeStyle = this.conic(cx, cy, (a: number): number[] => {
        const color: number[] = xyLight(a, t, XY_WHITE, 0.35, 2.6);
        return [color[0], color[1], color[2], (0.95 + 0.004 * (color[0] + color[1] - 120)) * appear];
      });
      this.trace(ring, cx, cy, R, 0, ring.length - 1);
      c.stroke();
    }
    c.shadowBlur = 0;
    c.filter = 'none';
    c.globalCompositeOperation = 'source-over';
  }

  build() {
    Canvas(this.ctx)
      .width(this.ringSize).height(this.ringSize)
      // Light, not paint: added onto the glass behind it.
      .blendMode(BlendMode.PLUS, BlendApplyType.OFFSCREEN)
      .hitTestBehavior(HitTestMode.None)
      .onReady((): void => { this.ready = true; this.draw(); })
  }
}
