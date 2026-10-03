# Slice 1 review package: entry, selection, More, Preferences, export metadata

- **Reference:** approved `docs/ui/app/` (approved revision ff5c5ae, canonical at 0352972), reviewed under `docs/ui/REVIEW-RULES.md`.
- **Status:** implemented and tested on both platforms. **No screen is exact-match verified yet.** Every captured comparison shows at least one difference (below), and part of the device matrix has not been captured.

## Commits
| Platform | Commits |
|---|---|
| iOS | 995dae7 audit · 407769f metadata switches in Save copy · 5567f23 Welcome, recovery, More, Preferences, stores, launch, iPhone portrait-only · e3b1f4f, 2c08d17 snapshot baselines · 7cce235 notes |
| Android | ad71805 metadata switches in Save copy · 16a502e entry, More, Preferences, camera, orientation policy · ba5449c layout corrections from the emulator comparison |
| Shared/docs | ff5c5ae design freeze · fe57df1 checklist and plan · 7156cc3 release drafts · 65c36ce mandatory exact-UX rules |

- **Known incident:** 9a63809, a test-photo commit, accidentally included the iOS agent's staged deletions of the old launch files. iOS did not build from 9a63809 through 407769f; it builds again from 5567f23. Every commit now uses an explicit pathspec.

## Tests (re-run by the coordinator where noted)
- **iOS (re-run by the coordinator):**
  - Unit: 397 passed, 0 failed.
  - UI: 20 tests; 15 passed, 5 skipped (camera captures, which need a camera), 0 failed.
  - App icon packaging check passes.
- **Android (agent run):** 283 test executions, 0 failures. Debug and release APKs build, and both launcher-icon checks pass.
- **Metadata, all four combinations, checked on saved JPEG bytes (both platforms):**
  - Keep metadata copies capture fields only.
  - Include location copies GPS only.
  - Both off removes optional metadata.
  - In every combination the colour profile is kept, and no stale dimensions, orientation or thumbnail are written.

## Comparison evidence
| Platform | Location | Captured | Not captured (unverified) |
|---|---|---|---|
| iOS | `~/.codex/artifacts/lightly/v1/slice1/ios/<device>-<orientation>-<theme>-<text>/<screen>.png` | iPhone 17 portrait; iPad Pro 11" and 13" in portrait and landscape; light and dark; default and large text (about 300 pairs) | iPhone 17 Pro Max (large phone) |
| Android | `~/.codex/artifacts/lightly/v1/slice1/android/side-by-side/` | Pixel 9 Pro; Fold inner in portrait and landscape; 4 theme/text variants each | Pixel 10 Pro XL (large phone), Fold outer (folded), Pixel Tablet in portrait and landscape. The machine was overloaded and the emulator kept restarting |

System UI (picker, camera, permission dialogs) is shown only as real flows on Pixel 9 Pro, and is not captured on the iOS simulator.

## Mismatches against the approved design (need correction or explicit approval)
| # | Platform | Screen(s) | Approved | Implemented |
|---|---|---|---|---|
| 1 | both (inconsistent) | Preferences, Legal, About and sub-pages on phones | Screen index: full pages. Interactive flow: pages inside the More sheet | iOS keeps them in the sheet; Android shows full pages. **Your decision:** which one is approved? |
| 2 | both | privacy, terms | Placeholder text bars | "This document isn't available in this build." (no text has been approved yet, D2) |
| 3 | both | support | Contact support button | No button, because there is no destination yet (D2) |
| 4 | both | about | "Version 1.0 (1)" | Real build values (iOS "1.0 (1)", Android "0.1.0-m2 (1)"). The scheme is proposed in docs/v1/release/README.md |
| 5 | both | pref-signature | A saved signature with Draw/Import/Delete | Empty state; Draw/Import arrive in slice 5 |
| 6 | Android | welcome, message screens on Fold inner | Brand and actions near the top of each pane | Vertically centred (Welcome); message text centring fixed in ba5449c, recapture pending |
| 7 | Android | headings at large text | ×1.24 scaling | Android scales large headings less |
| 8 | Android | launch | Mark centred | Splash mark about 24 dp higher (system splash geometry) |
| 9 | iOS | tablet More form sheet | Prototype position | About 9 pt higher (the system centres form sheets) |
| 10 | both | more (from the editor) | New editor behind the sheet | Old editor until slice 2 |
| 11 | both | message screens | Icon drawn at the leading edge (looks unintended in the prototype) | Matched as drawn. Confirm whether it should be centred |

Platform-drawn differences that are not layout changes: status and navigation bars, sheet corner radius and dimming, the system picker, the camera and its permission dialogs. On Android 16, the picker needs "Done" after selecting a photo.

## Not yet working or limited
- **Android EXIF LensModel:** not copied. The platform ExifInterface cannot write it; androidx.exifinterface would be a new dependency.
- **Android location from picked photos:** the system removes GPS unless the app holds ACCESS_MEDIA_LOCATION. Whether to request it is a product decision.
- **Share:** not built yet (slice 5). Only Save copy has the metadata policy so far.
- **Camera capture and review:** not verifiable on simulators. They need a device run.

## Decisions needed from you
1. Mismatch 1: More pages on phones, sheet or full page?
2. Mismatches 2–4: approve the interim "not available" wording until the release text exists, or provide the text.
3. Mismatch 11: centre the message-screen icon?
4. Android ACCESS_MEDIA_LOCATION for "Include location" on picked photos.
