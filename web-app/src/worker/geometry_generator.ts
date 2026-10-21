import { BoxParams, CadMeshRawBuffers, CylinderParams } from '../types/cad';

/**
 * Generates a Box solid with flat buffers conforming to cad_kernel.h.
 *
 * Topological structure:
 * - 6 planar faces:
 *   Face 1: +X (Right)
 *   Face 2: -X (Left)
 *   Face 3: +Y (Top)
 *   Face 4: -Y (Bottom)
 *   Face 5: +Z (Front)
 *   Face 6: -Z (Back)
 * - 24 vertices (4 per face for sharp orthogonal normal vectors)
 * - 12 triangles (2 per face)
 * - 12 sharp edges (1 line segment per edge)
 */
export function generateBoxBuffers(params: BoxParams): CadMeshRawBuffers {
  const { width, height, depth } = params;
  const hx = width / 2;
  const hy = height / 2;
  const hz = depth / 2;

  // 6 faces * 4 vertices = 24 vertices.
  // Each vertex: 3 floats (x, y, z)
  const positions = new Float32Array(24 * 3);
  const normals = new Float32Array(24 * 3);
  // 6 faces * 2 triangles = 12 triangles.
  // Each triangle: 3 indices
  const indices = new Uint32Array(12 * 3);
  // 12 triangles -> 12 face IDs
  const triangleToFaceId = new Uint32Array(12);

  interface FaceDef {
    id: number;
    normal: [number, number, number];
    vertices: [number, number, number][];
  }

  const faces: FaceDef[] = [
    // Face 1: +X (Right)
    {
      id: 1,
      normal: [1, 0, 0],
      vertices: [
        [hx, -hy, -hz],
        [hx, hy, -hz],
        [hx, hy, hz],
        [hx, -hy, hz],
      ],
    },
    // Face 2: -X (Left)
    {
      id: 2,
      normal: [-1, 0, 0],
      vertices: [
        [-hx, -hy, hz],
        [-hx, hy, hz],
        [-hx, hy, -hz],
        [-hx, -hy, -hz],
      ],
    },
    // Face 3: +Y (Top)
    {
      id: 3,
      normal: [0, 1, 0],
      vertices: [
        [-hx, hy, -hz],
        [hx, hy, -hz],
        [hx, hy, hz],
        [-hx, hy, hz],
      ],
    },
    // Face 4: -Y (Bottom)
    {
      id: 4,
      normal: [0, -1, 0],
      vertices: [
        [-hx, -hy, hz],
        [hx, -hy, hz],
        [hx, -hy, -hz],
        [-hx, -hy, -hz],
      ],
    },
    // Face 5: +Z (Front)
    {
      id: 5,
      normal: [0, 0, 1],
      vertices: [
        [-hx, -hy, hz],
        [hx, -hy, hz],
        [hx, hy, hz],
        [-hx, hy, hz],
      ],
    },
    // Face 6: -Z (Back)
    {
      id: 6,
      normal: [0, 0, -1],
      vertices: [
        [hx, -hy, -hz],
        [-hx, -hy, -hz],
        [-hx, hy, -hz],
        [hx, hy, -hz],
      ],
    },
  ];

  let vOffset = 0;
  let iOffset = 0;
  let triOffset = 0;

  for (const face of faces) {
    const baseVertexIndex = vOffset / 3;

    for (let i = 0; i < 4; i++) {
      const v = face.vertices[i];
      positions[vOffset] = v[0];
      positions[vOffset + 1] = v[1];
      positions[vOffset + 2] = v[2];

      normals[vOffset] = face.normal[0];
      normals[vOffset + 1] = face.normal[1];
      normals[vOffset + 2] = face.normal[2];

      vOffset += 3;
    }

    // Two triangles per quad: (0, 1, 2) and (0, 2, 3)
    indices[iOffset++] = baseVertexIndex + 0;
    indices[iOffset++] = baseVertexIndex + 1;
    indices[iOffset++] = baseVertexIndex + 2;
    triangleToFaceId[triOffset++] = face.id;

    indices[iOffset++] = baseVertexIndex + 0;
    indices[iOffset++] = baseVertexIndex + 2;
    indices[iOffset++] = baseVertexIndex + 3;
    triangleToFaceId[triOffset++] = face.id;
  }

  // 12 Sharp Edges:
  // Each edge has 2 endpoints: 6 floats
  const edgeLineVertices = new Float32Array(12 * 6);
  const edgeIds = new Uint32Array(12);

  const corners: [number, number, number][] = [
    [-hx, -hy, -hz], // 0
    [hx, -hy, -hz],  // 1
    [hx, -hy, hz],   // 2
    [-hx, -hy, hz],  // 3
    [-hx, hy, -hz],  // 4
    [hx, hy, -hz],   // 5
    [hx, hy, hz],    // 6
    [-hx, hy, hz],   // 7
  ];

  // 12 edges
  const edgePairs: [number, number][] = [
    // Bottom 4 edges (1..4)
    [0, 1],
    [1, 2],
    [2, 3],
    [3, 0],
    // Top 4 edges (5..8)
    [4, 5],
    [5, 6],
    [6, 7],
    [7, 4],
    // Vertical 4 edges (9..12)
    [0, 4],
    [1, 5],
    [2, 6],
    [3, 7],
  ];

  for (let e = 0; e < 12; e++) {
    const [c1, c2] = edgePairs[e];
    const p1 = corners[c1];
    const p2 = corners[c2];

    const idx = e * 6;
    edgeLineVertices[idx + 0] = p1[0];
    edgeLineVertices[idx + 1] = p1[1];
    edgeLineVertices[idx + 2] = p1[2];
    edgeLineVertices[idx + 3] = p2[0];
    edgeLineVertices[idx + 4] = p2[1];
    edgeLineVertices[idx + 5] = p2[2];

    edgeIds[e] = e + 1;
  }

  return {
    positions,
    normals,
    indices,
    triangleToFaceId,
    edgeVertices: edgeLineVertices,
    edgeIds,
    metadata: {
      solidType: 'box',
      vertexCount: 24,
      triangleCount: 12,
      edgeCount: 12,
      faceCount: 6,
      generatedAt: performance.now(),
    },
  };
}

/**
 * Generates a Cylinder solid with flat buffers conforming to cad_kernel.h.
 *
 * Topological structure:
 * - 3 faces:
 *   Face 1: Top circular face (normal +Y)
 *   Face 2: Bottom circular face (normal -Y)
 *   Face 3: Lateral cylindrical surface
 * - Sharp edges:
 *   Edge 1: Top rim circle
 *   Edge 2: Bottom rim circle
 */
export function generateCylinderBuffers(params: CylinderParams): CadMeshRawBuffers {
  const { radius, height, radialSegments = 32 } = params;
  const segments = Math.max(8, radialSegments);
  const hy = height / 2;

  // Triangles:
  // Top cap: segments triangles
  // Bottom cap: segments triangles
  // Side: 2 * segments triangles
  const totalTriangles = 4 * segments;

  // Vertices:
  // Top cap: (segments + 1) vertices (center + perimeter)
  // Bottom cap: (segments + 1) vertices (center + perimeter)
  // Side: 2 * (segments + 1) vertices
  const topVertCount = segments + 1;
  const botVertCount = segments + 1;
  const sideVertCount = 2 * (segments + 1);
  const totalVertices = topVertCount + botVertCount + sideVertCount;

  const positions = new Float32Array(totalVertices * 3);
  const normals = new Float32Array(totalVertices * 3);
  const indices = new Uint32Array(totalTriangles * 3);
  const triangleToFaceId = new Uint32Array(totalTriangles);

  let vIdx = 0;
  let iIdx = 0;
  let triIdx = 0;

  // 1. Top Face (Face 1: normal [0, 1, 0])
  const topCenterIndex = vIdx / 3;
  positions[vIdx + 0] = 0;
  positions[vIdx + 1] = hy;
  positions[vIdx + 2] = 0;
  normals[vIdx + 0] = 0;
  normals[vIdx + 1] = 1;
  normals[vIdx + 2] = 0;
  vIdx += 3;

  const topRimStart = vIdx / 3;
  for (let s = 0; s < segments; s++) {
    const theta = (s / segments) * Math.PI * 2;
    const x = radius * Math.cos(theta);
    const z = radius * Math.sin(theta);

    positions[vIdx + 0] = x;
    positions[vIdx + 1] = hy;
    positions[vIdx + 2] = z;
    normals[vIdx + 0] = 0;
    normals[vIdx + 1] = 1;
    normals[vIdx + 2] = 0;
    vIdx += 3;
  }

  for (let s = 0; s < segments; s++) {
    const nextS = (s + 1) % segments;
    indices[iIdx++] = topCenterIndex;
    indices[iIdx++] = topRimStart + s;
    indices[iIdx++] = topRimStart + nextS;
    triangleToFaceId[triIdx++] = 1; // Face 1: Top
  }

  // 2. Bottom Face (Face 2: normal [0, -1, 0])
  const botCenterIndex = vIdx / 3;
  positions[vIdx + 0] = 0;
  positions[vIdx + 1] = -hy;
  positions[vIdx + 2] = 0;
  normals[vIdx + 0] = 0;
  normals[vIdx + 1] = -1;
  normals[vIdx + 2] = 0;
  vIdx += 3;

  const botRimStart = vIdx / 3;
  for (let s = 0; s < segments; s++) {
    const theta = (s / segments) * Math.PI * 2;
    const x = radius * Math.cos(theta);
    const z = radius * Math.sin(theta);

    positions[vIdx + 0] = x;
    positions[vIdx + 1] = -hy;
    positions[vIdx + 2] = z;
    normals[vIdx + 0] = 0;
    normals[vIdx + 1] = -1;
    normals[vIdx + 2] = 0;
    vIdx += 3;
  }

  for (let s = 0; s < segments; s++) {
    const nextS = (s + 1) % segments;
    // Winding clockwise from top = counterclockwise from bottom
    indices[iIdx++] = botCenterIndex;
    indices[iIdx++] = botRimStart + nextS;
    indices[iIdx++] = botRimStart + s;
    triangleToFaceId[triIdx++] = 2; // Face 2: Bottom
  }

  // 3. Lateral Side (Face 3)
  const sideStart = vIdx / 3;
  for (let s = 0; s <= segments; s++) {
    const theta = (s / segments) * Math.PI * 2;
    const nx = Math.cos(theta);
    const nz = Math.sin(theta);
    const x = radius * nx;
    const z = radius * nz;

    // Top point on side
    positions[vIdx + 0] = x;
    positions[vIdx + 1] = hy;
    positions[vIdx + 2] = z;
    normals[vIdx + 0] = nx;
    normals[vIdx + 1] = 0;
    normals[vIdx + 2] = nz;
    vIdx += 3;

    // Bottom point on side
    positions[vIdx + 0] = x;
    positions[vIdx + 1] = -hy;
    positions[vIdx + 2] = z;
    normals[vIdx + 0] = nx;
    normals[vIdx + 1] = 0;
    normals[vIdx + 2] = nz;
    vIdx += 3;
  }

  for (let s = 0; s < segments; s++) {
    const v0 = sideStart + s * 2;
    const v1 = v0 + 1;
    const v2 = sideStart + (s + 1) * 2;
    const v3 = v2 + 1;

    // Tri 1: v0, v1, v2
    indices[iIdx++] = v0;
    indices[iIdx++] = v1;
    indices[iIdx++] = v2;
    triangleToFaceId[triIdx++] = 3; // Face 3: Side

    // Tri 2: v2, v1, v3
    indices[iIdx++] = v2;
    indices[iIdx++] = v1;
    indices[iIdx++] = v3;
    triangleToFaceId[triIdx++] = 3; // Face 3: Side
  }

  // Edges: Top rim (Edge ID 1) and Bottom rim (Edge ID 2)
  // Each has `segments` line segments
  const totalEdgeSegments = segments * 2;
  const edgeLineVertices = new Float32Array(totalEdgeSegments * 6);
  const edgeIds = new Uint32Array(totalEdgeSegments);

  let eIdx = 0;
  // Top rim
  for (let s = 0; s < segments; s++) {
    const theta1 = (s / segments) * Math.PI * 2;
    const theta2 = ((s + 1) / segments) * Math.PI * 2;

    const x1 = radius * Math.cos(theta1);
    const z1 = radius * Math.sin(theta1);
    const x2 = radius * Math.cos(theta2);
    const z2 = radius * Math.sin(theta2);

    edgeLineVertices[eIdx + 0] = x1;
    edgeLineVertices[eIdx + 1] = hy;
    edgeLineVertices[eIdx + 2] = z1;
    edgeLineVertices[eIdx + 3] = x2;
    edgeLineVertices[eIdx + 4] = hy;
    edgeLineVertices[eIdx + 5] = z2;

    edgeIds[s] = 1; // Top rim edge ID 1
    eIdx += 6;
  }

  // Bottom rim
  for (let s = 0; s < segments; s++) {
    const theta1 = (s / segments) * Math.PI * 2;
    const theta2 = ((s + 1) / segments) * Math.PI * 2;

    const x1 = radius * Math.cos(theta1);
    const z1 = radius * Math.sin(theta1);
    const x2 = radius * Math.cos(theta2);
    const z2 = radius * Math.sin(theta2);

    edgeLineVertices[eIdx + 0] = x1;
    edgeLineVertices[eIdx + 1] = -hy;
    edgeLineVertices[eIdx + 2] = z1;
    edgeLineVertices[eIdx + 3] = x2;
    edgeLineVertices[eIdx + 4] = -hy;
    edgeLineVertices[eIdx + 5] = z2;

    edgeIds[segments + s] = 2; // Bottom rim edge ID 2
    eIdx += 6;
  }

  return {
    positions,
    normals,
    indices,
    triangleToFaceId,
    edgeVertices: edgeLineVertices,
    edgeIds,
    metadata: {
      solidType: 'cylinder',
      vertexCount: totalVertices,
      triangleCount: totalTriangles,
      edgeCount: totalEdgeSegments,
      faceCount: 3,
      generatedAt: performance.now(),
    },
  };
}
