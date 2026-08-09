import { common } from '@kit.AbilityKit';
import { image } from '@kit.ImageKit';
import { TotpDecodedAsset } from './TotpBrandCache';

export const TOTP_BRAND_DECODE_WIDTH: number = 42;
export const TOTP_BRAND_DECODE_HEIGHT: number = 42;
export const TOTP_BRAND_DECODE_MAX_BYTES: number =
  TOTP_BRAND_DECODE_WIDTH * TOTP_BRAND_DECODE_HEIGHT * 4;

export interface TotpBrandResourceDecoder {
  /** Maximum PixelMap bytes guaranteed by the fixed target-size decoder. */
  readonly maxDecodedBytes: number;
  decode(localAsset: string): Promise<TotpDecodedAsset | null>;
}

class HarmonyPixelMapAsset implements TotpDecodedAsset {
  readonly bytes: number;
  readonly pixelMap: image.PixelMap;
  private released: boolean = false;

  constructor(pixelMap: image.PixelMap, bytes: number) {
    this.pixelMap = pixelMap;
    this.bytes = Math.max(1, bytes);
  }

  release(): void {
    if (this.released) { return; }
    this.released = true;
    this.pixelMap.release().catch((): void => {
      // The cache has already dropped ownership; platform cleanup is best effort.
    });
  }
}

/**
 * Decodes packaged rawfiles through ResourceManager + ImageKit. The returned
 * PixelMap is the same object later supplied to the visible Image, so the
 * cache and UI do not maintain two decode paths. It never accepts a URL and
 * never performs network I/O.
 */
class HarmonyTotpBrandResourceDecoder implements TotpBrandResourceDecoder {
  private readonly context: common.UIAbilityContext;
  readonly maxDecodedBytes: number = TOTP_BRAND_DECODE_MAX_BYTES;

  constructor(context: common.UIAbilityContext) {
    this.context = context;
  }

  async decode(localAsset: string): Promise<TotpDecodedAsset | null> {
    if (!localAsset.startsWith('totp-brands/') || localAsset.indexOf('..') >= 0) {
      return null;
    }
    let source: image.ImageSource | null = null;
    let pixelMap: image.PixelMap | null = null;
    try {
      // Decode from the rawfile bytes.  The RawFileDescriptor overload is not
      // available on every API 23 image backend and silently makes all SVG
      // decodes fail, leaving the card stuck on initials.
      const content: Uint8Array =
        this.context.resourceManager.getRawFileContentSync(localAsset);
      const buffer: ArrayBuffer = content.buffer.slice(
        content.byteOffset, content.byteOffset + content.byteLength);
      source = image.createImageSource(buffer);
      pixelMap = await source.createPixelMap({
        desiredSize: {
          width: TOTP_BRAND_DECODE_WIDTH,
          height: TOTP_BRAND_DECODE_HEIGHT
        },
        // Fix the output representation as RGBA_8888 so the cache reservation
        // is a hard upper bound for the actual PixelMap stride as well as the
        // requested 42x42 dimensions.
        desiredPixelFormat: image.PixelMapFormat.RGBA_8888
      });
      const info = await pixelMap.getImageInfo();
      const bytes: number = Math.max(1, info.stride * info.size.height);
      // ResourceManager/ImageKit are treated as untrusted for budgeting: the
      // output must satisfy the same fixed dimensions used for reservation.
      if (info.size.width > TOTP_BRAND_DECODE_WIDTH ||
        info.size.height > TOTP_BRAND_DECODE_HEIGHT ||
        bytes > this.maxDecodedBytes) {
        throw new Error('totp_brand_decode_oversize');
      }
      const owned: HarmonyPixelMapAsset = new HarmonyPixelMapAsset(pixelMap, bytes);
      pixelMap = null;
      return owned;
    } catch (_error) {
      if (pixelMap !== null) {
        try { await pixelMap.release(); } catch (_releaseError) { /* ignore */ }
      }
      return null;
    } finally {
      if (source !== null) {
        try { await source.release(); } catch (_releaseError) { /* ignore */ }
      }
    }
  }
}

let configuredDecoder: TotpBrandResourceDecoder | null = null;

export function configureTotpBrandResourceDecoder(
  context: common.UIAbilityContext
): void {
  configuredDecoder = new HarmonyTotpBrandResourceDecoder(context);
}

export function setTotpBrandResourceDecoderForTest(
  decoder: TotpBrandResourceDecoder | null
): void {
  configuredDecoder = decoder;
}

export function decodeTotpBrandAsset(localAsset: string): Promise<TotpDecodedAsset | null> {
  if (configuredDecoder === null) { return Promise.resolve(null); }
  return configuredDecoder.decode(localAsset);
}
