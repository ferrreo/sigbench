const std = @import("std");
const builtin = @import("builtin");

pub fn pinCpu(index: u32) !void {
    return switch (builtin.os.tag) {
        .linux => pinCpuLinux(index),
        else => error.UnsupportedCpuPinning,
    };
}

pub fn setHighPriority() !void {
    return switch (builtin.os.tag) {
        .linux => setHighPriorityLinux(),
        else => error.UnsupportedPriority,
    };
}

fn pinCpuLinux(index: u32) !void {
    var set = cpuSet(index) orelse return error.InvalidCpu;
    try std.os.linux.sched_setaffinity(0, &set);
}

fn setHighPriorityLinux() !void {
    const rc = std.os.linux.syscall3(.setpriority, 0, 0, @as(usize, @bitCast(@as(isize, -5))));
    switch (std.os.linux.errno(rc)) {
        .SUCCESS => {},
        .PERM, .ACCES => return error.PriorityPermissionDenied,
        .INVAL => return error.InvalidPriority,
        else => return error.UnexpectedPriorityFailure,
    }
}

fn cpuSet(index: u32) ?std.os.linux.cpu_set_t {
    var set: std.os.linux.cpu_set_t = @splat(0);
    const bits = @bitSizeOf(usize);
    const word_index: usize = @intCast(index / bits);
    if (word_index >= set.len) return null;
    const bit_index: std.math.Log2Int(usize) = @intCast(index % bits);
    set[word_index] = @as(usize, 1) << bit_index;
    return set;
}

test "cpu set marks requested bit" {
    const set = cpuSet(3).?;
    try std.testing.expectEqual(@as(usize, 8), set[0]);
}

test "cpu set rejects impossible index" {
    try std.testing.expect(cpuSet(10_000) == null);
}
