/**
 * Zero-dependency WebAssembly loader for OpenCAD modules.
 * Works uniformly in Browser Main Threads, Web Workers, and modern runtimes.
 */
export async function loadWasmModule<T>(
  input: string | URL | ArrayBuffer | Response | Promise<Response>,
  imports: WebAssembly.Imports = { env: { abort: () => console.error('Wasm aborted') } }
): Promise<{ instance: WebAssembly.Instance; exports: T }> {
  let bytes: ArrayBuffer;

  if (input instanceof ArrayBuffer) {
    bytes = input;
  } else if (typeof Response !== 'undefined' && input instanceof Response) {
    bytes = await input.arrayBuffer();
  } else if (typeof input === 'string' || input instanceof URL) {
    const res = await fetch(input);
    bytes = await res.arrayBuffer();
  } else {
    const res = await input;
    bytes = await res.arrayBuffer();
  }

  const module = await WebAssembly.compile(bytes);
  const instance = await WebAssembly.instantiate(module, imports);
  return {
    instance,
    exports: instance.exports as unknown as T,
  };
}
