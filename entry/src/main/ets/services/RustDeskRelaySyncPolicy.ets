/**
 * RustDeskRelaySyncPolicy — 中继配置本地写入与云快照合并规则。
 *
 * 本地保存后的云变化回调可能携带旧快照；配置时间戳优先，旧版本没有
 * 时间戳时再使用本地观测时间作为兼容兜底。
 */
export function shouldKeepLocalRelayConfig(localUpdatedAt: number, cloudUpdatedAt: number,
  localObservedAt: number, previousSnapshotAt: number): boolean {
  if (localUpdatedAt > 0 && cloudUpdatedAt > 0 && localUpdatedAt !== cloudUpdatedAt) {
    return localUpdatedAt > cloudUpdatedAt;
  }
  if (localUpdatedAt > 0 && cloudUpdatedAt <= 0) {
    return true;
  }
  return localObservedAt > previousSnapshotAt;
}

export function shouldKeepDeletedRelay(deletedAt: number, cloudUpdatedAt: number,
  previousSnapshotAt: number): boolean {
  if (deletedAt <= 0) {
    return false;
  }
  if (cloudUpdatedAt > 0) {
    return deletedAt > cloudUpdatedAt;
  }
  return deletedAt > previousSnapshotAt;
}
