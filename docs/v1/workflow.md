# Implementation workflow: heavy jobs and comparison evidence

These rules come from the product owner (2026-10-03). They apply to every agent working on Lightly. `AGENTS.md` and `docs/ui/REVIEW-RULES.md` still govern what counts as a match.

## One heavy job at a time, enforced

A heavy job is any build or test run, and any simulator or emulator session. Only one may run at a time.

- **Wrapper:** run every heavy job as `scripts/heavy <label> <command...>`. It holds `/tmp/lightly-heavy.lock`, and a second caller waits until the first finishes.
- **Hook:** `.claude/settings.json` runs `scripts/hooks/require_heavy_lock.py` before every Bash command. It refuses heavy commands that don't go through the wrapper:
  - `xcodebuild`, `gradle`/`gradlew`, `emulator`, `qemu-system*`;
  - `simctl boot`, `install`, `launch` and `io`;
  - `open -a Simulator`;
  - `swift build` and `swift test`.

  It also refuses the iOS Simulator MCP build tool, which cannot take the lock. Its cases are in `scripts/hooks/test_require_heavy_lock.py`.
- **Device cleanup:** the wrapper shuts down every simulator and emulator when it takes the lock and again when the job ends. Do a whole device session (boot, install, every capture, tests) in one invocation, for example `scripts/heavy android-captures bash -c '...'`.
- **Log:** `/tmp/lightly-heavy.log` records each job's label, queue wait, run time and exit status. Use it to measure the remaining work before estimating it.

## Comparison evidence

- **During development:** check one primary device per platform, plus every layout the change directly affects:
  - a tablet-layout fix needs a tablet check;
  - a large-text fix needs a large-text check;
  - a landscape fix needs a landscape check.
- **At handoff:** complete the full required comparison matrix (`docs/ui/REVIEW-RULES.md`).
  - After a fix, recapture the cases it affects.
  - Unchanged cases keep their evidence, labelled with the commit it was captured at.
  - Build once per capture batch, not once per screenshot.
- **Acceptance:** a slice handed over with pending comparisons or known deviations is progress, not acceptance.
- **The approved design is fixed:**
  - never alter the references;
  - never regenerate baselines to hide a difference;
  - never waive a mismatch to meet a deadline.

## Verification preflight

Before taking the lock for a verification run, export the commit under test and check it. The preflight takes seconds and fails immediately on the three causes of today's wasted runs: the Java version, missing git-ignored assets, and source identity.

```bash
scripts/verify_preflight.py snapshot <commit> <empty-dir>
eval "$(scripts/verify_preflight.py check android <empty-dir> <commit>)" && scripts/heavy verify-android-<commit> ...
```

- **What a handoff submits:** the exact tested commit and the results already recorded for it.
- **When to re-run:** only the checks needed to investigate a finding or establish confidence, not every full suite automatically.
