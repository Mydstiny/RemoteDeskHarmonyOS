/**
 * TOTP brand avatar contract tests.
 *
 * These tests are intentionally added before the implementation. They freeze
 * the privacy, exact-match, fallback, manifest, and page-ticker contracts.
 */
import { expect } from '@ohos/hypium';
import {
  auditedDescribe as describe,
  auditedIt as it
} from '../main/ets/services/FocusedTestRegistrationAudit';
import {
  resolveTotpBrand,
  resolveTotpBrandForEntry,
  totpBrandAvatarMode,
  totpBrandLogoUrl,
  totpBrandVisualForEntry,
  totpContrastRatio,
  totpForegroundForBackground,
  totpInitialOf
} from '../main/ets/services/TotpBrandService';
import {
  TOTP_BRAND_MANIFEST,
  TOTP_BRAND_MANIFEST_SOURCE_SHA256,
  TOTP_BRAND_MANIFEST_VERSION
} from '../main/ets/services/TotpBrandManifest';
import {
  TOTP_BRAND_ASSET_REGISTRY_MANIFEST_VERSION,
  TOTP_BRAND_ASSET_REGISTRY_SOURCE_SHA256
} from '../main/ets/services/TotpBrandAssetRegistry';
import { validateTotpBrandManifest } from '../main/ets/services/TotpBrandAssetValidator';
import {
  shouldRunTotpBrandTicker,
  TotpBrandTicker,
  TotpBrandTickerClock
} from '../main/ets/services/TotpBrandTicker';
import {
  TotpBrandAvatarState,
  totpBrandAssetVisibility
} from '../main/ets/services/TotpBrandAvatarState';
import { TotpBrandCache } from '../main/ets/services/TotpBrandCache';
import { TotpDecodedAsset } from '../main/ets/services/TotpBrandCache';
import { TotpEntry } from '../main/ets/model/TotpEntry';
import {
  cloudTableColumns,
  projectLocalRow
} from '../main/ets/services/CloudTableAdapter';
import { localBackupColumnsForTable } from '../main/ets/services/LocalBackupPolicy';

class FakeDecodedBrandAsset implements TotpDecodedAsset {
  readonly bytes: number;
  releaseCount: number = 0;

  constructor(bytes: number) {
    this.bytes = bytes;
  }

  release(): void {
    this.releaseCount++;
  }
}

class DeferredBrandDecode {
  private resolver: ((asset: TotpDecodedAsset | null) => void) | null = null;
  readonly promise: Promise<TotpDecodedAsset | null>;

  constructor() {
    this.promise = new Promise<TotpDecodedAsset | null>((resolve): void => {
      this.resolver = resolve;
    });
  }

  resolve(asset: TotpDecodedAsset | null): void {
    if (this.resolver !== null) {
      this.resolver(asset);
      this.resolver = null;
    }
  }
}

class FakeBrandTickerClock implements TotpBrandTickerClock {
  createCount: number = 0;
  cancelCount: number = 0;
  lastPeriodMs: number = 0;
  private nextId: number = 1;
  private callback: (() => void) | null = null;

  every(periodMs: number, callback: () => void): number {
    this.createCount++;
    this.lastPeriodMs = periodMs;
    this.callback = callback;
    return this.nextId++;
  }

  cancel(_timerId: number): void {
    this.cancelCount++;
    this.callback = null;
  }

  fire(): void {
    if (this.callback !== null) {
      this.callback();
    }
  }
}

export default function totpBrandServiceTest(): number {
  // Keep the brand suite behind one exact class name so the focused runner
  // cannot silently select none of its nested resolver/cache/ticker cases.
  describe('TotpBrandService', (): void => {
  describe('TotpBrandResolver_exact_matching', (): void => {
    it('does_not_map_duo_to_duolingo', 0, (): void => {
      expect(resolveTotpBrand('Duo', 'alice@example.com').brandId).assertEqual('');
      expect(resolveTotpBrand('Duo Security', 'alice@example.com').brandId).assertEqual('');
    });

    it('does_not_use_short_alias_substring_matching', 0, (): void => {
      expect(resolveTotpBrand('X Corporation', 'alice@example.com').brandId).assertEqual('');
      expect(resolveTotpBrand('JD Logistics', 'alice@example.com').brandId).assertEqual('');
      expect(resolveTotpBrand('QQ Enterprise Account', 'alice@example.com').brandId).assertEqual('');
      expect(resolveTotpBrand('GitHub', 'alice@example.com').brandId).assertEqual('github');
      expect(resolveTotpBrand('', 'alice@github.com').brandId).assertEqual('github');
      expect(resolveTotpBrand('', 'alice@notgithub.com').brandId).assertEqual('');
    });

    it('keeps_opentofu_and_terraform_as_separate_reviewed_brands', 0, (): void => {
      expect(resolveTotpBrand('OpenTofu', '').brandId).assertEqual('opentofu');
      expect(resolveTotpBrand('OpenTF', '').brandId).assertEqual('opentofu');
      expect(resolveTotpBrand('Terraform', '').brandId).assertEqual('terraform');
    });

    it('uses_only_reviewed_exact_login_domains', 0, (): void => {
      expect(resolveTotpBrand('', 'alice@gmail.com').brandId).assertEqual('google');
      expect(resolveTotpBrand('', 'alice@google.com').brandId).assertEqual('google');
      expect(resolveTotpBrand('', '  alice@GOOGLE.COM  ').brandId).assertEqual('google');
      expect(resolveTotpBrand('', 'alice@cloud.google.com').brandId).assertEqual('googlecloud');
      expect(resolveTotpBrand('', 'alice@apple.com').brandId).assertEqual('apple');
      expect(resolveTotpBrand('', 'alice@icloud.com').brandId).assertEqual('icloud');
      expect(resolveTotpBrand('', 'alice@google-com').brandId).assertEqual('');
      expect(resolveTotpBrand('', 'alice@google_com').brandId).assertEqual('');
      expect(resolveTotpBrand('', 'alice@notgoogle.com').brandId).assertEqual('');
      expect(resolveTotpBrand('', 'alice@google.com.evil').brandId).assertEqual('');
      expect(resolveTotpBrand('', 'alice@sub.google.com').brandId).assertEqual('');
      expect(resolveTotpBrand('', 'alice@sub.cloud.google.com').brandId).assertEqual('');
      expect(resolveTotpBrand('', 'alice@google.com.').brandId).assertEqual('');
      expect(resolveTotpBrand('', 'alice@commons.wikimedia.org').brandId).assertEqual('');
      expect(resolveTotpBrand('', 'alice@partnermarketinghub.withgoogle.com').brandId).assertEqual('');
      expect(resolveTotpBrand('', 'alice@googleusercontent.com').brandId).assertEqual('');
    });
  });

  describe('TotpBrandAvatar_fallback_and_privacy', (): void => {
    it('keeps_unknown_issuer_on_initials_without_a_blank_frame', 0, (): void => {
      expect(totpBrandAvatarMode('', false)).assertEqual('initials');
      expect(totpBrandAvatarMode('totp-brands/github.svg', true)).assertEqual('initials');
      expect(totpInitialOf('unknown issuer')).assertEqual('U');
    });

    it('does_not_request_network_by_default', 0, (): void => {
      expect(totpBrandLogoUrl('GitHub', 'alice@example.com')).assertEqual('');
      expect(totpBrandLogoUrl('GitHub', 'alice@example.com', true).indexOf(
        'simple-icons@16.21.0') >= 0).assertTrue();
    });

    it('waits_for_current_asset_ready_and_rejects_stale_callbacks', 0, (): void => {
      const state = new TotpBrandAvatarState();
      const first = state.begin('entry-a', 'github');
      expect(totpBrandAssetVisibility(state.snapshot(), true)).assertEqual('initials');
      expect(state.onComplete(first)).assertTrue();
      expect(totpBrandAssetVisibility(state.snapshot(), true)).assertEqual('asset');

      const second = state.begin('entry-b', 'google');
      expect(totpBrandAssetVisibility(state.snapshot(), true)).assertEqual('initials');
      expect(state.onComplete(first)).assertFalse();
      expect(totpBrandAssetVisibility(state.snapshot(), true)).assertEqual('initials');
      expect(state.onError(second)).assertTrue();
      expect(totpBrandAssetVisibility(state.snapshot(), true)).assertEqual('initials');
      state.invalidate();
      expect(state.onComplete(second)).assertFalse();
      expect(totpBrandAssetVisibility(state.snapshot(), true)).assertEqual('initials');
    });

    it('chooses_wcag_black_or_white_for_every_manifest_background', 0, (): void => {
      for (let index = 0; index < TOTP_BRAND_MANIFEST.length; index++) {
        const color = TOTP_BRAND_MANIFEST[index].brandColor;
        const foreground = totpForegroundForBackground(color);
        expect(foreground === '#000000' || foreground === '#FFFFFF').assertTrue();
        expect(totpContrastRatio(foreground, color) >= 4.5).assertTrue();
      }
    });

    it('derives_brand_locally_and_keeps_fixed_persistence_schema', 0, (): void => {
      const entry = new TotpEntry();
      entry.id = 'entry-local-derived';
      entry.issuer = 'GitHub';
      entry.account = 'alice@example.com';
      const derived = resolveTotpBrandForEntry(entry);
      expect(derived.brandId).assertEqual('github');
      expect(derived.avatarMode).assertEqual('local');
      expect(totpBrandVisualForEntry(entry).slug).assertEqual('github');

      const serialized: string = JSON.stringify(entry.toJSON());
      expect(serialized.indexOf('"brandId"') < 0).assertTrue();
      expect(serialized.indexOf('"avatarMode"') < 0).assertTrue();

      const restored = TotpEntry.fromJSON({
        id: 'legacy-row', userId: 'owner-a', issuer: 'GitHub', account: 'alice@example.com',
        secret: 'secret', algorithm: 0, digits: 6, period: 30, iconUrl: '', locked: false,
        lockType: 0, createdAt: 1, syncVersion: 1
      });
      expect(resolveTotpBrandForEntry(restored).brandId).assertEqual('github');

      const cloudColumns = cloudTableColumns('totpentries');
      const backupColumns = localBackupColumnsForTable('totpentries');
      const fixedColumns: string[] = [
        'id', 'userid', 'issuer', 'account', 'secret', 'algorithm', 'digits', 'period', 'iconurl',
        'locked', 'locktype', 'syncversion', 'createdat', 'updatedat'
      ];
      expect(cloudColumns.length).assertEqual(fixedColumns.length);
      expect(backupColumns.length).assertEqual(fixedColumns.length);
      for (let index = 0; index < fixedColumns.length; index++) {
        expect(cloudColumns[index]).assertEqual(fixedColumns[index]);
        expect(backupColumns[index]).assertEqual(fixedColumns[index]);
      }
      expect(cloudColumns.indexOf('brandid') < 0).assertTrue();
      expect(cloudColumns.indexOf('avatarmode') < 0).assertTrue();
      expect(backupColumns.indexOf('brandid') < 0).assertTrue();
      expect(backupColumns.indexOf('avatarmode') < 0).assertTrue();

      const localRow: Record<string, string> = {} as Record<string, string>;
      localRow['id'] = 'legacy-row';
      localRow['issuer'] = 'GitHub';
      localRow['account'] = 'alice@example.com';
      localRow['brandid'] = 'github';
      localRow['avatarmode'] = 'initials';
      const uploaded = projectLocalRow('totpentries', localRow);
      expect(uploaded['brandid'] === undefined).assertTrue();
      expect(uploaded['avatarmode'] === undefined).assertTrue();
    });
  });

  describe('TotpBrandCache_bounded_pixelmap_ownership', (): void => {
    it('evicts_lru_and_releases_decoded_assets_within_budget', 0, (): void => {
      const cache = new TotpBrandCache(2, 120);
      const a = new FakeDecodedBrandAsset(60);
      const b = new FakeDecodedBrandAsset(60);
      const c = new FakeDecodedBrandAsset(60);
      expect(cache.putReady('a', 'hash-a', a, 1)).assertTrue();
      expect(cache.putReady('b', 'hash-b', b, 2)).assertTrue();
      expect(cache.get('a', 'hash-a') !== null).assertTrue();
      const leaseA = cache.acquire('a', 'hash-a');
      expect(leaseA !== null).assertTrue();
      if (leaseA !== null) { expect(leaseA.asset === a).assertTrue(); }
      expect(cache.putReady('c', 'hash-c', c, 3)).assertTrue();
      expect(cache.get('a', 'hash-a') !== null).assertTrue();
      expect(cache.get('b', 'hash-b') === null).assertTrue();
      expect(b.releaseCount).assertEqual(1);
      expect(a.releaseCount).assertEqual(0);
      expect(cache.storesPixelMap()).assertTrue();
      expect(cache.totalBytes() <= 120).assertTrue();
      expect(cache.peakBytes() <= 120).assertTrue();
      cache.clear();
      // Clear evicts the record but cannot release a PixelMap held by the
      // visible card until its lease is returned.
      expect(a.releaseCount).assertEqual(0);
      expect(c.releaseCount).assertEqual(1);
      if (leaseA !== null) { leaseA.release(); leaseA.release(); }
      expect(a.releaseCount).assertEqual(1);
      expect(cache.totalBytes()).assertEqual(0);
    });

    it('keeps_evicted_pixelmap_alive_for_multiple_visible_leases', 0, (): void => {
      const cache = new TotpBrandCache(2, 120);
      const a = new FakeDecodedBrandAsset(60);
      const b = new FakeDecodedBrandAsset(60);
      const c = new FakeDecodedBrandAsset(60);
      expect(cache.putReady('a', 'hash-a', a)).assertTrue();
      expect(cache.putReady('b', 'hash-b', b)).assertTrue();
      const firstLease = cache.acquire('b', 'hash-b');
      const secondLease = cache.acquire('b', 'hash-b');
      expect(firstLease !== null && secondLease !== null).assertTrue();
      expect(cache.putReady('c', 'hash-c', c)).assertTrue();
      expect(cache.get('a', 'hash-a') === null).assertTrue();
      expect(b.releaseCount).assertEqual(0);
      cache.clear();
      expect(b.releaseCount).assertEqual(0);
      if (firstLease !== null) { firstLease.release(); }
      expect(b.releaseCount).assertEqual(0);
      if (secondLease !== null) { secondLease.release(); }
      expect(b.releaseCount).assertEqual(1);
      expect(c.releaseCount).assertEqual(1);
      expect(cache.totalBytes()).assertEqual(0);
    });

    it('releases_an_oversize_decode_instead_of_exceeding_8mb', 0, (): void => {
      const cache = new TotpBrandCache(64, 8 * 1024 * 1024);
      const oversized = new FakeDecodedBrandAsset(8 * 1024 * 1024 + 1);
      expect(cache.putReady('oversized', 'hash', oversized)).assertFalse();
      expect(oversized.releaseCount).assertEqual(1);
      expect(cache.totalBytes()).assertEqual(0);
    });

    it('does_not_exceed_budget_when_all_existing_pixelmaps_are_leased', 0, (): void => {
      const cache = new TotpBrandCache(2, 60);
      const active = new FakeDecodedBrandAsset(60);
      const rejected = new FakeDecodedBrandAsset(1);
      expect(cache.putReady('active', 'hash-active', active)).assertTrue();
      const lease = cache.acquire('active', 'hash-active');
      expect(lease !== null).assertTrue();
      expect(cache.putReady('rejected', 'hash-rejected', rejected)).assertFalse();
      expect(rejected.releaseCount).assertEqual(1);
      expect(cache.totalBytes() <= 60).assertTrue();
      expect(cache.reservedBytes()).assertEqual(0);
      expect(cache.peakBytes() <= 60).assertTrue();
      expect(cache.entryCount()).assertEqual(1);
      const replacement = new FakeDecodedBrandAsset(1);
      expect(cache.putReady('active', 'hash-replacement', replacement)).assertFalse();
      expect(cache.get('active', 'hash-active') !== null).assertTrue();
      expect(replacement.releaseCount).assertEqual(1);
      expect(active.releaseCount).assertEqual(0);
      if (lease !== null) { lease.release(); }
      // Releasing the visible lease does not evict a still-resident LRU entry;
      // the cache remains its owner until an explicit clear/eviction.
      expect(active.releaseCount).assertEqual(0);
      cache.clear();
      expect(active.releaseCount).assertEqual(1);
    });

    it('coalesces_same_key_decode_and_returns_one_lease_per_consumer', 0,
      async (): Promise<void> => {
        const cache = new TotpBrandCache(4, 120);
        const deferred = new DeferredBrandDecode();
        let decodeCount: number = 0;
        const firstPromise = cache.acquireOrDecode(
          'github', 'hash-github', 60, (): Promise<TotpDecodedAsset | null> => {
            decodeCount++;
            return deferred.promise;
          });
        const secondPromise = cache.acquireOrDecode(
          'github', 'hash-github', 60, (): Promise<TotpDecodedAsset | null> => {
            decodeCount++;
            return Promise.resolve(new FakeDecodedBrandAsset(40));
          });
        expect(decodeCount).assertEqual(1);
        expect(cache.reservedBytes()).assertEqual(60);
        const decoded = new FakeDecodedBrandAsset(40);
        deferred.resolve(decoded);
        const first = await firstPromise;
        const second = await secondPromise;
        expect(first !== null && second !== null).assertTrue();
        expect(cache.totalBytes()).assertEqual(40);
        expect(cache.reservedBytes()).assertEqual(0);
        if (first !== null) { first.release(); }
        if (second !== null) { second.release(); }
        expect(decoded.releaseCount).assertEqual(0);
        cache.clear();
        expect(decoded.releaseCount).assertEqual(1);
      });

    it('reserves_hard_budget_across_different_inflight_keys', 0,
      async (): Promise<void> => {
        const cache = new TotpBrandCache(4, 100);
        const firstDecode = new DeferredBrandDecode();
        let secondStarted: boolean = false;
        const firstPromise = cache.acquireOrDecode(
          'github', 'hash-github', 70, (): Promise<TotpDecodedAsset | null> =>
            firstDecode.promise);
        const secondPromise = cache.acquireOrDecode(
          'google', 'hash-google', 40, (): Promise<TotpDecodedAsset | null> => {
            secondStarted = true;
            return Promise.resolve(new FakeDecodedBrandAsset(20));
          });
        expect(secondStarted).assertFalse();
        expect(await secondPromise === null).assertTrue();
        expect(cache.reservedBytes()).assertEqual(70);
        firstDecode.resolve(new FakeDecodedBrandAsset(60));
        const first = await firstPromise;
        expect(first !== null).assertTrue();
        if (first !== null) { first.release(); }
        cache.clear();
        expect(cache.reservedBytes()).assertEqual(0);
      });

    it('returns_reservation_on_decode_failure', 0, async (): Promise<void> => {
      const cache = new TotpBrandCache(4, 100);
      const result = await cache.acquireOrDecode(
        'failed', 'hash-failed', 60,
        (): Promise<TotpDecodedAsset | null> => Promise.resolve(null));
      expect(result === null).assertTrue();
      expect(cache.reservedBytes()).assertEqual(0);
      expect(cache.totalBytes()).assertEqual(0);
    });

    it('stale_consumer_can_release_its_lease_without_releasing_shared_asset', 0,
      async (): Promise<void> => {
        const cache = new TotpBrandCache(4, 100);
        const deferred = new DeferredBrandDecode();
        const firstPromise = cache.acquireOrDecode(
          'stale', 'hash-stale', 60, (): Promise<TotpDecodedAsset | null> =>
            deferred.promise);
        const secondPromise = cache.acquireOrDecode(
          'stale', 'hash-stale', 60, (): Promise<TotpDecodedAsset | null> =>
            Promise.resolve(null));
        const decoded = new FakeDecodedBrandAsset(50);
        deferred.resolve(decoded);
        const first = await firstPromise;
        const second = await secondPromise;
        expect(first !== null && second !== null).assertTrue();
        if (first !== null) { first.release(); }
        expect(decoded.releaseCount).assertEqual(0);
        if (second !== null) { second.release(); }
        cache.clear();
        expect(decoded.releaseCount).assertEqual(1);
      });

    it('clear_during_inflight_cancels_reservation_and_releases_late_decode', 0,
      async (): Promise<void> => {
        const cache = new TotpBrandCache(4, 100);
        const deferred = new DeferredBrandDecode();
        const promise = cache.acquireOrDecode(
          'cleared', 'hash-cleared', 80, (): Promise<TotpDecodedAsset | null> =>
            deferred.promise);
        expect(cache.reservedBytes()).assertEqual(80);
        cache.clear();
        expect(cache.reservedBytes()).assertEqual(0);
        const decoded = new FakeDecodedBrandAsset(40);
        deferred.resolve(decoded);
        expect(await promise === null).assertTrue();
        expect(decoded.releaseCount).assertEqual(1);
        expect(cache.entryCount()).assertEqual(0);
      });

    it('rejects_actual_decode_larger_than_reserved_or_budget', 0,
      async (): Promise<void> => {
        const cache = new TotpBrandCache(4, 60);
        const result = await cache.acquireOrDecode(
          'oversized-inflight', 'hash-oversized', 60,
          (): Promise<TotpDecodedAsset | null> =>
            Promise.resolve(new FakeDecodedBrandAsset(61)));
        expect(result === null).assertTrue();
        expect(cache.reservedBytes()).assertEqual(0);
        expect(cache.totalBytes()).assertEqual(0);
      });
  });

  describe('TotpBrandManifest_provenance', (): void => {
    it('has_complete_provenance_for_the_representative_local_batch', 0, (): void => {
      const report = validateTotpBrandManifest();
      expect(report.errors.length).assertEqual(0);
      // The machine ID contains an underscore; display normalization must not
      // change the generated registry identity or its asset path.
      expect(resolveTotpBrand('Uniqlo', '').brandId).assertEqual('uniqlo_ja');
      expect(report.version).assertEqual(TOTP_BRAND_MANIFEST_VERSION);
      expect(report.uniqueAssetCount >= 250).assertTrue();
      expect(report.coverageGap.uniqueAssets).assertEqual(0);
      expect(report.domainSemanticValid).assertTrue();
      expect(report.coverageStatus).assertEqual('domain semantics pass; quantity gap');
      expect(report.domainCount > 0).assertTrue();
      expect(report.aliasCount < 500).assertTrue();
      expect(report.coverageGap.aliases).assertEqual(193);
      expect(TOTP_BRAND_ASSET_REGISTRY_MANIFEST_VERSION).assertEqual(TOTP_BRAND_MANIFEST_VERSION);
      expect(TOTP_BRAND_ASSET_REGISTRY_SOURCE_SHA256).assertEqual(TOTP_BRAND_MANIFEST_SOURCE_SHA256);
      expect(TOTP_BRAND_MANIFEST_SOURCE_SHA256.length).assertEqual(64);
      expect(report.generatedArtifactsSynchronized).assertTrue();
    });

    it('keeps_brand_resolution_local_for_legacy_rows', 0, (): void => {
      const legacy = TotpEntry.fromJSON({
        id: 'legacy-github', userId: 'owner-a', issuer: '', account: 'alice@github.com',
        secret: 'secret', algorithm: 0, digits: 6, period: 30, iconUrl: '', locked: false,
        lockType: 0, createdAt: 1, syncVersion: 1
      });
      expect(resolveTotpBrandForEntry(legacy).brandId).assertEqual('github');
      expect(resolveTotpBrandForEntry(legacy, 'initials').avatarMode).assertEqual('initials');
    });
  });

  describe('TotpBrandTicker_page_scope', (): void => {
    it('uses_one_1hz_timer_for_multiple_cards', 0, (): void => {
      const clock = new FakeBrandTickerClock();
      const ticker = new TotpBrandTicker(clock);
      let firstTicks: number = 0;
      let secondTicks: number = 0;
      const removeFirst = ticker.subscribe((): void => { firstTicks++; });
      const removeSecond = ticker.subscribe((): void => { secondTicks++; });

      expect(clock.createCount).assertEqual(1);
      expect(clock.lastPeriodMs).assertEqual(1000);
      expect(ticker.subscriberCount()).assertEqual(2);
      clock.fire();
      expect(firstTicks).assertEqual(1);
      expect(secondTicks).assertEqual(1);

      removeFirst();
      expect(clock.cancelCount).assertEqual(0);
      removeSecond();
      expect(clock.cancelCount).assertEqual(1);
      expect(shouldRunTotpBrandTicker(false, false, false)).assertTrue();
      expect(shouldRunTotpBrandTicker(true, false, false)).assertFalse();
      expect(shouldRunTotpBrandTicker(false, true, false)).assertFalse();
      expect(shouldRunTotpBrandTicker(false, false, true)).assertFalse();
    });
  });
  });
  return 22;
}
