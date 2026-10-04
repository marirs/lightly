# Decision sheet 1: assets, transfer and logos

Three decisions. Until you decide, the approved UX stays exactly as it is.

## 1. Background photos (Background › Change background › Image)

- **Today:** four Unsplash photos (landscape_01, sunset_03, wellexposed_02, backlit_02).
  - iOS ships them in release builds.
  - Android ships them only in debug builds, so its release builds show no image swatches.
  - The Unsplash License permits bundling them in an app and doesn't require credit. It forbids compiling Unsplash photos into a similar or competing service. backlit_02 shows a woman from behind; her face isn't visible.
- **Recommendation:** ship all four on both platforms, and credit the photographers in the Terms "Notices" section, which already exists. No screen changes.
- **UX impact:**
  - With the recommendation: Android release builds gain the approved image swatches, matching the approved `bg-change-image` screen. Today they're missing.
  - If you'd rather replace backlit_02: one swatch thumbnail changes, so the approved screen would show a different photo. That needs your approval of the replacement image.

## 2. Android device-to-device transfer (Android 12 and later)

- **Today:** the app disables cloud backup. Android still copies app files when a user moves to a new phone with a cable or Quick Switch, including saved signatures, saved logos and any interrupted edit session.
- **Recommendation:** exclude the edit-session folder from transfer (it's temporary and may hold face data), and let signatures and logos transfer (they're the user's own content). State both in the privacy policy, which already discusses local storage.
- **UX impact:** none. Data-extraction rules aren't visible in the UI.

## 3. Deleting a saved logo

- **Today:**
  - Watermark › Logo lets you import a logo, which is stored locally.
  - The approved design has no way to delete it: no screen in `docs/ui/app/` offers one, and Preferences covers only the signature.
- **Recommendation:** add no new UI for 1.0. Importing a new logo replaces the stored one (one logo is kept), and the old file is deleted at that moment. The privacy policy says so. A visible "Delete logo" control would need a design.
- **UX impact:** none with the recommendation. A delete control would add a row to Preferences or the Logo panel, which is a design change for you to approve.

Reply with "approve 1/2/3" or with changes.
