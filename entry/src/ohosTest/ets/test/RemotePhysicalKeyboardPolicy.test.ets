import { describe, it, expect } from '@ohos/hypium';
import {
  HARMONY_KEYCODE_CTRL_LEFT,
  HARMONY_KEYCODE_CTRL_RIGHT,
  HARMONY_KEYCODE_META_LEFT,
  HARMONY_KEYCODE_META_RIGHT,
  isMacCapsLockLongPress,
  mapPhysicalKeyForRemoteLayout,
  RemoteKeyboardLayout,
  remoteKeyboardLayoutDescription,
  shouldChoosePhysicalKeyboardLayout,
  shouldConsumeRemoteBack
} from '../../../main/ets/services/RemotePhysicalKeyboardPolicy';

export default function remotePhysicalKeyboardPolicyTest(): void {
  describe('RemotePhysicalKeyboardPolicy', (): void => {
    it('keeps_windows_modifier_layout_unchanged', 0, (): void => {
      expect(mapPhysicalKeyForRemoteLayout(RemoteKeyboardLayout.WINDOWS,
        HARMONY_KEYCODE_CTRL_LEFT)).assertEqual(HARMONY_KEYCODE_CTRL_LEFT);
      expect(mapPhysicalKeyForRemoteLayout(RemoteKeyboardLayout.WINDOWS,
        HARMONY_KEYCODE_META_RIGHT)).assertEqual(HARMONY_KEYCODE_META_RIGHT);
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
    });

    it('supports_remote_keyboard_layout_on_every_device_class', 0, (): void => {
      expect(shouldChoosePhysicalKeyboardLayout('rdp', true, 'xl')).assertTrue();
      expect(shouldChoosePhysicalKeyboardLayout('rustdesk', true, 'xl')).assertTrue();
      expect(shouldChoosePhysicalKeyboardLayout('rdp', true, 'lg')).assertTrue();
      expect(shouldChoosePhysicalKeyboardLayout('rustdesk', false, 'md')).assertTrue();
      expect(shouldChoosePhysicalKeyboardLayout('rdp', false, 'sm')).assertTrue();
      expect(shouldChoosePhysicalKeyboardLayout('ssh', true, 'xl')).assertFalse();
      expect(remoteKeyboardLayoutDescription(RemoteKeyboardLayout.MACOS).indexOf('Command') >= 0)
        .assertTrue();
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
  });
}
