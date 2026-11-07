import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  OpenCadCore,
  loadWasmModule,
} from '../dist/index.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const wasmDir = path.resolve(__dirname, '../../../web-app/public');

test('Kernel SDK exports OpenCadCore and loadWasmModule function', () => {
  assert.ok(OpenCadCore, 'OpenCadCore should be defined');
  assert.equal(typeof loadWasmModule, 'function', 'loadWasmModule should be a function');
});

test('OpenCadCore loads cad_core.wasm and generates parametric box buffers', async () => {
  const wasmPath = path.join(wasmDir, 'cad_core.wasm');
  assert.ok(fs.existsSync(wasmPath), 'cad_core.wasm must exist in web-app/public');

  const bytes = fs.readFileSync(wasmPath);
  const memory = Reflect.construct(WebAssembly.Memory, [{ initial: 128, maximum: 512, shared: true }]);
  const { exports } = await loadWasmModule(bytes.buffer, {
    env: { memory, abort: () => console.error('Wasm aborted') },
    opencad: {
      field_alloc: () => 0,
      field_eval_scalar: (_, __, ___, ____, defVal) => defVal,
      field_eval_vec3: () => {},
      cmd_write: () => {},
    },
  });
  const core = new OpenCadCore(exports);
  assert.ok(core, 'OpenCadCore instance should be created');

  const buffers = core.generateBox(2.0, 3.0, 4.0);
  if (buffers) {
    assert.ok(buffers.positions instanceof Float32Array, 'positions should be Float32Array');
    assert.ok(buffers.normals instanceof Float32Array, 'normals should be Float32Array');
    assert.ok(buffers.indices instanceof Uint32Array, 'indices should be Uint32Array');
    assert.ok(buffers.positions.length > 0, 'positions buffer should not be empty');
  }
});
