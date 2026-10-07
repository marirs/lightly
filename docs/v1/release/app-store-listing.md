# App Store submission materials: iOS (DRAFT, 2026-10-07)

> **DRAFT FOR REVIEW.** Written from what the 1.0 build does (code and the website text it bundles). Nothing here is
> submitted, uploaded or entered in App Store Connect. **[OPEN]** marks facts only the owner can supply; they are not
> guessed. Text that depends on an open approval is marked **[IF …]**.

## App Store Connect record
| Field | Draft | Status |
|---|---|---|
| Name (≤ 30) | Lightly: Photo Editor (21) | Name availability in App Store Connect not checked (needs the account) |
| Subtitle (≤ 30) | Presets, portraits, backdrops (29) | Draft |
| Bundle ID | com.lightlylabs.lightly | Explicit App ID not yet registered (see Signing) |
| SKU | lightly-ios-1 | Draft (internal only) |
| Primary language | English (U.K.) | **[OPEN]** the app's strings are one "en" localisation in British spelling ("colour"); confirm U.K. or U.S. |
| Category | Photo & Video (secondary: none) | Draft |
| Price | **[OPEN]** pricing | Owner fact (`legal-proposals.md` §2) |
| Availability (countries) | **[OPEN]** | Owner decision; counsel's model answers name markets |
| Copyright | © 2026 **[OPEN: operator name]** | Owner fact |
| Age rating | Questionnaire answers: no objectionable content, no web access, no user-generated content shared through the app, no ads → expected 4+ | **[OPEN]** the minimum age in the Terms is a separate owner fact |
| Support URL | https://lightly.pro/support | Live page |
| Marketing URL | https://lightly.pro | Live page |
| Privacy Policy URL | https://lightly.pro/privacy | Live; the local-storage update awaits deploy approval (Website, below) |
| App Privacy label | Proposed "Data Not Collected", no tracking (`store-privacy-answers.md`) | **[OPEN]** owner confirmation; the privacy manifest exists (`ios/Lightly/Resources/PrivacyInfo.xcprivacy`) |
| Version / build | 1.0.0 (build from `scripts/version.sh`, e.g. 261007053) | Engineering |

## Promotional text (≤ 170)
Edit colour, portraits, backgrounds, effects, a watermark and a border on one photo, on your device. Save a new copy
when it feels right. (137)

## Description (≤ 4,000)
Lightly is a photo editor for iPhone and iPad that keeps every edit together on one photograph, from colour and
portrait detail to backgrounds, effects and your signature. Everything happens on your device: there is no Lightly
account, no upload, no advertising and no analytics.

DEVELOP
Find a look for portraits, landscapes and everything between. Browse presets by category, set their strength, star
your favourites and compare with the original at any time. Auto gives the photo a balanced starting point.

PORTRAIT
When a face is detected, refine skin, under-eyes, eyes, teeth and hair, separately for each person in a group.

BACKGROUND
Let the subject lead. Replace the backdrop with a colour, a gradient or a photo, and refine the edge with a brush.
[IF depth model approved:] Add depth-aware Focus & Blur, with soft, swirl and motion styles.

EDIT
Crop, rotate, straighten and correct perspective. Adjust light, colour and detail.
[IF Remove model approved:] Brush over a distraction and Remove fills the area.

EFFECTS
Add a light leak, grain and vignette, or keep chosen colours with Selective Colour and turn the rest black and white.

WATERMARK AND BORDER
Draw or import your signature, set your name in type or add a logo, on the photo or its border. Choose a simple
border, a photo frame or an instant-photo-style frame.

MADE FOR THE WAY YOU HOLD IT
Designed for iPhone and iPad (iPad in portrait and landscape). Undo, Redo and the original are always close at hand.

YOUR PHOTOS STAY YOURS
Choosing a photo uses Apple's own picker, so Lightly never reads your library. Save copy writes a new photo and leaves
the original untouched, with separate controls for photo metadata and location.

Not stated, because they are not established: "every" preset count (depends on the preset-rights answer), camera
speed or quality claims, and any comparison with other apps.

## Keywords (≤ 100, comma-separated, no spaces)
`presets,filters,portrait,background,blur,retouch,watermark,signature,border,grain,film,vignette` (95)
Words in the name and subtitle ("photo", "editor", "presets") are not repeated where Apple already indexes them; "presets"
stays because the subtitle may change. "remove" and "bokeh" are left out until the two models are approved.

## App Review notes (draft)
- No account, no sign-in, no network access: every feature works offline, on device. There are no in-app purchases
  **[OPEN: pricing; update if any]**.
- To review: tap "Choose a photo" (system picker, no library permission) or "Camera" (camera permission asked only
  then). Any photo works; Portrait tools need a photo with a visible face. Background separates the main subject
  on device (Apple Vision). [IF approved:] Focus & Blur and Edit › Remove use on-device models bundled in the app.
- Save copy asks for add-only Photos access the first time and writes a new image; the original is never changed.
- Face data: faces are detected on device only to place the Portrait controls; nothing is stored after the edit ends
  or sent anywhere (Privacy Policy, "Faces, subjects and depth").
- Contact: hello@lightly.pro. **[OPEN: reviewer phone number and name for App Store Connect]**

## Screenshot capture route (prepared, not run: bulk capture automation is paused)
Requirements (App Store Connect, current): iPhone 6.9" set (1320 × 2868, portrait) and iPad 13" set (2064 × 2752).
Smaller sizes are derived by Apple. Up to 10 per set; 3–6 is enough.
- **Devices:** simulators "iPhone 17 Pro Max" (4F045805…) and "iPad Pro 13-inch (M5)" (18517D41…), light appearance,
  default text size, status bar overridden to 9:41 with full battery (`xcrun simctl status_bar … override`).
- **Build:** the shipping configuration. Screens that show Focus & Blur or Remove are captured only if those gates
  are open in the submitted build; otherwise they are left out (the store must not show features the build lacks).
- **Tool:** the existing `EditorCaptureUITests` (approved-screen states through `--scenario`, prototype photos from
  `docs/ui/assets/photos/`, rights-cleared), limited with `LIGHTLY_CAPTURE_ONLY`, one run per device through
  `scripts/heavy`, when the owner lifts the capture pause. No new capture tooling.
- **Proposed set (approved screen ids):** `welcome`, `dev-preset`, `pt-skin`, `bg-change-colour`,
  [IF depth approved] `bg-focus`, [IF Remove approved] `ed-remove`, `fx-combined`, `wm-signature`, `bd-polaroid`.
- **Checks before upload:** each image compared with its approved reference (`docs/ui/app/`), no debug UI, no
  unapproved difference visible; captions (if any) are an owner decision. Preset names shown must be ones the
  preset-rights answer allows.

## Signing (prepared; distribution signing not run; needs the owner's approval)
Checked on this Mac, 2026-10-07:
- Keychain identities: "Apple Development: Sriram Govindan (LZL4D9L363)", "Apple Development: … (TR63B6VCA3)",
  "Developer ID Application: … (3UDFB78DLC)". **No Apple Distribution identity** (private key) on this Mac.
- The account has an **Apple Distribution certificate for team 3UDFB78DLC** (valid until 8 Jun 2027): it is referenced
  by the existing App Store profile for another app (com.travllr). Its private key is not here: it is either
  Xcode-managed (cloud) or on another Mac.
- Lightly's archives are signed with the wildcard development profile "iOS Team Provisioning Profile: *"
  (3UDFB78DLC.*); **no explicit App ID and no App Store profile exist for com.lightlylabs.lightly**.

Account changes actually required for an App Store export:
1. Register the explicit App ID `com.lightlylabs.lightly` (no extra capabilities: the app uses none).
2. An App Store provisioning profile for it (Xcode creates "iOS Team Store Provisioning Profile: com.lightlylabs.lightly"
   with `-allowProvisioningUpdates`).
3. Distribution signing: Xcode's cloud-managed distribution signing (needs an Admin or Account Holder role; creates no
   local key), **or** a new Apple Distribution certificate made on this Mac if the existing one is not cloud-managed.
4. For upload later (not part of export): the App Store Connect app record (name, bundle ID, SKU, language).
The export itself would be `xcodebuild -exportArchive` with method `app-store-connect` and `destination export`
(write an .ipa locally; nothing uploaded).

## Website (prepared; commit and deploy not run; needs the owner's approval)
- **Repository and target:** `/Users/sg/Documents/Dev/pub-sites/lightly` (git@github.com:marirs/pub-sites.git), deployed
  with `./deploy.sh` → `wrangler deploy` to the Cloudflare Worker `lightly-web`, custom domains `lightly.pro` and
  `www.lightly.pro`.
- **Source of the page:** `scripts/build.mjs` (the `privacy` section array); `public/privacy.html`, `privacy.md` and
  `llms-full.txt` are generated from it. The earlier edit to `public/privacy.md` alone would have been overwritten by
  the deploy's build and never reached the served HTML; it is now made in `build.mjs` and rebuilt (`npm run check`:
  PASS, 7 pages).
- **Change:** "Last updated" 5 → 7 October 2026 on the privacy page only (Terms keeps 5 October); "Local storage"
  rewritten to describe recovery data per platform, when it is deleted, and its exclusion from backups and
  device-to-device transfers. Identical to the text already bundled in both apps (re-generated, no diff).
- **Diff:** `~/.codex/artifacts/lightly/v1/website-privacy-2026-10-07.diff`.
