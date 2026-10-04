# Lightly 1.0: third-party terms register

> **DRAFT FOR REVIEW. NOT LEGAL ADVICE.** This register records what the sources say and what the apps actually ship. Questions marked "counsel" need a lawyer; questions marked "owner" need a product-owner decision.
>
> Web sources were accessed on **2026-10-04** unless another date is given. Quotes are kept to 15 words or fewer. Where a page could not be fetched today, the entry says so and points to the earlier record in this repository.

## What each build actually ships (verified in code, 2026-10-04)

| Item | iOS Debug | iOS Release | Android debug | Android release | Where this is decided |
|---|---|---|---|---|---|
| Depth Anything V2 Small | bundled | only if `LIGHTLY_DEPTH_MODEL_TRAINING_DATA_SIGNED_OFF=YES` (now `NO`) | bundled when the local file exists | only with `-PlightlyDepthLegalSignOff=true` | `ios/project.yml`, `ios/Tools/bundle_depth_model.sh`, `android/app/build.gradle.kts` |
| LaMa big-lama | bundled | only if `LIGHTLY_REMOVE_MODEL_TRAINING_DATA_SIGNED_OFF=YES` (now `NO`) | bundled when the local file exists | only with `-PlightlyRemoveLegalSignOff=true` | same files, `bundle_remove_model.sh` |
| MediaPipe or ML Kit | n/a | n/a | **not a dependency** | **not a dependency** | `SubjectSegmenter.kt` and `EditorModels.kt` are stubs (D3); only `experiments/android-vision/` uses them |
| Apple Vision | system framework | system framework | n/a | n/a | `SceneAnalysis.swift`, `PersonDetector.swift` |
| LiteRT 1.4.2 | n/a | n/a | yes | yes | `android/gradle/libs.versions.toml` |
| Four OFL fonts and their licence files | yes | yes | yes | yes | `ios/project.yml`, `BundleWatermarkFontsTask` |
| Four Unsplash background photos and thumbnails | yes | **yes (no gate)** | yes | **no** (debug only) | `ios/project.yml`; `build.gradle.kts`, `variant.buildType == "debug"` |
| Prototype or test photos | no | no | no | no | nothing under `ios/Lightly` or `android/app/src/main` is a photo; the test fixtures are in test targets only |
| Develop catalogue `presets/develop-design-ui.json` (2,591 names) | yes | yes | yes | yes | `ios/project.yml`, `BundlePresetCatalogueTask` |
| Look pack `shared/look-pack/out/manifest.json` (2,591 recipes derived from the source presets) | yes | yes | yes | yes | `scripts/bundle_look_pack.sh`, `BundleLookPackTask` |
| `ios/Lightly/Resources/Presets/presets_photo.json` (7.0 MB, 3,157 recipes) and `luts_video.json` (1,742 entries) | yes | **yes** | n/a | n/a | everything under `ios/Lightly/` is a resource; both files carry an `originPath` that names the vendor pack |

---

## 1. Depth Anything V2 Small (iOS Core ML, Android LiteRT)

**What ships.**
- iOS: Apple's Core ML package `DepthAnythingV2SmallF16P8.mlpackage`, from https://huggingface.co/apple/coreml-depth-anything-v2-small @ `cfef6f6f…`. The weights SHA-256 is recorded in `ios/Tools/bundle_depth_model.sh`.
- Android: our own LiteRT conversion `da2_small_518x392_wi8.tflite`, made from https://huggingface.co/depth-anything/Depth-Anything-V2-Small-hf @ `5426e4f` (SHA-256 `8e719085…8078`).

| Layer | Finding | Source |
|---|---|---|
| Code | Apache-2.0. | https://github.com/DepthAnything/Depth-Anything-V2 (LICENSE section) |
| Weights | Apache-2.0 for Small only. The repo says "Depth-Anything-V2-Small model is under the Apache-2.0 license." Base, Large and Giant are "under the CC-BY-NC-4.0 license". Apple's Core ML repackaging is also tagged `apache-2.0`. | same; https://huggingface.co/depth-anything/Depth-Anything-V2-Small-hf; https://huggingface.co/apple/coreml-depth-anything-v2-small |
| Training data | The model card describes "595K synthetic labeled images and 62M+ real unlabeled images". Paper Table 7 (recorded in `docs/v1/depth-evaluation.md` §Licences) gives the sets. **Synthetic** (the teacher's labels): BlendedMVS, Hypersim, IRS, TartanAir, VKITTI 2. **Pseudo-labelled real** (the student): BDD100K, Google Landmarks, ImageNet-21K, LSUN, Objects365, Open Images V7, Places365, SA-1B. | https://huggingface.co/depth-anything/Depth-Anything-V2-Small-hf; https://arxiv.org/abs/2406.09414 |
| Identifiable people | Real sets contain people. SA-1B: "Faces and license plates de-identified". The model outputs only a per-pixel depth map. It produces no identity, landmarks or biometric template. | https://ai.meta.com/datasets/segment-anything/ |

**Dataset terms checked today.**

| Dataset | Terms (quote) | Source |
|---|---|---|
| SA-1B | "Research purposes only"; licence "Limited; see full license language". The full SA-1B licence sits behind Meta's download click-through and could not be retrieved today. | https://ai.meta.com/datasets/segment-anything/; https://ai.meta.com/datasets/segment-anything-downloads/ (the body was not readable) |
| ImageNet (applies to ImageNet-21K) | "only for non-commercial research and educational purposes." | https://www.image-net.org/download.php |
| BDD100K | Use "for educational, research, and not-for-profit purposes"; commercial rights go to BDD/BAIR members. Taken from search results; the primary page did not resolve today. | https://doc.bdd100k.com/license.html (DNS failure); search summary |
| Virtual KITTI 2 | "may be used for non-commercial purposes only" (CC BY-NC-SA 3.0). | https://europe.naverlabs.com/research/computer-vision/proxy-virtual-worlds-vkitti-2/ |
| Hypersim | CC BY-SA 3.0 Unported (images). | https://github.com/apple/ml-hypersim |
| Places365 | See item 2. | |
| Open Images V7 | Images are listed as CC BY 2.0 (recorded in `docs/v1/auto-data.md` §1.1). | https://storage.googleapis.com/openimages/web/factsfigures_v7.html |
| Google Landmarks, LSUN, Objects365, TartanAir, BlendedMVS, IRS | **Not checked today.** | — |

**Do the dataset terms bind users of the weights?**
- Dataset terms of use are agreements between the dataset host and **whoever downloaded the data**: here, the Depth Anything authors (and, for SA-1B, Meta's click-through). Lightly downloaded none of these datasets and accepted none of these terms. On their face they impose no contractual obligation on Lightly.
- Two questions remain open, and only counsel can answer them:
  1. Whether trained weights are an adaptation of the training images. If they are, the ShareAlike sets (Hypersim, VKITTI 2) and the NC sets would reach the weights through copyright, not contract. The law is unsettled, and differs between the US, EU and UK.
  2. Whether the authors had the right to license the Small weights as Apache-2.0, given that their teacher was trained on synthetic data (Hypersim, VKITTI 2) and the student on research-only real images. Apple's and Qualcomm's commercial redistribution under Apache-2.0 is evidence of industry practice, not a legal clearance.
- **Apache-2.0 obligations for us:**
  - ship the licence text;
  - keep the copyright and attribution notices;
  - state in the Android file's notice that we changed it (conversion to LiteRT with int8 weights; §4(b)).
  - Apple's palettised package is also a modified work. Its notice comes from Apple's repo.

**Risk.** Medium-low. No known claim has been made against Apache-licensed DA-V2-Small users, but this is a live area of law, and the NC/SA sets are upstream. Without the model, release builds show the approved failure state for every photo without embedded depth.

**Resolution options.**
- A. Accept with counsel's one-line sign-off. Ship the Apache-2.0 notice and a training-data note (see "Notices" below). Flip the two gates. *(Recommended in `depth-evaluation.md` T1.)*
- B. Ship 1.0 without the model: embedded depth only (the release gate stays off).
- C. Train or commission a model on licensed data (a paid commitment; not started).

## 2. LaMa big-lama (Edit › Remove)

**What ships.**
- Weights: `big-lama.zip` from the README-linked mirror https://huggingface.co/smartywu/big-lama @ `05cb2be7` (SHA-256 `f1b358ca…75f6`).
- iOS: converted to Core ML fp16. Android: converted to LiteRT fp32.

| Layer | Finding | Source |
|---|---|---|
| Code | Apache-2.0, "Copyright [2021] Samsung Research". | https://github.com/advimman/lama/blob/main/LICENSE |
| Weights | No separate weights licence upstream. The repo licence covers the release, and the mirror's card says `license: apache-2.0`. The mirror is not a Samsung account. | `docs/v1/remove-evaluation.md` §2; the mirror card |
| Training data | Places-Challenge / Places2. The Places2 download page (recorded 2019 terms) says: "only for non-commercial research and educational purposes" and "You will NOT distribute the above images." **Not re-verified today:** places2.csail.mit.edu and places.csail.mit.edu refused the connection. The Places365 repo states: "The copyright of all the images belongs to the image owners." The Places team itself licenses its own Places-trained CNNs as "Creative Common License (Attribution CC BY)". | `docs/v1/remove-evaluation.md` §2 note; https://github.com/CSAILVision/places365 |
| Identifiable people | Places images are scenes, but people do appear in them. The model fills masked pixels. It detects and identifies no one. | — |

**Does the weights' licence grant resolve the Places terms?**
- Partly.
  - The Places terms bind the downloader (the LaMa authors), not Lightly.
  - The Places team licenses its own trained models under CC BY. That shows the dataset owners treat trained models as licensable by whoever trained them.
- But the image copyrights belong to their owners. The Apache grant from Samsung Research can license only Samsung's rights in the weights, not any rights an image owner might have in a model trained on the images. The legal question is the same as in item 1.
- **Provenance (verified by engineering, 2026-10-04):**
  - The official repository's README (github.com/advimman/lama, `README.md` on `main`) names `curl -LJO https://huggingface.co/smartywu/big-lama/resolve/main/big-lama.zip` as the primary download. The "All yandex dist links went bad" note points to a Google Drive folder as the alternative.
  - Hugging Face's LFS record for `big-lama.zip` at revision `05cb2be7f8dbe6ca7c6e78f4fc827a4b2baaa4a9` (repository licence tag `apache-2.0`) gives SHA-256 `f1b358ca24093b93a106183b98a3dea6e8ed09f3b43ea7251eb2c81e7b4575f6`, 381,428,720 bytes. That is identical to our download (`experiments/inpaint/fetch_models.sh`).
  - Our weights are therefore byte-identical to the file the official README directs users to.
  - **Residual gap:** the authors publish no checksum of their own, so the chain of trust runs through the README link to the Hugging Face repository.
  - **Recommended resolution:** accept this provenance, pin revision `05cb2be7` (already done), and record the README link and LFS hash in the shipped notices. Optional cross-check: compare against the Google Drive copy linked from the same README.

**Risk.** Medium-low; the same class of risk as item 1. Every pretrained inpainting model we evaluated has the same Places2 lineage (`remove-evaluation.md` §8).

**Resolution options.**
- A. Counsel's sign-off, then flip the gates. Ship the Apache-2.0 notice and state that the files were converted. Optionally confirm the weights' hash against the official release link in the LaMa README (the Yandex Disk or Samsung download).
- B. Ship 1.0 with Remove showing its approved failure state (the gate stays off).
- C. Train on licensed data (paid; not started).

## 3. MediaPipe (Android face detection, landmarks and segmentation): not in 1.0 today

**Status in code.**
- No MediaPipe or ML Kit dependency exists in `android/`. Subject segmentation and face detection are stubs (D3).
- Portrait is debug-only. In release, Background works from depth alone, and Change background and Refine edges show the approved failure state.
- The models live only in `experiments/android-vision/models/` (MODELS.csv).

| Model | Licence (model card) | Training data (model card) | Card |
|---|---|---|---|
| Selfie segmenter (square and landscape) | "Apache License, Version 2.0" (card dated May 6, 2021) | "consented images of people using a mobile AR application"; geographically balanced over 17 regions; skin tone and gender evaluated | https://storage.googleapis.com/mediapipe-assets/Model%20Card%20MediaPipe%20Selfie%20Segmentation.pdf |
| BlazeFace short range | "Apache License, Version 2.0" (June 9, 2021) | "trained and evaluated on consented images of people"; out of scope: "Any form of surveillance or identity recognition" | https://storage.googleapis.com/mediapipe-assets/MediaPipe%20BlazeFace%20Model%20Card%20(Short%20Range).pdf |
| BlazeFace full range | Apache-2.0 per MODELS.csv | card not re-read today | https://storage.googleapis.com/mediapipe-assets/MediaPipe%20BlazeFace%20Model%20Card%20(Full%20Range).pdf |
| Face landmarker (`face_landmarker.task`) | Apache-2.0 per MODELS.csv | card not re-read today | https://storage.googleapis.com/mediapipe-assets/Model%20Card%20MediaPipe%20Face%20Mesh%20V2.pdf |
| Multiclass selfie, hair | Apache-2.0 per MODELS.csv | not re-read today | links in MODELS.csv |
| DeepLab v3 | **unverified** (no model card) | — | — |

**Findings that matter for release.**
- **Telemetry.** The merged manifests of the evaluation harness show Google `datatransport` (Firelog) components for **all three** candidates, MediaPipe Tasks Vision 1.0.0 included: `CctBackendFactory`, `JobInfoSchedulerService` and `AlarmManagerSchedulerBroadcastReceiver` (`experiments/android-vision/VisionEval/app/build/intermediates/merged_manifest/*Release/`).
  - The app's `verify<Variant>ManifestPrivacy` task fails the build on `datatransport`. Adding MediaPipe as it stands would fail the build.
  - The harness gets offline behaviour only by stripping `INTERNET` (`experiments/android-vision/README.md`).
- **ML Kit** terms say "The ML Kit APIs also send metrics about the performance and utilization". They also make the developer "responsible for informing users", https://developers.google.com/ml-kit/terms. This contradicts the privacy draft's "no data leaves the device".
- ML Kit Subject Segmentation is unbundled: Google Play services downloads it at runtime.

**Risk.** Licence: low (Apache-2.0, consented training data per the cards). Privacy: **high if the SDK is added unchanged**, because telemetry would contradict the privacy policy and both store labels.

**Resolution options (owner, at D3).**
- A. MediaPipe with the datatransport components removed through `tools:node="remove"` and no `INTERNET` permission. Prove with a network-off device test that nothing breaks, and keep the manifest check.
- B. Run the `.tflite` models directly on LiteRT (already approved), without the MediaPipe Tasks runtime. No new SDK and no telemetry, but we write the pre- and post-processing ourselves.
- C. ML Kit: requires disclosing Google's metrics collection, and changing the privacy policy and both store answers. **Not recommended.**

## 4. Apple Vision framework (iOS)

**What ships.**
- No model file. The app calls system requests: `VNDetectFaceRectanglesRequest`, `VNDetectFaceLandmarksRequest`, `VNDetectFaceCaptureQualityRequest`, `VNDetectHumanRectanglesRequest`, `VNGeneratePersonSegmentationRequest` and `VNGenerateForegroundInstanceMaskRequest`.
- These run in `SceneAnalysis.swift` and `PersonDetector.swift`.

**Terms.**
- Vision is part of the iOS SDK. No separate licence or click-through applies. It is covered by the Apple Developer Program License Agreement (DPLA), https://developer.apple.com/support/terms/apple-developer-program-license-agreement/.
- The DPLA has terms that **do** apply, because face landmarks are "Face Data" under §3.3.3(K). That definition includes "facial coordinates or facial landmark data". As extracted today, the obligations include:
  - "You may not sell Face Data."
  - "You may not transfer Face Data off-device without express prior written consent".
  - You must disclose in your privacy policy how you "collect, use, and share Face Data".
  - Re-read the clause in full before submission. The text came through a fetch tool.
- App Review Guideline 5.1.2(vi): data from "facial mapping tools" may not be used for marketing or data mining, https://developer.apple.com/app-store/review/guidelines/.

**Lightly's behaviour.**
- Faces are used only for Portrait and Background.
- Nothing leaves the device.
- **Correction to the earlier privacy draft:** while an edit has unsaved changes, face boxes and landmark polygons are **written to disk** as part of the restore record:
  - `PersistedAnalysis.people` in `Application Support/EditSession`;
  - files protected until first unlock and excluded from backup;
  - deleted when the edit is saved, discarded or closed, or when another photo is opened.
- The privacy draft now says so.

**Status: clear**, provided the privacy policy carries the Face Data disclosure (it does in the updated draft).

## 5. LiteRT `com.google.ai.edge.litert:litert:1.4.2` (+ `litert-api:1.4.2`)

- **Licence:** Apache-2.0 in both POMs (recorded with AAR hashes in `docs/v1/slice3-android.md` §LiteRT). Today's fetch of the Maven Central POM returned 404: the artifact is served from Google Maven (`maven.google.com`), not Central.
- **Manifest:** 1.4.2 declares no permissions. The manifest check passes in debug and release with nothing removed.
- **Obligations:** ship the Apache-2.0 text and the NOTICE (if the AAR carries one) in the app's notices.
- **Status: clear** (obligation: notices).

## 6. Bundled fonts: Allura, Cormorant Garamond, Inter, Caveat (SIL OFL 1.1)

- **Source:** github.com/google/fonts `ofl/*` (`shared/fonts/README.md`). SHA-256 values are in `shared/fonts/SHA256SUMS`.
- **OFL condition 1:** "may be sold by itself" is forbidden. Bundling in a paid app is allowed. https://openfontlicense.org/open-font-license-official-text/
- **OFL condition 2:** fonts may be bundled with software "provided that each copy contains the above copyright notice and this license". Both apps copy the four `*-OFL.txt` files into the bundle or assets (`ios/project.yml`, `BundleWatermarkFontsTask`). **Condition met.**
- **Reserved names:** apply only to modified fonts. We ship the files unmodified.
- **Terms of Use alignment:** the terms draft must not grant users rights in the fonts beyond the OFL. It says the fonts may not be extracted and resold as a separate product, which matches condition 1. It must not restrict the OFL freedoms of anyone who receives the font files. *(Counsel to confirm the wording.)*
- **Status: clear.**

## 7. The four bundled background photos (Unsplash License)

**Files and sources** (`docs/ui/assets/photos/SOURCES.csv`). Each has a `_thumb` from the same source.

| File | Photo page | Photographer | People? |
|---|---|---|---|
| `landscape_01.jpg` | https://unsplash.com/photos/seceda-mountains-in-ortisei-italy-hOhlYhAiizc | Daniela Kokina | none |
| `sunset_03.jpg` | https://unsplash.com/photos/low-sun-over-calm-ocean-AksmkMQTdik | Martin Franco | none |
| `wellexposed_02.jpg` | https://unsplash.com/photos/a-street-with-houses-and-trees-on-both-sides-rlxo_XrKb6k | Mykyta Kravčenko | none visible; houses and road signs |
| `backlit_02.jpg` | https://unsplash.com/photos/a-woman-standing-in-a-field-looking-at-the-sun-9nmReTKwQ3U | Alice Kotlyarenko | one woman, seen **from behind**, face not visible, plus a horse |

**Licence** (https://unsplash.com/license; https://unsplash.com/terms):
- **Grant:** a licence to "copy, modify, distribute, perform, and use images ... including for commercial purposes". Bundling in an app is within the grant.
- **Restrictions:**
  - Images "cannot be sold without significant modification".
  - No "compiling images from Unsplash to replicate a similar or competing service".
  - Four photos offered as backgrounds inside an editor neither sell the photos nor replicate a photo service. Counsel should confirm, but the risk is low.
- **Attribution:** not required, though "photographers appreciate it". It is customary. The suggested form is "Photo by [name] on Unsplash".
- **People:**
  - Terms §5 excludes "People's images if they are recognizable in the Images".
  - Unsplash gives no warranty (§15) and provides no model releases.
  - In `backlit_02` the person is not recognisable from the face, but she may still be recognisable to people who know her (figure, clothing, place).
  - Our use (a decorative background, no endorsement, nothing sensitive) is the kind usually done without a release. A release is not obtainable through Unsplash.
- **ML clause:** Terms §8 bars use "in connection with any machine learning and/or artificial intelligence datasets". Bundling a photo as a background is not that. But the same photo set is used for model evaluation in `experiments/` (see `docs/v1/auto-data.md`, which already flags this for counsel).

**Platform inconsistency (owner).** iOS bundles all four in **release** builds with no gate. Android packages them in **debug only** "until the licence is confirmed" (`build.gradle.kts`). The two platforms must not diverge.

**Resolution options (owner).**
- A. Accept the Unsplash License for all four. Credit the photographers in the Notices (customary). Ungate on Android.
- B. As A, but replace `backlit_02` with a no-people photo. **This changes the approved UX** (the bundled set is in `docs/ui/app/data.js`), so it needs explicit approval.
- C. Gate iOS release too, until counsel confirms. The approved row would then show no bundled photos on either platform.

## 8. Prototype sample photos

- **Release bundles contain none.**
  - Nothing under `ios/Lightly/` or `android/app/src/main/` is a photo.
  - `ios/project.yml` copies only the four backgrounds (item 7).
  - Android's asset tasks copy fonts, the catalogue, the look pack, gated models and (debug only) the backgrounds.
- **Test fixtures only:**
  - `ios/Tests/Fixtures/SubjectMattes/*.png`: mattes derived from Unsplash test photos.
  - `experiments/test-photos/` (`group_three_01.jpg`, Unsplash, three identifiable people).
  - These are in test targets and experiments, never in the app.
- **Status: clear.** Keep it that way: `docs/ui/assets/photos/` holds 20+ photos, including identifiable portraits, and must not be added to app resources.

## 9. Preset catalogue (`presets/`): provenance **unclear and a release blocker**

**What the repo says.**
- `presets/README.md`: the library holds 6,033 assets "copied from `/Users/sg/Downloads/Presets - for lightly`". The design catalogue (`develop-design-ui.json`, 2,591 presets) was selected from these, with "editorial membership proposed by Codex".

**Who authored the shipped presets** (traced on 2026-10-04 from `develop-design-catalogue.json` → `manifest.json` `sources[].vendor`):

| Vendor folder | Catalogue presets traced to it |
|---|---|
| SolutionPresets | 970 |
| The Ultimate Preset Bundle - Huliluts | 813 |
| WithLuke studios | 590 |
| WithLuke - Master Collection | 218 |
| **Total** | **2,591 (all of them)** |

- **Evidence of how they were obtained:** the WithLuke guide in the source folder opens with "Many thanks for purchasing my Preset Collection!" No licence, EULA or terms file exists in any of the four vendor folders; there are only installation guides.
  - Web searches for the Huliluts and WithLuke licence terms found nothing authoritative today.
  - Typical consumer preset licences allow use in your own editing, and forbid redistribution or resale.
- **What ships derived from them:**
  1. **Display names**, verbatim from the vendor files ("01 Fitness 01", "Light & Airy", …). On both platforms.
  2. **Look pack recipes**: the vendors' Lightroom slider and curve values, converted (`shared/look-pack/build_pack.py`), for all 2,591 presets. On both platforms.
  3. **iOS only:**
     - `presets_photo.json`: 3,157 recipes, each with an `originPath` naming the vendor pack (for example "SolutionPresets/…", "The Ultimate Preset Bundle - Huliluts/…");
     - `luts_video.json`: 1,742 entries naming "WithLuke studios/…" and Huliluts paths.
     - Both are in the release bundle because everything under `ios/Lightly/` is a resource.
- **Trademarks in display names:**
  - "Kodak Portra 1–10", "Portra 400 01–09", "Landscape 5 - Kodak", "Aerial 9 - Kodak Aerial", "16 - (Portrait) Kodak 2", "CC41 - Portrait | Kodak X", "Polaroid - 1–12".
  - Kodak, Portra and Polaroid are registered marks of their owners.
- **Adobe profile references:** 54 source files carry `crs:Copyright "© 2018 Adobe Systems, Inc."`, from an embedded Adobe creative profile ("Adobe Color", "Vintage 01"). We convert only the slider values. Whether any profile data is reproduced needs a check by the converter's owner.

**What's missing (exactly):**
1. The purchase records and the licence or EULA text for each of the four packs: SolutionPresets, Huliluts "The Ultimate Preset Bundle", WithLuke studios, WithLuke Master Collection.
2. Written permission from each vendor to redistribute their preset settings and names inside a commercial app, or an assignment of those rights. Nothing in the repo shows we hold either.
3. A decision on the trademarked names.

**Risk: high.**
- Redistributing purchased presets (and their names) in a competing commercial editor is the clearest breach scenario if the vendors' terms forbid redistribution, which is typical.
- Whether bare slider values are copyrightable is doubtful, but contract terms and names do not depend on that.
- The iOS bundle's `originPath` fields put the vendors' names inside the shipped app.

**Resolution options.**
- A. **Licence:** obtain written redistribution licences from the three vendors. Credit them as they require.
- B. **Replace:** commission or author our own presets. **This changes the approved catalogue (names and counts), so it needs explicit approval.**
- C. **Hybrid:** licence some vendors and replace the rest (same approval needed).
- Whatever is chosen:
  - remove `originPath` (and any vendor path) from the shipped iOS JSON;
  - decide whether `presets_photo.json` and `luts_video.json` should ship at all now that the look pack is the source (engineering question);
  - rename or license the Kodak, Portra and Polaroid names (a copy change, so it needs approval).

---

## Other release dependencies found while checking

- **iOS privacy manifest missing.**
  - No `PrivacyInfo.xcprivacy` exists in `ios/`.
  - The app uses `UserDefaults` (`PreferencesStore`, `FavouritePresetsStore`), which is a required-reason API. App Store submission needs `NSPrivacyAccessedAPICategoryUserDefaults` with reason `CA92.1`, plus `NSPrivacyTracking = false` and empty collected-data types.
  - Engineering task; not a docs/v1/release file.
- **Android 12+ device-to-device transfer.**
  - `android:allowBackup="false"` stops cloud backup. For apps targeting Android 12+, it does **not** stop device-to-device transfer (https://developer.android.com/guide/topics/data/autobackup).
  - The app targets SDK 36. To keep signatures and logos from moving to a new phone, `dataExtractionRules` must exclude them. Otherwise the privacy text must say they may move with a device transfer.
  - The drafts currently use the cautious wording.
- **No in-app place for licence notices.**
  - The approved UX (`docs/ui/app/`) has Privacy Policy, Terms of Use, About and Support, but no Acknowledgements or Licences page.
  - The terms draft now carries a "Notices" section, so the Apache-2.0 and OFL notices and the photo credits display without a UX change.
  - A separate Acknowledgements screen would need explicit approval.
  - The OFL and Apache text files are also in the bundles.

## Summary

| # | Item | Status | Exact question |
|---|---|---|---|
| 1 | Depth Anything V2 Small | **needs counsel** | Can we ship Apache-2.0 DA-V2-Small weights trained on pseudo-labels of research-only and NC/SA datasets (SA-1B, ImageNet-21K, BDD100K, VKITTI 2, Hypersim), when we never accepted those datasets' terms? |
| 2 | LaMa big-lama | **needs counsel** (provenance verified: identical to the official README's primary download) | Does Samsung's Apache-2.0 release of Places2-trained weights let us ship them commercially, given that Places' "non-commercial research" terms bound only the downloader? |
| 3 | MediaPipe / ML Kit (Android) | **needs owner action** (D3 choice) | Which option: MediaPipe with datatransport removed, raw `.tflite` on LiteRT, or ML Kit with metrics disclosed? The licences are clear (Apache-2.0, consented data). |
| 4 | Apple Vision | **clear** | None beyond the DPLA. The Face Data disclosure is in the privacy draft. |
| 5 | LiteRT 1.4.2 | **clear** | None; ship the Apache-2.0 notice. |
| 6 | OFL fonts | **clear** | None; the licence files ship, and the fonts are not sold on their own. |
| 7 | Unsplash backgrounds | **needs owner action** | Keep all four, crediting the photographers, and ungate them on Android? Or approve replacing `backlit_02` (a person seen from behind)? |
| 8 | Prototype sample photos | **clear** | None ship. |
| 9 | Preset catalogue | **needs owner action + counsel** (blocker) | Do we hold redistribution rights from SolutionPresets, Huliluts and WithLuke for the 2,591 preset names and settings, and may we use "Kodak", "Portra" and "Polaroid" in preset names? |
| — | iOS privacy manifest | needs engineering | Add `PrivacyInfo.xcprivacy` (UserDefaults CA92.1, no tracking, no collected data). |
| — | Android D2D transfer | needs owner action | Exclude signatures and logos from device transfer with `dataExtractionRules`, or disclose it? |
