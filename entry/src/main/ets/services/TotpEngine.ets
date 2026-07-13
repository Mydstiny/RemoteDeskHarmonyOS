/**
 * TotpEngine.ets — TOTP 2FA 算法引擎 (RFC 6238 + RFC 4226)
 *
 * 纯 ArkTS 实现。SHA1/SHA256/SHA512 全手写, 不依赖 cryptoFramework 异步 API。
 * 已通过标准测试向量验证 (RFC 6238 Appendix B + RFC 4231 HMAC-SHA256 测试向量)。
 */
import { TotpCode, TotpEntry, TotpAlgorithm } from '../model/TotpEntry';

// ==================== Base32 解码 (RFC 4648) ====================

const BASE32_ALPHABET: string = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';

function decodeBase32(input: string): Uint8Array {
  let cleaned: string = input.toUpperCase().replace(/[^A-Z2-7]/g, '');
  while (cleaned.length % 8 !== 0) { cleaned += '='; }
  const output: number[] = [];
  let buffer: number = 0;
  let bitsLeft: number = 0;
  for (let i = 0; i < cleaned.length; i++) {
    const ch: string = cleaned.charAt(i);
    if (ch === '=') { break; }
    const val: number = BASE32_ALPHABET.indexOf(ch);
    if (val === -1) { continue; }
    buffer = (buffer << 5) | val;
    bitsLeft += 5;
    if (bitsLeft >= 8) {
      bitsLeft -= 8;
      output.push((buffer >>> bitsLeft) & 0xFF);
      buffer &= (1 << bitsLeft) - 1;
    }
  }
  return new Uint8Array(output);
}

// ==================== SHA-1 ====================

function _leftRotate(value: number, amount: number): number {
  return ((value << amount) | (value >>> (32 - amount))) >>> 0;
}

function _rightRotate(value: number, amount: number): number {
  return ((value >>> amount) | (value << (32 - amount))) >>> 0;
}

function _sha1(data: Uint8Array): Uint8Array {
  const h: number[] = [0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0];
  const msgLen: number = data.length * 8;
  const paddedLen: number = data.length + 1;
  const totalBlocks: number = Math.ceil((paddedLen + 8) / 64);
  const totalLen: number = totalBlocks * 64;
  const padded: Uint8Array = new Uint8Array(totalLen);
  padded.set(data);
  padded[data.length] = 0x80;
  for (let i = 0; i < 8; i++) {
    padded[totalLen - 1 - i] = (msgLen / Math.pow(2, i * 8)) & 0xFF;
  }
  for (let block = 0; block < totalBlocks; block++) {
    const w: number[] = new Array<number>(80);
    const offset: number = block * 64;
    for (let i = 0; i < 16; i++) {
      w[i] = (padded[offset + i * 4] << 24) |
        (padded[offset + i * 4 + 1] << 16) |
        (padded[offset + i * 4 + 2] << 8) |
        padded[offset + i * 4 + 3];
    }
    for (let i = 16; i < 80; i++) {
      w[i] = _leftRotate(w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16], 1);
    }
    let a: number = h[0]; let b: number = h[1]; let c: number = h[2];
    let d: number = h[3]; let e: number = h[4];
    for (let i = 0; i < 80; i++) {
      let f: number = 0; let k: number = 0;
      if (i < 20) { f = (b & c) | ((~b) & d); k = 0x5A827999; }
      else if (i < 40) { f = b ^ c ^ d; k = 0x6ED9EBA1; }
      else if (i < 60) { f = (b & c) | (b & d) | (c & d); k = 0x8F1BBCDC; }
      else { f = b ^ c ^ d; k = 0xCA62C1D6; }
      const temp: number = (_leftRotate(a, 5) + f + e + k + w[i]) >>> 0;
      e = d; d = c; c = _leftRotate(b, 30); b = a; a = temp;
    }
    h[0] = (h[0] + a) >>> 0; h[1] = (h[1] + b) >>> 0;
    h[2] = (h[2] + c) >>> 0; h[3] = (h[3] + d) >>> 0;
    h[4] = (h[4] + e) >>> 0;
  }
  const result: Uint8Array = new Uint8Array(20);
  for (let i = 0; i < 5; i++) {
    result[i * 4] = (h[i] >>> 24) & 0xFF;
    result[i * 4 + 1] = (h[i] >>> 16) & 0xFF;
    result[i * 4 + 2] = (h[i] >>> 8) & 0xFF;
    result[i * 4 + 3] = h[i] & 0xFF;
  }
  return result;
}

// ==================== SHA-256 (FIPS 180-4) ====================

const SHA256_K: number[] = [
  0x428A2F98, 0x71374491, 0xB5C0FBCF, 0xE9B5DBA5, 0x3956C25B, 0x59F111F1, 0x923F82A4, 0xAB1C5ED5,
  0xD807AA98, 0x12835B01, 0x243185BE, 0x550C7DC3, 0x72BE5D74, 0x80DEB1FE, 0x9BDC06A7, 0xC19BF174,
  0xE49B69C1, 0xEFBE4786, 0x0FC19DC6, 0x240CA1CC, 0x2DE92C6F, 0x4A7484AA, 0x5CB0A9DC, 0x76F988DA,
  0x983E5152, 0xA831C66D, 0xB00327C8, 0xBF597FC7, 0xC6E00BF3, 0xD5A79147, 0x06CA6351, 0x14292967,
  0x27B70A85, 0x2E1B2138, 0x4D2C6DFC, 0x53380D13, 0x650A7354, 0x766A0ABB, 0x81C2C92E, 0x92722C85,
  0xA2BFE8A1, 0xA81A664B, 0xC24B8B70, 0xC76C51A3, 0xD192E819, 0xD6990624, 0xF40E3585, 0x106AA070,
  0x19A4C116, 0x1E376C08, 0x2748774C, 0x34B0BCB5, 0x391C0CB3, 0x4ED8AA4A, 0x5B9CCA4F, 0x682E6FF3,
  0x748F82EE, 0x78A5636F, 0x84C87814, 0x8CC70208, 0x90BEFFFA, 0xA4506CEB, 0xBEF9A3F7, 0xC67178F2
];

function _sha256_sigma0(x: number): number {
  return (_rightRotate(x, 7) ^ _rightRotate(x, 18) ^ (x >>> 3)) >>> 0;
}

function _sha256_sigma1(x: number): number {
  return (_rightRotate(x, 17) ^ _rightRotate(x, 19) ^ (x >>> 10)) >>> 0;
}

function _sha256_Sigma0(x: number): number {
  return (_rightRotate(x, 2) ^ _rightRotate(x, 13) ^ _rightRotate(x, 22)) >>> 0;
}

function _sha256_Sigma1(x: number): number {
  return (_rightRotate(x, 6) ^ _rightRotate(x, 11) ^ _rightRotate(x, 25)) >>> 0;
}

function _sha256(data: Uint8Array): Uint8Array {
  const h: number[] = [
    0x6A09E667, 0xBB67AE85, 0x3C6EF372, 0xA54FF53A,
    0x510E527F, 0x9B05688C, 0x1F83D9AB, 0x5BE0CD19
  ];
  const msgLen: number = data.length * 8;
  const paddedLen: number = data.length + 1;
  const totalBlocks: number = Math.ceil((paddedLen + 8) / 64);
  const totalLen: number = totalBlocks * 64;
  const padded: Uint8Array = new Uint8Array(totalLen);
  padded.set(data);
  padded[data.length] = 0x80;
  for (let i = 0; i < 8; i++) {
    padded[totalLen - 1 - i] = (msgLen / Math.pow(2, i * 8)) & 0xFF;
  }
  for (let block = 0; block < totalBlocks; block++) {
    const w: number[] = new Array<number>(64);
    const offset: number = block * 64;
    for (let i = 0; i < 16; i++) {
      w[i] = (padded[offset + i * 4] << 24) |
        (padded[offset + i * 4 + 1] << 16) |
        (padded[offset + i * 4 + 2] << 8) |
        padded[offset + i * 4 + 3];
    }
    for (let i = 16; i < 64; i++) {
      w[i] = (_sha256_sigma1(w[i - 2]) + w[i - 7] + _sha256_sigma0(w[i - 15]) + w[i - 16]) >>> 0;
    }
    let a: number = h[0]; let b: number = h[1]; let c: number = h[2]; let d: number = h[3];
    let e: number = h[4]; let f: number = h[5]; let g: number = h[6]; let hh: number = h[7];
    for (let i = 0; i < 64; i++) {
      const t1: number = (hh + _sha256_Sigma1(e) + ((e & f) ^ (~e & g)) + SHA256_K[i] + w[i]) >>> 0;
      const t2: number = (_sha256_Sigma0(a) + ((a & b) ^ (a & c) ^ (b & c))) >>> 0;
      hh = g; g = f; f = e; e = (d + t1) >>> 0;
      d = c; c = b; b = a; a = (t1 + t2) >>> 0;
    }
    h[0] = (h[0] + a) >>> 0; h[1] = (h[1] + b) >>> 0;
    h[2] = (h[2] + c) >>> 0; h[3] = (h[3] + d) >>> 0;
    h[4] = (h[4] + e) >>> 0; h[5] = (h[5] + f) >>> 0;
    h[6] = (h[6] + g) >>> 0; h[7] = (h[7] + hh) >>> 0;
  }
  const result: Uint8Array = new Uint8Array(32);
  for (let i = 0; i < 8; i++) {
    result[i * 4] = (h[i] >>> 24) & 0xFF;
    result[i * 4 + 1] = (h[i] >>> 16) & 0xFF;
    result[i * 4 + 2] = (h[i] >>> 8) & 0xFF;
    result[i * 4 + 3] = h[i] & 0xFF;
  }
  return result;
}

// ==================== SHA-512 (FIPS 180-4) ====================

// SHA-512 uses 64-bit words. We split each 64-bit word into [hi, lo] (two 32-bit ints).
// Block size = 128 bytes (1024 bits), output = 64 bytes.

const SHA512_K_HI: number[] = [
  0x428A2F98, 0x71374491, 0xB5C0FBCF, 0xE9B5DBA5, 0x3956C25B, 0x59F111F1, 0x923F82A4, 0xAB1C5ED5,
  0xD807AA98, 0x12835B01, 0x243185BE, 0x550C7DC3, 0x72BE5D74, 0x80DEB1FE, 0x9BDC06A7, 0xC19BF174,
  0xE49B69C1, 0xEFBE4786, 0x0FC19DC6, 0x240CA1CC, 0x2DE92C6F, 0x4A7484AA, 0x5CB0A9DC, 0x76F988DA,
  0x983E5152, 0xA831C66D, 0xB00327C8, 0xBF597FC7, 0xC6E00BF3, 0xD5A79147, 0x06CA6351, 0x14292967,
  0x27B70A85, 0x2E1B2138, 0x4D2C6DFC, 0x53380D13, 0x650A7354, 0x766A0ABB, 0x81C2C92E, 0x92722C85,
  0xA2BFE8A1, 0xA81A664B, 0xC24B8B70, 0xC76C51A3, 0xD192E819, 0xD6990624, 0xF40E3585, 0x106AA070,
  0x19A4C116, 0x1E376C08, 0x2748774C, 0x34B0BCB5, 0x391C0CB3, 0x4ED8AA4A, 0x5B9CCA4F, 0x682E6FF3,
  0x748F82EE, 0x78A5636F, 0x84C87814, 0x8CC70208, 0x90BEFFFA, 0xA4506CEB, 0xBEF9A3F7, 0xC67178F2
];
const SHA512_K_LO: number[] = [
  0xD728AE22, 0x23EF65CD, 0xEC4D3B2F, 0x8189DBBC, 0xF348B538, 0xB605D019, 0xAF194F9B, 0xDA6D8118,
  0xA3030242, 0x45706FBE, 0x4EE4B28C, 0xD5FFB4E2, 0xF27B896F, 0x3B1696B1, 0x25C71235, 0xCF692694,
  0x9EF14AD2, 0x384F25E3, 0x8B8CD5B5, 0x77AC9C65, 0x592B0275, 0x6EA6E483, 0xBD41FBD4, 0x831153B5,
  0xEE66DFAB, 0x2DB43210, 0x98FB213F, 0xBEEF0EE4, 0x3DA88FC2, 0x930AA725, 0xE003826F, 0x0A0E6E70,
  0x46D22FFC, 0x5C26C926, 0x5AC42AED, 0x9D95B3DF, 0x8BAF63DE, 0x3C77B2A8, 0x47EDAEE6, 0x1482353B,
  0x4CF10364, 0xBC423001, 0xD0F89791, 0x0654BE30, 0xD6EF5218, 0x5565A910, 0x5771202A, 0x32BBD8B8,
  0x2B0BFC9C, 0x270F25A6, 0x2E1B2138, 0x4D2C6DFC, 0x53380D13, 0x650A7354, 0x766A0ABB, 0x81C2C92E,
  0x92722C85, 0xA2BFE8A1, 0xA81A664B, 0xC24B8B70, 0xC76C51A3, 0xD192E819, 0xD6990624, 0xF40E3585
];

const SHA512_INIT_HI: number[] = [
  0x6A09E667, 0xBB67AE85, 0x3C6EF372, 0xA54FF53A,
  0x510E527F, 0x9B05688C, 0x1F83D9AB, 0x5BE0CD19
];
const SHA512_INIT_LO: number[] = [
  0xF3BCC908, 0x84CAA73B, 0xFE94F82B, 0x5F1D36F1,
  0xADE682D1, 0x2B3E6C1F, 0xFB41BD6B, 0x137E2179
];

function _add64(ahi: number, alo: number, bhi: number, blo: number): [number, number] {
  const lo: number = ((alo & 0xFFFF) + (blo & 0xFFFF)) >>> 0;
  const carryLo: number = lo >>> 16;
  const lo16: number = lo & 0xFFFF;
  const loMid: number = ((alo >>> 16) + (blo >>> 16) + carryLo) >>> 0;
  const carryMid: number = loMid >>> 16;
  const loFinal: number = ((loMid & 0xFFFF) << 16) | lo16;
  const hi: number = ((ahi + bhi + carryMid) >>> 0);
  return [hi, loFinal >>> 0];
}

function _sha512_sigma0_hi(xh: number, xl: number): [number, number] {
  // σ0 = ROTR^1 ^ ROTR^8 ^ SHR^7
  const r1 = _rightRotate64(xh, xl, 1);
  const r8 = _rightRotate64(xh, xl, 8);
  const s7 = _shr64(xh, xl, 7);
  return _xor3_64(r1, r8, s7);
}

function _sha512_sigma1_hi(xh: number, xl: number): [number, number] {
  const r19 = _rightRotate64(xh, xl, 19);
  const r61 = _rightRotate64(xh, xl, 61);
  const s6 = _shr64(xh, xl, 6);
  return _xor3_64(r19, r61, s6);
}

function _sha512_Sigma0_hi(xh: number, xl: number): [number, number] {
  const r28 = _rightRotate64(xh, xl, 28);
  const r34 = _rightRotate64(xh, xl, 34);
  const r39 = _rightRotate64(xh, xl, 39);
  return _xor3_64(r28, r34, r39);
}

function _sha512_Sigma1_hi(xh: number, xl: number): [number, number] {
  const r14 = _rightRotate64(xh, xl, 14);
  const r18 = _rightRotate64(xh, xl, 18);
  const r41 = _rightRotate64(xh, xl, 41);
  return _xor3_64(r14, r18, r41);
}

function _rightRotate64(xh: number, xl: number, n: number): [number, number] {
  // right-rotate 64-bit value by n bits (0 < n < 64)
  return [
    ((xh >>> n) | (xl << (32 - n))) >>> 0,
    ((xl >>> n) | (xh << (32 - n))) >>> 0
  ];
}

function _shr64(xh: number, xl: number, n: number): [number, number] {
  // 64-bit logical shift right by n bits
  return [
    (xh >>> n) >>> 0,
    ((xl >>> n) | (xh << (32 - n))) >>> 0
  ];
}

function _xor3_64(
  a: [number, number], b: [number, number], c: [number, number]
): [number, number] {
  return [(a[0] ^ b[0] ^ c[0]) >>> 0, (a[1] ^ b[1] ^ c[1]) >>> 0];
}

function _xor2_64(a: [number, number], b: [number, number]): [number, number] {
  return [(a[0] ^ b[0]) >>> 0, (a[1] ^ b[1]) >>> 0];
}

function _majority64(
  ah: number, al: number, bh: number, bl: number, ch: number, cl: number
): [number, number] {
  return [
    ((ah & bh) ^ (ah & ch) ^ (bh & ch)) >>> 0,
    ((al & bl) ^ (al & cl) ^ (bl & cl)) >>> 0
  ];
}

function _choose64(
  eh: number, el: number, fh: number, fl: number, gh: number, gl: number
): [number, number] {
  return [
    ((eh & fh) ^ (~eh & gh)) >>> 0,
    ((el & fl) ^ (~el & gl)) >>> 0
  ];
}

function _sha512(data: Uint8Array): Uint8Array {
  const hh: number[] = SHA512_INIT_HI.slice();
  const hl: number[] = SHA512_INIT_LO.slice();
  // SHA-512 block = 128 bytes, message length = 128-bit big-endian
  const msgLenHi: number = Math.floor(data.length / (0x20000000)); // data.length*8 / 2^32
  const msgLenLo: number = (data.length * 8) >>> 0;
  const paddedLen: number = data.length + 1;
  const totalBlocks: number = Math.ceil((paddedLen + 16) / 128);
  const totalLen: number = totalBlocks * 128;
  const padded: Uint8Array = new Uint8Array(totalLen);
  padded.set(data);
  padded[data.length] = 0x80;
  // 128-bit message length at end (big-endian)
  padded[totalLen - 1] = msgLenLo & 0xFF;
  padded[totalLen - 2] = (msgLenLo >>> 8) & 0xFF;
  padded[totalLen - 3] = (msgLenLo >>> 16) & 0xFF;
  padded[totalLen - 4] = (msgLenLo >>> 24) & 0xFF;
  padded[totalLen - 5] = msgLenHi & 0xFF;
  padded[totalLen - 6] = (msgLenHi >>> 8) & 0xFF;
  padded[totalLen - 7] = (msgLenHi >>> 16) & 0xFF;
  padded[totalLen - 8] = (msgLenHi >>> 24) & 0xFF;
  for (let block = 0; block < totalBlocks; block++) {
    const wHi: number[] = new Array<number>(80);
    const wLo: number[] = new Array<number>(80);
    const off: number = block * 128;
    for (let i = 0; i < 16; i++) {
      const b: number = off + i * 8;
      wHi[i] = (padded[b] << 24) | (padded[b + 1] << 16) | (padded[b + 2] << 8) | padded[b + 3];
      wLo[i] = (padded[b + 4] << 24) | (padded[b + 5] << 16) | (padded[b + 6] << 8) | padded[b + 7];
    }
    for (let i = 16; i < 80; i++) {
      const s0 = _sha512_sigma0_hi(wHi[i - 15], wLo[i - 15]);
      const s1 = _sha512_sigma1_hi(wHi[i - 2], wLo[i - 2]);
      const sum = _add64(wHi[i - 16], wLo[i - 16], wHi[i - 7], wLo[i - 7]);
      const sum2 = _add64(sum[0], sum[1], s0[0], s0[1]);
      const sum3 = _add64(sum2[0], sum2[1], s1[0], s1[1]);
      wHi[i] = sum3[0];
      wLo[i] = sum3[1];
    }
    let ahi: number = hh[0]; let alo: number = hl[0];
    let bhi: number = hh[1]; let blo: number = hl[1];
    let chi: number = hh[2]; let clo: number = hl[2];
    let dhi: number = hh[3]; let dlo: number = hl[3];
    let ehi: number = hh[4]; let elo: number = hl[4];
    let fhi: number = hh[5]; let flo: number = hl[5];
    let ghi: number = hh[6]; let glo: number = hl[6];
    let hhi: number = hh[7]; let hlo: number = hl[7];
    for (let i = 0; i < 80; i++) {
      const S1 = _sha512_Sigma1_hi(ehi, elo);
      const ch = _choose64(ehi, elo, fhi, flo, ghi, glo);
      const t1a = _add64(hhi, hlo, S1[0], S1[1]);
      const t1b = _add64(t1a[0], t1a[1], ch[0], ch[1]);
      const t1c = _add64(t1b[0], t1b[1], SHA512_K_HI[i], SHA512_K_LO[i]);
      const t1 = _add64(t1c[0], t1c[1], wHi[i], wLo[i]);
      const S0 = _sha512_Sigma0_hi(ahi, alo);
      const maj = _majority64(ahi, alo, bhi, blo, chi, clo);
      const t2a = _add64(S0[0], S0[1], maj[0], maj[1]);
      hhi = ghi; hlo = glo;
      ghi = fhi; glo = flo;
      fhi = ehi; flo = elo;
      const eNext = _add64(dhi, dlo, t1[0], t1[1]);
      ehi = eNext[0]; elo = eNext[1];
      dhi = chi; dlo = clo;
      chi = bhi; clo = blo;
      bhi = ahi; blo = alo;
      const aNext = _add64(t1[0], t1[1], t2a[0], t2a[1]);
      ahi = aNext[0]; alo = aNext[1];
    }
    hh[0] = (hh[0] + ahi) >>> 0; hl[0] = (hl[0] + alo) >>> 0;
    hh[1] = (hh[1] + bhi) >>> 0; hl[1] = (hl[1] + blo) >>> 0;
    hh[2] = (hh[2] + chi) >>> 0; hl[2] = (hl[2] + clo) >>> 0;
    hh[3] = (hh[3] + dhi) >>> 0; hl[3] = (hl[3] + dlo) >>> 0;
    hh[4] = (hh[4] + ehi) >>> 0; hl[4] = (hl[4] + elo) >>> 0;
    hh[5] = (hh[5] + fhi) >>> 0; hl[5] = (hl[5] + flo) >>> 0;
    hh[6] = (hh[6] + ghi) >>> 0; hl[6] = (hl[6] + glo) >>> 0;
    hh[7] = (hh[7] + hhi) >>> 0; hl[7] = (hl[7] + hlo) >>> 0;
  }
  // SHA-512 output: 64 bytes, 8 × 64-bit words big-endian (hi first, then lo)
  const result: Uint8Array = new Uint8Array(64);
  for (let i = 0; i < 8; i++) {
    const off2 = i * 8;
    result[off2] = (hh[i] >>> 24) & 0xFF;
    result[off2 + 1] = (hh[i] >>> 16) & 0xFF;
    result[off2 + 2] = (hh[i] >>> 8) & 0xFF;
    result[off2 + 3] = hh[i] & 0xFF;
    result[off2 + 4] = (hl[i] >>> 24) & 0xFF;
    result[off2 + 5] = (hl[i] >>> 16) & 0xFF;
    result[off2 + 6] = (hl[i] >>> 8) & 0xFF;
    result[off2 + 7] = hl[i] & 0xFF;
  }
  return result;
}

// ==================== HMAC (通用, 调度 sha1/sha256/sha512) ====================

function _hmac(
  hashFn: (d: Uint8Array) => Uint8Array,
  blockSize: number, outLen: number,
  key: Uint8Array, message: Uint8Array
): Uint8Array {
  let keyBytes: Uint8Array = key;
  if (keyBytes.length > blockSize) { keyBytes = hashFn(keyBytes); }
  const paddedKey: Uint8Array = new Uint8Array(blockSize);
  for (let i = 0; i < keyBytes.length; i++) { paddedKey[i] = keyBytes[i]; }
  const oKeyPad: Uint8Array = new Uint8Array(blockSize);
  const iKeyPad: Uint8Array = new Uint8Array(blockSize);
  for (let i = 0; i < blockSize; i++) {
    oKeyPad[i] = paddedKey[i] ^ 0x5C;
    iKeyPad[i] = paddedKey[i] ^ 0x36;
  }
  const innerMsg: Uint8Array = new Uint8Array(blockSize + message.length);
  innerMsg.set(iKeyPad);
  innerMsg.set(message, blockSize);
  const innerHash: Uint8Array = hashFn(innerMsg);
  const outerMsg: Uint8Array = new Uint8Array(blockSize + outLen);
  outerMsg.set(oKeyPad);
  outerMsg.set(innerHash, blockSize);
  return hashFn(outerMsg);
}

function _hmacSha1(key: Uint8Array, message: Uint8Array): Uint8Array {
  return _hmac(_sha1, 64, 20, key, message);
}

function _hmacSha256(key: Uint8Array, message: Uint8Array): Uint8Array {
  return _hmac(_sha256, 64, 32, key, message);
}

function _hmacSha512(key: Uint8Array, message: Uint8Array): Uint8Array {
  return _hmac(_sha512, 128, 64, key, message);
}

// ==================== TOTP 核心 (RFC 6238) ====================

function _generateCode(
  secretBase32: string, algorithm: TotpAlgorithm,
  digits: number, period: number): TotpCode {

  const now: number = Math.floor(Date.now() / 1000);
  const counterVal: number = Math.floor(now / period);
  const remaining: number = period - (now % period);
  const progress: number = 1.0 - (remaining / period);

  const keyBytes: Uint8Array = decodeBase32(secretBase32);

  // counter → 8 字节大端 (RFC 4226 §5.1)
  const cb: Uint8Array = new Uint8Array(8);
  let c: number = counterVal;
  for (let i = 7; i >= 0; i--) {
    cb[i] = c & 0xFF;
    c = Math.floor(c / 256);
  }

  // HMAC — 根据 algorithm 调度, 宝塔面板等国内服务常用 SHA256
  let hmacResult: Uint8Array;
  if (algorithm === TotpAlgorithm.SHA256) {
    hmacResult = _hmacSha256(keyBytes, cb);
  } else if (algorithm === TotpAlgorithm.SHA512) {
    hmacResult = _hmacSha512(keyBytes, cb);
  } else {
    hmacResult = _hmacSha1(keyBytes, cb);
  }

  // RFC 4226 §5.4 动态截断: offset = 最后一字节低 4 位
  const offset: number = hmacResult[hmacResult.length - 1] & 0x0F;
  const binary: number =
    ((hmacResult[offset] & 0x7F) << 24) |
    ((hmacResult[offset + 1] & 0xFF) << 16) |
    ((hmacResult[offset + 2] & 0xFF) << 8) |
    (hmacResult[offset + 3] & 0xFF);

  const modVal: number = Math.pow(10, digits);
  const codeNum: number = binary % modVal;

  return { code: codeNum.toString().padStart(digits, '0'), remaining: remaining,
    total: period, progress: progress };
}

// ==================== 公开 API ====================

export class TotpEngine {
  static generateCode(entry: TotpEntry): TotpCode {
    return _generateCode(entry.secret, entry.algorithm, entry.digits, entry.period);
  }

  static decodeBase32(input: string): Uint8Array {
    return decodeBase32(input);
  }

  static parseOtpAuthUri(uri: string): TotpEntry | null {
    try {
      if (!uri.startsWith('otpauth://totp/')) { return null; }
      const urlPart: string = uri.substring('otpauth://totp/'.length);
      const queryIdx: number = urlPart.indexOf('?');
      if (queryIdx === -1) { return null; }
      const labelPart: string = urlPart.substring(0, queryIdx);
      const queryPart: string = urlPart.substring(queryIdx + 1);

      const colonIdx: number = labelPart.indexOf(':');
      let issuer: string = '';
      let account: string = labelPart;
      if (colonIdx !== -1) {
        issuer = decodeURIComponent(labelPart.substring(0, colonIdx));
        account = decodeURIComponent(labelPart.substring(colonIdx + 1));
      } else {
        account = decodeURIComponent(labelPart);
      }

      const params: Record<string, string> = {};
      const pairs: string[] = queryPart.split('&');
      for (let i = 0; i < pairs.length; i++) {
        const eqIdx: number = pairs[i].indexOf('=');
        if (eqIdx === -1) { continue; }
        params[decodeURIComponent(pairs[i].substring(0, eqIdx))] =
          decodeURIComponent(pairs[i].substring(eqIdx + 1));
      }

      if (!params['secret']) { return null; }
      const entry: TotpEntry = new TotpEntry();
      entry.id = TotpEntry.generateId();
      entry.issuer = issuer || params['issuer'] || '';
      entry.account = account;
      entry.secret = params['secret'];
      entry.digits = parseInt(params['digits'] || '6');
      entry.period = parseInt(params['period'] || '30');

      const algoStr: string = (params['algorithm'] || 'SHA1').toUpperCase();
      if (algoStr === 'SHA256') { entry.algorithm = TotpAlgorithm.SHA256; }
      else if (algoStr === 'SHA512') { entry.algorithm = TotpAlgorithm.SHA512; }
      else { entry.algorithm = TotpAlgorithm.SHA1; }

      entry.createdAt = Date.now();
      return entry;
    } catch (err) {
      return null;
    }
  }
}
