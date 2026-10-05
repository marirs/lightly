# Release content: what is needed and the proposals

The app shows the Privacy Policy, Terms of Use, About (version and build) and Support. Placeholders must not ship. Until approved text exists, the screens show "This document isn't available in this build." Implementing and testing the screens does not wait on the text.

## Drafts for review
| File | What it is |
|---|---|
| `dependencies.md` | Sourced terms register: code, weights and training-data terms, plus the people and privacy questions. Covers the depth and Remove models, the Android vision candidates, Apple Vision, LiteRT, the fonts, the Unsplash backgrounds, sample photos and the preset catalogue. It ends with a status table. |
| `privacy-policy-DRAFT.md` | Written from the app's actual behaviour, verified in code on 2026-10-04: no network access, picker-only photo access, the permissions and when each is requested, the two metadata switches and their defaults, the restore record, signatures and logos, and no analytics. |
| `terms-of-use-DRAFT.md` | Skeleton, plus a Notices section (the licence notices and photo credits). The legal clauses are left to counsel. |
| `store-privacy-answers.md` | Proposed App Store privacy label ("Data Not Collected") and Google Play Data safety ("No data collected / shared") answers, the conditions they depend on, and what would change them. |

## Release blockers found in the register
1. **Presets (item 9).** All 2,591 shipped presets trace to purchased third-party packs (SolutionPresets, Huliluts, WithLuke). No redistribution licence is on file. Some preset names use the Kodak, Portra and Polaroid marks.
2. **Depth and Remove models (items 1–2).** Counsel's sign-off is needed before the release gates are switched on.
3. **Android vision SDK (item 3).** Every candidate SDK merges in Google telemetry, which would contradict the privacy text and both store answers.
4. **Background photos (item 7).** iOS ships them in release; Android ships them in debug only. The owner decides.
5. **iOS privacy manifest.** It is missing (UserDefaults, a required-reason API).

## Owner details still needed
Only these are missing. Every draft marks them `[OWNER: …]`.

Status 2026-10-05: the domain is known (`lightlylabs.app`, product spec §header; company name "Lightly Labs"). The website's legal drafts could not be reused: `https://lightlylabs.app` refused the connection, and no website source is in this workspace. Needed from the owner: the website's Privacy Policy and Terms text (or their location), and the contact email. The drafts here stay as they are until then.

| Detail | Used in |
|---|---|
| Legal entity name | Privacy Policy, Terms, store listings |
| Contact: privacy email and postal address | Privacy Policy, Terms |
| Jurisdiction (place of incorporation; governing law and venue) | Terms, and the rights section of the Privacy Policy |
| Effective date | both documents |
| Support URL or email, and whether the app opens it with mailto or a browser | About › Support, Terms, store listings |

Also needed before submission, though not legal text: the hosted URLs of the policy and terms; the minimum-age statement; the pricing model (free, Pro subscription or lifetime; spec §0.3); and whether an EU/UK representative is required (counsel).

## Proposed version and build scheme
- **Marketing version** (iOS `CFBundleShortVersionString`, Android `versionName`): semantic `MAJOR.MINOR.PATCH`, the same on both platforms. 1.0.0 is the first release.
- **Build** (iOS `CFBundleVersion`, Android `versionCode`): one monotonically increasing integer shared by both platforms, in the form `YYMMDDNN`. For example, 26100301 is the first build on 3 Oct 2026. It fits within Android's `versionCode` limit (2,100,000,000) until 2099.
- **Shown in About as:** "Version 1.0.0 (26100301)". Both values come from the build settings, never from hard-coded text.
- **Source of truth:** one file in the repo (for example `version.properties` at the root), read by both the Xcode project and Gradle. A release commit is tagged `v1.0.0+26100301`.
