# Auto experiment 1: closing report

Status: closed 2026-10-03. Not legal advice. The code is in `experiments/auto/`. Measurements are in `docs/m3/auto-progress.md` §7–§8. Data status and owner decisions are in `docs/v1/auto-data.md`. Nothing here is linked into either app.

## 0. Decision and release status

- **The model is not shipped.** `photo_a_001` and every gated variant of it stay research artefacts. They are git-ignored and archived privately (§7).
- **No substitute.**
  - No fixed filter, heuristic or control arm is presented as AI Auto.
  - The fixed control (`control_levels_greyworld`) is labelled NOT AI Auto in every result. It is worse than the model on held-out data.
  - The promised Auto behaviour is not weakened to fit what exists. This includes image-adaptive correction that leaves good photos alone and does not harm any scene class or skin tone.
- **Auto is an unresolved release requirement.** It stays open in the release tracking until a candidate passes S1–S5 of `docs/m1/auto-training-plan.md` on a frozen T1 set *and* the preference study (§4) shows that people prefer it. The current status of each gate is below.

| Gate | Status after experiment 1 |
|---|---|
| S1 rubric (frozen T1 set) | **Not met.** No T1 set exists. On the public held-out set PH-1, the model fails sunset, night, backlit and already-good |
| S2 already-good | **Not met.** PH-1 already-good mean ΔE00 is 3.44 (limit 3). The preference half is unmeasured |
| S3 preference | **Not measured** (§4) |
| S4 device parity | **Not measured** on phones. The desktop export parity passes |
| S5 provenance | **Open.** Counsel questions are in `auto-data.md` §3.4 |

## 1. What was built

| Item | Value |
|---|---|
| Model | `photo_a_001`: the ia3dlut contract. A 270,083-parameter classifier on the pinned 256 × 256 antialiased resize outputs 3 raw weights for 3 basis LUTs at 33³, fp32. Checkpoint at step 4000, chosen on validation only |
| Training | Self-supervised stage (a): plan §4(a) synthetic degradations of clean photos. The model learns to undo exposure, white balance, phone tone map, gamma, contrast, saturation and flatten. 25% identity samples. 6,000 steps, batch 8, CPU, 31 min. The full configuration and seeds are in `results/heldout_v1/run_card_photo_a_001.json` |
| Training code | Fingerprint `58145a11…` (`train.py` + `synthetic.py` + `lut_torch.py`). It equals the committed code: the files were last changed in `17ed6a0`. The run card's `code_commit` (`d5002bb`) is the repository HEAD at training time, before the auto code was committed. The fingerprint is the binding record |
| Training data | CC0REF: 5,182 CC0 photos from PD12M (Commons 3,810 + iNaturalist 1,372), 640 px. Split by capture session into train 4,340 / validation 542 / HO-SYN 300. Manifest `manifests/cc0ref_manifest.csv` (file sha256 `778cfe25…`), provenance `manifests/cc0ref_provenance.csv` |
| Frozen test sets | **PH-1:** 370 CC0/PD Commons photos. 331 are phone photos from 9 brands. Frozen and hashed before any photo training (`manifests/ph1_FROZEN.json`, rows hash `241d0f13…`).<br>**HO-SYN:** the 300-photo CC0REF held-out split, with per-image degradations fixed by each file's sha256 |
| Evaluation code | Protocol 1.0.0. `PROTOCOL.json`, `rubric.py` and `stats.py` are locked by `PROTOCOL.lock` (combined `e9dec2f5…`). `run_eval.py` produces PH-1 results; `eval_synthetic.py` produces HO-SYN results |
| Exports | Core ML fp32, ONNX opset 17, TFLite fp32, and the basis-LUT bin. modelVersion `candidate-c8059ab6b59610aa`. Desktop parity is within 7e-6, against a 1e-3 tolerance |
| Rights | No FiveK, Unsplash or Pexels data. Trained only on rows that PD12M records as CC0. Counsel questions 2–3 are open |

## 2. What "portraits passed" measures

On PH-1, `photo_a_001` passed the portrait class: 53 of 59 images. That result means exactly this.

**The protocol checks.** Under protocol 1.0.0, a portrait is judged only on its face skin. The skin mask is the central 60% of each detected face box (Apple Vision, confidence > 0.6), limited to skin-like hue and chroma in the original. On that mask:

| Check | Limit | What it catches |
|---|---|---|
| Median skin hue shift \|Δh\| | ≤ 4° | The model turning faces greener, redder or more orange |
| Skin chroma ratio (output / original) | ≤ 1.12 | Over-saturated skin |
| Skin lightness ΔL* > 0 | Only on images labelled `face_underexposed` | Failing to brighten an under-exposed face. **PH-1 has no such labels, so this check never ran** |

**The class rule.** The class passes when both hold:
- the class mean of each check is within its limit;
- at least 80% of portraits pass individually, judged on the point estimate.

Every check is a **preservation (harm) limit**. Nothing in the portrait rubric asks whether the face, or the photo, looks better.

**Passing a preservation threshold does not establish that the correction improves a portrait.** The PH-1 numbers show the gap.
- The unchanged Original passes all 59 portraits by construction.
- The model changes portraits more than any other class: mean ΔE00 4.08, p90 8.44.
- It darkens faces:
  - median skin ΔL* is −2.65, and the mean is −3.70;
  - 21 of 59 faces lose more than 5 L*, and 17 of those 21 still **pass**.
- Whether those darker faces look better or worse is exactly what the rubric cannot say. Only the preference study (§4) can.
- **"Portraits passed" means:** the model did not shift skin hue by more than 4° or raise skin chroma by more than 12% on at least 80% of faces, and on average.
- **It does not mean:** that portraits improved, that faces were exposed well, or that the result is fair across skin tones. There are no MST labels, so the skin-tone breakdown is unmeasured.

## 3. Results, reported separately

The three questions below are independent. A good answer to one says nothing about the others.

### 3.1 (a) Synthetic-degradation recovery: can it undo known global degradations?

- **Data.** HO-SYN: 300 CC0 photos, session-disjoint from training and validation, never tuned on. Each photo gets one frozen degradation from the plan §4(a) sampler: 230 degraded, 70 identity.
- **Metric.** Mean ΔE00 between the output and the clean original, over the 230 degraded images.

| Arm | Mean ΔE00 to clean (95% CI) | Median | Share improved vs input | Share worse by > 1 |
|---|---|---|---|---|
| Degraded input, unchanged | 8.71 (8.10–9.36) | 7.32 | — | — |
| Fixed control (NOT AI Auto) | 9.09 (8.46–9.75) | 7.36 | 0.41 | 0.34 |
| `photo_a_001` | **6.64 (6.26–7.05)** | 6.16 | **0.69** | 0.16 |

**Result.** It recovers part of the degradation: error falls 24% on average, and 69% of images improve. It is far from the plan's synthetic G1 bar (median ≤ 2.0); the median is 6.16. The degradations are synthetic and global, so this does not show that it fixes real phone failures.

### 3.2 (b) Preservation of already-good photos: does it leave good photos alone?

Two held-out measurements, plus the scene-specific harm found on PH-1:

| Measurement | Data | Limit | `photo_a_001` | Original |
|---|---|---|---|---|
| Identity drift: mean ΔE00, output vs input on undegraded photos | HO-SYN, 70 identity samples | Plan G1: ≤ 1.5 | **3.31** (2.79–3.90); only 20% ≤ 1.5 | 0.00 |
| Already-good class: mean ΔE00 | PH-1, 60 "would post unedited" photos | ≤ 3 | **3.44** (2.95–3.97); 32/60 pass. **FAIL** | 0.00, PASS |
| Night: median ΔL* ≤ 3, new black clip ≤ 0.5 pp | PH-1, 60 | ≥ 80% pass | 43/60. **FAIL**: 11 nights lifted by more than 3 L* | 60/60 |
| Sunset: warm chroma 0.95–1.10, \|Δh\| ≤ 4° | PH-1, 54 | ≥ 80% pass | 36/54. **FAIL**: 17 sunsets desaturated below 0.95 | 54/54 |
| Backlit: subject ΔL* > 0, new highlight clip ≤ 0.5 pp | PH-1, 54 | ≥ 80% pass | 9/54. **FAIL**: subjects darkened on average (−0.86) | 0/54 (it is a "must correct" class) |
| Portrait: skin limits (§2) | PH-1, 59 | ≥ 80% pass | 53/59, PASS. Preservation only | 59/59 |

**Result.** It does **not** leave good photos alone. It changes a photo that needs nothing about as much as it changes a degraded one (mean ΔE00 3.3–3.4). The scene-specific harm is lifted nights and desaturated sunsets. §5 tests whether a gate can fix this.

### 3.3 (c) Human preference: does anyone prefer the result? **Not measured.**

No person has compared `photo_a_001`'s output with the Original or with any baseline. Nothing in (a) or (b) substitutes for that:
- (a) measures distance to a synthetic target;
- (b) measures distance from the input.

A model could score perfectly on (b) by doing nothing.

## 4. The study that would measure preference

This is the design the plan specifies (S2, S3). Its sizes are **proposals**; the rationale is in `auto-data.md` §3.3.

- **Comparison.**
  - Blind paired comparison on one calibrated display, with left and right randomised.
  - Each pair is the candidate against the Original, and the candidate against the platform baseline (Core Image auto on iOS).
  - Raters answer "Which would you rather keep?" with no "same" option. A separate "no visible difference" flag is recorded.
- **Photos.** The frozen T1 set, by class. Each skin-tone group is reported separately.
- **Raters.** Proposed ≥ 8, mixing photographers and non-photographers. For portraits, ≥ 30% from skin-tone groups other than the subject's majority.
- **Size.** About 100 pilot comparisons to estimate rater agreement and the design effect. Then:
  - about **195 comparisons per arm pair**, to detect a 60% preference against 50%;
  - about **785 comparisons on already-good photos**, for S2 non-inferiority at a 45% margin.

  The plan never computed the second figure, and it is the dominant cost.
- **Pass.**
  - S3: the 95% CI lower bound of the preference share is above 50% overall.
  - No class or skin-tone group is significantly worse than the Original.
  - S2: on already-good photos, the CI lower bound is ≥ 45%.
- **Prerequisites.**
  - A candidate that first passes the rubric on a frozen set; otherwise the study would rate a known-harmful model.
  - T1 photos with consent.
  - Raters you recruit.

## 5. Conservative gating: can a gate leave good photos alone and avoid the night and sunset failures?

### 5.1 What a gate is here

A gate picks a strength s between 0 and 1 for each photo and applies `identity + s × (model LUT − identity)`.
- **s = 0** returns the photo unchanged; **s = 1** is the ungated model.
- **It never adds a correction of its own.** Without the model, nothing is left to apply, so a gate cannot turn a fixed filter into "AI".
- **It runs on device.** Every input comes from the 256-pixel model input and the model's own LUT. The code is `lightly_auto/gating.py`; the arm spec is `gated:<run>@<config>`; the tests are in `tests/test_gating.py`.

Three mechanisms were tested:
1. **Predicted-change soft threshold.** The applied change shrinks to roughly max(0, m − deadzone), where m is the model's own predicted ΔE00 on the preview.
2. **Learned "already-good" detector.** A logistic regression over preview statistics, the model's three weights and m. It was fitted on 1,000 CC0REF **train** photos (clean vs synthetically degraded). Below the threshold, s = 0.
3. **Scene-aware constraints.** Starting from that strength, s is lowered (never raised) until the 256-pixel preview satisfies all of:
   - dark scenes (median L* < 35): median L* lifts ≤ 1.5;
   - warm highlights: chroma ratio ≥ 0.98 and \|Δh\| ≤ 2.5°;
   - new clipping ≤ 0.25 pp.

   These are the protocol limits with margin. **They mirror the rubric, so a gate that uses them passes the rubric partly by construction.**

### 5.2 Development: validation split only

- **Data.** The 542 CC0REF validation photos, never PH-1 or HO-SYN.
  - Each photo was scored **clean**: a reference photo needing nothing, the stand-in for already-good.
  - Each was also scored **with one synthetic degradation**.
  - Night (37) and sunset (32) photos were tagged from PD12M's machine captions. The tags are noisy and are used for reporting only; no gate reads them.
- **What was swept.** Only the deadzone and the detector threshold. The scene-constraint thresholds were set once, before the study.
- **Results.** `results/gating_v1/validation/summary.md`. The table shows selected rows.

| Gate (validation) | Clean: mean ΔE00 to input | Clean ≤ 3 | Clean left unchanged | Degraded: mean ΔE00 to clean (input 8.68) | Recovery retained | Night-tagged fail | Sunset-tagged fail |
|---|---|---|---|---|---|---|---|
| Ungated model | 3.48 | 0.55 | 0.00 | 6.65 | 1.00 | 0.30 | 0.28 |
| Deadzone 2.5 | 1.37 | 0.84 | 0.46 | 7.11 | 0.77 | 0.11 | 0.16 |
| Deadzone 5 | 0.49 | 0.95 | 0.78 | 7.71 | 0.48 | 0.05 | 0.09 |
| Scene constraints only | 2.43 | 0.76 | 0.02 | 7.04 | 0.81 | 0.00 | 0.03 |
| Detector 0.6 | 0.98 | 0.87 | 0.84 | 7.02 | 0.82 | 0.08 | 0.12 |
| Deadzone 2.5 + scene | 1.04 | 0.90 | 0.50 | 7.45 | 0.61 | 0.00 | 0.03 |
| **Detector 0.6 + scene = gate_v1** | **0.78** | **0.91** | **0.84** | **7.40** | **0.63** | **0.00** | **0.03** |

**Findings (validation only).**
1. **The failures reproduce on validation.** Ungated, the model fails 30% of night-tagged and 28% of sunset-tagged clean photos, and changes clean photos by 3.48 ΔE00. This matches PH-1, so the gate could be developed without touching the frozen sets.
2. **Scene constraints fix the night and sunset failures on validation.** Failures drop to 0% and 3%, at the cost of 19% of the recovery.
3. **The model cannot tell well which photos need correcting.**
   - Its own predicted change separates clean from degraded photos with an AUC of only **0.66**.
   - The learned detector reaches **0.76**, on train and on validation alike.
   - Part of this is irreducible: a clean dark photo and an under-exposed one can be the same image.
4. **Preservation is bought with recovery.** Settings that bring clean photos under 1 ΔE00 keep 46–82% of the model's recovery. The detector alone does best, but still fails 8% of night-tagged and 12% of sunset-tagged photos. Adding the scene constraints that remove those failures brings the range to 46–67%. The share of degraded photos that improve falls from 72% ungated to 32–53%; for gate_v1 it is 46%.
5. **Selection rule, applied on validation:** maximise recovery retained, subject to clean ≤ 3 on at least 90% of photos and night and sunset failures each ≤ 10%. It selected gate_v1 (`gating/gate_v1.json`). On DEV-22 (development data) gate_v1 acted on only 4 of 22 photos.

### 5.3 One pre-registered check on the frozen sets

- **Pre-registration.** The gate, its parameters, the hypotheses and the exact commands were committed in `gating/PREREGISTRATION_gate_v1.json` (commit `61af3c6`) **before** the run.
- **The run.** It was run **once** (commit `c076dd0`) and is reported as it came out. No PH-1 image was viewed while the gate was chosen. The PH-1 before/after sheets were made only after the run.
- **Comparators** are the committed ungated results; they were not re-run.

| Pre-registered hypothesis | Result | Supported? |
|---|---|---|
| H1 PH-1 already-good passes S1 | 55/60 pass, mean ΔE00 0.62 (ungated: 32/60, 3.44) | Yes |
| H2 PH-1 night passes | 60/60, median ΔL* +0.14 (ungated: 43/60) | Yes |
| H3 PH-1 sunset passes | 52/54, warm chroma 1.00 (ungated: 36/54) | Yes |
| H4 PH-1 portrait passes (preservation only) | 56/59 (ungated: 53/59) | Yes |
| H5 PH-1 backlit fails (predicted: a gate cannot raise a subject) | 5/54, subject ΔL* −0.34 | Yes, it fails as predicted |
| H6 HO-SYN identity drift ≤ 1.5 | 1.18 (95% CI 0.63–1.81); 77% of photos ≤ 1.5 (ungated: 3.31, 20%) | Yes, point estimate. The CI crosses 1.5 |
| H7 HO-SYN still recovers (CI upper bound < 8.71) | 7.27 (6.77–7.82); 46% improved, 6% worse by > 1 (ungated: 6.64, 69%, 16%) | Yes. It keeps 69% of the ungated recovery |

**Pre-registered descriptive result:** the gate left **82% of PH-1 photos exactly unchanged** (s = 0). It acted on 68 of 370:

| | Portrait | Sunset | Night | Backlit | Already-good | Landscape | Indoor |
|---|---|---|---|---|---|---|---|
| Unchanged | 69% | 80% | 83% | 83% | 85% | 77% | 95% |

**What this shows.**
- **A conservative gate can make the model meet the preservation limits** on these public held-out sets. It fixes the night and sunset failures and leaves already-good photos alone.
- **It does so mostly by abstaining.** On real photos the detector rarely fires: it abstains on 83% of backlit photos, which are exactly the photos that need correcting. The passes are therefore close to what the unchanged Original gets by construction.
- **It is not evidence of improvement, and not a fix for Auto.** On the 18% of photos where it acts, whether people prefer the result is unmeasured.
- **Not the G0 set.** PH-1 is not the T1 G0 set.
- **PH-1 has now been scored for two candidates.** A next iteration must be judged on a new frozen set.

**Conclusion.** Gating is a useful safety layer, and the planned already-good and night hinges should be trained into the next model rather than bolted on. But the core problem is upstream: a model trained only on synthetic global degradations neither knows when a real photo needs help nor corrects real backlit, night or sunset failures. That needs the T1 data and labels in `auto-data.md` §3. **gate_v1 is not shipped either.**

## 6. Data needs: proposals, not requirements

Every count in `docs/v1/auto-data.md` §3 is a **proposed study parameter**. You did not set them, and each carries its rationale:
- a power calculation;
- variance measured on PH-1 and DEV-22;
- or coverage logic.

No collection request has been sent. One should go out only after you accept or change them. In summary:

| Parameter | Proposed | Basis |
|---|---|---|
| Images per gated class | 40 | Protocol 1.0.0 minimum. The PH-1 σ_d gives MDDs well inside the targets. It screens gross harm; it does not certify the 80% rule (a true 0.80 pass rate passes 59% of the time) |
| Night / backlit | ≈ 110 / ≈ 90 | Measured σ_d 3.71 / 3.33 L* → MDD of 1 L* (itself a proposal) |
| 80% rule on the CI lower bound (if you choose it) | ≈ 115 per class | 80% power at a true pass rate of 0.90 |
| Skin tone | ≥ 24 per MST group (30% of ≥ 80) | Protocol rule. A harm screen only; an equality test needs about 60–100 per group |
| Contributors | ≥ 10 per class, ≤ 4 images each per class | Contributor ICC 0.16–0.18 measured on PH-1 → design effect about 1.5 |
| Phone brands | ≥ 6, none > 30% of a class, plus 1 held-out device model | Coverage of maker-specific tone mapping. The brand list needs a sourced market-share figure for your launch markets |
| Validation split | 100–150 (about 20 per class) | Tuning only |
| Preference: comparisons | ≈ 195 per arm pair; ≈ 785 for already-good non-inferiority | 60% vs 50% at power 0.8 (60% is a proposal); 45% margin |
| Raters | ≥ 8; ≥ 30% of portrait raters from other skin-tone groups | No rater above 12.5% of judgements; coverage |

The dataset survey (`auto-data.md` §1) is now a per-dataset assessment of the sources examined. Each row separates the code licence, the weights licence, the dataset terms (evaluation vs training) and the people/privacy question. It replaces categorical claims such as "no public dataset fits".

## 7. Archive (outside Git)

- **Location.** `~/.codex/artifacts/lightly/v1/auto-experiment-1/`, 2.1 GB, 5,619 files, all listed in `SHA256SUMS`.
- **Built by.** `archive_experiment.py --with-data` at commit `66c413d`.
- **Verify** with `shasum -a 256 -c SHA256SUMS`. The sha256 of the SHA256SUMS file itself is `cf2f297a…`.
- **Instructions.** `REPRODUCE.txt` has the exact restore and reproduction commands.

| Folder | Contents |
|---|---|
| `model/photo_a_001/` | Selected checkpoint `classifier.pt` (`5441b561…`) and `basis_luts.npy` (`764046e7…`), the step-6000 checkpoint, run card, training log, and exports: Core ML, ONNX (`00b6e75a…`), TFLite (`1109a645…`), LUT bin |
| `config/` | Protocol 1.0.0 and its lock, the gate configs and pre-registration, and the Python environment freeze (Python 3.11.16, torch 2.5.1, numpy 2.4.6, scikit-image 0.26.0, scikit-learn 1.9.1) |
| `manifests/` | CC0REF and PH-1 manifests and provenance, `ph1_FROZEN.json`, DEV-22, and the pinned PH-1 face file |
| `data/` | The exact image bytes the manifests hash: 5,182 CC0REF references and 370 PH-1 proxies. Large data stays out of Git |
| `code/` | `git archive` of `experiments/auto` and `experiments/lut3d/reference` |
| `results/` | Ungated held-out results, the gated pre-registered run, the validation study and its per-image cache |
| `sheets/` | Before/after sheets: PH-1 per class (worst failures, median and a passing example, picked by rule) and HO-SYN. They show identifiable people from CC0 photos, so they stay private |

**Not archived.** The FiveK research weights, which are research-only.

## 8. Reproduction

From `experiments/auto/`, after restoring `data/` and `runs/photo_a_001/` from the archive. The heavy steps run under `OMP_NUM_THREADS=2 lockf -k /tmp/lightly-heavy.lock`.

```
python -m pytest tests                     # 49 tests
python train.py --run-id photo_a_001 --data manifest:manifests/cc0ref_manifest.csv --steps 6000 --val-every 500
python export.py runs/photo_a_001 && <venv_tflite>/bin/python export_tflite.py runs/photo_a_001
python eval_synthetic.py --manifest manifests/cc0ref_manifest.csv --arms original,control_levels_greyworld,run:runs/photo_a_001 --out results/heldout_v1/hosyn_photo_a_001
python run_eval.py --manifest manifests/ph1_manifest.csv --faces manifests/ph1_faces.json --arms original,control_levels_greyworld,run:runs/photo_a_001 --out results/heldout_v1/ph1_photo_a_001
python gate_study.py cache && python gate_study.py features --split validation
python gate_study.py features --split train --limit 1000 && python gate_study.py fit-detector
python gate_study.py analyse
# pre-registered, already run once; do not re-run to tune:
python run_eval.py --manifest manifests/ph1_manifest.csv --faces manifests/ph1_faces.json --arms gated:runs/photo_a_001@gating/gate_v1.json --out results/heldout_v1_gate_v1/ph1 --threads 2
python eval_synthetic.py --manifest manifests/cc0ref_manifest.csv --arms gated:runs/photo_a_001@gating/gate_v1.json --out results/heldout_v1_gate_v1/hosyn --threads 2
python make_before_after.py --gate gating/gate_v1.json
python archive_experiment.py --dest ~/.codex/artifacts/lightly/v1/auto-experiment-1 --with-data
```

Retraining was not re-run to check bit-exactness; the archived checkpoint is the reference. The evaluation runners are deterministic for a given protocol lock, manifest hash and arm.

## 9. Commits

| Commit | Content |
|---|---|
| `61af3c6` | Gate code, validation study and results, detector, gate_v1, **pre-registration** |
| `c076dd0` | The single pre-registered PH-1 / HO-SYN run of gate_v1 |
| `66c413d` | Archive and before/after sheet tools |
| this commit | This report, the rewritten `auto-data.md`, `auto-progress.md` §8 |
