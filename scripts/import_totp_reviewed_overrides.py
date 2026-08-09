#!/usr/bin/env python3
"""Import reviewed mainstream logo-catalog overrides into the TOTP manifest.

This is a maintainer-time, offline-from-runtime import. The source directory
must be a local checkout or extracted archive of the pinned svglogos commit.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
ASSET_ROOT = ROOT / "entry/src/main/resources/rawfile/totp-brands/catalog"
MANIFEST_PATH = ROOT / "entry/src/main/resources/rawfile/totp_brand_manifest.json"
REPOSITORY = "https://github.com/gilbarbara/logos"
COMMIT = "4de741f8503d5e81abf5dfa05214690e938296bf"
LICENSE_URL = f"{REPOSITORY}/blob/{COMMIT}/LICENSE.txt"


CATALOG_BRANDS: list[dict[str, object]] = [
    {
        "brandId": "aws",
        "displayName": "AWS",
        "sourceAsset": "aws.svg",
        "aliases": ["AWS", "Amazon Web Services", "Amazon AWS"],
        "exactDomains": ["aws.amazon.com", "amazonaws.com"],
        "brandSourceUrl": "https://aws.amazon.com/",
        "brandGuidelines": "https://brand.amazon.com/aws/",
        "brandColor": "#232F3E",
    },
    {
        "brandId": "slack",
        "displayName": "Slack",
        "sourceAsset": "slack-icon.svg",
        "aliases": ["Slack", "Slack Technologies"],
        "exactDomains": ["slack.com"],
        "brandSourceUrl": "https://slack.com/",
        "brandGuidelines": "https://slack.com/intl/en-gb/media-kit",
        "brandColor": "#4A154B",
    },
    {
        "brandId": "adobe",
        "displayName": "Adobe",
        "sourceAsset": "adobe-icon.svg",
        "aliases": ["Adobe", "Adobe Creative Cloud"],
        "exactDomains": ["adobe.com"],
        "brandSourceUrl": "https://www.adobe.com/",
        "brandGuidelines": "https://www.adobe.com/about-adobe/brand-guidelines.html",
        "brandColor": "#FF0000",
    },
    {
        "brandId": "openai",
        "displayName": "OpenAI",
        "sourceAsset": "openai-icon.svg",
        "aliases": ["OpenAI", "ChatGPT"],
        "exactDomains": ["openai.com", "chatgpt.com"],
        "brandSourceUrl": "https://openai.com/",
        "brandGuidelines": "https://openai.com/brand/",
        "brandColor": "#000000",
    },
    {
        "brandId": "anthropic",
        "displayName": "Anthropic",
        "sourceAsset": "anthropic-icon.svg",
        "aliases": ["Anthropic"],
        "exactDomains": ["anthropic.com"],
        "brandSourceUrl": "https://www.anthropic.com/",
        "brandGuidelines": "https://www.anthropic.com/brand",
        "brandColor": "#D97757",
    },
    {
        "brandId": "claude",
        "displayName": "Claude",
        "sourceAsset": "claude-icon.svg",
        "aliases": ["Claude", "Claude AI"],
        "exactDomains": ["claude.ai"],
        "brandSourceUrl": "https://claude.ai/",
        "brandGuidelines": "https://www.anthropic.com/brand",
        "brandColor": "#D97757",
    },
    {
        "brandId": "oracle",
        "displayName": "Oracle",
        "sourceAsset": "oracle.svg",
        "aliases": ["Oracle"],
        "exactDomains": ["oracle.com"],
        "brandSourceUrl": "https://www.oracle.com/",
        "brandGuidelines": "https://www.oracle.com/legal/trademarks.html",
        "brandColor": "#C74634",
    },
    {
        "brandId": "ibm",
        "displayName": "IBM",
        "sourceAsset": "ibm.svg",
        "aliases": ["IBM"],
        "exactDomains": ["ibm.com"],
        "brandSourceUrl": "https://www.ibm.com/",
        "brandGuidelines": "https://www.ibm.com/legal/us/en/copytrade.shtml",
        "brandColor": "#0F62FE",
    },
    {
        "brandId": "salesforce",
        "displayName": "Salesforce",
        "sourceAsset": "salesforce.svg",
        "aliases": ["Salesforce"],
        "exactDomains": ["salesforce.com"],
        "brandSourceUrl": "https://www.salesforce.com/",
        "brandGuidelines": "https://www.salesforce.com/news/stories/salesforce-brand-assets/",
        "brandColor": "#00A1E0",
    },
    {
        "brandId": "twilio",
        "displayName": "Twilio",
        "sourceAsset": "twilio-icon.svg",
        "aliases": ["Twilio"],
        "exactDomains": ["twilio.com"],
        "brandSourceUrl": "https://www.twilio.com/",
        "brandGuidelines": "https://brand.twilio.com/",
        "brandColor": "#F22F46",
    },
    {
        "brandId": "android",
        "displayName": "Android",
        "sourceAsset": "android-icon.svg",
        "aliases": ["Android"],
        "exactDomains": ["android.com"],
        "brandSourceUrl": "https://www.android.com/",
        "brandGuidelines": "https://developer.android.com/distribute/marketing-tools/brand-guidelines",
        "brandColor": "#3DDC84",
    },
    {
        "brandId": "microsoftazure",
        "displayName": "Microsoft Azure",
        "sourceAsset": "microsoft-azure.svg",
        "aliases": ["Microsoft Azure", "Azure"],
        "exactDomains": ["azure.com"],
        "brandSourceUrl": "https://azure.microsoft.com/",
        "brandGuidelines": "https://www.microsoft.com/en-us/legal/intellectualproperty/trademarks",
        "brandColor": "#0078D4",
    },
    {
        "brandId": "microsoftteams",
        "displayName": "Microsoft Teams",
        "sourceAsset": "microsoft-teams.svg",
        "aliases": ["Microsoft Teams", "Teams"],
        "exactDomains": ["teams.microsoft.com"],
        "brandSourceUrl": "https://www.microsoft.com/microsoft-teams/",
        "brandGuidelines": "https://www.microsoft.com/en-us/legal/intellectualproperty/trademarks",
        "brandColor": "#6264A7",
    },
    {
        "brandId": "microsoftedge",
        "displayName": "Microsoft Edge",
        "sourceAsset": "microsoft-edge.svg",
        "aliases": ["Microsoft Edge", "Edge"],
        "exactDomains": ["microsoftedge.com"],
        "brandSourceUrl": "https://www.microsoft.com/edge/",
        "brandGuidelines": "https://www.microsoft.com/en-us/legal/intellectualproperty/trademarks",
        "brandColor": "#0C59F2",
    },
    {
        "brandId": "deepseek",
        "displayName": "DeepSeek",
        "sourceAsset": "deepseek-icon.svg",
        "aliases": ["DeepSeek", "深度求索"],
        "exactDomains": ["deepseek.com"],
        "brandSourceUrl": "https://www.deepseek.com/",
        "brandGuidelines": "https://www.deepseek.com/",
        "brandColor": "#4D6BFE",
    },
    {
        "brandId": "unionpay",
        "displayName": "UnionPay",
        "sourceAsset": "unionpay.svg",
        "aliases": ["UnionPay", "中国银联", "银联"],
        "exactDomains": ["unionpay.com", "unionpay.com.cn"],
        "brandSourceUrl": "https://www.unionpayintl.com/",
        "brandGuidelines": "https://www.unionpayintl.com/",
        "brandColor": "#0052A4",
    },
    {
        "brandId": "firebase",
        "displayName": "Firebase",
        "sourceAsset": "firebase-icon.svg",
        "aliases": ["Firebase"],
        "exactDomains": ["firebase.google.com"],
        "brandSourceUrl": "https://firebase.google.com/",
        "brandGuidelines": "https://firebase.google.com/brand-guidelines",
        "brandColor": "#FFCA28",
    },
    {
        "brandId": "supabase",
        "displayName": "Supabase",
        "sourceAsset": "supabase-icon.svg",
        "aliases": ["Supabase"],
        "exactDomains": ["supabase.com"],
        "brandSourceUrl": "https://supabase.com/",
        "brandGuidelines": "https://supabase.com/brand",
        "brandColor": "#3ECF8E",
    },
    {
        "brandId": "hashicorp",
        "displayName": "HashiCorp",
        "sourceAsset": "hashicorp-icon.svg",
        "aliases": ["HashiCorp"],
        "exactDomains": ["hashicorp.com"],
        "brandSourceUrl": "https://www.hashicorp.com/",
        "brandGuidelines": "https://www.hashicorp.com/brand",
        "brandColor": "#5C2D91",
    },
    {
        "brandId": "vmware",
        "displayName": "VMware",
        "sourceAsset": "vmware.svg",
        "aliases": ["VMware"],
        "exactDomains": ["vmware.com"],
        "brandSourceUrl": "https://www.vmware.com/",
        "brandGuidelines": "https://www.vmware.com/brand",
        "brandColor": "#607078",
    },
    {
        "brandId": "snyk",
        "displayName": "Snyk",
        "sourceAsset": "snyk.svg",
        "aliases": ["Snyk"],
        "exactDomains": ["snyk.io"],
        "brandSourceUrl": "https://snyk.io/",
        "brandGuidelines": "https://snyk.io/brand",
        "brandColor": "#1E1E1E",
    },
    {
        "brandId": "auth0",
        "displayName": "Auth0",
        "sourceAsset": "auth0-icon.svg",
        "aliases": ["Auth0", "Auth0 by Okta"],
        "exactDomains": ["auth0.com"],
        "brandSourceUrl": "https://auth0.com/",
        "brandGuidelines": "https://auth0.com/brand",
        "brandColor": "#EB5424",
    },
    {
        "brandId": "zoho",
        "displayName": "Zoho",
        "sourceAsset": "zoho.svg",
        "aliases": ["Zoho", "Zoho Corporation"],
        "exactDomains": ["zoho.com"],
        "brandSourceUrl": "https://www.zoho.com/",
        "brandGuidelines": "https://www.zoho.com/brand-guidelines.html",
        "brandColor": "#F15B2A",
    },
    {
        "brandId": "zapier",
        "displayName": "Zapier",
        "sourceAsset": "zapier.svg",
        "aliases": ["Zapier"],
        "exactDomains": ["zapier.com"],
        "brandSourceUrl": "https://zapier.com/",
        "brandGuidelines": "https://zapier.com/brand",
        "brandColor": "#FF4F00",
    },
    {
        "brandId": "authy",
        "displayName": "Authy",
        "sourceAsset": "authy.svg",
        "aliases": ["Authy", "Twilio Authy"],
        "exactDomains": ["authy.com"],
        "brandSourceUrl": "https://www.authy.com/",
        "brandGuidelines": "https://www.twilio.com/en-us/legal/trademark-list",
        "brandColor": "#F22E46",
    },
]


def safe_svg(data: bytes) -> bool:
    text = data.decode("utf-8", errors="ignore").lower()
    if any(marker in text for marker in ("<script", "<foreignobject", "<iframe", "<object", "<embed", "<image", "javascript:", "data:")):
        return False
    return re.search(r"(?:href|xlink:href)\s*=\s*[\"']https?://", text) is None


def build_entry(spec: dict[str, object], source_root: Path) -> dict[str, object]:
    source_asset = str(spec["sourceAsset"])
    source_path = source_root / source_asset
    if not source_path.is_file():
        raise SystemExit(f"missing reviewed catalog asset: {source_path}")
    raw = source_path.read_bytes()
    if not safe_svg(raw):
        raise SystemExit(f"unsafe SVG content: {source_path}")
    payload = raw if raw.endswith(b"\n") else raw + b"\n"
    brand_id = str(spec["brandId"])
    return {
        "brandId": brand_id,
        "displayName": str(spec["displayName"]),
        "aliases": list(spec["aliases"]),
        "exactDomains": list(spec["exactDomains"]),
        "localAsset": f"totp-brands/catalog/{brand_id}.svg",
        "assetBytes": len(payload),
        "sha256": hashlib.sha256(payload).hexdigest(),
        "brandColor": str(spec["brandColor"]),
        "sourceType": "svglogos-catalog",
        "sourceUrl": f"{REPOSITORY}/blob/{COMMIT}/logos/{source_asset}",
        "brandSourceUrl": str(spec["brandSourceUrl"]),
        "brandGuidelines": str(spec["brandGuidelines"]),
        "upstreamVersion": COMMIT,
        "licenseType": "CC0-1.0",
        "licenseUrl": LICENSE_URL,
        "trademarkGuidelines": (
            f"{REPOSITORY}/blob/{COMMIT}/README.md; CC0 catalog vector; "
            "not an official brand-kit assertion; use only for supplier identification"
        ),
        "officialAssetVerified": False,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source-dir", type=Path, required=True,
                        help="extracted svglogos repository logos/ directory")
    args = parser.parse_args()
    manifest = json.loads(MANIFEST_PATH.read_text(encoding="utf-8"))
    existing = manifest.get("officialOverrides", [])
    existing_ids = {str(entry["brandId"]) for entry in existing}
    entries: list[dict[str, object]] = [entry for entry in existing
                                        if str(entry["brandId"]) not in {
                                            str(spec["brandId"]) for spec in CATALOG_BRANDS
                                        }]
    ASSET_ROOT.mkdir(parents=True, exist_ok=True)
    imported: list[dict[str, object]] = []
    for spec in CATALOG_BRANDS:
        entry = build_entry(spec, args.source_dir)
        destination = ROOT / "entry/src/main/resources/rawfile" / entry["localAsset"]
        destination.parent.mkdir(parents=True, exist_ok=True)
        source_path = args.source_dir / str(spec["sourceAsset"])
        destination.write_bytes(source_path.read_bytes() if source_path.read_bytes().endswith(b"\n")
                               else source_path.read_bytes() + b"\n")
        entries.append(entry)
        imported.append(entry)
    manifest["officialOverrides"] = entries
    manifest["manifestVersion"] = "totp-brand-manifest-2026.08.03-si-16.21.0-r8-mainstream-logo-catalog"
    MANIFEST_PATH.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({
        "catalogOverrides": len(imported),
        "officialOverrides": len(entries),
        "replacedExistingCatalogIds": sorted(existing_ids & {str(spec["brandId"]) for spec in CATALOG_BRANDS}),
    }, ensure_ascii=False, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
