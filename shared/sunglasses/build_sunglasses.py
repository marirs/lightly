#!/usr/bin/env python3
"""Build the sunglasses pack both apps bundle (Portrait › Sunglasses, owner-approved
docs/ui/proposals/portrait-sunglasses-v2.html, 2026-10-13: the ten purchased 3D pairs).

    python shared/sunglasses/build_sunglasses.py [--models ~/Downloads/Sunglasses\\ 3D] [--out shared/sunglasses/out]

Input: the purchased models (not in git). Each is normalised by experiments/sunglasses/normalize.py (metres; x across
with the wearer's left at +x, y up, z forward; origin at the lens centre; lens parts found; arms splayed to 80 mm).
Output (`out/`, git-ignored like the light-leak pack, so the purchase never enters the repository):
- sunglasses.json  format "lightly-sunglasses-pack" 1: per pair its id, name, order, mesh, thumbnail, materials and
                   the SHA-256 of every file;
- mesh/<id>.lsg    the pair's geometry (format below), reduced to at most TRIANGLE_BUDGET triangles;
- tex/<id>-<n>-{base,normal}.{jpg,png}  material textures, at most TEXTURE_EDGE px;
- thumb/<id>.png   the panel tile, 200 px wide, transparent.
- thumb/<id>-dark.png   the same tile for dark mode (studio rim lighting; optional `thumbnailDark` in the manifest).

LSG 1 (little-endian):
    "LSG1", u32 version (1), u32 vertexCount, u32 elementCount
    vertexCount x { f32 position[3] (metres), f32 normal[3], f32 uv[2] (origin top-left) }   interleaved, 32 bytes
    elementCount x { u32 materialIndex, u32 indexCount, u32 indices[indexCount] }            triangles

Ids are "sun-" + the first 12 hex digits of the source OBJ's SHA-256, so they never move when the set changes.
Names are the shape names the owner approved with the proposal (2026-10-13).
"""
from __future__ import annotations

import argparse
import hashlib
import json
import struct
import subprocess
import sys
from pathlib import Path

import numpy as np
from PIL import Image

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
sys.path.insert(0, str(REPO / 'experiments/sunglasses'))
import normalize  # noqa: E402  (experiments/sunglasses/normalize.py)

TRIANGLE_BUDGET = 40_000
TEXTURE_EDGE = 1024
# Owner-approved order and names (proposal v2). Source folder -> shape name.
PAIRS = [
    ('Kurt Cobain Round', 'Oval'), ('Oakley Frogskins Lite', 'Club'), ('Oakley Split Time', 'Pilot'),
    ('Ray-Ban Outdoorsman RB3422Q', 'Aviator'), ('Ray-Ban Wayfarer Double Bridge RB4540', 'Bridge'),
    ('Ray-Ban Wayfarer Liteforce RB4195', 'Wayfarer'), ('Rudy Project Spinair', 'Sport'),
    ('Saint Laurent SL57', 'Round'), ('Tom Ford FT0711', 'Square'), ('Tom Ford FT0834', 'Panto'),
]


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def read_obj(path: Path):
    """Positions, uvs, normals and triangles (fan-triangulated) grouped by usemtl key."""
    V, T, N = [], [], []
    groups: dict[str, list] = {}
    mat = None
    for line in open(path, errors='ignore'):
        p = line.split()
        if not p: continue
        if p[0] == 'v': V.append([float(x) for x in p[1:4]])
        elif p[0] == 'vt': T.append([float(x) for x in p[1:3]])
        elif p[0] == 'vn': N.append([float(x) for x in p[1:4]])
        elif p[0] == 'usemtl': mat = p[1]
        elif p[0] == 'f' and mat is not None:
            corners = []
            for c in p[1:]:
                idx = (c.split('/') + ['', ''])[:3]
                corners.append(tuple(int(i) - 1 if i else -1 for i in idx))
            for k in range(1, len(corners) - 1):
                groups.setdefault(mat, []).append((corners[0], corners[k], corners[k + 1]))
    return np.array(V, np.float64), np.array(T or [[0, 0]], np.float64), np.array(N or [[0, 0, 1]], np.float64), groups


def split_vertices(V, T, N, tris):
    """One vertex per distinct (position, uv, normal): UV seams and hard edges become open borders, which the
    simplifier preserves, so textures and creases survive the reduction."""
    key_index: dict[tuple, int] = {}
    pos, uv, nrm, faces = [], [], [], []
    for tri in tris:
        f = []
        for (vi, ti, ni) in tri:
            key = (vi, ti, ni)
            if key not in key_index:
                key_index[key] = len(pos); pos.append(V[vi]); uv.append(T[ti] if ti >= 0 else (0, 0)); nrm.append(N[ni] if ni >= 0 else (0, 0, 0))
            f.append(key_index[key])
        faces.append(f)
    return np.array(pos), np.array(uv), np.array(nrm), np.array(faces, np.int64)


def face_normals(P, F):
    n = np.cross(P[F[:, 1]] - P[F[:, 0]], P[F[:, 2]] - P[F[:, 0]])
    return n


def reduce_group(P, UV, NR, F, target):
    """Quadric simplification with borders kept, then each new vertex takes the UV and normal of the closest point
    on the original surface (seam vertices do not move, so they keep theirs exactly)."""
    if len(F) <= target:
        return P, UV, NR, F
    import pyfqmr  # only the full build reduces meshes
    s = pyfqmr.Simplify(); s.setMesh(P, F)
    s.simplify_mesh(target_count=int(target), aggressiveness=7, preserve_border=True, verbose=False)
    P2, F2, _ = s.getMesh()
    # nearest original vertex (exact for kept vertices; a close approximation for moved interior ones)
    from numpy.linalg import norm  # noqa
    order = np.argsort(P[:, 0]); Ps = P[order]
    uv2 = np.zeros((len(P2), 2)); n2 = np.zeros((len(P2), 3))
    for i, p in enumerate(P2):
        lo = np.searchsorted(Ps[:, 0], p[0] - 2e-3); hi = np.searchsorted(Ps[:, 0], p[0] + 2e-3)
        cand = order[lo:hi] if hi > lo else order
        j = cand[np.argmin(((P[cand] - p) ** 2).sum(1))]
        uv2[i] = UV[j]; n2[i] = NR[j]
    return P2, uv2, n2, F2.astype(np.int64)


def fix_normals(P, NR, F):
    """Vertices without a source normal get the area-weighted normal of their faces."""
    missing = np.linalg.norm(NR, axis=1) < 1e-6
    if missing.any():
        acc = np.zeros_like(P); fn = face_normals(P, F)
        for k in range(3): np.add.at(acc, F[:, k], fn)
        NR = NR.copy(); NR[missing] = acc[missing]
    l = np.linalg.norm(NR, axis=1, keepdims=True); l[l == 0] = 1
    return NR / l


def write_lsg(path: Path, P, NR, UV, elements):
    with open(path, 'wb') as f:
        f.write(b'LSG1'); f.write(struct.pack('<III', 1, len(P), len(elements)))
        inter = np.hstack([P, NR, np.column_stack([UV[:, 0], 1.0 - UV[:, 1]])]).astype('<f4')  # uv origin top-left
        f.write(inter.tobytes())
        for mat_index, F in elements:
            f.write(struct.pack('<II', mat_index, F.size)); f.write(F.astype('<u4').tobytes())


def save_texture(src: str, dst_stem: Path, keep_alpha: bool) -> Path:
    im = Image.open(src)
    im = im.convert('RGBA' if keep_alpha else 'RGB')
    im.thumbnail((TEXTURE_EDGE, TEXTURE_EDGE), Image.LANCZOS)
    if keep_alpha:
        out = dst_stem.with_suffix('.png'); im.save(out, optimize=True)
    else:
        out = dst_stem.with_suffix('.jpg'); im.save(out, quality=90)
    return out


def thumbnail(norm_dir: Path, out: Path, renderer: Path):
    """The tile: the pair turned 22 degrees, dark lenses, transparent, 200 px wide (same look as the proposal)."""
    import math
    t = math.radians(22); ex = (math.cos(t), 0, -math.sin(t)); ez = (math.sin(t), 0, math.cos(t))
    tmp = out.parent / '_thumb'
    args = [str(renderer), str(norm_dir), str(tmp), '480', '240', '240', '112', '2700', *map(str, (*ex, 0, 1, 0, *ez))]
    for p in ('frame', 'lens'): subprocess.run(args + [p], check=True, capture_output=True)
    fr = Image.open(f'{tmp}.frame.png').convert('RGBA'); ln = np.asarray(Image.open(f'{tmp}.lens.png').convert('RGBA'), np.float32)
    L = ln[..., 0] / 255 * ln[..., 3] / 255; H, W = L.shape; g = np.linspace(0.20, 0.0, H)[:, None]
    rgb = np.stack([np.full((H, W), 40.) + g * 128, np.full((H, W), 46.) + g * 128, np.full((H, W), 44.) + g * 140], -1)
    lens = Image.fromarray(np.dstack([rgb.clip(0, 255), L * 235]).astype(np.uint8), 'RGBA'); lens.alpha_composite(fr)
    lens = lens.crop(lens.getbbox()); lens.thumbnail((200, 100), Image.LANCZOS); lens.save(out, optimize=True)
    for p in ('frame', 'lens'): Path(f'{tmp}.{p}.png').unlink(missing_ok=True)


def dark_thumbnail(pack: Path, pid: str, out: Path, lsg_renderer: Path):
    """The dark-mode tile (owner choice A, 2026-10-19): the pack's own mesh rendered by render_lsg.swift with studio
    rim lighting (LSG_STUDIO=1: back lights both sides and a top light, so black acetate shows its edges on a dark
    tile) and lenses with a cool sky reflection over their top, same framing and size as thumbnail()."""
    import math, os
    t = math.radians(22); ex = (math.cos(t), 0, -math.sin(t)); ez = (math.sin(t), 0, math.cos(t))
    tmp = out.parent / '_dark'
    args = [str(lsg_renderer), str(pack), pid, str(tmp), '480', '240', '240', '112', '2700', *map(str, (*ex, 0, 1, 0, *ez))]
    env = dict(os.environ, LSG_STUDIO='1')
    for p in ('frame', 'lens'): subprocess.run(args + [p], check=True, capture_output=True, env=env)
    fr = Image.open(f'{tmp}.frame.png').convert('RGBA'); ln = np.asarray(Image.open(f'{tmp}.lens.png').convert('RGBA'), np.float32)
    L = ln[..., 0] / 255 * ln[..., 3] / 255; H, W = L.shape
    g = np.clip(1 - np.linspace(0, 1, H) / 0.45, 0, 1)[:, None] ** 1.5
    rgb = np.stack([np.full((H, W), 30.) + g * 150, np.full((H, W), 34.) + g * 162, np.full((H, W), 40.) + g * 185], -1)
    lens = Image.fromarray(np.dstack([rgb.clip(0, 255), L * 240]).astype(np.uint8)); lens.alpha_composite(fr)
    lens = lens.crop(lens.getbbox()); lens.thumbnail((200, 100), Image.LANCZOS); lens.save(out, optimize=True)
    for p in ('frame', 'lens'): Path(f'{tmp}.{p}.png').unlink(missing_ok=True)


def add_dark_thumbnails(pack: Path, lsg_renderer: Path):
    """Adds `thumbnailDark` and its digest to every pair of an existing pack (the rest of the pack is unchanged)."""
    manifest = json.loads((pack / 'sunglasses.json').read_text())
    for pair in manifest['pairs']:
        f = pack / f"thumb/{pair['id']}-dark.png"; dark_thumbnail(pack, pair['id'], f, lsg_renderer)
        pair['thumbnailDark'] = f"thumb/{pair['id']}-dark.png"; pair['thumbnailDarkSha256'] = sha256(f)
        print(pair['name'], pair['thumbnailDark'])
    (pack / 'sunglasses.json').write_text(json.dumps(manifest, indent=1))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--models', default=str(Path.home() / 'Downloads/Sunglasses 3D'))
    ap.add_argument('--out', default=str(HERE / 'out'))
    ap.add_argument('--renderer', help='compiled experiments/sunglasses/render_glasses3.swift')
    ap.add_argument('--lsg-renderer', required=True, help='compiled experiments/sunglasses/render_lsg.swift (dark-mode tiles)')
    ap.add_argument('--dark-thumbnails-only', action='store_true', help='only add the dark-mode tiles to an existing pack')
    a = ap.parse_args()
    if a.dark_thumbnails_only:
        add_dark_thumbnails(Path(a.out), Path(a.lsg_renderer)); return
    if not a.renderer: ap.error('--renderer is required to build the pack')
    out = Path(a.out); work = out / '_normalised'
    for sub in ('mesh', 'tex', 'thumb'): (out / sub).mkdir(parents=True, exist_ok=True)
    normalize.ROOT = a.models; normalize.OUT = str(work)
    pairs = []
    for order, (folder, name) in enumerate(PAIRS, 1):
        normalize.normalise(folder)
        nd = work / folder; spec = json.loads((nd / 'model.json').read_text())
        src_obj = next(Path(a.models, folder).rglob('*.obj'))
        pid = 'sun-' + sha256(src_obj)[:12]
        V, T, N, groups = read_obj(nd / 'model.obj')
        keys = sorted(groups)  # material keys in a stable order
        total = sum(len(groups[k]) for k in keys); ratio = min(1.0, TRIANGLE_BUDGET / total)
        allP, allN, allUV, elements, base = [], [], [], [], 0
        for mi, k in enumerate(keys):
            P, UV, NR, F = split_vertices(V, T, N, groups[k])
            P, UV, NR, F = reduce_group(P, UV, NR, F, max(64, len(F) * ratio))
            NR = fix_normals(P, NR, F)
            allP.append(P); allN.append(NR); allUV.append(UV); elements.append((mi, F + base)); base += len(P)
        P, NR, UV = np.vstack(allP), np.vstack(allN), np.vstack(allUV)
        mesh = out / f'mesh/{pid}.lsg'; write_lsg(mesh, P, NR, UV, elements)
        materials = []
        for mi, k in enumerate(keys):
            m = spec['materials'].get(k, {'role': 'frame'})
            entry = {'key': k, 'role': m['role'], 'baseColor': m.get('color', [0.03, 0.03, 0.03]),
                     'roughness': m.get('roughness', 0.25), 'metalness': m.get('metalness', 0.0),
                     'translucent': bool(m.get('translucent', False))}
            if m['role'] == 'lv':
                raise SystemExit(f'{folder}: single-mesh lens models are not in the approved set')
            for slot, kind in (('diffuse', 'base'), ('normal', 'normal')):
                if m.get(slot):
                    f = save_texture(m[slot], out / f'tex/{pid}-{mi}-{kind}', keep_alpha=(slot == 'diffuse' and entry['translucent']))
                    entry[kind] = f'tex/{f.name}'; entry[kind + 'Sha256'] = sha256(f)
            materials.append(entry)
        thumb = out / f'thumb/{pid}.png'; thumbnail(nd, thumb, Path(a.renderer))
        tri = sum(F.size // 3 for _, F in elements)
        pairs.append({'id': pid, 'name': name, 'order': order, 'mesh': f'mesh/{pid}.lsg', 'meshSha256': sha256(mesh),
                      'thumbnail': f'thumb/{pid}.png', 'thumbnailSha256': sha256(thumb), 'triangles': tri, 'materials': materials})
        print(f'{order:2d} {name:9s} {pid}  {total:7d} -> {tri:6d} triangles  {mesh.stat().st_size / 1e6:.2f} MB mesh')
    manifest = {'format': 'lightly-sunglasses-pack', 'formatVersion': 1, 'pairs': pairs}
    (out / 'sunglasses.json').write_text(json.dumps(manifest, indent=1))
    add_dark_thumbnails(out, Path(a.lsg_renderer))
    size = sum(f.stat().st_size for d in ('mesh', 'tex', 'thumb') for f in (out / d).iterdir())
    print(f'pack: {len(pairs)} pairs, {size / 1e6:.1f} MB')


if __name__ == '__main__':
    main()
