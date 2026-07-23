import { describe, it, expect } from '@ohos/hypium';
import { shouldPublishSnapshot } from '../main/ets/services/DataSnapshotRevisionPolicy';

export default function dataSnapshotRevisionPolicyTest(): void {
  describe('DataSnapshotRevisionPolicy', (): void => {
    it('publishes_the_initial_snapshot_even_when_it_is_empty', 0, (): void => {
      expect(shouldPublishSnapshot(false, '', '')).assertTrue();
    });

    it('suppresses_an_unchanged_follow_up_snapshot', 0, (): void => {
      expect(shouldPublishSnapshot(true, 'same', 'same')).assertFalse();
      expect(shouldPublishSnapshot(true, 'before', 'after')).assertTrue();
    });
  });
}
