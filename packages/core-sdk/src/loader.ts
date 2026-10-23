/**
 * @file loader.ts
 * Universal WebAssembly Loader supporting Web, Web Workers, Node.js, and Bun.
 */

import type { CadCoreWasmExports } from './types.js';

export type WasmBinarySource =
  | string
  | URL
  | ArrayBuffer
  | Uint8Array
  | WebAssembly.Module;

export interface WasmInstanceBundle {
  instance: WebAssembly.Instance;
  module: WebAssembly.Module;
  exports: CadCoreWasmExports;
}

/**
 * Loads and instantiates the cad_core WebAssembly binary across runtime environments.
 */
export async function loadCoreWasm(
  source?: WasmBinarySource,
  importObject: WebAssembly.Imports = {}
): Promise<WasmInstanceBundle> {
  if (!source) {
    try {
      source = new URL('./cad_core.wasm', import.meta.url);
    } catch {
      source = 'cad_core.wasm';
    }
  }

  let module: WebAssembly.Module;
  let instance: WebAssembly.Instance;

  if (source instanceof WebAssembly.Module) {
    module = source;
    instance = await WebAssembly.instantiate(module, importObject);
  } else if (source instanceof ArrayBuffer || source instanceof Uint8Array) {
    const res = await (WebAssembly.instantiate as any)(source, importObject);
    module = res.module ?? module!;
    instance = res.instance ?? res;
  } else if (typeof source === 'string' || source instanceof URL) {
    const urlOrPath = source.toString();

    // Check if file:// protocol in Node.js / Bun
    const proc = (globalThis as any).process;
    if (urlOrPath.startsWith('file://') && typeof proc !== 'undefined' && proc.versions?.node) {
      try {
        const urlMod = await (Function('return import("node:url")')() as Promise<any>);
        const filePath = urlMod.fileURLToPath(urlOrPath);
        const nodeFs = await (Function('return import("node:fs")')() as Promise<any>);
        const bytes = nodeFs.readFileSync(filePath);
        const res = await (WebAssembly.instantiate as any)(bytes, importObject);
        return {
          instance: res.instance ?? res,
          module: res.module ?? res,
          exports: (res.instance ?? res).exports as unknown as CadCoreWasmExports,
        };
      } catch (err) {
        // Fall back to fetch below
      }
    }

    // Check if in browser/worker or remote HTTP
    if (typeof fetch === 'function' && (urlOrPath.startsWith('http://') || urlOrPath.startsWith('https://') || urlOrPath.startsWith('/') || typeof window !== 'undefined')) {
      if (WebAssembly.instantiateStreaming) {
        try {
          const res = await WebAssembly.instantiateStreaming(fetch(urlOrPath), importObject);
          return {
            instance: res.instance,
            module: res.module,
            exports: res.instance.exports as unknown as CadCoreWasmExports,
          };
        } catch {
          // Fallback to fetch -> arrayBuffer
          const resp = await fetch(urlOrPath);
          const bytes = await resp.arrayBuffer();
          const res = await (WebAssembly.instantiate as any)(bytes, importObject);
          return {
            instance: res.instance ?? res,
            module: res.module,
            exports: (res.instance ?? res).exports as unknown as CadCoreWasmExports,
          };
        }
      } else {
        const resp = await fetch(urlOrPath);
        const bytes = await resp.arrayBuffer();
        const res = await (WebAssembly.instantiate as any)(bytes, importObject);
        return {
          instance: res.instance ?? res,
          module: res.module,
          exports: (res.instance ?? res).exports as unknown as CadCoreWasmExports,
        };
      }
    } else {
      // Node.js or Bun local file path
      let bytes: Uint8Array;
      if (typeof (globalThis as any).Bun !== 'undefined') {
        const bunFile = (globalThis as any).Bun.file(urlOrPath);
        bytes = new Uint8Array(await bunFile.arrayBuffer());
      } else {
        // Node.js dynamic filesystem loader
        const nodeFs = await (Function('return import("node:fs")')() as Promise<any>);
        bytes = nodeFs.readFileSync(urlOrPath);
      }
      const res = await (WebAssembly.instantiate as any)(bytes, importObject);
      module = res.module;
      instance = res.instance ?? res;
    }
  } else {
    throw new Error('Invalid WASM binary source provided to loadCoreWasm.');
  }

  return {
    instance,
    module,
    exports: instance.exports as unknown as CadCoreWasmExports,
  };
}
