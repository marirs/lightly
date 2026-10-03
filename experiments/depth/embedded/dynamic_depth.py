"""Embedded depth on Android: Dynamic Depth 1.0 (DEPTH_JPEG) and legacy GDepth XMP.

Reference reader the Android app ports (docs/v1/depth-evaluation.md §E2), plus a fixture writer so
the reader can be tested without device photos.

  python dynamic_depth.py read  photo.jpg               # prints metadata, saves photo.disparity.npy
  python dynamic_depth.py write src.png disparity.npy out.jpg [--gdepth]

Dynamic Depth 1.0 (https://developer.android.com/static/training/camera2/Dynamic-depth-v1.0.pdf):
  XMP Device:Container/Container:Directory is an ordered list of Container:Item (Item:Mime,
  Item:Length, Item:Padding, Item:DataURI). Item 0 is the primary JPEG (Length 0); secondary items
  are concatenated after the primary image's EOI (+ optional Padding), in directory order.
  Device:Cameras/Camera:DepthMap carries DepthMap:Format (RangeInverse|RangeLinear), Near, Far,
  Units, DepthURI (= the DataURI of the item holding the depth image), ConfidenceURI.
Legacy GDepth (Google Camera "Lens Blur", early Pixel Portrait): xmlns:GDepth="http://ns.google.com/photos/1.0/depthmap/",
  GDepth:Format/Near/Far/Mime and GDepth:Data (base64 PNG/JPEG), usually in extended XMP.

Both encode depth d from the normalised value v in [0,1]:
  RangeLinear:  d = near + v * (far - near)
  RangeInverse: d = far * near / (far - v * (far - near))
The renderer wants disparity (1/d, larger = nearer); it re-normalises by percentiles anyway.
"""
from __future__ import annotations

import base64
import io
import re
import struct
import sys
import uuid

import numpy as np
from PIL import Image

STANDARD_XMP_HEADER = b"http://ns.adobe.com/xap/1.0/\x00"
EXTENDED_XMP_HEADER = b"http://ns.adobe.com/xmp/extension/\x00"


# ------------------------------------------------------------------------------------- reading

def jpeg_segments(data: bytes):
    """Yield (marker, payload) for header segments up to the first SOS."""
    assert data[:2] == b"\xff\xd8", "not a JPEG"
    position = 2
    while position < len(data):
        if data[position] != 0xFF:
            raise ValueError("bad marker")
        marker = data[position + 1]
        if marker == 0xD9:
            return
        length = struct.unpack(">H", data[position + 2:position + 4])[0]
        yield marker, data[position + 4:position + 2 + length], position
        if marker == 0xDA:
            return
        position += 2 + length


def primary_image_length(data: bytes) -> int:
    """Byte length of the primary JPEG (through its EOI), walking all scans (progressive-safe)."""
    position = 2
    while True:
        marker = data[position + 1]
        if marker == 0xD9:
            return position + 2
        if 0xD0 <= marker <= 0xD7 or marker == 0x01:
            position += 2
            continue
        length = struct.unpack(">H", data[position + 2:position + 4])[0]
        position += 2 + length
        if marker == 0xDA:  # entropy-coded data until the next real marker
            while True:
                position = data.index(b"\xff", position)
                following = data[position + 1]
                if following == 0x00 or 0xD0 <= following <= 0xD7:
                    position += 2
                    continue
                break


def read_xmp(data: bytes) -> str:
    """Standard XMP packet plus extended XMP chunks reassembled (GUID-addressed, offset-ordered)."""
    standard, chunks = "", {}
    for marker, payload, _ in jpeg_segments(data):
        if marker != 0xE1:
            continue
        if payload.startswith(STANDARD_XMP_HEADER):
            standard = payload[len(STANDARD_XMP_HEADER):].decode("utf-8", "replace")
        elif payload.startswith(EXTENDED_XMP_HEADER):
            body = payload[len(EXTENDED_XMP_HEADER):]
            # Layout: 32-byte GUID, 4-byte total length (unused: chunks are joined by offset), 4-byte offset.
            guid, offset = body[:32].decode(), struct.unpack(">I", body[36:40])[0]
            chunks.setdefault(guid, {})[offset] = body[40:]
    extended = "".join(b"".join(parts[k] for k in sorted(parts)).decode("utf-8", "replace") for parts in chunks.values())
    return standard + extended


def _property(xmp: str, prefix: str, name: str) -> str | None:
    """Attribute form (prefix:name="v") or element form (<prefix:name>v</prefix:name>)."""
    match = re.search(rf'{prefix}:{name}="([^"]*)"', xmp) or re.search(rf"<{prefix}:{name}>([^<]*)</{prefix}:{name}>", xmp, re.S)
    return match.group(1).strip() if match else None


def decode_range(normalised: np.ndarray, format_name: str, near: float, far: float) -> np.ndarray:
    if format_name == "RangeInverse":
        return far * near / (far - normalised * (far - near))
    if format_name == "RangeLinear":
        return near + normalised * (far - near)
    raise ValueError(f"unknown depth format {format_name}")


def _normalised_pixels(blob: bytes) -> np.ndarray:
    image = Image.open(io.BytesIO(blob))
    array = np.asarray(image)
    if array.ndim == 3:
        array = array[..., 0]
    maximum = 65535.0 if array.dtype == np.uint16 or image.mode.startswith("I") else 255.0
    return array.astype(np.float64) / maximum


def read_embedded_depth(path: str) -> dict | None:
    """Return {'source', 'format', 'near', 'far', 'units', 'depth', 'disparity'} or None."""
    data = open(path, "rb").read()
    xmp = read_xmp(data)
    if "photos/dd/1.0" in xmp and _property(xmp, "DepthMap", "Format"):
        items = []
        for block in re.findall(r"<Container:Item\b(.*?)(?:/>|</Container:Item>)", xmp, re.S):
            def attribute(name):
                m = re.search(rf'Item:{name}="([^"]*)"', block) or re.search(rf"<Item:{name}>([^<]*)</Item:{name}>", block)
                return m.group(1) if m else None
            items.append({"mime": attribute("Mime"), "length": int(attribute("Length") or 0),
                          "padding": int(attribute("Padding") or 0), "uri": attribute("DataURI")})
        offset = primary_image_length(data) + (items[0]["padding"] if items else 0)
        blobs = {}
        for item in items[1:]:
            blobs[item["uri"]] = data[offset:offset + item["length"]]
            offset += item["length"]
        depth_uri = _property(xmp, "DepthMap", "DepthURI")
        format_name = _property(xmp, "DepthMap", "Format")
        near, far = float(_property(xmp, "DepthMap", "Near")), float(_property(xmp, "DepthMap", "Far"))
        units = _property(xmp, "DepthMap", "Units") or "None"
        depth = decode_range(_normalised_pixels(blobs[depth_uri]), format_name, near, far)
        source = "DynamicDepth1.0"
    elif _property(xmp, "GDepth", "Data"):
        format_name = _property(xmp, "GDepth", "Format")
        near, far = float(_property(xmp, "GDepth", "Near")), float(_property(xmp, "GDepth", "Far"))
        units = _property(xmp, "GDepth", "Units") or "None"
        depth = decode_range(_normalised_pixels(base64.b64decode(_property(xmp, "GDepth", "Data"))), format_name, near, far)
        source = "GDepth"
    else:
        return None
    return {"source": source, "format": format_name, "near": near, "far": far, "units": units,
            "depth": depth.astype(np.float32), "disparity": (1.0 / np.maximum(depth, 1e-6)).astype(np.float32)}


# ------------------------------------------------------------------------------- fixture writer

def _app1(header: bytes, body: bytes) -> bytes:
    payload = header + body
    return b"\xff\xe1" + struct.pack(">H", len(payload) + 2) + payload


def _encode_range_inverse_png(depth: np.ndarray, near: float, far: float) -> bytes:
    normalised = (far * (depth - near)) / (depth * (far - near))
    quantised = np.clip(np.round(normalised * 65535), 0, 65535).astype(np.uint16)
    buffer = io.BytesIO()
    Image.fromarray(quantised).save(buffer, format="PNG")
    return buffer.getvalue()


def write_fixture(image_path: str, disparity: np.ndarray, out_path: str, gdepth: bool = False) -> None:
    """Primary JPEG + depth (from a relative disparity in [0,1], mapped to 0.5..20 m)."""
    depth = 1.0 / (np.clip(disparity, 0, 1) * (1 / 0.5 - 1 / 20.0) + 1 / 20.0)
    near, far = float(depth.min()), float(depth.max())
    png = _encode_range_inverse_png(depth, near, far)
    buffer = io.BytesIO()
    Image.open(image_path).convert("RGB").save(buffer, format="JPEG", quality=90)
    primary = buffer.getvalue()
    if gdepth:
        extended = (f'<x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">'
                    f'<rdf:Description xmlns:GDepth="http://ns.google.com/photos/1.0/depthmap/" '
                    f'GDepth:Data="{base64.b64encode(png).decode()}"/></rdf:RDF></x:xmpmeta>').encode()
        guid = uuid.uuid4().hex.upper()
        standard = (f'<x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">'
                    f'<rdf:Description xmlns:GDepth="http://ns.google.com/photos/1.0/depthmap/" '
                    f'xmlns:xmpNote="http://ns.adobe.com/xmp/note/" xmpNote:HasExtendedXMP="{guid}" '
                    f'GDepth:Format="RangeInverse" GDepth:Near="{near}" GDepth:Far="{far}" GDepth:Mime="image/png" '
                    f'GDepth:Units="m"/></rdf:RDF></x:xmpmeta>').encode()
        segments = _app1(STANDARD_XMP_HEADER, standard)
        chunk_size = 65000
        for offset in range(0, len(extended), chunk_size):
            segments += _app1(EXTENDED_XMP_HEADER, guid.encode() + struct.pack(">II", len(extended), offset)
                              + extended[offset:offset + chunk_size])
        open(out_path, "wb").write(primary[:2] + segments + primary[2:])
        return
    xmp = f"""<x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
<rdf:Description xmlns:Device="http://ns.google.com/photos/dd/1.0/device/" xmlns:Container="http://ns.google.com/photos/dd/1.0/container/"
 xmlns:Item="http://ns.google.com/photos/dd/1.0/item/" xmlns:Camera="http://ns.google.com/photos/dd/1.0/camera/"
 xmlns:DepthMap="http://ns.google.com/photos/dd/1.0/depthmap/">
<Device:Container><Container:Directory><rdf:Seq>
 <rdf:li rdf:parseType="Resource"><Container:Item Item:Mime="image/jpeg" Item:Length="0" Item:Padding="0" Item:DataURI="primary_image"/></rdf:li>
 <rdf:li rdf:parseType="Resource"><Container:Item Item:Mime="image/png" Item:Length="{len(png)}" Item:DataURI="android/depthmap"/></rdf:li>
</rdf:Seq></Container:Directory></Device:Container>
<Device:Cameras><rdf:Seq><rdf:li rdf:parseType="Resource"><Device:Camera><Camera:DepthMap
 DepthMap:Format="RangeInverse" DepthMap:ItemSemantic="Depth" DepthMap:Near="{near}" DepthMap:Far="{far}"
 DepthMap:Units="Meters" DepthMap:DepthURI="android/depthmap"/></Device:Camera></rdf:li></rdf:Seq></Device:Cameras>
</rdf:Description></rdf:RDF></x:xmpmeta>""".encode()
    with_xmp = primary[:2] + _app1(STANDARD_XMP_HEADER, xmp) + primary[2:]
    open(out_path, "wb").write(with_xmp + png)


def main() -> None:
    if sys.argv[1] == "read":
        result = read_embedded_depth(sys.argv[2])
        if result is None:
            print("no embedded depth")
            return
        np.save(sys.argv[2] + ".disparity.npy", result["disparity"])
        print({k: v for k, v in result.items() if k not in ("depth", "disparity")}, result["depth"].shape)
    elif sys.argv[1] == "write":
        write_fixture(sys.argv[2], np.load(sys.argv[3]), sys.argv[4], gdepth="--gdepth" in sys.argv)
        print("wrote", sys.argv[4])


if __name__ == "__main__":
    main()
