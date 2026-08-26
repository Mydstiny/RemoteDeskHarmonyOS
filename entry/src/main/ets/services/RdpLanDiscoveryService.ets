/**
 * Bounded RDP LAN discovery for the port currently entered in the add form.
 * A TCP hit is admitted only after the existing FreeRDP certificate preflight
 * recognizes the endpoint; a certificate fingerprint is the stable identity
 * required for dynamic-address tracking.
 */
import { connection, socket } from '@kit.NetworkKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { safeError } from '../utils/SafeLogger';

const TAG: string = 'RdpLanDiscovery';
const CONNECT_TIMEOUT_MS: number = 320;
const MAX_CANDIDATES: number = 254;
const MAX_CONCURRENCY: number = 24;

export interface RdpLanIdentityProbeResult {
  recognized: boolean;
  fingerprintSha256: string;
  commonName: string;
}

export interface DiscoveredRdpHost {
  stableId: string;
  deviceName: string;
  host: string;
  port: number;
  fingerprintSha256: string;
  dynamicCapable: boolean;
}

/**
 * A certificate identity may drive DHCP refresh only when it maps to exactly
 * one address in the completed scan. Cloned certificates and multi-address
 * endpoints remain available as static choices but cannot update an address
 * non-deterministically.
 */
export function resolveRdpLanIdentityAmbiguity(
  hosts: DiscoveredRdpHost[]
): DiscoveredRdpHost[] {
  const fingerprintHosts: Map<string, Set<string>> = new Map<string, Set<string>>();
  for (let i = 0; i < hosts.length; i++) {
    const fingerprint: string = hosts[i].fingerprintSha256.trim().toLowerCase();
    if (fingerprint === '') { continue; }
    let addresses: Set<string> | undefined = fingerprintHosts.get(fingerprint);
    if (addresses === undefined) {
      addresses = new Set<string>();
      fingerprintHosts.set(fingerprint, addresses);
    }
    addresses.add(hosts[i].host.trim() + ':' + hosts[i].port.toString());
  }
  const result: DiscoveredRdpHost[] = [];
  for (let i = 0; i < hosts.length; i++) {
    const source: DiscoveredRdpHost = hosts[i];
    const fingerprint: string = source.fingerprintSha256.trim().toLowerCase();
    const addresses: Set<string> | undefined = fingerprintHosts.get(fingerprint);
    const unique: boolean = fingerprint !== '' && addresses !== undefined && addresses.size === 1;
    result.push({
      stableId: unique ? fingerprint : source.host.trim() + ':' + source.port.toString(),
      deviceName: source.deviceName,
      host: source.host,
      port: source.port,
      fingerprintSha256: fingerprint,
      dynamicCapable: unique
    });
  }
  return result;
}

export type RdpLanIdentityProbe =
  (host: string, port: number) => Promise<RdpLanIdentityProbeResult>;

export type RdpLanScanStatus = 'idle' | 'scanning' | 'completed' | 'invalid_port' |
  'no_private_network' | 'network_error' | 'no_open_port' | 'preflight_rejected' | 'cancelled';

/** Admit only a completed TLS probe or a valid Standard RDP Security response. */
export function rdpLanProbeRecognized(preflightStatus: string, errorCode: number): boolean {
  return preflightStatus === 'completed' ||
    (preflightStatus === 'inconclusive' && errorCode === -18);
}

function parseIpv4(address: string): number[] | null {
  const parts: string[] = address.trim().split('.');
  if (parts.length !== 4) { return null; }
  const result: number[] = [];
  for (let i = 0; i < parts.length; i++) {
    if (!/^\d{1,3}$/.test(parts[i])) { return null; }
    const value: number = Number(parts[i]);
    if (!Number.isInteger(value) || value < 0 || value > 255) { return null; }
    result.push(value);
  }
  return result;
}

function ipv4ToNumber(parts: number[]): number {
  return (((parts[0] * 256 + parts[1]) * 256 + parts[2]) * 256 + parts[3]);
}

function isPrivateLanIpv4(parts: number[]): boolean {
  return parts[0] === 10 ||
    (parts[0] === 172 && parts[1] >= 16 && parts[1] <= 31) ||
    (parts[0] === 192 && parts[1] === 168) ||
    (parts[0] === 169 && parts[1] === 254);
}

function numberToIpv4(value: number): string {
  const a: number = Math.floor(value / 16777216) % 256;
  const b: number = Math.floor(value / 65536) % 256;
  const c: number = Math.floor(value / 256) % 256;
  const d: number = value % 256;
  return a.toString() + '.' + b.toString() + '.' + c.toString() + '.' + d.toString();
}

/** Pure bounded subnet enumeration used by tests and the runtime scanner. */
export function rdpLanCandidateAddresses(localAddress: string, prefixLength: number): string[] {
  const parts: number[] | null = parseIpv4(localAddress);
  if (parts === null || !isPrivateLanIpv4(parts) ||
    prefixLength < 0 || prefixLength > 32) { return []; }
  const local: number = ipv4ToNumber(parts);
  // Never expand a large enterprise/VPN prefix. At most inspect the local /24.
  const effectivePrefix: number = Math.max(24, prefixLength);
  const hostBits: number = 32 - effectivePrefix;
  const blockSize: number = Math.pow(2, hostBits);
  const network: number = Math.floor(local / blockSize) * blockSize;
  const broadcast: number = network + blockSize - 1;
  const result: string[] = [];
  for (let current = network + 1;
    current < broadcast && result.length < MAX_CANDIDATES; current++) {
    if (current !== local) { result.push(numberToIpv4(current)); }
  }
  return result;
}

export class RdpLanDiscoveryService {
  private generation: number = 0;
  private activeSockets: socket.TCPSocket[] = [];
  private lastScanStatus: RdpLanScanStatus = 'idle';

  stopScan(): void {
    if (this.lastScanStatus === 'scanning') { this.lastScanStatus = 'cancelled'; }
    this.generation++;
    const sockets: socket.TCPSocket[] = this.activeSockets.slice();
    this.activeSockets = [];
    for (let i = 0; i < sockets.length; i++) {
      try { sockets[i].close(); } catch (_err) {}
    }
  }

  async startScan(port: number, probeIdentity: RdpLanIdentityProbe,
    onHost: (host: DiscoveredRdpHost) => void = (_host: DiscoveredRdpHost): void => {}):
    Promise<DiscoveredRdpHost[]> {
    if (!Number.isInteger(port) || port <= 0 || port > 65535) {
      this.lastScanStatus = 'invalid_port';
      return [];
    }
    this.stopScan();
    this.lastScanStatus = 'scanning';
    const generation: number = this.generation;
    const addresses: string[] = await this.defaultNetworkCandidates();
    if (generation !== this.generation) {
      this.lastScanStatus = 'cancelled';
      return [];
    }
    if (addresses.length === 0) {
      if (this.lastScanStatus === 'scanning') { this.lastScanStatus = 'no_private_network'; }
      return [];
    }
    const results: DiscoveredRdpHost[] = [];
    let openPortCount: number = 0;
    let nextIndex: number = 0;
    const worker = async (): Promise<void> => {
      while (generation === this.generation && nextIndex < addresses.length) {
        const index: number = nextIndex++;
        const address: string = addresses[index];
        if (!(await this.portIsOpen(address, port, generation))) { continue; }
        openPortCount++;
        if (generation !== this.generation) { return; }
        try {
          const identity: RdpLanIdentityProbeResult = await probeIdentity(address, port);
          if (generation !== this.generation || !identity.recognized) { continue; }
          const fingerprint: string = identity.fingerprintSha256.trim().toLowerCase();
          const stableId: string = fingerprint !== '' ? fingerprint : address + ':' + port.toString();
          const found: DiscoveredRdpHost = {
            stableId: stableId,
            deviceName: identity.commonName.trim() !== '' ? identity.commonName.trim() : address,
            host: address,
            port: port,
            fingerprintSha256: fingerprint,
            dynamicCapable: fingerprint !== ''
          };
          results.push(found);
        } catch (err) {
          hilog.warn(0x0001, TAG, 'identity probe failed: ' + safeError(err));
        }
      }
    };
    const workers: Promise<void>[] = [];
    const count: number = Math.min(MAX_CONCURRENCY, addresses.length);
    for (let i = 0; i < count; i++) { workers.push(worker()); }
    await Promise.all(workers);
    if (generation !== this.generation) {
      this.lastScanStatus = 'cancelled';
      return [];
    }
    const resolved: DiscoveredRdpHost[] = resolveRdpLanIdentityAmbiguity(results);
    for (let i = 0; i < resolved.length; i++) { onHost(resolved[i]); }
    this.lastScanStatus = resolved.length > 0 ? 'completed' :
      (openPortCount > 0 ? 'preflight_rejected' : 'no_open_port');
    return resolved;
  }

  getLastScanStatus(): RdpLanScanStatus {
    return this.lastScanStatus;
  }

  private async defaultNetworkCandidates(): Promise<string[]> {
    try {
      const net: connection.NetHandle = await connection.getDefaultNet();
      const properties: connection.ConnectionProperties =
        await connection.getConnectionProperties(net);
      for (let i = 0; i < properties.linkAddresses.length; i++) {
        const link: connection.LinkAddress = properties.linkAddresses[i];
        const address: string = link.address.address;
        if (parseIpv4(address) !== null && !address.startsWith('127.')) {
          const candidates: string[] = rdpLanCandidateAddresses(address, link.prefixLength);
          if (candidates.length > 0) { return candidates; }
        }
      }
    } catch (err) {
      this.lastScanStatus = 'network_error';
      hilog.warn(0x0001, TAG, 'network properties unavailable: ' + safeError(err));
    }
    return [];
  }

  private async portIsOpen(host: string, port: number, generation: number): Promise<boolean> {
    let tcp: socket.TCPSocket | null = null;
    try {
      tcp = socket.constructTCPSocketInstance();
      this.activeSockets.push(tcp);
      await tcp.connect({
        address: { address: host, port: port, family: 1 }, timeout: CONNECT_TIMEOUT_MS
      });
      return generation === this.generation;
    } catch (_err) {
      return false;
    } finally {
      if (tcp !== null) {
        const index: number = this.activeSockets.indexOf(tcp);
        if (index >= 0) { this.activeSockets.splice(index, 1); }
        try { tcp.close(); } catch (_closeError) {}
      }
    }
  }
}
