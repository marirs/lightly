# Eraser — 1.1 research and proposed scope

Date: 2026-10-05. Platforms: iOS and Android.
Owner approved scheduling Eraser for 1.1. The details below are recommendations,
not approved screens, promised model capabilities or a new 1.0 work assignment.

## Reference review

Reviewed all three supplied pages: product descriptions, visible promotional examples,
listed workflows and available privacy/version information. No competitor app was
installed or benchmarked. Marketing demonstrations are not independent quality evidence.
HitPaw failed in the text-fetch tool but loaded and was reviewed in the browser.

### 1. Magic Eraser — Remove Object

[App Store listing](https://apps.apple.com/us/app/magic-eraser-remove-object/id1619950778)

The publisher describes removal of people, text, stickers and details. Visible examples
show painted selections, object/text removal and separate background erasure. A listing
review describes brush/lasso selection, adjustable brush width and Undo; those controls
are user-reported, not independently tested. Version notes mention a brush magnifier.
The broader suite also includes expansion, replacement, generation and enhancement;
these are not implied Eraser scope. The listed flow selects a feature before a photo,
which must not replace Lightly's photo-first, single-session flow. The privacy label
reports tracking identifiers and other collection; it does not establish on-device
processing. Takeaway: clear selection feedback and precise correction matter as much
as the final fill. Neither ratings nor promotional examples prove reliable removal.

### 2. Remove Object Erase Background

[App Store listing](https://apps.apple.com/ae/app/remove-object-erase-background/id6479766047)

The listing focuses on objects, people and small skin blemishes, with a subscription
Smart Eraser. Visible promotional panels show a highlighted obstruction, a skin
before/after, portrait cut-out and a product-background example. The page does not
explain its model, processing location, selection controls or quality limits. It is
presented as designed for iPhone; that is not evidence of Android/tablet behaviour.
Privacy labels disclose diagnostics collection/tracking, and sufficient aggregate
reviews were not shown in this regional listing. Takeaway: small local repair and
large object removal need separate quality cases; do not turn a spot removal into
global skin smoothing or combine it with Background merely because this app does.

### 3. HitPaw FotorPea object/background remover

[Supplied landing page, without advertising tracking parameters](https://www.hitpaw.net/sem/photo-enhancer-object-remover-background.html)

The page explicitly separates object removal from background removal. Its object
workflow is import, brush or rectangular selection, then removal, preview and export.
It advertises selection refinement with a magic brush. Background examples are grouped
as people, animals, products, logos, cars, real estate and billboards, with transparency
or a replacement backdrop. These are background-removal categories, not established
object-removal modes. The page serves desktop downloads; use its interaction ideas,
not its desktop UI, as mobile references. Speed and automatic-quality claims are
unverified marketing. Takeaway: let users correct the selection before processing and
inspect the result before committing. Do not copy desktop upload/export steps into
Lightly's existing mobile editing session.

## Proposed Lightly feature

- Purpose: erase distractions and fill the selected region plausibly from surrounding
  image context; preserve the intended person/subject and existing edits.
- Suggested location: evolve Edit → Remove into Eraser rather than add a duplicate
  top-level tool. Final name, placement and mock screens require approval.
- Primary selection: paint over unwanted content; adjustable brush size; zoom/pan;
  visible mask; add/subtract selection; clear selection. Consider a magnified view
  for finger precision. Lasso and tap-to-select are candidates, not commitments.
- Explicit Erase action, processing progress/cancel, before/after comparison and a
  way to refine and retry. Failed or cancelled work must not commit a partial result.
- Each accepted removal integrates with session Undo/Redo and recovery. Repeated
  removals accumulate on the same photo. Save copy preserves the original.
- Candidate examples: photobombers, litter, signs/text overlays, small skin spots,
  poles/wires and clutter. Thin structures, large regions and patterned backgrounds
  must be evaluated rather than advertised as universally supported.
- Background cut-out/replacement stays a separate operation. Text-to-image generation,
  canvas expansion, object replacement and video erasing are outside this request.
- Follow Lightly's existing on-device/no-account privacy requirements. Do not infer
  that competitors meet them or silently introduce a remote processing service.

## Design and quality acceptance before implementation completion

1. Approve the full interaction states in docs/ui: entry, selection, correction,
   processing, cancellation/error, result, refinement and Undo/Redo. Cover the agreed
   phone, foldable and tablet layouts using shared components.
2. Evaluate real saved results on independent images: flat backgrounds, grass/water,
   brick/text patterns, lines crossing the selection, people beside the removal,
   image edges, small defects and large removals. Inspect full image and 1:1 crops.
3. Reject seams, repeated textures, smears, invented subject details and unintended
   changes outside the documented feathered region. Preview must match saved output.
4. Verify photo-switch and cancellation races, repeated removal, recovery, orientation,
   export dimensions and memory on supported physical devices. Report actual timings;
   no borrowed competitor speed promises.
5. Reuse the current inpainting work only where it meets these checks. Model selection,
   provenance and distribution readiness remain engineering evidence to establish.

## Next action

Roadmap only now. At the 1.1 planning stage, review the current Remove implementation,
resolve its relationship to Eraser, present precise mock screens, then implement the
approved design. Do not interrupt current 1.0 completion for new Eraser experiments.
