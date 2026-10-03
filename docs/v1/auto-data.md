# Auto: data status and what needs the product owner

Status: 2026-10-03, revised the same day when experiment 1 was closed. Not legal advice. Measurements are in `docs/m3/auto-progress.md` §7–§8. The closing report is `docs/v1/auto-experiment-1-report.md`. The code is in `experiments/auto/`. Nothing here is linked into either app.

**In short**
- **Done without you.**
  - A public held-out evaluation set (PH-1) of CC0 and public-domain phone and camera photos, frozen before any photo training.
  - A session-disjoint training and held-out reference set (CC0REF) of CC0 photos.
  - A self-supervised Auto model trained only on CC0REF, evaluated on both held-out sets, and exported to Core ML, ONNX and TFLite. It is image-adaptive and beats the fixed control on held-out data. It is **not** releasable as AI Auto. The experiment is closed; see the report.
- **Auto is still an unresolved release requirement.** No model in this repository meets it.
- **Still needs you.** No ship gate can pass without the items below.
  - Your decision on the **proposed** study parameters in §3.1 to §3.3. Every photo, contributor, brand and rater count in this document is a proposal with a stated rationale. None of them is a requirement you set. No collection request has been sent, and none should be until you have accepted or changed them.
  - T1 photos with signed rights (§3.1).
  - Human skin-tone and exposure labels (§3.2).
  - Raters for the preference study (§3.3).
  - Counsel's answers (§3.4).
  - Your D3 decisions (§3.5).

## 1. Data survey: the sources examined, one by one

**Scope.** These are the sources we examined: every row in the two tables below, including the Image-Adaptive-3DLUT code and weights that the architecture comes from. Statements apply only to them. We did not survey every public dataset; §1.3 lists relevant sources that were not examined. Pages were fetched on 2026-10-03, some through a summarising fetcher. Check every quotation against the live page before it goes into a legal memo.

**How to read the table.** Four separate questions are kept apart:
- **Code licence:** the licence of an associated code repository, if one exists.
- **Weights licence:** the licence of pretrained weights released with it, if any.
- **Dataset terms:** what the terms of the images permit. *Eval* means internal evaluation of a commercial model. *Train* means training a model that ships in a paid app.
- **People and privacy:** whether identifiable people appear, and what consent or release exists.

Copyright licences (CC0, PDM, CC BY) never clear personality, publicity or data-protection rights.

### 1.1 Sources with terms that may permit commercial evaluation or training

| Source (checked) | Code licence | Weights licence | Dataset terms → eval / train | People and privacy | Fit for Auto |
|---|---|---|---|---|---|
| **Wikimedia Commons, CC0/PD files** ([CC0 legal code](https://creativecommons.org/publicdomain/zero/1.0/legalcode.en), [Photographs of identifiable people](https://commons.wikimedia.org/wiki/Commons:Photographs_of_identifiable_people)) | No repo | None | Per-file licence. CC0 waives copyright for any purpose; no warranty from Wikimedia. **Eval: yes. Train: yes on copyright**, for each file whose CC0/PD status is verified. A mislabelled file is a residual risk | CC0 §4(b) disclaims clearing "rights of other persons". No model releases. Faces are personal data under GDPR; skin-tone labelling may touch special-category data. **Counsel (§3.4 Q2)** | Unedited phone and camera photos of every scene. No pairs, no skin-tone labels. **Used here** (PH-1, CC0REF) |
| **PD12M** ([HF card](https://huggingface.co/datasets/Spawning/PD12M)) | No repo examined | None released with it | Metadata CDLA-Permissive-2.0; images described as public domain and CC0. **Eval: yes. Train: yes on copyright** for verified rows; flag-and-remove process for mislabels | No statement on faces or consent. Commons-origin rows can show identifiable people; same caveat as Commons | Mostly museum objects and iNaturalist; the Commons camera-photo subset is useful. **Used here** as the download route |
| **Flickr CC0** ([Flickr CC page](https://www.flickr.com/creativecommons/), [Flickr terms](https://www.flickr.com/help/terms)) | No repo | None | CC0 per file: **eval and train yes on copyright.** Flickr's own terms prohibit scraping, so bulk collection needs the API or permission, which is a terms question separate from the image licence | No releases. Same GDPR questions as Commons | Large consumer-photo pool. Not used: needs a Flickr account and API key |
| **Flickr Public Domain Mark** ([PDM 1.0](https://creativecommons.org/publicdomain/mark/1.0/)) | No repo | None | PDM is a label, not a licence. Public-domain status must be established separately. **Counsel (§3.4 Q5)** | The deed notes publicity and privacy rights may remain | As Flickr CC0. Excluded so far |
| **NASA media** ([guidelines](https://www.nasa.gov/nasa-brand-center/images-and-media/)) | No repo | None | Generally not subject to US copyright. Insignia may not appear in AI training; third-party © items are marked. **Eval: yes. Train: yes after filtering** insignia and third-party items; non-US status unclear | NASA warns identifiable people may carry privacy and publicity rights | Poor fit (space and aerospace). Not used |
| **Google HDR+ bursts** ([dataset page](https://hdrplusdata.org/dataset.html)) | No code with the dataset | None | CC BY-SA (version not re-verified). **Eval: yes with attribution. Train: counsel** (is a trained model ShareAlike adapted material?) | Subjects include the authors' friends and family; no formal consent statement seen | 3,640 Nexus/Pixel phone bursts. Outputs are pipeline results, not expert edits |
| **Open Images V7** ([facts page](https://storage.googleapis.com/openimages/web/factsfigures_v7.html)) | Apache-2.0 (openimages/dataset tooling) | None released with V7 (not fully verified) | Images listed as CC BY 2.0 without warranty; verify per image. **Eval: yes with attribution. Train: probably permitted on copyright; attribution for a trained model is a counsel question** | No privacy or consent statement on the pages checked; people are common; no releases | About 9M Flickr consumer photos. No pairs, no skin-tone labels in the core set |
| **Unsplash Lite** ([TERMS.md](https://github.com/unsplash/datasets/blob/master/TERMS.md)) | No LICENSE file (repo is docs and terms) | None | Licence to train "for your internal business purposes"; no redistribution; comparisons may not be published. **Eval: probably yes, unpublished. Train: counsel (D2)** | Licensee carries publicity and privacy obligations; no consent statement | About 25k finished stock photos. No pairs |
| **Sony FHIBE** ([terms](https://fairnessbenchmark.ai.sony/legal/terms-of-use)) | Not addressed | None | Bias and fairness evaluation, including commercial; not training data except for bias mitigation; click-through. **Eval: bias only. Train: no** | Paid, informed, revocable consent; GDPR addendum; withdrawal can impose deletion duties | Skin-tone bias check only. Not downloaded (needs agreement, §3.2) |
| **Google MST-E** ([blog](https://research.google/blog/consensus-and-subjectivity-of-skin-tone-annotation-for-ml-fairness/), [paper](https://arxiv.org/abs/2305.09073)) | No repo | None | Not for training. Research and annotator training verified; "model evaluations" (cited earlier from the paper) could not be re-verified. **Eval: counsel. Train: no** | 19 consenting subjects (TONL stock) | Monk-scale reference images for annotator training. Not downloaded |

### 1.2 Sources whose terms exclude this use, or leave it unresolved

| Source (checked) | Code licence | Weights licence | Dataset terms → eval / train | People and privacy | Fit for Auto |
|---|---|---|---|---|---|
| **MIT-Adobe FiveK** ([LicenseAdobe.txt](https://data.csail.mit.edu/graphics/fivek/legal/LicenseAdobe.txt)) | No repo with the dataset | None with the dataset; downstream weights inherit the question | Research only, not "directed toward commercial advantage". **Eval: no. Train: no** | Includes people; no consent or release statement | 5,000 DSLR RAW images, 5 expert retouches each: expert pairs, but not phone |
| **Image-Adaptive-3DLUT** ([repo licence](https://api.github.com/repos/HuiZeng/Image-Adaptive-3DLUT/license), [issue #65](https://github.com/HuiZeng/Image-Adaptive-3DLUT/issues/65)) | **Apache-2.0** (added 2021, after the weights) | No separate licence. The weights are very probably FiveK-trained, and the issue asking is unanswered. **Treat as research-only** | n/a (inherits FiveK) | Inherits FiveK | The architecture is re-implemented under Apache-2.0. The research weights never ship |
| **PPR10K** ([repo](https://github.com/csjliang/PPR10K)) | Apache-2.0 | Hosted weights with no separate licence, trained on PPR10K, whose terms cover derived data. **Treat as no** | Non-commercial research only. **Eval: no. Train: no** | Every image is a portrait; no consent or sourcing statement found; minors unknown | 11,161 DSLR portraits, 3 expert retouches: expert pairs, not phone |
| **RAISE** ([guide](https://loki.disi.unitn.it/RAISE/guide.html)) | No repo found | None | Non-commercial research and education. **Eval: no. Train: no** | No statement | 8,156 DSLR RAW. No pairs |
| **DIV2K** ([page](https://data.vision.ee.ethz.ch/cvl/DIV2K/)) | No repo examined | None | Academic research only; third parties own copyright. **Eval: no. Train: no** | No statement; removal on request | 1,000 web images. No pairs |
| **LSDIR** ([site](https://ofsoundof.github.io/lsdir-data/)) | MIT (code only) | None found | Academic research only; Flickr owners keep copyright. **Eval: no. Train: no** | Removal on request; no consent statement | About 87k web images. No pairs |
| **Unsplash site licence** ([terms](https://unsplash.com/terms)) | No repo | None | §8 bars use "in connection with" ML or AI datasets. **Eval: counsel (DEV-22 is development data only). Train: no** | Licence does not cover recognisable people | Finished stock photos |
| **Pexels** ([terms](https://www.pexels.com/terms-of-service/), [licence](https://www.pexels.com/license/)) | No repo | None | Terms bar scraping for ML and bulk copying without permission. **Eval: unclear (small manual use). Train: no without written permission** | Model releases are the contributor's job; not warranted | Stock photos |
| **Megalith-10M** ([HF card](https://huggingface.co/datasets/madebyollin/megalith-10m)) | No repo; card tagged MIT (covers the URL list, not images) | None of its own | Mix of Flickr CC0, PDM, "no known copyright restrictions" and US Gov; creator estimates 1–2% may be copyright-constrained; no per-row licence field seen. **Eval and train: counsel**, after per-file checks via the Flickr API | No releases; no privacy statement | Consumer Flickr photos at scale |
| **Openverse** ([terms](https://docs.openverse.org/terms_of_service.html)) | Not checked | None | Grants no licence and does not verify licences. **Depends on each file** | Inherits the source | Search tool only |
| **Meta Casual Conversations v2** ([page](https://ai.meta.com/datasets/casual-conversations-v2-dataset/)) | No repo | None | "Limited"; full licence not located. **Eval and train: counsel** | Paid adults who consented and self-reported attributes | Videos with Fitzpatrick and Monk labels. Frames only |
| **Getty Images sample (Hugging Face)** | No repo | None | Gated; full terms not readable today (HTTP 401). Press reports bar competing products. **Eval and train: counsel** | Marketed as commercially safe, which implies releases; not verified | 3,750 stock images |
| **LOL** ([site](https://daooshee.github.io/BMVC2018website/)) | MIT (RetinexNet code) | Unclear | No dataset licence, so all rights reserved. **Eval: needs the authors' permission. Train: no** | Mostly rooms and objects; not verified | About 500 captured low/normal-light pairs, not expert edits |
| **SICE** ([repo](https://github.com/csjcai/SICE)) | None stated | Caffe models, no licence | No licence, so all rights reserved. **Eval: needs permission. Train: no** | No statement | References chosen from algorithm outputs, not expert edits |

### 1.3 What this survey does and does not show

- **Expert before/after pairs.** Among the sources examined, the two with expert pairs (FiveK, PPR10K) are research-only. That is a statement about these two, not about every paired dataset that exists.
  - **Not examined:**
    - Phone-capture paired sets: the Zurich RAW-to-RGB set, the See-in-the-Dark set, LOL-v2.
    - Exposure and colour sets: Afifi et al.'s exposure-error and white-balance sets, Cube++ and NUS colour constancy.
    - Licensed stock-AI data programmes.
    - Asking Adobe or MIT directly about FiveK.
  - Paired data stays behind Gate P (T4) of the training plan.
- **Used here.** The only sources used for training and evaluation are Commons CC0/PD files, fetched through PD12M and checked per file. They were chosen because each file has a reviewed licence and structured data we could check without an account. Flickr CC0 and Open Images would add consumer photos, but each has its own open question:
  - Flickr CC0 needs an account and the API.
  - Open Images raises the attribution question.
- **Consent.** Every CC0, PD, CC BY and Flickr-derived source has the same gap: copyright is handled, but there are no model releases and no consent from the people pictured. Only FHIBE, MST-E and Casual Conversations v2 document consent, and each bars general training.

## 2. What was done without you

**Data routes**
- **Discovery.** Wikimedia Commons was searched through its API, filtered on CC0 or public-domain status: structured data **and** the rendered licence must both agree.
- **Bulk originals.** These come from PD12M's own S3 copies. They are byte-identical to the Commons uploads (md5 checked), and PD12M hosts them to spare the origin servers.
  - Commons' upload server admits only about 7–8 requests a minute from an unauthenticated client, and answered sustained downloads with 600 s blocks.
  - Using PD12M also avoided putting your email in our User-Agent string.
- **Committed vs local.** Downloads stay git-ignored under `experiments/auto/data/`. Only the manifests are committed (URL, licence, author and sha256 for each file), under `experiments/auto/manifests/`.

| Set | What | Rights evidence per file | Use |
|---|---|---|---|
| **PH-1** (public held-out) | 370 unedited photos:<br>• 331 phone (Samsung 114, Apple 87, Xiaomi 44, Huawei 29, Motorola 14, LG, Honor, Google, …)<br>• 39 camera, used as a fallback for portrait and backlit only | The file's sha1 is traced to its Commons page, and the CC0/PD, stock-import and edit-software rules are re-applied there. 13 candidates were refused (5 untraceable, 7 stock-site imports, 1 edited in Lightroom) | **Evaluation only.** Frozen and hashed (`manifests/ph1_FROZEN.json`, rows hash `241d0f13…`) before any photo training. Never used for tuning |
| **CC0REF** | 5,182 CC0 reference photos (PD12M: Commons 3,810 + iNaturalist 1,372), 640 px:<br>• train 4,340<br>• validation 542<br>• held-out synthetic **HO-SYN** 300 | PD12M's per-row CC0 record. Commons rows must have camera EXIF, which excludes scans and artworks. PDM rows are excluded | Self-supervised training (train), checkpoint choice (validation), held-out restoration test (HO-SYN) |

**PH-1 coverage against the protocol targets**

| Class | Target | PH-1 | Phone | Note |
|---|---|---|---|---|
| portrait | ≥ 40 | **59** | 31 | Every image has a detected face (Apple Vision, protocol detector) |
| backlit | ≥ 40 | **54** | 43 | No faces detected, so the subject is the darkest 30% |
| night | ≥ 40 (≈ 90 advised) | **60** | 60 | |
| sunset | ≥ 40 | **54** | 54 | |
| already-good | ≥ 40 | **60** | 60 | Reviewer judged "would post unedited" |
| landscape / indoor mixed | reported | 39 / 44 | all | Not gated (D3) |
| Skin tone: each MST bucket ≥ 30% of portrait + backlit | **not met** | — | — | **Unlabelled.** A provisional ITA estimate puts 31/59 faces in the deepest group, but ITA mixes in scene lighting and is not an MST label |
| ≥ 6 phone brands, one held-out device model | partly | 9 phone brands | — | No device model is held out as an unseen-device test |
| `face_underexposed` labels | **missing** | 0 | — | That conditional criterion therefore never fires |

**Separation (plan §3.4)**
- PH-1 and CC0REF come from disjoint PD12M shards.
- 74 references sharing a device+date capture session with PH-1 were dropped.
- pHash near-duplicates against PH-1 and DEV-22: 0 found.
- PD12M has no photographer field, so photographer-disjointness between CC0REF splits is approximated by capture session. It cannot be proven.

**Minors and people**
- Apparent minors were excluded on review.
- No PH-1 file carries Commons' personality-rights template.
- Identifiable adults are present: CC0 does not clear their likeness (§3.4).

**Model work.** This was done without you; numbers are in `docs/m3/auto-progress.md` §7–§8 and the closing report.
- A stage (a) model trained only on CC0REF train.
- It was evaluated on HO-SYN and PH-1 against the Original and the fixed control.
- It was exported to Core ML fp32, ONNX and TFLite under the contract.

## 3. What needs you

Under protocol 1.0.0, ship gates S1–S5 cannot pass on public data alone. The reasons:
- the frozen set must be T1 (a project rule you can change, §3.5 item 4);
- S2 and S3 need human raters;
- S5 needs counsel.

Items are in order of what unblocks the most.

**Every number in §3.1 to §3.3 is a PROPOSED study parameter.** You did not set them. They come from:
- protocol 1.0.0, which the project froze itself;
- the training plan;
- measurements on PH-1 and DEV-22.

Each row gives the reason for the number and what would change it. You may accept, change or reject any of them. Changing a protocol-level number means protocol 1.1.0, before the first T1 scoring. **No collection request has been sent, and none should be until you have decided.**

### 3.1 T1 photos with signed rights (D1, blocking G0, G1-real, G2, S1–S3)

**Who supplies them:** you choose the contributors (team members and/or consenting contributors). **Counsel** approves the form first (§3.4).

**Proposed parameters for the frozen set (G0)**

| Parameter | Proposed | Rationale | What would change it |
|---|---|---|---|
| Images per gated class (portrait, backlit, sunset, already-good) | **40** | **Protocol 1.0.0 minimum.** Measured on PH-1 (paired σ_d, candidate − Original), n = 40 resolves differences well inside the target widths:<br>• skin \|Δh\| 0.51° against a 4° target;<br>• sunset warm \|Δh\| 0.54° against 4°;<br>• already-good ΔE00 0.88 against 3.<br>The 80%-pass rule at n = 40 passes a model with a true pass rate of 0.90 98.5% of the time, but also one at 0.80 59% of the time and one at 0.75 30% of the time. So n = 40 screens gross harm; it does not certify 80% | If you apply the 80% rule to the 95% CI lower bound (§3.5 item 3), about **115 per class** gives 80% power when the true pass rate is 0.90 |
| Night images | **≈ 110** (minimum 40) | σ_d of night median ΔL* is 3.71 on PH-1 (3.39 on DEV-22). For a minimum detectable difference (MDD) of 1 L*, n = ((1.96 + 0.84) × 3.71 / 1)² ≈ **108**. At n = 40 the MDD is 1.6 L*, against a 3 L* tolerance | The 1 L* MDD is itself a proposal (a third of the tolerance). Accepting 1.5 L* needs about 48 |
| Backlit images | **≈ 90** (minimum 40) | σ_d of backlit subject ΔL* is 3.33 on PH-1, so about **87** for an MDD of 1 L* | Same as night |
| Landscape, indoor mixed | 40 each, **only if you gate them** (D3) | Same reasoning as the 40 above | Not gated: reported only, any n |
| Skin tone (portrait + backlit) | **≥ 24 per MST group** (1–3, 4–7, 8–10): 30% of ≥ 80 | **Protocol 1.0.0 rule** (each bucket ≥ 30%). At 24 images, 22 passing gives an exact 95% CI of 0.73–0.99: it catches a group that fails badly. It cannot show that groups are equal. Detecting a pass-rate gap of 0.90 against 0.75 needs about **100 per group**, and 0.90 against 0.70 about 62 | Whether you want a per-group *equality* test or only a per-group harm screen |
| Contributors | **≥ 10 per class, ≤ 4 images per contributor per class** | Photos from one person or session are correlated. On PH-1 the intra-contributor correlation of the per-image result is **0.16–0.18** (210 Commons contributors; a noisy estimate). Design effect = 1 + (m − 1) × ICC:<br>• m = 4 → 1.5 (40 images count as about 27 independent ones);<br>• m = 10 → 2.6 (about 15) | A pilot on T1 photos re-estimates the ICC. If it is smaller, fewer contributors suffice |
| Phone brands | **≥ 6 brands, no brand > 30% of a class**, plus **one held-out device model** | **Coverage logic, not power.** Each maker's tone mapping and HDR differ, and those are the failures Auto must handle. PH-1 has 9 brands, but Samsung and Apple are 61% of the phone photos. The held-out model is a single-device generalisation check, not a statistical claim | The brand list should follow your launch markets' current market share. That needs a sourced figure, which this document does not supply |
| Capture | Default camera app, no edits, no messaging-app recompression | The model must see what the app's decoder sees | — |

**Proposed parameters for the validation split and training**

| Split | Proposed | Rationale |
|---|---|---|
| Validation | 100–150, about 20 per class, **different contributors and sessions** from the frozen set | It is used only for tuning (gates, checkpoints). At n = 20 the already-good MDD is 1.24 ΔE00: enough to rank settings, not to certify them |
| Training (optional) | Hundreds or more, any class | Each photo adds real phone failures that synthetic degradations do not model. Experiment 1 showed that synthetic recovery does not transfer to night, sunset and already-good |

**Why PH-1 cannot be the G0 set under protocol 1.0.0**
- The protocol requires the frozen set to be T1. That rule was chosen by the project; you can change it (§3.5 item 4).
- PH-1 has no consent from the people pictured.
- PH-1 has no human MST labels.
- 47% of PH-1 portraits are camera fallbacks, not phones.
- PH-1 has now been scored for two candidates: the ungated model and one pre-registered gate. Re-using it to choose between further variants would make it a tuning set. The next round should freeze a new held-out set.

### 3.2 Labels (needed for both T1 and PH-1)
- **MST bucket**:
  - two annotators per image (a proposal: two is the minimum that gives an agreement measure), plus self-identification where the contributor offers it;
  - T1 portrait and backlit;
  - **PH-1's 59 portraits**, so the existing held-out runs can be broken down by skin tone. These are public photos, so labelling them needs no consent, but annotators should follow the same guide.
- **`face_underexposed`** flag where it applies: T1 and PH-1 portraits and backlit.
- **Annotator training**:
  - Google MST-E: its terms (§1.1) cover annotator training. Someone must accept them; I did not.
  - Sony FHIBE (commercial **bias evaluation** only) needs a click-through agreement. Your decision, because agreeing to terms is yours to do.
- Manifest schema: `experiments/auto/lightly_auto/manifest.py`. Rights-ledger columns are `permitted_uses` and `rights_doc_id`.

### 3.3 Preference study (S2, S3): proposed design

**Why this study is needed.** The rubric only screens out harm. The unchanged Original passes every gated class except backlit. Whether the correction *improves* a photo is measurable only by people, and **it has not been measured** (report §4).

| Parameter | Proposed | Rationale | What would change it |
|---|---|---|---|
| Comparisons per arm pair (candidate vs Original, candidate vs Core Image auto) | **≈ 195 independent comparisons**, inflated by the design effect from the pilot | To detect a 60% preference against 50% (two-sided α = 0.05, power 0.8): n = 194 | **60% is a proposal for the smallest improvement worth detecting.** At 55%, n = 783. At 65%, n = 85 |
| Already-good non-inferiority (S2: 95% CI lower bound ≥ 45%) | **≈ 785 comparisons on already-good photos** | The plan's S2 rule. If the true share is 50%, n = ((1.96 + 0.84) × 0.5 / 0.05)² ≈ 785 for 80% power. This was not computed in the plan, and it is much larger than the 195 above | A wider margin (40%) needs about 196 |
| Pilot | **About 100 comparisons** | To estimate rater agreement (ICC) and the design effect before the main study | — |
| Raters | **≥ 8**, a mix of photographers and non-photographers, internal or volunteer | With 8 raters sharing the work evenly, no single rater supplies more than 12.5% of the judgements. A rater who always prefers one side moves the share by at most about 6 points | The pilot ICC. High rater disagreement means more raters |
| Rater diversity for portraits | **≥ 30% of portrait raters** from skin-tone groups other than the subject's majority | Coverage logic: skin rendering is judged differently across groups | — |
| Presentation | Blind, randomised left/right, same display, each photo shown once per rater | Standard paired-comparison controls | — |

### 3.4 Counsel questions (S5)
1. **Consent and IP form for T1.** It must cover training, evaluation and commercial shipping of the model, model releases, no minors, and revocation wording.
2. **CC0/PD photos of identifiable people.** Can CC0 Commons/PD12M photos showing identifiable adults be used to train a model shipped in a paid app? Copyright is waived, but privacy and publicity rights are not (CC0 §4(b); Commons, *Photographs of identifiable people*). GDPR also applies if any subject is in the EU.
3. **PD12M's per-row licence record.** Is it acceptable evidence for training references that were **not** individually traced to Commons? PH-1 files were traced; CC0REF files were not, because of the rate limit. Tracing all 5,182 would take about 10 hours at the API rate, and can be done if counsel wants it.
4. **Unsplash Lite.** Does "internal business purposes" cover a model shipped in a paid app? (D2, unchanged.)
5. **Public Domain Mark (PDM) files.** Excluded so far. Can they be used?
6. **MST-E and FHIBE.** Is use for annotator training and skin-tone bias evaluation of a commercial model covered by their terms?
7. **New: Open Images and HDR+.** Do CC BY attribution and CC BY-SA ShareAlike attach to a trained model?

### 3.5 Owner decisions (D3, plus new ones) before T1 scoring
Changing any of these means protocol 1.1.0, and it must happen **before** the first T1 scoring.
1. **Landscape.** Gate it or not, and with what target. Indoor mixed has the same question.
2. **The 0.5 pp new-clipping tolerance.** Accept it or tighten it.
3. **The 80% rule.** Apply it to the point estimate (current) or to the 95% CI lower bound (stricter; about 115 per class, §3.1).
4. **Should CC0 public photos count toward G0 for classes without people** (sunset, night, landscape, indoor, people-free already-good)?
   - **If yes,** you would only need T1 for portrait, backlit-with-people, and the skin-tone quotas. With the proposals above, that is roughly 130–200 T1 images instead of about 320 (400 if landscape and indoor are gated).
   - **Cost:** the set would no longer be all phone-native from known devices.
   - **Default if you do not decide:** no. The protocol stays T1-only.
5. **New: the proposed study parameters in §3.1 to §3.3.** Accept, change or reject each one. This includes:
   - the smallest preference effect worth detecting (60% proposed);
   - the night/backlit MDD (1 L* proposed);
   - whether skin-tone groups need an equality test or only a harm screen.

### 3.6 Not data, but also needed for shipping
- Android hardware (one Adreno and one Mali phone) for S4 parity.
- The iOS float-LUT Metal kernel.

## 4. What I did not do
- **Paid engagements, procurement and cloud processing.** None.
- **Downloads and agreements.** No download needed an account or a click-through. FHIBE, MST-E, the gated Getty sample and Flickr API access were left for you.
- **FiveK.** No FiveK data or weights touched any trained or exported artefact.
- **The apps.** The model is not integrated into either app. The exports stay git-ignored under `experiments/auto/runs/` and are archived privately (report §7).
