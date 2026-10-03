"""Wikimedia Commons search + licence/EXIF filtering for CC0 and public-domain photographs.

Licence selection is done twice, independently, and a file must pass both:
  1. structured data: the CirrusSearch query requires `haswbstatement:P275=Q6938433` (copyright licence = CC0)
     or `haswbstatement:P6216=Q19652` (copyright status = public domain);
  2. the rendered licence in extmetadata `LicenseShortName` must be CC0 or a public-domain tag we accept.
Files imported from Unsplash or Pexels are excluded even when they are CC0 on Commons: DEV-22 is Unsplash, and
excluding both sources avoids any argument about later stock-site terms and any overlap with DEV-22.
Personality-rights warnings ({{Personality rights}}) are recorded per file, not filtered: they restrict
endorsement/commercial use of a person's likeness, which matters for training and marketing, not for
internal evaluation. docs/v1/auto-data.md carries the counsel question.
"""
from __future__ import annotations

import hashlib
import json
import os
import re
import time

import requests

API = "https://commons.wikimedia.org/w/api.php"
# Wikimedia's User-Agent policy asks for an identifying UA with a contact route.
USER_AGENT = "LightlyAutoResearch/0.2 (offline photo-correction research; contact: repository owner) python-requests"
CC0_QUERY = "haswbstatement:P275=Q6938433"
PD_QUERY = "haswbstatement:P6216=Q19652"
# One CirrusSearch clause for both (haswbstatement accepts '|' as OR), so each term costs one query.
CC0_OR_PD_QUERY = "haswbstatement:P275=Q6938433|P6216=Q19652"
# Wikimedia rate limits (mediawiki.org/wiki/Wikimedia_APIs/Rate_limits): an unauthenticated client without
# contact details in its User-Agent gets ~10 API requests/minute. We stay under that, serially, and honour
# Retry-After on 429. Media (upload.wikimedia.org) is fetched at a gentler but separate pace.
API_MIN_INTERVAL_S = 6.5
MEDIA_MIN_INTERVAL_S = 1.0
ACCEPTED_LICENCE_PATTERNS = [r"^CC0$", r"^CC0 1\.0$", r"^Public domain$", r"^PD-self$", r"^PD-user$", r"^PD-author$",
                             r"^PD-USGov.*", r"^PD US Government$"]
EXCLUDED_SOURCE_PATTERN = re.compile(r"unsplash|pexels|pixabay|stocksnap|burst\.shopify", re.I)
PHONE_MAKES = {"apple": "Apple", "samsung": "Samsung", "google": "Google", "xiaomi": "Xiaomi", "redmi": "Xiaomi",
               "poco": "Xiaomi", "motorola": "Motorola", "nothing": "Nothing", "oneplus": "OnePlus", "huawei": "Huawei",
               "honor": "Honor", "oppo": "OPPO", "vivo": "vivo", "realme": "realme", "lge": "LG", "lg electronics": "LG",
               "sony": "Sony", "hmd global": "Nokia", "nokia": "Nokia", "fairphone": "Fairphone", "asus": "ASUS",
               "htc": "HTC", "zte": "ZTE", "tecno": "TECNO", "infinix": "Infinix", "itel": "itel", "meizu": "Meizu"}
# Sony makes both phones and cameras; only its Xperia phones (model codes like "SO-xx", "Xperia", "G8341") count.
SONY_PHONE_MODEL = re.compile(r"xperia|^so-|^sov|^[cdefghj]\d{4}|^xq-", re.I)
EDIT_SOFTWARE = re.compile(r"lightroom|photoshop|snapseed|gimp|darktable|rawtherapee|vsco|capture one|luminar|affinity|"
                           r"photoscape|picsart|lightroom|dxo|on1|paint\.net|pixelmator|polarr", re.I)


def _session() -> requests.Session:
    session = requests.Session()
    session.headers["User-Agent"] = USER_AGENT
    return session


_last_request_at = {"api": 0.0, "media": 0.0}


def polite_get(session: requests.Session, url: str, kind: str, params: dict | None = None,
               timeout: int = 120, attempts: int = 8) -> requests.Response:
    """GET with a per-kind minimum interval and Retry-After / exponential back-off on 429 and 5xx."""
    interval = API_MIN_INTERVAL_S if kind == "api" else MEDIA_MIN_INTERVAL_S
    response = None
    for attempt in range(attempts):
        wait = _last_request_at[kind] + interval - time.time()
        if wait > 0:
            time.sleep(wait)
        _last_request_at[kind] = time.time()
        response = session.get(url, params=params, timeout=timeout)
        if response.status_code == 200:
            return response
        if response.status_code in (429, 500, 502, 503, 504):
            retry_after = response.headers.get("Retry-After", "")
            time.sleep(float(retry_after) if retry_after.isdigit() else min(30 * 2 ** attempt, 600))
            continue
        break
    response.raise_for_status()
    raise RuntimeError(f"giving up on {url}: HTTP {response.status_code}")


def _metadata_dict(entries) -> dict:
    out = {}
    for entry in entries or []:
        value = entry.get("value")
        if isinstance(value, list):  # nested EXIF blocks are not needed
            continue
        out[entry["name"]] = value
    return out


def _strip_html(text: str) -> str:
    return re.sub(r"<[^>]+>", "", text or "").strip()


def licence_accepted(short_name: str) -> bool:
    return any(re.match(p, short_name.strip()) for p in ACCEPTED_LICENCE_PATTERNS)


def phone_brand(make: str, model: str) -> str | None:
    make_l = (make or "").strip().lower()
    for key, brand in PHONE_MAKES.items():
        if make_l.startswith(key):
            if brand == "Sony" and not SONY_PHONE_MODEL.search(model or ""):
                return None
            if brand == "Samsung" and re.match(r"^(nx|wb|ex|st|pl|es)\d", (model or "").lower()):
                return None  # Samsung NX/compact cameras
            if brand == "ASUS" and "zenfone" not in (model or "").lower() and not (model or "").upper().startswith(("ASUS_", "ZS", "ZE", "AI")):
                return None
            return brand
    return None


def record_from_page(page: dict) -> dict | None:
    info = (page.get("imageinfo") or [None])[0]
    if not info:
        return None
    ext = info.get("extmetadata") or {}
    meta = _metadata_dict(info.get("metadata"))

    def ext_value(key):
        return _strip_html(str((ext.get(key) or {}).get("value", "")))

    return {
        "title": page["title"], "pageid": page["pageid"], "descriptionurl": info.get("descriptionurl"),
        "url": (info.get("url") or "").split("?")[0], "sha1": info.get("sha1"), "bytes": info.get("size"),
        "width": info.get("width"), "height": info.get("height"), "mime": info.get("mime"),
        "licence_short": ext_value("LicenseShortName"), "licence_url": ext_value("LicenseUrl"),
        "usage_terms": ext_value("UsageTerms"), "artist": ext_value("Artist")[:200], "credit": ext_value("Credit")[:200],
        "categories": ext_value("Categories"), "restrictions": ext_value("Restrictions"),
        "description": ext_value("ImageDescription")[:300],
        "make": str(meta.get("Make", "")).strip(), "model": str(meta.get("Model", "")).strip(),
        "software": str(meta.get("Software", "")).strip(), "datetime_original": str(meta.get("DateTimeOriginal", "")),
        "orientation": meta.get("Orientation"),
        # Commons renders thumbnails upright (EXIF orientation applied) and in sRGB.
        "thumburl": (info.get("thumburl") or "").split("?")[0] or None,
    }


def search(query: str, limit: int, cache_dir: str, thumb_width: int | None = None) -> list[dict]:
    """Run a Commons file search with imageinfo; results are cached by query so harvesting is reproducible."""
    os.makedirs(cache_dir, exist_ok=True)
    cache_key = f"{query}|{limit}" + (f"|thumb{thumb_width}" if thumb_width else "")
    cache_path = os.path.join(cache_dir, hashlib.sha1(cache_key.encode()).hexdigest() + ".json")
    if os.path.exists(cache_path):
        return json.load(open(cache_path))["records"]
    session = _session()
    records, params = [], {
        "action": "query", "format": "json", "generator": "search", "gsrnamespace": 6, "gsrsearch": query,
        "gsrlimit": 50, "prop": "imageinfo", "iiprop": "url|size|sha1|mime|extmetadata|metadata",
        "iiextmetadatafilter": "LicenseShortName|LicenseUrl|UsageTerms|Artist|Credit|Categories|Restrictions|ImageDescription"}
    if thumb_width:
        params["iiurlwidth"] = thumb_width
    while len(records) < limit:
        data = polite_get(session, API, "api", params=params).json()
        pages = sorted((data.get("query") or {}).get("pages", {}).values(), key=lambda p: p.get("index", 0))
        records += [r for r in (record_from_page(p) for p in pages) if r]
        if "continue" not in data:
            break
        params.update(data["continue"])
    records = records[:limit]
    json.dump({"query": query, "limit": limit, "fetched_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
               "records": records}, open(cache_path, "w"))
    return records


def eligible(record: dict, require_phone: bool) -> tuple[bool, str]:
    if record.get("mime") not in ("image/jpeg", "image/png", "image/webp", "image/heic"):
        return False, "mime"
    if not licence_accepted(record.get("licence_short", "")):
        return False, f"licence {record.get('licence_short')!r}"
    provenance = " ".join(str(record.get(k, "")) for k in ("title", "credit", "artist", "categories", "description"))
    if EXCLUDED_SOURCE_PATTERN.search(provenance):
        return False, "stock-site import"
    if EDIT_SOFTWARE.search(record.get("software", "")):
        return False, "edited in " + record["software"]
    if require_phone and not phone_brand(record.get("make", ""), record.get("model", "")):
        return False, "not a phone capture"
    if min(record.get("width") or 0, record.get("height") or 0) < 1000:
        return False, "too small"
    return True, ""


def download(url: str, destination: str, expected_sha1: str | None) -> str:
    """Download once (idempotent), verify Commons' sha1, return the sha256 of the bytes on disk."""
    if not os.path.exists(destination):
        os.makedirs(os.path.dirname(destination), exist_ok=True)
        session = _session()
        response = polite_get(session, url, "media")
        tmp = destination + ".part"
        open(tmp, "wb").write(response.content)
        os.replace(tmp, destination)
    content = open(destination, "rb").read()
    if expected_sha1 and hashlib.sha1(content).hexdigest() != expected_sha1:
        os.remove(destination)
        raise ValueError(f"sha1 mismatch for {url}")
    return hashlib.sha256(content).hexdigest()
