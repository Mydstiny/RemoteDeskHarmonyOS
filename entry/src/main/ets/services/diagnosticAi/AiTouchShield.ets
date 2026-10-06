/**
 * The AI's floating orb and its small chat live in a non-modal dialog layer, and such a layer lets every touch through
 * to the page as well: a remote session's canvas (which reads raw touches) moved the remote mouse while the orb or its
 * chat was dragged. The layer registers where its orb and chat are; a session canvas leaves alone every touch that
 * starts there, until that finger lifts — the remote side never sees its press, its moves or its release.
 */
export class AiTouchShield {
  private static areas: Map<string, (x: number, y: number) => boolean> = new Map<string, (x: number, y: number) => boolean>();

  /** `hit(x, y)`: window coordinates (vp) on the orb or its chat. */
  static register(id: string, hit: (x: number, y: number) => boolean): void { AiTouchShield.areas.set(id, hit); }

  static unregister(id: string): void { AiTouchShield.areas.delete(id); }

  static covers(x: number, y: number): boolean {
    let covered: boolean = false;
    AiTouchShield.areas.forEach((hit: (x: number, y: number) => boolean): void => {
      if (!covered) {
        try { covered = hit(x, y); } catch (_error) { /* a layer going away */ }
      }
    });
    return covered;
  }
}

/** One canvas's view of the shield: the fingers that went down on the AI, kept out until they lift. */
export class AiTouchShieldTracker {
  private ids: number[] = [];

  /** True: this touch event belongs to the AI and the canvas must not act on it. */
  shields(event: TouchEvent): boolean {
    const changed: TouchObject[] = event.changedTouches !== undefined && event.changedTouches.length > 0 ?
      event.changedTouches : event.touches;
    if (changed.length === 0) { return false; }
    if (event.type === TouchType.Down) {
      const finger: TouchObject = changed[0];
      if (AiTouchShield.covers(finger.windowX, finger.windowY)) {
        if (this.ids.indexOf(finger.id) < 0) { this.ids.push(finger.id); }
        return true;
      }
      return false;
    }
    const mine: boolean = changed.every((t: TouchObject): boolean => this.ids.indexOf(t.id) >= 0);
    if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
      changed.forEach((t: TouchObject): void => {
        const at: number = this.ids.indexOf(t.id);
        if (at >= 0) { this.ids.splice(at, 1); }
      });
      if (event.type === TouchType.Cancel) { this.ids = []; }
    }
    return mine;
  }
}
