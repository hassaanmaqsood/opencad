/**
 * @file cad_kernel.h
 * @brief Zero-copy C ABI specification for open-parametric-cad.
 *
 * This header defines the binary interface exposed by the CAD kernel
 * (both native Zig kernel and C++ differential oracle).
 * Memory structures are designed for zero-copy views in WebAssembly
 * (Float32Array positions/normals, Uint32Array indices and triangle-to-face mappings)
 * allowing the Web Worker to pass geometry directly to Three.js without JSON serialization.
 */

#ifndef CAD_KERNEL_H
#define CAD_KERNEL_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ------------------------------------------------------------------------- */
/* Error Codes & Return Status                                               */
/* ------------------------------------------------------------------------- */
typedef enum cad_status_e {
    CAD_STATUS_OK = 0,
    CAD_STATUS_ERROR_INVALID_ARGUMENT = 1,
    CAD_STATUS_ERROR_OUT_OF_MEMORY = 2,
    CAD_STATUS_ERROR_TOPOLOGY_INVALID = 3,
    CAD_STATUS_ERROR_GEOMETRY_INTERSECTION = 4,
    CAD_STATUS_ERROR_OP_FAILED = 5,
    CAD_STATUS_ERROR_NOT_IMPLEMENTED = 6,
    CAD_STATUS_ERROR_TIMEOUT = 7,
    CAD_STATUS_ERROR_NON_MANIFOLD = 8,
    CAD_STATUS_ERROR_LIMIT_EXCEEDED = 9
} cad_status_t;

/* Deterministic Error Code Short Aliases */
#define CAD_ERR_OK CAD_STATUS_OK
#define CAD_ERR_INVALID_ARGUMENT CAD_STATUS_ERROR_INVALID_ARGUMENT
#define CAD_ERR_OOM CAD_STATUS_ERROR_OUT_OF_MEMORY
#define CAD_ERR_TOPOLOGY_INVALID CAD_STATUS_ERROR_TOPOLOGY_INVALID
#define CAD_ERR_GEOMETRY_INTERSECTION CAD_STATUS_ERROR_GEOMETRY_INTERSECTION
#define CAD_ERR_OP_FAILED CAD_STATUS_ERROR_OP_FAILED
#define CAD_ERR_NOT_IMPLEMENTED CAD_STATUS_ERROR_NOT_IMPLEMENTED
#define CAD_ERR_TIMEOUT CAD_STATUS_ERROR_TIMEOUT
#define CAD_ERR_NON_MANIFOLD CAD_STATUS_ERROR_NON_MANIFOLD
#define CAD_ERR_LIMIT_EXCEEDED CAD_STATUS_ERROR_LIMIT_EXCEEDED

/* ------------------------------------------------------------------------- */
/* Feature Flag & Backend Routing                                            */
/* ------------------------------------------------------------------------- */
typedef enum cad_backend_e {
    CAD_BACKEND_AUTO = 0,       /**< Dispatches based on module readiness */
    CAD_BACKEND_C_ORACLE = 1,   /**< Force OpenCASCADE/C++ reference */
    CAD_BACKEND_NATIVE_ZIG = 2  /**< Force native Zig implementation */
} cad_backend_t;

typedef enum cad_op_type_e {
    CAD_OP_PRIMITIVE_BOX = 0,
    CAD_OP_PRIMITIVE_CYLINDER = 1,
    CAD_OP_PRIMITIVE_SPHERE = 2,
    CAD_OP_SKETCH_EXTRUDE = 3,
    CAD_OP_BOOLEAN_UNION = 4,
    CAD_OP_BOOLEAN_DIFFERENCE = 5,
    CAD_OP_BOOLEAN_INTERSECTION = 6,
    CAD_OP_FILLET = 7,
    CAD_OP_CHAMFER = 8,
    CAD_OP_COUNT = 9
} cad_op_type_t;

/* ------------------------------------------------------------------------- */
/* Opaque Handles                                                            */
/* ------------------------------------------------------------------------- */
typedef uint64_t cad_solid_handle_t;
typedef uint64_t cad_face_handle_t;
typedef uint64_t cad_edge_handle_t;

#define CAD_INVALID_HANDLE 0ULL

/* ------------------------------------------------------------------------- */
/* 3D Vector & Transform Structures                                          */
/* ------------------------------------------------------------------------- */
typedef struct cad_vec3_s {
    float x;
    float y;
    float z;
} cad_vec3_t;

typedef struct cad_transform_s {
    float m[16]; /**< 4x4 column-major affine transform matrix */
} cad_transform_t;

/* ------------------------------------------------------------------------- */
/* Zero-Copy Flat Tessellation Buffer Slices                                 */
/* ------------------------------------------------------------------------- */

/**
 * @brief Zero-copy triangular mesh representation.
 * Pointers reference contiguous flat buffers in kernel memory.
 * In WebAssembly, these memory addresses map directly to JavaScript
 * Float32Array and Uint32Array views without copying or serialization.
 */
typedef struct cad_mesh_s {
    /* Vertex positions: [x0, y0, z0, x1, y1, z1, ...] (Float32Array) */
    const float* positions;
    uint32_t vertex_count;       /**< Number of vertices (positions len = vertex_count * 3) */

    /* Vertex normals: [nx0, ny0, nz0, nx1, ny1, nz1, ...] (Float32Array) */
    const float* normals;

    /* Triangle index buffer: [i0, i1, i2, ...] (Uint32Array) */
    const uint32_t* indices;
    uint32_t triangle_count;     /**< Number of triangles (indices len = triangle_count * 3) */

    /**
     * Map from triangle index to topological Face ID (Uint32Array).
     * Array length = triangle_count.
     * When Three.js raycasts an intersection, `intersect.faceIndex` provides
     * the triangle index. Looking up `triangle_to_face_id[faceIndex]` yields
     * the exact sub-shape Face ID in O(1) time.
     */
    const uint32_t* triangle_to_face_id;

    /* Edge line segments for sharp feature rendering and edge picking */
    /* Vertex coordinates: [x0, y0, z0, x1, y1, z1, ...] (Float32Array) */
    const float* edge_vertices;
    uint32_t edge_segment_count; /**< Number of line segments (edge_vertices len = edge_segment_count * 6) */

    /**
     * Map from edge segment index to topological Edge ID (Uint32Array).
     * Array length = edge_segment_count.
     */
    const uint32_t* segment_to_edge_id;

    /* Bounding box */
    cad_vec3_t bbox_min;
    cad_vec3_t bbox_max;
} cad_mesh_t;

/**
 * @brief B-Rep Topology Summary & Invariant Statistics
 */
typedef struct cad_brep_stats_s {
    uint32_t num_vertices;
    uint32_t num_edges;
    uint32_t num_wires;
    uint32_t num_faces;
    uint32_t num_shells;
    uint32_t num_solids;
    float volume;
    float surface_area;
    int32_t euler_characteristic; /**< V - E + F for checking topological invariants */
} cad_brep_stats_t;

/* ------------------------------------------------------------------------- */
/* Kernel Initialization and Feature-Flag Routing                            */
/* ------------------------------------------------------------------------- */

/**
 * @brief Initialize the CAD kernel subsystem and allocator.
 */
cad_status_t cad_kernel_init(void);

/**
 * @brief Deinitialize the CAD kernel subsystem and reclaim all registry memory.
 */
cad_status_t cad_kernel_deinit(void);

/**
 * @brief Set the routing backend for an individual CAD operation type.
 * Allows switching an op from C++ Oracle to native Zig as it passes fuzzing.
 */
cad_status_t cad_router_set_backend(cad_op_type_t op, cad_backend_t backend);

/**
 * @brief Get the active backend for an individual CAD operation type.
 */
cad_backend_t cad_router_get_backend(cad_op_type_t op);

/* ------------------------------------------------------------------------- */
/* Parametric Modeling Primitives & Operations                               */
/* ------------------------------------------------------------------------- */

/**
 * @brief Create an axis-aligned parametric box solid.
 * @param dx Size along X axis (> 0)
 * @param dy Size along Y axis (> 0)
 * @param dz Size along Z axis (> 0)
 * @param out_solid Output handle to the constructed B-Rep solid
 */
cad_status_t cad_primitive_box(
    float dx, float dy, float dz,
    cad_solid_handle_t* out_solid
);

/**
 * @brief Create a parametric cylinder solid along the Z axis.
 * @param radius Base radius (> 0)
 * @param height Height along Z axis (> 0)
 * @param out_solid Output handle to the constructed B-Rep solid
 */
cad_status_t cad_primitive_cylinder(
    float radius, float height,
    cad_solid_handle_t* out_solid
);

/**
 * @brief Extrude a 2D polygonal closed wire profile along a vector.
 * @param points Flat array of [x, y] coordinates (length = num_points * 2)
 * @param num_points Number of vertices in the 2D polygon wire
 * @param extrusion_vector Extrusion direction and magnitude [dx, dy, dz]
 * @param out_solid Output handle to the constructed solid
 */
cad_status_t cad_op_extrude(
    const float* points, uint32_t num_points,
    cad_vec3_t extrusion_vector,
    cad_solid_handle_t* out_solid
);

/**
 * @brief Perform a constructive solid geometry (CSG) Boolean operation.
 * @param op_type CAD_OP_BOOLEAN_UNION, CAD_OP_BOOLEAN_DIFFERENCE, or CAD_OP_BOOLEAN_INTERSECTION
 * @param solid_a First solid operand
 * @param solid_b Second solid operand
 * @param out_solid Resulting B-Rep solid
 */
cad_status_t cad_op_boolean(
    cad_op_type_t op_type,
    cad_solid_handle_t solid_a,
    cad_solid_handle_t solid_b,
    cad_solid_handle_t* out_solid
);

/* ------------------------------------------------------------------------- */
/* Tessellation, Inspection & Sub-shape Identification                      */
/* ------------------------------------------------------------------------- */

/**
 * @brief Tessellate a B-Rep solid into zero-copy flat linear buffers.
 * @param solid Handle to the B-Rep solid
 * @param chordal_deflection Linear chordal deflection tolerance for curved surfaces
 * @param angular_deflection Angular tolerance in radians
 * @param out_mesh Populated mesh structure containing flat pointers into kernel memory
 */
cad_status_t cad_solid_tessellate(
    cad_solid_handle_t solid,
    float chordal_deflection,
    float angular_deflection,
    cad_mesh_t* out_mesh
);

/**
 * @brief Retrieve topological invariants and statistics for validation.
 */
cad_status_t cad_solid_get_stats(
    cad_solid_handle_t solid,
    cad_brep_stats_t* out_stats
);

/**
 * @brief Free resources associated with a tessellated mesh.
 */
cad_status_t cad_mesh_free(cad_mesh_t* mesh);

/**
 * @brief Release a B-Rep solid handle and its associated topological DAG.
 */
cad_status_t cad_solid_release(cad_solid_handle_t solid);

/* ------------------------------------------------------------------------- */
/* Wave 2: 2D Parametric Sketch Constraint Solver Interface                   */
/* ------------------------------------------------------------------------- */

#define CAD_SKETCH_INVALID_ID 0xFFFFFFFFU

/**
 * @brief 2D Point Primitive in sketch coordinate space.
 */
typedef struct cad_sketch_point2d_s {
    uint32_t id;         /**< Unique point ID within sketch */
    double x;            /**< X coordinate (f64 precision) */
    double y;            /**< Y coordinate (f64 precision) */
    uint8_t is_fixed;    /**< 1 if point is grounded/fixed, 0 otherwise */
} cad_sketch_point2d_t;
typedef cad_sketch_point2d_t CadSketchPoint2D;

/**
 * @brief 2D Line Segment defined by endpoints.
 */
typedef struct cad_sketch_line2d_s {
    uint32_t id;             /**< Unique line ID within sketch */
    uint32_t start_point_id; /**< ID of start CadSketchPoint2D */
    uint32_t end_point_id;   /**< ID of end CadSketchPoint2D */
} cad_sketch_line2d_t;
typedef cad_sketch_line2d_t CadSketchLine2D;

/**
 * @brief 2D Circular Arc defined by center, start, end points and radius.
 */
typedef struct cad_sketch_arc2d_s {
    uint32_t id;              /**< Unique arc ID within sketch */
    uint32_t center_point_id; /**< ID of center CadSketchPoint2D */
    uint32_t start_point_id;  /**< ID of start CadSketchPoint2D */
    uint32_t end_point_id;    /**< ID of end CadSketchPoint2D */
    double radius;            /**< Arc radius */
} cad_sketch_arc2d_t;
typedef cad_sketch_arc2d_t CadSketchArc2D;

/**
 * @brief 2D Circle defined by center point and radius.
 */
typedef struct cad_sketch_circle2d_s {
    uint32_t id;              /**< Unique circle ID within sketch */
    uint32_t center_point_id; /**< ID of center CadSketchPoint2D */
    double radius;            /**< Circle radius */
} cad_sketch_circle2d_t;
typedef cad_sketch_circle2d_t CadSketchCircle2D;

/**
 * @brief Geometric constraint types supported by the 2D solver.
 */
typedef enum cad_sketch_constraint_type_e {
    CAD_CONSTRAINT_COINCIDENT = 0,    /**< Two points coincident or point on curve */
    CAD_CONSTRAINT_PARALLEL = 1,      /**< Two lines parallel */
    CAD_CONSTRAINT_PERPENDICULAR = 2, /**< Two lines perpendicular */
    CAD_CONSTRAINT_TANGENT = 3,       /**< Line-arc or arc-arc tangency */
    CAD_CONSTRAINT_HORIZONTAL = 4,    /**< Line or two points horizontal */
    CAD_CONSTRAINT_VERTICAL = 5,      /**< Line or two points vertical */
    CAD_CONSTRAINT_EQUAL = 6,         /**< Equal line length or equal circle/arc radius */
    CAD_CONSTRAINT_SYMMETRIC = 7,     /**< Two entities symmetric across a line */
    CAD_CONSTRAINT_DISTANCE = 8,      /**< Dimensional distance constraint */
    CAD_CONSTRAINT_ANGLE = 9,         /**< Angular constraint (in radians) */
    CAD_CONSTRAINT_RADIUS = 10        /**< Dimensional radius constraint */
} cad_sketch_constraint_type_t;
typedef cad_sketch_constraint_type_t CadSketchConstraintType;

/**
 * @brief Geometric constraint definition relating sketch entities.
 */
typedef struct cad_sketch_constraint_s {
    uint32_t id;                       /**< Unique constraint ID */
    cad_sketch_constraint_type_t type; /**< Constraint type */
    uint32_t entity1_id;               /**< First target entity ID */
    uint32_t entity2_id;               /**< Second target entity ID (CAD_SKETCH_INVALID_ID if unused) */
    uint32_t entity3_id;               /**< Third entity ID (e.g. symmetry axis or vertex, CAD_SKETCH_INVALID_ID if unused) */
    uint32_t entity4_id;               /**< Fourth entity ID (e.g. angle ray endpoint, CAD_SKETCH_INVALID_ID if unused) */
    double parameter_value;            /**< Target f64 parameter value (distance, angle in radians, or radius) */
    uint8_t is_driving;                /**< 1 if driving constraint, 0 if reference / driven */
} cad_sketch_constraint_t;
typedef cad_sketch_constraint_t CadSketchConstraint;

/**
 * @brief Convergence and diagnostic state returned by the 2D solver.
 */
typedef enum cad_solve_state_e {
    CAD_SOLVE_STATE_SOLVED = 0,           /**< System converged, residual < tolerance, 0 DOF */
    CAD_SOLVE_STATE_UNDER_CONSTRAINED = 1,/**< System converged, remaining degrees of freedom > 0 */
    CAD_SOLVE_STATE_OVER_CONSTRAINED = 2, /**< Redundant consistent constraints detected */
    CAD_SOLVE_STATE_CONFLICTING = 3       /**< Inconsistent/contradictory constraints prevent solution */
} cad_solve_state_t;
typedef cad_solve_state_t CadSolveState;

/**
 * @brief Diagnostic and convergence results from 2D constraint solving.
 */
typedef struct cad_solver_status_s {
    cad_solve_state_t solve_state;        /**< Convergence outcome */
    uint32_t degrees_of_freedom;          /**< Remaining degrees of freedom (DOF) */
    uint32_t iterations;                  /**< Iterations executed */
    double max_residual;                  /**< Maximum equation residual at termination */

    /* Zero-copy flat memory slices */
    const double* updated_coords;         /**< Interleaved solved coordinates [x0, y0, x1, y1, ...] */
    uint32_t coord_count;                 /**< Number of coordinate pairs (points) */

    const uint32_t* conflicting_constraint_ids; /**< IDs of conflicting or over-constraining equations */
    uint32_t conflicting_count;           /**< Number of conflicting constraint IDs */
} cad_solver_status_t;
typedef cad_solver_status_t CadSolverStatus;

/**
 * @brief Solve a 2D parametric geometric constraint sketch.
 *
 * Evaluates non-linear residual equations, computes the sparse Jacobian matrix,
 * and converges using iterative numerical optimization (Newton-Raphson / Levenberg-Marquardt).
 *
 * @param points Array of sketch point entities (updated with solved positions)
 * @param point_count Number of points in points array
 * @param lines Array of sketch line entities
 * @param line_count Number of lines
 * @param arcs Array of sketch arc entities
 * @param arc_count Number of arcs
 * @param circles Array of sketch circle entities
 * @param circle_count Number of circles
 * @param constraints Array of geometric constraints
 * @param constraint_count Number of constraints
 * @param max_iterations Maximum solver iterations allowed (e.g. 50-100)
 * @param convergence_tol Residual convergence threshold (e.g. 1e-7)
 * @param out_status Output status struct containing solve state, DOF, iterations, residual, and diagnostics
 * @return CAD_STATUS_OK if execution completed (inspect out_status->solve_state for convergence)
 */
cad_status_t cad_sketch_solve(
    cad_sketch_point2d_t* points, uint32_t point_count,
    const cad_sketch_line2d_t* lines, uint32_t line_count,
    const cad_sketch_arc2d_t* arcs, uint32_t arc_count,
    const cad_sketch_circle2d_t* circles, uint32_t circle_count,
    const cad_sketch_constraint_t* constraints, uint32_t constraint_count,
    uint32_t max_iterations, double convergence_tol,
    cad_solver_status_t* out_status
);

/**
 * @brief Compute remaining degrees of freedom (DOF) for a 2D sketch without full numerical convergence.
 *
 * Performs Rank-Revealing QR (RRQR) decomposition on the system Jacobian to determine
 * rank deficiency and identify under-constrained variables.
 *
 * @param point_count Number of sketch points
 * @param lines Array of sketch line entities
 * @param line_count Number of lines
 * @param arcs Array of sketch arc entities
 * @param arc_count Number of arcs
 * @param circles Array of sketch circle entities
 * @param circle_count Number of circles
 * @param constraints Array of geometric constraints
 * @param constraint_count Number of constraints
 * @param out_dof Output remaining degrees of freedom
 * @return CAD_STATUS_OK on success
 */
cad_status_t cad_sketch_get_dof(
    uint32_t point_count,
    const cad_sketch_line2d_t* lines, uint32_t line_count,
    const cad_sketch_arc2d_t* arcs, uint32_t arc_count,
    const cad_sketch_circle2d_t* circles, uint32_t circle_count,
    const cad_sketch_constraint_t* constraints, uint32_t constraint_count,
    uint32_t* out_dof
);

/* ------------------------------------------------------------------------- */
/* Wave 3: Parametric Feature DAG, Persistent Naming & Sub-Shape Slices       */
/* ------------------------------------------------------------------------- */

/**
 * @brief Sub-shape classification for persistent topological naming.
 */
typedef enum cad_subshape_type_e {
    CAD_SUBSHAPE_VERTEX = 0,
    CAD_SUBSHAPE_EDGE = 1,
    CAD_SUBSHAPE_FACE = 2,
    CAD_SUBSHAPE_SHELL = 3
} cad_subshape_type_t;
typedef cad_subshape_type_t CadSubshapeType;

/**
 * @brief 64-bit Persistent Topological Identifier (CadTopoId).
 *
 * Encodes the originating modeling feature ID, generating 2D sketch element ID,
 * CAD operation type, sub-shape type (vertex/edge/face), and a topological/spatial invariant hash.
 * Enables deterministic tracking across upstream parametric changes without broken downstream references.
 */
typedef union cad_topo_id_u {
    uint64_t raw;
    struct {
        uint32_t origin_feature_id : 16;        /**< Originating feature node ID (16 bits) */
        uint32_t source_sketch_entity_id : 16; /**< Source 2D sketch entity ID (16 bits) */
        uint16_t op_type : 8;                  /**< CAD operation type (cad_op_type_t) (8 bits) */
        uint16_t subshape_type : 4;            /**< cad_subshape_type_t (4 bits) */
        uint16_t flags : 4;                    /**< Disambiguation flags (start/end cap, lateral) (4 bits) */
        uint16_t subshape_hash : 16;           /**< Geometric / topological invariant hash (16 bits) */
    } fields;
} cad_topo_id_t;
typedef cad_topo_id_t CadTopoId;

#define CAD_INVALID_TOPO_ID ((cad_topo_id_t){ .raw = 0ULL })

/**
 * @brief Types of parametric modeling features in the DAG.
 */
typedef enum cad_feature_type_e {
    CAD_FEATURE_SKETCH = 0,
    CAD_FEATURE_EXTRUDE = 1,
    CAD_FEATURE_REVOLVE = 2,
    CAD_FEATURE_BOOLEAN_UNION = 3,
    CAD_FEATURE_BOOLEAN_CUT = 4,
    CAD_FEATURE_BOOLEAN_INTERSECT = 5,
    CAD_FEATURE_FILLET = 6,
    CAD_FEATURE_CHAMFER = 7,
    CAD_FEATURE_SHELL = 8,
    CAD_FEATURE_DRAFT = 9
} cad_feature_type_t;
typedef cad_feature_type_t CadFeatureType;

#define CAD_MAX_FEATURE_PARENTS 8
#define CAD_MAX_FEATURE_TARGETS 16

/* ------------------------------------------------------------------------- */
/* Wave 5: Dress-Up Operation Payloads                                       */
/* ------------------------------------------------------------------------- */

typedef enum cad_fillet_mode_e {
    CAD_FILLET_CONSTANT_RADIUS = 0,     /**< Uniform rolling-ball blend radius */
    CAD_FILLET_VARIABLE_RADIUS = 1,     /**< Linear taper from radius_start to radius_end */
    CAD_FILLET_CHORDAL = 2              /**< Fixed chord width blend */
} cad_fillet_mode_t;
typedef cad_fillet_mode_t CadFilletMode;

/**
 * @brief Constant or variable radius fillet dress-up operation payload.
 */
typedef struct cad_fillet_op_s {
    cad_fillet_mode_t mode;             /**< Constant, variable, or chordal */
    double radius_start;                /**< Primary/start blend radius (mm) */
    double radius_end;                  /**< End blend radius for variable fillets (mm) */
    uint32_t target_edge_count;         /**< Number of target edge IDs in target_edge_ids */
    cad_topo_id_t target_edge_ids[CAD_MAX_FEATURE_TARGETS]; /**< Edges to be blended */
} cad_fillet_op_t;
typedef cad_fillet_op_t CadFilletOp;

typedef enum cad_chamfer_mode_e {
    CAD_CHAMFER_EQUAL_DISTANCE = 0,     /**< 45-degree symmetric bevel (distance) */
    CAD_CHAMFER_TWO_DISTANCES = 1,      /**< Asymmetric bevel (distance1, distance2) */
    CAD_CHAMFER_DISTANCE_ANGLE = 2      /**< Bevel specified by setback distance and angle */
} cad_chamfer_mode_t;
typedef cad_chamfer_mode_t CadChamferMode;

/**
 * @brief Equal-distance, two-distance, or distance-angle chamfer payload.
 */
typedef struct cad_chamfer_op_s {
    cad_chamfer_mode_t mode;            /**< Equal distance, two distances, or distance/angle */
    double distance1;                   /**< Primary setback distance (mm) */
    double distance2;                   /**< Secondary setback distance (for two-distance mode) */
    double angle_rad;                   /**< Chamfer bevel angle (for distance/angle mode) */
    uint32_t target_edge_count;         /**< Number of target edge IDs in target_edge_ids */
    cad_topo_id_t target_edge_ids[CAD_MAX_FEATURE_TARGETS]; /**< Edges to be beveled */
} cad_chamfer_op_t;
typedef cad_chamfer_op_t CadChamferOp;

/**
 * @brief Hollow thin-walled shell dress-up operation payload.
 */
typedef struct cad_shell_op_s {
    double thickness;                   /**< Wall thickness (positive = inward offset, negative = outward) */
    uint8_t is_inward;                  /**< 1 for inward hollow cavity, 0 for outward */
    uint32_t open_face_count;           /**< Number of open faces removed from the hollowed solid */
    cad_topo_id_t open_face_ids[CAD_MAX_FEATURE_TARGETS]; /**< Face CadTopoIds to remain open */
} cad_shell_op_t;
typedef cad_shell_op_t CadShellOp;

/**
 * @brief Mold draft angle taper dress-up operation payload.
 */
typedef struct cad_draft_op_s {
    double draft_angle_rad;             /**< Draft taper angle (radians) */
    cad_vec3_t pull_direction;          /**< Mold draw / pull vector direction */
    cad_vec3_t neutral_plane_point;     /**< Point on parting / neutral reference plane */
    cad_vec3_t neutral_plane_normal;    /**< Normal vector of neutral reference plane */
    uint32_t draft_face_count;          /**< Number of faces to taper */
    cad_topo_id_t draft_face_ids[CAD_MAX_FEATURE_TARGETS]; /**< Faces subject to draft taper */
} cad_draft_op_t;
typedef cad_draft_op_t CadDraftOp;

/**
 * @brief Parametric feature node within the directed acyclic graph (DAG).
 */
typedef struct cad_feature_node_s {
    uint32_t feature_id;                 /**< Unique feature ID in DAG */
    cad_feature_type_t type;             /**< Feature operation type */
    uint8_t is_suppressed;               /**< 1 if feature is suppressed/disabled, 0 if active */

    /* Parent dependency tracking */
    uint32_t parent_count;               /**< Number of direct parent dependencies */
    uint32_t parent_ids[CAD_MAX_FEATURE_PARENTS]; /**< Feature IDs of prerequisite nodes */

    /* Target persistent topological references (for fillets, chamfers, sketches on faces) */
    uint32_t target_topo_count;          /**< Number of target topological sub-shapes */
    cad_topo_id_t target_topo_ids[CAD_MAX_FEATURE_TARGETS]; /**< CadTopoId targets */

    /* Parametric operation payload */
    union {
        struct {
            double distance;             /**< Extrusion depth */
            cad_vec3_t direction;        /**< Extrusion vector */
            uint8_t symmetric;           /**< 1 for two-sided symmetric extrusion */
        } extrude;
        struct {
            double angle_rad;            /**< Revolution angle (radians) */
            cad_vec3_t axis_origin;      /**< Revolution axis point */
            cad_vec3_t axis_direction;   /**< Revolution axis unit vector */
        } revolve;
        struct {
            double radius;               /**< Legacy constant fillet radius */
            cad_fillet_op_t op;          /**< Full constant/variable fillet payload */
        } fillet;
        struct {
            double distance;             /**< Legacy chamfer setback */
            double angle_rad;            /**< Legacy chamfer angle (radians) */
            cad_chamfer_op_t op;         /**< Full chamfer payload */
        } chamfer;
        cad_shell_op_t shell;            /**< Shell hollow wall thickness & open face IDs */
        cad_draft_op_t draft;            /**< Draft taper angle & pull direction */
        struct {
            uint32_t tool_feature_id;    /**< Feature ID providing tool solid */
        } boolean_op;
    } params;
} cad_feature_node_t;
typedef cad_feature_node_t CadFeatureNode;

/**
 * @brief Zero-copy tessellated solid slice for WebAssembly memory mapping.
 * Contains flat contiguous arrays of positions, normals, indices, and 64-bit CadTopoId
 * mappings for O(1) sub-shape face and edge selection in Three.js without JSON serialization.
 */
typedef struct cad_tessellated_solid_slice_s {
    /* Vertex coordinate buffer: [x0, y0, z0, x1, y1, z1, ...] */
    const float* positions;
    uint32_t vertex_count;               /**< Number of vertices (positions length = vertex_count * 3) */

    /* Vertex normal buffer: [nx0, ny0, nz0, ...] */
    const float* normals;                /**< Normals length = vertex_count * 3 */

    /* Triangle index buffer: [i0, i1, i2, ...] */
    const uint32_t* indices;
    uint32_t triangle_count;             /**< Number of triangles (indices length = triangle_count * 3) */

    /**
     * Map from triangle index to 64-bit persistent topological Face ID (CadTopoId).
     * Array length = triangle_count.
     * When Three.js raycasts a mesh, raycast.faceIndex yields the triangle index,
     * immediately resolving the exact persistent B-Rep Face ID in O(1) time.
     */
    const uint64_t* triangle_to_face_id;

    /**
     * 3D Polyline segments representing sharp feature edges for boundary rendering.
     * Interleaved [x0, y0, z0, x1, y1, z1, ...] (each segment = 2 vertices = 6 floats).
     */
    const float* edge_polylines;
    uint32_t edge_segment_count;         /**< Number of line segments (len = edge_segment_count * 6) */

    /**
     * Map from edge segment index to 64-bit persistent topological Edge ID (CadTopoId).
     * Array length = edge_segment_count.
     */
    const uint64_t* edge_to_topo_id;

    /* Axis-aligned bounding box */
    cad_vec3_t bbox_min;
    cad_vec3_t bbox_max;
} cad_tessellated_solid_slice_t;
typedef cad_tessellated_solid_slice_t CadTessellatedSolidSlice;

/**
 * @brief Evaluate the parametric feature DAG up to the active rollback index.
 * Reconstructs all modeling features, resolves persistent topological naming references,
 * and builds the resulting B-Rep solid.
 *
 * @param nodes Array of feature DAG nodes
 * @param node_count Number of nodes in the DAG
 * @param rollback_index Index up to which features should be evaluated (0 to node_count - 1)
 * @param out_solid Output handle to the evaluated B-Rep solid
 * @return CAD_STATUS_OK on success
 */
cad_status_t cad_dag_evaluate(
    const cad_feature_node_t* nodes,
    uint32_t node_count,
    uint32_t rollback_index,
    cad_solid_handle_t* out_solid
);

/**
 * @brief Set the active rollback index for the feature tree DAG.
 * Freezes evaluation past the rollback marker.
 *
 * @param rollback_index New rollback marker index
 * @return CAD_STATUS_OK on success
 */
cad_status_t cad_dag_set_rollback_index(
    uint32_t rollback_index
);

/**
 * @brief Tessellate a B-Rep solid into zero-copy persistent CadTopoId slice buffers.
 *
 * @param solid Handle to the evaluated B-Rep solid
 * @param chordal_deflection Linear chordal deflection tolerance
 * @param angular_deflection Angular tolerance in radians
 * @param out_slice Populated CadTessellatedSolidSlice with flat kernel pointers
 * @return CAD_STATUS_OK on success
 */
cad_status_t cad_solid_tessellate_slice(
    cad_solid_handle_t solid,
    float chordal_deflection,
    float angular_deflection,
    cad_tessellated_solid_slice_t* out_slice
);

/**
 * @brief Free resources associated with a CadTessellatedSolidSlice.
 */
cad_status_t cad_slice_free(
    cad_tessellated_solid_slice_t* slice
);

/* ------------------------------------------------------------------------- */
/* Wave 5: Dress-Up Solid Operations                                         */
/* ------------------------------------------------------------------------- */

/**
 * @brief Apply constant or variable-radius fillet blending to target edges of a B-Rep solid.
 *
 * @param solid Input solid handle
 * @param fillet_op Fillet specification payload (radii, mode, target edge CadTopoIds)
 * @param out_solid Output handle to the blended solid
 * @return CAD_STATUS_OK on success
 */
cad_status_t cad_solid_fillet(
    cad_solid_handle_t solid,
    const cad_fillet_op_t* fillet_op,
    cad_solid_handle_t* out_solid
);

/**
 * @brief Apply chamfer beveled transitions to target edges of a B-Rep solid.
 *
 * @param solid Input solid handle
 * @param chamfer_op Chamfer specification payload (setback distances, angle, edge IDs)
 * @param out_solid Output handle to the beveled solid
 * @return CAD_STATUS_OK on success
 */
cad_status_t cad_solid_chamfer(
    cad_solid_handle_t solid,
    const cad_chamfer_op_t* chamfer_op,
    cad_solid_handle_t* out_solid
);

/**
 * @brief Hollow out a solid to create a thin-walled shell with specified open faces.
 *
 * @param solid Input solid handle
 * @param shell_op Shelling specification (wall thickness, inward/outward, open face IDs)
 * @param out_solid Output handle to the hollowed shell solid
 * @return CAD_STATUS_OK on success
 */
cad_status_t cad_solid_shell(
    cad_solid_handle_t solid,
    const cad_shell_op_t* shell_op,
    cad_solid_handle_t* out_solid
);

/**
 * @brief Apply mold draft angle tapers to selected faces relative to a neutral pull vector.
 *
 * @param solid Input solid handle
 * @param draft_op Draft specification (draft angle, pull direction, neutral plane, face IDs)
 * @param out_solid Output handle to the drafted solid
 * @return CAD_STATUS_OK on success
 */
cad_status_t cad_solid_draft(
    cad_solid_handle_t solid,
    const cad_draft_op_t* draft_op,
    cad_solid_handle_t* out_solid
);

/* ------------------------------------------------------------------------- */
/* Wave 5: 3D Assembly Mates & Kinematic Solver                             */
/* ------------------------------------------------------------------------- */

typedef enum cad_assembly_mate_type_e {
    CAD_MATE_COINCIDENT = 0,    /**< MATE_COINCIDENT: Planar coincidence or point-on-point */
    CAD_MATE_CONCENTRIC = 1,    /**< MATE_CONCENTRIC: Collinear cylindrical/revolute axes */
    CAD_MATE_PARALLEL = 2,      /**< MATE_PARALLEL: Parallel planar normals or axes */
    CAD_MATE_DISTANCE = 3,      /**< MATE_DISTANCE: Fixed Euclidean offset distance */
    CAD_MATE_ANGLE = 4,         /**< MATE_ANGLE: Fixed dihedral angle between planar entities */
    CAD_MATE_GEAR = 5           /**< MATE_GEAR: Coupled rotational gear/pitch ratio */
} cad_assembly_mate_type_t;
typedef cad_assembly_mate_type_t CadAssemblyMateType;

/**
 * @brief Instantiated solid part in 3D assembly space.
 */
typedef struct cad_assembly_instance_s {
    uint32_t instance_id;                /**< Unique assembly instance identifier */
    cad_solid_handle_t solid_handle;     /**< Source prototype solid handle */
    uint8_t is_grounded;                 /**< 1 if instance is anchored/fixed in space (0 DOF) */
    float initial_transform[16];         /**< Initial 4x4 column-major affine transform matrix */
    char name[32];                       /**< Human-readable instance tag */
} cad_assembly_instance_t;
typedef cad_assembly_instance_t CadAssemblyInstance;

/**
 * @brief 3D kinematic joint mate linking two sub-shape topological entities across instances.
 */
typedef struct cad_assembly_mate_s {
    uint32_t mate_id;                    /**< Unique mate constraint ID */
    cad_assembly_mate_type_t type;       /**< MATE_COINCIDENT, MATE_CONCENTRIC, etc. */
    uint32_t instance1_id;               /**< First instance ID */
    cad_topo_id_t entity1_topo_id;       /**< Sub-shape CadTopoId on instance 1 */
    uint32_t instance2_id;               /**< Second instance ID */
    cad_topo_id_t entity2_topo_id;       /**< Sub-shape CadTopoId on instance 2 */
    uint8_t is_anti_aligned;             /**< 0 = Aligned normals, 1 = Opposed/Anti-aligned */
    double parameter_value;              /**< Target distance, angle in radians, or gear ratio */
    double limits_min;                   /**< Minimum limit range for kinematic joints */
    double limits_max;                   /**< Maximum limit range for kinematic joints */
} cad_assembly_mate_t;
typedef cad_assembly_mate_t CadAssemblyMate;

/**
 * @brief Convergence status and remaining degrees of freedom from assembly solver.
 */
typedef struct cad_assembly_solve_status_s {
    cad_solve_state_t solve_state;       /**< Solved, under-constrained, over-constrained, conflicting */
    uint32_t total_dof;                  /**< Remaining system degrees of freedom */
    uint32_t iterations;                 /**< Iterations taken to converge */
    double max_residual;                 /**< Maximum algebraic constraint residual */
    uint32_t conflicting_count;          /**< Number of conflicting mate IDs */
    const uint32_t* conflicting_mate_ids;/**< Pointer to conflicting mate IDs */
} cad_assembly_solve_status_t;
typedef cad_assembly_solve_status_t CadAssemblySolveStatus;

/**
 * @brief Solve assembly kinematic constraints and produce packed 4x4 transform matrices.
 *
 * The output matrices buffer contains packed 4x4 column-major f32 transform matrices
 * (16 floats per instance), perfectly formatted for direct zero-copy upload into
 * Three.js THREE.InstancedMesh.instanceMatrix.needsUpdate = true.
 *
 * @param instances Array of assembly part instances
 * @param instance_count Number of instances in the assembly
 * @param mates Array of assembly mates (coincident, concentric, parallel, etc.)
 * @param mate_count Number of mates
 * @param max_iterations Maximum nonlinear solver iterations
 * @param convergence_tol Convergence residual tolerance (e.g. 1e-7)
 * @param out_transforms_f32 Pre-allocated buffer of (instance_count * 16) floats receiving packed 4x4 matrices
 * @param out_status Output pointer receiving detailed solve status and remaining DOF
 * @return CAD_STATUS_OK on success
 */
cad_status_t cad_assembly_solve_transforms(
    const cad_assembly_instance_t* instances,
    uint32_t instance_count,
    const cad_assembly_mate_t* mates,
    uint32_t mate_count,
    uint32_t max_iterations,
    double convergence_tol,
    float* out_transforms_f32,
    cad_assembly_solve_status_t* out_status
);

/* ------------------------------------------------------------------------- */
/* Wave 5: Multi-Deflection LOD Tessellation                                */
/* ------------------------------------------------------------------------- */

typedef enum cad_lod_level_e {
    CAD_LOD_COARSE = 0,   /**< Coarse LOD: fast preview / background (chordal ~0.5mm, angular ~0.5 rad) */
    CAD_LOD_MEDIUM = 1,   /**< Medium LOD: standard viewport interaction (chordal ~0.1mm, angular ~0.2 rad) */
    CAD_LOD_FINE = 2      /**< Fine LOD: high-precision / export rendering (chordal ~0.01mm, angular ~0.05 rad) */
} cad_lod_level_t;
typedef cad_lod_level_t CadLodLevel;

/**
 * @brief Tessellate a B-Rep solid into zero-copy slice buffers using discrete LOD presets.
 * Automatically computes adaptive chordal and angular deflection parameters matching
 * the requested Level of Detail (COARSE, MEDIUM, FINE).
 *
 * @param solid Handle to the evaluated B-Rep solid
 * @param lod_level Desired Level of Detail (CAD_LOD_COARSE, CAD_LOD_MEDIUM, CAD_LOD_FINE)
 * @param out_slice Populated CadTessellatedSolidSlice with flat kernel pointers
 * @return CAD_STATUS_OK on success
 */
cad_status_t cad_solid_tessellate_lod(
    cad_solid_handle_t solid,
    cad_lod_level_t lod_level,
    cad_tessellated_solid_slice_t* out_slice
);

/* ------------------------------------------------------------------------- */
/* Wave 6A: Universal Custom Feature & Plugin Extension ABI                  */
/* ------------------------------------------------------------------------- */

/**
 * @brief Dynamic execution limits and sandbox constraints for untrusted inputs.
 */
typedef struct cad_kernel_limits_s {
    uint64_t max_wasm_memory_bytes; /**< Max dynamic heap allocation in bytes (default: 256 MiB) */
    uint32_t max_solver_iterations;  /**< Max iterations for 2D/3D non-linear solvers (default: 500) */
    uint32_t max_boolean_faces;      /**< Max faces allowed in boolean intersection operands (default: 100000) */
    uint32_t eval_timeout_ms;        /**< Max execution wall-clock timeout per operation in ms (default: 5000) */
} cad_kernel_limits_t;
typedef cad_kernel_limits_t CadKernelLimits;

/**
 * @brief Virtual method table for custom feature plugins and companion workbenches.
 * Enables Sheet Metal, FEA, Flexures, nTop Implicit, CAM/3MF, and 2D HLR modules
 * to register custom DAG operations that execute directly over shared memory B-Rep SoA.
 */
typedef struct cad_plugin_op_vtable_s {
    uint32_t op_type_id;             /**< Unique custom operation identifier (>= 1000) */
    const char* op_name;             /**< Human-readable operation name */

    /**
     * @brief Evaluate custom parametric operation and produce an updated B-Rep solid handle.
     */
    cad_status_t (*evaluate_fn)(
        uint32_t op_type_id,
        const cad_feature_node_t* node,
        const cad_solid_handle_t* input_solids,
        uint32_t input_count,
        cad_solid_handle_t* out_solid
    );

    /**
     * @brief Optional custom LOD tessellator for non-standard B-Rep or implicit solids.
     * Pass NULL to default to standard B-Rep surface triangulation.
     */
    cad_status_t (*tessellate_fn)(
        cad_solid_handle_t solid,
        double chordal_tol,
        double angular_tol,
        cad_tessellated_solid_slice_t* out_slice
    );

    /**
     * @brief Serialize custom feature node into declarative Code-CAD AST text.
     */
    cad_status_t (*serialize_ast_fn)(
        const cad_feature_node_t* node,
        char* out_buf,
        size_t buf_size,
        size_t* out_written
    );

    /**
     * @brief Release custom plugin resources associated with a solid handle.
     */
    void (*free_fn)(cad_solid_handle_t solid);
} cad_plugin_op_vtable_t;
typedef cad_plugin_op_vtable_t CadPluginOpVTable;

/**
 * @brief Register a custom feature operation VTable with the core DAG evaluator.
 *
 * @param vtable Pointer to persistent or statically allocated plugin VTable
 * @return CAD_STATUS_OK on success, CAD_STATUS_ERROR_INVALID_ARGUMENT if op_type_id < 1000 or vtable is NULL
 */
cad_status_t cad_register_plugin_op(const cad_plugin_op_vtable_t* vtable);

/**
 * @brief Unregister a custom feature operation.
 *
 * @param op_type_id Operation ID previously registered
 * @return CAD_STATUS_OK on success
 */
cad_status_t cad_unregister_plugin_op(uint32_t op_type_id);

/**
 * @brief Dispatch evaluation of a registered custom plugin operation.
 */
cad_status_t cad_execute_plugin_op(
    uint32_t op_type_id,
    const cad_feature_node_t* node,
    const cad_solid_handle_t* input_solids,
    uint32_t input_count,
    cad_solid_handle_t* out_solid
);

/**
 * @brief Configure kernel resource limits and sandboxing thresholds.
 */
cad_status_t cad_set_kernel_limits(const cad_kernel_limits_t* limits);

/**
 * @brief Retrieve current kernel resource limits.
 */
cad_status_t cad_get_kernel_limits(cad_kernel_limits_t* out_limits);

/**
 * @brief Allocate shared linear memory buffer accessible across core and plugin WASM modules.
 *
 * @param size Number of bytes to allocate
 * @return Pointer to allocated buffer in linear memory, or NULL on failure
 */
void* cad_shared_alloc(size_t size);

/**
 * @brief Free shared linear memory buffer.
 *
 * @param ptr Pointer previously returned by cad_shared_alloc
 * @param size Allocation size in bytes
 */
void cad_shared_free(void* ptr, size_t size);

#ifdef __cplusplus
}
#endif

#endif /* CAD_KERNEL_H */
