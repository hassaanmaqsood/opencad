/**
 * @file kernel.ts
 * Standalone OpenCAD Core Kernel Client for Web, Node.js, Bun, and CLI.
 */

import { loadCoreWasm, type WasmBinarySource } from './loader.js';
import {
  CadStatus,
  CadLodLevel,
  CadSolveState,
  type CadSolidHandle,
  type CadMesh,
  type CadTessellatedSolidSlice,
  type CadKernelLimits,
  type CadCoreWasmExports,
  type CadFeatureNode,
  type CadAssemblyInstance,
  type CadAssemblyMate,
  type CadAssemblySolveResult,
} from './types.js';

export class OpenCadKernel {
  private exports: CadCoreWasmExports;
  private isInitialized = false;

  constructor(exports: CadCoreWasmExports) {
    this.exports = exports;
  }

  public static async create(source?: WasmBinarySource): Promise<OpenCadKernel> {
    const bundle = await loadCoreWasm(source);
    const kernel = new OpenCadKernel(bundle.exports);
    kernel.init();
    return kernel;
  }

  public init(): void {
    if (this.isInitialized) return;
    if (this.exports.cad_kernel_init) {
      const st = this.exports.cad_kernel_init();
      if (st !== CadStatus.Ok) {
        throw new Error(`cad_kernel_init failed with status code ${st}`);
      }
    }
    this.isInitialized = true;
  }

  public deinit(): void {
    if (!this.isInitialized) return;
    if (this.exports.cad_kernel_deinit) {
      this.exports.cad_kernel_deinit();
    }
    this.isInitialized = false;
  }

  public createBox(dx: number, dy: number, dz: number): CadSolidHandle {
    this.assertInitialized();
    const outPtr = this.allocU64();
    try {
      const st = this.exports.cad_primitive_box!(dx, dy, dz, outPtr);
      if (st !== CadStatus.Ok) {
        throw new Error(`cad_primitive_box failed with status ${st}`);
      }
      return this.readU64(outPtr);
    } finally {
      this.free(outPtr, 8);
    }
  }

  public createCylinder(radius: number, height: number): CadSolidHandle {
    this.assertInitialized();
    const outPtr = this.allocU64();
    try {
      const st = this.exports.cad_primitive_cylinder!(radius, height, outPtr);
      if (st !== CadStatus.Ok) {
        throw new Error(`cad_primitive_cylinder failed with status ${st}`);
      }
      return this.readU64(outPtr);
    } finally {
      this.free(outPtr, 8);
    }
  }

  public createSphere(radius: number): CadSolidHandle {
    this.assertInitialized();
    const outPtr = this.allocU64();
    try {
      const st = this.exports.cad_primitive_sphere!(radius, outPtr);
      if (st !== CadStatus.Ok) {
        throw new Error(`cad_primitive_sphere failed with status ${st}`);
      }
      return this.readU64(outPtr);
    } finally {
      this.free(outPtr, 8);
    }
  }

  public releaseSolid(handle: CadSolidHandle): void {
    this.assertInitialized();
    this.exports.cad_solid_release!(handle);
  }

  public tessellate(handle: CadSolidHandle, chordalTol = 0.1, angularTol = 0.2): CadMesh {
    this.assertInitialized();
    const meshPtr = this.alloc(32);
    try {
      const st = this.exports.cad_solid_tessellate!(handle, chordalTol, angularTol, meshPtr);
      if (st !== CadStatus.Ok) {
        throw new Error(`cad_solid_tessellate failed with status ${st}`);
      }

      const mem = this.exports.memory.buffer;
      const view = new DataView(mem);
      const posPtr = view.getUint32(meshPtr, true);
      const vCount = view.getUint32(meshPtr + 4, true);
      const normPtr = view.getUint32(meshPtr + 8, true);
      const idxPtr = view.getUint32(meshPtr + 12, true);
      const triCount = view.getUint32(meshPtr + 16, true);

      const positions = new Float32Array(mem, posPtr, vCount * 3).slice();
      const normals = new Float32Array(mem, normPtr, vCount * 3).slice();
      const indices = new Uint32Array(mem, idxPtr, triCount * 3).slice();

      if (this.exports.cad_mesh_free) {
        this.exports.cad_mesh_free(meshPtr);
      }

      return {
        positions,
        normals,
        indices,
        vertexCount: vCount,
        triangleCount: triCount,
      };
    } finally {
      this.free(meshPtr, 32);
    }
  }

  public exportStep(handle: CadSolidHandle): string {
    this.assertInitialized();
    if (!this.exports.cad_wasm_step_export || !this.exports.cad_wasm_step_export_len) {
      throw new Error('STEP export not supported by current WASM build');
    }
    const ptr = this.exports.cad_wasm_step_export(handle);
    const len = this.exports.cad_wasm_step_export_len();
    if (!ptr || len === 0) return '';
    const bytes = new Uint8Array(this.exports.memory.buffer, ptr, len);
    return new TextDecoder().decode(bytes);
  }

  public importStep(stepText: string): CadSolidHandle {
    this.assertInitialized();
    if (!this.exports.cad_wasm_step_import) {
      throw new Error('STEP import not supported by current WASM build');
    }
    const encoder = new TextEncoder();
    const encoded = encoder.encode(stepText);
    const ptr = this.alloc(encoded.length);
    try {
      new Uint8Array(this.exports.memory.buffer, ptr, encoded.length).set(encoded);
      const handle = this.exports.cad_wasm_step_import(ptr, encoded.length);
      if (handle === 0) {
        throw new Error('Failed to parse STEP file');
      }
      return handle;
    } finally {
      this.free(ptr, encoded.length);
    }
  }

  public setLimits(limits: Partial<CadKernelLimits>): void {
    if (!this.exports.cad_set_kernel_limits) return;
    const ptr = this.alloc(32);
    try {
      const view = new DataView(this.exports.memory.buffer);
      view.setBigUint64(ptr, BigInt(limits.maxWasmMemoryBytes ?? 256 * 1024 * 1024), true);
      view.setUint32(ptr + 8, limits.maxSolverIterations ?? 500, true);
      view.setUint32(ptr + 12, limits.maxBooleanFaces ?? 100000, true);
      view.setUint32(ptr + 16, limits.evalTimeoutMs ?? 5000, true);
      const st = this.exports.cad_set_kernel_limits(ptr);
      if (st !== CadStatus.Ok) {
        throw new Error(`cad_set_kernel_limits failed with status ${st}`);
      }
    } finally {
      this.free(ptr, 32);
    }
  }

  public getLimits(): CadKernelLimits {
    if (!this.exports.cad_get_kernel_limits) {
      return {
        maxWasmMemoryBytes: 256 * 1024 * 1024,
        maxSolverIterations: 500,
        maxBooleanFaces: 100000,
        evalTimeoutMs: 5000,
      };
    }
    const ptr = this.alloc(32);
    try {
      this.exports.cad_get_kernel_limits(ptr);
      const view = new DataView(this.exports.memory.buffer);
      return {
        maxWasmMemoryBytes: Number(view.getBigUint64(ptr, true)),
        maxSolverIterations: view.getUint32(ptr + 8, true),
        maxBooleanFaces: view.getUint32(ptr + 12, true),
        evalTimeoutMs: view.getUint32(ptr + 16, true),
      };
    } finally {
      this.free(ptr, 32);
    }
  }

  public sharedAlloc(size: number): number {
    if (!this.exports.cad_shared_alloc) return 0;
    return this.exports.cad_shared_alloc(size);
  }

  public sharedFree(ptr: number, size: number): void {
    if (!this.exports.cad_shared_free || ptr === 0) return;
    this.exports.cad_shared_free(ptr, size);
  }

  private alloc(size: number): number {
    return this.sharedAlloc(size);
  }

  private free(ptr: number, size: number): void {
    this.sharedFree(ptr, size);
  }

  private allocU64(): number {
    return this.alloc(8);
  }

  private readU64(ptr: number): number | bigint {
    const view = new DataView(this.exports.memory.buffer);
    return view.getBigUint64(ptr, true);
  }

  private assertInitialized(): void {
    if (!this.isInitialized) {
      throw new Error('OpenCadKernel is not initialized. Call init() or use OpenCadKernel.create()');
    }
  }
}
