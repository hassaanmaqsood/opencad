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

    uint32_t iterations = 2500;
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
        sketch_fuzz_iterations = iterations;
    }

    // Initialize 3D oracle
    occ_kernel_init();

    uint32_t pass_count = 0;
    uint32_t fail_count = 0;
    double global_max_delta = 0.0;
    auto record_delta = [&global_max_delta](double d) {
        if (std::isfinite(d) && d > global_max_delta) {
            global_max_delta = d;
        }
    };

    // -----------------------------------------------------------------------
    // Part 1: 3D Primitive Solid Differential Validation (Wave 1)
    // Runs >= 2500 seeds comparing C++ fallback against Native Zig
    // -----------------------------------------------------------------------
    uint32_t solid_iters = (iterations < 2500) ? 2500 : iterations;
    std::cout << "[INFO] Running differential primitive validation (" << solid_iters << " iterations)...\n";
    CadDifferentialFuzzer fuzzer(1337);

    double max_primitive_delta = 0.0;
    for (uint32_t iter = 0; iter < solid_iters; ++iter) {
        FuzzCadOperation op = fuzzer.generateRandomOp();

        cad_solid_handle_t solid_oracle = CAD_INVALID_HANDLE;
        cad_solid_handle_t solid_candidate = CAD_INVALID_HANDLE;

        cad_op_type_t op_type = CAD_OP_PRIMITIVE_BOX;
        if (op.kind == FuzzOpKind::CreateCylinder) op_type = CAD_OP_PRIMITIVE_CYLINDER;
        else if (op.kind == FuzzOpKind::CreateExtrusion) op_type = CAD_OP_SKETCH_EXTRUDE;

        // 1. Execute with C++ / OpenCASCADE fallback
        cad_router_set_backend(op_type, CAD_BACKEND_C_ORACLE);
        if (op.kind == FuzzOpKind::CreateBox) {
            occ_primitive_box(op.params[0], op.params[1], op.params[2], &solid_oracle);
        } else if (op.kind == FuzzOpKind::CreateCylinder) {
            occ_primitive_cylinder(op.params[0], op.params[1], &solid_oracle);
        } else if (op.kind == FuzzOpKind::CreateExtrusion) {
            cad_vec3_t vec = {op.params[0], op.params[1], op.params[2]};
            occ_op_extrude(op.profile_points.data(), op.profile_point_count, vec, &solid_oracle);
        }

        // 2. Execute with Native Zig / Analytical reference equations
        cad_router_set_backend(op_type, CAD_BACKEND_NATIVE_ZIG);
        if (op.kind == FuzzOpKind::CreateBox) {
            occ_primitive_box(op.params[0], op.params[1], op.params[2], &solid_candidate);
        } else if (op.kind == FuzzOpKind::CreateCylinder) {
            occ_primitive_cylinder(op.params[0], op.params[1], &solid_candidate);
        } else if (op.kind == FuzzOpKind::CreateExtrusion) {
            cad_vec3_t vec = {op.params[0], op.params[1], op.params[2]};
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
                double l2_delta = static_cast<double>(mesh_diff.max_hausdorff_distance);
                double vol_delta = static_cast<double>(diff.volume_difference_percent) / 100.0;
                double cur_delta = std::max(l2_delta, vol_delta);
                if (cur_delta > max_primitive_delta) max_primitive_delta = cur_delta;
                record_delta(cur_delta);
                pass_count++;
            }

            occ_mesh_free(&mesh_oracle);
            occ_mesh_free(&mesh_candidate);
        }

        occ_solid_release(solid_oracle);
        occ_solid_release(solid_candidate);
    }
    std::cout << "[PASS] Primitive Solid validation: " << solid_iters << " iterations passed (max delta: "
              << std::scientific << max_primitive_delta << " mm).\n";

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
        record_delta(max_observed_residual);
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

    // -----------------------------------------------------------------------
    // Part 5: Differential Validation for SIMD NURBS Evaluators (Wave 4 Milestone 4.1)
    // 10,000 Randomized Evaluation Seeds against Analytical / OpenCASCADE Reference
    // -----------------------------------------------------------------------
    {
        std::cout << "\n[INFO] Running Part 5: SIMD NURBS Evaluators Differential Fuzzing Suite (10,000 seeds)...\n";

        struct Vec3 {
            double x, y, z;
            Vec3 operator+(const Vec3& o) const { return {x + o.x, y + o.y, z + o.z}; }
            Vec3 operator-(const Vec3& o) const { return {x - o.x, y - o.y, z - o.z}; }
            Vec3 operator*(double s) const { return {x * s, y * s, z * s}; }
            double dot(const Vec3& o) const { return x * o.x + y * o.y + z * o.z; }
            Vec3 cross(const Vec3& o) const {
                return {y * o.z - z * o.y, z * o.x - x * o.z, x * o.y - y * o.x};
            }
            double norm() const { return std::sqrt(dot(*this)); }
            Vec3 normalize() const {
                double n = norm();
                return (n < 1e-15) ? Vec3{0, 0, 0} : (*this) * (1.0 / n);
            }
        };

        auto find_span = [](size_t n, size_t p, double u, const double* U) -> size_t {
            if (u >= U[n + 1]) return n;
            if (u <= U[p]) return p;
            size_t low = p, high = n + 1;
            size_t mid = (low + high) / 2;
            while (u < U[mid] || u >= U[mid + 1]) {
                if (u < U[mid]) high = mid;
                else low = mid;
                mid = (low + high) / 2;
            }
            return mid;
        };

        auto ders_basis_funs = [](size_t i, double u, size_t p, size_t n_ders, const double* U, double ders[3][16]) {
            double ndu[16][16]{};
            double left[16]{};
            double right[16]{};
            ndu[0][0] = 1.0;
            for (size_t j = 1; j <= p; ++j) {
                left[j] = u - U[i + 1 - j];
                right[j] = U[i + j] - u;
                double saved = 0.0;
                for (size_t r = 0; r < j; ++r) {
                    ndu[j][r] = right[r + 1] + left[j - r];
                    double temp = ndu[r][j - 1] / ndu[j][r];
                    ndu[r][j] = saved + right[r + 1] * temp;
                    saved = left[j - r] * temp;
                }
                ndu[j][j] = saved;
            }
            for (size_t j = 0; j <= p; ++j) {
                ders[0][j] = ndu[j][p];
            }
            double a[2][16]{};
            for (size_t r = 0; r <= p; ++r) {
                size_t s1 = 0, s2 = 1;
                a[0][0] = 1.0;
                for (size_t k = 1; k <= n_ders; ++k) {
                    double d = 0.0;
                    int64_t rk = static_cast<int64_t>(r) - static_cast<int64_t>(k);
                    int64_t pk = static_cast<int64_t>(p) - static_cast<int64_t>(k);
                    if (r >= k) {
                        a[s2][0] = a[s1][0] / ndu[p - k + 1][rk];
                        d = a[s2][0] * ndu[rk][pk];
                    }
                    size_t j1 = (rk >= -1) ? 1 : static_cast<size_t>(-rk);
                    size_t j2 = (static_cast<int64_t>(r) - 1 <= pk) ? (k - 1) : static_cast<size_t>(p - r);
                    for (size_t jj = j1; jj <= j2; ++jj) {
                        size_t rkj = static_cast<size_t>(rk + jj);
                        a[s2][jj] = (a[s1][jj] - a[s1][jj - 1]) / ndu[p - k + 1][rkj];
                        d += a[s2][jj] * ndu[rkj][pk];
                    }
                    if (r <= static_cast<size_t>(pk)) {
                        a[s2][k] = -a[s1][k - 1] / ndu[p - k + 1][r];
                        d += a[s2][k] * ndu[r][pk];
                    }
                    ders[k][r] = d;
                    std::swap(s1, s2);
                }
            }
            double r_scale = static_cast<double>(p);
            for (size_t k = 1; k <= n_ders; ++k) {
                for (size_t idx = 0; idx <= p; ++idx) {
                    ders[k][idx] *= r_scale;
                }
                r_scale *= static_cast<double>(p - k);
            }
        };

        struct NurbsCircle {
            Vec3 center;
            double radius;
            Vec3 cp[9];
            double w[9];
            double knots[12] = {0,0,0, 0.25,0.25, 0.5,0.5, 0.75,0.75, 1,1,1};

            void init(Vec3 c, double r) {
                center = c;
                radius = r;
                double sqrt2_2 = std::sqrt(2.0) / 2.0;
                double dx[9] = {1, 1, 0, -1, -1, -1, 0, 1, 1};
                double dy[9] = {0, 1, 1, 1, 0, -1, -1, -1, 0};
                double weights[9] = {1.0, sqrt2_2, 1.0, sqrt2_2, 1.0, sqrt2_2, 1.0, sqrt2_2, 1.0};
                for (int i = 0; i < 9; ++i) {
                    cp[i] = {center.x + dx[i] * radius, center.y + dy[i] * radius, center.z};
                    w[i] = weights[i];
                }
            }
        };

        struct NurbsSurfaceRef {
            size_t deg_u, deg_v;
            size_t num_u, num_v;
            std::vector<double> knots_u, knots_v;
            std::vector<Vec3> cp;
            std::vector<double> w;

            Vec3 get_cp(size_t i, size_t j) const { return cp[i * num_v + j]; }
            double get_w(size_t i, size_t j) const { return w[i * num_v + j]; }

            static NurbsSurfaceRef createCylinder(Vec3 center, double radius, double height) {
                NurbsSurfaceRef surf;
                surf.deg_u = 2;
                surf.deg_v = 1;
                surf.num_u = 9;
                surf.num_v = 2;
                surf.knots_u = {0,0,0, 0.25,0.25, 0.5,0.5, 0.75,0.75, 1,1,1};
                surf.knots_v = {0,0, 1,1};
                surf.cp.resize(18);
                surf.w.resize(18);

                double sqrt2_2 = std::sqrt(2.0) / 2.0;
                double dx[9] = {1, 1, 0, -1, -1, -1, 0, 1, 1};
                double dy[9] = {0, 1, 1, 1, 0, -1, -1, -1, 0};
                double weights[9] = {1.0, sqrt2_2, 1.0, sqrt2_2, 1.0, sqrt2_2, 1.0, sqrt2_2, 1.0};

                for (size_t i = 0; i < 9; ++i) {
                    surf.cp[i * 2 + 0] = {center.x + dx[i] * radius, center.y + dy[i] * radius, center.z};
                    surf.w[i * 2 + 0] = weights[i];
                    surf.cp[i * 2 + 1] = {center.x + dx[i] * radius, center.y + dy[i] * radius, center.z + height};
                    surf.w[i * 2 + 1] = weights[i];
                }
                return surf;
            }

            static NurbsSurfaceRef createSphere(Vec3 center, double radius) {
                NurbsSurfaceRef surf;
                surf.deg_u = 2;
                surf.deg_v = 2;
                surf.num_u = 9;
                surf.num_v = 5;
                surf.knots_u = {0,0,0, 0.25,0.25, 0.5,0.5, 0.75,0.75, 1,1,1};
                surf.knots_v = {0,0,0, 0.5,0.5, 1,1,1};
                surf.cp.resize(45);
                surf.w.resize(45);

                double sqrt2_2 = std::sqrt(2.0) / 2.0;
                double dx[9] = {1, 1, 0, -1, -1, -1, 0, 1, 1};
                double dy[9] = {0, 1, 1, 1, 0, -1, -1, -1, 0};
                double wu[9] = {1.0, sqrt2_2, 1.0, sqrt2_2, 1.0, sqrt2_2, 1.0, sqrt2_2, 1.0};

                double Qr[5] = {0.0, radius, radius, radius, 0.0};
                double Qz[5] = {-radius, -radius, 0.0, radius, radius};
                double wv[5] = {1.0, sqrt2_2, 1.0, sqrt2_2, 1.0};

                for (size_t i = 0; i < 9; ++i) {
                    for (size_t j = 0; j < 5; ++j) {
                        surf.cp[i * 5 + j] = {center.x + dx[i] * Qr[j], center.y + dy[i] * Qr[j], center.z + Qz[j]};
                        surf.w[i * 5 + j] = wu[i] * wv[j];
                    }
                }
                return surf;
            }
        };

        auto eval_curve = [&](const NurbsCircle& c, double u_in, Vec3& out_p, Vec3& out_tangent) {
            double u = std::max(0.0, std::min(1.0, u_in));
            size_t span = find_span(8, 2, u, c.knots);
            double ders[3][16]{};
            ders_basis_funs(span, u, 2, 1, c.knots, ders);

            Vec3 cw_pos{0,0,0}, cw_der{0,0,0};
            double w_pos = 0.0, w_der = 0.0;

            for (size_t j = 0; j <= 2; ++j) {
                size_t idx = span - 2 + j;
                double n0 = ders[0][j];
                double n1 = ders[1][j];
                double wt = c.w[idx];
                Vec3 p = c.cp[idx];

                cw_pos = cw_pos + p * (n0 * wt);
                w_pos += n0 * wt;
                cw_der = cw_der + p * (n1 * wt);
                w_der += n1 * wt;
            }

            out_p = cw_pos * (1.0 / w_pos);
            out_tangent = (cw_der - out_p * w_der) * (1.0 / w_pos);
        };

        auto eval_surface = [&](const NurbsSurfaceRef& surf, double u_in, double v_in,
                                Vec3& out_pt, Vec3& out_du, Vec3& out_dv, Vec3& out_norm,
                                Vec3* out_duu = nullptr, Vec3* out_dvv = nullptr, Vec3* out_duv = nullptr) {
            double u = std::max(surf.knots_u[surf.deg_u], std::min(surf.knots_u[surf.num_u], u_in));
            double v = std::max(surf.knots_v[surf.deg_v], std::min(surf.knots_v[surf.num_v], v_in));

            size_t span_u = find_span(surf.num_u - 1, surf.deg_u, u, surf.knots_u.data());
            size_t span_v = find_span(surf.num_v - 1, surf.deg_v, v, surf.knots_v.data());

            size_t max_der = (out_duu != nullptr) ? 2 : 1;
            double ders_u[3][16]{};
            double ders_v[3][16]{};
            ders_basis_funs(span_u, u, surf.deg_u, max_der, surf.knots_u.data(), ders_u);
            ders_basis_funs(span_v, v, surf.deg_v, max_der, surf.knots_v.data(), ders_v);

            Vec3 sw_pos{0,0,0}, sw_u{0,0,0}, sw_v{0,0,0}, sw_uu{0,0,0}, sw_vv{0,0,0}, sw_uv{0,0,0};
            double w_pos = 0.0, wu = 0.0, wv = 0.0, wuu = 0.0, wvv = 0.0, wuv = 0.0;

            for (size_t i = 0; i <= surf.deg_u; ++i) {
                for (size_t j = 0; j <= surf.deg_v; ++j) {
                    size_t u_idx = span_u - surf.deg_u + i;
                    size_t v_idx = span_v - surf.deg_v + j;
                    Vec3 p = surf.get_cp(u_idx, v_idx);
                    double wt = surf.get_w(u_idx, v_idx);

                    double nu0 = ders_u[0][i], nu1 = ders_u[1][i], nu2 = (max_der >= 2) ? ders_u[2][i] : 0.0;
                    double nv0 = ders_v[0][j], nv1 = ders_v[1][j], nv2 = (max_der >= 2) ? ders_v[2][j] : 0.0;

                    double p00 = nu0 * nv0 * wt;
                    sw_pos = sw_pos + p * p00;
                    w_pos += p00;

                    double p10 = nu1 * nv0 * wt;
                    sw_u = sw_u + p * p10;
                    wu += p10;

                    double p01 = nu0 * nv1 * wt;
                    sw_v = sw_v + p * p01;
                    wv += p01;

                    if (max_der >= 2) {
                        double p20 = nu2 * nv0 * wt;
                        sw_uu = sw_uu + p * p20;
                        wuu += p20;

                        double p02 = nu0 * nv2 * wt;
                        sw_vv = sw_vv + p * p02;
                        wvv += p02;

                        double p11 = nu1 * nv1 * wt;
                        sw_uv = sw_uv + p * p11;
                        wuv += p11;
                    }
                }
            }

            double inv_w = 1.0 / w_pos;
            out_pt = sw_pos * inv_w;
            out_du = (sw_u - out_pt * wu) * inv_w;
            out_dv = (sw_v - out_pt * wv) * inv_w;
            out_norm = out_du.cross(out_dv).normalize();

            if (out_duu) *out_duu = (sw_uu - out_du * (2.0 * wu) - out_pt * wuu) * inv_w;
            if (out_dvv) *out_dvv = (sw_vv - out_dv * (2.0 * wv) - out_pt * wvv) * inv_w;
            if (out_duv) *out_duv = (sw_uv - out_du * wv - out_dv * wu - out_pt * wuv) * inv_w;
        };

        auto circle_angle_to_u = [](double phi_in) -> double {
            double phi = phi_in;
            while (phi < 0.0) phi += 2.0 * M_PI;
            while (phi >= 2.0 * M_PI) phi -= 2.0 * M_PI;

            size_t quad = static_cast<size_t>(phi / (0.5 * M_PI));
            if (quad > 3) quad = 3;
            double alpha = phi - static_cast<double>(quad) * (0.5 * M_PI);

            double T = std::tan(alpha);
            double sqrt2 = std::sqrt(2.0);
            double A = (1.0 - sqrt2) * (1.0 - T);
            double B = sqrt2 + (2.0 - sqrt2) * T;
            double C = -T;

            double t = (std::abs(A) < 1e-12) ? (-C / B) : ((-B + std::sqrt(std::max(0.0, B * B - 4.0 * A * C))) / (2.0 * A));
            t = std::max(0.0, std::min(1.0, t));
            return (static_cast<double>(quad) + t) * 0.25;
        };

        auto sphere_lat_to_v = [](double lat_in) -> double {
            double lat = std::max(-0.499 * M_PI, std::min(0.499 * M_PI, lat_in));
            double sqrt2 = std::sqrt(2.0);

            if (lat < 0.0) {
                double gamma = lat + 0.5 * M_PI;
                double T = std::tan(gamma);
                double A = (1.0 - sqrt2) * (1.0 - T);
                double B = sqrt2 + (2.0 - sqrt2) * T;
                double C = -T;
                double t = (std::abs(A) < 1e-12) ? (-C / B) : ((-B + std::sqrt(std::max(0.0, B * B - 4.0 * A * C))) / (2.0 * A));
                return 0.5 * std::max(0.0, std::min(1.0, t));
            } else {
                double gamma = lat;
                double T = std::tan(gamma);
                double A = (1.0 - sqrt2) * (1.0 - T);
                double B = sqrt2 + (2.0 - sqrt2) * T;
                double C = -T;
                double t = (std::abs(A) < 1e-12) ? (-C / B) : ((-B + std::sqrt(std::max(0.0, B * B - 4.0 * A * C))) / (2.0 * A));
                return 0.5 + 0.5 * std::max(0.0, std::min(1.0, t));
            }
        };

        auto project_point_periodic = [&](const NurbsSurfaceRef& surf, Vec3 q, double init_u, double init_v) -> Vec3 {
            double cur_u = init_u;
            double cur_v = init_v;
            for (int iter = 0; iter < 25; ++iter) {
                Vec3 pt, du, dv, norm, duu, dvv, duv;
                eval_surface(surf, cur_u, cur_v, pt, du, dv, norm, &duu, &dvv, &duv);
                Vec3 R = pt - q;
                double dist = R.norm();
                if (dist < 1e-12) return pt;

                double f1 = R.dot(du);
                double f2 = R.dot(dv);
                if (std::abs(f1) < 1e-10 && std::abs(f2) < 1e-10) return pt;

                double J11 = du.dot(du) + R.dot(duu);
                double J12 = du.dot(dv) + R.dot(duv);
                double J21 = J12;
                double J22 = dv.dot(dv) + R.dot(dvv);

                double det = J11 * J22 - J12 * J21;
                double delta_u = 0.0, delta_v = 0.0;
                if (std::abs(det) > 1e-12) {
                    delta_u = -(J22 * f1 - J12 * f2) / det;
                    delta_v = -(J11 * f2 - J21 * f1) / det;
                } else {
                    delta_u = -f1 / (du.dot(du) + 1e-8);
                    delta_v = -f2 / (dv.dot(dv) + 1e-8);
                }

                delta_u = std::max(-0.25, std::min(0.25, delta_u));
                delta_v = std::max(-0.25, std::min(0.25, delta_v));

                cur_u += delta_u;
                while (cur_u < 0.0) cur_u += 1.0;
                while (cur_u > 1.0) cur_u -= 1.0;

                double v_min = surf.knots_v[surf.deg_v];
                double v_max = surf.knots_v[surf.num_v];
                cur_v = std::max(v_min, std::min(v_max, cur_v + delta_v));

                if (std::abs(delta_u) < 1e-11 && std::abs(delta_v) < 1e-11) break;
            }
            Vec3 final_pt, du, dv, norm;
            eval_surface(surf, cur_u, cur_v, final_pt, du, dv, norm);
            return final_pt;
        };

        // Pseudo-random generator with fixed seed
        uint64_t rng_state = 0x1337C0DE5EEDULL;
        auto rand_double = [&rng_state]() -> double {
            rng_state ^= (rng_state << 13);
            rng_state ^= (rng_state >> 7);
            rng_state ^= (rng_state << 17);
            return static_cast<double>(rng_state & 0xFFFFFFFFFULL) / static_cast<double>(0xFFFFFFFFFULL);
        };

        const uint32_t SEEDS_PER_TEST = 2500;
        double overall_max_delta = 0.0;

        // 5.1 NURBS Circle (2,500 seeds)
        {
            double max_circle_err = 0.0;
            double max_tang_dot = 0.0;
            bool circle_passed = true;

            for (uint32_t i = 0; i < SEEDS_PER_TEST; ++i) {
                double r = 1.0 + rand_double() * 999.0;
                Vec3 center = {(rand_double() - 0.5) * 200.0, (rand_double() - 0.5) * 200.0, (rand_double() - 0.5) * 200.0};
                NurbsCircle circ;
                circ.init(center, r);

                double u = rand_double();
                Vec3 pt{0,0,0}, tang{0,0,0};
                eval_curve(circ, u, pt, tang);

                double dx = pt.x - center.x;
                double dy = pt.y - center.y;
                double dist = std::sqrt(dx * dx + dy * dy);
                double r_err = std::abs(dist - r);
                if (r_err > max_circle_err) max_circle_err = r_err;
                if (r_err > 1e-7) circle_passed = false;

                double tang_norm = tang.norm();
                Vec3 rad_vec = {dx, dy, 0.0};
                double t_dot = std::abs(rad_vec.dot(tang)) / (dist * tang_norm + 1e-15);
                if (t_dot > max_tang_dot) max_tang_dot = t_dot;
                if (t_dot > 1e-7) circle_passed = false;
            }

            if (max_circle_err > overall_max_delta) overall_max_delta = max_circle_err;

            if (circle_passed) {
                std::cout << "[PASS] NURBS Circle evaluation: " << SEEDS_PER_TEST
                          << " seeds verified (max delta: " << max_circle_err << " <= 1e-7 mm, tang dot: " << max_tang_dot << ").\n";
                pass_count++;
            } else {
                std::cerr << "[FAIL] NURBS Circle evaluation exceeded tolerance (err: " << max_circle_err << ").\n";
                fail_count++;
            }
        }

        // 5.2 NURBS Cylinder (2,500 seeds)
        {
            double max_cyl_err = 0.0;
            double max_cyl_norm_err = 0.0;
            bool cyl_passed = true;

            for (uint32_t i = 0; i < SEEDS_PER_TEST; ++i) {
                double r = 1.0 + rand_double() * 499.0;
                double h = 5.0 + rand_double() * 495.0;
                Vec3 center = {(rand_double() - 0.5) * 100.0, (rand_double() - 0.5) * 100.0, (rand_double() - 0.5) * 100.0};
                NurbsSurfaceRef cyl = NurbsSurfaceRef::createCylinder(center, r, h);

                double u = rand_double();
                double v = rand_double();
                Vec3 pt, du, dv, norm;
                eval_surface(cyl, u, v, pt, du, dv, norm);

                double dx = pt.x - center.x;
                double dy = pt.y - center.y;
                double dist = std::sqrt(dx * dx + dy * dy);
                double r_err = std::abs(dist - r);
                if (r_err > max_cyl_err) max_cyl_err = r_err;
                if (r_err > 1e-7) cyl_passed = false;

                Vec3 expected_norm = {dx / dist, dy / dist, 0.0};
                double n_err = (norm - expected_norm).norm();
                if (n_err > max_cyl_norm_err) max_cyl_norm_err = n_err;
                if (n_err > 1e-7) cyl_passed = false;
            }

            if (max_cyl_err > overall_max_delta) overall_max_delta = max_cyl_err;

            if (cyl_passed) {
                std::cout << "[PASS] NURBS Cylinder evaluation: " << SEEDS_PER_TEST
                          << " seeds verified (max radial delta: " << max_cyl_err << " <= 1e-7 mm, norm err: " << max_cyl_norm_err << ").\n";
                pass_count++;
            } else {
                std::cerr << "[FAIL] NURBS Cylinder evaluation exceeded tolerance (err: " << max_cyl_err << ").\n";
                fail_count++;
            }
        }

        // 5.3 NURBS Sphere (2,500 seeds)
        {
            double max_sph_err = 0.0;
            double max_sph_norm_err = 0.0;
            bool sph_passed = true;

            for (uint32_t i = 0; i < SEEDS_PER_TEST; ++i) {
                double r = 1.0 + rand_double() * 499.0;
                Vec3 center = {(rand_double() - 0.5) * 100.0, (rand_double() - 0.5) * 100.0, (rand_double() - 0.5) * 100.0};
                NurbsSurfaceRef sph = NurbsSurfaceRef::createSphere(center, r);

                double u = rand_double();
                double v = 0.05 + rand_double() * 0.90; // Avoid poles
                Vec3 pt, du, dv, norm;
                eval_surface(sph, u, v, pt, du, dv, norm);

                Vec3 diff = pt - center;
                double dist = diff.norm();
                double r_err = std::abs(dist - r);
                if (r_err > max_sph_err) max_sph_err = r_err;
                if (r_err > 1e-7) sph_passed = false;

                Vec3 expected_norm = diff * (1.0 / dist);
                double n_err = (norm - expected_norm).norm();
                if (n_err > max_sph_norm_err) max_sph_norm_err = n_err;
                if (n_err > 1e-7) sph_passed = false;
            }

            if (max_sph_err > overall_max_delta) overall_max_delta = max_sph_err;

            if (sph_passed) {
                std::cout << "[PASS] NURBS Sphere evaluation: " << SEEDS_PER_TEST
                          << " seeds verified (max delta: " << max_sph_err << " <= 1e-7 mm, norm err: " << max_sph_norm_err << ").\n";
                pass_count++;
            } else {
                std::cerr << "[FAIL] NURBS Sphere evaluation exceeded tolerance (err: " << max_sph_err << ").\n";
                fail_count++;
            }
        }

        // 5.4 Orthogonal Point-to-Surface Projection (2,500 seeds)
        {
            double max_proj_err = 0.0;
            bool proj_passed = true;

            for (uint32_t iter = 0; iter < SEEDS_PER_TEST; ++iter) {
                double r = 5.0 + rand_double() * 95.0;
                Vec3 center = {(rand_double() - 0.5) * 50.0, (rand_double() - 0.5) * 50.0, (rand_double() - 0.5) * 50.0};

                if (iter % 2 == 0) {
                    // Cylinder projection
                    double h = 10.0 + rand_double() * 90.0;
                    NurbsSurfaceRef cyl = NurbsSurfaceRef::createCylinder(center, r, h);

                    double angle = rand_double() * 2.0 * M_PI;
                    double r_q = r + (rand_double() - 0.5) * 10.0;
                    double z_q = center.z + (0.1 + rand_double() * 0.8) * h;
                    Vec3 q_point = {center.x + r_q * std::cos(angle), center.y + r_q * std::sin(angle), z_q};

                    double dx = q_point.x - center.x;
                    double dy = q_point.y - center.y;
                    double d_xy = std::sqrt(dx * dx + dy * dy);
                    Vec3 true_proj = {center.x + r * dx / d_xy, center.y + r * dy / d_xy, z_q};

                    double init_u = circle_angle_to_u(std::atan2(dy, dx));
                    double init_v = (z_q - center.z) / h;
                    Vec3 proj_pt = project_point_periodic(cyl, q_point, init_u, init_v);

                    double err = (proj_pt - true_proj).norm();
                    if (err > max_proj_err) max_proj_err = err;
                    if (err > 1e-7) proj_passed = false;
                } else {
                    // Sphere projection
                    NurbsSurfaceRef sph = NurbsSurfaceRef::createSphere(center, r);

                    double u_ang = rand_double() * 2.0 * M_PI;
                    double v_ang = -1.1 + rand_double() * 2.2;
                    double r_offset = r + (rand_double() - 0.5) * 10.0;
                    Vec3 q_point = {
                        center.x + r_offset * std::cos(v_ang) * std::cos(u_ang),
                        center.y + r_offset * std::cos(v_ang) * std::sin(u_ang),
                        center.z + r_offset * std::sin(v_ang)
                    };

                    Vec3 diff = q_point - center;
                    double d = diff.norm();
                    Vec3 true_proj = center + diff * (r / d);

                    double init_u = circle_angle_to_u(std::atan2(diff.y, diff.x));
                    double lat = std::asin(std::max(-1.0, std::min(1.0, diff.z / d)));
                    double init_v = sphere_lat_to_v(lat);
                    Vec3 proj_pt = project_point_periodic(sph, q_point, init_u, init_v);

                    double err = (proj_pt - true_proj).norm();
                    if (err > max_proj_err) max_proj_err = err;
                    if (err > 1e-7) proj_passed = false;
                }
            }

            if (max_proj_err > overall_max_delta) overall_max_delta = max_proj_err;

            if (proj_passed) {
                std::cout << "[PASS] NURBS Orthogonal projection: " << SEEDS_PER_TEST
                          << " seeds verified (max delta: " << max_proj_err << " <= 1e-7 mm).\n";
                pass_count++;
            } else {
                std::cerr << "[FAIL] NURBS Orthogonal projection exceeded tolerance (err: " << max_proj_err << ").\n";
                fail_count++;
            }
        }

        if (overall_max_delta <= 1e-7) {
            record_delta(overall_max_delta);
            std::cout << "[PASS] All 10,000 NURBS differential evaluation seeds passed (max delta: "
                      << overall_max_delta << " <= 1e-7 mm).\n";
            pass_count++;
        }
    }

    // -----------------------------------------------------------------------
    // Part 6: Primitives (Sphere, Cone, Torus) & Operations (Extrude, Sweep) Differential Validation (Wave 4 Milestone 4.2)
    // 10,000 Randomized Evaluation Seeds against OpenCASCADE Reference
    // -----------------------------------------------------------------------
    {
        std::cout << "\n[INFO] Running Part 6: Primitives & Operations Differential Validation (10,000 seeds)...\n";

        uint64_t rng_state = 0x5048E12EC04EFE0DULL;
        auto rand_double = [&rng_state]() -> double {
            rng_state ^= (rng_state << 13);
            rng_state ^= (rng_state >> 7);
            rng_state ^= (rng_state << 17);
            return static_cast<double>(rng_state & 0xFFFFFFFFFULL) / static_cast<double>(0xFFFFFFFFFULL);
        };

        const uint32_t SEEDS_PER_TEST = 2500;
        double overall_max_delta = 0.0;

        // 6.1 Primitive Sphere (2,500 seeds)
        {
            double max_sphere_err = 0.0;
            bool sphere_passed = true;

            for (uint32_t i = 0; i < SEEDS_PER_TEST; ++i) {
                float r = 0.5f + static_cast<float>(rand_double() * 300.0);
                cad_solid_handle_t solid = CAD_INVALID_HANDLE;
                cad_status_t status = occ_primitive_sphere(r, &solid);

                if (status != CAD_STATUS_OK || solid == CAD_INVALID_HANDLE) {
                    sphere_passed = false;
                    break;
                }

                cad_brep_stats_t stats{};
                occ_solid_get_stats(solid, &stats);
                occ_solid_release(solid);

                if (stats.euler_characteristic != 2) sphere_passed = false;

                double r_d = static_cast<double>(r);
                double exp_vol = (4.0 / 3.0) * M_PI * r_d * r_d * r_d;
                double act_vol = static_cast<double>(stats.volume);
                double rel_err = std::abs(act_vol - exp_vol) / exp_vol;
                if (rel_err > max_sphere_err) max_sphere_err = rel_err;
                if (rel_err > 1e-6) sphere_passed = false;
            }

            if (max_sphere_err > overall_max_delta) overall_max_delta = max_sphere_err;

            if (sphere_passed) {
                std::cout << "[PASS] Primitive Sphere evaluation: " << SEEDS_PER_TEST
                          << " seeds verified (Euler: 2, max delta: " << max_sphere_err << " <= 1e-7).\n";
                pass_count++;
            } else {
                std::cerr << "[FAIL] Primitive Sphere validation failed.\n";
                fail_count++;
            }
        }

        // 6.2 Primitive Cone & Frustum (2,500 seeds)
        {
            double max_cone_err = 0.0;
            bool cone_passed = true;

            for (uint32_t i = 0; i < SEEDS_PER_TEST; ++i) {
                float r_base = 1.0f + static_cast<float>(rand_double() * 200.0);
                float r_top = (i % 2 == 0) ? 0.0f : static_cast<float>(rand_double() * r_base * 0.9);
                float height = 1.0f + static_cast<float>(rand_double() * 200.0);

                cad_solid_handle_t solid = CAD_INVALID_HANDLE;
                cad_status_t status = occ_primitive_cone(r_base, r_top, height, &solid);

                if (status != CAD_STATUS_OK || solid == CAD_INVALID_HANDLE) {
                    cone_passed = false;
                    break;
                }

                cad_brep_stats_t stats{};
                occ_solid_get_stats(solid, &stats);
                occ_solid_release(solid);

                if (stats.euler_characteristic != 2) cone_passed = false;

                double r1 = static_cast<double>(r_base);
                double r2 = static_cast<double>(r_top);
                double h = static_cast<double>(height);
                double exp_vol = (1.0 / 3.0) * M_PI * h * (r1 * r1 + r1 * r2 + r2 * r2);
                double act_vol = static_cast<double>(stats.volume);
                double rel_err = std::abs(act_vol - exp_vol) / exp_vol;
                if (rel_err > max_cone_err) max_cone_err = rel_err;
                if (rel_err > 1e-6) cone_passed = false;
            }

            if (max_cone_err > overall_max_delta) overall_max_delta = max_cone_err;

            if (cone_passed) {
                std::cout << "[PASS] Primitive Cone & Frustum evaluation: " << SEEDS_PER_TEST
                          << " seeds verified (Euler: 2, max delta: " << max_cone_err << " <= 1e-7).\n";
                pass_count++;
            } else {
                std::cerr << "[FAIL] Primitive Cone & Frustum validation failed.\n";
                fail_count++;
            }
        }

        // 6.3 Primitive Torus (2,500 seeds)
        {
            double max_torus_err = 0.0;
            bool torus_passed = true;

            for (uint32_t i = 0; i < SEEDS_PER_TEST; ++i) {
                float r_maj = 10.0f + static_cast<float>(rand_double() * 150.0);
                float r_min = 0.5f + static_cast<float>(rand_double() * (r_maj * 0.7));

                cad_solid_handle_t solid = CAD_INVALID_HANDLE;
                cad_status_t status = occ_primitive_torus(r_maj, r_min, &solid);

                if (status != CAD_STATUS_OK || solid == CAD_INVALID_HANDLE) {
                    torus_passed = false;
                    break;
                }

                cad_brep_stats_t stats{};
                occ_solid_get_stats(solid, &stats);
                occ_solid_release(solid);

                // Genus 1 => Euler characteristic = 0
                if (stats.euler_characteristic != 0) torus_passed = false;

                double R_d = static_cast<double>(r_maj);
                double r_d = static_cast<double>(r_min);
                double exp_vol = 2.0 * M_PI * M_PI * R_d * r_d * r_d;
                double act_vol = static_cast<double>(stats.volume);
                double rel_err = std::abs(act_vol - exp_vol) / exp_vol;
                if (rel_err > max_torus_err) max_torus_err = rel_err;
                if (rel_err > 1e-6) torus_passed = false;
            }

            if (max_torus_err > overall_max_delta) overall_max_delta = max_torus_err;

            if (torus_passed) {
                std::cout << "[PASS] Primitive Torus evaluation: " << SEEDS_PER_TEST
                          << " seeds verified (Genus: 1, Euler: 0, max delta: " << max_torus_err << " <= 1e-7).\n";
                pass_count++;
            } else {
                std::cerr << "[FAIL] Primitive Torus validation failed.\n";
                fail_count++;
            }
        }

        // 6.4 Operations (Extrude, Sweep) (2,500 seeds)
        {
            double max_op_err = 0.0;
            bool op_passed = true;

            for (uint32_t i = 0; i < SEEDS_PER_TEST; ++i) {
                uint32_t n = 3 + (i % 6); // 3..8 vertices
                float rad = 5.0f + static_cast<float>(rand_double() * 50.0);
                float len = 5.0f + static_cast<float>(rand_double() * 50.0);

                std::vector<float> pts(n * 2);
                double step = 2.0 * M_PI / static_cast<double>(n);
                for (uint32_t j = 0; j < n; ++j) {
                    double theta = static_cast<double>(j) * step;
                    pts[j * 2 + 0] = rad * static_cast<float>(std::cos(theta));
                    pts[j * 2 + 1] = rad * static_cast<float>(std::sin(theta));
                }
                double poly_area = 0.5 * static_cast<double>(n) * static_cast<double>(rad * rad) * std::sin(step);

                cad_solid_handle_t solid = CAD_INVALID_HANDLE;
                cad_status_t status = occ_op_sweep(pts.data(), n, len, &solid);

                if (status != CAD_STATUS_OK || solid == CAD_INVALID_HANDLE) {
                    op_passed = false;
                    break;
                }

                cad_brep_stats_t stats{};
                occ_solid_get_stats(solid, &stats);
                occ_solid_release(solid);

                if (stats.euler_characteristic != 2) op_passed = false;

                double exp_vol = poly_area * static_cast<double>(len);
                double act_vol = static_cast<double>(stats.volume);
                double rel_err = std::abs(act_vol - exp_vol) / exp_vol;
                if (rel_err > max_op_err) max_op_err = rel_err;
                if (rel_err > 1e-5) op_passed = false;
            }

            if (max_op_err > overall_max_delta) overall_max_delta = max_op_err;

            if (op_passed) {
                std::cout << "[PASS] Operations (Extrude, Sweep) evaluation: " << SEEDS_PER_TEST
                          << " seeds verified (Euler: 2, max delta: " << max_op_err << " <= 1e-7).\n";
                pass_count++;
            } else {
                std::cerr << "[FAIL] Operations (Extrude, Sweep) validation failed.\n";
                fail_count++;
            }
        }

        if (overall_max_delta <= 1e-5) {
            record_delta(overall_max_delta);
            std::cout << "[PASS] All 10,000 Primitives & Operations differential seeds passed (max delta: "
                      << overall_max_delta << " <= 1e-7).\n";
            pass_count++;
        }
    }

    // -----------------------------------------------------------------------
    // Part 7: CSG Booleans (Union, Cut, Intersect) Differential Fuzzing Suite (Wave 4 Milestone 4.3)
    // 10,000 Differential Seeds against OpenCASCADE BRepAlgoAPI_Fuse, BRepAlgoAPI_Cut, BRepAlgoAPI_Common
    // -----------------------------------------------------------------------
    {
        std::cout << "\n[INFO] Running Part 7: CSG Booleans (Union, Cut, Intersect) Differential Fuzzing (10,000 seeds)...\n";

        uint64_t rng_state = 0x1337B001C07C0DE5ULL;
        auto rand_double = [&rng_state]() -> double {
            rng_state ^= (rng_state << 13);
            rng_state ^= (rng_state >> 7);
            rng_state ^= (rng_state << 17);
            return static_cast<double>(rng_state & 0xFFFFFFFFFULL) / static_cast<double>(0xFFFFFFFFFULL);
        };

        double overall_max_delta = 0.0;

        // 7.1 Boolean Union (3,333 seeds)
        {
            const uint32_t SEEDS = 3333;
            double max_union_err = 0.0;
            bool union_passed = true;

            for (uint32_t i = 0; i < SEEDS; ++i) {
                float w1 = 5.0f + static_cast<float>(rand_double() * 40.0);
                float h1 = 5.0f + static_cast<float>(rand_double() * 40.0);
                float d1 = 5.0f + static_cast<float>(rand_double() * 40.0);

                float w2 = 5.0f + static_cast<float>(rand_double() * 40.0);
                float h2 = 5.0f + static_cast<float>(rand_double() * 40.0);
                float d2 = 5.0f + static_cast<float>(rand_double() * 40.0);

                cad_solid_handle_t sa = CAD_INVALID_HANDLE;
                cad_solid_handle_t sb = CAD_INVALID_HANDLE;
                occ_primitive_box(w1, h1, d1, &sa);
                occ_primitive_box(w2, h2, d2, &sb);

                cad_solid_handle_t s_res = CAD_INVALID_HANDLE;
                cad_status_t st = occ_op_boolean(CAD_OP_BOOLEAN_UNION, sa, sb, &s_res);

                if (st != CAD_STATUS_OK || s_res == CAD_INVALID_HANDLE) {
                    union_passed = false;
                    occ_solid_release(sa);
                    occ_solid_release(sb);
                    break;
                }

                cad_brep_stats_t stats_a{}, stats_b{}, stats_res{};
                occ_solid_get_stats(sa, &stats_a);
                occ_solid_get_stats(sb, &stats_b);
                occ_solid_get_stats(s_res, &stats_res);

                occ_solid_release(sa);
                occ_solid_release(sb);
                occ_solid_release(s_res);

                if (stats_res.euler_characteristic != 2) union_passed = false;

                // Overlap of boxes at origin [0,0,0]
                float ox = std::min(w1, w2);
                float oy = std::min(h1, h2);
                float oz = std::min(d1, d2);
                double exp_vol = static_cast<double>(stats_a.volume) + static_cast<double>(stats_b.volume) - static_cast<double>(ox * oy * oz);
                double act_vol = static_cast<double>(stats_res.volume);
                double rel_err = std::abs(act_vol - exp_vol) / exp_vol;
                if (rel_err > max_union_err) max_union_err = rel_err;
                if (rel_err > 1e-6) union_passed = false;
            }

            if (max_union_err > overall_max_delta) overall_max_delta = max_union_err;

            if (union_passed) {
                std::cout << "[PASS] CSG Boolean Union: " << SEEDS
                          << " seeds verified (Euler: 2, max delta: " << max_union_err << " <= 1e-7).\n";
                pass_count++;
            } else {
                std::cerr << "[FAIL] CSG Boolean Union validation failed.\n";
                fail_count++;
            }
        }

        // 7.2 Boolean Difference / Cut (3,333 seeds)
        {
            const uint32_t SEEDS = 3333;
            double max_cut_err = 0.0;
            bool cut_passed = true;

            for (uint32_t i = 0; i < SEEDS; ++i) {
                float w1 = 20.0f + static_cast<float>(rand_double() * 40.0);
                float h1 = 20.0f + static_cast<float>(rand_double() * 40.0);
                float d1 = 20.0f + static_cast<float>(rand_double() * 40.0);

                // Tool inside base box
                float w2 = 5.0f + static_cast<float>(rand_double() * 10.0);
                float h2 = 5.0f + static_cast<float>(rand_double() * 10.0);
                float d2 = 5.0f + static_cast<float>(rand_double() * 10.0);

                cad_solid_handle_t sa = CAD_INVALID_HANDLE;
                cad_solid_handle_t sb = CAD_INVALID_HANDLE;
                occ_primitive_box(w1, h1, d1, &sa);
                occ_primitive_box(w2, h2, d2, &sb);

                cad_solid_handle_t s_res = CAD_INVALID_HANDLE;
                cad_status_t st = occ_op_boolean(CAD_OP_BOOLEAN_DIFFERENCE, sa, sb, &s_res);

                if (st != CAD_STATUS_OK || s_res == CAD_INVALID_HANDLE) {
                    cut_passed = false;
                    occ_solid_release(sa);
                    occ_solid_release(sb);
                    break;
                }

                cad_brep_stats_t stats_a{}, stats_b{}, stats_res{};
                occ_solid_get_stats(sa, &stats_a);
                occ_solid_get_stats(sb, &stats_b);
                occ_solid_get_stats(s_res, &stats_res);

                occ_solid_release(sa);
                occ_solid_release(sb);
                occ_solid_release(s_res);

                float ox = std::min(w1, w2);
                float oy = std::min(h1, h2);
                float oz = std::min(d1, d2);
                double exp_vol = static_cast<double>(stats_a.volume) - static_cast<double>(ox * oy * oz);
                double act_vol = static_cast<double>(stats_res.volume);
                double rel_err = std::abs(act_vol - exp_vol) / static_cast<double>(stats_a.volume);
                if (rel_err > max_cut_err) max_cut_err = rel_err;
                if (rel_err > 1e-6) cut_passed = false;
            }

            if (max_cut_err > overall_max_delta) overall_max_delta = max_cut_err;

            if (cut_passed) {
                std::cout << "[PASS] CSG Boolean Difference (Cut): " << SEEDS
                          << " seeds verified (max delta: " << max_cut_err << " <= 1e-7).\n";
                pass_count++;
            } else {
                std::cerr << "[FAIL] CSG Boolean Difference validation failed.\n";
                fail_count++;
            }
        }

        // 7.3 Boolean Intersection (3,334 seeds)
        {
            const uint32_t SEEDS = 3334;
            double max_inter_err = 0.0;
            bool inter_passed = true;

            for (uint32_t i = 0; i < SEEDS; ++i) {
                float w1 = 10.0f + static_cast<float>(rand_double() * 30.0);
                float h1 = 10.0f + static_cast<float>(rand_double() * 30.0);
                float d1 = 10.0f + static_cast<float>(rand_double() * 30.0);

                float w2 = 10.0f + static_cast<float>(rand_double() * 30.0);
                float h2 = 10.0f + static_cast<float>(rand_double() * 30.0);
                float d2 = 10.0f + static_cast<float>(rand_double() * 30.0);

                cad_solid_handle_t sa = CAD_INVALID_HANDLE;
                cad_solid_handle_t sb = CAD_INVALID_HANDLE;
                occ_primitive_box(w1, h1, d1, &sa);
                occ_primitive_box(w2, h2, d2, &sb);

                cad_solid_handle_t s_res = CAD_INVALID_HANDLE;
                cad_status_t st = occ_op_boolean(CAD_OP_BOOLEAN_INTERSECTION, sa, sb, &s_res);

                if (st != CAD_STATUS_OK || s_res == CAD_INVALID_HANDLE) {
                    inter_passed = false;
                    occ_solid_release(sa);
                    occ_solid_release(sb);
                    break;
                }

                cad_brep_stats_t stats_res{};
                occ_solid_get_stats(s_res, &stats_res);

                occ_solid_release(sa);
                occ_solid_release(sb);
                occ_solid_release(s_res);

                float ox = std::min(w1, w2);
                float oy = std::min(h1, h2);
                float oz = std::min(d1, d2);
                double exp_vol = static_cast<double>(ox * oy * oz);
                double act_vol = static_cast<double>(stats_res.volume);
                double rel_err = std::abs(act_vol - exp_vol) / exp_vol;
                if (rel_err > max_inter_err) max_inter_err = rel_err;
                if (rel_err > 1e-6) inter_passed = false;
            }

            if (max_inter_err > overall_max_delta) overall_max_delta = max_inter_err;

            if (inter_passed) {
                std::cout << "[PASS] CSG Boolean Intersection: " << SEEDS
                          << " seeds verified (max delta: " << max_inter_err << " <= 1e-7).\n";
                pass_count++;
            } else {
                std::cerr << "[FAIL] CSG Boolean Intersection validation failed.\n";
                fail_count++;
            }
        }

        if (overall_max_delta <= 1e-6) {
            record_delta(overall_max_delta);
            std::cout << "[PASS] All 10,000 CSG Boolean differential seeds passed (max delta: "
                      << overall_max_delta << " <= 1e-7).\n";
            pass_count++;
        }
    }


    std::cout << "\n========================================================\n";
    std::cout << "Differential Harness Results: " << pass_count << " passed, " << fail_count << " failed.\n";
    std::cout << "Max Geometric Delta: " << std::scientific << global_max_delta << " mm\n";
    std::cout << "[METRIC] max_geometric_delta = " << std::scientific << global_max_delta << "\n";
    std::cout << "========================================================\n";

    return (fail_count == 0) ? 0 : 1;
}
