import { describe, expect, it } from '@ohos/hypium';
import {
  resolveOperationGuideSheetLayout
} from '../main/ets/services/GuideSheetLayoutPolicy';

export default function guideSheetLayoutPolicyTest(): void {
  describe('GuideSheetLayoutPolicy', (): void => {
    it('caps_short_phone_sheet_and_keeps_lessons_scrollable', 0, (): void => {
      const layout = resolveOperationGuideSheetLayout(560, 'sm', 3, 5, true);
      expect(layout.height).assertEqual(544);
      expect(layout.compact).assertTrue();
      expect(layout.lessonViewportHeight).assertEqual(244);
    });

    it('shrinks_filtered_content_instead_of_leaving_a_large_tail', 0, (): void => {
      const filtered = resolveOperationGuideSheetLayout(1000, 'xl', 2, 2, false);
      const complete = resolveOperationGuideSheetLayout(1000, 'xl', 9, 5, true);
      expect(filtered.height).assertEqual(584);
      expect(complete.height).assertEqual(780);
      expect(filtered.height < complete.height).assertTrue();
    });

    it('uses_measured_wrapped_content_when_available', 0, (): void => {
      const estimated = resolveOperationGuideSheetLayout(900, 'md', 2, 2, false);
      const measured = resolveOperationGuideSheetLayout(900, 'md', 2, 2, false, 310);
      expect(estimated.height).assertEqual(584);
      expect(measured.height).assertEqual(660);
    });

    it('falls_back_safely_before_the_first_viewport_measurement', 0, (): void => {
      const layout = resolveOperationGuideSheetLayout(0, 'sm', 2, 2, false);
      expect(layout.height).assertEqual(584);
      expect(layout.height <= layout.availableHeight).assertTrue();
    });
  });
}
