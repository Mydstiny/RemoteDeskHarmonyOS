import { util } from '@kit.ArkTS';

/**
 * A zip archive written in memory with every entry stored (no compression). Word and Excel open stored entries like
 * any other, so the AI's documents need neither zlib nor a temporary directory layout to come out as .docx/.xlsx.
 */

const CRC_TABLE: number[] = [];

function crcTable(): number[] {
  if (CRC_TABLE.length === 0) {
    for (let n: number = 0; n < 256; n++) {
      let c: number = n;
      for (let k: number = 0; k < 8; k++) { c = (c & 1) !== 0 ? (0xEDB88320 ^ (c >>> 1)) : (c >>> 1); }
      CRC_TABLE.push(c >>> 0);
    }
  }
  return CRC_TABLE;
}

export function aiCrc32(bytes: Uint8Array): number {
  const table: number[] = crcTable();
  let crc: number = 0xFFFFFFFF;
  for (let i: number = 0; i < bytes.length; i++) { crc = table[(crc ^ bytes[i]) & 0xFF] ^ (crc >>> 8); }
  return (crc ^ 0xFFFFFFFF) >>> 0;
}

export class AiZipEntry {
  name: string;
  data: Uint8Array;

  constructor(name: string, data: Uint8Array) {
    this.name = name;
    this.data = data;
  }
}

export function aiZipTextEntry(name: string, text: string): AiZipEntry {
  return new AiZipEntry(name, new util.TextEncoder().encodeInto(text));
}

/** The entries as one stored zip (UTF-8 names, the current local time on every entry). */
export function aiZipStore(entries: AiZipEntry[]): Uint8Array {
  const encoder: util.TextEncoder = new util.TextEncoder();
  const names: Uint8Array[] = entries.map((entry: AiZipEntry): Uint8Array => encoder.encodeInto(entry.name));
  const crcs: number[] = entries.map((entry: AiZipEntry): number => aiCrc32(entry.data));
  let localSize: number = 0;
  let centralSize: number = 0;
  entries.forEach((entry: AiZipEntry, i: number): void => {
    localSize += 30 + names[i].length + entry.data.length;
    centralSize += 46 + names[i].length;
  });
  const out: Uint8Array = new Uint8Array(localSize + centralSize + 22);
  const view: DataView = new DataView(out.buffer);
  const now: Date = new Date();
  const dosTime: number = (now.getHours() << 11) | (now.getMinutes() << 5) | Math.floor(now.getSeconds() / 2);
  const dosDate: number = ((Math.max(1980, now.getFullYear()) - 1980) << 9) | ((now.getMonth() + 1) << 5) | now.getDate();
  const offsets: number[] = [];
  let at: number = 0;
  entries.forEach((entry: AiZipEntry, i: number): void => {
    offsets.push(at);
    view.setUint32(at, 0x04034b50, true);
    view.setUint16(at + 4, 20, true);
    view.setUint16(at + 6, 0x0800, true);
    view.setUint16(at + 8, 0, true);
    view.setUint16(at + 10, dosTime, true);
    view.setUint16(at + 12, dosDate, true);
    view.setUint32(at + 14, crcs[i], true);
    view.setUint32(at + 18, entry.data.length, true);
    view.setUint32(at + 22, entry.data.length, true);
    view.setUint16(at + 26, names[i].length, true);
    view.setUint16(at + 28, 0, true);
    out.set(names[i], at + 30);
    out.set(entry.data, at + 30 + names[i].length);
    at += 30 + names[i].length + entry.data.length;
  });
  const centralStart: number = at;
  entries.forEach((entry: AiZipEntry, i: number): void => {
    view.setUint32(at, 0x02014b50, true);
    view.setUint16(at + 4, 20, true);
    view.setUint16(at + 6, 20, true);
    view.setUint16(at + 8, 0x0800, true);
    view.setUint16(at + 10, 0, true);
    view.setUint16(at + 12, dosTime, true);
    view.setUint16(at + 14, dosDate, true);
    view.setUint32(at + 16, crcs[i], true);
    view.setUint32(at + 20, entry.data.length, true);
    view.setUint32(at + 24, entry.data.length, true);
    view.setUint16(at + 28, names[i].length, true);
    view.setUint16(at + 30, 0, true);
    view.setUint16(at + 32, 0, true);
    view.setUint16(at + 34, 0, true);
    view.setUint16(at + 36, 0, true);
    view.setUint32(at + 38, 0, true);
    view.setUint32(at + 42, offsets[i], true);
    out.set(names[i], at + 46);
    at += 46 + names[i].length;
  });
  view.setUint32(at, 0x06054b50, true);
  view.setUint16(at + 4, 0, true);
  view.setUint16(at + 6, 0, true);
  view.setUint16(at + 8, entries.length, true);
  view.setUint16(at + 10, entries.length, true);
  view.setUint32(at + 12, at - centralStart, true);
  view.setUint32(at + 16, centralStart, true);
  view.setUint16(at + 20, 0, true);
  return out;
}
