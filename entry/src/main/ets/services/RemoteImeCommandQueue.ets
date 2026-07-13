/**
 * RemoteImeCommandQueue.ets - ordered, privacy-safe remote IME commands.
 *
 * A command is consumed exactly once by the page-level dispatcher.  Keeping
 * text and cursor commands in one FIFO prevents a large gesture from being
 * overtaken by text committed immediately afterwards.
 */

export enum RemoteImeCommandKind {
  TEXT = 0,
  KEY_TAPS = 1
}

export interface RemoteImeCommand {
  kind: RemoteImeCommandKind;
  text: string;
  keyCode: number;
  tapCount: number;
  generation: number;
  source: string;
}

export class RemoteImeCommandQueue {
  private commands: RemoteImeCommand[] = [];

  enqueueText(text: string, generation: number, source: string): void {
    if (text.length === 0) {
      return;
    }
    this.commands.push({
      kind: RemoteImeCommandKind.TEXT,
      text,
      keyCode: 0,
      tapCount: 0,
      generation,
      source
    });
  }

  enqueueKeyTaps(keyCode: number, count: number, generation: number, source: string): void {
    if (count <= 0) {
      return;
    }
    this.commands.push({
      kind: RemoteImeCommandKind.KEY_TAPS,
      text: '',
      keyCode,
      tapCount: count,
      generation,
      source
    });
  }

  shift(): RemoteImeCommand | null {
    return this.commands.length > 0 ? this.commands.shift()! : null;
  }

  pushFront(command: RemoteImeCommand): void {
    this.commands.unshift(command);
  }

  clear(): void {
    this.commands = [];
  }

  size(): number {
    return this.commands.length;
  }
}
