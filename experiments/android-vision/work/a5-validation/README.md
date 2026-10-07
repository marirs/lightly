# A5 validation set (2026-10-07)
100 PD12M CC0 photos never used for the no-subject rule (not in the independent or fresh sets), captions without people;
60 seeded-random (20261007) among captions naming an object, 40 among the rest (`selection.json`). Labelled by eye from
`sheet0-3.jpg` before any model output, with the definitions of u2netp-fresh: subject = a separable person or object in
front of its background (small ones included); none = scenery, architecture filling the frame, sky; ambiguous
otherwise. 12 subject, 77 none, 11 ambiguous. For the semantic-agreement rule (object detector), not yet run.
