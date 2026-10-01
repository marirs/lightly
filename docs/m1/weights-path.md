# M1: a deployable weights path for the auto "develop" step

Status: research note, 2026-10-01. Not legal advice and not legal clearance. Builds on `licensing.md` §4 (4a commissioned retouching, 4b synthetic degradation, 4c FiveK commercial licence, 4d other datasets, 4e compute); those are not repeated here. Every term below was fetched today unless marked *secondary* (press or aggregator, not the primary terms page) or *unverified*.

**Objective used for "quality".** An image-specific global develop (exposure, white balance, tone, colour) that makes a typical phone or camera photo look deliberately graded. Arsenal 2 "Deep Color" is the reference point. That needs learned *taste*, not just correction.

## 1. Ranked options

| # | Option | Weights licence | Training-data terms | Commercial deployability | Quality vs objective | Effort / cost | Confidence | Sources |
|---|---|---|---|---|---|---|---|---|
| 1 | **Hybrid, our own weights.** Pretrain the Apache-2.0 3D-LUT port on synthetic degradations (4b), add zero-reference losses (row 4), fine-tune on 500–1,500 commissioned retoucher pairs (4a). | Ours | Own or commissioned photos with assigned edits. Unsplash Lite only if counsel accepts "internal business purposes". | High, with a clean chain of title. | Best reachable. The retoucher set supplies taste. | ~$2–8k retouching, 6–10 weeks, compute negligible (4e). | Medium-high | licensing.md §4a/4b/4e |
| 2 | **iOS runtime baseline: Core Image `autoAdjustmentFilters`**, called on-device. No training. | n/a (OS API) | n/a | High on iOS when called at runtime in our app. **iOS only**; I found no Android platform equivalent. | Modest and generic: "correcting deficiencies", not a look. Good control or fallback. | Days | High (API exists since iOS 5) | [Apple docs](https://developer.apple.com/documentation/coreimage/ciimage/autoadjustmentfilters(options:)) |
| 3 | **The paper's unpaired (WGAN) variant.** Inputs are our flat RAW renders. The "good" target distribution is licensed finished photos (Unsplash Lite, Getty sample or licensed stock). | Ours | Same as the source sets | High if the sources are clean | Medium. It learns "look like stock", with GAN instability. The paper's unpaired results trail its paired ones. | 1–3 weeks of engineering; 2–3× paired compute | Medium | licensing.md §4e; upstream repo |
| 4 | **Zero-reference losses** (Zero-DCE's exposure, colour-constancy, spatial and smoothness losses), re-implemented from the paper as an auxiliary objective. | Ours. **Do not copy Zero-DCE code:** "for non-commercial use only", CC BY-NC 4.0. | Any licensed unedited photos | High if clean-room | Corrective only (exposure, WB). No style. | ~1 week | Medium-high | [Zero-DCE](https://github.com/Li-Chongyi/Zero-DCE), [Zero-DCE++](https://github.com/Li-Chongyi/Zero-DCE_extension) |
| 5 | **Licensed stock as inputs or targets**: Shutterstock data licensing, Getty custom datasets, Wirestock, Defined.ai. | Ours | Shutterstock: opted-in contributors are paid "a 20% average corporate royalty". Getty offers "purpose-built datasets… for your exclusive use". None of them sells *paired expert edits* off the shelf. | Likely high under a negotiated licence; contract needed. | Supplies inputs and targets, not edits. Could be paired with option 1's retoucher. | Custom quotes only. *Secondary* reports: ~$0.03–0.10/image (Wirestock), ~$1–2/image (Defined.ai). | Medium (prices unverified) | [Shutterstock contributor help](https://submit.shutterstock.com/help/en/articles/10594694-shutterstock-data-licensing-and-the-contributor-fund), [Getty data licensing](https://www.gettyimages.in/enterprise/data-licensing), [DIYP on Wirestock (secondary)](https://www.diyphotography.net/this-platform-pays-you-to-use-your-photos-for-ai-dataset-training/) |
| 6 | **Getty sample dataset on Hugging Face** (3,750 images) as extra targets or an eval set. | Ours | *Secondary:* free to use; bans redistribution and products "that would directly compete with Getty". Dataset card not fetched. | Probably fine for a photo editor. Verify the card. | Too small to train on alone. | Free | Low-medium | [tech.co (secondary)](https://tech.co/news/dataset-getty-images-developers) |
| 7 | **CLIP or aesthetic score as a training-time reward or ranker.** Not shipped. | OpenAI CLIP: MIT code. The aesthetic predictor is Apache-2.0. | The CLIP card says "**Any** deployed use case… is currently out of scope". The predictor is trained on AVA + LAION logos + SAC (AVA terms unverified). LAION-trained OpenCLIP inherits LAION's dataset caveats. Apple MobileCLIP is `apple-amlr`, which excludes "use in any commercial product". | Medium. The weights never ship, but training-time use of research-terms models is a counsel question. Do not use MobileCLIP. | Can push towards "pleasing". Prone to reward hacking (oversaturation). Auxiliary only. | ~1–2 weeks | Medium-low | [CLIP model card](https://github.com/openai/CLIP/blob/main/model-card.md), [aesthetic predictor](https://github.com/christophschuhmann/improved-aesthetic-predictor), [MobileCLIP-S2](https://huggingface.co/apple/MobileCLIP-S2), [open_clip](https://github.com/mlfoundations/open_clip) |
| 8 | **darktable or RawTherapee as the input renderer or a weak teacher.** | Ours | GPL does not reach outputs. GNU FAQ: output copyright "inherits that of the input". | High for producing neutral "flat" inputs from our RAWs. | Weak as a teacher: their auto modes are basic. Strong as the input-side renderer for row 1. | Days | High (output); medium (fit) | [GNU GPL FAQ](https://www.gnu.org/licenses/gpl-faq.html#GPLOutput) |
| 9 | **Distil Apple Core Image auto outputs offline** and ship the student on both platforms. | Ours | Xcode and Apple SDKs Agreement §2.2.C: you will not "use output generated from an Apple model to train… another artificial intelligence model". It is unclear whether `autoAdjustmentFilters` (heuristics plus face detection) counts as an "Apple model". A developer-forum "it's fine" reply is from a non-Apple user. | **Avoid** without written counsel or Apple sign-off. | Would match option 2 at best. | — | High on the clause; low on its scope | Xcode agreement (apple.com/legal/sla/docs/xcode.pdf, EA2002); [forum thread](https://developer.apple.com/forums/thread/822330) |
| 10 | **Distil Lightroom Auto.** | — | Adobe General Terms §17 (updated 3 Oct 2025) bans using "any content, data, output" derived from Adobe Services or Software to "create, train, test, or otherwise improve" ML. | **No.** | — | — | High | [Adobe General Terms](https://www.adobe.com/legal/terms.html) |
| 11 | **Off-the-shelf weights** (none usable, details below). | Mostly Apache-2.0 or MIT code | FiveK, PPR10K or research-only data | **No** | — | — | High | see below |

### Off-the-shelf weights checked (row 11)
- **Image-adaptive LUT family.** AdaInt and SepLUT are Apache-2.0, but their weights are trained on FiveK and PPR10K. CLUT-Net states no licence and its weights are FiveK/PPR10K. I could not find the 4D-LUT or LUTwithBGrid repos at the URLs I tried, so those are *unverified*, but the papers benchmark on FiveK/PPR10K. ([AdaInt](https://github.com/ImCharlesY/AdaInt), [SepLUT](https://github.com/ImCharlesY/SepLUT), [CLUT-Net](https://github.com/Xian-Bei/CLUT-Net))
- **Google HDRNet.** Apache-2.0 code. The README does not document what trained its pretrained models. The paper's tasks use FiveK and HDR+-style data, so treat them as tainted. ([hdrnet](https://github.com/google/hdrnet))
- **Hugging Face tags can mislead.** `google/maxim-s2-enhancement-fivek` is tagged `apache-2.0` but was trained on FiveK. A licence tag is not data clearance; check the training set on every candidate. ([card](https://huggingface.co/google/maxim-s2-enhancement-fivek))
- **Model zoos.** Qualcomm AI Hub (BSD-3 repo, per-model licences) lists denoise, deblur, super-resolution, colourisation and inpainting, with no global tone/colour model. The opencv_zoo, ONNX Model Zoo (deprecated) and MediaPipe Solutions have no enhancement or tone task. ([AI Hub](https://github.com/quic/ai-hub-models), [opencv_zoo](https://github.com/opencv/opencv_zoo), [ONNX](https://github.com/onnx/models), [MediaPipe](https://developers.google.com/edge/mediapipe/solutions/guide))
- **Not checked:** NVIDIA NGC, and Adobe-released research weights (generally FiveK-derived when they exist). SICE terms were not checked because Zero-DCE is non-commercial anyway.

**Bottom line:** I found no off-the-shelf tone/colour weights that are both commercially licensed and trained on documented commercial data. The deployable path is to train our own weights.

## 2. Recommended path

1. **Ship option 2 on iOS as the immediate "Auto" baseline and control arm.** It is legally simplest and needs no data. Android needs its own simple heuristic as a stopgap (e.g. histogram stretch plus gray-world WB, our code).
2. **Build option 1 as the product model:**
   - *Inputs:* our own or commissioned RAWs, flat-rendered through a neutral pipeline (option 8 tools are acceptable).
   - *Pretraining:* synthetic degradation (4b) plus the zero-reference losses (option 4).
   - *Fine-tuning:* one retoucher's paired edits to a written "Lightly look" style guide.
3. Treat **options 3, 5 and 7 as add-ons**, adopted only if they beat the baseline in a blind A/B test.
4. **Do not use** options 9, 10 or 11.

### Week 1 (concrete)
1. **Eval harness first.**
   - Assemble 150–300 photos we own (team phones plus 2–3 DSLR/mirrorless RAW sets), with written IP assignment from staff.
   - Define a blind pairwise preference test: retoucher/PM raters, our model vs Core Image auto vs Arsenal-style reference edits made by our retoucher.
2. **Baseline.** Run `autoAdjustmentFilters` over the eval set (runtime-style use only; store the outputs for comparison, never as training targets) to get the bar to beat.
3. **Pretraining experiment.**
   - Implement the synthetic-degradation sampler and the four zero-reference losses (clean-room from the paper, citing the equations in code comments).
   - Kick off a pretraining run of the existing port on our own photos only, so it does not wait on the Unsplash Lite counsel answer.
4. **Procurement emails:**
   - two retouching vendors, quoting 1,500 global-only edits with copyright assignment and an ML-training grant;
   - Getty and Shutterstock data-licensing sales, asking whether they can supply *paired RAW + professional edit* custom sets, with a price per pair.
5. **Send counsel the open questions below.**

## 3. Open questions (counsel or vendors)

1. Does Xcode Agreement §2.2.C(2), "output generated from an Apple model", cover Core Image auto-adjust? Does that matter if the outputs are used only as eval references?
2. Is training-time use of CLIP (card: deployed use "out of scope") or an AVA/LAION-trained aesthetic scorer acceptable when those weights never ship?
3. Does the Unsplash Lite "internal business purposes" clause cover a model shipped in a paid app? (Carried over from licensing.md.)
4. Do Getty's sample-set terms on products that "compete with Getty" exclude a photo editor? The dataset card text still needs fetching.
5. Can stock vendors provide paired edits, at what price per pair, and with what indemnity?
6. Moral rights and AI-training grants in the retoucher contract for the vendor's jurisdiction.
7. Is opt-in use of user edits as future training data (a data flywheel) feasible under our privacy policy and the App Store and Play rules? This is not researched here.
8. **Quality risk:** can 500–1,500 pairs plus pretraining reach a "Deep Color"-like look? This is unproven until the week-1 harness gives numbers.
