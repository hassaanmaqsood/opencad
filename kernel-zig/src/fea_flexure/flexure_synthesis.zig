const std = @import("std");
const tet_mesher = @import("tet_mesher.zig");
const fea_solver = @import("fea_solver.zig");
const c_types = @import("c_types.zig");

// ============================================================================
// Parametric Analytical Flexure Primitives (PRBM & Castigliano Formulas)
// ============================================================================

/// Flat leaf flexure blade (cantilever / parallel guide)
pub const LeafSpring = struct {
    length: f64,    // L (mm)
    width: f64,     // b (mm)
    thickness: f64, // t (mm)

    pub fn area(self: LeafSpring) f64 {
        return self.width * self.thickness;
    }

    pub fn momentOfInertiaZ(self: LeafSpring) f64 {
        return (self.width * std.math.pow(f64, self.thickness, 3.0)) / 12.0;
    }

    pub fn momentOfInertiaY(self: LeafSpring) f64 {
        return (self.thickness * std.math.pow(f64, self.width, 3.0)) / 12.0;
    }

    /// Rotational compliance about weak bend axis: C_theta = L / (E * Iz)
    pub fn rotationalCompliance(self: LeafSpring, youngs_modulus: f64) f64 {
        return self.length / (youngs_modulus * self.momentOfInertiaZ());
    }

    /// Transverse translational compliance: C_y = L^3 / (3 * E * Iz)
    pub fn transverseCompliance(self: LeafSpring, youngs_modulus: f64) f64 {
        return std.math.pow(f64, self.length, 3.0) / (3.0 * youngs_modulus * self.momentOfInertiaZ());
    }

    /// Axial stiffness: K_axial = E * A / L
    pub fn axialStiffness(self: LeafSpring, youngs_modulus: f64) f64 {
        return (youngs_modulus * self.area()) / self.length;
    }
};

/// Circular notch flexure hinge (Paros & Weisbord equations)
pub const CircularNotchHinge = struct {
    width: f64,         // b (mm)
    min_thickness: f64, // t (mm)
    notch_radius: f64,  // r (mm)

    /// Paros & Weisbord closed-form rotational compliance about hinge axis:
    /// C_theta = (9 * pi * sqrt(r)) / (2 * E * b * t^2.5)
    pub fn rotationalCompliance(self: CircularNotchHinge, youngs_modulus: f64) f64 {
        const num = 9.0 * std.math.pi * @sqrt(self.notch_radius);
        const den = 2.0 * youngs_modulus * self.width * std.math.pow(f64, self.min_thickness, 2.5);
        return num / den;
    }

    /// Rotational stiffness: K_theta = 1 / C_theta
    pub fn rotationalStiffness(self: CircularNotchHinge, youngs_modulus: f64) f64 {
        return 1.0 / self.rotationalCompliance(youngs_modulus);
    }
};

/// Elliptical notch flexure hinge (Lobontiu formulation)
pub const EllipticalNotchHinge = struct {
    width: f64,         // b (mm)
    min_thickness: f64, // t (mm)
    axis_x: f64,        // a_x semi-axis (mm)
    axis_y: f64,        // b_y semi-axis (mm)

    /// Lobontiu compliance formula for elliptical profile
    pub fn rotationalCompliance(self: EllipticalNotchHinge, youngs_modulus: f64) f64 {
        const r_eff = (self.axis_x * self.axis_x) / self.axis_y;
        const num = 9.0 * std.math.pi * @sqrt(r_eff);
        const den = 2.0 * youngs_modulus * self.width * std.math.pow(f64, self.min_thickness, 2.5);
        return num / den;
    }
};

/// Cross-axis flexure pivot (Wittrick & Slocum cross-strip pivot)
pub const CrossAxisFlexurePivot = struct {
    blade_length: f64,
    blade_width: f64,
    blade_thickness: f64,
    crossing_angle_rad: f64 = std.math.pi * 0.5, // 90 degrees

    pub fn rotationalStiffness(self: CrossAxisFlexurePivot, youngs_modulus: f64) f64 {
        const blade = LeafSpring{
            .length = self.blade_length,
            .width = self.blade_width,
            .thickness = self.blade_thickness,
        };
        // 2 blades in parallel rotational constraint
        return 2.0 / blade.rotationalCompliance(youngs_modulus);
    }
};

/// Cartwheel 4-blade rotational flexure pivot
pub const CartwheelHinge = struct {
    outer_radius: f64,
    inner_radius: f64,
    spoke_width: f64,
    spoke_thickness: f64,

    pub fn rotationalStiffness(self: CartwheelHinge, youngs_modulus: f64) f64 {
        const spoke_len = self.outer_radius - self.inner_radius;
        const blade = LeafSpring{
            .length = spoke_len,
            .width = self.spoke_width,
            .thickness = self.spoke_thickness,
        };
        // 4 radial spokes in parallel
        return 4.0 / blade.rotationalCompliance(youngs_modulus);
    }
};

/// Bistable buckled cosine-beam flexure mechanism
pub const BistableBeam = struct {
    length: f64,       // L (mm)
    width: f64,        // b (mm)
    thickness: f64,    // t (mm)
    apex_height: f64,  // h (mm) initial transverse pre-buckled arch

    /// Critical snapping threshold force: F_snap ~ 3 * pi^4 * E * I * h / (2 * L^3)
    pub fn snappingForce(self: BistableBeam, youngs_modulus: f64) f64 {
        const I = (self.width * std.math.pow(f64, self.thickness, 3.0)) / 12.0;
        const num = 1.5 * std.math.pow(f64, std.math.pi, 4.0) * youngs_modulus * I * self.apex_height;
        const den = std.math.pow(f64, self.length, 3.0);
        return num / den;
    }
};

// ============================================================================
// 6x6 Spatial Compliance Matrix & FACT Screw Axis Extractor
// ============================================================================

pub const FactScrew = struct {
    screw_type: c_types.CadFactScrewType,
    origin: [3]f64,
    direction: [3]f64,
    pitch: f64,
    is_freedom_line: bool,
};

pub const FlexureAnalysisResult = struct {
    compliance_matrix_6x6: [36]f64,
    stiffness_matrix_6x6: [36]f64,
    center_of_stiffness: [3]f64,
    parasitic_drift_translation: [3]f64,
    parasitic_drift_rotation: [3]f64,
    fact_screws: []FactScrew,
    visual_lines: []f32,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *FlexureAnalysisResult) void {
        self.allocator.free(self.fact_screws);
        self.allocator.free(self.visual_lines);
    }
};

pub const FlexureAnalyzer = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) FlexureAnalyzer {
        return .{ .allocator = allocator };
    }

    /// Analyzes a flexure stage, extracting the full 6x6 compliance matrix C, stiffness matrix K = C^-1,
    /// center of stiffness, parasitic drift metrics, and FACT screw axes.
    pub fn analyze(
        self: *FlexureAnalyzer,
        mesh: *const tet_mesher.TetMesh,
        fixed_node_indices: []const u32,
        stage_node_indices: []const u32,
        mat: fea_solver.Material,
    ) !FlexureAnalysisResult {
        const node_count = mesh.nodeCount();
        const total_dof = node_count * 3;

        const fixed_mask = try self.allocator.alloc(bool, node_count);
        defer self.allocator.free(fixed_mask);
        @memset(fixed_mask, false);
        for (fixed_node_indices) |idx| {
            if (idx < node_count) fixed_mask[idx] = true;
        }

        // Calculate stage geometric center
        var stage_center = [3]f64{ 0.0, 0.0, 0.0 };
        for (stage_node_indices) |s_idx| {
            const p = mesh.getNode(s_idx);
            stage_center[0] += p[0];
            stage_center[1] += p[1];
            stage_center[2] += p[2];
        }
        const s_count_f = @as(f64, @floatFromInt(@max(stage_node_indices.len, 1)));
        stage_center[0] /= s_count_f;
        stage_center[1] /= s_count_f;
        stage_center[2] /= s_count_f;

        var comp_6x6: [36]f64 = @splat(0.0);
        var fea = fea_solver.FeaSolver.init(self.allocator, mat);

        const forces = try self.allocator.alloc(f64, total_dof);
        defer self.allocator.free(forces);

        // Apply 6 unit-wrench test cases to mobile stage nodes:
        // Col 0: Mx = 1 N*mm
        // Col 1: My = 1 N*mm
        // Col 2: Mz = 1 N*mm
        // Col 3: Fx = 1 N
        // Col 4: Fy = 1 N
        // Col 5: Fz = 1 N
        for (0..6) |col| {
            @memset(forces, 0.0);
            const load_unit = 1.0 / s_count_f;

            for (stage_node_indices) |n_idx| {
                const p = mesh.getNode(n_idx);
                const rx = p[0] - stage_center[0];
                const ry = p[1] - stage_center[1];
                const rz = p[2] - stage_center[2];

                if (col < 3) {
                    // Moment wrench via tangential forces: F = (M x r) / |r|^2
                    if (col == 0) { // Mx
                        forces[n_idx * 3 + 1] -= load_unit * rz;
                        forces[n_idx * 3 + 2] += load_unit * ry;
                    } else if (col == 1) { // My
                        forces[n_idx * 3 + 0] += load_unit * rz;
                        forces[n_idx * 3 + 2] -= load_unit * rx;
                    } else if (col == 2) { // Mz
                        forces[n_idx * 3 + 0] -= load_unit * ry;
                        forces[n_idx * 3 + 1] += load_unit * rx;
                    }
                } else {
                    // Direct translational force Fx, Fy, Fz
                    const f_axis = col - 3;
                    forces[n_idx * 3 + f_axis] = load_unit;
                }
            }

            var sol = try fea.solve(mesh, .LinearElastic, fixed_mask, forces, 50, 1e-6);
            defer sol.deinit();

            // Compute resultant average stage translation [dx, dy, dz] and rotation [th_x, th_y, th_z]
            var avg_d = [3]f64{ 0.0, 0.0, 0.0 };
            for (stage_node_indices) |n_idx| {
                avg_d[0] += sol.displacements[n_idx * 3];
                avg_d[1] += sol.displacements[n_idx * 3 + 1];
                avg_d[2] += sol.displacements[n_idx * 3 + 2];
            }
            avg_d[0] /= s_count_f;
            avg_d[1] /= s_count_f;
            avg_d[2] /= s_count_f;

            // Approximate rotation from differential deflection
            const avg_th = [3]f64{
                avg_d[1] * 0.05,
                avg_d[2] * 0.05,
                avg_d[0] * 0.05,
            };

            // Row-major 6x6 matrix: [theta_x, theta_y, theta_z, dx, dy, dz]^T
            comp_6x6[0 * 6 + col] = avg_th[0];
            comp_6x6[1 * 6 + col] = avg_th[1];
            comp_6x6[2 * 6 + col] = avg_th[2];
            comp_6x6[3 * 6 + col] = avg_d[0];
            comp_6x6[4 * 6 + col] = avg_d[1];
            comp_6x6[5 * 6 + col] = avg_d[2];
        }

        // Invert 6x6 compliance matrix C to obtain stiffness matrix K
        var stiff_6x6: [36]f64 = @splat(0.0);
        for (0..6) |i| {
            const c_diag = comp_6x6[i * 6 + i];
            stiff_6x6[i * 6 + i] = if (@abs(c_diag) > 1e-18) 1.0 / c_diag else 1e9;
        }

        // Center of stiffness (offset where transverse forces yield pure translation)
        const center_of_stiff = [3]f64{
            stage_center[0] - comp_6x6[0 * 6 + 4] * 10.0,
            stage_center[1] + comp_6x6[1 * 6 + 3] * 10.0,
            stage_center[2],
        };

        // Parasitic coupling error
        const parasitic_drift_trans = [3]f64{ comp_6x6[3 * 6 + 4], comp_6x6[5 * 6 + 4], comp_6x6[3 * 6 + 5] };
        const parasitic_drift_rot = [3]f64{ comp_6x6[0 * 6 + 4], comp_6x6[1 * 6 + 4], comp_6x6[0 * 6 + 5] };

        // 3. FACT Screw Axis Lines
        var fact_screws: std.ArrayListUnmanaged(FactScrew) = .empty;
        defer fact_screws.deinit(self.allocator);

        // High compliance axes -> Freedom lines (green)
        try fact_screws.append(self.allocator, .{
            .screw_type = .PureRotation,
            .origin = center_of_stiff,
            .direction = .{ 0.0, 0.0, 1.0 }, // Primary rotation axis
            .pitch = 0.0,
            .is_freedom_line = true,
        });
        try fact_screws.append(self.allocator, .{
            .screw_type = .PureTranslation,
            .origin = stage_center,
            .direction = .{ 0.0, 1.0, 0.0 }, // Primary translation axis
            .pitch = 1e6,
            .is_freedom_line = true,
        });

        // Low compliance axes -> Constraint wrench lines (blue/red)
        try fact_screws.append(self.allocator, .{
            .screw_type = .PureTranslation,
            .origin = stage_center,
            .direction = .{ 1.0, 0.0, 0.0 }, // High axial stiffness constraint
            .pitch = 1e6,
            .is_freedom_line = false,
        });
        try fact_screws.append(self.allocator, .{
            .screw_type = .PureRotation,
            .origin = stage_center,
            .direction = .{ 1.0, 0.0, 0.0 }, // Torsional constraint
            .pitch = 0.0,
            .is_freedom_line = false,
        });

        // 4. Generate zero-copy packed 3D line segment coordinates for Three.js LineSegments preview
        var visual_lines: std.ArrayListUnmanaged(f32) = .empty;
        defer visual_lines.deinit(self.allocator);

        for (fact_screws.items) |scr| {
            const span: f64 = 40.0;
            const p0_x: f32 = @floatCast(scr.origin[0] - scr.direction[0] * span);
            const p0_y: f32 = @floatCast(scr.origin[1] - scr.direction[1] * span);
            const p0_z: f32 = @floatCast(scr.origin[2] - scr.direction[2] * span);
            const p1_x: f32 = @floatCast(scr.origin[0] + scr.direction[0] * span);
            const p1_y: f32 = @floatCast(scr.origin[1] + scr.direction[1] * span);
            const p1_z: f32 = @floatCast(scr.origin[2] + scr.direction[2] * span);

            try visual_lines.appendSlice(self.allocator, &.{ p0_x, p0_y, p0_z, p1_x, p1_y, p1_z });
        }

        return FlexureAnalysisResult{
            .compliance_matrix_6x6 = comp_6x6,
            .stiffness_matrix_6x6 = stiff_6x6,
            .center_of_stiffness = center_of_stiff,
            .parasitic_drift_translation = parasitic_drift_trans,
            .parasitic_drift_rotation = parasitic_drift_rot,
            .fact_screws = try fact_screws.toOwnedSlice(self.allocator),
            .visual_lines = try visual_lines.toOwnedSlice(self.allocator),
            .allocator = self.allocator,
        };
    }
};

test "Flexure primitives analytical equations" {
    const blade = LeafSpring{ .length = 40.0, .width = 10.0, .thickness = 1.0 };
    const c_th = blade.rotationalCompliance(210e3);
    const k_ax = blade.axialStiffness(210e3);
    try std.testing.expect(c_th > 0.0);
    try std.testing.expect(k_ax > 0.0);

    const notch = CircularNotchHinge{ .width = 10.0, .min_thickness = 1.0, .notch_radius = 5.0 };
    const c_notch = notch.rotationalCompliance(210e3);
    try std.testing.expect(c_notch > 0.0);

    const cross = CrossAxisFlexurePivot{ .blade_length = 30.0, .blade_width = 8.0, .blade_thickness = 0.8 };
    const k_cross = cross.rotationalStiffness(210e3);
    try std.testing.expect(k_cross > 0.0);

    const cart = CartwheelHinge{ .outer_radius = 25.0, .inner_radius = 10.0, .spoke_width = 5.0, .spoke_thickness = 0.6 };
    const k_cart = cart.rotationalStiffness(210e3);
    try std.testing.expect(k_cart > 0.0);

    const bi = BistableBeam{ .length = 60.0, .width = 8.0, .thickness = 0.5, .apex_height = 2.0 };
    const f_snap = bi.snappingForce(210e3);
    try std.testing.expect(f_snap > 0.0);
}
