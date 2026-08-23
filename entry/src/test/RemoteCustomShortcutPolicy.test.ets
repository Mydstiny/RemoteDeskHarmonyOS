import { describe, expect, it } from '@ohos/hypium';
import {
  createRemoteCustomShortcut,
  decodeRemoteCustomShortcuts,
  encodeRemoteCustomShortcuts,
  remoteCustomShortcutKeyOptions,
  remoteCustomShortcutKeyGroupForKeyCode,
  remoteCustomShortcutLabel,
  remoteCustomShortcutLabelForPlatform,
  removeRemoteCustomShortcut,
  upsertRemoteCustomShortcut
} from '../main/ets/services/RemoteCustomShortcutPolicy';

export default function remoteCustomShortcutPolicyTest(): void {
  describe('RemoteCustomShortcutPolicy', (): void => {
    it('normalizes_modifier_order_and_derives_safe_labels', 0, (): void => {
      const shortcut = createRemoteCustomShortcut('custom-1', [2047, 2072, 2017]);
      expect(shortcut !== null).assertTrue();
      expect(shortcut?.label).assertEqual('Ctrl + Shift + A');
      expect(shortcut?.keyCodes[0]).assertEqual(2072);
      expect(shortcut?.keyCodes[1]).assertEqual(2047);
      expect(remoteCustomShortcutLabel([2045, 2093])).assertEqual('Alt + F4');
      expect(remoteCustomShortcutLabelForPlatform([2076, 2047, 2017], 'macos'))
        .assertEqual('Shift + Cmd + A');
    });

    it('rejects_missing_modifiers_unknown_actions_and_duplicates', 0, (): void => {
      expect(createRemoteCustomShortcut('bad', [2017])).assertNull();
      expect(createRemoteCustomShortcut('bad', [2072, 999999])).assertNull();
      const first = upsertRemoteCustomShortcut([], 'custom-1', [2072, 2019]);
      expect(first.accepted).assertTrue();
      const duplicate = upsertRemoteCustomShortcut(first.shortcuts,
        'custom-2', [2072, 2019]);
      expect(duplicate.accepted).assertFalse();
      expect(duplicate.shortcuts.length).assertEqual(1);
    });

    it('round_trips_valid_entries_and_drops_malformed_storage', 0, (): void => {
      const first = upsertRemoteCustomShortcut([], 'custom-1', [2072, 2019]);
      const second = upsertRemoteCustomShortcut(first.shortcuts,
        'custom-2', [2045, 2093]);
      const decoded = decodeRemoteCustomShortcuts(encodeRemoteCustomShortcuts(second.shortcuts));
      expect(decoded.length).assertEqual(2);
      expect(decoded[1].label).assertEqual('Alt + F4');
      expect(decodeRemoteCustomShortcuts('{bad json').length).assertEqual(0);
      const mixed: string = '{"version":1,"items":[' +
        '{"keyCodes":[2072,2019]},' +
        '{"id":"bad-codes","keyCodes":[2072,"A"]},' +
        '{"id":"custom-good","keyCodes":[2045,2093]}]}';
      const recovered = decodeRemoteCustomShortcuts(mixed);
      expect(recovered.length).assertEqual(1);
      expect(recovered[0].id).assertEqual('custom-good');
      expect(removeRemoteCustomShortcut(decoded, 'custom-1').length).assertEqual(1);
    });

    it('exposes_complete_bounded_key_groups_for_the_editor', 0, (): void => {
      expect(remoteCustomShortcutKeyOptions('letters').length).assertEqual(26);
      expect(remoteCustomShortcutKeyOptions('digits').length).assertEqual(10);
      expect(remoteCustomShortcutKeyOptions('symbols').length).assertEqual(11);
      expect(remoteCustomShortcutKeyOptions('functions').length).assertEqual(12);
      expect(remoteCustomShortcutKeyOptions('navigation').length).assertEqual(15);
      expect(remoteCustomShortcutKeyGroupForKeyCode(2043)).assertEqual('symbols');
      expect(remoteCustomShortcutKeyGroupForKeyCode(2049)).assertEqual('navigation');
      expect(remoteCustomShortcutKeyGroupForKeyCode(2050)).assertEqual('navigation');
      expect(remoteCustomShortcutKeyGroupForKeyCode(2054)).assertEqual('navigation');
      expect(remoteCustomShortcutKeyGroupForKeyCode(2055)).assertEqual('navigation');
    });
  });
}
