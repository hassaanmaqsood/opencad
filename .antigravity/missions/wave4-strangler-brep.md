# Mission Playbook: Wave 4 — 24/7 Strangler-Fig Migration of Primitives, NURBS & Booleans

## Objective
Progressively migrate core CAD geometric modeling capabilities from C-ABI wrapped OpenCASCADE fallbacks to native Zig modules using the Strangler-Fig pattern, enabling pure WASM-native client-side execution.

## Responsible Agents
- **`zig-solver-math`**: Implements SIMD (`wasm_simd128`) accelerated Non-Uniform Rational B-Splines (NURBS) curve/surface evaluators, de Boor's algorithm, and surface-surface intersection (SSI) marching in `kernel-zig/src/geom/`.
- **`zig-brep-topo`**: Implements 3D constructive solid geometry (CSG) Boolean operations (Union, Difference, Intersection) using exact Shewchuk predicates and half-edge topological reconstruction in `kernel-zig/src/ops/`.
- **`cad-architect`**: Coordinates router switches in `kernel-zig/src/router.zig` and STEP ISO-10303-21 parser/serializer specification.
- **`oracle-fuzzer-qa`**: Executes continuous differential fuzzing against OpenCASCADE reference outputs for 500+ complex intersecting shapes, gating router promotion.

## Architectural Requirements
1. **Strangler-Fig Migration Matrix**:
   - Primitive Box: [Migrated to Native Zig]
   - Primitive Cylinder: [Migrated to Native Zig]
   - Primitive Sphere: [Target Wave 4]
   - Sketch Extrude: [Target Wave 4]
   - CSG Boolean Union: [Target Wave 4]
   - CSG Boolean Difference: [Target Wave 4]
   - CSG Boolean Intersection: [Target Wave 4]
2. **Tolerance & Exact Computation**:
   - Exact 2D/3D geometric predicates (Shewchuk orientation and incircle tests).
   - Adaptive precision floating-point arithmetic for coplanar and near-tangent Boolean intersections.
3. **Verification Gate**:
   - Differential deviation $\le 10^{-7}$ mm across all Boolean benchmark primitives.
   - Zero manifold violations or non-manifold edge leaks.
