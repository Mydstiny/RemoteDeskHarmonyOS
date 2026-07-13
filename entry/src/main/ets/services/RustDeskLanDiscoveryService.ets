/**
 * RustDeskLanDiscoveryService — 局域网 RustDesk 设备发现
 *
 * 使用 UDP 广播到 255.255.255.255:21116 发现局域网内的 RustDesk 设备。
 * 手动触发扫描，独立服务，不嵌入 streaming 主链路。
 */
import { socket } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG = 'RustDeskLanDisc';
const RD_DISCOVERY_PORT = 21116;
const SCAN_TIMEOUT_MS = 15000;

/** 发现的局域网设备 */
export interface DiscoveredRustDeskPeer {
  peerId: string;     // RustDesk 远程 ID
  deviceName: string; // 设备名称
  host: string;       // 局域网 IP 地址
  port: number;       // 端口 (通常是 21116)
  version: string;    // RustDesk 版本 (如能解析)
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

          // 发送广播探测包
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
      // RustDesk LAN 发现探测: 发送 "RDCM" magic + version 到广播地址
      const probe: Uint8Array = new Uint8Array(12);
      const encoder: util.TextEncoder = new util.TextEncoder();
      const magic: Uint8Array = encoder.encode('RDCM');
      probe.set(magic.subarray(0, 4), 0); // offset 0-3: magic "RDCM"
      probe[4] = 0x01;       // offset 4: version
      probe[5] = 0x00;       // offset 5: flags (discovery probe)
      // offset 6-11: reserved (0)

      const sendOpts: socket.UDPSendOptions = {
        data: probe.buffer as ArrayBuffer,
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
      hilog.info(0x0001, TAG, 'discovery probe broadcast sent');
    } catch (err) {
      hilog.warn(0x0001, TAG, `sendDiscoveryProbe error: ${JSON.stringify(err)}`);
    }
  }

  /**
   * 解析发现响应
   *
   * RustDesk LAN 发现响应格式 (可变长度):
   *   [0-3]  magic "RDCM"
   *   [4]    version
   *   [5]    message type (0x02 = discovery response)
   *   [6-7]  peer ID length (uint16 LE, 可选)
   *   [8..]  peer ID UTF-8
   *   后面跟 device name (null-terminated) 和 version string
   *
   * 如果无法解析则返回 null (不是 RustDesk 设备或格式不匹配)
   */
  private parseDiscoveryResponse(data: ArrayBuffer, remoteAddr: string): DiscoveredRustDeskPeer | null {
    const bytes: Uint8Array = new Uint8Array(data);
    if (bytes.length < 8) {
      return null;
    }

    // 检查 magic
    const decoder: util.TextDecoder = new util.TextDecoder();
    const magic: string = decoder.decode(bytes.slice(0, 4));
    if (magic !== 'RDCM') {
      return null; // 非 RustDesk 响应
    }

    // version, message type
    const _version: number = bytes[4];
    const _msgType: number = bytes[5];

    // 提取 peer ID (从 offset 6 开始，长度可变)
    let peerId: string = '';
    let offset: number = 6;

    // 尝试解析 peer ID 长度 (2 bytes LE)
    if (bytes.length >= 8) {
      const idLen: number = bytes[6] | (bytes[7] << 8);
      if (idLen > 0 && idLen <= 128 && bytes.length >= 8 + idLen) {
        offset = 8;
        peerId = decoder.decode(bytes.slice(offset, offset + idLen));
        offset += idLen;
      } else {
        // Fallback: 直接读 null-terminated string
        let end: number = 6;
        while (end < bytes.length && bytes[end] !== 0) { end++; }
        if (end > 6) {
          peerId = decoder.decode(bytes.slice(6, end));
          offset = end + 1; // skip null
        }
      }
    }

    // 尝试提取 device name (null-terminated)
    let deviceName: string = '';
    if (offset < bytes.length) {
      let end: number = offset;
      while (end < bytes.length && bytes[end] !== 0) { end++; }
      if (end > offset) {
        deviceName = decoder.decode(bytes.slice(offset, end));
        offset = end + 1;
      }
    }

    // 尝试提取 version string (null-terminated)
    let version: string = '';
    if (offset < bytes.length) {
      let end: number = offset;
      while (end < bytes.length && bytes[end] !== 0) { end++; }
      if (end > offset) {
        version = decoder.decode(bytes.slice(offset, end));
      }
    }

    if (peerId.length === 0) {
      return null;
    }

    return {
      peerId: peerId,
      deviceName: deviceName.length > 0 ? deviceName : peerId,
      host: remoteAddr,
      port: RD_DISCOVERY_PORT,
      version: version
    };
  }
}
