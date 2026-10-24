/**
 * @file fluent.ts
 * Unified Fluent Auto-Disposing Parametric CAD API for OpenCAD.
 * Backed by WebAssembly.Memory, Parametric DAG, FinalizationRegistry, and Symbol.dispose.
 */
import { OpenCadKernel } from './kernel.js';
import { CadSolidHandle, CadMesh } from './types.js';
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