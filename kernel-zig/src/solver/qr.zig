const std = @import("std");

pub const RRQRResult = struct {
    rank: u32,
    pivots: []u32,
};

/// Householder Rank-Revealing QR decomposition with column pivoting.
/// Matrix A (size M x N, row-major) is decomposed into Q * R * P^T.
/// The upper triangular factor R is written into A in-place.
pub fn rrqrDecompose(
    allocator: std.mem.Allocator,
    A: []f64,
    M: usize,
    N: usize,
    tolerance: f64,
) !RRQRResult {
    const min_mn = @min(M, N);
    const pivots = try allocator.alloc(u32, N);
    for (0..N) |j| {
        pivots[j] = @intCast(j);
    }

    if (min_mn == 0) {
        return .{ .rank = 0, .pivots = pivots };
    }

    const col_norms_sq = try allocator.alloc(f64, N);
    defer allocator.free(col_norms_sq);

    var max_norm: f64 = 0.0;
    for (0..N) |j| {
        var sum: f64 = 0.0;
        for (0..M) |i| {
            const val = A[i * N + j];
            sum += val * val;
        }
        col_norms_sq[j] = sum;
        const nrm = @sqrt(sum);
        if (nrm > max_norm) max_norm = nrm;
    }

    const tol = if (tolerance > 0.0)
        tolerance
    else
        @max(1e-10, @as(f64, @floatFromInt(min_mn)) * 1e-12 * max_norm);

    var rank: u32 = 0;

    for (0..min_mn) |k| {
        // 1. Pivot selection: find column p >= k with maximum norm
        var max_col_norm_sq: f64 = col_norms_sq[k];
        var best_p: usize = k;
        for (k + 1..N) |p| {
            if (col_norms_sq[p] > max_col_norm_sq) {
                max_col_norm_sq = col_norms_sq[p];
                best_p = p;
            }
        }

        const max_col_norm = @sqrt(@max(0.0, max_col_norm_sq));
        if (max_col_norm <= tol) {
            // Rank cutoff reached
            break;
        }

        rank += 1;

        // 2. Column swap if needed
        if (best_p != k) {
            for (0..M) |i| {
                const tmp = A[i * N + k];
                A[i * N + k] = A[i * N + best_p];
                A[i * N + best_p] = tmp;
            }
            const tmp_norm = col_norms_sq[k];
            col_norms_sq[k] = col_norms_sq[best_p];
            col_norms_sq[best_p] = tmp_norm;

            const tmp_piv = pivots[k];
            pivots[k] = pivots[best_p];
            pivots[best_p] = tmp_piv;
        }

        // 3. Compute Householder reflector for column k, rows k..M-1
        const x0 = A[k * N + k];
        var sigma: f64 = 0.0;
        for (k + 1..M) |i| {
            const val = A[i * N + k];
            sigma += val * val;
        }

        if (sigma < 1e-28) {
            // Sub-column is already zero
            continue;
        }

        const norm_x = @sqrt(x0 * x0 + sigma);
        const alpha = if (x0 >= 0.0) -norm_x else norm_x;
        const v0 = x0 - alpha;
        const beta = 2.0 / (v0 * v0 + sigma);

        A[k * N + k] = alpha;

        // 4. Apply reflector (I - beta * v * v^T) to remaining columns j = k+1..N-1
        for (k + 1..N) |j| {
            var dot: f64 = v0 * A[k * N + j];
            for (k + 1..M) |i| {
                dot += A[i * N + k] * A[i * N + j];
            }
            const gamma = beta * dot;
            A[k * N + j] -= gamma * v0;
            for (k + 1..M) |i| {
                A[i * N + j] -= gamma * A[i * N + k];
            }
        }

        // 5. Zero out sub-diagonal
        for (k + 1..M) |i| {
            A[i * N + k] = 0.0;
        }

        // 6. Update column norms
        for (k + 1..N) |j| {
            const r_kj = A[k * N + j];
            col_norms_sq[j] -= r_kj * r_kj;
            if (col_norms_sq[j] < 1e-14) {
                var recomputed: f64 = 0.0;
                for (k + 1..M) |i| {
                    const val = A[i * N + j];
                    recomputed += val * val;
                }
                col_norms_sq[j] = recomputed;
            }
        }
    }

    return .{
        .rank = rank,
        .pivots = pivots,
    };
}

test "RRQR full rank 3x3 matrix" {
    // Identity matrix
    var A = [_]f64{
        1.0, 0.0, 0.0,
        0.0, 1.0, 0.0,
        0.0, 0.0, 1.0,
    };
    const res = try rrqrDecompose(std.testing.allocator, &A, 3, 3, 1e-7);
    defer std.testing.allocator.free(res.pivots);

    try std.testing.expectEqual(@as(u32, 3), res.rank);
}

test "RRQR rank deficient 3x3 matrix (col 2 = 2 * col 1)" {
    var A = [_]f64{
        1.0, 2.0, 0.0,
        2.0, 4.0, 0.0,
        3.0, 6.0, 1.0,
    };
    const res = try rrqrDecompose(std.testing.allocator, &A, 3, 3, 1e-7);
    defer std.testing.allocator.free(res.pivots);

    try std.testing.expectEqual(@as(u32, 2), res.rank);
}

test "RRQR all zero matrix" {
    var A = [_]f64{
        0.0, 0.0,
        0.0, 0.0,
    };
    const res = try rrqrDecompose(std.testing.allocator, &A, 2, 2, 1e-7);
    defer std.testing.allocator.free(res.pivots);

    try std.testing.expectEqual(@as(u32, 0), res.rank);
}
