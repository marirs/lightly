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
| 1 | Polaroid border: the floating Auto / "Reset all" buttons cover the Polaroid's bottom margin and signature | Fixed on iOS and Android (layout approved 2026-10-21: raise the print, shrink only as much as needed when it overlaps Auto + Reset all). Checked on iOS simulators (iPhone 11 Pro Max and SE sizes, light and dark). Verified on the physical iPhone SE 3 and iPhone 11 Pro Max, light mode, build 2021283 (261021001), group and boy photos. Unverified: dark mode on the phones, Android (no phone connected), foldable/Duo/iPad |
| 2 | VoiceOver and TalkBack pass | Moved to the last release (owner, 2026-10-21); not part of 1.1 |
| 3 | Out-of-date iOS screen tests and screenshot baselines | In progress. Counted 2026-10-21 (unit tests, iPhone 17 / iOS 26.5): every suite passes except `SliceOneSnapshotTests`, all 14 failing against pre-Lightly-2 references (2026-10-03). Preferences baselines removed (c638760). App defects found by comparing against the mockup, fixed: favourite thumbnails with no photo open on iOS (359437f) and with or without a photo on Android (4318b84); Lightly 2 notes break lines like the mockup on iOS (fd230f5; Roboto on Android is accepted, owner 2026-10-21). Verified on simulators/emulator in light mode only: iPhone 16e and 11 Pro Max simulators (iOS), Pixel 9 Pro emulator at 412 dp (Android). Unverified: dark mode, larger text sizes, physical devices. Next: test fixtures to the mockup's state (saved signature on More, Lightly 2 sample signature, preset pack loaded), then re-record only matching references. Privacy Policy "not available" keeps its test but gets no reference until its design is approved |

Related platform work: Android R8 done (2a27f64; 1.0.1 on `release/1.0`). iPhone Duo: large-screen
capture done (bec3560); iOS 27 SDK build and App Store screenshots open.
The full 1.0 feature check on the review phones (iPhone 11 Pro Max, SE 3, moto edge 60) is still not done;
defects it finds go to 1.0.x from `release/1.0`.

### Tooling issues (tracked separately, found 2026-10-21)

| Issue | Status |
|---|---|
| `android/tools/capture/capture-batch.sh` `FAVS` lists five preset ids that are no longer in the Android catalogue; `MainActivity` drops unknown favourites at launch, so captures of the favourites screens show none | Open |
| Android debug launch: `lightly.debug.appearance` (and other early preference updates) can write the preferences before the stored ones are in place, saving empty favourites over them; debug builds only | Open |
| iOS/Android row subtitles (`Text`, not notes) still wrap with the platform's standard strategy, e.g. iOS "Include location": "Off / by default." where the mockup has "Off by / default." | Open, not yet scoped |

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
