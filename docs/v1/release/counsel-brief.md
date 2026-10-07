# Lightly 1.0: brief for counsel (2026-10-07)

> Prepared by engineering for the owner to send. Facts only; every source is listed in `dependencies.md`. Nothing here
> is a legal conclusion, and no replacement model mentioned elsewhere is described as cleared.

**The product.** Lightly is a paid **[OPEN: price]** photo editor for iPhone, iPad and Android, sold by **[OPEN:
operator]** in **[OPEN: markets]**. All processing happens on the device; the apps have no network access (Android has
no INTERNET permission; iOS has no networking code). Model files are bundled inside the app and run only on the
user's own photos. No training data, and no image from any dataset, is distributed.

## A. Machine-learning models (each is switched off in release builds until you answer)
| # | Feature | Exact files shipped | Weights licence (documented) | Training data (documented) |
|---|---|---|---|---|
| 1 | Edit › Remove (both platforms) | LaMa big-lama: `big-lama.zip` from huggingface.co/smartywu/big-lama @ 05cb2be7 (SHA-256 f1b358ca…75f6, identical to the official README's download), converted to Core ML fp16 and LiteRT fp32 | Repository licence Apache-2.0, "Copyright [2021] Samsung Research"; no separate weights licence; the mirror is not a Samsung account | Places2. Its terms (as recorded in 2019): "only for non-commercial research and educational purposes", "You will NOT distribute the above images". Those terms bound the downloader (Samsung Research) |
| 2 | Background › Focus & Blur on photos without camera depth (both) | Depth Anything V2 Small: iOS Apple's Core ML repackaging (huggingface.co/apple/coreml-depth-anything-v2-small @ cfef6f6f); Android our conversion of huggingface.co/depth-anything/Depth-Anything-V2-Small-hf @ 5426e4f | Apache-2.0 for the Small model only (the larger ones are CC-BY-NC-4.0 and are not used) | Pseudo-labels on 62 M real images including SA-1B ("research purposes only") and ImageNet-21K; teacher labels from synthetic sets including Virtual KITTI 2 (CC BY-NC-SA 3.0) and Hypersim (CC BY-SA 3.0) |
| 3 | Change background, people (Android) | MODNet: converted from huggingface.co/Xenova/modnet ONNX (SHA-256 07c308cf…84df9) | Apache-2.0 (code) | Not documented by the authors |
| 4 | Change background, objects (Android) | U²-Netp: converted from github.com/xuebinqin/U-2-Net @ ac7e1c8 and the README's u2netp.pth (SHA-256 e7567cde…b854) | Apache-2.0 | DUTS-TR |

**Question A (one per model, the same shape):** May Lightly distribute these weights, under their stated licence, in
a paid app, given the training data above, when Lightly never downloaded the datasets or accepted their terms and
distributes no dataset image? In particular: (a) can image owners' or dataset licensors' rights reach trained
weights (are weights an adaptation of the training images, including for the NC and ShareAlike sets); (b) could the
weights' authors grant commercial rights in weights they produced under non-commercial dataset terms; (c) does the
answer differ in [markets]?

## B. Preset catalogue (both platforms) — see `preset-rights.md`
All 2,591 Develop presets are the Lightroom settings of four purchased packs (SolutionPresets, WithLuke Studios ×2,
an unidentified "Huliluts" seller), converted into the app's format and shipped with the vendors' names. No licence
beyond the vendors' store terms (which reserve copying and resale) and no receipts are on file.
**Question B:** with purchase only, may converted preset settings and names be shipped inside a commercial app; is
anything short of a written vendor licence sufficient? (Vendor enquiries are drafted, not sent.)

## C. Trademarks in preset names
"Kodak", "Portra" and "Polaroid" appear in at least 35 preset names (listed in `preset-rights.md`). **Question C:** rename, or is any descriptive use
defensible? (Renaming is the engineering default and needs the owner's copy approval.)

## D. Store and legal texts (`legal-proposals.md` §3)
Governing law and jurisdiction; warranty disclaimer and limitation of liability; Apple's standard EULA or a custom
one, and Google Play's terms; whether an EU or UK representative is required for an app that collects no personal
data (email correspondence only).

## Lower risk, for confirmation only
Four bundled Unsplash background photos (Unsplash License; one shows a person from behind); OFL fonts and Apache-2.0
libraries shipped with their licence texts.
