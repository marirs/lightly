# Preset names: final proposal (awaiting the owner's choice, 2026-10-06)

Not applied. The shipped names (`shared/look-pack/names/display-names.json`) are unchanged until you choose.
Supersedes `preset-name-collisions.md` (letters) and `preset-variant-names.md` (measured words); both are withdrawn.

## 1. Same name in different categories: 25 names
Keep the readable name. Where the two could be confused, show the category:
- On a category's ruler the selected tab already names the category; while browsing elsewhere the context line does
  ("Applied from Landscape · 37 / 518"). No change there.
- **Favourites** mixes categories. Proposed: when a favourite's name also exists in another category, the context line
  under the name shows its category, e.g. **"Dark Aesthetic 1"** with **"Travel"** below it. This adds text to the
  approved Favourites state, so it needs your approval.

## 2. Same name within one category: 73 groups, 148 presets
Stable variant numbers bound to preset ids:
- The member whose catalogue name has no numbering or code prefix of its own keeps the plain name
  ("Nordic 01" → **Nordic 1**).
- The others get **"· Variant 2"**, **"· Variant 3"** ("01 Nordic 01" → **Nordic 1 · Variant 2**).
  Ties are broken by preset id.
- The name's own number is kept once, never doubled. Prefixes such as "01 …", "P13 - " and "C4 - " are already dropped by
  the existing clean-up.
- Each preset keeps the name assigned to its id when applied. A later catalogue reorder or extension never moves a name
  to another preset; a new preset joining a group takes the next free variant number.

Representative examples:

| Category | Catalogue name | Proposed |
|---|---|---|
| Travel | Nordic 01 · 01 Nordic 01 | Nordic 1 · Nordic 1 · Variant 2 |
| Travel | Adventure 3 · Adventure 03 · 03 Adventure 03 | Adventure 3 · Adventure 3 · Variant 2 · Adventure 3 · Variant 3 |
| Film | Vintage 7 · 07 Vintage 07 | Vintage 7 · Vintage 7 · Variant 2 |
| Cinematic | Teals · C4 - Teals | Teals · Teals · Variant 2 |
| Portrait | T1 - Cinematic Film · P13 - Cinematic Film | Cinematic Film · Cinematic Film · Variant 2 (both prefixed: id order) |
| Landscape | Dark Green 4 · Dark Green 04 | Dark Green 4 · Dark Green 4 · Variant 2 (neither prefixed: id order) |

Apply after approval: `python3 shared/look-pack/display_names.py --apply-numbered`; both apps read the same file.

## Your choice
1. Approve §2 as written, or change the suffix form (e.g. "Nordic 1 (2)").
2. Approve or decline the Favourites category line in §1.

## Appendix A: names in more than one category

| Name | Categories |
|---|---|
| Dark Aesthetic 1 | Cinematic, Travel |
| Dark Aesthetic 10 | Cinematic, Travel |
| Dark Aesthetic 2 | Cinematic, Travel |
| Dark Aesthetic 3 | Cinematic, Travel |
| Dark Aesthetic 4 | Cinematic, Travel |
| Dark Aesthetic 5 | Cinematic, Travel |
| Dark Aesthetic 6 | Cinematic, Travel |
| Dark Aesthetic 7 | Cinematic, Travel |
| Dark Aesthetic 8 | Cinematic, Travel |
| Dark Aesthetic 9 | Cinematic, Travel |
| Forest | Cinematic, Portrait |
| Popped Film | Film, Portrait |
| Vintage 7 | Black & White, Film |
| Wild | Cinematic, Landscape |
| Winter | Cinematic, Landscape, Portrait |
| Winter 1 | Landscape, Street |
| Winter 10 | Landscape, Street |
| Winter 2 | Landscape, Street |
| Winter 3 | Landscape, Street |
| Winter 4 | Landscape, Street |
| Winter 5 | Landscape, Street |
| Winter 6 | Landscape, Street |
| Winter 7 | Landscape, Street |
| Winter 8 | Landscape, Street |
| Winter 9 | Landscape, Street |

## Appendix B: all 148 renamed presets

| Category | Catalogue name | Proposed | Preset id |
|---|---|---|---|
| Cinematic | Black Moody 02 | Black Moody 2 | `look-11f3c5b6d0b58ef07828` |
| Cinematic | Black Moody 2 | Black Moody 2 · Variant 2 | `look-61e9abd52300fbbcd8a3` |
| Cinematic | Black Moody 03 | Black Moody 3 | `look-819696464379216ba4b2` |
| Cinematic | Black Moody 3 | Black Moody 3 · Variant 2 | `look-dd39a61ab20a0ddc7849` |
| Cinematic | CCX4 - Blue | Tropical | Blue · Tropical | `look-0718f378e2edb75e43db` |
| Cinematic | CC34 - Blue | Tropical | Blue · Tropical · Variant 2 | `look-3bab1844688c5026f491` |
| Cinematic | Cinematic 2 | Cinematic 2 | `look-883f22c19fcb6a03ec15` |
| Cinematic | 02 Cinematic 02 | Cinematic 2 · Variant 2 | `look-4a6b2885c44f58938665` |
| Cinematic | Cinematic 3 | Cinematic 3 | `look-d7a39d7477e8e75c498c` |
| Cinematic | 03 Cinematic 03 | Cinematic 3 · Variant 2 | `look-8bb455da0872c779d0e8` |
| Cinematic | Cinematic 4 | Cinematic 4 | `look-436a32d19256af8b1f3e` |
| Cinematic | 04 Cinematic 04 | Cinematic 4 · Variant 2 | `look-e7011fae68436bcb2682` |
| Cinematic | Dreamy 2 | Dreamy 2 | `look-3c56d0a6aee9061573d6` |
| Cinematic | Dreamy 02 | Dreamy 2 · Variant 2 | `look-49eb005a759d0fd3b023` |
| Cinematic | Moody 01 | Moody 1 | `look-7505d6bf309f698dbd5f` |
| Cinematic | Moody 1 | Moody 1 · Variant 2 | `look-9c336f9be0f95528ae64` |
| Cinematic | Moody 2 | Moody 2 | `look-42065aab536f74b3727f` |
| Cinematic | Moody 02 | Moody 2 · Variant 2 | `look-aac1a9ba17b2ce542e35` |
| Cinematic | Moody 03 | Moody 3 | `look-21988037c57f381fe432` |
| Cinematic | Moody 3 | Moody 3 · Variant 2 | `look-39fdd77c99ae00a29683` |
| Cinematic | Teals | Teals | `look-68b385667dc799703788` |
| Cinematic | C4 - Teals | Teals · Variant 2 | `look-f7e7ab9335d0f2deca1f` |
| Film | Film 12 | Film 12 | `look-19bc30a8dc1af4c31ee2` |
| Film | 12 Film 12 | Film 12 · Variant 2 | `look-7c3b62269d96fc62f5b6` |
| Film | Film 13 | Film 13 | `look-abafa543eb4da5a518c3` |
| Film | 13 Film 13 | Film 13 · Variant 2 | `look-312949fb2581494fa9cc` |
| Film | Vintage 10 | Vintage 10 | `look-572c1880c8b609ce584e` |
| Film | 10 Vintage 10 | Vintage 10 · Variant 2 | `look-d32e0077f7b26f120a80` |
| Film | Vintage 11 | Vintage 11 | `look-9c61922a98e67625e634` |
| Film | 11 Vintage 11 | Vintage 11 · Variant 2 | `look-d4933fb8e90beb4dee29` |
| Film | Vintage 12 | Vintage 12 | `look-04679fc05581be5a519c` |
| Film | 12 Vintage 12 | Vintage 12 · Variant 2 | `look-ac2b578d7bc2e173422a` |
| Film | Vintage 13 | Vintage 13 | `look-78f5164acffdc150f9ea` |
| Film | 13 Vintage 13 | Vintage 13 · Variant 2 | `look-67cd7349989f41f591f9` |
| Film | Vintage 14 | Vintage 14 | `look-b0b817ae154514a6da0e` |
| Film | 14 Vintage 14 | Vintage 14 · Variant 2 | `look-754caca2ae813481384e` |
| Film | Vintage 15 | Vintage 15 | `look-b89b130282325b2981b1` |
| Film | 15 Vintage 15 | Vintage 15 · Variant 2 | `look-6fa79c59474629c5b175` |
| Film | Vintage 7 | Vintage 7 | `look-1475403eba2a058a1e60` |
| Film | 07 Vintage 07 | Vintage 7 · Variant 2 | `look-fe12dfb554bc1eb50f5c` |
| Film | Vintage 8 | Vintage 8 | `look-ba2626e872370763026d` |
| Film | 08 Vintage 08 | Vintage 8 · Variant 2 | `look-670aa838e13aa13e0091` |
| Film | Vintage 9 | Vintage 9 | `look-f48e03e3ae6f3bf4a6a3` |
| Film | 09 Vintage 09 | Vintage 9 · Variant 2 | `look-c58294231374cc1abafd` |
| Landscape | Dark Green 1 | Dark Green 1 | `look-67954da363306c58f5c9` |
| Landscape | Dark Green 01 | Dark Green 1 · Variant 2 | `look-84609a7f3e8d34b3191d` |
| Landscape | Dark Green 3 | Dark Green 3 | `look-8d5031777ed9507ec72f` |
| Landscape | Dark Green 03 | Dark Green 3 · Variant 2 | `look-d6f60dedda8d2316fa92` |
| Landscape | Dark Green 4 | Dark Green 4 | `look-c18c7c76a1f417411cbd` |
| Landscape | Dark Green 04 | Dark Green 4 · Variant 2 | `look-c5a3308f2e4acd97bcfa` |
| Landscape | Dark Green 05 | Dark Green 5 | `look-397011a64cc9d139d911` |
| Landscape | Dark Green 5 | Dark Green 5 · Variant 2 | `look-452f9b0db5e054284588` |
| Portrait | T1 - Cinematic Film | Cinematic Film | `look-205a0ec0c9e89ac0c1a1` |
| Portrait | P13 - Cinematic Film | Cinematic Film · Variant 2 | `look-3c475346d99a417eb81d` |
| Portrait | Fitness 2 | Fitness 2 | `look-2ac4712dca45f63253a9` |
| Portrait | 02 Fitness 02 | Fitness 2 · Variant 2 | `look-63237a87d002845b989b` |
| Portrait | Fitness 3 | Fitness 3 | `look-9ecba516417a1e666e59` |
| Portrait | 03 Fitness 03 | Fitness 3 · Variant 2 | `look-656ed1be040266f417f5` |
| Portrait | Fitness 4 | Fitness 4 | `look-78d5c93df4683b0c2847` |
| Portrait | 04 Fitness 04 | Fitness 4 · Variant 2 | `look-33a00e4f930e42c4360b` |
| Street | Neon Lights 01 | Neon Lights 1 | `look-239ed5e0bb1112ca2a9a` |
| Street | 01 Neon Lights 01 | Neon Lights 1 · Variant 2 | `look-337aa61c1d59651e32f6` |
| Street | Neon Lights 02 | Neon Lights 2 | `look-8337be24bf94dfe7e026` |
| Street | 02 Neon Lights 02 | Neon Lights 2 · Variant 2 | `look-004a780d2470c7bac0bc` |
| Street | Neon Lights 03 | Neon Lights 3 | `look-d5bccd8e9156a83f655b` |
| Street | 03 Neon Lights 03 | Neon Lights 3 · Variant 2 | `look-b14cac1c0ef5f6772e60` |
| Street | Neon Lights 04 | Neon Lights 4 | `look-90ce3547c12a7843a3cf` |
| Street | 04 Neon Lights 04 | Neon Lights 4 · Variant 2 | `look-8f50377ca1af789677e7` |
| Street | Neon Lights 05 | Neon Lights 5 | `look-3b63546889942372b393` |
| Street | 05 Neon Lights 05 | Neon Lights 5 · Variant 2 | `look-52d87e62a0b8e8b6e7ec` |
| Street | Neon Lights 06 | Neon Lights 6 | `look-76072b0d14cef838e380` |
| Street | 06 Neon Lights 06 | Neon Lights 6 · Variant 2 | `look-1d1cbe8f7f681494c972` |
| Street | Neon Lights 07 | Neon Lights 7 | `look-4f0d9acf1b0e99052f00` |
| Street | 07 Neon Lights 07 | Neon Lights 7 · Variant 2 | `look-82a1e707e30ed14d31fb` |
| Street | Neon Lights 08 | Neon Lights 8 | `look-ee5be234f4e7fcca9d81` |
| Street | 08 Neon Lights 08 | Neon Lights 8 · Variant 2 | `look-f8c6aa5cc9fb3b249381` |
| Street | Urban 01 | Urban 1 | `look-64a0320f1adc1350d711` |
| Street | 01 Urban 01 | Urban 1 · Variant 2 | `look-7b66d700c3801fa48ea7` |
| Street | Urban 10 | Urban 10 | `look-435d1e08c91c9ae81367` |
| Street | 10 Urban 10 | Urban 10 · Variant 2 | `look-c759960ecfcf6cb86482` |
| Street | Urban 02 | Urban 2 | `look-198b7fb3a06e597fdded` |
| Street | 02 Urban 02 | Urban 2 · Variant 2 | `look-e91efa16571e15efe7b1` |
| Street | Urban 03 | Urban 3 | `look-ff30516ac95912c07292` |
| Street | 03 Urban 03 | Urban 3 · Variant 2 | `look-f69086e6e4afa45109b5` |
| Street | Urban 04 | Urban 4 | `look-627eadce60a7f83108e4` |
| Street | 04 Urban 04 | Urban 4 · Variant 2 | `look-a637353c3b90f816ed87` |
| Street | Urban 05 | Urban 5 | `look-aadc956959374e22cbf2` |
| Street | 05 Urban 05 | Urban 5 · Variant 2 | `look-adaaf44e70826e4ff188` |
| Street | Urban 06 | Urban 6 | `look-91038ce0678432276484` |
| Street | 06 Urban 06 | Urban 6 · Variant 2 | `look-247a30ebf0d01c0710d8` |
| Street | Urban 07 | Urban 7 | `look-f1b71d10d30cceedccf0` |
| Street | 07 Urban 07 | Urban 7 · Variant 2 | `look-4c7cfcbb5f4c1c633bb0` |
| Street | Urban 08 | Urban 8 | `look-81076684fe251f9edae4` |
| Street | 08 Urban 08 | Urban 8 · Variant 2 | `look-65c420cad0dc2fb9d3ef` |
| Street | Urban 09 | Urban 9 | `look-57fafd86a7acb8ab70d8` |
| Street | 09 Urban 09 | Urban 9 · Variant 2 | `look-214d4c1e20e55374771d` |
| Travel | Adventure 1 | Adventure 1 | `look-c0cf9e877abc6e2a762f` |
| Travel | 01 Adventure 01 | Adventure 1 · Variant 2 | `look-797d691fcc023b8f356e` |
| Travel | Adventure 10 | Adventure 10 | `look-252a74f6ff4fb8a612df` |
| Travel | 10 Adventure 10 | Adventure 10 · Variant 2 | `look-3ccc52f54557c45d5b1e` |
| Travel | Adventure 11 | Adventure 11 | `look-cc4ce7acc2c639180204` |
| Travel | 11 Adventure 11 | Adventure 11 · Variant 2 | `look-bae7a08784414a46dd28` |
| Travel | Adventure 12 | Adventure 12 | `look-eba668b0393717f8d636` |
| Travel | 12 Adventure 12 | Adventure 12 · Variant 2 | `look-19b9de0e65bad356436f` |
| Travel | Adventure 13 | Adventure 13 | `look-55952e6a5db360a94f08` |
| Travel | 13 Adventure 13 | Adventure 13 · Variant 2 | `look-aae6bfb0f96f60abfa00` |
| Travel | Adventure 14 | Adventure 14 | `look-470b42704c0a88d91ffa` |
| Travel | 14 Adventure 14 | Adventure 14 · Variant 2 | `look-42d76b6c1c99f3aa678e` |
| Travel | Adventure 15 | Adventure 15 | `look-0884c74d0ed0912bc0e3` |
| Travel | 15 Adventure 15 | Adventure 15 · Variant 2 | `look-a035fa123476aaae7050` |
| Travel | Adventure 2 | Adventure 2 | `look-ac429d8d47f2d405b5f1` |
| Travel | 02 Adventure 02 | Adventure 2 · Variant 2 | `look-c1338497b6fab1b69f1c` |
| Travel | Adventure 3 | Adventure 3 | `look-45e650dd9eb0391e702f` |
| Travel | Adventure 03 | Adventure 3 · Variant 2 | `look-5e7ef91d7970b23e7777` |
| Travel | 03 Adventure 03 | Adventure 3 · Variant 3 | `look-c743c8f85eb448fcafd6` |
| Travel | Adventure 4 | Adventure 4 | `look-9c83a7f2a18905f3910a` |
| Travel | Adventure 04 | Adventure 4 · Variant 2 | `look-eead711e494e3660109f` |
| Travel | 04 Adventure 04 | Adventure 4 · Variant 3 | `look-9b48a4419f584fc2c080` |
| Travel | Adventure 5 | Adventure 5 | `look-278fa2727d6b7b2decd0` |
| Travel | 05 Adventure 05 | Adventure 5 · Variant 2 | `look-bda64de372663d822b98` |
| Travel | Adventure 6 | Adventure 6 | `look-1c2f27ad5065143895cc` |
| Travel | 06 Adventure 06 | Adventure 6 · Variant 2 | `look-7baa82cc4a484799df74` |
| Travel | Adventure 7 | Adventure 7 | `look-2338c56512175f52cdb6` |
| Travel | 07 Adventure 07 | Adventure 7 · Variant 2 | `look-0d00c0a0aeec89d5fecc` |
| Travel | Adventure 8 | Adventure 8 | `look-3f5431866c30f2c230d3` |
| Travel | 08 Adventure 08 | Adventure 8 · Variant 2 | `look-d932f7d2e955ae5d9cfa` |
| Travel | Adventure 9 | Adventure 9 | `look-d2f4bb45946e488462f8` |
| Travel | 09 Adventure 09 | Adventure 9 · Variant 2 | `look-7efc1a20ad9ed31b8404` |
| Travel | Nordic 01 | Nordic 1 | `look-756b8beab082699b4691` |
| Travel | 01 Nordic 01 | Nordic 1 · Variant 2 | `look-f289ba055f22d3124837` |
| Travel | Nordic 10 | Nordic 10 | `look-b6c27dba8ea69a1e9d9a` |
| Travel | 10 Nordic 10 | Nordic 10 · Variant 2 | `look-40c963e94eddf4484f74` |
| Travel | Nordic 02 | Nordic 2 | `look-8e214b41a115d90016af` |
| Travel | 02 Nordic 02 | Nordic 2 · Variant 2 | `look-e2769665004557dd6edf` |
| Travel | Nordic 03 | Nordic 3 | `look-9ddb3012d13aec7a84e2` |
| Travel | 03 Nordic 03 | Nordic 3 · Variant 2 | `look-e0aef4f589a51e7fd0b4` |
| Travel | Nordic 04 | Nordic 4 | `look-fd3e4bb65befb9ee9699` |
| Travel | 04 Nordic 04 | Nordic 4 · Variant 2 | `look-6763bba37b26f92e3343` |
| Travel | Nordic 05 | Nordic 5 | `look-0a004bfde691126a0c06` |
| Travel | 05 Nordic 05 | Nordic 5 · Variant 2 | `look-dbd16558ff5482b3fc6a` |
| Travel | Nordic 06 | Nordic 6 | `look-5e07099e0975f381d8ee` |
| Travel | 06 Nordic 06 | Nordic 6 · Variant 2 | `look-ba3cade834cbbd69cabf` |
| Travel | Nordic 07 | Nordic 7 | `look-6b2508f29713933994b7` |
| Travel | 07 Nordic 07 | Nordic 7 · Variant 2 | `look-9305df741ca8feec93da` |
| Travel | Nordic 08 | Nordic 8 | `look-9b0c5d4d834f1c29eda0` |
| Travel | 08 Nordic 08 | Nordic 8 · Variant 2 | `look-84dde337964d6e207f2c` |
| Travel | Nordic 09 | Nordic 9 | `look-6571e162a0bd9dfa193e` |
| Travel | 09 Nordic 09 | Nordic 9 · Variant 2 | `look-0b43acb90efb922d6e21` |
