/**
 * @file cdml.ts
 * CDML v1.0 Compliant 4-Step Engineering Surface API.
 * Emits zero-primitive normative CDML v1.0 XML documents (§6–§14).
 */
export interface VarMetadata {
    id: string;
    value: number | string;
    min?: number;
    max?: number;
    unit?: string;
}
export declare class CdmlEvaluationResult {
    status: number;
    diagnostic: string;
    probes: Map<string, number>;
    private stepData;
    private stlData;
    constructor(status: number, diagnostic: string, probes: Map<string, number>, stepData: string, stlData: Uint8Array);
    probe(id: string): number;
    toStep(): string;
    toStl(): Uint8Array;
}
export declare class SketchBuilder {
    private doc;
    id: string;
    chart: string;
    maxIter: number;
    vars: string[];
    wires: string[];
    constraints: string[];
    constructor(doc: CdmlDocument, id: string, chart: string, maxIter?: number);
    rectWire(id: string, options: {
        width: string | number;
        height: string | number;
        role?: string;
    }): this;
    rect_wire(id: string, options: {
        width: string | number;
        height: string | number;
        role?: string;
    }): this;
    circleWire(id: string, options: {
        radius: string | number;
        role?: string;
    }): this;
    circle_wire(id: string, options: {
        radius: string | number;
        role?: string;
    }): this;
    nurbsCurve(id: string, options: {
        degree: number;
        ctrl: string;
        weights: string;
        knots: string;
    }): this;
    paramCurve(id: string, options: {
        param: string;
        domain: string;
        uExpr: string;
        vExpr: string;
    }): this;
    toXml(): string;
    brep(id: string, options?: {
        material?: string;
    }): BrepBuilder;
    probe(id: string, options: {
        type?: string;
        target?: string;
        facePredicate?: string;
        quantity?: string;
    }): CdmlDocument;
    exportTessellate(target: string, options?: {
        chordTol?: number;
        angleTol?: number;
    }): CdmlDocument;
    exportStep(target: string, options?: {
        schema?: string;
    }): CdmlDocument;
    exportStl(target: string, options?: {
        binary?: boolean;
    }): CdmlDocument;
    toCDML(): string;
    to_cdml(): string;
    evaluate(importsMap?: Record<string, string>): Promise<CdmlEvaluationResult>;
}
export declare class BrepBuilder {
    private doc;
    id: string;
    material?: string;
    operations: string[];
    constructor(doc: CdmlDocument, id: string, options?: {
        material?: string;
    });
    sweepExtrude(id: string, options: {
        sketch: string;
        zExpr?: string;
        capEnds?: boolean;
    }): this;
    sweep_extrude(id: string, options: {
        sketch: string;
        zExpr?: string;
        capEnds?: boolean;
    }): this;
    fillet(id: string, options: {
        edgePredicate: string;
        radiusExpr: string | number;
    }): this;
    toXml(): string;
    probe(id: string, options: {
        type?: string;
        target?: string;
        facePredicate?: string;
        quantity?: string;
    }): CdmlDocument;
    exportTessellate(target: string, options?: {
        chordTol?: number;
        angleTol?: number;
    }): CdmlDocument;
    exportStep(target: string, options?: {
        schema?: string;
    }): CdmlDocument;
    exportStl(target: string, options?: {
        binary?: boolean;
    }): CdmlDocument;
    toCDML(): string;
    to_cdml(): string;
    evaluate(importsMap?: Record<string, string>): Promise<CdmlEvaluationResult>;
}
export declare class CdmlDocument {
    units: string;
    linearTol: string;
    angularTol: string;
    imports: string[];
    defs: string[];
    charts: string[];
    sketches: SketchBuilder[];
    breps: BrepBuilder[];
    probes: string[];
    exports: string[];
    varDefs: Map<string, VarMetadata>;
    constructor(units?: string, linearTol?: string, angularTol?: string);
    importDoc(src: string, prefix?: string): this;
    var(id: string, value: number | string, options?: {
        min?: number;
        max?: number;
        unit?: string;
    }): this;
    expr(id: string, exprStr: string): this;
    fieldSlot(id: string, slot: number, options?: {
        semantic?: string;
        gridX?: number;
        gridY?: number;
        gridZ?: number;
        defaultVal?: number;
    }): this;
    chartXY(id: string): this;
    chart_xy(id: string): this;
    sketch(id: string, options?: {
        chart?: string;
        maxIter?: number;
    }): SketchBuilder;
    brep(id: string, options?: {
        material?: string;
    }): BrepBuilder;
    probe(id: string, options: {
        type?: string;
        target?: string;
        facePredicate?: string;
        quantity?: string;
    }): this;
    exportTessellate(target: string, options?: {
        chordTol?: number;
        angleTol?: number;
    }): this;
    export_tessellate(target: string, options?: {
        chordTol?: number;
        angleTol?: number;
    }): this;
    exportStep(target: string, options?: {
        schema?: string;
    }): this;
    export_step(target: string, options?: {
        schema?: string;
    }): this;
    exportStl(target: string, options?: {
        binary?: boolean;
    }): this;
    export_stl(target: string, options?: {
        binary?: boolean;
    }): this;
    toCDML(): string;
    to_cdml(): string;
    evaluate(importsMap?: Record<string, string>): Promise<CdmlEvaluationResult>;
}
export declare function cdml(units?: string, linearTol?: string, angularTol?: string): CdmlDocument;
/**
 * Universal CDML Evaluator.
 * Evaluates CDML v1.0 XML strings against cad_core.wasm using the runtime's existing shared memory.
 */
export declare function evalCDML(xmlString: string, importsMap?: Record<string, string>): Promise<CdmlEvaluationResult>;
//# sourceMappingURL=cdml.d.ts.map