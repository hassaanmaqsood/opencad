import type { SheetMetalBendResult } from './types.js';
export interface SheetMetalWasmExports {
    cad_sheetmetal_calc_bend_allowance?: (t: number, r: number, k: number, angle: number) => number;
    cad_sheetmetal_calc_bend_deduction?: (t: number, r: number, k: number, angle: number) => number;
    cad_sheetmetal_unfold_box?: (w: number, l: number, t: number, r: number, k: number, fl: number) => number;
    cad_sheetmetal_get_unfolded_length?: () => number;
    cad_sheetmetal_get_unfolded_width?: () => number;
}
export declare class OpenCadSheetMetal {
    private exports;
    constructor(exports: SheetMetalWasmExports);
    static create(wasmInput: string | URL | ArrayBuffer): Promise<OpenCadSheetMetal>;
    calcBend(thickness: number, innerRadius: number, kFactor: number, angleRad: number): SheetMetalBendResult;
    unfoldBox(width: number, length: number, thickness: number, innerRadius: number, kFactor: number, flangeLength: number): {
        pointCount: number;
        totalWidth: number;
        totalLength: number;
    };
}
//# sourceMappingURL=sheetmetal.d.ts.map