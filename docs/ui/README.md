# Lightly UI reference

The approved interactive screens and mockups live in `app/`. Open `app/index.html` through the repository server. The earlier explorations in `directions/` are retained for context; they are not the implementation target.

From the repository root:

```sh
python3 -m http.server 8765
```

Open http://127.0.0.1:8765/docs/ui/app/index.html. The review site includes the complete screen catalogue, interactive flow, and device/layout selectors. Existing `/design/` review links redirect here.

Photos are included in `assets/photos/`. The fixed preset names and category/stop catalogue are versioned at `presets/develop-design-ui.json` and `presets/DEVELOP-PRESET-LIST.md`; the raw preset library remains local. Serve the repository root so the catalogue resolves.

The implementation checklist and plan are in `docs/v1/`. `tools/` contains the screen export and design checks. `app/coverage.json` is an earlier recorded check result, not a claim of verification of subsequent changes. Prototype image effects are visual simulations, not the native rendering implementation.

Every implementation review must follow [the exact-design review rules](REVIEW-RULES.md). UX deviations require explicit user approval.
