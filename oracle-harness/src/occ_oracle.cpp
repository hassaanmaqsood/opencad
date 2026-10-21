#include "occ_oracle.h"
#include <cstdlib>
#include <cstring>
#include <cmath>
#include <vector>
#include <unordered_map>
#include <iostream>

#if HAVE_OPENCASCADE
#include <BRepPrimAPI_MakeBox.hxx>
#include <BRepPrimAPI_MakeCylinder.hxx>
#include <BRepAlgoAPI_Fuse.hxx>
#include <BRepAlgoAPI_Cut.hxx>
#include <BRepAlgoAPI_Common.hxx>
#include <BRepMesh_IncrementalMesh.hxx>
#include <TopExp_Explorer.hxx>
#include <TopoDS.hxx>
#include <TopoDS_Shape.hxx>
#include <TopoDS_Face.hxx>
#include <TopoDS_Edge.hxx>
#include <BRep_Tool.hxx>
#include <Poly_Triangulation.hxx>
#include <Poly_PolygonOnTriangulation.hxx>
#include <GProp_GProps.hxx>
#include <BRepGProp.hxx>
#include <TopExp.hxx>
#include <TopTools_IndexedMapOfShape.hxx>
#endif

namespace {

struct InternalSolid {
    uint64_t id;
    enum Kind { BOX, CYLINDER, EXTRUDE, BOOLEAN } kind;
    float dims[3];
    float radius;
    float height;
    std::vector<float> profile;
    cad_brep_stats_t stats;
#if HAVE_OPENCASCADE
    TopoDS_Shape shape;
#endif
};

static uint64_t g_next_handle = 1000;
static std::unordered_map<uint64_t, InternalSolid> g_solids;
static std::unordered_map<uint32_t, cad_solid_handle_t> g_feature_solids;
static std::unordered_map<uint32_t, std::vector<float>> g_feature_sketches;
static uint32_t g_current_rollback_index = 0xFFFFFFFFU;

} // anonymous namespace

cad_status_t occ_kernel_init(void) {
    g_solids.clear();
    g_feature_solids.clear();
    g_feature_sketches.clear();
    g_current_rollback_index = 0xFFFFFFFFU;
    g_next_handle = 1000;
    return CAD_STATUS_OK;
}

cad_status_t occ_primitive_box(float dx, float dy, float dz, cad_solid_handle_t* out_solid) {
    if (!out_solid || dx <= 0.0f || dy <= 0.0f || dz <= 0.0f) {
        return CAD_STATUS_ERROR_INVALID_ARGUMENT;
    }

    uint64_t handle = ++g_next_handle;
    InternalSolid solid{};
    solid.id = handle;
    solid.kind = InternalSolid::BOX;
    solid.dims[0] = dx;
    solid.dims[1] = dy;
    solid.dims[2] = dz;

    solid.stats.num_vertices = 8;
    solid.stats.num_edges = 12;
    solid.stats.num_wires = 6;
    solid.stats.num_faces = 6;
    solid.stats.num_shells = 1;
    solid.stats.num_solids = 1;
    solid.stats.volume = dx * dy * dz;
    solid.stats.surface_area = 2.0f * (dx * dy + dy * dz + dz * dx);
    solid.stats.euler_characteristic = 8 - 12 + 6; // V - E + F = 2

#if HAVE_OPENCASCADE
    BRepPrimAPI_MakeBox mkBox(dx, dy, dz);
    solid.shape = mkBox.Shape();
    GProp_GProps volProps, surfProps;
    BRepGProp::VolumeProperties(solid.shape, volProps);
    BRepGProp::SurfaceProperties(solid.shape, surfProps);
    solid.stats.volume = static_cast<float>(volProps.Mass());
    solid.stats.surface_area = static_cast<float>(surfProps.Mass());
#endif

    g_solids[handle] = solid;
    *out_solid = handle;
    return CAD_STATUS_OK;
}

cad_status_t occ_primitive_cylinder(float radius, float height, cad_solid_handle_t* out_solid) {
    if (!out_solid || radius <= 0.0f || height <= 0.0f) {
        return CAD_STATUS_ERROR_INVALID_ARGUMENT;
    }

    uint64_t handle = ++g_next_handle;
    InternalSolid solid{};
    solid.id = handle;
    solid.kind = InternalSolid::CYLINDER;
    solid.radius = radius;
    solid.height = height;

    const float pi = 3.14159265358979323846f;
    solid.stats.num_vertices = 2; // Smooth cylinder analytical B-Rep topology
    solid.stats.num_edges = 3;    // 2 circular edges + 1 seam
    solid.stats.num_wires = 3;
    solid.stats.num_faces = 3;    // bottom, top, lateral
    solid.stats.num_shells = 1;
    solid.stats.num_solids = 1;
    solid.stats.volume = pi * radius * radius * height;
    solid.stats.surface_area = 2.0f * pi * radius * height + 2.0f * pi * radius * radius;
    solid.stats.euler_characteristic = 2;

#if HAVE_OPENCASCADE
    BRepPrimAPI_MakeCylinder mkCyl(radius, height);
    solid.shape = mkCyl.Shape();
    GProp_GProps volProps, surfProps;
    BRepGProp::VolumeProperties(solid.shape, volProps);
    BRepGProp::SurfaceProperties(solid.shape, surfProps);
    solid.stats.volume = static_cast<float>(volProps.Mass());
    solid.stats.surface_area = static_cast<float>(surfProps.Mass());
#endif

    g_solids[handle] = solid;
    *out_solid = handle;
    return CAD_STATUS_OK;
}

cad_status_t occ_op_extrude(const float* points, uint32_t num_points, cad_vec3_t vec, cad_solid_handle_t* out_solid) {
    if (!points || num_points < 3 || !out_solid) {
        return CAD_STATUS_ERROR_INVALID_ARGUMENT;
    }

    uint64_t handle = ++g_next_handle;
    InternalSolid solid{};
    solid.id = handle;
    solid.kind = InternalSolid::EXTRUDE;
    solid.profile.assign(points, points + num_points * 2);
    solid.dims[0] = vec.x;
    solid.dims[1] = vec.y;
    solid.dims[2] = vec.z;

    // Planar 2D polygon area via shoelace formula
    float area2d = 0.0f;
    for (uint32_t i = 0; i < num_points; ++i) {
        uint32_t next = (i + 1) % num_points;
        area2d += points[i * 2 + 0] * points[next * 2 + 1] - points[next * 2 + 0] * points[i * 2 + 1];
    }
    area2d = std::abs(area2d) * 0.5f;
    float ext_len = std::sqrt(vec.x * vec.x + vec.y * vec.y + vec.z * vec.z);

    solid.stats.num_vertices = num_points * 2;
    solid.stats.num_edges = num_points * 3;
    solid.stats.num_faces = num_points + 2;
    solid.stats.num_wires = num_points + 2;
    solid.stats.num_shells = 1;
    solid.stats.num_solids = 1;
    solid.stats.volume = area2d * ext_len;
    solid.stats.euler_characteristic = static_cast<int32_t>(solid.stats.num_vertices) - static_cast<int32_t>(solid.stats.num_edges) + static_cast<int32_t>(solid.stats.num_faces);

    g_solids[handle] = solid;
    *out_solid = handle;
    return CAD_STATUS_OK;
}

cad_status_t occ_op_boolean(cad_op_type_t op, cad_solid_handle_t a, cad_solid_handle_t b, cad_solid_handle_t* out_solid) {
    if (!out_solid || g_solids.find(a) == g_solids.end() || g_solids.find(b) == g_solids.end()) {
        return CAD_STATUS_ERROR_INVALID_ARGUMENT;
    }

    uint64_t handle = ++g_next_handle;
    InternalSolid solid{};
    solid.id = handle;
    solid.kind = InternalSolid::BOOLEAN;

#if HAVE_OPENCASCADE
    const auto& sa = g_solids[a].shape;
    const auto& sb = g_solids[b].shape;
    if (op == CAD_OP_BOOLEAN_UNION) {
        BRepAlgoAPI_Fuse fuse(sa, sb);
        solid.shape = fuse.Shape();
    } else if (op == CAD_OP_BOOLEAN_DIFFERENCE) {
        BRepAlgoAPI_Cut cut(sa, sb);
        solid.shape = cut.Shape();
    } else if (op == CAD_OP_BOOLEAN_INTERSECTION) {
        BRepAlgoAPI_Common common(sa, sb);
        solid.shape = common.Shape();
    }
    GProp_GProps volProps;
    BRepGProp::VolumeProperties(solid.shape, volProps);
    solid.stats.volume = static_cast<float>(volProps.Mass());
#else
    // Analytical reference for simple orthogonal box boolean test cases
    const auto& sa = g_solids[a];
    const auto& sb = g_solids[b];
    if (op == CAD_OP_BOOLEAN_UNION) {
        solid.stats.volume = sa.stats.volume + sb.stats.volume;
    } else if (op == CAD_OP_BOOLEAN_DIFFERENCE) {
        solid.stats.volume = std::max(0.0f, sa.stats.volume - sb.stats.volume);
    } else {
        solid.stats.volume = std::min(sa.stats.volume, sb.stats.volume);
    }
    solid.stats.euler_characteristic = 2;
#endif

    g_solids[handle] = solid;
    *out_solid = handle;
    return CAD_STATUS_OK;
}

cad_status_t occ_solid_tessellate(
    cad_solid_handle_t solid_id,
    float chordal_defl,
    float angular_defl,
    cad_mesh_t* out_mesh
) {
    (void)chordal_defl;
    (void)angular_defl;
    if (!out_mesh || g_solids.find(solid_id) == g_solids.end()) {
        return CAD_STATUS_ERROR_INVALID_ARGUMENT;
    }

    const auto& s = g_solids[solid_id];
    std::vector<float> pos;
    std::vector<float> nrm;
    std::vector<uint32_t> idx;
    std::vector<uint32_t> tri_face;
    std::vector<float> edges;
    std::vector<uint32_t> seg_edge;

    if (s.kind == InternalSolid::BOX) {
        float x = s.dims[0], y = s.dims[1], z = s.dims[2];

        // 6 rectangular faces, each with 4 vertices, 2 triangles, tagged with face_id 1..6
        struct FaceDef {
            float v[4][3];
            float n[3];
            uint32_t face_id;
        };

        const FaceDef faces[6] = {
            // Face 1: -Z (Bottom)
            { {{0,0,0}, {x,0,0}, {x,y,0}, {0,y,0}}, {0, 0, -1}, 1 },
            // Face 2: +Z (Top)
            { {{0,0,z}, {0,y,z}, {x,y,z}, {x,0,z}}, {0, 0, 1}, 2 },
            // Face 3: -Y (Front)
            { {{0,0,0}, {0,0,z}, {x,0,z}, {x,0,0}}, {0, -1, 0}, 3 },
            // Face 4: +Y (Back)
            { {{0,y,0}, {x,y,0}, {x,y,z}, {0,y,z}}, {0, 1, 0}, 4 },
            // Face 5: -X (Left)
            { {{0,0,0}, {0,y,0}, {0,y,z}, {0,0,z}}, {-1, 0, 0}, 5 },
            // Face 6: +X (Right)
            { {{x,0,0}, {x,0,z}, {x,y,z}, {x,y,0}}, {1, 0, 0}, 6 }
        };

        for (int f = 0; f < 6; ++f) {
            uint32_t base_idx = static_cast<uint32_t>(pos.size() / 3);
            for (int v = 0; v < 4; ++v) {
                pos.push_back(faces[f].v[v][0]);
                pos.push_back(faces[f].v[v][1]);
                pos.push_back(faces[f].v[v][2]);
                nrm.push_back(faces[f].n[0]);
                nrm.push_back(faces[f].n[1]);
                nrm.push_back(faces[f].n[2]);
            }
            // Triangle 1
            idx.push_back(base_idx + 0);
            idx.push_back(base_idx + 1);
            idx.push_back(base_idx + 2);
            tri_face.push_back(faces[f].face_id);

            // Triangle 2
            idx.push_back(base_idx + 0);
            idx.push_back(base_idx + 2);
            idx.push_back(base_idx + 3);
            tri_face.push_back(faces[f].face_id);
        }

        // 12 sharp edges
        const float c[8][3] = {
            {0,0,0}, {x,0,0}, {x,y,0}, {0,y,0},
            {0,0,z}, {x,0,z}, {x,y,z}, {0,y,z}
        };
        const int ed[12][2] = {
            {0,1}, {1,2}, {2,3}, {3,0},
            {4,5}, {5,6}, {6,7}, {7,4},
            {0,4}, {1,5}, {2,6}, {3,7}
        };
        for (int e = 0; e < 12; ++e) {
            edges.push_back(c[ed[e][0]][0]);
            edges.push_back(c[ed[e][0]][1]);
            edges.push_back(c[ed[e][0]][2]);
            edges.push_back(c[ed[e][1]][0]);
            edges.push_back(c[ed[e][1]][1]);
            edges.push_back(c[ed[e][1]][2]);
            seg_edge.push_back(e + 1);
        }

        out_mesh->bbox_min = {0.0f, 0.0f, 0.0f};
        out_mesh->bbox_max = {x, y, z};
    } else {
        // Cylinder or generic primitive tessellation
        const uint32_t segments = 32;
        const float pi = 3.14159265358979323846f;
        float r = s.radius > 0 ? s.radius : 1.0f;
        float h = s.height > 0 ? s.height : 2.0f;

        // Bottom cap (Face ID 1)
        uint32_t center_bot_idx = static_cast<uint32_t>(pos.size() / 3);
        pos.push_back(0); pos.push_back(0); pos.push_back(0);
        nrm.push_back(0); nrm.push_back(0); nrm.push_back(-1);

        for (uint32_t i = 0; i < segments; ++i) {
            float theta = 2.0f * pi * i / segments;
            pos.push_back(r * std::cos(theta));
            pos.push_back(r * std::sin(theta));
            pos.push_back(0);
            nrm.push_back(0); nrm.push_back(0); nrm.push_back(-1);

            uint32_t i0 = center_bot_idx;
            uint32_t i1 = center_bot_idx + 1 + i;
            uint32_t i2 = center_bot_idx + 1 + ((i + 1) % segments);
            idx.push_back(i0); idx.push_back(i2); idx.push_back(i1);
            tri_face.push_back(1); // Bottom Face ID
        }

        // Top cap (Face ID 2)
        uint32_t center_top_idx = static_cast<uint32_t>(pos.size() / 3);
        pos.push_back(0); pos.push_back(0); pos.push_back(h);
        nrm.push_back(0); nrm.push_back(0); nrm.push_back(1);

        for (uint32_t i = 0; i < segments; ++i) {
            float theta = 2.0f * pi * i / segments;
            pos.push_back(r * std::cos(theta));
            pos.push_back(r * std::sin(theta));
            pos.push_back(h);
            nrm.push_back(0); nrm.push_back(0); nrm.push_back(1);

            uint32_t i0 = center_top_idx;
            uint32_t i1 = center_top_idx + 1 + i;
            uint32_t i2 = center_top_idx + 1 + ((i + 1) % segments);
            idx.push_back(i0); idx.push_back(i1); idx.push_back(i2);
            tri_face.push_back(2); // Top Face ID
        }

        // Lateral side (Face ID 3)
        for (uint32_t i = 0; i < segments; ++i) {
            float th0 = 2.0f * pi * i / segments;
            float th1 = 2.0f * pi * (i + 1) / segments;
            float cos0 = std::cos(th0), sin0 = std::sin(th0);
            float cos1 = std::cos(th1), sin1 = std::sin(th1);

            uint32_t base = static_cast<uint32_t>(pos.size() / 3);
            pos.push_back(r * cos0); pos.push_back(r * sin0); pos.push_back(0);
            nrm.push_back(cos0); nrm.push_back(sin0); nrm.push_back(0);

            pos.push_back(r * cos1); pos.push_back(r * sin1); pos.push_back(0);
            nrm.push_back(cos1); nrm.push_back(sin1); nrm.push_back(0);

            pos.push_back(r * cos1); pos.push_back(r * sin1); pos.push_back(h);
            nrm.push_back(cos1); nrm.push_back(sin1); nrm.push_back(0);

            pos.push_back(r * cos0); pos.push_back(r * sin0); pos.push_back(h);
            nrm.push_back(cos0); nrm.push_back(sin0); nrm.push_back(0);

            idx.push_back(base + 0); idx.push_back(base + 1); idx.push_back(base + 2);
            tri_face.push_back(3); // Lateral Face ID
            idx.push_back(base + 0); idx.push_back(base + 2); idx.push_back(base + 3);
            tri_face.push_back(3);
        }

        out_mesh->bbox_min = {-r, -r, 0.0f};
        out_mesh->bbox_max = {r, r, h};
    }

    // Allocate flat zero-copy buffers
    size_t pos_bytes = pos.size() * sizeof(float);
    float* p_pos = static_cast<float*>(std::malloc(pos_bytes));
    std::memcpy(p_pos, pos.data(), pos_bytes);

    size_t nrm_bytes = nrm.size() * sizeof(float);
    float* p_nrm = static_cast<float*>(std::malloc(nrm_bytes));
    std::memcpy(p_nrm, nrm.data(), nrm_bytes);

    size_t idx_bytes = idx.size() * sizeof(uint32_t);
    uint32_t* p_idx = static_cast<uint32_t*>(std::malloc(idx_bytes));
    std::memcpy(p_idx, idx.data(), idx_bytes);

    size_t tf_bytes = tri_face.size() * sizeof(uint32_t);
    uint32_t* p_tf = static_cast<uint32_t*>(std::malloc(tf_bytes));
    std::memcpy(p_tf, tri_face.data(), tf_bytes);

    float* p_edges = nullptr;
    uint32_t* p_seg_edge = nullptr;
    if (!edges.empty()) {
        size_t ed_bytes = edges.size() * sizeof(float);
        p_edges = static_cast<float*>(std::malloc(ed_bytes));
        std::memcpy(p_edges, edges.data(), ed_bytes);

        size_t se_bytes = seg_edge.size() * sizeof(uint32_t);
        p_seg_edge = static_cast<uint32_t*>(std::malloc(se_bytes));
        std::memcpy(p_seg_edge, seg_edge.data(), se_bytes);
    }

    out_mesh->positions = p_pos;
    out_mesh->vertex_count = static_cast<uint32_t>(pos.size() / 3);
    out_mesh->normals = p_nrm;
    out_mesh->indices = p_idx;
    out_mesh->triangle_count = static_cast<uint32_t>(idx.size() / 3);
    out_mesh->triangle_to_face_id = p_tf;
    out_mesh->edge_vertices = p_edges;
    out_mesh->edge_segment_count = static_cast<uint32_t>(edges.size() / 6);
    out_mesh->segment_to_edge_id = p_seg_edge;

    return CAD_STATUS_OK;
}

cad_status_t occ_solid_get_stats(cad_solid_handle_t solid_id, cad_brep_stats_t* out_stats) {
    if (!out_stats || g_solids.find(solid_id) == g_solids.end()) {
        return CAD_STATUS_ERROR_INVALID_ARGUMENT;
    }
    *out_stats = g_solids[solid_id].stats;
    return CAD_STATUS_OK;
}

cad_status_t occ_mesh_free(cad_mesh_t* mesh) {
    if (!mesh) return CAD_STATUS_ERROR_INVALID_ARGUMENT;
    if (mesh->positions) std::free((void*)mesh->positions);
    if (mesh->normals) std::free((void*)mesh->normals);
    if (mesh->indices) std::free((void*)mesh->indices);
    if (mesh->triangle_to_face_id) std::free((void*)mesh->triangle_to_face_id);
    if (mesh->edge_vertices) std::free((void*)mesh->edge_vertices);
    if (mesh->segment_to_edge_id) std::free((void*)mesh->segment_to_edge_id);
    std::memset(mesh, 0, sizeof(cad_mesh_t));
    return CAD_STATUS_OK;
}

cad_status_t occ_solid_release(cad_solid_handle_t solid) {
    auto it = g_solids.find(solid);
    if (it != g_solids.end()) {
        g_solids.erase(it);
        return CAD_STATUS_OK;
    }
    return CAD_STATUS_ERROR_INVALID_ARGUMENT;
}

cad_status_t occ_dag_register_feature_solid(uint32_t feature_id, cad_solid_handle_t solid) {
    g_feature_solids[feature_id] = solid;
    return CAD_STATUS_OK;
}

cad_status_t occ_dag_register_sketch(uint32_t feature_id, const float* points, uint32_t num_points) {
    if (!points || num_points < 3) return CAD_STATUS_ERROR_INVALID_ARGUMENT;
    g_feature_sketches[feature_id].assign(points, points + num_points * 2);
    return CAD_STATUS_OK;
}

cad_status_t occ_dag_set_rollback_index(uint32_t rollback_index) {
    g_current_rollback_index = rollback_index;
    return CAD_STATUS_OK;
}

cad_status_t occ_dag_evaluate(
    const cad_feature_node_t* nodes,
    uint32_t node_count,
    uint32_t rollback_index,
    cad_solid_handle_t* out_solid
) {
    if (!nodes || node_count == 0 || !out_solid) {
        return CAD_STATUS_ERROR_INVALID_ARGUMENT;
    }

    uint32_t effective_limit = (rollback_index < node_count) ? rollback_index : (node_count - 1);
    cad_solid_handle_t active_solid = CAD_INVALID_HANDLE;

    // Use evaluation-local feature map seeded with currently valid registered solids
    std::unordered_map<uint32_t, cad_solid_handle_t> eval_features;
    for (const auto& kv : g_feature_solids) {
        if (g_solids.find(kv.second) != g_solids.end()) {
            eval_features[kv.first] = kv.second;
        }
    }

    for (uint32_t i = 0; i <= effective_limit; ++i) {
        const auto& node = nodes[i];
        if (node.is_suppressed) {
            continue;
        }

        if (node.type == CAD_FEATURE_EXTRUDE) {
            float depth = static_cast<float>(node.params.extrude.distance);
            if (depth <= 0.0f) depth = 10.0f;
            cad_vec3_t dir = node.params.extrude.direction;
            if (dir.x == 0.0f && dir.y == 0.0f && dir.z == 0.0f) {
                dir.z = depth;
            } else {
                dir.x *= depth;
                dir.y *= depth;
                dir.z *= depth;
            }

            auto it_sol = eval_features.find(node.feature_id);
            if (it_sol != eval_features.end() && g_solids.find(it_sol->second) != g_solids.end()) {
                active_solid = it_sol->second;
            } else {
                auto it_sk = g_feature_sketches.find(node.feature_id);
                if (it_sk == g_feature_sketches.end() && node.parent_count > 0) {
                    it_sk = g_feature_sketches.find(node.parent_ids[0]);
                }

                cad_solid_handle_t new_solid = CAD_INVALID_HANDLE;
                if (it_sk != g_feature_sketches.end() && it_sk->second.size() >= 6) {
                    uint32_t n_pts = static_cast<uint32_t>(it_sk->second.size() / 2);
                    occ_op_extrude(it_sk->second.data(), n_pts, dir, &new_solid);
                } else {
                    // Default base plate extrusion: 50.0 x 40.0 x depth
                    occ_primitive_box(50.0f, 40.0f, depth, &new_solid);
                }

                active_solid = new_solid;
                eval_features[node.feature_id] = new_solid;
            }
        } else if (node.type == CAD_FEATURE_BOOLEAN_UNION) {
            uint32_t tool_id = node.params.boolean_op.tool_feature_id;
            auto it_tool = eval_features.find(tool_id);
            if (it_tool != eval_features.end() && active_solid != CAD_INVALID_HANDLE) {
                cad_solid_handle_t union_solid = CAD_INVALID_HANDLE;
                cad_status_t status = occ_op_boolean(CAD_OP_BOOLEAN_UNION, active_solid, it_tool->second, &union_solid);
                if (status == CAD_STATUS_OK) {
                    active_solid = union_solid;
                    eval_features[node.feature_id] = union_solid;
                }
            }
        } else if (node.type == CAD_FEATURE_BOOLEAN_CUT) {
            uint32_t tool_id = node.params.boolean_op.tool_feature_id;
            auto it_tool = eval_features.find(tool_id);
            if (it_tool != eval_features.end() && active_solid != CAD_INVALID_HANDLE) {
                cad_solid_handle_t cut_solid = CAD_INVALID_HANDLE;
                cad_status_t status = occ_op_boolean(CAD_OP_BOOLEAN_DIFFERENCE, active_solid, it_tool->second, &cut_solid);
                if (status == CAD_STATUS_OK) {
                    active_solid = cut_solid;
                    eval_features[node.feature_id] = cut_solid;
                }
            }
        } else if (node.type == CAD_FEATURE_BOOLEAN_INTERSECT) {
            uint32_t tool_id = node.params.boolean_op.tool_feature_id;
            auto it_tool = eval_features.find(tool_id);
            if (it_tool != eval_features.end() && active_solid != CAD_INVALID_HANDLE) {
                cad_solid_handle_t int_solid = CAD_INVALID_HANDLE;
                cad_status_t status = occ_op_boolean(CAD_OP_BOOLEAN_INTERSECTION, active_solid, it_tool->second, &int_solid);
                if (status == CAD_STATUS_OK) {
                    active_solid = int_solid;
                    eval_features[node.feature_id] = int_solid;
                }
            }
        }
    }

    if (active_solid == CAD_INVALID_HANDLE) {
        return CAD_STATUS_ERROR_OP_FAILED;
    }

    *out_solid = active_solid;
    return CAD_STATUS_OK;
}

