const std = @import("std");
const analysis = @import("analysis.zig");
const api = @import("api.zig");
const baseline = @import("baseline.zig");
const sampling = @import("sampling.zig");

const uplot_js = @embedFile("vendor/uplot/uPlot.iife.min.js");
const uplot_css = @embedFile("vendor/uplot/uPlot.min.css");
const benchmark_header_html = @embedFile("templates/benchmark_header.html");
const error_report_html = @embedFile("templates/error_report.html");
const group_index_header_html = @embedFile("templates/group_index_header.html");
const top_index_header_html = @embedFile("templates/top_index_header.html");

const plot_names = [_][]const u8{
    "pdf",
    "regression",
    "iteration_times",
    "absolute_distributions",
    "relative_distributions",
    "t_test",
    "line_comparison",
    "throughput_line_comparison",
    "violin_summary",
};

pub fn write(
    init: std.process.Init,
    root: []const u8,
    group_id: []const u8,
    case_id: []const u8,
    samples: sampling.SampleSet,
    result: analysis.Result,
    comparison: ?baseline.Comparison,
    throughput: ?api.Throughput,
    seed: u64,
    chart_mode: sampling.ChartMode,
    unit: []const u8,
) !void {
    const case_dir = try std.fmt.allocPrint(init.gpa, "{s}/{s}/{s}/new", .{ root, group_id, case_id });
    defer init.gpa.free(case_dir);
    try std.Io.Dir.cwd().createDirPath(init.io, case_dir);

    const plot_dir = try std.fmt.allocPrint(init.gpa, "{s}/plots", .{case_dir});
    defer init.gpa.free(plot_dir);
    try std.Io.Dir.cwd().createDirPath(init.io, plot_dir);

    if (chart_mode != .uplot) {
        inline for (plot_names) |name| {
            const svg = try writeSvg(init.gpa, name, samples, result, comparison, throughput, unit);
            defer init.gpa.free(svg);
            const path = try std.fmt.allocPrint(init.gpa, "{s}/{s}.svg", .{ plot_dir, name });
            defer init.gpa.free(path);
            try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = path, .data = svg });
        }
    }

    const assets_dir = try std.fmt.allocPrint(init.gpa, "{s}/assets", .{case_dir});
    defer init.gpa.free(assets_dir);
    try std.Io.Dir.cwd().createDirPath(init.io, assets_dir);
    try writeChartAssets(init, assets_dir, samples, chart_mode);

    const page = try benchmarkHtml(init.gpa, group_id, case_id, result, comparison, throughput, seed, chart_mode, unit, samples);
    defer init.gpa.free(page);
    const page_path = try std.fmt.allocPrint(init.gpa, "{s}/report.html", .{case_dir});
    defer init.gpa.free(page_path);
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = page_path, .data = page });

    try writeGroupIndex(init, root, group_id);
    try writeTopIndex(init, root);
}

pub fn writeError(init: std.process.Init, root: []const u8, group_id: []const u8, case_id: []const u8, err: anyerror) !void {
    const case_dir = try std.fmt.allocPrint(init.gpa, "{s}/{s}/{s}/new", .{ root, group_id, case_id });
    defer init.gpa.free(case_dir);
    try std.Io.Dir.cwd().createDirPath(init.io, case_dir);

    const group_html = try escapedAlloc(init.gpa, group_id);
    defer init.gpa.free(group_html);
    const case_html = try escapedAlloc(init.gpa, case_id);
    defer init.gpa.free(case_html);
    const page = try std.fmt.allocPrint(init.gpa, error_report_html, .{ group_html, case_html, group_html, case_html, err });
    defer init.gpa.free(page);
    const page_path = try std.fmt.allocPrint(init.gpa, "{s}/report.html", .{case_dir});
    defer init.gpa.free(page_path);
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = page_path, .data = page });

    try writeGroupIndex(init, root, group_id);
    try writeTopIndex(init, root);
}

fn writeGroupIndex(init: std.process.Init, root: []const u8, group_id: []const u8) !void {
    const group_dir_path = try std.fmt.allocPrint(init.gpa, "{s}/{s}", .{ root, group_id });
    defer init.gpa.free(group_dir_path);
    var group_dir = try std.Io.Dir.cwd().openDir(init.io, group_dir_path, .{ .iterate = true });
    defer group_dir.close(init.io);

    var bytes = std.array_list.Managed(u8).init(init.gpa);
    defer bytes.deinit();
    const group_html = try escapedAlloc(init.gpa, group_id);
    defer init.gpa.free(group_html);
    try bytes.print(group_index_header_html, .{ group_html, group_html });
    const names = try directoryNames(init, group_dir);
    defer freeNames(init.gpa, names);
    for (names) |name| {
        const name_html = try escapedAlloc(init.gpa, name);
        defer init.gpa.free(name_html);
        try bytes.print("<p><a href=\"{s}/new/report.html\">{s}</a></p>", .{ name_html, name_html });
    }

    const group_path = try std.fmt.allocPrint(init.gpa, "{s}/index.html", .{group_dir_path});
    defer init.gpa.free(group_path);
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = group_path, .data = bytes.items });
}

fn writeTopIndex(init: std.process.Init, root: []const u8) !void {
    var root_dir = try std.Io.Dir.cwd().openDir(init.io, root, .{ .iterate = true });
    defer root_dir.close(init.io);

    var bytes = std.array_list.Managed(u8).init(init.gpa);
    defer bytes.deinit();
    try bytes.appendSlice(top_index_header_html);
    const names = try directoryNames(init, root_dir);
    defer freeNames(init.gpa, names);
    for (names) |name| {
        const name_html = try escapedAlloc(init.gpa, name);
        defer init.gpa.free(name_html);
        try bytes.print("<p><a href=\"{s}/index.html\">{s}</a></p>", .{ name_html, name_html });
    }

    const index_path = try std.fmt.allocPrint(init.gpa, "{s}/index.html", .{root});
    defer init.gpa.free(index_path);
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = index_path, .data = bytes.items });
}

fn directoryNames(init: std.process.Init, dir: std.Io.Dir) ![][]const u8 {
    var names = std.array_list.Managed([]const u8).init(init.gpa);
    errdefer {
        for (names.items) |name| init.gpa.free(name);
        names.deinit();
    }
    var it = dir.iterate();
    while (try it.next(init.io)) |entry| {
        if (entry.kind != .directory) continue;
        if (std.mem.eql(u8, entry.name, ".") or std.mem.eql(u8, entry.name, "..")) continue;
        try names.append(try init.gpa.dupe(u8, entry.name));
    }
    std.mem.sort([]const u8, names.items, {}, stringLessThan);
    return names.toOwnedSlice();
}

fn freeNames(allocator: std.mem.Allocator, names: [][]const u8) void {
    for (names) |name| allocator.free(name);
    allocator.free(names);
}

fn stringLessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn benchmarkHtml(allocator: std.mem.Allocator, group_id: []const u8, case_id: []const u8, result: analysis.Result, comparison: ?baseline.Comparison, throughput: ?api.Throughput, seed: u64, chart_mode: sampling.ChartMode, unit: []const u8, samples: sampling.SampleSet) ![]u8 {
    var bytes = std.array_list.Managed(u8).init(allocator);
    errdefer bytes.deinit();
    const group_html = try escapedAlloc(allocator, group_id);
    defer allocator.free(group_html);
    const case_html = try escapedAlloc(allocator, case_id);
    defer allocator.free(case_html);
    try bytes.appendSlice("<!doctype html><meta charset=\"utf-8\">");
    if (chart_mode == .uplot or chart_mode == .both) {
        try bytes.appendSlice("<link rel=\"stylesheet\" href=\"assets/uPlot.min.css\">");
    }
    try bytes.print(benchmark_header_html, .{
        group_html,
        case_html,
        group_html,
        case_html,
        result.estimates.mean.point,
        unit,
        result.estimates.mean.lower,
        result.estimates.mean.upper,
        result.estimates.median.point,
        unit,
        result.estimates.std_dev.point,
        unit,
        result.estimates.median_abs_dev.point,
        unit,
    });
    if (result.estimates.slope) |slope| try bytes.print("<p>slope: {d:.3} {s}</p>", .{ slope.point, unit });
    if (result.estimates.r2) |r2| try bytes.print("<p>R2: {d:.5}</p>", .{r2});
    try bytes.print("<p>outliers: {}</p><p>seed: {}</p><p><a href=\"sample.json\">sample JSON</a> <a href=\"estimates.json\">estimates JSON</a></p>", .{ result.outliers.total(), seed });
    if (std.mem.eql(u8, unit, "allocs")) try allocatorMetricsHtml(&bytes, samples);
    if (std.mem.eql(u8, unit, "bytes")) try memoryMetricsHtml(&bytes, samples);
    if (anyAsync(samples)) try bytes.appendSlice("<p>warning: async executor overhead can dominate tiny routines.</p>");
    if (throughput) |value| {
        const label, const amount = throughputParts(value);
        try bytes.print(
            \\<p>throughput: {d:.3} {s}/s [{d:.3}, {d:.3}]</p>
        , .{
            throughputRate(amount, result.estimates.mean.point),
            label,
            throughputRate(amount, result.estimates.mean.upper),
            throughputRate(amount, result.estimates.mean.lower),
        });
    }
    if (comparison) |cmp| {
        try bytes.print(
            \\<p>change: {d:.3}% [{d:.3}, {d:.3}] median {d:.3}% [{d:.3}, {d:.3}] p-value {d:.6} verdict {s}</p>
        , .{ cmp.mean_change * 100.0, cmp.mean_change_ci.lower * 100.0, cmp.mean_change_ci.upper * 100.0, cmp.median_change * 100.0, cmp.median_change_ci.lower * 100.0, cmp.median_change_ci.upper * 100.0, cmp.p_value, @tagName(cmp.verdict) });
    }
    if (chart_mode == .uplot or chart_mode == .both) {
        try bytes.appendSlice("<h2>interactive</h2><div id=\"uplot-chart\" style=\"width:640px;height:320px\"></div><script src=\"assets/uPlot.iife.min.js\"></script><script src=\"assets/chart.js\"></script>");
    }
    if (chart_mode != .uplot) {
        inline for (plot_names) |name| {
            try bytes.print("<h2>{s}</h2><a href=\"plots/{s}.svg\"><img src=\"plots/{s}.svg\" alt=\"{s}\"></a>", .{ name, name, name, name });
        }
    }
    if (chart_mode == .@"svg-js" or chart_mode == .both) {
        try bytes.appendSlice("<script src=\"assets/svg.js\"></script>");
    }
    return bytes.toOwnedSlice();
}

fn allocatorMetricsHtml(bytes: *std.array_list.Managed(u8), samples: sampling.SampleSet) !void {
    if (samples.allocator_counters.len == 0) return;
    try bytes.print(
        "<p>allocator: frees {d:.3}, resizes {d:.3}, allocated bytes {d:.3}, peak live bytes {d:.3}</p>",
        .{
            meanAlloc(samples, .frees),
            meanAlloc(samples, .resizes),
            meanAlloc(samples, .allocated_bytes),
            meanAlloc(samples, .peak_live_bytes),
        },
    );
}

fn memoryMetricsHtml(bytes: *std.array_list.Managed(u8), samples: sampling.SampleSet) !void {
    if (samples.process_memory.len == 0) return;
    try bytes.print(
        "<p>memory: peak RSS {d:.3} bytes, PSS {d:.3} bytes, private {d:.3} bytes</p>",
        .{
            meanMemory(samples, .peak_rss),
            meanMemory(samples, .pss),
            meanMemory(samples, .private_bytes),
        },
    );
}

const AllocField = enum { frees, resizes, allocated_bytes, peak_live_bytes };
const MemoryField = enum { peak_rss, pss, private_bytes };

fn meanAlloc(samples: sampling.SampleSet, field: AllocField) f64 {
    var total: f64 = 0;
    for (samples.allocator_counters) |counter| {
        total += @floatFromInt(switch (field) {
            .frees => counter.frees,
            .resizes => counter.resizes,
            .allocated_bytes => counter.allocated_bytes,
            .peak_live_bytes => counter.peak_live_bytes,
        });
    }
    return total / @as(f64, @floatFromInt(samples.allocator_counters.len));
}

fn meanMemory(samples: sampling.SampleSet, field: MemoryField) f64 {
    var total: f64 = 0;
    for (samples.process_memory) |memory| {
        total += switch (field) {
            .peak_rss => memory.peak_rss_bytes,
            .pss => memory.pss_bytes,
            .private_bytes => memory.private_bytes,
        };
    }
    return total / @as(f64, @floatFromInt(samples.process_memory.len));
}

fn throughputParts(value: api.Throughput) struct { []const u8, f64 } {
    return switch (value) {
        .bits => |n| .{ "bits", @floatFromInt(n) },
        .bytes => |n| .{ "bytes", @floatFromInt(n) },
        .elements => |n| .{ "elements", @floatFromInt(n) },
    };
}

fn throughputRate(amount: f64, ns: f64) f64 {
    return if (ns > 0) amount * @as(f64, @floatFromInt(std.time.ns_per_s)) / ns else 0;
}

fn anyAsync(samples: sampling.SampleSet) bool {
    for (samples.async_used) |used| if (used) return true;
    return false;
}

fn writeChartAssets(init: std.process.Init, assets_dir: []const u8, samples: sampling.SampleSet, chart_mode: sampling.ChartMode) !void {
    const display = try displayJson(init.gpa, samples);
    defer init.gpa.free(display);
    const display_path = try std.fmt.allocPrint(init.gpa, "{s}/display.json", .{assets_dir});
    defer init.gpa.free(display_path);
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = display_path, .data = display });

    if (chart_mode == .@"svg-js" or chart_mode == .both) {
        const svg_js_path = try std.fmt.allocPrint(init.gpa, "{s}/svg.js", .{assets_dir});
        defer init.gpa.free(svg_js_path);
        try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = svg_js_path, .data = "document.documentElement.classList.add('sigbench-svg-js');\n" });
    }

    if (chart_mode == .uplot or chart_mode == .both) {
        const js_path = try std.fmt.allocPrint(init.gpa, "{s}/uPlot.iife.min.js", .{assets_dir});
        defer init.gpa.free(js_path);
        try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = js_path, .data = uplot_js });

        const css_path = try std.fmt.allocPrint(init.gpa, "{s}/uPlot.min.css", .{assets_dir});
        defer init.gpa.free(css_path);
        try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = css_path, .data = uplot_css });

        const chart_js = try chartJs(init.gpa, samples);
        defer init.gpa.free(chart_js);
        const chart_path = try std.fmt.allocPrint(init.gpa, "{s}/chart.js", .{assets_dir});
        defer init.gpa.free(chart_path);
        try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = chart_path, .data = chart_js });
    }
}

fn displayJson(allocator: std.mem.Allocator, samples: sampling.SampleSet) ![]u8 {
    var bytes = std.array_list.Managed(u8).init(allocator);
    errdefer bytes.deinit();
    const min_y, const max_y = bounds(samples.avg_ns);
    try bytes.print("{{\"format\":1,\"min\":{d},\"max\":{d},\"x\":[", .{ min_y, max_y });
    try writeDisplayX(&bytes, samples);
    try bytes.appendSlice("],\"y\":[");
    try writeDisplayY(&bytes, samples);
    try bytes.appendSlice("]}\n");
    return bytes.toOwnedSlice();
}

fn writeDisplayX(bytes: *std.array_list.Managed(u8), samples: sampling.SampleSet) !void {
    var first = true;
    try forDisplayPoints(samples, bytes, &first, writeXPoint);
}

fn writeDisplayY(bytes: *std.array_list.Managed(u8), samples: sampling.SampleSet) !void {
    var first = true;
    try forDisplayPoints(samples, bytes, &first, writeYPoint);
}

fn writeXPoint(bytes: *std.array_list.Managed(u8), samples: sampling.SampleSet, i: usize, first: *bool) !void {
    if (!first.*) try bytes.appendSlice(",");
    first.* = false;
    try bytes.print("{}", .{samples.iterations[i]});
}

fn writeYPoint(bytes: *std.array_list.Managed(u8), samples: sampling.SampleSet, i: usize, first: *bool) !void {
    if (!first.*) try bytes.appendSlice(",");
    first.* = false;
    try bytes.print("{d}", .{samples.avg_ns[i]});
}

fn forDisplayPoints(samples: sampling.SampleSet, bytes: *std.array_list.Managed(u8), first: *bool, comptime emit: fn (*std.array_list.Managed(u8), sampling.SampleSet, usize, *bool) anyerror!void) !void {
    const max_points = 200;
    if (samples.avg_ns.len <= max_points) {
        for (samples.avg_ns, 0..) |_, i| try emit(bytes, samples, i, first);
        return;
    }
    const buckets = max_points / 2;
    for (0..buckets) |bucket| {
        const start = samples.avg_ns.len * bucket / buckets;
        const end = samples.avg_ns.len * (bucket + 1) / buckets;
        var min_i = start;
        var max_i = start;
        for (start + 1..end) |i| {
            if (samples.avg_ns[i] < samples.avg_ns[min_i]) min_i = i;
            if (samples.avg_ns[i] > samples.avg_ns[max_i]) max_i = i;
        }
        if (min_i < max_i) {
            try emit(bytes, samples, min_i, first);
            try emit(bytes, samples, max_i, first);
        } else {
            try emit(bytes, samples, max_i, first);
            try emit(bytes, samples, min_i, first);
        }
    }
}

fn chartJs(allocator: std.mem.Allocator, samples: sampling.SampleSet) ![]u8 {
    var bytes = std.array_list.Managed(u8).init(allocator);
    errdefer bytes.deinit();
    try bytes.appendSlice("const sigbenchFallback={x:[");
    try writeDisplayX(&bytes, samples);
    try bytes.appendSlice("],y:[");
    try writeDisplayY(&bytes, samples);
    try bytes.appendSlice("]};\nfunction sigbenchRender(d){new uPlot({width:640,height:320,series:[{}, {label:'avg ns',stroke:'#166534'}],axes:[{},{}]}, [d.x,d.y], document.getElementById('uplot-chart'));}\nfetch(\"assets/display.json\").then(r=>r.ok?r.json():sigbenchFallback).then(sigbenchRender,()=>sigbenchRender(sigbenchFallback));\n");
    return bytes.toOwnedSlice();
}

fn writeSvg(allocator: std.mem.Allocator, title: []const u8, samples: sampling.SampleSet, result: analysis.Result, comparison: ?baseline.Comparison, throughput: ?api.Throughput, unit: []const u8) ![]u8 {
    var bytes = std.array_list.Managed(u8).init(allocator);
    errdefer bytes.deinit();
    const title_xml = try escapedAlloc(allocator, title);
    defer allocator.free(title_xml);

    const y_values = try plotValues(allocator, title, samples, throughput);
    defer allocator.free(y_values);
    const use_iterations_x = std.mem.eql(u8, title, "regression") or std.mem.eql(u8, title, "iteration_times");
    const min_y, const max_y = bounds(y_values);
    const min_x, const max_x = if (use_iterations_x) iterationBounds(samples.iterations) else .{ @as(u64, 0), @as(u64, @intCast(@max(y_values.len - 1, 1))) };
    const span = if (max_y > min_y) max_y - min_y else 1;
    const span_x = if (max_x > min_x) max_x - min_x else 1;
    try bytes.print(
        \\<svg xmlns="http://www.w3.org/2000/svg" width="640" height="320" viewBox="0 0 640 320">
        \\<title>{s}</title><desc>mean {d:.6} {s} ci [{d:.6}, {d:.6}]
    , .{
        title_xml,
        result.estimates.mean.point,
        unit,
        result.estimates.mean.lower,
        result.estimates.mean.upper,
    });
    if (comparison) |cmp| try bytes.print(" change {d:.6}% ci [{d:.6}, {d:.6}] p {d:.6} verdict {s}", .{
        cmp.mean_change * 100.0,
        cmp.mean_change_ci.lower * 100.0,
        cmp.mean_change_ci.upper * 100.0,
        cmp.p_value,
        @tagName(cmp.verdict),
    });
    try bytes.print(
        \\</desc>
        \\<rect width="640" height="320" fill="white"/><text x="20" y="30" font-family="sans-serif" font-size="18">{s}</text>
        \\<polyline fill="none" stroke="#166534" stroke-width="2" points="
    , .{title_xml});
    for (y_values, 0..) |value, i| {
        const raw_x = if (use_iterations_x) samples.iterations[i] - min_x else i;
        const x = 40.0 + (@as(f64, @floatFromInt(raw_x)) / @as(f64, @floatFromInt(span_x))) * 560.0;
        const y = 280.0 - ((value - min_y) / span) * 220.0;
        try bytes.print("{d:.2},{d:.2} ", .{ x, y });
    }
    try bytes.appendSlice("\"/></svg>\n");
    return bytes.toOwnedSlice();
}

fn plotValues(allocator: std.mem.Allocator, title: []const u8, samples: sampling.SampleSet, throughput: ?api.Throughput) ![]f64 {
    const out = try allocator.alloc(f64, samples.avg_ns.len);
    if (std.mem.eql(u8, title, "regression")) {
        @memcpy(out, samples.elapsed_ns);
    } else if (std.mem.eql(u8, title, "absolute_distributions") or std.mem.eql(u8, title, "pdf")) {
        @memcpy(out, samples.avg_ns);
        std.mem.sort(f64, out, {}, comptime std.sort.asc(f64));
    } else if (std.mem.eql(u8, title, "relative_distributions") or std.mem.eql(u8, title, "line_comparison")) {
        const base = mean(samples.avg_ns);
        for (samples.avg_ns, 0..) |value, i| out[i] = if (base != 0) (value - base) / base * 100.0 else 0;
    } else if (std.mem.eql(u8, title, "t_test")) {
        const base = mean(samples.avg_ns);
        const sd = stddev(samples.avg_ns, base);
        for (samples.avg_ns, 0..) |value, i| out[i] = if (sd != 0) (value - base) / sd else 0;
    } else if (std.mem.eql(u8, title, "throughput_line_comparison")) {
        const amount = if (throughput) |t| throughputParts(t)[1] else 1.0;
        for (samples.avg_ns, 0..) |value, i| out[i] = throughputRate(amount, value);
    } else if (std.mem.eql(u8, title, "violin_summary")) {
        const base = mean(samples.avg_ns);
        for (samples.avg_ns, 0..) |value, i| out[i] = @abs(value - base);
        std.mem.sort(f64, out, {}, comptime std.sort.asc(f64));
    } else {
        @memcpy(out, samples.avg_ns);
    }
    return out;
}

fn mean(values: []const f64) f64 {
    var total: f64 = 0;
    for (values) |value| total += value;
    return total / @as(f64, @floatFromInt(values.len));
}

fn stddev(values: []const f64, m: f64) f64 {
    if (values.len < 2) return 0;
    var total: f64 = 0;
    for (values) |value| total += (value - m) * (value - m);
    return @sqrt(total / @as(f64, @floatFromInt(values.len - 1)));
}

fn iterationBounds(values: []const u64) struct { u64, u64 } {
    var min = values[0];
    var max = values[0];
    for (values[1..]) |value| {
        min = @min(min, value);
        max = @max(max, value);
    }
    return .{ min, max };
}

fn bounds(values: []const f64) struct { f64, f64 } {
    var min = values[0];
    var max = values[0];
    for (values[1..]) |value| {
        min = @min(min, value);
        max = @max(max, value);
    }
    return .{ min, max };
}

fn escapedAlloc(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    var bytes = std.array_list.Managed(u8).init(allocator);
    errdefer bytes.deinit();
    for (raw) |c| switch (c) {
        '&' => try bytes.appendSlice("&amp;"),
        '<' => try bytes.appendSlice("&lt;"),
        '>' => try bytes.appendSlice("&gt;"),
        '"' => try bytes.appendSlice("&quot;"),
        '\'' => try bytes.appendSlice("&#39;"),
        else => try bytes.append(c),
    };
    return bytes.toOwnedSlice();
}

fn testResult() analysis.Result {
    const estimate: @import("stats.zig").Estimate = .{ .point = 10, .lower = 8, .upper = 12, .standard_error = 1 };
    return .{
        .estimates = .{
            .mean = estimate,
            .median = estimate,
            .std_dev = estimate,
            .median_abs_dev = estimate,
            .slope = estimate,
            .r2 = 1,
        },
        .outliers = .{},
    };
}

fn testComparison() baseline.Comparison {
    const estimate: @import("stats.zig").Estimate = .{ .point = -0.1, .lower = -0.2, .upper = -0.05, .standard_error = 0.01 };
    return .{
        .mean_change = -0.1,
        .mean_change_ci = estimate,
        .median_change = -0.08,
        .median_change_ci = estimate,
        .p_value = 0.01,
        .verdict = .improved,
    };
}

test "report svg uses sample values" {
    var iterations = [_]u64{ 1, 1 };
    var elapsed = [_]f64{ 10, 20 };
    var avg = [_]f64{ 10, 20 };
    const samples: sampling.SampleSet = .{ .iterations = &iterations, .elapsed_ns = &elapsed, .avg_ns = &avg };
    const svg = try writeSvg(std.testing.allocator, "iteration_times", samples, testResult(), null, null, "ns");
    defer std.testing.allocator.free(svg);
    try std.testing.expect(std.mem.indexOf(u8, svg, "<polyline") != null);
    try std.testing.expect(std.mem.indexOf(u8, svg, "iteration_times") != null);
    try std.testing.expect(std.mem.indexOf(u8, svg, "mean 10") != null);
}

test "report svg includes comparison details" {
    var iterations = [_]u64{ 1, 1 };
    var elapsed = [_]f64{ 10, 20 };
    var avg = [_]f64{ 10, 20 };
    const samples: sampling.SampleSet = .{ .iterations = &iterations, .elapsed_ns = &elapsed, .avg_ns = &avg };
    const svg = try writeSvg(std.testing.allocator, "pdf", samples, testResult(), testComparison(), null, "ns");
    defer std.testing.allocator.free(svg);
    try std.testing.expect(std.mem.indexOf(u8, svg, "change -10") != null);
    try std.testing.expect(std.mem.indexOf(u8, svg, "verdict improved") != null);
}

test "regression plot uses elapsed totals" {
    var iterations = [_]u64{ 1, 2 };
    var elapsed = [_]f64{ 10, 40 };
    var avg = [_]f64{ 10, 20 };
    const samples: sampling.SampleSet = .{ .iterations = &iterations, .elapsed_ns = &elapsed, .avg_ns = &avg };
    const regression = try writeSvg(std.testing.allocator, "regression", samples, testResult(), null, null, "ns");
    defer std.testing.allocator.free(regression);
    const iteration_times = try writeSvg(std.testing.allocator, "iteration_times", samples, testResult(), null, null, "ns");
    defer std.testing.allocator.free(iteration_times);
    try std.testing.expect(!std.mem.eql(u8, regression, iteration_times));
}

test "distribution plots use transformed data" {
    var iterations = [_]u64{ 1, 2, 3 };
    var elapsed = [_]f64{ 10, 40, 90 };
    var avg = [_]f64{ 10, 20, 30 };
    const samples: sampling.SampleSet = .{ .iterations = &iterations, .elapsed_ns = &elapsed, .avg_ns = &avg };
    const iteration_times = try writeSvg(std.testing.allocator, "iteration_times", samples, testResult(), null, null, "ns");
    defer std.testing.allocator.free(iteration_times);
    const relative = try writeSvg(std.testing.allocator, "relative_distributions", samples, testResult(), null, null, "ns");
    defer std.testing.allocator.free(relative);
    const throughput = try writeSvg(std.testing.allocator, "throughput_line_comparison", samples, testResult(), null, .{ .bytes = 10 }, "ns");
    defer std.testing.allocator.free(throughput);
    try std.testing.expect(!std.mem.eql(u8, iteration_times, relative));
    try std.testing.expect(!std.mem.eql(u8, iteration_times, throughput));
}

test "throughput plot scales by configured amount" {
    var iterations = [_]u64{ 1, 2 };
    var elapsed = [_]f64{ 10, 20 };
    var avg = [_]f64{ 10, 20 };
    const samples: sampling.SampleSet = .{ .iterations = &iterations, .elapsed_ns = &elapsed, .avg_ns = &avg };
    const plain = try plotValues(std.testing.allocator, "throughput_line_comparison", samples, null);
    defer std.testing.allocator.free(plain);
    const bytes = try plotValues(std.testing.allocator, "throughput_line_comparison", samples, .{ .bytes = 10 });
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqual(plain[0] * 10.0, bytes[0]);
    const bits = try plotValues(std.testing.allocator, "throughput_line_comparison", samples, .{ .bits = 8 });
    defer std.testing.allocator.free(bits);
    try std.testing.expectEqual(plain[0] * 8.0, bits[0]);
}

test "benchmark html includes throughput when configured" {
    const result = testResult();
    var iterations = [_]u64{1};
    var elapsed = [_]f64{10};
    var avg = [_]f64{10};
    var async_used = [_]bool{true};
    const samples: sampling.SampleSet = .{ .iterations = &iterations, .elapsed_ns = &elapsed, .avg_ns = &avg, .async_used = &async_used };
    const html = try benchmarkHtml(std.testing.allocator, "g", "c", result, null, .{ .bytes = 100 }, 7, .svg, "ns", samples);
    defer std.testing.allocator.free(html);
    try std.testing.expect(std.mem.indexOf(u8, html, "throughput:") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "bytes/s") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "seed: 7") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "median:") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "slope:") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "href=\"plots/pdf.svg\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "href=\"estimates.json\"") != null);
    const bit_html = try benchmarkHtml(std.testing.allocator, "g", "c", result, null, .{ .bits = 8 }, 7, .svg, "ns", samples);
    defer std.testing.allocator.free(bit_html);
    try std.testing.expect(std.mem.indexOf(u8, bit_html, "bits/s") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "async executor overhead") != null);
}

test "report html and svg escape dynamic text" {
    var iterations = [_]u64{1};
    var elapsed = [_]f64{10};
    var avg = [_]f64{10};
    const samples: sampling.SampleSet = .{ .iterations = &iterations, .elapsed_ns = &elapsed, .avg_ns = &avg };
    const html = try benchmarkHtml(std.testing.allocator, "g<&", "c\"'", testResult(), null, null, 7, .svg, "ns", samples);
    defer std.testing.allocator.free(html);
    try std.testing.expect(std.mem.indexOf(u8, html, "g&lt;&amp;/c&quot;&#39;") != null);
    const svg = try writeSvg(std.testing.allocator, "p<&", samples, testResult(), null, null, "ns");
    defer std.testing.allocator.free(svg);
    try std.testing.expect(std.mem.indexOf(u8, svg, "p&lt;&amp;") != null);
}

test "display json preserves min max envelope" {
    var iterations = [_]u64{ 1, 2, 3 };
    var elapsed = [_]f64{ 10, 100, 20 };
    var avg = [_]f64{ 10, 100, 20 };
    const samples: sampling.SampleSet = .{ .iterations = &iterations, .elapsed_ns = &elapsed, .avg_ns = &avg };
    const json = try displayJson(std.testing.allocator, samples);
    defer std.testing.allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"min\":10") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"max\":100") != null);
}

test "display json decimation keeps outlier point" {
    var iterations: [300]u64 = undefined;
    var elapsed: [300]f64 = undefined;
    var avg: [300]f64 = undefined;
    for (&iterations, &elapsed, &avg, 0..) |*iteration, *elapsed_slot, *avg_slot, i| {
        iteration.* = @intCast(i + 1);
        elapsed_slot.* = 1;
        avg_slot.* = 1;
    }
    avg[150] = 999;
    const samples: sampling.SampleSet = .{ .iterations = &iterations, .elapsed_ns = &elapsed, .avg_ns = &avg };
    const json = try displayJson(std.testing.allocator, samples);
    defer std.testing.allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, ",999,") != null);
}

test "chart js uses decimated display data" {
    var iterations: [300]u64 = undefined;
    var elapsed: [300]f64 = undefined;
    var avg: [300]f64 = undefined;
    for (&iterations, &elapsed, &avg, 0..) |*iteration, *elapsed_slot, *avg_slot, i| {
        iteration.* = @intCast(i + 1);
        elapsed_slot.* = 1;
        avg_slot.* = 1;
    }
    avg[150] = 999;
    const samples: sampling.SampleSet = .{ .iterations = &iterations, .elapsed_ns = &elapsed, .avg_ns = &avg };
    const js = try chartJs(std.testing.allocator, samples);
    defer std.testing.allocator.free(js);
    try std.testing.expect(std.mem.indexOf(u8, js, "fetch(\"assets/display.json\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, ",999,") != null);
    try std.testing.expect(std.mem.count(u8, js, ",") < 500);
}
