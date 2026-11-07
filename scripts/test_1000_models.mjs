// scripts/test_1000_models.mjs
import fs from 'node:fs';
import path from 'node:path';

const wasmPath = './kernel-zig/zig-out/bin/cad_kernel.wasm';
if (!fs.existsSync(wasmPath)) {
  console.error(`Missing WASM at ${wasmPath}`);
  process.exit(1);
}

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
api.kernel_init();

let scratchCursor = 0x300000;
function writeString(str) {
  const bytes = Buffer.from(str, 'utf-8');
  scratchCursor = (scratchCursor + 15) & ~15;
  if (scratchCursor + bytes.length + 32 > 0x5F0000) {
    scratchCursor = 0x300000; // Reset scratch cursor within safe scratch window
  }
  const ptr = scratchCursor;
  new Uint8Array(sharedMem.buffer).set(bytes, ptr);
  scratchCursor += bytes.length + 16;
  return { ptr, len: bytes.length };
}

function getDiagnostic() {
  const ptr = api.get_string_ptr ? api.get_string_ptr() : 0;
  const len = api.get_string_len ? api.get_string_len() : 0;
  if (!ptr || len === 0 || len > 16384) return null;
  const bytes = new Uint8Array(sharedMem.buffer, ptr, len);
  const text = new TextDecoder().decode(bytes);
  try {
    return JSON.parse(text);
  } catch (e) {
    return { raw: text };
  }
}

// Read all CDML files from examples/lib
const libDir = './examples/lib';
const files = fs.readdirSync(libDir)
  .filter(f => f.endsWith('.cdml'))
  .sort();

console.log(`Found ${files.length} CDML models in ${libDir}. Beginning evaluation batch...`);

const stats = {
  total: files.length,
  passed: 0,
  failed: 0,
  openEdges: 0,
  zeroTriangles: 0,
  errorDetails: []
};

const startTime = Date.now();

for (let idx = 0; idx < files.length; idx++) {
  const file = files[idx];
  const filePath = path.join(libDir, file);
  const xml = fs.readFileSync(filePath, 'utf-8');

  const docStr = writeString(xml);
  const status = api.cdml_eval_document(docStr.ptr, docStr.len);

  if (status !== 0x0000) {
    stats.failed++;
    const diag = getDiagnostic();
    stats.errorDetails.push({ file, status, error: diag?.error || diag?.raw || 'Unknown error' });
    continue;
  }

  // Read tessellation control block
  const ctrlView = new DataView(sharedMem.buffer, 0x0F0000, 128);
  const vCount = ctrlView.getUint32(0x04, true);
  const triCount = ctrlView.getUint32(0x08, true);
  const posOffset = ctrlView.getUint32(0x0C, true);
  const idxOffset = ctrlView.getUint32(0x14, true);

  if (triCount === 0 || vCount === 0) {
    stats.zeroTriangles++;
    stats.errorDetails.push({ file, status: 0, error: `Zero triangles/vertices (v=${vCount}, t=${triCount})` });
    continue;
  }

  // Check for NaN or Inf in positions
  const posView = new Float32Array(sharedMem.buffer, posOffset, vCount * 3);
  let hasNan = false;
  for (let i = 0; i < posView.length; i++) {
    if (isNaN(posView[i]) || !isFinite(posView[i])) {
      hasNan = true;
      break;
    }
  }

  if (hasNan) {
    stats.failed++;
    stats.errorDetails.push({ file, status: 0, error: 'NaN or Inf found in vertex positions' });
    continue;
  }

  // Check manifold / boundary edges
  const idxView = new Uint32Array(sharedMem.buffer, idxOffset, triCount * 3);
  const edgeCounts = new Map();
  for (let i = 0; i < idxView.length; i += 3) {
    const a = idxView[i], b = idxView[i + 1], c = idxView[i + 2];
    const e0 = a < b ? `${a}_${b}` : `${b}_${a}`;
    const e1 = b < c ? `${b}_${c}` : `${c}_${b}`;
    const e2 = c < a ? `${c}_${a}` : `${a}_${c}`;
    edgeCounts.set(e0, (edgeCounts.get(e0) || 0) + 1);
    edgeCounts.set(e1, (edgeCounts.get(e1) || 0) + 1);
    edgeCounts.set(e2, (edgeCounts.get(e2) || 0) + 1);
  }

  let openBoundaryCount = 0;
  for (const cnt of edgeCounts.values()) {
    if (cnt === 1) openBoundaryCount++;
  }

  if (openBoundaryCount > 0) {
    stats.openEdges++;
    // Some models like open surfaces or 2D sheets might have boundary edges, let's track
    if (stats.openEdges <= 10) {
      console.warn(`[Boundary Edges] ${file}: ${openBoundaryCount} open boundary edges`);
    }
  }

  stats.passed++;

  if ((idx + 1) % 100 === 0) {
    console.log(`Evaluated ${idx + 1}/${files.length} models... (${stats.passed} passed, ${stats.failed} failed)`);
  }
}

const elapsedSec = ((Date.now() - startTime) / 1000).toFixed(2);
console.log('\n========================================');
console.log(`BATCH EVALUATION FINISHED in ${elapsedSec}s`);
console.log(`Total: ${stats.total}`);
console.log(`Passed: ${stats.passed}`);
console.log(`Failed: ${stats.failed}`);
console.log(`Zero Triangles: ${stats.zeroTriangles}`);
console.log(`With Open Boundary Edges: ${stats.openEdges}`);
console.log('========================================\n');

if (stats.errorDetails.length > 0) {
  console.log(`First 20 errors:`);
  for (const err of stats.errorDetails.slice(0, 20)) {
    console.log(` - ${err.file}: [0x${err.status.toString(16)}] ${err.error}`);
  }
}
