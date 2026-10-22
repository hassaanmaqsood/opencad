/**
 * @file kernel.ts
 * Standalone OpenCAD Core Kernel Client for Web, Node.js, Bun, and CLI.
 */
import { type WasmBinarySource } from './loader.js';
import { type CadSolidHandle, type CadMesh, type CadKernelLimits, type CadCoreWasmExports } from './types.js';
export declare class OpenCadKernel {
    private exports;
    private isInitialized;
    constructor(exports: CadCoreWasmExports);
    static create(source?: WasmBinarySource): Promise<OpenCadKernel>;
    init(): void;
    deinit(): void;
    createBox(dx: number, dy: number, dz: number): CadSolidHandle;
    createCylinder(radius: number, height: number): CadSolidHandle;
    createSphere(radius: number): CadSolidHandle;
    releaseSolid(handle: CadSolidHandle): void;
    tessellate(handle: CadSolidHandle, chordalTol?: number, angularTol?: number): CadMesh;
    exportStep(handle: CadSolidHandle): string;
    importStep(stepText: string): CadSolidHandle;
    setLimits(limits: Partial<CadKernelLimits>): void;
    getLimits(): CadKernelLimits;
    sharedAlloc(size: number): number;
    sharedFree(ptr: number, size: number): void;
    private alloc;
    private free;
    private allocU64;
    private readU64;
    private assertInitialized;
}
//# sourceMappingURL=kernel.d.ts.map