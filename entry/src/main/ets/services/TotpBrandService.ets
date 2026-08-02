/**
 * Public TOTP brand facade.
 *
 * Local assets are the only default visual source. The optional URL helper is
 * retained for an explicit, future opt-in path and is never used by the card.
 */
import { TotpBrandResolution, resolveTotpBrand as resolveBrand,
  resolveTotpBrandForEntry as resolveBrandForEntry,
  pinnedTotpBrandLogoUrl } from './TotpBrandResolver';
import { TotpEntry } from '../model/TotpEntry';

export interface TotpBrandVisual {
  slug: string;
  background: string;
  foreground: string;
  localAsset: string;
  sha256: string;
  localAssetBytes: number;
  initials: string;
  avatarMode: 'local' | 'initials';
}

export {
  resolveTotpBrand,
  resolveTotpBrandForEntry,
  totpBrandAvatarMode,
  totpContrastRatio,
  totpForegroundForBackground,
  totpInitialOf,
  totpRelativeLuminance
} from './TotpBrandResolver';

export function totpBrandVisual(issuer: string, account: string): TotpBrandVisual {
  const resolution: TotpBrandResolution = resolveBrand(issuer, account);
  return {
    slug: resolution.brandId,
    background: resolution.background,
    foreground: resolution.foreground,
    localAsset: resolution.localAsset,
    sha256: resolution.sha256,
    localAssetBytes: resolution.localAssetBytes,
    initials: resolution.initials,
    avatarMode: resolution.avatarMode
  };
}

export function totpBrandVisualForEntry(
  entry: TotpEntry,
  globalMode: 'logo' | 'initials' = 'logo'
): TotpBrandVisual {
  const resolution: TotpBrandResolution = resolveBrandForEntry(
    entry, globalMode === 'initials' ? 'initials' : 'logo');
  return {
    slug: resolution.brandId,
    background: resolution.background,
    foreground: resolution.foreground,
    localAsset: resolution.localAsset,
    sha256: resolution.sha256,
    localAssetBytes: resolution.localAssetBytes,
    initials: resolution.initials,
    avatarMode: resolution.avatarMode
  };
}

export function totpBrandLogoUrl(
  issuer: string,
  account: string,
  allowRemoteFallback: boolean = false
): string {
  return allowRemoteFallback ? pinnedTotpBrandLogoUrl(issuer, account) : '';
}
