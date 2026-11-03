// scripts/test_wasm_blackbox.mjs
import fs from 'node:fs';
import assert from 'node:assert/strict';

const wasmPath = './kernel-zig/zig-out/bin/cad_kernel.wasm';
assert.ok(fs.existsSync(wasmPath), `Missing compiled WASM at ${wasmPath}`);

const sharedMem = new WebAssembly.Memory({ initial: 128, maximum: 512, shared: true });
const wasmBytes = fs.readFileSync(wasmPath);

let wasmModule;
const imports = {
  env: { memory: sharedMem },
  opencad: {
    field_alloc: () => 0,
    field_eval_scalar: () => 0.0,
    field_eval_vec3: () => {},
    cmd_write: () => {},
  }
};

const { instance } = await WebAssembly.instantiate(wasmBytes, imports);
const api = instance.exports;

// 1. Verify required Pure-Math ABI exports exist
for (const fn of [
  'kernel_init', 'handle_free', 'expr_compile', 'expr_eval',
  'sys_create', 'sys_alloc_params', 'sys_add_residual', 'sys_solve', 'sys_get_dof', 'sys_read_params',
  'curve_define_nurbs', 'wire_assemble', 'solid_kinematic_sweep', 'solid_tensor_loft',
  'solid_envelope_fillet', 'solid_offset_shell', 'solid_boolean', 'solid_implicit_field',
  'solid_tessellate', 'solid_export_step', 'solid_export_stl',
  'get_positions_ptr', 'get_positions_len', 'get_normals_ptr', 'get_normals_len',
  'get_indices_ptr', 'get_indices_len', 'get_face_ids_ptr', 'get_face_ids_len',
  'get_string_ptr', 'get_string_len'
]) {
  assert.equal(typeof api[fn], 'function', `Missing required mathematical ABI export: ${fn}`);
}

api.kernel_init();

// 2. Verify Shared Memory Control Block at 0x0000
const ctrlView = new DataView(sharedMem.buffer, 0x0000, 64);
assert.equal(ctrlView.getUint32(0x00, true), 0x4F434144, 'Control block magic must be 0x4F434144 ("OCAD")');
assert.equal(ctrlView.getUint32(0x08, true), 0x001000, 'Solid arena offset must be 0x001000');
assert.equal(ctrlView.getUint32(0x0C, true), 0x0F0000, 'Tessellation buffer offset must be 0x0F0000');
assert.equal(ctrlView.getUint32(0x10, true), 0x1F0000, 'Field buffer offset must be 0x1F0000');

console.log('[BLACKBOX] Control Block & 18-Function Pure-Math ABI verified.');
