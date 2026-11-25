/**
 * @module opencad-bridge
 * Drop-in WebAssembly bridge for OpenCAD (`cad_kernel.wasm` / `cad_core.wasm`).
 * Manages SharedArrayBuffer lifecycle, CDML evaluation, 0x0F0000 tessellation slices,
 * 0x1F0000 voxel field injection, <probe> queries, and STEP / STL exports.
 */

export const TESS_HEADER_OFFSET = 0x0F0000;
export const FIELD_BUFFER_OFFSET = 0x1F0000;
export const SCRATCH_DOC_OFFSET = 0x5A0000;
export const SCRATCH_PROBE_NAME_OFFSET = 0x5E8000;
export const SCRATCH_PROBE_OUT_OFFSET = 0x5E9000;

export class OpenCadBridge {
  /**
   * @param {WebAssembly.Exports} api
   * @param {WebAssembly.Memory} memory
   */
  constructor(api, memory) {
    this.api = api;
    this.memory = memory;
  }

  /**
   * Instantiates the OpenCAD WebAssembly kernel using SharedArrayBuffer.
   * @param {Object} [options]
   * @param {string[]} [options.wasmUrls]
   * @returns {Promise<OpenCadBridge>}
   */
  static async create(options = {}) {
    if (typeof SharedArrayBuffer === 'undefined' || !self.crossOriginIsolated) {
      throw new Error('SharedArrayBuffer requires COOP/COEP headers or coi-serviceworker.js');
    }
    const candidates = options.wasmUrls || [
      './cad_kernel.wasm',
      './cad_core.wasm',
      '../../web-app/public/cad_kernel.wasm',
      'https://cdn.jsdelivr.net/gh/hassaanmaqsood/opencad@dist/cad_core.wasm',
    ];
    let lastErr;
    for (const url of candidates) {
      try {
        const resp = await fetch(url);
        if (!resp.ok) continue;
        const bytes = await resp.arrayBuffer();
        const memory = new WebAssembly.Memory({ initial: 128, maximum: 512, shared: true });
        const { instance } = await WebAssembly.instantiate(bytes, {
          env: {
            memory,
            abort: () => { throw new Error('OpenCAD WASM abort'); },
          },
          opencad: {
            field_alloc: () => 0,
            field_eval_scalar: (_s, _x, _y, _z, defVal) => defVal,
            field_eval_vec3: () => {},
            cmd_write: () => {},
          },
        });
        instance.exports.kernel_init();
        return new OpenCadBridge(instance.exports, memory);
      } catch (err) {
        lastErr = err;
      }
    }
    throw lastErr || new Error('Failed to load cad_kernel.wasm');
  }

  /**
   * Writes a UTF-8 string into the WASM linear memory scratch window.
   * @param {string} str
   * @param {number} [offset]
   * @returns {{ ptr: number, len: number }}
   */
  writeString(str, offset = SCRATCH_DOC_OFFSET) {
    const bytes = new TextEncoder().encode(str);
    new Uint8Array(this.memory.buffer, offset, bytes.length).set(bytes);
    return { ptr: offset, len: bytes.length };
  }

  /**
   * Reads a named <probe> value from the last evaluated CDML document.
   * @param {string} probeId
   * @returns {number}
   */
  readProbe(probeId) {
    const p = this.writeString(probeId, SCRATCH_PROBE_NAME_OFFSET);
    if (this.api.cdml_get_probe_value(p.ptr, p.len, SCRATCH_PROBE_OUT_OFFSET) !== 0) {
      return NaN;
    }
    return new DataView(this.memory.buffer).getFloat64(SCRATCH_PROBE_OUT_OFFSET, true);
  }

  /**
   * Evaluates a CDML v1.0 XML string and returns the tessellated 3D B-Rep mesh and probes.
   * @param {string} xml
   * @param {string[]} [probeIds]
   */
  evalCdml(xml, probeIds = ['plate_volume', 'mean_bore_temp']) {
    const s = this.writeString(xml, SCRATCH_DOC_OFFSET);
    const status = this.api.cdml_eval_document(s.ptr, s.len);
    if (status !== 0) {
      throw new Error(`OpenCAD error 0x${status.toString(16)}`);
    }
    const hdr = new DataView(this.memory.buffer, TESS_HEADER_OFFSET, 128);
    const vertexCount = hdr.getUint32(0x04, true);
    const triangleCount = hdr.getUint32(0x08, true);
    const posOffset = hdr.getUint32(0x0C, true);
    const idxOffset = hdr.getUint32(0x14, true);
    const bbox = [
      hdr.getFloat64(0x20, true), hdr.getFloat64(0x28, true), hdr.getFloat64(0x30, true),
      hdr.getFloat64(0x38, true), hdr.getFloat64(0x40, true), hdr.getFloat64(0x48, true),
    ];

    const probes = {};
    for (const id of probeIds) {
      probes[id] = this.readProbe(id);
    }

    return {
      vertexCount,
      triangleCount,
      positions: new Float32Array(new Float32Array(this.memory.buffer, posOffset, vertexCount * 3)),
      indices: new Uint32Array(new Uint32Array(this.memory.buffer, idxOffset, triangleCount * 3)),
      bbox,
      probes,
      volume: probes.plate_volume ?? NaN,
      boreTempProbe: probes.mean_bore_temp ?? NaN,
    };
  }

  /**
   * Writes a 3D Float32Array voxel grid into OpenCAD's shared Field Buffer at 0x1F0000.
   * @param {Float32Array} gridData
   */
  writeFieldBuffer(gridData) {
    const dest = new Float32Array(this.memory.buffer, FIELD_BUFFER_OFFSET, gridData.length);
    dest.set(gridData);
  }

  /**
   * Returns a copy of the active STEP or STL export buffer.
   * @param {'step'|'stl'} kind
   * @returns {Uint8Array|null}
   */
  getExportBytes(kind) {
    const ptr = kind === 'step' ? this.api.get_step_ptr() : this.api.get_stl_ptr();
    const len = kind === 'step' ? this.api.get_step_len() : this.api.get_stl_len();
    if (!ptr || !len) return null;
    return new Uint8Array(this.memory.buffer, ptr, len).slice();
  }
}
