#include "fuzzer.hpp"
#include <cmath>

std::vector<gcs_point_t> FuzzSketchConfiguration::toGcsPoints() const {
    std::vector<gcs_point_t> gcs_pts(points.size());
    for (size_t i = 0; i < points.size(); ++i) {
        gcs_pts[i].x = points[i].x;
        gcs_pts[i].y = points[i].y;
    }
    return gcs_pts;
}

std::vector<gcs_line_t> FuzzSketchConfiguration::toGcsLines() const {
    std::vector<gcs_line_t> gcs_lns(lines.size());
    for (size_t i = 0; i < lines.size(); ++i) {
        gcs_lns[i].p1_idx = lines[i].start_point_id;
        gcs_lns[i].p2_idx = lines[i].end_point_id;
    }
    return gcs_lns;
}

std::vector<gcs_constraint_t> FuzzSketchConfiguration::toGcsConstraints() const {
    std::vector<gcs_constraint_t> gcs_cons(constraints.size());
    for (size_t i = 0; i < constraints.size(); ++i) {
        gcs_cons[i].elem1 = constraints[i].entity1_id;
        gcs_cons[i].elem2 = constraints[i].entity2_id;
        gcs_cons[i].elem3 = constraints[i].entity3_id;
        gcs_cons[i].elem4 = constraints[i].entity4_id;
        gcs_cons[i].value = constraints[i].parameter_value;
        switch (constraints[i].type) {
            case CAD_CONSTRAINT_COINCIDENT:
                gcs_cons[i].type = GCS_COINCIDENT;
                break;
            case CAD_CONSTRAINT_DISTANCE:
                gcs_cons[i].type = GCS_DISTANCE;
                break;
            case CAD_CONSTRAINT_HORIZONTAL:
                gcs_cons[i].type = GCS_HORIZONTAL;
                break;
            case CAD_CONSTRAINT_VERTICAL:
                gcs_cons[i].type = GCS_VERTICAL;
                break;
            case CAD_CONSTRAINT_PARALLEL:
                gcs_cons[i].type = GCS_PARALLEL;
                break;
            case CAD_CONSTRAINT_PERPENDICULAR:
                gcs_cons[i].type = GCS_PERPENDICULAR;
                break;
            case CAD_CONSTRAINT_TANGENT:
                gcs_cons[i].type = GCS_TANGENT;
                break;
            case CAD_CONSTRAINT_EQUAL:
                gcs_cons[i].type = GCS_EQUAL;
                break;
            case CAD_CONSTRAINT_SYMMETRIC:
                gcs_cons[i].type = GCS_SYMMETRIC;
                break;
            case CAD_CONSTRAINT_ANGLE:
                gcs_cons[i].type = GCS_ANGLE;
                break;
            case CAD_CONSTRAINT_RADIUS:
                gcs_cons[i].type = GCS_RADIUS;
                break;
        }
    }
    return gcs_cons;
}

CadDifferentialFuzzer::CadDifferentialFuzzer(uint64_t seed)
    : rng_(seed),
      dim_dist_(0.5f, 100.0f),
      sketch_coord_dist_(5.0, 50.0),
      noise_dist_(-0.5, 0.5) {}

FuzzCadOperation CadDifferentialFuzzer::generateRandomOp() {
    FuzzCadOperation op{};
    std::uniform_int_distribution<int> op_kind_dist(0, 2);
    int kind = op_kind_dist(rng_);

    if (kind == 0) {
        op.kind = FuzzOpKind::CreateBox;
        op.params[0] = dim_dist_(rng_); // dx
        op.params[1] = dim_dist_(rng_); // dy
        op.params[2] = dim_dist_(rng_); // dz
    } else if (kind == 1) {
        op.kind = FuzzOpKind::CreateCylinder;
        op.params[0] = dim_dist_(rng_); // radius
        op.params[1] = dim_dist_(rng_); // height
    } else {
        op.kind = FuzzOpKind::CreateExtrusion;
        op.profile_point_count = 4;
        float w = dim_dist_(rng_);
        float h = dim_dist_(rng_);
        op.profile_points = {0.0f, 0.0f, w, 0.0f, w, h, 0.0f, h};
        op.params[0] = 0.0f;
        op.params[1] = 0.0f;
        op.params[2] = dim_dist_(rng_); // extrusion Z
    }

    return op;
}

std::vector<FuzzCadOperation> CadDifferentialFuzzer::generateSequence(size_t length) {
    std::vector<FuzzCadOperation> seq;
    seq.reserve(length);
    for (size_t i = 0; i < length; ++i) {
        seq.push_back(generateRandomOp());
    }
    return seq;
}

FuzzSketchConfiguration CadDifferentialFuzzer::generateTriangleSketch() {
    FuzzSketchConfiguration config{};
    double a = sketch_coord_dist_(rng_);
    double b = sketch_coord_dist_(rng_);
    double c = std::sqrt(a * a + b * b);

    // Ground truth: P0(0,0), P1(a,0), P2(a,b)
    config.points = {
        {0, 0.0, 0.0, 1},                      // Fixed origin
        {1, a + noise_dist_(rng_), noise_dist_(rng_), 0}, // P1 perturbed
        {2, a + noise_dist_(rng_), b + noise_dist_(rng_), 0}  // P2 perturbed
    };

    config.lines = {
        {0, 0, 1},
        {1, 1, 2},
        {2, 2, 0}
    };

    config.constraints = {
        {1, CAD_CONSTRAINT_DISTANCE, 0, 1, CAD_SKETCH_INVALID_ID, CAD_SKETCH_INVALID_ID, a, 1},
        {2, CAD_CONSTRAINT_DISTANCE, 1, 2, CAD_SKETCH_INVALID_ID, CAD_SKETCH_INVALID_ID, b, 1},
        {3, CAD_CONSTRAINT_DISTANCE, 2, 0, CAD_SKETCH_INVALID_ID, CAD_SKETCH_INVALID_ID, c, 1},
        {4, CAD_CONSTRAINT_HORIZONTAL, 0, 1, CAD_SKETCH_INVALID_ID, CAD_SKETCH_INVALID_ID, 0.0, 1}
    };

    return config;
}

FuzzSketchConfiguration CadDifferentialFuzzer::generateTangentSlotSketch() {
    FuzzSketchConfiguration config{};
    double L = sketch_coord_dist_(rng_);
    double R = 5.0 + 0.2 * sketch_coord_dist_(rng_);

    // Points:
    // C1: Center 1 (0, 0) - fixed
    // C2: Center 2 (L, 0)
    // P1: Top Left (0, R)
    // P2: Top Right (L, R)
    // P3: Bottom Left (0, -R)
    // P4: Bottom Right (L, -R)
    config.points = {
        {0, 0.0, 0.0, 1},                               // C1
        {1, L + noise_dist_(rng_), noise_dist_(rng_), 0}, // C2
        {2, noise_dist_(rng_), R + noise_dist_(rng_), 0}, // P1
        {3, L + noise_dist_(rng_), R + noise_dist_(rng_), 0}, // P2
        {4, noise_dist_(rng_), -R + noise_dist_(rng_), 0}, // P3
        {5, L + noise_dist_(rng_), -R + noise_dist_(rng_), 0} // P4
    };

    config.lines = {
        {0, 2, 3}, // Top Line: P1 -> P2
        {1, 4, 5}  // Bottom Line: P3 -> P4
    };

    config.arcs = {
        {0, 0, 2, 4, R}, // Arc 1 at C1 from P1 to P3
        {1, 1, 5, 3, R}  // Arc 2 at C2 from P4 to P2
    };

    config.constraints = {
        {1, CAD_CONSTRAINT_HORIZONTAL, 0, 1, CAD_SKETCH_INVALID_ID, CAD_SKETCH_INVALID_ID, 0.0, 1},
        {2, CAD_CONSTRAINT_DISTANCE, 0, 1, CAD_SKETCH_INVALID_ID, CAD_SKETCH_INVALID_ID, L, 1},
        {3, CAD_CONSTRAINT_PARALLEL, 0, 1, CAD_SKETCH_INVALID_ID, CAD_SKETCH_INVALID_ID, 0.0, 1},
        {4, CAD_CONSTRAINT_TANGENT, 0, 0, CAD_SKETCH_INVALID_ID, CAD_SKETCH_INVALID_ID, R, 1},
        {5, CAD_CONSTRAINT_TANGENT, 1, 0, CAD_SKETCH_INVALID_ID, CAD_SKETCH_INVALID_ID, R, 1},
        {6, CAD_CONSTRAINT_TANGENT, 0, 1, CAD_SKETCH_INVALID_ID, CAD_SKETCH_INVALID_ID, R, 1},
        {7, CAD_CONSTRAINT_TANGENT, 1, 1, CAD_SKETCH_INVALID_ID, CAD_SKETCH_INVALID_ID, R, 1},
        {8, CAD_CONSTRAINT_VERTICAL, 0, 2, CAD_SKETCH_INVALID_ID, CAD_SKETCH_INVALID_ID, 0.0, 1},
        {9, CAD_CONSTRAINT_VERTICAL, 0, 4, CAD_SKETCH_INVALID_ID, CAD_SKETCH_INVALID_ID, 0.0, 1},
        {10, CAD_CONSTRAINT_VERTICAL, 1, 3, CAD_SKETCH_INVALID_ID, CAD_SKETCH_INVALID_ID, 0.0, 1},
        {11, CAD_CONSTRAINT_VERTICAL, 1, 5, CAD_SKETCH_INVALID_ID, CAD_SKETCH_INVALID_ID, 0.0, 1}
    };

    return config;
}

FuzzSketchConfiguration CadDifferentialFuzzer::generateConcentricFlangesSketch() {
    FuzzSketchConfiguration config{};
    double R1 = 5.0 + 0.1 * sketch_coord_dist_(rng_);
    double R2 = R1 + 10.0 + 0.2 * sketch_coord_dist_(rng_);

    config.points = {
        {0, 0.0, 0.0, 1}, // Common center (fixed)
        {1, R1 + noise_dist_(rng_), noise_dist_(rng_), 0}, // Radius 1 point
        {2, noise_dist_(rng_), R2 + noise_dist_(rng_), 0}  // Radius 2 point
    };

    config.circles = {
        {0, 0, R1},
        {1, 0, R2}
    };

    config.constraints = {
        {1, CAD_CONSTRAINT_RADIUS, 0, 1, CAD_SKETCH_INVALID_ID, CAD_SKETCH_INVALID_ID, R1, 1},
        {2, CAD_CONSTRAINT_RADIUS, 1, 2, CAD_SKETCH_INVALID_ID, CAD_SKETCH_INVALID_ID, R2, 1}
    };

    return config;
}

FuzzSketchConfiguration CadDifferentialFuzzer::generateSymmetricBracketSketch() {
    FuzzSketchConfiguration config{};
    double w = 10.0 + 0.2 * sketch_coord_dist_(rng_);
    double h = 15.0 + 0.3 * sketch_coord_dist_(rng_);

    // Axis line: (0, -30) to (0, 30) (fixed)
    // Points:
    // P0: Axis start (0, -30) fixed
    // P1: Axis end (0, 30) fixed
    // P2: (-w, -h)
    // P3: (w, -h)
    // P4: (-w, h)
    // P5: (w, h)
    config.points = {
        {0, 0.0, -30.0, 1},
        {1, 0.0, 30.0, 1},
        {2, -w + noise_dist_(rng_), -h + noise_dist_(rng_), 0},
        {3, w + noise_dist_(rng_), -h + noise_dist_(rng_), 0},
        {4, -w + noise_dist_(rng_), h + noise_dist_(rng_), 0},
        {5, w + noise_dist_(rng_), h + noise_dist_(rng_), 0}
    };

    config.lines = {
        {0, 0, 1}, // Centerline axis
        {1, 2, 3}, // Bottom line
        {2, 4, 5}, // Top line
        {3, 2, 4}, // Left line
        {4, 3, 5}  // Right line
    };

    config.constraints = {
        {1, CAD_CONSTRAINT_SYMMETRIC, 2, 3, 0, CAD_SKETCH_INVALID_ID, 0.0, 1},
        {2, CAD_CONSTRAINT_SYMMETRIC, 4, 5, 0, CAD_SKETCH_INVALID_ID, 0.0, 1},
        {3, CAD_CONSTRAINT_DISTANCE, 2, 3, CAD_SKETCH_INVALID_ID, CAD_SKETCH_INVALID_ID, 2.0 * w, 1},
        {4, CAD_CONSTRAINT_DISTANCE, 2, 4, CAD_SKETCH_INVALID_ID, CAD_SKETCH_INVALID_ID, 2.0 * h, 1},
        {5, CAD_CONSTRAINT_HORIZONTAL, 2, 3, CAD_SKETCH_INVALID_ID, CAD_SKETCH_INVALID_ID, 0.0, 1}
    };

    return config;
}

FuzzSketchConfiguration CadDifferentialFuzzer::generateUnderConstrainedSketch() {
    FuzzSketchConfiguration config{};
    config.points = {
        {0, 0.0, 0.0, 1},
        {1, 10.0 + noise_dist_(rng_), 0.0 + noise_dist_(rng_), 0},
        {2, 10.0 + noise_dist_(rng_), 10.0 + noise_dist_(rng_), 0},
        {3, 0.0 + noise_dist_(rng_), 10.0 + noise_dist_(rng_), 0}
    };

    config.lines = {
        {0, 0, 1},
        {1, 1, 2},
        {2, 2, 3},
        {3, 3, 0}
    };

    // Only 2 constraints for 6 free variables -> remaining DOF > 0
    config.constraints = {
        {1, CAD_CONSTRAINT_DISTANCE, 0, 1, CAD_SKETCH_INVALID_ID, CAD_SKETCH_INVALID_ID, 10.0, 1},
        {2, CAD_CONSTRAINT_HORIZONTAL, 0, 1, CAD_SKETCH_INVALID_ID, CAD_SKETCH_INVALID_ID, 0.0, 1}
    };

    return config;
}

FuzzSketchConfiguration CadDifferentialFuzzer::generateOverConstrainedSketch() {
    FuzzSketchConfiguration config{};
    config.points = {
        {0, 0.0, 0.0, 1},
        {1, 10.0 + noise_dist_(rng_), noise_dist_(rng_), 0}
    };

    config.lines = {
        {0, 0, 1}
    };

    // 2 free variables (x1, y1), 3 consistent equations:
    // y1 = 0 (Horizontal)
    // (x1-0)^2 + y1^2 = 100 (Distance 10)
    // Redundant distance 10
    config.constraints = {
        {1, CAD_CONSTRAINT_HORIZONTAL, 0, 1, CAD_SKETCH_INVALID_ID, CAD_SKETCH_INVALID_ID, 0.0, 1},
        {2, CAD_CONSTRAINT_DISTANCE, 0, 1, CAD_SKETCH_INVALID_ID, CAD_SKETCH_INVALID_ID, 10.0, 1},
        {3, CAD_CONSTRAINT_DISTANCE, 0, 1, CAD_SKETCH_INVALID_ID, CAD_SKETCH_INVALID_ID, 10.0, 1}
    };

    return config;
}

FuzzSketchConfiguration CadDifferentialFuzzer::generateConflictingSketch() {
    FuzzSketchConfiguration config{};
    config.points = {
        {0, 0.0, 0.0, 1},
        {1, 8.0, 0.0, 0}
    };

    config.lines = {
        {0, 0, 1}
    };

    // Conflicting: distance must be 10 AND 5
    config.constraints = {
        {1, CAD_CONSTRAINT_HORIZONTAL, 0, 1, CAD_SKETCH_INVALID_ID, CAD_SKETCH_INVALID_ID, 0.0, 1},
        {2, CAD_CONSTRAINT_DISTANCE, 0, 1, CAD_SKETCH_INVALID_ID, CAD_SKETCH_INVALID_ID, 10.0, 1},
        {3, CAD_CONSTRAINT_DISTANCE, 0, 1, CAD_SKETCH_INVALID_ID, CAD_SKETCH_INVALID_ID, 5.0, 1}
    };

    return config;
}

FuzzSketchConfiguration CadDifferentialFuzzer::generateRandomSketch(uint32_t point_count) {
    if (point_count < 3) point_count = 3;
    FuzzSketchConfiguration config{};
    config.points.resize(point_count);

    // Generate ground truth points on a circle/polygon
    double radius = sketch_coord_dist_(rng_);
    std::vector<double> angles(point_count);
    for (uint32_t i = 0; i < point_count; ++i) {
        angles[i] = 2.0 * M_PI * static_cast<double>(i) / static_cast<double>(point_count);
        double gx = radius * std::cos(angles[i]);
        double gy = radius * std::sin(angles[i]);
        config.points[i].id = i;
        config.points[i].is_fixed = (i == 0) ? 1 : 0;
        config.points[i].x = gx + ((i > 0) ? noise_dist_(rng_) : 0.0);
        config.points[i].y = gy + ((i > 0) ? noise_dist_(rng_) : 0.0);
    }

    config.lines.resize(point_count);
    config.constraints.reserve(point_count + 1);

    for (uint32_t i = 0; i < point_count; ++i) {
        uint32_t next = (i + 1) % point_count;
        config.lines[i] = {i, i, next};
        double gx1 = radius * std::cos(angles[i]);
        double gy1 = radius * std::sin(angles[i]);
        double gx2 = radius * std::cos(angles[next]);
        double gy2 = radius * std::sin(angles[next]);
        double true_len = std::sqrt((gx2 - gx1) * (gx2 - gx1) + (gy2 - gy1) * (gy2 - gy1));

        config.constraints.push_back({
            i + 1,
            CAD_CONSTRAINT_DISTANCE,
            i,
            next,
            CAD_SKETCH_INVALID_ID,
            CAD_SKETCH_INVALID_ID,
            true_len,
            1
        });
    }

    // Add orientation lock: angle between line 0 and line 1
    double gx0 = radius * std::cos(angles[0]);
    double gy0 = radius * std::sin(angles[0]);
    double gx1 = radius * std::cos(angles[1]);
    double gy1 = radius * std::sin(angles[1]);
    double target_angle = std::atan2(gy1 - gy0, gx1 - gx0);
    config.constraints.push_back({
        point_count + 1,
        CAD_CONSTRAINT_HORIZONTAL,
        0,
        1,
        CAD_SKETCH_INVALID_ID,
        CAD_SKETCH_INVALID_ID,
        target_angle,
        1
    });

    return config;
}
