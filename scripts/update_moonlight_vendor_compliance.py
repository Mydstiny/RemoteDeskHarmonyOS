#!/usr/bin/env python3
"""Regenerate Moonlight notice, SPDX, and byte-hash records from the lock."""

from __future__ import annotations

import hashlib
import json
import re
from pathlib import Path

from verify_moonlight_vendor import (
    FILE_ID_PREFIX,
    HASH_PATH,
    NOTICE_PATH,
    ROOT,
    SBOM_PATH,
    component_files,
    load_lock,
    sha256_file,
)


NOTICE_BEGIN = "<!-- MOONLIGHT_VENDOR_NOTICE_BEGIN -->"
NOTICE_END = "<!-- MOONLIGHT_VENDOR_NOTICE_END -->"
NOTICE_ANCHOR = (
    "| Hypium / Hamock | root package lock | OpenHarmony package terms | tests only |\n"
)


def file_spdx_id(relative: str) -> str:
    suffix = hashlib.sha256(relative.encode("utf-8")).hexdigest()[:24]
    return FILE_ID_PREFIX + suffix


def source_records(lock: dict) -> list[tuple[str, str, dict]]:
    records: list[tuple[str, str, dict]] = []
    for component in lock["components"]:
        for path in component_files(component):
            records.append((
                path.relative_to(ROOT).as_posix(), sha256_file(path), component,
            ))
    return sorted(records, key=lambda item: item[0])


def update_notice(lock: dict) -> None:
    text = NOTICE_PATH.read_text(encoding="utf-8")
    block_pattern = re.compile(
        rf"\n*{re.escape(NOTICE_BEGIN)}.*?{re.escape(NOTICE_END)}\n*",
        re.DOTALL,
    )
    text, block_count = block_pattern.subn("\n", text)
    if block_count > 1:
        raise ValueError("THIRD_PARTY_NOTICES.md contains duplicate Moonlight blocks")
    anchor = text.find(NOTICE_ANCHOR)
    if anchor < 0:
        raise ValueError("THIRD_PARTY_NOTICES.md table anchor not found")
    anchor += len(NOTICE_ANCHOR)
    rows = [NOTICE_BEGIN]
    roles = {
        "moonlight-common-c": "Moonlight streaming protocol core; vendored source only in N1-01",
        "moonlight-enet": "common-c pinned reliable UDP transport fork",
        "moonlight-nanors": "common-c pinned Reed-Solomon/FEC implementation",
    }
    for component in lock["components"]:
        rows.append(
            f"| {component['name']} | {component['repository']} commit "
            f"`{component['revision']}`; tree `{component['tree']}` | "
            f"{component['license']} | {roles[component['id']]}; exact original "
            f"source and license retained under `{component['path']}` |"
        )
    rows.append(NOTICE_END)
    suffix = text[anchor:].lstrip("\n")
    block = "\n".join(rows) + "\n\n"
    NOTICE_PATH.write_text(text[:anchor] + block + suffix, encoding="utf-8")


def update_sbom(lock: dict, records: list[tuple[str, str, dict]]) -> None:
    sbom = json.loads(SBOM_PATH.read_text(encoding="utf-8"))
    package_ids = {component["spdxPackageId"] for component in lock["components"]}
    old_file_ids = {
        record.get("SPDXID") for record in sbom.get("files", [])
        if str(record.get("SPDXID", "")).startswith(FILE_ID_PREFIX)
    }
    old_file_ids = {item for item in old_file_ids if isinstance(item, str)}

    packages = [
        package for package in sbom.get("packages", [])
        if package.get("SPDXID") not in package_ids
    ]
    for component in lock["components"]:
        packages.append({
            "name": component["name"],
            "SPDXID": component["spdxPackageId"],
            "versionInfo": component["revision"],
            "downloadLocation": component["downloadLocation"],
            "filesAnalyzed": True,
            "licenseConcluded": component["license"],
            "licenseDeclared": component["license"],
            "copyrightText": "See vendored license and THIRD_PARTY_NOTICES.md",
            "externalRefs": [{
                "referenceCategory": "PACKAGE-MANAGER",
                "referenceType": "purl",
                "referenceLocator": component["purl"],
            }],
            "comment": (
                f"Exact unmodified source snapshot; repository={component['repository']}; "
                f"revision={component['revision']}; tree={component['tree']}; "
                f"contentManifestSha256={component['contentManifestSha256']}"
            ),
        })

    files = [
        record for record in sbom.get("files", [])
        if record.get("SPDXID") not in old_file_ids
    ]
    relationships = [
        relationship for relationship in sbom.get("relationships", [])
        if relationship.get("spdxElementId") not in package_ids
        and relationship.get("relatedSpdxElement") not in package_ids
        and relationship.get("spdxElementId") not in old_file_ids
        and relationship.get("relatedSpdxElement") not in old_file_ids
    ]

    for relative, digest, component in records:
        spdx_id = file_spdx_id(relative)
        files.append({
            "SPDXID": spdx_id,
            "fileName": relative,
            "checksums": [{"algorithm": "SHA256", "checksumValue": digest}],
            "licenseConcluded": component["license"],
            "licenseInfoInFiles": [component["license"]],
            "copyrightText": "See vendored source and license",
            "comment": (
                f"repository={component['repository']}; revision={component['revision']}; "
                f"tree={component['tree']}"
            ),
        })
        relationships.append({
            "spdxElementId": component["spdxPackageId"],
            "relationshipType": "CONTAINS",
            "relatedSpdxElement": spdx_id,
        })

    for component in lock["components"]:
        relationships.append({
            "spdxElementId": "SPDXRef-Package-RemoteDeskHarmonyOS",
            "relationshipType": "DEPENDS_ON",
            "relatedSpdxElement": component["spdxPackageId"],
        })
    for dependency in ("SPDXRef-Package-Moonlight-ENet", "SPDXRef-Package-Moonlight-Nanors"):
        relationships.append({
            "spdxElementId": "SPDXRef-Package-Moonlight-Common-C",
            "relationshipType": "DEPENDS_ON",
            "relatedSpdxElement": dependency,
        })

    sbom["packages"] = packages
    sbom["files"] = files
    sbom["relationships"] = relationships
    SBOM_PATH.write_text(
        json.dumps(sbom, ensure_ascii=False, indent=2) + "\n", encoding="utf-8",
    )


def update_hashes(lock: dict, records: list[tuple[str, str, dict]]) -> None:
    vendor_prefix = lock["vendorRoot"] + "/"
    kept = [
        line for line in HASH_PATH.read_text(encoding="utf-8").splitlines()
        if line and not line.split(" *", 1)[-1].startswith(vendor_prefix)
    ]
    generated = [f"{digest} *{relative}" for relative, digest, _ in records]
    HASH_PATH.write_text("\n".join(kept + generated) + "\n", encoding="utf-8")


def main() -> int:
    lock = load_lock()
    records = source_records(lock)
    update_notice(lock)
    update_sbom(lock, records)
    update_hashes(lock, records)
    print(json.dumps({
        "components": len(lock["components"]),
        "files": len(records),
    }, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
