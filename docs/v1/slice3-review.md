# Slice 3 review package: Background and Portrait

- **Reference:** approved `docs/ui/app/`, reviewed under `docs/ui/REVIEW-RULES.md`.
- **Status:** progress, **not accepted**.
  - Android is partly blocked (D3: subject segmentation and face detection need the device evaluation).
  - Both platforms carry deviations that need your decision.
  - Device-only checks are pending.
- **Whose results:** the platform agents'. The coordinator spot-checked one screen.
- **Detail:** `docs/v1/slice3-ios.md`, `docs/v1/slice3-android.md` and `docs/v1/contract-fixes-1.md`.

## Exact commits

| Platform | Code | Docs and evidence |
|---|---|---|
| Shared | fea63fb rendering-v2 revision 1 (blur, pull-push, grain chroma and aliasing, G3–G6, renderer goldens) | 2886f7a contract-fixes-1 |
| iOS | 5976127 (runner plus Background/Portrait), 0f8cc0c, 420f429, 10317d5, 5489d4c, 10ce7d2, a505854, ec1df87 (revision-1 port), 5c3a3ee (face-ring proportion), 73a42cc (iPad Portrait tab scroll) | 7202747, e7de483 |
| Android | 9cce099 (Background), 25f47bf, 725d117 (LiteRT depth behind the release gate, crash fix), 309a24e (revision-1 port) | eb4aa8c, ea45916 |
| Tooling | b0de57a (references load all fonts before rendering) | — |

## iOS: complete matrix (24 cells × 21 screens = 504)

- **How captured:** runner v5, one cell per lock, from one recorded build at 5c3a3ee. The pt-* screens in the 8 landscape cells were recaptured at 73a42cc after defect X3.
- **Records:** every capture's JSON record carries its revision, fingerprint and cell, plus:
  - `subjectMatte`: the macOS-computed matte fixture, because the Simulator cannot run Vision's foreground-instance mask;
  - `faceQuality`: ignored in the Simulator only, because Simulator scores are random (10317d5).
- **Result:** 28 exact matches. 476 carry recorded deviations only. No defect is open and no screen is unverified.

| Id | Screens | Deviation | Needs |
|---|---|---|---|
| S1 | bg-focus, bg-soft, bg-swirl, bg-motion, bg-replaced-blur | Blur strength and style: about 19% weaker than the prototype on iPhone 17 and stronger on tablets (contract-fixes-1 §1). Each style keeps its own texture | Your decision |
| S2 | bg-* with a subject | The prototype's illustrative mask leaves a halo of the old background around the subject; the real matte does not | Your decision |
| S3 | bg-focus family | The default focus sits on the detected face; the prototype uses a fixed point (0.40, 0.48) | Your decision |
| P1 | pt-teeth, pt-landscape-photo | The face ring now uses the prototype's measured ring-to-face proportion (5c3a3ee). The smile photo's hand-placed ring is wider than that proportion | Residual only; your decision |
| P2 | pt-multi | The approved screen shows a one-face photo, because no multi-person photo existed (the prototype says so). Native shows the licensed group photo with the approved face picker ("Face N · changes", "Each face keeps its own settings.", scrolling like the prototype's chip row) | Your decision |
| P3 | pt-no-usable-face | In the Simulator, Vision finds no person in the bar photo, so Portrait is hidden | Device check |
| M2, M3 | all iPad cells, Large cells | As in slice 2 | Your decision |
| M9 | bg-failed (its setup applies Glow) | Grain strength uncalibrated | Lightroom references |

**Coordinator spot check:** `iphone17-portrait-light-default/pt-multi`.
- The face picker matches `faceStrip` in `docs/ui/app/app.js`: chip labels, the note, and the horizontal scroll.
- The panels and tabs match.
- Differences: the status bar and P2.

## Android: partial (Pixel 9 Pro light-default only)

**Comparison:**

| Screens | Result |
|---|---|
| bg-separating | S1 (system bars) only |
| bg-failed | S1 and S8 (grain) |
| bg-focus, bg-soft, bg-swirl, bg-motion | Revision-1 blur ported; still weaker than the reference, because without D3 the focus falls on the image centre and the subject-in-focus rule cannot apply (B2) |
| bg-no-subject, bg-refine, bg-change-*, bg-replaced-blur | Blocked on D3 |
| Portrait | Blocked on D3 |

**Depth (Depth Anything V2 Small on LiteRT 1.4.2):**
- No INTERNET permission and no telemetry; enforced by a manifest-privacy check on every build.
- The model ships in debug builds only, until the training-data legal sign-off.

**Other matrix cells:** pending.

## Pending before acceptance

1. **Android:**
   - the D3 device evaluation (MediaPipe vs ML Kit) on the two dev phones, which need connecting;
   - then subject separation, the Portrait tool, and the slice-3 matrix.
2. **Device verification (dev devices only):**
   - iOS subject matte, the P3 bar photo and the face-quality threshold;
   - device timings on both platforms.
3. **Your decisions:**
   - S1 and tablet blur, the styles, S2, S3, P1 residual, P2;
   - the shipping licence for the debug-only background photos;
   - the legal sign-off on the depth model's training data.
4. **Lightroom grain references:** 20 exports, listed in contract-fixes-1 §3.
