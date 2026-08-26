import { expect } from '@ohos/hypium';
import {
  auditedDescribe as describe,
  auditedIt as it
} from '../main/ets/services/FocusedTestRegistrationAudit';
import {
  RemoteSessionServiceLease,
  RemoteSessionServiceOwnerTokenAllocator,
  cloneRemoteSessionServiceLease,
  remoteSessionServiceLeaseCanClaim,
  remoteSessionServiceLeaseEquals,
  remoteSessionServiceLeaseIsValid,
  remoteSessionServiceLeaseMatchesSession,
  remoteSessionServiceRestoreGeneration
} from '../main/ets/services/RemoteSessionServiceLeasePolicy';

export default function remoteSessionServiceLeasePolicyTest(): void {
  describe('RemoteSessionServiceLeasePolicy', (): void => {
    it('requires_an_exact_protocol_host_session_generation_and_owner', 0, (): void => {
      const moonlight: RemoteSessionServiceLease = {
        protocol: 'moonlight', hostId: 'host-a', sessionId: 41,
        generation: 3, ownerToken: 9001
      };
      const same: RemoteSessionServiceLease =
        cloneRemoteSessionServiceLease(moonlight);
      const rdp: RemoteSessionServiceLease = {
        protocol: 'rdp', hostId: 'host-b', sessionId: 42,
        generation: 4, ownerToken: 9002
      };
      expect(remoteSessionServiceLeaseIsValid(moonlight)).assertTrue();
      expect(remoteSessionServiceLeaseEquals(moonlight, same)).assertTrue();
      expect(remoteSessionServiceLeaseCanClaim(null, moonlight)).assertTrue();
      expect(remoteSessionServiceLeaseCanClaim(moonlight, same)).assertTrue();
      expect(remoteSessionServiceLeaseEquals(moonlight, rdp)).assertFalse();
      expect(remoteSessionServiceLeaseCanClaim(moonlight, rdp)).assertFalse();
      expect(remoteSessionServiceLeaseMatchesSession(
        moonlight, 'moonlight', 'host-a', 41)).assertTrue();
      expect(remoteSessionServiceLeaseMatchesSession(
        moonlight, 'rdp', 'host-a', 41)).assertFalse();
      expect(remoteSessionServiceLeaseMatchesSession(
        moonlight, 'moonlight', 'host-a', 42)).assertFalse();
      expect(remoteSessionServiceLeaseIsValid({
        protocol: 'moonlight', hostId: '', sessionId: 41,
        generation: 3, ownerToken: 9001
      })).assertFalse();
    });

    it('allocates_process_wide_monotonic_owner_tokens', 0, (): void => {
      const allocator: RemoteSessionServiceOwnerTokenAllocator =
        RemoteSessionServiceOwnerTokenAllocator.getInstance();
      allocator.resetForTest();
      const firstToken: number = allocator.next(1000);
      const secondToken: number = allocator.next(1000);
      expect(firstToken > 0).assertTrue();
      expect(secondToken > firstToken).assertTrue();
    });

    it('assigns_a_positive_generation_for_registry_restore_without_churning_reentry', 0, (): void => {
      expect(remoteSessionServiceRestoreGeneration(0, -1, 41)).assertEqual(1);
      expect(remoteSessionServiceRestoreGeneration(7, 41, 41)).assertEqual(7);
      expect(remoteSessionServiceRestoreGeneration(7, 41, 42)).assertEqual(8);
      expect(remoteSessionServiceRestoreGeneration(7, 41, 0)).assertEqual(0);
    });
  });
}
