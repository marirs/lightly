# Auto develop model: progress against the training plan (M3)

Status: 2026-10-02, updated 2026-10-03 (§7: public data, the first photo-trained model, held-out results; §8: experiment 1 closed, conservative gating). This note follows `docs/m1/auto-training-plan.md` in plan order. The code is in `experiments/auto/`, and nothing in it is linked into either app. The apps are unchanged.

**Experiment 1 is closed (read §8 and `docs/v1/auto-experiment-1-report.md` first).**
- **Not shipped.** `photo_a_001` is not shipped, and neither is any gated variant of it.
- **Auto is still an unresolved release requirement.**
- **Reported separately:**
  - synthetic recovery;
  - preservation of already-good photos;
  - human preference, which is **not measured**.
- **"Portraits passed" is a preservation result,** not an improvement result.
- **Gating.** A conservative gate developed on validation was checked once, pre-registered, on PH-1 and HO-SYN. It meets the preservation limits by leaving 82% of PH-1 photos unchanged.
- **Proposals, not requirements.** Photo, contributor, brand and rater counts are proposed study parameters, with rationale, in `docs/v1/auto-data.md` §3.

**Update 2026-10-03 (§7).**
- **There is now an image-adaptive model trained on photos**, `photo_a_001`. It is self-supervised on CC0 photos only and does not use FiveK.
- **It has been scored on two genuinely held-out sets:**
  - PH-1: 370 frozen CC0/PD phone and camera photos, scored with the frozen rubric;
  - HO-SYN: 300 photographer/session-disjoint photos with frozen synthetic degradations.
- **It is still not releasable as AI Auto.** It fails S1 on sunset, night, backlit and already-good. It also changes already-good photos by mean ΔE00 3.4.
- **Data needs.** What still needs the owner is listed precisely in `docs/v1/auto-data.md`.

**Read this first (2026-10-02 state; §0–§6 are unchanged history).**
- **No AI Auto existed on 2026-10-02.** Every arm measured below is either:
  - the unchanged Original;
  - a fixed, non-learned control;
  - the FiveK research model, which is research-only and never ships;
  - a pipeline smoke model trained on procedurally generated scenes.

  None of them is an AI Auto candidate, and none may be described as one.
- **No held-out evaluation has been possible.** The frozen held-out set the plan requires does not exist yet. Section 2 says what is needed to create it.
- **The 22 M1 photos ("DEV-22") are development data.** M1 used them to tune the guardrails and local exposure and to pick settings. No number on them is an evaluation result or evidence of quality.

## 0. Change against the plan's §0 status table

| Claim | Plan §0 status | Now | Basis |
|---|---|---|---|
| Evaluation protocol (G0 rules: rubric as code, S1 rule, CIs, already-good ΔE00 ≤ 3) | not started | **Frozen as protocol 1.0.0** (rules and code only) | §1 |
| Frozen held-out evaluation set (G0 data) | not started | **Does not exist.** It needs T1 phone captures | §2 |
| Baselines on a fixed runner | ad hoc M1 scripts | **Measured on DEV-22**, as pipeline verification only | §3.2 |
| Training pipeline obeys the deployment contract | not started | **Validated on desktop:** it trains, exports to Core ML fp32 and ONNX, and the exports match torch within 8e-6 | §3.3 |
| Stage (a) exit criteria (G1) | hypothesis | **Not met, even on procedural synthetic data**, at smoke budget | §3.4 |
| Guardrails meet the rubric | experimental, tuned on DEV-22 | **Unchanged.** guard75_hp passes portrait and sunset on DEV-22, but that is the set it was tuned on, so this is not new evidence | §3.2 |
| iOS/Android parity, Android inference | as in the plan | unchanged (not in scope) | — |

## 1. Evaluation protocol 1.0.0 (G0, rules part)

The files are `experiments/auto/PROTOCOL.json`, `PROTOCOL.lock`, `lightly_auto/{rubric,stats,manifest,protocol}.py` and `run_eval.py`. The tests are in `experiments/auto/tests/` (36 tests, all passing).

### 1.1 Targets and pass rules

| Item | Frozen rule |
|---|---|
| Per-class targets | From `spec.md` §1.1: |
| | skin: \|Δh\| ≤ 4°, chroma ratio ≤ 1.12 |
| | sunset: warm chroma 0.95–1.10, \|Δh\| ≤ 4° |
| | night: median ΔL* ≤ 3, new black clip ≤ 0.5 pp |
| | backlit: subject ΔL* > 0, new highlight clip ≤ 0.5 pp |
| | already-good: mean ΔE00 ≤ 3 |
| Skin | Applies to every image that has a detected face, not only portraits. A portrait with no usable face mask is *unscorable*; it is never a free pass |
| Face under-exposure ("must correct") | Gated (skin ΔL* > 0) only on images an annotator labels `face_underexposed`. It is never inferred from an L* threshold, because any fixed threshold would label deep skin tones as under-exposed |
| Not automated in v1 | Crushed sunset foreground and blocked night shadows (both need masks). These go to the preference study |
| Landscape, indoor mixed | No spec target, so they are reported but not gated (owner decision D3) |
| S1 class rule | Pass when both hold: (a) the class mean of every gated metric meets its target; (b) **≥ 80% of images in the class pass**, judged on the point estimate. Percentile bootstrap CIs (10,000 resamples, fixed seed) and exact Clopper–Pearson CIs are reported. Clopper–Pearson is included because the bootstrap collapses to [p, p] when every image passes |
| Analysis resolution | The 2048 px long-edge preview proxy. The model input is the pinned antialiased 256 resize of that proxy |
| Face detector | Pinned via faces.json (Apple Vision, conf > 0.6). Its sha256 is recorded in every run |
| Drift control | `PROTOCOL.lock` pins the sha256 of PROTOCOL.json, rubric.py and stats.py. The runner refuses to score if any of them changes without a version bump |

### 1.2 Frozen-set and training-rights checks

| Check | Rule |
|---|---|
| Frozen-set checks (code, `check_frozen_eval_set`) | ≥ 40 images per gated class |
| | each MST bucket (1–3, 4–7, 8–10) ≥ 30% of portrait + backlit |
| | T1 tier only |
| | documented `eval` right per image |
| | no exact (sha256) or near (DCT pHash, Hamming ≤ 6) duplicate in any train or validation manifest |
| Training-rights gate (`assert_training_rights`) | A run fails if any input lacks a documented `train` permission, is in the frozen eval split, or comes from the `unsplash_dev` or `fivek_research` tier. The test `test_dev22_photos_can_never_be_training_data` proves that DEV-22 is refused |

### 1.3 Departures from the M1 `evaluate.py`

These departures are deliberate:
- **Resolution.** Metrics are computed at the proxy rather than at 1/4 resolution.
- **Absolute hue shifts.** The rubric uses |Δh|, so a class mean cannot cancel out.
- **Labelled under-exposure.** Face under-exposure is gated only on labelled images, as described above.

Re-running the four baseline arms gave identical numbers. This confirms that the runner is deterministic.

## 2. Evaluation on genuinely held-out photos

**Today there are no held-out photos.** No evaluation result exists for any arm. Everything in §3 is pipeline verification.

**Definition (frozen in PROTOCOL.json, plan §3.4).** The held-out set is:
- built and hashed **before any training run**;
- never used for tuning, thresholds or model selection;
- scored only at gates;
- retired and rebuilt if it is ever used for a decision.

**What is needed to obtain it:**

| Item | Requirement |
|---|---|
| Count | At least 40 per gated class: portrait, sunset/golden hour, night, backlit, already-good. That is **≥ 200 images**, or **about 280** with landscape and indoor-mixed (reported classes) at 40 each |
| Skin-tone coverage | Portrait + backlit = ≥ 80 images, with each Monk bucket (1–3, 4–7, 8–10) at ≥ 30%, so **≥ 24 per bucket**. Two annotators label each, plus self-identification where offered |
| Devices | ≥ 6 brands (Apple, Samsung, Google, Xiaomi, Motorola, Nothing). One complete device model is held out as an unseen-device test |
| Capture | HEIC/JPEG straight from the default camera, with no edits and no recompression. Keep the original and its sha256. Location EXIF is stripped |
| Labels | Rubric class, MST bucket, and the `face_underexposed` flag where it applies |
| Licence | **T1 only.** The contributor's written IP assignment or licence must cover evaluation, training and commercial shipping of the model. Model releases are needed for identifiable people. No minors. Revocation wording needs counsel. Unsplash photos can never form this set |
| Separation | It must be disjoint by contributor and capture session from the validation split (used for tuning) and from all training data. The pHash check enforces this |
| Who provides it | Team members and consenting contributors (plan §3.1, T1). **The owner decides who.** Counsel approves the consent and assignment form |

**Sizing evidence (planning only, estimated from DEV-22).** This comes from `results/dev22_pipeline_check_v1.0.0/mdd_research_auto100_vs_original.json`. The spread is image-to-image σ of paired differences (research model − Original), with n = 3–7 per class. It is a rough planning input, not a result.

| Class · metric | σ_d (DEV-22) | MDD at n = 40 |
|---|---|---|
| portrait · skin \|Δh\| (°) | 1.77 | 0.79 |
| portrait · skin chroma ratio | 0.20 | 0.09 |
| sunset · warm \|Δh\| (°) | 1.60 | 0.71 |
| night · median ΔL* | 3.39 | 1.50 |
| backlit · subject ΔL* | 1.21 | 0.53 |
| already-good · ΔE00 | 2.34 | 1.04 |

At n = 40, every MDD is below the 3–4 unit width of the targets. Night median ΔL* (MDD 1.5 against a target of 3) is the weakest. If the first T1 runs confirm σ_d ≈ 3.4, an MDD of 1 L* would need about 90 night images (plan §6.3 fallback: enlarge before G0).

## 3. Pipeline verification (NOT evidence of quality)

### 3.1 Data used

| Data | Contents | Rights | Use here |
|---|---|---|---|
| DEV-22 (`eval/dev22_manifest.csv`, hash `a7dae315…`) | 22 Unsplash photos: 7 portrait, 3 each of sunset, night, backlit, already-good, landscape | Unsplash Licence. **No ML training** (Terms §8) | Rubric runs only. M1 tuned on it |
| Procedural scenes (`lightly_auto/synthetic.py`) | Generated gradients, shapes, skin/sky/foliage colours, light sources, dark and bright regimes | Our own code. No third-party content | Smoke training and validation |
| FiveK research weights | Upstream `classifier.pth` and `LUTs.pth` | **Research-only** | Research baseline arm only |

**Deviation from the task suggestion.** The task suggested known LUT degradations of the 22 photos as a synthetic training set. That was not done: Unsplash Terms §8 forbids ML training use, and plan §3.1 says those photos never train. Procedurally generated scenes were used instead. They measure plumbing, not quality.

**No paired photo data exists locally.** The only FiveK image is the upstream demo `a1629`, so there was nothing research-only to train on either.

### 3.2 Rubric arms on DEV-22 (development data: pipeline check, not an evaluation)

The source is `experiments/auto/results/dev22_pipeline_check_v1.0.0/` (protocol 1.0.0). Each cell shows pass count / scorable images and the S1 verdict.

| Arm (label) | Portrait | Sunset | Night | Backlit | Already-good | Mean ΔE00, all 22 |
|---|---|---|---|---|---|---|
| Original. **NOT AI Auto** | 7/7 PASS | 3/3 PASS | 3/3 PASS | 0/3 FAIL | 3/3 PASS | 0.00 |
| Control: auto-levels + grey-world, non-learned. **NOT AI Auto** | 6/7 PASS | 0/3 FAIL | 2/3 FAIL | 0/3 FAIL | 0/3 FAIL | 3.58 |
| FiveK research 100%. **RESEARCH-ONLY** | 1/7 FAIL | 0/3 FAIL | 0/3 FAIL | 0/3 FAIL | 0/3 FAIL | 7.35 |
| FiveK research + guard75_hp. **RESEARCH-ONLY**, guardrails tuned on these images | 7/7 PASS | 3/3 PASS | 0/3 FAIL | 0/3 FAIL | 0/3 FAIL | 5.73 |
| Smoke `smoke_full_001` (procedural). **NOT a candidate** | 6/7 PASS | 3/3 PASS | 0/3 FAIL | 1/3 FAIL | 1/3 FAIL | 6.61 |

Class means on the same data (development data):

| Metric (target) | Original | Control | Research 100% | Research guard75_hp | Smoke |
|---|---|---|---|---|---|
| Skin \|Δh\|, portraits (≤ 4°) | 0.00 | 3.09 | 5.39 | 3.07 | 0.88 |
| Skin chroma ratio (≤ 1.12) | 1.00 | 0.93 | 1.38 | 1.08 | 0.99 |
| Sunset warm \|Δh\| (≤ 4°) | 0.00 | 7.61 | 5.98 | 3.54 | 1.86 |
| Sunset warm chroma (0.95–1.10) | 1.00 | 0.9497 (fails) | 1.05 | 1.01 | 1.04 |
| Night median ΔL* (≤ 3) | 0.00 | −0.68 | 6.22 | 6.20 | 11.80 |
| Night new black clip, pp (≤ 0.5) | 0.00 | 3.91 | 8.60 | 0.15 | −0.36 |
| Backlit subject ΔL* (> 0) | 0.00 | −4.00 | −5.38 | −2.55 | +0.19 |
| Backlit new highlight clip, pp (≤ 0.5) | 0.00 | 3.14 | −2.91 | −0.24 | 0.74 |
| Already-good ΔE00 (≤ 3) | 0.00 | 3.62 | 8.31 | 6.88 | 5.48 |

What this shows about the **tooling**, not about quality:
- **The rubric is necessary, not sufficient.** An unchanged Original passes every gated class except backlit, because most spec targets are *preservation* targets. Improvement must come from the preference study (plan §5.3). The rubric only screens out harm.
- **The runner agrees with M1.** The research-model numbers reproduce M1 feasibility §5.1: skin +5.4°/1.38, night +6.3, backlit −5.5, already-good 8.4. The small differences come from the 2048 px proxy and from using absolute hue values.
- **The CIs are uninformative at this size.** For 3 images with 3/3 passing, the exact 95% CI is 0.29–1.00. That is why the frozen set needs ≥ 40 per class.

### 3.3 Training and export smoke runs (procedural data: plumbing only)

**The contract is held in training.**
- The classifier sees only the pinned antialiased 256 resize of 8-bit-quantised input. It is bitwise equal to `ia3dlut.prepare_256_antialiased` (tested).
- There are 3 basis LUTs at 33³ with raw-weight fusion, in fp32.
- The differentiable trilinear matches the contract reference within 2e-6 (tested).
- The losses are:
  - pixel MSE;
  - upstream TV (λ 1e-4) and monotonicity (λ 10);
  - the plan §4 endpoint hinge (λ 1);
  - the warm-hue hinge (λ 0.01). It is small on purpose, because inverting a synthetic white-balance shift legitimately rotates warm hues.
- The night and already-good hinges are **deferred** until labelled photos exist. They are marked in the code.

**Training conditions.**
- CPU only, 4 threads, batch 8.
- 512 procedural training scenes; 128 validation scenes from a different seed.
- 25% of samples are identity samples.
- The machine was shared with simulator and emulator runs at load average 38–49, so the times are not representative.

| Run | Degradations | Steps | Train time | Val median ΔE00, start → end (input) | Identity samples median ΔE00 | Share of val images improved | Synthetic G1 (≤ 2.0 / ≤ 1.5) |
|---|---|---|---|---|---|---|---|
| `diag_exp` | exposure only | 1,000 | 20 min | 8.46 → **5.53** (8.47) | 1.26 → 4.20 | 0.40 → **0.74** | fail |
| `smoke_exp_wb_001` | exposure + WB | 2,000 | 10 min | 5.48 → 6.09 (5.21) | 1.30 → 5.17 | 0.38 → 0.48 | fail |
| `smoke_full_001` | full plan §4(a) mix | 3,000 | 14 min | 7.14 → 7.40 (7.27) | 1.03 → 7.04 | 0.43 → 0.58 | fail |

| Export (each run) | Result |
|---|---|
| Core ML fp32 mlpackage | 1.09 MB. Weights vs torch: max 1.9e-6 (CPU) |
| ONNX opset 17 | 1.08 MB. Weights vs torch: max 8.1e-6 |
| Basis LUT bin | 1.72 MB. Bit-exact round trip |
| Fused-LUT effect of export error | ≤ 0.0013/255 |
| Contract weight tolerance | 1e-3. All runs pass |

**What the runs establish:**
- **The pipeline learns** (`diag_exp`: 74% of validation images improved, median ΔE00 −35%).
- **It exports on contract,** with parity three orders of magnitude inside tolerance.

**What they do not establish:**
- **The synthetic G1 criteria are not met.** At this budget (8–24k sample presentations, against roughly 1.8M upstream) the full mix does not converge, and validation is noisy across checkpoints.
- **Identity samples drift in every run (1.0 → 4–7 ΔE00).** Part of this is an ill-posed task: the procedural generator includes dark and bright *clean* scenes, so a dark clean scene and an under-exposed one look alike. Real photos carry priors that procedural scenes lack. This is the plan §8 risk, "synthetic degradations do not match real phone failures", showing up before any real data.
- On DEV-22, the smoke model lifts night by +11.8 L* and changes already-good photos by ΔE00 5.5. As expected, it is **not** an Auto candidate.

**Rights status of the smoke weights.**
- They contain no FiveK and no Unsplash data, so they are not research-only.
- They are still not shippable, because they are plumbing artefacts.
- The weights stay in the git-ignored `experiments/auto/runs/`. Only the run and export cards are committed, under `results/smoke/`.

**Reproduce:**

```
cd experiments/auto
python -m pytest tests
python run_eval.py --manifest eval/dev22_manifest.csv --arms original,control_levels_greyworld,research_auto100,research_guard75_hp,run:runs/smoke_full_001 --out results/dev22_pipeline_check_v1.0.0
python train.py --run-id smoke_full_001 --steps 3000
python export.py runs/smoke_full_001
```

## 4. Research-only items

These stay git-ignored and are never bundled in an app:
- the FiveK weights in `experiments/lut3d/reference/upstream/`;
- the converted models in `experiments/lut3d/models/`;
- the golden set.

The research arms are internal evaluation only, never shown externally, and never used as training targets.

**Not research-only, but not committed or shippable:** the smoke weights and exports in `experiments/auto/runs/`.

## 5. Next concrete dependency

**D1 (blocking): T1 photos with documented rights.** Without them there is:
- no frozen held-out set (so no G0 and no evaluation);
- no validation split for honest tuning;
- no real-photo stage (a) or (b) training (so no G1 or G2).

What is needed from the owner:
1. **Decide who contributes.** These are team members and/or consenting contributors.
2. **Have counsel approve a contributor form.** It must cover:
   - IP assignment or licence for training, evaluation and commercial shipping of the model;
   - model releases for identifiable people;
   - no minors;
   - revocation wording.
3. **Supply the photos.** About **280 photos for the frozen set** (spec in §2), plus a separate **validation split of about 100–150** from different contributors and sessions. The pipeline accepts **training photos** from the start, so hundreds more help stage (a) and (b) directly.
4. **Supply the labels.** Each image needs:
   - its rubric class;
   - an MST bucket from two annotators;
   - a `face_underexposed` flag where it applies;
   - a rights-ledger row (`permitted_uses`, `rights_doc_id`).

   The manifest schema is `lightly_auto/manifest.py`.

**D2 (unblocks T2 scale): counsel's answer on Unsplash Lite.** The question is whether "internal business purposes" covers a model shipped in a paid app (licensing.md §4a). The pipeline does not need it to start; it would add scale.

**D3 (owner decisions at G0, before the set is frozen):**
- whether landscape should be gated, and with what target;
- whether to accept the 0.5 pp new-clipping tolerance;
- whether to accept the 80% rule on the point estimate rather than on the CI lower bound.

Changing any of these means bumping the protocol to 1.1.0 **before** the first T1 scoring.

**Not needed now:** paired expert edits (T4, Gate P), procurement, and downloads. Nothing was downloaded for this work.

## 6. Commits (2026-10-02)

| Commit | Content |
|---|---|
| `329b78c` | Protocol 1.0.0, rubric library, runner, DEV-22 manifest, tests |
| `932d7ac` | Training and export pipeline, procedural data, smoke run cards |
| this commit | DEV-22 pipeline-check results, this note, status note in the plan |

## 7. Update 2026-10-03: public data, photo training, held-out results

The data verdicts and the owner's to-do list are in `docs/v1/auto-data.md`. This section has the measurements.

### 7.1 Data obtained without the owner

| Set | Content | Status |
|---|---|---|
| **PH-1** public held-out | 370 unedited CC0/PD Commons photos, 331 of them from phones (9 phone brands):<br>• portrait 59<br>• backlit 54<br>• night 60<br>• sunset 54<br>• already-good 60<br>• landscape 39<br>• indoor 44<br>Classes were assigned by eye. Faces come from the protocol detector (all 59 portraits have one). Every file is traced to its Commons page | **Frozen before training** (`manifests/ph1_FROZEN.json`, rows hash `241d0f13…`).<br>**Not G0:** the tier is not T1 and MST buckets are unlabelled |
| **CC0REF** | 5,182 PD12M CC0 references at 640 px:<br>• train 4,340<br>• validation 542<br>• HO-SYN 300<br>Split by capture session. PD12M shards are disjoint from PH-1. 74 PH-1-session references dropped | Committed manifests and provenance |

**Routes and limits**
- Commons' upload server rate-limits unauthenticated clients to about 7–8 requests a minute, with 600 s blocks. Originals were therefore fetched from PD12M's S3 mirror (md5 equal to the Commons bytes).
- Licences were checked on Commons for PH-1, and on PD12M's per-row record for CC0REF. That reliance is counsel question 3 in `docs/v1/auto-data.md` §3.4.
- **Protocol departure:** PH-1 portrait and backlit include 39 camera (non-phone) fallbacks. Public CC0 phone portraits are scarce.

### 7.2 Training (stage (a) on real photos)

**Setup**
- Run `photo_a_001`: `train.py --data manifest:manifests/cc0ref_manifest.csv --steps 6000`.
- Plan §4(a) degradation mix, 25% identity samples.
- CPU, 4 threads, 31 min.
- The checkpoint was chosen on the **validation split only** (step 4000).

Validation numbers are tuning data (pipeline verification, not evaluation):

| Step | Validation median ΔE00 to clean (input 7.65) | Identity-sample median ΔE00 | Share improved |
|---|---|---|---|
| 0 | 7.74 | 1.15 | 0.43 |
| 2000 | 6.54 | 2.88 | 0.65 |
| **4000 (selected)** | **6.20** | **2.90** | **0.68** |
| 6000 | 6.28 | 2.56 | 0.69 |

**Synthetic G1 (≤ 2.0 / ≤ 1.5): not met.** Compared with the procedural smoke runs (§3.3), photos make the task learnable: median error −19% here, against no gain for `smoke_full_001`. Identity drift is still the main failure.

A second run with 40% identity samples was started and then **stopped on the coordinator's instruction** (the machine was overloaded). It has no results.

### 7.3 Held-out evaluation: HELD-OUT, not tuning data

**HO-SYN.**
- **Data:** 300 CC0 photos, session-disjoint from training and validation. Frozen per-image degradations: 230 degraded, 70 identity.
- **Results:** `results/heldout_v1/hosyn_photo_a_001/`.

| Arm | Degraded: mean ΔE00 to clean (95% CI) | Median | Share improved | Share worse by > 1 | Identity: mean ΔE00 to input | Identity ≤ 1.5 |
|---|---|---|---|---|---|---|
| Original (input unchanged). NOT AI Auto | 8.71 (8.10–9.36) | 7.32 | — | — | 0.00 | 1.00 |
| Control: fixed levels + grey-world. NOT AI Auto | 9.09 (8.46–9.75) | 7.36 | 0.41 | 0.34 | 3.56 | 0.03 |
| **`photo_a_001`** (stage (a) research candidate) | **6.64 (6.26–7.05)** | **6.16** | **0.69** | 0.16 | 3.31 | 0.20 |

**PH-1, protocol 1.0.0 rubric.**
- **Data:** 370 natural photos.
- **Results:** `results/heldout_v1/ph1_photo_a_001/`; failure breakdown and σ_d in `ph1_analysis.json`.
- Each cell is pass count / n and the S1 verdict.

| Arm | Portrait | Sunset | Night | Backlit | Already-good | Indoor (gated by skin only) | Landscape | Mean ΔE00, all 370 |
|---|---|---|---|---|---|---|---|---|
| Original. NOT AI Auto | 59/59 PASS | 54/54 PASS | 60/60 PASS | 0/54 FAIL | 60/60 PASS | 44/44 | 39/39 | 0.00 |
| Control. NOT AI Auto | 28/59 FAIL | 12/54 FAIL | 46/60 FAIL | 3/54 FAIL | 21/60 FAIL | 43/44 | 39/39 | 3.31 |
| **`photo_a_001`** | **53/59 PASS** | 36/54 FAIL | 43/60 FAIL | 9/54 FAIL | 32/60 FAIL | 44/44 | 39/39 | 3.32 |

Class means for `photo_a_001` (control in brackets):

| Class | Metric (target) | `photo_a_001` | Control | Failures |
|---|---|---|---|---|
| Portrait | skin \|Δh\| (≤ 4°) | 2.07 | 4.82 | |
| Portrait | skin chroma (≤ 1.12) | 0.99 | 1.00 | |
| Sunset | warm \|Δh\| (≤ 4°) | 1.50 | 6.27 | |
| Sunset | warm chroma (0.95–1.10) | 0.98 | 0.98 | 17 images below 0.95: it desaturates some sunsets |
| Night | median ΔL\* (≤ 3) | −0.66 | −0.80 | 11 images above +3: it lifts some nights |
| Night | new black clip, pp (≤ 0.5) | −2.12 | 0.41 | |
| Backlit | subject ΔL\* (> 0) | −0.86 | −2.32 | |
| Backlit | new highlight clip, pp (≤ 0.5) | 0.20 | 0.90 | 27 images clip new highlights |
| Already-good | ΔE00 (≤ 3) | **3.44** | 3.40 | |

**What this establishes**
- **It is real and image-adaptive.** It changes photos by mean ΔE00 3.3, and its output differs per image (classifier weights per image are in `per_image.csv` arm_info). It is neither an unchanged Original nor a fixed filter.
- **It beats the fixed control on held-out data.**
  - HO-SYN error: 6.64 vs 9.09.
  - PH-1 pass counts are higher in every gated class: portrait 53 vs 28, sunset 36 vs 12, backlit 9 vs 3, already-good 32 vs 21. Night is the exception (43 vs 46).
  - It holds skin and warm hues within target on average.
- **It does not establish that it is better than the Original.** On PH-1 the Original passes every class except backlit, by construction.

**What it does not establish**
- **Not shippable.** It fails S1 on sunset, night, backlit and already-good.
- **Already-good.** It changes photos that needed nothing (ΔE00 3.44 > 3; identity drift 3.31 on HO-SYN). This is the same failure as the smoke runs, now measured on held-out photos.
- **Backlit.** It does not raise backlit subjects, consistent with plan §5.2 (3): a global LUT cannot do it alone, and A3 is untested.
- **Unmeasured.** Preference, skin-tone breakdown (no MST labels) and device parity.

**Sizing evidence from PH-1** (paired σ_d of candidate minus Original; planning input):

| Metric | σ_d | MDD at n = 40 | n for MDD = 1 |
|---|---|---|---|
| Night median ΔL\* | 3.71 | 1.64 | **≈ 108** |
| Backlit subject ΔL\* | 3.33 | 1.47 | ≈ 87 |
| Already-good ΔE00 | 1.98 | 0.88 | 31 |
| Skin \|Δh\| | 1.15 | 0.51 | 11 |
| Sunset warm \|Δh\| | 1.22 | 0.54 | 12 |

This confirms the DEV-22 estimate in §2: night (and now backlit) need about 90–110 images for an MDD of 1 L\*.

### 7.4 Export (contract: pinned 256 resize, 3 basis LUTs at 33³, fp32)

Export card: `results/heldout_v1/export_card_photo_a_001.json`. modelVersion is `candidate-c8059ab6b59610aa`. Artefacts are git-ignored under `runs/photo_a_001/export/` and **not integrated into either app**.

| Artefact | Size | Parity vs torch (weights, max abs) | Fused-LUT effect |
|---|---|---|---|
| Core ML fp32 mlpackage (iOS 16+) | 1,093,059 B | 1.0e-6 (CPU) | 0.0002/255 |
| ONNX opset 17 | 1,083,908 B | 6.0e-6 | 0.0016/255 |
| TFLite fp32 (litert-torch, `export_tflite.py`) | 1,103,588 B | 6.6e-6 | 0.0015/255 |
| Basis LUT bin, 3 × 33³ RGBA f32 (shared by all runtimes) | 1,724,976 B | bit-exact round trip | — |

All exports are inside the contract tolerance of 1e-3. The parity inputs are procedural scenes. This is not on-device parity (S4).

**Rights status of `photo_a_001`.**
- It contains no FiveK, Unsplash or Pexels data.
- It is trained only on PD12M rows recorded as CC0.
- It is **not shippable**: gates S1–S5 are unmet, and counsel questions 2–3 in `docs/v1/auto-data.md` §3.4 are open.

### 7.5 Next steps

**Engineering (no owner input needed)**
1. The identity-heavy run (40% identity samples) that was stopped.
2. An already-good identity hinge (plan §4), using CC0REF photos as unlabelled "good" samples.
3. A3 local exposure for backlit.
4. A warm-chroma floor in the warm-hue penalty, because sunsets drop below 0.95.

All of these are tuned on the validation split. PH-1 is scored only at a gate.

**Owner.** The checklist in `docs/v1/auto-data.md` §3: T1 photos and form, MST labels, raters, counsel, and the D3 decisions.

**Reproduce:**

```
cd experiments/auto
python -m data_tools.pd12m_eval_candidates            # + --pass2 portrait|backlit
python -m data_tools.build_eval_manifest --selection manifests/ph1_selection.json --faces manifests/ph1_faces.json
python -m data_tools.pd12m_train_refs --count 5000    # + --scene-boost 500 --out train_refs_boost.json
python -m data_tools.build_pd12m_train_manifest --exclude manifests/ph1_manifest.csv --exclude-provenance manifests/ph1_provenance.csv
python train.py --run-id photo_a_001 --data manifest:manifests/cc0ref_manifest.csv --steps 6000 --val-every 500
python eval_synthetic.py --manifest manifests/cc0ref_manifest.csv --arms original,control_levels_greyworld,run:runs/photo_a_001 --out results/heldout_v1/hosyn_photo_a_001
python run_eval.py --manifest manifests/ph1_manifest.csv --faces manifests/ph1_faces.json --arms original,control_levels_greyworld,run:runs/photo_a_001 --out results/heldout_v1/ph1_photo_a_001
python export.py runs/photo_a_001 && <venv_tflite>/bin/python export_tflite.py runs/photo_a_001
```
Heavy steps run under `lockf -k /tmp/lightly-heavy.lock` with `OMP_NUM_THREADS=2`, on a shared machine.

## 8. Update 2026-10-03: experiment 1 closed, conservative gating

The full account is `docs/v1/auto-experiment-1-report.md`. This section records the measurements.

### 8.1 Closing the experiment

- **Archived.** The model, exports, configs, manifests, frozen splits, evaluation code, image bytes and before/after sheets are archived outside Git in `~/.codex/artifacts/lightly/v1/auto-experiment-1/`, with `SHA256SUMS` (5,619 files) and `REPRODUCE.txt`.
- **Training code.** Its fingerprint `58145a11…` equals the committed code.
- **Three results, kept separate:**
  - **(a) Synthetic recovery (HO-SYN).** 8.71 → 6.64 mean ΔE00 to clean; 69% of images improved.
  - **(b) Preservation.** It fails: identity drift 3.31; PH-1 already-good 3.44 (32/60); night 43/60; sunset 36/54.
  - **(c) Human preference.** Not measured.
- **"Portraits passed" (53/59).** It checks only skin |Δh| ≤ 4° and skin chroma ≤ 1.12. The face-exposure check never ran, because PH-1 has no `face_underexposed` labels. The model darkened 21 of 59 faces by more than 5 L*, and 17 of those still passed.

### 8.2 Conservative gating

Code: `lightly_auto/gating.py`, `gate_study.py`, the `gated:` arm. Tests: `tests/test_gating.py`; the suite now has 49 tests, all passing.

**Validation split only** (542 CC0REF photos, each clean and degraded). Results are in `results/gating_v1/validation/`.
- **Separating "needs correction" from "already good".**
  - The model's predicted change does so poorly (AUC 0.66).
  - A logistic detector fitted on the train split reaches AUC 0.76.
- **Scene constraints** removed the night and sunset failures on validation (30% → 0%, 28% → 3%).
- **Selected gate.** gate_v1 = detector at 0.6 + scene constraints.
  - Clean photos: 0.78 ΔE00 (91% ≤ 3).
  - Degraded photos: it keeps 63% of the recovery.

**Pre-registered single frozen-set run.**
- **Order.** The pre-registration was committed (`61af3c6`) before the run; the run is `c076dd0`.

| Set | Measurement | Result |
|---|---|---|
| PH-1 | Already-good | 55/60 (mean ΔE00 0.62) |
| | Night | 60/60 |
| | Sunset | 52/54 |
| | Portrait | 56/59 |
| | Backlit | 5/54, a fail, as predicted |
| HO-SYN | Identity drift | 1.18 (CI 0.63–1.81) |
| | Degraded | 7.27, which keeps 69% of the ungated recovery |

- **The gate left 82% of PH-1 photos unchanged,** so these preservation passes largely reflect abstention.
- **What it does not show:** improvement.
- **PH-1 has now scored two candidates.** The next iteration needs a new frozen set.

### 8.3 Next steps

**Engineering (no owner input needed):**
- train the already-good and night hinges into the model rather than gating after the fact;
- add a warm-chroma floor;
- add A3 local exposure for backlit.

All of these are tuned on validation.

**Owner:** decide on the proposed study parameters, then the T1 collection, labels, raters and counsel (`docs/v1/auto-data.md` §3).

### 8.4 Commits

| Commit | Content |
|---|---|
| `61af3c6` | Gate code, validation study, detector, gate_v1, pre-registration |
| `c076dd0` | The pre-registered PH-1 / HO-SYN run |
| `66c413d` | Archive and before/after sheet tools |
| this commit | Closing report, rewritten `docs/v1/auto-data.md`, this section |
