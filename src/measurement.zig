const std = @import("std");
const api = @import("api.zig");
const builtin = @import("builtin");
const x86_cycles = @import("x86_cycles.zig");
const linux_perf = @import("linux_perf.zig");

pub const MeasurementValue = api.MeasurementValue;
pub const Measurement = @import("measurement_types.zig").Measurement;
pub const LinuxPerf = linux_perf.LinuxPerf;

pub fn unitLabel(kind: anytype) []const u8 {
    return switch (kind) {
        .wall_time => "ns",
        .cpu_cycles => "cycles",
        .linux_perf => "events",
        .macos_kperf => "events",
        .process_memory => "bytes",
        .allocator_counters => "allocs",
    };
}

pub const WallClock = struct {
    pub fn measurement(self: *WallClock) Measurement {
        return .{
            .ctx = self,
            .start = start,
            .end = end,
            .zero = zero,
            .add = add,
            .toF64 = toF64,
            .format = format,
        };
    }

    fn start(ctx: *anyopaque) !MeasurementValue {
        _ = ctx;
        return api.nowNs();
    }

    fn end(ctx: *anyopaque, started: MeasurementValue) !MeasurementValue {
        _ = ctx;
        return api.nowNs() - started;
    }

    fn zero(ctx: *anyopaque) MeasurementValue {
        _ = ctx;
        return 0;
    }

    fn add(ctx: *anyopaque, a: MeasurementValue, b: MeasurementValue) MeasurementValue {
        _ = ctx;
        return a + b;
    }

    fn toF64(ctx: *anyopaque, value: MeasurementValue) f64 {
        _ = ctx;
        return @floatFromInt(value);
    }

    fn format(ctx: *anyopaque, allocator: std.mem.Allocator, value: MeasurementValue) ![]u8 {
        _ = ctx;
        return std.fmt.allocPrint(allocator, "{} ns", .{value});
    }
};

pub const CpuCycles = struct {
    x86_support_checked: bool = false,
    x86_measurement_started: bool = false,
    x86_start_auxiliary: u32 = 0,

    pub fn measurement(self: *CpuCycles) Measurement {
        return .{
            .ctx = self,
            .start = start,
            .end = end,
            .zero = zero,
            .add = add,
            .toF64 = toF64,
            .format = format,
        };
    }

    pub fn read() !u64 {
        var cycles: CpuCycles = .{};
        return cycles.readStart();
    }

    fn start(ctx: *anyopaque) !MeasurementValue {
        const self: *CpuCycles = @ptrCast(@alignCast(ctx));
        return self.readStart();
    }

    fn end(ctx: *anyopaque, started: MeasurementValue) !MeasurementValue {
        const self: *CpuCycles = @ptrCast(@alignCast(ctx));
        if (builtin.os.tag == .windows) {
            const finished = try readWindowsThreadCycles();
            return finished - started;
        }
        return switch (builtin.cpu.arch) {
            .x86, .x86_64 => self.endX86(started),
            else => error.UnsupportedMeasurement,
        };
    }

    fn readStart(self: *CpuCycles) !u64 {
        if (builtin.os.tag == .windows) return readWindowsThreadCycles();
        return switch (builtin.cpu.arch) {
            .x86, .x86_64 => {
                if (!self.x86_support_checked) {
                    try x86_cycles.ensureSupported();
                    self.x86_support_checked = true;
                }
                const timestamp = x86_cycles.readStart();
                self.x86_measurement_started = true;
                self.x86_start_auxiliary = timestamp.auxiliary;
                return timestamp.cycles;
            },
            else => error.UnsupportedMeasurement,
        };
    }

    fn endX86(self: *CpuCycles, started: u64) !u64 {
        if (!self.x86_support_checked or !self.x86_measurement_started) {
            return error.UnsupportedMeasurement;
        }
        const started_timestamp: x86_cycles.Timestamp = .{
            .cycles = started,
            .auxiliary = self.x86_start_auxiliary,
        };
        const finished = x86_cycles.readEnd();
        self.x86_measurement_started = false;
        return x86_cycles.elapsed(started_timestamp, finished);
    }

    fn zero(ctx: *anyopaque) MeasurementValue {
        _ = ctx;
        return 0;
    }

    fn add(ctx: *anyopaque, a: MeasurementValue, b: MeasurementValue) MeasurementValue {
        _ = ctx;
        return a + b;
    }

    fn toF64(ctx: *anyopaque, value: MeasurementValue) f64 {
        _ = ctx;
        return @floatFromInt(value);
    }

    fn format(ctx: *anyopaque, allocator: std.mem.Allocator, value: MeasurementValue) ![]u8 {
        _ = ctx;
        return std.fmt.allocPrint(allocator, "{} cycles", .{value});
    }
};

pub const MacosKperf = if (builtin.os.tag.isDarwin()) struct {
    db: ?*KpepDb,
    config: ?*KpepConfig,
    counter_index: usize,
    counter_count: u32,

    const KPC_MAX_COUNTERS = 32;
    const KPC_CLASS_CONFIGURABLE_MASK: u32 = 1 << 1;
    const KpepDb = opaque {};
    const KpepConfig = opaque {};
    const KpepEvent = opaque {};

    pub fn measurement(self: *MacosKperf) Measurement {
        return .{
            .ctx = self,
            .start = start,
            .end = end,
            .zero = zero,
            .add = add,
            .toF64 = toF64,
            .format = format,
        };
    }

    pub fn open() !MacosKperf {
        var db: ?*KpepDb = null;
        try kpep(kpep_db_create(null, &db));
        errdefer kpep_db_free(db);

        var config: ?*KpepConfig = null;
        try kpep(kpep_config_create(db, &config));
        errdefer kpep_config_free(config);

        try kpep(kpep_config_force_counters(config));
        var event = try findEvent(db);
        try kpep(kpep_config_add_event(config, &event, 0, null));

        var classes: u32 = 0;
        var reg_count: usize = 0;
        var counter_map: [KPC_MAX_COUNTERS]usize = undefined;
        var regs: [KPC_MAX_COUNTERS]u64 = undefined;
        try kpep(kpep_config_kpc_classes(config, &classes));
        try kpep(kpep_config_kpc_count(config, &reg_count));
        try kpep(kpep_config_kpc_map(config, &counter_map, @sizeOf(@TypeOf(counter_map))));
        try kpep(kpep_config_kpc(config, &regs, @sizeOf(@TypeOf(regs))));

        if (kpc_force_all_ctrs_set(1) != 0) return error.KperfPermissionDenied;
        errdefer _ = kpc_force_all_ctrs_set(0);
        if ((classes & KPC_CLASS_CONFIGURABLE_MASK) != 0 and reg_count != 0) {
            if (kpc_set_config(classes, &regs) != 0) return error.KperfSetupFailed;
        }
        const counter_count = kpc_get_counter_count(classes);
        if (counter_count == 0) return error.KperfSetupFailed;
        if (counter_map[0] >= counter_count) return error.KperfSetupFailed;
        if (kpc_set_counting(classes) != 0) return error.KperfSetupFailed;
        errdefer _ = kpc_set_counting(0);
        if (kpc_set_thread_counting(classes) != 0) return error.KperfSetupFailed;

        return .{
            .db = db,
            .config = config,
            .counter_index = counter_map[0],
            .counter_count = counter_count,
        };
    }

    pub fn close(self: MacosKperf) void {
        _ = kpc_set_thread_counting(0);
        _ = kpc_set_counting(0);
        _ = kpc_force_all_ctrs_set(0);
        kpep_config_free(self.config);
        kpep_db_free(self.db);
    }

    fn start(ctx: *anyopaque) !MeasurementValue {
        const self: *MacosKperf = @ptrCast(@alignCast(ctx));
        return try self.read();
    }

    fn end(ctx: *anyopaque, started: MeasurementValue) !MeasurementValue {
        const self: *MacosKperf = @ptrCast(@alignCast(ctx));
        return (try self.read()) - started;
    }

    fn zero(ctx: *anyopaque) MeasurementValue {
        _ = ctx;
        return 0;
    }

    fn add(ctx: *anyopaque, a: MeasurementValue, b: MeasurementValue) MeasurementValue {
        _ = ctx;
        return a + b;
    }

    fn toF64(ctx: *anyopaque, value: MeasurementValue) f64 {
        _ = ctx;
        return @floatFromInt(value);
    }

    fn format(ctx: *anyopaque, allocator: std.mem.Allocator, value: MeasurementValue) ![]u8 {
        _ = ctx;
        return std.fmt.allocPrint(allocator, "{} events", .{value});
    }

    fn read(self: MacosKperf) !u64 {
        var counters: [KPC_MAX_COUNTERS]u64 = undefined;
        if (kpc_get_thread_counters(0, self.counter_count, &counters) != 0) return error.KperfReadFailed;
        return counters[self.counter_index];
    }

    fn findEvent(db: ?*KpepDb) !?*KpepEvent {
        const names = [_][*:0]const u8{
            "FIXED_CYCLES",
            "CPU_CLK_UNHALTED.THREAD",
            "CPU_CLK_UNHALTED.CORE",
        };
        for (names) |name| {
            var event: ?*KpepEvent = null;
            if (kpep_db_event(db, name, &event) == 0 and event != null) return event;
        }
        return error.KperfEventNotFound;
    }

    fn kpep(code: c_int) !void {
        if (code != 0) return error.KperfSetupFailed;
    }

    extern "kperf" fn kpc_set_counting(classes: u32) c_int;
    extern "kperf" fn kpc_set_thread_counting(classes: u32) c_int;
    extern "kperf" fn kpc_get_counter_count(classes: u32) u32;
    extern "kperf" fn kpc_get_thread_counters(tid: u32, buf_count: u32, buf: *[KPC_MAX_COUNTERS]u64) c_int;
    extern "kperf" fn kpc_force_all_ctrs_set(value: c_int) c_int;
    extern "kperf" fn kpc_set_config(classes: u32, config: *[KPC_MAX_COUNTERS]u64) c_int;
    extern "kperfdata" fn kpep_db_create(name: ?[*:0]const u8, db: *?*KpepDb) c_int;
    extern "kperfdata" fn kpep_db_free(db: ?*KpepDb) void;
    extern "kperfdata" fn kpep_db_event(db: ?*KpepDb, name: [*:0]const u8, event: *?*KpepEvent) c_int;
    extern "kperfdata" fn kpep_config_create(db: ?*KpepDb, config: *?*KpepConfig) c_int;
    extern "kperfdata" fn kpep_config_free(config: ?*KpepConfig) void;
    extern "kperfdata" fn kpep_config_force_counters(config: ?*KpepConfig) c_int;
    extern "kperfdata" fn kpep_config_add_event(config: ?*KpepConfig, event: *?*KpepEvent, flags: u32, err: ?*u32) c_int;
    extern "kperfdata" fn kpep_config_kpc_classes(config: ?*KpepConfig, classes: *u32) c_int;
    extern "kperfdata" fn kpep_config_kpc_count(config: ?*KpepConfig, count: *usize) c_int;
    extern "kperfdata" fn kpep_config_kpc_map(config: ?*KpepConfig, map: *[KPC_MAX_COUNTERS]usize, bytes: usize) c_int;
    extern "kperfdata" fn kpep_config_kpc(config: ?*KpepConfig, regs: *[KPC_MAX_COUNTERS]u64, bytes: usize) c_int;
} else struct {
    pub fn measurement(self: *MacosKperf) Measurement {
        return .{
            .ctx = self,
            .start = start,
            .end = end,
            .zero = zero,
            .add = add,
            .toF64 = toF64,
            .format = format,
        };
    }

    pub fn open() !MacosKperf {
        return error.UnsupportedMeasurement;
    }

    pub fn close(self: MacosKperf) void {
        _ = self;
    }

    fn start(ctx: *anyopaque) !MeasurementValue {
        _ = ctx;
        return error.UnsupportedMeasurement;
    }

    fn end(ctx: *anyopaque, started: MeasurementValue) !MeasurementValue {
        _ = ctx;
        _ = started;
        return error.UnsupportedMeasurement;
    }

    fn zero(ctx: *anyopaque) MeasurementValue {
        _ = ctx;
        return 0;
    }

    fn add(ctx: *anyopaque, a: MeasurementValue, b: MeasurementValue) MeasurementValue {
        _ = ctx;
        return a + b;
    }

    fn toF64(ctx: *anyopaque, value: MeasurementValue) f64 {
        _ = ctx;
        return @floatFromInt(value);
    }

    fn format(ctx: *anyopaque, allocator: std.mem.Allocator, value: MeasurementValue) ![]u8 {
        _ = ctx;
        return std.fmt.allocPrint(allocator, "{} events", .{value});
    }
};

pub fn preflight(kind: anytype, allocator: std.mem.Allocator, io: std.Io) !void {
    switch (kind) {
        .wall_time => {},
        .cpu_cycles => _ = try CpuCycles.read(),
        .linux_perf => {
            var perf = try LinuxPerf.open();
            perf.close();
        },
        .macos_kperf => {
            const kperf = try MacosKperf.open();
            kperf.close();
        },
        .process_memory => _ = try readProcessMemory(allocator, io),
        .allocator_counters => {},
    }
}

fn readWindowsThreadCycles() !u64 {
    const windows = std.os.windows;
    var cycles: u64 = 0;
    if (!QueryThreadCycleTime(windows.GetCurrentThread(), &cycles).toBool()) return error.UnsupportedMeasurement;
    return cycles;
}

extern "kernel32" fn QueryThreadCycleTime(thread: std.os.windows.HANDLE, cycles: *u64) callconv(.winapi) std.os.windows.BOOL;

pub const AllocatorCounters = struct {
    allocations: u64 = 0,
    frees: u64 = 0,
    resizes: u64 = 0,
    allocated_bytes: u64 = 0,
    freed_bytes: u64 = 0,
    resized_bytes: u64 = 0,
    live_bytes: u64 = 0,
    peak_live_bytes: u64 = 0,
};

pub const CountingAllocator = struct {
    child: std.mem.Allocator,
    counters: AllocatorCounters = .{},

    pub fn init(child: std.mem.Allocator) CountingAllocator {
        return .{ .child = child };
    }

    pub fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn recordAlloc(self: *CountingAllocator, len: usize) void {
        self.counters.allocations += 1;
        self.counters.allocated_bytes += len;
        self.counters.live_bytes += len;
        self.counters.peak_live_bytes = @max(self.counters.peak_live_bytes, self.counters.live_bytes);
    }

    fn recordFree(self: *CountingAllocator, len: usize) void {
        self.counters.frees += 1;
        self.counters.freed_bytes += len;
        self.counters.live_bytes -= len;
    }

    fn recordResize(self: *CountingAllocator, old_len: usize, new_len: usize) void {
        self.counters.resizes += 1;
        self.counters.resized_bytes += if (new_len > old_len) new_len - old_len else old_len - new_len;
        if (new_len > old_len) {
            self.counters.live_bytes += new_len - old_len;
        } else {
            self.counters.live_bytes -= old_len - new_len;
        }
        self.counters.peak_live_bytes = @max(self.counters.peak_live_bytes, self.counters.live_bytes);
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const ptr = self.child.rawAlloc(len, alignment, ret_addr) orelse return null;
        self.recordAlloc(len);
        return ptr;
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        if (!self.child.rawResize(memory, alignment, new_len, ret_addr)) return false;
        self.recordResize(memory.len, new_len);
        return true;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const ptr = self.child.rawRemap(memory, alignment, new_len, ret_addr) orelse return null;
        self.recordResize(memory.len, new_len);
        return ptr;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.child.rawFree(memory, alignment, ret_addr);
        self.recordFree(memory.len);
    }

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };
};

pub const ProcessMemory = struct {
    rss_bytes: u64,
    peak_rss_bytes: u64,
    pss_bytes: u64,
    private_bytes: u64,
};

pub fn readProcessMemory(allocator: std.mem.Allocator, io: std.Io) !ProcessMemory {
    return switch (builtin.os.tag) {
        .linux => readLinuxProcessMemory(allocator, io),
        .macos => readDarwinProcessMemory(),
        .windows => readWindowsProcessMemory(),
        else => error.UnsupportedMeasurement,
    };
}

fn readDarwinProcessMemory() !ProcessMemory {
    const task = std.c.mach_task_self();
    if (task == std.c.TASK.NULL) return error.UnsupportedMeasurement;
    var info: std.c.task_vm_info_data_t = undefined;
    var count = std.c.TASK.VM.INFO_COUNT;
    if (std.c.task_info(task, std.c.TASK.VM.INFO, @ptrCast(&info), &count) != 0) return error.UnsupportedMeasurement;
    return .{
        .rss_bytes = @intCast(info.resident_size),
        .peak_rss_bytes = @intCast(info.resident_size_peak),
        .pss_bytes = 0,
        .private_bytes = @intCast(info.phys_footprint),
    };
}

fn readWindowsProcessMemory() !ProcessMemory {
    const windows = std.os.windows;
    var counters: PROCESS_MEMORY_COUNTERS_EX = .{ .cb = @sizeOf(PROCESS_MEMORY_COUNTERS_EX) };
    if (!GetProcessMemoryInfo(windows.GetCurrentProcess(), &counters, counters.cb).toBool()) return error.UnsupportedMeasurement;
    return .{
        .rss_bytes = counters.WorkingSetSize,
        .peak_rss_bytes = counters.PeakWorkingSetSize,
        .pss_bytes = 0,
        .private_bytes = counters.PrivateUsage,
    };
}

const PROCESS_MEMORY_COUNTERS_EX = extern struct {
    cb: u32,
    PageFaultCount: u32 = 0,
    PeakWorkingSetSize: usize = 0,
    WorkingSetSize: usize = 0,
    QuotaPeakPagedPoolUsage: usize = 0,
    QuotaPagedPoolUsage: usize = 0,
    QuotaPeakNonPagedPoolUsage: usize = 0,
    QuotaNonPagedPoolUsage: usize = 0,
    PagefileUsage: usize = 0,
    PeakPagefileUsage: usize = 0,
    PrivateUsage: usize = 0,
};

extern "psapi" fn GetProcessMemoryInfo(process: std.os.windows.HANDLE, counters: *PROCESS_MEMORY_COUNTERS_EX, cb: u32) callconv(.winapi) std.os.windows.BOOL;

fn readLinuxProcessMemory(allocator: std.mem.Allocator, io: std.Io) !ProcessMemory {
    _ = allocator;
    var status_file = try std.Io.Dir.openFileAbsolute(io, "/proc/self/status", .{});
    defer status_file.close(io);
    var status_buffer: [64 * 1024]u8 = undefined;
    var status_reader = status_file.reader(io, &.{});
    const status_len = status_reader.interface.readSliceShort(&status_buffer) catch |err| switch (err) {
        error.ReadFailed => return status_reader.err.?,
    };
    const status = status_buffer[0..status_len];

    var memory: ProcessMemory = .{
        .rss_bytes = try parseProcKb(status, "VmRSS:"),
        .peak_rss_bytes = try parseProcKb(status, "VmHWM:"),
        .pss_bytes = 0,
        .private_bytes = 0,
    };

    if (readLinuxSmapsRollup(io)) |rollup| {
        memory.pss_bytes = rollup.pss_bytes;
        memory.private_bytes = rollup.private_bytes;
    } else |_| {}

    return memory;
}

fn readLinuxSmapsRollup(io: std.Io) !struct { pss_bytes: u64, private_bytes: u64 } {
    var file = try std.Io.Dir.openFileAbsolute(io, "/proc/self/smaps_rollup", .{});
    defer file.close(io);
    var buffer: [64 * 1024]u8 = undefined;
    var reader = file.reader(io, &.{});
    const len = reader.interface.readSliceShort(&buffer) catch |err| switch (err) {
        error.ReadFailed => return reader.err.?,
    };
    const bytes = buffer[0..len];
    return .{
        .pss_bytes = try parseProcKb(bytes, "Pss:"),
        .private_bytes = (try parseProcKb(bytes, "Private_Clean:")) + (try parseProcKb(bytes, "Private_Dirty:")),
    };
}

fn parseProcKb(bytes: []const u8, key: []const u8) !u64 {
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, key)) continue;
        var it = std.mem.tokenizeAny(u8, line[key.len..], " \t");
        const value = try std.fmt.parseInt(u64, it.next() orelse return error.InvalidProcessMemory, 10);
        return value * 1024;
    }
    return error.InvalidProcessMemory;
}

test "wall clock measurement shape" {
    var wall: WallClock = .{};
    const m = wall.measurement();
    const start_value = try m.start(m.ctx);
    const elapsed = try m.end(m.ctx, start_value);
    try std.testing.expect(m.toF64(m.ctx, elapsed) >= 0);
    try std.testing.expectEqual(@as(u64, 3), m.add(m.ctx, 1, 2));
    const formatted = try m.format(m.ctx, std.testing.allocator, 3);
    defer std.testing.allocator.free(formatted);
    try std.testing.expectEqualStrings("3 ns", formatted);
}

test "measurement unit labels cover all built-in kinds" {
    const Kind = enum { wall_time, cpu_cycles, linux_perf, macos_kperf, process_memory, allocator_counters };
    try std.testing.expectEqualStrings("ns", unitLabel(Kind.wall_time));
    try std.testing.expectEqualStrings("cycles", unitLabel(Kind.cpu_cycles));
    try std.testing.expectEqualStrings("events", unitLabel(Kind.linux_perf));
    try std.testing.expectEqualStrings("events", unitLabel(Kind.macos_kperf));
    try std.testing.expectEqualStrings("bytes", unitLabel(Kind.process_memory));
    try std.testing.expectEqualStrings("allocs", unitLabel(Kind.allocator_counters));
}

test "cpu cycle reader is monotonic on x86" {
    if (builtin.cpu.arch != .x86 and builtin.cpu.arch != .x86_64) return error.SkipZigTest;
    const a = try CpuCycles.read();
    const b = try CpuCycles.read();
    try std.testing.expect(b >= a);
}

test "cpu cycle measurement shape on x86" {
    if (builtin.cpu.arch != .x86 and builtin.cpu.arch != .x86_64) return error.SkipZigTest;
    var cycles: CpuCycles = .{};
    const m = cycles.measurement();
    const start_value = try m.start(m.ctx);
    const elapsed = try m.end(m.ctx, start_value);
    try std.testing.expect(m.toF64(m.ctx, elapsed) >= 0);
    try std.testing.expectEqual(@as(u64, 3), m.add(m.ctx, 1, 2));
    const formatted = try m.format(m.ctx, std.testing.allocator, 3);
    defer std.testing.allocator.free(formatted);
    try std.testing.expectEqualStrings("3 cycles", formatted);
}

test "macos kperf opens where supported" {
    if (!builtin.os.tag.isDarwin()) return error.SkipZigTest;
    const kperf = MacosKperf.open() catch return error.SkipZigTest;
    defer kperf.close();
}

test "counting allocator tracks alloc free and shrink" {
    var counting = CountingAllocator.init(std.testing.allocator);
    const allocator = counting.allocator();

    const memory_ptr = allocator.rawAlloc(16, .of(u8), @returnAddress()).?;
    var memory: []u8 = memory_ptr[0..16];
    try std.testing.expectEqual(@as(u64, 1), counting.counters.allocations);
    try std.testing.expectEqual(@as(u64, 16), counting.counters.live_bytes);
    try std.testing.expectEqual(@as(u64, 16), counting.counters.peak_live_bytes);

    if (allocator.rawResize(memory, .of(u8), 8, @returnAddress())) {
        memory = memory[0..8];
        try std.testing.expectEqual(@as(u64, 1), counting.counters.resizes);
        try std.testing.expectEqual(@as(u64, 8), counting.counters.live_bytes);
    }

    allocator.rawFree(memory, .of(u8), @returnAddress());
    try std.testing.expectEqual(@as(u64, 1), counting.counters.frees);
    try std.testing.expectEqual(@as(u64, 0), counting.counters.live_bytes);
}

test "process memory path is callable where supported" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos and builtin.os.tag != .windows) return error.SkipZigTest;
    const mem = try readProcessMemory(std.testing.allocator, std.testing.io);
    try std.testing.expect(mem.rss_bytes > 0);
}
