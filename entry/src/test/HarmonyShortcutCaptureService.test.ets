import { describe, expect, it } from '@ohos/hypium';
import {
  HarmonyCapturedSystemKeyEvent,
  HarmonyShortcutCaptureService,
  HarmonyShortcutConsumerCallback,
  HarmonyShortcutConsumerPort,
  HarmonyShortcutConsumerSubscription,
  HarmonyShortcutRetryScheduler
} from '../main/ets/services/HarmonyShortcutCaptureService';

class FakeHarmonyShortcutConsumerSubscription implements HarmonyShortcutConsumerSubscription {
  readonly keyCode: number;
  private readonly owner: FakeHarmonyShortcutConsumerPort;
  private readonly callback: HarmonyShortcutConsumerCallback;

  constructor(keyCode: number, owner: FakeHarmonyShortcutConsumerPort,
    callback: HarmonyShortcutConsumerCallback) {
    this.keyCode = keyCode;
    this.owner = owner;
    this.callback = callback;
  }

  release(): void {
    this.owner.release(this.keyCode, this.callback);
  }
}

class FakeHarmonyShortcutConsumerPort implements HarmonyShortcutConsumerPort {
  callbacks: Map<number, HarmonyShortcutConsumerCallback> =
    new Map<number, HarmonyShortcutConsumerCallback>();
  subscribeFailures: Map<number, number> = new Map<number, number>();
  releaseFailures: Map<number, number> = new Map<number, number>();
  released: number[] = [];

  subscribe(keyCode: number,
    callback: HarmonyShortcutConsumerCallback): HarmonyShortcutConsumerSubscription {
    const failures: number = this.subscribeFailures.get(keyCode) ?? 0;
    if (failures > 0) {
      this.subscribeFailures.set(keyCode, failures - 1);
      throw new Error('injected subscribe failure');
    }
    this.callbacks.set(keyCode, callback);
    return new FakeHarmonyShortcutConsumerSubscription(keyCode, this, callback);
  }

  release(keyCode: number, callback: HarmonyShortcutConsumerCallback): void {
    const releaseFailures: number = this.releaseFailures.get(keyCode) ?? 0;
    if (releaseFailures > 0) {
      this.releaseFailures.set(keyCode, releaseFailures - 1);
      throw new Error('injected release failure');
    }
    if (this.callbacks.get(keyCode) === callback) {
      this.callbacks.delete(keyCode);
    }
    this.released.push(keyCode);
  }

  emit(keyCode: number, action: number, deviceId: number): void {
    const callback: HarmonyShortcutConsumerCallback | undefined = this.callbacks.get(keyCode);
    if (callback !== undefined) { callback({ action, keyCode, deviceId }); }
  }
}

class FakeHarmonyShortcutRetryScheduler implements HarmonyShortcutRetryScheduler {
  callbacks: Array<(() => void) | null> = [];

  schedule(callback: () => void, _delayMs: number): number {
    this.callbacks.push(callback);
    return this.callbacks.length;
  }

  cancel(timerId: number): void {
    const index: number = timerId - 1;
    if (index >= 0 && index < this.callbacks.length) { this.callbacks[index] = null; }
  }

  pendingCount(): number {
    return this.callbacks.filter((callback: (() => void) | null): boolean =>
      callback !== null).length;
  }

  runNext(): void {
    for (let index: number = 0; index < this.callbacks.length; index++) {
      const callback: (() => void) | null = this.callbacks[index];
      if (callback === null) { continue; }
      this.callbacks[index] = null;
      callback();
      return;
    }
  }
}

export default function harmonyShortcutCaptureServiceTest(): void {
  describe('HarmonyShortcutCaptureService', (): void => {
    it('executes_callbacks_and_synthesizes_one_release_on_owner_switch', 0, (): void => {
      const port = new FakeHarmonyShortcutConsumerPort();
      const scheduler = new FakeHarmonyShortcutRetryScheduler();
      const service = new HarmonyShortcutCaptureService(port, scheduler);
      const first: HarmonyCapturedSystemKeyEvent[] = [];
      const second: HarmonyCapturedSystemKeyEvent[] = [];
      expect(service.activate('first', (event: HarmonyCapturedSystemKeyEvent): void => {
        first.push(event);
      }, [16])).assertEqual(1);
      port.emit(16, 1, 7);
      port.emit(16, 1, 7);
      expect(first.length).assertEqual(2);

      expect(service.activate('second', (event: HarmonyCapturedSystemKeyEvent): void => {
        second.push(event);
      }, [17])).assertEqual(1);
      expect(first.length).assertEqual(3);
      expect(first[2].pressed).assertFalse();
      expect(first[2].cancelled).assertTrue();
      expect(first[2].keyCode).assertEqual(16);
      port.emit(17, 1, 9);
      port.emit(17, 2, 9);
      expect(second.length).assertEqual(2);
      expect(second[0].pressed).assertTrue();
      expect(second[1].pressed).assertFalse();
      service.deactivate('second');
      expect(port.callbacks.size).assertEqual(0);
    });

    it('retries_partial_registration_without_duplicate_callbacks', 0, (): void => {
      const port = new FakeHarmonyShortcutConsumerPort();
      const scheduler = new FakeHarmonyShortcutRetryScheduler();
      const service = new HarmonyShortcutCaptureService(port, scheduler);
      port.subscribeFailures.set(17, 1);
      expect(service.activate('owner', (_event: HarmonyCapturedSystemKeyEvent): void => {},
        [16, 17])).assertEqual(1);
      expect(service.activate('owner', (_event: HarmonyCapturedSystemKeyEvent): void => {},
        [16, 17])).assertEqual(2);
      expect(port.callbacks.size).assertEqual(2);
      service.deactivate('owner');
    });

    it('retries_failed_unsubscription_until_local_key_is_released', 0, (): void => {
      const port = new FakeHarmonyShortcutConsumerPort();
      const scheduler = new FakeHarmonyShortcutRetryScheduler();
      const service = new HarmonyShortcutCaptureService(port, scheduler);
      port.releaseFailures.set(16, 1);
      service.activate('owner', (_event: HarmonyCapturedSystemKeyEvent): void => {}, [16]);
      service.deactivate('owner');
      expect(port.callbacks.has(16)).assertTrue();
      expect(scheduler.pendingCount()).assertEqual(1);
      scheduler.runNext();
      expect(port.callbacks.has(16)).assertFalse();
      expect(port.released.length).assertEqual(1);
      expect(scheduler.pendingCount()).assertEqual(0);
    });

    it('rejects_queued_callbacks_from_the_previous_capture_owner', 0, (): void => {
      const port = new FakeHarmonyShortcutConsumerPort();
      const scheduler = new FakeHarmonyShortcutRetryScheduler();
      const service = new HarmonyShortcutCaptureService(port, scheduler);
      const first: HarmonyCapturedSystemKeyEvent[] = [];
      const second: HarmonyCapturedSystemKeyEvent[] = [];
      service.activate('first', (event: HarmonyCapturedSystemKeyEvent): void => {
        first.push(event);
      }, [16]);
      const oldCallback: HarmonyShortcutConsumerCallback | undefined = port.callbacks.get(16);
      service.activate('second', (event: HarmonyCapturedSystemKeyEvent): void => {
        second.push(event);
      }, [16]);
      if (oldCallback !== undefined) {
        oldCallback({ action: 1, keyCode: 16, deviceId: 3 });
      }
      expect(first.length).assertEqual(0);
      expect(second.length).assertEqual(0);
      port.emit(16, 1, 3);
      expect(second.length).assertEqual(1);
      service.deactivate('second');
    });
  });
}
