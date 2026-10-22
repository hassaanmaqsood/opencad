import { loadWasmModule } from './loader.js';

export interface CamHlrWasmExports {
  memory: WebAssembly.Memory;
  cad_cam_generate_contour_gcode?: (
    pxPtr: number,
    pyPtr: number,
    count: number,
    depth: number,
    diameter: number,
    feed: number
  ) => number;
  cad_cam_get_gcode_ptr?: () => number;
  cad_hlr_project_point_isometric?: (x: number, y: number, z: number, outPtr: number) => void;
}

export class OpenCadCamHlr {
  private exports: CamHlrWasmExports;

  constructor(exports: CamHlrWasmExports) {
    this.exports = exports;
  }

  public static async create(wasmInput: string | URL | ArrayBuffer): Promise<OpenCadCamHlr> {
    const { exports } = await loadWasmModule<CamHlrWasmExports>(wasmInput);
    return new OpenCadCamHlr(exports);
  }

  public projectIsometric(x: number, y: number, z: number): [number, number] {
    const cos30 = 0.86602540378;
    const sin30 = 0.5;
    return [(x - z) * cos30, y + (x + z) * sin30];
  }
}
