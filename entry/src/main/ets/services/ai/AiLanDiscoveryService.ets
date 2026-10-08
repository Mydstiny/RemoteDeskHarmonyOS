/** Bounded TCP discovery for a selected AI Agent port on the current LAN. */
import { connection, socket } from '@kit.NetworkKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { AiBackend } from './AiModels';

const TAG: string = 'AiLanDiscovery';
const CONNECT_TIMEOUT_MS: number = 320;
const MAX_CANDIDATES: number = 254;
const MAX_CONCURRENCY: number = 24;

export interface DiscoveredAiAgent {
  stableId: string;
  host: string;
  port: number;
  backend: AiBackend;
  displayName: string;
}

export type AiLanScanStatus = 'idle' | 'scanning' | 'completed' | 'no_private_network' |
  'no_open_port' | 'network_error' | 'cancelled';

function parseIpv4(value: string): number[] | null {
  const parts: string[] = value.trim().split('.');
  if (parts.length !== 4) { return null; }
  const result: number[] = [];
  for (let i = 0; i < parts.length; i++) {
    if (!/^\d{1,3}$/.test(parts[i])) { return null; }
    const item: number = Number(parts[i]);
    if (!Number.isInteger(item) || item < 0 || item > 255) { return null; }
    result.push(item);
  }
  return result;
}

function ipv4Number(parts: number[]): number {
  return (((parts[0] * 256 + parts[1]) * 256 + parts[2]) * 256 + parts[3]);
}

function privateLan(parts: number[]): boolean {
  return parts[0] === 10 || (parts[0] === 172 && parts[1] >= 16 && parts[1] <= 31) ||
    (parts[0] === 192 && parts[1] === 168) || (parts[0] === 169 && parts[1] === 254);
}

function ipv4Text(value: number): string {
  return (Math.floor(value / 16777216) % 256).toString() + '.' +
    (Math.floor(value / 65536) % 256).toString() + '.' +
    (Math.floor(value / 256) % 256).toString() + '.' + (value % 256).toString();
}

export function aiLanCandidateAddresses(address: string, prefixLength: number): string[] {
  const parts: number[] | null = parseIpv4(address);
  if (parts === null || !privateLan(parts) || prefixLength < 0 || prefixLength > 32) { return []; }
  const prefix: number = Math.max(24, prefixLength);
  const blockSize: number = Math.pow(2, 32 - prefix);
  const local: number = ipv4Number(parts);
  const network: number = Math.floor(local / blockSize) * blockSize;
  const broadcast: number = network + blockSize - 1;
  const result: string[] = [];
  for (let current: number = network + 1; current < broadcast && result.length < MAX_CANDIDATES; current++) {
    if (current !== local) { result.push(ipv4Text(current)); }
  }
  return result;
}

export class AiLanDiscoveryService {
  private generation: number = 0;
  private sockets: socket.TCPSocket[] = [];
  private status: AiLanScanStatus = 'idle';

  stopScan(): void {
    if (this.status === 'scanning') { this.status = 'cancelled'; }
    this.generation++;
    const active: socket.TCPSocket[] = this.sockets.slice();
    this.sockets = [];
    for (let i = 0; i < active.length; i++) { try { active[i].close(); } catch (_error) {} }
  }

  async startScan(port: number, backend: AiBackend,
    onAgent: (agent: DiscoveredAiAgent) => void = (_agent: DiscoveredAiAgent): void => {}):
    Promise<DiscoveredAiAgent[]> {
    if (!Number.isInteger(port) || port < 1 || port > 65535) { return []; }
    this.stopScan(); this.status = 'scanning';
    const generation: number = this.generation;
    const addresses: string[] = await this.defaultCandidates();
    if (generation !== this.generation) { this.status = 'cancelled'; return []; }
    if (addresses.length === 0) {
      const currentStatus: AiLanScanStatus = this.status as AiLanScanStatus;
      if (currentStatus !== 'network_error') { this.status = 'no_private_network'; }
      return [];
    }
    const results: DiscoveredAiAgent[] = []; let next: number = 0; let openCount: number = 0;
    const worker = async (): Promise<void> => {
      while (generation === this.generation && next < addresses.length) {
        const host: string = addresses[next++];
        if (!(await this.open(host, port, generation))) { continue; }
        openCount++;
        const item: DiscoveredAiAgent = { stableId: host + ':' + port.toString(), host, port, backend,
          displayName: host };
        results.push(item);
        try { onAgent(item); } catch (error) {
          hilog.warn(0x0001, TAG, 'agent callback failed: ' + JSON.stringify(error));
        }
      }
    };
    const workers: Promise<void>[] = [];
    for (let i = 0; i < Math.min(MAX_CONCURRENCY, addresses.length); i++) { workers.push(worker()); }
    await Promise.all(workers);
    if (generation !== this.generation) { this.status = 'cancelled'; return []; }
    this.status = results.length > 0 ? 'completed' : (openCount > 0 ? 'completed' : 'no_open_port');
    return results;
  }

  getStatus(): AiLanScanStatus { return this.status; }

  private async defaultCandidates(): Promise<string[]> {
    try {
      const net: connection.NetHandle = await connection.getDefaultNet();
      const properties: connection.ConnectionProperties = await connection.getConnectionProperties(net);
      for (let i = 0; i < properties.linkAddresses.length; i++) {
        const link: connection.LinkAddress = properties.linkAddresses[i];
        const host: string = link.address.address;
        const candidates: string[] = aiLanCandidateAddresses(host, link.prefixLength);
        if (candidates.length > 0) { return candidates; }
      }
    } catch (error) {
      this.status = 'network_error';
      hilog.warn(0x0001, TAG, 'network properties unavailable: ' + JSON.stringify(error));
    }
    return [];
  }

  private async open(host: string, port: number, generation: number): Promise<boolean> {
    let tcp: socket.TCPSocket | null = null;
    try {
      tcp = socket.constructTCPSocketInstance(); this.sockets.push(tcp);
      await tcp.connect({ address: { address: host, port, family: 1 }, timeout: CONNECT_TIMEOUT_MS });
      return generation === this.generation;
    } catch (_error) { return false; }
    finally {
      if (tcp !== null) {
        const index: number = this.sockets.indexOf(tcp);
        if (index >= 0) { this.sockets.splice(index, 1); }
        try { tcp.close(); } catch (_closeError) {}
      }
    }
  }
}
