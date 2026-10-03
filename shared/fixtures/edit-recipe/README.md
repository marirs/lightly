# Edit recipe v1 fixtures (EditState schema 3)

These are shared by the iOS and Android tests. The schema is `shared/contracts/edit-recipe-v1.json`. `shared/contracts/make_edit_recipe_examples.py` generates the files; do not edit them by hand. Every file uses canonical bytes: keys in schema order, no whitespace, no trailing newline, and integers without a decimal point. Encoding the decoded value must reproduce the bytes exactly.

| Files | Expectation |
|---|---|
| `neutral.json` | Decodes and re-encodes identically: the `newSession` defaults with no Auto model |
| `develop-look-amount-auto.json` | A Look at Amount 60 (`strength` 0.6) on top of an applied Auto |
| `background-*.json` | Replacement (bundled image, colour, gradient) plus Focus & Blur: every style and bokeh, each depth source (embedded map, estimated map, subject matte), refine-edge strokes, and blur applied after replacement |
| `portrait-two-faces.json` | Two faces, each with its own settings |
| `edit-geometry.json`, `edit-adjust.json`, `edit-remove-strokes.json` | Crop, quarter turn, flip, perspective, straighten; every Adjust slider; one applied and one failed Remove stroke |
| `effects-combined-on-top-of-preset.json` | Light leak, grain and vignette over a Look (composed with the preset's own grain and vignette, never replacing them) |
| `watermark-*.json` | Drawn and imported signature references, a dragged offset, text in a bundled font, a logo, text on a border |
| `border-*.json` | Solid, Photo Frame, and Polaroid with the signature on its margin |
| `demo-combined.json` | The approved "Combined edit, one session" (`docs/ui/app/screens.js` DEMO steps 1 to 7) |
| `migrated-from-v2-with-look.json` | Expected result of migrating `../edit-state/v2-with-look.json` |
| `invalid-*.json` | Rejected as a whole: an unknown key, an out-of-range value, a colour name, schema 4, a missing tool section, an unknown depth source, Look strength above 1 |

## Relation to EditState schema 2

Schema 3 is schema 2 plus two keys: `recipeVersion` (1) and `tools`.
- The `source`, `auto`, `look` and `revision` keys are unchanged, with the same names, values and meaning.
- The Develop tool is exactly `auto` + `look`. Its Amount is `look.strength`.

Reading:
- **Schema 1:** migrate to schema 2 (`lookVersion` = `"legacy-v1-<n>"`), then to schema 3.
- **Schema 2:** migrate to schema 3. Add `recipeVersion: 1` and the neutral `tools`. The neutral grain seed is the first 32 bits of `source.fingerprint.headSha256`. Nothing else is reinterpreted.
- **Any other schema, or any unknown key:** reject the whole document; it is never half-read.

The schema-2 rules for resolving a saved Look still apply, and the pack's `lookVersion` is the version string:
- `lookId` is not in the pack: the Look is **unavailable**.
- `lookVersion` differs: the Look is **changed**. It is rendered without the Look until the user accepts the current version, which is a new undoable step.
- The app never substitutes another Look.

Saved signatures follow the same rule: a missing signature is unavailable, a different `signatureVersion` means changed, and nothing is substituted.

Model results (subject matte, depth map, inpainted patch) are `derivedRef`s, stored beside the edit by digest. A missing result is recomputed only with the same model id and version. Otherwise the tool shows its unavailable state.

Reader rules beyond the schema, implemented in `shared/contracts/schema_check.py`:
- crop and face rectangles must lie inside the frame;
- exactly the watermark part that matches `type` is set;
- gradient stop positions must not decrease;
- the depth `map` is null exactly when the source is `subject-matte`;
- a Remove `patch` is present exactly when the stroke was applied.
