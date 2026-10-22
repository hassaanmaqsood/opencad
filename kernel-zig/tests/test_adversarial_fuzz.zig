const std = @import("std");
const testing = std.testing;
const cad = @import("cad_kernel");
const c_abi = cad;

test "Adversarial Fuzzing: Malformed and Corrupted STEP Inputs" {
    _ = cad.cad_kernel_init();
    defer _ = cad.cad_kernel_deinit();

    const malformed_cases = [_][]const u8{
        "", // Empty file
        "ISO-10303-21;", // Truncated header
        "HEADER; FILE_DESCRIPTION(('OpenCAD'),'2;1'); ENDSEC; DATA; ENDSEC; END-ISO-10303-21;", // Empty DATA section
        "GARBAGE_BINARY_DATA\x00\xFF\xFE\xFD\x80\x01\x02\x03\x04\x05", // Binary garbage
        "ISO-10303-21; DATA; #1 = CARTESIAN_POINT('', (1.0, 2.0)); ENDSEC; END-ISO-10303-21;", // Incomplete point
        "ISO-10303-21; DATA; #1 = NON_EXISTENT_ENTITY('test'); ENDSEC; END-ISO-10303-21;", // Unknown entity
        "ISO-10303-21; DATA; #1 = ADVANCED_BREP_SHAPE_REPRESENTATION('', (#2), #3); ENDSEC; END-ISO-10303-21;", // Dangling forward refs
        "ISO-10303-21; DATA; #1 = VERTEX_POINT('', #1); ENDSEC; END-ISO-10303-21;", // Self cycle
    };

    for (malformed_cases) |case_str| {
        // Assert that importing malformed input never crashes or panics; returns 0
        const handle = cad.cad_wasm_step_import(case_str.ptr, case_str.len);
        try testing.expectEqual(@as(cad.CadSolidHandle, 0), handle);
    }

    // Pseudo-random fuzzer: 500 mutated strings
    var prng = std.Random.DefaultPrng.init(0xDEADBEEF);
    const rand = prng.random();

    var fuzz_buf: [256]u8 = undefined;
    for (0..500) |_| {
        const len = rand.uintLessThan(usize, fuzz_buf.len);
        for (0..len) |i| {
            fuzz_buf[i] = rand.int(u8);
        }
        const h = cad.cad_wasm_step_import(&fuzz_buf, len);
        try testing.expectEqual(@as(cad.CadSolidHandle, 0), h);
    }
}

test "Adversarial Fuzzing: Degenerate Zero-Area and Singular Sketches" {
    _ = cad.cad_kernel_init();
    defer _ = cad.cad_kernel_deinit();

    // 1. Degenerate zero-length line: Start and End coincident at (0, 0)
    var points = [_]c_abi.CadSketchPoint2D{
        .{ .id = 1, .x = 0.0, .y = 0.0, .is_fixed = 1 },
        .{ .id = 2, .x = 0.0, .y = 0.0, .is_fixed = 0 },
    };
    const lines = [_]c_abi.CadSketchLine2D{
        .{ .id = 10, .start_point_id = 1, .end_point_id = 2 },
    };

    // Conflicting constraints: Horizontal and Vertical simultaneously
    const constraints = [_]c_abi.CadSketchConstraint{
        .{ .id = 100, .type = .Horizontal, .entity1_id = 10, .entity2_id = 0, .entity3_id = 0, .entity4_id = 0, .parameter_value = 0, .is_driving = 1 },
        .{ .id = 101, .type = .Vertical, .entity1_id = 10, .entity2_id = 0, .entity3_id = 0, .entity4_id = 0, .parameter_value = 0, .is_driving = 1 },
        .{ .id = 102, .type = .Distance, .entity1_id = 1, .entity2_id = 2, .entity3_id = 0, .entity4_id = 0, .parameter_value = 10.0, .is_driving = 1 },
    };

    var out_status: c_abi.CadSolverStatus = undefined;

    const st = cad.cad_sketch_solve(
        &points,
        points.len,
        &lines,
        lines.len,
        null,
        0,
        null,
        0,
        &constraints,
        constraints.len,
        50,
        1e-6,
        &out_status,
    );

    try testing.expectEqual(c_abi.CadStatus.Ok, st);
    // Solver must gracefully identify over-constrained or conflicting state without division by zero or NaN
    try testing.expect(
        out_status.solve_state == .Conflicting or
        out_status.solve_state == .OverConstrained or
        out_status.solve_state == .UnderConstrained
    );
    for (points) |pt| {
        try testing.expect(!std.math.isNan(pt.x));
        try testing.expect(!std.math.isNan(pt.y));
    }
}

test "Adversarial Fuzzing: Resource Sandboxing and Memory Exhaustion" {
    _ = cad.cad_kernel_init();
    defer _ = cad.cad_kernel_deinit();

    // Set tight sandbox limit (512 KiB)
    const tight_limits = c_abi.CadKernelLimits{
        .max_wasm_memory_bytes = 512 * 1024,
        .max_solver_iterations = 25,
        .max_boolean_faces = 100,
        .eval_timeout_ms = 100,
    };
    try testing.expectEqual(c_abi.CadStatus.Ok, cad.cad_set_kernel_limits(&tight_limits));

    // 1. Allocation beyond sandbox must fail cleanly with null, zero leak
    const huge_alloc = cad.cad_shared_alloc(10 * 1024 * 1024);
    try testing.expectEqual(@as(?[*]u8, null), huge_alloc);

    // 2. Permitted allocation within sandbox must succeed and free cleanly
    const safe_alloc = cad.cad_shared_alloc(128 * 1024);
    try testing.expect(safe_alloc != null);
    cad.cad_shared_free(safe_alloc, 128 * 1024);

    // Restore standard limits
    const reset_limits = c_abi.CadKernelLimits{
        .max_wasm_memory_bytes = 256 * 1024 * 1024,
        .max_solver_iterations = 500,
        .max_boolean_faces = 100_000,
        .eval_timeout_ms = 5000,
    };
    try testing.expectEqual(c_abi.CadStatus.Ok, cad.cad_set_kernel_limits(&reset_limits));
}
