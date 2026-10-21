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

