# Explicit Linux perf thread aggregation

Linux perf measurements keep the benchmark caller event and accept explicit existing worker IDs
through `MeasurementScope.includeThread` before `start`. Each distinct worker gets its own
`perf_event_open` descriptor with kernel and hypervisor events excluded. Start resets and enables
all descriptors; stop disables, reads, checked-adds, and closes the worker descriptors.

The worker table is fixed at 64 entries and allocates nothing. Caller and duplicate IDs are
ignored. Registration, start, stop, read, and overflow failures reject the sample and clear all
worker descriptors. The caller descriptor remains open across samples; worker registrations are
per-scope and must be repeated for the next sample.

The scope's one-shot cleanup hook clears registrations after callbacks that fail before `start`
or omit `start`. Linux also checks `tgkill(getpid(), tid, 0)` immediately before opening each
worker event. The benchmark's keep-alive requirement prevents thread exit and numeric-ID reuse
from racing that membership check.

The thread that opens the Linux perf backend owns the caller descriptor and must execute both
scope boundaries. Start rejects a changed thread before enabling descriptors. End always disables
and clears worker state first, then rejects a changed thread, allowing a later scope on the opener
thread to reuse the backend safely.

This is explicit thread aggregation, not process inheritance. A worker must exist when registered,
remain alive through `stop`, and belong to the benchmark process. Workers cannot be registered
after `start`. Wall-clock and serialized TSC drivers keep null hooks, so `includeThread` is a no-op
for those measurements. This avoids process-wide perf inheritance, unbounded descriptor storage,
hidden allocations, and ambiguous inclusion of unrelated threads.
