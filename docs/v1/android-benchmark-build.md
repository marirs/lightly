# Android benchmark build: what it is and how it differs from Release (2026-10-07)

The review emulator runs the `benchmark` build type from checkpoint 6f4462c on (installed in place over the debug build:
same debug signing certificate `54d6cb10…`, same version code, first install date kept). It is the build to judge
Android speed and memory with.

## Same as Release (checked at 6f4462c)
- **Rendering code:** the bytecode of every class in `background`, `develop`, `render`, `vision`, `export` and `decode`
  is identical in `app-benchmark.apk` and `app-release-unsigned.apk` (dexdump of both, constant-pool indices
  normalised: 0 differing lines). The benchmark build links the library modules' release variants
  (`matchingFallbacks += "release"`).
- **Optimisation settings:** not debuggable in both, so ART compiles the app as it does Release. Neither build type
  minifies (no R8 anywhere in the project).

## Different from Release
| What | Benchmark | Release |
|---|---|---|
| Vision models (Portrait, Change background), depth model (Focus & Blur without embedded depth), Remove model | Packaged (internal build) | Packaged only with their sign-off switches (`-PlightlyVisionModels…`, `-PlightlyDepthLegalSignOff`, `-PlightlyRemoveLegalSignOff`); without them the approved unavailable states show |
| `BuildConfig.DIAGNOSTICS` | true: scripted launch scenarios, `LightlyBgTime` / `LightlyDevelop` timing lines, the full-resolution allocation trace | false: none of these run |
| Bundled sample background photos | Packaged | Not packaged |
| Manifest | `<profileable android:shell="true"/>` (simpleperf, heap dumps from the shell) | absent |
| Signing | debug certificate | release signing at submission |

The diagnostics add a few log lines per frame; they are not in the rendering loops.

## Speed comparisons are made between equal configurations
- **Debug → benchmark (configuration, not code):** the earlier Android drag frames of 1.2–2.1 s were measured on the
  debuggable APK. The same code at 68b4e37 on the benchmark build: median 289 ms (stress-bench1). This difference is
  ART's treatment of a debuggable app, not an optimisation.
- **Code optimisation d527e3a (2.2×):** measured between equal configurations only: JVM probe, same machine, 4 threads,
  old and new sources interleaved (132–171 → 63–75 ms); and on the spare emulator, benchmark build before and after
  (median 289 → 139–149 ms per drag frame, under varying host load).
