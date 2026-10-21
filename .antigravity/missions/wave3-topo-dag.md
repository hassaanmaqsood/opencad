# Mission Playbook: Wave 3 — SoA Half-Edge B-Rep, Feature DAG & Persistent Topological Naming

## Objective
Transition internal B-Rep representations from object-graph pointers to a high-density Struct-of-Arrays (SoA) Half-Edge topological store, integrate a persistent Parametric Feature Tree DAG with dependency invalidation, and implement a deterministic Topological Naming resolver.

## Responsible Agents
- **`zig-brep-topo`**: Develops SoA Half-Edge arrays (`vertices`, `half_edges`, `edges`, `loops`, `faces`, `shells`, `solids`), Feature DAG evaluator, and Persistent Naming UUID tracker in `kernel-zig/src/topo/`.
- **`zig-tess-wasm`**: Updates tessellator to emit `triangle_to_face_id` and `segment_to_edge_id` arrays directly from SoA indices.
- **`oracle-fuzzer-qa`**: Validates Euler-Poincaré invariants across multi-feature parametric edits ($V - E + F - (L - F) - 2(S - G) = 0$).
- **`threejs-ui-worker`**: Implements the SolidWorks-style Feature Tree UI, Rollback Bar, and sub-shape selection highlighting linked to the Persistent Naming table.

## Architectural Requirements
1. **Struct-of-Arrays (SoA) Memory Layout**:
   - Cache-friendly linear indexing: `half_edges.origin[i]`, `half_edges.twin[i]`, `half_edges.next[i]`, `half_edges.face[i]`.
   - Index-based handles (`u32`) instead of 64-bit pointers, enabling instant serialization-free WASM linear memory mapping.
2. **Persistent Topological Naming Engine**:
   - Deterministic topological tag generation combining `FeatureID`, `GenerationIndex`, and `OrientationCode`.
   - Heuristic shape graph matching across re-evaluations to resolve upstream sketch edits without destroying downstream fillets or chamfers.
3. **Verification Gate**:
   - `verify-zig-wasm` verifying zero leaks during re-evaluation and rollbacks.
   - 20-step parametric history fuzzing test verifying topological naming stability.
