# Lightly project instructions

Read `/Users/sg/.codex/RTK.md` and follow the workspace hygiene instructions supplied by the user.

## Mandatory: exact approved UX

The user explicitly requires **NO UX DEVIATIONS**. This applies to every implementation and every review, on iOS and Android and any later desktop implementation.

- The approved design in `docs/ui/app/` is the source of truth. Earlier explorations in `docs/ui/directions/` are not the target. Read `docs/ui/REVIEW-RULES.md` before every review.
- Match the approved appearance, screen flow, controls, copy, hierarchy, interactions, conditional states, and device-specific layouts exactly. Do not redesign, simplify, substitute, or introduce unapproved alternatives.
- A deviation requires explicit user approval. Engineering convenience, native defaults, passing tests, or reviewer preference do not authorize it.
- Never alter the approved mockups or re-record reference baselines to make a divergent implementation pass review.
- Review against the actual reference screens and interactions. Report mismatches as findings; missing visual or behavioural evidence is unverified, not accepted. Passing code tests alone is not UX approval.
- Technical, correctness, accessibility, and safety reviews remain required; they do not permit silent changes to the approved UX. Raise any conflict explicitly for user resolution.
