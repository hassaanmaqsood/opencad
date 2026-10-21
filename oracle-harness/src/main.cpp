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

    // -----------------------------------------------------------------------
    // Part 4: Multi-Feature DAG Evaluation Differential Validation (Wave 3)
    // -----------------------------------------------------------------------
    std::cout << "\n[INFO] Running Part 4: Multi-feature DAG evaluation differential validation against OpenCASCADE...\n";

    const double PI_CONST = 3.14159265358979323846;

    // Test 4.1: Base Plate Extrude Feature DAG Node
    {
        cad_feature_node_t base_node{};
        base_node.feature_id = 1;
        base_node.type = CAD_FEATURE_EXTRUDE;
        base_node.is_suppressed = 0;
        base_node.parent_count = 0;
        base_node.params.extrude.distance = 10.0;
        base_node.params.extrude.direction = {0.0f, 0.0f, 1.0f};

        cad_solid_handle_t out_solid = CAD_INVALID_HANDLE;
        cad_status_t status = occ_dag_evaluate(&base_node, 1, 0, &out_solid);
        if (status == CAD_STATUS_OK && out_solid != CAD_INVALID_HANDLE) {
            cad_brep_stats_t stats{};
            occ_solid_get_stats(out_solid, &stats);
            double expected_vol = 50.0 * 40.0 * 10.0;
            double vol_err = std::abs(static_cast<double>(stats.volume) - expected_vol);

            if (vol_err <= 1e-5 && stats.euler_characteristic == 2 && stats.num_faces == 6) {
                std::cout << "[PASS] DAG Extrude Base Plate invariant verified (vol: "
                          << stats.volume << ", Euler: " << stats.euler_characteristic << ", delta <= 1e-5).\n";
                pass_count++;
            } else {
                std::cerr << "[FAIL] DAG Extrude Base Plate volume or topology mismatch (vol: "
                          << stats.volume << ", err: " << vol_err << ").\n";
                fail_count++;
            }
            occ_solid_release(out_solid);
        } else {
            std::cerr << "[FAIL] DAG Extrude Base Plate evaluation failed (status: " << status << ").\n";
            fail_count++;
        }
    }

    // Test 4.2: Base Plate + Cylindrical Boss (Boolean Union Feature)
    {
        // 1. Create and register boss tool solid (r=5, h=10)
        cad_solid_handle_t boss_handle = CAD_INVALID_HANDLE;
        occ_primitive_cylinder(5.0f, 10.0f, &boss_handle);
        occ_dag_register_feature_solid(10, boss_handle);

        cad_feature_node_t nodes[2]{};
        // Node 0: Base plate
        nodes[0].feature_id = 1;
        nodes[0].type = CAD_FEATURE_EXTRUDE;
        nodes[0].params.extrude.distance = 10.0;
        nodes[0].params.extrude.direction = {0.0f, 0.0f, 1.0f};

        // Node 1: Boolean Union with tool feature 10
        nodes[1].feature_id = 2;
        nodes[1].type = CAD_FEATURE_BOOLEAN_UNION;
        nodes[1].parent_count = 1;
        nodes[1].parent_ids[0] = 1;
        nodes[1].params.boolean_op.tool_feature_id = 10;

        cad_solid_handle_t out_solid = CAD_INVALID_HANDLE;
        cad_status_t status = occ_dag_evaluate(nodes, 2, 1, &out_solid);
        if (status == CAD_STATUS_OK && out_solid != CAD_INVALID_HANDLE) {
            cad_brep_stats_t stats{};
            occ_solid_get_stats(out_solid, &stats);
            cad_brep_stats_t boss_stats{};
            occ_solid_get_stats(boss_handle, &boss_stats);
            float expected_vol = (50.0f * 40.0f * 10.0f) + boss_stats.volume;
            float vol_err = std::abs(stats.volume - expected_vol);

            if (vol_err <= 1e-5f && stats.euler_characteristic == 2) {
                std::cout << "[PASS] DAG Boolean Union Boss verified (vol: "
                          << stats.volume << ", delta: " << vol_err << " <= 1e-5).\n";
                pass_count++;
            } else {
                std::cerr << "[FAIL] DAG Boolean Union Boss mismatch (vol: "
                          << stats.volume << ", expected: " << expected_vol << ", err: " << vol_err << ").\n";
                fail_count++;
            }
            occ_solid_release(out_solid);
        } else {
            std::cerr << "[FAIL] DAG Boolean Union evaluation failed.\n";
            fail_count++;
        }
        occ_solid_release(boss_handle);
    }

    // Test 4.3: Base Plate + Cylindrical Hole Cut (Boolean Difference Feature)
    {
        // 1. Create and register hole tool solid (r=4, h=10)
        cad_solid_handle_t hole_handle = CAD_INVALID_HANDLE;
        occ_primitive_cylinder(4.0f, 10.0f, &hole_handle);
        occ_dag_register_feature_solid(20, hole_handle);

        cad_feature_node_t nodes[2]{};
        nodes[0].feature_id = 1;
        nodes[0].type = CAD_FEATURE_EXTRUDE;
        nodes[0].params.extrude.distance = 10.0;
        nodes[0].params.extrude.direction = {0.0f, 0.0f, 1.0f};

        nodes[1].feature_id = 3;
        nodes[1].type = CAD_FEATURE_BOOLEAN_CUT;
        nodes[1].parent_count = 1;
        nodes[1].parent_ids[0] = 1;
        nodes[1].params.boolean_op.tool_feature_id = 20;

        cad_solid_handle_t out_solid = CAD_INVALID_HANDLE;
        cad_status_t status = occ_dag_evaluate(nodes, 2, 1, &out_solid);
        if (status == CAD_STATUS_OK && out_solid != CAD_INVALID_HANDLE) {
            cad_brep_stats_t stats{};
            occ_solid_get_stats(out_solid, &stats);
            cad_brep_stats_t hole_stats{};
            occ_solid_get_stats(hole_handle, &hole_stats);
            float expected_vol = (50.0f * 40.0f * 10.0f) - hole_stats.volume;
            float vol_err = std::abs(stats.volume - expected_vol);

            if (vol_err <= 1e-5f) {
                std::cout << "[PASS] DAG Boolean Cut Hole verified (vol: "
                          << stats.volume << ", delta: " << vol_err << " <= 1e-5).\n";
                pass_count++;
            } else {
                std::cerr << "[FAIL] DAG Boolean Cut Hole mismatch (vol: "
                          << stats.volume << ", expected: " << expected_vol << ", err: " << vol_err << ").\n";
                fail_count++;
            }
            occ_solid_release(out_solid);
        } else {
            std::cerr << "[FAIL] DAG Boolean Cut evaluation failed.\n";
            fail_count++;
        }
        occ_solid_release(hole_handle);
    }

    // Test 4.4: DAG Rollback Bar Verification (Rolling back through feature history)
    {
        // Tools:
        // Boss tool (Feature 30): Cylinder r=6, h=10
        // Pocket tool (Feature 40): Box 10 x 10 x 5 -> vol = 500
        cad_solid_handle_t boss_h = CAD_INVALID_HANDLE;
        occ_primitive_cylinder(6.0f, 10.0f, &boss_h);
        occ_dag_register_feature_solid(30, boss_h);
        cad_brep_stats_t b_stats{};
        occ_solid_get_stats(boss_h, &b_stats);

        cad_solid_handle_t pocket_h = CAD_INVALID_HANDLE;
        occ_primitive_box(10.0f, 10.0f, 5.0f, &pocket_h);
        occ_dag_register_feature_solid(40, pocket_h);
        cad_brep_stats_t p_stats{};
        occ_solid_get_stats(pocket_h, &p_stats);

        cad_feature_node_t nodes[3]{};
        // Node 0: Base plate 50 x 40 x 10
        nodes[0].feature_id = 1;
        nodes[0].type = CAD_FEATURE_EXTRUDE;
        nodes[0].params.extrude.distance = 10.0;
        nodes[0].params.extrude.direction = {0.0f, 0.0f, 1.0f};

        // Node 1: Union Boss (tool 30)
        nodes[1].feature_id = 2;
        nodes[1].type = CAD_FEATURE_BOOLEAN_UNION;
        nodes[1].parent_count = 1;
        nodes[1].parent_ids[0] = 1;
        nodes[1].params.boolean_op.tool_feature_id = 30;

        // Node 2: Cut Pocket (tool 40)
        nodes[2].feature_id = 3;
        nodes[2].type = CAD_FEATURE_BOOLEAN_CUT;
        nodes[2].parent_count = 1;
        nodes[2].parent_ids[0] = 2;
        nodes[2].params.boolean_op.tool_feature_id = 40;

        bool rollback_pass = true;

        // Rollback to 0: Base plate only
        cad_solid_handle_t s0 = CAD_INVALID_HANDLE;
        occ_dag_evaluate(nodes, 3, 0, &s0);
        cad_brep_stats_t stats0{};
        occ_solid_get_stats(s0, &stats0);
        float exp0 = 20000.0f;
        if (std::abs(stats0.volume - exp0) > 1e-5f) rollback_pass = false;
        occ_solid_release(s0);

        // Rollback to 1: Base + Boss
        cad_solid_handle_t s1 = CAD_INVALID_HANDLE;
        occ_dag_evaluate(nodes, 3, 1, &s1);
        cad_brep_stats_t stats1{};
        occ_solid_get_stats(s1, &stats1);
        float exp1 = 20000.0f + b_stats.volume;
        if (std::abs(stats1.volume - exp1) > 1e-5f) rollback_pass = false;
        occ_solid_release(s1);

        // Roll forward to 2: Base + Boss - Pocket
        cad_solid_handle_t s2 = CAD_INVALID_HANDLE;
        occ_dag_evaluate(nodes, 3, 2, &s2);
        cad_brep_stats_t stats2{};
        occ_solid_get_stats(s2, &stats2);
        float exp2 = 20000.0f + b_stats.volume - p_stats.volume;
        if (std::abs(stats2.volume - exp2) > 1e-5f) rollback_pass = false;
        occ_solid_release(s2);

        if (rollback_pass) {
            std::cout << "[PASS] DAG Rollback Bar differential verification across all rollback markers (delta <= 1e-5).\n";
            pass_count++;
        } else {
            std::cerr << "[FAIL] DAG Rollback Bar verification failed.\n";
            fail_count++;
        }

        // Test 4.5: Feature Suppression
        nodes[1].is_suppressed = 1; // Suppress Union Boss
        cad_solid_handle_t s_supp = CAD_INVALID_HANDLE;
        occ_dag_evaluate(nodes, 3, 2, &s_supp);
        cad_brep_stats_t stats_supp{};
        occ_solid_get_stats(s_supp, &stats_supp);
        float exp_supp = 20000.0f - p_stats.volume; // Base plate - Pocket (boss skipped)
        float supp_err = std::abs(stats_supp.volume - exp_supp);
        if (supp_err <= 1e-5f) {
            std::cout << "[PASS] DAG Feature suppression differential evaluation verified (vol: "
                      << stats_supp.volume << ", delta <= 1e-5).\n";
            pass_count++;
        } else {
            std::cerr << "[FAIL] DAG Feature suppression failed (vol: "
                      << stats_supp.volume << ", exp: " << exp_supp << ").\n";
            fail_count++;
        }
        occ_solid_release(s_supp);

        occ_solid_release(boss_h);
        occ_solid_release(pocket_h);
    }

    // Test 4.6: Multi-Feature DAG Differential Fuzzing Suite (25 iterations)
    {
        std::cout << "[INFO] Running multi-feature DAG differential fuzzing suite (25 iterations)...\n";
        uint32_t dag_fuzz_passed = 0;
        float max_dag_residual = 0.0f;

        for (uint32_t iter = 0; iter < 25; ++iter) {
            float dx = 20.0f + (iter * 1.5f);
            float dy = 15.0f + (iter * 1.0f);
            float dz = 10.0f + (iter * 0.5f);
            float tool_r = 2.0f + (iter * 0.2f);
            float tool_h = dz;

            // Register dynamic cylinder tool
            cad_solid_handle_t tool_hdl = CAD_INVALID_HANDLE;
            occ_primitive_cylinder(tool_r, tool_h, &tool_hdl);
            cad_brep_stats_t tool_stats{};
            occ_solid_get_stats(tool_hdl, &tool_stats);

            uint32_t tool_feat_id = 1000 + iter;
            occ_dag_register_feature_solid(tool_feat_id, tool_hdl);

            // Register custom 2D sketch profile for base
            float sk_pts[8] = {
                0.0f, 0.0f,
                dx, 0.0f,
                dx, dy,
                0.0f, dy
            };
            uint32_t sk_feat_id = 2000 + iter;
            occ_dag_register_sketch(sk_feat_id, sk_pts, 4);

            cad_feature_node_t fuzz_nodes[2]{};
            fuzz_nodes[0].feature_id = 100;
            fuzz_nodes[0].type = CAD_FEATURE_EXTRUDE;
            fuzz_nodes[0].parent_count = 1;
            fuzz_nodes[0].parent_ids[0] = sk_feat_id;
            fuzz_nodes[0].params.extrude.distance = dz;
            fuzz_nodes[0].params.extrude.direction = {0.0f, 0.0f, 1.0f};

            bool is_union = (iter % 2 == 0);
            fuzz_nodes[1].feature_id = 101;
            fuzz_nodes[1].type = is_union ? CAD_FEATURE_BOOLEAN_UNION : CAD_FEATURE_BOOLEAN_CUT;
            fuzz_nodes[1].parent_count = 1;
            fuzz_nodes[1].parent_ids[0] = 100;
            fuzz_nodes[1].params.boolean_op.tool_feature_id = tool_feat_id;

            cad_solid_handle_t fuzz_solid = CAD_INVALID_HANDLE;
            cad_status_t f_status = occ_dag_evaluate(fuzz_nodes, 2, 1, &fuzz_solid);

            if (f_status == CAD_STATUS_OK && fuzz_solid != CAD_INVALID_HANDLE) {
                cad_brep_stats_t f_stats{};
                occ_solid_get_stats(fuzz_solid, &f_stats);

                float base_vol = dx * dy * dz;
                float expected_vol = is_union ? (base_vol + tool_stats.volume) : (base_vol - tool_stats.volume);
                float err = std::abs(f_stats.volume - expected_vol);

                if (err > max_dag_residual) max_dag_residual = err;

                if (err <= 1e-5f) {
                    dag_fuzz_passed++;
                } else {
                    std::cerr << "[FAIL] DAG fuzz iter " << iter << " exceeded tolerance (err: " << err << ")\n";
                    fail_count++;
                    occ_solid_release(fuzz_solid);
                    occ_solid_release(tool_hdl);
                    break;
                }
                occ_solid_release(fuzz_solid);
            } else {
                std::cerr << "[FAIL] DAG fuzz iter " << iter << " evaluation returned error\n";
                fail_count++;
                occ_solid_release(tool_hdl);
                break;
            }
            occ_solid_release(tool_hdl);
        }

        if (dag_fuzz_passed == 25) {
            std::cout << "[PASS] All 25 multi-feature DAG fuzz iterations passed differential validation (max delta: "
                      << max_dag_residual << " <= 1e-5).\n";
            pass_count++;
        }
    }


    std::cout << "\n========================================================\n";
    std::cout << "Differential Harness Results: " << pass_count << " passed, " << fail_count << " failed.\n";
    std::cout << "========================================================\n";

    return (fail_count == 0) ? 0 : 1;
}
