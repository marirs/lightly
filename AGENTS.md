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

## Mandatory: validate agreed behaviour in the installed app

Validation means checking the actual app against every agreed requirement in the requested scope, including subsequent explicit user amendments. Compilation, passing automated tests, code inspection, another assistant's report, or a few successful flows are not full validation.

- Before validating, enumerate the agreed requirements and conditional states in scope. For a full-app validation, cover all agreed features and flows; do not silently reduce it to a convenient sample.
- Verify controls and categories for the actual photo content. In particular, the Portrait preset category must be hidden when no person is detected, and a hidden category must never be selected as the starting category. Check the preset category separately from the Portrait tool in the dock.
- Check favourites updating immediately when added or removed, consistent state across screens, and persistence across photos and app restarts. Removing a favourite must not remove the applied edit.
- Exercise Auto, preset browsing and application, live dragging, crop, Effects, Undo/Redo and relevant loading, cancellation, failure and recovery states. Check transitions between photos, not only a single happy path.
- Compare appearance, placement, copy and interactions with the approved design and user amendments. Verify that preview and saved output agree and the original is preserved.
- Run applicable checks on the exact installed build and record build identity, platform/device, scenario and evidence. Simulator evidence does not establish physical-device behaviour; one platform does not establish the other.
- Mark each requirement **verified**, **failed** or **untested**. Code inspection can establish an implementation finding, but must not be presented as a device check. Never claim overall validation while required checks are failed or untested; report the actual coverage explicitly.
- Time or tooling limits leave checks untested. They never turn missing evidence into a pass. Do not weaken criteria or change approved references to make the implementation pass.

## Verification throughput

Read `docs/v1/verification-workflow.md` before scheduling builds, tests or screenshot batches. Use `scripts/heavy` for all heavy work, including commands prefixed by `rtk`. A busy lock is pending work, not permission to bypass it or launch automatic retry loops.

## Immediate review budget (2026-10-04)

User requires feedback within ten minutes. Bulk screenshot automation is paused; no automatic restart or bypass via snapshot copies. Follow the intervention section in `docs/v1/verification-workflow.md`. Show existing progress and record pending checks; do not hold handoff behind full matrices. Exact UX acceptance remains unchanged.
