import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';

export const MOONLIGHT_APP_CACHE_MAX_ENTRIES: number = 2048;
export const MOONLIGHT_APP_CACHE_MAX_BYTES: number = 64 * 1024 * 1024;
export const MOONLIGHT_APP_CACHE_MAX_ENTRY_BYTES: number = 2 * 1024 * 1024;

export interface MoonlightAppCacheEntryJSON {
  id: string;
  userId: string;
  hostId: string;
  appId: string;
  title: string;
  iconEtag: string;
  iconHashSha256: string;
  artworkLocalPath: string;
  catalogEtag: string;
  catalogHashSha256: string;
  available: boolean;
  sortOrder: number;
  lastCatalogAt: number;
  expiresAt: number;
  lastAccessedAt: number;
  sizeBytes: number;
}

export class MoonlightAppCacheEntry {
  id: string = '';
  userId: string = '';
  hostId: string = '';
  appId: string = '';
  title: string = '';
  iconEtag: string = '';
  iconHashSha256: string = '';
  artworkLocalPath: string = '';
  catalogEtag: string = '';
  catalogHashSha256: string = '';
  available: boolean = true;
  sortOrder: number = 0;
  lastCatalogAt: number = 0;
  expiresAt: number = 0;
  lastAccessedAt: number = 0;
  sizeBytes: number = 0;

  toJSON(): MoonlightAppCacheEntryJSON {
    return {
      id: this.id,
      userId: this.userId,
      hostId: this.hostId,
      appId: this.appId,
      title: this.title,
      iconEtag: this.iconEtag,
      iconHashSha256: this.iconHashSha256,
      artworkLocalPath: this.artworkLocalPath,
      catalogEtag: this.catalogEtag,
      catalogHashSha256: this.catalogHashSha256,
      available: this.available,
      sortOrder: this.sortOrder,
      lastCatalogAt: this.lastCatalogAt,
      expiresAt: this.expiresAt,
      lastAccessedAt: this.lastAccessedAt,
      sizeBytes: this.sizeBytes
    };
  }

  static fromJSON(json: MoonlightAppCacheEntryJSON): MoonlightAppCacheEntry {
    const entry = new MoonlightAppCacheEntry();
    entry.id = json.id;
    entry.userId = json.userId;
    entry.hostId = json.hostId;
    entry.appId = json.appId;
    entry.title = json.title;
    entry.iconEtag = json.iconEtag;
    entry.iconHashSha256 = json.iconHashSha256;
    entry.artworkLocalPath = json.artworkLocalPath;
    entry.catalogEtag = json.catalogEtag;
    entry.catalogHashSha256 = json.catalogHashSha256;
    entry.available = json.available;
    entry.sortOrder = json.sortOrder;
    entry.lastCatalogAt = json.lastCatalogAt;
    entry.expiresAt = json.expiresAt;
    entry.lastAccessedAt = json.lastAccessedAt;
    entry.sizeBytes = json.sizeBytes;
    return entry;
  }
}

function sha256Hex(value: string): string {
  const md = cryptoFramework.createMd('SHA256');
  md.updateSync({ data: new util.TextEncoder().encode(value) });
  const bytes: Uint8Array = md.digestSync().data;
  let result: string = '';
  for (let i = 0; i < bytes.length; i++) {
    result += bytes[i].toString(16).padStart(2, '0');
  }
  return result;
}

/** Deterministic, opaque key over the complete owner + host + app identity. */
export function moonlightAppCacheIdentity(
  userId: string, hostId: string, appId: string
): string {
  const owner: string = userId.trim();
  const host: string = hostId.trim();
  const app: string = appId.trim();
  if (owner === '' || host === '' || app === '') { return ''; }
  return sha256Hex('RemoteDeskHarmonyOS:moonlight-app-cache:v1\u0000' +
    owner + '\u0000' + host + '\u0000' + app);
}

function boundedText(value: string, minimum: number, maximum: number): boolean {
  if (typeof value !== 'string' || value.length < minimum || value.length > maximum) {
    return false;
  }
  for (let i = 0; i < value.length; i++) {
    const code: number = value.charCodeAt(i);
    if (code < 0x20 || code === 0x7f) { return false; }
  }
  return true;
}

function optionalText(value: string, maximum: number): boolean {
  return value === '' || boundedText(value, 1, maximum);
}

function optionalSha256(value: string): boolean {
  return value === '' || /^[0-9a-f]{64}$/.test(value);
}

function nonNegativeInteger(value: number): boolean {
  return Number.isSafeInteger(value) && value >= 0;
}

export function moonlightAppCacheEntryIsValid(
  entry: MoonlightAppCacheEntry
): boolean {
  if (entry === undefined || entry === null || typeof entry !== 'object' ||
      !boundedText(entry.userId, 1, 128) ||
      !boundedText(entry.hostId, 1, 128) ||
      !boundedText(entry.appId, 1, 128) ||
      !boundedText(entry.title, 1, 256) ||
      !optionalText(entry.iconEtag, 512) ||
      !optionalText(entry.catalogEtag, 512) ||
      !optionalText(entry.artworkLocalPath, 1024) ||
      !optionalSha256(entry.iconHashSha256) ||
      !optionalSha256(entry.catalogHashSha256) ||
      typeof entry.available !== 'boolean' ||
      !nonNegativeInteger(entry.sortOrder) || entry.sortOrder > 1000000 ||
      !nonNegativeInteger(entry.lastCatalogAt) ||
      !nonNegativeInteger(entry.expiresAt) ||
      !nonNegativeInteger(entry.lastAccessedAt) ||
      !nonNegativeInteger(entry.sizeBytes) ||
      entry.sizeBytes > MOONLIGHT_APP_CACHE_MAX_ENTRY_BYTES ||
      entry.expiresAt < entry.lastCatalogAt) {
    return false;
  }
  return entry.id === moonlightAppCacheIdentity(
    entry.userId, entry.hostId, entry.appId);
}

export function cloneMoonlightAppCacheEntry(
  source: MoonlightAppCacheEntry
): MoonlightAppCacheEntry {
  return MoonlightAppCacheEntry.fromJSON(source.toJSON());
}
