import { loadWasmModule } from './loader.js';

export interface ImplicitWasmExports {
  cad_implicit_eval_tpms_gyroid?: (x: number, y: number, z: number, cellSize: number, wallThickness: number) => number;
  cad_implicit_eval_tpms_schwarz_p?: (x: number, y: number, z: number, cellSize: number, wallThickness: number) => number;
  cad_implicit_eval_tpms_schwarz_d?: (x: number, y: number, z: number, cellSize: number, wallThickness: number) => number;
  cad_implicit_mesh_sphere?: (r: number, res: number) => number;
  cad_implicit_get_vertex_count?: () => number;
}

export class OpenCadImplicit {
  private exports: ImplicitWasmExports;

  constructor(exports: ImplicitWasmExports) {
    this.exports = exports;
  }

  public static async create(wasmInput: string | URL | ArrayBuffer): Promise<OpenCadImplicit> {
    const { exports } = await loadWasmModule<ImplicitWasmExports>(wasmInput);
    return new OpenCadImplicit(exports);
  }

  public evalGyroid(x: number, y: number, z: number, cellSize = 10, wallThickness = 1): number {
    return this.exports.cad_implicit_eval_tpms_gyroid
      ? this.exports.cad_implicit_eval_tpms_gyroid(x, y, z, cellSize, wallThickness)
      : 0;
  }

  public meshSphere(radius: number, resolution = 16): number {
    return this.exports.cad_implicit_mesh_sphere
      ? this.exports.cad_implicit_mesh_sphere(radius, resolution)
      : 0;
  }
}
