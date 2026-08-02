import { expect } from '@ohos/hypium';
import { common } from '@kit.AbilityKit';
import { image } from '@kit.ImageKit';
import {
  auditedDescribe as describe,
  auditedIt as it
} from '../../../main/ets/services/FocusedTestRegistrationAudit';
import {
  configureTotpBrandResourceDecoder,
  decodeTotpBrandAsset,
  TOTP_BRAND_DECODE_MAX_BYTES
} from '../../../main/ets/services/TotpBrandResourceDecoder';
import {
  TOTP_BRAND_CACHE,
  TotpBrandAssetLease,
  TotpDecodedAsset
} from '../../../main/ets/services/TotpBrandCache';
import {
  totpBrandAvatarMode,
  totpBrandVisual
} from '../../../main/ets/services/TotpBrandService';

/** Counts cache ownership while delegating the actual PixelMap to ImageKit. */
class CountingRealDecodedAsset implements TotpDecodedAsset {
  readonly bytes: number;
  readonly pixelMap: image.PixelMap | undefined;
  private readonly delegate: TotpDecodedAsset;
  releaseCount: number = 0;

  constructor(delegate: TotpDecodedAsset) {
    this.delegate = delegate;
    this.bytes = delegate.bytes;
    this.pixelMap = delegate.pixelMap;
  }

  release(): void {
    if (this.releaseCount > 0) { return; }
    this.releaseCount = 1;
    this.delegate.release();
  }
}

class DecodeObservation {
  private value: CountingRealDecodedAsset | null = null;

  set(asset: CountingRealDecodedAsset): void {
    this.value = asset;
  }

  get(): CountingRealDecodedAsset | null {
    return this.value;
  }
}

function testContext(): common.UIAbilityContext {
  return getContext() as common.UIAbilityContext;
}

export default function totpBrandResourceIntegrationTest(): number {
  describe('TotpBrandResourceIntegration', (): void => {
    it('decodes_packaged_png_through_resource_manager_imagekit_and_cache', 0,
      async (): Promise<void> => {
        const context: common.UIAbilityContext = testContext();
        expect(context !== undefined).assertTrue();
        configureTotpBrandResourceDecoder(context);
        TOTP_BRAND_CACHE.clear();
        const visual = totpBrandVisual('GitHub', 'alice@example.com');
        expect(visual.localAsset).assertEqual('totp-brands/github.png');
        const observation = new DecodeObservation();
        let lease: TotpBrandAssetLease | null = null;
        try {
          lease = await TOTP_BRAND_CACHE.acquireOrDecode(
            visual.slug, visual.sha256, TOTP_BRAND_DECODE_MAX_BYTES,
            async (): Promise<TotpDecodedAsset | null> => {
              const decoded: TotpDecodedAsset | null = await decodeTotpBrandAsset(
                visual.localAsset);
              if (decoded === null) { return null; }
              const wrapped: CountingRealDecodedAsset = new CountingRealDecodedAsset(decoded);
              observation.set(wrapped);
              return wrapped;
            });
          const counted: CountingRealDecodedAsset | null = observation.get();
          expect(lease !== null).assertTrue();
          expect(counted !== null).assertTrue();
          if (lease === null || counted === null) { return; }
          expect(lease.asset.pixelMap !== undefined).assertTrue();
          expect(counted.pixelMap !== undefined).assertTrue();
          if (counted.pixelMap !== undefined) {
            const info: image.ImageInfo = await counted.pixelMap.getImageInfo();
            expect(info.size.width).assertEqual(42);
            expect(info.size.height).assertEqual(42);
          }
          expect(counted.bytes > 0 && counted.bytes <= TOTP_BRAND_DECODE_MAX_BYTES)
            .assertTrue();
          expect(TOTP_BRAND_CACHE.totalBytes() <= TOTP_BRAND_DECODE_MAX_BYTES).assertTrue();
          lease.release();
          lease.release();
          // The cache remains the owner of an un-evicted resident asset.
          expect(counted.releaseCount).assertEqual(0);
          TOTP_BRAND_CACHE.clear();
          expect(counted.releaseCount).assertEqual(1);
          lease = null;
        } finally {
          if (lease !== null) { lease.release(); }
          TOTP_BRAND_CACHE.clear();
        }
      });

    it('missing_rawfile_fails_to_initials_without_network_or_cache_ownership', 0,
      async (): Promise<void> => {
        const context: common.UIAbilityContext = testContext();
        expect(context !== undefined).assertTrue();
        configureTotpBrandResourceDecoder(context);
        TOTP_BRAND_CACHE.clear();
        try {
          const lease: TotpBrandAssetLease | null =
            await TOTP_BRAND_CACHE.acquireOrDecode(
              'missing-brand', 'missing-sha256', TOTP_BRAND_DECODE_MAX_BYTES,
              (): Promise<TotpDecodedAsset | null> =>
                decodeTotpBrandAsset('totp-brands/does-not-exist.svg'));
          expect(lease === null).assertTrue();
          expect(TOTP_BRAND_CACHE.entryCount()).assertEqual(0);
          expect(TOTP_BRAND_CACHE.totalBytes()).assertEqual(0);
          expect(TOTP_BRAND_CACHE.reservedBytes()).assertEqual(0);
          expect(totpBrandAvatarMode('totp-brands/github.svg', true))
            .assertEqual('initials');
        } finally {
          TOTP_BRAND_CACHE.clear();
        }
      });
  });
  return 2;
}
