const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const strip = b.option(bool, "strip", "Strip debug symbols") orelse (optimize == std.builtin.OptimizeMode.ReleaseFast);

    const kernel_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const test_step = b.step("test", "Run all CAD kernel unit tests with leak checks");

    const test_files = [_][]const u8{
        "tests/test_brep.zig",
        "tests/test_tessellate.zig",
        "tests/test_router.zig",
        "tests/test_c_abi.zig",
        "tests/test_sketch_solver.zig",
        "tests/test_topo_invariants.zig",
        "tests/test_nurbs.zig",
        "tests/test_ssi.zig",
        "tests/test_primitives_ops.zig",
        "tests/test_booleans.zig",
        "tests/test_assembly_solver.zig",
        "tests/test_adversarial_fuzz.zig",
        "tests/test_wave7_manufacturing.zig",
        "tests/test_wave8_fea_flexure.zig",
    };

    inline for (test_files) |test_path| {
        const test_mod = b.createModule(.{
            .root_source_file = b.path(test_path),
            .target = target,
            .optimize = optimize,
        });
        test_mod.addImport("cad_kernel", kernel_mod);

        const t = b.addTest(.{
            .root_module = test_mod,
        });
        const run_t = b.addRunArtifact(t);
        test_step.dependOn(&run_t.step);
    }

    const main_test = b.addTest(.{
        .root_module = kernel_mod,
    });
    const run_main_test = b.addRunArtifact(main_test);
    test_step.dependOn(&run_main_test.step);

    // Harden step: Run all test runners with ReleaseSafe (integer bounds, overflow checks enabled)
    const harden_step = b.step("harden", "Run all CAD kernel unit tests compiled in ReleaseSafe mode");

    const kernel_mod_harden = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = .ReleaseSafe,
    });

    inline for (test_files) |test_path| {
        const test_mod_harden = b.createModule(.{
            .root_source_file = b.path(test_path),
            .target = target,
            .optimize = .ReleaseSafe,
        });
        test_mod_harden.addImport("cad_kernel", kernel_mod_harden);

        const t_harden = b.addTest(.{
            .root_module = test_mod_harden,
        });
        const run_t_harden = b.addRunArtifact(t_harden);
        harden_step.dependOn(&run_t_harden.step);
    }

    const main_test_harden = b.addTest(.{
        .root_module = kernel_mod_harden,
    });
    const run_main_test_harden = b.addRunArtifact(main_test_harden);
    harden_step.dependOn(&run_main_test_harden.step);

    // WebAssembly target (wasm32-freestanding)
    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
    });

    const wasm_targets = [_]struct {
        name: []const u8,
        src: []const u8,
        out_name: []const u8,
    }{
        .{ .name = "cad_kernel", .src = "src/main.zig", .out_name = "cad_kernel.wasm" },
        .{ .name = "cad_core", .src = "src/main.zig", .out_name = "cad_core.wasm" },
        .{ .name = "cad_sheetmetal", .src = "src/sheetmetal/wasm.zig", .out_name = "cad_sheetmetal.wasm" },
        .{ .name = "cad_fea_flexure", .src = "src/fea_flexure/wasm.zig", .out_name = "cad_fea_flexure.wasm" },
        .{ .name = "cad_implicit_ntop", .src = "src/implicit/wasm.zig", .out_name = "cad_implicit_ntop.wasm" },
        .{ .name = "cad_mfg_cam", .src = "src/cam_hlr/wasm.zig", .out_name = "cad_mfg_cam.wasm" },
        .{ .name = "cad_ast", .src = "src/ast/wasm.zig", .out_name = "cad_ast.wasm" },
    };

    inline for (wasm_targets) |wt| {
        const wasm_mod = b.createModule(.{
            .root_source_file = b.path(wt.src),
            .target = wasm_target,
            .optimize = .ReleaseFast,
            .strip = strip,
        });

        const wasm = b.addExecutable(.{
            .name = wt.name,
            .root_module = wasm_mod,
        });
        wasm.entry = .disabled;
        wasm.rdynamic = true;

        b.installArtifact(wasm);

        const copy_cmd = b.addSystemCommand(&[_][]const u8{ "cp" });
        copy_cmd.addFileArg(wasm.getEmittedBin());
        copy_cmd.addArg(b.fmt("../web-app/public/{s}", .{wt.out_name}));
        b.getInstallStep().dependOn(&copy_cmd.step);
    }
}
