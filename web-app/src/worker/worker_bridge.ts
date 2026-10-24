import {
  BoxParams,
  CadMeshRawBuffers,
  CadMeshTransferPayload,
  CadSolverStatus,
  CylinderParams,
  SolidGenerationRequest,
  SolveSketchTransferPayload,
  SolveSketchWorkerRequest,
  CadFeatureNode,
  CadTessellatedSolidSlice,
  CadTessellatedSolidSlicePayload,
  EvaluateDagWorkerRequest,
  SetRollbackIndexWorkerRequest,
  ImportStepWorkerRequest,
  ExportStepWorkerRequest,
  ExportStlWorkerRequest,
  SolveAssemblyWorkerRequest,
  AssemblySolvedTransferPayload,
  CadAssemblySolveStatus,
  CadLodLevel,
  TessellateLodWorkerRequest,
  ApplyDressUpWorkerRequest,
} from '../types/cad';

export class CadWorkerBridge {
  private worker: Worker;
  private pendingRequests = new Map<
    number,
    {
      resolve: (value: CadMeshRawBuffers) => void;
      reject: (reason?: any) => void;
    }
  >();
  private pendingSketchRequests = new Map<
    number,
    {
      resolve: (value: CadSolverStatus) => void;
      reject: (reason?: any) => void;
    }
  >();
  private pendingDagRequests = new Map<
    number,
    {
      resolve: (value: CadTessellatedSolidSlice) => void;
      reject: (reason?: any) => void;
    }
  >();
  private pendingExportStepRequests = new Map<
    number,
    {
      resolve: (value: string) => void;
      reject: (reason?: any) => void;
    }
  >();
  private pendingExportStlRequests = new Map<
    number,
    {
      resolve: (value: Uint8Array | string) => void;
      reject: (reason?: any) => void;
    }
  >();
  private pendingAssemblyRequests = new Map<
    number,
    {
      resolve: (value: {
        transforms: Float32Array;
        instanceCount: number;
        status: CadAssemblySolveStatus;
      }) => void;
      reject: (reason?: any) => void;
    }
  >();
  private pendingAstCountRequests = new Map<number, { resolve: (val: number) => void; reject: (err: any) => void }>();
  private pendingAstFormatRequests = new Map<number, { resolve: (val: string) => void; reject: (err: any) => void }>();
  private pendingAstMergeRequests = new Map<
    number,
    { resolve: (val: { mergedScript: string; conflictCount: number }) => void; reject: (err: any) => void }
  >();
  private pendingVisualDiffRequests = new Map<number, { resolve: (val: any) => void; reject: (err: any) => void }>();
  private nextRequestId = 1;

  constructor() {
    this.worker = new Worker(new URL('./cad.worker.ts', import.meta.url), {
      type: 'module',
    });

    this.worker.onmessage = this.handleMessage.bind(this);
    this.worker.onerror = this.handleError.bind(this);
  }

  private handleMessage(e: MessageEvent) {
    const data = e.data;
    if (!data || typeof data !== 'object') return;

    if (data.type === 'GEOMETRY_READY') {
      const payload = data as CadMeshTransferPayload;
      const requestId = payload.requestId ?? 0;
      const pending = this.pendingRequests.get(requestId);

      if (pending) {
        this.pendingRequests.delete(requestId);

        // Convert transferred raw ArrayBuffers back into TypedArray views in O(1)
        const rawBuffers: CadMeshRawBuffers = {
          positions: new Float32Array(payload.positions),
          normals: new Float32Array(payload.normals),
          indices: new Uint32Array(payload.indices),
          triangleToFaceId: new Uint32Array(payload.triangleToFaceId),
          edgeVertices: new Float32Array(payload.edgeVertices),
          edgeIds: new Uint32Array(payload.edgeIds),
          metadata: payload.metadata,
        };

        pending.resolve(rawBuffers);
      }
    } else if (data.type === 'DAG_EVALUATED') {
      const payload = data as CadTessellatedSolidSlicePayload;
      const requestId = payload.requestId ?? 0;
      const pending = this.pendingDagRequests.get(requestId);

      if (pending) {
        this.pendingDagRequests.delete(requestId);

        // Convert transferred ArrayBuffers directly to 64-bit TypedArray views in O(1)
        const slice: CadTessellatedSolidSlice = {
          positions: new Float32Array(payload.positions),
          normals: new Float32Array(payload.normals),
          indices: new Uint32Array(payload.indices),
          triangleToFaceId: new BigUint64Array(payload.triangleToFaceId),
          edgePolylines: new Float32Array(payload.edgePolylines),
          edgeToTopoId: new BigUint64Array(payload.edgeToTopoId),
          bbox: payload.bbox,
          metadata: payload.metadata,
        };

        pending.resolve(slice);
      }
    } else if (data.type === 'SKETCH_SOLVED') {
      const payload = data as SolveSketchTransferPayload;
      const requestId = payload.requestId ?? 0;
      const pending = this.pendingSketchRequests.get(requestId);

      if (pending) {
        this.pendingSketchRequests.delete(requestId);

        // Convert transferred ArrayBuffers directly to TypedArrays with zero copying
        const status: CadSolverStatus = {
          solve_state: payload.solve_state,
          degrees_of_freedom: payload.degrees_of_freedom,
          iterations: payload.iterations,
          max_residual: payload.max_residual,
          updated_coords: new Float64Array(payload.coordsBuffer),
          coord_count: payload.coord_count,
          conflicting_constraint_ids: new Uint32Array(payload.conflictingIdsBuffer),
          conflicting_count: payload.conflicting_count,
        };

        pending.resolve(status);
      }
    } else if (data.type === 'STEP_EXPORTED') {
      const payload = data as { requestId?: number; stepText: string };
      const requestId = payload.requestId ?? 0;
      const pending = this.pendingExportStepRequests.get(requestId);
      if (pending) {
        this.pendingExportStepRequests.delete(requestId);
        pending.resolve(payload.stepText);
      }
    } else if (data.type === 'STL_EXPORTED') {
      const payload = data as { requestId?: number; stlData: Uint8Array | string; isBinary: boolean };
      const requestId = payload.requestId ?? 0;
      const pending = this.pendingExportStlRequests.get(requestId);
      if (pending) {
        this.pendingExportStlRequests.delete(requestId);
        pending.resolve(payload.stlData);
      }
    } else if (data.type === 'ASSEMBLY_SOLVED') {
      const payload = data as AssemblySolvedTransferPayload;
      const requestId = payload.requestId ?? 0;
      const pending = this.pendingAssemblyRequests.get(requestId);
      if (pending) {
        this.pendingAssemblyRequests.delete(requestId);
        pending.resolve({
          transforms: new Float32Array(payload.transforms),
          instanceCount: payload.instanceCount,
          status: payload.status,
        });
      }
    } else if (data.type === 'AST_PARSE_COUNT_RESULT') {
      const requestId = data.requestId ?? 0;
      const pending = this.pendingAstCountRequests.get(requestId);
      if (pending) {
        this.pendingAstCountRequests.delete(requestId);
        pending.resolve(data.count ?? 0);
      }
    } else if (data.type === 'AST_FORMAT_RESULT') {
      const requestId = data.requestId ?? 0;
      const pending = this.pendingAstFormatRequests.get(requestId);
      if (pending) {
        this.pendingAstFormatRequests.delete(requestId);
        pending.resolve(data.formatted ?? '');
      }
    } else if (data.type === 'AST_MERGE_3WAY_RESULT') {
      const requestId = data.requestId ?? 0;
      const pending = this.pendingAstMergeRequests.get(requestId);
      if (pending) {
        this.pendingAstMergeRequests.delete(requestId);
        pending.resolve({
          mergedScript: data.mergedScript ?? '',
          conflictCount: data.conflictCount ?? 0,
        });
      }
    } else if (data.type === 'VISUAL_DIFF_RESULT') {
      const requestId = data.requestId ?? 0;
      const pending = this.pendingVisualDiffRequests.get(requestId);
      if (pending) {
        this.pendingVisualDiffRequests.delete(requestId);
        const raw = data.diff;
        pending.resolve({
          addedPositions: raw?.addedPositions ? new Float32Array(raw.addedPositions) : undefined,
          addedIndices: raw?.addedIndices ? new Uint32Array(raw.addedIndices) : undefined,
          removedPositions: raw?.removedPositions ? new Float32Array(raw.removedPositions) : undefined,
          removedIndices: raw?.removedIndices ? new Uint32Array(raw.removedIndices) : undefined,
          summary: raw?.summary,
        });
      }
    } else if (data.type === 'ERROR') {
      const requestId = data.requestId ?? 0;
      const pending = this.pendingRequests.get(requestId);
      if (pending) {
        this.pendingRequests.delete(requestId);
        pending.reject(new Error(data.error || 'Worker generation error'));
      }
      const pendingSketch = this.pendingSketchRequests.get(requestId);
      if (pendingSketch) {
        this.pendingSketchRequests.delete(requestId);
        pendingSketch.reject(new Error(data.error || 'Worker sketch error'));
      }
      const pendingDag = this.pendingDagRequests.get(requestId);
      if (pendingDag) {
        this.pendingDagRequests.delete(requestId);
        pendingDag.reject(new Error(data.error || 'Worker DAG error'));
      }
      const pendingExport = this.pendingExportStepRequests.get(requestId);
      if (pendingExport) {
        this.pendingExportStepRequests.delete(requestId);
        pendingExport.reject(new Error(data.error || 'Worker STEP export error'));
      }
      const pendingExportStl = this.pendingExportStlRequests.get(requestId);
      if (pendingExportStl) {
        this.pendingExportStlRequests.delete(requestId);
        pendingExportStl.reject(new Error(data.error || 'Worker STL export error'));
      }
      const pendingAssembly = this.pendingAssemblyRequests.get(requestId);
      if (pendingAssembly) {
        this.pendingAssemblyRequests.delete(requestId);
        pendingAssembly.reject(new Error(data.error || 'Worker assembly error'));
      }
    }
  }

  private handleError(e: ErrorEvent) {
    console.error('CAD Worker error:', e);
    for (const [id, req] of this.pendingRequests.entries()) {
      req.reject(new Error(`Worker encountered error: ${e.message}`));
      this.pendingRequests.delete(id);
    }
    for (const [id, req] of this.pendingSketchRequests.entries()) {
      req.reject(new Error(`Worker encountered error: ${e.message}`));
      this.pendingSketchRequests.delete(id);
    }
    for (const [id, req] of this.pendingDagRequests.entries()) {
      req.reject(new Error(`Worker encountered error: ${e.message}`));
      this.pendingDagRequests.delete(id);
    }
    for (const [id, req] of this.pendingExportStepRequests.entries()) {
      req.reject(new Error(`Worker encountered error: ${e.message}`));
      this.pendingExportStepRequests.delete(id);
    }
    for (const [id, req] of this.pendingExportStlRequests.entries()) {
      req.reject(new Error(`Worker encountered error: ${e.message}`));
      this.pendingExportStlRequests.delete(id);
    }
    for (const [id, req] of this.pendingAssemblyRequests.entries()) {
      req.reject(new Error(`Worker encountered error: ${e.message}`));
      this.pendingAssemblyRequests.delete(id);
    }
    for (const [id, req] of this.pendingAstCountRequests.entries()) {
      req.reject(new Error(`Worker encountered error: ${e.message}`));
      this.pendingAstCountRequests.delete(id);
    }
    for (const [id, req] of this.pendingAstFormatRequests.entries()) {
      req.reject(new Error(`Worker encountered error: ${e.message}`));
      this.pendingAstFormatRequests.delete(id);
    }
    for (const [id, req] of this.pendingAstMergeRequests.entries()) {
      req.reject(new Error(`Worker encountered error: ${e.message}`));
      this.pendingAstMergeRequests.delete(id);
    }
    for (const [id, req] of this.pendingVisualDiffRequests.entries()) {
      req.reject(new Error(`Worker encountered error: ${e.message}`));
      this.pendingVisualDiffRequests.delete(id);
    }
  }

  public async evaluateDag(
    nodes: CadFeatureNode[],
    rollbackIndex: number
  ): Promise<CadTessellatedSolidSlice> {
    const requestId = this.nextRequestId++;

    return new Promise<CadTessellatedSolidSlice>((resolve, reject) => {
      this.pendingDagRequests.set(requestId, { resolve, reject });
      const req: EvaluateDagWorkerRequest = {
        type: 'EVALUATE_DAG',
        requestId,
        nodes,
        rollbackIndex,
      };
      this.worker.postMessage(req);
    });
  }

  public async setRollbackIndex(rollbackIndex: number): Promise<CadTessellatedSolidSlice> {
    const requestId = this.nextRequestId++;

    return new Promise<CadTessellatedSolidSlice>((resolve, reject) => {
      this.pendingDagRequests.set(requestId, { resolve, reject });
      const req: SetRollbackIndexWorkerRequest = {
        type: 'SET_ROLLBACK_INDEX',
        requestId,
        rollbackIndex,
      };
      this.worker.postMessage(req);
    });
  }

  public async importStep(stepText: string): Promise<CadTessellatedSolidSlice> {
    const requestId = this.nextRequestId++;

    return new Promise<CadTessellatedSolidSlice>((resolve, reject) => {
      this.pendingDagRequests.set(requestId, { resolve, reject });
      const req: ImportStepWorkerRequest = {
        type: 'IMPORT_STEP',
        requestId,
        stepText,
      };
      this.worker.postMessage(req);
    });
  }

  public async exportStep(): Promise<string> {
    const requestId = this.nextRequestId++;

    return new Promise<string>((resolve, reject) => {
      this.pendingExportStepRequests.set(requestId, { resolve, reject });
      const req: ExportStepWorkerRequest = {
        type: 'EXPORT_STEP',
        requestId,
      };
      this.worker.postMessage(req);
    });
  }

  public async exportStl(options?: {
    binary?: boolean;
    deflection?: number;
    solidName?: string;
  }): Promise<Uint8Array | string> {
    const requestId = this.nextRequestId++;

    return new Promise<Uint8Array | string>((resolve, reject) => {
      this.pendingExportStlRequests.set(requestId, { resolve, reject });
      const req: ExportStlWorkerRequest = {
        type: 'EXPORT_STL',
        requestId,
        options,
      };
      this.worker.postMessage(req);
    });
  }

  public async generateSolid(request: SolidGenerationRequest): Promise<CadMeshRawBuffers> {
    const requestId = this.nextRequestId++;

    return new Promise<CadMeshRawBuffers>((resolve, reject) => {
      this.pendingRequests.set(requestId, { resolve, reject });
      this.worker.postMessage({
        ...request,
        requestId,
        type: 'GENERATE',
      });
    });
  }

  public async generateBox(params: BoxParams): Promise<CadMeshRawBuffers> {
    return this.generateSolid({ solidType: 'box', params });
  }

  public async generateCylinder(params: CylinderParams): Promise<CadMeshRawBuffers> {
    return this.generateSolid({ solidType: 'cylinder', params });
  }

  public async solveSketch(
    request: Omit<SolveSketchWorkerRequest, 'type' | 'requestId'>
  ): Promise<CadSolverStatus> {
    const requestId = this.nextRequestId++;

    return new Promise<CadSolverStatus>((resolve, reject) => {
      this.pendingSketchRequests.set(requestId, { resolve, reject });
      this.worker.postMessage({
        ...request,
        requestId,
        type: 'SOLVE_SKETCH',
      });
    });
  }

  public async loadWasmBinary(wasmBinary: ArrayBuffer): Promise<boolean> {
    return new Promise<boolean>((resolve) => {
      const handler = (e: MessageEvent) => {
        if (e.data?.type === 'WASM_LOADED') {
          this.worker.removeEventListener('message', handler);
          resolve(!!e.data.success);
        }
      };
      this.worker.addEventListener('message', handler);
      this.worker.postMessage({ type: 'LOAD_WASM', wasmBinary }, [wasmBinary]);
    });
  }

  public async solveAssembly(
    request: Omit<SolveAssemblyWorkerRequest, 'type' | 'requestId'>
  ): Promise<{
    transforms: Float32Array;
    instanceCount: number;
    status: CadAssemblySolveStatus;
  }> {
    const requestId = this.nextRequestId++;

    return new Promise((resolve, reject) => {
      this.pendingAssemblyRequests.set(requestId, { resolve, reject });
      const req: SolveAssemblyWorkerRequest = {
        type: 'SOLVE_ASSEMBLY',
        requestId,
        ...request,
      };
      this.worker.postMessage(req);
    });
  }

  public async tessellateLod(
    lodLevel: CadLodLevel,
    solidHandle?: number
  ): Promise<CadTessellatedSolidSlice> {
    const requestId = this.nextRequestId++;

    return new Promise<CadTessellatedSolidSlice>((resolve, reject) => {
      this.pendingDagRequests.set(requestId, { resolve, reject });
      const req: TessellateLodWorkerRequest = {
        type: 'TESSELLATE_LOD',
        requestId,
        lodLevel,
        solidHandle,
      };
      this.worker.postMessage(req);
    });
  }

  public async applyDressUp(
    request: Omit<ApplyDressUpWorkerRequest, 'type' | 'requestId'>
  ): Promise<CadTessellatedSolidSlice> {
    const requestId = this.nextRequestId++;

    return new Promise<CadTessellatedSolidSlice>((resolve, reject) => {
      this.pendingDagRequests.set(requestId, { resolve, reject });
      const req: ApplyDressUpWorkerRequest = {
        type: 'APPLY_DRESSUP',
        requestId,
        ...request,
      };
      this.worker.postMessage(req);
    });
  }

  public async loadPluginWasm(pluginId: string, wasmBinary: ArrayBuffer): Promise<boolean> {
    return new Promise<boolean>((resolve) => {
      const handler = (e: MessageEvent) => {
        if (e.data?.type === 'PLUGIN_WASM_LOADED' && e.data?.pluginId === pluginId) {
          this.worker.removeEventListener('message', handler);
          resolve(!!e.data.success);
        }
      };
      this.worker.addEventListener('message', handler);
      this.worker.postMessage({ type: 'LOAD_PLUGIN_WASM', pluginId, wasmBinary }, [wasmBinary]);
    });
  }

  public async parseAstCount(source: string): Promise<number> {
    const requestId = this.nextRequestId++;
    return new Promise<number>((resolve, reject) => {
      this.pendingAstCountRequests.set(requestId, { resolve, reject });
      this.worker.postMessage({ type: 'AST_PARSE_COUNT', requestId, source });
    });
  }

  public async formatAst(source: string): Promise<string> {
    const requestId = this.nextRequestId++;
    return new Promise<string>((resolve, reject) => {
      this.pendingAstFormatRequests.set(requestId, { resolve, reject });
      this.worker.postMessage({ type: 'AST_FORMAT', requestId, source });
    });
  }

  public async mergeAst3Way(
    base: string,
    ours: string,
    theirs: string
  ): Promise<{ mergedScript: string; conflictCount: number }> {
    const requestId = this.nextRequestId++;
    return new Promise((resolve, reject) => {
      this.pendingAstMergeRequests.set(requestId, { resolve, reject });
      this.worker.postMessage({ type: 'AST_MERGE_3WAY', requestId, base, ours, theirs });
    });
  }

  public async computeVisualDiff(
    baseNodes: CadFeatureNode[],
    targetNodes: CadFeatureNode[]
  ): Promise<any> {
    const requestId = this.nextRequestId++;
    return new Promise((resolve, reject) => {
      this.pendingVisualDiffRequests.set(requestId, { resolve, reject });
      this.worker.postMessage({ type: 'COMPUTE_VISUAL_DIFF', requestId, baseNodes, targetNodes });
    });
  }

  public terminate(): void {
    this.worker.terminate();
    this.pendingRequests.clear();
    this.pendingSketchRequests.clear();
    this.pendingDagRequests.clear();
    this.pendingExportStepRequests.clear();
    this.pendingExportStlRequests.clear();
    this.pendingAssemblyRequests.clear();
    this.pendingAstCountRequests.clear();
    this.pendingAstFormatRequests.clear();
    this.pendingAstMergeRequests.clear();
    this.pendingVisualDiffRequests.clear();
  }
}
