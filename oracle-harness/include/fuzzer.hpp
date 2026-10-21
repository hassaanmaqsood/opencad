#ifndef FUZZER_HPP
#define FUZZER_HPP

#include "cad_kernel.h"
#include "planegcs_oracle.h"
#include <random>
#include <vector>

enum class FuzzOpKind {
    CreateBox,
    CreateCylinder,
    CreateExtrusion,
    ApplyBooleanUnion,
    ApplyBooleanDifference,
    ApplyBooleanIntersection
};

struct FuzzCadOperation {
    FuzzOpKind kind;
    float params[6];
    uint32_t profile_point_count;
    std::vector<float> profile_points;
};

struct FuzzSketchConfiguration {
    std::vector<cad_sketch_point2d_t> points;
    std::vector<cad_sketch_line2d_t> lines;
    std::vector<cad_sketch_arc2d_t> arcs;
    std::vector<cad_sketch_circle2d_t> circles;
    std::vector<cad_sketch_constraint_t> constraints;

    std::vector<gcs_point_t> toGcsPoints() const;
    std::vector<gcs_line_t> toGcsLines() const;
    std::vector<gcs_constraint_t> toGcsConstraints() const;
};

class CadDifferentialFuzzer {
public:
    explicit CadDifferentialFuzzer(uint64_t seed);

    // 3D Solids (Wave 1)
    FuzzCadOperation generateRandomOp();
    std::vector<FuzzCadOperation> generateSequence(size_t length);

    // 2D Sketch Constraints (Wave 2)
    FuzzSketchConfiguration generateRandomSketch(uint32_t point_count = 4);
    FuzzSketchConfiguration generateTriangleSketch();
    FuzzSketchConfiguration generateTangentSlotSketch();
    FuzzSketchConfiguration generateConcentricFlangesSketch();
    FuzzSketchConfiguration generateSymmetricBracketSketch();
    FuzzSketchConfiguration generateUnderConstrainedSketch();
    FuzzSketchConfiguration generateOverConstrainedSketch();
    FuzzSketchConfiguration generateConflictingSketch();

private:
    std::mt19937_64 rng_;
    std::uniform_real_distribution<float> dim_dist_;
    std::uniform_real_distribution<double> sketch_coord_dist_;
    std::uniform_real_distribution<double> noise_dist_;
};

#endif /* FUZZER_HPP */
