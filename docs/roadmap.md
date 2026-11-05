# Lightly roadmap

## Release plan (owner, 2026-10-20)

| Release | Scope |
|---|---|
| 1.1 | Portrait › Sunglasses (open issues: [v1.1/sunglasses-open-issues.md](v1.1/sunglasses-open-issues.md)); 1.0 polishes; Effects › Ink (scanned ink strokes) |
| 1.2 | Eraser (below) |
| 1.3 | Enhance (on-device upscale + face restore; descratch/colourise later) |
| 1.4 | Torn paper edges from photographed scans |
| 1.5 | Preset Lab Studio presets (mass bundle, needs heavy curation; moved from 1.2) |
| Last | VoiceOver and TalkBack pass on iOS and Android (owner, 2026-10-21: the last item, after the versions above; only 6629e86, hidden Auto / Reset all no longer read, landed in 1.0) |

Any 1.0 defect that needs a store fix before 1.1 still ships as 1.0.x from `release/1.0`.


### 1.1 — 1.0 polishes (listed 2026-10-13, status 2026-10-21)

| # | Polish | Status |
|---|---|---|
| 1 | Polaroid border: the floating Auto / "Reset all" buttons cover the Polaroid's bottom margin and signature | Fixed on iOS and Android (layout approved 2026-10-21: raise the print, shrink only as much as needed when it overlaps Auto + Reset all). Checked on iOS simulators (iPhone 11 Pro Max and SE sizes, light and dark). Verified on the physical iPhone SE 3 and iPhone 11 Pro Max, light mode, build 2021283 (261021001), group and boy photos. Dark mode on the phones verified 2026-11-05, build 1.1.0 (261102001), `PortraitBorderDeviceUITests`, light and dark: iPhone 11 Pro Max (print ends at y 392 pt, Auto and Reset all start at y 398) and iPhone SE 3 (print ends at y 197, buttons at y 203; the print shrinks as approved). Unverified: Android phones (not connected 2026-11-05), foldable/Duo/iPad |
| 2 | VoiceOver and TalkBack pass | Moved to the last release (owner, 2026-10-21); not part of 1.1 |
| 3 | Out-of-date iOS screen tests and screenshot baselines | Done 2026-11-02: the owner accepted all 11 references (rendered from 1aacdb4, iPhone 17 / iOS 26.5; side-by-side review `experiments/snapshot-review-2026-11-02/`, which adds the new `more-menu-dark`). `SliceOneSnapshotTests`: 14 run, 3 skipped by design (Privacy Policy "not available" and the two largest-text screens get no references), 0 failures. History: counted 2026-10-21 (unit tests, iPhone 17 / iOS 26.5): every suite passes except `SliceOneSnapshotTests`, all 14 failing against pre-Lightly-2 references (2026-10-03). Preferences baselines removed (c638760). App defects found by comparing against the mockup, fixed: favourite thumbnails with no photo open on iOS (359437f) and with or without a photo on Android (4318b84); Lightly 2 notes break lines like the mockup on iOS (fd230f5; Roboto on Android is accepted, owner 2026-10-21). Verified on simulators/emulator in light mode only: iPhone 16e and 11 Pro Max simulators (iOS), Pixel 9 Pro emulator at 412 dp (Android). Unverified: dark mode, larger text sizes, physical devices. Next: test fixtures to the mockup's state (saved signature on More, Lightly 2 sample signature, preset pack loaded), then re-record only matching references. Privacy Policy "not available" keeps its test but gets no reference until its design is approved. Largest text (AX5 revision 3, approved 2026-10-22): Welcome scrolls, keeps "Lightly" on one line and wraps padded button labels; Appearance shows rows when the three labels no longer fit as tiles. `AccessibilityAuditUITests` largest-text checks, build 8806ad71, iOS 26.5 simulators, AX3 + AX5: Welcome on iPhone 17 and SE 3 (light and dark) and More on iPhone 17 (light, dark) pass; More on SE 3 failed in light and dark (fixed, below): "Preferred border" breaks as "Preferre / d border" at AX5 (outside revision 3). Proposal approved visually 2026-10-22 (both themes): when the title's longest word no longer fits beside the value, the value moves under the title and the chevron stays at the right. Implemented (`L2ValueRow`). The 11 default-size screens render pixel-identical to before. Recovery screens ("This photo can't be opened", "Camera access is off"; they share Welcome's scroll fix), iPhone 17 and SE 3, AX3 + AX5, light and dark: scrolling, overlap, word breaks and every tap pass; button padding failed on both screens and both devices (fixed, below): wrapped labels such as "Choose another photo" and "Choose a photo instead" touch the capsule at AX3 and overflow it at AX5, and "Try again"/"Open Settings" come within 2 pt at AX5 (pre-existing; revision 3's label insets were approved for Welcome only). Owner 2026-10-22: show Welcome's padded, wrapping buttons on both recovery screens at AX3 and AX5 on both phone sizes before implementing. Shown 2026-10-22 (`experiments/recovery-buttons-proposal-2026-10-22/`, real simulator screenshots); on the proposal build AX3 passes everywhere, AX5 still fails where a label wraps to two lines and its line ends come within 0.4–3.3 pt of the capsule's rounded ends ("Choose another photo" on SE 3; "Choose a photo instead" on iPhone 17 and SE 3). Revision 2 (`experiments/recovery-buttons-proposal-r2-2026-10-22/`): a wrapped label's side inset grows until its lines' corners clear the curved ends by 6 pt; one-line labels unchanged. Both recovery screens pass on SE 3 and iPhone 17, AX3 + AX5, light and dark; Welcome passes and captures identical apart from the clock. The button check now measures to the drawn edge: SwiftUI's continuous capsule ends gave false 0 pt readings on tall buttons (real touching labels still fail, 0.08 and 1.5 pt). Approved 2026-10-22 (owner inspected the AX5 screenshots in both themes) and implemented. Final build fe6c31da, iOS 26.5 simulators, AX3 + AX5, light and dark: both recovery screens, Welcome and More (with Preferred border) pass on SE 3 and iPhone 17 (ten jobs); the 11 default-size screens render pixel-identical to before; the 11 references are unchanged (still pending the owner's review). Unverified: physical devices, other sizes |

Related platform work: Android R8 done (2a27f64; 1.0.1 on `release/1.0`). iPhone Duo: large-screen
capture done (bec3560); iOS 27 SDK build and App Store screenshots open.
The full 1.0 feature check on the review phones (iPhone 11 Pro Max, SE 3, moto edge 60) is still not done;
defects it finds go to 1.0.x from `release/1.0`.

### Tooling issues (tracked separately, found 2026-10-21)

| Issue | Status |
|---|---|
| `android/tools/capture/capture-batch.sh` `FAVS` lists five preset ids that are no longer in the Android catalogue; `MainActivity` drops unknown favourites at launch, so captures of the favourites screens show none | Fixed 2026-11-01: the script resolves the five ids from `presets/develop-design-ui.json` by category and stop (Portrait 13, Landscape 37, Film 12, Golden Hour 4, Black & White 3), as iOS `--seed-favourites` does |
| Android debug launch: `lightly.debug.appearance` (and other early preference updates) can write the preferences before the stored ones are in place, saving empty favourites over them; debug builds only | Not reproduced 2026-11-01 (Pixel 9 Pro emulator: favourites stored, then cold and warm launches with `lightly.debug.appearance` dark/light; the stored favourites stayed). The empty favourites seen on 2026-10-21 fit the stale ids above, which `MainActivity` drops at launch |
| iOS/Android row subtitles (`Text`, not notes) still wrap with the platform's standard strategy, e.g. iOS "Include location": "Off / by default." where the mockup has "Off by / default." | Fixed on iOS 2026-11-01 (d5f04a7, `L2RowSubtitle`); Android keeps Roboto's breaks (owner, 2026-10-21) |

## 1.2 — Eraser

Recorded 2026-10-05 from the owner's explicit request; moved from 1.1 to 1.2 by the owner on 2026-10-20. Target: iOS and Android.
Status: scheduled for 1.2; research recorded, detailed UX and implementation not approved or started.

Remove unwanted people, objects and distractions from a photograph, reconstructing
what belongs behind them rather than leaving transparency or a blurred patch.
Keep the user in the same editing session with their other edits intact.

See [Eraser research and proposed scope](v1.1/eraser.md).

### Relationship to 1.0

The approved 1.0 design already has Edit → Remove and an inpainting implementation.
The new Eraser request overlaps it. Record the reference-led Eraser work under 1.2;
do not start it as additional 1.0 work. This roadmap entry does not silently delete,
rename, disable or re-scope the existing approved Remove control. Before 1.2 design,
resolve whether Eraser upgrades that control or replaces it. Any change to the 1.0
release scope or approved screens must be recorded explicitly with the owner.

Existing 1.0 defects and acceptance checks remain in the implementation checklist.
