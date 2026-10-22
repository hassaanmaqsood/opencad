export interface CamHlrWasmExports {
    memory: WebAssembly.Memory;
    cad_cam_generate_contour_gcode?: (pxPtr: number, pyPtr: number, count: number, depth: number, diameter: number, feed: number) => number;
    cad_cam_get_gcode_ptr?: () => number;
    cad_hlr_project_point_isometric?: (x: number, y: number, z: number, outPtr: number) => void;
}
export declare class OpenCadCamHlr {
    private exports;
    constructor(exports: CamHlrWasmExports);
    static create(wasmInput: string | URL | ArrayBuffer): Promise<OpenCadCamHlr>;
    projectIsometric(x: number, y: number, z: number): [number, number];
}
//# sourceMappingURL=cam_hlr.d.ts.map