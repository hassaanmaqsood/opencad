export type CadSolidType = 'box' | 'cylinder';

export interface BoxParams {
  width: number;
  height: number;
  depth: number;
}

export interface CylinderParams {
  radius: number;
  height: number;
  radialSegments?: number;
}

export type SolidGenerationRequest =
  | { solidType: 'box'; params: BoxParams }
  | { solidType: 'cylinder'; params: CylinderParams };

export interface CadMeshMetadata {
  solidType: string;
  vertexCount: number;
  triangleCount: number;
  edgeCount: number;
  faceCount: number;
  generatedAt: number;
}

export interface CadMeshTransferPayload {
  type: 'GEOMETRY_READY';
  requestId?: number;
  positions: ArrayBufferLike;
  normals: ArrayBufferLike;
  indices: ArrayBufferLike;
  triangleToFaceId: ArrayBufferLike;
  edgeVertices: ArrayBufferLike;
  edgeIds: ArrayBufferLike;
  metadata: CadMeshMetadata;
}

export interface CadMeshRawBuffers {
  positions: Float32Array;
  normals: Float32Array;
  indices: Uint32Array;
  triangleToFaceId: Uint32Array;
  edgeVertices: Float32Array;
  edgeIds: Uint32Array;
  metadata: CadMeshMetadata;
}

export type SubShapeSelection =
  | { type: 'none' }
  | {
      type: 'face';
      faceId: number;
      point: [number, number, number];
      normal?: [number, number, number];
      label?: string;
    }
  | {
      type: 'edge';
      edgeId: number;
      point: [number, number, number];
      label?: string;
    };
