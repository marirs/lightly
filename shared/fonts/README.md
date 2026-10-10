# Watermark fonts (shared by iOS and Android)

The watermark text fonts approved for the editor, bundled identically in both apps so watermark rendering works offline and looks the same on each platform.

| Font | File | Licence | Source |
|---|---|---|---|
| Allura | `Allura-Regular.ttf` | SIL Open Font License 1.1 (`Allura-OFL.txt`) | github.com/google/fonts `ofl/allura` |
| Cormorant Garamond | `CormorantGaramond-Variable.ttf` (wght axis) | SIL OFL 1.1 (`CormorantGaramond-OFL.txt`) | github.com/google/fonts `ofl/cormorantgaramond` |
| Inter | `Inter-Variable.ttf` (opsz, wght axes) | SIL OFL 1.1 (`Inter-OFL.txt`) | github.com/google/fonts `ofl/inter` |
| Caveat | `Caveat-Variable.ttf` (wght axis) | SIL OFL 1.1 (`Caveat-OFL.txt`) | github.com/google/fonts `ofl/caveat` |

Downloaded 2026-10-03 from the `main` branch of github.com/google/fonts. Hashes are in `SHA256SUMS`.

- **Licence terms:** the OFL allows bundling in apps. The licence text must ship with the fonts, so both apps include the OFL files and list them in About or the acknowledgements. Modified fonts must not use the reserved names.
- **Weights:** the watermark uses the regular weight (Cormorant Garamond at 500, as in the prototype).
- **Builds:** both platforms copy these files at build time. There are no private copies in `ios/` or `android/`.

Added 2026-10-10 from google/fonts: `DancingScript-Variable.ttf` (`ofl/dancingscript`) and `Lora-Variable.ttf` (`ofl/lora`), both at regular weight 400, with their OFL files and SHA-256 hashes.
