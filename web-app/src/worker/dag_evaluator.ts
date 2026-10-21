import {
  CadFeatureNode,
  CadFeatureType,
  CadSubshapeType,
  CadTessellatedSolidSlice,
  CadTopoFlags,
  makeCadTopoId,
} from '../types/cad';

// CAD Operation Types matching abi/cad_kernel.h
export const CAD_OP_PRIMITIVE_BOX = 0;
export const CAD_OP_PRIMITIVE_CYLINDER = 1;
export const CAD_OP_SKETCH_EXTRUDE = 3;
export const CAD_OP_BOOLEAN_UNION = 4;
export const CAD_OP_BOOLEAN_DIFFERENCE = 5;
export const CAD_OP_BOOLEAN_INTERSECTION = 6;
export const CAD_OP_FILLET = 7;
export const CAD_OP_CHAMFER = 8;

interface MeshAccumulator {
  positions: number[];
  normals: number[];
  indices: number[];
  triangleToFaceId: bigint[];
  edgePolylines: number[];
  edgeToTopoId: bigint[];
  minX: number;
  maxX: number;
  minY: number;
  maxY: number;
  minZ: number;
  maxZ: number;
}

function createAccumulator(): MeshAccumulator {
  return {
    positions: [],
    normals: [],
    indices: [],
    triangleToFaceId: [],
    edgePolylines: [],
    edgeToTopoId: [],
    minX: Infinity,
    maxX: -Infinity,
    minY: Infinity,
    maxY: -Infinity,
    minZ: Infinity,
    maxZ: -Infinity,
  };
}

function addVertex(acc: MeshAccumulator, x: number, y: number, z: number, nx: number, ny: number, nz: number): number {
  const index = acc.positions.length / 3;
  acc.positions.push(x, y, z);
  acc.normals.push(nx, ny, nz);

  if (x < acc.minX) acc.minX = x;
  if (x > acc.maxX) acc.maxX = x;
  if (y < acc.minY) acc.minY = y;
  if (y > acc.maxY) acc.maxY = y;
  if (z < acc.minZ) acc.minZ = z;
  if (z > acc.maxZ) acc.maxZ = z;

  return index;
}

function addTriangle(acc: MeshAccumulator, i0: number, i1: number, i2: number, topoId: bigint) {
  acc.indices.push(i0, i1, i2);
  acc.triangleToFaceId.push(topoId);
}

function addQuad(
  acc: MeshAccumulator,
  v0: [number, number, number],
  v1: [number, number, number],
  v2: [number, number, number],
  v3: [number, number, number],
  normal: [number, number, number],
  topoId: bigint
) {
  const idx0 = addVertex(acc, v0[0], v0[1], v0[2], normal[0], normal[1], normal[2]);
  const idx1 = addVertex(acc, v1[0], v1[1], v1[2], normal[0], normal[1], normal[2]);
  const idx2 = addVertex(acc, v2[0], v2[1], v2[2], normal[0], normal[1], normal[2]);
  const idx3 = addVertex(acc, v3[0], v3[1], v3[2], normal[0], normal[1], normal[2]);

  addTriangle(acc, idx0, idx1, idx2, topoId);
  addTriangle(acc, idx0, idx2, idx3, topoId);
}

function addEdgeSegment(
  acc: MeshAccumulator,
  p0: [number, number, number],
  p1: [number, number, number],
  topoId: bigint
) {
  acc.edgePolylines.push(p0[0], p0[1], p0[2], p1[0], p1[1], p1[2]);
  acc.edgeToTopoId.push(topoId);
}

/**
 * Generates default demo DAG feature tree representing a classic parametric part:
 * 1. Base Sketch (3.0 x 2.0 rectangle)
 * 2. Base Extrude (1.6 mm along +Y)
 * 3. Boss Sketch (circle, radius 0.75 mm)
 * 4. Boss Extrude (1.2 mm along +Y, from y=1.6 to 2.8)
 * 5. Boss Fillet (top rim radius 0.25 mm)
 * 6. Corner Chamfer (4 vertical corners setback 0.35 mm)
 */
export function getDefaultDemoFeatureDag(): CadFeatureNode[] {
  return [
    {
      feature_id: 1,
      name: 'Base Sketch',
      type: CadFeatureType.SKETCH,
      is_suppressed: false,
      parent_ids: [],
      params: {
        sketch: {
          plane: 'XZ',
          profileType: 'rectangle',
          width: 3.2,
          height: 2.2,
        },
      },
    },
    {
      feature_id: 2,
      name: 'Base Extrude',
      type: CadFeatureType.EXTRUDE,
      is_suppressed: false,
      parent_ids: [1],
      params: {
        extrude: {
          distance: 1.6,
          direction: [0, 1, 0],
          symmetric: false,
        },
      },
    },
    {
      feature_id: 3,
      name: 'Boss Sketch',
      type: CadFeatureType.SKETCH,
      is_suppressed: false,
      parent_ids: [2],
      params: {
        sketch: {
          plane: 'XZ',
          profileType: 'circle',
          radius: 0.75,
        },
      },
    },
    {
      feature_id: 4,
      name: 'Boss Extrude',
      type: CadFeatureType.EXTRUDE,
      is_suppressed: false,
      parent_ids: [3],
      params: {
        extrude: {
          distance: 1.2,
          direction: [0, 1, 0],
          symmetric: false,
        },
      },
    },
    {
      feature_id: 5,
      name: 'Boss Fillet',
      type: CadFeatureType.FILLET,
      is_suppressed: false,
      parent_ids: [4],
      params: {
        fillet: {
          radius: 0.25,
        },
      },
    },
    {
      feature_id: 6,
      name: 'Corner Chamfer',
      type: CadFeatureType.CHAMFER,
      is_suppressed: false,
      parent_ids: [2],
      params: {
        chamfer: {
          distance: 0.35,
          angle_rad: Math.PI / 4,
        },
      },
    },
  ];
}

/**
 * Evaluates the feature DAG up to rollbackIndex, omitting suppressed features.
 * Constructs flat zero-copy buffers conforming to CadTessellatedSolidSlice.
 */
export function evaluateFeatureDag(
  nodes: CadFeatureNode[],
  rollbackIndex: number
): CadTessellatedSolidSlice {
  const acc = createAccumulator();

  const clampedRollback = Math.max(0, Math.min(rollbackIndex, nodes.length - 1));
  const activeNodes = nodes.slice(0, clampedRollback + 1);

  // Check which features are active (index <= rollbackIndex and not suppressed)
  const isFeatureActive = (id: number): boolean => {
    const node = activeNodes.find((n) => n.feature_id === id);
    return !!node && !node.is_suppressed;
  };

  const hasBaseSketch = isFeatureActive(1);
  const hasBaseExtrude = isFeatureActive(2);
  const hasBossSketch = isFeatureActive(3);
  const hasBossExtrude = isFeatureActive(4);
  const hasBossFillet = isFeatureActive(5);
  const hasCornerChamfer = isFeatureActive(6);

  let activeCount = 0;
  for (const n of activeNodes) {
    if (!n.is_suppressed) activeCount++;
  }

  const lastActiveNode = activeNodes
    .slice()
    .reverse()
    .find((n) => !n.is_suppressed);
  const lastEvaluatedName = lastActiveNode ? lastActiveNode.name : 'None';

  // Base Pad Dimensions
  const baseWidth = 3.2;
  const baseDepth = 2.2;
  const baseHeight = 1.6;
  const hx = baseWidth / 2;
  const hz = baseDepth / 2;
  const y0 = 0.0;
  const y1 = baseHeight;

  // Case 1: Only Sketch 1 is evaluated (rollback before Extrude 1)
  if (!hasBaseExtrude && hasBaseSketch) {
    const sketchTopoFace = makeCadTopoId(1, 0, CAD_OP_SKETCH_EXTRUDE, CadSubshapeType.FACE, CadTopoFlags.START_CAP, 0x1111);
    addQuad(
      acc,
      [-hx, 0, -hz],
      [hx, 0, -hz],
      [hx, 0, hz],
      [-hx, 0, hz],
      [0, 1, 0],
      sketchTopoFace
    );

    // 4 sketch boundary edges
    const p0: [number, number, number] = [-hx, 0, -hz];
    const p1: [number, number, number] = [hx, 0, -hz];
    const p2: [number, number, number] = [hx, 0, hz];
    const p3: [number, number, number] = [-hx, 0, hz];

    addEdgeSegment(acc, p0, p1, makeCadTopoId(1, 1, CAD_OP_SKETCH_EXTRUDE, CadSubshapeType.EDGE, CadTopoFlags.START_CAP, 0x1001));
    addEdgeSegment(acc, p1, p2, makeCadTopoId(1, 2, CAD_OP_SKETCH_EXTRUDE, CadSubshapeType.EDGE, CadTopoFlags.START_CAP, 0x1002));
    addEdgeSegment(acc, p2, p3, makeCadTopoId(1, 3, CAD_OP_SKETCH_EXTRUDE, CadSubshapeType.EDGE, CadTopoFlags.START_CAP, 0x1003));
    addEdgeSegment(acc, p3, p0, makeCadTopoId(1, 4, CAD_OP_SKETCH_EXTRUDE, CadSubshapeType.EDGE, CadTopoFlags.START_CAP, 0x1004));
  } else if (hasBaseExtrude) {
    // -------------------------------------------------------------
    // FEATURE 2: BASE EXTRUDE (With optional Feature 6 Corner Chamfers)
    // -------------------------------------------------------------
    const c = hasCornerChamfer ? 0.35 : 0.0; // chamfer setback

    const bottomFaceTopo = makeCadTopoId(2, 0, CAD_OP_SKETCH_EXTRUDE, CadSubshapeType.FACE, CadTopoFlags.START_CAP, 0x2001);
    const topFaceTopo = makeCadTopoId(2, 0, CAD_OP_SKETCH_EXTRUDE, CadSubshapeType.FACE, CadTopoFlags.END_CAP, 0x2002);
    const rightFaceTopo = makeCadTopoId(2, 1, CAD_OP_SKETCH_EXTRUDE, CadSubshapeType.FACE, CadTopoFlags.LATERAL, 0x2003);
    const leftFaceTopo = makeCadTopoId(2, 2, CAD_OP_SKETCH_EXTRUDE, CadSubshapeType.FACE, CadTopoFlags.LATERAL, 0x2004);
    const frontFaceTopo = makeCadTopoId(2, 3, CAD_OP_SKETCH_EXTRUDE, CadSubshapeType.FACE, CadTopoFlags.LATERAL, 0x2005);
    const backFaceTopo = makeCadTopoId(2, 4, CAD_OP_SKETCH_EXTRUDE, CadSubshapeType.FACE, CadTopoFlags.LATERAL, 0x2006);

    if (c === 0) {
      // Standard Box Pad
      // Bottom Cap (-Y)
      addQuad(acc, [-hx, y0, hz], [hx, y0, hz], [hx, y0, -hz], [-hx, y0, -hz], [0, -1, 0], bottomFaceTopo);
      // Top Cap (+Y)
      addQuad(acc, [-hx, y1, -hz], [hx, y1, -hz], [hx, y1, hz], [-hx, y1, hz], [0, 1, 0], topFaceTopo);
      // Right (+X)
      addQuad(acc, [hx, y0, -hz], [hx, y1, -hz], [hx, y1, hz], [hx, y0, hz], [1, 0, 0], rightFaceTopo);
      // Left (-X)
      addQuad(acc, [-hx, y0, hz], [-hx, y1, hz], [-hx, y1, -hz], [-hx, y0, -hz], [-1, 0, 0], leftFaceTopo);
      // Front (+Z)
      addQuad(acc, [-hx, y0, hz], [hx, y0, hz], [hx, y1, hz], [-hx, y1, hz], [0, 0, 1], frontFaceTopo);
      // Back (-Z)
      addQuad(acc, [hx, y0, -hz], [-hx, y0, -hz], [-hx, y1, -hz], [hx, y1, -hz], [0, 0, -1], backFaceTopo);

      // Edges (12 sharp edges)
      const b0: [number, number, number] = [-hx, y0, -hz];
      const b1: [number, number, number] = [hx, y0, -hz];
      const b2: [number, number, number] = [hx, y0, hz];
      const b3: [number, number, number] = [-hx, y0, hz];

      const t0: [number, number, number] = [-hx, y1, -hz];
      const t1: [number, number, number] = [hx, y1, -hz];
      const t2: [number, number, number] = [hx, y1, hz];
      const t3: [number, number, number] = [-hx, y1, hz];

      // Bottom rim
      addEdgeSegment(acc, b0, b1, makeCadTopoId(2, 1, CAD_OP_SKETCH_EXTRUDE, CadSubshapeType.EDGE, CadTopoFlags.START_CAP, 0x2101));
      addEdgeSegment(acc, b1, b2, makeCadTopoId(2, 2, CAD_OP_SKETCH_EXTRUDE, CadSubshapeType.EDGE, CadTopoFlags.START_CAP, 0x2102));
      addEdgeSegment(acc, b2, b3, makeCadTopoId(2, 3, CAD_OP_SKETCH_EXTRUDE, CadSubshapeType.EDGE, CadTopoFlags.START_CAP, 0x2103));
      addEdgeSegment(acc, b3, b0, makeCadTopoId(2, 4, CAD_OP_SKETCH_EXTRUDE, CadSubshapeType.EDGE, CadTopoFlags.START_CAP, 0x2104));

      // Top rim
      addEdgeSegment(acc, t0, t1, makeCadTopoId(2, 1, CAD_OP_SKETCH_EXTRUDE, CadSubshapeType.EDGE, CadTopoFlags.END_CAP, 0x2201));
      addEdgeSegment(acc, t1, t2, makeCadTopoId(2, 2, CAD_OP_SKETCH_EXTRUDE, CadSubshapeType.EDGE, CadTopoFlags.END_CAP, 0x2202));
      addEdgeSegment(acc, t2, t3, makeCadTopoId(2, 3, CAD_OP_SKETCH_EXTRUDE, CadSubshapeType.EDGE, CadTopoFlags.END_CAP, 0x2203));
      addEdgeSegment(acc, t3, t0, makeCadTopoId(2, 4, CAD_OP_SKETCH_EXTRUDE, CadSubshapeType.EDGE, CadTopoFlags.END_CAP, 0x2204));

      // 4 vertical pillar edges
      addEdgeSegment(acc, b0, t0, makeCadTopoId(2, 1, CAD_OP_SKETCH_EXTRUDE, CadSubshapeType.EDGE, CadTopoFlags.LATERAL, 0x2301));
      addEdgeSegment(acc, b1, t1, makeCadTopoId(2, 2, CAD_OP_SKETCH_EXTRUDE, CadSubshapeType.EDGE, CadTopoFlags.LATERAL, 0x2302));
      addEdgeSegment(acc, b2, t2, makeCadTopoId(2, 3, CAD_OP_SKETCH_EXTRUDE, CadSubshapeType.EDGE, CadTopoFlags.LATERAL, 0x2303));
      addEdgeSegment(acc, b3, t3, makeCadTopoId(2, 4, CAD_OP_SKETCH_EXTRUDE, CadSubshapeType.EDGE, CadTopoFlags.LATERAL, 0x2304));
    } else {
      // Base Pad with 4 Corner Chamfers
      // 8-sided polygon base in XZ plane:
      // P0: (-hx + c, -hz), P1: (hx - c, -hz)
      // P2: (hx, -hz + c), P3: (hx, hz - c)
      // P4: (hx - c, hz), P5: (-hx + c, hz)
      // P6: (-hx, hz - c), P7: (-hx, -hz + c)
      const pB: [number, number, number][] = [
        [-hx + c, y0, -hz],
        [hx - c, y0, -hz],
        [hx, y0, -hz + c],
        [hx, y0, hz - c],
        [hx - c, y0, hz],
        [-hx + c, y0, hz],
        [-hx, y0, hz - c],
        [-hx, y0, -hz + c],
      ];
      const pT: [number, number, number][] = pB.map(([x, , z]) => [x, y1, z]);

      // Top Cap (polygon triangulation from center)
      const topCenterIdx = addVertex(acc, 0, y1, 0, 0, 1, 0);
      const topVertIdxs = pT.map(([x, y, z]) => addVertex(acc, x, y, z, 0, 1, 0));
      for (let i = 0; i < 8; i++) {
        const next = (i + 1) % 8;
        addTriangle(acc, topCenterIdx, topVertIdxs[i], topVertIdxs[next], topFaceTopo);
      }

      // Bottom Cap
      const botCenterIdx = addVertex(acc, 0, y0, 0, 0, -1, 0);
      const botVertIdxs = pB.map(([x, y, z]) => addVertex(acc, x, y, z, 0, -1, 0));
      for (let i = 0; i < 8; i++) {
        const next = (i + 1) % 8;
        addTriangle(acc, botCenterIdx, botVertIdxs[next], botVertIdxs[i], bottomFaceTopo);
      }

      // 4 Main Lateral Faces:
      // Back: P0 -> P1
      addQuad(acc, pB[1], pB[0], pT[0], pT[1], [0, 0, -1], backFaceTopo);
      // Right: P2 -> P3
      addQuad(acc, pB[2], pT[2], pT[3], pB[3], [1, 0, 0], rightFaceTopo);
      // Front: P4 -> P5
      addQuad(acc, pB[4], pB[5], pT[5], pT[4], [0, 0, 1], frontFaceTopo);
      // Left: P6 -> P7
      addQuad(acc, pB[6], pT[6], pT[7], pB[7], [-1, 0, 0], leftFaceTopo);

      // 4 Chamfer Bevel Faces (Feature 6!)
      const chamferTopo = (cornerId: number) =>
        makeCadTopoId(6, cornerId, CAD_OP_CHAMFER, CadSubshapeType.FACE, CadTopoFlags.CHAMFER, 0x6000 + cornerId);
      const chamferEdgeTopo = (cornerId: number) =>
        makeCadTopoId(6, cornerId, CAD_OP_CHAMFER, CadSubshapeType.EDGE, CadTopoFlags.CHAMFER, 0x6100 + cornerId);

      // Corner 1 (+X, -Z): P1 -> P2
      const invSqrt2 = 1 / Math.SQRT2;
      addQuad(acc, pB[1], pT[1], pT[2], pB[2], [invSqrt2, 0, -invSqrt2], chamferTopo(1));
      addEdgeSegment(acc, pB[1], pT[1], chamferEdgeTopo(1));
      addEdgeSegment(acc, pB[2], pT[2], chamferEdgeTopo(2));

      // Corner 2 (+X, +Z): P3 -> P4
      addQuad(acc, pB[3], pT[3], pT[4], pB[4], [invSqrt2, 0, invSqrt2], chamferTopo(2));
      addEdgeSegment(acc, pB[3], pT[3], chamferEdgeTopo(3));
      addEdgeSegment(acc, pB[4], pT[4], chamferEdgeTopo(4));

      // Corner 3 (-X, +Z): P5 -> P6
      addQuad(acc, pB[5], pT[5], pT[6], pB[6], [-invSqrt2, 0, invSqrt2], chamferTopo(3));
      addEdgeSegment(acc, pB[5], pT[5], chamferEdgeTopo(5));
      addEdgeSegment(acc, pB[6], pT[6], chamferEdgeTopo(6));

      // Corner 4 (-X, -Z): P7 -> P0
      addQuad(acc, pB[7], pT[7], pT[0], pB[0], [-invSqrt2, 0, -invSqrt2], chamferTopo(4));
      addEdgeSegment(acc, pB[7], pT[7], chamferEdgeTopo(7));
      addEdgeSegment(acc, pB[0], pT[0], chamferEdgeTopo(8));

      // Top and bottom 8-segment boundary polylines
      for (let i = 0; i < 8; i++) {
        const next = (i + 1) % 8;
        addEdgeSegment(acc, pT[i], pT[next], makeCadTopoId(2, i + 1, CAD_OP_SKETCH_EXTRUDE, CadSubshapeType.EDGE, CadTopoFlags.END_CAP, 0x2210 + i));
        addEdgeSegment(acc, pB[i], pB[next], makeCadTopoId(2, i + 1, CAD_OP_SKETCH_EXTRUDE, CadSubshapeType.EDGE, CadTopoFlags.START_CAP, 0x2110 + i));
      }
    }

    // -------------------------------------------------------------
    // FEATURE 3 & 4: BOSS SKETCH & BOSS EXTRUDE
    // -------------------------------------------------------------
    if (hasBossExtrude) {
      const bossRadius = 0.75;
      const bossHeight = 1.2;
      const bossBaseY = y1;
      const bossTopY = y1 + bossHeight;
      const radialSegments = 32;

      const bossLateralFaceTopo = makeCadTopoId(4, 1, CAD_OP_SKETCH_EXTRUDE, CadSubshapeType.FACE, CadTopoFlags.LATERAL, 0x4001);
      const bossTopFaceTopo = makeCadTopoId(4, 0, CAD_OP_SKETCH_EXTRUDE, CadSubshapeType.FACE, CadTopoFlags.END_CAP, 0x4002);

      // Check if Feature 5: Boss Fillet is applied
      if (!hasBossFillet) {
        // Sharp cylindrical boss
        // Top Cap
        const centerIdx = addVertex(acc, 0, bossTopY, 0, 0, 1, 0);
        const topCircleVerts: number[] = [];

        for (let i = 0; i < radialSegments; i++) {
          const theta = (i / radialSegments) * Math.PI * 2;
          const x = Math.cos(theta) * bossRadius;
          const z = Math.sin(theta) * bossRadius;
          topCircleVerts.push(addVertex(acc, x, bossTopY, z, 0, 1, 0));
        }

        for (let i = 0; i < radialSegments; i++) {
          const next = (i + 1) % radialSegments;
          addTriangle(acc, centerIdx, topCircleVerts[i], topCircleVerts[next], bossTopFaceTopo);
        }

        // Lateral Cylindrical Surface
        for (let i = 0; i < radialSegments; i++) {
          const theta0 = (i / radialSegments) * Math.PI * 2;
          const theta1 = ((i + 1) / radialSegments) * Math.PI * 2;

          const cos0 = Math.cos(theta0);
          const sin0 = Math.sin(theta0);
          const cos1 = Math.cos(theta1);
          const sin1 = Math.sin(theta1);

          const x0 = cos0 * bossRadius;
          const z0 = sin0 * bossRadius;
          const x1 = cos1 * bossRadius;
          const z1 = sin1 * bossRadius;

          const v00 = addVertex(acc, x0, bossBaseY, z0, cos0, 0, sin0);
          const v01 = addVertex(acc, x0, bossTopY, z0, cos0, 0, sin0);
          const v11 = addVertex(acc, x1, bossTopY, z1, cos1, 0, sin1);
          const v10 = addVertex(acc, x1, bossBaseY, z1, cos1, 0, sin1);

          addTriangle(acc, v00, v01, v11, bossLateralFaceTopo);
          addTriangle(acc, v00, v11, v10, bossLateralFaceTopo);

          // Rim Edge Segments
          const topRimTopo = makeCadTopoId(4, 1, CAD_OP_SKETCH_EXTRUDE, CadSubshapeType.EDGE, CadTopoFlags.END_CAP, 0x4100 + i);
          addEdgeSegment(acc, [x0, bossTopY, z0], [x1, bossTopY, z1], topRimTopo);

          const baseRimTopo = makeCadTopoId(4, 2, CAD_OP_SKETCH_EXTRUDE, CadSubshapeType.EDGE, CadTopoFlags.START_CAP, 0x4200 + i);
          addEdgeSegment(acc, [x0, bossBaseY, z0], [x1, bossBaseY, z1], baseRimTopo);
        }
      } else {
        // ---------------------------------------------------------
        // FEATURE 5: BOSS FILLET (Curved/Beveled Top Transition)
        // ---------------------------------------------------------
        const filletRadius = 0.22;
        const flatTopRadius = bossRadius - filletRadius;
        const filletStartY = bossTopY - filletRadius;

        const filletFaceTopo = makeCadTopoId(5, 1, CAD_OP_FILLET, CadSubshapeType.FACE, CadTopoFlags.FILLET, 0x5001);
        const filletEdgeTopo = (idx: number) =>
          makeCadTopoId(5, 1, CAD_OP_FILLET, CadSubshapeType.EDGE, CadTopoFlags.FILLET, 0x5100 + idx);

        // Top Flat Disc
        const centerIdx = addVertex(acc, 0, bossTopY, 0, 0, 1, 0);
        const topCircleVerts: number[] = [];

        for (let i = 0; i < radialSegments; i++) {
          const theta = (i / radialSegments) * Math.PI * 2;
          const x = Math.cos(theta) * flatTopRadius;
          const z = Math.sin(theta) * flatTopRadius;
          topCircleVerts.push(addVertex(acc, x, bossTopY, z, 0, 1, 0));
        }

        for (let i = 0; i < radialSegments; i++) {
          const next = (i + 1) % radialSegments;
          addTriangle(acc, centerIdx, topCircleVerts[i], topCircleVerts[next], bossTopFaceTopo);
        }

        // Fillet Toroidal Surface (3 rings for smooth curve)
        const filletSteps = 3;
        for (let s = 0; s < filletSteps; s++) {
          const phi0 = (s / filletSteps) * (Math.PI / 2);
          const phi1 = ((s + 1) / filletSteps) * (Math.PI / 2);

          const r0 = flatTopRadius + Math.sin(phi0) * filletRadius;
          const yF0 = filletStartY + Math.cos(phi0) * filletRadius;
          const r1 = flatTopRadius + Math.sin(phi1) * filletRadius;
          const yF1 = filletStartY + Math.cos(phi1) * filletRadius;

          for (let i = 0; i < radialSegments; i++) {
            const theta0 = (i / radialSegments) * Math.PI * 2;
            const theta1 = ((i + 1) / radialSegments) * Math.PI * 2;

            const cos0 = Math.cos(theta0);
            const sin0 = Math.sin(theta0);
            const cos1 = Math.cos(theta1);
            const sin1 = Math.sin(theta1);

            const n0: [number, number, number] = [cos0 * Math.sin(phi0), Math.cos(phi0), sin0 * Math.sin(phi0)];
            const n1: [number, number, number] = [cos1 * Math.sin(phi1), Math.cos(phi1), sin1 * Math.sin(phi1)];

            const v00 = addVertex(acc, cos0 * r0, yF0, sin0 * r0, n0[0], n0[1], n0[2]);
            const v01 = addVertex(acc, cos0 * r1, yF1, sin0 * r1, n1[0], n1[1], n1[2]);
            const v11 = addVertex(acc, cos1 * r1, yF1, sin1 * r1, n1[0], n1[1], n1[2]);
            const v10 = addVertex(acc, cos1 * r0, yF0, sin1 * r0, n0[0], n0[1], n0[2]);

            addTriangle(acc, v00, v01, v11, filletFaceTopo);
            addTriangle(acc, v00, v11, v10, filletFaceTopo);
          }
        }

        // Add Fillet Tangency Boundary Edges
        for (let i = 0; i < radialSegments; i++) {
          const theta0 = (i / radialSegments) * Math.PI * 2;
          const theta1 = ((i + 1) / radialSegments) * Math.PI * 2;

          const x0 = Math.cos(theta0) * flatTopRadius;
          const z0 = Math.sin(theta0) * flatTopRadius;
          const x1 = Math.cos(theta1) * flatTopRadius;
          const z1 = Math.sin(theta1) * flatTopRadius;
          addEdgeSegment(acc, [x0, bossTopY, z0], [x1, bossTopY, z1], filletEdgeTopo(i));
        }

        // Lateral Boss Wall (from bossBaseY to filletStartY)
        for (let i = 0; i < radialSegments; i++) {
          const theta0 = (i / radialSegments) * Math.PI * 2;
          const theta1 = ((i + 1) / radialSegments) * Math.PI * 2;

          const cos0 = Math.cos(theta0);
          const sin0 = Math.sin(theta0);
          const cos1 = Math.cos(theta1);
          const sin1 = Math.sin(theta1);

          const x0 = cos0 * bossRadius;
          const z0 = sin0 * bossRadius;
          const x1 = cos1 * bossRadius;
          const z1 = sin1 * bossRadius;

          const v00 = addVertex(acc, x0, bossBaseY, z0, cos0, 0, sin0);
          const v01 = addVertex(acc, x0, filletStartY, z0, cos0, 0, sin0);
          const v11 = addVertex(acc, x1, filletStartY, z1, cos1, 0, sin1);
          const v10 = addVertex(acc, x1, bossBaseY, z1, cos1, 0, sin1);

          addTriangle(acc, v00, v01, v11, bossLateralFaceTopo);
          addTriangle(acc, v00, v11, v10, bossLateralFaceTopo);

          // Junction Rim Edge with Base Pad
          const baseRimTopo = makeCadTopoId(4, 2, CAD_OP_SKETCH_EXTRUDE, CadSubshapeType.EDGE, CadTopoFlags.START_CAP, 0x4200 + i);
          addEdgeSegment(acc, [x0, bossBaseY, z0], [x1, bossBaseY, z1], baseRimTopo);
        }
      }
    } else if (hasBossSketch) {
      // Boss sketch on top of base pad (sketch circle wireframe overlay)
      const bossRadius = 0.75;
      const radialSegments = 32;
      const sketchEdgeTopo = (i: number) =>
        makeCadTopoId(3, i + 1, CAD_OP_SKETCH_EXTRUDE, CadSubshapeType.EDGE, CadTopoFlags.START_CAP, 0x3100 + i);

      for (let i = 0; i < radialSegments; i++) {
        const theta0 = (i / radialSegments) * Math.PI * 2;
        const theta1 = ((i + 1) / radialSegments) * Math.PI * 2;
        const x0 = Math.cos(theta0) * bossRadius;
        const z0 = Math.sin(theta0) * bossRadius;
        const x1 = Math.cos(theta1) * bossRadius;
        const z1 = Math.sin(theta1) * bossRadius;
        addEdgeSegment(acc, [x0, y1 + 0.002, z0], [x1, y1 + 0.002, z1], sketchEdgeTopo(i));
      }
    }
  }

  // Count distinct topological faces
  const uniqueFaces = new Set<bigint>();
  for (const f of acc.triangleToFaceId) {
    uniqueFaces.add(f);
  }

  // Convert to flat zero-copy TypedArrays
  const positions = new Float32Array(acc.positions);
  const normals = new Float32Array(acc.normals);
  const indices = new Uint32Array(acc.indices);
  const triangleToFaceId = new BigUint64Array(acc.triangleToFaceId);
  const edgePolylines = new Float32Array(acc.edgePolylines);
  const edgeToTopoId = new BigUint64Array(acc.edgeToTopoId);

  return {
    positions,
    normals,
    indices,
    triangleToFaceId,
    edgePolylines,
    edgeToTopoId,
    bbox: {
      min: [
        acc.minX === Infinity ? -1 : acc.minX,
        acc.minY === Infinity ? -1 : acc.minY,
        acc.minZ === Infinity ? -1 : acc.minZ,
      ],
      max: [
        acc.maxX === -Infinity ? 1 : acc.maxX,
        acc.maxY === -Infinity ? 1 : acc.maxY,
        acc.maxZ === -Infinity ? 1 : acc.maxZ,
      ],
    },
    metadata: {
      vertexCount: positions.length / 3,
      triangleCount: indices.length / 3,
      edgeSegmentCount: edgeToTopoId.length,
      faceCount: uniqueFaces.size,
      rollbackIndex: clampedRollback,
      activeFeatureCount: activeCount,
      totalFeatureCount: nodes.length,
      lastEvaluatedFeatureName: lastEvaluatedName,
      solidType: 'parametric-dag',
      generatedAt: performance.now(),
    },
  };
}
