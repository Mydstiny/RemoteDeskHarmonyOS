/**
 * RemoteSessionLiveViewPolicy.test.ets - supported background presentation decisions.
 */
import { describe, it, expect } from '@ohos/hypium';
import { LiveViewMode } from '../../../main/ets/services/LiveViewTypes';
import {
  RemoteSessionLiveViewDelivery,
  resolveRemoteSessionLiveViewDelivery
} from '../../../main/ets/services/RemoteSessionLiveViewPolicy';

export default function remoteSessionLiveViewPolicyTest(): void {
  describe('RemoteSessionLiveViewPolicy', (): void => {
    it('maps_notification_setting_to_supported_background_notification', 0, (): void => {
      expect(resolveRemoteSessionLiveViewDelivery(true, LiveViewMode.NOTIFICATION, true, true))
        .assertEqual(RemoteSessionLiveViewDelivery.BACKGROUND_NOTIFICATION);
    });

    it('uses_avsession_only_when_real_media_is_available', 0, (): void => {
      expect(resolveRemoteSessionLiveViewDelivery(true, LiveViewMode.AVSESSION, true, false))
        .assertEqual(RemoteSessionLiveViewDelivery.AVSESSION);
      expect(resolveRemoteSessionLiveViewDelivery(true, LiveViewMode.AVSESSION, false, true))
        .assertEqual(RemoteSessionLiveViewDelivery.AVSESSION);
      expect(resolveRemoteSessionLiveViewDelivery(true, LiveViewMode.AVSESSION, false, false))
        .assertEqual(RemoteSessionLiveViewDelivery.BACKGROUND_NOTIFICATION);
    });

    it('returns_none_when_disabled_or_explicitly_off', 0, (): void => {
      expect(resolveRemoteSessionLiveViewDelivery(false, LiveViewMode.AVSESSION, true, true))
        .assertEqual(RemoteSessionLiveViewDelivery.NONE);
      expect(resolveRemoteSessionLiveViewDelivery(true, LiveViewMode.OFF, true, true))
        .assertEqual(RemoteSessionLiveViewDelivery.NONE);
    });
  });
}
