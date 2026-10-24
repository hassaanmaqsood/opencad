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
      topoId?: bigint;
      decodedTopo?: DecodedCadTopoId;
      point: [number, number, number];
      normal?: [number, number, number];
      label?: string;
    }
  | {
      type: 'edge';
      edgeId: number;
      topoId?: bigint;
      decodedTopo?: DecodedCadTopoId;
      point: [number, number, number];
      label?: string;
    };

/* ------------------------------------------------------------------------- */
/* Wave 2: 2D Parametric Sketch Constraint Solver Types                      */
/* ------------------------------------------------------------------------- */

export const CAD_SKETCH_INVALID_ID = 0xffffffff;

/**
 * Geometric constraint types matching abi/cad_kernel.h
 */
export enum CadSketchConstraintType {
  COINCIDENT = 0,    /**< Two points coincident or point on curve */
  PARALLEL = 1,      /**< Two lines parallel */
  PERPENDICULAR = 2, /**< Two lines perpendicular */
  TANGENT = 3,       /**< Line-arc or arc-arc tangency */
  HORIZONTAL = 4,    /**< Line or two points horizontal */
  VERTICAL = 5,      /**< Line or two points vertical */
  EQUAL = 6,         /**< Equal line length or equal circle/arc radius */
  SYMMETRIC = 7,     /**< Two entities symmetric across a line */
  DISTANCE = 8,      /**< Dimensional distance constraint */
  ANGLE = 9,         /**< Angular constraint (in radians) */
  RADIUS = 10,       /**< Dimensional radius constraint */
}

/**
 * Solver convergence outcomes matching abi/cad_kernel.h
 */
export enum CadSolveState {
  SOLVED = 0,            /**< System converged, residual < tolerance, 0 DOF */
  UNDER_CONSTRAINED = 1, /**< System converged, remaining degrees of freedom > 0 */
  OVER_CONSTRAINED = 2,  /**< Redundant consistent constraints detected */
  CONFLICTING = 3,       /**< Inconsistent/contradictory constraints prevent solution */
}

/**
 * 2D Point Primitive in sketch coordinate space
 */
export interface CadSketchPoint2D {
  id: number;
  x: number;
  y: number;
  is_fixed?: number; // 1 if fixed/grounded, 0 otherwise
}

/**
 * 2D Line Segment defined by endpoints
 */
export interface CadSketchLine2D {
  id: number;
  start_point_id: number;
  end_point_id: number;
}

/**
 * 2D Circular Arc defined by center, start, end points and radius
 */
export interface CadSketchArc2D {
  id: number;
  center_point_id: number;
  start_point_id: number;
  end_point_id: number;
  radius: number;
}

/**
 * 2D Circle defined by center point and radius
 */
export interface CadSketchCircle2D {
  id: number;
  center_point_id: number;
  radius: number;
}

/**
 * Geometric constraint definition relating sketch entities
 */
export interface CadSketchConstraint {
  id: number;
  type: CadSketchConstraintType;
  entity1_id: number;
  entity2_id?: number;
  entity3_id?: number;
  entity4_id?: number;
  parameter_value?: number;
  is_driving?: number;
}

/**
 * Diagnostic and convergence results from 2D constraint solving
 */
export interface CadSolverStatus {
  solve_state: CadSolveState;
  degrees_of_freedom: number;
  iterations: number;
  max_residual: number;
  updated_coords: Float64Array; // Interleaved coordinates [x0, y0, x1, y1, ...]
  coord_count: number;
  conflicting_constraint_ids: Uint32Array;
  conflicting_count: number;
}

/**
 * Request payload sent to CAD Web Worker for solving sketch
 */
export interface SolveSketchWorkerRequest {
  type: 'SOLVE_SKETCH';
  requestId?: number;
  points: CadSketchPoint2D[];
  lines: CadSketchLine2D[];
  arcs: CadSketchArc2D[];
  circles: CadSketchCircle2D[];
  constraints: CadSketchConstraint[];
  draggedPointId?: number;
  dragTarget?: { x: number; y: number };
  maxIterations?: number;
  convergenceTol?: number;
}

/**
 * Transferable response payload from CAD Web Worker
 */
export interface SolveSketchTransferPayload {
  type: 'SKETCH_SOLVED';
  requestId?: number;
  solve_state: CadSolveState;
  degrees_of_freedom: number;
  iterations: number;
  max_residual: number;
  coord_count: number;
  coordsBuffer: ArrayBufferLike;
  conflicting_count: number;
  conflictingIdsBuffer: ArrayBufferLike;
}

/* ------------------------------------------------------------------------- */
/* Wave 3: Parametric Feature DAG, Persistent Naming & Sub-Shape Slices       */
/* ------------------------------------------------------------------------- */

/**
 * Sub-shape classification matching abi/cad_kernel.h
 */
export enum CadSubshapeType {
  VERTEX = 0,
  EDGE = 1,
  FACE = 2,
  SHELL = 3,
}

/**
 * Disambiguation topological flags for sub-shapes
 */
export enum CadTopoFlags {
  NONE = 0,
  START_CAP = 1,
  END_CAP = 2,
  LATERAL = 3,
  FILLET = 4,
  CHAMFER = 5,
}

/**
 * Types of parametric modeling features in the DAG matching abi/cad_kernel.h
 */
export enum CadFeatureType {
  SKETCH = 0,
  EXTRUDE = 1,
  REVOLVE = 2,
  BOOLEAN_UNION = 3,
  BOOLEAN_CUT = 4,
  BOOLEAN_INTERSECT = 5,
  FILLET = 6,
  CHAMFER = 7,
}

/**
 * 64-bit Persistent Topological Identifier (CadTopoId) decoded representation.
 * Encodes origin_feature_id (16b), source_sketch_entity_id (16b), op_type (8b),
 * subshape_type (4b), flags (4b), subshape_hash (16b).
 */
export interface DecodedCadTopoId {
  origin_feature_id: number;
  source_sketch_entity_id: number;
  op_type: number;
  subshape_type: CadSubshapeType;
  flags: number;
  subshape_hash: number;
  raw: bigint;
}

/**
 * Encodes persistent topological components into a 64-bit integer (CadTopoId).
 */
export function makeCadTopoId(
  originFeatureId: number,
  sourceSketchEntityId: number,
  opType: number,
  subshapeType: CadSubshapeType,
  flags: number = 0,
  subshapeHash: number = 0
): bigint {
  const fId = BigInt(originFeatureId & 0xffff);
  const sId = BigInt(sourceSketchEntityId & 0xffff) << 16n;
  const op = BigInt(opType & 0xff) << 32n;
  const sub = BigInt(subshapeType & 0x0f) << 40n;
  const flg = BigInt(flags & 0x0f) << 44n;
  const hsh = BigInt(subshapeHash & 0xffff) << 48n;
  return fId | sId | op | sub | flg | hsh;
}

/**
 * Decodes a 64-bit integer into its constituent persistent topological fields.
 */
export function decodeCadTopoId(raw: bigint | number): DecodedCadTopoId {
  const rawBig = typeof raw === 'bigint' ? raw : BigInt(raw);
  return {
    origin_feature_id: Number(rawBig & 0xffffn),
    source_sketch_entity_id: Number((rawBig >> 16n) & 0xffffn),
    op_type: Number((rawBig >> 32n) & 0xffn),
    subshape_type: Number((rawBig >> 40n) & 0x0fn) as CadSubshapeType,
    flags: Number((rawBig >> 44n) & 0x0fn),
    subshape_hash: Number((rawBig >> 48n) & 0xffffn),
    raw: rawBig,
  };
}

/**
 * Formats a 64-bit CadTopoId into a human-readable display string.
 */
export function formatCadTopoId(raw: bigint | number): string {
  const decoded = decodeCadTopoId(raw);
  const hex = '0x' + decoded.raw.toString(16).padStart(16, '0');
  const typeStr =
    decoded.subshape_type === CadSubshapeType.FACE
      ? 'Face'
      : decoded.subshape_type === CadSubshapeType.EDGE
      ? 'Edge'
      : decoded.subshape_type === CadSubshapeType.VERTEX
      ? 'Vertex'
      : 'Shell';

  let flagStr = '';
  if (decoded.flags === CadTopoFlags.START_CAP) flagStr = ' (Start/Bottom Cap)';
  else if (decoded.flags === CadTopoFlags.END_CAP) flagStr = ' (End/Top Cap)';
  else if (decoded.flags === CadTopoFlags.LATERAL) flagStr = ' (Lateral Side)';
  else if (decoded.flags === CadTopoFlags.FILLET) flagStr = ' (Fillet Transition)';
  else if (decoded.flags === CadTopoFlags.CHAMFER) flagStr = ' (Chamfer Bevel)';

  return `Feature #${decoded.origin_feature_id} • ${typeStr}${flagStr} • [${hex}]`;
}

/**
 * Parametric feature node within the directed acyclic graph (DAG)
 */
export interface CadFeatureNode {
  feature_id: number;
  name: string;
  type: CadFeatureType;
  is_suppressed: boolean;
  parent_ids: number[];
  target_topo_ids?: bigint[];
  params: {
    extrude?: {
      distance: number;
      direction?: [number, number, number];
      symmetric?: boolean;
    };
    revolve?: {
      angle_rad: number;
      axis_origin?: [number, number, number];
      axis_direction?: [number, number, number];
    };
    fillet?: {
      radius: number;
    };
    chamfer?: {
      distance: number;
      angle_rad?: number;
    };
    boolean_op?: {
      tool_feature_id: number;
    };
    sketch?: {
      plane?: 'XY' | 'XZ' | 'YZ';
      profileType?: 'rectangle' | 'circle' | 'polygon';
      width?: number;
      height?: number;
      radius?: number;
      points?: CadSketchPoint2D[];
      lines?: CadSketchLine2D[];
    };
  };
}

/**
 * Metadata accompanying zero-copy tessellated solid slice
 */
export interface CadTessellatedSliceMetadata {
  vertexCount: number;
  triangleCount: number;
  edgeSegmentCount: number;
  faceCount: number;
  rollbackIndex: number;
  activeFeatureCount: number;
  totalFeatureCount: number;
  lastEvaluatedFeatureName: string;
  solidType?: string;
  generatedAt: number;
  lodLevel?: number;
}

/**
 * Transferable zero-copy payload from worker conforming to cad_tessellated_solid_slice_t
 */
export interface CadTessellatedSolidSlicePayload {
  type: 'DAG_EVALUATED';
  requestId?: number;
  positions: ArrayBufferLike;
  normals: ArrayBufferLike;
  indices: ArrayBufferLike;
  triangleToFaceId: ArrayBufferLike; // BigUint64Array buffer
  edgePolylines: ArrayBufferLike;
  edgeToTopoId: ArrayBufferLike;     // BigUint64Array buffer
  bbox: {
    min: [number, number, number];
    max: [number, number, number];
  };
  metadata: CadTessellatedSliceMetadata;
}

/**
 * Client-side typed views over the zero-copy tessellated buffers
 */
export interface CadTessellatedSolidSlice {
  positions: Float32Array;
  normals: Float32Array;
  indices: Uint32Array;
  triangleToFaceId: BigUint64Array;
  edgePolylines: Float32Array;
  edgeToTopoId: BigUint64Array;
  bbox: {
    min: [number, number, number];
    max: [number, number, number];
  };
  metadata: CadTessellatedSliceMetadata;
}

/**
 * Request payload sent to CAD Web Worker for evaluating the DAG
 */
export interface EvaluateDagWorkerRequest {
  type: 'EVALUATE_DAG';
  requestId?: number;
  nodes: CadFeatureNode[];
  rollbackIndex: number;
}

/**
 * Request payload sent to CAD Web Worker for moving the rollback bar
 */
export interface SetRollbackIndexWorkerRequest {
  type: 'SET_ROLLBACK_INDEX';
  requestId?: number;
  rollbackIndex: number;
}

/* ------------------------------------------------------------------------- */
/* Wave 4: STEP AP214 (.step / .stp) Import & Export Types                   */
/* ------------------------------------------------------------------------- */

export interface ImportStepWorkerRequest {
  type: 'IMPORT_STEP';
  requestId?: number;
  stepText: string;
}

export interface ExportStepWorkerRequest {
  type: 'EXPORT_STEP';
  requestId?: number;
}

export interface ExportStepTransferPayload {
  type: 'STEP_EXPORTED';
  requestId?: number;
  stepText: string;
}

export interface ExportStlWorkerRequest {
  type: 'EXPORT_STL';
  requestId?: number;
  options?: {
    binary?: boolean;
    deflection?: number;
    solidName?: string;
  };
}

export interface ExportStlTransferPayload {
  type: 'STL_EXPORTED';
  requestId?: number;
  stlData: Uint8Array | string;
  isBinary: boolean;
}

/* ------------------------------------------------------------------------- */
/* Wave 5: Dress-Up Ops, 3D Assembly Kinematics & Multi-LOD Types            */
/* ------------------------------------------------------------------------- */

export enum CadFilletMode {
  CONSTANT_RADIUS = 0,
  VARIABLE_RADIUS = 1,
  CHORDAL = 2,
}

export interface CadFilletOp {
  mode: CadFilletMode;
  radiusStart: number;
  radiusEnd: number;
  targetEdgeTopoIds: bigint[];
}

export enum CadChamferMode {
  EQUAL_DISTANCE = 0,
  TWO_DISTANCES = 1,
  DISTANCE_ANGLE = 2,
}

export interface CadChamferOp {
  mode: CadChamferMode;
  distance1: number;
  distance2: number;
  angleRad: number;
  targetEdgeTopoIds: bigint[];
}

export interface CadShellOp {
  thickness: number;
  isInward: boolean;
  openFaceTopoIds: bigint[];
}

export interface CadDraftOp {
  draftAngleRad: number;
  pullDirection: [number, number, number];
  neutralPlanePoint: [number, number, number];
  neutralPlaneNormal: [number, number, number];
  draftFaceTopoIds: bigint[];
}

export enum CadAssemblyMateType {
  COINCIDENT = 0,
  CONCENTRIC = 1,
  PARALLEL = 2,
  DISTANCE = 3,
  ANGLE = 4,
  GEAR = 5,
}

export interface CadAssemblyInstance {
  instanceId: number;
  solidHandle: number;
  isGrounded: boolean;
  initialTransform: number[]; // 16 floats column-major
  name: string;
}

export interface CadAssemblyMate {
  mateId: number;
  type: CadAssemblyMateType;
  instance1Id: number;
  entity1TopoId: bigint;
  instance2Id: number;
  entity2TopoId: bigint;
  isAntiAligned: boolean;
  parameterValue: number;
  limitsMin?: number;
  limitsMax?: number;
}

export interface CadAssemblySolveStatus {
  solveState: CadSolveState;
  totalDof: number;
  iterations: number;
  maxResidual: number;
  conflictingCount: number;
}

export enum CadLodLevel {
  COARSE = 0,
  MEDIUM = 1,
  FINE = 2,
}

export interface SolveAssemblyWorkerRequest {
  type: 'SOLVE_ASSEMBLY';
  requestId?: number;
  instances: CadAssemblyInstance[];
  mates: CadAssemblyMate[];
  maxIterations?: number;
  convergenceTol?: number;
}

export interface AssemblySolvedTransferPayload {
  type: 'ASSEMBLY_SOLVED';
  requestId?: number;
  transforms: ArrayBufferLike; // Float32Array buffer (instanceCount * 16 floats)
  instanceCount: number;
  status: CadAssemblySolveStatus;
}

export interface TessellateLodWorkerRequest {
  type: 'TESSELLATE_LOD';
  requestId?: number;
  solidHandle?: number;
  lodLevel: CadLodLevel;
}

export interface ApplyDressUpWorkerRequest {
  type: 'APPLY_DRESSUP';
  requestId?: number;
  opType: 'fillet' | 'chamfer' | 'shell' | 'draft';
  solidHandle?: number;
  fillet?: CadFilletOp;
  chamfer?: CadChamferOp;
  shell?: CadShellOp;
  draft?: CadDraftOp;
}




