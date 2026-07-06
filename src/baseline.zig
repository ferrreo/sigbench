const std = @import("std");
const measure = @import("measurement.zig");
const sampling = @import("sampling.zig");
const stats = @import("stats.zig");

pub const SampleJson = struct {
    format: u32 = 1,
    measurement: []const u8 = "wall_time",
    seed: u64 = 0,
    sampling_mode: []const u8,
    iterations: []u64,
    elapsed_ns: []f64,
    allocator_counters: ?AllocatorCountersJson = null,
    process_memory: ?ProcessMemoryJson = null,
};

pub const AllocatorCountersJson = struct {
    allocations: []u64 = &.{},
    frees: []u64 = &.{},
    resizes: []u64 = &.{},
    allocated_bytes: []u64 = &.{},
    freed_bytes: []u64 = &.{},
    resized_bytes: []u64 = &.{},
    live_bytes: []u64 = &.{},
    peak_live_bytes: []u64 = &.{},
};

pub const ProcessMemoryJson = struct {
    rss_bytes: []f64 = &.{},
    peak_rss_bytes: []f64 = &.{},
    pss_bytes: []f64 = &.{},
    private_bytes: []f64 = &.{},
};

pub const Comparison = struct {
    mean_change: f64,
    mean_change_ci: stats.Estimate,
    median_change: f64,
    median_change_ci: stats.Estimate,
    p_value: f64,
    verdict: Verdict,
};

pub const Verdict = enum {
    improved,
    regressed,
    unchanged,
};

pub fn writeSampleJson(
    allocator: std.mem.Allocator,
    samples: sampling.SampleSet,
    mode: sampling.SamplingMode,
    measurement: sampling.MeasurementKind,
    seed: u64,
) ![]u8 {
    var bytes = std.array_list.Managed(u8).init(allocator);
    errdefer bytes.deinit();

    try bytes.print(
        "{{\n  \"format\": 1,\n  \"measurement\": \"{s}\",\n  \"seed\": {},\n  \"sampling_mode\": \"{s}\",\n  \"iterations\": [",
        .{ @tagName(measurement), seed, @tagName(mode) },
    );
    for (samples.iterations, 0..) |n, i| {
        if (i != 0) try bytes.appendSlice(", ");
        try bytes.print("{}", .{n});
    }
    try bytes.appendSlice("],\n  \"elapsed_ns\": [");
    for (samples.elapsed_ns, 0..) |n, i| {
        if (i != 0) try bytes.appendSlice(", ");
        try bytes.print("{d:.0}", .{n});
    }
    try bytes.appendSlice("]");
    if (measurement == .allocator_counters) try writeAllocatorCounters(&bytes, samples.allocator_counters);
    if (measurement == .process_memory) try writeProcessMemory(&bytes, samples.process_memory);
    try bytes.appendSlice("\n}\n");

    return bytes.toOwnedSlice();
}

fn writeAllocatorCounters(bytes: *std.array_list.Managed(u8), counters: []const measure.AllocatorCounters) !void {
    try bytes.appendSlice(",\n  \"allocator_counters\": {");
    try writeCounterArray(bytes, "allocations", counters, .allocations, true);
    try writeCounterArray(bytes, "frees", counters, .frees, false);
    try writeCounterArray(bytes, "resizes", counters, .resizes, false);
    try writeCounterArray(bytes, "allocated_bytes", counters, .allocated_bytes, false);
    try writeCounterArray(bytes, "freed_bytes", counters, .freed_bytes, false);
    try writeCounterArray(bytes, "resized_bytes", counters, .resized_bytes, false);
    try writeCounterArray(bytes, "live_bytes", counters, .live_bytes, false);
    try writeCounterArray(bytes, "peak_live_bytes", counters, .peak_live_bytes, false);
    try bytes.appendSlice("}");
}

const CounterField = enum { allocations, frees, resizes, allocated_bytes, freed_bytes, resized_bytes, live_bytes, peak_live_bytes };

fn writeCounterArray(bytes: *std.array_list.Managed(u8), name: []const u8, counters: []const measure.AllocatorCounters, field: CounterField, first: bool) !void {
    if (!first) try bytes.appendSlice(",");
    try bytes.print("\n    \"{s}\": [", .{name});
    for (counters, 0..) |counter, i| {
        if (i != 0) try bytes.appendSlice(", ");
        const value = switch (field) {
            .allocations => counter.allocations,
            .frees => counter.frees,
            .resizes => counter.resizes,
            .allocated_bytes => counter.allocated_bytes,
            .freed_bytes => counter.freed_bytes,
            .resized_bytes => counter.resized_bytes,
            .live_bytes => counter.live_bytes,
            .peak_live_bytes => counter.peak_live_bytes,
        };
        try bytes.print("{}", .{value});
    }
    try bytes.appendSlice("]");
}

fn writeProcessMemory(bytes: *std.array_list.Managed(u8), samples: []const sampling.MemorySample) !void {
    try bytes.appendSlice(",\n  \"process_memory\": {");
    try writeMemoryArray(bytes, "rss_bytes", samples, .rss, true);
    try writeMemoryArray(bytes, "peak_rss_bytes", samples, .peak_rss, false);
    try writeMemoryArray(bytes, "pss_bytes", samples, .pss, false);
    try writeMemoryArray(bytes, "private_bytes", samples, .private_bytes, false);
    try bytes.appendSlice("}");
}

const MemoryField = enum { rss, peak_rss, pss, private_bytes };

fn writeMemoryArray(bytes: *std.array_list.Managed(u8), name: []const u8, samples: []const sampling.MemorySample, field: MemoryField, first: bool) !void {
    if (!first) try bytes.appendSlice(",");
    try bytes.print("\n    \"{s}\": [", .{name});
    for (samples, 0..) |sample, i| {
        if (i != 0) try bytes.appendSlice(", ");
        const value = switch (field) {
            .rss => sample.rss_bytes,
            .peak_rss => sample.peak_rss_bytes,
            .pss => sample.pss_bytes,
            .private_bytes => sample.private_bytes,
        };
        try bytes.print("{d}", .{value});
    }
    try bytes.appendSlice("]");
}

pub fn readSampleJson(allocator: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(SampleJson) {
    var parsed = try std.json.parseFromSlice(SampleJson, allocator, bytes, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
    errdefer parsed.deinit();
    switch (parsed.value.format) {
        0, 1 => {},
        else => return error.UnsupportedBaselineFormat,
    }
    if (parsed.value.iterations.len == 0 or parsed.value.iterations.len != parsed.value.elapsed_ns.len) return error.InvalidBaseline;
    for (parsed.value.iterations, parsed.value.elapsed_ns) |iterations, elapsed| {
        if (iterations == 0 or !std.math.isFinite(elapsed)) return error.InvalidBaseline;
    }
    try validateMetricLengths(parsed.value);
    return parsed;
}

fn validateMetricLengths(loaded: SampleJson) !void {
    const len = loaded.iterations.len;
    if (loaded.allocator_counters) |counters| {
        if (counters.allocations.len != len or
            counters.frees.len != len or
            counters.resizes.len != len or
            counters.allocated_bytes.len != len or
            counters.freed_bytes.len != len or
            counters.resized_bytes.len != len or
            counters.live_bytes.len != len or
            counters.peak_live_bytes.len != len) return error.InvalidBaseline;
    }
    if (loaded.process_memory) |memory| {
        if (memory.rss_bytes.len != len or
            memory.peak_rss_bytes.len != len or
            memory.pss_bytes.len != len or
            memory.private_bytes.len != len) return error.InvalidBaseline;
        for (memory.rss_bytes, memory.peak_rss_bytes, memory.pss_bytes, memory.private_bytes) |rss, peak, pss, private| {
            if (!std.math.isFinite(rss) or !std.math.isFinite(peak) or !std.math.isFinite(pss) or !std.math.isFinite(private)) return error.InvalidBaseline;
        }
    }
}

pub fn copyMetricSamples(samples: sampling.SampleSet, loaded: SampleJson) void {
    if (loaded.allocator_counters) |counters| if (counters.allocations.len == samples.allocator_counters.len) {
        for (samples.allocator_counters, 0..) |*out, i| {
            out.* = .{
                .allocations = at(counters.allocations, i),
                .frees = at(counters.frees, i),
                .resizes = at(counters.resizes, i),
                .allocated_bytes = at(counters.allocated_bytes, i),
                .freed_bytes = at(counters.freed_bytes, i),
                .resized_bytes = at(counters.resized_bytes, i),
                .live_bytes = at(counters.live_bytes, i),
                .peak_live_bytes = at(counters.peak_live_bytes, i),
            };
        }
    };
    if (loaded.process_memory) |memory| if (memory.rss_bytes.len == samples.process_memory.len) {
        for (samples.process_memory, 0..) |*out, i| {
            out.* = .{
                .rss_bytes = atF(memory.rss_bytes, i),
                .peak_rss_bytes = atF(memory.peak_rss_bytes, i),
                .pss_bytes = atF(memory.pss_bytes, i),
                .private_bytes = atF(memory.private_bytes, i),
            };
        }
    };
}

fn at(values: []const u64, i: usize) u64 {
    return if (i < values.len) values[i] else 0;
}

fn atF(values: []const f64, i: usize) f64 {
    return if (i < values.len) values[i] else 0;
}

pub fn compareScratchLen(current_len: usize, baseline_len: usize, resamples: usize) usize {
    return current_len * 2 + baseline_len * 3 + resamples * 2;
}

pub fn compare(current_avg_ns: []const f64, baseline_elapsed_ns: []const f64, baseline_iterations: []const u64, measurement: sampling.MeasurementKind, noise_threshold: f64, significance_level: f64, confidence_level: f64, resamples: usize, seed: u64, scratch: []f64) Comparison {
    std.debug.assert(scratch.len >= compareScratchLen(current_avg_ns.len, baseline_elapsed_ns.len, resamples));
    for (baseline_elapsed_ns, baseline_iterations, 0..) |elapsed, iterations, i| {
        scratch[i] = if (measurement == .process_memory or measurement == .allocator_counters) elapsed else elapsed / @as(f64, @floatFromInt(iterations));
    }
    const baseline_avg = scratch[0..baseline_elapsed_ns.len];

    const current_mean = stats.mean(current_avg_ns);
    const baseline_mean = stats.mean(baseline_avg);
    const mean_change = stats.relativeChange(current_mean, baseline_mean);

    const current_median = medianCopy(current_avg_ns, scratch[baseline_elapsed_ns.len..][0..current_avg_ns.len]);
    const baseline_median = medianCopy(scratch[0..baseline_elapsed_ns.len], scratch[baseline_elapsed_ns.len + current_avg_ns.len ..][0..baseline_elapsed_ns.len]);
    const median_change = stats.relativeChange(current_median, baseline_median);
    const p_value = if (current_avg_ns.len > 1 and baseline_elapsed_ns.len > 1)
        pValue(current_avg_ns, baseline_avg)
    else
        1.0;

    const mean_dist_start = baseline_elapsed_ns.len + current_avg_ns.len + baseline_elapsed_ns.len;
    const median_dist_start = mean_dist_start + resamples;
    const current_tmp_start = median_dist_start + resamples;
    const baseline_tmp_start = current_tmp_start + current_avg_ns.len;
    const mean_dist = scratch[mean_dist_start..][0..resamples];
    const median_dist = scratch[median_dist_start..][0..resamples];
    bootstrapRelativeChanges(
        current_avg_ns,
        baseline_avg,
        mean_dist,
        median_dist,
        scratch[current_tmp_start..][0..current_avg_ns.len],
        scratch[baseline_tmp_start..][0..baseline_elapsed_ns.len],
        seed,
    );
    std.mem.sort(f64, mean_dist, {}, comptime std.sort.asc(f64));
    std.mem.sort(f64, median_dist, {}, comptime std.sort.asc(f64));

    return .{
        .mean_change = mean_change,
        .mean_change_ci = stats.confidenceIntervalSorted(mean_dist, confidence_level),
        .median_change = median_change,
        .median_change_ci = stats.confidenceIntervalSorted(median_dist, confidence_level),
        .p_value = p_value,
        .verdict = verdict(mean_change, p_value, noise_threshold, significance_level),
    };
}

pub fn metricRegressed(current: sampling.SampleSet, loaded: SampleJson, measurement: sampling.MeasurementKind, noise_threshold: f64) bool {
    return switch (measurement) {
        .process_memory => if (loaded.process_memory) |memory|
            regressedF(meanMemory(current.process_memory, .rss), memory.rss_bytes, noise_threshold) or
                regressedF(meanMemory(current.process_memory, .peak_rss), memory.peak_rss_bytes, noise_threshold) or
                regressedF(meanMemory(current.process_memory, .pss), memory.pss_bytes, noise_threshold) or
                regressedF(meanMemory(current.process_memory, .private_bytes), memory.private_bytes, noise_threshold)
        else
            false,
        .allocator_counters => if (loaded.allocator_counters) |counters|
            regressedU(meanAlloc(current.allocator_counters, .allocations), counters.allocations, noise_threshold) or
                regressedU(meanAlloc(current.allocator_counters, .frees), counters.frees, noise_threshold) or
                regressedU(meanAlloc(current.allocator_counters, .resizes), counters.resizes, noise_threshold) or
                regressedU(meanAlloc(current.allocator_counters, .allocated_bytes), counters.allocated_bytes, noise_threshold) or
                regressedU(meanAlloc(current.allocator_counters, .freed_bytes), counters.freed_bytes, noise_threshold) or
                regressedU(meanAlloc(current.allocator_counters, .resized_bytes), counters.resized_bytes, noise_threshold) or
                regressedU(meanAlloc(current.allocator_counters, .live_bytes), counters.live_bytes, noise_threshold) or
                regressedU(meanAlloc(current.allocator_counters, .peak_live_bytes), counters.peak_live_bytes, noise_threshold)
        else
            false,
        else => false,
    };
}

fn verdict(mean_change: f64, p_value: f64, noise_threshold: f64, significance_level: f64) Verdict {
    if (@abs(mean_change) <= noise_threshold or p_value > significance_level) return .unchanged;
    return if (mean_change < 0) .improved else .regressed;
}

fn pValue(current: []const f64, previous: []const f64) f64 {
    const t = stats.twoSampleT(current, previous);
    return stats.pValueFromT(t.t, t.degrees_freedom);
}

fn medianCopy(values: []const f64, scratch: []f64) f64 {
    @memcpy(scratch[0..values.len], values);
    std.mem.sort(f64, scratch[0..values.len], {}, comptime std.sort.asc(f64));
    return stats.medianSorted(scratch[0..values.len]);
}

fn bootstrapRelativeChanges(current: []const f64, baseline: []const f64, mean_dist: []f64, median_dist: []f64, current_tmp: []f64, baseline_tmp: []f64, seed: u64) void {
    for (mean_dist, median_dist, 0..) |*mean_slot, *median_slot, index| {
        var prng = std.Random.DefaultPrng.init(mixSeed(seed, index));
        const random = prng.random();
        var current_total: f64 = 0;
        var baseline_total: f64 = 0;
        for (current_tmp) |*slot| {
            slot.* = current[random.intRangeLessThan(usize, 0, current.len)];
            current_total += slot.*;
        }
        for (baseline_tmp) |*slot| {
            slot.* = baseline[random.intRangeLessThan(usize, 0, baseline.len)];
            baseline_total += slot.*;
        }
        std.mem.sort(f64, current_tmp, {}, comptime std.sort.asc(f64));
        std.mem.sort(f64, baseline_tmp, {}, comptime std.sort.asc(f64));
        mean_slot.* = stats.relativeChange(current_total / @as(f64, @floatFromInt(current.len)), baseline_total / @as(f64, @floatFromInt(baseline.len)));
        median_slot.* = stats.relativeChange(stats.medianSorted(current_tmp), stats.medianSorted(baseline_tmp));
    }
}

fn mixSeed(seed: u64, index: usize) u64 {
    var x = seed +% @as(u64, @intCast(index)) *% 0x9e3779b97f4a7c15;
    x = (x ^ (x >> 30)) *% 0xbf58476d1ce4e5b9;
    x = (x ^ (x >> 27)) *% 0x94d049bb133111eb;
    return x ^ (x >> 31);
}

fn regressedF(current: f64, baseline_values: []const f64, noise_threshold: f64) bool {
    return baseline_values.len != 0 and stats.relativeChange(current, meanF(baseline_values)) > noise_threshold;
}

fn regressedU(current: f64, baseline_values: []const u64, noise_threshold: f64) bool {
    return baseline_values.len != 0 and stats.relativeChange(current, meanU(baseline_values)) > noise_threshold;
}

fn meanF(values: []const f64) f64 {
    var total: f64 = 0;
    for (values) |value| total += value;
    return total / @as(f64, @floatFromInt(values.len));
}

fn meanU(values: []const u64) f64 {
    var total: f64 = 0;
    for (values) |value| total += @floatFromInt(value);
    return total / @as(f64, @floatFromInt(values.len));
}

fn meanMemory(samples: []const sampling.MemorySample, field: MemoryField) f64 {
    var total: f64 = 0;
    for (samples) |sample| total += switch (field) {
        .rss => sample.rss_bytes,
        .peak_rss => sample.peak_rss_bytes,
        .pss => sample.pss_bytes,
        .private_bytes => sample.private_bytes,
    };
    return total / @as(f64, @floatFromInt(samples.len));
}

fn meanAlloc(samples: []const measure.AllocatorCounters, field: CounterField) f64 {
    var total: f64 = 0;
    for (samples) |sample| total += @floatFromInt(switch (field) {
        .allocations => sample.allocations,
        .frees => sample.frees,
        .resizes => sample.resizes,
        .allocated_bytes => sample.allocated_bytes,
        .freed_bytes => sample.freed_bytes,
        .resized_bytes => sample.resized_bytes,
        .live_bytes => sample.live_bytes,
        .peak_live_bytes => sample.peak_live_bytes,
    });
    return total / @as(f64, @floatFromInt(samples.len));
}

test "sample json round trip" {
    var iterations = [_]u64{ 1, 2, 3 };
    var elapsed = [_]f64{ 10, 20, 30 };
    var avg = [_]f64{ 10, 10, 10 };
    const samples: sampling.SampleSet = .{ .iterations = &iterations, .elapsed_ns = &elapsed, .avg_ns = &avg };

    const bytes = try writeSampleJson(std.testing.allocator, samples, .linear, .wall_time, 123);
    defer std.testing.allocator.free(bytes);

    var parsed = try readSampleJson(std.testing.allocator, bytes);
    defer parsed.deinit();

    try std.testing.expectEqual(@as(u32, 1), parsed.value.format);
    try std.testing.expectEqual(@as(u64, 123), parsed.value.seed);
    try std.testing.expectEqualStrings("linear", parsed.value.sampling_mode);
    try std.testing.expectEqual(@as(u64, 2), parsed.value.iterations[1]);
    try std.testing.expectEqual(@as(f64, 30), parsed.value.elapsed_ns[2]);
}

test "sample json keeps allocator metrics" {
    var iterations = [_]u64{1};
    var elapsed = [_]f64{2};
    var avg = [_]f64{2};
    var counters = [_]measure.AllocatorCounters{.{ .allocations = 1, .frees = 1, .allocated_bytes = 16, .freed_bytes = 16, .peak_live_bytes = 16 }};
    const samples: sampling.SampleSet = .{ .iterations = &iterations, .elapsed_ns = &elapsed, .avg_ns = &avg, .allocator_counters = &counters };
    const bytes = try writeSampleJson(std.testing.allocator, samples, .flat, .allocator_counters, 1);
    defer std.testing.allocator.free(bytes);
    var parsed = try readSampleJson(std.testing.allocator, bytes);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(u64, 1), parsed.value.allocator_counters.?.frees[0]);
    try std.testing.expectEqual(@as(u64, 16), parsed.value.allocator_counters.?.peak_live_bytes[0]);
}

test "sample json keeps process memory metrics" {
    var iterations = [_]u64{1};
    var elapsed = [_]f64{2};
    var avg = [_]f64{2};
    var memory = [_]sampling.MemorySample{.{ .rss_bytes = 1, .peak_rss_bytes = 2, .pss_bytes = 3, .private_bytes = 4 }};
    const samples: sampling.SampleSet = .{ .iterations = &iterations, .elapsed_ns = &elapsed, .avg_ns = &avg, .process_memory = &memory };
    const bytes = try writeSampleJson(std.testing.allocator, samples, .flat, .process_memory, 1);
    defer std.testing.allocator.free(bytes);
    var parsed = try readSampleJson(std.testing.allocator, bytes);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(f64, 2), parsed.value.process_memory.?.peak_rss_bytes[0]);
    try std.testing.expectEqual(@as(f64, 4), parsed.value.process_memory.?.private_bytes[0]);
}

test "compare classifies inside noise as unchanged" {
    const current = [_]f64{ 100, 101, 102 };
    const baseline_elapsed = [_]f64{ 100, 100, 100 };
    const baseline_iterations = [_]u64{ 1, 1, 1 };
    var scratch: [compareScratchLen(current.len, baseline_elapsed.len, 16)]f64 = undefined;

    const c = compare(&current, &baseline_elapsed, &baseline_iterations, .wall_time, 0.05, 0.05, 0.95, 16, 1, &scratch);
    try std.testing.expectEqual(Verdict.unchanged, c.verdict);
    try std.testing.expect(c.mean_change_ci.lower <= c.mean_change_ci.upper);
}

test "compare requires significance before classifying change" {
    const current = [_]f64{ 110, 111, 112 };
    const baseline_elapsed = [_]f64{ 100, 101, 102 };
    const baseline_iterations = [_]u64{ 1, 1, 1 };
    var scratch: [compareScratchLen(current.len, baseline_elapsed.len, 16)]f64 = undefined;

    const c = compare(&current, &baseline_elapsed, &baseline_iterations, .wall_time, 0.0, 0.0, 0.95, 16, 1, &scratch);
    try std.testing.expect(c.p_value > 0);
    try std.testing.expectEqual(Verdict.unchanged, c.verdict);
}

test "identical baseline current has no change" {
    const current = [_]f64{ 100, 101, 102 };
    const baseline_elapsed = [_]f64{ 100, 101, 102 };
    const baseline_iterations = [_]u64{ 1, 1, 1 };
    var scratch: [compareScratchLen(current.len, baseline_elapsed.len, 16)]f64 = undefined;

    const c = compare(&current, &baseline_elapsed, &baseline_iterations, .wall_time, 0.0, 0.05, 0.95, 16, 1, &scratch);
    try std.testing.expectEqual(@as(f64, 0), c.mean_change);
    try std.testing.expectEqual(@as(f64, 0), c.median_change);
    try std.testing.expectEqual(Verdict.unchanged, c.verdict);
}

test "allocator baseline comparison uses raw counter values" {
    const current = [_]f64{ 6, 6, 6 };
    const baseline_elapsed = [_]f64{ 6, 6, 6 };
    const baseline_iterations = [_]u64{ 3, 3, 3 };
    var scratch: [compareScratchLen(current.len, baseline_elapsed.len, 16)]f64 = undefined;

    const c = compare(&current, &baseline_elapsed, &baseline_iterations, .allocator_counters, 0.0, 0.05, 0.95, 16, 1, &scratch);
    try std.testing.expectEqual(@as(f64, 0), c.mean_change);
}

test "metric regression detects memory and allocator increases" {
    var iterations = [_]u64{1};
    var elapsed = [_]f64{1};
    var avg = [_]f64{1};
    var memory = [_]sampling.MemorySample{.{ .rss_bytes = 1, .peak_rss_bytes = 20, .pss_bytes = 1, .private_bytes = 1 }};
    var counters = [_]measure.AllocatorCounters{.{ .allocations = 20 }};
    const memory_samples: sampling.SampleSet = .{ .iterations = &iterations, .elapsed_ns = &elapsed, .avg_ns = &avg, .process_memory = &memory };
    const alloc_samples: sampling.SampleSet = .{ .iterations = &iterations, .elapsed_ns = &elapsed, .avg_ns = &avg, .allocator_counters = &counters };
    var old_peak = [_]f64{10};
    var old_allocs = [_]u64{10};
    try std.testing.expect(metricRegressed(memory_samples, .{ .sampling_mode = "flat", .iterations = &iterations, .elapsed_ns = &elapsed, .process_memory = .{ .peak_rss_bytes = &old_peak } }, .process_memory, 0.05));
    try std.testing.expect(metricRegressed(alloc_samples, .{ .sampling_mode = "flat", .iterations = &iterations, .elapsed_ns = &elapsed, .allocator_counters = .{ .allocations = &old_allocs } }, .allocator_counters, 0.05));
}

test "format zero is previous baseline format" {
    var parsed = try readSampleJson(std.testing.allocator,
        \\{"format":0,"sampling_mode":"flat","iterations":[1],"elapsed_ns":[2]}
    );
    defer parsed.deinit();
    try std.testing.expectEqual(@as(u32, 0), parsed.value.format);
}

test "sample json rejects invalid sample values" {
    try std.testing.expectError(error.InvalidBaseline, readSampleJson(std.testing.allocator,
        \\{"format":1,"sampling_mode":"flat","iterations":[0],"elapsed_ns":[2]}
    ));
}

test "sample json rejects partial metric arrays" {
    try std.testing.expectError(error.InvalidBaseline, readSampleJson(std.testing.allocator,
        \\{"format":1,"sampling_mode":"flat","iterations":[1],"elapsed_ns":[2],"allocator_counters":{"allocations":[1]}}
    ));
    try std.testing.expectError(error.InvalidBaseline, readSampleJson(std.testing.allocator,
        \\{"format":1,"sampling_mode":"flat","iterations":[1],"elapsed_ns":[2],"process_memory":{"rss_bytes":[1],"peak_rss_bytes":[2],"pss_bytes":[3]}}
    ));
}
