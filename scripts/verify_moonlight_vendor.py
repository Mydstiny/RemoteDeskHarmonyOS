#!/usr/bin/env python3
"""Offline integrity and compliance gate for the pinned Moonlight sources."""

from __future__ import annotations

import hashlib
import json
import re
import subprocess
import sys
from argparse import ArgumentParser
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
LOCK_PATH = ROOT / "entry/src/main/cpp/moonlight/upstream/UPSTREAM.lock.json"
HASH_PATH = ROOT / "docs/compliance/THIRD_PARTY_ARTIFACTS.sha256"
SBOM_PATH = ROOT / "docs/compliance/SBOM.spdx.json"
NOTICE_PATH = ROOT / "THIRD_PARTY_NOTICES.md"
SOURCE_OFFER_PATH = ROOT / "docs/compliance/SOURCE_OFFER.md"
PROVENANCE_PATH = ROOT / "docs/compliance/MOONLIGHT_COMMON_C_PROVENANCE.md"
GIT_ATTRIBUTES_PATH = ROOT / ".gitattributes"
FILE_ID_PREFIX = "SPDXRef-File-MoonlightVendor-"
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
GIT_OBJECT_RE = re.compile(r"^[0-9a-f]{40}$")


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def load_lock() -> dict:
    lock = json.loads(LOCK_PATH.read_text(encoding="utf-8"))
    if lock.get("schemaVersion") != 1:
        raise ValueError("unsupported UPSTREAM.lock.json schemaVersion")
    components = lock.get("components")
    if not isinstance(components, list) or len(components) != 3:
        raise ValueError("UPSTREAM.lock.json must contain exactly three components")
    ids = [component.get("id") for component in components]
    if ids != ["moonlight-common-c", "moonlight-enet", "moonlight-nanors"]:
        raise ValueError("UPSTREAM.lock.json component order/identity drifted")
    expected_gitlinks = [
        {
            "path": component.get("gitlinkPath"),
            "revision": component.get("revision"),
        }
        for component in components[1:]
    ]
    if components[0].get("gitlinks") != expected_gitlinks:
        raise ValueError("common-c gitlinks do not match pinned child revisions")
    receipts = lock.get("buildReceipts")
    if not isinstance(receipts, dict):
        raise ValueError("UPSTREAM.lock.json lacks buildReceipts")
    if receipts.get("sdkApi") != "23":
        raise ValueError("UPSTREAM.lock.json build receipt SDK API drifted")
    for field in ("sdkVersion", "compiler", "opensslVersion"):
        if not receipts.get(field):
            raise ValueError(f"UPSTREAM.lock.json build receipt lacks {field}")
    archives = receipts.get("archives")
    if not isinstance(archives, dict) or list(archives) != ["arm64-v8a", "x86_64"]:
        raise ValueError("UPSTREAM.lock.json must contain ordered dual-ABI build receipts")
    for abi, receipt in archives.items():
        if not isinstance(receipt, dict):
            raise ValueError(f"invalid build receipt for {abi}")
        for archive in ("libmoonlight-common-c.a", "libenet.a"):
            if not SHA256_RE.fullmatch(str(receipt.get(archive, ""))):
                raise ValueError(f"invalid {abi} receipt for {archive}")
    return lock


def component_files(component: dict) -> list[Path]:
    base = ROOT / component["path"]
    excludes = set(component.get("excludeDirectories", []))
    if not base.is_dir():
        raise ValueError(f"missing vendored component directory: {component['path']}")
    files: list[Path] = []
    for path in base.rglob("*"):
        if not path.is_file():
            continue
        relative = path.relative_to(base)
        if relative.parts and relative.parts[0] in excludes:
            continue
        if ".git" in relative.parts:
            raise ValueError(f"Git metadata is forbidden in vendored source: {path}")
        files.append(path)
    return sorted(files, key=lambda item: item.relative_to(base).as_posix())


def component_manifest(component: dict) -> tuple[list[Path], str]:
    base = ROOT / component["path"]
    files = component_files(component)
    lines = [
        f"{sha256_file(path)} *{path.relative_to(base).as_posix()}"
        for path in files
    ]
    payload = ("\n".join(lines) + "\n").encode("utf-8")
    return files, hashlib.sha256(payload).hexdigest()


def git_object_id(kind: str, payload: bytes) -> bytes:
    header = f"{kind} {len(payload)}\0".encode("ascii")
    return hashlib.sha1(header + payload).digest()


def reconstructed_git_tree(component: dict, files: list[Path]) -> str:
    """Rebuild the official Git tree using only source-archive bytes and the lock."""
    base = ROOT / component["path"]
    executable_files = set(component.get("executableFiles", []))
    actual_files = {path.relative_to(base).as_posix() for path in files}
    unknown_executables = executable_files - actual_files
    if unknown_executables:
        raise ValueError(
            f"{component['id']} executableFiles contains unknown paths: "
            + ", ".join(sorted(unknown_executables))
        )

    root: dict[str, object] = {}
    for path in files:
        if path.is_symlink():
            raise ValueError(f"symbolic links require an explicit lock mode: {path}")
        relative = path.relative_to(base).as_posix()
        parts = relative.split("/")
        node = root
        for part in parts[:-1]:
            child = node.setdefault(part, {})
            if not isinstance(child, dict):
                raise ValueError(f"Git tree path collision in {component['id']}: {relative}")
            node = child
        leaf = parts[-1]
        if leaf in node:
            raise ValueError(f"duplicate Git tree path in {component['id']}: {relative}")
        mode = "100755" if relative in executable_files else "100644"
        node[leaf] = (mode, git_object_id("blob", path.read_bytes()))

    gitlinks = component.get("gitlinks", [])
    if not isinstance(gitlinks, list):
        raise ValueError(f"{component['id']} gitlinks must be a list")
    seen_gitlinks: set[str] = set()
    for gitlink in gitlinks:
        if not isinstance(gitlink, dict):
            raise ValueError(f"{component['id']} contains an invalid gitlink")
        relative = str(gitlink.get("path", ""))
        revision = str(gitlink.get("revision", ""))
        if not relative or "/" in relative or relative in seen_gitlinks:
            raise ValueError(f"{component['id']} contains an invalid gitlink path")
        if not GIT_OBJECT_RE.fullmatch(revision):
            raise ValueError(f"{component['id']} gitlink {relative} has invalid revision")
        if relative in root:
            raise ValueError(f"Git tree path collides with gitlink: {relative}")
        seen_gitlinks.add(relative)
        root[relative] = ("160000", bytes.fromhex(revision))

    def write_tree(node: dict[str, object]) -> bytes:
        entries: list[tuple[bytes, bool, str, bytes]] = []
        for name, value in node.items():
            name_bytes = name.encode("utf-8")
            if isinstance(value, dict):
                object_id = git_object_id("tree", write_tree(value))
                entries.append((name_bytes, True, "40000", object_id))
            else:
                mode, object_id = value
                entries.append((name_bytes, False, str(mode), bytes(object_id)))
        entries.sort(key=lambda entry: entry[0] + (b"/" if entry[1] else b""))
        return b"".join(
            mode.encode("ascii") + b" " + name + b"\0" + object_id
            for name, _, mode, object_id in entries
        )

    return git_object_id("tree", write_tree(root)).hex()


def parse_artifact_hashes(errors: list[str]) -> dict[str, str]:
    records: dict[str, str] = {}
    for number, line in enumerate(HASH_PATH.read_text(encoding="utf-8").splitlines(), 1):
        if not line:
            continue
        match = re.fullmatch(r"([0-9a-f]{64}) \*(.+)", line)
        if match is None:
            errors.append(f"invalid artifact hash line {number}")
            continue
        digest, relative = match.groups()
        if relative in records:
            errors.append(f"duplicate artifact hash path: {relative}")
        records[relative] = digest
    return records


def expected_source_records(lock: dict, errors: list[str]) -> dict[str, tuple[str, dict]]:
    expected: dict[str, tuple[str, dict]] = {}
    for component in lock["components"]:
        for key in (
            "repository", "revision", "tree", "path", "license", "licenseFile",
            "licenseSha256", "contentManifestSha256", "downloadLocation", "purl",
            "spdxPackageId",
        ):
            if not component.get(key):
                errors.append(f"{component.get('id', 'unknown')} missing lock field {key}")
        for key in ("revision", "tree", "licenseSha256", "contentManifestSha256"):
            value = str(component.get(key, ""))
            expected_length = 40 if key in ("revision", "tree") else 64
            if len(value) != expected_length or not re.fullmatch(r"[0-9a-f]+", value):
                errors.append(f"{component.get('id')} has invalid {key}")
        if not isinstance(component.get("executableFiles"), list):
            errors.append(f"{component.get('id')} lacks executableFiles mode inventory")

        files, manifest_digest = component_manifest(component)
        if len(files) != component.get("fileCount"):
            errors.append(
                f"{component['id']} file count drift: {len(files)} != {component.get('fileCount')}"
            )
        if manifest_digest != component.get("contentManifestSha256"):
            errors.append(f"{component['id']} content manifest drift")
        reconstructed_tree = reconstructed_git_tree(component, files)
        if reconstructed_tree != component.get("tree"):
            errors.append(
                f"{component['id']} official Git tree drift: "
                f"{reconstructed_tree} != {component.get('tree')}"
            )
        license_path = ROOT / component["licenseFile"]
        if not license_path.is_file():
            errors.append(f"{component['id']} license file missing")
        elif sha256_file(license_path) != component.get("licenseSha256"):
            errors.append(f"{component['id']} license hash drift")

        for path in files:
            relative = path.relative_to(ROOT).as_posix()
            digest = sha256_file(path)
            if relative in expected:
                errors.append(f"vendored file belongs to multiple components: {relative}")
            expected[relative] = (digest, component)
    return expected


def validate_artifact_hashes(
    expected: dict[str, tuple[str, dict]], records: dict[str, str], vendor_root: str,
    errors: list[str],
) -> None:
    recorded_vendor = {
        relative: digest for relative, digest in records.items()
        if relative.startswith(vendor_root + "/")
    }
    if set(recorded_vendor) != set(expected):
        missing = sorted(set(expected) - set(recorded_vendor))
        extra = sorted(set(recorded_vendor) - set(expected))
        if missing:
            errors.append(f"artifact hashes miss {len(missing)} vendored source files")
        if extra:
            errors.append(f"artifact hashes contain {len(extra)} stale vendored source files")
    for relative, (digest, _) in expected.items():
        if records.get(relative) != digest:
            errors.append(f"artifact hash mismatch: {relative}")


def validate_git_index(expected: dict[str, tuple[str, dict]], errors: list[str]) -> bool:
    try:
        probe = subprocess.run(
            ["git", "-C", str(ROOT), "rev-parse", "--is-inside-work-tree"],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            check=False,
        )
    except OSError:
        return False
    if probe.returncode != 0 or probe.stdout.strip() != "true":
        return False
    for relative, (digest, _) in expected.items():
        result = subprocess.run(
            ["git", "-C", str(ROOT), "show", f":{relative}"],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            check=False,
        )
        if result.returncode != 0:
            errors.append(f"vendored source is missing from the Git index: {relative}")
            continue
        if hashlib.sha256(result.stdout).hexdigest() != digest:
            errors.append(f"Git index normalized or changed vendored bytes: {relative}")
    return True


def validate_sbom(lock: dict, expected: dict[str, tuple[str, dict]], errors: list[str]) -> None:
    sbom = json.loads(SBOM_PATH.read_text(encoding="utf-8"))
    packages = sbom.get("packages", [])
    files = sbom.get("files", [])
    relationships = sbom.get("relationships", [])
    package_ids = {component["spdxPackageId"] for component in lock["components"]}

    for component in lock["components"]:
        matches = [
            package for package in packages
            if package.get("SPDXID") == component["spdxPackageId"]
        ]
        if len(matches) != 1:
            errors.append(f"SBOM package count mismatch: {component['id']}")
            continue
        package = matches[0]
        required = {
            "versionInfo": component["revision"],
            "downloadLocation": component["downloadLocation"],
            "licenseConcluded": component["license"],
            "licenseDeclared": component["license"],
            "filesAnalyzed": True,
        }
        for key, value in required.items():
            if package.get(key) != value:
                errors.append(f"SBOM {component['id']} has stale {key}")

    sbom_vendor_files = {
        record.get("fileName"): record for record in files
        if isinstance(record, dict)
        and str(record.get("SPDXID", "")).startswith(FILE_ID_PREFIX)
    }
    if set(sbom_vendor_files) != set(expected):
        errors.append("SBOM vendored file set does not match UPSTREAM.lock.json")
    expected_contains: set[tuple[str, str, str]] = set()
    for relative, (digest, component) in expected.items():
        record = sbom_vendor_files.get(relative)
        if record is None:
            continue
        checksums = [
            item.get("checksumValue") for item in record.get("checksums", [])
            if item.get("algorithm") == "SHA256"
        ]
        if checksums != [digest]:
            errors.append(f"SBOM checksum mismatch: {relative}")
        if record.get("licenseConcluded") != component["license"]:
            errors.append(f"SBOM license mismatch: {relative}")
        expected_contains.add((
            component["spdxPackageId"], "CONTAINS", record.get("SPDXID", ""),
        ))

    actual_relationships = {
        (
            str(item.get("spdxElementId", "")),
            str(item.get("relationshipType", "")),
            str(item.get("relatedSpdxElement", "")),
        )
        for item in relationships if isinstance(item, dict)
    }
    if not expected_contains.issubset(actual_relationships):
        errors.append("SBOM is missing Moonlight package CONTAINS relationships")
    root_dependencies = {
        ("SPDXRef-Package-RemoteDeskHarmonyOS", "DEPENDS_ON", package_id)
        for package_id in package_ids
    }
    common_dependencies = {
        (
            "SPDXRef-Package-Moonlight-Common-C", "DEPENDS_ON",
            "SPDXRef-Package-Moonlight-ENet",
        ),
        (
            "SPDXRef-Package-Moonlight-Common-C", "DEPENDS_ON",
            "SPDXRef-Package-Moonlight-Nanors",
        ),
    }
    if not (root_dependencies | common_dependencies).issubset(actual_relationships):
        errors.append("SBOM is missing Moonlight dependency relationships")
    if package_ids.intersection({
        package.get("SPDXID") for package in packages
        if package.get("licenseDeclared") == "NOASSERTION"
    }):
        errors.append("Moonlight SBOM package contains NOASSERTION license")


def validate_disclosures(lock: dict, errors: list[str]) -> None:
    notice = NOTICE_PATH.read_text(encoding="utf-8")
    source_offer = SOURCE_OFFER_PATH.read_text(encoding="utf-8")
    provenance = PROVENANCE_PATH.read_text(encoding="utf-8")
    notice_begin = "<!-- MOONLIGHT_VENDOR_NOTICE_BEGIN -->"
    notice_end = "<!-- MOONLIGHT_VENDOR_NOTICE_END -->"
    if notice.count(notice_begin) != 1 or notice.count(notice_end) != 1:
        errors.append("THIRD_PARTY_NOTICES.md must contain exactly one Moonlight vendor block")
    notice_anchor = (
        "| Hypium / Hamock | root package lock | OpenHarmony package terms | tests only |\n"
    )
    if notice_anchor + notice_begin + "\n" not in notice:
        errors.append("Moonlight notice block is not directly after the dependency table anchor")
    for component in lock["components"]:
        for label, text in (
            ("notice", notice), ("source offer", source_offer),
            ("provenance", provenance),
        ):
            if component["revision"] not in text:
                errors.append(f"{label} lacks {component['id']} revision")


def parse_arguments() -> object:
    parser = ArgumentParser(description=__doc__)
    parser.add_argument(
        "--print-build-receipt",
        nargs=2,
        metavar=("ABI", "ARCHIVE"),
        help="print one locked dual-ABI archive SHA-256 and exit",
    )
    return parser.parse_args()


def main() -> int:
    arguments = parse_arguments()
    if arguments.print_build_receipt:
        abi, archive = arguments.print_build_receipt
        try:
            receipt = load_lock()["buildReceipts"]["archives"][abi][archive]
        except (OSError, ValueError, KeyError, json.JSONDecodeError) as error:
            print(f"Moonlight vendor gate: {error}", file=sys.stderr)
            return 1
        print(receipt)
        return 0

    errors: list[str] = []
    index_checked = False
    try:
        lock = load_lock()
        vendor_root = str(lock.get("vendorRoot", ""))
        if vendor_root != "entry/src/main/cpp/moonlight/upstream/moonlight-common-c":
            errors.append("UPSTREAM.lock.json vendorRoot drifted")
        attributes = GIT_ATTRIBUTES_PATH.read_text(encoding="utf-8").splitlines()
        expected_attributes = (
            "entry/src/main/cpp/moonlight/upstream/moonlight-common-c/** -text "
            "whitespace=-blank-at-eol,-blank-at-eof,-space-before-tab,cr-at-eol"
        )
        if expected_attributes not in attributes:
            errors.append(".gitattributes does not preserve exact vendored source bytes")
        expected = expected_source_records(lock, errors)
        records = parse_artifact_hashes(errors)
        validate_artifact_hashes(expected, records, vendor_root, errors)
        index_checked = validate_git_index(expected, errors)
        validate_sbom(lock, expected, errors)
        validate_disclosures(lock, errors)
    except (OSError, ValueError, KeyError, json.JSONDecodeError) as error:
        errors.append(str(error))

    if errors:
        for error in errors:
            print(f"Moonlight vendor gate: {error}", file=sys.stderr)
        return 1
    index_status = "Git index checked" if index_checked else "source archive mode"
    print(
        "Moonlight vendor gate: PASS "
        f"(3 official Git trees, 117 exact source files, {index_status})"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
