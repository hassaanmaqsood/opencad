import { loadWasmModule } from './loader.js';
export class OpenCadSheetMetal {
    exports;
    constructor(exports) {
        this.exports = exports;
    }
    static async create(wasmInput) {
        const { exports } = await loadWasmModule(wasmInput);
        return new OpenCadSheetMetal(exports);
    }
    calcBend(thickness, innerRadius, kFactor, angleRad) {
        const ba = this.exports.cad_sheetmetal_calc_bend_allowance
            ? this.exports.cad_sheetmetal_calc_bend_allowance(thickness, innerRadius, kFactor, angleRad)
            : 0;
        const bd = this.exports.cad_sheetmetal_calc_bend_deduction
            ? this.exports.cad_sheetmetal_calc_bend_deduction(thickness, innerRadius, kFactor, angleRad)
            : 0;
        return { bendAllowance: ba, bendDeduction: bd };
    }
    unfoldBox(width, length, thickness, innerRadius, kFactor, flangeLength) {
        const ptCount = this.exports.cad_sheetmetal_unfold_box
            ? this.exports.cad_sheetmetal_unfold_box(width, length, thickness, innerRadius, kFactor, flangeLength)
            : 0;
        const totalLength = this.exports.cad_sheetmetal_get_unfolded_length ? this.exports.cad_sheetmetal_get_unfolded_length() : 0;
        const totalWidth = this.exports.cad_sheetmetal_get_unfolded_width ? this.exports.cad_sheetmetal_get_unfolded_width() : 0;
        return { pointCount: ptCount, totalWidth, totalLength };
    }
}
//# sourceMappingURL=sheetmetal.js.map