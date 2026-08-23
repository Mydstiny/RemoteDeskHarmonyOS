import { describe, expect, it } from '@ohos/hypium';
import {
  isAutomaticGuideMarkerKey,
  MOONLIGHT_CONTEXTUAL_GUIDE_STORAGE_KEY,
  remoteTouchpadGuideStorageKey,
  shouldPresentAutomaticGuide,
  SSH_CONTEXTUAL_GUIDE_STORAGE_KEY
} from '../main/ets/services/GuideVisibilityPolicy';

export default function guideVisibilityPolicyTest(): void {
  describe('GuideVisibilityPolicy', (): void => {
    it('shows_each_automatic_guide_once_by_default', 0, (): void => {
      expect(shouldPresentAutomaticGuide(false, false, false)).assertTrue();
      expect(shouldPresentAutomaticGuide(true, false, false)).assertFalse();
      expect(shouldPresentAutomaticGuide(false, false, true)).assertFalse();
    });

    it('always_visible_reopens_only_in_a_later_session', 0, (): void => {
      expect(shouldPresentAutomaticGuide(true, true, false)).assertTrue();
      expect(shouldPresentAutomaticGuide(true, true, true)).assertFalse();
    });

    it('keeps_markers_scoped_to_each_automatic_guide', 0, (): void => {
      const rdpKey: string = remoteTouchpadGuideStorageKey('rdp');
      const rustDeskKey: string = remoteTouchpadGuideStorageKey('rustdesk');
      const vncKey: string = remoteTouchpadGuideStorageKey('vnc');
      expect(rdpKey === rustDeskKey).assertFalse();
      expect(rustDeskKey === vncKey).assertFalse();
      expect(isAutomaticGuideMarkerKey(rdpKey)).assertTrue();
      expect(isAutomaticGuideMarkerKey(rustDeskKey)).assertTrue();
      expect(isAutomaticGuideMarkerKey(vncKey)).assertTrue();
      expect(isAutomaticGuideMarkerKey(SSH_CONTEXTUAL_GUIDE_STORAGE_KEY)).assertTrue();
      expect(isAutomaticGuideMarkerKey(MOONLIGHT_CONTEXTUAL_GUIDE_STORAGE_KEY)).assertTrue();
      expect(isAutomaticGuideMarkerKey('unknown-guide')).assertFalse();
    });
  });
}
