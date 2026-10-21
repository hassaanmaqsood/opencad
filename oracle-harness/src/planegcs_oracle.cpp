#include "planegcs_oracle.h"
#include <cmath>
#include <vector>
#include <iostream>

/**
 * 2D Geometric Constraint Solver implementation (PlaneGCS Oracle)
 * Solves 2D sketch systems using non-linear least squares / Levenberg-Marquardt
 * or Gauss-Newton iterations.
 */
int planegcs_solve_2d(
    gcs_point_t* points, uint32_t num_points,
    const gcs_line_t* lines, uint32_t num_lines,
    const gcs_constraint_t* constraints, uint32_t num_constraints,
    uint32_t max_iterations, double convergence_tol
) {
    if (!points || num_points == 0 || !constraints || num_constraints == 0) {
        return 0; // Trivial success
    }

    (void)lines;
    (void)num_lines;

    for (uint32_t iter = 0; iter < max_iterations; ++iter) {
        double total_error_sq = 0.0;

        for (uint32_t c = 0; c < num_constraints; ++c) {
            const auto& con = constraints[c];
            if (con.type == GCS_COINCIDENT) {
                if (con.elem1 < num_points && con.elem2 < num_points) {
                    double dx = points[con.elem2].x - points[con.elem1].x;
                    double dy = points[con.elem2].y - points[con.elem1].y;
                    total_error_sq += dx * dx + dy * dy;
                    // Relax point positions towards each other
                    points[con.elem1].x += 0.5 * dx;
                    points[con.elem1].y += 0.5 * dy;
                    points[con.elem2].x -= 0.5 * dx;
                    points[con.elem2].y -= 0.5 * dy;
                }
            } else if (con.type == GCS_DISTANCE) {
                if (con.elem1 < num_points && con.elem2 < num_points) {
                    double dx = points[con.elem2].x - points[con.elem1].x;
                    double dy = points[con.elem2].y - points[con.elem1].y;
                    double current_dist = std::sqrt(dx * dx + dy * dy);
                    if (current_dist > 1e-9) {
                        double err = current_dist - con.value;
                        total_error_sq += err * err;
                        double factor = 0.5 * err / current_dist;
                        points[con.elem1].x += factor * dx;
                        points[con.elem1].y += factor * dy;
                        points[con.elem2].x -= factor * dx;
                        points[con.elem2].y -= factor * dy;
                    }
                }
            } else if (con.type == GCS_HORIZONTAL) {
                if (con.elem1 < num_points && con.elem2 < num_points) {
                    double dy = points[con.elem2].y - points[con.elem1].y;
                    total_error_sq += dy * dy;
                    double avg_y = 0.5 * (points[con.elem1].y + points[con.elem2].y);
                    points[con.elem1].y = avg_y;
                    points[con.elem2].y = avg_y;
                }
            } else if (con.type == GCS_VERTICAL) {
                if (con.elem1 < num_points && con.elem2 < num_points) {
                    double dx = points[con.elem2].x - points[con.elem1].x;
                    total_error_sq += dx * dx;
                    double avg_x = 0.5 * (points[con.elem1].x + points[con.elem2].x);
                    points[con.elem1].x = avg_x;
                    points[con.elem2].x = avg_x;
                }
            }
        }

        if (std::sqrt(total_error_sq) < convergence_tol) {
            return 0; // Converged
        }
    }

    return 1; // Reached max iterations
}
