const std = @import("std");
const sampling = @import("sampling.zig");
const stats = @import("stats.zig");

pub const Estimates = struct {
    mean: stats.Estimate,
    median: stats.Estimate,
    std_dev: stats.Estimate,
    median_abs_dev: stats.Estimate,
    slope: ?stats.Estimate,
    r2: ?f64,
};

pub const OutlierSummary = struct {
    low_severe: u32 = 0,
    low_mild: u32 = 0,
    high_mild: u32 = 0,
    high_severe: u32 = 0,

    pub fn total(self: OutlierSummary) u32 {
        return self.low_severe + self.low_mild + self.high_mild + self.high_severe;
    }
};

pub const Result = struct {
    estimates: Estimates,
    outliers: OutlierSummary,
};

pub const Workspace = struct {
    allocator: std.mem.Allocator,
    sorted: []f64,
    bootstrap: []f64,
    mad_scratch: []f64,
    x: []f64,
    threads: []std.Thread,

    pub fn init(allocator: std.mem.Allocator, sample_size: usize, resamples: usize, jobs: usize) !Workspace {
        const sorted = try allocator.alloc(f64, sample_size);
        errdefer allocator.free(sorted);
        const bootstrap = try allocator.alloc(f64, resamples);
        errdefer allocator.free(bootstrap);
        const mad_scratch = try allocator.alloc(f64, sample_size);
        errdefer allocator.free(mad_scratch);
        const x = try allocator.alloc(f64, sample_size);
        errdefer allocator.free(x);
        const threads = try allocator.alloc(std.Thread, @max(jobs, 1));
        return .{
            .allocator = allocator,
            .sorted = sorted,
            .bootstrap = bootstrap,
            .mad_scratch = mad_scratch,
            .x = x,
            .threads = threads,
        };
    }

    pub fn deinit(self: Workspace) void {
        self.allocator.free(self.sorted);
        self.allocator.free(self.bootstrap);
        self.allocator.free(self.mad_scratch);
        self.allocator.free(self.x);
        self.allocator.free(self.threads);
    }
};

pub fn analyze(allocator: std.mem.Allocator, samples: sampling.SampleSet, config: sampling.Config) !Result {
    var workspace = try Workspace.init(allocator, samples.avg_ns.len, config.resamples, config.jobs);
    defer workspace.deinit();
    return analyzeWithWorkspace(&workspace, samples, config);
}

pub fn analyzeWithWorkspace(workspace: *Workspace, samples: sampling.SampleSet, config: sampling.Config) !Result {
    const n = samples.avg_ns.len;
    const resamples: usize = @intCast(config.resamples);
    std.debug.assert(workspace.sorted.len >= n);
    std.debug.assert(workspace.bootstrap.len >= resamples);
    std.debug.assert(workspace.mad_scratch.len >= n);
    std.debug.assert(workspace.x.len >= n);

    const sorted = workspace.sorted[0..n];
    @memcpy(sorted, samples.avg_ns);
    std.mem.sort(f64, sorted, {}, comptime std.sort.asc(f64));

    const bootstrap = workspace.bootstrap[0..resamples];
    try fillBootstrap(workspace.threads, samples.avg_ns, bootstrap, config.seed, config.jobs);
    std.mem.sort(f64, bootstrap, {}, comptime std.sort.asc(f64));

    const mean_est = stats.confidenceIntervalSorted(bootstrap, config.confidence_level);
    const median_est: stats.Estimate = .{
        .point = stats.medianSorted(sorted),
        .lower = stats.percentileSorted(sorted, (1.0 - config.confidence_level) / 2.0),
        .upper = stats.percentileSorted(sorted, 1.0 - (1.0 - config.confidence_level) / 2.0),
        .standard_error = stats.standardDeviation(sorted) / @sqrt(@as(f64, @floatFromInt(n))),
    };
    const std_dev = stats.standardDeviation(sorted);

    const mad_scratch = workspace.mad_scratch[0..n];
    const mad = stats.medianAbsoluteDeviation(sorted, mad_scratch);

    const x = workspace.x[0..n];
    for (samples.iterations, 0..) |iterations, i| x[i] = @floatFromInt(iterations);
    const regression = if (hasTimingRegression(config.measurement) and hasVaryingIterations(samples.iterations)) stats.linearRegression(x, samples.elapsed_ns) else null;

    return .{
        .estimates = .{
            .mean = mean_est,
            .median = median_est,
            .std_dev = scalarEstimate(std_dev),
            .median_abs_dev = scalarEstimate(mad),
            .slope = if (regression) |r| scalarEstimate(r.slope) else null,
            .r2 = if (regression) |r| r.r2 else null,
        },
        .outliers = countOutliers(samples.avg_ns, sorted),
    };
}

pub fn writeEstimatesJson(allocator: std.mem.Allocator, result: Result, unit: []const u8, seed: u64, samples: sampling.SampleSet, measurement: sampling.MeasurementKind) ![]u8 {
    try validateResult(result);
    var bytes = std.array_list.Managed(u8).init(allocator);
    errdefer bytes.deinit();
    try bytes.print(
        "{{\n  \"format\": 1,\n  \"unit\": \"{s}\",\n  \"seed\": {},\n  \"mean\": {d},\n  \"mean_ci\": [{d}, {d}],\n  \"median\": {d},\n  \"median_ci\": [{d}, {d}],\n  \"std_dev\": {d},\n  \"median_abs_dev\": {d},\n  \"slope\": ",
        .{
            unit,
            seed,
            result.estimates.mean.point,
            result.estimates.mean.lower,
            result.estimates.mean.upper,
            result.estimates.median.point,
            result.estimates.median.lower,
            result.estimates.median.upper,
            result.estimates.std_dev.point,
            result.estimates.median_abs_dev.point,
        },
    );
    if (result.estimates.slope) |slope| try bytes.print("{d}", .{slope.point}) else try bytes.appendSlice("null");
    try bytes.appendSlice(",\n  \"r2\": ");
    if (result.estimates.r2) |r2| try bytes.print("{d}", .{r2}) else try bytes.appendSlice("null");
    try bytes.print(
        ",\n  \"outliers\": {{\"low_severe\": {}, \"low_mild\": {}, \"high_mild\": {}, \"high_severe\": {}}}",
        .{
            result.outliers.low_severe,
            result.outliers.low_mild,
            result.outliers.high_mild,
            result.outliers.high_severe,
        },
    );
    if (measurement == .allocator_counters) try writeAllocatorMetricSummary(&bytes, samples);
    if (measurement == .process_memory) try writeMemoryMetricSummary(&bytes, samples);
    try bytes.appendSlice("\n}\n");
    return bytes.toOwnedSlice();
}

fn validateResult(result: Result) !void {
    try validateEstimate(result.estimates.mean);
    try validateEstimate(result.estimates.median);
    try validateEstimate(result.estimates.std_dev);
    try validateEstimate(result.estimates.median_abs_dev);
    if (result.estimates.slope) |slope| try validateEstimate(slope);
    if (result.estimates.r2) |r2| if (!std.math.isFinite(r2)) return error.InvalidAnalysisResult;
}

fn validateEstimate(estimate: @import("stats.zig").Estimate) !void {
    if (!std.math.isFinite(estimate.point) or
        !std.math.isFinite(estimate.lower) or
        !std.math.isFinite(estimate.upper) or
        !std.math.isFinite(estimate.standard_error)) return error.InvalidAnalysisResult;
}

fn writeAllocatorMetricSummary(bytes: *std.array_list.Managed(u8), samples: sampling.SampleSet) !void {
    try bytes.appendSlice(",\n  \"allocator_metrics\": {");
    try writeMetric(bytes, "allocations", meanAlloc(samples, .allocations), true);
    try writeMetric(bytes, "frees", meanAlloc(samples, .frees), false);
    try writeMetric(bytes, "resizes", meanAlloc(samples, .resizes), false);
    try writeMetric(bytes, "allocated_bytes", meanAlloc(samples, .allocated_bytes), false);
    try writeMetric(bytes, "freed_bytes", meanAlloc(samples, .freed_bytes), false);
    try writeMetric(bytes, "resized_bytes", meanAlloc(samples, .resized_bytes), false);
    try writeMetric(bytes, "live_bytes", meanAlloc(samples, .live_bytes), false);
    try writeMetric(bytes, "peak_live_bytes", meanAlloc(samples, .peak_live_bytes), false);
    try bytes.appendSlice("}");
}

fn writeMemoryMetricSummary(bytes: *std.array_list.Managed(u8), samples: sampling.SampleSet) !void {
    try bytes.appendSlice(",\n  \"memory_metrics\": {");
    try writeMetric(bytes, "rss_bytes", meanMemory(samples, .rss), true);
    try writeMetric(bytes, "peak_rss_bytes", meanMemory(samples, .peak_rss), false);
    try writeMetric(bytes, "pss_bytes", meanMemory(samples, .pss), false);
    try writeMetric(bytes, "private_bytes", meanMemory(samples, .private_bytes), false);
    try bytes.appendSlice("}");
}

fn writeMetric(bytes: *std.array_list.Managed(u8), name: []const u8, value: f64, first: bool) !void {
    if (!first) try bytes.appendSlice(",");
    try bytes.print("\n    \"{s}\": {{\"mean\": {d}}}", .{ name, value });
}

fn hasTimingRegression(measurement: sampling.MeasurementKind) bool {
    return measurement != .process_memory and measurement != .allocator_counters;
}

fn hasVaryingIterations(iterations: []const u64) bool {
    for (iterations[1..]) |value| if (value != iterations[0]) return true;
    return false;
}

const AllocField = enum { allocations, frees, resizes, allocated_bytes, freed_bytes, resized_bytes, live_bytes, peak_live_bytes };
const MemoryField = enum { rss, peak_rss, pss, private_bytes };

fn meanAlloc(samples: sampling.SampleSet, field: AllocField) f64 {
    var total: f64 = 0;
    for (samples.allocator_counters) |counter| {
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
        total += @floatFromInt(value);
    }
    return total / @as(f64, @floatFromInt(samples.allocator_counters.len));
}

fn meanMemory(samples: sampling.SampleSet, field: MemoryField) f64 {
    var total: f64 = 0;
    for (samples.process_memory) |memory| {
        total += switch (field) {
            .rss => memory.rss_bytes,
            .peak_rss => memory.peak_rss_bytes,
            .pss => memory.pss_bytes,
            .private_bytes => memory.private_bytes,
        };
    }
    return total / @as(f64, @floatFromInt(samples.process_memory.len));
}

fn fillBootstrap(threads: []std.Thread, values: []const f64, out: []f64, seed: u64, jobs: u32) !void {
    const worker_count = @min(@as(usize, @intCast(@max(jobs, 1))), out.len);
    if (worker_count <= 1) {
        stats.bootstrapMeanRange(values, out, seed, 0);
        return;
    }

    std.debug.assert(threads.len >= worker_count);
    var started: usize = 0;
    errdefer for (threads[0..started]) |thread| thread.join();

    for (threads[0..worker_count], 0..) |*thread, worker| {
        const start = out.len * worker / worker_count;
        const end = out.len * (worker + 1) / worker_count;
        thread.* = try std.Thread.spawn(.{}, stats.bootstrapMeanRange, .{ values, out[start..end], seed, start });
        started += 1;
    }
    for (threads[0..worker_count]) |thread| thread.join();
}

fn countOutliers(values: []const f64, sorted: []const f64) OutlierSummary {
    const fences = stats.tukeyFences(sorted);
    var out: OutlierSummary = .{};
    for (values) |value| {
        out.low_severe += @intFromBool(value < fences.low_severe);
        out.low_mild += @intFromBool(value >= fences.low_severe and value < fences.low_mild);
        out.high_mild += @intFromBool(value > fences.high_mild and value <= fences.high_severe);
        out.high_severe += @intFromBool(value > fences.high_severe);
    }
    return out;
}

fn scalarEstimate(value: f64) stats.Estimate {
    return .{ .point = value, .lower = value, .upper = value, .standard_error = 0 };
}

test "analysis computes estimates and outliers" {
    var iterations = [_]u64{ 1, 1, 1, 1, 1 };
    var elapsed = [_]f64{ 10, 11, 12, 13, 100 };
    var avg = [_]f64{ 10, 11, 12, 13, 100 };
    const samples: sampling.SampleSet = .{ .iterations = &iterations, .elapsed_ns = &elapsed, .avg_ns = &avg };
    const result = try analyze(std.testing.allocator, samples, .{ .resamples = 32, .seed = 1 });
    try std.testing.expect(result.estimates.mean.point > 10);
    try std.testing.expect(result.outliers.high_severe == 1);
}

test "branchless outlier counting matches classifier" {
    const values = [_]f64{ -100, 10, 11, 12, 13, 14, 100 };
    var expected: OutlierSummary = .{};
    const fences = stats.tukeyFences(&values);
    for (values) |value| switch (stats.classifyOutlier(value, fences)) {
        .low_severe => expected.low_severe += 1,
        .low_mild => expected.low_mild += 1,
        .normal => {},
        .high_mild => expected.high_mild += 1,
        .high_severe => expected.high_severe += 1,
    };
    try std.testing.expectEqual(expected, countOutliers(&values, &values));
}

test "analysis is deterministic across worker counts" {
    var iterations = [_]u64{ 1, 1, 1, 1, 1 };
    var elapsed = [_]f64{ 10, 11, 12, 13, 14 };
    var avg = [_]f64{ 10, 11, 12, 13, 14 };
    const samples: sampling.SampleSet = .{ .iterations = &iterations, .elapsed_ns = &elapsed, .avg_ns = &avg };
    const one = try analyze(std.testing.allocator, samples, .{ .resamples = 64, .seed = 1, .jobs = 1 });
    const many = try analyze(std.testing.allocator, samples, .{ .resamples = 64, .seed = 1, .jobs = 4 });
    try std.testing.expectEqual(one.estimates.mean.point, many.estimates.mean.point);
    try std.testing.expectEqual(one.estimates.mean.lower, many.estimates.mean.lower);
    try std.testing.expectEqual(one.estimates.mean.upper, many.estimates.mean.upper);
}

test "memory analysis omits timing regression" {
    var iterations = [_]u64{ 1, 1, 1, 1, 1 };
    var elapsed = [_]f64{ 0, 1, 0, 1, 0 };
    var avg = [_]f64{ 0, 1, 0, 1, 0 };
    const samples: sampling.SampleSet = .{ .iterations = &iterations, .elapsed_ns = &elapsed, .avg_ns = &avg };
    const result = try analyze(std.testing.allocator, samples, .{ .resamples = 32, .seed = 1, .measurement = .process_memory });
    try std.testing.expect(result.estimates.slope == null);
    try std.testing.expect(result.estimates.r2 == null);
}

test "flat timing analysis omits regression" {
    var iterations = [_]u64{ 3, 3, 3, 3, 3 };
    var elapsed = [_]f64{ 10, 11, 12, 13, 14 };
    var avg = [_]f64{ 10, 11, 12, 13, 14 };
    const samples: sampling.SampleSet = .{ .iterations = &iterations, .elapsed_ns = &elapsed, .avg_ns = &avg };
    const result = try analyze(std.testing.allocator, samples, .{ .resamples = 32, .seed = 1 });
    try std.testing.expect(result.estimates.slope == null);
    try std.testing.expect(result.estimates.r2 == null);
}

test "estimates json contains core fields" {
    const result: Result = .{
        .estimates = .{
            .mean = scalarEstimate(10),
            .median = scalarEstimate(9),
            .std_dev = scalarEstimate(1),
            .median_abs_dev = scalarEstimate(1),
            .slope = scalarEstimate(10),
            .r2 = 1,
        },
        .outliers = .{ .high_mild = 1 },
    };
    var iterations = [_]u64{1};
    var elapsed = [_]f64{10};
    var avg = [_]f64{10};
    const samples: sampling.SampleSet = .{ .iterations = &iterations, .elapsed_ns = &elapsed, .avg_ns = &avg };
    const bytes = try writeEstimatesJson(std.testing.allocator, result, "ns", 42, samples, .wall_time);
    defer std.testing.allocator.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"mean\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"median_ci\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"seed\": 42") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"outliers\"") != null);
}

test "estimates json rejects non-finite values" {
    const bad = scalarEstimate(std.math.inf(f64));
    const result: Result = .{
        .estimates = .{ .mean = bad, .median = scalarEstimate(1), .std_dev = scalarEstimate(1), .median_abs_dev = scalarEstimate(1), .slope = null, .r2 = null },
        .outliers = .{},
    };
    var iterations = [_]u64{1};
    var elapsed = [_]f64{1};
    var avg = [_]f64{1};
    const samples: sampling.SampleSet = .{ .iterations = &iterations, .elapsed_ns = &elapsed, .avg_ns = &avg };
    try std.testing.expectError(error.InvalidAnalysisResult, writeEstimatesJson(std.testing.allocator, result, "ns", 1, samples, .wall_time));
}

test "estimates json contains allocator metric summaries" {
    const estimate = scalarEstimate(1);
    const result: Result = .{
        .estimates = .{ .mean = estimate, .median = estimate, .std_dev = estimate, .median_abs_dev = estimate, .slope = null, .r2 = null },
        .outliers = .{},
    };
    var iterations = [_]u64{1};
    var elapsed = [_]f64{1};
    var avg = [_]f64{1};
    var counters = [_]@import("measurement.zig").AllocatorCounters{.{ .allocations = 2, .frees = 2, .peak_live_bytes = 16 }};
    const samples: sampling.SampleSet = .{ .iterations = &iterations, .elapsed_ns = &elapsed, .avg_ns = &avg, .allocator_counters = &counters };
    const bytes = try writeEstimatesJson(std.testing.allocator, result, "allocs", 1, samples, .allocator_counters);
    defer std.testing.allocator.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"allocator_metrics\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"peak_live_bytes\"") != null);
}

test "estimates json contains memory metric summaries" {
    const estimate = scalarEstimate(1);
    const result: Result = .{
        .estimates = .{ .mean = estimate, .median = estimate, .std_dev = estimate, .median_abs_dev = estimate, .slope = null, .r2 = null },
        .outliers = .{},
    };
    var iterations = [_]u64{1};
    var elapsed = [_]f64{1};
    var avg = [_]f64{1};
    var memory = [_]sampling.MemorySample{.{ .rss_bytes = 1, .peak_rss_bytes = 2, .pss_bytes = 3, .private_bytes = 4 }};
    const samples: sampling.SampleSet = .{ .iterations = &iterations, .elapsed_ns = &elapsed, .avg_ns = &avg, .process_memory = &memory };
    const bytes = try writeEstimatesJson(std.testing.allocator, result, "bytes", 1, samples, .process_memory);
    defer std.testing.allocator.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"memory_metrics\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"private_bytes\"") != null);
}
