// scripts/test_canary_extension.mjs
import fs from 'node:fs';
import assert from 'node:assert/strict';

const kernelPath = './kernel-zig/zig-out/bin/cad_kernel.wasm';
const canaryPath = fs.existsSync('./extensions/field_canary/ext_field_canary.wasm')
  ? './extensions/field_canary/ext_field_canary.wasm'
  : './extensions/field_canary/zig-out/bin/ext_field_canary.wasm';

assert.ok(fs.existsSync(kernelPath), `Missing kernel WASM at ${kernelPath}`);
assert.ok(fs.existsSync(canaryPath), `Missing canary WASM at ${canaryPath}`);

// 1. Single SharedArrayBuffer Memory Instance (Rule 2 & Gate 4)
const sharedMem = new WebAssembly.Memory({ initial: 128, maximum: 512, shared: true });

let lastCommand = null;
const opencadImports = {
  field_alloc: (slot, gx, gy, gz) => {
    return 0;
  },
  field_eval_scalar: (slot, x, y, z, defVal) => defVal,
  field_eval_vec3: (slot, x, y, z, outPtr) => {},
  cmd_write: (cmdType, a0, a1, a2, payloadPtr) => {
    lastCommand = { cmdType, a0, a1, a2, payloadPtr };
  },
};

// 2. Instantiate Kernel and Canary sharing the exact same WebAssembly.Memory
const kernelBytes = fs.readFileSync(kernelPath);
const canaryBytes = fs.readFileSync(canaryPath);

const { instance: kernelInst } = await WebAssembly.instantiate(kernelBytes, {
  env: { memory: sharedMem },
  opencad: opencadImports,
});
const cadApi = kernelInst.exports;

const { instance: canaryInst } = await WebAssembly.instantiate(canaryBytes, {
  env: { memory: sharedMem },
  opencad: opencadImports,
});
const extApi = canaryInst.exports;

assert.equal(typeof extApi.extension_tick, 'function', 'Missing extension_tick export in ext_field_canary.wasm');

cadApi.kernel_init();

let scratchCursor = 0x300000;
function writeString(str) {
  const bytes = Buffer.from(str, 'utf-8');
  const ptr = scratchCursor;
  new Uint8Array(sharedMem.buffer).set(bytes, ptr);
  scratchCursor += bytes.length + 16;
  return { ptr, len: bytes.length };
}

// 3. Register imports
const matXml = `<?xml version="1.0" encoding="UTF-8"?>
<cdml version="1.0" units="mm">
  <defs>
    <material id="al6061" name="Aluminum 6061-T6" youngs-modulus="68.9e9" poisson="0.33" density="2700"/>
  </defs>
</cdml>`;
const mP = writeString('lib/materials.cdml');
const mV = writeString(matXml);
cadApi.cdml_register_import(mP.ptr, mP.len, mV.ptr, mV.len);

const fastXml = `<?xml version="1.0" encoding="UTF-8"?>
<cdml version="1.0" units="mm">
  <defs>
    <var id="bolt_d" value="6.0" unit="mm"/>
    <var id="bolt_pcd" value="35.0" unit="mm"/>
  </defs>
</cdml>`;
const fP = writeString('lib/fasteners.cdml');
const fV = writeString(fastXml);
cadApi.cdml_register_import(fP.ptr, fP.len, fV.ptr, fV.len);

// CDML §14 Normative Document
const normativeDocXml = `<?xml version="1.0" encoding="UTF-8"?>
<cdml version="1.0" units="mm" linear_tol="1e-7" angular_tol="1e-11">
  <imports>
    <import src="lib/materials.cdml"/>
    <import src="lib/fasteners.cdml" prefix="fs"/>
  </imports>
  <defs>
    <var id="flange_w"    value="90.0"  unit="mm" min="60.0" max="150.0"/>
    <var id="flange_h"    value="16.0"  unit="mm" min="8.0"  max="40.0"/>
    <var id="bore_r"      value="15.0"  unit="mm" min="8.0"  max="25.0"/>
    <var id="wall_margin" value="3.0"   unit="mm" min="1.5"  max="6.0"/>
    <var id="fillet_r"    value="4.0"   unit="mm" min="0.5"  max="10.0"/>
    <var id="period"      value="9.0"   unit="mm"/>

    <expr id="half_w"   expr="flange_w / 2"/>
    <expr id="infill_r" expr="bore_r + wall_margin"/>

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
    <probe id="mean_bore_stress"
           type="face-mean"
           target="solid_flange"
           face-predicate="from_id('c_bore') and abs(k_gauss) < 1e-9"
           quantity="field_scalar(0, x, y, z, 40.0)"/>
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
    <csg id="solid_final">
      <boolean id="hollow_shell" op="subtract"
        left="solid_flange" right="solid_mask"/>
      <boolean id="lattice_core" op="intersect"
        left="solid_mask" right="solid_gyroid"/>
      <boolean id="assembly" op="union"
        left="hollow_shell" right="lattice_core"
        preserve-brep-tags="true" collar-tol="1e-6"/>
    </csg>
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
    <compose id="housing">
      <layer ref="solid_final"  role="shell"/>
      <layer ref="bolt_pattern" role="void"/>
    </compose>
  </body>
  <exports>
    <tessellate target="solid_final" chord-tol="0.02" angle-tol="0.05"/>
    <step        target="solid_flange" schema="AP214"/>
    <stl         target="solid_final"  binary="true"/>
  </exports>
</cdml>`;

const dStr = writeString(normativeDocXml);

// ============================================================================
// PASS 1: Initial Evaluation (Default Field Slot = 40.0)
// ============================================================================
console.log('=== PASS 1: Evaluating CDML §14 before Canary Extension runs ===');
const st1 = cadApi.cdml_eval_document(dStr.ptr, dStr.len);
assert.equal(st1, 0, 'Pass 1 CDML evaluation failed');

const p1Str = writeString('mean_bore_stress');
const outPtr1 = 0x3E0000;
cadApi.cdml_get_probe_value(p1Str.ptr, p1Str.len, outPtr1);
const initialStress = new Float64Array(sharedMem.buffer, outPtr1, 1)[0];
assert.equal(initialStress, 40.0, `Expected initial mean_bore_stress == 40.0, got ${initialStress}`);

const p2Str = writeString('housing_volume');
const outPtr2 = 0x3E0010;
cadApi.cdml_get_probe_value(p2Str.ptr, p2Str.len, outPtr2);
const initialVolume = new Float64Array(sharedMem.buffer, outPtr2, 1)[0];
assert.ok(initialVolume > 0, `Expected initial housing_volume > 0, got ${initialVolume}`);

console.log(`[PASS 1 OK] Initial mean_bore_stress: ${initialStress} MPa, housing_volume: ${initialVolume} mm³`);

// ============================================================================
// EXTENSION TICK: Populate Field Slot 0 with Analytical Stress Gradient
// ============================================================================
console.log('=== RUNNING CANARY EXTENSION TICK ===');
extApi.extension_tick(16.0);

assert.ok(lastCommand !== null, 'Extension must post retessellate command via cmd_write');
assert.equal(lastCommand.cmdType, 0x01, 'Command type must be CMD_REQUEST_RETESSELLATE (0x01)');

// Check that 0x1F0000 has been populated with non-zero f32 values
const fieldView = new Float32Array(sharedMem.buffer, 0x1F0000, 64 * 64 * 24);
assert.ok(fieldView[0] >= 40.0 && fieldView[0] <= 200.0, `Expected valid stress value in field buffer, got ${fieldView[0]}`);

console.log(`[CANARY TICK OK] Field buffer populated at 0x1F0000 (Sample 0: ${fieldView[0].toFixed(2)} MPa)`);

// ============================================================================
// PASS 2: Re-Evaluate Document with Populated Field Buffer
// ============================================================================
console.log('=== PASS 2: Re-evaluating CDML §14 with Populated Field Buffer ===');
const st2 = cadApi.cdml_eval_document(dStr.ptr, dStr.len);
assert.equal(st2, 0, 'Pass 2 CDML evaluation failed');

cadApi.cdml_get_probe_value(p1Str.ptr, p1Str.len, outPtr1);
const updatedStress = new Float64Array(sharedMem.buffer, outPtr1, 1)[0];
assert.ok(
  Math.abs(updatedStress - 80.0) < 5.0,
  `Expected mean_bore_stress to update to ~80.0 MPa, got ${updatedStress}`
);

cadApi.cdml_get_probe_value(p2Str.ptr, p2Str.len, outPtr2);
const updatedVolume = new Float64Array(sharedMem.buffer, outPtr2, 1)[0];
assert.ok(
  updatedVolume > initialVolume,
  `Expected housing_volume to increase due to thickened gyroid walls (${updatedVolume} > ${initialVolume})`
);

console.log(`[PASS 2 OK] Updated mean_bore_stress: ${updatedStress.toFixed(2)} MPa (was ${initialStress} MPa)`);
console.log(`[PASS 2 OK] Updated housing_volume: ${updatedVolume.toFixed(2)} mm³ (was ${initialVolume.toFixed(2)} mm³)`);
console.log('=== ZERO-COPY CANARY SHARED-MEMORY EXTENSION VERIFIED CLEANLY ===');
