/**
 * Shared SSH transport normalization for the legacy editor and the modern
 * add flow. Keeping this mapping pure prevents a UI label from changing the
 * wire protocol when a host is saved.
 */

export type SshFrpControlPlaneTransport = 'frp_visitor' | 'frp_stcp' | 'frp_sudp' | 'frp_xtcp';
export type SshEndpointTransport = 'http_connect' | 'socks5' | 'frp_tcp' |
  SshFrpControlPlaneTransport | 'ssh_jump';

export function normalizeSshEndpointTransport(value: string): SshEndpointTransport {
  if (value === 'socks5') { return 'socks5'; }
  if (value === 'frp_tcp') { return 'frp_tcp'; }
  if (value === 'frp_visitor') { return 'frp_visitor'; }
  if (value === 'frp_stcp') { return 'frp_stcp'; }
  if (value === 'frp_sudp') { return 'frp_sudp'; }
  if (value === 'frp_xtcp') { return 'frp_xtcp'; }
  if (value === 'ssh_jump') { return 'ssh_jump'; }
  return 'http_connect';
}

export function isSshFrpControlPlaneTransport(value: string): boolean {
  return value === 'frp_visitor' || value === 'frp_stcp' || value === 'frp_sudp' || value === 'frp_xtcp';
}

export function sshTransportHasNativeImplementation(value: string): boolean {
  return value === 'http_connect' || value === 'socks5' || value === 'frp_tcp' || value === 'ssh_jump';
}

export function sshEditorTransportForStoredHost(proxyHost: string, storedType: string): string {
  if (proxyHost.trim() === '') { return 'http_connect'; }
  if (storedType === 'direct') { return 'legacy_gateway'; }
  return normalizeSshEndpointTransport(storedType);
}

/**
 * A page-owned session must keep polling native state even while ArkUI still
 * describes it as disconnected/connecting. Native transport recovery can
 * finish without changing the session id, and the state poll is what restores
 * the page/tab binding before a latency request is allowed to run.
 */
export function shouldPollSshNativeConnectionState(sessionId: number,
  latencyProbeRunning: boolean): boolean {
  return sessionId > 0 && !latencyProbeRunning;
}
