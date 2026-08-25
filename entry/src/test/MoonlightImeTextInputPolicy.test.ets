import { expect } from '@ohos/hypium';
import {
  auditedDescribe as describe,
  auditedIt as it
} from '../main/ets/services/FocusedTestRegistrationAudit';
import {
  MoonlightImeKeyStroke,
  moonlightImeAsciiKeyStroke
} from '../main/ets/services/MoonlightImeTextInputPolicy';

export default function moonlightImeTextInputPolicyTest(): void {
  describe('MoonlightImeTextInputPolicy', (): void => {
    it('maps_every_printable_ascii_character_to_one_portable_key_stroke', 0, (): void => {
      for (let code: number = 32; code <= 126; code++) {
        expect(moonlightImeAsciiKeyStroke(String.fromCharCode(code)) !== null).assertTrue();
      }
    });

    it('uses_shift_for_uppercase_and_us_layout_symbols', 0, (): void => {
      const lower: MoonlightImeKeyStroke = moonlightImeAsciiKeyStroke('a') as MoonlightImeKeyStroke;
      const upper: MoonlightImeKeyStroke = moonlightImeAsciiKeyStroke('A') as MoonlightImeKeyStroke;
      const bang: MoonlightImeKeyStroke = moonlightImeAsciiKeyStroke('!') as MoonlightImeKeyStroke;
      const question: MoonlightImeKeyStroke = moonlightImeAsciiKeyStroke('?') as MoonlightImeKeyStroke;
      expect(lower.keyCode).assertEqual(2017);
      expect(lower.shift).assertFalse();
      expect(upper.keyCode).assertEqual(lower.keyCode);
      expect(upper.shift).assertTrue();
      expect(bang.keyCode).assertEqual(2001);
      expect(bang.shift).assertTrue();
      expect(question.keyCode).assertEqual(2064);
      expect(question.shift).assertTrue();
    });

    it('retains_utf8_lane_for_non_ascii_text', 0, (): void => {
      expect(moonlightImeAsciiKeyStroke('中') === null).assertTrue();
      expect(moonlightImeAsciiKeyStroke('🙂') === null).assertTrue();
      expect(moonlightImeAsciiKeyStroke('') === null).assertTrue();
    });
  });
}
