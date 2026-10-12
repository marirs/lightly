# Lightly 1.0 for Google Play: everything needed to publish

## App files (folder `app/`)
- **Upload this:** `Lightly-1.0.0-261012020.aab` (Android App Bundle). Signed with the owner's upload key.
- `Lightly-1.0.0-261012020.apk`: the same build as an APK, for testing on a phone only. Do not upload it.
- Package name: **com.lightlylabs.lightly** (fixed, cannot change after the first upload)
- Version name **1.0.0**, version code **261012020**
- Minimum Android 10 (API 29), target API 36
- **Play App Signing:** keep it on (Google manages the app signing key). Upload key certificate SHA-256:
  `2B:84:EC:45:58:52:67:FB:17:4B:2E:2A:B9:05:58:F2:A0:7D:32:DE:77:E2:49:80:41:52:62:5A:6E:C4:72:A1`

## Store listing
- **App name (30):** Lightly: Photo Enhancer
- **Short description (80):** Presets, portrait tools, background blur and your signature. Edits on device.
- **Full description:**

```
A little edit. A different feeling.

Lightly is a photo editor for bringing out the light and finding your colour. Every part of the picture is in one place, so you can move from a look to a softer background, a portrait detail or your signature without leaving the photo. Undo is always in reach, and Save makes a new copy, so your original stays untouched.

PRESETS
• 513 looks in nine collections: Essentials, Cinema, Film, Daylight, Golden Hour, Night, Moody, Portrait and Black & White
• Live thumbnails of every look on your own photo
• Adjust the strength of any preset, and keep favourites close
• Auto finds a starting point with one tap

PORTRAIT
• Smooth skin, brighten eyes and refine the face
• Bring out a smile
• Works per face when there are several people in the photo

BACKGROUND
• Focus & Blur: soft, depth-aware background blur that keeps your subject sharp
• Change the background to an image, a colour or a gradient
• Refine the edges by hand

EDIT
• Crop, rotate, straighten and fix perspective
• Remove: brush over anything you don't want in the picture

EFFECTS
• Light leaks from real film
• Grain and vignette
• Selective Colour: keep chosen colours and turn the rest black and white

TEXT, WATERMARK AND BORDER
• Add text in a choice of fonts and weights
• Sign your photos with your own signature, your name or a logo
• Simple borders, photo frames and an instant-photo frame with room for a signature

PRIVATE BY DESIGN
• No Lightly account
• Editing happens on your device; your photos are not uploaded
• Choose whether saved copies keep camera details and location

Made for Android phones and tablets, with a two-pane layout on larger screens.
```

## Graphics (folder `graphics/`, `screenshots/`)
- App icon: `graphics/app-icon-512x512.png` (512 × 512)
- Feature graphic: `graphics/feature-graphic-1024x500.png` (1024 × 500)
- Phone screenshots: `screenshots/phone/` (8, 1496 × 2992)
- 7-inch tablet screenshots: `screenshots/tablet-7inch/` (8, 1600 × 2560)
- 10-inch tablet screenshots: `screenshots/tablet-10inch/` (8, 2560 × 1600)

## Store settings
- Category: **Photography** · Tags: Photo editor, Photo filters
- Contact email: **hello@lightly.pro** · Website: **https://lightly.pro**
- Privacy policy: **https://lightly.pro/privacy**
- Price: **Free** (confirm with the owner) · Countries: all

## App content (Policy › App content)
- **Privacy policy:** https://lightly.pro/privacy
- **Ads:** No, the app contains no ads
- **App access:** All functionality is available without special access (no login)
- **Content rating (IARC):** category "All other app types"; answer **No** to every question (no violence, sexual content, language, controlled substances, gambling, user interaction or sharing, location sharing, purchases). Expected rating: Everyone / PEGI 3.
- **Target audience:** 13 and over (not designed for children)
- **News app:** No · **Government app:** No · **Financial features:** None · **Health:** None
- **Data safety:**
  - Does the app collect or share user data? **No**
  - No data is transmitted off the device; the app makes no network connections.
  - Encrypted in transit / deletion request: not applicable (no data collected)
- **Permissions:** CAMERA only (taking a new photo inside the app). No location, contacts, microphone or storage permissions; photos are chosen with the system photo picker.
- **Advertising ID:** No

## Before production
- A **new personal** Play developer account must first run a **closed test with at least 12 testers for 14 days** before it can publish to production. Organisation accounts are exempt.

## Upload key (owner only)
The upload keystore and its password are kept on the owner's Mac (`~/Documents/Dev/keys/`), never in this repository.
