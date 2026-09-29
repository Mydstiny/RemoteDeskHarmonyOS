import { ProAccessContext } from '../services/pro/ProAccessPolicy';
import { ProAppRuntime } from '../services/pro/ProAppRuntime';
import { ProFeatureVisibility } from '../services/pro/ProFeatureVisibility';
// UI binding only. Every business action must also call runtime.run/decision with current context.
@Component
export struct ProFeatureGate {
  @Prop featureId: string = '';
  @Prop context: ProAccessContext = ProAppRuntime.getInstance().context();
  @State revision: number = 0;
  @BuilderParam content: () => void = this.empty;
  private unsubscribe: (() => void) | null = null;
  private visibilityUnsubscribe: (() => void) | null = null;
  @Builder empty() {}
  aboutToAppear(): void {
    this.unsubscribe = ProAppRuntime.getInstance().runtime.subscribe((): void => { this.revision++; });
    this.visibilityUnsubscribe = ProFeatureVisibility.getInstance().subscribe((): void => { this.revision++; });
  }
  aboutToDisappear(): void {
    this.unsubscribe?.(); this.unsubscribe = null;
    this.visibilityUnsubscribe?.(); this.visibilityUnsubscribe = null;
  }
  private visible(_revision: number): boolean {
    return ProFeatureVisibility.getInstance().isVisible(this.featureId) &&
      ProAppRuntime.getInstance().runtime.decision(this.featureId, this.context).visible;
  }
  build() {
    if (this.visible(this.revision)) { this.content(); }
  }
}
