#!/usr/bin/env python3
"""Import a fixed, auditable Simple Icons batch into the TOTP manifest.

This is an explicit maintainer-time importer. Runtime validation never calls
the network. The generated JSON is the single source used by the ArkTS
manifest/registry generator.
"""

from __future__ import annotations

import hashlib
import io
import json
import re
import tarfile
import unicodedata
import urllib.request
import argparse
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
ASSET_ROOT = ROOT / "entry/src/main/resources/rawfile/totp-brands"
MANIFEST_PATH = ROOT / "entry/src/main/resources/rawfile/totp_brand_manifest.json"
VERSION = "16.21.0"
REPOSITORY = "https://github.com/simple-icons/simple-icons"
LICENSE_URL = f"{REPOSITORY}/blob/{VERSION}/LICENSE.md"
DISCLAIMER_URL = f"{REPOSITORY}/blob/{VERSION}/DISCLAIMER.md"
TARGET_ASSETS = 200
TARGET_ALIASES = 250
METADATA_SOURCE = f"{REPOSITORY}/blob/{VERSION}/data/simple-icons.json"

# Simple Icons deliberately omits some well-known marks for licensing or
# trademark reasons. These slugs are still high-signal brands available in the
# pinned review snapshot and are included explicitly instead of being pulled
# in by an alphabetical filler pass.
CURATED_SLUGS = [
    "bytedance", "dji", "honor", "kuaishou", "lenovo", "neteasecloudmusic",
    "oppo", "qq", "sinaweibo", "vivo", "xiaohongshu", "zhihu", "harmonyos",
    "deepin", "gitee", "csdn", "newyorktimes", "vmware", "cisco", "dell",
    "asus", "acer", "hp", "motorola", "pytorch", "tensorflow", "firebase",
    "supabase", "hashicorp", "gitbook", "snyk", "tradingview", "wise", "revolut",
    "bankofamerica", "chase", "wellsfargo", "cashapp",
]

# These are legitimate brands, but they are not high-signal consumer,
# enterprise, developer, or Chinese-market issuers for this app's first-party
# TOTP avatar set.
EXCLUDED_SLUGS = {"cloudron", "homebrew", "macports", "chocolatey"}

CURATED_ALIASES: dict[str, list[str]] = {
    "alipay": ["支付宝"],
    "alibabacloud": ["阿里云"],
    "baidu": ["百度"],
    "bilibili": ["哔哩哔哩", "B站"],
    "bytedance": ["字节跳动"],
    "csdn": ["CSDN"],
    "deepin": ["深度", "深度操作系统"],
    "dji": ["大疆"],
    "gitee": ["码云"],
    "harmonyos": ["鸿蒙"],
    "honor": ["荣耀"],
    "kuaishou": ["快手"],
    "lenovo": ["联想"],
    "meituan": ["美团"],
    "neteasecloudmusic": ["网易云音乐"],
    "oppo": ["欧珀"],
    "qq": ["QQ", "腾讯QQ"],
    "sinaweibo": ["微博", "新浪微博"],
    "taobao": ["淘宝"],
    "vivo": ["维沃"],
    "wechat": ["微信"],
    "xiaohongshu": ["小红书"],
    "xiaomi": ["小米"],
    "zhihu": ["知乎"],
}

SHORT_ALIAS_ALLOWLIST = {"qq", "b站"}


# Curated high-signal names. Entries not found in this list are only used as
# fixed-version, provenance-complete fillers after this list is exhausted;
# they are never fabricated aliases or placeholder files.
POPULAR_TITLES = [
    "Apple", "iCloud", "Google", "Google Cloud", "Microsoft", "Microsoft Azure",
    "Microsoft 365", "Amazon", "Amazon Web Services", "AWS", "Oracle", "IBM",
    "Red Hat", "Linux", "Ubuntu", "Debian", "Android", "Samsung", "Huawei",
    "Xiaomi", "Sony", "GitHub", "GitLab", "Bitbucket", "Docker", "Kubernetes",
    "NPM", "Node.js", "Python", "Rust", "Go", "Java", "C", "C++", "Swift",
    "TypeScript", "Visual Studio Code", "JetBrains", "IntelliJ IDEA", "Vercel",
    "Netlify", "Heroku", "DigitalOcean", "Cloudflare", "Sentry", "Datadog",
    "Grafana", "Prometheus", "Jenkins", "CircleCI", "Travis CI", "GitHub Actions",
    "Slack", "Discord", "Zoom", "Microsoft Teams", "Notion", "Figma", "Trello",
    "Jira", "Confluence", "Atlassian", "Asana", "Linear", "Monday.com", "Airtable",
    "Dropbox", "Box", "Evernote", "Canva", "Adobe", "Miro", "ClickUp", "Basecamp",
    "Facebook", "Instagram", "WhatsApp", "X", "Twitter", "LinkedIn", "TikTok",
    "Reddit", "Pinterest", "Snapchat", "Telegram", "WeChat", "Weibo", "YouTube",
    "Twitch", "Tumblr", "Mastodon", "Threads", "Bilibili", "Douban", "Vimeo",
    "Netflix", "Spotify", "Apple Music", "SoundCloud", "Deezer", "Tidal", "Steam",
    "Epic Games", "PlayStation", "Xbox", "Nintendo", "Roku", "HBO", "Disney+",
    "PayPal", "Stripe", "Visa", "Mastercard", "American Express", "Square",
    "Shopify", "eBay", "Walmart", "Target", "Costco", "Coinbase", "Binance",
    "Kraken", "OKX", "Alipay", "Taobao", "Alibaba Cloud", "Baidu", "DingTalk",
    "Feishu", "Tencent", "Tencent QQ", "JD.com", "Pinduoduo", "Meituan", "NetEase",
    "1Password", "Bitwarden", "Authy", "Okta", "LastPass", "Proton", "Proton Mail",
    "NordVPN", "ExpressVPN", "OpenVPN", "WireGuard", "Tailscale", "Tor", "Duo Security",
    "RustDesk", "TeamViewer", "AnyDesk", "Remote Desktop", "VNC", "OpenSSH", "PuTTY",
    "Let’s Encrypt", "Yubico", "YubiKey", "Kaspersky", "Norton", "McAfee", "CrowdStrike",
    "Uber", "Lyft", "Airbnb", "Booking.com", "Expedia", "Tripadvisor", "DoorDash",
    "McDonald's", "Starbucks", "Nike", "Adidas", "Coca-Cola", "Pepsi", "IKEA",
    "Lego", "Puma", "Zara", "H&M", "Uniqlo", "Toyota", "Tesla", "BMW", "Mercedes-Benz",
    "Ford", "General Motors", "Uber Eats", "DHL", "FedEx", "UPS", "USPS",
    "Wikipedia", "Wikimedia", "The New York Times", "BBC", "CNN", "The Guardian",
    "Reuters", "Medium", "Substack", "Product Hunt", "Hacker News", "Stack Overflow",
    "Stack Exchange", "Kaggle", "Coursera", "Udemy", "edX", "Duolingo", "Wikipedia",
    "WordPress", "Ghost", "Drupal", "Wix", "Squarespace", "Webflow", "Mailchimp",
    "SendGrid", "Twilio", "HubSpot", "Salesforce", "SAP", "ServiceNow", "Zendesk",
    "Freshdesk", "Intercom", "Pipedrive", "ZoomInfo", "Snowflake", "MongoDB", "MySQL",
    "PostgreSQL", "Redis", "SQLite", "MariaDB", "Elastic", "Elasticsearch", "Apache",
    "NGINX", "Terraform", "Ansible", "Puppet", "Chef", "Pulumi", "Rancher", "Istio",
    "Argo", "Flux", "Home Assistant", "Raspberry Pi", "Arduino", "NVIDIA", "AMD", "Intel",
    "Qualcomm", "OpenAI", "Hugging Face", "Mistral AI", "DeepMind", "Perplexity",
    "Midjourney", "DALL-E", "Unity", "Unreal Engine", "Blender", "Godot", "Figma",
    "Sketch", "Framer", "Dribbble", "Behance", "Unsplash", "Google Drive", "Google Docs",
    "Google Sheets", "Google Meet", "Google Analytics", "Google Play", "App Store",
    "Huawei Cloud", "Aliyun", "Tencent Cloud", "Bing", "DuckDuckGo", "Brave", "Firefox",
    "Google Chrome", "Safari", "Opera", "Microsoft Edge", "RustDesk Server", "HestiaCP",
    "Cloudron", "Plesk", "cPanel", "Homebrew", "MacPorts", "Chocolatey", "Scoop",
]


# Login domains are an explicit audit result, never a projection of the
# Simple Icons artwork/source URL.  A missing entry is intentional: the
# issuer may have a website, but no reliable evidence that its root domain is
# the domain users put in an authenticator account field.  The URLs below are
# official login/account pages captured at import time and are reviewed again
# by the manifest validator; they are not fetched at runtime.
AUDITED_LOGIN_DOMAINS: dict[str, dict[str, object]] = {
    "apple": {
        "domains": ["apple.com"],
        "sourceUrl": "https://account.apple.com/",
        "evidence": "Apple Account login is served by Apple's account scope; apple.com is the exact issuer domain.",
    },
    "icloud": {
        "domains": ["icloud.com"],
        "sourceUrl": "https://www.icloud.com/",
        "evidence": "iCloud web sign-in is served by icloud.com; Wikimedia is artwork provenance only and is not an issuer domain.",
    },
    "google": {
        "domains": ["google.com", "gmail.com"],
        "sourceUrl": "https://accounts.google.com/",
        "evidence": "Google Account sign-in covers google.com accounts and Gmail addresses; both domains are exact, reviewed issuer domains.",
    },
    "googlecloud": {
        "domains": ["cloud.google.com"],
        "sourceUrl": "https://console.cloud.google.com/",
        "evidence": "Google Cloud Console is the official account entry point for Google Cloud users.",
    },
    "github": {
        "domains": ["github.com"],
        "sourceUrl": "https://github.com/login",
        "evidence": "GitHub's official login is on github.com.",
    },
    "gitlab": {
        "domains": ["gitlab.com"],
        "sourceUrl": "https://gitlab.com/users/sign_in",
        "evidence": "GitLab.com sign-in is on gitlab.com.",
    },
    "docker": {
        "domains": ["docker.com"],
        "sourceUrl": "https://hub.docker.com/login",
        "evidence": "Docker Hub is Docker's official account/login service; docker.com is the reviewed issuer domain.",
    },
    "npm": {
        "domains": ["npmjs.com"],
        "sourceUrl": "https://www.npmjs.com/login",
        "evidence": "npm's official web login is on npmjs.com.",
    },
    "cloudflare": {
        "domains": ["cloudflare.com"],
        "sourceUrl": "https://dash.cloudflare.com/login",
        "evidence": "Cloudflare dashboard login is the official account entry point for cloudflare.com customers.",
    },
    "discord": {
        "domains": ["discord.com"],
        "sourceUrl": "https://discord.com/login",
        "evidence": "Discord's official login is on discord.com.",
    },
    "zoom": {
        "domains": ["zoom.us"],
        "sourceUrl": "https://zoom.us/signin",
        "evidence": "Zoom's official account sign-in is on zoom.us.",
    },
    "notion": {
        "domains": ["notion.so"],
        "sourceUrl": "https://www.notion.so/login",
        "evidence": "Notion's official login is on notion.so.",
    },
    "figma": {
        "domains": ["figma.com"],
        "sourceUrl": "https://www.figma.com/login",
        "evidence": "Figma's official login is on figma.com.",
    },
    "asana": {
        "domains": ["asana.com"],
        "sourceUrl": "https://app.asana.com/-/login",
        "evidence": "Asana's official account login is served under asana.com.",
    },
    "linear": {
        "domains": ["linear.app"],
        "sourceUrl": "https://linear.app/login",
        "evidence": "Linear's official login is on linear.app.",
    },
    "dropbox": {
        "domains": ["dropbox.com"],
        "sourceUrl": "https://www.dropbox.com/login",
        "evidence": "Dropbox's official account login is on dropbox.com.",
    },
    "facebook": {
        "domains": ["facebook.com"],
        "sourceUrl": "https://www.facebook.com/login/",
        "evidence": "Facebook's official login is on facebook.com.",
    },
    "instagram": {
        "domains": ["instagram.com"],
        "sourceUrl": "https://www.instagram.com/accounts/login/",
        "evidence": "Instagram's official login is on instagram.com.",
    },
    "whatsapp": {
        "domains": ["whatsapp.com"],
        "sourceUrl": "https://web.whatsapp.com/",
        "evidence": "WhatsApp's official web account entry point is on whatsapp.com.",
    },
    "tiktok": {
        "domains": ["tiktok.com"],
        "sourceUrl": "https://www.tiktok.com/login",
        "evidence": "TikTok's official login is on tiktok.com.",
    },
    "reddit": {
        "domains": ["reddit.com"],
        "sourceUrl": "https://www.reddit.com/login/",
        "evidence": "Reddit's official login is on reddit.com; redditinc.com is corporate brand provenance only.",
    },
    "telegram": {
        "domains": ["telegram.org"],
        "sourceUrl": "https://web.telegram.org/",
        "evidence": "Telegram's official web account entry point is on telegram.org.",
    },
    "youtube": {
        "domains": ["youtube.com"],
        "sourceUrl": "https://accounts.google.com/",
        "evidence": "YouTube account sign-in uses Google's official account entry point; youtube.com is the exact service domain.",
    },
    "paypal": {
        "domains": ["paypal.com"],
        "sourceUrl": "https://www.paypal.com/signin",
        "evidence": "PayPal's official account login is on paypal.com.",
    },
    "stripe": {
        "domains": ["stripe.com"],
        "sourceUrl": "https://dashboard.stripe.com/login",
        "evidence": "Stripe Dashboard login is the official account entry point under stripe.com.",
    },
    "shopify": {
        "domains": ["shopify.com"],
        "sourceUrl": "https://accounts.shopify.com/",
        "evidence": "Shopify's official account entry point is under shopify.com.",
    },
    "coinbase": {
        "domains": ["coinbase.com"],
        "sourceUrl": "https://login.coinbase.com/",
        "evidence": "Coinbase's official account login is under coinbase.com.",
    },
    "binance": {
        "domains": ["binance.com"],
        "sourceUrl": "https://accounts.binance.com/login",
        "evidence": "Binance's official account login is under binance.com.",
    },
    "okta": {
        "domains": ["okta.com"],
        "sourceUrl": "https://login.okta.com/",
        "evidence": "Okta's official login/account service is under okta.com.",
    },
    "proton": {
        "domains": ["proton.me"],
        "sourceUrl": "https://account.proton.me/login",
        "evidence": "Proton's official account login is under proton.me.",
    },
    "tailscale": {
        "domains": ["tailscale.com"],
        "sourceUrl": "https://login.tailscale.com/admin",
        "evidence": "Tailscale's official account service is under tailscale.com.",
    },
    "rustdesk": {
        "domains": ["rustdesk.com"],
        "sourceUrl": "https://rustdesk.com/",
        "evidence": "RustDesk's official account/service domain is rustdesk.com; no community-hosted source is used.",
    },
    "teamviewer": {
        "domains": ["teamviewer.com"],
        "sourceUrl": "https://login.teamviewer.com/",
        "evidence": "TeamViewer's official account login is under teamviewer.com.",
    },
    "anydesk": {
        "domains": ["anydesk.com"],
        "sourceUrl": "https://my.anydesk.com/",
        "evidence": "AnyDesk's official account service is under anydesk.com.",
    },
    "duolingo": {
        "domains": ["duolingo.com"],
        "sourceUrl": "https://www.duolingo.com/log-in",
        "evidence": "Duolingo's official login is on duolingo.com; a Duo issuer must never match this by substring.",
    },
    "wordpress": {
        "domains": ["wordpress.com"],
        "sourceUrl": "https://wordpress.com/log-in",
        "evidence": "WordPress.com's official account login is on wordpress.com; wordpress.org is project provenance only.",
    },
    "wix": {
        "domains": ["wix.com"],
        "sourceUrl": "https://users.wix.com/signin",
        "evidence": "Wix's official account entry point is under wix.com.",
    },
    "twilio": {
        "domains": ["twilio.com"],
        "sourceUrl": "https://console.twilio.com/",
        "evidence": "Twilio Console login is the official account entry point under twilio.com.",
    },
    "hubspot": {
        "domains": ["hubspot.com"],
        "sourceUrl": "https://app.hubspot.com/login",
        "evidence": "HubSpot's official account login is under hubspot.com.",
    },
    "mongodb": {
        "domains": ["mongodb.com"],
        "sourceUrl": "https://account.mongodb.com/account/login",
        "evidence": "MongoDB's official account login is under mongodb.com.",
    },
    "redis": {
        "domains": ["redis.io"],
        "sourceUrl": "https://cloud.redis.io/",
        "evidence": "Redis Cloud's official account entry point is the redis.io service domain.",
    },
    "openai": {
        "domains": ["openai.com"],
        "sourceUrl": "https://auth.openai.com/",
        "evidence": "OpenAI's official account service is under openai.com.",
    },
    "huggingface": {
        "domains": ["huggingface.co"],
        "sourceUrl": "https://huggingface.co/login",
        "evidence": "Hugging Face's official login is on huggingface.co.",
    },
    "blender": {
        "domains": ["blender.org"],
        "sourceUrl": "https://www.blender.org/login/",
        "evidence": "Blender's official account/login service is under blender.org.",
    },
    "alipay": {
        "domains": ["alipay.com"],
        "sourceUrl": "https://auth.alipay.com/",
        "evidence": "Alipay's official account service is under alipay.com.",
    },
    "alibabacloud": {
        "domains": ["aliyun.com", "alibabacloud.com"],
        "sourceUrl": "https://signin.aliyun.com/",
        "evidence": "Alibaba Cloud's official account service uses aliyun.com and alibabacloud.com.",
    },
    "baidu": {
        "domains": ["baidu.com"],
        "sourceUrl": "https://passport.baidu.com/",
        "evidence": "Baidu's official account service is under baidu.com.",
    },
    "bilibili": {
        "domains": ["bilibili.com"],
        "sourceUrl": "https://passport.bilibili.com/",
        "evidence": "Bilibili's official account service is under bilibili.com.",
    },
    "bytedance": {
        "domains": ["bytedance.com"],
        "sourceUrl": "https://www.bytedance.com/",
        "evidence": "ByteDance's official corporate domain is bytedance.com.",
    },
    "csdn": {
        "domains": ["csdn.net"],
        "sourceUrl": "https://passport.csdn.net/",
        "evidence": "CSDN's official account service is under csdn.net.",
    },
    "deepin": {
        "domains": ["deepin.org"],
        "sourceUrl": "https://www.deepin.org/",
        "evidence": "deepin's official project domain is deepin.org.",
    },
    "dji": {
        "domains": ["dji.com"],
        "sourceUrl": "https://www.dji.com/",
        "evidence": "DJI's official account/service domain is dji.com.",
    },
    "gitee": {
        "domains": ["gitee.com"],
        "sourceUrl": "https://gitee.com/login",
        "evidence": "Gitee's official login is on gitee.com.",
    },
    "harmonyos": {
        "domains": ["harmonyos.com"],
        "sourceUrl": "https://www.harmonyos.com/",
        "evidence": "HarmonyOS's official project domain is harmonyos.com.",
    },
    "honor": {
        "domains": ["honor.com"],
        "sourceUrl": "https://www.honor.com/",
        "evidence": "HONOR's official service domain is honor.com.",
    },
    "kuaishou": {
        "domains": ["kuaishou.com"],
        "sourceUrl": "https://www.kuaishou.com/",
        "evidence": "Kuaishou's official service domain is kuaishou.com.",
    },
    "lenovo": {
        "domains": ["lenovo.com"],
        "sourceUrl": "https://passport.lenovo.com/",
        "evidence": "Lenovo's official account service is under lenovo.com.",
    },
    "meituan": {
        "domains": ["meituan.com"],
        "sourceUrl": "https://www.meituan.com/",
        "evidence": "Meituan's official service domain is meituan.com.",
    },
    "neteasecloudmusic": {
        "domains": ["163.com"],
        "sourceUrl": "https://music.163.com/",
        "evidence": "NetEase Cloud Music's official service is under 163.com.",
    },
    "oppo": {
        "domains": ["oppo.com"],
        "sourceUrl": "https://www.oppo.com/",
        "evidence": "OPPO's official service domain is oppo.com.",
    },
    "qq": {
        "domains": ["qq.com"],
        "sourceUrl": "https://aq.qq.com/",
        "evidence": "Tencent QQ's official account service is under qq.com.",
    },
    "sinaweibo": {
        "domains": ["weibo.com"],
        "sourceUrl": "https://weibo.com/",
        "evidence": "Sina Weibo's official service domain is weibo.com.",
    },
    "vivo": {
        "domains": ["vivo.com"],
        "sourceUrl": "https://www.vivo.com/",
        "evidence": "vivo's official service domain is vivo.com.",
    },
    "xiaohongshu": {
        "domains": ["xiaohongshu.com"],
        "sourceUrl": "https://www.xiaohongshu.com/",
        "evidence": "Xiaohongshu's official service domain is xiaohongshu.com.",
    },
    "xiaomi": {
        "domains": ["mi.com", "xiaomi.com"],
        "sourceUrl": "https://account.xiaomi.com/",
        "evidence": "Xiaomi's official account service uses mi.com and xiaomi.com.",
    },
    "zhihu": {
        "domains": ["zhihu.com"],
        "sourceUrl": "https://www.zhihu.com/",
        "evidence": "Zhihu's official service domain is zhihu.com.",
    },
}


def norm(value: str) -> str:
    value = unicodedata.normalize("NFKC", value).strip().lower()
    value = re.sub(r"[._-]+", " ", value)
    return re.sub(r"\s+", " ", value)


def compact(value: str) -> str:
    return re.sub(r"\s+", "", value)


def safe_alias(value: str) -> bool:
    compact_value = compact(norm(value))
    if compact_value in SHORT_ALIAS_ALLOWLIST:
        return True
    if len(compact_value) >= 3:
        return True
    return len(compact_value) >= 2 and all("\u4e00" <= char <= "\u9fff" for char in compact_value)


def add_unique(values: list[str], value: str) -> None:
    if not value or not safe_alias(value):
        return
    if norm(value) not in {norm(existing) for existing in values}:
        values.append(value)


def load_upstream() -> tuple[list[dict], dict[str, tuple[str, bytes]]]:
    metadata_url = f"{REPOSITORY}/raw/{VERSION}/data/simple-icons.json"
    metadata = json.loads(urllib.request.urlopen(metadata_url).read().decode("utf-8"))
    tar_url = f"https://codeload.github.com/simple-icons/simple-icons/tar.gz/refs/tags/{VERSION}"
    archive_bytes = urllib.request.urlopen(tar_url).read()
    icons: dict[str, tuple[str, bytes]] = {}
    with tarfile.open(fileobj=io.BytesIO(archive_bytes), mode="r:gz") as archive:
        for member in archive.getmembers():
            if not member.isfile() or "/icons/" not in member.name or not member.name.endswith(".svg"):
                continue
            match = re.search(r"/icons/([^/]+)\.svg$", member.name)
            if not match:
                continue
            raw = archive.extractfile(member).read()
            title_match = re.search(rb"<title>(.*?)</title>", raw)
            if title_match:
                title = title_match.group(1).decode("utf-8")
                icons[norm(title)] = (match.group(1), raw)
    return metadata, icons


def load_review_snapshot(review_dir: Path) -> tuple[list[dict], dict[str, tuple[str, bytes]]]:
    """Load only the maintainer-reviewed local snapshot; never fetches assets."""
    catalog_path = review_dir / "catalog.json"
    icons_root = review_dir / "icons"
    if not catalog_path.is_file() or not icons_root.is_dir():
        raise SystemExit(f"invalid review snapshot: {review_dir}")
    catalog = json.loads(catalog_path.read_text(encoding="utf-8"))
    upstream = catalog.get("upstream", {})
    if upstream.get("name") != "simple-icons" or upstream.get("version") != VERSION:
        raise SystemExit("review snapshot must be Simple Icons 16.21.0")
    reviewed_entries = [
        entry for entry in catalog.get("entries", [])
        if entry.get("packagingEligible") is True
    ]
    expected_count = int(catalog.get("packagingEligibleCount", len(reviewed_entries)))
    if len(reviewed_entries) != expected_count:
        raise SystemExit(
            f"review snapshot eligible count mismatch: {len(reviewed_entries)} != {expected_count}"
        )

    metadata: list[dict] = []
    icons: dict[str, tuple[str, bytes]] = {}
    for review_entry in reviewed_entries:
        slug = str(review_entry.get("slug", ""))
        title = str(review_entry.get("title", ""))
        icon_path = icons_root / f"{slug}.svg"
        if not slug or not title or not icon_path.is_file():
            raise SystemExit(f"review snapshot entry is incomplete: {slug}")
        raw = icon_path.read_bytes()
        expected_bytes = int(review_entry.get("bytes", 0))
        expected_sha256 = str(review_entry.get("sha256", ""))
        actual_sha256 = hashlib.sha256(raw).hexdigest()
        if len(raw) != expected_bytes or actual_sha256 != expected_sha256:
            raise SystemExit(f"reviewed asset hash/size mismatch: {icon_path}")
        title_key = norm(title)
        if title_key in icons:
            raise SystemExit(f"review snapshot title collision: {title}")
        source_url = str(review_entry.get("sourceUrl", ""))
        metadata.append({
            "title": title,
            "slug": slug,
            "hex": str(review_entry.get("hex", "")).upper(),
            "aliases": review_entry.get("aliases") or {},
            # The reviewed snapshot records the fixed community-artwork source;
            # no official-logo claim is inferred when brand guidance is absent.
            "source": source_url,
            "guidelines": source_url,
        })
        icons[title_key] = (slug, raw)
    return metadata, icons


def index_metadata(metadata: list[dict]) -> dict[str, dict]:
    index: dict[str, dict] = {}
    # Direct upstream titles win over another brand's historical aka value.
    # This keeps independent brands such as Terraform and OpenTofu distinct.
    for entry in metadata:
        title = entry.get("title", "")
        if title:
            index[norm(title)] = entry
    for entry in metadata:
        keys = []
        keys.extend(entry.get("aliases", {}).get("aka", []))
        for key in keys:
            if key:
                index.setdefault(norm(key), entry)
    return index


def eligible(entry: dict) -> bool:
    license_data = entry.get("license")
    return license_data is None or license_data.get("type") == "CC0-1.0"


def make_entry(metadata: dict, slug: str, data: bytes) -> dict:
    title = metadata["title"]
    aliases: list[str] = []
    add_unique(aliases, title)
    for alias in metadata.get("aliases", {}).get("aka", []):
        add_unique(aliases, alias)
    for alias in metadata.get("aliases", {}).get("old", []):
        add_unique(aliases, alias)
    for alias in metadata.get("aliases", {}).get("loc", {}).values():
        add_unique(aliases, alias)
    for alias in CURATED_ALIASES.get(slug, []):
        add_unique(aliases, alias)
    source = metadata.get("source") or f"{REPOSITORY}/blob/{VERSION}/icons/{slug}.svg"
    guidelines = metadata.get("guidelines") or source
    domain_audit = AUDITED_LOGIN_DOMAINS.get(slug)
    if domain_audit is None:
        domains: list[str] = []
        # The pinned metadata is the audit record for a reviewed *absence*;
        # artwork/brand-source URLs must never masquerade as login evidence.
        domain_source = METADATA_SOURCE
        domain_evidence = (
            "Reviewed at import time: no reliable official login-domain evidence was identified; "
            "exactDomains intentionally empty."
        )
    else:
        domains = [str(domain) for domain in domain_audit["domains"]]
        domain_source = str(domain_audit["sourceUrl"])
        domain_evidence = str(domain_audit["evidence"])
    payload = data if data.endswith(b"\n") else data + b"\n"
    asset = f"totp-brands/{slug}.svg"
    return {
        "brandId": slug,
        "displayName": title,
        "aliases": aliases,
        "exactDomains": domains,
        "aliasReviewed": True,
        "aliasSourceUrl": METADATA_SOURCE,
        "aliasEvidence": (
            "Aliases are limited to the title and pinned Simple Icons metadata aka/old/loc values; "
            "slug-derived variants are excluded."
        ),
        "domainReviewed": True,
        "domainSourceUrl": domain_source,
        "domainEvidence": domain_evidence,
        "localAsset": asset,
        "assetBytes": len(payload),
        "sourceType": "simple-icons",
        "sourceUrl": f"{REPOSITORY}/blob/{VERSION}/icons/{slug}.svg",
        "brandSourceUrl": source,
        "brandGuidelines": guidelines,
        "upstreamVersion": VERSION,
        "sha256": hashlib.sha256(payload).hexdigest(),
        "licenseType": "CC0-1.0",
        "licenseUrl": LICENSE_URL,
        "trademarkGuidelines": (
            f"{DISCLAIMER_URL}; community brand glyph only; not an official logo; "
            "consult brandGuidelines before distribution"
        ),
        "officialAssetVerified": False,
        "brandColor": "#" + metadata["hex"].upper(),
        "_payload": payload,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--review-dir",
        type=Path,
        help="import the already reviewed local Simple Icons snapshot instead of fetching upstream",
    )
    parser.add_argument(
        "--prune",
        action="store_true",
        help="remove direct rawfile SVGs that are not in the explicit curated set",
    )
    args = parser.parse_args()
    metadata, icons = (
        load_review_snapshot(args.review_dir)
        if args.review_dir is not None
        else load_upstream()
    )
    by_name = index_metadata(metadata)
    selected: list[dict] = []
    selected_ids: set[str] = set()
    missing_curated: list[str] = []
    by_slug: dict[str, tuple[dict, tuple[str, bytes]]] = {}
    for meta in metadata:
        icon = icons.get(norm(meta.get("title", "")))
        if icon is not None:
            by_slug[icon[0]] = (meta, icon)

    def add_requested(label: str, meta: dict | None, icon: tuple[str, bytes] | None) -> None:
        if meta is None or icon is None:
            missing_curated.append(label)
            return
        slug, data = icon
        if slug in EXCLUDED_SLUGS or slug in selected_ids or not eligible(meta):
            return
        item = make_entry(meta, slug, data)
        if not item["aliases"]:
            missing_curated.append(label)
            return
        selected.append(item)
        selected_ids.add(slug)

    for requested in POPULAR_TITLES:
        meta = by_name.get(norm(requested))
        icon = icons.get(norm(meta.get("title", ""))) if meta is not None else None
        add_requested(requested, meta, icon)
    for slug in CURATED_SLUGS:
        pair = by_slug.get(slug)
        add_requested(slug, pair[0] if pair is not None else None, pair[1] if pair is not None else None)

    if len(selected) < 200:
        raise SystemExit(f"only {len(selected)} explicit curated assets resolved")

    # Keep ambiguous aliases out of the resolver namespace. Direct upstream
    # titles win over another brand's historical/locale alias; a collision
    # without a direct title is removed from every brand.
    alias_owners: dict[str, set[str]] = {}
    title_owners: dict[str, set[str]] = {}
    for item in selected:
        title_key = norm(item["displayName"])
        title_owners.setdefault(title_key, set()).add(item["brandId"])
        for alias in item["aliases"]:
            alias_owners.setdefault(norm(alias), set()).add(item["brandId"])
    ambiguous_aliases = {
        key for key, owners in alias_owners.items() if len(owners) > 1
    }
    removed_ambiguous_aliases: list[dict[str, str]] = []
    for item in selected:
        kept_aliases: list[str] = []
        for alias in item["aliases"]:
            key = norm(alias)
            owners = title_owners.get(key, set())
            if key not in ambiguous_aliases or owners == {item["brandId"]}:
                kept_aliases.append(alias)
            else:
                removed_ambiguous_aliases.append({
                    "brandId": item["brandId"],
                    "alias": alias,
                    "reason": "ambiguous exact alias; direct title retained for its owner",
                })
        item["aliases"] = kept_aliases

    # Keep explicitly audited domains disjoint from aliases: the resolver's
    # namespace is one exact-key namespace, so a domain that is already an
    # alias would make the match ambiguous. This is the only domain filtering
    # performed here; no source host is ever promoted to a login domain.
    used_aliases_domains: set[str] = {
        norm(alias) for item in selected for alias in item["aliases"]
    }
    removed_audited_domains: list[dict[str, str]] = []
    for item in selected:
        unique_domains: list[str] = []
        for domain in item["exactDomains"]:
            key = norm(domain)
            if key not in used_aliases_domains:
                unique_domains.append(domain)
                used_aliases_domains.add(key)
            else:
                removed_audited_domains.append({
                    "brandId": item["brandId"],
                    "domain": domain,
                    "reason": "alias/domain namespace collision",
                })
        item["exactDomains"] = unique_domains
    existing_manifest: dict = {}
    if MANIFEST_PATH.is_file():
        existing_manifest = json.loads(MANIFEST_PATH.read_text(encoding="utf-8"))
    manifest = {
        "manifestVersion": f"totp-brand-manifest-2026.08.03-si-{VERSION}-r7-mainstream-logo-catalog",
        "hashScope": "SHA-256 of the packaged local asset bytes, including the final newline",
        "upstream": {
            "name": "simple-icons",
            "version": VERSION,
            "repository": REPOSITORY,
            "license": "CC0-1.0",
            "licenseUrl": LICENSE_URL,
            "disclaimerUrl": DISCLAIMER_URL,
        },
        "completionTargets": {
            "uniqueLocalAssets": TARGET_ASSETS,
            "aliasesAndDomains": TARGET_ALIASES,
            "policy": (
                "Only fixed-version provenance-complete assets; no official-logo claim for community glyphs; "
                "login domains are independently audited and may be intentionally empty; quantity targets are "
                "reported separately from semantic validity."
            ),
        },
        "runtimePolicy": (
            "Runtime uses only this bundled manifest and rawfiles for exact issuer/domain matches; "
            "there is no remote brand lookup. Unknown or unmatched suppliers render initials. "
            "The explicit mainstream set is supplemented by reviewed fixed-commit logo-catalog overrides."
        ),
        "officialOverrides": existing_manifest.get("officialOverrides", []),
        "entries": selected,
    }

    ASSET_ROOT.mkdir(parents=True, exist_ok=True)
    # Write the bytes that were reviewed and hash-checked above. No generated
    # or user-provided asset can silently enter the packaged set.
    for item in selected:
        payload = item.pop("_payload")
        slug = item["brandId"]
        (ASSET_ROOT / f"{slug}.svg").write_bytes(payload)
    if args.prune:
        selected_files = {f"{item['brandId']}.svg" for item in selected}
        for path in ASSET_ROOT.glob("*.svg"):
            if path.name not in selected_files:
                path.unlink()
    MANIFEST_PATH.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    alias_count = len({norm(alias) for item in selected for alias in item["aliases"]})
    domain_count = len({norm(domain) for item in selected for domain in item["exactDomains"]})
    print(json.dumps({
        "selected": len(selected),
        "aliasNames": sum(len(item["aliases"]) for item in selected),
        "exactDomains": domain_count,
        "aliasesAndDomains": alias_count + domain_count,
        "auditedDomainEntries": sum(1 for item in selected if item["exactDomains"]),
        "removedAmbiguousAliases": removed_ambiguous_aliases,
        "removedAuditedDomains": removed_audited_domains,
        "missingCuratedNames": missing_curated,
        "preservedOfficialOverrides": len(manifest["officialOverrides"]),
    }, ensure_ascii=False, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
