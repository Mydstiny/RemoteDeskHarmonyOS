/**
 * The 小艺 halo, as light. Measured on a recording of the HarmonyOS assistant's own voice screen:
 *
 * - The ring is the only light source. It gives off colored light — never paint: cyan water raises green and blue
 *   (about +0, +70, +40 on the background) and leaves red alone; the core is a warm white, brightest where its cream
 *   glow passes and pinker, dimmer elsewhere. Four colored glows flow round it at their own speeds.
 * - Listening, ripples stand round it like water. They only reflect the ring's light: at each angle they carry the
 *   ring's color there (a moment ago, the light travels out with the wave) and shine brighter where they come closer
 *   to it. They move with the voice, not with a clock: each ripple answers the voice a moment after the one inside
 *   it, a louder voice pushes them out, and the direction the voice pushes from wanders.
 * - Thinking, the ring tumbles in space, smeared by its own motion, inside a still sphere — a faint haze with a soft
 *   rim — and the ripples stay where they were; both are lit only where the tumbling ring reaches.
 * - Speaking, the ring's light is refracted into a displaced, wider band that swells with the voice read out.
 *
 * Everything here is plain math (no UI), shared by the canvas that draws it and by the tests.
 */
const TAU: number = Math.PI * 2;

/** RGB light amounts (added to the background). */
export const XY_CYAN: number[] = [8, 78, 44];
export const XY_CREAM: number[] = [92, 74, 0];
export const XY_PINK: number[] = [96, 12, 46];
export const XY_VIOLET: number[] = [44, 16, 70];
export const XY_WHITE: number[] = [92, 100, 42];

class XyGlow {
  color: number[];
  width: number;
  speed: number;
  phase: number;

  constructor(color: number[], width: number, speed: number, phase: number) {
    this.color = color;
    this.width = width;
    this.speed = speed;
    this.phase = phase;
  }
}

/** The flowing glows: pink, cyan, cream, violet — width (rad), speed (rad/s), start angle. */
const XY_GLOWS: XyGlow[] = [
  new XyGlow(XY_PINK, 0.4, 0.85, 0),
  new XyGlow(XY_CYAN, 0.6, -0.55, 2.2),
  new XyGlow(XY_CREAM, 0.36, 0.42, 4.1),
  new XyGlow(XY_VIOLET, 0.3, 1.2, 1.1)
];

/**
 * The ring's light at `angle` (radians, canvas orientation) and time `t` (s): the glows passing there over `base`.
 * `gain` sets how strongly the glows color it (1 subtle … 3 vivid).
 */
export function xyLight(angle: number, t: number, base: number[], baseWeight: number, gain: number): number[] {
  let r: number = base[0] * baseWeight;
  let g: number = base[1] * baseWeight;
  let b: number = base[2] * baseWeight;
  let sum: number = baseWeight;
  for (const glow of XY_GLOWS) {
    let d: number = (angle - (glow.phase + glow.speed * t)) % TAU;
    if (d < 0) { d += TAU; }
    if (d > Math.PI) { d = TAU - d; }
    const w: number = gain * Math.exp(-d * d / (2 * glow.width * glow.width));
    r += glow.color[0] * w;
    g += glow.color[1] * w;
    b += glow.color[2] * w;
    sum += w;
  }
  return [r / sum, g / sum, b / sum];
}

/** Brightness of the ring's own light at an angle, 0…1 (its cream and white glows are the brightest). */
export function xyLuminance(angle: number, t: number): number {
  const c: number[] = xyLight(angle, t, XY_WHITE, 0.35, 2.6);
  return Math.min(1, (c[0] + c[1] + c[2]) / 234);
}

/**
 * 'rgba(…)' of a light amount scaled by k, as a bright color with the matching transparency: added (BlendMode.PLUS)
 * it gives exactly the measured light, and drawn normally — where a container does not blend additively — it still
 * reads as colored light over what is behind, never as a dark stroke.
 */
export function xyCss(c: number[], k: number): string {
  const r: number = Math.max(0, c[0] * k);
  const g: number = Math.max(0, c[1] * k);
  const b: number = Math.max(0, c[2] * k);
  const m: number = Math.max(r, g, b);
  if (m < 0.5) { return 'rgba(0,0,0,0)'; }
  const a: number = Math.min(1, m / 255);
  return 'rgba(' + Math.min(255, Math.round(r / a)).toString() + ',' + Math.min(255, Math.round(g / a)).toString() + ',' +
    Math.min(255, Math.round(b / a)).toString() + ',' + a.toFixed(3) + ')';
}

/** The same light, fully transparent: the end of a gradient that fades it out (no dark fringe on the way). */
export function xyCssClear(c: number[]): string {
  const m: number = Math.max(1, c[0], c[1], c[2]);
  return 'rgba(' + Math.round(c[0] / m * 255).toString() + ',' + Math.round(c[1] / m * 255).toString() + ',' +
    Math.round(c[2] / m * 255).toString() + ',0)';
}

/**
 * The voice voice mode hears (the microphone while listening, the voice read out while speaking), 0…1, as it
 * measures it. Its rings read it every frame themselves: passing it through the UI would rebuild the voice island
 * sixty times a second.
 */
export class XyLiveLevel {
  static value: number = 0;
}

/** Samples kept: 3 s at 60 Hz. */
const XY_HISTORY: number = 180;
const XY_STEP: number = 1 / 60;
/** The level's spring: angular frequency (rad/s) and damping. */
const XY_SPRING_W: number = 19;
const XY_SPRING_Z: number = 0.8;

/**
 * The voice the ring answers to, and how much it is listening, thinking or speaking (each eases in and out). The
 * level is sampled at 60 Hz so a ripple can look back at what the voice did a moment ago; while thinking the
 * ripples keep the history they had when it started.
 */
export class XyVoice {
  level: number = 0;
  listen: number = 0;
  think: number = 0;
  speak: number = 0;
  /** Seconds of tumbling (keeps running while thinking eases out, so the ring settles instead of snapping flat). */
  thinkTime: number = 0;
  private ema: number = 0;
  /** The level's speed: it follows the voice as a damped spring (no jumps with each syllable, no overshoot). */
  private velocity: number = 0;
  private dir: number = 0.3;
  private dirV: number = 0;
  private carry: number = 0;
  private levels: number[] = [];
  private dirs: number[] = [];
  private frozenLevels: number[] = [];
  private frozenDirs: number[] = [];
  private frozen: boolean = false;

  /** One frame: `dt` seconds in `mode` ('idle' | 'listen' | 'think' | 'speak') with the voice at `raw` (0…1). */
  step(dt: number, mode: string, raw: number, random: () => number = Math.random): void {
    const k: number = Math.min(3, Math.max(0, dt / XY_STEP));
    const ease: number = 1 - Math.pow(1 - 0.08, k);
    this.listen += ((mode === 'listen' ? 1 : 0) - this.listen) * ease;
    this.think += ((mode === 'think' ? 1 : 0) - this.think) * ease;
    this.speak += ((mode === 'speak' ? 1 : 0) - this.speak) * ease;
    const input: number = mode === 'listen' || mode === 'speak' ? Math.max(0, Math.min(1, raw)) : 0;
    // A damped spring (≈ 3 Hz, ζ 0.8) in small steps: the water swells and settles smoothly at any frame rate.
    let left: number = Math.min(0.05, Math.max(0, dt));
    while (left > 1e-6) {
      const h: number = Math.min(left, 1 / 240);
      this.velocity += (XY_SPRING_W * XY_SPRING_W * (input - this.level) - 2 * XY_SPRING_Z * XY_SPRING_W * this.velocity) * h;
      this.level = Math.max(0, Math.min(1.15, this.level + this.velocity * h));
      left -= h;
    }
    this.ema += (this.level - this.ema) * (1 - Math.pow(1 - 0.06, k));
    // Where the voice pushes the water from: a slow random walk, nudged by every rise of the voice.
    this.dirV += (random() - 0.5) * 0.02 * k;
    this.dirV *= Math.pow(0.97, k);
    this.dir += this.dirV + (this.level - this.ema) * 0.6 * k;
    this.carry += dt;
    while (this.carry >= XY_STEP) {
      this.carry -= XY_STEP;
      this.levels.push(this.level);
      this.dirs.push(this.dir);
      if (this.levels.length > XY_HISTORY) { this.levels.shift(); this.dirs.shift(); }
    }
    if (mode === 'think') {
      if (!this.frozen) {
        this.frozen = true;
        this.frozenLevels = this.levels.slice();
        this.frozenDirs = this.dirs.slice();
      }
    } else if (this.think < 0.02) {
      this.frozen = false;
    }
    if (mode === 'think' || this.think > 0.01) { this.thinkTime += dt; } else { this.thinkTime = 0; }
  }

  /** `delay` seconds back in the 60 Hz history, between samples (smooth at 120 frames a second too). */
  private pick(list: number[], delay: number, fallback: number, live: boolean): number {
    if (list.length === 0) { return fallback; }
    // Live, the newest sample is `carry` old; a frozen history stays exactly where it was.
    const back: number = Math.max(0, (delay - (live ? this.carry : 0)) / XY_STEP);
    const i: number = list.length - 1 - back;
    if (i <= 0) { return list[0]; }
    const lo: number = Math.floor(i);
    const f: number = i - lo;
    return lo + 1 < list.length ? list[lo] + (list[lo + 1] - list[lo]) * f : list[lo];
  }

  /** Thinking holds the history it had when it started: the ripples stay exactly where they were. */
  isFrozen(): boolean { return this.frozen; }

  /** The voice level `delay` seconds ago (from when thinking started, while it thinks). */
  levelAgo(delay: number): number {
    return this.frozen ? this.pick(this.frozenLevels, delay, 0, false) : this.pick(this.levels, delay, this.level, true);
  }

  /** The direction (radians) the voice pushed from `delay` seconds ago. */
  dirAgo(delay: number): number {
    return this.frozen ? this.pick(this.frozenDirs, delay, this.dir, false) : this.pick(this.dirs, delay, this.dir, true);
  }
}

/** One ripple's shape: centre offset (in R), radius (in R), band width (in R) and strength (0…~1). */
export class XyRipple {
  ox: number;
  oy: number;
  radius: number;
  width: number;
  strength: number;
  delay: number;

  constructor(ox: number, oy: number, radius: number, width: number, strength: number, delay: number) {
    this.ox = ox;
    this.oy = oy;
    this.radius = radius;
    this.width = width;
    this.strength = strength;
    this.delay = delay;
  }
}

const XY_RIPPLE_RADIUS: number[] = [1.24, 1.62, 1.95];
const XY_RIPPLE_OFFSET: number[] = [0.15, 0.1, 0.07];
const XY_RIPPLE_WIDTH: number[] = [0.12, 0.11, 0.1];
const XY_RIPPLE_STRENGTH: number[] = [1.0, 0.95, 0.75];

/** The three ripples now: each answers the voice 0.13 s after the one inside it. */
export function xyRipples(voice: XyVoice): XyRipple[] {
  const out: XyRipple[] = [];
  for (let i = 0; i < 3; i++) {
    const delay: number = (i + 1) * 0.13;
    // Listening, the shape eases out with the voice; thinking keeps the shape it had (only its light fades).
    const level: number = voice.levelAgo(delay) * (voice.isFrozen() ? 1 : voice.listen);
    const dir: number = voice.dirAgo(delay);
    const off: number = XY_RIPPLE_OFFSET[i] + 0.05 * level;
    out.push(new XyRipple(Math.cos(dir) * off, Math.sin(dir) * off,
      XY_RIPPLE_RADIUS[i] + 0.07 * (i + 1) * level,
      XY_RIPPLE_WIDTH[i] * (0.85 + 0.5 * level),
      XY_RIPPLE_STRENGTH[i] * ((0.6 + 0.5 * level) * voice.listen + 0.12 * voice.think), delay));
  }
  return out;
}

/**
 * How brightly a ripple shines at `angle`: closer to the ring is brighter (the eccentric ripple's near side makes the
 * crescent), and so is the ring's own light there.
 */
export function xyRippleShine(ripple: XyRipple, angle: number, t: number): number {
  const px: number = Math.cos(angle) * ripple.radius + ripple.ox;
  const py: number = Math.sin(angle) * ripple.radius + ripple.oy;
  const gap: number = Math.max(0.08, Math.hypot(px, py) - 1);
  const near: number = Math.min(1.6, Math.max(0.3, 0.3 / gap));
  return ripple.strength * (0.35 + 0.55 * near) * (0.6 + 0.6 * xyLuminance(angle, t - ripple.delay));
}

/**
 * The tumbling ring at time `u` (s of thinking), blended with the flat ring by `mix`: n + 1 points [x, y, z, angle]
 * on the unit circle (z toward the viewer). Measured: about 1.2 turns a second about axes that keep changing.
 */
export function xyRingPoints(u: number, mix: number, n: number): number[][] {
  const al: number = u * 7.2;
  const be: number = u * 4.4 + 0.7 * Math.sin(u * 0.9);
  const ga: number = u * 1.4;
  const ca: number = Math.cos(al);
  const sa: number = Math.sin(al);
  const cb: number = Math.cos(be);
  const sb: number = Math.sin(be);
  const cg: number = Math.cos(ga);
  const sg: number = Math.sin(ga);
  const s: number = 1 - 0.06 * mix;
  const out: number[][] = [];
  for (let i = 0; i <= n; i++) {
    const a: number = i / n * TAU;
    const x: number = Math.cos(a);
    const y: number = Math.sin(a);
    const y1: number = y * ca;
    const z1: number = y * sa;
    const x2: number = x * cb + z1 * sb;
    const z2: number = -x * sb + z1 * cb;
    const x3: number = x2 * cg - y1 * sg;
    const y3: number = x2 * sg + y1 * cg;
    out.push([s * (x + (x3 - x) * mix), s * (y + (y3 - y) * mix), z2 * mix, a]);
  }
  return out;
}

/** How far the tumbling ring (and its trail) reaches out at each screen angle, and its color there. */
export class XyReach {
  private readonly sectors: number = 48;
  private reach: number[] = [];
  private colors: number[][] = [];

  constructor(copies: number[][][], t: number) {
    for (let k = 0; k < this.sectors; k++) { this.reach.push(0); this.colors.push(XY_CYAN); }
    const seen: boolean[] = this.reach.map((): boolean => false);
    copies.forEach((points: number[][], j: number): void => {
      points.forEach((p: number[]): void => {
        const k: number = this.sector(Math.atan2(p[1], p[0]));
        const d: number = Math.hypot(p[0], p[1]) * (1 - j * 0.02);
        if (d > this.reach[k]) {
          this.reach[k] = d;
          this.colors[k] = xyLight(p[3], t, XY_CYAN, 0.4, 1.4);
          seen[k] = true;
        }
      });
    });
    // Light spreads a little to the sectors beside it.
    for (let pass = 0; pass < 4; pass++) {
      for (let k = 0; k < this.sectors; k++) {
        const l: number = (k + this.sectors - 1) % this.sectors;
        const r: number = (k + 1) % this.sectors;
        this.reach[k] = Math.max(this.reach[k], 0.9 * Math.max(this.reach[l], this.reach[r]));
        if (!seen[k]) { this.colors[k] = seen[l] ? this.colors[l] : this.colors[r]; }
      }
    }
  }

  private sector(angle: number): number {
    return ((Math.round(angle / TAU * this.sectors) % this.sectors) + this.sectors) % this.sectors;
  }

  /** The reach at `angle`, between the two nearest sectors (no steps as the ring turns). */
  private reachAt(angle: number): number {
    const f: number = ((angle / TAU * this.sectors) % this.sectors + this.sectors) % this.sectors;
    const lo: number = Math.floor(f) % this.sectors;
    const hi: number = (lo + 1) % this.sectors;
    return this.reach[lo] + (this.reach[hi] - this.reach[lo]) * (f - Math.floor(f));
  }

  /** 0…1: how strongly the ring lights this angle of the sphere's rim now. */
  lightAt(angle: number): number { return Math.max(0, this.reachAt(angle) - 0.6) / 0.4; }

  /** 0…1: how strongly it lights a still ripple further out at this angle. */
  rippleLightAt(angle: number): number { return Math.min(1, Math.max(0, this.reachAt(angle) - 0.5) * 2); }

  colorAt(angle: number): number[] {
    const f: number = ((angle / TAU * this.sectors) % this.sectors + this.sectors) % this.sectors;
    const lo: number = Math.floor(f) % this.sectors;
    const a: number[] = this.colors[lo];
    const b: number[] = this.colors[(lo + 1) % this.sectors];
    const w: number = f - Math.floor(f);
    return [a[0] + (b[0] - a[0]) * w, a[1] + (b[1] - a[1]) * w, a[2] + (b[2] - a[2]) * w];
  }
}
