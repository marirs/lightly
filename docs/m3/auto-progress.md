# Auto develop model: progress against the training plan (M3)

Status: 2026-10-02. This note follows `docs/m1/auto-training-plan.md` in plan order. The code is in `experiments/auto/`, and nothing in it is linked into either app. The apps are unchanged.

**Read this first.**
- **No AI Auto exists yet.** Every arm measured below is either:
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

## 6. Commits

| Commit | Content |
|---|---|
| `329b78c` | Protocol 1.0.0, rubric library, runner, DEV-22 manifest, tests |
| `932d7ac` | Training and export pipeline, procedural data, smoke run cards |
| this commit | DEV-22 pipeline-check results, this note, status note in the plan |
