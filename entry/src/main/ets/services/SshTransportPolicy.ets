/**
 * Shared SSH transport normalization for the legacy editor and the modern
 * add flow. Keeping this mapping pure prevents a UI label from changing the
 * wire protocol when a host is saved.
 */

export type SshEndpointTransport = 'http_connect' | 'socks5' | 'frp_tcp';

export function normalizeSshEndpointTransport(value: string): SshEndpointTransport {
  if (value === 'socks5') { return 'socks5'; }
  if (value === 'frp_tcp') { return 'frp_tcp'; }
  return 'http_connect';
}

export function sshEditorTransportForStoredHost(proxyHost: string, storedType: string): string {
  if (proxyHost.trim() === '') { return 'http_connect'; }
  if (storedType === 'direct') { return 'legacy_gateway'; }
  return normalizeSshEndpointTransport(storedType);
}
