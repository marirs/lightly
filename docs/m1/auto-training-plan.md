# Auto develop model: training and evaluation plan (M1)

Status: draft plan. Builds on `lut-feasibility.md` (§5 rubric, §5.3 additions A1–A3), `weights-path.md`, `licensing.md` §4, and `spec.md` §1.1 and §4.6. This is not legal advice. Every licensing statement here needs counsel confirmation.

**Scope note.** This plan does **not** start any paid retoucher engagement, vendor procurement or quote process. `weights-path.md` §2 "Week 1" item 4 (procurement emails) is deferred to Gate P (§9). Every dataset size in this document, including the "500–1,500 pairs" in `weights-path.md`, is a **hypothesis**. §6 describes how sufficiency will be measured.

## 0. What is established and what is not

| Claim | Status | Basis |
|---|---|---|
| The architecture converts to Core ML fp32 and ONNX within 1/255 of PyTorch on desktop | Validated (desktop) | feasibility §3 |
| iOS inference parity and timing (iPhone SE 3, 11 Pro Max) | Validated for the model. LUT application via Core Image **fails** tolerance (5/255). The float-LUT Metal kernel is not built yet | §6.1 |
| Android inference on phones | **Not validated.** The phones have not run. Emulator ORT hit SIGILL | §6.2 |
| iOS↔Android export parity | **Not validated** | §6.3 |
| Guardrails (endpoint, warm-hue) and local exposure meet the rubric | **Experimental only.** Tuned by eye on the same 22 images they were scored on, so they may be overfitted | §7 |
| Retraining fixes already-good over-processing and night lift | **Hypothesis** | §5.2 |
| A global LUT cannot raise a backlit subject on its own | Supported by the experiment and by first principles | §5.2 (3) |

## 1. Goals, non-goals, definition of done

**Goal.** Shippable, commercially clean weights for the `ia3dlut` contract. They should give an image-specific develop in the spirit of Arsenal 2 Deep Color: a considered result that holds up without a Look, where stronger saturation or brightness alone does not count as improvement.

**Non-goals (this plan):**
- semantic masks, face-specific edits, RAW or multi-frame processing;
- fp16;
- creative Looks;
- shipping the FiveK-trained research weights;
- any paid data collection.

**Done = all ship gates pass on the frozen held-out set (§3.4):**

| Gate | Criterion |
|---|---|
| S1 Rubric | Each `spec.md` §1.1 per-class target is met by the class mean. **≥ 80% of images in each class** pass individually, with a bootstrap 95% CI reported. The 80% figure is provisional and is fixed at G0, before any training. |
| S2 Already-good | Mean ΔE00 ≤ 3. In the preference study the candidate is **non-inferior** to the Original (95% CI lower bound of the preference share ≥ 45%). |
| S3 Preference | Overall, the candidate is preferred over the Original **and** over the Core Image auto baseline (iOS control). The 95% CI lower bound of the preference share must be > 50%. No scene class or skin-tone bucket is significantly worse than the Original. |
| S4 Parity | `spec.md` §4.4 golden tests pass on iOS **and** on at least two Android phones (one Adreno, one Mali). The model's weights are within 1e-3 of the reference. |
| S5 Provenance | Every training image has a documented right to train, confirmed by counsel. A datasheet and a model card are published internally. |

## 2. Architecture under test

**Fixed by the contract (`spec.md` §4.6, §4.2).** These items are not part of the search:
- Input: `[1,3,256,256]` sRGB-encoded [0,1], whole frame, aspect ignored, using the pinned antialiased resize.
- Output: raw `weights[3]`.
- `L = Σ wᵢBᵢ` with 33³ basis LUTs and exact-grid trilinear interpolation.
- fp32 Core ML and ONNX.
- **Training must use the deployment preprocessing.** The resize alone moved outputs by up to 14/255.

**Variable (under test):**
1. **Classifier + basis LUTs** (270k parameters + 3×3×33³), retrained from scratch. Initialisation is identity plus random basis, as upstream.
   - The basis count stays at 3, because changing it changes the contract.
   - An optional ablation tries 5 basis LUTs. Adopting it would require a contract version bump.
2. **LUT-space guardrails (A2).** These are the endpoint renormalisation and the warm-hue band. They are applied post-model and versioned in `AutoResult`.
   - They are trained *into* the model as regularisers (§4), so that guardrails fire rarely.
   - The guardrail firing rate on the held-out set is reported.
3. **Optional low-frequency local exposure, O0b (A3, U10).** A fixed, non-learned operator, gated on dynamic range, applied before the LUT.
   - It is trained jointly: the LUT sees the gain-adjusted input.
   - Every result is run as two arms, with and without it.
   - Chroma compensation is required, because backlit face chroma reached 1.39 in the experiment.

## 3. Data

### 3.1 Tiers

| Tier | Content | Rights basis | Use | Status |
|---|---|---|---|---|
| **T1 Own photos** | Team and consenting contributors' phone captures | Written IP assignment or licence to train and ship. Model release for identifiable people | Train, validation, frozen eval | Collect now |
| **T2 Licensed unedited photos** | Third-party photos whose terms permit ML training. Candidates: Unsplash Lite (§2A, "internal business purposes"); HDR+ (CC BY-SA, ShareAlike question) | **Counsel confirmation required per source before use** | Train only, never frozen eval | Blocked on counsel |
| **T3 Synthetic degradations** | T1/T2 images with sampled global degradations (§4a) | Inherits from the source | Pretraining | Engineering only |
| **T4 Paired expert edits** | Input plus edit made to a written style guide | Contract with copyright assignment and an ML grant | Fine-tune | **Gated (Gate P). Not started, not planned now** |

Unsplash Lite photos are finished stock. They serve as "good" anchors and as degradation sources, not as phone-native inputs. The 22 Unsplash evaluation images are **never** used for training (licensing.md, note on evaluation photos). They stay as a dev and regression set only.

### 3.2 Phone-native capture protocol (T1)
- **Format.** HEIC or JPEG straight from the default camera app with default settings (HDR and Night modes as the phone chooses). No edits, no messaging-app recompression. Keep the original file and record its sha256.
- **Devices.** At least 6 brands: Apple, Samsung, Google, Xiaomi, Motorola and Nothing, with at least 2 OS generations where possible. Record model, OS, lens and capture mode from EXIF.
- **Scene classes.** Use the rubric classes, with a minimum per class for the eval set:
  - sunset/golden hour, portrait, night, backlit, landscape;
  - **already-good**, i.e. photos the contributor would post unedited;
  - indoor mixed light, as a stress class.
- **Skin tones.** Bucket by the Monk Skin Tone scale, grouped as 1–3, 4–7 and 8–10. Each bucket gets at least 30% of the portrait and backlit eval share. Labels come from two annotators, plus self-identification where offered.
- **Consent.** Each subject signs a form covering training, evaluation and commercial shipping of the model, with a revocation path. Counsel decides what revocation means for already-trained weights. No minors. Location EXIF is stripped on ingest.

### 3.3 Documentation and tracking
- **Datasheet** (Gebru et al. format) per dataset version. It covers sources, collection, consent, demographics, known gaps and intended use.
- **Rights ledger** (CSV, one row per image):
  - image hash, source tier, contributor ID, licence/consent document ID, release status;
  - permitted uses (train, eval, marketing);
  - counsel status;
  - revocation flag.
- A training run fails if any input lacks a `train` permission.

### 3.4 Splits and the frozen evaluation set
- **Grouping.** Split by **contributor and capture session**, with perceptual-hash de-duplication across splits, so near-duplicate bursts never straddle splits.
- **Stratification.** Stratify by device brand.
- **Unseen-device split.** Hold out one complete device model as a separate unseen-device test.
- **Frozen eval set.** Built and hashed **before any training run** (Gate G0), with sizes justified in §6.3. A working target is ≥ 40 images per class, about 300 in total. Its manifest hash goes into the repo. Access is read-only, and it is never used for tuning.
- **Tuning.** All guardrail and hyperparameter tuning uses a separate validation split. The frozen set is scored only at gates. If it is ever used for a decision, it is retired and rebuilt.

## 4. Training stages

The base loss is the upstream regulariser: TV smoothness `λ=1e-4` and monotonicity `λ=10` on the LUTs, plus the following **rubric-matched regularisers** (all differentiable, computed in LUT space or on the output):
- **Endpoint:** penalise `L(0)` < 0 and `L(1)` < 1 per channel.
- **Skin and warm hue band:** for LUT nodes whose input lies in the warm band (hue 15–80°, chroma 6–80; as in `warm_hue_protection`), use a hinge on |Δhue| > 4° and on a chroma gain outside [0.92, 1.12].
- **Identity for good photos:** on samples labelled already-good, penalise mean ΔE00 to the input above 1.5. This uses a differentiable ΔE approximation, or ΔE76 as a proxy.
- **Night mood:** on night-labelled samples, use a hinge on median L* lift > 3 and on black-clip growth.

### (a) Synthetic degradation-inversion pretraining (T3)
- **Degradations.** Sample global degradations: ±1.5 EV, WB and tint shifts, gamma and contrast changes, saturation ×[0.6, 1.4], tone-curve flattening, and phone-like tone-mapping compression.
- **Clean samples.** 25% of samples are **undegraded with an identity target**, so the model learns to leave good photos alone.
- **Exit criteria (G1):**
  - On the validation split, it inverts held-out synthetic degradations to ΔE00 ≤ 2 (median).
  - Identity samples stay at ΔE00 ≤ 1.5.
  - On the T1 real validation set it does **no harm**: no class is worse than the Original on the rubric.

### (b) No-reference objectives (T1 + T2, unpaired)
Spatial-consistency, exposure-control, colour-constancy and smoothness losses are **re-implemented from the Zero-DCE paper's equations**. No Zero-DCE code is copied, because that code is CC BY-NC 4.0. Each equation is cited in the code comments.

Adaptations are needed because the raw losses conflict with the objective:
- **Exposure loss:** disabled on night and already-good samples.
- **Colour-constancy (grey-world) loss:** masked out of warm-band pixels and disabled on sunset samples, because it would neutralise sunset warmth.
- **Smoothness:** applied as TV on the fused LUT, not on per-pixel curves.

Scene labels come from the dataset tags. At inference there are no labels, so the model has to learn them implicitly. A label-free variant is an ablation.

An optional WGAN "look like finished photos" term (upstream unpaired) is used only as an ablation.

**Exit criteria (G2):** the rubric improves on the validation set over the (a) model, with no regression larger than the minimum detectable difference (MDD, §6.3) in any class.

### (c) Paired fine-tune (T4), gated
This stage runs only after Gate P. It uses the same regularisers with a low LR. Exit is the full ship gate set (S1–S5).

## 5. Evaluation protocol

### 5.1 Automatic rubric
- **Scripts.** `evaluate.py` metrics, factored into a library and run at full deployment resolution rather than 1/4 resolution:
  - ΔE00, ΔL, chroma ratio, clip growth;
  - skin dh, chroma ratio, ΔL;
  - warm chroma ratio and dh;
  - night p5/p50 ΔL;
  - backlit subject and highlight ΔL.
- **Targets.** From `spec.md` §1.1, reported as class mean, pass rate and bootstrap CI, broken down by skin-tone bucket and device brand.
- **Masks.** Face boxes come from a pinned detector version.
- **Known limits.** The rubric is heuristic and has no ground truth. Warm-band masks also catch wood and sand.

### 5.2 Regression set
- **Composition.** The 22-image M1 set plus golden images, plus any failure case found later.
- **When it runs.** In CI on every training run.
- **Failure rule.** It fails on any per-image metric regression beyond tolerance relative to the previous accepted model.

### 5.3 Blind pairwise preference study
- **Arms:**
  1. Original.
  2. Current FiveK research model, guard75_hp. This arm is **internal evaluation only**: it never ships, is never shown externally and is never used for training.
  3. Candidate(s), with and without A3.
  4. Core Image `autoAdjustmentFilters` (iOS control). Its outputs are never used as training targets.
  5. Optional: Arsenal 2 Deep Color, only if side-by-side captures exist (U9).
- **Design:**
  - two-alternative forced choice with a "no preference" option;
  - side-by-side, left/right randomised;
  - the arms' identity is hidden;
  - shown on a calibrated display and on a phone.
- **Question:** "Which is the better photo to share as-is?"
- **Raters:**
  - at least 8 raters, mixing photographers and non-photographers, internal or volunteer;
  - at least 30% of raters for portraits come from skin-tone groups other than the subject's majority;
  - each rater sees each image at most once per arm pair.
- **Power analysis.**
  - To detect a 60% vs 50% preference (two-sided α=0.05, power 0.8) needs about 195 independent comparisons per arm pair.
  - For 55%, it needs about 780.
  - Comparisons are clustered by image and rater, so inflate by the design effect. The intra-class correlation is estimated in a pilot of about 100 comparisons.
  - Analysis uses a mixed-effects logistic model (random effects for image and rater) or Bradley–Terry with bootstrap CIs.
- **Agreement.** Report Krippendorff's α. If α < 0.4, the question or the instructions are revised before results are used.
- **Pre-registration.** The hypotheses, the analysis plan and the MDD are fixed before unblinding.

### 5.4 On-device parity
- Golden tests from `spec.md` §4.4 run per model version:
  - weights within 1e-3;
  - preprocessing within 0.05;
  - LUT application max 2/255 with ≤ 1% of pixels > 1;
  - cross-platform mean ΔE00 ≤ 0.5, p99 ≤ 2.0.
- **iOS** needs the float-LUT Metal kernel first.
- **Android** is **pending hardware.** It must run on at least one Adreno and one Mali phone, including an ORT inference check (the SIGILL is unresolved).

## 6. Data sufficiency experiments

### 6.1 Learning curves
- **Design.** Train on 10/25/50/100% of each tier (T1, T1+T2, T1+T2+T3), with 3 seeds per point and nested subsets.
- **Evaluation.** Score on the validation split, and on the frozen set only at gates. Plot each primary metric (per-class pass rate, already-good ΔE00, skin dh) and a validation preference proxy.
- **Model fit.** Fit `err(n) = a·n^(−b) + c` and report the asymptote `c` with a CI.

### 6.2 Saturation criteria
A tier is **saturated** for a metric when both of these hold:
1. Going from 50% to 100% improves the metric by less than its MDD, and the 95% CI of the improvement includes 0.
2. The fitted curve predicts a gain below the MDD from a further 2× of data.

### 6.3 Minimum detectable differences
- **Formula.** For paired per-image metrics, MDD ≈ 2.8·σ_d/√n (α=0.05, power 0.8). σ_d is estimated from seed-to-seed and image-to-image variance in the first runs.
- **Eval set sizing.** Size the eval set so that the MDD is at most half the distance between a target and the current value. For example, if σ_d(ΔE00) is about 2, then n=40 gives an MDD of about 0.9.
- **Fallback.** If a class cannot reach that, enlarge it before G0 rather than after.

### 6.4 Decision rule: is paired data needed at all?
Paired data (T4) is **indicated** only if all of these hold:
1. The best unpaired candidate fails S1, S2 or S3.
2. The failing metrics are saturated (§6.2) on the unpaired tiers, so more of the same data will not help.
3. Failure analysis shows the gap is *taste* (grading choices), not something structural. Backlit cases fixed only by A3 do not count.
4. The gap is larger than the MDD.

If the unpaired candidate passes all ship gates, T4 is **not needed** for V1. The size of any T4 step is then set by extrapolating a small paired pilot's learning curve, not by the 500–1,500 figure.

## 7. Compute, tooling, reproducibility
- **Compute.** About 1–3 GPU-hours per run with pre-decoded tensors (licensing.md §4e; an estimate, not measured).
  - Learning curves: 4 fractions × 3 tiers × 3 seeds ≈ 36 runs.
  - Ablations: about 20 runs.
  - Total: tens to low hundreds of GPU-hours, roughly $100–1,000, or Apple-silicon MPS for experiments.
  - The dominant costs are data collection and rater time.
- **Tooling:**
  - a training repo outside `ios/Lightly/` that reuses `ia3dlut.py` and the deployment resize;
  - an evaluation library (rubric plus sheets);
  - a pairwise rating web tool;
  - an export script (Core ML, ONNX, basis LUT, golden tensors).
- **Reproducibility.** Each run records:
  - fixed seeds for Python, NumPy, torch and the degradation sampler;
  - deterministic data-loader ordering;
  - dataset manifests with per-image sha256 and a manifest hash;
  - code commit, config and environment lockfile;
  - artifacts hashed into the `modelVersion`.
- **Model card** per candidate (Mitchell et al.):
  - data tiers and rights;
  - rubric and preference results by class, skin tone and device;
  - known failures;
  - guardrail firing rate;
  - validated vs unvalidated platforms.

## 8. Risks, mitigations, open questions

| Risk | Mitigation |
|---|---|
| Guardrails are overfitted to the 22 M1 images | Re-tune on the validation split. Report on the frozen set only |
| Synthetic degradations do not match real phone failures | Phone-like tone-mapping degradations. The T1 real validation set is the deciding metric |
| No-reference losses neutralise sunsets and lift night | Class-masked losses, rubric hinges, per-class gates |
| Eval set leakage | Contributor/session splits, pHash de-duplication, frozen hash, single-use rule |
| Skin-tone imbalance | Bucket quotas, per-bucket reporting, a gate on "no bucket worse" |
| T2 terms not cleared | Plan works on T1 + T3 alone, at reduced scale |
| Android unvalidated | S4 blocks shipping. Run on hardware as soon as phones reconnect |
| Rubric heuristics disagree with people | The preference study decides. Rubric/preference correlation is reported |
| Scene labels are unavailable at inference | Implicit learning plus a label-free ablation. Per-class failures are tracked |

**Open questions:**
1. Counsel: Unsplash Lite "internal business purposes" for a shipped model; HDR+ ShareAlike; the consent and revocation wording; whether running the FiveK research model for internal evaluation is acceptable.
2. Data access: how many contributors and devices can be reached without payment; whether deep-skin-tone and night coverage can be met.
3. Arsenal comparison (U9): access to an Arsenal 2 and capture logistics for 20–30 side-by-side scenes. Without it, Deep Color is a qualitative reference only.
4. Android hardware availability for S4.

## 9. Phased schedule (relative weeks)

| Weeks | Phase | Gate | Evidence required to proceed |
|---|---|---|---|
| 0–3 | Capture T1. Build and freeze the eval set. Datasheet and rights ledger. Rubric library. Rating tool. Send counsel questions | **G0** | Frozen manifest hash committed. Per-class/bucket counts meet §6.3 MDD sizing. Ship thresholds (S1–S3) fixed in writing. Rights ledger complete for eval images |
| 2–5 | Stage (a) pretraining, A3 on/off | **G1** | §4(a) exit criteria on validation. Regression set passes. Seeds reproduce within MDD |
| 4–7 | Stage (b) no-ref + regularisers. Learning curves | **G2** | §4(b) exit. Learning curves with saturation analysis for each tier available |
| 7–9 | Frozen-set scoring. Preference pilot (ICC) then the full study | **G3** | S1–S3 results with CIs. Pre-registered analysis |
| any, ≥ 3 | Device parity (Metal kernel; Android phones) | **G-D** | S4 on iOS + ≥ 2 Android phones |
| after G3 | **Gate P: paired data go/no-go** (decision only) | **P** | §6.4 conditions all met **and** counsel-cleared contract terms **and** explicit budget approval by the product owner. Otherwise no-go: ship the unpaired candidate or iterate on T1/T3 |
| after G3 + G-D | Ship decision | **Ship** | S1–S5 all pass. Model card signed off |

## Status note (2026-10-02)

Progress against this plan is tracked in `docs/m3/auto-progress.md`.
- **G0 rules are frozen** as evaluation protocol 1.0.0 (`experiments/auto/PROTOCOL.json`, locked).
- **The G0 data part is blocked.** No T1 photos exist yet, so there is no frozen held-out set and no evaluation result.
- **The training and export pipeline is validated on procedural data only.** Stage (a) exit criteria are not met at smoke budget.
- **Next dependency:** T1 photos with documented rights, plus owner decisions D1–D3 in that note.
