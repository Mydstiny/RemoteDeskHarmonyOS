export interface TotpBrandTickerClock {
  every(periodMs: number, callback: () => void): number;
  cancel(timerId: number): void;
}

export function shouldRunTotpBrandTicker(
  pageLocked: boolean,
  entryLocked: boolean,
  appInBackground: boolean
): boolean {
  return !pageLocked && !entryLocked && !appInBackground;
}

class SystemTotpBrandTickerClock implements TotpBrandTickerClock {
  every(periodMs: number, callback: () => void): number {
    return setInterval(callback, periodMs);
  }

  cancel(timerId: number): void {
    clearInterval(timerId);
  }
}

const SYSTEM_CLOCK: TotpBrandTickerClock = new SystemTotpBrandTickerClock();

export class TotpBrandTicker {
  private static shared: TotpBrandTicker | null = null;
  private readonly clock: TotpBrandTickerClock;
  private readonly listeners: Array<() => void> = [];
  private timerId: number = -1;

  constructor(clock: TotpBrandTickerClock = SYSTEM_CLOCK) {
    this.clock = clock;
  }

  static sharedTicker(): TotpBrandTicker {
    if (TotpBrandTicker.shared === null) {
      TotpBrandTicker.shared = new TotpBrandTicker();
    }
    return TotpBrandTicker.shared;
  }

  subscribe(listener: () => void): () => void {
    this.listeners.push(listener);
    this.ensureStarted();
    let removed: boolean = false;
    return (): void => {
      if (removed) { return; }
      removed = true;
      const index: number = this.listeners.indexOf(listener);
      if (index >= 0) { this.listeners.splice(index, 1); }
      this.stopIfUnused();
    };
  }

  subscriberCount(): number {
    return this.listeners.length;
  }

  isRunning(): boolean {
    return this.timerId >= 0;
  }

  private ensureStarted(): void {
    if (this.timerId >= 0) { return; }
    this.timerId = this.clock.every(1000, (): void => {
      const snapshot: Array<() => void> = this.listeners.slice();
      for (let index = 0; index < snapshot.length; index++) {
        snapshot[index]();
      }
    });
  }

  private stopIfUnused(): void {
    if (this.listeners.length > 0 || this.timerId < 0) { return; }
    this.clock.cancel(this.timerId);
    this.timerId = -1;
  }
}
