import { test } from 'node:test';
import * as assert from 'node:assert';
import * as fs from 'node:fs';
import * as path from 'node:path';
import { runCli } from '../dist/cli.js';

test('OpenCAD CLI runs info command without error', () => {
  let output = '';
  const originalLog = console.log;
  console.log = (...args) => {
    output += args.join(' ') + '\n';
  };

  try {
    runCli(['info']);
    assert.match(output, /OpenCAD Standalone Kernel SDK/);
    assert.match(output, /WASM Engine/);
    assert.match(output, /Supported Workbenches/);
  } finally {
    console.log = originalLog;
  }
});

test('OpenCAD CLI emits starter templates', () => {
  let output = '';
  const originalLog = console.log;
  console.log = (...args) => {
    output += args.join(' ') + '\n';
  };

  try {
    runCli(['template', 'bracket']);
    assert.match(output, /CNC_Bracket/);

    output = '';
    runCli(['template', 'enclosure']);
    assert.match(output, /Enclosure_Chassis/);

    output = '';
    runCli(['template', 'flexure']);
    assert.match(output, /XY_Nanopositioner/);

    output = '';
    runCli(['template', 'gyroid']);
    assert.match(output, /Aero_Mount/);
  } finally {
    console.log = originalLog;
  }
});

test('OpenCAD CLI build command generates manufacturing artifacts', () => {
  const tmpDir = path.resolve(process.cwd(), './dist/test-cli-out');
  if (fs.existsSync(tmpDir)) {
    fs.rmSync(tmpDir, { recursive: true, force: true });
  }

  runCli(['build', 'test_part.ocad.ts', '--all', '--out-dir', tmpDir]);

  assert.strictEqual(fs.existsSync(path.join(tmpDir, 'test_part.step')), true);
  assert.strictEqual(fs.existsSync(path.join(tmpDir, 'test_part.3mf')), true);
  assert.strictEqual(fs.existsSync(path.join(tmpDir, 'test_part.dxf')), true);
  assert.strictEqual(fs.existsSync(path.join(tmpDir, 'test_part.gcode')), true);

  // Clean up
  fs.rmSync(tmpDir, { recursive: true, force: true });
});
