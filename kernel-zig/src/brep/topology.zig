const std = @import("std");
const Allocator = std.mem.Allocator;
pub const Vec3 = @import("../math/vec3.zig").Vec3;
const c_abi = @import("../c_abi.zig");

pub const Vertex = struct {
    point: Vec3,
};

pub const Edge = struct {
    v_start: u32,
    v_end: u32,
    id: u32,
};

pub const Wire = struct {
    edge_indices: std.ArrayList(u32),

    pub fn init() Wire {
        return .{ .edge_indices = std.ArrayList(u32).empty };
    }

    pub fn deinit(self: *Wire, allocator: Allocator) void {
        self.edge_indices.deinit(allocator);
    }
};

pub const SurfaceType = enum {
    Plane,
    Cylinder,
};

pub const Face = struct {
    id: u32,
    surface: SurfaceType,
    normal: Vec3,
    wire: Wire,

    pub fn deinit(self: *Face, allocator: Allocator) void {
        self.wire.deinit(allocator);
    }
};

pub const Shell = struct {
    faces: std.ArrayList(Face),

    pub fn init() Shell {
        return .{ .faces = std.ArrayList(Face).empty };
    }

    pub fn deinit(self: *Shell, allocator: Allocator) void {
        for (self.faces.items) |*face| {
            face.deinit(allocator);
        }
        self.faces.deinit(allocator);
    }
};

pub const Solid = struct {
    id: u64,
    shell: Shell,
    vertices: std.ArrayList(Vertex),
    edges: std.ArrayList(Edge),
    volume: f32,
    surface_area: f32,

    pub fn init(id: u64) Solid {
        return .{
            .id = id,
            .shell = Shell.init(),
            .vertices = std.ArrayList(Vertex).empty,
            .edges = std.ArrayList(Edge).empty,
            .volume = 0.0,
            .surface_area = 0.0,
        };
    }

    pub fn deinit(self: *Solid, allocator: Allocator) void {
        self.shell.deinit(allocator);
        self.vertices.deinit(allocator);
        self.edges.deinit(allocator);
    }

    pub fn getStats(self: *const Solid) c_abi.CadBrepStats {
        const v_count: u32 = @intCast(self.vertices.items.len);
        const e_count: u32 = @intCast(self.edges.items.len);
        const f_count: u32 = @intCast(self.shell.faces.items.len);
        const euler: i32 = @as(i32, @intCast(v_count)) - @as(i32, @intCast(e_count)) + @as(i32, @intCast(f_count));

        return .{
            .num_vertices = v_count,
            .num_edges = e_count,
            .num_wires = f_count,
            .num_faces = f_count,
            .num_shells = 1,
            .num_solids = 1,
            .volume = self.volume,
            .surface_area = self.surface_area,
            .euler_characteristic = euler,
        };
    }
};

pub const topo = @import("../topo/mod.zig");
pub const ops = @import("../ops/mod.zig");

test {
    _ = topo;
    _ = ops;
}



