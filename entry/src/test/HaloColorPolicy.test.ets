import { describe, it, expect } from '@ohos/hypium';
import {
  DEFAULT_DARK_HALO_COLOR,
  DEFAULT_LIGHT_HALO_COLOR,
  HALO_COLOR_DARK_KEY,
  HALO_COLOR_LIGHT_KEY,
  haloColorPreferenceKey,
  resolveStoredHaloColorForTheme,
  shouldMigrateLegacyHaloColorToTheme
} from '../main/ets/services/HaloColorPolicy';

export default function haloColorPolicyTest(): void {
  describe('HaloColorPolicy', (): void => {
    it('light_and_dark_modes_use_separate_halo_preference_keys', 0, (): void => {
      expect(haloColorPreferenceKey('light')).assertEqual(HALO_COLOR_LIGHT_KEY);
      expect(haloColorPreferenceKey('dark')).assertEqual(HALO_COLOR_DARK_KEY);
    });

    it('dark_mode_ignores_legacy_light_halo_and_uses_dark_default', 0, (): void => {
      const color: string = resolveStoredHaloColorForTheme('dark', '', '', '#FFFFFF');
      expect(color).assertEqual(DEFAULT_DARK_HALO_COLOR);
    });

    it('theme_specific_saved_halo_color_wins_for_each_mode', 0, (): void => {
      expect(resolveStoredHaloColorForTheme('light', '#F0F5FA', '#16213E', '#1A1A2E'))
        .assertEqual('#F0F5FA');
      expect(resolveStoredHaloColorForTheme('dark', '#F0F5FA', '#16213E', '#FFFFFF'))
        .assertEqual('#16213E');
    });

    it('legacy_halo_migrates_only_when_it_belongs_to_current_theme', 0, (): void => {
      expect(shouldMigrateLegacyHaloColorToTheme('light', '', '#FFF8F0')).assertTrue();
      expect(shouldMigrateLegacyHaloColorToTheme('dark', '', '#FFF8F0')).assertFalse();
      expect(resolveStoredHaloColorForTheme('light', '', '', '#FFF8F0')).assertEqual('#FFF8F0');
      expect(resolveStoredHaloColorForTheme('dark', '', '', '#FFF8F0')).assertEqual(DEFAULT_DARK_HALO_COLOR);
      expect(resolveStoredHaloColorForTheme('light', '', '', '')).assertEqual(DEFAULT_LIGHT_HALO_COLOR);
    });
  });
}
