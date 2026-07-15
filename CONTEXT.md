# Sigbench

Sigbench is a statistics-driven microbenchmarking library for Zig projects. It gives Zig users Criterion-style evidence about performance changes without copying Rust-specific APIs.

## Language

**Benchmark**:
One named thing being measured. A benchmark contains one or more benchmark cases.
_Avoid_: Test, perf test

**Benchmark Case**:
One benchmarked routine with one parameter set, one throughput setting, and one produced sample set.
_Avoid_: Target, function

**Benchmark ID**:
Stable path-safe identifier for a benchmark group or case. Baselines attach to IDs, not display names.
_Avoid_: Name when discussing persistence

**Benchmark Group**:
A named collection of related benchmark cases that share default configuration.
_Avoid_: Suite, category

**Routine**:
User code called by the bencher during warmup and measurement.
_Avoid_: Closure, callback, workload

**Iteration**:
One execution of a routine inside a timing loop.
_Avoid_: Run, call

**Sample**:
One measured batch containing an iteration count and one elapsed measurement.
_Avoid_: Measurement, datapoint

**Measurement**:
The value recorded for a sample. Wall-clock time, CPU cycles, Linux perf counters, and macOS kperf counters are supported measurement kinds.
_Avoid_: Duration when the value might later come from counters

**Measurement Scope**:
Explicit start and stop boundary inside a custom timing routine. Setup and teardown stay outside
the selected measurement kind.
_Avoid_: Timer when the selected measurement may be a hardware counter

**Resident Set Size**:
Process memory currently resident in physical memory. Platform APIs name this differently; Windows calls the closest process-level value working set.
_Avoid_: RSS when discussing Windows API names

**Proportional Set Size**:
Linux memory metric that divides shared pages proportionally across processes. Windows Process Snapshotting uses the acronym PSS for a different API and is not this metric.
_Avoid_: PSS without spelling it out

**Allocator Counters**:
Counts and byte totals recorded by a sigbench-wrapped allocator, such as allocations, frees, resizes, live bytes, and peak live bytes. They only describe memory routed through that allocator.
_Avoid_: Memory usage

**Estimate**:
A statistical result with a point estimate, confidence interval, and standard error.
_Avoid_: Average

**Baseline**:
Saved benchmark data from an earlier run used for comparison.
_Avoid_: Snapshot, previous result

**Throughput**:
Per-iteration work amount used to display bytes, bits, or elements per second.
_Avoid_: Bandwidth unless measuring bytes

## Example Dialogue

Dev: "I added a benchmark group for encoders with cases for 1 KiB and 1 MiB inputs."

Reviewer: "Does each case set throughput in bytes?"

Dev: "Yes. Each case produces samples, then sigbench compares those samples against the main baseline."

Reviewer: "The report says the slope estimate regressed but the change is inside the noise threshold, so we should not treat it as a real regression."
