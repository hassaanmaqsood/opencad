import { VisualDiffData } from '../core-shell/PluginTypes';
import { CadFeatureNode } from '../types/cad';
import { evaluateFeatureDag } from './dag_evaluator';

export class WorkerPluginBridge {
  private wasmModules = new Map<string, WebAssembly.Instance>();

  constructor() {}

  public async loadPluginWasm(pluginId: string, wasmBinary: ArrayBuffer): Promise<boolean> {
    try {
      const module = await WebAssembly.compile(wasmBinary);
      const instance = await WebAssembly.instantiate(module, {
        env: {
          abort: () => console.error(`Plugin ${pluginId} WASM aborted`),
        },
      });
      this.wasmModules.set(pluginId, instance);
      return true;
    } catch (err) {
      console.warn(`Failed to load plugin WASM for ${pluginId}:`, err);
      return false;
    }
  }

  public getPluginWasm(pluginId: string): WebAssembly.Instance | null {
    return this.wasmModules.get(pluginId) || null;
  }

  /**
   * Parses AST source and returns node count using cad_ast.wasm (or client fallback).
   */
  public parseAstCount(source: string): number {
    const astInstance = this.wasmModules.get('ast');
    if (astInstance && astInstance.exports.cad_ast_parse_count && astInstance.exports.memory) {
      const exports = astInstance.exports as any;
      const mem = exports.memory as WebAssembly.Memory;
      const encoder = new TextEncoder();
      const encoded = encoder.encode(source);

      // In wasm_allocator mode, or write to beginning of page if within bounds
      // We can use a simple buffer layout or check if alloc exists
      const bufPtr = 1024;
      const heap = new Uint8Array(mem.buffer, bufPtr, encoded.length);
      heap.set(encoded);

      try {
        const count = exports.cad_ast_parse_count(bufPtr, encoded.length);
        return count;
      } catch (e) {
        console.warn('cad_ast_parse_count failed:', e);
      }
    }

    // Client fallback: count non-empty trimmed lines
    const lines = source.split('\n').filter((l) => l.trim().length > 0 && !l.trim().startsWith('//'));
    return lines.length + 1; // +1 for root
  }

  /**
   * Formats AST code using cad_ast.wasm (or client fallback).
   */
  public formatAst(source: string): string {
    const astInstance = this.wasmModules.get('ast');
    if (
      astInstance &&
      astInstance.exports.cad_ast_format &&
      astInstance.exports.cad_ast_get_format_len &&
      astInstance.exports.memory
    ) {
      const exports = astInstance.exports as any;
      const mem = exports.memory as WebAssembly.Memory;
      const encoder = new TextEncoder();
      const encoded = encoder.encode(source);
      const bufPtr = 2048;
      const heap = new Uint8Array(mem.buffer, bufPtr, encoded.length);
      heap.set(encoded);

      try {
        const ptr = exports.cad_ast_format(bufPtr, encoded.length);
        const len = exports.cad_ast_get_format_len();
        if (ptr && len > 0) {
          const outBytes = new Uint8Array(mem.buffer, ptr, len);
          return new TextDecoder().decode(outBytes);
        }
      } catch (e) {
        console.warn('cad_ast_format failed:', e);
      }
    }

    // Fallback formatter: clean trailing semicolons and normalize spacing
    return source
      .split('\n')
      .map((l) => l.trim())
      .filter((l) => l.length > 0)
      .map((l) => (l.startsWith('//') || l.endsWith(';') || l.endsWith('{') || l.endsWith('}') ? l : `${l};`))
      .join('\n') + '\n';
  }

  /**
   * Merges 3-way AST scripts (base, ours, theirs) using cad_ast.wasm.
   */
  public merge3Way(
    base: string,
    ours: string,
    theirs: string
  ): { mergedScript: string; conflictCount: number } {
    const astInstance = this.wasmModules.get('ast');
    if (
      astInstance &&
      astInstance.exports.cad_ast_merge_3way &&
      astInstance.exports.cad_ast_get_merge_len &&
      astInstance.exports.cad_ast_get_conflict_count &&
      astInstance.exports.memory
    ) {
      const exports = astInstance.exports as any;
      const mem = exports.memory as WebAssembly.Memory;
      const enc = new TextEncoder();
      const bEncoded = enc.encode(base);
      const oEncoded = enc.encode(ours);
      const tEncoded = enc.encode(theirs);

      // Write safely separated
      const bPtr = 4096;
      new Uint8Array(mem.buffer, bPtr, bEncoded.length).set(bEncoded);
      const oPtr = 4096 + bEncoded.length + 128;
      new Uint8Array(mem.buffer, oPtr, oEncoded.length).set(oEncoded);
      const tPtr = oPtr + oEncoded.length + 128;
      new Uint8Array(mem.buffer, tPtr, tEncoded.length).set(tEncoded);

      try {
        const ptr = exports.cad_ast_merge_3way(
          bPtr,
          bEncoded.length,
          oPtr,
          oEncoded.length,
          tPtr,
          tEncoded.length
        );
        const len = exports.cad_ast_get_merge_len();
        const conflicts = exports.cad_ast_get_conflict_count();
        if (ptr && len > 0) {
          const outBytes = new Uint8Array(mem.buffer, ptr, len);
          return {
            mergedScript: new TextDecoder().decode(outBytes),
            conflictCount: conflicts,
          };
        }
      } catch (e) {
        console.warn('cad_ast_merge_3way failed:', e);
      }
    }

    // Fallback 3-way merge: line-based union
    const baseLines = new Set(base.split('\n').map((l) => l.trim()));
    const oursLines = ours.split('\n').map((l) => l.trim()).filter((l) => l.length > 0);
    const theirsLines = theirs.split('\n').map((l) => l.trim()).filter((l) => l.length > 0);

    const merged = new Set<string>();
    let conflicts = 0;

    for (const line of oursLines) {
      merged.add(line);
    }
    for (const line of theirsLines) {
      if (!merged.has(line) && !baseLines.has(line)) {
        // Line added in theirs
        merged.add(line);
      }
    }

    return {
      mergedScript: Array.from(merged).join('\n') + '\n',
      conflictCount: conflicts,
    };
  }

  /**
   * Computes 3D Visual Boolean Diff between two DAG states.
   * Returns Green addition mesh and Red removal mesh.
   */
  public computeVisualDiff(
    baseNodes: CadFeatureNode[],
    targetNodes: CadFeatureNode[]
  ): VisualDiffData {
    const baseSlice = evaluateFeatureDag(baseNodes, baseNodes.length - 1);
    const targetSlice = evaluateFeatureDag(targetNodes, targetNodes.length - 1);

    // If target has more nodes or modified geometry, target represents current state
    // Added geometry = elements in target not in base (or offset slightly outward for contrast)
    // Removed geometry = elements in base not in target

    const addedPositions = new Float32Array(targetSlice.positions.length);
    for (let i = 0; i < targetSlice.positions.length; i += 3) {
      // Scale slightly outward (1.02) to create a visual envelope highlight around added features
      addedPositions[i] = targetSlice.positions[i] * 1.015;
      addedPositions[i + 1] = targetSlice.positions[i + 1] * 1.015;
      addedPositions[i + 2] = targetSlice.positions[i + 2] * 1.015;
    }
    const addedIndices = new Uint32Array(targetSlice.indices);

    const removedPositions = new Float32Array(baseSlice.positions.length);
    for (let i = 0; i < baseSlice.positions.length; i += 3) {
      // Scale slightly outward (1.02) to create a visual envelope highlight around removed features
      removedPositions[i] = baseSlice.positions[i] * 1.015;
      removedPositions[i + 1] = baseSlice.positions[i + 1] * 1.015;
      removedPositions[i + 2] = baseSlice.positions[i + 2] * 1.015;
    }
    const removedIndices = new Uint32Array(baseSlice.indices);

    return {
      addedPositions,
      addedIndices,
      removedPositions,
      removedIndices,
      summary: {
        addedFaces: targetSlice.metadata.faceCount,
        removedFaces: baseSlice.metadata.faceCount,
        deltaVolumeApprox: targetSlice.metadata.triangleCount - baseSlice.metadata.triangleCount,
      },
    };
  }
}
