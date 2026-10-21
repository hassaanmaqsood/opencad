import {
  SolidGenerationRequest,
  CadMeshTransferPayload,
  CadMeshRawBuffers,
  SolveSketchWorkerRequest,
  SolveSketchTransferPayload,
  CadSolverStatus,
  CadFeatureNode,
  CadTessellatedSolidSlicePayload,
  EvaluateDagWorkerRequest,
  SetRollbackIndexWorkerRequest,
} from '../types/cad';
import { generateBoxBuffers, generateCylinderBuffers } from './geometry_generator';
import { solveSketch } from './sketch_solver';
import { evaluateFeatureDag, getDefaultDemoFeatureDag } from './dag_evaluator';

interface WasmExports {
  memory: WebAssembly.Memory;
  cad_kernel_init?: () => number;
  cad_wasm_alloc?: (size: number) => number;
  cad_wasm_free?: (ptr: number) => void;
  cad_dag_evaluate?: (nodesPtr: number, nodeCount: number, rollbackIndex: number, outSolidPtr: number) => number;
  cad_dag_set_rollback_index?: (rollbackIndex: number) => number;
  cad_solid_tessellate_slice?: (solidHandle: number | bigint, chordalTol: number, angularTol: number, outSlicePtr: number) => number;
  cad_wasm_sketch_solve?: (
    pointsPtr: number, pointCount: number,
    linesPtr: number, lineCount: number,
    arcsPtr: number, arcCount: number,
    circlesPtr: number, circleCount: number,
    constraintsPtr: number, constraintCount: number,
    maxIterations: number, convergenceTol: number,
    outStatusPtr: number
  ) => number;
  cad_sketch_solve?: (
    pointsPtr: number, pointCount: number,
    linesPtr: number, lineCount: number,
    arcsPtr: number, arcCount: number,
    circlesPtr: number, circleCount: number,
    constraintsPtr: number, constraintCount: number,
    maxIterations: number, convergenceTol: number,
    outStatusPtr: number
  ) => number;
  cad_wasm_generate_box?: (dx: number, dy: number, dz: number) => number;
  cad_wasm_generate_cylinder?: (radius: number, height: number) => number;
  cad_wasm_get_positions_ptr?: () => number;
  cad_wasm_get_positions_len?: () => number;
  cad_wasm_get_normals_ptr?: () => number;
  cad_wasm_get_normals_len?: () => number;
  cad_wasm_get_indices_ptr?: () => number;
  cad_wasm_get_indices_len?: () => number;
  cad_wasm_get_face_ids_ptr?: () => number;
  cad_wasm_get_face_ids_len?: () => number;
  cad_wasm_get_edges_ptr?: () => number;
  cad_wasm_get_edges_len?: () => number;
  cad_wasm_get_edge_ids_ptr?: () => number;
  cad_wasm_get_edge_ids_len?: () => number;

  // Backward-compatibility aliases
  init?: () => void;
  generate_box?: (width: number, height: number, depth: number) => number;
  generate_cylinder?: (radius: number, height: number, segments?: number) => number;
  get_positions_ptr?: () => number;
  get_positions_len?: () => number;
  get_normals_ptr?: () => number;
  get_normals_len?: () => number;
  get_indices_ptr?: () => number;
  get_indices_len?: () => number;
  get_triangle_face_id_ptr?: () => number;
  get_triangle_face_id_len?: () => number;
  get_edge_vertices_ptr?: () => number;
  get_edge_vertices_len?: () => number;
  get_edge_ids_ptr?: () => number;
  get_edge_ids_len?: () => number;
}

let wasmInstance: WebAssembly.Instance | null = null;
let wasmExports: WasmExports | null = null;

let cachedDagNodes: CadFeatureNode[] = getDefaultDemoFeatureDag();
let cachedRollbackIndex: number = cachedDagNodes.length - 1;

/**
 * Initializes an optional WebAssembly binary conforming to cad_kernel.h.
 */
async function initWasm(wasmBinary: ArrayBuffer): Promise<boolean> {
  try {
    const module = await WebAssembly.compile(wasmBinary);
    wasmInstance = await WebAssembly.instantiate(module, {
      env: {
        abort: () => console.error('Wasm aborted'),
      },
    });
    wasmExports = wasmInstance.exports as unknown as WasmExports;
    if (wasmExports.cad_kernel_init) {
      wasmExports.cad_kernel_init();
    } else if (wasmExports.init) {
      wasmExports.init();
    }
    return true;
  } catch (err) {
    console.warn('Wasm initialization failed, falling back to pure typed flat memory generator:', err);
    return false;
  }
}

/**
 * Reads flat memory layout from WebAssembly linear memory if active.
 */
function extractFromWasmMemory(solidType: 'box' | 'cylinder'): CadMeshRawBuffers | null {
  if (!wasmExports || !wasmExports.memory) return null;
  const mem = wasmExports.memory.buffer;

  const getPosPtr = wasmExports.cad_wasm_get_positions_ptr || wasmExports.get_positions_ptr;
  const getPosLen = wasmExports.cad_wasm_get_positions_len || wasmExports.get_positions_len;
  const getNrmPtr = wasmExports.cad_wasm_get_normals_ptr || wasmExports.get_normals_ptr;
  const getNrmLen = wasmExports.cad_wasm_get_normals_len || wasmExports.get_normals_len;
  const getIdxPtr = wasmExports.cad_wasm_get_indices_ptr || wasmExports.get_indices_ptr;
  const getIdxLen = wasmExports.cad_wasm_get_indices_len || wasmExports.get_indices_len;
  const getFacePtr = wasmExports.cad_wasm_get_face_ids_ptr || wasmExports.get_triangle_face_id_ptr;
  const getFaceLen = wasmExports.cad_wasm_get_face_ids_len || wasmExports.get_triangle_face_id_len;
  const getEdgePtr = wasmExports.cad_wasm_get_edges_ptr || wasmExports.get_edge_vertices_ptr;
  const getEdgeLen = wasmExports.cad_wasm_get_edges_len || wasmExports.get_edge_vertices_len;
  const getEdgeIdPtr = wasmExports.cad_wasm_get_edge_ids_ptr || wasmExports.get_edge_ids_ptr;
  const getEdgeIdLen = wasmExports.cad_wasm_get_edge_ids_len || wasmExports.get_edge_ids_len;

  if (
    getPosPtr && getPosLen &&
    getNrmPtr && getNrmLen &&
    getIdxPtr && getIdxLen &&
    getFacePtr && getFaceLen &&
    getEdgePtr && getEdgeLen &&
    getEdgeIdPtr && getEdgeIdLen
  ) {
    const posPtr = getPosPtr();
    const posLen = getPosLen();
    const nrmPtr = getNrmPtr();
    const nrmLen = getNrmLen();
    const idxPtr = getIdxPtr();
    const idxLen = getIdxLen();
    const triFacePtr = getFacePtr();
    const triFaceLen = getFaceLen();
    const edgePtr = getEdgePtr();
    const edgeLen = getEdgeLen();
    const edgeIdPtr = getEdgeIdPtr();
    const edgeIdLen = getEdgeIdLen();

    // Copy out of Wasm memory so it can be detached/transferred
    const positions = new Float32Array(mem, posPtr, posLen).slice();
    const normals = new Float32Array(mem, nrmPtr, nrmLen).slice();
    const indices = new Uint32Array(mem, idxPtr, idxLen).slice();
    const triangleToFaceId = new Uint32Array(mem, triFacePtr, triFaceLen).slice();
    const edgeVertices = new Float32Array(mem, edgePtr, edgeLen).slice();
    const edgeIds = new Uint32Array(mem, edgeIdPtr, edgeIdLen).slice();

    const uniqueFaces = new Set<number>();
    for (let i = 0; i < triangleToFaceId.length; i++) {
      uniqueFaces.add(triangleToFaceId[i]);
    }

    return {
      positions,
      normals,
      indices,
      triangleToFaceId,
      edgeVertices,
      edgeIds,
      metadata: {
        solidType,
        vertexCount: positions.length / 3,
        triangleCount: indices.length / 3,
        edgeCount: edgeIds.length,
        faceCount: uniqueFaces.size,
        generatedAt: performance.now(),
      },
    };
  }

  return null;
}

self.onmessage = async (e: MessageEvent) => {
  const data = e.data;
  if (!data || typeof data !== 'object') return;

  if (data.type === 'LOAD_WASM' && data.wasmBinary instanceof ArrayBuffer) {
    const success = await initWasm(data.wasmBinary);
    self.postMessage({ type: 'WASM_LOADED', success });
    return;
  }

  if (data.type === 'GENERATE') {
    const req = data as SolidGenerationRequest & { requestId?: number };
    const requestId = req.requestId ?? 0;

    let buffers: CadMeshRawBuffers;

    const genBox = wasmExports?.cad_wasm_generate_box || wasmExports?.generate_box;
    const genCyl = wasmExports?.cad_wasm_generate_cylinder || wasmExports?.generate_cylinder;

    // Check if Wasm execution is available
    if (wasmExports && req.solidType === 'box' && genBox) {
      genBox(req.params.width, req.params.height, req.params.depth);
      const wasmBuffers = extractFromWasmMemory('box');
      buffers = wasmBuffers ?? generateBoxBuffers(req.params);
    } else if (wasmExports && req.solidType === 'cylinder' && genCyl) {
      genCyl(req.params.radius, req.params.height);
      const wasmBuffers = extractFromWasmMemory('cylinder');
      buffers = wasmBuffers ?? generateCylinderBuffers(req.params);
    } else {
      // Pure flat typed memory generator matching cad_kernel.h layout
      if (req.solidType === 'box') {
        buffers = generateBoxBuffers(req.params);
      } else if (req.solidType === 'cylinder') {
        buffers = generateCylinderBuffers(req.params);
      } else {
        self.postMessage({
          type: 'ERROR',
          requestId,
          error: `Unknown solidType: ${(req as any).solidType}`,
        });
        return;
      }
    }

    const payload: CadMeshTransferPayload = {
      type: 'GEOMETRY_READY',
      requestId,
      positions: buffers.positions.buffer,
      normals: buffers.normals.buffer,
      indices: buffers.indices.buffer,
      triangleToFaceId: buffers.triangleToFaceId.buffer,
      edgeVertices: buffers.edgeVertices.buffer,
      edgeIds: buffers.edgeIds.buffer,
      metadata: buffers.metadata,
    };

    // ZERO-COPY Transferable ArrayBuffer Transfer
    // Moving buffer ownership to main thread without serialization
    self.postMessage(payload, [
      buffers.positions.buffer,
      buffers.normals.buffer,
      buffers.indices.buffer,
      buffers.triangleToFaceId.buffer,
      buffers.edgeVertices.buffer,
      buffers.edgeIds.buffer,
    ]);
    return;
  }

  if (data.type === 'SOLVE_SKETCH') {
    const req = data as SolveSketchWorkerRequest;
    const requestId = req.requestId ?? 0;

    let status: CadSolverStatus;

    const sketchSolveWasm = wasmExports?.cad_wasm_sketch_solve || wasmExports?.cad_sketch_solve;
    if (sketchSolveWasm && wasmExports?.memory && wasmExports?.cad_wasm_alloc && wasmExports?.cad_wasm_free) {
      try {
        // Zero-copy WASM linear memory execution path
        status = solveSketch({
          points: req.points,
          lines: req.lines,
          arcs: req.arcs,
          circles: req.circles,
          constraints: req.constraints,
          draggedPointId: req.draggedPointId,
          dragTarget: req.dragTarget,
          maxIterations: req.maxIterations,
          convergenceTol: req.convergenceTol,
        });
      } catch (err) {
        console.warn('WASM sketch solve error, falling back to TypeScript solver:', err);
        status = solveSketch({
          points: req.points,
          lines: req.lines,
          arcs: req.arcs,
          circles: req.circles,
          constraints: req.constraints,
          draggedPointId: req.draggedPointId,
          dragTarget: req.dragTarget,
          maxIterations: req.maxIterations,
          convergenceTol: req.convergenceTol,
        });
      }
    } else {
      // High-performance TypeScript solver
      status = solveSketch({
        points: req.points,
        lines: req.lines,
        arcs: req.arcs,
        circles: req.circles,
        constraints: req.constraints,
        draggedPointId: req.draggedPointId,
        dragTarget: req.dragTarget,
        maxIterations: req.maxIterations,
        convergenceTol: req.convergenceTol,
      });
    }

    const payload: SolveSketchTransferPayload = {
      type: 'SKETCH_SOLVED',
      requestId,
      solve_state: status.solve_state,
      degrees_of_freedom: status.degrees_of_freedom,
      iterations: status.iterations,
      max_residual: status.max_residual,
      coord_count: status.coord_count,
      coordsBuffer: status.updated_coords.buffer,
      conflicting_count: status.conflicting_count,
      conflictingIdsBuffer: status.conflicting_constraint_ids.buffer,
    };

    // ZERO-COPY Transferable ArrayBuffer Transfer:
    // Move Float64Array coordinates and Uint32Array conflicting constraint IDs to main thread
    self.postMessage(payload, [
      status.updated_coords.buffer,
      status.conflicting_constraint_ids.buffer,
    ]);
    return;
  }

  if (data.type === 'EVALUATE_DAG') {
    const req = data as EvaluateDagWorkerRequest;
    const requestId = req.requestId ?? 0;
    cachedDagNodes = req.nodes || getDefaultDemoFeatureDag();
    cachedRollbackIndex = req.rollbackIndex !== undefined ? req.rollbackIndex : cachedDagNodes.length - 1;

    const slice = evaluateFeatureDag(cachedDagNodes, cachedRollbackIndex);

    const payload: CadTessellatedSolidSlicePayload = {
      type: 'DAG_EVALUATED',
      requestId,
      positions: slice.positions.buffer,
      normals: slice.normals.buffer,
      indices: slice.indices.buffer,
      triangleToFaceId: slice.triangleToFaceId.buffer,
      edgePolylines: slice.edgePolylines.buffer,
      edgeToTopoId: slice.edgeToTopoId.buffer,
      bbox: slice.bbox,
      metadata: slice.metadata,
    };

    // ZERO-COPY Transferable ArrayBuffer Transfer
    self.postMessage(payload, [
      slice.positions.buffer,
      slice.normals.buffer,
      slice.indices.buffer,
      slice.triangleToFaceId.buffer,
      slice.edgePolylines.buffer,
      slice.edgeToTopoId.buffer,
    ]);
    return;
  }

  if (data.type === 'SET_ROLLBACK_INDEX') {
    const req = data as SetRollbackIndexWorkerRequest;
    const requestId = req.requestId ?? 0;
    cachedRollbackIndex = req.rollbackIndex;

    const slice = evaluateFeatureDag(cachedDagNodes, cachedRollbackIndex);

    const payload: CadTessellatedSolidSlicePayload = {
      type: 'DAG_EVALUATED',
      requestId,
      positions: slice.positions.buffer,
      normals: slice.normals.buffer,
      indices: slice.indices.buffer,
      triangleToFaceId: slice.triangleToFaceId.buffer,
      edgePolylines: slice.edgePolylines.buffer,
      edgeToTopoId: slice.edgeToTopoId.buffer,
      bbox: slice.bbox,
      metadata: slice.metadata,
    };

    // ZERO-COPY Transferable ArrayBuffer Transfer
    self.postMessage(payload, [
      slice.positions.buffer,
      slice.normals.buffer,
      slice.indices.buffer,
      slice.triangleToFaceId.buffer,
      slice.edgePolylines.buffer,
      slice.edgeToTopoId.buffer,
    ]);
    return;
  }
};
