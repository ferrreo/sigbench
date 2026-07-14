const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const sigbench = b.addModule("sigbench", .{
        .root_source_file = b.path("src/sigbench.zig"),
        .target = target,
        .optimize = optimize,
    });
    linkDarwinKperf(sigbench, target);

    const tests = b.addTest(.{ .root_module = sigbench });
    const run_tests = b.addRunArtifact(tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    const package_test = b.addSystemCommand(&.{ b.graph.zig_exe, "build", "test" });
    package_test.setCwd(b.path("tests/package_consumer"));
    test_step.dependOn(&package_test.step);

    const bench_mod = b.createModule(.{
        .root_source_file = b.path("examples/fib.zig"),
        .target = target,
        .optimize = optimize,
    });
    bench_mod.addImport("sigbench", sigbench);
    linkDarwinKperf(bench_mod, target);

    const bench_exe = b.addExecutable(.{
        .name = "fib-bench",
        .root_module = bench_mod,
    });

    const run_bench = b.addRunArtifact(bench_exe);
    if (b.args) |args| run_bench.addArgs(args);

    const bench_step = b.step("bench", "Run example benchmarks");
    bench_step.dependOn(&run_bench.step);
}

fn linkDarwinKperf(module: *std.Build.Module, target: std.Build.ResolvedTarget) void {
    if (!target.result.os.tag.isDarwin()) return;
    module.linkFramework("kperf", .{});
    module.linkFramework("kperfdata", .{});
}
