# iOS background replacement: hair fringe fixed

Status: **FIXED for the reported iOS red-wall/curl defect**, verified with live Vision on the iPhone 11 Pro Max on 8 October 2026. This is engineering verification of the image defect, not owner acceptance of the app or its full device matrix. Android A4/A5 are separate and unchanged.

## Implementation

- Accurate person segmentation runs on a crop around each face, then a closed-form alpha solve follows the photograph's local colour boundaries. The solve can restore dense hair coverage as well as open gaps between curls.
- Actual jaw/cheek contours protect faces. Clothing below the head and crop boundaries retain the existing mask.
- Strongly coloured backgrounds trigger the local refinement. Neutral/dark backdrops retain the existing Vision result, avoiding a new halo on the dark-studio portrait.
- Hair-edge colour comes from opaque crown hair, preserving observed hair colour and brightness. This also corrects contaminated pockets that the matte still treats as opaque. It does not assume black or grey hair.
- Replacement with blur uses the same colour reconstruction as the sharp replacement.
- Analysis runs once per photo, off the main actor, and propagates cancellation. A 400,000-unknown-pixel budget bounds the sparse allocation; non-convergence retains the prior matte. The recorded matte version is `ios-17-local-2`; restored older edits retain their recorded treatment.

## Evidence

Private original evidence: `~/.codex/artifacts/lightly/v1/hair-local-phone-2026-10-08/`.

| Check | Result |
|---|---|
| Red-wall portrait, dark and light replacement, live iPhone masks | Red/teal fringe and opaque red pockets removed in the inspected saved images; curls remain separated, face and clothing intact. `hair-final-dark.jpg`, `hair-final-light.jpg`. |
| Same portrait, light replacement plus Blur 60 | No colour fringe reintroduced. `hair-final-blur.jpg`. |
| Preview versus saved light replacement | Mean RGB difference 0.336/255; 99th percentile 7/255 after resizing the JPEG to the 1065×1600 preview. |
| Preview versus saved replacement plus blur | Mean RGB difference 0.310/255; 99th percentile 6/255. |
| Dark-studio portrait on light replacement | Visually unchanged. Earlier guarded-matte exports were byte-identical; final enabled-path repeat differs by mean 0.000078/255, with 0.00022% of pixels over 4/255. |
| Blonde portrait on dark replacement | Observed blonde colour preserved. Mean RGB difference from baseline 0.00022/255; 0.00018% of pixels differ by more than 4/255. |
| Three-person portrait | Faces, brown hair and clothing preserved; no cut-out hole introduced. Inspected before/after, mean RGB difference 0.437/255. |
| Normal enabled path versus experimental candidate | Light-replacement decoded output identical; no experiment flag required in the enabled path. |

The upper-left curls are out of focus in the source and remain soft; the fix does not invent sharp strands. These checks do not promise perfect matting for every photograph.

## Tests

34 distinct focused tests pass: local matting, spill/hair colour, hair-matte protection, Background responsiveness and Background rendering. Checks include known alpha mixtures, cancellation, bounded allocation, face-coordinate orientation, natural hair colour, opaque contamination, and existing Background behaviour. Numerical solver comparison against the existing 96×96 closed-form fixture: maximum alpha error 0.00000351.

On the red-wall 12 MP phone run, local analysis completed in about 6 seconds and Save copy in about 1.7 seconds. The analysis is cached; this is not a per-slider cost. All device experiment launches used `--keep-stored-session`.
