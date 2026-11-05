// scripts/test_cdml_compiler.mjs
import fs from 'node:fs';
import assert from 'node:assert/strict';

const wasmPath = './kernel-zig/zig-out/bin/cad_kernel.wasm';
assert.ok(fs.existsSync(wasmPath), `Missing compiled WASM at ${wasmPath}`);

const sharedMem = new WebAssembly.Memory({ initial: 128, maximum: 512, shared: true });
const wasmBytes = fs.readFileSync(wasmPath);

const imports = {
  env: { memory: sharedMem },
  opencad: {
    field_alloc: () => 0,
    field_eval_scalar: () => 40.0,
    field_eval_vec3: () => {},
    cmd_write: () => {},
  }
};

const { instance } = await WebAssembly.instantiate(wasmBytes, imports);
const api = instance.exports;

// 1. Verify required CDML ABI exports
for (const fn of [
  'cdml_register_import',
  'cdml_eval_document',
  'cdml_set_var',
  'cdml_get_probe_value',
]) {
  assert.equal(typeof api[fn], 'function', `Missing required CDML ABI export: ${fn}`);
}

api.kernel_init();

// Scratch string allocator
let scratchCursor = 0x300000;
function writeString(str) {
  const bytes = Buffer.from(str, 'utf-8');
  const ptr = scratchCursor;
  new Uint8Array(sharedMem.buffer).set(bytes, ptr);
  scratchCursor += bytes.length + 16;
  return { ptr, len: bytes.length };
}

function getDiagnostic() {
  const ptr = api.get_string_ptr();
  const len = api.get_string_len();
  if (!ptr || len === 0) return null;
  const bytes = new Uint8Array(sharedMem.buffer, ptr, len);
  const text = new TextDecoder().decode(bytes);
  try {
    return JSON.parse(text);
  } catch (e) {
    return { raw: text };
  }
}

console.log('=== TEST 1: CDML §14 Normative Document Evaluation ===');

// Register lib/materials.cdml
const matXml = `<?xml version="1.0" encoding="UTF-8"?>
<cdml version="1.0" units="mm">
  <defs>
    <material id="al6061" name="Aluminum 6061-T6" youngs-modulus="68.9e9" poisson="0.33" density="2700"/>
  </defs>
</cdml>`;
const matPathStr = writeString('lib/materials.cdml');
const matXmlStr = writeString(matXml);
const regMatRes = api.cdml_register_import(matPathStr.ptr, matPathStr.len, matXmlStr.ptr, matXmlStr.len);
assert.equal(regMatRes, 0x0000, 'Failed to register lib/materials.cdml');

// Register lib/fasteners.cdml
const fastXml = `<?xml version="1.0" encoding="UTF-8"?>
<cdml version="1.0" units="mm">
  <defs>
    <var id="bolt_d" value="6.0" unit="mm"/>
    <var id="bolt_pcd" value="35.0" unit="mm"/>
  </defs>
</cdml>`;
const fastPathStr = writeString('lib/fasteners.cdml');
const fastXmlStr = writeString(fastXml);
const regFastRes = api.cdml_register_import(fastPathStr.ptr, fastPathStr.len, fastXmlStr.ptr, fastXmlStr.len);
assert.equal(regFastRes, 0x0000, 'Failed to register lib/fasteners.cdml');

// Complete CDML §14 Normative Example
const normativeDocXml = `<?xml version="1.0" encoding="UTF-8"?>
<cdml version="1.0" units="mm" linear_tol="1e-7" angular_tol="1e-11">

  <!-- 1. IMPORTS: material library + fastener parameters -->
  <imports>
    <import src="lib/materials.cdml"/>              <!-- al6061 enters directly -->
    <import src="lib/fasteners.cdml" prefix="fs"/>  <!-- fs.bolt_d, fs.bolt_pcd -->
  </imports>

  <!-- 2. PARAMETERS, FIELD SLOTS, AND DESIGN ASSERTIONS -->
  <defs>
    <var id="flange_w"    value="90.0"  unit="mm" min="60.0" max="150.0"/>
    <var id="flange_h"    value="16.0"  unit="mm" min="8.0"  max="40.0"/>
    <var id="bore_r"      value="15.0"  unit="mm" min="8.0"  max="25.0"/>
    <var id="wall_margin" value="3.0"   unit="mm" min="1.5"  max="6.0"/>
    <var id="fillet_r"    value="4.0"   unit="mm" min="0.5"  max="10.0"/>
    <var id="period"      value="9.0"   unit="mm"/>

    <expr id="half_w"   expr="flange_w / 2"/>
    <expr id="infill_r" expr="bore_r + wall_margin"/>

    <!-- Field slot: FEA stress written by external extension after tessellation -->
    <field-slot id="stress_field" slot="0"
                semantic="stress"
                grid-x="64" grid-y="64" grid-z="24"
                default="40.0"/>

    <assert id="bore_clearance"
      expr="half_w - bore_r - wall_margin - 5.0"
      error="bore plus wall margin exceeds half flange width"/>
    <assert id="wall_positive"
      expr="flange_w * 0.5 - bore_r - wall_margin"
      error="no material between bore and edge"/>
  </defs>

  <body>

    <!-- 3. WORKPLANE AT Z = 0 -->
    <chart id="chart_xy">
      <vars>
        <vec3 id="p0" x="0.0" y="0.0" z="0.0" fixed="true"/>
        <vec3 id="e1" x="1.0" y="0.0" z="0.0" fixed="true"/>
        <vec3 id="e2" x="0.0" y="1.0" z="0.0" fixed="false"/>
      </vars>
      <constraints>
        <residual id="unit_e2"  expr="dot(e2, e2) - 1.0"/>
        <residual id="ortho"    expr="dot(e1, e2)"/>
        <residual id="planar_z" expr="dot(e2, vec3(0, 0, 1))"/>
      </constraints>
    </chart>

    <!-- 4. SKETCH: SQUARE PROFILE + EXACT CIRCLE BORE -->
    <sketch id="sk_flange" chart="chart_xy" max-iter="100">
      <vars>
        <point2d id="v0" u="-45.0" v="-45.0"/>
        <point2d id="v1" u=" 45.0" v="-45.0"/>
        <point2d id="v2" u=" 45.0" v=" 45.0"/>
        <point2d id="v3" u="-45.0" v=" 45.0"/>
      </vars>

      <wire id="wire_outer" closed="true" role="outer">
        <curve id="seg_bot" degree="1" ctrl="v0 v1" weights="1.0 1.0" knots="0 0 1 1"/>
        <curve id="seg_rgt" degree="1" ctrl="v1 v2" weights="1.0 1.0" knots="0 0 1 1"/>
        <curve id="seg_top" degree="1" ctrl="v2 v3" weights="1.0 1.0" knots="0 0 1 1"/>
        <curve id="seg_lft" degree="1" ctrl="v3 v0" weights="1.0 1.0" knots="0 0 1 1"/>
      </wire>

      <!-- Exact circle: parametric equation -->
      <wire id="wire_bore" closed="true" role="hole">
        <param-curve id="c_bore" param="t" domain="0 1"
          u-expr="ref(bore_r) * cos(2 * PI * t)"
          v-expr="ref(bore_r) * sin(2 * PI * t)"/>
      </wire>

      <constraints>
        <residual id="cx"    expr="v0.u + v1.u"/>
        <residual id="cy"    expr="v0.v + v3.v"/>
        <residual id="sym"   expr="v2.u + v3.u"/>
        <residual id="h0"    expr="v1.v - v0.v"/>
        <residual id="h1"    expr="v2.v - v3.v"/>
        <residual id="ortho" expr="dot(v1-v0, v2-v1)"/>
        <residual id="width" expr="norm(v1 - v0) - ref(flange_w)"/>
        <residual id="height" expr="norm(v2 - v1) - ref(flange_w)"/>
      </constraints>
    </sketch>

    <!-- 5. B-REP: LINEAR SWEEP + DIFFERENTIAL FILLET -->
    <brep id="solid_flange" material="al6061">
      <sweep id="sw_extrude" sketch="sk_flange" cap-ends="true">
        <trajectory>
          <translate x="0" y="0" z-expr="ref(flange_h) * v"/>
        </trajectory>
      </sweep>
      <fillet id="fillet_corners"
        edge-predicate="abs(tz) > 0.999 and x^2 + y^2 > ref(infill_r)^2"
        radius-expr="ref(fillet_r)"/>
    </brep>

    <!-- 5a. PROBE: mean field value on the bore faces of the B-Rep carrier -->
    <probe id="mean_bore_stress"
           type="face-mean"
           target="solid_flange"
           face-predicate="from_id('c_bore') and abs(k_gauss) < 1e-9"
           quantity="field_scalar(0, x, y, z, 40.0)"/>

    <!-- 6. IMPLICIT: GYROID INFILL -->
    <implicit id="solid_gyroid">
      <domain xmin="-45" xmax="45" ymin="-45" ymax="45" zmin="0" zmax="16"
              octree-depth="6" qef-reg="1e-4"/>
      <def name="omega" expr="2 * PI / ref(period)"/>
      <def name="g"
        expr="sin(omega*x)*cos(omega*y) +
              sin(omega*y)*cos(omega*z) +
              sin(omega*z)*cos(omega*x)"/>
      <def name="t_wall" expr="0.9 + 0.005 * probe('mean_bore_stress')"/>
      <field expr="abs_smooth(g, 1e-4) - (0.5 * omega * t_wall)"/>
    </implicit>

    <!-- 7. IMPLICIT: INFILL ZONE MASK -->
    <implicit id="solid_mask">
      <domain xmin="-45" xmax="45" ymin="-45" ymax="45" zmin="0" zmax="16"/>
      <def name="r"     expr="sqrt(x^2 + y^2)"/>
      <def name="d_box"
        expr="r_intersect(
                abs_smooth(x, 1e-3) - (ref(half_w) - ref(wall_margin)),
                abs_smooth(y, 1e-3) - (ref(half_w) - ref(wall_margin)))"/>
      <def name="d_z"
        expr="abs_smooth(z - ref(flange_h)*0.5, 1e-3)
              - (ref(flange_h)*0.5 - ref(wall_margin))"/>
      <def name="d_in" expr="ref(infill_r) - r"/>
      <field expr="r_intersect(r_intersect(d_box, d_z), d_in)"/>
    </implicit>

    <!-- 8. CSG: HYBRID BOOLEAN ASSEMBLY -->
    <csg id="solid_final">
      <boolean id="hollow_shell" op="subtract"
        left="solid_flange" right="solid_mask"/>
      <boolean id="lattice_core" op="intersect"
        left="solid_mask" right="solid_gyroid"/>
      <boolean id="assembly" op="union"
        left="hollow_shell" right="lattice_core"
        preserve-brep-tags="true" collar-tol="1e-6"/>
    </csg>

    <!-- 9. PROBES: geometry and field queries -->
    <probe id="max_fillet_stress"
           type="face-max"
           target="solid_final"
           face-predicate="abs(k_gauss) > 1e-6"
           quantity="field_scalar(0, x, y, z, 40.0)"/>

    <probe id="housing_volume"
           type="volume"
           target="solid_final"/>

    <assert id="stress_limit"
      expr="200.0 - probe('max_fillet_stress')"
      error="fillet stress exceeds 200 MPa yield margin"/>

    <!-- 10. BOLT HOLE: sketch on chart_xy, swept through the flange -->
    <sketch id="sk_bolt" chart="chart_xy">
      <wire id="wire_bolt" closed="true" role="outer">
        <param-curve id="c_bolt_profile" param="t" domain="0 1"
          u-expr="ref(fs.bolt_pcd) + ref(fs.bolt_d)/2 * cos(2*PI*t)"
          v-expr="ref(fs.bolt_d)/2 * sin(2*PI*t)"/>
      </wire>
    </sketch>

    <brep id="solid_bolt_hole">
      <sweep id="sw_bolt" sketch="sk_bolt" cap-ends="true">
        <trajectory>
          <translate x="0" y="0" z-expr="ref(flange_h) * v"/>
        </trajectory>
      </sweep>
    </brep>

    <repeat id="bolt_pattern" count="4" ref="solid_bolt_hole">
      <transform>
        <rotate axis="0 0 1" angle-expr="PI/2 * i"/>
      </transform>
    </repeat>

    <!-- 11. COMPOSE: SEMANTIC ROLE ASSIGNMENT -->
    <compose id="housing">
      <layer ref="solid_final"  role="shell"/>
      <layer ref="bolt_pattern" role="void"/>
    </compose>

  </body>

  <!-- 12. EXPORT TARGETS -->
  <exports>
    <tessellate target="solid_final" chord-tol="0.02" angle-tol="0.05"/>
    <step        target="solid_flange" schema="AP214"/>
    <stl         target="solid_final"  binary="true"/>
  </exports>

</cdml>`;

const docStr = writeString(normativeDocXml);
const evalStatus = api.cdml_eval_document(docStr.ptr, docStr.len);
if (evalStatus !== 0x0000) {
  console.error('CDML Evaluation failed with diagnostic:', getDiagnostic());
}
assert.equal(evalStatus, 0x0000, `Expected CDML_OK (0x0000), got 0x${evalStatus.toString(16)}`);

// Probe 1: mean_bore_stress == 40.0
const probe1Str = writeString('mean_bore_stress');
const outF64_1 = 0x3E0000;
const p1Res = api.cdml_get_probe_value(probe1Str.ptr, probe1Str.len, outF64_1);
assert.equal(p1Res, 0x0000, 'cdml_get_probe_value for mean_bore_stress failed');
const p1Val = new Float64Array(sharedMem.buffer, outF64_1, 1)[0];
assert.equal(p1Val, 40.0, `Expected probe mean_bore_stress == 40.0, got ${p1Val}`);

// Probe 2: housing_volume > 0
const probe2Str = writeString('housing_volume');
const outF64_2 = 0x3E0010;
const p2Res = api.cdml_get_probe_value(probe2Str.ptr, probe2Str.len, outF64_2);
assert.equal(p2Res, 0x0000, 'cdml_get_probe_value for housing_volume failed');
const p2Val = new Float64Array(sharedMem.buffer, outF64_2, 1)[0];
assert.ok(p2Val > 0, `Expected probe housing_volume > 0, got ${p2Val}`);

// Tessellation buffer at 0x0F0000
const ctrlView = new DataView(sharedMem.buffer, 0x0F0000, 128);
const solidId = ctrlView.getUint32(0x00, true);
const vCount = ctrlView.getUint32(0x04, true);
const triCount = ctrlView.getUint32(0x08, true);
const posOffset = ctrlView.getUint32(0x0C, true);
const faceOffset = ctrlView.getUint32(0x18, true);

assert.ok(vCount >= 4, `Expected at least 4 vertices, got ${vCount}`);
assert.ok(triCount >= 4, `Expected at least 4 triangles, got ${triCount}`);
assert.equal(posOffset, 0x0F0080);
assert.ok(faceOffset > posOffset);

// Check 192-bit TopoId per triangle (24 bytes per triangle: 3 uint64 words)
const topoView = new BigUint64Array(sharedMem.buffer, faceOffset, triCount * 3);
assert.equal(topoView.length, triCount * 3, 'Face IDs buffer must contain 3 u64 words per triangle');
assert.ok(topoView[0] !== 0n, 'First triangle TopoId feature_hash must be non-zero');

// Check exports
const upperBits = ctrlView.getUint32(0x1C, true);
const fullHandle = (BigInt(upperBits) << 32n) | BigInt(solidId);
console.log('solidId:', solidId, 'upper:', upperBits, 'fullHandle:', '0x' + fullHandle.toString(16));
const stepLen = api.solid_export_step(fullHandle);
assert.ok(stepLen > 0, 'STEP export must not be empty');
const stlLen = api.solid_export_stl(BigInt(solidId), 1);
assert.ok(stlLen > 84, 'STL binary export must be > 84 bytes');

console.log(`[PASS] Test 1: CDML §14 evaluated cleanly. V: ${vCount}, Triangles: ${triCount}, TopoIds verified.`);

console.log('=== TEST 2: Fast Parameter Update & Assert Violation Handling ===');
// Snapshot 0x0F0000 mesh before mutation
const beforeSnapshot = new Uint8Array(sharedMem.buffer, 0x0F0000, 128).slice();

// Set bore_r to 42.0 (violates bore_clearance assert)
const boreRStr = writeString('bore_r');
const setVarRes = api.cdml_set_var(boreRStr.ptr, boreRStr.len, 42.0);
assert.equal(setVarRes, 0x0203, `Expected ERR_ASSERT_VIOLATED (0x0203), got 0x${setVarRes.toString(16)}`);

const diag = getDiagnostic();
assert.ok(diag, 'Expected JSON diagnostic record');
assert.equal(diag.code, '0x0203');
assert.equal(diag.id, 'bore_clearance');

// Verify 0x0F0000 holds previous valid mesh untouched!
const afterSnapshot = new Uint8Array(sharedMem.buffer, 0x0F0000, 128);
assert.deepEqual(beforeSnapshot, afterSnapshot, '0x0F0000 tessellation buffer must remain untouched on assert failure!');
console.log('[PASS] Test 2: ERR_ASSERT_VIOLATED caught, JSON diagnostic emitted, buffer untouched.');

console.log('=== TEST 3: Deterministic Error Handling Path Verification ===');

// 3a. ERR_DAG_CYCLE (0x0103)
const cycleXml = `<?xml version="1.0" encoding="UTF-8"?>
<cdml version="1.0" units="mm">
  <defs>
    <expr id="var_a" expr="var_b + 1.0"/>
    <expr id="var_b" expr="var_a + 1.0"/>
  </defs>
  <body/>
</cdml>`;
const cycleStr = writeString(cycleXml);
const cycleRes = api.cdml_eval_document(cycleStr.ptr, cycleStr.len);
assert.equal(cycleRes, 0x0103, `Expected ERR_DAG_CYCLE (0x0103), got 0x${cycleRes.toString(16)}`);
const diagCycle = getDiagnostic();
assert.equal(diagCycle.code, '0x0103');
console.log('[PASS] Test 3a: ERR_DAG_CYCLE verified.');

// 3b. ERR_UNDEFINED_REF (0x0104)
const undefXml = `<?xml version="1.0" encoding="UTF-8"?>
<cdml version="1.0" units="mm">
  <defs>
    <expr id="good_var" expr="nonexistent_var_xyz * 2.0"/>
  </defs>
  <body/>
</cdml>`;
const undefStr = writeString(undefXml);
const undefRes = api.cdml_eval_document(undefStr.ptr, undefStr.len);
assert.equal(undefRes, 0x0104, `Expected ERR_UNDEFINED_REF (0x0104), got 0x${undefRes.toString(16)}`);
const diagUndef = getDiagnostic();
assert.equal(diagUndef.code, '0x0104');
console.log('[PASS] Test 3b: ERR_UNDEFINED_REF verified.');

// 3c. ERR_EXPR_CONTEXT (0x0204)
const ctxXml = `<?xml version="1.0" encoding="UTF-8"?>
<cdml version="1.0" units="mm">
  <defs>
    <expr id="bad_ctx" expr="10.0 + nx"/>
  </defs>
  <body/>
</cdml>`;
const ctxStr = writeString(ctxXml);
const ctxRes = api.cdml_eval_document(ctxStr.ptr, ctxStr.len);
assert.equal(ctxRes, 0x0204, `Expected ERR_EXPR_CONTEXT (0x0204), got 0x${ctxRes.toString(16)}`);
const diagCtx = getDiagnostic();
assert.equal(diagCtx.code, '0x0204');
console.log('[PASS] Test 3c: ERR_EXPR_CONTEXT verified.');

// 3d. ERR_FILLET_RADIUS_COLLAPSE (0x0402)
const filletXml = `<?xml version="1.0" encoding="UTF-8"?>
<cdml version="1.0" units="mm">
  <defs>
    <var id="flange_w" value="90.0"/>
    <var id="flange_h" value="16.0"/>
  </defs>
  <body>
    <brep id="b1">
      <fillet id="f1" radius-expr="100.0"/>
    </brep>
  </body>
</cdml>`;
const filletStr = writeString(filletXml);
const filletRes = api.cdml_eval_document(filletStr.ptr, filletStr.len);
assert.equal(filletRes, 0x0402, `Expected ERR_FILLET_RADIUS_COLLAPSE (0x0402), got 0x${filletRes.toString(16)}`);
const diagFillet = getDiagnostic();
assert.equal(diagFillet.code, '0x0402');
console.log('[PASS] Test 3d: ERR_FILLET_RADIUS_COLLAPSE verified.');

// --- Append to the bottom of scripts/test_cdml_compiler.mjs ---
// Adapter helpers for the Randomized Acid Test block
function evalCdmlString(xmlStr) {
  const enc = new TextEncoder().encode(xmlStr);
  const scratchOffset = 0x3A0000; // Safe input staging offset in SharedArrayBuffer
  new Uint8Array(sharedMem.buffer, scratchOffset, enc.length).set(enc);
  return api.cdml_eval_document(scratchOffset, enc.length);
}

function getProbeValue(probeId) {
  const idBytes = new TextEncoder().encode(probeId);
  const idOffset = 0x3B0000;
  const outF64Offset = 0x3B1000;
  new Uint8Array(sharedMem.buffer, idOffset, idBytes.length).set(idBytes);
  if (typeof api.cdml_get_probe_value === 'function') {
    const st = api.cdml_get_probe_value(idOffset, idBytes.length, outF64Offset);
    assert.equal(st, 0, `cdml_get_probe_value failed for ${probeId}`);
    return new DataView(sharedMem.buffer).getFloat64(outF64Offset, true);
  }
  // Fallback via expr_compile("probe('...')") + expr_eval
  const exprBytes = new TextEncoder().encode(`probe('${probeId}')`);
  new Uint8Array(sharedMem.buffer, idOffset, exprBytes.length).set(exprBytes);
  const exprH = api.expr_compile(idOffset, exprBytes.length);
  return api.expr_eval(exprH, 0, 0, 0);
}

{
  const sfx = Math.floor(1000 + Math.random() * 9000);
  const vR = `rad_${sfx}`, vH = `hgt_${sfx}`, vW = `wid_${sfx}`;

  // Acid Test A: Pure Region Cylinder (Volume = pi * R^2 * H = pi * 12^2 * 25 = 11309.7335)
  const regionXml = `<?xml version="1.0" encoding="UTF-8"?>
  <cdml version="1.0" units="mm">
    <defs>
      <var id="${vR}" value="12.0" unit="mm"/>
      <var id="${vH}" value="25.0" unit="mm"/>
    </defs>
    <body>
      <surface id="s_${sfx}"><eq>x^2 + y^2 - ref(${vR})^2</eq></surface>
      <region id="reg_${sfx}">
        <and>
          <ineq id="iw_${sfx}" surface="s_${sfx}" sense="-"/>
          <ineq id="ib_${sfx}">z</ineq>
          <ineq id="it_${sfx}">ref(${vH}) - z</ineq>
        </and>
      </region>
      <brep id="cyl_${sfx}" region="reg_${sfx}"/>
      <probe id="vol_${sfx}" type="volume" target="cyl_${sfx}"/>
    </body>
    <exports><tessellate target="cyl_${sfx}" chord-tol="0.02" angle-tol="0.05"/></exports>
  </cdml>`;

  const stA = evalCdmlString(regionXml);
  assert.equal(stA, 0, `Acid Test A (Region Cylinder) failed with status ${stA}`);
  const volA = getProbeValue(`vol_${sfx}`);
  const expectedCylVol = Math.PI * 12.0 * 12.0 * 25.0;
  assert.ok(Math.abs(volA - expectedCylVol) / expectedCylVol < 0.02,
    `Acid Test A Volume mismatch: got ${volA}, expected ~${expectedCylVol}`);

  // Acid Test B: Constrained Sketch Square with +/-10 seeds forced to W=37.5, swept by H=10 -> Vol = 14062.5
  const sketchXml = `<?xml version="1.0" encoding="UTF-8"?>
  <cdml version="1.0" units="mm">
    <defs>
      <var id="${vW}" value="37.5" unit="mm"/>
      <var id="${vH}" value="10.0" unit="mm"/>
    </defs>
    <body>
      <chart id="ch_${sfx}">
        <vars>
          <vec3 id="p0" x="0.0" y="0.0" z="0.0" fixed="true"/>
          <vec3 id="e1" x="1.0" y="0.0" z="0.0" fixed="true"/>
          <vec3 id="e2" x="0.0" y="1.0" z="0.0" fixed="false"/>
        </vars>
        <constraints>
          <residual id="u2" expr="dot(e2, e2) - 1.0"/>
          <residual id="or" expr="dot(e1, e2)"/>
          <residual id="pz" expr="dot(e2, vec3(0, 0, 1))"/>
        </constraints>
      </chart>
      <sketch id="sk_${sfx}" chart="ch_${sfx}" max-iter="100">
        <vars>
          <point2d id="v0" u="-10.0" v="-10.0"/>
          <point2d id="v1" u=" 10.0" v="-10.0"/>
          <point2d id="v2" u=" 10.0" v=" 10.0"/>
          <point2d id="v3" u="-10.0" v=" 10.0"/>
        </vars>
        <wire id="w_${sfx}" closed="true" role="outer">
          <curve id="c0" degree="1" ctrl="v0 v1" weights="1.0 1.0" knots="0 0 1 1"/>
          <curve id="c1" degree="1" ctrl="v1 v2" weights="1.0 1.0" knots="0 0 1 1"/>
          <curve id="c2" degree="1" ctrl="v2 v3" weights="1.0 1.0" knots="0 0 1 1"/>
          <curve id="c3" degree="1" ctrl="v3 v0" weights="1.0 1.0" knots="0 0 1 1"/>
        </wire>
        <constraints>
          <residual id="cx" expr="v0.u + v1.u"/>
          <residual id="cy" expr="v0.v + v3.v"/>
          <residual id="sy" expr="v2.u + v3.u"/>
          <residual id="h0" expr="v1.v - v0.v"/>
          <residual id="h1" expr="v2.v - v3.v"/>
          <residual id="ot" expr="dot(v1 - v0, v2 - v1)"/>
          <residual id="we" expr="dot(v1 - v0, v1 - v0) - ref(${vW})^2"/>
          <residual id="he" expr="dot(v2 - v1, v2 - v1) - ref(${vW})^2"/>
        </constraints>
      </sketch>
      <brep id="box_${sfx}">
        <sweep id="sw_${sfx}" sketch="sk_${sfx}" cap-ends="true">
          <trajectory><translate x="0" y="0" z-expr="ref(${vH}) * v"/></trajectory>
        </sweep>
      </brep>
      <probe id="bvol_${sfx}" type="volume" target="box_${sfx}"/>
    </body>
    <exports><tessellate target="box_${sfx}" chord-tol="0.05" angle-tol="0.1"/></exports>
  </cdml>`;

  const stB = evalCdmlString(sketchXml);
  assert.equal(stB, 0, `Acid Test B (Constrained Sketch Sweep) failed with status ${stB}`);
  const volB = getProbeValue(`bvol_${sfx}`);
  assert.ok(Math.abs(volB - 14062.5) < 1.0,
    `Acid Test B Volume mismatch: got ${volB}, expected 14062.5 (37.5 * 37.5 * 10.0)`);
  console.log('[ACID TEST PASSED] Randomized Region Cylinder Vol =', volA.toFixed(2), '| Solved Sketch Vol =', volB.toFixed(2));
}

console.log('=== ALL CDML v1.0 COMPILER TESTS PASSED CLEANLY ===');
