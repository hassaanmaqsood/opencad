const std = @import("std");
const Allocator = std.mem.Allocator;
const Vec3 = @import("../math/vec3.zig").Vec3;
const topo = @import("../topo/mod.zig");

const SoASolid = topo.SoASolid;
const CadTopoId = topo.CadTopoId;
const VertexId = topo.VertexId;
const HalfEdgeId = topo.HalfEdgeId;
const EdgeId = topo.EdgeId;
const LoopId = topo.LoopId;
const FaceId = topo.FaceId;
const ShellId = topo.ShellId;
const SurfaceType = topo.SurfaceType;
const INVALID_ID = topo.INVALID_ID;
const topo_naming = topo.topo_naming;

pub const StepError = error{
    EmptySolid,
    InvalidStepFormat,
    MissingDataSection,
    MissingSolidBrep,
    EntityNotFound,
    ParseError,
    OutOfMemory,
    ManifoldValidationFailed,
};

// ===========================================================================
// STEP Part 21 Exporter
// ===========================================================================

fn writeFmt(out: *std.ArrayList(u8), allocator: Allocator, comptime fmt: []const u8, args: anytype) !void {
    const s = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(s);
    try out.appendSlice(allocator, s);
}

fn writeStr(out: *std.ArrayList(u8), allocator: Allocator, s: []const u8) !void {
    try out.appendSlice(allocator, s);
}

/// Serializes an SoASolid B-Rep into standard ISO-10303-21 STEP text format (AP214/AP242).
pub fn exportStep(allocator: Allocator, solid: *const SoASolid) StepError![]const u8 {
    if (solid.vertices.len == 0 or solid.faces.len == 0) {
        return error.EmptySolid;
    }

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    // 1. ISO-10303-21 Header
    try writeStr(&out, allocator,
        \\ISO-10303-21;
        \\HEADER;
        \\FILE_DESCRIPTION(('OpenCAD B-Rep Solid Model','AP214/AP242 Standard Exchange'),'2;1');
        \\FILE_NAME('opencad_model.step','2026-10-21T00:00:00',('OpenCAD User'),('OpenCAD Project'),'OpenCAD STEP Processor 1.0','OpenCAD','');
        \\FILE_SCHEMA(('AUTOMOTIVE_DESIGN'));
        \\ENDSEC;
        \\DATA;
        \\#1 = APPLICATION_CONTEXT('core data for automotive mechanical design processes');
        \\#2 = APPLICATION_PROTOCOL_DEFINITION('international standard','automotive_design',2000,#1);
        \\#3 = PRODUCT_CONTEXT('',#1,'mechanical');
        \\#4 = PRODUCT('opencad_part','opencad_part','',(#3));
        \\#5 = PRODUCT_DEFINITION_FORMATION('','',#4);
        \\#6 = PRODUCT_DEFINITION('design','',#5,#3);
        \\#7 = PRODUCT_DEFINITION_SHAPE('','',#6);
        \\#8 = SHAPE_DEFINITION_REPRESENTATION(#7,#9);
        \\#9 = ADVANCED_BREP_SHAPE_REPRESENTATION('',(#10,#11),#12);
        \\#11 = AXIS2_PLACEMENT_3D('',#13,#14,#15);
        \\#13 = CARTESIAN_POINT('',(0.,0.,0.));
        \\#14 = DIRECTION('',(0.,0.,1.));
        \\#15 = DIRECTION('',(1.,0.,0.));
        \\#12 = ( GEOMETRIC_REPRESENTATION_CONTEXT(3) GLOBAL_UNCERTAINTY_ASSIGNED_CONTEXT((#16)) GLOBAL_UNIT_ASSIGNED_CONTEXT((#17,#18,#19)) REPRESENTATION_CONTEXT('Context #1','3D Context with UNIT and UNCERTAINTY') );
        \\#16 = UNCERTAINTY_MEASURE_WITH_UNIT(LENGTH_MEASURE(1.E-07),#17,'distance_accuracy_value','confusion accuracy');
        \\#17 = ( LENGTH_UNIT() NAMED_UNIT(*) SI_UNIT(.MILLI.,.METRE.) );
        \\#18 = ( NAMED_UNIT(*) PLANE_ANGLE_UNIT() SI_UNIT($,.RADIAN.) );
        \\#19 = ( NAMED_UNIT(*) SOLID_ANGLE_UNIT() SI_UNIT($,.STERADIAN.) );
        \\
    );

    var next_id: u32 = 20;

    // 2. Export Cartesian Points and Vertex Points
    const v_slice = solid.vertices.slice();
    const pts = v_slice.items(.point);
    const n_verts = solid.vertices.len;

    const v_entity_ids = try allocator.alloc(u32, n_verts);
    defer allocator.free(v_entity_ids);

    for (0..n_verts) |i| {
        const p = pts[i];
        const cp_id = next_id;
        next_id += 1;
        try writeFmt(&out, allocator, "#{d} = CARTESIAN_POINT('',({d:.6},{d:.6},{d:.6}));\n", .{ cp_id, p.x, p.y, p.z });

        const vp_id = next_id;
        next_id += 1;
        try writeFmt(&out, allocator, "#{d} = VERTEX_POINT('',#{d});\n", .{ vp_id, cp_id });

        v_entity_ids[i] = vp_id;
    }

    // 3. Export Edges and Curves
    const he_slice = solid.half_edges.slice();
    const origins = he_slice.items(.origin);
    const nexts = he_slice.items(.next);

    const e_slice = solid.edges.slice();
    const n_edges = solid.edges.len;

    const edge_entity_ids = try allocator.alloc(u32, n_edges);
    defer allocator.free(edge_entity_ids);

    const edge_start_v = try allocator.alloc(VertexId, n_edges);
    defer allocator.free(edge_start_v);

    const edge_end_v = try allocator.alloc(VertexId, n_edges);
    defer allocator.free(edge_end_v);

    for (0..n_edges) |e| {
        const he = e_slice.items(.half_edge)[e];
        const v0 = if (he != INVALID_ID) origins[he] else 0;
        const v1 = if (he != INVALID_ID and nexts[he] != INVALID_ID) origins[nexts[he]] else v0;

        edge_start_v[e] = v0;
        edge_end_v[e] = v1;

        const p0 = pts[v0];
        const p1 = pts[v1];
        var dir = p1.sub(p0);
        const len = dir.norm();
        if (len > 1e-9) {
            dir = dir.scale(1.0 / len);
        } else {
            dir = Vec3.init(1, 0, 0);
        }

        const dir_id = next_id;
        next_id += 1;
        try writeFmt(&out, allocator, "#{d} = DIRECTION('',({d:.6},{d:.6},{d:.6}));\n", .{ dir_id, dir.x, dir.y, dir.z });

        const vec_id = next_id;
        next_id += 1;
        try writeFmt(&out, allocator, "#{d} = VECTOR('',#{d},{d:.6});\n", .{ vec_id, dir_id, if (len > 1e-9) len else 1.0 });

        const line_cp_id = next_id;
        next_id += 1;
        try writeFmt(&out, allocator, "#{d} = CARTESIAN_POINT('',({d:.6},{d:.6},{d:.6}));\n", .{ line_cp_id, p0.x, p0.y, p0.z });

        const line_id = next_id;
        next_id += 1;
        try writeFmt(&out, allocator, "#{d} = LINE('',#{d},#{d});\n", .{ line_id, line_cp_id, vec_id });

        const ec_id = next_id;
        next_id += 1;
        const v0_eid = v_entity_ids[v0];
        const v1_eid = v_entity_ids[v1];
        try writeFmt(&out, allocator, "#{d} = EDGE_CURVE('',#{d},#{d},#{d},.T.);\n", .{ ec_id, v0_eid, v1_eid, line_id });

        edge_entity_ids[e] = ec_id;
    }

    // 4. Export Loops and Face Bounds
    const l_slice = solid.loops.slice();
    const n_loops = solid.loops.len;

    const bound_entity_ids = try allocator.alloc(u32, n_loops);
    defer allocator.free(bound_entity_ids);

    for (0..n_loops) |l| {
        const start_he = l_slice.items(.half_edge)[l];
        var oe_ids = std.ArrayList(u32).empty;
        defer oe_ids.deinit(allocator);

        if (start_he != INVALID_ID) {
            var curr = start_he;
            while (true) {
                const e = he_slice.items(.edge)[curr];
                const u = origins[curr];
                const v = origins[nexts[curr]];

                const is_forward = (e < n_edges and u == edge_start_v[e] and v == edge_end_v[e]);
                const sense_str = if (is_forward) ".T." else ".F.";

                const oe_id = next_id;
                next_id += 1;
                const ec_eid = if (e < n_edges) edge_entity_ids[e] else edge_entity_ids[0];
                try writeFmt(&out, allocator, "#{d} = ORIENTED_EDGE('',*,*,#{d},{s});\n", .{ oe_id, ec_eid, sense_str });
                try oe_ids.append(allocator, oe_id);

                curr = nexts[curr];
                if (curr == start_he or curr >= solid.half_edges.len) break;
            }
        }

        const loop_id = next_id;
        next_id += 1;
        try writeFmt(&out, allocator, "#{d} = EDGE_LOOP('',(", .{loop_id});
        for (oe_ids.items, 0..) |oe, idx| {
            if (idx > 0) try writeStr(&out, allocator, ",");
            try writeFmt(&out, allocator, "#{d}", .{oe});
        }
        try writeStr(&out, allocator, "));\n");

        const bound_id = next_id;
        next_id += 1;
        const is_outer = l_slice.items(.is_outer)[l];
        const bound_type = if (is_outer) "FACE_OUTER_BOUND" else "FACE_BOUND";
        try writeFmt(&out, allocator, "#{d} = {s}('',#{d},.T.);\n", .{ bound_id, bound_type, loop_id });

        bound_entity_ids[l] = bound_id;
    }

    // 5. Export Faces and Surfaces
    const f_slice = solid.faces.slice();
    const normals = f_slice.items(.normal);
    const surfaces = f_slice.items(.surface);
    const outer_loops = f_slice.items(.outer_loop);
    const n_faces = solid.faces.len;

    const face_entity_ids = try allocator.alloc(u32, n_faces);
    defer allocator.free(face_entity_ids);

    for (0..n_faces) |f| {
        const norm = normals[f].normalize();
        const loop_id = outer_loops[f];
        const p0 = if (loop_id < n_loops and l_slice.items(.half_edge)[loop_id] != INVALID_ID)
            pts[origins[l_slice.items(.half_edge)[loop_id]]]
        else
            Vec3.init(0, 0, 0);

        var ref = if (@abs(norm.x) < 0.9) norm.cross(Vec3.init(1, 0, 0)) else norm.cross(Vec3.init(0, 1, 0));
        ref = if (ref.norm() > 1e-6) ref.normalize() else Vec3.init(1, 0, 0);

        const p0_id = next_id;
        next_id += 1;
        try writeFmt(&out, allocator, "#{d} = CARTESIAN_POINT('',({d:.6},{d:.6},{d:.6}));\n", .{ p0_id, p0.x, p0.y, p0.z });

        const norm_id = next_id;
        next_id += 1;
        try writeFmt(&out, allocator, "#{d} = DIRECTION('',({d:.6},{d:.6},{d:.6}));\n", .{ norm_id, norm.x, norm.y, norm.z });

        const ref_id = next_id;
        next_id += 1;
        try writeFmt(&out, allocator, "#{d} = DIRECTION('',({d:.6},{d:.6},{d:.6}));\n", .{ ref_id, ref.x, ref.y, ref.z });

        const axis_id = next_id;
        next_id += 1;
        try writeFmt(&out, allocator, "#{d} = AXIS2_PLACEMENT_3D('',#{d},#{d},#{d});\n", .{ axis_id, p0_id, norm_id, ref_id });

        const surf_id = next_id;
        next_id += 1;
        const surf_type = surfaces[f];
        switch (surf_type) {
            .Cylinder => {
                try writeFmt(&out, allocator, "#{d} = CYLINDRICAL_SURFACE('',#{d},10.0);\n", .{ surf_id, axis_id });
            },
            .Sphere => {
                try writeFmt(&out, allocator, "#{d} = SPHERICAL_SURFACE('',#{d},10.0);\n", .{ surf_id, axis_id });
            },
            .Cone => {
                try writeFmt(&out, allocator, "#{d} = CONICAL_SURFACE('',#{d},10.0,0.5);\n", .{ surf_id, axis_id });
            },
            .Torus => {
                try writeFmt(&out, allocator, "#{d} = TOROIDAL_SURFACE('',#{d},20.0,5.0);\n", .{ surf_id, axis_id });
            },
            else => {
                try writeFmt(&out, allocator, "#{d} = PLANE('',#{d});\n", .{ surf_id, axis_id });
            },
        }

        const face_id = next_id;
        next_id += 1;
        const b_id = if (loop_id < n_loops) bound_entity_ids[loop_id] else bound_entity_ids[0];
        try writeFmt(&out, allocator, "#{d} = ADVANCED_FACE('',(#{d}),#{d},.T.);\n", .{ face_id, b_id, surf_id });

        face_entity_ids[f] = face_id;
    }

    // 6. Export Closed Shell and Manifold Solid B-Rep
    const shell_id = next_id;
    next_id += 1;
    try writeFmt(&out, allocator, "#{d} = CLOSED_SHELL('',(", .{shell_id});
    for (face_entity_ids, 0..) |fid, idx| {
        if (idx > 0) try writeStr(&out, allocator, ",");
        try writeFmt(&out, allocator, "#{d}", .{fid});
    }
    try writeStr(&out, allocator, "));\n");

    // #10 is our MANIFOLD_SOLID_BREP referenced in ADVANCED_BREP_SHAPE_REPRESENTATION (#9)
    try writeFmt(&out, allocator, "#10 = MANIFOLD_SOLID_BREP('solid',#{d});\n", .{shell_id});

    try writeStr(&out, allocator,
        \\ENDSEC;
        \\END-ISO-10303-21;
        \\
    );

    return out.toOwnedSlice(allocator);
}

// ===========================================================================
// STEP Part 21 Lexer & Parser
// ===========================================================================

const RawEntity = struct {
    type_name: []const u8,
    params_str: []const u8,
};

const QuantizedVec3 = struct {
    x: i32,
    y: i32,
    z: i32,
};

fn quantizePoint(p: Vec3, scale: f32) QuantizedVec3 {
    return .{
        .x = @as(i32, @intFromFloat(@round(p.x * scale))),
        .y = @as(i32, @intFromFloat(@round(p.y * scale))),
        .z = @as(i32, @intFromFloat(@round(p.z * scale))),
    };
}

const EdgeKey = struct {
    min_v: VertexId,
    max_v: VertexId,
};

/// Parses an ISO-10303-21 STEP Part 21 text into a watertight SoASolid B-Rep.
pub fn importStep(allocator: Allocator, feature_id: u16, step_text: []const u8) StepError!SoASolid {
    // 1. Locate DATA section
    const data_start = std.mem.indexOf(u8, step_text, "DATA;") orelse return error.MissingDataSection;
    const data_content = step_text[data_start + 5 ..];
    const data_end = std.mem.indexOf(u8, data_content, "ENDSEC;") orelse return error.InvalidStepFormat;
    const data_section = data_content[0..data_end];

    // 2. Lex & parse entity definitions: #<id> = <TYPE>(<params>);
    var entities = std.AutoHashMap(u32, RawEntity).init(allocator);
    defer entities.deinit();

    var idx: usize = 0;
    while (idx < data_section.len) {
        // Skip whitespace and comments
        if (data_section[idx] == '/' and idx + 1 < data_section.len and data_section[idx + 1] == '*') {
            idx += 2;
            while (idx + 1 < data_section.len and !(data_section[idx] == '*' and data_section[idx + 1] == '/')) : (idx += 1) {}
            idx += 2;
            continue;
        }

        if (data_section[idx] == '#') {
            idx += 1;
            const id_start = idx;
            while (idx < data_section.len and std.ascii.isDigit(data_section[idx])) : (idx += 1) {}
            if (idx == id_start) continue;

            const eid = std.fmt.parseInt(u32, data_section[id_start..idx], 10) catch continue;

            // Expect '='
            while (idx < data_section.len and (data_section[idx] == ' ' or data_section[idx] == '\t' or data_section[idx] == '\r' or data_section[idx] == '\n')) : (idx += 1) {}
            if (idx < data_section.len and data_section[idx] == '=') {
                idx += 1;
            } else {
                continue;
            }

            // Read Type Name
            while (idx < data_section.len and (data_section[idx] == ' ' or data_section[idx] == '\t' or data_section[idx] == '\r' or data_section[idx] == '\n')) : (idx += 1) {}
            const type_start = idx;
            while (idx < data_section.len and (std.ascii.isAlphanumeric(data_section[idx]) or data_section[idx] == '_')) : (idx += 1) {}
            const type_name = data_section[type_start..idx];

            // Expect '('
            while (idx < data_section.len and data_section[idx] != '(' and data_section[idx] != ';') : (idx += 1) {}
            if (idx >= data_section.len or data_section[idx] != '(') continue;

            idx += 1;
            const params_start = idx;
            var depth: usize = 1;
            var in_quote = false;

            while (idx < data_section.len and depth > 0) : (idx += 1) {
                const ch = data_section[idx];
                if (ch == '\'' and (idx == 0 or data_section[idx - 1] != '\\')) {
                    in_quote = !in_quote;
                } else if (!in_quote) {
                    if (ch == '(') depth += 1;
                    if (ch == ')') depth -= 1;
                }
            }

            const params_end = if (idx > 0) idx - 1 else params_start;
            const params_str = data_section[params_start..params_end];

            // Advance past ';'
            while (idx < data_section.len and data_section[idx] != ';') : (idx += 1) {}
            if (idx < data_section.len and data_section[idx] == ';') idx += 1;

            try entities.put(eid, RawEntity{
                .type_name = type_name,
                .params_str = params_str,
            });
        } else {
            idx += 1;
        }
    }

    // 3. Locate MANIFOLD_SOLID_BREP or CLOSED_SHELL
    var shell_id: ?u32 = null;
    var it = entities.iterator();
    while (it.next()) |entry| {
        if (std.mem.eql(u8, entry.value_ptr.type_name, "MANIFOLD_SOLID_BREP")) {
            const params = try splitTopLevelParams(allocator, entry.value_ptr.params_str);
            defer allocator.free(params);
            if (params.len >= 2) {
                shell_id = try parseSingleEntityId(params[1]);
                break;
            }
        } else if (std.mem.eql(u8, entry.value_ptr.type_name, "CLOSED_SHELL") and shell_id == null) {
            shell_id = entry.key_ptr.*;
        }
    }

    const target_shell = shell_id orelse return error.MissingSolidBrep;
    const shell_entity = entities.get(target_shell) orelse return error.EntityNotFound;

    const shell_params = try splitTopLevelParams(allocator, shell_entity.params_str);
    defer allocator.free(shell_params);
    if (shell_params.len < 2) return error.ParseError;

    const face_ids = try parseEntityIdsFromList(allocator, shell_params[1]);
    defer allocator.free(face_ids);

    // 4. Construct SoASolid from Face Loops
    var solid = SoASolid.init();
    errdefer solid.deinit(allocator);

    const solid_topo = CadTopoId.init(feature_id, 0, 7, .Shell, 0, 0);
    const solid_id = try solid.addSolid(allocator, solid_topo);
    const shell_topo = CadTopoId.init(feature_id, 0, 7, .Shell, 0, 0);
    const soa_shell_id = try solid.addShell(allocator, solid_id, true, shell_topo);

    var v_map = std.AutoHashMap(QuantizedVec3, VertexId).init(allocator);
    defer v_map.deinit();

    var edge_map = std.AutoHashMap(EdgeKey, HalfEdgeId).init(allocator);
    defer edge_map.deinit();

    for (face_ids, 0..) |fid, f_idx| {
        const face_raw = entities.get(fid) orelse continue;
        const f_params = try splitTopLevelParams(allocator, face_raw.params_str);
        defer allocator.free(f_params);
        if (f_params.len < 3) continue;

        // Resolve Outer Bound Loop
        const bound_ids = try parseEntityIdsFromList(allocator, f_params[1]);
        defer allocator.free(bound_ids);
        if (bound_ids.len == 0) continue;

        const outer_bound_raw = entities.get(bound_ids[0]) orelse continue;
        const b_params = try splitTopLevelParams(allocator, outer_bound_raw.params_str);
        defer allocator.free(b_params);
        if (b_params.len < 2) continue;

        const loop_id = try parseSingleEntityId(b_params[1]);
        const loop_raw = entities.get(loop_id) orelse continue;
        const l_params = try splitTopLevelParams(allocator, loop_raw.params_str);
        defer allocator.free(l_params);
        if (l_params.len < 2) continue;

        const oe_ids = try parseEntityIdsFromList(allocator, l_params[1]);
        defer allocator.free(oe_ids);

        // Resolve 3D Point Loop
        var loop_pts = std.ArrayList(Vec3).empty;
        defer loop_pts.deinit(allocator);

        for (oe_ids) |oe_id| {
            const oe_raw = entities.get(oe_id) orelse continue;
            const oe_params = try splitTopLevelParams(allocator, oe_raw.params_str);
            defer allocator.free(oe_params);
            if (oe_params.len < 5) continue;

            const ec_id = try parseSingleEntityId(oe_params[3]);
            const is_forward = std.mem.indexOf(u8, oe_params[4], ".T.") != null;

            const ec_raw = entities.get(ec_id) orelse continue;
            const ec_params = try splitTopLevelParams(allocator, ec_raw.params_str);
            defer allocator.free(ec_params);
            if (ec_params.len < 4) continue;

            const start_vid = try parseSingleEntityId(ec_params[1]);
            const end_vid = try parseSingleEntityId(ec_params[2]);
            const target_vid = if (is_forward) start_vid else end_vid;

            const vp_raw = entities.get(target_vid) orelse continue;
            const vp_params = try splitTopLevelParams(allocator, vp_raw.params_str);
            defer allocator.free(vp_params);
            if (vp_params.len < 2) continue;

            const cp_id = try parseSingleEntityId(vp_params[1]);
            const cp_raw = entities.get(cp_id) orelse continue;

            const pt = try parseVec3FromTuple(cp_raw.params_str);
            try loop_pts.append(allocator, pt);
        }

        if (loop_pts.items.len < 3) continue;

        // Resolve Face Surface and Normal
        var face_normal = Vec3.init(0, 0, 0);
        var face_surface: SurfaceType = .Plane;

        const surf_id = parseSingleEntityId(f_params[2]) catch null;
        if (surf_id) |sid| {
            if (entities.get(sid)) |s_raw| {
                if (std.mem.eql(u8, s_raw.type_name, "CYLINDRICAL_SURFACE")) {
                    face_surface = .Cylinder;
                } else if (std.mem.eql(u8, s_raw.type_name, "SPHERICAL_SURFACE")) {
                    face_surface = .Sphere;
                } else if (std.mem.eql(u8, s_raw.type_name, "CONICAL_SURFACE")) {
                    face_surface = .Cone;
                } else if (std.mem.eql(u8, s_raw.type_name, "TOROIDAL_SURFACE")) {
                    face_surface = .Torus;
                }

                // Extract normal from AXIS2_PLACEMENT_3D
                const s_params = try splitTopLevelParams(allocator, s_raw.params_str);
                defer allocator.free(s_params);
                if (s_params.len >= 2) {
                    if (parseSingleEntityId(s_params[1]) catch null) |axis_id| {
                        if (entities.get(axis_id)) |ax_raw| {
                            const ax_params = try splitTopLevelParams(allocator, ax_raw.params_str);
                            defer allocator.free(ax_params);
                            if (ax_params.len >= 3) {
                                if (parseSingleEntityId(ax_params[2]) catch null) |dir_id| {
                                    if (entities.get(dir_id)) |dir_raw| {
                                        face_normal = parseVec3FromTuple(dir_raw.params_str) catch Vec3.init(0, 0, 0);
                                        if (face_normal.norm() > 1e-6) face_normal = face_normal.normalize();
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        // Fallback normal calculation if not defined in surface
        if (face_normal.norm() < 1e-6) {
            const p0 = loop_pts.items[0];
            const p1 = loop_pts.items[1];
            const p2 = loop_pts.items[2];
            const cp = (p1.sub(p0)).cross(p2.sub(p0));
            if (cp.norm() > 1e-6) {
                face_normal = cp.normalize();
            } else {
                face_normal = Vec3.init(0, 0, 1);
            }
        }

        // Add Face and Outer Loop
        const f_topo = CadTopoId.init(
            feature_id,
            @intCast(f_idx),
            7,
            .Face,
            0,
            topo_naming.hashFace(face_normal, 0),
        );
        const soa_face_id = try solid.addFace(allocator, soa_shell_id, face_normal, face_surface, f_topo);
        const soa_loop_id = try solid.addLoop(allocator, soa_face_id, true, f_topo);
        solid.faces.slice().items(.outer_loop)[soa_face_id] = soa_loop_id;

        const k = loop_pts.items.len;
        const hes = try allocator.alloc(HalfEdgeId, k);
        defer allocator.free(hes);

        const vids = try allocator.alloc(VertexId, k);
        defer allocator.free(vids);

        for (loop_pts.items, 0..) |p, p_idx| {
            const v_topo = CadTopoId.init(feature_id, @intCast(p_idx), 7, .Vertex, 0, topo_naming.hashPoint(p));
            vids[p_idx] = try findOrAddVertex(&solid, allocator, p, v_topo, &v_map);
            hes[p_idx] = try solid.addHalfEdge(allocator, vids[p_idx], soa_loop_id, f_topo);
        }

        for (0..k) |j| {
            const next_j = (j + 1) % k;
            solid.setNextPrev(hes[j], hes[next_j]);
        }
        solid.loops.slice().items(.half_edge)[soa_loop_id] = hes[0];

        // Match twins via undirected EdgeKey
        for (0..k) |j| {
            const next_j = (j + 1) % k;
            const u = vids[j];
            const v = vids[next_j];
            const key = EdgeKey{ .min_v = @min(u, v), .max_v = @max(u, v) };

            if (edge_map.get(key)) |mate_he| {
                const e_topo = CadTopoId.init(feature_id, @intCast(solid.edges.len), 7, .Edge, 0, 0);
                const edge_id = try solid.addEdge(allocator, hes[j], e_topo);
                solid.setTwins(hes[j], mate_he, edge_id);
                _ = edge_map.remove(key);
            } else {
                try edge_map.put(key, hes[j]);
            }
        }
    }

    solid.updateMetrics();
    solid.validateManifold() catch return error.ManifoldValidationFailed;
    return solid;
}

// ===========================================================================
// Helper Parsers
// ===========================================================================

fn splitTopLevelParams(allocator: Allocator, s: []const u8) ![][]const u8 {
    var list = std.ArrayList([]const u8).empty;
    defer list.deinit(allocator);

    var start: usize = 0;
    var depth: usize = 0;
    var in_quote = false;

    for (s, 0..) |c, i| {
        if (c == '\'' and (i == 0 or s[i - 1] != '\\')) {
            in_quote = !in_quote;
        } else if (!in_quote) {
            if (c == '(') {
                depth += 1;
            } else if (c == ')') {
                if (depth > 0) depth -= 1;
            } else if (c == ',' and depth == 0) {
                const param = std.mem.trim(u8, s[start..i], " \t\r\n");
                try list.append(allocator, param);
                start = i + 1;
            }
        }
    }
    if (start < s.len) {
        const param = std.mem.trim(u8, s[start..], " \t\r\n");
        if (param.len > 0) {
            try list.append(allocator, param);
        }
    }
    return list.toOwnedSlice(allocator);
}

fn parseSingleEntityId(s: []const u8) StepError!u32 {
    const hash_idx = std.mem.indexOfScalar(u8, s, '#') orelse return error.ParseError;
    var end = hash_idx + 1;
    while (end < s.len and std.ascii.isDigit(s[end])) : (end += 1) {}
    if (end <= hash_idx + 1) return error.ParseError;
    return std.fmt.parseInt(u32, s[hash_idx + 1 .. end], 10) catch return error.ParseError;
}

fn parseEntityIdsFromList(allocator: Allocator, s: []const u8) ![]u32 {
    var ids = std.ArrayList(u32).empty;
    defer ids.deinit(allocator);

    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '#') {
            i += 1;
            const start = i;
            while (i < s.len and std.ascii.isDigit(s[i])) : (i += 1) {}
            if (i > start) {
                const val = std.fmt.parseInt(u32, s[start..i], 10) catch continue;
                try ids.append(allocator, val);
            }
        } else {
            i += 1;
        }
    }
    return ids.toOwnedSlice(allocator);
}

fn parseVec3FromTuple(s: []const u8) StepError!Vec3 {
    const open_idx = std.mem.indexOfScalar(u8, s, '(') orelse return error.InvalidStepFormat;
    const close_idx = std.mem.lastIndexOfScalar(u8, s, ')') orelse return error.InvalidStepFormat;
    if (close_idx <= open_idx) return error.InvalidStepFormat;

    const inner = s[open_idx + 1 .. close_idx];
    var it = std.mem.splitScalar(u8, inner, ',');

    const x_str = std.mem.trim(u8, it.next() orelse return error.InvalidStepFormat, " \t\r\n");
    const y_str = std.mem.trim(u8, it.next() orelse return error.InvalidStepFormat, " \t\r\n");
    const z_str = std.mem.trim(u8, it.next() orelse return error.InvalidStepFormat, " \t\r\n");

    const x = std.fmt.parseFloat(f32, x_str) catch return error.ParseError;
    const y = std.fmt.parseFloat(f32, y_str) catch return error.ParseError;
    const z = std.fmt.parseFloat(f32, z_str) catch return error.ParseError;

    return Vec3.init(x, y, z);
}

fn findOrAddVertex(
    solid: *SoASolid,
    allocator: Allocator,
    p: Vec3,
    topo_id: CadTopoId,
    v_map: *std.AutoHashMap(QuantizedVec3, VertexId),
) !VertexId {
    const key = quantizePoint(p, 1000.0);
    if (v_map.get(key)) |vid| {
        return vid;
    }

    var dx: i32 = -1;
    while (dx <= 1) : (dx += 1) {
        var dy: i32 = -1;
        while (dy <= 1) : (dy += 1) {
            var dz: i32 = -1;
            while (dz <= 1) : (dz += 1) {
                const n_key = QuantizedVec3{ .x = key.x + dx, .y = key.y + dy, .z = key.z + dz };
                if (v_map.get(n_key)) |cand_vid| {
                    const cand_pt = solid.vertices.slice().items(.point)[cand_vid];
                    if ((p.sub(cand_pt)).norm() < 1e-3) {
                        return cand_vid;
                    }
                }
            }
        }
    }

    const vid = try solid.addVertex(allocator, p, topo_id);
    try v_map.put(key, vid);
    return vid;
}

// ===========================================================================
// Unit Tests
// ===========================================================================

test "STEP Exporter: Box B-Rep produces valid ISO-10303-21 text" {
    const allocator = std.testing.allocator;
    const extrude = @import("extrude.zig");

    const sq = [_][2]f32{ .{ 0, 0 }, .{ 10, 0 }, .{ 10, 10 }, .{ 0, 10 } };
    var box = try extrude.extrudePolygon(allocator, 1, &sq, 10.0, Vec3.init(0, 0, 1), false);
    defer box.deinit(allocator);

    const step_text = try exportStep(allocator, &box);
    defer allocator.free(step_text);

    try std.testing.expect(std.mem.indexOf(u8, step_text, "ISO-10303-21;") != null);
    try std.testing.expect(std.mem.indexOf(u8, step_text, "FILE_SCHEMA(('AUTOMOTIVE_DESIGN'));") != null);
    try std.testing.expect(std.mem.indexOf(u8, step_text, "MANIFOLD_SOLID_BREP('solid',#") != null);
    try std.testing.expect(std.mem.indexOf(u8, step_text, "CLOSED_SHELL('',(") != null);
    try std.testing.expect(std.mem.indexOf(u8, step_text, "ADVANCED_FACE('',(") != null);
    try std.testing.expect(std.mem.indexOf(u8, step_text, "FACE_OUTER_BOUND('',#") != null);
    try std.testing.expect(std.mem.indexOf(u8, step_text, "EDGE_LOOP('',(") != null);
    try std.testing.expect(std.mem.indexOf(u8, step_text, "EDGE_CURVE('',#") != null);
    try std.testing.expect(std.mem.indexOf(u8, step_text, "VERTEX_POINT('',#") != null);
    try std.testing.expect(std.mem.indexOf(u8, step_text, "CARTESIAN_POINT('',(") != null);
    try std.testing.expect(std.mem.indexOf(u8, step_text, "END-ISO-10303-21;") != null);
}

test "STEP Round-Trip: Box B-Rep export and import preserves volume, area, and Euler invariant" {
    const allocator = std.testing.allocator;
    const extrude = @import("extrude.zig");

    // 1. Create original box: [0, 10] x [0, 20] x [0, 30] => Vol = 6000
    const rect = [_][2]f32{ .{ 0, 0 }, .{ 10, 0 }, .{ 10, 20 }, .{ 0, 20 } };
    var orig_box = try extrude.extrudePolygon(allocator, 10, &rect, 30.0, Vec3.init(0, 0, 1), false);
    defer orig_box.deinit(allocator);

    // 2. Export to STEP
    const step_text = try exportStep(allocator, &orig_box);
    defer allocator.free(step_text);

    // 3. Import from STEP
    var imported_box = try importStep(allocator, 20, step_text);
    defer imported_box.deinit(allocator);

    // 4. Validate Euler-Poincare invariant: V - E + F = 2
    try std.testing.expectEqual(@as(i32, 0), imported_box.calcEulerPoincare(0));
    try imported_box.validateManifold();

    // 5. Validate topology counts: 8 vertices, 12 edges, 6 faces
    try std.testing.expectEqual(@as(usize, 8), imported_box.vertices.len);
    try std.testing.expectEqual(@as(usize, 12), imported_box.edges.len);
    try std.testing.expectEqual(@as(usize, 6), imported_box.faces.len);

    // 6. Validate exact volume and surface area
    try std.testing.expectApproxEqAbs(orig_box.volume, imported_box.volume, 1e-2);
    try std.testing.expectApproxEqAbs(orig_box.surface_area, imported_box.surface_area, 1e-2);
    try std.testing.expectApproxEqAbs(@as(f32, 6000.0), imported_box.volume, 1e-2);
}

test "STEP Round-Trip: Extruded L-shape (non-convex polygon)" {
    const allocator = std.testing.allocator;
    const extrude = @import("extrude.zig");

    const l_pts = [_][2]f32{
        .{ 0.0, 0.0 },
        .{ 6.0, 0.0 },
        .{ 6.0, 2.0 },
        .{ 2.0, 2.0 },
        .{ 2.0, 6.0 },
        .{ 0.0, 6.0 },
    };

    var orig_l = try extrude.extrudePolygon(allocator, 30, &l_pts, 15.0, Vec3.init(0, 0, 1), false);
    defer orig_l.deinit(allocator);

    const step_text = try exportStep(allocator, &orig_l);
    defer allocator.free(step_text);

    var imported_l = try importStep(allocator, 40, step_text);
    defer imported_l.deinit(allocator);

    try std.testing.expectEqual(@as(i32, 0), imported_l.calcEulerPoincare(0));
    try imported_l.validateManifold();

    // 12 vertices, 18 edges, 8 faces
    try std.testing.expectEqual(@as(usize, 12), imported_l.vertices.len);
    try std.testing.expectEqual(@as(usize, 18), imported_l.edges.len);
    try std.testing.expectEqual(@as(usize, 8), imported_l.faces.len);

    try std.testing.expectApproxEqAbs(orig_l.volume, imported_l.volume, 1e-2);
    try std.testing.expectApproxEqAbs(orig_l.surface_area, imported_l.surface_area, 1e-2);
}

test "STEP Round-Trip: Cylinder B-Rep export and import preserves manifold validity" {
    const allocator = std.testing.allocator;
    const extrude = @import("extrude.zig");

    const n_segs = 8;
    const r: f32 = 5.0;
    var cyl_pts: [n_segs][2]f32 = undefined;
    for (0..n_segs) |i| {
        const theta = @as(f32, @floatFromInt(i)) * (2.0 * std.math.pi / @as(f32, @floatFromInt(n_segs)));
        cyl_pts[i] = .{ r * @cos(theta), r * @sin(theta) };
    }

    var orig_cyl = try extrude.extrudePolygon(allocator, 60, &cyl_pts, 20.0, Vec3.init(0, 0, 1), false);
    defer orig_cyl.deinit(allocator);

    const step_text = try exportStep(allocator, &orig_cyl);
    defer allocator.free(step_text);

    var imported_cyl = try importStep(allocator, 70, step_text);
    defer imported_cyl.deinit(allocator);

    try std.testing.expectEqual(@as(i32, 0), imported_cyl.calcEulerPoincare(0));
    try imported_cyl.validateManifold();

    try std.testing.expectEqual(orig_cyl.vertices.len, imported_cyl.vertices.len);
    try std.testing.expectEqual(orig_cyl.edges.len, imported_cyl.edges.len);
    try std.testing.expectEqual(orig_cyl.faces.len, imported_cyl.faces.len);
    try std.testing.expectApproxEqAbs(orig_cyl.volume, imported_cyl.volume, 1e-2);
}

test "STEP Parser: Error handling for malformed input" {
    const allocator = std.testing.allocator;

    const empty_res = importStep(allocator, 50, "");
    try std.testing.expectError(error.MissingDataSection, empty_res);

    const no_solid_res = importStep(allocator, 51, "ISO-10303-21; DATA; #1=CARTESIAN_POINT('',(0,0,0)); ENDSEC;");
    try std.testing.expectError(error.MissingSolidBrep, no_solid_res);
}
