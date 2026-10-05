# Android on-device vision: face detection and subject segmentation

Status: **decided for face and person detection; subject segmentation pending a model conversion approval.** Device accuracy and timing are pending (the dev phones are not connected).
Harness: `experiments/android-vision/` (standalone app `com.lightlylabs.visioneval`).

<!-- DEVICE-RESULTS -->

## 1. Decision (2026-10-04)

| Need | Choice | Runtime |
|---|---|---|
| Faces, landmarks (Portrait, face rings, Focus on the face) | MediaPipe BlazeFace **full range** + Face Mesh V2 landmarks (`face_landmarks_detector.tflite` from `face_landmarker.task`) | LiteRT 1.4.2 (already approved), our own pre/post-processing in `android/core-vision` |
| Person presence without a usable face (Portrait visibility, dim rings) | MediaPipe pose detector (`pose_detector.tflite` from `pose_landmarker_lite.task`) | same |
| Person matte (people only) | MediaPipe selfie segmenter (square) | same |
| Subject matte, class-agnostic (Change background, Refine edges, "No clear subject found") | U²-Netp, **pending**: conversion refused by the permission system twice (§5) | LiteRT, pluggable |

**MediaPipe Tasks is not used.** Its telemetry can be removed from the manifest (the privacy check then passes), but the logging code stays on the classpath and is always created, and no emulator inference run could confirm that the stripped build works (§2.4). The class-agnostic subject model needs LiteRT anyway. Running the MediaPipe `.tflite` files directly on the LiteRT 1.4.2 runtime the app already ships adds **no new dependency and no telemetry**.

## 2. Telemetry evidence: `com.google.mediapipe:tasks-vision:1.0.0`

### 2.1 Version

`1.0.0` is the newest version on Google Maven (`maven-metadata.xml`, `lastUpdated` 20260727204405; the earlier ones are 0.10.x and 0.20230731).

### 2.2 The app's exact configuration

A scratch, uncommitted copy of `android/` at `41b2340` had `implementation("com.google.mediapipe:tasks-vision:1.0.0")` added. It was built with JBR 25 (`openjdk 25.0.3`), job `build-android-mediapipe-appcfg`.

The `releaseRuntimeClasspath` gains:

| Artifact | Version | Role |
|---|---|---|
| `com.google.mediapipe:tasks-core` | 1.0.0 | Tasks runtime (`libmediapipe_tasks_jni.so`, 11.0 MB arm64) |
| `com.google.android.datatransport:transport-api` | 3.0.0 | Firelog API |
| `com.google.android.datatransport:transport-runtime` | 3.1.0 | Firelog scheduler and uploader |
| `com.google.android.datatransport:transport-backend-cct` | 3.1.0 | Clearcut (CCT) backend |
| `com.google.firebase:firebase-encoders` | 17.0.0 | encoders for the log payload |
| `com.google.firebase:firebase-encoders-json` | 18.0.0 | |
| `com.google.firebase:firebase-encoders-proto` | 16.0.0 | |
| `com.google.protobuf:protobuf-javalite` | 4.26.1 | |
| `com.google.flogger:flogger`, `flogger-system-backend` | 0.6 | |
| `com.google.guava:guava` | 27.0.1-android | |

The merged release manifest gains:
- `android.permission.INTERNET` and `android.permission.ACCESS_NETWORK_STATE`;
- the service `com.google.android.datatransport.runtime.backends.TransportBackendDiscovery`, whose meta-data names `backend:com.google.android.datatransport.cct.CctBackendFactory`;
- the service `com.google.android.datatransport.runtime.scheduling.jobscheduling.JobInfoSchedulerService`;
- the receiver `com.google.android.datatransport.runtime.scheduling.jobscheduling.AlarmManagerSchedulerBroadcastReceiver`.

`verifyReleaseManifestPrivacy` **fails**: "Merged manifest contains forbidden entries: android.permission.INTERNET, android.permission.ACCESS_NETWORK_STATE, datatransport".

### 2.3 Can it be switched off?

**By configuration: no.** In the `tasks-core-1.0.0` bytecode, `TasksStatsLoggerFactory.create(Context, String, String)` always returns `TasksStatsProtoLogger.create(...)`. That calls `TransportRuntime.initialize`, gets a transport for the log source `COREML_ON_DEVICE_SOLUTIONS` (proto `MediaPipeLogExtension`), and `RemoteLoggingClient` sends each event with `Transport.send`. `TasksStatsDummyLogger` exists, but no option selects it.

**By manifest removal: the build passes.** The same scratch copy then marked the two permissions and the three datatransport components `tools:node="remove"`. The merged manifest has none of them, and `verifyReleaseManifestPrivacy` passes ("OK: none of …"). The datatransport and Firebase encoder classes stay in the APK, and the logger is still created at every task start.

### 2.4 Does inference still work with them removed?

Not confirmed. The harness's `mediapipe` flavour (selfie segmenter) was built twice on the Pixel 9 Pro emulator (arm64, API 36, Apple-silicon host), with airplane mode on:
- **control**: datatransport kept, INTERNET removed;
- **stripped**: all three components and both permissions removed.

| Run | Result |
|---|---|
| Both, with the harness's original R8 rules | `ExceptionInInitializerError` in `com.google.mediapipe.framework.Graph.<clinit>`, caused by `IllegalStateException: no caller found on the stack`. Flogger's caller lookup broke under R8 renaming. This is a harness defect, not telemetry; fixed by keeping `com.google.common.flogger.**`. |
| Both, with the fix | The process dies with **SIGILL** (`ILL_ILLOPC`) in `libmediapipe_tasks_jni.so`, thread `drishti`, on the first inference. The control and the stripped build fail identically. |

The SIGILL matches the XNNPACK failure LiteRT shows on this emulator. LiteRT can turn XNNPACK off (`setUseXNNPACK(false)`); MediaPipe Tasks' CPU path cannot. So the emulator cannot show whether the stripped build works, and no datatransport log line appeared in either run. A device run is needed, and is moot after the decision in §1.

Evidence (logs, merged manifests, both classpaths): `~/.codex/artifacts/lightly/v1/android-vision/mediapipe-telemetry-2026-10-04/`. APK SHA-256: control `fa1dac66…4919`, stripped `c17e2984…b850`.

## 3. Models used on LiteRT

All come from Google's MediaPipe model bucket. The SHA-256 values are checked at build time when bundled.

| File in the app | Source | SHA-256 | Licence (model card) | Card |
|---|---|---|---|---|
| `blaze_face_full_range.tflite` | https://storage.googleapis.com/mediapipe-models/face_detector/blaze_face_full_range/float16/latest/blaze_face_full_range.tflite | `3698b18f063835bc609069ef052228fbe86d9c9a6dc8dcb7c7c2d69aed2b181b` | Apache-2.0 | https://storage.googleapis.com/mediapipe-assets/MediaPipe%20BlazeFace%20Model%20Card%20(Full%20Range).pdf |
| `face_landmarks_detector.tflite`, extracted from `face_landmarker.task` | https://storage.googleapis.com/mediapipe-models/face_landmarker/face_landmarker/float16/latest/face_landmarker.task (task `64184e229b263107bc2b804c6625db1341ff2bb731874b0bcc2fe6544e0bc9ff`) | `c7d54204ce0448474c7f3fa9af494787c0965cbdd6f20fc72867e43046bd43d5` | Apache-2.0 | https://storage.googleapis.com/mediapipe-assets/Model%20Card%20MediaPipe%20Face%20Mesh%20V2.pdf |
| `pose_detector.tflite`, extracted from `pose_landmarker_lite.task` | https://storage.googleapis.com/mediapipe-models/pose_landmarker/pose_landmarker_lite/float16/latest/pose_landmarker_lite.task (task `59929e1d1ee95287735ddd833b19cf4ac46d29bc7afddbbf6753c459690d574a`) | `46837eb883e6ec75b52c5f5ff6a9b78bd35e66c13f95e8c3566c582d146cb1d9` | Apache-2.0 | https://storage.googleapis.com/mediapipe-assets/Model%20Card%20BlazePose%20GHUM%203D.pdf |
| `selfie_segmenter.tflite` | https://storage.googleapis.com/mediapipe-models/image_segmenter/selfie_segmenter/float16/latest/selfie_segmenter.tflite | `191ac9529ae506ee0beefa6b2c945a172dab9d07d1e802a290a4e4038226658b` | Apache-2.0 | https://storage.googleapis.com/mediapipe-assets/Model%20Card%20MediaPipe%20Selfie%20Segmentation.pdf |

The model cards for full-range BlazeFace, Face Mesh V2 and BlazePose GHUM 3D were not re-read today; their licence is taken from MODELS.csv and the bucket listing. The selfie and short-range BlazeFace cards were read for `docs/v1/release/dependencies.md` item 3.

Pre- and post-processing follow the MediaPipe graphs (`modules/face_detection/*.pbtxt`, `tasks/cc/vision/face_detector/face_detector_graph.cc`, `face_landmarks_detector_graph.cc`, `modules/pose_detection/pose_detection_cpu.pbtxt`, `image_preprocessing_graph.cc`):
- **BlazeFace full range:**
  - letterboxed 192 × 192, zero border, RGB in [−1, 1];
  - SSD anchors: 1 layer, stride 4, 48 × 48 × 1 = 2304, fixed size, offset 0.5;
  - box and six keypoints decoded with scale 192, sigmoid score clipped at ±100, threshold 0.6;
  - weighted NMS at IoU 0.3, then the letterbox is removed.
- **Face landmarks:**
  - ROI = the detection box × 1.5, centred on the box, rotated so that keypoint 0 → keypoint 1 (the eyes) is horizontal;
  - sampled bilinearly to 256 × 256, RGB in [0, 1], aspect not kept;
  - 478 landmarks (x, y in tensor pixels) are mapped back through the same rotated ROI;
  - presence = sigmoid of the second output ≥ 0.5.
- **Pose detector (person presence):**
  - letterboxed 224 × 224, [−1, 1];
  - anchors: 5 layers, strides 8/16/32/32/32, 2 per location = 2254;
  - scale 224, threshold 0.5, weighted NMS 0.3.
- **Selfie segmenter:** stretched to 256 × 256, [0, 1], one confidence channel, upsampled to the photo.

## 4. Desk results against Apple Vision (macOS, same photos)

A numpy reference of §3 ran on the LiteRT Python interpreter (`ai-edge-litert` 2.2.0). Apple Vision on macOS ran `VNGenerateForegroundInstanceMaskRequest`, `VNDetectFaceLandmarksRequest` and `VNDetectHumanRectanglesRequest` (`upperBodyOnly = false`) on the same photos.

New fixtures for "a subject but no person" (CC0, Wikimedia Commons, 1920 px renditions):
- `subject_boat.jpg` = "Red boat Eretria Greece" by Jebulon, SHA-256 `9e880123…c2e0`;
- `subject_swan.jpg` = "Mute swan foraging grass (4)" by Peulle, SHA-256 `8a9de9b7…b19c`.

| Photo | Vision: subject / faces / humans | Android: faces (score, landmark presence) | Pose detector | Selfie IoU vs Vision subject |
|---|---|---|---|---|
| portrait_medium_02 | 1 / 1 / 1 | 1 (0.77, 1.00) | 1 | 0.965 |
| portrait_deep_02 | 1 / 1 / 1 | 1 (0.80, 1.00) | 1 | 0.909 |
| portrait_deep_03 | 1 / 1 / 1 | 1 (0.93, 1.00) | 1 | 0.969 |
| portrait_light_01 | 1 / 1 / 1 | 1 (0.96, 1.00) | 1 | 0.942 |
| group_three_01 | 1 / 3 / 2 | **3** (0.87, 0.93, 0.86; all 1.00) | 1 | 0.666 |
| backlit_02 (person, face not visible) | 1 / 0 / 1 | 0 | 1 | 0.957 |
| night_03 (bar) | 0 / 0 / 0 | 1 (0.63, **0.00**: not usable) | 1 | — |
| subject_boat | **1** / 0 / 0 | 0 | 0 | 0.431 |
| subject_swan | **1** / 0 / 0 | 0 | 0 | 0.669 |
| landscape_02 (lake, approved `bg-no-subject`) | **0** / 0 / 0 | 0 | 0 | — (selfie marks 12 %) |
| landscape_03 | 0 / 0 / 0 | 0 | 0 | — (selfie marks 32 %) |
| sunset_02 | 0 / 0 / 0 | 0 | 0 | — |

Findings:
- **Short-range BlazeFace misses one of the three faces** in `group_three_01` (2 of 3). The full-range detector finds all three.
- **Landmarks agree with Vision.** Measured per face as eye-centre and outer-lip-centre distance divided by the face width: eyes ≤ 0.017, lips ≤ 0.019, on all seven faces. That includes the strongly tilted left face in the group photo.
- **Person presence** (face ≥ 0.6, or a pose detection ≥ 0.5) matches the approved `toolsFor` on every photo:
  - `backlit_02` and the bar have people;
  - the boat, swan and landscapes do not.
- **The bar** gets one face that has no landmarks, so it is not usable. This is the approved `pt-no-usable-face` state (Portrait shown, "No face can be edited", dim rings). iOS in the Simulator misses these people (slice3-ios P3).
- **The selfie segmenter cannot decide "no subject"**: it marks 12 % of the lake and 32 % of the field. It cannot find the boat either (IoU 0.43). It is therefore used only as the person matte when people are present, never as the subject detector.
- **A class-agnostic model is needed** to match Vision on the boat and the swan (subject found, Portrait hidden) and on the lake (no subject).

## 5. Class-agnostic subject model: proposal (conversion pending approval)

Approved copy: "Change background needs a person or object in front". The segmenter must therefore be class-agnostic, as iOS's `VNGenerateForegroundInstanceMaskRequest` is.

| Candidate | Code licence | Weights licence | Size | Status |
|---|---|---|---|---|
| **U²-Netp** (`U2NETP`) | Apache-2.0 (github.com/xuebinqin/U-2-Net, LICENSE) | Apache-2.0 (the repository's licence; README links the weights) | 4.7 MB fp32 | **chosen for evaluation; conversion blocked (below)** |
| U²-Net (full) | Apache-2.0 | Apache-2.0 | 176 MB | too large |
| IS-Net / DIS (`isnet-general-use`) | Apache-2.0 ("Our code and evaluation metric use Apache License 2.0") | **not stated**; the DIS5K dataset has its own terms of use | 176 MB | excluded until the weights' licence is clear |
| RMBG and similar | — | non-commercial | — | excluded |
| MediaPipe `magic_touch` | Apache-2.0 | Apache-2.0 | 6.2 MB | needs a seed point; with an automatic seed it is not class-agnostic "subject finding" |
| MediaPipe `deeplab_v3` | — | unverified (no model card) | 2.8 MB | PASCAL classes only (no trees); excluded |

**Proposal (U²-Netp):**
- **Source:**
  - code: `model/u2net.py` at commit `ac7e1c817ecab7c7dff5ce6b1abba61cd213ff29` (SHA-256 `96dd7a19c7de4f13520ccfc1075ded3350ff4946493be3561b9918a46218f415`; reviewed: 525 lines, imports only `torch`, plain `nn.Module` classes);
  - weights: `u2netp.pth` from the README's Google Drive link (file id `1rbSTGKAE-MTxBYHd-51l2hMOQPT_7EPy`), SHA-256 `e7567cde013fb64813973ce6e1ecc25a80c05c3ca7adbc5a54f3c3d90991b854`, 4.7 MB.
- **Training data:** DUTS-TR (10,553 images; the U²-Net paper). DUTS publishes no explicit licence. **Counsel**, the same question as Depth Anything's training data.
- **Steps (offline, scratch venv with `torch` 2.13 and `litert-torch` 0.9.4):**
  1. verify the weights' SHA-256;
  2. `torch.load(path, map_location="cpu", weights_only=True)` into `U2NETP(3, 1)`;
  3. wrap the model to return `d0` only;
  4. `litert_torch.convert` with a 1 × 3 × 320 × 320 sample, export fp32;
  5. compare against torch on random input;
  6. record the output file's SHA-256.
- **Input contract** (`u2net_test.py`): RGB resized to 320 × 320, divided by its maximum, ImageNet mean/std, NCHW. Output: a 1 × 1 × 320 × 320 sigmoid saliency, upsampled and refined to the photo.
- **"No clear subject":** the matte's area and peak confidence are thresholded. The thresholds are set on the fixtures in §4 (boat and swan: subject; lake, field and sunset: none) and recorded here once measured.
- **What ships and what doesn't:** nothing ships until the owner approves bundling. Until then:
  - the converted file stays git-ignored, as the depth model does;
  - it would be packaged only into debug builds, and into release only behind a sign-off property (`-PlightlySubjectLegalSignOff=true`, training-data question above);
  - without it, a photo with no person shows the approved "Couldn't separate the subject" state, never a guessed "no subject";
  - a photo with people uses the person matte.
- **Status (2026-10-05): converted and desk-evaluated as an experiment; not approved for bundling, not wired.**
  - Earlier, the conversion was refused twice by the permission system ("[Code from External]"). On 2026-10-05 it ran at the owner's direction (`scripts/convert_u2netp.py`).
  - Provenance re-checked:
    - `model/u2net.py` is byte-identical to upstream at `ac7e1c8` (fetched again; SHA-256 above).
    - The repository has no copy of the weights. The README's Google Drive link (id above, still present at `ac7e1c8`) is the primary source, and the local file matches its recorded SHA-256.
    - Loaded with `weights_only=True`. Licence: Apache-2.0 (LICENSE at `ac7e1c8`).
  - Output `u2netp_320_fp32.tflite`, SHA-256 `40655434570d0716e005904f2f833f6a87856ed2ac26a26d529c7234a3fe399e` (git-ignored; `models/MODELS.csv`). Max |LiteRT − PyTorch|: 3.6e-5 on random input, ≤ 1.4e-4 on the boat, swan and lake.
  - Preprocessing confirmed against `u2net_test.py` / `data_loader.py`:
    - `skimage.transform.resize(image, (320, 320), mode='constant')`, which anti-aliases when downscaling;
    - then `image / max`, ImageNet mean/std, NCHW; the output is `d1` (= d0).
    - The script then min-max normalises (`normPRED`). The "no subject" decision must use the raw sigmoid, because normalising stretches every photo's peak to 1.
  - **Desk results (reference preprocessing, raw sigmoid, 320 × 320):**

    | Photo | Vision subject | Area ≥ 0.5 | Area ≥ 0.9 | IoU vs Vision matte |
    |---|---|---|---|---|
    | subject_boat | 1 | 36.5 % | 34.9 % | 0.965 |
    | subject_swan | 1 | 5.2 % | 4.6 % | 0.942 |
    | backlit_02 (person, no face) | 1 | 9.0 % | 8.1 % | — |
    | portraits (4), group_three_01 | 1 | 34–68 % | 33–67 % | — |
    | landscape_02 (lake, approved `bg-no-subject`) | 0 | 11.0 % | 1.1 % | — (soft blob on the mountain, peak 0.98) |
    | landscape_03 | 0 | 0.4 % | 0.0 % | — |
    | sunset_02 | 0 | 1.1 % | 0.8 % (the sun) | — |
    | night_03 (bar) | 0 | 1.0 % | 0.0 % | — |

    - The area at ≥ 0.9 separates all 12 (subjects ≥ 4.6 %, scenes without a subject ≤ 1.1 %). With 12 photos this is provisional, not calibrated.
    - The placeholder rule in `SubjectSaliency` (≥ 1 % at 0.5 and peak ≥ 0.5) is wrong: it calls the lake a subject.
  - **Preprocessing is decisive.** `SubjectSaliency.input`'s plain bilinear stretch changes the output by up to 0.99:
    - night_03 (bar) goes to 14.5 % at ≥ 0.9, so it would read as a subject;
    - area averaging is closer but still moves the lake from 1.1 % to 3.3 %, near the swan's 4.5 %.
    - Android needs an exact port of the anti-aliased resize, golden-checked against skimage.
  - **Portrait visibility is independent of this model.**
    - Portrait is offered only when the people analysis finds a person (`EditorModels.kt`: `presence == PRESENT`; covered by `DevelopPanelModelTest`).
    - §4 found no face and no pose on the boat and the swan, matching Vision's 0 faces / 0 humans, so a found boat or animal does not expose Portrait.
    - Separate existing finding: night_03 has one face with landmark presence 0.00 plus one pose detection. `PeopleAnalysis.hasPerson` (faces or people) is therefore true there, while Vision finds no human. Not re-tested in the app.
  - **Integrated 2026-10-05 (experimental, behind the vision-model release gate).**
    - Packaging: `subject_saliency.tflite` is in `optionalVisionModels`. Debug builds package it when the file is present; release builds only with `-PlightlyVisionModels=true`.
    - Preprocessing ported exactly (`ReferenceResize`, `SubjectSaliency.input`):
      - golden-checked against scikit-image 0.26 on three inputs (downscale, odd-sized crop, upscale): resized RGB ≤ 1e-5, NCHW tensor ≤ 1e-4 (`SubjectSaliencyPreprocessingTest`);
      - on the emulator, the app's saliency against the reference on the same display pixels: max 9e-5 (boat, swan, lake, bar), the same confident areas. The 0.99 difference is resolved;
      - against the reference on the original 1920 px photo, max 0.06 (the app works on the 1600 px display image).
    - Portrait path unchanged: a photo with people uses the person matte alone and U²-Netp is not run (test). This differs from iOS, where Vision may include objects next to people.
    - Emulator flows (debug build, real models; `scripts/u2netp_emulator_flows.sh`):
      - boat and swan: separation finished with Portrait absent from the tools; replace → Undo → Redo moved the recipe and history correctly; Save copy wrote 1920 px JPEGs;
      - lake: the approved "No clear subject found" state;
      - cancel "Finding the subject…": "Cancelled · nothing changed", then a new separation finished;
      - bar: Portrait offered with the approved "No face can be edited" notice and no controls.
      - Switching photos was exercised as separate launches only, not the in-app "Choose another photo" path.
  - **Saved-copy defects (open):** a light halo around the boat's edges and a red fringe at its lower left; the swan keeps a strip of grass under its body, with a halo.
  - **Held-out check of the "no subject" rule: it fails.** 13 local photos not used to choose it (`scripts/u2netp_heldout.py`, `work/u2netp-heldout/heldout_sheet.jpg`):
    - 9 have no people. Four of them come out as a "subject": landscape_01 (mountain ridge, 6.0 %), night_01 (a building, 18.7 %), wellexposed_01 (sky between towers, 13.6 %) and wellexposed_03 (sky down a street, 11.3 %). Visually none has a separable subject, and Vision finds none.
    - The other five no-people photos are correctly "none". All 4 subject photos are found (people photos take the person path in the app).
    - No small-subject photo was available locally, so small subjects are untested.
    - The 2 % rule therefore stays experimental and is a release blocker. A better decision needs new evidence, not tuning on this set.
  - **Bar scene and Portrait (written requirement):** the approved prototype's bar photo is `faces: [], people: true` (`docs/ui/app/data.js`). `toolsFor` offers Portrait, and the panel shows the "No face can be edited" notice. Android matches.
    - Defect: Android draws a face ring around the disco ball (its unusable face detection). The prototype marks only the people (dim rings).

## 6. Static comparison (desk, earlier)

APK impact was measured with one R8-shrunk release flavour per SDK, arm64-v8a only, against an empty app of 28.7 kB. Native libraries are stored uncompressed, so the "APK" column is close to install size. The "gz" column estimates what the Play download costs.

| Candidate | Delivery | APK +MB | of which native .so | native gz | dex | models |
|---|---|---|---|---|---|---|
| ML Kit Face Detection `com.google.mlkit:face-detection:16.1.7` | bundled | 13.6 | 8.5 (`libface_detector_v2_jni`) | 3.4 | 0.9 | 4.2 MB in AAR assets |
| ML Kit Face Mesh `face-mesh-detection:16.0.0-beta3` | bundled, beta | 25.5 | 21.6 (`libxeno_native`) | 5.7 | 0.8 | 2.7 MB |
| ML Kit Selfie Segmentation `segmentation-selfie:16.0.0-beta6` | bundled, beta | 23.0 | 21.6 (`libxeno_native`) | 5.7 | 0.8 | 0.25 MB |
| ML Kit Subject Segmentation `play-services-mlkit-subject-segmentation:16.0.0-beta1` | **unbundled** (Play services module, runtime download) | 1.05 | – | – | 0.7 | downloaded by GMS |
| MediaPipe Tasks Vision `com.google.mediapipe:tasks-vision:1.0.0` | bundled; models are app assets | 13.2 + models | 11.0 (`libmediapipe_tasks_jni`) | 4.9 | 2.1 (keep rules) | see below |

MediaPipe model files (Apache-2.0; uncompressed size / gz):

- `blaze_face_short_range`: 0.23 / 0.20 MB
- `blaze_face_full_range`: 1.08 / 0.97 MB
- `face_landmarker.task`: 3.76 / 3.33 MB
- `selfie_segmenter`: 0.25 / 0.21 MB
- `selfie_segmenter_landscape`: 0.25 / 0.21 MB
- `hair_segmenter`: 0.78 / 0.70 MB
- `selfie_multiclass_256x256`: 16.4 / 15.1 MB
- `deeplab_v3`: 2.8 / 2.6 MB
- `magic_touch`: 6.2 / 5.8 MB

All sha256 values are in `experiments/android-vision/models/MODELS.csv`.

Observations:

- **ML Kit Selfie Segmentation and MediaPipe `selfie_segmenter` are the same model.** The embedded build string `selfiesegmentation_mlkit-256x256-2021_01_19-v1215` appears in both.
- **ML Kit Face Mesh is MediaPipe's face mesh with attention**, using the assets `face_landmark_with_attention.tflite` and `facedetector-front`. ML Kit wraps these models in a 21.6 MB runtime (`libxeno_native`). MediaPipe's own runtime is 11 MB.
- `face-detection:16.1.7` (bundled) depends on `play-services-mlkit-face-detection:17.1.0` for its API classes and ships the bundled native detector next to it.
- With the models on LiteRT 1.4.2, the app adds about 6.7 MB of models and no native library: full-range BlazeFace 1.08, face landmarks 2.55, pose detector 2.8, selfie 0.25.
