const std = @import("std");
const sigbench = @import("sigbench");

fn fib(n: u64) u64 {
    return switch (n) {
        0, 1 => 1,
        else => fib(n - 1) + fib(n - 2),
    };
}

fn benchFib20(b: *sigbench.Bencher) void {
    b.iter(struct {
        fn run() void {
            const n = fib(20);
            std.mem.doNotOptimizeAway(n);
        }
    }.run);
}

fn benchAlloc(b: *sigbench.Bencher) void {
    const allocator = b.allocator orelse std.heap.smp_allocator;
    const start = sigbench.nowNs();
    var i: u64 = 0;
    while (i < b.iterations) : (i += 1) {
        const memory = allocator.alloc(u8, 16) catch return;
        allocator.free(memory);
    }
    b.finishCustom(sigbench.nowNs() - start);
}

pub const benchmarks = sigbench.group("fib", .{
    sigbench.benchWithId("fib-20", "fib 20", benchFib20),
    sigbench.benchWithThroughput("alloc", "alloc", .{ .bytes = 16 }, benchAlloc),
});

pub fn main(init: std.process.Init) !void {
    sigbench.run(init, &.{benchmarks}, .{}) catch |err| {
        std.debug.print("error: {}\n", .{err});
        std.process.exit(1);
    };
}
