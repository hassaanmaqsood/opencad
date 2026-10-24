/**
 * @file kernel.ts
 * Standalone OpenCAD Core Kernel Client for Web, Node.js, Bun, and CLI.
 */

import { loadCoreWasm, type WasmBinarySource } from './loader.js';
import { FluentPart } from './fluent.js';
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

  public exportStl(
    handle: CadSolidHandle,
    options?: { binary?: boolean; deflection?: number }
  ): Uint8Array | string {
    this.assertInitialized();
    const binary = options?.binary !== false;
    const deflection = options?.deflection ?? 0.02;

    if (this.exports.cad_wasm_stl_export && this.exports.cad_wasm_stl_export_len) {
      const ptr = this.exports.cad_wasm_stl_export(handle, deflection, 0.5, binary);
      const len = this.exports.cad_wasm_stl_export_len();
      if (ptr && len > 0) {
        const raw = new Uint8Array(this.exports.memory.buffer, ptr, len).slice();
        return binary ? raw : new TextDecoder().decode(raw);
      }
    }

    const mesh = this.tessellate(handle, deflection, 0.5);
    if (!mesh) {
      throw new Error('Failed to tessellate solid for STL export');
    }
    const triCount = Math.floor(mesh.indices.length / 3);
    if (binary) {
      const buf = new Uint8Array(84 + triCount * 50);
      new TextEncoder().encodeInto('OpenCAD Binary STL Export', buf);
      const view = new DataView(buf.buffer);
      view.setUint32(80, triCount, true);
      let offset = 84;
      for (let t = 0; t < triCount; t++) {
        const i0 = mesh.indices[t * 3];
        const i1 = mesh.indices[t * 3 + 1];
        const i2 = mesh.indices[t * 3 + 2];
        const v1 = [mesh.positions[i0 * 3], mesh.positions[i0 * 3 + 1], mesh.positions[i0 * 3 + 2]];
        const v2 = [mesh.positions[i1 * 3], mesh.positions[i1 * 3 + 1], mesh.positions[i1 * 3 + 2]];
        const v3 = [mesh.positions[i2 * 3], mesh.positions[i2 * 3 + 1], mesh.positions[i2 * 3 + 2]];
        const ax = v2[0] - v1[0], ay = v2[1] - v1[1], az = v2[2] - v1[2];
        const bx = v3[0] - v1[0], by = v3[1] - v1[1], bz = v3[2] - v1[2];
        let nx = ay * bz - az * by, ny = az * bx - ax * bz, nz = ax * by - ay * bx;
        const l = Math.hypot(nx, ny, nz) || 1.0;
        view.setFloat32(offset, nx / l, true); offset += 4;
        view.setFloat32(offset, ny / l, true); offset += 4;
        view.setFloat32(offset, nz / l, true); offset += 4;
        for (const v of [v1, v2, v3]) {
          view.setFloat32(offset, v[0], true); offset += 4;
          view.setFloat32(offset, v[1], true); offset += 4;
          view.setFloat32(offset, v[2], true); offset += 4;
        }
        view.setUint16(offset, 0, true); offset += 2;
      }
      return buf;
    } else {
      let out = 'solid opencad_model\n';
      for (let t = 0; t < triCount; t++) {
        const i0 = mesh.indices[t * 3];
        const i1 = mesh.indices[t * 3 + 1];
        const i2 = mesh.indices[t * 3 + 2];
        const v1 = [mesh.positions[i0 * 3], mesh.positions[i0 * 3 + 1], mesh.positions[i0 * 3 + 2]];
        const v2 = [mesh.positions[i1 * 3], mesh.positions[i1 * 3 + 1], mesh.positions[i1 * 3 + 2]];
        const v3 = [mesh.positions[i2 * 3], mesh.positions[i2 * 3 + 1], mesh.positions[i2 * 3 + 2]];
        const ax = v2[0] - v1[0], ay = v2[1] - v1[1], az = v2[2] - v1[2];
        const bx = v3[0] - v1[0], by = v3[1] - v1[1], bz = v3[2] - v1[2];
        let nx = ay * bz - az * by, ny = az * bx - ax * bz, nz = ax * by - ay * bx;
        const l = Math.hypot(nx, ny, nz) || 1.0;
        out += `  facet normal ${(nx/l).toFixed(6)} ${(ny/l).toFixed(6)} ${(nz/l).toFixed(6)}\n`;
        out += `    outer loop\n`;
        out += `      vertex ${v1[0].toFixed(6)} ${v1[1].toFixed(6)} ${v1[2].toFixed(6)}\n`;
        out += `      vertex ${v2[0].toFixed(6)} ${v2[1].toFixed(6)} ${v2[2].toFixed(6)}\n`;
        out += `      vertex ${v3[0].toFixed(6)} ${v3[1].toFixed(6)} ${v3[2].toFixed(6)}\n`;
        out += `    endloop\n`;
        out += `  endfacet\n`;
      }
      out += 'endsolid opencad_model\n';
      return out;
    }
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

  public part(name = 'Part'): FluentPart {
    this.assertInitialized();
    return new FluentPart(name, this);
  }

  private assertInitialized(): void {
    if (!this.isInitialized) {
      throw new Error('OpenCadKernel is not initialized. Call init() or use OpenCadKernel.create()');
    }
  }
}

export { OpenCadKernel as OpenCadCore };

export async function createKernel(source?: WasmBinarySource): Promise<OpenCadKernel> {
  return OpenCadKernel.create(source);
}

