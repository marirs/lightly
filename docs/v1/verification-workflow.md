# Verification without hour-long queues

The exact approved UX rule is unchanged. Coverage is an acceptance requirement, not a requirement to recapture every screen after every edit.

- One coordinator submits heavy jobs using `rtk proxy scripts/heavy <label> <command>`. Default lock wait is 120 seconds; exit 75 means busy. Mark pending and return to independent work. Do not queue duplicate jobs or spin in retry loops. Existing jobs started before this change retain their old wait behaviour.
- Capture one device/theme/text-size combination per lock acquisition. Split large matrices into resumable jobs; put verification ahead of additional capture batches. Never hold the lock across the entire matrix.
- Reuse the built test bundle with test-without-building where valid. Build once per relevant source/configuration revision. Do not use clean builds or Gradle --rerun-tasks routinely.
- Record the source revision and local-change fingerprint used by each run. Verify committed slices from a stable source snapshot, with reusable build output, instead of the moving working folder. Do not add worktrees or branches.
- The current EditorCaptureUITests launches per screen. A persistent-session replacement is NOT complete until implemented and measured. Its debug-only scenario driver must reset all per-screen state, await the actual render completion, and match the launch-based reference captures. Lifecycle/launch tests remain separate. Do not merely remove launches or shorten sleeps and call the images valid.
- Run targeted tests during changes and affected regression suites at handoff. Reuse existing results only when their code/configuration dependencies are unchanged. Run launch/recovery tests when lifecycle code changes.
- Keep original PNG evidence once. Generate compressed side-by-side contact sheets on demand; don't generate several full PNG copies per comparison. Use lossless originals for precise visual inspection. Preserve reference and native images plus commit/device/theme/text-size metadata.
- Reuse unchanged reference captures keyed by reference revision, assets, device, orientation, theme, text size and capture-tool version. Invalidate affected native captures after a change. No stale screenshot may be represented as a current verification.
- Track all required matrix cells as verified, deviation or pending. Chunking and caching must never remove coverage or lower UX acceptance.
- Keep generated output in temporary directories or private ~/.codex/artifacts/lightly, as appropriate. Do not delete active build directories, models, original evidence or user data to reclaim memory. Disk usage and swap allocation alone do not establish current memory pressure; measure paging activity and memory pressure before claiming the cause.
