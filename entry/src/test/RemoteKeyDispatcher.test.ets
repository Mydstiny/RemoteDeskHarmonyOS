import { expect } from '@ohos/hypium';
import { auditedDescribe as describe, auditedIt as it } from '../main/ets/services/FocusedTestRegistrationAudit';
import {
  RemoteKeyDispatcher,
  RemoteSourcePoint
} from '../main/ets/services/RemoteKeyDispatcher';
import { ExtensionLoader } from '../main/ets/services/ExtensionLoader';
import { RemoteShortcutContext } from '../main/ets/services/RemoteShortcutPolicy';

class FailingLegacyTransport extends ExtensionLoader {
  events: string[] = [];
  calls: number = 0;
  failAt: number = -1;

  override sendKey(sessionId: number, keyCode: number, pressed: boolean): void {
    this.calls += 1;
    this.events.push('key:' + sessionId.toString() + ':' + keyCode.toString() +
      (pressed ? ':down' : ':up'));
    if (this.calls === this.failAt) { throw new Error('legacy-key-failure'); }
  }

  override sendMouse(sessionId: number, x: number, y: number, button: number, pressed: boolean): void {
    this.calls += 1;
    this.events.push('mouse:' + sessionId.toString() + ':' + x.toString() + ':' + y.toString() +
      ':' + button.toString() + (pressed ? ':down' : ':up'));
    if (this.calls === this.failAt) { throw new Error('legacy-mouse-failure'); }
  }
}

class ScriptedFailureTransport extends ExtensionLoader {
  events: string[] = [];
  calls: number = 0;
  failureCalls: number[] = [];

  override sendKey(sessionId: number, keyCode: number, pressed: boolean): void {
    this.calls += 1;
    this.events.push('key:' + sessionId.toString() + ':' + keyCode.toString() +
      (pressed ? ':down' : ':up'));
    if (this.failureCalls.indexOf(this.calls) >= 0) {
      throw new Error('scripted-key-failure');
    }
  }

  override sendMouse(_sessionId: number, _x: number, _y: number,
    _button: number, _pressed: boolean): void {}
}

function hasEvent(events: string[], event: string): boolean {
  return events.indexOf(event) >= 0;
}

function assertReleaseForEveryAttempt(events: string[]): void {
  for (let index = 0; index < events.length; index++) {
    const event: string = events[index];
    if (event.endsWith(':down')) {
      const up: string = event.substring(0, event.length - 5) + ':up';
      expect(hasEvent(events, up)).assertTrue();
    }
  }
}

function assertEventSequence(actual: string[], expected: string[]): void {
  expect(actual.length).assertEqual(expected.length);
  for (let index = 0; index < expected.length; index++) {
    expect(actual[index]).assertEqual(expected[index]);
  }
}

function context(): RemoteShortcutContext {
  return {
    protocol: 'rdp', sessionId: 7, generation: 3, connected: true, viewOnly: false,
    canSendKeys: true, canSendText: true, clipboardEnabled: true,
    remotePlatform: 'windows', sessionLayout: 'unknown', isPreconnect: false,
    bracketedPaste: false, pasteTextBytes: 0
  };
}

export default function remoteKeyDispatcherTest(): void {
  describe('RemoteKeyDispatcher_semantic_atomicity', (): void => {
    it('sends_all_down_then_reverse_up_and_keeps_sticky_state_outside_plan', 0, (): void => {
      const events: string[] = [];
      const dispatcher = new RemoteKeyDispatcher();
      const result = dispatcher.dispatchSemanticAction('copy', context(), {
        isCurrent: (_sessionId: number, _generation: number): boolean => true,
        sendKey: (code: number, pressed: boolean): void => {
          events.push(code.toString() + (pressed ? ':down' : ':up'));
        }
      });
      expect(result.ok).assertTrue();
      expect(events[0]).assertEqual('2072:down');
      expect(events[1]).assertEqual('2019:down');
      expect(events[2]).assertEqual('2019:up');
      expect(events[3]).assertEqual('2072:up');
    });

    it('best_effort_releases_keys_when_transport_throws', 0, (): void => {
      const events: string[] = [];
      let calls: number = 0;
      const dispatcher = new RemoteKeyDispatcher();
      const result = dispatcher.dispatchSemanticAction('copy', context(), {
        isCurrent: (_sessionId: number, _generation: number): boolean => true,
        sendKey: (code: number, pressed: boolean): void => {
          calls++;
          events.push(code.toString() + (pressed ? ':down' : ':up'));
          if (calls === 2) { throw new Error('transport-failure'); }
        }
      });
      expect(result.ok).assertFalse();
      expect(events.indexOf('2072:up') >= 0).assertTrue();
      expect(events.indexOf('2019:up') >= 0).assertTrue();
    });

    it('release_failure_is_not_reported_as_success', 0, (): void => {
      let ups: number = 0;
      const dispatcher = new RemoteKeyDispatcher();
      const result = dispatcher.dispatchSemanticAction('copy', context(), {
        isCurrent: (_sessionId: number, _generation: number): boolean => true,
        sendKey: (_code: number, pressed: boolean): void => {
          if (!pressed) {
            ups++;
            if (ups === 1) { throw new Error('release-failure'); }
          }
        }
      });
      expect(result.ok).assertFalse();
      expect(result.reason).assertEqual('按键释放失败');
      expect(ups).assertEqual(2);
    });

    it('checks_session_and_generation_again_before_dispatch', 0, (): void => {
      const dispatcher = new RemoteKeyDispatcher();
      let sent: boolean = false;
      const result = dispatcher.dispatchSemanticAction('copy', context(), {
        isCurrent: (_sessionId: number, _generation: number): boolean => false,
        sendKey: (_code: number, _pressed: boolean): void => { sent = true; }
      });
      expect(result.ok).assertFalse();
      expect(sent).assertFalse();

      // The sender is immutable for one chord.  If the session barrier trips
      // after S1's Ctrl down, the release is still routed to S1 and never to
      // the newly active S2 transport.
      const s1Events: string[] = [];
      const s2Events: string[] = [];
      let activeSession: number = 1;
      const barrierContext: RemoteShortcutContext = context();
      barrierContext.sessionId = 1;
      barrierContext.generation = 11;
      const barrierResult = dispatcher.dispatchSemanticAction('copy', barrierContext, {
        isCurrent: (sessionId: number, _generation: number): boolean => activeSession === sessionId,
        sendKey: (code: number, pressed: boolean): void => {
          s1Events.push(code.toString() + (pressed ? ':down' : ':up'));
          if (pressed && code === 2072) { activeSession = 2; }
        }
      });
      expect(barrierResult.ok).assertFalse();
      assertEventSequence(s1Events, ['2072:down', '2072:up']);
      expect(s2Events.length).assertEqual(0);
    });

    it('legacy_virtual_tap_releases_when_down_or_up_throws', 0, (): void => {
      const dispatcher = new RemoteKeyDispatcher();
      for (let failAt = 1; failAt <= 2; failAt++) {
        const transport = new FailingLegacyTransport();
        transport.failAt = failAt;
        dispatcher.sendVirtualKeyTap(transport, 7, 2019, 'C');
        expect(hasEvent(transport.events, 'key:7:2019:up')).assertTrue();
      }
    });

    it('mapped_shortcut_keeps_command_and_letter_on_the_same_wire_path', 0, (): void => {
      const dispatcher = new RemoteKeyDispatcher();
      const transport = new FailingLegacyTransport();
      dispatcher.sendShortcutSequenceMapped(transport, 7, [2076, 2019], 'Cmd+C',
        null, null, null, (keyCode: number): number => keyCode | 0x20000);
      assertEventSequence(transport.events, [
        'key:7:133148:down', 'key:7:133091:down',
        'key:7:133091:up', 'key:7:133148:up'
      ]);
    });

    it('legacy_modified_key_releases_each_attempt_and_clears_once_latch', 0, (): void => {
      const dispatcher = new RemoteKeyDispatcher();
      for (let failAt = 1; failAt <= 4; failAt++) {
        const transport = new FailingLegacyTransport();
        transport.failAt = failAt;
        let ctrlLatch: string = 'once';
        dispatcher.sendModifiedKey(transport, 7, 2019, 'Ctrl+C',
          (mod: string): string => mod === 'ctrl' ? ctrlLatch : 'off',
          (mod: string, value: string): void => { if (mod === 'ctrl') { ctrlLatch = value; } },
          (_mod: string): boolean => false);
        assertReleaseForEveryAttempt(transport.events);
        expect(ctrlLatch).assertEqual('off');
      }

      // One stack, in the exact delivery order: Ctrl(once), Alt(locked),
      // then C. If C down throws after native delivery, teardown is C up,
      // Alt up, Ctrl up — never grouped by latch type.
      const keyFailure = new ScriptedFailureTransport();
      keyFailure.failureCalls = [3];
      let ctrlLatch: string = 'once';
      let altLatch: string = 'locked';
      let ctrlDown: boolean = false;
      let altDown: boolean = false;
      dispatcher.sendModifiedKey(keyFailure, 7, 2019, 'mixed key failure',
        (mod: string): string => mod === 'ctrl' ? ctrlLatch :
          (mod === 'alt' ? altLatch : 'off'),
        (mod: string, value: string): void => {
          if (mod === 'ctrl') { ctrlLatch = value; }
          if (mod === 'alt') { altLatch = value; }
        },
        (mod: string): boolean => mod === 'ctrl' ? ctrlDown : altDown,
        (mod: string, down: boolean): void => {
          if (mod === 'ctrl') { ctrlDown = down; }
          if (mod === 'alt') { altDown = down; }
        });
      assertEventSequence(keyFailure.events, [
        'key:7:2072:down', 'key:7:2045:down', 'key:7:2019:down',
        'key:7:2019:up', 'key:7:2045:up', 'key:7:2072:up'
      ]);
      expect(ctrlDown).assertFalse();
      expect(altDown).assertFalse();
      expect(ctrlLatch).assertEqual('off');

      // The second modifier may throw after delivering down; it still owns a
      // stack slot and is released before the earlier Ctrl.
      const secondModifierFailure = new ScriptedFailureTransport();
      secondModifierFailure.failureCalls = [2];
      const secondDispatcher = new RemoteKeyDispatcher();
      secondDispatcher.sendModifiedKey(secondModifierFailure, 7, 2019,
        'second modifier failure',
        (mod: string): string => mod === 'ctrl' ? 'once' :
          (mod === 'alt' ? 'locked' : 'off'),
        (): void => {}, (): boolean => false, (): void => {});
      assertEventSequence(secondModifierFailure.events, [
        'key:7:2072:down', 'key:7:2045:down',
        'key:7:2045:up', 'key:7:2072:up'
      ]);

      // A failed transient key-up must not prevent the earlier transient
      // modifier-up. The newly-held locked Alt remains owned by the sticky
      // stack and its mirror stays true until lifecycle teardown retries it.
      const keyUpFailure = new ScriptedFailureTransport();
      keyUpFailure.failureCalls = [4];
      const keyUpDispatcher = new RemoteKeyDispatcher();
      let keyUpAltDown: boolean = false;
      keyUpDispatcher.sendModifiedKey(keyUpFailure, 7, 2019, 'key up failure',
        (mod: string): string => mod === 'ctrl' ? 'once' :
          (mod === 'alt' ? 'locked' : 'off'),
        (): void => {}, (mod: string): boolean => mod === 'alt' ? keyUpAltDown : false,
        (mod: string, down: boolean): void => { if (mod === 'alt') { keyUpAltDown = down; } });
      assertEventSequence(keyUpFailure.events, [
        'key:7:2072:down', 'key:7:2045:down', 'key:7:2019:down',
        'key:7:2019:up', 'key:7:2072:up'
      ]);
      expect(keyUpAltDown).assertTrue(); // Sticky Alt remains owned; retry is lifecycle-scoped.

      const modifierUpFailure = new ScriptedFailureTransport();
      modifierUpFailure.failureCalls = [5];
      const modifierUpDispatcher = new RemoteKeyDispatcher();
      let modifierUpAltDown: boolean = false;
      modifierUpDispatcher.sendModifiedKey(modifierUpFailure, 7, 2019,
        'modifier up failure',
        (mod: string): string => mod === 'ctrl' ? 'once' :
          (mod === 'alt' ? 'locked' : 'off'),
        (): void => {}, (mod: string): boolean => mod === 'alt' ? modifierUpAltDown : false,
        (mod: string, down: boolean): void => { if (mod === 'alt') { modifierUpAltDown = down; } });
      assertEventSequence(modifierUpFailure.events, [
        'key:7:2072:down', 'key:7:2045:down', 'key:7:2019:down',
        'key:7:2019:up', 'key:7:2072:up'
      ]);
      expect(modifierUpAltDown).assertTrue();
      modifierUpDispatcher.releaseAllHeldKeys(modifierUpFailure, 7,
        (_x: number, _y: number): RemoteSourcePoint => ({ x: 0, y: 0 }), 0, 0, false,
        (mod: string, down: boolean): void => { if (mod === 'alt') { modifierUpAltDown = down; } });
      expect(modifierUpFailure.events[5]).assertEqual('key:7:2045:up');
      expect(modifierUpFailure.events[6]).assertEqual('key:7:2072:up');
      expect(modifierUpAltDown).assertFalse();

      // Existing sticky Alt and a temporary Ctrl share the same stack; the
      // existing Alt is not pressed twice and is released last on teardown.
      const stickyTransport = new ScriptedFailureTransport();
      const stickyDispatcher = new RemoteKeyDispatcher();
      let stickyAltDown: boolean = false;
      stickyDispatcher.sendModifierDown(stickyTransport, 7, 2045, 'alt',
        (_mod: string, down: boolean): void => { stickyAltDown = down; });
      stickyDispatcher.sendModifiedKey(stickyTransport, 7, 2019, 'sticky + once',
        (mod: string): string => mod === 'ctrl' ? 'once' :
          (mod === 'alt' ? 'locked' : 'off'),
        (): void => {}, (mod: string): boolean => mod === 'alt' ? stickyAltDown : false,
        (_mod: string, _down: boolean): void => {});
      assertEventSequence(stickyTransport.events.slice(0, 5), [
        'key:7:2045:down', 'key:7:2072:down', 'key:7:2019:down',
        'key:7:2019:up', 'key:7:2072:up'
      ]);
      stickyDispatcher.releaseAllHeldKeys(stickyTransport, 7,
        (_x: number, _y: number): RemoteSourcePoint => ({ x: 0, y: 0 }), 0, 0, false);
      expect(stickyTransport.events[5]).assertEqual('key:7:2045:up');

      // A new session clears the old stack and mirror before resolving a
      // locked modifier; S1's Alt is never released into S2.
      const sessionOne = new ScriptedFailureTransport();
      const sessionTwo = new ScriptedFailureTransport();
      const sessionDispatcher = new RemoteKeyDispatcher();
      let sessionAltDown: boolean = false;
      sessionDispatcher.sendModifierDown(sessionOne, 1, 2045, 'alt',
        (_mod: string, down: boolean): void => { sessionAltDown = down; });
      sessionDispatcher.sendModifiedKey(sessionTwo, 2, 2019, 'new session',
        (mod: string): string => mod === 'alt' ? 'locked' : 'off',
        (): void => {}, (mod: string): boolean => mod === 'alt' ? sessionAltDown : false,
        (_mod: string, down: boolean): void => { sessionAltDown = down; });
      expect(sessionOne.events[1]).assertEqual('key:1:2045:up');
      assertEventSequence(sessionTwo.events, [
        'key:2:2045:down', 'key:2:2019:down', 'key:2:2019:up'
      ]);
    });

    it('locked_modifier_success_is_mirrored_and_not_pressed_twice', 0, (): void => {
      const dispatcher = new RemoteKeyDispatcher();
      const transport = new FailingLegacyTransport();
      let remoteDown: boolean = false;
      dispatcher.sendModifiedKey(transport, 7, 2019, 'locked Ctrl+C',
        (_mod: string): string => 'locked',
        (_mod: string, _value: string): void => {},
        (_mod: string): boolean => remoteDown,
        (_mod: string, down: boolean): void => { remoteDown = down; });
      expect(remoteDown).assertTrue();
      expect(transport.events[0]).assertEqual('key:7:2072:down');
      const second = new FailingLegacyTransport();
      dispatcher.sendModifiedKey(second, 7, 2019, 'locked Ctrl+C retry',
        (_mod: string): string => 'locked',
        (_mod: string, _value: string): void => {},
        (_mod: string): boolean => remoteDown,
        (_mod: string, down: boolean): void => { remoteDown = down; });
      expect(second.events[0]).assertEqual('key:7:2019:down');
      expect(second.events.length).assertEqual(2);
    });

    it('locked_modifier_failure_releases_and_rolls_back_mirror', 0, (): void => {
      const dispatcher = new RemoteKeyDispatcher();
      const transport = new FailingLegacyTransport();
      transport.failAt = 1;
      let remoteDown: boolean = false;
      dispatcher.sendModifiedKey(transport, 7, 2019, 'locked Ctrl+C failure',
        (_mod: string): string => 'locked',
        (_mod: string, _value: string): void => {},
        (_mod: string): boolean => remoteDown,
        (_mod: string, down: boolean): void => { remoteDown = down; });
      expect(remoteDown).assertFalse();
      expect(hasEvent(transport.events, 'key:7:2072:up')).assertTrue();
    });

    it('legacy_ctrl_alt_del_sequence_releases_at_every_down_and_up_failure', 0, (): void => {
      const dispatcher = new RemoteKeyDispatcher();
      const sequence: number[] = [2072, 2045, 2071];
      let ctrlLatch: string = 'once';
      for (let failAt = 1; failAt <= 6; failAt++) {
        const transport = new FailingLegacyTransport();
        transport.failAt = failAt;
        ctrlLatch = 'once';
        dispatcher.sendShortcutSequence(transport, 7, sequence, 'Ctrl+Alt+Del',
          (mod: string): string => mod === 'ctrl' ? ctrlLatch : 'off',
          (): boolean => false,
          (): void => {},
          (mod: string, value: string): void => { if (mod === 'ctrl') { ctrlLatch = value; } });
        assertReleaseForEveryAttempt(transport.events);
        expect(ctrlLatch).assertEqual('off');
      }
    });

    it('legacy_release_all_continues_after_every_key_or_mouse_failure', 0, (): void => {
      const dispatcher = new RemoteKeyDispatcher();
      for (let failAt = 1; failAt <= 11; failAt++) {
        const transport = new FailingLegacyTransport();
        transport.failAt = failAt;
        const point: RemoteSourcePoint = { x: 42, y: 24 };
        dispatcher.releaseAllHeldKeys(transport, 7,
          (_x: number, _y: number): RemoteSourcePoint => point, 1, 2, true);
        expect(transport.events.length).assertEqual(11);
        expect(hasEvent(transport.events, 'mouse:7:42:24:0:up')).assertTrue();
        expect(hasEvent(transport.events, 'mouse:7:42:24:1:up')).assertTrue();
        expect(hasEvent(transport.events, 'mouse:7:42:24:2:up')).assertTrue();
      }
    });

    it('failed_locked_modifier_is_released_and_remote_state_is_cleared', 0, (): void => {
      const dispatcher = new RemoteKeyDispatcher();
      const transport = new FailingLegacyTransport();
      transport.failAt = 1;
      let remoteDown: boolean = false;
      dispatcher.sendShortcutSequence(transport, 7, [2072, 2019], 'locked Ctrl+C',
        (_mod: string): string => 'locked',
        (_mod: string): boolean => remoteDown,
        (_mod: string, down: boolean): void => { remoteDown = down; });
      expect(hasEvent(transport.events, 'key:7:2072:up')).assertTrue();
      expect(remoteDown).assertFalse();
    });
  });
}
