import { TOTP_BRAND_MANIFEST, TotpBrandManifestEntry } from './TotpBrandManifest';
import { TotpAvatarMode, TotpEntry } from '../model/TotpEntry';

export type TotpBrandAvatarMode = 'local' | 'initials';

export interface TotpBrandResolution {
  brandId: string;
  displayName: string;
  localAsset: string;
  localAssetBytes: number;
  sha256: string;
  sourceType: string;
  background: string;
  foreground: string;
  initials: string;
  avatarMode: TotpBrandAvatarMode;
}

const FALLBACK_COLORS: string[] = [
  '#1F3A5F', '#234E52', '#3B2F63', '#5A2A3A',
  '#304B36', '#4A3B25', '#263238', '#3A3F5C'
];

function normalizeUnicode(value: string): string {
  let normalized: string = value.trim();
  try {
    normalized = normalized.normalize('NFKC');
  } catch (_error) {
    // API 23 runtime fallback: ordinary lower-case/spacing still applies.
  }
  return normalized.toLowerCase();
}

/**
 * Issuer aliases are reviewed display text, so their explicit punctuation
 * folding remains intentional.  This helper must never be used for domains.
 */
function normalizeAlias(value: string): string {
  return normalizeUnicode(value).replace(/[._-]+/g, ' ').replace(/\s+/g, ' ');
}

/**
 * Manifest domains are exact ASCII/IDNA A-labels.  We accept surrounding
 * account-field whitespace and case differences, but no trailing dot,
 * punctuation folding, suffix matching, or Unicode-to-ASCII guessing.
 */
function normalizeVerifiedDomain(value: string): string {
  const normalized: string = value.trim().toLowerCase();
  if (normalized.length === 0 || normalized.endsWith('.')) { return ''; }
  if (/[^\x00-\x7F]/.test(normalized)) { return ''; }
  const labels: string[] = normalized.split('.');
  if (labels.length === 0) { return ''; }
  for (let index = 0; index < labels.length; index++) {
    const label: string = labels[index];
    if (label.length === 0 || label.length > 63 ||
      !/^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$/.test(label)) {
      return '';
    }
  }
  return normalized;
}

function accountDomain(account: string): string {
  const at: number = account.lastIndexOf('@');
  if (at < 0 || at + 1 >= account.length) { return ''; }
  return normalizeVerifiedDomain(account.substring(at + 1));
}

function findEntry(
  issuer: string,
  account: string
): TotpBrandManifestEntry | null {
  const issuerKey: string = normalizeAlias(issuer);
  const domainKey: string = accountDomain(account);
  for (let index = 0; index < TOTP_BRAND_MANIFEST.length; index++) {
    const entry: TotpBrandManifestEntry = TOTP_BRAND_MANIFEST[index];
    for (let aliasIndex = 0; aliasIndex < entry.aliases.length; aliasIndex++) {
      if (issuerKey === normalizeAlias(entry.aliases[aliasIndex])) { return entry; }
    }
    for (let domainIndex = 0; domainIndex < entry.exactDomains.length; domainIndex++) {
      if (domainKey === normalizeVerifiedDomain(entry.exactDomains[domainIndex])) {
        return entry;
      }
    }
  }
  return null;
}

function hexChannel(value: string): number {
  return parseInt(value, 16) / 255;
}

function linearChannel(value: number): number {
  return value <= 0.04045 ? value / 12.92 : Math.pow((value + 0.055) / 1.055, 2.4);
}

export function totpRelativeLuminance(color: string): number {
  if (!/^#[0-9A-Fa-f]{6}$/.test(color)) { return 0; }
  const red: number = linearChannel(hexChannel(color.substring(1, 3)));
  const green: number = linearChannel(hexChannel(color.substring(3, 5)));
  const blue: number = linearChannel(hexChannel(color.substring(5, 7)));
  return 0.2126 * red + 0.7152 * green + 0.0722 * blue;
}

export function totpContrastRatio(foreground: string, background: string): number {
  const foregroundLuminance: number = totpRelativeLuminance(foreground);
  const backgroundLuminance: number = totpRelativeLuminance(background);
  const lighter: number = Math.max(foregroundLuminance, backgroundLuminance);
  const darker: number = Math.min(foregroundLuminance, backgroundLuminance);
  return (lighter + 0.05) / (darker + 0.05);
}

export function totpForegroundForBackground(background: string): string {
  const blackRatio: number = totpContrastRatio('#000000', background);
  const whiteRatio: number = totpContrastRatio('#FFFFFF', background);
  return blackRatio >= whiteRatio ? '#000000' : '#FFFFFF';
}

function fallbackColor(issuer: string, account: string): string {
  const source: string = normalizeAlias(issuer) + '|' + normalizeAlias(account);
  let hash: number = 0;
  for (let index = 0; index < source.length; index++) {
    hash = source.charCodeAt(index) + ((hash << 5) - hash);
  }
  return FALLBACK_COLORS[Math.abs(hash) % FALLBACK_COLORS.length];
}

export function totpInitialOf(name: string): string {
  const text: string = name.trim();
  if (text.length === 0) { return '?'; }
  const first: string = text.charAt(0);
  return /[A-Za-z]/.test(first) ? first.toUpperCase() : first;
}

export function totpBrandAvatarMode(localAsset: string, localFailed: boolean): TotpBrandAvatarMode {
  return localAsset.trim().length > 0 && !localFailed ? 'local' : 'initials';
}

function resolutionFor(
  entry: TotpBrandManifestEntry | null,
  issuer: string,
  account: string,
  requestedMode: TotpAvatarMode
): TotpBrandResolution {
  const label: string = issuer.trim().length > 0 ? issuer : account;
  if (entry === null) {
    const background: string = fallbackColor(issuer, account);
    return {
      brandId: '',
      displayName: '',
      localAsset: '',
      localAssetBytes: 0,
      sha256: '',
      sourceType: 'initials',
      background,
      foreground: totpForegroundForBackground(background),
      initials: totpInitialOf(label),
      avatarMode: 'initials'
    };
  }
  return {
    brandId: entry.brandId,
    displayName: entry.displayName,
    localAsset: entry.localAsset,
    localAssetBytes: entry.assetBytes,
    sha256: entry.sha256,
    sourceType: entry.sourceType,
    background: entry.brandColor,
    foreground: totpForegroundForBackground(entry.brandColor),
    initials: totpInitialOf(label),
    avatarMode: requestedMode === 'initials' ? 'initials' : 'local'
  };
}

export function resolveTotpBrand(
  issuer: string,
  account: string,
  avatarMode: TotpAvatarMode = 'logo'
): TotpBrandResolution {
  return resolutionFor(findEntry(issuer, account), issuer, account, avatarMode);
}

export function resolveTotpBrandForEntry(
  entry: TotpEntry,
  globalMode: TotpAvatarMode = 'logo'
): TotpBrandResolution {
  return resolveTotpBrand(entry.issuer, entry.account, globalMode);
}
