const std = @import("std");
const sigbench = @import("sigbench");

fn scopedRoutine(_: u64, scope: *sigbench.MeasurementScope) !void {
    try scope.includeThread(std.Thread.getCurrentId());
    try scope.start();
    try scope.stop();
}

fn batchSetup() u8 {
    return 0;
}

fn batchRoutine(_: *u8) void {}

fn batchTeardown(_: *u8) void {}

pub fn main() !void {
    _ = sigbench.Config;
    var bencher: sigbench.Bencher = .{};
    try bencher.iterCustomScoped(scopedRoutine);
    bencher.iterBatchWithTeardown(
        u8,
        batchSetup,
        batchRoutine,
        batchTeardown,
        .per_iteration,
    );
}
