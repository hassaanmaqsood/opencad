const std = @import("std");
const cad = @import("cad_kernel");
const c_abi = cad.c_abi;
const AssemblySolver = cad.assembly_solver.AssemblySolver;
const CadAssemblyInstance = c_abi.CadAssemblyInstance;
const CadAssemblyMate = c_abi.CadAssemblyMate;
const CadAssemblySolveStatus = c_abi.CadAssemblySolveStatus;
const CadTopoId = c_abi.CadTopoId;
const se3 = cad.se3;

test "Assembly Solver: Grounded base and ungrounded coincident mate" {
    const allocator = std.testing.allocator;
    var solver = AssemblySolver.init(allocator);

    var instances = [_]CadAssemblyInstance{
        .{
            .instance_id = 1,
            .solid_handle = 0,
            .is_grounded = 1,
            .initial_transform = [16]f32{
                1, 0, 0, 0,
                0, 1, 0, 0,
                0, 0, 1, 0,
                0, 0, 0, 1,
            },
            .name = @splat(0),
        },
        .{
            .instance_id = 2,
            .solid_handle = 0,
            .is_grounded = 0,
            .initial_transform = [16]f32{
                1, 0, 0, 0,
                0, 1, 0, 0,
                0, 0, 1, 0,
                10, 20, 30, 1,
            },
            .name = @splat(0),
        },
    };

    // Coincident mate between instance 1 and instance 2
    const mate = CadAssemblyMate{
        .mate_id = 100,
        .type = .Coincident,
        .instance1_id = 1,
        .entity1_topo_id = CadTopoId.init(1, 0, 1, .Face, 2, 0), // CAP_TOP (0, 0, 1)
        .instance2_id = 2,
        .entity2_topo_id = CadTopoId.init(2, 0, 1, .Face, 1, 0), // CAP_BOTTOM (0, 0, -1)
        .is_anti_aligned = 1,
        .parameter_value = 0.0,
        .limits_min = 0.0,
        .limits_max = 0.0,
    };

    var out_transforms: [32]f32 = @splat(0.0);
    var status: CadAssemblySolveStatus = undefined;

    const res = try solver.solve(
        &instances,
        &[_]CadAssemblyMate{mate},
        100,
        1e-6,
        &out_transforms,
        &status,
    );

    try std.testing.expectEqual(c_abi.CadStatus.Ok, res);
    try std.testing.expect(status.max_residual <= 1e-5);
    try std.testing.expect(status.solve_state == .Solved or status.solve_state == .UnderConstrained);
}

test "Assembly Solver: Concentric and Distance Mate" {
    const allocator = std.testing.allocator;
    var solver = AssemblySolver.init(allocator);

    var instances = [_]CadAssemblyInstance{
        .{
            .instance_id = 1,
            .solid_handle = 0,
            .is_grounded = 1,
            .initial_transform = [16]f32{
                1, 0, 0, 0,
                0, 1, 0, 0,
                0, 0, 1, 0,
                0, 0, 0, 1,
            },
            .name = @splat(0),
        },
        .{
            .instance_id = 2,
            .solid_handle = 0,
            .is_grounded = 0,
            .initial_transform = [16]f32{
                1, 0, 0, 0,
                0, 1, 0, 0,
                0, 0, 1, 0,
                5, 5, 20, 1,
            },
            .name = @splat(0),
        },
    };

    const mates = [_]CadAssemblyMate{
        .{
            .mate_id = 1,
            .type = .Concentric,
            .instance1_id = 1,
            .entity1_topo_id = CadTopoId.init(1, 0, 1, .Face, 2, 0),
            .instance2_id = 2,
            .entity2_topo_id = CadTopoId.init(2, 0, 1, .Face, 2, 0),
            .is_anti_aligned = 0,
            .parameter_value = 0.0,
            .limits_min = 0.0,
            .limits_max = 0.0,
        },
        .{
            .mate_id = 2,
            .type = .Distance,
            .instance1_id = 1,
            .entity1_topo_id = CadTopoId.init(1, 0, 1, .Face, 2, 0),
            .instance2_id = 2,
            .entity2_topo_id = CadTopoId.init(2, 0, 1, .Face, 1, 0),
            .is_anti_aligned = 1,
            .parameter_value = 45.0,
            .limits_min = 0.0,
            .limits_max = 0.0,
        },
    };

    var out_transforms: [32]f32 = @splat(0.0);
    var status: CadAssemblySolveStatus = undefined;

    const res = try solver.solve(
        &instances,
        &mates,
        100,
        1e-6,
        &out_transforms,
        &status,
    );

    try std.testing.expectEqual(c_abi.CadStatus.Ok, res);
    try std.testing.expect(status.max_residual <= 1e-4);
}
