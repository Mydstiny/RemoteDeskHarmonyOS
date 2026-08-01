import { describe, it, expect } from '@ohos/hypium';
import {
  SSH_DEFAULT_TERMINAL_FONT_SIZE,
  SSH_DEFAULT_TERMINAL_FOREGROUND_COLOR,
  SSH_TERMINAL_FONT_SIZE_MAX,
  SSH_TERMINAL_FONT_SIZE_MIN,
  chooseSshTerminalFontSize,
  chooseSshTerminalForegroundColor,
  hasSshTerminalAppearanceCloudSettings,
  isValidSshTerminalFontSize,
  isValidSshTerminalForegroundColor,
  resolveSshTerminalAppearance,
  resolveSshTerminalAppearanceFromCloudSettings
} from '../../../main/ets/services/SshSettingsPolicy';

export default function sshSettingsPolicyTest(): void {
  describe('SshSettingsPolicy_Appearance', (): void => {
    it('new_key_value_should_win_over_legacy_value', 0, (): void => {
      const result = resolveSshTerminalAppearance('#00FFAA', '#FF0000', 24, 14);
      expect(result.foregroundColor).assertEqual('#00FFAA');
      expect(result.fontSize).assertEqual(24);
    });

    it('legacy_value_should_migrate_when_new_value_is_missing', 0, (): void => {
      expect(chooseSshTerminalForegroundColor('', '#FF8800', SSH_DEFAULT_TERMINAL_FOREGROUND_COLOR))
        .assertEqual('#FF8800');
      expect(chooseSshTerminalFontSize(0, 20, SSH_DEFAULT_TERMINAL_FONT_SIZE)).assertEqual(20);
    });

    it('invalid_values_should_fall_back_to_defaults', 0, (): void => {
      expect(isValidSshTerminalForegroundColor('#GG0000')).assertFalse();
      expect(isValidSshTerminalForegroundColor('#FFFFFF')).assertTrue();
      expect(isValidSshTerminalFontSize(11)).assertFalse();
      expect(isValidSshTerminalFontSize(33)).assertFalse();
      const result = resolveSshTerminalAppearance('#GG0000', 'rgb(0,0,0)', 40, 0);
      expect(result.foregroundColor).assertEqual(SSH_DEFAULT_TERMINAL_FOREGROUND_COLOR);
      expect(result.fontSize).assertEqual(SSH_DEFAULT_TERMINAL_FONT_SIZE);
    });

    it('font_size_boundary_should_be_inclusive', 0, (): void => {
      expect(isValidSshTerminalFontSize(SSH_TERMINAL_FONT_SIZE_MIN)).assertTrue();
      expect(isValidSshTerminalFontSize(SSH_TERMINAL_FONT_SIZE_MAX)).assertTrue();
    });

    it('cloud_patch_should_validate_and_preserve_partial_local_values', 0, (): void => {
      const fallback = { foregroundColor: '#ABCDEF', fontSize: 26 };
      const settings: Record<string, string | number | boolean> = {
        sshTerminalForegroundColor: '#00FFAA',
        terminalFgColor: '#FF0000',
        sshTerminalFontSize: 40,
        terminalFontSize: 22
      };
      const result = resolveSshTerminalAppearanceFromCloudSettings(settings, fallback);
      expect(hasSshTerminalAppearanceCloudSettings(settings)).assertTrue();
      expect(result.foregroundColor).assertEqual('#00FFAA');
      expect(result.fontSize).assertEqual(22);

      const partial: Record<string, string | number | boolean> = {
        sshTerminalForegroundColor: 'invalid'
      };
      const partialResult = resolveSshTerminalAppearanceFromCloudSettings(partial, fallback);
      expect(partialResult.foregroundColor).assertEqual('#ABCDEF');
      expect(partialResult.fontSize).assertEqual(26);
    });
  });
}
