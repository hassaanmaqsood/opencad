# Mission Playbook: Wave 5 — Rolling-Ball Fillets, Shells, 3D Assembly Mates & Instanced Viewport

## Objective
Implement advanced solid modeling operations (variable and constant radius rolling-ball fillets, shell hollowing, drafting) alongside a 3D multi-body assembly mating engine with hardware-accelerated instanced rendering.

## Responsible Agents
- **`zig-solver-math`**: Implements 3D assembly constraint solver (Coincident, Concentric, Parallel, Distance, Angle) and rolling-ball spine curve integration.
- **`zig-brep-topo`**: Implements face offset, edge blending, corner sphere transitions, and multi-body assembly DAG in `kernel-zig/src/ops/`.
- **`zig-tess-wasm`**: Implements multi-resolution Level-of-Detail (LOD) tessellation and spatial BVH generation.
- **`threejs-ui-worker`**: Implements `THREE.InstancedMesh` and `THREE.LOD` rendering for assemblies containing 1,000+ parts at 60 FPS, assembly tree UI, and mate manipulator gizmos.

## Architectural Requirements
1. **Rolling-Ball Filleting Engine**:
   - Spine curve calculation along shared topological edge boundaries.
   - Contact track curve evaluation on adjacent primary surfaces.
   - Blend surface generation with $G^1$ / $G^2$ continuity.
   - Multi-edge corner vertex patching with spherical / triangular transition surfaces.
2. **Assembly Constraint Engine**:
   - Rigid-body DOF transformation matrices (Euler angle / Quaternion parameterization).
   - Relative mate graph resolution.
3. **Verification Gate**:
   - Verification against OpenCASCADE `BRepFilletAPI_MakeFillet`.
   - Assembly rendering benchmark: 1,000 instances at $\ge 60$ FPS.
