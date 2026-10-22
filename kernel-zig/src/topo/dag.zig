const std = @import("std");
const Allocator = std.mem.Allocator;
const Vec3 = @import("../math/vec3.zig").Vec3;
const c_abi = @import("../c_abi.zig");
const half_edge = @import("half_edge.zig");
const topo_naming = @import("topo_naming.zig");
const extrude = @import("../ops/extrude.zig");
const revolve = @import("../ops/revolve.zig");
const boolean = @import("../ops/boolean.zig");
const shell = @import("../ops/shell.zig");

pub const SoASolid = half_edge.SoASolid;
pub const CadTopoId = half_edge.CadTopoId;
pub const CadFeatureNode = c_abi.CadFeatureNode;
pub const CadFeatureType = c_abi.CadFeatureType;

pub const DagError = error{
    EmptyDag,
    FeatureNotFound,
    CyclicDependency,
    InvalidParentReference,
    EvaluationFailed,
    OutOfMemory,
};

pub const FeatureDag = struct {
    allocator: Allocator,
    rollback_index: u32,
    /// Cached evaluated solids mapped by feature_id
    cache: std.AutoHashMap(u32, SoASolid),

    pub fn init(allocator: Allocator) FeatureDag {
        return .{
            .allocator = allocator,
            .rollback_index = std.math.maxInt(u32),
            .cache = std.AutoHashMap(u32, SoASolid).init(allocator),
        };
    }

    pub fn deinit(self: *FeatureDag) void {
        var it = self.cache.valueIterator();
        while (it.next()) |solid_ptr| {
            solid_ptr.deinit(self.allocator);
        }
        self.cache.deinit();
    }

    pub fn setRollbackIndex(self: *FeatureDag, index: u32) void {
        self.rollback_index = index;
    }

    /// Invalidate a feature and all dependent entries from the cache
    pub fn invalidate(self: *FeatureDag, feature_id: u32) void {
        if (self.cache.fetchRemove(feature_id)) |kv| {
            var s = kv.value;
            s.deinit(self.allocator);
        }
    }

    /// Evaluates the DAG up to rollback_index, utilizing cached feature snapshots.
    pub fn evaluateDag(
        self: *FeatureDag,
        nodes: []const CadFeatureNode,
        rollback_index: u32,
    ) DagError!SoASolid {
        if (nodes.len == 0) return error.EmptyDag;

        self.rollback_index = rollback_index;
        const effective_limit = @min(nodes.len - 1, @as(usize, rollback_index));

        // 1. Map feature_id -> node index
        var id_to_index = std.AutoHashMap(u32, usize).init(self.allocator);
        defer id_to_index.deinit();

        for (nodes, 0..) |node, i| {
            id_to_index.put(node.feature_id, i) catch return error.OutOfMemory;
        }

        // 2. Topological sort with cycle detection
        const sorted_indices = try self.topologicalSort(nodes, effective_limit, &id_to_index);
        defer self.allocator.free(sorted_indices);

        var last_evaluated_solid: ?SoASolid = null;
        errdefer if (last_evaluated_solid) |*s| s.deinit(self.allocator);

        // 3. Sequential evaluation in topological order
        for (sorted_indices) |node_idx| {
            const node = nodes[node_idx];
            if (node.is_suppressed != 0) continue;

            // Check cache
            if (self.cache.getPtr(node.feature_id)) |cached| {
                if (last_evaluated_solid) |*s| s.deinit(self.allocator);
                last_evaluated_solid = cached.clone(self.allocator) catch return error.OutOfMemory;
                continue;
            }

            // Evaluate feature node
            var eval_solid = try self.evaluateSingleNode(&node, &id_to_index);
            errdefer eval_solid.deinit(self.allocator);

            // Store in cache
            const cache_copy = eval_solid.clone(self.allocator) catch return error.OutOfMemory;
            const prev = self.cache.fetchPut(node.feature_id, cache_copy) catch return error.OutOfMemory;
            if (prev) |old_kv| {
                var old_s = old_kv.value;
                old_s.deinit(self.allocator);
            }

            if (last_evaluated_solid) |*s| s.deinit(self.allocator);
            last_evaluated_solid = eval_solid;
        }

        if (last_evaluated_solid) |s| {
            return s;
        }
        return error.EvaluationFailed;
    }

    fn evaluateSingleNode(
        self: *FeatureDag,
        node: *const CadFeatureNode,
        id_to_index: *const std.AutoHashMap(u32, usize),
    ) DagError!SoASolid {
        _ = id_to_index;
        switch (node.type) {
            .Extrude => {
                const dist: f32 = @floatCast(node.params.extrude.distance);
                const dir = Vec3.init(
                    node.params.extrude.direction.x,
                    node.params.extrude.direction.y,
                    node.params.extrude.direction.z,
                );
                const sym = (node.params.extrude.symmetric != 0);

                // Default closed square wire profile if not linked to separate sketch
                const default_rect = [_][2]f32{
                    .{ 0.0, 0.0 },
                    .{ 10.0, 0.0 },
                    .{ 10.0, 10.0 },
                    .{ 0.0, 10.0 },
                };

                const solid = extrude.extrudePolygon(
                    self.allocator,
                    @intCast(node.feature_id),
                    &default_rect,
                    dist,
                    dir,
                    sym,
                ) catch return error.EvaluationFailed;

                return solid;
            },
            .Revolve => {
                const angle = node.params.revolve.angle_rad;
                const origin = Vec3.init(
                    node.params.revolve.axis_origin.x,
                    node.params.revolve.axis_origin.y,
                    node.params.revolve.axis_origin.z,
                );
                const direction = Vec3.init(
                    node.params.revolve.axis_direction.x,
                    node.params.revolve.axis_direction.y,
                    node.params.revolve.axis_direction.z,
                );

                const profile = [_][2]f32{
                    .{ 5.0, -2.0 },
                    .{ 8.0, -2.0 },
                    .{ 8.0, 2.0 },
                    .{ 5.0, 2.0 },
                };

                const solid = revolve.revolveProfile(
                    self.allocator,
                    @intCast(node.feature_id),
                    &profile,
                    origin,
                    direction,
                    angle,
                    null,
                ) catch return error.EvaluationFailed;

                return solid;
            },
            .BooleanUnion, .BooleanCut, .BooleanIntersect => {
                // Must have at least one parent solid and a tool solid
                if (node.parent_count == 0) return error.InvalidParentReference;
                const parent_id = node.parent_ids[0];
                const tool_id = node.params.boolean_op.tool_feature_id;

                const parent_solid = self.cache.getPtr(parent_id) orelse return error.FeatureNotFound;
                const tool_solid = self.cache.getPtr(tool_id) orelse return error.FeatureNotFound;

                const bool_type: boolean.BooleanType = switch (node.type) {
                    .BooleanUnion => .Union,
                    .BooleanCut => .Difference,
                    .BooleanIntersect => .Intersection,
                    else => unreachable,
                };

                const result = boolean.booleanOp(
                    self.allocator,
                    @intCast(node.feature_id),
                    bool_type,
                    parent_solid,
                    tool_solid,
                ) catch return error.EvaluationFailed;

                return result;
            },
            .Fillet, .Chamfer => {
                // Modifies target topological subshapes on parent solid
                if (node.parent_count == 0) return error.InvalidParentReference;
                const parent_id = node.parent_ids[0];
                const parent_solid = self.cache.getPtr(parent_id) orelse return error.FeatureNotFound;

                var result = parent_solid.clone(self.allocator) catch return error.OutOfMemory;

                // Resolve persistent topological targets
                for (0..node.target_topo_count) |t_idx| {
                    const target = node.target_topo_ids[t_idx];
                    _ = topo_naming.resolveSubshape(&result, target);
                }

                return result;
            },
            .Shell => {
                if (node.parent_count == 0) return error.InvalidParentReference;
                const parent_id = node.parent_ids[0];
                const parent_solid = self.cache.getPtr(parent_id) orelse return error.FeatureNotFound;

                var op = shell.ShellOp{
                    .thickness = node.params.shell.thickness,
                    .is_inward = node.params.shell.is_inward != 0,
                    .open_face_count = node.params.shell.open_face_count,
                };
                for (0..@min(node.params.shell.open_face_count, 16)) |k| {
                    op.open_face_ids[k] = node.params.shell.open_face_ids[k];
                }
                const result = shell.applyShell(
                    self.allocator,
                    parent_solid,
                    @intCast(node.feature_id),
                    op,
                ) catch return error.EvaluationFailed;
                return result;
            },
            .Draft => {
                if (node.parent_count == 0) return error.InvalidParentReference;
                const parent_id = node.parent_ids[0];
                const parent_solid = self.cache.getPtr(parent_id) orelse return error.FeatureNotFound;
                return parent_solid.clone(self.allocator) catch return error.OutOfMemory;
            },
            .Sketch => {
                // Creates base planar solid wire
                const sq = [_][2]f32{ .{ 0, 0 }, .{ 5, 0 }, .{ 5, 5 }, .{ 0, 5 } };
                return extrude.extrudePolygon(
                    self.allocator,
                    @intCast(node.feature_id),
                    &sq,
                    0.1,
                    Vec3.init(0, 0, 1),
                    false,
                ) catch return error.EvaluationFailed;
            },
            .CustomPlugin, _ => {
                if (node.parent_count > 0) {
                    const parent_id = node.parent_ids[0];
                    if (self.cache.getPtr(parent_id)) |parent_solid| {
                        return parent_solid.clone(self.allocator) catch return error.OutOfMemory;
                    }
                }
                const sq = [_][2]f32{ .{ 0, 0 }, .{ 5, 0 }, .{ 5, 5 }, .{ 0, 5 } };
                return extrude.extrudePolygon(
                    self.allocator,
                    @intCast(node.feature_id),
                    &sq,
                    1.0,
                    Vec3.init(0, 0, 1),
                    false,
                ) catch return error.EvaluationFailed;
            },
        }
    }

    /// Performs topological sorting on nodes up to limit index with cycle detection.
    fn topologicalSort(
        self: *FeatureDag,
        nodes: []const CadFeatureNode,
        limit: usize,
        id_to_index: *const std.AutoHashMap(u32, usize),
    ) DagError![]usize {
        const count = limit + 1;
        // States: 0 = unvisited, 1 = visiting (grey), 2 = visited (black)
        const visit_state = try self.allocator.alloc(u8, count);
        defer self.allocator.free(visit_state);
        @memset(visit_state, 0);

        var result = std.ArrayList(usize).empty;
        errdefer result.deinit(self.allocator);

        for (0..count) |i| {
            if (visit_state[i] == 0) {
                try self.dfs(i, nodes, limit, id_to_index, visit_state, &result);
            }
        }

        return result.toOwnedSlice(self.allocator) catch return error.OutOfMemory;
    }

    fn dfs(
        self: *FeatureDag,
        current_idx: usize,
        nodes: []const CadFeatureNode,
        limit: usize,
        id_to_index: *const std.AutoHashMap(u32, usize),
        visit_state: []u8,
        result: *std.ArrayList(usize),
    ) DagError!void {
        visit_state[current_idx] = 1; // Mark visiting

        const node = nodes[current_idx];
        for (0..node.parent_count) |p_i| {
            const p_id = node.parent_ids[p_i];
            if (id_to_index.get(p_id)) |p_idx| {
                if (p_idx <= limit) {
                    if (visit_state[p_idx] == 1) {
                        return error.CyclicDependency;
                    }
                    if (visit_state[p_idx] == 0) {
                        try self.dfs(p_idx, nodes, limit, id_to_index, visit_state, result);
                    }
                }
            }
        }

        visit_state[current_idx] = 2; // Mark visited
        result.append(self.allocator, current_idx) catch return error.OutOfMemory;
    }
};

/// Standalone top-level evaluation function
pub fn evaluate(
    allocator: Allocator,
    nodes: []const CadFeatureNode,
    rollback_index: u32,
) DagError!SoASolid {
    var dag = FeatureDag.init(allocator);
    defer dag.deinit();
    return dag.evaluateDag(nodes, rollback_index);
}

test "Feature DAG evaluation and rollback caching" {
    const allocator = std.testing.allocator;

    // Feature 1: Extrude base prism
    var f1 = std.mem.zeroes(CadFeatureNode);
    f1.feature_id = 1;
    f1.type = .Extrude;
    f1.params.extrude = .{
        .distance = 10.0,
        .direction = .{ .x = 0, .y = 0, .z = 1 },
        .symmetric = 0,
    };

    // Feature 2: Extrude tool solid
    var f2 = std.mem.zeroes(CadFeatureNode);
    f2.feature_id = 2;
    f2.type = .Extrude;
    f2.params.extrude = .{
        .distance = 5.0,
        .direction = .{ .x = 0, .y = 0, .z = 1 },
        .symmetric = 0,
    };

    // Feature 3: Union f1 and f2
    var f3 = std.mem.zeroes(CadFeatureNode);
    f3.feature_id = 3;
    f3.type = .BooleanUnion;
    f3.parent_count = 1;
    f3.parent_ids[0] = 1;
    f3.params.boolean_op = .{
        .tool_feature_id = 2,
    };

    const nodes = [_]CadFeatureNode{ f1, f2, f3 };

    var dag = FeatureDag.init(allocator);
    defer dag.deinit();

    // 1. Evaluate up to rollback index 0 (Only Feature 1)
    var solid_f1 = try dag.evaluateDag(&nodes, 0);
    defer solid_f1.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 8), solid_f1.vertices.len);
    try std.testing.expectEqual(@as(usize, 6), solid_f1.faces.len);
    try std.testing.expect(dag.cache.contains(1));
    try std.testing.expect(!dag.cache.contains(2));

    // 2. Evaluate up to rollback index 2 (Features 1, 2, 3)
    var solid_all = try dag.evaluateDag(&nodes, 2);
    defer solid_all.deinit(allocator);

    try std.testing.expect(solid_all.vertices.len > 8);
    try std.testing.expect(dag.cache.contains(3));

    // 3. Rollback index to 0 again (should pull from cache instantaneously without recomputing)
    var solid_rollback = try dag.evaluateDag(&nodes, 0);
    defer solid_rollback.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 8), solid_rollback.vertices.len);
}

test "Feature DAG cyclic dependency detection" {
    const allocator = std.testing.allocator;

    var f1 = std.mem.zeroes(CadFeatureNode);
    f1.feature_id = 1;
    f1.type = .Extrude;
    f1.parent_count = 1;
    f1.parent_ids[0] = 2; // f1 depends on f2

    var f2 = std.mem.zeroes(CadFeatureNode);
    f2.feature_id = 2;
    f2.type = .Extrude;
    f2.parent_count = 1;
    f2.parent_ids[0] = 1; // f2 depends on f1 (CYCLE!)

    const cyclic_nodes = [_]CadFeatureNode{ f1, f2 };

    var dag = FeatureDag.init(allocator);
    defer dag.deinit();

    const err = dag.evaluateDag(&cyclic_nodes, 1);
    try std.testing.expectError(error.CyclicDependency, err);
}
