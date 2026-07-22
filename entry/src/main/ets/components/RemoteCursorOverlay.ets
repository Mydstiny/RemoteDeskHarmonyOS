/**
 * RemoteCursorOverlay.ets — isolated cursor layer for Phone/Pad sessions.
 *
 * Cursor coordinates change much more frequently than the remote session
 * controls. Keeping this layer in its own custom component prevents a cursor
 * frame from rebuilding the XComponent, input overlay, diagnostics dock and
 * session controls together.
 */
import { image } from '@kit.ImageKit';

@Observed
export class RemoteCursorOverlayState {
  viewRevision: number = 0;
  showCircle: boolean = false;
  circleX: number = 0;
  circleY: number = 0;
  circleOuterSize: number = 28;
  circleRingSize: number = 18;
  circleDotSize: number = 3;
  circleColor: string = '#00D1FF';
  circleDrag: boolean = false;
  showArrow: boolean = false;
  arrowInside: boolean = false;
  arrowPixelMap: image.PixelMap | null = null;
  arrowWidth: number = 0;
  arrowHeight: number = 0;
  arrowX: number = 0;
  arrowY: number = 0;
}

@Component
export struct RemoteCursorOverlay {
  @ObjectLink cursor: RemoteCursorOverlayState;

  build() {
    Stack() {
      // Read the revision in the component scope. Only this component needs
      // to be invalidated for a cursor frame.
      if (this.cursor.viewRevision >= 0) {
        if (this.cursor.showCircle) {
          Stack() {
              Stack()
                .width(this.cursor.circleRingSize)
                .height(this.cursor.circleRingSize)
                .borderRadius(this.cursor.circleRingSize / 2)
                .backgroundColor('rgba(0,0,0,0.08)')
                .border({ width: this.cursor.circleDrag ? 2 : 1.5, color: this.cursor.circleColor })
              Column()
                .width(this.cursor.circleDotSize)
                .height(this.cursor.circleDotSize)
                .borderRadius(2)
                .backgroundColor(this.cursor.circleColor)
          }
            .width(this.cursor.circleOuterSize)
            .height(this.cursor.circleOuterSize)
            .position({ x: this.cursor.circleX - this.cursor.circleOuterSize / 2,
              y: this.cursor.circleY - this.cursor.circleOuterSize / 2 })
        }
        if (this.cursor.showArrow && this.cursor.arrowInside && this.cursor.arrowPixelMap !== null) {
          Image(this.cursor.arrowPixelMap)
            .width(this.cursor.arrowWidth)
            .height(this.cursor.arrowHeight)
            .objectFit(ImageFit.Contain)
            .position({ x: this.cursor.arrowX, y: this.cursor.arrowY })
        }
      }
    }
    .width('100%')
    .height('100%')
    .hitTestBehavior(HitTestMode.None)
  }
}
