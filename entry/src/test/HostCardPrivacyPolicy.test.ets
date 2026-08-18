import { describe, it, expect } from '@ohos/hypium';
import {
  HOST_CARD_SENSITIVE_INFO_HIDDEN_TEXT,
  hostCardDisplayLabel,
  hostCardSensitiveValue,
  shouldHideHostCardSensitiveInfo
} from '../main/ets/services/HostCardPrivacyPolicy';

export default function hostCardPrivacyPolicyTest(): void {
  describe('HostCardPrivacyPolicy', (): void => {
    it('hides_card_details_when_the_device_preference_is_enabled', 0, (): void => {
      expect(shouldHideHostCardSensitiveInfo(true, false)).assertTrue();
      expect(hostCardSensitiveValue(true, 'admin@10.0.0.8:22'))
        .assertEqual(HOST_CARD_SENSITIVE_INFO_HIDDEN_TEXT);
    });

    it('also_hides_details_for_a_locked_host', 0, (): void => {
      expect(shouldHideHostCardSensitiveInfo(false, true)).assertTrue();
    });

    it('keeps_the_original_value_when_no_privacy_rule_applies', 0, (): void => {
      expect(shouldHideHostCardSensitiveInfo(false, false)).assertFalse();
      expect(hostCardSensitiveValue(false, '192.168.1.20:3389'))
        .assertEqual('192.168.1.20:3389');
    });

    it('replaces_only_rustdesk_ids_that_are_used_as_fallback_labels', 0, (): void => {
      expect(hostCardDisplayLabel(true, 'rustdesk', '83920133', '83920133', ''))
        .assertEqual('RustDesk 主机');
      expect(hostCardDisplayLabel(true, 'rustdesk', 'Office PC', '83920133', '83920133'))
        .assertEqual('Office PC');
      expect(hostCardDisplayLabel(false, 'rustdesk', '83920133', '83920133', ''))
        .assertEqual('83920133');
    });
  });
}
