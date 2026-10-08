# Inspection zoom — 8 October 2026

User request: inspect the image closely while editing.

Implemented on iOS and Android:

- Pinch from fit to 6×; pan with two fingers. One-finger tool gestures retain their purpose.
- Double-tap toggles between fit and 2.5× around the tapped point.
- Image and editing marks transform together. Auto stays at its approved size and fitted-photo position.
- Zoom survives preview publication, Compare, and tool changes within the same editor layout. A new photo starts fitted.
- Inspection never changes the recipe, history, export, or the fitted dimensions used for rendering.
- Inspection magnifies the existing editing preview; it does not decode an additional full-resolution image.

Verification:

- iOS Simulator interaction test: pinch, Auto preview update, unchanged Auto button size, tool changes, double-tap back to fit. Passed.
- Android Compose/Robolectric: all seven EditorScreen tests pass, including pinch/tool persistence, double-tap, and no accidental crop or Remove stroke during pinch.
- Existing Android UI assertions were reconciled with the owner's already implemented removal of stop-0 text, crop ratios and Effects switches. No reference images changed.
- Physical iPhone and Android verification remains pending. Manual visual inspection was blocked by the locked Mac. No claim of physical-device acceptance.

The separate flicker work remains open; this amendment does not close it.
