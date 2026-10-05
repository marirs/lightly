# Legal text: proposals for the owner (2026-10-05)

The apps show the published website text (https://lightly.pro/privacy and https://lightly.pro/terms, both live on
2026-10-05 with "Last updated · 5 October 2026", identical to `pub-sites/lightly/public/*.md`). Contact and support:
hello@lightly.pro. Nothing below changes that text until you approve it; nothing here is legal advice.

## 1. Proposed replacement for the circular Terms clause

**Now** (Terms › Using the app):
> Use the app in accordance with applicable law and the terms supplied with its release. Do not disrupt the website or
> attempt to access systems without permission. Any restrictions are subject to rights that applicable law gives you.

Inside the app these Terms *are* the terms supplied with the release, so the sentence points to itself.

**Proposed:**
> Use the app in accordance with applicable law and these terms. If you download Lightly from the App Store, Apple's
> Licensed Application End User License Agreement also applies; if you download it from Google Play, Google Play's terms
> also apply. Do not disrupt the website or attempt to access systems without permission. Any restrictions are subject
> to rights that applicable law gives you.

The Apple sentence assumes the standard Apple EULA is used rather than a custom one (question 3 below). After approval
the change is made once on the website and copied into both apps with `scripts/make_release_text.py`.

## 2. Missing facts (only you can supply them)
1. **Operator:** the legal entity or person behind Lightly and a postal address. The pages say "we" without naming
   anyone; both stores need a seller/developer name.
2. **Minimum age** for the store age ratings and, if you want it stated, in the Terms.
3. **Pricing:** free, subscription or lifetime (spec §0.3). The Terms say only that the website sells nothing.
4. **Bundled background photos:** ship them (credit the photographers in the notices below) or not.

## 3. Questions for counsel (not facts the owner can simply fill in)
1. Governing law and jurisdiction.
2. Warranty disclaimer and limitation of liability (the Terms have only the consumer-rights saving clause).
3. Apple's standard EULA or a custom EULA; Google Play terms.
4. Whether an EU/UK representative is required (the app collects no personal data; email correspondence only).
5. Training-data sign-off for the gated models (Depth Anything V2, LaMa, MODNet, U²-Netp) and redistribution rights for
   the 2,591 presets (register items 1, 2, 9).

## 4. Licence notices: proposal

**What must be delivered** (from `dependencies.md`; components that ship in a release build with the current gates):

| Component | Platform | Licence | Notice needed |
|---|---|---|---|
| Allura, Cormorant Garamond, Inter, Caveat | iOS, Android | SIL Open Font License 1.1 | Licence text with the fonts (the `*-OFL.txt` files ship in the app package) |
| LiteRT 1.4.2 | Android | Apache-2.0 | Licence and NOTICE text |
| BlazeFace, Face Mesh, pose detector, selfie segmenter (MediaPipe models on LiteRT) | Android, when the vision gate is on | Apache-2.0 | Licence text |
| AndroidX, Jetpack Compose, Kotlin standard library and coroutines | Android | Apache-2.0 | Licence text |
| Depth Anything V2 Small, LaMa, MODNet, U²-Netp | gated until counsel signs off | Apache-2.0 | Licence text once ungated |
| Four background photos | if they ship | Unsplash License | Credit (optional but proposed) |

Apple Vision is a system framework and needs none.

**The existing Legal structure cannot carry these without either a visible addition or a text change.** The approved
Legal page has two rows (Privacy Policy, Terms of Use) and no notices page. Two options:

- **A (recommended): a third Legal row, "Licences", below Terms of Use.** It opens a page built from the same components
  as Privacy Policy and Terms of Use: a group label per component (e.g. "Inter"), one paragraph with the copyright line
  and licence name, then the full Apache-2.0 and OFL 1.1 texts once each at the end. The row and page look exactly like
  their neighbours, but the row is a visible addition to an approved screen, so it needs your approval.
- **B (no change to the app's screens): a "Third-party notices" section added to the Terms** on the website and in the
  apps, listing the components above and linking to a new page, https://lightly.pro/licences, with the full texts. The
  licence files also ship inside the app package. It relies on the website for the full texts.

Nothing is built for either option yet.
