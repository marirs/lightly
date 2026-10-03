# Lightly Privacy Policy

> **DRAFT FOR REVIEW. NOT LEGAL ADVICE. NOT FOR RELEASE until counsel and the owner approve it.**
> Every statement below describes Lightly 1.0 as built on 2026-10-03 (see "Basis" at the end). If the app changes, this text must change with it. Fields in [BRACKETS] need owner input.

**Effective date:** [DATE]
**Who we are:** Lightly is made by [LEGAL ENTITY NAME], [REGISTERED ADDRESS] ("we"). Contact: [PRIVACY CONTACT EMAIL].

## Summary
Lightly edits your photos on your device. You don't need an account. We don't receive your photos or your edits, and the app doesn't send data about you to us.

## Photos you choose
- You choose a photo with your device's own photo picker or camera. Lightly can see only the photos you pick. It doesn't read the rest of your library.
- Lightly processes the photo on your device: automatic correction, presets, background, portrait, edit, effects, watermark and border.
- Your photo is not uploaded to us or to anyone else.
- Your original photo is never changed. When you choose Save copy, Lightly adds a new photo to your library. When you choose Share, the new copy goes only to the place you pick in your device's share sheet.

## Camera
Lightly uses the camera only when you choose Camera, after your device asks for your permission. You can turn camera access off in your device settings at any time.

## Photo information (metadata)
Photos can contain information such as the camera, lens, aperture, shutter speed, ISO, date taken and location. In Preferences:
- **Keep photo metadata** (on by default) keeps the camera and capture details in saved and shared copies. It never includes location.
- **Include location** (off by default) adds the photo's location to saved and shared copies.

The two settings are independent. With both off, Lightly removes optional information and keeps only what is needed to display the image correctly, such as its colour profile.

## Faces and people
Some tools, such as Portrait and Background, detect faces and people in the photo you are editing. This runs on your device. It is used only to apply the edits you choose.
- Lightly doesn't recognise who anyone is.
- It doesn't create or keep face templates.
- It doesn't send face data anywhere.
- Face and subject information exists only while you edit, and is discarded when you close the photo.

## Data stored on your device
Lightly stores, on your device only:
- your preferences: appearance, favourite presets, preferred border, and the two metadata settings;
- your saved signature, if you create one;
- a temporary record of the edit in progress, used to restore it if the app is interrupted.

Deleting the app removes them.

## Analytics, advertising and tracking
Lightly 1.0 contains no analytics, advertising or tracking. It doesn't use your data to track you across apps or websites.
[OWNER: if crash reporting or analytics are added before release, describe them here, and update the App Store privacy label and the Google Play Data safety form.]

[ANDROID: if the face-detection or segmentation component chosen for Android sends usage or diagnostic data to its provider, describe that here. This is under evaluation; see docs/v1/android-vision-evaluation.md.]

## Children
Lightly is not directed at children under [13/16 — OWNER].

## Changes
We will post any change to this policy in the app and update the effective date.

## Contact
[PRIVACY CONTACT EMAIL], [POSTAL ADDRESS]. If you are in the EU or UK: [EU/UK REPRESENTATIVE, IF REQUIRED].

---
### Basis (for reviewers; remove before release)
Verified in the code on 2026-10-03:
- **iOS:** `NSCameraUsageDescription` and `NSPhotoLibraryAddUsageDescription` only. There is no full-library read access, and no networking, analytics or crash SDK in `ios/Lightly`.
- **Android:** `CAMERA` is the only permission. There is no `INTERNET` permission and no analytics SDK.
- **Platform differences:** Android's photo access goes through the system Photo Picker with persistable read grants. Saving uses MediaStore with no storage permission.
- **To re-check before release:** any vision SDK added in slice 3 might add network access through manifest merging.
