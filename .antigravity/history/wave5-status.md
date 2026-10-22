# Wave 5 Status: Dress-Up Operations, 3D Assembly Mates & Multi-LOD Tessellation

- **Status:** ABI LOCKED (Implementation Ready)
- **Architect:** `cad-architect`
- **Timestamp:** 2026-10-22T08:08:00+05:00

---

## 1. Locked Wave 5 C ABI Specifications (`abi/cad_kernel.h`)

### 1.1 Dress-Up Feature Types & Operation Payloads

```c
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

typedef enum cad_fillet_mode_e {
    CAD_FILLET_CONSTANT_RADIUS = 0,     /**< Uniform rolling-ball blend radius */
    CAD_FILLET_VARIABLE_RADIUS = 1,     /**< Linear taper from radius_start to radius_end */
    CAD_FILLET_CHORDAL = 2              /**< Fixed chord width blend */
} cad_fillet_mode_t;
typedef cad_fillet_mode_t CadFilletMode;

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

typedef struct cad_chamfer_op_s {
    cad_chamfer_mode_t mode;            /**< Equal distance, two distances, or distance/angle */
    double distance1;                   /**< Primary setback distance (mm) */
    double distance2;                   /**< Secondary setback distance (for two-distance mode) */
    double angle_rad;                   /**< Chamfer bevel angle (for distance/angle mode) */
    uint32_t target_edge_count;         /**< Number of target edge IDs in target_edge_ids */
    cad_topo_id_t target_edge_ids[CAD_MAX_FEATURE_TARGETS]; /**< Edges to be beveled */
} cad_chamfer_op_t;
typedef cad_chamfer_op_t CadChamferOp;

typedef struct cad_shell_op_s {
    double thickness;                   /**< Wall thickness (positive = inward offset, negative = outward) */
    uint8_t is_inward;                  /**< 1 for inward hollow cavity, 0 for outward */
    uint32_t open_face_count;           /**< Number of open faces removed from the hollowed solid */
    cad_topo_id_t open_face_ids[CAD_MAX_FEATURE_TARGETS]; /**< Face CadTopoIds to remain open */
} cad_shell_op_t;
typedef cad_shell_op_t CadShellOp;

typedef struct cad_draft_op_s {
    double draft_angle_rad;             /**< Draft taper angle (radians) */
    cad_vec3_t pull_direction;          /**< Mold draw / pull vector direction */
    cad_vec3_t neutral_plane_point;     /**< Point on parting / neutral reference plane */
    cad_vec3_t neutral_plane_normal;    /**< Normal vector of neutral reference plane */
    uint32_t draft_face_count;          /**< Number of faces to taper */
    cad_topo_id_t draft_face_ids[CAD_MAX_FEATURE_TARGETS]; /**< Faces subject to draft taper */
} cad_draft_op_t;
typedef cad_draft_op_t CadDraftOp;
```

### 1.2 Procedural Dress-Up Functions

```c
cad_status_t cad_solid_fillet(
    cad_solid_handle_t solid,
    const cad_fillet_op_t* fillet_op,
    cad_solid_handle_t* out_solid
);

cad_status_t cad_solid_chamfer(
    cad_solid_handle_t solid,
    const cad_chamfer_op_t* chamfer_op,
    cad_solid_handle_t* out_solid
);

cad_status_t cad_solid_shell(
    cad_solid_handle_t solid,
    const cad_shell_op_t* shell_op,
    cad_solid_handle_t* out_solid
);

cad_status_t cad_solid_draft(
    cad_solid_handle_t solid,
    const cad_draft_op_t* draft_op,
    cad_solid_handle_t* out_solid
);
```

### 1.3 3D Assembly Mates & Multi-Instance Kinematic Solver

```c
typedef enum cad_assembly_mate_type_e {
    CAD_MATE_COINCIDENT = 0,    /**< MATE_COINCIDENT: Planar coincidence or point-on-point */
    CAD_MATE_CONCENTRIC = 1,    /**< MATE_CONCENTRIC: Collinear cylindrical/revolute axes */
    CAD_MATE_PARALLEL = 2,      /**< MATE_PARALLEL: Parallel planar normals or axes */
    CAD_MATE_DISTANCE = 3,      /**< MATE_DISTANCE: Fixed Euclidean offset distance */
    CAD_MATE_ANGLE = 4,         /**< MATE_ANGLE: Fixed dihedral angle between planar entities */
    CAD_MATE_GEAR = 5           /**< MATE_GEAR: Coupled rotational gear/pitch ratio */
} cad_assembly_mate_type_t;
typedef cad_assembly_mate_type_t CadAssemblyMateType;

typedef struct cad_assembly_instance_s {
    uint32_t instance_id;                /**< Unique assembly instance identifier */
    cad_solid_handle_t solid_handle;     /**< Source prototype solid handle */
    uint8_t is_grounded;                 /**< 1 if instance is anchored/fixed in space (0 DOF) */
    float initial_transform[16];         /**< Initial 4x4 column-major affine transform matrix */
    char name[32];                       /**< Human-readable instance tag */
} cad_assembly_instance_t;
typedef cad_assembly_instance_t CadAssemblyInstance;

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

typedef struct cad_assembly_solve_status_s {
    cad_solve_state_t solve_state;       /**< Solved, under-constrained, over-constrained, conflicting */
    uint32_t total_dof;                  /**< Remaining system degrees of freedom */
    uint32_t iterations;                 /**< Iterations taken to converge */
    double max_residual;                 /**< Maximum algebraic constraint residual */
    uint32_t conflicting_count;          /**< Number of conflicting mate IDs */
    const uint32_t* conflicting_mate_ids;/**< Pointer to conflicting mate IDs */
} cad_assembly_solve_status_t;
typedef cad_assembly_solve_status_t CadAssemblySolveStatus;

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
```

### 1.4 Multi-Deflection LOD Tessellation

```c
typedef enum cad_lod_level_e {
    CAD_LOD_COARSE = 0,   /**< Coarse LOD: fast preview / background (chordal ~0.5mm, angular ~0.5 rad) */
    CAD_LOD_MEDIUM = 1,   /**< Medium LOD: standard viewport interaction (chordal ~0.1mm, angular ~0.2 rad) */
    CAD_LOD_FINE = 2      /**< Fine LOD: high-precision / export rendering (chordal ~0.01mm, angular ~0.05 rad) */
} cad_lod_level_t;
typedef cad_lod_level_t CadLodLevel;

cad_status_t cad_solid_tessellate_lod(
    cad_solid_handle_t solid,
    cad_lod_level_t lod_level,
    cad_tessellated_solid_slice_t* out_slice
);
```

---

## 2. Verification Status

- **Syntax Validation:**
  - `gcc -fsyntax-only -std=c11 -Wall -Wextra abi/cad_kernel.h` -> Exit Code `0`
  - `g++ -fsyntax-only -std=c++17 -Wall -Wextra abi/cad_kernel.h` -> Exit Code `0`
- **Differential Oracle Harness Build:**
  - `cd oracle-harness/build && make -j$(nproc)` -> Exit Code `0`
- **Native Zig Kernel Tests:**
  - `cd kernel-zig && zig build test` -> Exit Code `0`
- **Web App Compilation:**
  - `npm --prefix web-app run build` -> Exit Code `0`
- **Stop Constraint Enforced:** Implementation files untouched; ABI locked for parallel subagent execution.
