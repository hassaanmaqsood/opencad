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

  public terminate(): void {
    this.worker.terminate();
    this.pendingRequests.clear();
  }
}
