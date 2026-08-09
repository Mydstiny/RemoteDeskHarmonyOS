import { image } from '@kit.ImageKit';

export type TotpBrandCacheState = 'ready' | 'failed';

/**
 * A decoded brand object owns native image memory and must release it when it
 * leaves the cache.  The production implementation wraps an ImageKit
 * PixelMap; tests use the same contract with a release counter.
 */
export interface TotpDecodedAsset {
  readonly bytes: number;
  /** The same decoded object that the visible Image consumes; no second decode path. */
  readonly pixelMap?: image.PixelMap;
  release(): void;
}

export type TotpBrandDecodeFactory = () => Promise<TotpDecodedAsset | null>;

class TotpBrandDecodeTask {
  readonly key: string;
  readonly reservedBytes: number;
  readonly epoch: number;
  cancelled: boolean = false;
  reservationReturned: boolean = false;
  promise: Promise<boolean> = Promise.resolve(false);

  constructor(key: string, reservedBytes: number, epoch: number) {
    this.key = key;
    this.reservedBytes = reservedBytes;
    this.epoch = epoch;
  }
}

export class TotpBrandAssetLease {
  readonly asset: TotpDecodedAsset;
  private readonly releaseCallback: () => void;
  private released: boolean = false;

  constructor(asset: TotpDecodedAsset, releaseCallback: () => void) {
    this.asset = asset;
    this.releaseCallback = releaseCallback;
  }

  release(): void {
    if (this.released) { return; }
    this.released = true;
    this.releaseCallback();
  }
}

export interface TotpBrandCacheRecord {
  brandId: string;
  sha256: string;
  state: TotpBrandCacheState;
  estimatedBytes: number;
  decoded: TotpDecodedAsset | null;
  updatedAt: number;
  lastUsedAt: number;
  referenceCount: number;
  evicted: boolean;
  released: boolean;
}

export const TOTP_BRAND_CACHE_MAX_ENTRIES: number = 64;
export const TOTP_BRAND_CACHE_MAX_BYTES: number = 8 * 1024 * 1024;

/**
 * Process-local LRU for decoded local brand assets.
 *
 * The cache stores the releasable decoded object, not just the SVG file size.
 * Every replacement, eviction, oversize rejection, and lifecycle clear calls
 * release() exactly once.  The byte counter is the decoded PixelMap budget and
 * is bounded independently of the rawfile package size.
 */
export class TotpBrandCache {
  private readonly maxEntries: number;
  private readonly maxBytes: number;
  private readonly records: Map<string, TotpBrandCacheRecord> =
    new Map<string, TotpBrandCacheRecord>();
  private sequence: number = 0;
  private bytes: number = 0;
  private peak: number = 0;
  private reserved: number = 0;
  private decodeEpoch: number = 0;
  private readonly inflight: Map<string, TotpBrandDecodeTask> =
    new Map<string, TotpBrandDecodeTask>();

  constructor(
    maxEntries: number = TOTP_BRAND_CACHE_MAX_ENTRIES,
    maxBytes: number = TOTP_BRAND_CACHE_MAX_BYTES
  ) {
    this.maxEntries = Math.max(1, Math.floor(maxEntries));
    this.maxBytes = Math.min(
      TOTP_BRAND_CACHE_MAX_BYTES,
      Math.max(1, Math.floor(maxBytes)));
  }

  get(brandId: string, sha256: string = ''): TotpBrandCacheRecord | null {
    const record: TotpBrandCacheRecord | undefined = this.records.get(brandId);
    if (record === undefined || (sha256 !== '' && record.sha256 !== sha256)) {
      return null;
    }
    record.lastUsedAt = ++this.sequence;
    return record;
  }

  /** Acquire a reference held by a visible component until it disappears. */
  acquire(brandId: string, sha256: string): TotpBrandAssetLease | null {
    const record: TotpBrandCacheRecord | null = this.get(brandId, sha256);
    if (record === null || record.state !== 'ready' || record.decoded === null ||
      record.evicted || record.released) {
      return null;
    }
    record.referenceCount++;
    return new TotpBrandAssetLease(record.decoded, (): void => {
      this.releaseLease(record);
    });
  }

  /**
   * Coalesce one decode per brand/hash and reserve the decoder's proven maximum
   * output before it can allocate a PixelMap. Each caller receives its own
   * lease after the shared decode is admitted to the cache.
   */
  async acquireOrDecode(
    brandId: string,
    sha256: string,
    maxDecodedBytes: number,
    factory: TotpBrandDecodeFactory
  ): Promise<TotpBrandAssetLease | null> {
    const cached: TotpBrandAssetLease | null = this.acquire(brandId, sha256);
    if (cached !== null) { return cached; }
    const key: string = this.decodeKey(brandId, sha256);
    let task: TotpBrandDecodeTask | null | undefined = this.inflight.get(key);
    if (task === undefined || task.cancelled) {
      if (task !== undefined) { this.inflight.delete(key); }
      task = this.startDecode(key, brandId, sha256, maxDecodedBytes, factory);
    }
    if (task === null || task === undefined) { return null; }
    const succeeded: boolean = await task.promise;
    return succeeded ? this.acquire(brandId, sha256) : null;
  }

  putReady(
    brandId: string,
    sha256: string,
    decoded: TotpDecodedAsset,
    nowMs: number = Date.now()
  ): boolean {
    const rawBytes: number = decoded.bytes;
    if (rawBytes !== rawBytes || rawBytes <= 0 || rawBytes > this.maxBytes) {
      this.releaseUnowned(decoded);
      return false;
    }
    const bytes: number = Math.max(1, Math.floor(rawBytes));
    const previous: TotpBrandCacheRecord | undefined = this.records.get(brandId);
    // A leased record is still part of the hard budget even after a logical
    // replacement is requested.  Do not remove it before admission: if the
    // replacement cannot fit, the visible consumer must retain its current
    // cache record and the rejected object must be the only release.
    if (previous !== undefined && previous.referenceCount === 0) {
      this.remove(brandId);
    }
    // Make room before taking ownership so the observable cache footprint
    // never crosses the budget even for the short insertion window.
    while (this.records.size + this.inflight.size >= this.maxEntries ||
      this.bytes + this.reserved + bytes > this.maxBytes) {
      if (!this.evictOldest()) { break; }
    }
    if (this.records.size + this.inflight.size >= this.maxEntries ||
      this.bytes + this.reserved + bytes > this.maxBytes) {
      // Every remaining record is leased, so retaining another decoded
      // PixelMap would exceed the hard resident-memory budget.
      this.releaseUnowned(decoded);
      return false;
    }
    const record: TotpBrandCacheRecord = {
      brandId,
      sha256,
      state: 'ready',
      estimatedBytes: bytes,
      decoded,
      updatedAt: nowMs,
      lastUsedAt: ++this.sequence,
      referenceCount: 0,
      evicted: false,
      released: false
    };
    if (previous !== undefined && previous.referenceCount > 0 && !previous.evicted) {
      previous.evicted = true;
    }
    this.records.set(brandId, record);
    this.bytes += bytes;
    this.peak = Math.max(this.peak, this.bytes + this.reserved);
    this.evict();
    return this.records.get(brandId) === record;
  }

  markFailed(
    brandId: string,
    sha256: string,
    nowMs: number = Date.now()
  ): void {
    this.remove(brandId);
    this.records.set(brandId, {
      brandId,
      sha256,
      state: 'failed',
      estimatedBytes: 0,
      decoded: null,
      updatedAt: nowMs,
      lastUsedAt: ++this.sequence,
      referenceCount: 0,
      evicted: false,
      released: false
    });
    this.evict();
  }

  clear(): void {
    this.decodeEpoch++;
    const tasks: TotpBrandDecodeTask[] = Array.from(this.inflight.values());
    for (let index = 0; index < tasks.length; index++) {
      this.cancelDecodeTask(tasks[index]);
    }
    const ids: string[] = Array.from(this.records.keys());
    for (let index = 0; index < ids.length; index++) {
      this.remove(ids[index]);
    }
  }

  entryCount(): number {
    return this.records.size;
  }

  totalBytes(): number {
    return this.bytes;
  }

  reservedBytes(): number {
    return this.reserved;
  }

  peakBytes(): number {
    return this.peak;
  }

  maxBytesBudget(): number {
    return this.maxBytes;
  }

  storesPixelMap(): boolean {
    return true;
  }

  private releaseRecord(record: TotpBrandCacheRecord): void {
    if (record.released) { return; }
    record.released = true;
    this.bytes = Math.max(0, this.bytes - record.estimatedBytes);
    const decoded: TotpDecodedAsset | null = record.decoded;
    record.decoded = null;
    if (decoded === null) { return; }
    this.releaseUnowned(decoded);
  }

  private releaseUnowned(decoded: TotpDecodedAsset): void {
    try {
      decoded.release();
    } catch (_error) {
      // Release is best effort; ownership is still removed from the cache.
    }
  }

  private decodeKey(brandId: string, sha256: string): string {
    return brandId + '|' + sha256;
  }

  private startDecode(
    key: string,
    brandId: string,
    sha256: string,
    maxDecodedBytes: number,
    factory: TotpBrandDecodeFactory
  ): TotpBrandDecodeTask | null {
    const rawRequested: number = maxDecodedBytes;
    if (rawRequested !== rawRequested || rawRequested <= 0 || rawRequested > this.maxBytes) {
      return null;
    }
    const requested: number = Math.max(1, Math.floor(rawRequested));
    while (this.records.size + this.inflight.size >= this.maxEntries ||
      this.bytes + this.reserved + requested > this.maxBytes) {
      if (!this.evictOldest()) { return null; }
    }
    this.reserved += requested;
    this.peak = Math.max(this.peak, this.bytes + this.reserved);
    const task: TotpBrandDecodeTask =
      new TotpBrandDecodeTask(key, requested, this.decodeEpoch);
    this.inflight.set(key, task);
    task.promise = this.runDecode(task, brandId, sha256, factory);
    task.promise.then((): void => {
      this.finishDecodeTask(task);
    }, (): void => {
      this.finishDecodeTask(task);
    });
    return task;
  }

  private async runDecode(
    task: TotpBrandDecodeTask,
    brandId: string,
    sha256: string,
    factory: TotpBrandDecodeFactory
  ): Promise<boolean> {
    let decoded: TotpDecodedAsset | null = null;
    try {
      decoded = await factory();
      if (decoded === null) {
        this.returnReservation(task);
        this.finishDecodeTask(task);
        return false;
      }
      if (task.cancelled || task.epoch !== this.decodeEpoch) {
        this.returnReservation(task);
        this.releaseUnowned(decoded);
        this.finishDecodeTask(task);
        return false;
      }
      const rawActualBytes: number = decoded.bytes;
      if (rawActualBytes !== rawActualBytes || rawActualBytes <= 0) {
        this.returnReservation(task);
        this.releaseUnowned(decoded);
        this.finishDecodeTask(task);
        return false;
      }
      const actualBytes: number = Math.max(1, Math.floor(rawActualBytes));
      if (!this.settleReservation(task, actualBytes)) {
        this.releaseUnowned(decoded);
        this.finishDecodeTask(task);
        return false;
      }
      // Do not count this task as an entry while putReady enforces maxEntries.
      this.finishDecodeTask(task);
      const accepted: boolean = this.putReady(brandId, sha256, decoded);
      decoded = null;
      return accepted;
    } catch (_error) {
      this.returnReservation(task);
      if (decoded !== null) {
        this.releaseUnowned(decoded);
        decoded = null;
      }
      this.finishDecodeTask(task);
      return false;
    }
  }

  private settleReservation(task: TotpBrandDecodeTask, actualBytes: number): boolean {
    if (task.reservationReturned) { return false; }
    const otherReserved: number = this.reserved - task.reservedBytes;
    if (actualBytes > task.reservedBytes || actualBytes > this.maxBytes ||
      this.bytes + otherReserved + actualBytes > this.maxBytes) {
      this.returnReservation(task);
      return false;
    }
    this.reserved = Math.max(0, otherReserved);
    task.reservationReturned = true;
    return true;
  }

  private returnReservation(task: TotpBrandDecodeTask): void {
    if (task.reservationReturned) { return; }
    this.reserved = Math.max(0, this.reserved - task.reservedBytes);
    task.reservationReturned = true;
  }

  private cancelDecodeTask(task: TotpBrandDecodeTask): void {
    task.cancelled = true;
    this.returnReservation(task);
    this.finishDecodeTask(task);
  }

  private finishDecodeTask(task: TotpBrandDecodeTask): void {
    const current: TotpBrandDecodeTask | undefined = this.inflight.get(task.key);
    if (current === task) { this.inflight.delete(task.key); }
  }

  private remove(brandId: string): void {
    const previous: TotpBrandCacheRecord | undefined = this.records.get(brandId);
    if (previous === undefined) { return; }
    this.records.delete(brandId);
    previous.evicted = true;
    // A visible Image may still be using this PixelMap. Keep the native
    // object resident until the last lease releases it.
    if (previous.referenceCount === 0) { this.releaseRecord(previous); }
  }

  private releaseLease(record: TotpBrandCacheRecord): void {
    record.referenceCount = Math.max(0, record.referenceCount - 1);
    if (record.evicted && record.referenceCount === 0) {
      this.releaseRecord(record);
    }
  }

  private evict(): void {
    while (this.records.size > this.maxEntries ||
      this.bytes + this.reserved > this.maxBytes) {
      if (!this.evictOldest()) { break; }
    }
  }

  private evictOldest(): boolean {
    let oldestId: string = '';
    let oldestSequence: number = Number.MAX_SAFE_INTEGER;
    const ids: string[] = Array.from(this.records.keys());
    for (let index = 0; index < ids.length; index++) {
      const candidate: TotpBrandCacheRecord | undefined = this.records.get(ids[index]);
      if (candidate !== undefined && candidate.referenceCount === 0 &&
        candidate.lastUsedAt < oldestSequence) {
        oldestId = candidate.brandId;
        oldestSequence = candidate.lastUsedAt;
      }
    }
    if (oldestId === '') { return false; }
    this.remove(oldestId);
    return true;
  }
}

/** Process-local cache shared by visible KeyVault cards. */
export const TOTP_BRAND_CACHE: TotpBrandCache = new TotpBrandCache();
