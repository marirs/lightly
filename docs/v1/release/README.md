# Release content: what is needed and the proposals

The app shows the Privacy Policy, Terms of Use, About (version and build) and Support. Placeholders must not ship. Until approved text exists, the screens show "This document isn't available in this build." Implementing and testing the screens does not wait on the text.

## Drafts for review
- `privacy-policy-DRAFT.md`: written from the app's actual behaviour as verified in code (no account, on-device processing, picker-only photo access, two metadata switches, local storage only, no analytics). Marked as a draft for review.
- `terms-of-use-DRAFT.md`: a skeleton. Legal clauses are left to counsel.

## Owner and contact details needed
| Item | Used in |
|---|---|
| Legal entity name and registered address | Privacy Policy, Terms, store listings |
| Privacy contact email (and postal address) | Privacy Policy |
| Support destination: an email address or a support web page URL, and whether the app opens it with mailto or a browser | About › Support, store listings |
| EU/UK representative, if required | Privacy Policy |
| Minimum age statement | Privacy Policy, age ratings |
| Governing law and venue; standard Apple EULA or a custom one | Terms |
| Pricing model (free, Pro subscription, lifetime; spec §0.3) | Terms, store listings |
| Effective date | both |
| Hosted URLs for the policy and terms (stores require public URLs) | App Store Connect, Google Play Console |

## Proposed version and build scheme
- **Marketing version** (iOS `CFBundleShortVersionString`, Android `versionName`): semantic `MAJOR.MINOR.PATCH`, the same on both platforms. 1.0.0 is the first release.
- **Build** (iOS `CFBundleVersion`, Android `versionCode`): one monotonically increasing integer shared by both platforms, `YYMMDDNN`, for example 26100301 for the first build on 3 Oct 2026. It fits within Android's `versionCode` limit (2,100,000,000) until 2099.
- **Shown in About as:** "Version 1.0.0 (26100301)". Both values come from the build settings, never from hard-coded text.
- **Source of truth:** one file in the repo (for example `version.properties` at the root), read by both the Xcode project and Gradle. A release commit is tagged `v1.0.0+26100301`.
