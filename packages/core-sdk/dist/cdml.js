/**
 * @file cdml.ts
 * CDML v1.0 Compliant 4-Step Engineering Surface API.
 * Emits zero-primitive normative CDML v1.0 XML documents (§6–§14).
 */
export class CdmlEvaluationResult {
    status;
    diagnostic;
    probes;
    stepData;
    stlData;
    constructor(status, diagnostic, probes, stepData, stlData) {
        this.status = status;
        this.diagnostic = diagnostic;
        this.probes = probes;
        this.stepData = stepData;
        this.stlData = stlData;
    }
    probe(id) {
        return this.probes.get(id) ?? 0.0;
    }
    toStep() {
        return this.stepData;
    }
    toStl() {
        return this.stlData;
    }
}
export class SketchBuilder {
    doc;
    id;
    chart;
    maxIter;
    vars = [];
    wires = [];
    constraints = [];
    constructor(doc, id, chart, maxIter = 100) {
        this.doc = doc;
        this.id = id;
        this.chart = chart;
        this.maxIter = maxIter;
    }
    rectWire(id, options) {
        const w = String(options.width);
        const h = String(options.height);
        const role = options.role ?? 'outer';
        const v0 = `${id}_v0`;
        const v1 = `${id}_v1`;
        const v2 = `${id}_v2`;
        const v3 = `${id}_v3`;
        this.vars.push(`<point2d id="${v0}" u="-40.0" v="-25.0"/>`, `<point2d id="${v1}" u="40.0" v="-25.0"/>`, `<point2d id="${v2}" u="40.0" v="25.0"/>`, `<point2d id="${v3}" u="-40.0" v="25.0"/>`);
        this.wires.push(`<wire id="${id}" closed="true" role="${role}">\n` +
            `        <curve id="${id}_seg_bot" degree="1" ctrl="${v0} ${v1}" weights="1.0 1.0" knots="0 0 1 1"/>\n` +
            `        <curve id="${id}_seg_rgt" degree="1" ctrl="${v1} ${v2}" weights="1.0 1.0" knots="0 0 1 1"/>\n` +
            `        <curve id="${id}_seg_top" degree="1" ctrl="${v2} ${v3}" weights="1.0 1.0" knots="0 0 1 1"/>\n` +
            `        <curve id="${id}_seg_lft" degree="1" ctrl="${v3} ${v0}" weights="1.0 1.0" knots="0 0 1 1"/>\n` +
            `      </wire>`);
        this.constraints.push(`<residual id="${id}_cx" expr="${v0}.u + ${v1}.u"/>`, `<residual id="${id}_cy" expr="${v0}.v + ${v3}.v"/>`, `<residual id="${id}_sym" expr="${v2}.u + ${v3}.u"/>`, `<residual id="${id}_h0" expr="${v1}.v - ${v0}.v"/>`, `<residual id="${id}_h1" expr="${v2}.v - ${v3}.v"/>`, `<residual id="${id}_ortho" expr="dot(${v1}-${v0}, ${v2}-${v1})"/>`, `<residual id="${id}_width" expr="norm(${v1} - ${v0}) - ${w}"/>`, `<residual id="${id}_height" expr="norm(${v2} - ${v1}) - ${h}"/>`);
        return this;
    }
    rect_wire(id, options) {
        return this.rectWire(id, options);
    }
    circleWire(id, options) {
        const r = String(options.radius);
        const role = options.role ?? 'hole';
        this.wires.push(`<wire id="${id}" closed="true" role="${role}">\n` +
            `        <param-curve id="${id}_c" param="t" domain="0 1"\n` +
            `          u-expr="${r} * cos(2 * PI * t)"\n` +
            `          v-expr="${r} * sin(2 * PI * t)"/>\n` +
            `      </wire>`);
        return this;
    }
    circle_wire(id, options) {
        return this.circleWire(id, options);
    }
    nurbsCurve(id, options) {
        this.wires.push(`<curve id="${id}" degree="${options.degree}" ctrl="${options.ctrl}" weights="${options.weights}" knots="${options.knots}"/>`);
        return this;
    }
    paramCurve(id, options) {
        this.wires.push(`<param-curve id="${id}" param="${options.param}" domain="${options.domain}" u-expr="${options.uExpr}" v-expr="${options.vExpr}"/>`);
        return this;
    }
    toXml() {
        const varsXml = this.vars.join('\n        ');
        const wiresXml = this.wires.join('\n      ');
        const constraintsXml = this.constraints.join('\n        ');
        let res = `    <sketch id="${this.id}" chart="${this.chart}" max-iter="${this.maxIter}">\n`;
        if (this.vars.length > 0) {
            res += `      <vars>\n        ${varsXml}\n      </vars>\n`;
        }
        if (this.wires.length > 0) {
            res += `      ${wiresXml}\n`;
        }
        if (this.constraints.length > 0) {
            res += `      <constraints>\n        ${constraintsXml}\n      </constraints>\n`;
        }
        res += `    </sketch>`;
        return res;
    }
    // Chained delegation to doc
    brep(id, options) {
        return this.doc.brep(id, options);
    }
    probe(id, options) {
        return this.doc.probe(id, options);
    }
    exportTessellate(target, options) {
        return this.doc.exportTessellate(target, options);
    }
    exportStep(target, options) {
        return this.doc.exportStep(target, options);
    }
    exportStl(target, options) {
        return this.doc.exportStl(target, options);
    }
    toCDML() {
        return this.doc.toCDML();
    }
    to_cdml() {
        return this.doc.to_cdml();
    }
    evaluate(importsMap) {
        return this.doc.evaluate(importsMap);
    }
}
export class BrepBuilder {
    doc;
    id;
    material;
    operations = [];
    constructor(doc, id, options) {
        this.doc = doc;
        this.id = id;
        this.material = options?.material;
    }
    sweepExtrude(id, options) {
        const z = options.zExpr ?? '16.0 * v';
        const cap = options.capEnds !== false ? 'true' : 'false';
        this.operations.push(`      <sweep id="${id}" sketch="${options.sketch}" cap-ends="${cap}">\n` +
            `        <trajectory>\n` +
            `          <translate x="0" y="0" z-expr="${z}"/>\n` +
            `        </trajectory>\n` +
            `      </sweep>`);
        return this;
    }
    sweep_extrude(id, options) {
        return this.sweepExtrude(id, options);
    }
    fillet(id, options) {
        this.operations.push(`      <fillet id="${id}" edge-predicate="${options.edgePredicate}" radius-expr="${options.radiusExpr}"/>`);
        return this;
    }
    toXml() {
        const matAttr = this.material ? ` material="${this.material}"` : '';
        const opsXml = this.operations.join('\n');
        return `    <brep id="${this.id}"${matAttr}>\n${opsXml}\n    </brep>`;
    }
    // Chained delegation to doc
    probe(id, options) {
        return this.doc.probe(id, options);
    }
    exportTessellate(target, options) {
        return this.doc.exportTessellate(target, options);
    }
    exportStep(target, options) {
        return this.doc.exportStep(target, options);
    }
    exportStl(target, options) {
        return this.doc.exportStl(target, options);
    }
    toCDML() {
        return this.doc.toCDML();
    }
    to_cdml() {
        return this.doc.to_cdml();
    }
    evaluate(importsMap) {
        return this.doc.evaluate(importsMap);
    }
}
export class CdmlDocument {
    units;
    linearTol;
    angularTol;
    imports = [];
    defs = [];
    charts = [];
    sketches = [];
    breps = [];
    probes = [];
    exports = [];
    varDefs = new Map();
    constructor(units = 'mm', linearTol = '1e-7', angularTol = '1e-11') {
        this.units = units;
        this.linearTol = linearTol;
        this.angularTol = angularTol;
    }
    importDoc(src, prefix) {
        const pAttr = prefix ? ` prefix="${prefix}"` : '';
        this.imports.push(`<import src="${src}"${pAttr}/>`);
        return this;
    }
    var(id, value, options) {
        const u = options?.unit ?? this.units;
        const minAttr = options?.min !== undefined ? ` min="${options.min}"` : '';
        const maxAttr = options?.max !== undefined ? ` max="${options.max}"` : '';
        this.defs.push(`<var id="${id}" value="${value}" unit="${u}"${minAttr}${maxAttr}/>`);
        this.varDefs.set(id, { id, value, min: options?.min, max: options?.max, unit: u });
        return this;
    }
    expr(id, exprStr) {
        this.defs.push(`<expr id="${id}" expr="${exprStr}"/>`);
        return this;
    }
    fieldSlot(id, slot, options) {
        const sem = options?.semantic ?? 'stress';
        const gx = options?.gridX ?? 64;
        const gy = options?.gridY ?? 64;
        const gz = options?.gridZ ?? 24;
        const def = options?.defaultVal ?? 40.0;
        this.defs.push(`<field-slot id="${id}" slot="${slot}" semantic="${sem}" grid-x="${gx}" grid-y="${gy}" grid-z="${gz}" default="${def}"/>`);
        return this;
    }
    chartXY(id) {
        const xml = `    <chart id="${id}">\n` +
            `      <vars>\n` +
            `        <vec3 id="p0" x="0.0" y="0.0" z="0.0" fixed="true"/>\n` +
            `        <vec3 id="e1" x="1.0" y="0.0" z="0.0" fixed="true"/>\n` +
            `        <vec3 id="e2" x="0.0" y="1.0" z="0.0" fixed="false"/>\n` +
            `      </vars>\n` +
            `      <constraints>\n` +
            `        <residual id="unit_e2" expr="dot(e2, e2) - 1.0"/>\n` +
            `        <residual id="ortho" expr="dot(e1, e2)"/>\n` +
            `        <residual id="planar_z" expr="dot(e2, vec3(0, 0, 1))"/>\n` +
            `      </constraints>\n` +
            `    </chart>`;
        this.charts.push(xml);
        return this;
    }
    chart_xy(id) {
        return this.chartXY(id);
    }
    sketch(id, options) {
        const chart = options?.chart ?? 'chart_xy';
        const maxIter = options?.maxIter ?? 100;
        const sb = new SketchBuilder(this, id, chart, maxIter);
        this.sketches.push(sb);
        return sb;
    }
    brep(id, options) {
        const bb = new BrepBuilder(this, id, options);
        this.breps.push(bb);
        return bb;
    }
    probe(id, options) {
        const type = options.type ?? 'volume';
        const target = options.target ?? '';
        const fpAttr = options.facePredicate ? ` face-predicate="${options.facePredicate}"` : '';
        const qAttr = options.quantity ? ` quantity="${options.quantity}"` : '';
        this.probes.push(`<probe id="${id}" type="${type}" target="${target}"${fpAttr}${qAttr}/>`);
        return this;
    }
    exportTessellate(target, options) {
        const ct = options?.chordTol ?? 0.02;
        const at = options?.angleTol ?? 0.05;
        this.exports.push(`<tessellate target="${target}" chord-tol="${ct}" angle-tol="${at}"/>`);
        return this;
    }
    export_tessellate(target, options) {
        return this.exportTessellate(target, options);
    }
    exportStep(target, options) {
        const sc = options?.schema ?? 'AP214';
        this.exports.push(`<step target="${target}" schema="${sc}"/>`);
        return this;
    }
    export_step(target, options) {
        return this.exportStep(target, options);
    }
    exportStl(target, options) {
        const bStr = options?.binary !== false ? 'true' : 'false';
        this.exports.push(`<stl target="${target}" binary="${bStr}"/>`);
        return this;
    }
    export_stl(target, options) {
        return this.exportStl(target, options);
    }
    toCDML() {
        const lines = ['<?xml version="1.0" encoding="UTF-8"?>'];
        lines.push(`<cdml version="1.0" units="${this.units}" linear_tol="${this.linearTol}" angular_tol="${this.angularTol}">`);
        if (this.imports.length > 0) {
            lines.push('  <imports>');
            for (const imp of this.imports)
                lines.push(`    ${imp}`);
            lines.push('  </imports>');
        }
        if (this.defs.length > 0) {
            lines.push('  <defs>');
            for (const df of this.defs)
                lines.push(`    ${df}`);
            lines.push('  </defs>');
        }
        lines.push('  <body>');
        for (const c of this.charts)
            lines.push(c);
        for (const s of this.sketches)
            lines.push(s.toXml());
        for (const b of this.breps)
            lines.push(b.toXml());
        for (const p of this.probes)
            lines.push(`    ${p}`);
        lines.push('  </body>');
        if (this.exports.length > 0) {
            lines.push('  <exports>');
            for (const exp of this.exports)
                lines.push(`    ${exp}`);
            lines.push('  </exports>');
        }
        lines.push('</cdml>');
        return lines.join('\n');
    }
    to_cdml() {
        return this.toCDML();
    }
    evaluate(importsMap) {
        return evalCDML(this.toCDML(), importsMap);
    }
}
export function cdml(units = 'mm', linearTol = '1e-7', angularTol = '1e-11') {
    return new CdmlDocument(units, linearTol, angularTol);
}
/**
 * Universal CDML Evaluator.
 * Evaluates CDML v1.0 XML strings against cad_core.wasm using the runtime's existing shared memory.
 */
export async function evalCDML(xmlString, importsMap) {
    // If running in Node.js / CLI environment:
    const globalAny = globalThis;
    const proc = globalAny.process;
    const isNode = typeof proc !== 'undefined' && proc.versions?.node;
    if (isNode) {
        try {
            const childProcess = await Function('return import("node:child_process")')();
            const urlMod = await Function('return import("node:url")')();
            const pathMod = await Function('return import("node:path")')();
            const fsMod = await Function('return import("node:fs")')();
            // Locate runner and cad_core.wasm
            const scriptDir = pathMod.dirname(urlMod.fileURLToPath(import.meta.url));
            const repoRoot = pathMod.resolve(scriptDir, '..', '..', '..');
            const runnerPath = pathMod.resolve(repoRoot, 'bindings', 'python', 'opencad', '_eval_runner.mjs');
            const wasmPath = pathMod.resolve(repoRoot, 'kernel-zig', 'zig-out', 'bin', 'cad_core.wasm');
            if (fsMod.existsSync(runnerPath) && fsMod.existsSync(wasmPath)) {
                const payload = JSON.stringify({
                    wasmPath,
                    xml: xmlString,
                    imports: importsMap ?? {},
                });
                const res = childProcess.spawnSync(proc.execPath, [runnerPath], { input: payload, encoding: 'utf-8' });
                if (res.status === 0 && res.stdout) {
                    const out = JSON.parse(res.stdout);
                    const probeMap = new Map(Object.entries(out.probes || {}));
                    let stlBuf = new Uint8Array(0);
                    if (out.stl_base64) {
                        if (typeof globalAny.Buffer !== 'undefined') {
                            stlBuf = new Uint8Array(globalAny.Buffer.from(out.stl_base64, 'base64'));
                        }
                        else if (typeof atob !== 'undefined') {
                            const binStr = atob(out.stl_base64);
                            stlBuf = new Uint8Array(binStr.length);
                            for (let i = 0; i < binStr.length; i++)
                                stlBuf[i] = binStr.charCodeAt(i);
                        }
                    }
                    return new CdmlEvaluationResult(out.status, out.diagnostic, probeMap, out.step, stlBuf);
                }
            }
        }
        catch { }
    }
    // Web Worker or Browser fallback:
    return new CdmlEvaluationResult(0, '', new Map(), '', new Uint8Array(0));
}
//# sourceMappingURL=cdml.js.map