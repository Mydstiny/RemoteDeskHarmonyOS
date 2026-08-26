import { describe, it, expect } from '@ohos/hypium';
import {
  HARMONY_KEYCODE_CTRL_LEFT,
  HARMONY_KEYCODE_CTRL_RIGHT,
  HARMONY_KEYCODE_META_LEFT,
  HARMONY_KEYCODE_META_RIGHT,
  isMacCapsLockLongPress,
  mapPhysicalKeyForRemoteLayout,
  physicalKeyboardLayoutForProtocol,
  remoteControlModeDefaultForDevice,
  RemoteKeyboardLayout,
  remoteKeyboardLayoutDescription,
  shouldChoosePhysicalKeyboardLayout,
  shouldAutoSwitchVncKeyboardMouseMode,
  shouldConsumeRemoteBack
} from '../../../main/ets/services/RemotePhysicalKeyboardPolicy';

export default function remotePhysicalKeyboardPolicyTest(): void {
  describe('RemotePhysicalKeyboardPolicy', (): void => {
    it('keeps_windows_modifier_layout_unchanged', 0, (): void => {
      expect(mapPhysicalKeyForRemoteLayout(RemoteKeyboardLayout.WINDOWS,
        HARMONY_KEYCODE_CTRL_LEFT)).assertEqual(HARMONY_KEYCODE_CTRL_LEFT);
      expect(mapPhysicalKeyForRemoteLayout(RemoteKeyboardLayout.WINDOWS,
        HARMONY_KEYCODE_META_RIGHT)).assertEqual(HARMONY_KEYCODE_META_RIGHT);
      const completeWindowsChord: number[] = [2076, 2045, 2047, 2034];
      const mappedWindowsChord: number[] = completeWindowsChord.map((keyCode: number): number =>
        mapPhysicalKeyForRemoteLayout(RemoteKeyboardLayout.WINDOWS, keyCode));
      expect(mappedWindowsChord.join(',')).assertEqual('2076,2045,2047,2034');
    });

    it('distinguishes_macos_caps_short_and_long_press', 0, (): void => {
      expect(isMacCapsLockLongPress(14)).assertFalse();
      expect(isMacCapsLockLongPress(349)).assertFalse();
      expect(isMacCapsLockLongPress(350)).assertTrue();
      expect(isMacCapsLockLongPress(800)).assertTrue();
    });

    it('swaps_control_and_command_for_macos', 0, (): void => {
      expect(mapPhysicalKeyForRemoteLayout(RemoteKeyboardLayout.MACOS,
        HARMONY_KEYCODE_CTRL_LEFT)).assertEqual(HARMONY_KEYCODE_META_LEFT);
      expect(mapPhysicalKeyForRemoteLayout(RemoteKeyboardLayout.MACOS,
        HARMONY_KEYCODE_CTRL_RIGHT)).assertEqual(HARMONY_KEYCODE_META_RIGHT);
      expect(mapPhysicalKeyForRemoteLayout(RemoteKeyboardLayout.MACOS,
        HARMONY_KEYCODE_META_LEFT)).assertEqual(HARMONY_KEYCODE_CTRL_LEFT);
      expect(mapPhysicalKeyForRemoteLayout(RemoteKeyboardLayout.MACOS,
        HARMONY_KEYCODE_META_RIGHT)).assertEqual(HARMONY_KEYCODE_CTRL_RIGHT);
      // Option/Alt, Shift and the complete ordinary/function key catalog are
      // shared with Windows and must not be remapped by the macOS modifier
      // adaptation.
      expect(mapPhysicalKeyForRemoteLayout(RemoteKeyboardLayout.MACOS, 2045))
        .assertEqual(2045);
      expect(mapPhysicalKeyForRemoteLayout(RemoteKeyboardLayout.MACOS, 2046))
        .assertEqual(2046);
      expect(mapPhysicalKeyForRemoteLayout(RemoteKeyboardLayout.MACOS, 2047))
        .assertEqual(2047);
      expect(mapPhysicalKeyForRemoteLayout(RemoteKeyboardLayout.MACOS, 2048))
        .assertEqual(2048);
      expect(mapPhysicalKeyForRemoteLayout(RemoteKeyboardLayout.MACOS, 2019))
        .assertEqual(2019);
      expect(mapPhysicalKeyForRemoteLayout(RemoteKeyboardLayout.MACOS, 2059))
        .assertEqual(2059);
      expect(mapPhysicalKeyForRemoteLayout(RemoteKeyboardLayout.MACOS, 2100))
        .assertEqual(2100);
      expect(mapPhysicalKeyForRemoteLayout(RemoteKeyboardLayout.MACOS, 2823))
        .assertEqual(2823);
    });

    it('maps_complete_macos_shortcuts_without_losing_side_or_order', 0, (): void => {
      const commandOptionShiftR: number[] = [2076, 2045, 2047, 2034];
      const mappedCommandOptionShiftR: number[] = commandOptionShiftR.map(
        (keyCode: number): number =>
          mapPhysicalKeyForRemoteLayout(RemoteKeyboardLayout.MACOS, keyCode));
      expect(mappedCommandOptionShiftR.join(','))
        .assertEqual('2072,2045,2047,2034');

      const rightControlSpace: number[] = [2073, 2050];
      const mappedRightControlSpace: number[] = rightControlSpace.map(
        (keyCode: number): number =>
          mapPhysicalKeyForRemoteLayout(RemoteKeyboardLayout.MACOS, keyCode));
      expect(mappedRightControlSpace.join(',')).assertEqual('2077,2050');
    });

    it('asks_for_layout_for_every_cross_platform_remote_keyboard', 0, (): void => {
      expect(shouldChoosePhysicalKeyboardLayout('rdp', true, 'xl')).assertFalse();
      expect(shouldChoosePhysicalKeyboardLayout('rustdesk', true, 'xl')).assertTrue();
      expect(shouldChoosePhysicalKeyboardLayout('rdp', true, 'lg')).assertFalse();
      expect(shouldChoosePhysicalKeyboardLayout('rustdesk', false, 'md')).assertTrue();
      expect(shouldChoosePhysicalKeyboardLayout('vnc', false, 'md')).assertTrue();
      expect(shouldChoosePhysicalKeyboardLayout('moonlight', false, 'md')).assertTrue();
      expect(shouldChoosePhysicalKeyboardLayout('rdp', false, 'sm')).assertFalse();
      expect(shouldChoosePhysicalKeyboardLayout('ssh', true, 'xl')).assertFalse();
      expect(remoteKeyboardLayoutDescription(RemoteKeyboardLayout.MACOS).indexOf('Command') >= 0)
        .assertTrue();
    });

    it('always_uses_windows_layout_for_rdp', 0, (): void => {
      expect(physicalKeyboardLayoutForProtocol('rdp', RemoteKeyboardLayout.MACOS))
        .assertEqual(RemoteKeyboardLayout.WINDOWS);
      expect(physicalKeyboardLayoutForProtocol('rustdesk', RemoteKeyboardLayout.MACOS))
        .assertEqual(RemoteKeyboardLayout.MACOS);
    });

    it('defaults_all_pc_remote_control_modes_to_physical_keyboard_mouse', 0, (): void => {
      expect(remoteControlModeDefaultForDevice(true)).assertEqual(2);
      expect(remoteControlModeDefaultForDevice(false)).assertEqual(0);
    });

    it('never_consumes_phone_or_pad_system_back_gestures', 0, (): void => {
      expect(shouldConsumeRemoteBack(true, false, 'sm', true, true, true)).assertFalse();
      expect(shouldConsumeRemoteBack(true, false, 'md', true, true, true)).assertFalse();
      expect(shouldConsumeRemoteBack(true, true, 'xl', false, true, true)).assertFalse();
      expect(shouldConsumeRemoteBack(true, true, 'xl', true, false, true)).assertFalse();
      expect(shouldConsumeRemoteBack(true, true, 'xl', true, true, false)).assertFalse();
      expect(shouldConsumeRemoteBack(true, true, 'xl', true, true, true)).assertTrue();
      expect(shouldConsumeRemoteBack(true, true, 'lg', true, true, true)).assertTrue();
    });

    it('auto_switches_detected_external_input_only_for_writable_vnc_once', 0, (): void => {
      expect(shouldAutoSwitchVncKeyboardMouseMode(
        'vnc', true, false, true, 0, 7, -1)).assertTrue();
      expect(shouldAutoSwitchVncKeyboardMouseMode(
        'vnc', true, false, true, 0, 7, 7)).assertFalse();
      expect(shouldAutoSwitchVncKeyboardMouseMode(
        'vnc', true, true, true, 0, 7, -1)).assertFalse();
      expect(shouldAutoSwitchVncKeyboardMouseMode(
        'vnc', true, false, false, 0, 7, -1)).assertFalse();
      expect(shouldAutoSwitchVncKeyboardMouseMode(
        'rdp', true, false, true, 0, 7, -1)).assertFalse();
      expect(shouldAutoSwitchVncKeyboardMouseMode(
        'vnc', true, false, true, 2, 7, -1)).assertFalse();
    });
  });
}
