#!/usr/bin/env python3
"""Update the auditable compliance records for packaged TOTP brand assets.

The JSON manifest is the only input. This script does not discover assets or
licenses and never fetches the network; acquisition is confined to the pinned
maintainer-time importer.
"""

from __future__ import annotations

import hashlib
import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MANIFEST_PATH = ROOT / "entry/src/main/resources/rawfile/totp_brand_manifest.json"
NOTICE_PATH = ROOT / "THIRD_PARTY_NOTICES.md"
SBOM_PATH = ROOT / "docs/compliance/SBOM.spdx.json"
HASH_PATH = ROOT / "docs/compliance/THIRD_PARTY_ARTIFACTS.sha256"
ASSET_PREFIX = "entry/src/main/resources/rawfile/"
NOTICE_BEGIN = "<!-- TOTP_BRAND_NOTICE_BEGIN -->"
NOTICE_END = "<!-- TOTP_BRAND_NOTICE_END -->"
PACKAGE_ID = "SPDXRef-Package-SimpleIcons-TOTP-16.21.0"
FILE_PREFIX = "SPDXRef-File-TotpBrand-"


def read_manifest() -> dict:
    return json.loads(MANIFEST_PATH.read_text(encoding="utf-8"))


def update_notice(manifest: dict) -> None:
    text = NOTICE_PATH.read_text(encoding="utf-8")
    begin = text.find(NOTICE_BEGIN)
    end = text.find(NOTICE_END)
    if begin >= 0 and end >= begin:
        end += len(NOTICE_END)
        text = text[:begin] + text[end:]
    upstream = manifest["upstream"]
    domain_count = sum(len(entry.get("exactDomains", [])) for entry in manifest["entries"])
    alias_count = sum(len(entry.get("aliases", [])) for entry in manifest["entries"])
    row = (
        f"{NOTICE_BEGIN}\n"
        f"| Simple Icons TOTP brand batch | `{upstream['name']}@{upstream['version']}`; "
        f"{upstream['repository']}/tree/{upstream['version']} | {upstream['license']} | "
        f"{len(manifest['entries'])} local community glyphs under "
        "`entry/src/main/resources/rawfile/totp-brands/`; per-asset source, "
        "revision, SHA-256 and trademark guidance are authoritative in "
        "`entry/src/main/resources/rawfile/totp_brand_manifest.json`; no asset "
        f"is represented as an official logo. {domain_count} exact login domains "
        f"and {alias_count} reviewed issuer aliases are recorded separately; "
        "unproven domains remain empty. |\n"
        f"{NOTICE_END}\n\n"
    )
    marker = "Artifact hashes are generated in"
    position = text.find(marker)
    if position < 0:
        raise SystemExit("THIRD_PARTY_NOTICES.md marker not found")
    text = text[:position] + row + text[position:]
    NOTICE_PATH.write_text(text, encoding="utf-8")


def file_records(manifest: dict) -> tuple[list[dict], list[dict]]:
    files: list[dict] = []
    relationships: list[dict] = []
    for entry in manifest["entries"]:
        file_name = ASSET_PREFIX + entry["localAsset"]
        file_id = FILE_PREFIX + entry["brandId"]
        comment = (
            f"sourceUrl={entry['sourceUrl']}; brandSourceUrl={entry['brandSourceUrl']}; "
            f"aliasReviewed={str(entry['aliasReviewed']).lower()}; "
            f"aliasSourceUrl={entry['aliasSourceUrl']}; "
            f"domainReviewed={str(entry['domainReviewed']).lower()}; "
            f"domainSourceUrl={entry['domainSourceUrl']}; "
            f"domainEvidence={entry['domainEvidence']}; "
            f"revision={entry['upstreamVersion']}; license={entry['licenseType']}; "
            f"trademarkGuidelines={entry['trademarkGuidelines']}; "
            f"assetSha256={entry['sha256']}"
        )
        files.append({
            "SPDXID": file_id,
            "fileName": file_name,
            "checksums": [{"algorithm": "SHA256", "checksumValue": entry["sha256"]}],
            "licenseConcluded": entry["licenseType"],
            "licenseInfoInFiles": [entry["licenseType"]],
            "copyrightText": "NOASSERTION",
            "comment": comment,
        })
        relationships.append({
            "spdxElementId": PACKAGE_ID,
            "relationshipType": "CONTAINS",
            "relatedSpdxElement": file_id,
        })
    return files, relationships


def update_sbom(manifest: dict) -> None:
    sbom = json.loads(SBOM_PATH.read_text(encoding="utf-8"))
    packages = [package for package in sbom.get("packages", []) if package.get("SPDXID") != PACKAGE_ID]
    package = {
        "name": "simple-icons-totp-brand-assets",
        "SPDXID": PACKAGE_ID,
        "versionInfo": manifest["upstream"]["version"],
        "downloadLocation": (
            f"{manifest['upstream']['repository']}/tree/{manifest['upstream']['version']}"
        ),
        "filesAnalyzed": True,
        "licenseConcluded": manifest["upstream"]["license"],
        "licenseDeclared": manifest["upstream"]["license"],
        "copyrightText": "NOASSERTION",
        "externalRefs": [{
            "referenceCategory": "PACKAGE-MANAGER",
            "referenceType": "purl",
            "referenceLocator": (
                f"pkg:github/simple-icons/simple-icons@{manifest['upstream']['version']}"
            ),
        }],
        "comment": (
            "Packaged TOTP avatar glyphs only; every file's source URL, fixed "
            "revision, license and trademark guidance is recorded in the "
            "single-source TOTP manifest. Exact login domains have independent "
            "review/source fields and are never derived from artwork hosts. "
            "Simple Icons community glyphs are not asserted to be official brand logos."
        ),
    }
    packages.append(package)
    files, relationships = file_records(manifest)
    old_file_ids = {file_record["SPDXID"] for file_record in sbom.get("files", [])}
    old_file_ids.update(
        relationship.get("relatedSpdxElement")
        for relationship in sbom.get("relationships", [])
        if relationship.get("spdxElementId") == PACKAGE_ID
    )
    old_file_ids = {file_id for file_id in old_file_ids if isinstance(file_id, str)}
    sbom["packages"] = packages
    sbom["files"] = [
        file_record for file_record in sbom.get("files", [])
        if file_record.get("SPDXID") not in old_file_ids
    ] + files
    old_relationships = [
        relationship for relationship in sbom.get("relationships", [])
        if relationship.get("spdxElementId") != PACKAGE_ID and
        relationship.get("relatedSpdxElement") not in old_file_ids
    ]
    sbom["relationships"] = old_relationships + relationships
    SBOM_PATH.write_text(json.dumps(sbom, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def update_hashes(manifest: dict) -> None:
    manifest_path = ASSET_PREFIX + "totp_brand_manifest.json"
    lines = HASH_PATH.read_text(encoding="utf-8").splitlines()
    remove_prefix = ASSET_PREFIX + "totp-brands/"
    kept = [
        line for line in lines
        if line and not line.split(" *", 1)[-1].startswith(remove_prefix)
        and not line.split(" *", 1)[-1] == manifest_path
    ]
    generated = []
    for entry in manifest["entries"]:
        generated.append(
            f"{entry['sha256']} *{ASSET_PREFIX}{entry['localAsset']}"
        )
    generated.append(
        f"{hashlib.sha256(MANIFEST_PATH.read_bytes()).hexdigest()} *{manifest_path}"
    )
    HASH_PATH.write_text("\n".join(kept + generated) + "\n", encoding="utf-8")


def main() -> int:
    manifest = read_manifest()
    update_notice(manifest)
    update_sbom(manifest)
    update_hashes(manifest)
    print(json.dumps({
        "assets": len(manifest["entries"]),
        "manifestVersion": manifest["manifestVersion"],
        "sbomFiles": len(manifest["entries"]),
    }, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
