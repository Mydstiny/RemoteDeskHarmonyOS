import { Action, inputConsumer, KeyCode, KeyEvent as InputConsumerKeyEvent } from '@kit.InputKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  harmonyShortcutForgetPressedKey,
  harmonyShortcutMissingSubscriptionKeyCodes,
  harmonyShortcutPressedKeysForRelease,
  harmonyShortcutRememberPressedKey,
  HarmonyShortcutPressedKeyIdentity
} from './HarmonyShortcutBlockingPolicy';

export interface HarmonyCapturedSystemKeyEvent {
  keyCode: number;
  pressed: boolean;
  cancelled: boolean;
  deviceId: number;
}

type HarmonyCapturedSystemKeyHandler = (event: HarmonyCapturedSystemKeyEvent) => void;
type HarmonyInputConsumerCallback = (event: InputConsumerKeyEvent) => void;

export interface HarmonyShortcutConsumerEvent {
  action: number;
  keyCode: number;
  deviceId: number;
}

export type HarmonyShortcutConsumerCallback =
  (event: HarmonyShortcutConsumerEvent) => void;

export interface HarmonyShortcutConsumerSubscription {
  keyCode: number;
  release(): void;
}

export interface HarmonyShortcutConsumerPort {
  subscribe(keyCode: number,
    callback: HarmonyShortcutConsumerCallback): HarmonyShortcutConsumerSubscription;
}

export interface HarmonyShortcutRetryScheduler {
  schedule(callback: () => void, delayMs: number): number;
  cancel(timerId: number): void;
}

class PlatformHarmonyShortcutConsumerSubscription implements HarmonyShortcutConsumerSubscription {
  readonly keyCode: number;
  private readonly callback: HarmonyInputConsumerCallback;

  constructor(keyCode: number, callback: HarmonyInputConsumerCallback) {
    this.keyCode = keyCode;
    this.callback = callback;
  }

  release(): void {
    inputConsumer.off('keyPressed', this.callback);
  }
}

class PlatformHarmonyShortcutConsumerPort implements HarmonyShortcutConsumerPort {
  subscribe(keyCode: number,
    callback: HarmonyShortcutConsumerCallback): HarmonyShortcutConsumerSubscription {
    const platformCallback: HarmonyInputConsumerCallback =
      (event: InputConsumerKeyEvent): void => {
        callback({
          action: event.action,
          keyCode: event.key === undefined || event.key === null ?
            keyCode : event.key.code,
          deviceId: event.key === undefined || event.key === null ?
            -1 : event.key.deviceId
        });
      };
    inputConsumer.on('keyPressed', {
      key: keyCode,
      action: 2,
      isRepeat: true
    }, platformCallback);
    return new PlatformHarmonyShortcutConsumerSubscription(keyCode, platformCallback);
  }
}

class PlatformHarmonyShortcutRetryScheduler implements HarmonyShortcutRetryScheduler {
  schedule(callback: () => void, delayMs: number): number {
    return setTimeout(callback, delayMs);
  }

  cancel(timerId: number): void { clearTimeout(timerId); }
}

class HarmonyShortcutTrackedSubscription {
  readonly owner: string;
  readonly activationEpoch: number;
  readonly subscription: HarmonyShortcutConsumerSubscription;

  constructor(owner: string, activationEpoch: number,
    subscription: HarmonyShortcutConsumerSubscription) {
    this.owner = owner;
    this.activationEpoch = activationEpoch;
    this.subscription = subscription;
  }

  keyCode(): number { return this.subscription.keyCode; }

  release(): void { this.subscription.release(); }
}

/**
 * Foreground-only bridge for the API 23 system-function keys that ordinary
 * ArkUI onKeyPreIme cannot receive before HarmonyOS applies its local action.
 *
 * API 23 documents keyPressed interception for volume and the three media
 * keys below. F1-F24 and ordinary combinations remain owned by each session's
 * onKeyPreIme path; registering undocumented key codes here would fail with
 * parameter error on released devices.
 */
export class HarmonyShortcutCaptureService {
  private static instance: HarmonyShortcutCaptureService | null = null;
  private ownerSequence: number = 0;
  private activationEpoch: number = 0;
  private activeOwner: string = '';
  private activeHandler: HarmonyCapturedSystemKeyHandler | null = null;
  private subscriptions: HarmonyShortcutTrackedSubscription[] = [];
  private desiredKeyCodes: number[] = [];
  private pressedKeys: HarmonyShortcutPressedKeyIdentity[] = [];
  private releaseRetryTimer: number = -1;
  private readonly consumerPort: HarmonyShortcutConsumerPort;
  private readonly retryScheduler: HarmonyShortcutRetryScheduler;

  constructor(
    consumerPort: HarmonyShortcutConsumerPort =
      new PlatformHarmonyShortcutConsumerPort(),
    retryScheduler: HarmonyShortcutRetryScheduler =
      new PlatformHarmonyShortcutRetryScheduler()
  ) {
    this.consumerPort = consumerPort;
    this.retryScheduler = retryScheduler;
  }

  static getInstance(): HarmonyShortcutCaptureService {
    if (HarmonyShortcutCaptureService.instance === null) {
      HarmonyShortcutCaptureService.instance = new HarmonyShortcutCaptureService();
    }
    return HarmonyShortcutCaptureService.instance;
  }

  createOwner(prefix: string): string {
    this.ownerSequence++;
    return prefix + '-' + this.ownerSequence.toString();
  }

  activate(owner: string, handler: HarmonyCapturedSystemKeyHandler,
    requestedKeyCodes: number[]): number {
    const normalizedOwner: string = owner.trim();
    if (normalizedOwner.length === 0) { return 0; }
    const desired: number[] = this.normalizeRequestedKeyCodes(requestedKeyCodes);
    const registrationChanged: boolean = this.activeOwner !== normalizedOwner ||
      !this.sameKeyCodes(this.desiredKeyCodes, desired);
    if (registrationChanged) {
      this.cancelActivePressedKeys();
      this.activationEpoch += 1;
    }
    this.activeOwner = normalizedOwner;
    this.activeHandler = handler;
    this.desiredKeyCodes = desired;
    this.reconcileSubscriptions();
    hilog.info(0x0014, 'HarmonyShortcutCapture',
      'activate owner=' + normalizedOwner +
      ' subscriptions=' + this.requestedSubscriptionCount().toString());
    return this.requestedSubscriptionCount();
  }

  deactivate(owner: string): void {
    if (owner.trim().length === 0 || owner !== this.activeOwner) { return; }
    this.cancelActivePressedKeys();
    this.activeOwner = '';
    this.activeHandler = null;
    this.desiredKeyCodes = [];
    this.activationEpoch += 1;
    this.reconcileSubscriptions();
    hilog.info(0x0014, 'HarmonyShortcutCapture', 'deactivate');
  }

  private supportedKeyCodes(): number[] {
    return [
      KeyCode.KEYCODE_VOLUME_UP,
      KeyCode.KEYCODE_VOLUME_DOWN,
      KeyCode.KEYCODE_MEDIA_PLAY_PAUSE,
      KeyCode.KEYCODE_MEDIA_NEXT,
      KeyCode.KEYCODE_MEDIA_PREVIOUS
    ];
  }

  private normalizeRequestedKeyCodes(requested: number[]): number[] {
    const supported: number[] = this.supportedKeyCodes();
    const normalized: number[] = [];
    for (let index: number = 0; index < requested.length; index++) {
      const keyCode: number = requested[index];
      if (supported.indexOf(keyCode) >= 0 && normalized.indexOf(keyCode) < 0) {
        normalized.push(keyCode);
      }
    }
    return normalized;
  }

  private sameKeyCodes(left: number[], right: number[]): boolean {
    if (left.length !== right.length) { return false; }
    for (let index: number = 0; index < left.length; index++) {
      if (right.indexOf(left[index]) < 0) { return false; }
    }
    return true;
  }

  private requestedSubscriptionCount(): number {
    let count: number = 0;
    for (let index: number = 0; index < this.subscriptions.length; index++) {
      const entry: HarmonyShortcutTrackedSubscription = this.subscriptions[index];
      if (entry.owner === this.activeOwner &&
        entry.activationEpoch === this.activationEpoch &&
        this.desiredKeyCodes.indexOf(entry.keyCode()) >= 0) { count++; }
    }
    return count;
  }

  private subscriptionKeyCodes(): number[] {
    const active: number[] = [];
    for (let index: number = 0; index < this.subscriptions.length; index++) {
      const entry: HarmonyShortcutTrackedSubscription = this.subscriptions[index];
      if (entry.owner === this.activeOwner &&
        entry.activationEpoch === this.activationEpoch) {
        active.push(entry.keyCode());
      }
    }
    return active;
  }

  private reconcileSubscriptions(): void {
    this.releaseUnrequestedSubscriptions();
    this.subscribeMissingSubscriptions();
    this.updateReleaseRetry();
  }

  private subscribeMissingSubscriptions(): void {
    const keys: number[] = harmonyShortcutMissingSubscriptionKeyCodes(
      this.desiredKeyCodes, this.subscriptionKeyCodes());
    for (let index: number = 0; index < keys.length; index++) {
      const configuredKeyCode: number = keys[index];
      const registrationOwner: string = this.activeOwner;
      const registrationEpoch: number = this.activationEpoch;
      const callback: HarmonyShortcutConsumerCallback =
        (event: HarmonyShortcutConsumerEvent): void => {
          const handler: HarmonyCapturedSystemKeyHandler | null = this.activeHandler;
          if (this.activeOwner !== registrationOwner ||
            this.activationEpoch !== registrationEpoch || handler === null ||
            this.desiredKeyCodes.indexOf(configuredKeyCode) < 0) { return; }
          const cancelled: boolean = event.action === Action.CANCEL;
          const captured: HarmonyCapturedSystemKeyEvent = {
            keyCode: event.keyCode,
            pressed: event.action === Action.DOWN,
            cancelled,
            deviceId: event.deviceId
          };
          if (captured.pressed) {
            this.rememberPressedKey(captured);
          } else {
            this.forgetPressedKey(event.keyCode, event.deviceId);
          }
          handler(captured);
        };
      try {
        const subscription: HarmonyShortcutConsumerSubscription =
          this.consumerPort.subscribe(configuredKeyCode, callback);
        this.subscriptions.push(new HarmonyShortcutTrackedSubscription(
          registrationOwner, registrationEpoch, subscription));
      } catch (error) {
        hilog.warn(0x0014, 'HarmonyShortcutCapture',
          'subscription rejected key=' + configuredKeyCode.toString() +
          ' error=' + JSON.stringify(error));
      }
    }
  }

  private rememberPressedKey(event: HarmonyCapturedSystemKeyEvent): void {
    this.pressedKeys = harmonyShortcutRememberPressedKey(
      this.pressedKeys, event.keyCode, event.deviceId);
  }

  private forgetPressedKey(keyCode: number, deviceId: number): void {
    this.pressedKeys = harmonyShortcutForgetPressedKey(this.pressedKeys, keyCode, deviceId);
  }

  /** Release remote key state before a preference, page or window changes owner. */
  private cancelActivePressedKeys(): void {
    const handler: HarmonyCapturedSystemKeyHandler | null = this.activeHandler;
    const pressed: HarmonyShortcutPressedKeyIdentity[] =
      harmonyShortcutPressedKeysForRelease(this.pressedKeys);
    this.pressedKeys = [];
    if (handler === null) { return; }
    for (let index: number = 0; index < pressed.length; index++) {
      try {
        handler({
          keyCode: pressed[index].keyCode,
          pressed: false,
          cancelled: true,
          deviceId: pressed[index].deviceId
        });
      } catch (error) {
        hilog.warn(0x0014, 'HarmonyShortcutCapture',
          'cancel pressed key failed key=' + pressed[index].keyCode.toString() +
          ' error=' + JSON.stringify(error));
      }
    }
  }

  private releaseUnrequestedSubscriptions(): void {
    const current: HarmonyShortcutTrackedSubscription[] = this.subscriptions;
    const retained: HarmonyShortcutTrackedSubscription[] = [];
    for (let index: number = 0; index < current.length; index++) {
      const stale: boolean = current[index].owner !== this.activeOwner ||
        current[index].activationEpoch !== this.activationEpoch ||
        this.desiredKeyCodes.indexOf(current[index].keyCode()) < 0;
      if (!stale) {
        retained.push(current[index]);
        continue;
      }
      try {
        current[index].release();
      } catch (error) {
        retained.push(current[index]);
        hilog.warn(0x0014, 'HarmonyShortcutCapture',
          'unsubscribe unrequested key failed key=' + current[index].keyCode().toString() +
          ' error=' + JSON.stringify(error));
      }
    }
    this.subscriptions = retained;
  }

  private hasUnrequestedSubscription(): boolean {
    for (let index: number = 0; index < this.subscriptions.length; index++) {
      if (this.subscriptions[index].owner !== this.activeOwner ||
        this.subscriptions[index].activationEpoch !== this.activationEpoch ||
        this.desiredKeyCodes.indexOf(this.subscriptions[index].keyCode()) < 0) {
        return true;
      }
    }
    return false;
  }

  private updateReleaseRetry(): void {
    if (!this.hasUnrequestedSubscription()) {
      if (this.releaseRetryTimer >= 0) {
        this.retryScheduler.cancel(this.releaseRetryTimer);
        this.releaseRetryTimer = -1;
      }
      return;
    }
    if (this.releaseRetryTimer >= 0) { return; }
    this.releaseRetryTimer = this.retryScheduler.schedule((): void => {
      this.releaseRetryTimer = -1;
      this.reconcileSubscriptions();
    }, 250);
  }
}
