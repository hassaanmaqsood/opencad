#ifndef FUZZER_HPP
#define FUZZER_HPP

#include "cad_kernel.h"
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

class CadDifferentialFuzzer {
public:
    explicit CadDifferentialFuzzer(uint64_t seed);
    FuzzCadOperation generateRandomOp();
    std::vector<FuzzCadOperation> generateSequence(size_t length);

private:
    std::mt19937_64 rng_;
    std::uniform_real_distribution<float> dim_dist_;
};

#endif /* FUZZER_HPP */
