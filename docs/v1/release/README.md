# Release content: what is needed and the proposals

The app shows the Privacy Policy, Terms of Use, About (version and build) and Support. Placeholders must not ship. Until approved text exists, the screens show "This document isn't available in this build." Implementing and testing the screens does not wait on the text.

## Source of the release text (2026-10-05)
- **Domain** `lightly.pro`; **contact and support** `hello@lightly.pro` (owner, 2026-10-05). The earlier note that named `lightlylabs.app` (from the product spec) is withdrawn.
- **Text:** the website's own pages, `/Users/sg/Documents/Dev/pub-sites/lightly/public/privacy.md` and `terms.md` ("Last updated · 5 October 2026"). `scripts/make_release_text.py` copies them unchanged into both apps' Legal screens (`ios/Lightly/Resources/Content/legal.json`, `android/app/src/main/assets/legal/release-text.json`) and sets Support to `mailto:hello@lightly.pro`; only page decoration is dropped. Re-run it whenever the website text changes.
- **Not legal approval.** These are drafts that the owner published; counsel review is still open (below).
- `privacy-policy-DRAFT.md` and `terms-of-use-DRAFT.md` here are superseded by the website text; they are kept only for their sourced analysis (permissions, notices).

## The website text against the app's behaviour (checked 2026-10-05)
Consistent with the code: on-device processing with no upload, account, advertising or analytics; system picker or camera; Android keeps access to a chosen photo for restore; faces, subjects and depth analysed locally without identifying anyone, kept only with an unfinished edit; the two metadata switches (location off by default, only when the photo carries it) for saved and shared copies; local storage of preferences, favourites, signatures, logos and recovery data; Save copy as a new image; Share through the system sheet.

## Unresolved clauses and missing owner details (one list)
1. **Who "we" are.** Neither page names the operator (legal entity or person) or a postal address. The App Store and Google Play listings need a seller/developer name. Not invented here.
2. **Terms point to themselves.** "Use the app in accordance with applicable law and the terms supplied with its release": in the app these pages *are* the release terms. Reword, or state whether Apple's standard EULA applies on iOS.
3. **Governing law, jurisdiction, warranty and liability.** None stated (only the consumer-rights saving clause). Counsel.
4. **Minimum age.** Not stated; the store forms ask for it.
5. **Licence notices.** The Terms say third-party fonts and photographs keep their licences, but the app has no Licences/Notices screen. The bundled fonts (OFL) and models (Apache-2.0) need their notices delivered somewhere the owner approves (an approved screen or the website).
6. **Purchases.** "No purchase or subscription is offered on this website": the app's pricing (free, subscription or lifetime; spec §0.3) is still undecided, and the Terms need a clause once it is.
7. **EU/UK representative** and any other regional requirement: counsel.
8. **Hosted URLs** for the store listings: `https://lightly.pro/privacy`, `/terms`, `/support` (live? the site is not reachable from this machine's checks; confirm deployment).

## Release blockers in the terms register (`dependencies.md`), status 2026-10-05
1. **Presets (item 9):** all 2,591 shipped presets trace to purchased third-party packs (SolutionPresets, Huliluts, WithLuke) with no redistribution licence on file; some names use the Kodak, Portra and Polaroid marks. Open.
2. **Model training data (items 1–2, Android vision):** Depth Anything, LaMa (Places2), MODNet and U²-Netp (DUTS-TR) stay behind release gates until counsel signs off. Open.
3. **Android vision SDK telemetry (item 3):** resolved by running the MediaPipe models on LiteRT without MediaPipe Tasks (no telemetry, no INTERNET permission; checked on every build).
4. **Background photos (item 7):** iOS ships them in release, Android in debug only. Owner decision open.
5. **iOS privacy manifest:** added (1e9a526).

## Proposed version and build scheme
- **Marketing version** (iOS `CFBundleShortVersionString`, Android `versionName`): semantic `MAJOR.MINOR.PATCH`, the same on both platforms. 1.0.0 is the first release.
- **Build** (iOS `CFBundleVersion`, Android `versionCode`): one monotonically increasing integer shared by both platforms, in the form `YYMMDDNN`. For example, 26100301 is the first build on 3 Oct 2026. It fits within Android's `versionCode` limit (2,100,000,000) until 2099.
- **Shown in About as:** "Version 1.0.0 (26100301)". Both values come from the build settings, never from hard-coded text.
- **Source of truth:** one file in the repo (for example `version.properties` at the root), read by both the Xcode project and Gradle. A release commit is tagged `v1.0.0+26100301`.
