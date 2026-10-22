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
#include <stdbool.h>

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

/* ------------------------------------------------------------------------- */
/* Wave 7: Sheet Metal Operations & 2D Flat-Pattern Unfolding                */
/* ------------------------------------------------------------------------- */

/**
 * @brief Corner/notch relief punch geometry for sheet metal bends.
 */
typedef enum cad_relief_type_e {
    CAD_RELIEF_RECTANGULAR = 0,         /**< Rectangular corner punch relief */
    CAD_RELIEF_ROUND = 1,               /**< Cylindrical/semi-circular punch relief */
    CAD_RELIEF_TEAR = 2,                /**< Zero-width slit / tear relief cut */
    CAD_RELIEF_NONE = 3                 /**< No relief cut (open boundary) */
} cad_relief_type_t;
typedef cad_relief_type_t CadReliefType;

/**
 * @brief Global and feature-specific sheet metal material and bend configuration.
 */
typedef struct cad_sheetmetal_config_s {
    double thickness;                   /**< Sheet stock thickness (mm, e.g. 0.5 to 10.0) */
    double bend_radius;                 /**< Inner bend radius (mm, default = thickness) */
    double k_factor;                    /**< Neutral axis ratio (0.0 to 1.0, typical 0.33 to 0.50 per DIN 6935) */
    cad_relief_type_t relief_type;      /**< Corner/tear relief cut geometry */
    double relief_width;                /**< Width of relief cut (mm, default = thickness) */
    double relief_depth;                /**< Depth of relief cut past bend line (mm) */
} cad_sheetmetal_config_t;
typedef cad_sheetmetal_config_t CadSheetMetalConfig;

/**
 * @brief Hem profile styles for sheet metal edge finishing.
 */
typedef enum cad_hem_type_e {
    CAD_HEM_CLOSED = 0,                 /**< Fully flattened / mashed hem */
    CAD_HEM_OPEN = 1,                   /**< Open U-shape hem with clearance air gap */
    CAD_HEM_TEARDROP = 2,               /**< Curved teardrop loop */
    CAD_HEM_ROLLED = 3                  /**< 270-360 degree rolled safety bead */
} cad_hem_type_t;
typedef cad_hem_type_t CadHemType;

/**
 * @brief Sheet metal extruded bend flange payload.
 */
typedef struct cad_flange_op_s {
    cad_topo_id_t target_edge_id;       /**< Base edge CadTopoId where flange is bent */
    double length;                      /**< Length / height of extruded flange (mm) */
    double angle_rad;                   /**< Bend angle in radians (e.g. PI/2 for 90-degree bend) */
    double offset_start;                /**< Offset from edge start vertex (mm) */
    double offset_end;                  /**< Offset from edge end vertex (mm) */
    cad_sheetmetal_config_t config;     /**< Sheet metal bend parameters */
} cad_flange_op_t;
typedef cad_flange_op_t CadFlangeOp;

/**
 * @brief Sheet metal hem payload.
 */
typedef struct cad_hem_op_s {
    cad_topo_id_t target_edge_id;       /**< Edge CadTopoId for hemming */
    cad_hem_type_t hem_type;            /**< Hem profile style */
    double length;                      /**< Hem return length (mm) */
    double gap;                         /**< Air gap for open / teardrop hems (mm) */
    cad_sheetmetal_config_t config;     /**< Sheet metal bend parameters */
} cad_hem_op_t;
typedef cad_hem_op_t CadHemOp;

/**
 * @brief Fold direction annotation for flat-pattern bend centerlines.
 */
typedef enum cad_bend_direction_e {
    CAD_BEND_UP = 0,                    /**< Sheet folded upward (+Z in local frame) */
    CAD_BEND_DOWN = 1                   /**< Sheet folded downward (-Z in local frame) */
} cad_bend_direction_t;
typedef cad_bend_direction_t CadBendDirection;

/**
 * @brief 2D bend centerline annotation with manufacturing fold instructions.
 */
typedef struct cad_bend_centerline_s {
    double start_point[2];              /**< Flat pattern 2D start coordinate [X, Y] */
    double end_point[2];                /**< Flat pattern 2D end coordinate [X, Y] */
    double bend_angle_rad;              /**< Fold angle in radians */
    double bend_radius;                 /**< Inner bend radius (mm) */
    cad_bend_direction_t direction;     /**< Up or Down fold direction */
    double bend_allowance;              /**< Computed DIN 6935 bend allowance (mm) */
    cad_topo_id_t source_bend_edge;     /**< Persistent TopoId of original 3D bend edge */
} cad_bend_centerline_t;
typedef cad_bend_centerline_t CadBendCenterline;

/**
 * @brief Unfolded 2D flat-pattern representation for CNC laser, plasma, and punch cutting.
 */
typedef struct cad_flat_pattern_s {
    cad_solid_handle_t flat_solid;      /**< 2D planar unbent B-Rep sheet solid handle */
    const cad_bend_centerline_t* bend_lines; /**< Array of bend centerlines */
    uint32_t bend_line_count;           /**< Number of bend centerlines */
    double bounding_box_2d[4];          /**< [min_x, min_y, max_x, max_y] of flat stock */
    double total_cut_length;            /**< Perimeter cutting length for CNC laser/waterjet */
    double total_area;                  /**< Flat sheet blank surface area (mm^2) */
} cad_flat_pattern_t;
typedef cad_flat_pattern_t CadFlatPattern;

/**
 * @brief Apply an angled extruded flange to a sheet metal body edge.
 */
cad_status_t cad_sheetmetal_flange(
    cad_solid_handle_t solid,
    const cad_flange_op_t* flange_op,
    cad_solid_handle_t* out_solid
);

/**
 * @brief Apply a hem finishing edge to a sheet metal body edge.
 */
cad_status_t cad_sheetmetal_hem(
    cad_solid_handle_t solid,
    const cad_hem_op_t* hem_op,
    cad_solid_handle_t* out_solid
);

/**
 * @brief Unfold a 3D folded sheet metal solid into a 2D flat-pattern B-Rep and bend centerlines.
 *
 * @param solid Input folded 3D sheet metal solid handle
 * @param fixed_face_id Base face CadTopoId that remains fixed during unfolding
 * @param out_flat_pattern Output flat-pattern B-Rep solid, bend lines, and metrics
 * @return CAD_STATUS_OK on success
 */
cad_status_t cad_sheetmetal_unfold(
    cad_solid_handle_t solid,
    cad_topo_id_t fixed_face_id,
    cad_flat_pattern_t* out_flat_pattern
);

/**
 * @brief Release memory resources allocated in a flat pattern.
 */
cad_status_t cad_flat_pattern_free(cad_flat_pattern_t* flat_pattern);

/* ------------------------------------------------------------------------- */
/* Wave 7: 2D Engineering Drawings, Hidden-Line Removal & Vector Export      */
/* ------------------------------------------------------------------------- */

/**
 * @brief Orthographic, isometric, or section drawing projection type.
 */
typedef enum cad_projection_type_e {
    CAD_PROJ_TOP = 0,                   /**< Top orthographic view (+Z -> -Z) */
    CAD_PROJ_FRONT = 1,                 /**< Front orthographic view (+Y -> -Y) */
    CAD_PROJ_RIGHT = 2,                 /**< Right orthographic view (+X -> -X) */
    CAD_PROJ_ISOMETRIC = 3,             /**< Standard 30-degree isometric axonometric view */
    CAD_PROJ_SECTION = 4,               /**< Cross-sectional cut with hatching */
    CAD_PROJ_CUSTOM = 5                 /**< Custom camera direction and up vector */
} cad_projection_type_t;
typedef cad_projection_type_t CadProjectionType;

/**
 * @brief Curve visibility class in 2D projected engineering drawing.
 */
typedef enum cad_curve_visibility_e {
    CAD_CURVE_VISIBLE = 0,              /**< Unobstructed outer/sharp silhouette (solid line) */
    CAD_CURVE_HIDDEN = 1,               /**< Occluded interior boundary (dashed/hidden line) */
    CAD_CURVE_SILHOUETTE = 2,           /**< Smooth curved surface horizon silhouette */
    CAD_CURVE_CENTERLINE = 3,           /**< Cylindrical hole / boss axis centerline (dash-dot) */
    CAD_CURVE_HATCH = 4                 /**< Section-cut cross-hatch boundary line */
} cad_curve_visibility_t;
typedef cad_curve_visibility_t CadCurveVisibility;

/**
 * @brief 2D projected polyline curve with topological provenance.
 */
typedef struct cad_drawing_curve_s {
    cad_curve_visibility_t visibility;  /**< Visible, hidden, silhouette, centerline, or hatch */
    const float* points_2d;             /**< Packed flat array of 2D coordinates [X0, Y0, X1, Y1, ...] */
    uint32_t point_count;               /**< Number of 2D coordinate pairs */
    cad_topo_id_t source_topo_id;       /**< Source 3D B-Rep Edge or Face CadTopoId */
} cad_drawing_curve_t;
typedef cad_drawing_curve_t CadDrawingCurve;

/**
 * @brief Planar cross-section definition for section drawings.
 */
typedef struct cad_section_plane_s {
    double origin[3];                   /**< Section cut plane origin [X, Y, Z] */
    double normal[3];                   /**< Section cut plane unit normal [Nx, Ny, Nz] */
    double hatch_angle_rad;             /**< Hatch line rotation angle (e.g. PI/4 = 45 deg) */
    double hatch_spacing;               /**< Hatch line spacing in drawing units (mm) */
} cad_section_plane_t;
typedef cad_section_plane_t CadSectionPlane;

/**
 * @brief Drawing view projection request parameters.
 */
typedef struct cad_drawing_view_params_s {
    cad_projection_type_t proj_type;    /**< Projection mode (Top, Front, Right, Isometric, Section, Custom) */
    double camera_dir[3];               /**< View direction vector for CAD_PROJ_CUSTOM */
    double up_dir[3];                   /**< Up vector for CAD_PROJ_CUSTOM */
    double scale;                       /**< Drawing scale factor (1.0 = 1:1, 0.5 = 1:2) */
    bool include_hidden_lines;          /**< Extract and return occluded dashed lines */
    bool include_smooth_silhouettes;    /**< Extract curved horizon silhouettes */
    bool include_centerlines;           /**< Extract hole / cylinder centerlines */
    cad_section_plane_t section_cut;    /**< Section cut plane when proj_type == CAD_PROJ_SECTION */
} cad_drawing_view_params_t;
typedef cad_drawing_view_params_t CadDrawingViewParams;

/**
 * @brief Projected 2D engineering drawing view containing classified vector polylines.
 */
typedef struct cad_drawing_view_s {
    const cad_drawing_curve_t* curves;  /**< Array of projected 2D curves */
    uint32_t curve_count;               /**< Number of curves in view */
    double view_bbox[4];                /**< [min_x, min_y, max_x, max_y] bounding box in drawing mm */
    double section_cut_area;            /**< Solid cross-sectional area if section view (mm^2) */
} cad_drawing_view_t;
typedef cad_drawing_view_t CadDrawingView;

/**
 * @brief Project a 3D B-Rep solid into a 2D engineering drawing view via exact Hidden-Line Removal.
 */
cad_status_t cad_hlr_project_view(
    cad_solid_handle_t solid,
    const cad_drawing_view_params_t* params,
    cad_drawing_view_t* out_view
);

/**
 * @brief Free allocated memory associated with a projected 2D drawing view.
 */
cad_status_t cad_drawing_view_free(cad_drawing_view_t* view);

/**
 * @brief Export projected drawing view curves to industry-standard AutoCAD DXF R12/2000 text.
 *
 * @param view Projected 2D drawing view
 * @param out_dxf_str Pointer to heap-allocated null-terminated DXF string
 * @param out_dxf_len Number of bytes written
 * @return CAD_STATUS_OK on success
 */
cad_status_t cad_export_dxf(
    const cad_drawing_view_t* view,
    char** out_dxf_str,
    size_t* out_dxf_len
);

/**
 * @brief Export projected drawing view curves to W3C SVG vector document with standard engineering layers.
 *
 * @param view Projected 2D drawing view
 * @param sheet_width_mm Drawing sheet width (e.g. 420.0 for ISO A3)
 * @param sheet_height_mm Drawing sheet height (e.g. 297.0 for ISO A3)
 * @param out_svg_str Pointer to heap-allocated null-terminated SVG string
 * @param out_svg_len Number of bytes written
 * @return CAD_STATUS_OK on success
 */
cad_status_t cad_export_svg_drawing(
    const cad_drawing_view_t* view,
    double sheet_width_mm,
    double sheet_height_mm,
    char** out_svg_str,
    size_t* out_svg_len
);

/* ------------------------------------------------------------------------- */
/* Wave 7: Additive & Subtractive CAM, 3MF Production & Build Nesting        */
/* ------------------------------------------------------------------------- */

/**
 * @brief Production 3MF export packaging options conforming to 3MF Core & Production Extensions.
 */
typedef struct cad_3mf_production_options_s {
    const char* part_number;            /**< Manufacturing Part Number / SKU identifier */
    const char* material_name;          /**< Material name (e.g. PA12, Ti-6Al-4V, PLA, 6061-T6) */
    double layer_height_mm;             /**< Target additive slice layer height (mm) */
    bool include_thumbnail;             /**< Embed rendered PNG viewport preview */
    bool use_compression;               /**< Apply Deflate ZIP container compression */
} cad_3mf_production_options_t;
typedef cad_3mf_production_options_t Cad3mfProductionOptions;

/**
 * @brief Export an assembly or collection of solids into a production-grade 3MF container.
 *
 * @param solids Array of B-Rep solid handles
 * @param transforms_4x4 Flat array of 4x4 column-major transforms (solid_count * 16 floats), or NULL for identity
 * @param solid_count Number of solids to package
 * @param options Production metadata and packaging options
 * @param out_3mf_bytes Pointer to allocated byte buffer containing the 3MF archive
 * @param out_3mf_len Byte length of the generated 3MF package
 * @return CAD_STATUS_OK on success
 */
cad_status_t cad_export_3mf_production(
    const cad_solid_handle_t* solids,
    const float* transforms_4x4,
    uint32_t solid_count,
    const cad_3mf_production_options_t* options,
    uint8_t** out_3mf_bytes,
    size_t* out_3mf_len
);

/**
 * @brief Nesting solver optimization strategy.
 */
typedef enum cad_nesting_mode_e {
    CAD_NESTING_2D_BUILD_PLATE = 0,     /**< FDM / CNC 2D flat plate nesting with part spacing */
    CAD_NESTING_3D_SINTER_BOX = 1       /**< SLS / DMLS 3D volumetric dense bounding-box / voxel packing */
} cad_nesting_mode_t;
typedef cad_nesting_mode_t CadNestingMode;

/**
 * @brief Configuration parameters for build volume nesting and packing algorithms.
 */
typedef struct cad_nesting_config_s {
    cad_nesting_mode_t mode;            /**< 2D bed or 3D powder chamber */
    double build_volume_dx;             /**< Printable width X (mm) */
    double build_volume_dy;             /**< Printable depth Y (mm) */
    double build_volume_dz;             /**< Printable height Z (mm, ignored if 2D) */
    double part_spacing_mm;             /**< Minimum clearance margin between parts (mm) */
    double margin_boundary_mm;          /**< Clearance from chamber perimeter walls (mm) */
    bool allow_rotation_xy;             /**< Allow 90 or arbitrary Z-axis rotation */
    bool allow_rotation_3d;             /**< Allow arbitrary SO(3) 3D re-orientation (SLS only) */
} cad_nesting_config_t;
typedef cad_nesting_config_t CadNestingConfig;

/**
 * @brief Placement transform and status for an individual nested part instance.
 */
typedef struct cad_nest_instance_s {
    cad_solid_handle_t solid;           /**< Part solid handle */
    float transform_4x4[16];            /**< Computed column-major placement transform matrix */
    bool fits_in_volume;                /**< True if successfully packed without collision */
} cad_nest_instance_t;
typedef cad_nest_instance_t CadNestInstance;

/**
 * @brief Build volume nesting optimization results and packing efficiency metrics.
 */
typedef struct cad_nesting_result_s {
    const cad_nest_instance_t* instances; /**< Packed instances array */
    uint32_t instance_count;            /**< Total number of instances requested */
    double packing_density_percent;     /**< Volumetric density: (part_volumes / chamber_volume) * 100 */
    double max_height_reached_mm;       /**< Maximum Z-height used (determines SLS print cycle time) */
    uint32_t parts_packed_count;        /**< Count of parts successfully packed within volume */
    uint32_t parts_overflow_count;      /**< Count of parts that could not fit */
} cad_nesting_result_t;
typedef cad_nesting_result_t CadNestingResult;

/**
 * @brief Nest and pack multiple part solids into an SLS sinter box or FDM build plate.
 *
 * @param solids Array of unique part solid handles
 * @param quantities Quantity required for each part solid
 * @param part_type_count Number of entries in solids and quantities arrays
 * @param config Build chamber volume and clearance constraints
 * @param out_result Output nested instance transforms and packing efficiency metrics
 * @return CAD_STATUS_OK on success
 */
cad_status_t cad_nest_build_volume(
    const cad_solid_handle_t* solids,
    const uint32_t* quantities,
    uint32_t part_type_count,
    const cad_nesting_config_t* config,
    cad_nesting_result_t* out_result
);

/**
 * @brief Free allocated memory associated with a nesting result.
 */
cad_status_t cad_nest_result_free(cad_nesting_result_t* result);

/**
 * @brief Subtractive CNC milling and drilling toolpath strategies.
 */
typedef enum cad_toolpath_strategy_e {
    CAD_CAM_2D_CONTOUR = 0,             /**< 2.5D perimeter profiling with lead-in/lead-out arcs */
    CAD_CAM_2D_POCKET = 1,              /**< 2.5D concentric / raster pocket clearing */
    CAD_CAM_ADAPTIVE_CLEARING = 2,      /**< Constant tool engagement angle high-speed trochoidal clearing */
    CAD_CAM_DRILL_CYCLE = 3,            /**< G81 standard / G83 peck drilling for cylindrical holes */
    CAD_CAM_SURFACE_3D = 4              /**< 3D parallel / scallop finish toolpath */
} cad_toolpath_strategy_t;
typedef cad_toolpath_strategy_t CadToolpathStrategy;

/**
 * @brief Subtractive cutting tool definition.
 */
typedef struct cad_tool_definition_s {
    uint32_t tool_number;               /**< Tool slot / position (T1, T2, etc.) */
    double diameter_mm;                 /**< Endmill or drill diameter (mm) */
    double corner_radius_mm;            /**< Flat endmill (0), bullnose (R), or ballnose (D/2) */
    double flute_length_mm;             /**< Maximum cutting depth per pass (mm) */
    uint32_t flute_count;               /**< Number of flutes (for chip load calculation) */
} cad_tool_definition_t;
typedef cad_tool_definition_t CadToolDefinition;

/**
 * @brief CNC toolpath generation parameters.
 */
typedef struct cad_cam_params_s {
    cad_toolpath_strategy_t strategy;   /**< Milling strategy (Contour, Pocket, Adaptive, Drill, 3D) */
    cad_tool_definition_t tool;         /**< Cutting tool geometry */
    double spindle_rpm;                 /**< Spindle speed RPM */
    double feed_cutting_mmpm;           /**< Cutting feedrate (mm/min) */
    double feed_plunge_mmpm;            /**< Plunge feedrate (mm/min) */
    double stepover_mm;                 /**< Radial stepover distance (mm) */
    double stepdown_mm;                 /**< Axial stepdown depth per pass (mm) */
    double stock_to_leave;              /**< Material stock left for finish pass (mm) */
    double clearance_height_mm;         /**< Rapid clearance plane Z (mm) */
    double retract_height_mm;           /**< Intermediate retract plane Z (mm) */
    cad_topo_id_t target_face_id;       /**< Floor or wall face CadTopoId to machine */
} cad_cam_params_t;
typedef cad_cam_params_t CadCamParams;

/**
 * @brief Generated CNC toolpath containing G-code and 3D visual preview polylines.
 */
typedef struct cad_cam_toolpath_s {
    cad_toolpath_strategy_t strategy;   /**< Strategy used */
    const char* gcode_text;             /**< Formatted standard RS-274 / ISO G-code string */
    size_t gcode_len;                   /**< Byte length of G-code string */
    double estimated_time_seconds;      /**< Machining cycle time estimation */
    double total_path_length_mm;        /**< Total feed distance (mm) */
    double rapid_distance_mm;           /**< Rapid traverse distance (mm) */
    const float* visual_points;         /**< Packed 3D toolpath coordinates [X0, Y0, Z0, ...] for Three.js preview */
    uint32_t visual_point_count;        /**< Number of 3D visual vertices */
} cad_cam_toolpath_t;
typedef cad_cam_toolpath_t CadCamToolpath;

/**
 * @brief Generate a subtractive CNC toolpath and RS-274 G-code for a target feature or solid.
 *
 * @param solid Input B-Rep solid handle
 * @param params Tooling, feeds, speeds, and strategy parameters
 * @param out_toolpath Output G-code buffer, cycle metrics, and visual toolpath points
 * @return CAD_STATUS_OK on success
 */
cad_status_t cad_cam_generate_toolpath(
    cad_solid_handle_t solid,
    const cad_cam_params_t* params,
    cad_cam_toolpath_t* out_toolpath
);

/**
 * @brief Free allocated memory associated with a generated CAM toolpath.
 */
cad_status_t cad_cam_toolpath_free(cad_cam_toolpath_t* toolpath);

/* ========================================================================= */
/* Wave 8: Tetrahedral Meshing, FEA & FACT Compliant Flexure Synthesis       */
/* ========================================================================= */

/**
 * @brief Finite element solver formulation modes.
 */
typedef enum cad_fea_mode_e {
    CAD_FEA_MODE_LINEAR_ELASTIC = 0,            /**< Small-displacement linear elastic PCG solver */
    CAD_FEA_MODE_COROTATIONAL_NONLINEAR = 1     /**< Corotational formulation for geometric large-deflection analysis */
} cad_fea_mode_t;
typedef cad_fea_mode_t CadFeaMode;

/**
 * @brief Tetrahedral finite element discretization order.
 */
typedef enum cad_fea_element_type_e {
    CAD_FEA_ELEMENT_TET4 = 4,                   /**< 4-node linear constant-strain tetrahedron */
    CAD_FEA_ELEMENT_TET10 = 10                  /**< 10-node quadratic isoparametric tetrahedron */
} cad_fea_element_type_t;
typedef cad_fea_element_type_t CadFeaElementType;

/**
 * @brief Material isotropic mechanical properties for structural FEA and flexures.
 */
typedef struct cad_material_props_s {
    double youngs_modulus_pa;                   /**< Young's modulus E in Pascals (e.g. 210e9 for Structural Steel, 69e9 for Al 6061-T6) */
    double poisson_ratio;                       /**< Poisson's ratio nu (e.g. 0.30 for Steel, 0.33 for Aluminum) */
    double yield_strength_pa;                   /**< Yield strength sigma_y in Pascals (e.g. 250e6 for Steel, 276e6 for Al 6061-T6) */
    double density;                             /**< Mass density rho in kg/m^3 (e.g. 7850 for Steel, 2700 for Aluminum) */
} cad_material_props_t;
typedef cad_material_props_t CadMaterialProps;

/**
 * @brief Structural boundary condition types.
 */
typedef enum cad_bc_type_e {
    CAD_BC_FIXED_FACE = 0,                      /**< Restrains all 3 translational DOFs (u_x = u_y = u_z = 0) */
    CAD_BC_FORCE_VECTOR = 1,                     /**< Distributed surface traction or nodal force vector [Fx, Fy, Fz] in Newtons */
    CAD_BC_MOMENT_VECTOR = 2,                    /**< Torsional / bending moment vector [Mx, My, Mz] in N*m */
    CAD_BC_PRESCRIBED_DISPLACEMENT = 3           /**< Enforced nodal displacement vector [dx, dy, dz] in meters */
} cad_bc_type_t;
typedef cad_bc_type_t CadBcType;

/**
 * @brief Boundary condition or load applied to a sub-shape CadTopoId.
 */
typedef struct cad_boundary_condition_s {
    cad_bc_type_t type;                          /**< Fixed support, force, moment, or displacement */
    cad_topo_id_t target_topo_id;                /**< Persistent CadTopoId of target face, edge, or vertex */
    double value[3];                             /**< Vector value [X, Y, Z] (Forces in N, Moments in N*m, Displacements in m) */
} cad_boundary_condition_t;
typedef cad_boundary_condition_t CadBoundaryCondition;

/**
 * @brief Tetrahedral mesh generator parameters.
 */
typedef struct cad_fea_mesh_params_s {
    cad_fea_element_type_t element_type;         /**< Tet4 (linear) or Tet10 (quadratic) */
    double max_element_size_m;                   /**< Maximum tetrahedral edge length (meters) */
    double growth_rate;                          /**< Element gradation factor (e.g. 1.2 to 1.5) */
    bool optimize_aspect_ratio;                  /**< Delaunay quality optimization to eliminate sliver tets */
} cad_fea_mesh_params_t;
typedef cad_fea_mesh_params_t CadFeaMeshParams;

/**
 * @brief Zero-copy tetrahedral volume mesh representation.
 */
typedef struct cad_tet_mesh_s {
    const float* node_positions;                 /**< Packed nodal coordinates [X0, Y0, Z0, ...] in meters (Float32Array) */
    uint32_t node_count;                         /**< Total number of nodes (positions len = node_count * 3) */
    const uint32_t* element_indices;             /**< Packed element connectivity [n0, n1, n2, n3, ...] (Uint32Array) */
    uint32_t element_count;                      /**< Total number of elements (stride = element_type) */
    cad_fea_element_type_t element_type;         /**< Tet4 (stride 4) or Tet10 (stride 10) */
} cad_tet_mesh_t;
typedef cad_tet_mesh_t CadTetMesh;

/**
 * @brief Maximum number of natural vibration or buckling mode shapes computed.
 */
#define CAD_FEA_NUM_MODE_SHAPES 6

/**
 * @brief Natural vibration eigenfrequency or linear buckling mode shape.
 */
typedef struct cad_fea_mode_shape_s {
    double natural_frequency_hz;                 /**< Resonant eigenfrequency (Hz) or buckling load factor lambda */
    const float* eigenmode_displacements;        /**< Zero-copy normalized nodal displacement vector [ux0, uy0, uz0, ...] */
} cad_fea_mode_shape_t;
typedef cad_fea_mode_shape_t CadFeaModeShape;

/**
 * @brief Zero-copy FEA solver results slice for high-performance Three.js WebGL visualization.
 */
typedef struct cad_fea_result_slice_s {
    uint32_t node_count;                         /**< Total nodes in discretized model */
    uint32_t element_count;                      /**< Total tetrahedral elements */

    /**
     * Zero-copy nodal displacement vectors u_xyz [ux0, uy0, uz0, ux1, uy1, uz1, ...] in meters.
     * Array length = node_count * 3 (Float32Array).
     */
    const float* u_xyz;

    /**
     * Zero-copy Von Mises equivalent stress scalar field in Pascals (N/m^2).
     * Array length = node_count (Float32Array) for node-averaged colormap rendering.
     */
    const float* von_mises_stresses;

    /**
     * Zero-copy structural safety factor map: sigma_yield / sigma_von_mises.
     * Array length = node_count (Float32Array).
     */
    const float* safety_factor_map;

    /**
     * Critical scalar response extrema
     */
    float max_displacement_m;                    /**< Maximum resultant nodal deflection |u|_max (meters) */
    float max_von_mises_pa;                      /**< Peak Von Mises equivalent stress (Pascals) */
    float min_safety_factor;                     /**< Minimum factor of safety (yield margin) across solid */

    /**
     * Natural vibration and buckling eigenmodes
     */
    cad_fea_mode_shape_t mode_shapes[CAD_FEA_NUM_MODE_SHAPES]; /**< First 6 mode shapes */
    uint32_t mode_shape_count;                   /**< Number of valid mode shapes (up to 6) */

    /**
     * Tetrahedral volume mesh geometry
     */
    cad_tet_mesh_t mesh;
} cad_fea_result_slice_t;
typedef cad_fea_result_slice_t CadFeaResultSlice;

/**
 * @brief FACT (Freedom and Constraint Topologies) screw axis types.
 */
typedef enum cad_fact_screw_type_e {
    CAD_FACT_PURE_ROTATION = 0,                  /**< Zero pitch screw axis (pure rotational freedom line or constraint line) */
    CAD_FACT_PURE_TRANSLATION = 1,               /**< Infinite pitch (pure translational freedom direction or constraint plane) */
    CAD_FACT_GENERAL_SCREW = 2                   /**< Finite pitch helical screw axis */
} cad_fact_screw_type_t;
typedef cad_fact_screw_type_t CadFactScrewType;

/**
 * @brief Individual FACT spatial screw-axis line segment.
 */
typedef struct cad_fact_screw_axis_s {
    cad_fact_screw_type_t type;                  /**< Pure rotation, translation, or helical screw */
    double origin[3];                            /**< Origin coordinate on axis [X, Y, Z] in stage frame */
    double direction[3];                         /**< Unit axis vector [Dx, Dy, Dz] */
    double pitch;                                /**< Screw pitch h (meters / radian) */
    bool is_freedom_line;                        /**< True = freedom twist axis (green), False = constraint wrench line (red) */
} cad_fact_screw_axis_t;
typedef cad_fact_screw_axis_t CadFactScrewAxis;

/**
 * @brief Compliant mechanism flexure analysis metrics, 6x6 spatial compliance/stiffness matrices, and FACT visualization.
 */
typedef struct cad_flexure_analysis_s {
    /**
     * Extracted 6x6 spatial compliance matrix C [rad/N, rad/(N*m); m/N, m/(N*m)].
     * Row-major flat array of 36 double-precision floats:
     * [delta_theta_x, delta_theta_y, delta_theta_z, delta_x, delta_y, delta_z]^T = C * [Fx, Fy, Fz, Mx, My, Mz]^T
     */
    double compliance_matrix_6x6[36];

    /**
     * Extracted 6x6 spatial stiffness matrix K = C^-1 [N/rad, (N*m)/rad; N/m, (N*m)/m].
     * Row-major flat array of 36 double-precision floats.
     */
    double stiffness_matrix_6x6[36];

    /**
     * 3D Coordinates of the Elastic Center of Stiffness [X, Y, Z] in stage coordinate space.
     * Center where pure transverse forces produce zero parasitic angular tilt.
     */
    double center_of_stiffness[3];

    /**
     * Parasitic axis cross-coupling drift error metrics:
     */
    double parasitic_drift_translation[3];       /**< Off-axis translational displacement drift under primary motion (m) */
    double parasitic_drift_rotation[3];          /**< Off-axis parasitic angular tilt (radians) */

    /**
     * FACT (Freedom and Constraint Topologies) screw axes
     */
    const cad_fact_screw_axis_t* fact_screw_axes; /**< Array of freedom and constraint screw lines */
    uint32_t fact_screw_axis_count;              /**< Total screw lines */

    /**
     * Zero-copy packed 3D line segment vertices [X0, Y0, Z0, X1, Y1, Z1, ...] (Float32Array).
     * Ready for direct Three.js LineSegments buffer geometry rendering.
     */
    const float* fact_visual_lines;
    uint32_t fact_visual_line_count;             /**< Number of 2-point line segments (vertices = count * 2) */
} cad_flexure_analysis_t;
typedef cad_flexure_analysis_t CadFlexureAnalysis;

/**
 * @brief Generate a tetrahedral Delaunay mesh from a B-Rep solid body.
 *
 * @param solid Target solid handle
 * @param params Meshing element type, maximum edge size, and quality parameters
 * @param out_mesh Output zero-copy tetrahedral mesh structure
 * @return CAD_STATUS_OK on success
 */
cad_status_t cad_fea_mesh_generate(
    cad_solid_handle_t solid,
    const cad_fea_mesh_params_t* params,
    cad_tet_mesh_t* out_mesh
);

/**
 * @brief Free allocated memory associated with a tetrahedral mesh.
 */
cad_status_t cad_fea_mesh_free(cad_tet_mesh_t* mesh);

/**
 * @brief Execute finite element analysis (FEA) on a B-Rep solid body.
 *
 * Discretizes the solid into a tetrahedral mesh, applies boundary conditions and loads,
 * and solves the equilibrium system using Jacobi-preconditioned conjugate gradient (PCG).
 *
 * @param solid Target B-Rep solid handle
 * @param mode Solver formulation (CAD_FEA_MODE_LINEAR_ELASTIC or CAD_FEA_MODE_COROTATIONAL_NONLINEAR)
 * @param material Material mechanical properties (Young's modulus, Poisson's ratio, yield strength, density)
 * @param mesh_params Discretization element type and edge length constraints
 * @param boundary_conditions Array of boundary constraints and force/moment loads
 * @param bc_count Number of entries in boundary_conditions array
 * @param out_result Output zero-copy FEA results slice (displacements, stresses, modes)
 * @return CAD_STATUS_OK on success
 */
cad_status_t cad_fea_solve(
    cad_solid_handle_t solid,
    cad_fea_mode_t mode,
    const cad_material_props_t* material,
    const cad_fea_mesh_params_t* mesh_params,
    const cad_boundary_condition_t* boundary_conditions,
    uint32_t bc_count,
    cad_fea_result_slice_t* out_result
);

/**
 * @brief Free allocated memory associated with an FEA result slice.
 */
cad_status_t cad_fea_result_free(cad_fea_result_slice_t* result);

/**
 * @brief Synthesize and evaluate compliant mechanism flexure performance.
 *
 * Extracts the 6x6 spatial compliance and stiffness matrices, calculates the center of stiffness,
 * quantifies parasitic cross-axis drift, and outputs FACT freedom and constraint screw lines.
 *
 * @param solid Target compliant mechanism solid handle
 * @param fixed_face_id Persistent CadTopoId of the fixed reference ground face
 * @param stage_face_id Persistent CadTopoId of the moving stage / tip face
 * @param material Material Young's modulus, Poisson's ratio, and yield strength
 * @param out_analysis Output compliance matrix, center of stiffness, drift, and FACT visualization
 * @return CAD_STATUS_OK on success
 */
cad_status_t cad_flexure_analyze(
    cad_solid_handle_t solid,
    cad_topo_id_t fixed_face_id,
    cad_topo_id_t stage_face_id,
    const cad_material_props_t* material,
    cad_flexure_analysis_t* out_analysis
);

/**
 * @brief Free allocated memory associated with a flexure compliance analysis.
 */
cad_status_t cad_flexure_analysis_free(cad_flexure_analysis_t* analysis);

#ifdef __cplusplus
}
#endif

#endif /* CAD_KERNEL_H */
