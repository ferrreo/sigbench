const std = @import("std");
const api = @import("api.zig");

pub const Measurement = struct {
    ctx: *anyopaque,
    start: *const fn (*anyopaque) anyerror!api.MeasurementValue,
    end: *const fn (*anyopaque, api.MeasurementValue) anyerror!api.MeasurementValue,
    zero: *const fn (*anyopaque) api.MeasurementValue,
    add: *const fn (*anyopaque, api.MeasurementValue, api.MeasurementValue) api.MeasurementValue,
    toF64: *const fn (*anyopaque, api.MeasurementValue) f64,
    format: *const fn (*anyopaque, std.mem.Allocator, api.MeasurementValue) anyerror![]u8,
    include_thread: ?*const fn (*anyopaque, std.Thread.Id) anyerror!void = null,
    cleanup: ?*const fn (*anyopaque) void = null,
};
