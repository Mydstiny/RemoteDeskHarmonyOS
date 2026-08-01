import { RustDeskRelayConfig } from '../model/RustDeskRelayConfig';
import {
  DataMutationCode,
  DataMutationResult
} from './DataMutationResult';
import {
  rustDeskRelayReadbackMatches
} from './RustDeskRelaySavePolicy';

export interface RustDeskRelayPersistencePort {
  beginTransaction: () => void
  upsertRelay: () => boolean
  writeControlPlaneProfile: () => boolean
  recordMutationJournal: () => boolean
  commit: () => void
  rollback: () => void
  readback: () => RustDeskRelayConfig | null
}

export interface RustDeskRelayPersistenceGate {
  storeReady: boolean
  localMutationAllowed: boolean
  ownerAllowed: boolean
  sensitiveWriteAllowed: boolean
  sensitiveFailure: DataMutationResult | null
}

export function rustDeskRelayPersistenceGateResult(
  relayId: string,
  gate: RustDeskRelayPersistenceGate
): DataMutationResult | null {
  if (!gate.storeReady) {
    return DataMutationResult.failure(
      relayId, 'not_ready', '本地数据库未就绪',
      'waiting_gate');
  }
  if (!gate.localMutationAllowed) {
    return DataMutationResult.failure(
      relayId, 'restore_in_progress',
      '恢复进行中，暂不能保存', 'waiting_gate');
  }
  if (!gate.ownerAllowed) {
    return DataMutationResult.failure(
      relayId, 'invalid_data',
      'RustDesk 中继属于其他账号，已拒绝保存',
      'waiting_gate');
  }
  if (!gate.sensitiveWriteAllowed) {
    if (gate.sensitiveFailure !== null) {
      return DataMutationResult.failure(
        relayId, gate.sensitiveFailure.code,
        gate.sensitiveFailure.message, 'waiting_gate');
    }
    return DataMutationResult.failure(
      relayId, 'crypto_lifecycle_blocked',
      '加密数据生命周期尚未就绪',
      'waiting_gate');
  }
  return null;
}

/**
 * The production transaction boundary. Verification is deliberately separate
 * so the UI path can yield a frame after commit and before stable-ID readback.
 */
export function commitRustDeskRelayPersistence(
  relay: RustDeskRelayConfig,
  port: RustDeskRelayPersistencePort
): DataMutationResult {
  let code: DataMutationCode = 'local_write_failed';
  let begun: boolean = false;
  try {
    port.beginTransaction();
    begun = true;
    if (!port.upsertRelay()) {
      throw new Error('relay upsert failed');
    }
    code = 'metadata_write_failed';
    if (!port.writeControlPlaneProfile()) {
      throw new Error('relay profile write failed');
    }
    code = 'journal_write_failed';
    if (!port.recordMutationJournal()) {
      throw new Error('relay journal write failed');
    }
    code = 'local_write_failed';
    port.commit();
    return DataMutationResult.success(
      relay.id, 'ok', 'verifying');
  } catch (_err) {
    if (begun) {
      try { port.rollback(); } catch (_rollbackError) {}
    }
    return DataMutationResult.failure(
      relay.id, code, 'RustDesk 中继保存未完成',
      'committing');
  }
}

export function verifyRustDeskRelayPersistence(
  relay: RustDeskRelayConfig,
  port: RustDeskRelayPersistencePort
): DataMutationResult {
  let readback: RustDeskRelayConfig | null = null;
  try {
    readback = port.readback();
  } catch (_err) {
    readback = null;
  }
  if (readback === null) {
    return DataMutationResult.failure(
      relay.id, 'readback_not_found',
      'RustDesk 中继提交后无法回读',
      'verifying', true);
  }
  if (!rustDeskRelayReadbackMatches(relay, readback)) {
    return DataMutationResult.failure(
      relay.id, 'readback_mismatch',
      'RustDesk 中继提交后校验不一致',
      'verifying', true);
  }
  return DataMutationResult.success(relay.id);
}

export function executeRustDeskRelayPersistence(
  relay: RustDeskRelayConfig,
  port: RustDeskRelayPersistencePort
): DataMutationResult {
  const committed: DataMutationResult =
    commitRustDeskRelayPersistence(relay, port);
  return committed.ok
    ? verifyRustDeskRelayPersistence(relay, port)
    : committed;
}
