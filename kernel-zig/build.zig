const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

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

    // WebAssembly target (wasm32-freestanding)
    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
    });

    const wasm_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = wasm_target,
        .optimize = .ReleaseFast,
    });

    const wasm = b.addExecutable(.{
        .name = "cad_kernel",
        .root_module = wasm_mod,
    });
    wasm.entry = .disabled;
    wasm.rdynamic = true;

    b.installArtifact(wasm);

    // Copy compiled wasm to web-app/public/cad_kernel.wasm
    const copy_cmd = b.addSystemCommand(&[_][]const u8{ "cp" });
    copy_cmd.addFileArg(wasm.getEmittedBin());
    copy_cmd.addArg("../web-app/public/cad_kernel.wasm");
    b.getInstallStep().dependOn(&copy_cmd.step);
}
