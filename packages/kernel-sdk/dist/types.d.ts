export interface CadWasmMemoryBuffers {
    positions: Float32Array;
    normals: Float32Array;
    indices: Uint32Array;
    triangleToFaceId?: BigUint64Array | Uint32Array;
    edgePolylines?: Float32Array;
    edgeToTopoId?: BigUint64Array | Uint32Array;
}
export interface SheetMetalBendResult {
    bendAllowance: number;
    bendDeduction: number;
}
export interface FeaMeshResult {
    nodeCount: number;
    elementCount: number;
}
export interface ImplicitTpmsResult {
    nodalValue: number;
}
export declare enum CadImplicitOpcode {
    PRIMITIVE = 0,
    BREP_DISTANCE = 1,
    TPMS_GYROID = 2,
    TPMS_SCHWARZ_P = 3,
    TPMS_DIAMOND = 4,
    STRESS_FIELD_MODULATE = 5,
    SMOOTH_UNION = 6,
    SMOOTH_INTERSECT = 7,
    SMOOTH_DIFFERENCE = 8,
    SHELL = 9,
    OFFSET = 10,
    WARP = 11
}
export declare enum CadImplicitPrimType {
    SPHERE = 0,
    BOX = 1,
    CYLINDER = 2,
    TORUS = 3,
    PLANE = 4
}
export declare enum CadImplicitWarpType {
    TWIST = 0,
    TAPER = 1,
    BEND = 2
}
export interface CadImplicitOp {
    opcode: CadImplicitOpcode;
    outReg: number;
    inRegA?: number;
    inRegB?: number;
    params?: Record<string, unknown>;
}
export interface CadSliceContour2D {
    points: Float32Array;
    pointCount: number;
    isOuterBoundary: boolean;
}
export interface CadSlice2D {
    zHeight: number;
    contours: CadSliceContour2D[];
    contourCount: number;
    bbox: [number, number, number, number];
    totalSolidArea: number;
}
//# sourceMappingURL=types.d.ts.map