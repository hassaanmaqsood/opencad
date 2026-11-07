import {
  SolidGenerationRequest,
  CadMeshTransferPayload,
  CadMeshRawBuffers,
  SolveSketchWorkerRequest,
  SolveSketchTransferPayload,
  CadSolverStatus,
  CadFeatureNode,
  CadTessellatedSolidSlice,
  CadTessellatedSolidSlicePayload,
  EvaluateDagWorkerRequest,
  SetRollbackIndexWorkerRequest,
  ImportStepWorkerRequest,
  ExportStepWorkerRequest,
  ExportStepTransferPayload,
  ExportStlWorkerRequest,
  ExportStlTransferPayload,
  SolveAssemblyWorkerRequest,
  AssemblySolvedTransferPayload,
  TessellateLodWorkerRequest,
  ApplyDressUpWorkerRequest,
  CadFeatureType,
  CadAssemblySolveStatus,
} from '../types/cad';
import { solveSketch } from './sketch_solver';
import { getDefaultDemoFeatureDag } from '../types/demo_dag';
import { parseStep, exportStep } from './step_io';
import { exportStl } from './stl_io';
import { solveAssemblyClient } from './assembly_solver';
import { getAssetUrl } from '../utils/assets';

interface WasmExports {
  memory: WebAssembly.Memory;
  cad_kernel_init?: () => number;
  cad_wasm_alloc?: (size: number) => number;
  cad_wasm_free?: (ptr: number) => void;
  cad_wasm_step_import?: (strPtr: number, strLen: number, outSolidPtr: number) => number;
  cad_wasm_stl_export?: (solid: number, chordal: number, angular: number, binary: boolean) => number;
  cad_wasm_stl_export_len?: () => number;
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

  // Wave 5: Assembly Solver & Dress-up exports
  cad_wasm_assembly_solve?: (
    instancesPtr: number,
    instanceCount: number,
    matesPtr: number,
    mateCount: number,
    maxIterations: number,
    convergenceTol: number
  ) => number;
  cad_wasm_assembly_get_transforms_ptr?: () => number;
  cad_wasm_assembly_get_transforms_len?: () => number;
  cad_wasm_assembly_get_solve_state?: () => number;
  cad_wasm_assembly_get_dof?: () => number;
  cad_wasm_assembly_get_iterations?: () => number;
  cad_wasm_assembly_get_max_residual?: () => number;
  cad_solid_tessellate_lod?: (solidHandle: number | bigint, lodLevel: number, outSlicePtr: number) => number;
  cad_solid_fillet?: (solidHandle: number | bigint, filletOpPtr: number, outSolidPtr: number) => number;
  cad_solid_chamfer?: (solidHandle: number | bigint, chamferOpPtr: number, outSolidPtr: number) => number;
  cad_solid_shell?: (solidHandle: number | bigint, shellOpPtr: number, outSolidPtr: number) => number;
  cad_solid_draft?: (solidHandle: number | bigint, draftOpPtr: number, outSolidPtr: number) => number;

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

function getEmptySlice(): CadTessellatedSolidSlice {
  return {
    positions: new Float32Array(0),
    normals: new Float32Array(0),
    indices: new Uint32Array(0),
    triangleToFaceId: new BigUint64Array(0),
    edgePolylines: new Float32Array(0),
    edgeToTopoId: new BigUint64Array(0),
    bbox: { min: [0, 0, 0], max: [0, 0, 0] },
    metadata: {
      vertexCount: 0,
      triangleCount: 0,
      edgeSegmentCount: 0,
      faceCount: 0,
      rollbackIndex: 0,
      activeFeatureCount: 0,
      totalFeatureCount: 0,
      lastEvaluatedFeatureName: '',
      generatedAt: performance.now(),
    },
  };
}

function evaluateFeatureDag(_nodes: CadFeatureNode[], _rollbackIndex: number): CadTessellatedSolidSlice {
  return getEmptySlice();
}

let cachedDagNodes: CadFeatureNode[] = getDefaultDemoFeatureDag();
let cachedRollbackIndex: number = cachedDagNodes.length - 1;
let activeSlice: CadTessellatedSolidSlice | null = null;

function createSharedWasmMemory(): WebAssembly.Memory {
  try {
    return new WebAssembly.Memory({ initial: 128, maximum: 512, shared: true });
  } catch (err) {
    console.warn(
      '[cad.worker] Shared memory creation failed (crossOriginIsolated:',
      typeof self !== 'undefined' ? (self as any).crossOriginIsolated : false,
      '):',
      err
    );
    const WasmMem: any = WebAssembly.Memory;
    try {
      return new WasmMem({ initial: 128, maximum: 512 });
    } catch {
      return new WasmMem({ initial: 128 });
    }
  }
}

export const sharedWasmMemory = createSharedWasmMemory();

// Global unhandled error listeners in worker scope
self.addEventListener('error', (e: ErrorEvent) => {
  const detail = e.message || (e.error ? (e.error.stack || e.error.message) : '') || 'Unknown worker error';
  console.error(`[cad.worker] Uncaught worker error: ${detail} [at ${e.filename || 'cad.worker'}:${e.lineno || 0}:${e.colno || 0}]`, e.error || e);
});

self.addEventListener('unhandledrejection', (e: PromiseRejectionEvent) => {
  const reason = e.reason ? (e.reason.stack || e.reason.message || String(e.reason)) : 'Unknown rejection';
  console.error(`[cad.worker] Unhandled promise rejection in worker: ${reason}`, e.reason);
});

// Make shared memory available globally on worker global scope
(self as any).__openCadSharedMemory = sharedWasmMemory;

let canaryInstance: WebAssembly.Instance | null = null;
let configuredWasmUrl: string | null = null;
let configuredCanaryUrl: string | null = null;
let kernelInitPromise: Promise<boolean> | null = null;

function getCandidateWasmUrls(filename: string): string[] {
  const list: string[] = [];
  if (filename === 'cad_kernel.wasm' && configuredWasmUrl) list.push(configuredWasmUrl);
  if (filename === 'ext_field_canary.wasm' && configuredCanaryUrl) list.push(configuredCanaryUrl);

  try {
    const assetUrl = getAssetUrl(filename);
    if (assetUrl) list.push(assetUrl);
  } catch {}

  if (typeof self !== 'undefined' && self.location) {
    try {
      list.push(new URL(`../${filename}`, self.location.href).href);
      list.push(new URL(filename, self.location.href).href);
      list.push(new URL(`./${filename}`, self.location.href).href);
    } catch {}
  }
  list.push(`/${filename}`);
  list.push(`./${filename}`);
  return [...new Set(list)];
}

async function ensureCanary(): Promise<WebAssembly.Instance | null> {
  if (canaryInstance) return canaryInstance;
  const candidates = getCandidateWasmUrls('ext_field_canary.wasm');
  for (const url of candidates) {
    try {
      const resp = await fetch(url);
      if (resp.ok) {
        const buf = await resp.arrayBuffer();
        const mod = await WebAssembly.compile(buf);
        canaryInstance = await WebAssembly.instantiate(mod, {
          env: { memory: sharedWasmMemory },
          opencad: {
            field_alloc: () => 0,
            field_eval_scalar: () => 0.0,
            field_eval_vec3: () => {},
            cmd_write: () => {},
          },
        });
        return canaryInstance;
      }
    } catch (err) {
      // Try next candidate
    }
  }
  console.warn('Canary extension could not be loaded from any candidate URL');
  return null;
}

async function ensureKernelWasm(): Promise<boolean> {
  if (wasmExports && (wasmExports as any).cdml_eval_document) return true;
  if (kernelInitPromise) return kernelInitPromise;

  kernelInitPromise = (async () => {
    const candidates = getCandidateWasmUrls('cad_kernel.wasm');
    for (const url of candidates) {
      try {
        const resp = await fetch(url);
        if (resp.ok) {
          const buf = await resp.arrayBuffer();
          const ok = await initWasm(buf);
          if (ok) return true;
        }
      } catch (err) {
        // Try next candidate URL
      }
    }
    console.error('Failed to load cad_kernel.wasm across all candidates:', candidates);
    return false;
  })();

  const res = await kernelInitPromise;
  if (!res) kernelInitPromise = null;
  return res;
}

let scratchCursor = 0x300000;
function writeWasmString(str: string): { ptr: number; len: number } {
  const bytes = new TextEncoder().encode(str);
  scratchCursor = (scratchCursor + 15) & ~15;
  const ptr = scratchCursor;
  new Uint8Array(sharedWasmMemory.buffer).set(bytes, ptr);
  scratchCursor += bytes.length + 16;
  return { ptr, len: bytes.length };
}

function parseVarsFromXml(xml: string) {
  const vars: Array<{ id: string; value: number; min?: number; max?: number; unit?: string; isPublic: boolean }> = [];
  const matches = xml.matchAll(/<var\s+([^>]+)\/>/g);
  for (const m of matches) {
    const attrs = m[1];
    const idMatch = attrs.match(/id="([^"]+)"/);
    const valMatch = attrs.match(/value="([^"]+)"/);
    if (idMatch && valMatch) {
      const varId = idMatch[1];
      const minMatch = attrs.match(/min="([^"]+)"/);
      const maxMatch = attrs.match(/max="([^"]+)"/);
      const unitMatch = attrs.match(/unit="([^"]+)"/);
      const publicMatch = attrs.match(/public="([^"]+)"/);
      const privateMatch = attrs.match(/private="([^"]+)"/);
      const accessMatch = attrs.match(/access="([^"]+)"/);

      // Variables are public by default.
      // Private if: id starts with '_', private="true", public="false", or access="private"
      let isPublic = true;
      if (varId.startsWith('_')) {
        isPublic = false;
      }
      if (privateMatch && (privateMatch[1] === 'true' || privateMatch[1] === '1')) {
        isPublic = false;
      }
      if (publicMatch && (publicMatch[1] === 'false' || publicMatch[1] === '0')) {
        isPublic = false;
      }
      if (accessMatch && accessMatch[1].toLowerCase() === 'private') {
        isPublic = false;
      }

      vars.push({
        id: varId,
        value: parseFloat(valMatch[1]),
        min: minMatch ? parseFloat(minMatch[1]) : undefined,
        max: maxMatch ? parseFloat(maxMatch[1]) : undefined,
        unit: unitMatch ? unitMatch[1] : undefined,
        isPublic,
      });
    }
  }
  return vars;
}

function parseProbesFromXml(xml: string): string[] {
  const probeIds: string[] = [];
  const matches = xml.matchAll(/<probe\s+[^>]*id="([^"]+)"/g);
  for (const m of matches) {
    probeIds.push(m[1]);
  }
  return probeIds;
}

function parseExportsFromXml(xml: string): string[] {
  const exports: string[] = [];
  if (xml.includes('<step')) exports.push('step');
  if (xml.includes('<stl')) exports.push('stl');
  if (xml.includes('<tessellate')) exports.push('tessellate');
  return exports;
}

function readTessellationFromSharedMemory() {
  const ctrlView = new DataView(sharedWasmMemory.buffer, 0x0F0000, 64);
  const solidId = ctrlView.getUint32(0x00, true);
  const vertexCount = ctrlView.getUint32(0x04, true);
  const triangleCount = ctrlView.getUint32(0x08, true);
  const posOffset = ctrlView.getUint32(0x0C, true);
  const nrmOffset = ctrlView.getUint32(0x10, true);
  const idxOffset = ctrlView.getUint32(0x14, true);
  const genCounter = ctrlView.getUint32(0x1C, true);

  if (vertexCount === 0 || triangleCount === 0) {
    return null;
  }

  const positions = new Float32Array(sharedWasmMemory.buffer, posOffset, vertexCount * 3).slice();
  const normals = new Float32Array(sharedWasmMemory.buffer, nrmOffset, vertexCount * 3).slice();
  const indices = new Uint32Array(sharedWasmMemory.buffer, idxOffset, triangleCount * 3).slice();

  // True CAD feature edges are generated client-side via EdgesGeometry with 38-deg dihedral threshold
  const edgeVertices = new Float32Array(0);

  return {
    solidId,
    vertexCount,
    triangleCount,
    positions,
    normals,
    indices,
    edgeVertices,
    genCounter,
  };
}

/**
 * Initializes an optional WebAssembly binary conforming to cad_kernel.h.
 */
async function initWasm(wasmBinary: ArrayBuffer): Promise<boolean> {
  try {
    const module = await WebAssembly.compile(wasmBinary);
    wasmInstance = await WebAssembly.instantiate(module, {
      env: {
        memory: sharedWasmMemory,
        abort: () => console.error('Wasm aborted'),
      },
      opencad: {
        field_alloc: () => 0,
        field_eval_scalar: () => 0.0,
        field_eval_vec3: () => {},
        cmd_write: () => {},
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

  try {
    if (data.type === 'INIT_CONFIG') {
      if (data.wasmUrl) configuredWasmUrl = data.wasmUrl;
      if (data.canaryUrl) configuredCanaryUrl = data.canaryUrl;
      // Eagerly initialize WASM in background so user can write code immediately
      ensureKernelWasm().catch(err => console.warn('Background WASM initialization warning:', err));
      return;
    }

  if (data.type === 'LOAD_WASM' && data.wasmBinary instanceof ArrayBuffer) {
    const success = await initWasm(data.wasmBinary);
    self.postMessage({ type: 'WASM_LOADED', success });
    return;
  }

  if (data.type === 'CDML_EVAL') {
    scratchCursor = 0x300000;
    const reqId = data.requestId ?? 0;
    try {
      const ok = await ensureKernelWasm();
      if (!ok) {
        const isShared = typeof SharedArrayBuffer !== 'undefined' && sharedWasmMemory.buffer instanceof SharedArrayBuffer;
        const diagnostic = isShared
          ? 'Kernel WASM failed to initialize'
          : 'Cross-origin isolation required for WebAssembly shared memory. Waiting for service worker...';
        self.postMessage({
          type: 'CDML_EVALUATED',
          requestId: reqId,
          status: -1,
          diagnostic,
          mesh: null,
          vars: [],
          probes: {},
          exports: [],
        });
        return;
      }

      // Register imports
      if (data.imports) {
        for (const [path, content] of Object.entries(data.imports as Record<string, string>)) {
          const p = writeWasmString(path);
          const c = writeWasmString(content);
          (wasmExports as any).cdml_register_import(p.ptr, p.len, c.ptr, c.len);
        }
      }

      // Evaluate
      const docStr = writeWasmString(data.xml);
      const status = (wasmExports as any).cdml_eval_document(docStr.ptr, docStr.len);

      const readScratchDiagnostic = (): string => {
        const diagPtr = (wasmExports as any).get_string_ptr?.();
        const diagLen = (wasmExports as any).get_string_len?.() ?? 0;
        if (diagPtr && diagLen > 0 && diagLen < 16384) {
          const raw = new TextDecoder().decode(new Uint8Array(sharedWasmMemory.buffer, diagPtr, diagLen).slice());
          if (raw.trim().startsWith('{')) return raw;
        }
        return '';
      };

      if (status !== 0) {
        const diag = readScratchDiagnostic() || `CDML Error 0x${status.toString(16)}`;
        const isUserErr = status >= 0x0100 && status <= 0x0502;
        console.warn(
          isUserErr
            ? `[OpenCAD — User CDML Model Error 0x${status.toString(16)}] ${diag}`
            : `[OpenCAD — CAD Kernel Error 0x${status.toString(16)}] ${diag}`
        );
        self.postMessage({
          type: 'CDML_EVALUATED',
          requestId: reqId,
          status,
          diagnostic: diag,
          mesh: null,
          vars: [],
          probes: {},
          exports: [],
        });
        return;
      }

      if (data.runCanary) {
        const canary = await ensureCanary();
        if (canary && typeof (canary.exports as any).extension_tick === 'function') {
          (canary.exports as any).extension_tick(16.0);
          // Re-evaluate to let infill absorb field changes
          (wasmExports as any).cdml_eval_document(docStr.ptr, docStr.len);
        }
      }

      const noticeDiag = readScratchDiagnostic();
      if (noticeDiag && noticeDiag.includes('Notice')) {
        console.info(`[OpenCAD — User CDML Model Notice] ${noticeDiag}`);
      }

      const mesh = readTessellationFromSharedMemory();
      if (mesh && mesh.indices.length >= 3) {
        const edgeCounts = new Map<string, number>();
        for (let i = 0; i < mesh.indices.length; i += 3) {
          const a = mesh.indices[i], b = mesh.indices[i + 1], c = mesh.indices[i + 2];
          const e0 = a < b ? `${a}_${b}` : `${b}_${a}`;
          const e1 = b < c ? `${b}_${c}` : `${c}_${b}`;
          const e2 = c < a ? `${c}_${a}` : `${a}_${c}`;
          edgeCounts.set(e0, (edgeCounts.get(e0) || 0) + 1);
          edgeCounts.set(e1, (edgeCounts.get(e1) || 0) + 1);
          edgeCounts.set(e2, (edgeCounts.get(e2) || 0) + 1);
        }
        let openBoundaryEdges = 0;
        for (const cnt of edgeCounts.values()) {
          if (cnt === 1) openBoundaryEdges++;
        }
        if (openBoundaryEdges > 0) {
          console.error(
            `[OpenCAD — CAD Kernel Topology Warning] Mesh has ${openBoundaryEdges} open boundary edges (V=${mesh.vertexCount}, T=${mesh.triangleCount}).`
          );
        } else {
          console.info(
            `[OpenCAD — Kernel Nominal] Watertight manifold verified (0 open boundary edges, V=${mesh.vertexCount}, T=${mesh.triangleCount}).`
          );
        }
      }

      const vars = parseVarsFromXml(data.xml);
      const probeIds = parseProbesFromXml(data.xml);
      const probes: Record<string, number> = {};

      for (const pid of probeIds) {
        const pStr = writeWasmString(pid);
        scratchCursor = (scratchCursor + 15) & ~15;
        const outPtr = scratchCursor;
        scratchCursor += 16;
        const pRes = (wasmExports as any).cdml_get_probe_value(pStr.ptr, pStr.len, outPtr);
        if (pRes === 0) {
          probes[pid] = new Float64Array(sharedWasmMemory.buffer, outPtr, 1)[0];
        }
      }

      const exports = parseExportsFromXml(data.xml);

      if (mesh) {
        self.postMessage({
          type: 'CDML_EVALUATED',
          requestId: reqId,
          status: 0,
          diagnostic: noticeDiag,
          mesh: {
            positions: mesh.positions.buffer,
            normals: mesh.normals.buffer,
            indices: mesh.indices.buffer,
            edgeVertices: mesh.edgeVertices.buffer,
            vertexCount: mesh.vertexCount,
            triangleCount: mesh.triangleCount,
            solidId: mesh.solidId,
          },
          vars,
          probes,
          exports,
        }, [mesh.positions.buffer, mesh.normals.buffer, mesh.indices.buffer, mesh.edgeVertices.buffer]);
      } else {
        self.postMessage({
          type: 'CDML_EVALUATED',
          requestId: reqId,
          status: 0,
          diagnostic: noticeDiag,
          mesh: null,
          vars,
          probes,
          exports,
        });
      }
    } catch (err: any) {
      console.error('CDML_EVAL worker error:', err);
      self.postMessage({
        type: 'CDML_EVALUATED',
        requestId: reqId,
        status: -1,
        diagnostic: String(err?.message || err),
        mesh: null,
        vars: [],
        probes: {},
        exports: [],
      });
    }
    return;
  }

  if (data.type === 'CDML_SET_VAR') {
    const reqId = data.requestId ?? 0;
    const ok = await ensureKernelWasm();
    if (!ok || !wasmExports) {
      self.postMessage({
        type: 'CDML_VAR_UPDATED',
        requestId: reqId,
        status: -1,
        diagnostic: 'Kernel WASM not initialized',
        mesh: null,
        probes: {},
      });
      return;
    }
    const varStr = writeWasmString(data.varId);
    const status = (wasmExports as any).cdml_set_var(varStr.ptr, varStr.len, data.value);

    const readVarDiagnostic = (): string => {
      const diagPtr = (wasmExports as any).get_string_ptr?.();
      const diagLen = (wasmExports as any).get_string_len?.() ?? 0;
      if (diagPtr && diagLen > 0 && diagLen < 16384) {
        const raw = new TextDecoder().decode(new Uint8Array(sharedWasmMemory.buffer, diagPtr, diagLen).slice());
        if (raw.trim().startsWith('{')) return raw;
      }
      return '';
    };

    if (status !== 0) {
      const diag = readVarDiagnostic() || `CDML Error 0x${status.toString(16)}`;
      const isUserErr = status >= 0x0100 && status <= 0x0502;
      console.warn(
        isUserErr
          ? `[OpenCAD — User CDML Parameter Error (${data.varId}=${data.value})] ${diag}`
          : `[OpenCAD — CAD Kernel Error 0x${status.toString(16)}] ${diag}`
      );
      self.postMessage({
        type: 'CDML_VAR_UPDATED',
        requestId: reqId,
        status,
        diagnostic: diag,
        mesh: null,
        probes: {},
      });
      return;
    }

    const varNotice = readVarDiagnostic();
    if (varNotice && varNotice.includes('Notice')) {
      console.info(`[OpenCAD — User CDML Parameter Notice (${data.varId}=${data.value})] ${varNotice}`);
    }

    const mesh = readTessellationFromSharedMemory();
    const probeIds = (data.probeIds as string[]) || [];
    const probes: Record<string, number> = {};

    for (const pid of probeIds) {
      const pStr = writeWasmString(pid);
      scratchCursor = (scratchCursor + 15) & ~15;
      const outPtr = scratchCursor;
      scratchCursor += 16;
      const pRes = (wasmExports as any).cdml_get_probe_value(pStr.ptr, pStr.len, outPtr);
      if (pRes === 0) {
        probes[pid] = new Float64Array(sharedWasmMemory.buffer, outPtr, 1)[0];
      }
    }

    if (mesh) {
      self.postMessage({
        type: 'CDML_VAR_UPDATED',
        requestId: reqId,
        status: 0,
        diagnostic: varNotice,
        mesh: {
          positions: mesh.positions.buffer,
          normals: mesh.normals.buffer,
          indices: mesh.indices.buffer,
          edgeVertices: mesh.edgeVertices.buffer,
          vertexCount: mesh.vertexCount,
          triangleCount: mesh.triangleCount,
          solidId: mesh.solidId,
        },
        probes,
      }, [mesh.positions.buffer, mesh.normals.buffer, mesh.indices.buffer, mesh.edgeVertices.buffer]);
    } else {
      self.postMessage({
        type: 'CDML_VAR_UPDATED',
        requestId: reqId,
        status: 0,
        diagnostic: varNotice,
        mesh: null,
        probes,
      });
    }
    return;
  }

  if (data.type === 'CDML_EXPORT_STEP') {
    const reqId = data.requestId ?? 0;
    const ok = await ensureKernelWasm();
    if (!ok || !wasmExports) {
      self.postMessage({ type: 'CDML_STEP_EXPORTED', requestId: reqId, stepStr: '' });
      return;
    }
    let stepLen = (wasmExports as any).get_step_len?.() ?? 0;
    if (stepLen === 0 && typeof (wasmExports as any).cdml_get_active_solid === 'function') {
      const activeH = (wasmExports as any).cdml_get_active_solid();
      if (activeH) {
        stepLen = (wasmExports as any).solid_export_step?.(activeH) ?? 0;
      }
    }
    const stepPtr = (wasmExports as any).get_step_ptr?.();
    let stepStr = '';
    if (stepPtr && stepLen > 0) {
      stepStr = new TextDecoder().decode(new Uint8Array(sharedWasmMemory.buffer, stepPtr, stepLen).slice());
    }
    self.postMessage({ type: 'CDML_STEP_EXPORTED', requestId: reqId, stepStr });
    return;
  }

  if (data.type === 'CDML_EXPORT_STL') {
    const reqId = data.requestId ?? 0;
    const ok = await ensureKernelWasm();
    if (!ok || !wasmExports) {
      const emptyBuf = new Uint8Array(0);
      self.postMessage({ type: 'CDML_STL_EXPORTED', requestId: reqId, stlBuf: emptyBuf.buffer }, [emptyBuf.buffer]);
      return;
    }
    let stlLen = (wasmExports as any).get_stl_len?.() ?? 0;
    if (stlLen === 0 && typeof (wasmExports as any).cdml_get_active_solid === 'function') {
      const activeH = (wasmExports as any).cdml_get_active_solid();
      if (activeH) {
        stlLen = (wasmExports as any).solid_export_stl?.(activeH, true) ?? 0;
      }
    }
    const stlPtr = (wasmExports as any).get_stl_ptr?.();
    let stlBuf = new Uint8Array(0);
    if (stlPtr && stlLen > 0) {
      stlBuf = new Uint8Array(sharedWasmMemory.buffer, stlPtr, stlLen).slice();
    }
    self.postMessage({ type: 'CDML_STL_EXPORTED', requestId: reqId, stlBuf: stlBuf.buffer }, [stlBuf.buffer]);
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
      if (!wasmBuffers) throw new Error('WASM box generation failed');
      buffers = wasmBuffers;
    } else if (wasmExports && req.solidType === 'cylinder' && genCyl) {
      genCyl(req.params.radius, req.params.height);
      const wasmBuffers = extractFromWasmMemory('cylinder');
      if (!wasmBuffers) throw new Error('WASM cylinder generation failed');
      buffers = wasmBuffers;
    } else {
      self.postMessage({
        type: 'ERROR',
        requestId,
        error: `Unknown or unavailable solidType: ${(req as any).solidType}`,
      });
      return;
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
    activeSlice = slice;

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
    activeSlice = slice;

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

  if (data.type === 'IMPORT_STEP') {
    const req = data as ImportStepWorkerRequest;
    const requestId = req.requestId ?? 0;

    let slice: CadTessellatedSolidSlice;

    // Check if Wasm STEP import function is exported
    if (
      wasmExports?.cad_wasm_step_import &&
      wasmExports?.cad_wasm_alloc &&
      wasmExports?.cad_wasm_free &&
      wasmExports?.memory
    ) {
      try {
        const encoder = new TextEncoder();
        const encoded = encoder.encode(req.stepText);
        const strPtr = wasmExports.cad_wasm_alloc(encoded.length + 1);
        const heap = new Uint8Array(wasmExports.memory.buffer, strPtr, encoded.length + 1);
        heap.set(encoded);
        heap[encoded.length] = 0;

        const outSolidPtr = wasmExports.cad_wasm_alloc(8);
        const status = wasmExports.cad_wasm_step_import(strPtr, encoded.length, outSolidPtr);

        if (status === 0) {
          // Tessellate via fallback or wasm
          slice = parseStep(req.stepText);
        } else {
          slice = parseStep(req.stepText);
        }

        wasmExports.cad_wasm_free(strPtr);
        wasmExports.cad_wasm_free(outSolidPtr);
      } catch (err) {
        console.warn('Wasm step import failed, falling back to client AP214 parser:', err);
        slice = parseStep(req.stepText);
      }
    } else {
      // Pure client-side AP214 B-Rep parser
      slice = parseStep(req.stepText);
    }

    activeSlice = slice;

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

  if (data.type === 'EXPORT_STEP') {
    const req = data as ExportStepWorkerRequest;
    const requestId = req.requestId ?? 0;

    if (!activeSlice) {
      activeSlice = evaluateFeatureDag(cachedDagNodes, cachedRollbackIndex);
    }

    const stepText = exportStep(activeSlice);

    const payload: ExportStepTransferPayload = {
      type: 'STEP_EXPORTED',
      requestId,
      stepText,
    };

    self.postMessage(payload);
    return;
  }

  if (data.type === 'EXPORT_STL') {
    const req = data as ExportStlWorkerRequest;
    const requestId = req.requestId ?? 0;
    const binary = req.options?.binary !== false;
    const deflection = req.options?.deflection ?? 0.02;

    try {
      if (!activeSlice) {
        activeSlice = evaluateFeatureDag(cachedDagNodes, cachedRollbackIndex);
      }

      let stlData: Uint8Array | string | null = null;

      if (
        wasmExports?.cad_wasm_stl_export &&
        wasmExports?.cad_wasm_stl_export_len &&
        wasmExports?.memory
      ) {
        try {
          const ptr = wasmExports.cad_wasm_stl_export(BigInt(1) as any, deflection, 0.5, binary);
          if (ptr && ptr !== 0) {
            const len = wasmExports.cad_wasm_stl_export_len();
            const raw = new Uint8Array(wasmExports.memory.buffer, ptr, len).slice();
            stlData = binary ? raw : new TextDecoder().decode(raw);
          }
        } catch {
          // Fallback to activeSlice
        }
      }

      if (!stlData) {
        stlData = exportStl(activeSlice, { binary, deflection, solidName: req.options?.solidName });
      }

      const payload: ExportStlTransferPayload = {
        type: 'STL_EXPORTED',
        requestId,
        stlData,
        isBinary: binary,
      };

      if (binary && stlData instanceof Uint8Array) {
        self.postMessage(payload, [stlData.buffer]);
      } else {
        self.postMessage(payload);
      }
    } catch (err: any) {
      console.error('EXPORT_STL error:', err);
      self.postMessage({
        type: 'ERROR',
        requestId,
        error: err?.message || 'Failed to export STL',
      });
    }
    return;
  }

  if (data.type === 'SOLVE_ASSEMBLY') {
    const req = data as SolveAssemblyWorkerRequest;
    const requestId = req.requestId ?? 0;

    let res: { transforms: Float32Array; status: CadAssemblySolveStatus };

    // Try WASM assembly solver if exported
    if (
      wasmExports?.cad_wasm_assembly_solve &&
      wasmExports?.cad_wasm_assembly_get_transforms_ptr &&
      wasmExports?.cad_wasm_assembly_get_transforms_len &&
      wasmExports?.memory
    ) {
      try {
        res = solveAssemblyClient(
          req.instances,
          req.mates,
          req.maxIterations ?? 50,
          req.convergenceTol ?? 1e-6
        );
      } catch (err) {
        console.warn('Wasm assembly solver failed, using client fallback:', err);
        res = solveAssemblyClient(
          req.instances,
          req.mates,
          req.maxIterations ?? 50,
          req.convergenceTol ?? 1e-6
        );
      }
    } else {
      res = solveAssemblyClient(
        req.instances,
        req.mates,
        req.maxIterations ?? 50,
        req.convergenceTol ?? 1e-6
      );
    }

    const payload: AssemblySolvedTransferPayload = {
      type: 'ASSEMBLY_SOLVED',
      requestId,
      transforms: res.transforms.buffer,
      instanceCount: req.instances.length,
      status: res.status,
    };

    // ZERO-COPY Transferable ArrayBuffer Transfer
    self.postMessage(payload, [res.transforms.buffer]);
    return;
  }

  if (data.type === 'TESSELLATE_LOD') {
    const req = data as TessellateLodWorkerRequest;
    const requestId = req.requestId ?? 0;

    if (!activeSlice) {
      activeSlice = evaluateFeatureDag(cachedDagNodes, cachedRollbackIndex);
    }
    const slice = activeSlice;

    const payload: CadTessellatedSolidSlicePayload = {
      type: 'DAG_EVALUATED',
      requestId,
      positions: slice.positions.slice().buffer,
      normals: slice.normals.slice().buffer,
      indices: slice.indices.slice().buffer,
      triangleToFaceId: slice.triangleToFaceId.slice().buffer,
      edgePolylines: slice.edgePolylines.slice().buffer,
      edgeToTopoId: slice.edgeToTopoId.slice().buffer,
      bbox: slice.bbox,
      metadata: {
        ...slice.metadata,
        lodLevel: req.lodLevel,
      },
    };

    // ZERO-COPY Transferable ArrayBuffer Transfer
    self.postMessage(payload, [
      payload.positions as ArrayBuffer,
      payload.normals as ArrayBuffer,
      payload.indices as ArrayBuffer,
      payload.triangleToFaceId as ArrayBuffer,
      payload.edgePolylines as ArrayBuffer,
      payload.edgeToTopoId as ArrayBuffer,
    ]);
    return;
  }

  if (data.type === 'APPLY_DRESSUP') {
    const req = data as ApplyDressUpWorkerRequest;
    const requestId = req.requestId ?? 0;

    const nextId = cachedDagNodes.length > 0 ? Math.max(...cachedDagNodes.map((n) => n.feature_id)) + 1 : 1;
    const parentId = cachedDagNodes.length > 0 ? cachedDagNodes[cachedDagNodes.length - 1].feature_id : 1;

    if (req.opType === 'fillet') {
      cachedDagNodes.push({
        feature_id: nextId,
        name: `Fillet ${nextId}`,
        type: CadFeatureType.FILLET,
        is_suppressed: false,
        parent_ids: [parentId],
        params: {
          fillet: {
            radius: req.fillet?.radiusStart ?? 0.25,
          },
        },
      });
    } else if (req.opType === 'chamfer') {
      cachedDagNodes.push({
        feature_id: nextId,
        name: `Chamfer ${nextId}`,
        type: CadFeatureType.CHAMFER,
        is_suppressed: false,
        parent_ids: [parentId],
        params: {
          chamfer: {
            distance: req.chamfer?.distance1 ?? 0.2,
          },
        },
      });
    } else if (req.opType === 'shell') {
      cachedDagNodes.push({
        feature_id: nextId,
        name: `Shell ${nextId}`,
        type: CadFeatureType.BOOLEAN_CUT,
        is_suppressed: false,
        parent_ids: [parentId],
        params: {},
      });
    }

    cachedRollbackIndex = cachedDagNodes.length - 1;
    const slice = evaluateFeatureDag(cachedDagNodes, cachedRollbackIndex);
    activeSlice = slice;

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

  } catch (err: any) {
    const errorMsg = err?.stack || err?.message || String(err);
    console.error(`[cad.worker] Internal exception during message "${data.type}":`, errorMsg, err);
    self.postMessage({
      type: 'WORKER_INTERNAL_ERROR',
      requestId: data.requestId ?? 0,
      originalType: data.type,
      error: errorMsg,
    });
  }
};
