# Preset rights: pack-by-pack audit and draft vendor enquiries (2026-10-07)

> **DRAFT FOR THE OWNER'S REVIEW. NOT LEGAL ADVICE. No vendor has been contacted.** Trademark naming (Kodak,
> Portra, Polaroid) is a separate question, at the end; it is not a redistribution right.

## What ships from the packs (both platforms unless stated)
Every one of the 2,591 Develop presets traces to one of four purchased folders (`dependencies.md` §9):
the vendor's Lightroom slider and curve values converted into the look pack, and the vendor's preset names verbatim.
iOS also bundles `presets_photo.json` and `luts_video.json`, whose `originPath` fields name the vendor packs.

## Two different permissions
- **Editing your own photographs** with a purchased preset: what a buyer normally gets. Nothing found limits it, and
  it is not what Lightly needs.
- **Redistributing the presets** (files, or settings converted into another format) and their names inside an app
  sold or given to other people: Lightly's use. No document found grants it; the vendors' published terms (below)
  reserve copying and resale. This is the missing permission.

## Evidence found, pack by pack
Searched: every file in `/Users/sg/Downloads/Presets - for lightly/` (36 zips listed, all PDFs and text files read),
`~/Downloads`, and a Spotlight search of the home folder for the vendor names; the vendors' own websites. **No
licence, EULA, terms file, receipt or order confirmation for any pack exists on this Mac.** The packs contain only
installation guides; the WithLuke guide opens "Many thanks for purchasing my Preset Collection!".

| Pack (presets shipped) | Seller found | Published terms (read 2026-10-07) | Purchase record | Missing |
|---|---|---|---|---|
| SolutionPresets (970) | SolutionPresets, solutionpresets@gmail.com (solutionpresets.com) | Store terms of service: "You agree not to reproduce, duplicate, copy, sell, resell or exploit any portion of the Service"; no product licence for presets | None on this Mac | Receipt; written permission to redistribute converted settings and names in a commercial app |
| WithLuke studios (590) | WithLuke Studios (Luke Stackpoole), info@withlukestudios.com (withlukestudios.com) | Store terms of service: the same reproduce/resell clause; no product licence; no FAQ page | None on this Mac | Receipt; written permission, as above |
| WithLuke - Master Collection (218) | Same seller (the guide is "WithLuke Presets User Guide 2025") | As above | None on this Mac | Covered by the same enquiry |
| The Ultimate Preset Bundle - Huliluts (813) | **Not identified.** No site or terms for "Huliluts" found. A same-named product, "Ultimate Preset Bundle", is sold by H&V Presets (790 presets per format); whether "Huliluts" is the author, a reseller or an unauthorised copy is unknown | None found | None on this Mac | First: who sold it and whether the seller had rights; then permission from the actual author |

Sources: https://solutionpresets.com/pages/terms-of-service, https://withlukestudios.com/policies/terms-of-service,
https://www.withluke.com/ (links to withlukestudios.com for presets).

## The four purchased packs and what each needs
A receipt identifies the purchase and the seller; it does not grant redistribution. Permission must come from the
licence that governs the pack or, failing one, from the rights holder (the presets' author, or whoever the author
licensed to sell them).

| # | Pack (folder in `~/Downloads/Presets - for lightly/`) | Presets shipped | What is on disk (no licence in any) | Needed |
|---|---|---|---|---|
| 1 | **SolutionPresets** — products: Black Presets, Car Presets, Cinematic Presets, Influencer Bundle, iPhone - Movies Presets, and "Presets" for Android / iPhone / Desktop | 970 | 24 zips (Android, iPhone, Desktop variants), downloaded 15 Aug 2026 | Order confirmation(s) naming the products; the licence or EULA in force at purchase (the store's terms reserve copying and resale and name no product licence); written permission from SolutionPresets (solutionpresets@gmail.com) as rights holder, after confirming they authored the presets |
| 2 | **The Ultimate Preset Bundle - Huliluts** (incl. "New Update … 20.5.2026", "Analog Film V2") | 813 | 598 XMP, 598 DNG, 597 CUBE; guides only | First: who sold it (receipt, store, URL) and who authored it. A product of the same name (790 presets per format) is sold by H&V Presets; "Huliluts" may be the author, a reseller or an unauthorised copy. Then the licence and the author's written permission. If the seller had no rights, this pack cannot be licensed through this purchase |
| 3 | **WithLuke studios** — Master Lightroom Presets Collection, Complete Collection Video LUTs Parts 1–3, Rich Black Video LUTs | 590 | 1,180 XMP, 590 lrtemplate, 366 CUBE; Shopify zip names dated 27 Feb 2024 and 12 Nov 2025 | Order confirmation; the product licence (the store terms reserve copying and resale; no product licence found); written permission from WithLuke Studios (Luke Stackpoole, info@withlukestudios.com) |
| 4 | **WithLuke - Master Collection** (2025, with the "2025 Additional Update", Legacy and Cinematic collections) | 218 | 497 XMP, 206 lrtemplate, 126 DNG; "WithLuke Presets User Guide 2025" ("Many thanks for purchasing my Preset Collection!") | Same seller as 3: order confirmation, product licence, and the same permission (one enquiry covers 3 and 4) |

For every pack the permission has to cover, in writing: converting the Lightroom settings into Lightly's own format;
shipping them inside a paid app on iOS and Android in [markets]; showing the vendor's preset names (or our own); for
how long; any fee and credit; and confirmation that the grantor holds the rights.

Engineering, once rights are settled: remove `originPath` and vendor names from the shipped iOS JSON (and decide
whether `presets_photo.json` and `luts_video.json` ship at all).

## Draft enquiries (for your review; none is sent until you authorise it)

**Enquiry A, to SolutionPresets (solutionpresets@gmail.com), pack 1. Enquiry B, to WithLuke Studios
(info@withlukestudios.com), packs 3 and 4.** Same text, with each pack's product names and counts.

Subject: Licence to include your presets in a photo-editing app

> Hello,
>
> I bought [product names, order numbers and dates] from you. I am building Lightly, a photo editor for iPhone, iPad
> and Android (lightly.pro). I would like to include [number] of your presets in it, converted from your Lightroom
> settings into the app's own format, under your preset names [or: under names we choose], as built-in looks that
> people apply to their own photos. The app does not export or share the preset files or settings.
>
> Your store's terms do not cover this use, so I am asking for written permission. Could you tell me whether you
> would grant a licence for it, on what terms (fee, credit, territory, duration), and confirm that you are the author
> of all the presets in these packs or hold the rights to license them?
>
> [Name, operator and address: owner facts still open]

**Enquiry C, pack 2 ("Huliluts"): not addressable yet.** The receipt or the store page must name the seller first. If
it was H&V Presets (or another author's shop), Enquiry A's text goes to them with: "Please confirm that you are the
author of this bundle." If the seller cannot be identified or had no rights, these 813 presets cannot be licensed
through that purchase.

## Trademark names (separate question)
Display names containing "Kodak", "Portra" (Kodak Portra 1–10, Portra 400 01–09, Landscape 5 - Kodak, Aerial 9 -
Kodak Aerial, 16 - (Portrait) Kodak 2, CC41 - Portrait | Kodak X) and "Polaroid" (Polaroid - 1–12). A vendor
permission would not cover these marks. Options: rename them (D3 preset-name proposal; a copy change that needs your
approval) or a trademark clearance by counsel.
