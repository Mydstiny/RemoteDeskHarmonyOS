import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';
import { RustDeskAccount } from '../model/RustDeskAccount';
import { RustDeskRelayConfig } from '../model/RustDeskRelayConfig';
import {
  DataMutationCode,
  DataMutationResult,
  DataMutationStage
} from './DataMutationResult';

export type RustDeskRelaySaveRecovery =
  'none' | 'retry' | 'unlock' | 'wait_for_restore' | 'reload' |
  'review_account' | 'review_fields';

export type RustDeskRelayCloudSyncState =
  'not_configured' | 'pending' | 'completed' | 'failed';

export class RustDeskRelayCloudSyncOutcome {
  state: RustDeskRelayCloudSyncState = 'not_configured';
  failureKind: string = '';
}

export class RustDeskRelaySaveResult {
  ok: boolean = false;
  attemptId: string = '';
  relayId: string = '';
  relayIdFingerprint: string = '';
  stage: DataMutationStage = 'committing';
  code: DataMutationCode = 'local_write_failed';
  message: string = '';
  recovery: RustDeskRelaySaveRecovery = 'retry';
  localCommitted: boolean = false;
  cloudSyncRequested: boolean = false;
  cloudSyncState: RustDeskRelayCloudSyncState =
    'not_configured';
  cloudSyncFailureKind: string = '';

  static fromMutation(
    attemptId: string,
    relayId: string,
    mutation: DataMutationResult,
    cloudSyncRequested: boolean = false
  ): RustDeskRelaySaveResult {
    const result = new RustDeskRelaySaveResult();
    result.ok = mutation.ok;
    result.attemptId = attemptId;
    result.relayId = relayId;
    result.relayIdFingerprint = rustDeskRelayIdFingerprint(relayId);
    result.stage = mutation.stage;
    result.code = mutation.code;
    result.message = rustDeskRelaySaveMessage(mutation.code, mutation.message);
    result.recovery = mutation.stage === 'validating'
      ? 'review_fields' : rustDeskRelaySaveRecoveryForCode(mutation.code);
    result.localCommitted = mutation.localCommitted;
    result.cloudSyncRequested = mutation.ok && cloudSyncRequested;
    result.cloudSyncState = mutation.ok && cloudSyncRequested
      ? 'pending' : 'not_configured';
    return result;
  }

  applyCloudSyncState(
    state: RustDeskRelayCloudSyncState,
    failureKind: string = ''
  ): RustDeskRelaySaveResult {
    this.cloudSyncState = state;
    this.cloudSyncRequested =
      state === 'pending' || state === 'completed' ||
      state === 'failed';
    this.cloudSyncFailureKind =
      state === 'failed' ? failureKind : '';
    return this;
  }

  diagnosticSummary(): string {
    return 'attempt=' + this.attemptId + ' relay=' + this.relayIdFingerprint +
      ' stage=' + this.stage + ' code=' + this.code + ' committed=' +
      this.localCommitted.toString() + ' cloud=' +
      this.cloudSyncState +
      (this.cloudSyncFailureKind === ''
        ? '' : ' cloud_failure=' + this.cloudSyncFailureKind);
  }
}

export function rustDeskRelayCloudSyncMessage(
  state: RustDeskRelayCloudSyncState
): string {
  switch (state) {
    case 'completed': return '云端上传已完成';
    case 'pending': return '本地已保存，云端上传待处理；应用会按日志自动重试';
    case 'failed': return '本地已保存，云端上传失败；可立即重试';
    default: return '本地已保存；当前账号未配置此表的云同步';
  }
}

export function rustDeskRelaySaveRecoveryForCode(
  code: DataMutationCode
): RustDeskRelaySaveRecovery {
  switch (code) {
    case 'unlock_required':
    case 'crypto_lifecycle_blocked':
      return 'unlock';
    case 'restore_in_progress':
      return 'wait_for_restore';
    case 'invalid_data':
      return 'review_account';
    case 'readback_not_found':
    case 'readback_mismatch':
      return 'reload';
    case 'ok':
    case 'unchanged':
      return 'none';
    default:
      return 'retry';
  }
}

export function rustDeskRelaySaveMessage(
  code: DataMutationCode,
  detail: string = ''
): string {
  if (detail.trim().length > 0) { return detail; }
  switch (code) {
    case 'not_ready': return '本地数据库正在准备，请稍后重试。';
    case 'unlock_required': return '加密数据已锁定，请先解锁后再保存。';
    case 'crypto_lifecycle_blocked': return '加密数据生命周期尚未就绪，请先解锁或完成恢复。';
    case 'restore_in_progress': return '数据恢复正在进行，草稿已保留，请稍后重试。';
    case 'invalid_data': return '该中继属于其他账号，请切回原账号或重新添加。';
    case 'metadata_write_failed': return '服务器已回滚：控制面配置写入失败，请重试。';
    case 'journal_write_failed': return '服务器已回滚：本地同步日志写入失败，请重试。';
    case 'readback_not_found': return '服务器已写入，但保存后回读不到记录；请重新载入后重试。';
    case 'readback_mismatch': return '服务器已写入，但保存后校验不一致；请重新载入后重试。';
    case 'local_write_failed': return '本地数据库写入失败，未保存该服务器。';
    case 'not_found': return '要编辑的服务器已不存在，请重新载入列表。';
    default: return code === 'ok' ? '' : '服务器保存未完成，请重试。';
  }
}

export function rustDeskRelayIdFingerprint(relayId: string): string {
  if (relayId.trim().length === 0) { return 'none'; }
  const md = cryptoFramework.createMd('SHA256');
  md.updateSync({ data: new util.TextEncoder().encode(
    'RemoteDeskHarmonyOS:rustdesk-relay:v1:' + relayId.trim()) });
  const digest: Uint8Array = new Uint8Array(md.digestSync().data);
  let result: string = '';
  for (let i = 0; i < digest.length && i < 6; i++) {
    result += digest[i].toString(16).padStart(2, '0');
  }
  return result;
}

function accountsMatch(expected: RustDeskAccount[], actual: RustDeskAccount[]): boolean {
  if (expected.length !== actual.length) { return false; }
  for (let i = 0; i < expected.length; i++) {
    const left: RustDeskAccount = expected[i];
    const right: RustDeskAccount = actual[i];
    if (left.id !== right.id || left.relayId !== right.relayId ||
      left.username !== right.username || left.password !== right.password ||
      left.loginStatus !== right.loginStatus || left.lastLoginAt !== right.lastLoginAt ||
      left.createdAt !== right.createdAt) {
      return false;
    }
  }
  return true;
}

/**
 * Exact post-commit verification without serializing or logging a secret-bearing
 * relay object. createdAt is excluded because RDB owns it for a first insert.
 */
export function rustDeskRelayReadbackMatches(
  expected: RustDeskRelayConfig,
  actual: RustDeskRelayConfig
): boolean {
  return expected.id === actual.id &&
    expected.userId === actual.userId &&
    expected.idServer === actual.idServer &&
    expected.idServerPort === actual.idServerPort &&
    expected.relayServer === actual.relayServer &&
    expected.relayPort === actual.relayPort &&
    expected.apiServer === actual.apiServer &&
    expected.apiUsername === actual.apiUsername &&
    expected.apiPassword === actual.apiPassword &&
    expected.key === actual.key &&
    expected.keyMode === actual.keyMode &&
    expected.controlPlaneProfile === actual.controlPlaneProfile &&
    expected.healthStatus === actual.healthStatus &&
    expected.healthLatency === actual.healthLatency &&
    expected.healthCheckedAt === actual.healthCheckedAt &&
    expected.apiLoginStatus === actual.apiLoginStatus &&
    expected.syncVersion === actual.syncVersion &&
    expected.updatedAt === actual.updatedAt &&
    accountsMatch(expected.accounts, actual.accounts);
}

/** Stable-ID retries are idempotent only for the same configuration payload. */
export function rustDeskRelayCreatePayloadMatches(
  expected: RustDeskRelayConfig,
  actual: RustDeskRelayConfig
): boolean {
  return expected.id === actual.id &&
    expected.idServer === actual.idServer &&
    expected.idServerPort === actual.idServerPort &&
    expected.relayServer === actual.relayServer &&
    expected.relayPort === actual.relayPort &&
    expected.apiServer === actual.apiServer &&
    expected.key === actual.key &&
    expected.keyMode === actual.keyMode &&
    expected.controlPlaneProfile ===
      actual.controlPlaneProfile;
}
