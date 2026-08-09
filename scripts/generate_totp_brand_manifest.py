#!/usr/bin/env python3
"""Render the ArkTS brand manifest and rawfile registry from one JSON source.

This command is intentionally offline. Asset import is a separate, explicit
operation; validation can therefore never add or refresh a network resource.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
import unicodedata
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MANIFEST_PATH = ROOT / "entry/src/main/resources/rawfile/totp_brand_manifest.json"
MANIFEST_ETS_PATH = ROOT / "entry/src/main/ets/services/TotpBrandManifest.ets"
REGISTRY_ETS_PATH = ROOT / "entry/src/main/ets/services/TotpBrandAssetRegistry.ets"
OFFICIAL_REGISTRY_ETS_PATH = ROOT / "entry/src/main/ets/services/TotpBrandOfficialAssetRegistry.ets"


def load_manifest(path: Path = MANIFEST_PATH) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def source_digest(manifest: dict) -> str:
    payload = {
        "manifestVersion": manifest.get("manifestVersion"),
        "hashScope": manifest.get("hashScope"),
        "upstream": manifest.get("upstream"),
        "completionTargets": manifest.get("completionTargets"),
        "runtimePolicy": manifest.get("runtimePolicy"),
        "officialOverrides": manifest.get("officialOverrides", []),
        "entries": manifest.get("entries", []),
    }
    encoded = json.dumps(payload, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(encoded.encode("utf-8")).hexdigest()


def ts_string(value: str) -> str:
    return json.dumps(value, ensure_ascii=False)


def ts_array(values: list[str]) -> str:
    return "[" + ", ".join(ts_string(value) for value in values) + "]"


def normalized_alias(value: str) -> str:
    normalized = unicodedata.normalize("NFKC", value).strip().lower()
    normalized = re.sub(r"[._-]+", " ", normalized)
    return re.sub(r"\s+", " ", normalized)


def render_manifest_ets(manifest: dict) -> str:
    entries = manifest["entries"]
    upstream = manifest["upstream"]
    targets = manifest["completionTargets"]
    digest = source_digest(manifest)
    lines = [
        "/** GENERATED FILE. Edit totp_brand_manifest.json and rerun the generator. */",
        "",
        f"export const TOTP_BRAND_MANIFEST_VERSION: string = {ts_string(manifest['manifestVersion'])};",
        f"export const TOTP_BRAND_MANIFEST_SOURCE_SHA256: string = {ts_string(digest)};",
        f"export const TOTP_BRAND_ASSET_TARGET: number = {int(targets['uniqueLocalAssets'])};",
        f"export const TOTP_BRAND_ALIAS_TARGET: number = {int(targets['aliasesAndDomains'])};",
        "",
        "export type TotpBrandSourceType = 'simple-icons';",
        "",
        "export interface TotpBrandManifestEntry {",
        "  brandId: string;",
        "  displayName: string;",
        "  aliases: string[];",
        "  exactDomains: string[];",
        "  aliasReviewed: boolean;",
        "  aliasSourceUrl: string;",
        "  aliasEvidence: string;",
        "  domainReviewed: boolean;",
        "  domainSourceUrl: string;",
        "  domainEvidence: string;",
        "  localAsset: string;",
        "  assetBytes: number;",
        "  sourceType: TotpBrandSourceType;",
        "  sourceUrl: string;",
        "  brandSourceUrl: string;",
        "  brandGuidelines: string;",
        "  upstreamVersion: string;",
        "  sha256: string;",
        "  licenseType: string;",
        "  licenseUrl: string;",
        "  trademarkGuidelines: string;",
        "  officialAssetVerified: boolean;",
        "  brandColor: string;",
        "}",
        "",
        f"const SIMPLE_ICONS_SOURCE: string = {ts_string(upstream['repository'])};",
        f"const SIMPLE_ICONS_LICENSE: string = {ts_string(upstream['licenseUrl'])};",
        f"const SIMPLE_ICONS_DISCLAIMER: string = {ts_string(upstream['disclaimerUrl'])};",
        "",
        "export const TOTP_BRAND_MANIFEST: TotpBrandManifestEntry[] = [",
    ]
    rendered_entries: list[str] = []
    for entry in entries:
        rendered_entries.append("  {")
        ordered = [
            ("brandId", ts_string(entry["brandId"])),
            ("displayName", ts_string(entry["displayName"])),
            ("aliases", ts_array(entry["aliases"])),
            ("exactDomains", ts_array(entry["exactDomains"])),
            ("aliasReviewed", "true" if entry["aliasReviewed"] else "false"),
            ("aliasSourceUrl", ts_string(entry["aliasSourceUrl"])),
            ("aliasEvidence", ts_string(entry["aliasEvidence"])),
            ("domainReviewed", "true" if entry["domainReviewed"] else "false"),
            ("domainSourceUrl", ts_string(entry["domainSourceUrl"])),
            ("domainEvidence", ts_string(entry["domainEvidence"])),
            ("localAsset", ts_string(entry["localAsset"])),
            ("assetBytes", str(int(entry["assetBytes"]))),
            ("sourceType", ts_string(entry["sourceType"])),
            ("sourceUrl", ts_string(entry["sourceUrl"])),
            ("brandSourceUrl", ts_string(entry["brandSourceUrl"])),
            ("brandGuidelines", ts_string(entry["brandGuidelines"])),
            ("upstreamVersion", ts_string(entry["upstreamVersion"])),
            ("sha256", ts_string(entry["sha256"])),
            ("licenseType", ts_string(entry["licenseType"])),
            ("licenseUrl", ts_string(entry["licenseUrl"])),
            ("trademarkGuidelines", ts_string(entry["trademarkGuidelines"])),
            ("officialAssetVerified", "false" if not entry["officialAssetVerified"] else "true"),
            ("brandColor", ts_string(entry["brandColor"])),
        ]
        rendered_entries.extend(f"    {key}: {value}," for key, value in ordered[:-1])
        rendered_entries.append(f"    {ordered[-1][0]}: {ordered[-1][1]}")
        rendered_entries.append("  },")
    if rendered_entries:
        rendered_entries[-1] = "  }"
    lines.extend(rendered_entries)
    lines.extend([
        "];",
        "",
    ])
    return "\n".join(lines)


def render_registry_ets(manifest: dict) -> str:
    entries = manifest["entries"]
    digest = source_digest(manifest)
    lines = [
        "/** GENERATED FILE. Edit totp_brand_manifest.json and rerun the generator. */",
        "",
        "import { totpOfficialBrandAssetPath, totpOfficialBrandAssetResource } from './TotpBrandOfficialAssetRegistry';",
        "",
        f"export const TOTP_BRAND_ASSET_REGISTRY_MANIFEST_VERSION: string = {ts_string(manifest['manifestVersion'])};",
        f"export const TOTP_BRAND_ASSET_REGISTRY_SOURCE_SHA256: string = {ts_string(digest)};",
        "export const TOTP_BRAND_ASSET_REGISTRY_IDS: string[] = [",
    ]
    for index, entry in enumerate(entries):
        suffix = "," if index + 1 < len(entries) else ""
        lines.append(f"  {ts_string(entry['brandId'])}{suffix}")
    lines.extend([
        "];",
        "",
        "export function totpBrandAssetPath(brandId: string): string {",
        "  const officialPath: string = totpOfficialBrandAssetPath(brandId);",
        "  if (officialPath !== '') { return officialPath; }",
        "  switch (brandId) {",
    ])
    for entry in entries:
        lines.append(
            f"    case {ts_string(entry['brandId'])}: return {ts_string(entry['localAsset'])};"
        )
    lines.extend([
        "    default: return '';",
        "  }",
        "}",
        "",
        "export function totpBrandAssetResource(brandId: string): Resource | null {",
        "  const officialResource: Resource | null = totpOfficialBrandAssetResource(brandId);",
        "  if (officialResource !== null) { return officialResource; }",
        "  switch (brandId) {",
    ])
    for entry in entries:
        lines.append(
            f"    case {ts_string(entry['brandId'])}: return $rawfile({ts_string(entry['localAsset'])});"
        )
    lines.extend([
        "    default: return null;",
        "  }",
        "}",
        "",
    ])
    return "\n".join(lines)


def render_official_registry_ets(manifest: dict) -> str:
    entries = manifest.get("officialOverrides", [])
    digest = source_digest(manifest)
    lines = [
        "/** GENERATED FILE. Edit totp_brand_manifest.json and rerun the generator. */",
        "",
        f"export const TOTP_OFFICIAL_BRAND_SOURCE_SHA256: string = {ts_string(digest)};",
        "",
        "export interface TotpOfficialBrandEntry {",
        "  brandId: string;",
        "  displayName: string;",
        "  aliases: string[];",
        "  exactDomains: string[];",
        "  localAsset: string;",
        "  assetBytes: number;",
        "  sha256: string;",
        "  sourceType: 'official' | 'svglogos-catalog';",
        "  brandColor: string;",
        "}",
        "",
        "export const TOTP_OFFICIAL_BRANDS: TotpOfficialBrandEntry[] = [",
    ]
    rendered_entries: list[str] = []
    for entry in entries:
        normalized_aliases = [normalized_alias(value) for value in entry["aliases"]]
        rendered_entries.extend([
            "  {",
            f"    brandId: {ts_string(entry['brandId'])},",
            f"    displayName: {ts_string(entry['displayName'])},",
            f"    aliases: {ts_array(normalized_aliases)},",
            f"    exactDomains: {ts_array(entry['exactDomains'])},",
            f"    localAsset: {ts_string(entry['localAsset'])},",
            f"    assetBytes: {int(entry['assetBytes'])},",
            f"    sha256: {ts_string(entry['sha256'])},",
            f"    sourceType: {ts_string(entry['sourceType'])},",
            f"    brandColor: {ts_string(entry['brandColor'])}",
            "  },",
        ])
    if rendered_entries:
        rendered_entries[-1] = "  }"
    lines.extend(rendered_entries)
    lines.extend([
        "];",
        "",
        "export function findTotpOfficialBrand(issuerKey: string, domainKey: string): TotpOfficialBrandEntry | null {",
        "  if (issuerKey.length > 0) {",
        "    for (let index = 0; index < TOTP_OFFICIAL_BRANDS.length; index++) {",
        "      const entry: TotpOfficialBrandEntry = TOTP_OFFICIAL_BRANDS[index];",
        "      if (entry.aliases.indexOf(issuerKey) >= 0) { return entry; }",
        "    }",
        "    return null;",
        "  }",
        "  if (domainKey.length === 0) { return null; }",
        "  for (let index = 0; index < TOTP_OFFICIAL_BRANDS.length; index++) {",
        "    const entry: TotpOfficialBrandEntry = TOTP_OFFICIAL_BRANDS[index];",
        "    if (entry.exactDomains.indexOf(domainKey) >= 0) { return entry; }",
        "  }",
        "  return null;",
        "}",
        "",
        "export function totpOfficialBrandAssetPath(brandId: string): string {",
        "  switch (brandId) {",
    ])
    for entry in entries:
        lines.append(
            f"    case {ts_string(entry['brandId'])}: return {ts_string(entry['localAsset'])};"
        )
    lines.extend([
        "    default: return '';",
        "  }",
        "}",
        "",
        "export function totpOfficialBrandAssetResource(brandId: string): Resource | null {",
        "  switch (brandId) {",
    ])
    for entry in entries:
        lines.append(
            f"    case {ts_string(entry['brandId'])}: return $rawfile({ts_string(entry['localAsset'])});"
        )
    lines.extend([
        "    default: return null;",
        "  }",
        "}",
        "",
    ])
    return "\n".join(lines)


def check_or_write(path: Path, expected: str, write: bool) -> bool:
    actual = path.read_text(encoding="utf-8") if path.exists() else None
    if actual == expected:
        return True
    if write:
        path.write_text(expected, encoding="utf-8")
        return True
    return False


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--write", action="store_true", help="write generated ArkTS files")
    parser.add_argument("--check", action="store_true", help="fail if generated files drift")
    args = parser.parse_args()
    if args.write and args.check:
        parser.error("choose --write or --check")
    write = args.write
    check = args.check or not write
    manifest = load_manifest()
    manifest_ok = check_or_write(MANIFEST_ETS_PATH, render_manifest_ets(manifest), write)
    registry_ok = check_or_write(REGISTRY_ETS_PATH, render_registry_ets(manifest), write)
    official_registry_ok = check_or_write(
        OFFICIAL_REGISTRY_ETS_PATH, render_official_registry_ets(manifest), write)
    if not (manifest_ok and registry_ok and official_registry_ok):
        print("generated TOTP ArkTS artifacts drift from the JSON manifest", file=sys.stderr)
        return 1
    if check:
        print("generated TOTP ArkTS artifacts: synchronized")
    else:
        print("generated TOTP ArkTS artifacts: written")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
