import { describe, it, expect } from '@ohos/hypium';
import {
  shouldKeepDeletedRelay,
  shouldKeepLocalRelayConfig
} from '../main/ets/services/RustDeskRelaySyncPolicy';

export default function rustDeskRelaySyncPolicyTest(): void {
  describe('RustDeskRelaySyncPolicy', (): void => {
    it('keeps_local_config_when_local_timestamp_is_newer', 0, (): void => {
      expect(shouldKeepLocalRelayConfig(200, 100, 0, 0)).assertTrue();
      expect(shouldKeepLocalRelayConfig(100, 200, 0, 0)).assertFalse();
    });

    it('keeps_local_config_for_legacy_cloud_rows_after_local_edit', 0, (): void => {
      expect(shouldKeepLocalRelayConfig(0, 0, 500, 400)).assertTrue();
      expect(shouldKeepLocalRelayConfig(0, 0, 400, 500)).assertFalse();
    });

    it('keeps_newer_local_delete_from_old_cloud_snapshot', 0, (): void => {
      expect(shouldKeepDeletedRelay(300, 200, 0)).assertTrue();
      expect(shouldKeepDeletedRelay(200, 300, 0)).assertFalse();
      expect(shouldKeepDeletedRelay(300, 0, 250)).assertTrue();
    });
  });
}
