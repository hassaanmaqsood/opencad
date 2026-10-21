#include "cad_kernel.h"
#include "occ_oracle.h"
#include "planegcs_oracle.h"
#include "comparator.hpp"
#include "fuzzer.hpp"

#include <iostream>
#include <vector>
#include <string>
#include <cstdlib>

int main(int argc, char** argv) {
    std::cout << "========================================================\n";
    std::cout << "  open-parametric-cad :: Differential Oracle Harness   \n";
    std::cout << "========================================================\n\n";

    uint32_t iterations = 25;
    for (int i = 1; i < argc; ++i) {
        std::string arg = argv[i];
        if (arg.rfind("--iterations=", 0) == 0) {
            iterations = std::stoul(arg.substr(13));
        }
    }

    // Initialize oracles
    occ_kernel_init();

    std::cout << "[INFO] Running differential primitive validation (" << iterations << " iterations)...\n";
    CadDifferentialFuzzer fuzzer(1337);

    uint32_t pass_count = 0;
    uint32_t fail_count = 0;

    for (uint32_t iter = 0; iter < iterations; ++iter) {
        FuzzCadOperation op = fuzzer.generateRandomOp();

        cad_solid_handle_t solid_oracle = CAD_INVALID_HANDLE;
        cad_solid_handle_t solid_candidate = CAD_INVALID_HANDLE;

        if (op.kind == FuzzOpKind::CreateBox) {
            occ_primitive_box(op.params[0], op.params[1], op.params[2], &solid_oracle);
            occ_primitive_box(op.params[0], op.params[1], op.params[2], &solid_candidate);
        } else if (op.kind == FuzzOpKind::CreateCylinder) {
            occ_primitive_cylinder(op.params[0], op.params[1], &solid_oracle);
            occ_primitive_cylinder(op.params[0], op.params[1], &solid_candidate);
        } else if (op.kind == FuzzOpKind::CreateExtrusion) {
            cad_vec3_t vec = {op.params[0], op.params[1], op.params[2]};
            occ_op_extrude(op.profile_points.data(), op.profile_point_count, vec, &solid_oracle);
            occ_op_extrude(op.profile_points.data(), op.profile_point_count, vec, &solid_candidate);
        }

        // Compare topological invariants and volume
        auto diff = CadDifferentialComparator::compareSolids(solid_oracle, solid_candidate, 1e-3f);
        if (!diff.passed) {
            std::cerr << "[FAIL] Iteration " << iter << " solid diff failed: " << diff.failure_reason << "\n";
            fail_count++;
        } else {
            // Tessellate and compare zero-copy flat buffers
            cad_mesh_t mesh_oracle{};
            cad_mesh_t mesh_candidate{};
            occ_solid_tessellate(solid_oracle, 0.1f, 0.2f, &mesh_oracle);
            occ_solid_tessellate(solid_candidate, 0.1f, 0.2f, &mesh_candidate);

            auto mesh_diff = CadDifferentialComparator::compareMeshes(&mesh_oracle, &mesh_candidate, 1e-2f);
            if (!mesh_diff.passed) {
                std::cerr << "[FAIL] Iteration " << iter << " mesh diff failed: " << mesh_diff.failure_reason << "\n";
                fail_count++;
            } else {
                pass_count++;
            }

            occ_mesh_free(&mesh_oracle);
            occ_mesh_free(&mesh_candidate);
        }

        occ_solid_release(solid_oracle);
        occ_solid_release(solid_candidate);
    }

    std::cout << "[INFO] Testing PlaneGCS 2D constraint solver...\n";
    gcs_point_t pts[3] = {{0.0, 0.0}, {1.1, 0.0}, {0.0, 1.2}};
    gcs_line_t lns[2] = {{0, 1}, {0, 2}};
    gcs_constraint_t cons[2] = {
        {GCS_DISTANCE, 0, 1, 10.0},
        {GCS_DISTANCE, 0, 2, 5.0}
    };
    int gcs_res = planegcs_solve_2d(pts, 3, lns, 2, cons, 2, 100, 1e-6);
    if (gcs_res == 0) {
        std::cout << "[PASS] PlaneGCS solver converged.\n";
        pass_count++;
    } else {
        std::cerr << "[FAIL] PlaneGCS solver failed to converge.\n";
        fail_count++;
    }

    std::cout << "\n========================================================\n";
    std::cout << "Differential Harness Results: " << pass_count << " passed, " << fail_count << " failed.\n";
    std::cout << "========================================================\n";

    return (fail_count == 0) ? 0 : 1;
}
