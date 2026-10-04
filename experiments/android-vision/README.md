# experiments/android-vision — on-device face detection and subject segmentation

This is a standalone evaluation harness. Its application id is `com.lightlylabs.visioneval`. It is not linked into `android/` and never touches `com.lightlylabs.lightly`. The findings are in `docs/v1/android-vision-evaluation.md`.

| Path | Committed? | Contents |
|---|---|---|
| `VisionEval/` | sources | Android app. There is one flavour per SDK for APK-size probes; `all` is the flavour that gets installed. |
| `VisionEval/app/src/sdk*/java` | yes | Candidate implementations: ML Kit face / face mesh / selfie / subject, and MediaPipe Tasks |
| `models/MODELS.csv` | yes | MediaPipe model URLs, sha256 and licence. The `.tflite`/`.task` files themselves are ignored. |
| `scripts/prepare_assets.sh` | yes | Fetches and verifies the models, builds the photo set and stages both as `all` assets (ignored) |
| `scripts/make_test_set.py` | yes | Produces 25 photos at 2048 px: 22 lut3d Unsplash originals, `experiments/test-photos/group_three_01.jpg` and 2 synthetic composites |
| `scripts/vision_reference.swift` | yes | Apple Vision reference run on macOS, used for iOS parity and as pseudo ground truth. Writes to `work/vision_ref/` (ignored). |
| `scripts/ground_truth.json` | yes | Hand-labelled face boxes, skin-tone bucket and person counts |
| `scripts/run_device.sh` | yes | Installs the harness on an allow-listed dev phone, runs one candidate per process, pulls the results and uninstalls |
| `scripts/analyse.py` | yes | Writes `results/summary.{json,md}` and contact sheets to `~/.codex/artifacts/lightly/v1/android-vision/` |
| `results/<device>/` | JSON only | Raw per-candidate results. Mask PNGs are ignored. |

## Reproduce

```bash
export JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
scripts/prepare_assets.sh
swiftc -O scripts/vision_reference.swift -o work/vision_reference && work/vision_reference work/photos work/vision_ref
scripts/run_device.sh 002843623001047   # Nothing A069
scripts/run_device.sh ZY22MQNLBJ        # motorola edge 60
.venv/bin/python scripts/analyse.py
# size probes: (cd VisionEval && ./gradlew assemble{None,MlkitFace,MlkitFaceMesh,MlkitSelfie,MlkitSubject,Mediapipe}Release)
```

The harness manifest strips `INTERNET` and `ACCESS_NETWORK_STATE`, the permissions that the SDKs' Firelog telemetry merges in. Every bundled candidate therefore runs without any network access.

## LiteRT path (the app's choice, docs/v1/android-vision-evaluation.md §1)

The app does not use MediaPipe Tasks. It runs the MediaPipe `.tflite` files on LiteRT 1.4.2 with its own pre- and post-processing (`android/core-vision`). These scripts are the numpy reference for that port and the comparison with Apple Vision:

| Path | Contents |
|---|---|
| `scripts/litert_reference.py` | BlazeFace (short and full range) letterbox, anchors, decoding and weighted NMS; Face Mesh V2 ROI and landmark mapping; selfie segmenter. Runs on `ai-edge-litert`. Unzip `face_landmarker.task` into `models/face_landmarker/` first. |
| `scripts/litert_pose_reference.py` | Pose detector, used for person presence (unzip `pose_landmarker_lite.task` into `models/pose_landmarker/`) |
| `scripts/compare_landmarks_vision.py` | Eye and lip error against Vision's landmarks, divided by the face width |
| `scripts/vision_subject_reference.swift` | macOS Vision: foreground-instance matte, face landmarks, human rectangles |
| `scripts/subject_photos.csv` | The two CC0 "subject, no person" photos (boat, swan) |
| `scripts/convert_u2netp.py` | U²-Netp → LiteRT. Not run: needs the owner's permission (evaluation §5) |

The harness's R8 rules now keep Flogger. Without that, `Graph.<clinit>` threw "no caller found on the stack" in every MediaPipe candidate. On the arm64 emulator, MediaPipe Tasks inference then dies with SIGILL (XNNPACK), so Tasks candidates can only be measured on devices.
