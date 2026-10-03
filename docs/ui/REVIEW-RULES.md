# Mandatory exact-design review

User directive, 2026-10-03: “the UX is exactly what was created NO DEVIATIONS … EVERY REVIEW SHOULD BE … EXACT”.

## Acceptance baseline

Use the approved `docs/ui/app/` prototype, the fixed preset catalogue, and `docs/v1/implementation-checklist.md`. The canonical relocation was committed at `0352972`; retain the approved design and incorporate only subsequent changes explicitly approved by the user. Implementation changes never constitute design approval.

## Every review

1. Identify the implementation commit, reference revision, screens and behaviours under review.
2. Compare actual native screenshots side by side with the corresponding approved reference, using the same device dimensions, orientation, theme, text scale, content and state. Check spacing, alignment, typography, colour, icons, borders, image area, controls and wording. Explain unavoidable platform-rendering differences; do not use them to excuse layout or design changes.
3. Exercise the approved flow: entry and navigation, conditional tool visibility, category and preset selection, sliders, accumulated edits in one photo session, undo/redo, save-copy, preferences, and relevant loading/error/recovery states. Review only applicable behaviours for the slice, and leave the rest pending.
4. Check the approved device matrix: portrait phones and folded phones; unfolded foldables and tablets in their approved orientations; 11-inch and 13-inch tablets; light/dark and large-text variants. Do not add a phone-landscape design without approval.
5. Record each mismatch with the expected reference, observed behaviour, and screenshot or reproduction evidence. Each in-scope item is either exact-match verified, a deviation requiring correction/explicit approval, or unverified. No “close enough” approval.
6. Keep correctness, real image-processing results, accessibility, performance and regression checks alongside visual review. A convincing mock or screenshot does not prove the feature works.

## Change control

Do not change the reference to match the implementation, waive differences yourself, or treat unavailable-state designs as permission to omit promised functionality. If a constraint prevents faithful implementation, document the specific conflict and obtain explicit user approval before changing the UX. Until resolved, the affected item cannot receive UX acceptance.
