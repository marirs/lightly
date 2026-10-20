# Lightly roadmap

## Release plan (owner, 2026-10-20)

| Release | Scope |
|---|---|
| 1.1 | Portrait › Sunglasses (open issues: [v1.1/sunglasses-open-issues.md](v1.1/sunglasses-open-issues.md)); 1.0 polishes; Effects › Ink (scanned ink strokes) |
| 1.2 | Eraser (below) |
| 1.3 | Enhance (on-device upscale + face restore; descratch/colourise later) |
| 1.4 | Torn paper edges from photographed scans |
| 1.5 | Preset Lab Studio presets (mass bundle, needs heavy curation; moved from 1.2) |

Any 1.0 defect that needs a store fix before 1.1 still ships as 1.0.x from `release/1.0`.

## 1.2 — Eraser

Recorded 2026-10-05 from the owner's explicit request; moved from 1.1 to 1.2 by the owner on 2026-10-20. Target: iOS and Android.
Status: scheduled for 1.2; research recorded, detailed UX and implementation not approved or started.

Remove unwanted people, objects and distractions from a photograph, reconstructing
what belongs behind them rather than leaving transparency or a blurred patch.
Keep the user in the same editing session with their other edits intact.

See [Eraser research and proposed scope](v1.1/eraser.md).

### Relationship to 1.0

The approved 1.0 design already has Edit → Remove and an inpainting implementation.
The new Eraser request overlaps it. Record the reference-led Eraser work under 1.2;
do not start it as additional 1.0 work. This roadmap entry does not silently delete,
rename, disable or re-scope the existing approved Remove control. Before 1.2 design,
resolve whether Eraser upgrades that control or replaces it. Any change to the 1.0
release scope or approved screens must be recorded explicitly with the owner.

Existing 1.0 defects and acceptance checks remain in the implementation checklist.
