import { describe, expect, it } from '@ohos/hypium';
import {
  defaultRemoteKeyboardPreferences,
  normalizeRemoteKeyboardPreferences,
  normalizeRemoteShortcutPlatform,
  remoteShortcutTransportKeyCode,
  remoteShortcutCategories,
  remoteShortcutPresets
} from '../main/ets/services/RemoteKeyboardSettingsPolicy';

export default function remoteKeyboardSettingsPolicyTest(): void {
  describe('RemoteKeyboardSettingsPolicy', (): void => {
    it('normalizes_platform_and_keeps_safe_defaults', 0, (): void => {
      expect(normalizeRemoteShortcutPlatform('Command')).assertEqual('macos');
      expect(normalizeRemoteShortcutPlatform('unknown')).assertEqual('windows');
      const defaults = defaultRemoteKeyboardPreferences();
      expect(defaults.shortcutPlatform).assertEqual('windows');
      expect(defaults.functionKeysVisible).assertTrue();
      expect(defaults.closePanelAfterShortcut).assertFalse();
      const normalized = normalizeRemoteKeyboardPreferences('mac', true, false, true);
      expect(normalized.shortcutPlatform).assertEqual('macos');
      expect(normalized.simpleKeyboardEnabled).assertTrue();
      expect(normalized.functionKeysVisible).assertFalse();
      expect(normalized.closePanelAfterShortcut).assertTrue();
    });

    it('exposes_broad_distinct_windows_and_macos_catalogs', 0, (): void => {
      const windows = remoteShortcutPresets('windows');
      const macos = remoteShortcutPresets('macos');
      expect(windows.length >= 70).assertTrue();
      expect(macos.length >= 30).assertTrue();
      expect(windows.some((item): boolean => item.chord === 'Ctrl+Alt+Del')).assertTrue();
      expect(windows.some((item): boolean => item.chord === 'Win+Shift+S')).assertTrue();
      expect(windows.some((item): boolean => item.chord === 'Win+Ctrl+Shift+B')).assertTrue();
      expect(windows.some((item): boolean => item.chord === 'Win+Shift+→')).assertTrue();
      expect(macos.some((item): boolean => item.chord === 'Cmd+Option+Esc')).assertTrue();
      expect(macos.some((item): boolean => item.chord === 'Shift+Cmd+5')).assertTrue();
      expect(macos.some((item): boolean => item.chord.indexOf('Win+') >= 0)).assertFalse();

      const windowsCopy = windows.filter((item): boolean => item.id === 'copy')[0];
      const macosCopy = macos.filter((item): boolean => item.id === 'copy')[0];
      expect(windowsCopy.chord).assertEqual('Ctrl+C');
      expect(windowsCopy.keyCodes[0]).assertEqual(2072);
      expect(macosCopy.chord).assertEqual('Cmd+C');
      expect(macosCopy.keyCodes[0]).assertEqual(2076);
      expect(macos.filter((item): boolean => item.id === 'macPreviousTab')[0].chord)
        .assertEqual('Shift+Cmd+[');
      expect(macos.filter((item): boolean => item.id === 'macNextTab')[0].chord)
        .assertEqual('Shift+Cmd+]');
    });

    it('covers_every_visible_category_for_both_platforms', 0, (): void => {
      const categories = remoteShortcutCategories();
      for (let index: number = 0; index < categories.length; index++) {
        expect(remoteShortcutPresets('windows', categories[index]).length > 0).assertTrue();
        expect(remoteShortcutPresets('macos', categories[index]).length > 0).assertTrue();
      }
    });

    it('marks_rustdesk_macos_keys_for_explicit_physical_map_transport', 0, (): void => {
      expect(remoteShortcutTransportKeyCode('rustdesk', 'macos', 2076)).assertEqual(133148);
      expect(remoteShortcutTransportKeyCode('rustdesk', 'macos', 2019)).assertEqual(133091);
      expect(remoteShortcutTransportKeyCode('rustdesk', 'windows', 2076)).assertEqual(2076);
      expect(remoteShortcutTransportKeyCode('vnc', 'macos', 2076)).assertEqual(2076);
    });
  });
}
