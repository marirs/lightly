# M1 licensing review: Image-Adaptive 3D LUT auto-enhance and bundled presets

Status: research note, 2026-10-01. **Not legal advice.** This note sets out what can be checked from primary sources (licence files, git history, published terms). It also lists what needs a lawyer's opinion before a paid release of Lightly on iOS or Android.

Upstream: `HuiZeng/Image-Adaptive-3DLUT` @ `b491f6df64a588864739a157db271e5c848e1805`. Local clone: `experiments/lut3d/reference/upstream`.

---

## Summary

| Artifact | Licence / terms | Commercial use in a paid app? | Confidence | Evidence |
|---|---|---|---|---|
| Upstream Python code (`models*.py`, train/eval scripts, `datasets.py`, `utils/`) | Apache-2.0. Root `LICENSE` matches the canonical text apart from whitespace; copyright placeholder left unfilled; no NOTICE file; no per-file headers. | **Yes**, with Apache §4 obligations (include licence text, mark changes). | High | `LICENSE`; [issue #42](https://github.com/HuiZeng/Image-Adaptive-3DLUT/issues/42); [PR #53](https://github.com/HuiZeng/Image-Adaptive-3DLUT/pull/53) |
| `trilinear_c/`, `trilinear_cpp/` CUDA/C++ kernels | No headers and no third-party marker, so presumably the repo's Apache-2.0. | Yes, but our port does not use them (we use Core ML / ONNX plus our own LUT sampling). | Medium-high | file inspection |
| `torchvision_x_functional.py` | **Not from torchvision.** Closest match (78% line similarity) is `torchsat/transforms/functional.py` by sshuair (formerly `torchvision-enhance`), which is **MIT**. The MIT notice was not kept upstream. | Not needed. It is training-time augmentation only and not in our port. If reused, add the MIT notice. | Medium-high | [sshuair/torchsat](https://github.com/sshuair/torchsat); diff in §1.4 |
| `ssim.m` (Zhou Wang) | Custom licence for educational and research use only, with no commercial adaptation. | **No.** Evaluation script only, so do not ship or port it. | High | file header |
| `local_tone_mapping/wlsFilter.m`, `wlsTonemap.m` | No licence header; appears to be a third-party reference implementation of Farbman et al. 2008. | Unknown. Not used and not shipped. | Low | file header |
| MIT-Adobe FiveK images (inputs **and** expert A–E retouches) | Adobe "Research License" (2,690 files) and Adobe+MIT "Research License" (2,310 files). Research only, with no commercial advantage. | **No** (for using the data) | High | [LicenseAdobe.txt](https://data.csail.mit.edu/graphics/fivek/legal/LicenseAdobe.txt), [LicenseAdobeMIT.txt](https://data.csail.mit.edu/graphics/fivek/legal/LicenseAdobeMIT.txt) |
| Shipped weights `pretrained_models/{sRGB,XYZ}/*.pth` (paired and unpaired) | Apache-2.0 applies to the repo, and nothing carves the weights out. They were trained on FiveK expert C (inferred: author never confirmed, [issue #65](https://github.com/HuiZeng/Image-Adaptive-3DLUT/issues/65) unanswered). | **Unresolved. Treat as no.** | Low (legal question is unsettled) | §2–3 |
| Our converted artefacts `experiments/lut3d/models/*` (Core ML, ONNX, LUT .bin) | Derived from the sRGB paired FiveK weights (see `MODEL_CARD.json`). | Same as the weights: **do not bundle.** They are currently git-ignored and not in `ios/Lightly/`. | High (factual) | `experiments/lut3d/models/MODEL_CARD.json` |
| Google HDR+ burst dataset | CC BY-SA 4.0, with a stated intention of "scientific purposes". | Possible in principle (BY-SA allows commercial use), but ShareAlike's effect on trained weights is unclear and the domain is different. Not used by the shipped weights. | Medium | [hdrplusdata.org](https://hdrplusdata.org/dataset.html) |
| PPR10K | Non-commercial research only, **including "derived data"**. | **No** | High | [PPR10K README](https://github.com/csjliang/PPR10K) |
| Unsplash photos (standard licence, our 22 test photos) | Unsplash License plus Terms §8, which **prohibits ML dataset/training use**. | Not for training. Evaluation use is a grey area (§4a). | High (training) / Medium (eval) | [unsplash.com/terms](https://unsplash.com/terms) |
| Unsplash **Lite Dataset** (25k images) | Dataset Terms §2A: commercial licence to train ML models "for your internal business purposes". | **Probably yes, but counsel must confirm** that shipping the trained model counts as internal business purposes. | Medium | [unsplash/datasets TERMS.md](https://github.com/unsplash/datasets/blob/master/TERMS.md) |
| Pexels photos | Pexels Licence is silent on ML. ToS §8 bans scraping or automated collection "for machine learning purposes". | Unclear. Manual download for training is not expressly allowed. Avoid. | Medium | [pexels.com/terms-of-service](https://www.pexels.com/terms-of-service/) |
| **Bundled presets** `presets_photo.json` (3,157) and `luts_video.json` (1,742 entries) | All come from commercial third-party packs (WithLuke, SolutionPresets, Huliluts). Huliluts **expressly forbids** putting presets inside an end product. | **Huliluts: the published terms prohibit it** (quoted, §5). **WithLuke and SolutionPresets: unverified.** No redistribution grant was found, and no prohibition specific to the presets was found either. | High (Huliluts) / Low (others) | §5 |

**Bottom line**

- **Code.** Apache-2.0 is fine for the code.
- **Weights.** The pretrained weights should not ship in a paid app. They come from FiveK expert-C retouches, which are under a research-only licence, and the repo's Apache-2.0 notice does not reliably clean that up.
- **Auto-enhance plan.** Retrain our own reimplementation of the Apache-2.0 architecture on data we have commercial rights to.
- **Presets.** The bundled presets come from three commercial packs.
  - Huliluts' published file licence prohibits incorporating its presets in an end product.
  - For WithLuke and SolutionPresets the terms are unverified. Confirm them with each vendor before distributing their presets.
  - This is a distribution question only. It does not gate internal conversion, evaluation or engineering acceptance.

---

## 1. Code licence

### 1.1 LICENSE file and history
- `LICENSE` is the standard Apache License 2.0. A whitespace-insensitive diff against `apache.org/licenses/LICENSE-2.0.txt` shows no differences. The appendix placeholder `Copyright [yyyy] [name of copyright owner]` was never filled in.
- `git log -- LICENSE` returns one commit: `9b59e5db413213ca39ddd7bb5e20b28dc42467bd`, 2021-09-23 09:49 +0800, **Hui Zeng** ("Create LICENSE", merged as PR #53).
- Context: issue #42 ("Could you please specify the license for the repo?") was opened 2021-01-23. The author closed it on 2021-09-23, replying that "the Apache license has been specified". The GitHub API reports `spdx_id: Apache-2.0`.
- **Timing matters for §3.** The code and paired weights were committed 2020-09-28 and the unpaired weights 2020-10-09. All of this was about a year **before** the LICENSE was added. Earlier copies of the repo had no licence at all. Our pinned commit `b491f6d` postdates the LICENSE, so Apache-2.0 applies to what we cloned.

### 1.2 NOTICE and per-file headers
- There is no `NOTICE` file, so Apache §4(d) has nothing extra to pass on.
- No Python, C, C++ or CUDA file carries a copyright or licence header. The only authorship marker is `utils/visualize_lut.py: @author: Hongkai Zhang`, a contributor. That file is covered by the repo licence and not used by us.

### 1.3 Vendored or third-party material inside the repo
| File | Origin | Licence | Relevance |
|---|---|---|---|
| `trilinear_c/src/*`, `trilinear_cpp/src/*` | Written for this repo. The `CUDA_1D_KERNEL_LOOP` macro is a common idiom also found in Caffe2/Detectron, but it is trivial. | Repo Apache-2.0 | Not used by our port. |
| `torchvision_x_functional.py` | Derived from sshuair's `torchvision_x` / TorchSat (see §1.4). Includes a Chinese-language comment typical of that project. | **MIT** (TorchSat LICENSE, © 2018/2019 sshuair). Notice not kept upstream. | Training augmentation only. Not ported. |
| `ssim.m` | Zhou Wang, 2009 | Custom research licence: "shall not be used, rewritten, or adapted as the basis of a commercial software" (header) | Evaluation only. **Do not port.** |
| `local_tone_mapping/wlsFilter.m`, `wlsTonemap.m` | Reference implementation of Farbman et al., "Edge-Preserving Decompositions", SIGGRAPH 2008. Original author unknown; no header. | Unknown | Not used. |
| `models.py: resnet18_224` | Loads torchvision ImageNet-pretrained ResNet-18. | torchvision code is BSD-3. ImageNet-derived weights carry their own non-commercial concerns. | **Not used** by the shipped `Classifier` (a 270k-parameter CNN trained from scratch). No ImageNet dependency in our port. |
| `IdentityLUT33/64.txt`, `visualization_lut/learned_LUT_*.txt` | Identity LUTs are generated data. Learned LUTs are FiveK-trained outputs. | — | Learned LUTs share the weights' status. Do not use. |

### 1.4 What `torchvision_x_functional.py` actually is
The brief guessed it was copied from torchvision (BSD-3). It is not a torchvision copy:
- It defines functions torchvision never had, such as `to_tiff_image`, `bbox_*`, `elastic_transform`, `noise` and `preserve_channel_dim`.
- I compared it with every historical `functional.py` in `github.com/sshuair/torchsat` (formerly `torchvision-enhance`, PyPI `torchvision-enhance` 0.1.x, whose package is literally named `torchvision_x`). The best match is `torchsat/transforms/functional.py` at commit `13b8ba2` (2019-09-26), with difflib line ratio 0.78.
- The PyPI 0.1.x releases score only 0.08. They are an older, smaller version.
- TorchSat is MIT-licensed. Parts of it may themselves be adapted from torchvision (BSD-3). For our purposes this does not matter, because **we do not use this file**.

### 1.5 Our obligations if we ship a port of the code
`experiments/lut3d/reference/ia3dlut.py` reimplements `Classifier` / `Generator3DLUT` / trilinear lookup.

- **If it copies upstream code** (structure, layer definitions), treat it as a derivative work under Apache-2.0. That means:
  - include the Apache-2.0 text in the app's "Licences" screen (the spec v1.1 already plans "About → Licences");
  - attribute "Image-Adaptive-3DLUT, © Hui Zeng et al.";
  - mark the files as modified (§4(b)).
- **If it is a clean reimplementation from the paper**, attribution is courtesy rather than obligation. Including it anyway is cheap.

### 1.6 Author statements on licensing or commercial use
- GitHub issue search on `license`, `commercial`, `weights` and `pretrained` finds only #42 and PR #53 on licensing.
- **No author statement anywhere addresses commercial use or the licence of the weights or data.**
- Issue #65 (2022-06-15) asks "Which training dataset was used for these models?" and is still open with no answer.
- Issue #51 uses the word "commercial" only to mean commercial LUTs, and is technical.
- Web searches for "Image-Adaptive-3DLUT commercial" found nothing further.

---

## 2. Dataset terms

### 2.1 MIT-Adobe FiveK
- **Two licences split the 5,000 photos.** The site says "You can use these photos for research under the terms of the following licenses".
  - `LicenseAdobe.txt` (© 2011 Adobe) covers the 2,690 files in `filesAdobe.txt`, e.g. `a0001-jmac_DSC1459`.
  - `LicenseAdobeMIT.txt` (© 2011 Adobe and MIT) covers the 2,310 files in `filesAdobeMIT.txt`.
  - The two texts are the same apart from the parties.
- **Operative restrictions (both licences)**, quoted:
  - Use is limited to "solely for your own research purposes" (condition 1).
  - Licensees may not act in any manner "intended for or directed toward commercial advantage or monetary compensation" (condition 1).
  - The licence binds on access: "BY DOWNLOADING, VIEWING OR OTHERWISE EXERCISING ANY OF THE RIGHTS PROVIDED HEREIN…" (preamble).
  - Breach ends the licence: rights "will terminate automatically upon any breach by you" (closing paragraph).
  - The licence claims to be the "entire agreement" with respect to the Images.
- **Do the restrictions cover the expert retouches (expert C targets)?** The licences cover "the images provided in connection with this license". Expert A–E renditions are distributed from the same page, under the same "License" heading and in the same archive, with per-image links next to each input. Nothing offers a separate or more permissive licence for the renditions.
  - The natural reading is that the research-only terms cover the input DNGs, the expert TIFFs and the Lightroom catalog alike.
  - The retouches are also derivative works of the input photos, so they could not be more freely usable than the inputs in any case.
  - A lawyer could argue the licence text speaks of "Images" without defining them to include renditions. But there is no affirmative grant anywhere that would allow commercial use of the retouches. **Confidence: high** that expert C targets are research-only.
- **Who owns what.** The retouches were made by five paid photography students. The photos were contributed by many photographers ("Special thanks to everyone who contributed their photos").

### 2.2 Which dataset trained each shipped weight file
| Weight file | Training data (inferred) | Basis |
|---|---|---|
| `sRGB/LUTs.pth`, `sRGB/classifier.pth` (paired) | FiveK: 4,500 pairs of 480p sRGB input (`train_input.txt` + `train_label.txt`) with **expert C** JPG targets | `image_adaptive_lut_train_paired.py` defaults to `--dataset_name fiveK` and uses `ImageDataset_sRGB` with `combined=True`, which merges both lists. Paper §4.3: "4,500 image pairs are used for training". |
| `XYZ/LUTs.pth`, `XYZ/classifier.pth` (paired) | FiveK: 16-bit XYZ input (`PNG/480p_16bits_XYZ_WB`) with **expert C** sRGB targets | `ImageDataset_XYZ`. The HDR+ loader has no XYZ variant and is not wired into either training script. |
| `*/LUTs_unpaired.pth`, `*/classifier_unpaired.pth` | FiveK too: 2,250 inputs (`train_input.txt`) against 2,250 **expert C** images of *other* scenes (`train_label.txt`) | `ImageDataset_*_unpaired`. Author in #10: retrained "using the released code" (FiveK defaults). |

- HDR+ is used in the paper (675 Nexus 6P training scenes) but, as far as the code shows, **not** for any shipped weights.
- PPR10K is not involved. It is a later paper by an overlapping author group.
- Confidence that all shipped weights are FiveK expert C: **medium-high**. It follows from the defaults, folder layout and paper; the author has not confirmed it (#65).
- The **unpaired** weights still learn the expert-C distribution through the discriminator, so "unpaired" does not avoid the FiveK question.

### 2.3 HDR+ burst dataset
- Licence: CC BY-SA 4.0. The site adds that "our main intention is that the dataset be used for scientific purposes". That is a statement of intent, not a licence term.
- CC BY-SA 4.0 permits commercial use, with attribution and ShareAlike for "Adapted Material". Whether a trained model is Adapted Material, which would force SA licensing of the weights, is unsettled.
- Its targets are Google's tuned HDR+ pipeline outputs for Nexus 6P bursts. They capture camera-pipeline tone mapping, not retoucher taste.

---

## 3. Pretrained weight terms

**What the repo says:** nothing specific. There is no model card, no weights licence, and no README statement. The only licence is the repo-wide Apache-2.0, added a year after the weights.

**Argument that the weights are Apache-2.0:**
1. They are files in the repo.
2. The licensor put a root LICENSE with no carve-out.
3. GitHub convention treats a root licence as covering the whole repository.

On this view the author has granted everyone Apache-2.0 rights in the weights, including commercial use.

**Why that does not settle it:**
1. **The licensor cannot grant more than it has (*nemo dat*).** Apache-2.0 licenses the contributor's own copyright and patents. It cannot license rights belonging to Adobe, MIT, the FiveK photographers or the retouchers.
   - If the weights embody protectable expression from FiveK, Hui Zeng's Apache grant does not cover that part.
   - If the weights embody no protectable expression, Apache-2.0 adds little; the issue is then contract (point 3), not copyright.
2. **Whether trained weights are a "derivative work" of training data is legally unsettled.** This varies by jurisdiction and is being litigated in several countries for generative models; it is less studied for small discriminative or regression models.
   - For a 270k-parameter model that predicts 3 mixing weights over 3 learned 33³ LUTs, the argument that the weights copy any particular photo is weak. But the basis LUTs are a compressed statistical summary of expert C's colour decisions.
   - Style itself is generally not protected by copyright. The individual retouched images are.
   - The **copyrightability of weights themselves** (machine-generated numbers) is also unsettled.
3. **Contractual restrictions can bind regardless of copyright status.**
   - The FiveK licence is drafted as a click-through contract ("YOU ACCEPT AND AGREE TO BE BOUND"). It restricts the *exercise of rights* to research and forbids anything "directed toward commercial advantage".
   - Hui Zeng (or PolyU) downloaded FiveK under that contract. Publishing the trained weights for research was within it; sublicensing them for commercial use arguably was not.
   - **We** are not party to the FiveK contract unless we download FiveK. **We have not**, according to the repo contents (`experiments/lut3d/photos` contains 22 Unsplash images). Our exposure is therefore mainly:
     - (a) a copyright-derivation claim, which is weak but not zero;
     - (b) the commercial reality that the Apache grant may be ineffective for FiveK-derived rights, so we would rely on an unlicensed chain;
     - (c) reputation and App Store review: "trained on a research-only dataset" is a well-known red flag in due diligence and acquisitions.
   - If anyone on the team has downloaded FiveK (e.g. to reproduce results), they **are** bound by its licence. Any training they do with it must stay research-only.
4. **Industry practice.** Commercial products avoid FiveK-trained weights. Datasets from this same author group (PPR10K) explicitly extend the research-only restriction to "derived data". That shows how the research community itself reads these licences.

**Assessment:** shipping the upstream weights, or our Core ML / ONNX conversions of them, in a paid app is **not a defensible default**. The risk is not that a claim is certain; it is that we cannot show a clean chain of rights. Retraining is cheap (§4e), so the cost-benefit strongly favours retraining.

What a lawyer would need to confirm is listed in "Open questions for counsel".

---

## 4. Viable commercial paths

### 4a. Retrain the Apache-2.0 architecture on commercially licensed paired data

**Source photos (inputs). Options checked:**
| Source | Terms (as fetched 2026-10-01) | Usable for training? |
|---|---|---|
| Unsplash standard licence and site | The licence allows commercial use but not to "compile images from Unsplash to replicate a similar or competing service". **Terms §8** prohibits using images "in connection with any machine learning and/or artificial intelligence datasets", e.g. training. API Terms §12 redirects ML use to unsplash.com/data. | **No.** |
| **Unsplash Lite Dataset** (25k photos, free) | Dataset Terms §2A: a licence to "internally use the Commercial Licensed Data to train machine learning models" "for your internal business purposes". §3 forbids redistributing the data and publishing dataset comparisons. §9 has a broad indemnity, including for models trained on it. | **Probably**, subject to counsel on whether shipping the trained model in a paid app is "internal business purposes". Its photos are finished or edited stock, so they work as *targets* for path 4b but are poor "flat" *inputs*. |
| Unsplash Full Dataset | §2B is non-commercial: models trained on it "must not be used for commercial purposes". | **No.** |
| Pexels | The licence page is silent on ML. ToS §8 says scraping and automated collection are "strictly prohibited for all unauthorised purposes, including without limitation for machine learning purposes". It also bans "bulk, large-scale or systematic copying". | **Avoid.** Training use is not expressly allowed, and building a dataset would hit the bulk-copy ban. |
| Own or commissioned RAW captures | Work-for-hire or IP assignment from the photographers, plus model releases where people are identifiable. | **Yes, the cleanest option.** RAW lets us render the "flat" input exactly as Lightly's pipeline sees it. |
| Stock agencies' AI-training data licences (Shutterstock, Getty, Adobe Stock, etc.) | Enterprise deals; terms and prices not verified here. | Possible but costly. Needs a quote. |

**Targets (expert edits):**
- Hire **one** professional retoucher, or a small team working to one written style guide, under a contract that:
  - assigns copyright in the edits (or is work-for-hire where valid);
  - grants explicit rights to train models and ship them commercially;
  - waives moral rights where possible.
- Using a single retoucher mirrors FiveK's single expert C. It gives a consistent "Lightly look", which is a product advantage.
- Deliverables: Lightroom-style global edits (exposure, WB, tone curve, HSL) exported as 8-bit sRGB at 480p short side, plus the full-resolution master and the slider/XMP history.

**Size, cost and time (rough orders of magnitude, not quotes):**
- **Images needed.** The paper uses 4,500 pairs. Usable models are likely with 2,000–3,000 pairs plus augmentation, and better with 5,000.
- **Retouching effort.** A global-only edit takes about 1–3 minutes per image, so 3,000–5,000 images is roughly 50–250 hours.
- **Retouching cost.** About US$2k–15k at freelance rates (~$25–60/h) or bulk editing-service pricing (~$0.5–3 per image).
- **Photo cost.** $0 for Unsplash Lite (if counsel agrees) or our own shoots; an unknown agency fee otherwise.
- **Calendar time.** About 4–10 weeks including style-guide iteration and QA. Training itself is days (§4e).

**Pros:**
- Same architecture and our existing port.
- Clean, documented chain of title.
- The look is ours and can be tuned.

**Cons:**
- Retoucher cost and time.
- Need for a QA loop.
- Unsplash Lite inputs are already "finished", so they need deliberate flattening; see the hybrid with 4b.

### 4b. Self-supervised / synthetic degradation
- **Method.** Take licensed, well-exposed images (Unsplash Lite, own photos). Apply random global degradations: exposure ±EV, WB/tint shifts, contrast and gamma changes, saturation changes, and mild tone-curve flattening. Train the model to map degraded images back to the originals.
- **Pros:**
  - Data cost is near zero.
  - Unlimited pairs.
  - Fast (1–2 weeks of engineering).
  - The 3D-LUT model's global, monotonic-regularised structure suits global degradations well.
- **Cons and quality risk:**
  - It learns to *undo our degradation distribution*, not *expert taste*.
  - On already-good photos it may do nearly nothing, or regress towards the "average stock photo" look.
  - Its corrections are bounded by how realistic the degradation model is. Real camera failures (mixed lighting, clipped highlights, phone HDR tone mapping) differ from synthetic shifts.
  - Stock "originals" are not neutral ground truth; they carry each photographer's own grading.
- **Best use.** Pretrain with 4b, then fine-tune on a smaller 4a set (500–1,500 retoucher pairs). This hybrid is likely the best quality per dollar.

### 4c. Commercial licence for FiveK from Adobe/MIT
- **No documented channel.**
  - The licence says it is the "entire agreement".
  - The site offers only research licences and a Google Group (`fivek-dataset`).
  - Searches found no record of a commercial licence ever being offered.
- **Possible contacts:** Adobe Research (dataset authors Paris, Chan), MIT CSAIL / Prof. Durand, or the MIT Technology Licensing Office.
- **Obstacle:** Adobe and MIT may not hold rights from the contributing photographers that would let them grant commercial use at all. That is not verified.
- **Verdict:** low probability, slow (months), and outside our control. It is reasonable to send one email, but do not plan around it.

### 4d. Other paired retouching datasets
Checked. **None verified as commercially usable:**
| Dataset | Terms | Commercial? |
|---|---|---|
| PPR10K (portraits, 3 experts) | "available for non-commercial research purposes only", covering "any portion of derived data" | No |
| FFHQR (Skylab retouched FFHQ faces) | CC BY-NC-SA 4.0; underlying FFHQ images include BY-NC | No |
| INRetouch PRD (~100k preset edits) | Built on FiveK images, so it inherits the FiveK restriction even though its presets are CC | No |
| HDR+ | CC BY-SA 4.0 (see §2.3) | Possibly, but with ShareAlike uncertainty and a camera-pipeline domain. Counsel question. |
| LOL, SICE and other low-light sets | Not checked in detail; generally research-only and a different task | Not verified, so not assumed |

I found no genuinely commercial-licensed expert-retouch paired dataset. Treat 4a/4b as the only clean routes.

### 4e. Training compute estimate
**Figures from the code:**
- Paired training: `n_epochs=400`, `batch_size=1`, `lr=1e-4`, 4,500 images, which is about **1.8M iterations**.
- Unpaired training: 800 epochs × 2,250, also about 1.8M iterations, each with a WGAN-GP critic step (`n_critic=1`), so roughly 2–3× the cost per iteration.
- Model: 270,083 parameters (classifier) plus 3 × 3 × 33³ LUT entries.
- The paper reports inference time but not training time.

**Estimate (not measured):**
- On a current datacentre GPU (L4, A10G, A100 class), the forward and backward pass is a few milliseconds.
- Upstream's `n_cpu=1` PIL JPEG decode and augmentation dominate, at around 10–30 ms per iteration. That gives about **5–15 GPU-hours per paired run** as written, or **~1–3 h** with multiple loader workers or pre-decoded tensors.
- Batch size >1 with gradient-equivalent LR scaling is a further easy speed-up. It needs validation.

**Cloud cost:**
- Assumes roughly $0.5–2 per GPU-hour on-demand for that class. These are typical public list prices and were not re-verified today.
- That is about **$1–30 per run**. A 20–50-run sweep comes to **under ~$1,000**. An Apple-silicon Mac (MPS) is also viable for experiments.

**Conclusion:** compute is negligible. Data (retoucher time) and evaluation are the real costs.

### Note on our evaluation photos
- `experiments/lut3d/photos/MANIFEST.csv` lists 22 Unsplash images; no Pexels images are present despite the plan.
- They must **not** be used for training.
- Running a model on them for internal evaluation is a grey area under Terms §8's "in connection with any machine learning … datasets" wording. The literal text could be read to cover evaluation sets.
- Low practical risk, but for publishable or marketing comparisons, prefer our own photos.

---

## 5. Bundled preset library (second, more urgent issue)

**Facts from `ios/Lightly/Resources/Presets/presets_photo.json`** (`version 1.0`, `totalCount 3157`, `freeTierCount 10`). Each entry holds the full numeric recipe (sliders, tone curves, HSL, colour grading), a display name, and an `originPath` naming the source pack.

Distinct top-level packs (first path component of `originPath`):
| Pack (vendor) | Presets | Sub-archives (examples) |
|---|---|---|
| WithLuke studios (Luke Stackpoole / WithLuke Studios) | 1,174 | `Master Lightroom Presets Collection/…` |
| SolutionPresets | 829 | `Presets for Desktop (Windows&Mac)(1).zip` 397, `Presets for iPhone(2).zip` 230, `Presets for Windows and Mac.zip` 53, `Influencer Bundle XMP…` 49, `Cinematic Presets - Desktop.zip` 25, and others |
| The Ultimate Preset Bundle – Huliluts | 788 | `The Ultimate Preset Bundle - Huliluts.zip` 577, `New Update … Huliluts.zip` 140, `… 20.5.2026.zip` 60, `Analog Film V2.zip` 11 |
| WithLuke – Master Collection | 366 | `WithLuke - Master Collection.zip` 250, `WithLuke - Desktop Presets` 116 |
| **Total** | **3,157** | WithLuke combined 1,540 (48.8%) |

- **All 10 free-tier presets are WithLuke presets** (9 from Master Collection, 1 from WithLuke studios).
- `luts_video.json` (1,742 entries) has the same origin problem: Huliluts 1,386 and WithLuke studios 356. For now it contains metadata only (hash, size, `originPath`), and no `.cube` files are bundled in `ios/Lightly/`.
- Some preset names are third-party trademarks or titles (e.g. "Batman", "Euphoria"). That is a separate trademark and naming concern.
- The vendor names themselves ship inside the app bundle via `originPath`.

**Contradiction with the product spec.** `docs/lightly_product_technical_spec_v1.1.md` (lines 29, 103, 376) states the bundled presets are "owned by Lightly Labs / the founders", with no third-party packs, and that licensing is "not a blocker". The `originPath` data contradicts this unless the founders own WithLuke Studios, SolutionPresets and Huliluts, which I cannot verify and consider unlikely. **This needs an internal answer first.**

**Vendor terms found (fetched 2026-10-01):**
- **Huliluts** ([File Licenses](https://huliluts.com/pages/file-licenses)): explicit and prohibitive.
  - The licence is "non-exclusive, non-transferable", for one seat on up to two computers.
  - The page states: "You may not incorporate or distribute the actions or presets within an End Product." It allows only linking users to where they can buy the presets.
  - Oddity: the page text names "Cafiraforest" in places. It looks like a template, which slightly weakens its quality as evidence but not its plain meaning.
  - **Bundling 788 Huliluts presets (and 1,386 LUT entries) in a paid app conflicts directly with this licence.**
- **WithLuke Studios** ([withlukestudios.com/policies/terms-of-service](https://withlukestudios.com/policies/terms-of-service)): I found no preset-specific licence page.
  - The ToS is generic Shopify boilerplate: you may not "reproduce, duplicate, copy, sell, resell or exploit any portion of the Service".
  - That clause targets the "Service", not obviously the purchased files, so it is weak evidence either way.
  - No licence was found granting redistribution. Absent a grant, the default is no redistribution right.
  - The original ZIPs may contain a licence or README, but they are not in this repo, so I could not check.
- **SolutionPresets** ([solutionpresets.com/policies/terms-of-service](https://solutionpresets.com/policies/terms-of-service)): the same Shopify boilerplate, with no preset-specific licence found. Same conclusion as WithLuke.
- General market practice for paid presets is end-user use only, with no resale or redistribution. Every licence surfaced in searches said so; none of those were these vendors.

**Does converting XMP to our JSON "recipe" format avoid the issue? Probably not, and do not rely on it.**
- Whether a set of slider values is copyrightable is genuinely uncertain. It could be argued to be functional parameters or facts, and the answer varies by jurisdiction.
- But the purchase licences are **contracts** binding whoever bought the packs. Huliluts forbids incorporating "the presets" in an end product, regardless of file format.
- We also kept the vendors' names and preset names, which makes the derivation obvious.
- How the packs were obtained matters too (direct purchase, or a third-party "mega-bundle" reseller). That is unknown.

**Conclusion (distribution only; engineering work is not gated on this):**
- **Huliluts.** Its published terms prohibit incorporation in an end product, so do not distribute Huliluts-derived presets without a written licence.
- **WithLuke and SolutionPresets.** Their terms are unverified, and this note does not claim that distribution is prohibited. Obtain written confirmation from each vendor.

Options:
1. Before an external build that includes them, confirm terms per vendor. Exclude any pack whose terms prohibit or don't permit bundling.
2. Rebuild the library from first-party presets: ones the founders create, or ones made by contractors under IP assignment, possibly designed with the same retoucher as 4a.
3. Optionally, approach the vendors (e.g. WithLuke, whose presets fill the free tier) for a paid, written bundling licence.
4. Drop `originPath` vendor strings from shipped data either way.

---

## Recommendation

1. **Do not ship the upstream FiveK-trained weights**, or our Core ML / ONNX / LUT conversions of them, in any paid or public build. Keep them for research benchmarking only (they are already git-ignored), and label them in `MODEL_CARD.json` as "research-only, FiveK-derived".
2. **Keep the architecture and our port.** Ship it with Apache-2.0 attribution in About → Licences. Do not port `ssim.m`. Do not depend on `torchvision_x_functional.py`; if it is ever reused, add TorchSat's MIT notice.
3. **Retrain with the hybrid of 4b and 4a:**
   - (i) Pretrain on synthetic degradations of licensed images. Use own photos plus the Unsplash Lite Dataset if counsel confirms "internal business purposes" covers a shipped model.
   - (ii) Fine-tune on 1,000–3,000 pairs edited by one contracted retoucher under a written IP assignment that explicitly allows ML training and commercial deployment.
   - (iii) Build the evaluation set from our own photos.
   - Expected cost: ~$3k–15k (mostly retoucher time), 6–10 weeks elapsed. Compute is negligible.
   - **Why this path:** it is the only path with a clean, documentable chain of rights. It reuses all existing engineering, and it gives Lightly an owned "house look" instead of FiveK expert C's.
4. **Interim:** if auto-enhance must exist before the retrain lands, ship a deterministic, non-learned auto-adjust (histogram and white-balance heuristics), not the FiveK model.
5. **Presets (distribution, per vendor):**
   - Huliluts terms prohibit bundling.
   - WithLuke and SolutionPresets terms are unverified, so get written confirmation.
   - Reconcile the spec's "first-party only" statement.
   - Internal conversion and evaluation proceed independently.
6. **Freedom-to-operate:** one co-author (Z. Cao) is at DJI. A search-engine summary claimed the paper is "associated with a PCT patent". I could **not** verify this on PolyU's page or the paper, and I found no patent number. Apache-2.0's patent grant (§3) covers only contributor-held patents embodied in the contribution; it would not cover a DJI- or PolyU-held patent. Ask counsel to run a short FTO search.

## Open questions for counsel

1. **FiveK-derived weights.** Under the laws of our launch markets (at least US, EU/UK, India), could distributing models trained on FiveK expert-C retouches expose us, given that (a) we never agreed to the FiveK licence and (b) the weights were published under Apache-2.0 by someone bound by FiveK's research-only contract? (We are not planning to rely on this; the answer informs how strictly we quarantine research artefacts.)
2. **Unsplash Lite Dataset §2A.** Does "internally use … to train machine learning models … for your internal business purposes" permit shipping the trained model (weights embedded in a paid app)? What does the §9 indemnity mean for us?
3. **Unsplash Terms §8.** Does running models on Unsplash-licensed photos for internal evaluation fall under "in connection with any machine learning … datasets"?
4. **HDR+ (CC BY-SA 4.0).** Would weights trained on it be "Adapted Material" requiring ShareAlike? Is it usable as supplementary data with attribution?
5. **Retoucher contract.** What wording is needed for: copyright assignment or work-for-hire for the edits; an explicit licence to train and commercially deploy models; moral-rights waiver; and model and property releases for any identifiable people in commissioned photos? Are there GDPR considerations for training on identifiable people?
6. **Presets.** Are numeric preset parameters protectable in our markets? Separately, does the purchase contract (Huliluts' explicit clause; WithLuke and SolutionPresets' unknown in-ZIP terms) bar our re-encoded bundling regardless? What exposure exists if any build with these presets has already been distributed (TestFlight, Play internal testing)?
7. **Patents.** Run an FTO search on image-adaptive multi-basis 3D LUT enhancement (PolyU, DJI, others) for our launch markets.
8. **Attribution format.** Confirm the Apache-2.0 attribution format for the in-app Licences screen, and whether an Apache-licensed reimplementation needs the §4(b) "modified files" notices if we never redistribute source.

## Sources
Retrieved 2026-10-01 unless stated.

- Upstream repo (pinned): https://github.com/HuiZeng/Image-Adaptive-3DLUT/tree/b491f6df64a588864739a157db271e5c848e1805 (local clone `experiments/lut3d/reference/upstream`)
- Issue #42 "License": https://github.com/HuiZeng/Image-Adaptive-3DLUT/issues/42
- PR #53 "Create LICENSE": https://github.com/HuiZeng/Image-Adaptive-3DLUT/pull/53
- Issue #65 (training data of pretrained models, unanswered): https://github.com/HuiZeng/Image-Adaptive-3DLUT/issues/65
- Issue #10 (unpaired models retrained with released code): https://github.com/HuiZeng/Image-Adaptive-3DLUT/issues/10
- Issue #51 (only "commercial" hit, technical): https://github.com/HuiZeng/Image-Adaptive-3DLUT/issues/51
- Paper (TPAMI 2022): https://www4.comp.polyu.edu.hk/~cslzhang/paper/PAMI_LUT.pdf; arXiv https://arxiv.org/abs/2009.14468
- Apache License 2.0: https://www.apache.org/licenses/LICENSE-2.0.txt
- TorchSat (origin of `torchvision_x_functional.py`, MIT): https://github.com/sshuair/torchsat; PyPI `torchvision-enhance`: https://pypi.org/project/torchvision-enhance/
- MIT-Adobe FiveK: https://data.csail.mit.edu/graphics/fivek/
  - https://data.csail.mit.edu/graphics/fivek/legal/LicenseAdobe.txt
  - https://data.csail.mit.edu/graphics/fivek/legal/LicenseAdobeMIT.txt
  - https://data.csail.mit.edu/graphics/fivek/legal/filesAdobe.txt
  - https://data.csail.mit.edu/graphics/fivek/legal/filesAdobeMIT.txt
- FiveK Google Group: https://groups.google.com/g/fivek-dataset
- HDR+ dataset: https://hdrplusdata.org/dataset.html
- PPR10K: https://github.com/csjliang/PPR10K
- FFHQR: https://github.com/skylab-tech/ffhqr-dataset
- INRetouch: https://arxiv.org/html/2412.03848
- Unsplash License: https://unsplash.com/license
- Unsplash Terms: https://unsplash.com/terms
- Unsplash API Terms: https://unsplash.com/api-terms
- Unsplash data: https://unsplash.com/data
- Unsplash Dataset Terms: https://github.com/unsplash/datasets/blob/master/TERMS.md
- Pexels License: https://www.pexels.com/license/
- Pexels Terms (last updated 2024-11-15): https://www.pexels.com/terms-of-service/
- Huliluts File Licenses: https://huliluts.com/pages/file-licenses
- Huliluts ToS: https://huliluts.com/policies/terms-of-service
- WithLuke Studios ToS: https://withlukestudios.com/policies/terms-of-service
- WithLuke site: https://www.withluke.com/
- SolutionPresets ToS: https://solutionpresets.com/policies/terms-of-service
- PolyU publication page (no patent listed): https://research.polyu.edu.hk/en/publications/learning-image-adaptive-3d-lookup-tables-for-high-performance-pho/

**Method notes:**
- Unsplash and Pexels pages block direct `curl`. Their clauses were read through a fetch tool that summarises pages, so treat the quoted wording as near-verbatim and re-check it before relying on it in a contract.
- FiveK licence texts, Unsplash Dataset Terms (GitHub), PPR10K, FFHQR and Huliluts licence text were read verbatim.
