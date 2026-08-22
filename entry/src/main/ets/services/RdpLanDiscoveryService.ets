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

export type RdpLanIdentityProbe =
  (host: string, port: number) => Promise<RdpLanIdentityProbeResult>;

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

  stopScan(): void {
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
    if (!Number.isInteger(port) || port <= 0 || port > 65535) { return []; }
    this.stopScan();
    const generation: number = this.generation;
    const addresses: string[] = await this.defaultNetworkCandidates();
    if (generation !== this.generation || addresses.length === 0) { return []; }
    const results: DiscoveredRdpHost[] = [];
    let nextIndex: number = 0;
    const worker = async (): Promise<void> => {
      while (generation === this.generation && nextIndex < addresses.length) {
        const index: number = nextIndex++;
        const address: string = addresses[index];
        if (!(await this.portIsOpen(address, port, generation))) { continue; }
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
          onHost(found);
        } catch (err) {
          hilog.warn(0x0001, TAG, 'identity probe failed: ' + safeError(err));
        }
      }
    };
    const workers: Promise<void>[] = [];
    const count: number = Math.min(MAX_CONCURRENCY, addresses.length);
    for (let i = 0; i < count; i++) { workers.push(worker()); }
    await Promise.all(workers);
    return generation === this.generation ? results : [];
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
