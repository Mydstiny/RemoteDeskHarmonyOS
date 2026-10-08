import { describe, it, expect } from '@ohos/hypium';
import {
  PRO_FEEDBACK_CHANLIAN_MANIFEST_URL,
  PRO_FEEDBACK_FEATURE,
  PRO_FEEDBACK_QQ_MANIFEST_URL
} from '../main/ets/services/pro/ProFeedbackPolicy';

export default function proFeedbackPolicyTest() {
  describe('ProFeedbackPolicy', (): void => {
    it('uses_two_distinct_trusted_manifest_endpoints', 0, (): void => {
      expect(PRO_FEEDBACK_FEATURE).assertEqual('pro.feedback');
      expect(PRO_FEEDBACK_CHANLIAN_MANIFEST_URL).assertEqual(
        'https://lijiong.online/feedback/pro-chanlian.json');
      expect(PRO_FEEDBACK_QQ_MANIFEST_URL).assertEqual(
        'https://lijiong.online/feedback/pro-qq.json');
      expect(PRO_FEEDBACK_CHANLIAN_MANIFEST_URL === PRO_FEEDBACK_QQ_MANIFEST_URL).assertFalse();
    });
  });
}
