/** Single owner for the page's mirror of remote sticky modifier state. */
export type RemoteModifierName = 'ctrl' | 'alt' | 'shift' | 'win';

export interface RemoteModifierSnapshot {
  ctrl: boolean;
  alt: boolean;
  shift: boolean;
  win: boolean;
}

export class RemoteModifierStateController {
  private state: RemoteModifierSnapshot = {
    ctrl: false,
    alt: false,
    shift: false,
    win: false
  };

  isDown(modifier: string): boolean {
    if (modifier === 'ctrl') { return this.state.ctrl; }
    if (modifier === 'alt') { return this.state.alt; }
    if (modifier === 'shift') { return this.state.shift; }
    if (modifier === 'win') { return this.state.win; }
    return false;
  }

  setDown(modifier: string, down: boolean): void {
    if (modifier === 'ctrl') {
      this.state.ctrl = down;
    } else if (modifier === 'alt') {
      this.state.alt = down;
    } else if (modifier === 'shift') {
      this.state.shift = down;
    } else if (modifier === 'win') {
      this.state.win = down;
    }
  }

  reset(): void {
    this.state.ctrl = false;
    this.state.alt = false;
    this.state.shift = false;
    this.state.win = false;
  }

  snapshot(): RemoteModifierSnapshot {
    return {
      ctrl: this.state.ctrl,
      alt: this.state.alt,
      shift: this.state.shift,
      win: this.state.win
    };
  }
}
