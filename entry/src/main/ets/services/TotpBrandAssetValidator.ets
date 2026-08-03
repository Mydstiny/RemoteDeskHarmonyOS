import {
  TOTP_BRAND_ALIAS_TARGET,
  TOTP_BRAND_ASSET_TARGET,
  TOTP_BRAND_MANIFEST,
  TOTP_BRAND_MANIFEST_SOURCE_SHA256,
  TOTP_BRAND_MANIFEST_VERSION,
  TotpBrandManifestEntry
} from './TotpBrandManifest';
import {
  TOTP_BRAND_ASSET_REGISTRY_IDS,
  TOTP_BRAND_ASSET_REGISTRY_MANIFEST_VERSION,
  TOTP_BRAND_ASSET_REGISTRY_SOURCE_SHA256,
  totpBrandAssetPath
} from './TotpBrandAssetRegistry';
import {
  totpOfficialBrandAssetPath
} from './TotpBrandOfficialAssetRegistry';
import { totpContrastRatio, totpForegroundForBackground } from './TotpBrandResolver';

export interface TotpBrandCoverageGap {
  uniqueAssets: number;
  aliases: number;
  assetTarget: number;
  aliasTarget: number;
}

export interface TotpBrandManifestReport {
  version: string;
  errors: string[];
  uniqueAssetCount: number;
  aliasCount: number;
  domainCount: number;
  domainSemanticValid: boolean;
  coverageStatus: string;
  generatedArtifactsSynchronized: boolean;
  coverageGap: TotpBrandCoverageGap;
}

const SHA256_PATTERN: RegExp = /^[0-9a-f]{64}$/;
const COLOR_PATTERN: RegExp = /^#[0-9A-Fa-f]{6}$/;
const DOMAIN_PATTERN: RegExp = /^(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$/;

function normalize(value: string): string {
  let normalized: string = value.trim();
  try {
    normalized = normalized.normalize('NFKC');
  } catch (_error) {
    // Older API levels still have the exact ASCII fallback below.
  }
  return normalized.toLowerCase().replace(/[._-]+/g, ' ').replace(/\s+/g, ' ');
}

function hasText(value: string): boolean {
  return value.trim().length > 0;
}

function isHttpsUrl(value: string): boolean {
  return value.trim().startsWith('https://');
}

function count(values: string[], candidate: string): number {
  let result: number = 0;
  for (let index = 0; index < values.length; index++) {
    if (values[index] === candidate) { result++; }
  }
  return result;
}

function uniqueCount(values: string[]): number {
  const unique: string[] = [];
  for (let index = 0; index < values.length; index++) {
    if (unique.indexOf(values[index]) < 0) { unique.push(values[index]); }
  }
  return unique.length;
}

function isShort(value: string): boolean {
  const compact: string = value.replace(/\s+/g, '');
  if (compact === 'qq' || compact === 'b站') { return false; }
  if (compact.length >= 3) { return false; }
  if (compact.length >= 2) {
    let allCjk: boolean = true;
    for (let index = 0; index < compact.length; index++) {
      const code: number = compact.charCodeAt(index);
      if (code < 0x4E00 || code > 0x9FFF) {
        allCjk = false;
        break;
      }
    }
    if (allCjk) { return false; }
  }
  return true;
}

export function validateTotpBrandManifest(
  entries: TotpBrandManifestEntry[] = TOTP_BRAND_MANIFEST
): TotpBrandManifestReport {
  const errors: string[] = [];
  const brandIds: string[] = [];
  const assets: string[] = [];
  const exactKeys: string[] = [];
  let aliasCount: number = 0;
  let domainCount: number = 0;
  let domainSemanticErrorCount: number = 0;

  const registrySynchronized: boolean =
    entries.length === TOTP_BRAND_MANIFEST.length &&
    TOTP_BRAND_ASSET_REGISTRY_MANIFEST_VERSION === TOTP_BRAND_MANIFEST_VERSION &&
    TOTP_BRAND_ASSET_REGISTRY_SOURCE_SHA256 === TOTP_BRAND_MANIFEST_SOURCE_SHA256 &&
    TOTP_BRAND_ASSET_REGISTRY_IDS.length === TOTP_BRAND_MANIFEST.length;
  if (!registrySynchronized) {
    errors.push('generated manifest/registry source or entry count mismatch');
  }

  for (let index = 0; index < entries.length; index++) {
    const entry: TotpBrandManifestEntry = entries[index];
    const prefix: string = 'manifest[' + index.toString() + ']';
    const rawBrandId: string = entry.brandId.trim();
    const brandId: string = normalize(rawBrandId);
    const asset: string = entry.localAsset.trim();
    if (!hasText(brandId) || brandIds.indexOf(brandId) >= 0) {
      errors.push(prefix + '.brandId must be unique and non-empty');
    }
    brandIds.push(brandId);
    if (!hasText(entry.displayName)) { errors.push(prefix + '.displayName missing'); }
    if (!hasText(asset) || !asset.startsWith('totp-brands/') ||
      (!asset.endsWith('.svg') && !asset.endsWith('.png')) ||
      asset.indexOf('..') >= 0) {
      errors.push(prefix + '.localAsset must be a safe packaged image path');
    }
    if (assets.indexOf(asset) >= 0) { errors.push(prefix + '.localAsset duplicated'); }
    assets.push(asset);
    if (entry.assetBytes <= 0) { errors.push(prefix + '.assetBytes must be positive'); }

    for (let aliasIndex = 0; aliasIndex < entry.aliases.length; aliasIndex++) {
      const alias: string = normalize(entry.aliases[aliasIndex]);
      if (!hasText(alias) || isShort(alias)) {
        errors.push(prefix + '.aliases contains unsafe short alias');
      }
      if (exactKeys.indexOf(alias) >= 0) {
        errors.push(prefix + '.alias duplicated or ambiguous: ' + alias);
      } else {
        exactKeys.push(alias);
        aliasCount++;
      }
    }
    for (let domainIndex = 0; domainIndex < entry.exactDomains.length; domainIndex++) {
      const rawDomain: string = entry.exactDomains[domainIndex].trim().toLowerCase().replace(/\.$/, '');
      const domain: string = normalize(rawDomain);
      domainCount++;
      if (!hasText(domain) || isShort(domain) || !DOMAIN_PATTERN.test(rawDomain)) {
        errors.push(prefix + '.exactDomains contains unsafe short value');
        domainSemanticErrorCount++;
      }
      if (exactKeys.indexOf(domain) >= 0) {
        errors.push(prefix + '.alias/domain duplicated or ambiguous: ' + domain);
        domainSemanticErrorCount++;
      } else {
        exactKeys.push(domain);
        aliasCount++;
      }
    }

    if (entry.sourceType !== 'simple-icons') { errors.push(prefix + '.sourceType unsupported'); }
    if (!isHttpsUrl(entry.sourceUrl) || !isHttpsUrl(entry.brandSourceUrl) ||
      !isHttpsUrl(entry.brandGuidelines) || entry.upstreamVersion !== '16.21.0') {
      errors.push(prefix + '.source provenance incomplete');
    }
    if (!SHA256_PATTERN.test(entry.sha256)) { errors.push(prefix + '.sha256 invalid'); }
    if (entry.licenseType !== 'CC0-1.0' || !isHttpsUrl(entry.licenseUrl)) {
      errors.push(prefix + '.license provenance incomplete');
    }
    if (!hasText(entry.trademarkGuidelines)) { errors.push(prefix + '.trademarkGuidelines missing'); }
    if (entry.officialAssetVerified) {
      errors.push(prefix + '.officialAssetVerified must remain false for Simple Icons');
    }
    if (entry.aliasReviewed !== true || !isHttpsUrl(entry.aliasSourceUrl) ||
      entry.aliasSourceUrl.indexOf('/data/simple-icons.json') < 0 ||
      !hasText(entry.aliasEvidence)) {
      errors.push(prefix + '.alias provenance incomplete');
    }
    const domainSource: string = entry.domainSourceUrl.trim();
    const domainEvidence: string = entry.domainEvidence.trim();
    if (entry.domainReviewed !== true || !isHttpsUrl(domainSource) ||
      !hasText(domainEvidence)) {
      errors.push(prefix + '.domain review provenance incomplete');
      domainSemanticErrorCount++;
    }
    if (entry.exactDomains.length > 0) {
      if (domainSource === entry.sourceUrl || domainSource === entry.brandSourceUrl ||
        domainSource.indexOf('raw.githubusercontent.com') >= 0 ||
        domainSource.indexOf('simpleicons.org') >= 0 ||
        domainSource.indexOf('commons.wikimedia.org') >= 0 ||
        domainEvidence.toLowerCase().indexOf('intentionally empty') >= 0) {
        errors.push(prefix + '.exact login domains must have independent official evidence');
        domainSemanticErrorCount++;
      }
    } else if (domainEvidence.toLowerCase().indexOf('intentionally empty') < 0) {
      errors.push(prefix + '.empty exactDomains must document intentional absence of evidence');
      domainSemanticErrorCount++;
    }
    if (!COLOR_PATTERN.test(entry.brandColor)) {
      errors.push(prefix + '.color metadata incomplete');
    } else {
      const foreground: string = totpForegroundForBackground(entry.brandColor);
      if (totpContrastRatio(foreground, entry.brandColor) < 4.5) {
        errors.push(prefix + '.brandColor has insufficient WCAG contrast');
      }
    }

    // Registry identity is a generated machine key.  Display alias
    // normalization intentionally folds '_' to a space, so it must not be
    // used for IDs such as uniqlo_ja.
    if (count(TOTP_BRAND_ASSET_REGISTRY_IDS, rawBrandId) !== 1) {
      errors.push(prefix + '.registry brandId mapping must be unique');
    }
    if (TOTP_BRAND_ASSET_REGISTRY_IDS[index] !== rawBrandId) {
      errors.push(prefix + '.registry brandId order mismatch');
    }
    const officialAsset: string = totpOfficialBrandAssetPath(rawBrandId);
    const expectedRegistryAsset: string = officialAsset !== '' ? officialAsset : asset;
    if (totpBrandAssetPath(rawBrandId) !== expectedRegistryAsset) {
      errors.push(prefix + '.registry asset path mismatch');
    }
  }

  const uniqueAssetCount: number = uniqueCount(assets);
  const generatedArtifactsSynchronized: boolean = registrySynchronized && errors.length === 0;
  const domainSemanticValid: boolean = domainSemanticErrorCount === 0;
  const aliasGap: number = Math.max(0, TOTP_BRAND_ALIAS_TARGET - aliasCount);
  const assetGap: number = Math.max(0, TOTP_BRAND_ASSET_TARGET - uniqueAssetCount);
  return {
    version: TOTP_BRAND_MANIFEST_VERSION,
    errors,
    uniqueAssetCount,
    aliasCount,
    domainCount,
    domainSemanticValid,
    coverageStatus: domainSemanticValid && (aliasGap > 0 || assetGap > 0)
      ? 'domain semantics pass; quantity gap'
      : domainSemanticValid ? 'domain semantics pass; quantity target met' : 'domain semantics fail',
    generatedArtifactsSynchronized,
    coverageGap: {
      uniqueAssets: assetGap,
      aliases: aliasGap,
      assetTarget: TOTP_BRAND_ASSET_TARGET,
      aliasTarget: TOTP_BRAND_ALIAS_TARGET
    }
  };
}
