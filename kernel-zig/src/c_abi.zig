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

// ---------------------------------------------------------------------------
// Wave 2: 2D Parametric Sketch Constraint Solver Types
// ---------------------------------------------------------------------------

pub const CAD_SKETCH_INVALID_ID: u32 = 0xFFFFFFFF;

pub const CadSketchPoint2D = extern struct {
    id: u32,
    x: f64,
    y: f64,
    is_fixed: u8,
};

pub const CadSketchLine2D = extern struct {
    id: u32,
    start_point_id: u32,
    end_point_id: u32,
};

pub const CadSketchArc2D = extern struct {
    id: u32,
    center_point_id: u32,
    start_point_id: u32,
    end_point_id: u32,
    radius: f64,
};

pub const CadSketchCircle2D = extern struct {
    id: u32,
    center_point_id: u32,
    radius: f64,
};

pub const CadSketchConstraintType = enum(c_int) {
    Coincident = 0,
    Parallel = 1,
    Perpendicular = 2,
    Tangent = 3,
    Horizontal = 4,
    Vertical = 5,
    Equal = 6,
    Symmetric = 7,
    Distance = 8,
    Angle = 9,
    Radius = 10,
};

pub const CadSketchConstraint = extern struct {
    id: u32,
    type: CadSketchConstraintType,
    entity1_id: u32,
    entity2_id: u32,
    entity3_id: u32,
    entity4_id: u32,
    parameter_value: f64,
    is_driving: u8,
};

pub const CadSolveState = enum(c_int) {
    Solved = 0,
    UnderConstrained = 1,
    OverConstrained = 2,
    Conflicting = 3,
};

pub const CadSolverStatus = extern struct {
    solve_state: CadSolveState,
    degrees_of_freedom: u32,
    iterations: u32,
    max_residual: f64,
    updated_coords: ?[*]const f64,
    coord_count: u32,
    conflicting_constraint_ids: ?[*]const u32,
    conflicting_count: u32,
};

// ---------------------------------------------------------------------------
// Wave 3: Feature DAG, Topological Naming & Sub-Shape Tessellation Types
// ---------------------------------------------------------------------------

pub const CadSubshapeType = enum(u4) {
    Vertex = 0,
    Edge = 1,
    Face = 2,
    Shell = 3,
};

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

    pub fn init(
        origin_feature: u16,
        source_sketch_entity: u16,
        op_type: u8,
        subshape_type: CadSubshapeType,
        flags: u4,
        subshape_hash: u16,
    ) CadTopoId {
        return .{
            .fields = .{
                .origin_feature_id = origin_feature,
                .source_sketch_entity_id = source_sketch_entity,
                .op_type = op_type,
                .subshape_type = @intFromEnum(subshape_type),
                .flags = flags,
                .subshape_hash = subshape_hash,
            },
        };
    }
};

pub const CadFeatureType = enum(c_int) {
    Sketch = 0,
    Extrude = 1,
    Revolve = 2,
    BooleanUnion = 3,
    BooleanCut = 4,
    BooleanIntersect = 5,
    Fillet = 6,
    Chamfer = 7,
    Shell = 8,
    Draft = 9,
};

pub const CAD_MAX_FEATURE_PARENTS: usize = 8;
pub const CAD_MAX_FEATURE_TARGETS: usize = 16;

// ---------------------------------------------------------------------------
// Wave 5: Dress-Up Operations & 3D Assembly Mates
// ---------------------------------------------------------------------------

pub const CadFilletMode = enum(c_int) {
    ConstantRadius = 0,
    VariableRadius = 1,
    Chordal = 2,
};

pub const CadFilletOp = extern struct {
    mode: CadFilletMode,
    radius_start: f64,
    radius_end: f64,
    target_edge_count: u32,
    target_edge_ids: [CAD_MAX_FEATURE_TARGETS]CadTopoId,
};

pub const CadChamferMode = enum(c_int) {
    EqualDistance = 0,
    TwoDistances = 1,
    DistanceAngle = 2,
};

pub const CadChamferOp = extern struct {
    mode: CadChamferMode,
    distance1: f64,
    distance2: f64,
    angle_rad: f64,
    target_edge_count: u32,
    target_edge_ids: [CAD_MAX_FEATURE_TARGETS]CadTopoId,
};

pub const CadShellOp = extern struct {
    thickness: f64,
    is_inward: u8,
    open_face_count: u32,
    open_face_ids: [CAD_MAX_FEATURE_TARGETS]CadTopoId,
};

pub const CadDraftOp = extern struct {
    draft_angle_rad: f64,
    pull_direction: CadVec3,
    neutral_plane_point: CadVec3,
    neutral_plane_normal: CadVec3,
    draft_face_count: u32,
    draft_face_ids: [CAD_MAX_FEATURE_TARGETS]CadTopoId,
};

pub const CadFeatureParams = extern union {
    extrude: extern struct {
        distance: f64,
        direction: CadVec3,
        symmetric: u8,
    },
    revolve: extern struct {
        angle_rad: f64,
        axis_origin: CadVec3,
        axis_direction: CadVec3,
    },
    fillet: extern struct {
        radius: f64,
        op: CadFilletOp,
    },
    chamfer: extern struct {
        distance: f64,
        angle_rad: f64,
        op: CadChamferOp,
    },
    shell: CadShellOp,
    draft: CadDraftOp,
    boolean_op: extern struct {
        tool_feature_id: u32,
    },
};

pub const CadFeatureNode = extern struct {
    feature_id: u32,
    type: CadFeatureType,
    is_suppressed: u8,
    parent_count: u32,
    parent_ids: [CAD_MAX_FEATURE_PARENTS]u32,
    target_topo_count: u32,
    target_topo_ids: [CAD_MAX_FEATURE_TARGETS]CadTopoId,
    params: CadFeatureParams,
};

pub const CadTessellatedSolidSlice = extern struct {
    positions: ?[*]const f32,
    vertex_count: u32,
    normals: ?[*]const f32,
    indices: ?[*]const u32,
    triangle_count: u32,
    triangle_to_face_id: ?[*]const u64,
    edge_polylines: ?[*]const f32,
    edge_segment_count: u32,
    edge_to_topo_id: ?[*]const u64,
    bbox_min: CadVec3,
    bbox_max: CadVec3,
};

pub const CadAssemblyMateType = enum(c_int) {
    Coincident = 0,
    Concentric = 1,
    Parallel = 2,
    Distance = 3,
    Angle = 4,
    Gear = 5,
};

pub const CadAssemblyInstance = extern struct {
    instance_id: u32,
    solid_handle: CadSolidHandle,
    is_grounded: u8,
    initial_transform: [16]f32,
    name: [32]u8,
};

pub const CadAssemblyMate = extern struct {
    mate_id: u32,
    type: CadAssemblyMateType,
    instance1_id: u32,
    entity1_topo_id: CadTopoId,
    instance2_id: u32,
    entity2_topo_id: CadTopoId,
    is_anti_aligned: u8,
    parameter_value: f64,
    limits_min: f64,
    limits_max: f64,
};

pub const CadAssemblySolveStatus = extern struct {
    solve_state: CadSolveState,
    total_dof: u32,
    iterations: u32,
    max_residual: f64,
    conflicting_count: u32,
    conflicting_mate_ids: ?[*]const u32,
};

pub const CadLodLevel = enum(c_int) {
    Coarse = 0,
    Medium = 1,
    Fine = 2,
};

