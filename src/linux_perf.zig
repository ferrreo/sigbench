const std = @import("std");
const api = @import("api.zig");
const builtin = @import("builtin");
const measurement_types = @import("measurement_types.zig");

pub const LinuxPerf = struct {
    fd: std.os.linux.fd_t,
    main_thread_id: std.Thread.Id = 0,
    worker_fds: [max_worker_threads]std.os.linux.fd_t = undefined,
    worker_ids: [max_worker_threads]std.Thread.Id = undefined,
    worker_count: usize = 0,

    pub const max_worker_threads = 64;

    pub fn measurement(self: *LinuxPerf) measurement_types.Measurement {
        return .{
            .ctx = self,
            .start = start,
            .end = end,
            .zero = zero,
            .add = add,
            .toF64 = toF64,
            .format = format,
            .include_thread = includeThreadDriver,
            .cleanup = cleanupDriver,
        };
    }

    pub fn open() !LinuxPerf {
        if (builtin.os.tag != .linux) return error.UnsupportedMeasurement;
        return .{
            .fd = try openEvent(0),
            .main_thread_id = std.Thread.getCurrentId(),
        };
    }

    pub fn close(self: LinuxPerf) void {
        var mutable = self;
        _ = mutable.disableAll();
        mutable.clearWorkers();
        _ = std.os.linux.close(mutable.fd);
    }

    fn includeThread(self: *LinuxPerf, thread_id: std.Thread.Id) !void {
        if (builtin.os.tag != .linux) return error.UnsupportedMeasurement;
        errdefer self.clearWorkers();
        const main_thread_id = self.bindMainThread();
        const slot = try workerSlot(
            main_thread_id,
            self.worker_ids[0..self.worker_count],
            thread_id,
        ) orelse return;
        const pid = std.math.cast(std.posix.pid_t, thread_id) orelse {
            return error.InvalidPerfThreadId;
        };
        try validateThread(pid);
        self.worker_fds[slot] = try openEvent(pid);
        self.worker_ids[slot] = thread_id;
        self.worker_count += 1;
    }

    fn includeThreadDriver(ctx: *anyopaque, thread_id: std.Thread.Id) !void {
        const self: *LinuxPerf = @ptrCast(@alignCast(ctx));
        try self.includeThread(thread_id);
    }

    fn cleanupDriver(ctx: *anyopaque) void {
        const self: *LinuxPerf = @ptrCast(@alignCast(ctx));
        self.clearWorkers();
    }

    fn start(ctx: *anyopaque) !api.MeasurementValue {
        const self: *LinuxPerf = @ptrCast(@alignCast(ctx));
        errdefer self.clearWorkers();
        if (std.Thread.getCurrentId() != self.bindMainThread()) {
            return error.PerfMeasurementThreadChanged;
        }
        try self.ioctlAll(std.os.linux.PERF.EVENT_IOC.RESET);
        self.ioctlAll(std.os.linux.PERF.EVENT_IOC.ENABLE) catch |err| {
            _ = self.disableAll();
            return err;
        };
        return 0;
    }

    fn end(ctx: *anyopaque, started: api.MeasurementValue) !api.MeasurementValue {
        _ = started;
        const self: *LinuxPerf = @ptrCast(@alignCast(ctx));
        defer self.clearWorkers();
        if (self.disableAll()) |err| return err;
        if (std.Thread.getCurrentId() != self.bindMainThread()) {
            return error.PerfMeasurementThreadChanged;
        }
        var total = try readFd(self.fd);
        for (self.worker_fds[0..self.worker_count]) |fd| {
            total = try addCounter(total, try readFd(fd));
        }
        return total;
    }

    fn ioctlAll(self: *const LinuxPerf, request: u32) !void {
        try ioctlFd(self.fd, request);
        for (self.worker_fds[0..self.worker_count]) |fd| try ioctlFd(fd, request);
    }

    fn disableAll(self: *const LinuxPerf) ?anyerror {
        var first_error: ?anyerror = null;
        ioctlFd(self.fd, std.os.linux.PERF.EVENT_IOC.DISABLE) catch |err| {
            first_error = err;
        };
        for (self.worker_fds[0..self.worker_count]) |fd| {
            ioctlFd(fd, std.os.linux.PERF.EVENT_IOC.DISABLE) catch |err| {
                if (first_error == null) first_error = err;
            };
        }
        return first_error;
    }

    fn clearWorkers(self: *LinuxPerf) void {
        for (self.worker_fds[0..self.worker_count]) |fd| _ = std.os.linux.close(fd);
        self.worker_count = 0;
    }

    fn bindMainThread(self: *LinuxPerf) std.Thread.Id {
        if (self.main_thread_id == 0) self.main_thread_id = std.Thread.getCurrentId();
        return self.main_thread_id;
    }

    fn zero(_: *anyopaque) api.MeasurementValue {
        return 0;
    }

    fn add(_: *anyopaque, a: api.MeasurementValue, b: api.MeasurementValue) api.MeasurementValue {
        return a + b;
    }

    fn toF64(_: *anyopaque, value: api.MeasurementValue) f64 {
        return @floatFromInt(value);
    }

    fn format(_: *anyopaque, allocator: std.mem.Allocator, value: api.MeasurementValue) ![]u8 {
        return std.fmt.allocPrint(allocator, "{} events", .{value});
    }
};

fn workerSlot(
    main_thread_id: std.Thread.Id,
    worker_ids: []const std.Thread.Id,
    thread_id: std.Thread.Id,
) !?usize {
    if (thread_id == main_thread_id) return null;
    for (worker_ids) |existing| {
        if (existing == thread_id) return null;
    }
    if (worker_ids.len == LinuxPerf.max_worker_threads) return error.TooManyPerfThreads;
    return worker_ids.len;
}

fn addCounter(total: u64, value: u64) !u64 {
    const result = @addWithOverflow(total, value);
    if (result[1] != 0) return error.PerfCounterOverflow;
    return result[0];
}

fn validateThread(thread_id: std.posix.pid_t) !void {
    const rc = std.os.linux.tgkill(
        std.os.linux.getpid(),
        thread_id,
        @enumFromInt(0),
    );
    switch (std.os.linux.errno(rc)) {
        .SUCCESS => {},
        .SRCH => return error.PerfThreadNotInProcess,
        .PERM => return error.PerfThreadAccessDenied,
        else => return error.PerfThreadValidationFailed,
    }
}

fn openEvent(pid: std.posix.pid_t) !std.os.linux.fd_t {
    var attr: std.os.linux.perf_event_attr = .{
        .type = .HARDWARE,
        .config = @intFromEnum(std.os.linux.PERF.COUNT.HW.CPU_CYCLES),
    };
    attr.flags.disabled = true;
    attr.flags.exclude_kernel = true;
    attr.flags.exclude_hv = true;
    return std.posix.perf_event_open(
        &attr,
        pid,
        -1,
        -1,
        std.os.linux.PERF.FLAG.FD_CLOEXEC,
    );
}

fn readFd(fd: std.os.linux.fd_t) !u64 {
    var buffer: [@sizeOf(u64)]u8 = undefined;
    const rc = std.os.linux.read(fd, &buffer, buffer.len);
    const n = switch (std.os.linux.errno(rc)) {
        .SUCCESS => rc,
        else => return error.InvalidPerfRead,
    };
    if (n != buffer.len) return error.InvalidPerfRead;
    return std.mem.readInt(u64, &buffer, builtin.cpu.arch.endian());
}

fn ioctlFd(fd: std.os.linux.fd_t, request: u32) !void {
    const rc = std.os.linux.ioctl(fd, request, 0);
    switch (std.os.linux.errno(rc)) {
        .SUCCESS => {},
        else => return error.PerfIoctlFailed,
    }
}

test "linux perf opens where supported" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const compatible_literal: LinuxPerf = .{ .fd = -1 };
    try std.testing.expectEqual(@as(std.Thread.Id, 0), compatible_literal.main_thread_id);
    const const_perf = LinuxPerf.open() catch return error.SkipZigTest;
    try std.testing.expect(const_perf.fd >= 0);
    const_perf.close();
    var perf = try LinuxPerf.open();
    defer perf.close();
    const m = perf.measurement();
    const formatted = try m.format(m.ctx, std.testing.allocator, 3);
    defer std.testing.allocator.free(formatted);
    try std.testing.expectEqualStrings("3 events", formatted);
}

test "linux perf worker table deduplicates and is bounded" {
    var ids: [LinuxPerf.max_worker_threads]std.Thread.Id = undefined;
    for (&ids, 0..) |*id, index| id.* = @intCast(index + 2);
    try std.testing.expectEqual(null, try workerSlot(1, ids[0..3], 1));
    try std.testing.expectEqual(null, try workerSlot(1, ids[0..3], 3));
    try std.testing.expectEqual(@as(?usize, 3), try workerSlot(1, ids[0..3], 99));
    try std.testing.expectError(error.TooManyPerfThreads, workerSlot(1, &ids, 99));
    try std.testing.expectEqual(@as(u64, 7), try addCounter(3, 4));
    try std.testing.expectError(error.PerfCounterOverflow, addCounter(std.math.maxInt(u64), 1));
}

test "linux perf rejects a live thread from another process" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const io = std.testing.io;
    const argv = [_][]const u8{ "/bin/sleep", "30" };
    var child = std.process.spawn(io, .{
        .argv = &argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return error.SkipZigTest;
    defer child.kill(io);
    const child_thread_id: std.posix.pid_t = child.id.?;
    try std.testing.expectError(
        error.PerfThreadNotInProcess,
        validateThread(child_thread_id),
    );
}

test "linux perf rejects measurement thread changes and remains reusable" {
    if (builtin.os.tag != .linux or builtin.single_threaded) return error.SkipZigTest;
    const WrongStart = struct {
        perf: *LinuxPerf,
        result: ?anyerror = null,

        fn run(self: *@This()) void {
            const m = self.perf.measurement();
            _ = m.start(m.ctx) catch |err| {
                self.result = err;
                return;
            };
            self.result = error.ExpectedStartFailure;
        }
    };
    const WrongEnd = struct {
        perf: *LinuxPerf,
        started: api.MeasurementValue,
        result: ?anyerror = null,

        fn run(self: *@This()) void {
            const m = self.perf.measurement();
            _ = m.end(m.ctx, self.started) catch |err| {
                self.result = err;
                return;
            };
            self.result = error.ExpectedEndFailure;
        }
    };

    var perf = LinuxPerf.open() catch return error.SkipZigTest;
    defer perf.close();
    var wrong_start: WrongStart = .{ .perf = &perf };
    const start_thread = try std.Thread.spawn(.{}, WrongStart.run, .{&wrong_start});
    start_thread.join();
    try std.testing.expectEqual(error.PerfMeasurementThreadChanged, wrong_start.result.?);

    const m = perf.measurement();
    const started = try m.start(m.ctx);
    var wrong_end: WrongEnd = .{ .perf = &perf, .started = started };
    const end_thread = try std.Thread.spawn(.{}, WrongEnd.run, .{&wrong_end});
    end_thread.join();
    try std.testing.expectEqual(error.PerfMeasurementThreadChanged, wrong_end.result.?);
    try std.testing.expectEqual(@as(usize, 0), perf.worker_count);

    const reused_start = try m.start(m.ctx);
    _ = try m.end(m.ctx, reused_start);
}

test "linux perf aggregates registered live thread cycles" {
    if (builtin.os.tag != .linux or builtin.single_threaded) return error.SkipZigTest;
    const io = std.testing.io;
    const Worker = struct {
        ready: std.Io.Semaphore = .{},
        start_signal: std.Io.Semaphore = .{},
        done: std.Io.Semaphore = .{},
        thread_id: std.atomic.Value(std.Thread.Id) = .init(0),
        sink: u64 = 1,

        fn run(self: *@This()) void {
            self.thread_id.store(std.Thread.getCurrentId(), .release);
            self.ready.post(io);
            var round: usize = 0;
            while (round < 3) : (round += 1) {
                self.start_signal.waitUncancelable(io);
                const sink: *volatile u64 = &self.sink;
                var iteration: usize = 0;
                while (iteration < 5_000_000) : (iteration += 1) {
                    sink.* = sink.* *% 6_364_136_223_846_793_005 +% iteration;
                }
                self.done.post(io);
            }
        }
    };

    var perf = LinuxPerf.open() catch return error.SkipZigTest;
    defer perf.close();
    var worker: Worker = .{};
    const thread = try std.Thread.spawn(.{}, Worker.run, .{&worker});
    defer {
        worker.start_signal.post(io);
        worker.start_signal.post(io);
        worker.start_signal.post(io);
        thread.join();
    }
    worker.ready.waitUncancelable(io);
    const worker_id = worker.thread_id.load(.acquire);
    const m = perf.measurement();

    const baseline_start = try m.start(m.ctx);
    worker.start_signal.post(io);
    worker.done.waitUncancelable(io);
    const baseline = try m.end(m.ctx, baseline_start);

    try perf.includeThread(std.Thread.getCurrentId());
    try perf.includeThread(worker_id);
    try perf.includeThread(worker_id);
    try std.testing.expectEqual(@as(usize, 1), perf.worker_count);
    const included_start = try m.start(m.ctx);
    worker.start_signal.post(io);
    worker.done.waitUncancelable(io);
    const included = try m.end(m.ctx, included_start);
    try std.testing.expectEqual(@as(usize, 0), perf.worker_count);
    try std.testing.expect(included > baseline + 1_000_000);

    try perf.includeThread(worker_id);
    try std.testing.expectError(
        error.InvalidPerfThreadId,
        perf.includeThread(std.math.maxInt(std.Thread.Id)),
    );
    try std.testing.expectEqual(@as(usize, 0), perf.worker_count);
    try perf.includeThread(worker_id);
    const reused_start = try m.start(m.ctx);
    worker.start_signal.post(io);
    worker.done.waitUncancelable(io);
    const reused = try m.end(m.ctx, reused_start);
    try std.testing.expectEqual(@as(usize, 0), perf.worker_count);
    try std.testing.expect(reused > baseline + 1_000_000);
}
