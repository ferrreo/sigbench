const std = @import("std");
const api = @import("api.zig");
const measurement = @import("measurement.zig");

pub const SamplingMode = enum { auto, linear, flat };
pub const MeasurementKind = enum { wall_time, cpu_cycles, linux_perf, macos_kperf, process_memory, allocator_counters };
pub const Priority = enum { normal, high };
pub const OutputFormat = enum { terse, verbose, json };
pub const ColorMode = enum { auto, always, never };

pub const Config = struct {
    confidence_level: f64 = 0.95,
    significance_level: f64 = 0.05,
    noise_threshold: f64 = 0.02,
    sample_size: u32 = 100,
    resamples: u32 = 100_000,
    warmup_ns: u64 = 3 * std.time.ns_per_s,
    measurement_ns: u64 = 5 * std.time.ns_per_s,
    profile_ns: ?u64 = null,
    profiler: api.Profiler = .{},
    measurement: MeasurementKind = .wall_time,
    sampling_mode: SamplingMode = .auto,
    seed: u64 = 0x51_6b_65_6e_63_68,
    jobs: u32 = 0,
    plot: bool = true,
    chart_mode: ChartMode = .@"svg-js",
    output_format: OutputFormat = .verbose,
    color: ColorMode = .auto,
    quiet: bool = false,
    isolate_process: bool = false,
    pin_cpu: ?u32 = null,
    priority: Priority = .normal,
    output_dir: []const u8 = "zig-out/sigbench",
    quick: bool = false,
};

pub const ChartMode = enum { @"svg-js", svg, uplot, both };

pub const Warmup = struct {
    iterations: u64,
    elapsed_ns: u64,

    pub fn meanNs(self: Warmup) f64 {
        if (self.iterations == 0) return 0;
        return @as(f64, @floatFromInt(self.elapsed_ns)) / @as(f64, @floatFromInt(self.iterations));
    }
};

pub const SampleSet = struct {
    iterations: []u64,
    elapsed_ns: []f64,
    avg_ns: []f64,
    allocator_counters: []measurement.AllocatorCounters = &.{},
    process_memory: []MemorySample = &.{},
    async_used: []bool = &.{},

    pub fn alloc(allocator: std.mem.Allocator, len: usize) !SampleSet {
        const iterations = try allocator.alloc(u64, len);
        errdefer allocator.free(iterations);
        const elapsed_ns = try allocator.alloc(f64, len);
        errdefer allocator.free(elapsed_ns);
        const avg_ns = try allocator.alloc(f64, len);
        errdefer allocator.free(avg_ns);
        const allocator_counters = try allocator.alloc(measurement.AllocatorCounters, len);
        errdefer allocator.free(allocator_counters);
        @memset(allocator_counters, .{});
        const process_memory = try allocator.alloc(MemorySample, len);
        errdefer allocator.free(process_memory);
        @memset(process_memory, .{});
        const async_used = try allocator.alloc(bool, len);
        @memset(async_used, false);
        return .{ .iterations = iterations, .elapsed_ns = elapsed_ns, .avg_ns = avg_ns, .allocator_counters = allocator_counters, .process_memory = process_memory, .async_used = async_used };
    }

    pub fn free(self: SampleSet, allocator: std.mem.Allocator) void {
        allocator.free(self.iterations);
        allocator.free(self.elapsed_ns);
        allocator.free(self.avg_ns);
        if (self.allocator_counters.len != 0) allocator.free(self.allocator_counters);
        if (self.process_memory.len != 0) allocator.free(self.process_memory);
        if (self.async_used.len != 0) allocator.free(self.async_used);
    }
};

pub const MemorySample = struct {
    rss_bytes: f64 = 0,
    peak_rss_bytes: f64 = 0,
    pss_bytes: f64 = 0,
    private_bytes: f64 = 0,
};

pub fn warmup(allocator: std.mem.Allocator, case: api.BenchmarkCase, target_ns: u64, kind: MeasurementKind) !Warmup {
    var total_iterations: u64 = 0;
    var total_elapsed: u64 = 0;
    var iterations: u64 = 1;

    while (total_elapsed < target_ns) : (iterations = std.math.mul(u64, iterations, 2) catch iterations) {
        var b: api.Bencher = .{ .iterations = iterations };
        var counting = measurement.CountingAllocator.init(allocator);
        if (kind == .allocator_counters) b.allocator = counting.allocator();
        try case.run(&b);
        if (b.timing_error) |err| return err;
        if (requiresExternalTiming(kind) and b.unscoped_custom_timing) {
            return error.ExternalMeasurementRequiresScopedCustomTiming;
        }
        if (requiresTimingLoop(kind) and !b.measured) return error.BenchmarkDidNotMeasure;
        total_iterations += iterations;
        total_elapsed += @max(@as(u64, 1), b.elapsed_ns);
        if (iterations == std.math.maxInt(u64)) break;
    }

    return .{ .iterations = total_iterations, .elapsed_ns = total_elapsed };
}

pub fn iterationCounts(allocator: std.mem.Allocator, sample_size: u32, mean_ns: f64, measurement_ns: u64, mode: SamplingMode) ![]u64 {
    const len: usize = @intCast(sample_size);
    const out = try allocator.alloc(u64, len);
    const safe_mean = if (mean_ns > 0) mean_ns else 1;
    const selected = selectedMode(sample_size, safe_mean, measurement_ns, mode);

    switch (selected) {
        .linear => {
            const denom = @as(u64, @intCast(sample_size)) * (@as(u64, @intCast(sample_size)) + 1) / 2;
            const d = @max(@as(u64, 1), @as(u64, @intFromFloat(@as(f64, @floatFromInt(measurement_ns)) / safe_mean / @as(f64, @floatFromInt(denom)))));
            for (out, 0..) |*slot, i| slot.* = d * (@as(u64, @intCast(i)) + 1);
        },
        .flat => {
            const per_sample = @max(@as(u64, 1), @as(u64, @intFromFloat(@as(f64, @floatFromInt(measurement_ns)) / safe_mean / @as(f64, @floatFromInt(sample_size)))));
            for (out) |*slot| slot.* = per_sample;
        },
        .auto => unreachable,
    }
    return out;
}

pub fn collect(
    allocator: std.mem.Allocator,
    io: std.Io,
    case: api.BenchmarkCase,
    samples: SampleSet,
    counts: []const u64,
    kind: MeasurementKind,
) !void {
    var linux_perf = if (kind == .linux_perf) try measurement.LinuxPerf.open() else null;
    defer if (linux_perf) |perf| perf.close();
    var macos_kperf = if (kind == .macos_kperf) try measurement.MacosKperf.open() else null;
    defer if (macos_kperf) |kperf| kperf.close();
    var cpu_cycles: measurement.CpuCycles = .{};

    for (counts, 0..) |iterations, i| {
        var b: api.Bencher = .{
            .iterations = iterations,
            .external_timing = kind == .cpu_cycles or kind == .linux_perf or kind == .macos_kperf,
        };
        if (kind == .cpu_cycles) {
            samples.elapsed_ns[i] = try collectMeasured(case, &b, cpu_cycles.measurement());
        } else if (kind == .linux_perf) {
            samples.elapsed_ns[i] = try collectMeasured(case, &b, linux_perf.?.measurement());
        } else if (kind == .macos_kperf) {
            samples.elapsed_ns[i] = try collectMeasured(case, &b, macos_kperf.?.measurement());
        } else if (kind == .process_memory) {
            const before = try measurement.readProcessMemory(allocator, io);
            try case.run(&b);
            if (b.timing_error) |err| return err;
            const after = try measurement.readProcessMemory(allocator, io);
            samples.process_memory[i] = .{
                .rss_bytes = delta(after.rss_bytes, before.rss_bytes),
                .peak_rss_bytes = @floatFromInt(after.peak_rss_bytes),
                .pss_bytes = delta(after.pss_bytes, before.pss_bytes),
                .private_bytes = delta(after.private_bytes, before.private_bytes),
            };
            samples.elapsed_ns[i] = samples.process_memory[i].rss_bytes;
        } else if (kind == .allocator_counters) {
            var counting = measurement.CountingAllocator.init(allocator);
            b.allocator = counting.allocator();
            try case.run(&b);
            if (b.timing_error) |err| return err;
            samples.elapsed_ns[i] = @floatFromInt(counting.counters.allocations);
            samples.allocator_counters[i] = counting.counters;
        } else {
            try case.run(&b);
            if (b.timing_error) |err| return err;
            if (!b.measured) return error.BenchmarkDidNotMeasure;
            samples.elapsed_ns[i] = @floatFromInt(b.elapsed_ns);
        }
        if (samples.async_used.len != 0) samples.async_used[i] = b.used_async;
        samples.iterations[i] = iterations;
        samples.avg_ns[i] = if (kind == .process_memory or kind == .allocator_counters) samples.elapsed_ns[i] else samples.elapsed_ns[i] / @as(f64, @floatFromInt(iterations));
    }
}

fn collectMeasured(case: api.BenchmarkCase, b: *api.Bencher, m: measurement.Measurement) !f64 {
    b.measurement_driver = .{
        .ctx = m.ctx,
        .start = m.start,
        .end = m.end,
        .zero = m.zero,
        .add = m.add,
    };
    try case.run(b);
    if (b.timing_error) |err| return err;
    if (b.unscoped_custom_timing) return error.ExternalMeasurementRequiresScopedCustomTiming;
    if (!b.measured) return error.BenchmarkDidNotMeasure;
    return m.toF64(m.ctx, b.elapsed_ns);
}

fn delta(after: u64, before: u64) f64 {
    return @as(f64, @floatFromInt(after)) - @as(f64, @floatFromInt(before));
}

fn requiresTimingLoop(kind: MeasurementKind) bool {
    return switch (kind) {
        .wall_time, .cpu_cycles, .linux_perf, .macos_kperf => true,
        .process_memory, .allocator_counters => false,
    };
}

fn requiresExternalTiming(kind: MeasurementKind) bool {
    return switch (kind) {
        .cpu_cycles, .linux_perf, .macos_kperf => true,
        .wall_time, .process_memory, .allocator_counters => false,
    };
}

pub fn selectedMode(sample_size: u32, mean_ns: f64, measurement_ns: u64, mode: SamplingMode) SamplingMode {
    return if (mode == .auto) autoMode(sample_size, mean_ns, measurement_ns) else mode;
}

pub fn defaultJobs(nproc: u32) u32 {
    if (nproc < 4) return nproc;
    return @min(nproc, @max(@as(u32, 4), nproc / 2));
}

fn autoMode(sample_size: u32, mean_ns: f64, measurement_ns: u64) SamplingMode {
    const per_sample = @as(f64, @floatFromInt(measurement_ns)) / @as(f64, @floatFromInt(sample_size));
    return if (mean_ns * 10.0 < per_sample) .linear else .flat;
}

test "warmup estimate math" {
    const w: Warmup = .{ .iterations = 4, .elapsed_ns = 100 };
    try std.testing.expectEqual(@as(f64, 25), w.meanNs());
}

test "warmup rejects unmeasured timing benchmark" {
    const S = struct {
        fn run(_: *api.Bencher) void {}
    };
    const case = comptime api.benchWithId("noop", "noop", S.run);
    try std.testing.expectError(error.BenchmarkDidNotMeasure, warmup(std.testing.allocator, case, 1, .wall_time));
}

test "config defaults match spec" {
    const config: Config = .{};
    try std.testing.expectEqual(@as(u32, 100), config.sample_size);
    try std.testing.expectEqual(@as(u64, 3 * std.time.ns_per_s), config.warmup_ns);
    try std.testing.expectEqual(@as(u64, 5 * std.time.ns_per_s), config.measurement_ns);
}

test "linear iteration counts grow by step" {
    const counts = try iterationCounts(std.testing.allocator, 4, 10, 1000, .linear);
    defer std.testing.allocator.free(counts);

    try std.testing.expectEqual(@as(u64, 10), counts[0]);
    try std.testing.expectEqual(@as(u64, 20), counts[1]);
    try std.testing.expectEqual(@as(u64, 30), counts[2]);
    try std.testing.expectEqual(@as(u64, 40), counts[3]);
}

test "flat iteration counts are equal" {
    const counts = try iterationCounts(std.testing.allocator, 4, 10, 1000, .flat);
    defer std.testing.allocator.free(counts);

    try std.testing.expectEqual(@as(u64, 25), counts[0]);
    try std.testing.expectEqual(counts[0], counts[3]);
}

test "default jobs follows spec" {
    try std.testing.expectEqual(@as(u32, 1), defaultJobs(1));
    try std.testing.expectEqual(@as(u32, 3), defaultJobs(3));
    try std.testing.expectEqual(@as(u32, 4), defaultJobs(8));
    try std.testing.expectEqual(@as(u32, 8), defaultJobs(16));
}

test "allocator counter collection records allocations" {
    const S = struct {
        fn run(b: *api.Bencher) void {
            const allocator = b.benchmarkAllocator();
            var i: u64 = 0;
            while (i < b.iterations) : (i += 1) {
                const memory = allocator.alloc(u8, 1) catch return;
                allocator.free(memory);
            }
        }
    };
    const case = comptime api.benchWithId("alloc", "alloc", S.run);
    var iterations = [_]u64{3};
    var elapsed = [_]f64{0};
    var avg = [_]f64{0};
    var counters = [_]measurement.AllocatorCounters{.{}};
    const samples: SampleSet = .{ .iterations = &iterations, .elapsed_ns = &elapsed, .avg_ns = &avg, .allocator_counters = &counters };
    try collect(std.testing.allocator, std.testing.io, case, samples, &iterations, .allocator_counters);
    try std.testing.expectEqual(@as(f64, 3), samples.elapsed_ns[0]);
    try std.testing.expectEqual(@as(f64, 3), samples.avg_ns[0]);
    try std.testing.expectEqual(@as(u64, 3), samples.allocator_counters[0].frees);
    try std.testing.expectEqual(@as(u64, 3), samples.allocator_counters[0].allocated_bytes);
    try std.testing.expectEqual(@as(u64, 1), samples.allocator_counters[0].peak_live_bytes);
}

test "async collection marks async samples" {
    const S = struct {
        fn noop() void {}
        fn exec(_: *anyopaque, routine: *const fn () void) void {
            routine();
        }
        fn run(b: *api.Bencher) void {
            b.iterAsync(.{ .ctx = undefined, .run = exec }, noop);
        }
    };
    const case = comptime api.benchWithId("async", "async", S.run);
    var iterations = [_]u64{1};
    var elapsed = [_]f64{0};
    var avg = [_]f64{0};
    var async_used = [_]bool{false};
    const samples: SampleSet = .{ .iterations = &iterations, .elapsed_ns = &elapsed, .avg_ns = &avg, .async_used = &async_used };
    try collect(std.testing.allocator, std.testing.io, case, samples, &iterations, .wall_time);
    try std.testing.expect(samples.async_used[0]);
}

test "wall-time collection does not allocate" {
    const S = struct {
        fn noop() void {}

        fn run(b: *api.Bencher) void {
            b.iter(noop);
        }
    };
    const case = comptime api.benchWithId("noop", "noop", S.run);
    var iterations = [_]u64{ 1, 2 };
    var elapsed = [_]f64{ 0, 0 };
    var avg = [_]f64{ 0, 0 };
    const samples: SampleSet = .{ .iterations = &iterations, .elapsed_ns = &elapsed, .avg_ns = &avg };
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });

    try collect(failing.allocator(), std.testing.io, case, samples, &iterations, .wall_time);

    try std.testing.expect(!failing.has_induced_failure);
    try std.testing.expectEqual(@as(usize, 0), failing.allocations);
    try std.testing.expect(samples.elapsed_ns[0] >= 0);
    try std.testing.expect(samples.avg_ns[1] >= 0);
}

test "wall-time collection rejects unmeasured benchmark" {
    const S = struct {
        fn run(_: *api.Bencher) void {}
    };
    const case = comptime api.benchWithId("noop", "noop", S.run);
    var iterations = [_]u64{1};
    var elapsed = [_]f64{0};
    var avg = [_]f64{0};
    const samples: SampleSet = .{ .iterations = &iterations, .elapsed_ns = &elapsed, .avg_ns = &avg };
    try std.testing.expectError(error.BenchmarkDidNotMeasure, collect(std.testing.allocator, std.testing.io, case, samples, &iterations, .wall_time));
}

test "external measurement honors scoped custom boundaries" {
    const S = struct {
        var now: u64 = 0;
        var starts: u64 = 0;
        var ends: u64 = 0;

        fn bench(b: *api.Bencher) !void {
            now += 100;
            try b.iterCustomScoped(run);
            now += 200;
        }

        fn run(iterations: u64, scope: *api.MeasurementScope) !void {
            now += 300;
            try scope.start();
            var iteration: u64 = 0;
            while (iteration < iterations) : (iteration += 1) now += 7;
            try scope.stop();
            now += 400;
        }

        fn start(_: *anyopaque) !measurement.MeasurementValue {
            starts += 1;
            return now;
        }

        fn end(_: *anyopaque, started: measurement.MeasurementValue) !measurement.MeasurementValue {
            ends += 1;
            return now - started;
        }

        fn zero(_: *anyopaque) measurement.MeasurementValue {
            return 0;
        }

        fn add(_: *anyopaque, a: measurement.MeasurementValue, b: measurement.MeasurementValue) measurement.MeasurementValue {
            return a + b;
        }

        fn toF64(_: *anyopaque, value: measurement.MeasurementValue) f64 {
            return @floatFromInt(value);
        }

        fn format(_: *anyopaque, allocator: std.mem.Allocator, value: measurement.MeasurementValue) ![]u8 {
            return std.fmt.allocPrint(allocator, "{}", .{value});
        }
    };
    var ctx: u8 = 0;
    var b: api.Bencher = .{ .iterations = 3, .external_timing = true };
    const case = comptime api.benchWithId("scoped", "scoped", S.bench);
    const elapsed = try collectMeasured(case, &b, .{
        .ctx = &ctx,
        .start = S.start,
        .end = S.end,
        .zero = S.zero,
        .add = S.add,
        .toF64 = S.toF64,
        .format = S.format,
    });
    try std.testing.expectEqual(@as(f64, 21), elapsed);
    try std.testing.expectEqual(@as(u64, 1), S.starts);
    try std.testing.expectEqual(@as(u64, 1), S.ends);
}

test "external measurement rejects legacy custom timing" {
    const S = struct {
        fn elapsed(iterations: u64) u64 {
            return iterations;
        }

        fn bench(b: *api.Bencher) void {
            b.iterCustom(elapsed);
        }
    };
    var wall: measurement.WallClock = .{};
    var b: api.Bencher = .{ .external_timing = true };
    const case = comptime api.benchWithId("legacy", "legacy", S.bench);
    try std.testing.expectError(
        error.ExternalMeasurementRequiresScopedCustomTiming,
        collectMeasured(case, &b, wall.measurement()),
    );
    try std.testing.expectError(
        error.ExternalMeasurementRequiresScopedCustomTiming,
        warmup(std.testing.allocator, case, 1, .cpu_cycles),
    );
}

test "collection rejects caught scope protocol error" {
    const S = struct {
        fn scoped(_: u64, _: *api.MeasurementScope) !void {}

        fn bench(b: *api.Bencher) void {
            b.iterCustomScoped(scoped) catch {};
        }
    };
    const case = comptime api.benchWithId("caught", "caught", S.bench);
    var iterations = [_]u64{1};
    var elapsed = [_]f64{0};
    var avg = [_]f64{0};
    const samples: SampleSet = .{
        .iterations = &iterations,
        .elapsed_ns = &elapsed,
        .avg_ns = &avg,
    };
    try std.testing.expectError(
        error.MeasurementScopeNotStarted,
        collect(
            std.testing.allocator,
            std.testing.io,
            case,
            samples,
            &iterations,
            .wall_time,
        ),
    );
}
