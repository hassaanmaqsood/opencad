const std = @import("std");

pub fn build(b: *std.Build) void {
    var wasm_target_query: std.Target.Query = .{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
    };
    const wasm_features = std.Target.wasm.Feature;
    wasm_target_query.cpu_features_add.addFeature(@intFromEnum(wasm_features.atomics));
    wasm_target_query.cpu_features_add.addFeature(@intFromEnum(wasm_features.bulk_memory));
    const target = b.resolveTargetQuery(wasm_target_query);
    const optimize = b.standardOptimizeOption(.{});

    const wasm_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const wasm = b.addExecutable(.{
        .name = "ext_field_canary",
        .root_module = wasm_mod,
    });

    wasm.entry = .disabled;
    wasm.rdynamic = true;
    wasm.import_memory = true;
    wasm.export_memory = true;
    wasm.shared_memory = true;
    wasm.initial_memory = 128 * 65536;
    wasm.max_memory = 2048 * 65536;

    b.installArtifact(wasm);
}
