import { describe, it, expect } from '@ohos/hypium';
import {
  shouldKeepDeletedHost,
  shouldKeepLocalHostConfig
} from '../main/ets/services/HostSyncMergePolicy';

export default function hostSyncMergePolicyTest(): void {
  describe('HostSyncMergePolicy', (): void => {
    it('keeps_local_host_config_after_local_write', 0, (): void => {
      expect(shouldKeepLocalHostConfig(200, 100)).assertTrue();
      expect(shouldKeepLocalHostConfig(100, 200)).assertFalse();
    });

    it('keeps_local_delete_from_old_cloud_snapshot', 0, (): void => {
      expect(shouldKeepDeletedHost(300, 200)).assertTrue();
      expect(shouldKeepDeletedHost(200, 300)).assertFalse();
    });
  });
}
