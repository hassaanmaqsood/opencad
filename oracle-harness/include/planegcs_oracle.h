#ifndef PLANEGCS_ORACLE_H
#define PLANEGCS_ORACLE_H

#include <stdint.h>
#include <stddef.h>
#include "cad_kernel.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef enum gcs_constraint_type_e {
    GCS_COINCIDENT = 0,
    GCS_DISTANCE = 1,
    GCS_HORIZONTAL = 2,
    GCS_VERTICAL = 3,
    GCS_PARALLEL = 4,
    GCS_PERPENDICULAR = 5,
    GCS_TANGENT = 6,
    GCS_EQUAL = 7,
    GCS_SYMMETRIC = 8,
    GCS_ANGLE = 9,
    GCS_RADIUS = 10
} gcs_constraint_type_t;

typedef struct gcs_point_s {
    double x;
    double y;
} gcs_point_t;

typedef struct gcs_line_s {
    uint32_t p1_idx;
    uint32_t p2_idx;
} gcs_line_t;

typedef struct gcs_constraint_s {
    gcs_constraint_type_t type;
    uint32_t elem1;
    uint32_t elem2;
    double value;
    uint32_t elem3;
    uint32_t elem4;
} gcs_constraint_t;

int planegcs_solve_2d(
    gcs_point_t* points, uint32_t num_points,
    const gcs_line_t* lines, uint32_t num_lines,
    const gcs_constraint_t* constraints, uint32_t num_constraints,
    uint32_t max_iterations, double convergence_tol
);

int planegcs_solve_sketch(
    cad_sketch_point2d_t* points, uint32_t point_count,
    const cad_sketch_line2d_t* lines, uint32_t line_count,
    const cad_sketch_arc2d_t* arcs, uint32_t arc_count,
    const cad_sketch_circle2d_t* circles, uint32_t circle_count,
    const cad_sketch_constraint_t* constraints, uint32_t constraint_count,
    uint32_t max_iterations, double convergence_tol,
    cad_solver_status_t* out_status
);

#ifdef __cplusplus
}
#endif

#endif /* PLANEGCS_ORACLE_H */
