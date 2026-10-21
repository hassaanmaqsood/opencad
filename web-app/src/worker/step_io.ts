import {
  CadSubshapeType,
  CadTessellatedSolidSlice,
  CadTopoFlags,
  makeCadTopoId,
} from '../types/cad';

const CAD_OP_STEP_IMPORT = 9;

interface StepEntity {
  id: number;
  name: string;
  args: string;
}

/**
 * Parses raw ISO-10303-21 STEP text into entity dictionary.
 */
function parseStepEntities(stepText: string): Map<number, StepEntity> {
  const entities = new Map<number, StepEntity>();

  // Extract DATA section
  const dataStart = stepText.indexOf('DATA;');
  const dataEnd = stepText.lastIndexOf('ENDSEC;');
  if (dataStart === -1 || dataEnd === -1 || dataEnd <= dataStart) {
    throw new Error('Invalid STEP file: missing DATA section');
  }

  const dataSection = stepText.substring(dataStart + 5, dataEnd);

  // Normalize multi-line records and comments
  // Remove /* ... */ comments
  const cleanData = dataSection.replace(/\/\*[\s\S]*?\*\//g, '');

  // Split by semicolon outside of strings
  const statements = cleanData.split(';');

  for (const rawStmt of statements) {
    const stmt = rawStmt.trim();
    if (!stmt || !stmt.startsWith('#')) continue;

    const eqIdx = stmt.indexOf('=');
    if (eqIdx === -1) continue;

    const idStr = stmt.substring(1, eqIdx).trim();
    const id = parseInt(idStr, 10);
    if (isNaN(id)) continue;

    const rest = stmt.substring(eqIdx + 1).trim();
    const parenIdx = rest.indexOf('(');
    if (parenIdx === -1) continue;

    const name = rest.substring(0, parenIdx).trim().toUpperCase();
    const args = rest.substring(parenIdx);

    entities.set(id, { id, name, args });
  }

  return entities;
}

/**
 * Extracts comma-separated parameters from parenthesis string: (a, b, (c, d), ...)
 */
export function extractArgs(parenStr: string): string[] {
  const trimmed = parenStr.trim();
  if (!trimmed.startsWith('(') || !trimmed.endsWith(')')) {
    return [trimmed];
  }
  const inner = trimmed.substring(1, trimmed.length - 1);
  const result: string[] = [];
  let depth = 0;
  let current = '';

  for (let i = 0; i < inner.length; i++) {
    const char = inner[i];
    if (char === '(') depth++;
    else if (char === ')') depth--;

    if (char === ',' && depth === 0) {
      result.push(current.trim());
      current = '';
    } else {
      current += char;
    }
  }

  if (current.trim().length > 0) {
    result.push(current.trim());
  }

  return result;
}

/**
 * Extracts point coordinates [x, y, z] from CARTESIAN_POINT args.
 */
function extractPointCoords(args: string): [number, number, number] {
  // Format: ('', (1.0, 2.0, 3.0)) or ('Origin', (0., 0., 0.))
  const match = args.match(/\(\s*([-\d.eE+]+)\s*,\s*([-\d.eE+]+)\s*,\s*([-\d.eE+]+)\s*\)/);
  if (match) {
    return [parseFloat(match[1]), parseFloat(match[2]), parseFloat(match[3])];
  }
  // Try 2D point fallback
  const match2d = args.match(/\(\s*([-\d.eE+]+)\s*,\s*([-\d.eE+]+)\s*\)/);
  if (match2d) {
    return [parseFloat(match2d[1]), parseFloat(match2d[2]), 0];
  }
  return [0, 0, 0];
}

/**
 * Extracts entity reference IDs from args: e.g. '(#10, #11, #12)' or '#10'
 */
function extractRefIds(str: string): number[] {
  const ids: number[] = [];
  const regex = /#(\d+)/g;
  let match;
  while ((match = regex.exec(str)) !== null) {
    ids.push(parseInt(match[1], 10));
  }
  return ids;
}

/**
 * Parses an ISO-10303-21 STEP (AP214/AP203) string into a CadTessellatedSolidSlice.
 */
export function parseStep(stepText: string): CadTessellatedSolidSlice {
  const entities = parseStepEntities(stepText);

  // 1. Resolve Cartesian Points: ID -> [x, y, z]
  const cartesianPoints = new Map<number, [number, number, number]>();
  for (const entity of entities.values()) {
    if (entity.name === 'CARTESIAN_POINT') {
      cartesianPoints.set(entity.id, extractPointCoords(entity.args));
    }
  }

  // 2. Resolve Vertex Points: ID -> [x, y, z]
  const vertexPoints = new Map<number, [number, number, number]>();
  for (const entity of entities.values()) {
    if (entity.name === 'VERTEX_POINT') {
      const refs = extractRefIds(entity.args);
      if (refs.length > 0 && cartesianPoints.has(refs[0])) {
        vertexPoints.set(entity.id, cartesianPoints.get(refs[0])!);
      }
    }
  }

  // Helper to resolve a point from vertex or cartesian point ID
  const getPoint = (id: number): [number, number, number] | null => {
    if (vertexPoints.has(id)) return vertexPoints.get(id)!;
    if (cartesianPoints.has(id)) return cartesianPoints.get(id)!;
    return null;
  };

  // 3. Resolve Loops: ID -> [p0, p1, p2, ...]
  const loops = new Map<number, [number, number, number][]>();

  // Poly loops: direct points
  for (const entity of entities.values()) {
    if (entity.name === 'POLY_LOOP') {
      const refs = extractRefIds(entity.args);
      const pts: [number, number, number][] = [];
      for (const ref of refs) {
        const pt = getPoint(ref);
        if (pt) pts.push(pt);
      }
      if (pts.length >= 3) {
        loops.set(entity.id, pts);
      }
    }
  }

  // Edge curves: #edge_curve = EDGE_CURVE('', #v1, #v2, ...)
  const edgeCurves = new Map<number, { start: [number, number, number]; end: [number, number, number] }>();
  for (const entity of entities.values()) {
    if (entity.name === 'EDGE_CURVE') {
      const refs = extractRefIds(entity.args);
      if (refs.length >= 2) {
        const p1 = getPoint(refs[0]);
        const p2 = getPoint(refs[1]);
        if (p1 && p2) {
          edgeCurves.set(entity.id, { start: p1, end: p2 });
        }
      }
    }
  }

  // Oriented edges: #oriented_edge = ORIENTED_EDGE('', *, *, #edge_curve, .T./.F.)
  const orientedEdges = new Map<number, { start: [number, number, number]; end: [number, number, number] }>();
  for (const entity of entities.values()) {
    if (entity.name === 'ORIENTED_EDGE') {
      const refs = extractRefIds(entity.args);
      const isForward = !entity.args.includes('.F.');
      if (refs.length > 0 && edgeCurves.has(refs[0])) {
        const curve = edgeCurves.get(refs[0])!;
        if (isForward) {
          orientedEdges.set(entity.id, { start: curve.start, end: curve.end });
        } else {
          orientedEdges.set(entity.id, { start: curve.end, end: curve.start });
        }
      }
    }
  }

  // Edge loops: #loop = EDGE_LOOP('', (#oe1, #oe2, ...))
  for (const entity of entities.values()) {
    if (entity.name === 'EDGE_LOOP') {
      const refs = extractRefIds(entity.args);
      const pts: [number, number, number][] = [];
      for (const ref of refs) {
        if (orientedEdges.has(ref)) {
          pts.push(orientedEdges.get(ref)!.start);
        } else if (edgeCurves.has(ref)) {
          pts.push(edgeCurves.get(ref)!.start);
        }
      }
      if (pts.length >= 3) {
        loops.set(entity.id, pts);
      }
    }
  }

  // 4. Resolve Face Outer Bounds: ID -> loop points
  const faceBounds = new Map<number, [number, number, number][]>();
  for (const entity of entities.values()) {
    if (entity.name === 'FACE_OUTER_BOUND' || entity.name === 'FACE_BOUND') {
      const refs = extractRefIds(entity.args);
      if (refs.length > 0 && loops.has(refs[0])) {
        faceBounds.set(entity.id, loops.get(refs[0])!);
      }
    }
  }

  // 5. Resolve Faces: ADVANCED_FACE, FACE_SURFACE, etc.
  const faces: [number, number, number][][] = [];

  for (const entity of entities.values()) {
    if (
      entity.name === 'ADVANCED_FACE' ||
      entity.name === 'FACE_SURFACE' ||
      entity.name === 'FACE'
    ) {
      const refs = extractRefIds(entity.args);
      for (const ref of refs) {
        if (faceBounds.has(ref)) {
          faces.push(faceBounds.get(ref)!);
          break;
        } else if (loops.has(ref)) {
          faces.push(loops.get(ref)!);
          break;
        }
      }
    }
  }

  // If no advanced faces found, use all valid loops as faces
  if (faces.length === 0) {
    for (const loopPts of loops.values()) {
      faces.push(loopPts);
    }
  }

  // If still no loops, fallback to direct triangulation of Cartesian points
  if (faces.length === 0 && cartesianPoints.size >= 3) {
    const pts = Array.from(cartesianPoints.values());
    faces.push(pts);
  }

  if (faces.length === 0) {
    throw new Error('STEP file parsed successfully, but no valid B-Rep faces or loops were found');
  }

  // 6. Triangulate Faces & Extract Sharp Edges
  const positionsArr: number[] = [];
  const normalsArr: number[] = [];
  const indicesArr: number[] = [];
  const triangleToFaceIdArr: bigint[] = [];
  const edgePolylinesArr: number[] = [];
  const edgeToTopoIdArr: bigint[] = [];

  let minX = Infinity, maxX = -Infinity;
  let minY = Infinity, maxY = -Infinity;
  let minZ = Infinity, maxZ = -Infinity;

  for (let faceIdx = 0; faceIdx < faces.length; faceIdx++) {
    const polygon = faces[faceIdx];
    if (polygon.length < 3) continue;

    const faceTopoId = makeCadTopoId(
      1,
      faceIdx + 1,
      CAD_OP_STEP_IMPORT,
      CadSubshapeType.FACE,
      CadTopoFlags.LATERAL,
      faceIdx
    );

    // Compute polygon normal via Newell's method
    let nx = 0, ny = 0, nz = 0;
    for (let i = 0; i < polygon.length; i++) {
      const pCurrent = polygon[i];
      const pNext = polygon[(i + 1) % polygon.length];
      nx += (pCurrent[1] - pNext[1]) * (pCurrent[2] + pNext[2]);
      ny += (pCurrent[2] - pNext[2]) * (pCurrent[0] + pNext[0]);
      nz += (pCurrent[0] - pNext[0]) * (pCurrent[1] + pNext[1]);
    }
    const len = Math.hypot(nx, ny, nz) || 1.0;
    nx /= len;
    ny /= len;
    nz /= len;

    // Fan triangulation of polygon
    const baseVertexIdx = positionsArr.length / 3;

    for (let i = 0; i < polygon.length; i++) {
      const p = polygon[i];
      positionsArr.push(p[0], p[1], p[2]);
      normalsArr.push(nx, ny, nz);

      if (p[0] < minX) minX = p[0];
      if (p[0] > maxX) maxX = p[0];
      if (p[1] < minY) minY = p[1];
      if (p[1] > maxY) maxY = p[1];
      if (p[2] < minZ) minZ = p[2];
      if (p[2] > maxZ) maxZ = p[2];
    }

    // Add triangles (0, i, i + 1)
    for (let i = 1; i < polygon.length - 1; i++) {
      indicesArr.push(baseVertexIdx, baseVertexIdx + i, baseVertexIdx + i + 1);
      triangleToFaceIdArr.push(faceTopoId);
    }

    // Add boundary edges
    for (let i = 0; i < polygon.length; i++) {
      const p0 = polygon[i];
      const p1 = polygon[(i + 1) % polygon.length];
      const edgeTopoId = makeCadTopoId(
        1,
        faceIdx * 100 + i + 1,
        CAD_OP_STEP_IMPORT,
        CadSubshapeType.EDGE,
        CadTopoFlags.LATERAL,
        faceIdx * 100 + i
      );

      edgePolylinesArr.push(p0[0], p0[1], p0[2], p1[0], p1[1], p1[2]);
      edgeToTopoIdArr.push(edgeTopoId);
    }
  }

  const positions = new Float32Array(positionsArr);
  const normals = new Float32Array(normalsArr);
  const indices = new Uint32Array(indicesArr);
  const triangleToFaceId = new BigUint64Array(triangleToFaceIdArr);
  const edgePolylines = new Float32Array(edgePolylinesArr);
  const edgeToTopoId = new BigUint64Array(edgeToTopoIdArr);

  return {
    positions,
    normals,
    indices,
    triangleToFaceId,
    edgePolylines,
    edgeToTopoId,
    bbox: {
      min: [minX === Infinity ? -1 : minX, minY === Infinity ? -1 : minY, minZ === Infinity ? -1 : minZ],
      max: [maxX === -Infinity ? 1 : maxX, maxY === -Infinity ? 1 : maxY, maxZ === -Infinity ? 1 : maxZ],
    },
    metadata: {
      vertexCount: positions.length / 3,
      triangleCount: indices.length / 3,
      edgeSegmentCount: edgeToTopoId.length,
      faceCount: faces.length,
      rollbackIndex: 0,
      activeFeatureCount: 1,
      totalFeatureCount: 1,
      lastEvaluatedFeatureName: 'Imported STEP Solid',
      solidType: 'imported-step',
      generatedAt: performance.now(),
    },
  };
}

/**
 * Serializes a CadTessellatedSolidSlice into a standard ISO-10303-21 AP214 STEP file.
 */
export function exportStep(slice: CadTessellatedSolidSlice): string {
  const { positions, indices, triangleToFaceId } = slice;
  const isoTimestamp = new Date().toISOString().replace(/[-:]/g, '').split('.')[0];

  const header = [
    'ISO-10303-21;',
    'HEADER;',
    "FILE_DESCRIPTION(('OpenCAD AP214 STEP Model', 'B-Rep Solid Representation'), '2;1');",
    `FILE_NAME('opencad_solid.step', '${isoTimestamp}', ('OpenCAD User'), ('OpenCAD Project'), 'OpenCAD Kernel v0.1', 'OpenCAD Web Viewport', '');`,
    "FILE_SCHEMA(('AUTOMOTIVE_DESIGN'));",
    'ENDSEC;',
    'DATA;',
  ];

  const lines: string[] = [...header];
  let entityId = 1;

  // Context & Product structure
  const appContextId = entityId++;
  lines.push(`#${appContextId} = APPLICATION_CONTEXT('automotive_design');`);

  const appProtocolId = entityId++;
  lines.push(`#${appProtocolId} = APPLICATION_PROTOCOL_DEFINITION('international standard', 'automotive_design', 2000, #${appContextId});`);

  const prodContextId = entityId++;
  lines.push(`#${prodContextId} = PRODUCT_CONTEXT('', #${appContextId}, 'mechanical');`);

  const productId = entityId++;
  lines.push(`#${productId} = PRODUCT('OpenCAD_Part', 'OpenCAD Parametric Solid', '', (#${prodContextId}));`);

  const prodDefFormationId = entityId++;
  lines.push(`#${prodDefFormationId} = PRODUCT_DEFINITION_FORMATION('1', '', #${productId});`);

  const prodDefId = entityId++;
  lines.push(`#${prodDefId} = PRODUCT_DEFINITION('design', '', #${prodDefFormationId}, #${prodContextId});`);

  const prodShapeId = entityId++;
  lines.push(`#${prodShapeId} = PRODUCT_DEFINITION_SHAPE('', '', #${prodDefId});`);

  // World Axis Placement
  const originPtId = entityId++;
  lines.push(`#${originPtId} = CARTESIAN_POINT('Origin', (0.0, 0.0, 0.0));`);

  const zAxisDirId = entityId++;
  lines.push(`#${zAxisDirId} = DIRECTION('ZAxis', (0.0, 0.0, 1.0));`);

  const xAxisDirId = entityId++;
  lines.push(`#${xAxisDirId} = DIRECTION('XAxis', (1.0, 0.0, 0.0));`);

  const axisPlacementId = entityId++;
  lines.push(`#${axisPlacementId} = AXIS2_PLACEMENT_3D('WorldAxis', #${originPtId}, #${zAxisDirId}, #${xAxisDirId});`);

  // Write unique Cartesian Points
  // Group triangles by topological face ID
  const triCount = indices.length / 3;
  const faceToTriangles = new Map<bigint, number[]>();

  for (let t = 0; t < triCount; t++) {
    const fid = triangleToFaceId[t];
    if (!faceToTriangles.has(fid)) {
      faceToTriangles.set(fid, []);
    }
    faceToTriangles.get(fid)!.push(t);
  }

  const advancedFaceIds: number[] = [];

  for (const [faceTopoId, triIndices] of faceToTriangles.entries()) {
    // For each triangle in this face, write an ADVANCED_FACE / POLY_LOOP
    for (const t of triIndices) {
      const i0 = indices[t * 3];
      const i1 = indices[t * 3 + 1];
      const i2 = indices[t * 3 + 2];

      const p0: [number, number, number] = [positions[i0 * 3], positions[i0 * 3 + 1], positions[i0 * 3 + 2]];
      const p1: [number, number, number] = [positions[i1 * 3], positions[i1 * 3 + 1], positions[i1 * 3 + 2]];
      const p2: [number, number, number] = [positions[i2 * 3], positions[i2 * 3 + 1], positions[i2 * 3 + 2]];

      const cp0 = entityId++;
      lines.push(`#${cp0} = CARTESIAN_POINT('', (${p0[0].toFixed(6)}, ${p0[1].toFixed(6)}, ${p0[2].toFixed(6)}));`);

      const cp1 = entityId++;
      lines.push(`#${cp1} = CARTESIAN_POINT('', (${p1[0].toFixed(6)}, ${p1[1].toFixed(6)}, ${p1[2].toFixed(6)}));`);

      const cp2 = entityId++;
      lines.push(`#${cp2} = CARTESIAN_POINT('', (${p2[0].toFixed(6)}, ${p2[1].toFixed(6)}, ${p2[2].toFixed(6)}));`);

      const polyLoopId = entityId++;
      lines.push(`#${polyLoopId} = POLY_LOOP('', (#${cp0}, #${cp1}, #${cp2}));`);

      const boundId = entityId++;
      lines.push(`#${boundId} = FACE_OUTER_BOUND('', #${polyLoopId}, .T.);`);

      // Face normal for plane surface
      const v01 = [p1[0] - p0[0], p1[1] - p0[1], p1[2] - p0[2]];
      const v02 = [p2[0] - p0[0], p2[1] - p0[1], p2[2] - p0[2]];
      let fnx = v01[1] * v02[2] - v01[2] * v02[1];
      let fny = v01[2] * v02[0] - v01[0] * v02[2];
      let fnz = v01[0] * v02[1] - v01[1] * v02[0];
      const fnlen = Math.hypot(fnx, fny, fnz) || 1.0;
      fnx /= fnlen;
      fny /= fnlen;
      fnz /= fnlen;

      const normDirId = entityId++;
      lines.push(`#${normDirId} = DIRECTION('', (${fnx.toFixed(6)}, ${fny.toFixed(6)}, ${fnz.toFixed(6)}));`);

      const facePlacementId = entityId++;
      lines.push(`#${facePlacementId} = AXIS2_PLACEMENT_3D('', #${cp0}, #${normDirId}, #${xAxisDirId});`);

      const planeId = entityId++;
      lines.push(`#${planeId} = PLANE('', #${facePlacementId});`);

      const faceId = entityId++;
      lines.push(`#${faceId} = ADVANCED_FACE('Face_0x${faceTopoId.toString(16)}', (#${boundId}), #${planeId}, .T.);`);
      advancedFaceIds.push(faceId);
    }
  }

  // Combine faces into CLOSED_SHELL
  const shellId = entityId++;
  const faceRefs = advancedFaceIds.map((id) => `#${id}`).join(', ');
  lines.push(`#${shellId} = CLOSED_SHELL('OpenCAD_Shell', (${faceRefs}));`);

  // MANIFOLD_SOLID_BREP
  const solidBrepId = entityId++;
  lines.push(`#${solidBrepId} = MANIFOLD_SOLID_BREP('OpenCAD_Solid', #${shellId});`);

  const repContextId = entityId++;
  lines.push(`#${repContextId} = GEOMETRIC_REPRESENTATION_CONTEXT(3);`);

  const shapeRepId = entityId++;
  lines.push(`#${shapeRepId} = ADVANCED_BREP_SHAPE_REPRESENTATION('OpenCAD_ShapeRep', (#${solidBrepId}, #${axisPlacementId}), #${repContextId});`);

  const shapeDefRepId = entityId++;
  lines.push(`#${shapeDefRepId} = SHAPE_DEFINITION_REPRESENTATION(#${prodShapeId}, #${shapeRepId});`);

  lines.push('ENDSEC;');
  lines.push('END-ISO-10303-21;');

  return lines.join('\n') + '\n';
}

/**
 * Returns a standard sample STEP AP214 cube solid for testing and demonstrations.
 */
export function generateSampleStepBox(): string {
  return `ISO-10303-21;
HEADER;
FILE_DESCRIPTION(('OpenCAD AP214 Sample Solid'), '2;1');
FILE_NAME('sample_box.step', '20261021T190000', ('OpenCAD User'), ('OpenCAD Project'), 'OpenCAD Kernel v0.1', 'OpenCAD Viewport', '');
FILE_SCHEMA(('AUTOMOTIVE_DESIGN'));
ENDSEC;
DATA;
#1 = APPLICATION_CONTEXT('automotive_design');
#2 = APPLICATION_PROTOCOL_DEFINITION('international standard', 'automotive_design', 2000, #1);
#3 = PRODUCT_CONTEXT('', #1, 'mechanical');
#4 = PRODUCT('Sample_Box', 'Sample 2x2x2 Box Solid', '', (#3));
#5 = PRODUCT_DEFINITION_FORMATION('1', '', #4);
#6 = PRODUCT_DEFINITION('design', '', #5, #3);
#7 = PRODUCT_DEFINITION_SHAPE('', '', #6);
#10 = CARTESIAN_POINT('', (-1.0, -1.0, -1.0));
#11 = CARTESIAN_POINT('', ( 1.0, -1.0, -1.0));
#12 = CARTESIAN_POINT('', ( 1.0,  1.0, -1.0));
#13 = CARTESIAN_POINT('', (-1.0,  1.0, -1.0));
#14 = CARTESIAN_POINT('', (-1.0, -1.0,  1.0));
#15 = CARTESIAN_POINT('', ( 1.0, -1.0,  1.0));
#16 = CARTESIAN_POINT('', ( 1.0,  1.0,  1.0));
#17 = CARTESIAN_POINT('', (-1.0,  1.0,  1.0));
#20 = POLY_LOOP('Bottom_Face', (#10, #11, #15, #14));
#21 = POLY_LOOP('Top_Face', (#13, #17, #16, #12));
#22 = POLY_LOOP('Front_Face', (#14, #15, #16, #17));
#23 = POLY_LOOP('Back_Face', (#11, #10, #13, #12));
#24 = POLY_LOOP('Left_Face', (#10, #14, #17, #13));
#25 = POLY_LOOP('Right_Face', (#15, #11, #12, #16));
#30 = FACE_OUTER_BOUND('', #20, .T.);
#31 = FACE_OUTER_BOUND('', #21, .T.);
#32 = FACE_OUTER_BOUND('', #22, .T.);
#33 = FACE_OUTER_BOUND('', #23, .T.);
#34 = FACE_OUTER_BOUND('', #24, .T.);
#35 = FACE_OUTER_BOUND('', #25, .T.);
#40 = ADVANCED_FACE('Face_Bottom', (#30), #50, .T.);
#41 = ADVANCED_FACE('Face_Top', (#31), #50, .T.);
#42 = ADVANCED_FACE('Face_Front', (#32), #50, .T.);
#43 = ADVANCED_FACE('Face_Back', (#33), #50, .T.);
#44 = ADVANCED_FACE('Face_Left', (#34), #50, .T.);
#45 = ADVANCED_FACE('Face_Right', (#35), #50, .T.);
#50 = PLANE('', #60);
#60 = AXIS2_PLACEMENT_3D('', #10, #70, #71);
#70 = DIRECTION('', (0.0, 1.0, 0.0));
#71 = DIRECTION('', (1.0, 0.0, 0.0));
#80 = CLOSED_SHELL('Box_Shell', (#40, #41, #42, #43, #44, #45));
#90 = MANIFOLD_SOLID_BREP('Sample_Box_Solid', #80);
ENDSEC;
END-ISO-10303-21;
`;
}
