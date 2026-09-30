import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { AppConfig } from '../common/Theme';
import { proBadgeFlowStops } from '../services/pro/ProBadgeFlowPolicy';

const PRO_BADGE_PREFS_KEY: string = 'proBadgeV1';
const PRO_BADGE_FLOW: string = 'proBadgeFlow';
const PRO_BADGE_VISIBLE: string = 'proBadgeVisible';

/** Device-local look of the Pro marker, shared by every badge through AppStorage. */
export class ProBadgePreferences {
  private static loaded: boolean = false;

  static load(context: common.Context): void {
    if (ProBadgePreferences.loaded) { return; }
    ProBadgePreferences.loaded = true;
    let flow: boolean = true;
    let visible: boolean = true;
    try {
      const raw = preferences.getPreferencesSync(context, { name: 'RemoteDesktopAppPrefs' })
        .getSync(PRO_BADGE_PREFS_KEY, '{}') as string;
      const parsed = JSON.parse(raw) as Record<string, Object>;
      if (typeof parsed['flow'] === 'boolean') { flow = parsed['flow'] as boolean; }
      if (typeof parsed['visible'] === 'boolean') { visible = parsed['visible'] as boolean; }
    } catch (_error) { /* malformed data keeps the defaults */ }
    AppStorage.setOrCreate(PRO_BADGE_FLOW, flow);
    AppStorage.setOrCreate(PRO_BADGE_VISIBLE, visible);
  }

  static update(context: common.Context, flow: boolean, visible: boolean): void {
    AppStorage.setOrCreate(PRO_BADGE_FLOW, flow);
    AppStorage.setOrCreate(PRO_BADGE_VISIBLE, visible);
    try {
      const prefs = preferences.getPreferencesSync(context, { name: 'RemoteDesktopAppPrefs' });
      prefs.putSync(PRO_BADGE_PREFS_KEY, JSON.stringify({ flow, visible }));
      prefs.flushSync();
    } catch (_error) { /* the in-memory choice still applies for this run */ }
  }
}

const FLOW_PERIOD_MS: number = 2800;
const FLOW_FRAME_MS: number = 33;
const PRO_BADGE_PHASE: string = 'proBadgePhase';

/** One shared frame clock for every visible flowing badge. */
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

/**
 * Product marker only; never grants access or represents a payment status on its own.
 * Iridescent, flowing by default; both the flow and the marker itself can be turned off in
 * 设置 > Pro 功能.
 */
@Component
export struct ProBadge {
  @Prop large: boolean = false;
  @StorageProp('proBadgeFlow') @Watch('syncClock') flow: boolean = true;
  @StorageProp('proBadgeVisible') @Watch('syncClock') visible: boolean = true;
  @StorageProp('proBadgePhase') phase: number = 0;
  private ticking: boolean = false;

  aboutToAppear(): void {
    ProBadgePreferences.load(getContext(this));
    this.syncClock();
  }

  aboutToDisappear(): void {
    if (this.ticking) { ProBadgeFlowClock.release(); this.ticking = false; }
  }

  syncClock(): void {
    const wanted: boolean = this.flow && this.visible;
    if (wanted && !this.ticking) { ProBadgeFlowClock.acquire(); this.ticking = true; }
    if (!wanted && this.ticking) { ProBadgeFlowClock.release(); this.ticking = false; }
  }

  build() {
    if (this.visible) {
      Text('Pro').fontSize(this.large ? 13 : 10).fontWeight(FontWeight.Bold).fontFamily(AppConfig.fontFamily)
        .fontColor('#29223F').maxLines(1).textAlign(TextAlign.Center)
        .width(this.large ? 46 : 32).height(this.large ? 24 : 18).borderRadius(this.large ? 9 : 7)
        .linearGradient({ angle: 90, colors: proBadgeFlowStops(this.flow ? this.phase : 0.08) })
        .border({ width: 0.5, color: '#90FFFFFF' })
        .accessibilityText('Pro 功能标识')
    }
  }
}
