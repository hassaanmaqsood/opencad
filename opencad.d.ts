// OpenCAD TypeScript Definitions Bundle (Wave 15)
/**
 * @file types.ts
 * Type definitions for @open-cad/core matching abi/cad_kernel.h
 */
export type CadSolidHandle = bigint | number;
export type CadFaceHandle = bigint | number;
export type CadEdgeHandle = bigint | number;
export declare const CAD_INVALID_HANDLE = 0;
export declare enum CadStatus {
    Ok = 0,
    InvalidArgument = 1,
    OutOfMemory = 2,
    TopologyInvalid = 3,
    GeometryIntersection = 4,
    OpFailed = 5,
    NotImplemented = 6,
    Timeout = 7,
    NonManifold = 8,
    LimitExceeded = 9
}
export declare enum CadBackend {
    Auto = 0,
    COracle = 1,
    NativeZig = 2
}
export declare enum CadOpType {
    PrimitiveBox = 0,
    PrimitiveCylinder = 1,
    PrimitiveSphere = 2,
    SketchExtrude = 3,
    BooleanUnion = 4,
    BooleanDifference = 5,
    BooleanIntersection = 6,
    Fillet = 7,
    Chamfer = 8,
    Count = 9
}
export declare enum CadLodLevel {
    Coarse = 0,
    Medium = 1,
    Fine = 2
}
export declare enum CadSolveState {
    Solved = 0,
    UnderConstrained = 1,
    OverConstrained = 2,
    Conflicting = 3
}
export interface CadVec3 {
    x: number;
    y: number;
    z: number;
}
export interface CadMesh {
    positions: Float32Array;
    normals: Float32Array;
    indices: Uint32Array;
    vertexCount: number;
    triangleCount: number;
}
export interface CadBrepStats {
    numVertices: number;
    numEdges: number;
    numFaces: number;
    eulerCharacteristic: number;
    surfaceArea: number;
    volume: number;
}
export interface CadKernelLimits {
    maxWasmMemoryBytes: number;
    maxSolverIterations: number;
    maxBooleanFaces: number;
    evalTimeoutMs: number;
}
export interface CadTopoId {
    originFeatureId: number;
    sourceSketchEntityId: number;
    opType: number;
    subshapeType: number;
    subshapeIndex: number;
    disambiguationIndex: number;
}
export declare enum CadSketchConstraintType {
    Coincident = 0,
    Parallel = 1,
    Perpendicular = 2,
    Tangent = 3,
    Horizontal = 4,
    Vertical = 5,
    Equal = 6,
    Symmetric = 7,
    Distance = 8,
    Angle = 9,
    Radius = 10
}
export interface CadSketchPoint2D {
    id: number;
    x: number;
    y: number;
    isFixed: boolean;
}
export interface CadSketchLine2D {
    id: number;
    startPointId: number;
    endPointId: number;
}
export interface CadSketchArc2D {
    id: number;
    centerPointId: number;
    startPointId: number;
    endPointId: number;
    radius: number;
}
export interface CadSketchCircle2D {
    id: number;
    centerPointId: number;
    radius: number;
}
export interface CadSketchConstraint {
    id: number;
    type: CadSketchConstraintType;
    entity1Id: number;
    entity2Id: number;
    entity3Id?: number;
    parameterValue: number;
}
export interface CadSolverStatus {
    solveState: CadSolveState;
    degreesOfFreedom: number;
    iterations: number;
    maxResidual: number;
    conflictingCount: number;
    conflictingConstraintIds: number[];
}
export declare enum CadFeatureType {
    Sketch = 0,
    Extrude = 1,
    Revolve = 2,
    BooleanUnion = 3,
    BooleanCut = 4,
    BooleanIntersect = 5,
    Fillet = 6,
    Chamfer = 7,
    Shell = 8,
    Draft = 9,
    CustomPlugin = 1000
}
export interface CadFeatureNode {
    featureId: number;
    type: CadFeatureType | number;
    isSuppressed: boolean;
    parentIds: number[];
    targetTopoIds: CadTopoId[];
    params: Record<string, any>;
}
export interface CadTessellatedSolidSlice {
    positions: Float32Array;
    normals: Float32Array;
    indices: Uint32Array;
    vertexCount: number;
    triangleCount: number;
    triangleToFaceId: BigUint64Array | Uint32Array;
    edgePolylines: Float32Array;
    edgeSegmentCount: number;
    edgeToTopoId: BigUint64Array | Uint32Array;
    bboxMin: CadVec3;
    bboxMax: CadVec3;
}
export interface CadAssemblyInstance {
    instanceId: number;
    solidHandle: CadSolidHandle;
    isGrounded: boolean;
    initialTransform: Float32Array;
    name: string;
}
export declare enum CadAssemblyMateType {
    Coincident = 0,
    Concentric = 1,
    Parallel = 2,
    Distance = 3,
    Angle = 4,
    Gear = 5
}
export interface CadAssemblyMate {
    mateId: number;
    type: CadAssemblyMateType;
    instance1Id: number;
    entity1TopoId: CadTopoId;
    instance2Id: number;
    entity2TopoId: CadTopoId;
    isAntiAligned: boolean;
    parameterValue: number;
    limitsMin?: number;
    limitsMax?: number;
}
export interface CadAssemblySolveResult {
    solveState: CadSolveState;
    totalDof: number;
    iterations: number;
    maxResidual: number;
    transforms: Float32Array;
}
export interface CadPluginOpVTable {
    opTypeId: number;
    opName: string;
    evaluateFn?: (opTypeId: number, nodePtr: number, inputSolidsPtr: number, inputCount: number, outSolidPtr: number) => CadStatus;
    tessellateFn?: (solid: number, chordalTol: number, angularTol: number, outSlicePtr: number) => CadStatus;
    serializeAstFn?: (nodePtr: number, outBufPtr: number, bufSize: number, outWrittenPtr: number) => CadStatus;
    freeFn?: (solid: number) => void;
}
export interface CadCoreWasmExports {
    memory: WebAssembly.Memory;
    cad_kernel_init?: () => number;
    cad_kernel_deinit?: () => number;
    cad_primitive_box?: (dx: number, dy: number, dz: number, outHandle: number) => number;
    cad_primitive_cylinder?: (radius: number, height: number, outHandle: number) => number;
    cad_primitive_sphere?: (radius: number, outHandle: number) => number;
    cad_solid_release?: (handle: number | bigint) => number;
    cad_solid_tessellate?: (handle: number | bigint, chordalTol: number, angularTol: number, outMesh: number) => number;
    cad_mesh_free?: (meshPtr: number) => number;
    cad_solid_tessellate_slice?: (handle: number | bigint, chordalTol: number, angularTol: number, outSlice: number) => number;
    cad_solid_tessellate_lod?: (handle: number | bigint, lodLevel: number, outSlice: number) => number;
    cad_slice_free?: (slicePtr: number) => number;
    cad_dag_evaluate?: (nodesPtr: number, nodeCount: number, rollbackIndex: number, outSolid: number) => number;
    cad_wasm_step_export?: (handle: number | bigint) => number;
    cad_wasm_step_export_len?: () => number;
    cad_wasm_step_import?: (ptr: number, len: number) => number;
    cad_wasm_stl_export?: (handle: number | bigint, chordal: number, angular: number, binary: boolean) => number;
    cad_wasm_stl_export_len?: () => number;
    cad_assembly_solve_transforms?: (instancesPtr: number, instanceCount: number, matesPtr: number, mateCount: number, maxIter: number, tol: number, outTransforms: number, outStatus: number) => number;
    cad_set_kernel_limits?: (limitsPtr: number) => number;
    cad_get_kernel_limits?: (outLimitsPtr: number) => number;
    cad_register_plugin_op?: (vtablePtr: number) => number;
    cad_unregister_plugin_op?: (opTypeId: number) => number;
    cad_execute_plugin_op?: (opTypeId: number, nodePtr: number, inputSolidsPtr: number, inputCount: number, outSolidPtr: number) => number;
    cad_shared_alloc?: (size: number) => number;
    cad_shared_free?: (ptr: number, size: number) => void;
}
//# sourceMappingURL=types.d.ts.map
/**
 * @file loader.ts
 * Universal WebAssembly Loader supporting Web, Web Workers, Node.js, and Bun.
 */

export type WasmBinarySource = string | URL | ArrayBuffer | Uint8Array | WebAssembly.Module;
export interface WasmInstanceBundle {
    instance: WebAssembly.Instance;
    module: WebAssembly.Module;
    exports: CadCoreWasmExports;
}
/**
 * Loads and instantiates the cad_core WebAssembly binary across runtime environments.
 */
export declare function loadCoreWasm(source?: WasmBinarySource, importObject?: WebAssembly.Imports): Promise<WasmInstanceBundle>;
//# sourceMappingURL=loader.d.ts.map
/**
 * @file kernel.ts
 * Standalone OpenCAD Core Kernel Client for Web, Node.js, Bun, and CLI.
 */



export declare class OpenCadKernel {
    private exports;
    private isInitialized;
    constructor(exports: CadCoreWasmExports);
    static create(source?: WasmBinarySource): Promise<OpenCadKernel>;
    init(): void;
    deinit(): void;
    createBox(dx: number, dy: number, dz: number): CadSolidHandle;
    createCylinder(radius: number, height: number): CadSolidHandle;
    createSphere(radius: number): CadSolidHandle;
    releaseSolid(handle: CadSolidHandle): void;
    tessellate(handle: CadSolidHandle, chordalTol?: number, angularTol?: number): CadMesh;
    exportStep(handle: CadSolidHandle): string;
    exportStl(handle: CadSolidHandle, options?: {
        binary?: boolean;
        deflection?: number;
    }): Uint8Array | string;
    importStep(stepText: string): CadSolidHandle;
    setLimits(limits: Partial<CadKernelLimits>): void;
    getLimits(): CadKernelLimits;
    sharedAlloc(size: number): number;
    sharedFree(ptr: number, size: number): void;
    private alloc;
    private free;
    private allocU64;
    private readU64;
    part(name?: string): FluentPart;
    private assertInitialized;
}
export { OpenCadKernel as OpenCadCore };
export declare function createKernel(source?: WasmBinarySource): Promise<OpenCadKernel>;
//# sourceMappingURL=kernel.d.ts.map
/**
 * @file fluent.ts
 * Unified Fluent Auto-Disposing Parametric CAD API for OpenCAD.
 * Backed by WebAssembly.Memory, Parametric DAG, FinalizationRegistry, and Symbol.dispose.
 */


declare const symDispose: symbol;
export declare class FluentSketch {
    private part;
    private plane;
    private elements;
    private isConstructionMode;
    constructor(part: FluentPart, plane?: string);
    construction(enabled?: boolean): this;
    rect(width: number, height: number): this;
    circle(cx: number, cy: number, radius: number, options?: {
        cut?: boolean;
    }): this;
    spline(points: [number, number][], degree?: number): this;
    slot(center1: [number, number], center2: [number, number], radius: number): this;
    ellipse(cx: number, cy: number, majorRadius: number, minorRadius: number, rotation?: number): this;
    polygon(cx: number, cy: number, radius: number, sideCount?: number, rotation?: number): this;
    text(text: string, fontSize?: number, origin?: [number, number]): this;
    fillet2D(radius: number, cornerIndex?: number): this;
    chamfer2D(distance: number, cornerIndex?: number): this;
    offset(distance: number): this;
    boolean(op: 'union' | 'subtract' | 'intersect', otherSketch: FluentSketch | any[]): this;
    extrude(depth: number): FluentPart;
    revolve(angleDeg?: number, axis?: string): FluentPart;
    sweep(path: any): FluentPart;
}
export declare class FluentFlexureWorkbench {
    private part;
    constructor(part: FluentPart);
    analyze(options: {
        fixed: string;
        stage: string;
    }): FluentPart;
}
export declare class FluentImplicitWorkbench {
    private part;
    constructor(part: FluentPart);
    gyroidInfill(options: {
        preserve: string[];
        cellSize: number;
        wallThickness?: number;
    }): FluentPart;
}
export declare class FluentPart {
    [symDispose]: () => void;
    readonly name: string;
    handle: CadSolidHandle;
    readonly metadata: Record<string, any>;
    readonly flexure: FluentFlexureWorkbench;
    readonly implicit: FluentImplicitWorkbench;
    private kernel;
    private isDisposed;
    constructor(name?: string, kernel?: OpenCadKernel, initialHandle?: CadSolidHandle);
    dispose(): void;
    sketch(plane?: string): FluentSketch;
    box(dx: number, dy: number, dz: number): this;
    cylinder(radius: number, height: number): this;
    fillet(options: {
        select: string;
        radius: number;
    } | number, edges?: number[]): this;
    chamfer(distance: number, edges?: number[]): this;
    shell(thickness: number): this;
    add(tool: FluentPart | {
        shape: string;
        [key: string]: any;
    }): this;
    cut(tool: FluentPart | {
        shape: string;
        [key: string]: any;
    }): this;
    intersect(tool: FluentPart | {
        shape: string;
        [key: string]: any;
    }): this;
    union(other: FluentPart): this;
    subtract(other: FluentPart): this;
    holeWizard(params: {
        type?: 'simple' | 'cbore' | 'csink' | 'tapped';
        diameter: number;
        depth: number;
        cboreDiameter?: number;
        cboreDepth?: number;
        csinkDiameter?: number;
        csinkAngle?: number;
        pitch?: number;
        position?: [number, number, number];
        normal?: [number, number, number];
    }): this;
    thread(params: {
        standard?: 'metric_coarse' | 'metric_fine' | 'unc' | 'unf' | 'trapezoidal';
        nominalDiameter: number;
        pitch: number;
        length: number;
        isModeled?: boolean;
        isInternal?: boolean;
        origin?: [number, number, number];
        direction?: [number, number, number];
    }): this;
    datumPlane(params: {
        type?: 'offset' | 'angle' | 'threepoint' | 'midplane' | 'tangent';
        origin?: [number, number, number];
        normal?: [number, number, number];
        offset?: number;
        angle?: number;
    }): this;
    datumAxis(params: {
        type?: 'cylinder' | 'twoplanes' | 'twopoints';
        point?: [number, number, number];
        direction?: [number, number, number];
    }): this;
    splitBody(params: {
        origin: [number, number, number];
        normal: [number, number, number];
    }): {
        positive: FluentPart;
        negative: FluentPart;
    };
    _applyExtrude(depth: number, elements: any[], plane: string): this;
    _applyRevolve(angleDeg: number, axis: string, elements: any[], plane: string): this;
    _applySweep(path: any, elements: any[], plane: string): this;
    tessellate(chordalTol?: number, angularTol?: number): CadMesh | null;
    exportStep(): string;
    exportStl(options?: {
        binary?: boolean;
        deflection?: number;
    }): Uint8Array | string;
}
export { FluentPart as Part };
//# sourceMappingURL=fluent.d.ts.map
/**
 * @file element.ts
 * Zero-Code Web Component (<opencad-viewer> and <opencad-studio>)
 * Allows non-dev makers and engineers to embed interactive 3D parametric CAD models
 * with parameter sliders into any HTML page, Notion, or Markdown document.
 */
declare const BaseElement: {
    new (): HTMLElement;
    prototype: HTMLElement;
};
export declare class OpenCadViewerElement extends BaseElement {
    protected iframe: HTMLIFrameElement | null;
    protected canvas: HTMLCanvasElement | null;
    static get observedAttributes(): string[];
    connectedCallback(): void;
    disconnectedCallback(): void;
    private handleMessage;
    attributeChangedCallback(name: string, oldValue: string | null, newValue: string | null): void;
    protected getBaseUrl(): string;
    protected isEmbedMode(): boolean;
    protected buildTargetUrl(): string;
    protected updateIframeSrc(): void;
    postMessage(message: any): void;
    downloadStep(): void;
    downloadStl(options?: {
        binary?: boolean;
        deflection?: number;
    }): void;
    download3mf(): void;
    downloadDxf(): void;
    setCode(code: string): void;
    setTemplate(templateId: string): void;
    emitMetrics(metrics: {
        volumeMm3: number;
        massGrams: number;
        bbox: {
            dx: number;
            dy: number;
            dz: number;
        };
        bendCount?: number;
        cncRuntimeMinutes?: number;
    }): void;
    protected render(): void;
}
export declare class OpenCadStudioElement extends OpenCadViewerElement {
    protected isEmbedMode(): boolean;
}
export {};
//# sourceMappingURL=element.d.ts.map
