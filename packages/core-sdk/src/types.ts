/**
 * @file types.ts
 * Type definitions for @open-cad/core matching abi/cad_kernel.h
 */

export type CadSolidHandle = bigint | number;
export type CadFaceHandle = bigint | number;
export type CadEdgeHandle = bigint | number;

export const CAD_INVALID_HANDLE = 0;

export enum CadStatus {
  Ok = 0,
  InvalidArgument = 1,
  OutOfMemory = 2,
  TopologyInvalid = 3,
  GeometryIntersection = 4,
  OpFailed = 5,
  NotImplemented = 6,
  Timeout = 7,
  NonManifold = 8,
  LimitExceeded = 9,
}

export enum CadBackend {
  Auto = 0,
  COracle = 1,
  NativeZig = 2,
}

export enum CadOpType {
  PrimitiveBox = 0,
  PrimitiveCylinder = 1,
  PrimitiveSphere = 2,
  SketchExtrude = 3,
  BooleanUnion = 4,
  BooleanDifference = 5,
  BooleanIntersection = 6,
  Fillet = 7,
  Chamfer = 8,
  Count = 9,
}

export enum CadLodLevel {
  Coarse = 0,
  Medium = 1,
  Fine = 2,
}

export enum CadSolveState {
  Solved = 0,
  UnderConstrained = 1,
  OverConstrained = 2,
  Conflicting = 3,
}

export interface CadVec3 {
  x: number;
  y: number;
  z: number;
}

export interface CadMesh {
  positions: Float32Array;
  normals: Float32Array;
  indices: Uint32Array;
  vertexCount: number;
  triangleCount: number;
}

export interface CadBrepStats {
  numVertices: number;
  numEdges: number;
  numFaces: number;
  eulerCharacteristic: number;
  surfaceArea: number;
  volume: number;
}

export interface CadKernelLimits {
  maxWasmMemoryBytes: number;
  maxSolverIterations: number;
  maxBooleanFaces: number;
  evalTimeoutMs: number;
}

export interface CadTopoId {
  originFeatureId: number;
  sourceSketchEntityId: number;
  opType: number;
  subshapeType: number;
  subshapeIndex: number;
  disambiguationIndex: number;
}

export enum CadSketchConstraintType {
  Coincident = 0,
  Parallel = 1,
  Perpendicular = 2,
  Tangent = 3,
  Horizontal = 4,
  Vertical = 5,
  Equal = 6,
  Symmetric = 7,
  Distance = 8,
  Angle = 9,
  Radius = 10,
}

export interface CadSketchPoint2D {
  id: number;
  x: number;
  y: number;
  isFixed: boolean;
}

export interface CadSketchLine2D {
  id: number;
  startPointId: number;
  endPointId: number;
}

export interface CadSketchArc2D {
  id: number;
  centerPointId: number;
  startPointId: number;
  endPointId: number;
  radius: number;
}

export interface CadSketchCircle2D {
  id: number;
  centerPointId: number;
  radius: number;
}

export interface CadSketchConstraint {
  id: number;
  type: CadSketchConstraintType;
  entity1Id: number;
  entity2Id: number;
  entity3Id?: number;
  parameterValue: number;
}

export interface CadSolverStatus {
  solveState: CadSolveState;
  degreesOfFreedom: number;
  iterations: number;
  maxResidual: number;
  conflictingCount: number;
  conflictingConstraintIds: number[];
}

export enum CadFeatureType {
  Sketch = 0,
  Extrude = 1,
  Revolve = 2,
  BooleanUnion = 3,
  BooleanCut = 4,
  BooleanIntersect = 5,
  Fillet = 6,
  Chamfer = 7,
  Shell = 8,
  Draft = 9,
  CustomPlugin = 1000,
}

export interface CadFeatureNode {
  featureId: number;
  type: CadFeatureType | number;
  isSuppressed: boolean;
  parentIds: number[];
  targetTopoIds: CadTopoId[];
  params: Record<string, any>;
}

export interface CadTessellatedSolidSlice {
  positions: Float32Array;
  normals: Float32Array;
  indices: Uint32Array;
  vertexCount: number;
  triangleCount: number;
  triangleToFaceId: BigUint64Array | Uint32Array;
  edgePolylines: Float32Array;
  edgeSegmentCount: number;
  edgeToTopoId: BigUint64Array | Uint32Array;
  bboxMin: CadVec3;
  bboxMax: CadVec3;
}

export interface CadAssemblyInstance {
  instanceId: number;
  solidHandle: CadSolidHandle;
  isGrounded: boolean;
  initialTransform: Float32Array;
  name: string;
}

export enum CadAssemblyMateType {
  Coincident = 0,
  Concentric = 1,
  Parallel = 2,
  Distance = 3,
  Angle = 4,
  Gear = 5,
}

export interface CadAssemblyMate {
  mateId: number;
  type: CadAssemblyMateType;
  instance1Id: number;
  entity1TopoId: CadTopoId;
  instance2Id: number;
  entity2TopoId: CadTopoId;
  isAntiAligned: boolean;
  parameterValue: number;
  limitsMin?: number;
  limitsMax?: number;
}

export interface CadAssemblySolveResult {
  solveState: CadSolveState;
  totalDof: number;
  iterations: number;
  maxResidual: number;
  transforms: Float32Array;
}

export interface CadPluginOpVTable {
  opTypeId: number;
  opName: string;
  evaluateFn?: (
    opTypeId: number,
    nodePtr: number,
    inputSolidsPtr: number,
    inputCount: number,
    outSolidPtr: number
  ) => CadStatus;
  tessellateFn?: (
    solid: number,
    chordalTol: number,
    angularTol: number,
    outSlicePtr: number
  ) => CadStatus;
  serializeAstFn?: (
    nodePtr: number,
    outBufPtr: number,
    bufSize: number,
    outWrittenPtr: number
  ) => CadStatus;
  freeFn?: (solid: number) => void;
}

export interface CadCoreWasmExports {
  memory: WebAssembly.Memory;
  cad_kernel_init?: () => number;
  cad_kernel_deinit?: () => number;
  cad_primitive_box?: (dx: number, dy: number, dz: number, outHandle: number) => number;
  cad_primitive_cylinder?: (radius: number, height: number, outHandle: number) => number;
  cad_primitive_sphere?: (radius: number, outHandle: number) => number;
  cad_solid_release?: (handle: number | bigint) => number;
  cad_solid_tessellate?: (handle: number | bigint, chordalTol: number, angularTol: number, outMesh: number) => number;
  cad_mesh_free?: (meshPtr: number) => number;
  cad_solid_tessellate_slice?: (handle: number | bigint, chordalTol: number, angularTol: number, outSlice: number) => number;
  cad_solid_tessellate_lod?: (handle: number | bigint, lodLevel: number, outSlice: number) => number;
  cad_slice_free?: (slicePtr: number) => number;
  cad_dag_evaluate?: (nodesPtr: number, nodeCount: number, rollbackIndex: number, outSolid: number) => number;
  cad_wasm_step_export?: (handle: number | bigint) => number;
  cad_wasm_step_export_len?: () => number;
  cad_wasm_step_import?: (ptr: number, len: number) => number;
  cad_assembly_solve_transforms?: (
    instancesPtr: number,
    instanceCount: number,
    matesPtr: number,
    mateCount: number,
    maxIter: number,
    tol: number,
    outTransforms: number,
    outStatus: number
  ) => number;
  cad_set_kernel_limits?: (limitsPtr: number) => number;
  cad_get_kernel_limits?: (outLimitsPtr: number) => number;
  cad_register_plugin_op?: (vtablePtr: number) => number;
  cad_unregister_plugin_op?: (opTypeId: number) => number;
  cad_execute_plugin_op?: (
    opTypeId: number,
    nodePtr: number,
    inputSolidsPtr: number,
    inputCount: number,
    outSolidPtr: number
  ) => number;
  cad_shared_alloc?: (size: number) => number;
  cad_shared_free?: (ptr: number, size: number) => void;
}
