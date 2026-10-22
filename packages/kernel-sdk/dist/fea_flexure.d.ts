import type { FeaMeshResult } from './types.js';
export interface FeaFlexureWasmExports {
    cad_fea_generate_box_mesh?: (dx: number, dy: number, dz: number, nx: number, ny: number, nz: number) => number;
    cad_fea_get_node_count?: () => number;
    cad_flexure_calc_blade_stiffness?: (l: number, b: number, t: number, E: number) => number;
    cad_flexure_calc_notch_compliance?: (b: number, t: number, r: number, E: number) => number;
}
export declare class OpenCadFeaFlexure {
    private exports;
    constructor(exports: FeaFlexureWasmExports);
    static create(wasmInput: string | URL | ArrayBuffer): Promise<OpenCadFeaFlexure>;
    generateBoxMesh(dx: number, dy: number, dz: number, nx: number, ny: number, nz: number): FeaMeshResult;
    calcBladeStiffness(length: number, width: number, thickness: number, youngsModulus: number): number;
    calcNotchCompliance(width: number, minThickness: number, notchRadius: number, youngsModulus: number): number;
}
//# sourceMappingURL=fea_flexure.d.ts.map