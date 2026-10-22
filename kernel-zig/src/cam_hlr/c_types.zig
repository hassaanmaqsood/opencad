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

pub const CadProjectionType = enum(c_int) {
    Top = 0,
    Front = 1,
    Right = 2,
    Isometric = 3,
    Section = 4,
    Custom = 5,
};

pub const CadCurveVisibility = enum(c_int) {
    Visible = 0,
    Hidden = 1,
    Silhouette = 2,
    Centerline = 3,
    Hatch = 4,
};

pub const CadDrawingCurve = extern struct {
    visibility: CadCurveVisibility,
    points_2d: ?[*]const f32,
    point_count: u32,
    source_topo_id: CadTopoId,
};

pub const CadSectionPlane = extern struct {
    origin: [3]f64,
    normal: [3]f64,
    hatch_angle_rad: f64,
    hatch_spacing: f64,
};

pub const CadDrawingViewParams = extern struct {
    proj_type: CadProjectionType,
    camera_dir: [3]f64,
    up_dir: [3]f64,
    scale: f64,
    include_hidden_lines: bool,
    include_smooth_silhouettes: bool,
    include_centerlines: bool,
    section_cut: CadSectionPlane,
};

pub const CadDrawingView = extern struct {
    curves: ?[*]const CadDrawingCurve,
    curve_count: u32,
    view_bbox: [4]f64,
    section_cut_area: f64,
};

pub const Cad3mfProductionOptions = extern struct {
    part_number: ?[*:0]const u8,
    material_name: ?[*:0]const u8,
    layer_height_mm: f64,
    include_thumbnail: bool,
    use_compression: bool,
};

pub const CadNestingMode = enum(c_int) {
    BuildPlate2D = 0,
    SinterBox3D = 1,
};

pub const CadNestingConfig = extern struct {
    mode: CadNestingMode,
    build_volume_dx: f64,
    build_volume_dy: f64,
    build_volume_dz: f64,
    part_spacing_mm: f64,
    margin_boundary_mm: f64,
    allow_rotation_xy: bool,
    allow_rotation_3d: bool,
};

pub const CadNestInstance = extern struct {
    solid: CadSolidHandle,
    transform_4x4: [16]f32,
    fits_in_volume: bool,
};

pub const CadNestingResult = extern struct {
    instances: ?[*]const CadNestInstance,
    instance_count: u32,
    packing_density_percent: f64,
    max_height_reached_mm: f64,
    parts_packed_count: u32,
    parts_overflow_count: u32,
};

pub const CadToolpathStrategy = enum(c_int) {
    Contour2D = 0,
    Pocket2D = 1,
    AdaptiveClearing = 2,
    DrillCycle = 3,
    Surface3D = 4,
};

pub const CadToolDefinition = extern struct {
    tool_number: u32,
    diameter_mm: f64,
    corner_radius_mm: f64,
    flute_length_mm: f64,
    flute_count: u32,
};

pub const CadCamParams = extern struct {
    strategy: CadToolpathStrategy,
    tool: CadToolDefinition,
    spindle_rpm: f64,
    feed_cutting_mmpm: f64,
    feed_plunge_mmpm: f64,
    stepover_mm: f64,
    stepdown_mm: f64,
    stock_to_leave: f64,
    clearance_height_mm: f64,
    retract_height_mm: f64,
    target_face_id: CadTopoId,
};

pub const CadCamToolpath = extern struct {
    strategy: CadToolpathStrategy,
    gcode_text: ?[*:0]const u8,
    gcode_len: usize,
    estimated_time_seconds: f64,
    total_path_length_mm: f64,
    rapid_distance_mm: f64,
    visual_points: ?[*]const f32,
    visual_point_count: u32,
};
