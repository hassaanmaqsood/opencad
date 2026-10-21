#ifndef OCC_ORACLE_H
#define OCC_ORACLE_H

#include "cad_kernel.h"

#ifdef __cplusplus
extern "C" {
#endif

/* OpenCASCADE / Reference Oracle specific C ABI implementations */
cad_status_t occ_kernel_init(void);
cad_status_t occ_primitive_box(float dx, float dy, float dz, cad_solid_handle_t* out_solid);
cad_status_t occ_primitive_cylinder(float radius, float height, cad_solid_handle_t* out_solid);
cad_status_t occ_op_extrude(const float* points, uint32_t num_points, cad_vec3_t vec, cad_solid_handle_t* out_solid);
cad_status_t occ_op_boolean(cad_op_type_t op, cad_solid_handle_t a, cad_solid_handle_t b, cad_solid_handle_t* out_solid);
cad_status_t occ_solid_tessellate(cad_solid_handle_t solid, float chordal_defl, float angular_defl, cad_mesh_t* out_mesh);
cad_status_t occ_solid_get_stats(cad_solid_handle_t solid, cad_brep_stats_t* out_stats);
cad_status_t occ_mesh_free(cad_mesh_t* mesh);
cad_status_t occ_solid_release(cad_solid_handle_t solid);

/* Wave 3: Multi-Feature DAG Evaluation Differential Oracle Functions */
cad_status_t occ_dag_register_feature_solid(uint32_t feature_id, cad_solid_handle_t solid);
cad_status_t occ_dag_register_sketch(uint32_t feature_id, const float* points, uint32_t num_points);
cad_status_t occ_dag_evaluate(
    const cad_feature_node_t* nodes,
    uint32_t node_count,
    uint32_t rollback_index,
    cad_solid_handle_t* out_solid
);
cad_status_t occ_dag_set_rollback_index(uint32_t rollback_index);


#ifdef __cplusplus
}
#endif

#endif /* OCC_ORACLE_H */
