# Implementation Plan

This plan turns `docs/SPEC.md` into buildable work. It is strict about data-oriented design, tests, file size, allocation behavior, and no runtime dependencies.

## Engineering Rules

- Target Zig 0.16.0.
- Use Zig-style public API names.
- No runtime dependencies: no gnuplot, helper daemons, CDN, runtime template engine, or runtime package fetch.
- Prefer Zig stdlib, direct syscalls, and OS APIs.
- Timed loops allocate nothing.
- Use structure-of-arrays for samples and analysis buffers.
- Keep stats kernels pure over slices: no allocator, filesystem, global state, or reporting.
- Implement scalar kernels first, then SIMD/branchless replacements in the same milestone when measured faster and test-equivalent.
- Keep scalar fallback as correctness oracle and unsupported-target fallback.
- Analysis output must be bit-for-bit independent of worker count.
- Every non-trivial branch/loop/parser/stat kernel gets a unit test or self-check.
- Do not use Criterion.rs fixtures as correctness oracle. Test sigbench math directly.
- Zig source files stay under 750 non-test lines. Test blocks do not count toward the limit.
- Split files before they become mixed-purpose. Do not add abstraction only to satisfy the line limit.
- One file owns one clear concern: runner, sampling, stats kernel, report model, SVG plot, platform counter, etc.
- Public baseline format is versioned JSON.
- Vendored assets require `THIRD_PARTY_NOTICES.md`.

## Milestone 1: Benchmark Core

Goal: runnable benchmark declaration, timing, sampling, and raw data.

Tasks:

- Create Zig package layout and `build.zig` for Zig 0.16.0.
- Add `sigbench` module.
- Add example benchmark executable that calls runner API from user-owned `main`.
- Implement Zig-style public API for groups, cases, parameters, stable IDs, display names, and config structs.
- Implement comptime registration.
- Implement runtime registration.
- Implement parameter matrix API with stable parameter IDs and display labels.
- Implement `Bencher.iter`.
- Implement `Bencher.iterCustom`.
- Implement `Bencher.iterCustomScoped` with one explicit measurement scope.
- Implement `Bencher.iterBatch`.
- Implement warmup with `1, 2, 4, ...` iteration growth.
- Implement linear, flat, and auto sampling modes.
- Implement `SampleSet` as structure-of-arrays.
- Preallocate sample and analysis workspace before timed loops.
- Implement wall-clock measurement.
- Implement CLI entrypoint through `zig build bench`.
- Implement filters and `--list`.
- Emit JSON event stream skeleton.
- Write raw `sample.json`.

Verification:

- `zig build test` passes.
- `zig build bench` runs example.
- Allocation guard proves timed loops and sample measurement allocate nothing.
- Unit tests cover warmup estimate and iteration count selection.
- Comptime and runtime registration produce identical stable IDs.
- Parameterized cases preserve stable IDs.
- JSON events cover benchmark start, warmup, measurement start, measurement complete, error, and benchmark end.
- Source files under 750 non-test lines.

## Milestone 2: Statistics And Baselines

Goal: deterministic statistical analysis and baseline comparison.

Tasks:

- Implement percentiles.
- Implement Tukey fences and outlier labels.
- Implement mean, median, standard deviation, median absolute deviation.
- Implement linear regression slope and R2.
- Implement bootstrap distribution generation with fixed default seed.
- Implement deterministic parallel work partitioning.
- Implement relative mean/median change.
- Implement two-sample t statistic and p-value.
- Implement confidence interval extraction.
- Implement CLI/config for confidence, significance, noise threshold, sample size, warmup time, measurement time, sampling mode, quick mode, jobs, and seed.
- Implement default jobs: `min(nproc, max(4, nproc / 2))`, capped to `nproc` when `nproc < 4`.
- Implement versioned JSON baseline save/load.
- Implement current plus one previous baseline format reader.
- Implement `--baseline`, `--baseline-strict`, `--save-baseline`, `--load-baseline`.
- Implement Criterion-style text output.
- Implement `--fail-on-regression`, `--gate`, and exit code policy.
- Implement benchmark routine error handling and `--fail-fast`.

Verification:

- Unit tests cover every stats function.
- Property checks cover shuffle invariance, scale invariance, identical baseline/current no-change, seed determinism, and worker-count independence.
- `--jobs 1` and default jobs produce byte-identical JSON and estimates.
- Baseline save/load/compare round trip works.
- Missing strict baseline fails before measurement.
- Regressions do not fail CI without explicit gate/fail flag.
- Source files under 750 non-test lines.

## Milestone 3: Measurements, Async, And Process Controls

Goal: non-wall-clock measurements and runtime modes.

Tasks:

- Implement measurement interface: `start`, `end`, `zero`, `add`, `toF64`, formatter.
- Route bencher timing boundaries through the selected measurement driver.
- Implement CPU cycles measurement.
- Serialize x86 cycle boundaries; require invariant TSC; reject migration and backwards TSC.
- Implement Linux perf counters through `perf_event_open`.
- Implement macOS kperf counters.
- Implement Windows cycles through `QueryThreadCycleTime` or `QueryProcessCycleTime`.
- Implement process memory counters:
  - RSS/working set.
  - peak RSS/peak working set.
  - Linux Proportional Set Size.
  - private/committed memory where available.
- Implement `CountingAllocator`.
- Track allocations, frees, resizes, allocated bytes, freed bytes, resized bytes, live bytes, and peak live bytes.
- Sample process memory before/after each benchmark sample.
- Capture allocator counters exactly per sample.
- Fail unsupported selected measurements before warmup.
- Ensure counter setup allocates before warmup and reads allocate nothing in timed loops.
- Reject unscoped custom wall-clock timings when cycle or perf measurement is selected.
- Implement async executor adapter API.
- Implement `iterAsync`.
- Implement `--profile-time`.
- Implement no-op external profiler mode.
- Implement in-process profiler `start`/`stop` hooks.
- Implement same-process default execution.
- Implement `--isolate-process`.
- Implement `--pin-cpu` and `--priority`.

Verification:

- Unsupported counters fail before warmup.
- Linux perf tests run where supported and skip clearly where blocked.
- macOS kperf tests run where supported and skip clearly where blocked.
- Windows cycles/memory tests run where supported.
- Allocator counter tests cover alloc/free/resize/live/peak accounting and wrapper transparency.
- Async test proves executor is called and measured.
- Scope tests cover setup/teardown exclusion, missing/repeated boundaries, caught violations,
  and callback-error cleanup.
- Profiling test proves hooks fire exactly once per selected case and analysis/report saving are skipped.
- Isolated process mode preserves result schema.
- Priority/affinity are opt-in and reported.
- Source files under 750 non-test lines.

## Milestone 4: Reports, Plots, And Optimization

Goal: complete offline reports and measured kernel optimization.

Tasks:

- Implement in-tree SVG writer.
- Implement plot data model.
- Implement PDF plot.
- Implement regression plot.
- Implement iteration times plot.
- Implement absolute distributions plot.
- Implement relative distributions plot.
- Implement t-test plot.
- Implement line comparison plot.
- Implement throughput line comparison plot.
- Implement violin summary plot.
- Implement local/offline HTML templates embedded at comptime.
- Implement per-benchmark report page.
- Implement group summary report page.
- Implement top-level index page.
- Vendor uPlot and required CSS/JS.
- Add `THIRD_PARTY_NOTICES.md`.
- Implement `svg-js`, `svg`, `uplot`, and `both` chart modes.
- Implement decimated interactive display data with min/max envelope preservation.
- Link raw local JSON from report pages.
- Implement `--noplot`, `--plotting-backend sigbench|none`, `--chart-mode`, `--output-format`, `--color`, `--verbose`, `--quiet`.
- Benchmark stats kernels.
- Replace hot scalar kernels with SIMD where faster and exact enough.
- Replace branch-heavy loops with branchless code where faster and still readable.

Verification:

- HTML opens from local disk with no network.
- SVG files exist for every required plot type.
- All chart modes produce expected local assets.
- Decimator preserves min/max envelopes on outlier-heavy fixtures.
- Scalar/SIMD equivalence tests pass.
- SIMD/branchless replacements have benchmark evidence before replacing scalar hot path.
- No external process is used for plots, HTML, counters, or profiling.
- Source files under 750 non-test lines.

## File Size Rule

Every Zig source file must stay under 750 non-test lines.

Counting rule:

- Count normal source lines.
- Do not count `test {}` blocks.
- Do not count blank lines inside test blocks.
- Do not count comments inside test blocks.

If a file approaches the cap, split by responsibility. Good splits are data model, parser, platform backend, stats kernel, formatter, report renderer, plot type, or test helper. Bad splits are arbitrary halves or generic utility dumping grounds.

## Done Definition

A milestone is done only when:

- Scope tasks are implemented.
- Verification checks pass.
- Docs/spec stay consistent with implementation.
- No runtime dependency was added.
- Timed-loop allocation rule still holds.
- Zig source files respect the 750-line cap.
