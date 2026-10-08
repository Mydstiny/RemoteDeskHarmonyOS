import { HdsSceneController, HdsSceneType, HdsVisualComponent } from '@kit.UIDesignKit';

/**
 * HDS dual-edge flow light adapter for the AI card. The hand-built gradient remains underneath as a compatibility
 * fallback; when the current device exposes the HDS scene, this component supplies the platform light motion around
 * the card edge. It is intentionally a small edge layer, never a full-screen material wash.
 */
@Component
export struct HdsImmersiveEdgeLight {
  @Prop @Watch('onActiveChanged') active: boolean = false;
  private readonly controller: HdsSceneController = new HdsSceneController();

  private onActiveChanged(): void {
    if (this.active) { this.controller.start(); }
    else { this.controller.pause(); }
  }

  aboutToAppear(): void {
    this.controller.setSceneParams({
      backgroundMaskColors: ['#00000000'],
      firstEdgeFlowLight: { startPos: 0, endPos: 0.48, color: '#42CBF7' },
      secondEdgeFlowLight: { startPos: 0.52, endPos: 1, color: '#FF678C' }
    });
    if (this.active) { this.controller.start(); }
  }

  aboutToDisappear(): void { this.controller.stop(); }

  build() {
    HdsVisualComponent() {
      Row().width('100%').height('100%')
    }
    .scene(HdsSceneType.DUAL_EDGE_FLOW_LIGHT_WITH_BACKGROUND_MASK, this.controller)
    .width('100%').height('100%')
    .opacity(this.active ? 1 : 0)
    .hitTestBehavior(HitTestMode.None)
  }
}
