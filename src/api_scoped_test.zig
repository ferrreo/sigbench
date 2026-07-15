const std = @import("std");
const api = @import("api.zig");

const Bencher = api.Bencher;
const MeasurementDriver = api.MeasurementDriver;
const MeasurementScope = api.MeasurementScope;

test "measurement driver scopes built-in timing loops" {
    const S = struct {
        var context: u8 = 0;
        var now: u64 = 0;
        var starts: u64 = 0;
        var ends: u64 = 0;
        var zeroes: u64 = 0;
        var adds: u64 = 0;

        fn reset() void {
            now = 0;
            starts = 0;
            ends = 0;
            zeroes = 0;
            adds = 0;
        }

        fn driver() MeasurementDriver {
            return .{ .ctx = &context, .start = start, .end = end, .zero = zero, .add = add };
        }

        fn start(_: *anyopaque) !u64 {
            starts += 1;
            return now;
        }

        fn end(_: *anyopaque, started: u64) !u64 {
            ends += 1;
            return now - started;
        }

        fn zero(_: *anyopaque) u64 {
            zeroes += 1;
            return 0;
        }

        fn add(_: *anyopaque, a: u64, b: u64) u64 {
            adds += 1;
            return a + b;
        }

        fn routine() void {
            now += 7;
        }

        fn execute(_: *anyopaque, routine_fn: *const fn () void) void {
            routine_fn();
        }

        fn setup() u8 {
            now += 100;
            return 0;
        }

        fn batchRoutine(_: *u8) void {
            routine();
        }
    };

    S.reset();
    var iter_b: Bencher = .{
        .iterations = 3,
        .external_timing = true,
        .measurement_driver = S.driver(),
    };
    S.now += 100;
    iter_b.iter(S.routine);
    S.now += 200;
    try std.testing.expectEqual(@as(u64, 21), iter_b.elapsed_ns);
    try std.testing.expectEqual(@as(u64, 1), S.starts);
    try std.testing.expectEqual(@as(u64, 1), S.ends);

    S.reset();
    var async_b: Bencher = .{
        .iterations = 3,
        .external_timing = true,
        .measurement_driver = S.driver(),
    };
    S.now += 100;
    async_b.iterAsync(.{ .ctx = &S.context, .run = S.execute }, S.routine);
    S.now += 200;
    try std.testing.expectEqual(@as(u64, 21), async_b.elapsed_ns);
    try std.testing.expectEqual(@as(u64, 1), S.starts);
    try std.testing.expectEqual(@as(u64, 1), S.ends);

    S.reset();
    var batch_b: Bencher = .{
        .iterations = 3,
        .external_timing = true,
        .measurement_driver = S.driver(),
    };
    batch_b.iterBatch(u8, S.setup, S.batchRoutine, .per_iteration);
    try std.testing.expectEqual(@as(u64, 21), batch_b.elapsed_ns);
    try std.testing.expectEqual(@as(u64, 3), S.starts);
    try std.testing.expectEqual(@as(u64, 3), S.ends);
    try std.testing.expectEqual(@as(u64, 1), S.zeroes);
    try std.testing.expectEqual(@as(u64, 3), S.adds);
}

test "batch teardown stays outside external measurement and accumulates batches" {
    const S = struct {
        var context: u8 = 0;
        var now: u64 = 0;
        var starts: u64 = 0;
        var ends: u64 = 0;
        var zeroes: u64 = 0;
        var adds: u64 = 0;
        var teardowns: u64 = 0;

        fn setup() u8 {
            now += 100;
            return 0;
        }

        fn routine(_: *u8) void {
            now += 7;
        }

        fn teardown(_: *u8) void {
            now += 200;
            teardowns += 1;
        }

        fn start(_: *anyopaque) !u64 {
            starts += 1;
            return now;
        }

        fn end(_: *anyopaque, started: u64) !u64 {
            ends += 1;
            return now - started;
        }

        fn zero(_: *anyopaque) u64 {
            zeroes += 1;
            return 0;
        }

        fn add(_: *anyopaque, a: u64, b: u64) u64 {
            adds += 1;
            return a + b;
        }
    };
    var b: Bencher = .{
        .iterations = 5,
        .external_timing = true,
        .measurement_driver = .{
            .ctx = &S.context,
            .start = S.start,
            .end = S.end,
            .zero = S.zero,
            .add = S.add,
        },
    };
    b.iterBatchWithTeardown(
        u8,
        S.setup,
        S.routine,
        S.teardown,
        .{ .num_batches = 2 },
    );
    try std.testing.expectEqual(@as(u64, 35), b.elapsed_ns);
    try std.testing.expectEqual(@as(u64, 635), S.now);
    try std.testing.expectEqual(@as(u64, 2), S.starts);
    try std.testing.expectEqual(@as(u64, 2), S.ends);
    try std.testing.expectEqual(@as(u64, 1), S.zeroes);
    try std.testing.expectEqual(@as(u64, 2), S.adds);
    try std.testing.expectEqual(@as(u64, 2), S.teardowns);
    try std.testing.expect(b.measured);
}

test "batch teardown runs after measurement start and end failures" {
    const StartFailure = struct {
        var context: u8 = 0;
        var setups: u64 = 0;
        var routines: u64 = 0;
        var teardowns: u64 = 0;
        var ends: u64 = 0;

        fn setup() u8 {
            setups += 1;
            return 0;
        }

        fn routine(_: *u8) void {
            routines += 1;
        }

        fn teardown(_: *u8) void {
            teardowns += 1;
        }

        fn start(_: *anyopaque) !u64 {
            return error.StartFailure;
        }

        fn end(_: *anyopaque, _: u64) !u64 {
            ends += 1;
            return 0;
        }

        fn zero(_: *anyopaque) u64 {
            return 0;
        }

        fn add(_: *anyopaque, a: u64, b: u64) u64 {
            return a + b;
        }
    };
    var start_failure: Bencher = .{
        .iterations = 3,
        .external_timing = true,
        .measurement_driver = .{
            .ctx = &StartFailure.context,
            .start = StartFailure.start,
            .end = StartFailure.end,
            .zero = StartFailure.zero,
            .add = StartFailure.add,
        },
    };
    start_failure.iterBatchWithTeardown(
        u8,
        StartFailure.setup,
        StartFailure.routine,
        StartFailure.teardown,
        .per_iteration,
    );
    try std.testing.expectEqual(error.StartFailure, start_failure.timing_error.?);
    try std.testing.expectEqual(@as(u64, 1), StartFailure.setups);
    try std.testing.expectEqual(@as(u64, 0), StartFailure.routines);
    try std.testing.expectEqual(@as(u64, 1), StartFailure.teardowns);
    try std.testing.expectEqual(@as(u64, 0), StartFailure.ends);
    try std.testing.expect(!start_failure.measured);

    const EndFailure = struct {
        var context: u8 = 0;
        var setups: u64 = 0;
        var routines: u64 = 0;
        var teardowns: u64 = 0;
        var starts: u64 = 0;

        fn setup() u8 {
            setups += 1;
            return 0;
        }

        fn routine(_: *u8) void {
            routines += 1;
        }

        fn teardown(_: *u8) void {
            teardowns += 1;
        }

        fn start(_: *anyopaque) !u64 {
            starts += 1;
            return 0;
        }

        fn end(_: *anyopaque, _: u64) !u64 {
            return error.EndFailure;
        }

        fn zero(_: *anyopaque) u64 {
            return 0;
        }

        fn add(_: *anyopaque, a: u64, b: u64) u64 {
            return a + b;
        }
    };
    var end_failure: Bencher = .{
        .iterations = 3,
        .external_timing = true,
        .measurement_driver = .{
            .ctx = &EndFailure.context,
            .start = EndFailure.start,
            .end = EndFailure.end,
            .zero = EndFailure.zero,
            .add = EndFailure.add,
        },
    };
    end_failure.iterBatchWithTeardown(
        u8,
        EndFailure.setup,
        EndFailure.routine,
        EndFailure.teardown,
        .per_iteration,
    );
    try std.testing.expectEqual(error.EndFailure, end_failure.timing_error.?);
    try std.testing.expectEqual(@as(u64, 1), EndFailure.setups);
    try std.testing.expectEqual(@as(u64, 1), EndFailure.routines);
    try std.testing.expectEqual(@as(u64, 1), EndFailure.teardowns);
    try std.testing.expectEqual(@as(u64, 1), EndFailure.starts);
    try std.testing.expect(!end_failure.measured);
}

test "scoped custom timing excludes setup and teardown" {
    const S = struct {
        var context: u8 = 0;
        var now: u64 = 0;
        var starts: u64 = 0;
        var ends: u64 = 0;

        fn start(_: *anyopaque) !u64 {
            starts += 1;
            return now;
        }

        fn end(_: *anyopaque, started: u64) !u64 {
            ends += 1;
            return now - started;
        }

        fn zero(_: *anyopaque) u64 {
            return 0;
        }

        fn add(_: *anyopaque, a: u64, b: u64) u64 {
            return a + b;
        }

        fn run(iterations: u64, scope: *MeasurementScope) !void {
            now += 100;
            try scope.start();
            var iteration: u64 = 0;
            while (iteration < iterations) : (iteration += 1) now += 7;
            try scope.stop();
            now += 200;
        }
    };
    var b: Bencher = .{
        .iterations = 3,
        .external_timing = true,
        .measurement_driver = .{
            .ctx = &S.context,
            .start = S.start,
            .end = S.end,
            .zero = S.zero,
            .add = S.add,
        },
    };
    try b.iterCustomScoped(S.run);
    try std.testing.expectEqual(@as(u64, 21), b.elapsed_ns);
    try std.testing.expectEqual(@as(u64, 1), S.starts);
    try std.testing.expectEqual(@as(u64, 1), S.ends);
}

test "scoped custom timing registers threads before start" {
    const S = struct {
        var context: u8 = 0;
        var included: [2]std.Thread.Id = undefined;
        var included_count: usize = 0;
        var cleanups: usize = 0;

        fn includeThread(_: *anyopaque, thread_id: std.Thread.Id) !void {
            included[included_count] = thread_id;
            included_count += 1;
        }

        fn start(_: *anyopaque) !u64 {
            return 1;
        }

        fn end(_: *anyopaque, _: u64) !u64 {
            return 2;
        }

        fn zero(_: *anyopaque) u64 {
            return 0;
        }

        fn add(_: *anyopaque, a: u64, b: u64) u64 {
            return a + b;
        }

        fn cleanup(_: *anyopaque) void {
            cleanups += 1;
        }

        fn run(_: u64, scope: *MeasurementScope) !void {
            try scope.includeThread(11);
            try scope.includeThread(22);
            try scope.start();
            try scope.stop();
        }
    };
    var b: Bencher = .{ .measurement_driver = .{
        .ctx = &S.context,
        .start = S.start,
        .end = S.end,
        .zero = S.zero,
        .add = S.add,
        .include_thread = S.includeThread,
        .cleanup = S.cleanup,
    } };
    try b.iterCustomScoped(S.run);
    try std.testing.expectEqualSlices(
        std.Thread.Id,
        &.{ 11, 22 },
        S.included[0..S.included_count],
    );
    try std.testing.expectEqual(@as(usize, 1), S.cleanups);
}

test "scoped custom timing thread hook is optional" {
    const S = struct {
        fn run(_: u64, scope: *MeasurementScope) !void {
            try scope.includeThread(std.Thread.getCurrentId());
            try scope.start();
            try scope.stop();
        }
    };
    var b: Bencher = .{};
    try b.iterCustomScoped(S.run);
    try std.testing.expect(b.measured);
}

const CleanupDriver = struct {
    var context: u8 = 0;
    var registered = false;
    var cleanups: usize = 0;
    var starts: usize = 0;
    var ends: usize = 0;

    fn reset() void {
        registered = false;
        cleanups = 0;
        starts = 0;
        ends = 0;
    }

    fn driver() MeasurementDriver {
        return .{
            .ctx = &context,
            .start = start,
            .end = end,
            .zero = zero,
            .add = add,
            .include_thread = includeThread,
            .cleanup = cleanup,
        };
    }

    fn includeThread(_: *anyopaque, _: std.Thread.Id) !void {
        if (registered) return error.StaleThreadRegistration;
        registered = true;
    }

    fn cleanup(_: *anyopaque) void {
        registered = false;
        cleanups += 1;
    }

    fn start(_: *anyopaque) !u64 {
        starts += 1;
        return 0;
    }

    fn end(_: *anyopaque, _: u64) !u64 {
        ends += 1;
        return 1;
    }

    fn zero(_: *anyopaque) u64 {
        return 0;
    }

    fn add(_: *anyopaque, a: u64, b: u64) u64 {
        return a + b;
    }

    fn callbackFailure(_: u64, scope: *MeasurementScope) !void {
        try scope.includeThread(11);
        return error.CallbackFailure;
    }

    fn missingStart(_: u64, scope: *MeasurementScope) !void {
        try scope.includeThread(11);
    }

    fn valid(_: u64, scope: *MeasurementScope) !void {
        try scope.includeThread(11);
        try scope.start();
        try scope.stop();
    }
};

test "scoped custom timing cleans pre-start registrations and permits reuse" {
    CleanupDriver.reset();
    var callback_failure: Bencher = .{ .measurement_driver = CleanupDriver.driver() };
    try std.testing.expectError(
        error.CallbackFailure,
        callback_failure.iterCustomScoped(CleanupDriver.callbackFailure),
    );
    try std.testing.expect(!CleanupDriver.registered);
    try std.testing.expectEqual(@as(usize, 1), CleanupDriver.cleanups);

    var missing_start: Bencher = .{ .measurement_driver = CleanupDriver.driver() };
    try std.testing.expectError(
        error.MeasurementScopeNotStarted,
        missing_start.iterCustomScoped(CleanupDriver.missingStart),
    );
    try std.testing.expect(!CleanupDriver.registered);
    try std.testing.expectEqual(@as(usize, 2), CleanupDriver.cleanups);

    var valid: Bencher = .{ .measurement_driver = CleanupDriver.driver() };
    try valid.iterCustomScoped(CleanupDriver.valid);
    try std.testing.expect(!CleanupDriver.registered);
    try std.testing.expectEqual(@as(usize, 3), CleanupDriver.cleanups);
    try std.testing.expectEqual(@as(usize, 1), CleanupDriver.starts);
    try std.testing.expectEqual(@as(usize, 1), CleanupDriver.ends);
}

test "scoped custom timing rejects thread registration after start" {
    const S = struct {
        var context: u8 = 0;
        var ends: u64 = 0;

        fn start(_: *anyopaque) !u64 {
            return 0;
        }

        fn end(_: *anyopaque, _: u64) !u64 {
            ends += 1;
            return 1;
        }

        fn zero(_: *anyopaque) u64 {
            return 0;
        }

        fn add(_: *anyopaque, a: u64, b: u64) u64 {
            return a + b;
        }

        fn run(_: u64, scope: *MeasurementScope) !void {
            try scope.start();
            scope.includeThread(11) catch {};
            try scope.stop();
        }
    };
    var b: Bencher = .{ .measurement_driver = .{
        .ctx = &S.context,
        .start = S.start,
        .end = S.end,
        .zero = S.zero,
        .add = S.add,
    } };
    try std.testing.expectError(
        error.MeasurementScopeThreadIncludedAfterStart,
        b.iterCustomScoped(S.run),
    );
    try std.testing.expectEqual(error.MeasurementScopeThreadIncludedAfterStart, b.timing_error.?);
    try std.testing.expectEqual(@as(u64, 1), S.ends);
}

test "scoped custom timing persists caught thread hook errors" {
    const S = struct {
        var context: u8 = 0;
        var includes: u64 = 0;
        var starts: u64 = 0;

        fn includeThread(_: *anyopaque, _: std.Thread.Id) !void {
            includes += 1;
            return error.ThreadRegistrationFailure;
        }

        fn start(_: *anyopaque) !u64 {
            starts += 1;
            return 0;
        }

        fn end(_: *anyopaque, _: u64) !u64 {
            return 1;
        }

        fn zero(_: *anyopaque) u64 {
            return 0;
        }

        fn add(_: *anyopaque, a: u64, b: u64) u64 {
            return a + b;
        }

        fn run(_: u64, scope: *MeasurementScope) !void {
            scope.includeThread(11) catch {};
            scope.includeThread(22) catch {};
            scope.start() catch {};
            scope.stop() catch {};
            return error.CallbackFailure;
        }
    };
    var b: Bencher = .{ .measurement_driver = .{
        .ctx = &S.context,
        .start = S.start,
        .end = S.end,
        .zero = S.zero,
        .add = S.add,
        .include_thread = S.includeThread,
    } };
    try std.testing.expectError(error.ThreadRegistrationFailure, b.iterCustomScoped(S.run));
    try std.testing.expectEqual(error.ThreadRegistrationFailure, b.timing_error.?);
    try std.testing.expectEqual(@as(u64, 1), S.includes);
    try std.testing.expectEqual(@as(u64, 0), S.starts);
}

test "scoped custom timing rejects missing and repeated boundaries" {
    const S = struct {
        var context: u8 = 0;
        var starts: u64 = 0;
        var ends: u64 = 0;

        fn driver() MeasurementDriver {
            return .{ .ctx = &context, .start = start, .end = end, .zero = zero, .add = add };
        }

        fn start(_: *anyopaque) !u64 {
            starts += 1;
            return 0;
        }

        fn end(_: *anyopaque, _: u64) !u64 {
            ends += 1;
            return 1;
        }

        fn zero(_: *anyopaque) u64 {
            return 0;
        }

        fn add(_: *anyopaque, a: u64, b: u64) u64 {
            return a + b;
        }

        fn missingStart(_: u64, _: *MeasurementScope) !void {}

        fn missingStop(_: u64, scope: *MeasurementScope) !void {
            try scope.start();
        }

        fn doubleStart(_: u64, scope: *MeasurementScope) !void {
            try scope.start();
            scope.start() catch {};
            try scope.stop();
        }

        fn doubleStop(_: u64, scope: *MeasurementScope) !void {
            try scope.start();
            try scope.stop();
            scope.stop() catch {};
        }

        fn stopBeforeStart(_: u64, scope: *MeasurementScope) !void {
            scope.stop() catch {};
            try scope.start();
            try scope.stop();
        }
    };

    var missing_start: Bencher = .{ .measurement_driver = S.driver() };
    try std.testing.expectError(
        error.MeasurementScopeNotStarted,
        missing_start.iterCustomScoped(S.missingStart),
    );
    try std.testing.expectEqual(error.MeasurementScopeNotStarted, missing_start.timing_error.?);

    S.ends = 0;
    var missing_stop: Bencher = .{ .measurement_driver = S.driver() };
    try std.testing.expectError(
        error.MeasurementScopeNotStopped,
        missing_stop.iterCustomScoped(S.missingStop),
    );
    try std.testing.expectEqual(@as(u64, 1), S.ends);

    var double_start: Bencher = .{ .measurement_driver = S.driver() };
    try std.testing.expectError(
        error.MeasurementScopeStartedTwice,
        double_start.iterCustomScoped(S.doubleStart),
    );

    var double_stop: Bencher = .{ .measurement_driver = S.driver() };
    try std.testing.expectError(
        error.MeasurementScopeStoppedTwice,
        double_stop.iterCustomScoped(S.doubleStop),
    );

    var stop_before_start: Bencher = .{ .measurement_driver = S.driver() };
    try std.testing.expectError(
        error.MeasurementScopeStoppedBeforeStart,
        stop_before_start.iterCustomScoped(S.stopBeforeStart),
    );
}

test "scoped custom timing closes active driver on callback error" {
    const S = struct {
        var context: u8 = 0;
        var ends: u64 = 0;

        fn start(_: *anyopaque) !u64 {
            return 0;
        }

        fn end(_: *anyopaque, _: u64) !u64 {
            ends += 1;
            return error.CloseFailure;
        }

        fn zero(_: *anyopaque) u64 {
            return 0;
        }

        fn add(_: *anyopaque, a: u64, b: u64) u64 {
            return a + b;
        }

        fn fail(_: u64, scope: *MeasurementScope) !void {
            try scope.start();
            return error.CallbackFailure;
        }
    };
    var b: Bencher = .{
        .measurement_driver = .{
            .ctx = &S.context,
            .start = S.start,
            .end = S.end,
            .zero = S.zero,
            .add = S.add,
        },
    };
    try std.testing.expectError(error.CallbackFailure, b.iterCustomScoped(S.fail));
    try std.testing.expectEqual(@as(u64, 1), S.ends);
    try std.testing.expectEqual(error.CallbackFailure, b.timing_error.?);
}

test "scoped custom timing does not repeat failed driver stop" {
    const S = struct {
        var context: u8 = 0;
        var ends: u64 = 0;

        fn start(_: *anyopaque) !u64 {
            return 0;
        }

        fn end(_: *anyopaque, _: u64) !u64 {
            ends += 1;
            return error.StopFailure;
        }

        fn zero(_: *anyopaque) u64 {
            return 0;
        }

        fn add(_: *anyopaque, a: u64, b: u64) u64 {
            return a + b;
        }

        fn run(_: u64, scope: *MeasurementScope) !void {
            try scope.start();
            try scope.stop();
        }
    };
    var b: Bencher = .{
        .measurement_driver = .{
            .ctx = &S.context,
            .start = S.start,
            .end = S.end,
            .zero = S.zero,
            .add = S.add,
        },
    };
    try std.testing.expectError(error.StopFailure, b.iterCustomScoped(S.run));
    try std.testing.expectEqual(@as(u64, 1), S.ends);
    try std.testing.expectEqual(error.StopFailure, b.timing_error.?);
}

test "legacy custom timing remains wall-clock compatible" {
    const S = struct {
        fn run(iterations: u64) u64 {
            return iterations * 11;
        }
    };
    var b: Bencher = .{ .iterations = 17 };
    b.iterCustom(S.run);
    try std.testing.expectEqual(@as(u64, 187), b.elapsed_ns);
    try std.testing.expect(b.timing_error == null);

    b.finishCustom(23);
    try std.testing.expectEqual(@as(u64, 23), b.elapsed_ns);
    try std.testing.expect(b.timing_error == null);

    var external: Bencher = .{ .external_timing = true };
    external.finishCustom(23);
    try std.testing.expectEqual(
        error.ExternalMeasurementRequiresScopedCustomTiming,
        external.timing_error.?,
    );
}
