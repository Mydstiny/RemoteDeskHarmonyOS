import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { AppConfig } from '../common/Theme';

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

// One seamless period of the iridescent colors; the strip holds two periods and slides by one.
const FLOW_PERIOD: number = 64;
const FLOW_COLORS: Array<[ResourceColor, number]> = [['#B9F3EA', 0], ['#CDC9FF', 0.125], ['#F4C8E5', 0.25],
  ['#F9E3B8', 0.375], ['#B9F3EA', 0.5], ['#CDC9FF', 0.625], ['#F4C8E5', 0.75], ['#F9E3B8', 0.875], ['#B9F3EA', 1]];

/**
 * Product marker only; never grants access or represents a payment status on its own.
 * Iridescent, flowing by default; both the flow and the marker itself can be turned off in
 * 设置 > Pro 功能.
 */
@Component
export struct ProBadge {
  @Prop large: boolean = false;
  @StorageProp('proBadgeFlow') @Watch('onFlowChange') flow: boolean = true;
  @StorageProp('proBadgeVisible') visible: boolean = true;
  @State shift: number = 0;

  aboutToAppear(): void { ProBadgePreferences.load(getContext(this)); }
  // Turning the flow back on restarts the loop from its first frame.
  onFlowChange(): void {
    if (!this.flow) { return; }
    this.shift = 0;
    setTimeout((): void => { this.shift = -FLOW_PERIOD; }, 16);
  }

  build() {
    if (this.visible) {
      Stack({ alignContent: Alignment.Start }) {
        Row().width(FLOW_PERIOD * 2).height('100%')
          .linearGradient({ angle: 90, colors: FLOW_COLORS })
          .translate({ x: this.flow ? this.shift : -FLOW_PERIOD / 4 })
          .animation(this.flow ? { duration: 2600, curve: Curve.Linear, iterations: -1, playMode: PlayMode.Normal } :
            { duration: 0 })
        Text('Pro').fontSize(this.large ? 13 : 10).fontWeight(FontWeight.Bold).fontFamily(AppConfig.fontFamily)
          .fontColor('#29223F').maxLines(1).width('100%').textAlign(TextAlign.Center)
      }
      .width(this.large ? 46 : 32).height(this.large ? 24 : 18).borderRadius(this.large ? 9 : 7).clip(true)
      .border({ width: 0.5, color: '#90FFFFFF' })
      .onAppear((): void => { this.shift = -FLOW_PERIOD; })
      .accessibilityText('Pro 功能标识')
    }
  }
}
