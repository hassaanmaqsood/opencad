#include "comparator.hpp"
#include "occ_oracle.h"
#include <cmath>
#include <algorithm>
#include <sstream>

DifferentialDiffResult CadDifferentialComparator::compareSolids(
    cad_solid_handle_t solid_oracle,
    cad_solid_handle_t solid_candidate,
    float tolerance
) {
    DifferentialDiffResult res{};
    res.passed = true;

    cad_brep_stats_t stats_oracle{};
    cad_brep_stats_t stats_candidate{};

    if (occ_solid_get_stats(solid_oracle, &stats_oracle) != CAD_STATUS_OK ||
        occ_solid_get_stats(solid_candidate, &stats_candidate) != CAD_STATUS_OK) {
        res.passed = false;
        res.failure_reason = "Failed to query B-Rep stats from one or both solids";
        return res;
    }

    res.euler_char_actual = stats_candidate.euler_characteristic;
    res.euler_char_expected = stats_oracle.euler_characteristic;
    res.face_count_delta = std::abs((int32_t)stats_candidate.num_faces - (int32_t)stats_oracle.num_faces);
    res.edge_count_delta = std::abs((int32_t)stats_candidate.num_edges - (int32_t)stats_oracle.num_edges);

    // Topological Euler invariant check: for any 2-manifold genus-0 solid, chi = 2
    if (res.euler_char_actual != res.euler_char_expected) {
        res.passed = false;
        std::ostringstream ss;
        ss << "Euler characteristic mismatch: expected " << res.euler_char_expected
           << " but got " << res.euler_char_actual;
        res.failure_reason = ss.str();
        return res;
    }

    // Volume comparison
    float max_vol = std::max(std::abs(stats_oracle.volume), 1e-4f);
    res.volume_difference_percent = std::abs(stats_oracle.volume - stats_candidate.volume) / max_vol * 100.0f;
    if (res.volume_difference_percent > (tolerance * 100.0f)) {
        res.passed = false;
        std::ostringstream ss;
        ss << "Volume divergence: " << res.volume_difference_percent << "% exceeds tolerance";
        res.failure_reason = ss.str();
        return res;
    }

    // Surface area comparison
    float max_area = std::max(std::abs(stats_oracle.surface_area), 1e-4f);
    res.surface_area_difference_percent = std::abs(stats_oracle.surface_area - stats_candidate.surface_area) / max_area * 100.0f;
    if (res.surface_area_difference_percent > (tolerance * 100.0f)) {
        res.passed = false;
        std::ostringstream ss;
        ss << "Surface area divergence: " << res.surface_area_difference_percent << "% exceeds tolerance";
        res.failure_reason = ss.str();
        return res;
    }

    return res;
}

DifferentialDiffResult CadDifferentialComparator::compareMeshes(
    const cad_mesh_t* mesh_oracle,
    const cad_mesh_t* mesh_candidate,
    float tolerance
) {
    DifferentialDiffResult res{};
    res.passed = true;

    if (!mesh_oracle || !mesh_candidate) {
        res.passed = false;
        res.failure_reason = "Null mesh pointer";
        return res;
    }

    // Bounding box comparison
    float dx = std::abs(mesh_oracle->bbox_max.x - mesh_candidate->bbox_max.x);
    float dy = std::abs(mesh_oracle->bbox_max.y - mesh_candidate->bbox_max.y);
    float dz = std::abs(mesh_oracle->bbox_max.z - mesh_candidate->bbox_max.z);
    float max_bbox_err = std::max({dx, dy, dz});

    if (max_bbox_err > tolerance) {
        res.passed = false;
        std::ostringstream ss;
        ss << "Bounding box mismatch: max delta = " << max_bbox_err;
        res.failure_reason = ss.str();
        return res;
    }

    // Sample-based Hausdorff distance
    float max_h_dist = 0.0f;
    for (uint32_t i = 0; i < mesh_candidate->vertex_count; ++i) {
        float cx = mesh_candidate->positions[i * 3 + 0];
        float cy = mesh_candidate->positions[i * 3 + 1];
        float cz = mesh_candidate->positions[i * 3 + 2];

        float min_dist_sq = 1e9f;
        for (uint32_t j = 0; j < mesh_oracle->vertex_count; ++j) {
            float ox = mesh_oracle->positions[j * 3 + 0];
            float oy = mesh_oracle->positions[j * 3 + 1];
            float oz = mesh_oracle->positions[j * 3 + 2];
            float d2 = (cx - ox)*(cx - ox) + (cy - oy)*(cy - oy) + (cz - oz)*(cz - oz);
            if (d2 < min_dist_sq) min_dist_sq = d2;
        }
        float dist = std::sqrt(min_dist_sq);
        if (dist > max_h_dist) max_h_dist = dist;
    }

    res.max_hausdorff_distance = max_h_dist;
    if (max_h_dist > tolerance) {
        res.passed = false;
        std::ostringstream ss;
        ss << "Mesh Hausdorff distance " << max_h_dist << " exceeds tolerance " << tolerance;
        res.failure_reason = ss.str();
    }

    return res;
}
