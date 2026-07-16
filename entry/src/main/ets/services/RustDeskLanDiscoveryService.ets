/**
 * RustDeskLanDiscoveryService — 局域网 RustDesk 设备发现
 *
 * 使用 RustDesk 官方 PeerDiscovery protobuf，通过 UDP 广播到 255.255.255.255:21119
 * 发现局域网内的 RustDesk 设备。发现响应的直连 TCP 端口为 21118。
 * 手动触发扫描，独立服务，不嵌入 streaming 主链路。
 */
import { socket } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG = 'RustDeskLanDisc';
const RD_DISCOVERY_PORT: number = 21119;
const RD_DIRECT_PORT: number = 21118;
const SCAN_TIMEOUT_MS = 15000;

/** 发现的局域网设备 */
export interface DiscoveredRustDeskPeer {
  peerId: string;     // RustDesk 远程 ID
  deviceName: string; // 设备名称
  host: string;       // 局域网 IP 地址
  port: number;       // 直连端口 (RustDesk peer TCP, 默认 21118)
  version: string;    // RustDesk 版本 (如能解析)
}

export interface RustDeskLanPeerDiscovery {
  cmd: string;
  mac: string;
  id: string;
  username: string;
  hostname: string;
  platform: string;
  misc: string;
}

interface ProtoVarintResult {
  value: number;
  next: number;
}

function appendProtoVarint(target: number[], value: number): void {
  let current: number = Math.max(0, Math.floor(value));
  do {
    let byte: number = current % 128;
    current = Math.floor(current / 128);
    if (current > 0) { byte += 128; }
    target.push(byte);
  } while (current > 0);
}

function appendProtoString(target: number[], fieldNumber: number, value: string): void {
  if (value.length === 0) { return; }
  const bytes: Uint8Array = new util.TextEncoder().encode(value);
  appendProtoVarint(target, (fieldNumber * 8) + 2);
  appendProtoVarint(target, bytes.length);
  for (let i = 0; i < bytes.length; i++) { target.push(bytes[i]); }
}

function encodePeerDiscovery(peer: RustDeskLanPeerDiscovery): ArrayBuffer {
  const inner: number[] = [];
  appendProtoString(inner, 1, peer.cmd);
  appendProtoString(inner, 2, peer.mac);
  appendProtoString(inner, 3, peer.id);
  appendProtoString(inner, 4, peer.username);
  appendProtoString(inner, 5, peer.hostname);
  appendProtoString(inner, 6, peer.platform);
  appendProtoString(inner, 7, peer.misc);

  const outer: number[] = [];
  // RendezvousMessage.peer_discovery = 22, wire type 2.
  appendProtoVarint(outer, (22 * 8) + 2);
  appendProtoVarint(outer, inner.length);
  for (let i = 0; i < inner.length; i++) { outer.push(inner[i]); }
  return new Uint8Array(outer).buffer;
}

export function encodeRustDeskLanPeerDiscovery(peer: RustDeskLanPeerDiscovery): ArrayBuffer {
  return encodePeerDiscovery(peer);
}

export function encodeRustDeskLanPing(): ArrayBuffer {
  return encodePeerDiscovery({
    cmd: 'ping',
    mac: '',
    id: '',
    username: '',
    hostname: '',
    platform: '',
    misc: ''
  });
}

function readProtoVarint(bytes: Uint8Array, start: number): ProtoVarintResult | null {
  let value: number = 0;
  let multiplier: number = 1;
  let index: number = start;
  for (let i = 0; i < 10; i++) {
    if (index >= bytes.length) { return null; }
    const byte: number = bytes[index++];
    value += (byte % 128) * multiplier;
    if (byte < 128) { return { value: value, next: index }; }
    multiplier *= 128;
  }
  return null;
}

function skipProtoField(bytes: Uint8Array, start: number, wireType: number): number | null {
  if (wireType === 0) {
    const varint: ProtoVarintResult | null = readProtoVarint(bytes, start);
    return varint === null ? null : varint.next;
  }
  if (wireType === 1) { return start + 8 <= bytes.length ? start + 8 : null; }
  if (wireType === 2) {
    const length: ProtoVarintResult | null = readProtoVarint(bytes, start);
    if (length === null) { return null; }
    const end: number = length.next + length.value;
    return end <= bytes.length ? end : null;
  }
  if (wireType === 5) { return start + 4 <= bytes.length ? start + 4 : null; }
  return null;
}

function parsePeerDiscoveryMessage(bytes: Uint8Array): RustDeskLanPeerDiscovery | null {
  const result: RustDeskLanPeerDiscovery = {
    cmd: '', mac: '', id: '', username: '', hostname: '', platform: '', misc: ''
  };
  let seenField: boolean = false;
  let index: number = 0;
  const decoder: util.TextDecoder = new util.TextDecoder();
  while (index < bytes.length) {
    const tag: ProtoVarintResult | null = readProtoVarint(bytes, index);
    if (tag === null) { return null; }
    index = tag.next;
    const fieldNumber: number = Math.floor(tag.value / 8);
    const wireType: number = tag.value % 8;
    if (wireType !== 2) {
      const next: number | null = skipProtoField(bytes, index, wireType);
      if (next === null) { return null; }
      index = next;
      continue;
    }
    const length: ProtoVarintResult | null = readProtoVarint(bytes, index);
    if (length === null) { return null; }
    const start: number = length.next;
    const end: number = start + length.value;
    if (end > bytes.length) { return null; }
    const text: string = decoder.decode(bytes.slice(start, end));
    if (fieldNumber === 1) { result.cmd = text; seenField = true; }
    else if (fieldNumber === 2) { result.mac = text; seenField = true; }
    else if (fieldNumber === 3) { result.id = text; seenField = true; }
    else if (fieldNumber === 4) { result.username = text; seenField = true; }
    else if (fieldNumber === 5) { result.hostname = text; seenField = true; }
    else if (fieldNumber === 6) { result.platform = text; seenField = true; }
    else if (fieldNumber === 7) { result.misc = text; seenField = true; }
    index = end;
  }
  return seenField ? result : null;
}

export function parseRustDeskLanPeerDiscovery(data: ArrayBuffer): RustDeskLanPeerDiscovery | null {
  const bytes: Uint8Array = new Uint8Array(data);
  let index: number = 0;
  while (index < bytes.length) {
    const tag: ProtoVarintResult | null = readProtoVarint(bytes, index);
    if (tag === null) { return null; }
    index = tag.next;
    const fieldNumber: number = Math.floor(tag.value / 8);
    const wireType: number = tag.value % 8;
    if (wireType === 2) {
      const length: ProtoVarintResult | null = readProtoVarint(bytes, index);
      if (length === null) { return null; }
      const start: number = length.next;
      const end: number = start + length.value;
      if (end > bytes.length) { return null; }
      if (fieldNumber === 22) {
        return parsePeerDiscoveryMessage(bytes.slice(start, end));
      }
      index = end;
      continue;
    }
    const next: number | null = skipProtoField(bytes, index, wireType);
    if (next === null) { return null; }
    index = next;
  }
  return null;
}

export class RustDeskLanDiscoveryService {
  private scanning: boolean = false;
  private udp: socket.UDPSocket | null = null;
  private scanTimer: number = -1;

  /**
   * 启动局域网扫描
   * @param timeoutMs 超时时间 (默认 15s)
   * @returns 发现的设备列表
   */
  startScan(timeoutMs: number = SCAN_TIMEOUT_MS): Promise<DiscoveredRustDeskPeer[]> {
    return new Promise<DiscoveredRustDeskPeer[]>((resolve) => {
      if (this.scanning) {
        resolve([]);
        return;
      }
      this.scanning = true;
      const discovered: DiscoveredRustDeskPeer[] = [];
      const seenPeers: Set<string> = new Set<string>();

      try {
        this.udp = socket.constructUDPSocketInstance();

        // 绑定本地端口 0 (系统分配)
        const bindAddr: socket.NetAddress = {
          address: '0.0.0.0',
          port: 0,
          family: 1
        };

        this.udp.bind(bindAddr, (err: BusinessError) => {
          if (err) {
            hilog.warn(0x0001, TAG, `bind failed: ${err.code} ${err.message}`);
            this.stopScanInternal();
            resolve([]);
            return;
          }

          hilog.info(0x0001, TAG, 'UDP socket bound for LAN scan');

          // 监听响应
          this.udp!.on('message', (data: socket.SocketMessageInfo) => {
            if (!this.scanning) {
              return;
            }
            try {
              const peer: DiscoveredRustDeskPeer | null = this.parseDiscoveryResponse(
                data.message, data.remoteInfo.address);
              if (peer && !seenPeers.has(peer.peerId)) {
                seenPeers.add(peer.peerId);
                discovered.push(peer);
                hilog.info(0x0001, TAG,
                  `discovered: ${peer.peerId} @ ${peer.host}:${peer.port} [${peer.deviceName}]`);
              }
            } catch (e) {
              // 解析失败 — 忽略非 RustDesk 响应
            }
          });

          const startProbe: () => void = (): void => {
            // 发送广播探测包；RustDesk 的 LAN listener 监听 21119 并返回 protobuf pong。
            this.sendDiscoveryProbe();
            // 重发一次 (UDP 可能丢包)
            setTimeout(() => {
              if (this.scanning) { this.sendDiscoveryProbe(); }
            }, 500);

            // 超时停止
            this.scanTimer = setTimeout(() => {
              this.stopScanInternal();
              hilog.info(0x0001, TAG, `scan complete: ${discovered.length} device(s) found`);
              resolve(discovered);
            }, timeoutMs);
          };
          // HarmonyOS 默认禁止 UDP 广播，必须在 bind 成功后显式打开。
          this.udp!.setExtraOptions({ broadcast: true }, (optionErr: BusinessError): void => {
            if (!this.scanning) { return; }
            if (optionErr) {
              hilog.warn(0x0001, TAG, `enable UDP broadcast failed: ${optionErr.code} ${optionErr.message}`);
            }
            startProbe();
          });
        });

      } catch (err) {
        hilog.warn(0x0001, TAG, `startScan error: ${JSON.stringify(err)}`);
        this.stopScanInternal();
        resolve([]);
      }
    });
  }

  /** 停止扫描 */
  stopScan(): void {
    this.stopScanInternal();
  }

  /** 是否正在扫描 */
  isScanning(): boolean {
    return this.scanning;
  }

  // ============================================================
  // 内部实现
  // ============================================================

  private stopScanInternal(): void {
    this.scanning = false;
    if (this.scanTimer >= 0) {
      clearTimeout(this.scanTimer);
      this.scanTimer = -1;
    }
    if (this.udp !== null) {
      try {
        this.udp.off('message');
        this.udp.close();
      } catch (_e) {
        // ignore
      }
      this.udp = null;
    }
  }

  /** 发送 UDP 广播探测包 */
  private sendDiscoveryProbe(): void {
    if (!this.udp || !this.scanning) {
      return;
    }
    try {
      const sendOpts: socket.UDPSendOptions = {
        data: encodeRustDeskLanPing(),
        address: {
          address: '255.255.255.255',
          port: RD_DISCOVERY_PORT,
          family: 1
        }
      };

      this.udp.send(sendOpts, (err: BusinessError) => {
        if (err) {
          hilog.warn(0x0001, TAG, `broadcast send failed: ${err.code}`);
        }
      });
      hilog.info(0x0001, TAG, 'RustDesk PeerDiscovery ping broadcast sent');
    } catch (err) {
      hilog.warn(0x0001, TAG, `sendDiscoveryProbe error: ${JSON.stringify(err)}`);
    }
  }

  /** 解析 RustDesk 官方 RendezvousMessage.peer_discovery pong。 */
  private parseDiscoveryResponse(data: ArrayBuffer, remoteAddr: string): DiscoveredRustDeskPeer | null {
    const peer: RustDeskLanPeerDiscovery | null = parseRustDeskLanPeerDiscovery(data);
    if (peer === null || peer.cmd !== 'pong' || peer.id.trim() === '') { return null; }
    return {
      peerId: peer.id,
      deviceName: peer.hostname.length > 0 ? peer.hostname : peer.id,
      host: remoteAddr,
      port: RD_DIRECT_PORT,
      version: peer.platform
    };
  }
}
