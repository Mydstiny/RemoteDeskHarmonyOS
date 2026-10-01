import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { AppConfig } from '../common/Theme';
import {
  badgeInkFor, badgeLuminance, cleanBadgeColors, cycleColor, mixHex, PRO_BADGE_DEFAULT_PRIMARY, PRO_BADGE_DEFAULT_SECONDARY,
  proBadgeCycleStops, ProBadgeMeteor, proBadgeMeteors, proBadgePulse, proBadgeShimmerStops, proBadgeStaticStops,
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

export type ProBadgeStyle = 'capsule' | 'soft' | 'outline' | 'carbon' | 'emblem';
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
  { id: 'emblem', label: '性能徽记', detail: '斜体字标，底部光带' }
];

export const PRO_BADGE_MOTION_OPTIONS: ProBadgeMotionOption[] = [
  { id: 'sweep', label: '流彩', detail: '颜色沿徽章缓慢流动' },
  { id: 'meteor', label: '流星', detail: '光尾从徽章向两侧发散' },
  { id: 'shimmer', label: '高光', detail: '一束光掠过后稍作停顿' },
  { id: 'pulse', label: '呼吸', detail: '亮度与辉光柔和起伏' },
  { id: 'static', label: '静态', detail: '固定渐变，不播放动效' }
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
  return value === 'soft' || value === 'outline' || value === 'carbon' || value === 'emblem' ?
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

  static acquire(): void {
    ProBadgeFlowClock.users++;
    if (ProBadgeFlowClock.timer !== -1) { return; }
    ProBadgeFlowClock.timer = setInterval((): void => {
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

/** Product marker only; never grants access or represents a payment status on its own. */
@Component
export struct ProBadge {
  @Prop large: boolean = false;
  /** Optional preview overrides used by the Pro 标识 settings. */
  @Prop previewStyle: string = '';
  @Prop previewMotion: string = '';
  /** JSON array of colors for previews; empty uses the saved colors. */
  @Prop previewColors: string = '';
  @StorageProp(PRO_BADGE_VISIBLE) @Watch('syncClock') visible: boolean = true;
  @StorageProp(PRO_BADGE_STYLE) style: string = 'capsule';
  @StorageProp(PRO_BADGE_MOTION) @Watch('syncClock') motion: string = 'sweep';
  @StorageProp(PRO_BADGE_COLORS) colorsJson: string = '';
  @StorageProp(PRO_BADGE_PHASE) phase: number = 0;
  private ticking: boolean = false;

  aboutToAppear(): void {
    ProBadgePreferences.load(getContext(this));
    this.syncClock();
  }

  aboutToDisappear(): void {
    if (this.ticking) { ProBadgeFlowClock.release(); this.ticking = false; }
  }

  syncClock(): void {
    const wanted: boolean = this.shown() && this.activeMotion() !== 'static';
    if (wanted && !this.ticking) { ProBadgeFlowClock.acquire(); this.ticking = true; }
    if (!wanted && this.ticking) { ProBadgeFlowClock.release(); this.ticking = false; }
  }

  private shown(): boolean { return this.visible || this.previewStyle.length > 0; }
  private activeStyle(): ProBadgeStyle { return styleOr(this.previewStyle.length > 0 ? this.previewStyle : this.style); }
  private activeMotion(): ProBadgeMotion { return motionOr(this.previewMotion.length > 0 ? this.previewMotion : this.motion); }
  private colors(): string[] { return parseColors(this.previewColors.length > 0 ? this.previewColors : this.colorsJson); }
  /** Light styles fill with the colors; carbon and emblem sit on a dark body. */
  private darkBody(): boolean { return this.activeStyle() === 'carbon' || this.activeStyle() === 'emblem'; }

  private fillStops(): Array<[ResourceColor, number]> {
    const motion: ProBadgeMotion = this.activeMotion();
    if (motion === 'shimmer') { return proBadgeShimmerStops(this.phase, this.colors()); }
    if (motion === 'sweep' || motion === 'meteor') { return proBadgeCycleStops(this.phase * (motion === 'meteor' ? 0.5 : 1), this.colors()); }
    return proBadgeStaticStops(this.colors());
  }
  /** Body fill: a dark metal for carbon/emblem, transparent for outline, otherwise the animated colors. */
  private bodyStops(): Array<[ResourceColor, number]> {
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
    if (style === 'emblem') { return this.large ? 56 : 40; }
    return this.large ? 48 : 34;
  }
  private h(): number {
    const style: ProBadgeStyle = this.activeStyle();
    return style === 'soft' ? (this.large ? 28 : 21) : (this.large ? 25 : 19);
  }
  private radius(): number {
    const style: ProBadgeStyle = this.activeStyle();
    if (style === 'outline' || style === 'emblem') { return this.large ? 7 : 5; }
    return this.large ? 10 : 8;
  }

  @Builder private meteor(item: ProBadgeMeteor) {
    Row()
      .width(Math.max(2, item.length * this.h()))
      .height(this.large ? 2 : 1.6)
      .borderRadius(1)
      .linearGradient({ angle: 90, colors: [[withAlpha(item.color, '00'), 0], [withAlpha(item.color, 'F2'), 0.62],
        ['#FFFFFFFF', 1]] })
      .opacity(item.opacity)
      .position({
        x: this.w() / 2 + Math.cos(item.angle * Math.PI / 180) * (this.w() / 2 + item.travel * this.h()) -
          item.length * this.h() / 2,
        y: this.h() / 2 + Math.sin(item.angle * Math.PI / 180) * (this.h() / 2 + item.travel * this.h() * 0.35) - 0.7
      })
      .rotate({ angle: item.angle })
      .hitTestBehavior(HitTestMode.None)
  }

  @Builder private body() {
    Stack({ alignContent: Alignment.Bottom }) {
      Text(this.activeStyle() === 'emblem' ? 'PRO' : 'Pro')
        .fontSize(this.activeStyle() === 'emblem' ? (this.large ? 12 : 9) : (this.large ? 13 : 10))
        .fontWeight(this.activeStyle() === 'emblem' ? FontWeight.Bolder : FontWeight.Bold)
        .fontStyle(this.activeStyle() === 'emblem' ? FontStyle.Italic : FontStyle.Normal)
        .letterSpacing(this.activeStyle() === 'emblem' ? 1.6 : 0)
        .fontFamily(AppConfig.fontFamily).maxLines(1).textAlign(TextAlign.Center)
        .fontColor(this.activeStyle() === 'outline' ? this.ringColor() : this.activeStyle() === 'carbon' ? this.liveColor() :
          this.activeStyle() === 'emblem' ? '#FFFFFF' : badgeInkFor(this.colors()))
        .width('100%').height('100%')
      if (this.activeStyle() === 'emblem') {
        // The light stripe under the letters carries the colors.
        Row().width('78%').height(this.large ? 2 : 1.5).borderRadius(1).margin({ bottom: this.large ? 3 : 2 })
          .linearGradient({ angle: 90, colors: this.fillStops() })
      }
    }
    .width(this.w()).height(this.h()).borderRadius(this.radius())
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
        if (this.activeMotion() === 'meteor') {
          ForEach(proBadgeMeteors(this.phase, this.colors()), (item: ProBadgeMeteor): void => { this.meteor(item) },
            (_item: ProBadgeMeteor, index: number): string => 'm' + index.toString())
        }
        this.body()
      }
      .width(this.w()).height(this.h()).clip(false)
      .accessibilityText('Pro 功能标识，' + proBadgeStyleLabel(this.activeStyle()))
    }
  }
}

/** Palette swatch helper for settings: a small gradient chip of the palette's colors. */
export function proBadgePaletteStops(colors: string[]): Array<[ResourceColor, number]> {
  return proBadgeStaticStops(colors);
}
