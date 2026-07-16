/**
 * HostSyncMergePolicy — 主机配置与云快照的本地优先合并规则。
 *
 * RemoteHost 没有独立的配置更新时间字段，因此本机写入用观测时间
 * 标记，避免紧跟在本地保存之后到达的旧云快照覆盖当前页面状态。
 */
export function shouldKeepLocalHostConfig(localObservedAt: number, previousSnapshotAt: number): boolean {
  return localObservedAt > previousSnapshotAt;
}

export function shouldKeepDeletedHost(deletedAt: number, previousSnapshotAt: number): boolean {
  return deletedAt > previousSnapshotAt;
}
