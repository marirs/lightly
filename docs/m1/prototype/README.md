# Lightly editing prototype (M1)

A single self-contained HTML file (`index.html`) that shows the M1 editing flow:
pick a photo → it develops automatically → Auto is the baseline → pick a Look
(category + stepped slider) → Compare → Undo/Redo → Save copy.

## How to open

Open `index.html` in any current browser (double-click it, or
`open docs/m1/prototype/index.html`). It makes no network requests. The photo
is embedded as a base64 JPEG.

The page toolbar switches **Layout** (Phone 390×844, Phone landscape 844×390,
Foldable 884×1104, Tablet 1194×834), **Theme** (System/Light/Dark), **Large text**
and **Reduce motion**. The device frame is drawn at exact CSS px and scaled down
to fit the window.

Side panels:

- **State** jumps to any state. It also has a "Next save result" switch
  (success / not enough storage / permission denied) and a live readout of the
  session. Use the readout to check that a layout switch keeps everything.
- **Screen reader output** shows approximate VoiceOver or TalkBack speech for
  the focused control (Tab through the device) and every live-region
  announcement.

## Deep links

Hash tokens are separated by `-`, `,` or `&`, and order does not matter:

| Token | Effect |
|---|---|
| `phone`, `landscape` (or `phonel`), `fold`, `tablet` | layout |
| `empty`, `developing`, `failed`, `auto`, `look`, `comparing`, `saving`, `saved`, `savefailed`, `denied`, `leave`, `asset` | state |
| `natural` / `warm` / `cool` / `film` / `mono` followed by `<stop>` and optionally `<strength>` | Look, for example `film-2-80` = Film, stop 2 (Pastel), 80% |
| `dark`, `light` | theme |
| `large` (or `ax3`) | large text |
| `rm` | reduce motion |
| `talkback` | TalkBack phrasing in the speech panel |
| `shot` | screenshot mode: only the device, unscaled. Developing and saving progress freeze. |

Examples: `index.html#phone-look-film-2-80`, `#fold-saved-dark`,
`#tablet-developing-shot`, `#phone-large-look-film-2-80`.

The page is also scriptable through `window.proto`:

```js
await proto.ready;                       // resolves after the photo is decoded
proto.set({ layout: 'fold', state: 'look', category: 'film', stop: 2, strength: 80,
            largeText: false, theme: 'dark', compare: false, shot: true });
proto.get();                             // { layout, phase, look, strength, undo, redo, save, renderMs, … }
proto.undo(); proto.redo();
```

`state` takes one of `empty | developing | developFailed | auto | look | comparing | saving | saved | saveFailed | saveDenied | leave | largeAsset`.

Screenshots in `screenshots/` were captured with headless Chromium (Playwright)
in `#shot` mode.

## Behaviour modelled

- **Auto develop.** There is no Develop button. Picking a photo starts
  developing straight away. The original stays visible, with a thin progress
  bar, a soft shimmer and a Cancel button. If developing fails, you can choose
  Retry or Continue with original. "Continue with original" makes the original
  the baseline.
- **Looks.** There are 5 categories (Natural, Warm, Cool, Film, Mono) with
  5 stops each. Stop 0 is always Auto. Choosing a stop previews it straight
  away, with no Apply step.
  - A Look always applies on top of Auto. Choosing another Look replaces the
    current one; Looks never stack.
  - Browsing another category keeps the current Look until you pick a non-Auto
    stop there. On screen, the slider thumb turns dashed and a note says which
    Look is kept. The active-Look chip and a dot on the owning tab show it too.
    Screen readers announce it when the category changes.
  - Strength (0–100%, default 100%) appears only while a Look is active. It
    resets to 100% on Reset or when you go back to Auto.
- **Compare.** Press and hold the photo, or hold Space while the photo has
  focus, to see the original with an "Original" badge. There is also a
  `Compare` toggle button (`aria-pressed`).
- **Undo/Redo.** There is one step per settled change: a slider or strength
  change after a 450 ms settle or pointer-up, or a Reset. Shortcuts are
  Ctrl/⌘+Z and Shift+Ctrl/⌘+Z.
- **Save copy.** The button shows "Saving copy…", then the message "Saved as a
  new photo. Original unchanged." with View and Done actions.
  - Storage failure: "Couldn't save — not enough storage…" with Retry.
  - Permission denied: asks for "Add Photos Only" access, with Open Settings
    and Retry.
  - The original is never modified.
- **Leave.** Back with unsaved edits opens "Discard edits?" with Keep editing
  (focused by default) and Discard. It also explains that edits are never
  written to the original.
- **Large-asset notice.** This is optional and can be reached from the State
  panel.
- **Layout continuity.** Switching layout (rotate/fold) only changes
  presentation. Category, stop, strength, compare and the undo/redo stacks are
  kept. The preview buffers are rebuilt at the new display size.
- **Compact phone.** The controls are a bottom panel of at most 35% of the
  screen height (42% with large text, and it scrolls). The photo is never
  covered.
- **Wide layouts.** Foldable, tablet and phone landscape use a side panel.

## Accessibility implemented

- The stepped slider is a real `role="slider"` with `aria-valuemin/max/now`.
  `aria-valuetext` reads, for example, "Film, Pastel, 3 of 5". Arrow keys move
  one stop, Home/End jump to the ends, and PageUp/PageDown move two stops.
  Each change is logged as speech.
- Categories form a `tablist` with roving tabindex and arrow-key navigation.
  In large text it becomes a labelled native `<select>` picker.
- The photo is `role="img"`. Its label follows the state, for example "Photo,
  sunset over a misty meadow. Auto enhanced, Film look Pastel at 80%." It also
  has a described-by hint for Compare.
- Live regions:
  - polite: developing, developed, Saving copy…, Saved…, undo/redo results,
    category-browsing rule.
  - assertive: develop failed, save failed, permission denied.
- The leave dialog is `role="alertdialog"` + `aria-modal`. Focus moves into it
  and is trapped there, Escape means Keep editing, and focus returns afterwards.
  The editor is `inert` while the dialog is open.
- Large text scales device type by ~1.9×, simulating iOS AX3 / Android 200%.
  - Tabs become a picker.
  - Stop labels collapse into one current-stop label plus "n of 5".
  - Strength stacks.
  - The panel scrolls.
  - The photo keeps a minimum visible height.
- The whole prototype works from the keyboard, and `:focus-visible` rings are
  visible. Tap targets are at least 44 px.
- `prefers-reduced-motion` (or the Reduce motion toggle) removes the shimmer,
  the cross-fade, the spinners' motion and the thumb transitions.
- Light and dark themes use tokens from `Lightly/DesignSystem/Tokens/LightlyColor.swift`.
  The device bezel and status bar follow the theme.

## What is illustrative

- **Auto** is a stand-in for the on-device ML enhancement. It uses luminance
  auto-levels, midtone gamma, a gentle S-curve and +12% saturation, computed
  once and cached.
- **Looks** are hand-tuned 3×3 colour matrices (white-balance shift +
  saturation/mono) plus per-channel tone curves and optional grain. They are
  not the shipping presets or LUTs. The names are made up and deliberately not
  trademarked, and the set is a small curated example, not a catalogue.
- The render path mirrors the real architecture: preview = Auto ∘ Look, blended
  by Strength. It is computed from the cached Auto buffer at display size, and
  the original is never recompressed. One render takes about 1–6 ms; the
  footer shows the time.
- Saving, permissions, View and Open Settings are simulated.

Photo: Dawid Zawiła on Unsplash (Unsplash License),
<https://unsplash.com/photos/trees-under-cloudy-sky-during-sunset--G3rw6Y02D0>,
downscaled to 1100 px.

## Corrections after Codex M1 review

- **Choosing Auto always removes the Look (finding 5).**
  - Before: Film → browse Warm → choose Auto left Film applied.
  - Now: explicitly choosing Auto clears the active Look in any category, whether by tapping the Auto label or pressing Home/Left at Auto in a non-owning category.
  - Browsing a category without choosing a stop still keeps the current Look.
- **One gesture = one undo step (finding 6).** The 450 ms settle timer was removed, so a paused drag no longer commits.
  - Pointer drag on the stepped slider: renders live, commits once on release.
  - Keyboard / assistive-technology increment: each step commits once.
  - Strength: renders on `input`, commits on `change` (release or key step).
- **Regression test:** `tests/codex_findings.test.js` uses Playwright and drives the real UI. It passes on this version and fails on `f7336fb`.

```bash
NODE_PATH=<dir containing playwright> node tests/codex_findings.test.js
```

## Limits of this prototype (not validated)

- The screen-reader panel is a **simulation** of VoiceOver/TalkBack wording. It is not accessibility validation: real VoiceOver and TalkBack testing on devices is required in M3/M4.
- The large-text layout needs refinement. On a compact phone the panel grows to about 42% of the height and must scroll, and the Strength row can sit below the fold.
