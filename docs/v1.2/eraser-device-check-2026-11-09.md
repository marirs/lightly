# Eraser and processing overlay — device check, 2026-11-09

Approved scope: the simplified Eraser flow and six full-screen processing states,
using standard platform spinners. The approved mockups were not changed.

## Build identity

- Base: `22759720058b815088bc74a700bbc8795e5e4e59`, master, with uncommitted implementation.
- Production diff SHA-256: `5c52e7f510efde3518eb02bdc491427b7416a34ac0f4bb5cc1fc8e30ac9ff5bc`.
- iOS installed development build: `261109004`.
- Android installed debug APK SHA-256: `db9ad0925f382c75a8c26008f28dded564aa5efac912bd3f792b695f18669515`.
- Private screenshots, test results, logs and source fingerprint:
  `~/.codex/artifacts/lightly/eraser-1.2-device/`.

## Physical-device evidence

The test opens a disposable landscape sample, enters Edit → Eraser, draws two
independent marks, checks that lifting the finger does not process, undoes one
mark, clears the remaining mark, draws two again and taps Erase. It then undoes
the completed batch, restores that batch using editor Undo and saves a new photo.

| Device | Theme | Draft, Undo, Clear, explicit Erase, batch undo, save success |
| --- | --- | --- |
| iPhone 11 Pro Max | Light | Verified; `iphone11-004.xcresult` |
| iPhone SE 3 | Light | Verified; `se004.xcresult` |
| moto edge 60 | Light | Verified; `moto-final/result.json` |
| Nothing A069 | Dark | Verified; `nothing-final/result.json` |

The inspected iOS recording and Android processing screenshots show the whole
screen dimmed with a centred native spinner, without loading text or Cancel.
The Eraser controls use the approved outlined Undo/Clear buttons and primary
Erase button. The fixed tool panel scrolls; its bottom fade is retained.

Android `EditEffectsTest`: 31 tests passed, including deferred draft application,
atomic multi-stroke history and retained marks on failure. The new iOS unit tests
were added but have not been run; the physical iOS UI tests above passed.

## Explicitly unverified

- Follow-up: all six loading states individually on every phone/theme are now
  verified on the newer build in [the processing review](processing-device-check-2026-11-09.md).
  The Eraser flow results above retain their original build identity.
- Failure/retry through the physical UI, two-finger zoom/pan with pending marks,
  and preview-to-export pixel comparison.
- Foldables, tablets, large text and accessibility services for this change.
- Removal quality across varied objects/photos; the inpainting model is unchanged.

No snapshot references were replaced. No commit or push was made for this work.
