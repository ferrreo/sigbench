const sigbench = @import("sigbench");

fn scopedRoutine(_: u64, scope: *sigbench.MeasurementScope) !void {
    try scope.start();
    try scope.stop();
}

pub fn main() !void {
    _ = sigbench.Config;
    var bencher: sigbench.Bencher = .{};
    try bencher.iterCustomScoped(scopedRoutine);
}
