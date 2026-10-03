"""PD12M (Spawning, CDLA-Permissive-2.0 metadata; per-row licence) as the bulk route to Commons/iNaturalist
CC0 originals.

Why: upload.wikimedia.org admits only ~7-8 requests/minute from an unauthenticated client and answered our
originals with 600 s blocks. PD12M hosts byte-identical copies (md5 checked per file) on its own S3 bucket
"to avoid placing an undue burden on the original image hosts" (PD12M README), so bulk fetching from there
is the intended route.

Rights handling:
  * only rows whose licence is CC0 (https://creativecommons.org/publicdomain/zero/1.0/) are used; Public
    Domain Mark rows are skipped (PDM is a label, not a licence: counsel question);
  * evaluation files are additionally traced back to their Commons file page by sha1 (Commons API
    list=allimages&aisha1) and re-checked there (data_tools/commons.py rules), so PH-1 carries the same
    per-file evidence as a direct Commons download;
  * training files rely on PD12M's per-row CC0 record plus camera EXIF (to exclude scans and artworks).
"""
from __future__ import annotations

import glob
import hashlib
import io
import os
import re
import time
from concurrent.futures import ThreadPoolExecutor

import requests
from PIL import Image

AUTO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PD12M_DIR = os.path.join(AUTO_ROOT, "data", "pd12m")
CC0_URL = "https://creativecommons.org/publicdomain/zero/1.0/"
S3_WORKERS = 6
HEADER_BYTES = 131072
EXIF_TAGS = {"make": 271, "model": 272, "software": 305, "datetime": 306, "artist": 315, "copyright": 33432}

# Caption keywords only NOMINATE candidates for review; the class is assigned by eye on contact sheets.
NOMINATION_PATTERNS = {
    "night": r"\bat night\b|\bnight ?time\b|\bnight sky\b|\blit up at night\b|\billuminated at night\b|\bnight\b",
    "sunset": r"\bsunset\b|\bsunrise\b|\bgolden hour\b|\bdusk\b|\bsetting sun\b",
    "backlit": r"\bsilhouett|\bbacklit\b|\bagainst the (?:bright )?sun\b|\bsun (?:is )?shining (?:through|behind)\b|\blens flare\b|\bsun behind\b",
    "portrait": r"\bportrait of\b|\bselfie\b|\b(?:a|the) (?:young |old |smiling )?(?:woman|man|girl|boy|child|person)\b|\bsmiling\b|\bfaces?\b",
    "landscape": r"\blandscape\b|\bmountains?\b|\bvalley\b|\blake\b|\bhills\b|\bcountryside\b",
    "indoor_mixed": r"\binterior\b|\binside (?:a|an|the)\b|\brestaurant\b|\bkitchen\b|\blobby\b|\bcaf[eé]\b|\bliving room\b|\bshop\b",
}
NOT_A_PHOTO = re.compile(r"\bpainting\b|\bdrawing\b|\billustration\b|\bengraving\b|\bmap\b|\bposter\b|\bsketch\b|"
                         r"\bmanuscript\b|\bdocument\b|\bstamp\b|\bcoin\b|\bblack and white\b|\bbl(?:ack|ue)print\b|"
                         r"\bdiagram\b|\blogo\b|\bscreenshot\b|\bprint of\b|\bwoodcut\b|\blithograph", re.I)


def load_rows(shards: list[int], sources: tuple[str, ...]) -> list[dict]:
    import pyarrow as pa
    import pyarrow.compute as pc
    import pyarrow.parquet as pq
    rows = []
    for shard in shards:
        table = pq.read_table(os.path.join(PD12M_DIR, f"pd12m.{shard:03d}.parquet"))
        # Filter in Arrow first: converting whole shards to Python objects costs gigabytes.
        mask = pc.and_(pc.and_(pc.is_in(table["source"], value_set=pa.array(list(sources))),
                               pc.equal(table["license"], CC0_URL)),
                       pc.equal(table["mime_type"], "image/jpeg"))
        for row in table.filter(pc.fill_null(mask, False)).to_pylist():
            row["shard"] = shard
            rows.append(row)
    return rows


def _session() -> requests.Session:
    session = requests.Session()
    session.headers["User-Agent"] = "LightlyAutoResearch/0.2 (offline photo-correction research)"
    return session


def header_exif(row: dict, session: requests.Session) -> dict:
    """EXIF from the first 128 KiB (HTTP Range), so non-phone candidates are never downloaded in full."""
    for attempt in range(4):
        try:
            response = session.get(row["url"], headers={"Range": f"bytes=0-{HEADER_BYTES - 1}"}, timeout=60)
            if response.status_code in (200, 206):
                break
        except requests.RequestException:
            pass
        time.sleep(2 * (attempt + 1))
    else:
        return {"error": "fetch"}
    try:
        exif = Image.open(io.BytesIO(response.content)).getexif()
        sub = exif.get_ifd(0x8769)
    except Exception:  # noqa: BLE001 - unreadable header: treated as no EXIF
        return {"error": "parse"}
    out = {name: str(exif.get(tag, "") or "").strip("\x00 ").strip() for name, tag in EXIF_TAGS.items()}
    out["datetime_original"] = str(sub.get(36867, "") or out["datetime"]).strip("\x00 ")
    return out


def headers_for(rows: list[dict]) -> list[dict]:
    session = _session()
    with ThreadPoolExecutor(max_workers=S3_WORKERS) as pool:
        return list(pool.map(lambda r: header_exif(r, session), rows))


def download_verified(row: dict, destination: str, session: requests.Session | None = None) -> str:
    """Full download once; md5 must match PD12M's record. Returns sha1 (the Commons lookup key)."""
    if not os.path.exists(destination):
        os.makedirs(os.path.dirname(destination), exist_ok=True)
        session = session or _session()
        for attempt in range(4):
            try:
                response = session.get(row["url"], timeout=120)
                if response.status_code == 200:
                    break
            except requests.RequestException:
                pass
            time.sleep(3 * (attempt + 1))
        else:
            raise RuntimeError(f"download failed {row['url']}")
        if hashlib.md5(response.content).hexdigest() != row["hash"]:
            raise ValueError(f"md5 mismatch {row['url']}")
        open(destination + ".part", "wb").write(response.content)
        os.replace(destination + ".part", destination)
    return hashlib.sha1(open(destination, "rb").read()).hexdigest()


def session_key(row: dict, exif: dict) -> str:
    """Capture-session proxy for split grouping: camera model + capture date. Rows without a date fall back to
    their own id (no grouping possible)."""
    date = (exif.get("datetime_original") or "")[:10]
    if date and exif.get("model"):
        return f"{exif.get('make', '')}|{exif['model']}|{date}".lower()
    return "id:" + row["id"]
