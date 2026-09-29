import { ProAccessContext } from '../services/pro/ProAccessPolicy';
import { ProAppRuntime } from '../services/pro/ProAppRuntime';
import { ProEntries } from '../services/pro/ProEntries';
// UI binding only. Every business action must also call runtime.run/decision with current context.
@Component
export struct ProFeatureGate {
  @Prop featureId: string = '';
  @Prop context: ProAccessContext = ProAppRuntime.getInstance().context();
  @State revision: number = 0;
  @BuilderParam content: () => void = this.empty;
  private unsubscribe: (() => void) | null = null;
  @Builder empty() {}
  aboutToAppear(): void {
    this.unsubscribe = ProEntries.subscribe((): void => { this.revision++; });
  }
  aboutToDisappear(): void {
    this.unsubscribe?.(); this.unsubscribe = null;
  }
  private visible(_revision: number): boolean {
    return ProEntries.visible(this.featureId, this.context);
  }
  build() {
    if (this.visible(this.revision)) { this.content(); }
  }
}
