# Saved-edit fixtures (EditState schema 2)

These are shared by the iOS and Android tests. Both platforms must load these files from here; neither keeps a private copy. The `v2-*` files are byte-exact: encoding the same state must reproduce them exactly, with no trailing newline.

| File | Expectation |
|---|---|
| `v2-with-look.json` | Decodes; re-encodes to identical bytes |
| `v2-no-look.json` | Decodes (`look` and `guardrail` are explicit `null`); re-encodes to identical bytes |
| `v1-numeric-look-version.json` | Schema 1 (numeric `lookVersion`). Must be **migrated**, not dropped and not reinterpreted. The result must equal `v1-migrated-to-v2.json` |
| `v1-migrated-to-v2.json` | Migration output: schema 2, `lookVersion` = `"legacy-v1-<n>"`, everything else unchanged |
| `invalid-unknown-key.json` | Rejected: unknown keys are never half-read |
| `invalid-future-schema.json` | Rejected: schema 3 is unknown |
| `invalid-strength-out-of-range.json` | Rejected: strengths must be within 0…1 |

## Schema 2

- `lookVersion` is the Look pack's version string (`stops[].lookVersion`, the first 12 hex digits of the LUT's sha256).
- Schema 1 used a hand-numbered integer for the Look version.

## Resolving a saved Look against the installed pack

The same rules apply on both platforms. They never silently substitute another Look:

1. **`lookId` not in the pack:** the Look is *unavailable*.
   - The photo renders with Auto only (or Original), and a notice says the Look isn't in this build.
   - The saved `LookRef` and the history are kept unchanged.
2. **`lookId` in the pack, but `lookVersion` differs:** the Look is *changed*. This includes every migrated `legacy-v1-*` version.
   - The photo renders without the Look, and a notice says the Look has changed since this edit.
   - The notice offers "Use current version". Accepting it is a new, undoable step that writes the pack's current version.
   - Nothing is applied until the user accepts.
3. **Both match:** the Look renders normally.

What is displayed is what Save copy writes. While a Look is unavailable or changed, the export matches the screen (without that Look), and the notice stays visible.
