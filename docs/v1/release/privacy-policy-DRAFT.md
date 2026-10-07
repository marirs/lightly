> **Superseded 2026-10-05** by the website text (lightly.pro, `pub-sites/lightly/public/privacy.md`), which the apps now bundle. Kept for its sourced analysis only; see docs/v1/release/README.md.

# Lightly Privacy Policy

> **DRAFT FOR REVIEW. NOT LEGAL ADVICE. NOT FOR RELEASE until counsel and the owner approve it.**
> Every statement below describes Lightly 1.0 as built on 2026-10-04 (see "Basis" at the end). If the app changes, this text must change with it. `[OWNER: …]` marks details only the owner can supply. `[DECISION: …]` marks text that depends on an open release decision (see `dependencies.md`).

**Effective date:** [OWNER: effective date]
**Who we are:** Lightly is made by [OWNER: legal entity name], [OWNER: registered address] ("we"). Contact: [OWNER: privacy contact email].

## Summary
Lightly edits your photos on your device. You don't need an account. Lightly has no internet access of its own:
- it doesn't upload your photos;
- it doesn't send us information about you or how you use the app;
- it contains no analytics, advertising or tracking.

## Photos you choose
- You pick a photo with your device's own photo picker, or take one with the camera. Lightly can open only the photos you pick, and it never reads the rest of your library.
- All editing happens on your device: automatic correction, presets, background, portrait, edit and remove, effects, watermark and border.
- Your original photo is never changed.
  - **Save copy** adds a new photo to your library.
  - **Share** hands that saved copy only to the app or person you choose in your device's share sheet.
- *Android:* while a photo is open, Lightly keeps permission to read that one photo, so that it can restore your edit if Android closes the app. It gives up that permission when you discard the edit or open another photo.

## Permissions, and when Lightly asks for them
| Permission | When it is requested | What it is used for |
|---|---|---|
| Camera (iPhone/iPad and Android) | Only when you choose **Camera** | Taking a new photo to edit. On Android the photo is taken by your camera app and kept in Lightly's private storage, not added to your library. It is replaced by your next camera photo. |
| Add to Photos (iPhone/iPad, "add only") | The first time you choose **Save copy** | Saving the edited copy. Lightly can add photos but cannot read your library. |
| Photo library read access | **Never requested.** | The system photo picker gives Lightly only the photos you choose. |
| Storage or media permissions (Android) | **None.** | Saving uses Android's media store, which needs no permission for new photos. Lightly does not request "access media location". |

You can turn camera or photo access off at any time in your device settings.

## Photo information (metadata)
Photos can contain information such as the camera, lens, aperture, shutter speed, ISO, date taken and location. Two independent settings in **Preferences** control what saved and shared copies carry:
- **Keep photo metadata** (on by default) keeps the camera and capture details. It never includes location.
- **Include location** (off by default) copies the original photo's location, if it has one.

The same settings apply to Save copy and to Share. With both off, Lightly writes no optional information. It keeps only what is needed to display the picture correctly, such as its colour profile. A copy never inherits the original's thumbnail, orientation or maker notes.

*Android:* the system photo picker usually removes location from photos before apps receive them, and Lightly does not ask for permission to see it. So on Android, **Include location** can only copy a location that the photo still carries when Lightly receives it.

## Faces and people
*iPhone and iPad:*
- **Portrait** and **Background** use Apple's on-device Vision framework to find faces (their outline and features, such as eyes and lips) and people in the photo you are editing.
- Lightly uses this information only to apply the edits you choose.

*Android:* Lightly 1.0 does not detect faces. [DECISION: update if an Android face or person detector is added before release.]

On every platform:
- Lightly doesn't recognise who anyone is.
- It doesn't create face templates.
- It doesn't send face data anywhere.
- It doesn't use face data for advertising, marketing or profiling.
- Face information stays on your device. While an edit has unsaved changes, it is kept in the restore record described below, and it is deleted with that record.

## Depth and object removal
- **Background › Focus & Blur** estimates how far each part of the photo is from the camera.
- **Edit › Remove** fills in the areas you brush over.

Both use models that run on your device. [DECISION: keep this paragraph only if the depth and Remove models ship; see `dependencies.md` items 1 and 2.]

## Data stored on your device
> **Superseded for shipping (2026-10-07):** the text that ships is the website's `pub-sites/lightly/public/privacy.md`,
> bundled into both apps by `scripts/make_release_text.py`; its "Local storage" section states the recovery-data
> behaviour below in one paragraph per platform. Change that file, not this draft.

Lightly stores the following only on your device. Nothing is sent to us.

| What | Where | How long |
|---|---|---|
| Preferences: appearance, favourite presets, preferred border, the two metadata settings | App settings storage | Until you change them or delete the app |
| Your saved signatures (a drawn signature, and an imported signature with its paper removed) | App storage | Until you delete them in Preferences, or delete the app |
| Logo images you choose for a watermark | App storage | Until you delete the app |
| **Restore record** for the edit in progress, so you can pick up where you left off if the system closes Lightly (see below) | App storage | See below |
| Temporary files: the copy prepared for Share, and files used while saving | App temporary storage | Replaced by the next save or share; the system may clear them at any time |

**Restore record.**
- *iPhone and iPad:*
  - Contents: a copy of the photo being edited, your edit history, and the results the app computed for it (face and person positions, subject outline, depth).
  - It is kept only while the edit has unsaved changes.
  - It is deleted when you save a copy, discard the edit, close the photo or open another one.
  - It is excluded from iCloud and device backups, and protected by your device's encryption until you first unlock the device after a restart.
- *Android:*
  - Contents: your edit history, kept by Android for Lightly while the app is in your recent apps; the fills made by Remove; and a copy of the photo being edited, so a saved copy and a restored edit still work if the photo is deleted or moved meanwhile. The fills and the photo copy are kept in Lightly's private storage.
  - The photo copy is kept while the photo is open in Lightly, including after the system closes Lightly, so the edit can be restored.
  - They are deleted when you discard the edit, leave the editor, or open another photo, and the next time Lightly starts without an edit to restore (for example after you remove it from your recent apps).
  - Lightly also keeps permission to read the photo (see "Photos you choose").

**Backups.**
- *iPhone and iPad:* your preferences, signatures and logos may be included in your iCloud or computer backup, like other app data. The restore record is not.
- *Android:* Lightly opts out of Android's cloud backup. The copy of the photo being edited is kept where Android excludes it from both backups and device-to-device transfers. [DECISION: Android can still copy app data during a device-to-device transfer unless the app excludes it. Either exclude signatures and logos (engineering), or keep this sentence: "If you move to a new phone with a device-to-device transfer, your Lightly settings, signatures and logos may move with it."]

Deleting Lightly removes everything it stored.

## Analytics, advertising and tracking
Lightly 1.0 contains no analytics, crash-reporting, advertising or tracking code. It doesn't track you across apps or websites, and it doesn't sell or share personal information.

Your device maker or app store may offer to send crash reports or diagnostics. Those are governed by their own privacy policies and your device settings, not by Lightly. [COUNSEL: confirm this sentence.]

[OWNER: if crash reporting, analytics or any network feature is added before release, describe it here, and update both store declarations (`store-privacy-answers.md`).]

## Support
If you choose **Support** in About, Lightly opens your email app or web browser at [OWNER: support email or URL]. What you send is handled under this policy and [OWNER: describe how support emails are kept and for how long].

## Children
Lightly is not directed at children under [OWNER: minimum age, 13 or 16]. Lightly collects no personal information from anyone.

## Your rights
Because we receive no personal data from the app, we usually hold nothing about you. If you contact us, you can ask for access to, correction of or deletion of your messages at [OWNER: privacy contact email]. [COUNSEL: jurisdiction-specific rights wording (GDPR/UK GDPR, CCPA), and an EU/UK representative if one is required.]

## Changes
We will post any change to this policy in the app and on [OWNER: hosted policy URL], and update the effective date.

## Contact
[OWNER: legal entity name], [OWNER: postal address], [OWNER: privacy contact email]. If you are in the EU or UK: [COUNSEL/OWNER: EU/UK representative, if required].

---
### Basis (for reviewers; remove before release)
Verified in the code on 2026-10-04:
- **No networking.**
  - *Android:* the manifest declares only `android.permission.CAMERA`, with no `INTERNET` or `ACCESS_NETWORK_STATE`. `verify<Variant>ManifestPrivacy` (`android/app/build.gradle.kts`) fails every assemble if the merged manifest contains `INTERNET`, `ACCESS_NETWORK_STATE`, `datatransport`, `firebase`, `com.google.android.gms.measurement`, `analytics`, `telemetry` or `crashlytics`.
  - *iOS:* there is no `URLSession`, `URLRequest`, `Network` framework, `NWConnection`, web view, or any analytics or crash SDK in `ios/Lightly`.
  - The only outward actions on either platform are the system share sheet, opening Settings, and (once configured) the Support link (`mailto:` or `https:`), which the system opens in another app.
- **Permissions.**
  - *iOS:* `NSCameraUsageDescription` and `NSPhotoLibraryAddUsageDescription` only (`ios/project.yml`). Add-only authorisation is requested at save (`PhotoKitLibraryWriter.requestAddOnlyAuthorization`). Camera access is requested on Camera (`CameraAccess`). Selection uses `PhotosPicker`.
  - *Android:* `CAMERA` is requested on Camera (`MainActivity`). There is no `ACCESS_MEDIA_LOCATION` (`PlatformExifMetadata.kt`, which notes it is DEFERRED). The Photo Picker gives persistable read grants (`ContentResolverPhotoAccessGrants`), and saving uses MediaStore.
- **Metadata.** `ExportMetadataPolicy.default` (iOS) and `MetadataPolicy.DEFAULT` (Android) are keep-metadata **on** and include-location **off**. Both use an allowlist of camera, lens, exposure, ISO and date tags, and GPS only when location is on.
- **Restore.**
  - *iOS:* `EditSessionStore`: `Application Support/EditSession`, `isExcludedFromBackup`, `completeUntilFirstUserAuthentication`. It stores `original.bin`, the history, and `PersistedAnalysis` (faces with landmark polygons, subject matte, depth, person matte). It is cleared on no unsaved edits, close, discard or a new photo.
  - *Android:* `SavedStateHandle` key `editor.session.json`; `RemovePatchStore` in `filesDir/remove-patches`, cleared on a new photo.
- **Signatures and logos.** *iOS:* `SignatureStore` in `Application Support/Signatures`, **not** excluded from backup; there is no logo deletion path. *Android:* `filesDir/signatures`; `allowBackup="false"`, `targetSdk 36` (D2D caveat).
- **Not stated in the policy, and an engineering follow-up:** iOS Remove fills (`Application Support/RemovePatches`) are not excluded from backup. They are deleted when another photo is opened.
- **Faces on Android:** `SubjectSegmenter` and the person detector are stubs (D3), and Portrait is debug-only (`EditorTools.isImplemented`, commit 0083646).
- **Apple DPLA §3.3.3(K) Face Data** requires this policy to disclose the collection, use and sharing of face data. The "Faces and people" section does that.
