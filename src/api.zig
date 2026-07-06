const std = @import("std");
const builtin = @import("builtin");

pub const BenchFn = *const fn (*Bencher) anyerror!void;

pub const BenchmarkCase = struct {
    id: []const u8,
    name: []const u8,
    run: BenchFn,
    throughput: ?Throughput = null,
};

pub const BenchmarkGroup = struct {
    id: []const u8,
    name: []const u8,
    cases: []const BenchmarkCase,
};

pub const BatchPolicy = union(enum) {
    small_input,
    large_input,
    per_iteration,
    num_batches: u64,
    num_iterations: u64,
};

pub const AsyncExecutor = struct {
    ctx: *anyopaque,
    run: *const fn (*anyopaque, *const fn () void) void,
};

pub const Profiler = struct {
    ctx: ?*anyopaque = null,
    startFn: ?*const fn (?*anyopaque, []const u8, []const u8) void = null,
    stopFn: ?*const fn (?*anyopaque, []const u8, []const u8) void = null,

    pub fn start(self: Profiler, benchmark_id: []const u8, profile_dir: []const u8) void {
        if (self.startFn) |f| f(self.ctx, benchmark_id, profile_dir);
    }

    pub fn stop(self: Profiler, benchmark_id: []const u8, profile_dir: []const u8) void {
        if (self.stopFn) |f| f(self.ctx, benchmark_id, profile_dir);
    }
};

pub const Bencher = struct {
    iterations: u64 = 1,
    elapsed_ns: u64 = 0,
    allocator: ?std.mem.Allocator = null,
    used_async: bool = false,
    measured: bool = false,
    external_timing: bool = false,

    pub fn benchmarkAllocator(self: *Bencher) std.mem.Allocator {
        return self.allocator.?;
    }

    pub fn iter(self: *Bencher, routine: *const fn () void) void {
        const start = if (self.external_timing) 0 else nowNs();
        var i: u64 = 0;
        while (i < self.iterations) : (i += 1) routine();
        self.elapsed_ns = if (self.external_timing) 0 else nowNs() - start;
        self.measured = true;
    }

    pub fn iterCustom(self: *Bencher, routine: *const fn (u64) u64) void {
        self.elapsed_ns = routine(self.iterations);
        self.measured = true;
    }

    pub fn finishCustom(self: *Bencher, elapsed_ns: u64) void {
        self.elapsed_ns = elapsed_ns;
        self.measured = true;
    }

    pub fn iterAsync(self: *Bencher, executor: AsyncExecutor, routine: *const fn () void) void {
        self.used_async = true;
        const start = if (self.external_timing) 0 else nowNs();
        var i: u64 = 0;
        while (i < self.iterations) : (i += 1) executor.run(executor.ctx, routine);
        self.elapsed_ns = if (self.external_timing) 0 else nowNs() - start;
        self.measured = true;
    }

    pub fn iterBatch(
        self: *Bencher,
        comptime T: type,
        setup: *const fn () T,
        routine: *const fn (*T) void,
        policy: BatchPolicy,
    ) void {
        const batches = batchCount(self.iterations, policy);
        var b: u64 = 0;
        var done: u64 = 0;
        var total_elapsed: u64 = 0;
        while (b < batches and done < self.iterations) : (b += 1) {
            var input = setup();
            const batches_left = batches - b;
            const remaining = self.iterations - done;
            const this_batch = 1 + (remaining - 1) / batches_left;
            const start = if (self.external_timing) 0 else nowNs();
            var i: u64 = 0;
            while (i < this_batch and done < self.iterations) : ({
                i += 1;
                done += 1;
            }) routine(&input);
            if (!self.external_timing) total_elapsed += nowNs() - start;
        }
        self.elapsed_ns = total_elapsed;
        self.measured = true;
    }
};

pub const RuntimeRegistry = struct {
    allocator: std.mem.Allocator,
    groups: std.array_list.Managed(BenchmarkGroup),

    pub fn init(allocator: std.mem.Allocator) RuntimeRegistry {
        return .{
            .allocator = allocator,
            .groups = .init(allocator),
        };
    }

    pub fn deinit(self: RuntimeRegistry) void {
        self.groups.deinit();
    }

    pub fn addGroup(self: *RuntimeRegistry, g: BenchmarkGroup) !void {
        try self.groups.append(g);
    }

    pub fn items(self: RuntimeRegistry) []const BenchmarkGroup {
        return self.groups.items;
    }
};

pub const Parameter = struct {
    id: []const u8,
    label: []const u8,
};

pub const Throughput = union(enum) {
    bits: u64,
    bytes: u64,
    elements: u64,
};

pub fn bench(comptime name: []const u8, comptime run_fn: anytype) BenchmarkCase {
    return benchWithId(name, name, run_fn);
}

pub fn benchWithId(comptime id: []const u8, comptime name: []const u8, comptime run_fn: anytype) BenchmarkCase {
    return .{ .id = id, .name = name, .run = wrapper(run_fn).run };
}

pub fn benchWithThroughput(comptime id: []const u8, comptime name: []const u8, throughput_value: Throughput, comptime run_fn: anytype) BenchmarkCase {
    return .{ .id = id, .name = name, .run = wrapper(run_fn).run, .throughput = throughput_value };
}

pub fn group(comptime name: []const u8, comptime cases: anytype) BenchmarkGroup {
    return .{ .id = name, .name = name, .cases = &cases };
}

pub fn groupWithId(comptime id: []const u8, comptime name: []const u8, comptime cases: anytype) BenchmarkGroup {
    return .{ .id = id, .name = name, .cases = &cases };
}

pub fn parameter(comptime id: []const u8, comptime label: []const u8) Parameter {
    return .{ .id = id, .label = label };
}

pub fn parameterCase(
    comptime base_id: []const u8,
    comptime base_name: []const u8,
    comptime param: Parameter,
    comptime run_fn: anytype,
) BenchmarkCase {
    return .{
        .id = base_id ++ "-" ++ param.id,
        .name = base_name ++ " " ++ param.label,
        .run = wrapper(run_fn).run,
    };
}

pub fn parameterCaseWithValue(
    comptime T: type,
    comptime base_id: []const u8,
    comptime base_name: []const u8,
    comptime param: Parameter,
    comptime value: T,
    comptime run_fn: anytype,
) BenchmarkCase {
    return .{
        .id = base_id ++ "-" ++ param.id,
        .name = base_name ++ " " ++ param.label,
        .run = wrapperParam(T, value, run_fn).run,
    };
}

fn wrapper(comptime run_fn: anytype) type {
    const Fn = @typeInfo(@TypeOf(run_fn)).@"fn";
    const Return = Fn.return_type orelse @compileError("benchmark function must return void or !void");
    return struct {
        fn run(b: *Bencher) anyerror!void {
            switch (@typeInfo(Return)) {
                .void => {
                    run_fn(b);
                    return;
                },
                .error_union => |info| {
                    if (info.payload != void) @compileError("benchmark function must return void or !void");
                    try run_fn(b);
                },
                else => @compileError("benchmark function must return void or !void"),
            }
        }
    };
}

fn wrapperParam(comptime T: type, comptime value: T, comptime run_fn: anytype) type {
    return struct {
        fn run(b: *Bencher) anyerror!void {
            const returned = run_fn(b, value);
            switch (@typeInfo(@TypeOf(returned))) {
                .void => return,
                .error_union => |info| {
                    if (info.payload != void) @compileError("benchmark function must return void or !void");
                    try returned;
                },
                else => @compileError("benchmark function must return void or !void"),
            }
        }
    };
}

fn batchCount(iterations: u64, policy: BatchPolicy) u64 {
    return switch (policy) {
        .small_input => @min(iterations, 10),
        .large_input => @min(iterations, 1000),
        .per_iteration => iterations,
        .num_batches => |n| @max(@as(u64, 1), @min(iterations, n)),
        .num_iterations => |n| if (iterations == 0) 0 else 1 + (iterations - 1) / @max(@as(u64, 1), n),
    };
}

pub fn nowNs() u64 {
    if (builtin.os.tag == .windows) return windowsNowNs();
    var ts: std.posix.timespec = undefined;
    switch (std.posix.errno(std.posix.system.clock_gettime(.MONOTONIC, &ts))) {
        .SUCCESS => {},
        else => return 0,
    }
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

fn windowsNowNs() u64 {
    var counter: std.os.windows.LARGE_INTEGER = 0;
    var frequency: std.os.windows.LARGE_INTEGER = 0;
    if (!std.os.windows.ntdll.RtlQueryPerformanceCounter(&counter).toBool()) return 0;
    if (!std.os.windows.ntdll.RtlQueryPerformanceFrequency(&frequency).toBool() or frequency <= 0) return 0;
    return @intFromFloat(@as(f64, @floatFromInt(counter)) * @as(f64, @floatFromInt(std.time.ns_per_s)) / @as(f64, @floatFromInt(frequency)));
}

test "iter runs routine exactly requested iterations" {
    const S = struct {
        var n: u64 = 0;
        fn run() void {
            n += 1;
        }
    };
    var b: Bencher = .{ .iterations = 17 };
    b.iter(S.run);
    try std.testing.expectEqual(@as(u64, 17), S.n);
    try std.testing.expect(b.elapsed_ns > 0);
}

test "external timing runs routine without wall-clock reads" {
    const S = struct {
        var n: u64 = 0;
        fn run() void {
            n += 1;
        }
    };
    var b: Bencher = .{ .iterations = 17, .external_timing = true };
    b.iter(S.run);
    try std.testing.expectEqual(@as(u64, 17), S.n);
    try std.testing.expect(b.measured);
    try std.testing.expectEqual(@as(u64, 0), b.elapsed_ns);
}

test "iterBatch runs all iterations across uneven batches" {
    const S = struct {
        var setups: u64 = 0;
        var routines: u64 = 0;
        fn setup() u8 {
            setups += 1;
            return 0;
        }
        fn routine(_: *u8) void {
            routines += 1;
        }
    };
    var b: Bencher = .{ .iterations = 17 };
    b.iterBatch(u8, S.setup, S.routine, .small_input);
    try std.testing.expectEqual(@as(u64, 10), S.setups);
    try std.testing.expectEqual(@as(u64, 17), S.routines);
    try std.testing.expect(b.elapsed_ns > 0);
}

test "iterBatch num_iterations caps batch size" {
    const S = struct {
        var setups: u64 = 0;
        var largest: u64 = 0;
        var current: u64 = 0;
        fn setup() u8 {
            largest = @max(largest, current);
            current = 0;
            setups += 1;
            return 0;
        }
        fn routine(_: *u8) void {
            current += 1;
        }
    };
    var b: Bencher = .{ .iterations = 10 };
    b.iterBatch(u8, S.setup, S.routine, .{ .num_iterations = 3 });
    S.largest = @max(S.largest, S.current);
    try std.testing.expectEqual(@as(u64, 4), S.setups);
    try std.testing.expect(S.largest <= 3);
}

test "iterAsync routes through executor" {
    const S = struct {
        var routine_calls: u64 = 0;
        var executor_calls: u64 = 0;
        fn routine() void {
            routine_calls += 1;
        }
        fn run(ctx: *anyopaque, routine_fn: *const fn () void) void {
            _ = ctx;
            executor_calls += 1;
            routine_fn();
        }
    };
    var b: Bencher = .{ .iterations = 3 };
    var ctx: u8 = 0;
    b.iterAsync(.{ .ctx = &ctx, .run = S.run }, S.routine);
    try std.testing.expectEqual(@as(u64, 3), S.executor_calls);
    try std.testing.expectEqual(@as(u64, 3), S.routine_calls);
}

test "benchmark case can return errors" {
    const S = struct {
        fn fail(_: *Bencher) !void {
            return error.IntentionalFailure;
        }
    };
    const c = comptime benchWithId("fail", "fail", S.fail);
    var b: Bencher = .{};
    try std.testing.expectError(error.IntentionalFailure, c.run(&b));
}

test "benchmark case can carry throughput" {
    const S = struct {
        fn noop(_: *Bencher) void {}
    };
    const c = comptime benchWithThroughput("copy", "copy", .{ .bytes = 1024 }, S.noop);
    try std.testing.expectEqual(@as(u64, 1024), c.throughput.?.bytes);
    const bit_case = comptime benchWithThroughput("encode", "encode", .{ .bits = 8 }, S.noop);
    try std.testing.expectEqual(@as(u64, 8), bit_case.throughput.?.bits);
}

test "group can separate stable id from display name" {
    const S = struct {
        fn noop(_: *Bencher) void {}
    };
    const c = comptime benchWithId("fib-20", "fib 20", S.noop);
    const g = comptime groupWithId("fib", "Fibonacci", .{c});
    try std.testing.expectEqualStrings("fib", g.id);
    try std.testing.expectEqualStrings("Fibonacci", g.name);
    try std.testing.expectEqualStrings("fib-20", g.cases[0].id);
    try std.testing.expectEqualStrings("fib 20", g.cases[0].name);
}

test "runtime registration preserves comptime IDs" {
    const S = struct {
        fn noop(_: *Bencher) void {}
    };
    const c = comptime benchWithId("fib-20", "fib 20", S.noop);
    const g = comptime groupWithId("fib", "Fibonacci", .{c});
    var registry = RuntimeRegistry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.addGroup(g);
    try std.testing.expectEqualStrings(g.id, registry.items()[0].id);
    try std.testing.expectEqualStrings(g.cases[0].id, registry.items()[0].cases[0].id);
}

test "profiler hooks fire" {
    const S = struct {
        var starts: u32 = 0;
        var stops: u32 = 0;
        fn start(_: ?*anyopaque, benchmark_id: []const u8, profile_dir: []const u8) void {
            if (std.mem.eql(u8, benchmark_id, "bench") and std.mem.eql(u8, profile_dir, "dir")) starts += 1;
        }
        fn stop(_: ?*anyopaque, benchmark_id: []const u8, profile_dir: []const u8) void {
            if (std.mem.eql(u8, benchmark_id, "bench") and std.mem.eql(u8, profile_dir, "dir")) stops += 1;
        }
    };
    const profiler: Profiler = .{ .startFn = S.start, .stopFn = S.stop };
    profiler.start("bench", "dir");
    profiler.stop("bench", "dir");
    try std.testing.expectEqual(@as(u32, 1), S.starts);
    try std.testing.expectEqual(@as(u32, 1), S.stops);
}

test "parameter case keeps explicit stable id" {
    const S = struct {
        fn noop(_: *Bencher) void {}
    };
    const p = comptime parameter("size-1024", "1 KiB");
    const c = comptime parameterCase("encode", "encode", p, S.noop);
    try std.testing.expectEqualStrings("encode-size-1024", c.id);
    try std.testing.expectEqualStrings("encode 1 KiB", c.name);
}

test "parameter case can pass typed value" {
    const S = struct {
        var seen: u32 = 0;
        fn run(_: *Bencher, value: u32) void {
            seen = value;
        }
    };
    const c = comptime parameterCaseWithValue(u32, "encode", "encode", parameter("size-1024", "1 KiB"), 1024, S.run);
    var b: Bencher = .{};
    try c.run(&b);
    try std.testing.expectEqualStrings("encode-size-1024", c.id);
    try std.testing.expectEqual(@as(u32, 1024), S.seen);
}
