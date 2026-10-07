# A5: object-detector label coverage (2026-10-07, before any download)

EfficientDet-Lite0 detects the 80 COCO categories only. The 31 subjects labelled in our three sets, by eye:

| Set | Covered by a COCO class | Only through a wrong class | Outside the vocabulary |
|---|---|---|---|
| fresh (12) | bowl, truck, cell phone, bench, vase | mannequin, skeleton (person?) | shrine, field sign, cereus flower, display case, lighthouse |
| independent + edges (7) | vase, cat, swan (bird), boat, swan | — | Buddha statue, chandelier |
| validation (12) | tram (train), chair, potted palm, motorcycle, boats, van (car/truck) | owl statuette (bird?), leaf (potted plant?) | flowers, thistle, lifeguard tower, street sign |
| **total (31)** | **16** | **4** | **11** |

**The rule proposed earlier ("subject only when a detection overlaps the salient region") is withdrawn:** it would have
refused about half of real subjects, silently restricting Lightly to COCO's 80 categories.

**Corrected role: supporting evidence only.** A detection overlapping the confident region can *add* evidence for a
subject; no detection never establishes that there is no subject. Valid subjects outside the vocabulary stay decided by
the existing class-agnostic evidence (U²-Netp's confident region and the depth step), exactly as now.

**Consequence:** a supporting-only detector can only raise the share of subjects found. It cannot lower false subjects,
which is where the area-and-depth rule already stands at 3/82 on the fresh set (its weakness was recall: 9/12; of the
three missed, the truck is in the vocabulary, the display case is not, the vase is below the 2 % area). The download is
therefore worth it only for recall, with an expected gain of about one subject in twelve. No download is requested until
that trade-off is decided; the validation set (labels committed before any run) stays unused.

## Decision (owner, 2026-10-07)
EfficientDet is deferred: its expected benefit does not justify another integration now. **A5 stays open.** The
class-agnostic rule (U²-Netp confident area and depth step) is not a solution: on the fresh set it found 9 of 12 subjects
and called 3 of 82 subject-free photos subjects, and no threshold separates the classes.
