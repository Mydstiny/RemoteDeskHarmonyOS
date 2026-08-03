#!/usr/bin/env python3
"""Offline validator for the single-source TOTP brand manifest."""

from __future__ import annotations

import hashlib
import json
import re
import sys
import unicodedata
from pathlib import Path
from urllib.parse import urlparse

from generate_totp_brand_manifest import (
    MANIFEST_ETS_PATH,
    REGISTRY_ETS_PATH,
    load_manifest,
    render_manifest_ets,
    render_registry_ets,
)


ROOT = Path(__file__).resolve().parents[1]
MANIFEST_PATH = ROOT / "entry/src/main/resources/rawfile/totp_brand_manifest.json"
ASSET_ROOT = ROOT / "entry/src/main/resources/rawfile"
NOTICE_PATH = ROOT / "THIRD_PARTY_NOTICES.md"
SBOM_PATH = ROOT / "docs/compliance/SBOM.spdx.json"
HASH_PATH = ROOT / "docs/compliance/THIRD_PARTY_ARTIFACTS.sha256"
ASSET_PREFIX = "entry/src/main/resources/rawfile/"
SIMPLE_ICONS_PACKAGE_ID = "SPDXRef-Package-SimpleIcons-TOTP-16.21.0"
SHA256_PATTERN = re.compile(r"^[0-9a-f]{64}$")
COLOR_PATTERN = re.compile(r"^#[0-9A-Fa-f]{6}$")
DOMAIN_PATTERN = re.compile(
    r"^(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$"
)
DISALLOWED_DOMAIN_SOURCE_HOSTS = {
    "raw.githubusercontent.com", "simpleicons.org",
    "simple-icons.github.io", "commons.wikimedia.org", "wikimedia.org",
}


def normalized(value: str) -> str:
    value = unicodedata.normalize("NFKC", value).strip().lower()
    value = re.sub(r"[._-]+", " ", value)
    return re.sub(r"\s+", " ", value)


def unsafe_svg(data: bytes) -> bool:
    text = data.decode("utf-8", errors="ignore").lower()
    forbidden = ("<script", "<foreignobject", "<iframe", "<object", "<embed",
                 "<image", "javascript:", "data:")
    if any(marker in text for marker in forbidden):
        return True
    # The SVG namespace is required and harmless. Reject only external
    # resource references, not xmlns="http://www.w3.org/2000/svg".
    return re.search(r"(?:href|xlink:href)\s*=\s*[\"']https?://", text) is not None


def invalid_png(data: bytes) -> bool:
    """Reject a malformed packaged PNG before it reaches ImageKit."""
    if len(data) < 24 or data[:8] != b"\x89PNG\r\n\x1a\n" or data[12:16] != b"IHDR":
        return True
    width = int.from_bytes(data[16:20], "big")
    height = int.from_bytes(data[20:24], "big")
    return width <= 0 or height <= 0


def relative_luminance(color: str) -> float:
    channels = []
    for start in (1, 3, 5):
        value = int(color[start:start + 2], 16) / 255.0
        channels.append(value / 12.92 if value <= 0.04045 else ((value + 0.055) / 1.055) ** 2.4)
    return 0.2126 * channels[0] + 0.7152 * channels[1] + 0.0722 * channels[2]


def best_foreground_contrast(background: str) -> float:
    background_luminance = relative_luminance(background)
    black = (background_luminance + 0.05) / 0.05
    white = 1.05 / (background_luminance + 0.05)
    return max(black, white)


def validate_compliance_records(manifest: dict, errors: list[str]) -> bool:
    synchronized = True
    upstream = manifest.get("upstream", {})
    version = str(upstream.get("version", ""))
    entries = manifest.get("entries", [])
    try:
        notice = NOTICE_PATH.read_text(encoding="utf-8")
    except OSError as error:
        errors.append(f"compliance notice unreadable: {error}")
        synchronized = False
        notice = ""
    notice_needles = (
        f"simple-icons@{version}",
        f"{len(entries)} local community glyphs",
        "totp_brand_manifest.json",
        "no asset is represented as an official logo",
    )
    for needle in notice_needles:
        if needle not in notice:
            errors.append(f"compliance notice missing: {needle}")
            synchronized = False

    try:
        sbom = json.loads(SBOM_PATH.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        errors.append(f"compliance SBOM unreadable: {error}")
        synchronized = False
        sbom = {}
    packages = [
        package for package in sbom.get("packages", [])
        if package.get("SPDXID") == SIMPLE_ICONS_PACKAGE_ID
    ]
    if len(packages) != 1:
        errors.append("compliance SBOM must contain exactly one Simple Icons TOTP package")
        synchronized = False
    else:
        package = packages[0]
        if package.get("versionInfo") != version or package.get("licenseDeclared") != "CC0-1.0" or not package.get("filesAnalyzed"):
            errors.append("compliance SBOM Simple Icons package metadata is incomplete")
            synchronized = False
    sbom_files = {
        file_record.get("fileName"): file_record
        for file_record in sbom.get("files", [])
        if isinstance(file_record, dict)
    }
    if len([name for name in sbom_files if str(name).startswith(ASSET_PREFIX + "totp-brands/")]) != len(entries):
        errors.append("compliance SBOM asset file count does not match manifest")
        synchronized = False
    for entry in entries:
        file_name = ASSET_PREFIX + str(entry.get("localAsset", ""))
        record = sbom_files.get(file_name)
        if record is None:
            errors.append(f"compliance SBOM file missing: {file_name}")
            synchronized = False
            continue
        checksum_values = [
            checksum.get("checksumValue") for checksum in record.get("checksums", [])
            if checksum.get("algorithm") == "SHA256"
        ]
        comment = str(record.get("comment", ""))
        required_comment_parts = (
            str(entry.get("sourceUrl", "")),
            str(entry.get("brandSourceUrl", "")),
            f"aliasReviewed={str(entry.get('aliasReviewed', '')).lower()}",
            f"aliasSourceUrl={entry.get('aliasSourceUrl', '')}",
            f"domainReviewed={str(entry.get('domainReviewed', '')).lower()}",
            f"domainSourceUrl={entry.get('domainSourceUrl', '')}",
            f"domainEvidence={entry.get('domainEvidence', '')}",
            f"revision={entry.get('upstreamVersion', '')}",
            f"license={entry.get('licenseType', '')}",
            str(entry.get("trademarkGuidelines", "")),
            f"assetSha256={entry.get('sha256', '')}",
        )
        if checksum_values != [entry.get("sha256")] or any(part not in comment for part in required_comment_parts):
            errors.append(f"compliance SBOM provenance/hash mismatch: {file_name}")
            synchronized = False

    try:
        hash_lines = {
            line.strip() for line in HASH_PATH.read_text(encoding="utf-8").splitlines()
            if line.strip()
        }
    except OSError as error:
        errors.append(f"compliance artifact hash file unreadable: {error}")
        synchronized = False
        hash_lines = set()
    expected_hash_lines = {
        f"{entry.get('sha256', '')} *{ASSET_PREFIX}{entry.get('localAsset', '')}"
        for entry in entries
    }
    expected_hash_lines.add(
        f"{hashlib.sha256(MANIFEST_PATH.read_bytes()).hexdigest()} *{ASSET_PREFIX}totp_brand_manifest.json"
    )
    if not expected_hash_lines.issubset(hash_lines):
        errors.append("compliance artifact hash file is missing a manifest/asset hash")
        synchronized = False
    return synchronized


def main() -> int:
    manifest = load_manifest(MANIFEST_PATH)
    entries = manifest.get("entries", [])
    errors: list[str] = []
    seen_ids: set[str] = set()
    seen_assets: set[str] = set()
    seen_aliases_domains: set[str] = set()
    alias_name_count = 0
    domain_count = 0
    domain_semantic_errors: list[str] = []
    total_bytes = 0
    minimum_contrast = float("inf")

    if not manifest.get("manifestVersion"):
        errors.append("manifestVersion missing")
    if not manifest.get("hashScope"):
        errors.append("hashScope missing")
    upstream = manifest.get("upstream", {})
    if upstream.get("name") != "simple-icons":
        errors.append("upstream.name must be simple-icons")
    if upstream.get("version") != "16.21.0":
        errors.append("upstream.version must be the pinned Simple Icons version 16.21.0")
    targets = manifest.get("completionTargets", {})
    asset_target = int(targets.get("uniqueLocalAssets", 0))
    alias_target = int(targets.get("aliasesAndDomains", 0))
    if asset_target != 250:
        errors.append("completionTargets.uniqueLocalAssets must be 250")
    if alias_target != 500:
        errors.append("completionTargets.aliasesAndDomains must be 500")

    required = (
        "brandId", "displayName", "aliases", "exactDomains", "localAsset", "assetBytes",
        "aliasReviewed", "aliasSourceUrl", "aliasEvidence",
        "domainReviewed", "domainSourceUrl", "domainEvidence",
        "sourceType", "sourceUrl", "brandSourceUrl", "brandGuidelines", "upstreamVersion",
        "sha256", "licenseType", "licenseUrl", "trademarkGuidelines",
        "officialAssetVerified", "brandColor"
    )
    # Some reviewed brands have intentionally unsafe-short titles (for
    # example C or 42). They remain packaged, but cannot be exact issuer
    # aliases and therefore correctly fall back to initials.
    required_nonempty = set(required) - {"exactDomains", "aliases"}
    for index, entry in enumerate(entries):
        prefix = f"entries[{index}]"
        for field in required:
            if field not in entry or (field in required_nonempty and entry[field] in ("", None, [])):
                errors.append(f"{prefix}.{field} missing")

        brand_id = str(entry.get("brandId", ""))
        asset = str(entry.get("localAsset", ""))
        if brand_id in seen_ids:
            errors.append(f"{prefix}.brandId duplicated: {brand_id}")
        seen_ids.add(brand_id)
        if asset in seen_assets:
            errors.append(f"{prefix}.localAsset duplicated: {asset}")
        seen_assets.add(asset)
        if (not asset.startswith("totp-brands/") or
                (not asset.endswith(".svg") and not asset.endswith(".png")) or
                ".." in Path(asset).parts):
            errors.append(f"{prefix}.localAsset must be a safe packaged image path")

        for alias in entry.get("aliases", []):
            alias_name_count += 1
            key = normalized(str(alias))
            if len(key.replace(" ", "")) < 3:
                errors.append(f"{prefix}.unsafe short alias: {alias}")
            if key in seen_aliases_domains:
                errors.append(f"{prefix}.alias duplicated: {alias}")
            seen_aliases_domains.add(key)
        for domain in entry.get("exactDomains", []):
            domain_count += 1
            raw_domain = str(domain).strip().lower().rstrip(".")
            key = normalized(raw_domain)
            if not DOMAIN_PATTERN.fullmatch(raw_domain):
                errors.append(f"{prefix}.invalid exact login domain: {domain}")
                domain_semantic_errors.append(f"{prefix}.invalid exact login domain: {domain}")
            if key in seen_aliases_domains:
                errors.append(f"{prefix}.alias/domain duplicated: {domain}")
                domain_semantic_errors.append(f"{prefix}.duplicate exact login domain: {domain}")
            seen_aliases_domains.add(key)

        if entry.get("sourceType") != "simple-icons":
            errors.append(f"{prefix}.sourceType must be simple-icons")
        if entry.get("upstreamVersion") != upstream.get("version"):
            errors.append(f"{prefix}.upstreamVersion does not match manifest upstream")
        for url_field in ("sourceUrl", "brandSourceUrl", "brandGuidelines", "licenseUrl"):
            if not str(entry.get(url_field, "")).startswith("https://"):
                errors.append(f"{prefix}.{url_field} must be an HTTPS URL")
        if entry.get("licenseType") != "CC0-1.0":
            errors.append(f"{prefix}.licenseType must be CC0-1.0")
        if entry.get("officialAssetVerified") is not False:
            errors.append(f"{prefix}.officialAssetVerified must be false")
        if not SHA256_PATTERN.fullmatch(str(entry.get("sha256", ""))):
            errors.append(f"{prefix}.sha256 invalid")
        if not COLOR_PATTERN.fullmatch(str(entry.get("brandColor", ""))):
            errors.append(f"{prefix}.brandColor invalid")
        else:
            contrast = best_foreground_contrast(str(entry["brandColor"]))
            minimum_contrast = min(minimum_contrast, contrast)
            if contrast < 4.5:
                errors.append(f"{prefix}.brandColor has insufficient WCAG contrast")
        if not str(entry.get("trademarkGuidelines", "")).strip():
            errors.append(f"{prefix}.trademarkGuidelines missing")

        if entry.get("aliasReviewed") is not True:
            errors.append(f"{prefix}.aliasReviewed must be true")
        alias_source = str(entry.get("aliasSourceUrl", ""))
        if not alias_source.startswith("https://") or "/data/simple-icons.json" not in alias_source:
            errors.append(f"{prefix}.aliasSourceUrl must be the pinned Simple Icons metadata source")
        if not str(entry.get("aliasEvidence", "")).strip():
            errors.append(f"{prefix}.aliasEvidence missing")

        domain_reviewed = entry.get("domainReviewed") is True
        domain_source = str(entry.get("domainSourceUrl", "")).strip()
        domain_evidence = str(entry.get("domainEvidence", "")).strip()
        if not domain_reviewed:
            errors.append(f"{prefix}.domainReviewed must be true")
            domain_semantic_errors.append(f"{prefix}.domain review missing")
        if not domain_source.startswith("https://"):
            errors.append(f"{prefix}.domainSourceUrl must be an HTTPS URL")
            domain_semantic_errors.append(f"{prefix}.domain source missing")
        if not domain_evidence:
            errors.append(f"{prefix}.domainEvidence missing")
            domain_semantic_errors.append(f"{prefix}.domain evidence missing")
        source_host = (urlparse(domain_source).hostname or "").lower()
        if source_host.startswith("www."):
            source_host = source_host[4:]
        if entry.get("exactDomains"):
            if domain_source in {
                str(entry.get("sourceUrl", "")),
                str(entry.get("brandSourceUrl", "")),
            }:
                errors.append(f"{prefix}.domainSourceUrl must be independent of artwork provenance")
                domain_semantic_errors.append(f"{prefix}.domain source reuses artwork provenance")
            if source_host in DISALLOWED_DOMAIN_SOURCE_HOSTS:
                errors.append(f"{prefix}.domainSourceUrl must not use a community/artwork host")
                domain_semantic_errors.append(f"{prefix}.domain source uses disallowed host")
            if "intentionally empty" in domain_evidence.lower():
                errors.append(f"{prefix}.domainEvidence contradicts exactDomains")
                domain_semantic_errors.append(f"{prefix}.domain evidence contradicts exact domain")
        elif "intentionally empty" not in domain_evidence.lower():
            errors.append(f"{prefix}.empty exactDomains must document intentional absence of evidence")
            domain_semantic_errors.append(f"{prefix}.empty domain review is not explicit")

        asset_path = ASSET_ROOT / asset
        if not asset_path.is_file():
            errors.append(f"{prefix}.asset missing: {asset_path}")
            continue
        data = asset_path.read_bytes()
        total_bytes += len(data)
        if asset.endswith(".svg") and unsafe_svg(data):
            errors.append(f"{prefix}.asset contains unsafe SVG content")
        if asset.endswith(".png") and invalid_png(data):
            errors.append(f"{prefix}.asset is not a valid PNG")
        digest = hashlib.sha256(data).hexdigest()
        if digest != entry.get("sha256"):
            errors.append(f"{prefix}.sha256 mismatch: expected {entry.get('sha256')} got {digest}")
        if len(data) != entry.get("assetBytes"):
            errors.append(f"{prefix}.assetBytes mismatch: expected {entry.get('assetBytes')} got {len(data)}")

    generated_artifacts_synchronized = True
    expected_manifest_ets = render_manifest_ets(manifest)
    expected_registry_ets = render_registry_ets(manifest)
    if not MANIFEST_ETS_PATH.is_file() or MANIFEST_ETS_PATH.read_text(encoding="utf-8") != expected_manifest_ets:
        generated_artifacts_synchronized = False
        errors.append("TotpBrandManifest.ets is not generated from the JSON manifest")
    if not REGISTRY_ETS_PATH.is_file() or REGISTRY_ETS_PATH.read_text(encoding="utf-8") != expected_registry_ets:
        generated_artifacts_synchronized = False
        errors.append("TotpBrandAssetRegistry.ets is not generated from the JSON manifest")

    registry_text = REGISTRY_ETS_PATH.read_text(encoding="utf-8") if REGISTRY_ETS_PATH.is_file() else ""
    for entry in entries:
        asset_case = (
            f"case {json.dumps(entry['brandId'], ensure_ascii=False)}: return "
            f"{json.dumps(entry['localAsset'], ensure_ascii=False)};"
        )
        resource_case = (
            f"case {json.dumps(entry['brandId'], ensure_ascii=False)}: return $rawfile("
            f"{json.dumps(entry['localAsset'], ensure_ascii=False)});"
        )
        if asset_case not in registry_text or resource_case not in registry_text:
            errors.append(f"registry mapping missing or ambiguous for {entry['brandId']}")

    compliance_records_synchronized = validate_compliance_records(manifest, errors)

    unique_assets = len(seen_assets)
    aliases_and_domains = len(seen_aliases_domains)
    asset_gap = max(0, asset_target - unique_assets)
    alias_gap = max(0, alias_target - aliases_and_domains)
    domain_semantic_valid = len(domain_semantic_errors) == 0
    coverage_status = (
        "domain semantics pass; quantity target met"
        if domain_semantic_valid and not (asset_gap or alias_gap)
        else "domain semantics pass; quantity gap"
        if domain_semantic_valid
        else "domain semantics fail"
    )
    report = {
        "manifestVersion": manifest.get("manifestVersion"),
        "entries": len(entries),
        "uniqueLocalAssets": unique_assets,
        "aliasNames": alias_name_count,
        "exactDomains": domain_count,
        "aliasesAndDomains": aliases_and_domains,
        "domainSemanticValid": domain_semantic_valid,
        "coverageStatus": coverage_status,
        "minimumContrastRatio": 0 if minimum_contrast == float("inf") else round(minimum_contrast, 4),
        "localBytes": total_bytes,
        "generatedArtifactsSynchronized": generated_artifacts_synchronized,
        "complianceRecordsSynchronized": compliance_records_synchronized,
        "coverageGap": {
            "uniqueLocalAssets": asset_gap,
            "aliasesAndDomains": alias_gap,
        },
        "errors": errors,
    }
    print(json.dumps(report, ensure_ascii=False, sort_keys=True))
    if errors:
        return 1
    if asset_gap or alias_gap:
        print(
            "coverage blocker: add only provenance-complete fixed-version assets; "
            f"missing {asset_gap} unique assets and {alias_gap} aliases/domains",
            file=sys.stderr,
        )
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
