/**
 * RdpCertificateProbeLifecyclePolicy.ets — 证书异步探测结果生命周期策略。
 *
 * generation 用于丢弃取消、重试或切换主机后返回的旧 native 结果。
 */

export function nextRdpCertificateProbeGeneration(current: number): number {
  return current >= Number.MAX_SAFE_INTEGER ? 1 : current + 1;
}
export function shouldApplyRdpCertificateProbeResult(activeGeneration: number,
  resultGeneration: number, activeHostId: string, resultHostId: string): boolean {
  return activeGeneration === resultGeneration && activeHostId.length > 0 && activeHostId === resultHostId;
}
