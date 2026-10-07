# A4 hair candidates (2026-10-07)

Development photos (pm02, pd03), `portrait_edges/hair_projection.py dev <variant>`:
| Candidate | pm02 dark teal | pm02 dark red | Verdict |
|---|---|---|---|
| shipped (closed-form matte) | 31,998 | 0.4 | — |
| 1 projection alpha | 9,359 | 15.8 | rejected: red returns (as Vision's matte) |
| 2 interior chromaticity | 5,946 | 0.8 | chosen for the fresh run |
| 3 interior colour | 1,333 | 4.4 | rejected: skin colour in the hair (dev-three-candidates.jpg) |

Fresh set (`portrait_edges/fresh/set.json`, fixed before the run; 18 cases), candidate 2, conditions fixed before the run:
**FAIL** — P1 14/18 (needed 15), P2 fails in 14 cases, P3 passes. `fresh/hair-chroma-fresh.json`.

Visual review (fresh-shipped-vs-chroma.jpg): candidate 2 removes the magenta glow left of portrait_medium_01's head on
the dark background and shows no visible regression; deep_01 (dense afro), the blonde portraits and 68ec5896 are clean in
both; backlit_01 has a dark outline in both. The gate's colour thresholds count natural hair colour: blue-black hair as
teal (medium_01: 82,006 px shipped) and warm or blonde hair as red excess (9–23 in the shipped output). The verdict is
kept as fixed; the candidate is not ported. The gate needs a reference that knows the true hair colour (ground-truth
alpha), not a colour threshold.

## Corrections (2026-10-07, later)
- **The result stands: candidate 2 FAILED its pre-set gate.** Limitation of that gate, documented and not used to
  reinterpret the result: its colour thresholds (cyan > 8 as "teal", red excess as "red") classify natural hair colour,
  blue-black hair as teal and warm or blonde hair as red, so they cannot tell a cast from the subject's own colour.
- **PPM-100 is not used.** Its matte annotations are licensed non-commercial; evaluating Lightly (a commercial product)
  on them is commercial use, so it is unsuitable without counsel.
- **What a ground-truth composite would and would not establish.** With a true alpha only, alpha x photo + (1 - alpha) x
  replacement keeps the old background inside translucent hair (the photo is I = alpha F + (1 - alpha) B), so it checks
  alpha accuracy, not foreground-colour accuracy. The defect here (teal, red) is a foreground-colour error; judging it needs
  the true foreground colour F as well, which only composited datasets provide (their licences are research-only too).
- **Criterion for the next decision: a blind paired review by the owner**, the only judge independent of my metrics and of
  the definition of the outcome itself ("no visible teal/grey fringe"): the 18 fresh cases, shipped and candidate in
  random left/right order, the question "which edge looks more natural, or no difference", answers recorded before the
  key is opened. Fixed now: the candidate passes if it is preferred or tied in at least 15 of 18 pairs and preferred in
  every pair where a cast is visible in either; any pair where the owner sees a new fringe in the candidate fails it.
