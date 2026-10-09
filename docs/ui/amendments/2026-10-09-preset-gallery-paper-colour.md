# Preset gallery, Paper and shared colour picker — 9 October 2026

The owner approved the design mock and asked to implement this slice before preset curation. The subsequent correction takes precedence: expanding the preset picker overlays the existing photo; it must not resize or reposition it.

## Scope

- Current-photo preset thumbnails: two horizontal rows when compact, two vertically scrolling columns when expanded. Selection, favourites, Amount and labelled Reset remain available. Category changes start at the beginning and do not apply an edit.
- Paper border: Clean, Deckled and Torn, with colour, width and texture, through preview, save and restored recipes.
- Shared colour control in Border, frame mat, Watermark and Background (solid and gradient stops). Photo-derived palette, Paper & ink and Earth palettes, custom colour and HEX, photo eyedropper and shared recent colours. Preview is transient; Done commits one step, Cancel restores the committed edit.
- Light and dark colours follow appearance. No preset was removed, renamed or curated.

## Implementation and verification

Paper uses a deterministic surface in source-width coordinates. Android whole/tiled output is tested for every finish; iOS tests cover deterministic output and preserving the photo interior. Optional recipe properties preserve old canonical recipe bytes when defaulted.

Focused iOS native tests cover Paper/picker entry, preset expansion with the photo frame unchanged, Reset/Undo, and Favourites beginning at the first tile. Colour Done/Cancel and dark-theme checks are recorded with the packaged evidence. Android screen tests are updated from ruler interactions to thumbnail selection; renderer/recipe tests remain applicable.

This is a focused slice, not acceptance of the complete device/theme/text-size matrix. No approved reference image or mock was rewritten.

## Follow-up: gesture expansion

Owner approved replacing visible Expand/Collapse buttons with gestures. Swipe up on the compact tray (or its grab handle) to expand over the unchanged photo. Horizontal swipes keep browsing the compact tray. In the expanded grid, downward scrolling browses normally until the top; pulling down from the top collapses it. The grab handle can collapse the panel from any scroll position. Screen-reader custom actions expose the same operations without visible buttons.

### Border None state — owner approved

When None is selected, show the border style choices only. Remove the redundant Border heading/reset row and preferred-border explanation from this state on both platforms. Style adjustment controls remain conditional on the selected style.

### Front-camera capture — owner approved

Keep front-camera captures mirrored horizontally to match the viewfinder when entering the editor. Apply the transform before HEIC/JPEG encoding, respecting sensor orientation, so previews, session recovery and saved copies share the same source. Rear-camera and library photos are unchanged.

### Camera confirmation mirroring — follow-up correction

The prior correction ran after the system Use Photo screen and missed the reported transition. The supported UIImagePickerController overlay now owns capture controls and Retake / Use Photo review. Capture remains system-managed. Review displays the mirrored encoded image itself; Use Photo delivers those same bytes, with no second transform. Front-camera, rear-camera, flash, shutter and cancellation remain available. The native camera confirmation is bypassed via showsCameraControls=false and takePicture(), without inspecting private UIKit views.
