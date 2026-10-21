/**
 * Definition of the flat memory layout matching cad_kernel.h.
 *
 * All geometry data is represented as contiguous flat typed arrays suitable
 * for direct mapping into WebAssembly Linear Memory or transferable ArrayBuffers:
 * - positions: Float32Array (x, y, z triplets per vertex)
 * - normals: Float32Array (nx, ny, nz triplets per vertex)
 * - indices: Uint32Array (i0, i1, i2 triplets per triangle)
 * - triangle_to_face_id: Uint32Array (1 face ID per triangle, length = triangle_count)
 * - edge_line_vertices: Float32Array (x0, y0, z0, x1, y1, z1 per line segment)
 * - edge_ids: Uint32Array (1 edge ID per line segment, length = edge_count)
 */

export interface CadKernelMeshLayout {
  positions: Float32Array;
  normals: Float32Array;
  indices: Uint32Array;
  triangle_to_face_id: Uint32Array;
  edge_line_vertices: Float32Array;
  edge_ids: Uint32Array;
}
