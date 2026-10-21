#ifndef COMPARATOR_HPP
#define COMPARATOR_HPP

#include "cad_kernel.h"
#include <string>
#include <vector>

struct DifferentialDiffResult {
    bool passed;
    std::string failure_reason;
    float volume_difference_percent;
    float surface_area_difference_percent;
    float max_hausdorff_distance;
    int euler_char_actual;
    int euler_char_expected;
    uint32_t face_count_delta;
    uint32_t edge_count_delta;
};

class CadDifferentialComparator {
public:
    static DifferentialDiffResult compareSolids(
        cad_solid_handle_t solid_oracle,
        cad_solid_handle_t solid_candidate,
        float tolerance = 1e-3f
    );

    static DifferentialDiffResult compareMeshes(
        const cad_mesh_t* mesh_oracle,
        const cad_mesh_t* mesh_candidate,
        float tolerance = 1e-2f
    );
};

#endif /* COMPARATOR_HPP */
