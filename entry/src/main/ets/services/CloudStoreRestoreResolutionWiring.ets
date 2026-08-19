import {
  CloudMetadataReadResult,
  cloudMetadataAbsentProven
} from './CloudMetadataSafetyPolicy';
import {
  CLOUD_SELECTION_REENABLE_BARRIERS_KEY
} from './CloudStoreVncLifecycleWiring';
import {
  CloudSelectionReenablePhase,
  normalizeCloudSelectionReenablePhase
} from './CloudSelectionReenablePolicy';

export const RESTORED_NOT_UPLOADED_KEY: string =
  'restored_not_uploaded';
export const RESTORED_NOT_UPLOADED_TABLE_PREFIX: string =
  'restored_not_uploaded|';
export const CLOUD_BOOTSTRAP_COMPLETED_KEY: string =
  'cloud_bootstrap_completed_v1';
export const CLOUD_SYNC_DURABLE_STATE_KEY: string =
  'cloud_sync_durable_state_v1';

export interface CloudRestoreResolutionPort {
  beginTransaction: () => void;
  commit: () => void;
  rollback: () => void;
  readMetadata: (key: string) =>
    CloudMetadataReadResult;
  writeMetadata: (key: string,
    value: string) => boolean;
  deleteMetadata: (key: string) => boolean;
}

export interface CloudRestoreResolutionResult {
  ok: boolean;
  committed: boolean;
  reason: string;
}

export function writeFullRestoreQuarantineMarkers(
  cloudTables: string[],
  writeMetadata: (key: string,
    value: string) => boolean
): boolean {
  for (let i = 0; i < cloudTables.length; i++) {
    if (!writeMetadata(
      RESTORED_NOT_UPLOADED_TABLE_PREFIX +
      cloudTables[i], '1')) {
      return false;
    }
  }
  return writeMetadata(
    RESTORED_NOT_UPLOADED_KEY, '1');
}

function distinctKnownTables(
  values: string[], cloudTables: string[]
): string[] {
  const result: string[] = [];
  for (let i = 0; i < values.length; i++) {
    if (cloudTables.indexOf(values[i]) >= 0 &&
      result.indexOf(values[i]) < 0) {
      result.push(values[i]);
    }
  }
  return result;
}

/**
 * Returns the exact restored-table marker set. `null` means the metadata
 * boundary is unreadable or internally inconsistent and must fail closed.
 */
export function pendingRestoreResolutionTables(
  cloudTables: string[],
  readMetadata: (key: string) =>
    CloudMetadataReadResult,
  legacyGlobalTables: string[] = cloudTables
): string[] | null {
  const globalMarker: CloudMetadataReadResult =
    readMetadata(RESTORED_NOT_UPLOADED_KEY);
  if (globalMarker.state === 'error' ||
    (globalMarker.state === 'present' &&
      globalMarker.value !== '1')) {
    return null;
  }
  const pending: string[] = [];
  for (let i = 0; i < cloudTables.length; i++) {
    const marker: CloudMetadataReadResult =
      readMetadata(
        RESTORED_NOT_UPLOADED_TABLE_PREFIX +
        cloudTables[i]);
    if (marker.state === 'error' ||
      (marker.state === 'present' &&
        marker.value !== '1')) {
      return null;
    }
    if (marker.state === 'present') {
      pending.push(cloudTables[i]);
    }
  }
  if (globalMarker.state === 'present' &&
    pending.length === 0) {
    // Legacy/full replacement restores wrote only the global marker. They
    // replaced every table that existed in that release. Optional tables added
    // by a later app version must not be inferred from that old marker: doing
    // so would make a missing AGC schema block the original cloud tables.
    const fallback: string[] =
      distinctKnownTables(legacyGlobalTables, cloudTables);
    return fallback.length > 0 ? fallback : cloudTables.slice();
  }
  // A 1.0.x crash could remove the global row before finishing the sequential
  // per-table cleanup. Remaining table rows are still authoritative barriers.
  return pending;
}

function readRemainingBarriers(
  port: CloudRestoreResolutionPort,
  resolvedTables: string[],
  cloudTables: string[]
): Record<string, string> | null {
  const metadata: CloudMetadataReadResult =
    port.readMetadata(
      CLOUD_SELECTION_REENABLE_BARRIERS_KEY);
  if (metadata.state === 'error') { return null; }
  if (metadata.state === 'absent') { return {}; }
  try {
    const raw: Object =
      JSON.parse(metadata.value) as Object;
    if (raw === null || Array.isArray(raw) ||
      typeof raw !== 'object') {
      return null;
    }
    const parsed: Record<string, Object> =
      raw as Record<string, Object>;
    const result: Record<string, string> = {};
    const keys: string[] = Object.keys(parsed);
    for (let i = 0; i < keys.length; i++) {
      if (cloudTables.indexOf(keys[i]) < 0) {
        return null;
      }
      const phase:
        CloudSelectionReenablePhase | null =
        normalizeCloudSelectionReenablePhase(
          parsed[keys[i]]);
      if (phase === null) { return null; }
      if (resolvedTables.indexOf(keys[i]) < 0) {
        result[keys[i]] = phase;
      }
    }
    return result;
  } catch (_error) {
    return null;
  }
}

function metadataMatches(
  port: CloudRestoreResolutionPort,
  key: string, expected: string
): boolean {
  const read: CloudMetadataReadResult =
    port.readMetadata(key);
  return read.state === 'present' &&
    read.value === expected;
}

/**
 * The production restore-resolution transaction entry. The ready lifecycle
 * state, bootstrap marker, restore markers and any covered re-enable barriers
 * become visible together or remain fail-closed together.
 */
export function completeCloudRestoreResolution(
  stateEncoded: string,
  resolvedTables: string[],
  cloudTables: string[],
  port: CloudRestoreResolutionPort,
  legacyGlobalTables: string[] = cloudTables
): CloudRestoreResolutionResult {
  const covered: string[] =
    distinctKnownTables(
      resolvedTables, cloudTables);
  let transactionStarted: boolean = false;
  let committed: boolean = false;
  let remainingBarriers:
    Record<string, string> | null = null;
  let barriersEncoded: string = '';
  try {
    port.beginTransaction();
    transactionStarted = true;
    const pending: string[] | null =
      pendingRestoreResolutionTables(
        cloudTables,
        (key: string):
          CloudMetadataReadResult =>
          port.readMetadata(key),
        legacyGlobalTables);
    if (pending === null) {
      throw new Error(
        'restore marker set is unreadable');
    }
    for (let i = 0; i < pending.length; i++) {
      if (covered.indexOf(pending[i]) < 0) {
        throw new Error(
          'restore table remains unresolved');
      }
    }
    remainingBarriers =
      readRemainingBarriers(
        port, covered, cloudTables);
    if (remainingBarriers === null) {
      throw new Error(
        'selection barrier is unreadable');
    }
    barriersEncoded =
      JSON.stringify(remainingBarriers);
    if (!port.writeMetadata(
      CLOUD_BOOTSTRAP_COMPLETED_KEY, '1') ||
      !port.writeMetadata(
        CLOUD_SYNC_DURABLE_STATE_KEY,
        stateEncoded) ||
      !port.deleteMetadata(
        RESTORED_NOT_UPLOADED_KEY)) {
      throw new Error(
        'restore resolution metadata write failed');
    }
    for (let i = 0; i < cloudTables.length; i++) {
      if (!port.deleteMetadata(
        RESTORED_NOT_UPLOADED_TABLE_PREFIX +
        cloudTables[i])) {
        throw new Error(
          'restore marker delete failed');
      }
    }
    if (Object.keys(remainingBarriers).length === 0) {
      if (!port.deleteMetadata(
        CLOUD_SELECTION_REENABLE_BARRIERS_KEY)) {
        throw new Error(
          'selection barrier delete failed');
      }
    } else if (!port.writeMetadata(
      CLOUD_SELECTION_REENABLE_BARRIERS_KEY,
      barriersEncoded)) {
      throw new Error(
        'selection barrier write failed');
    }
    port.commit();
    committed = true;
  } catch (error) {
    if (transactionStarted && !committed) {
      try { port.rollback(); } catch (_rollbackError) {}
    }
    return {
      ok: false,
      committed,
      reason: error instanceof Error
        ? error.message : 'transaction failed'
    };
  }
  if (!metadataMatches(
    port, CLOUD_BOOTSTRAP_COMPLETED_KEY, '1') ||
    !metadataMatches(
      port, CLOUD_SYNC_DURABLE_STATE_KEY,
      stateEncoded) ||
    !cloudMetadataAbsentProven(
      port.readMetadata(
        RESTORED_NOT_UPLOADED_KEY))) {
    return {
      ok: false, committed: true,
      reason: 'post-commit lifecycle readback failed'
    };
  }
  for (let i = 0; i < cloudTables.length; i++) {
    if (!cloudMetadataAbsentProven(
      port.readMetadata(
        RESTORED_NOT_UPLOADED_TABLE_PREFIX +
        cloudTables[i]))) {
      return {
        ok: false, committed: true,
        reason: 'post-commit marker readback failed'
      };
    }
  }
  const barrierRead: CloudMetadataReadResult =
    port.readMetadata(
      CLOUD_SELECTION_REENABLE_BARRIERS_KEY);
  const barriersVerified: boolean =
    Object.keys(remainingBarriers as
      Record<string, string>).length === 0
      ? cloudMetadataAbsentProven(barrierRead)
      : barrierRead.state === 'present' &&
        barrierRead.value === barriersEncoded;
  if (!barriersVerified) {
    return {
      ok: false, committed: true,
      reason: 'post-commit barrier readback failed'
    };
  }
  return { ok: true, committed: true, reason: '' };
}
