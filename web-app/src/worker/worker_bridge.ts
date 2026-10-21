import {
  BoxParams,
  CadMeshRawBuffers,
  CadMeshTransferPayload,
  CylinderParams,
  SolidGenerationRequest,
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
    } else if (data.type === 'ERROR') {
      const requestId = data.requestId ?? 0;
      const pending = this.pendingRequests.get(requestId);
      if (pending) {
        this.pendingRequests.delete(requestId);
        pending.reject(new Error(data.error || 'Worker generation error'));
      }
    }
  }

  private handleError(e: ErrorEvent) {
    console.error('CAD Worker error:', e);
    for (const [id, req] of this.pendingRequests.entries()) {
      req.reject(new Error(`Worker encountered error: ${e.message}`));
      this.pendingRequests.delete(id);
    }
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
