const std = @import("std");

const tsc_mask: u32 = 1 << 4;
const sse2_mask: u32 = 1 << 26;
const rdtscp_mask: u32 = 1 << 27;
const invariant_tsc_mask: u32 = 1 << 8;
const extended_features_leaf: u32 = 0x80000001;
const invariant_tsc_leaf: u32 = 0x80000007;

pub const Timestamp = struct {
    cycles: u64,
    auxiliary: u32,
};

const CpuidLeaf = struct {
    eax: u32,
    ebx: u32,
    ecx: u32,
    edx: u32,
};

pub fn ensureSupported() !void {
    const maximum_basic = cpuid(0, 0).eax;
    if (maximum_basic < 1) return error.UnsupportedMeasurement;

    const maximum_extended = cpuid(0x80000000, 0).eax;
    if (maximum_extended < invariant_tsc_leaf) return error.UnsupportedMeasurement;

    const basic = cpuid(1, 0);
    const extended = cpuid(extended_features_leaf, 0);
    const invariant = cpuid(invariant_tsc_leaf, 0);
    if (!featuresSupported(basic.edx, extended.edx, invariant.edx)) {
        return error.UnsupportedMeasurement;
    }
}

pub fn readStart() Timestamp {
    var low: u32 = undefined;
    var high: u32 = undefined;
    var auxiliary: u32 = undefined;
    asm volatile ("lfence\n\trdtscp\n\tlfence"
        : [low] "={eax}" (low),
          [high] "={edx}" (high),
          [auxiliary] "={ecx}" (auxiliary),
        :
        : .{ .memory = true });
    return .{ .cycles = combine(low, high), .auxiliary = auxiliary };
}

pub fn readEnd() Timestamp {
    var low: u32 = undefined;
    var high: u32 = undefined;
    var auxiliary: u32 = undefined;
    asm volatile ("rdtscp\n\tlfence"
        : [low] "={eax}" (low),
          [high] "={edx}" (high),
          [auxiliary] "={ecx}" (auxiliary),
        :
        : .{ .memory = true });
    return .{ .cycles = combine(low, high), .auxiliary = auxiliary };
}

pub fn elapsed(start: Timestamp, end: Timestamp) !u64 {
    if (start.auxiliary != end.auxiliary) return error.CpuMigrationDetected;
    return std.math.sub(u64, end.cycles, start.cycles) catch {
        return error.TimestampCounterWentBackwards;
    };
}

fn cpuid(leaf: u32, subleaf: u32) CpuidLeaf {
    var eax: u32 = undefined;
    var ebx: u32 = undefined;
    var ecx: u32 = undefined;
    var edx: u32 = undefined;
    asm volatile ("cpuid"
        : [eax] "={eax}" (eax),
          [ebx] "={ebx}" (ebx),
          [ecx] "={ecx}" (ecx),
          [edx] "={edx}" (edx),
        : [leaf] "{eax}" (leaf),
          [subleaf] "{ecx}" (subleaf),
    );
    return .{ .eax = eax, .ebx = ebx, .ecx = ecx, .edx = edx };
}

fn featuresSupported(basic: u32, extended: u32, invariant: u32) bool {
    const required_basic = tsc_mask | sse2_mask;
    return basic & required_basic == required_basic and
        extended & rdtscp_mask != 0 and invariant & invariant_tsc_mask != 0;
}

fn combine(low: u32, high: u32) u64 {
    return (@as(u64, high) << 32) | low;
}

test "cycle feature predicate requires tsc lfence rdtscp and invariant tsc" {
    const Case = struct { basic: u32, extended: u32, invariant: u32, supported: bool };
    const all_basic = tsc_mask | sse2_mask;
    const cases = [_]Case{
        .{
            .basic = all_basic,
            .extended = rdtscp_mask,
            .invariant = invariant_tsc_mask,
            .supported = true,
        },
        .{
            .basic = sse2_mask,
            .extended = rdtscp_mask,
            .invariant = invariant_tsc_mask,
            .supported = false,
        },
        .{
            .basic = tsc_mask,
            .extended = rdtscp_mask,
            .invariant = invariant_tsc_mask,
            .supported = false,
        },
        .{ .basic = all_basic, .extended = 0, .invariant = invariant_tsc_mask, .supported = false },
        .{ .basic = all_basic, .extended = rdtscp_mask, .invariant = 0, .supported = false },
    };
    for (cases) |case| {
        try std.testing.expectEqual(
            case.supported,
            featuresSupported(case.basic, case.extended, case.invariant),
        );
    }
}

test "timestamp halves combine without truncation" {
    try std.testing.expectEqual(@as(u64, 0x89abcdef01234567), combine(0x01234567, 0x89abcdef));
}

test "timestamp elapsed rejects migration and backwards counters" {
    const start: Timestamp = .{ .cycles = 100, .auxiliary = 7 };
    try std.testing.expectEqual(
        @as(u64, 23),
        try elapsed(start, .{ .cycles = 123, .auxiliary = 7 }),
    );
    try std.testing.expectError(
        error.CpuMigrationDetected,
        elapsed(start, .{ .cycles = 123, .auxiliary = 8 }),
    );
    try std.testing.expectError(
        error.TimestampCounterWentBackwards,
        elapsed(start, .{ .cycles = 99, .auxiliary = 7 }),
    );
}
