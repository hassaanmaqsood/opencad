// bindings/python/opencad/_eval_runner.js
import fs from 'node:fs';

const chunks = [];
process.stdin.on('data', chunk => chunks.push(chunk));
process.stdin.on('end', async () => {
  try {
    const input = JSON.parse(Buffer.concat(chunks).toString('utf-8'));
    const wasmPath = input.wasmPath;
    const xml = input.xml;
    const imports = input.imports || {};
    const probeIds = input.probeIds || [];

    if (!fs.existsSync(wasmPath)) {
      throw new Error(`WASM binary not found at ${wasmPath}`);
    }

    const wasmBytes = fs.readFileSync(wasmPath);
    const sharedMem = new WebAssembly.Memory({ initial: 128, maximum: 512, shared: true });
    const opencadImports = {
      field_alloc: () => 0,
      field_eval_scalar: (_s, _x, _y, _z, defVal) => defVal,
      field_eval_vec3: () => {},
      cmd_write: () => {},
    };

    const { instance } = await WebAssembly.instantiate(wasmBytes, {
      env: { memory: sharedMem },
      opencad: opencadImports,
    });
    const api = instance.exports;
    api.kernel_init();

    let scratchCursor = 0x300000;
    function writeString(str) {
      const bytes = Buffer.from(str, 'utf-8');
      const ptr = scratchCursor;
      new Uint8Array(sharedMem.buffer).set(bytes, ptr);
      scratchCursor += bytes.length + 16;
      return { ptr, len: bytes.length };
    }

    // Register imports
    for (const [path, content] of Object.entries(imports)) {
      const p = writeString(path);
      const c = writeString(content);
      api.cdml_register_import(p.ptr, p.len, c.ptr, c.len);
    }

    // Evaluate document
    const docStr = writeString(xml);
    const status = api.cdml_eval_document(docStr.ptr, docStr.len);

    let diagnostic = '';
    if (status !== 0) {
      const diagPtr = api.get_string_ptr();
      const diagLen = api.get_string_len();
      if (diagPtr && diagLen > 0) {
        diagnostic = Buffer.from(sharedMem.buffer, diagPtr, diagLen).toString('utf-8');
      }
    }

    // Read probes
    const probes = {};
    for (const pid of probeIds) {
      const pStr = writeString(pid);
      scratchCursor = (scratchCursor + 15) & ~15;
      const outPtr = scratchCursor;
      scratchCursor += 16;
      const pRes = api.cdml_get_probe_value(pStr.ptr, pStr.len, outPtr);
      if (pRes === 0) {
        const val = new Float64Array(sharedMem.buffer, outPtr, 1)[0];
        probes[pid] = val;
      }
    }

    // Also auto-detect probes from XML if none provided
    const probeMatches = xml.matchAll(/<probe\s+[^>]*id="([^"]+)"/g);
    for (const m of probeMatches) {
      const pid = m[1];
      if (probes[pid] === undefined) {
        const pStr = writeString(pid);
        scratchCursor = (scratchCursor + 15) & ~15;
        const outPtr = scratchCursor;
        scratchCursor += 16;
        const pRes = api.cdml_get_probe_value(pStr.ptr, pStr.len, outPtr);
        if (pRes === 0) {
          const val = new Float64Array(sharedMem.buffer, outPtr, 1)[0];
          probes[pid] = val;
        }
      }
    }

    // Read STEP
    let stepStr = '';
    const stepPtr = api.get_step_ptr();
    const stepLen = api.get_step_len();
    if (stepPtr && stepLen > 0) {
      stepStr = Buffer.from(sharedMem.buffer, stepPtr, stepLen).toString('utf-8');
    }

    // Read STL
    let stlBase64 = '';
    const stlPtr = api.get_stl_ptr();
    const stlLen = api.get_stl_len();
    if (stlPtr && stlLen > 0) {
      stlBase64 = Buffer.from(sharedMem.buffer, stlPtr, stlLen).toString('base64');
    }

    const result = {
      status,
      diagnostic,
      probes,
      step: stepStr,
      stl_base64: stlBase64,
    };

    process.stdout.write(JSON.stringify(result));
  } catch (err) {
    process.stdout.write(JSON.stringify({
      status: -1,
      diagnostic: err.message,
      probes: {},
      step: '',
      stl_base64: '',
    }));
  }
});
