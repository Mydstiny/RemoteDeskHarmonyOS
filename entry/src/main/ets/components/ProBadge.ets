import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { displaySync } from '@kit.ArkGraphics2D';
import { AppConfig } from '../common/Theme';
import {
  badgeInkFor, badgeLuminance, badgePalette, cleanBadgeColors, cycleColor, mixHex, PRO_BADGE_DEFAULT_PRIMARY, PRO_BADGE_DEFAULT_SECONDARY,
  PRO_BADGE_RAY_LAYERS, proBadgeCycleStops, proBadgePulse, proBadgeRayLayer, ProBadgeWarpRay, proBadgeWarpRays,
  proBadgeShimmerStops, proBadgeStaticStops, validBadgeHex, withAlpha
} from '../services/pro/ProBadgeFlowPolicy';

const PRO_BADGE_PREFS_KEY: string = 'proBadgeV3';
const PRO_BADGE_V2_PREFS_KEY: string = 'proBadgeV2';
const PRO_BADGE_V1_PREFS_KEY: string = 'proBadgeV1';
const PRO_BADGE_FLOW: string = 'proBadgeFlow';
const PRO_BADGE_VISIBLE: string = 'proBadgeVisible';
const PRO_BADGE_STYLE: string = 'proBadgeStyle';
const PRO_BADGE_MOTION: string = 'proBadgeMotion';
const PRO_BADGE_PRIMARY: string = 'proBadgePrimary';
const PRO_BADGE_SECONDARY: string = 'proBadgeSecondary';
/** JSON array of the 2–4 colors the badge uses. */
const PRO_BADGE_COLORS: string = 'proBadgeColors';
const PRO_BADGE_PALETTE: string = 'proBadgePalette';

export type ProBadgeStyle = 'capsule' | 'soft' | 'outline' | 'carbon' | 'emblem' | 'warp';
export type ProBadgeMotion = 'sweep' | 'pulse' | 'shimmer' | 'meteor' | 'static';

export interface ProBadgeSettings {
  visible: boolean;
  style: ProBadgeStyle;
  motion: ProBadgeMotion;
  /** Palette id from PRO_BADGE_PALETTES, or 'custom'. */
  palette: string;
  colors: string[];
}

export interface ProBadgeStyleOption { id: ProBadgeStyle; label: string; detail: string; }
export interface ProBadgeMotionOption { id: ProBadgeMotion; label: string; detail: string; }

export const PRO_BADGE_STYLE_OPTIONS: ProBadgeStyleOption[] = [
  { id: 'capsule', label: '曜石胶囊', detail: '轻盈圆润，适合列表' },
  { id: 'soft', label: '柔光卡片', detail: '更饱满的圆角徽章' },
  { id: 'outline', label: '霓虹描边', detail: '透明底，发光轮廓' },
  { id: 'carbon', label: '曜黑金属', detail: '深色底，彩色字' },
  { id: 'emblem', label: '性能徽记', detail: '斜体字标，底部光带' },
  { id: 'warp', label: '星爆铭牌', detail: '深蓝底板，放射光线' }
];

export const PRO_BADGE_MOTION_OPTIONS: ProBadgeMotionOption[] = [
  { id: 'sweep', label: '流彩', detail: '颜色沿徽章缓慢流动' },
  { id: 'meteor', label: '星爆', detail: '光线从中心向四周放射流动' },
  { id: 'shimmer', label: '高光', detail: '一束光掠过后稍作停顿' },
  { id: 'pulse', label: '呼吸', detail: '亮度与辉光柔和起伏' },
  { id: 'static', label: '静态', detail: '固定渐变，不播放动效' }
];

/** A one-tap look: style, motion and palette chosen to go together. */
export interface ProBadgePreset { id: string; label: string; style: ProBadgeStyle; motion: ProBadgeMotion; palette: string; }

export const PRO_BADGE_PRESETS: ProBadgePreset[] = [
  { id: 'default', label: '极光流彩', style: 'capsule', motion: 'sweep', palette: 'aurora' },
  { id: 'warp', label: '星际穿越', style: 'warp', motion: 'meteor', palette: 'glacier' },
  { id: 'neon', label: '霓虹夜行', style: 'outline', motion: 'sweep', palette: 'neon' },
  { id: 'gold', label: '暗金典藏', style: 'carbon', motion: 'shimmer', palette: 'gold' },
  { id: 'crimson', label: '赤焰性能', style: 'emblem', motion: 'shimmer', palette: 'crimson' },
  { id: 'sunset', label: '落日星爆', style: 'warp', motion: 'meteor', palette: 'sunset' },
  { id: 'sakura', label: '樱花呼吸', style: 'soft', motion: 'pulse', palette: 'sakura' },
  { id: 'forest', label: '森野静谧', style: 'soft', motion: 'static', palette: 'forest' }
];

export function proBadgeStyleLabel(style: string): string {
  const found: ProBadgeStyleOption | undefined = PRO_BADGE_STYLE_OPTIONS.find((item: ProBadgeStyleOption): boolean =>
    item.id === style);
  return found === undefined ? '曜石胶囊' : found.label;
}

export function proBadgeMotionLabel(motion: string): string {
  const found: ProBadgeMotionOption | undefined = PRO_BADGE_MOTION_OPTIONS.find((item: ProBadgeMotionOption): boolean =>
    item.id === motion);
  return found === undefined ? '流彩' : found.label;
}

/** Palette name for summaries: a built-in palette's label, otherwise 自定义. */
export function proBadgePaletteLabel(palette: string): string {
  const found = badgePalette(palette);
  return found === null ? '自定义' : found.label;
}

/** The preset the current look matches exactly, or null when it was put together by hand. */
export function proBadgeMatchingPreset(style: string, motion: string, palette: string): ProBadgePreset | null {
  const found: ProBadgePreset | undefined = PRO_BADGE_PRESETS.find((item: ProBadgePreset): boolean =>
    item.style === style && item.motion === motion && item.palette === palette);
  return found === undefined ? null : found;
}

/** One-line description of the current look for the settings row: a preset name, or style · motion · palette. */
export function proBadgeSummary(visible: boolean, style: string, motion: string, palette: string): string {
  if (!visible) { return '已隐藏'; }
  const preset: ProBadgePreset | null = proBadgeMatchingPreset(style, motion, palette);
  if (preset !== null) { return '显示 · 预设「' + preset.label + '」'; }
  return '显示 · ' + proBadgeStyleLabel(style) + ' · ' + proBadgeMotionLabel(motion) + ' · ' + proBadgePaletteLabel(palette);
}

function styleOr(value: Object): ProBadgeStyle {
  return value === 'soft' || value === 'outline' || value === 'carbon' || value === 'emblem' || value === 'warp' ?
    value as ProBadgeStyle : 'capsule';
}
function motionOr(value: Object): ProBadgeMotion {
  return value === 'pulse' || value === 'shimmer' || value === 'meteor' || value === 'static' ?
    value as ProBadgeMotion : 'sweep';
}
function parseColors(raw: Object): string[] {
  if (Array.isArray(raw)) { return cleanBadgeColors(raw as string[]); }
  if (typeof raw === 'string') {
    try { return cleanBadgeColors(JSON.parse(raw as string) as string[]); } catch (_error) { return cleanBadgeColors([]); }
  }
  return cleanBadgeColors([]);
}

function defaultSettings(): ProBadgeSettings {
  return { visible: true, style: 'capsule', motion: 'sweep', palette: 'aurora', colors: cleanBadgeColors([]) };
}

/** Device-local look of the Pro marker, shared by every badge through AppStorage. */
export class ProBadgePreferences {
  private static loaded: boolean = false;

  static load(context: common.Context): void {
    if (ProBadgePreferences.loaded) { return; }
    ProBadgePreferences.loaded = true;
    const settings: ProBadgeSettings = defaultSettings();
    try {
      const prefs = preferences.getPreferencesSync(context, { name: 'RemoteDesktopAppPrefs' });
      let raw: string = prefs.getSync(PRO_BADGE_PREFS_KEY, '') as string;
      if (raw.length === 0) { raw = prefs.getSync(PRO_BADGE_V2_PREFS_KEY, '') as string; }
      if (raw.length === 0) { raw = prefs.getSync(PRO_BADGE_V1_PREFS_KEY, '{}') as string; }
      const parsed = JSON.parse(raw) as Record<string, Object>;
      settings.visible = typeof parsed['visible'] === 'boolean' ? parsed['visible'] as boolean : true;
      settings.style = styleOr(parsed['style']);
      if (typeof parsed['motion'] === 'string') {
        settings.motion = motionOr(parsed['motion']);
      } else {
        // v1 stored only a boolean flow switch.
        settings.motion = parsed['flow'] === false ? 'static' : 'sweep';
      }
      if (parsed['colors'] !== undefined) {
        settings.colors = parseColors(parsed['colors']);
        settings.palette = typeof parsed['palette'] === 'string' ? parsed['palette'] as string : 'custom';
      } else if (typeof parsed['primary'] === 'string' && typeof parsed['secondary'] === 'string') {
        // v2 stored a start and end color.
        const primary: string = parsed['primary'] as string;
        const secondary: string = parsed['secondary'] as string;
        if (validBadgeHex(primary) && validBadgeHex(secondary) &&
          !(primary.toUpperCase() === PRO_BADGE_DEFAULT_PRIMARY && secondary.toUpperCase() === PRO_BADGE_DEFAULT_SECONDARY)) {
          settings.colors = cleanBadgeColors([primary, secondary]);
          settings.palette = 'custom';
        }
      }
    } catch (_error) { /* malformed data keeps the defaults */ }
    ProBadgePreferences.setStorage(settings);
  }

  static snapshot(): ProBadgeSettings {
    return {
      visible: AppStorage.get<boolean>(PRO_BADGE_VISIBLE) ?? true,
      style: styleOr(AppStorage.get<string>(PRO_BADGE_STYLE) ?? 'capsule'),
      motion: motionOr(AppStorage.get<string>(PRO_BADGE_MOTION) ?? 'sweep'),
      palette: AppStorage.get<string>(PRO_BADGE_PALETTE) ?? 'aurora',
      colors: parseColors(AppStorage.get<string>(PRO_BADGE_COLORS) ?? '')
    };
  }

  private static setStorage(settings: ProBadgeSettings): void {
    const colors: string[] = cleanBadgeColors(settings.colors);
    AppStorage.setOrCreate(PRO_BADGE_VISIBLE, settings.visible);
    AppStorage.setOrCreate(PRO_BADGE_FLOW, settings.motion !== 'static');
    AppStorage.setOrCreate(PRO_BADGE_STYLE, settings.style);
    AppStorage.setOrCreate(PRO_BADGE_MOTION, settings.motion);
    AppStorage.setOrCreate(PRO_BADGE_PALETTE, settings.palette);
    AppStorage.setOrCreate(PRO_BADGE_COLORS, JSON.stringify(colors));
    AppStorage.setOrCreate(PRO_BADGE_PRIMARY, colors[0]);
    AppStorage.setOrCreate(PRO_BADGE_SECONDARY, colors[1]);
  }

  static save(context: common.Context, settings: ProBadgeSettings): void {
    const next: ProBadgeSettings = {
      visible: settings.visible, style: styleOr(settings.style), motion: motionOr(settings.motion),
      palette: settings.palette, colors: cleanBadgeColors(settings.colors)
    };
    ProBadgePreferences.setStorage(next);
    try {
      const prefs = preferences.getPreferencesSync(context, { name: 'RemoteDesktopAppPrefs' });
      prefs.putSync(PRO_BADGE_PREFS_KEY, JSON.stringify({ version: 3, visible: next.visible, style: next.style,
        motion: next.motion, palette: next.palette, colors: next.colors }));
      prefs.flushSync();
    } catch (_error) { /* the in-memory choice still applies for this run */ }
  }

  /** Compatibility entry point for older callers that only know the flow switch. */
  static update(context: common.Context, flow: boolean, visible: boolean): void {
    const current: ProBadgeSettings = ProBadgePreferences.snapshot();
    current.motion = flow ? (current.motion === 'static' ? 'sweep' : current.motion) : 'static';
    current.visible = visible;
    ProBadgePreferences.save(context, current);
  }
}

const FLOW_PERIOD_MS: number = 2800;
const FLOW_FRAME_MS: number = 40;
const PRO_BADGE_PHASE: string = 'proBadgePhase';
/** One 星爆 layer's flight from the center to the edges. */
const RAY_FLIGHT_MS: number = 1500;

/**
 * One shared frame clock for every visible animated badge; it stops when none is on screen. Ticks come from the
 * display's vsync at up to 30 fps, so steps stay even while the UI thread is busy; a timer is only the fallback.
 */
class ProBadgeFlowClock {
  private static users: number = 0;
  private static timer: number = -1;
  private static sync: displaySync.DisplaySync | null = null;

  /** Phase of the shared cycle right now (0–1); every badge reads the same value, so they move in step. */
  static now(): number { return (Date.now() % FLOW_PERIOD_MS) / FLOW_PERIOD_MS; }

  private static tick(): void {
    AppStorage.setOrCreate(PRO_BADGE_PHASE, ProBadgeFlowClock.now());
  }

  static acquire(): void {
    ProBadgeFlowClock.users++;
    if (ProBadgeFlowClock.sync !== null || ProBadgeFlowClock.timer !== -1) { return; }
    try {
      const sync: displaySync.DisplaySync = displaySync.create();
      sync.setExpectedFrameRateRange({ min: 20, max: 30, expected: 30 });
      sync.on('frame', (): void => { ProBadgeFlowClock.tick(); });
      sync.start();
      ProBadgeFlowClock.sync = sync;
    } catch (_error) {
      ProBadgeFlowClock.timer = setInterval((): void => { ProBadgeFlowClock.tick(); }, FLOW_FRAME_MS);
    }
  }

  static release(): void {
    ProBadgeFlowClock.users = Math.max(0, ProBadgeFlowClock.users - 1);
    if (ProBadgeFlowClock.users > 0) { return; }
    if (ProBadgeFlowClock.sync !== null) {
      try { ProBadgeFlowClock.sync.stop(); ProBadgeFlowClock.sync.off('frame'); } catch (_error) { /* already stopped */ }
      ProBadgeFlowClock.sync = null;
    }
    if (ProBadgeFlowClock.timer !== -1) {
      clearInterval(ProBadgeFlowClock.timer);
      ProBadgeFlowClock.timer = -1;
    }
  }
}

/** Silver-white on dark plates with every fourth ray tinted by the palette; white over light fills. */
function badgeRayColor(index: number, count: number, dark: boolean, colors: string[]): string {
  if (!dark) { return '#FFFFFF'; }
  return index % 4 === 0 ? cycleColor(index / count, colors) : '#E8EEF8';
}

/**
 * Strokes rays as tapered streaks from the badge center: two solid halves (faint inner, bright outer), no gradient
 * objects. Positions are in half-diagonals of the w × h badge so the rays reach every corner.
 */
function paintBadgeRays(ctx: CanvasRenderingContext2D, items: ProBadgeWarpRay[], lineWidth: number, w: number,
  h: number, dark: boolean, colors: string[]): void {
  const reach: number = Math.sqrt(w * w + h * h) / 2;
  ctx.clearRect(0, 0, w, h);
  items.forEach((item: ProBadgeWarpRay, index: number): void => {
    const opacity: number = Math.min(1, item.opacity * (dark ? 1 : 0.7));
    if (opacity <= 0.01) { return; }
    const rad: number = item.angle * Math.PI / 180;
    const inner: number = (item.radius - item.length / 2) * reach;
    const outer: number = (item.radius + item.length / 2) * reach;
    const x0: number = w / 2 + Math.cos(rad) * inner;
    const y0: number = h / 2 + Math.sin(rad) * inner;
    const x1: number = w / 2 + Math.cos(rad) * outer;
    const y1: number = h / 2 + Math.sin(rad) * outer;
    const xm: number = (x0 + x1) / 2;
    const ym: number = (y0 + y1) / 2;
    ctx.strokeStyle = badgeRayColor(index, items.length, dark, colors);
    ctx.lineWidth = lineWidth * item.weight;
    ctx.globalAlpha = opacity * 0.35;
    ctx.beginPath();
    ctx.moveTo(x0, y0);
    ctx.lineTo(xm, ym);
    ctx.stroke();
    ctx.globalAlpha = opacity;
    ctx.beginPath();
    ctx.moveTo(xm, ym);
    ctx.lineTo(x1, y1);
    ctx.stroke();
  });
  ctx.globalAlpha = 1;
}

/**
 * The flying 星爆 rays: three layers painted once near the center, which the system scales outward and fades on the
 * render thread, a third of a cycle apart. A separate component so the parent's color clock never re-renders these
 * canvases; each flight starts once, on the layer's first onReady (later readies come from resizes and only repaint).
 */
@Component
struct ProBadgeRayLayers {
  @Prop @Watch('repaint') rayWidth: number = 34;
  @Prop @Watch('repaint') rayHeight: number = 19;
  @Prop @Watch('repaint') large: boolean = false;
  @Prop @Watch('repaint') dark: boolean = false;
  @Prop @Watch('repaint') colorsKey: string = '';
  @State scale0: number = 0.5;
  @State scale1: number = 0.5;
  @State scale2: number = 0.5;
  @State fade0: number = 0;
  @State fade1: number = 0;
  @State fade2: number = 0;
  private contexts: CanvasRenderingContext2D[] = [];
  private ready: boolean[] = [];
  private flying: boolean[] = [];

  aboutToAppear(): void {
    for (let k: number = 0; k < PRO_BADGE_RAY_LAYERS; k++) {
      this.contexts.push(new CanvasRenderingContext2D(new RenderingContextSettings(true)));
      this.ready.push(false);
      this.flying.push(false);
    }
  }

  repaint(): void {
    for (let k: number = 0; k < this.contexts.length; k++) { this.paint(k); }
  }

  private colors(): string[] { return parseColors(this.colorsKey); }

  /** One layer near the center; thinner strokes because the layer is scaled up as it flies. */
  private paint(k: number): void {
    if (this.ready[k] !== true) { return; }
    paintBadgeRays(this.contexts[k], proBadgeRayLayer(k, this.large ? 14 : 9), this.large ? 0.55 : 0.45,
      this.rayWidth, this.rayHeight, this.dark, this.colors());
  }

  /**
   * Endless flight of one layer. The outward motion is one continuous accelerating curve; the fade is a separate
   * in-then-out animation on the same clock. Splitting the motion into an ease-out leg and an ease-in leg stopped
   * the rays for a moment at the hand-over (the middle of their path), which read as a stutter.
   */
  private fly(k: number): void {
    const delay: number = Math.round(k * RAY_FLIGHT_MS / PRO_BADGE_RAY_LAYERS);
    this.getUIContext().animateTo({ duration: RAY_FLIGHT_MS, delay, iterations: -1, curve: Curve.EaseIn },
      (): void => { this.setScale(k, 3.0); });
    this.getUIContext().keyframeAnimateTo({ iterations: -1, delay }, [
      {
        duration: Math.round(RAY_FLIGHT_MS * 0.3), curve: Curve.EaseOut,
        event: (): void => { this.setFade(k, 1); }
      },
      {
        duration: Math.round(RAY_FLIGHT_MS * 0.7), curve: Curve.EaseIn,
        event: (): void => { this.setFade(k, 0); }
      }
    ]);
  }

  private setScale(k: number, scale: number): void {
    if (k === 0) { this.scale0 = scale; } else if (k === 1) { this.scale1 = scale; } else { this.scale2 = scale; }
  }

  private setFade(k: number, fade: number): void {
    if (k === 0) { this.fade0 = fade; } else if (k === 1) { this.fade1 = fade; } else { this.fade2 = fade; }
  }

  private layerScale(k: number): number { return k === 0 ? this.scale0 : k === 1 ? this.scale1 : this.scale2; }
  private layerFade(k: number): number { return k === 0 ? this.fade0 : k === 1 ? this.fade1 : this.fade2; }

  @Builder private layer(k: number) {
    Canvas(this.contexts[k])
      .width('100%').height('100%')
      .hitTestBehavior(HitTestMode.None)
      .scale({ x: this.layerScale(k), y: this.layerScale(k) })
      .opacity(this.layerFade(k))
      .onReady((): void => {
        this.ready[k] = true;
        this.paint(k);
        if (!this.flying[k]) {
          this.flying[k] = true;
          this.fly(k);
        }
      })
  }

  build() {
    Stack() {
      this.layer(0)
      this.layer(1)
      this.layer(2)
    }.width('100%').height('100%').hitTestBehavior(HitTestMode.None)
  }
}

/** Product marker only; never grants access or represents a payment status on its own. */
@Component
export struct ProBadge {
  @Prop large: boolean = false;
  /** Optional preview overrides used by the Pro 标识 settings. */
  @Prop @Watch('onLookChange') previewStyle: string = '';
  @Prop @Watch('onLookChange') previewMotion: string = '';
  /** JSON array of colors for previews; empty uses the saved colors. */
  @Prop @Watch('onLookChange') previewColors: string = '';
  @StorageProp(PRO_BADGE_VISIBLE) @Watch('syncClock') visible: boolean = true;
  @StorageProp(PRO_BADGE_STYLE) @Watch('onLookChange') style: string = 'capsule';
  @StorageProp(PRO_BADGE_MOTION) @Watch('onLookChange') motion: string = 'sweep';
  @StorageProp(PRO_BADGE_COLORS) @Watch('onLookChange') colorsJson: string = '';
  /** Shared clock; only animated badges copy it into `frame`, so still badges never re-render on its ticks. */
  @StorageProp(PRO_BADGE_PHASE) @Watch('onClockTick') phase: number = 0;
  @State frame: number = 0;
  /**
   * 星爆 rays never repaint per frame: the still burst is painted once, and the moving rays are painted once onto three
   * layers that the system scales outward and fades on the render thread (no JS clock, no canvas redraw per frame).
   */
  private rayContext: CanvasRenderingContext2D = new CanvasRenderingContext2D(new RenderingContextSettings(true));
  private rayCanvasReady: boolean = false;
  /**
   * Moving layers exist only while flying; removing them is what stops their endless animations. They live in their
   * own component so the color clock re-rendering this badge never touches a running flight.
   */
  @State raysFlying: boolean = false;
  private ticking: boolean = false;
  /** Whether any part of the badge is on screen; hidden tabs, closed sheets and scrolled-away rows do not animate. */
  private onScreen: boolean = false;

  aboutToAppear(): void {
    ProBadgePreferences.load(getContext(this));
    this.syncClock();
  }

  aboutToDisappear(): void {
    if (this.ticking) { ProBadgeFlowClock.release(); this.ticking = false; }
    this.raysFlying = false;
  }

  /** Style, motion or colors changed: re-evaluate the clock and rays, and repaint the still plate once. */
  onLookChange(): void {
    this.syncClock();
    this.catchUp();
    this.drawRays();
  }

  /** Clock tick: color-flow badges advance their frame; still and 星爆-only badges ignore it. */
  onClockTick(): void {
    if (!this.onScreen || !this.shown() || !this.clocked()) { return; }
    this.frame = this.phase;
  }

  /**
   * A badge that starts moving (appears, scrolls back in, or switches to a color motion) takes the current phase at
   * once; otherwise it would show its stale frame until the next tick and visibly jump.
   */
  private catchUp(): void {
    if (this.onScreen && this.shown() && this.clocked()) { this.frame = ProBadgeFlowClock.now(); }
  }

  syncClock(): void {
    const wanted: boolean = this.onScreen && this.shown() && this.clocked();
    if (wanted && !this.ticking) { ProBadgeFlowClock.acquire(); this.ticking = true; }
    if (!wanted && this.ticking) { ProBadgeFlowClock.release(); this.ticking = false; }
    this.syncRays();
  }

  /** Only the color motions need the JS frame clock; 星爆 runs entirely as render-thread layer animations. */
  private clocked(): boolean {
    const motion: ProBadgeMotion = this.activeMotion();
    return motion === 'sweep' || motion === 'shimmer' || motion === 'pulse';
  }

  private syncRays(): void {
    const wanted: boolean = this.onScreen && this.shown() && this.showsRays() && this.raysMove();
    if (wanted !== this.raysFlying) { this.raysFlying = wanted; }
  }

  private shown(): boolean { return this.visible || this.previewStyle.length > 0; }
  private activeStyle(): ProBadgeStyle { return styleOr(this.previewStyle.length > 0 ? this.previewStyle : this.style); }
  private activeMotion(): ProBadgeMotion { return motionOr(this.previewMotion.length > 0 ? this.previewMotion : this.motion); }
  /** Parsed colors, cached by their JSON so a frame (and each of its 40 rays) does not re-parse them. */
  private colorsKey: string = '\u0000';
  private colorsCache: string[] = [];
  private colors(): string[] {
    const key: string = this.previewColors.length > 0 ? this.previewColors : this.colorsJson;
    if (key !== this.colorsKey) { this.colorsKey = key; this.colorsCache = parseColors(key); }
    return this.colorsCache;
  }
  /** Light styles fill with the colors; carbon, emblem and the warp plate sit on a dark body. */
  private darkBody(): boolean {
    return this.activeStyle() === 'carbon' || this.activeStyle() === 'emblem' || this.activeStyle() === 'warp';
  }
  /** The 星爆 rays: always on the warp plate, and on any style with the 星爆 motion. */
  private showsRays(): boolean { return this.activeStyle() === 'warp' || this.activeMotion() === 'meteor'; }
  /** Rays fly outward with every motion except 静态, where the plate shows its fixed burst. */
  private raysMove(): boolean { return this.activeMotion() !== 'static'; }
  /** Small badges carry fewer rays: same look at their size, much less to paint. */
  private rayCount(): number { return this.large ? 40 : 24; }

  private fillStops(): Array<[ResourceColor, number]> {
    const motion: ProBadgeMotion = this.activeMotion();
    if (motion === 'shimmer') { return proBadgeShimmerStops(this.frame, this.colors()); }
    if (motion === 'sweep') { return proBadgeCycleStops(this.frame, this.colors()); }
    return proBadgeStaticStops(this.colors());
  }
  /** Body fill: a dark metal for carbon/emblem, transparent for outline, otherwise the animated colors. */
  private bodyStops(): Array<[ResourceColor, number]> {
    if (this.activeStyle() === 'warp') { return [['#1D2856', 0], ['#0B1028', 0.55], ['#121A3C', 1]]; }
    if (this.darkBody()) { return [['#2B2B35', 0], ['#121217', 1]]; }
    if (this.activeStyle() === 'outline') { return [['#00000000', 0], ['#00000000', 1]]; }
    return this.fillStops();
  }
  /** Current single accent color (outline ring, carbon text, emblem stripe, glow). */
  private liveColor(): string {
    return this.clocked() ? cycleColor(this.frame, this.colors()) : this.colors()[0];
  }
  /** Outline ring and text: pastel palettes are deepened a little so they stay visible on light surfaces. */
  private ringColor(): string {
    const color: string = this.liveColor();
    return badgeLuminance(color) > 0.55 ? mixHex(color, '#1E1A3A', 0.32) : color;
  }
  private pulse(): number { return this.activeMotion() === 'pulse' ? proBadgePulse(this.frame) : 0; }

  private w(): number {
    const style: ProBadgeStyle = this.activeStyle();
    if (style === 'soft') { return this.large ? 52 : 36; }
    if (style === 'emblem' || style === 'warp') { return this.large ? 56 : 40; }
    return this.large ? 48 : 34;
  }
  private h(): number {
    const style: ProBadgeStyle = this.activeStyle();
    return style === 'soft' ? (this.large ? 28 : 21) : (this.large ? 25 : 19);
  }
  private radius(): number {
    const style: ProBadgeStyle = this.activeStyle();
    if (style === 'outline' || style === 'emblem' || style === 'warp') { return this.large ? 7 : 5; }
    return this.large ? 10 : 8;
  }

  /** The still burst of the 星爆 plate under 静态. Moving rays have no still layer beneath them. Painted once. */
  drawRays(): void {
    if (!this.rayCanvasReady || !this.showsRays()) { return; }
    const ctx: CanvasRenderingContext2D = this.rayContext;
    ctx.clearRect(0, 0, this.w(), this.h());
    if (!this.raysMove()) {
      paintBadgeRays(ctx, proBadgeWarpRays(0, false, this.rayCount()), this.large ? 1 : 0.8,
        this.w(), this.h(), this.darkBody(), this.colors());
    }
  }

  @Builder private body() {
    Stack({ alignContent: Alignment.Bottom }) {
      if (this.activeStyle() === 'warp') {
        // Brighter core so the rays seem to come out of the plate's depth.
        Column().width('100%').height('100%')
          .radialGradient({ center: ['50%', '50%'], radius: this.w() * 0.55,
            colors: [['#663A5BC8', 0], ['#00000000', 1]] })
      }
      if (this.showsRays() && !this.raysMove()) {
        Canvas(this.rayContext)
          .width('100%').height('100%')
          .hitTestBehavior(HitTestMode.None)
          .onReady((): void => { this.rayCanvasReady = true; this.drawRays(); })
      }
      if (this.raysFlying) {
        ProBadgeRayLayers({ rayWidth: this.w(), rayHeight: this.h(), large: this.large, dark: this.darkBody(),
          colorsKey: JSON.stringify(this.colors()) })
          .width('100%').height('100%')
      }
      Text(this.activeStyle() === 'emblem' ? 'PRO' : 'Pro')
        .fontSize(this.activeStyle() === 'emblem' ? (this.large ? 12 : 9) : (this.large ? 13 : 10))
        .fontWeight(this.activeStyle() === 'emblem' ? FontWeight.Bolder : FontWeight.Bold)
        .fontStyle(this.activeStyle() === 'emblem' ? FontStyle.Italic : FontStyle.Normal)
        .letterSpacing(this.activeStyle() === 'emblem' ? 1.6 : 0)
        .fontFamily(AppConfig.fontFamily).maxLines(1).textAlign(TextAlign.Center)
        .fontColor(this.activeStyle() === 'outline' ? this.ringColor() : this.activeStyle() === 'carbon' ? this.liveColor() :
          this.activeStyle() === 'emblem' || this.activeStyle() === 'warp' ? '#FFFFFF' : badgeInkFor(this.colors()))
        .textShadow(this.showsRays() ? { radius: 3, color: this.darkBody() ? '#CC0B1028' : '#66FFFFFF', offsetX: 0, offsetY: 0 } :
          { radius: 0, color: '#00000000', offsetX: 0, offsetY: 0 })
        .width('100%').height('100%')
      if (this.activeStyle() === 'emblem') {
        // The light stripe under the letters carries the colors.
        Row().width('78%').height(this.large ? 2 : 1.5).borderRadius(1).margin({ bottom: this.large ? 3 : 2 })
          .linearGradient({ angle: 90, colors: this.fillStops() })
      }
    }
    .width(this.w()).height(this.h()).borderRadius(this.radius()).clip(true)
    .linearGradient({ angle: this.darkBody() ? 160 : 90, colors: this.bodyStops() })
    .border({ width: this.activeStyle() === 'outline' ? 1.2 : 0.5,
      color: this.activeStyle() === 'outline' ? this.ringColor() :
        this.darkBody() ? withAlpha(this.liveColor(), '66') : '#90FFFFFF' })
    .shadow({
      radius: this.activeStyle() === 'outline' || this.darkBody() ? 6 + this.pulse() * 8 : 3 + this.pulse() * 6,
      color: this.activeStyle() === 'outline' || this.darkBody() || this.pulse() > 0 ?
        withAlpha(this.liveColor(), this.pulse() > 0 ? 'A0' : '66') : '#22000000',
      offsetY: 1
    })
    .opacity(this.activeMotion() === 'pulse' ? 0.86 + 0.14 * this.pulse() : 1)
  }

  build() {
    if (this.shown()) {
      Stack() {
        this.body()
      }
      .width(this.w()).height(this.h())
      .onVisibleAreaChange([0.0, 0.01], (visible: boolean, _ratio: number): void => {
        if (visible === this.onScreen) { return; }
        this.onScreen = visible;
        this.syncClock();
        if (visible) { this.catchUp(); }
      })
      .accessibilityText('Pro 功能标识，' + proBadgeStyleLabel(this.activeStyle()))
    }
  }
}

/** Palette swatch helper for settings: a small gradient chip of the palette's colors. */
export function proBadgePaletteStops(colors: string[]): Array<[ResourceColor, number]> {
  return proBadgeStaticStops(colors);
}
