const std = @import("std");

pub const CadStatus = enum(c_int) {
    Ok = 0,
    InvalidArguments = 1,
    OutOfMemory = 2,
    TopologyInvalid = 3,
    GeometryIntersection = 4,
    OpFailed = 5,
    NotImplemented = 6,
};

pub const CadBackend = enum(c_int) {
    Auto = 0,
    COracle = 1,
    NativeZig = 2,
};

pub const CadOpType = enum(c_int) {
    PrimitiveBox = 0,
    PrimitiveCylinder = 1,
    PrimitiveSphere = 2,
    SketchExtrude = 3,
    BooleanUnion = 4,
    BooleanDifference = 5,
    BooleanIntersection = 6,
    Fillet = 7,
    Chamfer = 8,
    Count = 9,
};

pub const CadSolidHandle = u64;
pub const CadFaceHandle = u64;
pub const CadEdgeHandle = u64;

pub const CAD_INVALID_HANDLE: CadSolidHandle = 0;

pub const CadVec3 = extern struct {
    x: f32,
    y: f32,
    z: f32,
};

pub const CadTransform = extern struct {
    m: [16]f32,
};

pub const CadMesh = extern struct {
    positions: ?[*]const f32,
    vertex_count: u32,

    normals: ?[*]const f32,

    indices: ?[*]const u32,
    triangle_count: u32,

    triangle_to_face_id: ?[*]const u32,

    edge_vertices: ?[*]const f32,
    edge_segment_count: u32,

    segment_to_edge_id: ?[*]const u32,

    bbox_min: CadVec3,
    bbox_max: CadVec3,
};

pub const CadBrepStats = extern struct {
    num_vertices: u32,
    num_edges: u32,
    num_wires: u32,
    num_faces: u32,
    num_shells: u32,
    num_solids: u32,
    volume: f32,
    surface_area: f32,
    euler_characteristic: i32,
};
