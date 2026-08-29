import { describe, expect, it } from '@ohos/hypium';
import {
  disconnectAllSubmissionMayReleaseTracking,
  nativeSessionStateBlocksAutomaticTransition,
  RemoteSessionTransitionGate,
  RemoteSessionTransitionLease
} from '../main/ets/services/RemoteSessionTransitionGate';

export default function remoteSessionTransitionGateTest(): void {
  describe('RemoteSessionTransitionGate', (): void => {
    it('atomically_blocks_new_sessions_until_the_exact_lease_releases',
      0, (): void => {
        const gate = new RemoteSessionTransitionGate();
        const lease: RemoteSessionTransitionLease | null =
          gate.tryAcquire();
        expect(lease !== null).assertTrue();
        expect(gate.newSessionAllowed()).assertFalse();
        expect(gate.tryAcquire() === null).assertTrue();
        expect(gate.release({ epoch: 999 })).assertFalse();
        expect(gate.newSessionAllowed()).assertFalse();
        expect(gate.release(lease)).assertTrue();
        expect(gate.newSessionAllowed()).assertTrue();
      });

    it('stale_detached_native_sessions_do_not_block_account_repair',
      0, (): void => {
        expect(nativeSessionStateBlocksAutomaticTransition(0)).assertFalse();
        expect(nativeSessionStateBlocksAutomaticTransition(-1)).assertFalse();
        expect(nativeSessionStateBlocksAutomaticTransition(4)).assertFalse();
        expect(nativeSessionStateBlocksAutomaticTransition(2)).assertTrue();
        expect(nativeSessionStateBlocksAutomaticTransition(3)).assertTrue();
      });

    it('rejected_disconnect_all_retains_background_pending_activity',
      0, (): void => {
        expect(disconnectAllSubmissionMayReleaseTracking(false))
          .assertFalse();
        expect(disconnectAllSubmissionMayReleaseTracking(true))
          .assertTrue();
      });
  });
}
