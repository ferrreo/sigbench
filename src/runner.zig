const std = @import("std");
const analysis = @import("analysis.zig");
const api = @import("api.zig");
const baseline = @import("baseline.zig");
const gate = @import("gate.zig");
const measure = @import("measurement.zig");
const process_control = @import("process_control.zig");
const report = @import("report.zig");
const sampling = @import("sampling.zig");
const Cli = struct {
    list: bool = false,
    baseline_name: ?[]const u8 = null,
    baseline_strict: bool = false,
    save_baseline: ?[]const u8 = null,
    load_baseline: ?[]const u8 = null,
    exact_filter: ?[]const u8 = null,
    fail_on_regression: bool = false,
    fail_fast: bool = false,
    config: sampling.Config = .{},
    filters: std.array_list.Managed([]const u8),
    gates: std.array_list.Managed(gate.Gate),

    fn init(allocator: std.mem.Allocator) Cli {
        return .{ .filters = .init(allocator), .gates = .init(allocator) };
    }

    fn deinit(self: Cli) void {
        self.filters.deinit();
        self.gates.deinit();
    }
};
pub fn run(init: std.process.Init, groups: []const api.BenchmarkGroup, defaults: sampling.Config) !void {
    var cli = Cli.init(init.gpa);
    defer cli.deinit();
    cli.config = defaults;
    try parseArgs(init, &cli);
    if (cli.config.jobs == 0) {
        const nproc: u32 = @intCast(std.Thread.getCpuCount() catch 1);
        cli.config.jobs = sampling.defaultJobs(nproc);
    }
    try validateConfig(cli.config);
    try validateBenchmarkIds(groups);
    if (cli.list) {
        for (groups) |g| for (g.cases) |c| {
            if (matches(cli.filters.items, cli.exact_filter, g, c)) {
                const line = try std.fmt.allocPrint(init.gpa, "{s}/{s}\n", .{ g.id, c.id });
                defer init.gpa.free(line);
                try writeStdout(init, line);
            }
        };
        return;
    }

    var workspace = try analysis.Workspace.init(init.gpa, cli.config.sample_size, cli.config.resamples, cli.config.jobs);
    defer workspace.deinit();

    var failed = false;
    for (groups) |g| {
        for (g.cases) |c| {
            if (!matches(cli.filters.items, cli.exact_filter, g, c)) continue;
            runCase(init, g, c, cli, &workspace) catch |err| {
                failed = true;
                if (cli.config.plot and err != error.BenchmarkRegression and err != error.GateFailed) report.writeError(init, cli.config.output_dir, g.id, c.id, err) catch {};
                if (isJson(cli.config)) {
                    jsonErrorEvent(init, g.id, c.id, err) catch {};
                    jsonEvent(init, "benchmark_end", g.id, c.id) catch {};
                }
                if (!isJson(cli.config) and !silent(cli.config)) std.debug.print("{s}/{s} error: {}\n", .{ g.id, c.id, err });
                if (cli.fail_fast) return err;
            };
        }
    }
    if (failed) return error.BenchmarkCaseFailed;
}

fn parseArgs(init: std.process.Init, cli: *Cli) !void {
    var it = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer it.deinit();
    _ = it.next();

    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--list")) {
            cli.list = true;
        } else if (std.mem.eql(u8, arg, "--quick")) {
            cli.config.quick = true;
            cli.config.sample_size = 5;
            cli.config.resamples = 1000;
            cli.config.warmup_ns = 5 * std.time.ns_per_ms;
            cli.config.measurement_ns = 10 * std.time.ns_per_ms;
        } else if (std.mem.eql(u8, arg, "--output-format")) {
            const value = it.next() orelse return error.MissingArgument;
            cli.config.output_format = parseOutputFormat(value) orelse return error.UnknownOption;
        } else if (std.mem.eql(u8, arg, "--output-dir")) {
            cli.config.output_dir = it.next() orelse return error.MissingArgument;
        } else if (std.mem.eql(u8, arg, "--sample-size")) {
            const value = it.next() orelse return error.MissingArgument;
            cli.config.sample_size = try parseConfigU32(value);
        } else if (std.mem.eql(u8, arg, "--measurement-time")) {
            cli.config.measurement_ns = try parseDurationNs(it.next() orelse return error.MissingArgument);
        } else if (std.mem.eql(u8, arg, "--warm-up-time")) {
            cli.config.warmup_ns = try parseDurationNs(it.next() orelse return error.MissingArgument);
        } else if (std.mem.eql(u8, arg, "--profile-time")) {
            cli.config.profile_ns = try parseDurationNs(it.next() orelse return error.MissingArgument);
        } else if (std.mem.eql(u8, arg, "--confidence-level")) {
            cli.config.confidence_level = try parseConfigFloat(it.next() orelse return error.MissingArgument);
        } else if (std.mem.eql(u8, arg, "--significance-level")) {
            cli.config.significance_level = try parseConfigFloat(it.next() orelse return error.MissingArgument);
        } else if (std.mem.eql(u8, arg, "--noise-threshold")) {
            cli.config.noise_threshold = try parseConfigFloat(it.next() orelse return error.MissingArgument);
        } else if (std.mem.eql(u8, arg, "--jobs")) {
            cli.config.jobs = try parseConfigU32(it.next() orelse return error.MissingArgument);
        } else if (std.mem.eql(u8, arg, "--seed")) {
            cli.config.seed = try parseConfigU64(it.next() orelse return error.MissingArgument);
        } else if (std.mem.eql(u8, arg, "--measurement")) {
            cli.config.measurement = parseMeasurementKind(it.next() orelse return error.MissingArgument) orelse return error.UnknownOption;
        } else if (std.mem.eql(u8, arg, "--sampling-mode")) {
            cli.config.sampling_mode = parseSamplingMode(it.next() orelse return error.MissingArgument) orelse return error.UnknownOption;
        } else if (std.mem.eql(u8, arg, "--noplot")) {
            cli.config.plot = false;
        } else if (std.mem.eql(u8, arg, "--plotting-backend")) {
            const value = it.next() orelse return error.MissingArgument;
            if (std.mem.eql(u8, value, "none")) cli.config.plot = false else if (!std.mem.eql(u8, value, "sigbench")) return error.UnknownOption;
        } else if (std.mem.eql(u8, arg, "--chart-mode")) {
            cli.config.chart_mode = parseChartMode(it.next() orelse return error.MissingArgument) orelse return error.UnknownOption;
        } else if (std.mem.eql(u8, arg, "--color")) {
            cli.config.color = parseColorMode(it.next() orelse return error.MissingArgument) orelse return error.UnknownOption;
        } else if (std.mem.eql(u8, arg, "--verbose")) {
            cli.config.output_format = .verbose;
        } else if (std.mem.eql(u8, arg, "--quiet")) {
            cli.config.quiet = true;
        } else if (std.mem.eql(u8, arg, "--baseline")) {
            cli.baseline_name = it.next() orelse return error.MissingArgument;
        } else if (std.mem.eql(u8, arg, "--baseline-strict")) {
            cli.baseline_name = it.next() orelse return error.MissingArgument;
            cli.baseline_strict = true;
        } else if (std.mem.eql(u8, arg, "--save-baseline")) {
            cli.save_baseline = it.next() orelse return error.MissingArgument;
        } else if (std.mem.eql(u8, arg, "--load-baseline")) {
            cli.load_baseline = it.next() orelse return error.MissingArgument;
        } else if (std.mem.eql(u8, arg, "--sigbench-exact")) {
            cli.exact_filter = it.next() orelse return error.MissingArgument;
        } else if (std.mem.eql(u8, arg, "--fail-on-regression")) {
            cli.fail_on_regression = true;
        } else if (std.mem.eql(u8, arg, "--fail-fast")) {
            cli.fail_fast = true;
        } else if (std.mem.eql(u8, arg, "--gate")) {
            try cli.gates.append(try gate.parse(it.next() orelse return error.MissingArgument));
        } else if (std.mem.eql(u8, arg, "--isolate-process")) {
            cli.config.isolate_process = true;
        } else if (std.mem.eql(u8, arg, "--pin-cpu")) {
            cli.config.pin_cpu = try parseConfigU32(it.next() orelse return error.MissingArgument);
        } else if (std.mem.eql(u8, arg, "--priority")) {
            cli.config.priority = parsePriority(it.next() orelse return error.MissingArgument) orelse return error.UnknownOption;
        } else if (std.mem.startsWith(u8, arg, "--")) {
            return error.UnknownOption;
        } else {
            try cli.filters.append(arg);
        }
    }
}

fn runCase(init: std.process.Init, group: api.BenchmarkGroup, case: api.BenchmarkCase, cli: Cli, workspace: *analysis.Workspace) !void {
    if (cli.config.isolate_process) return runIsolated(init, group, case);
    if (isJson(cli.config)) try jsonEvent(init, "benchmark_start", group.id, case.id);

    if (cli.config.profile_ns) |profile_ns| {
        try applyProcessControls(cli.config);
        try runProfileCase(init, group, case, cli, profile_ns);
        return;
    }

    var loaded_baseline = try maybeReadBaseline(init, cli.config.output_dir, group.id, case.id, cli.baseline_name);
    defer if (loaded_baseline) |*loaded| loaded.deinit();
    if (cli.baseline_strict and loaded_baseline == null) return error.MissingStrictBaseline;

    if (cli.load_baseline) |name| {
        var loaded_current = (try maybeReadBaseline(init, cli.config.output_dir, group.id, case.id, name)) orelse return error.MissingBaseline;
        defer loaded_current.deinit();
        try writeLoadedAsNew(init, cli.config.output_dir, group.id, case.id, loaded_current.value, cli.config, case.throughput);
        if (!isJson(cli.config) and !silent(cli.config)) std.debug.print("loaded baseline {s}\n", .{name});
        if (isJson(cli.config)) try jsonEvent(init, "benchmark_end", group.id, case.id);
        return;
    }

    try preflight(cli.config);
    try applyProcessControls(cli.config);

    if (!silent(cli.config) and cli.config.output_format == .verbose) std.debug.print("{s}/{s} ... ", .{ group.name, case.name });
    if (!silent(cli.config) and cli.config.output_format == .verbose) printControls(cli.config);

    const warm = try sampling.warmup(init.gpa, case, cli.config.warmup_ns, cli.config.measurement);
    if (isJson(cli.config)) try jsonEvent(init, "warmup", group.id, case.id);

    const counts = try sampling.iterationCounts(
        init.gpa,
        cli.config.sample_size,
        warm.meanNs(),
        cli.config.measurement_ns,
        cli.config.sampling_mode,
    );
    defer init.gpa.free(counts);

    var samples = try sampling.SampleSet.alloc(init.gpa, counts.len);
    defer samples.free(init.gpa);

    if (isJson(cli.config)) try jsonEvent(init, "measurement_start", group.id, case.id);
    try sampling.collect(init.gpa, init.io, case, samples, counts, cli.config.measurement);
    if (isJson(cli.config)) try jsonEvent(init, "measurement_complete", group.id, case.id);

    const analysis_result = try analysis.analyzeWithWorkspace(workspace, samples, cli.config);
    const unit = measure.unitLabel(cli.config.measurement);
    const estimates_json = try analysis.writeEstimatesJson(init.gpa, analysis_result, unit, cli.config.seed, samples, cli.config.measurement);
    defer init.gpa.free(estimates_json);

    const selected_mode = sampling.selectedMode(cli.config.sample_size, warm.meanNs(), cli.config.measurement_ns, cli.config.sampling_mode);
    const sample_json = try baseline.writeSampleJson(init.gpa, samples, selected_mode, cli.config.measurement, cli.config.seed);
    defer init.gpa.free(sample_json);
    try writeRunFiles(init, cli.config.output_dir, group.id, case.id, "new", sample_json, estimates_json);
    if (cli.save_baseline) |name| try writeRunFiles(init, cli.config.output_dir, group.id, case.id, name, sample_json, estimates_json);

    var comparison: ?baseline.Comparison = null;
    var regression_failed = false;
    if (loaded_baseline) |loaded| {
        const loaded_measurement = try parseLoadedMeasurement(loaded.value.measurement);
        try requireMatchingMeasurement(cli.config.measurement, loaded_measurement);
        const scratch_len = baseline.compareScratchLen(samples.avg_ns.len, loaded.value.elapsed_ns.len, cli.config.resamples);
        const scratch = try init.gpa.alloc(f64, scratch_len);
        defer init.gpa.free(scratch);
        const cmp = baseline.compare(samples.avg_ns, loaded.value.elapsed_ns, loaded.value.iterations, loaded_measurement, cli.config.noise_threshold, cli.config.significance_level, cli.config.confidence_level, cli.config.resamples, cli.config.seed, scratch);
        comparison = cmp;
        if (!silent(cli.config) and cli.config.output_format == .verbose) {
            const relation: []const u8 = if (cmp.p_value <= cli.config.significance_level) "<=" else ">";
            std.debug.print("change: [{d:.3}% {d:.3}% {d:.3}%] (p = {d:.3} {s} {d:.3}) ({s}) ", .{ cmp.mean_change_ci.lower * 100.0, cmp.mean_change * 100.0, cmp.mean_change_ci.upper * 100.0, cmp.p_value, relation, cli.config.significance_level, @tagName(cmp.verdict) });
            std.debug.print("{s} ", .{switch (cmp.verdict) {
                .improved => "Performance improved.",
                .regressed => "Performance regressed.",
                .unchanged => "No change in performance detected.",
            }});
        }
        regression_failed = cli.fail_on_regression and (cmp.verdict == .regressed or baseline.metricRegressed(samples, loaded.value, loaded_measurement, cli.config.noise_threshold));
    }

    if (cli.config.plot) try report.write(init, cli.config.output_dir, group.id, case.id, samples, analysis_result, comparison, case.throughput, cli.config.seed, cli.config.chart_mode, unit);
    try gate.apply(cli.gates.items, analysis_result, cli.config.measurement, samples);
    if (regression_failed) return error.BenchmarkRegression;

    if (isJson(cli.config)) {
        try jsonEvent(init, "benchmark_end", group.id, case.id);
    } else if (!silent(cli.config) and cli.config.output_format == .terse) {
        std.debug.print("{s}/{s} {d:.3} {s}\n", .{ group.id, case.id, analysis_result.estimates.mean.point, unit });
    } else if (!silent(cli.config)) {
        printTextResult(init.io, analysis_result, samples.avg_ns.len, cli.config.color, unit);
    }
}

fn preflight(config: sampling.Config) !void {
    try validateConfig(config);
    try @import("measurement.zig").preflight(config.measurement, std.heap.smp_allocator, std.Io.Threaded.global_single_threaded.io());
}

fn validateConfig(config: sampling.Config) !void {
    if (config.sample_size == 0 or config.resamples == 0) return error.InvalidConfiguration;
    if (config.warmup_ns == 0 or config.measurement_ns == 0) return error.InvalidConfiguration;
    if (config.profile_ns) |ns| if (ns == 0) return error.InvalidConfiguration;
    if (!std.math.isFinite(config.confidence_level) or config.confidence_level <= 0 or config.confidence_level >= 1) return error.InvalidConfiguration;
    if (!std.math.isFinite(config.significance_level) or config.significance_level <= 0 or config.significance_level >= 1) return error.InvalidConfiguration;
    if (!std.math.isFinite(config.noise_threshold) or config.noise_threshold < 0) return error.InvalidConfiguration;
}

fn validateBenchmarkIds(groups: []const api.BenchmarkGroup) !void {
    for (groups) |group| {
        try validatePathId(group.id);
        for (group.cases) |case| try validatePathId(case.id);
    }
}

fn validatePathId(id: []const u8) !void {
    if (id.len == 0 or std.mem.eql(u8, id, ".") or std.mem.eql(u8, id, "..")) return error.InvalidBenchmarkId;
    for (id) |c| switch (c) {
        '/', '\\', ':', '*', '?', '"', '<', '>', '|', '#', '%', 0...31 => return error.InvalidBenchmarkId,
        else => {},
    };
}

fn runIsolated(init: std.process.Init, group: api.BenchmarkGroup, case: api.BenchmarkCase) !void {
    var args_it = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args_it.deinit();

    var argv = std.array_list.Managed([]const u8).init(init.gpa);
    defer argv.deinit();

    if (args_it.next()) |exe| try argv.append(exe);
    while (args_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--isolate-process")) continue;
        if (!std.mem.startsWith(u8, arg, "--")) continue;
        try argv.append(arg);
        if (optionTakesValue(arg)) try argv.append(args_it.next() orelse return error.MissingArgument);
    }

    const exact = try std.fmt.allocPrint(init.gpa, "{s}/{s}", .{ group.id, case.id });
    defer init.gpa.free(exact);
    try argv.append("--sigbench-exact");
    try argv.append(exact);

    const result = try std.process.run(init.gpa, init.io, .{
        .argv = argv.items,
        .stdout_limit = .limited(64 * 1024 * 1024),
        .stderr_limit = .limited(64 * 1024 * 1024),
    });
    defer init.gpa.free(result.stdout);
    defer init.gpa.free(result.stderr);

    if (result.stdout.len > 0) try writeStdout(init, result.stdout);
    if (result.stderr.len > 0) std.debug.print("{s}", .{result.stderr});
    switch (result.term) {
        .exited => |code| if (code != 0) return error.IsolatedBenchmarkFailed,
        else => return error.IsolatedBenchmarkFailed,
    }
}

fn optionTakesValue(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "--output-format") or
        std.mem.eql(u8, arg, "--output-dir") or
        std.mem.eql(u8, arg, "--sample-size") or
        std.mem.eql(u8, arg, "--measurement-time") or
        std.mem.eql(u8, arg, "--warm-up-time") or
        std.mem.eql(u8, arg, "--profile-time") or
        std.mem.eql(u8, arg, "--confidence-level") or
        std.mem.eql(u8, arg, "--significance-level") or
        std.mem.eql(u8, arg, "--noise-threshold") or
        std.mem.eql(u8, arg, "--jobs") or
        std.mem.eql(u8, arg, "--seed") or
        std.mem.eql(u8, arg, "--measurement") or
        std.mem.eql(u8, arg, "--sampling-mode") or
        std.mem.eql(u8, arg, "--plotting-backend") or
        std.mem.eql(u8, arg, "--chart-mode") or
        std.mem.eql(u8, arg, "--color") or
        std.mem.eql(u8, arg, "--baseline") or
        std.mem.eql(u8, arg, "--baseline-strict") or
        std.mem.eql(u8, arg, "--save-baseline") or
        std.mem.eql(u8, arg, "--load-baseline") or
        std.mem.eql(u8, arg, "--gate") or
        std.mem.eql(u8, arg, "--pin-cpu") or
        std.mem.eql(u8, arg, "--priority") or
        std.mem.eql(u8, arg, "--sigbench-exact");
}

fn applyProcessControls(config: sampling.Config) !void {
    if (config.pin_cpu) |cpu| try process_control.pinCpu(cpu);
    if (config.priority == .high) try process_control.setHighPriority();
}

fn printControls(config: sampling.Config) void {
    if (config.pin_cpu) |cpu| std.debug.print("pin-cpu={} ", .{cpu});
    if (config.priority != .normal) std.debug.print("priority={s} ", .{@tagName(config.priority)});
}

fn runProfileCase(init: std.process.Init, group: api.BenchmarkGroup, case: api.BenchmarkCase, cli: Cli, profile_ns: u64) !void {
    const benchmark_id = try std.fmt.allocPrint(init.gpa, "{s}/{s}", .{ group.id, case.id });
    defer init.gpa.free(benchmark_id);
    const profile_dir = try std.fmt.allocPrint(init.gpa, "{s}/{s}/{s}/profile", .{ cli.config.output_dir, group.id, case.id });
    defer init.gpa.free(profile_dir);
    try std.Io.Dir.cwd().createDirPath(init.io, profile_dir);

    cli.config.profiler.start(benchmark_id, profile_dir);
    defer cli.config.profiler.stop(benchmark_id, profile_dir);

    const start = api.nowNs();
    while (api.nowNs() - start < profile_ns) {
        var b: api.Bencher = .{ .iterations = 1 };
        try case.run(&b);
        if (b.timing_error) |err| return err;
    }
    if (!silent(cli.config)) std.debug.print("{s}/{s} profiled for {} ns\n", .{ group.name, case.name, profile_ns });
    if (isJson(cli.config)) try jsonEvent(init, "benchmark_end", group.id, case.id);
}

fn writeRunFiles(
    init: std.process.Init,
    root: []const u8,
    group_id: []const u8,
    case_id: []const u8,
    slot: []const u8,
    sample_json: []const u8,
    estimates_json: []const u8,
) !void {
    try writeFileInSlot(init, root, group_id, case_id, slot, "sample.json", sample_json);
    try writeFileInSlot(init, root, group_id, case_id, slot, "estimates.json", estimates_json);
}

fn writeSampleFile(
    init: std.process.Init,
    root: []const u8,
    group_id: []const u8,
    case_id: []const u8,
    slot: []const u8,
    sample_json: []const u8,
) !void {
    try writeFileInSlot(init, root, group_id, case_id, slot, "sample.json", sample_json);
}

fn writeFileInSlot(
    init: std.process.Init,
    root: []const u8,
    group_id: []const u8,
    case_id: []const u8,
    slot: []const u8,
    filename: []const u8,
    data: []const u8,
) !void {
    const dir = try std.fmt.allocPrint(init.gpa, "{s}/{s}/{s}/{s}", .{ root, group_id, case_id, slot });
    defer init.gpa.free(dir);
    try std.Io.Dir.cwd().createDirPath(init.io, dir);

    const path = try std.fmt.allocPrint(init.gpa, "{s}/{s}", .{ dir, filename });
    defer init.gpa.free(path);

    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = path, .data = data });
}

fn maybeReadBaseline(
    init: std.process.Init,
    root: []const u8,
    group_id: []const u8,
    case_id: []const u8,
    name: ?[]const u8,
) !?std.json.Parsed(baseline.SampleJson) {
    const slot = name orelse return null;
    const path = try std.fmt.allocPrint(init.gpa, "{s}/{s}/{s}/{s}/sample.json", .{ root, group_id, case_id, slot });
    defer init.gpa.free(path);

    const bytes = std.Io.Dir.cwd().readFileAlloc(init.io, path, init.gpa, .limited(64 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => |e| return e,
    };
    defer init.gpa.free(bytes);
    return try baseline.readSampleJson(init.gpa, bytes);
}

fn writeLoadedAsNew(init: std.process.Init, root: []const u8, group_id: []const u8, case_id: []const u8, loaded: baseline.SampleJson, config: sampling.Config, throughput: ?api.Throughput) !void {
    var samples = try sampling.SampleSet.alloc(init.gpa, loaded.iterations.len);
    defer samples.free(init.gpa);
    @memcpy(samples.iterations, loaded.iterations);
    @memcpy(samples.elapsed_ns, loaded.elapsed_ns);
    baseline.copyMetricSamples(samples, loaded);
    const measurement = try parseLoadedMeasurement(loaded.measurement);
    for (samples.elapsed_ns, samples.iterations, 0..) |elapsed, iterations, i| {
        samples.avg_ns[i] = if (measurement == .process_memory or measurement == .allocator_counters) elapsed else elapsed / @as(f64, @floatFromInt(iterations));
    }
    const mode: sampling.SamplingMode = if (std.mem.eql(u8, loaded.sampling_mode, "flat")) .flat else .linear;
    const seed = if (loaded.seed != 0) loaded.seed else config.seed;
    const sample_json = try baseline.writeSampleJson(init.gpa, samples, mode, measurement, seed);
    defer init.gpa.free(sample_json);
    var loaded_config = config;
    loaded_config.measurement = measurement;
    const result = try analysis.analyze(init.gpa, samples, loaded_config);
    const unit = measure.unitLabel(measurement);
    const estimates_json = try analysis.writeEstimatesJson(init.gpa, result, unit, seed, samples, measurement);
    defer init.gpa.free(estimates_json);
    try writeRunFiles(init, root, group_id, case_id, "new", sample_json, estimates_json);
    if (config.plot) try report.write(init, root, group_id, case_id, samples, result, null, throughput, seed, config.chart_mode, unit);
}

fn matches(filters: []const []const u8, exact: ?[]const u8, group: api.BenchmarkGroup, case: api.BenchmarkCase) bool {
    if (exact) |value| {
        const slash = std.mem.indexOfScalar(u8, value, '/') orelse return false;
        return std.mem.eql(u8, value[0..slash], group.id) and std.mem.eql(u8, value[slash + 1 ..], case.id);
    }
    if (filters.len == 0) return true;
    for (filters) |filter| {
        if (std.mem.indexOf(u8, group.name, filter) != null) return true;
        if (std.mem.indexOf(u8, case.name, filter) != null) return true;
        if (std.mem.indexOf(u8, case.id, filter) != null) return true;
    }
    return false;
}

fn parseDurationNs(raw: []const u8) !u64 {
    if (std.mem.endsWith(u8, raw, "ms")) return try parseDurationNumber(raw[0 .. raw.len - 2], std.time.ns_per_ms);
    if (std.mem.endsWith(u8, raw, "us")) return try parseDurationNumber(raw[0 .. raw.len - 2], std.time.ns_per_us);
    if (std.mem.endsWith(u8, raw, "ns")) return try parseDurationNumber(raw[0 .. raw.len - 2], 1);
    if (std.mem.endsWith(u8, raw, "s")) return try parseDurationNumber(raw[0 .. raw.len - 1], std.time.ns_per_s);
    return try parseDurationNumber(raw, 1);
}

fn parseChartMode(raw: []const u8) ?sampling.ChartMode {
    if (std.mem.eql(u8, raw, "svg-js")) return .@"svg-js";
    if (std.mem.eql(u8, raw, "svg")) return .svg;
    if (std.mem.eql(u8, raw, "uplot")) return .uplot;
    if (std.mem.eql(u8, raw, "both")) return .both;
    return null;
}

fn parseOutputFormat(raw: []const u8) ?sampling.OutputFormat {
    if (std.mem.eql(u8, raw, "terse")) return .terse;
    if (std.mem.eql(u8, raw, "verbose")) return .verbose;
    if (std.mem.eql(u8, raw, "json")) return .json;
    return null;
}

fn parseColorMode(raw: []const u8) ?sampling.ColorMode {
    if (std.mem.eql(u8, raw, "auto")) return .auto;
    if (std.mem.eql(u8, raw, "always")) return .always;
    if (std.mem.eql(u8, raw, "never")) return .never;
    return null;
}

fn parseMeasurementKind(raw: []const u8) ?sampling.MeasurementKind {
    if (std.mem.eql(u8, raw, "wall-time") or std.mem.eql(u8, raw, "wall_time")) return .wall_time;
    if (std.mem.eql(u8, raw, "cpu-cycles") or std.mem.eql(u8, raw, "cpu_cycles")) return .cpu_cycles;
    if (std.mem.eql(u8, raw, "linux-perf") or std.mem.eql(u8, raw, "linux_perf")) return .linux_perf;
    if (std.mem.eql(u8, raw, "macos-kperf") or std.mem.eql(u8, raw, "macos_kperf")) return .macos_kperf;
    if (std.mem.eql(u8, raw, "process-memory") or std.mem.eql(u8, raw, "process_memory")) return .process_memory;
    if (std.mem.eql(u8, raw, "allocator-counters") or std.mem.eql(u8, raw, "allocator_counters")) return .allocator_counters;
    return null;
}

fn parseSamplingMode(raw: []const u8) ?sampling.SamplingMode {
    if (std.mem.eql(u8, raw, "auto")) return .auto;
    if (std.mem.eql(u8, raw, "linear")) return .linear;
    if (std.mem.eql(u8, raw, "flat")) return .flat;
    return null;
}

fn parseLoadedMeasurement(raw: []const u8) !sampling.MeasurementKind {
    return parseMeasurementKind(raw) orelse error.InvalidBaselineMeasurement;
}

fn requireMatchingMeasurement(current: sampling.MeasurementKind, loaded: sampling.MeasurementKind) !void {
    if (current != loaded) return error.BaselineMeasurementMismatch;
}

fn parsePriority(raw: []const u8) ?sampling.Priority {
    if (std.mem.eql(u8, raw, "normal")) return .normal;
    if (std.mem.eql(u8, raw, "high")) return .high;
    return null;
}

fn parseDurationNumber(raw: []const u8, scale: u64) !u64 {
    const value = std.fmt.parseFloat(f64, raw) catch return error.InvalidDuration;
    if (!std.math.isFinite(value) or value <= 0) return error.InvalidDuration;
    const scaled = value * @as(f64, @floatFromInt(scale));
    if (scaled < 1 or scaled >= @as(f64, @floatFromInt(std.math.maxInt(u64)))) return error.InvalidDuration;
    return @intFromFloat(scaled);
}

fn parseConfigU32(raw: []const u8) !u32 {
    return std.fmt.parseInt(u32, raw, 10) catch error.InvalidConfiguration;
}

fn parseConfigU64(raw: []const u8) !u64 {
    return std.fmt.parseInt(u64, raw, 10) catch error.InvalidConfiguration;
}

fn parseConfigFloat(raw: []const u8) !f64 {
    return std.fmt.parseFloat(f64, raw) catch error.InvalidConfiguration;
}

fn printTextResult(io: std.Io, result: analysis.Result, sample_count: usize, color: sampling.ColorMode, unit: []const u8) void {
    const mean_est = result.estimates.mean;
    if (colorEnabled(io, color)) {
        std.debug.print("\x1b[32mtime:\x1b[0m [{d:.3} {s} {d:.3} {s} {d:.3} {s}]\n", .{ mean_est.lower, unit, mean_est.point, unit, mean_est.upper, unit });
    } else {
        std.debug.print("time: [{d:.3} {s} {d:.3} {s} {d:.3} {s}]\n", .{ mean_est.lower, unit, mean_est.point, unit, mean_est.upper, unit });
    }
    if (result.outliers.total() > 0) {
        const total = result.outliers.total();
        const n: f64 = @floatFromInt(sample_count);
        std.debug.print("Found {} outliers among {} measurements ({d:.2}%)\n", .{ total, sample_count, @as(f64, @floatFromInt(total)) * 100.0 / n });
        if (result.outliers.low_severe > 0) std.debug.print("  {} ({d:.2}%) low severe\n", .{ result.outliers.low_severe, @as(f64, @floatFromInt(result.outliers.low_severe)) * 100.0 / n });
        if (result.outliers.low_mild > 0) std.debug.print("  {} ({d:.2}%) low mild\n", .{ result.outliers.low_mild, @as(f64, @floatFromInt(result.outliers.low_mild)) * 100.0 / n });
        if (result.outliers.high_mild > 0) std.debug.print("  {} ({d:.2}%) high mild\n", .{ result.outliers.high_mild, @as(f64, @floatFromInt(result.outliers.high_mild)) * 100.0 / n });
        if (result.outliers.high_severe > 0) std.debug.print("  {} ({d:.2}%) high severe\n", .{ result.outliers.high_severe, @as(f64, @floatFromInt(result.outliers.high_severe)) * 100.0 / n });
    }
}

fn colorEnabled(io: std.Io, color: sampling.ColorMode) bool {
    return switch (color) {
        .always => true,
        .never => false,
        .auto => std.Io.File.stderr().supportsAnsiEscapeCodes(io) catch false,
    };
}

fn isJson(config: sampling.Config) bool {
    return config.output_format == .json;
}

fn silent(config: sampling.Config) bool {
    return config.quiet and config.output_format != .json;
}

fn writeStdout(init: std.process.Init, bytes: []const u8) !void {
    try std.Io.File.writeStreamingAll(.stdout(), init.io, bytes);
}

fn jsonEvent(init: std.process.Init, kind: []const u8, group_id: []const u8, case_id: []const u8) !void {
    var bytes = std.array_list.Managed(u8).init(init.gpa);
    defer bytes.deinit();
    try bytes.appendSlice("{\"event\":");
    try writeJsonString(&bytes, kind);
    try bytes.appendSlice(",\"benchmark\":");
    try writeBenchmarkJsonString(&bytes, group_id, case_id);
    try bytes.appendSlice("}\n");
    try writeStdout(init, bytes.items);
}

fn jsonErrorEvent(init: std.process.Init, group_id: []const u8, case_id: []const u8, err: anyerror) !void {
    var bytes = std.array_list.Managed(u8).init(init.gpa);
    defer bytes.deinit();
    try bytes.appendSlice("{\"event\":\"error\",\"benchmark\":");
    try writeBenchmarkJsonString(&bytes, group_id, case_id);
    try bytes.print(",\"error\":\"{}\"}}\n", .{err});
    try writeStdout(init, bytes.items);
}

fn writeBenchmarkJsonString(bytes: *std.array_list.Managed(u8), group_id: []const u8, case_id: []const u8) !void {
    try bytes.append('"');
    try appendJsonStringContent(bytes, group_id);
    try bytes.append('/');
    try appendJsonStringContent(bytes, case_id);
    try bytes.append('"');
}

fn writeJsonString(bytes: *std.array_list.Managed(u8), raw: []const u8) !void {
    try bytes.append('"');
    try appendJsonStringContent(bytes, raw);
    try bytes.append('"');
}

fn appendJsonStringContent(bytes: *std.array_list.Managed(u8), raw: []const u8) !void {
    for (raw) |c| switch (c) {
        '"' => try bytes.appendSlice("\\\""),
        '\\' => try bytes.appendSlice("\\\\"),
        '\n' => try bytes.appendSlice("\\n"),
        '\r' => try bytes.appendSlice("\\r"),
        '\t' => try bytes.appendSlice("\\t"),
        else => if (c < 0x20) try bytes.print("\\u{X:0>4}", .{c}) else try bytes.append(c),
    };
}

test "filter matches group case name or id" {
    const S = struct {
        fn noop(_: *api.Bencher) void {}
    };
    const c = comptime api.benchWithId("fib-20", "fib 20", S.noop);
    const g = comptime api.group("fib", .{c});
    try std.testing.expect(matches(&.{"fib"}, null, g, c));
    try std.testing.expect(matches(&.{"20"}, null, g, c));
    try std.testing.expect(matches(&.{}, "fib/fib-20", g, c));
    try std.testing.expect(!matches(&.{"hash"}, null, g, c));
}

test "run accepts runtime registry slices" {
    const S = struct {
        fn noop(_: *api.Bencher) void {}
    };
    const c = comptime api.benchWithId("id", "name", S.noop);
    const g = comptime api.group("group", .{c});
    var registry = api.RuntimeRegistry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.addGroup(g);
    const groups: []const api.BenchmarkGroup = registry.items();
    const run_fn: *const fn (std.process.Init, []const api.BenchmarkGroup, sampling.Config) anyerror!void = run;
    try std.testing.expectEqual(@as(usize, 1), groups.len);
    _ = run_fn;
}

test "json event strings are escaped" {
    var bytes = std.array_list.Managed(u8).init(std.testing.allocator);
    defer bytes.deinit();
    try writeBenchmarkJsonString(&bytes, "g\"\\", "c\n");
    try std.testing.expectEqualStrings("\"g\\\"\\\\/c\\n\"", bytes.items);
}

test "duration parser accepts common units" {
    try std.testing.expectEqual(@as(u64, 5), try parseDurationNs("5"));
    try std.testing.expectEqual(@as(u64, 5000), try parseDurationNs("5us"));
    try std.testing.expectEqual(@as(u64, 5 * std.time.ns_per_ms), try parseDurationNs("5ms"));
    try std.testing.expectEqual(@as(u64, 1500 * std.time.ns_per_ms), try parseDurationNs("1.5s"));
    try std.testing.expectError(error.InvalidDuration, parseDurationNs("0ms"));
    try std.testing.expectError(error.InvalidDuration, parseDurationNs("-1ms"));
    try std.testing.expectError(error.InvalidDuration, parseDurationNs("0.5ns"));
    try std.testing.expectError(error.InvalidDuration, parseDurationNs("1xs"));
    try std.testing.expectError(error.InvalidDuration, parseDurationNs("18446744073709551616ns"));
}

test "chart mode parser" {
    try std.testing.expectEqual(sampling.ChartMode.@"svg-js", parseChartMode("svg-js").?);
    try std.testing.expectEqual(sampling.ChartMode.svg, parseChartMode("svg").?);
    try std.testing.expect(parseChartMode("bad") == null);
}

test "output controls parser" {
    try std.testing.expectEqual(sampling.OutputFormat.terse, parseOutputFormat("terse").?);
    try std.testing.expectEqual(sampling.OutputFormat.json, parseOutputFormat("json").?);
    try std.testing.expectEqual(sampling.ColorMode.never, parseColorMode("never").?);
    try std.testing.expect(parseOutputFormat("xml") == null);
}

test "measurement and priority parsers" {
    try std.testing.expectEqual(sampling.MeasurementKind.wall_time, parseMeasurementKind("wall-time").?);
    try std.testing.expectEqual(sampling.MeasurementKind.cpu_cycles, parseMeasurementKind("cpu-cycles").?);
    try std.testing.expectEqual(sampling.SamplingMode.linear, parseSamplingMode("linear").?);
    try std.testing.expect(parseSamplingMode("staircase") == null);
    try std.testing.expectEqual(sampling.MeasurementKind.linux_perf, try parseLoadedMeasurement("linux_perf"));
    try std.testing.expectError(error.InvalidBaselineMeasurement, parseLoadedMeasurement("bad"));
    try requireMatchingMeasurement(.wall_time, .wall_time);
    try std.testing.expectError(error.BaselineMeasurementMismatch, requireMatchingMeasurement(.wall_time, .cpu_cycles));
    try std.testing.expect(parseMeasurementKind("cycles") == null);
    try std.testing.expectEqual(sampling.Priority.high, parsePriority("high").?);
}

test "preflight rejects empty sample config" {
    try std.testing.expectError(error.InvalidConfiguration, preflight(.{ .sample_size = 0 }));
    try std.testing.expectError(error.InvalidConfiguration, preflight(.{ .resamples = 0 }));
    try std.testing.expectError(error.InvalidConfiguration, validateConfig(.{ .confidence_level = 1 }));
    try std.testing.expectError(error.InvalidConfiguration, validateConfig(.{ .significance_level = 0 }));
    try std.testing.expectError(error.InvalidConfiguration, validateConfig(.{ .noise_threshold = -0.1 }));
    try std.testing.expectError(error.InvalidConfiguration, validateConfig(.{ .warmup_ns = 0 }));
    try std.testing.expectError(error.InvalidConfiguration, validateConfig(.{ .measurement_ns = 0 }));
    try std.testing.expectError(error.InvalidConfiguration, validateConfig(.{ .profile_ns = 0 }));
    try validateConfig(.{});
}

test "config number parsers return configuration errors" {
    try std.testing.expectError(error.InvalidConfiguration, parseConfigU32("nope"));
    try std.testing.expectError(error.InvalidConfiguration, parseConfigU64("nope"));
    try std.testing.expectError(error.InvalidConfiguration, parseConfigFloat("nope"));
}

test "benchmark ids must be path safe" {
    const S = struct {
        fn bench(_: *api.Bencher) void {}
    };
    const ok_case = comptime api.benchWithId("case-1", "case 1", S.bench);
    const ok_group = comptime api.groupWithId("group_1", "group 1", .{ok_case});
    try validateBenchmarkIds(&.{ok_group});

    const bad_case = comptime api.benchWithId("../case", "bad", S.bench);
    const bad_group = comptime api.groupWithId("group", "group", .{bad_case});
    try std.testing.expectError(error.InvalidBenchmarkId, validateBenchmarkIds(&.{bad_group}));
    try std.testing.expectError(error.InvalidBenchmarkId, validateBenchmarkIds(&.{comptime api.groupWithId("bad/group", "bad", .{ok_case})}));
    try std.testing.expectError(error.InvalidBenchmarkId, validateBenchmarkIds(&.{comptime api.groupWithId("bad#group", "bad", .{ok_case})}));
}

test "preflight rejects unsupported counters before warmup" {
    const builtin = @import("builtin");
    const measurement: sampling.MeasurementKind = if (builtin.os.tag == .linux) .macos_kperf else .linux_perf;
    try std.testing.expectError(error.UnsupportedMeasurement, preflight(.{ .measurement = measurement }));
}

test "profile mode calls hooks once and skips reports" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(root);

    const S = struct {
        var starts: u32 = 0;
        var stops: u32 = 0;
        fn bench(_: *api.Bencher) void {}
        fn start(_: ?*anyopaque, benchmark_id: []const u8, profile_dir: []const u8) void {
            if (std.mem.eql(u8, benchmark_id, "g/c") and std.mem.endsWith(u8, profile_dir, "/g/c/profile")) starts += 1;
        }
        fn stop(_: ?*anyopaque, benchmark_id: []const u8, profile_dir: []const u8) void {
            if (std.mem.eql(u8, benchmark_id, "g/c") and std.mem.endsWith(u8, profile_dir, "/g/c/profile")) stops += 1;
        }
    };
    var cli = Cli.init(std.testing.allocator);
    defer cli.deinit();
    cli.config.output_dir = root;
    cli.config.profiler = .{ .startFn = S.start, .stopFn = S.stop };
    cli.config.quiet = true;
    const init: std.process.Init = .{
        .minimal = undefined,
        .arena = undefined,
        .gpa = std.testing.allocator,
        .io = std.testing.io,
        .environ_map = undefined,
        .preopens = undefined,
    };
    const case = comptime api.benchWithId("c", "case", S.bench);
    const group = comptime api.group("g", .{case});
    try runProfileCase(init, group, case, cli, 0);
    try std.testing.expectEqual(@as(u32, 1), S.starts);
    try std.testing.expectEqual(@as(u32, 1), S.stops);

    const profile_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/g/c/profile", .{root});
    defer std.testing.allocator.free(profile_path);
    var profile_dir = try std.Io.Dir.cwd().openDir(std.testing.io, profile_path, .{});
    profile_dir.close(std.testing.io);
    const report_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/g/c/new/report.html", .{root});
    defer std.testing.allocator.free(report_path);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().openFile(std.testing.io, report_path, .{}));
    const sample_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/g/c/new/sample.json", .{root});
    defer std.testing.allocator.free(sample_path);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().openFile(std.testing.io, sample_path, .{}));
    const estimates_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/g/c/new/estimates.json", .{root});
    defer std.testing.allocator.free(estimates_path);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().openFile(std.testing.io, estimates_path, .{}));
}

test "missing strict baseline fails before measurement" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(root);

    const S = struct {
        var runs: u32 = 0;
        fn bench(b: *api.Bencher) void {
            runs += 1;
            b.iter(tick);
        }
        fn tick() void {}
    };
    var cli = Cli.init(std.testing.allocator);
    defer cli.deinit();
    cli.baseline_name = "missing";
    cli.baseline_strict = true;
    cli.config = .{ .sample_size = 2, .resamples = 4, .warmup_ns = 1, .measurement_ns = 1, .plot = false, .quiet = true, .output_dir = root, .jobs = 1 };
    const init: std.process.Init = .{
        .minimal = undefined,
        .arena = undefined,
        .gpa = std.testing.allocator,
        .io = std.testing.io,
        .environ_map = undefined,
        .preopens = undefined,
    };
    var workspace = try analysis.Workspace.init(std.testing.allocator, cli.config.sample_size, cli.config.resamples, cli.config.jobs);
    defer workspace.deinit();
    const case = comptime api.benchWithId("c", "case", S.bench);
    const group = comptime api.group("g", .{case});

    try std.testing.expectError(error.MissingStrictBaseline, runCase(init, group, case, cli, &workspace));
    try std.testing.expectEqual(@as(u32, 0), S.runs);
}

test "case failure does not poison following case" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(root);

    const S = struct {
        var passes: u32 = 0;
        fn fail(_: *api.Bencher) !void {
            return error.IntentionalFailure;
        }
        fn tick() void {
            passes += 1;
        }
        fn pass(b: *api.Bencher) void {
            b.iter(tick);
        }
    };
    var cli = Cli.init(std.testing.allocator);
    defer cli.deinit();
    cli.config = .{ .sample_size = 2, .resamples = 4, .warmup_ns = 1, .measurement_ns = 1, .plot = false, .quiet = true, .output_dir = root, .jobs = 1 };
    const init: std.process.Init = .{
        .minimal = undefined,
        .arena = undefined,
        .gpa = std.testing.allocator,
        .io = std.testing.io,
        .environ_map = undefined,
        .preopens = undefined,
    };
    var workspace = try analysis.Workspace.init(std.testing.allocator, cli.config.sample_size, cli.config.resamples, cli.config.jobs);
    defer workspace.deinit();
    const fail_case = comptime api.benchWithId("fail", "fail", S.fail);
    const pass_case = comptime api.benchWithId("pass", "pass", S.pass);
    const group = comptime api.group("g", .{ fail_case, pass_case });

    try std.testing.expectError(error.IntentionalFailure, runCase(init, group, fail_case, cli, &workspace));
    try runCase(init, group, pass_case, cli, &workspace);
    try std.testing.expect(S.passes > 0);
}
