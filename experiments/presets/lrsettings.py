"""Lossless reader for Lightroom / Camera Raw develop settings.

Sources: .xmp (crs namespace), .lrtemplate (Lua table, `s = { ... value = { settings = {...} } }`),
.dng (XMP packet in TIFF tag 700) and .zip archives containing any of these.

Unlike scripts/ingest_presets.py this keeps EVERY crs key with its raw value (scalars as str, sequences as
lists, nested structs as dicts) and never swallows errors: a file that fails to parse is reported with the
exception text. Mapping to Lightly operators happens elsewhere (convert.py), so nothing is dropped here.
"""
from __future__ import annotations

import io
import re
import zipfile
import xml.etree.ElementTree as ET
from dataclasses import dataclass, field
from pathlib import Path

NS = {
    "x": "adobe:ns:meta/",
    "rdf": "http://www.w3.org/1999/02/22-rdf-syntax-ns#",
    "crs": "http://ns.adobe.com/camera-raw-settings/1.0/",
}
CRS = "{%s}" % NS["crs"]
RDF = "{%s}" % NS["rdf"]


@dataclass
class ParsedPreset:
    source: str  # file path, or "zip -> member"
    kind: str  # xmp | lrtemplate | dng
    name: str
    settings: dict = field(default_factory=dict)
    error: str | None = None


# ---------------------------------------------------------------- XMP

def _rdf_value(el: ET.Element):
    """Convert an XMP property element into str | list | dict."""
    for container in ("Seq", "Bag", "Alt"):
        c = el.find(f"{RDF}{container}")
        if c is not None:
            items = [_rdf_value(li) if len(li) else (li.text or "") for li in c.findall(f"{RDF}li")]
            return items
    desc = el.find(f"{RDF}Description")
    if desc is not None:
        return _description_to_dict(desc)
    if el.get(f"{RDF}parseType") == "Resource":
        return _description_to_dict(el)
    return (el.text or "").strip()


def _description_to_dict(desc: ET.Element) -> dict:
    out = {}
    for k, v in desc.attrib.items():
        if k.startswith(CRS):
            out[k[len(CRS):]] = v
    for child in desc:
        if child.tag.startswith(CRS):
            out[child.tag[len(CRS):]] = _rdf_value(child)
    return out


def parse_xmp_text(text: str) -> dict:
    root = ET.fromstring(text.encode("utf-8") if isinstance(text, str) else text)
    settings: dict = {}
    for desc in root.iter(f"{RDF}Description"):
        settings.update(_description_to_dict(desc))
    return settings


def _xmp_name(settings: dict, fallback: str) -> str:
    name = settings.get("Name")
    if isinstance(name, list) and name:
        return str(name[0])
    return fallback


# ---------------------------------------------------------------- lrtemplate (Lua)

class _Lua:
    """Minimal parser for the Lua table literals Lightroom writes in .lrtemplate files."""

    token = re.compile(r'\s*(?:(--\[\[.*?\]\])|(--[^\n]*)|("(?:[^"\\]|\\.)*")|(\[\[.*?\]\])|([{}\[\]=,;])|([A-Za-z_][A-Za-z0-9_]*)|(-?\d+(?:\.\d*)?(?:[eE][-+]?\d+)?))', re.S)

    def __init__(self, text: str):
        self.toks = []
        pos = 0
        while pos < len(text):
            m = self.token.match(text, pos)
            if not m or m.end() == pos:
                if text[pos:].strip() == "":
                    break
                raise ValueError(f"lua tokenize error at {pos}: {text[pos:pos+30]!r}")
            pos = m.end()
            if m.group(1) or m.group(2):
                continue
            if m.group(3):
                self.toks.append(("str", bytes(m.group(3)[1:-1], "utf-8").decode("unicode_escape", "ignore")))
            elif m.group(4):
                self.toks.append(("str", m.group(4)[2:-2]))
            elif m.group(5):
                self.toks.append(("sym", m.group(5)))
            elif m.group(6):
                self.toks.append(("id", m.group(6)))
            elif m.group(7):
                self.toks.append(("num", m.group(7)))
        self.i = 0

    def peek(self, k=0):
        return self.toks[self.i + k] if self.i + k < len(self.toks) else ("eof", "")

    def next(self):
        t = self.peek(); self.i += 1; return t

    def value(self):
        kind, v = self.next()
        if kind == "sym" and v == "{":
            return self.table()
        if kind == "str":
            return v
        if kind == "num":
            return v
        if kind == "id":
            return {"true": "True", "false": "False", "nil": None}.get(v, v)
        raise ValueError(f"unexpected token {kind} {v!r}")

    def table(self):
        items: dict = {}
        arr: list = []
        while True:
            kind, v = self.peek()
            if kind == "sym" and v == "}":
                self.next(); break
            if kind == "sym" and v in ",;":
                self.next(); continue
            if kind == "id" and self.peek(1) == ("sym", "="):
                self.next(); self.next(); items[v] = self.value()
            elif kind == "sym" and v == "[":
                self.next(); key = self.value(); self.next()  # ]
                self.next()  # =
                items[str(key)] = self.value()
            else:
                arr.append(self.value())
        if items and arr:
            items["_array"] = arr
            return items
        return items if items else arr


def parse_lrtemplate_text(text: str) -> tuple[str, dict]:
    m = re.search(r"\bs\s*=\s*\{", text)
    if not m:
        raise ValueError("no `s = {` table")
    lua = _Lua(text[m.end() - 1:])
    lua.next()  # {
    top = lua.table()
    value = top.get("value", {}) if isinstance(top, dict) else {}
    settings = value.get("settings", {}) if isinstance(value, dict) else {}
    # Curves are flat number arrays [x0, y0, x1, y1, ...] in lrtemplate; normalise to "x, y" strings like XMP.
    for k, v in list(settings.items()):
        if isinstance(v, list) and k.startswith(("ToneCurve",)) and all(isinstance(x, str) for x in v) and len(v) % 2 == 0:
            settings[k] = [f"{v[i]}, {v[i+1]}" for i in range(0, len(v), 2)]
    name = top.get("title") or top.get("internalName") or "?" if isinstance(top, dict) else "?"
    return str(name), settings


# ---------------------------------------------------------------- DNG

def extract_dng_xmp(data: bytes) -> str:
    start = data.find(b"<x:xmpmeta")
    end = data.find(b"</x:xmpmeta>")
    if start < 0 or end < 0:
        raise ValueError("no XMP packet in DNG")
    return data[start:end + len(b"</x:xmpmeta>")].decode("utf-8", "ignore")


# ---------------------------------------------------------------- walking

def parse_bytes(data: bytes, source: str, ext: str) -> ParsedPreset:
    stem = Path(source.split(" -> ")[-1]).stem
    try:
        if ext == ".xmp":
            s = parse_xmp_text(data.decode("utf-8", "ignore"))
            return ParsedPreset(source, "xmp", _xmp_name(s, stem), s)
        if ext == ".lrtemplate":
            name, s = parse_lrtemplate_text(data.decode("utf-8", "ignore"))
            return ParsedPreset(source, "lrtemplate", name or stem, s)
        if ext == ".dng":
            s = parse_xmp_text(extract_dng_xmp(data))
            return ParsedPreset(source, "dng", stem, s)
    except Exception as e:  # noqa: BLE001 - reported, never swallowed
        return ParsedPreset(source, ext.lstrip("."), stem, {}, error=f"{type(e).__name__}: {e}")
    raise ValueError(ext)


def walk(root: Path):
    """Yield ParsedPreset for every preset file under root, descending into zip archives."""
    for path in sorted(root.rglob("*")):
        if not path.is_file() or path.name.startswith("._"):
            continue
        ext = path.suffix.lower()
        if ext in (".xmp", ".lrtemplate", ".dng"):
            yield parse_bytes(path.read_bytes(), str(path.relative_to(root)), ext)
        elif ext == ".zip":
            try:
                with zipfile.ZipFile(path) as z:
                    for member in sorted(z.namelist()):
                        mext = Path(member).suffix.lower()
                        if mext in (".xmp", ".lrtemplate", ".dng") and "__MACOSX" not in member and not Path(member).name.startswith("._"):
                            yield parse_bytes(z.read(member), f"{path.relative_to(root)} -> {member}", mext)
            except zipfile.BadZipFile as e:
                yield ParsedPreset(str(path.relative_to(root)), "zip", path.stem, {}, error=f"BadZipFile: {e}")
