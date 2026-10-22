import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  OpenCadCore,
  OpenCadSheetMetal,
  OpenCadFeaFlexure,
  OpenCadImplicit,
  OpenCadCamHlr,
  loadWasmModule,
} from '../dist/index.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const wasmDir = path.resolve(__dirname, '../../../web-app/public');

test('Kernel SDK exports all workbench classes and loadWasmModule function', () => {
  assert.ok(OpenCadCore, 'OpenCadCore should be defined');
  assert.ok(OpenCadSheetMetal, 'OpenCadSheetMetal should be defined');
  assert.ok(OpenCadFeaFlexure, 'OpenCadFeaFlexure should be defined');
  assert.ok(OpenCadImplicit, 'OpenCadImplicit should be defined');
  assert.ok(OpenCadCamHlr, 'OpenCadCamHlr should be defined');
  assert.equal(typeof loadWasmModule, 'function', 'loadWasmModule should be a function');
});

test('OpenCadCore loads cad_core.wasm and generates parametric box buffers', async () => {
  const wasmPath = path.join(wasmDir, 'cad_core.wasm');
  assert.ok(fs.existsSync(wasmPath), 'cad_core.wasm must exist in web-app/public');

  const bytes = fs.readFileSync(wasmPath);
  const core = await OpenCadCore.create(bytes.buffer);
  assert.ok(core, 'OpenCadCore instance should be created');

  const buffers = core.generateBox(2.0, 3.0, 4.0);
  if (buffers) {
    assert.ok(buffers.positions instanceof Float32Array, 'positions should be Float32Array');
    assert.ok(buffers.normals instanceof Float32Array, 'normals should be Float32Array');
    assert.ok(buffers.indices instanceof Uint32Array, 'indices should be Uint32Array');
    assert.ok(buffers.positions.length > 0, 'positions buffer should not be empty');
  }
});

test('OpenCadSheetMetal loads cad_sheetmetal.wasm and computes bend allowances', async () => {
  const wasmPath = path.join(wasmDir, 'cad_sheetmetal.wasm');
  assert.ok(fs.existsSync(wasmPath), 'cad_sheetmetal.wasm must exist in web-app/public');

  const bytes = fs.readFileSync(wasmPath);
  const sm = await OpenCadSheetMetal.create(bytes.buffer);
  assert.ok(sm, 'OpenCadSheetMetal instance should be created');

  const bend = sm.calcBend(2.0, 3.0, 0.44, Math.PI / 2);
  assert.equal(typeof bend.bendAllowance, 'number', 'bendAllowance should be a number');
  assert.equal(typeof bend.bendDeduction, 'number', 'bendDeduction should be a number');

  const unfold = sm.unfoldBox(100, 100, 2.0, 3.0, 0.44, 20);
  assert.equal(typeof unfold.pointCount, 'number');
  assert.equal(typeof unfold.totalWidth, 'number');
  assert.equal(typeof unfold.totalLength, 'number');
});

test('OpenCadFeaFlexure loads cad_fea_flexure.wasm and calculates stiffness', async () => {
  const wasmPath = path.join(wasmDir, 'cad_fea_flexure.wasm');
  assert.ok(fs.existsSync(wasmPath), 'cad_fea_flexure.wasm must exist in web-app/public');

  const bytes = fs.readFileSync(wasmPath);
  const fea = await OpenCadFeaFlexure.create(bytes.buffer);
  assert.ok(fea, 'OpenCadFeaFlexure instance should be created');

  const stiffness = fea.calcBladeStiffness(50, 10, 1, 200000);
  assert.equal(typeof stiffness, 'number', 'calcBladeStiffness should return a number');

  const compliance = fea.calcNotchCompliance(10, 1, 2, 200000);
  assert.equal(typeof compliance, 'number', 'calcNotchCompliance should return a number');

  const mesh = fea.generateBoxMesh(10, 10, 10, 2, 2, 2);
  assert.equal(typeof mesh.nodeCount, 'number');
  assert.equal(typeof mesh.elementCount, 'number');
});

test('OpenCadImplicit loads cad_implicit_ntop.wasm and evaluates TPMS fields', async () => {
  const wasmPath = path.join(wasmDir, 'cad_implicit_ntop.wasm');
  assert.ok(fs.existsSync(wasmPath), 'cad_implicit_ntop.wasm must exist in web-app/public');

  const bytes = fs.readFileSync(wasmPath);
  const implicit = await OpenCadImplicit.create(bytes.buffer);
  assert.ok(implicit, 'OpenCadImplicit instance should be created');

  const gyroidVal = implicit.evalGyroid(0.5, 0.5, 0.5, 10, 1);
  assert.equal(typeof gyroidVal, 'number', 'evalGyroid should return a number');

  const sphereVerts = implicit.meshSphere(5.0, 16);
  assert.equal(typeof sphereVerts, 'number', 'meshSphere should return a number');
});

test('OpenCadCamHlr loads cad_mfg_cam.wasm and projects isometric points', async () => {
  const wasmPath = path.join(wasmDir, 'cad_mfg_cam.wasm');
  assert.ok(fs.existsSync(wasmPath), 'cad_mfg_cam.wasm must exist in web-app/public');

  const bytes = fs.readFileSync(wasmPath);
  const cam = await OpenCadCamHlr.create(bytes.buffer);
  assert.ok(cam, 'OpenCadCamHlr instance should be created');

  const projected = cam.projectIsometric(10, 20, 30);
  assert.ok(Array.isArray(projected), 'projectIsometric should return array');
  assert.equal(projected.length, 2, 'projectIsometric should return 2D point [x, y]');
  assert.equal(typeof projected[0], 'number');
  assert.equal(typeof projected[1], 'number');
});
