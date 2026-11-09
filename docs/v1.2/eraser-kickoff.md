# 1.2 — Eraser kickoff

Started 2026-11-09 at the owner's request. Version 1.1 is released on iOS and Android.
Baseline: master `22759720058b815088bc74a700bbc8795e5e4e59`.
This is an implementation audit and proposed scope, not UX approval or device validation.

## Existing implementation inspected

| Behaviour | iOS | Android |
| --- | --- | --- |
| Entry | Edit → Remove | Edit → Remove |
| Selection | One brush stroke, processed on release | One brush stroke, processed on release |
| Controls | Brush size, Undo stroke | Brush size, Undo stroke |
| Processing | Removing / Cancel; failure / Try again | Removing / Cancel; failure / Try again |
| Commit | Completed patch appended as an undoable edit | Completed patch appended as an undoable edit |
| Repeated work | Earlier removal patches supplied to next fill | Earlier patches composited into the source window |
| Model input | Native crop or downscaled context, 512 square | Native crop or downscaled context, 512 square |
| Long thin strokes | Tiled-native route explicitly deferred | Tiled-native route explicitly deferred |

Sources: `ios/Lightly/Features/Edit/EditPanel.swift`,
`ios/Lightly/Features/Develop/EditorSession.swift` (removeStroke through finishRemove),
`ios/Lightly/ImageEngine/Remove/RemoveEngine.swift`,
`android/app/src/main/kotlin/com/lightlylabs/lightly/editor/EditPanel.kt`,
`EditorViewModel.kt` (removeStroke through runRemove), and `RemoveEngine.kt` in that directory.

The October evaluation describes a tiled route, but the shipping implementations
explicitly defer it. Its research results must not be presented as current app coverage.
Existing cancellation, history and export infrastructure is reusable; its behaviour
with a multi-stroke selection still needs implementation and device verification.

## Approved implementation — 2026-11-09

The owner approved the simplified flow and the six full-screen loading mockups,
with the existing standard platform spinner in place of the illustrative CSS ring.

- Edit → Eraser. Brush multiple independent strokes; lifting a finger does not process.
- Brush size, Undo, Clear, Erase. No Add/Subtract, Select/Deselect, Restore, Keep or Refine.
- Clear discards pending marks only. Undo removes the latest pending stroke, otherwise
  reverses the latest removal. Erase applies all pending strokes as one history step.
- The result applies immediately. Failure preserves the marks and existing photo for retry.
- Two fingers zoom and pan; one finger brushes.
- Opening, Auto, subject separation, depth, Eraser and saving share one blocking overlay:
  the entire background dimmed evenly, standard spinner centred on screen, no visible
  loading text or Cancel. Existing failure and saved-success screens remain.
- iOS and Android, light and dark. Preserve fixed panels and approved responsive layouts.

The model and its quality limits are unchanged. Independent strokes are processed
against earlier successful patches off the main thread, then published atomically.
A failed batch publishes nothing; patches are retained for export and history replay.

## Validation scope

For this implementation: pending marks, Undo/Clear, explicit Erase, multiple strokes
in one history operation, failure/retry, gesture mapping, six loading states, saved
output, and installed build identity on the two Android phones and two test iPhones.
Device evidence and remaining untested states are recorded separately; compilation
and unit tests alone do not establish the phone experience.
