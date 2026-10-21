#include "planegcs_oracle.h"
#include <cmath>
#include <vector>
#include <algorithm>
#include <unordered_map>
#include <iostream>
#include <cstring>

namespace {

thread_local std::vector<double> tls_updated_coords;
thread_local std::vector<uint32_t> tls_conflicting_ids;

struct PointVar {
    uint32_t id;
    double x;
    double y;
    bool is_fixed;
    int var_x_idx; // -1 if fixed
    int var_y_idx; // -1 if fixed
};

// Gaussian elimination with partial pivoting to solve A * x = b
bool solveLinearSystem(std::vector<double>& A, std::vector<double>& b, int n, std::vector<double>& x) {
    x.resize(n, 0.0);
    std::vector<int> p(n);
    for (int i = 0; i < n; ++i) p[i] = i;

    for (int col = 0; col < n; ++col) {
        // Pivot
        int max_row = col;
        double max_val = std::abs(A[p[col] * n + col]);
        for (int r = col + 1; r < n; ++r) {
            double v = std::abs(A[p[r] * n + col]);
            if (v > max_val) {
                max_val = v;
                max_row = r;
            }
        }

        if (max_val < 1e-15) {
            continue; // Singular or rank-deficient
        }

        std::swap(p[col], p[max_row]);
        int prow = p[col];

        for (int r = col + 1; r < n; ++r) {
            int rrow = p[r];
            double factor = A[rrow * n + col] / A[prow * n + col];
            A[rrow * n + col] = 0.0;
            for (int c = col + 1; c < n; ++c) {
                A[rrow * n + c] -= factor * A[prow * n + c];
            }
            b[rrow] -= factor * b[prow];
        }
    }

    // Back substitution
    for (int i = n - 1; i >= 0; --i) {
        int row = p[i];
        double diag = A[row * n + i];
        if (std::abs(diag) < 1e-15) {
            x[i] = 0.0;
            continue;
        }
        double sum = b[row];
        for (int j = i + 1; j < n; ++j) {
            sum -= A[row * n + j] * x[j];
        }
        x[i] = sum / diag;
    }

    return true;
}

// Compute rank of Jacobian matrix J (M x V) via Gaussian elimination with full pivoting
int computeRank(std::vector<double> J, int M, int V, double tol = 1e-6) {
    if (M == 0 || V == 0) return 0;
    int rank = 0;
    int max_r = std::min(M, V);
    for (int k = 0; k < max_r; ++k) {
        int best_r = k, best_c = k;
        double max_val = std::abs(J[k * V + k]);
        for (int r = k; r < M; ++r) {
            for (int c = k; c < V; ++c) {
                double val = std::abs(J[r * V + c]);
                if (val > max_val) {
                    max_val = val;
                    best_r = r;
                    best_c = c;
                }
            }
        }
        if (max_val < tol) break;

        // Swap rows k and best_r
        if (best_r != k) {
            for (int c = 0; c < V; ++c) {
                std::swap(J[k * V + c], J[best_r * V + c]);
            }
        }
        // Swap cols k and best_c
        if (best_c != k) {
            for (int r = 0; r < M; ++r) {
                std::swap(J[r * V + k], J[r * V + best_c]);
            }
        }

        // Eliminate
        double pivot = J[k * V + k];
        rank++;
        for (int r = k + 1; r < M; ++r) {
            double factor = J[r * V + k] / pivot;
            J[r * V + k] = 0.0;
            for (int c = k + 1; c < V; ++c) {
                J[r * V + c] -= factor * J[k * V + c];
            }
        }
    }
    return rank;
}

} // namespace

int planegcs_solve_sketch(
    cad_sketch_point2d_t* points, uint32_t point_count,
    const cad_sketch_line2d_t* lines, uint32_t line_count,
    const cad_sketch_arc2d_t* arcs, uint32_t arc_count,
    const cad_sketch_circle2d_t* circles, uint32_t circle_count,
    const cad_sketch_constraint_t* constraints, uint32_t constraint_count,
    uint32_t max_iterations, double convergence_tol,
    cad_solver_status_t* out_status
) {
    if (!out_status) return CAD_STATUS_ERROR_INVALID_ARGUMENT;

    // Reset status
    std::memset(out_status, 0, sizeof(cad_solver_status_t));
    tls_conflicting_ids.clear();

    if (!points || point_count == 0) {
        out_status->solve_state = CAD_SOLVE_STATE_SOLVED;
        out_status->degrees_of_freedom = 0;
        return CAD_STATUS_OK;
    }

    // Build lookup maps
    std::unordered_map<uint32_t, size_t> pt_id_to_idx;
    std::vector<PointVar> pt_vars(point_count);
    int num_free_vars = 0;

    for (uint32_t i = 0; i < point_count; ++i) {
        pt_id_to_idx[points[i].id] = i;
        pt_vars[i].id = points[i].id;
        pt_vars[i].x = points[i].x;
        pt_vars[i].y = points[i].y;
        pt_vars[i].is_fixed = (points[i].is_fixed != 0);

        if (pt_vars[i].is_fixed) {
            pt_vars[i].var_x_idx = -1;
            pt_vars[i].var_y_idx = -1;
        } else {
            pt_vars[i].var_x_idx = num_free_vars++;
            pt_vars[i].var_y_idx = num_free_vars++;
        }
    }

    std::unordered_map<uint32_t, size_t> line_id_to_idx;
    for (uint32_t i = 0; i < line_count; ++i) {
        line_id_to_idx[lines[i].id] = i;
    }

    std::unordered_map<uint32_t, size_t> arc_id_to_idx;
    for (uint32_t i = 0; i < arc_count; ++i) {
        arc_id_to_idx[arcs[i].id] = i;
    }

    std::unordered_map<uint32_t, size_t> circle_id_to_idx;
    for (uint32_t i = 0; i < circle_count; ++i) {
        circle_id_to_idx[circles[i].id] = i;
    }

    // Helper to evaluate residuals and Jacobian
    auto evaluateSystem = [&](
        const std::vector<PointVar>& vars,
        std::vector<double>& F,
        std::vector<double>& J,
        std::vector<uint32_t>& eq_to_con_id
    ) {
        F.clear();
        J.clear();
        eq_to_con_id.clear();

        auto addEquation = [&](double res, uint32_t con_id) -> size_t {
            size_t eq_idx = F.size();
            F.push_back(res);
            eq_to_con_id.push_back(con_id);
            J.resize((eq_idx + 1) * num_free_vars, 0.0);
            return eq_idx;
        };

        auto setDeriv = [&](size_t eq_idx, int var_idx, double deriv) {
            if (var_idx >= 0 && var_idx < num_free_vars) {
                J[eq_idx * num_free_vars + var_idx] += deriv;
            }
        };

        for (uint32_t c = 0; c < constraint_count; ++c) {
            const auto& con = constraints[c];
            switch (con.type) {
                case CAD_CONSTRAINT_COINCIDENT: {
                    if (pt_id_to_idx.count(con.entity1_id) && pt_id_to_idx.count(con.entity2_id)) {
                        size_t p1 = pt_id_to_idx[con.entity1_id];
                        size_t p2 = pt_id_to_idx[con.entity2_id];
                        size_t eq_x = addEquation(vars[p2].x - vars[p1].x, con.id);
                        setDeriv(eq_x, vars[p1].var_x_idx, -1.0);
                        setDeriv(eq_x, vars[p2].var_x_idx, 1.0);

                        size_t eq_y = addEquation(vars[p2].y - vars[p1].y, con.id);
                        setDeriv(eq_y, vars[p1].var_y_idx, -1.0);
                        setDeriv(eq_y, vars[p2].var_y_idx, 1.0);
                    } else if (pt_id_to_idx.count(con.entity1_id) && line_id_to_idx.count(con.entity2_id)) {
                        size_t p = pt_id_to_idx[con.entity1_id];
                        const auto& ln = lines[line_id_to_idx[con.entity2_id]];
                        if (pt_id_to_idx.count(ln.start_point_id) && pt_id_to_idx.count(ln.end_point_id)) {
                            size_t p1 = pt_id_to_idx[ln.start_point_id];
                            size_t p2 = pt_id_to_idx[ln.end_point_id];
                            double dx = vars[p2].x - vars[p1].x;
                            double dy = vars[p2].y - vars[p1].y;
                            double res = dx * (vars[p].y - vars[p1].y) - dy * (vars[p].x - vars[p1].x);
                            size_t eq = addEquation(res, con.id);
                            setDeriv(eq, vars[p].var_x_idx, -dy);
                            setDeriv(eq, vars[p].var_y_idx, dx);
                            setDeriv(eq, vars[p1].var_x_idx, dy);
                            setDeriv(eq, vars[p1].var_y_idx, -dx);
                            setDeriv(eq, vars[p2].var_x_idx, -(vars[p].y - vars[p1].y));
                            setDeriv(eq, vars[p2].var_y_idx, vars[p].x - vars[p1].x);
                        }
                    }
                    break;
                }
                case CAD_CONSTRAINT_HORIZONTAL: {
                    size_t p1 = 0, p2 = 0;
                    if (pt_id_to_idx.count(con.entity1_id) && pt_id_to_idx.count(con.entity2_id)) {
                        p1 = pt_id_to_idx[con.entity1_id];
                        p2 = pt_id_to_idx[con.entity2_id];
                    } else if (line_id_to_idx.count(con.entity1_id)) {
                        const auto& ln = lines[line_id_to_idx[con.entity1_id]];
                        p1 = pt_id_to_idx[ln.start_point_id];
                        p2 = pt_id_to_idx[ln.end_point_id];
                    }
                    size_t eq = addEquation(vars[p2].y - vars[p1].y, con.id);
                    setDeriv(eq, vars[p1].var_y_idx, -1.0);
                    setDeriv(eq, vars[p2].var_y_idx, 1.0);
                    break;
                }
                case CAD_CONSTRAINT_VERTICAL: {
                    size_t p1 = 0, p2 = 0;
                    if (pt_id_to_idx.count(con.entity1_id) && pt_id_to_idx.count(con.entity2_id)) {
                        p1 = pt_id_to_idx[con.entity1_id];
                        p2 = pt_id_to_idx[con.entity2_id];
                    } else if (line_id_to_idx.count(con.entity1_id)) {
                        const auto& ln = lines[line_id_to_idx[con.entity1_id]];
                        p1 = pt_id_to_idx[ln.start_point_id];
                        p2 = pt_id_to_idx[ln.end_point_id];
                    }
                    size_t eq = addEquation(vars[p2].x - vars[p1].x, con.id);
                    setDeriv(eq, vars[p1].var_x_idx, -1.0);
                    setDeriv(eq, vars[p2].var_x_idx, 1.0);
                    break;
                }
                case CAD_CONSTRAINT_DISTANCE: {
                    size_t p1 = 0, p2 = 0;
                    if (pt_id_to_idx.count(con.entity1_id) && pt_id_to_idx.count(con.entity2_id)) {
                        p1 = pt_id_to_idx[con.entity1_id];
                        p2 = pt_id_to_idx[con.entity2_id];
                    } else if (line_id_to_idx.count(con.entity1_id)) {
                        const auto& ln = lines[line_id_to_idx[con.entity1_id]];
                        p1 = pt_id_to_idx[ln.start_point_id];
                        p2 = pt_id_to_idx[ln.end_point_id];
                    }
                    double dx = vars[p2].x - vars[p1].x;
                    double dy = vars[p2].y - vars[p1].y;
                    double dist = std::sqrt(dx * dx + dy * dy);
                    double safe_dist = (dist > 1e-12) ? dist : 1e-12;
                    double target_dist = con.parameter_value;
                    size_t eq = addEquation(dist - target_dist, con.id);
                    setDeriv(eq, vars[p1].var_x_idx, -dx / safe_dist);
                    setDeriv(eq, vars[p1].var_y_idx, -dy / safe_dist);
                    setDeriv(eq, vars[p2].var_x_idx, dx / safe_dist);
                    setDeriv(eq, vars[p2].var_y_idx, dy / safe_dist);
                    break;
                }
                case CAD_CONSTRAINT_PARALLEL: {
                    if (line_id_to_idx.count(con.entity1_id) && line_id_to_idx.count(con.entity2_id)) {
                        const auto& l1 = lines[line_id_to_idx[con.entity1_id]];
                        const auto& l2 = lines[line_id_to_idx[con.entity2_id]];
                        size_t p1 = pt_id_to_idx[l1.start_point_id];
                        size_t p2 = pt_id_to_idx[l1.end_point_id];
                        size_t p3 = pt_id_to_idx[l2.start_point_id];
                        size_t p4 = pt_id_to_idx[l2.end_point_id];
                        double dx1 = vars[p2].x - vars[p1].x;
                        double dy1 = vars[p2].y - vars[p1].y;
                        double dx2 = vars[p4].x - vars[p3].x;
                        double dy2 = vars[p4].y - vars[p3].y;
                        double res = dx1 * dy2 - dy1 * dx2;
                        size_t eq = addEquation(res, con.id);
                        setDeriv(eq, vars[p1].var_x_idx, -dy2);
                        setDeriv(eq, vars[p1].var_y_idx, dx2);
                        setDeriv(eq, vars[p2].var_x_idx, dy2);
                        setDeriv(eq, vars[p2].var_y_idx, -dx2);
                        setDeriv(eq, vars[p3].var_x_idx, dy1);
                        setDeriv(eq, vars[p3].var_y_idx, -dx1);
                        setDeriv(eq, vars[p4].var_x_idx, -dy1);
                        setDeriv(eq, vars[p4].var_y_idx, dx1);
                    }
                    break;
                }
                case CAD_CONSTRAINT_PERPENDICULAR: {
                    if (line_id_to_idx.count(con.entity1_id) && line_id_to_idx.count(con.entity2_id)) {
                        const auto& l1 = lines[line_id_to_idx[con.entity1_id]];
                        const auto& l2 = lines[line_id_to_idx[con.entity2_id]];
                        size_t p1 = pt_id_to_idx[l1.start_point_id];
                        size_t p2 = pt_id_to_idx[l1.end_point_id];
                        size_t p3 = pt_id_to_idx[l2.start_point_id];
                        size_t p4 = pt_id_to_idx[l2.end_point_id];
                        double dx1 = vars[p2].x - vars[p1].x;
                        double dy1 = vars[p2].y - vars[p1].y;
                        double dx2 = vars[p4].x - vars[p3].x;
                        double dy2 = vars[p4].y - vars[p3].y;
                        double res = dx1 * dx2 + dy1 * dy2;
                        size_t eq = addEquation(res, con.id);
                        setDeriv(eq, vars[p1].var_x_idx, -dx2);
                        setDeriv(eq, vars[p1].var_y_idx, -dy2);
                        setDeriv(eq, vars[p2].var_x_idx, dx2);
                        setDeriv(eq, vars[p2].var_y_idx, dy2);
                        setDeriv(eq, vars[p3].var_x_idx, -dx1);
                        setDeriv(eq, vars[p3].var_y_idx, -dy1);
                        setDeriv(eq, vars[p4].var_x_idx, dx1);
                        setDeriv(eq, vars[p4].var_y_idx, dy1);
                    }
                    break;
                }
                case CAD_CONSTRAINT_EQUAL: {
                    if (line_id_to_idx.count(con.entity1_id) && line_id_to_idx.count(con.entity2_id)) {
                        const auto& l1 = lines[line_id_to_idx[con.entity1_id]];
                        const auto& l2 = lines[line_id_to_idx[con.entity2_id]];
                        size_t p1 = pt_id_to_idx[l1.start_point_id];
                        size_t p2 = pt_id_to_idx[l1.end_point_id];
                        size_t p3 = pt_id_to_idx[l2.start_point_id];
                        size_t p4 = pt_id_to_idx[l2.end_point_id];
                        double dx1 = vars[p2].x - vars[p1].x;
                        double dy1 = vars[p2].y - vars[p1].y;
                        double dist1 = std::sqrt(dx1 * dx1 + dy1 * dy1);
                        double safe_d1 = (dist1 > 1e-12) ? dist1 : 1e-12;

                        double dx2 = vars[p4].x - vars[p3].x;
                        double dy2 = vars[p4].y - vars[p3].y;
                        double dist2 = std::sqrt(dx2 * dx2 + dy2 * dy2);
                        double safe_d2 = (dist2 > 1e-12) ? dist2 : 1e-12;

                        size_t eq = addEquation(dist1 - dist2, con.id);
                        setDeriv(eq, vars[p1].var_x_idx, -dx1 / safe_d1);
                        setDeriv(eq, vars[p1].var_y_idx, -dy1 / safe_d1);
                        setDeriv(eq, vars[p2].var_x_idx, dx1 / safe_d1);
                        setDeriv(eq, vars[p2].var_y_idx, dy1 / safe_d1);
                        setDeriv(eq, vars[p3].var_x_idx, dx2 / safe_d2);
                        setDeriv(eq, vars[p3].var_y_idx, dy2 / safe_d2);
                        setDeriv(eq, vars[p4].var_x_idx, -dx2 / safe_d2);
                        setDeriv(eq, vars[p4].var_y_idx, -dy2 / safe_d2);
                    }
                    break;
                }
                case CAD_CONSTRAINT_TANGENT: {
                    size_t line_idx = 0;
                    size_t center_pt = 0;
                    double radius = con.parameter_value;

                    if (line_id_to_idx.count(con.entity1_id) && (arc_id_to_idx.count(con.entity2_id) || circle_id_to_idx.count(con.entity2_id))) {
                        line_idx = line_id_to_idx[con.entity1_id];
                        if (arc_id_to_idx.count(con.entity2_id)) {
                            center_pt = pt_id_to_idx[arcs[arc_id_to_idx[con.entity2_id]].center_point_id];
                            radius = arcs[arc_id_to_idx[con.entity2_id]].radius;
                        } else {
                            center_pt = pt_id_to_idx[circles[circle_id_to_idx[con.entity2_id]].center_point_id];
                            radius = circles[circle_id_to_idx[con.entity2_id]].radius;
                        }
                    } else if (line_id_to_idx.count(con.entity2_id) && (arc_id_to_idx.count(con.entity1_id) || circle_id_to_idx.count(con.entity1_id))) {
                        line_idx = line_id_to_idx[con.entity2_id];
                        if (arc_id_to_idx.count(con.entity1_id)) {
                            center_pt = pt_id_to_idx[arcs[arc_id_to_idx[con.entity1_id]].center_point_id];
                            radius = arcs[arc_id_to_idx[con.entity1_id]].radius;
                        } else {
                            center_pt = pt_id_to_idx[circles[circle_id_to_idx[con.entity1_id]].center_point_id];
                            radius = circles[circle_id_to_idx[con.entity1_id]].radius;
                        }
                    }

                    const auto& ln = lines[line_idx];
                    size_t p1 = pt_id_to_idx[ln.start_point_id];
                    size_t p2 = pt_id_to_idx[ln.end_point_id];

                    double ux = vars[p2].x - vars[p1].x;
                    double uy = vars[p2].y - vars[p1].y;
                    double L = std::sqrt(ux * ux + uy * uy);
                    double safe_L = (L > 1e-12) ? L : 1e-12;
                    double wx = vars[center_pt].x - vars[p1].x;
                    double wy = vars[center_pt].y - vars[p1].y;
                    double cross = ux * wy - uy * wx;
                    double dist = cross / safe_L;
                    double sign = (dist >= 0.0) ? 1.0 : -1.0;

                    size_t eq = addEquation(dist - sign * radius, con.id);
                    // Exact analytical derivatives of dist = cross / L
                    setDeriv(eq, vars[center_pt].var_x_idx, -uy / safe_L);
                    setDeriv(eq, vars[center_pt].var_y_idx, ux / safe_L);
                    setDeriv(eq, vars[p1].var_x_idx, (uy - wy + dist * (ux / safe_L)) / safe_L);
                    setDeriv(eq, vars[p1].var_y_idx, (wx - ux + dist * (uy / safe_L)) / safe_L);
                    setDeriv(eq, vars[p2].var_x_idx, (wy - dist * (ux / safe_L)) / safe_L);
                    setDeriv(eq, vars[p2].var_y_idx, (-wx - dist * (uy / safe_L)) / safe_L);
                    break;
                }
                case CAD_CONSTRAINT_SYMMETRIC: {
                    if (pt_id_to_idx.count(con.entity1_id) && pt_id_to_idx.count(con.entity2_id) && line_id_to_idx.count(con.entity3_id)) {
                        size_t pa = pt_id_to_idx[con.entity1_id];
                        size_t pb = pt_id_to_idx[con.entity2_id];
                        const auto& axis = lines[line_id_to_idx[con.entity3_id]];
                        size_t p1 = pt_id_to_idx[axis.start_point_id];
                        size_t p2 = pt_id_to_idx[axis.end_point_id];

                        double ax = vars[p2].x - vars[p1].x;
                        double ay = vars[p2].y - vars[p1].y;
                        double mx = 0.5 * (vars[pa].x + vars[pb].x);
                        double my = 0.5 * (vars[pa].y + vars[pb].y);

                        // Eq 1: Midpoint lies on axis line
                        double res1 = ax * (my - vars[p1].y) - ay * (mx - vars[p1].x);
                        size_t eq1 = addEquation(res1, con.id);
                        setDeriv(eq1, vars[pa].var_x_idx, -0.5 * ay);
                        setDeriv(eq1, vars[pa].var_y_idx, 0.5 * ax);
                        setDeriv(eq1, vars[pb].var_x_idx, -0.5 * ay);
                        setDeriv(eq1, vars[pb].var_y_idx, 0.5 * ax);

                        // Eq 2: Vector (pb - pa) perpendicular to axis
                        double vx = vars[pb].x - vars[pa].x;
                        double vy = vars[pb].y - vars[pa].y;
                        double res2 = vx * ax + vy * ay;
                        size_t eq2 = addEquation(res2, con.id);
                        setDeriv(eq2, vars[pa].var_x_idx, -ax);
                        setDeriv(eq2, vars[pa].var_y_idx, -ay);
                        setDeriv(eq2, vars[pb].var_x_idx, ax);
                        setDeriv(eq2, vars[pb].var_y_idx, ay);
                    }
                    break;
                }
                case CAD_CONSTRAINT_ANGLE: {
                    if (line_id_to_idx.count(con.entity1_id) && line_id_to_idx.count(con.entity2_id)) {
                        const auto& l1 = lines[line_id_to_idx[con.entity1_id]];
                        const auto& l2 = lines[line_id_to_idx[con.entity2_id]];
                        size_t p1 = pt_id_to_idx[l1.start_point_id];
                        size_t p2 = pt_id_to_idx[l1.end_point_id];
                        size_t p3 = pt_id_to_idx[l2.start_point_id];
                        size_t p4 = pt_id_to_idx[l2.end_point_id];
                        double ux = vars[p2].x - vars[p1].x;
                        double uy = vars[p2].y - vars[p1].y;
                        double vx = vars[p4].x - vars[p3].x;
                        double vy = vars[p4].y - vars[p3].y;
                        double L1 = std::sqrt(ux * ux + uy * uy);
                        double L2 = std::sqrt(vx * vx + vy * vy);
                        double safe_denom = (L1 * L2 > 1e-12) ? (L1 * L2) : 1e-12;
                        double cos_theta = std::cos(con.parameter_value);
                        double res = (ux * vx + uy * vy) - safe_denom * cos_theta;
                        size_t eq = addEquation(res, con.id);
                        setDeriv(eq, vars[p1].var_x_idx, -vx + ux / L1 * L2 * cos_theta);
                        setDeriv(eq, vars[p1].var_y_idx, -vy + uy / L1 * L2 * cos_theta);
                        setDeriv(eq, vars[p2].var_x_idx, vx - ux / L1 * L2 * cos_theta);
                        setDeriv(eq, vars[p2].var_y_idx, vy - uy / L1 * L2 * cos_theta);
                        setDeriv(eq, vars[p3].var_x_idx, -ux + vx / L2 * L1 * cos_theta);
                        setDeriv(eq, vars[p3].var_y_idx, -uy + vy / L2 * L1 * cos_theta);
                        setDeriv(eq, vars[p4].var_x_idx, ux - vx / L2 * L1 * cos_theta);
                        setDeriv(eq, vars[p4].var_y_idx, uy - vy / L2 * L1 * cos_theta);
                    }
                    break;
                }
                case CAD_CONSTRAINT_RADIUS: {
                    size_t center_pt = 0;
                    size_t start_pt = 0;
                    double target_r = con.parameter_value;
                    if (circle_id_to_idx.count(con.entity1_id)) {
                        const auto& c_ent = circles[circle_id_to_idx[con.entity1_id]];
                        center_pt = pt_id_to_idx[c_ent.center_point_id];
                        if (pt_id_to_idx.count(con.entity2_id)) {
                            start_pt = pt_id_to_idx[con.entity2_id];
                        }
                    } else if (arc_id_to_idx.count(con.entity1_id)) {
                        const auto& a_ent = arcs[arc_id_to_idx[con.entity1_id]];
                        center_pt = pt_id_to_idx[a_ent.center_point_id];
                        start_pt = pt_id_to_idx[a_ent.start_point_id];
                    }
                    if (start_pt != center_pt) {
                        double dx = vars[start_pt].x - vars[center_pt].x;
                        double dy = vars[start_pt].y - vars[center_pt].y;
                        double dist = std::sqrt(dx * dx + dy * dy);
                        double safe_d = (dist > 1e-12) ? dist : 1e-12;
                        size_t eq = addEquation(dist - target_r, con.id);
                        setDeriv(eq, vars[center_pt].var_x_idx, -dx / safe_d);
                        setDeriv(eq, vars[center_pt].var_y_idx, -dy / safe_d);
                        setDeriv(eq, vars[start_pt].var_x_idx, dx / safe_d);
                        setDeriv(eq, vars[start_pt].var_y_idx, dy / safe_d);
                    }
                    break;
                }
            }
        }
    };

    // Levenberg-Marquardt solver loop
    std::vector<double> F;
    std::vector<double> J;
    std::vector<uint32_t> eq_to_con_id;

    double lambda = 1e-3;
    uint32_t iters_taken = 0;
    double max_res = 0.0;

    for (uint32_t iter = 0; iter < max_iterations; ++iter) {
        iters_taken = iter + 1;
        evaluateSystem(pt_vars, F, J, eq_to_con_id);

        int M = static_cast<int>(F.size());
        int V = num_free_vars;

        max_res = 0.0;
        double error_sq = 0.0;
        for (double r : F) {
            double abs_r = std::abs(r);
            if (abs_r > max_res) max_res = abs_r;
            error_sq += abs_r * abs_r;
        }

        if (max_res <= convergence_tol || M == 0 || V == 0) {
            break;
        }

        // Form normal equations: (J^T J + lambda I) delta = -J^T F
        std::vector<double> A(V * V, 0.0);
        std::vector<double> b(V, 0.0);

        for (int r = 0; r < M; ++r) {
            double fr = F[r];
            for (int c = 0; c < V; ++c) {
                double j_rc = J[r * V + c];
                b[c] -= j_rc * fr;
                for (int c2 = 0; c2 < V; ++c2) {
                    A[c * V + c2] += j_rc * J[r * V + c2];
                }
            }
        }

        for (int c = 0; c < V; ++c) {
            A[c * V + c] += lambda;
        }

        std::vector<double> delta;
        solveLinearSystem(A, b, V, delta);

        // Candidate state
        std::vector<PointVar> cand_vars = pt_vars;
        for (auto& pv : cand_vars) {
            if (pv.var_x_idx >= 0) pv.x += delta[pv.var_x_idx];
            if (pv.var_y_idx >= 0) pv.y += delta[pv.var_y_idx];
        }

        std::vector<double> cand_F;
        std::vector<double> cand_J;
        std::vector<uint32_t> cand_eq_to_con_id;
        evaluateSystem(cand_vars, cand_F, cand_J, cand_eq_to_con_id);

        double cand_error_sq = 0.0;
        for (double r : cand_F) cand_error_sq += r * r;

        if (cand_error_sq < error_sq) {
            pt_vars = cand_vars;
            lambda = std::max(lambda * 0.1, 1e-14);
        } else {
            lambda = std::min(lambda * 10.0, 1e8);
        }
    }

    // Final evaluation
    evaluateSystem(pt_vars, F, J, eq_to_con_id);
    max_res = 0.0;
    for (double r : F) {
        double abs_r = std::abs(r);
        if (abs_r > max_res) max_res = abs_r;
    }

    // Rank and DOF analysis via Gaussian elimination with full pivoting
    int M = static_cast<int>(F.size());
    int V = num_free_vars;
    int rank = computeRank(J, M, V, 1e-6);
    int dof = (V >= rank) ? (V - rank) : 0;

    out_status->iterations = iters_taken;
    out_status->max_residual = max_res;
    out_status->degrees_of_freedom = static_cast<uint32_t>(dof);

    if (max_res <= convergence_tol) {
        if (dof > 0) {
            out_status->solve_state = CAD_SOLVE_STATE_UNDER_CONSTRAINED;
        } else if (M > rank) {
            out_status->solve_state = CAD_SOLVE_STATE_OVER_CONSTRAINED;
        } else {
            out_status->solve_state = CAD_SOLVE_STATE_SOLVED;
        }
    } else {
        out_status->solve_state = CAD_SOLVE_STATE_CONFLICTING;
        for (size_t i = 0; i < F.size(); ++i) {
            if (std::abs(F[i]) > convergence_tol) {
                uint32_t cid = eq_to_con_id[i];
                if (std::find(tls_conflicting_ids.begin(), tls_conflicting_ids.end(), cid) == tls_conflicting_ids.end()) {
                    tls_conflicting_ids.push_back(cid);
                }
            }
        }
    }

    // Update input points and populate flat buffers
    tls_updated_coords.resize(point_count * 2);
    for (uint32_t i = 0; i < point_count; ++i) {
        points[i].x = pt_vars[i].x;
        points[i].y = pt_vars[i].y;
        tls_updated_coords[2 * i] = pt_vars[i].x;
        tls_updated_coords[2 * i + 1] = pt_vars[i].y;
    }

    out_status->updated_coords = tls_updated_coords.data();
    out_status->coord_count = point_count;
    out_status->conflicting_constraint_ids = tls_conflicting_ids.data();
    out_status->conflicting_count = static_cast<uint32_t>(tls_conflicting_ids.size());

    return CAD_STATUS_OK;
}

int planegcs_solve_2d(
    gcs_point_t* points, uint32_t num_points,
    const gcs_line_t* lines, uint32_t num_lines,
    const gcs_constraint_t* constraints, uint32_t num_constraints,
    uint32_t max_iterations, double convergence_tol
) {
    if (!points || num_points == 0 || !constraints || num_constraints == 0) {
        return 0;
    }

    std::vector<cad_sketch_point2d_t> sk_points(num_points);
    for (uint32_t i = 0; i < num_points; ++i) {
        sk_points[i].id = i;
        sk_points[i].x = points[i].x;
        sk_points[i].y = points[i].y;
        sk_points[i].is_fixed = (i == 0) ? 1 : 0;
    }

    std::vector<cad_sketch_line2d_t> sk_lines(num_lines);
    for (uint32_t i = 0; i < num_lines; ++i) {
        sk_lines[i].id = 100 + i;
        sk_lines[i].start_point_id = lines[i].p1_idx;
        sk_lines[i].end_point_id = lines[i].p2_idx;
    }

    std::vector<cad_sketch_constraint_t> sk_cons(num_constraints);
    for (uint32_t i = 0; i < num_constraints; ++i) {
        sk_cons[i].id = 1000 + i;
        sk_cons[i].parameter_value = constraints[i].value;
        sk_cons[i].is_driving = 1;

        // Map element IDs if line or point
        uint32_t e1 = constraints[i].elem1;
        uint32_t e2 = constraints[i].elem2;

        switch (constraints[i].type) {
            case GCS_COINCIDENT:
                sk_cons[i].type = CAD_CONSTRAINT_COINCIDENT;
                sk_cons[i].entity1_id = e1;
                sk_cons[i].entity2_id = e2;
                break;
            case GCS_DISTANCE:
                sk_cons[i].type = CAD_CONSTRAINT_DISTANCE;
                sk_cons[i].entity1_id = e1;
                sk_cons[i].entity2_id = e2;
                break;
            case GCS_HORIZONTAL:
                sk_cons[i].type = CAD_CONSTRAINT_HORIZONTAL;
                sk_cons[i].entity1_id = e1;
                sk_cons[i].entity2_id = e2;
                break;
            case GCS_VERTICAL:
                sk_cons[i].type = CAD_CONSTRAINT_VERTICAL;
                sk_cons[i].entity1_id = e1;
                sk_cons[i].entity2_id = e2;
                break;
            case GCS_PARALLEL:
                sk_cons[i].type = CAD_CONSTRAINT_PARALLEL;
                sk_cons[i].entity1_id = 100 + e1;
                sk_cons[i].entity2_id = 100 + e2;
                break;
            case GCS_PERPENDICULAR:
                sk_cons[i].type = CAD_CONSTRAINT_PERPENDICULAR;
                sk_cons[i].entity1_id = 100 + e1;
                sk_cons[i].entity2_id = 100 + e2;
                break;
            case GCS_TANGENT:
                sk_cons[i].type = CAD_CONSTRAINT_TANGENT;
                sk_cons[i].entity1_id = 100 + e1;
                sk_cons[i].entity2_id = 200 + e2;
                break;
            case GCS_EQUAL:
                sk_cons[i].type = CAD_CONSTRAINT_EQUAL;
                sk_cons[i].entity1_id = 100 + e1;
                sk_cons[i].entity2_id = 100 + e2;
                break;
            case GCS_SYMMETRIC:
                sk_cons[i].type = CAD_CONSTRAINT_SYMMETRIC;
                sk_cons[i].entity1_id = e1;
                sk_cons[i].entity2_id = e2;
                sk_cons[i].entity3_id = 100 + constraints[i].elem3;
                break;
            case GCS_ANGLE:
                sk_cons[i].type = CAD_CONSTRAINT_ANGLE;
                sk_cons[i].entity1_id = 100 + e1;
                sk_cons[i].entity2_id = 100 + e2;
                break;
            case GCS_RADIUS:
                sk_cons[i].type = CAD_CONSTRAINT_RADIUS;
                sk_cons[i].entity1_id = 300 + e1;
                break;
        }
    }

    cad_solver_status_t status{};
    cad_status_t res = (cad_status_t)planegcs_solve_sketch(
        sk_points.data(), num_points,
        sk_lines.data(), num_lines,
        nullptr, 0,
        nullptr, 0,
        sk_cons.data(), num_constraints,
        max_iterations, convergence_tol,
        &status
    );

    if (res == CAD_STATUS_OK && (status.solve_state == CAD_SOLVE_STATE_SOLVED || status.solve_state == CAD_SOLVE_STATE_UNDER_CONSTRAINED || status.solve_state == CAD_SOLVE_STATE_OVER_CONSTRAINED)) {
        for (uint32_t i = 0; i < num_points; ++i) {
            points[i].x = sk_points[i].x;
            points[i].y = sk_points[i].y;
        }
        return 0; // Success
    }

    return 1; // Failed to converge
}
