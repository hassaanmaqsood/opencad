export interface ImplicitWasmExports {
    cad_implicit_eval_tpms_gyroid?: (x: number, y: number, z: number, cellSize: number, wallThickness: number) => number;
    cad_implicit_eval_tpms_schwarz_p?: (x: number, y: number, z: number, cellSize: number, wallThickness: number) => number;
    cad_implicit_eval_tpms_schwarz_d?: (x: number, y: number, z: number, cellSize: number, wallThickness: number) => number;
    cad_implicit_mesh_sphere?: (r: number, res: number) => number;
    cad_implicit_get_vertex_count?: () => number;
}
export declare class OpenCadImplicit {
    private exports;
    constructor(exports: ImplicitWasmExports);
    static create(wasmInput: string | URL | ArrayBuffer): Promise<OpenCadImplicit>;
    evalGyroid(x: number, y: number, z: number, cellSize?: number, wallThickness?: number): number;
    meshSphere(radius: number, resolution?: number): number;
}
//# sourceMappingURL=implicit.d.ts.map