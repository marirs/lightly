# Fresh validation set for the no-subject rule (A5, 2026-10-06)
Photos the rule was never measured on: PD12M CC0 (`experiments/auto/data/pd12m/eval_originals`), excluding the 41 of the
independent set; captions without people. Batch 1 (`selection.json`, 75): every candidate whose caption says small, tiny,
lone, single, distant, alone or solitary (45), plus 30 seeded-random (20261006). Batch 2 (`selection-batch2.json`, 30):
seeded-random among captions naming an object (bird, boat, animal, bench, statue, lamp …).
Labels (`labels-batch1.json`, `labels-batch2.json`) set by eye from contact sheets **before any model output**, committed
before the rule was run: subject = a separable person or object in front of its background (small ones included); none =
scenery, architecture filling the frame, sky; ambiguous otherwise. Small subjects are scarce in this pool: only 48 (a sign
post in a field) and B20 (a bench by a path).
