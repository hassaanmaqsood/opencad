/**
 * @file loader.ts
 * Universal WebAssembly Loader supporting Web, Web Workers, Node.js, and Bun.
 */
/**
 * Loads and instantiates the cad_core WebAssembly binary across runtime environments.
 */
export async function loadCoreWasm(source, importObject = {}) {
    if (!source) {
        try {
            source = new URL('./cad_core.wasm', import.meta.url);
        }
        catch {
            source = 'cad_core.wasm';
        }
    }
    let module;
    let instance;
    if (source instanceof WebAssembly.Module) {
        module = source;
        instance = await WebAssembly.instantiate(module, importObject);
    }
    else if (source instanceof ArrayBuffer || source instanceof Uint8Array) {
        const res = await WebAssembly.instantiate(source, importObject);
        module = res.module ?? module;
        instance = res.instance ?? res;
    }
    else if (typeof source === 'string' || source instanceof URL) {
        const urlOrPath = source.toString();
        // Check if file:// protocol in Node.js / Bun
        const proc = globalThis.process;
        if (urlOrPath.startsWith('file://') && typeof proc !== 'undefined' && proc.versions?.node) {
            try {
                const urlMod = await Function('return import("node:url")')();
                const filePath = urlMod.fileURLToPath(urlOrPath);
                const nodeFs = await Function('return import("node:fs")')();
                const bytes = nodeFs.readFileSync(filePath);
                const res = await WebAssembly.instantiate(bytes, importObject);
                return {
                    instance: res.instance ?? res,
                    module: res.module ?? res,
                    exports: (res.instance ?? res).exports,
                };
            }
            catch (err) {
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
                        exports: res.instance.exports,
                    };
                }
                catch {
                    // Fallback to fetch -> arrayBuffer
                    const resp = await fetch(urlOrPath);
                    const bytes = await resp.arrayBuffer();
                    const res = await WebAssembly.instantiate(bytes, importObject);
                    return {
                        instance: res.instance ?? res,
                        module: res.module,
                        exports: (res.instance ?? res).exports,
                    };
                }
            }
            else {
                const resp = await fetch(urlOrPath);
                const bytes = await resp.arrayBuffer();
                const res = await WebAssembly.instantiate(bytes, importObject);
                return {
                    instance: res.instance ?? res,
                    module: res.module,
                    exports: (res.instance ?? res).exports,
                };
            }
        }
        else {
            // Node.js or Bun local file path
            let bytes;
            if (typeof globalThis.Bun !== 'undefined') {
                const bunFile = globalThis.Bun.file(urlOrPath);
                bytes = new Uint8Array(await bunFile.arrayBuffer());
            }
            else {
                // Node.js dynamic filesystem loader
                const nodeFs = await Function('return import("node:fs")')();
                bytes = nodeFs.readFileSync(urlOrPath);
            }
            const res = await WebAssembly.instantiate(bytes, importObject);
            module = res.module;
            instance = res.instance ?? res;
        }
    }
    else {
        throw new Error('Invalid WASM binary source provided to loadCoreWasm.');
    }
    return {
        instance,
        module,
        exports: instance.exports,
    };
}
//# sourceMappingURL=loader.js.map