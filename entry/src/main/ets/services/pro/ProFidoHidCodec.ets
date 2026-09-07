// The USB probe deliberately supports a single unnumbered 64-byte CTAPHID
// collection. Other HID layouts remain unsupported instead of guessing routes.
export const PRO_FIDO_PACKET_SIZE: number = 64;
export const PRO_FIDO_BROADCAST: number = 0xffffffff;
export const PRO_FIDO_INIT: number = 0x06;

export function isProFidoReportDescriptor(bytes: Uint8Array): boolean {
  if (bytes.length < 16 || bytes.length > 4096) { return false; }
  let page: number = 0;
  let usage: number = -1;
  let size: number = 0;
  let count: number = 0;
  let depth: number = 0;
  let collections: number = 0;
  let inputs: number = 0;
  let outputs: number = 0;
  for (let offset = 0; offset < bytes.length;) {
    const prefix = bytes[offset++];
    if (prefix === 0xfe) { return false; }
    const width = (prefix & 3) === 3 ? 4 : prefix & 3;
    if (offset + width > bytes.length) { return false; }
    let value: number = 0;
    for (let i = 0; i < width; i++) { value += bytes[offset + i] * Math.pow(256, i); }
    offset += width;
    const type = (prefix >> 2) & 3;
    const tag = prefix >> 4;
    if (type === 1) {
      if (tag === 0) { page = value; }
      else if (tag === 7) { size = value; }
      else if (tag === 9) { count = value; }
      else if (tag === 8 || tag === 10 || tag === 11) { return false; } // report IDs / push / pop
    } else if (type === 2) {
      // Local usages accumulate until the next Main item. Overwriting one
      // would conceal a keyboard or another usage in the same report.
      if (tag !== 0 || width === 0 || usage !== -1) { return false; }
      usage = width === 4 ? value : page * 65536 + value;
    } else if (type === 0) {
      if (tag === 10) {
        if (depth !== 0 || ++collections !== 1 || value !== 1 || usage !== 0xf1d00001) { return false; }
        depth = 1;
      } else if (tag === 12) {
        if (depth !== 1 || width !== 0 || usage !== -1) { return false; }
        depth = 0;
      } else if (tag === 8 || tag === 9) {
        if (depth !== 1 || page !== 0xf1d0 || size !== 8 || count !== PRO_FIDO_PACKET_SIZE ||
          (value & 7) !== 2) { return false; }
        if (tag === 8) { if (usage !== 0xf1d00020 || ++inputs !== 1) { return false; } }
        else { if (usage !== 0xf1d00021 || ++outputs !== 1) { return false; } }
      } else { return false; }
      usage = -1;
    } else { return false; }
  }
  return collections === 1 && depth === 0 && inputs === 1 && outputs === 1 && usage === -1;
}

function readChannel(bytes: Uint8Array): number {
  return bytes[0] * 16777216 + bytes[1] * 65536 + bytes[2] * 256 + bytes[3];
}

export function proFidoPackets(channel: number, command: number, data: Uint8Array): Uint8Array[] {
  if (!Number.isInteger(channel) || channel <= 0 || channel > PRO_FIDO_BROADCAST ||
    !Number.isInteger(command) || command < 1 || command > 0x7f || data.length > 7609) {
    throw new Error('无效的 FIDO 数据包');
  }
  const packets: Uint8Array[] = [];
  let offset: number = 0;
  let sequence: number = -1;
  do {
    const packet = new Uint8Array(PRO_FIDO_PACKET_SIZE);
    packet[0] = Math.floor(channel / 16777216) & 255;
    packet[1] = Math.floor(channel / 65536) & 255;
    packet[2] = Math.floor(channel / 256) & 255;
    packet[3] = channel & 255;
    let header: number = 5;
    if (sequence === -1) {
      packet[4] = command | 0x80;
      packet[5] = data.length >> 8;
      packet[6] = data.length & 255;
      header = 7;
    } else { packet[4] = sequence; }
    const length = Math.min(PRO_FIDO_PACKET_SIZE - header, data.length - offset);
    packet.set(data.subarray(offset, offset + length), header);
    offset += length;
    sequence++;
    packets.push(packet);
  } while (offset < data.length);
  return packets;
}

export class ProFidoHidResponse {
  private channel: number;
  private command: number;
  private data: Uint8Array | null = null;
  private offset: number = 0;
  private sequence: number = 0;
  private complete: boolean = false;
  constructor(channel: number, command: number) { this.channel = channel; this.command = command; }
  // Reports on another allocated channel are not ours. A malformed report on
  // our channel terminates the operation; it cannot be assembled into success.
  accept(packet: Uint8Array): Uint8Array | null {
    if (this.complete || packet.length !== PRO_FIDO_PACKET_SIZE) { throw new Error('FIDO 响应长度无效'); }
    if (readChannel(packet) !== this.channel) { return null; }
    let header: number = 5;
    if ((packet[4] & 0x80) !== 0) {
      if (this.data !== null || (packet[4] & 0x7f) !== this.command) { throw new Error('FIDO 响应命令无效'); }
      const length = packet[5] * 256 + packet[6];
      if (length > 7609) { throw new Error('FIDO 响应过大'); }
      this.data = new Uint8Array(length);
      header = 7;
    } else if (this.data === null || packet[4] !== this.sequence++ || packet[4] > 0x7f) {
      throw new Error('FIDO 响应顺序无效');
    }
    const data = this.data;
    if (data === null) { throw new Error('FIDO 响应未初始化'); }
    const length = Math.min(PRO_FIDO_PACKET_SIZE - header, data.length - this.offset);
    data.set(packet.subarray(header, header + length), this.offset);
    this.offset += length;
    if (this.offset < data.length) { return null; }
    this.complete = true;
    return data;
  }
}

export interface ProFidoInitInfo { channel: number; cbor: boolean; }

export function parseProFidoInit(data: Uint8Array, nonce: Uint8Array): ProFidoInitInfo {
  if (data.length < 17 || nonce.length !== 8) { throw new Error('安全密钥初始化响应不完整'); }
  for (let i = 0; i < 8; i++) {
    if (data[i] !== nonce[i]) { throw new Error('安全密钥初始化响应不匹配'); }
  }
  const channel = readChannel(data.subarray(8, 12));
  if (channel === 0 || channel === PRO_FIDO_BROADCAST || data[12] !== 2) {
    throw new Error('安全密钥返回不支持的通道或版本');
  }
  return { channel, cbor: (data[16] & 0x04) !== 0 };
}
