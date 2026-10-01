import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { AppConfig } from '../common/Theme';
import {
  badgeInkFor, badgeLuminance, cleanBadgeColors, cycleColor, mixHex, PRO_BADGE_DEFAULT_PRIMARY, PRO_BADGE_DEFAULT_SECONDARY,
  proBadgeCycleStops, proBadgePulse, ProBadgeWarpRay, proBadgeWarpRays, proBadgeShimmerStops, proBadgeStaticStops,
  validBadgeHex, withAlpha
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
const FLOW_FRAME_MS: number = 33;
const PRO_BADGE_PHASE: string = 'proBadgePhase';

/** One shared frame clock for every visible animated badge; it stops when none is on screen. */
class ProBadgeFlowClock {
  private static users: number = 0;
  private static timer: number = -1;
  /** Scrolling lists pause the clock so badges do not re-render while the user drags. */
  static pausedBy: number = 0;

  static acquire(): void {
    ProBadgeFlowClock.users++;
    if (ProBadgeFlowClock.timer !== -1) { return; }
    ProBadgeFlowClock.timer = setInterval((): void => {
      if (ProBadgeFlowClock.pausedBy > 0) { return; }
      AppStorage.setOrCreate(PRO_BADGE_PHASE, (Date.now() % FLOW_PERIOD_MS) / FLOW_PERIOD_MS);
    }, FLOW_FRAME_MS);
  }

  static release(): void {
    ProBadgeFlowClock.users = Math.max(0, ProBadgeFlowClock.users - 1);
    if (ProBadgeFlowClock.users === 0 && ProBadgeFlowClock.timer !== -1) {
      clearInterval(ProBadgeFlowClock.timer);
      ProBadgeFlowClock.timer = -1;
    }
  }
}

/**
 * Freezes every Pro badge animation while a scroll is in progress (call with true on scroll start, false on stop).
 * Each badge keeps its current frame, so pausing is invisible apart from the motion holding still.
 */
export function setProBadgeAnimationPaused(paused: boolean): void {
  ProBadgeFlowClock.pausedBy = paused ? 1 : 0;
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
  @StorageProp(PRO_BADGE_PHASE) @Watch('drawRays') phase: number = 0;
  /** Rays are painted on a canvas each frame; ForEach over same-keyed items would never repaint them. */
  private rayContext: CanvasRenderingContext2D = new CanvasRenderingContext2D(new RenderingContextSettings(true));
  private rayCanvasReady: boolean = false;
  private ticking: boolean = false;

  aboutToAppear(): void {
    ProBadgePreferences.load(getContext(this));
    this.syncClock();
  }

  aboutToDisappear(): void {
    if (this.ticking) { ProBadgeFlowClock.release(); this.ticking = false; }
  }

  /** Style, motion or colors changed: re-evaluate the clock and repaint a still canvas. */
  onLookChange(): void { this.syncClock(); this.drawRays(); }

  syncClock(): void {
    const wanted: boolean = this.shown() && this.activeMotion() !== 'static';
    if (wanted && !this.ticking) { ProBadgeFlowClock.acquire(); this.ticking = true; }
    if (!wanted && this.ticking) { ProBadgeFlowClock.release(); this.ticking = false; }
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
  private rays(): ProBadgeWarpRay[] { return proBadgeWarpRays(this.phase, this.raysMove()); }
  /** The plate keeps a faint fixed burst underneath the moving rays, like the engraved lines of the badge. */
  private engravedRays(): ProBadgeWarpRay[] {
    return this.activeStyle() === 'warp' && this.raysMove() ? proBadgeWarpRays(0, false) : [];
  }
  /** Silver-white on the plate with every fourth ray tinted by the palette; white over light fills. */
  private rayColor(index: number): string {
    if (!this.darkBody()) { return '#FFFFFF'; }
    return index % 4 === 0 ? cycleColor(this.phase + index / 40, this.colors()) : '#E8EEF8';
  }

  private fillStops(): Array<[ResourceColor, number]> {
    const motion: ProBadgeMotion = this.activeMotion();
    if (motion === 'shimmer') { return proBadgeShimmerStops(this.phase, this.colors()); }
    if (motion === 'sweep') { return proBadgeCycleStops(this.phase, this.colors()); }
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
    return this.activeMotion() === 'static' ? this.colors()[0] : cycleColor(this.phase, this.colors());
  }
  /** Outline ring and text: pastel palettes are deepened a little so they stay visible on light surfaces. */
  private ringColor(): string {
    const color: string = this.liveColor();
    return badgeLuminance(color) > 0.55 ? mixHex(color, '#1E1A3A', 0.32) : color;
  }
  private pulse(): number { return this.activeMotion() === 'pulse' ? proBadgePulse(this.phase) : 0; }

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

  /** Half the badge diagonal: the unit the rays are measured in, so they reach every corner. */
  private reach(): number { return Math.sqrt(this.w() * this.w() + this.h() * this.h()) / 2; }

  /** Paints the engraved burst (plate only) and the moving rays for the current phase. */
  drawRays(): void {
    if (!this.rayCanvasReady || !this.showsRays()) { return; }
    const ctx: CanvasRenderingContext2D = this.rayContext;
    const w: number = this.w();
    const h: number = this.h();
    const reach: number = this.reach();
    ctx.clearRect(0, 0, w, h);
    const paint = (items: ProBadgeWarpRay[], strength: number): void => {
      items.forEach((item: ProBadgeWarpRay, index: number): void => {
        const opacity: number = item.opacity * strength * (this.darkBody() ? 1 : 0.7);
        if (opacity <= 0.01) { return; }
        const rad: number = item.angle * Math.PI / 180;
        const inner: number = (item.radius - item.length / 2) * reach;
        const outer: number = (item.radius + item.length / 2) * reach;
        const x0: number = w / 2 + Math.cos(rad) * inner;
        const y0: number = h / 2 + Math.sin(rad) * inner;
        const x1: number = w / 2 + Math.cos(rad) * outer;
        const y1: number = h / 2 + Math.sin(rad) * outer;
        const color: string = this.rayColor(index);
        const gradient: CanvasGradient = ctx.createLinearGradient(x0, y0, x1, y1);
        gradient.addColorStop(0, withAlpha(color, '00'));
        gradient.addColorStop(1, withAlpha(color, 'FF'));
        ctx.globalAlpha = Math.min(1, opacity);
        ctx.strokeStyle = gradient;
        ctx.lineWidth = (this.large ? 1 : 0.8) * item.weight;
        ctx.beginPath();
        ctx.moveTo(x0, y0);
        ctx.lineTo(x1, y1);
        ctx.stroke();
      });
    };
    paint(this.engravedRays(), 0.35);
    paint(this.rays(), 1);
    ctx.globalAlpha = 1;
  }

  @Builder private body() {
    Stack({ alignContent: Alignment.Bottom }) {
      if (this.activeStyle() === 'warp') {
        // Brighter core so the rays seem to come out of the plate's depth.
        Column().width('100%').height('100%')
          .radialGradient({ center: ['50%', '50%'], radius: this.w() * 0.55,
            colors: [['#663A5BC8', 0], ['#00000000', 1]] })
      }
      if (this.showsRays()) {
        Canvas(this.rayContext)
          .width('100%').height('100%')
          .hitTestBehavior(HitTestMode.None)
          .onReady((): void => { this.rayCanvasReady = true; this.drawRays(); })
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
      .accessibilityText('Pro 功能标识，' + proBadgeStyleLabel(this.activeStyle()))
    }
  }
}

/** Palette swatch helper for settings: a small gradient chip of the palette's colors. */
export function proBadgePaletteStops(colors: string[]): Array<[ResourceColor, number]> {
  return proBadgeStaticStops(colors);
}
