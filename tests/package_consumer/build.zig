const std = @import("std");

pub fn build(b: *std.Build) void {
    const dependency = b.dependency("sigbench", .{});
    const executable = b.addExecutable(.{
        .name = "sigbench-package-consumer",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
            .imports = &.{.{
                .name = "sigbench",
                .module = dependency.module("sigbench"),
            }},
        }),
    });
    b.step("test", "Build package consumer").dependOn(&executable.step);
}
