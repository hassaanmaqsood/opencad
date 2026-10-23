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
    constructor(part: FluentPart, plane?: string);
    rect(width: number, height: number): this;
    circle(cx: number, cy: number, radius: number, options?: {
        cut?: boolean;
    }): this;
    extrude(depth: number): FluentPart;
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
    _applyExtrude(depth: number, elements: any[], plane: string): this;
    tessellate(chordalTol?: number, angularTol?: number): CadMesh | null;
    exportStep(): string;
}
export { FluentPart as Part };
//# sourceMappingURL=fluent.d.ts.map