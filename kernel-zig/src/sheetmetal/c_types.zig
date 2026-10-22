const std = @import("std");

pub const CadStatus = enum(c_int) {
    Ok = 0,
    InvalidArguments = 1,
    OutOfMemory = 2,
    TopologyInvalid = 3,
    GeometryIntersection = 4,
    OpFailed = 5,
    NotImplemented = 6,
    Timeout = 7,
    NonManifold = 8,
    LimitExceeded = 9,
};

pub const CadSolidHandle = u64;

pub const CadTopoId = extern union {
    raw: u64,
    fields: packed struct(u64) {
        origin_feature_id: u16,
        source_sketch_entity_id: u16,
        op_type: u8,
        subshape_type: u4,
        flags: u4,
        subshape_hash: u16,
    },
    pub const INVALID: CadTopoId = .{ .raw = 0 };
};

pub const CadReliefType = enum(c_int) {
    Tear = 0,
    Rectangular = 1,
    Obround = 2,
    None = 3,
};

pub const CadSheetMetalConfig = extern struct {
    thickness: f64,
    bend_radius: f64,
    k_factor: f64,
    relief_type: CadReliefType,
    relief_width: f64,
    relief_depth: f64,
};

pub const CadHemType = enum(c_int) {
    Closed = 0,
    Open = 1,
    Teardrop = 2,
    Rolled = 3,
};

pub const CadFlangeOp = extern struct {
    target_edge_id: CadTopoId,
    length: f64,
    angle_rad: f64,
    offset_start: f64,
    offset_end: f64,
    config: CadSheetMetalConfig,
};

pub const CadHemOp = extern struct {
    target_edge_id: CadTopoId,
    hem_type: CadHemType,
    length: f64,
    gap: f64,
    config: CadSheetMetalConfig,
};

pub const CadBendDirection = enum(c_int) {
    Up = 0,
    Down = 1,
};

pub const CadBendCenterline = extern struct {
    start_point: [2]f64,
    end_point: [2]f64,
    bend_angle_rad: f64,
    bend_radius: f64,
    direction: CadBendDirection,
    bend_allowance: f64,
    source_bend_edge: CadTopoId,
};

pub const CadFlatPattern = extern struct {
    flat_solid: CadSolidHandle,
    bend_lines: ?[*]const CadBendCenterline,
    bend_line_count: u32,
    bounding_box_2d: [4]f64,
    total_cut_length: f64,
    total_area: f64,
};
