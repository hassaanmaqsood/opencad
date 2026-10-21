#include "fuzzer.hpp"

CadDifferentialFuzzer::CadDifferentialFuzzer(uint64_t seed)
    : rng_(seed), dim_dist_(0.5f, 100.0f) {}

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
        // Simple rectangular closed wire
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
