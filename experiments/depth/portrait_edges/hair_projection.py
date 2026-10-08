"""A4 correction candidate (2026-10-07): colour-projection alpha in the matte's soft band.

Evidence (exp_alpha_opacity.py, a4-matte-swap-pm02-dark.jpg): the foreground estimate is right; the shipped closed-form
alpha is too low in dense curls (dark-teal: the wall is over-subtracted) and Vision's too high (red: wall kept as
subject). Correction: where the matte is soft (0.02 < a < 0.98), alpha is re-solved from the compositing equation with
known colours, I = a F + (1 - a) B, where F is the local subject colour (pull-push fill from a >= 0.95) and B the local
background colour (fill from a <= 0.05): a = (I - B).(F - B) / |F - B|^2, clamped to [0, 1], in linear light. Only where
|F - B| >= MIN_CONTRAST (the equation is ill-conditioned between similar colours); the shipped alpha elsewhere.

Then exactly the Android pipeline (stages.py): foreground estimate at the 768 px working size, full-resolution composite
with the shift. Constants fixed before the fresh run: MIN_CONTRAST 0.05 (linear), the 0.02 / 0.98 band, SURE 0.95.

Usage: hair_projection.py dev|fresh [projection|chroma]   (dev = pm02, pd03; fresh = fresh/set.json, run once)
Candidate 1 (projection) failed on the development photos (pm02 dark red 0.4 -> 15.8) and was not run on the fresh set.
Candidate 2 (chroma, interior_chroma): the shipped alpha, foreground chromaticity from the interior in the soft band.
Candidate 3 (interior, full interior colour) failed on the development photos (skin colour in the hair) and was not run
on the fresh set. Candidate 5 (projchroma, 2026-10-07): coverage and colour changed together: the projected alpha (candidate 1) with
the interior-chroma foreground (candidate 2). Development photos first; the same P1-P4 bars on a new set if it passes.
Candidate 4 (modnetmax, failed on development): max(shipped alpha, MODNet alpha) where the shipped alpha is below 0.98.
Candidate 2 is the one attempted; its fresh run is decided by these conditions, fixed before the run
(2026-10-07), over the 18 fresh cases (9 portraits x dark/light):
  P1 teal <= max(0.5 x shipped, 300 px) in at least 15 of 18 cases;
  P2 red excess <= shipped + 2.0 and <= 7.5 in every case;
  P3 haze <= shipped + 1.0 in every case;
  P4 the visual sheet of all 18 shows no new visible fringe.
Metrics per case (shipped vs projected), as exp_alpha_opacity.py: teal px (cyan > 8) and red excess in the head's soft
band (union of both mattes' bands), haze = mean |output - replacement| in a ring outside the subject (MODNet a > 0.5
dilated 61 px, both mattes < 0.05).
"""
import sys, json, os
import numpy as np, cv2
from PIL import Image, ImageOps
from pymatting import estimate_foreground_ml, estimate_alpha_cf
HERE = os.path.dirname(os.path.abspath(__file__))
exec(open(os.path.join(HERE, 'stages.py')).read().split("if __name__")[0])
EXP = os.path.abspath(os.path.join(HERE, '..', '..'))
OUT = os.path.join(HERE, '..', 'out', 'hair-projection'); os.makedirs(OUT, exist_ok=True)
MIN_CONTRAST = 0.05
SURE = 0.95


def pull_push(values, weight):
  """Fill where weight is 0 from weighted neighbours at coarser scales (as Refocus.fillMasked)."""
  levels = [(values * weight[..., None], weight)]
  while min(levels[-1][1].shape) > 2:
    v, w = levels[-1]
    levels.append((cv2.resize(v, (max(1, v.shape[1] // 2), max(1, v.shape[0] // 2)), interpolation=cv2.INTER_AREA),
                   cv2.resize(w, (max(1, w.shape[1] // 2), max(1, w.shape[0] // 2)), interpolation=cv2.INTER_AREA)))
  v, w = levels[-1]; filled = v / np.maximum(w, 1e-6)[..., None]
  for v, w in reversed(levels[:-1]):
    up = cv2.resize(filled, (w.shape[1], w.shape[0]), interpolation=cv2.INTER_LINEAR)
    own = v / np.maximum(w, 1e-6)[..., None]; k = np.clip(w, 0, 1)[..., None]
    filled = own * k + up * (1 - k)
  return filled


def shipped_alpha(full_srgb, a_disp, ww, wh):
  """ClosedFormMatting.refine: closed-form matting at the working size, trimap from the prior (sure 0.95, erode 3)."""
  a_w0 = np.clip(bil(a_disp, ww, wh), 0, 1); k = np.ones((7, 7), np.uint8)
  fg = cv2.erode((a_w0 >= SURE).astype(np.uint8), k) > 0; bg = cv2.erode((a_w0 <= 1 - SURE).astype(np.uint8), k) > 0
  tri = np.full(a_w0.shape, 0.5); tri[fg] = 1; tri[bg] = 0
  return np.clip(estimate_alpha_cf(area(full_srgb, ww, wh), tri), 0, 1)


def projected_alpha(I_lin, a):
  F = pull_push(I_lin, (a >= SURE).astype(np.float64)); B = pull_push(I_lin, (a <= 1 - SURE).astype(np.float64))
  d = F - B; c2 = (d * d).sum(-1)
  ap = np.clip(((I_lin - B) * d).sum(-1) / np.maximum(c2, 1e-9), 0, 1)
  use = (a > 0.02) & (a < 0.98) & (np.sqrt(c2) >= MIN_CONTRAST)
  return np.where(use, ap, a), use


def interior_chroma(F_w, I_w, a_w):
  """Candidate 2: in the soft band the foreground keeps its estimated luminance, with the chromaticity of the local
  interior subject colour (pull-push fill of the photo from a >= 0.95)."""
  Fi = pull_push(I_w, (a_w >= SURE).astype(np.float64))
  y = lambda x: 0.2126 * x[..., 0] + 0.7152 * x[..., 1] + 0.0722 * x[..., 2]
  scaled = np.clip(Fi * (y(F_w) / np.maximum(y(Fi), 1e-4))[..., None], 0, 1)
  band = ((a_w > 0.02) & (a_w < 0.98))[..., None]
  return np.where(band, scaled, F_w)


def interior_colour(F_w, I_w, a_w):
  """Candidate 3: in the soft band the foreground colour is the local interior subject colour (brightness included)."""
  Fi = pull_push(I_w, (a_w >= SURE).astype(np.float64))
  return np.where(((a_w > 0.02) & (a_w < 0.98))[..., None], np.clip(Fi, 0, 1), F_w)


def composite(full, a_w, I_w, hexc, chroma=False):
  H, W, _ = full.shape
  F_w = np.clip(estimate_foreground_ml(I_w, a_w), 0, 1)
  if chroma: F_w = (interior_colour if VARIANT == 'interior' else interior_chroma)(F_w, I_w, a_w)
  shift = F_w - I_w
  a = np.clip(bil(a_w, W, H), 0, 1)[..., None]; repl = lin(np.array(hexc) / 255.)
  return enc(np.clip(lin(full) + bil(shift, W, H), 0, 1) * a + repl * (1 - a)) * 255, a[..., 0]


def guided_upsample(a_low, guide_lin, r=8, eps=1e-4):
  """Candidate 6b: joint (guided-filter) upsampling of the working-size alpha with the full-resolution luminance as guide
  (He et al.), so the alpha follows strands and wall pockets the 768 px solve averaged together."""
  H, W = guide_lin.shape[:2]; p = np.clip(bil(a_low, W, H), 0, 1)
  g = 0.2126 * guide_lin[..., 0] + 0.7152 * guide_lin[..., 1] + 0.0722 * guide_lin[..., 2]
  box = lambda x: cv2.boxFilter(x, -1, (2 * r + 1, 2 * r + 1))
  mg, mp = box(g), box(p); cov = box(g * p) - mg * mp; var = box(g * g) - mg * mg
  A = cov / (var + eps); b = mp - A * mg
  return np.clip(box(A) * g + box(b), 0, 1)


def composite_full(full, a_w, hexc, guided):
  """Candidate 6 (2026-10-08, resolution hypothesis): the foreground estimate at full resolution instead of a 768 px
  shift added to the full-resolution photo. 6a: alpha bilinear from the working size (as shipped); 6b: guided upsampling."""
  H, W, _ = full.shape; I = lin(full)
  a = guided_upsample(a_w, I) if guided else np.clip(bil(a_w, W, H), 0, 1)
  F = np.clip(estimate_foreground_ml(I, a), 0, 1); repl = lin(np.array(hexc) / 255.)
  return enc(F * a[..., None] + repl * (1 - a[..., None])) * 255, a


def composite_joint(full, a_w, hexc, refined=False):
  """Candidate 7 (2026-10-08): coverage and colour solved together per pixel at full resolution, from the compositing
  equation I = a F + (1 - a) B with B the local background (pull-push from a <= 0.05) and F constrained to the local
  interior chromaticity c (pull-push from a >= 0.95, luminance-normalised) with free brightness: I - B = u c - a B,
  linear in (u = a * lum(F), a), least squares per pixel, a clamped to [0, 1], u >= 0. Output = u c + (1 - a) R.
  Wall pockets between curls (I ~ B) get a ~ 0 whatever the matte said; hair with wall light mixed in keeps its own
  chromaticity instead of an over-subtracted (teal) estimate. Only in the soft band and where c and B are not
  colinear (the system is singular there); the shipped route elsewhere."""
  H, W, _ = full.shape; I = lin(full); a = np.clip(bil(a_w, W, H), 0, 1)
  y = lambda x: 0.2126 * x[..., 0] + 0.7152 * x[..., 1] + 0.0722 * x[..., 2]
  B = pull_push(I, (a <= 1 - SURE).astype(np.float64))
  interior = a >= SURE
  if refined:
    # 7b: interior pixels indistinguishable from the local background (wall pockets the matte called subject) say
    # nothing about the subject's colour: leave them out of the chromaticity estimate.
    interior &= np.linalg.norm(I - B, axis=-1) > 0.5 * np.linalg.norm(B, axis=-1)
  Fi = pull_push(I, interior.astype(np.float64))
  c = Fi / np.maximum(y(Fi), 1e-4)[..., None]
  # normal equations for M = [c, -B], rhs = I - B
  r = I - B; cc = (c * c).sum(-1); bb = (B * B).sum(-1); cb = (c * B).sum(-1)
  cr = (c * r).sum(-1); br = (B * r).sum(-1); det = cc * bb - cb * cb
  ok = det > 1e-3 * cc * bb   # sin^2 of the angle between c and B above 1e-3
  aj = np.clip((cc * (-br) + cb * cr) / np.maximum(det, 1e-12), 0, 1)
  uj = np.maximum(((c * (r + aj[..., None] * B)).sum(-1)) / np.maximum(cc, 1e-12), 0)
  band = (a > 0.02) & (a < 0.98) & ok
  F_ship = np.clip(estimate_foreground_ml(I, a), 0, 1); repl = lin(np.array(hexc) / 255.)
  ship = F_ship * a[..., None] + repl * (1 - a[..., None])
  joint = np.clip(uj[..., None] * c, 0, 1) + repl * (1 - aj[..., None])
  if refined:
    # 7b: feather the switch between the joint solve and the shipped route (no hard band edge).
    wgt = cv2.GaussianBlur(band.astype(np.float64), (0, 0), 3)[..., None]
    out = joint * wgt + ship * (1 - wgt)
  else:
    out = np.where(band[..., None], joint, ship)
  return enc(out) * 255, np.where(band, aj, a)


def evaluate(tag, src):
  full = np.asarray(ImageOps.exif_transpose(Image.open(src)).convert('RGB')) / 255.; H, W, _ = full.shape
  s = 1600 / max(W, H); dw, dh = round(W * s), round(H * s); disp = area(full, dw, dh)
  a_disp = np.clip(bil(modnet(disp), dw, dh), 0, 1)
  s2 = 768 / max(W, H); ww, wh = round(W * s2), round(H * s2); I_w = lin(area(full, ww, wh))
  a_ship = shipped_alpha(full, a_disp, ww, wh)
  a_proj, used = projected_alpha(I_w, a_ship)
  if VARIANT == 'modnetmax':
    # Candidate 4 (2026-10-07): dense curls need partial coverage between the closed-form alpha (too low) and Vision's
    # (too high). MODNet's own alpha is a portrait matting estimate with partial coverage in hair: where the shipped
    # matte is soft or has dropped the curls (a_ship < 0.98) and MODNet still sees subject, take the larger.
    a_mod = np.clip(bil(a_disp, ww, wh), 0, 1)
    used = (a_ship < 0.98) & (a_mod > a_ship)
    a_proj = np.where(used, a_mod, a_ship)
  head = np.zeros((H, W), bool); head[:int(H * .45)] = True
  subject = bil(a_disp, W, H) > 0.5
  rows = []
  for sc, hexc in (('dark', (0x1F, 0x23, 0x28)), ('light', (0xF4, 0xF1, 0xEC))):
    outs = {}
    for name, aw in (('shipped', a_ship), ('projected', a_ship if VARIANT in ('chroma', 'interior') else a_proj)):
      if name == 'projected' and VARIANT in ('joint', 'jointb'):
        outs[name] = composite_joint(full, a_ship, hexc, refined=(VARIANT == 'jointb')); continue
      if name == 'projected' and VARIANT in ('fullres', 'guidedfull'):
        outs[name] = composite_full(full, a_ship, hexc, guided=(VARIANT == 'guidedfull')); continue
      outs[name] = composite(full, aw, I_w, hexc, chroma=(name == 'projected' and VARIANT in ('chroma', 'interior', 'projchroma')))
    a1, a2 = outs['shipped'][1], outs['projected'][1]
    band = head & (((a1 > 0.02) & (a1 < 0.98)) | ((a2 > 0.02) & (a2 < 0.98)))
    ring = head & (cv2.dilate(subject.astype(np.uint8), np.ones((61, 61))) > 0) & (a1 < 0.05) & (a2 < 0.05)
    repl = enc(lin(np.array(hexc) / 255.)) * 255
    m = {}
    for name, (on, _) in outs.items():
      cy = (on[..., 1] + on[..., 2]) / 2 - on[..., 0]; rd = on[..., 0] - (on[..., 1] + on[..., 2]) / 2
      m[name] = dict(teal=int((band & (cy > 8)).sum()), red=float(np.clip(rd, 0, None)[band].mean()) if band.any() else 0.0,
                     haze=float(np.abs(on[ring] - repl).mean()) if ring.any() else 0.0)
      Image.fromarray(on.astype(np.uint8)).save(f'{OUT}/{tag}-{sc}-{name}.jpg', quality=92)
    rows.append(dict(case=f'{tag}-{sc}', band_px=int(band.sum()), projected_px=int(used.sum()), **{f'{k}_{n}': v for n in m for k, v in m[n].items()}))
    r = rows[-1]
    print(f"{r['case']:28s} teal {r['teal_shipped']:6d} -> {r['teal_projected']:6d} | red {r['red_shipped']:5.1f} -> {r['red_projected']:5.1f} | "
          f"haze {r['haze_shipped']:5.1f} -> {r['haze_projected']:5.1f}", flush=True)
  return rows


if __name__ == '__main__':
  which = sys.argv[1]
  VARIANT = sys.argv[2] if len(sys.argv) > 2 else 'projection'
  OUT = os.path.join(OUT, VARIANT); os.makedirs(OUT, exist_ok=True)
  if which == 'dev':
    cases = {'pm02': f'{S}/iosbg/pm02_12mp.jpg', 'pd03': f'{S}/iosbg/pd03_full.jpg'}
  else:
    # fresh (spent on candidate 2) or validation (2026-10-08, spent on candidate 7b)
    cases = {k: os.path.join(EXP, v) for k, v in json.load(open(os.path.join(HERE, which, 'set.json')))['photos'].items()}
  results = [r for tag, src in cases.items() for r in evaluate(tag, src)]
  if (which, VARIANT) in (('fresh', 'chroma'), ('validation', 'jointb')):
    p1 = sum(r['teal_projected'] <= max(0.5 * r['teal_shipped'], 300) for r in results)
    p2 = [r['case'] for r in results if not (r['red_projected'] <= r['red_shipped'] + 2.0 and r['red_projected'] <= 7.5)]
    p3 = [r['case'] for r in results if not r['haze_projected'] <= r['haze_shipped'] + 1.0]
    print(f'P1 {p1}/{len(results)} (need 15) {"pass" if p1 >= 15 else "FAIL"}; P2 failures {p2 or "none"}; P3 failures {p3 or "none"}')
  json.dump(results, open(os.path.join(HERE, which if which != 'dev' else '.', f'hair-{VARIANT}-{which}.json'), 'w'), indent=1)
