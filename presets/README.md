# Lightly source preset collection

This local source library contains 6,033 byte-distinct assets copied from
`/Users/sg/Downloads/Presets - for lightly`, including presets inside ZIPs.
7,189 exact duplicate occurrences were removed. The original collection is unchanged.

- `library/`: original bytes, stored by SHA-256; every copy was hash-verified.
- `manifest.json`: hashes, source paths and aliases, names, formats and parsing errors.
- `catalog.json`: categories derived from source folders and archive names.
- `browse-catalog.json`: design-preview names, including the original Wedding,
  Drone and Trending parent categories. Parent categories overlap their subcollections.
- `summary.json`: counts and the deduplication rule.

Different formats or differently encoded settings are retained; similar names or
approximate visual similarity are not proof of equivalence. These are source files,
not 6,033 validated, app-ready Looks. One LRTemplate file has a parsing error and is
preserved with that error recorded. Video LUTs are retained separately in the
catalogue; their input colour spaces have not been qualified for photo editing.

The data files are local and ignored by Git. No app resources or installed apps
are changed by this library. Recreate the exact-content inventory with:

```sh
python3 scripts/catalogue_collection.py '/Users/sg/Downloads/Presets - for lightly'
```

The design uses the real catalogue names and counts. Its photo effects and Auto
states are illustrative, not Lightroom conversion or trained-model evidence.

## Fixed design catalogue

`DEVELOP-PRESET-LIST.md` lists every selected preset in its exact category and slider
order. `develop-design-ui.json` is the UI input: IDs, display names and stops only.
`develop-design-catalogue.json` provides private source bindings and classification
reasons. `develop-design-exclusions.json` accounts for every unselected asset.

This selection uses parsed XMP sources. Other formats remain preserved and are
not assumed equivalent. Deduplication within this selection compares all parsed
processing and restriction fields, excluding only naming/author metadata. It does
not claim visual equivalence of different settings. Distinct same-name recipes
receive explicit variation names. Category membership is an editorial assignment,
not an image-quality assessment. Natural name order fixes the browsing sequence;
it is not a strength or perceptual progression. Rendering remains unvalidated.

Regenerate with `python3 scripts/build_design_catalogue.py`. The design input is
frozen for Claude: do not reclassify, rename, sample or reorder it during mockups.
