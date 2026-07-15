# Sigbench Specification

Sigbench should be a Zig 0.16.0-native equivalent of `criterion-rs/criterion.rs`: Criterion-grade benchmarking semantics for Zig, with a data-oriented implementation that keeps timed paths allocation-free.

## Sources

- `criterion-rs/criterion.rs` upstream repository: https://github.com/criterion-rs/criterion.rs
- Criterion.rs analysis process: https://criterion-rs.github.io/book/analysis.html
- Criterion.rs timing loops: https://criterion-rs.github.io/book/user_guide/timing_loops.html
- Criterion.rs command-line options: https://criterion-rs.github.io/book/user_guide/command_line_options.html
- Criterion.rs HTML reports and plots: https://criterion-rs.github.io/book/user_guide/html_report.html
- Criterion.rs async benchmarks: https://criterion-rs.github.io/book/user_guide/benchmarking_async.html
- Criterion.rs profiling: https://criterion-rs.github.io/book/user_guide/profiling.html
- `D-Berg/crap` counter implementation reference: https://github.com/D-Berg/crap
- Windows `QueryThreadCycleTime`: https://learn.microsoft.com/en-us/windows/win32/api/realtimeapiset/nf-realtimeapiset-querythreadcycletime
- Windows `QueryProcessCycleTime`: https://learn.microsoft.com/en-us/windows/win32/api/realtimeapiset/nf-realtimeapiset-queryprocesscycletime
- Windows `GetProcessMemoryInfo`: https://learn.microsoft.com/en-us/windows/win32/api/psapi/nf-psapi-getprocessmemoryinfo
- Windows process snapshotting: https://learn.microsoft.com/en-us/previous-versions/windows/desktop/proc_snap/overview-of-process-snapshotting
- Windows PMU events through ETW/WPR: https://learn.microsoft.com/en-us/windows-hardware/test/wpt/recording-pmu-events
- uPlot interactive chart reference: https://github.com/leeoniya/uPlot
- Zig 0.16.0 release notes: https://ziglang.org/download/0.16.0/release-notes.html

Upstream inspected at `criterion-rs/criterion.rs` `master` commit `60ab5fd10cc41d5c43a421f982d6bd981d36d05f`.

## Success Criteria

1. Zig 0.16.0 project can declare benchmarks, run them with `zig build bench`, and get Criterion-style CLI output.
2. Each benchmark follows Criterion's core phases: warmup, sample collection, analysis, baseline comparison.
3. Timed loops allocate nothing. Sample collection and stats reuse buffers allocated before measurement starts.
4. CLI supports benchmark filtering, color control, output verbosity, plotting backend selection, profiling mode, baseline operations, and quick mode.
5. HTML reports and plots are produced by default when output is enabled.
6. Async benchmarks can run on a user-provided executor.
7. Profiling mode runs benchmarks for fixed time, skips analysis and saving, and calls profiler hooks.
8. Reports include time estimate, throughput when configured, outlier summary, plots, HTML pages, and baseline change verdict.
9. Baseline files are stable enough for future versions to read or migrate.
10. Runnable checks cover sampling math, baseline comparison, async bench execution, profiler hook ordering, and report artifact creation.

## Full Scope

Sigbench should match Criterion.rs' product surface, translated to Zig:

- Core benchmark API.
- CLI runner through `zig build bench`.
- Statistical analysis and baseline comparison.
- HTML reports.
- Plot generation.
- Async benchmarking.
- Profiling mode and in-process profiler hooks.
- Throughput reporting.
- Custom measurements, including CPU cycles and perf counters.

## Dependency Policy

Sigbench has no runtime dependencies. This includes plot generation: do not shell out to gnuplot or require any external executable, daemon, library, CDN, or system service beyond kernel/OS APIs that are already part of the target platform.

Allowed:

- Zig stdlib.
- Direct syscalls.
- Compile-time embedded templates and vendored static assets.
- Optional compile-time OS bindings when the target platform requires them.

Forbidden:

- Runtime gnuplot dependency.
- Runtime template engine dependency.
- Runtime JavaScript/CSS CDN dependency.
- Runtime helper process for counters, plots, HTML, or profiling.
- Adding a package for stats code that can be written directly.

`D-Berg/crap` is the counter precedent: Linux uses `std.posix.perf_event_open`, macOS uses `kperf`, and unsupported counters are platform-specific instead of abstracted behind a runtime service.

The implementation order can still be staged, but the spec does not treat these as optional add-ons.

## Product Shape

Sigbench is a library plus build integration, not a standalone runner first.

Public API names use idiomatic Zig style. Criterion.rs concepts are translated, not copied verbatim when Rust naming feels foreign.

Benchmark authors define Zig benchmark files and expose a comptime benchmark list. `build.zig` wires a user-owned bench executable into `zig build bench`.

```zig
const std = @import("std");
const sigbench = @import("sigbench");

fn fib(n: u64) u64 {
    return switch (n) {
        0, 1 => 1,
        else => fib(n - 1) + fib(n - 2),
    };
}

fn benchFib20(b: *sigbench.Bencher) void {
    b.iter(struct {
        fn run() void {
            std.mem.doNotOptimizeAway(fib(std.mem.doNotOptimizeAway(20)));
        }
    }.run);
}

pub const benchmarks = sigbench.group("fib", .{
    sigbench.bench("fib 20", benchFib20),
});
```

Recommended default: use Zig functions and comptime declarations instead of a macro-like DSL. Zig already has comptime; do not build a second language.

The CLI executable is still first-class. `zig build bench` should compile the benchmark runner and forward args to it, so direct execution and external profiler usage work without build-system magic.

Sigbench provides a small runner API users call from their benchmark `main`. It does not generate hidden runner source.

Runtime registration is also supported for generated benchmark sets and data-driven parameter matrices. Comptime registration remains the default for hand-written benchmarks.

Parameterized benchmarks are first-class. Parameter matrices use typed values plus explicit stable parameter IDs and display labels. Sigbench does not infer baseline IDs from raw value serialization.

Benchmark identity separates stable `id` from display `name`. The `id` is path-safe and controls baseline/report paths. The `name` is human-facing and can be richer without changing persistence identity.

## Core Flow

Each benchmark case runs this flow:

1. Warmup executes the routine with iteration counts `1, 2, 4, ...` until configured warmup time is exceeded.
2. Mean execution time estimate is `warmup_elapsed_ns / warmup_iterations`.
3. Sampling mode chooses iteration counts:
   - Linear for fast routines: `[d, 2d, 3d, ... Nd]`.
   - Flat for long routines: roughly equal iteration counts per sample.
   - Auto chooses between them from estimated time and measurement budget.
4. Measurement runs each sample and records `(iterations, elapsed_ns)`.
5. Analysis computes per-iteration times, Tukey outlier labels, bootstrap estimates, and linear regression slope for linear sampling.
6. Comparison loads baseline samples, bootstraps relative mean and median changes, computes p-value, and classifies result as improved, regressed, unchanged, or inside noise threshold.
7. Report writes CLI output and baseline files.
8. Plot generation consumes saved measurement data and writes SVG artifacts.
9. HTML generation consumes estimates, comparison data, and plot paths.

## Data Model

Use structure-of-arrays buffers. Avoid per-sample structs in hot analysis loops.

```zig
pub const SampleSet = struct {
    iterations: []u64,
    elapsed_ns: []f64,
    avg_ns: []f64,
    outliers: []OutlierKind,
};

pub const Estimates = struct {
    mean: Estimate,
    median: Estimate,
    median_abs_dev: Estimate,
    std_dev: Estimate,
    slope: ?Estimate,
};

pub const Estimate = struct {
    point: f64,
    lower: f64,
    upper: f64,
    standard_error: f64,
};
```

`SampleSet` memory is allocated once per benchmark case. Stats workspaces are allocated once per run from the configured allocator and reused across cases when capacity allows.

## Allocation Rule

Allowed:

- CLI arg parsing before benchmarks start.
- Benchmark registry construction.
- Workspace allocation before each case enters warmup.
- File I/O and formatting after measurement ends.

Forbidden:

- Allocation inside `Bencher.iter`.
- Allocation inside sample measurement loops.
- Allocation inside bootstrap loops after workspace allocation.
- Hidden allocation in formatting called from timed code.

This is stricter than Criterion.rs, which uses `Vec` throughout sampling and analysis. Sigbench should spend complexity only where it removes runtime allocation from repeat paths.

## Timing Loops

Sigbench supports:

- `iter`: default tight loop; one start/end measurement per sample.
- `iterCustom`: legacy wall-clock API; user receives iteration count and returns elapsed
  nanoseconds.
- `iterCustomScoped`: user receives iteration count and a `MeasurementScope`; setup and teardown
  run outside its explicit `start` and `stop` boundary.
- `iterBatch`: setup outside measured region, routine inside measured region, fixed batch policy.
- `iterAsync`: executor-backed async routine loop.

`iterCustomScoped` requires exactly one `start` and one `stop`. Missing, repeated, or
out-of-order boundaries reject the sample even when the benchmark catches the immediate
error. A callback error closes an active measurement before returning the original callback
error. `iterCustom` and `finishCustom` remain compatible for wall-clock sampling, but selected
cycle and perf counters reject them instead of measuring surrounding setup and teardown.
If a selected counter's `stop` fails, Sigbench returns that error without invoking `stop` again.

Skip `iter_with_large_drop` as a separate concept. Zig has explicit lifetimes and no Rust `Drop`; `iterBatch` covers the real need.

Batch policy:

- `small_input`: about 10 batches per sample.
- `large_input`: about 1000 batches per sample.
- `per_iteration`: one batch per iteration.
- `num_batches(n)`.
- `num_iterations(n)`.

## Async Benchmarks

Async support mirrors Criterion's executor model, not any one runtime. Sigbench provides an executor adapter API; benchmark authors supply the runtime adapter used in their project.

```zig
pub const AsyncExecutor = struct {
    ctx: *anyopaque,
    run: *const fn (ctx: *anyopaque, frame: anytype) void,
};
```

The exact Zig 0.16 async surface needs validation against real compiler support before implementation. Requirement: benchmark authors can use the same runtime they use in production, and sigbench measures the routine plus executor overhead honestly. Reports must warn that async overhead can dominate tiny routines.

Sigbench does not ship opinionated built-in runtimes in the first API. Runtime-specific adapters can live in examples or extension packages.

## Profiling

Profiling mode is a separate run mode:

- CLI: `--profile-time <duration>`.
- Runs each selected benchmark for roughly the requested duration.
- Does not save baselines.
- Does not run bootstrap analysis.
- Does not generate plots or HTML.
- Calls `Profiler.start(benchmark_id, profile_dir)` before the profiled loop.
- Calls `Profiler.stop(benchmark_id, profile_dir)` after the profiled loop.

Default profiler is no-op for external tools such as `perf`. In-process profiler hooks are compile-time configured on the benchmark runner. Both external profiler mode and in-process hooks are required.

## Measurements

Sigbench supports multiple measurement kinds from the start:

- Wall-clock elapsed time.
- CPU cycles.
- Linux perf counters.
- macOS kperf counters.
- Process memory counters.
- Allocator counters.

Measurement API requirements:

- `start` captures the counter state before a timed loop.
- `end` returns the measured delta after a timed loop.
- `zero` and `add` support batched timing loops.
- `toF64` provides analysis units.
- `formatter` handles CLI, HTML, plot, and JSON units.

Cycle and perf measurements must be explicit in benchmark configuration. Wall-clock remains default because it is portable.

On x86 and x86_64, CPU-cycle samples use `LFENCE; RDTSCP; LFENCE` at the start and
`RDTSCP; LFENCE` at the end, with compiler memory barriers on both boundaries. Preflight checks
CPUID for TSC, invariant TSC, SSE2/LFENCE, and RDTSCP support before executing those
instructions. Start and end capture `TSC_AUX`; a changed value rejects the sample with
`CpuMigrationDetected`. A backwards counter rejects it with `TimestampCounterWentBackwards`.
Public `CpuCycles.read` uses the serialized start sequence. Windows keeps thread-cycle
accounting through `QueryThreadCycleTime`.

Perf constraints:

- Linux perf support can be Linux-only.
- macOS kperf counter support is in first counter scope. It must be explicit, and permission/setup failures must stop before warmup.
- Windows cycle support uses `QueryThreadCycleTime` or `QueryProcessCycleTime`.
- Windows PMU event counters such as branch misses, cache misses, and retired instructions are not considered an easy no-runtime-deps equivalent. ETW/WPR can collect PMU events, but that is a profiling/reporting integration candidate, not a timed-loop measurement backend.
- Permission errors must fail clearly before measurement starts.
- Counter setup allocates and opens descriptors before warmup.
- Counter reads inside timed loops must not allocate.
- Unsupported measurements fail before warmup; they do not silently fall back to wall-clock.
- Use Zig stdlib or direct syscalls/OS APIs for perf integration. Do not add runtime dependencies.

Memory measurement families:

- Process resident memory: RSS on Linux/macOS, working set on Windows.
- Peak resident memory: peak RSS where supported, peak working set on Windows.
- Proportional set size: Linux only through `/proc/self/smaps_rollup` or equivalent procfs parsing. Spell this out as Proportional Set Size; do not confuse it with Windows Process Snapshotting APIs.
- Private/committed memory: private dirty/private bytes/commit where the platform exposes it.
- Allocator counters: allocations, frees, resizes, allocated bytes, freed bytes, resized bytes, live bytes, peak live bytes.

Memory constraints:

- Process memory sampling is outside tight timed loops unless the selected measurement explicitly asks for per-sample process memory. OS process-memory APIs can be expensive and noisy.
- Process memory measurements sample before and after each benchmark sample by default, not inside each routine iteration.
- Allocator counters are precise only for allocations routed through `sigbench.CountingAllocator`.
- `CountingAllocator` must compose with user-provided allocators and preserve allocator semantics.
- Allocation/resizing counters are in scope for benchmark routines that accept or construct a sigbench-wrapped allocator.
- Allocator counters can be captured exactly for each sample because they are maintained by the wrapped allocator.
- Sigbench does not attempt automatic global allocation tracking.
- Windows process memory uses `GetProcessMemoryInfo`/`PROCESS_MEMORY_COUNTERS_EX` for working set, peak working set, private usage, and related process-level values.
- Windows Process Snapshotting can be explored for richer diagnostics, but it is not the Windows equivalent of Linux Proportional Set Size.

## Statistics

Sigbench matches Criterion's visible behavior:

- Percentiles: 25th, 50th, 75th.
- Outliers: Tukey fences at `1.5 * IQR` and severe fences at `3.0 * IQR`.
- Absolute estimates: mean, median, standard deviation, median absolute deviation.
- Linear estimate: slope from least-squares regression for linear sampling.
- Confidence interval from bootstrap distributions.
- Comparison: relative mean and median change, two-sample t distribution, p-value, configurable significance level and noise threshold.

Default config:

```zig
pub const Config = struct {
    confidence_level: f64 = 0.95,
    significance_level: f64 = 0.05,
    noise_threshold: f64 = 0.02,
    sample_size: u32 = 100,
    resamples: u32 = 100_000,
    warmup_ns: u64 = 3 * std.time.ns_per_s,
    measurement_ns: u64 = 5 * std.time.ns_per_s,
    sampling_mode: SamplingMode = .auto,
    seed: u64 = 0x51_6b_65_6e_63_68,
};
```

## Data-Oriented Implementation Notes

- Store raw sample arrays contiguously: `iterations`, `elapsed_ns`, `avg_ns`.
- Sort index buffers when possible; preserve raw sample order for reports.
- Use branchless classification for outlier counts where it is faster and still readable:
  `count += @intFromBool(value > high_fence);`
- Implement scalar kernels first, then replace hot kernels with SIMD in the same development phase when benchmarks show speedup and tests prove equivalent output:
  - `avg_ns[i] = elapsed_ns[i] / @as(f64, @floatFromInt(iterations[i]))`
  - bootstrap statistic reductions
  - throughput scaling
- Final implementation should be a measured mix of scalar, SIMD, and branchless code. Keep scalar fallback for unsupported targets and as correctness oracle in tests.
- Prefer `std.Random.DefaultPrng` or Zig 0.16 stdlib RNG with explicit seed in workspace.
- Keep all stats kernels pure over slices. No filesystem, allocator, or global state in stats.

## Test Strategy

Do not depend on Criterion.rs test fixtures as the source of truth. Sigbench may inspect Criterion behavior for product parity, but its correctness tests should verify the math directly.

Required tests:

- Unit tests for percentiles, Tukey fences, outlier classification, mean, standard deviation, median absolute deviation, linear regression, confidence interval indexing, t statistic, p-value calculation, and relative change estimates.
- Property tests or generated self-checks for invariants: shuffled samples do not change univariate estimates, scaling all times scales estimates, identical baseline/current gives no change, deterministic seed produces stable bootstrap distributions, and worker count does not change output.
- Scalar/SIMD equivalence tests for every SIMD replacement.
- Allocation tests around timed loops where Zig tooling permits it.
- Platform tests for unsupported counters failing before warmup.

## Baseline Files

Default output root: `zig-out/sigbench`.

CLI can override this with `--output-dir <path>`.

Per benchmark case:

```text
zig-out/sigbench/<group>/<case>/new/sample.json
zig-out/sigbench/<group>/<case>/new/estimates.json
zig-out/sigbench/<group>/<case>/<baseline>/sample.json
zig-out/sigbench/<group>/<case>/<baseline>/estimates.json
```

`sample.json` contains:

```json
{
  "format": 1,
  "sampling_mode": "linear",
  "iterations": [10, 20, 30],
  "elapsed_ns": [1000.0, 2010.0, 3025.0]
}
```

Use versioned JSON for public baselines because users can inspect, diff, and archive it in CI. Binary cache format can come later if JSON read/write becomes measurable pain, but JSON remains the compatibility format.

Baseline compatibility policy: sigbench reads the current format and one previous format automatically. Older formats fail with a clear migration error. Do not keep unbounded migration code.

## CLI

`zig build bench -- [options]`

Benchmark configuration is set through Zig API/config structs and overridden by CLI flags. Sigbench does not define a separate config file format.

Required options:

- `--baseline <name>`: compare against saved baseline, lenient if absent.
- `--baseline-strict <name>`: compare and fail if missing.
- `--save-baseline <name>`: save current `new` results under baseline name.
- `--load-baseline <name>`: load saved data as current run.
- `--sample-size <n>`.
- `--measurement-time <duration>`.
- `--warm-up-time <duration>`.
- `--measurement wall-time|cpu-cycles|linux-perf|macos-kperf|process-memory|allocator-counters`.
- `--sampling-mode auto|linear|flat`.
- `--confidence-level <fraction>`.
- `--significance-level <fraction>`.
- `--noise-threshold <fraction>`.
- `--quick`: reduced sampling for local feedback.
- `--profile-time <duration>`.
- `--color auto|always|never`.
- `--verbose`.
- `--quiet`.
- `--noplot`.
- `--plotting-backend sigbench|none`.
- `--chart-mode svg-js|svg|uplot|both`.
- `--output-format terse|verbose|json`.
- `--output-dir <path>`.
- `--isolate-process`.
- `--pin-cpu <index>`.
- `--priority normal|high`.
- `--jobs <n>`.
- `--seed <u64>`.
- `--fail-on-regression`.
- `--fail-fast`.
- `--gate <metric><op><value>`.
- `--list`.
- benchmark name filters as positional substrings.

Use Zig 0.16 `std.process.Init` in the runner so args, allocator, and I/O are explicit.

Benchmark cases run in the same process by default. `--isolate-process` runs each selected benchmark case in a subprocess to reduce cross-case allocator, cache, and global-state leakage.

CPU affinity and scheduler priority controls are optional. Sigbench never silently pins CPUs or raises priority; users must request it.

Analysis runs in parallel by default. Default worker count is `min(nproc, max(4, nproc / 2))`; if `nproc < 4`, use `nproc`. `--jobs <n>` overrides it.

Analysis results must be bit-for-bit independent of worker count. Bootstrap RNG streams, resample ranges, reductions, and sort/merge steps must be partitioned deterministically so `--jobs 1` and `--jobs N` produce the same estimates, p-values, JSON, SVG, and HTML.

Bootstrap uses a fixed default seed and accepts `--seed <u64>` for sensitivity checks. The seed is saved in report and baseline metadata.

## Plots

Plots are first-class report artifacts. Default and only required backend is an in-tree SVG writer. Gnuplot is not supported as a runtime backend because sigbench has no runtime dependencies.

Chart modes:

- `svg-js`: default. Zig generates SVG plots and a small vendored JavaScript layer adds local interactions.
- `svg`: static SVG only.
- `uplot`: vendored uPlot renders interactive Canvas charts from local JSON data.
- `both`: writes SVG plots and uPlot interactive charts.

uPlot is the preferred high-performance JS chart library. It is MIT licensed, small, Canvas-based, and focused on fast time-series/line charts, which matches sigbench's plot data better than larger general-purpose chart suites. uPlot is vendored and embedded; no CDN or runtime package fetch is allowed.

Interactive reports load decimated display data by default and link to raw local JSON for full-fidelity inspection or replotting. The decimator must preserve min/max envelopes so outliers and distribution shape are not hidden.

Required plot types:

- PDF.
- Regression.
- Iteration times.
- Absolute distributions.
- Relative distributions.
- T-test.
- Line comparison.
- Throughput line comparison.
- Violin summary.

Plot code consumes `SampleSet`, `Estimates`, comparison data, and formatter scaling. Plot code must not touch timed loops.

## HTML Reports

HTML reports are generated by default when plots are enabled.

Required pages:

- Per-benchmark report.
- Group summary report.
- Top-level index.

Required content:

- Time confidence interval.
- Throughput confidence interval when configured.
- Slope, R2, mean, std dev, median, MAD.
- Outlier summary.
- Change estimate and p-value when baseline exists.
- Links to plot SVGs.

Use static HTML templates embedded at comptime. Avoid runtime template engines.

Reports must be local/offline. CSS and JavaScript can be vendored from upstream CDN packages when that makes the templates better, but generated reports must not depend on network access.

Static assets are embedded in the sigbench module and copied to the report directory during report generation.

Vendored assets must be permissively licensed and compatible with BSD-3-Clause distribution. Add or update `THIRD_PARTY_NOTICES.md` whenever vendored CSS, JavaScript, fonts, or other assets are added.

## Report Output

Keep first output close to Criterion:

```text
fib/fib 20              time:   [26.029 us 26.251 us 26.505 us]
                        change: [-1.200% +0.400% +2.100%] (p = 0.52 > 0.05)
                        No change in performance detected.
Found 11 outliers among 100 measurements (11.00%)
  6 (6.00%) high mild
  5 (5.00%) high severe
```

JSON output is required for tools. It streams structured events, not one final summary blob and not a duplicate of baseline files.

Memory metrics are reported as separate estimates from time/cycles. They do not feed timing regression or slope calculations.

Users can still gate memory metrics. Gates are explicit CLI or config rules, for example `--gate peak_rss<=64MiB`, `--gate alloc_count==0`, or `--fail-on-regression` with memory metrics included in baseline comparison.

Exit code policy:

- Nonzero for benchmark routine failure.
- Nonzero for setup errors, including unavailable selected measurements.
- Nonzero for missing strict baseline.
- Nonzero for explicit gate failure or `--fail-on-regression`.
- Zero for detected regressions when no gate/fail flag was requested.

Benchmark routines may return errors. A case error aborts that case, records an error event/report entry, and continues with remaining selected cases by default. `--fail-fast` stops at the first case error.

## Milestones

Milestones are execution checkpoints for one complete product, not scope deferrals. Each milestone must leave the repo runnable and documented.

### Milestone 1: Benchmark Core

Goal: prove the benchmark declaration, timing, sampling, and data layout.

Scope:

- Zig 0.16.0 build setup.
- Public API with Zig-style names.
- Comptime benchmark registration.
- Runtime benchmark registration.
- Benchmark groups and benchmark cases.
- Parameterized benchmark matrix API with explicit stable parameter IDs and display labels.
- `Bencher` timing loops: `iter`, `iterCustom`, `iterBatch`.
- Scoped custom timing through one explicit `MeasurementScope` start/stop pair.
- Warmup loop with `1, 2, 4, ...` iteration growth.
- Linear, flat, and auto sampling modes.
- Structure-of-arrays sample buffers.
- Allocation-free timed loops.
- Wall-clock measurement.
- CLI runner entrypoint through `zig build bench`.
- CLI filters and `--list`.
- JSON event stream skeleton.

Verification:

- Example benchmark runs with `zig build bench`.
- Unit tests cover iteration count selection and warmup estimate math.
- Allocation check proves `iter` and sample measurement loops do not allocate.
- Runtime and comptime registration produce same benchmark IDs.
- Parameterized benchmarks preserve stable IDs when values are regenerated with the same parameter IDs.
- JSON events are emitted for benchmark start, warmup, measurement start, measurement complete, and benchmark end.

Exit criteria:

- A Zig project can add sigbench, define sync benchmarks, run filtered benchmarks, and inspect raw sample JSON.

### Milestone 2: Statistics And Baselines

Goal: make benchmark output statistically useful and deterministic.

Scope:

- Percentiles.
- Tukey outlier fences and labels.
- Mean, median, standard deviation, median absolute deviation.
- Linear regression slope and R2.
- Bootstrap distributions for absolute estimates.
- Relative change estimates against baselines.
- Two-sample t statistic and p-value.
- Config fields and CLI flags for confidence, significance, noise threshold, sample size, warmup time, measurement time, quick mode, jobs, and seed.
- Parallel analysis default: `min(nproc, max(4, nproc / 2))`, capped to `nproc` when `nproc < 4`.
- Worker-count-independent deterministic output.
- Versioned JSON baselines under `zig-out/sigbench`, with `--output-dir`.
- `--baseline`, `--baseline-strict`, `--save-baseline`, and `--load-baseline`.
- CLI text output matching Criterion-style information density.

Verification:

- Unit tests cover each statistical function directly.
- Property tests cover shuffle invariance, scale invariance, identical baseline/current no-change behavior, deterministic seed behavior, and worker-count independence.
- `--jobs 1` and default jobs produce byte-identical estimates, p-values, JSON, SVG data inputs, and HTML data inputs.
- Baseline save/load/compare round trip works.
- Missing strict baseline fails before measurement.

Exit criteria:

- Users can detect improvement, regression, no-change, and within-noise outcomes with stable repeatable output.

### Milestone 3: Measurements, Async, And Process Controls

Goal: support the non-wall-clock measurement and runtime modes that affect API shape.

Scope:

- Measurement interface: `start`, `end`, `zero`, `add`, `toF64`, formatter.
- CPU cycles measurement.
- Linux perf counters via Zig stdlib/direct syscall path, using `perf_event_open`.
- macOS kperf counters using OS APIs.
- Windows cycle counters through `QueryThreadCycleTime` or `QueryProcessCycleTime`.
- Process memory measurements: RSS/working set, peak RSS/peak working set, Linux Proportional Set Size, private/committed memory where available.
- Allocator measurements: allocations, frees, resizes, bytes, live bytes, peak live bytes through `CountingAllocator`.
- Permission/setup checks before warmup.
- Unsupported measurements fail before warmup, never fall back silently.
- Counter reads inside timed loops allocate nothing.
- Scoped custom timing excludes setup and teardown for wall, cycle, and perf measurements.
- Async benchmark API through user-supplied executor adapter.
- `iterAsync`.
- Profiling mode: `--profile-time <duration>`.
- External profiler mode with no required hooks.
- In-process profiler hooks with `start` and `stop`.
- Same-process default execution.
- `--isolate-process` per-case subprocess mode.
- Optional `--pin-cpu <index>` and `--priority normal|high`.

Verification:

- Unsupported counter test fails before warmup.
- Linux perf setup/read tests run where available; skipped clearly where kernel/permissions block them.
- macOS kperf setup/read tests run where available; skipped clearly where platform/permissions block them.
- Windows cycle and process-memory tests run where available.
- Allocator counter tests verify alloc/free/resize/live/peak accounting and wrapper transparency.
- Async executor test proves executor is called and measured.
- Profiling test proves hooks fire exactly once per selected benchmark and no baseline/report analysis runs.
- Isolated process mode returns same benchmark result shape as same-process mode.
- Priority/affinity changes are opt-in and reported.

Exit criteria:

- Users can benchmark sync, async, wall-clock, cycles, Linux perf, macOS kperf, Windows cycles, process memory, and allocator-memory cases with explicit measurement choice and no runtime dependencies.

### Milestone 4: Reports, Plots, And Optimization

Goal: finish user-facing reporting and optimize hot paths without changing results.

Scope:

- In-tree SVG plot backend.
- Chart modes: `svg-js`, `svg`, `uplot`, `both`.
- Vendored uPlot assets embedded at comptime.
- Local/offline HTML reports.
- Per-benchmark report page.
- Group summary report page.
- Top-level index page.
- Static assets copied into report directory.
- Plot types: PDF, regression, iteration times, absolute distributions, relative distributions, t-test, line comparison, throughput line comparison, violin summary.
- Decimated interactive display data with min/max envelope preservation.
- Raw local JSON links for full-fidelity data.
- `--noplot`, `--plotting-backend sigbench|none`, `--chart-mode`, `--output-format terse|verbose|json`, `--color`, `--verbose`, and `--quiet`.
- Scalar reference kernels.
- SIMD replacements for measured hot kernels in the same development phase.
- Branchless implementations where measured faster and still readable.

Verification:

- HTML report opens from local disk with no network.
- SVG plots exist for all required plot types.
- `svg-js`, `svg`, `uplot`, and `both` modes produce expected assets.
- Decimated display data preserves min/max envelope for test datasets with outliers.
- Scalar/SIMD equivalence tests pass for every SIMD kernel.
- Benchmarks show SIMD/branchless replacements are faster before scalar path is replaced.
- No runtime external process is used for plots, HTML, counters, or profiling.

Exit criteria:

- Sigbench produces complete offline Criterion-style reports with static and interactive plots, while keeping timed paths allocation-free and analysis deterministic.

## Resolved Decisions

- Product surface follows Criterion.rs semantics, translated to Zig.
- Public API uses Zig-style names.
- Keep this file as the product spec for planning; split `docs/API.md`, `docs/REPORTS.md`, and `docs/MEASUREMENTS.md` when implementation starts.
- Use `docs/IMPLEMENTATION_PLAN.md` for milestone execution and engineering rules.
- Configuration comes from Zig API/config structs plus CLI overrides; no separate config file.
- CI only fails on explicit gates/regression flags, strict baseline misses, setup errors, or benchmark failures.
- No runtime dependencies.
- Default plots are in-tree SVG; gnuplot is excluded.
- Default chart mode is `svg-js`.
- uPlot is vendored for optional high-performance interactive Canvas charts.
- Reports are local/offline; vendored CSS/JS assets are allowed.
- Vendored assets require `THIRD_PARTY_NOTICES.md`.
- Timed loops allocate nothing.
- Stats use scalar first, SIMD/branchless where measured faster and equivalent.
- First public scope includes wall-clock, CPU cycles, Linux perf counters, macOS kperf counters, Windows cycle counters, process memory counters, and allocator counters.
- Allocator metrics use explicit `CountingAllocator`; no global allocation tracking.
- Unsupported measurements fail before warmup.
- Reports and baselines default to `zig-out/sigbench` with `--output-dir`.
- Baselines are versioned JSON.
- Baseline reader supports current and one previous format automatically.
- CLI JSON output is an event stream.
- Registration supports comptime and runtime paths.
- Async uses user-supplied executor adapters.
- Profiling supports external mode and in-process hooks.
- Same-process benchmark execution is default; `--isolate-process` is available.
- CPU pinning and priority changes are explicit only.
- Analysis is parallel by default and bit-for-bit deterministic across worker counts.
- Bootstrap uses fixed default seed with `--seed`.
- Tests verify sigbench math directly rather than treating Criterion fixtures as truth.
