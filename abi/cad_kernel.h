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
    CAD_STATUS_ERROR_NOT_IMPLEMENTED = 6
} cad_status_t;

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

#ifdef __cplusplus
}
#endif

#endif /* CAD_KERNEL_H */
