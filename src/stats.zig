const std = @import("std");

pub const Estimate = struct {
    point: f64,
    lower: f64,
    upper: f64,
    standard_error: f64,
};

pub const OutlierKind = enum {
    low_severe,
    low_mild,
    normal,
    high_mild,
    high_severe,
};

pub const TukeyFences = struct {
    low_mild: f64,
    high_mild: f64,
    low_severe: f64,
    high_severe: f64,
};

pub const Regression = struct {
    slope: f64,
    intercept: f64,
    r2: f64,
};

pub const TTest = struct {
    t: f64,
    degrees_freedom: f64,
};

pub fn mean(values: []const f64) f64 {
    var total: f64 = 0;
    for (values) |value| total += value;
    return total / @as(f64, @floatFromInt(values.len));
}

pub fn medianSorted(values: []const f64) f64 {
    return percentileSorted(values, 0.5);
}

pub fn percentileSorted(values: []const f64, p: f64) f64 {
    if (values.len == 1) return values[0];
    const rank = p * @as(f64, @floatFromInt(values.len - 1));
    const lo: usize = @intFromFloat(@floor(rank));
    const hi: usize = @intFromFloat(@ceil(rank));
    if (lo == hi) return values[lo];
    const w = rank - @as(f64, @floatFromInt(lo));
    return values[lo] * (1.0 - w) + values[hi] * w;
}

pub fn standardDeviation(values: []const f64) f64 {
    if (values.len < 2) return 0;
    const m = mean(values);
    var total: f64 = 0;
    for (values) |value| {
        const d = value - m;
        total += d * d;
    }
    return @sqrt(total / @as(f64, @floatFromInt(values.len - 1)));
}

pub fn medianAbsoluteDeviation(sorted_values: []const f64, scratch: []f64) f64 {
    const m = medianSorted(sorted_values);
    for (sorted_values, 0..) |value, i| scratch[i] = @abs(value - m);
    std.mem.sort(f64, scratch[0..sorted_values.len], {}, comptime std.sort.asc(f64));
    return medianSorted(scratch[0..sorted_values.len]);
}

pub fn tukeyFences(sorted_values: []const f64) TukeyFences {
    const q1 = percentileSorted(sorted_values, 0.25);
    const q3 = percentileSorted(sorted_values, 0.75);
    const iqr = q3 - q1;
    return .{
        .low_mild = q1 - 1.5 * iqr,
        .high_mild = q3 + 1.5 * iqr,
        .low_severe = q1 - 3.0 * iqr,
        .high_severe = q3 + 3.0 * iqr,
    };
}

pub fn classifyOutlier(value: f64, fences: TukeyFences) OutlierKind {
    if (value < fences.low_severe) return .low_severe;
    if (value < fences.low_mild) return .low_mild;
    if (value > fences.high_severe) return .high_severe;
    if (value > fences.high_mild) return .high_mild;
    return .normal;
}

pub fn linearRegression(x: []const f64, y: []const f64) Regression {
    const mx = mean(x);
    const my = mean(y);
    var sxx: f64 = 0;
    var sxy: f64 = 0;
    var syy: f64 = 0;
    for (x, y) |xi, yi| {
        const dx = xi - mx;
        const dy = yi - my;
        sxx += dx * dx;
        sxy += dx * dy;
        syy += dy * dy;
    }
    if (sxx == 0) return .{ .slope = 0, .intercept = my, .r2 = 1 };
    const slope = sxy / sxx;
    const intercept = my - slope * mx;
    return .{
        .slope = slope,
        .intercept = intercept,
        .r2 = if (sxx == 0 or syy == 0) 1 else (sxy * sxy) / (sxx * syy),
    };
}

pub fn relativeChange(current: f64, baseline: f64) f64 {
    if (baseline == 0) return if (current == 0) 0 else std.math.inf(f64);
    return (current - baseline) / baseline;
}

pub fn twoSampleT(a: []const f64, b: []const f64) TTest {
    const ma = mean(a);
    const mb = mean(b);
    const va = variance(a);
    const vb = variance(b);
    const na: f64 = @floatFromInt(a.len);
    const nb: f64 = @floatFromInt(b.len);
    const sa = va / na;
    const sb = vb / nb;
    const denom = @sqrt(sa + sb);
    if (denom == 0) {
        return .{
            .t = if (ma == mb) 0 else std.math.inf(f64),
            .degrees_freedom = std.math.inf(f64),
        };
    }
    const df_denom = (sa * sa) / (na - 1.0) + (sb * sb) / (nb - 1.0);
    return .{
        .t = (ma - mb) / denom,
        .degrees_freedom = if (df_denom == 0) std.math.inf(f64) else ((sa + sb) * (sa + sb)) / df_denom,
    };
}

pub fn pValueFromT(t: f64, degrees_freedom: f64) f64 {
    if (t == 0) return 1.0;
    if (!std.math.isFinite(t)) return 0.0;
    if (!std.math.isFinite(degrees_freedom)) return 2.0 * (1.0 - normalCdf(@abs(t)));
    const x = degrees_freedom / (degrees_freedom + t * t);
    return regularizedIncompleteBeta(x, degrees_freedom / 2.0, 0.5);
}

pub fn confidenceIntervalSorted(distribution: []const f64, confidence: f64) Estimate {
    const alpha = 1.0 - confidence;
    return .{
        .point = medianSorted(distribution),
        .lower = percentileSorted(distribution, alpha / 2.0),
        .upper = percentileSorted(distribution, 1.0 - alpha / 2.0),
        .standard_error = standardDeviation(distribution),
    };
}

fn normalCdf(x: f64) f64 {
    return 0.5 * (1.0 + erfApprox(x * std.math.sqrt1_2));
}

fn erfApprox(x: f64) f64 {
    const sign: f64 = if (x < 0) -1 else 1;
    const ax = @abs(x);
    const t = 1.0 / (1.0 + 0.3275911 * ax);
    const y = 1.0 - (((((1.061405429 * t - 1.453152027) * t) + 1.421413741) * t - 0.284496736) * t + 0.254829592) * t * @exp(-ax * ax);
    return sign * y;
}

fn regularizedIncompleteBeta(x: f64, a: f64, b: f64) f64 {
    if (x <= 0.0) return 0.0;
    if (x >= 1.0) return 1.0;
    const log_bt = std.math.lgamma(f64, a + b) - std.math.lgamma(f64, a) - std.math.lgamma(f64, b) + a * @log(x) + b * @log(1.0 - x);
    const bt = @exp(log_bt);
    if (x < (a + 1.0) / (a + b + 2.0)) {
        return bt * betaContinuedFraction(a, b, x) / a;
    }
    return 1.0 - bt * betaContinuedFraction(b, a, 1.0 - x) / b;
}

fn betaContinuedFraction(a: f64, b: f64, x: f64) f64 {
    const max_iter = 200;
    const eps = 3.0e-14;
    const fpmin = 1.0e-300;
    const qab = a + b;
    const qap = a + 1.0;
    const qam = a - 1.0;
    var c: f64 = 1.0;
    var d: f64 = 1.0 - qab * x / qap;
    if (@abs(d) < fpmin) d = fpmin;
    d = 1.0 / d;
    var h = d;
    for (1..max_iter + 1) |m_usize| {
        const m: f64 = @floatFromInt(m_usize);
        const m2 = 2.0 * m;
        var aa = m * (b - m) * x / ((qam + m2) * (a + m2));
        d = 1.0 + aa * d;
        if (@abs(d) < fpmin) d = fpmin;
        c = 1.0 + aa / c;
        if (@abs(c) < fpmin) c = fpmin;
        d = 1.0 / d;
        h *= d * c;
        aa = -(a + m) * (qab + m) * x / ((a + m2) * (qap + m2));
        d = 1.0 + aa * d;
        if (@abs(d) < fpmin) d = fpmin;
        c = 1.0 + aa / c;
        if (@abs(c) < fpmin) c = fpmin;
        d = 1.0 / d;
        const del = d * c;
        h *= del;
        if (@abs(del - 1.0) <= eps) break;
    }
    return h;
}

pub fn bootstrapMean(values: []const f64, out: []f64, seed: u64, jobs: u32) void {
    _ = jobs;
    bootstrapMeanRange(values, out, seed, 0);
}

pub fn bootstrapMeanRange(values: []const f64, out: []f64, seed: u64, start_index: usize) void {
    for (out, 0..) |*slot, offset| {
        var prng = std.Random.DefaultPrng.init(mixSeed(seed, start_index + offset));
        const random = prng.random();
        var total: f64 = 0;
        for (0..values.len) |_| total += values[random.intRangeLessThan(usize, 0, values.len)];
        slot.* = total / @as(f64, @floatFromInt(values.len));
    }
}

fn mixSeed(seed: u64, index: usize) u64 {
    var x = seed +% @as(u64, @intCast(index)) *% 0x9e3779b97f4a7c15;
    x = (x ^ (x >> 30)) *% 0xbf58476d1ce4e5b9;
    x = (x ^ (x >> 27)) *% 0x94d049bb133111eb;
    return x ^ (x >> 31);
}

fn variance(values: []const f64) f64 {
    if (values.len < 2) return 0;
    const m = mean(values);
    var total: f64 = 0;
    for (values) |value| {
        const d = value - m;
        total += d * d;
    }
    return total / @as(f64, @floatFromInt(values.len - 1));
}

test "percentiles and median" {
    const values = [_]f64{ 1, 2, 3, 4, 5 };
    try std.testing.expectEqual(@as(f64, 3), medianSorted(&values));
    try std.testing.expectEqual(@as(f64, 2), percentileSorted(&values, 0.25));
    try std.testing.expectEqual(@as(f64, 4), percentileSorted(&values, 0.75));
}

test "mean standard deviation and mad" {
    const values = [_]f64{ 1, 2, 3, 4, 5 };
    var scratch: [5]f64 = undefined;
    try std.testing.expectEqual(@as(f64, 3), mean(&values));
    try std.testing.expectApproxEqAbs(@as(f64, 1.5811388300841898), standardDeviation(&values), 1e-12);
    try std.testing.expectEqual(@as(f64, 1), medianAbsoluteDeviation(&values, &scratch));
}

test "univariate estimates survive shuffle after sorting" {
    var a = [_]f64{ 1, 2, 3, 4, 100 };
    var b = [_]f64{ 100, 3, 1, 4, 2 };
    std.mem.sort(f64, &a, {}, comptime std.sort.asc(f64));
    std.mem.sort(f64, &b, {}, comptime std.sort.asc(f64));
    var scratch_a: [5]f64 = undefined;
    var scratch_b: [5]f64 = undefined;
    try std.testing.expectEqual(mean(&a), mean(&b));
    try std.testing.expectEqual(medianSorted(&a), medianSorted(&b));
    try std.testing.expectEqual(standardDeviation(&a), standardDeviation(&b));
    try std.testing.expectEqual(medianAbsoluteDeviation(&a, &scratch_a), medianAbsoluteDeviation(&b, &scratch_b));
}

test "scaling samples scales univariate estimates" {
    const a = [_]f64{ 1, 2, 3, 4, 5 };
    const b = [_]f64{ 10, 20, 30, 40, 50 };
    var scratch_a: [5]f64 = undefined;
    var scratch_b: [5]f64 = undefined;
    try std.testing.expectEqual(mean(&a) * 10, mean(&b));
    try std.testing.expectEqual(medianSorted(&a) * 10, medianSorted(&b));
    try std.testing.expectApproxEqAbs(standardDeviation(&a) * 10, standardDeviation(&b), 1e-12);
    try std.testing.expectEqual(medianAbsoluteDeviation(&a, &scratch_a) * 10, medianAbsoluteDeviation(&b, &scratch_b));
}

test "tukey fences and labels" {
    const values = [_]f64{ 10, 11, 12, 13, 14, 15, 100 };
    const fences = tukeyFences(&values);
    try std.testing.expectEqual(OutlierKind.high_severe, classifyOutlier(100, fences));
    try std.testing.expectEqual(OutlierKind.normal, classifyOutlier(12, fences));
}

test "linear regression" {
    const x = [_]f64{ 1, 2, 3, 4 };
    const y = [_]f64{ 3, 5, 7, 9 };
    const r = linearRegression(&x, &y);
    try std.testing.expectApproxEqAbs(@as(f64, 2), r.slope, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 1), r.intercept, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 1), r.r2, 1e-12);
}

test "linear regression constant y has finite r2" {
    const x = [_]f64{ 1, 2, 3 };
    const y = [_]f64{ 5, 5, 5 };
    const r = linearRegression(&x, &y);
    try std.testing.expectEqual(@as(f64, 0), r.slope);
    try std.testing.expectEqual(@as(f64, 1), r.r2);
}

test "single sample statistics are finite" {
    const values = [_]f64{5};
    try std.testing.expectEqual(@as(f64, 0), standardDeviation(&values));
    const r = linearRegression(&values, &values);
    try std.testing.expectEqual(@as(f64, 0), r.slope);
    try std.testing.expectEqual(@as(f64, 5), r.intercept);
    try std.testing.expectEqual(@as(f64, 1), r.r2);
}

test "relative change and t statistic" {
    const a = [_]f64{ 10, 11, 12, 13 };
    const b = [_]f64{ 20, 21, 22, 23 };
    try std.testing.expectEqual(@as(f64, 0.1), relativeChange(11, 10));
    try std.testing.expectEqual(@as(f64, 0), relativeChange(0, 0));
    try std.testing.expect(std.math.isPositiveInf(relativeChange(1, 0)));
    const t = twoSampleT(&b, &a);
    try std.testing.expect(t.t > 0);
    try std.testing.expect(t.degrees_freedom > 0);
    try std.testing.expect(pValueFromT(0, 10) > 0.99);
    try std.testing.expect(pValueFromT(4, std.math.inf(f64)) < 0.001);
}

test "student t p value uses degrees of freedom" {
    try std.testing.expectApproxEqAbs(@as(f64, 0.05), pValueFromT(2.2281388519649385, 10), 1e-6);
    try std.testing.expect(pValueFromT(2.2281388519649385, 3) > pValueFromT(2.2281388519649385, 10));
}

test "confidence interval indexing" {
    const values = [_]f64{ 1, 2, 3, 4, 5 };
    const e = confidenceIntervalSorted(&values, 0.8);
    try std.testing.expectEqual(@as(f64, 3), e.point);
    try std.testing.expectApproxEqAbs(@as(f64, 1.4), e.lower, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 4.6), e.upper, 1e-12);
}

test "bootstrap seed and jobs are deterministic" {
    const values = [_]f64{ 1, 2, 3, 4 };
    var a: [8]f64 = undefined;
    var b: [8]f64 = undefined;
    bootstrapMean(&values, &a, 123, 1);
    bootstrapMean(&values, &b, 123, 8);
    try std.testing.expectEqualSlices(f64, &a, &b);
}

test "bootstrap range partitioning is deterministic" {
    const values = [_]f64{ 1, 2, 3, 4 };
    var whole: [8]f64 = undefined;
    var chunks: [8]f64 = undefined;
    bootstrapMean(&values, &whole, 123, 1);
    bootstrapMeanRange(&values, chunks[0..3], 123, 0);
    bootstrapMeanRange(&values, chunks[3..], 123, 3);
    try std.testing.expectEqualSlices(f64, &whole, &chunks);
}
