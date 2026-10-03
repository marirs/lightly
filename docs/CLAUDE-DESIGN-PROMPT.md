# Claude: design Lightly from this fixed product contract

Design only. Produce premium, high-fidelity mobile app screens and a clickable
prototype. No native builds, device installs, backend/model work, publishing or
pushes. Work in the main checkout on master; preserve all code, source assets and
the existing Lightly icon. Put disposable outputs under TMPDIR and durable review
evidence under ~/.codex/artifacts/lightly/.

Read the original product specification, v1.1 and M1 in docs. The decisions here
override conflicts. Do not reduce the whole application to a preset browser.

## Fixed preset input — no classification work delegated to you

Read `presets/DEVELOP-PRESET-LIST.md`: it names EVERY selected preset at EVERY
slider stop. Load `presets/develop-design-ui.json` directly into the prototype.
The complete private source bindings are in `presets/develop-design-catalogue.json`.

Use these exact nine categories, names, IDs and orders. Do not guess membership,
generate substitutes, choose a smaller shortlist, rename or reorder presets.
Do not use the older browse-catalog.json, catalog.json or the 18-Look pack for this
design. Those are different inventories, not this fixed design input.

Categories: Portrait; Landscape; Film; Cinematic; Street; Travel; Wedding;
Golden Hour; Black & White. Favourites is a separate shortcut of up to five looks.

Each slider stop selects one actual preset. Stop zero reads Auto only when Auto
correction is applied, otherwise Original. Display the preset name and position.
Preview during sliding; commit on release as one undo step. No previous/next
arrows beneath the slider, and no interpolation between presets. Category changes
alone do not change the applied Look. A new Look replaces the previous one while
preserving other tools' edits. Amount is secondary. Returning to the same Look
preserves its Amount. Show the full large categories, not padded or truncated lists.

Names and assets are Lightly's. No vendor/source-pack references, platform labels,
file extensions or technical diagnostics in the app UI. Catalogue content is real;
rendering fidelity remains unvalidated. Label simulated processing outside product
chrome, without pretending effects or Auto models already work.

## One photo, one session

No login, account or mandatory onboarding. Open once, switch tools freely, and
retain all accumulated edits. Save copy writes a NEW JPEG; never overwrite the
original. Compare, Undo/Redo and Save copy are actions, not editing categories.

Top-level tools, exactly:

1. **Develop:** automatic correction; the fixed categories and preset slider above.
2. **Background:** Focus & Blur; Change Background. Focus supports selecting the
   target, focus depth, blur amount and proposed Lens/Soft/Swirl/Motion styles,
   with applicable bokeh shapes and edge refinement. Change supports an image,
   colour or gradient, position and scale. Focus & Blur MUST remain available
   after replacement. Define the UX even where rendering is not implemented.
3. **Portrait:** conditional on detected faces/people. Hide it with none; select
   a single usable face automatically; let users choose among multiple faces.
   Facial controls require a usable face. Inside: Skin (smoothing, blemish reduction,
   tone, texture preservation), Under-eye, Eyes, Teeth, Hair & Beard. Keep face
   adjustments separate and conservative. Preserve pores and identity; no automatic
   face reshaping or whitening. Do not duplicate Background navigation here.
4. **Edit:** Crop, Rotate/Flip, Straighten, Perspective, Adjust, Remove. Adjust
   includes exposure, contrast, highlights/shadows, white balance, colour and detail.
   Remove uses a brush for unwanted objects/spots. Show real controls for each.
5. **Effects:** Light Leaks (style, intensity, position, rotation); Grain (style,
   amount, size, roughness); Vignette (amount, size, softness). They can combine.
   Flag any unresolved interaction with grain/vignette already in a Look for
   review; do not silently double or erase effects.
6. **Watermark:** None, Signature, Text, Logo. Draw/import and save a signature;
   position, size, opacity, colour where applicable. Can sit on a photo or border.
7. **Border:** None, Solid, Photo Frame, Polaroid. Appropriate width/colour/spacing
   controls; demonstrate Polaroid's larger lower margin and signature placement.

At top-right, vertical three dots open **More**. Inside: Preferences, Legal, About.
Preferences: appearance; manage/reorder up to five favourites; saved signature;
preferred border (initially None); two independent export switches: Keep photo metadata (On by default; camera, lens, aperture, shutter speed, ISO and capture date, excluding location) and Include location (Off by default; GPS). Turning off either must not change the other. Both off removes optional source metadata; necessary rendering metadata such as the output colour profile remains. Add a Privacy Policy link at the bottom of Welcome; its Back action returns to Welcome. Favourites
and saved signatures are shortcuts, not automatically applied edits. Make border
default behavior explicit. Legal contains Privacy Policy and Terms. About contains
version/build and Support. No profile or account screen.

## Required screen index

Show the whole experience, not only the editor:
- Welcome with Choose a photo, Camera and More; native picker/camera handoff.
- Loading, development, success and continue-with-original states.
- Landscape, single-person and multiple-person editors.
- Every top-level tool and every inside option listed above.
- All Develop categories, full-range sliders, Amount, favourites and five-item limit.
- Focus selection, blur styles, replacement, edge refinement, replacement then blur.
- Face selection and each portrait adjustment.
- Crop/geometry, manual adjustments and removal brush.
- Each effect and a combined-effects state.
- Signature creation/import, text/logo placement and every border including Polaroid.
- Saving, saved, share, keep editing, another photo and leaving unsaved changes.
- More, preferences, favourite management, legal pages, About and support entry.
- Relevant load/develop/tool failures, missing subject/face/model, permissions,
  cancellation, storage-full and save-failure recovery. Preserve existing edits.

Distinguish editor panels, screens, sheets and temporary states. Tools must not
become separate photo-opening workflows. Include a screen overview/contact sheet
and a clickable journey through the whole app.

## Device layouts and presentation

Cover iOS and Android: phone portrait/landscape, foldable folded/unfolded, tablet
portrait/landscape. Desktop is deferred. Keep photos dominant, controls clear of
hinges/system gestures, readable typography and reachable actions. Do not squeeze
seven tiny buttons across a phone. Show large text, long names and light/dark.

First present TWO genuinely different polished visual directions using the same
real photos and these screens: Welcome; landscape Develop editor; contextual
Portrait editor; Background Focus & Blur. Differences must be meaningful layout
and interaction choices, not recolouring. Recommend one and stop for our choice.

After our choice, expand every screen/state, the responsive layouts and the full
clickable prototype. Demonstrate Develop → background replacement → focus/blur →
portrait adjustment → effect → signature → Polaroid → new JPEG, all in one session.

Inspect your own screens before presenting. We approve the complete UX and visual
design before native implementation. Backend progress and test counts are not a
substitute. Ask only about genuine unresolved decisions; preset classification,
membership and slider order have already been supplied and are not your task.
