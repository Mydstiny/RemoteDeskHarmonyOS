import { OverlayPlacement, emptyOverlayPlacement } from '../services/RemoteOverlayViewportPolicy';
import { RemoteShortcutAction } from '../services/RemoteShortcutCatalog';

export interface RemoteShortcutSurfaceActions {
  onAction: (actionId: string) => void;
  onRailDrag: (offsetX: number, offsetY: number) => void;
}

@Component
export struct RemoteShortcutSurface {
  @StorageProp('accentColor') accentColor: string = '#007DFF';
  @Prop deviceClass: 'pc' | 'pad' | 'phone' = 'pc';
  @Prop placement: OverlayPlacement = emptyOverlayPlacement();
  @Prop actions: Array<RemoteShortcutAction> = [];
  @Prop measurementGeneration: number = -1;
  @Prop measurementToken: string = '';
  surfaceActions: RemoteShortcutSurfaceActions = {
    onAction: (_actionId: string): void => {},
    onRailDrag: (_offsetX: number, _offsetY: number): void => {}
  };

  @Builder
  private actionButton(action: RemoteShortcutAction) {
    Button() {
      Column() {
        Text(action.label)
          .fontSize(this.deviceClass === 'pc' ? 13 : 11)
          .fontWeight(FontWeight.Medium)
          .fontColor(action.enabled ? '#FFFFFF' : 'rgba(255,255,255,0.45)')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(action.subtitle)
          .fontSize(9)
          .fontColor(action.enabled ? 'rgba(255,255,255,0.72)' : 'rgba(255,255,255,0.30)')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .justifyContent(FlexAlign.Center)
    }
    .enabled(action.enabled)
    .height(44)
    .width(this.deviceClass === 'pc' ? 92 : 64)
    .padding({ left: 4, right: 4 })
    .borderRadius(9)
    .backgroundColor(action.enabled ? this.accentColor : 'rgba(80,84,92,0.72)')
    .accessibilityText(action.accessibilityText)
    .onClick((): void => { this.surfaceActions.onAction(action.id); });
  }

  private visibleActions(): Array<RemoteShortcutAction> {
    const maximum: number = this.actions.length > 0 && this.actions[0].id === 'terminalCtrlC' ? 5 : 3;
    return this.actions.slice(0, maximum);
  }

  private hiddenByPlacement(): boolean {
    return this.placement.fallback === 'hidden' ||
      (this.placement.expandedRect.width <= 0 && this.placement.railRect.width <= 0);
  }

  private areaChangeHandler(): (oldArea: Area, nextArea: Area) => void {
    const generation: number = this.measurementGeneration;
    const token: string = this.measurementToken;
    return (_oldArea: Area, nextArea: Area): void => {
      const width: number = nextArea.width as number;
      const height: number = nextArea.height as number;
      const x: number = nextArea.globalPosition.x as number;
      const y: number = nextArea.globalPosition.y as number;
      if (generation < 0 || token.length === 0 || !Number.isFinite(width) ||
        !Number.isFinite(height) || !Number.isFinite(x) || !Number.isFinite(y) ||
        width <= 0 || height <= 0) { return; }
      this.onMeasured(generation, token, x, y, width, height);
    };
  }

  onMeasured: (generation: number, measurementToken: string,
    x: number, y: number, width: number, height: number) => void =
    (_generation: number, _token: string, _x: number, _y: number,
      _width: number, _height: number): void => {};

  build() {
    if (this.hiddenByPlacement()) {
      Column().width(0).height(0).hitTestBehavior(HitTestMode.None)
    } else if (this.deviceClass === 'pc') {
      Row({ space: 6 }) {
        ForEach(this.visibleActions(), (action: RemoteShortcutAction): void => {
          this.actionButton(action);
        }, (action: RemoteShortcutAction): string => action.id)
      }
      .height(52)
      .padding({ left: 6, right: 6 })
      .backgroundColor('rgba(20,24,32,0.86)')
      .borderRadius(10)
      .position({ x: this.placement.expandedRect.x, y: this.placement.expandedRect.y })
      .onAreaChange(this.areaChangeHandler())
        .hitTestBehavior(HitTestMode.Default)
    } else {
      Column({ space: 6 }) {
        ForEach(this.visibleActions(), (action: RemoteShortcutAction): void => {
          this.actionButton(action);
        }, (action: RemoteShortcutAction): string => action.id)
      }
      .width(Math.max(44, this.placement.railRect.width))
      .padding({ left: 4, right: 4, top: 4, bottom: 4 })
      .backgroundColor('rgba(20,24,32,0.86)')
      .borderRadius(12)
      .onAreaChange(this.areaChangeHandler())
      .gesture(PanGesture({ fingers: 1, distance: 5 })
        .onActionEnd((event: GestureEvent): void => {
          this.surfaceActions.onRailDrag(event.offsetX, event.offsetY);
        }))
      .position({ x: this.placement.railRect.x, y: this.placement.railRect.y })
    }
  }
}
