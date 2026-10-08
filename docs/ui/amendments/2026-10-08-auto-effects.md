# Auto and Effects — owner amendment 8 October 2026

Auto is a magic-wand toggle at the bottom-left inside the fitted photograph, regardless of image aspect ratio. The owner approved the revised mock on 8 October ("OK this is better"). A 30 pt/dp translucent charcoal disc carries an 18 pt/dp white wand. Applied adds a fine white ring and a small white check badge; neither state has an orange background. The visible disc sits 12 pt/dp inside the photo edges. The invisible touch area remains 44 pt on iOS and 48 dp on Android. This supersedes the rejected top-left orange disc. Remove the Auto row and all no-preset/Auto placeholder text from the preset name row.

Light Leaks, Grain and Vignette have no enable switches. Choosing a style, adjusting a control or moving a leak applies the effect immediately. Intensity/Amount zero removes it. Preview and commit follow the same rule; Undo remains one step per gesture. Browsing effect tabs alone does not apply an effect.

References checked: Apple Photos Enhance (https://support.apple.com/en-bh/guide/iphone/iphb08064d57/ios) and Lightroom Auto (https://helpx.adobe.com/lightroom/mobile/adjust-light-and-color/apply-auto-settings.html). Placement follows the owner's explicit instruction.

## Photo-dependent preset categories — 8 October

The owner reconfirmed that the Portrait preset category is hidden unless a person is detected. This applies independently of the Portrait tool in the dock. A hidden category cannot be the selected category, including when a stored or applied preset refers to it. Applying or retaining a look is separate from category visibility. Existing Favourites/Landscape fallback behaviour is unchanged; the proposed All presets category and remembered-category redesign were not approved.

## Lightly preset names — approved 8 October

The owner approved a representative nine-name sample and extending that descriptive naming style to the full catalogue. All 2,591 IDs have unique frozen names in `shared/look-pack/names/display-names.json`. The nine approved names are retained. The remaining assignments use measured colour/tone characteristics, with representative colour-stage previews visually reviewed, not a claim of manual review of all 2,591 looks. Labels contain no numeric suffixes and are at most 30 characters. IDs, versions, recipes, favourites and edit histories are unchanged. `display_names.py` validates coverage and uniqueness without regenerating inherited source names.

## Watermark free placement — owner request 2026-10-08

Remove the On photo / On border selector and the Position row. Drag the watermark over the full output canvas, including an existing border; no border is required or added. Size, opacity and colour remain. Dragging previews the position and commits one undo step. A canvas-relative centre is persisted and used by preview and export, clamped inside the output. Legacy photo/border recipes retain their initial rendering until moved. Installed-device visual verification is pending.
