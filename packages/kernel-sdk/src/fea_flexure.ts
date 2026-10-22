import { loadWasmModule } from './loader.js';
import type { FeaMeshResult } from './types.js';

export interface FeaFlexureWasmExports {
  cad_fea_generate_box_mesh?: (dx: number, dy: number, dz: number, nx: number, ny: number, nz: number) => number;
  cad_fea_get_node_count?: () => number;
  cad_flexure_calc_blade_stiffness?: (l: number, b: number, t: number, E: number) => number;
  cad_flexure_calc_notch_compliance?: (b: number, t: number, r: number, E: number) => number;
}

export class OpenCadFeaFlexure {
  private exports: FeaFlexureWasmExports;

  constructor(exports: FeaFlexureWasmExports) {
    this.exports = exports;
  }

  public static async create(wasmInput: string | URL | ArrayBuffer): Promise<OpenCadFeaFlexure> {
    const { exports } = await loadWasmModule<FeaFlexureWasmExports>(wasmInput);
    return new OpenCadFeaFlexure(exports);
  }

  public generateBoxMesh(dx: number, dy: number, dz: number, nx: number, ny: number, nz: number): FeaMeshResult {
    const elCount = this.exports.cad_fea_generate_box_mesh
      ? this.exports.cad_fea_generate_box_mesh(dx, dy, dz, nx, ny, nz)
      : 0;
    const nodeCount = this.exports.cad_fea_get_node_count ? this.exports.cad_fea_get_node_count() : 0;
    return { nodeCount, elementCount: elCount };
  }

  public calcBladeStiffness(length: number, width: number, thickness: number, youngsModulus: number): number {
    return this.exports.cad_flexure_calc_blade_stiffness
      ? this.exports.cad_flexure_calc_blade_stiffness(length, width, thickness, youngsModulus)
      : 0;
  }

  public calcNotchCompliance(width: number, minThickness: number, notchRadius: number, youngsModulus: number): number {
    return this.exports.cad_flexure_calc_notch_compliance
      ? this.exports.cad_flexure_calc_notch_compliance(width, minThickness, notchRadius, youngsModulus)
      : 0;
  }
}
