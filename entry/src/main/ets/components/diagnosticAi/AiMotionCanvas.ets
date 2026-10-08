import { displaySync } from '@kit.ArkGraphics2D';
import { AI_MOTION_REDUCED, AI_MOTION_SPEED, aiMotionSpeedFactor } from '../../services/diagnosticAi/DiagnosticAiMotionPolicy';

/**
 * Canvas motions of AI 动效. Note on drawing: ArkUI's canvas applies the transform current at fill/stroke time, so
 * shapes here are placed with explicit coordinates (and ellipse()) instead of translate/rotate/scale around a path.
 */

/**
 * A vsync frame clock (timer fallback) that calls `tick` until stopped, with the frame's own time in seconds (the
 * display's vsync, evenly spaced — not when the callback happened to run), at up to `maxRate` frames a second.
 */
export class AiFrameClock {
  private sync: displaySync.DisplaySync | null = null;
  private timer: number = -1;

  start(tick: (time: number) => void, maxRate: number = 60): void {
    if (this.sync !== null || this.timer !== -1) { return; }
    try {
      const sync: displaySync.DisplaySync = displaySync.create();
      const rate: number = Math.max(30, Math.min(120, maxRate));
      sync.setExpectedFrameRateRange({ min: 30, max: rate, expected: rate });
      sync.on('frame', (info: displaySync.IntervalInfo): void => { tick(info.timestamp / 1e9); });
      sync.start();
      this.sync = sync;
    } catch (_error) {
      this.timer = setInterval((): void => { tick(Date.now() / 1000); }, 16);
    }
  }

  stop(): void {
    if (this.sync !== null) {
      try { this.sync.stop(); this.sync.off('frame'); } catch (_error) { /* already stopped */ }
      this.sync = null;
    }
    if (this.timer !== -1) { clearInterval(this.timer); this.timer = -1; }
  }
}

const AI_RGB: number[][] = [[66, 203, 247], [42, 125, 255], [164, 121, 255], [255, 103, 140], [255, 170, 80]];

function rgba(c: number[], a: number): string {
  return 'rgba(' + c[0].toString() + ',' + c[1].toString() + ',' + c[2].toString() + ',' + a.toFixed(3) + ')';
}

function mix(a: number[], b: number[], t: number): number[] {
  return [Math.round(a[0] + (b[0] - a[0]) * t), Math.round(a[1] + (b[1] - a[1]) * t), Math.round(a[2] + (b[2] - a[2]) * t)];
}

/** AI colors around a loop, u in 0…1. */
function loopColor(u: number): number[] {
  const x: number = ((u % 1) + 1) % 1 * AI_RGB.length;
  const i: number = Math.floor(x);
  return mix(AI_RGB[i], AI_RGB[(i + 1) % AI_RGB.length], x - i);
}

function ease(x: number): number { return 1 - Math.pow(1 - Math.min(1, Math.max(0, x)), 3); }

/**
 * 圆片环: white discs on a ring seen in space, like a carousel. The whole ring turns (its tilt swaying slowly);
 * nearer discs are larger and brighter, farther ones smaller and dimmer, so size changes gradually round the ring;
 * all discs turn about their own axis together, like coins, with a soft highlight.
 */
@Component
export struct AiCoinDiscRing {
  @Prop ringSize: number = 34;
  @StorageProp(AI_MOTION_SPEED) speed: string = 'normal';
  @StorageProp(AI_MOTION_REDUCED) reduced: boolean = false;
  /** One still frame, no clock (settings tiles that are not selected). */
  @Prop still: boolean = false;
  private readonly settings: RenderingContextSettings = new RenderingContextSettings(true);
  private readonly ctx: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.settings);
  private readonly clock: AiFrameClock = new AiFrameClock();
  private readonly born: number = Date.now();
  private ready: boolean = false;

  aboutToAppear(): void { if (!this.reduced && !this.still) { this.clock.start((): void => { this.draw(); }); } }
  aboutToDisappear(): void { this.clock.stop(); }

  private draw(): void {
    if (!this.ready) { return; }
    const w: number = this.ctx.width;
    const h: number = this.ctx.height;
    if (w <= 0 || h <= 0) { return; }
    const t: number = (Date.now() - this.born) / 1000 * aiMotionSpeedFactor(this.speed);
    const c = this.ctx;
    c.clearRect(0, 0, w, h);
    const n: number = 10;
    const ring: number = w * 0.36;
    const largest: number = w * 0.1;
    const turn: number = t * Math.PI * 2 / 2.8;
    // The ring is tilted towards the viewer and its tilt sways slowly, so it reads as a carousel in space.
    const tilt: number = 0.42 + 0.14 * Math.sin(t * Math.PI * 2 / 5.5);
    const roll: number = 0.18 * Math.sin(t * Math.PI * 2 / 7);
    // One shared self-spin for all discs (a coin turning), never fully edge-on.
    const spin: number = t * Math.PI * 2 / 1.5;
    const order: number[][] = [];
    for (let i: number = 0; i < n; i++) {
      const a: number = turn + i * Math.PI * 2 / n;
      const depth: number = (Math.sin(a) + 1) / 2;   // 0 far … 1 near
      order.push([depth, a]);
    }
    order.sort((p: number[], q: number[]): number => p[0] - q[0]);   // far discs first
    order.forEach((item: number[]): void => {
      const depth: number = item[0];
      const a: number = item[1];
      const px: number = Math.cos(a) * ring;
      const py: number = Math.sin(a) * ring * tilt;
      const x: number = w / 2 + px * Math.cos(roll) - py * Math.sin(roll);
      const y: number = h / 2 + px * Math.sin(roll) + py * Math.cos(roll);
      const size: number = largest * (0.5 + 0.5 * depth);   // nearer discs larger: a gradual size change round the ring
      const face: number = Math.cos(spin + a * 0.5);
      const width: number = size * (0.3 + 0.7 * Math.abs(face));
      const g: CanvasGradient = c.createRadialGradient(x - width * 0.35, y - size * 0.35, 0, x, y, size * 1.1);
      g.addColorStop(0, 'rgba(255,255,255,1)');
      g.addColorStop(0.55, face >= 0 ? 'rgba(238,242,255,1)' : 'rgba(205,212,228,1)');
      g.addColorStop(1, 'rgba(170,180,205,1)');
      c.globalAlpha = 0.35 + 0.65 * depth;
      c.fillStyle = g;
      c.shadowColor = 'rgba(255,255,255,0.75)';
      c.shadowBlur = w * 0.05 * depth;
      c.beginPath();
      c.ellipse(x, y, width, size, a + Math.PI / 2 + roll, 0, Math.PI * 2);
      c.fill();
    });
    c.globalAlpha = 1;
    c.shadowBlur = 0;
  }

  build() {
    Canvas(this.ctx).width(this.ringSize).height(this.ringSize)
      .onReady((): void => { this.ready = true; this.draw(); })
  }
}

/** 极光环: a ring of the AI colors flowing round, with a soft glow and a slow breath. */
@Component
export struct AiAuroraRing {
  @Prop ringSize: number = 34;
  @StorageProp(AI_MOTION_SPEED) speed: string = 'normal';
  @StorageProp(AI_MOTION_REDUCED) reduced: boolean = false;
  /** One still frame, no clock (settings tiles that are not selected). */
  @Prop still: boolean = false;
  private readonly settings: RenderingContextSettings = new RenderingContextSettings(true);
  private readonly ctx: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.settings);
  private readonly clock: AiFrameClock = new AiFrameClock();
  private readonly born: number = Date.now();
  private ready: boolean = false;

  aboutToAppear(): void { if (!this.reduced && !this.still) { this.clock.start((): void => { this.draw(); }); } }
  aboutToDisappear(): void { this.clock.stop(); }

  private draw(): void {
    if (!this.ready) { return; }
    const w: number = this.ctx.width;
    const h: number = this.ctx.height;
    if (w <= 0 || h <= 0) { return; }
    const t: number = (Date.now() - this.born) / 1000 * aiMotionSpeedFactor(this.speed);
    const c = this.ctx;
    c.clearRect(0, 0, w, h);
    const breath: number = 0.5 + 0.5 * Math.sin(t * Math.PI * 2 / 2.4);
    const r: number = w * (0.3 + 0.02 * breath);
    const g: CanvasGradient = c.createConicGradient(t * Math.PI * 2 / 2.2, w / 2, h / 2);
    for (let k: number = 0; k <= 10; k++) { g.addColorStop(k / 10, rgba(loopColor(k / 10), 1)); }
    c.globalCompositeOperation = 'lighter';
    // Wide soft glow, then the bright ring.
    c.strokeStyle = g;
    c.globalAlpha = 0.35 + 0.2 * breath;
    c.lineWidth = w * 0.16;
    c.shadowColor = 'rgba(164,121,255,0.9)';
    c.shadowBlur = w * 0.25;
    c.beginPath(); c.arc(w / 2, h / 2, r, 0, Math.PI * 2); c.stroke();
    c.globalAlpha = 1;
    c.lineWidth = w * 0.05;
    c.shadowBlur = w * 0.08;
    c.beginPath(); c.arc(w / 2, h / 2, r, 0, Math.PI * 2); c.stroke();
    c.shadowBlur = 0;
    c.globalCompositeOperation = 'source-over';
  }

  build() {
    Canvas(this.ctx).width(this.ringSize).height(this.ringSize)
      .onReady((): void => { this.ready = true; this.draw(); })
  }
}

/** 彗星轨道: three glowing points on tilted orbits, each trailing a fading tail. */
@Component
export struct AiCometOrbit {
  @Prop ringSize: number = 34;
  @StorageProp(AI_MOTION_SPEED) speed: string = 'normal';
  @StorageProp(AI_MOTION_REDUCED) reduced: boolean = false;
  /** One still frame, no clock (settings tiles that are not selected). */
  @Prop still: boolean = false;
  private readonly settings: RenderingContextSettings = new RenderingContextSettings(true);
  private readonly ctx: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.settings);
  private readonly clock: AiFrameClock = new AiFrameClock();
  private readonly born: number = Date.now();
  private ready: boolean = false;

  aboutToAppear(): void { if (!this.reduced && !this.still) { this.clock.start((): void => { this.draw(); }); } }
  aboutToDisappear(): void { this.clock.stop(); }

  private point(t: number, k: number, w: number, h: number): number[] {
    const period: number = [1.3, 1.7, 2.2][k];
    const tilt: number = [0, Math.PI / 3, -Math.PI / 3][k];
    const a: number = t * Math.PI * 2 / period + k * 2.1;
    // An ellipse (radius rx, ry) rotated by `tilt` about the center.
    const ex: number = Math.cos(a) * w * 0.36;
    const ey: number = Math.sin(a) * w * 0.15;
    return [w / 2 + ex * Math.cos(tilt) - ey * Math.sin(tilt), h / 2 + ex * Math.sin(tilt) + ey * Math.cos(tilt)];
  }

  private draw(): void {
    if (!this.ready) { return; }
    const w: number = this.ctx.width;
    const h: number = this.ctx.height;
    if (w <= 0 || h <= 0) { return; }
    const t: number = (Date.now() - this.born) / 1000 * aiMotionSpeedFactor(this.speed);
    const c = this.ctx;
    c.clearRect(0, 0, w, h);
    c.globalCompositeOperation = 'lighter';
    const colors: number[][] = [[66, 203, 247], [164, 121, 255], [255, 103, 140]];
    for (let k: number = 0; k < 3; k++) {
      // The tail: earlier positions, smaller and fainter.
      for (let s: number = 10; s >= 0; s--) {
        const p: number[] = this.point(t - s * 0.022, k, w, h);
        const fade: number = 1 - s / 11;
        c.fillStyle = rgba(s === 0 ? [255, 255, 255] : colors[k], s === 0 ? 1 : 0.55 * fade);
        c.shadowColor = rgba(colors[k], 0.9);
        c.shadowBlur = s === 0 ? w * 0.18 : 0;
        c.beginPath(); c.arc(p[0], p[1], w * (s === 0 ? 0.055 : 0.04 * fade), 0, Math.PI * 2); c.fill();
      }
    }
    c.shadowBlur = 0;
    c.globalCompositeOperation = 'source-over';
  }

  build() {
    Canvas(this.ctx).width(this.ringSize).height(this.ringSize)
      .onReady((): void => { this.ready = true; this.draw(); })
  }
}

/** 极光球: a dark glass sphere with soft color glows slowly circling inside it. */
@Component
export struct AiAuroraOrb {
  @Prop orbSize: number = 48;
  @Prop active: boolean = false;
  @StorageProp(AI_MOTION_SPEED) speed: string = 'normal';
  @StorageProp(AI_MOTION_REDUCED) reduced: boolean = false;
  /** One still frame, no clock (settings tiles that are not selected). */
  @Prop still: boolean = false;
  private readonly settings: RenderingContextSettings = new RenderingContextSettings(true);
  private readonly ctx: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.settings);
  private readonly clock: AiFrameClock = new AiFrameClock();
  private readonly born: number = Date.now();
  private ready: boolean = false;

  aboutToAppear(): void { if (!this.reduced && !this.still) { this.clock.start((): void => { this.draw(); }); } }
  aboutToDisappear(): void { this.clock.stop(); }

  private draw(): void {
    if (!this.ready) { return; }
    const w: number = this.ctx.width;
    const h: number = this.ctx.height;
    if (w <= 0 || h <= 0) { return; }
    const t: number = (Date.now() - this.born) / 1000 * aiMotionSpeedFactor(this.speed) * (this.active ? 1.6 : 1);
    const c = this.ctx;
    const r: number = w / 2 - 0.8;
    c.clearRect(0, 0, w, h);
    const body: CanvasGradient = c.createRadialGradient(w / 2, h * 0.42, r * 0.1, w / 2, h / 2, r);
    body.addColorStop(0, 'rgba(16,16,24,1)'); body.addColorStop(0.75, 'rgba(6,6,10,1)'); body.addColorStop(1, 'rgba(24,28,40,1)');
    c.fillStyle = body;
    c.beginPath(); c.arc(w / 2, h / 2, r, 0, Math.PI * 2); c.fill();
    c.globalCompositeOperation = 'lighter';
    const glows: number[][] = [[164, 121, 255], [42, 125, 255], [255, 103, 140], [66, 220, 200]];
    for (let k: number = 0; k < glows.length; k++) {
      const a: number = t * Math.PI * 2 / [5.5, 7, 6.2, 8][k] + k * Math.PI / 2;
      const d: number = r * (0.28 + 0.12 * Math.sin(t * 0.9 + k));
      const x: number = w / 2 + Math.cos(a) * d;
      const y: number = h / 2 + Math.sin(a) * d * 0.8;
      const g: CanvasGradient = c.createRadialGradient(x, y, 0, x, y, r * 0.62);
      g.addColorStop(0, rgba(glows[k], this.active ? 0.7 : 0.5));
      g.addColorStop(1, rgba(glows[k], 0));
      c.fillStyle = g;
      c.beginPath(); c.arc(w / 2, h / 2, r - 1, 0, Math.PI * 2); c.fill();
    }
    c.globalCompositeOperation = 'source-over';
    const rim: CanvasGradient = c.createLinearGradient(0, 0, 0, h);
    rim.addColorStop(0, 'rgba(255,255,255,0.25)'); rim.addColorStop(1, 'rgba(255,255,255,0.55)');
    c.strokeStyle = rim; c.lineWidth = Math.max(0.8, w * 0.022);
    c.beginPath(); c.arc(w / 2, h / 2, r, 0, Math.PI * 2); c.stroke();
    const shine: CanvasGradient = c.createRadialGradient(w / 2, h * 0.1, 0, w / 2, h * 0.1, r * 0.75);
    shine.addColorStop(0, 'rgba(255,255,255,0.22)'); shine.addColorStop(1, 'rgba(255,255,255,0)');
    c.fillStyle = shine;
    c.beginPath(); c.arc(w / 2, h / 2, r, 0, Math.PI * 2); c.fill();
  }

  build() {
    Canvas(this.ctx).width(this.orbSize).height(this.orbSize)
      .onReady((): void => { this.ready = true; this.draw(); })
  }
}

/** Shared drawing of a check from (ax,ay) to (bx,by) to (ex,ey), drawn up to `p` (0…1) of its length. */
function drawCheck(c: CanvasRenderingContext2D, w: number, h: number, p: number): void {
  if (p <= 0) { return; }
  const ax: number = w * 0.32; const ay: number = h * 0.52;
  const bx: number = w * 0.45; const by: number = h * 0.65;
  const ex: number = w * 0.69; const ey: number = h * 0.38;
  const first: number = Math.hypot(bx - ax, by - ay);
  const second: number = Math.hypot(ex - bx, ey - by);
  const drawn: number = (first + second) * p;
  c.beginPath(); c.moveTo(ax, ay);
  if (drawn <= first) {
    c.lineTo(ax + (bx - ax) * drawn / first, ay + (by - ay) * drawn / first);
  } else {
    c.lineTo(bx, by);
    const rest: number = (drawn - first) / second;
    c.lineTo(bx + (ex - bx) * rest, by + (ey - by) * rest);
  }
  c.stroke();
}

/** A one-shot canvas animation of `duration` seconds; `paint(t)` draws the frame at t. */
@Component
struct AiOneShotCanvas {
  @Prop markSize: number = 34;
  @Prop kind: string = 'ripple';
  @Prop still: boolean = false;
  private readonly settings: RenderingContextSettings = new RenderingContextSettings(true);
  private readonly ctx: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.settings);
  private readonly clock: AiFrameClock = new AiFrameClock();
  private startedAt: number = 0;
  private ready: boolean = false;

  aboutToAppear(): void {
    // Still: show the finished mark at once.
    this.startedAt = this.still ? Date.now() - 10000 : Date.now();
    if (!this.still) { this.clock.start((): void => { this.draw(); }); }
  }
  aboutToDisappear(): void { this.clock.stop(); }

  private draw(): void {
    if (!this.ready) { return; }
    const w: number = this.ctx.width;
    const h: number = this.ctx.height;
    if (w <= 0 || h <= 0) { return; }
    const t: number = (Date.now() - this.startedAt) / 1000;
    const c = this.ctx;
    c.clearRect(0, 0, w, h);
    c.lineCap = 'round'; c.lineJoin = 'round';
    if (this.kind === 'island') { this.island(c, w, h, t); }
    else if (this.kind === 'sparkle') { this.sparkle(c, w, h, t); }
    else { this.ripple(c, w, h, t); }
    if (t > 1.4) { this.clock.stop(); }
  }

  /** 涟漪扩散: a green disc pops in with the check, two glowing rings spread out and fade. */
  private ripple(c: CanvasRenderingContext2D, w: number, h: number, t: number): void {
    for (let k: number = 0; k < 2; k++) {
      const p: number = ease((t - 0.25 - k * 0.18) / 0.9);
      if (p > 0 && p < 1) {
        c.strokeStyle = 'rgba(52,199,89,' + (0.8 * (1 - p)).toFixed(3) + ')';
        c.lineWidth = w * 0.04;
        c.beginPath(); c.arc(w / 2, h / 2, w * (0.3 + 0.2 * p), 0, Math.PI * 2); c.stroke();
      }
    }
    const pop: number = ease(t / 0.3);
    c.fillStyle = 'rgba(52,199,89,1)';
    c.shadowColor = 'rgba(52,199,89,0.8)'; c.shadowBlur = w * 0.15;
    c.beginPath(); c.arc(w / 2, h / 2, w * 0.3 * (0.6 + 0.4 * pop), 0, Math.PI * 2); c.fill();
    c.shadowBlur = 0;
    c.strokeStyle = '#FFFFFF'; c.lineWidth = w * 0.075;
    drawCheck(c, w, h, ease((t - 0.15) / 0.35));
  }

  /** 粒子绽放: the check draws while small sparks burst outward in the AI colors and fade. */
  private sparkle(c: CanvasRenderingContext2D, w: number, h: number, t: number): void {
    c.globalCompositeOperation = 'lighter';
    for (let k: number = 0; k < 12; k++) {
      const a: number = k * Math.PI * 2 / 12 + 0.3;
      const p: number = ease((t - 0.3) / 0.8);
      if (p > 0 && p < 1) {
        const d: number = w * (0.26 + 0.24 * p);
        c.fillStyle = rgba(loopColor(k / 12), 1 - p);
        c.shadowColor = rgba(loopColor(k / 12), 1); c.shadowBlur = w * 0.1;
        c.beginPath(); c.arc(w / 2 + Math.cos(a) * d, h / 2 + Math.sin(a) * d, w * 0.035 * (1 - p * 0.5), 0, Math.PI * 2);
        c.fill();
      }
    }
    c.shadowBlur = 0;
    c.globalCompositeOperation = 'source-over';
    c.strokeStyle = 'rgba(255,255,255,0.9)'; c.lineWidth = w * 0.05;
    c.beginPath(); c.arc(w / 2, h / 2, w * 0.3, -Math.PI / 2, -Math.PI / 2 + Math.PI * 2 * ease(t / 0.4)); c.stroke();
    c.lineWidth = w * 0.075;
    drawCheck(c, w, h, ease((t - 0.3) / 0.35));
  }

  /**
   * 灵动岛光环: green rings tumble in 3D (ellipses whose short axis and tilt keep turning, with a fading trail),
   * close up into one circle, and the check draws inside it.
   */
  private island(c: CanvasRenderingContext2D, w: number, h: number, t: number): void {
    const cx: number = w / 2;
    const cy: number = h / 2;
    const r: number = w * 0.36;
    c.lineWidth = Math.max(1.4, w * 0.04);
    c.shadowColor = 'rgba(142,232,155,0.8)';
    c.shadowBlur = w * 0.08;
    const close: number = ease((t - 0.42) / 0.24);   // rings tumble 0–0.42 s, close by 0.66 s
    if (close < 1) {
      for (let i: number = 0; i < 3; i++) {
        for (let k: number = 3; k >= 0; k--) {
          const tk: number = Math.max(0, t - k * 0.03);
          // A little over half a turn in all, slowing down as the rings close: they settle, not spin.
          const turn: number = ease(Math.min(1, tk / 0.66));
          const spin: number = turn * Math.PI * 1.15 + i * Math.PI / 3;
          const squash: number = Math.abs(Math.cos(spin)) * (1 - close) + close;
          const tilt: number = (i * 60 + turn * 45) * Math.PI / 180 * (1 - close);
          c.strokeStyle = 'rgba(142,232,155,' + ((k === 0 ? 0.95 : 0.25 / k) * (1 - close * 0.6)).toFixed(3) + ')';
          c.beginPath(); c.ellipse(cx, cy, r, Math.max(r * 0.04, r * squash), tilt, 0, Math.PI * 2); c.stroke();
        }
      }
    }
    if (close > 0) {
      c.strokeStyle = 'rgba(142,232,155,' + close.toFixed(3) + ')';
      c.beginPath(); c.arc(cx, cy, r, 0, Math.PI * 2); c.stroke();
    }
    c.strokeStyle = 'rgba(142,232,155,1)';
    drawCheck(c, w, h, ease((t - 0.6) / 0.3));   // the check draws 0.6–0.9 s
    c.shadowBlur = 0;
  }

  build() {
    Canvas(this.ctx).width(this.markSize).height(this.markSize)
      .onReady((): void => { this.ready = true; this.draw(); })
  }
}

/** 灵动岛光环 (plays once). */
@Component
export struct AiIslandRingsCheck {
  @Prop markSize: number = 64;

  @Prop still: boolean = false;

  build() { AiOneShotCanvas({ markSize: this.markSize, kind: 'island', still: this.still }) }
}

/** 涟漪扩散 (plays once). */
@Component
export struct AiRippleCheck {
  @Prop markSize: number = 30;

  @Prop still: boolean = false;

  build() { AiOneShotCanvas({ markSize: this.markSize, kind: 'ripple', still: this.still }) }
}

/** 粒子绽放 (plays once). */
@Component
export struct AiSparkleCheck {
  @Prop markSize: number = 30;

  @Prop still: boolean = false;

  build() { AiOneShotCanvas({ markSize: this.markSize, kind: 'sparkle', still: this.still }) }
}

/** Colors of the 智能光环, from the reference's glow layers (lavender, magenta, blue, violet, red, orange). */
const AI_HALO_STOPS: string[] = ['#BC82F3', '#FF00D3', '#0099FF', '#7700FF', '#FF6777', '#FF8300', '#BC82F3'];

/**
 * 智能光环: a loop of light tumbling in 3D (an ellipse whose tilt and depth keep changing over ~4.2 s), stroked
 * with the multicolor gradient over several glow layers from wide and faint to narrow and bright, with a pale
 * pastel core line along it.
 */
@Component
export struct AiHaloRing {
  @Prop ringSize: number = 34;
  /** A dark lens behind the ring, for a floating orb over bright pages. */
  @Prop backdrop: boolean = false;
  @Prop active: boolean = false;
  @StorageProp(AI_MOTION_SPEED) speed: string = 'normal';
  @StorageProp(AI_MOTION_REDUCED) reduced: boolean = false;
  /** One still frame, no clock (settings tiles that are not selected). */
  @Prop still: boolean = false;
  private readonly settings: RenderingContextSettings = new RenderingContextSettings(true);
  private readonly ctx: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.settings);
  private readonly clock: AiFrameClock = new AiFrameClock();
  private readonly born: number = Date.now();
  private ready: boolean = false;

  aboutToAppear(): void { if (!this.reduced && !this.still) { this.clock.start((): void => { this.draw(); }); } }
  aboutToDisappear(): void { this.clock.stop(); }

  private draw(): void {
    if (!this.ready) { return; }
    const w: number = this.ctx.width;
    const h: number = this.ctx.height;
    if (w <= 0 || h <= 0) { return; }
    const t: number = (this.reduced ? 1 : (Date.now() - this.born) / 1000) * aiMotionSpeedFactor(this.speed) *
      (this.active ? 1.4 : 1);
    const c = this.ctx;
    c.clearRect(0, 0, w, h);
    if (this.backdrop) {
      const lens: CanvasGradient = c.createRadialGradient(w / 2, h * 0.45, 0, w / 2, h / 2, w / 2);
      lens.addColorStop(0, 'rgba(20,18,30,0.92)'); lens.addColorStop(1, 'rgba(8,8,12,0.92)');
      c.fillStyle = lens;
      c.beginPath(); c.arc(w / 2, h / 2, w / 2 - 0.5, 0, Math.PI * 2); c.fill();
    }
    const phase: number = t * Math.PI * 2 / 4.2;
    const r: number = w * (this.backdrop ? 0.3 : 0.34);
    // Tumbling: the ring's apparent depth (short axis) and tilt drift, never quite flat.
    const ry: number = r * (0.42 + 0.5 * (0.5 + 0.5 * Math.cos(phase)));
    const rx: number = r * (0.92 + 0.08 * Math.sin(phase * 2));
    const tilt: number = -0.5 + 0.7 * Math.sin(phase * 0.5);
    const g: CanvasGradient = c.createConicGradient(phase * 0.8, w / 2, h / 2);
    AI_HALO_STOPS.forEach((col: string, i: number): void => { g.addColorStop(i / (AI_HALO_STOPS.length - 1), col); });
    c.globalCompositeOperation = 'lighter';
    const glows: number[][] = [[0.3, 0.2, 0.3], [0.18, 0.12, 0.45], [0.09, 0.06, 0.8]];  // [width, blur, alpha]
    glows.forEach((gl: number[]): void => {
      c.strokeStyle = g;
      c.globalAlpha = gl[2];
      c.lineWidth = w * gl[0];
      c.shadowColor = 'rgba(188,130,243,0.9)';
      c.shadowBlur = w * gl[1];
      c.beginPath(); c.ellipse(w / 2, h / 2, rx, ry, tilt, 0, Math.PI * 2); c.stroke();
    });
    // The pale core along the ring.
    const core: CanvasGradient = c.createConicGradient(phase * 0.8 + 1, w / 2, h / 2);
    core.addColorStop(0, '#FFFFFF'); core.addColorStop(0.36, '#FFE8D7'); core.addColorStop(0.7, '#CAEAFF');
    core.addColorStop(1, '#FFFFFF');
    c.strokeStyle = core;
    c.globalAlpha = 0.9;
    c.lineWidth = Math.max(0.8, w * 0.03);
    c.shadowBlur = w * 0.04;
    c.beginPath(); c.ellipse(w / 2, h / 2, rx, ry, tilt, 0, Math.PI * 2); c.stroke();
    c.globalAlpha = 1;
    c.shadowBlur = 0;
    c.globalCompositeOperation = 'source-over';
    if (this.backdrop) {
      c.strokeStyle = 'rgba(255,255,255,0.35)';
      c.lineWidth = Math.max(0.8, w * 0.02);
      c.beginPath(); c.arc(w / 2, h / 2, w / 2 - 0.8, 0, Math.PI * 2); c.stroke();
    }
  }

  build() {
    Canvas(this.ctx).width(this.ringSize).height(this.ringSize)
      .onReady((): void => { this.ready = true; this.draw(); })
  }
}

/** Strand colors of 彩丝声波, from the reference (magenta, red, purple, violet, indigo, blue). */
const AI_STRAND_RGB: number[][] = [[222, 62, 192], [220, 79, 79], [117, 20, 178], [121, 31, 236], [76, 64, 255], [44, 134, 255]];

/**
 * 彩丝声波: a voice line of many fine colored strands, each swinging on its own frequency and phase within an
 * envelope that pinches to a point at both ends; about one breath of the line every 1.1 s.
 */
@Component
export struct AiVoiceStrands {
  @Prop ringSize: number = 34;
  @StorageProp(AI_MOTION_SPEED) speed: string = 'normal';
  @StorageProp(AI_MOTION_REDUCED) reduced: boolean = false;
  /** One still frame, no clock (settings tiles that are not selected). */
  @Prop still: boolean = false;
  private readonly settings: RenderingContextSettings = new RenderingContextSettings(true);
  private readonly ctx: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.settings);
  private readonly clock: AiFrameClock = new AiFrameClock();
  private readonly born: number = Date.now();
  private ready: boolean = false;

  aboutToAppear(): void { if (!this.reduced && !this.still) { this.clock.start((): void => { this.draw(); }); } }
  aboutToDisappear(): void { this.clock.stop(); }

  private draw(): void {
    if (!this.ready) { return; }
    const w: number = this.ctx.width;
    const h: number = this.ctx.height;
    if (w <= 0 || h <= 0) { return; }
    const t: number = (Date.now() - this.born) / 1000 * aiMotionSpeedFactor(this.speed);
    const c = this.ctx;
    c.clearRect(0, 0, w, h);
    c.globalCompositeOperation = 'lighter';
    c.lineCap = 'round';
    const breath: number = 0.75 + 0.25 * Math.sin(t * Math.PI * 2 / 1.1);
    for (let k: number = 0; k < 12; k++) {
      const col: number[] = AI_STRAND_RGB[k % AI_STRAND_RGB.length];
      const amp: number = h * (0.12 + 0.18 * ((k * 37) % 10) / 10) * breath;
      const freq: number = 1.2 + (k % 4) * 0.35;
      const speed: number = (k % 2 === 0 ? 1 : -1) * (Math.PI * 2 / 1.1) * (0.7 + (k % 3) * 0.25);
      c.strokeStyle = rgba(col, 0.85);
      c.lineWidth = k % 5 === 0 ? 1.6 : 1;
      c.shadowColor = rgba(col, 0.9);
      c.shadowBlur = w * 0.06;
      c.beginPath();
      for (let i: number = 0; i <= 30; i++) {
        const u: number = i / 30;
        const y: number = h / 2 + Math.sin(u * Math.PI * 2 * freq + t * speed + k * 0.9) * amp * Math.pow(Math.sin(Math.PI * u), 1.5);
        if (i === 0) { c.moveTo(w * u, y); } else { c.lineTo(w * u, y); }
      }
      c.stroke();
    }
    c.shadowBlur = 0;
    c.globalCompositeOperation = 'source-over';
  }

  build() {
    Canvas(this.ctx).width(this.ringSize).height(this.ringSize)
      .onReady((): void => { this.ready = true; this.draw(); })
  }
}
