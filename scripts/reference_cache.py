#!/usr/bin/env python3
"""Content-addressed cache of approved-design reference captures.

A reference capture is the approved renderer drawing one approved screen at
one device, orientation, theme and text size, optionally with a named variant
from scripts/reference_variants.json (for example Auto "unavailable" while D1
blocks the registered Auto-applied state). Those images only change when
their inputs change, so re-rendering them for every comparison run wastes the
heavy-job budget (docs/v1/verification-workflow.md). This tool renders a
capture once and reuses it while every input is unchanged.

Cache key inputs (all recorded in the metadata file next to each image):
  - reference revision: git tree hash of docs/ui/app
  - assets: git tree hash of docs/ui/assets
  - capture tool: git blob hashes of docs/ui/tools/shot.js and
    scripts/reference_shot.js, the playwright-core version and the Chromium
    version it drives
  - variant: its name and the SHA-256 of its definition (empty when none)
  - web fonts: SHA-256 of the Google Fonts CSS that docs/ui/app/index.html
    loads. The CSS names versioned font files, so a font update changes it
  - screen, device, orientation, theme, text size

Refusals, so that no stale or unreproducible image is recorded as current:
  - docs/ui has uncommitted changes (the review server serves the working
    folder, so the image would not match the recorded revision)
  - the font CSS cannot be fetched (the key would be unknown)
  - scripts/reference_shot.js without a variant does not reproduce shot.js
    byte for byte (checked once per tool revision, recorded in the cache)

Usage:
  scripts/reference_cache.py get <screen> <device> <orientation> <theme> <text> [variant]
      Print the cached PNG path, rendering it first on a miss.
  scripts/reference_cache.py batch <cells-file>
      One "<screen> <device> <orientation> <theme> <text> [variant]" per line.
      Prints "<hit|rendered> <path>" per line.
  scripts/reference_cache.py key <screen> <device> <orientation> <theme> <text> [variant]
      Print the key inputs as JSON without rendering.

Reference renders run Chromium, not a simulator or emulator, so they do not
take the heavy-job lock.
"""
from __future__ import annotations

import datetime
import hashlib
import json
import os
import subprocess
import sys
import tempfile
import urllib.request
from functools import lru_cache
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
CACHE_ROOT = Path.home() / ".codex/artifacts/lightly/reference-cache"
APPROVED_SHOT_TOOL = REPO_ROOT / "docs/ui/tools/shot.js"
VARIANT_SHOT_TOOL = REPO_ROOT / "scripts/reference_shot.js"
VARIANTS_FILE = REPO_ROOT / "scripts/reference_variants.json"
# The equivalence check renders this cell with both tools.
EQUIVALENCE_PROBE_CELL = ("dev-preset", "iphone17", "portrait", "light", "default")
PLAYWRIGHT_MODULES = Path(
    os.environ.get("LIGHTLY_PLAYWRIGHT_NODE_PATH", "/Users/sg/Documents/Dev/pub-sites/zyphr/node_modules")
)
REVIEW_SERVER = os.environ.get("LIGHTLY_REVIEW_SERVER", "http://127.0.0.1:8765")
GOOGLE_FONTS_CSS_URL = (
    "https://fonts.googleapis.com/css2?family=Allura&family=Caveat:wght@500"
    "&family=Cormorant+Garamond:wght@500&family=Inter:wght@400;500;600;700"
    "&family=Roboto:wght@400;500;700&display=swap"
)
# Chromium's user agent decides which font files Google serves, so fetch the
# CSS the same way the capture browser would see it.
CHROMIUM_LIKE_USER_AGENT = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36"
)
CACHE_FORMAT_VERSION = 1
VALID_ORIENTATIONS = {"portrait", "landscape"}
VALID_THEMES = {"light", "dark"}
VALID_TEXT_SIZES = {"default", "large"}


class ReferenceCacheError(RuntimeError):
    pass


def git_output(*args: str) -> str:
    return subprocess.run(
        ["git", "-C", str(REPO_ROOT), *args], check=True, capture_output=True, text=True
    ).stdout.strip()


def require_clean_reference_inputs() -> None:
    tracked_inputs = ["docs/ui", "scripts/reference_shot.js", "scripts/reference_variants.json"]
    changes = git_output("status", "--porcelain", "--", *tracked_inputs)
    if changes:
        raise ReferenceCacheError(
            "reference inputs have uncommitted changes; captures must come from a committed revision:\n" + changes
        )


@lru_cache(maxsize=1)
def playwright_versions() -> dict[str, str]:
    package = json.loads((PLAYWRIGHT_MODULES / "playwright-core/package.json").read_text())
    probe = (
        "const { chromium } = require('playwright-core');"
        "(async () => { const b = await chromium.launch(); console.log(b.version()); await b.close(); })()"
        ".catch(e => { console.error(e.message); process.exit(1); });"
    )
    chromium_version = subprocess.run(
        ["node", "-e", probe],
        check=True, capture_output=True, text=True,
        env={**os.environ, "NODE_PATH": str(PLAYWRIGHT_MODULES)},
    ).stdout.strip()
    return {"playwright_core": package["version"], "chromium": chromium_version}


@lru_cache(maxsize=1)
def web_fonts_css_sha256() -> str:
    request = urllib.request.Request(GOOGLE_FONTS_CSS_URL, headers={"User-Agent": CHROMIUM_LIKE_USER_AGENT})
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            return hashlib.sha256(response.read()).hexdigest()
    except OSError as error:
        raise ReferenceCacheError(f"cannot fetch the web-font CSS, so the cache key is unknown: {error}") from error


@lru_cache(maxsize=1)
def shared_key_inputs() -> dict[str, object]:
    require_clean_reference_inputs()
    return {
        "cache_format": CACHE_FORMAT_VERSION,
        "reference_tree": git_output("rev-parse", "HEAD:docs/ui/app"),
        "assets_tree": git_output("rev-parse", "HEAD:docs/ui/assets"),
        "shot_tool_blob": git_output("rev-parse", "HEAD:docs/ui/tools/shot.js"),
        "variant_tool_blob": git_output("rev-parse", "HEAD:scripts/reference_shot.js"),
        **playwright_versions(),
        "web_fonts_css_sha256": web_fonts_css_sha256(),
    }


def variant_definition_sha256(variant: str) -> str:
    if not variant:
        return ""
    variants = json.loads(VARIANTS_FILE.read_text())
    if variant not in variants:
        raise ReferenceCacheError(f"unknown variant {variant!r}; define it in {VARIANTS_FILE.name}")
    return hashlib.sha256(json.dumps(variants[variant], sort_keys=True).encode()).hexdigest()


def validate_cell(screen: str, device: str, orientation: str, theme: str, text_size: str) -> None:
    problems = []
    if orientation not in VALID_ORIENTATIONS:
        problems.append(f"orientation {orientation!r}")
    if theme not in VALID_THEMES:
        problems.append(f"theme {theme!r}")
    if text_size not in VALID_TEXT_SIZES:
        problems.append(f"text size {text_size!r}")
    if not screen or not device:
        problems.append("empty screen or device")
    if problems:
        raise ReferenceCacheError("invalid cell: " + ", ".join(problems))


def key_inputs(
    screen: str, device: str, orientation: str, theme: str, text_size: str, variant: str = ""
) -> dict[str, object]:
    validate_cell(screen, device, orientation, theme, text_size)
    return {
        **shared_key_inputs(),
        "screen": screen, "device": device, "orientation": orientation, "theme": theme, "text_size": text_size,
        "variant": variant, "variant_sha256": variant_definition_sha256(variant),
    }


def cache_paths(inputs: dict[str, object]) -> tuple[Path, Path]:
    digest = hashlib.sha256(json.dumps(inputs, sort_keys=True).encode()).hexdigest()
    readable = f"{inputs['screen']}__{inputs['device']}__{inputs['orientation']}__{inputs['theme']}__{inputs['text_size']}"
    if inputs["variant"]:
        readable += f"__{inputs['variant']}"
    folder = CACHE_ROOT / digest[:2]
    return folder / f"{readable}__{digest[:16]}.png", folder / f"{readable}__{digest[:16]}.json"


def run_renderer(tool: Path, cell: tuple[str, ...], out_path: Path, variant: str = "") -> None:
    arguments = ["node", str(tool), *cell, str(out_path), REVIEW_SERVER]
    if variant:
        arguments.append(variant)
    try:
        subprocess.run(
            arguments, check=True, capture_output=True, text=True,
            env={**os.environ, "NODE_PATH": str(PLAYWRIGHT_MODULES)},
        )
    except subprocess.CalledProcessError as error:
        raise ReferenceCacheError(f"{tool.name} failed for {cell}: {error.stderr.strip()}") from error


def require_variant_tool_matches_approved_tool() -> None:
    """reference_shot.js must reproduce shot.js exactly when no variant is used.

    Checked once per (shot.js, reference_shot.js, Playwright, Chromium)
    combination; the passing result is recorded so later runs skip it.
    """
    shared = shared_key_inputs()
    marker_inputs = {k: shared[k] for k in ("shot_tool_blob", "variant_tool_blob", "playwright_core", "chromium")}
    marker_digest = hashlib.sha256(json.dumps(marker_inputs, sort_keys=True).encode()).hexdigest()[:16]
    marker = CACHE_ROOT / "tool-equivalence" / f"{marker_digest}.json"
    if marker.exists():
        return
    with tempfile.TemporaryDirectory() as scratch:
        approved_png, variant_tool_png = Path(scratch, "approved.png"), Path(scratch, "variant-tool.png")
        run_renderer(APPROVED_SHOT_TOOL, EQUIVALENCE_PROBE_CELL, approved_png)
        run_renderer(VARIANT_SHOT_TOOL, EQUIVALENCE_PROBE_CELL, variant_tool_png)
        approved_sha = hashlib.sha256(approved_png.read_bytes()).hexdigest()
        variant_tool_sha = hashlib.sha256(variant_tool_png.read_bytes()).hexdigest()
    if approved_sha != variant_tool_sha:
        raise ReferenceCacheError(
            "scripts/reference_shot.js no longer reproduces docs/ui/tools/shot.js "
            f"({variant_tool_sha[:12]} vs {approved_sha[:12]}); bring it back in line before rendering references"
        )
    marker.parent.mkdir(parents=True, exist_ok=True)
    marker.write_text(json.dumps({**marker_inputs, "probe_cell": EQUIVALENCE_PROBE_CELL,
                                  "image_sha256": approved_sha}, indent=2) + "\n")


def render_reference(inputs: dict[str, object], image_path: Path, metadata_path: Path) -> None:
    image_path.parent.mkdir(parents=True, exist_ok=True)
    # Render to a temporary file first so an interrupted render never leaves
    # a partial image under a valid key.
    with tempfile.NamedTemporaryFile(suffix=".png", dir=image_path.parent, delete=False) as partial:
        partial_path = Path(partial.name)
    cell = tuple(str(inputs[k]) for k in ("screen", "device", "orientation", "theme", "text_size"))
    try:
        if inputs["variant"]:
            require_variant_tool_matches_approved_tool()
            run_renderer(VARIANT_SHOT_TOOL, cell, partial_path, str(inputs["variant"]))
        else:
            # No variant: render with the approved tool itself.
            run_renderer(APPROVED_SHOT_TOOL, cell, partial_path)
        image_sha256 = hashlib.sha256(partial_path.read_bytes()).hexdigest()
        partial_path.replace(image_path)
    except ReferenceCacheError:
        partial_path.unlink(missing_ok=True)
        raise
    metadata = {
        "key_inputs": inputs,
        "image_sha256": image_sha256,
        "rendered_at": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
        "repo_head": git_output("rev-parse", "HEAD"),
    }
    metadata_path.write_text(json.dumps(metadata, indent=2, sort_keys=True) + "\n")


def cached_image_is_intact(image_path: Path, metadata_path: Path) -> bool:
    if not (image_path.exists() and metadata_path.exists()):
        return False
    recorded = json.loads(metadata_path.read_text()).get("image_sha256")
    return recorded == hashlib.sha256(image_path.read_bytes()).hexdigest()


def get_reference(cell: list[str]) -> tuple[str, Path]:
    inputs = key_inputs(*cell)
    image_path, metadata_path = cache_paths(inputs)
    if cached_image_is_intact(image_path, metadata_path):
        return "hit", image_path
    render_reference(inputs, image_path, metadata_path)
    return "rendered", image_path


def parse_cells_file(path: str) -> list[list[str]]:
    cells = []
    for line_number, line in enumerate(Path(path).read_text().splitlines(), start=1):
        fields = line.split("#", 1)[0].split()
        if not fields:
            continue
        if len(fields) not in (5, 6):
            raise ReferenceCacheError(f"{path}:{line_number}: expected 5 or 6 fields, got {len(fields)}")
        cells.append(fields)
    return cells


def main(argv: list[str]) -> int:
    if len(argv) < 2 or argv[1] not in {"get", "batch", "key"}:
        print(__doc__, file=sys.stderr)
        return 64
    command = argv[1]
    try:
        if command == "batch":
            if len(argv) != 3:
                raise ReferenceCacheError("batch takes one cells file")
            for cell in parse_cells_file(argv[2]):
                status, image_path = get_reference(cell)
                print(f"{status} {image_path}", flush=True)
            return 0
        if len(argv) not in (7, 8):
            raise ReferenceCacheError(f"{command} takes <screen> <device> <orientation> <theme> <text> [variant]")
        if command == "key":
            print(json.dumps(key_inputs(*argv[2:]), indent=2, sort_keys=True))
            return 0
        print(get_reference(argv[2:])[1])
        return 0
    except ReferenceCacheError as error:
        print(f"reference_cache: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
