"""Social Adapter Manager — fetches CEO-grade social intelligence via Google News RSS proxy.

Platforms: X/Twitter, Threads, TikTok, Instagram (English)
           抖音 (Douyin), 小紅書 (Xiaohongshu), Bilibili (Chinese)

Design:
- Dual strategy: site:platform for well-indexed platforms (X, TikTok)
                  reference queries for poorly-indexed (Threads, IG, Douyin, Xiaohongshu, Bilibili)
- CEO-grade quality filter at supply: rejects low-info, video-description-only, KOL promo
- Requires BigTech mention + actionable signal for every item
- Parallel fetch via ThreadPoolExecutor (stdlib) — wall time ~3-5s
- Generates adapter_selection_manifest.json + social_adapter_debug.log
- No new pip dependencies (stdlib only)
"""

from __future__ import annotations

import json
import logging as _sam_log
import re
import time
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import UTC, datetime
from pathlib import Path

_log = _sam_log.getLogger("ai_intel")

# ── Platform definitions ──────────────────────────────────────────────────
# strategy: "site" = use site:domain, "reference" = news articles mentioning the platform

_PLATFORMS = {
    # English social
    "x_twitter": {
        "display": "X/Twitter",
        "lang": "en",
        "social_type": "social_english",
        "strategy": "site",
        "queries": [
            "site:x.com OR site:twitter.com (NVIDIA OR OpenAI OR Google OR Anthropic OR Microsoft OR Meta) (AI OR model OR launch OR announce) when:1d",
            "site:x.com OR site:twitter.com (DeepSeek OR AMD OR Intel OR Apple OR Tesla) (AI OR chip OR GPU OR agent) when:1d",
        ],
    },
    "threads": {
        "display": "Threads",
        "lang": "en",
        "social_type": "social_english",
        "strategy": "reference",
        "queries": [
            "(Threads OR \"Meta Threads\") (AI OR model OR launch OR NVIDIA OR OpenAI OR Anthropic OR Google OR Microsoft) announcement when:1d",
            "Threads Meta AI (launch OR update OR announce OR model OR policy) when:1d",
        ],
    },
    "tiktok": {
        "display": "TikTok",
        "lang": "en",
        "social_type": "social_english",
        "strategy": "reference",
        "queries": [
            "TikTok (NVIDIA OR OpenAI OR Google OR Microsoft OR Meta OR Apple) (AI OR model OR launch OR chip OR ban OR policy) when:1d",
            "TikTok (AI OR tech OR chip) (NVIDIA OR DeepSeek OR Anthropic OR AMD) when:1d",
        ],
    },
    "instagram": {
        "display": "Instagram",
        "lang": "en",
        "social_type": "social_english",
        "strategy": "reference",
        "queries": [
            "(Instagram OR \"IG post\") (NVIDIA OR OpenAI OR Google OR Microsoft OR Meta OR Apple OR Tesla) (AI OR launch OR announce OR model) when:1d",
        ],
    },
    # Chinese social
    "douyin": {
        "display": "抖音",
        "lang": "zh",
        "social_type": "social_chinese",
        "strategy": "reference",
        "queries": [
            "(抖音 OR Douyin OR 字節跳動 OR ByteDance) (AI OR 人工智能 OR 大模型 OR 輝達 OR NVIDIA OR GPU OR 算力) when:1d",
        ],
    },
    "xiaohongshu": {
        "display": "小紅書",
        "lang": "zh",
        "social_type": "social_chinese",
        "strategy": "reference",
        "queries": [
            "(小紅書 OR Xiaohongshu OR RedNote) (AI OR 人工智能 OR 大模型 OR NVIDIA OR OpenAI OR 輝達) when:1d",
        ],
    },
    "bilibili": {
        "display": "Bilibili",
        "lang": "zh",
        "social_type": "social_chinese",
        "strategy": "reference",
        "queries": [
            "(Bilibili OR B站 OR 嗶哩嗶哩) (AI OR 人工智能 OR 大模型 OR NVIDIA OR OpenAI OR 輝達) when:1d",
            "(Bilibili OR B站) (DeepSeek OR 百度 OR 阿里 OR 騰訊 OR 字節) AI when:1d",
        ],
    },
}

# ── BigTech regex (EN + ZH) ───────────────────────────────────────────────

_BIGTECH_RE = re.compile(
    r"(?:\b(?:NVIDIA|OpenAI|Anthropic|Amazon|AWS|Google|Apple|Meta|Microsoft|"
    r"xAI|Mistral|DeepMind|Gemini|DeepSeek|Tesla|Qualcomm|Samsung|"
    r"Baidu|Alibaba|Cohere|Salesforce|Intel|AMD|Grok|Perplexity|Scale\s*AI|"
    r"HuggingFace|Hugging\s*Face|Stability\s*AI|Runway|ByteDance|Tencent|Huawei|"
    r"Jensen\s*Huang|Sam\s*Altman|Dario\s*Amodei|Sundar\s*Pichai|Demis\s*Hassabis|"
    r"Andy\s*Jassy|Tim\s*Cook|Mark\s*Zuckerberg|Satya\s*Nadella|Elon\s*Musk)\b"
    r"|輝達|英偉達|字節跳動|阿里巴巴|阿里雲|騰訊|百度|華為|三星|蘋果|谷歌|微軟|特斯拉"
    r"|商湯|科大訊飛|DeepSeek|黃仁勳|馬斯克|祖克柏|納德拉|庫克)",
    re.IGNORECASE,
)

# ── CEO-grade actionable keywords ────────────────────────────────────────

_ACTIONABLE_RE = re.compile(
    r"(?:\b(?:launch|released?|announc|ship(?:s|ped)?|roll\s*out|unveil|debut|update[ds]?|"
    r"partnership|acqui|invest|pricing|sell(?:s|ing)?|divest|"
    r"policy|regulat|executive\s+order|hearing|CEO|CTO|appointed|"
    r"benchmark|model|agent|chip|GPU|semiconductor|earnings|revenue|"
    r"ban|restrict|sanction|tariff|export\s+control|antitrust|"
    r"layoff|cut\s+jobs|restructur|strategy|expand|developer|"
    r"AI\s+(?:act|safety|risk|governance|law|copyright|lawsuit)|"
    r"sued|litigation|copyright|infring|compliance|"
    r"upgrade|commission|adjust|app\s+store)\b"
    r"|發布|推出|合作|投資|收購|出售|調整|政策|監管|算力|晶片|大模型|裁員|營收|禁令|制裁"
    r"|關稅|壟斷|併購|上市|IPO|升級|佣金|侵權|版權|開發者|策略|深化|戰略|評級)",
    re.IGNORECASE,
)

# ── Low-info / video-description / KOL promo patterns ────────────────────

_LOW_INFO_RE = re.compile(
    r"(?:subscribe|like\s+and\s+share|follow\s+for\s+more|turn\s+on\s+notification|"
    r"link\s+in\s+bio|check\s+out\s+my|use\s+code|discount|giveaway|unboxing|"
    r"關注|點讚|訂閱|分享|抽獎|開箱|優惠碼|折扣)",
    re.IGNORECASE,
)

_VIDEO_DESC_ONLY_RE = re.compile(
    r"(?:watch\s+(?:the\s+)?full\s+video|完整影片|看完整版|"
    r"(?:chapter|timestamp|目錄|時間軸)\s*[:：]|"
    r"(?:\d{1,2}:\d{2}(?::\d{2})?)\s*[-–—]\s*\w|"
    r"sponsored\s+by|#ad\b|#sponsored\b|"
    r"this\s+video\s+is\s+(?:sponsored|brought\s+to\s+you)|"
    r"本影片(?:由|贊助)|業配|合作影片)",
    re.IGNORECASE,
)

_KOL_PROMO_RE = re.compile(
    r"(?:(?:use|with)\s+(?:my\s+)?(?:code|link|coupon)|affiliate|referral\s+link|"
    r"paid\s+partnership|#ad\b|#sponsored\b|#業配|#合作|"
    r"(?:折扣|優惠|回饋)\s*(?:碼|連結|link)|"
    r"(?:limited\s+time|flash\s+sale|exclusive\s+deal))",
    re.IGNORECASE,
)


def _gnews_rss_url(query: str) -> str:
    q = urllib.parse.quote_plus(query)
    return f"https://news.google.com/rss/search?q={q}&hl=zh-TW&gl=TW&ceid=TW:zh-Hant"


def _parse_rss(xml_text: str) -> list[dict]:
    items = []
    try:
        root = ET.fromstring(xml_text.encode("utf-8", errors="replace"))
    except ET.ParseError:
        return items
    channel = root.find("channel")
    if channel is None:
        return items
    for item_el in channel.findall("item"):
        title_el = item_el.find("title")
        link_el = item_el.find("link")
        pub_el = item_el.find("pubDate")
        desc_el = item_el.find("description")
        title = (title_el.text or "").strip() if title_el is not None else ""
        link = (link_el.text or "").strip() if link_el is not None else ""
        pub = (pub_el.text or "").strip() if pub_el is not None else ""
        desc = (desc_el.text or "").strip() if desc_el is not None else ""
        if title and link:
            items.append({"title": title, "url": link, "published": pub, "description": desc})
    return items


def _is_ceo_grade(title: str, description: str) -> tuple[bool, str]:
    """Check if item meets CEO-grade intelligence threshold.
    Returns (pass, reject_reason).
    """
    blob = f"{title} {description}"

    if len(title.strip()) < 15:
        return False, "title_too_short"
    if _VIDEO_DESC_ONLY_RE.search(blob):
        return False, "video_description_only"
    if _KOL_PROMO_RE.search(blob):
        return False, "kol_promo"
    if _LOW_INFO_RE.search(title):
        return False, "low_info"
    if not _BIGTECH_RE.search(blob):
        return False, "no_bigtech_mention"
    if not _ACTIONABLE_RE.search(blob):
        return False, "no_actionable_signal"
    return True, ""


def _fetch_platform(platform_key: str, config: dict, debug_lines: list) -> list[dict]:
    """Fetch items for a single platform via Google News RSS. Returns raw dicts."""
    results = []
    seen_urls: set[str] = set()

    for query in config["queries"]:
        rss_url = _gnews_rss_url(query)
        try:
            req = urllib.request.Request(rss_url, headers={
                "User-Agent": "ai-intel-scraper/2.0",
            })
            with urllib.request.urlopen(req, timeout=8) as resp:
                xml_text = resp.read().decode("utf-8", errors="replace")
            entries = _parse_rss(xml_text)
            debug_lines.append(
                f"[{platform_key}] query={query[:80]}... entries={len(entries)}"
            )
            for entry in entries[:8]:
                url = entry["url"]
                if url in seen_urls:
                    continue
                seen_urls.add(url)

                passed, reason = _is_ceo_grade(entry["title"], entry["description"])
                if not passed:
                    debug_lines.append(
                        f"[{platform_key}] REJECT ({reason}): {entry['title'][:60]}"
                    )
                    continue

                entry["platform_key"] = platform_key
                entry["display_name"] = config["display"]
                entry["lang"] = config["lang"]
                entry["social_type"] = config["social_type"]
                results.append(entry)
            time.sleep(0.3)
        except Exception as exc:
            debug_lines.append(f"[{platform_key}] FETCH ERROR: {exc}")

    debug_lines.append(f"[{platform_key}] total_passed={len(results)}")
    return results


def fetch_social_items(project_root: str | Path) -> list[dict]:
    """Fetch CEO-grade social items from all 7 platforms in parallel.

    Returns list of dicts with keys:
        title, url, published, description, platform_key, display_name, lang, social_type

    Writes:
        outputs/social_adapter_debug.log
        outputs/adapter_selection_manifest.json
    """
    project_root = Path(project_root)
    t_start = time.time()
    debug_lines: list[str] = [
        f"=== Social Adapter Manager START === {datetime.now(UTC).isoformat()}",
        f"platforms={len(_PLATFORMS)}",
    ]

    all_items: list[dict] = []
    platform_results: dict[str, list[dict]] = {}
    platform_debug: dict[str, list[str]] = {}

    with ThreadPoolExecutor(max_workers=7) as executor:
        futures = {}
        for pkey, pconfig in _PLATFORMS.items():
            plines: list[str] = []
            platform_debug[pkey] = plines
            futures[executor.submit(_fetch_platform, pkey, pconfig, plines)] = pkey

        for future in as_completed(futures):
            pkey = futures[future]
            try:
                items = future.result(timeout=15)
                platform_results[pkey] = items
                all_items.extend(items)
            except Exception as exc:
                debug_lines.append(f"[{pkey}] THREAD ERROR: {exc}")
                platform_results[pkey] = []

    # Deduplicate by URL across platforms
    seen: set[str] = set()
    deduped: list[dict] = []
    for item in all_items:
        if item["url"] not in seen:
            seen.add(item["url"])
            deduped.append(item)

    elapsed = time.time() - t_start

    # Build manifest
    en_count = 0
    zh_count = 0
    en_platforms: list[str] = []
    zh_platforms: list[str] = []
    per_platform: dict = {}

    for pkey, pitems in platform_results.items():
        pconfig = _PLATFORMS[pkey]
        count = len(pitems)
        per_platform[pkey] = {
            "display": pconfig["display"],
            "lang": pconfig["lang"],
            "social_type": pconfig["social_type"],
            "strategy": pconfig["strategy"],
            "items_passed": count,
        }
        if count > 0:
            if pconfig["lang"] == "en":
                en_count += count
                en_platforms.append(pkey)
            else:
                zh_count += count
                zh_platforms.append(pkey)

    manifest = {
        "run_timestamp": datetime.now(UTC).isoformat(),
        "elapsed_sec": round(elapsed, 1),
        "platforms_attempted": len(_PLATFORMS),
        "platforms_with_results": sum(1 for v in platform_results.values() if v),
        "total_raw": len(all_items),
        "total_deduped": len(deduped),
        "social_english_count": en_count,
        "social_chinese_count": zh_count,
        "social_english_platforms": en_platforms,
        "social_chinese_platforms": zh_platforms,
        "total_social": en_count + zh_count,
        "per_platform": per_platform,
    }

    # Aggregate debug lines
    debug_lines.append("")
    for pkey in _PLATFORMS:
        for line in platform_debug.get(pkey, []):
            debug_lines.append(line)
        debug_lines.append("")

    debug_lines.append("=== SUMMARY ===")
    debug_lines.append(f"elapsed={elapsed:.1f}s")
    debug_lines.append(f"total_raw={len(all_items)} deduped={len(deduped)}")
    debug_lines.append(f"en_count={en_count} zh_count={zh_count}")
    debug_lines.append(f"en_platforms={en_platforms} zh_platforms={zh_platforms}")
    debug_lines.append("=== Social Adapter Manager END ===")

    # Write outputs
    out_dir = project_root / "outputs"
    out_dir.mkdir(parents=True, exist_ok=True)

    try:
        (out_dir / "social_adapter_debug.log").write_text(
            "\n".join(debug_lines), encoding="utf-8"
        )
    except Exception as exc:
        _log.warning("social_adapter_debug.log write failed: %s", exc)

    try:
        (out_dir / "adapter_selection_manifest.json").write_text(
            json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8"
        )
    except Exception as exc:
        _log.warning("adapter_selection_manifest.json write failed: %s", exc)

    _log.info(
        "[SocialAdapter] fetched %d items (en=%d zh=%d) in %.1fs from %d platforms",
        len(deduped), en_count, zh_count, elapsed, len(platform_results),
    )

    return deduped
