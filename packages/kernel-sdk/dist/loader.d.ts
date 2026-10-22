/**
 * Zero-dependency WebAssembly loader for OpenCAD modules.
 * Works uniformly in Browser Main Threads, Web Workers, and modern runtimes.
 */
export declare function loadWasmModule<T>(input: string | URL | ArrayBuffer | Response | Promise<Response>, imports?: WebAssembly.Imports): Promise<{
    instance: WebAssembly.Instance;
    exports: T;
}>;
//# sourceMappingURL=loader.d.ts.map