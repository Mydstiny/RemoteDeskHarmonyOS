/** SSH terminal appearance preference policy tests. */

import { describe, it, expect } from '@ohos/hypium';
import {
  SSH_DEFAULT_TERMINAL_LINE_SPACING,
  SSH_TERMINAL_LINE_SPACING_KEY,
  defaultSshTerminalAppearance,
  isSshTerminalAppearanceKey,
  normalizeSshTerminalLineSpacing,
  resolveSshTerminalAppearance,
  resolveSshTerminalAppearanceFromCloudSettings
} from '../main/ets/services/SshSettingsPolicy';

export default function sshSettingsPolicyTest(): void {
  describe('SshSettingsPolicy', (): void => {
    it('normalizes_line_spacing_to_a_bounded_two_decimal_multiplier', 0, (): void => {
      expect(normalizeSshTerminalLineSpacing(1.237)).assertEqual(1.24);
      expect(normalizeSshTerminalLineSpacing(0.5)).assertEqual(SSH_DEFAULT_TERMINAL_LINE_SPACING);
      expect(normalizeSshTerminalLineSpacing(2.0)).assertEqual(SSH_DEFAULT_TERMINAL_LINE_SPACING);
    });

    it('keeps_line_spacing_in_the_resolved_appearance', 0, (): void => {
      const appearance = resolveSshTerminalAppearance('#00FF00', '', 24, 0, 1.4, 0);
      expect(appearance.fontSize).assertEqual(24);
      expect(appearance.lineSpacing).assertEqual(1.4);
    });

    it('applies_a_partial_cloud_line_spacing_update_without_resetting_other_fields', 0, (): void => {
      const fallback = defaultSshTerminalAppearance();
      const settings: Record<string, string | number | boolean> = {};
      settings[SSH_TERMINAL_LINE_SPACING_KEY] = 1.5;
      const next = resolveSshTerminalAppearanceFromCloudSettings(
        settings, fallback);
      expect(next.foregroundColor).assertEqual(fallback.foregroundColor);
      expect(next.fontSize).assertEqual(fallback.fontSize);
      expect(next.lineSpacing).assertEqual(1.5);
      expect(isSshTerminalAppearanceKey(SSH_TERMINAL_LINE_SPACING_KEY)).assertTrue();
    });
  });
}
