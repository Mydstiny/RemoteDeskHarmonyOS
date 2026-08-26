import { describe, it, expect } from '@ohos/hypium';
import {
  normalizeVncPhysicalKeyCode,
  normalizeVncPhysicalKeyEventCode,
  resolveVncPhysicalModifierState,
  VncPhysicalKeyBindingTracker
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

    it('uses_named_function_keys_before_overlapping_android_codes', 0, (): void => {
      expect(normalizeVncPhysicalKeyEventCode(112, 'F1')).assertEqual(2090);
      expect(normalizeVncPhysicalKeyEventCode(113, 'KEYCODE_F2')).assertEqual(2091);
      expect(normalizeVncPhysicalKeyEventCode(123, 'F12')).assertEqual(2101);
      expect(normalizeVncPhysicalKeyEventCode(124, 'F13')).assertEqual(2816);
      expect(normalizeVncPhysicalKeyEventCode(135, 'F24')).assertEqual(2827);
      expect(normalizeVncPhysicalKeyEventCode(46, 'ForwardDelete')).assertEqual(2071);
    });

    it('recovers_unnamed_windows_function_row_before_android_fallback', 0, (): void => {
      expect(normalizeVncPhysicalKeyEventCode(112, '', {
        unicode: 0, ctrl: false, alt: false, shift: false, meta: false
      })).assertEqual(2090);
      expect(normalizeVncPhysicalKeyEventCode(123, '', {
        unicode: 0, ctrl: false, alt: false, shift: false, meta: false
      })).assertEqual(2101);
      expect(normalizeVncPhysicalKeyEventCode(113, '', {
        unicode: 0, ctrl: true, alt: false, shift: false, meta: false
      })).assertEqual(2072);
      expect(normalizeVncPhysicalKeyEventCode(112, 'ForwardDelete', {
        unicode: 0, ctrl: false, alt: false, shift: false, meta: false
      })).assertEqual(2071);
    });

    it('recovers_unnamed_dom_modifiers_without_reclassifying_printable_keys', 0, (): void => {
      expect(normalizeVncPhysicalKeyEventCode(16, '', {
        unicode: 0, ctrl: false, alt: false, shift: true, meta: false
      })).assertEqual(2047);
      expect(normalizeVncPhysicalKeyEventCode(16, '', {
        unicode: 0, ctrl: false, alt: false, shift: false, meta: false
      })).assertEqual(2047);
      expect(normalizeVncPhysicalKeyEventCode(16, '', {
        unicode: 57, ctrl: false, alt: false, shift: true, meta: false
      })).assertEqual(2009);
      expect(normalizeVncPhysicalKeyEventCode(17, '', {
        unicode: 0, ctrl: false, alt: false, shift: false, meta: false
      })).assertEqual(2072);
      expect(normalizeVncPhysicalKeyEventCode(18, '', {
        unicode: 0, ctrl: false, alt: false, shift: false, meta: false
      })).assertEqual(2045);
      expect(normalizeVncPhysicalKeyEventCode(160, '', {
        unicode: 0, ctrl: false, alt: false, shift: false, meta: false
      })).assertEqual(2047);
      expect(normalizeVncPhysicalKeyEventCode(161, '', {
        unicode: 0, ctrl: false, alt: false, shift: false, meta: false
      })).assertEqual(2048);
      expect(normalizeVncPhysicalKeyEventCode(162, '', {
        unicode: 0, ctrl: false, alt: false, shift: false, meta: false
      })).assertEqual(2072);
      expect(normalizeVncPhysicalKeyEventCode(163, '', {
        unicode: 0, ctrl: false, alt: false, shift: false, meta: false
      })).assertEqual(2073);
      expect(normalizeVncPhysicalKeyEventCode(164, '', {
        unicode: 0, ctrl: false, alt: false, shift: false, meta: false
      })).assertEqual(2045);
      expect(normalizeVncPhysicalKeyEventCode(165, '', {
        unicode: 0, ctrl: false, alt: false, shift: false, meta: false
      })).assertEqual(2046);
      expect(normalizeVncPhysicalKeyEventCode(161, '', {
        unicode: 61, ctrl: false, alt: false, shift: false, meta: false
      })).assertEqual(2120);
    });

    it('keeps_an_explicit_modifier_hold_when_pc_snapshot_is_false', 0, (): void => {
      expect(resolveVncPhysicalModifierState(false, false, true)).assertTrue();
      expect(resolveVncPhysicalModifierState(true, false, false)).assertTrue();
      expect(resolveVncPhysicalModifierState(false, true, false)).assertTrue();
      expect(resolveVncPhysicalModifierState(false, false, false)).assertFalse();
    });

    it('keeps_down_up_mapping_stable_across_previews_and_missing_release_text', 0, (): void => {
      const tracker = new VncPhysicalKeyBindingTracker();
      expect(tracker.resolve(7, 112, 'down', 2090, false)).assertEqual(2090);
      expect(tracker.resolve(7, 112, 'down', 2090, true)).assertEqual(2090);
      expect(tracker.resolve(7, 112, 'up', 2071, false)).assertEqual(2090);
      expect(tracker.resolve(7, 112, 'up', 2071, true)).assertEqual(2090);
      expect(tracker.resolve(7, 112, 'down', 2071, false)).assertEqual(2071);
    });
  });
}
