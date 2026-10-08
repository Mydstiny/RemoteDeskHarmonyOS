import { expect } from '@ohos/hypium';
import { auditedDescribe as describe, auditedIt as it } from '../main/ets/services/FocusedTestRegistrationAudit';
import { RemoteKeyDispatcher } from '../main/ets/services/RemoteKeyDispatcher';
import { ExtensionLoader } from '../main/ets/services/ExtensionLoader';

/**
 * Records what the dispatcher hands to the transport. Taps and chords are
 * delivered as one native batch; only the release-all path sends single keys.
 */
class RecordingTransport extends ExtensionLoader {
  events: string[] = [];
  batches: number = 0;
  accept: boolean = true;

  override sendKeySequence(sessionId: number, keyCodes: Array<number>): boolean {
    this.batches += 1;
    for (let i = 0; i < keyCodes.length; i++) {
      this.events.push('tap:' + sessionId.toString() + ':' + keyCodes[i].toString());
    }
    return this.accept;
  }

  override sendKeyEvents(sessionId: number, keyCodes: Array<number>, pressed: Array<boolean>): boolean {
    this.batches += 1;
    for (let i = 0; i < keyCodes.length; i++) {
      this.events.push('key:' + sessionId.toString() + ':' + keyCodes[i].toString() +
        (pressed[i] ? ':down' : ':up'));
    }
    return this.accept;
  }

  override sendKey(sessionId: number, scancode: number, pressed: boolean): void {
    this.events.push('single:' + sessionId.toString() + ':' + scancode.toString() +
      (pressed ? ':down' : ':up'));
  }

  override sendMouse(sessionId: number, x: number, y: number, button: number, pressed: boolean): void {
    this.events.push('mouse:' + sessionId.toString() + ':' + x.toString() + ':' + y.toString() +
      ':' + button.toString() + (pressed ? ':down' : ':up'));
  }
}

class LatchState {
  ctrl: string = 'off';
  alt: string = 'off';
  shift: string = 'off';
  win: string = 'off';
  ctrlDown: boolean = false;
  altDown: boolean = false;
  mirroredWireCodes: number[] = [];

  latch(mod: string): string {
    if (mod === 'ctrl') { return this.ctrl; }
    if (mod === 'alt') { return this.alt; }
    if (mod === 'shift') { return this.shift; }
    if (mod === 'win') { return this.win; }
    return 'off';
  }

  setLatch(mod: string, value: string): void {
    if (mod === 'ctrl') { this.ctrl = value; }
    if (mod === 'alt') { this.alt = value; }
    if (mod === 'shift') { this.shift = value; }
    if (mod === 'win') { this.win = value; }
  }

  isDown(mod: string): boolean {
    return mod === 'ctrl' ? this.ctrlDown : (mod === 'alt' ? this.altDown : false);
  }

  setDown(mod: string, down: boolean, wireCode?: number): void {
    if (mod === 'ctrl') { this.ctrlDown = down; }
    if (mod === 'alt') { this.altDown = down; }
    if (wireCode !== undefined) { this.mirroredWireCodes.push(wireCode); }
  }
}

function assertEventSequence(actual: string[], expected: string[]): void {
  expect(actual.length).assertEqual(expected.length);
  for (let index = 0; index < expected.length; index++) {
    expect(actual[index]).assertEqual(expected[index]);
  }
}

function sendModified(dispatcher: RemoteKeyDispatcher, transport: RecordingTransport,
  latches: LatchState, label: string, mapKeyCode: ((keyCode: number) => number) | null = null): void {
  dispatcher.sendModifiedKeyMapped(transport, 7, 2019, label,
    (mod: string): string => latches.latch(mod),
    (mod: string, value: string): void => latches.setLatch(mod, value),
    (mod: string): boolean => latches.isDown(mod),
    mapKeyCode,
    (mod: string, down: boolean, wireCode?: number): void => latches.setDown(mod, down, wireCode));
}

export default function remoteKeyDispatcherTest(): void {
  describe('RemoteKeyDispatcher_semantic_atomicity', (): void => {
    it('virtual_tap_is_one_batch_with_the_mapped_wire_code', 0, (): void => {
      const dispatcher = new RemoteKeyDispatcher();
      const plain = new RecordingTransport();
      dispatcher.sendVirtualKeyTap(plain, 7, 2019, 'C');
      assertEventSequence(plain.events, ['tap:7:2019']);
      expect(plain.batches).assertEqual(1);

      const mapped = new RecordingTransport();
      dispatcher.sendVirtualKeyTapMapped(mapped, 7, 2019, 'C',
        (keyCode: number): number => keyCode | 0x20000);
      assertEventSequence(mapped.events, ['tap:7:133091']);
    });

    it('shortcut_sends_all_down_then_reverse_up_on_one_mapped_wire_path', 0, (): void => {
      const dispatcher = new RemoteKeyDispatcher();
      const transport = new RecordingTransport();
      dispatcher.sendShortcutSequenceMapped(transport, 7, [2076, 2019], 'Cmd+C',
        null, null, null, (keyCode: number): number => keyCode | 0x20000);
      assertEventSequence(transport.events, [
        'key:7:133148:down', 'key:7:133091:down',
        'key:7:133091:up', 'key:7:133148:up'
      ]);
      expect(transport.batches).assertEqual(1);
    });

    it('modified_key_wraps_once_modifiers_in_order_and_clears_the_once_latches', 0, (): void => {
      const dispatcher = new RemoteKeyDispatcher();
      const transport = new RecordingTransport();
      const latches = new LatchState();
      latches.ctrl = 'once';
      latches.shift = 'once';
      sendModified(dispatcher, transport, latches, 'Ctrl+Shift+C');
      assertEventSequence(transport.events, [
        'key:7:2072:down', 'key:7:2047:down', 'key:7:2019:down',
        'key:7:2019:up', 'key:7:2047:up', 'key:7:2072:up'
      ]);
      expect(transport.batches).assertEqual(1);
      expect(latches.ctrl).assertEqual('off');
      expect(latches.shift).assertEqual('off');
    });

    it('modified_key_without_modifiers_is_a_plain_tap', 0, (): void => {
      const dispatcher = new RemoteKeyDispatcher();
      const transport = new RecordingTransport();
      sendModified(dispatcher, transport, new LatchState(), 'C');
      assertEventSequence(transport.events, ['tap:7:2019']);
    });

    it('locked_modifier_is_pressed_once_mirrored_and_left_down', 0, (): void => {
      const dispatcher = new RemoteKeyDispatcher();
      const latches = new LatchState();
      latches.alt = 'locked';
      const first = new RecordingTransport();
      sendModified(dispatcher, first, latches, 'locked Alt+C');
      assertEventSequence(first.events, [
        'key:7:2045:down', 'key:7:2019:down', 'key:7:2019:up'
      ]);
      expect(latches.altDown).assertTrue();
      expect(latches.alt).assertEqual('locked');
      expect(latches.mirroredWireCodes.length).assertEqual(1);
      expect(latches.mirroredWireCodes[0]).assertEqual(2045);

      // Already held on the remote side: never pressed a second time.
      const second = new RecordingTransport();
      sendModified(dispatcher, second, latches, 'locked Alt+C again');
      assertEventSequence(second.events, ['key:7:2019:down', 'key:7:2019:up']);
    });

    it('rejected_batch_clears_once_latches_but_never_mirrors_a_locked_modifier', 0, (): void => {
      const dispatcher = new RemoteKeyDispatcher();
      const transport = new RecordingTransport();
      transport.accept = false;
      const latches = new LatchState();
      latches.ctrl = 'once';
      latches.alt = 'locked';
      sendModified(dispatcher, transport, latches, 'rejected Ctrl+Alt+C');
      assertEventSequence(transport.events, [
        'key:7:2072:down', 'key:7:2045:down', 'key:7:2019:down',
        'key:7:2019:up', 'key:7:2072:up'
      ]);
      expect(latches.ctrl).assertEqual('off');
      expect(latches.altDown).assertFalse();
      expect(latches.mirroredWireCodes.length).assertEqual(0);
    });

    it('locked_modifier_mirror_records_the_mapped_wire_code', 0, (): void => {
      const dispatcher = new RemoteKeyDispatcher();
      const transport = new RecordingTransport();
      const latches = new LatchState();
      latches.ctrl = 'locked';
      sendModified(dispatcher, transport, latches, 'mapped locked Ctrl+C',
        (keyCode: number): number => keyCode | 0x20000);
      assertEventSequence(transport.events, [
        'key:7:133144:down', 'key:7:133091:down', 'key:7:133091:up'
      ]);
      expect(latches.ctrlDown).assertTrue();
      expect(latches.mirroredWireCodes[0]).assertEqual(133144);
    });

    it('shortcut_with_a_locked_modifier_mirrors_it_only_after_acceptance', 0, (): void => {
      const dispatcher = new RemoteKeyDispatcher();
      const accepted = new RecordingTransport();
      const latches = new LatchState();
      latches.ctrl = 'locked';
      dispatcher.sendShortcutSequence(accepted, 7, [2072, 2019], 'locked Ctrl+C',
        (mod: string): string => latches.latch(mod),
        (mod: string): boolean => latches.isDown(mod),
        (mod: string, down: boolean, wireCode?: number): void => latches.setDown(mod, down, wireCode));
      assertEventSequence(accepted.events, [
        'key:7:2072:down', 'key:7:2019:down', 'key:7:2019:up'
      ]);
      expect(latches.ctrlDown).assertTrue();

      const rejected = new RecordingTransport();
      rejected.accept = false;
      const fresh = new LatchState();
      fresh.ctrl = 'locked';
      dispatcher.sendShortcutSequence(rejected, 7, [2072, 2019], 'rejected locked Ctrl+C',
        (mod: string): string => fresh.latch(mod),
        (mod: string): boolean => fresh.isDown(mod),
        (mod: string, down: boolean, wireCode?: number): void => fresh.setDown(mod, down, wireCode));
      expect(fresh.ctrlDown).assertFalse();
    });

    it('release_all_releases_every_modifier_and_optionally_the_mouse_buttons', 0, (): void => {
      const dispatcher = new RemoteKeyDispatcher();
      const point: Record<string, number> = { 'x': 42, 'y': 24 };
      const withMouse = new RecordingTransport();
      dispatcher.releaseAllHeldKeys(withMouse, 7,
        (_x: number, _y: number): Record<string, number> => point, 1, 2, true);
      assertEventSequence(withMouse.events, [
        'single:7:2072:up', 'single:7:2073:up', 'single:7:2045:up', 'single:7:2046:up',
        'single:7:2047:up', 'single:7:2048:up', 'single:7:2076:up', 'single:7:2077:up',
        'mouse:7:42:24:0:up', 'mouse:7:42:24:1:up', 'mouse:7:42:24:2:up'
      ]);

      // A keyboard focus change is not a pointer cancellation.
      const keysOnly = new RecordingTransport();
      dispatcher.releaseAllHeldKeys(keysOnly, 7,
        (_x: number, _y: number): Record<string, number> => point, 1, 2, false);
      expect(keysOnly.events.length).assertEqual(8);
      expect(keysOnly.events.indexOf('mouse:7:42:24:0:up')).assertEqual(-1);
    });
  });
}
