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
