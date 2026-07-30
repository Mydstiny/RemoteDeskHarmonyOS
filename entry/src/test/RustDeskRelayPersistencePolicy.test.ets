import { describe, expect, it } from '@ohos/hypium';
import { RustDeskRelayConfig } from '../main/ets/model/RustDeskRelayConfig';
import {
  commitRustDeskRelayPersistence,
  executeRustDeskRelayPersistence,
  RustDeskRelayPersistenceGate,
  RustDeskRelayPersistencePort,
  rustDeskRelayPersistenceGateResult,
  verifyRustDeskRelayPersistence
} from '../main/ets/services/RustDeskRelayPersistencePolicy';

function relay(): RustDeskRelayConfig {
  const value = new RustDeskRelayConfig();
  value.id = 'relay-stable';
  value.userId = 'owner-local';
  value.idServer = 'rd.example.test';
  value.idServerPort = 21116;
  value.relayServer = 'rd.example.test';
  value.relayPort = 21117;
  value.key = 'server-key';
  value.keyMode = 'server_public_key';
  value.updatedAt = 42;
  return value;
}

class FaultPort implements RustDeskRelayPersistencePort {
  failure: string = '';
  rollbackCount: number = 0;
  commitCount: number = 0;
  stored: RustDeskRelayConfig | null = relay();

  beginTransaction(): void {
    if (this.failure === 'begin') {
      throw new Error('injected begin');
    }
  }

  upsertRelay(): boolean {
    return this.failure !== 'upsert';
  }

  writeControlPlaneProfile(): boolean {
    return this.failure !== 'profile';
  }

  recordMutationJournal(): boolean {
    return this.failure !== 'journal';
  }

  commit(): void {
    if (this.failure === 'commit') {
      throw new Error('injected commit');
    }
    this.commitCount++;
  }

  rollback(): void {
    this.rollbackCount++;
  }

  readback(): RustDeskRelayConfig | null {
    if (this.failure === 'readback_throw') {
      throw new Error('injected readback');
    }
    if (this.failure === 'readback_missing') {
      return null;
    }
    const value: RustDeskRelayConfig | null =
      this.stored === null
        ? null
        : RustDeskRelayConfig.fromJSON(
          this.stored.toJSON());
    if (value !== null &&
      this.failure === 'readback_mismatch') {
      value.relayPort = 30000;
    }
    return value;
  }
}

export default function rustDeskRelayPersistencePolicyTest():
  void {
  describe('RustDeskRelayPersistencePolicy', (): void => {
    it('rolls_back_each_transaction_substep_failure',
      0, (): void => {
        const failures: string[] = [
          'upsert', 'profile', 'journal', 'commit'
        ];
        const expectedCodes: string[] = [
          'local_write_failed', 'metadata_write_failed',
          'journal_write_failed', 'local_write_failed'
        ];
        for (let i = 0; i < failures.length; i++) {
          const port = new FaultPort();
          port.failure = failures[i];
          const result =
            commitRustDeskRelayPersistence(
              relay(), port);
          expect(result.ok).assertFalse();
          expect(result.code).assertEqual(
            expectedCodes[i]);
          expect(port.rollbackCount).assertEqual(1);
          expect(port.commitCount).assertEqual(0);
        }
        const begin = new FaultPort();
        begin.failure = 'begin';
        const beginResult =
          commitRustDeskRelayPersistence(
            relay(), begin);
        expect(beginResult.ok).assertFalse();
        expect(begin.rollbackCount).assertEqual(0);
      });

    it('keeps_commit_success_distinct_from_readback_failure',
      0, (): void => {
        const failures: string[] = [
          'readback_missing', 'readback_throw',
          'readback_mismatch'
        ];
        const expectedCodes: string[] = [
          'readback_not_found', 'readback_not_found',
          'readback_mismatch'
        ];
        for (let i = 0; i < failures.length; i++) {
          const port = new FaultPort();
          port.failure = failures[i];
          const committed =
            commitRustDeskRelayPersistence(
              relay(), port);
          expect(committed.ok).assertTrue();
          const verified =
            verifyRustDeskRelayPersistence(
              relay(), port);
          expect(verified.ok).assertFalse();
          expect(verified.localCommitted).assertTrue();
          expect(verified.code).assertEqual(
            expectedCodes[i]);
          expect(port.rollbackCount).assertEqual(0);
        }
      });

    it('uses_the_same_stable_id_for_duplicate_idempotent_upserts',
      0, (): void => {
        const first = new FaultPort();
        const firstResult =
          executeRustDeskRelayPersistence(
            relay(), first);
        const second = new FaultPort();
        const secondResult =
          executeRustDeskRelayPersistence(
            relay(), second);
        expect(firstResult.ok).assertTrue();
        expect(secondResult.ok).assertTrue();
        expect(firstResult.recordId)
          .assertEqual('relay-stable');
        expect(secondResult.recordId)
          .assertEqual('relay-stable');
        expect(first.commitCount).assertEqual(1);
        expect(second.commitCount).assertEqual(1);
      });

    it('fails_closed_at_owner_restore_and_crypto_gates',
      0, (): void => {
        const base: RustDeskRelayPersistenceGate = {
          storeReady: true,
          localMutationAllowed: true,
          ownerAllowed: true,
          sensitiveWriteAllowed: true,
          sensitiveFailure: null
        };
        base.localMutationAllowed = false;
        expect(rustDeskRelayPersistenceGateResult(
          'relay-stable', base)?.code)
          .assertEqual('restore_in_progress');
        base.localMutationAllowed = true;
        base.ownerAllowed = false;
        expect(rustDeskRelayPersistenceGateResult(
          'relay-stable', base)?.code)
          .assertEqual('invalid_data');
        base.ownerAllowed = true;
        base.sensitiveWriteAllowed = false;
        expect(rustDeskRelayPersistenceGateResult(
          'relay-stable', base)?.code)
          .assertEqual('crypto_lifecycle_blocked');
      });
  });
}
