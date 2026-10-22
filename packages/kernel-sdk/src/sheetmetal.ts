import { loadWasmModule } from './loader.js';
import type { SheetMetalBendResult } from './types.js';

export interface SheetMetalWasmExports {
  cad_sheetmetal_calc_bend_allowance?: (t: number, r: number, k: number, angle: number) => number;
  cad_sheetmetal_calc_bend_deduction?: (t: number, r: number, k: number, angle: number) => number;
  cad_sheetmetal_unfold_box?: (w: number, l: number, t: number, r: number, k: number, fl: number) => number;
  cad_sheetmetal_get_unfolded_length?: () => number;
  cad_sheetmetal_get_unfolded_width?: () => number;
}

export class OpenCadSheetMetal {
  private exports: SheetMetalWasmExports;

  constructor(exports: SheetMetalWasmExports) {
    this.exports = exports;
  }

  public static async create(wasmInput: string | URL | ArrayBuffer): Promise<OpenCadSheetMetal> {
    const { exports } = await loadWasmModule<SheetMetalWasmExports>(wasmInput);
    return new OpenCadSheetMetal(exports);
  }

  public calcBend(thickness: number, innerRadius: number, kFactor: number, angleRad: number): SheetMetalBendResult {
    const ba = this.exports.cad_sheetmetal_calc_bend_allowance
      ? this.exports.cad_sheetmetal_calc_bend_allowance(thickness, innerRadius, kFactor, angleRad)
      : 0;
    const bd = this.exports.cad_sheetmetal_calc_bend_deduction
      ? this.exports.cad_sheetmetal_calc_bend_deduction(thickness, innerRadius, kFactor, angleRad)
      : 0;
    return { bendAllowance: ba, bendDeduction: bd };
  }

  public unfoldBox(width: number, length: number, thickness: number, innerRadius: number, kFactor: number, flangeLength: number) {
    const ptCount = this.exports.cad_sheetmetal_unfold_box
      ? this.exports.cad_sheetmetal_unfold_box(width, length, thickness, innerRadius, kFactor, flangeLength)
      : 0;
    const totalLength = this.exports.cad_sheetmetal_get_unfolded_length ? this.exports.cad_sheetmetal_get_unfolded_length() : 0;
    const totalWidth = this.exports.cad_sheetmetal_get_unfolded_width ? this.exports.cad_sheetmetal_get_unfolded_width() : 0;
    return { pointCount: ptCount, totalWidth, totalLength };
  }
}
