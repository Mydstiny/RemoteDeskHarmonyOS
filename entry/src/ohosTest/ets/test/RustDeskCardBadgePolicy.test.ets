/** RustDeskCardBadgePolicy.test.ets — host card badge mapping */
import { describe, it, expect } from '@ohos/hypium';
import { resolveRustDeskBadges } from '../../../main/ets/services/RustDeskCardBadgePolicy';

export default function rustDeskCardBadgePolicyTest(): void {
  describe('RustDeskCardBadgePolicy', (): void => {
    it('direct_host_should_show_direct_badge', 0, (): void => {
      expect(resolveRustDeskBadges(true, false).join(',')).assertEqual('直连');
    });

    it('relay_host_should_show_relay_badge', 0, (): void => {
      expect(resolveRustDeskBadges(false, false).join(',')).assertEqual('中继');
    });

    it('pro_relay_host_should_show_both_badges', 0, (): void => {
      expect(resolveRustDeskBadges(false, true).join(',')).assertEqual('Pro,中继');
    });
  });
}
