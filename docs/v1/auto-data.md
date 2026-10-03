# Auto: data status and what needs the product owner

Status: 2026-10-03. Not legal advice. Progress is tracked in `docs/m3/auto-progress.md` (§7 has this round's results). The code is in `experiments/auto/`. Nothing here is linked into either app.

**In short**
- **Done without you.**
  - A public held-out evaluation set (PH-1) of CC0 and public-domain phone and camera photos, frozen before any photo training.
  - A session-disjoint training and held-out reference set (CC0REF) of CC0 photos.
  - A self-supervised Auto model trained only on CC0REF, evaluated on both held-out sets, and exported to Core ML, ONNX and TFLite.
    - It is image-adaptive and beats the fixed control on held-out data.
    - It still fails the rubric on sunset, night, backlit and already-good, so it is **not** releasable as AI Auto.
- **Still needs you.** No ship gate can pass without:
  - **T1 photos** with signed rights (§3.1);
  - **human skin-tone and exposure labels** (§3.2);
  - **raters** for the preference study (§3.3);
  - **counsel's answers** (§3.4);
  - **your three D3 decisions** (§3.5).

## 1. Data survey

Primary terms pages were fetched on 2026-10-03. Quotes are short extracts, so check them against the live page before relying on them in a legal memo.
- **Eval-ok:** we may score our model on it internally for a commercial product.
- **Train-ok:** we may train a model that ships in a paid app.

| Source | Licence and decisive terms | Expert before/after pairs | Content and size | Skin-tone labels | Verdict |
|---|---|---|---|---|---|
| **Wikimedia Commons, CC0 or public domain (checked per file)** | [CC0 1.0](https://creativecommons.org/publicdomain/zero/1.0/legalcode) waives copyright "for any purpose whatsoever, including … commercial". It does **not** clear personality or privacy rights ([Template:Personality rights](https://commons.wikimedia.org/wiki/Template:Personality_rights): people shown "may have rights that legally restrict certain re-uses"). Wikimedia gives no warranty | No | About 8.6M CC0 bitmap files; phone and camera photos of every scene type. CC0 **phone** portraits are scarce (43 found) | No | **Eval-ok. Train-ok per file**, with the counsel question on identifiable people (§3.4). **Used here** |
| Openverse | [ToS](https://docs.openverse.org/terms_of_service.html): "does not verify its licensing status". It grants no licence of its own | No | Search index over Flickr, Commons and others | No | Only as a search tool. The underlying file's licence decides |
| Flickr CC0 / Public Domain Mark | CC0 is a waiver. PDM is a label, not a licence ("not legally operative"). Checking each file needs the Flickr API, which needs an account | No | Large | No | CC0: train-ok per file (not used, because it needs an account). PDM: counsel |
| Megalith-10M | Card is MIT. Its rows are Flickr CC0, PDM, "no known copyright restrictions" or US Gov, with **no per-row licence field**. The creator says "1-2% may be copyright-constrained" | No | 9.58M Flickr URLs | No | **Neither as is.** Each file cannot be checked without the Flickr API |
| PD12M (Spawning) | CDLA-Permissive-2.0 metadata; "public domain and CC0" images | No | 12.4M, mostly museum collections and iNaturalist | No | Train-ok but a poor fit (few consumer photos). Not used |
| NASA media | [Guidelines](https://www.nasa.gov/nasa-brand-center/images-and-media/): "generally are not subject to copyright". Insignia may not appear "in the training of AI tools". Identifiable people carry publicity rights | No | Space and aerospace imagery | No | Eval-ok and train-ok after filtering out people, insignia and third-party © material. A poor fit; not used |
| Unsplash (site licence) | [Terms](https://unsplash.com/terms): you may not "use the Images in connection with any machine learning and/or artificial intelligence datasets" | No | Millions of stock photos | No | **Neither.** DEV-22 is development data only, and even that is a grey area |
| Unsplash Lite dataset | [TERMS.md](https://github.com/unsplash/datasets/blob/master/TERMS.md) §2A: "train machine learning models … for your internal business purposes". Redistribution and publishing comparisons are banned | No | About 25k finished stock photos | No | **Counsel (D2):** does a model shipped in a paid app count as "internal business purposes"? |
| Pexels | [ToS](https://www.pexels.com/terms-of-service/): scraping is "strictly prohibited … for machine learning purposes"; "bulk, large-scale or systematic copying" needs permission | No | Stock photos | No | **Neither at scale** without written permission from Pexels |
| MIT-Adobe FiveK | [LicenseAdobe.txt](https://data.csail.mit.edu/graphics/fivek/legal/LicenseAdobe.txt): "solely for your own research purposes … not … directed toward commercial advantage" | **Yes (5 experts)** | 5,000 RAW | No | **Neither.** Research-only. Never in any shippable artefact |
| PPR10K | [README](https://github.com/csjliang/PPR10K): "non-commercial research purposes only", including "any portion of derived data" | **Yes (3 experts)** | 11,161 RAW portraits | No | **Neither** |
| RAISE | [Guide](https://loki.disi.unitn.it/RAISE/guide.html): "non-commercial research and educational purposes" | No | 8,156 RAW (DSLR) | No | **Neither** |
| DIV2K | [Page](https://data.vision.ee.ethz.ch/cvl/DIV2K/): "academic research purpose only"; third parties own the copyright | No | 1,000 2K images | No | **Neither** |
| LSDIR | [Site](https://ofsoundof.github.io/lsdir-data/): "academic research purpose only"; Flickr owners keep copyright | No | About 87k | No | **Neither** |
| Google HDR+ | [Dataset page](https://hdrplusdata.org/dataset.html): CC BY-SA, with "main intention … scientific purposes" | Pipeline outputs only, not expert edits | 3,640 phone bursts (Nexus/Pixel) | No | Eval-ok with attribution. Training is a counsel question (ShareAlike) |
| Open Images V7 | [Facts page](https://storage.googleapis.com/openimages/web/factsfigures_v7.html): images "listed as having a CC BY 2.0 license", with no warranty | No | About 9M Flickr images | No | Eval-ok with attribution. Training is a counsel question |
| Sony FHIBE | [Terms](https://fairnessbenchmark.ai.sony/legal/terms-of-use): use "to research or evaluate bias … for commercial … purposes". It "may not be used as training data" except for bias mitigation | No | Consented people, with fairness annotations | Yes (verify) | **Eval-ok for skin-tone bias only. Train: no.** Needs a click-through agreement, so not downloaded here (§3.2) |
| Google MST-E | [Paper](https://arxiv.org/abs/2305.09073): "research, model evaluations, or annotator-training purposes only"; "cannot be used to train" | No | 1,515 images, 19 consented subjects | **Yes (Monk scale)** | **Eval-ok (annotator training and skin-tone checks). Train: no** |
| Meta Casual Conversations v2 | "Limited; see full license"; evaluation allowed; training only on certain labels | No | 26,467 videos, consented | Yes (Fitzpatrick + Monk) | Counsel (full licence not reviewed). Video frames only |
| Getty sample (Hugging Face) | Grant refers to "permitted uses below" but lists none; no competing products; attribution required | No | 3,750 stock images | No | Counsel |
| LOL, SICE (low-light) | No licence stated, so all rights reserved | LOL: captured pairs; SICE: algorithm-chosen | ~500 / 4,413 | No | **Neither** |

**Bottom line**
- **Paired expert edits.** No public source offers expert before/after pairs with commercial rights. Every paired set (FiveK, PPR10K) is research-only. Paired data stays behind Gate P (T4).
- **Clean public source.** The only clean public source for both evaluation and training is CC0 or public-domain photos, checked per file. Wikimedia Commons is the practical way to get them, because every file has a reviewed licence and structured data we can check without an account.
- **Unsplash and Pexels.** Neither may be used for training.

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

**Model work.** This was done without you; numbers are in `docs/m3/auto-progress.md` §7.
- A stage (a) model trained only on CC0REF train.
- It was evaluated on HO-SYN and PH-1 against the Original and the fixed control.
- It was exported to Core ML fp32, ONNX and TFLite under the contract.

## 3. What needs you

Ship gates S1–S5 cannot pass on public data alone. Items in order of what unblocks the most.

### 3.1 T1 photos with signed rights (D1, blocking G0, G1-real, G2, S1–S3)

**Who supplies them:** you choose the contributors (team members and/or consenting contributors). **Counsel** approves the form first (§3.4).

| Split | Images | Per class | Skin tone (portrait + backlit) | Other |
|---|---|---|---|---|
| **G0 frozen set** | **≈ 280** (≥ 200 gated) | ≥ 40 each: portrait, backlit, sunset, already-good. Night: **≥ 40, plan for ≈ 90** if σ_d ≈ 3.4 holds. Landscape and indoor: 40 each if you gate them (D3) | ≥ 80 images, with ≥ 24 per MST group (1–3, 4–7, 8–10) | ≥ 6 brands. Hold out one complete device model. Default camera app, no edits, no messaging-app recompression |
| **Validation split** | 100–150 | ~20 per class | Same ratio | **Different contributors and sessions** from the frozen set |
| Training (optional, helps G1/G2) | hundreds or more | any | any | Same form. Each one adds real phone failures that synthetic degradations do not model |

**Why public data does not substitute here**
- Protocol 1.0.0 requires the frozen set to be T1.
- PH-1 has no consent from the people pictured.
- PH-1 has no human MST labels.
- PH-1 portraits are 47% camera fallbacks.

### 3.2 Labels (needed for both T1 and PH-1)
- **MST bucket**:
  - two annotators per image, plus self-identification where the contributor offers it;
  - T1 portrait and backlit (≈ 80+);
  - **PH-1's 59 portraits**, so the existing held-out runs can be broken down by skin tone. These are public photos, so labelling them needs no consent, but annotators should follow the same guide.
- **`face_underexposed`** flag where it applies: T1 and PH-1 portraits and backlit.
- **Annotator training**:
  - Google MST-E is licensed for "annotator-training purposes". Someone must accept its terms; I did not.
  - Sony FHIBE (commercial **bias evaluation** only) needs a click-through agreement. Your decision, because agreeing to terms is yours to do.
- Manifest schema: `experiments/auto/lightly_auto/manifest.py`. Rights-ledger columns are `permitted_uses` and `rights_doc_id`.

### 3.3 Raters for the preference study (S2, S3)
**Raters**
- ≥ 8, mixing photographers and non-photographers, internal or volunteer.
- For portraits, ≥ 30% of raters from skin-tone groups other than the subject's majority.

**Volume**
- About 100 comparisons for the pilot (ICC).
- About **195 independent comparisons per arm pair** to detect 60% vs 50%, inflated by the design effect from the pilot.
- Arm pairs: candidate vs Original, and candidate vs Core Image auto.

The rubric only screens out harm: the unchanged Original passes every gated class except backlit. **Improvement is only measurable by people.**

### 3.4 Counsel questions (S5)
1. **Consent and IP form for T1.** It must cover training, evaluation and commercial shipping of the model, model releases, no minors, and revocation wording.
2. **CC0/PD photos of identifiable people.** Can CC0 Commons/PD12M photos showing identifiable adults be used to train a model shipped in a paid app? Copyright is waived, but privacy and publicity rights are not (CC0 text; Commons Template:Personality rights). GDPR also applies if any subject is in the EU.
3. **PD12M's per-row licence record.** Is it acceptable evidence for training references that were **not** individually traced to Commons? PH-1 files were traced; CC0REF files were not, because of the rate limit. Tracing all 5,182 would take about 10 hours at the API rate, and can be done if counsel wants it.
4. **Unsplash Lite.** Does "internal business purposes" cover a model shipped in a paid app? (D2, unchanged.)
5. **Public Domain Mark (PDM) files.** Excluded so far. Can they be used?
6. **MST-E and FHIBE.** Is use for annotator training and skin-tone bias evaluation of a commercial model covered by their terms?

### 3.5 Owner decisions (D3, plus one new) before T1 scoring
Changing any of these means protocol 1.1.0, and it must happen **before** the first T1 scoring.
1. **Landscape.** Gate it or not, and with what target. Indoor mixed has the same question.
2. **The 0.5 pp new-clipping tolerance.** Accept it or tighten it.
3. **The 80% rule.** Apply it to the point estimate (current) or to the 95% CI lower bound (stricter; needs larger n).
4. **New: should CC0 public photos count toward G0 for classes without people** (sunset, night, landscape, indoor, people-free already-good)?
   - **If yes,** you would only need T1 for portrait, backlit-with-people, and the skin-tone quotas. That is roughly 100–130 T1 images instead of about 280.
   - **Cost:** the set would no longer be all phone-native from known devices.
   - **Default if you do not decide:** no. The protocol stays T1-only.

### 3.6 Not data, but also needed for shipping
- Android hardware (one Adreno and one Mali phone) for S4 parity.
- The iOS float-LUT Metal kernel.

## 4. What I did not do
- **Paid engagements, procurement and cloud processing.** None.
- **Downloads and agreements.** No download needed an account or a click-through. FHIBE, MST-E and Flickr API access were left for you.
- **FiveK.** No FiveK data or weights touched any trained or exported artefact.
- **The apps.** The model is not integrated into either app. The exports stay git-ignored under `experiments/auto/runs/`.
