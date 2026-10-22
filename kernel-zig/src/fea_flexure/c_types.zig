//! C-ABI types for FEA and Flexure Synthesis (mirrors abi/cad_kernel.h)

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
pub const CadTopoId = extern struct {
    raw: u64,
};

pub const CadFeaMode = enum(c_int) {
    LinearElastic = 0,
    CorotationalNonlinear = 1,
};

pub const CadFeaElementType = enum(c_int) {
    Tet4 = 4,
    Tet10 = 10,
};

pub const CadMaterialProps = extern struct {
    youngs_modulus_pa: f64,
    poisson_ratio: f64,
    yield_strength_pa: f64,
    density: f64,
};

pub const CadBcType = enum(c_int) {
    FixedFace = 0,
    ForceVector = 1,
    MomentVector = 2,
    PrescribedDisplacement = 3,
};

pub const CadBoundaryCondition = extern struct {
    type: CadBcType,
    target_topo_id: CadTopoId,
    value: [3]f64,
};

pub const CadFeaMeshParams = extern struct {
    element_type: CadFeaElementType,
    max_element_size_m: f64,
    growth_rate: f64,
    optimize_aspect_ratio: bool,
};

pub const CadTetMesh = extern struct {
    node_positions: ?[*]const f32,
    node_count: u32,
    element_indices: ?[*]const u32,
    element_count: u32,
    element_type: CadFeaElementType,
};

pub const CAD_FEA_NUM_MODE_SHAPES: usize = 6;

pub const CadFeaModeShape = extern struct {
    natural_frequency_hz: f64,
    eigenmode_displacements: ?[*]const f32,
};

pub const CadFeaResultSlice = extern struct {
    node_count: u32,
    element_count: u32,
    u_xyz: ?[*]const f32,
    von_mises_stresses: ?[*]const f32,
    safety_factor_map: ?[*]const f32,
    max_displacement_m: f32,
    max_von_mises_pa: f32,
    min_safety_factor: f32,
    mode_shapes: [CAD_FEA_NUM_MODE_SHAPES]CadFeaModeShape,
    mode_shape_count: u32,
    mesh: CadTetMesh,
};

pub const CadFactScrewType = enum(c_int) {
    PureRotation = 0,
    PureTranslation = 1,
    GeneralScrew = 2,
};

pub const CadFactScrewAxis = extern struct {
    type: CadFactScrewType,
    origin: [3]f64,
    direction: [3]f64,
    pitch: f64,
    is_freedom_line: bool,
};

pub const CadFlexureAnalysis = extern struct {
    compliance_matrix_6x6: [36]f64,
    stiffness_matrix_6x6: [36]f64,
    center_of_stiffness: [3]f64,
    parasitic_drift_translation: [3]f64,
    parasitic_drift_rotation: [3]f64,
    fact_screw_axes: ?[*]const CadFactScrewAxis,
    fact_screw_axis_count: u32,
    fact_visual_lines: ?[*]const f32,
    fact_visual_line_count: u32,
};
