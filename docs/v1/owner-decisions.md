# Lightly 1.0: owner decisions (one sheet, 2026-10-06)

Already decided by the owner (not reopened here): iOS Auto stays Core Image; Android Auto is implemented independently;
non-person subject cut-out is in 1.0; the approved UX plus the owner's amendments is mandatory, with no blanket
"keep the implementation" approval.

Until each answer arrives, the current behaviour stays as recorded below; nothing here is treated as approved.

## 1. Proposals ready for your answer (no further alternatives)
| # | Proposal | Where it is recorded |
|---|---|---|
| D1 | **Preview that cannot render (Android):** after its one retry fails, a notice over the photo: "Couldn't update the preview." with "Try again". Until approved, the stale frame is not marked (the app records `previewFailed`). | remaining-work.md, Android memory |
| D2 | **Depth failure message:** replace "Couldn't measure depth. Blur needs it. Change background still works." with "Couldn't estimate depth. Try again to use Focus & Blur." | remaining-work.md, owner decisions 1 |
| D3 | **Preset names:** `release/preset-name-proposal.md` (variant numbers bound to ids; category line in Favourites). | that file |

## 2. Remaining differences from the approved screens (each one separately)
Each line: the approved screen, what the apps do, the visible effect, the evidence, and my recommendation. "Match" means
change the apps to the approved screen.

| Id | Approved screen | Apps now | Visible effect | Evidence | Recommendation |
|---|---|---|---|---|---|
| W1 | Watermark sized as the prototype draws it over its viewport | Sizes in on-screen dp over the displayed photo (provisional) | On screen it matches the prototype; the **saved** file differs by device: watermark 1.45× and blur 1.48× larger in the photo when edited on a phone than on a tablet | slice4-android.md, Sizing evidence | Decide a sizing policy. Mine: store the resolved fraction in the recipe when the tool is first set (same saved output on every device); needs a contract field |
| S1 | Prototype blur strength | Rendering contract strength | Blur about 19 % weaker than the prototype on iPhone 17, stronger on tablets; each style keeps its texture | slice3-review.md S1, contract-fixes-1 §1 | Match the prototype's on-screen strength on phones by a per-device constant, if the strength itself is what you approved |
| S3 | Focus point fixed at (0.40, 0.48) | Focus on the detected face | On a face photo the sharp plane is the face, not a fixed point; on the prototype photo they nearly coincide | slice3-review.md S3 | Your call: the fixed point is the approved screen; the face is what the prototype intends for a person |
| E1 | Straighten zoom fixed at 1.12 | Smallest zoom with no empty corners (1.077 at −3° on 3:2) | The straightened photo is slightly less magnified than in the approved screen | slice4-ios.md / slice4-android.md E1 | Match 1.12 only if the fixed zoom was intended; otherwise approve the contract zoom |
| E2 | Perspective screen: photo not warped | Keystone applied | Moving the Perspective slider visibly warps the photo (the approved screen is a static mock) | rendering-v2 §7.2, E2 | Approve the warp (the control has no effect otherwise) |
| Q1 | Edit dot rules (`toolUsed`) | Flip vertical and Perspective do not light the Edit dot, exactly as `toolUsed` | Changing only those leaves no dot on Edit | slice4-android.md Q1 | Confirm (implemented exactly as the prototype's code) |
| P2 | Multi-face screen shows a one-face photo (no licensed group photo existed) | The licensed group photo with the approved face picker | Same controls and copy, different photo | slice3-review.md P2 | Confirm (content, not layout) |
| F1 | Preset-conflict notice picks "Film n" by a stand-in hash | The preset's real finishing decides; the scenario uses the first Film preset with grain | The notice appears for the presets that really have grain | slice4-android.md F1 | Confirm |
| Fine | Ruler Fine state shown, not its timing | Fine starts after 0.5 s holding still, quarter speed | Feel only | slice2-review.md conflict 2 | Confirm 0.5 s / ¼ or give values |
| M3 | About shows "Version 1.0 (1)" | Version from the build (e.g. 1.0.0 (261006021)) | Different version string | slice1-android.md M3 | Approve the build's real version (a fixed "1.0 (1)" would be false) |
| SC | Selective Colour: temporary blue overlay while Range is dragged | No overlay | The overlay in the proposal page is absent | proposals/selective-colour README, Status | Implement the overlay if it is part of your approved layout (the README lists it as "in this page, not in the apps") |
| M2 | iPad: top safe area 24 pt | iPadOS status bar 32 pt | Top bar and photo 8 pt lower on iPad | slice2-ios.md M2 | Match: draw the top bar from 24 pt under the status bar area, as the approved screen does (recorded as possible in slice2-ios.md) |
| Splash | Mark centred below the status bar | Android 12+ system splash centres it in the screen | Mark about 24 dp higher | slice1-android.md M6 | Platform constraint (the system splash API fixes the position): needs your acceptance |

**Removed from this sheet:**
- **M4 text wrapping (iOS):** fixed for notes in 858a06f and for the preset name in 1ef2c0d (test: the name breaks at the
  last word that fits at every width 140–320 pt). Not an acceptance request.
- **P1 ring proportion:** residual only on one hand-placed prototype ring (slice3-review.md); not requested.

## 3. Model release gates: evidence and the approval each still needs
Splitting a gate is a build switch; it does not clear a model. Each row needs the named approval before its gate opens.

| Model (feature) | Licence of code and weights (established) | Training data (established) | Still needed | Gate |
|---|---|---|---|---|
| BlazeFace, Face Mesh, pose detector, selfie segmenter (Android Portrait, people, person matte) | Apache-2.0 (model cards; BlazeFace full range and Face Mesh cards not re-read) | "Consented images of people" (selfie, BlazeFace short-range cards) | Your D3 choice: the apps run the raw `.tflite` files on LiteRT (option B: no MediaPipe runtime, no telemetry); confirm that choice | `-PlightlyVisionModels` (shared with MODNet and U²-Netp today; can be split into its own switch) |
| MODNet (Android Change background, people) | Apache-2.0 code | Not documented by the authors | Counsel (training data) | same vision gate |
| U²-Netp (Android Change background, objects) | Apache-2.0 | DUTS-TR | Counsel (training data); also the no-subject rule (below) | same vision gate |
| Depth Anything V2 Small (Focus & Blur without embedded depth, both) | Apache-2.0 code and Small weights | Includes research-only and NC/SA sets | Counsel (the three questions in remaining-work.md) | iOS `LIGHTLY_DEPTH_MODEL_TRAINING_DATA_SIGNED_OFF`, Android `-PlightlyDepthLegalSignOff` |
| LaMa (Remove, both) | Apache-2.0 code; weights without separate licence | Places2 (non-commercial terms) | Counsel | iOS `LIGHTLY_REMOVE_MODEL_TRAINING_DATA_SIGNED_OFF`, Android `-PlightlyRemoveLegalSignOff` |

Android Auto needs no model (its own analysis) and works in Release.

## 4. Restoring an edit after the app ends (current behaviour, kept until you decide)
Persisting and restoring an edit is the app's own behaviour, not the platform's:
- **iOS:** while an edit has unsaved changes, the app keeps the session on disk (original bytes, every undo step, Auto
  state, analysis results). On the next launch it restores the session only when a SwiftUI scene-storage flag marks an
  editing scene; iOS clears that flag when the user swipes the app away, so **after a user force-quit the edit is not
  restored**, and after the system ends the app it is (simulator-tested; slice5-ios.md R1).
- **Android:** the edit is kept in the activity's saved state, which Android keeps when the system ends the process and
  drops when the user removes the task; **after a swipe-away the edit is not restored** (not yet recorded on a device).
- Your decision: keep this, or restore after a force-quit as well (then the app keeps the session regardless of the flag).

## 5. Still yours to supply
Legal facts (`release/legal-proposals.md` §2): operator name and address, minimum age, pricing, whether the bundled
background photos ship; counsel's questions (§3). Grain (M9) and vignette (G2) calibration needs Lightroom Classic
exports: the 20-export grain set is specified in `contract-fixes-1.md` ("Lightroom references needed"); a vignette set
of the same kind still has to be specified.
