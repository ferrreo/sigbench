const std = @import("std");
const analysis = @import("analysis.zig");
const sampling = @import("sampling.zig");

pub const Gate = struct {
    metric: Metric,
    op: Op,
    value: f64,
};

pub const Metric = enum {
    mean_ns,
    median_ns,
    std_dev_ns,
    rss,
    peak_rss,
    pss,
    private_bytes,
    alloc_count,
    alloc_frees,
    alloc_resizes,
    alloc_bytes,
    freed_bytes,
    resized_bytes,
    live_bytes,
    peak_live_bytes,
};

pub const Op = enum { lt, le, eq, ge, gt };

pub fn parse(raw: []const u8) !Gate {
    const ops = [_]struct { text: []const u8, op: Op }{
        .{ .text = "<=", .op = .le },
        .{ .text = ">=", .op = .ge },
        .{ .text = "==", .op = .eq },
        .{ .text = "<", .op = .lt },
        .{ .text = ">", .op = .gt },
    };
    inline for (ops) |entry| {
        if (std.mem.indexOf(u8, raw, entry.text)) |i| {
            return .{
                .metric = parseMetric(raw[0..i]) orelse return error.UnsupportedGateMetric,
                .op = entry.op,
                .value = try parseValue(raw[i + entry.text.len ..]),
            };
        }
    }
    return error.InvalidGate;
}

fn parseMetric(raw: []const u8) ?Metric {
    if (std.mem.eql(u8, raw, "mean_ns")) return .mean_ns;
    if (std.mem.eql(u8, raw, "median_ns")) return .median_ns;
    if (std.mem.eql(u8, raw, "std_dev_ns")) return .std_dev_ns;
    if (std.mem.eql(u8, raw, "rss")) return .rss;
    if (std.mem.eql(u8, raw, "peak_rss")) return .peak_rss;
    if (std.mem.eql(u8, raw, "pss")) return .pss;
    if (std.mem.eql(u8, raw, "private_bytes")) return .private_bytes;
    if (std.mem.eql(u8, raw, "alloc_count")) return .alloc_count;
    if (std.mem.eql(u8, raw, "alloc_frees")) return .alloc_frees;
    if (std.mem.eql(u8, raw, "alloc_resizes")) return .alloc_resizes;
    if (std.mem.eql(u8, raw, "alloc_bytes")) return .alloc_bytes;
    if (std.mem.eql(u8, raw, "freed_bytes")) return .freed_bytes;
    if (std.mem.eql(u8, raw, "resized_bytes")) return .resized_bytes;
    if (std.mem.eql(u8, raw, "live_bytes")) return .live_bytes;
    if (std.mem.eql(u8, raw, "peak_live_bytes")) return .peak_live_bytes;
    return null;
}

fn parseValue(raw: []const u8) !f64 {
    const units = [_]struct { suffix: []const u8, scale: f64 }{
        .{ .suffix = "KiB", .scale = 1024 },
        .{ .suffix = "MiB", .scale = 1024 * 1024 },
        .{ .suffix = "GiB", .scale = 1024 * 1024 * 1024 },
        .{ .suffix = "KB", .scale = 1000 },
        .{ .suffix = "MB", .scale = 1000 * 1000 },
        .{ .suffix = "GB", .scale = 1000 * 1000 * 1000 },
    };
    inline for (units) |unit| {
        if (std.mem.endsWith(u8, raw, unit.suffix)) {
            return try checkedValue(raw[0 .. raw.len - unit.suffix.len], unit.scale);
        }
    }
    return checkedValue(raw, 1);
}

fn checkedValue(raw: []const u8, scale: f64) !f64 {
    const value = (std.fmt.parseFloat(f64, raw) catch return error.InvalidGate) * scale;
    if (!std.math.isFinite(value)) return error.InvalidGate;
    return value;
}

pub fn apply(gates: []const Gate, result: analysis.Result, measurement: sampling.MeasurementKind, samples: sampling.SampleSet) !void {
    for (gates) |entry| {
        const actual = switch (entry.metric) {
            .mean_ns => result.estimates.mean.point,
            .median_ns => result.estimates.median.point,
            .std_dev_ns => result.estimates.std_dev.point,
            .rss => try memoryMean(measurement, samples, .rss),
            .peak_rss => try memoryMean(measurement, samples, .peak_rss),
            .pss => try memoryMean(measurement, samples, .pss),
            .private_bytes => try memoryMean(measurement, samples, .private_bytes),
            .alloc_count => try allocatorCounterMean(measurement, samples, .allocations),
            .alloc_frees => try allocatorCounterMean(measurement, samples, .frees),
            .alloc_resizes => try allocatorCounterMean(measurement, samples, .resizes),
            .alloc_bytes => try allocatorCounterMean(measurement, samples, .allocated_bytes),
            .freed_bytes => try allocatorCounterMean(measurement, samples, .freed_bytes),
            .resized_bytes => try allocatorCounterMean(measurement, samples, .resized_bytes),
            .live_bytes => try allocatorCounterMean(measurement, samples, .live_bytes),
            .peak_live_bytes => try allocatorCounterMean(measurement, samples, .peak_live_bytes),
        };
        const pass = switch (entry.op) {
            .lt => actual < entry.value,
            .le => actual <= entry.value,
            .eq => actual == entry.value,
            .ge => actual >= entry.value,
            .gt => actual > entry.value,
        };
        if (!pass) return error.GateFailed;
    }
}

const AllocCounterField = enum { allocations, frees, resizes, allocated_bytes, freed_bytes, resized_bytes, live_bytes, peak_live_bytes };

const MemoryField = enum { rss, peak_rss, pss, private_bytes };

fn memoryMean(measurement: sampling.MeasurementKind, samples: sampling.SampleSet, field: MemoryField) !f64 {
    if (measurement != .process_memory) return error.UnsupportedGateMetric;
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

fn allocatorCounterMean(measurement: sampling.MeasurementKind, samples: sampling.SampleSet, field: AllocCounterField) !f64 {
    if (measurement != .allocator_counters) return error.UnsupportedGateMetric;
    var total: f64 = 0;
    for (samples.allocator_counters) |counters| {
        const value = switch (field) {
            .allocations => counters.allocations,
            .frees => counters.frees,
            .resizes => counters.resizes,
            .allocated_bytes => counters.allocated_bytes,
            .freed_bytes => counters.freed_bytes,
            .resized_bytes => counters.resized_bytes,
            .live_bytes => counters.live_bytes,
            .peak_live_bytes => counters.peak_live_bytes,
        };
        total += @floatFromInt(value);
    }
    return total / @as(f64, @floatFromInt(samples.allocator_counters.len));
}

test "gate parser" {
    const mean_gate = try parse("mean_ns<=42");
    try std.testing.expectEqual(Metric.mean_ns, mean_gate.metric);
    try std.testing.expectEqual(Op.le, mean_gate.op);
    try std.testing.expectEqual(@as(f64, 42), mean_gate.value);
    const memory_gate = try parse("peak_rss<=64MiB");
    try std.testing.expectEqual(Metric.peak_rss, memory_gate.metric);
    try std.testing.expectEqual(@as(f64, 64 * 1024 * 1024), memory_gate.value);
    const pss_gate = try parse("pss>=0");
    try std.testing.expectEqual(Metric.pss, pss_gate.metric);
    const alloc_gate = try parse("alloc_count==0");
    try std.testing.expectEqual(Metric.alloc_count, alloc_gate.metric);
    const peak_gate = try parse("peak_live_bytes<=16");
    try std.testing.expectEqual(Metric.peak_live_bytes, peak_gate.metric);
    try std.testing.expectError(error.InvalidGate, parse("mean_ns<=nope"));
    try std.testing.expectError(error.InvalidGate, parse("mean_ns<=nan"));
}
