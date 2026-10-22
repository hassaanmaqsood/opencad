export interface CadWasmMemoryBuffers {
  positions: Float32Array;
  normals: Float32Array;
  indices: Uint32Array;
  triangleToFaceId?: BigUint64Array | Uint32Array;
  edgePolylines?: Float32Array;
  edgeToTopoId?: BigUint64Array | Uint32Array;
}

export interface SheetMetalBendResult {
  bendAllowance: number;
  bendDeduction: number;
}

export interface FeaMeshResult {
  nodeCount: number;
  elementCount: number;
}

export interface ImplicitTpmsResult {
  nodalValue: number;
}
