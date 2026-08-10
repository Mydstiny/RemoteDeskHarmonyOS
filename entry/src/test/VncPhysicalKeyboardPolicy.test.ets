import { describe, it, expect } from '@ohos/hypium';
import {
  normalizeVncPhysicalKeyCode,
  normalizeVncPhysicalKeyEventCode
} from '../main/ets/services/VncPhysicalKeyboardPolicy';

export default function vncPhysicalKeyboardPolicyTest(): void {
  describe('VncPhysicalKeyboardPolicy', (): void => {
    it('keeps_harmony_codes_idempotent', 0, (): void => {
      expect(normalizeVncPhysicalKeyCode(2000)).assertEqual(2000);
      expect(normalizeVncPhysicalKeyCode(2017)).assertEqual(2017);
      expect(normalizeVncPhysicalKeyCode(2074)).assertEqual(2074);
      expect(normalizeVncPhysicalKeyCode(2103)).assertEqual(2103);
      expect(normalizeVncPhysicalKeyCode(2816)).assertEqual(2816);
    });

    it('normalizes_android_external_keyboard_codes', 0, (): void => {
      expect(normalizeVncPhysicalKeyCode(7)).assertEqual(2000);
      expect(normalizeVncPhysicalKeyCode(16)).assertEqual(2009);
      expect(normalizeVncPhysicalKeyCode(29)).assertEqual(2017);
      expect(normalizeVncPhysicalKeyCode(54)).assertEqual(2042);
      expect(normalizeVncPhysicalKeyCode(19)).assertEqual(2012);
      expect(normalizeVncPhysicalKeyCode(23)).assertEqual(2054);
      expect(normalizeVncPhysicalKeyCode(57)).assertEqual(2045);
      expect(normalizeVncPhysicalKeyCode(62)).assertEqual(2050);
      expect(normalizeVncPhysicalKeyCode(113)).assertEqual(2072);
      expect(normalizeVncPhysicalKeyCode(118)).assertEqual(2077);
      expect(normalizeVncPhysicalKeyCode(131)).assertEqual(2090);
      expect(normalizeVncPhysicalKeyCode(142)).assertEqual(2101);
      expect(normalizeVncPhysicalKeyCode(144)).assertEqual(2103);
      expect(normalizeVncPhysicalKeyCode(163)).assertEqual(2122);
    });

    it('normalizes_desktop_physical_key_codes_without_touching_other_values', 0, (): void => {
      expect(normalizeVncPhysicalKeyCode(65)).assertEqual(2017);
      expect(normalizeVncPhysicalKeyCode(90)).assertEqual(2042);
      expect(normalizeVncPhysicalKeyCode(186)).assertEqual(2062);
      expect(normalizeVncPhysicalKeyCode(192)).assertEqual(2056);
      expect(normalizeVncPhysicalKeyCode(219)).assertEqual(2059);
      expect(normalizeVncPhysicalKeyCode(222)).assertEqual(2063);
      expect(normalizeVncPhysicalKeyCode(2816)).assertEqual(2816);
      expect(normalizeVncPhysicalKeyCode(0x10039)).assertEqual(0x10039);
    });

    it('disambiguates_dom_modifier_names_from_android_digit_codes', 0, (): void => {
      expect(normalizeVncPhysicalKeyEventCode(16, 'KEYCODE_SHIFT_LEFT')).assertEqual(2047);
      expect(normalizeVncPhysicalKeyEventCode(16, 'Shift')).assertEqual(2047);
      expect(normalizeVncPhysicalKeyEventCode(17, 'KEYCODE_CTRL_LEFT')).assertEqual(2072);
      expect(normalizeVncPhysicalKeyEventCode(32, 'KEYCODE_SPACE')).assertEqual(2050);
      expect(normalizeVncPhysicalKeyEventCode(16, 'KEYCODE_9')).assertEqual(2009);
    });
  });
}
