# Lightly UX assessment — 8 October 2026

Initial rendering checkpoint: `46947eb`, build 1.0.0 (261008032). The subsequent clarity optimisation preserves each pixel’s arithmetic, parallelises independent rows and reuses horizontal sampling coordinates; its measured results are below. Reference: `docs/ui/app/`, `docs/ui/REVIEW-RULES.md`, and the approved 5/8 October amendments. The later Auto-overlay amendment supersedes the earlier separate Auto-row proposal.

This is a product-wide assessment, not blanket exact-design acceptance. Live inspection uses the iPhone 17 Pro Simulator, light appearance, normal text, with an actual portrait and accumulated edits. Android implementation is inspected alongside the shared renderer; Android physical interaction and the full device/theme/text matrix remain unverified. Each recommendation below is a proposed improvement, not permission to change the approved design.

## Rendering and interaction defects addressed in this checkpoint

| Defect | Cause and correction | Evidence / limit |
| --- | --- | --- |
| Hard diagonal edge when rotating Rose Light Leak | The renderer clipped the inverse-rotated coordinate to a rectangle. The radial field now continues naturally outside that rectangle on both platforms. | Rose at 53° inspected live in the Simulator; adjacent-pixel continuity test and updated numerical rendering fixtures. Original native screenshot: private artifacts `interaction-quality-2026-10-08/rose-rotation-53.png`. |
| Image changes quality when a preset/effect drag ends | Moving frames used a smaller source, a smaller LUT and/or a cheaper finishing pipeline. Moving and settled requests now use the same source, full LUT and complete stage order. | iOS ruler and Effects byte-equality tests pass. Android affected tests pass. Hardware timing is recorded separately; passing equality does not prove responsiveness. |
| Blur changes while opening a different panel | Panel heights resize the fitted image; that measurement previously changed blur scale and could publish a committed edit over a live drag. Rendering now holds a stable reference size for the photo session. | Panel-resize regression passes; code inspection covers blur/watermark scale and background-analysis completion. |
| Slider thumb feels sticky | Displayed position depended on rounded committed state. The thumb now follows local continuous touch position, with rounded recipe updates and one commit at release. | Live Simulator Vignette and Portrait smoothing drags; Android compile/unit checks. Physical gesture timing still requires the device check. |
| Effects reprocess unrelated stages on every change | iOS now caches one exact image before Effects, invalidated by upstream recipe, analysis, Auto or render-size changes. | Bounded one-frame cache; all downstream Effects still render. No approximate compositing or changed stage order. |

## Highest-impact improvements

1. **Keep the photograph visually stable while navigating tools.** Switching Light Leaks to Vignette visibly enlarges the photo because the controls have different heights; Portrait and Crop resize it again. This is separate from changing pixel quality. Recommend a consistent editor control area, or a deliberately resizable sheet whose movement is user-controlled. Acceptance: normal subtab changes do not jump the photo scale or position. Design approval required.
2. **Add image inspection at 1:1.** The ordinary photo stage has no pinch-to-zoom/double-tap inspection workflow. Hair edges, grain, skin texture and Remove cannot be judged reliably at fit size. Recommend zoom and pan with a clear distinction between inspection and tool gestures; retain the same zoom when switching relevant tools. This is a new interaction requiring approval.
3. **Make every adjustment slider behave and align consistently.** Tracks currently begin at different horizontal positions because labels have different widths; this is visible in Vignette and Portrait. Use common label/value columns and equal usable track widths. Provide an unobtrusive per-control reset and optional precision adjustment; maintain one Undo step per drag. The thumb-tracking defect is fixed separately.
4. **Make presets visually discoverable.** A ruler plus names and a position such as 37/518 is efficient only after the user knows the looks. Add an optional thumbnail browser showing the current photo, with search/filtering and favourites; retain the approved ruler for fast browsing until a replacement is approved. The Auto toggle should remain separate, at its approved bottom-left photo position.
5. **Remember the last subtool within the current edit.** `EditorScreen.select` resets Effects to Light Leaks, Edit to Crop, Portrait to Skin and Background to Focus & Blur whenever the dock tool changes. Recommend returning to the subtool the person just used, without applying anything merely by opening it. This changes the older prototype and needs approval.

## Reference patterns checked

Adobe documents double-tapping a slider to reset it and press-and-hold comparison in [Lightroom mobile gesture controls](https://helpx.adobe.com/lightroom/mobile/get-started/gesture-controls-in-lightroom-for-mobile.html). Its [mobile editing lesson](https://www.adobe.com/learn/lightroom-cc/web/lightroom-mobile-adjustments?learnIn=1&locale=en) demonstrates zooming and slider reset. These support the inspection/reset proposals; they are not evidence that Lightly currently implements them, nor a reason to copy another app's entire layout.

## Assessment across the app

| Area | Observed or inspected | Improvement / disposition |
| --- | --- | --- |
| Welcome and photo entry | Welcome implementation offers photo selection and camera directly. No new entry-flow defect established in this pass. | Keep the focused entry. Camera permission denial, cancellation and return from picker need device-flow verification; do not add onboarding copy to solve editor problems. |
| Editor top bar | Compact Save copy pill, Undo/Redo, comparison and Close remain clear in live inspection. | Keep approved chrome. Ensure all actions retain accessible touch areas. No visual redesign recommended here. |
| Photo canvas | Tool-panel changes visibly resize the image. Ordinary stage lacks inspection zoom. | Highest-priority layout and inspection improvements above. Avoid animated crossfades that conceal rendering inconsistency. |
| Develop / Auto | Readable names, selected-category underline, edited dots and small neutral Auto overlay visible. No Auto/no-preset sentence. | Keep these corrections. Add visual preset discovery only through an approved design. Category eligibility must continue to follow the photo, not remembered invalid categories. |
| Favourites | Preferences displays “0 of 5”; empty page says “5 free”; store enforces five entries. | Consider removing the arbitrary five-item limit. “5 free” can read like a pricing tier; simpler empty-state copy would be clearer. Persistent state and immediate updates need cross-photo regression coverage, not only this empty-state inspection. |
| Background | Full subject/depth path is part of the phone interaction probe. Prior user image shows coloured hair contamination. | Do not equate a fast preview with acceptable hair. Keep image-quality validation separate, including white/light and photographic replacement backgrounds. Loading must not block unrelated controls. No new hair-quality claim in this checkpoint. |
| Portrait | Live selected-face oval, smoothing/blemish/texture controls and long explanatory note inspected. Smoothing dragged successfully. | Aligned tracks; zoom to selected face for inspection; consider temporary face selection highlight and contextual help instead of persistent explanatory paragraphs. Proposals, not current approval. |
| Edit / Crop | Live free-form grid and Done are present; no ratio chips. | Preserve Done → cropped preview → Adjust crop. Corner handles need clear contrast on white content. Add inspection zoom without interfering with crop dragging. Full rotate/straighten/export matrix not repeated here. |
| Edit / adjustments | Common slider component inspected. | Same alignment, precision and reset behaviour across Light/Colour/Detail. Never change the pipeline quality at release. |
| Edit / Remove | Brush workflow and render paths inspected; no new physical stroke run in this assessment. | A brush cursor, zoom and unambiguous pending-stroke feedback are key. Evaluate them together on the phone; do not claim improved removal quality from renderer tests. |
| Effects | Rose rotation, Vignette and switching tabs exercised live. Hard cutoff removed; panel resize remains visually noticeable. | Style chips could show small visual previews. Keep direct application and zero-to-remove; do not restore On/Off switches. Keep grain spatially stable between frames. |
| Selective Colour | Controls and selection overlay inspected in source, not a fresh physical interaction. | Zoom and clear selected-colour feedback should use the same canvas interaction system. Mark selection/loading/error behaviour unverified until exercised. |
| Watermark | Canvas-relative free placement inspected in implementation and amendment. | Keep free dragging with no On photo/On border selector. Consider selected-object bounds, resize handles and snapping guides so placement is direct. Do not add a border automatically. |
| Border | Border controls inspected. `signatureOnMargin` still tests legacy `.border` placement while moved watermarks use `.canvas`. | Potential semantic mismatch: a signature physically in the margin can leave that switch reporting off. Reproduce and resolve the relationship with free placement; do not introduce another placement mode. |
| Dock navigation | Phone viewport shows only some of the seven tools; Watermark is partially visible and Border is offscreen. | Make horizontal overflow discoverable and ensure the selected tool scrolls into view. Avoid shrinking all seven labels into tiny targets. CUA scrolling did not establish a functional scrolling defect. |
| Save / share / recovery | Existing Save-copy contract and sheet inspected. Pixel-equivalence tests cover changed render paths. | Keep original preservation and recoverable failure actions. This pass does not re-certify all storage, permission, backgrounding and restoration cases. |
| More | Three rows occupy a nearly full-height sheet, with large blank space below. | A compact menu/sheet would match the amount of content and reduce navigation distance. Design proposal. |
| Preferences | Live inspection: clear groups, metadata/location separation, duplicated “None” below and beside Preferred border. | Remove redundant secondary value in a future approved polish pass; retain explicit metadata/location controls. |
| Legal / support / About | Live Privacy page shows its online URL instead of Last updated; navigation/readability checked. Support/About implementation inspected. | Keep requested plain links. This assessment concerns presentation, not legal content. |
| Accessibility | Simulator accessibility tree has labels; custom slider bridge reports `nan` numerically while the spoken-description field contains the actual value. | Investigate on VoiceOver before calling this a spoken-value defect. Larger text, contrast and traversal are not certified by a normal-text screenshot. |

## What this assessment does not claim

The entire app has been considered, but not every state has been physically exercised. Dark appearance, accessibility text, iPad/foldables, camera hardware, spoken VoiceOver/TalkBack, and current Android hardware remain outside this live pass. Approved references have not been altered. Suggestions are ranked product improvements, not an expanding list of automatic release blockers.

## Device verification

Final checkpoint `b4ee87b`, build **1.0.0 (261008033)**, is installed in place and read back on the review Simulator and Android emulator. The matching iPhone package is ready; its installation and physical verification remain blocked by the device connection.

Build 261008032 installed and read back on review Simulator D75D820D and Android emulator 5554. The iPhone package built successfully using existing local signing. Installation failed with CoreDevice error 4000: tunnel interrupted / network connection timed out. Two app-container reads also timed out; no on-phone flicker verification was completed.

The expanded iOS EditorSession run passed 29/34 tests, including every Effects control retaining identical pixels on release. Four failures selected Portrait despite a no-person fixture; those fixtures now explicitly supply a detected person. Their rerun passed. The fifth is a real open performance finding: 20-stop rapid scrubbing reached 520 ms staleness against the existing 100 ms target. A bounded-prefetch experiment still measured 568 ms; it was discarded. A separate clarity optimisation reduced rapid-scrub worst staleness to 305 ms, with a full-frame median of 143 ms (previous probe: 181 ms). Spatial preview/release equality and tile-continuity checks passed. The target is unchanged. Broad flicker/responsiveness is not closed by image-equality tests.

### Final functional verification

After correcting the four person-detection fixtures, all 33 non-timing EditorSession tests passed against 46947eb. The timing failure was recorded separately, not waived. The twelve-control test covers Light Leak intensity/rotation/position, Grain amount/size/roughness, Vignette amount/size/softness and Selective Colour range/strength with accumulated effects and a spatial preset.

The assessment is complete as a product review. The rendering/interaction task remains open for rapid-preset latency and physical iPhone verification. A test-compatible image is not sufficient evidence of a smooth interface.
