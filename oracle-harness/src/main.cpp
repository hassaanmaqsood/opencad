#include "cad_kernel.h"
#include "occ_oracle.h"
#include "planegcs_oracle.h"
#include "comparator.hpp"
#include "fuzzer.hpp"

#include <iostream>
#include <vector>
#include <string>
#include <cstdlib>
#include <chrono>
#include <cmath>

int main(int argc, char** argv) {
    std::cout << "========================================================\n";
    std::cout << "  open-parametric-cad :: Differential Oracle Harness   \n";
    std::cout << "========================================================\n\n";

    uint32_t iterations = 25;
    uint32_t sketch_fuzz_iterations = 0;
    bool explicit_sketch_fuzz = false;

    for (int i = 1; i < argc; ++i) {
        std::string arg = argv[i];
        if (arg.rfind("--iterations=", 0) == 0) {
            iterations = std::stoul(arg.substr(13));
        } else if (arg.rfind("--sketch-fuzz-iterations=", 0) == 0) {
            sketch_fuzz_iterations = std::stoul(arg.substr(25));
            explicit_sketch_fuzz = true;
        }
    }

    if (!explicit_sketch_fuzz) {
        // If iterations is large (e.g. 10000), use it for sketch fuzzing
        sketch_fuzz_iterations = iterations;
    }

    // Initialize 3D oracle
    occ_kernel_init();

    uint32_t pass_count = 0;
    uint32_t fail_count = 0;

    // -----------------------------------------------------------------------
    // Part 1: 3D Primitive Solid Differential Validation (Wave 1)
    // -----------------------------------------------------------------------
    uint32_t solid_iters = (iterations > 100) ? 50 : iterations;
    std::cout << "[INFO] Running differential primitive validation (" << solid_iters << " iterations)...\n";
    CadDifferentialFuzzer fuzzer(1337);

    for (uint32_t iter = 0; iter < solid_iters; ++iter) {
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

        auto diff = CadDifferentialComparator::compareSolids(solid_oracle, solid_candidate, 1e-3f);
        if (!diff.passed) {
            std::cerr << "[FAIL] Iteration " << iter << " solid diff failed: " << diff.failure_reason << "\n";
            fail_count++;
        } else {
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

    // -----------------------------------------------------------------------
    // Part 2: Dedicated 2D Sketch Constraint Invariant Tests
    // -----------------------------------------------------------------------
    std::cout << "[INFO] Running dedicated 2D sketch constraint tests...\n";

    // 1. Triangle sketch with 3 distance constraints
    {
        auto tri = fuzzer.generateTriangleSketch();
        cad_solver_status_t status{};
        int res = planegcs_solve_sketch(
            tri.points.data(), static_cast<uint32_t>(tri.points.size()),
            tri.lines.data(), static_cast<uint32_t>(tri.lines.size()),
            nullptr, 0,
            nullptr, 0,
            tri.constraints.data(), static_cast<uint32_t>(tri.constraints.size()),
            50, 1e-7, &status
        );
        if (res == CAD_STATUS_OK && status.solve_state == CAD_SOLVE_STATE_SOLVED && status.max_residual <= 1e-7) {
            std::cout << "[PASS] Triangle sketch converged (max residual: " << status.max_residual << ").\n";
            pass_count++;
        } else {
            std::cerr << "[FAIL] Triangle sketch failed (state: " << status.solve_state << ", res: " << status.max_residual << ").\n";
            fail_count++;
        }
    }

    // 2. Tangent Slot profile
    {
        auto slot = fuzzer.generateTangentSlotSketch();
        cad_solver_status_t status{};
        int res = planegcs_solve_sketch(
            slot.points.data(), static_cast<uint32_t>(slot.points.size()),
            slot.lines.data(), static_cast<uint32_t>(slot.lines.size()),
            slot.arcs.data(), static_cast<uint32_t>(slot.arcs.size()),
            nullptr, 0,
            slot.constraints.data(), static_cast<uint32_t>(slot.constraints.size()),
            50, 1e-7, &status
        );
        if (res == CAD_STATUS_OK && (status.solve_state == CAD_SOLVE_STATE_SOLVED || status.solve_state == CAD_SOLVE_STATE_OVER_CONSTRAINED) && status.max_residual <= 1e-7) {
            std::cout << "[PASS] Tangent slot profile converged (max residual: " << status.max_residual << ").\n";
            pass_count++;
        } else {
            std::cerr << "[FAIL] Tangent slot failed (state: " << status.solve_state << ", res: " << status.max_residual << ").\n";
            fail_count++;
        }
    }

    // 3. Concentric Flanges
    {
        auto flanges = fuzzer.generateConcentricFlangesSketch();
        cad_solver_status_t status{};
        int res = planegcs_solve_sketch(
            flanges.points.data(), static_cast<uint32_t>(flanges.points.size()),
            nullptr, 0,
            nullptr, 0,
            flanges.circles.data(), static_cast<uint32_t>(flanges.circles.size()),
            flanges.constraints.data(), static_cast<uint32_t>(flanges.constraints.size()),
            50, 1e-7, &status
        );
        if (res == CAD_STATUS_OK && status.max_residual <= 1e-7) {
            std::cout << "[PASS] Concentric flanges converged (max residual: " << status.max_residual << ").\n";
            pass_count++;
        } else {
            std::cerr << "[FAIL] Concentric flanges failed (state: " << status.solve_state << ", res: " << status.max_residual << ").\n";
            fail_count++;
        }
    }

    // 4. Symmetric Bracket
    {
        auto bracket = fuzzer.generateSymmetricBracketSketch();
        cad_solver_status_t status{};
        int res = planegcs_solve_sketch(
            bracket.points.data(), static_cast<uint32_t>(bracket.points.size()),
            bracket.lines.data(), static_cast<uint32_t>(bracket.lines.size()),
            nullptr, 0,
            nullptr, 0,
            bracket.constraints.data(), static_cast<uint32_t>(bracket.constraints.size()),
            50, 1e-7, &status
        );
        if (res == CAD_STATUS_OK && status.max_residual <= 1e-7) {
            std::cout << "[PASS] Symmetric bracket converged (max residual: " << status.max_residual << ").\n";
            pass_count++;
        } else {
            std::cerr << "[FAIL] Symmetric bracket failed (state: " << status.solve_state << ", res: " << status.max_residual << ").\n";
            fail_count++;
        }
    }

    // 5. Under-constrained Sketch (DOF > 0)
    {
        auto under = fuzzer.generateUnderConstrainedSketch();
        cad_solver_status_t status{};
        int res = planegcs_solve_sketch(
            under.points.data(), static_cast<uint32_t>(under.points.size()),
            under.lines.data(), static_cast<uint32_t>(under.lines.size()),
            nullptr, 0,
            nullptr, 0,
            under.constraints.data(), static_cast<uint32_t>(under.constraints.size()),
            50, 1e-7, &status
        );
        if (res == CAD_STATUS_OK && status.solve_state == CAD_SOLVE_STATE_UNDER_CONSTRAINED && status.degrees_of_freedom > 0) {
            std::cout << "[PASS] Under-constrained sketch detected (DOF: " << status.degrees_of_freedom << ").\n";
            pass_count++;
        } else {
            std::cerr << "[FAIL] Under-constrained sketch check failed (state: " << status.solve_state << ", dof: " << status.degrees_of_freedom << ").\n";
            fail_count++;
        }
    }

    // 6. Over-constrained Consistent Sketch (Redundant constraint detected)
    {
        auto over = fuzzer.generateOverConstrainedSketch();
        cad_solver_status_t status{};
        int res = planegcs_solve_sketch(
            over.points.data(), static_cast<uint32_t>(over.points.size()),
            over.lines.data(), static_cast<uint32_t>(over.lines.size()),
            nullptr, 0,
            nullptr, 0,
            over.constraints.data(), static_cast<uint32_t>(over.constraints.size()),
            50, 1e-7, &status
        );
        if (res == CAD_STATUS_OK && status.solve_state == CAD_SOLVE_STATE_OVER_CONSTRAINED && status.max_residual <= 1e-7) {
            std::cout << "[PASS] Over-constrained consistent sketch detected.\n";
            pass_count++;
        } else {
            std::cerr << "[FAIL] Over-constrained sketch check failed (state: " << status.solve_state << ").\n";
            fail_count++;
        }
    }

    // 7. Conflicting Sketch (Contradictory constraints -> Conflicting state & IDs)
    {
        auto conf = fuzzer.generateConflictingSketch();
        cad_solver_status_t status{};
        int res = planegcs_solve_sketch(
            conf.points.data(), static_cast<uint32_t>(conf.points.size()),
            conf.lines.data(), static_cast<uint32_t>(conf.lines.size()),
            nullptr, 0,
            nullptr, 0,
            conf.constraints.data(), static_cast<uint32_t>(conf.constraints.size()),
            50, 1e-7, &status
        );
        if (res == CAD_STATUS_OK && status.solve_state == CAD_SOLVE_STATE_CONFLICTING && status.conflicting_count > 0) {
            std::cout << "[PASS] Conflicting sketch detected (" << status.conflicting_count << " conflicting constraints).\n";
            pass_count++;
        } else {
            std::cerr << "[FAIL] Conflicting sketch check failed (state: " << status.solve_state << ", count: " << status.conflicting_count << ").\n";
            fail_count++;
        }
    }

    // 8. PlaneGCS 2D solver differential validation
    {
        std::cout << "[INFO] Testing PlaneGCS 2D constraint solver (planegcs_solve_2d)...\n";
        gcs_point_t pts[3] = {{0.0, 0.0}, {1.1, 0.0}, {0.0, 1.2}};
        gcs_line_t lns[2] = {{0, 1}, {0, 2}};
        gcs_constraint_t cons[2] = {
            {GCS_DISTANCE, 0, 1, 10.0},
            {GCS_DISTANCE, 0, 2, 5.0}
        };
        int gcs_res = planegcs_solve_2d(pts, 3, lns, 2, cons, 2, 100, 1e-7);
        if (gcs_res == 0) {
            double d1 = std::hypot(pts[1].x - pts[0].x, pts[1].y - pts[0].y);
            double d2 = std::hypot(pts[2].x - pts[0].x, pts[2].y - pts[0].y);
            if (std::abs(d1 - 10.0) <= 1e-7 && std::abs(d2 - 5.0) <= 1e-7) {
                std::cout << "[PASS] PlaneGCS solver converged with delta <= 1e-7 mm.\n";
                pass_count++;
            } else {
                std::cerr << "[FAIL] PlaneGCS residual error exceeds 1e-7 mm.\n";
                fail_count++;
            }
        } else {
            std::cerr << "[FAIL] PlaneGCS solver failed to converge.\n";
            fail_count++;
        }
    }

    // -----------------------------------------------------------------------
    // Part 3: Randomized 2D Sketch Differential Fuzzing Suite
    // -----------------------------------------------------------------------
    std::cout << "[INFO] Running 2D sketch differential fuzzing suite (" << sketch_fuzz_iterations << " iterations)...\n";
    auto fuzz_start = std::chrono::high_resolution_clock::now();

    double max_observed_residual = 0.0;
    uint32_t fuzz_passed = 0;

    for (uint32_t iter = 0; iter < sketch_fuzz_iterations; ++iter) {
        FuzzSketchConfiguration cfg;
        uint32_t mode = iter % 6;
        if (mode == 0) {
            cfg = fuzzer.generateTriangleSketch();
        } else if (mode == 1) {
            cfg = fuzzer.generateTangentSlotSketch();
        } else if (mode == 2) {
            cfg = fuzzer.generateConcentricFlangesSketch();
        } else if (mode == 3) {
            cfg = fuzzer.generateSymmetricBracketSketch();
        } else if (mode == 4) {
            cfg = fuzzer.generateRandomSketch(3 + (iter % 5));
        } else {
            cfg = fuzzer.generateOverConstrainedSketch();
        }

        // Solve via sketch solver
        cad_solver_status_t status{};
        int res = planegcs_solve_sketch(
            cfg.points.data(), static_cast<uint32_t>(cfg.points.size()),
            cfg.lines.data(), static_cast<uint32_t>(cfg.lines.size()),
            cfg.arcs.data(), static_cast<uint32_t>(cfg.arcs.size()),
            cfg.circles.data(), static_cast<uint32_t>(cfg.circles.size()),
            cfg.constraints.data(), static_cast<uint32_t>(cfg.constraints.size()),
            50, 1e-7, &status
        );

        if (res == CAD_STATUS_OK && status.max_residual <= 1e-7) {
            fuzz_passed++;
            if (status.max_residual > max_observed_residual) {
                max_observed_residual = status.max_residual;
            }
        } else {
            std::cerr << "[FAIL] Fuzz iteration " << iter << " failed to converge (state: "
                      << status.solve_state << ", max_residual: " << status.max_residual << ")\n";
            fail_count++;
            break;
        }

        // Cross-validate with planegcs_solve_2d
        if (cfg.arcs.empty() && cfg.circles.empty()) {
            auto gcs_pts = cfg.toGcsPoints();
            auto gcs_lns = cfg.toGcsLines();
            auto gcs_cons = cfg.toGcsConstraints();
            int gres = planegcs_solve_2d(
                gcs_pts.data(), static_cast<uint32_t>(gcs_pts.size()),
                gcs_lns.data(), static_cast<uint32_t>(gcs_lns.size()),
                gcs_cons.data(), static_cast<uint32_t>(gcs_cons.size()),
                50, 1e-7
            );
            if (gres != 0) {
                std::cerr << "[FAIL] Fuzz iteration " << iter << " planegcs_solve_2d failed to converge\n";
                fail_count++;
                break;
            }
        }
    }

    auto fuzz_end = std::chrono::high_resolution_clock::now();
    double fuzz_ms = std::chrono::duration<double, std::milli>(fuzz_end - fuzz_start).count();

    if (fuzz_passed == sketch_fuzz_iterations) {
        std::cout << "[PASS] All " << fuzz_passed << " sketch fuzz iterations converged in "
                  << fuzz_ms << " ms (max residual: " << max_observed_residual << " <= 1e-7 mm).\n";
        pass_count++;
    }

    std::cout << "\n========================================================\n";
    std::cout << "Differential Harness Results: " << pass_count << " passed, " << fail_count << " failed.\n";
    std::cout << "========================================================\n";

    return (fail_count == 0) ? 0 : 1;
}
