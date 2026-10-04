# Store privacy declarations: proposed answers (DRAFT)

> **DRAFT FOR REVIEW.** These answers describe Lightly 1.0 as built on 2026-10-04. They hold only while the conditions below hold. If any condition changes, re-answer both forms.

**Conditions:**
- no networking code on iOS;
- no `INTERNET` permission on Android (the manifest privacy check passes);
- no analytics, crash or ads SDK on either platform;
- no Android vision SDK added with its Google telemetry left in (`dependencies.md` item 3).

Definitions relied on (accessed 2026-10-04):
- Apple: data "processed only on device is not 'collected'". https://developer.apple.com/app-store/app-privacy-details/
- Google Play: "Collect" means "transmitting data from your app off a user's device". Data "only processed locally" need not be disclosed. https://support.google.com/googleplay/android-developer/answer/10787469

## App Store Connect: App Privacy ("nutrition label")

| Question | Answer | Why |
|---|---|---|
| Do you or your third-party partners collect data from this app? | **No, we do not collect data from this app** | Photos, face data, depth, signatures, logos and preferences are processed and stored only on the device. The app makes no network requests. |
| Resulting label | **Data Not Collected** | — |
| Tracking (ATT) | **No.** The app does not track. | There is no IDFA, no SDKs and no data linking. |
| Privacy Policy URL | [OWNER: hosted privacy policy URL] | Required for all apps (Guideline 5.1.1(i)). |
| Support URL (App Information) | [OWNER: support URL] | — |

Also required for submission, but not part of the label:
- **Privacy manifest:** `PrivacyInfo.xcprivacy` with:
  - `NSPrivacyTracking` = false;
  - `NSPrivacyTrackingDomains` empty;
  - `NSPrivacyCollectedDataTypes` empty;
  - `NSPrivacyAccessedAPITypes`: `NSPrivacyAccessedAPICategoryUserDefaults`, reason `CA92.1`.
  - This is missing today; it is an engineering task (`dependencies.md`, "Other release dependencies").
- **Face Data:** the privacy policy must describe it (DPLA §3.3.3(K)). The draft does.
- **Age rating questionnaire:** no user-generated content is shared through the app, no web access, no ads. [OWNER: confirm.]

## Google Play Console: Data safety

| Question | Answer | Why |
|---|---|---|
| Does your app collect or share any of the required user data types? | **No** | Nothing leaves the device. There is no `INTERNET` permission, which the build check enforces. |
| Is all user data collected by your app encrypted in transit? | Not shown (no data collected) | — |
| Do you provide a way for users to request that their data is deleted? | Not shown (no data collected) | Deleting the app removes all local data. |
| Resulting section | **No data collected · No data shared** | — |
| Privacy policy URL | [OWNER: hosted privacy policy URL] | Required even for apps that collect no data. |

Other Play Console declarations to check at the same time:
- **Permissions:** `CAMERA` only. The Photo Picker and MediaStore need no declaration. There is no `ACCESS_MEDIA_LOCATION`.
- **Ads:** no. **Target audience:** [OWNER: minimum age]. **Health/financial/government:** none.

## What would change these answers
| Change | iOS label | Play Data safety |
|---|---|---|
| ML Kit (bundled or unbundled) for faces or segmentation | "Diagnostics / Other diagnostic data, not linked, not tracking" (Google's metrics) | "App activity / Other actions" or "Diagnostics", collected, shared with Google |
| MediaPipe with datatransport kept | same as above | same as above |
| Crash reporting or analytics | Diagnostics (crash, performance) | Crash logs and diagnostics |
| Support form inside the app (instead of mailto/browser) | Contact info (email), linked | Personal info (email), collected |
| Model download on first use (instead of bundling) | none if nothing about the user is sent and kept; [COUNSEL: confirm] | same |
