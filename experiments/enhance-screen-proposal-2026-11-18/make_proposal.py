"""Enhance screen proposal (1.3), built from the approved Lightly 2 mockup without changing it.

Reads docs/ui/directions/lightly-2-concept/index.html, adds Edit › Enhance using only the mockup's own components
(tabs, resetRow, primary, note, notice, quietBtn, progressCard, toast), replaces the screen list with the Enhance
states plus the approved Remove states it follows, and writes index.html beside this script. Every device and both
themes come from the mockup's own switches.

Run: python3 make_proposal.py
"""
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
MOCKUP = ROOT / "docs/ui/directions/lightly-2-concept/index.html"


def replace_once(text: str, old: str, new: str) -> str:
    if text.count(old) != 1:
        raise SystemExit(f"expected exactly one match for: {old[:80]!r}")
    return text.replace(old, new)


ENHANCE_BODY = r"""// PROPOSED (1.3): Edit › Enhance follows Edit › Remove: one action, the same progress card with Cancel on the photo,
// the same failure notice, and the section's Reset. No sliders: the strength is fixed by the engine.
function enhanceBody(e) {
  if (e.op === 'enhancing') return notice('info', '<span>Enhancing…</span>', quietBtn('Cancel'));
  if (e.op === 'enhanceFailed') return notice('warn', "<span><b>Couldn't enhance this photo.</b> Your other edits are kept.</span>", quietBtn('Try again'));
  if (e.enhanced) return note(e.painting ? 'This looks like a painting, so faces are kept as painted. The rest is twice the size.' : 'Twice the size, with soft faces restored.');
  return primary('Enhance photo') + note('Doubles the size and restores small or soft faces, on this phone.' + (e.large ? ' Photos over 2000 px are enhanced at 2000 px, so they come out at up to 4000 px.' : ''));
}
function editPanel(s) {"""

PROPOSAL_NOTE = r"""<section style="max-width: 760px; margin: 8px 0 24px; font-size: 14px; line-height: 1.5">
<h2 style="margin: 0 0 6px">Enhance (1.3) · proposal for approval, 2026-11-18</h2>
<p style="margin: 0 0 8px"><b>Where:</b> a new last tab in Edit, <b>Enhance</b>, after Remove. Edit already holds the
operations that change the photo's pixels (Remove); no new dock tool, and the panel keeps its one fixed height.</p>
<p style="margin: 0 0 8px"><b>Flow:</b> “Enhance photo” → the same progress card Remove uses, on the photo, with a
progress bar (it takes 6–80 s on the review phones) and Cancel → done: the note says what changed, a toast
“Enhanced”, Reset in the section row and Undo in the header undo it. Failure: the same notice as Remove, other edits
kept. Paintings: faces are kept as painted (the engine's painting check), and the note says so.</p>
<p style="margin: 0 0 8px"><b>Behaviour behind it:</b> Enhance works on the original photo, under the other edits, so
presets, crop and effects stay adjustable after it. Saved copies are twice the size (photos over 2000 px are enhanced
at 2000 px: up to 4000 px). Everything runs on the phone.</p>
<p style="margin: 0"><b>Deliberately left out:</b> strength sliders, per-face choices, face outlines (owner amendment:
no face marks). Every component below is the mockup's own; nothing else in the mockup changes.</p></section>"""

# Swapped in just before render(), after the mockup's own amendments to J have run.
NEW_SCREENS = r"""J.splice(0, J.length,
  ['Edit · Enhance (proposed)', [
    ['enh', 'Enhance · one action', ED('edit', 'smile', { ed: { sub: 'enhance' } })],
    ['enh-large', 'Enhance · a photo over 2000 px', ED('edit', 'lake', { ed: { sub: 'enhance', large: true } })],
    ['enh-running', 'Enhancing · progress on the photo, cancellable', ED('edit', 'smile', { ed: { sub: 'enhance', op: 'enhancing', pct: 45 } })],
    ['enh-done', 'Enhanced · Reset and Undo undo it', ED('edit', 'smile', { ed: { sub: 'enhance', enhanced: true }, toast: 'Enhanced' })],
    ['enh-done-edited', 'Enhanced · other edits stay adjustable', ED('edit', 'woman', { ed: { sub: 'enhance', enhanced: true }, ...EDITED })],
    ['enh-painting', 'Enhanced · a painting: faces kept as painted', ED('edit', 'street', { ed: { sub: 'enhance', enhanced: true, painting: true } })],
    ['enh-failed', 'Enhance failed · edits kept', ED('edit', 'smile', { ed: { sub: 'enhance', op: 'enhanceFailed' }, dev: HONEY })]]],
  ['Edit · Remove (approved, unchanged: the pattern Enhance follows)', [
    ['ed-remove', 'Remove · brush over unwanted objects', ED('edit', 'field', { ed: { sub: 'remove', touched: true, strokes: true } })],
    ['ed-removing', 'Removing · cancellable', ED('edit', 'field', { ed: { sub: 'remove', op: 'removing', touched: true } })],
    ['ed-remove-failed', 'Remove failed · edits kept', ED('edit', 'field', { ed: { sub: 'remove', op: 'failed', touched: true }, dev: HONEY })]]]);
function render() {"""


def main() -> None:
    html = MOCKUP.read_text()
    # Paths: this page sits two folders below the repo root instead of four.
    html = html.replace("url('../../../../shared/", "url('../../shared/")
    html = replace_once(html, "const A = (n) => `assets/${n}`;", "const A = (n) => `../../docs/ui/directions/lightly-2-concept/assets/${n}`;")
    html = replace_once(html, "`../../../../shared/leaks/out/", "`../../shared/leaks/out/")
    html = replace_once(html, "<title>Lightly 2 · full mockup</title>", "<title>Enhance proposal</title>")
    html = replace_once(html, "<h1>Lightly 2 · full mockup</h1>", "<h1>Lightly 2 · Enhance proposal</h1>")
    # Edit › Enhance.
    html = replace_once(html, "function editPanel(s) {", ENHANCE_BODY)
    html = replace_once(html, "  const names = { crop: 'Crop', rotate: 'Rotate', straighten: 'Straighten', perspective: 'Perspective', adjust: 'Adjust', remove: 'Remove' };\n  return col(6, tabs(Object.entries(names).map(([k, l]) => [k, l]), sub) + resetRow(names[sub], !!e.touched) + body);",
                        "  if (sub === 'enhance') body = enhanceBody(e);\n  const names = { crop: 'Crop', rotate: 'Rotate', straighten: 'Straighten', perspective: 'Perspective', adjust: 'Adjust', remove: 'Remove', enhance: 'Enhance' };\n  return col(6, tabs(Object.entries(names).map(([k, l]) => [k, l]), sub) + resetRow(names[sub], sub === 'enhance' ? !!e.enhanced : !!e.touched) + body);")
    html = replace_once(html, "  if (op) m.push(progressCard(op, true));",
                        "  if (op) m.push(progressCard(op, true));\n  if ((s.ed || {}).op === 'enhancing') m.push(progressCard('Enhancing…', true, (s.ed || {}).pct));")
    # The screens: Enhance, and the approved Remove states beside it.
    html = replace_once(html, "function render() {", NEW_SCREENS)
    html = replace_once(html, "let out = iconSection();", f"let out = {PROPOSAL_NOTE!r};")
    (HERE / "index.html").write_text(html)
    print("wrote", HERE / "index.html")


if __name__ == "__main__":
    main()
